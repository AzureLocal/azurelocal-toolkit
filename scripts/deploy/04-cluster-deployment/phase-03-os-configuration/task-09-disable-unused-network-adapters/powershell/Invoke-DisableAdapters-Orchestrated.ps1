#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-DisableAdapters-Orchestrated.ps1
    Disables unused (disconnected) network adapters on all Azure Local nodes via PSRemoting.

.DESCRIPTION
    Runs from the management server. Reads node IPs from infrastructure.yml,
    connects to each node over PSRemoting, and disables all adapters in a
    Disconnected state.

    infrastructure.yml paths used:
      compute.cluster_nodes                           - Node names and management IPs
      identity.accounts.account_local_admin_username  - Credential username
      identity.accounts.account_local_admin_password  - KV reference for password

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-detected from .\configs\ if not specified.

.PARAMETER Credential
    PSCredential for PSRemoting. If omitted, resolved from Key Vault.

.EXAMPLE
    .\Invoke-DisableAdapters-Orchestrated.ps1 -ConfigPath ".\configs\infrastructure-azl-lab.yml"
    .\Invoke-DisableAdapters-Orchestrated.ps1

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      2.0.0
    Phase:        03-os-configuration
    Task:         task-09-disable-unused-network-adapters
    Execution:    Run from management server (PSRemoting outbound to nodes)
    Prerequisites: WinRM enabled on all nodes, static IP configured (Task 03)
    Run after:    Task 08 - ICMP ping enabled
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region HELPERS

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "SUCCESS" { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "ERROR"   { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
        "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
        default   { Write-Host "[$ts] [INFO] $Message" }
    }
}

function Resolve-ConfigPath {
    param([string]$Provided)

    if ($Provided -ne "" -and (Test-Path $Provided)) { return (Resolve-Path $Provided).Path }

    $searchPaths = @(
        (Join-Path $PSScriptRoot "..\..\..\..\configs"),
        (Join-Path $PSScriptRoot "..\..\..\..\..\configs"),
        "C:\configs",
        "C:\AzureLocal\configs"
    )

    $found = @()
    foreach ($dir in $searchPaths) {
        if (Test-Path $dir) {
            $found += Get-ChildItem -Path $dir -Filter "infrastructure*.yml" -File -ErrorAction SilentlyContinue
        }
    }

    $found = @($found | Sort-Object FullName -Unique)

    if ($found.Count -eq 0) {
        throw "No infrastructure*.yml found. Pass -ConfigPath or place it in a standard location."
    }

    if ($found.Count -eq 1) {
        return $found[0].FullName
    }

    Write-Log "Multiple config files found:" "WARN"
    for ($i = 0; $i -lt $found.Count; $i++) {
        Write-Host "  [$($i+1)] $($found[$i].FullName)" -ForegroundColor Yellow
    }
    $choice = Read-Host "Select config [1-$($found.Count)]"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $found.Count) { throw "Invalid selection." }
    return $found[$idx].FullName
}

function Get-ClusterConfig {
    [CmdletBinding()]
    param([string]$ConfigPath)

    if (-not (Get-Module -Name powershell-yaml -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Log "Installing powershell-yaml module..." "WARN"
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        Write-Log "  Node: $($_.Key)  IP: $($_.Value.management_ip)"
        [PSCustomObject]@{ hostname = $_.Key; management_ip = $_.Value.management_ip }
    }

    if (-not $nodes) { throw "No nodes found under compute.cluster_nodes in $ConfigPath." }

    $adminUser    = $cfg.identity.accounts.account_local_admin_username
    $adminPassUri = $cfg.identity.accounts.account_local_admin_password

    return [PSCustomObject]@{
        Nodes        = @($nodes)
        AdminUser    = $adminUser
        AdminPassUri = $adminPassUri
    }
}

function Resolve-KeyVaultRef {
    param([Parameter(Mandatory)][string]$KvUri)
    if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') { return $null }
    $vaultName  = $Matches[1]
    $secretName = $Matches[2]
    Write-Log "  Fetching '$secretName' from Key Vault '$vaultName'..."
    if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
            if ($secret) { return $secret }
            Write-Log "  Az.KeyVault returned no secret." WARN
        } catch {
            Write-Log "  Az.KeyVault failed: $($_.Exception.Message)" WARN
        }
    }
    try {
        $azOut = & az keyvault secret show --vault-name $vaultName --name $secretName --query value -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and $azOut) { return ($azOut | Out-String).Trim() }
        $errDetail = if ($azOut) { ": $azOut" } else { " (exit $LASTEXITCODE)" }
        Write-Log "  az CLI failed$errDetail." WARN
        return $null
    } catch {
        return $null
    }
}

