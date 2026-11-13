<#
.SYNOPSIS
    Creates the Log Analytics workspace that operations.monitoring of infrastructure.yml names.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 01 (Log Analytics workspace). This script creates the one Log Analytics workspace of the
    design, operations.monitoring.log_analytics_workspace, in the resource group operations.monitoring.workspace_resource_group, in the region
    azure.location. It is the workspace Insights for Azure Local sends to.

    It creates only that workspace. It does not create the resource group (the Azure foundation stage does; a missing group is a failure), the
    data collection endpoint (Deploy-DataCollectionEndpoint.ps1), the data collection rule (Enable-HciInsights.ps1) or an action group
    (Deploy-ActionGroup.ps1). It creates no second workspace for security operations and turns on no paid security service: the toolkit turns
    on nothing paid.

    The pricing tier is not set. A new workspace is pay-as-you-go, which is the only tier that fits this use: the commitment tiers start at
    100 GB a day and the legacy tiers are closed to new customers. The retention is operations.monitoring.retention_days when the file sets it;
    without it the workspace gets the Azure default of 30 days. Microsoft Learn says retention beyond 31 days is charged.

    When operations.monitoring.enabled is false the design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent. A workspace that exists is reported as AlreadyExists and left alone (a region or a retention that differs from the file is
    reported, not changed), so a second run creates nothing. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzOperationalInsightsWorkspace, behind -WhatIf. It does not sign in: run
    Connect-AzAccount to the tenant in azure.tenant_id first. You need Log Analytics Contributor (or Contributor) on the resource group. The
    tags in the file-level tags map are put on the workspace. The workspace is created in azure.subscription_id.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.location, tags
        operations.monitoring.enabled                    false means: do nothing
        operations.monitoring.log_analytics_workspace    the workspace name
        operations.monitoring.workspace_resource_group   the resource group of the workspace; it must exist
        operations.monitoring.retention_days             optional; the retention of a workspace the script creates (30 to 730)

    Exit codes: 0 the workspace exists (created now, already there, planned under -WhatIf) or monitoring is switched off in the file; 1 an Azure
    call failed or a precondition failed (not signed in, wrong tenant, Az modules missing, the resource group does not exist, the creation
    failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-LogAnalyticsWorkspace.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the workspace would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-LogAnalyticsWorkspace.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the workspace. Run it again: it is reported as AlreadyExists.
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

function Get-Text([string]$Path) {
    $value = Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path
    if ($null -eq $value) { return '' }
    ([string]$value).Trim()
}

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$region = Get-Text 'azure.location'
$monitoring = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid -or $tenantId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.tenant_id is missing, not a GUID or the all-zero placeholder. It is the tenant the sign-in must belong to.' }
if ($monitoring -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'operations.monitoring is missing. Describe the Log Analytics workspace.' }
if ((Get-Text 'operations.monitoring.enabled').ToLowerInvariant() -eq 'false') {
    Write-Line 'operations.monitoring.enabled is false: Azure Monitor is not part of the design, so no Log Analytics workspace is created.'
    exit 0
}
$workspaceName = Get-Text 'operations.monitoring.log_analytics_workspace'
$group = Get-Text 'operations.monitoring.workspace_resource_group'
$retentionText = Get-Text 'operations.monitoring.retention_days'
if (-not $workspaceName) { Exit-InputProblem 'operations.monitoring.log_analytics_workspace is missing. Name the workspace to create.' }
if ($workspaceName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{2,61}[A-Za-z0-9]$') { Exit-InputProblem "operations.monitoring.log_analytics_workspace '$workspaceName' is not a valid name (4 to 63 letters, digits and hyphens; starts and ends with a letter or digit)." }
if (-not $group) { Exit-InputProblem 'operations.monitoring.workspace_resource_group is missing.' }
if (-not $region) { Exit-InputProblem 'azure.location is missing. It is the region of the workspace.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder. The workspace is created there.' }
$retentionDays = $null
if ($retentionText) {
    $parsed = 0
    if (-not [int]::TryParse($retentionText, [ref]$parsed) -or $parsed -lt 30 -or $parsed -gt 730) { Exit-InputProblem "operations.monitoring.retention_days '$retentionText' is not a whole number of days from 30 to 730." }
    $retentionDays = $parsed
}

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResourceGroup', 'Get-AzOperationalInsightsWorkspace', 'New-AzOperationalInsightsWorkspace') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts, Az.Resources and Az.OperationalInsights modules: Install-Module Az.Accounts, Az.Resources, Az.OperationalInsights -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$row = [ordered]@{ Workspace = $workspaceName; Action = ''; Location = $region; Detail = '' }
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop

    # the resource group must exist; this script does not create it
    $resourceGroup = $null
    try { $resourceGroup = Get-AzResourceGroup -Name $group -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The resource group '$group' could not be read: $($_.Exception.Message)" } }
    if (-not $resourceGroup) { Exit-Failed "The resource group '$group' does not exist in the subscription of azure.subscription_id. Create it first (the Azure foundation stage)." }
    Write-Line "Log Analytics workspace '$workspaceName' in '$group' ($region)"

    $existing = $null
    try { $existing = Get-AzOperationalInsightsWorkspace -ResourceGroupName $group -Name $workspaceName -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        Write-Line "[exists]  '$workspaceName' is already there, nothing changed."
        $differences = [System.Collections.Generic.List[string]]::new()
        $existingRegion = if ($existing.PSObject.Properties['Location']) { [string]$existing.Location } else { '' }
        if ($existingRegion) { $row.Location = $existingRegion }
        if ($existingRegion -and (ConvertTo-RegionKey $existingRegion) -ne (ConvertTo-RegionKey $region)) {
            $differences.Add("the workspace is in $existingRegion, azure.location is $region (a workspace cannot move: create a new one if the region must change)")
        }
        $existingRetention = if ($existing.PSObject.Properties['RetentionInDays'] -and $null -ne $existing.RetentionInDays) { [int]$existing.RetentionInDays } else { $null }
        if ($null -ne $retentionDays -and $null -ne $existingRetention -and $existingRetention -ne $retentionDays) {
            $differences.Add("the workspace keeps data for $existingRetention days, operations.monitoring.retention_days is $retentionDays")
        }
        if ($differences.Count -gt 0) {
            $row.Detail = "Differs from the file ($($differences -join '; ')); left unchanged."
            Write-Warning "${workspaceName}: $($row.Detail)"
        }
    }
    elseif ($PSCmdlet.ShouldProcess("Log Analytics workspace '$workspaceName' in '$group'", "Create ($region)")) {
        $arguments = @{ Name = $workspaceName; ResourceGroupName = $group; Location = $region; ErrorAction = 'Stop' }
        if ($tags.Count) { $arguments.Tag = $tags }
        if ($null -ne $retentionDays) { $arguments.RetentionInDays = $retentionDays }
        $null = New-AzOperationalInsightsWorkspace @arguments
        $row.Action = 'Created'
        Write-Line "[created] '$workspaceName'."
    }
    else {
        $row.Action = 'WouldCreate'
        Write-Line "[plan]    '$workspaceName' would be created."
    }
}
catch {
    $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
    Write-Warning "${workspaceName}: $($row.Detail)"
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
