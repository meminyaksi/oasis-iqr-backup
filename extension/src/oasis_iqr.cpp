#include "oasis_iqr.hpp"

#include "coalesced_fetcher.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/parallel/task_scheduler.hpp"
#include "oasis/iqr_runner.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/configuration.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parcore_metadata_util.hpp"
#include "parquet_reader.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

namespace duckdb {

// ---------------------------------------------------------------------------------------------
// iqr_flags(path VARCHAR, column VARCHAR)
//
// A *pipeline-breaking* table function (like ORDER BY / a global aggregate): the IQR operator needs
// the whole column before it can flag any row (the quartiles are global), so the work is done once,
// up front, and the results are then streamed out as (value, is_outlier) rows.
//
// M2a (this file): the SQL surface -- bind/schema, registration, and the emit + bitmask-unpack loop.
// The heavy phase (decode the column across all row groups + run the IQR two passes) is the seam
// filled in M2b; for now it throws so the function still binds and is visible in DuckDB.
// ---------------------------------------------------------------------------------------------

namespace {

struct IqrFlagsBindData : public TableFunctionData {
    string      filename;
    string      column_name;
    idx_t       column_id = DConstants::INVALID_INDEX; // index of the target column in the file
    LogicalType column_type;                           // its type (must be a 64-bit integer)
    bool        is_signed = true;                      // BIGINT -> signed, UBIGINT -> unsigned

    // Parsed footer, captured at bind time. The CPU path builds one ParquetReader per worker and
    // hands each this cache so the footer is parsed once, not once per thread.
    shared_ptr<ParquetFileMetadataCache> parquet_metadata;

    // iqr_flags echoes the value column back, so it needs the decoded column gathered contiguously.
    // iqr_flags_only emits just the bitmask and therefore never has to see the values at all, which
    // is what makes the streaming path below legal for it.
    bool needs_values = true;
};

// Global state shared across DuckDB workers. iqr_flags is a pipeline breaker: the heavy phase (decode
// + the IQR passes) runs once, in InitGlobal, before any worker starts. *Emission* is then embarrassingly
// parallel -- `values` and `flags` are fully materialized, read-only, and every row is independent --
// so workers claim disjoint STANDARD_VECTOR_SIZE slices off an atomic cursor. Emitting serially
// (the old MaxThreads == 1) cost 81 ms of the 144 ms taxi_d4 query, more than the FPGA work itself.
struct IqrFlagsGlobalState : public GlobalTableFunctionState {
    std::shared_ptr<libstf::Buffer> values; // decoded int64 column (N elements), for the value output
    std::shared_ptr<libstf::Buffer> flags;  // packed outlier bitmask (1 bit/element)
    size_t                          num_elements = 0;
    std::atomic<size_t>             cursor {0}; // next element to claim

