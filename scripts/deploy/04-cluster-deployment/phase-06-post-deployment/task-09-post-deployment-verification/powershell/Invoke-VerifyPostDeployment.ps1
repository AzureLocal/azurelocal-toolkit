#Requires -Version 5.1
<#
.SYNOPSIS
    Orchestrated: verifies all Phase 06 post-deployment tasks against infrastructure.yml.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 08 — Post-Deployment Verification

    Runs read-only checks against the cluster to confirm all Phase 06 tasks completed
    successfully. Checks: Task 01 (WAC), 02 (quorum), 03 (security groups), 04 (SSH),
    05 (storage), 06 (VM images via az CLI), 07 (logical networks via az CLI).

    All checks are idempotent — nothing is created or modified.

.PARAMETER ConfigPath
    Path to infrastructure YAML. Defaults to configs\infrastructure.yml in CWD.

.PARAMETER Credential
    Credential for PSRemoting to cluster nodes. If omitted, resolved via Key Vault
    (Resolve-KeyVaultRef) then interactive Get-Credential prompt.

.PARAMETER TargetNode
    Limit node checks to specific node(s). Empty = all nodes in compute.cluster_nodes.

.PARAMETER WhatIf
    Log all planned checks without executing — validates config before a live run.

.PARAMETER LogPath
    Override log file path. Default: logs\task-08-post-deployment-verification\
    <YYYY-MM-DD_HHmmss>_VerifyPostDeployment.log (relative to CWD).

.PARAMETER WacServer
    FQDN or IP of the Windows Admin Center server. Override at the command line or set
    management.wac.server_fqdn in infrastructure.yml. If empty, WAC checks are skipped.

.PARAMETER ClusterName
    Override cluster name. Defaults to compute.azure_local.cluster_name from YAML.

.EXAMPLE
    # Run from repo root with default config:
    .\scripts\deploy\04-cluster-deployment\phase-06-post-deployment\task-08-post-deployment-verification\powershell\Invoke-VerifyPostDeployment.ps1

.EXAMPLE
    # Dry-run (logs planned checks, no execution):
    .\...\Invoke-VerifyPostDeployment.ps1 -WhatIf

.EXAMPLE
    # Pass WAC server explicitly:
    .\...\Invoke-VerifyPostDeployment.ps1 -WacServer "wac.contoso.cloud"

.EXAMPLE
    # Limit to one node:
    .\...\Invoke-VerifyPostDeployment.ps1 -TargetNode iic-01-n01

.NOTES
    Requires: powershell-yaml module  (Install-Module powershell-yaml -Scope CurrentUser)
    Requires: FailoverClusters module on management server
    Requires: az CLI authenticated    (az login) for Tasks 06-07
    Read-only: no changes are made to cluster or Azure resources.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]      $ConfigPath  = "",
    [PSCredential]$Credential,
    [string[]]    $TargetNode  = @(),
    [switch]      $WhatIf,
    [string]      $LogPath     = "",

    # YAML-overridable
    [string]      $WacServer   = "",   # management.wac.server_fqdn — leave empty to skip WAC check
    [string]      $ClusterName = ""    # compute.azure_local.cluster_name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region LOGGING -----------------------------------------------------------------
$taskFolderName = "task-08-post-deployment-verification"
$timestamp      = Get-Date -Format "yyyy-MM-dd_HHmmss"

if ([string]::IsNullOrEmpty($LogPath)) {
    $logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
    $LogPath = Join-Path $logDir "${timestamp}_VerifyPostDeployment.log"
}

$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[{0}] [{1,-5}] {2}" -f $ts, $Level, $Message
    $entry | Out-File -FilePath $LogPath -Append -Encoding utf8
    $color = switch ($Level) {
        "FAIL"  { "Red"    }
        "WARN"  { "Yellow" }
        "PASS"  { "Green"  }
        default { "Cyan"   }
    }
    Write-Host $entry -ForegroundColor $color
}

Write-Log "======================================================="
Write-Log " Task 08 — Post-Deployment Verification (Orchestrated)"
Write-Log " Log: $LogPath"
if ($WhatIf) { Write-Log " [WhatIf] Dry-run mode — no checks will be executed" "WARN" }
Write-Log "======================================================="
#endregion

#region CONFIG LOADING ----------------------------------------------------------
if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path (Get-Location).Path "configs\infrastructure.yml"
}
if (-not (Test-Path $ConfigPath)) {
    Write-Log "Config not found: $ConfigPath" "FAIL"; throw "Config not found"
}

Write-Log "Loading config: $ConfigPath"
Import-Module powershell-yaml -ErrorAction Stop
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

