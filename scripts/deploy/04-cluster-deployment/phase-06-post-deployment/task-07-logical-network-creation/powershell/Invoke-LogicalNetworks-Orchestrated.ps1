#Requires -Version 7.0
<#
.SYNOPSIS
    Orchestrated: creates all logical networks defined in infrastructure.yml.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 07 — Logical Network Creation

    Reads every entry from networking.logical_networks[] in the infrastructure YAML
    and calls az stack-hci-vm network lnet create for each one. Entries with
    enabled: false are skipped. Networks that already exist are skipped.

    Command reference: https://learn.microsoft.com/en-us/azure/azure-local/manage/create-logical-networks

.PARAMETER ConfigPath
    Path to infrastructure YAML. Defaults to configs\infrastructure.yml in CWD.

.PARAMETER Credential
    Not used for logical network creation (ARM/CLI operation). Included for
    parameter contract compliance.

.PARAMETER TargetNode
    Not used for logical network creation (ARM operation). Included for
    parameter contract compliance.

.PARAMETER WhatIf
    Dry-run mode: logs all planned operations without making any changes.

.PARAMETER LogPath
    Override log file path. Default: logs\task-07-logical-network-creation\
    <YYYY-MM-DD_HHmmss>_LogicalNetworks.log (relative to CWD).

.EXAMPLE
    .\scripts\deploy\04-cluster-deployment\phase-06-post-deployment\task-07-logical-network-creation\powershell\Invoke-LogicalNetworks-Orchestrated.ps1 -ConfigPath configs\infrastructure-azl-lab.yml -WhatIf

.EXAMPLE
    .\scripts\deploy\04-cluster-deployment\phase-06-post-deployment\task-07-logical-network-creation\powershell\Invoke-LogicalNetworks-Orchestrated.ps1 -ConfigPath configs\infrastructure-azl-lab.yml

.NOTES
    Requires: powershell-yaml module  (Install-Module powershell-yaml -Scope CurrentUser)
    Requires: az CLI authenticated    (az login)
    Requires: az stack-hci-vm extension (az extension add --name stack-hci-vm)
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
if ($ConfigPath -eq "") { $ConfigPath = Join-Path (Get-Location).Path "configs\infrastructure.yml" }
if (-not (Test-Path $ConfigPath)) { Write-Log "Config not found: $ConfigPath" "FAIL"; throw "Config not found" }

Import-Module powershell-yaml -ErrorAction Stop
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

# Subscription — find first subscription key that has an .id property
$subscriptionId = $null
foreach ($key in $cfg.azure_platform.subscriptions.Keys) {         # azure_platform.subscriptions.<key>.id
    $sub = $cfg.azure_platform.subscriptions[$key]
    if ($sub -is [System.Collections.IDictionary] -and $sub['id']) {
        $subscriptionId = $sub['id']
        break
    }
}
if (-not $subscriptionId) { throw "Cannot resolve subscription ID from config" }

$resourceGroup      = $cfg.compute.azure_local.arc_resource_group               # compute.azure_local.arc_resource_group
$location           = $cfg.azure_platform.region                                # azure_platform.region
$customLocationName = $cfg.compute.azure_local.azure_custom_location_name       # compute.azure_local.azure_custom_location_name
$vmSwitchName       = $cfg.compute.azure_local.vm_switch_name                   # compute.azure_local.vm_switch_name

# Build custom location ID directly per MS docs — no API call needed
# /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ExtendedLocation/customLocations/<name>
$customLocationId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ExtendedLocation/customLocations/$customLocationName"

$logicalNetworks = $cfg.networking.logical_networks                              # networking.logical_networks[]
if (-not $logicalNetworks -or $logicalNetworks.Count -eq 0) {
    Write-Log "No logical_networks entries found in config — nothing to do." "WARN"
    exit 0
}
#endregion

