#!/bin/bash
# END-TO-END TIME SWEEP -- all 7 datasets, build-21 SHIPPING config (index mode OFF, the value path).
#
# Confirms the FPGA-vs-CPU speedup holds on the current build before investing in index mode. Runs the
# established methodology (RESULTS.md 9.35): medians of N warm runs, C++ arm = iqr_cpu_flags_groupby
# (the fair, SQL-exact baseline), against DuckDB's built-in SQL. Reports END-TO-END, OPERATOR (heavy),
# and CPU-SECONDS. Both benchmarks per the "report BOTH" rule:
#   --consume     : aggregate the flags (isolates the operators)      <- primary
#   (default)     : CREATE TABLE (what a user typing SQL experiences) <- realistic e2e
#
# Shipping defaults are ON by build (WINDOW_IQR, STREAM_RAGGED, fuse_min_rows=30M so taxi stays memcpy);
# index mode is OFF unless OASIS_IQR_IDX_PASS2 is set, and we explicitly clear it here.
#
# Usage (ON the FPGA node):
#   bench/e2e_sweep.sh              # N=15
#   N=7 bench/e2e_sweep.sh          # quicker
set -u

export LD_LIBRARY_PATH="$HOME/opt/lib:${LD_LIBRARY_PATH:-}"
unset OASIS_IQR_IDX_PASS2 OASIS_IQR_STREAM OASIS_IQR_FUSE OASIS_IQR_WINDOW_FPGA   # value path, defaults

N="${N:-15}"
LOG="${LOG:-$HOME/oasis/bench/e2e_sweep_$(date +%Y%m%d_%H%M%S).log}"

if pgrep -x duckdb >/dev/null; then
  echo "ABORT: a duckdb process is already running -- two on one vFPGA can wedge the card." >&2
  exit 1
fi

# Warm the page cache so the first timed run is not penalised for cold reads.
for f in taxi_d1 taxi_d2 taxi_d3 taxi_d4 tpch_qty tpch_extprice tpch_extprice_sf10; do
  cat "$HOME/datasets/$f.parquet" >/dev/null 2>&1 || true
done

run() {
  echo "======================================================================"
  echo "$1"
  echo "======================================================================"
  shift
  python3 "$HOME/oasis/bench/medians.py" "$@"
}

{
  echo "build-21 e2e sweep -- $(date)  node=$(hostname)  N=$N  index=OFF"
  run "CONSUME (operator-isolated)"      --consume -n "$N" --cpp-impl groupby
  echo
  run "CREATE TABLE (realistic e2e)"               -n "$N" --cpp-impl groupby
} 2>&1 | tee "$LOG"

echo
echo "saved: $LOG"