# Cluster name — YAML-overridable
if ([string]::IsNullOrEmpty($ClusterName)) {
    $ClusterName = $cfg.compute.azure_local.cluster_name              # compute.azure_local.cluster_name
}
if ([string]::IsNullOrEmpty($ClusterName)) { throw "Cannot resolve cluster_name from config or -ClusterName" }

# WAC server — YAML-overridable, optional (empty = skip WAC check)
if ([string]::IsNullOrEmpty($WacServer) -and $cfg.management.wac.server_fqdn) {
    $WacServer = $cfg.management.wac.server_fqdn                      # management.wac.server_fqdn
}

# Cluster nodes: objects with Hostname (display) and Ip (PSRemoting connection target)
$allNodes = @()
if ($cfg.compute.cluster_nodes) {
    $allNodes = @($cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{ Hostname = $_.Value.hostname; Ip = $_.Value.management_ip }  # compute.cluster_nodes.<key>.hostname / management_ip
    })
}
$nodesToCheck = if ($TargetNode.Count -gt 0) {
    @($allNodes | Where-Object { $_.Hostname -in $TargetNode -or $_.Ip -in $TargetNode })
} elseif ($allNodes.Count -gt 0) { $allNodes } else { @() }

# Subscription / resource group for Azure CLI checks
$subscriptionId = $null
if ($cfg.azure_platform.subscriptions) {
    $subKey         = ($cfg.azure_platform.subscriptions.GetEnumerator() | Select-Object -First 1).Key
    $subscriptionId = $cfg.azure_platform.subscriptions.$subKey.id    # azure_platform.subscriptions.<key>.id
}
$resourceGroup = if ($cfg.azure_platform.resource_group_name) {
                     $cfg.azure_platform.resource_group_name          # azure_platform.resource_group_name
                 } elseif ($cfg.compute.azure_local.arc_resource_group) {
                     $cfg.compute.azure_local.arc_resource_group      # compute.azure_local.arc_resource_group
                 } else { $null }

# Expected counts for pass/fail comparison
$logicalNetworks = if ($cfg.networking.logical_networks) { $cfg.networking.logical_networks } else { @() }  # networking.logical_networks[]
$marketplace     = if ($cfg.marketplace_images.images)   { $cfg.marketplace_images.images }   else { @() }  # marketplace_images.images[]

Write-Log "Cluster:     $ClusterName"
Write-Log "WAC server:  $(if ($WacServer) { $WacServer } else { '(skipped — not configured)' })"
Write-Log "Nodes:       $(($nodesToCheck | ForEach-Object { "$($_.Hostname)($($_.Ip))" }) -join ', ')"
Write-Log "Config:      $ConfigPath"
#endregion

#region CREDENTIAL RESOLUTION ---------------------------------------------------
function Resolve-KeyVaultRef {
    param([string]$KvUri)
    if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') { Write-Log "  Not a Key Vault URI: $KvUri" "WARN"; return $null }
    $vaultName  = $Matches[1]
    $secretName = $Matches[2]

    if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            Write-Log "  Retrieving '$secretName' from '$vaultName' (Az.KeyVault)..."
            $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
            if ($secret) { Write-Log "  Secret retrieved." "PASS"; return $secret }
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
        Write-Log "  Secret retrieved (az CLI)." "PASS"
        return $val
    } catch { Write-Log "  az CLI failed: $_" "WARN"; return $null }
}

if (-not $Credential) {
    # Post-deployment: nodes are domain-joined and local admin is renamed by Azure Local.
    # Use the LCM domain account for PSRemoting.
    $lcmUser       = $cfg.identity.accounts.account_lcm_username         # identity.accounts.account_lcm_username
    $lcmPassUri    = $cfg.identity.accounts.account_lcm_password          # identity.accounts.account_lcm_password
    $domainNetbios = $cfg.identity.active_directory.ad_netbios_name       # identity.active_directory.ad_netbios_name
    $lcmFqUser     = if ($domainNetbios) { "$domainNetbios\$lcmUser" } else { $lcmUser }
    Write-Log "Resolving LCM credentials from Key Vault..."
    $lcmPass = Resolve-KeyVaultRef -KvUri $lcmPassUri
    if ($lcmPass) {
        $Credential = New-Object PSCredential($lcmFqUser, (ConvertTo-SecureString $lcmPass -AsPlainText -Force))
        Write-Log "Credentials resolved for '$lcmFqUser'." "PASS"
    } else {
        Write-Log "Key Vault unavailable — prompting for credentials." "WARN"
        $Credential = Get-Credential -Message "Enter LCM account credentials for cluster nodes" -UserName $lcmFqUser
    }
}

$credParam = if ($Credential) { @{ Credential = $Credential } } else { @{} }
#endregion

#region VERIFICATION ------------------------------------------------------------
$passCount = 0; $failCount = 0; $skipCount = 0

