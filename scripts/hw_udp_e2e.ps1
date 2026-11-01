param(
    [string]$BoardIp = '192.168.8.6', [switch]$VerifyWeights,
    [ValidateSet('integer','mxfp4')][string]$Profile = 'integer',
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/udp_host.ps1"
$BOARD_IP = $BoardIp
if ($Profile -eq 'mxfp4') {
    if (-not $DataDir) { $DataDir = "$root/build/mxfp4_vectors" }
    $weightPrefix = "$DataDir/weight_r"
    $activationPath = "$DataDir/activation.mem"
    $referencePath = "$DataDir/ref_1024.hex"
} else {
    if ($DataDir) { throw 'DataDir is supported by the mxfp4 profile only' }
    $weightPrefix = "$root/mem_init/expert0/gate_r"
    $activationPath = "$root/sim/data/input.mem"
    $referencePath = "$root/sim/data/ref_out.hex"
}
$timer = [Diagnostics.Stopwatch]::StartNew()
function Mark([string]$Message) { Write-Output ('[{0:N2}s] {1}' -f $timer.Elapsed.TotalSeconds, $Message) }
function Send-Only([byte]$Cmd, [byte[]]$Payload = @()) {
    [byte[]]$frame = New-Frame -Cmd $Cmd -Payload $Payload
    [void]$udp.Send($frame, $frame.Length, $BOARD_IP, $PORT)
    Start-Sleep -Milliseconds 3
}
function Read-Reply([byte]$Cmd, [byte[]]$Payload, [int]$Length) {
    [byte[]]$reply = Send-Cmd -Udp $udp -Cmd $Cmd -Payload $Payload
    if ($null -eq $reply -or $reply.Length -ne $Length) {
        throw "Command $Cmd response length $($reply.Length), expected $Length"
    }
    return ,$reply
}
function Check-Status {
    [byte[]]$status = Read-Reply 4 @() 8
    if ($status[2] -ne 0) { throw "Loader error $($status[2]); status: $(Show-Bytes $status)" }
    return ,$status
}
$udp = New-Udp
try {
    Mark "Arithmetic profile: $Profile"
    [byte[]]$initial = Check-Status
    Mark "Initial STATUS: $(Show-Bytes $initial)"
    $banks = @()
    for ($bank = 0; $bank -lt 4; $bank++) {
        $rows = @(Get-Content "${weightPrefix}$bank.mem" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($rows.Count -ne 1024) { throw "Bank $bank row count is $($rows.Count)" }
        [byte[]]$data = New-Object byte[] 32768
        for ($row = 0; $row -lt 1024; $row++) {
            if ($rows[$row].Length -ne 64) { throw "Invalid bank $bank row $row" }
            for ($j = 0; $j -lt 32; $j++) { $data[$row*32+$j] = [Convert]::ToByte($rows[$row].Substring($j*2,2),16) }
        }
        $banks += ,$data
        for ($row = 0; $row -lt 1024; $row += 32) {
            [byte[]]$payload = New-Object byte[] 1027
            $payload[0] = $bank; $payload[1] = $row -shr 8; $payload[2] = $row -band 255
            [Array]::Copy($data, $row*32, $payload, 3, 1024)
            Send-Only 1 $payload
            $null = Check-Status
        }
        Mark "Bank $bank loaded: 32768 bytes"
    }
    if ($Profile -eq 'mxfp4') {
        for ($bank = 0; $bank -lt 4; $bank++) {
            $scaleRows = @(Get-Content "$DataDir/scale_r$bank.mem" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($scaleRows.Count -ne 32) { throw "Bank $bank scale row count must be 32" }
            for ($block = 0; $block -lt 32; $block++) {
                if ($scaleRows[$block].Length -ne 128) { throw "Invalid scale row bank=$bank block=$block" }
                [byte[]]$payload = New-Object byte[] 67
                $payload[0] = $bank; $payload[1] = 0; $payload[2] = $block
                for ($lane = 0; $lane -lt 64; $lane++) {
                    $payload[3+$lane] = [Convert]::ToByte($scaleRows[$block].Substring((63-$lane)*2,2),16)
                }
                Send-Only 8 $payload
                $null = Check-Status
            }
            Mark "Bank $bank E8M0 scales loaded: 2048 bytes"
        }
    }
    if ($VerifyWeights) { for ($bank = 0; $bank -lt 4; $bank++) {
        for ($row = 0; $row -lt 1024; $row += 32) {
            [byte[]]$reply = Read-Reply 6 ([byte[]]@($bank, ($row -shr 8), ($row -band 255), 31)) 1024
            for ($j = 0; $j -lt 1024; $j++) {
                if ($reply[$j] -ne $banks[$bank][$row*32+$j]) { throw "Weight mismatch bank=$bank row=$row byte=$j" }
            }
        }
        Mark "Bank $bank readback: all 32768 bytes match"
    } }
    Send-Only 7
    [byte[]]$status = Check-Status
    if ($status[0] -ne 1) { throw 'COMMIT did not set weights_ready' }
    Mark 'COMMIT passed'
    $acts = @(Get-Content $activationPath | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($acts.Count -ne 1024) { throw 'Activation count is not 1024' }
    for ($row = 0; $row -lt 1024; $row += 256) {
        [byte[]]$payload = New-Object byte[] 514
        $payload[0] = $row -shr 8; $payload[1] = $row -band 255
        for ($j = 0; $j -lt 256; $j++) {
            $v = [Convert]::ToUInt16($acts[$row+$j],16)
            $payload[2+$j*2] = $v -shr 8; $payload[3+$j*2] = $v -band 255
        }
        Send-Only 2 $payload
        $null = Check-Status
    }
    [byte[]]$status = Check-Status
    if ($status[0] -ne 1 -or $status[1] -ne 1) { throw 'Weights or activations not ready' }
    Mark 'Activations loaded: 2048 bytes'
    $reference = @(Get-Content $referencePath | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($reference.Count -ne 256) { throw 'Reference count is not 256' }
    for ($run = 1; $run -le 3; $run++) {
        Send-Only 3
        $null = Check-Status
        [byte[]]$result = Read-Reply 5 ([byte[]]@(0,255)) 1024
        [long]$sum = 0
        $hex = @()
        for ($lane = 0; $lane -lt 256; $lane++) {
            [uint32]$actual = [BitConverter]::ToUInt32($result,$lane*4)
            [uint32]$expected = [Convert]::ToUInt32($reference[$lane],16)
            if ($actual -ne $expected) { throw ('Run {0} lane {1}: got {2:X8}, expected {3:X8}' -f $run,$lane,$actual,$expected) }
            $sum = ($sum + [long]$actual) % 4294967296
            $hex += $actual.ToString('x8')
        }
        [IO.File]::WriteAllLines("$root/build/logs/udp_e2e_result.hex",[string[]]$hex)
        Mark ('RUN {0}: 256/256 lanes match; checksum {1:X8}' -f $run,$sum)
    }
    Mark 'RESULT: UDP END-TO-END PASSED'
} finally { $udp.Close() }
