#!/usr/bin/env bash
# Build status for an OASIS hardware build -- phase, elapsed, timing, and whether it is alive.
#
#   scripts/util/build_status.sh                 # newest hardware/build-* , once
#   scripts/util/build_status.sh build-15        # a specific build
#   scripts/util/build_status.sh build-15 -w     # re-print every 60 s until the bitstream lands
#
# Reads the log only; it never touches the running Vivado. Safe to run any number of times, from any
# node (home is NFS-shared, but the "alive" check is per-node -- run it on hacc-build-02 for that
# line to mean anything).
set -uo pipefail

ROOT="${OASIS_ROOT:-$HOME/oasis}"
BUILD="${1:-}"
[[ "$BUILD" == "-w" ]] && BUILD=""
if [[ -z "$BUILD" ]]; then
    BUILD=$(ls -dt "$ROOT"/hardware/build-* 2>/dev/null | head -1)
else
    BUILD="$ROOT/hardware/${BUILD#hardware/}"
fi
[[ -d "$BUILD" ]] || { echo "no such build: $BUILD" >&2; exit 1; }

WATCH=0
for a in "$@"; do [[ "$a" == "-w" || "$a" == "--watch" ]] && WATCH=1; done

LOG="$BUILD/bitgen.log"
BIT="$BUILD/bitstreams/cyt_top.bit"

report() {
    echo "=== $(basename "$BUILD")  @ $(date +%H:%M:%S) ==="

    if [[ -f "$BIT" ]]; then
        echo "  DONE -- bitstream: $BIT"
        [[ -f "$BUILD/analysis.txt" ]] && { echo "  --- analysis.txt ---"; head -12 "$BUILD/analysis.txt"; }
        return 0
    fi
    [[ -f "$LOG" ]] || { echo "  no bitgen.log yet"; return 1; }

    # Vivado numbers phases per command, so the phase alone is ambiguous. Anchor on the last command
    # banner (place_design / route_design / write_bitstream) to say which stage we are actually in.
    local stage
    stage=$(grep -oE "Starting (Placer|Routing|Bitgen|Writing Bitstream|Post-Route|Design Initialization)[A-Za-z ]*" "$LOG" | tail -1)
    echo "  stage : ${stage:-unknown}"
    echo "  phase : $(grep '^Phase' "$LOG" | tail -1 | sed 's/ | Checksum.*//')"
    echo "  time  : $(grep 'elapsed =' "$LOG" | tail -1 | sed 's/^Time (s): //;s/ Memory.*//')"

    # Liveness. Log AGE, not growth over a sampling window: routing writes sparsely (~70 bytes per
    # 45 s during global iterations), so any short growth sample reads as "idle" on a healthy build.
    # A process that is up but silent for many minutes inside routing is still normal; silent AND
    # gone is the failure that matters.
    local age
    age=$(( $(date +%s) - $(stat -c %Y "$LOG") ))
    if pgrep -f "$(basename "$BUILD")" >/dev/null 2>&1; then
        echo "  alive : yes, last log write ${age}s ago"
    else
        echo "  alive : NO PROCESS on $(hostname -s) -- finished, died, or running on another node"
    fi

    # WNS as soon as any timing summary exists; negative here is not yet fatal (build-14 shipped at
    # -0.773 and was bit-exact on silicon), but a large swing means the fuse changed the critical path.
    local wns
    wns=$(grep -A6 -iE "(post.route|post.placement).*timing summary" "$LOG" | grep -oE '^ *-?[0-9]+\.[0-9]+' | head -1)
    [[ -n "$wns" ]] && echo "  WNS   : $wns ns (provisional)"

    grep -ciE "^ERROR" "$LOG" | grep -qv '^0$' && echo "  ERRORS: $(grep -cE '^ERROR' "$LOG") -- grep '^ERROR' $LOG"
    return 1
}

if [[ "$WATCH" == "1" ]]; then
    while ! report; do echo; sleep 60; done
else
    report
fi
