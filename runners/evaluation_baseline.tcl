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
set arm_definitions_file [file join $script_dir arm_definitions.tcl]

set start [clock seconds]
source $lib_setup_file
source $design_setup_file
source $arm_definitions_file

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

# Percentage reduction where lower is better (e.g., slew violation count).
proc pct_reduction {before after} {
  set denom [expr {abs($before)}]
  if {$denom < 1e-9} {
    set denom 1.0
  }
  return [expr {($before - $after) / $denom}]
}

proc get_slew_violator_count {} {
  if {[catch {set cnt [sta::max_slew_violation_count]} slew_err]} {
    puts stderr "WARN: max slew violation query failed: $slew_err"
    return 0
  }
  return $cnt
}

proc get_design_area_from_db {} {
  if {[catch {set block [ord::get_db_block]} area_err]} {
    puts stderr "WARN: failed to access db block for area: $area_err"
    return 0.0
  }

  if {$block == "NULL"} {
    return 0.0
  }

  set dbu [$block getDbUnitsPerMicron]
  if {$dbu <= 0} {
    return 0.0
  }

  set total_area_dbu2 0.0
  foreach inst [$block getInsts] {
    set master [$inst getMaster]
    if {$master == "NULL"} {
      continue
    }
    set width [$master getWidth]
    set height [$master getHeight]
    set total_area_dbu2 [expr {$total_area_dbu2 + (double($width) * double($height))}]
  }

  return [expr {$total_area_dbu2 / (double($dbu) * double($dbu))}]
}

proc collect_eval_metrics {} {
  set wns [worst_negative_slack -max]
  set tns [total_negative_slack -max]
  set area [get_design_area_from_db]
  set slew [get_slew_violator_count]
  return [dict create wns $wns tns $tns area $area slew $slew]
}

proc normalize_arm_id_list {arm_ids} {
  set normalized {}
  foreach arm_id $arm_ids {
    if {$arm_id eq ""} {
      continue
    }
    if {[lsearch -exact $normalized $arm_id] >= 0} {
      continue
    }
    if {[catch {arms::get $arm_id} arm_err]} {
      puts stderr "ERROR: Invalid active arm id $arm_id: $arm_err"
      exit 3
    }
    lappend normalized $arm_id
  }
  if {[llength $normalized] == 0} {
    puts stderr "ERROR: No active arms selected for offline shootout"
    exit 3
  }
  return $normalized
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
puts "\[INFO\] Start offline arm shootout ..."

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

if {[info exists ::env(OFFLINE_ARM_BUDGET_SEC)] && $::env(OFFLINE_ARM_BUDGET_SEC) ne ""} {
  set offline_arm_budget_sec $::env(OFFLINE_ARM_BUDGET_SEC)
} else {
  set offline_arm_budget_sec 3600
}

#set timing_guard_opts "-max_iterations $bandit_max_iterations -max_repairs_per_pass $bandit_max_repairs_per_pass"
set timing_guard_opts ""

file mkdir $folder
set shootout_py [file join $proj_dir offline_shootout_state.py]
set shootout_state [file join $folder ${design_name}_offline_shootout.json]
set shootout_winner [file join $folder ${design_name}_offline_winner.json]
set arm_runner_tcl [file join $proj_dir offline_arm_runner.tcl]

# Code-level default selection. Edit this list directly when you want a different subset.
set offline_active_arm_ids [arms::all_ids]
if {[info exists ::env(OFFLINE_ACTIVE_ARMS)] && $::env(OFFLINE_ACTIVE_ARMS) ne ""} {
  set offline_active_arm_ids $::env(OFFLINE_ACTIVE_ARMS)
}
set offline_active_arm_ids [normalize_arm_id_list $offline_active_arm_ids]
puts [format "\[INFO\] Active arms selected for this run: %s" [join [lmap arm_id $offline_active_arm_ids {arms::describe $arm_id}] {, }]]

# Minute-0 baseline metrics before any arm optimization starts.
estimate_parasitics -placement
set baseline_metrics [collect_eval_metrics]
set base_wns [dict get $baseline_metrics wns]
set base_tns [dict get $baseline_metrics tns]
set base_area [dict get $baseline_metrics area]
set base_slew [dict get $baseline_metrics slew]
puts [format "\[INFO\] Baseline (minute 0): wns=%.6f tns=%.6f area=%.6f slew=%d" \
  $base_wns $base_tns $base_area $base_slew]

if {[catch {
  exec python3 $shootout_py init \
    --state $shootout_state \
    --design-name $design_name \
    --budget-sec $offline_arm_budget_sec \
    --arm-ids {*}$offline_active_arm_ids \
    --arm-names {*}[lmap arm_id $offline_active_arm_ids {arms::name $arm_id}] \
    --baseline-wns $base_wns \
    --baseline-tns $base_tns \
    --baseline-area $base_area \
    --baseline-slew $base_slew
} shootout_init_err]} {
  puts stderr "ERROR: Failed to initialize offline shootout state: $shootout_init_err"
  exit 3
}

foreach arm_id $offline_active_arm_ids {
  puts "\[INFO\] Launching isolated shootout arm process: arm=$arm_id"
  if {[catch {
    exec env \
      TOP_PROJ_DIR=$top_proj_dir \
      PROJ_DIR=$proj_dir \
      DESIGN_NAME=$design_name \
      ARM_ID=$arm_id \
      OFFLINE_ARM_BUDGET_SEC=$offline_arm_budget_sec \
      SHOOTOUT_STATE=$shootout_state \
      $top_proj_dir/OpenROAD/build/bin/openroad -exit $arm_runner_tcl \
      >@stdout 2>@stdout
  } arm_run_err]} {
    puts stderr "ERROR: Offline arm runner failed for arm $arm_id: $arm_run_err"
    exit 3
  }
}

if {[catch {exec python3 $shootout_py finalize --state $shootout_state --winner-out $shootout_winner} winner_id_raw]} {
  puts stderr "ERROR: Failed to finalize offline shootout winner: $winner_id_raw"
  exit 3
}
set winner_id [string trim $winner_id_raw]
puts "\[INFO\] Offline shootout winner arm: $winner_id"

# Continue the rest of the flow from the exact baseline starting line.
# Parent process has remained at minute-0 baseline state throughout shootout arm subprocesses.

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