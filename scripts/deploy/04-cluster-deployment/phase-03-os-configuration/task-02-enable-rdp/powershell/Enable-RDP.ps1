#Requires -Version 5.1
<#
.SYNOPSIS
    Enable-RDP.ps1
    Enables Remote Desktop Protocol on the local Azure Local node.

.DESCRIPTION
    Run directly on each Azure Local node (locally via iDRAC Virtual Console,
    or via PSRemoting once WinRM is enabled from Task 01).

    Performs the following:
    - Enables Remote Desktop via registry
    - Enables RDP firewall rules
    - Verifies RDP is enabled

.EXAMPLE
    .\Enable-RDP.ps1

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-02-enable-rdp
    Execution:    Run directly on the node (iDRAC Virtual Console or PSRemoting)
    Prerequisites: PowerShell 5.1+, local admin rights
#>

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
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# ============================================================================
# MAIN
# ============================================================================

try {
    Write-Log "=== Enable-RDP.ps1 ===" "HEADER"
    Write-Log "Node: $($env:COMPUTERNAME)"

    # Enable Remote Desktop
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name "fDenyTSConnections" -Value 0 -ErrorAction Stop
    Write-Log "Remote Desktop registry key set."

    # Enable RDP firewall rules
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Stop
    Write-Log "Remote Desktop firewall rules enabled."

    # Verify
    $rdp = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name "fDenyTSConnections").fDenyTSConnections

    if ($rdp -eq 0) {
        Write-Log "RDP enabled successfully on $($env:COMPUTERNAME)." "SUCCESS"
    } else {
        Write-Log "ERROR: RDP registry key did not apply correctly on $($env:COMPUTERNAME)." "ERROR"
        exit 1
    }

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}
