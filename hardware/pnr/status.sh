#!/usr/bin/env bash
# Status of the build-28 P&R directive sweeps. Run from anywhere: bash ~/oasis/hardware/build-28/reseed/status.sh
#
# Why not a one-liner: Vivado ECHOES the .tcl source into its log, so a naive grep for "RESEED RESULT"
# matches the unresolved template line ("WNS = $wns ns") and reports it as a result. We therefore drop
# any line still containing a $variable, and read only the real logs (reseed.log / physopt.log) -- never
# the vivado_*.backup.log rotations.
set -uo pipefail
cd "$(dirname "$0")"

printf '%-28s %-12s %s\n' "RUN" "RESULT" "LAST ACTIVITY"
printf '%-28s %-12s %s\n' "---" "------" "-------------"

for d in */; do
    d="${d%/}"
    f=$(ls "$d"/physopt.log "$d"/reseed.log 2>/dev/null | head -1)
    [[ -z "$f" ]] && { printf '%-28s %-12s %s\n' "$d" "-" "(no log)"; continue; }

    clean=$(tr -d '\000' < "$f" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '\$')

    # Final answer, if the run produced one.
    res=$(printf '%s\n' "$clean" | grep -aoE '(RESEED|ROUTE SWEEP) RESULT \([A-Za-z_]+\): WNS = -?[0-9.]+|best WNS = -?[0-9.]+' | tail -1 | grep -oE -- '-?[0-9]+\.[0-9]+$')
    if [[ -z "$res" ]]; then
        if printf '%s\n' "$clean" | grep -qE '^ERROR|CERR|route_design failed'; then res="FAILED"; fi
    fi

    # What it is doing right now.
    act=$(printf '%s\n' "$clean" | grep -aoE 'ATTEMPT: phys_opt_design -directive [A-Za-z]+|KEPT \([A-Za-z]+\)[^"]*|discarded \([A-Za-z]+\)[^"]*|REJECTED \([A-Za-z]+\)[^"]*|Phase [0-9.]+ [A-Za-z][A-Za-z ]*|Starting [A-Za-z ]+Task|open_checkpoint|write_bitstream' | tail -1)

    age=$(( ($(date +%s) - $(stat -c %Y "$f")) / 60 ))

    # Congestion alarm -- the SSI_HighUtilSLRs failure mode. Only actionable on a run that is STILL
    # ALIVE (no verdict yet and the log is moving); on a finished run it is just history, not advice.
    warn=""
    if [[ -z "$res" && $age -lt 15 ]] && printf '%s\n' "$clean" | grep -q 'Route 35-162'; then
        n=$(printf '%s\n' "$clean" | grep -oE '[0-9]+ signals failed to route' | tail -1)
        warn="  <<< CONGESTION: $n -- KILL THIS ONE"
    fi
    printf '%-28s %-12s %s (log %dm old)%s\n' "$d" "${res:-running}" "${act:-starting}" "$age" "$warn"
done

echo
echo "baseline to beat: -0.657 (SSI_SpreadSLLs)   target: better than -0.5"
echo "node: $(free -g | awk '/^Mem:/{print $7" GB available of "$2}')   vivado procs: $(pgrep -cf 'unwrapped.*vivado' || echo 0)"
