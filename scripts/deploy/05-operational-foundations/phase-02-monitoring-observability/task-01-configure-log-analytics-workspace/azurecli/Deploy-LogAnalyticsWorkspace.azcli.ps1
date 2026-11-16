<#
.SYNOPSIS
    Creates the Log Analytics workspace that operations.monitoring of infrastructure.yml names, with the Azure CLI.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 01 (Log Analytics workspace), Azure CLI variant of Deploy-LogAnalyticsWorkspace.ps1. It does the same with
    az commands, for a host that has the Azure CLI and not the Az PowerShell modules. It creates the one Log Analytics workspace of the design,
    operations.monitoring.log_analytics_workspace, in the resource group operations.monitoring.workspace_resource_group, in the region azure.location.
    It is the workspace Insights for Azure Local sends to.

    It creates only that workspace: not the resource group (the Azure foundation stage does; a missing group is a failure), not the data collection
    endpoint (Deploy-DataCollectionEndpoint.azcli.ps1), not the data collection rule (Enable-HciInsights.azcli.ps1), not an action group. It creates no
    second workspace for security operations and turns on no paid security service.

    The pricing tier is not set: a new workspace is pay-as-you-go (az monitor log-analytics workspace create leaves the tier at the Azure default). The
    retention is operations.monitoring.retention_days when the file sets it; without it the workspace gets the Azure default of 30 days. Microsoft Learn
    says retention beyond 31 days is charged.

    When operations.monitoring.enabled is false the design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent. A workspace that exists is reported as AlreadyExists and left alone (a region or a retention that differs from the file is reported, not
    changed), so a second run creates nothing. -WhatIf changes nothing.

    The script does not sign in: run az login to the tenant in azure.tenant_id first. It does not change the Azure CLI default subscription: every call
    carries --subscription. You need Log Analytics Contributor (or Contributor) on the resource group. The file-level tags map is put on the workspace.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.location, tags
        operations.monitoring.enabled                    false means: do nothing
        operations.monitoring.log_analytics_workspace    the workspace name
        operations.monitoring.workspace_resource_group   the resource group of the workspace; it must exist
        operations.monitoring.retention_days             optional; the retention of a workspace the script creates (30 to 730)

    Exit codes: 0 the workspace exists (created now, already there, planned under -WhatIf) or monitoring is switched off in the file; 1 an Azure call
    failed or a precondition failed (az missing, not signed in, wrong tenant, the resource group does not exist, the creation failed); 2 a value in the
    file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-LogAnalyticsWorkspace.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the workspace would be created, and creates nothing.
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

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# The Azure CLI is started through a command file on Windows. These characters would be read as commands there, so no value that holds one is sent.
$UnsafeArgument = '[&|<>^%"`\r\n]'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { $v = Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }
function ConvertTo-RegionKey([string]$Region) { ($Region -replace '\s', '').ToLowerInvariant() }
# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the text of standard output; throws when az ends with an error.
function Invoke-Az {
    $arguments = @($args | ForEach-Object { $_ } | ForEach-Object { [string]$_ })
    foreach ($argument in $arguments) {
        if ($argument -match $UnsafeArgument) { throw "An argument holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote): $argument" }
    }
    $all = @(& az @arguments '--only-show-errors' 2>&1)
    $code = $LASTEXITCODE
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw $(if ($err) { $err.Trim() } else { $out.Trim() }) }
    $out.Trim()
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$region = Get-Text 'azure.location'
$monitoring = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tagArguments = @()
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tagArguments += "$k=$($rawTags[$k])" } } }

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
foreach ($pair in $tagArguments) { if ($pair -match $UnsafeArgument) { Exit-InputProblem "The tag '$pair' holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote)." } }
$retentionDays = $null
if ($retentionText) {
    $parsed = 0
    if (-not [int]::TryParse($retentionText, [ref]$parsed) -or $parsed -lt 30 -or $parsed -gt 730) { Exit-InputProblem "operations.monitoring.retention_days '$retentionText' is not a whole number of days from 30 to 730." }
    $retentionDays = $parsed
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Deploy-LogAnalyticsWorkspace.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

$row = [ordered]@{ Workspace = $workspaceName; Action = ''; Location = $region; Detail = '' }
try {
    # the resource group must exist; this script does not create it
    try { $null = Invoke-Az group show --subscription $subscriptionId --name $group --output none }
    catch {
        if ($_.Exception.Message -match $NotFound) { Exit-Failed "The resource group '$group' does not exist in the subscription of azure.subscription_id. Create it first (the Azure foundation stage)." }
        Exit-Failed "The resource group '$group' could not be read: $($_.Exception.Message)"
    }
    Write-Line "Log Analytics workspace '$workspaceName' in '$group' ($region)"

    $existing = $null
    try { $existing = Invoke-Az monitor log-analytics workspace show --subscription $subscriptionId --resource-group $group --workspace-name $workspaceName --output json | ConvertFrom-Json }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        Write-Line "[exists]  '$workspaceName' is already there, nothing changed."
        $differences = [System.Collections.Generic.List[string]]::new()
        $existingRegion = if ($existing.PSObject.Properties['location'] -and $existing.location) { [string]$existing.location } else { '' }
        if ($existingRegion) { $row.Location = $existingRegion }
        if ($existingRegion -and (ConvertTo-RegionKey $existingRegion) -ne (ConvertTo-RegionKey $region)) {
            $differences.Add("the workspace is in $existingRegion, azure.location is $region (a workspace cannot move: create a new one if the region must change)")
        }
        $existingRetention = if ($existing.PSObject.Properties['retentionInDays'] -and $null -ne $existing.retentionInDays) { [int]$existing.retentionInDays } else { $null }
        if ($null -ne $retentionDays -and $null -ne $existingRetention -and $existingRetention -ne $retentionDays) {
            $differences.Add("the workspace keeps data for $existingRetention days, operations.monitoring.retention_days is $retentionDays")
        }
        if ($differences.Count -gt 0) {
            $row.Detail = "Differs from the file ($($differences -join '; ')); left unchanged."
            Write-Warning "${workspaceName}: $($row.Detail)"
        }
    }
    elseif ($PSCmdlet.ShouldProcess("Log Analytics workspace '$workspaceName' in '$group'", "Create ($region)")) {
        $arguments = @('monitor', 'log-analytics', 'workspace', 'create', '--subscription', $subscriptionId, '--resource-group', $group, '--workspace-name', $workspaceName, '--location', $region)
        if ($null -ne $retentionDays) { $arguments += @('--retention-time', [string]$retentionDays) }
        if ($tagArguments.Count) { $arguments += @('--tags') + $tagArguments }
        $null = Invoke-Az ($arguments + @('--output', 'none'))
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

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
