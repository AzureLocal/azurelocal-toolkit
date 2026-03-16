#Requires -Version 5.1
<#
.SYNOPSIS
    Disable-DHCPOnAllAdapters.ps1
    Disables DHCP on all network adapters except virtual/management adapters.

.DESCRIPTION
    Run directly on each Azure Local node (locally or via PSRemoting).
    Disables DHCP on every physical NIC. Adapters whose InterfaceDescription
    matches the $ExcludePattern are skipped — this preserves DHCP on Remote NDIS
    and Hyper-V virtual adapters.

    Why exclude NDIS / virtual adapters:
    - Remote NDIS Compatible Device: USB or virtual management NIC — should keep DHCP
    - Hyper-V Virtual Ethernet Adapter: post-cluster vEthernet — must keep DHCP
    - WAN Miniport: VPN/routing tunnels — no meaningful IPv4 interface to set

    Behaviour:
    - Skips adapters matching $ExcludePattern in InterfaceDescription
    - Skips adapters with no IPv4 interface (nothing to configure)
    - Checks idempotency — already-disabled adapters are reported as OK, not re-set
    - Logs a final table of every adapter: Name, Description, Status, DHCP result

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-04-disable-dhcp-on-management-adapter
    Execution:    Run directly on the node (console, KVM, RDP, or PSRemoting)
    Prerequisites: PowerShell 5.1+, local admin rights
    Run after:    Task 03 — static IP must already be configured on management NIC

.EXAMPLE
    .\Disable-DHCPOnAllAdapters.ps1
#>

# ============================================================================
#region CONFIGURATION
# Adapters whose InterfaceDescription matches ANY of these patterns will be SKIPPED.
# Add patterns here to protect additional virtual or management adapters.
# ============================================================================

$ExcludePattern = "NDIS|Hyper-V Virtual|WAN Miniport|Bluetooth|Wi-Fi Direct|Microsoft Kernel Debug|Multiplexor"

#endregion CONFIGURATION
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "HEADER"  { "Cyan" }
        "SKIP"    { "DarkGray" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# ============================================================================
# MAIN
# ============================================================================

try {
    Write-Log "=== Disable-DHCPOnAllAdapters.ps1 ===" "HEADER"
    Write-Log "Node: $($env:COMPUTERNAME)"
    Write-Log "Exclude pattern: $ExcludePattern"

    $adapters = Get-NetAdapter | Sort-Object Name

    if ($adapters.Count -eq 0) {
        Write-Log "No network adapters found." "WARN"
        exit 0
    }

    Write-Log "Adapters found: $($adapters.Count)"

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($adapter in $adapters) {
        $desc   = $adapter.InterfaceDescription
        $name   = $adapter.Name
        $status = $adapter.Status

        # Check exclude pattern
        if ($desc -match $ExcludePattern) {
            Write-Log "  SKIP  $name  ($desc)" "SKIP"
            $results.Add([PSCustomObject]@{
                Name        = $name
                Description = $desc
                Status      = $status
                DHCP        = "Skipped (excluded)"
                Result      = "Skipped"
            })
            continue
        }

        # Get IPv4 interface — some adapters have no IPv4 interface
        $ipIface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $ipIface) {
            Write-Log "  SKIP  $name  (no IPv4 interface)" "SKIP"
            $results.Add([PSCustomObject]@{
                Name        = $name
                Description = $desc
                Status      = $status
                DHCP        = "N/A (no IPv4)"
                Result      = "Skipped"
            })
            continue
        }

        # Idempotency check
        if ($ipIface.Dhcp -eq "Disabled") {
            Write-Log "  OK    $name  (already Disabled)" "SUCCESS"
            $results.Add([PSCustomObject]@{
                Name        = $name
                Description = $desc
                Status      = $status
                DHCP        = "Disabled"
                Result      = "AlreadyDisabled"
            })
            continue
        }

        # Disable DHCP
        try {
            Write-Log "  SET   $name  ($status)  $($ipIface.Dhcp) -> Disabled"
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop

            # Verify
            $afterIface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($afterIface.Dhcp -eq "Disabled") {
                Write-Log "  OK    $name  DHCP disabled" "SUCCESS"
                $results.Add([PSCustomObject]@{
                    Name        = $name
                    Description = $desc
                    Status      = $status
                    DHCP        = "Disabled"
                    Result      = "Changed"
                })
            } else {
                Write-Log "  FAIL  $name  DHCP is still $($afterIface.Dhcp)" "WARN"
                $results.Add([PSCustomObject]@{
                    Name        = $name
                    Description = $desc
                    Status      = $status
                    DHCP        = $afterIface.Dhcp
                    Result      = "Failed"
                })
            }
        } catch {
            Write-Log "  ERROR $name  $_" "ERROR"
            $results.Add([PSCustomObject]@{
                Name        = $name
                Description = $desc
                Status      = $status
                DHCP        = "Error"
                Result      = "Error: $_"
            })
        }
    }

    # Final summary table
    Write-Log "=== RESULTS ===" "HEADER"
    $results | Format-Table -AutoSize | Out-String | Write-Host

    $failed = @($results | Where-Object { $_.Result -notin @("Changed","AlreadyDisabled","Skipped") })
    if ($failed.Count -gt 0) {
        Write-Log "$($failed.Count) adapter(s) failed. Review errors above." "WARN"
        exit 1
    }

    $changed  = @($results | Where-Object { $_.Result -eq "Changed" }).Count
    $already  = @($results | Where-Object { $_.Result -eq "AlreadyDisabled" }).Count
    $skipped  = @($results | Where-Object { $_.Result -eq "Skipped" }).Count
    Write-Log "Changed: $changed  Already disabled: $already  Skipped: $skipped" "SUCCESS"
    Write-Log "DHCP DISABLE COMPLETE" "SUCCESS"
    exit 0

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}
