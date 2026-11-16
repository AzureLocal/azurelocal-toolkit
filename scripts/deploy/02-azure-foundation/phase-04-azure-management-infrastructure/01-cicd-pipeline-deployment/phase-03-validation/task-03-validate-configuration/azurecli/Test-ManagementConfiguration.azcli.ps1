<#
.SYNOPSIS
    Checks with the Azure CLI the Key Vault access, the Log Analytics workspace, the diagnostic settings and the tags of the management infrastructure. Changes nothing.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), CI/CD pipeline deployment, Phase 03 (validation), Task 03 (validate configuration). The Azure side of
    the configuration checks of the guide, with az commands. One result row per check: Check, Target, Status (Pass or Fail) and Detail.

        Key Vault access      each key_vaults[]: the signed-in account can read the secret list of the vault ("az keyvault secret list"), which proves
                              the data plane and the role assignment. The guide's test writes a test secret and reads it back; this script does not
                              write to a vault, so it reads the list only. Soft delete, the retention days of the file and purge protection (on unless
                              scenario.environment_class is lab, test or dev, the rule of Deploy-KeyVaults.ps1) are checked, and the public network
                              access is shown in the detail.
        Log Analytics         operations.monitoring.log_analytics_workspace: provisioning state Succeeded and the retention days of the file.
        Diagnostic settings   the VPN gateway, the Bastion host and each Key Vault have a diagnostic setting that sends enabled logs to the workspace
                              of the file ("az monitor diagnostic-settings list").
        Tags                  every resource in each resource group of the file has each tag of the file-level tags map with the same value
                              ("az resource list").

    A part is checked only when the file describes it. The data collection and the Azure Monitor Agent are out of scope here (the Azure Local
    monitoring tasks check them).

    The script only reads. It does not sign in: run "az login --tenant <azure.tenant_id>" first. Reader on the subscriptions and a role that can list
    the secrets of each vault (for example Key Vault Secrets User) are enough. Each az call names its subscription with --subscription, so the
    subscription that az has selected is not changed.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, scenario.environment_class, tags
        landing_zone.subscriptions[].name, .id, landing_zone.resource_groups[].name, .subscription
        landing_zone.networks[].name, .subscription, .resource_group
        landing_zone.connectivity.vpn_gateway.name, .resource_group, .network
        landing_zone.connectivity.bastion.name, .resource_group, .network
        key_vaults[].name, .subscription_id, .resource_group, .soft_delete_retention_days
        operations.monitoring.enabled, .log_analytics_workspace, .workspace_resource_group, .retention_days

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every check passed; 1 a check failed, an az call failed or a precondition failed (az missing, not signed in, wrong tenant); 2 the
    file describes nothing to check, or a value is not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-ManagementConfiguration.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Prints one row for each check and ends with exit code 0 when all of them pass.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = '(?i)NotFound|not found|could not be found|does not exist|\b404\b'
# The environment classes of scenario.environment_class in which a vault has to be removable, so purge protection is off (Deploy-KeyVaults.ps1).
$RemovableClass = @('lab', 'test', 'dev')

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# One az call. Returns the text of standard output; throws, with the error text, when az ends with an error (warnings on standard error are dropped).
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgument)
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $AzArgument
    if ($unsafe) { Exit-InputProblem $unsafe }
    $all = @(& az @AzArgument 2>&1)
    $code = $LASTEXITCODE
    $errorText = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ').Trim()
    $text = (@($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0) { throw $(if ($errorText -or $text) { (@($errorText, $text) | Where-Object { $_ }) -join ' ' } else { "az ended with exit code $code." }) }
    $text
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

function Get-List([string]$Path) {
    $raw = Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path
    @(@($raw) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($raw)) { Exit-InputProblem "An entry of $Path is not a map (names with their settings)." } })
}

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$homeSubscription = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
$instanceGroup = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.resource_group')).Trim()
$environmentClass = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.environment_class')).Trim().ToLowerInvariant()
$subscriptionEntries = @(Get-List 'landing_zone.subscriptions')
$networkEntries = @(Get-List 'landing_zone.networks')
$groupEntries = @(Get-List 'landing_zone.resource_groups')
$vaultEntries = @(Get-List 'key_vaults')
$vpn = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.vpn_gateway'
$bastion = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.bastion'
$monitoringEnabled = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring.enabled'
$workspaceName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring.log_analytics_workspace')).Trim()
$workspaceGroup = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring.workspace_resource_group')).Trim()
$workspaceRetention = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring.retention_days')).Trim()
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = [ordered]@{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }

