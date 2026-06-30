# ila_capture_b06_scan.tcl — capture ONLY the scan ILA on the CURRENT build-06 bitstream,
# with the 1024-value (i%10) dataset, to read PER-BANK histogram totals and confirm whether the
# ~3% count-loss is bank-specific (banks 5,7 low) or spread across all banks. No rebuild/reflash.
# Usage (alveo-u55c-07): vivado -mode tcl -source hardware/ila_capture_b06_scan.tcl
#   then run ./examples/iqr_sim/build/iqr_sim in another shell, press Enter here.

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set ltx /home/myaksi/oasis/hardware/build-06/bitstreams/cyt_top.ltx
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev

# scan ILA = the one WITHOUT the _rmw suffix
set ila_scan [lindex [get_hw_ilas -of_objects $dev -filter {CELL_NAME =~ "*inst_ila_iqr"}] 0]
puts "=== ila_scan : $ila_scan"
if {$ila_scan eq ""} { puts "!!! scan ILA not found"; return }

# Trigger on ENTERING QUARTILES (state==1) so the bin-0..9 readback is captured regardless of how
# long/gappy the 128-beat input stream is. Position early so we see QUARTILES entry + the whole scan.
set_property CONTROL.DATA_DEPTH       1024 $ila_scan
set_property CONTROL.TRIGGER_POSITION 16   $ila_scan
set stp [lindex [get_hw_probes -of_objects $ila_scan -filter {NAME =~ "*state*"}] 0]
puts "=== trigger probe: $stp"
set_property TRIGGER_COMPARE_VALUE eq2'b01 $stp

run_hw_ila $ila_scan
puts ">>> ARMED. Run ./examples/iqr_sim/build/iqr_sim in another shell, then press Enter."
gets stdin
wait_on_hw_ila $ila_scan
set d [upload_hw_ila_data $ila_scan]
write_hw_ila_data -csv_file /home/myaksi/iqr_ila_scan.csv -force $d
puts ">>> scan ILA -> ~/iqr_ila_scan.csv"
