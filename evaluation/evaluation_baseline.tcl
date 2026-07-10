# Use OR repair_timing to perform buffering&sizing

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

# Percentage improvement helper used for bandit reward normalization.
proc pct_improvement {before after} {
  set denom [expr {abs($before)}]
  if {$denom < 1e-9} {
    set denom 1.0
  }
  return [expr {($after - $before) / $denom}]
}

# ================== (1) read tech, libs, DEF, netlist, link ==================
# foreach lef_file ${lefs}    { read_lef     $lef_file }
# foreach lib_file ${libbest} { read_liberty $lib_file }

read_def      $def_file

puts $def_file 

read_verilog  $verilog_netlist

 
puts $verilog_netlist


read_sdc $sdc_file
#set_propagated_clock [get_clocks *]
set_ideal_network [all_clocks]

set end_setting [clock seconds]

source $rc_file
estimate_parasitics -placement

# Keep units exactly as requested
set_cmd_units -time ns -capacitance pF -current mA -voltage V -resistance kOhm -distance um
set_units -power mW

puts "report_design_area start"
report_design_area 

set start_rsz [clock seconds]
puts "\[INFO\] Start OpenROAD RSZ ..."
repair_design

puts "report_design_area after repair_design"
report_design_area 

# ================== simple 8-arm explore-first bandit ==================
set bandit_py [file join $proj_dir bandit_round_robin.py]
set bandit_state [file join $folder ${design_name}_bandit_state.json]

if {[info exists ::env(BANDIT_ITERS)] && $::env(BANDIT_ITERS) ne ""} {
  set bandit_iters $::env(BANDIT_ITERS)
} else {
  set bandit_iters 5
}

if {[info exists ::env(BANDIT_MAX_ITERATIONS)] && $::env(BANDIT_MAX_ITERATIONS) ne ""} {
  set bandit_max_iterations $::env(BANDIT_MAX_ITERATIONS)
} else {
  set bandit_max_iterations 400
}

if {[info exists ::env(BANDIT_MAX_REPAIRS_PER_PASS)] && $::env(BANDIT_MAX_REPAIRS_PER_PASS) ne ""} {
  set bandit_max_repairs_per_pass $::env(BANDIT_MAX_REPAIRS_PER_PASS)
} else {
  set bandit_max_repairs_per_pass 800
}

#set timing_guard_opts "-max_iterations $bandit_max_iterations -max_repairs_per_pass $bandit_max_repairs_per_pass"
set timing_guard_opts ""


file mkdir $folder
if {[catch {exec python3 $bandit_py init --state $bandit_state --iterations $bandit_iters} bandit_init_err]} {
  puts stderr "ERROR: Failed to initialize bandit policy: $bandit_init_err"
  exit 3
}

