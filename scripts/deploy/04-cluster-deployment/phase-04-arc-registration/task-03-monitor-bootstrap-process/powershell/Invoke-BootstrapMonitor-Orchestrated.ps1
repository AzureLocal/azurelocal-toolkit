#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-BootstrapMonitor-Orchestrated.ps1
    Monitors Arc registration and OEM bootstrap progress across all cluster nodes.

.DESCRIPTION
    Comprehensive monitoring of the Arc registration bootstrap lifecycle on Azure
    Local cluster nodes. Polls each node periodically and collects:

      - Arc bootstrap status and phases (Update: Scan/Download/Install, ArcConfiguration)
      - Solution update metadata (target version, package size, KB link)
      - Downloaded files in C:\bootstrap (size, count, recent activity)
      - Windows Update service status and pending reboot detection
      - Reboot events from the System event log (clean/unexpected/uptime)
      - Arc agent installation and local connection status (himds service, azcmagent)
      - Azure-side Arc resource verification (Get-AzConnectedMachine)
      - Latest bootstrap log file entries (C:\Windows\System32\Bootstrap\Logs)
      - Validation report failures/warnings (AzStackHciEnvironmentReport.json)

    OEM IMAGE BOOTSTRAP:
    When nodes ship with a preinstalled or outdated Azure Stack HCI OS image (Dell,
    HPE, Lenovo, etc.), the Invoke-AzStackHciArcInitialization command triggers an
    automatic update cycle:
      1. Scan     — detect the current OS version vs. latest baseline
      2. Download — download the update package (~40-60 min depending on network)
      3. Install  — apply the OS update
      4. REBOOT   — node reboots to complete the update (node is UNREACHABLE)
      5. Resume   — bootstrap service resumes Arc registration using cached SPN

    This monitor handles unreachable nodes gracefully — nodes that are rebooting
    during OEM updates are reported as "Unreachable (may be rebooting)" rather than
    failed. Monitoring continues until all nodes report Succeeded or Failed, or
    MaxIterations is reached.

    NODE ACCESS: Uses local administrator credentials resolved from Key Vault
    (identity.accounts). The -Credential parameter overrides Key Vault resolution.

.PARAMETER ConfigPath
    Path to infrastructure.yml. Defaults to auto-detect from script location.

.PARAMETER Credential
    PSCredential for PSRemoting to cluster nodes. If omitted, resolved from
    Key Vault using identity.accounts.account_local_admin_password, then
    interactive Get-Credential prompt.

.PARAMETER TargetNode
    One or more node hostnames or IPs. Defaults to all nodes in config.

.PARAMETER WhatIf
    Dry-run mode — shows what would be monitored without connecting.

.PARAMETER LogPath
    Override log file path. Default: ./logs/<task-folder>/<timestamp>_BootstrapMonitor.log

.PARAMETER PollIntervalSeconds
    Seconds between status checks. Default: 60. YAML path: N/A (runtime only)

.PARAMETER MaxIterations
    Maximum poll cycles before exiting. Default: 120 (= 2 hours at 60s interval).
    YAML path: N/A (runtime only)

.PARAMETER SubscriptionId
    Override Azure subscription ID for Arc resource verification.
    YAML path: azure_platform.subscriptions.lab.id

.PARAMETER ResourceGroup
    Override Arc resource group for Azure verification.
    YAML path: compute.azure_local.arc_resource_group

.PARAMETER ContinuousMode
    Continue monitoring even after all nodes report Succeeded or Failed.
    Useful for observing post-registration behavior.

.PARAMETER Dashboard
    Full-screen dashboard display mode. Clears the screen each poll cycle
    and redraws a compact status table with progress bars, events, and
    summary counts. Inspired by the Project Phoenix deployment dashboards.
    The log file still captures all data in standard scrolling format.
    Default (without -Dashboard) is the original timestamped log output.

.PARAMETER TailLines
    Number of bootstrap log lines to display per node. Default: 5

.EXAMPLE
    .\Invoke-BootstrapMonitor-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml

.EXAMPLE
    .\Invoke-BootstrapMonitor-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -PollIntervalSeconds 30

.EXAMPLE
    .\Invoke-BootstrapMonitor-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -WhatIf

.EXAMPLE
    .\Invoke-BootstrapMonitor-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -TargetNode azl-lab-01-n01 -TailLines 10

.EXAMPLE
    .\Invoke-BootstrapMonitor-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -ContinuousMode

.NOTES
    Author:  Azure Local Cloud AzureLocalCloud
    Phase:   04-arc-registration
    Task:    03 - Monitor Bootstrap Process
    Mode:    READ-ONLY. No changes made to any node.
    Adapted: From Monitor-ArcRegistration.ps1 (azl-demo reference implementation)
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [string[]]$TargetNode = @(),

    [switch]$WhatIf,

    [string]$LogPath = "",

    [int]$PollIntervalSeconds = 60,        # Seconds between status checks
    [int]$MaxIterations       = 120,       # Max poll cycles (120 × 60s = 2 hours)

    # YAML-overridable Azure parameters (for Azure-side verification)
    [string]$SubscriptionId = "",          # azure_platform.subscriptions.lab.id
    [string]$ResourceGroup  = "",          # compute.azure_local.arc_resource_group

    [switch]$ContinuousMode,              # Continue after all nodes complete
    [switch]$Dashboard,                    # Full-screen dashboard display mode
    [int]$TailLines = 5                    # Bootstrap log lines per node
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Log file initialization ───────────────────────────────────────────────
# Scripts are always run from the repo root, so ./logs/<task-folder>/ is CWD-relative
$scriptShortName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -replace '^Invoke-|-Orchestrated$', ''
$taskFolderName  = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf   # e.g. task-03-monitor-bootstrap-process
$logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
if ($LogPath -ne "") {
    $logDir  = Split-Path $LogPath -Parent
    $logFile = $LogPath
} else {
    $logFile = Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd_HHmmss')_${scriptShortName}.log"
}
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# ── Monitoring path constants ─────────────────────────────────────────────
$BootstrapLogPath      = "C:\Windows\System32\Bootstrap\Logs"
$BootstrapDownloadPath = "C:\bootstrap"
$SolutionUpdateXmlPath = "C:\bootstrap\SolutionUpdate.xml"
$ValidationReportPath  = "C:\Windows\System32\Bootstrap\DiagnosticsHistory\Bootstrap\AzStackHciEnvironmentReport.json"

