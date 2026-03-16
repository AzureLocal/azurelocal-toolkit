#Requires -Version 5.1
<#
.SYNOPSIS
    Set-StaticIPAddress.ps1
    Configures a static IP address on the management NIC of an Azure Local node.

.DESCRIPTION
    Run directly on each Azure Local node (locally or via PSRemoting).
    All configuration values are defined in the #region CONFIGURATION block below.
    The script does NOT read DHCP-assigned values — all IP settings must be
    explicitly set before running.

    Behaviour:
    - Hard-fails at startup if any REPLACE placeholder values remain
    - Looks up the NIC by exact name; lists all adapters and exits if not found
    - If the adapter already has the correct static IP, exits cleanly (idempotent)
    - If the adapter has the correct IP but is still DHCP-assigned, locks it in as static
    - Validates all settings after applying; retries up to $RetryCount times
    - Validates: IP, prefix length, PrefixOrigin = Manual, DHCP disabled, gateway route, DNS servers

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-03-configure-static-ip-address
    Execution:    Run directly on the node (console, KVM, or PSRemoting)
    Prerequisites: PowerShell 5.1+, local admin rights
    Source values: infrastructure.yml per-node management_ip, network.management.gateway,
                   dns.primary, dns.secondary, cluster.management_nic_name

.EXAMPLE
    # Copy to node, edit #region CONFIGURATION, then run:
    .\Set-StaticIPAddress.ps1
#>

# ============================================================================
#region CONFIGURATION
# Fill in ALL values before running. Script will hard-fail on any REPLACE value.
# ============================================================================

$ManagementNIC  = "REPLACE_WITH_NIC_NAME"   # Exact adapter name from Get-NetAdapter
                                             # Dell Nvidia/Mellanox: "Slot 3 Port 1"
                                             # Dell Embedded Intel/Broadcom: "Embedded NIC 1"
                                             # Source: infrastructure.yml -> cluster.management_nic_name

$IPAddress      = "REPLACE_WITH_IP"         # e.g. "10.10.1.11"
                                             # Source: infrastructure.yml -> nodes.<name>.management_ip

$PrefixLength   = 0                          # Subnet prefix (e.g. 24 for /24, 25 for /25)
                                             # Source: infrastructure.yml -> network.management.prefix_length

$Gateway        = "REPLACE_WITH_GATEWAY"    # e.g. "10.10.1.1"
                                             # Source: infrastructure.yml -> network.management.gateway

$DNSPrimary     = "REPLACE_WITH_DNS1"       # e.g. "10.10.0.10"
                                             # Source: infrastructure.yml -> dns.primary

$DNSSecondary   = "REPLACE_WITH_DNS2"       # e.g. "10.10.0.11"
                                             # Source: infrastructure.yml -> dns.secondary

$RetryCount     = 3                          # Number of attempts if validation fails
$RetryDelaySec  = 10                         # Seconds between retries

#endregion CONFIGURATION
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# FUNCTIONS
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
    $errors = [System.Collections.Generic.List[string]]::new()

    if ($ManagementNIC -eq "REPLACE_WITH_NIC_NAME" -or [string]::IsNullOrWhiteSpace($ManagementNIC)) {
        $errors.Add("ManagementNIC is not set")
    }
    if ($IPAddress -eq "REPLACE_WITH_IP" -or [string]::IsNullOrWhiteSpace($IPAddress)) {
        $errors.Add("IPAddress is not set")
    }
    if ($PrefixLength -eq 0) {
        $errors.Add("PrefixLength is 0 — set the correct subnet prefix (e.g. 24)")
    }
    if ($Gateway -eq "REPLACE_WITH_GATEWAY" -or [string]::IsNullOrWhiteSpace($Gateway)) {
        $errors.Add("Gateway is not set")
    }
    if ($DNSPrimary -eq "REPLACE_WITH_DNS1" -or [string]::IsNullOrWhiteSpace($DNSPrimary)) {
        $errors.Add("DNSPrimary is not set")
    }
    if ($DNSSecondary -eq "REPLACE_WITH_DNS2" -or [string]::IsNullOrWhiteSpace($DNSSecondary)) {
        $errors.Add("DNSSecondary is not set")
    }

    if ($errors.Count -gt 0) {
        Write-Log "=== CONFIGURATION INCOMPLETE ===" "ERROR"
        Write-Log "Edit the #region CONFIGURATION block before running:" "ERROR"
        foreach ($e in $errors) {
            Write-Log "  - $e" "ERROR"
        }
        exit 1
    }
}