for {set bandit_iter 0} {$bandit_iter < $bandit_iters} {incr bandit_iter} {
  if {[catch {exec python3 $bandit_py select --state $bandit_state} arm_id_raw]} {
    puts stderr "ERROR: Failed to select bandit arm: $arm_id_raw"
    exit 3
  }
  set arm_id [string trim $arm_id_raw]

  if {$arm_id eq "-1"} {
    puts "\[INFO\] Bandit budget exhausted."
    break
  }

  set wns_before [worst_negative_slack -max]
  set tns_before [total_negative_slack -max]
  set area_before [rsz::design_area]
  set legalization_used 0

  switch -- $arm_id {
    0 {
      set arm_name "setup_fast_sizeup"
      set arm_cmd "repair_timing -setup -sequence \"sizeup\" -repair_tns 20 -max_passes 25 $timing_guard_opts"
    }
    1 {
      set arm_name "setup_fast_sizeup_buffer"
      set arm_cmd "repair_timing -setup -sequence \"sizeup,buffer\" -repair_tns 20 -max_passes 30 $timing_guard_opts"
    }
    2 {
      set arm_name "setup_medium_sizeup_buffer_split"
      set arm_cmd "repair_timing -setup -sequence \"sizeup,buffer,split\" -repair_tns 40 -max_passes 40 $timing_guard_opts"
    }
    3 {
      set arm_name "setup_no_clone_no_swap"
      set arm_cmd "repair_timing -setup -skip_gate_cloning -skip_pin_swap -repair_tns 40 -max_passes 40 $timing_guard_opts"
    }
    4 {
      set arm_name "setup_deep"
      set arm_cmd "repair_timing -setup -sequence \"sizeup,buffer,split\" -repair_tns 70 -max_passes 80 $timing_guard_opts"
    }
    5 {
      set arm_name "hold_light"
      set arm_cmd "repair_timing -hold -hold_margin 0.01 -max_buffer_percent 2 -max_passes 20 $timing_guard_opts"
    }
    6 {
      set arm_name "legalize_only"
      set arm_cmd "detailed_placement"
    }
    7 {
      set arm_name "noop"
      set arm_cmd ""
    }
    default {
      puts stderr "ERROR: Unknown arm id selected by policy: $arm_id"
      exit 3
    }
  }

  puts "\[INFO\] Bandit iter [expr {$bandit_iter + 1}] / $bandit_iters: arm=$arm_id ($arm_name)"

  if {$arm_cmd ne ""} {
    set arm_start [clock seconds]
    if {[catch {eval $arm_cmd} arm_err]} {
      puts stderr "WARN: Arm command failed for $arm_name: $arm_err"
    }
    set arm_end [clock seconds]
    puts "\[INFO\] Arm runtime: [expr {$arm_end - $arm_start}] second"
  }

  if {![is_placement_legal]} {
    set legalization_used 1
    puts "\[INFO\] Placement illegal after arm pull; running detailed_placement"
    detailed_placement
  }

  estimate_parasitics -placement

  set wns_after [worst_negative_slack -max]
  set tns_after [total_negative_slack -max]
  set area_after [rsz::design_area]

  set wns_pct [pct_improvement $wns_before $wns_after]
  set tns_pct [pct_improvement $tns_before $tns_after]
  set area_pct [pct_improvement $area_before $area_after]
  set area_penalty [expr {$area_pct > 0.0 ? $area_pct : 0.0}]

  # 80% timing (WNS/TNS) and 20% area/legality.
  set reward [expr {0.4 * $wns_pct + 0.4 * $tns_pct - 0.15 * $area_penalty - 0.05 * $legalization_used}]

  puts [format "\[INFO\] Bandit reward: %.6f (wns_pct=%.6f tns_pct=%.6f area_pct=%.6f legalize=%d)" \
    $reward $wns_pct $tns_pct $area_pct $legalization_used]

  if {[catch {
    exec python3 $bandit_py update \
      --state $bandit_state \
      --arm-id $arm_id \
      --reward $reward \
      --wns-before $wns_before \
      --wns-after $wns_after \
      --tns-before $tns_before \
      --tns-after $tns_after \
      --area-before $area_before \
      --area-after $area_after \
      --wns-pct $wns_pct \
      --tns-pct $tns_pct \
      --area-pct $area_pct \
      --legalization-used $legalization_used
  } bandit_update_err]} {
    puts stderr "ERROR: Failed to update bandit state: $bandit_update_err"
    exit 3
  }
}

set end_rsz [clock seconds]
puts "\[INFO\] OR RSZ runtime:   [expr {$end_rsz - $start_rsz}] second"



set start_flow [clock seconds]
# ================== (2) legalization if needed ==================
puts "### Check placement legality ###"
set placement_legal [is_placement_legal]
if {$placement_legal} {
  puts "Placement is legal; skip legalization."
} else {
  puts "Placement NOT legal; running detailed_placement..."

  detailed_placement
  # Best-effort re-check
  set placement_legal [is_placement_legal]
  if {$placement_legal} {
    puts "Placement legalized."
  } else {
    puts stderr "WARN: Placement still illegal after detailed_placement."
  }
}

puts "report_design_area after legalization"
report_design_area 

# Write out baseline results after detailed placement
write_def ${folder}/${design_name}_baseline.def
write_verilog ${folder}/${design_name}_baseline.v


# ================== (3) global route with auto-legalize retry ==================
# Route layer setup (override via design_setup.tcl if provided)
if {[info exists route_signal_layers]} { set sig_layers $route_signal_layers } else { set sig_layers "M2-M9" }
if {[info exists route_clock_layers]}  { set clk_layers $route_clock_layers }  else { set clk_layers "M2-M9" }

set_routing_layers -signal $sig_layers -clock $clk_layers
#set_global_routing_layer_adjustment * 0.5



puts "### Global routing (first attempt) ###"
set placement_legal 1
if {[catch { global_route -skip_large_fanout_nets 300 -allow_congestion -congestion_iterations 50 -congestion_report_file $crfile } gr_err]} {
  # If GR fails (e.g., unplaced inst), legalize then retry
  puts "INFO: global_route failed on first attempt: $gr_err"
  puts "INFO: running detailed_placement, then retrying global_route..."
  set placement_legal 0

  detailed_placement
  if {[catch { global_route -skip_large_fanout_nets 300 -allow_congestion -congestion_iterations 50} gr_err2]} {
    puts stderr "ERROR: global_route still failing after detailed_placement: $gr_err2"
    exit 2
  }
}

puts "report_design_area after global_route"
report_design_area

# Estimate parasitics using global routing
estimate_parasitics -global_routing

set end_flow [clock seconds]

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

puts "\[INFO\] OpenROAD RSZ running time:   [expr {$end_rsz - $start_rsz}] second"
puts "\[INFO\] Flow running time:   [expr {$end_flow - $start_flow + $end_setting - $start}] second"