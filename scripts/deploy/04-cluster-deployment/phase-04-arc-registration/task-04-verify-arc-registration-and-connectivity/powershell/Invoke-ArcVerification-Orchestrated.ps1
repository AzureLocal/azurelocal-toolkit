#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-ArcVerification-Orchestrated.ps1
    Verifies Arc registration and connectivity across all cluster nodes.

.DESCRIPTION
    Connects to each node via PSRemoting (in parallel) and runs read-only checks for:
      Check 1 — himds (Arc agent) service is Running
      Check 2 — azcmagent show reports Agent Status = Connected
      Check 3 — azcmagent check confirms all endpoints reachable
      Check 4 — Arc Gateway configured (if enabled in infrastructure.yml)

    Optionally verifies Azure-side resource status using Get-AzConnectedMachine
    (requires Azure authentication via SPN or existing Az context).

    Configuration values are read from infrastructure.yml. Azure parameters can be
    overridden via command-line parameters.

.PARAMETER ConfigPath
    Path to infrastructure.yml. Defaults to auto-detect from script location.

.PARAMETER Credential
    PSCredential for PSRemoting. If omitted, resolved from Key Vault, then interactive prompt.

.PARAMETER TargetNode
    One or more node hostnames or IPs. Defaults to all nodes in config.

.PARAMETER WhatIf
    Dry-run mode — shows what would be verified without connecting.

.PARAMETER LogPath
    Override log file path. Default: ./logs/<task-folder>/<timestamp>_ArcVerification.log

.PARAMETER SubscriptionId
    Override subscription for Azure-side check. YAML path: azure_platform.subscriptions.lab.id

.PARAMETER ResourceGroup
    Override resource group for Azure-side check. YAML path: compute.azure_local.arc_resource_group

.PARAMETER SkipAzureCheck
    Skip Azure-side verification (only run local agent checks on nodes).

.EXAMPLE
    .\Invoke-ArcVerification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml

.EXAMPLE
    .\Invoke-ArcVerification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -WhatIf

.EXAMPLE
    .\Invoke-ArcVerification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -SkipAzureCheck

.EXAMPLE
    .\Invoke-ArcVerification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -TargetNode azl-lab-01-n02

.NOTES
    Author:  Azure Local Cloud AzureLocalCloud
    Phase:   04-arc-registration
    Task:    04 - Verify Arc Registration and Connectivity
    Mode:    Read-only. No changes are made to any node.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [string[]]$TargetNode = @(),

    [switch]$WhatIf,

    [string]$LogPath = "",

    # YAML-overridable Azure parameters (for Azure-side check)
    [string]$SubscriptionId = "",        # azure_platform.subscriptions.lab.id
    [string]$ResourceGroup  = "",        # compute.azure_local.arc_resource_group

    [switch]$SkipAzureCheck              # Skip Get-AzConnectedMachine check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Log file initialization ───────────────────────────────────────────────
