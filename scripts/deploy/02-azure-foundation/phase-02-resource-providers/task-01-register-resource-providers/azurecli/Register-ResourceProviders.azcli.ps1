<#
.SYNOPSIS
    Registers the Azure resource providers that Azure Local needs, with the Azure CLI, in the subscription of infrastructure.yml.

.DESCRIPTION
    Phase 02 (resource providers), Task 01, Azure CLI variant of Register-ResourceProviders.ps1. It does the same with az commands, for a
    host that has the Azure CLI and not the Az PowerShell modules. The 13 providers are the list of the toolkit, Get-AzlArmMandatoryProvider
    in scripts/common/arm-deployment/AzlArmDeploymentRun.psm1 (Microsoft Learn: Assign required permissions for Azure Local deployment,
    Register required resource providers). This script has no list of its own.

    A provider that is Registered is left alone. A provider that is not is registered with "az provider register", behind -WhatIf. With -Wait
    the script polls until every provider it registered is Registered, or until -MaxWaitMinutes has passed.

    The script does not sign in: run "az login" to the tenant in azure.tenant_id first. It selects azure.subscription_id with
    "az account set" and puts the earlier subscription back at the end.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure): azure.tenant_id, azure.subscription_id.

    Exit codes: 0 every provider is registered, registering (without -Wait), or planned under -WhatIf; 1 an az call failed, a precondition
    failed (az missing, not signed in, wrong tenant) or a provider did not reach Registered within the time; 2 a value in the file is
    missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read.

.PARAMETER Wait
    Wait until the providers that this run registered report Registered.

.PARAMETER MaxWaitMinutes
    The longest time -Wait waits, in minutes (1 to 120). Default: 15.

.PARAMETER PollSeconds
    Seconds between two reads of the registration state while -Wait waits (1 to 300). Default: 30.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Register-ResourceProviders.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which providers would be registered, and registers none.
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

# One az call. Returns the text of standard output; throws when az ends with an error (the exit code is read from $LASTEXITCODE).
function Invoke-Az {
    $out = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($out | ForEach-Object { "$_" }) -join ' ') }
    (($out | ForEach-Object { "$_" }) -join "`n").Trim()
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$subscriptionId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder. It is the subscription the providers are registered in.' }
$providers = @(Get-AzlArmMandatoryProvider)

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Register-ResourceProviders.ps1.' }
try { $account = Invoke-Az account show --query '[tenantId,id]' --output tsv }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
$accountParts = @($account -split '\s+')
if ($accountParts[0] -ne $tenantId) { Exit-Failed "Signed in to tenant $($accountParts[0]), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalSubscription = if ($accountParts.Count -gt 1) { $accountParts[1] } else { '' }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Provider, [string]$Action, [string]$State = '', [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Provider = $Provider; Action = $Action; State = $State; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } 'AlreadyRegistered' { '[exists]  ' } 'WouldRegister' { '[plan]    ' } 'TimedOut' { '[timeout] ' } default { '[done]    ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Provider, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}

try {
    $null = Invoke-Az account set --subscription $subscriptionId
    Write-Line "Resource providers: $($providers.Count) required in subscription $subscriptionId."
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($provider in $providers) {
        try {
            $state = Invoke-Az provider show --namespace $provider --query registrationState --output tsv
            if ($state -eq 'Registered') { Add-Row $provider 'AlreadyRegistered' 'Registered'; continue }
            if ($PSCmdlet.ShouldProcess("resource provider '$provider' in subscription $subscriptionId", 'Register')) {
                $null = Invoke-Az provider register --namespace $provider
                Add-Row $provider 'Registered' 'Registering' 'registration started'
                $pending.Add($provider)
            }
            else { Add-Row $provider 'WouldRegister' $state }
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
                    if ((Invoke-Az provider show --namespace $provider --query registrationState --output tsv) -eq 'Registered') { $null = $pending.Remove($provider); Add-Row $provider 'Registered' 'Registered' 'registration finished' }
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
        try { $null = Invoke-Az account set --subscription $originalSubscription } catch { Write-Verbose "Could not restore the original subscription: $($_.Exception.Message)" }
    }
}

$failed = @($rows | Where-Object { $_.Action -in 'Failed', 'TimedOut' }).Count
$already = @($rows | Where-Object Action -EQ 'AlreadyRegistered').Count
$planned = @($rows | Where-Object Action -EQ 'WouldRegister').Count
Write-Line "Summary: $already already registered, $planned planned, $failed failed."
$rows
if ($failed -gt 0) { exit 1 }
exit 0
