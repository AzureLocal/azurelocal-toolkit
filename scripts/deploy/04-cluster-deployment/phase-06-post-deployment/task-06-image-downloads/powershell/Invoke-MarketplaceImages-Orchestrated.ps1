#Requires -Version 7.0
<#
.SYNOPSIS
    Orchestrated: downloads all marketplace_images entries from infrastructure.yml
    to the Azure Local cluster as gallery images.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 06 — VM Image Downloads

    Reads each image definition from marketplace_images.images[] and calls
    az stack-hci-vm image create for each one. Images that already exist are
    skipped. Supports -WhatIf for dry-run validation.

.PARAMETER ConfigPath
    Path to infrastructure YAML. Defaults to configs\infrastructure.yml in CWD.

.PARAMETER Credential
    Not used for image creation (uses current az CLI / Az PowerShell session).
    Included for parameter contract compliance.

.PARAMETER TargetNode
    Not used for image creation (ARM operation — no PSRemoting).
    Included for parameter contract compliance.

.PARAMETER WhatIf
    Log planned actions without making any changes.

.PARAMETER LogPath
    Override log directory. Default: logs\task-06-image-downloads\ in CWD.

.EXAMPLE
    # From the toolkit repo root — dry-run first:
    .\scripts\deploy\04-cluster-deployment\phase-06-post-deployment\task-06-image-downloads\powershell\Invoke-MarketplaceImages-Orchestrated.ps1 -WhatIf

.EXAMPLE
    # Full run:
    .\scripts\...\Invoke-MarketplaceImages-Orchestrated.ps1

.EXAMPLE
    # Explicit config path:
    .\scripts\...\Invoke-MarketplaceImages-Orchestrated.ps1 -ConfigPath configs\infrastructure-iic01.yml

.NOTES
    Run from the toolkit repo root.
    Requires: az CLI authenticated (az login) and stack-hci-vm extension installed.
              Run: az extension add --name stack-hci-vm
    Requires: powershell-yaml module  (Install-Module powershell-yaml -Scope CurrentUser)
#>