function Test-UsableId([string]$Id) { $Id -match $Guid -and $Id -ne [guid]::Empty.ToString() }
function Get-SubscriptionIdByName([string]$Name, [string]$At) {
    if (-not $Name) {
        if (-not (Test-UsableId $homeSubscription)) { Exit-InputProblem "$At names no subscription, and azure.subscription_id is missing, not a GUID or the all-zero placeholder." }
        return $homeSubscription
    }
    $entry = @($subscriptionEntries | Where-Object { (Get-Entry $_ 'name') -eq $Name }) | Select-Object -First 1
    if (-not $entry) { Exit-InputProblem "$At.subscription '$Name' is not a name in landing_zone.subscriptions." }
    $id = Get-Entry $entry 'id'
    if (-not (Test-UsableId $id)) { Exit-InputProblem "$At.subscription '$Name' has no usable id in landing_zone.subscriptions." }
    $id
}
function Get-NetworkPlace([string]$NetworkName, [string]$At) {
    if (-not $NetworkName) { Exit-InputProblem "$At.network is missing. Name the virtual network (an entry of landing_zone.networks)." }
    $network = @($networkEntries | Where-Object { (Get-Entry $_ 'name') -eq $NetworkName }) | Select-Object -First 1
    if (-not $network) { Exit-InputProblem "$At.network '$NetworkName' is not an entry of landing_zone.networks." }
    $group = Get-Entry $network 'resource_group'
    if (-not $group) { Exit-InputProblem "The network '$NetworkName' has no resource_group in landing_zone.networks." }
    if (-not (Get-Entry $network 'subscription')) { Exit-InputProblem "The network '$NetworkName' has no subscription in landing_zone.networks." }
    [pscustomobject]@{ SubscriptionId = (Get-SubscriptionIdByName (Get-Entry $network 'subscription') "landing_zone.networks '$NetworkName'"); ResourceGroup = $group }
}

$vaults = [System.Collections.Generic.List[object]]::new()
foreach ($vault in $vaultEntries) {
    $name = Get-Entry $vault 'name'
    if (-not $name) { Exit-InputProblem 'An entry of key_vaults has no name.' }
    $id = if (Get-Entry $vault 'subscription_id') { Get-Entry $vault 'subscription_id' } else { $homeSubscription }
    if (-not (Test-UsableId $id)) { Exit-InputProblem "key_vaults '$name' has no usable subscription_id, and azure.subscription_id is missing, not a GUID or the all-zero placeholder." }
    $vaults.Add([pscustomobject]@{ Name = $name; SubscriptionId = $id; ResourceGroup = (Get-Entry $vault 'resource_group'); Retention = (Get-Entry $vault 'soft_delete_retention_days') })
}

$workspace = $null
if ($monitoringEnabled -ne $false -and $workspaceName) {
    if (-not $workspaceGroup) { Exit-InputProblem 'operations.monitoring.log_analytics_workspace is set, but operations.monitoring.workspace_resource_group is missing.' }
    $workspace = [pscustomobject]@{ Name = $workspaceName; ResourceGroup = $workspaceGroup; SubscriptionId = (Get-SubscriptionIdByName '' 'operations.monitoring'); Retention = $workspaceRetention }
}

