<#
.SYNOPSIS
    Checks with the Azure CLI that the Azure resource providers Azure Local needs are registered in the subscription of infrastructure.yml. Changes nothing.

.DESCRIPTION
    Phase 02 (resource providers), Task 02, Azure CLI variant of Test-ResourceProviders.ps1. Reads the registration state of each of the 13
    providers Microsoft Learn lists (Assign required permissions for Azure Local deployment, Register required resource providers) with
    "az provider show". The list is the one list of the toolkit, Get-AzlArmMandatoryProvider in scripts/common/arm-deployment/AzlArmDeploymentRun.psm1.
    This script has no list of its own.

    One result row per provider: Provider, RegistrationState, IsRegistered. Register the missing ones with Register-ResourceProviders.azcli.ps1
    (task 01).

    The script only reads. It does not sign in: run "az login --tenant <azure.tenant_id>" first. Reader on the subscription is enough. Each az call
    names the subscription with --subscription, so the subscription that az has selected is not changed.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id          the tenant the sign-in must belong to
        azure.subscription_id    the subscription that is checked

    Exit codes: 0 every provider is Registered; 1 a provider is not Registered, an Azure call failed or a precondition failed (az missing, not signed
    in, wrong tenant); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-ResourceProviders.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Prints one row for each provider and ends with exit code 0 when all are Registered.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common'))
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# One az call. Returns the text of standard output; throws, with the error text, when az ends with an error (warnings on standard error are dropped).
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgument)
    $all = @(& az @AzArgument 2>&1)
    $code = $LASTEXITCODE
    $errorText = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ').Trim()
    $text = (@($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0) { throw $(if ($errorText -or $text) { (@($errorText, $text) | Where-Object { $_ }) -join ' ' } else { "az ended with exit code $code." }) }
    $text
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$subscriptionId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder. It is the subscription that is checked.' }
$providers = @(Get-AzlArmMandatoryProvider)

# ---- preconditions
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Test-ResourceProviders.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($provider in $providers) {
    $state = 'Error'
    try {
        $text = Invoke-Az -AzArgument @('provider', 'show', '--namespace', $provider, '--subscription', $subscriptionId, '--query', 'registrationState', '--output', 'tsv')
        $state = if ($text) { $text } else { 'NotFound' }
    }
    catch { Write-Warning "${provider}: $($_.Exception.Message)" }
    $rows.Add([pscustomobject][ordered]@{ Provider = $provider; RegistrationState = $state; IsRegistered = ($state -eq 'Registered') })
}

$missing = @($rows | Where-Object { -not $_.IsRegistered })
Write-Line "$($rows.Count - $missing.Count) of $($rows.Count) required resource providers are registered."
foreach ($row in $missing) { Write-Line "  not registered: $($row.Provider) ($($row.RegistrationState))" }
$rows
if ($missing.Count -gt 0) { exit 1 }
exit 0
