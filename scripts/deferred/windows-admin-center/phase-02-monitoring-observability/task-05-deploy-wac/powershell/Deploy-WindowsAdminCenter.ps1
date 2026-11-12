#Requires -Modules Az.KeyVault
<#
.SYNOPSIS
    Deploy Windows Admin Center (WAC) to the management server via PSRemoting.
.DESCRIPTION
    Retrieves domain credentials from Key Vault, connects to the WAC server
    via PowerShell remoting, downloads the WAC installer, runs a silent
    install with auto-generated SSL certificate, and verifies the service started.
.PARAMETER ConfigPath
    Path to the YAML variables file. Defaults to ./config/variables.yml.
.PARAMETER WhatIf
    Preview changes without making them.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "./config/variables.yml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Load config ───────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config     = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$wacServer  = $config.management.wac_server_fqdn
$wacPort    = $config.management.wac_port
$kvName     = $config.azure.key_vault.name

Write-Host "Deploying Windows Admin Center to: $wacServer" -ForegroundColor Cyan

# ── Retrieve credentials from Key Vault ───────────────────────────────────────
Write-Host "  Retrieving credentials from Key Vault: $kvName..."
$adminUser  = Get-AzKeyVaultSecret -VaultName $kvName -Name "domain-admin-username" -AsPlainText
$adminPass  = Get-AzKeyVaultSecret -VaultName $kvName -Name "domain-admin-password" -AsPlainText |
              ConvertTo-SecureString -AsPlainText -Force
$adminCreds = New-Object System.Management.Automation.PSCredential($adminUser, $adminPass)

# ── Execute installation via PSRemoting ───────────────────────────────────────
if ($PSCmdlet.ShouldProcess($wacServer, "Install Windows Admin Center")) {
    Write-Host "  Connecting to $wacServer via PSRemoting..."

    $installResult = Invoke-Command -ComputerName $wacServer -Credential $adminCreds -ScriptBlock {
        param($Port)

        $installerPath = "$env:TEMP\WindowsAdminCenter.msi"
        $logPath       = "$env:TEMP\wac-install.log"

        # Download WAC installer
        Write-Output "  Downloading Windows Admin Center installer..."
        Invoke-WebRequest -Uri "https://aka.ms/wacdownload" -OutFile $installerPath -UseBasicParsing

        # Run silent installation
        Write-Output "  Running installer on port $Port..."
        $msiArgs = @(
            "/i", $installerPath,
            "/qn",
            "/L*v", $logPath,
            "SME_PORT=$Port",
            "SSL_CERTIFICATE_OPTION=generate"
        )
        $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "MSI install failed with exit code $($proc.ExitCode). See log: $logPath"
        }

        # Verify service is running
        Write-Output "  Verifying ServerManagementGateway service..."
        $service = Get-Service -Name "ServerManagementGateway" -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq "Running") {
            return "INSTALLED: WAC service is running on port $Port"
        } else {
            # Attempt to start
            Start-Service -Name "ServerManagementGateway"
            $service = Get-Service -Name "ServerManagementGateway"
            return "STARTED: WAC service status is $($service.Status)"
        }
    } -ArgumentList $wacPort

    Write-Host "  $installResult" -ForegroundColor Green
}

Write-Host "`nWindows Admin Center deployment complete." -ForegroundColor Cyan
Write-Host "Access WAC at: https://$wacServer`:$wacPort"
