# check_bank_slr.tcl — open build-06's routed checkpoint and report the SLR + site of each IQR
# histogram bank BRAM, to confirm whether banks 4-7 (the lossy ones) are placed across the SLR
# boundary from the IQR control logic. No bitgen. Run: vivado -mode tcl -source hardware/check_bank_slr.tcl
open_checkpoint /home/myaksi/oasis/hardware/build-06/checkpoints/shell_routed.dcp

puts "================ IQR bank BRAM placement ================"
# All BRAM primitives under the IQR histogram banks.
set cells [get_cells -hier -filter {(REF_NAME =~ RAMB* ) && (NAME =~ *iqr_detection*g_bank*)}]
foreach c [lsort -dictionary $cells] {
    set site [get_property LOC $c]
    set slr  [get_property NAME [get_slrs -of_objects [get_cells $c]]]
    puts [format "  %-90s site=%-16s %s" $c $site $slr]
}

puts "================ IQR control-logic SLR (reference) ================"
foreach ref {FSM_sequential_state_reg* *drain_cnt* *scan_cnt* *total_reg*} {
    set fc [lindex [get_cells -hier -filter "NAME =~ *iqr_detection*$ref"] 0]
    if {$fc ne ""} {
        set slr [get_property NAME [get_slrs -of_objects [get_cells $fc]]]
        puts [format "  %-90s %s" $fc $slr]
    }
}

puts "================ summary: SLR of each bank ================"
for {set k 0} {$k < 8} {incr k} {
    set bc [get_cells -hier -filter "(REF_NAME =~ RAMB*) && (NAME =~ *iqr_detection*g_bank\\\[$k\\\]*)"]
    set slrs {}
    foreach c $bc { lappend slrs [get_property NAME [get_slrs -of_objects [get_cells $c]]] }
    puts "  bank $k : [lsort -unique $slrs]   ([llength $bc] BRAM prims)"
}
puts ">>> DONE. If banks 4-7 show a different SLR than banks 0-3 / the control logic, the SLR crossing is the cause."
