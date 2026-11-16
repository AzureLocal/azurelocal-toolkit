<#
.SYNOPSIS
    Gives the customer administrator access to the Azure Local resources in Azure with the Azure CLI and writes the transfer record.

.DESCRIPTION
    Stage 07 (validation and handover), task 06, Azure CLI variant of Set-CustomerTransfer.ps1. It does the same with az commands, for a host that has the Azure CLI and not the
    Az PowerShell modules. For the instance that infrastructure.yml describes (cluster.name in the resource group azure.resource_group of the subscription azure.subscription_id):

      1. looks the customer administrator up in Microsoft Entra ID: az ad user show --id <user principal name>, then, for a guest, az ad user list --filter "mail eq '<mail>'";
      2. assigns the built-in role Contributor on the resource group and Reader on the subscription when the administrator does not have them
         (az role assignment list, then az role assignment create --assignee-object-id --assignee-principal-type User --role --scope; Microsoft Learn: Assign Azure roles using Azure CLI);
      3. counts the role assignments the administrator now has;
      4. writes the transfer record: a Markdown page and a JSON file in -OutputPath (when it is given).

    Idempotent. A role the administrator already has is reported and not assigned again. The script never removes a role assignment. -WhatIf reads Azure and changes nothing,
    and writes no file. The script does not sign in: run az login --tenant <azure.tenant_id> first, with an account that may create role assignments (Owner or User Access
    Administrator). It selects azure.subscription_id with az account set and puts the earlier subscription back at the end. It does not touch the cluster nodes: local access
    is the customer's decision (a domain group, see identity.active_directory.security_groups), and the record says so.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure): cluster.name, azure.tenant_id, azure.subscription_id, azure.resource_group, site.customer.

    Exit codes: 0 the transfer is in place (assigned now, already there, planned under -WhatIf) and the record is written; 1 an az call failed or a precondition failed (az missing,
    not signed in, wrong tenant, the administrator not found, an assignment failed); 2 a value in the file or a parameter is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read.

.PARAMETER CustomerTenantId
    The customer's Microsoft Entra tenant id (a GUID). It is put in the portal link of the record.

.PARAMETER CustomerAdminUPN
    The user principal name (or mail address of a guest) of the customer administrator.

.PARAMETER OutputPath
    Optional. The folder for the transfer record (Markdown and JSON). It is created when it does not exist. Without it nothing is written.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Set-CustomerTransfer.azcli.ps1 -InfrastructureFile ./infrastructure.yml -CustomerTenantId <tenant-id> -CustomerAdminUPN admin@improbability.cloud -WhatIf

    Shows which roles would be assigned and writes nothing.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [Parameter(Mandatory)][string]$CustomerTenantId,
    [Parameter(Mandatory)][string]$CustomerAdminUPN,
    [string]$OutputPath,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
# The Azure CLI is started through a command file on Windows. These characters would be read as commands there, so no value that holds one is sent.
$UnsafeArgument = '[&|<>^%"`\r\n]'
# The two roles of the transfer: the customer administrator manages the resource group and can read the subscription. They are the definition of the handover (Azure built-in
# role names, Microsoft Learn: Azure built-in roles), not a setting of a deployment: access beyond these two roles is the customer's own decision after the transfer.
$ResourceGroupRole = 'Contributor'
$SubscriptionRole = 'Reader'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

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

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$clusterName = Get-Text 'cluster.name'
$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$resourceGroup = Get-Text 'azure.resource_group'
$customer = Get-Text 'site.customer'

