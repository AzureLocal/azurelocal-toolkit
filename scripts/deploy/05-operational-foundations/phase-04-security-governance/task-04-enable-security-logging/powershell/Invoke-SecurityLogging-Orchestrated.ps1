<#
.SYNOPSIS
    Collects the Windows Security, System and Application event logs of the Azure Local machines into the Log Analytics workspace: creates the data
    collection rule of operations.security_logging and associates it with the Arc machine of every node. Idempotent.

.DESCRIPTION
    Operational foundations, phase 04 (security and governance), Task 04 (enable security logging). Microsoft Learn (Collect Windows events with
    Azure Monitor Agent; Data collection rule samples): a data collection rule with a windowsEventLogs data source (the Microsoft-Event stream) and a
    Log Analytics destination makes the Azure Monitor Agent send the selected events to the Event table of the workspace. The Security log of such a
    rule goes to the Event table with the other logs; the SecurityEvent table is filled only by the paid Windows Security Events via AMA connector of a security analytics product, which the toolkit does not set up. Query the events with: Event | where EventLog == "Security".

    What the rule collects (the choices the portal offers, from the file):
      Security     operations.security_logging.security_audit: success_and_failure (Audit success and Audit failure) or failure (Audit failure).
      System and   operations.security_logging.event_levels: any of critical, error, warning, information, verbose (default critical, error,
      Application  warning).

    Steps:
      1. Checks (read only): operations.monitoring.enabled is true, the workspace operations.monitoring.log_analytics_workspace exists in
         operations.monitoring.workspace_resource_group, and the Azure Monitor Agent extension (AzureMonitorWindowsAgent) is on the instance
         (Install-AzureMonitorAgent.ps1, phase 02 task 02).
      2. The rule operations.security_logging.data_collection_rule in the workspace resource group and the region of the workspace. A rule that
         exists is checked and never changed: when it sends to another workspace or collects other queries than the file says, the run fails and no
         node is associated (change the rule in the portal, or name another rule). A missing rule is created (kind Windows, the file-level tags).
      3. One association per node, with the Arc machine (Microsoft.HybridCompute/machines) of nodes[] in azure.resource_group, named
         <machine>-<rule>. An association to the rule that exists is left alone; an association of that name to another rule is a Conflict.

    With operations.security_logging.enabled false or absent the script does nothing and exits 0. -WhatIf reads Azure and changes nothing.
    Each node is billed for the data its events add to the workspace (Learn: Azure Monitor Logs pricing); collect only what you need.

    The script does not sign in: run Connect-AzAccount -Tenant <azure.tenant_id> first. It needs Monitoring Contributor on the workspace resource
    group and on the Arc machines, and Log Analytics Contributor on the workspace.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        operations.security_logging.enabled, data_collection_rule, security_audit, event_levels
        operations.monitoring.enabled, log_analytics_workspace, workspace_resource_group
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name, tags, nodes[] (name, arc_machine_name)

    Exit codes: 0 the rule and every association are in place (created now, already there, planned under -WhatIf, or not asked for); 1 an Azure call
    or a precondition failed (Az missing, not signed in, wrong tenant, no workspace, no agent, the rule differs, an association failed or
    conflicts); 2 a value in the file is missing or not usable. On exit code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Invoke-SecurityLogging-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./Invoke-SecurityLogging-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml
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
$ResourceGroupPattern = '^[-\w\._\(\)]{1,90}$'
$RuleNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{1,62}[A-Za-z0-9_]$'
# Fixed by Microsoft (Learn, Azure Arc extension management on Azure Local): the agent extension and the one Arc setting of an instance.
$AgentExtensionName = 'AzureMonitorWindowsAgent'
$ArcSettingName = 'default'
# Learn (Collect Windows events with Azure Monitor Agent, the XPath the portal writes): the Security keywords of Audit success (0x20000000000000)
# and Audit failure (0x10000000000000), and the event levels 1 Critical, 2 Error, 3 Warning, 4 and 0 Information, 5 Verbose.
$AuditSuccess = 9007199254740992
$AuditFailure = 4503599627370496
$LevelFilter = [ordered]@{ critical = 'Level=1'; error = 'Level=2'; warning = 'Level=3'; information = 'Level=4 or Level=0'; verbose = 'Level=5' }
$Stream = 'Microsoft-Event'
$DestinationName = 'workspace'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-RuleField([object]$Object, [string]$Name) { if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $null } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$enabled = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.security_logging.enabled'
if ($null -ne $enabled -and $enabled -isnot [bool]) { Exit-InputProblem "operations.security_logging.enabled must be true or false; found '$enabled'." }
if ($enabled -ne $true) { Write-Line 'operations.security_logging.enabled is not true: nothing to do.'; exit 0 }
if ((Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring.enabled') -ne $true) { Exit-InputProblem 'operations.security_logging.enabled is true, but operations.monitoring.enabled is not: the events go to the workspace of operations.monitoring.' }

$ruleName = Get-Text 'operations.security_logging.data_collection_rule'
if ($ruleName -notmatch $RuleNamePattern) { Exit-InputProblem "operations.security_logging.data_collection_rule '$ruleName' is missing or not a valid rule name (3 to 64 letters, digits, . _ -)." }
$audit = Get-Text 'operations.security_logging.security_audit'
if (-not $audit) { $audit = 'success_and_failure' }
if ($audit -notin 'success_and_failure', 'failure') { Exit-InputProblem "operations.security_logging.security_audit must be success_and_failure or failure; found '$audit'." }
$levelsValue = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.security_logging.event_levels'
$levels = @(@($levelsValue) | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
if ($levels.Count -eq 0) { $levels = @('critical', 'error', 'warning') }
$unknown = @($levels | Where-Object { -not $LevelFilter.Contains($_) })
if ($unknown) { Exit-InputProblem "operations.security_logging.event_levels holds values that are not levels: $($unknown -join ', '). Use critical, error, warning, information, verbose." }

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$armGroup = Get-Text 'azure.resource_group'
$clusterName = Get-Text 'cluster.name'
$workspaceName = Get-Text 'operations.monitoring.log_analytics_workspace'
$group = Get-Text 'operations.monitoring.workspace_resource_group'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if ($armGroup -notmatch $ResourceGroupPattern) { Exit-InputProblem 'azure.resource_group is missing or not valid. It is the resource group of the instance and of its Arc machines.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. The Azure Monitor Agent extension is read on the instance.' }
if (-not $workspaceName) { Exit-InputProblem 'operations.monitoring.log_analytics_workspace is missing. The events go to that workspace.' }
if ($group -notmatch $ResourceGroupPattern) { Exit-InputProblem 'operations.monitoring.workspace_resource_group is missing or not valid. The rule is created there.' }
$machines = [System.Collections.Generic.List[string]]::new()
foreach ($node in @(Get-AzlInfrastructureNode -Infrastructure $infra)) { if ($node.ArcMachineName -and -not @($machines | Where-Object { $_ -ieq $node.ArcMachineName })) { $machines.Add([string]$node.ArcMachineName) } }
if ($machines.Count -eq 0) { Exit-InputProblem 'nodes[] lists no machine. The rule is associated with the Arc machine of every node.' }
$tags = @{}
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

# The XPath queries of the rule, as the portal writes them.
$keywords = if ($audit -eq 'failure') { $AuditFailure } else { $AuditSuccess + $AuditFailure }
$levelText = ($levels | ForEach-Object { $LevelFilter[$_] }) -join ' or '
$queries = @(
    "Security!*[System[(band(Keywords,$keywords))]]"
    "System!*[System[($levelText)]]"
    "Application!*[System[($levelText)]]"
)

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzOperationalInsightsWorkspace', 'Get-AzStackHciExtension', 'Get-AzDataCollectionRule', 'New-AzDataCollectionRule', 'Get-AzDataCollectionRuleAssociation', 'New-AzDataCollectionRuleAssociation') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts, Az.OperationalInsights, Az.StackHCI and Az.Monitor modules: Install-Module Az.Accounts, Az.OperationalInsights, Az.StackHCI, Az.Monitor -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Kind, [string]$Name, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Kind = $Kind; Name = $Name; Action = $Action; Detail = $Detail })
    $tag = switch -Wildcard ($Action) { 'Failed' { '[failed]  ' } 'Conflict' { '[failed]  ' } 'Already*' { '[exists]  ' } 'Would*' { '[plan]    ' } default { '[created] ' } }
    Write-Line ("{0}{1} {2}{3}" -f $tag, $Kind, $Name, $(if ($Detail) { " ($Detail)" } else { '' }))
}

try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop

    $workspace = $null
    try { $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $group -Name $workspaceName -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    if (-not $workspace) { Exit-Failed "The Log Analytics workspace '$workspaceName' does not exist in '$group'. Run Deploy-LogAnalyticsWorkspace.ps1 (phase 02, task 01) first." }
    $workspaceId = [string]$workspace.ResourceId
    $location = [string]$workspace.Location

    $agent = $null
    try { $agent = Get-AzStackHciExtension -ClusterName $clusterName -ResourceGroupName $armGroup -ArcSettingName $ArcSettingName -Name $AgentExtensionName -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    if (-not $agent) { Exit-Failed "The Azure Monitor Agent extension ($AgentExtensionName) is not installed on the instance '$clusterName'. Run Install-AzureMonitorAgent.ps1 (phase 02, task 02) first." }

    # ---- the rule
    $rule = $null
    try { $rule = Get-AzDataCollectionRule -Name $ruleName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    $ruleId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Insights/dataCollectionRules/$ruleName"
    if ($rule) {
        if ($rule.PSObject.Properties['Id'] -and $rule.Id) { $ruleId = [string]$rule.Id }
        $haveQueries = @(foreach ($source in @(Get-RuleField $rule 'DataSourceWindowsEventLog')) { foreach ($q in @(Get-RuleField $source 'XPathQuery')) { if ($q) { [string]$q } } })
        $haveWorkspaces = @(foreach ($d in @(Get-RuleField $rule 'DestinationLogAnalytic')) { $w = Get-RuleField $d 'WorkspaceResourceId'; if ($w) { [string]$w } })
        $problems = @()
        if (-not @($haveWorkspaces | Where-Object { $_ -ieq $workspaceId })) { $problems += "it sends to [$($haveWorkspaces -join ', ')], not to '$workspaceName'" }
        $missing = @($queries | Where-Object { $_ -notin $haveQueries })
        $extra = @($haveQueries | Where-Object { $_ -notin $queries })
        if ($missing) { $problems += "it lacks the queries $($missing -join '; ')" }
        if ($extra) { $problems += "it holds queries the file does not ask for: $($extra -join '; ')" }
        if ($problems) {
            Add-Row 'Rule' $ruleName 'Failed' "the rule exists but differs from the file: $($problems -join '; '). The script never changes a rule: change it in the portal or name another rule in operations.security_logging.data_collection_rule. No node was associated."
            $rows; exit 1
        }
        Add-Row 'Rule' $ruleName 'AlreadyExists' "sends to '$workspaceName'"
    }
    elseif ($PSCmdlet.ShouldProcess("data collection rule '$ruleName' in '$group'", "Create (Security $audit; System and Application $($levels -join ', '); to '$workspaceName')")) {
        $body = [ordered]@{
            location   = $location
            kind       = 'Windows'
            properties = [ordered]@{
                description  = "Windows Security, System and Application event logs of the Azure Local instance $clusterName"
                dataSources  = [ordered]@{ windowsEventLogs = @([ordered]@{ name = 'eventLogs'; streams = @($Stream); xPathQueries = $queries }) }
                destinations = [ordered]@{ logAnalytics = @([ordered]@{ name = $DestinationName; workspaceResourceId = $workspaceId }) }
                dataFlows    = @([ordered]@{ streams = @($Stream); destinations = @($DestinationName) })
            }
        }
        if ($tags.Count) { $body.tags = $tags }
        $created = New-AzDataCollectionRule -Name $ruleName -ResourceGroupName $group -SubscriptionId $subscriptionId -JsonString ($body | ConvertTo-Json -Depth 10) -ErrorAction Stop
        if ($created -and $created.PSObject.Properties['Id'] -and $created.Id) { $ruleId = [string]$created.Id }
        Add-Row 'Rule' $ruleName 'Created' "in $location, to '$workspaceName'"
    }
    else { Add-Row 'Rule' $ruleName 'WouldCreate' "Security $audit; System and Application $($levels -join ', '); to '$workspaceName'" }

    # ---- the associations, one per node
    foreach ($machine in $machines) {
        $machineId = "/subscriptions/$subscriptionId/resourceGroups/$armGroup/providers/Microsoft.HybridCompute/machines/$machine"
        $associationName = "$machine-$ruleName"
        try {
            $have = @(Get-AzDataCollectionRuleAssociation -TargetResourceId $machineId -ErrorAction Stop)
            $same = @($have | Where-Object { $_.PSObject.Properties['DataCollectionRuleId'] -and [string]$_.DataCollectionRuleId -ieq $ruleId })
            $sameName = @($have | Where-Object { $_.PSObject.Properties['Name'] -and [string]$_.Name -ieq $associationName })
            if ($same.Count -gt 0) { Add-Row 'Association' $machine 'AlreadyExists' "with '$ruleName'" }
            elseif ($sameName.Count -gt 0) { Add-Row 'Association' $machine 'Conflict' "the association '$associationName' points to another rule; left unchanged" }
            elseif ($PSCmdlet.ShouldProcess("Arc machine '$machine'", "Associate with data collection rule '$ruleName'")) {
                $null = New-AzDataCollectionRuleAssociation -TargetResourceId $machineId -DataCollectionRuleId $ruleId -AssociationName $associationName -ErrorAction Stop
                Add-Row 'Association' $machine 'Created' "with '$ruleName'"
            }
            else { Add-Row 'Association' $machine 'WouldCreate' "with '$ruleName'" }
        }
        catch { Add-Row 'Association' $machine 'Failed' $_.Exception.Message }
    }
}
catch { Add-Row 'Azure' $subscriptionId 'Failed' $_.Exception.Message }
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Warning "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$rows
if (@($rows | Where-Object { $_.Action -in 'Failed', 'Conflict' })) { exit 1 }
exit 0
