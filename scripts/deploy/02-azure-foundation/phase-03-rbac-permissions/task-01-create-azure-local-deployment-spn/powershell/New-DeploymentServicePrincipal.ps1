<#
.SYNOPSIS
    Creates the Azure Local deployment service principal for automation.

.DESCRIPTION
    This script creates a dedicated service principal (SPN) for Azure Local 
    deployment automation. It creates the app registration, generates a 
    client secret, and optionally stores credentials in Key Vault.

.PARAMETER ServicePrincipalName
    The display name for the service principal. Default: sp-azurelocal-deploy

.PARAMETER KeyVaultName
    Name of the Key Vault to store credentials. If not specified, credentials
    are output to console (for manual storage).

.PARAMETER SecretValidityYears
    Number of years the client secret is valid. Default: 1

.PARAMETER SkipKeyVaultStorage
    If specified, skips storing credentials in Key Vault and outputs them.

.EXAMPLE
    .\New-DeploymentServicePrincipal.ps1 -KeyVaultName "kv-azl-prod-eus"

.EXAMPLE
    .\New-DeploymentServicePrincipal.ps1 -ServicePrincipalName "sp-azl-deploy-dev" -SkipKeyVaultStorage

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Requires:
    - Az.Resources module
    - Az.KeyVault module (if storing in Key Vault)
    - Owner or User Access Administrator role
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ServicePrincipalName = "sp-azurelocal-deploy",

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [int]$SecretValidityYears = 1,

    [switch]$SkipKeyVaultStorage
)

#Requires -Modules Az.Resources

# Script root and imports
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\common\utilities\helpers"

# Import helpers if available
if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $color = switch ($Level) {
            "INFO" { "White" }
            "WARN" { "Yellow" }
            "ERROR" { "Red" }
            "SUCCESS" { "Green" }
        }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
    }
}

try {
    Write-Log -Message "Starting Azure Local Deployment SPN Creation" -Level "INFO"
    Write-Log -Message "Service Principal Name: $ServicePrincipalName" -Level "INFO"

    # Get current context
    $context = Get-AzContext
    $tenantId = $context.Tenant.Id
    Write-Log -Message "Operating in tenant: $tenantId" -Level "INFO"

    # Check if SPN already exists
    $existingSp = Get-AzADServicePrincipal -DisplayName $ServicePrincipalName -ErrorAction SilentlyContinue
    if ($existingSp) {
        Write-Log -Message "Service principal '$ServicePrincipalName' already exists (App ID: $($existingSp.AppId))" -Level "WARN"
        $useExisting = Read-Host "Do you want to create a new secret for the existing SPN? (y/n)"
        
        if ($useExisting -ne 'y') {
            Write-Log -Message "Operation cancelled by user" -Level "INFO"
            exit 0
        }
        
        $appId = $existingSp.AppId
        $objectId = $existingSp.Id
    }
    else {
        # Create new service principal
        Write-Log -Message "Creating new service principal..." -Level "INFO"
        
        $sp = New-AzADServicePrincipal -DisplayName $ServicePrincipalName
        
        $appId = $sp.AppId
        $objectId = $sp.Id
        
        Write-Log -Message "Service principal created successfully" -Level "SUCCESS"
    }

    # Create client secret
    Write-Log -Message "Creating client secret (valid for $SecretValidityYears year(s))..." -Level "INFO"
    
    $endDate = (Get-Date).AddYears($SecretValidityYears)
    $credential = New-AzADAppCredential -ApplicationId $appId -EndDate $endDate
    
    $secretValue = $credential.SecretText
    
    if (-not $secretValue) {
        Write-Log -Message "Failed to retrieve secret value. This may be a permissions issue." -Level "ERROR"
        exit 1
    }

    Write-Log -Message "Client secret created successfully" -Level "SUCCESS"
    Write-Log -Message "Secret expires: $endDate" -Level "INFO"

    # Store in Key Vault or output
    if ($KeyVaultName -and -not $SkipKeyVaultStorage) {
        Write-Log -Message "Storing credentials in Key Vault: $KeyVaultName" -Level "INFO"
        
        # Import Az.KeyVault if not loaded
        if (-not (Get-Module Az.KeyVault)) {
            Import-Module Az.KeyVault -ErrorAction Stop
        }

        # Verify Key Vault exists
        $kv = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
        if (-not $kv) {
            Write-Log -Message "Key Vault '$KeyVaultName' not found" -Level "ERROR"
            exit 1
        }

        # Store secrets
        $secretNames = @{
            "$ServicePrincipalName-appid"    = $appId
            "$ServicePrincipalName-secret"   = $secretValue
            "$ServicePrincipalName-tenantid" = $tenantId
            "$ServicePrincipalName-objectid" = $objectId
        }

        foreach ($secretName in $secretNames.Keys) {
            $secretVal = ConvertTo-SecureString -String $secretNames[$secretName] -AsPlainText -Force
            Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -SecretValue $secretVal | Out-Null
            Write-Log -Message "  Stored secret: $secretName" -Level "INFO"
        }

        Write-Log -Message "All credentials stored in Key Vault" -Level "SUCCESS"
    }
    else {
        # Output credentials (for manual storage)
        Write-Host ""
        Write-Host "======================================================" -ForegroundColor Yellow
        Write-Host "  SERVICE PRINCIPAL CREDENTIALS" -ForegroundColor Yellow
        Write-Host "  COPY THESE VALUES IMMEDIATELY - SECRET IS SHOWN ONCE" -ForegroundColor Red
        Write-Host "======================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Display Name:    $ServicePrincipalName" -ForegroundColor Cyan
        Write-Host "Application ID:  $appId" -ForegroundColor Cyan
        Write-Host "Object ID:       $objectId" -ForegroundColor Cyan
        Write-Host "Tenant ID:       $tenantId" -ForegroundColor Cyan
        Write-Host "Client Secret:   $secretValue" -ForegroundColor Cyan
        Write-Host "Secret Expires:  $endDate" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "======================================================" -ForegroundColor Yellow
    }

    # Output result object
    $result = [PSCustomObject]@{
        ServicePrincipalName = $ServicePrincipalName
        ApplicationId        = $appId
        ObjectId             = $objectId
        TenantId             = $tenantId
        SecretExpiry         = $endDate
        KeyVaultStored       = ($KeyVaultName -and -not $SkipKeyVaultStorage)
    }

    Write-Log -Message "Service principal creation completed successfully" -Level "SUCCESS"
    
    return $result
}
catch {
    Write-Log -Message "Failed to create service principal: $_" -Level "ERROR"
    throw
}
