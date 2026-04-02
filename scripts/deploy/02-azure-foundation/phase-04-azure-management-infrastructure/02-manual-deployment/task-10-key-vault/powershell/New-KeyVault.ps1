<#
.SYNOPSIS
    Creates an Azure Key Vault for Azure Local deployment secrets.

.DESCRIPTION
    This script creates an Azure Key Vault configured for Azure Local deployment
    with proper RBAC access policies, soft delete, and purge protection enabled.

.PARAMETER KeyVaultName
    Name of the Key Vault to create.

.PARAMETER ResourceGroupName
    Name of the resource group where Key Vault will be created.

.PARAMETER Location
    Azure region for deployment. Default: eastus

.PARAMETER Sku
    Key Vault SKU. Default: Premium

.PARAMETER EnableRbacAuthorization
    Use RBAC for authorization instead of access policies. Default: true

.EXAMPLE
    .\New-KeyVault.ps1 -KeyVaultName "kv-azl-prd-eus" -ResourceGroupName "rg-azlmgmt-prd-eus-01"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Standard", "Premium")]
    [string]$Sku = "Premium",

    [Parameter(Mandatory = $false)]
    [bool]$EnableRbacAuthorization = $true,

    [Parameter(Mandatory = $false)]
    [int]$SoftDeleteRetentionDays = 90,

    [Parameter(Mandatory = $false)]
    [hashtable]$Tags = @{}
)

#Requires -Modules Az.KeyVault

# Import logging helper
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\common\utilities\helpers"

if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $color = switch ($Level) {
            "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }
        }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
    }
}

try {
    Write-Log -Message "Starting Key Vault Creation" -Level "INFO"
    Write-Log -Message "Key Vault Name: $KeyVaultName" -Level "INFO"

    # Check if Key Vault already exists
    $existingKv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($existingKv) {
        Write-Log -Message "Key Vault '$KeyVaultName' already exists" -Level "WARN"
        return $existingKv
    }

    # Check for soft-deleted vault with same name
    $deletedKv = Get-AzKeyVault -VaultName $KeyVaultName -Location $Location -InRemovedState -ErrorAction SilentlyContinue
    if ($deletedKv) {
        Write-Log -Message "Found soft-deleted vault with name '$KeyVaultName'" -Level "WARN"
        $recover = Read-Host "Do you want to recover the deleted vault? (y/n)"
        if ($recover -eq 'y') {
            Undo-AzKeyVaultRemoval -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -Location $Location
            Write-Log -Message "Key Vault recovered successfully" -Level "SUCCESS"
            return Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName
        }
    }

    # Build tags
    $defaultTags = @{
        "Environment"  = "Production"
        "Application"  = "Azure Local"
        "ManagedBy"    = "Azure Local Cloud"
        "CreatedDate"  = (Get-Date -Format "yyyy-MM-dd")
    }
    $allTags = $defaultTags + $Tags

    # Create Key Vault
    Write-Log -Message "Creating Key Vault with the following settings:" -Level "INFO"
    Write-Log -Message "  Location: $Location" -Level "INFO"
    Write-Log -Message "  SKU: $Sku" -Level "INFO"
    Write-Log -Message "  RBAC Authorization: $EnableRbacAuthorization" -Level "INFO"
    Write-Log -Message "  Soft Delete Retention: $SoftDeleteRetentionDays days" -Level "INFO"

    $kvParams = @{
        Name                         = $KeyVaultName
        ResourceGroupName            = $ResourceGroupName
        Location                     = $Location
        Sku                          = $Sku
        EnableRbacAuthorization      = $EnableRbacAuthorization
        EnableSoftDelete             = $true
        SoftDeleteRetentionInDays    = $SoftDeleteRetentionDays
        EnablePurgeProtection        = $true
        Tag                          = $allTags
    }

    $kv = New-AzKeyVault @kvParams

    Write-Log -Message "Key Vault created successfully" -Level "SUCCESS"

    # Output details
    Write-Host ""
    Write-Log -Message "Key Vault Details:" -Level "INFO"
    Write-Host "  Name: $($kv.VaultName)"
    Write-Host "  URI: $($kv.VaultUri)"
    Write-Host "  Resource Group: $ResourceGroupName"
    Write-Host "  Location: $($kv.Location)"
    Write-Host "  SKU: $Sku"

    if ($EnableRbacAuthorization) {
        Write-Host ""
        Write-Log -Message "RBAC authorization is enabled. Assign roles to grant access:" -Level "INFO"
        Write-Host "  - Key Vault Administrator: Full access"
        Write-Host "  - Key Vault Secrets User: Read secrets"
        Write-Host "  - Key Vault Secrets Officer: Manage secrets"
    }

    return $kv
}
catch {
    Write-Log -Message "Failed to create Key Vault: $_" -Level "ERROR"
    throw
}
