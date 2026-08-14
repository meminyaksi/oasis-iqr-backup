# @brief  P&R-only placer-directive sweep to attack the SLL COLUMN CONGESTION that is holding
#         build-28 at WNS -0.995 with a FLAT wall (12 unrelated clusters within 0.024 ns).
#
# DIAGNOSIS (from build-28/bitgen.log "Estimated SLL Demand Per Column"):
#   SLR [0-1]  column 13 = 1793 / 1440 = 125%  (OVERSUBSCRIBED)
#   SLR [1-2]  column 13 = 1401 / 1440 =  97%  (at the limit)
#   ... while OVERALL SLL utilization is only 32-35% and columns 0-3 sit at 0-10%.
# So we are not short of SLR-crossing capacity, the crossings are all FUNNELLED THROUGH ONE COLUMN.
# Nets that cannot get an SLL locally detour laterally -> the 1.390 ns route on the IQR FSM net, and
# the flat ~-0.99 wall shared by IQR + decoders + shell converters + vhsnunzip + output_writer.
#
# ROOT CAUSE OF THE ROOT CAUSE: the ML placer picked `SSI_BalanceSLRs`, which per the Vivado man page
# balances "number of CELLS between SLRs" -- it balances LOGIC and is indifferent to crossing wires.
# The directives that target OUR failure mode are:
#   SSI_SpreadSLLs   - "Partition across SLRs and allocate extra area for regions of higher connectivity"
#   SSI_BalanceSLLs  - "Partition across SLRs while attempting to balance SLLs between SLRs"
#   SSI_HighUtilSLRs - "place logic closer together in each SLR" (fewer crossings per module)
#
# This needs NO RTL change, NO HBM change and NO hand-written Pblocks -- it is P&R only, resumed from
# shell_opted.dcp (opt_design is deterministic and unchanged). Outputs are directive-tagged, so the
# original build-28 checkpoints/bitstream are NEVER clobbered.
#
# Usage:  export TERM=xterm                      # base.tcl's color proc shells out to tput
#         vivado -mode batch -source pnr_reseed.tcl -tclargs <PLACE_DIRECTIVE>
#
# Parallel-safe: run each directive from its OWN cwd so vivado.jou/vivado.log do not collide.

if {[catch {

source "/home/myaksi/oasis/hardware/build-28/base.tcl"

set place_dir "SSI_SpreadSLLs"
if {$argc >= 1} { set place_dir [lindex $argv 0] }
set tag [string tolower $place_dir]

# Cap threads so several directives can run concurrently on the 64-core build node.
if {$argc >= 2} { set_param general.maxThreads [lindex $argv 1] } else { set_param general.maxThreads 8 }

puts "[color $clr_flow "** RESEED P&R on build-28: place_design -directive $place_dir"]"
puts "[color $clr_flow "** baseline: build-28 = -0.995 ns with SSI_BalanceSLRs (SLL col 13 at 125%)"]"

open_checkpoint "$dcp_dir/shell_opted.dcp"

place_design -directive $place_dir
write_checkpoint -force "$dcp_dir/shell_placed_$tag.dcp"
report_timing_summary -file "$rprt_dir/shell_timing_postplace_$tag.rpt"
puts "[color $clr_flow "** place_design ($place_dir) done"]"

# Match the main flow's post-place stages exactly, so the ONLY variable is the placer directive.
phys_opt_design -directive AggressiveExplore
route_design    -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force "$dcp_dir/shell_routed_$tag.dcp"

report_utilization    -file "$rprt_dir/shell_utilization_$tag.rpt"
report_timing_summary -file "$rprt_dir/shell_timing_summary_$tag.rpt"
report_timing -max_paths 1000 -sort_by group -file "$rprt_dir/shell_timing_worst_$tag.rpt"

# Did the SLL congestion actually spread out? This is the number that explains the WNS.
if {[catch {
    report_design_analysis -extend -congestion \
        -file "$rprt_dir/shell_congestion_$tag.rpt"
} e]} { puts "** (congestion report skipped: $e)" }

set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
puts "[color $clr_cmplt "** RESEED RESULT ($place_dir): WNS = $wns ns   (build-28 SSI_BalanceSLRs = -0.995)"]"

# A winner should be immediately flashable -- ~10 min out of a ~6 h run.
if {[catch {
    write_bitstream -force "$bit_dir/cyt_top_$tag.bit"
    puts "[color $clr_cmplt "** bitstream: $bit_dir/cyt_top_$tag.bit"]"
} e]} { puts "** (write_bitstream skipped: $e)" }

close_project

} errorstring]} {
    puts "** CERR: $errorstring"
    exit 1
}
exit 0
