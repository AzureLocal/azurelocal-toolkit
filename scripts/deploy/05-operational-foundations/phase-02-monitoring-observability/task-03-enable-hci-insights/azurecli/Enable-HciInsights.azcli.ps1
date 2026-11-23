<#
.SYNOPSIS
    Enables Insights for Azure Local with the Azure CLI: associates the Insights data collection rule with the Arc machine of every node.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 03 (Insights), Azure CLI variant of Enable-HciInsights.ps1. Insights for Azure Local (Microsoft Learn,
    Monitor a single Azure Local system with Insights, and Enable Insights for Azure Local at scale using Azure policies) needs the Azure Monitor Agent on
    the nodes (Install-AzureMonitorAgent.azcli.ps1, task 02) and an association of a data collection rule with every node. This script does the
    association.

    ONE STEP STAYS IN THE PORTAL: creating the rule. Learn documents no template for the rule of Insights and says not to build your own, because the
    rule the portal creates includes a special data stream that Insights needs. So this script never creates or changes a rule. Enable Insights once for
    this instance in the Azure portal (the instance, Capabilities, Insights, Get Started) and name the rule it uses, or the one it creates, in
    operations.monitoring.data_collection_rule (the rule must be in operations.monitoring.workspace_resource_group). Then run this script. When the rule
    does not exist the script stops with exit 1 and says so.

    When the rule exists, the script first checks it, read only, against what Learn lists for Insights (Monitor a single Azure Local system with
    Insights, Data collection rules): the performance counters Memory\Available Bytes, Network Interface\Bytes Total/sec, Processor\% Processor
    Time, RDMA Activity\RDMA Inbound Bytes/sec and RDMA Activity\RDMA Outbound Bytes/sec (any instance), the event log channels
    Microsoft-Windows-Health/Operational and Microsoft-Windows-SDDC-Management/Operational, and a Log Analytics destination, which must be the
    workspace operations.monitoring.log_analytics_workspace in operations.monitoring.workspace_resource_group when that key is set. When something
    is missing the script stops with exit 1, lists it and associates nothing: Learn's way back is the portal (the instance, Capabilities,
    Insights, Update). The rule is never changed.

    Then the script associates the rule with the Arc machine (Microsoft.HybridCompute/machines) of every entry of nodes[], in
    azure.resource_group, with the association name <machine>-dataCollectionRuleAssociations that the Learn policy uses
    (az monitor data-collection rule association create).

    When operations.monitoring.enabled is false the design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent. An association that exists is reported as AlreadyExists and left alone. An association with the right name that points to another rule is
    reported as Conflict, never changed, and the script ends with exit code 1. -WhatIf changes nothing.

    The script needs the Azure CLI extensions stack-hci and monitor-control-service (az monitor data-collection); it installs neither (az extension add
    --name stack-hci, az extension add --name monitor-control-service). It does not sign in: run az login to
    the tenant in azure.tenant_id first. It does not change the Azure CLI default subscription. You need Monitoring Contributor (or Contributor) on the
    resource group.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name, nodes[] (name, arc_machine_name)
        operations.monitoring.enabled                               false means: do nothing
        operations.monitoring.workspace_resource_group              the resource group of the rule
        operations.monitoring.data_collection_rule                  the name of the existing rule
        operations.monitoring.log_analytics_workspace               optional: the workspace the rule must send to

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every node is associated (created now, already there, planned under -WhatIf) or monitoring is switched off in the file; 1 an Azure call
    failed or a precondition failed (az missing, not signed in, wrong tenant, extension stack-hci or monitor-control-service missing, no Azure Monitor
    Agent on the instance, the rule
    does not exist or lacks what Insights needs, an association failed or is in conflict); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Enable-HciInsights.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which nodes would be associated with the rule, and changes nothing.
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

# Fixed by Microsoft (Learn, Azure Arc extension management on Azure Local): the extension and the one Arc setting of an instance.
$AgentExtensionName = 'AzureMonitorWindowsAgent'
$ArcSettingName = 'default'

