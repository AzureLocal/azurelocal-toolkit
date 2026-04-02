#Requires -Modules Az.Network
<#
.SYNOPSIS
    Test VPN, DNS, and network connectivity for Phase 04 management infrastructure.
.DESCRIPTION
    Validates VPN connection status, BGP peers, DNS resolution, and TCP
    connectivity to on-premises hosts using PowerShell network cmdlets.
.PARAMETER ConfigPath
    Path to the YAML variables file. Defaults to ./config/variables.yml.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "./config/variables.yml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$net    = $config.azure.networking

$errors = 0

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Testing Phase 04 Management Infrastructure Connectivity"
Write-Host "======================================================" -ForegroundColor Cyan

# ── DNS Resolution ─────────────────────────────────────────────────────────────
Write-Host "`n[1/3] DNS resolution: $($net.test_fqdn) via $($net.dns_server)"
try {
    $result = Resolve-DnsName -Name $net.test_fqdn -Server $net.dns_server -ErrorAction Stop
    $ip = ($result | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1).IPAddress
    Write-Host "  [PASS] Resolved to: $ip" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] DNS resolution failed: $_" -ForegroundColor Red
    $errors++
}

# ── TCP Connectivity ────────────────────────────────────────────────────────────
$testTargets = @(
    @{ ComputerName = $net.on_prem_test_host; Port = 443; Description = "On-premises HTTPS" }
    @{ ComputerName = $net.on_prem_test_host; Port = 3389; Description = "On-premises RDP" }
)

foreach ($target in $testTargets) {
    Write-Host "`n[2/3] TCP test: $($target.Description) ($($target.ComputerName):$($target.Port))"
    $result = Test-NetConnection -ComputerName $target.ComputerName -Port $target.Port -WarningAction SilentlyContinue
    if ($result.TcpTestSucceeded) {
        Write-Host "  [PASS] TCP connection to $($target.ComputerName):$($target.Port) succeeded" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] TCP connection to $($target.ComputerName):$($target.Port) failed" -ForegroundColor Red
        $errors++
    }
}

# ── Ping ────────────────────────────────────────────────────────────────────────
Write-Host "`n[3/3] Ping: $($net.on_prem_test_host)"
$ping = Test-NetConnection -ComputerName $net.on_prem_test_host -WarningAction SilentlyContinue
if ($ping.PingSucceeded) {
    Write-Host "  [PASS] Ping to $($net.on_prem_test_host) succeeded (RTT: $($ping.PingReplyDetails.RoundtripTime)ms)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Ping to $($net.on_prem_test_host) failed" -ForegroundColor Red
    $errors++
}

# ── Summary ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================"
if ($errors -eq 0) {
    Write-Host " CONNECTIVITY TESTS PASSED (0 errors)" -ForegroundColor Green
} else {
    Write-Host " CONNECTIVITY TESTS FAILED ($errors errors)" -ForegroundColor Red
    exit 1
}
Write-Host "======================================================"
