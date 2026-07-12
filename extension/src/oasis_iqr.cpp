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
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
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

// Global state shared across DuckDB workers. iqr_flags is serial (MaxThreads == 1): it is one global
// blocking operator, computed once into `values` + `flags`, then sliced out by a single cursor.
struct IqrFlagsGlobalState : public GlobalTableFunctionState {
    std::mutex mutex;
    bool       computed = false;

    std::shared_ptr<libstf::Buffer> values; // decoded int64 column (N elements), for the value output
    std::shared_ptr<libstf::Buffer> flags;  // packed outlier bitmask (1 bit/element)
    size_t                          num_elements = 0;
    size_t                          cursor = 0; // next element to emit

    idx_t MaxThreads() const override { return 1; }
};

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

// Decodes the target column across every row group via the ParCore decoder and concatenates the
// decoded int64 values into one contiguous host buffer (DMA-mapped, so IqrRunner can stream it).
// Each group is one QuerySplinter (source -> decode -> sink) submitted to the scheduler and drained
// synchronously -- iqr_flags is a pipeline breaker, so we block for the whole column up front.
std::shared_ptr<libstf::Buffer> DecodeColumnAllGroups(ClientContext &context, oasis::OasisContext &ctx,
                                                      const IqrFlagsBindData &bind,
                                                      size_t &num_values_out) {
    auto &fs          = FileSystem::GetFileSystem(context);
    auto  file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);

    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {bind.filename}, parquet_opts);
    auto           meta = BuildParcoreMetadata(reader);

    const size_t col = bind.column_id;

    // Total values across all groups for this column.
    size_t total = 0;
    for (const auto &group : meta.groups) {
        total += group.chunks[col].num_values;
    }
    num_values_out = total;
    if (total == 0) {
        return nullptr;
    }

    // One contiguous int64 destination buffer for the whole column.
    size_t total_bytes = total * sizeof(int64_t);
    void  *dst         = nullptr;
    auto   st          = ctx.memory_pool()->allocate(total_bytes, &dst);
    if (!st.ok()) {
        throw IOException("iqr_flags: could not allocate value buffer: " + st.message());
    }
    ctx.tlb_manager()->ensure_tlb_mapping(dst, total_bytes);
    auto values = libstf::make_buffer(ctx.memory_pool(), dst, total_bytes, total_bytes);

    size_t off_elems = 0;
    for (size_t gi = 0; gi < meta.groups.size(); gi++) {
        const auto &group = meta.groups[gi];
        const auto &cc    = group.chunks[col];
        if (cc.num_values == 0) {
            continue;
        }
        auto type = parcore::metadata::to_libstf_type(cc.type);

        // Full byte span of the row group ([min chunk offset, max chunk end) over ALL chunks).
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

        // source -> decode -> sink, one flow.
        oasis::QuerySplinter splinter;
        oasis::OperatorFlow  flow;
        flow.push_back(MakeHostSourceCopy(ctx, fetcher.Resolve(handle)));
        flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
        auto sink = ctx.allocate_output_buffer(cc.num_values * libstf::size_of(type));
        flow.push_back(std::make_unique<oasis::LocalSinkOperator>(sink, 0));
        splinter.streams.push_back(std::move(flow));

        auto result = ctx.scheduler().submit(std::move(splinter));
        auto batch  = result.get_next_batch(); // blocks until this group is decoded
        if (!batch) {
            throw InternalException("iqr_flags: decode of row group %llu produced no output",
                                    (unsigned long long)gi);
        }

        std::memcpy(static_cast<int64_t *>(dst) + off_elems, batch->buffer->ptr,
                    cc.num_values * sizeof(int64_t));
        off_elems += cc.num_values;
    }

    return values;
}

// Computes the whole result once: decode the target column, run the IQR two passes, store the value
// buffer + packed flag bitmask into `gstate`.
void RunHeavyPhase(ClientContext &context, const IqrFlagsBindData &bind, IqrFlagsGlobalState &gstate) {
    auto &ctx = GetOrCreateOasisContext(context);

    size_t n = 0;
    gstate.values       = DecodeColumnAllGroups(context, ctx, bind, n);
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
    auto             res = runner.run({{gstate.values->ptr, n * sizeof(int64_t)}});
    gstate.flags         = res.flags;
}

