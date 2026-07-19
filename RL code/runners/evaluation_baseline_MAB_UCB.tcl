# Standard UCB1 evaluation runner.
# This file keeps the OpenROAD flow local and uses the shared arm catalog
# from core_shared/ so future algorithm swaps only change the selection logic.

set script_dir [file dirname [file normalize [info script]]]
set rl_code_dir [file dirname $script_dir]
set repo_root [file dirname $rl_code_dir]
set evaluation_dir [file join $repo_root evaluation]

if {[info exists ::env(TOP_PROJ_DIR)] && $::env(TOP_PROJ_DIR) ne ""} {
  set top_proj_dir $::env(TOP_PROJ_DIR)
} else {
  set top_proj_dir $repo_root
}

if {[info exists ::env(PROJ_DIR)] && $::env(PROJ_DIR) ne ""} {
  set proj_dir $::env(PROJ_DIR)
} else {
  set proj_dir $script_dir
}

if {[info exists ::env(DESIGN_NAME)] && $::env(DESIGN_NAME) ne ""} {
  set design_name $::env(DESIGN_NAME)
} else {
  error "DESIGN_NAME is required"
}

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
file mkdir $folder

set core_shared_dir [file join $rl_code_dir core_shared]

set lib_setup_file [file join $evaluation_dir $design_name lib_setup.tcl]
set design_setup_file [file join $evaluation_dir $design_name design_setup.tcl]
set arm_definitions_file [file join $core_shared_dir arm_definitions.tcl]

set start [clock seconds]
source $lib_setup_file
source $design_setup_file
source $arm_definitions_file

# ================== helpers ==================

# Placement is legal if OpenROAD can validate it without raising an error.
proc is_placement_legal {} {
  if {[catch {check_placement -verbose} err]} {
    puts "check_placement reported errors: $err"
    return 0
  }
  return 1
}

# Return a normalized improvement score.
# Positive values mean the new value is better than the old value.
proc pct_improvement {before after} {
  set denom [expr {abs($before)}]
  if {$denom < 1e-9} {
    set denom 1.0
  }
  return [expr {($after - $before) / $denom}]
}

# A compact reward that prefers timing improvement and penalizes extra area
# or any legalization recovery required after the arm executes.
proc compute_reward {wns_before tns_before area_before wns_after tns_after area_after legalization_used} {
  set wns_pct [pct_improvement $wns_before $wns_after]
  set tns_pct [pct_improvement $tns_before $tns_after]

  set area_delta [expr {$area_after - $area_before}]
  set area_penalty 0.0
  if {$area_delta > 0.0} {
    set denom [expr {abs($area_before)}]
    if {$denom < 1e-9} {
      set denom 1.0
    }
    set area_penalty [expr {$area_delta / $denom}]
  }

  set reward [expr {0.45 * $wns_pct + 0.45 * $tns_pct - 0.08 * $area_penalty - 0.02 * $legalization_used}]
  return [list $reward $wns_pct $tns_pct $area_penalty]
}

# Keep the arm source of truth in one place. If OFFLINE_ACTIVE_ARMS is set,
# use that subset; otherwise use the full arm catalog.
proc get_available_arms {} {
  if {[info exists ::env(OFFLINE_ACTIVE_ARMS)] && $::env(OFFLINE_ACTIVE_ARMS) ne ""} {
    return [split $::env(OFFLINE_ACTIVE_ARMS)]
  }
  return [arms::all_ids]
}

# State file format: arm,count,mean_reward
proc load_state {state_file} {
  set counts_dict {}
  set means_dict {}

  if {![file exists $state_file]} {
    return [list $counts_dict $means_dict]
  }

  set fh [open $state_file r]
  set lines [split [read $fh] "\n"]
  close $fh

  foreach line $lines {
    set line [string trim $line]
    if {$line eq ""} {
      continue
    }
    if {[string match "arm,*" $line]} {
      continue
    }

    set fields [split $line ","]
    if {[llength $fields] < 3} {
      continue
    }

    set arm [lindex $fields 0]
    set count [lindex $fields 1]
    set mean [lindex $fields 2]

    dict set counts_dict $arm $count
    dict set means_dict $arm $mean
  }

  return [list $counts_dict $means_dict]
}

