<#
.SYNOPSIS
    Creates the Azure Local logical networks that networking.logical_networks of infrastructure.yml lists, with the Azure CLI only.

.DESCRIPTION
    Phase 06 (post-deployment), Task 08 (logical network creation). Azure CLI variant of New-LogicalNetwork.ps1: the same keys, the same checks and
    the same exit codes, with one difference. It does the Azure side only and never reaches a node, so it cannot read the external virtual switch of
    the cluster (Get-VMSwitch -SwitchType External) the way the PowerShell script does: every enabled network must name its switch in
    networking.logical_networks[].vm_switch_name, or the script stops with exit code 2 before it sends anything. A logical network is the Azure resource that says how the network interfaces
    of Azure Local virtual machines connect to the physical network: virtual switch, VLAN, address space, gateway, DNS servers and an address pool
    (Microsoft Learn, Create logical networks for Azure Local VMs). For every entry of networking.logical_networks that is not disabled
    (enabled: false) the script creates the logical network in azure.resource_group, on the custom location of the instance (azure.custom_location),
    in azure.location, with the file-level tags.

    Static networks (the default; ip_allocation_method Static) need address_prefix, gateway, dns_servers, vlan_id (0 for untagged) and ip_pool: Learn
    says DNS server, gateway and VLAN ID must be specified for a static logical network. Dynamic networks (DHCP) need nothing more; gateway, DNS
    servers and pool of a Dynamic entry are not used and the script says so.

    The virtual switch. The logical network is created on an external virtual switch of the cluster, and the name cannot be changed afterwards.
    Learn gets the name with Get-VMSwitch -SwitchType External on a machine of the instance. This script does not reach the cluster, so the name
    comes from networking.logical_networks[].vm_switch_name of each enabled network, and the script cannot check it against the cluster. Read the
    name with Get-VMSwitch -SwitchType External on a node, or use New-LogicalNetwork.ps1, which reads it. The script does not build a name from the
    intent.

    Network security groups. A logical network is tied to its network security group (nsg_name) at the moment it is created, so run
    New-NetworkSecurityGroup.azcli.ps1 (task 07) first. A network with nsg_name needs sdn.enabled true, the name in networking.network_security_groups,
    and the group, with at least one rule, in Azure. The script does not associate a group with a logical network that already exists.

    Azure CLI. The PowerShell cmdlet New-AzStackHCIVMLogicalNetwork documents no network security group and no gateway parameter, so the script
    uses the Azure CLI (az stack-hci-vm network lnet create) with the stack-hci-vm extension. It does not install the extension: install it
    yourself (az extension add --name stack-hci-vm). It does not sign in: run az login --tenant <azure.tenant_id> first. It does not change the
    Azure CLI default subscription: every call carries --subscription.

    Idempotent. A logical network that exists is reported as AlreadyExists and left alone (Learn: gateway, IP pools, address space, VLAN ID and
    virtual switch cannot be changed after creation); a difference from the file is reported. Nothing is deleted or changed. -WhatIf reads Azure
    and changes nothing.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location, azure.custom_location, tags, sdn.enabled
        networking.network_security_groups[]: name
        networking.logical_networks[]: name, enabled, ip_allocation_method, vlan_id, address_prefix, gateway, dns_servers, ip_pool.start,
                                       ip_pool.end, nsg_name, vm_switch_name

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every logical network exists (created now, already there, planned under -WhatIf, disabled) or the file lists none; 1 a call or a
    precondition failed (az missing, not signed in, wrong tenant, extension missing, a lookup or a creation failed); 2 a value in the file is missing
    or not usable, including an enabled network without vm_switch_name. On exit code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-LogicalNetwork.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which logical networks would be created and on which virtual switch, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-LogicalNetwork.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the logical networks. Run it again: they are reported as AlreadyExists.
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
# Microsoft Learn, naming rules for Microsoft.Network (Learn points to them for logical networks): 1 to 80 characters; letters, digits, underscore, period and hyphen; start with a letter or digit; end with a letter, digit or underscore.
$ResourceName = '^[A-Za-z0-9]([A-Za-z0-9._-]{0,78}[A-Za-z0-9_])?$'
$Octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
$Ipv4 = "^($Octet\.){3}$Octet$"
$Cidr = "^($Octet\.){3}$Octet/([0-9]|[12][0-9]|3[0-2])$"
# The registry default of networking.logical_networks[].ip_allocation_method (the key is optional); Microsoft Learn: Static or Dynamic.
$DefaultAllocationMethod = 'Static'

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
function ConvertTo-Address([string]$Address) {
    $bytes = ([ipaddress]$Address).GetAddressBytes()
    [Array]::Reverse($bytes)
    [BitConverter]::ToUInt32($bytes, 0)
}
function Test-InSubnet([string]$Address, [string]$Subnet) {
    $network, $length = $Subnet.Split('/')
    $mask = [uint32](([uint64]4294967295 -shl (32 - [int]$length)) -band [uint64]4294967295)
    ((ConvertTo-Address $Address) -band $mask) -eq ((ConvertTo-Address $network) -band $mask)
}

# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the exit code, stdout and stderr.
function Invoke-AzCli([string[]]$Arguments) {
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $Arguments
    if ($unsafe) { Exit-InputProblem $unsafe }
    # Not az.cmd: a virtual switch that Network ATC named has parentheses (ComputeSwitch(compute)), and cmd.exe ends the batch file at the closing one.
    $launcher = Get-AzlAzureCliLauncher
    $parenthesis = Get-AzlAzureCliParenthesisProblem -Launcher $launcher -Argument $Arguments
    if ($parenthesis) { Exit-InputProblem $parenthesis }
    $all = @(& $launcher.Command @($launcher.Prefix + $Arguments) 2>&1)
    $code = [int](Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err; Detail = $(if ($err) { $err.Trim() } else { $out.Trim() }) }
}
function ConvertFrom-AzJson([string]$Text) { if ($Text -and $Text.Trim()) { $Text | ConvertFrom-Json -Depth 20 } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$networking = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking'
$networkList = @(@(Get-Field $networking 'logical_networks' @()) | Where-Object { $null -ne $_ })
if ($networkList.Count -eq 0) {
    Write-Line 'The file lists no networking.logical_networks: nothing to do.'
    exit 0
}
$groupNames = @(@(Get-Field $networking 'network_security_groups' @()) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne (Get-Field $networking 'network_security_groups' @())) { Exit-InputProblem 'An entry of networking.network_security_groups is not a map (names with their settings).' } } | ForEach-Object { ([string](Get-Field $_ 'name' '')).Trim().ToLowerInvariant() })

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$location = Get-Text 'azure.location'
$customLocation = Get-Text 'azure.custom_location'
$sdnEnabled = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'sdn.enabled'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tagArguments = @()
if ($rawTags -is [System.Collections.IDictionary]) {
    foreach ($k in $rawTags.Keys) {
        if ($null -eq $rawTags[$k]) { continue }
        $pair = "$k=$($rawTags[$k])"
        $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "tags.$k" = $pair }); if ($problem) { Exit-InputProblem $problem }
        $tagArguments += $pair
    }
}

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The logical networks are created there.' }
if (-not $location) { Exit-InputProblem 'azure.location is missing.' }
if (-not $customLocation) { Exit-InputProblem 'azure.custom_location is missing. It is the custom location of the Azure Local instance.' }
$customLocationId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ExtendedLocation/customLocations/$customLocation"

