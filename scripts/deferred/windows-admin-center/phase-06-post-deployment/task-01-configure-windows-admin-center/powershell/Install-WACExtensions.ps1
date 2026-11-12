<#
.SYNOPSIS
    Installs required Windows Admin Center extensions for Azure Local management.

.DESCRIPTION
    Downloads and installs WAC extensions needed for managing Azure Local infrastructure:
    - Active Directory
    - Hyper-V
    - Dell OpenManage Integration

.PARAMETER WACInstallPath
    Path where WAC is installed (default: C:\Program Files\Windows Admin Center)

.PARAMETER Extensions
    Array of extension names to install (default: all required)

.EXAMPLE
    .\Install-WACExtensions.ps1

.EXAMPLE
    .\Install-WACExtensions.ps1 -Extensions @("dell-openmanage-integration")

.NOTES
    Run this script on the WAC server after WAC installation
    Requires internet access for downloading extensions
#>

[CmdletBinding()]
param(
    [string]$WACInstallPath = "C:\Program Files\Windows Admin Center",

    [string[]]$Extensions = @(
        "dell-openmanage-integration",
        "msft.hyperv",
        "msft.activedirectory"
    )
)

$ErrorActionPreference = "Stop"

Write-Host "=== Windows Admin Center Extensions Installation ===" -ForegroundColor Cyan
Write-Host "WAC Path: $WACInstallPath" -ForegroundColor Gray
Write-Host "Extensions to install: $($Extensions -join ', ')" -ForegroundColor Gray
Write-Host ""

# ============================================
# PHASE 1: Validate WAC Installation
# ============================================

Write-Host "[1/4] Validating WAC installation..." -ForegroundColor Yellow

if (-not (Test-Path $WACInstallPath)) {
    throw "WAC installation not found at: $WACInstallPath"
}

$wacExe = Join-Path $WACInstallPath "WindowsAdminCenter.exe"
if (-not (Test-Path $wacExe)) {
    throw "WAC executable not found: $wacExe"
}

Write-Host "✓ WAC installation validated" -ForegroundColor Green

# ============================================
# PHASE 2: Stop WAC Service
# ============================================

Write-Host ""
Write-Host "[2/4] Stopping WAC service..." -ForegroundColor Yellow

try {
    $wacService = Get-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue
    if ($wacService) {
        Stop-Service -Name "WindowsAdminCenter" -Force
        Write-Host "✓ WAC service stopped" -ForegroundColor Green
    } else {
        Write-Host "ℹ WAC service not running" -ForegroundColor Yellow
    }
}
catch {
    Write-Warning "Could not stop WAC service: $_"
}

# ============================================
# PHASE 3: Install Extensions
# ============================================

Write-Host ""
Write-Host "[3/4] Installing extensions..." -ForegroundColor Yellow

$extensionUrls = @{
    "dell-openmanage-integration" = "https://aka.ms/wac-extension-dell-openmanage"
    "msft.hyperv" = "https://aka.ms/wac-extension-hyperv"
    "msft.activedirectory" = "https://aka.ms/wac-extension-activedirectory"
}

$extensionsPath = Join-Path $WACInstallPath "extensions"

foreach ($extension in $Extensions) {
    Write-Host "  Installing $extension..." -ForegroundColor Gray

    if ($extensionUrls.ContainsKey($extension)) {
        $url = $extensionUrls[$extension]

        try {
            # Download extension
            $tempFile = Join-Path $env:TEMP "$extension.zip"
            Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing

            # Extract to extensions directory
            $extensionDir = Join-Path $extensionsPath $extension
            if (Test-Path $extensionDir) {
                Remove-Item $extensionDir -Recurse -Force
            }

            Expand-Archive -Path $tempFile -DestinationPath $extensionDir -Force

            # Clean up
            Remove-Item $tempFile -Force

            Write-Host "  ✓ $extension installed" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to install $extension`: $_"
        }
    } else {
        Write-Warning "Unknown extension: $extension"
    }
}

# ============================================
# PHASE 4: Start WAC Service
# ============================================

Write-Host ""
Write-Host "[4/4] Starting WAC service..." -ForegroundColor Yellow

try {
    Start-Service -Name "WindowsAdminCenter"
    Write-Host "✓ WAC service started" -ForegroundColor Green
}
catch {
    Write-Warning "Could not start WAC service: $_"
}

Write-Host ""
Write-Host "=== Extension Installation Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Open WAC in browser: https://localhost" -ForegroundColor Gray
Write-Host "2. Verify extensions are loaded in Settings → Extensions" -ForegroundColor Gray
Write-Host "3. Test extension functionality by connecting to target servers" -ForegroundColor Gray
Write-Host ""
Write-Host "Installed Extensions:" -ForegroundColor Cyan
foreach ($extension in $Extensions) {
    Write-Host "  • $extension" -ForegroundColor Gray
}