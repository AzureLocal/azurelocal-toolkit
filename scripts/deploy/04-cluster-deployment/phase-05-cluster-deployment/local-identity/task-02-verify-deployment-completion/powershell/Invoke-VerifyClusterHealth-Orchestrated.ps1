<#
.SYNOPSIS
    Invoke-VerifyClusterHealth-Orchestrated.ps1
    Orchestrated cluster health verification for Azure Local deployments.

.DESCRIPTION
    Reads cluster configuration from infrastructure.yml and verifies health
    on all cluster nodes (or specific nodes via -TargetNode). Checks cluster
    state, node state, and storage pool health on each node via PSRemoting.

    Credentials are resolved in priority order:
      1. -Credential parameter
      2. Key Vault reference in infrastructure.yml (keyvault://<vault>/<secret>)
      3. Interactive Get-Credential prompt

.PARAMETER ConfigPath
    Path to infrastructure.yml. Defaults to 'config/infrastructure.yml' relative
    to the working directory.

.PARAMETER Credential
    Override credential for PSRemoting. If omitted, resolved from Key Vault or prompt.

.PARAMETER TargetNode
    Limit verification to specific node(s). Empty = all cluster nodes.

.PARAMETER WhatIf
    Dry-run mode. Resolves config and credentials, shows what would be checked,
    but performs no PSRemoting connections.

.PARAMETER LogPath
    Override log file path. Default: logs/task-03-verify-deployment-completion/<date>_<time>_VerifyClusterHealth.log

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-03-verify-deployment-completion
    Execution:    Run from management server with access to infrastructure.yml

.EXAMPLE
    .\Invoke-VerifyClusterHealth-Orchestrated.ps1 -ConfigPath config/infrastructure.yml
    .\Invoke-VerifyClusterHealth-Orchestrated.ps1 -ConfigPath config/infrastructure.yml -TargetNode iic-01-n01
    .\Invoke-VerifyClusterHealth-Orchestrated.ps1 -ConfigPath config/infrastructure.yml -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath  = "",
    [PSCredential]$Credential,
    [string[]]$TargetNode = @(),
    [switch]$WhatIf,
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region LOGGING
$TaskFolderName = "task-03-verify-deployment-completion"
$ShortName      = "VerifyClusterHealth"

if (-not $LogPath) {
    $LogDir  = Join-Path (Get-Location).Path "logs\$TaskFolderName"
    $LogPath = Join-Path $LogDir ("{0}_{1}_{2}.log" -f (Get-Date -f 'yyyy-MM-dd'), (Get-Date -f 'HHmmss'), $ShortName)
}

if (-not (Test-Path (Split-Path $LogPath -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO')
    $entry = "{0} [{1}] {2}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogPath -Value $entry
    switch ($Level) {
        'WARN'  { Write-Host $entry -ForegroundColor Yellow }
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        default { Write-Host $entry }
    }
}
#endregion LOGGING

#region CONFIG LOADING
# Helpers — dot-source from repo root
. (Join-Path (Get-Location).Path "scripts\common\utilities\helpers\config-loader.ps1")
. (Join-Path (Get-Location).Path "scripts\common\utilities\helpers\keyvault-helper.ps1")

if (-not $ConfigPath) { $ConfigPath = Join-Path (Get-Location).Path "configs\infrastructure.yml" }
Write-Log "Loading configuration from: $ConfigPath"
$cfg = Get-ClusterConfig -ConfigPath $ConfigPath
#endregion CONFIG LOADING

#region RESOLVE NODES
$allNodes = $cfg.compute.cluster_nodes  # compute.cluster_nodes[*]
if ($TargetNode.Count -gt 0) {
    $nodes = @($allNodes | Where-Object { $_.name -in $TargetNode })
    if ($nodes.Count -eq 0) {
        Write-Log "No matching nodes found for: $($TargetNode -join ', ')" -Level ERROR
        exit 1
    }
} else {
    $nodes = @($allNodes)
}
Write-Log "Nodes to verify: $($nodes.name -join ', ')"
#endregion RESOLVE NODES

#region RESOLVE CREDENTIAL
if (-not $Credential) {
    $kvPassword = $cfg.identity.accounts.account_local_admin_password  # identity.accounts.account_local_admin_password
    $username   = $cfg.identity.accounts.account_local_admin_username  # identity.accounts.account_local_admin_username
    if ($kvPassword -match '^keyvault://') {
        Write-Log "Resolving local admin password from Key Vault..."
        $kvName  = $cfg.security.keyvault.kv_azl.kv_azl_name           # security.keyvault.kv_azl.kv_azl_name
        $secret  = Resolve-KeyVaultRef -Uri $kvPassword -VaultName $kvName
        $Credential = New-Object PSCredential($username, (ConvertTo-SecureString $secret -AsPlainText -Force))
    } else {
        Write-Log "Credential not provided and no KV reference found; prompting..." -Level WARN
        $Credential = Get-Credential -Message "Enter local admin credentials for cluster nodes"
    }
}
#endregion RESOLVE CREDENTIAL

#region WHATIF
if ($WhatIf) {
    Write-Log "[WhatIf] Would verify cluster health on: $($nodes | ForEach-Object { $_.management_ip } | Join-String ', ')"
    Write-Log "[WhatIf] Checks: cluster state, node state, storage pool health"
    exit 0
}
#endregion WHATIF

#region MAIN
Write-Log "=== Cluster Health Verification ==="

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$failCount = 0

foreach ($node in $nodes) {
    $ip = $node.management_ip  # compute.cluster_nodes[*].management_ip
    Write-Log "Connecting to $($node.name) ($ip)..."

    try {
        $nodeResult = Invoke-Command -ComputerName $ip -Credential $Credential -ScriptBlock {
            $r = [PSCustomObject]@{
                NodeName    = $env:COMPUTERNAME
                ClusterName = $null
                NodeState   = $null
                AllNodesUp  = $false
                PoolHealthy = $false
                Errors      = @()
            }

            try {
                $cluster = Get-Cluster
                $r.ClusterName = $cluster.Name
            } catch { $r.Errors += "Get-Cluster failed: $_" }

            try {
                $clNodes = @(Get-ClusterNode)
                $r.NodeState  = ($clNodes | Select-Object Name, State | Out-String).Trim()
                $r.AllNodesUp = ($clNodes | Where-Object { $_.State -ne 'Up' }).Count -eq 0
            } catch { $r.Errors += "Get-ClusterNode failed: $_" }

            try {
                $pools = @(Get-StoragePool | Where-Object { -not $_.IsPrimordial })
                $r.PoolHealthy = ($pools.Count -eq 0) -or ($pools | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count -eq 0
            } catch { $r.Errors += "Get-StoragePool failed: $_" }

            $r
        }

        Write-Log "  Cluster   : $($nodeResult.ClusterName)"
        Write-Log "  Nodes Up  : $($nodeResult.AllNodesUp)"
        Write-Log "  Pool OK   : $($nodeResult.PoolHealthy)"
        foreach ($err in $nodeResult.Errors) {
            Write-Log "  $err" -Level WARN
        }
        if (-not $nodeResult.AllNodesUp -or -not $nodeResult.PoolHealthy) {
            $failCount++
        }
        $results.Add($nodeResult)

    } catch {
        Write-Log "Failed to connect to $ip : $_" -Level ERROR
        $failCount++
    }
}

Write-Log "=== Summary: $($nodes.Count) node(s) checked, $failCount warning(s) ==="

if ($failCount -gt 0) {
    Write-Log "Cluster health check completed with warnings — review log: $LogPath" -Level WARN
    exit 1
} else {
    Write-Log "Cluster health check passed on all nodes."
}
#endregion MAIN