    // DuckDB clamps parallelism to min(MaxThreads(), scheduler threads). One worker per output chunk.
    idx_t MaxThreads() const override {
        return MaxValue<idx_t>(1, (num_elements + STANDARD_VECTOR_SIZE - 1) / STANDARD_VECTOR_SIZE);
    }
};

// No per-worker state: emission reads only the shared, immutable `values`/`flags` buffers.
struct IqrFlagsLocalState : public LocalTableFunctionState {};

// Wraps one fetched compressed column-chunk slice as a LocalSourceOperator. Copies the bytes into a
// fresh memory-pool buffer (the simple, always-correct path; the zero-copy aligned-slice path in
// oasis_scan.cpp is an optimization we can adopt later).
std::unique_ptr<oasis::SourceOperator> MakeHostSourceCopy(oasis::OasisContext &ctx,
                                                          const CoalescedFetcher::RangeView &view) {
    void *ptr = nullptr;
    auto  st  = ctx.memory_pool()->allocate(view.size, &ptr);
    if (!st.ok()) {
        throw IOException("iqr_flags: could not allocate input buffer: " + st.message());
    }
    std::memcpy(ptr, view.data(), view.size);
    auto buffer = libstf::make_buffer(ctx.memory_pool(), ptr, view.size, view.size);
    return std::make_unique<oasis::LocalSourceOperator>(std::move(buffer));
}

// How many row groups to keep in flight on the decoder(s). Must be at least (decoder lanes x
// scheduler pipeline depth) to keep every lane fed; larger costs memory (one sink buffer per group
// in flight) and buys nothing. OASIS_IQR_DECODE_WINDOW=1 restores the old submit-and-block shape,
// which is useful for measuring what the pipelining is worth.
size_t decode_window() {
    static const size_t window = [] {
        const char *env = std::getenv("OASIS_IQR_DECODE_WINDOW");
        if (env) {
            long v = std::strtol(env, nullptr, 10);
            if (v >= 1) {
                return static_cast<size_t>(v);
            }
        }
        return static_cast<size_t>(8);
    }();
    return window;
}

// A non-owning view of `[off, off+size)` inside `owner`. The FPGA can write straight into it, so a
// row group's decoded values land in their final place in the column buffer with no copy. The
// deleter frees only the Buffer struct and keeps `owner` alive for as long as any slice of it is.
std::shared_ptr<libstf::Buffer> MakeSlice(const std::shared_ptr<libstf::Buffer> &owner, size_t off,
                                          size_t size, size_t capacity) {
    auto *view = new libstf::Buffer {static_cast<std::byte *>(owner->ptr) + off, size, capacity};
    return std::shared_ptr<libstf::Buffer>(view, [owner](libstf::Buffer *p) { delete p; });
}

size_t RoundUpToTransfer(size_t bytes) {
    const size_t unit = libstf::BYTES_PER_FPGA_TRANSFER;
    return ((std::max<size_t>(bytes, 1) + unit - 1) / unit) * unit;
}

// Wall-clock phase breakdown, printed to stderr when OASIS_IQR_TIMING=1. Wall clock only: the FPGA's
// StreamProfiler counters accumulate for the life of the bitstream and cannot time a single query.
bool timing_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_TIMING");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

using TimingClock = std::chrono::steady_clock;
double ms_since(TimingClock::time_point t) {
    return std::chrono::duration<double, std::milli>(TimingClock::now() - t).count();
}

// Where the decode phase's wall clock goes. `wait` is the only part the FPGA controls: it is time
// spent blocked on a row group the decoder has not finished. Everything else is host work that the
// pipelining is meant to hide behind it.
struct DecodeTiming {
    double fetch_ms  = 0.0; // read compressed bytes (page cache) into a pooled buffer
    double submit_ms = 0.0; // build the flow, allocate the sink, hand it to the scheduler
    double wait_ms   = 0.0; // blocked on the FPGA finishing a row group
    double copy_ms   = 0.0; // memcpy decoded values into the column buffer (0 on the zero-copy path)
    size_t groups    = 0;
    bool   zero_copy = false;
    bool   streamed  = false; // handed the per-group buffers to IqrRunner instead of gathering them
};

// OASIS_IQR_STREAM=1 passes the per-row-group decoded buffers straight to IqrRunner instead of
// gathering them into one contiguous column, removing the host memcpy entirely.
//
// This is legal because IqrRunner::run() already takes a *vector* of chunks and concatenates them
// logically, asserting `last` only on the final one -- the gather was never a device requirement,
// only a convenience. It is off by default because the first attempt (measured on the 1-decoder
// build-11) was a wash: the copy saving was cancelled by ~27 ms of extra decode wait from holding
// every sink buffer to the end. With more decoder lanes the decode-side penalty shrinks while the
// copy saving does not, so the trade-off is worth re-measuring per bitstream.
bool stream_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_STREAM");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

// OASIS_IQR_OVERLAP=1 drives the IQR histogram (pass 1) DURING decode instead of after it, so that
// heavy = max(decode, pass1) + pass2 rather than decode + pass1 + pass2. Requires the streaming path
// (the per-group buffers must survive to be re-streamed for pass 2) and is therefore implied to be
// off whenever OASIS_IQR_STREAM is off.
//
// The bins must be fixed before the first pass-1 beat, so the window comes from DeriveWindowSpanning()
// (a host-side sample across uniformly-spaced row groups) rather than from the decoded column. The
// first implementation derived it from a PREFIX instead and was catastrophically wrong on
// order-dependent data -- 19,997,999 of 20,000,000 rows flagged against a true answer of 200. See
// RESULTS.md 9.15, and re-run bench/overlap_ab.sh accuracy after touching any of this.
// OASIS_IQR_FUSE=1 arms the RTL to feed the histogram straight from the decoder output, so pass 1
// costs no PCIe traffic and no host time at all. Needs a bitstream with IqrHistogramFeed (build-15
// onwards); on an older bitstream the fuse CSRs are ignored and pass 1 would never terminate, so the
// runner's histogram_total check catches it rather than silently returning wrong flags.
// Unlike OASIS_IQR_OVERLAP this does NOT require the streaming sink -- the tee is in hardware.
bool fuse_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_FUSE");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

bool overlap_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_OVERLAP");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

// Callback invoked by DecodeColumnAllGroups on the streaming path: once with the total element count
// before any group decodes, then once per decoded chunk in column order. Lets the caller feed the
// IQR histogram pass while the remaining groups are still decoding.
struct DecodeHooks {
    // (total_elements, streaming): `streaming` is the FINAL per-file sink decision, not the env
    // var. The software overlap needs the streaming sink and must bail when it is false, or it
    // would arm pass 1 and then wait forever for chunks that are never fed.
    std::function<void(size_t total_elements, bool streaming)>                on_start;
    std::function<void(const std::shared_ptr<libstf::Buffer> &, size_t, bool)> on_chunk;
};

// Number of histogram bins baked into the bitstream. Must match IqrRunner::NUM_BINS and the vFPGA
// top's IQR_NUM_BINS -- the window is only meaningful relative to it.
constexpr int64_t IQR_HW_NUM_BINS = 1024;

// Defined below; declared here for DeriveWindowSpanning.
template <typename F>
void ParallelRanges(size_t n, size_t nthreads, F &&fn);

// How many row groups the window sample spans. Measured on build-16 (2026-07-23):
//
//   groups | win_derive (sf10) | taxi_d3 fpga_vs_cpp
//       16 |            8.68ms | 31791   <- WRONG: 1296479 of 1328270 outliers found
//       48 |           19.21ms |   162   <- exactly the full-column-derive baseline
//
// 48 costs ~10.5 ms on sf10 (heavy 140.65 -> 149.60, still -12% vs the 169.6 unfused baseline) and
// buys a correct answer on taxi_d3. A wrong answer is not worth 10 ms, so accuracy wins.
// Do NOT lower this: 16 loses taxi_d3, and 8 regresses taxi_d1 to 1348 (§9.15.1).
size_t window_groups() {
    static const size_t k = [] {
        const char *e = std::getenv("OASIS_IQR_WINDOW_GROUPS");
        if (e) {
            long v = std::strtol(e, nullptr, 10);
            if (v > 0) {
                return static_cast<size_t>(v);
            }
        }
        return static_cast<size_t>(48);
    }();
    return k;
}

// Row count below which fusing pass 1 is a NET LOSS, so the legacy path is used instead.
//
// Fusion deletes pass 1, worth ~0.64 ms per million rows (8 bytes/row at the measured 12.5 GB/s).
// But the histogram window must be sized BEFORE the first beat, and that sample is a roughly FIXED
// cost (~9-19 ms). Below the break-even the window costs more than the pass it saves. Measured
// end-to-end ratios, build-16, fused+FPGA window vs the same bitstream unfused:
//
//   taxi_d1   3.0M   1.67x -> 1.27x   LOST    (saved ~2 ms, paid ~9)
//   extprice  6.0M   1.00x -> 0.86x   LOST    (saved ~4 ms, paid ~9)
//   taxi_d3  13.1M   0.82x -> 0.86x   won
//   taxi_d4  20.3M   0.78x -> 0.90x   won
//   sf10     60.0M   0.85x -> 1.06x   won
//
// This is the same fixed-cost-vs-scaling-benefit arithmetic that keeps OASIS_IQR_OVERLAP off
// (§9.15.1). 10M sits in the measured gap between extprice (lost) and taxi_d3 (won).
size_t fuse_min_rows() {
    static const size_t n = [] {
        const char *e = std::getenv("OASIS_IQR_FUSE_MIN_ROWS");
        if (e) {
            long long v = std::strtoll(e, nullptr, 10);
            if (v >= 0) {
                return static_cast<size_t>(v);
            }
        }
        return static_cast<size_t>(10000000);
    }();
    return n;
}

// OASIS_IQR_WINDOW_FPGA=1 takes the window sample from the FPGA decoder instead of decompressing it
// on the host. See DeriveWindowFromFpga() for why that is worth doing. Off by default so the fused
// bitstream can be validated against the window path that is already trusted.
bool window_fpga_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_WINDOW_FPGA");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

// The one place the (sample -> bin_min, bin_shift) rule lives. Both window derivations feed it, so
// they cannot drift apart: whichever way the sample was collected, identical values must produce an
// identical window. Same rule as IqrRunner::derive_window -- robust percentiles, NOT min/max, so a
// stray outlier cannot blow up the bin width (footer min/max was tried and is degenerate: taxi_d4
// spans -128540..33407632, which makes 1024 bins 32768 wide while the fares live in 0..5000).
// Consumes `sample` (sorts it in place). Returns false if there is nothing usable to measure.
bool WindowFromSample(std::vector<int64_t> &sample, int64_t &bin_min_out, uint64_t &bin_shift_out) {
    if (sample.size() < 2) {
        return false;
    }
    std::sort(sample.begin(), sample.end());
    const size_t  m     = sample.size();
    const int64_t lo    = sample[m * 1 / 100];
    const int64_t hi    = sample[std::min(m - 1, m * 99 / 100)];
    const int64_t range = hi - lo;
    if (range <= 0) {
        bin_min_out   = lo;
        bin_shift_out = 0;
        return true;
    }

    uint64_t width = static_cast<uint64_t>((range + IQR_HW_NUM_BINS - 1) / IQR_HW_NUM_BINS);
    uint64_t shift = 0;
    while ((1ull << shift) < width) {
        ++shift;
    }
    const int64_t binw = static_cast<int64_t>(1ull << shift);

    // Floor-align the low edge to a bin boundary (correct for negative lo too).
    bin_min_out   = (lo >= 0) ? (lo / binw) * binw : -(((-lo) + binw - 1) / binw) * binw;
    bin_shift_out = shift;
    return true;
}

// Derives the histogram window (bin_min, bin_shift) WITHOUT the decoded column in hand, so pass 1 can
// be started before decode finishes. Returns false if no usable sample could be taken, in which case
// the caller must fall back to the serial path.
//
// WHY THIS SHAPE. Three cheaper sources were tried or considered and all fail:
//   * a PREFIX of the decoded column -- measured, and catastrophic: on order-drifting data the bins
//     span only the early range, everything later clamps into the top bin, Q3 collapses and the
//     fences flag 19,997,999 of 20,000,000 rows (RESULTS.md 9.15).
//   * parquet footer min/max -- present on every row group of every dataset here, but NOT robust:
//     taxi_d4 spans -128540..33407632, so 1024 bins are 32768 wide while the fares themselves live
//     in 0..5000. Every value lands in bin 0 => q1 == q3 => IQR 0 => degenerate fences.
//   * a percentile over the per-group footer min/max -- no better, because outliers are spread
//     across essentially every row group (taxi_d4 is 10 % outliers), so every group's max is extreme.
// What is actually needed is real values drawn from ACROSS the file. Reading the first DataChunk of
// a handful of uniformly-spaced row groups costs a few ms of host CPU, spans the column by
// construction, and feeds the same robust p1/p99 rule IqrRunner::derive_window already uses.
bool DeriveWindowSpanning(ClientContext &context, const IqrFlagsBindData &bind, int64_t &bin_min_out,
                          uint64_t &bin_shift_out) {
    const size_t k_groups = window_groups();

    ParquetOptions parquet_opts(context);
    ParquetReader  probe(context, OpenFileInfo {bind.filename}, parquet_opts, bind.parquet_metadata);
    auto           meta = BuildParcoreMetadata(probe);

    std::vector<size_t> live;
    for (size_t g = 0; g < meta.groups.size(); g++) {
        if (meta.groups[g].chunks[bind.column_id].num_values > 0) {
            live.push_back(g);
        }
    }
    if (live.empty()) {
        return false;
    }

    // Uniformly spaced groups, always including the first and last: drift is monotonic in row order,
    // so the extremes of the file are exactly the points a prefix sample misses.
    const size_t        k = std::min(k_groups, live.size());
    std::vector<size_t> picks;
    picks.reserve(k);
    for (size_t i = 0; i < k; i++) {
        picks.push_back(live[(k == 1) ? 0 : (i * (live.size() - 1)) / (k - 1)]);
    }
    picks.erase(std::unique(picks.begin(), picks.end()), picks.end());

    // The groups are sampled in PARALLEL. Serially this cost 51.6 ms on sf10 (3.2 ms per group --
    // pulling one DataChunk still forces a full page decompress), which is MORE than the ~38 ms the
    // overlap saves, and made `heavy` worse than the serial path. The picks are independent, so this
    // is embarrassingly parallel.
    const size_t nworkers =
        std::min<size_t>(picks.size(), std::max<unsigned>(1, std::thread::hardware_concurrency()));
    std::vector<std::vector<int64_t>> parts(nworkers);

    ParallelRanges(picks.size(), nworkers, [&](size_t t, size_t a, size_t b) {
        auto &part = parts[t];
        for (size_t i = a; i < b; i++) {
            ParquetOptions opts(context);
            ParquetReader  reader(context, OpenFileInfo {bind.filename}, opts, probe.metadata);
            // Both lists in lockstep: InitializeScan builds readers from `column_indexes`, Schedule()
            // walks `column_ids` to decide what to fetch. Setting only one yields empty rows.
            reader.column_ids.push_back(MultiFileLocalColumnId(bind.column_id));
            reader.column_indexes.emplace_back(bind.column_id);

            ParquetReaderScanState state;
            reader.InitializeScan(context, state, {static_cast<idx_t>(picks[i])});

            DataChunk chunk;
            chunk.Initialize(Allocator::Get(context), {bind.column_type});
            chunk.Reset();
            auto res = reader.Scan(context, state, chunk);
            while (res.GetResultType() == AsyncResultType::BLOCKED) {
                res.ExecuteTasksSynchronously();
                res = reader.Scan(context, state, chunk);
            }
            // One DataChunk per group is enough: k groups x STANDARD_VECTOR_SIZE is tens of thousands
            // of values, far more than the ~8192 the serial path samples, and it stops after the
            // group's first page rather than decoding the whole group.
            if (chunk.size() == 0) {
                continue;
            }
            auto &vec = chunk.data[0];
            vec.Flatten();
            const int64_t *p = FlatVector::GetData<int64_t>(vec);
            part.insert(part.end(), p, p + chunk.size());
        }
    });

    std::vector<int64_t> sample;
    for (auto &part : parts) {
        sample.insert(sample.end(), part.begin(), part.end());
    }
    return WindowFromSample(sample, bin_min_out, bin_shift_out);
}

// Total non-null values in the target column, read from the CACHED FOOTER -- no decoding, no page
// reads. Needed before decode starts, because whether to fuse depends on the row count (see
// fuse_min_rows) and the window sample must not be taken if we are not going to fuse.
size_t ColumnRowCountFromFooter(ClientContext &context, const IqrFlagsBindData &bind) {
    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {bind.filename}, parquet_opts, bind.parquet_metadata);
    auto           meta  = BuildParcoreMetadata(reader);
    size_t         total = 0;
    for (const auto &g : meta.groups) {
        total += g.chunks[bind.column_id].num_values;
    }
    return total;
}

// Derives the histogram window from a sample decoded BY THE FPGA, so the host never decompresses
// anything twice.
//
// WHY. DeriveWindowSpanning() pulls one DataChunk (2048 rows) from each of 16 spanning row groups on
// the HOST. That sounds cheap -- 0.05 % of sf10 -- but you cannot decode 2048 rows out of a
// compressed Parquet page: reading any row forces a full page decompress. So it costs ~3.2 ms per
// group, ~51 ms of host CPU, parallelised down to ~18 ms of wall clock. And every one of those pages
// is decompressed AGAIN by the FPGA moments later as part of the real decode. It is pure duplicated
// work, and it lands on the metric this study leads with: §9.15.1 measured host CPU-work on
// tpch_extprice falling 3.70x -> 1.91x once the window was enabled.
//
// So: decode the 16 spanning groups on the FPGA (fuse off, since the bins do not exist yet), sample
// their output, derive the window, and let the caller then decode the WHOLE column with the bins
// already set. The sampled groups therefore decode twice, ~3 ms of FPGA time. That is deliberate.
// The alternative -- keeping their decoded values and replaying them into the (idle) iqr_host_in
// port so nothing decodes twice -- saves ~1.7 ms but requires flipping fuse_enable in the middle of
// the HISTOGRAM state, i.e. a posted CSR write with no ordering against in-flight data. That is the
// same hazard class that already forced the histogram-clear fence, and it is not worth 1.7 ms.
//
// The sample must SPAN the column. Taking it from whichever groups decode first is the prefix window,
// which flagged 19,997,999 of 20,000,000 rows against a true answer of 200 (RESULTS.md 9.15).
//
// Returns false if no usable sample could be taken; the caller must then fall back.
bool DeriveWindowFromFpga(ClientContext &context, oasis::OasisContext &ctx,
                          const IqrFlagsBindData &bind, int64_t &bin_min_out,
                          uint64_t &bin_shift_out) {
    auto &fs          = FileSystem::GetFileSystem(context);
    auto  file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);

    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {bind.filename}, parquet_opts, bind.parquet_metadata);
    auto           meta = BuildParcoreMetadata(reader);

    const size_t col = bind.column_id;

    std::vector<size_t> live;
    for (size_t gi = 0; gi < meta.groups.size(); gi++) {
        if (meta.groups[gi].chunks[col].num_values > 0) {
            live.push_back(gi);
        }
    }
    if (live.empty()) {
        return false;
    }

    // Uniformly spaced, first and last always included: drift is monotonic in row order, so the ends
    // of the file are exactly what a prefix sample misses.
    const size_t        k = std::min(window_groups(), live.size());
    std::vector<size_t> picks;
    picks.reserve(k);
    for (size_t i = 0; i < k; i++) {
        picks.push_back(live[(k == 1) ? 0 : (i * (live.size() - 1)) / (k - 1)]);
    }
    picks.erase(std::unique(picks.begin(), picks.end()), picks.end());

    // STRIDE-SAMPLE, do not keep everything. The FPGA decodes whole row groups, so these picks yield
    // ~2 M values on sf10 -- and std::sort on 2 M int64 costs ~100 ms, which would swallow the entire
    // saving. ~2048 per group matches what the host path sampled and is far more than the ~8192 the
    // serial derive_window() uses.
    constexpr size_t PER_GROUP_SAMPLE = 2048;

    struct InFlight {
        oasis::SplinterResultHandle result;
        size_t                      num_values;
        size_t                      gi;
    };
    std::deque<InFlight> in_flight;
    std::vector<int64_t> sample;
    sample.reserve(picks.size() * PER_GROUP_SAMPLE);

    auto drain_one = [&]() {
        InFlight g = std::move(in_flight.front());
        in_flight.pop_front();
        auto batch = g.result.get_next_batch();
        if (!batch) {
            throw InternalException("iqr_flags: window decode of row group %llu produced no output",
                                    (unsigned long long)g.gi);
        }
        const int64_t *p      = static_cast<const int64_t *>(batch->buffer->ptr);
        const size_t   stride = std::max<size_t>(1, g.num_values / PER_GROUP_SAMPLE);
        for (size_t i = 0; i < g.num_values; i += stride) {
            sample.push_back(p[i]);
        }
    };

    const size_t depth = decode_window();
    for (size_t gi : picks) {
        const auto &group = meta.groups[gi];
        const auto &cc    = group.chunks[col];
        auto        type  = parcore::metadata::to_libstf_type(cc.type);

        uint64_t span_begin = std::numeric_limits<uint64_t>::max();
        uint64_t span_end   = 0;
        for (const auto &c : group.chunks) {
            span_begin = std::min<uint64_t>(span_begin, c.offset);
            span_end   = std::max<uint64_t>(span_end, c.offset + c.total_compressed_size);
        }
        CoalescedFetcher fetcher(*file_handle, ctx.memory_pool(),
                                 {span_begin, span_end - span_begin});
        auto handle = fetcher.Register(cc.offset, cc.total_compressed_size);
        fetcher.PrepareReads();
        for (size_t i = 0; i < fetcher.num_reads(); i++) {
            fetcher.ExecuteMergedRead(i);
        }

        oasis::QuerySplinter splinter;
        oasis::OperatorFlow  flow;
        flow.push_back(MakeHostSourceCopy(ctx, fetcher.Resolve(handle)));
        flow.push_back(
            std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
        flow.push_back(std::make_unique<oasis::LocalSinkOperator>(
            ctx.allocate_output_buffer(cc.num_values * libstf::size_of(type)), gi));
        splinter.streams.push_back(std::move(flow));

        in_flight.push_back({ctx.scheduler().submit(std::move(splinter)), cc.num_values, gi});
        if (in_flight.size() >= depth) {
            drain_one();
        }
    }
    while (!in_flight.empty()) {
        drain_one();
    }

    return WindowFromSample(sample, bin_min_out, bin_shift_out);
}

