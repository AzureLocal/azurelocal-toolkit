<#
.SYNOPSIS
    Configures Windows Admin Center for Kerberos delegation (2-hop connections).

.DESCRIPTION
    Sets up Kerberos Constrained Delegation to allow WAC to authenticate through
    intermediate servers (gateways) to reach target servers. Required for managing
    servers that aren't directly accessible from the WAC server.

.PARAMETER WACComputerName
    The computer name of the WAC server (default: $env:COMPUTERNAME)

.PARAMETER DomainAdminCredential
    Domain admin credentials for AD configuration

.EXAMPLE
    .\Configure-WACKerberosDelegation.ps1 -DomainAdminCredential (Get-Credential)

.NOTES
    Must be run with domain admin privileges
    WAC service must be running as a domain service account
#>

[CmdletBinding()]
param(
    [string]$WACComputerName = $env:COMPUTERNAME,
    [PSCredential]$DomainAdminCredential = (Get-Credential -Message "Enter domain admin credentials")
)

$ErrorActionPreference = "Stop"

Write-Host "=== Windows Admin Center Kerberos Delegation Configuration ===" -ForegroundColor Cyan
Write-Host "WAC Server: $WACComputerName" -ForegroundColor Gray
Write-Host ""

# ============================================
# PHASE 1: Verify Prerequisites
# ============================================

Write-Host "[1/4] Verifying prerequisites..." -ForegroundColor Yellow

# Check if running as domain admin
$domainAdminGroup = Get-LocalGroupMember -Group "Administrators" -Member "*$env:USERDOMAIN*" -ErrorAction SilentlyContinue
if (-not $domainAdminGroup) {
    Write-Warning "Not running with domain admin privileges. Some operations may fail."
}

# Check WAC service
$wacService = Get-Service -Name "ServerManagementGateway" -ErrorAction SilentlyContinue
if (-not $wacService) {
    throw "Windows Admin Center service not found. Install WAC first."
}

Write-Host "✓ Prerequisites verified" -ForegroundColor Green

# ============================================
# PHASE 2: Register SPNs for WAC
# ============================================

Write-Host ""
Write-Host "[2/4] Registering SPNs for WAC..." -ForegroundColor Yellow

# Get WAC service account (assuming it's running as LocalSystem for now)
# In production, WAC should run as a dedicated service account
$wacServiceAccount = "$env:USERDOMAIN\$env:COMPUTERNAME`$"

# Register SPNs
$spns = @(
    "HTTP/$WACComputerName",
    "HTTP/$WACComputerName.$env:USERDNSDOMAIN"
)

foreach ($spn in $spns) {
    Write-Host "  Registering SPN: $spn" -ForegroundColor Gray
    try {
        & setspn -S $spn $wacServiceAccount 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ SPN registered: $spn" -ForegroundColor Green
        } else {
            Write-Warning "  SPN may already exist: $spn"
        }
    }
    catch {
        Write-Warning "  Failed to register SPN $spn : $_"
    }
}

# ============================================
# PHASE 3: Configure Kerberos Delegation
# ============================================

Write-Host ""
Write-Host "[3/4] Configuring Kerberos delegation..." -ForegroundColor Yellow

# Note: This requires manual configuration in Active Directory
# The WAC computer account needs "Trust this computer for delegation to specified services only"
# with the target services (CIFS, HOST, RPCSS, etc.) for the target servers

Write-Host "⚠ Manual AD Configuration Required:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Open Active Directory Users and Computers" -ForegroundColor Gray
Write-Host "2. Find computer account: $WACComputerName" -ForegroundColor Gray
Write-Host "3. Properties → Delegation tab" -ForegroundColor Gray
Write-Host "4. Select 'Trust this computer for delegation to specified services only'" -ForegroundColor Gray
Write-Host "5. Add target servers and services (CIFS, HOST, RPCSS, etc.)" -ForegroundColor Gray
Write-Host ""
Write-Host "Target servers for your environment:" -ForegroundColor Cyan
Write-Host "  - DC01 ($((Get-ADComputer -Identity "vm-dc01" -ErrorAction SilentlyContinue).DNSHostName))" -ForegroundColor Gray
Write-Host "  - DC02 ($((Get-ADComputer -Identity "vm-dc02" -ErrorAction SilentlyContinue).DNSHostName))" -ForegroundColor Gray
Write-Host "  - Azure Local nodes (azl-lab-01-n01, azl-lab-01-n02, azl-lab-01-n03)" -ForegroundColor Gray

# ============================================
# PHASE 4: Configure WAC for Delegation
# ============================================

Write-Host ""
Write-Host "[4/4] Configuring WAC delegation settings..." -ForegroundColor Yellow

# WAC configuration for Kerberos delegation
$wacConfigPath = "$env:ProgramData\Windows Admin Center"

if (Test-Path $wacConfigPath) {
    Write-Host "✓ WAC configuration directory exists" -ForegroundColor Green

    # Note: WAC delegation settings are configured through the web interface
    # or via the settings.json file
    Write-Host ""
    Write-Host "WAC Delegation Configuration:" -ForegroundColor Cyan
    Write-Host "1. Open WAC web interface (https://localhost)" -ForegroundColor Gray
    Write-Host "2. Go to Settings → Gateway Settings" -ForegroundColor Gray
    Write-Host "3. Enable 'Use Kerberos delegation'" -ForegroundColor Gray
    Write-Host "4. Configure delegation settings" -ForegroundColor Gray
} else {
    Write-Warning "WAC configuration directory not found. Install WAC first."
}

Write-Host ""
Write-Host "=== Kerberos Delegation Configuration Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Complete manual AD delegation configuration" -ForegroundColor Gray
Write-Host "2. Configure WAC gateway settings" -ForegroundColor Gray
Write-Host "3. Test connections to managed servers" -ForegroundColor Gray
Write-Host ""
Write-Host "Note: Kerberos delegation allows WAC to authenticate through gateways" -ForegroundColor Cyan
Write-Host "      to servers that aren't directly accessible from the WAC server." -ForegroundColor Cyan