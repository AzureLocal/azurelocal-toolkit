<#
.SYNOPSIS
    Creates the user-assigned managed identity that azure.automation_identity of infrastructure.yml names.

.DESCRIPTION
    Phase 03 (RBAC and permissions), Task 01 (the identity that runs the automation). When azure.automation_identity.type is managed_identity,
    this script creates the user-assigned managed identity of that name in the subscription and resource group the entry gives (else the
    subscription and resource group of the instance, azure.subscription_id and azure.resource_group), in the region azure.location. A
    managed identity has no secret to store or rotate, which is why the file prefers it.

    It creates only the identity. It assigns no role (Set-EntraGroupRoleAssignments.ps1 and the role assignment task do that), it does not
    create the resource group (the landing zone resource group task does), and it does not touch a service principal: when the entry says
    service_principal, the CI/CD bootstrap (phase 01 task 01 of the CI/CD infrastructure) creates that app registration and this script
    stops with exit 2.

    Idempotent. If the identity already exists the script changes nothing and reports its client id and principal id, so a second run with
    the same file creates nothing. If the existing identity is in another region than azure.location, that is reported as a difference and
    nothing is changed (a managed identity cannot move). -WhatIf changes nothing.

    The client id and the principal id are not secrets. The script reports them; record the client id in azure.automation_identity.client_id
    (the pipelines read it there) and use the principal id for role assignments.

    The script reads Azure to find the identity (read only) and writes only with New-AzUserAssignedIdentity, behind -WhatIf. It does not sign
    in: run Connect-AzAccount to the tenant in azure.tenant_id first. You need Managed Identity Contributor (or Contributor) on the resource
    group. The tags in the file-level tags map are put on the identity.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                                the tenant the sign-in must belong to
        azure.location                                 the region of the identity
        azure.subscription_id, azure.resource_group    the place when the entry has none
        tags                                           tags for the identity (optional)
        azure.automation_identity.type                 must be managed_identity
        azure.automation_identity.name                 the name of the identity
        azure.automation_identity.subscription_id      the subscription that holds it (optional)
        azure.automation_identity.resource_group       the resource group that holds it (optional)

    Exit codes: 0 the identity exists (created now, already there, or planned under -WhatIf); 1 an Azure call failed or a precondition failed
    (not signed in, wrong tenant, Az modules missing, the resource group does not exist, the creation failed); 2 a value in the file is
    missing or not usable, or the identity is not a managed identity.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-AutomationManagedIdentity.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the identity would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./New-AutomationManagedIdentity.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the identity and prints its client id and principal id. Run it again: it is reported as AlreadyExists.
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

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'ResourceNotFound|NotFound|could not be found|does not exist|\b404\b'
$GroupNotFound = 'ResourceGroupNotFound|Resource group ''[^'']*'' could not be found'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}

function Exit-InputProblem([string]$Message) {
    Write-Error $Message -ErrorAction Continue
    exit 2
}

function Exit-Failed([string]$Message) {
    Write-Error $Message -ErrorAction Continue
    exit 1
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$location = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$defaultSubscription = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')
$defaultGroup = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.resource_group')
$identity = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.automation_identity'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

function Get-Field([string]$Key) {
    if ($identity -is [System.Collections.IDictionary] -and $identity.Contains($Key) -and $null -ne $identity[$Key]) { return ([string]$identity[$Key]).Trim() }
    ''
}

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($identity -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'azure.automation_identity is missing. Give it a type (managed_identity) and a name.' }
$type = Get-Field 'type'
if ($type -eq 'service_principal') { Exit-InputProblem 'azure.automation_identity.type is service_principal. That identity is an app registration; the CI/CD bootstrap creates it. This script creates a managed identity only.' }
if ($type -ne 'managed_identity') { Exit-InputProblem "azure.automation_identity.type '$type' is missing or is not managed_identity." }
$name = Get-Field 'name'
if (-not $name) { Exit-InputProblem 'azure.automation_identity.name is missing.' }
if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$') { Exit-InputProblem "azure.automation_identity.name '$name' is not a valid managed identity name (3 to 128 letters, digits, hyphens and underscores; starts with a letter or digit)." }
$subscriptionId = if (Get-Field 'subscription_id') { Get-Field 'subscription_id' } else { $defaultSubscription }
$resourceGroup = if (Get-Field 'resource_group') { Get-Field 'resource_group' } else { $defaultGroup }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'No usable subscription: azure.automation_identity.subscription_id and azure.subscription_id are empty or not a GUID.' }
if (-not $resourceGroup) { Exit-InputProblem 'No resource group: azure.automation_identity.resource_group and azure.resource_group are empty.' }
if (-not $location) { Exit-InputProblem 'azure.location is missing. It is the region of the identity.' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Get-AzUserAssignedIdentity', 'New-AzUserAssignedIdentity') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.ManagedServiceIdentity modules: Install-Module Az.Accounts, Az.ManagedServiceIdentity -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Managed identity '$name' in resource group '$resourceGroup' ($location)"

$row = [ordered]@{ Name = $name; Action = ''; ClientId = ''; PrincipalId = ''; Detail = '' }
try {
    $existing = $null
    try { $existing = Get-AzUserAssignedIdentity -ResourceGroupName $resourceGroup -Name $name -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch {
        if ($_.Exception.Message -match $GroupNotFound) { Exit-Failed "The resource group '$resourceGroup' does not exist in the subscription. Create it first (the landing zone resource group task)." }
        if ($_.Exception.Message -notmatch $NotFound) { throw }
    }

    if ($existing) {
        $row.Action = 'AlreadyExists'; $row.ClientId = [string]$existing.ClientId; $row.PrincipalId = [string]$existing.PrincipalId
        Write-Line "[exists]  '$name' is already there, nothing changed."
        $existingLocation = if ($existing.PSObject.Properties['Location']) { [string]$existing.Location } else { '' }
        if ($existingLocation -and ($existingLocation -replace '\s', '').ToLowerInvariant() -ne ($location -replace '\s', '').ToLowerInvariant()) {
            $row.Detail = "Differs from the file (region is $existingLocation, azure.location is $location); left unchanged. A managed identity cannot move: create a new one if the region must change."
            Write-Warning "${name}: $($row.Detail)"
        }
    }
    elseif ($PSCmdlet.ShouldProcess("managed identity '$name' in '$resourceGroup'", 'Create user-assigned managed identity')) {
        $arguments = @{ ResourceGroupName = $resourceGroup; Name = $name; Location = $location; SubscriptionId = $subscriptionId; ErrorAction = 'Stop' }
        if ($tags.Count) { $arguments.Tag = $tags }
        $created = New-AzUserAssignedIdentity @arguments
        $row.Action = 'Created'; $row.ClientId = [string]$created.ClientId; $row.PrincipalId = [string]$created.PrincipalId
        Write-Line "[created] '$name' created."
    }
    else {
        $row.Action = 'WouldCreate'
        Write-Line "[plan]    '$name' would be created."
    }
}
catch {
    $detail = $_.Exception.Message
    if ($detail -match $GroupNotFound) { $detail = "The resource group '$resourceGroup' does not exist in the subscription. Create it first (the landing zone resource group task). $detail" }
    $row.Action = 'Failed'; $row.Detail = $detail
    Write-Warning "${name}: $detail"
}

if ($row.ClientId) { Write-Line "Client id: $($row.ClientId). Record it in azure.automation_identity.client_id. Principal id (for role assignments): $($row.PrincipalId)." }
[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
