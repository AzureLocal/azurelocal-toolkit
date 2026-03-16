<#
.SYNOPSIS
    Enable-ICMPFirewallRule.ps1
    Enables ICMP (ping) firewall rules on the local Azure Local node.

.DESCRIPTION
    Run directly ON the target node (console/KVM/RDP).
    Enables the ICMPv4 and ICMPv6 inbound firewall rules required for
    network diagnostics and connectivity validation.

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-08-enable-icmp-ping
    Execution:    Run directly on the node (console, KVM, RDP)
    Prerequisites: Local admin rights
    Run after:    Task 07 - NTP configured

.EXAMPLE
    .\Enable-ICMPFirewallRule.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================================
#  MAIN
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Task 08: Enable ICMP (Ping)" -ForegroundColor Cyan
Write-Host " Node: $(hostname)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$rules = @(
    "File and Printer Sharing (Echo Request - ICMPv4-In)",
    "File and Printer Sharing (Echo Request - ICMPv6-In)"
)

$failed = 0

foreach ($ruleName in $rules) {
    Write-Host ""
    Write-Host "[*] Enabling: $ruleName" -ForegroundColor Yellow

    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        Write-Host "    [WARN] Rule not found -- may already be enabled via policy or named differently" -ForegroundColor Yellow
        continue
    }

    Enable-NetFirewallRule -DisplayName $ruleName
    $rule = Get-NetFirewallRule -DisplayName $ruleName
    if ($rule.Enabled -eq "True") {
        Write-Host "    [PASS] Enabled" -ForegroundColor Green
    } else {
        Write-Host "    [FAIL] Still disabled" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "OVERALL: PASS -- ICMP rules enabled" -ForegroundColor Green
} else {
    Write-Host "OVERALL: FAIL -- $failed rule(s) could not be enabled" -ForegroundColor Red
    exit 1
}