proc save_state {state_file arms counts_dict means_dict} {
  set fh [open $state_file w]
  puts $fh "arm,count,mean_reward"
  foreach arm $arms {
    set count 0
    set mean 0.0
    if {[dict exists $counts_dict $arm]} {
      set count [dict get $counts_dict $arm]
    }
    if {[dict exists $means_dict $arm]} {
      set mean [dict get $means_dict $arm]
    }
    puts $fh "$arm,$count,$mean"
  }
  close $fh
}

# Standard UCB1 selection:
#   score = mean_reward + sqrt(2 * ln(total_pulls) / pulls_of_arm)
# Untried arms are selected first so every arm gets at least one sample.
proc ucb_pick_arm {arms state_file} {
  lassign [load_state $state_file] counts means

  set total_pulls 0
  foreach arm $arms {
    if {![dict exists $counts $arm]} {
      dict set counts $arm 0
      dict set means $arm 0.0
    }
    incr total_pulls [dict get $counts $arm]
  }

  foreach arm $arms {
    if {[dict get $counts $arm] == 0} {
      return $arm
    }
  }

  if {$total_pulls < 1} {
    return [lindex $arms 0]
  }

  set best_arm [lindex $arms 0]
  set best_score -1e100

  foreach arm $arms {
    set n [dict get $counts $arm]
    set mean [dict get $means $arm]
    set bonus [expr {sqrt(2.0 * log(double($total_pulls)) / double($n))}]
    set score [expr {$mean + $bonus}]

    if {$score > $best_score} {
      set best_score $score
      set best_arm $arm
    }
  }

  return $best_arm
}

# Incremental mean update for the selected arm.
proc ucb_update_arm {state_file selected_arm reward} {
  set arms [get_available_arms]
  lassign [load_state $state_file] counts means

  if {![dict exists $counts $selected_arm]} {
    dict set counts $selected_arm 0
    dict set means $selected_arm 0.0
  }

  set old_count [dict get $counts $selected_arm]
  set old_mean [dict get $means $selected_arm]
  set new_count [expr {$old_count + 1}]
  set new_mean [expr {$old_mean + (double($reward) - $old_mean) / double($new_count)}]

  dict set counts $selected_arm $new_count
  dict set means $selected_arm $new_mean

  save_state $state_file $arms $counts $means
}

proc run_selected_arm {arm_id} {
  set arm_cmd [arms::command $arm_id]
  if {$arm_cmd eq ""} {
    puts "\[INFO\] Selected arm $arm_id ([arms::name $arm_id]) is noop; skipping execution."
    return
  }

  puts "\[INFO\] Executing arm $arm_id ([arms::name $arm_id])"
  if {[catch {eval $arm_cmd} arm_err]} {
    puts stderr "ERROR: arm $arm_id failed: $arm_err"
    exit 3
  }
}

# ================== read tech, libs, DEF, netlist, link ==================

read_def $def_file
puts $def_file

read_verilog $verilog_netlist
puts $verilog_netlist

read_sdc $sdc_file
set_ideal_network [all_clocks]

set end_setting [clock seconds]

source $rc_file
estimate_parasitics -placement

# Keep units exactly as requested.
set_cmd_units -time ns -capacitance pF -current mA -voltage V -resistance kOhm -distance um
set_units -power mW

puts "report_design_area start"
report_design_area

# ================== UCB selection and execution ==================

set state_file [file join $folder ${design_name}_ucb_state.csv]
set available_arms [get_available_arms]
set selected_arm [ucb_pick_arm $available_arms $state_file]

puts "\[INFO\] UCB selected arm: $selected_arm ([arms::name $selected_arm])"

# Capture the baseline state before the arm changes the design.
set wns_before [worst_negative_slack -max]
set tns_before [total_negative_slack -max]
set area_before [rsz::design_area]

set legalization_used 0
run_selected_arm $selected_arm

# If the arm leaves placement illegal, recover with a legalization pass.
if {![is_placement_legal]} {
  set legalization_used 1
  puts "\[INFO\] Placement illegal after selected arm; running detailed_placement"
  detailed_placement
}

estimate_parasitics -placement

