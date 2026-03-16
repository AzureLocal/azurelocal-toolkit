<#
.SYNOPSIS
    Registers all required Azure resource providers for Azure Local deployment.

.DESCRIPTION
    This script registers the 12 required Azure resource providers needed for 
    Azure Local (formerly Azure Stack HCI) cluster deployment. It checks each 
    provider's current registration status and only registers those that aren't 
    already registered.

.PARAMETER SubscriptionId
    The Azure subscription ID where resource providers will be registered.
    If not provided, uses the current subscription context.

.PARAMETER ConfigFile
    Path to the infrastructure.yml configuration file.
    Defaults to configs/infrastructure.yml in the repository root.

.PARAMETER WaitForRegistration
    If specified, waits for all provider registrations to complete.

.PARAMETER MaxWaitMinutes
    Maximum time to wait for provider registration (default: 15 minutes).

.EXAMPLE
    # Register providers using config file
    .\Register-ResourceProviders.ps1 -ConfigFile "C:\git\azl-toolkit\configs\infrastructure.yml"

.EXAMPLE
    # Register providers and wait for completion
    .\Register-ResourceProviders.ps1 -WaitForRegistration -MaxWaitMinutes 20

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Requires:
    - Az.Resources module
    - Contributor or Owner role on target subscription
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [switch]$WaitForRegistration,

    [Parameter(Mandatory = $false)]
    [int]$MaxWaitMinutes = 15
)

#Requires -Modules Az.Resources

# Script root and imports
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
# Resolve helpers path relative to script location (5 levels up to scripts/, then common/utilities/helpers)
$HelpersPath = Join-Path $ScriptRoot ".." ".." ".." ".." ".." "common" "utilities" "helpers" | Resolve-Path

# Import helpers
. (Join-Path $HelpersPath "logging.ps1")
. (Join-Path $HelpersPath "config-loader.ps1")
. (Join-Path $HelpersPath "error-handling.ps1")

# Required resource providers for Azure Local
$RequiredProviders = @(
    "Microsoft.HybridCompute",
    "Microsoft.GuestConfiguration",
    "Microsoft.HybridConnectivity",
    "Microsoft.AzureStackHCI",
    "Microsoft.Kubernetes",
    "Microsoft.KubernetesConfiguration",
    "Microsoft.ExtendedLocation",
    "Microsoft.ResourceConnector",
    "Microsoft.HybridContainerService",
    "Microsoft.Attestation",
    "Microsoft.Storage",
    "Microsoft.Insights"
)

function Register-SingleProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderNamespace
    )

    try {
        $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction SilentlyContinue
        
        if ($provider.RegistrationState -eq "Registered") {
            Write-Log -Message "Provider '$ProviderNamespace' is already registered" -Level "INFO"
            return @{
                Provider = $ProviderNamespace
                Status   = "AlreadyRegistered"
                Success  = $true
            }
        }

        Write-Log -Message "Registering provider '$ProviderNamespace'..." -Level "INFO"
        $result = Register-AzResourceProvider -ProviderNamespace $ProviderNamespace
        
        return @{
            Provider = $ProviderNamespace
            Status   = $result.RegistrationState
            Success  = $true
        }
    }
    catch {
        Write-Log -Message "Failed to register provider '$ProviderNamespace': $_" -Level "ERROR"
        return @{
            Provider = $ProviderNamespace
            Status   = "Failed"
            Success  = $false
            Error    = $_.Exception.Message
        }
    }
}

function Wait-ProviderRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Providers,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 15
    )

    $startTime = Get-Date
    $timeoutTime = $startTime.AddMinutes($TimeoutMinutes)
    $pendingProviders = $Providers.Clone()

    Write-Log -Message "Waiting for $($pendingProviders.Count) providers to complete registration..." -Level "INFO"

    while ($pendingProviders.Count -gt 0 -and (Get-Date) -lt $timeoutTime) {
        $stillPending = @()

        foreach ($provider in $pendingProviders) {
            $status = Get-AzResourceProvider -ProviderNamespace $provider
            
            if ($status.RegistrationState -eq "Registered") {
                Write-Log -Message "Provider '$provider' registration completed" -Level "INFO"
            }
            elseif ($status.RegistrationState -eq "Registering") {
                $stillPending += $provider
            }
            else {
                Write-Log -Message "Provider '$provider' has unexpected state: $($status.RegistrationState)" -Level "WARN"
            }
        }

        $pendingProviders = $stillPending

        if ($pendingProviders.Count -gt 0) {
            Write-Log -Message "$($pendingProviders.Count) providers still registering. Waiting 30 seconds..." -Level "INFO"
            Start-Sleep -Seconds 30
        }
    }

    if ($pendingProviders.Count -gt 0) {
        Write-Log -Message "Timeout waiting for providers: $($pendingProviders -join ', ')" -Level "WARN"
        return $false
    }

    return $true
}

# Main execution
try {
    Write-Log -Message "Starting Azure Local Resource Provider Registration" -Level "INFO"
    Write-Log -Message "Script Version: 1.0.0" -Level "INFO"

    # Load configuration if specified
    if ($ConfigFile -and (Test-Path $ConfigFile)) {
        Write-Log -Message "Loading configuration from: $ConfigFile" -Level "INFO"
        $config = Get-Configuration -Path $ConfigFile
        
        if (-not $SubscriptionId -and $config.azure_platform.subscriptions.lab.id) {
            $SubscriptionId = $config.azure_platform.subscriptions.lab.id
        }
    }

    # Set subscription context if provided
    if ($SubscriptionId) {
        Write-Log -Message "Setting subscription context to: $SubscriptionId" -Level "INFO"
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }

    # Get current context
    $context = Get-AzContext
    Write-Log -Message "Operating on subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -Level "INFO"

    # Register each provider
    $results = @()
    $providersToWait = @()

    foreach ($provider in $RequiredProviders) {
        $result = Register-SingleProvider -ProviderNamespace $provider
        $results += $result

        if ($result.Status -eq "Registering") {
            $providersToWait += $provider
        }
    }

    # Wait for registration if requested
    if ($WaitForRegistration -and $providersToWait.Count -gt 0) {
        $waitSuccess = Wait-ProviderRegistration -Providers $providersToWait -TimeoutMinutes $MaxWaitMinutes
        
        if (-not $waitSuccess) {
            Write-Log -Message "Some providers did not complete registration within timeout" -Level "WARN"
        }
    }

    # Summary
    $registered = ($results | Where-Object { $_.Status -eq "AlreadyRegistered" -or $_.Status -eq "Registered" }).Count
    $registering = ($results | Where-Object { $_.Status -eq "Registering" }).Count
    $failed = ($results | Where-Object { -not $_.Success }).Count

    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Registration Summary:" -Level "INFO"
    Write-Log -Message "  Registered/Already Registered: $registered" -Level "INFO"
    Write-Log -Message "  Still Registering: $registering" -Level "INFO"
    Write-Log -Message "  Failed: $failed" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"

    # Output results
    $results | ForEach-Object {
        [PSCustomObject]@{
            Provider = $_.Provider
            Status   = $_.Status
            Success  = $_.Success
        }
    } | Format-Table -AutoSize

    if ($failed -gt 0) {
        Write-Log -Message "Some providers failed to register. Check errors above." -Level "ERROR"
        exit 1
    }

    Write-Log -Message "Resource provider registration completed successfully" -Level "INFO"
    exit 0
}
catch {
    Write-Log -Message "Fatal error during resource provider registration: $_" -Level "ERROR"
    throw
}