// Decodes the target column across every row group via the ParCore decoder into one contiguous host
// buffer (DMA-mapped, so IqrRunner can stream it). Each group is one QuerySplinter
// (source -> decode -> sink); the scheduler dispatches them asynchronously across the decoder lanes
// and we keep `decode_window()` of them in flight.
//
// Where each group's sink lives decides whether we pay a copy:
//   zero-copy  -- the sink IS the group's slice of the column buffer, so the FPGA DMAs the decoded
//                 values straight into their final position. Needs every non-final group to be a
//                 whole number of 64 KB FPGA transfers (DuckDB's 122,880-row groups are exactly 15),
//                 so that the next group starts on a transfer boundary.
//   fallback   -- a standalone sink per group, memcpy'd into place. Always correct.
// When `chunks_out` is non-null and the streaming preconditions hold, the decoded per-group buffers
// are appended to it in column order and NO contiguous column is built (the return value is null).
std::shared_ptr<libstf::Buffer> DecodeColumnAllGroups(
    ClientContext &context, oasis::OasisContext &ctx, const IqrFlagsBindData &bind,
    size_t &num_values_out, DecodeTiming &tm,
    std::vector<std::pair<std::shared_ptr<libstf::Buffer>, size_t>> *chunks_out = nullptr,
    DecodeHooks *hooks = nullptr) {
    auto &fs          = FileSystem::GetFileSystem(context);
    auto  file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);

    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {bind.filename}, parquet_opts);
    auto           meta = BuildParcoreMetadata(reader);

    const size_t col = bind.column_id;

    // The non-empty row groups, in order, and the total value count.
    std::vector<size_t> live;
    size_t              total = 0;
    for (size_t gi = 0; gi < meta.groups.size(); gi++) {
        size_t nv = meta.groups[gi].chunks[col].num_values;
        if (nv == 0) {
            continue;
        }
        live.push_back(gi);
        total += nv;
    }
    num_values_out = total;
    if (total == 0) {
        return nullptr;
    }

    // DISABLED -- a slice sink DOES NOT WORK on this hardware, and it hangs, not errors.
    //
    // The FPGA output writer manages each output buffer as a whole *registered allocation*; the
    // decode-completion interrupt routes back to the runner by allocation. A MakeSlice() view into a
    // shared buffer is not a registered allocation, so the interrupt never arrives and the runner
    // blocks forever in get_next_batch(). This is the "one-buffer-per-chunk invariant" that the
    // working scan path documents and obeys (oasis_scan.cpp: each chunk's sink is its own
    // ctx.allocate_output_buffer()). Zero-copy legitimately lives on the SOURCE and the DuckDB-emit
    // side (FlatVector::SetData), never on the sink.
    //
    // The 64 KB-alignment guard below was never the real constraint -- it merely happened to fail on
    // every real (unaligned) parquet and so always fell back to memcpy, hiding the broken path. Feeding
    // it an aligned file exposed the hang. The memcpy is not removable this way; the only legitimate
    // way to drop it is to teach IqrRunner to stream the per-chunk buffers in sequence instead of
    // gathering them into one contiguous column. Do not re-enable slice sinks. See
    // memory/iqr-fpga-beats-duckdb-host-path.md and IQR_HBM_LEARNINGS.md.
    bool zero_copy = false;
    tm.zero_copy = zero_copy;

    // Streaming precondition. FlagBitPacker emits 8 flags per beat, so a chunk that is not a whole
    // number of 8 elements would make the packer insert padding bits *mid-stream* and misalign every
    // flag after it. Only the FINAL chunk may be partial. DuckDB writes 122,880-row groups (a clean
    // multiple of 8) so this normally holds, but taxi files carry odd-sized groups -- hence the check
    // rather than an assumption. Falling back to the memcpy is always correct.
    bool stream = chunks_out && stream_enabled() && !bind.needs_values;
    if (stream) {
        for (size_t i = 0; i + 1 < live.size(); i++) {
            if (meta.groups[live[i]].chunks[col].num_values % 8 != 0) {
                stream = false;
                break;
            }
        }
    }
    tm.streamed = stream;

    // One contiguous int64 destination buffer for the whole column. Allocated through the output-buffer
    // path so its address/capacity satisfy the hardware enqueue rules -- the slices inherit that.
    // Skipped entirely when streaming: the per-group sink buffers ARE the input to the two passes.
    size_t total_bytes = total * sizeof(int64_t);
    auto   values      = stream ? nullptr : ctx.allocate_output_buffer(total_bytes);
    void  *dst         = stream ? nullptr : values->ptr;
    if (!stream) {
        ctx.tlb_manager()->ensure_tlb_mapping(dst, values->capacity);
    }

    // Row groups decode independently, and Scheduler::submit() is asynchronous and load-balances
    // flows across the decoder lanes. So keep a sliding window of groups in flight: the FPGA decodes
    // earlier groups while the host fetches and copies out later ones. Submitting one group and
    // immediately blocking on it left the decoder idle for every fetch, submit and memcpy -- which
    // is most of the wall clock, since decode is ~77% of the query and the lane was stalling inside
    // it. The window bounds peak memory (window x group_size of sink buffers, on top of `values`).
    struct InFlightGroup {
        oasis::SplinterResultHandle result;
        size_t                      off_elems;
        size_t                      num_values;
        size_t                      gi;
    };
    std::deque<InFlightGroup> in_flight;

    // On the fallback path the 166 per-group copies are independent and write to disjoint ranges, so
    // they run on a pool of threads rather than on this one. Serially they cost ~20 ms of a 77 ms
    // query (163 MB at one core's memcpy bandwidth); the FPGA has long since finished by then, so
    // there is nothing to overlap them with -- they have to be made faster, not hidden.
    struct PendingCopy {
        std::shared_ptr<libstf::Buffer> src;
        size_t                          off_elems;
        size_t                          num_values;
    };
    std::vector<PendingCopy> copies;

    auto drain_one = [&]() {
        InFlightGroup g = std::move(in_flight.front());
        in_flight.pop_front();

        auto t0    = TimingClock::now();
        auto batch = g.result.get_next_batch();
        tm.wait_ms += ms_since(t0);
        if (!batch) {
            throw InternalException("iqr_flags: decode of row group %llu produced no output",
                                    (unsigned long long)g.gi);
        }

        // Streaming: keep the sink buffer itself as one input chunk. drain_one pops the FIFO front,
        // which is submission (row-group) order, so the chunks stay in column order.
        if (stream) {
            size_t bytes = g.num_values * sizeof(int64_t);
            chunks_out->emplace_back(batch->buffer, bytes);
            if (hooks && hooks->on_chunk) {
                // Column order is guaranteed by the FIFO pop above, which the histogram does not
                // strictly need but pass 2 does -- and both read this same chunk list.
                hooks->on_chunk(batch->buffer, bytes, chunks_out->size() == live.size());
            }
        } else if (!zero_copy) {
            // zero-copy: the sink WAS the column slice, so the values are already in place.
            copies.push_back({batch->buffer, g.off_elems, g.num_values});
        }
    };

    auto run_copies = [&]() {
        if (copies.empty()) {
            return;
        }
        auto   t0        = TimingClock::now();
        size_t n_threads = std::min<size_t>(copies.size(),
                                            std::max<unsigned>(1, std::thread::hardware_concurrency()));
        std::atomic<size_t>      next {0};
        std::vector<std::thread> workers;
        workers.reserve(n_threads);
        for (size_t t = 0; t < n_threads; t++) {
            workers.emplace_back([&] {
                for (size_t i = next.fetch_add(1); i < copies.size(); i = next.fetch_add(1)) {
                    const auto &c = copies[i];
                    std::memcpy(static_cast<int64_t *>(dst) + c.off_elems, c.src->ptr,
                                c.num_values * sizeof(int64_t));
                }
            });
        }
        for (auto &w : workers) {
            w.join();
        }
        copies.clear(); // releases the sink buffers back to the pool
        tm.copy_ms += ms_since(t0);
    };

    // Flush the copies in batches so the sink buffers we are holding stay bounded (a full column's
    // worth of them would double peak memory on large inputs).
    const size_t copy_batch = std::max<size_t>(8, 2 * std::thread::hardware_concurrency());

    // NOTE (measured 2026-07-22, build-13 + streaming): fetching on a background pool was tried and
    // is a NO-OP. The async scheduler already keeps `window` groups in flight, so the inline fetch
    // below overlaps with FPGA decode by construction -- prefetching only moved 42.8 ms out of
    // `fetch` and into `fpga_wait` with decode total unchanged (181.1 -> 181.7 ms), while costing
    // ~7 % more host CPU (sf10 0.442 -> 0.474 CPU-s). The decoder, not the host feed, bounds this
    // phase. See RESULTS.md 9.11.
    // Announce the element count now that the streaming decision is final, so the caller can arm
    // the IQR pass before the first group lands. Fired regardless of sink: the RTL-fused path tees
    // in hardware and works with the memcpy sink too; only the software overlap needs streaming,
    // and it gates itself on stream_enabled().
    if (hooks && hooks->on_start) {
        hooks->on_start(total, stream);
    }

    const size_t window    = decode_window();
    size_t       off_elems = 0;
    for (size_t gi : live) {
        const auto &group = meta.groups[gi];
        const auto &cc    = group.chunks[col];
        auto        type  = parcore::metadata::to_libstf_type(cc.type);
        tm.groups++;

        // Full byte span of the row group ([min chunk offset, max chunk end) over ALL chunks).
        auto     t0         = TimingClock::now();
        uint64_t span_begin = std::numeric_limits<uint64_t>::max();
        uint64_t span_end   = 0;
        for (const auto &c : group.chunks) {
            span_begin = std::min<uint64_t>(span_begin, c.offset);
            span_end   = std::max<uint64_t>(span_end, c.offset + c.total_compressed_size);
        }
        CoalescedFetcher fetcher(*file_handle, ctx.memory_pool(),
                                 {span_begin, span_end - span_begin});
        auto handle = fetcher.Register(cc.offset, cc.total_compressed_size);
        fetcher.PrepareReads();
        for (size_t i = 0; i < fetcher.num_reads(); i++) {
            fetcher.ExecuteMergedRead(i);
        }
        tm.fetch_ms += ms_since(t0);

        // source -> decode -> sink, one flow. MakeHostSourceCopy copies the compressed bytes into a
        // pooled buffer, so the fetcher may die at the end of this iteration while the flow is still
        // in flight.
        t0 = TimingClock::now();
        oasis::QuerySplinter splinter;
        oasis::OperatorFlow  flow;
        flow.push_back(MakeHostSourceCopy(ctx, fetcher.Resolve(handle)));
        flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));

        const size_t out_bytes = cc.num_values * libstf::size_of(type);
        auto         sink      = zero_copy
                                     ? MakeSlice(values, off_elems * sizeof(int64_t), out_bytes,
                                                 RoundUpToTransfer(out_bytes))
                                     : ctx.allocate_output_buffer(out_bytes);
        flow.push_back(std::make_unique<oasis::LocalSinkOperator>(sink, gi));
        splinter.streams.push_back(std::move(flow));

        in_flight.push_back(
            {ctx.scheduler().submit(std::move(splinter)), off_elems, cc.num_values, gi});
        tm.submit_ms += ms_since(t0);

        off_elems += cc.num_values;

        if (in_flight.size() >= window) {
            drain_one();
        }
        if (copies.size() >= copy_batch) {
            run_copies();
        }
    }
    while (!in_flight.empty()) {
        drain_one();
    }
    run_copies();

    return values;
}

