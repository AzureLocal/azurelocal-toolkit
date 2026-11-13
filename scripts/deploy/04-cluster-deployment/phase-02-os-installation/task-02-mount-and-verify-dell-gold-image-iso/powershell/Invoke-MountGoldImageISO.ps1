#Requires -Version 7.0
<#
.SYNOPSIS
    Mount and verify a Dell gold image ISO via iDRAC Virtual Media (Redfish API).
.DESCRIPTION
    For each node, ejects any currently-mounted virtual media and mounts the
    gold image ISO from the path specified in config/variables.yml.
    Verifies the media is inserted before proceeding.
.PARAMETER ConfigPath
    Path to the YAML variables file. Defaults to ./config/variables.yml.
.PARAMETER WhatIf
    Preview changes without making them.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "./config/variables.yml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'redfish', 'AzlRedfishCore.psm1'))) -Force

# ── Load config ───────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config   = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$nodes    = $config.cluster.nodes
$isoPath  = $config.cluster.gold_image_iso_path

# ── iDRAC credentials: hardware.bmc in the infrastructure file (secret references) ─
Write-Host "Reading the iDRAC credentials from the secret references..." -ForegroundColor Cyan
$idracCred = Resolve-AzlBmcCredential -Infrastructure $config -NoPrompt

# ── Helper: Invoke Redfish ────────────────────────────────────────────────────
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
    $baseUri     = "https://$($node.idrac_ip)"
    $vmMediaPath = "/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD"

    Write-Host ""
    Write-Host "================================================"
    Write-Host " Node: $($node.name) | iDRAC: $($node.idrac_ip)"
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
