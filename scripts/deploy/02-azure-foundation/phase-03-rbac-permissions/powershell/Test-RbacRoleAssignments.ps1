<#
.SYNOPSIS
    Validates RBAC role assignments for Azure Local deployment service principal or user.

.DESCRIPTION
    Loads config from infrastructure.yml, validates role assignments at subscription and resource group scope.

.PARAMETER ConfigPath
    Path to infrastructure.yml config file. Defaults to configs/infrastructure.yml in the repository root.

.PARAMETER ServicePrincipalDisplayName
    Display name of the deployment service principal to validate.

.PARAMETER UserPrincipalName
    UPN of the deployment user to validate.

.PARAMETER ObjectId
    Entra ID Object ID of the principal to validate (optional).

.EXAMPLE
    .\Validate-RbacRoleAssignments.ps1 -ConfigPath "configs/infrastructure.yml" -ServicePrincipalDisplayName "sp-azurelocal-deploy"

.EXAMPLE
    .\Validate-RbacRoleAssignments.ps1 -ConfigPath "configs/infrastructure.yml" -UserPrincipalName "deployment-user@yourdomain.com"

.EXAMPLE
    .\Validate-RbacRoleAssignments.ps1 -ConfigPath "configs/infrastructure.yml" -ObjectId "55555555-5555-5555-5555-555555555555"

.NOTES
    Requires: Az.Accounts, Az.Resources, powershell-yaml modules
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({Test-Path $_})]
    [string]$ConfigPath = "configs/infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$ServicePrincipalDisplayName,

    [Parameter(Mandatory = $false)]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [string]$ObjectId
)

#Requires -Modules Az.Accounts, Az.Resources, powershell-yaml

# ============================================================================
# INITIALIZATION
# ============================================================================
$ErrorActionPreference = "Stop"

# ============================================================================
# MAIN LOGIC
# ============================================================================