function Write-Check {
    param([bool]$Pass, [string]$Check, [string]$Detail = "")
    $level = if ($Pass) { "PASS" } else { "FAIL" }
    Write-Log "  [$level] $Check$(if ($Detail) { " — $Detail" })" $level
    if ($Pass) { $script:passCount++ } else { $script:failCount++ }
}

function Write-Skip {
    param([string]$Check, [string]$Reason = "")
    Write-Log "  [SKIP] $Check$(if ($Reason) { " — $Reason" })" "WARN"
    $script:skipCount++
}

# ── Task 01: Windows Admin Center ───────────────────────────────────────────
Write-Log ""; Write-Log "Task 01 — Windows Admin Center"
if ([string]::IsNullOrEmpty($WacServer)) {
    Write-Skip "WAC checks" "WacServer not configured — pass -WacServer or set management.wac.server_fqdn"
} elseif ($WhatIf) {
    Write-Log "  [WhatIf] Would test WAC port 443 and gateway service on $WacServer" "WARN"
} else {
    $wacPort = Test-NetConnection -ComputerName $WacServer -Port 443 -WarningAction SilentlyContinue
    Write-Check -Pass $wacPort.TcpTestSucceeded -Check "WAC port 443 reachable" -Detail $WacServer
    try {
        $wacSvc = Invoke-Command -ComputerName $WacServer @credParam -ScriptBlock {
            Get-Service ServerManagementGateway -ErrorAction SilentlyContinue
        }
        Write-Check -Pass ($wacSvc.Status -eq "Running") -Check "WAC gateway service" -Detail $wacSvc.Status
    } catch { Write-Log "  [FAIL] WAC gateway check failed: $_" "FAIL"; $failCount++ }
}

# ── Task 02: Cluster Quorum ──────────────────────────────────────────────────
Write-Log ""; Write-Log "Task 02 — Cluster Quorum"
if ($WhatIf) {
    Write-Log "  [WhatIf] Would query cluster quorum on $ClusterName" "WARN"
} else {
    try {
        $quorum      = Get-ClusterQuorum -Cluster $ClusterName -ErrorAction Stop
        $quorumState = (Get-Cluster -Name $ClusterName).QuorumState
        Write-Check -Pass ($null -ne $quorum.QuorumType) -Check "Quorum type configured"  -Detail $quorum.QuorumType
        Write-Check -Pass ($quorumState -eq "Normal")    -Check "Quorum state Normal"     -Detail $quorumState
    } catch { Write-Log "  [FAIL] Cluster quorum query failed: $_" "FAIL"; $failCount++ }
}

# ── Task 03: Security Groups ─────────────────────────────────────────────────
Write-Log ""; Write-Log "Task 03 — Security Groups"
foreach ($node in $nodesToCheck) {
    if ($WhatIf) { Write-Log "  [WhatIf] Would check local group membership on $($node.Hostname) ($($node.Ip))" "WARN"; continue }
    try {
        $groups = Invoke-Command -ComputerName $node.Ip @credParam -ErrorAction Stop -ScriptBlock {
            @{
                AdminGroups = (Get-LocalGroupMember -Group "Administrators"          | Where-Object ObjectClass -eq "Group").Count
                RmGroups    = (Get-LocalGroupMember -Group "Remote Management Users" | Where-Object ObjectClass -eq "Group").Count
            }
        }
        Write-Check -Pass ($groups.AdminGroups -gt 0) -Check "$($node.Hostname) — Administrators AD group(s)"          -Detail "$($groups.AdminGroups)"
        Write-Check -Pass ($groups.RmGroups    -gt 0) -Check "$($node.Hostname) — Remote Management Users AD group(s)" -Detail "$($groups.RmGroups)"
    } catch { Write-Log "  [FAIL] $($node.Hostname) — group check failed: $_" "FAIL"; $failCount++ }
}

# ── Task 04: SSH Connectivity ────────────────────────────────────────────────
Write-Log ""; Write-Log "Task 04 — SSH Connectivity"
foreach ($node in $nodesToCheck) {
    if ($WhatIf) { Write-Log "  [WhatIf] Would check sshd service and port 22 on $($node.Hostname) ($($node.Ip))" "WARN"; continue }
    try {
        $sshSvc = Invoke-Command -ComputerName $node.Ip @credParam -ErrorAction Stop -ScriptBlock {
            Get-Service sshd -ErrorAction SilentlyContinue
        }
        Write-Check -Pass ($sshSvc.Status -eq "Running") -Check "$($node.Hostname) — sshd service" -Detail $sshSvc.Status
    } catch { Write-Log "  [FAIL] $($node.Hostname) — sshd check failed: $_" "FAIL"; $failCount++ }
    $sshPort = Test-NetConnection -ComputerName $node.Ip -Port 22 -WarningAction SilentlyContinue
    Write-Check -Pass $sshPort.TcpTestSucceeded -Check "$($node.Hostname) — port 22 reachable"
}

