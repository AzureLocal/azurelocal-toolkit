#Requires -Modules Az.KeyVault
<#
.SYNOPSIS
    Delete and recreate the virtual disk on Dell BOSS cards via the Redfish API.
.DESCRIPTION
    Connects to each node's iDRAC, locates the BOSS storage controller,
    deletes existing virtual disks, and creates a new RAID-1 volume across
    the two BOSS M.2 physical drives.
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

# ── Load config ───────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config  = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$nodes   = $config.cluster.nodes
$kvName  = $config.azure.key_vault.name

# ── Get iDRAC credentials from Key Vault ──────────────────────────────────────
Write-Host "Retrieving iDRAC credentials from Key Vault: $kvName" -ForegroundColor Cyan
$idracUser = Get-AzKeyVaultSecret -VaultName $kvName -Name "idrac-username" -AsPlainText
$idracPass = Get-AzKeyVaultSecret -VaultName $kvName -Name "idrac-password" -AsPlainText |
             ConvertTo-SecureString -AsPlainText -Force
$idracCred = New-Object System.Management.Automation.PSCredential($idracUser, $idracPass)

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
    $baseUri = "https://$($node.idrac_ip)"
    Write-Host ""
    Write-Host "================================================"
    Write-Host " Node: $($node.name) | iDRAC: $($node.idrac_ip)"
    Write-Host "================================================" -ForegroundColor Cyan

    if (-not ($PSCmdlet.ShouldProcess($node.name, "Reset BOSS virtual disk"))) { continue }

    # Find BOSS controller
    Write-Host "  Discovering BOSS controller..."
    $storage = Invoke-Redfish -BaseUri $baseUri `
        -Path "/redfish/v1/Systems/System.Embedded.1/Storage" `
        -Credential $idracCred
    $bossController = $storage.Members | Where-Object {
        $_.{'@odata.id'} -match "BOSS"
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
        Name       = "BOSS-RAID1"
    }
    $result = Invoke-Redfish -BaseUri $baseUri `
        -Path "$controllerPath/Volumes" `
        -Method "POST" `
        -Body $newVol `
        -Credential $idracCred

    Write-Host "  [DONE] RAID-1 volume created: $($result.'@odata.id')" -ForegroundColor Green
}

Write-Host "`nBOSS virtual disk reset complete." -ForegroundColor Cyan
