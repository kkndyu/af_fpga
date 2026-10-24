# -----------------------------------------------------------------------------
# golden.ps1 - independent golden model for the 256-lane FP4 GEMV
# -----------------------------------------------------------------------------
#   pwsh -File scripts/golden.ps1
#
# Purpose: the existing reference (sim/data/ref_out.hex) is produced by
# scripts/gen_mem.py, which states in its own header that it "mirrors
# rtl/core/fp4_product_gen.v".  A shared misunderstanding of the codebook would
# therefore cancel out and still compare equal.  This is a second implementation,
# written from the RTL and in a different language, so agreement between the two
# is real evidence rather than a tautology.
#
# Deliberately NOT a translation of gen_mem.py:
#   * PowerShell rather than Python
#   * 64-bit integers by default, so the 32-bit wraparound is applied explicitly
#     instead of being masked in and out of arbitrary-precision integers
#   * the codebook is transcribed from fp4_product_gen.v, not from the Python
#
# Specification, traced through the RTL:
#
#   lane j          -> region g = floor(j/64), local i = j mod 64
#                      (result_readout.v: acc_flat[g*2048 + lane_lo*32 +: 32])
#   weight code     -> nibble i of row k of gate_r{g}.mem
#                      (mac_region.v: wcode_d[i*WCODE_W +: WCODE_W])
#   nibble i        -> bits [4i+3 : 4i]; the .mem line is MSB first, so nibble i
#                      is hex character (63 - i)
#   out[j]          = sum over k of prod(act[k], code)
#                      (mac_lane.v: acc_out <= acc_out + selected_ext)
#   accumulate      -> 32-bit two's complement, no saturation
# -----------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$ROOT = Split-Path -Parent $PSScriptRoot
$H_DIM      = 1024
$OUT_LANES  = 256
$REGION_LANES = 64

function Now { (Get-Date).ToString('HH:mm:ss') }

# --- codebook, transcribed from fp4_product_gen.v -----------------------------
# a_x_1p5 = a_ext + (a_ext >>> 1), an ARITHMETIC shift, so for negative a it is
# a + floor(a/2), not 1.5a.  PowerShell's -shr is arithmetic on signed values,
# which matches Verilog >>>.  Getting this wrong shifts every result by one unit
# of a for odd negative activations and is the single easiest thing to get wrong.
function Get-Products([long]$a) {
    $half  = $a -shr 1
    $quart = $a -shr 2
    return @(
        [long]0,                       # 0  zero
        [long]$half,                   # 1  +0.5
        [long]$a,                      # 2  +1
        [long]($a + $half),            # 3  +1.5
        [long]($a -shl 1),             # 4  +2
        [long]($a -shl 2),             # 5  +4
        [long]$quart,                  # 6  +0.25
        [long]0,                       # 7  zero
        [long]0,                       # 8  zero
        [long](-$half),                # 9  -0.5
        [long](-$a),                   # 10 -1
        [long](-($a + $half)),         # 11 -1.5
        [long](-($a -shl 1)),          # 12 -2
        [long](-($a -shl 2)),          # 13 -4
        [long](-$quart),               # 14 -0.25
        [long]0                        # 15 zero
    )
}

# --- hex digit lookup (faster than parsing per character) --------------------
$NIB = New-Object 'int[]' 256
for ($i = 0; $i -lt 256; $i++) { $NIB[$i] = -1 }
for ($i = 0; $i -lt 10; $i++) { $NIB[[int][char][string]$i] = $i }
for ($i = 0; $i -lt 6;  $i++) {
    $NIB[[int][char][string][char]([int][char]'a' + $i)] = 10 + $i
    $NIB[[int][char][string][char]([int][char]'A' + $i)] = 10 + $i
}

