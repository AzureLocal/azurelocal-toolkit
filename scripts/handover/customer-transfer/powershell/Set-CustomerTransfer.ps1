<#
.SYNOPSIS
    Gives the customer administrator access to the Azure Local resources in Azure and writes the transfer record.

.DESCRIPTION
    Handover, customer transfer. For the instance that infrastructure.yml describes (cluster.name in the resource group azure.resource_group of
    the subscription azure.subscription_id) the script:
      1. looks the customer administrator up in Microsoft Entra ID (by user principal name, then by mail for a guest);
      2. assigns the Contributor role on the resource group and the Reader role on the subscription, when the administrator does not have them
         (Microsoft Learn: Assign Azure roles using Azure PowerShell, New-AzRoleAssignment);
      3. counts the role assignments the administrator now has;
      4. writes the transfer record: a Markdown page and a JSON file in -OutputPath (when it is given).

    The script no longer touches the cluster nodes: the earlier step that was meant to add the customer administrator to the local
    Administrators group of every node only printed "manual configuration required", and local access is the customer's decision (a domain
    group, see identity.active_directory.security_groups). The record says so.

    Idempotent. A role the administrator already has is reported and not assigned again. The script never removes a role assignment.
    -WhatIf reads Azure and changes nothing, and writes no file.

    The script does not sign in: run Connect-AzAccount to the tenant in azure.tenant_id first, with an account that may create role assignments
    (Owner or User Access Administrator). It changes the subscription of the session while it works and puts it back.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name, azure.tenant_id, azure.subscription_id, azure.resource_group, site.customer

    Exit codes: 0 the transfer is in place (assigned now, already there, planned under -WhatIf) and the record is written; 1 an Azure call failed or a
    precondition failed (not signed in, wrong tenant, Az modules missing, the administrator not found, an assignment failed); 2 a value in the file or
    a parameter is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER CustomerTenantId
    The customer's Microsoft Entra tenant id (a GUID). It is put in the portal link of the record.

.PARAMETER CustomerAdminUPN
    The user principal name (or mail address of a guest) of the customer administrator.

.PARAMETER OutputPath
    Optional. The folder for the transfer record (Markdown and JSON). It is created when it does not exist. Without it nothing is written.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Set-CustomerTransfer.ps1 -InfrastructureFile ./infrastructure.yml -CustomerTenantId <tenant-id> -CustomerAdminUPN admin@improbability.cloud -WhatIf

    Shows which roles would be assigned and writes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Set-CustomerTransfer.ps1 -InfrastructureFile ./infrastructure.yml -CustomerTenantId <tenant-id> -CustomerAdminUPN admin@improbability.cloud -OutputPath ./handover

    Assigns the roles and writes the transfer record. Run it again: the roles are reported as already assigned.
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

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
# The two roles of the transfer: the customer administrator manages the resource group and can read the subscription.
$ResourceGroupRole = 'Contributor'
$SubscriptionRole = 'Reader'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

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
if ($CustomerTenantId.Trim() -notmatch $Guid) { Exit-InputProblem '-CustomerTenantId is not a GUID.' }
$admin = $CustomerAdminUPN.Trim()
if ($admin -notmatch '^[^@\s]+@[^@\s]+$') { Exit-InputProblem '-CustomerAdminUPN is not a user principal name (name@domain).' }
$CustomerTenantId = $CustomerTenantId.Trim()

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzADUser', 'Get-AzRoleAssignment', 'New-AzRoleAssignment') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts, Az.Resources modules: Install-Module Az.Accounts, Az.Resources -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

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
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop

    $user = $null
    try { $user = Get-AzADUser -UserPrincipalName $admin -ErrorAction Stop } catch { Write-Verbose "No user with the user principal name: $($_.Exception.Message)" }
    if (-not $user) {
        $escaped = $admin.Replace("'", "''")
        try { $user = Get-AzADUser -Filter "mail eq '$escaped'" -ErrorAction Stop } catch { Write-Verbose "No user with that mail address: $($_.Exception.Message)" }
    }
    $user = @($user) | Select-Object -First 1
    if (-not $user) {
        Add-Step 'Customer administrator' 'Failed' "$admin was not found in Microsoft Entra ID. A guest may have to be invited first."
    }
    else {
        Add-Step 'Customer administrator' 'Found' $admin
        foreach ($assignment in @(@{ Role = $ResourceGroupRole; Scope = $scopeGroup; Where = "resource group $resourceGroup" }, @{ Role = $SubscriptionRole; Scope = $scopeSubscription; Where = 'the subscription' })) {
            $step = "Azure role $($assignment.Role) on $($assignment.Where)"
            try {
                $existing = @(Get-AzRoleAssignment -ObjectId $user.Id -Scope $assignment.Scope -RoleDefinitionName $assignment.Role -ErrorAction Stop)
                if ($existing.Count -gt 0) { Add-Step $step 'AlreadyAssigned'; continue }
                if ($PSCmdlet.ShouldProcess("$admin on $($assignment.Scope)", "Assign the role $($assignment.Role)")) {
                    $null = New-AzRoleAssignment -ObjectId $user.Id -Scope $assignment.Scope -RoleDefinitionName $assignment.Role -ErrorAction Stop
                    Add-Step $step 'Assigned'
                }
                else { Add-Step $step 'WouldAssign' }
            }
            catch { Add-Step $step 'Failed' $_.Exception.Message }
        }
        try {
            $all = @(Get-AzRoleAssignment -ObjectId $user.Id -ErrorAction Stop)
            Add-Step 'Role assignments of the administrator' 'Verified' "$($all.Count) role assignment(s) in the subscription"
        }
        catch { Add-Step 'Role assignments of the administrator' 'Failed' $_.Exception.Message }
    }
    Add-Step 'Local administrator access on the nodes' 'Skipped' 'Not changed by this script. Give the customer a domain group (identity.active_directory.security_groups) and add it to the local Administrators group.'
}
catch { Add-Step 'Azure' 'Failed' $_.Exception.Message }
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
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