function Get-ManagementAdapter {
    # Exact name match only — no guessing
    $adapter = Get-NetAdapter | Where-Object { $_.InterfaceAlias -eq $ManagementNIC }

    if (-not $adapter) {
        Write-Log "Adapter '$ManagementNIC' not found on this node." "ERROR"
        Write-Log "" "ERROR"
        Write-Log "Available adapters:" "WARN"
        Get-NetAdapter | Select-Object Name, InterfaceAlias, Status, MacAddress |
            Format-Table -AutoSize | Out-String | Write-Host
        Write-Log "Update ManagementNIC in #region CONFIGURATION and re-run." "ERROR"
        exit 1
    }

    if ($adapter.Status -ne "Up") {
        Write-Log "Adapter '$ManagementNIC' exists but status is '$($adapter.Status)'. Verify cabling." "WARN"
    }

    return $adapter
}

function Get-CurrentIPState {
    param([Microsoft.Management.Infrastructure.CimInstance]$Adapter)

    $ipConfig   = Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex
    $ipAddress  = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $interface  = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
    $gateway    = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" }
    $dns        = (Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4).ServerAddresses

    return @{
        IPAddress    = $ipAddress.IPAddress
        PrefixLength = $ipAddress.PrefixLength
        PrefixOrigin = $ipAddress.PrefixOrigin
        DHCP         = $interface.Dhcp
        Gateway      = if ($gateway) { $gateway.NextHop } else { $null }
        DNS          = $dns
    }
}

function Test-AlreadyConfigured {
    param([hashtable]$State)

    # Check if the adapter already has the correct static configuration
    $allMatch = (
        $State.IPAddress    -eq $IPAddress      -and
        $State.PrefixLength -eq $PrefixLength   -and
        $State.PrefixOrigin -eq "Manual"        -and
        $State.DHCP         -eq "Disabled"      -and
        $State.Gateway      -eq $Gateway        -and
        ($State.DNS -contains $DNSPrimary)      -and
        ($State.DNS -contains $DNSSecondary)
    )

    return $allMatch
}

