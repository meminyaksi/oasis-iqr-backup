#include "oasis_iqr.hpp"

#include "duckdb/common/exception.hpp"
#include "oasis/iqr_runner.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parquet_reader.hpp"

#include <algorithm>
#include <mutex>

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

// Computes the whole result once: decode the target column, run the IQR two passes, store the value
// buffer + packed flag bitmask into `gstate`. Filled in M2b.
void RunHeavyPhase(ClientContext &context, const IqrFlagsBindData &bind, IqrFlagsGlobalState &gstate) {
    // M2b plan (the ParCore decode path + IqrRunner):
    //   auto &ctx = GetOrCreateOasisContext(context);
    //   gstate.values = DecodeColumnInt64(context, ctx, bind);   // decode all row groups -> host buffer
    //   oasis::IqrRunner runner(ctx, bind.is_signed, /*auto_window=*/true);
    //   auto res = runner.run({{ gstate.values->ptr, gstate.values->size }});
    //   gstate.flags        = res.flags;
    //   gstate.num_elements = res.num_elements;
    (void)context;
    (void)bind;
    (void)gstate;
    throw NotImplementedException(
        "iqr_flags: the column-decode + IQR run is wired in M2b (needs the ParCore decode path and a "
        "co-resident IQR bitstream). The function binds and the schema is final.");
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