$plans = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($entry in $networkList) {
    $index++
    $at = "networking.logical_networks[$index]"
    if ($entry -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a logical network (a map with name)." }
    $name = ([string](Get-Field $entry 'name' '')).Trim()
    if ($name -notmatch $ResourceName) { Exit-InputProblem "$at.name '$name' is not a valid name: 1 to 80 letters, digits, underscore, period or hyphen, starting with a letter or digit and ending with a letter, digit or underscore." }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seen[$name.ToLowerInvariant()] = $true

    $enabled = Get-Field $entry 'enabled' $true
    if ($enabled -isnot [bool]) { Exit-InputProblem "$at.enabled must be true or false; found '$enabled'." }
    if (-not $enabled) { $plans.Add([pscustomobject]@{ Name = $name; Enabled = $false }); continue }

    $method = ([string](Get-Field $entry 'ip_allocation_method' $DefaultAllocationMethod)).Trim()
    $methodName = switch ($method.ToLowerInvariant()) { 'static' { 'Static' } 'dynamic' { 'Dynamic' } default { '' } }
    if (-not $methodName) { Exit-InputProblem "$at.ip_allocation_method must be Static or Dynamic; found '$method'." }

    $vlanRaw = Get-Field $entry 'vlan_id'
    $vlan = $null
    if ($null -ne $vlanRaw) {
        $number = 0
        if (-not [int]::TryParse("$vlanRaw", [ref]$number) -or $number -lt 0 -or $number -gt 4094) { Exit-InputProblem "$at.vlan_id must be a whole number from 0 to 4094; found '$vlanRaw'." }
        $vlan = $number
    }

    $plan = [ordered]@{ Name = $name; Enabled = $true; Method = $methodName; Vlan = $vlan; Prefix = ''; Gateway = ''; Dns = @(); PoolStart = ''; PoolEnd = ''; Nsg = ''; Switch = '' }
    if ($methodName -eq 'Static') {
        $prefix = ([string](Get-Field $entry 'address_prefix' '')).Trim()
        if ($prefix -notmatch $Cidr) { Exit-InputProblem "$at.address_prefix '$prefix' is missing or is not an IPv4 range in CIDR form. A static logical network needs it." }
        $gateway = ([string](Get-Field $entry 'gateway' '')).Trim()
        if ($gateway -notmatch $Ipv4) { Exit-InputProblem "$at.gateway '$gateway' is missing or is not an IPv4 address. Microsoft Learn: gateway, DNS server and VLAN ID must be specified for a static logical network." }
        if (-not (Test-InSubnet $gateway $prefix)) { Exit-InputProblem "$at.gateway $gateway is outside address_prefix $prefix." }
        $dnsList = @(@(Get-Field $entry 'dns_servers' @()) | ForEach-Object { ([string]$_).Trim() })
        if ($dnsList.Count -eq 0) { Exit-InputProblem "$at.dns_servers is missing. Microsoft Learn: gateway, DNS server and VLAN ID must be specified for a static logical network." }
        foreach ($dns in $dnsList) { if ($dns -notmatch $Ipv4) { Exit-InputProblem "$at.dns_servers holds '$dns', which is not an IPv4 address." } }
        if ($null -eq $vlan) { Exit-InputProblem "$at.vlan_id is missing. Microsoft Learn: gateway, DNS server and VLAN ID must be specified for a static logical network. Use 0 for untagged." }
        $pool = Get-Field $entry 'ip_pool'
        $poolStart = ([string](Get-Field $pool 'start' '')).Trim()
        $poolEnd = ([string](Get-Field $pool 'end' '')).Trim()
        if ($poolStart -notmatch $Ipv4 -or $poolEnd -notmatch $Ipv4) { Exit-InputProblem "$at.ip_pool needs start and end, both IPv4 addresses. A static logical network needs the pool of addresses for virtual machines." }
        if (-not (Test-InSubnet $poolStart $prefix) -or -not (Test-InSubnet $poolEnd $prefix)) { Exit-InputProblem "$at.ip_pool ($poolStart to $poolEnd) is not inside address_prefix $prefix." }
        if ((ConvertTo-Address $poolStart) -gt (ConvertTo-Address $poolEnd)) { Exit-InputProblem "$at.ip_pool start $poolStart is above its end $poolEnd." }
        $plan.Prefix = $prefix; $plan.Gateway = $gateway; $plan.Dns = $dnsList; $plan.PoolStart = $poolStart; $plan.PoolEnd = $poolEnd
    }
    else {
        foreach ($unused in 'gateway', 'dns_servers', 'ip_pool') {
            if ($null -ne (Get-Field $entry $unused)) { Write-Warning "$at.$unused is not used: the network is Dynamic, so DHCP hands out the addresses." }
        }
    }

    $nsgName = ([string](Get-Field $entry 'nsg_name' '')).Trim()
    if ($nsgName) {
        if ($nsgName -notmatch $ResourceName) { Exit-InputProblem "$at.nsg_name '$nsgName' is not a valid network security group name." }
        if ($sdnEnabled -isnot [bool] -or -not $sdnEnabled) { Exit-InputProblem "$at.nsg_name is set, but sdn.enabled is not true. Network security groups need SDN enabled by Azure Arc; this script does not turn SDN on." }
        if ($groupNames -notcontains $nsgName.ToLowerInvariant()) { Exit-InputProblem "$at.nsg_name '$nsgName' is not in networking.network_security_groups[]. List the group there and create it first with New-NetworkSecurityGroup.azcli.ps1 (task 07): the group is tied to the logical network when it is created." }
        $plan.Nsg = $nsgName
    }
    $switchName = ([string](Get-Field $entry 'vm_switch_name' '')).Trim()
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "$at.vm_switch_name" = $switchName }); if ($problem) { Exit-InputProblem $problem }
    if (-not $switchName) { Exit-InputProblem "$at.vm_switch_name is missing. This script does not reach the cluster, so it cannot read the external virtual switch (Get-VMSwitch -SwitchType External on a node). Name the switch in the file, or use New-LogicalNetwork.ps1." }
    $plan.Switch = $switchName
    $plans.Add([pscustomobject]$plan)
}