set wns_after [worst_negative_slack -max]
set tns_after [total_negative_slack -max]
set area_after [rsz::design_area]

lassign [compute_reward $wns_before $tns_before $area_before $wns_after $tns_after $area_after $legalization_used] reward wns_pct tns_pct area_penalty

puts [format "\[INFO\] UCB reward: %.6f (wns_pct=%.6f tns_pct=%.6f area_penalty=%.6f legalize=%d)" \
  $reward $wns_pct $tns_pct $area_penalty $legalization_used]
ucb_update_arm $state_file $selected_arm $reward

# ================== legalization if needed ==================

set start_rsz [clock seconds]
puts "\[INFO\] Start OpenROAD RSZ ..."
repair_design

puts "report_design_area after repair_design"
report_design_area

set placement_legal [is_placement_legal]
if {$placement_legal} {
  puts "Placement is legal; skip legalization."
} else {
  puts "Placement NOT legal; running detailed_placement..."
  detailed_placement
  set placement_legal [is_placement_legal]
  if {$placement_legal} {
    puts "Placement legalized."
  } else {
    puts stderr "WARN: Placement still illegal after detailed_placement."
  }
}

set end_rsz [clock seconds]

puts "report_design_area after legalization"
report_design_area

write_def ${folder}/${design_name}_baseline.def
write_verilog ${folder}/${design_name}_baseline.v

set start_flow [clock seconds]

# ================== global route with auto-legalize retry ==================

if {[info exists route_signal_layers]} {
  set sig_layers $route_signal_layers
} else {
  set sig_layers "M2-M9"
}
if {[info exists route_clock_layers]} {
  set clk_layers $route_clock_layers
} else {
  set clk_layers "M2-M9"
}

set_routing_layers -signal $sig_layers -clock $clk_layers

puts "### Global routing (first attempt) ###"
set placement_legal 1
if {[catch {global_route -skip_large_fanout_nets 300 -allow_congestion -congestion_iterations 50 -congestion_report_file $crfile} gr_err]} {
  puts "INFO: global_route failed on first attempt: $gr_err"
  puts "INFO: running detailed_placement, then retrying global_route..."
  set placement_legal 0

  detailed_placement
  if {[catch {global_route -skip_large_fanout_nets 300 -allow_congestion -congestion_iterations 50} gr_err2]} {
    puts stderr "ERROR: global_route still failing after detailed_placement: $gr_err2"
    exit 2
  }
}

puts "report_design_area after global_route"
report_design_area

estimate_parasitics -global_routing

set end_flow [clock seconds]

# ================== evaluation metrics (OpenSTA + OpenROAD) ==================

set TOTAL_INSTS [llength [get_cells *]]
puts "===== METRICS ====="
puts "design:                 $design_name"
puts "placement_legal:        $placement_legal"
puts [format "total_insts:            %d" $TOTAL_INSTS]
report_units
report_tns
report_wns -digits 4
report_power

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

set gird_x_count [llength [$gcellgrid getGridX]]
set gird_y_count [llength [$gcellgrid getGridY]]

for {set x 0} {$x < $gird_x_count} {incr x} {
  for {set y 0} {$y < $gird_y_count} {incr y} {
    set capacity_value 0
    set usage_value 0
    foreach layer $layers {
      set capacity [$gcellgrid getCapacity $layer $x $y]
      set usage [$gcellgrid getUsage $layer $x $y]
      set capacity_value [expr {$capacity_value + $capacity}]
      set usage_value [expr {$usage_value + $usage}]
    }
    set congestion 0
    if {$capacity_value > 0} {
      set congestion [expr {($usage_value * 100.0) / $capacity_value}]
    }
    puts "$x $y $capacity_value $usage_value $congestion"
  }
}
puts "End Global Routing Results Analysis ..."

report_check_types -max_slew        -violators
report_check_types -max_capacitance -violators
report_check_types -max_fanout      -violators

puts "report_design_area end"
report_design_area

puts "\[INFO\] OpenROAD RSZ running time:   [expr {$end_rsz - $start_rsz}] second"
puts "\[INFO\] Flow running time:   [expr {$end_flow - $start_flow + $end_setting - $start}] second"
