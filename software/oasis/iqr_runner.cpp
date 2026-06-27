#include "oasis/iqr_runner.hpp"

#include <coyote/cDefs.hpp>
#include <coyote/cOps.hpp>
#include <libstf/buffer.hpp>
#include <libstf/configuration.hpp>
#include <libstf/util.hpp>

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <stdexcept>
#include <thread>

namespace oasis {

IqrRunner::IqrRunner(OasisContext &ctx, bool is_signed, bool auto_window, int64_t bin_min,
                     uint64_t bin_shift)
    : ctx_(ctx),
      iqr_config_(ctx.config<IqrConfig>()),
      is_signed_(is_signed),
      auto_window_(auto_window),
      bin_min_(bin_min),
      bin_shift_(bin_shift) {
    // Signedness follows the column type and can be set now. The window (bin_min/bin_shift) is
    // written in run(), after it is (optionally) derived from the data.
    iqr_config_->set_signed(is_signed_);

    // No StreamConfig: the production IQR lane in vfpga_top.svh reinterprets the incoming bytes as
    // data64 directly (8x64 ndata), so the input type is fixed at 64-bit in hardware.
}

size_t IqrRunner::count_elements(const std::vector<InputChunk> &inputs) {
    size_t total = 0;
    for (const auto &chunk : inputs) {
        total += chunk.second / sizeof(int64_t);
    }
    return total;
}

void IqrRunner::derive_window(const std::vector<InputChunk> &inputs) {
    // Stride-sample the column (cheap; only sizes the bins -- the FPGA still histograms every row).
    // Robust percentiles, not min/max, so a stray outlier cannot blow up the bin width.
    size_t total = count_elements(inputs);
    if (total == 0) {
        bin_min_ = 0;
        bin_shift_ = 0;
        return;
    }

    std::vector<int64_t> sample;
    sample.reserve(std::min<size_t>(total, SAMPLE_TARGET));
    size_t step = std::max<size_t>(1, total / SAMPLE_TARGET);
    size_t idx = 0, next = 0;
    for (const auto &chunk : inputs) {
        const int64_t *p = reinterpret_cast<const int64_t *>(chunk.first);
        size_t n = chunk.second / sizeof(int64_t);
        for (size_t i = 0; i < n; ++i, ++idx) {
            if (idx == next) {
                sample.push_back(p[i]);
                next += step;
            }
        }
    }

    std::sort(sample.begin(), sample.end());
    size_t  m  = sample.size();
    int64_t lo = sample[m * 1 / 100];                   // ~1st percentile
    int64_t hi = sample[std::min(m - 1, m * 99 / 100)]; // ~99th percentile
    int64_t range = hi - lo;

    if (range <= 0) {
        bin_min_ = lo;
        bin_shift_ = 0;
        return;
    }

    // bin width = ceil(range / NUM_BINS), rounded up to a power of two (the HW shifts).
    uint64_t width = static_cast<uint64_t>((range + NUM_BINS - 1) / NUM_BINS);
    uint64_t shift = 0;
    while ((1ull << shift) < width) {
        ++shift;
    }
    int64_t binw = static_cast<int64_t>(1ull << shift);

    // Floor-align the low edge to a bin boundary (correct for negative lo too).
    int64_t aligned = (lo >= 0) ? (lo / binw) * binw : -(((-lo) + binw - 1) / binw) * binw;

    bin_min_ = aligned;
    bin_shift_ = shift;
}

void IqrRunner::stream_pass(const std::vector<InputChunk> &inputs) {
    size_t last = inputs.size() - 1;
    for (size_t i = 0; i < inputs.size(); ++i) {
        bool is_last = (i == last);
        libstf::enqueue_stream_input(ctx_.cthread(), ctx_.tlb_manager(), inputs[i].first,
                                     inputs[i].second, ctx_.iqrStream(), is_last);
    }
}

IqrRunner::Result IqrRunner::run(const std::vector<InputChunk> &inputs) {
    Result result;
    result.num_elements = count_elements(inputs);
    if (inputs.empty() || result.num_elements == 0) {
        // Nothing to flag. Leave result.flags null; the caller treats this as an empty column.
        return result;
    }

    // 1. Decide and push the histogram window.
    if (auto_window_) {
        derive_window(inputs); // sets bin_min_/bin_shift_
    }
    iqr_config_->set_bin_min(bin_min_);
    iqr_config_->set_bin_shift(bin_shift_);
    result.bin_min = bin_min_;
    result.bin_shift = bin_shift_;

    // 2. Allocate the packed flag (output) buffer. The device packs the flags into a dense bitmask
    // (1 bit/element) emitted as full 512-bit (= NUM_TUPLES*64) beats, so the output is
    // ceil(N/512) 64-byte beats -- 64x smaller than an INT64-per-flag column.
    static constexpr size_t FLAG_BITS_PER_BEAT  = 512; // CELERIS_NUM_TUPLES(8) * 64
    static constexpr size_t FLAG_BYTES_PER_BEAT = FLAG_BITS_PER_BEAT / 8; // 64
    size_t out_beats = (result.num_elements + FLAG_BITS_PER_BEAT - 1) / FLAG_BITS_PER_BEAT;
    size_t out_bytes = out_beats * FLAG_BYTES_PER_BEAT;

    void *out_ptr = nullptr;
    auto  status  = ctx_.memory_pool()->allocate(out_bytes, &out_ptr);
    if (!status.ok()) {
        throw std::runtime_error("IqrRunner: failed to allocate output buffer: " + status.message());
    }
    ctx_.tlb_manager()->ensure_tlb_mapping(out_ptr, out_bytes);
    result.flags = libstf::make_buffer(ctx_.memory_pool(), out_ptr, out_bytes, out_bytes);

    auto cthread = ctx_.cthread();

    // 3. Zero the histogram and FENCE the clear ahead of the input DMA. The clear is a posted CSR
    // write on the control plane; the input DMA travels the data plane with no mutual ordering. If
    // pass-1 beats reach the core before the clear does, they get binned then wiped -> lost counts.
    // The device exposes a clear-completion counter that advances when a sweep finishes: capture it,
    // pulse clear, then spin until it advances -- at which point the banks are zero AND the core is
    // idle-ready, so the subsequent DMA cannot lose beats. (Spin is ~tens of us, negligible.)
    uint64_t clr_seq0 = iqr_config_->clear_seq();
    iqr_config_->clear_histogram();
    for (uint64_t spins = 0; iqr_config_->clear_seq() == clr_seq0; ++spins) {
        if (spins > 100000000ull) {
            throw std::runtime_error("IqrRunner: timed out waiting for histogram clear to complete");
        }
    }

    // 4. Two-pass input (LOCAL_READ x2 via enqueue_stream_input) + one host-initiated LOCAL_WRITE
    // that captures the FLAG output. The FPGA only drives axis_host_send during pass 2 (FLAG), so the
    // LOCAL_WRITE collects exactly the N packed flags. The write is chunked to MAX_TRANSFER_SIZE.
    stream_pass(inputs); // pass 1: HISTOGRAM
    stream_pass(inputs); // pass 2: FLAG (input)

    size_t     n_writes = 0;
    std::byte *obp      = static_cast<std::byte *>(out_ptr);
    for (size_t off = 0; off < out_bytes; off += coyote::MAX_TRANSFER_SIZE) {
        coyote::localSg sg;
        sg.addr   = obp + off;
        sg.len    = static_cast<uint32_t>(std::min<size_t>(out_bytes - off, coyote::MAX_TRANSFER_SIZE));
        sg.stream = coyote::STRM_HOST;
        sg.dest   = ctx_.iqrStream(); // flags come back on the IQR lane's output
        bool last_w = (off + coyote::MAX_TRANSFER_SIZE >= out_bytes);
        cthread->invoke(coyote::CoyoteOper::LOCAL_WRITE, sg, last_w);
        ++n_writes;
    }

    // 5. Poll until the FPGA has written the whole flag column (writes completing implies pass 2
    // finished).
    while (cthread->checkCompleted(coyote::CoyoteOper::LOCAL_WRITE) < n_writes) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(50));
    }
    cthread->clearCompleted();

    // 6. Debug: read back the histogram grand total (== N iff the banks were zeroed).
    result.histogram_total = iqr_config_->histogram_total();
    return result;
}

} // namespace oasis
