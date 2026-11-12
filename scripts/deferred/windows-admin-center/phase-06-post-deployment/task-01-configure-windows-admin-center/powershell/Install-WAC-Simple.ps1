# Simplified Windows Admin Center Installation Script
# This script can be executed remotely via Invoke-AzVMRunCommand

Write-Host "Installing Windows Admin Center..." -ForegroundColor Yellow

# Download and install WAC
$installerUrl = "https://aka.ms/WACDownload"
$installerPath = "$env:TEMP\WAC.msi"

try {
    Write-Host "Downloading WAC installer..."
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

    Write-Host "Installing WAC..."
    $installArgs = "/i `"$installerPath`" /quiet /norestart SME_PORT=443 SSL_CERTIFICATE_OPTION=generate"
    Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait

    Write-Host "✓ Windows Admin Center installed successfully" -ForegroundColor Green

    # Clean up
    Remove-Item $installerPath -Force

    # Start the service
    Start-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue

    Write-Host "✓ WAC service started" -ForegroundColor Green
    Write-Host "Access WAC at: https://localhost" -ForegroundColor Cyan

} catch {
    Write-Error "Installation failed: $_"
    exit 1
}