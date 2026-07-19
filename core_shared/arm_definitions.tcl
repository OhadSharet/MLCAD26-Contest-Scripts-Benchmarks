# Shared offline arm catalog.

namespace eval arms {
  variable definitions
  set definitions [dict create \
    0 [dict create name "setup_fast_sizeup" cmd {repair_timing -setup -sequence "sizeup" -repair_tns 20 -max_passes 25}] \
    1 [dict create name "setup_fast_sizeup_buffer" cmd {repair_timing -setup -sequence "sizeup,buffer" -repair_tns 20 -max_passes 30}] \
    2 [dict create name "setup_medium_sizeup_buffer_split" cmd {repair_timing -setup -sequence "sizeup,buffer,split" -repair_tns 40 -max_passes 40}] \
    3 [dict create name "setup_no_clone_no_swap" cmd {repair_timing -setup -skip_gate_cloning -skip_pin_swap -repair_tns 40 -max_passes 40}] \
    4 [dict create name "setup_deep" cmd {repair_timing -setup -sequence "sizeup,buffer,split" -repair_tns 70 -max_passes 80}] \
    5 [dict create name "hold_light" cmd {repair_timing -hold -hold_margin 0.01 -max_buffer_percent 2 -max_passes 20}] \
    6 [dict create name "legalize_only" cmd {detailed_placement}] \
    7 [dict create name "noop" cmd {}] \
    8 [dict create name "repair_slew_cap_micro" cmd {repair_design}] \
    9 [dict create name "setup_micro_sizeup" cmd {repair_timing -setup -sequence "sizeup" -repair_tns 5 -max_passes 3}] \
    10 [dict create name "setup_micro_buffer" cmd {repair_timing -setup -sequence "buffer" -repair_tns 5 -max_passes 3}] \
    11 [dict create name "setup_wns_scalpel" cmd {repair_timing -setup -repair_tns 1 -max_passes 5}] \
    12 [dict create name "setup_margin_push" cmd {repair_timing -setup -setup_margin 0.02 -repair_tns 5 -max_passes 3}] \
    13 [dict create name "setup_topo_only" cmd {repair_timing -setup -skip_buffer_insertion -skip_gate_cloning -repair_tns 10 -max_passes 5}] \
    14 [dict create name "hold_micro_safe" cmd {repair_timing -hold -max_buffer_percent 0.5 -max_passes 2}] \
    15 [dict create name "slew_margin_tighten" cmd {repair_design -slew_margin 0.05 -cap_margin 0.05}]
  ]
}

proc arms::all_ids {} {
  variable definitions
  return [lsort -integer [dict keys $definitions]]
}

proc arms::all_names {} {
  variable definitions
  set names {}
  foreach arm_id [arms::all_ids] {
    lappend names [dict get [dict get $definitions $arm_id] name]
  }
  return $names
}

proc arms::get {arm_id} {
  variable definitions
  if {![dict exists $definitions $arm_id]} {
    error "Unknown arm id: $arm_id"
  }
  return [dict get $definitions $arm_id]
}

proc arms::name {arm_id} {
  return [dict get [arms::get $arm_id] name]
}

proc arms::command {arm_id} {
  return [dict get [arms::get $arm_id] cmd]
}

proc arms::describe {arm_id} {
  return [format "%s:%s" $arm_id [arms::name $arm_id]]
}