try {
    Write-Host "Loading configuration from: $ConfigPath" -ForegroundColor Cyan

    # Load infrastructure.yml
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "powershell-yaml module not found. Install with: Install-Module powershell-yaml -Scope CurrentUser"
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $yamlContent = Get-Content -Path $ConfigPath -Raw
    $config = ConvertFrom-Yaml -Yaml $yamlContent -Ordered
    Write-Host "  Config loaded successfully" -ForegroundColor Green

    # Extract config values
    # Handle different possible subscription structures
    if ($config.azure_platform.subscriptions.demo) {
        $subscriptionId = $config.azure_platform.subscriptions.demo.id
    } elseif ($config.azure_platform.subscriptions.primary) {
        $subscriptionId = $config.azure_platform.subscriptions.primary.id
    } else {
        # Get first subscription
        $firstSubKey = $config.azure_platform.subscriptions.Keys | Select-Object -First 1
        $subscriptionId = $config.azure_platform.subscriptions[$firstSubKey].id
    }

    # Handle different possible resource group structures
    if ($config.azure_platform.resource_group_name) {
        $targetResourceGroup = $config.azure_platform.resource_group_name
    } else {
        $targetResourceGroup = $config.azure_platform.resource_group_name
    }

    $subscriptionRoles = $config.identity.service_principal.roles.subscription
    $resourceGroupRoles = $config.identity.service_principal.roles.resource_group

    # Use default roles if not specified in config
    if (-not $subscriptionRoles) {
        Write-Host "`nUsing default subscription-level roles (not found in config)" -ForegroundColor Yellow
        $subscriptionRoles = @(
            "Contributor"
            "User Access Administrator"
            "Azure Stack HCI Administrator"
            "Reader"
        )
    }

    if (-not $resourceGroupRoles) {
        Write-Host "Using default resource group-level roles (not found in config)" -ForegroundColor Yellow
        $resourceGroupRoles = @(
            "Key Vault Data Access Administrator"
            "Key Vault Secrets Officer"
            "Key Vault Contributor"
            "Storage Account Contributor"
            "Azure Connected Machine Onboarding"
            "Azure Connected Machine Resource Administrator"
        )
    }

    Write-Host "`nSubscription ID: $subscriptionId" -ForegroundColor White
    Write-Host "Target RG: $targetResourceGroup" -ForegroundColor White

    # Determine principal to validate
    if ($ObjectId) {
        Write-Host "`nUsing provided Object ID: $ObjectId" -ForegroundColor Cyan
        $principal = Get-AzADUser -ObjectId $ObjectId -ErrorAction SilentlyContinue
        if (-not $principal) {
            $principal = Get-AzADServicePrincipal -ObjectId $ObjectId -ErrorAction SilentlyContinue
        }
        if ($principal) {
            Write-Host "  Resolved: $($principal.DisplayName)" -ForegroundColor Green
            $principalType = if ($principal.PSObject.Properties['UserPrincipalName']) { "User" } else { "Service Principal" }
        } else {
            Write-Host "  Could not resolve display name - proceeding with Object ID" -ForegroundColor Yellow
            $principalType = "Unknown"
        }
        $principalObjectId = $ObjectId
        $principalDisplayName = if ($principal) { $principal.DisplayName } else { $ObjectId }
    } elseif ($ServicePrincipalDisplayName) {
        Write-Host "`nFinding service principal: $ServicePrincipalDisplayName" -ForegroundColor Cyan
        $principal = Get-AzADServicePrincipal -DisplayName $ServicePrincipalDisplayName
        $principalType = "Service Principal"
    } elseif ($UserPrincipalName) {
        Write-Host "`nFinding user: $UserPrincipalName" -ForegroundColor Cyan
        $principal = Get-AzADUser -UserPrincipalName $UserPrincipalName
        $principalType = "User"
    } else {
        Write-Host "ERROR: Must specify -ServicePrincipalDisplayName, -UserPrincipalName, or -ObjectId" -ForegroundColor Red
        exit 1
    }

    if (-not $ObjectId) {
        if (-not $principal) {
            Write-Host "ERROR: $principalType not found" -ForegroundColor Red
            exit 1
        }
        $principalObjectId = $principal.Id
        $principalDisplayName = $principal.DisplayName
    }

    Write-Host "  Display Name: $principalDisplayName" -ForegroundColor Green
    Write-Host "  Object ID: $principalObjectId" -ForegroundColor White

    # Set subscription context
    Write-Host "`nSetting Azure subscription context..." -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    Write-Host "  Context set to subscription: $subscriptionId" -ForegroundColor Green

    # Define scopes
    $subscriptionScope = "/subscriptions/$subscriptionId"
    $targetScope = "/subscriptions/$subscriptionId/resourceGroups/$targetResourceGroup"

    # Validate subscription-level roles
    Write-Host "`nValidating subscription-level roles..." -ForegroundColor Cyan
    $subscriptionAssignments = Get-AzRoleAssignment -ObjectId $principalObjectId -Scope $subscriptionScope -ErrorAction SilentlyContinue
    $assignedSubscriptionRoles = $subscriptionAssignments.RoleDefinitionName

    $missingSubscriptionRoles = @()
    foreach ($role in $subscriptionRoles) {
        if ($assignedSubscriptionRoles -notcontains $role) {
            $missingSubscriptionRoles += $role
        } else {
            Write-Host "  ✓ $role - assigned" -ForegroundColor Green
        }
    }

    if ($missingSubscriptionRoles.Count -gt 0) {
        Write-Host "  ✗ Missing subscription roles: $($missingSubscriptionRoles -join ', ')" -ForegroundColor Red
    }

    # Validate resource group-level roles
    Write-Host "`nValidating resource group-level roles ($targetResourceGroup)..." -ForegroundColor Cyan
    $resourceGroupAssignments = Get-AzRoleAssignment -ObjectId $principalObjectId -Scope $targetScope -ErrorAction SilentlyContinue
    $assignedResourceGroupRoles = $resourceGroupAssignments.RoleDefinitionName

    $missingResourceGroupRoles = @()
    foreach ($role in $resourceGroupRoles) {
        if ($assignedResourceGroupRoles -notcontains $role) {
            $missingResourceGroupRoles += $role
        } else {
            Write-Host "  ✓ $role - assigned" -ForegroundColor Green
        }
    }

    if ($missingResourceGroupRoles.Count -gt 0) {
        Write-Host "  ✗ Missing resource group roles: $($missingResourceGroupRoles -join ', ')" -ForegroundColor Red
    }

    # Summary
    Write-Host "`n=========================================" -ForegroundColor Cyan
    Write-Host "VALIDATION SUMMARY" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    $totalRoles = $subscriptionRoles.Count + $resourceGroupRoles.Count
    $assignedRoles = ($subscriptionRoles.Count - $missingSubscriptionRoles.Count) + ($resourceGroupRoles.Count - $missingResourceGroupRoles.Count)

    Write-Host "Principal: $principalDisplayName" -ForegroundColor White
    Write-Host "Type: $principalType" -ForegroundColor White
    Write-Host "Subscription: $subscriptionId" -ForegroundColor White
    Write-Host "Resource Group: $targetResourceGroup" -ForegroundColor White
    Write-Host "Roles Assigned: $assignedRoles / $totalRoles" -ForegroundColor $(if ($assignedRoles -eq $totalRoles) { "Green" } else { "Red" })

    if ($missingSubscriptionRoles.Count -eq 0 -and $missingResourceGroupRoles.Count -eq 0) {
        Write-Host "`n✓ All required RBAC roles are assigned!" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "`n✗ Some RBAC roles are missing. Run the assignment script to fix." -ForegroundColor Red
        exit 1
    }

} catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# CLEANUP / OUTPUT
# ============================================================================