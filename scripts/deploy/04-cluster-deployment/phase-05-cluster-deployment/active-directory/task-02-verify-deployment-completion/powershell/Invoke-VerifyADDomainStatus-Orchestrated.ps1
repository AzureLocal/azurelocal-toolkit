<#
.SYNOPSIS
    Invoke-VerifyADDomainStatus-Orchestrated.ps1
    Orchestrated wrapper — verifies AD domain join status across all cluster nodes.

.DESCRIPTION
    Reads infrastructure config for node IPs, domain FQDN, OU path, and LCM account,
    then calls Test-ADDomainStatus.ps1 against each node. Follows the Invoke- script
    mandatory contract (ConfigPath, Credential, TargetNode, WhatIf, LogPath).

.PARAMETER ConfigPath
    Path to the infrastructure YAML config (default: config/infrastructure.yml).

.PARAMETER Credential
    PSCredential for remote node access. Falls back to Key Vault → interactive prompt.

.PARAMETER TargetNode
    Limit verification to specific node names. Empty = all nodes.

.PARAMETER WhatIf
    Dry-run mode — shows what would be checked without executing remote commands.

.PARAMETER LogPath
    Override log file path. Defaults to ./logs/<task-folder-name>/<timestamp>.log.

.EXAMPLE
    .\Invoke-VerifyADDomainStatus-Orchestrated.ps1

.EXAMPLE
    .\Invoke-VerifyADDomainStatus-Orchestrated.ps1 -ConfigPath "config/infrastructure-azl-demo.yml" -WhatIf

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Script Type:  Invoke (Option 1 — config-driven orchestration)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string[]]$TargetNode = @(),

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Logging ────────────────────────────────────────────────────────────
$taskFolderName = "task-02-verify-deployment-completion"
$timestamp      = Get-Date -Format "yyyy-MM-dd_HHmmss"

if (-not $LogPath) {
    $logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
    $LogPath = Join-Path $logDir "${timestamp}_VerifyADDomainStatus.log"
}

$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] [$Level] $Message"
    $entry | Out-File -FilePath $LogPath -Append -Encoding utf8
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARNING" { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
}

Write-Log "=== AD Domain Status Verification — Orchestrated ==="
Write-Log "Log: $LogPath"

# ── Config Loading ─────────────────────────────────────────────────────
if (-not $ConfigPath) {
    $candidates = @("config/infrastructure.yml", "config/infrastructure.yaml")
    foreach ($c in $candidates) {
        if (Test-Path $c) { $ConfigPath = $c; break }
    }
    if (-not $ConfigPath) {
        Write-Log "No config file found. Specify -ConfigPath." -Level "ERROR"
        exit 1
    }
}

Write-Log "Loading config: $ConfigPath"

try {
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
    }
    Import-Module powershell-yaml -ErrorAction Stop
    $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Yaml
}
catch {
    Write-Log "Failed to load YAML config: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

# ── Extract Config Values ──────────────────────────────────────────────
$clusterNodes = $cfg.compute.cluster_nodes                                   # compute.cluster_nodes
$domainFqdn   = $cfg.cluster_arm_deployment.domain_fqdn                      # cluster_arm_deployment.domain_fqdn
$ouPath       = $cfg.cluster_arm_deployment.domain_ou_path                   # cluster_arm_deployment.domain_ou_path
$lcmUser      = $cfg.accounts.lcm_admin.username                            # accounts.lcm_admin.username
$clusterName  = $cfg.cluster_arm_deployment.cluster_name                     # cluster_arm_deployment.cluster_name

Write-Log "Domain FQDN:    $domainFqdn"
Write-Log "OU Path:        $ouPath"
Write-Log "LCM Account:    $lcmUser"
Write-Log "Cluster Name:   $clusterName"
Write-Log "Nodes found:    $($clusterNodes.Count)"

# ── Filter Nodes ───────────────────────────────────────────────────────
if ($TargetNode.Count -gt 0) {
    $clusterNodes = $clusterNodes | Where-Object { $TargetNode -contains $_.name }
    Write-Log "Filtered to $($clusterNodes.Count) target node(s): $($TargetNode -join ', ')"
}

if (-not $clusterNodes -or $clusterNodes.Count -eq 0) {
    Write-Log "No cluster nodes found in config." -Level "ERROR"
    exit 1
}

# ── Credential Resolution ─────────────────────────────────────────────
if (-not $Credential) {
    # Try Key Vault resolution
    $kvRef = $cfg.accounts.local_admin.password  # accounts.local_admin.password
    if ($kvRef -and $kvRef -match '^keyvault://') {
        Write-Log "Resolving credential from Key Vault reference..."
        try {
            $parts     = $kvRef -replace '^keyvault://', '' -split '/'
            $vaultName = $parts[0]; $secretName = $parts[1]
            $secret    = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -ErrorAction Stop
            $adminUser = $cfg.accounts.local_admin.username  # accounts.local_admin.username
            $Credential = New-Object PSCredential($adminUser, $secret.SecretValue)
            Write-Log "Credential resolved from Key Vault." -Level "SUCCESS"
        }
        catch {
            Write-Log "Key Vault resolution failed: $($_.Exception.Message)" -Level "WARNING"
        }
    }

    if (-not $Credential) {
        Write-Log "Prompting for credential..." -Level "WARNING"
        $Credential = Get-Credential -Message "Enter credentials for remote node access"
    }
}

# ── WhatIf Gate ────────────────────────────────────────────────────────
if ($WhatIf) {
    Write-Log "[WhatIf] Would verify AD domain status for:" -Level "WARNING"
    foreach ($node in $clusterNodes) {
        Write-Log "[WhatIf]   $($node.name) ($($node.ipv4_address))" -Level "WARNING"
    }
    Write-Log "[WhatIf] Domain:  $domainFqdn" -Level "WARNING"
    Write-Log "[WhatIf] OU:      $ouPath" -Level "WARNING"
    Write-Log "[WhatIf] LCM:     $lcmUser" -Level "WARNING"
    Write-Log "[WhatIf] Cluster: $clusterName" -Level "WARNING"
    Write-Log "[WhatIf] No changes will be made." -Level "WARNING"
    exit 0
}

# ── Call Verification Script ───────────────────────────────────────────
$testScript = Join-Path $PSScriptRoot "Test-ADDomainStatus.ps1"
if (-not (Test-Path $testScript)) {
    Write-Log "Test-ADDomainStatus.ps1 not found at: $testScript" -Level "ERROR"
    exit 1
}

Write-Log "Calling Test-ADDomainStatus.ps1..."

$nodeIPs = $clusterNodes | ForEach-Object { $_.ipv4_address }

$testParams = @{
    NodeIPs     = $nodeIPs
    DomainFqdn  = $domainFqdn
    OUPath      = $ouPath
    LcmUser     = $lcmUser
    ClusterName = $clusterName
    Credential  = $Credential
}

try {
    $results = & $testScript @testParams
}
catch {
    Write-Log "Test-ADDomainStatus.ps1 failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

# ── Results Summary ────────────────────────────────────────────────────
Write-Log ""
Write-Log "=== Verification Complete ==="

$failures = $results | Where-Object { -not $_.Passed }
if ($failures) {
    Write-Log "$($failures.Count) check(s) FAILED:" -Level "ERROR"
    foreach ($f in $failures) {
        Write-Log "  FAIL: $($f.Test) — $($f.Detail)" -Level "ERROR"
    }
    exit 1
}
else {
    Write-Log "All AD domain status checks passed." -Level "SUCCESS"
    exit 0
}
