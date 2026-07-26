#!/usr/bin/env bash
# Full FPGA-vs-CPU measurement campaign. Run ON the FPGA node (alveo-u55c-XX).
#
#   bench/measure_all.sh <outdir> [n]                  # safe: index mode OFF everywhere
#   IQR_MEASURE_IDX=1 bench/measure_all.sh <outdir> [n] # ALSO run the index-mode steps
#
# INDEX MODE IS OPT-IN AND DANGEROUS. On build-20 it produces 2 spurious flags on sf10
# (alveo-u55c-10) and DEADLOCKS THE HOST (alveo-u55c-09) -- `BypassStreamReceiver::next()` waits on a
# condition variable with no timeout, so a bad beat count hangs until `timeout` fires and can leave the
# card needing a reflash. RESULTS.md 9.23 / 9.27. Do not enable it to "just check" it.
#
# Every FPGA invocation is wrapped in `timeout`. NEVER Ctrl-C an FPGA query.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?usage: measure_all.sh <outdir> [n]   (IQR_MEASURE_IDX=1 to include index mode)}
N=${2:-15}
IDX_ON=${IQR_MEASURE_IDX:-0}
mkdir -p "$OUT"
export LD_LIBRARY_PATH=$HOME/opt/lib:${LD_LIBRARY_PATH:-}
DUCKDB=./extension/build/release/duckdb
DS=/home/myaksi/datasets
SF10=$DS/tpch_extprice_sf10.parquet

BASE="OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 OASIS_IQR_DECODE_WINDOW=16"
IDX="OASIS_IQR_IDX_PASS2=1"

# Refuse to share the card: two concurrent processes on one vFPGA is a wedge waiting to happen.
if pgrep -x duckdb > /dev/null; then
    echo "ABORT: a duckdb process is already running (pid $(pgrep -x duckdb | tr '\n' ' '))." >&2
    echo "Wait for it, or kill it, before touching the card." >&2
    exit 1
fi

step() { echo; echo "########## $* ##########"; }
run()  { echo "\$ $*"; eval "$@"; echo "[exit $?]"; }

{
echo "measure_all.sh  host=$(hostname -s)  date=$(date -Is)  n=$N  index_mode=$IDX_ON"
echo "geometry: $(grep -m1 'IQR_CPU_HIST_BINS = ' extension/src/oasis_iqr.cpp)"
echo "          $(grep -m1 'using IqrHistCount' extension/src/oasis_iqr.cpp)"
echo "cpu alloc: $(grep -m1 -o 'out.reset(new int64_t\[total\])\|out = Allocator::Get' extension/src/oasis_iqr.cpp)"
echo "binary:   $(stat -c '%y %s' $DUCKDB)"
echo "hugepages(1G): total=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages) free=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages)"

step "0. card alive + decoder lanes"
run "timeout 60 $DUCKDB -c \"SELECT decoder FROM decoder_profiler();\""

step "1. SMOKE: taxi_d1 must be 317554, pass1=fused only above 10M rows"
run "env $BASE OASIS_IQR_TIMING=1 timeout 120 $DUCKDB -c \
  \"SELECT count(*) FILTER (WHERE is_outlier) AS n FROM iqr_flags_only('$DS/taxi_d1.parquet','fare_cents');\" 2>&1 | grep -E '^\[iqr\]|^.[[:space:]]*[0-9]+[[:space:]]*.$'"

step "2. ENGAGE: sf10, index OFF (expect pass1=fused, passes ~38, heavy ~139)"
run "env $BASE OASIS_IQR_TIMING=1 timeout 200 $DUCKDB -c \
  \"SELECT count(*) FILTER (WHERE is_outlier) AS n FROM iqr_flags_only('$SF10','v');\" 2>&1 | grep -E '^\[iqr|^.[[:space:]]*[0-9]+[[:space:]]*.$'"

step "3. CPU baseline phases on sf10 -- histogram zoom"
run "env OASIS_IQR_TIMING=1 timeout 400 $DUCKDB -c \
  \"PRAGMA threads=32; SELECT count(*) FILTER (WHERE is_outlier) AS n FROM iqr_cpu_flags('$SF10','v');\" 2>&1 | grep -E '^\[iqr-cpu\]'"

step "4. CPU baseline phases on sf10 -- direct SQL transliteration (RESULTS.md 9.29)"
run "env OASIS_IQR_TIMING=1 timeout 600 $DUCKDB -c \
  \"PRAGMA threads=32; SELECT count(*) FILTER (WHERE is_outlier) AS n FROM iqr_cpu_flags_groupby('$SF10','v');\" 2>&1 | grep -E '^\[iqr-cpu-gb\]'"

step "5. ACCURACY GATE (window), index OFF -- all four numbers must be 200"
run "env OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 timeout 900 bench/overlap_ab.sh accuracy"

step "6. CORRECTNESS GATE, index OFF (d1 317554 d2 625445 d3 1328108 d4 2112164 qty 0 ext 0 sf10 0)"
run "env $BASE timeout 1200 $DUCKDB < bench/sql/cpu_op_correctness.sql"

step "7. CORRECTNESS: the two CPU baselines must agree exactly (9.29)"
run "timeout 900 $DUCKDB -c \"PRAGMA threads=32;
  SELECT 'taxi_d1' d,
    (SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags_groupby('$DS/taxi_d1.parquet','fare_cents')) gb,
    (SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags('$DS/taxi_d1.parquet','fare_cents')) zoom
  UNION ALL SELECT 'taxi_d4',
    (SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags_groupby('$DS/taxi_d4.parquet','fare_cents')),
    (SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags('$DS/taxi_d4.parquet','fare_cents'))
  UNION ALL SELECT 'tpch_qty',
    (SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags_groupby('$DS/tpch_qty.parquet','v')),
    (SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags('$DS/tpch_qty.parquet','v'))
  UNION ALL SELECT 'sf10',
    (SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags_groupby('$SF10','v')),
    (SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags('$SF10','v'));\""

step "8. MEDIANS, index OFF, cpp arm = histogram zoom, n=$N"
run "env $BASE timeout 5400 python3 bench/medians.py --consume -n $N --stats --cpp-impl zoom"

step "9. MEDIANS, index OFF, cpp arm = SQL transliteration, n=$N"
run "env $BASE timeout 5400 python3 bench/medians.py --consume -n $N --stats --cpp-impl groupby"

if [ "$IDX_ON" = "1" ]; then
    step "10. INDEX MODE (OPT-IN, KNOWN TO HANG -- see the header of this script)"
    run "env $BASE $IDX OASIS_IQR_TIMING=1 timeout 200 $DUCKDB -c \
      \"SELECT count(*) FILTER (WHERE is_outlier) AS n FROM iqr_flags_only('$SF10','v');\" 2>&1 | grep -E '^\[iqr|^.[[:space:]]*[0-9]+[[:space:]]*.$'"
    step "11. INDEX MODE accuracy gate (OPT-IN)"
    run "env OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 $IDX timeout 900 bench/overlap_ab.sh accuracy"
    step "12. INDEX MODE correctness gate (OPT-IN)"
    run "env $BASE $IDX timeout 1200 $DUCKDB < bench/sql/cpu_op_correctness.sql"
    step "13. INDEX MODE medians (OPT-IN)"
    run "env $BASE $IDX timeout 5400 python3 bench/medians.py --consume -n $N --stats"
else
    echo
    echo "########## index-mode steps SKIPPED (set IQR_MEASURE_IDX=1 to include them) ##########"
fi

echo; echo "########## DONE $(date -Is) ##########"
} 2>&1 | tee "$OUT/measure_all.log"
