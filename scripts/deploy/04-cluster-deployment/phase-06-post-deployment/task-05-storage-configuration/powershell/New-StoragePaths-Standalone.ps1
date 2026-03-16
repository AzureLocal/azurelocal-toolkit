#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone: registers Azure Local storage paths in Azure via az CLI.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 05 — Storage Configuration (Section 3)

    Fill in the #region CONFIGURATION block and run from any machine with
    az CLI access. No infrastructure.yml dependency. No PS Remoting.

.NOTES
    Requires: az CLI logged in with Contributor on the cluster resource group.
    Requires: az extension add --name stack-hci-vm
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region CONFIGURATION -----------------------------------------------------------
$ResourceGroup  = "rg-iic01-azl-eus-01"
$CustomLocation = "cl-iic01"

$StoragePaths = @(
    [PSCustomObject]@{
        Name = "sp-iic01-clus01-m2-vmstore-prd-01"
        Path = "C:\ClusterStorage\csv-iic01-clus01-m2-vmstore-prd-01\VMs"
    }
    [PSCustomObject]@{
        Name = "sp-iic01-clus01-m2-vmstore-prd-02"
        Path = "C:\ClusterStorage\csv-iic01-clus01-m2-vmstore-prd-02\VMs"
    }
)
#endregion ----------------------------------------------------------------------

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) { "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; default { "Cyan" } }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

# Verify az CLI login
$account = az account show --query name -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Status "Not logged in to az CLI. Run: az login" -Level "ERROR"; exit 1
}
Write-Status "Azure account : $account" -Level "OK"

# Ensure stack-hci-vm extension
$extCheck = az extension list --query "[?name=='stack-hci-vm'].name" -o tsv 2>$null
if ([string]::IsNullOrEmpty($extCheck)) {
    Write-Status "Installing stack-hci-vm extension..." -Level "WARN"
    az extension add --name stack-hci-vm --yes 2>&1 | Out-Null
    Write-Status "Extension installed" -Level "OK"
}

Write-Status "Registering storage paths in $ResourceGroup"
Write-Status "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

foreach ($sp in $StoragePaths) {
    Write-Status "Processing: $($sp.Name)"

    $existing = az stack-hci-vm storagepath show `
        --resource-group $ResourceGroup `
        --name           $sp.Name `
        --query          "provisioningState" `
        -o tsv 2>$null

    if ($existing -eq "Succeeded") {
        Write-Status "  Already registered — skipping" -Level "WARN"
        continue
    }

    az stack-hci-vm storagepath create `
        --resource-group  $ResourceGroup `
        --custom-location $CustomLocation `
        --name            $sp.Name `
        --path            $sp.Path `
        --output          none

    if ($LASTEXITCODE -eq 0) {
        Write-Status "  Registered: $($sp.Path)" -Level "OK"
    } else {
        Write-Status "  Failed — check az CLI output above" -Level "ERROR"
    }
}

Write-Status "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Status "Done. Run Section 4 validation to confirm." -Level "OK"
