# ================== environment & setup ==================
set script_dir [file dirname [file normalize [info script]]]
set default_top_proj_dir [file dirname $script_dir]

if {[info exists ::env(TOP_PROJ_DIR)] && $::env(TOP_PROJ_DIR) ne ""} {
  set top_proj_dir $::env(TOP_PROJ_DIR)
} else {
  set top_proj_dir $default_top_proj_dir
}

if {[info exists ::env(PROJ_DIR)] && $::env(PROJ_DIR) ne ""} {
  set proj_dir $::env(PROJ_DIR)
} else {
  set proj_dir $script_dir
}

set design_name $::env(DESIGN_NAME)
if {[info exists ::env(CONGESTION_REPORT)] && $::env(CONGESTION_REPORT) ne ""} {
  set crfile $::env(CONGESTION_REPORT)
} else {
  set crfile [file join $proj_dir ${design_name}_congestion_report.rpt]
}

if {[info exists ::env(FOLDER_NAME)] && $::env(FOLDER_NAME) ne ""} {
  set folder $::env(FOLDER_NAME)
} else {
  set folder [file join $proj_dir results ${design_name}_evaluation]
}

set lib_setup_file [file join $script_dir $design_name lib_setup.tcl]
set design_setup_file [file join $script_dir $design_name design_setup.tcl]

set start [clock seconds]
source $lib_setup_file
source $design_setup_file

