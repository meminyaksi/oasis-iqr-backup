#!/bin/bash
# Compare three CPU-EXACT IQR formulations (same answer, different SQL), timed head-to-head.
#   1) quantile_disc   -- DuckDB's built-in discrete quantile
#   2) groupby_current -- what bench/sql/exact_count.sql does (GROUP BY + CDF, re-scan s to count)
#   3) groupby_histsum -- same quartiles, but count outliers by summing the histogram (no re-scan)
#
# Run ON alveo-u55c-07 (the extension binary inits the FPGA context on load -> needs huge pages;
# these queries are CPU-only but the binary still requires the card/driver to be up).
#   export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
#   bash bench/cpu_variants.sh taxi_d4          # or taxi_d1/d2/d3, tpch_qty, tpch_extprice[_sf10]
# Knobs: THREADS=32 WARMUP=2 REPS=5
set -u
DB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-$HOME/datasets}"
name="${1:-taxi_d4}"
case "$name" in
  taxi_d1|taxi_d2|taxi_d3|taxi_d4) path="$DS/$name.parquet"; col="fare_cents";;
  tpch_qty)                        path="$DS/tpch_qty.parquet"; col="v";;
  tpch_extprice)                   path="$DS/tpch_extprice.parquet"; col="v";;
  tpch_extprice_sf10)              path="$DS/tpch_extprice_sf10.parquet"; col="v";;
  *) echo "unknown dataset: $name"; exit 1;;
esac
threads="${THREADS:-32}"; WARMUP="${WARMUP:-2}"; REPS="${REPS:-5}"

Q_qdisc="WITH s AS (SELECT ${col}::BIGINT v FROM read_parquet('$path')),
q AS (SELECT quantile_disc(v,0.25) q1, quantile_disc(v,0.75) q3 FROM s),
f AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM q)
SELECT count(*) FROM s,f WHERE s.v<f.lo OR s.v>f.hi;"

Q_current="WITH s AS (SELECT ${col}::BIGINT v FROM read_parquet('$path')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t) q1, (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT count(*) FROM s,ef WHERE s.v<ef.lo OR s.v>ef.hi;"

Q_histsum="WITH s AS (SELECT ${col}::BIGINT v FROM read_parquet('$path')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t) q1, (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT COALESCE(sum(c),0) FROM ecnt,ef WHERE ecnt.v<ef.lo OR ecnt.v>ef.hi;"

stats(){ sort -g | awk '{a[NR]=$1} END{if(NR==0){print "NA";exit} m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; printf "median=%.4fs  min=%.4fs", m, a[1]}'; }

run_one(){
  local label="$1" q="$2"
  local cnt; cnt=$("$DB" -noheader -list -c "PRAGMA threads=$threads; $q" 2>/dev/null | tr -d '[:space:]')
  local times; times=$( { echo "PRAGMA threads=$threads;"; echo ".timer on";
      for _ in $(seq 1 $((WARMUP+REPS))); do echo "$q"; done; } \
    | "$DB" 2>&1 | grep -oE 'real [0-9.]+' | awk '{print $2}' | tail -n +"$((WARMUP+1))" )
  printf "%-20s count=%-10s " "$label" "$cnt"; echo "$times" | stats; echo
}

echo "dataset=$name  col=$col  threads=$threads  (warmup=$WARMUP reps=$REPS)"
echo "-------------------------------------------------------------------"
run_one "1 quantile_disc"    "$Q_qdisc"
run_one "2 groupby_current"  "$Q_current"
run_one "3 groupby_histsum"  "$Q_histsum"