$active = @($plans | Where-Object Enabled)
# Learn: logical networks with overlapping IP pools on the same VLAN are not permitted.
for ($i = 0; $i -lt $active.Count; $i++) {
    for ($j = $i + 1; $j -lt $active.Count; $j++) {
        $a = $active[$i]; $b = $active[$j]
        if ($a.Method -ne 'Static' -or $b.Method -ne 'Static' -or $a.Vlan -ne $b.Vlan) { continue }
        if ((ConvertTo-Address $a.PoolStart) -le (ConvertTo-Address $b.PoolEnd) -and (ConvertTo-Address $b.PoolStart) -le (ConvertTo-Address $a.PoolEnd)) {
            Exit-InputProblem "The IP pools of '$($a.Name)' and '$($b.Name)' overlap on VLAN $($a.Vlan). Microsoft Learn does not permit overlapping IP pools on the same VLAN."
        }
    }
}

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A value that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group; 'azure.location' = $location; 'azure.custom_location' = $customLocation })
if ($problem) { Exit-InputProblem $problem }

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

Write-Line "Logical networks in '$group' ($location), custom location '$customLocation'"

# Which networks exist, read before anything is created.
$toCreate = [System.Collections.Generic.List[object]]::new()
foreach ($plan in $plans) {
    $item = "logical network $($plan.Name)"
    if (-not $plan.Enabled) { Add-Row $item 'Skipped' 'enabled is false'; continue }
    try {
        $show = Invoke-AzCli (@('stack-hci-vm', 'network', 'lnet', 'show') + $common + @('--name', $plan.Name, '--output', 'json', '--only-show-errors'))
        if ($show.ExitCode -eq 0) {
            $have = ConvertFrom-AzJson $show.Output
            $differences = [System.Collections.Generic.List[string]]::new()
            $subnet = @(Get-Prop $have @('properties', 'subnets')) | Select-Object -First 1
            $havePrefix = [string](Get-Prop $subnet @('properties', 'addressPrefix'))
            if ($plan.Method -eq 'Static' -and $havePrefix -and $havePrefix -ne $plan.Prefix) { $differences.Add("address prefix is $havePrefix") }
            $haveMethod = [string](Get-Prop $subnet @('properties', 'ipAllocationMethod'))
            if ($haveMethod -and $haveMethod -ne $plan.Method) { $differences.Add("allocation method is $haveMethod") }
            $haveSwitch = [string](Get-Prop $have @('properties', 'vmSwitchName'))
            if ($plan.Switch -and $haveSwitch -and $haveSwitch -ne $plan.Switch) { $differences.Add("virtual switch is $haveSwitch") }
            Add-Row $item 'AlreadyExists' $(if ($differences.Count) { "differs from the file ($($differences -join '; ')); left unchanged. A logical network cannot be changed after it is created: create one with another name." } else { '' })
        }
        elseif ($show.Detail -match $NotFound) { $toCreate.Add($plan) }
        else { throw "The lookup failed: $($show.Detail)" }
    }
    catch { Add-Row $item 'Failed' $_.Exception.Message }
}

