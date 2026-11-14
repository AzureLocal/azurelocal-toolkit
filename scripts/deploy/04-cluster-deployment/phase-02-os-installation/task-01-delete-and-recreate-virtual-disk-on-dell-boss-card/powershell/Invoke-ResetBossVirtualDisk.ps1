#Requires -Version 7.0
<#
.SYNOPSIS
    Delete and recreate the virtual disk on Dell BOSS cards via the Redfish API.
.DESCRIPTION
    Connects to each node's iDRAC, locates the BOSS storage controller,
    deletes existing virtual disks, and creates a new RAID-1 volume across
    the two BOSS M.2 physical drives.
.PARAMETER ConfigPath
    Path to the infrastructure.yml (schema 5). Defaults to ./configs/infrastructure.yml.
.PARAMETER VolumeName
    The label the new virtual disk gets (default BOSS-RAID1). A label on the mirror; nothing in the deployment reads it.
.PARAMETER WhatIf
    Preview changes without making them.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "./configs/infrastructure.yml",
    [ValidateNotNullOrEmpty()][string]$VolumeName = "BOSS-RAID1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'redfish', 'AzlRedfishCore.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

# The Redfish path of the system's storage controllers on a Dell iDRAC. Fixed by the DMTF Redfish schema and by Dell's iDRAC Redfish API: the system resource of an
# iDRAC is always System.Embedded.1. This script is for Dell BOSS cards only.
$StorageCollectionPath = "/redfish/v1/Systems/System.Embedded.1/Storage"

# ── Load config ───────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config  = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$nodes   = Get-AzlInfrastructureValue -Infrastructure $config -Path 'nodes'

# ── iDRAC credentials: hardware.bmc in the infrastructure file (secret references) ─
Write-Host "Reading the iDRAC credentials from the secret references..." -ForegroundColor Cyan
$idracCred = Resolve-AzlBmcCredential -Infrastructure $config -NoPrompt

# ── Helper: the BMC address of a node (nodes[].bmc.ip_address) ────────────────
function Get-NodeBmcAddress {
    param([System.Collections.IDictionary]$Node)
    $bmc = if ($Node.Contains('bmc')) { $Node['bmc'] } else { $null }
    if ($bmc -is [System.Collections.IDictionary] -and $bmc.Contains('ip_address')) { return [string]$bmc['ip_address'] }
    return ''
}

# ── Helper: Invoke Redfish────────────────────────────────────────────────────
function Invoke-Redfish {
    param(
        [string]$BaseUri,
        [string]$Path,
        [string]$Method = "GET",
        [hashtable]$Body,
        [System.Management.Automation.PSCredential]$Credential
    )
    $uri    = "$BaseUri$Path"
    $params = @{
        Uri                  = $uri
        Method               = $Method
        Credential           = $Credential
        Authentication       = "Basic"
        ContentType          = "application/json"
        SkipCertificateCheck = $true
    }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 5) }
    Invoke-RestMethod @params
}

# ── Process each node ─────────────────────────────────────────────────────────
foreach ($node in $nodes) {
    $bmcIp = Get-NodeBmcAddress -Node $node
    if (-not $bmcIp) { Write-Warning "  [SKIP] $($node.name) has no nodes[].bmc.ip_address"; continue }
    $baseUri = "https://$($bmcIp)"
    Write-Host ""
    Write-Host "================================================"
    Write-Host " Node: $($node.name) | iDRAC: $($bmcIp)"
    Write-Host "================================================" -ForegroundColor Cyan

    if (-not ($PSCmdlet.ShouldProcess($node.name, "Reset BOSS virtual disk"))) { continue }

    # Find BOSS controller
    Write-Host "  Discovering BOSS controller..."
    $storage = Invoke-Redfish -BaseUri $baseUri `
        -Path $StorageCollectionPath `
        -Credential $idracCred
    $bossController = $storage.Members | Where-Object {
        $_.'@odata.id' -match "BOSS"
    } | Select-Object -First 1

    if (-not $bossController) {
        Write-Warning "  [SKIP] No BOSS controller found on $($node.name)"
        continue
    }

    $controllerPath = $bossController.'@odata.id'
    $controllerData = Invoke-Redfish -BaseUri $baseUri -Path $controllerPath -Credential $idracCred
    Write-Host "  Found controller: $($controllerData.Id)"

    # Delete existing virtual disks
    Write-Host "  Deleting existing virtual disks..."
    $volumes = Invoke-Redfish -BaseUri $baseUri `
        -Path "$controllerPath/Volumes" `
        -Credential $idracCred
    foreach ($vol in $volumes.Members) {
        $volPath = $vol.'@odata.id'
        Write-Host "    Deleting: $volPath"
        Invoke-Redfish -BaseUri $baseUri -Path $volPath -Method "DELETE" -Credential $idracCred | Out-Null
    }

    # Get physical drives (BOSS M.2 slots)
    Write-Host "  Reading physical drives..."
    $drives = Invoke-Redfish -BaseUri $baseUri `
        -Path "$controllerPath/Drives" `
        -Credential $idracCred
    $driveRefs = $drives.Members | Select-Object -First 2 | ForEach-Object {
        @{ '@odata.id' = $_.'@odata.id' }
    }

    if ($driveRefs.Count -lt 2) {
        Write-Warning "  [WARN] Less than 2 physical drives found; cannot create RAID-1. Skipping."
        continue
    }

    # Create RAID-1 virtual disk
    Write-Host "  Creating RAID-1 virtual disk across $($driveRefs.Count) drives..."
    $newVol = @{
        VolumeType = "Mirrored"
        Drives     = @($driveRefs)
        Name       = $VolumeName
    }
    $result = Invoke-Redfish -BaseUri $baseUri `
        -Path "$controllerPath/Volumes" `
        -Method "POST" `
        -Body $newVol `
        -Credential $idracCred

    Write-Host "  [DONE] RAID-1 volume created: $($result.'@odata.id')" -ForegroundColor Green
}

Write-Host "`nBOSS virtual disk reset complete." -ForegroundColor Cyan