# ── Task 05: Storage ─────────────────────────────────────────────────────────
Write-Log ""; Write-Log "Task 05 — Storage"
if ($WhatIf) {
    Write-Log "  [WhatIf] Would query storage pool and CSV volumes on $ClusterName" "WARN"
} else {
    try {
        $pool = Get-StoragePool -CimSession $ClusterName | Where-Object IsPrimordial -eq $false
        if ($pool) {
            Write-Check -Pass ($pool.HealthStatus -eq "Healthy") -Check "Storage pool health" -Detail $pool.HealthStatus
        } else {
            Write-Log "  [FAIL] No storage pool found on $ClusterName" "FAIL"; $failCount++
        }
        $csvVolumes = Get-ClusterSharedVolume -Cluster $ClusterName
        Write-Check -Pass ($csvVolumes.Count -gt 0) -Check "CSV volumes mounted" -Detail "$($csvVolumes.Count) volume(s)"
        foreach ($csv in $csvVolumes) {
            Write-Check -Pass ($csv.State -eq "Online") -Check "  $($csv.Name)" -Detail $csv.State
        }
    } catch { Write-Log "  [FAIL] Storage check failed: $_" "FAIL"; $failCount++ }
}

# ── Task 06: VM Images (Azure) ───────────────────────────────────────────────
Write-Log ""; Write-Log "Task 06 — VM Images (Azure)"
if (-not $subscriptionId -or -not $resourceGroup) {
    Write-Skip "VM images" "Cannot resolve subscription/resource group — verify manually in Azure Portal"
} elseif ($WhatIf) {
    Write-Log "  [WhatIf] Would run: az stack-hci-vm image list --resource-group $resourceGroup" "WARN"
} else {
    $imagesJson = az stack-hci-vm image list --subscription $subscriptionId --resource-group $resourceGroup --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $imagesJson) {
        $images    = $imagesJson | ConvertFrom-Json
        $succeeded = @($images | Where-Object { $_.provisioningState -eq "Succeeded" })
        Write-Check -Pass ($images.Count -gt 0) -Check "VM images in $resourceGroup" -Detail "$($images.Count) found"
        if ($marketplace.Count -gt 0) {
            Write-Check -Pass ($succeeded.Count -ge $marketplace.Count) -Check "All expected images Succeeded" -Detail "$($succeeded.Count)/$($marketplace.Count)"
        }
    } else { Write-Log "  [FAIL] Could not query VM images — check az CLI auth" "FAIL"; $failCount++ }
}

# ── Task 07: Logical Networks (Azure) ────────────────────────────────────────
Write-Log ""; Write-Log "Task 07 — Logical Networks (Azure)"
if (-not $subscriptionId -or -not $resourceGroup) {
    Write-Skip "Logical networks" "Cannot resolve subscription/resource group — verify manually in Azure Portal"
} elseif ($WhatIf) {
    Write-Log "  [WhatIf] Would run: az stack-hci-vm network lnet list --resource-group $resourceGroup" "WARN"
} else {
    $lnetsJson = az stack-hci-vm network lnet list --subscription $subscriptionId --resource-group $resourceGroup --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $lnetsJson) {
        $lnets     = $lnetsJson | ConvertFrom-Json
        $succeeded = @($lnets | Where-Object { $_.provisioningState -eq "Succeeded" })
        Write-Check -Pass ($lnets.Count -gt 0) -Check "Logical networks in $resourceGroup" -Detail "$($lnets.Count) found"
        if ($logicalNetworks.Count -gt 0) {
            Write-Check -Pass ($succeeded.Count -ge $logicalNetworks.Count) -Check "All expected networks Succeeded" -Detail "$($succeeded.Count)/$($logicalNetworks.Count)"
        }
    } else { Write-Log "  [FAIL] Could not query logical networks — check az CLI auth" "FAIL"; $failCount++ }
}
#endregion

#region SUMMARY -----------------------------------------------------------------
Write-Log ""
Write-Log "======================================================="
Write-Log " Summary"
Write-Log "   Passed  : $passCount"
Write-Log "   Failed  : $failCount"
Write-Log "   Skipped : $skipCount"
Write-Log " Log: $LogPath"
Write-Log "======================================================="

if ($WhatIf) { Write-Log "Dry-run complete. Re-run without -WhatIf to execute checks." "WARN" }
if ($failCount -gt 0) { throw "$failCount check(s) failed. Review log: $LogPath" }
#endregion
