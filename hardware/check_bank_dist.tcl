# check_bank_dist.tcl — run in the already-open routed checkpoint.
#   source hardware/check_bank_dist.tcl
# Pairs each bank's BRAM site with its s1_we / s1_bin launch FF site, so we can see whether the
# lossy banks (4-7) have physically distant BRAMs (long write route) vs the clean banks (0-3).

array set bram {}; array set we {}; array set bin {}
foreach c [get_cells -hier -filter {REF_NAME =~ RAMB* && NAME =~ *detection*}] {
    if {[regexp {bank\[([0-7])\]} $c -> k]} { lappend bram($k) [get_property LOC $c] }
}
foreach c [get_cells -hier -filter {NAME =~ *detection*s1_we_reg*}] {
    if {[regexp {bank\[([0-7])\]} $c -> k]} { set we($k) [get_property LOC $c] }
}
foreach c [get_cells -hier -filter {NAME =~ *detection*s1_bin_reg*}] {
    if {[regexp {bank\[([0-7])\]} $c -> k]} { set bin($k) [get_property LOC $c] }
}
puts "bank | BRAM site(s)                 | s1_we launch     | s1_bin launch"
for {set k 0} {$k < 8} {incr k} {
    set b  [expr {[info exists bram($k)] ? $bram($k) : "-"}]
    set w  [expr {[info exists we($k)]   ? $we($k)   : "-"}]
    set s  [expr {[info exists bin($k)]  ? $bin($k)  : "-"}]
    puts [format "  %d  | %-28s | %-16s | %s" $k $b $w $s]
}
puts ">>> DONE. Look for a big Y (or X) jump in BRAM site between banks 0-3 and 4-7."
