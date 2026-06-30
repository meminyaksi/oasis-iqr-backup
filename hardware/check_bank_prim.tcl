# check_bank_prim.tcl — run in the already-open routed checkpoint.
#   source hardware/check_bank_prim.tcl
# Reports the actual memory PRIMITIVE TYPE backing each histogram bank. If banks 0-3 and 4-7 use
# DIFFERENT primitives (e.g. LUTRAM/URAM vs RAMB36), that asymmetry is why only 4-7 lose counts.

puts "==== memory primitives per bank (g_bank[*].mem*) ===="
foreach c [lsort -dictionary [get_cells -hier -filter {NAME =~ *detection*g_bank* && (NAME =~ *mem* || REF_NAME =~ RAMB* || REF_NAME =~ URAM* || REF_NAME =~ RAMD* || REF_NAME =~ RAMS*)}]] {
    set k "?"
    regexp {bank\[([0-7])\]} $c -> k
    puts [format "  bank %s | %-12s | %-14s | %s" $k [get_property REF_NAME $c] [get_property LOC $c] [string range $c [string last g_bank $c] end]]
}

puts "==== count of primitive REF_NAMEs under IQR detection (excludes ila) ===="
array set cnt {}
foreach c [get_cells -hier -filter {NAME =~ *detection*g_bank*}] {
    set r [get_property REF_NAME $c]
    if {[regexp {RAMB|URAM|RAMD|RAMS|SRL} $r]} { incr cnt($r) }
}
foreach r [lsort [array names cnt]] { puts "  $r : $cnt($r)" }
puts ">>> DONE."
