#Requires -Modules Az.Resources
<#
.SYNOPSIS
    Deploy a single Azure Management Group (simplified deployment).
.DESCRIPTION
    Creates one management group under the tenant root or a specified parent
    using values from config/variables.yml.
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

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$mg     = $config.azure.management_group

Write-Host "Deploying management group: $($mg.display_name) ($($mg.name))..." -ForegroundColor Cyan

$parentPath = "/providers/Microsoft.Management/managementGroups/$($mg.parent_id)"

$existing = Get-AzManagementGroup -GroupName $mg.name -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  [SKIP] Management group '$($mg.name)' already exists." -ForegroundColor Yellow
} else {
    if ($PSCmdlet.ShouldProcess($mg.name, "Create management group")) {
        New-AzManagementGroup `
            -GroupName    $mg.name `
            -DisplayName  $mg.display_name `
            -ParentId     $parentPath
        Write-Host "  [CREATED] $($mg.name)" -ForegroundColor Green
    }
}

Write-Host "Management group deployment complete." -ForegroundColor Cyan
