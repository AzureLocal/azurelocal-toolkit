<#
.SYNOPSIS
    Checks the Azure side of the Azure Arc registration of the Azure Local machines, with the Azure CLI: subscription, resource providers, resource group and the roles of the signed-in account. Read only.

.DESCRIPTION
    Phase 04 (Arc registration), Task 01 (pre-registration validation), the Azure side. The connectivity half of this task (the Environment Checker
    on each machine) runs on the machines and is not an Azure CLI task. Nothing is created, changed or deleted.

    Checks, in this order:
      1. Subscription: azure.subscription_id is visible to the signed-in account, is Enabled and belongs to the tenant azure.tenant_id.
      2. Resource group: azure.resource_group exists (the Arc machines are registered into it) and its provisioning state is Succeeded.
      3. Resource providers: every provider of the toolkit's list (Get-AzlArmMandatoryProvider in scripts/common/arm-deployment/AzlArmDeploymentRun.psm1,
         Microsoft Learn: Register required resource providers) is Registered in the subscription.
      4. Roles: the signed-in user or service principal can register the machines as Arc resources in the resource group: it holds Owner, or both
         Azure Connected Machine Onboarding and Azure Connected Machine Resource Administrator, at the resource group, the subscription or above, directly or
         through a group when the account is a user (Microsoft Learn: Assign required permissions for Azure Local deployment, Register the machines with Azure Arc).

    -WhatIf lists the checks and runs none. The script does not sign in: run az login --tenant <azure.tenant_id> first. It does not change the Azure CLI
    default subscription: every call carries --subscription. Reading the account's own role assignments needs permission to read role assignments
    and, for a signed-in user, to read its own directory object (az ad signed-in-user show).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure): azure.tenant_id, azure.subscription_id, azure.resource_group.

    Exit codes: 0 every check passed (or planned under -WhatIf); 1 a check failed or a precondition failed (az missing, not signed in, wrong tenant);
    2 a value in the file is missing or unusable (nothing was checked).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. Only the keys above are read.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-ArcPrerequisites.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    az login --tenant <tenant-id>
    ./Test-ArcPrerequisites.azcli.ps1 -InfrastructureFile ./infrastructure.yml
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
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
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# The Azure CLI is started through a command file on Windows. These characters would be read as commands there, so no value that holds one is sent.
$UnsafeArgument = '[&|<>^%"`\r\n]'
# Microsoft Learn, Assign required permissions for Azure Local deployment: the roles that register the machines as Arc resources, unless the account owns the resource group.
$OwnerRole = 'Owner'
$ArcRegistrationRole = @('Azure Connected Machine Onboarding', 'Azure Connected Machine Resource Administrator')

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Prop($Object, [string[]]$Path) {
    $node = $Object
    foreach ($part in $Path) {
        if ($null -eq $node) { return $null }
        if ($node -is [System.Collections.IDictionary]) { if ($node.Contains($part)) { $node = $node[$part] } else { return $null } }
        elseif ($node.PSObject.Properties[$part]) { $node = $node.PSObject.Properties[$part].Value }
        else { return $null }
    }
    $node
}

# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the exit code, stdout and stderr.
function Invoke-AzCli([string[]]$Arguments) {
    foreach ($argument in $Arguments) {
        if ($argument -match $UnsafeArgument) { throw "An argument holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote): $argument" }
    }
    $all = @(& az @Arguments 2>&1)
    $code = [int](Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err; Detail = $(if ($err) { $err.Trim() } else { $out.Trim() }) }
}
function ConvertFrom-AzJson([string]$Text) { if ($Text -and $Text.Trim()) { $Text | ConvertFrom-Json -Depth 20 } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The Arc machines are registered into it.' }
if ($group -match $UnsafeArgument) { Exit-InputProblem 'azure.resource_group holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote).' }
$providers = @(Get-AzlArmMandatoryProvider)

Write-Line "Arc registration prerequisites (Azure): subscription $subscriptionId, resource group '$group', $($providers.Count) resource providers"
if (-not $PSCmdlet.ShouldProcess("the Azure prerequisites of the Arc registration in resource group '$group'", 'Check')) {
    foreach ($line in @('Subscription is Enabled and in the tenant of the file', 'Resource group exists and is Succeeded', "$($providers.Count) resource providers are Registered", 'The signed-in account can register Arc machines in the resource group')) { Write-Line "[plan]    $line" }
    Write-Line 'Planned only: run again without -WhatIf to run the checks.'
    exit 0
}

# ---- preconditions (read only)
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>.' }
$account = Invoke-AzCli @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors')
if ($account.ExitCode -ne 0) { Exit-Failed "Not signed in to the Azure CLI for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($account.Detail)" }
$accountInfo = ConvertFrom-AzJson $account.Output
if ([string](Get-Prop $accountInfo @('tenantId')) -ne $tenantId) { Exit-Failed "The Azure CLI is signed in to tenant $(Get-Prop $accountInfo @('tenantId')), but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Check, [string]$Result, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Check = $Check; Result = $Result; Detail = $Detail })
    $tag = switch ($Result) { 'Failed' { '[FAIL] ' } 'Skipped' { '[SKIP] ' } default { '[PASS] ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Check, $(if ($Detail) { " - $Detail" } else { '' }))
}

# 1. Subscription
$subscriptionState = [string](Get-Prop $accountInfo @('state'))
Add-Check "subscription $subscriptionId is Enabled" $(if ($subscriptionState -eq 'Enabled') { 'Passed' } else { 'Failed' }) $subscriptionState

# 2. Resource group
$rg = Invoke-AzCli @('group', 'show', '--subscription', $subscriptionId, '--name', $group, '--output', 'json', '--only-show-errors')
if ($rg.ExitCode -ne 0) { Add-Check "resource group $group" 'Failed' $(if ($rg.Detail -match $NotFound) { 'not found. Create it first (phase 02).' } else { $rg.Detail }) }
else {
    $rgState = [string](Get-Prop (ConvertFrom-AzJson $rg.Output) @('properties', 'provisioningState'))
    Add-Check "resource group $group exists" $(if ($rgState -eq 'Succeeded') { 'Passed' } else { 'Failed' }) $rgState
}

# 3. Resource providers
foreach ($provider in $providers) {
    $state = Invoke-AzCli @('provider', 'show', '--namespace', $provider, '--subscription', $subscriptionId, '--query', 'registrationState', '--output', 'tsv', '--only-show-errors')
    if ($state.ExitCode -ne 0) { Add-Check "resource provider $provider" 'Failed' "could not be read: $($state.Detail)"; continue }
    Add-Check "resource provider $provider is Registered" $(if ($state.Output.Trim() -eq 'Registered') { 'Passed' } else { 'Failed' }) $state.Output.Trim()
}

# 4. Roles of the signed-in account
$roleCheck = 'roles to register Arc machines'
try {
    $userType = ([string](Get-Prop $accountInfo @('user', 'type'))).ToLowerInvariant()
    $userName = [string](Get-Prop $accountInfo @('user', 'name'))
    $lookup = switch ($userType) {
        'user' { @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv', '--only-show-errors') }
        'serviceprincipal' { @('ad', 'sp', 'show', '--id', $userName, '--query', 'id', '--output', 'tsv', '--only-show-errors') }
        default { $null }
    }
    if (-not $lookup) { throw "The sign-in is of type '$userType'; only a user or a service principal is checked." }
    $objectId = Invoke-AzCli $lookup
    if ($objectId.ExitCode -ne 0 -or -not $objectId.Output.Trim()) { throw "The directory object of the signed-in account could not be read: $($objectId.Detail)" }
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$group"
    $roleArguments = @('role', 'assignment', 'list', '--assignee', $objectId.Output.Trim(), '--scope', $scope, '--include-inherited')
    # Groups are expanded for a user only: Azure CLI reference, az role assignment list --include-groups (the groups of which the user is a member).
    if ($userType -eq 'user') { $roleArguments += '--include-groups' }
    $roles = Invoke-AzCli ($roleArguments + @('--query', '[].roleDefinitionName', '--output', 'json', '--only-show-errors'))
    if ($roles.ExitCode -ne 0) { throw "The role assignments could not be read: $($roles.Detail)" }
    $held = @(@(ConvertFrom-AzJson $roles.Output) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $missing = @($ArcRegistrationRole | Where-Object { $_ -notin $held })
    if ($OwnerRole -in $held) { Add-Check $roleCheck 'Passed' "$OwnerRole at or above the resource group" }
    elseif ($missing.Count -eq 0) { Add-Check $roleCheck 'Passed' ($ArcRegistrationRole -join ' and ') }
    else { Add-Check $roleCheck 'Failed' "missing at or above the resource group: $($missing -join ', '). Assign them, or use an owner of the resource group." }
}
catch { Add-Check $roleCheck 'Failed' $_.Exception.Message }

$failed = @($rows | Where-Object Result -EQ 'Failed').Count
$passed = @($rows | Where-Object Result -EQ 'Passed').Count
Write-Line "Summary: $passed passed, $failed failed"
$rows
if ($failed -gt 0) { exit 1 }
exit 0
