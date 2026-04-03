# Helper Utilities

> **Purpose**: Shared helper functions for all PowerShell scripts in the toolkit  
> **Standard**: [Scripting Standards](https://azurelocal.cloud/standards/scripting/scripting-standards)

## Files

| File | Purpose |
|------|---------|
| `config-loader.ps1` | Load and parse `infrastructure.yml` configuration files |
| `keyvault-helper.ps1` | Azure Key Vault secret operations using `keyvault://` URIs |
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
$tenantId = Get-ConfigValue -Config $config -Path 'azure.tenant.id'
$subscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscriptions.management.id'
$kvName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.key_vaults.platform.name'

# Get tags for Azure resources
$tags = Get-ConfigTags -Config $config
```

### Option B: Environment Script (For Node Execution)

When running scripts directly on nodes without access to the full config structure, generate an environment script:

```powershell
# Generated env-variables.ps1 for node execution
$script:Environment = @{
    TenantId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    SubscriptionId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    KeyVaultName = "azl-platform-kv"
    Location = "eastus"
    Tags = @{
        Environment = "Production"
        ManagedBy = "AzureLocal Cloud Team"
    }
}
```

## Key Vault Operations

### Reading Secrets

```powershell
# Using keyvault:// URI syntax
$password = Get-SecretFromUri -Uri "keyvault://azl-platform-kv/local-admin-password" -AsPlainText

# Or using config reference
$secretUri = Get-ConfigValue -Config $config -Path 'credentials.local_admin.password'
$password = Get-SecretFromUri -Uri $secretUri -AsPlainText
```

### Writing Secrets

```powershell
# Write to platform Key Vault
Set-SecretToKeyVault -Config $config -SecretName "my-secret" -SecretValue "secret-value"
```

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
| `azure.tenant.id` | Azure AD tenant ID |
| `azure.subscriptions.<name>.id` | Subscription ID by purpose |
| `azure_infrastructure.key_vaults.platform.name` | Platform Key Vault name |
| `azure_infrastructure.resource_groups.<name>.name` | Resource group name |
| `tags.*` | Standard Azure resource tags |
| `credentials.<name>.password` | Credential secret URI |

See [Scripting Standards - Variable Path Contract](https://azurelocal.cloud/standards/scripting/scripting-standards#variable-path-contract) for the complete list.
