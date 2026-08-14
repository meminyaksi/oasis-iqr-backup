#!/bin/bash
# PER-ROW correctness of the FUSED / streaming path (obstacle-1 validation).
#
# correctness_3way.sh can only test the MEMCPY path: it uses iqr_flags, which echoes each row's value
# and therefore must gather the column contiguously (never streams). Only iqr_flags_only streams/fuses,
# but it emits just the bitmask -- so to check it PER ROW we align its flags with the column values by
# FILE ORDER, using each table's implicit rowid (0..N-1 in insertion order for a fresh, un-mutated table).
#
# A bit-shift mislabel (the ragged-packer failure mode: byte-padding shifts every subsequent flag) is
# COUNT-PRESERVING, so a matching net count does NOT prove per-row correctness. This counts actual
# per-row disagreements against the C++-exact fence (correctness_3way_fences.sql's GROUP-BY quartile).
#
# CRITICAL: the FPGA function is materialized ALONE -- a bare CREATE TABLE AS with NO window / GROUP BY /
# join on top (those deadlock the no-timeout receiver; a plain streaming sink does not). All alignment
# and comparison happen afterwards over PLAIN TABLES, no FPGA in the pipeline.
#
# Usage (ON the FPGA node):
#   export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
#   bench/fused_perrow.sh                        # taxi_d3 + taxi_d4 (the sets that fuse: >10M rows)
#   DATASETS_ONLY="taxi_d3" bench/fused_perrow.sh
#
# threads=1 for the two ORDER-SENSITIVE materializes (so rowid == file order); the comparison can run
# full-threads (order-independent). NEVER Ctrl-C an FPGA query -- let the timeout fire.
set -u

DUCKDB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-$HOME/datasets}"
TMPDB="${TMPDB:-/tmp/fused_perrow.$$.db}"
TIMEOUT="${TIMEOUT:-300}"

# The fused recipe: ragged stitch + FPGA window (IQR rule). 4096 bins are baked into the bitstream.
export OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 \
       OASIS_IQR_STREAM_RAGGED=1 OASIS_IQR_WINDOW_IQR=1

DATASETS=(
  "taxi_d3:$DS/taxi_d3.parquet:fare_cents"
  "taxi_d4:$DS/taxi_d4.parquet:fare_cents"
)
want() { [ -z "${DATASETS_ONLY:-}" ] && return 0; case " $DATASETS_ONLY " in *" $1 "*) return 0;; *) return 1;; esac; }

if pgrep -x duckdb >/dev/null; then
  echo "ABORT: a duckdb process is already running -- two on one vFPGA can wedge the card." >&2
  exit 1
fi

for entry in "${DATASETS[@]}"; do
  IFS=: read -r name path col <<<"$entry"
  want "$name" || continue
  echo "==================== $name ($col) ===================="
  rm -f "$TMPDB"

  # PHASE 1 -- FPGA, ISOLATED. Bare CREATE TABLE AS over iqr_flags_only: a plain streaming sink, NO
  # window/join/aggregate on top (that is what deadlocks). ff.rowid == emission order == file order.
  if ! timeout "$TIMEOUT" "$DUCKDB" "$TMPDB" -c \
      "PRAGMA threads=1;
       CREATE TABLE ff AS SELECT is_outlier AS f FROM iqr_flags_only('$path','$col');"; then
    echo "!! FPGA materialize failed/timed out on $name (card left intact by timeout)"; rm -f "$TMPDB"; continue
  fi

  # PHASE 2a -- PURE SQL, threads=1 so cc.rowid == file order (matches ff.rowid).
  "$DUCKDB" "$TMPDB" -c \
    "PRAGMA threads=1;
     CREATE TABLE cc AS SELECT ${col}::BIGINT AS v FROM read_parquet('$path');"

  # PHASE 2b -- PURE SQL, no FPGA. Recompute the C++-exact fence, join flags to values on rowid, count
  # per-row disagreements. net_diff vs per_row_mismatch is the whole point:
  #   per_row_mismatch ~= net_diff  -> threshold-consistent (binning at the fence only): OK, taxi fuses.
  #   per_row_mismatch >> net_diff  -> compensating swaps / bit-shift mislabel: obstacle-1 NOT fixed.
  "$DUCKDB" "$TMPDB" -box -c \
    "WITH
     ecnt AS (SELECT v, count(*) c FROM cc GROUP BY v),
     etot AS (SELECT sum(c) t FROM ecnt),
     ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
     g    AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                     (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
     gf   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM g),
     j    AS (SELECT ff.f AS f, cc.v AS v FROM ff JOIN cc ON ff.rowid = cc.rowid)
     SELECT
       count(*)                                                  AS rows,
       count(*) FILTER (WHERE j.f)                               AS n_fpga,
       count(*) FILTER (WHERE j.v < gf.lo OR j.v > gf.hi)        AS n_cpp,
       abs(count(*) FILTER (WHERE j.f)
           - count(*) FILTER (WHERE j.v < gf.lo OR j.v > gf.hi)) AS net_diff,
       count(*) FILTER (WHERE j.f <> (j.v < gf.lo OR j.v > gf.hi)) AS per_row_mismatch
     FROM j, gf;"
  rm -f "$TMPDB"
done
echo "==================== done ===================="
