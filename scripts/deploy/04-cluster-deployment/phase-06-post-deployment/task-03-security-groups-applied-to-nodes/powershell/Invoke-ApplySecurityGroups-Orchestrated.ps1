#Requires -Version 7.0
# ==============================================================================
# Script : Invoke-ApplySecurityGroups-Orchestrated.ps1
# Purpose: Add AD security groups to local groups on every cluster node,
#          driven by identity.active_directory.security_groups[].local_groups in
#          infrastructure.yml. Skips entries where local_groups is empty
#          (wac_admins, wac_users — those are applied on the WAC server only).
# Run    : From management server — reads infrastructure.yml, uses PSRemoting
# Prereqs: PSRemoting enabled on all nodes, infrastructure.yml accessible,
#          powershell-yaml module installed
# Login  : -Credential, else the LCM account of the file (identity.active_directory.lcm_user, the password a secret reference read
#          through AzlSecret). The script never asks. With neither it stops with exit code 2.
# Exit   : 0 done (or planned under -WhatIf); 1 a node failed; 2 the file or the login is missing or not usable (nothing was changed).
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,   # The master infrastructure.yml (schema 5)
    [PSCredential]$Credential,     # The account for PSRemoting; without it the LCM account of the file is used
    [string[]]$TargetNode = @(),   # Limit to specific nodes; empty = all nodes from config
    [switch]$WhatIf,               # Dry-run — validate only, no changes
    [string]$LogPath      = ""     # Override log file path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

