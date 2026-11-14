<#
.SYNOPSIS
    Creates the Azure Local network security groups, and their rules, that networking.network_security_groups of infrastructure.yml lists.

.DESCRIPTION
    Phase 06 (post-deployment), Task 07 (configure NSGs). A network security group (NSG) controls the traffic of Azure Local virtual machines and
    logical networks with rules on direction, address, port and protocol (Microsoft Learn, Create network security groups on Azure Local). For every
    entry of networking.network_security_groups the script creates the group in azure.resource_group, on the custom location of the instance
    (azure.custom_location), in azure.location, with the file-level tags, and then creates the rules of the entry that the group does not have.

    Prerequisites, from Microsoft Learn:
      * SDN enabled by Azure Arc. The script does not turn SDN on. When the file lists a group and sdn.enabled is not true, the script stops with
        exit code 2 and creates nothing.
      * A group needs at least one rule: an empty group denies all inbound traffic, and a machine or logical network that uses it cannot be reached.
        The script refuses (exit code 2) a group without rules.
      * The Azure CLI with the stack-hci-vm extension. Microsoft documents these groups for the Azure CLI only; there is no Az PowerShell cmdlet.
        The script does not install the extension: install it yourself (az extension add --name stack-hci-vm).

    Order of the tasks: run this script before New-LogicalNetwork.ps1 (task 08). A logical network is tied to its group when the logical network
    is created (networking.logical_networks[].nsg_name), so the group must exist first.

    Idempotent. A group that exists is reported as AlreadyExists and left alone; a rule that exists (same name) is left alone and, when it differs
    from the file, reported (change it with az stack-hci-vm network nsg rule update). Nothing is deleted. -WhatIf reads Azure and changes nothing.
    If creating a rule fails after the group was created, the group has no rule yet: the script says so, and a second run creates the missing rules.
    Do not tie the group to a logical network or a machine before every rule is there.

    The script does not sign in: run az login to the tenant in azure.tenant_id first (az login --tenant <id>). It does not change the Azure CLI
    default subscription: every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location, azure.custom_location, tags, sdn.enabled
        networking.network_security_groups[]: name
            rules[]: name, priority, direction, access, protocol, source_address_prefixes, destination_address_prefixes,
                     source_port_ranges, destination_port_ranges, description

    Exit codes: 0 every group and rule exists (created now, already there, planned under -WhatIf) or the file lists no group; 1 a call or a precondition
    failed (az missing, not signed in, wrong tenant, extension missing, a creation failed); 2 a value in the file is missing or not usable, or SDN is
    off. On exit code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-NetworkSecurityGroup.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which groups and rules would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-NetworkSecurityGroup.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the groups and rules. Run it again: they are reported as AlreadyExists.
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
# Microsoft Learn, naming rules for Microsoft.Network: 1 to 80 characters; letters, digits, underscore, period and hyphen; start with a letter or digit; end with a letter, digit or underscore.
$ResourceName = '^[A-Za-z0-9]([A-Za-z0-9._-]{0,78}[A-Za-z0-9_])?$'
$Octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
$Ipv4 = "^($Octet\.){3}$Octet$"
$Cidr = "^($Octet\.){3}$Octet/([0-9]|[12][0-9]|3[0-2])$"
# The Azure CLI is started through a command file on Windows. These characters would be read as commands there, so no value that holds one is sent.
$UnsafeArgument = '[&|<>^%"`\r\n]'
$ProtocolName = @{ '*' = '*'; tcp = 'Tcp'; udp = 'Udp'; icmp = 'Icmp' }

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Field($Map, [string]$Key, $Default = $null) {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key] -and "$($Map[$Key])" -ne '') { return $Map[$Key] }
    $Default
}
function Get-Prop($Object, [string[]]$Path) {
    $node = $Object
    foreach ($part in $Path) {
        if ($null -eq $node) { return $null }
        if ($node -is [System.Collections.IDictionary]) { if ($node.Contains($part)) { $node = $node[$part] } else { return $null } }
        elseif ($node.PSObject.Properties[$part]) { $node = $node.PSObject.Properties[$part].Value }
        else { return $null }
    }
    $node
}

# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the exit code, stdout and stderr.
function Invoke-AzCli([string[]]$Arguments) {
    foreach ($argument in $Arguments) {
        if ($argument -match $UnsafeArgument) { throw "An argument holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote): $argument" }
    }
    $all = @(& az @Arguments 2>&1)
    $code = [int](Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err; Detail = $(if ($err) { $err.Trim() } else { $out.Trim() }) }
}
function ConvertFrom-AzJson([string]$Text) { if ($Text -and $Text.Trim()) { $Text | ConvertFrom-Json -Depth 20 } }

function ConvertTo-StringList($Value, [string[]]$Default) {
    if ($null -eq $Value -or "$Value" -eq '') { return , @($Default) }
    , @(@($Value) | ForEach-Object { ([string]$_).Trim() })
}
function Test-AddressPrefix([string]$Value) { $Value -eq '*' -or $Value -match $Ipv4 -or $Value -match $Cidr }
function Test-PortRange([string]$Value) {
    if ($Value -eq '*') { return $true }
    if ($Value -notmatch '^(?<a>[0-9]{1,5})(-(?<b>[0-9]{1,5}))?$') { return $false }
    $low = [int]$Matches['a']
    $high = if ($Matches['b']) { [int]$Matches['b'] } else { $low }
    $low -le 65535 -and $high -le 65535 -and $low -le $high
}
function Test-SameSet($Left, $Right) {
    $a = @(@($Left) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
    $b = @(@($Right) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
    ($a -join ',') -eq ($b -join ',')
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$networking = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking'
$groupList = @(@(Get-Field $networking 'network_security_groups' @()) | Where-Object { $null -ne $_ })
if ($groupList.Count -eq 0) {
    Write-Line 'The file lists no networking.network_security_groups: nothing to do.'
    exit 0
}

$sdnEnabled = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'sdn.enabled'
if ($sdnEnabled -isnot [bool] -or -not $sdnEnabled) {
    Exit-InputProblem 'The file lists network security groups, but sdn.enabled is not true. Network security groups on Azure Local need SDN enabled by Azure Arc (Microsoft Learn, Enable SDN integration). This script does not turn SDN on: enable it first and set sdn.enabled to true, or take the groups out of the file.'
}

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$location = Get-Text 'azure.location'
$customLocation = Get-Text 'azure.custom_location'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tagArguments = @()
if ($rawTags -is [System.Collections.IDictionary]) {
    foreach ($k in $rawTags.Keys) {
        if ($null -eq $rawTags[$k]) { continue }
        $pair = "$k=$($rawTags[$k])"
        if ($pair -match $UnsafeArgument) { Exit-InputProblem "The tag '$k' holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote)." }
        $tagArguments += $pair
    }
}

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The network security groups are created there.' }
if (-not $location) { Exit-InputProblem 'azure.location is missing.' }
if (-not $customLocation) { Exit-InputProblem 'azure.custom_location is missing. It is the custom location of the Azure Local instance.' }
$customLocationId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ExtendedLocation/customLocations/$customLocation"

$plans = [System.Collections.Generic.List[object]]::new()
$seenGroup = @{}
$groupIndex = -1
foreach ($entry in $groupList) {
    $groupIndex++
    $at = "networking.network_security_groups[$groupIndex]"
    if ($entry -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a network security group (a map with name and rules)." }
    $name = ([string](Get-Field $entry 'name' '')).Trim()
    if ($name -notmatch $ResourceName) { Exit-InputProblem "$at.name '$name' is not a valid name: 1 to 80 letters, digits, underscore, period or hyphen, starting with a letter or digit and ending with a letter, digit or underscore." }
    if ($seenGroup.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seenGroup[$name.ToLowerInvariant()] = $true

    $ruleList = @(@(Get-Field $entry 'rules' @()) | Where-Object { $null -ne $_ })
    if ($ruleList.Count -eq 0) {
        Exit-InputProblem "$at ('$name') has no rules. Microsoft Learn: a network security group must have at least one rule, because an empty group denies all inbound traffic and a machine or logical network that uses it cannot be reached. Add a rule, or take the group out of the file."
    }

    $rules = [System.Collections.Generic.List[object]]::new()
    $seenRule = @{}
    $seenPriority = @{}
    $ruleIndex = -1
    foreach ($rule in $ruleList) {
        $ruleIndex++
        $ruleAt = "$at.rules[$ruleIndex]"
        if ($rule -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$ruleAt is not a rule (a map)." }
        $ruleName = ([string](Get-Field $rule 'name' '')).Trim()
        if ($ruleName -notmatch $ResourceName) { Exit-InputProblem "$ruleAt.name '$ruleName' is not a valid name: 1 to 80 letters, digits, underscore, period or hyphen, starting with a letter or digit and ending with a letter, digit or underscore." }
        if ($seenRule.ContainsKey($ruleName.ToLowerInvariant())) { Exit-InputProblem "$ruleAt.name '$ruleName' is listed twice in '$name'." }
        $seenRule[$ruleName.ToLowerInvariant()] = $true

        $priority = 0
        if (-not [int]::TryParse("$(Get-Field $rule 'priority' '')", [ref]$priority) -or $priority -lt 100 -or $priority -gt 4096) { Exit-InputProblem "$ruleAt.priority must be a whole number from 100 to 4096; found '$(Get-Field $rule 'priority' '')'." }
        if ($seenPriority.ContainsKey($priority)) { Exit-InputProblem "$ruleAt.priority $priority is used by two rules of '$name'. The priority must be unique in the group." }
        $seenPriority[$priority] = $true

        $direction = ([string](Get-Field $rule 'direction' '')).Trim()
        $directionName = switch ($direction.ToLowerInvariant()) { 'inbound' { 'Inbound' } 'outbound' { 'Outbound' } default { '' } }
        if (-not $directionName) { Exit-InputProblem "$ruleAt.direction must be Inbound or Outbound; found '$direction'." }
        $access = ([string](Get-Field $rule 'access' '')).Trim()
        $accessName = switch ($access.ToLowerInvariant()) { 'allow' { 'Allow' } 'deny' { 'Deny' } default { '' } }
        if (-not $accessName) { Exit-InputProblem "$ruleAt.access must be Allow or Deny; found '$access'." }
        $protocol = ([string](Get-Field $rule 'protocol' '*')).Trim().ToLowerInvariant()
        if (-not $ProtocolName.ContainsKey($protocol)) { Exit-InputProblem "$ruleAt.protocol must be *, Tcp, Udp or Icmp; found '$protocol'." }

        $sourceAddress = ConvertTo-StringList (Get-Field $rule 'source_address_prefixes') @('*')
        $destinationAddress = ConvertTo-StringList (Get-Field $rule 'destination_address_prefixes') @('*')
        $sourcePort = ConvertTo-StringList (Get-Field $rule 'source_port_ranges') @('*')
        if ($null -eq (Get-Field $rule 'destination_port_ranges')) { Exit-InputProblem "$ruleAt.destination_port_ranges is missing. List the ports the rule matches, or * for any port." }
        $destinationPort = ConvertTo-StringList (Get-Field $rule 'destination_port_ranges') @()
        foreach ($item in @(@{ Key = 'source_address_prefixes'; List = $sourceAddress }, @{ Key = 'destination_address_prefixes'; List = $destinationAddress })) {
            foreach ($value in $item.List) { if (-not (Test-AddressPrefix $value)) { Exit-InputProblem "$ruleAt.$($item.Key) holds '$value'. Use *, an IPv4 address or an IPv4 range in CIDR form." } }
        }
        foreach ($item in @(@{ Key = 'source_port_ranges'; List = $sourcePort }, @{ Key = 'destination_port_ranges'; List = $destinationPort })) {
            foreach ($value in $item.List) { if (-not (Test-PortRange $value)) { Exit-InputProblem "$ruleAt.$($item.Key) holds '$value'. Use *, a port from 0 to 65535 or a range such as 8000-8100." } }
        }

        $description = ([string](Get-Field $rule 'description' '')).Trim()
        if ($description.Length -gt 140) { Exit-InputProblem "$ruleAt.description has $($description.Length) characters; Microsoft Learn allows at most 140." }
        if ($description -match $UnsafeArgument) { Exit-InputProblem "$ruleAt.description holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote). Rewrite it without." }

        $rules.Add([pscustomobject]@{
                Name = $ruleName; Priority = $priority; Direction = $directionName; Access = $accessName; Protocol = $ProtocolName[$protocol]
                SourceAddress = $sourceAddress; DestinationAddress = $destinationAddress; SourcePort = $sourcePort; DestinationPort = $destinationPort; Description = $description
            })
    }
    $plans.Add([pscustomobject]@{ Name = $name; Rules = $rules })
}

# ---- preconditions (read only)
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>.' }
$account = Invoke-AzCli @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors')
if ($account.ExitCode -ne 0) { Exit-Failed "Not signed in to the Azure CLI for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($account.Detail)" }
$accountInfo = ConvertFrom-AzJson $account.Output
if ([string](Get-Prop $accountInfo @('tenantId')) -ne $tenantId) { Exit-Failed "The Azure CLI is signed in to tenant $(Get-Prop $accountInfo @('tenantId')), but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }
$extension = Invoke-AzCli @('extension', 'show', '--name', 'stack-hci-vm', '--output', 'json', '--only-show-errors')
if ($extension.ExitCode -ne 0) { Exit-Failed 'The Azure CLI extension stack-hci-vm is not installed. This script does not install it. Run: az extension add --name stack-hci-vm' }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } 'AlreadyExists' { '[exists]  ' } 'Skipped' { '[skipped] ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[created] ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Item, $(if ($Detail) { " ($Detail)" } else { '' }))
}
$common = @('--subscription', $subscriptionId, '--resource-group', $group)

Write-Line "Network security groups in '$group' ($location), custom location '$customLocation'"
foreach ($plan in $plans) {
    $item = "network security group $($plan.Name)"
    $groupReady = $false
    $existingRules = @()
    try {
        $show = Invoke-AzCli (@('stack-hci-vm', 'network', 'nsg', 'show') + $common + @('--name', $plan.Name, '--output', 'json', '--only-show-errors'))
        if ($show.ExitCode -eq 0) { $groupReady = $true }
        elseif ($show.Detail -notmatch $NotFound) { throw "The lookup failed: $($show.Detail)" }

        if ($groupReady) {
            $list = Invoke-AzCli (@('stack-hci-vm', 'network', 'nsg', 'rule', 'list') + $common + @('--nsg-name', $plan.Name, '--output', 'json', '--only-show-errors'))
            if ($list.ExitCode -ne 0) { throw "The rules could not be listed: $($list.Detail)" }
            $existingRules = @(@(ConvertFrom-AzJson $list.Output) | Where-Object { $null -ne $_ })
            Add-Row $item 'AlreadyExists' $(if ($existingRules.Count -eq 0) { 'it has no rules yet; the rules of the file are created below' } else { "$($existingRules.Count) rule(s)" })
        }
        elseif ($PSCmdlet.ShouldProcess("network security group '$($plan.Name)' in '$group'", "Create ($($plan.Rules.Count) rule(s) follow)")) {
            $arguments = @('stack-hci-vm', 'network', 'nsg', 'create') + $common + @('--name', $plan.Name, '--custom-location', $customLocationId, '--location', $location)
            if ($tagArguments.Count) { $arguments += @('--tags') + $tagArguments }
            $result = Invoke-AzCli ($arguments + @('--output', 'none', '--only-show-errors'))
            if ($result.ExitCode -ne 0) { throw "The creation failed: $($result.Detail)" }
            $groupReady = $true
            Add-Row $item 'Created' 'empty until its rules are created; do not use it before'
        }
        else { Add-Row $item 'WouldCreate' "$($plan.Rules.Count) rule(s) follow" }
    }
    catch {
        Add-Row $item 'Failed' $_.Exception.Message
        foreach ($rule in $plan.Rules) { Add-Row "rule $($plan.Name)/$($rule.Name)" 'Skipped' 'the group is not there' }
        continue
    }

    foreach ($rule in $plan.Rules) {
        $ruleItem = "rule $($plan.Name)/$($rule.Name)"
        try {
            $have = @($existingRules | Where-Object { ([string](Get-Prop $_ @('name'))).Split('/')[-1] -eq $rule.Name }) | Select-Object -First 1
            if ($have) {
                $differences = [System.Collections.Generic.List[string]]::new()
                if ([string](Get-Prop $have @('properties', 'priority')) -ne [string]$rule.Priority) { $differences.Add("priority is $(Get-Prop $have @('properties', 'priority'))") }
                if ([string](Get-Prop $have @('properties', 'direction')) -ne $rule.Direction) { $differences.Add("direction is $(Get-Prop $have @('properties', 'direction'))") }
                if ([string](Get-Prop $have @('properties', 'access')) -ne $rule.Access) { $differences.Add("access is $(Get-Prop $have @('properties', 'access'))") }
                if (([string](Get-Prop $have @('properties', 'protocol'))).ToLowerInvariant() -ne $rule.Protocol.ToLowerInvariant()) { $differences.Add("protocol is $(Get-Prop $have @('properties', 'protocol'))") }
                foreach ($pair in @(
                        @{ Key = 'sourceAddressPrefixes'; Want = $rule.SourceAddress }, @{ Key = 'destinationAddressPrefixes'; Want = $rule.DestinationAddress }
                        @{ Key = 'sourcePortRanges'; Want = $rule.SourcePort }, @{ Key = 'destinationPortRanges'; Want = $rule.DestinationPort })) {
                    if (-not (Test-SameSet (Get-Prop $have @('properties', $pair.Key)) $pair.Want)) { $differences.Add("$($pair.Key) differ") }
                }
                Add-Row $ruleItem 'AlreadyExists' $(if ($differences.Count) { "differs from the file ($($differences -join '; ')); left unchanged. Change it with az stack-hci-vm network nsg rule update." } else { '' })
                continue
            }
            $clash = @($existingRules | Where-Object { [string](Get-Prop $_ @('properties', 'priority')) -eq [string]$rule.Priority }) | Select-Object -First 1
            if ($clash) { throw "Priority $($rule.Priority) is already used by the rule '$(Get-Prop $clash @('name'))' of the group. Priorities must be unique." }
            if (-not $groupReady) { Add-Row $ruleItem 'WouldCreate' "$($rule.Direction) $($rule.Access) priority $($rule.Priority)"; continue }

            if ($PSCmdlet.ShouldProcess("rule '$($rule.Name)' of '$($plan.Name)'", "Create ($($rule.Direction) $($rule.Access), priority $($rule.Priority))")) {
                # The argument names are fixed by the Azure CLI reference of az stack-hci-vm network nsg rule create; nothing here is a deployment choice.
                $arguments = @('stack-hci-vm', 'network', 'nsg', 'rule', 'create') + $common + @(
                    '--nsg-name', $plan.Name, '--name', $rule.Name, '--priority', [string]$rule.Priority, '--custom-location', $customLocationId, '--location', $location
                    '--access', $rule.Access, '--direction', $rule.Direction, '--protocol', $rule.Protocol)
                $arguments += @('--source-port-ranges') + $rule.SourcePort
                $arguments += @('--source-address-prefixes') + $rule.SourceAddress
                $arguments += @('--destination-port-ranges') + $rule.DestinationPort
                $arguments += @('--destination-address-prefixes') + $rule.DestinationAddress
                if ($rule.Description) { $arguments += @('--description', $rule.Description) }
                $result = Invoke-AzCli ($arguments + @('--output', 'none', '--only-show-errors'))
                if ($result.ExitCode -ne 0) { throw "The creation failed: $($result.Detail)" }
                Add-Row $ruleItem 'Created' "$($rule.Direction) $($rule.Access), priority $($rule.Priority)"
            }
            else { Add-Row $ruleItem 'WouldCreate' "$($rule.Direction) $($rule.Access), priority $($rule.Priority)" }
        }
        catch {
            Add-Row $ruleItem 'Failed' $_.Exception.Message
            Write-Warning "The group '$($plan.Name)' may be missing rules. Run the script again to create them, and do not tie the group to a logical network or a machine before then."
        }
    }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
