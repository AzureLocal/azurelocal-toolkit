<#
.SYNOPSIS
    Installs the Azure Monitor Agent extension on the Azure Local instance that infrastructure.yml describes, with the Azure CLI.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 02 (Azure Monitor Agent), Azure CLI variant of Install-AzureMonitorAgent.ps1. Insights for Azure Local
    collects its data with the Azure Monitor Agent. Microsoft Learn (Azure Arc extension management on Azure Local) documents one way to install it from
    automation: one extension on the instance, through the Azure Local resource provider, which installs it on every node and adds it to a node that
    joins later. This script does exactly that, with az stack-hci extension create: the extension AzureMonitorWindowsAgent, publisher
    Microsoft.Azure.Monitor, on the Arc setting "default" of the instance cluster.name in azure.resource_group.

    It does not install anything machine by machine, no Log Analytics (MMA) agent, and no Linux agent. It sets no automatic upgrade: Learn says the
    upgrade happens during the solution update. It does not create the data collection rule or the associations (Enable-HciInsights.azcli.ps1, task 03).

    When operations.monitoring.enabled is false the design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent. An extension that exists is reported as AlreadyExists and left alone (its provisioning state is reported). -WhatIf changes nothing.

    The script needs the Azure CLI extension stack-hci (az extension add --name stack-hci); it does not install it. It does not sign in: run az login to
    the tenant in azure.tenant_id first. It does not change the Azure CLI default subscription: every call carries --subscription. You need Contributor on
    the resource group of the instance.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name
        operations.monitoring.enabled                    false means: do nothing

    Exit codes: 0 the extension is on the instance (installed now, already there, planned under -WhatIf) or monitoring is switched off in the file; 1 an
    Azure call failed or a precondition failed (az missing, not signed in, wrong tenant, extension stack-hci missing, the instance does not exist, the
    installation failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Install-AzureMonitorAgent.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the extension would be installed, and installs nothing.
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

# Fixed by Microsoft (Learn, Azure Arc extension management on Azure Local): the extension, its publisher and the one Arc setting of an instance.
$ExtensionName = 'AzureMonitorWindowsAgent'
$ExtensionPublisher = 'Microsoft.Azure.Monitor'
$ArcSettingName = 'default'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { $v = Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }
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
$group = Get-Text 'azure.resource_group'
$clusterName = Get-Text 'cluster.name'
$monitoring = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring'

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($monitoring -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'operations.monitoring is missing. Say whether Azure Monitor is part of the design.' }
if ((Get-Text 'operations.monitoring.enabled').ToLowerInvariant() -eq 'false') {
    Write-Line 'operations.monitoring.enabled is false: Azure Monitor is not part of the design, so the Azure Monitor Agent is not installed.'
    exit 0
}
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. It is the resource group of the Azure Local instance.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. It is the Azure Local instance the agent is installed on.' }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Install-AzureMonitorAgent.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }
try { $null = Invoke-Az extension show --name stack-hci --output none }
catch { Exit-Failed 'The Azure CLI extension stack-hci is not installed. This script does not install it. Run: az extension add --name stack-hci' }

$row = [ordered]@{ Extension = $ExtensionName; Cluster = $clusterName; Action = ''; Detail = '' }
try {
    # the instance must exist; this script does not create it
    try { $null = Invoke-Az stack-hci cluster show --subscription $subscriptionId --resource-group $group --cluster-name $clusterName --output none }
    catch {
        if ($_.Exception.Message -match $NotFound) { Exit-Failed "The Azure Local instance '$clusterName' does not exist in '$group' of the subscription of azure.subscription_id." }
        Exit-Failed "The instance '$clusterName' could not be read: $($_.Exception.Message)"
    }
    Write-Line "Azure Monitor Agent on the instance '$clusterName' in '$group'"

    $existing = $null
    try { $existing = Invoke-Az stack-hci extension show --subscription $subscriptionId --resource-group $group --cluster-name $clusterName --arc-setting-name $ArcSettingName --name $ExtensionName --output json | ConvertFrom-Json }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        Write-Line "[exists]  $ExtensionName is already on '$clusterName', nothing changed."
        $state = ''
        if ($existing.PSObject.Properties['provisioningState'] -and $existing.provisioningState) { $state = [string]$existing.provisioningState }
        elseif ($existing.PSObject.Properties['properties'] -and $existing.properties -and $existing.properties.PSObject.Properties['provisioningState']) { $state = [string]$existing.properties.provisioningState }
        if ($state -and $state -ne 'Succeeded') {
            $row.Detail = "Its provisioning state is $state. Look at the Extensions page of the instance in the Azure portal."
            Write-Warning "${ExtensionName}: $($row.Detail)"
        }
    }
    elseif ($PSCmdlet.ShouldProcess("instance '$clusterName' in '$group'", "Install the extension $ExtensionName")) {
        $null = Invoke-Az stack-hci extension create --subscription $subscriptionId --resource-group $group --cluster-name $clusterName --arc-setting-name $ArcSettingName --name $ExtensionName --publisher $ExtensionPublisher --type $ExtensionName --output none
        $row.Action = 'Created'
        Write-Line "[created] $ExtensionName on '$clusterName'."
    }
    else {
        $row.Action = 'WouldCreate'
        Write-Line "[plan]    $ExtensionName would be installed on '$clusterName'."
    }
}
catch {
    $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
    Write-Warning "${ExtensionName}: $($row.Detail)"
}

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
