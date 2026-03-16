#Requires -Version 5.1
<#
.SYNOPSIS
    Start-Phase03OsConfiguration.ps1
    Runs all Phase 03 OS configuration steps (Tasks 02–10) locally on a single node.

.DESCRIPTION
    Run this script directly on each cluster node (via RDP or iDRAC console) to
    complete all Phase 03 OS configuration tasks in a single execution:

      Task 02 - Enable RDP
      Task 03 - Configure static IP address
      Task 04 - Disable DHCP on management adapter
      Task 05 - Configure DNS servers
      Task 06 - Verify DNS client configuration
      Task 07 - Configure NTP (time synchronization)
      Task 08 - Enable ICMP (ping)
      Task 09 - Disable unused network adapters
      Task 10 - Configure hostname (rename + restart prompt)

    Set all -REPLACE_ parameter values before running. The script will refuse to
    run if any parameter still contains the default "REPLACE_" placeholder.

    *** Task 01 (Enable WinRM) must be completed before running this script.
    *** Task 11 (Clear Previous Storage) is conditional — run separately if needed.

    All values can be found in infrastructure.yml:
      -StaticIP      -> compute.cluster_nodes.<name>.management_ip
      -Gateway       -> compute.azure_local.default_gateway
      -PrefixLength  -> compute.azure_local.subnet_mask (e.g. 24 for 255.255.255.0)
      -DNSPrimary    -> compute.azure_local.dns_servers[0]
      -DNSSecondary  -> compute.azure_local.dns_servers[1]
      -NTPServer     -> NTP peer (e.g. time.windows.com or internal NTP)
      -NewHostname   -> compute.cluster_nodes.<name>.hostname

.PARAMETER StaticIP
    Static management IP to assign to the management adapter.
    Example: "192.168.211.11"

.PARAMETER Gateway
    Default gateway for the management network.
    Example: "192.168.211.1"

.PARAMETER PrefixLength
    Subnet prefix length (e.g. 24 for /24 or 255.255.255.0).
    Default: 24

.PARAMETER DNSPrimary
    Primary DNS server IP.

.PARAMETER DNSSecondary
    Secondary DNS server IP.

.PARAMETER NTPServer
    NTP server address(es). Separate multiple with a space.
    Default: "time.windows.com"

.PARAMETER NewHostname
    Target hostname for this node (must comply with NetBIOS naming rules).
    Example: "azl-lab-01-n01"

.PARAMETER SkipRestart
    If specified, suppresses the restart prompt at the end.
    Use only if you intend to restart the node manually.

.EXAMPLE
    .\Start-Phase03OsConfiguration.ps1 `
        -StaticIP "192.168.211.11" `
        -Gateway "192.168.211.1" `
        -DNSPrimary "10.250.1.36" `
        -DNSSecondary "10.250.1.37" `
        -NewHostname "azl-lab-01-n01"

.EXAMPLE
    .\Start-Phase03OsConfiguration.ps1 `
        -StaticIP "192.168.211.12" -Gateway "192.168.211.1" `
        -DNSPrimary "10.250.1.36" -DNSSecondary "10.250.1.37" `
        -NTPServer "10.250.0.1 time.windows.com" `
        -NewHostname "azl-lab-01-n02" `
        -SkipRestart

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-12-complete-combined-script-all-steps
    Execution:    Run locally on each node (RDP, console, SConfig terminal)
    Prerequisites: WinRM enabled (Task 01), PowerShell 5.1+, local admin rights
    Excludes:     Task 01 (WinRM — manual), Task 11 (Clear Storage — conditional)
    Run as:       Local Administrator
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$StaticIP = "REPLACE_WITH_STATIC_IP",

    [Parameter(Mandatory = $false)]
    [string]$Gateway = "REPLACE_WITH_GATEWAY",

    [Parameter(Mandatory = $false)]
    [int]$PrefixLength = 24,

    [Parameter(Mandatory = $false)]
    [string]$DNSPrimary = "REPLACE_WITH_DNS_PRIMARY",

    [Parameter(Mandatory = $false)]
    [string]$DNSSecondary = "REPLACE_WITH_DNS_SECONDARY",

    [Parameter(Mandatory = $false)]
    [string]$NTPServer = "time.windows.com",

    [Parameter(Mandatory = $false)]
    [string]$NewHostname = "REPLACE_WITH_HOSTNAME",

    [switch]$SkipRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "SUCCESS" { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "ERROR"   { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
        "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
        default   { Write-Host "[$ts] [INFO] $Message" }
    }
}

