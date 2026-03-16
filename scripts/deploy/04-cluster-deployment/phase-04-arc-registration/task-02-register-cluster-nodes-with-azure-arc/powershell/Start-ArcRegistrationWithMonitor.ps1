#Requires -Version 5.1
<#
.SYNOPSIS
    Start-ArcRegistrationWithMonitor.ps1
    Launches Arc registration and bootstrap monitoring together.

.DESCRIPTION
    Thin wrapper that coordinates Task 02 (Invoke-ArcRegistration-Orchestrated.ps1)
    and Task 03 (Invoke-BootstrapMonitor-Orchestrated.ps1) for a complete Arc
    onboarding experience.

    Execution flow:
      1. Resolves ConfigPath to an absolute path
      2. Launches the bootstrap monitor in a NEW PowerShell window (background)
         — the monitor resolves its own credentials from Key Vault
         — the monitor polls until all nodes report Succeeded/Failed
      3. Runs the Arc registration script in the CURRENT window (foreground)
         — blocks until synchronous Invoke-Command completes on all nodes
      4. Reports final status of both processes

    OEM Image Scenario:
    When nodes have outdated OS images, registration triggers an automatic
    update cycle. The Invoke-AzStackHciArcInitialization cmdlet manages the
    full update + reboot + resume cycle internally. The monitor window tracks
    progress (Scan → Download → Install → Reboot → Arc Registration).

    This script does NOT resolve credentials itself — each child script handles
    its own credential resolution independently:
      - Registration: uses SPN auth (Key Vault → prompt)
      - Monitor: uses local admin auth (Key Vault → prompt)

.PARAMETER ConfigPath
    Path to infrastructure.yml. Required.

.PARAMETER TargetNode
    One or more node hostnames or IPs. Passed to both scripts.

.PARAMETER WhatIf
    Dry-run mode — runs registration in WhatIf mode. Does NOT launch monitor window.

.PARAMETER PollIntervalSeconds
    Seconds between bootstrap monitor status checks. Default: 60. Passed to monitor.

.PARAMETER MaxIterations
    Maximum monitor poll cycles. Default: 120 (= 2 hours). Passed to monitor.

.PARAMETER MonitorDelaySeconds
    Seconds to wait after launching monitor before starting registration. Default: 5.
    Gives the monitor window time to initialize.

.PARAMETER NoMonitor
    Skip launching the monitor window. Only run registration.

.PARAMETER SpnSecret
    SPN secret override for registration. Passed directly to registration script.

.EXAMPLE
    .\Start-ArcRegistrationWithMonitor.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml
    # Launches monitor in new window, runs registration in current window

.EXAMPLE
    .\Start-ArcRegistrationWithMonitor.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -WhatIf
    # Dry-run mode — only runs registration WhatIf, no monitor window

.EXAMPLE
    .\Start-ArcRegistrationWithMonitor.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -TargetNode azl-lab-01-n01
    # Target specific node — both registration and monitor target only n01

.EXAMPLE
    .\Start-ArcRegistrationWithMonitor.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -NoMonitor
    # Registration only — no monitor window launched

.NOTES
    Author:  Azure Local Cloud AzureLocalCloud
    Phase:   04-arc-registration
    Task:    02 - Register Cluster Nodes with Azure Arc (wrapper)
    Mode:    Coordinator. Launches child scripts.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ })]
    [string]$ConfigPath,

    [string[]]$TargetNode = @(),

    [switch]$WhatIf,

    [int]$PollIntervalSeconds = 60,
    [int]$MaxIterations       = 120,
    [int]$MonitorDelaySeconds = 5,

    [switch]$NoMonitor,

    [switch]$NoArcGateway,

    [switch]$Dashboard,

    [string]$SpnSecret = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Resolve paths ─────────────────────────────────────────────────────────
$resolvedConfigPath = (Resolve-Path $ConfigPath).Path

# Registration script: same folder as this wrapper
$registrationScript = Join-Path $PSScriptRoot "Invoke-ArcRegistration-Orchestrated.ps1"
if (-not (Test-Path $registrationScript)) {
    throw "Registration script not found: $registrationScript"
}

# Monitor script: sibling task folder
$monitorScript = Join-Path $PSScriptRoot "..\..\task-03-monitor-bootstrap-process\powershell\Invoke-BootstrapMonitor-Orchestrated.ps1"
if (-not (Test-Path $monitorScript)) {
    $monitorScript = $null
    Write-Warning "Monitor script not found — will run registration only."
} else {
    $monitorScript = (Resolve-Path $monitorScript).Path
}