// Computes the whole result once: decode the target column, run the IQR two passes, store the value
// buffer + packed flag bitmask into `gstate`.
void RunHeavyPhase(ClientContext &context, const IqrFlagsBindData &bind, IqrFlagsGlobalState &gstate) {
    auto &ctx = GetOrCreateOasisContext(context);

    auto         t_all = TimingClock::now();
    DecodeTiming tm;

    // OASIS_IQR_USE_CARD=1 stages the decoded column in HBM and reads both passes from card memory
    // instead of re-DMAing from the host (needs an EN_MEM bitstream). Off by default (legacy host path).
    static const bool use_card = [] {
        const char *e = std::getenv("OASIS_IQR_USE_CARD");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();

    // Overlapped pass 1: feed each decoded row group to the histogram as it lands, so pass 1 hides
    // under decode instead of running after it. Card mode stages the whole column up front and so has
    // nothing to overlap.
    //
    // The bins must be fixed before the first beat, and they MUST come from a sample that spans the
    // column -- a prefix-derived window is a wrong-answer bug, not a precision trade-off (§9.15).
    // If the spanning sample cannot be taken we simply do not overlap.
    // Fused pass 1 (RTL) takes precedence over the software overlap: it is strictly better where
    // available (no PCIe traffic, no host CPU) and works with either sink.
    bool fuse = fuse_enabled() && !use_card;

    // Row-count gate. Fusion's saving scales with N while its window sample is a fixed cost, so
    // below fuse_min_rows() it is a measured NET LOSS (taxi_d1 1.67x -> 1.27x, extprice 1.00x ->
    // 0.86x). Counted from the footer, so no decoding is wasted deciding this. Skipping the gate
    // when the count is unavailable (0) leaves the previous behaviour.
    size_t fuse_rows = 0;
    if (fuse) {
        fuse_rows = ColumnRowCountFromFooter(context, bind);
        if (fuse_rows > 0 && fuse_rows < fuse_min_rows()) {
            fuse = false;
        }
    }

    bool       overlap = !fuse && overlap_enabled() && stream_enabled() && !use_card && !bind.needs_values;
    int64_t     win_min   = 0;
    uint64_t    win_shift = 0;
    double      window_ms = 0.0;
    const char *win_src   = "n/a";
    if (fuse || overlap) {
        // Both need the bins fixed before any value arrives, so the window comes from a sample that
        // SPANS the column (a prefix-derived one is a wrong-answer bug -- RESULTS.md 9.15).
        //
        // Two ways to get that sample. The FPGA path decodes the spanning groups on the device and
        // costs ~3 ms of device time; the host path decompresses their pages on the CPU and costs
        // ~18 ms wall / ~51 ms of host CPU for work the FPGA is about to repeat. The FPGA path is
        // strictly better but changes which values are sampled -- whole groups, stride-sampled,
        // rather than each group's first DataChunk -- so bin_min/bin_shift can land a step apart and
        // flag counts can shift. It is therefore opt-in until re-gated with overlap_ab.sh accuracy.
        auto t_win = TimingClock::now();
        bool ok    = false;
        if (window_fpga_enabled()) {
            ok = DeriveWindowFromFpga(context, ctx, bind, win_min, win_shift);
            win_src = ok ? "fpga" : "fpga-failed";
        }
        if (!ok) {
            ok      = DeriveWindowSpanning(context, bind, win_min, win_shift);
            win_src = window_fpga_enabled() ? "host(fallback)" : "host";
        }
        window_ms = ms_since(t_win);
        fuse      = fuse && ok;
        overlap   = overlap && ok;
    }

    // auto_window stays true: if the overlap does not engage (the streaming guard rejects the file),
    // run() must derive its own window exactly as before, not inherit the spanning one.
    oasis::IqrRunner runner(ctx, bind.is_signed, /*auto_window=*/true, /*bin_min=*/0, /*bin_shift=*/0,
                            use_card);

    bool        pass1_started = false;
    DecodeHooks hooks;

    if (fuse) {
        // Arm the device before the first group decodes; the decode then drives pass 1 as a side
        // effect of the hardware tee. The element count must be exact -- the on-chip feed
        // regenerates the terminating `last` from it, since each lane asserts `last` per row group.
        hooks.on_start = [&](size_t total_elements, bool) {
            runner.begin_fused(win_min, win_shift, total_elements);
            pass1_started = true;
        };
    }
    if (overlap) {
        hooks.on_start = [&](size_t, bool streaming) {
            if (!streaming) {
                return;   // memcpy fallback: leave pass1_started false so run() handles it
            }
            runner.begin_overlapped(win_min, win_shift); // clears the histogram
            pass1_started = true;
        };
        hooks.on_chunk = [&](const std::shared_ptr<libstf::Buffer> &buf, size_t bytes, bool is_last) {
            runner.feed_pass1({buf->ptr, bytes}, is_last);
        };
    }

    size_t n        = 0;
    auto   t_decode = TimingClock::now();
    // Non-empty only on the streaming path; then gstate.values stays null and these ARE the input.
    std::vector<std::pair<std::shared_ptr<libstf::Buffer>, size_t>> chunks;
    gstate.values =
        DecodeColumnAllGroups(context, ctx, bind, n, tm, &chunks, (fuse || overlap) ? &hooks : nullptr);
    double decode_ms    = ms_since(t_decode);
    gstate.num_elements = n;
    if (n == 0) {
        return; // empty column -> no rows, no flags
    }

    // Snapshot the free-running StreamProfiler counters BEFORE the run so the print below can subtract
    // and report just THIS run's cycles (they accumulate for the life of the bitstream, see above).
    oasis::IqrConfig::StreamProfile base_in{}, base_out{};
    if (timing_enabled()) {
        auto cfg = ctx.config<oasis::IqrConfig>();
        base_in  = cfg->input_profile();
        base_out = cfg->output_profile();
    }
    // One chunk (the gathered column) on the default path; one chunk per row group when streaming.
    // run() concatenates them logically and asserts `last` only on the final one, so the packed
    // bitmask is identical either way.
    std::vector<oasis::IqrRunner::InputChunk> inputs;
    if (chunks.empty()) {
        inputs.emplace_back(gstate.values->ptr, n * sizeof(int64_t));
    } else {
        inputs.reserve(chunks.size());
        for (const auto &c : chunks) {
            inputs.emplace_back(c.first->ptr, c.second);
        }
    }

    // pass1_started is the authority, not `overlap`: the decode path silently falls back to the
    // memcpy sink when a row group is not a multiple of 8 elements, and then no chunk was ever fed.
    auto             t_iqr = TimingClock::now();
    auto             res   = !pass1_started ? runner.run(inputs)
                             : (fuse ? runner.finish_fused(inputs)
                                     : runner.finish_overlapped(inputs));
    double           iqr_ms = ms_since(t_iqr);
    gstate.flags           = res.flags;

    if (timing_enabled()) {
        std::fprintf(stderr,
                     "[iqr] rows=%zu  groups=%zu  window=%zu  sink=%s  pass1=%s  "
                     "win_derive %.2f ms (%s)\n"
                     "[iqr]   decode  %8.2f ms   (fpga_wait %.2f | fetch %.2f | submit %.2f | copy %.2f)\n"
                     "[iqr]   iqr     %8.2f ms   (staging %.2f | passes %.2f)\n"
                     "[iqr]   heavy   %8.2f ms   <- everything before DuckDB emits a single row\n",
                     n, tm.groups, decode_window(),
                     tm.streamed ? "stream" : (tm.zero_copy ? "zero-copy" : "memcpy"),
                     // overlapped: pass 1 is inside `decode`, so `passes` below is pass 2 only.
                     // win_derive is the spanning sample, charged to `heavy` but not to decode; its
                     // source is host (CPU page decompress) or fpga (device decode of the picks).
                     // "serial(small)" distinguishes the row-count gate from a fuse that was simply
                     // not requested -- otherwise a small file looks like OASIS_IQR_FUSE was ignored.
                     !pass1_started
                         ? (fuse_enabled() && fuse_rows > 0 && fuse_rows < fuse_min_rows()
                                ? "serial(small)"
                                : "serial")
                         : (fuse ? "fused" : "overlapped"),
                     window_ms, win_src,
                     decode_ms,
                     tm.wait_ms, tm.fetch_ms, tm.submit_ms, tm.copy_ms, iqr_ms, res.stage_ms,
                     res.passes_ms, ms_since(t_all));

        // FPGA-internal cycle breakdown (StreamProfiler). Subtract the pre-run snapshot to isolate
        // this run. 250 MHz -> us = cycles/250. handshakes should equal 2*N/8 (2 passes, 8 elems/beat),
        // and each handshake beat moves 64 bytes. busy/starved/stalled exclude idle (between-pass,
        // host-timing-dependent). starved = FPGA ready but no data (waiting on PCIe/host -- the HBM
        // target); stalled = data present but FPGA back-pressuring (compute-bound).
        auto sub = [](uint64_t a, uint64_t b) { return (a >= b) ? (a - b) : a; };
        oasis::IqrConfig::StreamProfile in{
            sub(res.input_profile.handshakes, base_in.handshakes),  sub(res.input_profile.starved, base_in.starved),
            sub(res.input_profile.stalled,    base_in.stalled),     sub(res.input_profile.idle,    base_in.idle)};
        oasis::IqrConfig::StreamProfile out{
            sub(res.output_profile.handshakes, base_out.handshakes), sub(res.output_profile.starved, base_out.starved),
            sub(res.output_profile.stalled,    base_out.stalled),    sub(res.output_profile.idle,    base_out.idle)};
        auto     pct     = [](uint64_t x, uint64_t t) { return t ? 100.0 * (double) x / (double) t : 0.0; };
        uint64_t in_act  = in.handshakes + in.starved + in.stalled;
        uint64_t out_act = out.handshakes + out.starved + out.stalled;
        double   in_bw   = res.passes_ms > 0.0 ? (double) in.handshakes * 64.0 / (res.passes_ms * 1e6) : 0.0;
        std::fprintf(stderr,
                     "[iqr-prof] N=%zu  expect handshakes(2N/8)=%.0f  passes=%.2f ms\n"
                     "[iqr-prof]  INPUT  hs=%llu starved=%llu stalled=%llu idle=%llu | busy=%.1f%% starved=%.1f%% stalled=%.1f%%  active=%.1f us  eff=%.2f GB/s\n"
                     "[iqr-prof]  OUTPUT hs=%llu starved=%llu stalled=%llu idle=%llu | busy=%.1f%% starved=%.1f%% stalled=%.1f%%  active=%.1f us\n"
                     "[iqr-prof]  (self-check: raw in.hs=%llu base in.hs=%llu -- if raw already==2N/8 the counters self-zero and the delta is a no-op)\n",
                     n, 2.0 * (double) n / 8.0, res.passes_ms,
                     (unsigned long long) in.handshakes, (unsigned long long) in.starved,
                     (unsigned long long) in.stalled, (unsigned long long) in.idle,
                     pct(in.handshakes, in_act), pct(in.starved, in_act), pct(in.stalled, in_act),
                     in_act / 250.0, in_bw,
                     (unsigned long long) out.handshakes, (unsigned long long) out.starved,
                     (unsigned long long) out.stalled, (unsigned long long) out.idle,
                     pct(out.handshakes, out_act), pct(out.starved, out_act), pct(out.stalled, out_act),
                     out_act / 250.0,
                     (unsigned long long) res.input_profile.handshakes, (unsigned long long) base_in.handshakes);
    }
}

// Resolves (file, column) to a validated IqrFlagsBindData: locates the target column, checks it is a
// 64-bit integer, and captures its signedness. Shared by iqr_flags and iqr_flags_only, which run the
// identical heavy phase and differ only in output schema. `fn` names the caller for error messages.
unique_ptr<IqrFlagsBindData> ResolveIqrColumn(ClientContext &context, const string &filename,
                                              const string &column, const char *fn) {
    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {filename}, parquet_opts);

    auto bind_data = make_uniq<IqrFlagsBindData>();
    for (idx_t i = 0; i < reader.columns.size(); i++) {
        if (reader.columns[i].name.GetIdentifierName() == column) {
            bind_data->column_id   = i;
            bind_data->column_type = reader.columns[i].type;
            break;
        }
    }
    if (bind_data->column_id == DConstants::INVALID_INDEX) {
        throw BinderException("%s: column '%s' not found in '%s'", fn, column, filename);
    }

    // The vFPGA top instantiates IQR_detection with 64-bit values, so only 64-bit integer columns
    // are supported. Signedness is taken from the column type and forwarded to the device.
    auto type_id = bind_data->column_type.id();
    if (type_id != LogicalTypeId::BIGINT && type_id != LogicalTypeId::UBIGINT) {
        throw BinderException("%s: column '%s' must be a 64-bit integer (BIGINT or UBIGINT), but is %s",
                              fn, column, bind_data->column_type.ToString());
    }
    bind_data->filename         = filename;
    bind_data->column_name      = column;
    bind_data->is_signed        = (type_id == LogicalTypeId::BIGINT);
    bind_data->parquet_metadata = reader.metadata;
    return bind_data;
}

