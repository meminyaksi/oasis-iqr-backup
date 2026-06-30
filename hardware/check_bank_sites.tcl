# check_bank_sites.tcl — run in the already-open routed checkpoint.
#   source hardware/check_bank_sites.tcl
# Dumps the physical site (RAMB36_XnYm) of every IQR histogram BRAM + key control/source FFs,
# so we can see whether banks 4-7 are placed far from banks 0-3 / the logic (long-route loss).

puts "==== IQR BRAM sites (site = column Xn, row Ym) ===="
foreach c [lsort -dictionary [get_cells -hier -filter {REF_NAME =~ RAMB* && NAME =~ *detection*}]] {
    set tail [string range $c [string last detection $c] end]
    puts [format "  %-18s  %s" [get_property LOC $c] $tail]
}

puts "==== reference logic sites (where the writes are launched from) ===="
foreach pat {*detection*FSM_sequential_state_reg[0]* *detection*s1_we_reg* *detection*s1_bin_reg[0]* *detection*clear_addr_reg[0]* *detection*q_raddr* } {
    set c [lindex [get_cells -hier -filter "NAME =~ $pat"] 0]
    if {$c ne ""} { puts [format "  %-18s  %s" [get_property LOC $c] [string range $c [string last detection $c] end]] }
}

puts "==== bounding box of IQR BRAMs ===="
set xs {}; set ys {}
foreach c [get_cells -hier -filter {REF_NAME =~ RAMB* && NAME =~ *detection*}] {
    if {[regexp {X(\d+)Y(\d+)} [get_property LOC $c] -> x y]} { lappend xs $x; lappend ys $y }
}
if {[llength $ys]} {
    puts "  X range: [lindex [lsort -integer $xs] 0] .. [lindex [lsort -integer $xs] end]"
    puts "  Y range: [lindex [lsort -integer $ys] 0] .. [lindex [lsort -integer $ys] end]"
}
puts ">>> DONE."
