<#
.SYNOPSIS
    Establishes an Azure CLI session for Azure Local deployment.

.DESCRIPTION
    Connects to Azure using Azure CLI (az login) and sets the subscription context.
    The tenant and the subscription come only from the infrastructure file: azure.tenant_id and azure.subscription_id.
    The script asks for nothing. When a value of the file is missing or not a GUID it ends with exit code 2 and signs in to nothing.

    Two ways to sign in:
    1. Browser login (default).
    2. Device code login, for headless or remote sessions (use -UseDeviceCode).

    Exit codes: 0 signed in and the subscription is set; 1 az login or az account set failed, or Azure CLI is missing; 2 the file
    cannot be read or a value of it is missing.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only azure.tenant_id and azure.subscription_id are read.

.PARAMETER UseDeviceCode
    Use device code flow instead of browser-based login. Useful for headless/SSH sessions.

.EXAMPLE
    .\Connect-AzureCliSession.ps1 -InfrastructureFile ./infrastructure.yml

.EXAMPLE
    # Device code flow for headless sessions
    .\Connect-AzureCliSession.ps1 -InfrastructureFile ./infrastructure.yml -UseDeviceCode

.NOTES
    File Name      : Connect-AzureCliSession.ps1
    Author         : Azure Local Cloud AzureLocalCloud
    Prerequisite   : PowerShell 7.0+, Azure CLI (az)
    Created        : 2026-03-02
    Version        : 1.0.0

    Standards      : AzureLocal Cloud Team PowerShell Standards
    Framework      : AzureLocal Cloud Team Scripting Framework
    Repository     : AzureLocalCloud-docs-azl-toolkit

.LINK
    https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false, HelpMessage = "Use device code flow for headless/remote sessions")]
    [switch]$UseDeviceCode
)

#Requires -Version 7.0

# =============================================================================
# SCRIPT INITIALIZATION
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScriptName = "Connect-AzureCliSession"
$script:ScriptVersion = "1.0.0"

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info','Warning','Error','Success')] [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# =============================================================================
# PREREQUISITE CHECK
# =============================================================================

Write-Log "[$script:ScriptName v$script:ScriptVersion] Starting Azure CLI session setup"

# Verify Azure CLI is installed
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Log "Azure CLI (az) not found. Install from: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli" -Level Error
    exit 1
}

$azVersion = (az version 2>$null | ConvertFrom-Json).'azure-cli'
Write-Log "Azure CLI version: $azVersion"

# =============================================================================
# CONFIGURATION RESOLUTION
# =============================================================================

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

Write-Log "Loading the sign-in values from: $InfrastructureFile"
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Error "Cannot read the infrastructure file: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
$TenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$SubscriptionId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')
foreach ($pair in @(@('azure.tenant_id', $TenantId), @('azure.subscription_id', $SubscriptionId))) {
    if ($pair[1] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or $pair[1] -eq [guid]::Empty.ToString()) {
        Write-Error "$($pair[0]) is missing, is not a GUID or is the all-zero placeholder. Set it in the infrastructure file." -ErrorAction Continue
        exit 2
    }
}

# =============================================================================
# AUTHENTICATION
# =============================================================================

Write-Log "Connecting to Azure via CLI (Tenant: $TenantId)..."

$loginArgs = @("login", "--tenant", $TenantId)

if ($UseDeviceCode) {
    $loginArgs += "--use-device-code"
    Write-Log "Using device code authentication — follow the instructions displayed" -Level Warning
}

try {
    $result = & az @loginArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az login failed with exit code $LASTEXITCODE`: $result"
    }
    Write-Log "Authentication successful" -Level Success
}
catch {
    Write-Log "Authentication failed: $($_.Exception.Message)" -Level Error
    throw
}

# =============================================================================
# SET SUBSCRIPTION CONTEXT
# =============================================================================

Write-Log "Setting subscription context: $SubscriptionId"

try {
    $result = & az account set --subscription $SubscriptionId 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az account set failed with exit code $LASTEXITCODE`: $result"
    }
    Write-Log "Subscription context set successfully" -Level Success
}
catch {
    Write-Log "Failed to set subscription context: $($_.Exception.Message)" -Level Error
    Write-Log "Verify the subscription ID is correct and you have access" -Level Warning
    throw
}

# =============================================================================
# VERIFICATION
# =============================================================================

$accountInfo = az account show --output json 2>$null | ConvertFrom-Json

Write-Log "Session verified:" -Level Success
Write-Host ""
Write-Host "  Account        : $($accountInfo.user.name)" -ForegroundColor Cyan
Write-Host "  Subscription   : $($accountInfo.name) ($($accountInfo.id))" -ForegroundColor Cyan
Write-Host "  Tenant         : $($accountInfo.tenantId)" -ForegroundColor Cyan
Write-Host "  Environment    : $($accountInfo.environmentName)" -ForegroundColor Cyan
Write-Host "  State          : $($accountInfo.state)" -ForegroundColor Cyan
Write-Host ""
Write-Log "Azure CLI session is ready. You may now run deployment commands."
