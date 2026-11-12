<#
.SYNOPSIS
    Complete Windows Admin Center deployment and configuration script.

.DESCRIPTION
    Orchestrates the complete WAC setup including:
    - Installation
    - Kerberos delegation configuration
    - Entra ID authentication setup
    - Required extensions installation

.PARAMETER TenantId
    Azure AD tenant ID

.PARAMETER SubscriptionId
    Azure subscription ID

.PARAMETER WACUrl
    URL for WAC access (e.g., https://wac.local)

.PARAMETER CertificatePath
    Path to certificate for token signing

.PARAMETER SkipExtensions
    Skip extension installation

.EXAMPLE
    .\Deploy-WindowsAdminCenter.ps1 -TenantId "12345678-1234-1234-1234-123456789012" -WACUrl "https://wac.local"

.NOTES
    Run this script on the WAC server with admin privileges
    Requires internet access and Azure AD admin rights
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$WACUrl,

    [string]$CertificatePath,

    [switch]$SkipExtensions
)

$ErrorActionPreference = "Stop"

Write-Host "=== Complete Windows Admin Center Deployment ===" -ForegroundColor Cyan
Write-Host "Tenant ID: $TenantId" -ForegroundColor Gray
Write-Host "WAC URL: $WACUrl" -ForegroundColor Gray
Write-Host "Skip Extensions: $SkipExtensions" -ForegroundColor Gray
Write-Host ""

# ============================================
# PHASE 1: Join Domain
# ============================================

Write-Host "[1/6] Joining domain..." -ForegroundColor Yellow

# Check if already domain-joined
$computerSystem = Get-WmiObject -Class Win32_ComputerSystem
if ($computerSystem.PartOfDomain) {
    Write-Host "✓ Already domain-joined: $($computerSystem.Domain)" -ForegroundColor Green
} else {
    try {
        # Domain credentials should be provided via parameters or retrieved from Key Vault
        Write-Host "[ERROR] Domain join requires credentials to be provided via parameters" -ForegroundColor Red
        Write-Host "Please use -DomainCredential parameter or retrieve from Key Vault" -ForegroundColor Yellow
        throw "Domain credentials not provided. Use -DomainCredential parameter."
        
        # Example for future implementation:
        # $domainName = Get-ConfigValue -Config $config -Path 'active_directory.domain_fqdn'
        # $credential = Get-DomainCredentialFromKeyVault
        
        Add-Computer -DomainName $domainName -Credential $credential -Restart:$false -Force
        
        Write-Host "✓ Domain join successful - RESTART REQUIRED" -ForegroundColor Green
        Write-Host "⚠ Please restart the server and run this script again" -ForegroundColor Yellow
        exit 0
    }
    catch {
        Write-Error "Domain join failed: $_"
        exit 1
    }
}

# ============================================
# PHASE 2: Install Windows Admin Center
# ============================================

Write-Host ""
Write-Host "[2/6] Installing Windows Admin Center..." -ForegroundColor Yellow

try {
    $installScript = Join-Path $PSScriptRoot "Install-WindowsAdminCenter.ps1"
    if (Test-Path $installScript) {
        & $installScript
        Write-Host "✓ WAC installation completed" -ForegroundColor Green
    } else {
        throw "Installation script not found: $installScript"
    }
}
catch {
    Write-Error "WAC installation failed: $_"
    exit 1
}

# ============================================
# PHASE 3: Configure Kerberos Delegation
# ============================================

Write-Host ""
Write-Host "[3/6] Configuring Kerberos delegation..." -ForegroundColor Yellow

try {
    $kerberosScript = Join-Path $PSScriptRoot "Configure-WACKerberosDelegation.ps1"
    if (Test-Path $kerberosScript) {
        & $kerberosScript -WACUrl $WACUrl
        Write-Host "✓ Kerberos delegation configured" -ForegroundColor Green
    } else {
        throw "Kerberos script not found: $kerberosScript"
    }
}
catch {
    Write-Error "Kerberos configuration failed: $_"
    exit 1
}

# ============================================
# PHASE 4: Configure Entra ID Authentication
# ============================================

Write-Host ""
Write-Host "[4/6] Configuring Entra ID authentication..." -ForegroundColor Yellow

try {
    $entraScript = Join-Path $PSScriptRoot "Configure-WACEntraID.ps1"
    if (Test-Path $entraScript) {
        $params = @{
            TenantId = $TenantId
            SubscriptionId = $SubscriptionId
            WACUrl = $WACUrl
        }
        if ($CertificatePath) {
            $params.CertificatePath = $CertificatePath
        }

        & $entraScript @params
        Write-Host "✓ Entra ID authentication configured" -ForegroundColor Green
    } else {
        throw "Entra ID script not found: $entraScript"
    }
}
catch {
    Write-Error "Entra ID configuration failed: $_"
    exit 1
}

# ============================================
# PHASE 5: Install Extensions
# ============================================

Write-Host ""
if (-not $SkipExtensions) {
    Write-Host "[5/6] Installing required extensions..." -ForegroundColor Yellow

    try {
        $extensionsScript = Join-Path $PSScriptRoot "Install-WACExtensions.ps1"
        if (Test-Path $extensionsScript) {
            & $extensionsScript
            Write-Host "✓ Extensions installed" -ForegroundColor Green
        } else {
            throw "Extensions script not found: $extensionsScript"
        }
    }
    catch {
        Write-Error "Extensions installation failed: $_"
        exit 1
    }
} else {
    Write-Host "[5/6] Skipping extensions installation..." -ForegroundColor Yellow
}

# ============================================
# PHASE 6: Validation and Summary
# ============================================

Write-Host ""
Write-Host "[6/6] Validating deployment..." -ForegroundColor Yellow

# Check WAC service
$wacService = Get-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue
if ($wacService -and $wacService.Status -eq "Running") {
    Write-Host "✓ WAC service is running" -ForegroundColor Green
} else {
    Write-Warning "WAC service is not running"
}

# Check extensions
$wacPath = "C:\Program Files\Windows Admin Center"
$extensionsPath = Join-Path $wacPath "extensions"
$requiredExtensions = @("dell-openmanage-integration", "msft.hyperv", "msft.activedirectory")

$installedExtensions = @()
if (Test-Path $extensionsPath) {
    $installedExtensions = Get-ChildItem $extensionsPath | Select-Object -ExpandProperty Name
}

$missingExtensions = $requiredExtensions | Where-Object { $_ -notin $installedExtensions }
if ($missingExtensions.Count -eq 0) {
    Write-Host "✓ All required extensions are installed" -ForegroundColor Green
} else {
    Write-Warning "Missing extensions: $($missingExtensions -join ', ')"
}

Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Windows Admin Center is now configured for:" -ForegroundColor Cyan
Write-Host "  • Entra ID authentication" -ForegroundColor Gray
Write-Host "  • Kerberos delegation for 2-hop connections" -ForegroundColor Gray
Write-Host "  • Azure Local management extensions" -ForegroundColor Gray
Write-Host ""
Write-Host "Access WAC at: https://localhost" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Complete manual AD delegation setup (see Kerberos script output)" -ForegroundColor Gray
Write-Host "2. Grant admin consent for Azure AD app permissions" -ForegroundColor Gray
Write-Host "3. Test connections to Azure Local nodes and domain servers" -ForegroundColor Gray
Write-Host "4. Configure additional WAC settings as needed" -ForegroundColor Gray