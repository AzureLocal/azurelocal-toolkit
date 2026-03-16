<#
.SYNOPSIS
    Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1
    Creates the required non-built-in local administrator account on all Azure Local
    nodes via PSRemoting. Mandatory pre-deployment step for Local Identity authentication.

.DESCRIPTION
    Runs from the management/jump box. Reads the target account name and password from
    infrastructure.yml, connects to each node over PSRemoting using an existing local
    administrator credential, and creates the deployment account if it does not already
    exist. Adds the account to the Administrators group and verifies the result.

    Microsoft requires this account to:
      - NOT be the built-in Administrator account
      - Have an identical username and password on every cluster node
      - Have a password of at least 14 characters
    Ref: https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault

    infrastructure.yml paths used:
      identity.accounts.account_local_admin_username  - New account username to create
      identity.accounts.account_local_admin_password  - Key Vault ref for new account password
      compute.cluster_nodes[].management_ip           - PSRemoting connection target per node
      compute.cluster_nodes[] (key name)              - Node hostname (display only)

    Bootstrap credential note:
      The -Credential parameter (or interactive prompt fallback) provides the EXISTING
      local administrator credentials used to PSRemote into nodes. This is intentionally
      NOT resolved from Key Vault because the account being CREATED in this script is
      typically the same account that would later be stored in KV. Use an existing
      built-in or setup credential to connect, then this script creates the target account.

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-discovers infrastructure*.yml if not provided.

.PARAMETER Credential
    EXISTING local administrator credentials used to connect to cluster nodes via
    PSRemoting. If not provided, prompts interactively (Key Vault is intentionally
    skipped — see bootstrap credential note above).

.PARAMETER TargetNode
    Limit execution to one or more specific nodes by hostname. Empty = run all nodes.

.PARAMETER WhatIf
    Dry-run mode — logs what would happen without making any changes.

.PARAMETER LogPath
    Override the log file path. Default: .\logs\task-01-initiate-deployment-via-azure-portal\<timestamp>.log

.PARAMETER LocalAdminUsername
    Override the local admin username to create. When provided, takes precedence over
    identity.accounts.account_local_admin_username in infrastructure.yml.

.EXAMPLE
    .\Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1

.EXAMPLE
    .\Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1 -ConfigPath .\configs\infrastructure.yml

.EXAMPLE
    .\Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1 -TargetNode iic-01-n01

.EXAMPLE
    .\Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1 -WhatIf

.EXAMPLE
    .\Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1 -LogPath C:\logs\local-identity-setup.log

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-01-initiate-deployment-via-azure-portal (Local Identity pre-deployment)
    Execution:    Run from management/jump box (PSRemoting outbound to cluster nodes)
    Prerequisites: WinRM enabled on all nodes, existing local admin credential
    Run before:   Portal deployment — Local Identity via Azure Key Vault
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string[]]$TargetNode = @(),

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "",

    # YAML-overridable: takes precedence over identity.accounts.account_local_admin_username
    [Parameter(Mandatory = $false)]
    [string]$LocalAdminUsername = ""
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

    if ($script:LogFile) {
        "[$ts] [$Level] $Message" | Add-Content -Path $script:LogFile -ErrorAction SilentlyContinue
    }
}

function Resolve-ConfigPath {
    param([string]$Provided)

    if ($Provided -ne "" -and (Test-Path $Provided)) { return (Resolve-Path $Provided).Path }

    $searchPaths = @(
        (Join-Path $PSScriptRoot "..\..\..\..\..\..\configs"),
        (Join-Path $PSScriptRoot "..\..\..\..\..\..\..\configs"),
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
        Write-Log "Config: $($found[0].FullName)"
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

    # identity.accounts.account_local_admin_username
    $adminUser = $cfg.identity.accounts.account_local_admin_username
    if (-not $adminUser) {
        throw "identity.accounts.account_local_admin_username not found in $ConfigPath."
    }

    # identity.accounts.account_local_admin_password
    $adminPassUri = $cfg.identity.accounts.account_local_admin_password
    if (-not $adminPassUri) {
        throw "identity.accounts.account_local_admin_password not found in $ConfigPath."
    }

    # compute.cluster_nodes
    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        Write-Log "  Node: $($_.Key)  IP: $($_.Value.management_ip)"
        [PSCustomObject]@{ hostname = $_.Key; management_ip = $_.Value.management_ip }
    }

    if (-not $nodes) { throw "No nodes found under compute.cluster_nodes in $ConfigPath." }

    return [PSCustomObject]@{
        AdminUser    = $adminUser
        AdminPassUri = $adminPassUri
        Nodes        = @($nodes)
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
            Write-Log "  Az.KeyVault returned no secret." "WARN"
        } catch {
            Write-Log "  Az.KeyVault failed: $($_.Exception.Message)" "WARN"
        }
    }
    try {
        $azOut = & az keyvault secret show --vault-name $vaultName --name $secretName --query value -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and $azOut) { return ($azOut | Out-String).Trim() }
        $errDetail = if ($azOut) { ": $azOut" } else { " (exit $LASTEXITCODE)" }
        Write-Log "  az CLI failed$errDetail." "WARN"
        return $null
    } catch {
        return $null
    }
}

#endregion HELPERS

#region MAIN

Write-Log "=== Phase 05 / Task 01 — Create Local Identity Accounts (Pre-Deployment) ===" "HEADER"
if ($WhatIf) { Write-Log "*** DRY-RUN MODE — no changes will be made ***" "WARN" }