[CmdletBinding()]
param(
    [string]      $ConfigPath = "",
    [PSCredential]$Credential = $null,
    [string[]]    $TargetNode = @(),
    [switch]      $WhatIf,
    [string]      $LogPath    = ""
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
        "DEBUG"   { Write-Debug   "[$ts] $Message" }
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

$imgConfig = $cfg.marketplace_images                             # marketplace_images

if (-not $imgConfig.enabled) {
    Write-Log "marketplace_images.enabled is false — nothing to do." "WARN"
    exit 0
}

$images           = $imgConfig.images                                         # marketplace_images.images[]
$subscriptionId   = $cfg.azure_platform.subscriptions.lab.id                  # azure_platform.subscriptions.lab.id
$resourceGroup    = $cfg.compute.azure_local.arc_resource_group               # compute.azure_local.arc_resource_group
$location         = $cfg.azure_platform.region                                # azure_platform.region
$customLocName    = $cfg.compute.azure_local.azure_custom_location_name       # compute.azure_local.azure_custom_location_name

$customLocationId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup" +
                    "/providers/Microsoft.ExtendedLocation/customLocations/$customLocName"

Write-Log "Subscription    : $subscriptionId"
Write-Log "Resource group  : $resourceGroup"
Write-Log "Location        : $location"
Write-Log "Custom location : $customLocName"
Write-Log "Images defined  : $($images.Count)"
Write-Log "WhatIf          : $WhatIf"
#endregion

#region VERSION RESOLUTION ------------------------------------------------------
# Resolve the real latest version from Azure Marketplace for any image with version = "latest"
# Updates the config file in place so the pinned version is recorded.
Write-Log "Resolving image versions from Azure Marketplace..." "HEADER"
$resolvedImages = foreach ($img in $images) {
    if (-not $img.version -or $img.version -eq "latest") {
        Write-Log "  [$($img.name)] Querying latest version for $($img.publisher)/$($img.offer)/$($img.sku)..."
        $latestVer = az vm image list `
            --location  $location `
            --publisher $img.publisher `
            --offer     $img.offer `
            --sku       $img.sku `
            --all       `
            --query     "[-1].version" `
            -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($latestVer)) {
            Write-Log "  [$($img.name)] Could not resolve version — will pass version omitted" "WARN"
            $img.version = ""
        } else {
            $latestVer = $latestVer.Trim()
            Write-Log "  [$($img.name)] Resolved version: $latestVer" "PASS"
            # Update config file with resolved version
            $configContent = Get-Content $ConfigPath -Raw
            $escapedName   = [regex]::Escape($img.name)
            $configContent = $configContent -replace `
                "(?s)(name:\s*`"$escapedName`"(?:(?!- name:).)*?version:\s*)`"[^`"]*`"", `
                "`${1}`"$latestVer`""
            Set-Content -Path $ConfigPath -Value $configContent -Encoding utf8 -NoNewline
            $img.version = $latestVer
        }
    } else {
        Write-Log "  [$($img.name)] Using pinned version: $($img.version)"
    }
    $img
}
Write-Log "Version resolution complete."
#endregion

#region IMAGE CREATION (PARALLEL) -----------------------------------------------
# All images are independent ARM operations — run in parallel with a mutex for log safety
$logMutex = [System.Threading.Mutex]::new($false, "ImageLogMutex")

$resolvedImages | ForEach-Object -Parallel {
    $img             = $_
    $imgName         = $img.name
    $publisher       = $img.publisher
    $offer           = $img.offer
    $sku             = $img.sku
    $version         = if ($img.version) { $img.version } else { "latest" }
    $osType          = $img.os_type
    $subscriptionId  = $using:subscriptionId
    $resourceGroup   = $using:resourceGroup
    $location        = $using:location
    $customLocationId = $using:customLocationId
    $WhatIf          = $using:WhatIf
    $logFile         = $using:logFile
    $mutex           = $using:logMutex

    function Write-PLog {
        param([string]$Message, [string]$Level = "INFO")
        $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "[$ts] [$Level] [$imgName] $Message"
        $mutex.WaitOne() | Out-Null
        try { $line | Out-File -FilePath $logFile -Append -Encoding utf8 }
        finally { $mutex.ReleaseMutex() }
        switch ($Level) {
            "PASS" { Write-Host $line -ForegroundColor Green }
            "FAIL" { Write-Host $line -ForegroundColor Red }
            "WARN" { Write-Host $line -ForegroundColor Yellow }
            default { Write-Host $line }
        }
    }

    Write-PLog "Starting: $publisher / $offer / $sku / $version [$osType]"

    if ($WhatIf) {
        Write-PLog "  [WhatIf] Would create gallery image '$imgName'" "WARN"
        return
    }

    # Check if already exists
    $existing = az stack-hci-vm image show `
        --subscription   $subscriptionId `
        --resource-group $resourceGroup `
        --name           $imgName `
        --query          "properties.provisioningState" `
        -o tsv 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($existing)) {
        if ($existing -eq "Succeeded") {
            Write-PLog "Already exists (Succeeded) — skipped" "WARN"
            return
        }
        if ($existing -ne "Failed") {
            Write-PLog "Already in progress (state: $existing) — skipped" "WARN"
            return
        }
        # Only delete if Failed
        Write-PLog "Exists in state 'Failed' — deleting to recreate..." "WARN"
        az stack-hci-vm image delete `
            --subscription   $subscriptionId `
            --resource-group $resourceGroup `
            --name           $imgName `
            --yes 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-PLog "Delete failed — aborting" "FAIL"; return }
        Write-PLog "Deleted failed resource" "WARN"
    }

    try {
        Write-PLog "Creating image (15–30 minutes)..."

        # Build args — no --subscription per MS docs; explicit --version always passed
        $azArgs = @(
            "stack-hci-vm", "image", "create",
            "--resource-group",  $resourceGroup,
            "--custom-location", $customLocationId,
            "--name",            $imgName,
            "--os-type",         $osType,
            "--offer",           $offer,
            "--publisher",       $publisher,
            "--sku",             $sku,
            "--version",         $version,
            "--output",          "none"
        )

        $output = & az @azArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
        Write-PLog "Created successfully" "PASS"
    }
    catch {
        Write-PLog "Failed: $_" "FAIL"
    }
} -ThrottleLimit $images.Count

$logMutex.Dispose()
#endregion

Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Log "Done. Validate with: az stack-hci-vm image list --resource-group $resourceGroup" "PASS"
Write-Log "Log: $logFile"
