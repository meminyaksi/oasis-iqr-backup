#!/bin/bash
# Timing A/B of outlier-detection methods, CPU only (NO FPGA datapath -> safe, no hang risk).
# Every method EMITS a per-row is_outlier flag; `count(*) FILTER (WHERE is_outlier)` forces the whole flag
# array to be produced, then aggregates it (same --consume methodology as medians.py; excludes the
# table-append tax). Times are DuckDB's own `.timer` real seconds; first run per method is the warm-up.
#
#   bench/methods_ab.sh [dataset ...]      default: taxi_d1 sf10
#   (datasets: taxi_d1 taxi_d2 taxi_d3 taxi_d4 tpch_qty tpch_extprice sf10)
#
# NOTE: z-score (mean +/- 3 sigma) is a DIFFERENT rule than IQR -- it flags different rows. This compares
# COST, not results. quantile_cont = exact built-in; approx_quantile = t-digest (fast, approximate);
# groupby CDF = the SQL our C++ transliterates; iqr_cpu_flags_groupby = our C++ operator.
set -u
D="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-$HOME/datasets}"
export LD_LIBRARY_PATH=$HOME/opt/lib:${LD_LIBRARY_PATH:-}
REPS="${REPS:-3}"                 # runs per method (first is warm-up)
sel=("$@"); [ ${#sel[@]} -eq 0 ] && sel=(taxi_d1 sf10)

col_of() { case "$1" in taxi_*) echo fare_cents;; *) echo v;; esac; }
path_of(){ case "$1" in sf10) echo "$DS/tpch_extprice_sf10.parquet";; *) echo "$DS/$1.parquet";; esac; }

if pgrep -x duckdb >/dev/null; then echo "ABORT: a duckdb is already running." >&2; exit 1; fi

for name in "${sel[@]}"; do
  p=$(path_of "$name"); c=$(col_of "$name")
  [ -f "$p" ] || { echo "== $name MISSING $p =="; continue; }
  echo; echo "==================== $name ($c) ===================="

  # Build one SQL script: each method labeled, run $REPS times with .timer on.
  gen() { # $1 = label   $2 = inner SELECT that yields column is_outlier
    echo "SELECT '>>> $1';"
    for _ in $(seq "$REPS"); do echo "SELECT count(*) FILTER (WHERE is_outlier) FROM ($2);"; done
  }
  {
    echo ".timer on"
    echo "PRAGMA threads=32;"
    gen "zscore (avg/stddev)" \
      "SELECT (abs(t.$c - s.mu) > 3*s.sigma) AS is_outlier
         FROM read_parquet('$p') t,
              (SELECT avg($c) mu, stddev_pop($c) sigma FROM read_parquet('$p')) s"
    gen "IQR exact (quantile_cont)" \
      "SELECT (t.$c < s.q1-1.5*(s.q3-s.q1) OR t.$c > s.q3+1.5*(s.q3-s.q1)) AS is_outlier
         FROM read_parquet('$p') t,
              (SELECT quantile_cont($c,0.25) q1, quantile_cont($c,0.75) q3 FROM read_parquet('$p')) s"
    gen "IQR approx (approx_quantile)" \
      "SELECT (t.$c < s.q1-1.5*(s.q3-s.q1) OR t.$c > s.q3+1.5*(s.q3-s.q1)) AS is_outlier
         FROM read_parquet('$p') t,
              (SELECT approx_quantile($c,0.25) q1, approx_quantile($c,0.75) q3 FROM read_parquet('$p')) s"
    gen "IQR our SQL (groupby CDF)" \
      "WITH s AS MATERIALIZED (SELECT $c::BIGINT v FROM read_parquet('$p')),
         ecnt AS (SELECT v,count(*) c FROM s GROUP BY v),
         etot AS (SELECT sum(c) t FROM ecnt),
         ecum AS (SELECT v,sum(c) OVER (ORDER BY v) cc FROM ecnt),
         eq AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t) q1,(SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
         ef AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
       SELECT (s.v<ef.lo OR s.v>ef.hi) AS is_outlier FROM s,ef"
    gen "IQR our C++ (iqr_cpu_flags_groupby)" \
      "SELECT is_outlier FROM iqr_cpu_flags_groupby('$p','$c')"
  } | "$D" 2>&1 | grep -E '^>>>|Run Time|^[0-9]+$|Error'
done
echo; echo "==================== done ===================="
