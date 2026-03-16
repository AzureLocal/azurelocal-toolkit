<#
.SYNOPSIS
    Get-HciResourceProviderObjectId.ps1
    Retrieves the Microsoft.AzureStackHCI resource provider service principal Object ID
    and updates infrastructure.yml with the value.

.DESCRIPTION
    Config-driven script (Option 2). Reads infrastructure.yml, looks up the
    Microsoft.AzureStackHCI resource provider's service principal Object ID from
    Entra ID, and writes it back to the config file at
    cluster_arm_deployment.resource_provider_object_id.

    infrastructure.yml paths used:
      cluster_arm_deployment.resource_provider_object_id  - Target field to update

    Requires:
      - Az.Resources module (Get-AzADServicePrincipal)
      - Authenticated Azure session (Connect-AzAccount)

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-discovers infrastructure*.yml if not provided.

.PARAMETER UpdateConfig
    When specified, writes the Object ID back to infrastructure.yml.
    Without this switch, the script only displays the value.

.EXAMPLE
    .\Get-HciResourceProviderObjectId.ps1 -ConfigPath .\configs\infrastructure.yml

.EXAMPLE
    .\Get-HciResourceProviderObjectId.ps1 -ConfigPath .\configs\infrastructure.yml -UpdateConfig

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-01-initiate-deployment-via-arm-template (HCI RP Object ID lookup)
    Execution:    Run from management/jump box
    Script Type:  Config-driven (Option 2 — Azure PowerShell)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$UpdateConfig
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
        (Join-Path (Get-Location).Path "configs"),
        (Join-Path $PSScriptRoot "..\..\..\..\..\..\..\..\configs"),
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

#endregion HELPERS

#region LOGGING

$taskFolderName = "task-01-initiate-deployment-via-arm-template"
$logDir         = Join-Path (Get-Location).Path "logs\$taskFolderName"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$script:LogFile = Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd')_$(Get-Date -Format 'HHmmss')_Get-HciRPObjectId.log"

#endregion LOGGING

#region MAIN

Write-Log "========================================" "HEADER"
Write-Log " Get HCI Resource Provider Object ID"     "HEADER"
Write-Log "========================================" "HEADER"

# --- Resolve config ---
$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Using config: $configFile"

# --- Verify Azure context ---
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    throw "Not authenticated to Azure. Run Connect-AzAccount first."
}
Write-Log "Azure context: $($ctx.Account.Id) / Tenant: $($ctx.Tenant.Id)"

# --- Lookup HCI Resource Provider SP ---
Write-Log "Looking up Microsoft.AzureStackHCI Resource Provider service principal..."
$hciRP = Get-AzADServicePrincipal -DisplayName "Microsoft.AzureStackHCI Resource Provider" -ErrorAction Stop

if (-not $hciRP) {
    Write-Log "Microsoft.AzureStackHCI Resource Provider not found in this tenant." "ERROR"
    throw "HCI RP service principal not found. Ensure Azure Local resource provider is registered."
}

$objectId = $hciRP.Id
Write-Log "HCI Resource Provider Object ID: $objectId" "SUCCESS"

# --- Update config if requested ---
if ($UpdateConfig) {
    Write-Log "Updating infrastructure.yml at cluster_arm_deployment.resource_provider_object_id..."

    $content = Get-Content -Path $configFile -Raw
    $pattern = '(?m)(^\s*resource_provider_object_id:\s*)"[^"]*"'
    if ($content -match $pattern) {
        $updated = $content -replace $pattern, "`$1`"$objectId`""
        Set-Content -Path $configFile -Value $updated -NoNewline
        Write-Log "Updated $configFile with Object ID: $objectId" "SUCCESS"
    }
    else {
        Write-Log "Could not find resource_provider_object_id field in $configFile. Update manually." "WARN"
        Write-Log "  YAML path: cluster_arm_deployment.resource_provider_object_id" "WARN"
        Write-Log "  Value:     $objectId" "WARN"
    }
}
else {
    Write-Log ""
    Write-Log "To update infrastructure.yml, re-run with -UpdateConfig:" "INFO"
    Write-Log "  .\Get-HciResourceProviderObjectId.ps1 -ConfigPath `"$configFile`" -UpdateConfig" "INFO"
    Write-Log ""
    Write-Log "Or set manually in infrastructure.yml:" "INFO"
    Write-Log "  YAML path: cluster_arm_deployment.resource_provider_object_id" "INFO"
    Write-Log "  Value:     $objectId" "INFO"
}

Write-Log "========================================" "HEADER"
Write-Log " Complete" "HEADER"
Write-Log "========================================" "HEADER"
Write-Log "Log: $($script:LogFile)"

#endregion MAIN
