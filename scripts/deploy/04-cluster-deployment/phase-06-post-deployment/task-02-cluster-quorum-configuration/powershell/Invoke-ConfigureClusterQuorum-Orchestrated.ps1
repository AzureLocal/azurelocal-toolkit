<#
.SYNOPSIS
    Invoke-ConfigureClusterQuorum-Orchestrated.ps1
    Validates or creates the cloud witness storage account, then configures
    cluster quorum (Cloud Witness / File Share Witness).

.DESCRIPTION
    Runs from the management server. Reads witness configuration from
    infrastructure.yml, validates/creates the Azure storage account (for cloud
    witness), then sets quorum via PSRemoting to a single cluster node.

    infrastructure.yml paths used:
      compute.azure_local.cluster_name                          - Cluster name
      compute.azure_local.cluster_witness_type                  - Witness type (cloud_witness / file_share_witness)
      compute.azure_local.cluster_witness_file_share_path       - UNC path (file_share_witness only)
      compute.cluster_nodes.<key>.management_ip                 - Node IPs (first used for PSRemoting)
      storage_accounts.storage_accounts.cluster_witness.name    - Witness storage account name
      storage_accounts.storage_accounts.cluster_witness.resource_group - Witness SA resource group
      storage_accounts.storage_accounts.cluster_witness.subscription   - Witness SA subscription
      storage_accounts.storage_accounts.cluster_witness.sku            - Witness SA SKU
      azure_platform.region                                     - Region for SA creation
      identity.accounts.account_lcm_username                    - LCM service account username
      identity.accounts.account_lcm_password                    - LCM service account password (keyvault:// URI)
      identity.accounts.account_local_admin_username            - Local admin username (fallback)
      identity.accounts.account_local_admin_password            - Local admin password (keyvault:// URI, fallback)
      identity.active_directory.ad_netbios_name                 - Netbios domain name (for LCM account)

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        06-post-deployment
    Task:         task-02-cluster-quorum-configuration
    Execution:    Run from management server (PSRemoting outbound to one cluster node)
    Prerequisites: Az.Accounts + Az.Storage modules; authenticated to Azure (cloud_witness only)
    Run after:    Phase 05 cluster deployment complete

.EXAMPLE
    .\Invoke-ConfigureClusterQuorum-Orchestrated.ps1 -ConfigPath "configs\infrastructure.yml"
    .\Invoke-ConfigureClusterQuorum-Orchestrated.ps1 -ConfigPath "configs\infrastructure.yml" -WhatIf
    .\Invoke-ConfigureClusterQuorum-Orchestrated.ps1 -ConfigPath "configs\infrastructure.yml" -WitnessType cloud_witness
#>

[CmdletBinding()]
param(
    [string]$ConfigPath           = "",          # Path to infrastructure.yml
    [PSCredential]$Credential,                   # Override credential resolution
    [string[]]$TargetNode         = @(),         # Specific node IP for PSRemoting; empty = first node from config
    [switch]$WhatIf,                             # Dry-run — validate and log only, no changes
    [string]$LogPath              = "",          # Override log file path

    # YAML-overridable parameters
    [string]$WitnessType          = "",          # Override: compute.azure_local.cluster_witness_type
    [string]$WitnessAccountName   = "",          # Override: storage_accounts.storage_accounts.cluster_witness.name
    [string]$WitnessResourceGroup = "",          # Override: storage_accounts.storage_accounts.cluster_witness.resource_group
    [string]$WitnessSubscription  = "",          # Override: storage_accounts.storage_accounts.cluster_witness.subscription
    [string]$WitnessSku           = "",          # Override: storage_accounts.storage_accounts.cluster_witness.sku
    [string]$FileSharePath        = ""           # Override: compute.azure_local.cluster_witness_file_share_path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region LOGGING

$taskFolderName = "task-02-cluster-quorum-configuration"

if (-not $LogPath) {
    $logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
    $logFile = Join-Path $logDir ("{0}_{1}_ConfigureClusterQuorum.log" -f (Get-Date -Format 'yyyy-MM-dd'), (Get-Date -Format 'HHmmss'))
} else {
    $logDir  = Split-Path $LogPath
    $logFile = $LogPath
}

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    $color = switch ($Level) {
        'SUCCESS' { 'Green'  }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        'HEADER'  { 'Cyan'   }
        default   { 'White'  }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $logFile -Value $line
}

#endregion LOGGING

#region HELPERS

function Resolve-ConfigPath {
    param([string]$Provided)
    if ($Provided -ne "" -and (Test-Path $Provided)) { return (Resolve-Path $Provided).Path }

    $searchPaths = @(
        (Join-Path $PSScriptRoot "..\..\..\..\..\..\configs"),
        (Join-Path $PSScriptRoot "..\..\..\..\..\..\..\configs"),
        (Join-Path (Get-Location).Path "configs")
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
        Write-Log "Config auto-resolved: $($found[0].FullName)"
        return $found[0].FullName
    }

    Write-Log "Multiple config files found:" 'WARN'
    for ($i = 0; $i -lt $found.Count; $i++) {
        Write-Host "  [$($i+1)] $($found[$i].FullName)" -ForegroundColor Yellow
    }
    $choice = Read-Host "Select config [1-$($found.Count)]"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $found.Count) { throw "Invalid selection." }
    return $found[$idx].FullName
}

function Resolve-KeyVaultRef {
    param([Parameter(Mandatory)][string]$KvUri)
    if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') { return $null }
    $vaultName  = $Matches[1]
    $secretName = $Matches[2]
    Write-Log "  Fetching secret '$secretName' from Key Vault '$vaultName'..."
    if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
            if ($secret) { return $secret }
        } catch {
            Write-Log "  Az.KeyVault failed: $($_.Exception.Message)" 'WARN'
        }
    }
    try {
        $azOut = & az keyvault secret show --vault-name $vaultName --name $secretName --query value -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and $azOut) { return ($azOut | Out-String).Trim() }
        Write-Log "  az CLI KV lookup failed (exit $LASTEXITCODE): $azOut" 'WARN'
        return $null
    } catch {
        return $null
    }
}

