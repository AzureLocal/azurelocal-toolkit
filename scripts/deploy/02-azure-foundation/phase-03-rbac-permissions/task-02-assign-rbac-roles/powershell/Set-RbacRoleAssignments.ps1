<#
.SYNOPSIS
    Assigns RBAC roles to the Azure Local deployment service principal.

.DESCRIPTION
    This script assigns the required Azure RBAC roles to the deployment service
    principal at subscription and resource group scopes for Azure Local deployment.
    Reads configuration from infrastructure.yml using fixed variable paths.

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration file.
    Default: infrastructure.yml in repository root

.PARAMETER WhatIf
    Shows what would be assigned without making actual changes.
    This parameter is automatically available due to SupportsShouldProcess.

.EXAMPLE
    # Assign RBAC roles (dry run)
    .\Set-RbacRoleAssignments.ps1 -ConfigFile ..\..\infrastructure.yml -WhatIf

.EXAMPLE
    # Assign RBAC roles
    .\Set-RbacRoleAssignments.ps1 -ConfigFile ..\..\infrastructure.yml

.NOTES
    Requires: Az.Accounts, Az.KeyVault, powershell-yaml modules
    Author: AzureLocal Cloud Team Team
    Date: 2026-02-08
    Version: 1.0.0
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFile = ".\infrastructure.yml"
)

#Requires -Modules Az.Accounts, Az.KeyVault, powershell-yaml

# ============================================================================
# INITIALIZATION
# ============================================================================
$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

# Load configuration
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Yaml

# ============================================================================
# MAIN LOGIC
# ============================================================================

# Required RBAC roles for Azure Local deployment
$RequiredRoles = @(
    # Subscription-level roles
    @{
        RoleName = "Contributor"
        Scope    = "Subscription"
        Required = $true
    },
    @{
        RoleName = "User Access Administrator"
        Scope    = "Subscription"
        Required = $true
    },
    @{
        RoleName = "Azure Stack HCI Administrator"
        Scope    = "Subscription"
        Required = $true
    },
    @{
        RoleName = "Reader"
        Scope    = "Subscription"
        Required = $true
    },
    # Resource group-level roles
    @{
        RoleName = "Azure Connected Machine Onboarding"
        Scope    = "ResourceGroup"
        Required = $true
    },
    @{
        RoleName = "Azure Connected Machine Resource Administrator"
        Scope    = "ResourceGroup"
        Required = $true
    },
    @{
        RoleName = "Key Vault Data Access Administrator"
        Scope    = "ResourceGroup"
        Required = $true
    },
    @{
        RoleName = "Key Vault Secrets Officer"
        Scope    = "ResourceGroup"
        Required = $true
    },
    @{
        RoleName = "Key Vault Contributor"
        Scope    = "ResourceGroup"
        Required = $true
    },
    @{
        RoleName = "Storage Account Contributor"
        Scope    = "ResourceGroup"
        Required = $true
    }
)

function Assign-SingleRole {
    [CmdletBinding()]
    param(
        [string]$PrincipalId,
        [string]$RoleName,
        [string]$Scope
    )

    try {
        # Check if assignment already exists
        $existing = Get-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $RoleName -Scope $Scope -ErrorAction SilentlyContinue
        
        if ($existing) {
            Write-Host "Role '$RoleName' already assigned at scope" -ForegroundColor Green
            return @{ Success = $true; Status = "AlreadyAssigned" }
        }

        # Create new assignment
        Write-Host "Assigning role '$RoleName'..." -ForegroundColor Yellow
        $assignment = New-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $RoleName -Scope $Scope -ErrorAction Stop
        
        Write-Host "Role '$RoleName' assigned successfully" -ForegroundColor Green
        return @{ Success = $true; Status = "Assigned"; Assignment = $assignment }
    }
    catch {
        Write-Host "Failed to assign role '$RoleName': $_" -ForegroundColor Red
        return @{ Success = $false; Status = "Failed"; Error = $_.Exception.Message }
    }
}

try {
    Write-Host "Starting RBAC Role Assignment for Azure Local Deployment SPN" -ForegroundColor Cyan

    # Extract values from config using fixed paths
    $subscriptionId = $config.azure_platform.subscriptions.lab.id
    if (-not $subscriptionId) {
        # Fallback to first available subscription
        $subscriptions = $config.azure_platform.subscriptions
        if ($subscriptions) {
            $firstSub = $subscriptions.PSObject.Properties | Select-Object -First 1
            if ($firstSub) {
                $subscriptionId = $firstSub.Value.id
            }
        }
    }
    $servicePrincipalAppId = $config.identity.service_principal.client_id
    
    # Extract Azure Local cluster resource group for resource group-level role assignments
    $clusterResourceGroup = $config.azure_platform.resource_group_name

    # Validate required parameters
    if (-not $subscriptionId) {
        Write-Host "SubscriptionId is required" -ForegroundColor Red
        exit 1
    }

    if (-not $servicePrincipalAppId) {
        Write-Host "ServicePrincipalAppId is required" -ForegroundColor Red
        exit 1
    }

    if (-not $clusterResourceGroup) {
        Write-Host "Cluster resource group is required" -ForegroundColor Red
        exit 1
    }

    Write-Host "Using Subscription ID: $subscriptionId" -ForegroundColor Green
    Write-Host "Using Service Principal App ID: $servicePrincipalAppId" -ForegroundColor Green
    Write-Host "Using Cluster Resource Group: $clusterResourceGroup" -ForegroundColor Green

    # Get service principal object ID
    $sp = Get-AzADServicePrincipal -ApplicationId $servicePrincipalAppId -ErrorAction Stop
    $principalId = $sp.Id
    Write-Host "Service Principal: $($sp.DisplayName) (Object ID: $principalId)" -ForegroundColor Green

    # Set subscription context if provided
    if ($subscriptionId) {
        Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    }
    
    $context = Get-AzContext
    $subscriptionScope = "/subscriptions/$($context.Subscription.Id)"
    Write-Host "Subscription scope: $subscriptionScope" -ForegroundColor Green

    # Assign roles
    $results = @()

    foreach ($role in $RequiredRoles) {
        $scope = switch ($role.Scope) {
            "Subscription" { $subscriptionScope }
            "ResourceGroup" {
                if ($clusterResourceGroup) {
                    "$subscriptionScope/resourceGroups/$clusterResourceGroup"
                } else {
                    Write-Host "No cluster resource group found for '$($role.RoleName)' - skipping" -ForegroundColor Yellow
                    $null
                }
            }
        }

        if (-not $scope) {
            if ($role.Required) {
                Write-Host "Skipping '$($role.RoleName)' - no scope available" -ForegroundColor Yellow
            }
            continue
        }

        $result = Assign-SingleRole -PrincipalId $principalId -RoleName $role.RoleName -Scope $scope
        $results += [PSCustomObject]@{
            Role    = $role.RoleName
            Scope   = $role.Scope
            Status  = $result.Status
            Success = $result.Success
        }
    }

    # Summary
    Write-Host ""
    Write-Host "RBAC Assignment Summary:" -ForegroundColor Cyan
    $results | Format-Table -AutoSize

    $failed = ($results | Where-Object { -not $_.Success }).Count
    if ($failed -gt 0) {
        Write-Host "$failed role assignments failed" -ForegroundColor Red
        exit 1
    }

    Write-Host "RBAC role assignment completed successfully" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "Fatal error during RBAC assignment: $_" -ForegroundColor Red
    throw
}
