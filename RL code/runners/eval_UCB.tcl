# Minimal UCB runner with in-memory state only.
# Uses shared arm catalog from RL code/core_shared/arm_definitions.tcl.

# ================== environment & setup ==================
set script_dir [file dirname [file normalize [info script]]]
set default_top_proj_dir [file dirname $script_dir]

if {[info exists ::env(TOP_PROJ_DIR)] && $::env(TOP_PROJ_DIR) ne ""} {
  set top_proj_dir $::env(TOP_PROJ_DIR)
} else {
  set top_proj_dir $default_top_proj_dir
}

set evaluation_dir [file join $top_proj_dir evaluation]
set core_shared_dir [file join $top_proj_dir {RL code} core_shared]

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

set lib_setup_file [file join $evaluation_dir $design_name lib_setup.tcl]
set design_setup_file [file join $evaluation_dir $design_name design_setup.tcl]
set arm_definitions_file [file join $core_shared_dir arm_definitions.tcl]

set start [clock seconds]
source $lib_setup_file
source $design_setup_file
source $arm_definitions_file

# ================== helpers ==================

proc is_placement_legal {} {
  if {[catch {check_placement -verbose} err]} {
    puts "check_placement reported errors: $err"
    return 0
  }
  return 1
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
    puts stderr "ERROR: No active arms selected"
    exit 3
  }
  return $normalized
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

proc ucb_emit {msg} {
  global ucb_log_fh
  puts $msg
  puts $ucb_log_fh $msg
  flush $ucb_log_fh
}

proc sign {x} {
  if {$x > 0} { return 1 }
  if {$x < 0} { return -1 }
  return 0
}

# Reward = sign(delta) * ln(1 + abs(delta)), where delta = WNS_after - WNS_before
proc sym_log_reward {wns_before wns_after} {
  set delta [expr {$wns_after - $wns_before}]
  set reward [expr {[sign $delta] * log(1.0 + abs($delta))}]
  return [list $delta $reward]
}

# Returns: selected_arm estimated_mean ucb_score pulls_before
proc ucb_select_arm {arm_ids counts means} {
  set total_pulls 0
  foreach arm_id $arm_ids {
    incr total_pulls [dict get $counts $arm_id]
  }

  foreach arm_id $arm_ids {
    if {[dict get $counts $arm_id] == 0} {
      return [list $arm_id [dict get $means $arm_id] 1e100 0]
    }
  }

  set best_arm [lindex $arm_ids 0]
  set best_score -1e100
  foreach arm_id $arm_ids {
    set pulls [dict get $counts $arm_id]
    set mean [dict get $means $arm_id]
    set bonus [expr {sqrt(2.0 * log(double($total_pulls)) / double($pulls))}]
    set score [expr {$mean + $bonus}]
    if {$score > $best_score} {
      set best_score $score
      set best_arm $arm_id
    }
  }

  return [list $best_arm [dict get $means $best_arm] $best_score [dict get $counts $best_arm]]
}

proc ucb_final_score {mean total_pulls pulls} {
  if {$pulls == 0} {
    return "inf"
  }
  if {$total_pulls <= 1} {
    return [format "%.6f" $mean]
  }
  set bonus [expr {sqrt(2.0 * log(double($total_pulls)) / double($pulls))}]
  return [format "%.6f" [expr {$mean + $bonus}]]
}

proc print_gr_overflow_table {} {
  puts "Start Global Routing Results Analysis ..."
  set block [ord::get_db_block]
  set gcellgrid [$block getGCellGrid]
  set tech [$block getTech]
  set layers {}
  foreach layer [$tech getLayers] {
    if {[$layer getRoutingLevel] > 0} {
      lappend layers $layer
    }
  }

  set grid_x_count [llength [$gcellgrid getGridX]]
  set grid_y_count [llength [$gcellgrid getGridY]]

  for {set x 0} {$x < $grid_x_count} {incr x} {
    for {set y 0} {$y < $grid_y_count} {incr y} {
      set capacity_value 0
      set usage_value 0
      foreach layer $layers {
        set capacity_value [expr {$capacity_value + [$gcellgrid getCapacity $layer $x $y]}]
        set usage_value [expr {$usage_value + [$gcellgrid getUsage $layer $x $y]}]
      }
      set congestion 0
      if {$capacity_value > 0} {
        set congestion [expr {($usage_value * 100.0) / $capacity_value}]
      }
      puts "$x $y $capacity_value $usage_value $congestion"
    }
  }
  puts "End Global Routing Results Analysis ..."
}

# ================== read design ==================

read_def $def_file
puts $def_file

read_verilog $verilog_netlist
puts $verilog_netlist

read_sdc $sdc_file
set_ideal_network [all_clocks]

set end_setting [clock seconds]

source $rc_file
estimate_parasitics -placement

set_cmd_units -time ns -capacitance pF -current mA -voltage V -resistance kOhm -distance um
set_units -power mW

puts "report_design_area start"
report_design_area

file mkdir $folder
set ucb_log_file [file join $folder ucb_compact.log]
set ucb_log_fh [open $ucb_log_file w]