# The resources whose diagnostic settings are checked: the VPN gateway and the Bastion host. Key Vaults are added from $vaults.
$diagnosticTargets = [System.Collections.Generic.List[object]]::new()
if ($vpn -is [System.Collections.IDictionary] -and (Get-Entry $vpn 'name')) {
    $place = Get-NetworkPlace -NetworkName (Get-Entry $vpn 'network') -At 'landing_zone.connectivity.vpn_gateway'
    $group = if (Get-Entry $vpn 'resource_group') { Get-Entry $vpn 'resource_group' } else { $place.ResourceGroup }
    $diagnosticTargets.Add([pscustomobject]@{ Label = 'VPN gateway'; Name = (Get-Entry $vpn 'name'); Show = @('network', 'vnet-gateway', 'show', '--resource-group', $group, '--name', (Get-Entry $vpn 'name'), '--subscription', $place.SubscriptionId) })
}
if ($bastion -is [System.Collections.IDictionary] -and (Get-Entry $bastion 'name')) {
    $place = Get-NetworkPlace -NetworkName (Get-Entry $bastion 'network') -At 'landing_zone.connectivity.bastion'
    $group = if (Get-Entry $bastion 'resource_group') { Get-Entry $bastion 'resource_group' } else { $place.ResourceGroup }
    $diagnosticTargets.Add([pscustomobject]@{ Label = 'Azure Bastion'; Name = (Get-Entry $bastion 'name'); Show = @('network', 'bastion', 'show', '--resource-group', $group, '--name', (Get-Entry $bastion 'name'), '--subscription', $place.SubscriptionId) })
}
foreach ($vault in $vaults) {
    $show = @('keyvault', 'show', '--name', $vault.Name, '--subscription', $vault.SubscriptionId)
    if ($vault.ResourceGroup) { $show += @('--resource-group', $vault.ResourceGroup) }
    $diagnosticTargets.Add([pscustomobject]@{ Label = 'Key Vault'; Name = $vault.Name; Show = $show })
}

# The resource groups whose resources must carry the tags of the file.
$tagGroups = [System.Collections.Generic.List[object]]::new()
if ($tags.Count -gt 0) {
    if ($groupEntries.Count -gt 0) {
        $index = -1
        foreach ($entry in $groupEntries) {
            $index++
            $name = Get-Entry $entry 'name'
            if (-not $name) { Exit-InputProblem "landing_zone.resource_groups[$index] has no name." }
            $tagGroups.Add([pscustomobject]@{ Name = $name; SubscriptionId = (Get-SubscriptionIdByName (Get-Entry $entry 'subscription') "landing_zone.resource_groups[$index]") })
        }
    }
    elseif ($instanceGroup) { $tagGroups.Add([pscustomobject]@{ Name = $instanceGroup; SubscriptionId = (Get-SubscriptionIdByName '' 'azure.resource_group') }) }
}

if ($vaults.Count -eq 0 -and -not $workspace -and $diagnosticTargets.Count -eq 0 -and $tagGroups.Count -eq 0) {
    Exit-InputProblem 'The file describes nothing to check: list key_vaults, operations.monitoring.log_analytics_workspace, landing_zone.connectivity or tags with a resource group.'
}

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A name that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{
        'key_vaults name' = @($vaults | ForEach-Object { $_.Name }); 'key_vaults resource_group' = @($vaults | ForEach-Object { $_.ResourceGroup })
        'operations.monitoring.log_analytics_workspace' = $(if ($workspace) { $workspace.Name } else { '' }); 'operations.monitoring.workspace_resource_group' = $(if ($workspace) { $workspace.ResourceGroup } else { '' })
        'the resource groups checked for tags' = @($tagGroups | ForEach-Object { $_.Name })
    })