unique_ptr<FunctionData> IqrFlagsBind(ClientContext &context, TableFunctionBindInput &input,
                                      vector<LogicalType> &return_types, vector<string> &names) {
    auto bind_data = ResolveIqrColumn(context, StringValue::Get(input.inputs[0]),
                                      StringValue::Get(input.inputs[1]), "iqr_flags");

    // Output schema: the value column, then the boolean outlier flag.
    names.push_back(bind_data->column_name);
    return_types.push_back(bind_data->column_type);
    names.push_back("is_outlier");
    return_types.push_back(LogicalType::BOOLEAN);

    return std::move(bind_data);
}

// iqr_flags_only(path, column) -> just the BOOLEAN is_outlier column (one row per input row). Same
// heavy phase as iqr_flags, but the emit skips re-copying the value: the caller already has the
// values, so the only new information is the per-row flag. Half the output to materialize, and it is
// the mask you apply back onto your own table.
unique_ptr<FunctionData> IqrFlagsOnlyBind(ClientContext &context, TableFunctionBindInput &input,
                                          vector<LogicalType> &return_types, vector<string> &names) {
    auto bind_data = ResolveIqrColumn(context, StringValue::Get(input.inputs[0]),
                                      StringValue::Get(input.inputs[1]), "iqr_flags_only");
    bind_data->needs_values = false; // bitmask only -> the decoded column never has to be gathered
    names.emplace_back("is_outlier");
    return_types.push_back(LogicalType::BOOLEAN);
    return std::move(bind_data);
}

// The heavy phase runs here: InitGlobal is called once, on one thread, before any worker executes.
// That also lets MaxThreads() see the final row count, so DuckDB sizes the scan's parallelism.
unique_ptr<GlobalTableFunctionState> IqrFlagsInitGlobal(ClientContext &context,
                                                        TableFunctionInitInput &input) {
    auto &bind   = input.bind_data->Cast<IqrFlagsBindData>();
    auto  gstate = make_uniq<IqrFlagsGlobalState>();
    RunHeavyPhase(context, bind, *gstate);
    return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> IqrFlagsInitLocal(ExecutionContext &, TableFunctionInitInput &,
                                                      GlobalTableFunctionState *) {
    return make_uniq<IqrFlagsLocalState>();
}

void IqrFlagsFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &gstate = data_p.global_state->Cast<IqrFlagsGlobalState>();

    // Claim a disjoint slice of rows. Workers never overlap, so no lock is needed past this point.
    size_t start = gstate.cursor.fetch_add(STANDARD_VECTOR_SIZE, std::memory_order_relaxed);
    if (start >= gstate.num_elements) {
        output.SetChildCardinality(0);
        return;
    }
    size_t emit = std::min<size_t>(STANDARD_VECTOR_SIZE, gstate.num_elements - start);

    const int64_t *values = reinterpret_cast<const int64_t *>(gstate.values->ptr);
    const uint8_t *mask   = reinterpret_cast<const uint8_t *>(gstate.flags->ptr);

    auto &value_vec = output.data[0];
    auto &flag_vec  = output.data[1];
    value_vec.SetVectorType(VectorType::FLAT_VECTOR);
    flag_vec.SetVectorType(VectorType::FLAT_VECTOR);
    auto value_out = FlatVector::GetDataMutable<int64_t>(value_vec);
    auto flag_out  = FlatVector::GetDataMutable<bool>(flag_vec);

    for (size_t k = 0; k < emit; k++) {
        size_t i     = start + k;
        value_out[k] = values[i];
        // Packed bitmask: element i is byte i/8, bit i%8 (LSB-first) -- matches IQR_detection.sv.
        flag_out[k] = (mask[i >> 3] >> (i & 7)) & 1u;
    }
    output.SetChildCardinality(emit);
}

