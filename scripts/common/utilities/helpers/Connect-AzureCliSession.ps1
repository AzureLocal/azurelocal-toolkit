<#
.SYNOPSIS
    Establishes an Azure CLI session for Azure Local deployment.

.DESCRIPTION
    Connects to Azure using Azure CLI (az login) and sets the subscription context.
    This is a standalone authentication helper — no Key Vault or infrastructure.yml dependencies.

    Supports three modes:
    1. Interactive login (default) — Opens browser for authentication
    2. Device code login — For headless/remote sessions (use -UseDeviceCode)
    3. Config-based login — Reads TenantId/SubscriptionId from infrastructure.yml (use -ConfigPath)

    All parameters are prompted for interactively if not provided at invocation.

.PARAMETER TenantId
    Microsoft Entra ID tenant ID. Prompted if not provided and -ConfigPath is not used.

.PARAMETER SubscriptionId
    Azure subscription ID. Prompted if not provided and -ConfigPath is not used.

.PARAMETER UseDeviceCode
    Use device code flow instead of browser-based login. Useful for headless/SSH sessions.

.PARAMETER ConfigPath
    Optional path to an infrastructure.yml config file. If provided, TenantId and SubscriptionId
    are read from azure.tenant_id and azure.subscription_id in the YAML config.
    Requires the powershell-yaml module.

.EXAMPLE
    # Interactive — prompts for TenantId and SubscriptionId
    .\Connect-AzureCliSession.ps1

.EXAMPLE
    # Pass parameters directly
    .\Connect-AzureCliSession.ps1 -TenantId "00000000-0000-0000-0000-000000000000" -SubscriptionId "11111111-1111-1111-1111-111111111111"

.EXAMPLE
    # Device code flow for headless sessions
    .\Connect-AzureCliSession.ps1 -TenantId "00000000-..." -SubscriptionId "11111111-..." -UseDeviceCode

.EXAMPLE
    # Read values from infrastructure.yml
    .\Connect-AzureCliSession.ps1 -ConfigPath "../../configs/infrastructure.yml"

.NOTES
    File Name      : Connect-AzureCliSession.ps1
    Author         : Azure Local Cloud AzureLocalCloud
    Prerequisite   : PowerShell 7.0+, Azure CLI (az)
    Created        : 2026-03-02
    Version        : 1.0.0

    Standards      : Azure Local Cloudnology PowerShell Standards
    Framework      : Azure Local Cloudnology Scripting Framework
    Repository     : AzureLocalCloud-docs-azl-toolkit

.LINK
    https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Microsoft Entra ID tenant ID")]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [Parameter(Mandatory = $false, HelpMessage = "Azure subscription ID")]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Use device code flow for headless/remote sessions")]
    [switch]$UseDeviceCode,

    [Parameter(Mandatory = $false, HelpMessage = "Path to infrastructure.yml config file")]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath
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
    throw "Azure CLI is not installed or not in PATH."
}

$azVersion = (az version 2>$null | ConvertFrom-Json).'azure-cli'
Write-Log "Azure CLI version: $azVersion"

# =============================================================================
# CONFIGURATION RESOLUTION
# =============================================================================

# If ConfigPath is provided, read TenantId and SubscriptionId from YAML
if ($ConfigPath) {
    Write-Log "Loading configuration from: $ConfigPath"

    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "powershell-yaml module required for -ConfigPath. Install with: Install-Module powershell-yaml -Scope CurrentUser"
    }

    Import-Module powershell-yaml -ErrorAction Stop
    $yamlContent = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Yaml

    if (-not $TenantId -and $yamlContent.azure.tenant_id) {
        $TenantId = $yamlContent.azure.tenant_id
        Write-Log "TenantId loaded from config: $TenantId"
    }

    if (-not $SubscriptionId -and $yamlContent.azure.subscription_id) {
        $SubscriptionId = $yamlContent.azure.subscription_id
        Write-Log "SubscriptionId loaded from config: $SubscriptionId"
    }
}

# Prompt for any values still missing
if (-not $TenantId) {
    $TenantId = Read-Host -Prompt "Enter Microsoft Entra ID Tenant ID"
    if ($TenantId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "Invalid Tenant ID format. Expected a GUID."
    }
}

if (-not $SubscriptionId) {
    $SubscriptionId = Read-Host -Prompt "Enter Azure Subscription ID"
    if ($SubscriptionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "Invalid Subscription ID format. Expected a GUID."
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
