<#
.SYNOPSIS
    Test-DnsClientConfig.ps1
    Verifies DNS client configuration on the local Azure Local node.

.DESCRIPTION
    Run directly ON the target node (console/KVM/RDP).
    Validates that the correct primary and secondary DNS servers are configured
    on the management NIC, then tests resolution of critical Azure endpoints.

    Behaviour:
    - Hard-fails on any REPLACE placeholder remaining in #region CONFIGURATION
    - Finds the management adapter by exact name — lists adapters and exits if not found
    - Compares configured DNS servers against expected values from infrastructure.yml
    - Tests resolution of Azure Arc and Azure Resource Manager endpoints
    - Exits with code 1 on any DNS mismatch or resolution failure

    Variables:  All values come from infrastructure.yml (see mapping table below)
      cluster.management_nic_name  → $ManagementNIC
      dns.primary                  → $ExpectedDNSPrimary
      dns.secondary                → $ExpectedDNSSecondary

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-06-verify-dns-client-configuration
    Execution:    Run directly on the node (console, KVM, RDP)
    Prerequisites: PowerShell 5.1+, local admin rights
    Run after:    Task 05 — DNS servers configured

.EXAMPLE
    .\Test-DnsClientConfig.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
#  CONFIGURATION — edit these values before running
# ============================================================================

#region CONFIGURATION
# ── Edit these values to match your environment ──────────────────────────────
$ManagementNIC        = "REPLACE_WITH_MANAGEMENT_NIC_NAME" # cluster.management_nic_name
$ExpectedDNSPrimary   = "REPLACE_WITH_DNS_PRIMARY"          # dns.primary
$ExpectedDNSSecondary = "REPLACE_WITH_DNS_SECONDARY"        # dns.secondary
#endregion CONFIGURATION

# ============================================================================
#  VALIDATION — hard-fail on any REPLACE placeholder
# ============================================================================

function Assert-ConfigValues {
    param([hashtable]$Values)
    $bad = @()
    foreach ($key in $Values.Keys) {
        if ($Values[$key] -match "^REPLACE_|^\s*$") { $bad += $key }
    }
    if ($bad.Count -gt 0) {
        Write-Host "[ERROR] Unconfigured values in #region CONFIGURATION: $($bad -join ', ')" -ForegroundColor Red
        Write-Host "        Edit the values at the top of this script before running." -ForegroundColor Red
        exit 1
    }
}

Assert-ConfigValues @{
    ManagementNIC        = $ManagementNIC
    ExpectedDNSPrimary   = $ExpectedDNSPrimary
    ExpectedDNSSecondary = $ExpectedDNSSecondary
}

# ============================================================================
#  MAIN
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Task 06: Verify DNS Client Configuration" -ForegroundColor Cyan
Write-Host " Node: $(hostname)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ── [1] Verify adapter exists ─────────────────────────────────────────────────
Write-Host ""
Write-Host "[1] Checking management adapter: '$ManagementNIC'" -ForegroundColor Yellow

$adapter = Get-NetAdapter -Name $ManagementNIC -ErrorAction SilentlyContinue
if (-not $adapter) {
    Write-Host "[ERROR] Adapter '$ManagementNIC' not found." -ForegroundColor Red
    Write-Host "        Available adapters:" -ForegroundColor Red
    Get-NetAdapter | Sort-Object Name | Format-Table Name, InterfaceDescription, Status, MacAddress -AutoSize
    exit 1
}
Write-Host "        Found: '$($adapter.InterfaceDescription)' [Status: $($adapter.Status)]" -ForegroundColor Green

# ── [2] Read configured DNS servers ──────────────────────────────────────────
Write-Host ""
Write-Host "[2] Reading DNS configuration on '$ManagementNIC'..." -ForegroundColor Yellow

$dnsConfig     = Get-DnsClientServerAddress -InterfaceAlias $ManagementNIC -AddressFamily IPv4 -ErrorAction SilentlyContinue
$actualServers = @()
if ($dnsConfig -and $dnsConfig.ServerAddresses) {
    $actualServers = @($dnsConfig.ServerAddresses)
}

$actualPrimary   = if ($actualServers.Count -gt 0) { $actualServers[0] } else { "(not set)" }
$actualSecondary = if ($actualServers.Count -gt 1) { $actualServers[1] } else { "(not set)" }

# ── [3] Compare against expected ─────────────────────────────────────────────
Write-Host ""
Write-Host "[3] Validating DNS server configuration..." -ForegroundColor Yellow

$dnsResults = @(
    [PSCustomObject]@{
        Label    = "Primary"
        Expected = $ExpectedDNSPrimary
        Actual   = $actualPrimary
        Status   = if ($actualPrimary -eq $ExpectedDNSPrimary) { "PASS" } else { "FAIL" }
    },
    [PSCustomObject]@{
        Label    = "Secondary"
        Expected = $ExpectedDNSSecondary
        Actual   = $actualSecondary
        Status   = if ($actualSecondary -eq $ExpectedDNSSecondary) { "PASS" } else { "FAIL" }
    }
)

foreach ($r in $dnsResults) {
    $color = if ($r.Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host ("        [{0,-9}] {1,-6}: expected '{2}', got '{3}'" -f $r.Label, $r.Status, $r.Expected, $r.Actual) -ForegroundColor $color
}

# ── [4] Test Azure endpoint resolution ───────────────────────────────────────
Write-Host ""
Write-Host "[4] Testing critical Azure endpoint resolution..." -ForegroundColor Yellow

$azureEndpoints = @(
    "management.azure.com",
    "login.microsoftonline.com",
    "guestnotificationservice.azure.com",
    "dp.kubernetesconfiguration.azure.com",
    "azurecluster.net"
)

$endpointResults = @()
foreach ($ep in $azureEndpoints) {
    try {
        $null = Resolve-DnsName -Name $ep -Type A -ErrorAction Stop
        $status = "RESOLVED"
        Write-Host "        PASS  $ep" -ForegroundColor Green
    } catch {
        $status = "FAILED"
        Write-Host "        FAIL  $ep" -ForegroundColor Red
    }
    $endpointResults += [PSCustomObject]@{ Endpoint = $ep; Status = $status }
}

# ── SUMMARY ───────────────────────────────────────────────────────────────────
$dnsFail      = ($dnsResults      | Where-Object { $_.Status -ne "PASS"     }).Count
$endpointFail = ($endpointResults | Where-Object { $_.Status -ne "RESOLVED" }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " DNS Verification Summary — $(hostname)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "DNS Server Configuration:" -ForegroundColor White
$dnsResults | Format-Table Label, Expected, Actual, Status -AutoSize

Write-Host "Azure Endpoint Resolution:" -ForegroundColor White
$endpointResults | Format-Table Endpoint, Status -AutoSize

if ($dnsFail -eq 0 -and $endpointFail -eq 0) {
    Write-Host "OVERALL: PASS — DNS configuration verified" -ForegroundColor Green
} else {
    Write-Host "OVERALL: FAIL — $dnsFail DNS mismatch(es), $endpointFail endpoint failure(s)" -ForegroundColor Red
    exit 1
}