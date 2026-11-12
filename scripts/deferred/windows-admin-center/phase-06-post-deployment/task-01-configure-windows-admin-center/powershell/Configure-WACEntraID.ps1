<#
.SYNOPSIS
    Configures Windows Admin Center for Entra ID (Azure AD) authentication.

.DESCRIPTION
    Sets up Azure AD integration for WAC authentication instead of local accounts.
    Creates Azure AD app registration and configures WAC to use it.

.PARAMETER TenantId
    Azure AD tenant ID

.PARAMETER SubscriptionId
    Azure subscription ID for app registration

.PARAMETER WACUrl
    The URL where WAC will be accessed (e.g., https://wac.corp.hybrid.mgmt)

.PARAMETER CertificatePath
    Path to certificate file for token signing (optional)

.EXAMPLE
    .\Configure-WACEntraID.ps1 -TenantId "12345678-1234-1234-1234-123456789012" -WACUrl "https://wac.local"

.NOTES
    Requires Azure AD admin privileges
    Certificate should be installed in LocalMachine\My store
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$WACUrl,

    [string]$CertificatePath
)

$ErrorActionPreference = "Stop"

Write-Host "=== Windows Admin Center Entra ID Configuration ===" -ForegroundColor Cyan
Write-Host "Tenant ID: $TenantId" -ForegroundColor Gray
Write-Host "WAC URL: $WACUrl" -ForegroundColor Gray
Write-Host ""

# ============================================
# PHASE 1: Connect to Azure
# ============================================

Write-Host "[1/6] Connecting to Azure..." -ForegroundColor Yellow

try {
    Connect-AzAccount -TenantId $TenantId -SubscriptionId $SubscriptionId | Out-Null
    Write-Host "✓ Connected to Azure" -ForegroundColor Green
}
catch {
    throw "Failed to connect to Azure: $_"
}

# ============================================
# PHASE 2: Create Azure AD App Registration
# ============================================

Write-Host ""
Write-Host "[2/6] Creating Azure AD app registration..." -ForegroundColor Yellow

$appName = "Windows Admin Center"
$appUri = $WACUrl.TrimEnd('/')

# Check if app already exists
$existingApp = Get-AzADApplication -DisplayName $appName -ErrorAction SilentlyContinue

if ($existingApp) {
    Write-Host "✓ App registration already exists: $($existingApp.AppId)" -ForegroundColor Green
    $appId = $existingApp.AppId
} else {
    # Create new app registration
    $app = New-AzADApplication -DisplayName $appName `
        -HomePage $appUri `
        -ReplyUrls @($appUri) `
        -IdentifierUris @($appUri)

    $appId = $app.AppId
    Write-Host "✓ Created app registration: $appId" -ForegroundColor Green
}

# ============================================
# PHASE 3: Create Service Principal
# ============================================

Write-Host ""
Write-Host "[3/6] Creating service principal..." -ForegroundColor Yellow

$sp = Get-AzADServicePrincipal -ApplicationId $appId -ErrorAction SilentlyContinue

if (-not $sp) {
    $sp = New-AzADServicePrincipal -ApplicationId $appId
    Write-Host "✓ Created service principal" -ForegroundColor Green

    # Wait for SP to propagate
    Start-Sleep -Seconds 30
} else {
    Write-Host "✓ Service principal already exists" -ForegroundColor Green
}

# ============================================
# PHASE 4: Configure Certificate (if provided)
# ============================================

Write-Host ""
Write-Host "[4/6] Configuring certificates..." -ForegroundColor Yellow

if ($CertificatePath) {
    if (Test-Path $CertificatePath) {
        # Import certificate to Azure AD app
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
        $keyCredential = New-Object Microsoft.Azure.PowerShell.Cmdlets.Resources.MSGraph.Models.ApiV10.MicrosoftGraphKeyCredential
        $keyCredential.KeyId = [guid]::NewGuid()
        $keyCredential.Type = "AsymmetricX509Cert"
        $keyCredential.Usage = "Verify"
        $keyCredential.Key = $cert.GetRawCertData()

        Update-AzADApplication -ApplicationId $appId -KeyCredentials @($keyCredential)
        Write-Host "✓ Certificate uploaded to Azure AD app" -ForegroundColor Green
    } else {
        Write-Warning "Certificate file not found: $CertificatePath"
    }
} else {
    Write-Host "ℹ No certificate provided - using client secret authentication" -ForegroundColor Yellow

    # Generate client secret
    $clientSecret = New-AzADAppCredential -ApplicationId $appId -EndDate (Get-Date).AddYears(2)
    Write-Host "✓ Client secret created (expires: $($clientSecret.EndDate))" -ForegroundColor Green
    Write-Host "  ⚠ Save this secret securely: $($clientSecret.SecretText)" -ForegroundColor Red
}

# ============================================
# PHASE 5: Configure API Permissions
# ============================================

Write-Host ""
Write-Host "[5/6] Configuring API permissions..." -ForegroundColor Yellow

# Add Microsoft Graph permissions
$graphPermissions = @(
    "User.Read",
    "Group.Read.All",
    "Directory.Read.All"
)

foreach ($permission in $graphPermissions) {
    Add-AzADAppPermission -ApplicationId $appId -ApiId "00000003-0000-0000-c000-000000000000" -PermissionId $permission
}

Write-Host "✓ API permissions configured" -ForegroundColor Green

# Grant admin consent
Write-Host "⚠ Admin consent required for API permissions" -ForegroundColor Yellow
Write-Host "  Go to: https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/CallAnAPI/appId/$appId" -ForegroundColor Gray
Write-Host "  Grant admin consent for the configured permissions" -ForegroundColor Gray

# ============================================
# PHASE 6: Generate WAC Configuration
# ============================================

Write-Host ""
Write-Host "[6/6] Generating WAC configuration..." -ForegroundColor Yellow

$wacConfig = @{
    azure = @{
        tenant = $TenantId
        clientId = $appId
        mode = "aad"
        authority = "https://login.microsoftonline.com/$TenantId"
        redirectUri = $appUri
    }
}

# Save configuration for reference
$configPath = "$PSScriptRoot\wac-entra-config.json"
$wacConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $configPath -Encoding UTF8

Write-Host "✓ Configuration saved to: $configPath" -ForegroundColor Green

Write-Host ""
Write-Host "=== Entra ID Configuration Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Grant admin consent for API permissions in Azure portal" -ForegroundColor Gray
Write-Host "2. Configure WAC settings through web interface:" -ForegroundColor Gray
Write-Host "   - Open WAC: https://localhost" -ForegroundColor Gray
Write-Host "   - Settings → Azure → Enable Azure AD authentication" -ForegroundColor Gray
Write-Host "   - Enter Tenant ID: $TenantId" -ForegroundColor Gray
Write-Host "   - Enter Client ID: $appId" -ForegroundColor Gray
Write-Host "3. Upload certificate to WAC if using certificate auth" -ForegroundColor Gray
Write-Host ""
Write-Host "Configuration Details:" -ForegroundColor Cyan
Write-Host "  Tenant ID: $TenantId" -ForegroundColor Gray
Write-Host "  Client ID: $appId" -ForegroundColor Gray
Write-Host "  WAC URL: $WACUrl" -ForegroundColor Gray
if ($clientSecret) {
    Write-Host "  Client Secret: $($clientSecret.SecretText)" -ForegroundColor Red
}