# ---------------------------------------------------------------------------
# Validate parameters — no REPLACE_ placeholders allowed
# ---------------------------------------------------------------------------
$placeholders = @{
    "-StaticIP"     = $StaticIP
    "-Gateway"      = $Gateway
    "-DNSPrimary"   = $DNSPrimary
    "-DNSSecondary" = $DNSSecondary
    "-NewHostname"  = $NewHostname
}

$invalid = $placeholders.GetEnumerator() | Where-Object { $_.Value -match "^REPLACE_" }
if ($invalid) {
    Write-Host ""
    Write-Host "ERROR: The following parameters still contain placeholder values:" -ForegroundColor Red
    $invalid | ForEach-Object { Write-Host "  $($_.Key) = '$($_.Value)'" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Set all required values before running. See Get-Help for examples." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Log "================================================================" HEADER
Write-Log "   Phase 03 OS Configuration — Local Execution (Tasks 02–10)" HEADER
Write-Log "================================================================" HEADER
Write-Log "  Running on   : $($env:COMPUTERNAME)"
Write-Log "  Target IP    : $StaticIP/$PrefixLength  GW: $Gateway"
Write-Log "  DNS          : $DNSPrimary, $DNSSecondary"
Write-Log "  NTP          : $NTPServer"
Write-Log "  New hostname : $NewHostname"
Write-Log ""

$errors = @()

function Run-Task {
    param([string]$Name, [scriptblock]$Action)
    Write-Log "--- $Name ---" HEADER
    try {
        $out = & $Action
        if ($out) { foreach ($l in @($out)) { if ($l -is [string]) { Write-Log "  $($l.Trim())" } } }
        Write-Log "$Name — DONE" SUCCESS
    } catch {
        Write-Log "$Name — FAILED: $($_.Exception.Message)" ERROR
        $script:errors += "$Name : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Task 02 — Enable RDP
# ---------------------------------------------------------------------------
Run-Task "Task 02 - Enable RDP" {
    Set-ItemProperty `
        -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name fDenyTSConnections -Value 0 -ErrorAction Stop
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Stop
    "RDP enabled and firewall rule activated."
}

# ---------------------------------------------------------------------------
# Task 03/04 — Disable DHCP + Configure Static IP
# ---------------------------------------------------------------------------
Run-Task "Task 03/04 - Disable DHCP + Configure Static IP" {
    # Prefer adapter that currently holds the target IP; fall back to first Up adapter
    $adapter = Get-NetAdapter -ErrorAction Stop |
        Where-Object { $_.Status -eq "Up" } |
        Sort-Object {
            $ip4 = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 `
                        -ErrorAction SilentlyContinue).IPAddress
            if ($ip4 -contains $StaticIP) { 0 } else { 1 }
        } |
        Select-Object -First 1

    if (-not $adapter) { throw "No active (Up) network adapter found." }

    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled -ErrorAction Stop

    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress `
        -InterfaceIndex $adapter.ifIndex `
        -IPAddress $StaticIP `
        -PrefixLength $PrefixLength `
        -DefaultGateway $Gateway `
        -ErrorAction Stop | Out-Null

    "Adapter '$($adapter.Name)': IP=$StaticIP/$PrefixLength  GW=$Gateway  DHCP=Disabled"
}

# ---------------------------------------------------------------------------
# Task 05 — Configure DNS Servers
# ---------------------------------------------------------------------------
Run-Task "Task 05 - Configure DNS Servers" {
    $adapter = Get-NetAdapter -ErrorAction Stop |
        Where-Object { $_.Status -eq "Up" } |
        Sort-Object {
            $ip4 = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 `
                        -ErrorAction SilentlyContinue).IPAddress
            if ($ip4 -contains $StaticIP) { 0 } else { 1 }
        } |
        Select-Object -First 1

    if (-not $adapter) { throw "No active network adapter found for DNS configuration." }

    Set-DnsClientServerAddress `
        -InterfaceIndex $adapter.ifIndex `
        -ServerAddresses @($DNSPrimary, $DNSSecondary) `
        -ErrorAction Stop

    "DNS set on '$($adapter.Name)': primary=$DNSPrimary, secondary=$DNSSecondary"
}

# ---------------------------------------------------------------------------
# Task 06 — Verify DNS Configuration
# ---------------------------------------------------------------------------
Run-Task "Task 06 - Verify DNS Configuration" {
    $configured = Get-DnsClientServerAddress -AddressFamily IPv4 |
        Where-Object { $_.ServerAddresses.Count -gt 0 }

    $allServers = @($configured | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)

    if ($allServers -notcontains $DNSPrimary) {
        throw "Primary DNS $DNSPrimary not found in configured servers: $($allServers -join ', ')"
    }
    "DNS verified — configured servers: $($allServers -join ', ')"
}

# ---------------------------------------------------------------------------
# Task 07 — Configure NTP
# ---------------------------------------------------------------------------
Run-Task "Task 07 - Configure NTP" {
    & w32tm /config /manualpeerlist:"$NTPServer" /syncfromflags:manual /update 2>&1 | Out-Null
    Restart-Service w32time -ErrorAction Stop
    & w32tm /resync 2>&1 | Out-Null
    $source = (& w32tm /query /source 2>&1 | Out-String).Trim()
    "NTP configured. Current source: $source"
}

# ---------------------------------------------------------------------------
# Task 08 — Enable ICMP
# ---------------------------------------------------------------------------
Run-Task "Task 08 - Enable ICMP" {
    $icmpRules = @(
        "File and Printer Sharing (Echo Request - ICMPv4-In)",
        "Core Networking Diagnostics - ICMP Echo Request (ICMPv4-In)"
    )
    $enabled = 0
    foreach ($ruleName in $icmpRules) {
        try { Enable-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop; $enabled++ } catch {}
    }
    if ($enabled -eq 0) {
        Enable-NetFirewallRule -Group "File and Printer Sharing" -ErrorAction SilentlyContinue
    }
    "ICMP firewall rules enabled ($enabled rule(s) matched by name)."
}

# ---------------------------------------------------------------------------
# Task 09 — Disable Unused Network Adapters
# ---------------------------------------------------------------------------
Run-Task "Task 09 - Disable Unused Adapters" {
    $disconnected = @(Get-NetAdapter | Where-Object { $_.Status -eq "Disconnected" })
    if ($disconnected.Count -eq 0) {
        "No disconnected adapters found — nothing to disable."
    } else {
        foreach ($a in $disconnected) {
            Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop
        }
        "Disabled $($disconnected.Count) adapter(s): $($disconnected.Name -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# Task 10 — Configure Hostname
# ---------------------------------------------------------------------------
Write-Log "--- Task 10 - Configure Hostname ---" HEADER

$currentName = $env:COMPUTERNAME
if ($currentName -eq $NewHostname) {
    Write-Log "Hostname already '$NewHostname' — skipping rename." SUCCESS
} else {
    Write-Log "Current hostname: '$currentName' — renaming to '$NewHostname'..."
    try {
        Rename-Computer -NewName $NewHostname -Force -ErrorAction Stop
        Write-Log "Task 10 - Configure Hostname — DONE" SUCCESS
        Write-Log "** Restart required to apply hostname change. **" WARN
    } catch {
        Write-Log "Task 10 - Configure Hostname — FAILED: $($_.Exception.Message)" ERROR
        $errors += "Task 10 - Configure Hostname : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Log ""
Write-Log "================================================================" HEADER
Write-Log "  SUMMARY" HEADER
Write-Log "================================================================" HEADER

if ($errors.Count -gt 0) {
    Write-Log "$($errors.Count) task(s) had errors:" ERROR
    $errors | ForEach-Object { Write-Log "  $_" ERROR }
} else {
    Write-Log "All tasks completed successfully on $($env:COMPUTERNAME)." SUCCESS
}

Write-Log ""
Write-Log "Post-script checklist:"
Write-Log "  1. Verify network: Test-NetConnection $Gateway"
Write-Log "  2. Verify DNS:     Resolve-DnsName $DNSPrimary"
Write-Log "  3. Verify NTP:     w32tm /query /status"
Write-Log "  4. Restart the node to apply the hostname change."

# ---------------------------------------------------------------------------
# Restart prompt
# ---------------------------------------------------------------------------
if (-not $SkipRestart -and $currentName -ne $NewHostname -and $errors.Count -eq 0) {
    Write-Log ""
    Write-Host -NoNewline "Restart now to apply hostname change? [Y/N]: " -ForegroundColor Yellow
    $answer = Read-Host
    if ($answer -match "^[Yy]") {
        Write-Log "Restarting $($env:COMPUTERNAME) now..."
        Restart-Computer -Force
    } else {
        Write-Log "Restart skipped. Remember to restart before proceeding to Phase 04." WARN
    }
}

if ($errors.Count -gt 0) { exit 1 }
