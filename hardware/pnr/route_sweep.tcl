# @brief  TIER 2 (~2.5-3 h per directive): keep the WINNING SSI_SpreadSLLs PLACEMENT and sweep the
#         route_design axis, which has never been varied (always AggressiveExplore).
#
# Resumes from shell_placed_ssi_spreadslls.dcp, so the ~40 min placement is not repeated and the ONLY
# variable is the router. Two route directives are specifically relevant to our remaining critical path:
#   NoTimingRelaxation   - the router never relaxes a timing constraint to finish (we are 0.657 short,
#                          not unroutable, so refusing to relax is exactly what we want)
#   AdvancedSkewModeling - better clock-skew modelling; our worst path carries 0.268 ns of inter-SLR
#                          compensation plus clock-skew terms, which this directly models
#   MoreGlobalIterations / HigherDelayCost / AlternateCLBRouting - additional effort / cost-function variants
#
# Outputs are directive-tagged, so the SSI_SpreadSLLs routed checkpoint and bitstream are never clobbered.
#
# Usage:  export TERM=xterm
#         vivado -mode batch -source route_sweep.tcl -tclargs <ROUTE_DIRECTIVE> [maxThreads]
# Parallel-safe: run each from its OWN cwd (vivado.jou/log collide otherwise).

if {[catch {

source "/home/myaksi/oasis/hardware/build-28/base.tcl"

set route_dir "NoTimingRelaxation"
if {$argc >= 1} { set route_dir [lindex $argv 0] }
if {$argc >= 2} { set_param general.maxThreads [lindex $argv 1] } else { set_param general.maxThreads 8 }
set tag "ssi_spreadslls_rt_[string tolower $route_dir]"

puts "[color $clr_flow "** TIER-2 ROUTE SWEEP: route_design -directive $route_dir"]"
puts "[color $clr_flow "** placement = SSI_SpreadSLLs (fixed); baseline WNS with AggressiveExplore = -0.657"]"

open_checkpoint "$dcp_dir/shell_placed_ssi_spreadslls.dcp"

# Keep the pre-route phys_opt identical to the run that produced -0.657 so the router is the only change.
phys_opt_design -directive AggressiveExplore
route_design    -directive $route_dir
phys_opt_design -directive AggressiveExplore

write_checkpoint -force "$dcp_dir/shell_routed_$tag.dcp"
report_timing_summary -file "$rprt_dir/shell_timing_summary_$tag.rpt"
report_timing -max_paths 1000 -sort_by group -file "$rprt_dir/shell_timing_worst_$tag.rpt"

set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -hold]  0]]
puts "[color $clr_cmplt "** ROUTE SWEEP RESULT ($route_dir): WNS = $wns   WHS = $whs   (AggressiveExplore = -0.657)"]"

if {$wns > -0.657 && $whs >= 0} {
    if {[catch {
        write_bitstream -force "$bit_dir/cyt_top_$tag.bit"
        puts "[color $clr_cmplt "** bitstream: $bit_dir/cyt_top_$tag.bit"]"
    } e]} { puts "** (write_bitstream skipped: $e)" }
}

close_project

} errorstring]} {
    puts "** CERR: $errorstring"
    exit 1
}
exit 0
