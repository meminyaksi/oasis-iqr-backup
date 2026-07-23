#!/usr/bin/env bash
# Standalone xsim run for tb_iqr_index.sv -- proves the pass-2 bin-index compare is bit-identical
# to the value compare it replaces. Pure combinational logic, no shell or interfaces needed.
#
#   module load vivado/2024.2
#   hardware/unit-tests/run_index_tb.sh
set -euo pipefail

ROOT="${OASIS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LIBSTF="$ROOT/parcore/libstf/hardware/src/hdl"
WORK="${TMPDIR:-/tmp}/index_tb.$$"

command -v xvlog >/dev/null || { echo "xvlog not on PATH -- run: module load vivado/2024.2" >&2; exit 2; }

mkdir -p "$WORK"; cd "$WORK"

xvlog -sv -i "$LIBSTF" \
    "$ROOT/hardware/src/hdl/iqr_index.sv" \
    "$ROOT/hardware/unit-tests/tb_iqr_index.sv"

xelab -debug typical tb_iqr_index -s index_tb
xsim index_tb -runall