if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. It is the name of the Azure Local instance that is handed over.' }
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $resourceGroup) { Exit-InputProblem 'azure.resource_group is missing. The roles are assigned on it.' }
if ($resourceGroup -match $UnsafeArgument -or $resourceGroup -match '\s') { Exit-InputProblem 'azure.resource_group holds a character that is not sent to the Azure CLI.' }
if ($CustomerTenantId.Trim() -notmatch $Guid) { Exit-InputProblem '-CustomerTenantId is not a GUID.' }
$admin = $CustomerAdminUPN.Trim()
if ($admin -notmatch '^[^@\s]+@[^@\s]+$' -or $admin -match $UnsafeArgument) { Exit-InputProblem '-CustomerAdminUPN is not a user principal name (name@domain).' }
$CustomerTenantId = $CustomerTenantId.Trim()

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Set-CustomerTransfer.ps1.' }
$account = Invoke-AzCli @('account', 'show', '--query', '[tenantId,id]', '--output', 'tsv')
if ($account.ExitCode -ne 0) { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
$accountParts = @($account.Output -split '\s+' | Where-Object { $_ })
if ($accountParts.Count -lt 1 -or $accountParts[0] -ne $tenantId) { Exit-Failed "Signed in to tenant $(if ($accountParts.Count) { $accountParts[0] } else { '(unknown)' }), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalSubscription = if ($accountParts.Count -gt 1) { $accountParts[1] } else { '' }

$steps = [System.Collections.Generic.List[object]]::new()
function Add-Step([string]$Step, [string]$Status, [string]$Detail = '') {
    $steps.Add([pscustomobject][ordered]@{ Step = $Step; Status = $Status; Detail = $Detail; Time = (Get-Date -Format 'HH:mm:ss') })
    $tag = switch ($Status) { 'Failed' { '[failed] ' } 'AlreadyAssigned' { '[exists] ' } 'Skipped' { '[skip]   ' } { $_ -like 'Would*' } { '[plan]   ' } default { '[done]   ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Step, $Status, $(if ($Detail) { " ($Detail)" } else { '' }))
}

Write-Line "Customer transfer of '$clusterName' to $admin"
$scopeGroup = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
$scopeSubscription = "/subscriptions/$subscriptionId"
try {
    $set = Invoke-AzCli @('account', 'set', '--subscription', $subscriptionId)
    if ($set.ExitCode -ne 0) { throw "The subscription could not be selected: $($set.Detail)" }

    $userId = ''
    $byName = Invoke-AzCli @('ad', 'user', 'show', '--id', $admin, '--query', 'id', '--output', 'tsv')
    if ($byName.ExitCode -eq 0 -and $byName.Output.Trim() -match $Guid) { $userId = $byName.Output.Trim() }
    else {
        $byMail = Invoke-AzCli @('ad', 'user', 'list', '--filter', "mail eq '$admin'", '--query', '[0].id', '--output', 'tsv')
        if ($byMail.ExitCode -eq 0 -and $byMail.Output.Trim() -match $Guid) { $userId = $byMail.Output.Trim() }
    }
    if (-not $userId) {
        Add-Step 'Customer administrator' 'Failed' "$admin was not found in Microsoft Entra ID. A guest may have to be invited first."
    }
    else {
        Add-Step 'Customer administrator' 'Found' $admin
        foreach ($assignment in @(@{ Role = $ResourceGroupRole; Scope = $scopeGroup; Where = "resource group $resourceGroup" }, @{ Role = $SubscriptionRole; Scope = $scopeSubscription; Where = 'the subscription' })) {
            $step = "Azure role $($assignment.Role) on $($assignment.Where)"
            try {
                $existing = Invoke-AzCli @('role', 'assignment', 'list', '--assignee', $userId, '--role', $assignment.Role, '--scope', $assignment.Scope, '--query', '[].id', '--output', 'tsv')
                if ($existing.ExitCode -ne 0) { throw "The role assignments could not be read: $($existing.Detail)" }
                if (@($existing.Output -split '\s+' | Where-Object { $_ }).Count -gt 0) { Add-Step $step 'AlreadyAssigned'; continue }
                if ($PSCmdlet.ShouldProcess("$admin on $($assignment.Scope)", "Assign the role $($assignment.Role)")) {
                    $create = Invoke-AzCli @('role', 'assignment', 'create', '--assignee-object-id', $userId, '--assignee-principal-type', 'User', '--role', $assignment.Role, '--scope', $assignment.Scope, '--output', 'none')
                    if ($create.ExitCode -ne 0) { throw $create.Detail }
                    Add-Step $step 'Assigned'
                }
                else { Add-Step $step 'WouldAssign' }
            }
            catch { Add-Step $step 'Failed' $_.Exception.Message }
        }
        $all = Invoke-AzCli @('role', 'assignment', 'list', '--assignee', $userId, '--all', '--query', '[].id', '--output', 'tsv')
        if ($all.ExitCode -eq 0) { Add-Step 'Role assignments of the administrator' 'Verified' "$(@($all.Output -split '\s+' | Where-Object { $_ }).Count) role assignment(s) in the subscription" }
        else { Add-Step 'Role assignments of the administrator' 'Failed' $all.Detail }
    }
    Add-Step 'Local administrator access on the nodes' 'Skipped' 'Not changed by this script. Give the customer a domain group (identity.active_directory.security_groups) and add it to the local Administrators group.'
}
catch { Add-Step 'Azure' 'Failed' $_.Exception.Message }
finally {
    if ($originalSubscription -and $originalSubscription -ne $subscriptionId) {
        $back = Invoke-AzCli @('account', 'set', '--subscription', $originalSubscription)
        if ($back.ExitCode -ne 0) { Write-Verbose "Could not restore the original subscription: $($back.Detail)" }
    }
}

# ---- the transfer record
$portalLink = "https://portal.azure.com/#@$CustomerTenantId/resource$scopeGroup"
$stamp = Get-Date -Format 'yyyyMMdd'
$recordRows = @($steps | ForEach-Object { "| $($_.Step) | $($_.Status) | $($_.Detail) | $($_.Time) |" }) -join "`n"
$markdown = @"
# Azure Local customer transfer

- Transfer date: $(Get-Date -Format 'yyyy-MM-dd')
- Customer: $(if ($customer) { $customer } else { 'not set (site.customer)' })
- Cluster: $clusterName
- Customer administrator: $admin

## Access

- Azure portal: $portalLink
- Subscription: $subscriptionId
- Resource group: $resourceGroup

## Assigned roles

| Role | Scope |
| --- | --- |
| $ResourceGroupRole | resource group $resourceGroup |
| $SubscriptionRole | subscription $subscriptionId |

## Steps

| Step | Status | Details | Time |
| --- | --- | --- | --- |
$recordRows
"@
$record = [ordered]@{ Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'); Customer = $customer; Cluster = $clusterName; CustomerAdmin = $admin; PortalLink = $portalLink; Steps = @($steps) }

if ($OutputPath) {
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write the transfer record')) {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
        $name = "Customer-Transfer-$clusterName-$stamp"
        Set-Content -LiteralPath (Join-Path $OutputPath "$name.md") -Value $markdown -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $OutputPath "$name.json") -Value ($record | ConvertTo-Json -Depth 6) -Encoding UTF8
        Write-Line "[done]    Transfer record written to $OutputPath ($name.md and $name.json)."
    }
    else { Write-Line "[plan]    The transfer record would be written to $OutputPath." }
}

$steps
$failed = @($steps | Where-Object Status -EQ 'Failed').Count
Write-Line "Summary: $(@($steps | Where-Object Status -In 'Assigned', 'AlreadyAssigned', 'Found', 'Verified').Count) done, $(@($steps | Where-Object Status -EQ 'Skipped').Count) skipped, $failed failed."
if ($failed -gt 0) { exit 1 }
exit 0