#region HELPERS

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    $line | Out-File -FilePath $script:logFile -Append -Encoding utf8
    switch ($Level) {
        "PASS"    { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "FAIL"    { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
        "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
        "SUCCESS" { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "VERBOSE" { Write-Verbose "[$ts] $Message" }
        "DEBUG"   { Write-Debug  "[$ts] $Message" }
        default   { Write-Host "[$ts] [INFO] $Message" }
    }
}

function Get-Config {
    param([string]$Path)
    if ($Path -eq "" -or -not (Test-Path $Path)) {
        foreach ($c in @(
            (Join-Path $PSScriptRoot "..\..\..\..\..\..\configs\infrastructure.yml"),
            (Join-Path $PSScriptRoot "..\..\..\..\..\..\..\configs\infrastructure.yml")
        )) { if (Test-Path $c) { $Path = (Resolve-Path $c).Path; break } }
    } else {
        $Path = (Resolve-Path $Path).Path
    }
    if (-not (Test-Path $Path)) { throw "infrastructure.yml not found. Use -ConfigPath." }

    Write-Log "Loading config from: $Path"
    Write-Log "Resolved config path: $Path" VERBOSE

    Import-Module powershell-yaml -ErrorAction Stop
    $cfg = Get-Content $Path -Raw | ConvertFrom-Yaml

    # compute.cluster_nodes                                          # compute.cluster_nodes
    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            nodename = $_.Key                                        # compute.cluster_nodes.<key>
            hostname = if ($_.Value.hostname) { $_.Value.hostname }  # compute.cluster_nodes.<key>.hostname
                       else { $_.Key }
            ip       = $_.Value.management_ip                        # compute.cluster_nodes.<key>.management_ip
        }
    }

    return [PSCustomObject]@{
        Nodes          = @($nodes)
        AdminUser      = $cfg.identity.accounts.account_local_admin_username   # identity.accounts.account_local_admin_username
        AdminPassUri   = $cfg.identity.accounts.account_local_admin_password   # identity.accounts.account_local_admin_password
        SubscriptionId = $cfg.azure_platform.subscriptions.lab.id              # azure_platform.subscriptions.lab.id
        ResourceGroup  = $cfg.compute.azure_local.arc_resource_group           # compute.azure_local.arc_resource_group
    }
}

function Resolve-KeyVaultRef {
    param([string]$KvUri)
    if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') { Write-Log "  Not a Key Vault URI: $KvUri" "WARN"; return $null }
    $vaultName  = $Matches[1]
    $secretName = $Matches[2]

    if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            Write-Log "  Retrieving '$secretName' from '$vaultName' (Az.KeyVault)..."
            $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
            if ($secret) { Write-Log "  Secret retrieved." "SUCCESS"; return $secret }
            Write-Log "  Az.KeyVault returned no secret." "WARN"
        } catch { Write-Log "  Az.KeyVault failed: $_" "WARN" }
        Write-Log "  Falling back to Azure CLI..." "WARN"
    } else {
        Write-Log "  Az.KeyVault module not found — trying Azure CLI..." "WARN"
    }

    try {
        $azCmd = Get-Command az -ErrorAction SilentlyContinue
        if (-not $azCmd) { Write-Log "  Azure CLI (az) not found." "WARN"; return $null }
        Write-Log "  Retrieving '$secretName' from '$vaultName' (az CLI)..."
        $tmpErr = [System.IO.Path]::GetTempFileName()
        $val    = (& az keyvault secret show --vault-name $vaultName --name $secretName --query value --output tsv --only-show-errors 2>$tmpErr)
        $azErr  = (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue).Trim()
        Remove-Item $tmpErr -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($val)) {
            $errDetail = if ($azErr) { ": $azErr" } else { " (exit $LASTEXITCODE)" }
            Write-Log "  az CLI failed$errDetail." "WARN"
            return $null
        }
        Write-Log "  Secret retrieved (az CLI)." "SUCCESS"
        return $val
    } catch { Write-Log "  az CLI failed: $_" "WARN"; return $null }
}

#endregion HELPERS

#region MONITORING SCRIPTBLOCKS

