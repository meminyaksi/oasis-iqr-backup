#!/usr/bin/env bash
# Cross-column state-leak test for IqrWideFlagPack (the §9.23 first-word defect).
#   module load vivado/2024.2
#   hardware/unit-tests/run_wide_pack_reset_tb.sh
# Runs BOTH: no +RESTART (current hardware behaviour -> expect LEAK if the bug is real) and
# +RESTART (the i_restart fix -> expect CLEAN). The no-RESTART run is the revert check.
set -uo pipefail
ROOT="${OASIS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LIBSTF="$ROOT/parcore/libstf/hardware/src/hdl"
WORK="${TMPDIR:-/tmp}/wide_pack_reset_tb.$$"
command -v xvlog >/dev/null || { echo "xvlog not on PATH -- run: module load vivado/2024.2" >&2; exit 2; }
LYNX=$(ls -t "$ROOT"/hardware/build-*/oasis_shell/hdl/lynx_pkg.sv 2>/dev/null | head -1)
[[ -f "$LYNX" ]] || { echo "no generated lynx_pkg.sv under hardware/build-*" >&2; exit 2; }

mkdir -p "$WORK"; cd "$WORK"
xvlog -sv -i "$LIBSTF" \
    "$LYNX" "$LIBSTF/common.sv" "$LIBSTF/data_interfaces.sv" "$LIBSTF/util/reset_resync.sv" \
    "$ROOT/hardware/src/hdl/iqr_index.sv" \
    "$ROOT/hardware/src/hdl/iqr_index_stream.sv" \
    "$ROOT/hardware/unit-tests/tb_iqr_wide_pack_reset.sv"
xelab -debug typical tb_iqr_wide_pack_reset -s wpk

echo; echo "######## RUN 1: NO restart (current HW behaviour -- revert check) ########"
xsim wpk -runall

echo; echo "######## RUN 2: WITH i_restart fix (+RESTART) ########"
xsim wpk -runall -testplusarg RESTART
