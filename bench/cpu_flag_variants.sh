#!/bin/bash
# CPU-exact FLAG-ARRAY implementation sweep: times all 5 quartile methods
# (bench/sql/cpu_variants/approach{1..5}.sql) on each dataset and prints the quartile cross-check.
# All five produce the IDENTICAL flag array (the useful product); only the Q1/Q3 computation differs,
# so the timing spread = quartile-compute cost. (Distinct from the older cpu_variants.sh, which compared
# three COUNT-only formulations.)
#
# Low-card result (tpch_qty, warm, 2026-07-19): A1 0.092 (winner) < A5 0.380 < A2 0.603 < A3 0.733 < A4 3.381.
# Dropping GROUP BY is a pessimization on low card (loses the N->distinct collapse). High-card sweep pending.
#
# Run from a plain DuckDB CLI (no FPGA needed -- these are CPU-only baselines):
#   bash bench/cpu_flag_variants.sh
DUCKDB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
SQLDIR="$(cd "$(dirname "$0")/sql/cpu_variants" && pwd)"
DS="${DS:-$HOME/datasets}"

# dataset:file:column
DATASETS=(
  "tpch_qty:$DS/tpch_qty.parquet:v"
  "tpch_extprice:$DS/tpch_extprice.parquet:v"
  "taxi_d4:$DS/taxi_d4.parquet:fare_cents"
)

# Run each variant twice (cold+warm); report both Run Time lines (second = warm). PRAGMA threads=32, .timer on.
runsql() { sed -e "s#@PATH@#$2#g" -e "s#@COL@#$3#g" "$SQLDIR/$1"; }

for entry in "${DATASETS[@]}"; do
  IFS=: read -r name path col <<<"$entry"
  [ -f "$path" ] || { echo "== $name : MISSING $path =="; continue; }
  echo "==================== $name ($col) ===================="
  for i in 1 2 3 4 5; do
    echo "-- approach $i (cold, warm) --"
    { echo "PRAGMA threads=32;"; echo ".timer on"; runsql "approach$i.sql" "$path" "$col"; runsql "approach$i.sql" "$path" "$col"; } \
      | "$DUCKDB" 2>&1 | grep -E 'Run Time'
  done
  echo "-- quartile cross-check (gb/qd/pd/rn must match; approx may differ) --"
  runsql "correctness.sql" "$path" "$col" | "$DUCKDB" -box
done
