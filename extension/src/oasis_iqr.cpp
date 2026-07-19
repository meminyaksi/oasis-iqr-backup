#include "oasis_iqr.hpp"

#include "coalesced_fetcher.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_system.hpp"
#include "oasis/iqr_runner.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parcore_metadata_util.hpp"
#include "parquet_reader.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <limits>
#include <mutex>
#include <thread>
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
};

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
std::shared_ptr<libstf::Buffer> DecodeColumnAllGroups(ClientContext &context, oasis::OasisContext &ctx,
                                                      const IqrFlagsBindData &bind,
                                                      size_t &num_values_out, DecodeTiming &tm) {
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

    // One contiguous int64 destination buffer for the whole column. Allocated through the output-buffer
    // path so its address/capacity satisfy the hardware enqueue rules -- the slices inherit that.
    size_t total_bytes = total * sizeof(int64_t);
    auto   values      = ctx.allocate_output_buffer(total_bytes);
    void  *dst         = values->ptr;
    ctx.tlb_manager()->ensure_tlb_mapping(dst, values->capacity);

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

        // zero-copy: the sink WAS the column slice, so the values are already in place.
        if (!zero_copy) {
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

    size_t n            = 0;
    auto   t_decode     = TimingClock::now();
    gstate.values       = DecodeColumnAllGroups(context, ctx, bind, n, tm);
    double decode_ms    = ms_since(t_decode);
    gstate.num_elements = n;
    if (n == 0) {
        return; // empty column -> no rows, no flags
    }

    // OASIS_IQR_USE_CARD=1 stages the decoded column in HBM and reads both passes from card memory
    // instead of re-DMAing from the host (needs an EN_MEM bitstream). Off by default (legacy host path).
    static const bool use_card = [] {
        const char *e = std::getenv("OASIS_IQR_USE_CARD");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();

    oasis::IqrRunner runner(ctx, bind.is_signed, /*auto_window=*/true, /*bin_min=*/0, /*bin_shift=*/0,
                            use_card);
    auto             t_iqr = TimingClock::now();
    auto             res   = runner.run({{gstate.values->ptr, n * sizeof(int64_t)}});
    double           iqr_ms = ms_since(t_iqr);
    gstate.flags           = res.flags;

    if (timing_enabled()) {
        std::fprintf(stderr,
                     "[iqr] rows=%zu  groups=%zu  window=%zu  sink=%s\n"
                     "[iqr]   decode  %8.2f ms   (fpga_wait %.2f | fetch %.2f | submit %.2f | copy %.2f)\n"
                     "[iqr]   iqr     %8.2f ms   (staging %.2f | passes %.2f)\n"
                     "[iqr]   heavy   %8.2f ms   <- everything before DuckDB emits a single row\n",
                     n, tm.groups, decode_window(), tm.zero_copy ? "zero-copy" : "memcpy", decode_ms,
                     tm.wait_ms, tm.fetch_ms, tm.submit_ms, tm.copy_ms, iqr_ms, res.stage_ms,
                     res.passes_ms, ms_since(t_all));
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
    bind_data->filename    = filename;
    bind_data->column_name = column;
    bind_data->is_signed   = (type_id == LogicalTypeId::BIGINT);
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

    const uint8_t *mask = reinterpret_cast<const uint8_t *>(gstate.flags->ptr);

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
}

} // namespace duckdb
