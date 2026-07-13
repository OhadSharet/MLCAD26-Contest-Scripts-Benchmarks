# Run exactly one offline arm from a clean process and append results to shootout state.

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
set arm_id $::env(ARM_ID)
set budget_sec $::env(OFFLINE_ARM_BUDGET_SEC)
set shootout_state $::env(SHOOTOUT_STATE)

set lib_setup_file [file join $script_dir $design_name lib_setup.tcl]
set design_setup_file [file join $script_dir $design_name design_setup.tcl]
source $lib_setup_file
source $design_setup_file

proc is_placement_legal {} {
  if {[catch { check_placement -verbose } err]} {
    puts "check_placement reported errors: $err"
    return 0
  }
  return 1
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

read_def $def_file
read_verilog $verilog_netlist
read_sdc $sdc_file
set_ideal_network [all_clocks]
source $rc_file
estimate_parasitics -placement

set_cmd_units -time ns -capacitance pF -current mA -voltage V -resistance kOhm -distance um
set_units -power mW

set timing_guard_opts ""

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
    puts stderr "ERROR: Unknown arm id: $arm_id"
    exit 3
  }
}

puts "\[INFO\] Offline arm runner arm=$arm_id ($arm_name), budget=${budget_sec}s"

set arm_start [clock seconds]
set arm_iterations 0
set arm_legalization_events 0
set arm_errors 0

while {1} {
  set elapsed_now [expr {[clock seconds] - $arm_start}]
  if {$elapsed_now >= $budget_sec} {
    break
  }

  if {$arm_cmd ne ""} {
    if {[catch {eval $arm_cmd} arm_err]} {
      incr arm_errors
      puts stderr "WARN: Arm command failed for $arm_name: $arm_err"
    }
  }

  if {![is_placement_legal]} {
    incr arm_legalization_events
    puts "\[INFO\] Placement illegal after arm step; running detailed_placement"
    if {[catch {detailed_placement} dpl_err]} {
      incr arm_errors
      puts stderr "WARN: detailed_placement failed during arm $arm_name: $dpl_err"
    }
  }

  estimate_parasitics -placement
  incr arm_iterations
}

set arm_elapsed [expr {[clock seconds] - $arm_start}]
set final_metrics [collect_eval_metrics]
set final_wns [dict get $final_metrics wns]
set final_tns [dict get $final_metrics tns]
set final_area [dict get $final_metrics area]
set final_slew [dict get $final_metrics slew]

set shootout_py [file join $proj_dir offline_shootout_state.py]
if {[catch {
  exec python3 $shootout_py record-final \
    --state $shootout_state \
    --arm-id $arm_id \
    --arm-name $arm_name \
    --iterations $arm_iterations \
    --elapsed-sec $arm_elapsed \
    --legalization-events $arm_legalization_events \
    --arm-errors $arm_errors \
    --final-wns $final_wns \
    --final-tns $final_tns \
    --final-area $final_area \
    --final-slew $final_slew
} record_err]} {
  puts stderr "ERROR: Failed to record final arm results: $record_err"
  exit 3
}

puts [format "\[INFO\] Arm %d done: iter=%d elapsed=%ds final_wns=%.6f final_tns=%.6f final_area=%.6f final_slew=%.2f" \
  $arm_id $arm_iterations $arm_elapsed $final_wns $final_tns $final_area $final_slew]
