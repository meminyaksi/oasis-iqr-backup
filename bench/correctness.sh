#!/bin/bash
# Correctness sweep: for each dataset prints CPU (exact vs hist-1024) metrics and, if the FPGA is
# available, the FPGA-vs-exact metrics. Output is copy-paste friendly (one labelled block per set).
#
# Run ON alveo-u55c-07 with huge pages enabled + bitstream flashed (iqr_flags needs the FPGA).
#   export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
#   bash bench/correctness.sh
set -u
DUCKDB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
SQLDIR="$(cd "$(dirname "$0")/sql" && pwd)"
DS="${DS:-$HOME/datasets}"

# dataset:file:column   (edit to taste)
DATASETS=(
  "tpch_qty:$DS/tpch_qty.parquet:v"
  "taxi_d1:$DS/taxi_d1.parquet:fare_cents"
  "taxi_d2:$DS/taxi_d2.parquet:fare_cents"
  "taxi_d3:$DS/taxi_d3.parquet:fare_cents"
  "taxi_d4:$DS/taxi_d4.parquet:fare_cents"
  "tpch_extprice:$DS/tpch_extprice.parquet:v"
  "tpch_extprice_sf10:$DS/tpch_extprice_sf10.parquet:v"
)
run() { sed -e "s#@PATH@#$2#g" -e "s#@COL@#$3#g" "$SQLDIR/$1" | "$DUCKDB" -box; }

for entry in "${DATASETS[@]}"; do
  IFS=: read -r name path col <<<"$entry"
  [ -f "$path" ] || { echo "== $name : MISSING $path =="; continue; }
  echo "==================== $name ($col) ===================="
  echo "-- CPU: exact vs hist-1024 --";            run correctness_cpu.sql  "$path" "$col"
  echo "-- FPGA: iqr_flags vs exact (needs card) --"; run correctness_fpga.sql "$path" "$col"
done
