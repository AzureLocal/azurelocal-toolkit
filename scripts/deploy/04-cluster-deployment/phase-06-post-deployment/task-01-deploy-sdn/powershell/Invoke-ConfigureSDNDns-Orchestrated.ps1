# ==============================================================================
# Script : Invoke-ConfigureSDNDns-Orchestrated.ps1
# Purpose: Configure DNS for SDN deployment — validates dynamic DNS zone update
#          settings or creates/validates a static A record for the Network
#          Controller REST endpoint.
#          Executes on the domain controller VM via Invoke-AzVMRunCommand
#          (no PSRemoting, no domain credentials required).
# Run    : From the repo root before running Invoke-DeploySDN-Orchestrated.ps1
# ==============================================================================

[CmdletBinding()]
param(
    [string]$ConfigPath  = "",    # Path to infrastructure.yml; CWD-relative default
    [string]$ResourceGroupName = "",  # Override DC VM resource group (default: from config)
    [string]$VMName      = "",    # Override DC VM name (default: from config)
    [switch]$WhatIf               # Validate and report — do not create DNS records
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging ───────────────────────────────────────────────────────────────────
$taskFolderName = "task-01-deploy-sdn"
$logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
$logFile = Join-Path $logDir ("{0}_{1}_PrepareSDNDns.log" -f (Get-Date -Format 'yyyy-MM-dd'), (Get-Date -Format 'HHmmss'))
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } })
    Add-Content -Path $logFile -Value $line
}

Write-Log "Prepare-SDNDns started"
Write-Log "Log: $logFile"

# ── Config loading ────────────────────────────────────────────────────────────
if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Get-Location).Path "configs\infrastructure.yml"
}
if (-not (Test-Path $ConfigPath)) {
    Write-Log "Config file not found: $ConfigPath" 'ERROR'
    throw "Config file not found: $ConfigPath"
}

Write-Log "Loading config: $ConfigPath"
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

# ── Read SDN config ───────────────────────────────────────────────────────────
$sdnEnabled     = $cfg.networking.azure.sdn.sdn_enabled        # networking.azure.sdn.sdn_enabled
$sdnPrefix      = $cfg.networking.azure.sdn.sdn_prefix         # networking.azure.sdn.sdn_prefix
$sdnDnsMode     = $cfg.networking.azure.sdn.sdn_dns_mode       # networking.azure.sdn.sdn_dns_mode
$sdnNcReservedIp = $cfg.networking.azure.sdn.sdn_nc_reserved_ip # networking.azure.sdn.sdn_nc_reserved_ip
$domainFqdn     = $cfg.identity.active_directory.ad_domain_fqdn # identity.active_directory.ad_domain_fqdn

if (-not $sdnEnabled) {
    Write-Log "sdn_enabled is false — SDN is not configured for this cluster. Nothing to do." 'WARN'
    return
}
if (-not $sdnPrefix) {
    Write-Log "sdn_prefix is empty — set networking.azure.sdn.sdn_prefix before proceeding." 'ERROR'
    throw "sdn_prefix is required"
}
if (-not $sdnDnsMode) {
    Write-Log "sdn_dns_mode is empty — set networking.azure.sdn.sdn_dns_mode to 'dynamic' or 'static'." 'ERROR'
    throw "sdn_dns_mode is required"
}

$ncRecordName = "$sdnPrefix-NC"
Write-Log "SDN prefix    : $sdnPrefix"
Write-Log "DNS mode      : $sdnDnsMode"
Write-Log "NC record     : $ncRecordName"
Write-Log "Domain FQDN   : $domainFqdn"
if ($sdnDnsMode -eq 'static') {
    Write-Log "NC reserved IP: $sdnNcReservedIp"
}

# ── Resolve DC VM target ──────────────────────────────────────────────────────
if (-not $ResourceGroupName) {
    $ResourceGroupName = $cfg.compute.azure_vms.dc01.resource_group  # compute.azure_vms.dc01.resource_group
}
if (-not $VMName) {
    $VMName = $cfg.compute.azure_vms.dc01.name                        # compute.azure_vms.dc01.name
}