# ================== UCB optimization loop ==================

if {[info exists ::env(UCB_ITERS)] && $::env(UCB_ITERS) ne ""} {
  set ucb_iters $::env(UCB_ITERS)
} elseif {[info exists ::env(BANDIT_ITERS)] && $::env(BANDIT_ITERS) ne ""} {
  set ucb_iters $::env(BANDIT_ITERS)
} else {
  set ucb_iters 24
}

set active_arm_ids [arms::all_ids]
if {[info exists ::env(OFFLINE_ACTIVE_ARMS)] && $::env(OFFLINE_ACTIVE_ARMS) ne ""} {
  set active_arm_ids $::env(OFFLINE_ACTIVE_ARMS)
}
set active_arm_ids [normalize_arm_id_list $active_arm_ids]

ucb_emit [format "\[UCB\]\[RUN\] rounds=%d" $ucb_iters]
ucb_emit [format "\[UCB\]\[RUN\] active_arms=%s" [join [lmap arm_id $active_arm_ids {arms::describe $arm_id}] {, }]]

set counts {}
set means {}
foreach arm_id $active_arm_ids {
  dict set counts $arm_id 0
  dict set means $arm_id 0.0
}

set start_rsz [clock seconds]
for {set iter 1} {$iter <= $ucb_iters} {incr iter} {
  lassign [ucb_select_arm $active_arm_ids $counts $means] arm_id mean_est ucb_score pulls_before

  if {$pulls_before == 0} {
    set ucb_score_str "INF"
  } else {
    set ucb_score_str [format "%.6f" $ucb_score]
  }

  set iter_start_ts [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]
  ucb_emit [format "\[UCB\]\[ITER_START\] time=%s iter=%d/%d arm_id=%s arm_name=%s est_mean=%.6f ucb_score=%s pulls_before=%d" \
    $iter_start_ts $iter $ucb_iters $arm_id [arms::name $arm_id] $mean_est $ucb_score_str $pulls_before]

  set wns_before [worst_negative_slack -max]
  run_selected_arm $arm_id

  if {![is_placement_legal]} {
    puts "\[INFO\] Placement illegal after arm $arm_id; running detailed_placement"
    detailed_placement
  }

  estimate_parasitics -placement
  set wns_after [worst_negative_slack -max]

  lassign [sym_log_reward $wns_before $wns_after] delta reward

  set old_count [dict get $counts $arm_id]
  set old_mean [dict get $means $arm_id]
  set new_count [expr {$old_count + 1}]
  set new_mean [expr {$old_mean + (double($reward) - $old_mean) / double($new_count)}]

  dict set counts $arm_id $new_count
  dict set means $arm_id $new_mean

  set iter_end_ts [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]
  ucb_emit [format "\[UCB\]\[ITER_RESULT\] time=%s iter=%d/%d delta=%.6f reward_symlog=%.6f updated_mean=%.6f" \
    $iter_end_ts $iter $ucb_iters $delta $reward $new_mean]
}
set end_rsz [clock seconds]

set total_pulls 0
foreach arm_id $active_arm_ids {
  incr total_pulls [dict get $counts $arm_id]
}

ucb_emit "===== UCB FINAL SUMMARY ====="
foreach arm_id $active_arm_ids {
  set pull_count [dict get $counts $arm_id]
  set mean_score [dict get $means $arm_id]
  set final_ubc [ucb_final_score $mean_score $total_pulls $pull_count]
  ucb_emit [format "\[UCB\]\[ARM\] arm_id=%s arm_name=%s pick_count=%d final_score=%.6f final_UBC_score=%s" \
    $arm_id [arms::name $arm_id] $pull_count $mean_score $final_ubc]
}

# ================== finish physical flow ==================

puts "report_design_area after UCB"
report_design_area

puts "### Check placement legality ###"
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

puts "report_design_area after legalization"
report_design_area

file mkdir $folder
write_def ${folder}/${design_name}_baseline.def
write_verilog ${folder}/${design_name}_baseline.v

set start_flow [clock seconds]

if {[info exists route_signal_layers]} { set sig_layers $route_signal_layers } else { set sig_layers "M2-M9" }
if {[info exists route_clock_layers]}  { set clk_layers $route_clock_layers }  else { set clk_layers "M2-M9" }
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

# ================== metrics ==================

set TOTAL_INSTS [llength [get_cells *]]
puts "===== METRICS ====="
puts "design:                 $design_name"
puts "placement_legal:        $placement_legal"
puts [format "total_insts:            %d" $TOTAL_INSTS]
report_units
report_tns
report_wns -digits 4
report_power

print_gr_overflow_table

report_check_types -max_slew        -violators
report_check_types -max_capacitance -violators
report_check_types -max_fanout      -violators

puts "report_design_area end"
report_design_area

puts "\[INFO\] OR RSZ running time:   [expr {$end_rsz - $start_rsz}] second"
puts "\[INFO\] Flow running time:   [expr {$end_flow - $start_flow + $end_setting - $start}] second"

close $ucb_log_fh
