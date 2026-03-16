<#
.SYNOPSIS
    Key Vault helper functions for Microsoft Hybrid Cloud solutions.

.DESCRIPTION
    This module provides functions for working with Azure Key Vault in the context
    of solution configurations. It handles:
    - Retrieving secrets from Key Vault
    - Writing secrets to Key Vault
    - Resolving keyvault:// URI references in configuration
    - Service Principal credential management

.NOTES
    Requires:
    - Az.KeyVault module
    - Az.Accounts module (for authentication)
    - scripts/utilities/helpers/config-loader.ps1

.EXAMPLE
    # Load config and resolve secret references
    $config = Get-SolutionConfig -Solution "azure-local"
    $password = Get-SecretFromUri -Uri $config.security.credentials.local_admin_password

.EXAMPLE
    # Store a new secret
    $config = Get-SolutionConfig -Solution "azure-local"
    Set-SecretToKeyVault -Config $config -SecretName "my-secret" -SecretValue "secret-value"
#>

#Requires -Modules Az.KeyVault, Az.Accounts

# Import the config loader
$configLoaderPath = Join-Path $PSScriptRoot "config-loader.ps1"
if (Test-Path $configLoaderPath) {
    . $configLoaderPath
}

<#
.SYNOPSIS
    Parses a keyvault:// URI into its components.

.DESCRIPTION
    Parses URIs in the format: keyvault://<vault-name>/<secret-name>[/<version>]

.PARAMETER Uri
    The keyvault:// URI to parse.

.EXAMPLE
    $parsed = ConvertFrom-KeyVaultUri -Uri "keyvault://kv-platform-prod/admin-password"
    # Returns: @{ VaultName = "kv-platform-prod"; SecretName = "admin-password"; Version = $null }
#>
function ConvertFrom-KeyVaultUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    if (-not $Uri.StartsWith("keyvault://")) {
        throw "Invalid Key Vault URI. Must start with 'keyvault://'. Got: $Uri"
    }

    $path = $Uri.Substring(11)  # Remove "keyvault://"
    $parts = $path -split '/'

    if ($parts.Count -lt 2) {
        throw "Invalid Key Vault URI format. Expected: keyvault://<vault-name>/<secret-name>[/<version>]. Got: $Uri"
    }

    return @{
        VaultName  = $parts[0]
        SecretName = $parts[1]
        Version    = if ($parts.Count -gt 2) { $parts[2] } else { $null }
    }
}

<#
.SYNOPSIS
    Creates a keyvault:// URI from components.

.DESCRIPTION
    Builds a keyvault:// URI from vault name and secret name.

.PARAMETER VaultName
    The Key Vault name.

.PARAMETER SecretName
    The secret name.

.PARAMETER Version
    Optional. The secret version.

.EXAMPLE
    $uri = ConvertTo-KeyVaultUri -VaultName "kv-platform" -SecretName "admin-password"
    # Returns: "keyvault://kv-platform/admin-password"
#>
function ConvertTo-KeyVaultUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$SecretName,

        [Parameter(Mandatory = $false)]
        [string]$Version
    )

    if ($Version) {
        return "keyvault://$VaultName/$SecretName/$Version"
    }
    return "keyvault://$VaultName/$SecretName"
}

<#
.SYNOPSIS
    Checks if a value is a Key Vault URI reference.

.PARAMETER Value
    The value to check.

.EXAMPLE
    if (Test-KeyVaultUri -Value $config.security.credentials.password) {
        $password = Get-SecretFromUri -Uri $config.security.credentials.password
    }
#>
function Test-KeyVaultUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        $Value
    )

    if ($null -eq $Value) { return $false }
    if ($Value -isnot [string]) { return $false }
    return $Value.StartsWith("keyvault://")
}

<#
.SYNOPSIS
    Retrieves a secret value from Azure Key Vault using a keyvault:// URI.

.DESCRIPTION
    Parses the URI, connects to Key Vault, and retrieves the secret value.
    Returns the secret as a SecureString or plain text based on parameter.

.PARAMETER Uri
    The keyvault:// URI pointing to the secret.

.PARAMETER AsPlainText
    If specified, returns the secret as plain text instead of SecureString.

.EXAMPLE
    $password = Get-SecretFromUri -Uri "keyvault://kv-platform-prod/admin-password" -AsPlainText

.EXAMPLE
    $securePassword = Get-SecretFromUri -Uri $config.security.credentials.local_admin_password
#>
function Get-SecretFromUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [switch]$AsPlainText
    )

    # Parse the URI
    $parsed = ConvertFrom-KeyVaultUri -Uri $Uri

    # Get the secret
    $getParams = @{
        VaultName = $parsed.VaultName
        Name      = $parsed.SecretName
    }
    
    if ($parsed.Version) {
        $getParams.Version = $parsed.Version
    }

    $secret = Get-AzKeyVaultSecret @getParams

    if ($null -eq $secret) {
        throw "Secret not found: $Uri"
    }

    if ($AsPlainText) {
        return $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
    }
    
    return $secret.SecretValue
}

