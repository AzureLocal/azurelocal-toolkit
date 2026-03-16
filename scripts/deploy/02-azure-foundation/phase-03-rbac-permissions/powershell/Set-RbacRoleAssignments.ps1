<#
.SYNOPSIS
    Assigns RBAC roles to Azure Local deployment service principal or user based on config.

.DESCRIPTION
    Loads config from infrastructure.yml, assigns roles at subscription/resource group scope, supports WhatIf and verification mode.

.PARAMETER ConfigPath
    Path to infrastructure.yml config file. Defaults to configs/infrastructure.yml in the repository root.

.PARAMETER ServicePrincipalDisplayName
    Display name of the deployment service principal.

.PARAMETER UserPrincipalName
    UPN of the deployment user (optional).

.PARAMETER ObjectId
    Entra ID Object ID of the principal to assign roles to (optional). Use when you have
    the Object ID directly and don't need to look up by display name or UPN.

.PARAMETER VerifyOnly
    If specified, only verifies assignments (no changes).

.EXAMPLE
    .\Set-RbacRoleAssignments.ps1 -ConfigPath "configs/infrastructure.yml" -ServicePrincipalDisplayName "sp-azurelocal-deploy" -WhatIf

.EXAMPLE
    .\Set-RbacRoleAssignments.ps1 -ConfigPath "configs/infrastructure.yml" -UserPrincipalName "deployment-user@yourdomain.com" -VerifyOnly

.EXAMPLE
    .\Set-RbacRoleAssignments.ps1 -ConfigPath "configs/infrastructure.yml" -ObjectId "55555555-5555-5555-5555-555555555555"

.NOTES
    Requires: Az.Accounts, Az.Resources, powershell-yaml modules
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({Test-Path $_})]
    [string]$ConfigPath = "configs/infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$ServicePrincipalDisplayName,

    [Parameter(Mandatory = $false)]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [string]$ObjectId,

    [Parameter(Mandatory = $false)]
    [switch]$VerifyOnly
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

    # Determine principal to assign roles to
    if ($ObjectId) {
        Write-Host "`nUsing provided Object ID: $ObjectId" -ForegroundColor Cyan
        # Try to resolve display name for logging (user or SP)
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
        # Use the provided ObjectId directly for role assignments
        $principalObjectId = $ObjectId
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
    }

    Write-Host "  Display Name: $(if ($principal) { $principal.DisplayName } else { 'N/A' })" -ForegroundColor Green
    Write-Host "  Object ID: $principalObjectId" -ForegroundColor White

    # Set subscription context
    Write-Host "`nSetting Azure subscription context..." -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    Write-Host "  Context set to subscription: $subscriptionId" -ForegroundColor Green

    # Define scopes
    $subscriptionScope = "/subscriptions/$subscriptionId"
    $targetScope = "/subscriptions/$subscriptionId/resourceGroups/$targetResourceGroup"

    # Function to assign roles
    function Assign-Role {
        param(
            [string]$RoleName,
            [string]$Scope,
            [string]$PrincipalId
        )
        
        $existing = Get-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $RoleName -Scope $Scope -ErrorAction SilentlyContinue
        
        if ($existing) {
            Write-Host "    $RoleName - already assigned" -ForegroundColor Yellow
        } elseif ($VerifyOnly) {
            Write-Host "    $RoleName - would assign" -ForegroundColor Gray
        } elseif ($PSCmdlet.ShouldProcess($Scope, "Assign role: $RoleName")) {
            try {
                New-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $RoleName -Scope $Scope -ErrorAction Stop | Out-Null
                Write-Host "    $RoleName - assigned" -ForegroundColor Green
            } catch {
                Write-Host "    $RoleName - FAILED: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # Assign subscription-level roles
    Write-Host "`nAssigning subscription-level roles..." -ForegroundColor Cyan
    foreach ($role in $subscriptionRoles) {
        Assign-Role -RoleName $role -Scope $subscriptionScope -PrincipalId $principalObjectId
    }

    # Assign resource group roles (Azure Local cluster RG where all resources are deployed)
    Write-Host "`nAssigning resource group roles to Azure Local cluster RG ($targetResourceGroup)..." -ForegroundColor Cyan
    foreach ($role in $resourceGroupRoles) {
        Assign-Role -RoleName $role -Scope $targetScope -PrincipalId $principalObjectId
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "RBAC role assignment complete" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan

} catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# CLEANUP / OUTPUT
# ============================================================================
