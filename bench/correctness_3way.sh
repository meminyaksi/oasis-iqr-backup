#!/bin/bash
# THREE-WAY CORRECTNESS: FPGA  vs  our C++ CPU-exact (iqr_cpu_flags_groupby)  vs  DuckDB built-in quantile.
#
# Two checks per dataset:
#   quartiles  -- correctness_3way_quartiles.sql : built-in quantile_disc vs our GROUP BY quartile, and
#                 floor(1.5*IQR) vs textbook 1.5*IQR outlier counts. Fast, full threads, NO FPGA needed.
#   flags      -- correctness_3way_builtin.sql   : per-ROW three-way flag comparison. Value-carried +
#                 PARALLEL (no threads=1, no positional join, FPGA touched once). NEEDS bitstream + huge
#                 pages. Fast -- seconds even on sf10.
#
# Usage (run ON the FPGA node for `flags`/`all`; `quartiles` runs anywhere):
#   export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
#   bench/correctness_3way.sh quartiles      # oracle-vs-ours quartile check, no card
#   bench/correctness_3way.sh flags          # the line-by-line flag comparison (needs card)
#   bench/correctness_3way.sh all            # both  (default)
#   DATASETS_ONLY="taxi_d1 sf10" bench/correctness_3way.sh flags   # restrict the set
#
# Every FPGA / positional query is wrapped in `timeout`. NEVER Ctrl-C an FPGA query -- it can wedge the
# card (no inter-process reset). Let the timeout fire.
set -u
MODE="${1:-all}"
DUCKDB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
SQLDIR="$(cd "$(dirname "$0")/sql" && pwd)"
DS="${DS:-$HOME/datasets}"
TIMEOUT_FLAGS="${TIMEOUT_FLAGS:-300}"    # per-dataset cap; the value-carried check is parallel + fast

# name:file:column   -- taxi first (the sets that can actually fail), sf10 last (slow single-threaded).
DATASETS=(
  "taxi_d1:$DS/taxi_d1.parquet:fare_cents"
  "taxi_d2:$DS/taxi_d2.parquet:fare_cents"
  "taxi_d3:$DS/taxi_d3.parquet:fare_cents"
  "taxi_d4:$DS/taxi_d4.parquet:fare_cents"
  "tpch_qty:$DS/tpch_qty.parquet:v"
  "tpch_extprice:$DS/tpch_extprice.parquet:v"
  "sf10:$DS/tpch_extprice_sf10.parquet:v"
)

if pgrep -x duckdb >/dev/null; then
  echo "ABORT: a duckdb process is already running (pid $(pgrep -x duckdb | tr '\n' ' ')). Two processes"
  echo "       on one vFPGA can wedge the card. Wait for it or kill it first." >&2
  exit 1
fi

want() { [ -z "${DATASETS_ONLY:-}" ] && return 0; case " $DATASETS_ONLY " in *" $1 "*) return 0;; *) return 1;; esac; }
sub()  { sed -e "s#@PATH@#$1#g" -e "s#@COL@#$2#g" "$SQLDIR/$3"; }

for entry in "${DATASETS[@]}"; do
  IFS=: read -r name path col <<<"$entry"
  want "$name" || continue
  [ -f "$path" ] || { echo "== $name : MISSING $path =="; continue; }
  echo
  echo "==================== $name ($col) ===================="

  if [ "$MODE" = quartiles ] || [ "$MODE" = all ]; then
    echo "-- quartiles: built-in quantile_disc vs our GROUP BY  (quartiles_match=true, n_floor==n_true wanted) --"
    sub "$path" "$col" correctness_3way_quartiles.sql | "$DUCKDB" -box
  fi

  if [ "$MODE" = flags ] || [ "$MODE" = all ]; then
    echo "-- flags: per-row FPGA vs C++ vs built-in  (fpga_vs_cpp = binning error; cpp_vs_oracle must be 0) --"
    # STAGE 1: fences + CPU/oracle counts in PURE SQL (no FPGA operator).
    fence_csv=$(sub "$path" "$col" correctness_3way_fences.sql | "$DUCKDB" -csv -noheader 2>&1)
    IFS=, read -r glo ghi blo bhi n_cpp n_oracle cpp_vs_oracle <<<"$fence_csv"
    if [ -z "${ghi:-}" ]; then
      echo "!! stage-1 fence query failed: $fence_csv"; continue
    fi
    # STAGE 2: ONE aggregate over iqr_flags with the fences injected as CONSTANTS. The only FPGA query,
    # and the exact shape proven safe (no materialize, no join, no script). Run via -c, not a pipe.
    q2=$(sed -e "s#@PATH@#$path#g" -e "s#@COL@#$col#g" \
             -e "s#@GLO@#$glo#g" -e "s#@GHI@#$ghi#g" -e "s#@BLO@#$blo#g" -e "s#@BHI@#$bhi#g" \
             "$SQLDIR/correctness_3way_fpga.sql")
    fpga_csv=$(timeout "$TIMEOUT_FLAGS" "$DUCKDB" -csv -noheader -c "$q2")
    rc=$?
    if [ $rc -eq 124 ]; then
      echo "!! TIMEOUT after ${TIMEOUT_FLAGS}s on $name FPGA stage (card left intact by timeout)"; continue
    fi
    IFS=, read -r total n_fpga fpga_vs_cpp fpga_vs_oracle <<<"$fpga_csv"
    printf '  %-9s rows=%s n_fpga=%s n_cpp=%s n_oracle=%s | fpga_vs_cpp=%s cpp_vs_oracle=%s fpga_vs_oracle=%s\n' \
      "$name" "$total" "$n_fpga" "$n_cpp" "$n_oracle" "$fpga_vs_cpp" "$cpp_vs_oracle" "$fpga_vs_oracle"
  fi
done

echo
echo "==================== done ===================="
