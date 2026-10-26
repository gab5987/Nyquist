# Read memory test status via In-System Sources and Probes.
# Usage: quartus_stp -t scripts/status.tcl [restart]
# Probe: [0]=init_done [1]=busy [2]=done [3]=pass [4]=fail [9:8]=phase
#        [31:16]=err_cnt [55:32]=first_err_addr [63:56]=cur_addr[23:16]

set restart [expr {[llength $argv] > 0 && [lindex $argv 0] eq "restart"}]

set hw  [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
puts "Hardware: $hw / Device: $dev"

start_insystem_source_probe -device_name $dev -hardware_name $hw

if {$restart} {
    write_source_data -instance_index 0 -value 0 -value_in_hex
    write_source_data -instance_index 0 -value 1 -value_in_hex
    write_source_data -instance_index 0 -value 0 -value_in_hex
    puts "Test restarted."
}

proc read_status {} {
    set hex [read_probe_data -instance_index 0 -value_in_hex]
    set v   [expr "0x$hex"]
    set init  [expr {($v >> 0)  & 1}]
    set busy  [expr {($v >> 1)  & 1}]
    set done  [expr {($v >> 2)  & 1}]
    set pass  [expr {($v >> 3)  & 1}]
    set fail  [expr {($v >> 4)  & 1}]
    set phase [expr {($v >> 8)  & 3}]
    set errs  [expr {($v >> 16) & 0xFFFF}]
    set ferr  [expr {($v >> 32) & 0xFFFFFF}]
    set cur   [expr {($v >> 56) & 0xFF}]
    puts [format "raw=%s init_done=%d busy=%d done=%d pass=%d fail=%d phase=%d err_cnt=%d first_err_addr=0x%06X progress=%d%%" \
          $hex $init $busy $done $pass $fail $phase $errs $ferr [expr {$cur * 100 / 256}]]
    return $done
}

# Poll until done (max ~30 s)
for {set i 0} {$i < 60} {incr i} {
    if {[read_status]} { break }
    after 500
}

end_insystem_source_probe
