#include "oasis/iqr_runner.hpp"

#include <coyote/cDefs.hpp>
#include <coyote/cOps.hpp>
#include <libstf/buffer.hpp>
#include <libstf/configuration.hpp>
#include <libstf/util.hpp>

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdlib>
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

    // Seek directly to each sampled index instead of walking every element to find it: we want a few
    // thousand values out of (here) 20M, so stepping over the column touches that many cache lines
    // rather than reading all 163 MB through one core. Same indices, same sample, ~8 ms cheaper on
    // taxi_d4. The reads are ~20 KB apart, so each costs a cache miss (~80 ns) -- the sample size is
    // therefore a direct accuracy/latency knob, tunable with OASIS_IQR_SAMPLE for measurement.
    static const size_t sample_target = [] {
        const char *e = std::getenv("OASIS_IQR_SAMPLE");
        if (e) {
            long v = std::strtol(e, nullptr, 10);
            if (v >= 64) {
                return static_cast<size_t>(v);
            }
        }
        return SAMPLE_TARGET;
    }();

    std::vector<int64_t> sample;
    sample.reserve(std::min<size_t>(total, sample_target));
    size_t step = std::max<size_t>(1, total / sample_target);

    size_t chunk_base = 0; // index of the first element of the current chunk
    size_t c          = 0;
    for (size_t idx = 0; idx < total; idx += step) {
        // Advance to the chunk containing `idx` (indices are non-decreasing, so this walks forward).
        while (c < inputs.size() &&
               idx >= chunk_base + inputs[c].second / sizeof(int64_t)) {
            chunk_base += inputs[c].second / sizeof(int64_t);
            ++c;
        }
        if (c >= inputs.size()) {
            break;
        }
        const int64_t *p = reinterpret_cast<const int64_t *>(inputs[c].first);
        sample.push_back(p[idx - chunk_base]);
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

void IqrRunner::clear_histogram_fenced() {
    // Zero the histogram and FENCE the clear ahead of the input DMA. The clear is a posted CSR
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
}

size_t IqrRunner::index_bytes_for(size_t n) {
    // 32 indices per 512-bit beat, padded to a whole beat. The device zero-fills the tail and masks
    // it against hist_expected, so the padding never reaches a flag.
    constexpr size_t IDX_PER_BEAT = 32;
    constexpr size_t BEAT_BYTES   = 64;
    return ((n + IDX_PER_BEAT - 1) / IDX_PER_BEAT) * BEAT_BYTES;
}

std::shared_ptr<libstf::Buffer>
IqrRunner::drain_to_buffer(BypassStreamReceiver::Handle &handle, size_t total_bytes) {
    std::vector<std::shared_ptr<libstf::Buffer>> chunks;
    while (auto buffer = handle.next()) {
        chunks.push_back(buffer);
    }
    if (chunks.empty()) {
        throw std::runtime_error("IqrRunner: transfer drained no buffers");
    }
    if (chunks.size() == 1) {
        return chunks.front();
    }
    void *ptr    = nullptr;
    auto  status = ctx_.memory_pool()->allocate(total_bytes, &ptr);
    if (!status.ok()) {
        throw std::runtime_error("IqrRunner: failed to allocate drain buffer: " + status.message());
    }
    size_t off = 0;
    for (const auto &c : chunks) {
        std::memcpy(static_cast<std::byte *>(ptr) + off, c->ptr, c->size);
        off += c->size;
    }
    return libstf::make_buffer(ctx_.memory_pool(), ptr, total_bytes, total_bytes);
}

// Returns the instant the FPGA finished writing the flags, so callers can close `passes_ms` on the
// drain alone -- the concatenation and CSR read-back below are host book-keeping, not device time.
std::chrono::steady_clock::time_point
IqrRunner::collect_result(Result &result, size_t out_bytes, BypassStreamReceiver::Handle &handle) {
    // Drain the flag buffer(s) the FPGA wrote. next() blocks on the completion interrupt and
    // returns nullptr once the transfer is fully drained.
    result.flags   = drain_to_buffer(handle, out_bytes);
    auto t_drained = std::chrono::steady_clock::now();

    // Debug: the histogram grand total (== N iff the banks were zeroed) and the count-loss
    // diagnostics, so the host can see WHERE counts were lost without guessing:
    // num_elements >= accepted >= committed >= histogram_total (input / coalescing / BRAM hazard).
    result.histogram_total = iqr_config_->histogram_total();
    result.accepted        = iqr_config_->accepted();
    result.committed       = iqr_config_->committed();
    result.flushes         = iqr_config_->flushes();
    result.collisions      = iqr_config_->collisions();

    // Stream-utilization breakdown (read now, before the next run's first beat re-zeroes them).
    result.input_profile  = iqr_config_->input_profile();
    result.output_profile = iqr_config_->output_profile();
    return t_drained;
}

// Flag output size. The device packs the flags into a dense bitmask (1 bit/element) emitted as full
// 512-bit (= NUM_TUPLES*64) beats, so the output is ceil(N/512) 64-byte beats -- 64x smaller than an
// INT64-per-flag column.
static constexpr size_t FLAG_BITS_PER_BEAT  = 512; // CELERIS_NUM_TUPLES(8) * 64
static constexpr size_t FLAG_BYTES_PER_BEAT = FLAG_BITS_PER_BEAT / 8; // 64

static size_t flag_bytes_for(size_t num_elements) {
    size_t beats = (num_elements + FLAG_BITS_PER_BEAT - 1) / FLAG_BITS_PER_BEAT;
    return beats * FLAG_BYTES_PER_BEAT;
}

void IqrRunner::begin_fused(int64_t bin_min, uint64_t bin_shift, size_t expected_elements) {
    if (use_card_) {
        throw std::runtime_error("IqrRunner: begin_fused() is not supported with use_card");
    }
    bin_min_   = bin_min;
    bin_shift_ = bin_shift;
    iqr_config_->set_bin_min(bin_min_);
    iqr_config_->set_bin_shift(bin_shift_);
    iqr_config_->set_use_card(false);

    // Order matters: the element count and the enable must be in place BEFORE the clear pulse,
    // because that same pulse re-arms the feed's element counter on the device.
    iqr_config_->set_hist_expected(expected_elements);
    iqr_config_->set_fuse_enable(true);

    // Step 2: arm the index receive BEFORE the clear/pass 1. The device starts emitting index beats
    // with the first HISTOGRAM beat, so a handle acquired later would miss them.
    iqr_config_->set_idx_mode(idx_mode_);
    if (idx_mode_) {
        idx_bytes_  = index_bytes_for(expected_elements);
        idx_handle_ = ctx_.bypass_receiver().acquire(idx_bytes_);
    }

    clear_histogram_fenced();
    fused_ = true;
}

IqrRunner::Result IqrRunner::finish_fused(const std::vector<InputChunk> &inputs) {
    if (!fused_) {
        throw std::runtime_error("IqrRunner: finish_fused() called before begin_fused()");
    }
    fused_ = false;

    Result result;
    result.num_elements = count_elements(inputs);
    result.bin_min      = bin_min_;
    result.bin_shift    = bin_shift_;
    if (result.num_elements == 0) {
        iqr_config_->set_fuse_enable(false);
        return result;
    }

    // Pass 1 ran on-chip during decode. Wait for the feed to have sent its terminating `last`
    // before enqueuing pass 2: the device would back-pressure anyway (the input mux parks the host
    // source while the core is in HISTOGRAM), but polling turns a silent stall into a clear error.
    // Bound this in WALL CLOCK, not spins. Each feed_done() is an MMIO read (~1 us), so a spin
    // budget of 200 M was really a ~200 s timeout -- longer than any sane `timeout` on the query,
    // which meant the process was always killed before it could report WHY. The whole point of
    // polling here is to turn a silent stall into a diagnostic, so the budget has to be short
    // enough to actually be reached: decode is ~90 ms on the largest column we run.
    {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (!iqr_config_->feed_done()) {
            if (std::chrono::steady_clock::now() > deadline) {
                iqr_config_->set_fuse_enable(false);   // unpark the mux before giving up
                throw std::runtime_error(
                    "IqrRunner: fused pass 1 did not complete (fed " +
                    std::to_string(iqr_config_->fed_elements()) + " of " +
                    std::to_string(result.num_elements) + " elements, histogram_total " +
                    std::to_string(iqr_config_->histogram_total()) + ")");
            }
        }
    }

    // Step 2: collect the index array pass 1 produced, and use IT as pass 2's input. The two
    // host-bound streams share one output writer on the device but are disjoint in time (indices
    // during HISTOGRAM, flags during FLAG), so this drain must complete before the flag receive is
    // armed.
    std::vector<InputChunk>         pass2_chunks = inputs;
    std::shared_ptr<libstf::Buffer> idx_buffer;
    if (idx_mode_) {
        // FENCE THE DRAIN BEHIND AN OBSERVABLE COUNT. BypassStreamReceiver::Handle::next() waits on
        // a condition variable with no timeout, so if the device emitted fewer index beats than the
        // host armed for, the query hangs with nothing printed -- the same failure shape as the
        // build-15 arbiter bug, where the diagnostic existed but could never be reached. Poll the
        // device's own beat counter first, bounded in WALL CLOCK, so a shortfall is a readable error.
        const uint64_t want_beats = idx_bytes_ / 64;
        const auto     deadline   = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (iqr_config_->index_beats() < want_beats) {
            if (std::chrono::steady_clock::now() > deadline) {
                iqr_config_->set_fuse_enable(false);
                iqr_config_->set_idx_mode(false);
                throw std::runtime_error(
                    "IqrRunner: index stream incomplete (" +
                    std::to_string(iqr_config_->index_beats()) + " of " +
                    std::to_string(want_beats) + " beats for " +
                    std::to_string(result.num_elements) + " elements; histogram_total " +
                    std::to_string(iqr_config_->histogram_total()) +
                    "). Is idx_mode supported by this bitstream?");
            }
        }
        idx_buffer = drain_to_buffer(*idx_handle_, idx_bytes_);
        idx_handle_.reset();
        pass2_chunks.assign(1, InputChunk {idx_buffer->ptr, idx_bytes_});
    }

    size_t out_bytes = flag_bytes_for(result.num_elements);
    auto   handle    = ctx_.bypass_receiver().acquire(out_bytes);

    auto t_pass0 = std::chrono::steady_clock::now();
    stream_pass(pass2_chunks, coyote::STRM_HOST, static_cast<int64_t>(ctx_.iqrStream())); // pass 2

    auto t_drained   = collect_result(result, out_bytes, *handle);
    result.passes_ms = std::chrono::duration<double, std::milli>(t_drained - t_pass0).count();

    iqr_config_->set_fuse_enable(false);   // leave the device on the legacy path
    iqr_config_->set_idx_mode(false);

    // A miscounted pass 1 yields plausible but wrong quartiles, so check rather than trust.
    if (result.histogram_total != result.num_elements) {
        throw std::runtime_error(
            "IqrRunner: fused pass 1 histogram total " + std::to_string(result.histogram_total) +
            " != " + std::to_string(result.num_elements) + " elements");
    }
    return result;
}

void IqrRunner::begin_overlapped(int64_t bin_min, uint64_t bin_shift) {
    if (use_card_) {
        // Card mode stages the whole column before either pass, so there is nothing to overlap.
        throw std::runtime_error("IqrRunner: begin_overlapped() is not supported with use_card");
    }
    // The caller owns the window here (see the header): the runner has not seen a single value yet,
    // so anything it could derive would be a prefix -- the bug in RESULTS.md 9.15.
    bin_min_   = bin_min;
    bin_shift_ = bin_shift;
    iqr_config_->set_bin_min(bin_min_);
    iqr_config_->set_bin_shift(bin_shift_);
    iqr_config_->set_use_card(false);

    clear_histogram_fenced();
    overlapped_ = true;
}

void IqrRunner::feed_pass1(const InputChunk &chunk, bool is_last) {
    if (!overlapped_) {
        throw std::runtime_error("IqrRunner: feed_pass1() called before begin_overlapped()");
    }
    if (chunk.second == 0) {
        return;
    }
    libstf::enqueue_stream_input(ctx_.cthread(), ctx_.tlb_manager(), chunk.first, chunk.second,
                                 static_cast<libstf::stream_t>(ctx_.iqrStream()), is_last,
                                 coyote::STRM_HOST);
}

IqrRunner::Result IqrRunner::finish_overlapped(const std::vector<InputChunk> &inputs) {
    if (!overlapped_) {
        throw std::runtime_error("IqrRunner: finish_overlapped() called before begin_overlapped()");
    }
    overlapped_ = false;

    Result result;
    result.num_elements = count_elements(inputs);
    result.bin_min      = bin_min_;
    result.bin_shift    = bin_shift_;
    if (result.num_elements == 0) {
        return result;
    }

    size_t out_bytes = flag_bytes_for(result.num_elements);

    // The flag destination must be enqueued before the FLAG pass emits. Pass 1 is already in flight
    // but emits nothing, so acquiring here -- after the histogram, before pass 2 -- is in time.
    auto handle = ctx_.bypass_receiver().acquire(out_bytes);

    // Only pass 2 is timed here: pass 1 was overlapped with decode and is accounted to the decode
    // phase, so `passes_ms` is directly comparable to run()'s figure halved.
    auto t_pass0 = std::chrono::steady_clock::now();
    stream_pass(inputs, coyote::STRM_HOST, static_cast<int64_t>(ctx_.iqrStream())); // pass 2: FLAG

    auto t_drained = collect_result(result, out_bytes, *handle);
    result.passes_ms = std::chrono::duration<double, std::milli>(t_drained - t_pass0).count();
    return result;
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
        auto t_stage0 = std::chrono::steady_clock::now();
        card_buf      = stage_to_card(inputs);
        result.stage_ms =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t_stage0)
                .count();
        card_inputs = {{card_buf->ptr, card_buf->size}};
        pass_inputs = &card_inputs;
    }
    iqr_config_->set_use_card(use_card_);
    const uint32_t strm_kind = use_card_ ? coyote::STRM_CARD : coyote::STRM_HOST;
    const int64_t  dest      = use_card_ ? CARD_STREAM : static_cast<int64_t>(ctx_.iqrStream());

    // 2. Flag output size (dense 1-bit-per-element bitmask, whole 512-bit beats).
    size_t out_bytes = flag_bytes_for(result.num_elements);

    // 3. Zero the histogram, fenced ahead of the input DMA.
    clear_histogram_fenced();

    // 4. Enqueue the flag output buffer BEFORE streaming the input. In oasis, output is FPGA-initiated:
    // the buffer is enqueued to the IQR stream (the reserved stream past the decoders) and the
    // OutputWriter fills it during the FLAG pass, signalling completion via an interrupt that the
    // bypass receiver collects -- so the destination must already be enqueued when the flags emit.
    // (This is the oasis output model, not celeris's host-initiated LOCAL_WRITE.)
    auto handle = ctx_.bypass_receiver().acquire(out_bytes);

    // 5. Two-pass input (LOCAL_READ x2 via enqueue_stream_input): pass 1 builds the histogram, pass 2
    // re-streams the column and the operator emits the packed flags. Timed as one block with the
    // drain below: together they are the time the FPGA spends actually reading the column, which is
    // what we compare between the host and card sources.
    auto t_pass0 = std::chrono::steady_clock::now();
    stream_pass(*pass_inputs, strm_kind, dest); // pass 1: HISTOGRAM
    stream_pass(*pass_inputs, strm_kind, dest); // pass 2: FLAG

    // 6. Drain the flags and read back the diagnostics.
    auto t_drained = collect_result(result, out_bytes, *handle);
    result.passes_ms = std::chrono::duration<double, std::milli>(t_drained - t_pass0).count();
    return result;
}

} // namespace oasis