#endregion HELPERS

#region MAIN

Write-Log "=== Task 09 - Disable Unused Network Adapters ===" "HEADER"

$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Config: $configFile"

$clusterCfg = Get-ClusterConfig -ConfigPath $configFile
$nodes      = $clusterCfg.Nodes

Write-Log "Nodes : $($nodes.Count) found"

if (-not $Credential) {
    Write-Log "Resolving credentials from Key Vault..."
    $adminPass = Resolve-KeyVaultRef -KvUri $clusterCfg.AdminPassUri
    if ($adminPass) {
        $Credential = New-Object PSCredential($clusterCfg.AdminUser.Trim(), (ConvertTo-SecureString $adminPass -AsPlainText -Force))
        Write-Log "Credentials resolved for '$($clusterCfg.AdminUser.Trim())'." SUCCESS
    } else {
        Write-Log "Key Vault unavailable — prompting for credentials." WARN
        $Credential = Get-Credential -Message "Enter local Administrator credentials for cluster nodes" -UserName $clusterCfg.AdminUser.Trim()
    }
}
$cred = $Credential

$results = @()

foreach ($node in $nodes) {
    $ip       = $node.management_ip
    $hostname = $node.hostname
    if (-not $ip) {
        Write-Log "[$hostname] management_ip missing — skipping" WARN
        continue
    }

    Write-Log "[$hostname] Connecting to $ip..." "HEADER"

    try {
        $r = Invoke-Command -ComputerName $ip -Credential $cred -ScriptBlock {
            $disabled = @()
            $errors   = @()
            foreach ($a in (Get-NetAdapter | Where-Object Status -eq "Disconnected")) {
                try {
                    $a | Disable-NetAdapter -Confirm:$false -ErrorAction Stop
                    $disabled += $a.Name
                } catch {
                    $errors += "$($a.Name): $_"
                }
            }
            $after = Get-NetAdapter | Sort-Object Name | Select-Object Name, Status, LinkSpeed
            [PSCustomObject]@{
                DisabledCount = $disabled.Count
                Disabled      = $disabled
                Errors        = $errors
                Adapters      = $after
            }
        }

        if ($r.Errors.Count -gt 0) {
            Write-Log "[$hostname] Completed with errors:" WARN
            $r.Errors | ForEach-Object { Write-Log "  $_" WARN }
        } else {
            Write-Log "[$hostname] Disabled $($r.DisabledCount) adapter(s)." SUCCESS
        }
        $r.Adapters | ForEach-Object {
            Write-Log "  $($_.Name.PadRight(30)) $($_.Status.PadRight(15)) $($_.LinkSpeed)"
        }
        $results += [PSCustomObject]@{
            Node     = $hostname
            IP       = $ip
            Result   = if ($r.Errors.Count -gt 0) { "Error" } else { "OK" }
            Disabled = $r.DisabledCount
            Detail   = if ($r.Errors.Count -gt 0) { $r.Errors -join "; " } else { "Disabled: $($r.Disabled -join ', ')" }
        }
    } catch {
        Write-Log "[$hostname] Failed: $_" ERROR
        $results += [PSCustomObject]@{
            Node     = $hostname
            IP       = $ip
            Result   = "Error"
            Disabled = 0
            Detail   = $_.ToString()
        }
    }
}

#endregion MAIN

Write-Log ""
Write-Log "=== Summary ===" "HEADER"
$results | Format-Table Node, IP, Result, Disabled, Detail -AutoSize

$failCount = @($results | Where-Object { $_.Result -ne "OK" }).Count
if ($failCount -eq 0) {
    Write-Log "All $($results.Count) node(s) completed successfully." "SUCCESS"
} else {
    Write-Log "$failCount node(s) had errors. Review output above." "ERROR"
    exit 1
}