// Unpacks `emit` flags starting at element `start` out of a packed bitmask into a single BOOLEAN
// output vector. Shared verbatim by iqr_flags_only (FPGA) and iqr_cpu_flags (CPU): both produce the
// same packed layout, so the entire output path of the two operators is the same code. That is what
// makes the head-to-head a controlled experiment -- only the compute differs, never the emit.
void EmitFlagSlice(const uint8_t *mask, size_t start, size_t emit, DataChunk &output) {
    auto &flag_vec = output.data[0];
    flag_vec.SetVectorType(VectorType::FLAT_VECTOR);
    auto flag_out = FlatVector::GetDataMutable<bool>(flag_vec);

    for (size_t k = 0; k < emit; k++) {
        size_t i    = start + k;
        // Packed bitmask: element i is byte i/8, bit i%8 (LSB-first) -- matches IQR_detection.sv.
        flag_out[k] = (mask[i >> 3] >> (i & 7)) & 1u;
    }
    output.SetChildCardinality(emit);
}

// Emit only the boolean flag column (no value echoed back). Shares InitGlobal/InitLocal/GlobalState
// with iqr_flags; the parallel cursor + bitmask-unpack are identical, just without the value copy.
void IqrFlagsOnlyFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &gstate = data_p.global_state->Cast<IqrFlagsGlobalState>();

    size_t start = gstate.cursor.fetch_add(STANDARD_VECTOR_SIZE, std::memory_order_relaxed);
    if (start >= gstate.num_elements) {
        output.SetChildCardinality(0);
        return;
    }
    size_t emit = std::min<size_t>(STANDARD_VECTOR_SIZE, gstate.num_elements - start);

    EmitFlagSlice(reinterpret_cast<const uint8_t *>(gstate.flags->ptr), start, emit, output);
}

// =============================================================================================
// iqr_cpu_flags(path VARCHAR, column VARCHAR) -- the CPU reference implementation
//
// The apples-to-apples twin of iqr_flags_only: same bind, same validation, same packed-bitmask
// output, same emit code (EmitFlagSlice). The ONLY difference is that the quartiles and the fence
// comparison run on the host cores instead of on the FPGA.
//
// Why this exists. The CPU baseline used to be an ~9-line SQL query (6 CTEs, a GROUP BY, a window
// function, correlated subqueries). That measures "FPGA operator vs CPU algorithm + DuckDB's parser,
// binder, optimizer and general-purpose executor" -- not FPGA vs CPU. Our own phrasing sweep proved
// the point: the *same* algorithm written five different ways in SQL ranged 0.092 s to 3.381 s, a
// 37x spread. A SQL baseline therefore measures the query, not the machine. Implementing it here
// makes both sides one line of SQL and makes the baseline something a reviewer can actually read.
//
// The algorithm, matching the SQL exactly:
//   q1 = smallest v with (#elements <= v)*4 >= N  ==  the ceil(N/4)-th smallest value
//   q3 = smallest v with (#elements <= v)*4 >= 3N ==  the ceil(3N/4)-th smallest value
//   d = q3-q1;  lo = q1 - (d + (d>>1));  hi = q3 + (d + (d>>1))   (1.5*IQR, divider-free)
//   flag[i] = (v[i] < lo) || (v[i] > hi)
// so the quartiles are plain order statistics. We resolve them with a two-level histogram rather
// than a sort: one parallel min/max pass, one parallel 65536-bin pass to find which bin holds each
// rank, then one parallel pass collecting only the two winning bins and an nth_element inside them.
// O(N), no sort, bounded memory, and the same shape as the hardware's windowed histogram.
// =============================================================================================

// DuckDB's configured worker count (PRAGMA threads), so the CPU baseline gets exactly the
// parallelism the user asked for -- the same knob that governs the SQL baseline.
size_t CpuThreadCount(ClientContext &context) {
    int32_t n = TaskScheduler::GetScheduler(context).NumberOfThreads();
    return n < 1 ? 1u : static_cast<size_t>(n);
}

// Splits [0, n) into at most `nthreads` contiguous ranges and runs fn(thread_idx, lo, hi) on each.
// thread_idx is always < nthreads, so callers can index per-thread scratch by it.
template <class F>
void ParallelRanges(size_t n, size_t nthreads, F &&fn) {
    if (n == 0) {
        return;
    }
    if (nthreads <= 1) {
        fn(size_t(0), size_t(0), n);
        return;
    }
    const size_t             chunk = (n + nthreads - 1) / nthreads;
    std::vector<std::thread> workers;
    workers.reserve(nthreads);
    for (size_t t = 0; t < nthreads; t++) {
        size_t lo = t * chunk;
        if (lo >= n) {
            break;
        }
        size_t hi = std::min(n, lo + chunk);
        workers.emplace_back([&fn, t, lo, hi] { fn(t, lo, hi); });
    }
    for (auto &w : workers) {
        w.join();
    }
}

template <class T>
void ParallelMinMax(const T *v, size_t n, size_t nt, T &out_min, T &out_max) {
    // Unused slots keep the identity values, so the reductions below stay correct when
    // ParallelRanges spawns fewer than `nt` threads.
    std::vector<T> mins(nt, std::numeric_limits<T>::max());
    std::vector<T> maxs(nt, std::numeric_limits<T>::lowest());
    ParallelRanges(n, nt, [&](size_t t, size_t lo, size_t hi) {
        T mn = std::numeric_limits<T>::max();
        T mx = std::numeric_limits<T>::lowest();
        for (size_t i = lo; i < hi; i++) {
            T x = v[i];
            mn  = x < mn ? x : mn;
            mx  = x > mx ? x : mx;
        }
        mins[t] = mn;
        maxs[t] = mx;
    });
    out_min = *std::min_element(mins.begin(), mins.end());
    out_max = *std::max_element(maxs.begin(), maxs.end());
}

// 4096 bins x 4 B = 16 KB per table -- small enough to stay resident in L1 alongside the streaming
// column. The previous 65536 x 8 B = 512 KB table overflowed L2, so every increment was a cache miss
// and the histogram passes ran at ~11 GB/s against the ~40 GB/s this machine sustains on a plain scan.
// Fewer bins means more levels in principle, but every real column here still resolves in two.
// uint32 counters are safe up to 4.29e9 rows per thread.
constexpr size_t IQR_CPU_HIST_BINS = 1u << 12;

// One "find the rank-th smallest value inside [lo,hi]" question, narrowed one histogram level at a
// time. Several of these are advanced together so that q1 and q3 share a single pass over the column.
template <class T>
struct RankQuery {
    T      lo;
    T      hi;
    size_t rank; // 0-indexed, relative to the elements currently inside [lo,hi]
    bool   done;
    T      result;
};

// Advances every unfinished query by one level in a SINGLE pass over the column. Queries whose
// ranges are identical (which is always the case on the first level, where both quartiles span
// [min,max]) share one histogram instead of building the same counts twice.
template <class T>
void AdvanceRankQueries(const T *v, size_t n, size_t nt, RankQuery<T> *q, size_t nq,
                        std::vector<std::vector<uint32_t>> &scratch) {
    using U                    = typename std::make_unsigned<T>::type;
    constexpr size_t MAX_ACTIVE = 4;

    size_t   active[MAX_ACTIVE];   // index into q[] of each unfinished query
    size_t   hist_of[MAX_ACTIVE];  // which histogram that query reads
    U        base[MAX_ACTIVE];
    unsigned shift[MAX_ACTIVE];
    size_t   nbins[MAX_ACTIVE];
    size_t   na = 0, nh = 0;

    for (size_t i = 0; i < nq && na < MAX_ACTIVE; i++) {
        if (q[i].done) {
            continue;
        }
        if (q[i].lo == q[i].hi) { // range collapsed to one value: that is the answer
            q[i].result = q[i].lo;
            q[i].done   = true;
            continue;
        }
        const U  b     = static_cast<U>(q[i].lo);
        const U  range = static_cast<U>(q[i].hi) - b;
        unsigned sh    = 0;
        while ((range >> sh) >= IQR_CPU_HIST_BINS) {
            sh++;
        }
        // Share a histogram with an earlier active query covering exactly the same range.
        size_t reuse = nh;
        for (size_t j = 0; j < na; j++) {
            if (q[active[j]].lo == q[i].lo && q[active[j]].hi == q[i].hi) {
                reuse = hist_of[j];
                break;
            }
        }
        if (reuse == nh) {
            base[nh]  = b;
            shift[nh] = sh;
            nbins[nh] = static_cast<size_t>(range >> sh) + 1;
            nh++;
        }
        hist_of[na] = reuse;
        active[na]  = i;
        na++;
    }
    if (na == 0) {
        return;
    }

    // Span of each histogram as an unsigned offset from its base. Hoisted out of the scan: unsigned
    // wrap puts any out-of-range value above the span, so membership is a single compare per element.
    U span[MAX_ACTIVE];
    for (size_t h = 0; h < nh; h++) {
        span[h] = ((static_cast<U>(nbins[h]) - 1) << shift[h]) | ((U(1) << shift[h]) - 1);
    }

    const size_t stride = IQR_CPU_HIST_BINS;
    if (scratch.size() != nt) {
        scratch.assign(nt, {});
    }
    ParallelRanges(n, nt, [&](size_t t, size_t lo, size_t hi) {
        auto &sc = scratch[t];
        if (sc.size() < stride * nh) {
            sc.assign(stride * nh, 0);
        } else {
            std::fill(sc.begin(), sc.begin() + stride * nh, 0);
        }
        uint32_t *sp = sc.data();
        if (nh == 1) {
            // The first level always lands here (both quartiles share [min,max]). Keeping it a flat
            // loop over scalars, with nothing indexed by a loop variable, is worth a lot to the
            // vectorizer compared with the general path below.
            const U        b0 = base[0], s0 = span[0];
            const unsigned k0 = shift[0];
            for (size_t i = lo; i < hi; i++) {
                const U off = static_cast<U>(v[i]) - b0;
                if (off <= s0) {
                    sp[static_cast<size_t>(off >> k0)]++;
                }
            }
            return;
        }
        for (size_t i = lo; i < hi; i++) {
            const T x = v[i];
            for (size_t h = 0; h < nh; h++) {
                const U off = static_cast<U>(x) - base[h];
                if (off <= span[h]) {
                    sp[h * stride + static_cast<size_t>(off >> shift[h])]++;
                }
            }
        }
    });

    for (size_t j = 0; j < na; j++) {
        RankQuery<T> &qq = q[active[j]];
        const size_t  h  = hist_of[j];

        uint64_t cum = 0, before = 0;
        size_t   chosen = nbins[h] - 1;
        bool     found  = false;
        for (size_t b = 0; b < nbins[h]; b++) {
            uint64_t c = 0;
            for (size_t t = 0; t < nt; t++) {
                const auto &sc = scratch[t];
                if (sc.size() >= stride * nh) {
                    c += sc[h * stride + b];
                }
            }
            if (cum + c > qq.rank) {
                chosen = b;
                before = cum;
                found  = true;
                break;
            }
            cum += c;
        }
        if (!found) {
            before = cum; // rank past the end: clamp into the last bin
        }
        qq.rank -= static_cast<size_t>(before);

        const T nlo = static_cast<T>(base[h] + (static_cast<U>(chosen) << shift[h]));
        if (shift[h] == 0) {
            qq.result = nlo; // one distinct value per bin -- exact
            qq.done   = true;
            continue;
        }
        T nhi = static_cast<T>(base[h] + ((static_cast<U>(chosen + 1) << shift[h]) - 1));
        if (nhi > qq.hi) {
            nhi = qq.hi;
        }
        qq.lo = nlo;
        qq.hi = nhi;
    }
}