# ── Comprehensive node status collection ──────────────────────────────────
# This scriptblock runs ON each node via Invoke-Command and collects all
# monitoring data in a single remote call to minimize WinRM round-trips.
$CollectNodeStatus = {
    param(
        [string]$BootstrapLogPath,
        [string]$BootstrapDownloadPath,
        [string]$SolutionUpdateXmlPath,
        [string]$ValidationReportPath
    )

    $result = @{
        Node               = $env:COMPUTERNAME
        Timestamp          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        # Bootstrap status
        OverallStatus      = "Unknown"
        StartTime          = ""
        EndTime            = ""
        UpdatePhase        = @{ Status = "NotStarted"; Scan = "NotStarted"; Download = "NotStarted"; Install = "NotStarted" }
        ArcRegPhase        = @{ Status = "NotStarted" }

        # Arc agent
        ArcServiceStatus   = "Unknown"
        ArcAgentConnected  = $false
        ArcAgentVersion    = ""

        # System
        Uptime             = "Unknown"
        RebootRequired     = $false
        WUServiceRunning   = $false

        # Downloads
        DownloadFiles      = 0
        DownloadSizeMB     = 0
        RecentFiles        = @()

        # Solution update metadata
        TargetVersion      = ""
        UpdateName         = ""
        PackageSizeMB      = 0
        PlatformVersion    = ""
        OSVersion          = ""

        # Validation
        ValidationFailed   = @()
        ValidationWarning  = @()

        # Bootstrap log
        LatestLogFile      = ""
        LatestLogLines     = @()

        # Reboot events (last 30 min)
        RebootEvents       = @()

        # Errors & transient warnings
        Errors             = @()
        Warnings           = @()
    }

    # ── System uptime ──────────────────────────────────────────────────
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $uptime = (Get-Date) - $os.LastBootUpTime
        $result.Uptime = "{0}d {1:hh\:mm\:ss}" -f [int]$uptime.TotalDays, $uptime
    } catch {
        $upErr = $_.Exception.Message
        if ($upErr -match 'WinRM|WSMan|RPC server|unavailable') {
            $result.Warnings += "Node unreachable (may be rebooting)"
        } else {
            $result.Errors += "Uptime: $upErr"
        }
    }

    # ── Bootstrap status + phases ──────────────────────────────────────
    try {
        $bs = Get-ArcBootstrapStatus -ErrorAction SilentlyContinue
        if ($bs -and $bs.Response) {
            $result.OverallStatus = "$($bs.Response.Status)"
            $result.StartTime    = "$($bs.Response.StartTime)"
            $result.EndTime      = "$($bs.Response.EndTime)"

            if ($bs.Response.DetailedResponse) {
                foreach ($phase in $bs.Response.DetailedResponse) {
                    if ($phase.Name -eq "Update") {
                        $result.UpdatePhase.Status = "$($phase.Status)"
                        if ($phase.DetailedResponse) {
                            foreach ($sub in $phase.DetailedResponse) {
                                switch ($sub.Name) {
                                    "Scan"     { $result.UpdatePhase.Scan     = "$($sub.Status)" }
                                    "Download" { $result.UpdatePhase.Download = "$($sub.Status)" }
                                    "Install"  { $result.UpdatePhase.Install  = "$($sub.Status)" }
                                }
                            }
                        }
                    } elseif ($phase.Name -eq "ArcConfiguration") {
                        $result.ArcRegPhase.Status = "$($phase.Status)"
                        if ($phase.DetailedResponse) {
                            foreach ($sub in $phase.DetailedResponse) {
                                if ($sub.Name -eq "ArcRegistration") {
                                    $result.ArcRegPhase.Status = "$($sub.Status)"
                                }
                            }
                        }
                    }
                }
            }
        }
    } catch {
        $bsErr = $_.Exception.Message
        # Bootstrap service not yet started after reboot — transient, not a real error
        if ($bsErr -match 'net\.tcp://localhost:9098|BootstrapOobeService|TCP error code 10061') {
            $result.Warnings += "Bootstrap service not yet available (node may be rebooting)"
        } else {
            $result.Errors += "Bootstrap status: $bsErr"
        }
    }

    # ── Arc agent service + connection ─────────────────────────────────
    try {
        $svc = Get-Service -Name "himds" -ErrorAction SilentlyContinue
        if ($svc) { $result.ArcServiceStatus = "$($svc.Status)" }
    } catch { }

    try {
        $agentPath = "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe"
        if (Test-Path $agentPath) {
            $agentOutput = & $agentPath show 2>$null
            if ($agentOutput -match "Agent Status\s*:\s*Connected") {
                $result.ArcAgentConnected = $true
            }
            $versionMatch = $agentOutput | Where-Object { $_ -match "Agent Version\s*:\s*(.+)" }
            if ($versionMatch -and $Matches[1]) { $result.ArcAgentVersion = $Matches[1].Trim() }
        }
    } catch { }

    # ── Windows Update / Reboot pending ────────────────────────────────
    try {
        $wuSvc = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
        if ($wuSvc) { $result.WUServiceRunning = ($wuSvc.Status -eq 'Running') }
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $result.RebootRequired = $true }
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $result.RebootRequired = $true }
    } catch { }

    # ── Download directory ─────────────────────────────────────────────
    try {
        if (Test-Path $BootstrapDownloadPath) {
            $items = Get-ChildItem -Path $BootstrapDownloadPath -Recurse -File -ErrorAction SilentlyContinue
            $result.DownloadFiles  = ($items | Measure-Object).Count
            $result.DownloadSizeMB = [math]::Round(($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum / 1MB, 2)
            $result.RecentFiles    = @($items | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
                ForEach-Object { "$([System.IO.Path]::GetFileName($_.FullName)) ($([math]::Round($_.Length / 1MB, 1)) MB) $($_.LastWriteTime.ToString('HH:mm:ss'))" })
        }
    } catch { }

    # ── SolutionUpdate.xml metadata ────────────────────────────────────
    try {
        if (Test-Path $SolutionUpdateXmlPath) {
            [xml]$xml = Get-Content $SolutionUpdateXmlPath
            $update = $xml.ASZSolutionBundleUpdates.ApplicableUpdate | Select-Object -First 1
            if ($update) {
                $result.TargetVersion  = "$($update.Version)"
                $result.UpdateName     = "$($update.UpdateInfo.UpdateName)"
                $result.PackageSizeMB  = [math]::Round([int]$update.UpdateInfo.PackageSizeInMb, 0)
                $platformBom = $update.BillOfMaterials.BomItem | Where-Object { $_.Id -eq "PlatformUpdate" }
                if ($platformBom) {
                    $result.PlatformVersion = "$($platformBom.Version)"
                    $osBom = $platformBom.BomItem | Where-Object { $_.Id -eq "OSColdpatchVersion" }
                    if ($osBom) { $result.OSVersion = "$($osBom.Version)" }
                }
            }
        }
    } catch { }

    # ── Validation report ──────────────────────────────────────────────
    try {
        if (Test-Path $ValidationReportPath) {
            $report = Get-Content $ValidationReportPath -Raw | ConvertFrom-Json
            foreach ($test in $report.TestResults) {
                if ($test.Status -eq "Failed") {
                    $result.ValidationFailed += "$($test.Title): $($test.AdditionalData.Message)"
                } elseif ($test.Status -eq "Warning") {
                    $result.ValidationWarning += "$($test.Title): $($test.AdditionalData.Message)"
                }
            }
        }
    } catch { }

    # ── Latest bootstrap log ───────────────────────────────────────────
    try {
        if (Test-Path $BootstrapLogPath) {
            $latestLog = Get-ChildItem -Path $BootstrapLogPath -Filter "*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestLog) {
                $result.LatestLogFile  = $latestLog.FullName
                $result.LatestLogLines = @(Get-Content -Path $latestLog.FullName -Tail 10 -ErrorAction SilentlyContinue)
            }
        }
    } catch { }

    # ── Reboot events (last 30 min) ───────────────────────────────────
    try {
        $since = (Get-Date).AddMinutes(-30)
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            ID        = 1074, 6006, 6008, 6013, 41
            StartTime = $since
        } -ErrorAction SilentlyContinue | Select-Object -First 5

        $result.RebootEvents = @($events | ForEach-Object {
            $type = switch ($_.Id) {
                1074 { "Restart Initiated" }
                6006 { "Clean Shutdown" }
                6008 { "Unexpected Shutdown" }
                6013 { "System Uptime" }
                41   { "Unclean Reboot" }
                default { "Event $($_.Id)" }
            }
            "$($_.TimeCreated.ToString('HH:mm:ss')) $type"
        })
    } catch { }

    return $result
}

#endregion MONITORING SCRIPTBLOCKS

#region DISPLAY FUNCTIONS

