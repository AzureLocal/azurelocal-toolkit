#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone: creates Azure Local logical networks — no YAML or toolkit required.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 07 — Logical Network Creation

    Creates Azure Local logical networks using az stack-hci-vm network lnet create.
    All values are configured in the #region CONFIGURATION block below. Copy this
    script, fill in your environment values, and run from any workstation with Azure
    CLI access. No toolkit clone or YAML dependency needed.

    Supports both Static (IP pools + default gateway) and Dynamic (DHCP) allocation.
    Networks that already exist are detected and skipped automatically.

.NOTES
    Prerequisites:
      - az login                                       (Azure CLI authenticated)
      - az extension add --name stack-hci-vm           (extension installed)

.EXAMPLE
    # Configure the CONFIGURATION region below, then run:
    .\New-LogicalNetworks-Standalone.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region CONFIGURATION -----------------------------------------------------------

# ─── Azure Scope ────────────────────────────────────────────────────────────────
$subscription_id    = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
$resource_group     = "rg-iic01-azl-eus-01"
$location           = "eastus"

# Full custom location ARM resource ID
# Found via: az customlocation list --resource-group <rg> --query "[].{Name:name,Id:id}" --output table
$custom_location_id = "/subscriptions/a1b2c3d4-e5f6-7890-abcd-ef1234567890/resourceGroups/rg-iic01-azl-eus-01/providers/Microsoft.ExtendedLocation/customLocations/cl-iic01"

# Hyper-V virtual switch name (from Get-VMSwitch on a cluster node)
$vm_switch_name     = "ConvergedSwitch(hci)"

# ─── NSG Association ─────────────────────────────────────────────────────────────
# Set to $true to associate NSGs with logical networks during creation.
# Requires SDN enabled on the cluster and NSGs created in Task 07.
$associate_nsg      = $false

# ─── Logical Networks ────────────────────────────────────────────────────────────
# ip_allocation_method: "Static" or "Dynamic"
#   Static  — requires address_prefix, default_gateway, ip_pools
#   Dynamic — requires dhcp_options; address_prefix / ip_pools are not used

$logical_networks = @(
    # ── Static network example: Management ──────────────────────────────────────
    @{
        name                 = "ln-iic01-management-100"
        display_name         = "Management Network"
        vlan_id              = 100
        address_prefix       = "10.100.0.0/24"
        default_gateway      = "10.100.0.1"
        ip_allocation_method = "Static"
        dns_servers          = @("10.100.0.10", "10.100.0.11")
        ip_pools             = @(
            @{ name = "pool-mgmt-vms"; start = "10.100.0.50"; end = "10.100.0.200"; type = "vm" }
        )
        nsg_name             = "nsg-iic-management"   # only used when $associate_nsg = $true
        routes               = @()                  # optional extra routes (list of @{address_prefix; next_hop})
    },

    # ── Static network example: Production ──────────────────────────────────────
    @{
        name                 = "ln-iic01-production-200"
        display_name         = "Production Network"
        vlan_id              = 200
        address_prefix       = "10.200.0.0/24"
        default_gateway      = "10.200.0.1"
        ip_allocation_method = "Static"
        dns_servers          = @("10.100.0.10", "10.100.0.11")
        ip_pools             = @(
            @{ name = "pool-prod-vms"; start = "10.200.0.50"; end = "10.200.0.250"; type = "vm" }
        )
        nsg_name             = "nsg-iic-production"   # only used when $associate_nsg = $true
        routes               = @()
    },

    # ── Dynamic network example: AVD (DHCP) ─────────────────────────────────────
    @{
        name                 = "ln-iic01-avd-300"
        display_name         = "AVD Network"
        vlan_id              = 300
        ip_allocation_method = "Dynamic"
        dhcp_options         = @{
            dns_servers  = @("10.100.0.10", "10.100.0.11")
            domain_name  = "contoso.cloud"
        }
        nsg_name             = "nsg-iic-avd"           # only used when $associate_nsg = $true
        routes               = @()
    }
)

#endregion

#region PREREQ CHECK ------------------------------------------------------------
Write-Host ""
Write-Host "Task 07 — Logical Network Creation (Standalone)" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Verify az CLI login
$accountInfo = az account show --output json 2>$null | ConvertFrom-Json
if (-not $accountInfo) {
    throw "Not logged in to Azure CLI. Run 'az login' first."
}
Write-Host "[INFO] Authenticated as: $($accountInfo.user.name)" -ForegroundColor Cyan

# Ensure stack-hci-vm extension is available
$extCheck = az extension show --name stack-hci-vm --output json 2>$null | ConvertFrom-Json
if (-not $extCheck) {
    Write-Host "[INFO] Installing stack-hci-vm extension..." -ForegroundColor Cyan
    az extension add --name stack-hci-vm --output none
}
Write-Host ""
#endregion

#region LOGICAL NETWORK CREATION -----------------------------------------------
$created = 0; $skipped = 0; $failed = 0

