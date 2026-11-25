<#
.SYNOPSIS
    Checks the rules of the Azure Local network security groups, with the Azure CLI, against networking.network_security_groups of infrastructure.yml. Read only.

.DESCRIPTION
    Phase 01 (SDN), Task 03 (verify network security groups). The Verification section of the guide page lists the rules of each group
    (az stack-hci-vm network nsg rule list) and compares them with what the design says. This script does that for every entry of
    networking.network_security_groups: the group must exist, and each rule of the file must exist with the same priority, direction, access, protocol,
    addresses and ports. A rule the group has and the file does not list is reported as Extra and does not fail the check (a rule added by hand on
    purpose is not a defect; Set-NetworkSecurityGroupRule.azcli.ps1 -RemoveUnlistedRules removes it).

    This script never creates, changes or deletes anything. The association of a group with a logical network or a VM network interface is shown in the
    Azure portal (Azure Arc, Azure Local, Logical networks, and the Networking page of the machine); this script does not read it. There is no PowerShell
    script for this task: the Azure CLI with the stack-hci-vm extension is the only supported way to read these groups.

    The script does not sign in: run az login to the tenant in azure.tenant_id first. It does not change the Azure CLI default subscription. The
    extension stack-hci-vm must be installed (az extension add --name stack-hci-vm); this script does not install it.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, sdn.enabled
        networking.network_security_groups[]: name
            rules[]: name, priority, direction, access, protocol, source_address_prefixes, destination_address_prefixes,
                     source_port_ranges, destination_port_ranges, description
        networking.management.subnet, networking.vlans[] (name, subnet, purpose), networking.logical_networks[] (name, address_prefix)
            only when a rule names a network instead of an address. source_address_prefixes and destination_address_prefixes take *, an IPv4 address or
            range, or a reference that is replaced by the subnet the file already holds: management (networking.management.subnet); oob, automation,
            compute or storage (every networking.vlans[] entry with that purpose); vlan:<name> (that VLAN's subnet); logical-network:<name> (that logical
            network's address_prefix). The run prints each reference with the address and the variable it came from.

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every group and rule of the file is there and as the file says (or the file lists no group); 1 a precondition failed (az missing, not
    signed in, wrong tenant, extension missing) or a group or rule is missing or differs; 2 a value in the file is missing or not usable, or SDN is off.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Test-NetworkSecurityGroupRule.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Compares every listed group and rule with Azure and ends with exit code 1 when one is missing or differs.
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

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common'))
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'sdn', 'AzlSdn.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'azure-cli', 'AzlAzureCliArgument.psm1')) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# Microsoft Learn, naming rules for Microsoft.Network: 1 to 80 characters; letters, digits, underscore, period and hyphen; start with a letter or digit; end with a letter, digit or underscore.
$ResourceName = '^[A-Za-z0-9]([A-Za-z0-9._-]{0,78}[A-Za-z0-9_])?$'
$Octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
$Ipv4 = "^($Octet\.){3}$Octet$"
$Cidr = "^($Octet\.){3}$Octet/([0-9]|[12][0-9]|3[0-2])$"
# The protocol names of az stack-hci-vm network nsg rule create --protocol.
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
function ConvertFrom-AzJson([string]$Text) { if ($Text -and $Text.Trim()) { $Text | ConvertFrom-Json -Depth 20 } }
function ConvertTo-StringList($Value, [string[]]$Default) {
    if ($null -eq $Value -or "$Value" -eq '') { return , @($Default) }
    , @(@($Value) | ForEach-Object { ([string]$_).Trim() })
}
function Test-AddressPrefix([string]$Value) { $Value -eq '*' -or $Value -match $Ipv4 -or $Value -match $Cidr }
# A source or destination may name a network the file already holds (management, storage, vlan:<name>, ...): it is replaced by that subnet, and the
# line says which variable it came from. Literal addresses stay as written. See Resolve-AzlNsgAddressPrefix in scripts/common/sdn/AzlSdn.psm1.
function Resolve-NetworkReference([string]$At, [string[]]$List) {
    $resolved = Resolve-AzlNsgAddressPrefix -Infrastructure $infra -Value $List
    if ($resolved.Problem) { Exit-InputProblem "${At}: $($resolved.Problem)" }
    foreach ($note in $resolved.Notes) { Write-Line "$At`: $note" }
    , @($resolved.Addresses)
}
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
# A value of a rule as the Azure CLI returns it: under properties, or at the top.
function Get-RuleValue($Rule, [string]$Key) {
    $value = Get-Prop $Rule @('properties', $Key)
    if ($null -eq $value) { $value = Get-Prop $Rule @($Key) }
    $value
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
    Exit-InputProblem 'The file lists network security groups, but sdn.enabled is not true. Network security groups on Azure Local need SDN enabled by Azure Arc (Microsoft Learn, Enable SDN integration).'
}

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The network security groups are in it.' }

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
    if ($ruleList.Count -eq 0) { Exit-InputProblem "$at ('$name') has no rules. Microsoft Learn: an empty network security group denies all inbound traffic. List at least one rule, or take the group out of the file." }

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
        $sourceAddress = Resolve-NetworkReference "$ruleAt.source_address_prefixes" $sourceAddress
        $destinationAddress = Resolve-NetworkReference "$ruleAt.destination_address_prefixes" $destinationAddress
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
        $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "$ruleAt.description" = $description }); if ($problem) { Exit-InputProblem $problem }
        $rules.Add([pscustomobject]@{
                Name = $ruleName; Priority = $priority; Direction = $directionName; Access = $accessName; Protocol = $ProtocolName[$protocol]
                SourceAddress = $sourceAddress; DestinationAddress = $destinationAddress; SourcePort = $sourcePort; DestinationPort = $destinationPort; Description = $description
            })
    }
    $plans.Add([pscustomobject]@{ Name = $name; Rules = $rules })
}

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A value that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }
try { $null = Invoke-Az extension show --name stack-hci-vm --output none }
catch { Exit-Failed 'The Azure CLI extension stack-hci-vm is not installed. This script does not install it. Run: az extension add --name stack-hci-vm' }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'InSync' { '[ok]      ' } 'Extra' { '[note]    ' } default { '[failed]  ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Item, $(if ($Detail) { " ($Detail)" } else { '' }))
}
$scopeArgs = @('--subscription', $subscriptionId, '--resource-group', $group)
function Get-Difference($Have, $Rule) {
    $differences = [System.Collections.Generic.List[string]]::new()
    if ([string](Get-RuleValue $Have 'priority') -ne [string]$Rule.Priority) { $differences.Add("priority is $(Get-RuleValue $Have 'priority')") }
    if ([string](Get-RuleValue $Have 'direction') -ne $Rule.Direction) { $differences.Add("direction is $(Get-RuleValue $Have 'direction')") }
    if ([string](Get-RuleValue $Have 'access') -ne $Rule.Access) { $differences.Add("access is $(Get-RuleValue $Have 'access')") }
    if (([string](Get-RuleValue $Have 'protocol')).ToLowerInvariant() -ne $Rule.Protocol.ToLowerInvariant()) { $differences.Add("protocol is $(Get-RuleValue $Have 'protocol')") }
    foreach ($pair in @(
            @{ Key = 'sourceAddressPrefixes'; Want = $Rule.SourceAddress }, @{ Key = 'destinationAddressPrefixes'; Want = $Rule.DestinationAddress }
            @{ Key = 'sourcePortRanges'; Want = $Rule.SourcePort }, @{ Key = 'destinationPortRanges'; Want = $Rule.DestinationPort })) {
        if (-not (Test-SameSet (Get-RuleValue $Have $pair.Key) $pair.Want)) { $differences.Add("$($pair.Key) differ") }
    }
    , $differences
}

