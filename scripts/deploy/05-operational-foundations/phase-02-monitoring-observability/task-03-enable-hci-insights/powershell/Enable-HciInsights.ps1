<#
.SYNOPSIS
    Enables Insights for Azure Local: associates the Insights data collection rule with the Arc machine of every node.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 03 (Insights). Insights for Azure Local (Microsoft Learn, Monitor a single Azure Local system with
    Insights, and Enable Insights for Azure Local at scale using Azure policies) needs the Azure Monitor Agent on the nodes
    (Install-AzureMonitorAgent.ps1, task 02) and an association of a data collection rule with every node. This script does the association.

    ONE STEP STAYS IN THE PORTAL: creating the rule. Learn documents no template for the rule of Insights and says not to build your own, because the
    rule the portal creates includes a special data stream that Insights needs. So this script never creates or changes a rule. Enable Insights once
    for this instance in the Azure portal (the instance, Capabilities, Insights, Get Started; Learn: Monitor a single Azure Local system with
    Insights, Enable Insights) and name the rule it uses, or the one it creates, in operations.monitoring.data_collection_rule (the rule must be in
    operations.monitoring.workspace_resource_group). Then run this script. When the rule does not exist the script stops with exit 1 and says so.

    When the rule exists, the script associates it with the Arc machine (Microsoft.HybridCompute/machines) of every entry of nodes[], in
    azure.resource_group, with the association name <machine>-dataCollectionRuleAssociations that the Learn policy uses.

    When operations.monitoring.enabled is false the design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent. An association that exists is reported as AlreadyExists and left alone. An association with the right name that points to another
    rule is reported as Conflict, never changed, and the script ends with exit code 1. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzDataCollectionRuleAssociation, behind -WhatIf. It does not sign in: run
    Connect-AzAccount to the tenant in azure.tenant_id first. You need Monitoring Contributor (or Contributor) on the resource group.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name, nodes[] (name, arc_machine_name)
        operations.monitoring.enabled                               false means: do nothing
        operations.monitoring.workspace_resource_group              the resource group of the rule
        operations.monitoring.data_collection_rule                  the name of the existing rule

    Exit codes: 0 every node is associated (created now, already there, planned under -WhatIf) or monitoring is switched off in the file; 1 an Azure
    call failed or a precondition failed (not signed in, wrong tenant, Az modules missing, no Azure Monitor Agent on the instance, the rule does not
    exist, an association failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Enable-HciInsights.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which nodes would be associated with the rule, and changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Enable-HciInsights.ps1 -InfrastructureFile ./infrastructure.yml

    Associates the rule with every node. Run it again: every row is AlreadyExists.
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

# Fixed by Microsoft (Learn, Azure Arc extension management on Azure Local): the extension and the one Arc setting of an instance.
$AgentExtensionName = 'AzureMonitorWindowsAgent'
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
$armGroup = Get-Text 'azure.resource_group'
$clusterName = Get-Text 'cluster.name'
$monitoring = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring'

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($monitoring -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'operations.monitoring is missing. Name the data collection rule of Insights.' }
if ((Get-Text 'operations.monitoring.enabled').ToLowerInvariant() -eq 'false') {
    Write-Line 'operations.monitoring.enabled is false: Azure Monitor is not part of the design, so Insights is not enabled.'
    exit 0
}
$group = Get-Text 'operations.monitoring.workspace_resource_group'
$ruleName = Get-Text 'operations.monitoring.data_collection_rule'
if (-not $group) { Exit-InputProblem 'operations.monitoring.workspace_resource_group is missing. It is the resource group of the data collection rule.' }
if (-not $ruleName) { Exit-InputProblem 'operations.monitoring.data_collection_rule is missing. Name the data collection rule that Insights uses (create it once in the Azure portal).' }
if ($ruleName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { Exit-InputProblem "operations.monitoring.data_collection_rule '$ruleName' is not a valid name (1 to 64 letters, digits, . _ -; starts with a letter or digit)." }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $armGroup) { Exit-InputProblem 'azure.resource_group is missing. It is the resource group of the instance and of its Arc machines.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. It is the Azure Local instance the Azure Monitor Agent runs on.' }
$machines = [System.Collections.Generic.List[string]]::new()
foreach ($node in @(Get-AzlInfrastructureNode -Infrastructure $infra)) {
    if ($node.ArcMachineName -and -not @($machines | Where-Object { $_ -ieq $node.ArcMachineName })) { $machines.Add([string]$node.ArcMachineName) }
}
if ($machines.Count -eq 0) { Exit-InputProblem 'nodes[] lists no machine. The data collection rule is associated with the Arc machine of every node.' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzStackHciExtension', 'Get-AzDataCollectionRule', 'Get-AzDataCollectionRuleAssociation', 'New-AzDataCollectionRuleAssociation') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts, Az.StackHCI and Az.Monitor modules: Install-Module Az.Accounts, Az.StackHCI, Az.Monitor -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$rows = [System.Collections.Generic.List[object]]::new()
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop

    # the Azure Monitor Agent must be on the instance (task 02)
    $agent = $null
    try { $agent = Get-AzStackHciExtension -ClusterName $clusterName -ResourceGroupName $armGroup -ArcSettingName $ArcSettingName -Name $AgentExtensionName -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The extensions of the instance '$clusterName' could not be read: $($_.Exception.Message)" } }
    if (-not $agent) { Exit-Failed "The Azure Monitor Agent extension ($AgentExtensionName) is not installed on the instance '$clusterName'. Run Install-AzureMonitorAgent.ps1 (task 02) first." }

    # the rule must exist: this script never creates or changes it
    $rule = $null
    try { $rule = Get-AzDataCollectionRule -Name $ruleName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The data collection rule '$ruleName' could not be read: $($_.Exception.Message)" } }
    if (-not $rule) {
        Exit-Failed "The data collection rule '$ruleName' does not exist in '$group'. Microsoft Learn documents no way to create the Insights rule from a script, and says not to build your own: enable Insights once for the instance '$clusterName' in the Azure portal (the instance, Capabilities, Insights, Get Started; Learn: Monitor a single Azure Local system with Insights), choose or name the rule so that it matches operations.monitoring.data_collection_rule and sits in '$group', then run this script again."
    }
    $ruleId = if ($rule.PSObject.Properties['Id'] -and $rule.Id) { [string]$rule.Id } else { "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Insights/dataCollectionRules/$ruleName" }
    Write-Line "Insights data collection rule '$ruleName' in '$group', $($machines.Count) node(s)"

    # ---- the associations, one per node
    foreach ($machine in $machines) {
        $row = [ordered]@{ Kind = 'Association'; Name = $machine; Action = ''; Detail = '' }
        try {
            $machineId = "/subscriptions/$subscriptionId/resourceGroups/$armGroup/providers/Microsoft.HybridCompute/machines/$machine"
            $associationName = "$machine-dataCollectionRuleAssociations"
            $have = @(Get-AzDataCollectionRuleAssociation -TargetResourceId $machineId -ErrorAction Stop)
            $same = @($have | Where-Object { $_.PSObject.Properties['DataCollectionRuleId'] -and [string]$_.DataCollectionRuleId -ieq $ruleId })
            $sameName = @($have | Where-Object { $_.PSObject.Properties['Name'] -and [string]$_.Name -ieq $associationName })
            if ($same.Count -gt 0) {
                $row.Action = 'AlreadyExists'
                Write-Line "[exists]  '$machine' is already associated with '$ruleName'."
            }
            elseif ($sameName.Count -gt 0) {
                $row.Action = 'Conflict'
                $row.Detail = "The association '$associationName' points to another rule; left unchanged, so this node is not associated with '$ruleName'. Remove that association by hand, then run this script again."
                Write-Warning "${machine}: $($row.Detail)"
            }
            elseif ($PSCmdlet.ShouldProcess("Arc machine '$machine'", "Associate with data collection rule '$ruleName'")) {
                $null = New-AzDataCollectionRuleAssociation -TargetResourceId $machineId -DataCollectionRuleId $ruleId -AssociationName $associationName -ErrorAction Stop
                $row.Action = 'Created'
                Write-Line "[created] '$machine' is associated with '$ruleName'."
            }
            else {
                $row.Action = 'WouldCreate'
                Write-Line "[plan]    '$machine' would be associated with '$ruleName'."
            }
        }
        catch {
            $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
            Write-Warning "${machine}: $($row.Detail)"
        }
        $rows.Add([pscustomobject]$row)
    }
}
catch { Exit-Failed "An Azure call failed (the subscription $subscriptionId, the agent or the rule): $($_.Exception.Message)" }
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$rows
if (@($rows | Where-Object { $_.Action -in 'Failed', 'Conflict' })) { exit 1 }
exit 0
