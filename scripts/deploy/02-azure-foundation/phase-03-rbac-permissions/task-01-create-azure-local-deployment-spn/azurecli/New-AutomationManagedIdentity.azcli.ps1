<#
.SYNOPSIS
    Creates the user-assigned managed identity that azure.automation_identity of infrastructure.yml names, with the Azure CLI.

.DESCRIPTION
    Phase 03 (RBAC and permissions), Task 01 (the identity that runs the automation), Azure CLI variant of New-AutomationManagedIdentity.ps1. When
    azure.automation_identity.type is managed_identity, this script creates the user-assigned managed identity of that name ("az identity create") in
    the subscription and resource group the entry gives (else the subscription and resource group of the instance, azure.subscription_id and
    azure.resource_group), in the region azure.location. A managed identity has no secret to store or rotate, which is why the file prefers it.

    It creates only the identity. It assigns no role (Set-EntraGroupRoleAssignments.azcli.ps1 and the role assignment task do that), it does not
    create the resource group (the landing zone resource group task does), and it does not touch a service principal: when the entry says
    service_principal, the CI/CD bootstrap (phase 01 task 01 of the CI/CD infrastructure) creates that app registration and this script stops with
    exit 2.

    Idempotent. If the identity already exists the script changes nothing and reports its client id and principal id, so a second run with the same
    file creates nothing. If the existing identity is in another region than azure.location, that is reported as a difference and nothing is changed
    (a managed identity cannot move). -WhatIf changes nothing.

    The client id and the principal id are not secrets. The script reports them; record the client id in azure.automation_identity.client_id (the
    pipelines read it there) and use the principal id for role assignments.

    The script reads Azure to find the identity (read only) and writes only with "az identity create", behind -WhatIf. It does not sign in: run
    "az login --tenant <azure.tenant_id>" first. You need Managed Identity Contributor (or Contributor) on the resource group. The tags in the
    file-level tags map are put on the identity.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                                the tenant the sign-in must belong to
        azure.location                                 the region of the identity
        azure.subscription_id, azure.resource_group    the place when the entry has none
        tags                                           tags for the identity (optional)
        azure.automation_identity.type                 must be managed_identity
        azure.automation_identity.name                 the name of the identity
        azure.automation_identity.subscription_id      the subscription that holds it (optional)
        azure.automation_identity.resource_group       the resource group that holds it (optional)

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 the identity exists (created now, already there, or planned under -WhatIf); 1 an Azure call failed or a precondition failed (az
    missing, not signed in, wrong tenant, the resource group does not exist, the creation failed); 2 a value in the file is missing or not usable, or
    the identity is not a managed identity.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-AutomationManagedIdentity.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the identity would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-AutomationManagedIdentity.azcli.ps1 -InfrastructureFile ./infrastructure.yml

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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = '(?i)ResourceNotFound|NotFound|not found|could not be found|does not exist|\b404\b'
$GroupNotFound = '(?i)ResourceGroupNotFound|Resource group ''[^'']*'' could not be found'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# One az call. Returns the text of standard output; throws, with the error text, when az ends with an error (warnings on standard error are dropped).
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgument)
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $AzArgument
    if ($unsafe) { Exit-InputProblem $unsafe }
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
$location = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')).Trim()
$defaultSubscription = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
$defaultGroup = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.resource_group')).Trim()
$identity = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.automation_identity'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
# The tags go into az arguments: refuse a key or a value that az.cmd cannot carry before any Azure call (also under -WhatIf).
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = $rawTags })
if ($problem) { Exit-InputProblem $problem }
$tags = [ordered]@{}
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

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A name that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.automation_identity.resource_group (or azure.resource_group)' = $resourceGroup; 'azure.location' = $location })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use New-AutomationManagedIdentity.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Managed identity '$name' in resource group '$resourceGroup' ($location)"

$row = [ordered]@{ Name = $name; Action = ''; ClientId = ''; PrincipalId = ''; Detail = '' }
$query = '{clientId:clientId,principalId:principalId,location:location}'
try {
    $existing = $null
    try { $existing = Invoke-Az -AzArgument @('identity', 'show', '--name', $name, '--resource-group', $resourceGroup, '--subscription', $subscriptionId, '--query', $query, '--output', 'json') | ConvertFrom-Json }
    catch {
        if ($_.Exception.Message -match $GroupNotFound) { Exit-Failed "The resource group '$resourceGroup' does not exist in the subscription. Create it first (the landing zone resource group task)." }
        if ($_.Exception.Message -notmatch $NotFound) { throw }
    }

    if ($existing) {
        $row.Action = 'AlreadyExists'; $row.ClientId = [string]$existing.clientId; $row.PrincipalId = [string]$existing.principalId
        Write-Line "[exists]  '$name' is already there, nothing changed."
        $existingLocation = if ($existing.PSObject.Properties['location']) { [string]$existing.location } else { '' }
        if ($existingLocation -and ($existingLocation -replace '\s', '').ToLowerInvariant() -ne ($location -replace '\s', '').ToLowerInvariant()) {
            $row.Detail = "Differs from the file (region is $existingLocation, azure.location is $location); left unchanged. A managed identity cannot move: create a new one if the region must change."
            Write-Warning "${name}: $($row.Detail)"
        }
    }
    elseif ($PSCmdlet.ShouldProcess("managed identity '$name' in '$resourceGroup'", 'Create user-assigned managed identity')) {
        $create = @('identity', 'create', '--name', $name, '--resource-group', $resourceGroup, '--location', $location, '--subscription', $subscriptionId)
        if ($tags.Count) { $create += @('--tags') + @($tags.Keys | ForEach-Object { "$_=$($tags[$_])" }) }
        $created = Invoke-Az -AzArgument ($create + @('--query', $query, '--output', 'json')) | ConvertFrom-Json
        $row.Action = 'Created'; $row.ClientId = [string]$created.clientId; $row.PrincipalId = [string]$created.principalId
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