if ($problem) { Exit-InputProblem $problem }
foreach ($target in $diagnosticTargets) {
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "the arguments that read the $($target.Label) '$($target.Name)'" = $target.Show })
    if ($problem) { Exit-InputProblem $problem }
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Invoke-ValidateConfiguration-Orchestrated.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param([string]$Check, [string]$Target, [bool]$Pass, [string]$Detail = '')
    $rows.Add([pscustomobject][ordered]@{ Check = $Check; Target = $Target; Status = $(if ($Pass) { 'Pass' } else { 'Fail' }); Detail = $Detail })
    Write-Line ('[{0}] {1}: {2}{3}' -f $(if ($Pass) { 'pass' } else { 'FAIL' }), $Check, $Target, $(if ($Detail) { " ($Detail)" } else { '' }))
}
# Reads one resource as JSON; $null when it does not exist.
function Get-Resource([string[]]$AzArgument) {
    try { return (Invoke-Az -AzArgument $AzArgument | ConvertFrom-Json) }
    catch { if ($_.Exception.Message -match $NotFound) { return $null }; throw }
}

Write-Line "Validating the configuration: $($vaults.Count) Key Vault(s), $(if ($workspace) { '1 workspace' } else { 'no workspace' }), $($diagnosticTargets.Count) resource(s) for diagnostic settings, $($tagGroups.Count) resource group(s) for tags"

# ---- Key Vault access and settings
foreach ($vault in $vaults) {
    try {
        $show = @('keyvault', 'show', '--name', $vault.Name, '--subscription', $vault.SubscriptionId)
        if ($vault.ResourceGroup) { $show += @('--resource-group', $vault.ResourceGroup) }
        $resource = Get-Resource ($show + @('--query', '{state:properties.provisioningState,softDelete:properties.enableSoftDelete,retention:properties.softDeleteRetentionInDays,purge:properties.enablePurgeProtection,network:properties.publicNetworkAccess}', '--output', 'json'))
        if (-not $resource) { Add-Check -Check 'Key Vault' -Target $vault.Name -Pass $false -Detail 'not found'; continue }
        $problems = [System.Collections.Generic.List[string]]::new()
        if ([string]$resource.state -ne 'Succeeded') { $problems.Add("provisioning state is $($resource.state), not Succeeded") }
        if ($null -ne $resource.softDelete -and -not $resource.softDelete) { $problems.Add('soft delete is off') }
        if ($vault.Retention -and [string]$resource.retention -ne $vault.Retention) { $problems.Add("the soft delete retention is $($resource.retention) days, the file says $($vault.Retention)") }
        if ($RemovableClass -notcontains $environmentClass -and -not $resource.purge) { $problems.Add('purge protection is off') }
        try { $null = Invoke-Az -AzArgument @('keyvault', 'secret', 'list', '--vault-name', $vault.Name, '--maxresults', '1', '--output', 'none') }
        catch { $problems.Add("the secret list cannot be read: $($_.Exception.Message)") }
        $detail = ($problems -join '; ')
        if ($resource.network) { $detail = (@($detail, "public network access $($resource.network)") | Where-Object { $_ }) -join '; ' }
        Add-Check -Check 'Key Vault' -Target $vault.Name -Pass ($problems.Count -eq 0) -Detail $detail
    }
    catch { Add-Check -Check 'Key Vault' -Target $vault.Name -Pass $false -Detail $_.Exception.Message }
}

# ---- Log Analytics workspace
$workspaceId = ''
if ($workspace) {
    try {
        $resource = Get-Resource @('monitor', 'log-analytics', 'workspace', 'show', '--resource-group', $workspace.ResourceGroup, '--workspace-name', $workspace.Name, '--subscription', $workspace.SubscriptionId, '--query', '{id:id,state:provisioningState,retention:retentionInDays}', '--output', 'json')
        if (-not $resource) { Add-Check -Check 'Log Analytics workspace' -Target $workspace.Name -Pass $false -Detail 'not found' }
        else {
            $workspaceId = [string]$resource.id
            $problems = [System.Collections.Generic.List[string]]::new()
            if ([string]$resource.state -ne 'Succeeded') { $problems.Add("provisioning state is $($resource.state), not Succeeded") }
            if ($workspace.Retention -and [string]$resource.retention -ne $workspace.Retention) { $problems.Add("the retention is $($resource.retention) days, the file says $($workspace.Retention)") }
            Add-Check -Check 'Log Analytics workspace' -Target $workspace.Name -Pass ($problems.Count -eq 0) -Detail ($problems -join '; ')
        }
    }
    catch { Add-Check -Check 'Log Analytics workspace' -Target $workspace.Name -Pass $false -Detail $_.Exception.Message }
}