function Show-NodeStatus {
    param($Status, [string]$NodeName, [string]$NodeIP, $DownloadMetrics)

    Write-Log "────────────────────────────────────────────────────────────" HEADER
    Write-Log "  NODE: $NodeName  ($NodeIP)" HEADER
    Write-Log "────────────────────────────────────────────────────────────" HEADER

    if (-not $Status) {
        Write-Log "  UNREACHABLE (may be rebooting for OEM update)" WARN
        return
    }

    # Uptime
    Write-Log "  Uptime         : $($Status.Uptime)" INFO

    # Overall bootstrap status
    $bsLevel = switch -Regex ($Status.OverallStatus) {
        "Succeeded"       { "PASS" }
        "Failed"          { "FAIL" }
        "InProgress"      { "INFO" }
        default           { "WARN" }
    }
    Write-Log "  Bootstrap      : $($Status.OverallStatus)" $bsLevel

    # Update phases
    if ($Status.UpdatePhase.Status -ne "NotStarted") {
        $upLevel = switch ($Status.UpdatePhase.Status) {
            "Succeeded"  { "PASS" }
            "Failed"     { "FAIL" }
            "InProgress" { "WARN" }
            default      { "INFO" }
        }
        Write-Log "  Update Phase   : $($Status.UpdatePhase.Status)" $upLevel
        Write-Log "    Scan         : $($Status.UpdatePhase.Scan)" VERBOSE
        Write-Log "    Download     : $($Status.UpdatePhase.Download)" VERBOSE
        Write-Log "    Install      : $($Status.UpdatePhase.Install)" VERBOSE
    }

    # Arc registration phase
    $arcLevel = switch ($Status.ArcRegPhase.Status) {
        "Succeeded"  { "PASS" }
        "Failed"     { "FAIL" }
        "InProgress" { "WARN" }
        default      { "INFO" }
    }
    Write-Log "  Arc Reg Phase  : $($Status.ArcRegPhase.Status)" $arcLevel

    # Solution update metadata
    if ($Status.TargetVersion) {
        Write-Log "  Target Version : $($Status.TargetVersion)" INFO
        if ($Status.PackageSizeMB -gt 0) {
            # PackageSizeMB is the bundle metadata from SolutionUpdate.xml. Actual download
            # includes all OEM drivers, OS patches, and firmware — typically 10-20x larger.
            $pkgNote = if ($Status.DownloadSizeMB -gt $Status.PackageSizeMB * 1.5) {
                "(bundle metadata only — actual download is $($Status.DownloadSizeMB) MB)"
            } else { "(from SolutionUpdate.xml)" }
            Write-Log "  Package Meta   : $($Status.PackageSizeMB) MB $pkgNote" INFO
        }
        if ($Status.PlatformVersion)     { Write-Log "  Platform       : $($Status.PlatformVersion)" VERBOSE }
        if ($Status.OSVersion)           { Write-Log "  OS Version     : $($Status.OSVersion)" VERBOSE }
    }

    # Download directory — enhanced with rate/delta/ETA
    if ($Status.DownloadFiles -gt 0) {
        $dlLine = "  Downloads      : $($Status.DownloadFiles) files ($($Status.DownloadSizeMB) MB)"

        # Append delta from last poll
        if ($DownloadMetrics -and ($DownloadMetrics.DeltaMB -ne 0 -or $DownloadMetrics.DeltaFiles -ne 0)) {
            $deltaSign = if ($DownloadMetrics.DeltaMB -ge 0) { "+" } else { "" }
            $dlLine += "  [${deltaSign}$($DownloadMetrics.DeltaMB) MB, ${deltaSign}$($DownloadMetrics.DeltaFiles) files since last poll]"
        }
        Write-Log $dlLine INFO

        # Download rate
        if ($DownloadMetrics -and $DownloadMetrics.HasRate) {
            $rateLevel = if ($DownloadMetrics.IsDownloading) { "WARN" } else { "INFO" }
            Write-Log "  Download Rate  : ~$($DownloadMetrics.RateMBPerMin) MB/min" $rateLevel
        }

        # Progress bar + ETA (only when we have a completed reference size)
        if ($DownloadMetrics -and $DownloadMetrics.HasReference -and $DownloadMetrics.PctComplete -gt 0) {
            # Build text progress bar: [████████░░░░░░░░░░░░] 42.3%
            $barWidth = 30
            $filled   = [math]::Round($barWidth * $DownloadMetrics.PctComplete / 100)
            $empty    = $barWidth - $filled
            $bar      = ('█' * $filled) + ('░' * $empty)
            $pctLine  = "  Progress       : [$bar] $($DownloadMetrics.PctComplete)%"

            if ($DownloadMetrics.EstMinutes -gt 0 -and $DownloadMetrics.IsDownloading) {
                if ($DownloadMetrics.EstMinutes -ge 60) {
                    $etaH = [math]::Floor($DownloadMetrics.EstMinutes / 60)
                    $etaM = $DownloadMetrics.EstMinutes % 60
                    $pctLine += "  (~${etaH}h ${etaM}m remaining)"
                } else {
                    $pctLine += "  (~$($DownloadMetrics.EstMinutes) min remaining)"
                }
            }
            Write-Log $pctLine INFO
        } elseif ($DownloadMetrics -and $DownloadMetrics.IsDownloading -and -not $DownloadMetrics.HasReference) {
            # No reference yet — show what we can
            if ($DownloadMetrics.HasRate) {
                Write-Log "  Progress       : Downloading... (no reference total yet — first node to complete sets baseline)" INFO
            }
        }

        foreach ($rf in $Status.RecentFiles) {
            Write-Log "    Recent: $rf" VERBOSE
        }
    }

    # Arc agent
    if ($Status.ArcServiceStatus -ne "Unknown") {
        $svcLevel = if ($Status.ArcServiceStatus -eq "Running") { "PASS" } else { "WARN" }
        Write-Log "  Arc Service    : $($Status.ArcServiceStatus)" $svcLevel
    }
    if ($Status.ArcAgentConnected) {
        Write-Log "  Arc Agent      : Connected$(if ($Status.ArcAgentVersion) { " (v$($Status.ArcAgentVersion))" })" PASS
    } elseif ($Status.UpdatePhase.Install -in "NotStarted", "InProgress") {
        Write-Log "  Arc Agent      : Not installed yet (waiting for OS update)" INFO
    }

    # Windows Update
    if ($Status.WUServiceRunning) { Write-Log "  Windows Update : Service Running" INFO }
    if ($Status.RebootRequired)   { Write-Log "  REBOOT PENDING" WARN }

    # Validation issues
    foreach ($vf in $Status.ValidationFailed) { Write-Log "  Val FAIL: $vf" FAIL }
    foreach ($vw in $Status.ValidationWarning) { Write-Log "  Val WARN: $vw" WARN }

    # Reboot events
    foreach ($re in $Status.RebootEvents) { Write-Log "  Reboot Event: $re" WARN }

    # Errors
    foreach ($w in $Status.Warnings) { Write-Log "  Warning: $w" WARN }
    foreach ($e in $Status.Errors) { Write-Log "  Error: $e" FAIL }
}

function Show-BootstrapLogs {
    param($Status, [string]$NodeName, [int]$Lines)

    if (-not $Status -or -not $Status.LatestLogFile) { return }

    Write-Log "  Log: $($Status.LatestLogFile)" VERBOSE
    $linesToShow = if ($Status.LatestLogLines.Count -le $Lines) { $Status.LatestLogLines } else { $Status.LatestLogLines[-$Lines..-1] }
    foreach ($line in $linesToShow) {
        Write-Log "    $line" DEBUG
    }
}

function Get-DownloadMetrics {
    param(
        [System.Collections.ArrayList]$History,
        [double]$CompletedRefMB,
        [string]$DownloadPhaseStatus
    )

    $metrics = [PSCustomObject]@{
        DeltaMB       = 0
        DeltaFiles    = 0
        RateMBPerMin  = 0
        PctComplete   = 0
        EstMinutes    = 0
        HasRate       = $false
        HasReference  = ($CompletedRefMB -gt 0)
        IsDownloading = ($DownloadPhaseStatus -eq 'InProgress')
    }

    if (-not $History -or $History.Count -lt 2) { return $metrics }

    # Delta from last poll
    $prev = $History[$History.Count - 2]
    $curr = $History[$History.Count - 1]
    $metrics.DeltaMB    = [math]::Round($curr.SizeMB - $prev.SizeMB, 2)
    $metrics.DeltaFiles = $curr.Files - $prev.Files

    # Rate: use up to last 5 samples for a smoother average
    $window = [math]::Min($History.Count, 5)
    $oldest = $History[$History.Count - $window]
    $newest = $curr
    $elapsedMin = ($newest.Time - $oldest.Time).TotalMinutes
    if ($elapsedMin -gt 0) {
        $totalDelta = $newest.SizeMB - $oldest.SizeMB
        $metrics.RateMBPerMin = [math]::Round($totalDelta / $elapsedMin, 1)
        $metrics.HasRate = ($metrics.RateMBPerMin -gt 0)
    }

    # Percentage + ETA (only if we have a completed reference size)
    if ($CompletedRefMB -gt 0 -and $curr.SizeMB -gt 0) {
        $metrics.PctComplete = [math]::Min(100, [math]::Round(($curr.SizeMB / $CompletedRefMB) * 100, 1))
        if ($metrics.HasRate -and $metrics.PctComplete -lt 100) {
            $remainingMB = $CompletedRefMB - $curr.SizeMB
            if ($remainingMB -gt 0) {
                $metrics.EstMinutes = [math]::Round($remainingMB / $metrics.RateMBPerMin, 0)
            }
        }
    }

    return $metrics
}

