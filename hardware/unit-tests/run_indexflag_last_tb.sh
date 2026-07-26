#!/usr/bin/env bash
# Suspect #2: does IqrIndexFlag withhold o_last under an i_expected/beat mismatch, leaving IqrWideFlagPack
# dirty? Runs both without +RESTART (current HW) and with (the wide-packer i_restart fix).
set -uo pipefail
ROOT="${OASIS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LIBSTF="$ROOT/parcore/libstf/hardware/src/hdl"
WORK="${TMPDIR:-/tmp}/indexflag_last_tb.$$"
command -v xvlog >/dev/null || { echo "xvlog not on PATH -- module load vivado/2024.2" >&2; exit 2; }
LYNX=$(ls -t "$ROOT"/hardware/build-*/oasis_shell/hdl/lynx_pkg.sv 2>/dev/null | head -1)
mkdir -p "$WORK"; cd "$WORK"
xvlog -sv -i "$LIBSTF" "$LYNX" "$LIBSTF/common.sv" "$LIBSTF/data_interfaces.sv" \
    "$LIBSTF/util/reset_resync.sv" "$ROOT/hardware/src/hdl/iqr_index.sv" \
    "$ROOT/hardware/src/hdl/iqr_index_stream.sv" \
    "$ROOT/hardware/unit-tests/tb_iqr_indexflag_last.sv"
xelab -debug typical tb_iqr_indexflag_last -s iflast
echo; echo "######## RUN 1: NO restart (current HW) ########"; xsim iflast -runall
echo; echo "######## RUN 2: WITH wide-packer i_restart (+RESTART) ########"; xsim iflast -runall -testplusarg RESTART
