<#
.SYNOPSIS
    Installs Windows Admin Center on the WAC VM.

.DESCRIPTION
    This script:
    1. Downloads the latest Windows Admin Center MSI from Microsoft
    2. Installs WAC with default settings (port 443, self-signed cert)
    3. Configures Windows Firewall to allow HTTPS traffic
    4. Verifies the installation

.PARAMETER WACPort
    Port for Windows Admin Center (default: 443)

.PARAMETER InstallPath
    Installation directory (default: C:\Program Files\Windows Admin Center)

.EXAMPLE
    .\Install-WindowsAdminCenter.ps1
    
.EXAMPLE
    .\Install-WindowsAdminCenter.ps1 -WACPort 6516
#>

[CmdletBinding()]
param(
    [int]$WACPort = 443,
    [string]$InstallPath = "C:\Program Files\Windows Admin Center"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Windows Admin Center Installation ===" -ForegroundColor Cyan
Write-Host "Port: $WACPort" -ForegroundColor Gray
Write-Host "Install Path: $InstallPath" -ForegroundColor Gray
Write-Host ""

# Create temp directory for download
$tempDir = "$env:TEMP\WACInstall"
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

# Download latest Windows Admin Center
Write-Host "[1/5] Downloading latest Windows Admin Center..." -ForegroundColor Yellow
$downloadUrl = "https://aka.ms/WACDownload"
$installerPath = "$tempDir\WindowsAdminCenter.msi"

try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
    Write-Host "✓ Downloaded Windows Admin Center installer" -ForegroundColor Green
    Write-Host "  Installer: $installerPath" -ForegroundColor Gray
} catch {
    Write-Error "Failed to download Windows Admin Center: $_"
    exit 1
}

# Install Windows Admin Center
Write-Host "[2/5] Installing Windows Admin Center..." -ForegroundColor Yellow
$msiArgs = @(
    "/i"
    "`"$installerPath`""
    "/qn"
    "/norestart"
    "SME_PORT=$WACPort"
    "SSL_CERTIFICATE_OPTION=generate"
)

Write-Host "  Running installer (this may take 5-10 minutes)..." -ForegroundColor Gray
$process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru

if ($process.ExitCode -eq 0) {
    Write-Host "✓ Windows Admin Center installed successfully" -ForegroundColor Green
} else {
    Write-Error "Installation failed with exit code: $($process.ExitCode)"
    exit 1
}

# Configure Windows Firewall
Write-Host "[3/5] Configuring Windows Firewall..." -ForegroundColor Yellow
$firewallRuleName = "Windows Admin Center - HTTPS"

$existingRule = Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue
if ($existingRule) {
    Write-Host "  Firewall rule already exists" -ForegroundColor Gray
} else {
    New-NetFirewallRule -DisplayName $firewallRuleName `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $WACPort `
        -Action Allow `
        -Profile Domain,Private | Out-Null
    Write-Host "✓ Firewall rule created for port $WACPort" -ForegroundColor Green
}

# Wait for service to start
Write-Host "[4/5] Waiting for Windows Admin Center service to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

$service = Get-Service -Name ServerManagementGateway -ErrorAction SilentlyContinue
if ($service -and $service.Status -eq 'Running') {
    Write-Host "✓ Windows Admin Center service is running" -ForegroundColor Green
} else {
    Write-Warning "Windows Admin Center service is not running yet. It may take a few minutes to start."
}

# Verify installation
Write-Host "[5/5] Verifying installation..." -ForegroundColor Yellow
$wacExe = "$InstallPath\sme.exe"
if (Test-Path $wacExe) {
    $version = (Get-Item $wacExe).VersionInfo.ProductVersion
    Write-Host "✓ Windows Admin Center installed: v$version" -ForegroundColor Green
} else {
    Write-Warning "Could not verify installation path: $wacExe"
}

# Cleanup temp files
Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Windows Admin Center Installation Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Access URL: https://$(hostname):$WACPort" -ForegroundColor Cyan
Write-Host "  (Use https://10.1.0.25:$WACPort from other VMs)" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Access WAC via Azure Bastion or VPN" -ForegroundColor Gray
Write-Host "2. Add managed servers to WAC" -ForegroundColor Gray
Write-Host "3. Configure gateway settings as needed" -ForegroundColor Gray
Write-Host ""
Write-Host "Note: First access may take a few minutes while WAC completes initialization" -ForegroundColor Yellow
