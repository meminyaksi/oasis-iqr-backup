#!/usr/bin/env bash
# Raw per-phase timings for BOTH operators on every dataset. No parsing, no Python -- it just runs
# duckdb and prints the [iqr] / [iqr-cpu] lines so you can read them yourself.
#
#   bench/phases.sh          # 3 timed runs per cell
#   bench/phases.sh 7        # 7 timed runs per cell
#   bench/phases.sh 3 sf10   # one dataset
#
# The FIRST run of each block is a warm-up (cold page cache) -- ignore it, read the later ones.
# Queries CONSUME the flags rather than CREATE TABLE: 92 % of a CREATE TABLE is DuckDB's
# single-threaded table append, identical on both sides (RESULTS.md 9.18).
set -u
export LD_LIBRARY_PATH="$HOME/opt/lib:${LD_LIBRARY_PATH:-}"
export OASIS_IQR_TIMING=1
export OASIS_IQR_STREAM=1
export OASIS_IQR_DECODE_WINDOW=16

DB=./extension/build/release/duckdb
DS=/home/myaksi/datasets
N=${1:-3}
ONLY=${2:-}

ALL="taxi_d1:fare_cents tpch_qty:v taxi_d2:fare_cents tpch_extprice:v \
     taxi_d3:fare_cents taxi_d4:fare_cents tpch_extprice_sf10:v"

for F in $ALL; do
  P=${F%%:*}; C=${F##*:}
  [ -n "$ONLY" ] && [ "$P" != "$ONLY" ] && continue
  [ -f "$DS/$P.parquet" ] || { echo "skip $P (missing)"; continue; }
  echo ""
  echo "################  $P  ################"
  for IMPL in iqr_flags_only iqr_cpu_flags; do
    echo "----------------  $IMPL"
    {
      echo "PRAGMA threads=32;"
      echo ".timer on"
      for i in $(seq 0 "$N"); do
        echo "SELECT count(*) FILTER (WHERE is_outlier) FROM $IMPL('$DS/$P.parquet','$C');"
      done
    } | timeout 300 $DB 2>&1 | grep -E '^\[iqr|Run Time|Error'
  done
done