foreach ($plan in $toCreate) {
    $item = "logical network $($plan.Name)"
    try {
        $switchUse = $plan.Switch

        if ($plan.Nsg) {
            $nsg = Invoke-AzCli (@('stack-hci-vm', 'network', 'nsg', 'show') + $common + @('--name', $plan.Nsg, '--output', 'json', '--only-show-errors'))
            if ($nsg.ExitCode -ne 0) {
                if ($nsg.Detail -match $NotFound) { throw "The network security group '$($plan.Nsg)' does not exist in '$group'. Run New-NetworkSecurityGroup.azcli.ps1 (task 07) first." }
                throw "The network security group '$($plan.Nsg)' could not be read: $($nsg.Detail)"
            }
            $nsgRules = Invoke-AzCli (@('stack-hci-vm', 'network', 'nsg', 'rule', 'list') + $common + @('--nsg-name', $plan.Nsg, '--output', 'json', '--only-show-errors'))
            if ($nsgRules.ExitCode -ne 0) { throw "The rules of '$($plan.Nsg)' could not be read: $($nsgRules.Detail)" }
            if (@(@(ConvertFrom-AzJson $nsgRules.Output) | Where-Object { $null -ne $_ }).Count -eq 0) {
                throw "The network security group '$($plan.Nsg)' has no rule. An empty group denies all inbound traffic and the logical network would not be reachable (Microsoft Learn). Run New-NetworkSecurityGroup.azcli.ps1 again to create its rules."
            }
        }

        $summary = "$($plan.Method), VLAN $(if ($null -ne $plan.Vlan) { $plan.Vlan } else { 'default' }), switch $switchUse$(if ($plan.Nsg) { ", group $($plan.Nsg)" })"
        if ($PSCmdlet.ShouldProcess("logical network '$($plan.Name)' in '$group'", "Create ($summary)")) {
            $arguments = @('stack-hci-vm', 'network', 'lnet', 'create') + $common + @(
                '--name', $plan.Name, '--custom-location', $customLocationId, '--location', $location, '--vm-switch-name', $switchUse, '--ip-allocation-method', $plan.Method)
            if ($null -ne $plan.Vlan) { $arguments += @('--vlan', [string]$plan.Vlan) }
            if ($plan.Method -eq 'Static') {
                $arguments += @('--address-prefixes', $plan.Prefix, '--gateway', $plan.Gateway, '--dns-servers') + $plan.Dns + @('--ip-pool-start', $plan.PoolStart, '--ip-pool-end', $plan.PoolEnd)
            }
            if ($plan.Nsg) { $arguments += @('--network-security-group', $plan.Nsg) }
            if ($tagArguments.Count) { $arguments += @('--tags') + $tagArguments }
            $result = Invoke-AzCli ($arguments + @('--output', 'none', '--only-show-errors'))
            if ($result.ExitCode -ne 0) { throw "The creation failed: $($result.Detail)" }
            Add-Row $item 'Created' $summary
        }
        else { Add-Row $item 'WouldCreate' $summary }
    }
    catch { Add-Row $item 'Failed' $_.Exception.Message }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
