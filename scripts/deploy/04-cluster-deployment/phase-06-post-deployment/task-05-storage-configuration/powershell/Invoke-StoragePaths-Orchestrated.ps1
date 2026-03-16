#Requires -Version 7.0
<#
.SYNOPSIS
    Registers Azure Local storage paths in Azure from infrastructure.yml.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 05 — Storage Configuration (Section 3)

    Reads cluster_shared_volumes.storage_paths from infrastructure.yml and
    registers each entry as an Azure storage path resource using:
        az stack-hci-vm storagepath create

    No PS Remoting required — all operations are Azure control-plane calls
    via az CLI from the management server.

.PARAMETER ConfigPath
    Path to infrastructure YAML. Defaults to configs/infrastructure.yml in CWD.

.PARAMETER Credential
    Not used for storage path registration (Azure CLI handles auth via az login).
    Included to satisfy the mandatory Invoke- script parameter contract.

.PARAMETER TargetNode
    Not applicable for this task — storage paths are cluster-scoped Azure resources.
    Included to satisfy the mandatory Invoke- script parameter contract.

.PARAMETER WhatIf
    Log planned az CLI commands without executing them.

.PARAMETER LogPath
    Override log directory. Default: logs\task-05-storage-paths\ in CWD.

.NOTES
    Run from the repo root.
    Requires: az CLI logged in with Contributor on the cluster resource group.
    Requires: az extension add --name stack-hci-vm
    Requires: powershell-yaml module  (Install-Module powershell-yaml)
#>

[CmdletBinding()]
param(
    [string]      $ConfigPath  = "",
    [PSCredential]$Credential  = $null,
    [string[]]    $TargetNode  = @(),
    [switch]      $WhatIf,
    [string]      $LogPath     = ""
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

$resourceGroup        = $cfg.compute.azure_local.arc_resource_group           # compute.azure_local.arc_resource_group
$subscriptionId       = $cfg.azure_platform.subscriptions.lab.id                 # azure_platform.subscriptions.lab.id
$location             = $cfg.azure_platform.region                               # azure_platform.region
$customLocationName   = $cfg.compute.azure_local.azure_custom_location_name      # compute.azure_local.azure_custom_location_name
$customLocation       = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ExtendedLocation/customLocations/$customLocationName"
$csvConfig            = $cfg.compute.cluster_shared_volumes                      # compute.cluster_shared_volumes

if (-not $csvConfig.enabled) {
    Write-Log "cluster_shared_volumes.enabled is false — nothing to do." -Level "WARN"
    exit 0
}

$storagePaths = $csvConfig.storage_paths.GetEnumerator()             # cluster_shared_volumes.storage_paths

Write-Log "Resource group  : $resourceGroup"
Write-Log "Location        : $location"
Write-Log "Custom location : $customLocation"
Write-Log "WhatIf          : $WhatIf"
#endregion

#region PREREQ CHECK ------------------------------------------------------------
Write-Log "Verifying az CLI and stack-hci-vm extension..."

$azAccount = az account show --query name -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "az CLI not logged in. Run: az login" "FAIL"; throw "az CLI auth required"
}
Write-Log "Azure account: $azAccount" "PASS"

$extCheck = az extension list --query "[?name=='stack-hci-vm'].name" -o tsv 2>$null
if ([string]::IsNullOrEmpty($extCheck)) {
    Write-Log "stack-hci-vm extension not installed. Installing..." -Level "WARN"
    if (-not $WhatIf) {
        az extension add --name stack-hci-vm --yes 2>&1 | Out-Null
        Write-Log "Extension installed" "PASS"
    }
}
#endregion

#region STORAGE PATH REGISTRATION -----------------------------------------------
foreach ($entry in $storagePaths) {
    $pathKey  = $entry.Key
    $pathName = $entry.Value.name   # cluster_shared_volumes.storage_paths.<key>.name
    $pathVal  = $entry.Value.path   # cluster_shared_volumes.storage_paths.<key>.path

    Write-Log "Storage path [$pathKey]: $pathName  →  $pathVal"

    if ($WhatIf) {
        Write-Log "  [WhatIf] az stack-hci-vm storagepath create --name $pathName --path $pathVal" -Level "WARN"
        continue
    }

    # Check if already exists
    $existing = az stack-hci-vm storagepath show `
        --resource-group $resourceGroup `
        --name           $pathName `
        --query          "provisioningState" `
        -o tsv 2>$null

    if ($existing -eq "Succeeded") {
        Write-Log "  Already registered (Succeeded) — skipping" -Level "WARN"
        continue
    }

    try {
        az stack-hci-vm storagepath create `
            --resource-group  $resourceGroup `
            --custom-location $customLocation `
            --location        $location `
            --name            $pathName `
            --path            $pathVal `
            --output          none `
            2>&1 | ForEach-Object { Write-Log "  az: $_" }

        if ($LASTEXITCODE -eq 0) {
            Write-Log "  Registered successfully" "PASS"
        } else {
            Write-Log "  az CLI returned non-zero exit code" "FAIL"
        }
    }
    catch {
        Write-Log "  Failed: $_" "FAIL"
    }
}
#endregion

Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Log "Done. Proceed to Section 4 to validate." "PASS"
Write-Log "Log: $logFile"