# ── Logging ───────────────────────────────────────────────────────────────────
$scriptShortName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -replace '^Invoke-|-Orchestrated$', ''
$taskFolderName  = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf
$logDir  = if ($LogPath -ne "") { Split-Path $LogPath -Parent } else { Join-Path (Get-Location).Path "logs\$taskFolderName" }
$logFile = if ($LogPath -ne "") { $LogPath } else { Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd_HHmmss')_${scriptShortName}.log" }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    $line | Out-File -FilePath $script:logFile -Append -Encoding utf8
    switch ($Level) {
        "PASS"    { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "FAIL"    { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
        "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
        "VERBOSE" { Write-Verbose "[$ts] $Message" }
        "DEBUG"   { Write-Debug  "[$ts] $Message" }
        default   { Write-Host "[$ts] [INFO] $Message" }
    }
}

Write-Log "Invoke-ApplySecurityGroups-Orchestrated started"
Write-Log "Log: $logFile"

# ── Config loading ────────────────────────────────────────────────────────────
try { $cfg = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Log "Cannot read the infrastructure file: $($_.Exception.Message)" 'FAIL'; exit 2 }
Write-Log "Loaded the infrastructure file: $InfrastructureFile"
$script:SecretInfrastructure = $cfg

# ── Build the AD group -> local groups list ────────────────────────────────────
# identity.active_directory.security_groups[] of infrastructure.yml: name, purpose, local_groups (registry 4.1.0).
$domainNetbios = Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.netbios_name'
$sgValue       = Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.security_groups'
$sgConfig      = @(@($sgValue) | Where-Object { $null -ne $_ })

# Build assignment list: [ { AdGroup, LocalGroups } ... ] — skip where local_groups is empty
$assignments = @()
foreach ($group in $sgConfig) {
    $key         = [string]$group['name']                                     # identity.active_directory.security_groups[].name
    $localGroups = @($group['local_groups'] | Where-Object { $_ })            # identity.active_directory.security_groups[].local_groups
    if ($localGroups.Count -eq 0) {
        Write-Log "Skipping '$key' — local_groups is empty" 'WARN'
        continue
    }
    $adGroupFqdn = "$domainNetbios\$key"
    $assignments += [PSCustomObject]@{
        Key         = $key
        AdGroup     = $adGroupFqdn
        LocalGroups = $localGroups
    }
    Write-Log "Will assign: $adGroupFqdn → [$($localGroups -join ', ')]"
}
if ($assignments.Count -eq 0) {
    Write-Log "No groups with local_groups assignments found — nothing to do" 'WARN'
    exit 0
}

# ── Determine target nodes ────────────────────────────────────────────────────
# Use management_ip for PSRemoting so NTLM auth works from non-domain management machines.
# Hostname-based Kerberos auth requires the management machine to be domain-joined.
$nodes = if ($TargetNode.Count) {
    $TargetNode
} else {
    Get-AzlInfrastructureNode -Infrastructure $cfg | ForEach-Object { $_.ManagementIp }    # nodes[].management.ip_address
}

Write-Log "Target nodes: $($nodes -join ', ')"

# ── WhatIf guard ──────────────────────────────────────────────────────────────
if ($WhatIf) {
    foreach ($a in $assignments) {
        Write-Log "[WhatIf] Would add '$($a.AdGroup)' to [$($a.LocalGroups -join ', ')] on: $($nodes -join ', ')" 'WARN'
    }
    Write-Log "WhatIf complete — no changes made" 'WARN'
    exit 0
}

# ── Credential resolution ─────────────────────────────────────────────────────
function Resolve-KeyVaultRef {
    # Reads a secret reference through the toolkit's one secret resolver (AzlSecret.psm1): any provider, no Azure CLI.
    # Returns a SecureString, or $null when it cannot be read; the caller then stops with exit code 2. No value is logged.
    param([string]$KvUri)
    if (-not (Get-AzlSecretProvider -Reference $KvUri)) { Write-Log "  The value is not a secret reference." "WARN"; return $null }
    try {
        $value = Get-AzlSecretValue -Reference $KvUri -Infrastructure $script:SecretInfrastructure
        Write-Log "  Secret retrieved." "PASS"
        return $value
    }
    catch { Write-Log "  The secret could not be read: $($_.Exception.Message)" "WARN"; return $null }
}

# CREDENTIAL RESOLUTION ORDER:
# 1. -Credential parameter (passed directly)
# 2. The LCM account of the file (domain account for PSRemoting to domain-joined nodes); the password is a secret reference
# Nothing is asked: with neither the script stops with exit code 2.
if (-not $Credential) {
    $netBios    = Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.netbios_name'
    $lcmUser    = Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.lcm_user.username'
    $lcmPassUri = Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.lcm_user.password'
    # Prefix with DOMAIN\ so NTLM resolves correctly when connecting via IP from a non-domain machine
    $lcmUserFqn = "${netBios}\${lcmUser}"
    Write-Log "Resolving LCM credentials from the secret reference..."
    if ([string]::IsNullOrWhiteSpace([string]$netBios) -or [string]::IsNullOrWhiteSpace([string]$lcmUser)) {
        Write-Log "No login: pass -Credential, or set identity.active_directory.netbios_name and identity.active_directory.lcm_user.username in the file." 'FAIL'
        exit 2
    }
    $lcmPass = if ($lcmPassUri) { Resolve-KeyVaultRef -KvUri $lcmPassUri } else { $null }
    if (-not $lcmPass) {
        Write-Log "No login: pass -Credential, or set identity.active_directory.lcm_user.username and password (a secret reference) in the file." 'FAIL'
        exit 2
    }
    $Credential = [pscredential]::new($lcmUserFqn, $lcmPass)
    Write-Log "Credentials resolved for '$lcmUserFqn'." "PASS"
}

$credParam = @{ Credential = $Credential }

$results = @()

foreach ($node in $nodes) {
    Write-Log "[$node] Applying security groups..."

    try {
        $nodeResult = Invoke-Command -ComputerName $node @credParam -ScriptBlock {
        param($Assignments)

        $log    = @()
        $errors = @()

        function Add-GroupMemberSafe {
            param([string]$LocalGroup, [string]$Member)
            try {
                Add-LocalGroupMember -Group $LocalGroup -Member $Member -ErrorAction Stop
                return "Added '$Member' to '$LocalGroup'"
            } catch {
                if ($_.Exception.Message -match 'already a member|is already a member') {
                    return "'$Member' already in '$LocalGroup' — no change"
                }
                throw
            }
        }

        $applied = @{}
        foreach ($a in $Assignments) {
            $ok = $true
            foreach ($lg in $a.LocalGroups) {
                try {
                    $log += Add-GroupMemberSafe -LocalGroup $lg -Member $a.AdGroup
                } catch {
                    $errors += "[$($a.Key)] ${lg}: $($_.Exception.Message)"
                    $ok = $false
                }
            }
            # Verify each local_group membership
            $confirmed = @{}
            foreach ($lg in $a.LocalGroups) {
                $members = Get-LocalGroupMember -Group $lg -ErrorAction SilentlyContinue
                $confirmed[$lg] = ($members | Where-Object { $_.Name -match [regex]::Escape($a.AdGroup) }).Count -gt 0
            }
            $applied[$a.Key] = [PSCustomObject]@{
                AdGroup    = $a.AdGroup
                Confirmed  = $confirmed
                Errors     = ($errors | Where-Object { $_ -match $a.Key })
            }
        }

        return [PSCustomObject]@{
            Success  = ($errors.Count -eq 0)
            Node     = $env:COMPUTERNAME
            Applied  = $applied
            Log      = $log
            Errors   = $errors
        }
    } -ArgumentList (, $assignments)

        foreach ($line in $nodeResult.Log)   { Write-Log "[$node] $line" }
        foreach ($err  in $nodeResult.Errors) { Write-Log "[$node] $err" 'FAIL' }

        foreach ($key in $nodeResult.Applied.Keys) {
            $a = $nodeResult.Applied[$key]
            foreach ($lg in $a.Confirmed.Keys) {
                $status = if ($a.Confirmed[$lg]) { 'OK' } else { 'NOT CONFIRMED' }
                Write-Log "[$node] $key → $lg : $status"
            }
        }

        $results += [PSCustomObject]@{
            Node    = $node
            Status  = if ($nodeResult.Success) { 'Success' } else { 'Failed' }
            Applied = $nodeResult.Applied
            Errors  = $nodeResult.Errors -join '; '
        }
    } catch {
        Write-Log "[$node] PSRemoting failed: $($_.Exception.Message)" 'FAIL'
        $results += [PSCustomObject]@{
            Node    = $node
            Status  = 'Failed'
            Applied = $null
            Errors  = $_.Exception.Message
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Log "Security group application complete"
$results | Format-Table Node, Status, Errors -AutoSize

$failed = @($results | Where-Object Status -eq 'Failed')

Write-Log "Invoke-ApplySecurityGroups-Orchestrated complete"
$results
if ($failed.Count -gt 0) {
    Write-Log "$($failed.Count) node(s) failed — review log: $logFile" 'WARN'
    exit 1
}
exit 0