function Set-StaticIPConfiguration {
    param([Microsoft.Management.Infrastructure.CimInstance]$Adapter)

    Write-Log "Disabling DHCP..."
    Set-NetIPInterface -InterfaceIndex $Adapter.ifIndex -Dhcp Disabled

    Write-Log "Removing existing IPv4 addresses..."
    Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Write-Log "Removing existing default gateway routes..."
    Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    Write-Log "Setting static IP: $IPAddress/$PrefixLength  GW: $Gateway"
    New-NetIPAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -IPAddress $IPAddress `
        -PrefixLength $PrefixLength `
        -DefaultGateway $Gateway `
        -ErrorAction Stop | Out-Null

    Write-Log "Setting DNS: $DNSPrimary, $DNSSecondary"
    Set-DnsClientServerAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -ServerAddresses @($DNSPrimary, $DNSSecondary)
}

function Wait-ForIPStabilization {
    param([Microsoft.Management.Infrastructure.CimInstance]$Adapter, [int]$TimeoutSec = 30)

    Write-Log "Waiting for IP configuration to stabilize (up to ${TimeoutSec}s)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        $ip = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ip -and $ip.IPAddress -eq $IPAddress) {
            Start-Sleep -Seconds 2   # brief settle
            return $true
        }
        Start-Sleep -Seconds 2
    }

    return $false
}

function Test-Configuration {
    param([Microsoft.Management.Infrastructure.CimInstance]$Adapter)

    $issues = [System.Collections.Generic.List[string]]::new()

    $ip        = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $iface     = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
    $gw        = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" }
    $dnsAddrs  = (Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4).ServerAddresses

    if (-not $ip)                                { $issues.Add("No IPv4 address on adapter") }
    elseif ($ip.IPAddress -ne $IPAddress)        { $issues.Add("IP mismatch: expected $IPAddress, got $($ip.IPAddress)") }
    if ($ip -and $ip.PrefixLength -ne $PrefixLength) { $issues.Add("Prefix mismatch: expected $PrefixLength, got $($ip.PrefixLength)") }
    if ($ip -and $ip.PrefixOrigin -ne "Manual")  { $issues.Add("PrefixOrigin is '$($ip.PrefixOrigin)' — should be 'Manual'") }
    if ($iface.Dhcp -ne "Disabled")              { $issues.Add("DHCP is '$($iface.Dhcp)' — should be 'Disabled'") }
    if (-not $gw)                                { $issues.Add("No default gateway route") }
    elseif ($gw.NextHop -ne $Gateway)            { $issues.Add("Gateway mismatch: expected $Gateway, got $($gw.NextHop)") }
    if ($dnsAddrs -notcontains $DNSPrimary)      { $issues.Add("DNS primary $DNSPrimary not found in: $($dnsAddrs -join ', ')") }
    if ($dnsAddrs -notcontains $DNSSecondary)    { $issues.Add("DNS secondary $DNSSecondary not found in: $($dnsAddrs -join ', ')") }

    return $issues
}

# ============================================================================
# MAIN
# ============================================================================

try {
    Write-Log "=== Set-StaticIPAddress.ps1 ===" "HEADER"
    Write-Log "Node: $($env:COMPUTERNAME)"

    # 1. Validate all config values are filled in
    Assert-ConfigValues

    Write-Log "Configuration:"
    Write-Log "  NIC:      $ManagementNIC"
    Write-Log "  IP:       $IPAddress/$PrefixLength"
    Write-Log "  Gateway:  $Gateway"
    Write-Log "  DNS:      $DNSPrimary, $DNSSecondary"

    # 2. Get adapter (hard-fail if not found)
    $adapter = Get-ManagementAdapter
    Write-Log "Adapter found: $($adapter.InterfaceAlias)  MAC: $($adapter.MacAddress)  Status: $($adapter.Status)"

    # 3. Check current state
    $currentState = Get-CurrentIPState -Adapter $adapter

    Write-Log "Current state:"
    Write-Log "  IP:       $($currentState.IPAddress)/$($currentState.PrefixLength)"
    Write-Log "  Origin:   $($currentState.PrefixOrigin)"
    Write-Log "  DHCP:     $($currentState.DHCP)"
    Write-Log "  Gateway:  $($currentState.Gateway)"
    Write-Log "  DNS:      $($currentState.DNS -join ', ')"

    # 4. Idempotency check — already fully configured?
    if (Test-AlreadyConfigured -State $currentState) {
        Write-Log "Adapter is already correctly configured as static with target IP. No changes needed." "SUCCESS"
        exit 0
    }

    # 5. DHCP == target IP scenario warning
    if ($currentState.IPAddress -eq $IPAddress -and $currentState.PrefixOrigin -eq "Dhcp") {
        Write-Log "NOTE: Adapter currently has the target IP ($IPAddress) via DHCP." "WARN"
        Write-Log "      Proceeding to lock it in as static." "WARN"
    }

    # 6. Apply configuration with retry loop
    $success = $false
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        Write-Log "--- Attempt $attempt of $RetryCount ---" "HEADER"

        try {
            Set-StaticIPConfiguration -Adapter $adapter

            # Wait for IP to appear on the adapter
            if (-not (Wait-ForIPStabilization -Adapter $adapter)) {
                throw "Target IP $IPAddress did not appear on adapter within timeout"
            }

            # Validate
            $issues = Test-Configuration -Adapter $adapter

            if ($issues.Count -eq 0) {
                Write-Log "All validation checks passed." "SUCCESS"
                $success = $true
                break
            } else {
                Write-Log "Validation failed ($($issues.Count) issue(s)):" "WARN"
                foreach ($issue in $issues) { Write-Log "  - $issue" "WARN" }

                if ($attempt -lt $RetryCount) {
                    Write-Log "Waiting $RetryDelaySec seconds before retry..." "WARN"
                    Start-Sleep -Seconds $RetryDelaySec
                }
            }

        } catch {
            Write-Log "Attempt $attempt threw: $_" "ERROR"
            if ($attempt -lt $RetryCount) {
                Write-Log "Waiting $RetryDelaySec seconds before retry..." "WARN"
                Start-Sleep -Seconds $RetryDelaySec
            }
        }
    }

    if (-not $success) {
        Write-Log "FAILED after $RetryCount attempts. Manual intervention required." "ERROR"
        Write-Log "Run: Get-NetIPConfiguration -InterfaceAlias '$ManagementNIC'" "WARN"
        exit 1
    }

    # 7. Final summary
    Write-Log "=== FINAL STATE ===" "HEADER"
    $finalIP    = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    $finalIface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    $finalGW    = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
                    Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" }
    $finalDNS   = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses

    Write-Log "  IP Address:    $($finalIP.IPAddress)/$($finalIP.PrefixLength)"
    Write-Log "  IP Origin:     $($finalIP.PrefixOrigin)"
    Write-Log "  DHCP:          $($finalIface.Dhcp)"
    Write-Log "  Gateway:       $($finalGW.NextHop)"
    Write-Log "  DNS:           $($finalDNS -join ', ')"

    Write-Log "STATIC IP CONFIGURATION COMPLETE" "SUCCESS"
    exit 0

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}