# Fixed by Microsoft (Learn, Monitor a single Azure Local system with Insights, Data collection rules): what the rule of Insights collects. A
# counter matches with any instance, with or without the leading backslash.
$InsightsCounters = [ordered]@{
    'Memory\Available Bytes'                 = '^\\?Memory(\([^)]*\))?\\Available Bytes$'
    'Network Interface\Bytes Total/sec'      = '^\\?Network Interface(\([^)]*\))?\\Bytes Total/sec$'
    'Processor(_Total)\% Processor Time'     = '^\\?Processor(\([^)]*\))?\\% Processor Time$'
    'RDMA Activity\RDMA Inbound Bytes/sec'   = '^\\?RDMA Activity(\([^)]*\))?\\RDMA Inbound Bytes/sec$'
    'RDMA Activity\RDMA Outbound Bytes/sec'  = '^\\?RDMA Activity(\([^)]*\))?\\RDMA Outbound Bytes/sec$'
}
$InsightsChannels = @('Microsoft-Windows-Health/Operational', 'Microsoft-Windows-SDDC-Management/Operational')

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { $v = Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }
# A property of an object az returned, or $null when it has none (strict mode stops on a missing property).
function Get-RuleField([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}
# What the rule lacks for Insights, one line each; nothing when it has everything.
function Get-InsightsRuleProblem([string[]]$Counters, [string[]]$Queries, [string[]]$Workspaces) {
    foreach ($counter in $InsightsCounters.Keys) {
        if (-not @($Counters | Where-Object { $_ -and $_.Trim() -match $InsightsCounters[$counter] })) { "the performance counter $counter is not collected" }
    }
    foreach ($channel in $InsightsChannels) {
        if (-not @($Queries | Where-Object { $_ -and $_.Trim().StartsWith("$channel!", [StringComparison]::OrdinalIgnoreCase) })) { "the event log channel $channel is not collected" }
    }
    $sent = @($Workspaces | Where-Object { $_ })
    if ($sent.Count -eq 0) { 'it sends to no Log Analytics workspace' }
    elseif ($workspaceName) {
        $suffix = "/resourceGroups/$group/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"
        if (-not @($sent | Where-Object { $_.TrimEnd('/').EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) })) {
            "it sends to $(($sent | ForEach-Object { $_.Split('/')[-1] }) -join ', '), not to the workspace '$workspaceName' in '$group' (operations.monitoring.log_analytics_workspace)"
        }
    }
}
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
$workspaceName = Get-Text 'operations.monitoring.log_analytics_workspace'
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
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'the machine names' = $machines }); if ($problem) { Exit-InputProblem $problem }

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A value that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $armGroup; 'cluster.name' = $clusterName; 'operations.monitoring.workspace_resource_group' = $group })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Enable-HciInsights.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }
try { $null = Invoke-Az extension show --name stack-hci --output none }
catch { Exit-Failed 'The Azure CLI extension stack-hci is not installed. This script does not install it. Run: az extension add --name stack-hci' }
# az monitor data-collection is in the extension monitor-control-service; without it az asks to install it and an unattended run stops there.
try { $null = Invoke-Az extension show --name monitor-control-service --output none }
catch { Exit-Failed 'The Azure CLI extension monitor-control-service is not installed. This script does not install it. Run: az extension add --name monitor-control-service' }

