# check_bank_slr2.tcl — run in the ALREADY-OPEN routed checkpoint (do NOT re-open).
#   source hardware/check_bank_slr2.tcl
# Finds the IQR histogram BRAMs by the "detection" substring (matches inst_iqr_detection OR
# IQR_detection hierarchy) and reports each one's site + SLR, then summarizes per bank.

set allramb [get_cells -hier -filter {REF_NAME =~ RAMB*}]
puts "total RAMB prims in design: [llength $allramb]"

# IQR BRAMs: name contains "detection" (case-stable in both hierarchy spellings)
set iqr [filter $allramb {NAME =~ *detection*}]
puts "IQR (detection) RAMB prims: [llength $iqr]"
if {[llength $iqr] == 0} {
    puts "!! none matched *detection* -- dumping any RAMB whose name contains 'bank' or 'mem' under user logic:"
    set iqr [filter $allramb {NAME =~ *bank* || NAME =~ *hist*}]
    puts "fallback matches: [llength $iqr]"
}

puts "---- individual BRAMs ----"
foreach c [lsort -dictionary $iqr] {
    set site [get_property LOC $c]
    set slr  [get_property NAME [get_slrs -of_objects [get_cells $c]]]
    puts [format "  %s\n      site=%s  %s" $c $site $slr]
}

puts "---- per-bank SLR summary (bank index parsed from name) ----"
array set bankslr {}
foreach c $iqr {
    set slr [get_property NAME [get_slrs -of_objects [get_cells $c]]]
    if {[regexp {bank\[?([0-7])\]?} $c -> k]} {
        lappend bankslr($k) $slr
    }
}
for {set k 0} {$k < 8} {incr k} {
    if {[info exists bankslr($k)]} {
        puts "  bank $k : [lsort -unique $bankslr($k)]"
    } else {
        puts "  bank $k : (no name matched - see individual list above)"
    }
}

puts "---- control-logic reference SLR ----"
set sc [lindex [get_cells -hier -filter {NAME =~ *detection*FSM_sequential_state_reg*}] 0]
if {$sc ne ""} { puts "  state FSM: [get_property NAME [get_slrs -of_objects [get_cells $sc]]]" }
puts ">>> DONE."