function Show-DashboardScreen {
    param(
        [hashtable]$NodeStatuses,
        [array]$Nodes,
        [hashtable]$DlHistory,
        [hashtable]$DlMetrics,
        [double]$RefMB,
        [int]$Iteration,
        [int]$MaxIter,
        [DateTime]$StartTime,
        [int]$PollSec
    )

    Clear-Host
    $elapsed = (Get-Date) - $StartTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    # ── Header ──────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                      ARC BOOTSTRAP MONITOR                               ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Nodes: " -NoNewline -ForegroundColor Gray
    Write-Host "$($Nodes.Count)" -NoNewline -ForegroundColor White
    Write-Host "  |  Elapsed: " -NoNewline -ForegroundColor Gray
    Write-Host "$elapsedStr" -NoNewline -ForegroundColor Yellow
    Write-Host "  |  Poll: " -NoNewline -ForegroundColor Gray
    Write-Host "$Iteration/$MaxIter" -ForegroundColor White
    Write-Host ""

    # ── Node Status Table ───────────────────────────────────────────────────
    Write-Host "  ┌────────────────┬────────────┬────────────┬────────────┬───────────┐" -ForegroundColor DarkGray
    Write-Host "  │ Node           │ Bootstrap  │ Update     │ Arc Reg    │ Agent     │" -ForegroundColor DarkGray
    Write-Host "  ├────────────────┼────────────┼────────────┼────────────┼───────────┤" -ForegroundColor DarkGray

    foreach ($node in $Nodes) {
        $s = $NodeStatuses[$node.hostname]
        $nName = $node.hostname
        if ($nName.Length -gt 14) { $nName = $nName.Substring($nName.Length - 14) }

        Write-Host "  │ " -NoNewline -ForegroundColor DarkGray

        if (-not $s) {
            Write-Host "$($nName.PadRight(14))" -NoNewline -ForegroundColor White
            Write-Host " │ " -NoNewline -ForegroundColor DarkGray
            Write-Host "REBOOTING " -NoNewline -ForegroundColor Yellow
            Write-Host " │ " -NoNewline -ForegroundColor DarkGray
            Write-Host "---       " -NoNewline -ForegroundColor DarkGray
            Write-Host " │ " -NoNewline -ForegroundColor DarkGray
            Write-Host "---       " -NoNewline -ForegroundColor DarkGray
            Write-Host " │ " -NoNewline -ForegroundColor DarkGray
            Write-Host "---      " -NoNewline -ForegroundColor DarkGray
            Write-Host " │" -ForegroundColor DarkGray
        } else {
            Write-Host "$($nName.PadRight(14))" -NoNewline -ForegroundColor White
            Write-Host " │ " -NoNewline -ForegroundColor DarkGray

            # Bootstrap — show "Rebooting" when service is unavailable (warning present)
            $bsRaw = "$($s.OverallStatus)"
            if ($bsRaw -eq "Unknown" -and $s.Warnings.Count -gt 0) { $bsRaw = "Rebooting" }
            $bsColor = switch -Regex ($bsRaw) { "Succeeded" { "Green" }; "Failed" { "Red" }; "InProgress|Rebooting" { "Yellow" }; default { "DarkGray" } }
            Write-Host "$($bsRaw.PadRight(10))" -NoNewline -ForegroundColor $bsColor
            Write-Host " │ " -NoNewline -ForegroundColor DarkGray

            # Update — show active sub-phase if in progress; truncate long statuses
            $upRaw = "$($s.UpdatePhase.Status)"
            if ($upRaw -eq "InProgress") {
                if ($s.UpdatePhase.Download -eq "InProgress") { $upRaw = "Download" }
                elseif ($s.UpdatePhase.Install -eq "InProgress") { $upRaw = "Install" }
                elseif ($s.UpdatePhase.Scan -eq "InProgress") { $upRaw = "Scan" }
            } elseif ($upRaw -eq "NotApplicable") { $upRaw = "N/A" }
            elseif ($upRaw -eq "NotStarted") { $upRaw = "Waiting" } elseif ($upRaw -eq "NotApplicable") { $upRaw = "N/A" }
            elseif ($upRaw -eq "NotStarted") { $upRaw = "Pending" }
            $upColor = switch ($s.UpdatePhase.Status) { "Succeeded" { "Green" }; "Failed" { "Red" }; "InProgress" { "Yellow" }; "NotApplicable" { "DarkGray" }; default { "DarkGray" } }
            Write-Host "$($upRaw.PadRight(10))" -NoNewline -ForegroundColor $upColor
            Write-Host " │ " -NoNewline -ForegroundColor DarkGray

            # Arc reg
            $arcRaw = "$($s.ArcRegPhase.Status)"
            if ($arcRaw -eq "NotStarted") { $arcRaw = "Pending" }
            elseif ($arcRaw -eq "NotApplicable") { $arcRaw = "N/A" }
            $arcColor = switch ($s.ArcRegPhase.Status) { "Succeeded" { "Green" }; "Failed" { "Red" }; "InProgress" { "Yellow" }; default { "DarkGray" } }
            Write-Host "$($arcRaw.PadRight(10))" -NoNewline -ForegroundColor $arcColor
            Write-Host " │ " -NoNewline -ForegroundColor DarkGray

            # Agent
            $agentRaw = if ($s.ArcAgentConnected) { "Connected" } elseif ($s.ArcServiceStatus -eq "Running") { "Running" } else { "---" }
            $agentColor = if ($s.ArcAgentConnected) { "Green" } elseif ($s.ArcServiceStatus -eq "Running") { "Yellow" } else { "DarkGray" }
            Write-Host "$($agentRaw.PadRight(9))" -NoNewline -ForegroundColor $agentColor
            Write-Host " │" -ForegroundColor DarkGray
        }
    }

    Write-Host "  └────────────────┴────────────┴────────────┴────────────┴───────────┘" -ForegroundColor DarkGray
    Write-Host ""

    # ── Download Progress ───────────────────────────────────────────────────
    $hasDownloads = $false
    foreach ($node in $Nodes) {
        $s = $NodeStatuses[$node.hostname]
        if ($s -and $s.UpdatePhase.Status -ne "NotApplicable" -and ($s.DownloadFiles -gt 0 -or ($s.UpdatePhase.Download -notin "NotStarted",""))) { $hasDownloads = $true; break }
    }

    if ($hasDownloads) {
        Write-Host "  ┌──────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
        Write-Host "  │  DOWNLOAD PROGRESS                                                       │" -ForegroundColor Cyan
        Write-Host "  ├──────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkGray

        foreach ($node in $Nodes) {
            $s = $NodeStatuses[$node.hostname]
            $short = ($node.hostname -split '-')[-1]

            if (-not $s) {
                $txt = "  $($short): REBOOTING"
                Write-Host "  │" -NoNewline -ForegroundColor DarkGray
                Write-Host $txt -NoNewline -ForegroundColor Yellow
                Write-Host (" " * [math]::Max(0, 72 - $txt.Length)) -NoNewline
                Write-Host "│" -ForegroundColor DarkGray
                continue
            }

            if ($s.DownloadFiles -eq 0 -and $s.UpdatePhase.Download -in "NotStarted","") {
                $txt = "  $($short): Waiting..."
                Write-Host "  │" -NoNewline -ForegroundColor DarkGray
                Write-Host $txt -NoNewline -ForegroundColor DarkGray
                Write-Host (" " * [math]::Max(0, 72 - $txt.Length)) -NoNewline
                Write-Host "│" -ForegroundColor DarkGray
                continue
            }

            # Calculate percentage
            $m = if ($DlMetrics.ContainsKey($node.hostname)) { $DlMetrics[$node.hostname] } else { $null }
            $pct = 0
            if ($s.UpdatePhase.Download -eq "Succeeded") { $pct = 100 }
            elseif ($m -and $m.PctComplete -gt 0) { $pct = $m.PctComplete }

            $barWidth = 25
            $filled = [math]::Round($barWidth * $pct / 100)
            $empty = $barWidth - $filled
            $barColor = if ($pct -ge 100) { "Green" } elseif ($pct -gt 0) { "Yellow" } else { "DarkGray" }

            $sizeStr = "$($s.DownloadSizeMB) MB"
            $etaStr = ""
            if ($s.UpdatePhase.Download -eq "Succeeded") { $etaStr = "Complete" }
            elseif ($m -and $m.EstMinutes -gt 0 -and $m.IsDownloading) {
                if ($m.EstMinutes -ge 60) {
                    $h = [math]::Floor($m.EstMinutes / 60); $mn = $m.EstMinutes % 60
                    $etaStr = "~${h}h${mn}m"
                } else { $etaStr = "~$($m.EstMinutes)m" }
            }

            Write-Host "  │  $($short): [" -NoNewline -ForegroundColor Gray
            Write-Host ("█" * $filled) -NoNewline -ForegroundColor $barColor
            Write-Host ("░" * $empty) -NoNewline -ForegroundColor DarkGray
            Write-Host "] " -NoNewline -ForegroundColor Gray
            $pctStr = ("{0,3}" -f [math]::Round($pct)) + "%"
            Write-Host $pctStr -NoNewline -ForegroundColor Cyan
            Write-Host "  $sizeStr" -NoNewline -ForegroundColor White
            Write-Host "  $etaStr" -NoNewline -ForegroundColor DarkGray
            # Pad to fill box (74 inner chars)
            $contentLen = 4 + $short.Length + 3 + $barWidth + 2 + $pctStr.Length + 2 + $sizeStr.Length + 2 + $etaStr.Length
            Write-Host (" " * [math]::Max(0, 74 - $contentLen)) -NoNewline
            Write-Host "│" -ForegroundColor DarkGray
        }

        Write-Host "  └──────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
        Write-Host ""
    }

    # ── Events ──────────────────────────────────────────────────────────────
    $events = [System.Collections.ArrayList]::new()
    foreach ($node in $Nodes) {
        $s = $NodeStatuses[$node.hostname]
        $short = ($node.hostname -split '-')[-1]

        if (-not $s) {
            [void]$events.Add(@{ Text = "$($short): Unreachable — may be rebooting"; Color = "Yellow" })
            continue
        }
        if ($s.RebootRequired) { [void]$events.Add(@{ Text = "$($short): REBOOT PENDING"; Color = "Yellow" }) }
        foreach ($re in $s.RebootEvents) { [void]$events.Add(@{ Text = "$($short): $re"; Color = "Yellow" }) }
        foreach ($vf in $s.ValidationFailed) {
            $msg = if ($vf.Length -gt 55) { $vf.Substring(0, 52) + "..." } else { $vf }
            [void]$events.Add(@{ Text = "$($short): FAIL: $msg"; Color = "Red" })
        }
        foreach ($w in $s.Warnings) {
            $msg = if ($w.Length -gt 60) { $w.Substring(0, 57) + "..." } else { $w }
            [void]$events.Add(@{ Text = "$($short): $msg"; Color = "Yellow" })
        }
        foreach ($e in $s.Errors) {
            $msg = if ($e.Length -gt 55) { $e.Substring(0, 52) + "..." } else { $e }
            [void]$events.Add(@{ Text = "$($short): $e"; Color = "Red" })
        }
        if ($s.ArcAgentConnected) {
            $v = if ($s.ArcAgentVersion) { " v$($s.ArcAgentVersion)" } else { "" }
            [void]$events.Add(@{ Text = "$($short): Arc agent connected$v"; Color = "Green" })
        }
        if ($s.WUServiceRunning -and $s.UpdatePhase.Download -eq "InProgress") {
            $rate = ""
            $m = if ($DlMetrics.ContainsKey($node.hostname)) { $DlMetrics[$node.hostname] } else { $null }
            if ($m -and $m.HasRate) { $rate = " (~$($m.RateMBPerMin) MB/min)" }
            [void]$events.Add(@{ Text = "$($short): Downloading OEM updates$rate"; Color = "Cyan" })
        }
    }

    if ($events.Count -gt 0) {
        Write-Host "  ┌──────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
        Write-Host "  │  EVENTS                                                                  │" -ForegroundColor Cyan
        Write-Host "  ├──────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkGray

        $maxEv = [math]::Min($events.Count, 8)
        for ($ei = 0; $ei -lt $maxEv; $ei++) {
            $ev = $events[$ei]
            $evText = $ev.Text
            if ($evText.Length -gt 72) { $evText = $evText.Substring(0, 69) + "..." }
            Write-Host "  │  " -NoNewline -ForegroundColor DarkGray
            Write-Host $evText -NoNewline -ForegroundColor $ev.Color
            Write-Host (" " * [math]::Max(0, 72 - $evText.Length)) -NoNewline
            Write-Host "│" -ForegroundColor DarkGray
        }

        Write-Host "  └──────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
    }

    Write-Host ""

    # ── Summary line ────────────────────────────────────────────────────────
    $succeeded = @($Nodes | Where-Object { $NodeStatuses[$_.hostname] -and $NodeStatuses[$_.hostname].OverallStatus -eq "Succeeded" }).Count
    $failed    = @($Nodes | Where-Object { $NodeStatuses[$_.hostname] -and $NodeStatuses[$_.hostname].OverallStatus -eq "Failed" }).Count
    $inProg    = @($Nodes | Where-Object { $NodeStatuses[$_.hostname] -and $NodeStatuses[$_.hostname].OverallStatus -eq "InProgress" }).Count
    $unreach   = @($Nodes | Where-Object { -not $NodeStatuses[$_.hostname] }).Count

    Write-Host "  " -NoNewline
    if ($succeeded -gt 0) { Write-Host "$succeeded OK" -NoNewline -ForegroundColor Green; Write-Host "  " -NoNewline }
    if ($inProg -gt 0)    { Write-Host "$inProg Running" -NoNewline -ForegroundColor Yellow; Write-Host "  " -NoNewline }
    if ($failed -gt 0)    { Write-Host "$failed Failed" -NoNewline -ForegroundColor Red; Write-Host "  " -NoNewline }
    if ($unreach -gt 0)   { Write-Host "$unreach Rebooting" -NoNewline -ForegroundColor Yellow }
    Write-Host ""

    # ── Completion banner ───────────────────────────────────────────────────
    if ($succeeded -eq $Nodes.Count -and $Nodes.Count -gt 0) {
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "  ║             ALL NODES COMPLETED — BOOTSTRAP SUCCEEDED                    ║" -ForegroundColor Green
        Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    } elseif ($failed -gt 0 -and ($failed + $succeeded) -eq $Nodes.Count) {
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "  ║             BOOTSTRAP COMPLETED WITH FAILURES                            ║" -ForegroundColor Red
        Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    }

    Write-Host ""

    # ── Footer ──────────────────────────────────────────────────────────────
    Write-Host "  ──────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Last refresh: $(Get-Date -Format 'HH:mm:ss')  |  Next: ${PollSec}s  |  Ctrl+C to exit" -ForegroundColor DarkGray
}