$rows = [System.Collections.Generic.List[object]]::new()
try {
    # the Azure Monitor Agent must be on the instance (task 02)
    try { $null = Invoke-Az stack-hci extension show --subscription $subscriptionId --resource-group $armGroup --cluster-name $clusterName --arc-setting-name $ArcSettingName --name $AgentExtensionName --output none }
    catch {
        if ($_.Exception.Message -match $NotFound) { Exit-Failed "The Azure Monitor Agent extension ($AgentExtensionName) is not installed on the instance '$clusterName'. Run Install-AzureMonitorAgent.azcli.ps1 (task 02) first." }
        Exit-Failed "The extensions of the instance '$clusterName' could not be read: $($_.Exception.Message)"
    }

    # the rule must exist: this script never creates or changes it
    $rule = $null
    try { $rule = Invoke-Az monitor data-collection rule show --subscription $subscriptionId --resource-group $group --name $ruleName --output json | ConvertFrom-Json }
    catch {
        if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The data collection rule '$ruleName' could not be read: $($_.Exception.Message)" }
    }
    if (-not $rule) {
        Exit-Failed "The data collection rule '$ruleName' does not exist in '$group'. Microsoft Learn documents no way to create the Insights rule from a script, and says not to build your own: enable Insights once for the instance '$clusterName' in the Azure portal (the instance, Capabilities, Insights, Get Started), choose or name the rule so that it matches operations.monitoring.data_collection_rule and sits in '$group', then run this script again."
    }
    $ruleId = if ($rule.PSObject.Properties['id'] -and $rule.id) { [string]$rule.id } else { "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Insights/dataCollectionRules/$ruleName" }

    # the rule must collect what Insights needs (read only; the rule is never changed)
    $sources = Get-RuleField $rule 'dataSources'
    $counters = @(foreach ($source in @(Get-RuleField $sources 'performanceCounters')) { foreach ($c in @(Get-RuleField $source 'counterSpecifiers')) { if ($c) { [string]$c } } })
    $queries = @(foreach ($source in @(Get-RuleField $sources 'windowsEventLogs')) { foreach ($q in @(Get-RuleField $source 'xPathQueries')) { if ($q) { [string]$q } } })
    $workspaces = @(foreach ($destination in @(Get-RuleField (Get-RuleField $rule 'destinations') 'logAnalytics')) { $w = Get-RuleField $destination 'workspaceResourceId'; if ($w) { [string]$w } })
    $problems = @(Get-InsightsRuleProblem -Counters $counters -Queries $queries -Workspaces $workspaces)
    if ($problems.Count -gt 0) {
        Exit-Failed "The data collection rule '$ruleName' is not ready for Insights, so no node is associated: $($problems -join '; '). Microsoft Learn (Monitor a single Azure Local system with Insights, Data collection rules and Update Insights) lists what the rule collects; repair it in the Azure portal (the instance '$clusterName', Capabilities, Insights, Update) or name the rule Insights created in operations.monitoring.data_collection_rule, then run this script again. This script never changes a rule."
    }
    Write-Line "The rule '$ruleName' collects the performance counters and event log channels Insights needs."
    Write-Line "Insights data collection rule '$ruleName' in '$group', $($machines.Count) node(s)"

    # ---- the associations, one per node
    foreach ($machine in $machines) {
        $row = [ordered]@{ Kind = 'Association'; Name = $machine; Action = ''; Detail = '' }
        try {
            $machineId = "/subscriptions/$subscriptionId/resourceGroups/$armGroup/providers/Microsoft.HybridCompute/machines/$machine"
            $associationName = "$machine-dataCollectionRuleAssociations"
            $have = @(@(Invoke-Az monitor data-collection rule association list-by-resource --resource $machineId --output json | ConvertFrom-Json) | Where-Object { $null -ne $_ })
            $same = @($have | Where-Object { $_.PSObject.Properties['dataCollectionRuleId'] -and [string]$_.dataCollectionRuleId -ieq $ruleId })
            $sameName = @($have | Where-Object { $_.PSObject.Properties['name'] -and [string]$_.name -ieq $associationName })
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
                $null = Invoke-Az monitor data-collection rule association create --name $associationName --rule-id $ruleId --resource $machineId --output none
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

$rows
if (@($rows | Where-Object { $_.Action -in 'Failed', 'Conflict' }).Count -gt 0) { exit 1 }
exit 0