# Scripts are always run from the repo root, so ./logs/<task-folder>/ is CWD-relative
$scriptShortName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -replace '^Invoke-|-Orchestrated$', ''
$taskFolderName  = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf   # e.g. task-04-verify-arc-registration-and-connectivity
$logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
if ($LogPath -ne "") {
    $logDir  = Split-Path $LogPath -Parent
    $logFile = $LogPath
} else {
    $logFile = Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd_HHmmss')_${scriptShortName}.log"
}
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

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

    $az = $cfg.compute.azure_local                                   # compute.azure_local

    return [PSCustomObject]@{
        Nodes            = @($nodes)
        SubscriptionId   = $cfg.azure_platform.subscriptions.lab.id  # azure_platform.subscriptions.lab.id
        ResourceGroup    = $az.arc_resource_group                    # compute.azure_local.arc_resource_group
        ArcGatewayEnabled = [bool]$az.arc_gateway_enabled            # compute.azure_local.arc_gateway_enabled
        ArcGatewayId     = $az.arc_gateway_id                        # compute.azure_local.arc_gateway_id
        AdminUser        = $cfg.identity.accounts.account_local_admin_username   # identity.accounts.account_local_admin_username
        AdminPassUri     = $cfg.identity.accounts.account_local_admin_password   # identity.accounts.account_local_admin_password
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

#region VERIFICATION SCRIPTBLOCK

$VerifyScript = {
    param(
        [bool]$ExpectGateway
    )

    $checks = [ordered]@{}

    # ── Check 1: himds (Arc agent) service ────────────────────────────────────
    $svc = Get-Service himds -ErrorAction SilentlyContinue
    $checks['ArcAgent_Service'] = if ($svc -and $svc.Status -eq 'Running') {
        "PASS (himds=Running, StartType=$($svc.StartType))"
    } elseif ($svc) {
        "FAIL: himds=$($svc.Status)"
    } else {
        "FAIL: himds service not found — Arc agent may not be installed"
    }

    # ── Check 2: azcmagent show → Agent Status ───────────────────────────────
    $agentExe = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    if (Test-Path $agentExe) {
        $showOutput  = (& $agentExe show 2>&1) | Out-String
        $statusMatch = [regex]::Match($showOutput, 'Agent Status\s*:\s*(.+)')
        $agentStatus = if ($statusMatch.Success) { $statusMatch.Groups[1].Value.Trim() } else { "Unknown" }

        $checks['ArcAgent_Status'] = if ($agentStatus -eq 'Connected') {
            "PASS (AgentStatus=Connected)"
        } else {
            "FAIL: AgentStatus=$agentStatus"
        }

        # Extract additional info for logging
        $versionMatch = [regex]::Match($showOutput, 'Agent Version\s*:\s*(.+)')
        $agentVersion = if ($versionMatch.Success) { $versionMatch.Groups[1].Value.Trim() } else { "Unknown" }

        # ── Check 3: azcmagent check → endpoint connectivity ─────────────────
        $checkOutput = (& $agentExe check 2>&1) | Out-String
        # Count lines with "Unreachable" or similar failure indicators
        $unreachableCount = ([regex]::Matches($checkOutput, '(?mi)Unreachable|Not Reachable|Failed')).Count

        $checks['ArcAgent_Endpoints'] = if ($unreachableCount -eq 0) {
            "PASS (All endpoints reachable, Agent v$agentVersion)"
        } else {
            "FAIL: $unreachableCount endpoint(s) unreachable"
        }

        # ── Check 4: Arc Gateway (if enabled) ────────────────────────────────
        if ($ExpectGateway) {
            $gwMatch  = [regex]::Match($showOutput, 'Gateway URL\s*:\s*(.+)')
            $gwUrl    = if ($gwMatch.Success) { $gwMatch.Groups[1].Value.Trim() } else { "" }

            $checks['ArcGateway'] = if ($gwUrl -match 'https://') {
                "PASS (Arc Gateway URL=$gwUrl)"
            } elseif ($gwUrl -ne "") {
                "WARN: Unexpected Arc Gateway URL=$gwUrl"
            } else {
                "WARN: Arc Gateway URL not found in azcmagent show"
            }
        }
    } else {
        $checks['ArcAgent_Status']    = "FAIL: azcmagent.exe not found at $agentExe"
        $checks['ArcAgent_Endpoints'] = "FAIL: Skipped (agent not installed)"
        if ($ExpectGateway) {
            $checks['ArcGateway'] = "FAIL: Skipped (agent not installed)"
        }
    }

    return $checks
}

#endregion VERIFICATION SCRIPTBLOCK

#region MAIN

Write-Log "================================================================" HEADER
Write-Log "   Phase 04 Arc Registration — Task 04: Verify Registration" HEADER
Write-Log "================================================================" HEADER
Write-Log "" INFO
Write-Log "  Checks  : himds service, Agent Status, Endpoint connectivity," INFO
Write-Log "            Arc Gateway (if enabled), Azure resource status" INFO
Write-Log "  Mode    : Read-only. No changes are made to any node." INFO
Write-Log "  Log     : $logFile" INFO
Write-Log "" INFO

# ── Load config ──────────────────────────────────────────────────────────────
Write-Log "Config : $ConfigPath" INFO
Write-Log "--- Loading configuration ---" HEADER

$cfg = Get-Config -Path $ConfigPath

# ── Apply overrides ───────────────────────────────────────────────────────────
if ($SubscriptionId -ne "") { $cfg.SubscriptionId = $SubscriptionId; Write-Log "  Override: SubscriptionId=$SubscriptionId" WARN }
if ($ResourceGroup  -ne "") { $cfg.ResourceGroup  = $ResourceGroup;  Write-Log "  Override: ResourceGroup=$ResourceGroup" WARN }

Write-Log "  Subscription   : $($cfg.SubscriptionId)" INFO
Write-Log "  Resource Group : $($cfg.ResourceGroup)" INFO
Write-Log "  Arc Gateway    : $(if ($cfg.ArcGatewayEnabled) { 'Enabled' } else { 'Disabled' })" INFO
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
    Write-Log "Would verify $($nodes.Count) node(s):" INFO
    Write-Log "" INFO

    foreach ($n in $nodes) {
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        Write-Log "  NODE: $($n.hostname)  ($($n.ip))" HEADER
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        Write-Log "  WHATIF: Check 1 — himds Service    : Would verify himds service is Running" INFO
        Write-Log "  WHATIF: Check 2 — Agent Status     : Would verify azcmagent show → Connected" INFO
        Write-Log "  WHATIF: Check 3 — Endpoints        : Would verify azcmagent check → all reachable" INFO
        if ($cfg.ArcGatewayEnabled) {
            Write-Log "  WHATIF: Check 4 — Arc Gateway      : Would verify Arc Gateway routing is active" INFO
        }
        Write-Log "" INFO
    }

    if (-not $SkipAzureCheck) {
        Write-Log "Would also verify Azure-side status:" INFO
        Write-Log "  Get-AzConnectedMachine -ResourceGroupName $($cfg.ResourceGroup)" INFO
        Write-Log "  Expect all nodes Status=Connected" INFO
    } else {
        Write-Log "Azure-side check: SKIPPED (-SkipAzureCheck)" INFO
    }

    Write-Log "" INFO
    Write-Log "Connection method : Invoke-Command -ComputerName <ip> -Credential $($cfg.AdminUser) -AsJob" INFO
    Write-Log "Job timeout       : 120 seconds per node" INFO
    Write-Log "" INFO
    Write-Log "Re-run without -WhatIf to execute." INFO
    Write-Log "Log file: $logFile" INFO
    exit 0
}

