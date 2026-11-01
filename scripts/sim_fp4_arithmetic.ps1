$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$xil = 'D:/Xilinx/Vivado/2019.1/bin'
Push-Location $root
try {
    node scripts/gen_fp4_arithmetic_vectors.js
    if ($LASTEXITCODE -ne 0) { throw 'Reference generation failed' }
    & "$xil/xvlog.bat" -i rtl/include rtl/core/fp4_bf16_product_gen.v rtl/core/fp32_pack.v rtl/core/fp32_add.v rtl/core/fp4_bf16_mul.v sim/tb/tb_fp4_arithmetic.v
    if ($LASTEXITCODE -ne 0) { throw 'FP4 arithmetic compile failed' }
    & "$xil/xelab.bat" tb_fp4_arithmetic -timescale 1ns/1ps -s tb_fp4_arithmetic
    if ($LASTEXITCODE -ne 0) { throw 'FP4 arithmetic elaboration failed' }
    & "$xil/xsim.bat" tb_fp4_arithmetic -R
    if ($LASTEXITCODE -ne 0) { throw 'FP4 arithmetic simulation failed' }
} finally { Pop-Location }
