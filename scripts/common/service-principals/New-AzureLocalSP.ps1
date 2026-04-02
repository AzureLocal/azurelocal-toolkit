<#
.SYNOPSIS
    Creates an Azure Local deployment service principal.

.DESCRIPTION
    Creates a service principal with the required permissions for Azure Local 
    cluster deployment. The service principal credentials are automatically 
    stored in the platform Key Vault from the solution configuration.

    Required Azure Roles (assigned at subscription level):
    - Azure Stack HCI Administrator
    - Reader
    - Key Vault Secrets User (on platform Key Vault)

.PARAMETER Solution
    The solution name. Defaults to "azure-local".

.PARAMETER SpNameSuffix
    Optional suffix for the service principal name. 
    Full name will be: sp-<solution>-deploy-<suffix>

.PARAMETER RoleAssignmentScope
    Scope for role assignment. Defaults to subscription level.

.PARAMETER CredentialValidityDays
    Number of days the credential is valid. Defaults to 365.

.EXAMPLE


.EXAMPLE
    # Create SP with custom name suffix
    .\New-AzureLocalSP.ps1 -SpNameSuffix "prod-cluster1"

.NOTES
    Requires:
    - Az.Resources module
    - Az.KeyVault module
    - Contributor or higher on target subscription
    - Application Administrator or Cloud Application Administrator in Azure AD
#>

[CmdletBinding(SupportsShouldProcess)]

[CmdletBinding(SupportsShouldProcess)]

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution = "azure-local",

    [Parameter(Mandatory = $false)]
    [string]$SpNameSuffix,

    [Parameter(Mandatory = $false)]
    [string]$RoleAssignmentScope,

    [Parameter(Mandatory = $false)]
    [int]$CredentialValidityDays = 365,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath
)




# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

Write-Host "`n[1/5] Loading infrastructure configuration..." -ForegroundColor Cyan
# Allow config path override, otherwise use default relative path
if ($ConfigPath) {
    $infraConfigPath = $ConfigPath
} else {
    $infraConfigPath = Join-Path $PSScriptRoot "..\..\..\configs\infrastructure.yml"
}
if (!(Test-Path $infraConfigPath)) {
    throw "infrastructure.yml not found at $infraConfigPath"
}
# Load YAML directly (requires powershell-yaml module)
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
     throw "powershell-yaml module not found. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml -ErrorAction Stop
$content = Get-Content -Path $infraConfigPath -Raw
$config = ConvertFrom-Yaml $content -Ordered





# Robust extraction with null checks
if ($config.Contains("azure") -and $config["azure"].Contains("tenant") -and $config["azure"]["tenant"].Contains("id")) {
    $tenantId = $config["azure"]["tenant"]["id"]
} else {
    throw "[ERROR] 'azure.tenant.id' not found in infrastructure.yml."
}
if ($config["azure"].Contains("subscriptions") -and $config["azure"]["subscriptions"].Contains("demo") -and $config["azure"]["subscriptions"]["demo"].Contains("id")) {
    $subscriptionId = $config["azure"]["subscriptions"]["demo"]["id"]
} else {
    throw "[ERROR] 'azure.subscriptions.demo.id' not found in infrastructure.yml."
}
if ($config.Contains("site") -and $config["site"].Contains("name")) {
    $siteName = $config["site"]["name"]
} else {
    $siteName = ""
}
if ($config.Contains("azure_resources") -and $config["azure_resources"].Contains("tags")) {
    $tags = $config["azure_resources"]["tags"]
} else {
    $tags = @{}
}


### Use deployment SPN name from config (infrastructure.yml only)
Write-Host "[DEBUG] identity.service_principal section:" -ForegroundColor Yellow
if ($config["identity"] -and $config["identity"].Contains("service_principal")) {
    $config["identity"]["service_principal"] | ConvertTo-Json -Depth 5 | Write-Host
}

$spName = $null
if (
    $config.Contains("identity") -and
    $config["identity"].Contains("service_principal") -and
    $config["identity"]["service_principal"].Contains("name")
) {
    $spName = $config["identity"]["service_principal"]["name"]
}
if (-not $spName) {
    throw "[ERROR] 'identity.service_principal.name' not found in infrastructure.yml."
}

# Set role assignment scope if not provided
if (-not $RoleAssignmentScope) {
    $RoleAssignmentScope = "/subscriptions/$subscriptionId"
}

Write-Host "  Solution: $solutionName" -ForegroundColor Gray
Write-Host "  Tenant ID: $tenantId" -ForegroundColor Gray
Write-Host "  Subscription ID: $subscriptionId" -ForegroundColor Gray
Write-Host "  Service Principal Name: $spName" -ForegroundColor Gray

