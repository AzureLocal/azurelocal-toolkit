<#
.SYNOPSIS
    Creates a new script from the template of the toolkit: one that takes -InfrastructureFile and reads registered keys.

.DESCRIPTION
    Writes a PowerShell 7 script with the structure every script of scripts/deploy follows:
      - comment-based help with the keys the script reads and the exit codes (0 done, 1 a call failed, 2 a value is missing);
      - -InfrastructureFile (mandatory) and -LogPath, SupportsShouldProcess;
      - Set-StrictMode, $ErrorActionPreference = 'Stop';
      - the file is loaded with Import-AzlInfrastructure and read with Get-AzlInfrastructureValue, never by a path of its own;
      - no prompt: a script never asks for a value or a credential.

    The template has no value of a deployment. Add the keys the script reads to config/variables/schema/master-registry.yaml first (the registry
    is the only master), then read them in the script, and register the script parameters with config/variables/scripts/New-ScriptParameterRegistry.ps1.
    A script that needs a secret reads it through scripts/common/secrets/AzlSecret.psm1.

.PARAMETER ScriptType
    Type of script to generate:
    - PowerShell: PowerShell 7 script (Verb-Noun.ps1)
    - AzurePowerShell: Azure PowerShell script (Verb-AzResource.ps1). It checks the sign-in and the tenant of azure.tenant_id; it does not sign in.
    - AzureCliPowerShell: Azure CLI called from PowerShell (az-verb-resource.ps1). It checks that az is signed in; it does not sign in.
    - InvokeScript: Remote or management-box script (Invoke-Action.ps1)

.PARAMETER Name
    Name for the script (will be formatted according to type).

.PARAMETER Description
    Brief description of what the script does. Required: the tool has no default text, so a script is never written with a placeholder.

.PARAMETER OutputPath
    Directory to create the script in. Defaults to current directory.

.EXAMPLE
    .\New-ScriptFromTemplate.ps1 -ScriptType AzurePowerShell -Name "New-AzKeyVault" -Description "Creates a Key Vault"

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 2.0.0
#>

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("PowerShell", "AzurePowerShell", "AzureCliPowerShell", "InvokeScript")]
    [string]$ScriptType,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Description,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Determine file name based on type
switch ($ScriptType) {
    "PowerShell" { $fileName = "$Name.ps1" }
    "AzurePowerShell" { $fileName = "$Name.ps1" }
    "AzureCliPowerShell" { $fileName = "az-$($Name.ToLower()).ps1" }
    "InvokeScript" { $fileName = "Invoke-$Name.ps1" }
}

$fullPath = Join-Path $OutputPath $fileName

# The block of the script that checks the sign-in. Only the Azure types have one.
$azureCheck = switch ($ScriptType) {
    "AzurePowerShell" {
        @'

# ---- preconditions (read only): the script does not sign in. Run Connect-AzAccount to the tenant of the file first.
$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
if (-not $tenantId) { Exit-InputProblem 'azure.tenant_id is missing in the infrastructure file.' }
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
'@
    }
    "AzureCliPowerShell" {
        @'

# ---- preconditions (read only): the script does not sign in. Run az login to the tenant of the file first.
$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
if (-not $tenantId) { Exit-InputProblem 'azure.tenant_id is missing in the infrastructure file.' }
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found.' }
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) { Exit-Failed 'Not signed in to the Azure CLI. Run az login --tenant <azure.tenant_id>.' }
if ([string]$account.tenantId -ne $tenantId) { Exit-Failed "Signed in to tenant $($account.tenantId), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
'@
    }
    default { '' }
}
$keysRead = if ($ScriptType -in 'AzurePowerShell', 'AzureCliPowerShell') { "        azure.tenant_id" } else { "        (list every key the script reads here, as a dotted path)" }

$template = @"
<#
.SYNOPSIS
    $Description

.DESCRIPTION
    $Description

    Idempotent: an item that is already in place is reported and left alone. -WhatIf shows what would change and changes nothing.
    The script asks for nothing and does not sign in.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
$keysRead

    Exit codes: 0 done, already there, or planned under -WhatIf; 1 a call or a precondition failed; 2 a value in the file is missing or not usable
    (nothing was sent anywhere).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./$fileName -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would happen. Changes nothing.

.NOTES
    Type: schema 5 script (see scripts/tools/authoring/README.md)
    Date: $(Get-Date -Format 'yyyy-MM-dd')
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]`$InfrastructureFile,
    [string]`$LogPath
)
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$logFile = `$LogPath

function Find-AzlModule([string]`$RelativePath) {
    # Walk up from this script to the repository root that holds scripts/common.
    `$current = Get-Item -LiteralPath `$PSScriptRoot
    while (`$null -ne `$current) {
        `$candidate = [IO.Path]::Combine(`$current.FullName, 'scripts', 'common', `$RelativePath)
        if (Test-Path -LiteralPath `$candidate) { return `$candidate }
        `$current = `$current.Parent
    }
    throw "Unable to find scripts/common/`$RelativePath above '`$PSScriptRoot'."
}
Import-Module (Find-AzlModule 'infrastructure/AzlInfrastructure.psm1') -Force

function Write-Line([string]`$Text) {
    Write-Information -MessageData `$Text -InformationAction Continue
    if (`$logFile) { Add-Content -LiteralPath `$logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), `$Text) -WhatIf:`$false }
}
function Exit-InputProblem([string]`$Message) { Write-Error `$Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]`$Message) { Write-Error `$Message -ErrorAction Continue; exit 1 }

# ---- the values, from infrastructure.yml only. Register a key in config/variables/schema/master-registry.yaml before the script reads it.
try { `$infra = Import-AzlInfrastructure -Path `$InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: `$(`$_.Exception.Message)" }
$azureCheck

# ---- the work: one result row per item
`$rows = [System.Collections.Generic.List[object]]::new()
# Add the items of the script here. For each item: read it, report [exists] and leave it alone when it is in place, otherwise
# act behind `$PSCmdlet.ShouldProcess(...) and report [done], or [plan] under -WhatIf.

`$rows
if (@(`$rows | Where-Object Action -EQ 'Failed').Count -gt 0) { exit 1 }
exit 0
"@

# Write the template
$template | Out-File -FilePath $fullPath -Encoding utf8

Write-Host "Script created: $fullPath" -ForegroundColor Green
Write-Host "Type: $ScriptType" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Register the keys the script reads in config/variables/schema/master-registry.yaml"
Write-Host "  2. Read them with Get-AzlInfrastructureValue and write the work of the script"
Write-Host "  3. Test with -WhatIf, and write a Pester test with the cmdlets mocked"
Write-Host "  4. Run config/variables/scripts/New-ScriptParameterRegistry.ps1 and New-VariableMap.ps1"

return [PSCustomObject]@{
    ScriptPath = $fullPath
    ScriptType = $ScriptType
}
