#!/bin/bash
# FPGA-only end-to-end timing (fills the rows perf.sh left NA). Same method: 2 warmup + REPS timed,
# DuckDB .timer per statement. Run ON alveo-u55c-07 (huge pages on, bitstream flashed).
#   export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
#   bash bench/perf_fpga.sh | tee bench/perf_fpga.csv
set -u
DUCKDB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
SQLDIR="$(cd "$(dirname "$0")/sql" && pwd)"
DS="${DS:-$HOME/datasets}"
WARMUP="${WARMUP:-2}"; REPS="${REPS:-7}"
DATASETS=(
  "tpch_qty:$DS/tpch_qty.parquet:v"
  "taxi_d1:$DS/taxi_d1.parquet:fare_cents"
  "taxi_d2:$DS/taxi_d2.parquet:fare_cents"
  "taxi_d3:$DS/taxi_d3.parquet:fare_cents"
  "taxi_d4:$DS/taxi_d4.parquet:fare_cents"
  "tpch_extprice:$DS/tpch_extprice.parquet:v"
  "tpch_extprice_sf10:$DS/tpch_extprice_sf10.parquet:v"
)
stats() { sort -g | awk '{a[NR]=$1} END{if(NR==0){print "NA,NA";exit} m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; printf "%.6f,%.6f", m, a[1]}'; }
echo "dataset,rows,bytes,system,threads,median_s,min_s,reps"
for entry in "${DATASETS[@]}"; do
  IFS=: read -r name path col <<<"$entry"
  [ -f "$path" ] || { echo "# MISSING $path" >&2; continue; }
  bytes=$(stat -c %s "$path")
  rows=$("$DUCKDB" -noheader -list -c "SELECT count(*) FROM read_parquet('$path');" 2>/dev/null | tr -d '[:space:]')
  q="$(sed -e "s#@PATH@#$path#g" -e "s#@COL@#$col#g" "$SQLDIR/fpga_count.sql")"
  ms=$({ echo "PRAGMA threads=32;"; echo ".timer on"; for _ in $(seq 1 $((WARMUP+REPS))); do echo "$q"; done; } \
        | "$DUCKDB" 2>&1 | grep -oE 'real [0-9.]+' | awk '{print $2}' | tail -n +"$((WARMUP+1))" | stats)
  echo "$name,$rows,$bytes,fpga,32,$ms,$REPS"
done
