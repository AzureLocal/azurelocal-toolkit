<#
.SYNOPSIS
    Deploys Key Vault for platform secrets in Security subscription.

.DESCRIPTION
    This script creates:
    - Resource Group in Security subscription
    - Key Vault with RBAC authorization
    - RBAC Assignment for Key Vault Administrator
    
    Follows CAF/WAF Landing Zone principles - Key Vault deploys to Security subscription.

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers"

.PARAMETER SecuritySubscriptionId
    Security subscription ID.

.PARAMETER ResourceGroup
    Resource group name.

.PARAMETER KeyVaultName
    Key Vault name.

.PARAMETER Location
    Azure region.

.PARAMETER UserObjectId
    User Object ID for Key Vault Administrator role.

.EXAMPLE
    # Using solution configuration
    .\Deploy-KeyVault.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Deploy-KeyVault.ps1 -SecuritySubscriptionId "your-sub-id" -KeyVaultName "kv-platform"
    
.EXAMPLE
    .\Deploy-KeyVault.ps1 -Solution "azure-local" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$SecuritySubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$UserObjectId
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
if ($Solution) {
    Write-Host "[Config] Loading solution configuration for: $Solution" -ForegroundColor Cyan
    . "$PSScriptRoot\..\..\..\utilities\helpers\config-loader.ps1"
    $config = Get-SolutionConfig -Solution $Solution
    
    # Map config values to script parameters - only if not explicitly provided
    if (-not $SecuritySubscriptionId) { $SecuritySubscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscriptions.security.id' }
    if (-not $ResourceGroup) { $ResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.security.name' }
    if (-not $KeyVaultName) { $KeyVaultName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.key_vaults.platform.name' }
    if (-not $Location) { $Location = Get-ConfigValue -Config $config -Path 'azure.location' }
    if (-not $UserObjectId) { $UserObjectId = Get-ConfigValue -Config $config -Path 'azure_infrastructure.key_vaults.platform.admin_object_id' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $SecuritySubscriptionId) { $missingParams += 'SecuritySubscriptionId' }
if (-not $ResourceGroup) { $missingParams += 'ResourceGroup' }
if (-not $KeyVaultName) { $missingParams += 'KeyVaultName' }
if (-not $Location) { $missingParams += 'Location' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

Write-Host "=== Key Vault Deployment (Security Subscription) ===" -ForegroundColor Cyan
Write-Host "Subscription: $SecuritySubscriptionId" -ForegroundColor Gray
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "Key Vault: $KeyVaultName" -ForegroundColor Gray
Write-Host "Location: $Location" -ForegroundColor Gray
Write-Host "User Object ID: $UserObjectId" -ForegroundColor Gray
Write-Host ""

# Set subscription context
Write-Host "[1/4] Setting subscription context to Security subscription..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($SecuritySubscriptionId, "Set Azure context")) {
    Set-AzContext -SubscriptionId $SecuritySubscriptionId | Out-Null
    $currentContext = Get-AzContext
    if ($currentContext.Subscription.Id -ne $SecuritySubscriptionId) {
        throw "Failed to set subscription context to $SecuritySubscriptionId"
    }
    Write-Host "✓ Context set to: $($currentContext.Subscription.Name)" -ForegroundColor Green
}

# Create Resource Group
Write-Host "[2/4] Creating resource group..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($ResourceGroup, "Create Resource Group")) {
    $rg = Get-AzResourceGroup -Name $ResourceGroup -Location $Location -ErrorAction SilentlyContinue
    if (-not $rg) {
        New-AzResourceGroup -Name $ResourceGroup -Location $Location -Tag @{
            "Environment" = "Production"
            "Purpose" = "Security"
            "ManagedBy" = "PowerShell"
            "Subscription" = "local-security-001"
        } | Out-Null
        Write-Host "✓ Resource group created: $ResourceGroup" -ForegroundColor Green
    } else {
        Write-Host "✓ Resource group already exists: $ResourceGroup" -ForegroundColor Green
    }
}

# Create Key Vault
Write-Host "[3/4] Creating Key Vault with RBAC authorization..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($KeyVaultName, "Create Key Vault")) {
    $kv = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
    if (-not $kv) {
        New-AzKeyVault -Name $KeyVaultName `
            -ResourceGroupName $ResourceGroup `
            -Location $Location `
            -EnableRbacAuthorization `
            -SoftDeleteRetentionInDays 90 `
            -EnablePurgeProtection `
            -Tag @{
                "Environment" = "Production"
                "Purpose" = "Platform Secrets"
                "ManagedBy" = "PowerShell"
            } | Out-Null
        Write-Host "✓ Key Vault created: $KeyVaultName" -ForegroundColor Green
        Write-Host "  - RBAC Authorization: Enabled" -ForegroundColor Gray
        Write-Host "  - Soft Delete: 90 days" -ForegroundColor Gray
        Write-Host "  - Purge Protection: Enabled" -ForegroundColor Gray
    } else {
        Write-Host "✓ Key Vault already exists: $KeyVaultName" -ForegroundColor Green
    }
}

# Assign Key Vault Administrator role
Write-Host "[4/4] Assigning Key Vault Administrator role..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($UserObjectId, "Assign Key Vault Administrator")) {
    $kv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroup
    $kvScope = $kv.ResourceId
    
    # Check if role assignment already exists
    $existingAssignment = Get-AzRoleAssignment -ObjectId $UserObjectId `
        -RoleDefinitionName "Key Vault Administrator" `
        -Scope $kvScope `
        -ErrorAction SilentlyContinue
    
    if (-not $existingAssignment) {
        New-AzRoleAssignment -ObjectId $UserObjectId `
            -RoleDefinitionName "Key Vault Administrator" `
            -Scope $kvScope | Out-Null
        Write-Host "✓ Role assigned: Key Vault Administrator" -ForegroundColor Green
        Write-Host "  - Principal: $UserObjectId" -ForegroundColor Gray
    } else {
        Write-Host "✓ Role already assigned: Key Vault Administrator" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Key Vault Deployment Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Key Vault Details:" -ForegroundColor Cyan
Write-Host "  Name: $KeyVaultName" -ForegroundColor Gray
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Subscription: local-security-001" -ForegroundColor Gray
Write-Host "  Vault URI: https://$KeyVaultName.vault.azure.net/" -ForegroundColor Gray
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Store admin credentials in Key Vault" -ForegroundColor Yellow
Write-Host "     `$secret = ConvertTo-SecureString '!!AzureLocal2025!!' -AsPlainText -Force" -ForegroundColor Gray
Write-Host "     Set-AzKeyVaultSecret -VaultName '$KeyVaultName' -Name 'admin-password' -SecretValue `$secret" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Store domain admin credentials" -ForegroundColor Yellow
Write-Host "     Set-AzKeyVaultSecret -VaultName '$KeyVaultName' -Name 'domain-admin-password' -SecretValue `$secret" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Deploy infrastructure VMs (Phase 2)" -ForegroundColor Yellow
Write-Host ""
