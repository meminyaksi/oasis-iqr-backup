#!/usr/bin/env bash
# Standalone xsim run for tb_iqr_index_stream.sv -- the step-2 index path end to end
# (encode -> pack -> host round trip -> unpack -> compare -> flags) against the value path.
#
#   module load vivado/2024.2
#   hardware/unit-tests/run_index_stream_tb.sh
set -euo pipefail

ROOT="${OASIS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LIBSTF="$ROOT/parcore/libstf/hardware/src/hdl"
WORK="${TMPDIR:-/tmp}/index_stream_tb.$$"

command -v xvlog >/dev/null || { echo "xvlog not on PATH -- run: module load vivado/2024.2" >&2; exit 2; }

LYNX=$(ls -t "$ROOT"/hardware/build-*/oasis_shell/hdl/lynx_pkg.sv 2>/dev/null | head -1)
[[ -f "$LYNX" ]] || { echo "no generated lynx_pkg.sv found under hardware/build-*" >&2; exit 2; }

mkdir -p "$WORK"; cd "$WORK"

xvlog -sv -i "$LIBSTF" \
    "$LYNX" \
    "$LIBSTF/common.sv" \
    "$LIBSTF/data_interfaces.sv" \
    "$LIBSTF/util/reset_resync.sv" \
    "$ROOT/hardware/src/hdl/iqr_index.sv" \
    "$ROOT/hardware/src/hdl/iqr_index_stream.sv" \
    "$ROOT/hardware/unit-tests/tb_iqr_index_stream.sv"

xelab -debug typical tb_iqr_index_stream -s index_stream_tb
xsim index_stream_tb -runall
