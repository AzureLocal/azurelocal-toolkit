<#
.SYNOPSIS
    Test-LocalIdentityConfig.ps1
    Verifies Local Identity (AD-less) configuration directly on this cluster node.

.DESCRIPTION
    Run this script directly ON a cluster node (via RDP or console session).
    Verifies that the cluster deployed in AD-less mode by checking that:
      1. The node is NOT domain-joined (Domain = WORKGROUP)
      2. The cluster ADAware parameter = 2 (AD-less mode)
    No PSRemoting or infrastructure.yml required — runs in local context.

    Source: https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-03-verify-deployment-completion
    Execution:    Run directly ON a cluster node (console/RDP)
    Run after:    Portal deployment completes

.EXAMPLE
    .\Test-LocalIdentityConfig.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "`n=== Local Identity Configuration Verification — $env:COMPUTERNAME ===" -ForegroundColor Cyan

$passCount = 0
$warnCount = 0

# ── Check 1: Node must NOT be domain-joined — expected: WORKGROUP ─────────────
Write-Host "`n--- Check 1: Domain Membership ---" -ForegroundColor Cyan
$domain = (Get-WmiObject Win32_ComputerSystem).Domain
Write-Host "  Domain: $domain" -ForegroundColor $(if ($domain -eq 'WORKGROUP') { 'Green' } else { 'Red' })
if ($domain -eq 'WORKGROUP') {
    Write-Host "[PASS] Node is not domain-joined (WORKGROUP)" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "[FAIL] Node is domain-joined ('$domain'). Expected WORKGROUP for Local Identity." -ForegroundColor Red
    $warnCount++
}

# ── Check 2: Cluster must be in AD-less mode — expected: ADAware = 2 ─────────
Write-Host "`n--- Check 2: Cluster ADAware Parameter ---" -ForegroundColor Cyan
try {
    $adAware = Get-ClusterResource "Cluster Name" | Get-ClusterParameter ADAware
    Write-Host "  ADAware: $($adAware.Value)" -ForegroundColor $(if ($adAware.Value -eq 2) { 'Green' } else { 'Red' })
    if ($adAware.Value -eq 2) {
        Write-Host "[PASS] ADAware = 2 (cluster is in AD-less / Local Identity mode)" -ForegroundColor Green
        $passCount++
    } else {
        Write-Host "[FAIL] ADAware = $($adAware.Value). Expected 2 for Local Identity mode." -ForegroundColor Red
        $warnCount++
    }
} catch {
    Write-Host "[FAIL] Could not read ADAware parameter: $_" -ForegroundColor Red
    $warnCount++
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  PASS: $passCount / 2"
Write-Host "  FAIL: $warnCount / 2"

if ($warnCount -eq 0) {
    Write-Host "`n[PASS] Local Identity configuration verified on $env:COMPUTERNAME" -ForegroundColor Green
} else {
    Write-Host "`n[FAIL] $warnCount check(s) failed on $env:COMPUTERNAME" -ForegroundColor Red
    exit 1
}