#endregion HELPERS

#region MAIN

Write-Log "=== Task 02 — Cluster Quorum Configuration ===" 'HEADER'
Write-Log "Log file: $logFile"

# ── Config loading ────────────────────────────────────────────────────────────
$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Config: $configFile"

if (-not (Get-Module -Name powershell-yaml -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Log "Installing powershell-yaml module..." 'WARN'
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
}
Import-Module powershell-yaml -ErrorAction Stop

$cfg = Get-Content $configFile -Raw | ConvertFrom-Yaml

# ── Extract values (param overrides take precedence) ─────────────────────────
$clusterName     = $cfg.compute.azure_local.cluster_name                                            # compute.azure_local.cluster_name
$resolvedWitType = if ($WitnessType          -ne "") { $WitnessType }          else { $cfg.compute.azure_local.cluster_witness_type }                              # compute.azure_local.cluster_witness_type
$resolvedAcctName= if ($WitnessAccountName   -ne "") { $WitnessAccountName }   else { $cfg.storage_accounts.storage_accounts.cluster_witness.name }               # storage_accounts.storage_accounts.cluster_witness.name
$resolvedWitRg   = if ($WitnessResourceGroup -ne "") { $WitnessResourceGroup } else { $cfg.storage_accounts.storage_accounts.cluster_witness.resource_group }     # storage_accounts.storage_accounts.cluster_witness.resource_group
$witSubRaw       = if ($WitnessSubscription  -ne "") { $WitnessSubscription }  else { $cfg.storage_accounts.storage_accounts.cluster_witness.subscription }       # storage_accounts.storage_accounts.cluster_witness.subscription
# Resolve subscription key reference (e.g. "lab") to actual subscription ID via azure_platform.subscriptions.<key>.id
$resolvedWitSub  = if ($witSubRaw -and $cfg.azure_platform.subscriptions -and $cfg.azure_platform.subscriptions[$witSubRaw]) {
    $cfg.azure_platform.subscriptions[$witSubRaw].id
} else {
    $witSubRaw
}
$resolvedWitSku  = if ($WitnessSku           -ne "") { $WitnessSku }           else { $cfg.storage_accounts.storage_accounts.cluster_witness.sku }                # storage_accounts.storage_accounts.cluster_witness.sku
$resolvedFsPath  = if ($FileSharePath        -ne "") { $FileSharePath }        else { $cfg.compute.azure_local.PSObject.Properties['cluster_witness_file_share_path']?.Value }  # compute.azure_local.cluster_witness_file_share_path (optional)
$witnessRegion   = $cfg.azure_platform.region                                                       # azure_platform.region

$lcmUser    = $cfg.identity.accounts.account_lcm_username          # identity.accounts.account_lcm_username
$lcmPassUri = $cfg.identity.accounts.account_lcm_password          # identity.accounts.account_lcm_password
$localUser  = $cfg.identity.accounts.account_local_admin_username  # identity.accounts.account_local_admin_username
$localPassUri=$cfg.identity.accounts.account_local_admin_password  # identity.accounts.account_local_admin_password
$netbios    = $cfg.identity.active_directory.ad_netbios_name        # identity.active_directory.ad_netbios_name

# ── Determine target node ─────────────────────────────────────────────────────
$nodeIp = $null
if ($TargetNode.Count -gt 0) {
    $nodeIp = $TargetNode[0]
    Write-Log "Target node (override): $nodeIp"
} else {
    $firstNode = $cfg.compute.cluster_nodes.GetEnumerator() | Select-Object -First 1  # compute.cluster_nodes
    if (-not $firstNode) { throw "No nodes found under compute.cluster_nodes in $configFile." }
    $nodeIp = $firstNode.Value.management_ip
    Write-Log "Target node (first from config): $($firstNode.Key) @ $nodeIp"
}

Write-Log "Cluster      : $clusterName"
Write-Log "Witness type : $resolvedWitType"
Write-Log "Node IP      : $nodeIp"

# ── WhatIf guard ──────────────────────────────────────────────────────────────
if ($WhatIf) {
    Write-Log "[WhatIf] Would configure '$resolvedWitType' quorum on cluster '$clusterName' via node '$nodeIp'" 'WARN'
    if ($resolvedWitType -eq 'cloud_witness') {
        Write-Log "[WhatIf] Would validate/create storage account '$resolvedAcctName' in RG '$resolvedWitRg' (sub: $resolvedWitSub)" 'WARN'
    } elseif ($resolvedWitType -eq 'file_share_witness') {
        Write-Log "[WhatIf] Would set file share witness: $resolvedFsPath" 'WARN'
    }
    Write-Log "WhatIf complete — no changes made" 'WARN'
    return
}

# ── Credential resolution ─────────────────────────────────────────────────────
# Try local admin first (works on non-domain / pre-domain nodes).
# If PSRemoting with local admin fails at runtime, the invoke block retries with LCM.
$remoteCred = $null
$lcmCred    = $null

if ($Credential) {
    $remoteCred = $Credential
    Write-Log "Credentials supplied via -Credential parameter."
} else {
    Write-Log "Resolving local admin credentials from Key Vault..."
    $localPass = Resolve-KeyVaultRef -KvUri $localPassUri
    if ($localPass) {
        $remoteCred = New-Object PSCredential($localUser, (ConvertTo-SecureString $localPass -AsPlainText -Force))
        Write-Log "Local admin credentials resolved: $localUser" 'SUCCESS'
    } else {
        Write-Log "Local admin Key Vault lookup failed." 'WARN'
    }

    Write-Log "Resolving LCM domain credentials from Key Vault (fallback)..."
    $lcmPass = Resolve-KeyVaultRef -KvUri $lcmPassUri
    if ($lcmPass) {
        $domainUser = "$netbios\$lcmUser"
        $lcmCred = New-Object PSCredential($domainUser, (ConvertTo-SecureString $lcmPass -AsPlainText -Force))
        Write-Log "LCM credentials resolved: $domainUser" 'SUCCESS'
    } else {
        Write-Log "LCM Key Vault lookup failed." 'WARN'
    }

    if (-not $remoteCred -and -not $lcmCred) {
        Write-Log "Key Vault unavailable for both accounts — prompting for credentials." 'WARN'
        $remoteCred = Get-Credential -Message "Enter credentials for cluster node $nodeIp" -UserName $localUser
    }
}

# ── Cloud Witness: validate or create storage account ─────────────────────────
$witnessKey = $null

if ($resolvedWitType -eq 'cloud_witness') {
    Write-Log "--- Step 1: Validate cloud witness storage account" 'HEADER'

    if (-not (Get-Module -Name Az.Storage -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Log "Installing Az.Storage module..." 'WARN'
        Install-Module -Name Az.Storage -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Az.Accounts, Az.Storage -ErrorAction Stop

    $ctx = Get-AzContext
    if (-not $ctx) {
        Write-Log "Not authenticated to Azure — run Connect-AzAccount first" 'ERROR'
        throw "Azure authentication required for cloud_witness"
    }
    Write-Log "Azure context: $($ctx.Account.Id) / $($ctx.Subscription.Name)"

    if ($resolvedWitSub) {
        Write-Log "Setting subscription context: $resolvedWitSub"
        Set-AzContext -Subscription $resolvedWitSub | Out-Null
    }

    Write-Log "Checking storage account: $resolvedAcctName (RG: $resolvedWitRg)"
    $sa = Get-AzStorageAccount -ResourceGroupName $resolvedWitRg -Name $resolvedAcctName -ErrorAction SilentlyContinue

    if (-not $sa) {
        Write-Log "Storage account not found — creating '$resolvedAcctName'" 'WARN'
        Write-Log "  Resource Group : $resolvedWitRg"
        Write-Log "  Region         : $witnessRegion"
        Write-Log "  SKU            : $resolvedWitSku"

        $sa = New-AzStorageAccount `
            -ResourceGroupName      $resolvedWitRg `
            -Name                   $resolvedAcctName `
            -Location               $witnessRegion `
            -SkuName                $resolvedWitSku `
            -Kind                   'StorageV2' `
            -AccessTier             'Hot' `
            -EnableHttpsTrafficOnly $true `
            -MinimumTlsVersion      'TLS1_2' `
            -AllowBlobPublicAccess  $false

        Write-Log "Storage account created: $($sa.Id)" 'SUCCESS'
    } else {
        Write-Log "Storage account exists: $($sa.Id)" 'SUCCESS'
    }

    Write-Log "Retrieving storage account key..."
    $keys = Get-AzStorageAccountKey -ResourceGroupName $resolvedWitRg -Name $resolvedAcctName
    $witnessKey = $keys[0].Value
    Write-Log "Storage account key retrieved" 'SUCCESS'
}

# ── Configure quorum ─────────────────────────────────────────────────────────
# Set-ClusterQuorum supports -Cluster <name> for direct RPC from a management machine.
# This avoids PSRemoting double-hop (Kerberos can't re-delegate inside a remote session,
# causing "no administrative privileges" even when the account has cluster admin rights).
# Try to install FailoverClusters RSAT locally if missing, then run via RPC.

Write-Log "--- Step 2: Configure cluster quorum" 'HEADER'

$result = $null
$localFCAvailable = Get-Module -Name FailoverClusters -ListAvailable -ErrorAction SilentlyContinue

if ($localFCAvailable) {
    Write-Log "FailoverClusters module available locally — configuring quorum via direct RPC (no PSRemoting)"
    Import-Module FailoverClusters -ErrorAction Stop

    $log = [System.Collections.Generic.List[string]]::new()
    try {
        switch ($resolvedWitType) {
            'cloud_witness' {
                if (-not $resolvedAcctName -or -not $witnessKey) {
                    throw "cloud_witness requires AccountName and AccountKey"
                }
                Set-ClusterQuorum -Cluster $clusterName -CloudWitness -AccountName $resolvedAcctName -AccessKey $witnessKey -Endpoint "core.windows.net" -ErrorAction Stop
                $log.Add("Set-ClusterQuorum: cloud_witness configured (account: $resolvedAcctName)")
            }
            'file_share_witness' {
                if (-not $resolvedFsPath) {
                    throw "file_share_witness requires FileSharePath"
                }
                Set-ClusterQuorum -Cluster $clusterName -FileShareWitness $resolvedFsPath -ErrorAction Stop
                $log.Add("Set-ClusterQuorum: file_share_witness configured (path: $resolvedFsPath)")
            }
            'disk_witness' {
                throw "disk_witness requires a pre-existing shared disk cluster resource — use Set-ClusterQuorum -DiskWitness manually"
            }
            default {
                throw "Unknown WitnessType '$resolvedWitType' — expected cloud_witness, file_share_witness, or disk_witness"
            }
        }

        $quorum = Get-ClusterQuorum -Cluster $clusterName
        $result = [PSCustomObject]@{
            Success        = $true
            QuorumType     = [string]$quorum.QuorumType
            QuorumResource = if ($quorum.QuorumResource) { [string]$quorum.QuorumResource.Name } else { "(none)" }
            QuorumState    = [string](Get-Cluster -Name $clusterName).QuorumState
            Log            = $log
        }
    } catch {
        $result = [PSCustomObject]@{
            Success        = $false
            Error          = $_.Exception.Message
            QuorumType     = $null
            QuorumResource = $null
            QuorumState    = $null
            Log            = $log
        }
    }
} else {
    Write-Log "FailoverClusters not available locally — using PSRemoting" 'WARN'

    $invokeBlock = {
        param($Cluster, $WType, $AccountName, $AccountKey, $SharePath)

        $log = [System.Collections.Generic.List[string]]::new()
        try {
            Import-Module FailoverClusters -ErrorAction Stop
            $log.Add("FailoverClusters module loaded on $env:COMPUTERNAME")

            switch ($WType) {
                'cloud_witness' {
                    if (-not $AccountName -or -not $AccountKey) { throw "cloud_witness requires AccountName and AccountKey" }
                    Set-ClusterQuorum -CloudWitness -AccountName $AccountName -AccessKey $AccountKey -Endpoint "core.windows.net" -ErrorAction Stop | Out-Null
                    $log.Add("Set-ClusterQuorum: cloud_witness configured (account: $AccountName)")
                }
                'file_share_witness' {
                    if (-not $SharePath) { throw "file_share_witness requires FileSharePath" }
                    Set-ClusterQuorum -FileShareWitness $SharePath -ErrorAction Stop | Out-Null
                    $log.Add("Set-ClusterQuorum: file_share_witness configured (path: $SharePath)")
                }
                'disk_witness' {
                    throw "disk_witness requires a pre-existing shared disk cluster resource — use Set-ClusterQuorum -DiskWitness manually"
                }
                default {
                    throw "Unknown WitnessType '$WType' — expected cloud_witness, file_share_witness, or disk_witness"
                }
            }

            $quorum = Get-ClusterQuorum
            return [PSCustomObject]@{
                Success        = $true
                QuorumType     = [string]$quorum.QuorumType
                QuorumResource = if ($quorum.QuorumResource) { [string]$quorum.QuorumResource.Name } else { "(none)" }
                QuorumState    = [string](Get-Cluster).QuorumState
                Log            = $log
            }
        } catch {
            return [PSCustomObject]@{
                Success        = $false
                Error          = $_.Exception.Message
                QuorumType     = $null
                QuorumResource = $null
                QuorumState    = $null
                Log            = $log
            }
        }
    }

    # Try local admin first; retry with LCM domain account if access denied
    $credentialsToTry = @()
    if ($remoteCred) { $credentialsToTry += @{ Label = $remoteCred.UserName; Cred = $remoteCred } }
    if ($lcmCred)    { $credentialsToTry += @{ Label = $lcmCred.UserName;    Cred = $lcmCred    } }

    $result = $null
    $rawResult = $null
    foreach ($attempt in $credentialsToTry) {
        Write-Log "Connecting to $nodeIp as $($attempt.Label)..."
        try {
            $rawResult = Invoke-Command -ComputerName $nodeIp -Credential $attempt.Cred -ScriptBlock $invokeBlock -ArgumentList $clusterName, $resolvedWitType, $resolvedAcctName, $witnessKey, $resolvedFsPath
            # Extract our PSCustomObject in case Set-ClusterQuorum also emitted pipeline output
            $result = @($rawResult) | Where-Object { $_.PSObject.Properties['Success'] } | Select-Object -Last 1
            Write-Log "PSRemoting succeeded with $($attempt.Label)" 'SUCCESS'
            break
        } catch {
            if ($_.Exception.Message -match 'Access is denied|Access denied|AuthenticationException|LogonFailure') {
                Write-Log "Access denied with $($attempt.Label) — trying next credential..." 'WARN'
            } else {
                throw
            }
        }
    }

    if (-not $result) {
        throw "PSRemoting to $nodeIp failed with all available credentials"
    }
}

# ── Results ───────────────────────────────────────────────────────────────────
if ($result.Log) { foreach ($line in $result.Log) { Write-Log $line } }

if ($result.Success) {
    Write-Log "Quorum configured successfully" 'SUCCESS'
    Write-Log "  Quorum Type    : $($result.QuorumType)"
    Write-Log "  Quorum Resource: $($result.QuorumResource)"
    Write-Log "  Quorum State   : $($result.QuorumState)"

    if ($result.QuorumState -ne 'Normal') {
        Write-Log "Quorum state is '$($result.QuorumState)' — expected 'Normal'; check cluster events" 'WARN'
    }
} else {
    Write-Log "Quorum configuration failed: $($result.Error)" 'ERROR'
    throw $result.Error
}

Write-Log "=== Task 02 complete ===" 'HEADER'

return [PSCustomObject]@{
    Cluster        = $clusterName
    WitnessType    = $resolvedWitType
    QuorumType     = $result.QuorumType
    QuorumResource = $result.QuorumResource
    QuorumState    = $result.QuorumState
    Success        = $result.Success
}

#endregion MAIN
