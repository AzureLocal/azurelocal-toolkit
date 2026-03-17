#Requires -Version 7.0
<#
.SYNOPSIS
    Creates S2D CSV volumes on the Azure Local cluster via PS Remoting.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 05 — Storage Configuration (Section 2)

    Reads cluster_shared_volumes.volumes[] from infrastructure.yml and creates
    each defined volume via Invoke-Command to the cluster VIP. New-Volume is
    executed remotely so it has direct access to the S2D storage pool.

    Credential resolution order:
      1. -Credential parameter (if passed)
      2. Key Vault  (identity.accounts.account_local_admin_username/password)
      3. Interactive Get-Credential prompt

.PARAMETER ConfigPath
    Path to infrastructure YAML. Defaults to config/infrastructure.yml in CWD.

.PARAMETER Credential
    Override credential resolution — skips Key Vault and prompt.

.PARAMETER TargetNode
    Specific node hostname to remote into for volume creation. If empty, the
    script remotes to the cluster VIP (recommended — cluster handles routing).

.PARAMETER WhatIf
    Log planned actions without making any changes.

.PARAMETER LogPath
    Override log directory. Default: logs\task-05-storage-csv\ in CWD.

.PARAMETER StoragePoolName
    Override S2D pool name. Default: auto-derived as "S2D on <cluster_name>".

.NOTES
    Run from the repo root.
    Requires: FailoverClusters + Storage RSAT features on management server,
              or PS Remoting will carry them from the cluster node.
    Requires: powershell-yaml module  (Install-Module powershell-yaml)
#>

[CmdletBinding()]
param(
    [string]      $ConfigPath      = "",
    [PSCredential]$Credential      = $null,
    [string[]]    $TargetNode      = @(),
    [switch]      $WhatIf,
    [string]      $LogPath         = "",
    [string]      $StoragePoolName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region LOGGING -----------------------------------------------------------------
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
#endregion

#region CONFIG LOADING ----------------------------------------------------------
if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path (Get-Location).Path "configs\infrastructure.yml"
}
if (-not (Test-Path $ConfigPath)) {
    Write-Log "Config not found: $ConfigPath" "FAIL"; throw "Config not found"
}

Import-Module powershell-yaml -ErrorAction Stop
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

$clusterName    = $cfg.compute.azure_local.cluster_name          # compute.azure_local.cluster_name
$csvConfig      = $cfg.compute.cluster_shared_volumes             # compute.cluster_shared_volumes

# Sorted node hostnames for CSV ownership balancing (node01 → node02 → …)
$nodeHostnames  = $cfg.compute.cluster_nodes.GetEnumerator() |
    Sort-Object Key |
    ForEach-Object { $_.Value.hostname }                          # compute.cluster_nodes.<key>.hostname

if (-not $csvConfig.enabled) {
    Write-Log "cluster_shared_volumes.enabled is false — nothing to do." "WARN"
    exit 0
}

$volumes = $csvConfig.volumes                                    # compute.cluster_shared_volumes.volumes[]

# Resolve storage pool name: param override → config → default
if ([string]::IsNullOrEmpty($StoragePoolName)) {
    if (-not [string]::IsNullOrEmpty($csvConfig.storage_pool_name)) {
        $StoragePoolName = $csvConfig.storage_pool_name          # compute.cluster_shared_volumes.storage_pool_name
    } else {
        $StoragePoolName = "S2D on $clusterName"
    }
}

Write-Log "Cluster      : $clusterName"
Write-Log "Storage pool : $StoragePoolName"
Write-Log "Volumes      : $($volumes.Count) defined"
Write-Log "Nodes        : $($nodeHostnames -join ', ')"
Write-Log "WhatIf       : $WhatIf"
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
#endregion

#region VOLUME CREATION ---------------------------------------------------------
# Remote target: cluster VIP by default (unless -TargetNode was passed)
$remoteTarget = if ($TargetNode.Count -gt 0) { $TargetNode[0] } else { $clusterName }
Write-Log "Remote target: $remoteTarget"