// Exact order statistics k1 and k3 (both 0-indexed) by iterative histogram narrowing, with both
// quartiles advanced in the same pass. No sort, no candidate materialization, O(N) per level and at
// most a handful of levels (every dataset here needs two).
template <class T>
void SelectQuartiles(const T *v, size_t n, size_t k1, size_t k3, size_t nt, T &q1, T &q3) {
    T vmin, vmax;
    ParallelMinMax<T>(v, n, nt, vmin, vmax);
    if (vmin == vmax) {
        q1 = q3 = vmin; // constant column: every order statistic is that value
        return;
    }

    RankQuery<T> q[2] = {{vmin, vmax, k1, false, T {}}, {vmin, vmax, k3, false, T {}}};
    std::vector<std::vector<uint32_t>> scratch;
    while (!q[0].done || !q[1].done) {
        AdvanceRankQueries<T>(v, n, nt, q, 2, scratch);
    }
    q1 = q[0].result;
    q3 = q[1].result;
}

// lo/hi for the 1.5*IQR rule. Computed in 128-bit so q3+1.5*IQR can never overflow T, then clamped
// back into T's range -- clamping is exact here, since no value of type T can lie outside it anyway.
template <class T>
void IqrFences(T q1, T q3, T &lo, T &hi) {
    const __int128 a    = static_cast<__int128>(q1);
    const __int128 b    = static_cast<__int128>(q3);
    const __int128 d    = b - a;
    const __int128 ext  = d + (d >> 1); // d + d/2 == 1.5*IQR; d >= 0, so the shift is exact
    const __int128 l    = a - ext;
    const __int128 h    = b + ext;
    const __int128 tmin = static_cast<__int128>(std::numeric_limits<T>::lowest());
    const __int128 tmax = static_cast<__int128>(std::numeric_limits<T>::max());
    lo = static_cast<T>(l < tmin ? tmin : (l > tmax ? tmax : l));
    hi = static_cast<T>(h < tmin ? tmin : (h > tmax ? tmax : h));
}

// flag[i] = v[i] < lo || v[i] > hi, into the same LSB-first packed bitmask the FPGA writes. Threads
// are split on *byte* boundaries so no two of them ever touch the same mask byte.
template <class T>
void ComputeFlagMask(const T *v, size_t n, T lo, T hi, uint8_t *mask, size_t nt) {
    const size_t nbytes = (n + 7) / 8;
    ParallelRanges(nbytes, nt, [&](size_t, size_t blo, size_t bhi) {
        for (size_t b = blo; b < bhi; b++) {
            const size_t base  = b * 8;
            const size_t limit = std::min<size_t>(8, n - base);
            uint8_t      byte  = 0;
            for (size_t j = 0; j < limit; j++) {
                T x = v[base + j];
                byte |= static_cast<uint8_t>((x < lo || x > hi) ? 1u : 0u) << j;
            }
            mask[b] = byte;
        }
    });
}

// Reads the target column into one contiguous int64 array using DuckDB's own parquet reader (the
// CPU's best decoder, just as the FPGA path uses its own). Row counts come from the footer, so each
// worker knows its destination offset up front and workers write disjoint ranges of `out`.
size_t ReadColumnCpu(ClientContext &context, const IqrFlagsBindData &bind, size_t nt,
                     AllocatedData &out) {
    ParquetOptions parquet_opts(context);
    ParquetReader  probe(context, OpenFileInfo {bind.filename}, parquet_opts, bind.parquet_metadata);
    auto           meta = BuildParcoreMetadata(probe);

    const size_t        ngroups = meta.groups.size();
    std::vector<size_t> group_off(ngroups, 0);
    size_t              total = 0;
    for (size_t g = 0; g < ngroups; g++) {
        group_off[g] = total;
        total += meta.groups[g].chunks[bind.column_id].num_values;
    }
    if (total == 0) {
        return 0;
    }
    // Allocated through DuckDB's own allocator rather than new[], so the column is pooled and freed
    // the same way the FPGA path's buffers are. With new[], releasing 457.7 MB (sf10) landed AFTER
    // the `heavy` timer stopped and showed up as a 63.8 ms "tax" against the CPU -- 5x the FPGA's
    // 12.7 ms -- which flattered the FPGA's end-to-end numbers for a reason that was an artefact of
    // this allocation choice, not a property of CPU execution. Like new[], this does NOT
    // value-initialise: std::vector would memset the whole column single-threaded before the read
    // overwrites it (82 ms on taxi_d4, 229 ms on sf10), and leaving it untouched also pushes
    // first-touch page faulting into the parallel read where 32 workers absorb it.
    out = Allocator::Get(context).Allocate(total * sizeof(int64_t));

    // One worker per contiguous block of row groups; each builds its own reader and scan state
    // (neither is thread-safe) but shares the already-parsed footer.
    const size_t nworkers = std::min(nt, ngroups);
    ParallelRanges(ngroups, nworkers, [&](size_t, size_t ga, size_t gb) {
        ParquetOptions opts(context);
        ParquetReader  reader(context, OpenFileInfo {bind.filename}, opts, probe.metadata);
        // Project only the target column. Both lists must be pushed in lockstep and are indexed
        // positionally: InitializeScan builds state.column_readers from `column_indexes`, while
        // Schedule() walks `column_ids` to decide which chunks to actually fetch. Setting only
        // column_indexes yields a reader that returns rows containing nothing.
        reader.column_ids.push_back(MultiFileLocalColumnId(bind.column_id));
        reader.column_indexes.emplace_back(bind.column_id);

        vector<idx_t> groups;
        groups.reserve(gb - ga);
        for (size_t g = ga; g < gb; g++) {
            groups.push_back(static_cast<idx_t>(g));
        }
        ParquetReaderScanState state;
        reader.InitializeScan(context, state, std::move(groups));

        DataChunk chunk;
        chunk.Initialize(Allocator::Get(context), {bind.column_type});

        int64_t *const start = reinterpret_cast<int64_t *>(out.get()) + group_off[ga];
        int64_t       *dst   = start;
        for (;;) {
            chunk.Reset();
            auto res = reader.Scan(context, state, chunk);
            // The reader may need async I/O; run it here rather than yielding to the scheduler.
            while (res.GetResultType() == AsyncResultType::BLOCKED) {
                res.ExecuteTasksSynchronously();
                res = reader.Scan(context, state, chunk);
            }
            const idx_t count = chunk.size();
            if (count == 0) {
                break;
            }
            auto &vec = chunk.data[0];
            vec.Flatten();
            std::memcpy(dst, FlatVector::GetData<int64_t>(vec), count * sizeof(int64_t));
            dst += count;
        }

        // The footer already told us how many values these groups hold, so a short read means the
        // scan silently stopped early and the tail of `out` would still be zero-filled -- which
        // produces q1 == q3 == 0, fences of [0,0] and a plausible-looking all-false mask. Fail loudly
        // instead: a wrong answer here is far worse than an exception.
        const size_t expected = (gb < ngroups ? group_off[gb] : total) - group_off[ga];
        const size_t got      = static_cast<size_t>(dst - start);
        if (got != expected) {
            throw InternalException("iqr_cpu_flags: row groups [%llu,%llu) yielded %llu values, "
                                    "expected %llu",
                                    (unsigned long long)ga, (unsigned long long)gb,
                                    (unsigned long long)got, (unsigned long long)expected);
        }
    });
    return total;
}

// Quartiles + fences + flags for one signedness. Returns a short description of the fences it
// derived, so OASIS_IQR_TIMING=1 can print them next to the FPGA's for a direct comparison.
template <class T>
std::string IqrCpuCore(const int64_t *raw, size_t n, size_t nt, uint8_t *mask, double &quart_ms,
                       double &flag_ms) {
    const T *v = reinterpret_cast<const T *>(raw);

    // min(v) WHERE cc*4 >= t  ==  the ceil(N/4)-th smallest, 1-indexed. Likewise 3N/4 for q3.
    const size_t k1 = (n + 3) / 4;
    const size_t k3 = (3 * n + 3) / 4;

    T    q1, q3, lo, hi;
    auto t0 = TimingClock::now();
    SelectQuartiles<T>(v, n, k1 - 1, k3 - 1, nt, q1, q3);
    IqrFences<T>(q1, q3, lo, hi);
    quart_ms = ms_since(t0);

    auto t1 = TimingClock::now();
    ComputeFlagMask<T>(v, n, lo, hi, mask, nt);
    flag_ms = ms_since(t1);

    return "q1=" + std::to_string(q1) + " q3=" + std::to_string(q3) + " lo=" + std::to_string(lo) +
           " hi=" + std::to_string(hi);
}

// The CPU twin of IqrFlagsGlobalState: owns plain host memory, so this operator builds and runs with
// no FPGA present at all.
struct IqrCpuGlobalState : public GlobalTableFunctionState {
    std::unique_ptr<uint8_t[]> flags; // packed outlier bitmask, same layout as the FPGA's
    size_t                     num_elements = 0;
    std::atomic<size_t>        cursor {0};

