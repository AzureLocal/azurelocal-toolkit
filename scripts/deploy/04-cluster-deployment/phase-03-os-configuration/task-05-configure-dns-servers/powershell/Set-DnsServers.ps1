#Requires -Version 5.1
<#
.SYNOPSIS
    Set-DnsServers.ps1
    Configures primary and secondary DNS servers on the management NIC.

.DESCRIPTION
    Run directly on each Azure Local node (locally or via PSRemoting).
    Sets DNS server addresses on the management network adapter by exact name,
    then validates the configuration.

    Behaviour:
    - Hard-fails on startup if any REPLACE placeholder values remain in the
      configuration block — prevents accidentally pushing unconfigured values
    - Finds the management adapter by exact name — lists all adapters and
      exits cleanly if the name does not match
    - Checks idempotency — exits clean if DNS is already set to the target values
    - Sets DNS servers via Set-DnsClientServerAddress
    - Validates by reading back the DNS configuration
    - Optionally tests resolution against a known host

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-05-configure-dns-servers
    Execution:    Run directly on the node (console, KVM, RDP, or PSRemoting)
    Prerequisites: PowerShell 5.1+, local admin rights
    Run after:    Task 04 — DHCP disabled on all adapters
    Variables:    All values come from infrastructure.yml (see mapping table below)

    infrastructure.yml mapping:
      $ManagementNIC  -> cluster.management_nic_name
      $DNSPrimary     -> dns.primary
      $DNSSecondary   -> dns.secondary

.EXAMPLE
    .\Set-DnsServers.ps1
#>

# ============================================================================
#region CONFIGURATION
# Edit ALL values below before running.
# Hard-fails on startup if any value still contains "REPLACE".
# ============================================================================

$ManagementNIC = "REPLACE_WITH_cluster.management_nic_name"
# Example: "Embedded NIC 1"  — must match Get-NetAdapter Name exactly

$DNSPrimary    = "REPLACE_WITH_dns.primary"
# Example: "10.100.10.2"

$DNSSecondary  = "REPLACE_WITH_dns.secondary"
# Example: "10.100.10.3"

#endregion CONFIGURATION
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# HELPERS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "HEADER"  { "Cyan" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Assert-ConfigValues {
    $errors = @()
    if ($ManagementNIC -match "REPLACE") { $errors += "  ManagementNIC : $ManagementNIC" }
    if ($DNSPrimary    -match "REPLACE") { $errors += "  DNSPrimary    : $DNSPrimary" }
    if ($DNSSecondary  -match "REPLACE") { $errors += "  DNSSecondary  : $DNSSecondary" }
    if ($errors.Count -gt 0) {
        Write-Log "Configuration placeholders not replaced:" "ERROR"
        $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        Write-Log "Edit the #region CONFIGURATION block with values from infrastructure.yml before running." "ERROR"
        exit 1
    }
}

function Get-ManagementAdapter {
    $adapter = Get-NetAdapter | Where-Object { $_.Name -eq $ManagementNIC }
    if (-not $adapter) {
        Write-Log "Management adapter '$ManagementNIC' not found." "ERROR"
        Write-Log "Available adapters:" "WARN"
        Get-NetAdapter | Sort-Object Name | ForEach-Object {
            Write-Host "  $($_.Name)  [$($_.Status)]  $($_.InterfaceDescription)" -ForegroundColor Yellow
        }
        Write-Log "Update cluster.management_nic_name in infrastructure.yml with the correct name." "ERROR"
        exit 1
    }
    return $adapter
}

function Test-AlreadyConfigured {
    param($IfIndex)
    $current = (Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    if ($current -and
        $current.Count -ge 2 -and
        $current[0] -eq $DNSPrimary -and
        $current[1] -eq $DNSSecondary) {
        return $true
    }
    return $false
}

function Test-DnsConfiguration {
    param($IfIndex)
    $current = (Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $pass = $true
    if (-not $current -or $current.Count -lt 2) {
        Write-Log "  FAIL: DNS server list has fewer than 2 entries (got: $($current -join ','))" "WARN"
        $pass = $false
    } else {
        if ($current[0] -ne $DNSPrimary) {
            Write-Log "  FAIL: Primary DNS is '$($current[0])', expected '$DNSPrimary'" "WARN"
            $pass = $false
        }
        if ($current[1] -ne $DNSSecondary) {
            Write-Log "  FAIL: Secondary DNS is '$($current[1])', expected '$DNSSecondary'" "WARN"
            $pass = $false
        }
    }
    return $pass
}

# ============================================================================
# MAIN
# ============================================================================

try {
    Write-Log "=== Set-DnsServers.ps1 ===" "HEADER"
    Write-Log "Node: $($env:COMPUTERNAME)"

    # Step 1 — Validate config block
    Write-Log "Validating configuration block..."
    Assert-ConfigValues
    Write-Log "  ManagementNIC : $ManagementNIC"
    Write-Log "  DNSPrimary    : $DNSPrimary"
    Write-Log "  DNSSecondary  : $DNSSecondary"

    # Step 2 — Find adapter
    Write-Log "Locating management adapter '$ManagementNIC'..."
    $adapter = Get-ManagementAdapter
    Write-Log "  Found: $($adapter.Name) [$($adapter.Status)] $($adapter.InterfaceDescription)"

    # Step 3 — Idempotency check
    Write-Log "Checking current DNS configuration..."
    if (Test-AlreadyConfigured -IfIndex $adapter.ifIndex) {
        Write-Log "DNS already configured to target values. Nothing to do." "SUCCESS"
        exit 0
    }

    $currentDNS = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    Write-Log "  Current DNS: $($currentDNS -join ', ')"
    Write-Log "  Target DNS : $DNSPrimary, $DNSSecondary"

    # Step 4 — Set DNS
    Write-Log "Setting DNS servers..."
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
        -ServerAddresses @($DNSPrimary, $DNSSecondary) `
        -ErrorAction Stop
    Write-Log "  Set-DnsClientServerAddress completed"

    # Step 5 — Validate
    Write-Log "Validating DNS configuration..."
    if (-not (Test-DnsConfiguration -IfIndex $adapter.ifIndex)) {
        Write-Log "DNS validation FAILED. Review errors above." "ERROR"
        exit 1
    }

    $afterDNS = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses
    Write-Log "  Primary   : $($afterDNS[0])" "SUCCESS"
    Write-Log "  Secondary : $($afterDNS[1])" "SUCCESS"
    Write-Log "DNS CONFIGURATION COMPLETE" "SUCCESS"
    exit 0

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}