Write-Log "=======================================================" "HEADER"
Write-Log " Task 07 — Logical Network Creation (Orchestrated)" "HEADER"
Write-Log " Log: $logFile" "HEADER"
if ($WhatIf) { Write-Log " [WhatIf] Dry-run mode — no changes will be made" "WARN" }
Write-Log "=======================================================" "HEADER"
Write-Log "Subscription   : $subscriptionId"
Write-Log "Resource Group : $resourceGroup"
Write-Log "Location       : $location"
Write-Log "Custom Location: $customLocationName"
Write-Log "vSwitch        : $vmSwitchName"
Write-Log "Networks       : $($logicalNetworks.Count) defined"

#region AUTH CHECK --------------------------------------------------------------
$accountInfo = az account show --output json 2>$null | ConvertFrom-Json
if (-not $accountInfo) { Write-Log "Not logged in — run 'az login' first." "FAIL"; throw "Not authenticated" }
Write-Log "Authenticated as: $($accountInfo.user.name)  (sub: $($accountInfo.id))"
#endregion

#region EXTENSION CHECK ---------------------------------------------------------
# Ensure stack-hci-vm extension is installed and up to date.
Write-Log "Checking az stack-hci-vm extension..."
$extInfo = az extension show --name stack-hci-vm --output json 2>$null | ConvertFrom-Json
if (-not $extInfo) {
    Write-Log "stack-hci-vm extension not found — installing..." "WARN"
    az extension add --name stack-hci-vm --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to install stack-hci-vm extension" }
    Write-Log "stack-hci-vm extension installed." "PASS"
} else {
    Write-Log "stack-hci-vm extension v$($extInfo.version) found — updating to latest..."
    az extension update --name stack-hci-vm --output none
    if ($LASTEXITCODE -ne 0) { Write-Log "Extension update failed — proceeding with installed version." "WARN" }
    else { Write-Log "stack-hci-vm extension updated." "PASS" }
}
#endregion

#region NETWORK CREATION --------------------------------------------------------
$created = 0; $skipped = 0; $failed = 0

# ConvertFrom-Yaml returns OrderedDictionary — use helper for all field access
function Get-LnetProp {
    param($obj, [string]$key)
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) { return $obj[$key] }
    if ($obj.PSObject -and $obj.PSObject.Properties[$key]) { return $obj.PSObject.Properties[$key].Value }
    try { return $obj.$key } catch { return $null }
}

