<#
.SYNOPSIS
    Creates the Azure Monitor data collection endpoint that operations.monitoring of infrastructure.yml names.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 01 (Log Analytics workspace). Once the Log Analytics workspace exists, this script creates the
    data collection endpoint (DCE) of operations.monitoring.data_collection_endpoint in the resource group of the workspace
    (operations.monitoring.workspace_resource_group), in the region of the workspace, with public network access enabled. A DCE is the ingestion
    address the data collection rules and the Azure Monitor Agent send to; it must be in the region of the workspace it feeds, which is why the
    region is read from the workspace and not assumed.

    It creates only the endpoint. It does not create the workspace (the task's workspace script does), the data collection rule, or any
    association. The second half of the original deployment, the action group for alerts, is Deploy-ActionGroup.ps1 in the alerting task.

    When operations.monitoring.enabled is false the design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent. An endpoint that exists is reported as AlreadyExists and left alone (a region that differs from the workspace is reported), so
    a second run creates nothing. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzDataCollectionEndpoint, behind -WhatIf. It does not sign in: run
    Connect-AzAccount to the tenant in azure.tenant_id first. You need Monitoring Contributor (or Contributor) on the resource group. The tags in
    the file-level tags map are put on the endpoint. The workspace is looked up in azure.subscription_id.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.location (fallback region), tags
        operations.monitoring.enabled                    false means: do nothing
        operations.monitoring.log_analytics_workspace    the workspace that must exist
        operations.monitoring.workspace_resource_group   the resource group of the workspace and of the endpoint
        operations.monitoring.data_collection_endpoint   the endpoint name

    Exit codes: 0 the endpoint exists (created now, already there, planned under -WhatIf) or monitoring is switched off in the file; 1 an Azure
    call failed or a precondition failed (not signed in, wrong tenant, Az modules missing, the workspace does not exist, the creation failed);
    2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-DataCollectionEndpoint.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the endpoint would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-DataCollectionEndpoint.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the endpoint. Run it again: it is reported as AlreadyExists.
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
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'

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

function ConvertTo-RegionKey([string]$Region) { ($Region -replace '\s', '').ToLowerInvariant() }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$subscriptionId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')
$defaultLocation = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$monitoring = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

function Get-Field([string]$Key) {
    if ($monitoring -is [System.Collections.IDictionary] -and $monitoring.Contains($Key) -and $null -ne $monitoring[$Key]) { return ([string]$monitoring[$Key]).Trim() }
    ''
}

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($monitoring -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'operations.monitoring is missing. Describe the workspace and the data collection endpoint.' }
if ((Get-Field 'enabled').ToLowerInvariant() -eq 'false') {
    Write-Line 'operations.monitoring.enabled is false: Azure Monitor is not part of the design, so no data collection endpoint is created.'
    exit 0
}
$workspaceName = Get-Field 'log_analytics_workspace'
$group = Get-Field 'workspace_resource_group'
$endpointName = Get-Field 'data_collection_endpoint'
if (-not $workspaceName) { Exit-InputProblem 'operations.monitoring.log_analytics_workspace is missing.' }
if (-not $group) { Exit-InputProblem 'operations.monitoring.workspace_resource_group is missing.' }
if (-not $endpointName) { Exit-InputProblem 'operations.monitoring.data_collection_endpoint is missing. Name the endpoint to create.' }
if ($endpointName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}[A-Za-z0-9_]$|^[A-Za-z0-9]$') { Exit-InputProblem "operations.monitoring.data_collection_endpoint '$endpointName' is not a valid name (1 to 64 letters, digits, . _ -; starts with a letter or digit)." }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder. The workspace is looked up there.' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzOperationalInsightsWorkspace', 'Get-AzDataCollectionEndpoint', 'New-AzDataCollectionEndpoint') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts, Az.OperationalInsights and Az.Monitor modules: Install-Module Az.Accounts, Az.OperationalInsights, Az.Monitor -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$row = [ordered]@{ Endpoint = $endpointName; Action = ''; Location = ''; Detail = '' }
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop

    # the workspace must exist, and its region is the region of the endpoint
    $workspace = $null
    try { $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $group -Name $workspaceName -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The Log Analytics workspace '$workspaceName' could not be read: $($_.Exception.Message)" } }
    if (-not $workspace) { Exit-Failed "The Log Analytics workspace '$workspaceName' does not exist in '$group'. Create it first (the workspace script of this task)." }
    $region = if ($workspace.PSObject.Properties['Location'] -and $workspace.Location) { [string]$workspace.Location } else { $defaultLocation }
    if (-not $region) { Exit-InputProblem 'No region: the workspace reports none and azure.location is empty.' }
    $row.Location = $region
    Write-Line "Data collection endpoint '$endpointName' in '$group' ($region), for the workspace '$workspaceName'"

    $existing = $null
    try { $existing = Get-AzDataCollectionEndpoint -Name $endpointName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        Write-Line "[exists]  '$endpointName' is already there, nothing changed."
        $existingRegion = if ($existing.PSObject.Properties['Location']) { [string]$existing.Location } else { '' }
        if ($existingRegion -and (ConvertTo-RegionKey $existingRegion) -ne (ConvertTo-RegionKey $region)) {
            $row.Detail = "Differs from the workspace (the endpoint is in $existingRegion, the workspace in $region); left unchanged. An endpoint cannot move: create a new one if the region must change."
            Write-Warning "${endpointName}: $($row.Detail)"
        }
    }
    elseif ($PSCmdlet.ShouldProcess("data collection endpoint '$endpointName' in '$group'", "Create ($region, public network access enabled)")) {
        $arguments = @{ Name = $endpointName; ResourceGroupName = $group; SubscriptionId = $subscriptionId; Location = $region; NetworkAclsPublicNetworkAccess = 'Enabled'; ErrorAction = 'Stop' }
        if ($tags.Count) { $arguments.Tag = $tags }
        $null = New-AzDataCollectionEndpoint @arguments
        $row.Action = 'Created'
        Write-Line "[created] '$endpointName'."
    }
    else {
        $row.Action = 'WouldCreate'
        Write-Line "[plan]    '$endpointName' would be created."
    }
}
catch {
    $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
    Write-Warning "${endpointName}: $($row.Detail)"
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
