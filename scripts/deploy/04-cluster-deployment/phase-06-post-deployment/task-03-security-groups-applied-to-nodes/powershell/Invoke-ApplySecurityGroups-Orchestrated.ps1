#Requires -Version 7.0
# ==============================================================================
# Script : Invoke-ApplySecurityGroups-Orchestrated.ps1
# Purpose: Add AD security groups to local groups on every cluster node,
#          driven by active_directory.security_groups[*].local_groups in
#          infrastructure.yml. Skips entries where local_groups is empty
#          (wac_admins, wac_users — those are applied on the WAC server only).
# Run    : From management server — reads infrastructure.yml, uses PSRemoting
# Prereqs: PSRemoting enabled on all nodes, infrastructure.yml accessible,
#          powershell-yaml module installed
# ==============================================================================

[CmdletBinding()]
param(
    [string]$ConfigPath   = "",    # Path to infrastructure.yml; defaults to .\configs\infrastructure.yml
    [PSCredential]$Credential,     # Override credential resolution
    [string[]]$TargetNode = @(),   # Limit to specific nodes; empty = all nodes from config
    [switch]$WhatIf,               # Dry-run — validate only, no changes
    [string]$LogPath      = ""     # Override log file path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Get-Location).Path "configs\infrastructure.yml"
}
if (-not (Test-Path $ConfigPath)) {
    Write-Log "Config file not found: $ConfigPath" 'FAIL'
    throw "Config file not found: $ConfigPath"
}

Import-Module powershell-yaml -ErrorAction Stop
Write-Log "Loading config: $ConfigPath"
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

# ── Build per-group → local_groups mapping (skip entries with empty local_groups) ─
$domainNetbios = $cfg.identity.active_directory.domain.netbios                # identity.active_directory.domain.netbios
$sgConfig      = $cfg.identity.active_directory.security_groups               # identity.active_directory.security_groups

# Only process keyed group entries (hashtable values); skip scalar metadata keys
$groupKeys = $sgConfig.Keys | Where-Object { $sgConfig[$_] -is [System.Collections.IDictionary] }

# Build assignment list: [ { AdGroup, LocalGroups } ... ] — skip where local_groups is empty
$assignments = @()
foreach ($key in $groupKeys) {
    $localGroups = @($sgConfig[$key]['local_groups'])                          # active_directory.security_groups.<key>.local_groups
    if ($localGroups.Count -eq 0 -or ($localGroups.Count -eq 1 -and $localGroups[0] -eq $null)) {
        Write-Log "Skipping '$key' — local_groups is empty (WAC server only)" 'WARN'
        continue
    }
    $adGroupFqdn = "$domainNetbios\$($sgConfig[$key]['name'])"                 # active_directory.security_groups.<key>.name
    $assignments += [PSCustomObject]@{
        Key         = $key
        AdGroup     = $adGroupFqdn
        LocalGroups = $localGroups
    }
    Write-Log "Will assign: $adGroupFqdn → [$($localGroups -join ', ')]"
}

if ($assignments.Count -eq 0) {
    Write-Log "No groups with local_groups assignments found — check configuration" 'WARN'
    return
}

# ── Determine target nodes ────────────────────────────────────────────────────
# Use management_ip for PSRemoting so NTLM auth works from non-domain management machines.
# Hostname-based Kerberos auth requires the management machine to be domain-joined.
$nodes = if ($TargetNode.Count) {
    $TargetNode
} else {
    $cfg.compute.cluster_nodes.Values | ForEach-Object { $_.management_ip }    # compute.cluster_nodes.<key>.management_ip
}

Write-Log "Target nodes: $($nodes -join ', ')"

# ── WhatIf guard ──────────────────────────────────────────────────────────────
if ($WhatIf) {
    foreach ($a in $assignments) {
        Write-Log "[WhatIf] Would add '$($a.AdGroup)' to [$($a.LocalGroups -join ', ')] on: $($nodes -join ', ')" 'WARN'
    }
    Write-Log "WhatIf complete — no changes made" 'WARN'
    return
}

# ── Credential resolution ─────────────────────────────────────────────────────
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

# CREDENTIAL RESOLUTION ORDER:
# 1. -Credential parameter (passed directly)
# 2. Key Vault — LCM account (domain account for PSRemoting to domain-joined nodes)
# 3. Interactive Get-Credential prompt
if (-not $Credential) {
    $netBios    = $cfg.identity.active_directory.domain.netbios            # identity.active_directory.domain.netbios
    $lcmUser    = $cfg.identity.accounts.account_lcm_username              # identity.accounts.account_lcm_username
    $lcmPassUri = $cfg.identity.accounts.account_lcm_password              # identity.accounts.account_lcm_password
    # Prefix with DOMAIN\ so NTLM resolves correctly when connecting via IP from a non-domain machine
    $lcmUserFqn = "${netBios}\${lcmUser}"
    Write-Log "Resolving LCM credentials from Key Vault..."
    $lcmPass = Resolve-KeyVaultRef -KvUri $lcmPassUri
    if ($lcmPass) {
        $Credential = New-Object PSCredential(
            $lcmUserFqn,
            (ConvertTo-SecureString $lcmPass -AsPlainText -Force)
        )
        Write-Log "Credentials resolved for '$lcmUserFqn'." "PASS"
    } else {
        Write-Log "Key Vault unavailable — prompting for credentials." "WARN"
        $Credential = Get-Credential -Message "Enter LCM credentials for PSRemoting to cluster nodes" -UserName $lcmUserFqn
    }
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

$failed = $results | Where-Object Status -eq 'Failed'
if ($failed) {
    Write-Log "$($failed.Count) node(s) failed — review log: $logFile" 'WARN'
}

Write-Log "Invoke-ApplySecurityGroups-Orchestrated complete"
return $results
