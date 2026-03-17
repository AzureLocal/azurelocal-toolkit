<#
.SYNOPSIS
    Establishes an Azure PowerShell session for Azure Local deployment.

.DESCRIPTION
    Connects to Azure using Azure PowerShell (Az module) and sets the subscription context.
    This is a standalone authentication helper — no Key Vault or infrastructure.yml dependencies.

    Supports three modes:
    1. Interactive login (default) — Opens browser for authentication
    2. Device code login — For headless/remote sessions (use -UseDeviceAuthentication)
    3. Config-based login — Reads TenantId/SubscriptionId from infrastructure.yml (use -ConfigPath)

    All parameters are prompted for interactively if not provided at invocation.

.PARAMETER TenantId
    Microsoft Entra ID tenant ID. Prompted if not provided and -ConfigPath is not used.

.PARAMETER SubscriptionId
    Azure subscription ID. Prompted if not provided and -ConfigPath is not used.

.PARAMETER UseDeviceAuthentication
    Use device code flow instead of browser-based login. Useful for headless/SSH sessions.

.PARAMETER ConfigPath
    Optional path to an infrastructure.yml file. If provided, TenantId and SubscriptionId
    are read from azure.tenant_id and azure.subscription_id in the YAML config.
    Requires the powershell-yaml module.

.PARAMETER Scope
    Azure context scope. Default is 'Process' to avoid persisting credentials.
    Use 'CurrentUser' to persist the session across PowerShell instances.

.EXAMPLE
    # Interactive — prompts for TenantId and SubscriptionId
    .\Connect-AzureSession.ps1

.EXAMPLE
    # Pass parameters directly
    .\Connect-AzureSession.ps1 -TenantId "00000000-0000-0000-0000-000000000000" -SubscriptionId "11111111-1111-1111-1111-111111111111"

.EXAMPLE
    # Device code flow for headless sessions
    .\Connect-AzureSession.ps1 -TenantId "00000000-..." -SubscriptionId "11111111-..." -UseDeviceAuthentication

.EXAMPLE
    # Read values from infrastructure.yml
    .\Connect-AzureSession.ps1 -ConfigPath "../../config/infrastructure.yml"

.NOTES
    File Name      : Connect-AzureSession.ps1
    Author         : Azure Local Cloud AzureLocalCloud
    Prerequisite   : PowerShell 7.0+, Az.Accounts module
    Created        : 2026-03-02
    Version        : 1.0.0

    Standards      : Azure Local Cloudnology PowerShell Standards
    Framework      : Azure Local Cloudnology Scripting Framework
    Repository     : AzureLocalCloud-docs-azl-toolkit

.LINK
    https://learn.microsoft.com/en-us/powershell/azure/authenticate-azureps
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
    [switch]$UseDeviceAuthentication,

    [Parameter(Mandatory = $false, HelpMessage = "Path to infrastructure.yml config file")]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false, HelpMessage = "Azure context scope (Process or CurrentUser)")]
    [ValidateSet('Process', 'CurrentUser')]
    [string]$Scope = 'Process'
)

#Requires -Version 7.0
#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.0.0" }

# =============================================================================
# SCRIPT INITIALIZATION
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScriptName = "Connect-AzureSession"
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
# CONFIGURATION RESOLUTION
# =============================================================================

Write-Log "[$script:ScriptName v$script:ScriptVersion] Starting Azure PowerShell session setup"

# If ConfigPath is provided, read TenantId and SubscriptionId from YAML
if ($ConfigPath) {
    Write-Log "Loading configuration from: $ConfigPath"

    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "powershell-yaml module required for -ConfigPath. Install with: Install-Module powershell-yaml -Scope CurrentUser"
    }

    Import-Module powershell-yaml -ErrorAction Stop
    $yamlContent = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Yaml

    # Support both flat (azure.tenant_id) and nested (azure.tenant.id) YAML structures
    if (-not $TenantId) {
        $TenantId = if ($yamlContent.azure.tenant.id) { $yamlContent.azure.tenant.id }
                    elseif ($yamlContent.azure.tenant_id) { $yamlContent.azure.tenant_id }
                    else { $null }
        if ($TenantId) { Write-Log "TenantId loaded from config: $TenantId" }
    }

    # Support both flat (azure.subscription_id) and nested (azure.subscriptions.*.id) structures
    if (-not $SubscriptionId) {
        if ($yamlContent.azure.subscription_id) {
            $SubscriptionId = $yamlContent.azure.subscription_id
        } elseif ($yamlContent.azure.subscriptions) {
            # Take the first subscription found
            $firstSub = $yamlContent.azure.subscriptions.GetEnumerator() | Select-Object -First 1
            $SubscriptionId = $firstSub.Value.id
        }
        if ($SubscriptionId) { Write-Log "SubscriptionId loaded from config: $SubscriptionId" }
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

Write-Log "Connecting to Azure (Tenant: $TenantId)..."

$connectParams = @{
    TenantId       = $TenantId
    SubscriptionId = $SubscriptionId
    Scope          = $Scope
}

if ($UseDeviceAuthentication) {
    $connectParams['UseDeviceAuthentication'] = $true
    Write-Log "Using device code authentication — follow the instructions in the browser" -Level Warning
}

try {
    Connect-AzAccount @connectParams | Out-Null
    Write-Log "Authentication successful" -Level Success
}
catch {
    Write-Log "Authentication failed: $($_.Exception.Message)" -Level Error
    throw
}

# =============================================================================
# VERIFICATION
# =============================================================================

$context = Get-AzContext
Write-Log "Session verified:" -Level Success
Write-Host ""
Write-Host "  Account        : $($context.Account.Id)" -ForegroundColor Cyan
Write-Host "  Subscription   : $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Cyan
Write-Host "  Tenant         : $($context.Tenant.Id)" -ForegroundColor Cyan
Write-Host "  Environment    : $($context.Environment.Name)" -ForegroundColor Cyan
Write-Host "  Scope          : $Scope" -ForegroundColor Cyan
Write-Host ""
Write-Log "Azure PowerShell session is ready. You may now run deployment scripts."
