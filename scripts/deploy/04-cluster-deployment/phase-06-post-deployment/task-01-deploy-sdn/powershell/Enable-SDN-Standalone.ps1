# ==============================================================================
# Script : Enable-SDN-Standalone.ps1
# Purpose: Enable SDN integration on Azure Local — Network Controller as
#          Failover Cluster service (SDN enabled by Arc) — fully self-contained
# Run    : From management server or jump box with PSRemoting to a cluster node
# WARNING: SDN enablement is IRREVERSIBLE. Once enabled, it cannot be disabled.
# ==============================================================================

#region CONFIGURATION
# ── Edit these values to match your environment ──────────────────────────────

# Target cluster node (any node; run Add-EceFeature on one node only)
$TargetNode = "iic-01-n01"

# SDN prefix — used to form the NC REST URL: https://<Prefix>-NC.<domain>/
# Rules: max 8 chars, alphanumeric + hyphens, no consecutive hyphens, no trailing hyphen
$SdnPrefix = "iic01"

# DNS mode: "dynamic" (AD-integrated, auto-creates record) or "static" (pre-create A record manually)
$SdnDnsMode = "dynamic"

# Reserved IP for Network Controller DNS record — 5th IP in your management pool
# Required only when $SdnDnsMode = "static"
$SdnNcReservedIp = "192.168.211.14"

# Network intent pattern on this cluster: 1 = single intent, 2 = mgmt+compute / storage, 3 = disaggregated
$SdnIntentPattern = 2

# Suppress interactive prompts (set $true when running unattended)
$AcknowledgeMaintenanceWindow = $false
$AcknowledgeDNSRecordCreation = $false

# Credentials for PSRemoting (leave $null to use current session credentials)
$Credential = $null

#endregion CONFIGURATION

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Deploy SDN — Standalone"                                          -ForegroundColor Cyan
Write-Host " Target Node    : $TargetNode"                                     -ForegroundColor Cyan
Write-Host " SDN Prefix     : $SdnPrefix"                                      -ForegroundColor Cyan
Write-Host " DNS Mode       : $SdnDnsMode"                                     -ForegroundColor Cyan
Write-Host " Intent Pattern : $SdnIntentPattern"                               -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "WARNING: SDN enablement is IRREVERSIBLE." -ForegroundColor Yellow
Write-Host "         Once Network Controller is deployed it cannot be removed." -ForegroundColor Yellow
Write-Host ""

# ── Validate SDN prefix ───────────────────────────────────────────────────────
Write-Host "-- Validating SDN prefix: '$SdnPrefix'"
if ([string]::IsNullOrWhiteSpace($SdnPrefix)) {
    Write-Host "ERROR: SdnPrefix is empty" -ForegroundColor Red; exit 1
}
if ($SdnPrefix.Length -gt 8) {
    Write-Host "ERROR: SdnPrefix '$SdnPrefix' exceeds 8 characters" -ForegroundColor Red; exit 1
}
if ($SdnPrefix -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$' -or $SdnPrefix -match '--') {
    Write-Host "ERROR: SdnPrefix contains invalid characters or consecutive hyphens" -ForegroundColor Red; exit 1
}
Write-Host "  Prefix OK: '$SdnPrefix'"

# ── Validate intent pattern ───────────────────────────────────────────────────
Write-Host "-- Validating intent pattern: $SdnIntentPattern"
if ($SdnIntentPattern -notin 1, 2, 3) {
    Write-Host "ERROR: SdnIntentPattern must be 1, 2, or 3" -ForegroundColor Red; exit 1
}
Write-Host "  Intent pattern OK: $SdnIntentPattern"

# ── DNS validation (static) ───────────────────────────────────────────────────
$ncRecordName = "$SdnPrefix-NC"
if ($SdnDnsMode -eq 'static') {
    Write-Host "-- Validating static DNS record: $ncRecordName"
    if (-not $SdnNcReservedIp) {
        Write-Host "ERROR: SdnNcReservedIp is required for static DNS mode" -ForegroundColor Red; exit 1
    }
    try {
        $resolved   = Resolve-DnsName $ncRecordName -ErrorAction Stop
        $resolvedIp = ($resolved | Where-Object QueryType -eq 'A' | Select-Object -First 1).IPAddress
        if ($resolvedIp -ne $SdnNcReservedIp) {
            Write-Host "  WARN: '$ncRecordName' resolves to '$resolvedIp', expected '$SdnNcReservedIp'" -ForegroundColor Yellow
        } else {
            Write-Host "  DNS record OK: '$ncRecordName' -> '$resolvedIp'"
        }
    } catch {
        Write-Host "ERROR: DNS record '$ncRecordName' not found. Create A record -> '$SdnNcReservedIp' before proceeding." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  Dynamic DNS — no pre-created record required"
}

# ── Enable SDN ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "-- Enabling SDN on node '$TargetNode'..."
Write-Host "   This may take up to 20 minutes. Do not interrupt."
Write-Host ""

$credParam = @{}
if ($Credential) { $credParam['Credential'] = $Credential }

$featureParams = @{
    Name      = 'NC'
    SDNPrefix = $SdnPrefix
}
if ($AcknowledgeMaintenanceWindow) { $featureParams['AcknowledgeMaintenanceWindow'] = $true }
if ($AcknowledgeDNSRecordCreation) { $featureParams['AcknowledgeDNSRecordCreation'] = $true }

$result = Invoke-Command -ComputerName $TargetNode @credParam -ScriptBlock {
    param($FP)
    try {
        $outcome = Add-EceFeature @FP
        return [PSCustomObject]@{ Success = $true; Outcome = $outcome }
    } catch {
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
} -ArgumentList $featureParams

# ── Results ───────────────────────────────────────────────────────────────────
Write-Host ""
if ($result.Success) {
    Write-Host "-- Validating Network Controller cluster group..."
    $ncGroup = Invoke-Command -ComputerName $TargetNode @credParam -ScriptBlock {
        Get-ClusterGroup | Where-Object { $_.Name -match 'Network Controller' }
    }

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host " SDN Deployment Complete"                                          -ForegroundColor Green
    if ($ncGroup) {
        Write-Host "  NC Cluster Group : $($ncGroup.Name)"                         -ForegroundColor Green
        Write-Host "  State            : $($ncGroup.State)"                        -ForegroundColor Green
    }
    Write-Host "  NC REST URL      : https://$ncRecordName.<yourdomain>/"          -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green

    if ($ncGroup -and $ncGroup.State -ne 'Online') {
        Write-Host "WARNING: NC group state is '$($ncGroup.State)' — expected Online" -ForegroundColor Yellow
    }
} else {
    Write-Host "ERROR: Add-EceFeature failed: $($result.Error)" -ForegroundColor Red
    exit 1
}