<#
.SYNOPSIS
    Retrieves a secret from the solution's platform Key Vault.

.DESCRIPTION
    Uses the solution configuration to find the platform Key Vault name,
    then retrieves the specified secret.

.PARAMETER Config
    The solution configuration (from Get-SolutionConfig).

.PARAMETER SecretName
    The name of the secret to retrieve.

.PARAMETER AsPlainText
    If specified, returns the secret as plain text.

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    $password = Get-SecretFromConfig -Config $config -SecretName "local-admin-password" -AsPlainText
#>
function Get-SecretFromConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$SecretName,

        [Parameter(Mandatory = $false)]
        [switch]$AsPlainText
    )

    # Get the platform Key Vault name from config
    $kvName = Get-PlatformKeyVault -Config $Config

    # Build URI and get secret
    $uri = ConvertTo-KeyVaultUri -VaultName $kvName -SecretName $SecretName
    return Get-SecretFromUri -Uri $uri -AsPlainText:$AsPlainText
}

<#
.SYNOPSIS
    Stores a secret in the solution's platform Key Vault.

.DESCRIPTION
    Uses the solution configuration to find the platform Key Vault name,
    then stores the specified secret.

.PARAMETER Config
    The solution configuration (from Get-SolutionConfig).

.PARAMETER SecretName
    The name of the secret to store.

.PARAMETER SecretValue
    The value to store (can be string or SecureString).

.PARAMETER ContentType
    Optional. Content type for the secret (e.g., "application/json", "password").

.PARAMETER Tags
    Optional. Tags to apply to the secret. If not specified, uses solution tags.

.PARAMETER ExpiresInDays
    Optional. Number of days until the secret expires.

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    Set-SecretToKeyVault -Config $config -SecretName "new-password" -SecretValue "MyP@ssw0rd!" -ExpiresInDays 365
#>
function Set-SecretToKeyVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$SecretName,

        [Parameter(Mandatory = $true)]
        $SecretValue,

        [Parameter(Mandatory = $false)]
        [string]$ContentType,

        [Parameter(Mandatory = $false)]
        [hashtable]$Tags,

        [Parameter(Mandatory = $false)]
        [int]$ExpiresInDays
    )

    # Get the platform Key Vault name from config
    $kvName = Get-PlatformKeyVault -Config $Config

    # Convert to SecureString if needed
    if ($SecretValue -is [string]) {
        $secureValue = ConvertTo-SecureString -String $SecretValue -AsPlainText -Force
    }
    elseif ($SecretValue -is [SecureString]) {
        $secureValue = $SecretValue
    }
    else {
        throw "SecretValue must be a string or SecureString"
    }

    # Build parameters
    $setParams = @{
        VaultName   = $kvName
        Name        = $SecretName
        SecretValue = $secureValue
    }

    if ($ContentType) {
        $setParams.ContentType = $ContentType
    }

    # Use solution tags if not provided
    if (-not $Tags) {
        $Tags = Get-ConfigTags -Config $Config
    }
    if ($Tags -and $Tags.Count -gt 0) {
        $setParams.Tag = $Tags
    }

    if ($ExpiresInDays) {
        $setParams.Expires = (Get-Date).AddDays($ExpiresInDays)
    }

    # Set the secret
    $result = Set-AzKeyVaultSecret @setParams

    # Return the keyvault:// URI for reference
    return ConvertTo-KeyVaultUri -VaultName $kvName -SecretName $SecretName
}

<#
.SYNOPSIS
    Resolves all keyvault:// references in a credential section.

.DESCRIPTION
    Takes a credentials hashtable from configuration and resolves all
    keyvault:// URIs to their actual values. Useful for preparing
    credentials for deployment.

.PARAMETER Credentials
    The credentials section from configuration.

.PARAMETER AsPlainText
    If specified, returns passwords as plain text.

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    $creds = Resolve-CredentialReferences -Credentials $config.credentials -AsPlainText
#>
function Resolve-CredentialReferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Credentials,

        [Parameter(Mandatory = $false)]
        [switch]$AsPlainText
    )

    $resolved = @{}

    foreach ($key in $Credentials.Keys) {
        $value = $Credentials[$key]
        
        if ($value -is [hashtable] -or $value -is [System.Collections.Specialized.OrderedDictionary]) {
            # Recurse into nested hashtables
            $resolved[$key] = Resolve-CredentialReferences -Credentials $value -AsPlainText:$AsPlainText
        }
        elseif (Test-KeyVaultUri -Value $value) {
            # Resolve the Key Vault reference
            $resolved[$key] = Get-SecretFromUri -Uri $value -AsPlainText:$AsPlainText
        }
        else {
            # Keep the value as-is
            $resolved[$key] = $value
        }
    }

    return $resolved
}

