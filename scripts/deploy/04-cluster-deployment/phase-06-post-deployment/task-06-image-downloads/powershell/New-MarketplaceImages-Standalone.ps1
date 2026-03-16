#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone: creates Azure Local gallery images from Azure Marketplace.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 06 — VM Image Downloads

    Fill in the #region CONFIGURATION block with your environment values.
    No infrastructure.yml or toolkit dependency. Safe to copy and share.

    Three standard images are pre-configured:
      - Windows Server 2025 Datacenter Azure Edition Gen 2
      - Windows Server 2022 Datacenter Azure Edition Hotpatch Gen 2
      - Windows 11 Enterprise Multi-Session 25H2 + Microsoft 365 Apps Gen 2

.EXAMPLE
    .\New-MarketplaceImages-Standalone.ps1

.NOTES
    Requires: az CLI authenticated (az login) and stack-hci-vm extension.
              Run: az extension add --name stack-hci-vm
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region CONFIGURATION -----------------------------------------------------------
$subscription_id    = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"  # azure_platform.subscription_id
$resource_group     = "rg-iic01-azl-eus-01"                    # azure_platform.resource_group
$location           = "eastus"                                  # azure_platform.location
$custom_location_id = "/subscriptions/$subscription_id/resourceGroups/$resource_group" +
                      "/providers/Microsoft.ExtendedLocation/customLocations/cl-iic01"
                                                                # compute.azure_local.custom_location_name

$images = @(
    @{
        name      = "img-iic01-ws2025-azedition-g2"
        publisher = "MicrosoftWindowsServer"
        offer     = "WindowsServer"
        sku       = "2025-datacenter-azure-edition-g2"
        version   = "latest"
        os_type   = "Windows"
    },
    @{
        name      = "img-iic01-ws2022-azedition-hotpatch-g2"
        publisher = "MicrosoftWindowsServer"
        offer     = "WindowsServer"
        sku       = "2022-datacenter-azure-edition-hotpatch-g2"
        version   = "latest"
        os_type   = "Windows"
    },
    @{
        name      = "img-iic01-win11-25h2-avd-m365-g2"
        publisher = "MicrosoftWindowsDesktop"
        offer     = "office-365"
        sku       = "win11-25h2-avd-m365"
        version   = "latest"
        os_type   = "Windows"
    }
)
#endregion

#region IMAGE CREATION ----------------------------------------------------------
foreach ($img in $images) {
    Write-Host "[INFO] Image: $($img.name)  ($($img.publisher) / $($img.offer) / $($img.sku))" -ForegroundColor Cyan
    Write-Host "       (this may take 15-30 minutes per image...)"

    $existing = az stack-hci-vm image show `
        --subscription   $subscription_id `
        --resource-group $resource_group `
        --name           $img.name 2>$null

    if ($LASTEXITCODE -eq 0 -and $existing) {
        Write-Host "[WARN] Already exists — skipped" -ForegroundColor Yellow
        continue
    }

    az stack-hci-vm image create `
        --subscription   $subscription_id `
        --resource-group $resource_group `
        --custom-location $custom_location_id `
        --location       $location `
        --name           $img.name `
        --os-type        $img.os_type `
        --offer          $img.offer `
        --publisher      $img.publisher `
        --sku            $img.sku `
        --version        $img.version `
        --output         none

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to create $($img.name)" -ForegroundColor Red
    } else {
        Write-Host "[OK]   Created: $($img.name)" -ForegroundColor Green
    }
}
#endregion

Write-Host ""
Write-Host "Done. Validate with:" -ForegroundColor Green
Write-Host "  az stack-hci-vm image list --resource-group $resource_group --output table" -ForegroundColor Green
