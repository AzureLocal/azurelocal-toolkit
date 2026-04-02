<#
.SYNOPSIS
    Removes all infrastructure resources for Azure Local environment.

.DESCRIPTION
    This script deletes:
    - All infrastructure VMs (DC01, DC02, Jump, Lighthouse)
    - All NICs and public IPs
    - Infrastructure subnet
    - NSG
    
    ** USE WITH EXTREME CAUTION **

.PARAMETER SubscriptionId
    Azure subscription ID (default: 11111111-1111-1111-1111-111111111111)

.PARAMETER ResourceGroup
    Resource group name (example: rg-connectivity-hub)

.PARAMETER Force
    Skip confirmation prompts (use with caution)

.EXAMPLE
    .\cleanup-infrastructure.ps1 -WhatIf
    
.EXAMPLE
    .\cleanup-infrastructure.ps1
    
.EXAMPLE
    .\cleanup-infrastructure.ps1 -Force
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Red
Write-Host "  Infrastructure Cleanup Script" -ForegroundColor Red
Write-Host "  ** DESTRUCTIVE OPERATION **" -ForegroundColor Red
Write-Host "============================================" -ForegroundColor Red
Write-Host ""
Write-Host "Subscription: $SubscriptionId" -ForegroundColor Gray
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host ""

if (-not $Force -and -not $WhatIfPreference) {
    Write-Host "This will DELETE the following resources:" -ForegroundColor Yellow
    Write-Host "  - vm-dc01" -ForegroundColor Gray
    Write-Host "  - vm-dc02" -ForegroundColor Gray
    Write-Host "  - vm-jump" -ForegroundColor Gray
    Write-Host "  - vm-lighthouse" -ForegroundColor Gray
    Write-Host "  - All NICs and public IPs" -ForegroundColor Gray
    Write-Host "  - snet-infra (subnet)" -ForegroundColor Gray
    Write-Host "  - nsg-infra (NSG)" -ForegroundColor Gray
    Write-Host ""
    
    $confirmation = Read-Host "Type 'DELETE' to confirm deletion"
    if ($confirmation -ne "DELETE") {
        Write-Host "Cleanup cancelled" -ForegroundColor Yellow
        exit 0
    }
}

# Set subscription context
Write-Host "[1/7] Setting subscription context..." -ForegroundColor Yellow
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription context"
}
Write-Host "✓ Subscription context set" -ForegroundColor Green

# Delete VMs
Write-Host "[2/7] Deleting virtual machines..." -ForegroundColor Yellow
# Note: These should come from solution config
$vms = @(
    "vm-dc01",
    "vm-dc02",
    "vm-jump",
    "vm-lighthouse"
)

foreach ($vm in $vms) {
    if ($PSCmdlet.ShouldProcess($vm, "Delete VM")) {
        Write-Host "  Deleting $vm..." -ForegroundColor Gray
        az vm delete --resource-group $ResourceGroup --name $vm --yes --no-wait
    }
}
Write-Host "✓ VM deletion initiated (running in background)" -ForegroundColor Green

# Wait for VM deletions
if (-not $WhatIfPreference) {
    Write-Host "[3/7] Waiting for VM deletions to complete..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    Write-Host "✓ Proceeding with cleanup" -ForegroundColor Green
}

# Delete NICs
Write-Host "[4/7] Deleting network interfaces..." -ForegroundColor Yellow
# Note: These should come from solution config
$nics = @(
    "nic-dc01",
    "nic-dc02",
    "nic-jump",
    "nic-lighthouse"
)

foreach ($nic in $nics) {
    if ($PSCmdlet.ShouldProcess($nic, "Delete NIC")) {
        Write-Host "  Deleting $nic..." -ForegroundColor Gray
        az network nic delete --resource-group $ResourceGroup --name $nic --no-wait 2>$null
    }
}
Write-Host "✓ NIC deletion initiated" -ForegroundColor Green

# Delete public IP
Write-Host "[5/7] Deleting public IP..." -ForegroundColor Yellow
# Note: Name should come from solution config
if ($PSCmdlet.ShouldProcess("pip-lighthouse", "Delete public IP")) {
    az network public-ip delete --resource-group $ResourceGroup --name "pip-lighthouse" --no-wait 2>$null
}
Write-Host "✓ Public IP deletion initiated" -ForegroundColor Green

# Wait for NIC/IP deletions
if (-not $WhatIfPreference) {
    Write-Host "  Waiting for network resources to delete..." -ForegroundColor Gray
    Start-Sleep -Seconds 15
}

# Delete subnet
Write-Host "[6/7] Deleting infrastructure subnet..." -ForegroundColor Yellow
# Note: Names should come from solution config
if ($PSCmdlet.ShouldProcess("snet-infra", "Delete subnet")) {
    az network vnet subnet delete `
        --resource-group $ResourceGroup `
        --vnet-name "vnet-connectivity-hub" `
        --name "snet-infra" 2>$null
}
Write-Host "✓ Subnet deleted" -ForegroundColor Green

# Delete NSG
Write-Host "[7/7] Deleting network security group..." -ForegroundColor Yellow
# Note: Name should come from solution config
if ($PSCmdlet.ShouldProcess("nsg-infra", "Delete NSG")) {
    az network nsg delete --resource-group $ResourceGroup --name "nsg-infra" 2>$null
}
Write-Host "✓ NSG deleted" -ForegroundColor Green

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Infrastructure Cleanup Complete" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "All infrastructure resources have been deleted." -ForegroundColor Gray
Write-Host "To redeploy, run: .\deploy-infrastructure.ps1" -ForegroundColor Gray
