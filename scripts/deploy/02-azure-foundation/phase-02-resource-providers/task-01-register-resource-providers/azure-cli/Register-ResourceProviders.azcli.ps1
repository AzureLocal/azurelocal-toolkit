<#
.SYNOPSIS
    Registers Azure resource providers using Azure CLI commands.

.DESCRIPTION
    This script uses Azure CLI (az commands) to register the required Azure
    resource providers for Azure Local deployment. Useful when Az PowerShell
    module is not available or when CLI consistency is preferred.

.PARAMETER SubscriptionId
    The Azure subscription ID where resource providers will be registered.

.PARAMETER WaitForRegistration
    If specified, waits for all provider registrations to complete.

.EXAMPLE
    .\Register-ResourceProviders.azcli.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Requires:
    - Azure CLI (az) installed and authenticated
    - Contributor or Owner role on target subscription
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [switch]$WaitForRegistration,

    [Parameter(Mandatory = $false)]
    [int]$MaxWaitMinutes = 15
)

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
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "White" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Verify Azure CLI is installed
if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) {
    Write-Log -Message "Azure CLI (az) is not installed or not in PATH" -Level "ERROR"
    exit 1
}

# Set subscription if provided
if ($SubscriptionId) {
    Write-Log -Message "Setting subscription context to: $SubscriptionId" -Level "INFO"
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        Write-Log -Message "Failed to set subscription context" -Level "ERROR"
        exit 1
    }
}

# Get current subscription
$currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
Write-Log -Message "Operating on subscription: $($currentSub.name) ($($currentSub.id))" -Level "INFO"

Write-Log -Message "Starting resource provider registration..." -Level "INFO"

$results = @()
$pendingProviders = @()

foreach ($provider in $RequiredProviders) {
    # Check current status
    $status = az provider show --namespace $provider --query "registrationState" -o tsv 2>$null
    
    if ($status -eq "Registered") {
        Write-Log -Message "Provider '$provider' is already registered" -Level "INFO"
        $results += @{ Provider = $provider; Status = "AlreadyRegistered"; Success = $true }
    }
    else {
        Write-Log -Message "Registering provider '$provider'..." -Level "INFO"
        az provider register --namespace $provider --wait:$false 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            $results += @{ Provider = $provider; Status = "Registering"; Success = $true }
            $pendingProviders += $provider
        }
        else {
            Write-Log -Message "Failed to register provider '$provider'" -Level "ERROR"
            $results += @{ Provider = $provider; Status = "Failed"; Success = $false }
        }
    }
}

# Wait for registration if requested
if ($WaitForRegistration -and $pendingProviders.Count -gt 0) {
    Write-Log -Message "Waiting for $($pendingProviders.Count) providers to complete registration..." -Level "INFO"
    
    $startTime = Get-Date
    $timeoutTime = $startTime.AddMinutes($MaxWaitMinutes)
    
    while ($pendingProviders.Count -gt 0 -and (Get-Date) -lt $timeoutTime) {
        $stillPending = @()
        
        foreach ($provider in $pendingProviders) {
            $status = az provider show --namespace $provider --query "registrationState" -o tsv
            
            if ($status -eq "Registered") {
                Write-Log -Message "Provider '$provider' registration completed" -Level "INFO"
            }
            elseif ($status -eq "Registering") {
                $stillPending += $provider
            }
            else {
                Write-Log -Message "Provider '$provider' has unexpected state: $status" -Level "WARN"
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
    Write-Log -Message "Some providers failed to register" -Level "ERROR"
    exit 1
}

Write-Log -Message "Resource provider registration completed successfully" -Level "INFO"
exit 0
