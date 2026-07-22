#!/bin/bash
# Stage 4a head-to-head across ALL datasets: the FULL per-row flag mask (one is_outlier per row, for
# EVERY row -- not just outliers), materialized on both sides so the comparison is apples-to-apples.
#   FPGA : iqr_flags_only(path,col)  -> boolean array straight from the packed bitmask
#   CPU  : optimized GROUP BY histogram -> divider-free quartiles -> fences -> per-row compare
# Each side runs TWICE; read the SECOND (warm) "Run Time ... real" value. Fills RESULTS.md 6.3.
#
# Needs: card flashed (build-11) + 1 GiB huge pages.
#   bash bench/stage4a_all.sh
set -u
DUCKDB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-$HOME/datasets}"
export LD_LIBRARY_PATH="$HOME/opt/lib:${LD_LIBRARY_PATH:-}"
unset OASIS_IQR_TIMING   # end-to-end wall time only, no profiler noise

DATASETS=(
  "tpch_qty:$DS/tpch_qty.parquet:v"
  "tpch_extprice:$DS/tpch_extprice.parquet:v"
  "tpch_extprice_sf10:$DS/tpch_extprice_sf10.parquet:v"
  "taxi_d1:$DS/taxi_d1.parquet:fare_cents"
  "taxi_d2:$DS/taxi_d2.parquet:fare_cents"
  "taxi_d3:$DS/taxi_d3.parquet:fare_cents"
  "taxi_d4:$DS/taxi_d4.parquet:fare_cents"
)

for entry in "${DATASETS[@]}"; do
  IFS=: read -r name path col <<<"$entry"
  [ -f "$path" ] || { echo "== $name : MISSING $path =="; continue; }
  echo "==================== $name ===================="

  echo "-- FPGA  (iqr_flags_only -> full mask)   [cold, warm] --"
  "$DUCKDB" <<SQL 2>&1 | grep -E 'Run Time'
PRAGMA threads=32;
.timer on
CREATE OR REPLACE TABLE mask AS SELECT is_outlier FROM iqr_flags_only('$path','$col');
CREATE OR REPLACE TABLE mask AS SELECT is_outlier FROM iqr_flags_only('$path','$col');
SQL

  echo "-- CPU-exact (GROUP BY -> full mask)     [cold, warm] --"
  "$DUCKDB" <<SQL 2>&1 | grep -E 'Run Time'
PRAGMA threads=32;
.timer on
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT $col::BIGINT v FROM read_parquet('$path')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT $col::BIGINT v FROM read_parquet('$path')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
SQL
  echo
done
