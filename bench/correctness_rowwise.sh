#!/bin/bash
# Comprehensive per-ROW correctness: for each dataset, checks the FPGA's actual per-row outlier flags
# against CPU-EXACT -- row-by-row, not just the outlier count. Three checks per dataset:
#   1) rowwise      -- total/agree/disagree/ppm of FPGA flag vs CPU-exact decision on every row
#   2) consistency  -- every value gets one flag (result must be 0)
#   3) disagree     -- the specific values that differ (the 1024-bin boundary band; empty = bit-exact)
#
# Run ON alveo-u55c-07 with the card flashed + 1 GiB huge pages (iqr_flags needs the FPGA).
#   export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
#   bash bench/correctness_rowwise.sh
set -u
DUCKDB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
SQLDIR="$(cd "$(dirname "$0")/sql" && pwd)"
DS="${DS:-$HOME/datasets}"

# dataset:file:column
DATASETS=(
  "tpch_qty:$DS/tpch_qty.parquet:v"
  "tpch_extprice:$DS/tpch_extprice.parquet:v"
  "taxi_d4:$DS/taxi_d4.parquet:fare_cents"
)
run() { sed -e "s#@PATH@#$2#g" -e "s#@COL@#$3#g" "$SQLDIR/$1" | "$DUCKDB" -box; }

for entry in "${DATASETS[@]}"; do
  IFS=: read -r name path col <<<"$entry"
  [ -f "$path" ] || { echo "== $name : MISSING $path =="; continue; }
  echo "==================== $name ($col) ===================="
  echo "-- per-row agreement (FPGA flag vs CPU-exact, every row) --"; run correctness_rowwise.sql       "$path" "$col"
  echo "-- FPGA internal consistency (must be 0) --";                 run correctness_consistency.sql    "$path" "$col"
  echo "-- disagreeing values (empty = bit-exact) --";               run correctness_disagree_detail.sql "$path" "$col"
done
