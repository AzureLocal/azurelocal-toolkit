#Requires -Version 7.0
<#
.SYNOPSIS
    Get-HardwareDiscovery-Standalone.ps1
    Standalone hardware discovery via Dell iDRAC Redfish API.

.DESCRIPTION
    Fully self-contained. No infrastructure.yml or helper dependencies.
    Update the #region CONFIGURATION block with iDRAC IPs and credentials
    before running. Collects hardware inventory, BIOS, and iDRAC attributes
    from each node and saves JSON files to the specified output path.

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Phase: 01-hardware-provisioning
    Task: task-02-hardware-discovery-via-dell-redfish-api
    Prerequisites: PowerShell 7+, iDRAC network access (port 443)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region CONFIGURATION
# ── Edit before running ─────────────────────────────────────────────────────
# iDRAC IPs — from infrastructure.yml: nodes.<name>.idrac_ip
$NodeInventory = @(
    @{ Name = "node01"; iDRACIP = "REPLACE_WITH_IDRAC_IP" }
    @{ Name = "node02"; iDRACIP = "REPLACE_WITH_IDRAC_IP" }
    @{ Name = "node03"; iDRACIP = "REPLACE_WITH_IDRAC_IP" }
    @{ Name = "node04"; iDRACIP = "REPLACE_WITH_IDRAC_IP" }
)
$iDRACUsername = "root"
$OutputPath    = ".\configs\network-devices\bmc"
#endregion CONFIGURATION

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "HEADER"  { "Cyan" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Invoke-RedfishGet {
    param([string]$Uri, [PSCredential]$Credential)
    return Invoke-RestMethod -Uri $Uri -Credential $Credential -SkipCertificateCheck `
        -ContentType "application/json" -ErrorAction Stop
}

# ============================================================================
# MAIN
# ============================================================================

try {
    Write-Log "=== Hardware Discovery (Standalone) ===" "HEADER"

    $iDRACPassword = Read-Host "Enter iDRAC password for user '$iDRACUsername'" -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential($iDRACUsername, $iDRACPassword)

    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Log "Output directory: $OutputPath"

    $results = @()
    foreach ($node in $NodeInventory) {
        Write-Log "=== Discovering: $($node.Name) ($($node.iDRACIP)) ===" "HEADER"
        $base = "https://$($node.iDRACIP)/redfish/v1"
        try {
            $system      = Invoke-RedfishGet "$base/Systems/System.Embedded.1" $cred
            $idracNics   = Invoke-RedfishGet "$base/Managers/iDRAC.Embedded.1/EthernetInterfaces" $cred
            $sysNics     = Invoke-RedfishGet "$base/Systems/System.Embedded.1/NetworkInterfaces" $cred
            $bios        = Invoke-RedfishGet "$base/Systems/System.Embedded.1/Bios" $cred
            $idracAttrib = Invoke-RedfishGet "$base/Managers/iDRAC.Embedded.1/Attributes" $cred
            $storage     = Invoke-RedfishGet "$base/Systems/System.Embedded.1/Storage" $cred

            $inventory = @{
                NodeName        = $node.Name
                iDRACIP         = $node.iDRACIP
                CollectedAt     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
                System          = $system
                iDRACInterfaces = $idracNics
                SystemNICs      = $sysNics
                BIOSAttributes  = $bios
                iDRACAttributes = $idracAttrib
                Storage         = $storage
            }

            $serviceTag = $system.SKU
            $outFile    = Join-Path $OutputPath "$serviceTag.json"
            $inventory | ConvertTo-Json -Depth 15 | Set-Content $outFile -Encoding UTF8
            Write-Log "  Service Tag: $serviceTag | Saved: $outFile" "SUCCESS"
            $results += [PSCustomObject]@{ Name = $node.Name; ServiceTag = $serviceTag; Success = $true }
        } catch {
            Write-Log "  Failed: $_" "ERROR"
            $results += [PSCustomObject]@{ Name = $node.Name; ServiceTag = $null; Success = $false }
        }
    }

    Write-Log "=== SUMMARY ===" "HEADER"
    foreach ($r in $results) {
        if ($r.Success) { Write-Log "  OK   $($r.Name) — $($r.ServiceTag)" "SUCCESS" }
        else            { Write-Log "  FAIL $($r.Name)" "ERROR" }
    }
    Write-Log "Discovery complete. Files in: $OutputPath"
    Write-Log "Run Update-InfrastructureYml-FromDiscovery.ps1 to write values into infrastructure.yml."

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}