# ── Banner ────────────────────────────────────────────────────────────────
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "[$ts] [----] ================================================================" -ForegroundColor Cyan
Write-Host "[$ts] [----]   Arc Registration with Bootstrap Monitor" -ForegroundColor Cyan
Write-Host "[$ts] [----] ================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[$ts] [INFO]   Config   : $resolvedConfigPath"
Write-Host "[$ts] [INFO]   Register : $registrationScript"
Write-Host "[$ts] [INFO]   Monitor  : $(if ($monitorScript) { $monitorScript } else { '(not found)' })"
if ($TargetNode.Count -gt 0) { Write-Host "[$ts] [WARN]   Targets  : $($TargetNode -join ', ')" -ForegroundColor Yellow }
Write-Host ""

# ── WhatIf mode — registration only, no monitor ──────────────────────────
if ($WhatIf) {
    Write-Host "[$ts] [----] WHATIF — Running registration dry-run only (no monitor window)." -ForegroundColor Cyan
    Write-Host ""

    $regParams = @{
        ConfigPath = $resolvedConfigPath
        WhatIf     = [switch]$true
    }
    if ($TargetNode.Count -gt 0) { $regParams['TargetNode'] = $TargetNode }
    if ($SpnSecret -ne "") { $regParams['SpnSecret'] = $SpnSecret }
    if ($NoArcGateway) { $regParams['NoArcGateway'] = [switch]$true }

    & $registrationScript @regParams
    exit $LASTEXITCODE
}

# ── Launch bootstrap monitor in new window ────────────────────────────────
$monitorProcess = $null
if (-not $NoMonitor -and $monitorScript) {
    Write-Host "[$ts] [----] Launching bootstrap monitor in new window..." -ForegroundColor Cyan

    # Build monitor command string (use -Command so arrays bind correctly)
    $monCmd = "& '$monitorScript' -ConfigPath '$resolvedConfigPath' -PollIntervalSeconds $PollIntervalSeconds -MaxIterations $MaxIterations"
    if ($Dashboard) { $monCmd += " -Dashboard" }
    if ($TargetNode.Count -gt 0) {
        $targetStr = ($TargetNode -join "','")
        $monCmd += " -TargetNode '$targetStr'"
    }
    $monArgs = "-NoExit -Command `"$monCmd`""

    try {
        $monitorProcess = Start-Process -FilePath "pwsh" -ArgumentList $monArgs `
            -PassThru -WindowStyle Normal
        Write-Host "[$ts] [PASS] Monitor launched (PID: $($monitorProcess.Id))" -ForegroundColor Green
        Write-Host "[$ts] [INFO] Waiting $MonitorDelaySeconds seconds for monitor to initialize..."
        Start-Sleep -Seconds $MonitorDelaySeconds
    } catch {
        Write-Host "[$ts] [WARN] Failed to launch monitor: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "[$ts] [WARN] Continuing with registration only." -ForegroundColor Yellow
    }
} elseif ($NoMonitor) {
    Write-Host "[$ts] [INFO] -NoMonitor specified — skipping bootstrap monitor." 
} else {
    Write-Host "[$ts] [WARN] Monitor script not found — running registration only." -ForegroundColor Yellow
}

# ── Run registration in current window ────────────────────────────────────
Write-Host ""
Write-Host "[$ts] [----] Starting Arc registration..." -ForegroundColor Cyan
Write-Host "[$ts] [----] ================================================================" -ForegroundColor Cyan
Write-Host ""

$regParams = @{
    ConfigPath = $resolvedConfigPath
}
if ($TargetNode.Count -gt 0) {
    $regParams['TargetNode'] = $TargetNode
}
if ($SpnSecret -ne "") {
    $regParams['SpnSecret'] = $SpnSecret
}
if ($NoArcGateway) {
    $regParams['NoArcGateway'] = [switch]$true
}

try {
    & $registrationScript @regParams
    $regExitCode = $LASTEXITCODE
} catch {
    Write-Host ""
    Write-Host "[$ts] [FAIL] Registration script threw an error: $($_.Exception.Message)" -ForegroundColor Red
    $regExitCode = 1
}

# ── Final status ──────────────────────────────────────────────────────────
Write-Host ""
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "[$ts] [----] ================================================================" -ForegroundColor Cyan
Write-Host "[$ts] [----]   Registration Complete" -ForegroundColor Cyan
Write-Host "[$ts] [----] ================================================================" -ForegroundColor Cyan
Write-Host ""

if ($regExitCode -eq 0) {
    Write-Host "[$ts] [PASS] Registration finished successfully." -ForegroundColor Green
} else {
    Write-Host "[$ts] [WARN] Registration finished with exit code $regExitCode." -ForegroundColor Yellow
}

if ($monitorProcess -and -not $monitorProcess.HasExited) {
    Write-Host "[$ts] [INFO] Bootstrap monitor is still running in the other window (PID: $($monitorProcess.Id))."
    Write-Host "[$ts] [INFO] The monitor will continue tracking OEM update progress."
    Write-Host "[$ts] [INFO] Close the monitor window when all nodes show Succeeded."
} elseif ($monitorProcess -and $monitorProcess.HasExited) {
    Write-Host "[$ts] [INFO] Bootstrap monitor has already completed."
}

Write-Host ""
exit $regExitCode