unique_ptr<FunctionData> IqrFlagsBind(ClientContext &context, TableFunctionBindInput &input,
                                      vector<LogicalType> &return_types, vector<string> &names) {
    auto filename = StringValue::Get(input.inputs[0]);
    auto column   = StringValue::Get(input.inputs[1]);

    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {filename}, parquet_opts);

    // Locate the target column by name.
    auto bind_data = make_uniq<IqrFlagsBindData>();
    for (idx_t i = 0; i < reader.columns.size(); i++) {
        if (reader.columns[i].name.GetIdentifierName() == column) {
            bind_data->column_id   = i;
            bind_data->column_type = reader.columns[i].type;
            break;
        }
    }
    if (bind_data->column_id == DConstants::INVALID_INDEX) {
        throw BinderException("iqr_flags: column '%s' not found in '%s'", column, filename);
    }

    // The vFPGA top instantiates IQR_detection with 64-bit values, so only 64-bit integer columns
    // are supported. Signedness is taken from the column type and forwarded to the device.
    auto type_id = bind_data->column_type.id();
    if (type_id != LogicalTypeId::BIGINT && type_id != LogicalTypeId::UBIGINT) {
        throw BinderException(
            "iqr_flags: column '%s' must be a 64-bit integer (BIGINT or UBIGINT), but is %s", column,
            bind_data->column_type.ToString());
    }
    bind_data->filename    = filename;
    bind_data->column_name = column;
    bind_data->is_signed   = (type_id == LogicalTypeId::BIGINT);

    // Output schema: the value column, then the boolean outlier flag.
    names.push_back(column);
    return_types.push_back(bind_data->column_type);
    names.push_back("is_outlier");
    return_types.push_back(LogicalType::BOOLEAN);

    return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> IqrFlagsInitGlobal(ClientContext &, TableFunctionInitInput &) {
    return make_uniq<IqrFlagsGlobalState>();
}

void IqrFlagsFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &bind   = data_p.bind_data->Cast<IqrFlagsBindData>();
    auto &gstate = data_p.global_state->Cast<IqrFlagsGlobalState>();

    // Run the (one-time) heavy phase under the lock the first time we are called.
    {
        std::lock_guard<std::mutex> lock(gstate.mutex);
        if (!gstate.computed) {
            RunHeavyPhase(context, bind, gstate);
            gstate.computed = true;
        }
    }

    // Emit the next STANDARD_VECTOR_SIZE slice of (value, is_outlier).
    size_t remaining = gstate.num_elements - gstate.cursor;
    if (remaining == 0) {
        output.SetChildCardinality(0);
        return;
    }
    size_t emit = std::min<size_t>(remaining, STANDARD_VECTOR_SIZE);

    const int64_t *values = reinterpret_cast<const int64_t *>(gstate.values->ptr);
    const uint8_t *mask   = reinterpret_cast<const uint8_t *>(gstate.flags->ptr);

    auto &value_vec = output.data[0];
    auto &flag_vec  = output.data[1];
    value_vec.SetVectorType(VectorType::FLAT_VECTOR);
    flag_vec.SetVectorType(VectorType::FLAT_VECTOR);
    auto value_out = FlatVector::GetDataMutable<int64_t>(value_vec);
    auto flag_out  = FlatVector::GetDataMutable<bool>(flag_vec);

    for (size_t k = 0; k < emit; k++) {
        size_t i     = gstate.cursor + k;
        value_out[k] = values[i];
        // Packed bitmask: element i is byte i/8, bit i%8 (LSB-first) -- matches IQR_detection.sv.
        flag_out[k] = (mask[i >> 3] >> (i & 7)) & 1u;
    }
    gstate.cursor += emit;
    output.SetChildCardinality(emit);
}

} // namespace

void RegisterOasisIqrFunction(ExtensionLoader &loader) {
    TableFunction iqr_flags("iqr_flags",                                  // name
                            {LogicalType::VARCHAR, LogicalType::VARCHAR}, // args: file path, column
                            IqrFlagsFunction,                            // emit
                            IqrFlagsBind,                                // bind (schema)
                            IqrFlagsInitGlobal                           // global init
    );
    loader.RegisterFunction(iqr_flags);
}

} // namespace duckdb
