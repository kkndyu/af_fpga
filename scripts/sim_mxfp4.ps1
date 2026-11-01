param([ValidateSet('engine','loader')][string]$Target='engine',[switch]$Fp32)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$xil='D:/Xilinx/Vivado/2019.1/bin'
Push-Location $root
try {
    node scripts/gen_mxfp4_vectors.js
    if($LASTEXITCODE -ne 0) {throw 'MXFP4 reference generation failed'}
    $files=@('rtl/core/fp4_bf16_product_gen.v','rtl/core/mxfp4_lane.v','rtl/core/mxfp4_region.v','rtl/core/mxfp4_gemv_engine.v','rtl/mem/wbank_region.v','rtl/mem/act_buffer.v','rtl/ctrl/weight_readback.v')
    if($Target -eq 'loader') {
        $files+=@('rtl/core/gemv_engine.v','rtl/core/expert_engine.v','rtl/core/result_readout.v','rtl/top/moe_proto_top.v','rtl/ctrl/moe_loader.v')
    }
    $tb="tb_mxfp4_$Target"
    if($Fp32) {
          $files+=@('rtl/core/fp32_pack.v','rtl/core/fp32_add.v','rtl/core/mxfp4_lane_fp32.v')
      }
      $defs=@('-d','MOE_MXFP4')
      if($Fp32) { $defs+=@('-d','MOE_MXFP4_FP32') }
      & "$xil/xvlog.bat" @defs -i rtl/include @files "sim/tb/$tb.v"
    if($LASTEXITCODE -ne 0) {throw 'MXFP4 compile failed'}
    & "$xil/xelab.bat" $tb -timescale 1ns/1ps -s $tb
    if($LASTEXITCODE -ne 0) {throw 'MXFP4 elaboration failed'}
    & "$xil/xsim.bat" $tb -R
    if($LASTEXITCODE -ne 0) {throw 'MXFP4 simulation failed'}
} finally {Pop-Location}
