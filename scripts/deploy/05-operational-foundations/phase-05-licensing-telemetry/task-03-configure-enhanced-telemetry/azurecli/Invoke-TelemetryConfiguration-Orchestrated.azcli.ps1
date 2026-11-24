<#
.SYNOPSIS
    Sets the diagnostic level of the Azure Local instance from security.telemetry.diagnostic_level of infrastructure.yml (Off, Basic or Enhanced),
    with the Azure CLI. The Azure CLI twin of Invoke-TelemetryConfiguration-Orchestrated.ps1. Idempotent.

.DESCRIPTION
    Operational foundations, phase 05 (licensing and telemetry), Task 03 (configure enhanced telemetry). Microsoft Learn documents the desired
    diagnostic level of the instance resource (desiredProperties.diagnosticLevel: Off, Basic, Enhanced) and the Azure CLI form
    az stack-hci cluster update --desired-properties diagnostic-level=<level>. There is no Full level.

    The script reads the instance (az stack-hci cluster show). When its desired level is the one of the file, nothing is changed (AlreadySet).
    Otherwise it runs az stack-hci cluster update and reads the instance again. Azure side only: the PowerShell script also runs Sync-AzureStackHCI on
    a node so that the machines take the setting at once; without it they take it at their next daily sync.

    With security.telemetry.diagnostic_level absent the script does nothing and exits 0. It refuses scenario.connectivity disconnected (exit 2).
    -WhatIf reads Azure and changes nothing.

    The script does not sign in: run az login --tenant <azure.tenant_id> first, with Contributor or Owner on the instance. It needs the Azure CLI
    extension stack-hci (az extension add --name stack-hci) and does not install it. Every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        security.telemetry.diagnostic_level, azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name, scenario.connectivity

    Exit codes: 0 the level is as the file says (set now, already so, planned under -WhatIf, or not asked for); 1 a call or a precondition failed
    (az missing, not signed in, wrong tenant, extension missing, the instance not found, the update failed); 2 a value in the file is missing or not
    usable. On exit code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Invoke-TelemetryConfiguration-Orchestrated.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf
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
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# The values of desiredProperties.diagnosticLevel (Microsoft.AzureStackHCI/clusters; Learn, az stack-hci cluster update).
$Levels = @('Off', 'Basic', 'Enhanced')

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
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
# The desired diagnostic level, as az returns it: at the top of the object or under properties.
function Get-Level($Cluster) {
    foreach ($node in @($Cluster, $(if ($Cluster -and $Cluster.PSObject.Properties['properties']) { $Cluster.properties }))) {
        if ($node -and $node.PSObject.Properties['desiredProperties'] -and $node.desiredProperties -and $node.desiredProperties.PSObject.Properties['diagnosticLevel'] -and $node.desiredProperties.diagnosticLevel) {
            return [string]$node.desiredProperties.diagnosticLevel
        }
    }
    ''
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$wanted = Get-Text 'security.telemetry.diagnostic_level'
if (-not $wanted) { Write-Line 'security.telemetry.diagnostic_level is not set: nothing to do.'; exit 0 }
$level = $Levels | Where-Object { $_ -ieq $wanted } | Select-Object -First 1
if (-not $level) { Exit-InputProblem "security.telemetry.diagnostic_level must be Off, Basic or Enhanced; found '$wanted'. (There is no Full level.)" }

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$clusterName = Get-Text 'cluster.name'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The Azure Local instance is in it.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. It is the name of the Azure Local instance.' }
if ((Get-Text 'scenario.connectivity').ToLowerInvariant() -eq 'disconnected') { Exit-InputProblem 'scenario.connectivity is disconnected. The diagnostic level of the instance resource is set through Azure; remove security.telemetry.diagnostic_level.' }
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group; 'cluster.name' = $clusterName })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Invoke-TelemetryConfiguration-Orchestrated.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }
try { $null = Invoke-Az extension show --name stack-hci --output none }
catch { Exit-Failed 'The Azure CLI extension stack-hci is not installed. This script does not install it. Run: az extension add --name stack-hci' }

$row = [ordered]@{ Cluster = $clusterName; Action = ''; Desired = ''; Detail = '' }
try {
    $cluster = $null
    try { $cluster = Invoke-Az stack-hci cluster show --subscription $subscriptionId --resource-group $group --name $clusterName --output json | ConvertFrom-Json }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    if (-not $cluster) { throw "The Azure Local instance '$clusterName' was not found in the resource group '$group'." }
    $row.Desired = Get-Level $cluster
    if ($row.Desired -ieq $level) {
        $row.Action = 'AlreadySet'
        Write-Line "[exists]  The diagnostic level of '$clusterName' is already $level; nothing changed."
    }
    elseif ($PSCmdlet.ShouldProcess("Azure Local instance '$clusterName' in '$group'", "Set the diagnostic level to $level")) {
        $null = Invoke-Az stack-hci cluster update --subscription $subscriptionId --resource-group $group --name $clusterName --desired-properties "diagnostic-level=$level" --output none
        $after = Invoke-Az stack-hci cluster show --subscription $subscriptionId --resource-group $group --name $clusterName --output json | ConvertFrom-Json
        $row.Desired = Get-Level $after
        $row.Action = 'Set'
        if ($row.Desired -ine $level) { $row.Detail = "The call succeeded, but the desired level reads '$($row.Desired)'. Read it again in a few minutes." }
        Write-Line "[done]    The diagnostic level of '$clusterName' is set to $level. The machines take it at their next sync (Sync-AzureStackHCI on a node for now)."
    }
    else {
        $row.Action = 'WouldSet'
        Write-Line "[plan]    The diagnostic level of '$clusterName' would be set to $level (now: $(if ($row.Desired) { $row.Desired } else { 'not reported' }))."
    }
}
catch { $row.Action = 'Failed'; $row.Detail = $_.Exception.Message; Write-Warning "${clusterName}: $($row.Detail)" }

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
