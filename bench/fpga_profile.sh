#!/bin/bash
# Detailed FPGA time-spend test. Runs iqr_flags with OASIS_IQR_TIMING=1 on each dataset (2 warm runs)
# and shows BOTH breakdowns:
#   [iqr]      -- host wall-clock phases: decode (fpga_wait/fetch/submit/copy), iqr (staging/passes), heavy
#   [iqr-prof] -- FPGA-internal StreamProfiler cycles: INPUT/OUTPUT busy vs starved vs stalled, eff GB/s
#
# What to read:
#   busy%    = FPGA doing useful work (handshakes)
#   starved% = FPGA idle, waiting on data from PCIe/host  <- the HBM/tap target
#   stalled% = data present but FPGA back-pressuring       <- compute-bound (should be ~0)
#   handshakes should == 2*N/8 exactly (deterministic); if it drifts, the reading is wrong.
#   eff GB/s = achieved input bandwidth; compare vs 16 GB/s core ceiling and 12.5 GB/s PCIe line rate.
#
# Requires: card flashed + 1 GiB huge pages + the profiler-enabled build (rebuild the `shell` target).
#   export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
#   bash bench/fpga_profile.sh
set -u
DUCKDB="${DUCKDB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-$HOME/datasets}"
export LD_LIBRARY_PATH="$HOME/opt/lib:${LD_LIBRARY_PATH:-}"
export OASIS_IQR_TIMING=1

# dataset:file:column  (the canonical 7, small -> large)
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
  echo "==================== $name ($col) ===================="
  # Run twice in one process: the 1st warms caches/pins pages, read the 2nd. The profiler lines print
  # to stderr per query; the 2nd block is the warm measurement.
  "$DUCKDB" -c "PRAGMA threads=32;
    SELECT count(*) FILTER (WHERE f) FROM iqr_flags('$path','$col') t(v,f);
    SELECT count(*) FILTER (WHERE f) FROM iqr_flags('$path','$col') t(v,f);" 2>&1 \
    | grep -E '^\[iqr'
  echo
done
