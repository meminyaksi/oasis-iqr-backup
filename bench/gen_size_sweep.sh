#!/bin/bash
# SIZE-SWEEP DATASET GENERATOR -- synthetic INT64 columns, 1M .. 100M rows, everything except ROW
# COUNT held constant, for the microbenchmark that isolates the effect of input size on runtime.
#
# WHY SYNTHETIC. The 7 real datasets differ in size AND cardinality AND encoding AND row-group
# geometry simultaneously, so a "size" plot over them confounds four variables. Here only N moves.
#
# DATA SHAPE -- deliberately HIGH CARDINALITY, not low. Real columns that contain outliers are
# high-cardinality with noise (measured: extprice 934k distinct, sf10 1.35M; only tpch_qty is low at
# 50). A low-cardinality column would also let DuckDB pick a small dictionary, making the sweep a
# measurement of dictionary decode rather than of size. So:
#   base value : hash(i) % CARD          -> ~CARD distinct, high entropy, STATIONARY (no drift, so a
#                                           sampled window is valid and results are reproducible)
#   outliers   : every OUTLIER_EVERY-th row gets +OUTLIER_OFFSET
#
# CARD IS FIXED IN ABSOLUTE TERMS across the sweep (default 1,000,000 ~ sf10's 1.35M). Consequence
# worth knowing: at N=1M the column is ~all-distinct, at N=100M each value repeats ~100x. The
# distinct COUNT is what is held fixed, not the distinct RATIO -- fixing the ratio instead would grow
# the dictionary with N and eventually flip the encoding, which would confound the very thing we are
# measuring. The script prints actual cardinality, encoding and bytes/row per file so any drift is
# visible in the output rather than hidden.
#
# WHY THE OUTLIERS SIT IN AN EMPTY GAP. base spans [0, CARD) = [0, 1e6); with a uniform base the
# fences land at ~[-500k, 1.5e6]. Outliers are placed at +5e6, i.e. in [5e6, 6e6) -- far outside the
# fence, with NOTHING in between. So no value lies near a fence, and the FPGA's 4096-bin quantisation
# (which resolves the window to ~610) CANNOT change any row's verdict. Expected flags is therefore
# EXACTLY N/OUTLIER_EVERY at every size, so the sweep self-checks: any deviation is a real bug, never
# a binning artefact.
#
# ROW_GROUP_SIZE 122880 is mandatory-ish: it is a multiple of 8, and a non-final row group whose
# num_values % 8 != 0 makes the host's ragged guard reject streaming and silently fall back to the
# memcpy path -- which would change the code path mid-sweep. Generated from range() rather than by
# re-writing an existing parquet, because COPY preserves the SOURCE row-group layout (that is how
# taxi_d4_dd ended up with odd 51449/124849 groups).
#
# Usage:
#   bench/gen_size_sweep.sh                 # default sizes, CARD=1e6, 0.1% outliers
#   SIZES="1 10 100" bench/gen_size_sweep.sh        # in millions
#   CARD=5000000 OUTLIER_EVERY=10000 bench/gen_size_sweep.sh
#   bench/gen_size_sweep.sh verify          # re-print the metadata table without regenerating
set -u

DB="${DB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-/home/myaksi/datasets/sizesweep}"

SIZES="${SIZES:-1 3 6 10 20 40 60 80 100}"     # millions of rows
CARD="${CARD:-1000000}"                        # distinct base values, FIXED across the sweep
OUTLIER_EVERY="${OUTLIER_EVERY:-1000}"         # 1 in N rows is an outlier -> 0.1%
OUTLIER_OFFSET="${OUTLIER_OFFSET:-5000000}"    # lands far outside the fence, in an empty gap
RGS="${RGS:-122880}"                           # row-group size; MUST be a multiple of 8

mkdir -p "$DS"
[[ -x "$DB" ]] || { echo "duckdb not found/executable: $DB" >&2; exit 2; }
if (( RGS % 8 != 0 )); then echo "ROW_GROUP_SIZE $RGS is not a multiple of 8 -- refusing" >&2; exit 2; fi

metadata_table() {
    for m in $SIZES; do
        f="$DS/size_${m}M.parquet"
        [[ -f "$f" ]] || continue
        rows=$(( m * 1000000 ))
        exp=$(( rows / OUTLIER_EVERY ))
        bytes=$(stat -c %s "$f")
        # encodings/group geometry from the footer; cardinality approximated (exact is O(N) and this
        # is only a sanity annotation for the plot).
        $DB -noheader -list -c "
          SELECT
            '$(basename "$f")' || '  rows=$rows' ||
            '  file=' || printf('%.1f', $bytes/1048576.0) || 'MB' ||
            '  bytes/row=' || printf('%.2f', $bytes*1.0/$rows) ||
            '  distinct~' || (SELECT approx_count_distinct(v) FROM read_parquet('$f')) ||
            '  expect_outliers=$exp' ||
            '  groups=' || (SELECT count(*) FROM parquet_metadata('$f')) ||
            '  min_group=' || (SELECT min(num_values) FROM parquet_metadata('$f')) ||
            '  min_group%8=' || (SELECT min(num_values) % 8 FROM parquet_metadata('$f')) ||
            '  enc=' || (SELECT DISTINCT encodings FROM parquet_metadata('$f') LIMIT 1);"
    done
}

if [[ "${1:-}" == "verify" ]]; then
    echo "=== size-sweep datasets in $DS ==="
    metadata_table
    echo
    echo "GATES: min_group%8 must be 0 on every file (else streaming falls back to memcpy),"
    echo "       and enc must be IDENTICAL across all files (else the sweep measures encoding, not size)."
    exit 0
fi

echo "=== generating size-sweep datasets into $DS ==="
echo "    CARD=$CARD (fixed)  outliers=1/$OUTLIER_EVERY (+$OUTLIER_OFFSET)  ROW_GROUP_SIZE=$RGS"
echo

for m in $SIZES; do
    rows=$(( m * 1000000 ))
    f="$DS/size_${m}M.parquet"
    if [[ -f "$f" && -z "${FORCE:-}" ]]; then
        echo "  size_${m}M.parquet exists (FORCE=1 to regenerate) -- skipping"
        continue
    fi
    echo "  writing size_${m}M.parquet  ($rows rows) ..."
    # hash(i) is DuckDB-native, high-entropy and non-periodic-looking -- preferred over the i*PRIME
    # trick used by overlap_ab.sh, whose period would be exactly CARD and could make Snappy compress
    # the large files unusually well, drifting bytes/row across the sweep.
    $DB -c "
      COPY (SELECT (hash(i) % $CARD)::BIGINT
                   + CASE WHEN i % $OUTLIER_EVERY = 0 THEN $OUTLIER_OFFSET ELSE 0 END AS v
            FROM range($rows) t(i))
      TO '$f' (FORMAT PARQUET, ROW_GROUP_SIZE $RGS);" || { echo "  !! failed on ${m}M" >&2; exit 1; }
done

echo
echo "=== metadata ==="
metadata_table
echo
echo "GATES: min_group%8 must be 0 on every file (else streaming falls back to memcpy),"
echo "       and enc must be IDENTICAL across all files (else the sweep measures encoding, not size)."
echo
echo "disk used: $(du -sh "$DS" | cut -f1)"
echo "next: python3 bench/size_sweep.py"
