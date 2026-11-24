<#
.SYNOPSIS
    Collects the Windows Security, System and Application event logs of the Azure Local machines into the Log Analytics workspace, with the Azure
    CLI: creates the data collection rule of operations.security_logging and associates it with the Arc machine of every node. The Azure CLI twin of
    Invoke-SecurityLogging-Orchestrated.ps1. Idempotent.

.DESCRIPTION
    Operational foundations, phase 04 (security and governance), Task 04 (enable security logging). Same rule, same checks and same results as the
    PowerShell script; see its help for the Microsoft Learn background. In short: a windowsEventLogs data source (Microsoft-Event stream) sends the
    selected events to the Event table of the workspace; the Security log of such a rule goes there too (the SecurityEvent table is filled only by the paid Windows Security Events via AMA connector, which the toolkit does not set up).

      1. Checks (read only): operations.monitoring.enabled is true, the workspace exists (az monitor log-analytics workspace show), and the Azure
         Monitor Agent extension is on the instance (az stack-hci extension show).
      2. The rule (az monitor data-collection rule show / create --rule-file). A rule that exists is checked and never changed; when it differs
         from the file the run fails and no node is associated.
      3. One association per node (az monitor data-collection rule association list-by-resource / create), named <machine>-<rule>.

    With operations.security_logging.enabled false or absent the script does nothing and exits 0. -WhatIf reads Azure and changes nothing.

    The script does not sign in: run az login --tenant <azure.tenant_id> first. It needs the Azure CLI extension stack-hci (az extension add --name
    stack-hci) and does not install it. Every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        operations.security_logging.enabled, data_collection_rule, security_audit, event_levels
        operations.monitoring.enabled, log_analytics_workspace, workspace_resource_group
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name, tags, nodes[] (name, arc_machine_name)

    Exit codes: 0 the rule and every association are in place (created now, already there, planned under -WhatIf, or not asked for); 1 a call or a
    precondition failed (az missing, not signed in, wrong tenant, extension missing, no workspace, no agent, the rule differs, an association failed
    or conflicts); 2 a value in the file is missing or not usable. On exit code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Invoke-SecurityLogging-Orchestrated.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf
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
function Get-Text([string]$Path) { $v = Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }
function Get-RuleField([object]$Object, [string]$Name) { if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $null } }
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
$tags = [ordered]@{}
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'cluster.name' = $clusterName; 'operations.monitoring.log_analytics_workspace' = $workspaceName; 'nodes[].arc_machine_name' = ($machines -join ' ') })
if ($problem) { Exit-InputProblem $problem }

$keywords = if ($audit -eq 'failure') { $AuditFailure } else { $AuditSuccess + $AuditFailure }
$levelText = ($levels | ForEach-Object { $LevelFilter[$_] }) -join ' or '
$queries = @(
    "Security!*[System[(band(Keywords,$keywords))]]"
    "System!*[System[($levelText)]]"
    "Application!*[System[($levelText)]]"
)

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Invoke-SecurityLogging-Orchestrated.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }
try { $null = Invoke-Az extension show --name stack-hci --output none }
catch { Exit-Failed 'The Azure CLI extension stack-hci is not installed. This script does not install it. Run: az extension add --name stack-hci' }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Kind, [string]$Name, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Kind = $Kind; Name = $Name; Action = $Action; Detail = $Detail })
    $tag = switch -Wildcard ($Action) { 'Failed' { '[failed]  ' } 'Conflict' { '[failed]  ' } 'Already*' { '[exists]  ' } 'Would*' { '[plan]    ' } default { '[created] ' } }
    Write-Line ("{0}{1} {2}{3}" -f $tag, $Kind, $Name, $(if ($Detail) { " ($Detail)" } else { '' }))
}

