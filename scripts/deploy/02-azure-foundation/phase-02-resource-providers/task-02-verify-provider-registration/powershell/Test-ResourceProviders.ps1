<#
.SYNOPSIS
    Checks that the Azure resource providers Azure Local needs are registered in the subscription of infrastructure.yml. Changes nothing.

.DESCRIPTION
    Phase 02 (resource providers), Task 02. Reads the registration state of each of the 13 providers Microsoft Learn lists (Assign required
    permissions for Azure Local deployment, Register required resource providers). The list is the one list of the toolkit,
    Get-AzlArmMandatoryProvider in scripts/common/arm-deployment/AzlArmDeploymentRun.psm1. This script has no list of its own.

    One result row per provider: Provider, RegistrationState, IsRegistered. Register the missing ones with Register-ResourceProviders.ps1
    (task 01).

    The script only reads. It does not sign in: run Connect-AzAccount to the tenant in azure.tenant_id first. Reader on the subscription is
    enough. The session subscription is changed to azure.subscription_id while the script works and put back at the end.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id          the tenant the sign-in must belong to
        azure.subscription_id    the subscription that is checked

    Exit codes: 0 every provider is Registered; 1 a provider is not Registered, an Azure call failed or a precondition failed (not signed in,
    wrong tenant, Az modules missing); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-ResourceProviders.ps1 -InfrastructureFile ./infrastructure.yml

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

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$subscriptionId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder. It is the subscription that is checked.' }
$providers = @(Get-AzlArmMandatoryProvider)

# ---- preconditions
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResourceProvider') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Resources modules: Install-Module Az.Accounts, Az.Resources -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalSubscription = if ($context.PSObject.Properties['Subscription'] -and $context.Subscription) { [string]$context.Subscription.Id } else { '' }

$rows = [System.Collections.Generic.List[object]]::new()
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    foreach ($provider in $providers) {
        $state = 'Error'
        try {
            $states = @(Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | ForEach-Object { [string]$_.RegistrationState } | Select-Object -Unique)
            $state = if ($states.Count -eq 0) { 'NotFound' } elseif (@($states | Where-Object { $_ -ne 'Registered' }).Count -eq 0) { 'Registered' } else { ($states | Where-Object { $_ -ne 'Registered' } | Select-Object -First 1) }
        }
        catch { Write-Warning "${provider}: $($_.Exception.Message)" }
        $rows.Add([pscustomobject][ordered]@{ Provider = $provider; RegistrationState = $state; IsRegistered = ($state -eq 'Registered') })
    }
}
catch { Exit-Failed "The providers could not be checked: $($_.Exception.Message)" }
finally {
    if ($originalSubscription -and $originalSubscription -ne $subscriptionId) {
        try { $null = Set-AzContext -SubscriptionId $originalSubscription -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$missing = @($rows | Where-Object { -not $_.IsRegistered })
Write-Line "$($rows.Count - $missing.Count) of $($rows.Count) required resource providers are registered."
foreach ($row in $missing) { Write-Line "  not registered: $($row.Provider) ($($row.RegistrationState))" }
$rows
if ($missing.Count -gt 0) { exit 1 }
exit 0
