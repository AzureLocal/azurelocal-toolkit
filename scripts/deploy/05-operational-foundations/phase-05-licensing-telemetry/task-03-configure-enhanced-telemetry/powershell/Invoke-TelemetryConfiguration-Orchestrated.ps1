<#
.SYNOPSIS
    Sets the diagnostic level of the Azure Local instance from security.telemetry.diagnostic_level of infrastructure.yml (Off, Basic or Enhanced),
    then syncs the machines with Azure. Reports the diagnostic data settings of the deployment. Idempotent.

.DESCRIPTION
    Operational foundations, phase 05 (licensing and telemetry), Task 03 (configure enhanced telemetry).

    What Microsoft Learn documents after the deployment: the instance resource (Microsoft.AzureStackHCI/clusters) has a desired diagnostic level,
    desiredProperties.diagnosticLevel, with the values Off, Basic and Enhanced (Update-AzStackHciCluster -DesiredPropertyDiagnosticLevel; az stack-hci
    cluster update --desired-properties diagnostic-level). There is no Full level. The streaming data, episodic data upload and EU location settings
    (security.telemetry.streaming_data, episodic_data_upload, eu_location) are deployment settings: the ARM deployment sets them, and Learn documents
    no way to change them afterwards, so this script only shows them.

    Steps:
      1. Azure: reads the instance (Get-AzStackHciCluster). When its desired diagnostic level is the one of the file, nothing is changed
         (AlreadySet). Otherwise Update-AzStackHciCluster -DesiredPropertyDiagnosticLevel <level>, then the instance is read again.
      2. The machines: after a change, Sync-AzureStackHCI runs on one node, so the machines take the setting now and not at their next daily sync.
         -SkipSync leaves that out.

    With security.telemetry.diagnostic_level absent the script does nothing and exits 0. It refuses scenario.connectivity disconnected (exit 2).
    -WhatIf reads Azure and changes nothing (no update, no sync).

    Sign-in: the script does not sign in; run Connect-AzAccount -Tenant <azure.tenant_id> first, with Contributor or Owner on the instance. The
    sync on a node uses -Credential, else the account the file names for the identity: identity.active_directory.lcm_user (as <netbios name>\<user>)
    with active_directory, identity.local_admin (as .\<user>) with local_identity; the password is a secret reference read through
    scripts/common/secrets/AzlSecret.psm1. The script never asks. Without a login the sync is left out with a warning (the machines sync daily).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        security.telemetry.diagnostic_level, streaming_data, episodic_data_upload, eu_location
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name, scenario.connectivity, scenario.identity
        nodes[].name, nodes[].management.ip_address
        identity.active_directory.netbios_name, identity.active_directory.lcm_user (username, password), identity.local_admin (username, password)

    Exit codes: 0 the level is as the file says (set now, already so, planned under -WhatIf, or not asked for); 1 an Azure call or a precondition
    failed (Az missing, not signed in, wrong tenant, the instance not found, the update failed); 2 a value in the file is missing or not usable.
    A sync that fails is a warning, not a failure: the machines sync on their own.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The node to run Sync-AzureStackHCI on (a node name of the file or an address), instead of the first node of nodes[].

.PARAMETER Credential
    Optional. The account for the remoting session of the sync. Without it the account of the file is used (see above).

.PARAMETER SkipSync
    Optional. Do not run Sync-AzureStackHCI after a change.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Invoke-TelemetryConfiguration-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./Invoke-TelemetryConfiguration-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ComputerName,
    [pscredential]$Credential,
    [switch]$SkipSync,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# The values of desiredProperties.diagnosticLevel (Microsoft.AzureStackHCI/clusters; Learn, Update-AzStackHciCluster).
