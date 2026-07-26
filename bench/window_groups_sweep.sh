#!/usr/bin/env bash
# Experiment 2: does a WINDOW_GROUPS between 16 and 48 change taxi_d3/d4's FUSED outlier count?
#
# Forces fusion on the ragged taxi sets (OASIS_IQR_FORCE_STREAM=1, TEST ONLY -- per-row flags are
# mislabeled by the ragged packer, but the COUNT is preserved and is the window-accuracy signal).
# Prints, per group: pass1 mode (must be `fused`), win_derive, heavy, and the outlier count vs exact.
set -uo pipefail
cd "$(dirname "$0")/.."
export LD_LIBRARY_PATH=$HOME/opt/lib:${LD_LIBRARY_PATH:-}
D=./extension/build/release/duckdb
DS=/home/myaksi/datasets
ERR=$(mktemp)

# name col exact_outliers
run_set() {
  local name=$1 col=$2 exact=$3
  echo
  echo "########## $name  (exact = $exact) ##########"
  for g in 16 24 32 40 48; do
    local cnt pass1 wd hv delta
    cnt=$(OASIS_IQR_FORCE_STREAM=1 OASIS_IQR_WINDOW_GROUPS="$g" \
          OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 OASIS_IQR_TIMING=1 \
          timeout 200 "$D" -csv -noheader -c \
          "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('$DS/$name.parquet','$col');" 2>"$ERR" \
          | tr -d '[:space:]')
    pass1=$(grep -oE 'pass1=[a-z()+-]+'   "$ERR" | head -1 | cut -d= -f2)
    wd=$(grep -oE 'win_derive [0-9.]+ ms' "$ERR" | head -1 | grep -oE '[0-9.]+')
    hv=$(grep -oE 'heavy +[0-9.]+ ms'     "$ERR" | head -1 | grep -oE '[0-9.]+')
    if [ -n "$cnt" ]; then delta=$(( cnt - exact )); else cnt=ERR; delta=NA; fi
    echo "WINDOW_GROUPS=$g   pass1=${pass1:-?}   win_derive=${wd:-?}ms   heavy=${hv:-?}ms   count=$cnt  delta=$delta"
  done
}

# warm the page cache
cat "$DS/taxi_d3.parquet" > /dev/null
cat "$DS/taxi_d4.parquet" > /dev/null

run_set taxi_d3 fare_cents 1328270
run_set taxi_d4 fare_cents 2057243

rm -f "$ERR"
echo
echo "want: pass1=fused; delta=0 (exact); heavy under memcpy baseline. taxi_d3 memcpy-FPGA count=1328108."
