<#
.SYNOPSIS
    Creates the Azure network security groups that landing_zone.network_security_groups of infrastructure.yml lists, with their rules, with the Azure CLI.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 06 (network security groups), Azure CLI variant of New-LandingZoneNsg.ps1.
    It does the same with az commands, for a host that has the Azure CLI and not the Az PowerShell modules. Run it after the resource groups exist
    (phase 01, task 03) and BEFORE Deploy-VirtualNetworks.ps1 (task 01): that script attaches a security group to a subnet by the name the subnet gives in
    landing_zone.networks[].subnets[].network_security_group, and looks the group up in the resource group of the network. If the group is not
    there yet it creates the subnet without it and says so.

    For each entry of landing_zone.network_security_groups the script finds the networks whose subnets name it and creates the group in the
    subscription, resource group and region of each of those networks (a subnet can use only a group of its own region and subscription). Each rule
    of the entry becomes a security rule (Microsoft Learn: az network nsg create, az network nsg rule create; rules and their limits:
    Azure network security groups overview). A group that no subnet names is reported as NotUsed and not created. A subnet that names a group the
    file does not list is left to whoever makes it (the script says nothing about it).

    Idempotent, and additive. A group that exists is reported as AlreadyExists; the rules it lacks are added (by name), and a rule that exists with
    the same name is left as it is and, when its priority, direction, access or protocol differs from the file, reported. The script never
    removes or changes a rule, never deletes a group and never attaches one to a subnet. -WhatIf changes nothing. A rule is a separate az call:
    when one fails, the group keeps the rules made before it, and a new run adds the rest.

    The script reads Azure (read only) and writes only with "az network nsg create" and "az network nsg rule create", behind -WhatIf. It does not
    sign in: run "az login --tenant <azure.tenant_id>" first. You need Network Contributor (or Contributor) on each resource group. Every az call
    names its subscription, so the subscription of the az session is not changed. The tags in the file-level tags map are put on the groups it
    creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags
        landing_zone.subscriptions[].name, .id                                  the subscription of each network
        landing_zone.networks[].name, .subscription, .resource_group, .location
        landing_zone.networks[].subnets[].name, .network_security_group         which networks use which group
        landing_zone.network_security_groups[].name
        landing_zone.network_security_groups[].rules[].name, .priority, .direction, .access, .protocol, .source_address_prefixes,
            .source_port_ranges, .destination_address_prefixes, .destination_port_ranges, .description

    Exit codes: 0 every group is in place (created now, already there, rules added, planned under -WhatIf) or the file lists no group; 1 an az call
    failed or a precondition failed (az missing, not signed in, wrong tenant, a creation failed); 2 a value in the file is missing or
    not usable (a name or priority Azure refuses, two rules with the same priority and direction, a service tag mixed with addresses, a network
    whose subscription has no id).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-LandingZoneNsg.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which groups and rules would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-LandingZoneNsg.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the groups. Run it again: they are reported as AlreadyExists.
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

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'ResourceNotFound|NotFound|could not be found|was not found|does not exist|\b404\b'
$NamePattern = '^[A-Za-z0-9]([A-Za-z0-9._-]{0,78}[A-Za-z0-9_])?$'
$AddressPattern = '^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)(/([0-9]|[12]\d|3[0-2]))?$'
$ServiceTagPattern = '^[A-Za-z][A-Za-z0-9.]*$'
$PortPattern = '^(\*|\d{1,5}(-\d{1,5})?)$'
$Protocols = @{ '*' = '*'; tcp = 'Tcp'; udp = 'Udp'; icmp = 'Icmp'; esp = 'Esp'; ah = 'Ah' }

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}
function ConvertTo-TextList([object]$Value) {
    @(@($Value) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
}
# The address list of a rule: * alone, addresses or ranges, or one service tag alone.
function Test-AddressList([string[]]$Values, [string]$At) {
    if ($Values.Count -eq 0) { return }
    $isAddress = { param($v) $v -match $AddressPattern }
    $tags = @($Values | Where-Object { $_ -ne '*' -and -not (& $isAddress $_) })
    foreach ($tag in $tags) { if ($tag -notmatch $ServiceTagPattern) { Exit-InputProblem "$At holds '$tag', which is not *, an IPv4 address or range in CIDR form, or a service tag." } }
    if ($Values -contains '*' -and $Values.Count -gt 1) { Exit-InputProblem "$At mixes * with other values. Use * alone." }
    if ($tags.Count -gt 1) { Exit-InputProblem "$At holds more than one service tag. A rule takes one service tag." }
    if ($tags.Count -eq 1 -and $Values.Count -gt 1) { Exit-InputProblem "$At mixes a service tag with addresses. A service tag cannot be combined with other values." }
}
function Test-PortList([string[]]$Values, [string]$At) {
    foreach ($port in $Values) {
        if ($port -notmatch $PortPattern) { Exit-InputProblem "$At holds '$port', which is not * , a port or a range such as 8000-8100." }
        if ($port -ne '*') { foreach ($n in $port.Split('-')) { if ([int]$n -gt 65535) { Exit-InputProblem "$At holds '$port': a port is 0 to 65535." } } }
    }
    if ($Values -contains '*' -and $Values.Count -gt 1) { Exit-InputProblem "$At mixes * with other ports. Use * alone." }
}

# One az call. Returns the text of standard output (warnings on standard error are dropped); throws with the error text when az fails.
function Invoke-Az {
    $out = @(& az @args 2>&1)
    if ($LASTEXITCODE -ne 0) { throw (($out | ForEach-Object { "$_" }) -join ' ').Trim() }
    (@($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
}
# One az call with JSON output, parsed; $null when az printed nothing.
function Invoke-AzJson {
    $text = Invoke-Az @args '--output' 'json'
    if ($text) { $text | ConvertFrom-Json }
}
# The --tags arguments of az, from the file-level tags map; nothing when there are none.
function Get-TagArgument { if ($tags.Count) { '--tags'; @($tags.Keys | Sort-Object | ForEach-Object { "$_=$($tags[$_])" }) } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$defaultLocation = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')).Trim()
$rawGroups = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.network_security_groups'
$groupEntries = @(@($rawGroups) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networkEntries = @(@($rawNetworks) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptionEntries = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($groupEntries.Count -eq 0) {
    Write-Line 'The file lists no landing_zone.network_security_groups: nothing to do.'
    exit 0
}
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }

# ---- the groups and their rules
$definitions = [System.Collections.Generic.List[object]]::new()
$seenGroup = @{}
$gi = -1
foreach ($entry in $groupEntries) {
    $gi++
    $at = "landing_zone.network_security_groups[$gi]"
    $name = Get-Entry $entry 'name'
    if ($name -notmatch $NamePattern) { Exit-InputProblem "$at.name '$name' is missing or is not a valid network security group name (1 to 80 letters, digits, . _ -; starts with a letter or digit, ends with a letter, digit or underscore)." }
    if ($seenGroup.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seenGroup[$name.ToLowerInvariant()] = $true

    $rules = [System.Collections.Generic.List[object]]::new()
    $seenRule = @{}
    $seenPriority = @{}
    $ri = -1
    $rawRules = if ($entry.Contains('rules')) { $entry['rules'] } else { $null }
    foreach ($rule in @(@($rawRules) | Where-Object { $null -ne $_ })) {
        $ri++
        $rat = "$at.rules[$ri]"
        if ($rule -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$rat is not a rule (a map with name, priority, direction, access and destination_port_ranges)." }
        $ruleName = Get-Entry $rule 'name'
        if ($ruleName -notmatch $NamePattern) { Exit-InputProblem "$rat.name '$ruleName' is missing or is not a valid rule name (1 to 80 letters, digits, . _ -; starts with a letter or digit, ends with a letter, digit or underscore)." }
        if ($seenRule.ContainsKey($ruleName.ToLowerInvariant())) { Exit-InputProblem "$rat.name '$ruleName' is listed twice in '$name'." }
        $seenRule[$ruleName.ToLowerInvariant()] = $true

        $priority = 0
        if (-not [int]::TryParse((Get-Entry $rule 'priority'), [ref]$priority) -or $priority -lt 100 -or $priority -gt 4096) { Exit-InputProblem "$rat.priority must be a whole number from 100 to 4096; found '$(Get-Entry $rule 'priority')'." }
        $direction = Get-Entry $rule 'direction'
        $directionName = @('Inbound', 'Outbound') | Where-Object { $_ -ieq $direction } | Select-Object -First 1
        if (-not $directionName) { Exit-InputProblem "$rat.direction must be Inbound or Outbound; found '$direction'." }
        $access = Get-Entry $rule 'access'
        $accessName = @('Allow', 'Deny') | Where-Object { $_ -ieq $access } | Select-Object -First 1
        if (-not $accessName) { Exit-InputProblem "$rat.access must be Allow or Deny; found '$access'." }
        if ($seenPriority.ContainsKey("$directionName|$priority")) { Exit-InputProblem "$rat.priority $priority is used twice for $directionName rules of '$name'. Two rules cannot have the same priority and direction." }
        $seenPriority["$directionName|$priority"] = $true

        $protocolText = Get-Entry $rule 'protocol'
        $protocol = if (-not $protocolText) { '*' } elseif ($Protocols.ContainsKey($protocolText.ToLowerInvariant())) { $Protocols[$protocolText.ToLowerInvariant()] } else { Exit-InputProblem "$rat.protocol '$protocolText' is not one of: *, Tcp, Udp, Icmp, Esp, Ah." }

        $sourceAddress = @(ConvertTo-TextList $(if ($rule.Contains('source_address_prefixes')) { $rule['source_address_prefixes'] })); if ($sourceAddress.Count -eq 0) { $sourceAddress = @('*') }
        $destinationAddress = @(ConvertTo-TextList $(if ($rule.Contains('destination_address_prefixes')) { $rule['destination_address_prefixes'] })); if ($destinationAddress.Count -eq 0) { $destinationAddress = @('*') }
        $sourcePort = @(ConvertTo-TextList $(if ($rule.Contains('source_port_ranges')) { $rule['source_port_ranges'] })); if ($sourcePort.Count -eq 0) { $sourcePort = @('*') }
        $destinationPort = @(ConvertTo-TextList $(if ($rule.Contains('destination_port_ranges')) { $rule['destination_port_ranges'] }))
        if ($destinationPort.Count -eq 0) { Exit-InputProblem "$rat.destination_port_ranges is missing. List the ports (or *) the rule matches." }
        Test-AddressList $sourceAddress "$rat.source_address_prefixes"
        Test-AddressList $destinationAddress "$rat.destination_address_prefixes"
        Test-PortList $sourcePort "$rat.source_port_ranges"
        Test-PortList $destinationPort "$rat.destination_port_ranges"
        $description = Get-Entry $rule 'description'
        if ($description.Length -gt 140) { Exit-InputProblem "$rat.description is longer than 140 characters." }

        $rules.Add([pscustomobject]@{
                Name = $ruleName; Priority = $priority; Direction = $directionName; Access = $accessName; Protocol = $protocol; Description = $description
                SourceAddress = $sourceAddress; SourcePort = $sourcePort; DestinationAddress = $destinationAddress; DestinationPort = $destinationPort
            })
    }
    $definitions.Add([pscustomobject]@{ Name = $name; Rules = @($rules) })
}

# ---- where each group goes: the network of every subnet that names it
$targets = [System.Collections.Generic.List[object]]::new()
$used = @{}
$ni = -1
foreach ($network in $networkEntries) {
    $ni++
    $at = "landing_zone.networks[$ni]"
    $rawSubnets = if ($network.Contains('subnets')) { $network['subnets'] } else { $null }
    $wantedNames = @(@($rawSubnets) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { Get-Entry $_ 'network_security_group' } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($groupName in $wantedNames) {
        $definition = @($definitions | Where-Object { $_.Name -ieq $groupName }) | Select-Object -First 1
        if (-not $definition) { continue }
        $used[$definition.Name.ToLowerInvariant()] = $true
        $networkName = Get-Entry $network 'name'
        $subscriptionName = Get-Entry $network 'subscription'
        $subscription = @($subscriptionEntries | Where-Object { (Get-Entry $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
        $subscriptionId = if ($subscription) { Get-Entry $subscription 'id' } else { '' }
        if (-not $subscriptionName) { Exit-InputProblem "$at '$networkName': no subscription, so the group '$($definition.Name)' has no place." }
        if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "$at '$networkName': the subscription '$subscriptionName' has no usable id in landing_zone.subscriptions." }
        $resourceGroup = Get-Entry $network 'resource_group'
        if (-not $resourceGroup) { Exit-InputProblem "$at '$networkName': no resource_group, so the group '$($definition.Name)' has no place." }
        $location = Get-Entry $network 'location'
        if (-not $location) { $location = $defaultLocation }
        if (-not $location) { Exit-InputProblem "$at '$networkName': no location, and azure.location is empty." }
        $key = "$($subscriptionId.ToLowerInvariant())/$($resourceGroup.ToLowerInvariant())/$($definition.Name.ToLowerInvariant())"
        if (@($targets | Where-Object { $_.Key -eq $key }).Count -eq 0) {
            $targets.Add([pscustomobject]@{ Key = $key; Definition = $definition; SubscriptionId = $subscriptionId; Subscription = $subscriptionName; ResourceGroup = $resourceGroup; Location = $location; Network = $networkName })
        }
    }
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use New-LandingZoneNsg.ps1.' }
try { $account = Invoke-Az account show --query tenantId --output tsv }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($account -ne $tenantId) { Exit-Failed "Signed in to tenant $account, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

# The az arguments of "az network nsg rule create" for one rule of a group in one place.
function Get-RuleArgument([object]$Rule, [object]$Target) {
    $arguments = @('network', 'nsg', 'rule', 'create', '--nsg-name', $Target.Definition.Name, '--resource-group', $Target.ResourceGroup, '--subscription', $Target.SubscriptionId,
        '--name', $Rule.Name, '--priority', [string]$Rule.Priority, '--direction', $Rule.Direction, '--access', $Rule.Access, '--protocol', $Rule.Protocol)
    $arguments += '--source-address-prefixes'; $arguments += @($Rule.SourceAddress)
    $arguments += '--source-port-ranges'; $arguments += @($Rule.SourcePort)
    $arguments += '--destination-address-prefixes'; $arguments += @($Rule.DestinationAddress)
    $arguments += '--destination-port-ranges'; $arguments += @($Rule.DestinationPort)
    if ($Rule.Description) { $arguments += '--description'; $arguments += $Rule.Description }
    $arguments
}
function Get-RuleDifference([object]$Wanted, [object]$Have) {
    $differences = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in @(@('priority', 'Priority', $Wanted.Priority), @('direction', 'Direction', $Wanted.Direction), @('access', 'Access', $Wanted.Access), @('protocol', 'Protocol', $Wanted.Protocol))) {
        if ($Have.PSObject.Properties[$pair[0]] -and "$($Have.($pair[0]))" -and "$($Have.($pair[0]))" -ine "$($pair[2])") { $differences.Add("$($pair[1]) is $($Have.($pair[0])), the file says $($pair[2])") }
    }
    $differences
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($definition in $definitions) {
    if (-not $used.ContainsKey($definition.Name.ToLowerInvariant())) {
        $rows.Add([pscustomobject][ordered]@{ NetworkSecurityGroup = $definition.Name; ResourceGroup = ''; Action = 'NotUsed'; RulesAdded = 0; Detail = 'No subnet of landing_zone.networks names this group (network_security_group), so it has no resource group or region. Nothing created.' })
        Write-Warning "$($definition.Name): no subnet of landing_zone.networks names it; nothing created."
    }
}

Write-Line "Network security groups: $($targets.Count) to place from $($definitions.Count) in the file"
foreach ($target in $targets) {
    $definition = $target.Definition
    $row = [ordered]@{ NetworkSecurityGroup = $definition.Name; ResourceGroup = $target.ResourceGroup; Action = ''; RulesAdded = 0; Detail = '' }
    try {
        $existing = $null
        try { $existing = Invoke-AzJson network nsg show --name $definition.Name --resource-group $target.ResourceGroup --subscription $target.SubscriptionId }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

        if (-not $existing) {
            if ($PSCmdlet.ShouldProcess("network security group '$($definition.Name)' in '$($target.ResourceGroup)'", "Create ($($target.Location), $($definition.Rules.Count) rule(s))")) {
                $createArgs = @('network', 'nsg', 'create', '--name', $definition.Name, '--resource-group', $target.ResourceGroup, '--location', $target.Location, '--subscription', $target.SubscriptionId)
                $createArgs += @(Get-TagArgument)
                $null = Invoke-AzJson @createArgs
                foreach ($rule in $definition.Rules) {
                    $ruleArguments = Get-RuleArgument $rule $target
                    $null = Invoke-AzJson @ruleArguments
                }
                $row.Action = 'Created'; $row.RulesAdded = $definition.Rules.Count
                Write-Line "[created] $($definition.Name) in '$($target.ResourceGroup)' ($($target.Location)), $($definition.Rules.Count) rule(s)."
            }
            else {
                $row.Action = 'WouldCreate'; $row.RulesAdded = $definition.Rules.Count
                Write-Line "[plan]    $($definition.Name) would be created in '$($target.ResourceGroup)' ($($target.Location)), $($definition.Rules.Count) rule(s)."
            }
        }
        else {
            $have = @(if ($existing.PSObject.Properties['securityRules'] -and $existing.securityRules) { $existing.securityRules })
            $missing = @($definition.Rules | Where-Object { $wantedName = $_.Name; -not @($have | Where-Object { $_.name -ieq $wantedName }) })
            $notes = [System.Collections.Generic.List[string]]::new()
            foreach ($rule in @($definition.Rules | Where-Object { $missing -notcontains $_ })) {
                $current = @($have | Where-Object { $_.name -ieq $rule.Name }) | Select-Object -First 1
                $difference = @(Get-RuleDifference $rule $current)
                if ($difference.Count) { $notes.Add("rule '$($rule.Name)': $($difference -join '; '); left unchanged") }
            }
            if ($missing.Count -eq 0) {
                $row.Action = 'AlreadyExists'
                Write-Line "[exists]  $($definition.Name) is already there with every rule of the file, nothing changed."
            }
            elseif ($PSCmdlet.ShouldProcess("network security group '$($definition.Name)' in '$($target.ResourceGroup)'", "Add $($missing.Count) rule(s): $(($missing | ForEach-Object { $_.Name }) -join ', ')")) {
                foreach ($rule in $missing) {
                    $ruleArguments = Get-RuleArgument $rule $target
                    $null = Invoke-AzJson @ruleArguments
                }
                $row.Action = 'RulesAdded'; $row.RulesAdded = $missing.Count
                Write-Line "[updated] $($definition.Name): added $($missing.Count) rule(s): $(($missing | ForEach-Object { $_.Name }) -join ', ')."
            }
            else {
                $row.Action = 'WouldAddRules'; $row.RulesAdded = $missing.Count
                Write-Line "[plan]    $($definition.Name) would get $($missing.Count) rule(s): $(($missing | ForEach-Object { $_.Name }) -join ', ')."
            }
            if ($notes.Count) { $row.Detail = $notes -join ' | '; Write-Warning "$($definition.Name): $($row.Detail)" }
        }
    }
    catch {
        $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
        Write-Warning "$($definition.Name): $($row.Detail)"
    }
    $rows.Add([pscustomobject]$row)
}

$failed = @($rows | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $(@($rows | Where-Object Action -EQ 'Created').Count) created, $(@($rows | Where-Object Action -EQ 'RulesAdded').Count) with rules added, $(@($rows | Where-Object Action -EQ 'AlreadyExists').Count) already there, $(@($rows | Where-Object Action -In 'WouldCreate', 'WouldAddRules').Count) planned, $(@($rows | Where-Object Action -EQ 'NotUsed').Count) not used, $failed failed."

$rows
if ($failed -gt 0) { exit 1 }
exit 0