if (-not $ResourceGroupName -or -not $VMName) {
    Write-Log "DC VM not found in config — set compute.azure_vms.dc01.resource_group and compute.azure_vms.dc01.name" 'ERROR'
    throw "DC VM resource group and name are required"
}

Write-Log "Target DC VM  : $VMName (RG: $ResourceGroupName)"

# ── Verify Az.Compute is available ───────────────────────────────────────────
if (-not (Get-Module -Name Az.Compute -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Log "Az.Compute module not found — run: Install-Module Az.Compute" 'ERROR'
    throw "Az.Compute module is required"
}

# ── Build remote script ───────────────────────────────────────────────────────
if ($sdnDnsMode -eq 'dynamic') {
    $remoteScript = @"
`$ErrorActionPreference = 'Continue'
Import-Module DnsServer -ErrorAction Stop

`$zoneName   = '$domainFqdn'
`$recordName = '$ncRecordName'

Write-Output "=== SDN DNS Preparation - Dynamic Mode ==="
Write-Output "Zone    : `$zoneName"
Write-Output "Record  : `$recordName"
Write-Output ""

# Check zone exists
`$zone = Get-DnsServerZone -Name `$zoneName -ErrorAction SilentlyContinue
if (-not `$zone) {
    Write-Output "ERROR: DNS zone '`$zoneName' not found on this server"
    exit 1
}
Write-Output "Zone found: `$zoneName"

# Check dynamic update setting
`$dynUpdate = `$zone.DynamicUpdate
Write-Output "DynamicUpdate : `$dynUpdate"
if (`$dynUpdate -eq 'None') {
    Write-Output "ERROR: Zone '`$zoneName' has DynamicUpdate = None - SDN will not be able to register the NC record automatically"
    Write-Output "Fix: Set-DnsServerPrimaryZone -Name '`$zoneName' -DynamicUpdate Secure"
    exit 1
}
if (`$dynUpdate -eq 'Secure') {
    Write-Output "PASS: DynamicUpdate = Secure (recommended)"
} else {
    Write-Output "WARN: DynamicUpdate = `$dynUpdate - Secure is recommended"
}

# Check if record already exists (pre-existing record would conflict)
`$existing = Get-DnsServerResourceRecord -ZoneName `$zoneName -Name `$recordName -RRType A -ErrorAction SilentlyContinue
if (`$existing) {
    Write-Output "WARN: DNS record '`$recordName' already exists - IP: `$(`$existing.RecordData.IPv4Address)"
    Write-Output "      Review this record - if it is stale from a previous deployment, remove it before proceeding"
} else {
    Write-Output "PASS: No pre-existing record for '`$recordName' - dynamic DNS will create it automatically"
}

Write-Output ""
Write-Output "=== Dynamic DNS check complete ==="
"@
} else {
    # static mode
    if (-not $sdnNcReservedIp) {
        Write-Log "sdn_nc_reserved_ip is required for static DNS mode" 'ERROR'
        throw "sdn_nc_reserved_ip is required when sdn_dns_mode = 'static'"
    }
    if ($WhatIf) {
        $createRecord = '$false'
    } else {
        $createRecord = '$true'
    }
    $remoteScript = @"
`$ErrorActionPreference = 'Continue'
Import-Module DnsServer -ErrorAction Stop

`$zoneName    = '$domainFqdn'
`$recordName  = '$ncRecordName'
`$reservedIp  = '$sdnNcReservedIp'
`$createRecord = $createRecord

Write-Output "=== SDN DNS Preparation - Static Mode ==="
Write-Output "Zone       : `$zoneName"
Write-Output "Record     : `$recordName"
Write-Output "Reserved IP: `$reservedIp"
Write-Output "WhatIf     : `$(-not `$createRecord)"
Write-Output ""

# Check zone exists
`$zone = Get-DnsServerZone -Name `$zoneName -ErrorAction SilentlyContinue
if (-not `$zone) {
    Write-Output "ERROR: DNS zone '`$zoneName' not found on this server"
    exit 1
}
Write-Output "Zone found: `$zoneName"

# Check if record already exists
`$existing = Get-DnsServerResourceRecord -ZoneName `$zoneName -Name `$recordName -RRType A -ErrorAction SilentlyContinue
if (`$existing) {
    `$existingIp = `$existing.RecordData.IPv4Address.ToString()
    if (`$existingIp -eq `$reservedIp) {
        Write-Output "PASS: DNS record '`$recordName' already exists with correct IP `$reservedIp — nothing to do"
    } else {
        Write-Output "WARN: DNS record '`$recordName' exists but points to `$existingIp — expected `$reservedIp"
        Write-Output "      Remove the stale record and re-run, or update it manually"
    }
} else {
    if (`$createRecord) {
        try {
            Add-DnsServerResourceRecordA -ZoneName `$zoneName -Name `$recordName -IPv4Address `$reservedIp -ErrorAction Stop
            Write-Output "PASS: Created DNS A record '`$recordName' -> `$reservedIp"
        } catch {
            Write-Output "ERROR: Failed to create DNS record: `$_"
            exit 1
        }
    } else {
        Write-Output "[WhatIf] Would create DNS A record '`$recordName' -> `$reservedIp"
    }
}

