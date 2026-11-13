<#
.SYNOPSIS
    Installs the Azure Monitor Agent extension on the Azure Local instance that infrastructure.yml describes.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 02 (Azure Monitor Agent). Insights for Azure Local collects its data with the Azure Monitor Agent.
    Microsoft Learn (Azure Arc extension management on Azure Local) documents one way to install it from automation: one extension on the instance,
    through the Azure Local resource provider, which installs it on every node and adds it to a node that joins later. This script does exactly
    that, with New-AzStackHciExtension: the extension AzureMonitorWindowsAgent, publisher Microsoft.Azure.Monitor, on the Arc setting "default" of
    the instance cluster.name in azure.resource_group.

    It does not install anything machine by machine, no Log Analytics (MMA) agent, and no Linux agent. It sets no automatic upgrade: Learn says
    the upgrade happens during the solution update. It does not create the data collection rule or the associations (Enable-HciInsights.ps1, task 03).

    When operations.monitoring.enabled is false the design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent. An extension that exists is reported as AlreadyExists and left alone (its provisioning state is reported). -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzStackHciExtension, behind -WhatIf. It does not sign in: run Connect-AzAccount to
    the tenant in azure.tenant_id first. You need Contributor on the resource group of the instance.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name
        operations.monitoring.enabled                    false means: do nothing

    Exit codes: 0 the extension is on the instance (installed now, already there, planned under -WhatIf) or monitoring is switched off in the file;
    1 an Azure call failed or a precondition failed (not signed in, wrong tenant, Az modules missing, the instance does not exist, the installation
    failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Install-AzureMonitorAgent.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the extension would be installed, and installs nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Install-AzureMonitorAgent.ps1 -InfrastructureFile ./infrastructure.yml

    Installs the extension on the instance. Run it again: it is reported as AlreadyExists.
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
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzStackHciCluster', 'Get-AzStackHciExtension', 'New-AzStackHciExtension') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.StackHCI modules: Install-Module Az.Accounts, Az.StackHCI -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$row = [ordered]@{ Extension = $ExtensionName; Cluster = $clusterName; Action = ''; Detail = '' }
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop

    # the instance must exist; this script does not create it
    $cluster = $null
    try { $cluster = Get-AzStackHciCluster -Name $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The instance '$clusterName' could not be read: $($_.Exception.Message)" } }
    if (-not $cluster) { Exit-Failed "The Azure Local instance '$clusterName' does not exist in '$group' of the subscription of azure.subscription_id." }
    Write-Line "Azure Monitor Agent on the instance '$clusterName' in '$group'"

    $existing = $null
    try { $existing = Get-AzStackHciExtension -ClusterName $clusterName -ResourceGroupName $group -ArcSettingName $ArcSettingName -Name $ExtensionName -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        Write-Line "[exists]  $ExtensionName is already on '$clusterName', nothing changed."
        $state = if ($existing.PSObject.Properties['ProvisioningState'] -and $existing.ProvisioningState) { [string]$existing.ProvisioningState } else { '' }
        if ($state -and $state -ne 'Succeeded') {
            $row.Detail = "Its provisioning state is $state. Look at the Extensions page of the instance in the Azure portal."
            Write-Warning "${ExtensionName}: $($row.Detail)"
        }
    }
    elseif ($PSCmdlet.ShouldProcess("instance '$clusterName' in '$group'", "Install the extension $ExtensionName")) {
        $null = New-AzStackHciExtension -ClusterName $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -ArcSettingName $ArcSettingName -Name $ExtensionName `
            -ExtensionParameterPublisher $ExtensionPublisher -ExtensionParameterType $ExtensionName -ErrorAction Stop
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
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
