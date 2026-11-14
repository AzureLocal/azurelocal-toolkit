<#
.SYNOPSIS
    Establishes an Azure PowerShell session for Azure Local deployment.

.DESCRIPTION
    Connects to Azure using Azure PowerShell (Az module) and sets the subscription context.
    The tenant and the subscription come only from the infrastructure file: azure.tenant_id and azure.subscription_id.
    The script asks for nothing. When a value of the file is missing or not a GUID it ends with exit code 2 and signs in to nothing.

    Two ways to sign in:
    1. Browser login (default).
    2. Device code login, for headless or remote sessions (use -UseDeviceAuthentication).

    Exit codes: 0 signed in; 1 the sign-in failed; 2 the file cannot be read or a value of it is missing.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only azure.tenant_id and azure.subscription_id are read.

.PARAMETER UseDeviceAuthentication
    Use device code flow instead of browser-based login. Useful for headless/SSH sessions.

.PARAMETER Scope
    Azure context scope. Default is 'Process' to avoid persisting credentials.
    Use 'CurrentUser' to persist the session across PowerShell instances.

.EXAMPLE
    .\Connect-AzureSession.ps1 -InfrastructureFile ./infrastructure.yml

.EXAMPLE
    # Device code flow for headless sessions
    .\Connect-AzureSession.ps1 -InfrastructureFile ./infrastructure.yml -UseDeviceAuthentication

.NOTES
    File Name      : Connect-AzureSession.ps1
    Author         : Azure Local Cloud AzureLocalCloud
    Prerequisite   : PowerShell 7.0+, Az.Accounts module
    Created        : 2026-03-02
    Version        : 1.0.0

    Standards      : AzureLocal Cloud Team PowerShell Standards
    Framework      : AzureLocal Cloud Team Scripting Framework
    Repository     : AzureLocalCloud-docs-azl-toolkit

.LINK
    https://learn.microsoft.com/en-us/powershell/azure/authenticate-azureps
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false, HelpMessage = "Use device code flow for headless/remote sessions")]
    [switch]$UseDeviceAuthentication,

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
