<#
.SYNOPSIS
    Turns on the Windows Server subscription add-on for the Azure Local instance when operations.licensing.windows_server_subscription of infrastructure.yml is true.

.DESCRIPTION
    Phase 05 (licensing and telemetry), Task 02. The Windows Server subscription add-on activates every Windows Server VM on the instance: when it is on,
    the Azure Local machines set up automatic VM activation (AVMA) by themselves and a guest uses a generic AVMA key (Microsoft Learn, Activate Windows
    Server VMs on Azure Local). It is a setting of the Azure Local instance (the cluster resource).

    When operations.licensing.windows_server_subscription is true the script:
      1. reads the instance (Get-AzStackHciCluster) and the desired state of the add-on;
      2. does nothing when it is already Enabled;
      3. otherwise turns it on with Update-AzStackHciCluster -DesiredPropertyWindowsServerSubscription Enabled, the Azure PowerShell form of
         az stack-hci cluster update --desired-properties windows-server-subscription=Enabled that Learn documents, and reads the instance again.

    When the key is false or missing the script does nothing and says so. The script never turns the add-on off.

    It is a paid add-on (Learn: see the Add-on workloads section of the Azure Local pricing page); with Azure Hybrid Benefit activated
    (operations.licensing.azure_hybrid_benefit, task 01) it is at no extra cost. Learn requires that every machine of the instance is online and
    registered to Azure and that updates are installed. The script cannot see the machines, so that is yours to check before you set the key.
    To check the subscription on a machine, run Get-AzureStackHCISubscriptionStatus on it, and Get-VMAutomaticActivation to check AVMA.

    The script refuses scenario.connectivity disconnected (exit 2): the add-on needs cloud connected management.

    Idempotent. -WhatIf reads the instance and changes nothing. The script does not sign in and asks nothing: run Connect-AzAccount to the tenant of
    azure.tenant_id first, with a role that can write to the instance (Contributor or Owner). It changes the subscription of the session while it works
    and puts it back.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name
        scenario.connectivity
        operations.licensing.windows_server_subscription

    Exit codes: 0 the add-on is Enabled (turned on now, already there, planned under -WhatIf) or the file does not ask for it; 1 an Azure call
    failed or a precondition failed (not signed in, wrong tenant, Az.StackHCI missing, the instance not found); 2 a value in the file is missing or
    not usable. Nothing is sent to Azure on exit code 2.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Enable-WindowsServerSubscription.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows the state of the add-on and whether it would be turned on. Changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Enable-WindowsServerSubscription.ps1 -InfrastructureFile ./infrastructure.yml

    Turns the add-on on. Run it again: it reports that the add-on is already Enabled.
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
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# The value of the desired state that the add-on is on. Fixed by the Azure Stack HCI resource provider (Learn: Activate Windows Server VMs on Azure Local).
$EnabledState = 'Enabled'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-State([object]$Cluster) {
    if ($Cluster -and $Cluster.PSObject.Properties['DesiredPropertyWindowsServerSubscription'] -and $Cluster.DesiredPropertyWindowsServerSubscription) { return [string]$Cluster.DesiredPropertyWindowsServerSubscription }
    ''
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$requested = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.licensing.windows_server_subscription'
if ($null -ne $requested -and $requested -isnot [bool]) { Exit-InputProblem "operations.licensing.windows_server_subscription must be true or false; found '$requested'." }
if ($requested -ne $true) {
    Write-Line 'operations.licensing.windows_server_subscription is not true: nothing to do. This script never turns the add-on off.'
    exit 0
}

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$clusterName = Get-Text 'cluster.name'
$connectivity = (Get-Text 'scenario.connectivity').ToLowerInvariant()
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The Azure Local instance is in it.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. It is the name of the Azure Local instance.' }
if ($connectivity -eq 'disconnected') { Exit-InputProblem 'scenario.connectivity is disconnected. The Windows Server subscription add-on needs cloud connected management. Set operations.licensing.windows_server_subscription to false.' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzStackHciCluster', 'Update-AzStackHciCluster') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.StackHCI modules: Install-Module Az.Accounts, Az.StackHCI -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$row = [ordered]@{ Cluster = $clusterName; Action = ''; State = ''; Detail = '' }
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    $cluster = $null
    try { $cluster = Get-AzStackHciCluster -Name $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    if (-not $cluster) { throw "The Azure Local instance '$clusterName' was not found in the resource group '$group'. Deploy it first, then run this script." }

    $state = Get-State $cluster
    $row.State = $state
    if ($state -ieq $EnabledState) {
        $row.Action = 'AlreadyEnabled'
        Write-Line "[exists]  The Windows Server subscription add-on is already Enabled on '$clusterName', nothing changed."
    }
    elseif ($PSCmdlet.ShouldProcess("Azure Local instance '$clusterName' in '$group'", 'Turn on the Windows Server subscription add-on (a paid add-on; at no extra cost with Azure Hybrid Benefit)')) {
        $null = Update-AzStackHciCluster -Name $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -DesiredPropertyWindowsServerSubscription $EnabledState -ErrorAction Stop
        $after = Get-AzStackHciCluster -Name $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop
        $row.State = Get-State $after
        $row.Action = 'Enabled'
        if ($row.State -ine $EnabledState) { $row.Detail = "The call succeeded, but the state reads '$($row.State)'. Read it again in a few minutes." }
        Write-Line "[done]    The Windows Server subscription add-on is turned on for '$clusterName' (state: $($row.State)). The machines apply it at their next sync; check a machine with Get-AzureStackHCISubscriptionStatus."
    }
    else {
        $row.Action = 'WouldEnable'
        Write-Line "[plan]    The Windows Server subscription add-on would be turned on for '$clusterName' (state now: $(if ($state) { $state } else { 'not reported' }))."
    }
}
catch {
    $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
    Write-Warning "${clusterName}: $($row.Detail)"
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Warning "Could not restore the original subscription context ($($originalContext.Subscription.Id)); the session now points at $subscriptionId. $($_.Exception.Message)" }
    }
}

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
