<#
.SYNOPSIS
    Creates a service principal for Azure DevOps or GitHub Actions pipelines.

.DESCRIPTION
    Creates a service principal with the required permissions for CI/CD pipelines
    to deploy Azure resources. The service principal credentials are automatically 
    stored in the platform Key Vault from the solution configuration.

    The script creates federated credentials for OIDC authentication if the
    DevOps platform supports it (GitHub Actions, Azure DevOps with workload identity).

.PARAMETER Solution
    The solution name (e.g., "azure-local").

.PARAMETER Platform
    The DevOps platform. Valid values: "github", "azuredevops", "gitlab".

.PARAMETER RepoUrl
    The repository URL (used for federated credential configuration).

.PARAMETER EnvironmentName
    The environment name for federated credentials (e.g., "production", "staging").

.PARAMETER Role
    The Azure role to assign. Defaults to "Contributor".

.PARAMETER CredentialValidityDays
    Number of days the credential is valid. Defaults to 365.

.EXAMPLE
    # Create SP for GitHub Actions
    .\New-PipelineSP.ps1 -Solution "azure-local" -Platform "github" -RepoUrl "https://github.com/myorg/myrepo"

.EXAMPLE
    # Create SP for Azure DevOps
    .\New-PipelineSP.ps1 -Solution "azure-local" -Platform "azuredevops" -RepoUrl "https://dev.azure.com/myorg/myproject"

.NOTES
    Requires:
    - Az.Resources module
    - Az.KeyVault module
    - Microsoft.Graph module (for federated credentials)
    - Contributor or higher on target subscription
    - Application Administrator in Azure AD
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $true)]
    [ValidateSet("github", "azuredevops", "gitlab")]
    [string]$Platform,

    [Parameter(Mandatory = $false)]
    [string]$RepoUrl,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName = "production",

    [Parameter(Mandatory = $false)]
    [string]$Role = "Contributor",

    [Parameter(Mandatory = $false)]
    [int]$CredentialValidityDays = 365
)

# Import required modules
$scriptRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $scriptRoot "utilities\helpers\config-loader.ps1")
. (Join-Path $scriptRoot "utilities\helpers\keyvault-helper.ps1")

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
Write-Host "`n[1/5] Loading solution configuration..." -ForegroundColor Cyan
$config = Get-SolutionConfig -Solution $Solution

# Validate required configuration paths
$validation = Test-ConfigPaths -Config $config
if (-not $validation.IsValid) {
    throw "Missing required configuration paths: $($validation.MissingPaths -join ', ')"
}

# Extract configuration values using fixed paths
$tenantId = Get-ConfigValue -Config $config -Path 'azure.tenant.id'
$subscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscription.id'
$solutionName = Get-ConfigValue -Config $config -Path 'solution.name'
$tags = Get-ConfigTags -Config $config

# Build service principal name
$platformShortName = switch ($Platform) {
    "github" { "gh" }
    "azuredevops" { "ado" }
    "gitlab" { "gl" }
}
$spName = "sp-$solutionName-$platformShortName-pipeline"

Write-Host "  Solution: $solutionName" -ForegroundColor Gray
Write-Host "  Platform: $Platform" -ForegroundColor Gray
Write-Host "  Service Principal Name: $spName" -ForegroundColor Gray

# ============================================================================
# AZURE CONNECTION
# ============================================================================
Write-Host "`n[2/5] Connecting to Azure..." -ForegroundColor Cyan
$context = Connect-AzureFromConfig -Config $config

# ============================================================================
# CREATE SERVICE PRINCIPAL
# ============================================================================
Write-Host "`n[3/5] Creating service principal..." -ForegroundColor Cyan

