# ==============================================================================
# Script : Set-SDNDns-Standalone.ps1
# Purpose: Configure DNS for SDN deployment — validates dynamic DNS zone update
#          settings or creates/validates a static A record for the Network
#          Controller REST endpoint.
#          Run this script directly on the DNS server (domain controller).
#          No external dependencies — no infrastructure.yml, no helpers.
# Run    : RDP to the domain controller and execute
# ==============================================================================

#region CONFIGURATION
# ── Edit these values to match your environment ──────────────────────────────

# DNS zone name (your AD domain FQDN)
$ZoneName = "improbability.cloud"

# SDN prefix — used to form the NC REST URL: https://<Prefix>-NC.<domain>/
$SdnPrefix = "iic01"

# DNS mode: "dynamic" (AD-integrated, auto-creates record) or "static" (pre-create A record manually)
$SdnDnsMode = "dynamic"

# Reserved IP for Network Controller DNS record — 5th IP in your management pool
# Required only when $SdnDnsMode = "static"
$SdnNcReservedIp = "192.168.211.14"

# WhatIf: report only, do not create records
$WhatIf = $false

#endregion CONFIGURATION

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ncRecordName = "$SdnPrefix-NC"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Prepare SDN DNS"                                                  -ForegroundColor Cyan
Write-Host " Zone       : $ZoneName"                                           -ForegroundColor Cyan
Write-Host " Record     : $ncRecordName"                                       -ForegroundColor Cyan
Write-Host " DNS Mode   : $SdnDnsMode"                                         -ForegroundColor Cyan
if ($SdnDnsMode -eq 'static') {
Write-Host " Reserved IP: $SdnNcReservedIp"                                    -ForegroundColor Cyan
}
Write-Host " WhatIf     : $WhatIf"                                             -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

Import-Module DnsServer -ErrorAction Stop

# ── Check zone ────────────────────────────────────────────────────────────────
Write-Host "-- Checking DNS zone '$ZoneName'..."
$zone = Get-DnsServerZone -Name $ZoneName -ErrorAction SilentlyContinue
if (-not $zone) {
    Write-Host "ERROR: DNS zone '$ZoneName' not found on this server" -ForegroundColor Red
    exit 1
}
Write-Host "  Zone found: $ZoneName"

# ── Dynamic DNS ───────────────────────────────────────────────────────────────
if ($SdnDnsMode -eq 'dynamic') {
    Write-Host ""
    Write-Host "-- Checking dynamic update setting..."
    $dynUpdate = $zone.DynamicUpdate
    Write-Host "  DynamicUpdate: $dynUpdate"

    if ($dynUpdate -eq 'None') {
        Write-Host ""
        Write-Host "  ERROR: Zone '$ZoneName' has DynamicUpdate = None" -ForegroundColor Red
        Write-Host "         SDN cannot register the NC record automatically." -ForegroundColor Red
        Write-Host "         Fix: Set-DnsServerPrimaryZone -Name '$ZoneName' -DynamicUpdate Secure" -ForegroundColor Yellow
        exit 1
    }

    if ($dynUpdate -eq 'Secure') {
        Write-Host "  PASS: DynamicUpdate = Secure (recommended)" -ForegroundColor Green
    } else {
        Write-Host "  WARN: DynamicUpdate = $dynUpdate — Secure is recommended" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "-- Checking for pre-existing '$ncRecordName' record..."
    $existing = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $ncRecordName -RRType A -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  WARN: Record '$ncRecordName' already exists — IP: $($existing.RecordData.IPv4Address)" -ForegroundColor Yellow
        Write-Host "         Review this record — if stale from a previous deployment, remove it before proceeding." -ForegroundColor Yellow
    } else {
        Write-Host "  PASS: No pre-existing record — dynamic DNS will create it automatically." -ForegroundColor Green
    }
}

# ── Static DNS ────────────────────────────────────────────────────────────────
if ($SdnDnsMode -eq 'static') {
    if (-not $SdnNcReservedIp) {
        Write-Host "ERROR: SdnNcReservedIp is required for static DNS mode" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "-- Checking for existing '$ncRecordName' record..."
    $existing = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $ncRecordName -RRType A -ErrorAction SilentlyContinue

    if ($existing) {
        $existingIp = $existing.RecordData.IPv4Address.ToString()
        if ($existingIp -eq $SdnNcReservedIp) {
            Write-Host "  PASS: Record '$ncRecordName' already exists with correct IP $SdnNcReservedIp — nothing to do." -ForegroundColor Green
        } else {
            Write-Host "  WARN: Record '$ncRecordName' exists but points to $existingIp — expected $SdnNcReservedIp" -ForegroundColor Yellow
            Write-Host "         Remove the stale record and re-run, or update it manually." -ForegroundColor Yellow
        }
    } else {
        if ($WhatIf) {
            Write-Host "  [WhatIf] Would create DNS A record '$ncRecordName' -> $SdnNcReservedIp" -ForegroundColor Yellow
        } else {
            Write-Host "-- Creating DNS A record '$ncRecordName' -> $SdnNcReservedIp..."
            try {
                Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $ncRecordName -IPv4Address $SdnNcReservedIp -ErrorAction Stop
                Write-Host "  PASS: Created DNS A record '$ncRecordName' -> $SdnNcReservedIp" -ForegroundColor Green
            } catch {
                Write-Host "  ERROR: Failed to create DNS record: $_" -ForegroundColor Red
                exit 1
            }

            Write-Host ""
            Write-Host "-- Verifying DNS resolution for '$ncRecordName.$ZoneName'..."
            try {
                $resolved = Resolve-DnsName "$ncRecordName.$ZoneName" -ErrorAction Stop
                $resolvedIp = ($resolved | Where-Object QueryType -eq 'A' | Select-Object -First 1).IPAddress
                if ($resolvedIp -eq $SdnNcReservedIp) {
                    Write-Host "  PASS: '$ncRecordName.$ZoneName' resolves to $resolvedIp" -ForegroundColor Green
                } else {
                    Write-Host "  WARN: '$ncRecordName.$ZoneName' resolves to $resolvedIp — expected $SdnNcReservedIp" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  WARN: Resolution check failed (replication lag?) — retry in a few seconds: $_" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " DNS preparation complete — proceed to Step 3"                     -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
