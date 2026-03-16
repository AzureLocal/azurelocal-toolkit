<#
.SYNOPSIS
    Get-HciResourceProviderObjectId-Standalone.ps1
    Retrieves the Microsoft.AzureStackHCI resource provider service principal Object ID.

.DESCRIPTION
    Standalone script (Option 5). No infrastructure.yml dependency. Looks up the
    Microsoft.AzureStackHCI resource provider Object ID and outputs it.

    Requires:
      - Az.Resources module (Get-AzADServicePrincipal)
      - Authenticated Azure session (Connect-AzAccount)

.EXAMPLE
    .\Get-HciResourceProviderObjectId-Standalone.ps1

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Script Type:  Standalone (Option 5 — no config dependency)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Verify Azure context
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    throw "Not authenticated to Azure. Run Connect-AzAccount first."
}
Write-Host "Azure context: $($ctx.Account.Id) / Tenant: $($ctx.Tenant.Id)" -ForegroundColor Cyan

# Lookup HCI Resource Provider SP
Write-Host "Looking up Microsoft.AzureStackHCI Resource Provider..." -ForegroundColor Cyan
$hciRP = Get-AzADServicePrincipal -DisplayName "Microsoft.AzureStackHCI Resource Provider" -ErrorAction Stop

if (-not $hciRP) {
    throw "Microsoft.AzureStackHCI Resource Provider not found in this tenant."
}

Write-Host ""
Write-Host "HCI Resource Provider Object ID: $($hciRP.Id)" -ForegroundColor Green
Write-Host ""
Write-Host "Set this value in your infrastructure.yml:" -ForegroundColor Yellow
Write-Host "  YAML path: cluster_arm_deployment.resource_provider_object_id" -ForegroundColor Yellow
Write-Host "  Value:     $($hciRP.Id)" -ForegroundColor Yellow

# Return the object so it can be captured: $id = .\Get-HciResourceProviderObjectId-Standalone.ps1
return $hciRP.Id
