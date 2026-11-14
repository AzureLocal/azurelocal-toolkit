# Helper Utilities

> **Purpose**: Shared helper functions for all PowerShell scripts in the toolkit  
> **Standard**: [Scripting Standards](https://azurelocal.cloud/standards/scripting/scripting-standards)

## Files

| File | Purpose |
|------|---------|
| `config-loader.ps1` | Load and parse `infrastructure.yml` configuration files |
| `keyvault-helper.ps1` | Reads secret references through the secret resolver |
| `logging.ps1` | Standardized logging with console colors and optional file output |
| `error-handling.ps1` | Retry logic and error detail extraction |

## Usage

All scripts should dot-source these helpers:

```powershell
# At the top of every script
$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

# Import helpers
. "$scriptRoot/../../common/utilities/helpers/config-loader.ps1"
. "$scriptRoot/../../common/utilities/helpers/logging.ps1"
. "$scriptRoot/../../common/utilities/helpers/keyvault-helper.ps1"
. "$scriptRoot/../../common/utilities/helpers/error-handling.ps1"
```

## Configuration Loading

### Option A: Load from infrastructure.yml (Recommended)

```powershell
# Load environment configuration
$config = Get-SolutionConfig -Solution "azure-local"

# Access values using the Variable Path Contract
$tenantId = Get-ConfigValue -Config $config -Path 'azure.tenant_id'
$subscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscription_id'
$kvName = Get-PlatformKeyVault -Config $config   # the vault listed under key_vaults

# Get tags for Azure resources
$tags = Get-ConfigTags -Config $config
```

### Option B: Environment Script (For Node Execution)

When running scripts directly on nodes without access to the full config structure, generate an environment script:

```powershell
# Generated env-variables.ps1 for node execution
$script:Environment = @{
    TenantId = "00000000-0000-0000-0000-000000000000"
    SubscriptionId = "00000000-0000-0000-0000-000000000000"
    KeyVaultName = "kv-iic-mgmt-01"
    Location = "westeurope"
    Tags = @{
        Environment = "Production"
        ManagedBy = "AzureLocal Cloud Team"
    }
}
```

## Key Vault Operations

### Reading Secrets

Reading goes through the toolkit's one secret resolver (`scripts/common/secrets/AzlSecret.psm1`). The reference comes from the
infrastructure file, and the loaded file is passed with it (it lists `key_vaults` and the `secrets` section).

```powershell
$infra = Import-AzlInfrastructure -Path ./infrastructure.yml
$secretUri = $infra.identity.local_admin.password   # keyvault://, env://, file:// or command://
$password = Get-SecretFromUri -Uri $secretUri -Infrastructure $infra -AsPlainText
```

### Writing Secrets

No helper writes a secret. Set the value with `Set-AzKeyVaultSecret` (or the portal) as someone who may write it.
`Deploy-KeyVaults.ps1` lists the references of the file whose secret is still missing.

## Logging

```powershell
# Standard log levels
Write-Log -Level Info -Message "Starting deployment"
Write-Log -Level Warning -Message "Resource already exists"
Write-Log -Level Error -Message "Deployment failed"

# Section headers
Write-LogSection -Title "Stage 6: Security Configuration"

# File logging
Start-LogFile -Path "C:\logs\deployment.log"
# ... operations ...
Stop-LogFile
```

## Error Handling

```powershell
# Retry pattern
$result = Invoke-WithRetry -ScriptBlock {
    Connect-AzAccount -Tenant $tenantId
} -MaxRetries 3 -ExponentialBackoff

# Operation wrapper
Invoke-Operation -Operation "Create Key Vault" -ScriptBlock {
    New-AzKeyVault -Name $kvName -ResourceGroupName $rgName -Location $location
}
```

## Variable Path Contract

All scripts use consistent paths to access configuration values. These paths are guaranteed to exist:

| Path | Description |
|------|-------------|
| `azure.tenant_id` | Azure AD tenant ID |
| `azure.subscription_id` | Subscription ID |
| `key_vaults[].name` | Key Vault name (`Get-PlatformKeyVault`: the only vault listed, or the one whose `purpose` is given with `-Purpose`) |
| `azure_infrastructure.resource_groups.<name>.name` | Resource group name |
| `tags.*` | Standard Azure resource tags |
| `credentials.<name>.password` | Credential secret URI |

See [Scripting Standards - Variable Path Contract](https://azurelocal.cloud/standards/scripting/scripting-standards#variable-path-contract) for the complete list.
