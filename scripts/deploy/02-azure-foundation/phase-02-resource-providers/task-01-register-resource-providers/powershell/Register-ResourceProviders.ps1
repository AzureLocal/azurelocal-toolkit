<#
.SYNOPSIS
    Registers the Azure resource providers that Azure Local needs in the subscription of infrastructure.yml.

.DESCRIPTION
    Phase 02 (resource providers), Task 01. Azure Local needs 13 resource providers registered in the subscription before the deployment
    (Microsoft Learn: Assign required permissions for Azure Local deployment, Register required resource providers). The list is the one
    list of the toolkit, Get-AzlArmMandatoryProvider in scripts/common/arm-deployment/AzlArmDeploymentRun.psm1; the pre-cluster
    verification and the ARM deployment use the same list. This script has no list of its own.

    For each provider it reads the registration state (read only). A provider that is Registered is left alone. A provider that is not is
    registered with Register-AzResourceProvider, behind -WhatIf. With -Wait the script then polls until every provider it registered
    reports Registered, or until -MaxWaitMinutes has passed.

    Idempotent. A second run registers nothing. The script never unregisters a provider.

    The script does not sign in: run Connect-AzAccount to the tenant in azure.tenant_id first. You need the Contributor or Owner role (or
    a custom role with the /register/action permission) on the subscription. The session subscription is changed to
    azure.subscription_id while the script works and put back at the end.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id          the tenant the sign-in must belong to
        azure.subscription_id    the subscription the providers are registered in

    Exit codes: 0 every provider is registered, registering (without -Wait), or planned under -WhatIf; 1 an Azure call failed, a precondition
    failed (not signed in, wrong tenant, Az modules missing) or a provider did not reach Registered within the time; 2 a value in the
    file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER Wait
    Wait until the providers that this run registered report Registered.

.PARAMETER MaxWaitMinutes
    The longest time -Wait waits, in minutes (1 to 120). Default: 15.

.PARAMETER PollSeconds
    Seconds between two reads of the registration state while -Wait waits (1 to 300). Default: 30.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Register-ResourceProviders.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which providers would be registered, and registers none.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Register-ResourceProviders.ps1 -InfrastructureFile ./infrastructure.yml -Wait

    Registers the providers that are missing and waits until they are Registered.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [switch]$Wait,
    [ValidateRange(1, 120)][int]$MaxWaitMinutes = 15,
    [ValidateRange(1, 300)][int]$PollSeconds = 30,
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
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Test-AllRegistered([string[]]$States) { $States.Count -gt 0 -and @($States | Where-Object { $_ -ne 'Registered' }).Count -eq 0 }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$subscriptionId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder. It is the subscription the providers are registered in.' }
$providers = @(Get-AzlArmMandatoryProvider)

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResourceProvider', 'Register-AzResourceProvider') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Resources modules: Install-Module Az.Accounts, Az.Resources -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalSubscription = if ($context.PSObject.Properties['Subscription'] -and $context.Subscription) { [string]$context.Subscription.Id } else { '' }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Provider, [string]$Action, [string]$State = '', [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Provider = $Provider; Action = $Action; State = $State; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } 'AlreadyRegistered' { '[exists]  ' } 'WouldRegister' { '[plan]    ' } 'TimedOut' { '[timeout] ' } default { '[done]    ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Provider, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}

try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    Write-Line "Resource providers: $($providers.Count) required in subscription $subscriptionId."

    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($provider in $providers) {
        try {
            $states = @(Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | ForEach-Object { [string]$_.RegistrationState } | Select-Object -Unique)
            if (Test-AllRegistered $states) { Add-Row $provider 'AlreadyRegistered' 'Registered'; continue }
            if ($PSCmdlet.ShouldProcess("resource provider '$provider' in subscription $subscriptionId", 'Register')) {
                $null = Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop
                Add-Row $provider 'Registered' 'Registering' 'registration started'
                $pending.Add($provider)
            }
            else { Add-Row $provider 'WouldRegister' ($states -join ',') }
        }
        catch { Add-Row $provider 'Failed' '' $_.Exception.Message }
    }

    if ($Wait -and $pending.Count -gt 0) {
        $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
        Write-Line "Waiting for $($pending.Count) provider(s), at most $MaxWaitMinutes minute(s)."
        while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $PollSeconds
            foreach ($provider in @($pending)) {
                try {
                    $states = @(Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | ForEach-Object { [string]$_.RegistrationState } | Select-Object -Unique)
                    if (Test-AllRegistered $states) { $null = $pending.Remove($provider); Add-Row $provider 'Registered' 'Registered' 'registration finished' }
                }
                catch { Write-Verbose "${provider}: could not read the state: $($_.Exception.Message)" }
            }
        }
        foreach ($provider in $pending) { Add-Row $provider 'TimedOut' 'Registering' "not Registered after $MaxWaitMinutes minute(s)" }
    }
}
catch { Exit-Failed "Resource provider registration stopped: $($_.Exception.Message)" }
finally {
    if ($originalSubscription -and $originalSubscription -ne $subscriptionId) {
        try { $null = Set-AzContext -SubscriptionId $originalSubscription -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$failed = @($rows | Where-Object { $_.Action -in 'Failed', 'TimedOut' }).Count
$already = @($rows | Where-Object Action -EQ 'AlreadyRegistered').Count
$planned = @($rows | Where-Object Action -EQ 'WouldRegister').Count
Write-Line "Summary: $already already registered, $planned planned, $failed failed."
if (@($rows | Where-Object Action -EQ 'Registered').Count -eq 0 -and $planned -eq 0 -and $failed -eq 0) { Write-Line 'Nothing to do: every required provider is already registered.' }
$rows
if ($failed -gt 0) { exit 1 }
exit 0