#endregion DISPLAY FUNCTIONS

#region MAIN

Write-Log "================================================================" HEADER
Write-Log "   Phase 04 Arc Registration — Task 03: Bootstrap Monitor" HEADER
Write-Log "================================================================" HEADER
Write-Log "" INFO
Write-Log "  Action   : Poll bootstrap status on each node" INFO
Write-Log "  Interval : $PollIntervalSeconds seconds" INFO
Write-Log "  Max time : ~$([math]::Round($PollIntervalSeconds * $MaxIterations / 60)) minutes ($MaxIterations iterations)" INFO
Write-Log "  Mode     : Read-only. No changes made to any node." INFO
Write-Log "  Log      : $logFile" INFO
Write-Log "" INFO

# ── Load config ──────────────────────────────────────────────────────────────
Write-Log "Config : $ConfigPath" INFO
Write-Log "--- Loading configuration ---" HEADER

$cfg = Get-Config -Path $ConfigPath

# ── Apply YAML-overridable parameter overrides ───────────────────────────────
if ($SubscriptionId -ne "") { $cfg.SubscriptionId = $SubscriptionId; Write-Log "  Override: SubscriptionId=$SubscriptionId" WARN }
if ($ResourceGroup  -ne "") { $cfg.ResourceGroup  = $ResourceGroup;  Write-Log "  Override: ResourceGroup=$ResourceGroup" WARN }

