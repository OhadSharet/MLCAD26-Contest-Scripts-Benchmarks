set asap7_dir [file join $top_proj_dir asap7]

set tech_lef [file join $asap7_dir lef asap7_tech_1x_201209.lef]

set std_lef [list \
  [file join $asap7_dir lef asap7sc7p5t_28_L_1x_220121a.lef] \
  [file join $asap7_dir lef asap7sc7p5t_28_R_1x_220121a.lef] \
  [file join $asap7_dir lef asap7sc7p5t_28_SL_1x_220121a.lef] \
  [file join $asap7_dir lef sram_asap7_64x256_1rw.lef]]

set lib_files [list \
  [file join $asap7_dir lib asap7sc7p5t_AO_LVT_FF_nldm_211120.lib] \
  [file join $asap7_dir lib asap7sc7p5t_AO_RVT_FF_nldm_211120.lib] \
  [file join $asap7_dir lib asap7sc7p5t_AO_SLVT_FF_nldm_211120.lib] \
  [file join $asap7_dir lib asap7sc7p5t_INVBUF_LVT_FF_nldm_220122.lib] \
  [file join $asap7_dir lib asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.lib] \
  [file join $asap7_dir lib asap7sc7p5t_INVBUF_SLVT_FF_nldm_220122.lib] \
  [file join $asap7_dir lib asap7sc7p5t_OA_LVT_FF_nldm_211120.lib] \
  [file join $asap7_dir lib asap7sc7p5t_OA_RVT_FF_nldm_211120.lib] \
  [file join $asap7_dir lib asap7sc7p5t_OA_SLVT_FF_nldm_211120.lib] \
  [file join $asap7_dir lib asap7sc7p5t_SEQ_LVT_FF_nldm_220123.lib] \
  [file join $asap7_dir lib asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib] \
  [file join $asap7_dir lib asap7sc7p5t_SEQ_SLVT_FF_nldm_220123.lib] \
  [file join $asap7_dir lib asap7sc7p5t_SIMPLE_LVT_FF_nldm_211120.lib] \
  [file join $asap7_dir lib asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib] \
  [file join $asap7_dir lib asap7sc7p5t_SIMPLE_SLVT_FF_nldm_211120.lib] \
  [file join $asap7_dir lib sram_asap7_64x256_1rw.lib] ]

#reading tech lef
read_lef $tech_lef

# Read all stdcell lefs
foreach lef $std_lef {
  puts "READ_LEF: $lef"
  read_lef $lef
  }

# Read all libs
foreach lib $lib_files {
  puts "READ_LIBERTY: $lib"
  read_liberty $lib
}

set rc_file [file join $asap7_dir setRC.tcl]