    idx_t MaxThreads() const override {
        return MaxValue<idx_t>(1, (num_elements + STANDARD_VECTOR_SIZE - 1) / STANDARD_VECTOR_SIZE);
    }
};

void RunHeavyPhaseCpu(ClientContext &context, const IqrFlagsBindData &bind, IqrCpuGlobalState &gstate) {
    const size_t nt    = CpuThreadCount(context);
    auto         t_all = TimingClock::now();

    AllocatedData values;
    auto          t_read  = TimingClock::now();
    const size_t               n       = ReadColumnCpu(context, bind, nt, values);
    const double               read_ms = ms_since(t_read);
    gstate.num_elements                = n;
    if (n == 0) {
        return;
    }

    // ComputeFlagMask writes every byte, so this too is left uninitialized on purpose.
    gstate.flags.reset(new uint8_t[(n + 7) / 8]);

    const int64_t *vals = reinterpret_cast<const int64_t *>(values.get());
    double      quart_ms = 0.0, flag_ms = 0.0;
    std::string fences =
        bind.is_signed
            ? IqrCpuCore<int64_t>(vals, n, nt, gstate.flags.get(), quart_ms, flag_ms)
            : IqrCpuCore<uint64_t>(vals, n, nt, gstate.flags.get(), quart_ms, flag_ms);

    if (timing_enabled()) {
        std::fprintf(stderr,
                     "[iqr-cpu] rows=%zu  threads=%zu  %s\n"
                     "[iqr-cpu]   read    %8.2f ms   <- DuckDB parquet decode of the target column\n"
                     "[iqr-cpu]   quart   %8.2f ms   <- min/max + 2-level histogram + nth_element\n"
                     "[iqr-cpu]   flags   %8.2f ms   <- fence compare into the packed bitmask\n"
                     "[iqr-cpu]   heavy   %8.2f ms   <- everything before DuckDB emits a single row\n",
                     n, nt, fences.c_str(), read_ms, quart_ms, flag_ms, ms_since(t_all));
    }
}

unique_ptr<FunctionData> IqrCpuFlagsBind(ClientContext &context, TableFunctionBindInput &input,
                                         vector<LogicalType> &return_types, vector<string> &names) {
    auto bind_data = ResolveIqrColumn(context, StringValue::Get(input.inputs[0]),
                                      StringValue::Get(input.inputs[1]), "iqr_cpu_flags");
    names.emplace_back("is_outlier");
    return_types.push_back(LogicalType::BOOLEAN);
    return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> IqrCpuFlagsInitGlobal(ClientContext &context,
                                                           TableFunctionInitInput &input) {
    auto &bind   = input.bind_data->Cast<IqrFlagsBindData>();
    auto  gstate = make_uniq<IqrCpuGlobalState>();
    RunHeavyPhaseCpu(context, bind, *gstate);
    return std::move(gstate);
}

void IqrCpuFlagsFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &gstate = data_p.global_state->Cast<IqrCpuGlobalState>();

    size_t start = gstate.cursor.fetch_add(STANDARD_VECTOR_SIZE, std::memory_order_relaxed);
    if (start >= gstate.num_elements) {
        output.SetChildCardinality(0);
        return;
    }
    size_t emit = std::min<size_t>(STANDARD_VECTOR_SIZE, gstate.num_elements - start);

    EmitFlagSlice(gstate.flags.get(), start, emit, output);
}

// iqr_profiler() -> one row of the RAW StreamProfiler counters (regs 7-14), cumulative since the
// bitstream was loaded and NOT reset. Read it yourself, before and after an iqr_flags query, to see a
// run's accumulation and control it manually (unlike the [iqr-prof] print, which auto-subtracts):
//   SELECT * FROM iqr_profiler();                                   -- baseline
//   SELECT count(*) FROM iqr_flags_only('/path.parquet','col');     -- run (accumulates)
//   SELECT * FROM iqr_profiler();                                   -- after; delta = this run's cycles
// in_handshakes should rise by exactly 2*N/8 per run (2 passes, 8 elems/beat). 250 MHz -> us=cycles/250.
struct IqrProfilerState : public GlobalTableFunctionState {
    bool  done = false;
    idx_t MaxThreads() const override { return 1; }
};

unique_ptr<FunctionData> IqrProfilerBind(ClientContext &, TableFunctionBindInput &,
                                         vector<LogicalType> &return_types, vector<string> &names) {
    for (auto *c : {"in_handshakes", "in_starved", "in_stalled", "in_idle", "out_handshakes",
                    "out_starved", "out_stalled", "out_idle"}) {
        names.emplace_back(c);
        return_types.push_back(LogicalType::UBIGINT);
    }
    return make_uniq<TableFunctionData>();
}

unique_ptr<GlobalTableFunctionState> IqrProfilerInit(ClientContext &, TableFunctionInitInput &) {
    return make_uniq<IqrProfilerState>();
}

void IqrProfilerFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &st = data_p.global_state->Cast<IqrProfilerState>();
    if (st.done) {
        output.SetChildCardinality(0);
        return;
    }
    auto    &ctx = GetOrCreateOasisContext(context);
    auto     cfg = ctx.config<oasis::IqrConfig>();
    auto     in  = cfg->input_profile();
    auto     out = cfg->output_profile();
    uint64_t vals[8] = {in.handshakes,  in.starved,  in.stalled,  in.idle,
                        out.handshakes, out.starved, out.stalled, out.idle};
    for (int c = 0; c < 8; c++) {
        output.data[c].SetVectorType(VectorType::FLAT_VECTOR);
        FlatVector::GetDataMutable<uint64_t>(output.data[c])[0] = vals[c];
    }
    output.SetChildCardinality(1);
    st.done = true;
}

// decoder_profiler() -> one row PER DECODER LANE of the built-in ColumnChunkDecoder StreamProfilers
// (input + output). Tells you where the DECODER spends its time: in_starved = waiting on compressed
// bytes (fetch/PCIe-bound); out_stalled = decoder output back-pressured; high busy with low starved/
// stalled = compute-bound (the hard-column case). NOTE: these HW profilers AUTO-RESET after each full
// read, so each call returns the cycles since the PREVIOUS call -- read once to clear, run your query,
// read again for that query's decode. 250 MHz -> us = cycles/250.
struct DecoderProfilerState : public GlobalTableFunctionState {
    bool  done = false;
    idx_t MaxThreads() const override { return 1; }
};

unique_ptr<FunctionData> DecoderProfilerBind(ClientContext &, TableFunctionBindInput &,
                                             vector<LogicalType> &return_types, vector<string> &names) {
    names.emplace_back("decoder");
    return_types.push_back(LogicalType::UBIGINT);
    for (auto *c : {"in_handshakes", "in_starved", "in_stalled", "in_idle", "out_handshakes",
                    "out_starved", "out_stalled", "out_idle"}) {
        names.emplace_back(c);
        return_types.push_back(LogicalType::UBIGINT);
    }
    return make_uniq<TableFunctionData>();
}

unique_ptr<GlobalTableFunctionState> DecoderProfilerInit(ClientContext &, TableFunctionInitInput &) {
    return make_uniq<DecoderProfilerState>();
}

void DecoderProfilerFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &st = data_p.global_state->Cast<DecoderProfilerState>();
    if (st.done) {
        output.SetChildCardinality(0);
        return;
    }
    auto &ctx = GetOrCreateOasisContext(context);
    auto  cfg = ctx.config<parcore::ColumnChunkDecoderConfig>();
    auto  nd  = cfg->num_decoders();
    for (int col = 0; col < 9; col++) {
        output.data[col].SetVectorType(VectorType::FLAT_VECTOR);
    }
    for (libstf::stream_t d = 0; d < nd; d++) {
        auto     p        = cfg->read_profile(d);
        uint64_t row[9]   = {(uint64_t) d,
                             p.in.handshakes_cycles,  p.in.starved_cycles,  p.in.stalled_cycles,  p.in.idle_cycles,
                             p.out.handshakes_cycles, p.out.starved_cycles, p.out.stalled_cycles, p.out.idle_cycles};
        for (int col = 0; col < 9; col++) {
            FlatVector::GetDataMutable<uint64_t>(output.data[col])[d] = row[col];
        }
    }
    output.SetChildCardinality(nd);
    st.done = true;
}

} // namespace

void RegisterOasisIqrFunction(ExtensionLoader &loader) {
    TableFunction iqr_flags("iqr_flags",                                  // name
                            {LogicalType::VARCHAR, LogicalType::VARCHAR}, // args: file path, column
                            IqrFlagsFunction,                            // emit (parallel)
                            IqrFlagsBind,                                // bind (schema)
                            IqrFlagsInitGlobal,                          // global init (heavy phase)
                            IqrFlagsInitLocal                            // local init (per worker)
    );
    loader.RegisterFunction(iqr_flags);

    // Flag-only sibling: same heavy phase, emits just the is_outlier boolean array (no value column).
    TableFunction iqr_flags_only("iqr_flags_only", {LogicalType::VARCHAR, LogicalType::VARCHAR},
                                 IqrFlagsOnlyFunction, IqrFlagsOnlyBind, IqrFlagsInitGlobal,
                                 IqrFlagsInitLocal);
    loader.RegisterFunction(iqr_flags_only);

    // CPU reference implementation: identical signature, schema and emit path to iqr_flags_only, so
    //   SELECT is_outlier FROM iqr_flags_only(f,c);   -- FPGA
    //   SELECT is_outlier FROM iqr_cpu_flags (f,c);   -- CPU
    // differ in nothing but where the quartiles and the fence compare run.
    TableFunction iqr_cpu_flags("iqr_cpu_flags", {LogicalType::VARCHAR, LogicalType::VARCHAR},
                                IqrCpuFlagsFunction, IqrCpuFlagsBind, IqrCpuFlagsInitGlobal,
                                IqrFlagsInitLocal);
    loader.RegisterFunction(iqr_cpu_flags);

    // Raw StreamProfiler read (no args): SELECT * FROM iqr_profiler(); returns the cumulative regs 7-14
    // so you can snapshot/subtract manually around your own queries (accumulation under your control).
    TableFunction iqr_profiler("iqr_profiler", {}, IqrProfilerFunction, IqrProfilerBind, IqrProfilerInit);
    loader.RegisterFunction(iqr_profiler);

    // Built-in ColumnChunkDecoder StreamProfilers (one row per decoder lane): SELECT * FROM
    // decoder_profiler(); shows where the DECODER spends time. HW auto-resets after each read.
    TableFunction decoder_profiler("decoder_profiler", {}, DecoderProfilerFunction, DecoderProfilerBind,
                                   DecoderProfilerInit);
    loader.RegisterFunction(decoder_profiler);
}

} // namespace duckdb