Write-Log "Found $($cfg.Nodes.Count) node(s):" INFO
$cfg.Nodes | ForEach-Object { Write-Log "  $($_.hostname)  ($($_.ip))" INFO }

# ── Resolve credentials ───────────────────────────────────────────────────────
# CREDENTIAL RESOLUTION ORDER:
# 1. -Credential parameter (passed directly)
# 2. Key Vault (Az.KeyVault module, then az CLI fallback)
# 3. Interactive Get-Credential prompt
Write-Log "--- Resolving credentials ---" HEADER
if (-not $Credential) {
    $adminUser    = $cfg.AdminUser                                   # identity.accounts.account_local_admin_username
    $adminPassUri = $cfg.AdminPassUri                                # identity.accounts.account_local_admin_password
    Write-Log "Resolving credentials from Key Vault..."
    $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
    if ($adminPass) {
        $Credential = [PSCredential]::new($adminUser, (ConvertTo-SecureString $adminPass -AsPlainText -Force))
        Write-Log "Credentials resolved for '$adminUser'." SUCCESS
    } else {
        Write-Log "Key Vault unavailable — prompting for credentials." WARN
        $Credential = Get-Credential -Message "Enter local Administrator credentials for cluster nodes" -UserName $adminUser
    }
} else {
    Write-Log "Credentials provided via -Credential parameter." SUCCESS
}

# ── Apply TargetNode filter ───────────────────────────────────────────────────
$nodes = $cfg.Nodes
if ($TargetNode.Count -gt 0) {
    $nodes = @($nodes | Where-Object { $TargetNode -contains $_.hostname -or $TargetNode -contains $_.nodename -or $TargetNode -contains $_.ip })
    if ($nodes.Count -eq 0) { throw "No nodes matched filter: $($TargetNode -join ', ')" }
    Write-Log "Node filter applied — running against: $($nodes.hostname -join ', ')" WARN
}

# ── WhatIf — dry-run mode ────────────────────────────────────────────────────
if ($WhatIf) {
    Write-Log "" INFO
    Write-Log "================================================================" HEADER
    Write-Log "  WHATIF — Dry-run mode. No connections will be made." HEADER
    Write-Log "================================================================" HEADER
    Write-Log "" INFO
    Write-Log "Would monitor bootstrap status on $($nodes.Count) node(s):" INFO
    Write-Log "" INFO

    foreach ($n in $nodes) {
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        Write-Log "  NODE: $($n.hostname)  ($($n.ip))" HEADER
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        Write-Log "  WHATIF: Would collect comprehensive bootstrap status including:" INFO
        Write-Log "    - Get-ArcBootstrapStatus (phases: Update Scan/Download/Install, ArcConfiguration)" INFO
        Write-Log "    - SolutionUpdate.xml metadata (target version, package size)" INFO
        Write-Log "    - Download directory size/count ($BootstrapDownloadPath)" INFO
        Write-Log "    - Windows Update service and reboot pending status" INFO
        Write-Log "    - System reboot events (Event IDs 1074, 6006, 6008, 41)" INFO
        Write-Log "    - Arc agent status (himds service, azcmagent show)" INFO
        Write-Log "    - Bootstrap log tail ($BootstrapLogPath)" INFO
        Write-Log "    - Validation report ($ValidationReportPath)" INFO
        Write-Log "  WHATIF: Would poll every $PollIntervalSeconds seconds, max $MaxIterations iterations" INFO
        Write-Log "  WHATIF: Would handle unreachable nodes (reboots during OEM updates)" INFO
        Write-Log "" INFO
    }

    Write-Log "Poll interval  : $PollIntervalSeconds seconds" INFO
    Write-Log "Max iterations : $MaxIterations (~$([math]::Round($PollIntervalSeconds * $MaxIterations / 60)) min)" INFO
    Write-Log "Continuous mode: $ContinuousMode" INFO
    Write-Log "" INFO
    Write-Log "Re-run without -WhatIf to execute." INFO
    Write-Log "Log file: $logFile" INFO
    exit 0
}

# ── Polling loop ──────────────────────────────────────────────────────────────
Write-Log "" INFO
Write-Log "Starting bootstrap monitor..." HEADER
Write-Log "Press Ctrl+C to stop monitoring (nodes continue in background)." INFO
Write-Log "================================================================" HEADER

$nodeStatus = @{}  # Track last-known status per node
$downloadHistory = @{}  # Track download size over time per node: hostname -> ArrayList of @{Time; SizeMB; Files}
$completedDownloadSize = 0  # Reference: final download size from first node to finish (used for ETA on remaining nodes)
$startTime  = Get-Date