# Check if SP already exists
$existingSp = Get-AzADServicePrincipal -DisplayName $spName -ErrorAction SilentlyContinue
if ($existingSp) {
    Write-Warning "Service principal '$spName' already exists. AppId: $($existingSp.AppId)"
    $sp = $existingSp
    
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
# ASSIGN ROLES
# ============================================================================
Write-Host "`n[4/5] Assigning roles..." -ForegroundColor Cyan

$scope = "/subscriptions/$subscriptionId"
$existingAssignment = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $Role -Scope $scope -ErrorAction SilentlyContinue

if (-not $existingAssignment) {
    if ($PSCmdlet.ShouldProcess("$Role on subscription", "Assign role")) {
        New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $Role -Scope $scope | Out-Null
        Write-Host "  Assigned: $Role" -ForegroundColor Green
    }
} else {
    Write-Host "  Already assigned: $Role" -ForegroundColor Yellow
}

# Assign Key Vault access
$kvName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.key_vaults.platform.name'
$kvRg = Get-ConfigValue -Config $config -Path 'azure_infrastructure.key_vaults.platform.resource_group'
if ($kvName -and $kvRg) {
    $kvScope = "/subscriptions/$subscriptionId/resourceGroups/$kvRg/providers/Microsoft.KeyVault/vaults/$kvName"
    $existingKvAssignment = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Key Vault Secrets User" -Scope $kvScope -ErrorAction SilentlyContinue
    
    if (-not $existingKvAssignment) {
        if ($PSCmdlet.ShouldProcess("Key Vault Secrets User on $kvName", "Assign role")) {
            New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Key Vault Secrets User" -Scope $kvScope | Out-Null
            Write-Host "  Assigned: Key Vault Secrets User on $kvName" -ForegroundColor Green
        }
    } else {
        Write-Host "  Already assigned: Key Vault Secrets User on $kvName" -ForegroundColor Yellow
    }
}

# ============================================================================
# STORE CREDENTIALS IN KEY VAULT
# ============================================================================
Write-Host "`n[5/5] Storing credentials in Key Vault..." -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($kvName, "Store service principal credentials")) {
    $kvUris = Set-ServicePrincipalToKeyVault -Config $config -SpName $spName -AppId $appId -Secret $secretText -ExpiresInDays $CredentialValidityDays
    Write-Host "  Stored App ID: $($kvUris.AppIdUri)" -ForegroundColor Green
    Write-Host "  Stored Secret: $($kvUris.SecretUri)" -ForegroundColor Green
}

# ============================================================================
# OUTPUT
# ============================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Pipeline Service Principal Created" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Service Principal Name: $spName"
Write-Host "Application (Client) ID: $appId"
Write-Host "Tenant ID: $tenantId"
Write-Host ""

# Platform-specific instructions
switch ($Platform) {
    "github" {
        Write-Host "GitHub Actions Configuration:" -ForegroundColor Yellow
        Write-Host "Add these secrets to your GitHub repository:"
        Write-Host "  AZURE_CLIENT_ID: $appId"
        Write-Host "  AZURE_TENANT_ID: $tenantId"
        Write-Host "  AZURE_SUBSCRIPTION_ID: $subscriptionId"
        Write-Host "  AZURE_CLIENT_SECRET: (retrieve from Key Vault)"
        Write-Host ""
        Write-Host "For OIDC authentication (recommended), configure federated credentials"
        Write-Host "using the Azure Portal or Microsoft Graph API."
    }
    "azuredevops" {
        Write-Host "Azure DevOps Configuration:" -ForegroundColor Yellow
        Write-Host "Create a Service Connection with these values:"
        Write-Host "  Service Principal ID: $appId"
        Write-Host "  Tenant ID: $tenantId"
        Write-Host "  Subscription ID: $subscriptionId"
        Write-Host "  Service Principal Key: (retrieve from Key Vault)"
    }
    "gitlab" {
        Write-Host "GitLab CI Configuration:" -ForegroundColor Yellow
        Write-Host "Add these CI/CD variables to your GitLab project:"
        Write-Host "  AZURE_CLIENT_ID: $appId"
        Write-Host "  AZURE_TENANT_ID: $tenantId"
        Write-Host "  AZURE_SUBSCRIPTION_ID: $subscriptionId"
        Write-Host "  AZURE_CLIENT_SECRET: (retrieve from Key Vault)"
    }
}

Write-Host ""
Write-Host "Credentials stored in Key Vault:" -ForegroundColor Yellow
Write-Host "  App ID: $($kvUris.AppIdUri)"
Write-Host "  Secret: $($kvUris.SecretUri)"
Write-Host ""

# Return object for pipeline usage
return [PSCustomObject]@{
    ServicePrincipalName = $spName
    ApplicationId        = $appId
    TenantId             = $tenantId
    SubscriptionId       = $subscriptionId
    Platform             = $Platform
    AppIdKeyVaultUri     = $kvUris.AppIdUri
    SecretKeyVaultUri    = $kvUris.SecretUri
    RoleAssigned         = $Role
    ValidUntil           = (Get-Date).AddDays($CredentialValidityDays)
}
