#Requires -Version 7.0
<#
.SYNOPSIS
    Mount and verify a Dell gold image ISO via iDRAC Virtual Media (Redfish API).
.DESCRIPTION
    For each node, ejects any currently-mounted virtual media and mounts the
    gold image ISO from provisioning.iso.image_uri of infrastructure.yml. The iDRAC addresses are nodes[].bmc.ip_address.
    Verifies the media is inserted before proceeding.
.PARAMETER ConfigPath
    Path to the infrastructure.yml (schema 5). Defaults to ./configs/infrastructure.yml.
.PARAMETER WhatIf
    Preview changes without making them.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "./configs/infrastructure.yml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'redfish', 'AzlRedfishCore.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

# The Redfish path of the virtual CD of a Dell iDRAC. Fixed by Dell's iDRAC Redfish API (the manager is always iDRAC.Embedded.1 and its virtual CD is VirtualMedia/CD).
# This script is for Dell iDRAC only.
$VirtualMediaPath = "/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD"

# ── Load config ───────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config   = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$nodes    = Get-AzlInfrastructureValue -Infrastructure $config -Path 'nodes'
$isoPath  = [string](Get-AzlInfrastructureValue -Infrastructure $config -Path 'provisioning.iso.image_uri')
if (-not $isoPath) { throw "provisioning.iso.image_uri is missing in $ConfigPath. It is the address the iDRAC fetches the ISO from." }

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
    $baseUri     = "https://$($bmcIp)"
    $vmMediaPath = $VirtualMediaPath

    Write-Host ""
    Write-Host "================================================"
    Write-Host " Node: $($node.name) | iDRAC: $($bmcIp)"
    Write-Host "================================================" -ForegroundColor Cyan

    if (-not ($PSCmdlet.ShouldProcess($node.name, "Mount gold image ISO"))) { continue }

    # Check current media status
    Write-Host "  Checking current virtual media status..."
    $mediaStatus = Invoke-Redfish -BaseUri $baseUri -Path $vmMediaPath -Credential $idracCred

    if ($mediaStatus.Inserted) {
        Write-Host "  Current media inserted: $($mediaStatus.Image)"
        Write-Host "  Ejecting current media..."
        Invoke-Redfish -BaseUri $baseUri `
            -Path "$vmMediaPath/Actions/VirtualMedia.EjectMedia" `
            -Method "POST" `
            -Body @{} `
            -Credential $idracCred | Out-Null
        Start-Sleep -Seconds 5
    } else {
        Write-Host "  No media currently inserted."
    }

    # Mount gold image ISO
    Write-Host "  Mounting ISO: $isoPath"
    $mountPayload = @{
        Image            = $isoPath
        Inserted         = $true
        WriteProtected   = $true
    }
    Invoke-Redfish -BaseUri $baseUri `
        -Path "$vmMediaPath/Actions/VirtualMedia.InsertMedia" `
        -Method "POST" `
        -Body $mountPayload `
        -Credential $idracCred | Out-Null

    # Verify insertion
    Write-Host "  Verifying mount..."
    Start-Sleep -Seconds 3
    $verify = Invoke-Redfish -BaseUri $baseUri -Path $vmMediaPath -Credential $idracCred

    if ($verify.Inserted -eq $true) {
        Write-Host "  [PASS] ISO mounted and verified: $($verify.Image)" -ForegroundColor Green
    } else {
        Write-Error "  [FAIL] ISO not reported as inserted on $($node.name)"
    }
}

Write-Host "`nGold image ISO mount complete." -ForegroundColor Cyan
