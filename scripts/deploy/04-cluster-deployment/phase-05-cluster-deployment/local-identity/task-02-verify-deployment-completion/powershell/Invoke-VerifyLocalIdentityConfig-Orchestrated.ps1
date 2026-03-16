<#
.SYNOPSIS
    Invoke-VerifyLocalIdentityConfig-Orchestrated.ps1
    Orchestrated Local Identity configuration verification for Azure Local deployments.

.DESCRIPTION
    Reads cluster configuration from infrastructure.yml and verifies Local Identity
    state on all cluster nodes (or specific nodes via -TargetNode) via PSRemoting.

    Verifies per node:
      1. Node Domain = WORKGROUP (not domain-joined)
      2. Cluster ADAware parameter = 2 (AD-less / Local Identity mode)

    Credentials are resolved in priority order:
      1. -Credential parameter
      2. Key Vault reference in infrastructure.yml (keyvault://<vault>/<secret>)
      3. Interactive Get-Credential prompt

    Source: https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault

.PARAMETER ConfigPath
    Path to infrastructure.yml. Defaults to 'configs/infrastructure.yml' relative
    to the working directory.

.PARAMETER Credential
    Override credential for PSRemoting. If omitted, resolved from Key Vault or prompt.

.PARAMETER TargetNode
    Limit verification to specific node(s). Empty = all cluster nodes.

.PARAMETER WhatIf
    Dry-run mode. Resolves config and credentials, shows what would be checked,
    but performs no PSRemoting connections.

.PARAMETER LogPath
    Override log file path. Default: logs/task-03-verify-deployment-completion/<date>_<time>_VerifyLocalIdentityConfig.log

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-03-verify-deployment-completion
    Execution:    Run from management server with access to infrastructure.yml

.EXAMPLE
    .\Invoke-VerifyLocalIdentityConfig-Orchestrated.ps1 -ConfigPath configs/infrastructure.yml
    .\Invoke-VerifyLocalIdentityConfig-Orchestrated.ps1 -ConfigPath configs/infrastructure.yml -TargetNode iic-01-n01,iic-01-n02
    .\Invoke-VerifyLocalIdentityConfig-Orchestrated.ps1 -ConfigPath configs/infrastructure.yml -WhatIf
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
$ShortName      = "VerifyLocalIdentityConfig"

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
    Write-Log "[WhatIf] Would verify Local Identity config on: $($nodes | ForEach-Object { $_.management_ip } | Join-String ', ')"
    Write-Log "[WhatIf] Checks: Domain = WORKGROUP, ADAware = 2"
    exit 0
}
#endregion WHATIF

#region MAIN
Write-Log "=== Local Identity Configuration Verification ==="

$failCount = 0
$results   = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($node in $nodes) {
    $ip = $node.management_ip  # compute.cluster_nodes[*].management_ip
    Write-Log "Connecting to $($node.name) ($ip)..."

    try {
        $nodeResult = Invoke-Command -ComputerName $ip -Credential $Credential -ScriptBlock {
            $r = [PSCustomObject]@{
                NodeName    = $env:COMPUTERNAME
                Domain      = (Get-WmiObject Win32_ComputerSystem).Domain
                ADAware     = $null
                Errors      = @()
            }
            try {
                $adAware = Get-ClusterResource "Cluster Name" | Get-ClusterParameter ADAware
                $r.ADAware = $adAware.Value
            } catch {
                $r.Errors += "ADAware check failed: $_"
            }
            $r
        }

        $domainPass  = $nodeResult.Domain   -eq 'WORKGROUP'
        $adAwarePass = $nodeResult.ADAware  -eq 2

        Write-Log "  Domain  : $($nodeResult.Domain)  — $(if ($domainPass) { 'PASS' } else { 'FAIL' })"
        Write-Log "  ADAware : $($nodeResult.ADAware) — $(if ($adAwarePass) { 'PASS' } else { 'FAIL' })"
        foreach ($err in $nodeResult.Errors) { Write-Log "  $err" -Level WARN }

        if (-not $domainPass -or -not $adAwarePass) { $failCount++ }
        $results.Add($nodeResult)

    } catch {
        Write-Log "Failed to connect to $ip : $_" -Level ERROR
        $failCount++
    }
}

# ── Summary table ─────────────────────────────────────────────────────────────
Write-Log "=== Summary: $($nodes.Count) node(s) checked, $failCount failure(s) ==="
$results | Format-Table NodeName, Domain, ADAware -AutoSize | Out-String | ForEach-Object { Write-Log $_ }

if ($failCount -gt 0) {
    Write-Log "Local Identity verification completed with failures — review log: $LogPath" -Level ERROR
    exit 1
} else {
    Write-Log "Local Identity configuration verified on all nodes."
}
#endregion MAIN
