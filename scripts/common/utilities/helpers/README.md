# Helper Utilities

> **Purpose**: Small helpers that scripts of the toolkit dot-source or run  
> **Standard**: [Scripting Standards](https://azurelocal.cloud/standards/scripting/scripting-standards)

## Files

| File | Purpose |
|------|---------|
| `logging.ps1` | Standardized logging with console colors and optional file output |
| `error-handling.ps1` | Retry logic and error detail extraction |
| `Connect-AzureSession.ps1` | Signs in to Azure with Azure PowerShell. Takes `-TenantId` and `-SubscriptionId`, or reads them from the infrastructure file (`-InfrastructureFile`). Never asks |
| `Connect-AzureCliSession.ps1` | The same for the Azure CLI |

## Where the old helpers went

`config-loader.ps1` and `keyvault-helper.ps1` are retired. Nothing dot-sources them.

| Need | Use |
|------|-----|
| Load the infrastructure file | `Import-AzlInfrastructure` in `scripts/common/infrastructure/AzlInfrastructure.psm1` |
| Read a value | `Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id'` (registered keys only) |
| Check a file | `scripts/common/infrastructure/Test-InfrastructureFile.ps1 -Path ./infrastructure.yml` |
| Read a secret | `Get-AzlSecretValue` (SecureString) and `Get-AzlSecretPlainText` in `scripts/common/secrets/AzlSecret.psm1` |
| Build or test a secret reference | `New-AzlSecretReference` and `Test-AzlSecretReference` in the same module |

No helper writes a secret. Set the value with `Set-AzKeyVaultSecret` (or the portal) as someone who may write it.
`Deploy-KeyVaults.ps1` lists the references of the file whose secret is still missing.

## Usage

A script of the toolkit takes `-InfrastructureFile`, loads it once and reads values from it:

```powershell
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$subscriptionId = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id'
$reference = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.local_admin.password'
$password = Get-AzlSecretValue -Reference $reference -Infrastructure $infra
```

## Logging

```powershell
. "$PSScriptRoot/../../common/utilities/helpers/logging.ps1"

Write-Log -Level Info -Message "Starting deployment"
Write-Log -Level Warning -Message "Resource already exists"
Write-Log -Level Error -Message "Deployment failed"

Write-LogSection -Title "Security configuration"

Start-LogFile -Path "C:\logs\deployment.log"
# ... operations ...
Stop-LogFile
```

## Error Handling

```powershell
. "$PSScriptRoot/../../common/utilities/helpers/error-handling.ps1"

$result = Invoke-WithRetry -ScriptBlock {
    Get-AzContext
} -MaxRetries 3 -ExponentialBackoff
```