try {
    $workspace = $null
    try { $workspace = Invoke-Az monitor log-analytics workspace show --subscription $subscriptionId --resource-group $group --workspace-name $workspaceName --output json | ConvertFrom-Json }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    if (-not $workspace) { Exit-Failed "The Log Analytics workspace '$workspaceName' does not exist in '$group'. Run Deploy-LogAnalyticsWorkspace.ps1 (phase 02, task 01) first." }
    $workspaceId = [string]$workspace.id
    $location = [string]$workspace.location

    try { $null = Invoke-Az stack-hci extension show --subscription $subscriptionId --resource-group $armGroup --cluster-name $clusterName --arc-setting-name $ArcSettingName --name $AgentExtensionName --output none }
    catch {
        if ($_.Exception.Message -match $NotFound) { Exit-Failed "The Azure Monitor Agent extension ($AgentExtensionName) is not installed on the instance '$clusterName'. Run Install-AzureMonitorAgent.ps1 (phase 02, task 02) first." }
        throw
    }

    $rule = $null
    try { $rule = Invoke-Az monitor data-collection rule show --subscription $subscriptionId --resource-group $group --name $ruleName --output json | ConvertFrom-Json }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    $ruleId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Insights/dataCollectionRules/$ruleName"
    if ($rule) {
        if ($rule.PSObject.Properties['id'] -and $rule.id) { $ruleId = [string]$rule.id }
        $sources = Get-RuleField $rule 'dataSources'
        $haveQueries = @(foreach ($source in @(Get-RuleField $sources 'windowsEventLogs')) { foreach ($q in @(Get-RuleField $source 'xPathQueries')) { if ($q) { [string]$q } } })
        $haveWorkspaces = @(foreach ($d in @(Get-RuleField (Get-RuleField $rule 'destinations') 'logAnalytics')) { $w = Get-RuleField $d 'workspaceResourceId'; if ($w) { [string]$w } })
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
        # The rule goes to az as a file: its XPath queries hold characters (! [ ] ( )) that a command line would mangle.
        $ruleFile = Join-Path ([IO.Path]::GetTempPath()) ("azl-dcr-{0}.json" -f [guid]::NewGuid().ToString('N'))
        try {
            Set-Content -LiteralPath $ruleFile -Value ($body | ConvertTo-Json -Depth 10) -Encoding utf8 -WhatIf:$false
            $created = Invoke-Az monitor data-collection rule create --subscription $subscriptionId --resource-group $group --name $ruleName --location $location --rule-file $ruleFile --output json | ConvertFrom-Json
        }
        finally { Remove-Item -LiteralPath $ruleFile -Force -ErrorAction SilentlyContinue -WhatIf:$false }
        if ($created -and $created.PSObject.Properties['id'] -and $created.id) { $ruleId = [string]$created.id }
        Add-Row 'Rule' $ruleName 'Created' "in $location, to '$workspaceName'"
    }
    else { Add-Row 'Rule' $ruleName 'WouldCreate' "Security $audit; System and Application $($levels -join ', '); to '$workspaceName'" }

    foreach ($machine in $machines) {
        $machineId = "/subscriptions/$subscriptionId/resourceGroups/$armGroup/providers/Microsoft.HybridCompute/machines/$machine"
        $associationName = "$machine-$ruleName"
        try {
            $have = @(@(Invoke-Az monitor data-collection rule association list-by-resource --resource $machineId --output json | ConvertFrom-Json) | Where-Object { $null -ne $_ })
            $same = @($have | Where-Object { [string](Get-RuleField $_ 'dataCollectionRuleId') -ieq $ruleId })
            $sameName = @($have | Where-Object { [string](Get-RuleField $_ 'name') -ieq $associationName })
            if ($same.Count -gt 0) { Add-Row 'Association' $machine 'AlreadyExists' "with '$ruleName'" }
            elseif ($sameName.Count -gt 0) { Add-Row 'Association' $machine 'Conflict' "the association '$associationName' points to another rule; left unchanged" }
            elseif ($PSCmdlet.ShouldProcess("Arc machine '$machine'", "Associate with data collection rule '$ruleName'")) {
                $null = Invoke-Az monitor data-collection rule association create --name $associationName --rule-id $ruleId --resource $machineId --output none
                Add-Row 'Association' $machine 'Created' "with '$ruleName'"
            }
            else { Add-Row 'Association' $machine 'WouldCreate' "with '$ruleName'" }
        }
        catch { Add-Row 'Association' $machine 'Failed' $_.Exception.Message }
    }
}
catch { Add-Row 'Azure' $subscriptionId 'Failed' $_.Exception.Message }

$rows
if (@($rows | Where-Object { $_.Action -in 'Failed', 'Conflict' })) { exit 1 }
exit 0
