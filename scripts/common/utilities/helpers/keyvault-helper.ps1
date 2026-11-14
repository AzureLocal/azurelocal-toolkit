<#
.SYNOPSIS
    Secret helper functions for the older scripts that dot-source the helper files.

.DESCRIPTION
    This file reads secret references through the toolkit's one secret resolver, scripts/common/secrets/AzlSecret.psm1. The reference
    is keyvault://<vault>/<secret>, env://<VARIABLE>, file://<name> or command://<name>, and it comes from the infrastructure file.

    This file never calls Get-AzKeyVaultSecret or Set-AzKeyVaultSecret, never parses a reference, and never names a vault or a secret.
    The vault is a key_vaults entry of the infrastructure file; the secret name is part of the reference the file holds. No helper
    writes a secret value: create a secret with Set-AzKeyVaultSecret (or the portal) as someone who may write it, then list the
    references that still lack a secret by running Deploy-KeyVaults.ps1.

.NOTES
    Requires:
    - Az.Accounts (Connect-AzureFromConfig only)
    - config-loader.ps1 (loaded from the same folder)

.EXAMPLE
    # Resolve the secret a reference of the file points to
    $infra = Import-AzlInfrastructure -Path ./infrastructure.yml
    $password = Get-SecretFromUri -Uri $infra.identity.local_admin.password -Infrastructure $infra

.EXAMPLE
    # Read a secret by its name, in the provider the file selects (secrets.provider)
    $infra = Import-AzlInfrastructure -Path ./infrastructure.yml
    $value = Get-SecretFromConfig -Config $infra -SecretName $secretNameFromYourFile -AsPlainText
#>

#Requires -Modules Az.Accounts

# Import the config loader
$configLoaderPath = Join-Path $PSScriptRoot "config-loader.ps1"
if (Test-Path $configLoaderPath) {
    . $configLoaderPath
}

# Import the toolkit's one secret resolver
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'secrets', 'AzlSecret.psm1')) -ErrorAction Stop

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
    $uri = ConvertTo-KeyVaultUri -VaultName $vault.name -SecretName $secretName
    # Returns: "keyvault://<vault>/<secret>"
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
    Checks if a value is a secret reference (keyvault://, env://, file:// or command://).

.PARAMETER Value
    The value to check.

.EXAMPLE
    if (Test-KeyVaultUri -Value $infra.identity.local_admin.password) {
        $password = Get-SecretFromUri -Uri $infra.identity.local_admin.password -Infrastructure $infra
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
    return [bool](Get-AzlSecretProvider -Reference $Value)
}

<#
.SYNOPSIS
    Reads a secret from a secret reference with the toolkit's one secret resolver.

.DESCRIPTION
    The reference is keyvault://<vault>/<secret>, env://<VARIABLE>, file://<name> or command://<name>.
    The resolver needs the loaded infrastructure file (key_vaults and the secrets section).
    Returns the secret as a SecureString or plain text based on parameter.

.PARAMETER Uri
    The secret reference.

.PARAMETER Infrastructure
    The loaded infrastructure file (Import-AzlInfrastructure).

.PARAMETER AsPlainText
    If specified, returns the secret as plain text instead of SecureString.

.EXAMPLE
    $password = Get-SecretFromUri -Uri $infra.identity.local_admin.password -Infrastructure $infra -AsPlainText

.EXAMPLE
    $securePassword = Get-SecretFromUri -Uri $infra.identity.local_admin.password -Infrastructure $infra
#>
function Get-SecretFromUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [System.Collections.IDictionary]$Infrastructure,

        [Parameter(Mandatory = $false)]
        [switch]$AsPlainText
    )

    if ($AsPlainText) {
        return Get-AzlSecretPlainText -Reference $Uri -Infrastructure $Infrastructure
    }

    return Get-AzlSecretValue -Reference $Uri -Infrastructure $Infrastructure
}

<#
.SYNOPSIS
    Reads a secret by its name, in the provider the infrastructure file selects.

.DESCRIPTION
    Builds the reference with New-AzlSecretReference, which uses secrets.provider of the file (Key Vault when the file does not say;
    the vault is then the only one listed under key_vaults), then reads it with the toolkit's one secret resolver. The caller takes
    the secret name from the file; this function has no name of its own.

.PARAMETER Config
    The loaded infrastructure file (Import-AzlInfrastructure).

.PARAMETER SecretName
    The name of the secret to retrieve.

.PARAMETER AsPlainText
    If specified, returns the secret as plain text.

.EXAMPLE
    $infra = Import-AzlInfrastructure -Path ./infrastructure.yml
    $value = Get-SecretFromConfig -Config $infra -SecretName $secretNameFromYourFile -AsPlainText
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

    # The provider is secrets.provider of the file; the vault of a keyvault reference comes from key_vaults in the file
    $reference = New-AzlSecretReference -Name $SecretName -Infrastructure $Config
    return Get-SecretFromUri -Uri $reference -Infrastructure $Config -AsPlainText:$AsPlainText
}

<#
.SYNOPSIS
    Resolves all secret references in a credential section.

.DESCRIPTION
    Takes a credentials hashtable from configuration and resolves all
    secret references (keyvault://, env://, file://, command://) to their
    actual values with the toolkit's one secret resolver. Useful for
    preparing credentials for deployment.

.PARAMETER Credentials
    The credentials section from configuration.

.PARAMETER Infrastructure
    The loaded infrastructure file (Import-AzlInfrastructure).

.PARAMETER AsPlainText
    If specified, returns passwords as plain text.

.EXAMPLE
    $infra = Import-AzlInfrastructure -Path ./infrastructure.yml
    $creds = Resolve-CredentialReferences -Credentials $infra.identity -Infrastructure $infra
#>
function Resolve-CredentialReferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Credentials,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [System.Collections.IDictionary]$Infrastructure,

        [Parameter(Mandatory = $false)]
        [switch]$AsPlainText
    )

    $resolved = @{}

    foreach ($key in $Credentials.Keys) {
        $value = $Credentials[$key]

        if ($value -is [hashtable] -or $value -is [System.Collections.Specialized.OrderedDictionary]) {
            # Recurse into nested hashtables
            $resolved[$key] = Resolve-CredentialReferences -Credentials $value -Infrastructure $Infrastructure -AsPlainText:$AsPlainText
        }
        elseif (Test-KeyVaultUri -Value $value) {
            # Resolve the secret reference
            $resolved[$key] = Get-SecretFromUri -Uri $value -Infrastructure $Infrastructure -AsPlainText:$AsPlainText
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
    Ensures connection to Azure with the correct subscription.

.DESCRIPTION
    Checks if already connected to Azure, and if so, ensures the correct
    subscription is selected based on the infrastructure file.

.PARAMETER Config
    The loaded infrastructure file.

.PARAMETER Force
    If specified, forces a new login even if already connected.

.EXAMPLE
    $infra = Import-AzlInfrastructure -Path ./infrastructure.yml
    Connect-AzureFromConfig -Config $infra
#>
function Connect-AzureFromConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    $tenantId = Get-ConfigValue -Config $Config -Path 'azure.tenant_id'
    $subscriptionId = Get-ConfigValue -Config $Config -Path 'azure.subscription_id'

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
    'ConvertTo-KeyVaultUri',
    'Test-KeyVaultUri',
    'Get-SecretFromUri',
    'Get-SecretFromConfig',
    'Resolve-CredentialReferences',
    'Connect-AzureFromConfig'
)
