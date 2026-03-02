set libdir "/MLCAD26-Contest-Scripts-Benchmarks/asap7/lib/NLDM"
set lefdir "/MLCAD26-Contest-Scripts-Benchmarks/asap7/lef"

set libworst "
  ${libdir}/asap7sc7p5t_SEQ_LVT_FF_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_LVT_SS_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_LVT_TT_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_RVT_SS_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SLVT_FF_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SLVT_SS_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SLVT_TT_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SRAM_FF_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SRAM_SS_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SRAM_TT_nldm_220123.lib \
  ${libdir}/fakeram_256x128.lib \
  ${libdir}/fakeram_256x64.lib \
  ${libdir}/fakeram_32x46.lib \
  ${libdir}/fakeram_512x8.lib \
  ${libdir}/fakeram_64x20.lib \
  ${libdir}/fakeram_64x22.lib \
  ${libdir}/fakeram7_128x64.lib \
  ${libdir}/fakeram7_2048x39.lib \
  ${libdir}/fakeram7_256x256.lib \
  ${libdir}/fakeram7_256x32.lib \
  ${libdir}/fakeram7_256x34.lib \
  ${libdir}/fakeram7_64x21.lib \
  ${libdir}/fakeram7_64x256.lib \
  ${libdir}/fakeram7_64x25.lib \
  ${libdir}/fakeram7_64x28.lib \
  ${libdir}/fakeregfile_128x64.lib \
  ${libdir}/fakeregfile_32x46.lib \
  ${libdir}/fakeregfile_64x64.lib \
  "

set libbest "
  ${libdir}/asap7sc7p5t_SEQ_LVT_FF_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_LVT_SS_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_LVT_TT_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_RVT_SS_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SLVT_FF_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SLVT_SS_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SLVT_TT_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SRAM_FF_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SRAM_SS_nldm_220123.lib \
  ${libdir}/asap7sc7p5t_SEQ_SRAM_TT_nldm_220123.lib \
  ${libdir}/fakeram_256x128.lib \
  ${libdir}/fakeram_256x64.lib \
  ${libdir}/fakeram_32x46.lib \
  ${libdir}/fakeram_512x8.lib \
  ${libdir}/fakeram_64x20.lib \
  ${libdir}/fakeram_64x22.lib \
  ${libdir}/fakeram7_128x64.lib \
  ${libdir}/fakeram7_2048x39.lib \
  ${libdir}/fakeram7_256x256.lib \
  ${libdir}/fakeram7_256x32.lib \
  ${libdir}/fakeram7_256x34.lib \
  ${libdir}/fakeram7_64x21.lib \
  ${libdir}/fakeram7_64x256.lib \
  ${libdir}/fakeram7_64x25.lib \
  ${libdir}/fakeram7_64x28.lib \
  ${libdir}/fakeregfile_128x64.lib \
  ${libdir}/fakeregfile_32x46.lib \
  ${libdir}/fakeregfile_64x64.lib \
  "

set lefs "
  ${lefdir}/asap7_tech_1x_201209.lef \
  ${lefdir}/asap7sc7p5t_28_L_1x_220121a.lef \
  ${lefdir}/asap7sc7p5t_28_R_1x_220121a.lef \
  ${lefdir}/asap7sc7p5t_28_SL_1x_220121a.lef \
  ${lefdir}/asap7sc7p5t_28_SRAM_1x_220121a.lef \
  ${lefdir}/asap7sc7p5t_DFFHQNH2V2X.lef \
  ${lefdir}/asap7sc7p5t_DFFHQNV2X.lef \
  ${lefdir}/asap7sc7p5t_DFFHQNV4X.lef \
  ${lefdir}/asap7sc7p5t_DFHV2X.lef \
  "

set rc_file "/home/jethiraj/MLCAD26-Contest-Scripts-Benchmarks/asap7/setRC.tcl"


