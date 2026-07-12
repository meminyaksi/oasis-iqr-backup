#!/bin/bash
# End-to-end timing sweep -> CSV on stdout: dataset,rows,bytes,system,threads,median_s,min_s,reps
#
# Fairness: identical query shape per system (produce the outlier count). 2 warmup runs (discarded,
# warms OS cache + amortizes one-time FPGA context init) + REPS timed runs; we report median & min.
# DuckDB's own .timer measures each statement, so process startup is NOT in the timed region.
#
# Run ON alveo-u55c-07 (huge pages on, bitstream flashed) for the FPGA rows; CPU rows run anywhere
# with the same duckdb binary.
#   export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
#   bash bench/perf.sh | tee bench/perf_results.csv
set -u
DUCKDB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
SQLDIR="$(cd "$(dirname "$0")/sql" && pwd)"
DS="${DS:-$HOME/datasets}"
WARMUP="${WARMUP:-2}"
REPS="${REPS:-7}"
THREADS_LIST="${THREADS_LIST:-1 4 16 32}"

DATASETS=(
  "tpch_qty:$DS/tpch_qty.parquet:v"
  "taxi_d1:$DS/taxi_d1.parquet:fare_cents"
  "taxi_d2:$DS/taxi_d2.parquet:fare_cents"
  "taxi_d3:$DS/taxi_d3.parquet:fare_cents"
  "taxi_d4:$DS/taxi_d4.parquet:fare_cents"
  "tpch_extprice:$DS/tpch_extprice.parquet:v"
  "tpch_extprice_sf10:$DS/tpch_extprice_sf10.parquet:v"
)

# median + min of stdin numbers
stats() { sort -g | awk '{a[NR]=$1} END{if(NR==0){print "NA,NA";exit} m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; printf "%.6f,%.6f", m, a[1]}'; }

# time one (sql-template, path, col, threads) -> emits "median,min" over REPS (warmups dropped)
time_one() {
  local tmpl="$1" path="$2" col="$3" threads="$4"
  local q; q="$(sed -e "s#@PATH@#$path#g" -e "s#@COL@#$col#g" "$SQLDIR/$tmpl")"
  { echo "PRAGMA threads=$threads;"; echo ".timer on"
    for _ in $(seq 1 $((WARMUP+REPS))); do echo "$q"; done
  } | "$DUCKDB" 2>&1 \
    | grep -oE 'real [0-9.]+' | awk '{print $2}' \
    | tail -n +"$((WARMUP+1))" | stats
}

echo "dataset,rows,bytes,system,threads,median_s,min_s,reps"
for entry in "${DATASETS[@]}"; do
  IFS=: read -r name path col <<<"$entry"
  [ -f "$path" ] || { echo "# MISSING $path" >&2; continue; }
  bytes=$(stat -c %s "$path")
  rows=$("$DUCKDB" -noheader -list -c "SELECT count(*) FROM read_parquet('$path');" 2>/dev/null | tr -d '[:space:]')
  for t in $THREADS_LIST; do
    echo "$name,$rows,$bytes,cpu_exact,$t,$(time_one exact_count.sql "$path" "$col" "$t"),$REPS"
    echo "$name,$rows,$bytes,cpu_hist,$t,$(time_one hist_count.sql "$path" "$col" "$t"),$REPS"
  done
  # FPGA: single engine; DuckDB-side count uses max threads. iqr_flags needs the card.
  echo "$name,$rows,$bytes,fpga,32,$(time_one fpga_count.sql "$path" "$col" 32),$REPS"
done