<#
.SYNOPSIS
    Stores a service principal's credentials in Key Vault.

.DESCRIPTION
    Creates secrets for a service principal's App ID and Secret in Key Vault,
    following the naming convention: sp-<name>-appid and sp-<name>-secret.

.PARAMETER Config
    The solution configuration.

.PARAMETER SpName
    The service principal name (used in secret naming).

.PARAMETER AppId
    The Application (Client) ID.

.PARAMETER Secret
    The client secret value.

.PARAMETER ExpiresInDays
    Optional. Number of days until the secret expires.

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    $uris = Set-ServicePrincipalToKeyVault -Config $config -SpName "azure-local-deploy" -AppId $sp.AppId -Secret $secret.SecretText

.NOTES
    Returns a hashtable with the keyvault:// URIs for both the AppId and Secret.
#>
function Set-ServicePrincipalToKeyVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$SpName,

        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $true)]
        $Secret,

        [Parameter(Mandatory = $false)]
        [int]$ExpiresInDays = 365
    )

    $appIdSecretName = "sp-$SpName-appid"
    $secretSecretName = "sp-$SpName-secret"

    $appIdUri = Set-SecretToKeyVault -Config $Config -SecretName $appIdSecretName -SecretValue $AppId -ContentType "application-id"
    $secretUri = Set-SecretToKeyVault -Config $Config -SecretName $secretSecretName -SecretValue $Secret -ContentType "client-secret" -ExpiresInDays $ExpiresInDays

    return @{
        AppIdUri   = $appIdUri
        SecretUri  = $secretUri
        AppIdName  = $appIdSecretName
        SecretName = $secretSecretName
    }
}

<#
.SYNOPSIS
    Retrieves a service principal's credentials from Key Vault.

.DESCRIPTION
    Gets the App ID and Secret for a service principal from Key Vault,
    using the naming convention: sp-<name>-appid and sp-<name>-secret.

.PARAMETER Config
    The solution configuration.

.PARAMETER SpName
    The service principal name.

.PARAMETER AsPlainText
    If specified, returns the secret as plain text.

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    $spCreds = Get-ServicePrincipalFromKeyVault -Config $config -SpName "azure-local-deploy" -AsPlainText
    
    # Use the credentials
    $credential = New-Object PSCredential($spCreds.AppId, (ConvertTo-SecureString $spCreds.Secret -AsPlainText -Force))
#>
function Get-ServicePrincipalFromKeyVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$SpName,

        [Parameter(Mandatory = $false)]
        [switch]$AsPlainText
    )

    $appIdSecretName = "sp-$SpName-appid"
    $secretSecretName = "sp-$SpName-secret"

    $appId = Get-SecretFromConfig -Config $Config -SecretName $appIdSecretName -AsPlainText
    $secret = Get-SecretFromConfig -Config $Config -SecretName $secretSecretName -AsPlainText:$AsPlainText

    return @{
        AppId  = $appId
        Secret = $secret
    }
}

<#
.SYNOPSIS
    Ensures connection to Azure with the correct subscription.

.DESCRIPTION
    Checks if already connected to Azure, and if so, ensures the correct
    subscription is selected based on solution configuration.

.PARAMETER Config
    The solution configuration.

.PARAMETER Force
    If specified, forces a new login even if already connected.

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    Connect-AzureFromConfig -Config $config
#>
function Connect-AzureFromConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    $tenantId = Get-ConfigValue -Config $Config -Path 'azure.tenant.id'
    $subscriptionId = Get-ConfigValue -Config $Config -Path 'azure.subscription.id'

    if ([string]::IsNullOrEmpty($tenantId) -or [string]::IsNullOrEmpty($subscriptionId)) {
        throw "Azure tenant ID and subscription ID must be defined in configuration"
    }

    # Check current context
    $context = Get-AzContext -ErrorAction SilentlyContinue

    if ($Force -or -not $context -or $context.Subscription.Id -ne $subscriptionId) {
        Write-Host "Connecting to Azure subscription: $subscriptionId" -ForegroundColor Cyan
        Connect-AzAccount -TenantId $tenantId -SubscriptionId $subscriptionId
    }
    else {
        Write-Host "Already connected to subscription: $($context.Subscription.Name)" -ForegroundColor Green
    }

    return Get-AzContext
}

# Export functions
Export-ModuleMember -Function @(
    'ConvertFrom-KeyVaultUri',
    'ConvertTo-KeyVaultUri',
    'Test-KeyVaultUri',
    'Get-SecretFromUri',
    'Get-SecretFromConfig',
    'Set-SecretToKeyVault',
    'Resolve-CredentialReferences',
    'Set-ServicePrincipalToKeyVault',
    'Get-ServicePrincipalFromKeyVault',
    'Connect-AzureFromConfig'
)