foreach ($lnet in $logicalNetworks) {

    $enabledVal = Get-LnetProp $lnet 'enabled'
    if ($null -ne $enabledVal -and ($enabledVal -eq $false -or $enabledVal -eq "false")) {
        Write-Log "[$(Get-LnetProp $lnet 'name')] Skipping — disabled" "WARN"; $skipped++; continue
    }

    $lnetName    = Get-LnetProp $lnet 'name'
    $vlanId      = [string]([int](Get-LnetProp $lnet 'vlan_id'))
    $allocRaw    = Get-LnetProp $lnet 'ip_allocation_method'
    $allocMethod = if ($allocRaw) { $allocRaw } else { "Static" }

    Write-Log "" "HEADER"
    Write-Log "--- $lnetName (VLAN $vlanId | $allocMethod) ---" "HEADER"

    # Check if already exists
    if (-not $WhatIf) {
        $null = az stack-hci-vm network lnet show `
            --subscription   $subscriptionId `
            --resource-group $resourceGroup `
            --name           $lnetName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "[$lnetName] Already exists — skipped" "WARN"; $skipped++; continue
        }
    }

    # Build args per MS docs:
    # https://learn.microsoft.com/cli/azure/stack-hci-vm/network/lnet
    # Requires stack-hci-vm extension >= current (az extension update --name stack-hci-vm)
    $createArgs = [System.Collections.Generic.List[string]]@(
        "stack-hci-vm", "network", "lnet", "create",
        "--subscription",         $subscriptionId,
        "--resource-group",       $resourceGroup,
        "--custom-location",      $customLocationId,
        "--location",             $location,
        "--name",                 $lnetName,
        "--vm-switch-name",       "`"$vmSwitchName`"",
        "--ip-allocation-method", $allocMethod,
        "--vlan",                 $vlanId,
        "--output",               "none"
    )

    if ($allocMethod -eq "Static") {
        $addrPrefix = Get-LnetProp $lnet 'address_prefix'
        if ($null -eq $addrPrefix) {
            Write-Log "[$lnetName] FAILED: No address_prefix found in config" "FAIL"
            $failed++; continue
        }
        $createArgs.AddRange([string[]]@("--address-prefixes", $addrPrefix))

        $gwValue = Get-LnetProp $lnet 'default_gateway'
        if ($gwValue) {
            $createArgs.AddRange([string[]]@("--gateway", $gwValue))
        } else {
            $createArgs.Add("--no-gateway")
        }

        $dnsServers = Get-LnetProp $lnet 'dns_servers'
        if ($dnsServers -and ($dnsServers.Count -gt 0 -or $dnsServers.Length -gt 0)) {
            $createArgs.Add("--dns-servers")
            foreach ($dns in $dnsServers) { $createArgs.Add($dns) }
        }

        # IP pool — extract from first pool entry
        # ConvertFrom-Yaml can return List<Object>, Object[], or a single OrderedDictionary
        # depending on the version — handle all cases explicitly.
        $poolListRaw = Get-LnetProp $lnet 'ip_pools'
        $poolStart = $null; $poolEnd = $null; $poolType = "vm"

        if ($poolListRaw) {
            # Force into an array regardless of how ConvertFrom-Yaml wrapped it
            $poolArr = @($poolListRaw)
            Write-Log "[$lnetName] ip_pools type=$($poolListRaw.GetType().FullName), count=$($poolArr.Count)" "DEBUG"

            if ($poolArr.Count -gt 0) {
                $pool = $poolArr[0]
                Write-Log "[$lnetName] pool[0] type=$($pool.GetType().FullName)" "DEBUG"

                # Try every known access pattern for the pool dictionary
                if ($pool -is [System.Collections.IDictionary]) {
                    $poolStart = $pool['start']
                    $poolEnd   = $pool['end']
                    $poolType  = if ($pool['type']) { $pool['type'] } else { "vm" }
                } elseif ($pool.PSObject) {
                    $poolStart = $pool.start
                    $poolEnd   = $pool.end
                    $poolType  = if ($pool.type) { $pool.type } else { "vm" }
                }

                # Last-resort: iterate keys if above returned nothing
                if (-not $poolStart -and $pool -is [System.Collections.IDictionary]) {
                    foreach ($k in $pool.Keys) {
                        $kLower = "$k".Trim().ToLower()
                        if ($kLower -eq 'start') { $poolStart = $pool[$k] }
                        if ($kLower -eq 'end')   { $poolEnd   = $pool[$k] }
                        if ($kLower -eq 'type')  { $poolType  = $pool[$k] }
                    }
                }
            }
        }

        if ($poolStart -and $poolEnd) {
            $createArgs.AddRange([string[]]@(
                "--ip-pool-start", [string]$poolStart,
                "--ip-pool-end",   [string]$poolEnd,
                "--ip-pool-type",  [string]$poolType
            ))
            Write-Log "[$lnetName] Configured pool: $poolStart - $poolEnd ($poolType)"
        } else {
            Write-Log "[$lnetName] FAILED: Could not resolve IP pool start/end from config. Raw ip_pools type=$($poolListRaw.GetType().FullName)" "FAIL"
            $failed++; continue
        }
    }

    if ($WhatIf) {
        Write-Log "[$lnetName] [WhatIf] Would run: az $($createArgs -join ' ')" "WARN"
        $created++
    } else {
        Write-Log "[$lnetName] Creating..."
        $output = & az @createArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[$lnetName] FAILED: $output" "FAIL"
            $failed++
        } else {
            Write-Log "[$lnetName] Created successfully" "PASS"
            $created++
        }
    }
}
#endregion

Write-Log "" "HEADER"
Write-Log "=======================================================" "HEADER"
Write-Log " Summary — Created: $created  Skipped: $skipped  Failed: $failed" "HEADER"
Write-Log "=======================================================" "HEADER"

if ($WhatIf) { Write-Log "Dry-run complete. Re-run without -WhatIf to apply." "WARN" }
if ($failed -gt 0) { throw "$failed logical network(s) failed. Review log: $logFile" }