# ── Log file setup (CWD-relative, not PSScriptRoot-relative) ──────────────────
$taskFolderName = "task-01-initiate-deployment-via-azure-portal"
$logDir = Join-Path (Get-Location).Path "logs\$taskFolderName"
if ($LogPath -ne "") {
    $script:LogFile = $LogPath
} else {
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $script:LogFile = Join-Path $logDir "${stamp}_CreateLocalIdentityAccounts.log"
}
Write-Log "Log file: $script:LogFile"

# ── Load config ───────────────────────────────────────────────────────────────
$configFile   = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Config: $configFile"
$clusterCfg   = Get-ClusterConfig -ConfigPath $configFile

# ── Apply -LocalAdminUsername override ────────────────────────────────────────
$targetUser = if ($LocalAdminUsername -ne "") {
    Write-Log "Using -LocalAdminUsername override: '$LocalAdminUsername'"
    $LocalAdminUsername
} else {
    $clusterCfg.AdminUser
}

Write-Log "Target account  : $targetUser"
Write-Log "Password source : $($clusterCfg.AdminPassUri)"

# ── Resolve new account password from Key Vault ───────────────────────────────
$newAccountPass = Resolve-KeyVaultRef -KvUri $clusterCfg.AdminPassUri
if (-not $newAccountPass) {
    Write-Log "Key Vault unavailable — prompting for new account password." "WARN"
    $newAccountPassSecure = Read-Host -AsSecureString "Enter password for new account '$targetUser' (min 14 chars, must match on all nodes)"
    $newAccountPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($newAccountPassSecure)
    )
}

# ── Bootstrap connection credential ──────────────────────────────────────────
# Key Vault is intentionally skipped here: the account being created IS the one
# that will later be stored in KV. Use an existing setup credential to connect.
if (-not $Credential) {
    Write-Log "No -Credential provided — prompting for EXISTING node admin credentials." "WARN"
    $Credential = Get-Credential -Message "Enter EXISTING local administrator credentials to connect to cluster nodes"
}

# ── Apply -TargetNode filter ──────────────────────────────────────────────────
$nodes = $clusterCfg.Nodes
if ($TargetNode.Count -gt 0) {
    $nodes = $nodes | Where-Object { $TargetNode -contains $_.hostname }
    Write-Log "Filtered to $($nodes.Count) node(s): $($TargetNode -join ', ')"
}

Write-Log "Processing $($nodes.Count) node(s)..."

$results = @()

foreach ($node in $nodes) {
    $ip       = $node.management_ip
    $hostname = $node.hostname

    if (-not $ip) {
        Write-Log "[$hostname] management_ip missing — skipping" "WARN"
        continue
    }

    Write-Log "[$hostname] Target: $ip"

    if ($WhatIf) {
        Write-Log "[$hostname] [WHATIF] Would create local account '$targetUser' and add to Administrators" "WARN"
        $results += [PSCustomObject]@{ Node = $hostname; IP = $ip; Status = "WHATIF"; Detail = "Skipped (WhatIf)" }
        continue
    }

    try {
        $r = Invoke-Command -ComputerName $ip -Credential $Credential -ArgumentList $targetUser, $newAccountPass -ScriptBlock {
            param($username, $password)

            # Guard: never create built-in Administrator — MS explicitly prohibits this
            if ($username -ieq "Administrator") {
                throw "Account name 'Administrator' is not permitted. MS docs require a non-built-in account. Use a custom username."
            }

            $secPwd = ConvertTo-SecureString $password -AsPlainText -Force

            # Check if account already exists with correct group membership
            $existing = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
            $inAdmins = $false
            if ($existing) {
                $inAdmins = [bool](Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*\$username" -or $_.Name -eq $username })
            }

            if ($existing -and $inAdmins) {
                # Account exists — ensure password is set to match (idempotent)
                Set-LocalUser -Name $username -Password $secPwd -ErrorAction Stop
                return [PSCustomObject]@{
                    Hostname = $env:COMPUTERNAME
                    Status   = "PASS"
                    Detail   = "Account already existed — password updated to ensure consistency"
                }
            }

            if (-not $existing) {
                New-LocalUser -Name $username -Password $secPwd -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop
            }

            if (-not $inAdmins) {
                Add-LocalGroupMember -Group "Administrators" -Member $username -ErrorAction Stop
            }

            # Verify
            $verify = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
            if (-not $verify) {
                throw "Account '$username' not found after creation — check for errors."
            }

            return [PSCustomObject]@{
                Hostname = $env:COMPUTERNAME
                Status   = "PASS"
                Detail   = "Account created and added to Administrators"
            }
        }

        Write-Log "[$hostname] $($r.Status)  $($r.Detail)" "SUCCESS"
        $results += [PSCustomObject]@{ Node = $hostname; IP = $ip; Status = $r.Status; Detail = $r.Detail }

    } catch {
        Write-Log "[$hostname] FAILED: $($_.Exception.Message)" "ERROR"
        $results += [PSCustomObject]@{ Node = $hostname; IP = $ip; Status = "ERROR"; Detail = $_.Exception.Message }
    }
}

Write-Log ""
Write-Log "=== Local Identity Account Creation Summary ===" "HEADER"
$results | Format-Table Node, IP, Status, Detail -AutoSize -Wrap

$failCount = @($results | Where-Object { $_.Status -eq "ERROR" }).Count
if ($failCount -eq 0) {
    Write-Log "All $($results.Count) node(s) completed successfully." "SUCCESS"
    Write-Log "Next step: proceed with portal deployment — select '$targetUser' as the local identity account." "INFO"
} else {
    Write-Log "$failCount node(s) failed. Resolve errors before starting portal deployment." "ERROR"
    exit 1
}

#endregion MAIN
