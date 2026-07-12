#include "oasis/iqr_runner.hpp"

#include <coyote/cDefs.hpp>
#include <coyote/cOps.hpp>
#include <libstf/buffer.hpp>
#include <libstf/configuration.hpp>
#include <libstf/util.hpp>

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>

namespace oasis {

IqrRunner::IqrRunner(OasisContext &ctx, bool is_signed, bool auto_window, int64_t bin_min,
                     uint64_t bin_shift, bool use_card)
    : ctx_(ctx),
      iqr_config_(ctx.config<IqrConfig>()),
      is_signed_(is_signed),
      auto_window_(auto_window),
      bin_min_(bin_min),
      bin_shift_(bin_shift),
      use_card_(use_card) {
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

void IqrRunner::stream_pass(const std::vector<InputChunk> &inputs, uint32_t strm_kind, int64_t dest) {
    size_t last = inputs.size() - 1;
    for (size_t i = 0; i < inputs.size(); ++i) {
        bool is_last = (i == last);
        libstf::enqueue_stream_input(ctx_.cthread(), ctx_.tlb_manager(), inputs[i].first,
                                     inputs[i].second, static_cast<libstf::stream_t>(dest), is_last,
                                     strm_kind);
    }
}

std::shared_ptr<libstf::Buffer> IqrRunner::stage_to_card(const std::vector<InputChunk> &inputs) {
    // One contiguous host buffer holding the whole decoded column...
    size_t total = 0;
    for (const auto &c : inputs) {
        total += c.second;
    }
    void *ptr    = nullptr;
    auto  status = ctx_.memory_pool()->allocate(total, &ptr);
    if (!status.ok()) {
        throw std::runtime_error("IqrRunner: card staging allocation failed: " + status.message());
    }
    size_t off = 0;
    for (const auto &c : inputs) {
        std::memcpy(static_cast<std::byte *>(ptr) + off, c.first, c.second);
        off += c.second;
    }

    // ...migrated to HBM. After LOCAL_OFFLOAD the vaddr `ptr` is card-resident, so both passes read
    // it with STRM_CARD (no host round-trip). The caller's original host buffers are untouched and
    // still back the value-column output.
    ctx_.tlb_manager()->ensure_tlb_mapping(ptr, total);
    coyote::syncSg sg;
    sg.addr = ptr;
    sg.len  = total;
    ctx_.cthread()->invoke(coyote::CoyoteOper::LOCAL_OFFLOAD, sg);

    return libstf::make_buffer(ctx_.memory_pool(), ptr, total, total);
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

    // 1b. Choose the input source for the two passes. Card mode stages the decoded column into HBM
    // ONCE (derive_window above already read it on the host, so this must come after) and both passes
    // then read it locally at ~HBM bandwidth instead of re-DMAing it from the host twice. The device
    // mux is switched via the use_card CSR; host mode is the unchanged legacy path.
    std::shared_ptr<libstf::Buffer> card_buf;
    std::vector<InputChunk>         card_inputs;
    const std::vector<InputChunk>  *pass_inputs = &inputs;
    if (use_card_) {
        card_buf    = stage_to_card(inputs);
        card_inputs = {{card_buf->ptr, card_buf->size}};
        pass_inputs = &card_inputs;
    }
    iqr_config_->set_use_card(use_card_);
    const uint32_t strm_kind = use_card_ ? coyote::STRM_CARD : coyote::STRM_HOST;
    const int64_t  dest      = use_card_ ? CARD_STREAM : static_cast<int64_t>(ctx_.iqrStream());

    // 2. Flag output size. The device packs the flags into a dense bitmask (1 bit/element) emitted as
    // full 512-bit (= NUM_TUPLES*64) beats, so the output is ceil(N/512) 64-byte beats -- 64x smaller
    // than an INT64-per-flag column.
    static constexpr size_t FLAG_BITS_PER_BEAT  = 512; // CELERIS_NUM_TUPLES(8) * 64
    static constexpr size_t FLAG_BYTES_PER_BEAT = FLAG_BITS_PER_BEAT / 8; // 64
    size_t out_beats = (result.num_elements + FLAG_BITS_PER_BEAT - 1) / FLAG_BITS_PER_BEAT;
    size_t out_bytes = out_beats * FLAG_BYTES_PER_BEAT;

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

    // 4. Enqueue the flag output buffer BEFORE streaming the input. In oasis, output is FPGA-initiated:
    // the buffer is enqueued to the IQR stream (the reserved stream past the decoders) and the
    // OutputWriter fills it during the FLAG pass, signalling completion via an interrupt that the
    // bypass receiver collects -- so the destination must already be enqueued when the flags emit.
    // (This is the oasis output model, not celeris's host-initiated LOCAL_WRITE.)
    auto handle = ctx_.bypass_receiver().acquire(out_bytes);

    // 5. Two-pass input (LOCAL_READ x2 via enqueue_stream_input): pass 1 builds the histogram, pass 2
    // re-streams the column and the operator emits the packed flags.
    stream_pass(*pass_inputs, strm_kind, dest); // pass 1: HISTOGRAM
    stream_pass(*pass_inputs, strm_kind, dest); // pass 2: FLAG

    // 6. Drain the flag buffer(s) the FPGA wrote. handle->next() blocks on the completion interrupt
    // and returns nullptr once the transfer is fully drained.
    std::vector<std::shared_ptr<libstf::Buffer>> chunks;
    while (auto buffer = handle->next()) {
        chunks.push_back(buffer);
    }

    if (chunks.size() == 1) {
        // Common case (the whole flag column fits one output-writer buffer): hand it back directly.
        result.flags = chunks.front();
    } else {
        // Large column split across buffers: concatenate into one contiguous bitmask for the caller.
        void *ptr    = nullptr;
        auto  status = ctx_.memory_pool()->allocate(out_bytes, &ptr);
        if (!status.ok()) {
            throw std::runtime_error("IqrRunner: failed to allocate flag buffer: " + status.message());
        }
        size_t off = 0;
        for (const auto &c : chunks) {
            std::memcpy(static_cast<std::byte *>(ptr) + off, c->ptr, c->size);
            off += c->size;
        }
        result.flags = libstf::make_buffer(ctx_.memory_pool(), ptr, out_bytes, out_bytes);
    }

    // 7. Debug: read back the histogram grand total (== N iff the banks were zeroed) and the
    // count-loss diagnostics. The host can now see WHERE counts were lost without guessing:
    // num_elements >= accepted >= committed >= histogram_total (input / coalescing / BRAM hazard).
    result.histogram_total = iqr_config_->histogram_total();
    result.accepted        = iqr_config_->accepted();
    result.committed       = iqr_config_->committed();
    result.flushes         = iqr_config_->flushes();
    result.collisions      = iqr_config_->collisions();

    // Stream-utilization breakdown (read now, before the next run's first beat re-zeroes them).
    result.input_profile  = iqr_config_->input_profile();
    result.output_profile = iqr_config_->output_profile();
    return result;
}

} // namespace oasis
