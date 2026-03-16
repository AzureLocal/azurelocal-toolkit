# ==============================================================================
# Script : Get-VirtualSwitchName-Standalone.ps1
# Purpose: Discover the external vSwitch name on this cluster node and display
#          the value to copy into infrastructure.yml
# Run    : RDP or console directly on any cluster node — no external dependencies
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Discover External vSwitch Name"                                   -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$switches = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' }

if (-not $switches) {
    Write-Host "ERROR: No external vSwitch found on this node." -ForegroundColor Red
    Write-Host "       Verify cluster networking is configured before proceeding." -ForegroundColor Red
    exit 1
}

Write-Host "External vSwitch(es) found:" -ForegroundColor Green
Write-Host ""
$switches | Format-Table Name, SwitchType, NetAdapterInterfaceDescription -AutoSize

$primary = $switches | Select-Object -First 1
Write-Host "================================================================" -ForegroundColor Green
Write-Host " Copy this value into configs/infrastructure.yml:"                 -ForegroundColor Green
Write-Host ""
Write-Host "  compute:"                                                         -ForegroundColor White
Write-Host "    azure_local:"                                                   -ForegroundColor White
Write-Host "      vm_switch_name: `"$($primary.Name)`"" -ForegroundColor Yellow
Write-Host ""
Write-Host "  YAML path: compute.azure_local.vm_switch_name"                   -ForegroundColor Gray
Write-Host "================================================================" -ForegroundColor Green