# Verify resolution
Write-Output ""
Write-Output "Verifying DNS resolution for '`$recordName.`$zoneName'..."
try {
    `$resolved = Resolve-DnsName "`$recordName.`$zoneName" -ErrorAction Stop
    `$resolvedIp = (`$resolved | Where-Object QueryType -eq 'A' | Select-Object -First 1).IPAddress
    if (`$resolvedIp -eq `$reservedIp) {
        Write-Output "PASS: '`$recordName.`$zoneName' resolves to `$resolvedIp"
    } else {
        Write-Output "WARN: '`$recordName.`$zoneName' resolves to `$resolvedIp — expected `$reservedIp"
    }
} catch {
    if (`$createRecord) {
        Write-Output "WARN: DNS record created but resolution check failed (replication lag?) — retry in a few seconds"
    } else {
        Write-Output "[WhatIf] Record does not yet exist — resolution check skipped"
    }
}

Write-Output ""
Write-Output "=== Static DNS check complete ==="
"@
}

# ── Execute via Invoke-AzVMRunCommand ─────────────────────────────────────────
if ($WhatIf -and $sdnDnsMode -eq 'dynamic') {
    Write-Log "[WhatIf] Would run DNS zone check on VM '$VMName' via Invoke-AzVMRunCommand"
    Write-Host "[WhatIf] No changes made — remove -WhatIf to run the check." -ForegroundColor Yellow
    return
}

Write-Log "Running DNS check on '$VMName' via Invoke-AzVMRunCommand..."

try {
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName            $VMName `
        -CommandId         'RunPowerShellScript' `
        -ScriptString      $remoteScript `
        -ErrorAction       Stop

    $output = $result.Value | Where-Object { $_.Code -match 'StdOut' } | Select-Object -ExpandProperty Message
    $errOut  = $result.Value | Where-Object { $_.Code -match 'StdErr' } | Select-Object -ExpandProperty Message

    if ($output) {
        Write-Log "--- DC output ---"
        $output -split "`n" | ForEach-Object { Write-Log $_.Trim() }
    }
    if ($errOut -and $errOut.Trim()) {
        Write-Log "--- DC stderr ---"
        $errOut -split "`n" | ForEach-Object { Write-Log $_.Trim() 'WARN' }
    }

    if ($output -match '^ERROR:' -or ($errOut -and $errOut -match 'ParserError|FullyQualifiedErrorId|CategoryInfo')) {
        Write-Log "DNS preparation failed — review output above" 'ERROR'
        throw "DNS preparation reported errors"
    }

    Write-Log "DNS preparation complete"
    Write-Host "`nDNS is ready for SDN deployment. Proceed to Step 3." -ForegroundColor Green

} catch {
    Write-Log "Invoke-AzVMRunCommand failed: $_" 'ERROR'
    throw
}
