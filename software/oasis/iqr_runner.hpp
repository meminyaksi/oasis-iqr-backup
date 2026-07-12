#pragma once

#include "oasis/iqr_config.hpp"
#include "oasis/oasis_context.hpp"

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>

#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

namespace oasis {

/**
 * Drives the IQR_detection vFPGA operator for one column, re-homed on OasisContext.
 *
 * This is the oasis port of celeris::IqrOperator's core: the host streams the (already decoded)
 * 64-bit value column to the device TWICE on stream 0 --
 *   pass 1 (HISTOGRAM) -> the FPGA builds a banked histogram and, in hardware, derives Q1/Q3 and
 *                         the 1.5*IQR fences (the host never sees the histogram),
 *   pass 2 (FLAG)      -> the same column is re-streamed and the FPGA emits a dense, packed
 *                         1-bit-per-element outlier bitmask.
 *
 * The caller (the iqr_flags table function) supplies the decoded column as host buffers. The runner
 * caches nothing of its own across calls -- it is single-use per column, mirroring the standalone
 * operator. Only 64-bit (INT64) columns are supported (the vFPGA top instantiates IQR_detection
 * with value_t = data64_t, an 8x64 ndata layout).
 *
 * NOTE: unlike celeris, the runner does NOT round-trip a Table. The two passes stream the same host
 * buffers the caller passes in -- so the caller owns the decoded-column lifetime for the duration of
 * run().
 */
class IqrRunner {
  public:
    // One contiguous decoded-column chunk to stream: raw pointer + byte size. The runner treats the
    // bytes as packed int64 values.
    using InputChunk = std::pair<const void *, size_t>;

    struct Result {
        // Packed outlier bitmask: ceil(N/512) 64-byte beats, 1 bit per input element (1 = outlier).
        std::shared_ptr<libstf::Buffer> flags;
        size_t                          num_elements = 0;

        // The histogram window actually used (derived in auto mode, else the explicit values).
        int64_t  bin_min   = 0;
        uint64_t bin_shift = 0;

        // Debug: the device's histogram grand total for this run (== num_elements iff the banks were
        // zeroed; a short-fall exposes the silicon count-loss we documented).
        uint64_t histogram_total = 0;

        // Count-loss diagnostics (per run). The chain  num_elements >= accepted >= committed >=
        // histogram_total  localizes where pass-1 counts are lost: accepted < num_elements -> input/
        // DMA; committed < accepted -> coalescing; histogram_total < committed -> BRAM RMW hazard.
        // collisions counts flush-reads that hit a just-written bin (direct hazard evidence);
        // flushes is the BRAM write count.
        uint64_t accepted   = 0;
        uint64_t committed  = 0;
        uint64_t flushes    = 0;
        uint64_t collisions = 0;

        // StreamProfiler cycle breakdown (read after both passes). input_* aggregates the histogram
        // + flag input streams; output_* is the flag emission. starved dominating input => the path
        // is host/DMA-bound (the round-trip HBM staging targets); stalled dominating => back-pressured.
        IqrConfig::StreamProfile input_profile  = {};
        IqrConfig::StreamProfile output_profile = {};
    };

    /**
     * @param ctx          the shared oasis context (owns the cThread, memory pool, TLB, configs).
     * @param is_signed    treat the column values as signed (sign-aware binning + fences).
     * @param auto_window  if true, derive bin_min/bin_shift from a sample of the data; if false, use
     *                     the explicit bin_min/bin_shift passed in.
     * @param bin_min      explicit histogram window low edge   (used only when auto_window == false).
     * @param bin_shift    explicit bin width = 2**bin_shift     (used only when auto_window == false).
     */
    IqrRunner(OasisContext &ctx, bool is_signed, bool auto_window, int64_t bin_min = 0,
              uint64_t bin_shift = 0, bool use_card = false);

    /**
     * Streams `inputs` through both passes and returns the packed outlier bitmask. The chunks are
     * concatenated logically in order; `last` is asserted only on the final chunk of pass 2's input.
     * Throws std::runtime_error on allocation / timeout failures.
     */
    Result run(const std::vector<InputChunk> &inputs);

  private:
    OasisContext              &ctx_;
    std::shared_ptr<IqrConfig> iqr_config_;

    bool     is_signed_;
    bool     auto_window_;
    int64_t  bin_min_;
    uint64_t bin_shift_;
    bool     use_card_;   // read the two passes from card/HBM instead of re-DMAing from the host

    // Histogram bin count baked into the bitstream (must match the vFPGA top's IQR_NUM_BINS).
    static constexpr int64_t NUM_BINS      = 1024;
    static constexpr size_t  SAMPLE_TARGET = 8192;   // ~rows sampled to size the window
    // Card stream index the HBM-staged column is read on (matches axis_card_recv[0] in vfpga_top).
    static constexpr int64_t CARD_STREAM   = 0;

    // Counts total int64 elements across all chunks.
    static size_t count_elements(const std::vector<InputChunk> &inputs);

    // Sets bin_min_/bin_shift_ from a robust percentile range of a stride-sample of the data, so a
    // stray outlier cannot blow up the bin width. Port of celeris::IqrOperator::derive_window.
    void derive_window(const std::vector<InputChunk> &inputs);

    // Streams every chunk once, asserting `last` exactly on the final chunk. `strm_kind`/`dest`
    // select host vs card (STRM_HOST + iqrStream, or STRM_CARD + CARD_STREAM).
    void stream_pass(const std::vector<InputChunk> &inputs, uint32_t strm_kind, int64_t dest);

    // Card mode: copy the decoded chunks into one host buffer and migrate it to HBM (LOCAL_OFFLOAD),
    // leaving the caller's original host buffers intact (they still back the value-column output).
    // Returns the staged buffer (its ptr is the card-resident vaddr the passes read).
    std::shared_ptr<libstf::Buffer> stage_to_card(const std::vector<InputChunk> &inputs);
};

} // namespace oasis