# --- read the activation vector ----------------------------------------------
$act = New-Object 'long[]' $H_DIM
$actLines = [System.IO.File]::ReadAllLines("$ROOT\sim\data\input.mem")
$k = 0
foreach ($ln in $actLines) {
    $t = $ln.Trim()
    if ($t -eq '') { continue }
    $v = [Convert]::ToInt64($t, 16)
    if ($v -ge 0x8000) { $v -= 0x10000 }        # 16-bit two's complement
    $act[$k] = $v
    $k++
}
if ($k -ne $H_DIM) { throw "expected $H_DIM activations, read $k" }
Write-Output "read $k activations"

# --- accumulate ---------------------------------------------------------------
$out = New-Object 'long[]' $OUT_LANES
$sw  = [System.Diagnostics.Stopwatch]::StartNew()

for ($g = 0; $g -lt 4; $g++) {
    $lines = [System.IO.File]::ReadAllLines(("{0}\mem_init\expert0\gate_r{1}.mem" -f $ROOT, $g))
    $rows  = New-Object 'System.Collections.Generic.List[string]'
    foreach ($ln in $lines) { $t = $ln.Trim(); if ($t -ne '') { $rows.Add($t) } }
    if ($rows.Count -ne $H_DIM) { throw "region ${g}: expected $H_DIM rows, read $($rows.Count)" }

    $base = $g * $REGION_LANES
    for ($kk = 0; $kk -lt $H_DIM; $kk++) {
        $row   = $rows[$kk]
        $prods = Get-Products $act[$kk]
        # nibble i is hex character (63 - i); walk the string backwards so that
        # character index maps to lane 0, 1, 2 ... in order
        $idx = 63
        for ($i = 0; $i -lt $REGION_LANES; $i++) {
            $code = $NIB[[int][char]$row[$idx]]
            if ($code -lt 0) { throw "bad hex '$($row[$idx])' in region $g row $kk" }
            $out[$base + $i] += $prods[$code]
            $idx--
        }
    }
    Write-Output ("region {0} done  ({1:N1}s)" -f $g, $sw.Elapsed.TotalSeconds)
}

# --- wrap to 32 bits, signed --------------------------------------------------
# Each lane is a sum of 1024 products, each at most 4 x 32768 in magnitude, so the
# magnitude stays near 1.3e8 - well inside 2^31.  No intermediate wrap can occur,
# which is why summing in 64 bits and masking once is faithful to the hardware's
# step-by-step 32-bit accumulation.
$hex = New-Object 'string[]' $OUT_LANES
$sum = [long]0
$M32 = [long]4294967296
for ($j = 0; $j -lt $OUT_LANES; $j++) {
    # Reduce with % rather than -band.  In Windows PowerShell a 0xFFFFFFFF literal
    # does not reliably behave as a 32-bit mask (it can be taken as [int] -1, which
    # leaves a value of -76 as -76), and ToString('x8') on a negative Int64
    # produces 16 hex digits.  Pure arithmetic has no such ambiguity.
    $w = $out[$j] % $M32
    if ($w -lt 0) { $w += $M32 }
    $hex[$j] = $w.ToString('x8')
    $sum = ($sum + $w) % $M32
}

# --- compare with the existing reference --------------------------------------
$ref = @([System.IO.File]::ReadAllLines("$ROOT\sim\data\ref_out.hex") | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' })
$bad = 0
for ($j = 0; $j -lt $OUT_LANES; $j++) {
    if ($hex[$j] -ne $ref[$j]) {
        if ($bad -lt 8) { Write-Output ("  lane {0,3}: golden {1}  gen_mem.py {2}" -f $j, $hex[$j], $ref[$j]) }
        $bad++
    }
}

Write-Output ""
Write-Output ("checksum over 256 lanes = {0}" -f $sum.ToString('X8'))
Write-Output ("mismatches vs ref_out.hex = {0} of {1}" -f $bad, $OUT_LANES)
if ($bad -eq 0) {
    Write-Output "RESULT: two independent implementations agree"
} else {
    Write-Output "RESULT: DISAGREEMENT - at least one implementation is wrong"
}

# Leave the output behind so it can be diffed or inspected later.
[System.IO.File]::WriteAllLines("$ROOT\sim\data\golden_ps.hex", $hex)
