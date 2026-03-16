<#
.SYNOPSIS
    Validates Task 01 AD artifacts: OU creation, LCM user, and KDS Root Key.

.DESCRIPTION
    Validates only what Task 01 (OU Creation & Pre-Creation Artifacts) creates
    via New-HciAdObjectsPreCreation:
    - KDS Root Key exists
    - Cluster OU structure exists
    - LCM user account exists, is enabled, and is in the correct OU

    Does NOT check security groups, DNS records, computer accounts, or other
    artifacts — those belong to later tasks.

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration file.

.PARAMETER DomainController
    Target domain controller FQDN. If not specified, auto-detected from config
    (azure_vms.dc01.fqdn) or Active Directory.

.EXAMPLE
    .\Validate-ADConfiguration.ps1 -ConfigFile ".\infrastructure-azl-lab.yml"

.EXAMPLE
    .\Validate-ADConfiguration.ps1 -ConfigFile ".\infrastructure-azl-lab.yml" -DomainController "azrsdc-eus-01.azrl.mgmt"

.NOTES
    Requires: ActiveDirectory PowerShell module, powershell-yaml module
    Must be run from a domain-joined machine or with credentials that can query AD.
    Author: Azure Local Cloudnology Team
    Version: 1.1.0
    Created: 2026-02-27
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$DomainController
)

#Requires -Modules powershell-yaml

# ============================================================================
# INITIALIZATION
# ============================================================================
$ErrorActionPreference = "Stop"

# Counters
$script:totalChecks = 0
$script:passedChecks = 0
$script:failedChecks = 0
$script:warnChecks = 0

function Write-Check {
    param(
        [string]$Name,
        [ValidateSet("PASS", "FAIL", "WARN", "INFO")]
        [string]$Status,
        [string]$Detail = ""
    )

    $script:totalChecks++
    $icon = switch ($Status) {
        "PASS" { $script:passedChecks++; "✓" }
        "FAIL" { $script:failedChecks++; "✗" }
        "WARN" { $script:warnChecks++; "⚠" }
        "INFO" { "ℹ" }
    }
    $color = switch ($Status) {
        "PASS" { "Green" }
        "FAIL" { "Red" }
        "WARN" { "Yellow" }
        "INFO" { "Cyan" }
    }

    $msg = "  $icon $Name"
    if ($Detail) { $msg += " - $Detail" }
    Write-Host $msg -ForegroundColor $color
}

# ============================================================================
# LOAD CONFIGURATION
# ============================================================================
try {
    Write-Host "Loading configuration from: $ConfigFile" -ForegroundColor Cyan
    Import-Module powershell-yaml -ErrorAction Stop
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Yaml
    Write-Host "  Config loaded successfully" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to load config: $_" -ForegroundColor Red
    exit 1
}

# Extract values from config
$adDomainFqdn = $config.identity.active_directory.ad_domain_fqdn
if (-not $adDomainFqdn) { $adDomainFqdn = $config.identity.active_directory.fqdn }

$clusterOUPath = $config.identity.active_directory.ad_clusters_ou_path
if (-not $clusterOUPath) { $clusterOUPath = $config.identity.active_directory.ad_clusters_ou_path }

$lcmUsername = $config.identity.accounts.account_lcm_username
# Extract just the SAM account name (before @domain)
$lcmSamAccount = if ($lcmUsername -match '^([^@]+)@') { $Matches[1] } else { $lcmUsername }

# Determine domain controller
if (-not $DomainController) {
    # Try to get from config (azure_vms.dc01.fqdn)
    if ($config.compute.azure_vms.dc01.fqdn) {
        $DomainController = $config.compute.azure_vms.dc01.fqdn
    }
    else {
        # Auto-detect from domain
        try {
            $DomainController = (Get-ADDomainController -Discover -DomainName $adDomainFqdn).HostName[0]
        }
        catch {
            Write-Host "ERROR: Cannot determine domain controller. Use -DomainController parameter." -ForegroundColor Red
            exit 1
        }
    }
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Task 01: OU & Pre-Creation Validation" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Domain:            $adDomainFqdn" -ForegroundColor White
Write-Host "  Domain Controller: $DomainController" -ForegroundColor White
Write-Host "  Cluster OU:        $clusterOUPath" -ForegroundColor White
Write-Host "  LCM Account:       $lcmSamAccount" -ForegroundColor White
Write-Host ""

# ============================================================================
# CHECK 1: Domain Connectivity
# ============================================================================
Write-Host "Checking domain connectivity..." -ForegroundColor Cyan

try {
    $pingResult = Test-Connection -ComputerName $DomainController -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($pingResult) {
        Write-Check -Name "DC reachable (ICMP)" -Status "PASS" -Detail $DomainController
    }
    else {
        Write-Check -Name "DC reachable (ICMP)" -Status "WARN" -Detail "ICMP blocked (may still work via LDAP)"
    }
}
catch {
    Write-Check -Name "DC reachable (ICMP)" -Status "WARN" -Detail "Test failed: $_"
}

try {
    $ldapTest = Test-NetConnection -ComputerName $DomainController -Port 389 -WarningAction SilentlyContinue
    if ($ldapTest.TcpTestSucceeded) {
        Write-Check -Name "LDAP connectivity (port 389)" -Status "PASS"
    }
    else {
        Write-Check -Name "LDAP connectivity (port 389)" -Status "FAIL" -Detail "Cannot connect"
    }
}
catch {
    Write-Check -Name "LDAP connectivity (port 389)" -Status "FAIL" -Detail $_
}

try {
    $kerbTest = Test-NetConnection -ComputerName $DomainController -Port 88 -WarningAction SilentlyContinue
    if ($kerbTest.TcpTestSucceeded) {
        Write-Check -Name "Kerberos connectivity (port 88)" -Status "PASS"
    }
    else {
        Write-Check -Name "Kerberos connectivity (port 88)" -Status "WARN" -Detail "May affect authentication"
    }
}
catch {
    Write-Check -Name "Kerberos connectivity (port 88)" -Status "WARN" -Detail $_
}

# ============================================================================
# CHECK 2: ActiveDirectory Module
# ============================================================================
Write-Host ""
Write-Host "Checking prerequisites..." -ForegroundColor Cyan

$adModuleAvailable = $false
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $adModuleAvailable = $true
    Write-Check -Name "ActiveDirectory module" -Status "PASS" -Detail "Loaded"
}
catch {
    Write-Check -Name "ActiveDirectory module" -Status "FAIL" -Detail "Not available — install RSAT or run from DC"
    Write-Host "`n  ERROR: ActiveDirectory module required for remaining checks." -ForegroundColor Red
    Write-Host "  Install: Add-WindowsCapability -Name Rsat.ActiveDirectory.DS-LDS.Tools -Online" -ForegroundColor Yellow
    exit 1
}