$credParam = @{ Credential = $Credential }

foreach ($vol in $volumes) {
    $volName    = $vol.volume_name     # cluster_shared_volumes.volumes[].volume_name
    $sizeGB     = $vol.size_gb         # cluster_shared_volumes.volumes[].size_gb
    $fsType     = if ($vol.filesystem -eq "ReFS") { "CSVFS_ReFS" } else { "CSVFS_NTFS" }
    $resiliency = $vol.resiliency      # cluster_shared_volumes.volumes[].resiliency

    Write-Log "Volume: $volName  ($sizeGB GB  $resiliency  $($vol.filesystem))"

    if ($WhatIf) {
        Write-Log "  [WhatIf] Would create via New-Volume on $remoteTarget" -Level "WARN"
        continue
    }

    try {
        $result = Invoke-Command -ComputerName $remoteTarget @credParam -ScriptBlock {
            param($VolName, $SizeGB, $Resiliency, $FsType, $PoolName)

            $existing = Get-VirtualDisk -FriendlyName $VolName -ErrorAction SilentlyContinue
            if ($existing) { return "EXISTS:$($existing.OperationalStatus)" }

            New-Volume `
                -FriendlyName            $VolName `
                -StoragePoolFriendlyName $PoolName `
                -Size                    ($SizeGB * 1GB) `
                -ProvisioningType        Thin `
                -ResiliencySettingName   $Resiliency `
                -FileSystem              $FsType `
                -ErrorAction             Stop | Out-Null

            return "CREATED"
        } -ArgumentList $volName, $sizeGB, $resiliency, $fsType, $StoragePoolName

        if ($result -like "EXISTS:*") {
            Write-Log "  Already exists ($($result -replace 'EXISTS:','')) — skipped" -Level "WARN"
        } else {
            Write-Log "  Created successfully" "PASS"
        }
    }
    catch {
        Write-Log "  Failed: $_" "FAIL"
    }
}
#endregion

#region CSV OWNERSHIP BALANCING -------------------------------------------------
Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "HEADER"
Write-Log "Balancing CSV ownership across nodes..." "HEADER"

for ($i = 0; $i -lt $volumes.Count; $i++) {
    $volName    = $volumes[$i].volume_name
    $ownerNode  = $nodeHostnames[$i % $nodeHostnames.Count]
    $csvResName = "Cluster Virtual Disk ($volName)"

    Write-Log "[$volName]  →  target owner: $ownerNode"

    if ($WhatIf) {
        Write-Log "  [WhatIf] Would move '$csvResName' to $ownerNode" "WARN"
        continue
    }

    try {
        $moveResult = Invoke-Command -ComputerName $remoteTarget @credParam -ScriptBlock {
            param($CsvResName, $OwnerNode)
            $csv = Get-ClusterSharedVolume -Name $CsvResName -ErrorAction SilentlyContinue
            if (-not $csv) { return "NOTFOUND" }
            if ($csv.OwnerNode.Name -eq $OwnerNode) { return "ALREADY:$OwnerNode" }
            Move-ClusterSharedVolume -Name $CsvResName -Node $OwnerNode -ErrorAction Stop | Out-Null
            return "MOVED:$OwnerNode"
        } -ArgumentList $csvResName, $ownerNode

        switch -Wildcard ($moveResult) {
            "NOTFOUND"  { Write-Log "  CSV resource not found — may still be coming online" "WARN" }
            "ALREADY:*" { Write-Log "  Already owned by $ownerNode — skipped" "WARN" }
            "MOVED:*"   { Write-Log "  Ownership moved to $ownerNode" "PASS" }
        }
    }
    catch {
        Write-Log "  Move failed: $_" "FAIL"
    }
}
#endregion
Write-Log "Done. Proceed to Section 3 to register storage paths in Azure." "PASS"
Write-Log "Log: $logFile"