Write-Log "" INFO
Write-Log "Ready. Verifying $($nodes.Count) node(s) in parallel..." HEADER
Write-Log "================================================================" HEADER

# ── Launch parallel verification jobs ──────────────────────────────────────
$jobTimeout = 120   # seconds
$jobs       = [ordered]@{}
$summary    = @()

Write-Log "Launching verification jobs in parallel..." HEADER
foreach ($node in $nodes) {
    try {
        $job = Invoke-Command `
            -ComputerName $node.ip `
            -Credential $Credential `
            -ScriptBlock $VerifyScript `
            -ArgumentList $cfg.ArcGatewayEnabled `
            -AsJob `
            -JobName "ArcVerify-$($node.hostname)" `
            -ErrorAction Stop
        $jobs[$node.hostname] = @{ Job = $job; Node = $node; Error = $null }
        Write-Log "  [$($node.hostname)] Job submitted ($($node.ip))" INFO
    } catch {
        $errMsg = $_.Exception.Message -replace '^.*\] ', ''
        $jobs[$node.hostname] = @{ Job = $null; Node = $node; Error = $errMsg }
        Write-Log "  [$($node.hostname)] Failed to submit: $errMsg" FAIL
    }
}

# ── Wait for all jobs ─────────────────────────────────────────────────────
$activeJobs = @($jobs.Values | Where-Object { $_.Job } | ForEach-Object { $_.Job })
if ($activeJobs.Count -gt 0) {
    Write-Log "Waiting for $($activeJobs.Count) job(s) to complete (timeout=${jobTimeout}s)..." INFO
    $null = $activeJobs | Wait-Job -Timeout $jobTimeout
}

# ── Collect and display results per node ──────────────────────────────────
Write-Log "" INFO
foreach ($entry in $jobs.GetEnumerator()) {
    $nodeName = $entry.Key
    $node     = $entry.Value.Node
    $job      = $entry.Value.Job
    $jobError = $entry.Value.Error

    Write-Log "================================================================" HEADER
    Write-Log "  NODE: $nodeName  ($($node.ip))" HEADER
    Write-Log "================================================================" HEADER

    $nodeChecksPassed = 0
    $nodeChecksFailed = 0
    $nodeChecksWarned = 0
    $nodeError        = $jobError
    $rawChecks        = $null

    if ($job) {
        if ($job.State -eq 'Running') {
            $job | Stop-Job -ErrorAction SilentlyContinue
            $nodeError = "Job timed out after ${jobTimeout}s"
            Write-Log "[$nodeName] $nodeError" FAIL
        } elseif ($job.State -eq 'Failed') {
            $nodeError = ($job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason.Message }) -join '; '
            if (-not $nodeError) { $nodeError = "Remote job failed (unknown reason)" }
            Write-Log "[$nodeName] Job failed: $nodeError" FAIL
        } else {
            try {
                $rawChecks = Receive-Job -Job $job -ErrorAction Stop
            } catch {
                $nodeError = $_.Exception.Message -replace '^.*\] ', ''
                Write-Log "[$nodeName] Error receiving results: $nodeError" FAIL
            }
        }
    } elseif (-not $nodeError) {
        $nodeError = "No job was created"
        Write-Log "[$nodeName] $nodeError" FAIL
    } else {
        Write-Log "[$nodeName] Connection failed: $nodeError" FAIL
    }

    if ($rawChecks) {
        foreach ($key in $rawChecks.Keys) {
            $val    = "$($rawChecks[$key])"
            $isPASS = $val -match '^PASS'
            $isWARN = $val -match '^WARN'

            $label = $key.PadRight(22)
            if ($isPASS) {
                Write-Host "  [PASS] $label  $val" -ForegroundColor Green
                "  [PASS] $label  $val" | Out-File -FilePath $logFile -Append -Encoding utf8
                $nodeChecksPassed++
            } elseif ($isWARN) {
                Write-Host "  [WARN] $label  $val" -ForegroundColor Yellow
                "  [WARN] $label  $val" | Out-File -FilePath $logFile -Append -Encoding utf8
                $nodeChecksWarned++
            } else {
                Write-Host "  [FAIL] $label  $val" -ForegroundColor Red
                "  [FAIL] $label  $val" | Out-File -FilePath $logFile -Append -Encoding utf8
                $nodeChecksFailed++
            }
        }
    }

    $total  = $nodeChecksPassed + $nodeChecksFailed + $nodeChecksWarned
    $status = if ($nodeError) { "Error" }
              elseif ($nodeChecksFailed -gt 0) { "Failed ($nodeChecksFailed/$total)" }
              elseif ($nodeChecksWarned -gt 0) { "Warnings ($nodeChecksWarned/$total)" }
              else { "All PASS ($nodeChecksPassed/$total)" }

    Write-Log "[$nodeName] $status" $(if ($nodeError -or $nodeChecksFailed -gt 0) { 'FAIL' } elseif ($nodeChecksWarned) { 'WARN' } else { 'PASS' })

    $summary += [PSCustomObject]@{
        Node     = $nodeName
        IP       = $node.ip
        Passed   = $nodeChecksPassed
        Warned   = $nodeChecksWarned
        Failed   = $nodeChecksFailed
        Status   = $status
        Error    = $nodeError
    }
}

# ── Cleanup jobs ──────────────────────────────────────────────────────────
$activeJobs | Remove-Job -Force -ErrorAction SilentlyContinue

# ── Azure-side verification (optional) ────────────────────────────────────
if (-not $SkipAzureCheck) {
    Write-Log "" INFO
    Write-Log "================================================================" HEADER
    Write-Log "  AZURE RESOURCE STATUS" HEADER
    Write-Log "================================================================" HEADER

    try {
        # Try existing Az context first; if not authenticated, try to authenticate
        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            Write-Log "No active Az session. Run Connect-AzAccount first, or use -SkipAzureCheck." WARN
        } else {
            # Ensure correct subscription
            if ($azContext.Subscription.Id -ne $cfg.SubscriptionId) {
                Set-AzContext -SubscriptionId $cfg.SubscriptionId | Out-Null
            }

            $machines = Get-AzConnectedMachine -ResourceGroupName $cfg.ResourceGroup -ErrorAction Stop
            foreach ($m in $machines) {
                $level = if ($m.Status -eq 'Connected') { 'PASS' } else { 'FAIL' }
                Write-Log "  [$($m.Name)] Azure Status=$($m.Status), Agent=$($m.AgentVersion), LastSeen=$($m.LastStatusChange)" $level
            }

            # Check for missing nodes
            $registeredNames = @($machines | ForEach-Object { $_.Name.ToUpper() })
            foreach ($node in $nodes) {
                if ($node.hostname.ToUpper() -notin $registeredNames) {
                    Write-Log "  [$($node.hostname)] NOT FOUND in Azure Arc resources" FAIL
                }
            }
        }
    } catch {
        Write-Log "Azure resource check failed: $($_.Exception.Message)" WARN
        Write-Log "This is non-critical — local agent checks above are authoritative." INFO
        Write-Log "To enable Azure check: Connect-AzAccount -SubscriptionId $($cfg.SubscriptionId)" INFO
    }
} else {
    Write-Log "" INFO
    Write-Log "Azure-side check: SKIPPED (-SkipAzureCheck)" INFO
}

# ── Summary table ──────────────────────────────────────────────────────────
Write-Log "" INFO
Write-Log "================================================================" HEADER
Write-Log "  SUMMARY" HEADER
Write-Log "================================================================" HEADER

$tableStr = ($summary | Format-Table Node, IP, Passed, Warned, Failed, Status -AutoSize | Out-String).Trim()
Write-Host $tableStr
$tableStr | Out-File -FilePath $logFile -Append -Encoding utf8

$totalFailed = @($summary | Where-Object { $_.Failed -gt 0 -or $_.Error }).Count

if ($totalFailed -eq 0 -and @($summary | Where-Object { $_.Warned -gt 0 }).Count -eq 0) {
    Write-Log "All $($nodes.Count) node(s) passed Arc verification." PASS
} elseif ($totalFailed -eq 0) {
    Write-Log "All $($nodes.Count) node(s) passed with warnings. Review WARNs above." WARN
} else {
    Write-Log "$totalFailed node(s) had failures. Review output above." FAIL
    Write-Log "Log file: $logFile" INFO
    exit 1
}

Write-Log "" INFO
Write-Log "Phase 04 Arc Registration is complete. Phase 05 Cluster Deployment may now proceed." INFO
Write-Log "Log file: $logFile" INFO

#endregion MAIN
