<#
.SYNOPSIS
    Verifies Azure resource provider registration status.

.DESCRIPTION
    This script checks the registration status of all required Azure resource
    providers for Azure Local deployment and reports their current state.

.PARAMETER SubscriptionId
    The Azure subscription ID to check. Uses current context if not specified.

.PARAMETER OutputFormat
    Output format: Table, JSON, or CSV. Default is Table.

.EXAMPLE
    .\Test-ResourceProviders.ps1
    
.EXAMPLE
    .\Test-ResourceProviders.ps1 -OutputFormat JSON

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Table", "JSON", "CSV")]
    [string]$OutputFormat = "Table"
)

#Requires -Modules Az.Resources

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

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "White" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Set subscription if provided
if ($SubscriptionId) {
    Write-Log -Message "Setting subscription context to: $SubscriptionId" -Level "INFO"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$context = Get-AzContext
Write-Log -Message "Checking subscription: $($context.Subscription.Name)" -Level "INFO"

# Check each provider
$results = @()
$allRegistered = $true

foreach ($provider in $RequiredProviders) {
    try {
        $status = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue
        $registrationState = $status.RegistrationState
        
        $results += [PSCustomObject]@{
            Provider          = $provider
            RegistrationState = $registrationState
            IsRegistered      = ($registrationState -eq "Registered")
        }
        
        if ($registrationState -ne "Registered") {
            $allRegistered = $false
        }
    }
    catch {
        $results += [PSCustomObject]@{
            Provider          = $provider
            RegistrationState = "Error"
            IsRegistered      = $false
        }
        $allRegistered = $false
    }
}

# Output results
switch ($OutputFormat) {
    "JSON" {
        $results | ConvertTo-Json -Depth 2
    }
    "CSV" {
        $results | ConvertTo-Csv -NoTypeInformation
    }
    default {
        Write-Host ""
        $results | Format-Table -AutoSize
    }
}

# Summary
$registered = ($results | Where-Object { $_.IsRegistered }).Count
$total = $results.Count

Write-Host ""
if ($allRegistered) {
    Write-Log -Message "All $total required resource providers are registered" -Level "SUCCESS"
    exit 0
}
else {
    $notRegistered = $results | Where-Object { -not $_.IsRegistered }
    Write-Log -Message "Only $registered of $total providers are registered" -Level "WARN"
    Write-Log -Message "Missing providers:" -Level "WARN"
    foreach ($p in $notRegistered) {
        Write-Log -Message "  - $($p.Provider): $($p.RegistrationState)" -Level "WARN"
    }
    exit 1
}
