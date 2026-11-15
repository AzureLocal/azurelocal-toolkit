<#
.SYNOPSIS
    Turns on the Windows Server subscription add-on for the Azure Local instance when operations.licensing.windows_server_subscription of infrastructure.yml is true, with the Azure CLI.

.DESCRIPTION
    Phase 05 (licensing and telemetry), Task 02, Azure CLI variant of Enable-WindowsServerSubscription.ps1. The Windows Server subscription add-on
    activates every Windows Server VM on the instance: when it is on, the Azure Local machines set up automatic VM activation (AVMA) by themselves and a
    guest uses a generic AVMA key (Microsoft Learn, Activate Windows Server VMs on Azure Local). It is a setting of the Azure Local instance (the cluster
    resource).

    When operations.licensing.windows_server_subscription is true the script:
      1. reads the instance (az stack-hci cluster show) and the desired state of the add-on;
      2. does nothing when it is already Enabled;
      3. otherwise turns it on with az stack-hci cluster update --desired-properties windows-server-subscription=Enabled, the command Learn documents,
         and reads the instance again.

    When the key is false or missing the script does nothing and says so. The script never turns the add-on off.

    It is a paid add-on (Learn: see the Add-on workloads section of the Azure Local pricing page); with Azure Hybrid Benefit activated
    (operations.licensing.azure_hybrid_benefit, task 01) it is at no extra cost. Learn requires that every machine of the instance is online and
    registered to Azure and that updates are installed. The script cannot see the machines, so that is yours to check before you set the key. To check
    the subscription on a machine, run Get-AzureStackHCISubscriptionStatus on it, and Get-VMAutomaticActivation to check AVMA.

    The script refuses scenario.connectivity disconnected (exit 2): the add-on needs cloud connected management.

    Idempotent. -WhatIf reads the instance and changes nothing. The script needs the Azure CLI extension stack-hci (az extension add --name stack-hci);
    it does not install it. It does not sign in: run az login to the tenant in azure.tenant_id first, with a role that can write to the instance
    (Contributor or Owner). It does not change the Azure CLI default subscription: every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name
        scenario.connectivity
        operations.licensing.windows_server_subscription

    Exit codes: 0 the add-on is Enabled (turned on now, already there, planned under -WhatIf) or the file does not ask for it; 1 an Azure call failed or a
    precondition failed (az missing, not signed in, wrong tenant, extension stack-hci missing, the instance not found); 2 a value in the file is missing
    or not usable. Nothing is sent to Azure on exit code 2.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Enable-WindowsServerSubscription.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows the state of the add-on and whether it would be turned on. Changes nothing.
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
# The value of the desired state that the add-on is on. Fixed by the Azure Stack HCI resource provider (Learn: Activate Windows Server VMs on Azure Local).
$EnabledState = 'Enabled'
# The Azure CLI is started through a command file on Windows. These characters would be read as commands there, so no value that holds one is sent.
$UnsafeArgument = '[&|<>^%"`\r\n]'

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
# The desired state of the add-on, as az returns it: at the top of the object or under properties.
function Get-State($Cluster) {
    foreach ($node in @($Cluster, $(if ($Cluster -and $Cluster.PSObject.Properties['properties']) { $Cluster.properties }))) {
        if ($node -and $node.PSObject.Properties['desiredProperties'] -and $node.desiredProperties -and $node.desiredProperties.PSObject.Properties['windowsServerSubscription'] -and $node.desiredProperties.windowsServerSubscription) {
            return [string]$node.desiredProperties.windowsServerSubscription
        }
    }
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
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Enable-WindowsServerSubscription.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }
try { $null = Invoke-Az extension show --name stack-hci --output none }
catch { Exit-Failed 'The Azure CLI extension stack-hci is not installed. This script does not install it. Run: az extension add --name stack-hci' }

$row = [ordered]@{ Cluster = $clusterName; Action = ''; State = ''; Detail = '' }
try {
    $cluster = $null
    try { $cluster = Invoke-Az stack-hci cluster show --subscription $subscriptionId --resource-group $group --name $clusterName --output json | ConvertFrom-Json }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    if (-not $cluster) { throw "The Azure Local instance '$clusterName' was not found in the resource group '$group'. Deploy it first, then run this script." }

    $state = Get-State $cluster
    $row.State = $state
    if ($state -ieq $EnabledState) {
        $row.Action = 'AlreadyEnabled'
        Write-Line "[exists]  The Windows Server subscription add-on is already Enabled on '$clusterName', nothing changed."
    }
    elseif ($PSCmdlet.ShouldProcess("Azure Local instance '$clusterName' in '$group'", 'Turn on the Windows Server subscription add-on (a paid add-on; at no extra cost with Azure Hybrid Benefit)')) {
        $null = Invoke-Az stack-hci cluster update --subscription $subscriptionId --resource-group $group --name $clusterName --desired-properties "windows-server-subscription=$EnabledState" --output none
        $after = Invoke-Az stack-hci cluster show --subscription $subscriptionId --resource-group $group --name $clusterName --output json | ConvertFrom-Json
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

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
