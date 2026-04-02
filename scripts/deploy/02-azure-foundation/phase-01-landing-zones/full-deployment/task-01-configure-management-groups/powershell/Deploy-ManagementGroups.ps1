#Requires -Modules Az.Resources
<#
.SYNOPSIS
    Deploy Azure Management Group hierarchy.
.DESCRIPTION
    Creates the full management group hierarchy from config/variables.yml.
    Run after authenticating with Connect-AzAccount targeting the tenant root.
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

# Load config
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$mg = $config.azure.management_groups

function Get-MgParentId {
    param([string]$Name)
    "/providers/Microsoft.Management/managementGroups/$Name"
}

function New-MgIfNotExists {
    param(
        [string]$GroupName,
        [string]$DisplayName,
        [string]$ParentId
    )
    $existing = Get-AzManagementGroup -GroupName $GroupName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  [SKIP] Management group '$GroupName' already exists." -ForegroundColor Yellow
        return $existing
    }
    if ($PSCmdlet.ShouldProcess("Management Group '$GroupName'", "Create")) {
        Write-Host "  [CREATE] $DisplayName ($GroupName) under $ParentId" -ForegroundColor Green
        New-AzManagementGroup -GroupName $GroupName -DisplayName $DisplayName -ParentId $ParentId
    }
}

Write-Host "Deploying management group hierarchy..." -ForegroundColor Cyan

$rootId = $mg.tenant_root.name

# Platform MG
New-MgIfNotExists -GroupName $mg.platform.name `
    -DisplayName $mg.platform.display_name `
    -ParentId (Get-MgParentId $rootId)

# Platform children
foreach ($child in @('platform_identity', 'platform_management', 'platform_connectivity')) {
    New-MgIfNotExists -GroupName $mg.$child.name `
        -DisplayName $mg.$child.display_name `
        -ParentId (Get-MgParentId $mg.platform.name)
}

# Landing Zone MG
New-MgIfNotExists -GroupName $mg.landing_zone.name `
    -DisplayName $mg.landing_zone.display_name `
    -ParentId (Get-MgParentId $rootId)

# Landing Zone children
foreach ($child in @('lz_corp', 'lz_online')) {
    New-MgIfNotExists -GroupName $mg.$child.name `
        -DisplayName $mg.$child.display_name `
        -ParentId (Get-MgParentId $mg.landing_zone.name)
}

# Top-level siblings
foreach ($child in @('sandbox', 'decommissioned')) {
    New-MgIfNotExists -GroupName $mg.$child.name `
        -DisplayName $mg.$child.display_name `
        -ParentId (Get-MgParentId $rootId)
}

Write-Host "`nManagement group hierarchy deployment complete." -ForegroundColor Cyan
