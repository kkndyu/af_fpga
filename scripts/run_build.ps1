# -----------------------------------------------------------------------------
# run_build.ps1 - launch build_moe.tcl with live, tail-able logging
# -----------------------------------------------------------------------------
#   powershell -NoProfile -ExecutionPolicy Bypass -File build\moe\run_build.ps1
#
# Why this exists
# ---------------
# The first attempt piped Vivado's output through `Select-String`.  PowerShell
# buffers a pipeline until the child process exits, so for 28 minutes there was
# no output at all - and when the run was cancelled, nothing had been captured.
#
# So: Vivado writes straight to a file with cmd-style redirection, and this
# script only TAILS that file.  Nothing is buffered by a pipeline.
#
#   build\moe\vivado.log      full transcript, safe to Ctrl-C and re-tail
#
# The Tcl also writes a checkpoint after every stage, so cancelling is now
# recoverable: post_synth.dcp / post_opt.dcp / post_place.dcp / post_route.dcp.
# -----------------------------------------------------------------------------
param(
    [string]$LogPath,          # defaults to build/moe/vivado.log
    [string]$VivadoBat,
    [string]$TclScript,
    [int]$TailSeconds = 20,
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'

# Resolve paths from the repo root regardless of where the caller sits.
# This script lives in <repo>/scripts, so the repo root is one level up.  The
# fallback keeps it working if someone moves it again without updating this.
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repoRoot 'rtl'))) {
    $repoRoot = 'D:\ai\moe_fpga_proto_verilog'
}

if (-not $LogPath)   { $LogPath   = Join-Path $repoRoot 'build\logs\vivado.log' }
if (-not $VivadoBat) { $VivadoBat = 'D:\Xilinx\Vivado\2019.1\bin\vivado.bat' }
if (-not $TclScript) { $TclScript = Join-Path $repoRoot 'scripts\build_moe.tcl' }

foreach ($p in @($VivadoBat, $TclScript)) {
    if (-not (Test-Path $p)) { throw "not found: $p" }
}

# Truncate the old log so a stale run cannot be mistaken for this one.
if (Test-Path $LogPath) { Remove-Item $LogPath -Force }
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null

Write-Host "repo root : $repoRoot"
Write-Host "tcl       : $TclScript"
Write-Host "log       : $LogPath"
Write-Host ""

# cmd-style redirection happens in cmd.exe, NOT through a PowerShell pipeline,
# so the file grows as Vivado writes.
$cmdLine = 'cd /d "{0}" && "{1}" -mode batch -nolog -nojournal -notrace -source "{2}" > "{3}" 2>&1' -f `
    $repoRoot, $VivadoBat, $TclScript, $LogPath

Write-Host "launching: $cmdLine"
Write-Host ""
Write-Host "--- live tail (${TailSeconds}s poll). Ctrl-C stops WATCHING; Vivado keeps running. ---"
Write-Host ""

$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $cmdLine" -PassThru -WindowStyle Hidden

$seen = 0
$lastStage = ''
while (-not $proc.HasExited) {
    Start-Sleep -Seconds $TailSeconds

    if (Test-Path $LogPath) {
        $lines = @(Get-Content $LogPath -ErrorAction SilentlyContinue)
        if ($lines.Count -gt $seen) {
            # Only surface the phase markers and errors, not every netlist line,
            # so this stays readable in a terminal.
            $lines[$seen..($lines.Count - 1)] |
                Where-Object { $_ -match '^====|ERROR|CRITICAL WARNING|Timing constraints|Slack \(' } |
                ForEach-Object { Write-Host $_ }
            $seen = $lines.Count
        }

        # Show which stage is running even when it has printed nothing new.
        $stages = $lines | Where-Object { $_ -match '^====.*STAGE:' } | Select-Object -Last 1
        if ($stages -and $stages -ne $lastStage) {
            $lastStage = $stages
        }
    }
}

# Drain whatever arrived between the last poll and exit.
if (Test-Path $LogPath) {
    $lines = @(Get-Content $LogPath -ErrorAction SilentlyContinue)
    if ($lines.Count -gt $seen) {
        $lines[$seen..($lines.Count - 1)] |
            Where-Object { $_ -match '^====|ERROR|CRITICAL WARNING|Timing constraints' } |
            ForEach-Object { Write-Host $_ }
    }
}

Write-Host ""
$proc.Refresh()
Write-Host "vivado exit code: $($proc.ExitCode)"

$bit = Join-Path $repoRoot 'build\moe\out\moe_proto.bit'
if (Test-Path $bit) {
    $f = Get-Item $bit
    Write-Host "BITSTREAM: $($f.FullName)  ($($f.Length) bytes)"
} else {
    Write-Host "BITSTREAM: not produced"
}

Write-Host ""
Write-Host "checkpoints:"
Get-ChildItem (Join-Path $repoRoot 'build\moe\out') -Filter '*.dcp' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("  {0}  {1:N1} MB" -f $_.Name, ($_.Length / 1MB)) }

exit $proc.ExitCode