$Levels = @('Off', 'Basic', 'Enhanced')

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Property([object]$Object, [string]$Name) { if ($Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { [string]$Object.$Name } else { '' } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$wanted = Get-Text 'security.telemetry.diagnostic_level'
foreach ($k in 'streaming_data', 'episodic_data_upload', 'eu_location') {
    $v = Get-AzlInfrastructureValue -Infrastructure $infra -Path "security.telemetry.$k"
    Write-Line "security.telemetry.${k}: $(if ($null -eq $v) { 'not set (the registry default applies)' } else { $v }) - a deployment setting, not changed here."
}
if (-not $wanted) {
    Write-Line 'security.telemetry.diagnostic_level is not set: nothing to do.'
    exit 0
}
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

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzStackHciCluster', 'Update-AzStackHciCluster') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.StackHCI modules: Install-Module Az.Accounts, Az.StackHCI -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$row = [ordered]@{ Cluster = $clusterName; Action = ''; Desired = ''; Reported = ''; Sync = ''; Detail = '' }
$changed = $false
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    $cluster = $null
    try { $cluster = Get-AzStackHciCluster -Name $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    if (-not $cluster) { throw "The Azure Local instance '$clusterName' was not found in the resource group '$group'." }
    $row.Desired = Get-Property $cluster 'DesiredPropertyDiagnosticLevel'
    $row.Reported = Get-Property $cluster 'ReportedPropertyDiagnosticLevel'
    if ($row.Desired -ieq $level) {
        $row.Action = 'AlreadySet'
        Write-Line "[exists]  The diagnostic level of '$clusterName' is already $level; nothing changed."
    }
    elseif ($PSCmdlet.ShouldProcess("Azure Local instance '$clusterName' in '$group'", "Set the diagnostic level to $level (now: $(if ($row.Desired) { $row.Desired } else { 'not reported' }))")) {
        $null = Update-AzStackHciCluster -Name $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -DesiredPropertyDiagnosticLevel $level -ErrorAction Stop
        $after = Get-AzStackHciCluster -Name $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop
        $row.Desired = Get-Property $after 'DesiredPropertyDiagnosticLevel'
        $row.Reported = Get-Property $after 'ReportedPropertyDiagnosticLevel'
        $row.Action = 'Set'
        $changed = $true
        if ($row.Desired -ine $level) { $row.Detail = "The call succeeded, but the desired level reads '$($row.Desired)'. Read it again in a few minutes." }
        Write-Line "[done]    The diagnostic level of '$clusterName' is set to $level."
    }
    else {
        $row.Action = 'WouldSet'
        Write-Line "[plan]    The diagnostic level of '$clusterName' would be set to $level (now: $(if ($row.Desired) { $row.Desired } else { 'not reported' }))."
    }
}
catch { $row.Action = 'Failed'; $row.Detail = $_.Exception.Message; Write-Warning "${clusterName}: $($row.Detail)" }
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Warning "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

# ---- the machines: sync after a change
if (-not $changed) { $row.Sync = 'NotNeeded' }
elseif ($SkipSync) { $row.Sync = 'Skipped' }
else {
    $remoteCredential = $Credential
    if (-not $remoteCredential) {
        if ((Get-Text 'scenario.identity').ToLowerInvariant() -eq 'local_identity') { $user = Get-Text 'identity.local_admin.username'; $reference = Get-Text 'identity.local_admin.password'; $account = ".\$user" }
        else {
            $netbios = Get-Text 'identity.active_directory.netbios_name'
            $user = Get-Text 'identity.active_directory.lcm_user.username'; $reference = Get-Text 'identity.active_directory.lcm_user.password'
            $account = if ($user -match '\\|@') { $user } elseif ($netbios) { "$netbios\$user" } else { $user }
        }
        if ($user -and $reference) {
            try { $remoteCredential = [pscredential]::new($account, (Get-AzlSecretValue -Reference $reference -Infrastructure $infra)) }
            catch { Write-Warning "The password of the login could not be read, so the machines were not synced now (they sync daily): $($_.Exception.Message)" }
        }
    }
    $nodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
    $target = if ($ComputerName) { $ComputerName.Trim() } elseif ($nodes.Count) { $(if ($nodes[0].ManagementIp) { $nodes[0].ManagementIp } else { $nodes[0].Name }) } else { '' }
    if (-not $remoteCredential -or -not $target) { $row.Sync = 'Skipped'; Write-Warning 'No login or no node: the machines were not synced now. They take the setting at their next sync (Sync-AzureStackHCI on a node).' }
    else {
        try {
            Invoke-Command -ComputerName $target -Credential $remoteCredential -ErrorAction Stop -ScriptBlock { param($Step) Sync-AzureStackHCI -ErrorAction Stop } -ArgumentList 'Sync' | Out-Null
            $row.Sync = 'Synced'
            Write-Line "[done]    Sync-AzureStackHCI ran on '$target'."
        }
        catch { $row.Sync = 'SyncFailed'; Write-Warning "Sync-AzureStackHCI on '$target' failed (the machines sync daily): $($_.Exception.Message)" }
    }
}

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