# ============================================================================
# CHECK 3: KDS Root Key
# ============================================================================
Write-Host ""
Write-Host "Checking KDS Root Key..." -ForegroundColor Cyan

try {
    $kdsKey = Get-KdsRootKey -ErrorAction SilentlyContinue
    if ($kdsKey) {
        Write-Check -Name "KDS Root Key" -Status "PASS" -Detail "Key ID: $($kdsKey[0].KeyId.ToString().Substring(0,8))..."
    }
    else {
        Write-Check -Name "KDS Root Key" -Status "FAIL" -Detail "Not found — run: Add-KdsRootKey -EffectiveTime (Get-Date).AddHours(-10)"
    }
}
catch {
    Write-Check -Name "KDS Root Key" -Status "WARN" -Detail "Cannot check: $_"
}

# ============================================================================
# CHECK 4: OU Structure
# ============================================================================
Write-Host ""
Write-Host "Checking OU structure..." -ForegroundColor Cyan

# Check the cluster OU itself
try {
    $clusterOU = Get-ADOrganizationalUnit -Identity $clusterOUPath -Server $DomainController -ErrorAction Stop
    Write-Check -Name "Cluster OU" -Status "PASS" -Detail $clusterOUPath
}
catch {
    Write-Check -Name "Cluster OU" -Status "FAIL" -Detail "Not found: $clusterOUPath"
}

# Check parent OUs in the path exist
$ouParts = $clusterOUPath -split ","
$parentOUs = @()
for ($i = 1; $i -lt $ouParts.Count; $i++) {
    $parentPath = ($ouParts[$i..($ouParts.Count - 1)]) -join ","
    if ($parentPath -match "^OU=") {
        $parentOUs += $parentPath
    }
}

foreach ($parentOU in $parentOUs) {
    try {
        $null = Get-ADOrganizationalUnit -Identity $parentOU -Server $DomainController -ErrorAction Stop
        Write-Check -Name "Parent OU" -Status "PASS" -Detail $parentOU
    }
    catch {
        Write-Check -Name "Parent OU" -Status "FAIL" -Detail "Not found: $parentOU"
    }
}

# ============================================================================
# CHECK 5: LCM User Account
# ============================================================================
Write-Host ""
Write-Host "Checking LCM user account..." -ForegroundColor Cyan

try {
    $lcmUser = Get-ADUser -Filter "SamAccountName -eq '$lcmSamAccount'" -Server $DomainController -Properties Enabled, DistinguishedName, WhenCreated -ErrorAction Stop

    if ($lcmUser) {
        Write-Check -Name "LCM user exists" -Status "PASS" -Detail "$lcmSamAccount ($($lcmUser.DistinguishedName))"

        if ($lcmUser.Enabled) {
            Write-Check -Name "LCM user enabled" -Status "PASS"
        }
        else {
            Write-Check -Name "LCM user enabled" -Status "FAIL" -Detail "Account is disabled"
        }

        # Check if LCM user is in the cluster OU
        if ($lcmUser.DistinguishedName -like "*$clusterOUPath*") {
            Write-Check -Name "LCM user in cluster OU" -Status "PASS"
        }
        else {
            Write-Check -Name "LCM user in cluster OU" -Status "WARN" -Detail "User is in $($lcmUser.DistinguishedName)"
        }
    }
    else {
        Write-Check -Name "LCM user exists" -Status "FAIL" -Detail "Not found: $lcmSamAccount"
    }
}
catch {
    Write-Check -Name "LCM user exists" -Status "FAIL" -Detail "Query failed: $_"
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "VALIDATION SUMMARY" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Domain:            $adDomainFqdn" -ForegroundColor White
Write-Host "  Domain Controller: $DomainController" -ForegroundColor White
Write-Host "  Cluster OU:        $clusterOUPath" -ForegroundColor White
Write-Host "  LCM Account:       $lcmSamAccount" -ForegroundColor White
Write-Host ""
Write-Host "  Passed:  $script:passedChecks" -ForegroundColor Green
Write-Host "  Failed:  $script:failedChecks" -ForegroundColor $(if ($script:failedChecks -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings: $script:warnChecks" -ForegroundColor $(if ($script:warnChecks -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Total:   $script:totalChecks" -ForegroundColor White

if ($script:failedChecks -eq 0) {
    Write-Host ""
    Write-Host "✓ AD configuration validation passed!" -ForegroundColor Green
    exit 0
}
else {
    Write-Host ""
    Write-Host "✗ $($script:failedChecks) check(s) failed. Review above and remediate." -ForegroundColor Red
    exit 1
}