# ============================================================================
# AZURE CONNECTION
# ============================================================================
Write-Host "`n[2/5] Using existing Azure session/context..." -ForegroundColor Cyan

# ============================================================================
# CREATE SERVICE PRINCIPAL (ONLY)
# ============================================================================
Write-Host "`n[3/4] Creating service principal..." -ForegroundColor Cyan

# Check if SP already exists
$existingSp = Get-AzADServicePrincipal -DisplayName $spName -ErrorAction SilentlyContinue
if ($existingSp) {
    Write-Warning "Service principal '$spName' already exists. AppId: $($existingSp.AppId)"
    if ($PSCmdlet.ShouldProcess($spName, "Create new credential for existing service principal")) {
        # Create new credential for existing SP
        $credential = New-AzADSpCredential -ObjectId $existingSp.Id -EndDate (Get-Date).AddDays($CredentialValidityDays)
        $appId = $existingSp.AppId
        $secretText = $credential.SecretText
        Write-Host "  Created new credential for existing SP" -ForegroundColor Green
    }
} else {
    if ($PSCmdlet.ShouldProcess($spName, "Create new service principal")) {
        # Create new service principal
        $sp = New-AzADServicePrincipal -DisplayName $spName -EndDate (Get-Date).AddDays($CredentialValidityDays)
        $appId = $sp.AppId
        $secretText = $sp.PasswordCredentials.SecretText
        Write-Host "  Created service principal: $spName" -ForegroundColor Green
        Write-Host "  Application ID: $appId" -ForegroundColor Gray
    }
}

# ============================================================================
# STORE CREDENTIALS IN KEY VAULT
# ============================================================================
Write-Host "`n[4/4] Storing credentials in Key Vault..." -ForegroundColor Cyan

# Always extract platform Key Vault info before storing
$kvName = $null
$kvRg = $null
if ($config.Contains("platform")) {
    if ($config["platform"].Contains("kv_platform_name")) {
        $kvName = $config["platform"]["kv_platform_name"]
    }
    if ($config["platform"].Contains("kv_platform_resource_group")) {
        $kvRg = $config["platform"]["kv_platform_resource_group"]
    }
}

$kvUris = @{}
if ($kvName -and $kvRg -and $appId -and $secretText) {
    if ($PSCmdlet.ShouldProcess($kvName, "Store service principal credentials")) {
        # Store AppId and Secret as separate secrets in Key Vault
        $appIdSecretName = "$spName-appid"
        $secretSecretName = "$spName-secret"
        # Use Azure CLI as workaround for PowerShell Forbidden error
        $appIdSecretJson = az keyvault secret set --vault-name $kvName --name $appIdSecretName --value $appId | ConvertFrom-Json
        $secretSecretJson = az keyvault secret set --vault-name $kvName --name $secretSecretName --value $secretText | ConvertFrom-Json
        $kvUris.AppIdUri = $appIdSecretJson.id
        $kvUris.SecretUri = $secretSecretJson.id
        Write-Host "  Stored App ID: $($kvUris.AppIdUri) [via az cli]" -ForegroundColor Green
        Write-Host "  Stored Secret: $($kvUris.SecretUri) [via az cli]" -ForegroundColor Green
    }
} else {
    Write-Warning "Key Vault name/resource group, AppId, or Secret missing. Skipping Key Vault storage."
    $kvUris.AppIdUri = ""
    $kvUris.SecretUri = ""
}

# ============================================================================
# OUTPUT
# ============================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Service Principal Created Successfully" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Service Principal Name: $spName"
Write-Host "Application (Client) ID: $appId"
Write-Host "Tenant ID: $tenantId"
Write-Host ""
Write-Host "Credentials stored in Key Vault:" -ForegroundColor Yellow
Write-Host "  App ID Secret: $($kvUris.AppIdUri)"
Write-Host "  Client Secret: $($kvUris.SecretUri)"
Write-Host ""
# No solution.yaml. All config is in infrastructure.yml. Output Key Vault URIs for reference.
Write-Host "Update your infrastructure.yml or automation to reference these secrets:" -ForegroundColor Cyan
Write-Host "  credentials:"
Write-Host "    azure_local_sp:"
Write-Host "      app_id: `\"$($kvUris.AppIdUri)`\""
Write-Host "      secret: `\"$($kvUris.SecretUri)`\""
Write-Host ""

# Return object for pipeline usage
return [PSCustomObject]@{
    ServicePrincipalName = $spName
    ApplicationId        = $appId
    TenantId             = $tenantId
    AppIdKeyVaultUri     = $kvUris.AppIdUri
    SecretKeyVaultUri    = $kvUris.SecretUri
    RolesAssigned        = $rolesToAssign
    ValidUntil           = (Get-Date).AddDays($CredentialValidityDays)
}