Write-Line "Network security groups in '$group'"
foreach ($plan in $plans) {
    $existingRules = @()
    try {
        $null = Invoke-Az stack-hci-vm network nsg show @scopeArgs --name $plan.Name --output none
        $existingRules = @(@(ConvertFrom-AzJson (Invoke-Az stack-hci-vm network nsg rule list @scopeArgs --nsg-name $plan.Name --output json)) | Where-Object { $null -ne $_ })
    }
    catch {
        $message = if ($_.Exception.Message -match $NotFound) { 'The group does not exist. Create it with New-NetworkSecurityGroup.ps1 (post-deployment, task 07).' } else { "The group could not be read: $($_.Exception.Message)" }
        Add-Row "network security group $($plan.Name)" 'GroupMissing' $message
        continue
    }
    Add-Row "network security group $($plan.Name)" 'InSync' "$($existingRules.Count) rule(s)"
    $listed = @{}
    foreach ($rule in $plan.Rules) {
        $item = "rule $($plan.Name)/$($rule.Name)"
        $listed[$rule.Name.ToLowerInvariant()] = $true
        $have = @($existingRules | Where-Object { ([string](Get-Prop $_ @('name'))).Split('/')[-1] -ieq $rule.Name }) | Select-Object -First 1
        if (-not $have) { Add-Row $item 'Missing' "$($rule.Direction) $($rule.Access), priority $($rule.Priority)"; continue }
        $differences = Get-Difference $have $rule
        if ($differences.Count -eq 0) { Add-Row $item 'InSync' } else { Add-Row $item 'Differs' ($differences -join '; ') }
    }
    foreach ($have in $existingRules) {
        $haveName = ([string](Get-Prop $have @('name'))).Split('/')[-1]
        if (-not $listed.ContainsKey($haveName.ToLowerInvariant())) { Add-Row "rule $($plan.Name)/$haveName" 'Extra' 'the group has it, the file does not list it' }
    }
}

$bad = @($rows | Where-Object { $_.Action -in 'GroupMissing', 'Missing', 'Differs' }).Count
Write-Line "Summary: $bad group(s) or rule(s) missing or different."
$rows
if ($bad -gt 0) { exit 1 }
exit 0