proc json_escape {value} {
  set escaped [string map [list \\ \\\\ \" \\\" ] $value]
  set newline "\n"
  set carriage "\r"
  set tab "\t"
  regsub -all $newline $escaped {\\n} escaped
  regsub -all $carriage $escaped {\\r} escaped
  regsub -all $tab $escaped {\\t} escaped
  return $escaped
}

proc write_run_archive {} {
  global folder top_proj_dir design_name def_file verilog_netlist sdc_file
  global lib_setup_file design_setup_file

  if {[info exists ::env(RUN_TIMESTAMP_UTC)] && $::env(RUN_TIMESTAMP_UTC) ne ""} {
    set run_timestamp_utc $::env(RUN_TIMESTAMP_UTC)
  } else {
    set run_timestamp_utc [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]
  }

  if {[info exists ::env(RUN_GIT_COMMIT)] && $::env(RUN_GIT_COMMIT) ne ""} {
    set run_git_commit $::env(RUN_GIT_COMMIT)
  } else {
    set run_git_commit "unknown"
  }

  file mkdir $folder
  set inputs_dir [file join $folder inputs]
  file mkdir $inputs_dir

  foreach source_path [list $def_file $verilog_netlist $sdc_file $lib_setup_file $design_setup_file] {
    file copy -force $source_path $inputs_dir
  }

  set manifest_path [file join $folder run_manifest.json]
  set fp [open $manifest_path w]
  puts $fp "{"
  puts $fp [format {  "design_name": "%s",} [json_escape $design_name]]
  puts $fp [format {  "run_timestamp_utc": "%s",} [json_escape $run_timestamp_utc]]
  puts $fp [format {  "git_commit": "%s",} [json_escape $run_git_commit]]
  puts $fp [format {  "top_proj_dir": "%s",} [json_escape $top_proj_dir]]
  puts $fp [format {  "design_setup_file": "%s",} [json_escape $design_setup_file]]
  puts $fp [format {  "lib_setup_file": "%s",} [json_escape $lib_setup_file]]
  puts $fp [format {  "def_file": "%s",} [json_escape $def_file]]
  puts $fp [format {  "verilog_netlist": "%s",} [json_escape $verilog_netlist]]
  puts $fp [format {  "sdc_file": "%s"} [json_escape $sdc_file]]
  puts $fp "}"
  close $fp
}

write_run_archive

# ================== helpers ==================

# Returns 1 if placement looks legal, 0 otherwise.
proc is_placement_legal {} {
  # If check_placement throws (e.g. DPL-0386), treat as illegal.
  if {[catch { check_placement -verbose } err]} {
    puts "check_placement reported errors: $err"
    return 0
  }
  return 1
}

# ================== (1) read tech, libs, DEF, netlist, link ==================
#foreach lef_file ${lefs}    { read_lef     $lef_file }
#foreach lib_file ${libbest} { read_liberty $lib_file }


puts $def_file 
puts $verilog_netlist
puts $sdc_file


read_def      $def_file
read_verilog  $verilog_netlist

read_sdc $sdc_file

#set_propagated_clock [get_clocks *]
set_ideal_network [all_clocks]

source $rc_file
estimate_parasitics -placement

# Keep units exactly as requested
set_cmd_units -time ns -capacitance pF -current mA -voltage V -resistance kOhm -distance um -power mW
set_units -power mW

puts "report_design_area start"
report_design_area 

# ================== (2) Check placement legality ==================
puts "### Check placement legality ###"
set placement_legal [is_placement_legal]
if {$placement_legal} {
  puts "Placement is legal"
} else {
  puts stderr "ERROR: Placement is NOT legal (continuing)"
  exit 1
}

# ================== (3) global route with auto-legalize retry ==================
# Route layer setup (override via design_setup.tcl if provided)
if {[info exists route_signal_layers]} { set sig_layers $route_signal_layers } else { set sig_layers "M2-M9" }
if {[info exists route_clock_layers]}  { set clk_layers $route_clock_layers }  else { set clk_layers "M2-M9" }

set_routing_layers -signal $sig_layers -clock $clk_layers
#set_global_routing_layer_adjustment * 0.5

puts "### Global routing (first attempt) ###"
set placement_legal 1
if {[catch { global_route -skip_large_fanout_nets 300 -allow_congestion -congestion_report_file $crfile } gr_err]} {
  # If GR fails (e.g., unplaced inst), legalize then retry
  puts "INFO: global_route failed on first attempt: $gr_err"
  puts "INFO: running detailed_placement, then retrying global_route..."
  set placement_legal 0
  detailed_placement
  if {[catch { global_route -skip_large_fanout_nets 300 -allow_congestion } gr_err2]} {
    puts stderr "ERROR: global_route still failing after detailed_placement: $gr_err2"
    exit 2
  }
}

puts "report_design_area after legalization"
report_design_area

# Estimate parasitics using global routing
estimate_parasitics -global_routing

set end [clock seconds]

# ================== (4) evaluation metrics (OpenSTA + OpenROAD) ==================
set TOTAL_INSTS [llength [get_cells *]]
puts "===== METRICS ====="
puts "design:                 $design_name"
puts "placement_legal:        $placement_legal"
puts [format "total_insts:            %d" $TOTAL_INSTS]
report_units
report_tns
report_wns -digits 4
report_power
puts "report_tns"

# ---- global routing overflow -----
puts "Start Global Routing Results Analysis ..."
set block [ord::get_db_block]
set gcellgrid [$block getGCellGrid]
set tech [$block getTech]
set layers {}
foreach layer [$tech getLayers] {
  set routing_level [$layer getRoutingLevel]
  if {$routing_level > 0} {
    lappend layers $layer
  }
}

puts "report_design_area after global_route"
report_design_area

# set layers [lsort -unique $layers]
set gird_x_count [llength [$gcellgrid getGridX]]
set gird_y_count [llength [$gcellgrid getGridY]]

## For loop for x from 0 to gird_x_count - 1
for {set x 0} {$x < $gird_x_count} {incr x} {
  for {set y 0} {$y < $gird_y_count} {incr y} {
    set capacity_value 0
    set usage_value 0
    foreach layer $layers {
      set capacity [$gcellgrid getCapacity $layer $x $y]
      set usage [$gcellgrid getUsage $layer $x $y]
      set capacity_value [expr $capacity_value + $capacity]
      set usage_value [expr $usage_value + $usage]
    }
    set congestion 0
    if {$capacity_value > 0} {
    set congestion [expr ($usage_value *100.0) / $capacity_value]
    }
    puts "$x $y $capacity_value $usage_value $congestion"
  }
}
puts "End Global Routing Results Analysis ..."


report_check_types -max_slew         -violators 
report_check_types -max_capacitance  -violators 
report_check_types -max_fanout       -violators
puts "report_design_area end"
report_design_area 


puts "\[INFO\] Flow running time:   [expr {$end - $start}] second"