# ---- diagnostic settings
foreach ($target in $diagnosticTargets) {
    $check = "$($target.Label) diagnostic settings"
    try {
        $resourceId = Invoke-Az -AzArgument ($target.Show + @('--query', 'id', '--output', 'tsv'))
        $json = Invoke-Az -AzArgument @('monitor', 'diagnostic-settings', 'list', '--resource', $resourceId, '--output', 'json') | ConvertFrom-Json
        $settings = @(@(if ($json -and $json.PSObject.Properties['value']) { $json.value } else { $json }) | Where-Object { $_ })
        $good = @($settings | Where-Object {
                $_.PSObject.Properties['workspaceId'] -and $_.workspaceId -and
                (-not $workspaceId -or [string]$_.workspaceId -ieq $workspaceId) -and
                @(@($_.logs) | Where-Object { $_ -and $_.enabled }).Count -gt 0 })
        if ($good.Count -gt 0) { Add-Check -Check $check -Target $target.Name -Pass $true -Detail "sent to the workspace by: $(($good | ForEach-Object { $_.name }) -join ', ')" }
        elseif ($settings.Count -eq 0) { Add-Check -Check $check -Target $target.Name -Pass $false -Detail 'no diagnostic setting' }
        else { Add-Check -Check $check -Target $target.Name -Pass $false -Detail "no setting sends enabled logs to $(if ($workspaceId) { 'the workspace of the file' } else { 'a Log Analytics workspace' })" }
    }
    catch { Add-Check -Check $check -Target $target.Name -Pass $false -Detail $_.Exception.Message }
}

# ---- tags
foreach ($group in $tagGroups) {
    try {
        $listText = $null
        try { $listText = Invoke-Az -AzArgument @('resource', 'list', '--resource-group', $group.Name, '--subscription', $group.SubscriptionId, '--query', '[].{name:name,tags:tags}', '--output', 'json') }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
        if ($null -eq $listText) { Add-Check -Check 'Tags' -Target $group.Name -Pass $false -Detail 'the resource group was not found'; continue }
        $resources = @($listText | ConvertFrom-Json)
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($resource in $resources) {
            $actual = $resource.tags
            $lacks = @($tags.Keys | Where-Object { -not ($actual -and $actual.PSObject.Properties[$_] -and [string]$actual.PSObject.Properties[$_].Value -ceq $tags[$_]) })
            if ($lacks.Count -gt 0) { $missing.Add("$($resource.name) ($($lacks -join ', '))") }
        }
        $detail = if ($missing.Count -gt 0) { "$($missing.Count) of $($resources.Count) resource(s) lack a tag of the file: $((@($missing) | Select-Object -First 10) -join '; ')" } else { "$($resources.Count) resource(s) checked" }
        Add-Check -Check 'Tags' -Target $group.Name -Pass ($missing.Count -eq 0) -Detail $detail
    }
    catch { Add-Check -Check 'Tags' -Target $group.Name -Pass $false -Detail $_.Exception.Message }
}

$failed = @($rows | Where-Object Status -EQ 'Fail')
Write-Line "Summary: $($rows.Count - $failed.Count) of $($rows.Count) checks passed, $($failed.Count) failed."
$rows
if ($failed.Count -gt 0) { exit 1 }
exit 0