foreach ($lnet in $logical_networks) {
    $lnetName    = $lnet.name
    $vlanId      = [int]$lnet.vlan_id
    $allocMethod = $lnet.ip_allocation_method

    Write-Host "[INFO] Processing: $lnetName  (VLAN $vlanId | $allocMethod)" -ForegroundColor Cyan

    # Check if already exists
    $existing = az stack-hci-vm network lnet show `
        --subscription   $subscription_id `
        --resource-group $resource_group `
        --name           $lnetName 2>$null

    if ($LASTEXITCODE -eq 0 -and $existing) {
        Write-Host "[WARN] Already exists — skipped: $lnetName" -ForegroundColor Yellow
        $skipped++
        continue
    }

    # ── Build subnet object ──────────────────────────────────────────────────────
    $subnetObj = [ordered]@{
        name               = "default"
        ipAllocationMethod = $allocMethod
    }

    if ($allocMethod -eq "Static") {
        $subnetObj['addressPrefix'] = $lnet.address_prefix

        if ($lnet.dns_servers -and $lnet.dns_servers.Count -gt 0) {
            $subnetObj['dnsServers'] = @($lnet.dns_servers)
        }

        if ($lnet.ip_pools -and $lnet.ip_pools.Count -gt 0) {
            $subnetObj['ipPools'] = @($lnet.ip_pools | ForEach-Object {
                [ordered]@{
                    name       = if ($_.name)  { $_.name }  else { "pool-01" }
                    start      = $_.start
                    end        = $_.end
                    ipPoolType = @(if ($_.type) { $_.type } else { "vm" })
                }
            })
        }

        if ($lnet.default_gateway) {
            $subnetObj['routes'] = @(@{
                name          = "default-gw"
                addressPrefix = "0.0.0.0/0"
                nextHop       = $lnet.default_gateway
            })
        }
    }

    if ($allocMethod -eq "Dynamic" -and $lnet.dhcp_options) {
        $dhcp = [ordered]@{}
        if ($lnet.dhcp_options.dns_servers -and $lnet.dhcp_options.dns_servers.Count -gt 0) {
            $dhcp['dnsServers'] = @($lnet.dhcp_options.dns_servers)
        }
        if ($lnet.dhcp_options.domain_name) { $dhcp['domainName'] = $lnet.dhcp_options.domain_name }
        if ($dhcp.Count -gt 0) { $subnetObj['dhcpOptions'] = $dhcp }
    }

    # Extra static routes (both Static and Dynamic)
    if ($lnet.routes -and $lnet.routes.Count -gt 0) {
        $extraRoutes = @($lnet.routes | ForEach-Object {
            [ordered]@{
                name          = if ($_.name) { $_.name } else { "route-$($_.address_prefix -replace '[.:/]','-')" }
                addressPrefix = $_.address_prefix
                nextHop       = $_.next_hop
            }
        })
        if ($subnetObj['routes']) { $subnetObj['routes'] += $extraRoutes }
        else { $subnetObj['routes'] = $extraRoutes }
    }

    $subnetJson = @($subnetObj) | ConvertTo-Json -Depth 10 -Compress

    # ── Run az command ───────────────────────────────────────────────────────────
    $createArgs = @(
        "stack-hci-vm", "network", "lnet", "create",
        "--subscription",    $subscription_id,
        "--resource-group",  $resource_group,
        "--custom-location", $custom_location_id,
        "--location",        $location,
        "--name",            $lnetName,
        "--vm-switch-name",  "`"$vm_switch_name`"",
        "--vlan",            "$vlanId",
        "--subnets",         $subnetJson,
        "--output",          "none"
    )

    if ($lnet.display_name) {
        $createArgs += @("--tags", "displayName=$($lnet.display_name)")
    }

    # Associate NSG if opted in and nsg_name is defined
    if ($associate_nsg -and $lnet.nsg_name) {
        $createArgs += @("--network-security-group", $lnet.nsg_name)
        Write-Host "[INFO] NSG association: $($lnet.nsg_name)" -ForegroundColor Cyan
    }

    Write-Host "[INFO] Creating: $lnetName..." -ForegroundColor Cyan
    & az @createArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to create: $lnetName" -ForegroundColor Red
        $failed++
    } else {
        Write-Host "[OK]   Created: $lnetName" -ForegroundColor Green
        $created++
    }
}
#endregion

#region SUMMARY -----------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "   Created : $created" -ForegroundColor $(if ($created -gt 0) { "Green" } else { "White" })
Write-Host "   Skipped : $skipped" -ForegroundColor $(if ($skipped -gt 0) { "Yellow" } else { "White" })
Write-Host "   Failed  : $failed"  -ForegroundColor $(if ($failed  -gt 0) { "Red" }   else { "White" })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Validate with:" -ForegroundColor Cyan
Write-Host "  az stack-hci-vm network lnet list ``" -ForegroundColor White
Write-Host "      --subscription  $subscription_id ``" -ForegroundColor White
Write-Host "      --resource-group $resource_group ``" -ForegroundColor White
Write-Host "      --output table" -ForegroundColor White
#endregion