for ($i = 1; $i -le $MaxIterations; $i++) {
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
    if (-not $Dashboard) {
        Write-Log "" INFO
        Write-Log "=== Iteration $i / $MaxIterations  $(Get-Date -Format 'HH:mm:ss')  (${elapsed} min elapsed) ===" HEADER
    }
    "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [----] === Iteration $i / $MaxIterations (${elapsed} min) ===" | Out-File -FilePath $logFile -Append -Encoding utf8

    $allDone = $true
    $nodeMetrics = @{}

    foreach ($node in $nodes) {
        try {
            $status = Invoke-Command -ComputerName $node.ip -Credential $Credential `
                -ArgumentList $BootstrapLogPath, $BootstrapDownloadPath, $SolutionUpdateXmlPath, $ValidationReportPath `
                -ScriptBlock $CollectNodeStatus -ErrorAction Stop

            $nodeStatus[$node.hostname] = $status

            # Track download history for rate/ETA calculations
            if (-not $downloadHistory.ContainsKey($node.hostname)) {
                $downloadHistory[$node.hostname] = [System.Collections.ArrayList]::new()
            }
            [void]$downloadHistory[$node.hostname].Add(@{
                Time   = Get-Date
                SizeMB = [double]$status.DownloadSizeMB
                Files  = [int]$status.DownloadFiles
            })

            # If this node's download phase just completed, record the final size as reference
            if ($status.UpdatePhase.Download -in 'Succeeded','Failed' -and $completedDownloadSize -eq 0 -and $status.DownloadSizeMB -gt 0) {
                $completedDownloadSize = $status.DownloadSizeMB
                Write-Log "  Download reference size set: $completedDownloadSize MB (from $($node.hostname))" INFO
            }

            # Calculate download metrics
            $dlMetrics = Get-DownloadMetrics -History $downloadHistory[$node.hostname] `
                -CompletedRefMB $completedDownloadSize `
                -DownloadPhaseStatus $status.UpdatePhase.Download
            $nodeMetrics[$node.hostname] = $dlMetrics

            # Display rich status (skip in dashboard mode — renders all at once after loop)
            if (-not $Dashboard) {
                Show-NodeStatus -Status $status -NodeName $node.hostname -NodeIP $node.ip -DownloadMetrics $dlMetrics
                Show-BootstrapLogs -Status $status -NodeName $node.hostname -Lines $TailLines
            }

            if ($status.OverallStatus -notin "Succeeded", "Failed") { $allDone = $false }

        } catch {
            $nodeStatus[$node.hostname] = $null
            if (-not $Dashboard) {
                Write-Log "────────────────────────────────────────────────────────────" HEADER
                Write-Log "  NODE: $($node.hostname)  ($($node.ip))" HEADER
                Write-Log "────────────────────────────────────────────────────────────" HEADER
                Write-Log "  UNREACHABLE (may be rebooting for OEM update)" WARN
                Write-Log "  Error: $($_.Exception.Message)" DEBUG
            } else {
                "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [WARN] $($node.hostname): Unreachable - $($_.Exception.Message)" | Out-File -FilePath $logFile -Append -Encoding utf8
            }
            $allDone = $false
        }
    }

    # ── Dashboard rendering ───────────────────────────────────────────────────
    if ($Dashboard) {
        Show-DashboardScreen -NodeStatuses $nodeStatus -Nodes $nodes `
            -DlHistory $downloadHistory -DlMetrics $nodeMetrics -RefMB $completedDownloadSize `
            -Iteration $i -MaxIter $MaxIterations -StartTime $startTime -PollSec $PollIntervalSeconds
        # Log compact summary to file (console handled by dashboard)
        foreach ($n in $nodes) {
            $s = $nodeStatus[$n.hostname]
            if ($s) {
                $line = "$($n.hostname): $($s.OverallStatus) | Update: $($s.UpdatePhase.Status) | ArcReg: $($s.ArcRegPhase.Status)"
                if ($s.ArcAgentConnected) { $line += " | Agent: Connected" }
                "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [INFO] $line" | Out-File -FilePath $logFile -Append -Encoding utf8
            }
        }
    }

    # ── Azure-side verification (only when nodes report Arc agent connected) ──
    if (-not $Dashboard) {
        $connectedNodes = @($nodeStatus.GetEnumerator() | Where-Object { $_.Value -and $_.Value.ArcAgentConnected })
        if ($connectedNodes.Count -gt 0) {
            Write-Log "" INFO
            Write-Log "--- Azure-side Arc verification ---" HEADER
            try {
                $azSub = $cfg.SubscriptionId                             # azure_platform.subscriptions.lab.id
                $azRG  = $cfg.ResourceGroup                              # compute.azure_local.arc_resource_group

                foreach ($entry in $connectedNodes) {
                    $arcName = $entry.Key.ToLower()
                    try {
                        $arcResource = Get-AzConnectedMachine -ResourceGroupName $azRG -Name $arcName -SubscriptionId $azSub -ErrorAction Stop
                        Write-Log "  $arcName : Azure Status=$($arcResource.Status), Provisioning=$($arcResource.ProvisioningState)" PASS
                    } catch {
                        Write-Log "  $arcName : Not found in Azure RG '$azRG' — $($_.Exception.Message)" WARN
                    }
                }
            } catch {
                Write-Log "  Azure verification skipped: $($_.Exception.Message)" WARN
            }
        }
    }

    if ($allDone -and -not $ContinuousMode) {
        Write-Log "" INFO
        Write-Log "All nodes completed bootstrap." PASS
        break
    }

    if ($i -lt $MaxIterations) {
        if (-not $Dashboard) {
            Write-Log "" INFO
            Write-Log "Waiting $PollIntervalSeconds seconds... (Ctrl+C to stop)" INFO
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

# ── Final summary ──────────────────────────────────────────────────────────
$elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
Write-Log "" INFO
Write-Log "================================================================" HEADER
Write-Log "  SUMMARY  (${elapsed} min total)" HEADER
Write-Log "================================================================" HEADER

$summary = @()
foreach ($node in $nodes) {
    $s = $nodeStatus[$node.hostname]
    $finalStatus = if ($s) { $s.OverallStatus } else { "Unreachable" }
    $summary += [PSCustomObject]@{
        Node   = $node.hostname
        IP     = $node.ip
        Status = $finalStatus
        Update = if ($s) { $s.UpdatePhase.Status } else { "-" }
        ArcReg = if ($s) { $s.ArcRegPhase.Status } else { "-" }
        Agent  = if ($s -and $s.ArcAgentConnected) { "Connected" } else { "-" }
    }
}

$tableStr = ($summary | Format-Table Node, IP, Status, Update, ArcReg, Agent -AutoSize | Out-String).Trim()
Write-Host $tableStr
$tableStr | Out-File -FilePath $logFile -Append -Encoding utf8

$succeeded   = @($summary | Where-Object { $_.Status -eq 'Succeeded' }).Count
$failed      = @($summary | Where-Object { $_.Status -eq 'Failed' }).Count
$unreachable = @($summary | Where-Object { $_.Status -eq 'Unreachable' }).Count
$other       = @($summary | Where-Object { $_.Status -notin 'Succeeded','Failed','Unreachable' }).Count

if ($succeeded -eq $nodes.Count) {
    Write-Log "All $($nodes.Count) node(s) bootstrap completed successfully." PASS
    Write-Log "" INFO
    Write-Log "Proceed to Task 04: Verify Arc Registration and Connectivity." INFO
} elseif ($failed -gt 0) {
    Write-Log "$failed node(s) failed bootstrap." FAIL
    Write-Log 'Collect diagnostic logs: Invoke-Command -ComputerName <ip> -Credential $cred -ScriptBlock { Collect-ArcBootstrapSupportLogs }' INFO
    Write-Log "Log file: $logFile" INFO
    exit 1
} elseif ($unreachable -gt 0 -or $other -gt 0) {
    $remaining = $unreachable + $other
    Write-Log "$remaining node(s) still in progress or unreachable after $MaxIterations iterations." WARN
    Write-Log "Re-run this script to continue monitoring, or check nodes manually." WARN
}

Write-Log "Log file: $logFile" INFO

#endregion MAIN
