<#
.SYNOPSIS
    Creates the Azure Monitor data collection endpoint that operations.monitoring of infrastructure.yml names, with the Azure CLI.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 01 (Log Analytics workspace), Azure CLI variant of Deploy-DataCollectionEndpoint.ps1. Once the Log
    Analytics workspace exists, this script creates the data collection endpoint (DCE) of operations.monitoring.data_collection_endpoint in the resource
    group of the workspace (operations.monitoring.workspace_resource_group), in the region of the workspace. A DCE is the ingestion address the data
    collection rules and the Azure Monitor Agent send to; it must be in the region of the workspace it feeds, which is why the region is read from the
    workspace and not assumed. The network access is left open to the public network, the Azure default: az monitor data-collection endpoint create
    needs the setting stated, and the script states Enabled, the value the PowerShell variant leaves at the default. It sets no private link, because
    Microsoft Learn asks for an endpoint only when the agents use private links.

    It creates only the endpoint. It does not create the workspace (Deploy-LogAnalyticsWorkspace.azcli.ps1), the data collection rule or any
    association (Enable-HciInsights.azcli.ps1, task 03), or the action group of the alerting task.

    When operations.monitoring.enabled is false the design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent. An endpoint that exists is reported as AlreadyExists and left alone (a region that differs from the workspace is reported), so a second
    run creates nothing. -WhatIf changes nothing.

    The script needs the Azure CLI extension monitor-control-service (az extension add --name monitor-control-service), which holds
    az monitor data-collection; it does not install it. The script does not sign in: run az login to the tenant in azure.tenant_id first. It does not
    change the Azure CLI default subscription: every call carries --subscription. You need Monitoring Contributor (or Contributor) on the resource
    group. The file-level tags map is put on the endpoint.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.location (fallback region), tags
        operations.monitoring.enabled                    false means: do nothing
        operations.monitoring.log_analytics_workspace    the workspace that must exist
        operations.monitoring.workspace_resource_group   the resource group of the workspace and of the endpoint
        operations.monitoring.data_collection_endpoint   the endpoint name

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 the endpoint exists (created now, already there, planned under -WhatIf) or monitoring is switched off in the file; 1 an Azure call
    failed or a precondition failed (az missing, not signed in, wrong tenant, extension monitor-control-service missing, the workspace does not exist,
    the creation failed); 2 a value in the file
    is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-DataCollectionEndpoint.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the endpoint would be created, and creates nothing.
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
Import-Module ([IO.Path]::Combine($common, 'azure-cli', 'AzlAzureCliArgument.psm1')) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# Fixed by the Azure CLI: az monitor data-collection endpoint create requires --public-network-access. Enabled is the Azure default (public), as in the PowerShell variant.
$PublicNetworkAccess = 'Enabled'
# The Azure CLI extension that holds az monitor data-collection.
$MonitorExtension = 'monitor-control-service'

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
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $arguments
    if ($unsafe) { Exit-InputProblem $unsafe }
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
$defaultLocation = Get-Text 'azure.location'
$monitoring = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tagArguments = @()
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tagArguments += "$k=$($rawTags[$k])" } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($monitoring -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'operations.monitoring is missing. Describe the workspace and the data collection endpoint.' }
if ((Get-Text 'operations.monitoring.enabled').ToLowerInvariant() -eq 'false') {
    Write-Line 'operations.monitoring.enabled is false: Azure Monitor is not part of the design, so no data collection endpoint is created.'
    exit 0
}
$workspaceName = Get-Text 'operations.monitoring.log_analytics_workspace'
$group = Get-Text 'operations.monitoring.workspace_resource_group'
$endpointName = Get-Text 'operations.monitoring.data_collection_endpoint'
if (-not $workspaceName) { Exit-InputProblem 'operations.monitoring.log_analytics_workspace is missing.' }
if (-not $group) { Exit-InputProblem 'operations.monitoring.workspace_resource_group is missing.' }
if (-not $endpointName) { Exit-InputProblem 'operations.monitoring.data_collection_endpoint is missing. Name the endpoint to create.' }
if ($endpointName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}[A-Za-z0-9_]$|^[A-Za-z0-9]$') { Exit-InputProblem "operations.monitoring.data_collection_endpoint '$endpointName' is not a valid name (1 to 64 letters, digits, . _ -; starts with a letter or digit)." }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder. The workspace is looked up there.' }
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = $tagArguments }); if ($problem) { Exit-InputProblem $problem }

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A value that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'operations.monitoring.log_analytics_workspace' = $workspaceName; 'operations.monitoring.workspace_resource_group' = $group; 'azure.location' = $defaultLocation })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Deploy-DataCollectionEndpoint.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }
# az monitor data-collection is in the extension monitor-control-service. Without it az offers to install it and waits for an answer, which an
# unattended run cannot give (lab run 2026-11-23: EOFError). Checked here, never installed.
try { $null = Invoke-Az extension show --name $MonitorExtension --output none }
catch { Exit-Failed "The Azure CLI extension $MonitorExtension is not installed. This script does not install it. Run: az extension add --name $MonitorExtension" }

$row = [ordered]@{ Endpoint = $endpointName; Action = ''; Location = ''; Detail = '' }
try {
    # the workspace must exist, and its region is the region of the endpoint
    $workspace = $null
    try { $workspace = Invoke-Az monitor log-analytics workspace show --subscription $subscriptionId --resource-group $group --workspace-name $workspaceName --output json | ConvertFrom-Json }
    catch {
        if ($_.Exception.Message -match $NotFound) { Exit-Failed "The Log Analytics workspace '$workspaceName' does not exist in '$group'. Create it first (Deploy-LogAnalyticsWorkspace.azcli.ps1)." }
        Exit-Failed "The Log Analytics workspace '$workspaceName' could not be read: $($_.Exception.Message)"
    }
    $region = if ($workspace -and $workspace.PSObject.Properties['location'] -and $workspace.location) { [string]$workspace.location } else { $defaultLocation }
    if (-not $region) { Exit-InputProblem 'No region: the workspace reports none and azure.location is empty.' }
    $row.Location = $region
    Write-Line "Data collection endpoint '$endpointName' in '$group' ($region), for the workspace '$workspaceName'"

    $existing = $null
    try { $existing = Invoke-Az monitor data-collection endpoint show --subscription $subscriptionId --resource-group $group --name $endpointName --output json | ConvertFrom-Json }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        Write-Line "[exists]  '$endpointName' is already there, nothing changed."
        $existingRegion = if ($existing.PSObject.Properties['location']) { [string]$existing.location } else { '' }
        if ($existingRegion -and (ConvertTo-RegionKey $existingRegion) -ne (ConvertTo-RegionKey $region)) {
            $row.Detail = "Differs from the workspace (the endpoint is in $existingRegion, the workspace in $region); left unchanged. An endpoint cannot move: create a new one if the region must change."
            Write-Warning "${endpointName}: $($row.Detail)"
        }
    }
    elseif ($PSCmdlet.ShouldProcess("data collection endpoint '$endpointName' in '$group'", "Create ($region)")) {
        $arguments = @('monitor', 'data-collection', 'endpoint', 'create', '--subscription', $subscriptionId, '--resource-group', $group, '--name', $endpointName, '--location', $region, '--public-network-access', $PublicNetworkAccess)
        if ($tagArguments.Count) { $arguments += @('--tags') + $tagArguments }
        $null = Invoke-Az ($arguments + @('--output', 'none'))
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

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
