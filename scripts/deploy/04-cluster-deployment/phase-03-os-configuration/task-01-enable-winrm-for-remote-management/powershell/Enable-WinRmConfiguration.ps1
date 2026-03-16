<#
.SYNOPSIS
    Enables and configures WinRM on the local Azure Local node.

.DESCRIPTION
    Bootstrap script that must be run directly on each node via iDRAC Virtual Console.
    WinRM cannot be enabled remotely — this script runs locally.

    Performs the following:
    - Enables WinRM via winrm quickconfig
    - Sets network profile to Private
    - Enables WinRM firewall rules
    - Configures TrustedHosts
    - Verifies WinRM service status

.PARAMETER TrustedHosts
    Management subnet to add to TrustedHosts. Defaults to 10.245.64.*
    Replace with the management subnet from infrastructure.yml.

.EXAMPLE
    .\Enable-WinRmConfiguration.ps1

.EXAMPLE
    .\Enable-WinRmConfiguration.ps1 -TrustedHosts "10.10.10.*"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 2.0.0
    Phase: 03-os-configuration
    Task: task-01-enable-winrm-for-remote-management
    Run on each node locally via iDRAC Virtual Console.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TrustedHosts = "10.245.64.*"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Enable WinRM
winrm quickconfig -q

# Set network profile to Private (required for WinRM)
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Enable WinRM firewall rules
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"

# Configure TrustedHosts — replace with management subnet from infrastructure.yml
Set-Item WSMan:\localhost\Client\TrustedHosts -Value $TrustedHosts -Force

# Verify
Get-Service WinRM | Select-Object Name, Status, StartType
Test-WSMan -ComputerName localhost
