<#
.SYNOPSIS
    Set-NTPConfiguration.ps1
    Configures the NTP time source on the local Azure Local node.

.DESCRIPTION
    Run directly ON the target node (console/KVM/RDP).
    Configures w32tm with the specified NTP server, restarts the time service,
    forces an immediate resync, and reports the current sync status.

    Variables: All values come from infrastructure.yml
      active_directory.ntp_servers[0]  -> $NTPServer

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-07-configure-time-synchronization-ntp
    Execution:    Run directly on the node (console, KVM, RDP)
    Prerequisites: Local admin rights
    Run after:    Task 06 - DNS verified

.EXAMPLE
    .\Set-NTPConfiguration.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region CONFIGURATION
$NTPServer = "REPLACE_WITH_NTP_SERVER"   # active_directory.ntp_servers[0]
#endregion CONFIGURATION

if ($NTPServer -match "^REPLACE_") {
    Write-Host "[ERROR] Set `$NTPServer before running" -ForegroundColor Red; exit 1
}

# Pre-flight: verify at least one NTP peer is reachable
$peers = $NTPServer -split '\s+' | Where-Object { $_ -ne '' }
$reachable = @()
foreach ($peer in $peers) {
    if (Test-Connection -ComputerName $peer -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        $reachable += $peer
        Write-Host "[INFO] NTP peer reachable: $peer" -ForegroundColor Cyan
    } else {
        Write-Host "[WARN] NTP peer NOT reachable: $peer" -ForegroundColor Yellow
    }
}
if ($reachable.Count -eq 0) {
    Write-Host "[ERROR] No NTP peers reachable: $($peers -join ', '). Deploy DCs first." -ForegroundColor Red
    exit 1
}

w32tm /config /manualpeerlist:$NTPServer /syncfromflags:manual /reliable:YES /update
Restart-Service w32time -Force
w32tm /resync /force

$status  = w32tm /query /status
$status
$source  = ($status | Select-String 'Source:')  -replace '.*Source:\s*(.+)', '$1'
$stratum = ($status | Select-String 'Stratum:') -replace '.*Stratum:\s*(\d+).*', '$1'
if ($source -match 'Local CMOS Clock|Free-running') {
    Write-Host "[ERROR] NTP not syncing — source is '$($source.Trim())' despite peers being reachable." -ForegroundColor Red
    exit 1
}
Write-Host "[PASS] NTP configured. Stratum: $($stratum.Trim())  Source: $($source.Trim())" -ForegroundColor Green
