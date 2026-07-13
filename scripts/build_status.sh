#!/bin/bash
# Status of the two in-flight bitgens. Run any time:  bash scripts/build_status.sh
# Add -w to block until one of them produces a bitstream.
B11="$HOME/oasis/hardware/build-11"
HW="$HOME/oasis/parcore/libstf/coyote/examples/01_hello_world/hw/build_hw"

status() {
    local name="$1" dir="$2"
    local bit="$dir/bitstreams/cyt_top.bit"
    printf "%-14s " "$name"
    if [ -f "$bit" ]; then
        printf "DONE   bitstream @ %s\n" "$(stat -c '%y' "$bit" | cut -d. -f1)"
        return 0
    fi
    # Which tcl stage is Vivado in? (synth_shell / pnr_shell / ...)
    local stage
    stage=$(pgrep -af "vivado.*$dir" | grep -oE '[a-z_]+\.tcl' | head -1)
    if [ -z "$stage" ]; then
        printf "NOT RUNNING (no vivado process) -- check %s/bitgen.log\n" "$dir"
        return 1
    fi
    printf "running  stage=%-16s  last log: %s\n" "${stage:-?}" \
        "$(tail -1 "$dir/bitgen.log" 2>/dev/null | cut -c1-60)"
    return 1
}

while :; do
    echo "--- $(date '+%H:%M:%S') ---"
    status "hello_world" "$HW"; h=$?
    status "build-11"    "$B11"; b=$?
    [ "$1" != "-w" ] && break
    { [ $h -eq 0 ] || [ $b -eq 0 ]; } && { echo; echo ">>> A BITSTREAM IS READY <<<"; break; }
    sleep 120
done
