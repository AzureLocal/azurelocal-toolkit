<#
.SYNOPSIS
    Creates a service principal for Azure Arc server onboarding.

.DESCRIPTION
    Creates a service principal with the required permissions for onboarding 
    servers to Azure Arc. The service principal credentials are automatically 
    stored in the platform Key Vault from the solution configuration.

    Required Azure Roles:
    - Azure Connected Machine Onboarding
    - Azure Connected Machine Resource Administrator (optional, for management)

.PARAMETER Solution
    The solution name. Defaults to "azure-arc-servers".

.PARAMETER SpNameSuffix
    Optional suffix for the service principal name.

.PARAMETER IncludeResourceAdminRole
    If specified, also assigns Azure Connected Machine Resource Administrator role.

.PARAMETER CredentialValidityDays
    Number of days the credential is valid. Defaults to 365.

.EXAMPLE
    # Create Arc onboarding SP using defaults
    .\New-ArcOnboardingSP.ps1

.EXAMPLE
    # Create SP with management capabilities
    .\New-ArcOnboardingSP.ps1 -IncludeResourceAdminRole

.EXAMPLE
    # Create SP for a different solution
    .\New-ArcOnboardingSP.ps1 -Solution "azure-local"

.NOTES
    Requires:
    - Az.Resources module
    - Az.KeyVault module
    - Contributor or higher on target subscription
    - Application Administrator in Azure AD
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution = "azure-arc-servers",

    [Parameter(Mandatory = $false)]
    [string]$SpNameSuffix,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeResourceAdminRole,

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

# Get Arc-specific resource group if defined
$arcResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.arc.name'
if (-not $arcResourceGroup) {
    $arcResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.compute.name'
}

# Build service principal name
$spBaseName = "sp-arc-onboarding"
if ($SpNameSuffix) {
    $spName = "$spBaseName-$SpNameSuffix"
} else {
    $spName = "$spBaseName-$solutionName"
}

Write-Host "  Solution: $solutionName" -ForegroundColor Gray
Write-Host "  Tenant ID: $tenantId" -ForegroundColor Gray
Write-Host "  Subscription ID: $subscriptionId" -ForegroundColor Gray
Write-Host "  Service Principal Name: $spName" -ForegroundColor Gray
Write-Host "  Arc Resource Group: $arcResourceGroup" -ForegroundColor Gray

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

# Determine scope - resource group if available, otherwise subscription
if ($arcResourceGroup) {
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$arcResourceGroup"
    Write-Host "  Scope: Resource Group ($arcResourceGroup)" -ForegroundColor Gray
} else {
    $scope = "/subscriptions/$subscriptionId"
    Write-Host "  Scope: Subscription" -ForegroundColor Gray
}

# Build list of roles to assign
$rolesToAssign = @(
    "Azure Connected Machine Onboarding"
)

if ($IncludeResourceAdminRole) {
    $rolesToAssign += "Azure Connected Machine Resource Administrator"
}

foreach ($role in $rolesToAssign) {
    $existingAssignment = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $role -Scope $scope -ErrorAction SilentlyContinue
    
    if (-not $existingAssignment) {
        if ($PSCmdlet.ShouldProcess("$role on $scope", "Assign role")) {
            New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $role -Scope $scope | Out-Null
            Write-Host "  Assigned: $role" -ForegroundColor Green
        }
    } else {
        Write-Host "  Already assigned: $role" -ForegroundColor Yellow
    }
}

# ============================================================================
# STORE CREDENTIALS IN KEY VAULT
# ============================================================================
Write-Host "`n[5/5] Storing credentials in Key Vault..." -ForegroundColor Cyan

$kvName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.key_vaults.platform.name'

if ($kvName) {
    if ($PSCmdlet.ShouldProcess($kvName, "Store service principal credentials")) {
        $kvUris = Set-ServicePrincipalToKeyVault -Config $config -SpName $spName -AppId $appId -Secret $secretText -ExpiresInDays $CredentialValidityDays
        Write-Host "  Stored App ID: $($kvUris.AppIdUri)" -ForegroundColor Green
        Write-Host "  Stored Secret: $($kvUris.SecretUri)" -ForegroundColor Green
    }
} else {
    Write-Warning "No Key Vault configured. Credentials will be output only."
    $kvUris = @{
        AppIdUri = "NOT STORED"
        SecretUri = "NOT STORED"
    }
}

# ============================================================================
# OUTPUT
# ============================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Arc Onboarding SP Created Successfully" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Service Principal Name: $spName"
Write-Host "Application (Client) ID: $appId"
Write-Host "Tenant ID: $tenantId"
Write-Host ""

# Generate onboarding script snippet
Write-Host "Use in Arc onboarding script:" -ForegroundColor Yellow
Write-Host '  $servicePrincipalId = "' + $appId + '"'
Write-Host '  $servicePrincipalSecret = Get-SecretFromConfig -Config $config -SecretName "' + $kvUris.SecretName + '" -AsPlainText'
Write-Host ''
Write-Host "Or use the azcmagent connect command:" -ForegroundColor Yellow
Write-Host "  azcmagent connect --service-principal-id `"$appId`" --service-principal-secret `"<secret>`" --tenant-id `"$tenantId`" --subscription-id `"$subscriptionId`" --resource-group `"$arcResourceGroup`" --location `"<location>`""
Write-Host ""

if ($kvName) {
    Write-Host "Credentials stored in Key Vault:" -ForegroundColor Yellow
    Write-Host "  App ID: $($kvUris.AppIdUri)"
    Write-Host "  Secret: $($kvUris.SecretUri)"
}

Write-Host ""

# Return object for pipeline usage
return [PSCustomObject]@{
    ServicePrincipalName = $spName
    ApplicationId        = $appId
    TenantId             = $tenantId
    SubscriptionId       = $subscriptionId
    ResourceGroup        = $arcResourceGroup
    AppIdKeyVaultUri     = $kvUris.AppIdUri
    SecretKeyVaultUri    = $kvUris.SecretUri
    RolesAssigned        = $rolesToAssign
    ValidUntil           = (Get-Date).AddDays($CredentialValidityDays)
}
