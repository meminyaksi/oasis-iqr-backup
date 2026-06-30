# ila_capture.tcl — capture BOTH IQR ILAs, time-aligned, for build-07.
#   ila_iqr      : full life of `total` (scan/reduction tree, quartiles, fences)  -> ~/iqr_ila_scan.csv
#   ila_iqr_rmw  : per-bank RMW write path (ALL banks 0-7) + wdata_dbg (BRAM DI tap) -> ~/iqr_ila_rmw.csv
# Usage (on alveo-u55c-07, in one shell):
#   vivado -mode tcl -source hardware/ila_capture.tcl
# It arms both ILAs, then waits for you to run ./examples/iqr_sim/build/iqr_sim in ANOTHER shell.
# Both arm on the SAME event (accept_q==1, the first binned beat), so the two CSVs share t=0.

open_hw_manager
connect_hw_server -allow_non_jtag                 ;# auto-starts a local hw_server on :3121
open_hw_target                                    ;# auto-discovers the U55C JTAG target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

# Load the probe<->signal map produced by the build.
set ltx /home/myaksi/oasis/hardware/build-07/bitstreams/cyt_top.ltx
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev

# Grab both ILAs explicitly (exact cell-name suffix, not a loose glob).
set ila_scan [lindex [get_hw_ilas -of_objects $dev -filter {CELL_NAME =~ "*inst_ila_iqr"}] 0]
set ila_rmw  [lindex [get_hw_ilas -of_objects $dev -filter {CELL_NAME =~ "*inst_ila_iqr_rmw"}] 0]
puts "=== ila_scan : $ila_scan"
puts "=== ila_rmw  : $ila_rmw"
if {$ila_scan eq "" || $ila_rmw eq ""} {
    puts "!!! ERROR: could not find both ILAs. Found ilas:"
    foreach i [get_hw_ilas -of_objects $dev] { puts "    $i" }
    return
}

# --- arm ila_iqr (scan) : built depth 1024 -------------------------------------------------------
set_property CONTROL.DATA_DEPTH       1024 $ila_scan
set_property CONTROL.TRIGGER_POSITION 64   $ila_scan
set acc_s [get_hw_probes -of_objects $ila_scan -filter {NAME =~ "*accept_q*"}]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $acc_s

# --- arm ila_iqr_rmw : built depth 2048 ----------------------------------------------------------
set_property CONTROL.DATA_DEPTH       1024 $ila_rmw
set_property CONTROL.TRIGGER_POSITION 128  $ila_rmw
set acc_r [get_hw_probes -of_objects $ila_rmw -filter {NAME =~ "*accept_q*"}]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $acc_r

# Arm both BEFORE the run so the first accept_q triggers both simultaneously.
run_hw_ila $ila_scan
run_hw_ila $ila_rmw
puts ">>> BOTH ARMED. Now run  ./examples/iqr_sim/build/iqr_sim  in another shell, then press Enter here."
gets stdin

wait_on_hw_ila $ila_scan
set d_scan [upload_hw_ila_data $ila_scan]
display_hw_ila_data $d_scan
write_hw_ila_data -csv_file /home/myaksi/iqr_ila_scan.csv -force $d_scan
puts ">>> scan ILA  -> ~/iqr_ila_scan.csv"

wait_on_hw_ila $ila_rmw
set d_rmw [upload_hw_ila_data $ila_rmw]
write_hw_ila_data -csv_file /home/myaksi/iqr_ila_rmw.csv -force $d_rmw
puts ">>> rmw  ILA  -> ~/iqr_ila_rmw.csv"
puts ">>> DONE. Two CSVs written; both share t=0 at the first accept_q==1."
