#Requires -Version 7.0
<#
.SYNOPSIS
    Reads and checks infrastructure.yml, the one environment file for an Azure Local instance (schema 5).

.DESCRIPTION
    Every toolkit script reads the environment through this module, so no script parses keys its own way.

    Import-AzlInfrastructure  Read the file, check it, and return it as a hashtable. Stops when the file has errors.
    Test-AzlInfrastructure    Check the file and return every finding: schema errors first, then the checks that a
                              JSON schema can't express (addresses inside subnets, the infrastructure pool, node counts,
                              Key Vault references). Each finding has an ID, a severity, the key path, a message and,
                              for rules from Microsoft's documentation, the Learn page.
    Get-AzlInfrastructureValue  Read one value by its dotted path, for example networking.management.gateway.
    Get-AzlManagementIpAssignment  How the machines' management addresses are set: static (default), dhcp or preconfigured;
                              with -Node, that node's management port (schema 5.2 adds dhcp_reservation).
    Get-AzlArcMachineName     A node's Arc machine name: arc_machine_name, else the node name.
    Get-AzlNodeNetworkAdapter A node's ports: nodes[].network_adapters (5.2), or one port made from nodes[].management.
    Get-AzlManagementAdapter  The port that owns a node's management address, with the address, mask, gateway, DNS and
                              the VLAN the host tags, defaults applied from networking.management.
    Get-AzlBiosSetting        A node's BIOS attributes: hardware.bios with nodes[].bios merged over it (the final state);
                              with -Phase DuringProvisioning, the values for the OS install (5.3).
    Get-AzlBiosProvisioningOverride  The BIOS keys that hold for the OS install only (5.3), each with the value to set
                              back afterwards.
    Get-AzlManagementStaticMethod  Who sets the static management address (5.3): device (default) or site.
    Get-AzlInfrastructureScope  _metadata.scope (5.3): full (default) or ztp, a file for azurelocal-ztp on its own.
    Get-AzlSiteIpRange        The site's management address range for simplified provisioning: site_ip_range, else the
                              lowest to the highest static management address.

    Needs the powershell-yaml module. The schema is infrastructure.schema.json in config/variables/schema (generated from the master registry).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DefaultSchemaPath = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'config', 'variables', 'schema', 'infrastructure.schema.json'))
$script:SupportedMajor = 5

# HOOK remoting-profiles (schema 5.6): rules AZL-060 to AZL-068 live with the profile resolver, so the validator and the run agree.
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'remoting' 'AzlRemotingProfile.psm1'))

$script:Learn = @{
    Decision8   = 'https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-8-determine-management-ips-and-infrastructure-network'
    Decision4   = 'https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-4-determine-cluster-size'
    Topologies  = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-introduction#validated-network-topologies'
    RackAware   = 'https://learn.microsoft.com/azure/azure-local/concepts/rack-aware-cluster-requirements'
    Witness     = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-prerequisites'
    Quorum      = 'https://learn.microsoft.com/windows-server/storage/storage-spaces/quorum#cluster-quorum-overview'
    Intents     = 'https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-7-determine-network-traffic-intents'
    CustomIp    = 'https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#custom-ips-for-storage'
    Simplified  = 'https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning'
    Arm         = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template#arm-template-parameters-reference'
    Symmetry    = 'https://learn.microsoft.com/azure/azure-local/concepts/host-network-requirements#switch-embedded-teaming-set'
    AtcPrereq   = 'https://learn.microsoft.com/windows-server/networking/network-atc/network-atc#prerequisites'
}

# networking.management.ip_assignment (5.0, 5.1) as a port's ip_assignment (5.2). 5.1's dhcp meant a reserved address.
$script:SiteModeToPort = @{ static = 'static'; dhcp = 'dhcp_reservation'; preconfigured = 'preconfigured' }
$script:AddressModes = @('static', 'dhcp_reservation', 'dhcp', 'preconfigured')

# ---------------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------------

function New-Finding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory finding object; changes no system state.')]
    param([string]$Id, [ValidateSet('error', 'warning', 'info')][string]$Severity, [string]$Path, [string]$Message, [string]$LearnUrl = '')
    [pscustomobject]@{ Id = $Id; Severity = $Severity; Path = $Path; Message = $Message; LearnUrl = $LearnUrl }
}

function Get-AzlInfrastructureValue {
    <#
    .SYNOPSIS
        Reads one value from a loaded infrastructure file by its dotted path. Returns $null when any part is missing.
    .EXAMPLE
        Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking.management.gateway'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][string]$Path)
    $node = $Infrastructure
    foreach ($part in $Path.Split('.')) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node = $node[$part] } else { return $null }
    }
    return , $node
}

function Get-AzlManagementIpAssignment {
    <#
    .SYNOPSIS
        How each machine's management address is set before deployment: static (the default), dhcp or preconfigured.
    .DESCRIPTION
        Reads networking.management.ip_assignment. static: the address is set on the port with management.mac_address
        (by simplified provisioning, or for an ISO install by the operator or the toolkit). dhcp: the port stays on DHCP,
        with a reservation for the MAC. preconfigured: the port is already configured and the tools leave it alone.
        Not networking.management.use_dhcp, which is the deployment's ARM useDhcp.

        With -Node, the ip_assignment of that node's management port (schema 5.2): static, dhcp_reservation, dhcp or
        preconfigured. For a node without network_adapters that is networking.management.ip_assignment, with 5.1's dhcp
        read as dhcp_reservation. Without -Node and without networking.management.ip_assignment, the value every node's
        management port shares, or 'mixed' when they differ.
    .EXAMPLE
        Get-AzlManagementIpAssignment -Infrastructure $infra
    .EXAMPLE
        Get-AzlManagementIpAssignment -Infrastructure $infra -Node $infra.nodes[0]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [System.Collections.IDictionary]$Node)
    if ($Node) {
        $owner = Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $Node
        if ($owner) { return $owner.IpAssignment }
        return $null
    }
    $mode = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'networking.management.ip_assignment'
    if ($mode -is [string] -and $mode) { return $mode.ToLowerInvariant() }
    $nodes = @(Get-List $Infrastructure['nodes'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('network_adapters') })
    if ($nodes.Count -gt 0) {
        $modes = @($nodes | ForEach-Object { Get-AzlManagementIpAssignment -Infrastructure $Infrastructure -Node $_ } | Where-Object { $_ } | Select-Object -Unique)
        if ($modes.Count -eq 1) { return $modes[0] }
        if ($modes.Count -gt 1) { return 'mixed' }
    }
    return 'static'
}

function Get-AzlNodeNetworkAdapter {
    <#
    .SYNOPSIS
        A node's physical ports as ordered dictionaries: nodes[].network_adapters (schema 5.2), or, for a node described with
        nodes[].management only, one management port made from it.
    .DESCRIPTION
        Each port carries its own keys plus _path (where it is in the file) and _source (network_adapters or management).
        A port made from nodes[].management has roles [management] and the ip_assignment networking.management.ip_assignment
        gives (5.1's dhcp is dhcp_reservation; default static).
    .EXAMPLE
        Get-AzlNodeNetworkAdapter -Infrastructure $infra -Node $infra.nodes[0] | ForEach-Object name
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    $index = [array]::IndexOf(@(Get-List $Infrastructure['nodes']), $Node)
    $at = if ($index -ge 0) { "nodes[$index]" } else { 'nodes[?]' }
    if ($Node.Contains('network_adapters')) {
        $list = @(Get-List $Node['network_adapters'])
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($list[$i] -isnot [System.Collections.IDictionary]) { continue }
            $a = [ordered]@{}
            foreach ($k in $list[$i].Keys) { $a[$k] = $list[$i][$k] }
            $a['_path'] = "$at.network_adapters[$i]"
            $a['_source'] = 'network_adapters'
            $a
        }
        return
    }
    $m = $Node['management']
    if ($m -isnot [System.Collections.IDictionary]) { return }
    $site = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'networking.management.ip_assignment'
    $mode = if ($site -is [string] -and $script:SiteModeToPort.ContainsKey($site.ToLowerInvariant())) { $script:SiteModeToPort[$site.ToLowerInvariant()] } else { 'static' }
    $a = [ordered]@{ name = $(if ($m['adapter_name']) { [string]$m['adapter_name'] } else { '' }); roles = @('management'); ip_assignment = $mode }
    if ($m.Contains('mac_address')) { $a['mac_address'] = $m['mac_address'] }
    if ($m.Contains('ip_address')) { $a['ip_address'] = $m['ip_address'] }
    $a['_path'] = "$at.management"
    $a['_source'] = 'management'
    $a
}

function Get-AzlManagementAdapter {
    <#
    .SYNOPSIS
        The port that owns a node's management address, with networking.management's defaults applied. $null when the node
        has no such port, or more than one.
    .OUTPUTS
        Name, MacAddress (AA:BB:CC:DD:EE:FF), IpAddress, PrefixLength, SubnetMask, Gateway, DnsServers, VlanId (the VLAN the
        host tags: 0 for an access port), VlanMode, IpAssignment, Source (network_adapters or management), Path.
    .EXAMPLE
        $infra.nodes | ForEach-Object { Get-AzlManagementAdapter -Infrastructure $infra -Node $_ }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    $owners = @(Get-AzlNodeNetworkAdapter -Infrastructure $Infrastructure -Node $Node | Where-Object { Test-IsManagementOwner $_ })
    if ($owners.Count -ne 1) { return $null }
    $a = $owners[0]
    $mgmt = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'networking.management'
    if ($mgmt -isnot [System.Collections.IDictionary]) { $mgmt = @{} }
    $prefix = if ($a.Contains('prefix_length')) { [int]$a['prefix_length'] } elseif (Test-IsCidr $mgmt['subnet']) { [int]($mgmt['subnet'].Split('/')[1]) } else { $null }
    $siteVlan = if ($null -ne $mgmt['vlan_id']) { [int]$mgmt['vlan_id'] } else { 0 }
    [pscustomobject]@{
        Name         = [string]$a['name']
        MacAddress   = ConvertTo-AzlMac $a['mac_address']
        IpAddress    = $(if ($a.Contains('ip_address')) { [string]$a['ip_address'] } else { $null })
        PrefixLength = $prefix
        SubnetMask   = $(if ($null -ne $prefix) { ConvertTo-SubnetMask $prefix } else { $null })
        Gateway      = $(if ($a.Contains('gateway')) { [string]$a['gateway'] } else { [string]$mgmt['gateway'] })
        DnsServers   = @(if ($a.Contains('dns_servers')) { Get-List $a['dns_servers'] } else { Get-List $mgmt['dns_servers'] })
        VlanId       = Get-HostVlan $a $siteVlan
        VlanMode     = $(if ($a.Contains('vlan_mode')) { [string]$a['vlan_mode'] } else { $null })
        IpAssignment = [string]$a['ip_assignment']
        Source       = [string]$a['_source']
        Path         = [string]$a['_path']
    }
}

function Merge-BiosSource([System.Collections.IDictionary]$Into, [object[]]$Source) {
    foreach ($one in $Source) {
        if ($one -isnot [System.Collections.IDictionary]) { continue }
        foreach ($k in $one.Keys) { $Into[[string]$k] = [string]$one[$k] }
    }
}

function Get-AzlBiosSetting {
    <#
    .SYNOPSIS
        A node's BIOS attributes: hardware.bios, with the node's own bios merged over it. Empty when neither is set.
    .DESCRIPTION
        -Phase Final (default): the machine's FINAL state, hardware.bios with nodes[].bios merged over it (schema 5.2).
        -Phase DuringProvisioning (schema 5.3): the values to apply at the Boot stage for the OS install: the final state
        with hardware.bios_during_provisioning and then nodes[].bios_during_provisioning merged over it, so a
        during-provisioning value wins over bios.
    .EXAMPLE
        Get-AzlBiosSetting -Infrastructure $infra -Node $infra.nodes[0]
    .EXAMPLE
        Get-AzlBiosSetting -Infrastructure $infra -Node $infra.nodes[0] -Phase DuringProvisioning
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [System.Collections.IDictionary]$Node,
        [ValidateSet('Final', 'DuringProvisioning')][string]$Phase = 'Final'
    )
    $merged = [ordered]@{}
    Merge-BiosSource $merged @((Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'hardware.bios'))
    if ($Node) { Merge-BiosSource $merged @($Node['bios']) }
    if ($Phase -eq 'DuringProvisioning') {
        Merge-BiosSource $merged @((Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'hardware.bios_during_provisioning'))
        if ($Node) { Merge-BiosSource $merged @($Node['bios_during_provisioning']) }
    }
    return $merged
}

function Get-AzlBiosProvisioningOverride {
    <#
    .SYNOPSIS
        The BIOS keys that hold for the OS install only (schema 5.3): hardware.bios_during_provisioning with the node's
        bios_during_provisioning merged over it, each with the value to set back in the Restore stage.
    .OUTPUTS
        Name, ProvisioningValue (the temporary value), FinalValue (the bios value, or $null when bios doesn't name the key:
        then Restore uses the original value it saved at Boot).
    .EXAMPLE
        Get-AzlBiosProvisioningOverride -Infrastructure $infra -Node $infra.nodes[0]
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [System.Collections.IDictionary]$Node)
    $temporary = [ordered]@{}
    Merge-BiosSource $temporary @((Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'hardware.bios_during_provisioning'))
    if ($Node) { Merge-BiosSource $temporary @($Node['bios_during_provisioning']) }
    $final = Get-AzlBiosSetting -Infrastructure $Infrastructure -Node $Node
    foreach ($k in $temporary.Keys) {
        [pscustomobject]@{ Name = $k; ProvisioningValue = $temporary[$k]; FinalValue = $(if ($final.Contains($k)) { $final[$k] } else { $null }) }
    }
}

function Get-AzlInfrastructureScope {
    <#
    .SYNOPSIS
        The scope of the file (schema 5.3): full (the default, the whole instance) or ztp (only what azurelocal-ztp reads).
    .EXAMPLE
        Get-AzlInfrastructureScope -Infrastructure $infra
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure)
    $scope = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path '_metadata.scope'
    if ($scope -is [string] -and $scope) { return $scope.ToLowerInvariant() }
    return 'full'
}

function Test-AzlProvisioningDhcpPort {
    <#
    .SYNOPSIS
        True when the node has a port with role provisioning, other than the management port, whose ip_assignment gives it
        DHCP (dhcp or dhcp_reservation): the maintenance environment's way to Azure when the management network has none.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    foreach ($p in @(Get-AzlNodeNetworkAdapter -Infrastructure $Infrastructure -Node $Node)) {
        $roles = @(Get-List $p['roles'])
        if ('provisioning' -in $roles -and 'management' -notin $roles -and [string]$p['ip_assignment'] -in 'dhcp', 'dhcp_reservation') { return $true }
    }
    return $false
}

function Get-AzlManagementMode {
    <#
    .SYNOPSIS
        A node's management address mode, by the names the docs use (config/variables/docs/infrastructure-file.md, "Management address
        modes"): A Reserved, B Static with DHCP, C Static without management DHCP.
    .DESCRIPTION
        From the ip_assignment of the management port (the port with role management that owns the address, found by its
        MAC; any make or slot) and whether that port takes DHCP while the machine is provisioned (ManagementDhcp):
        networking.management.provisioning_network is dhcp (the default) and the management port also has role provisioning,
        or the node has no network_adapters (its one management port is the maintenance environment's way to Azure).
          A  Reserved                         dhcp_reservation.
          B  Static with DHCP                 static, ManagementDhcp.
          C  Static without management DHCP   static, no ManagementDhcp: another port with role provisioning reaches Azure.
        dhcp (no reservation) and preconfigured are none of the three: Mode is '' and Label says what they are. $null when
        the node has no single management port.
    .OUTPUTS
        Mode, Name, IpAssignment, ManagementDhcp, Label (for example 'Mode B (Static with DHCP)').
    .EXAMPLE
        Get-AzlManagementMode -Infrastructure $infra -Node $infra.nodes[0]
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    $owner = Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $Node
    if (-not $owner) { return $null }
    $network = [string](Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'networking.management.provisioning_network')
    $dhcp = $network -ne 'static'
    if ($dhcp -and $owner.Source -eq 'network_adapters') {
        $raw = @(Get-AzlNodeNetworkAdapter -Infrastructure $Infrastructure -Node $Node | Where-Object { Test-IsManagementOwner $_ }) | Select-Object -First 1
        $dhcp = 'provisioning' -in @(Get-List $raw['roles'])
    }
    $mode, $name = switch ($owner.IpAssignment) {
        'dhcp_reservation' { 'A', 'Reserved' }
        'static' { if ($dhcp) { 'B', 'Static with DHCP' } else { 'C', 'Static without management DHCP' } }
        'dhcp' { '', 'dhcp without a reservation (not Mode A, B or C)' }
        default { '', [string]$owner.IpAssignment }
    }
    [pscustomobject]@{ Mode = $mode; Name = $name; IpAssignment = $owner.IpAssignment; ManagementDhcp = $dhcp; Label = $(if ($mode) { "Mode $mode ($name)" } else { $name }) }
}

function Get-AzlManagementStaticMethod {
    <#
    .SYNOPSIS
        Who sets the static management address with simplified provisioning (schema 5.3): device (the default) or site.
    .DESCRIPTION
        device: azurelocal-ztp's Device stage sets the address on the management port, by MAC, through the maintenance
        environment's Configurator service before the claim; the Arc site's network setting is Automatic. site: the site is
        Manual with an address range and Microsoft's OS install assigns the address (to the first ready port, not the MAC).
        Only matters when the management ip_assignment is static.
    .EXAMPLE
        Get-AzlManagementStaticMethod -Infrastructure $infra
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure)
    $method = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'networking.management.static_method'
    if ($method -is [string] -and $method) { return $method.ToLowerInvariant() }
    return 'device'
}
function Get-AzlSiteIpRange {
    <#
    .SYNOPSIS
        The management address range of the simplified-provisioning site (schema 5.2): networking.management.site_ip_range,
        else the lowest to the highest static management address. $null when no node's management address is static.
    .OUTPUTS
        Start, End, Source (site_ip_range or derived).
    .EXAMPLE
        Get-AzlSiteIpRange -Infrastructure $infra
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure)
    $range = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'networking.management.site_ip_range'
    if ($range -is [System.Collections.IDictionary] -and (Test-IsIPv4 $range['start']) -and (Test-IsIPv4 $range['end'])) {
        return [pscustomobject]@{ Start = [string]$range['start']; End = [string]$range['end']; Source = 'site_ip_range' }
    }
    $static = @(Get-List $Infrastructure['nodes'] | Where-Object { $_ -is [System.Collections.IDictionary] } |
            ForEach-Object { Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $_ } |
            Where-Object { $_ -and $_.IpAssignment -eq 'static' -and (Test-IsIPv4 $_.IpAddress) } | ForEach-Object IpAddress)
    if ($static.Count -eq 0) { return $null }
    $sorted = @($static | Sort-Object { ConvertTo-UInt32Address $_ })
    return [pscustomobject]@{ Start = $sorted[0]; End = $sorted[-1]; Source = 'derived' }
}

function Get-AzlArcMachineName {
    <#
    .SYNOPSIS
        The name of a node's Arc machine: arc_machine_name, else the deprecated arc_resource_name, else the node name.
    .EXAMPLE
        $infra.nodes | ForEach-Object { Get-AzlArcMachineName -Node $_ }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    foreach ($key in 'arc_machine_name', 'arc_resource_name', 'name') {
        if ($Node.Contains($key) -and $Node[$key] -is [string] -and $Node[$key]) { return $Node[$key] }
    }
    return $null
}

function ConvertTo-UInt32Address([string]$Address) {
    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    return [uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + [uint64]$bytes[3]
}

function Get-SubnetRange([string]$Cidr) {
    $address, $bits = $Cidr.Split('/')
    # Unsigned arithmetic only: a 0xFFFFFFFF literal is Int32 -1 in PowerShell.
    $size = [uint64]1 -shl (32 - [int]$bits)
    $value = [uint64](ConvertTo-UInt32Address $address)
    $network = $value - ($value % $size)
    [pscustomobject]@{ First = [uint64]$network; Last = [uint64]($network + $size - 1) }
}

function Test-AddressInSubnet([string]$Address, [string]$Cidr) {
    $range = Get-SubnetRange $Cidr
    $value = [uint64](ConvertTo-UInt32Address $Address)
    return ($value -ge $range.First -and $value -le $range.Last)
}

function Test-IsIPv4([object]$Value) {
    return ($Value -is [string] -and $Value -match '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$')
}

function Test-IsCidr([object]$Value) {
    return ($Value -is [string] -and $Value -match '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)/([0-9]|[12][0-9]|3[0-2])$')
}

function Get-List([object]$Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IList]) { return @($Value) }
    return @($Value)
}

# AA:BB:CC:DD:EE:FF, whatever notation the file used.
function ConvertTo-AzlMac([object]$Mac) {
    if ($Mac -is [string] -and $Mac) { return $Mac.ToUpperInvariant().Replace('-', ':') }
    return $null
}

# 24 -> 255.255.255.0. Unsigned arithmetic only, as in Get-SubnetRange.
function ConvertTo-SubnetMask([int]$PrefixLength) {
    $all = [uint64]4294967295
    $bits = if ($PrefixLength -le 0) { [uint64]0 } else { ([uint64]($all -shl (32 - $PrefixLength))) -band $all }
    return (3, 2, 1, 0 | ForEach-Object { ($bits -shr (8 * $_)) -band 0xFF }) -join '.'
}

# The port that owns the management address: role management and an ip_assignment that gives it one.
function Test-IsManagementOwner([object]$Adapter) {
    return ($Adapter -is [System.Collections.IDictionary] -and 'management' -in @(Get-List $Adapter['roles']) -and [string]$Adapter['ip_assignment'] -in $script:AddressModes)
}

# The VLAN the host tags on a port: 0 on an access port; else vlan_id; else the default given.
function Get-HostVlan([System.Collections.IDictionary]$Adapter, [object]$Default) {
    if ([string]$Adapter['vlan_mode'] -eq 'access') { return 0 }
    if ($null -ne $Adapter['vlan_id']) { return [int]$Adapter['vlan_id'] }
    return $Default
}

# Every string value in the file with its path, for the Key Vault reference check.
function Get-StringLeaf([object]$Node, [string]$Path) {
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) { Get-StringLeaf $Node[$key] $(if ($Path) { "$Path.$key" } else { "$key" }) }
    } elseif ($Node -is [System.Collections.IList] -and $Node -isnot [string]) {
        for ($i = 0; $i -lt $Node.Count; $i++) { Get-StringLeaf $Node[$i] "$Path[$i]" }
    } elseif ($Node -is [string]) {
        [pscustomobject]@{ Path = $Path; Value = $Node }
    }
}

function Read-InfrastructureFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Infrastructure file not found: $Path" }
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw 'The powershell-yaml module is required: Install-Module powershell-yaml -Scope CurrentUser'
    }
    Import-Module powershell-yaml -ErrorAction Stop
    $text = Get-Content -LiteralPath $Path -Raw
    $data = ConvertFrom-Yaml -Yaml $text -Ordered
    if ($data -isnot [System.Collections.IDictionary]) { throw "The infrastructure file must be a YAML mapping: $Path" }
    return $data
}

# ---------------------------------------------------------------------------------------------------------------------
# Schema check
# ---------------------------------------------------------------------------------------------------------------------

# Test-Json reports only top-level errors, so the schema is evaluated with JsonSchema.Net (shipped with PowerShell 7.4+)
# in list output, which returns every node. An error counts only when every schema node above it failed too: that drops
# the expected failures inside if conditions, not, and the anyOf alternatives that didn't need to match.
function Get-SchemaFinding {
    param([string]$Json, [string]$SchemaText)
    if (-not ('Json.Schema.JsonSchema' -as [type])) { '{}' | Test-Json -Schema '{}' | Out-Null }
    $schema = [Json.Schema.JsonSchema]::FromText($SchemaText)
    $options = [Json.Schema.EvaluationOptions]::new()
    $options.OutputFormat = [Json.Schema.OutputFormat]::List
    $result = $schema.Evaluate([System.Text.Json.Nodes.JsonNode]::Parse($Json), $options)
    if ($result.IsValid) { return }

    # A schema node is identified by its evaluation path and the instance location it was applied to: every item of an
    # array is evaluated by the same schema path, so the path alone would let one valid node hide the errors of another.
    $prefixes = {
        param([string]$Pointer)
        $parts = $Pointer.Split('/')
        for ($i = 1; $i -le $parts.Count; $i++) { $parts[0..($i - 1)] -join '/' }
    }
    $validity = @{}
    # ToString() explicitly: a JsonPointer is enumerable, so string interpolation would join its segments.
    foreach ($d in $result.Details) { $validity[$d.EvaluationPath.ToString() + '|' + $d.InstanceLocation.ToString()] = $d.IsValid }
    # Every (schema node, instance) pair that has a failed node somewhere below it.
    $invalidBelow = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($d in $result.Details) {
        if ($d.IsValid) { continue }
        $own = $d.EvaluationPath.ToString()
        $instPrefixes = @(& $prefixes $d.InstanceLocation.ToString())
        foreach ($e in @(& $prefixes $own)) {
            if ($e -eq $own) { continue }
            foreach ($p in $instPrefixes) { [void]$invalidBelow.Add("$e|$p") }
        }
    }
    # anyOf branches that passed, by the branch's parent and instance: a failed sibling branch is then not an error.
    $passedBranch = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($d in $result.Details) {
        if ($d.IsValid -and $d.EvaluationPath.ToString() -match '^(.*)/anyOf/\d+$') { [void]$passedBranch.Add("$($Matches[1])|$($d.InstanceLocation.ToString())") }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($d in $result.Details) {
        $evalPath = $d.EvaluationPath.ToString()
        $instance = $d.InstanceLocation.ToString()
        # Inside a contains or an if, items and conditions are expected to fail: the contains keyword reports on the
        # array itself, and a failed if only means its then doesn't apply.
        if ($evalPath -match '/(contains|if)(/|$)') { continue }
        $branchMasked = $false
        foreach ($m in [regex]::Matches($evalPath, '/anyOf/\d+')) {
            $parent = $evalPath.Substring(0, $m.Index)
            foreach ($p in @(& $prefixes $instance)) { if ($passedBranch.Contains("$parent|$p")) { $branchMasked = $true; break } }
            if ($branchMasked) { break }
        }
        if ($branchMasked) { continue }
        # A failed node with no message of its own (for example a failing not) counts when no node below it failed.
        $silentFailure = (-not $d.IsValid) -and (-not $d.HasErrors) -and -not $invalidBelow.Contains("$evalPath|$instance")
        if (-not $d.HasErrors -and -not $silentFailure) { continue }
        # Masked when a schema node above it, applied to this value or one that contains it, passed.
        $masked = $false
        $instPrefixes = @(& $prefixes $instance)
        foreach ($e in @(& $prefixes $evalPath)) {
            if ($e -eq $evalPath) { break }
            foreach ($p in $instPrefixes) {
                $key = "$e|$p"
                if ($validity.ContainsKey($key) -and $validity[$key]) { $masked = $true; break }
            }
            if ($masked) { break }
        }
        if ($masked) { continue }
        $at = ($d.InstanceLocation.ToString().TrimStart('/') -replace '/(\d+)(?=/|$)', '[$1]' -replace '/', '.')
        if ($silentFailure) {
            if ($seen.Add("$at|not")) { New-Finding 'SCHEMA' error $at "This value isn't allowed here; see the key's description in infrastructure.schema.json." }
            continue
        }
        foreach ($keyword in $d.Errors.Keys) {
            $message = switch ($keyword) {
                '' { 'Unknown key. Check the spelling, or put it under extensions.' }
                'required' { $d.Errors[$keyword] -replace '^Required properties \[(.*)\] are not present$', 'Missing required key(s): $1' -replace '"', '' }
                { $_ -in 'contains', 'minContains', 'maxContains' } { "$($d.Errors[$keyword]) ($keyword). See the key's description in infrastructure.schema.json for what the list must hold." }
                default { "$($d.Errors[$keyword]) ($keyword)" }
            }
            if ($seen.Add("$at|$message")) { New-Finding 'SCHEMA' error $at $message }
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Checks a JSON schema can't express
# ---------------------------------------------------------------------------------------------------------------------

function Get-SemanticFinding {
    param([System.Collections.IDictionary]$Infra)

    $v = { param($p) Get-AzlInfrastructureValue -Infrastructure $Infra -Path $p }
    $scenario = & $v 'scenario'
    if ($scenario -isnot [System.Collections.IDictionary]) { return }
    $nodes = @(Get-List (& $v 'nodes') | Where-Object { $_ -is [System.Collections.IDictionary] })
    $nodeCount = $nodes.Count
    $storageArch = $scenario['storage_architecture']
    $usesS2d = $storageArch -in @('s2d', 'hybrid')

    # Key Vault references name a listed vault.
    $vaults = @(Get-List (& $v 'key_vaults') | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_['name'] } })
    foreach ($leaf in (Get-StringLeaf $Infra '')) {
        if ($leaf.Value -match '^keyvault://([^/]+)/') {
            if ($Matches[1] -notin $vaults) {
                New-Finding 'AZL-001' error $leaf.Path "References vault '$($Matches[1])', which isn't listed in key_vaults."
            }
        }
    }

    # Node names and management addresses are unique.
    foreach ($group in ($nodes | Group-Object { $_['name'] } | Where-Object Count -gt 1)) {
        New-Finding 'AZL-002' error 'nodes' "Node name '$($group.Name)' is used $($group.Count) times."
    }
    # Each node's management port: nodes[].management, or from 5.2 the network_adapters port that owns the address.
    $owners = @(foreach ($n in $nodes) { Get-AzlManagementAdapter -Infrastructure $Infra -Node $n })
    $ownerOf = @{}
    for ($i = 0; $i -lt $nodeCount; $i++) { $ownerOf[$i] = Get-AzlManagementAdapter -Infrastructure $Infra -Node $nodes[$i] }
    $nodeIps = @($owners | Where-Object { $_ -and (Test-IsIPv4 $_.IpAddress) } | ForEach-Object IpAddress)
    foreach ($group in ($nodeIps | Group-Object | Where-Object Count -gt 1)) {
        New-Finding 'AZL-003' error 'nodes' "Management address $($group.Name) is used by $($group.Count) nodes."
    }

    # Management network: node addresses and the gateway inside the subnet, and the infrastructure pool.
    $mgmt = & $v 'networking.management'
    if ($mgmt -is [System.Collections.IDictionary] -and (Test-IsCidr $mgmt['subnet'])) {
        $subnet = $mgmt['subnet']
        for ($i = 0; $i -lt $nodeCount; $i++) {
            $o = $ownerOf[$i]
            $ip = if ($o) { $o.IpAddress }
            if ((Test-IsIPv4 $ip) -and -not (Test-AddressInSubnet $ip $subnet)) {
                New-Finding 'AZL-004' error "$($o.Path).ip_address" "$ip isn't in the management subnet $subnet. Node addresses must be on the same subnet as the infrastructure pool." $script:Learn.Decision8
            }
        }
        if ((Test-IsIPv4 $mgmt['gateway']) -and -not (Test-AddressInSubnet $mgmt['gateway'] $subnet)) {
            New-Finding 'AZL-004' error 'networking.management.gateway' "The gateway $($mgmt['gateway']) isn't in the management subnet $subnet." $script:Learn.Decision8
        }
        $pool = $mgmt['infrastructure_pool']
        if ($pool -is [System.Collections.IDictionary] -and (Test-IsIPv4 $pool['start']) -and (Test-IsIPv4 $pool['end'])) {
            $start = ConvertTo-UInt32Address $pool['start']
            $end = ConvertTo-UInt32Address $pool['end']
            if ($start -gt $end) {
                New-Finding 'AZL-005' error 'networking.management.infrastructure_pool' "The pool starts at $($pool['start']), after its end $($pool['end'])." $script:Learn.Decision8
            } else {
                if (-not ((Test-AddressInSubnet $pool['start'] $subnet) -and (Test-AddressInSubnet $pool['end'] $subnet))) {
                    New-Finding 'AZL-005' error 'networking.management.infrastructure_pool' "The pool $($pool['start'])-$($pool['end']) isn't inside the management subnet $subnet." $script:Learn.Decision8
                }
                if (($end - $start + 1) -lt 6) {
                    New-Finding 'AZL-005' error 'networking.management.infrastructure_pool' "The pool has $($end - $start + 1) addresses; Azure Local needs at least six consecutive addresses." $script:Learn.Decision8
                }
                $inPool = @($nodeIps + @($mgmt['gateway']) | Where-Object { (Test-IsIPv4 $_) -and ((ConvertTo-UInt32Address $_) -ge $start) -and ((ConvertTo-UInt32Address $_) -le $end) })
                foreach ($ip in $inPool) {
                    New-Finding 'AZL-005' error 'networking.management.infrastructure_pool' "The pool includes $ip, which is a node or gateway address. The pool must not include node addresses." $script:Learn.Decision8
                }
            }
        }
    }

    # Reserved Arc resource bridge and AKS ranges.
    $checked = [System.Collections.Generic.List[object]]::new()
    foreach ($ip in $nodeIps) { $checked.Add(@('nodes[].management.ip_address', $ip)) }
    if ($mgmt -is [System.Collections.IDictionary]) {
        if (Test-IsIPv4 $mgmt['gateway']) { $checked.Add(@('networking.management.gateway', $mgmt['gateway'])) }
        foreach ($dns in (Get-List $mgmt['dns_servers'])) { if (Test-IsIPv4 $dns) { $checked.Add(@('networking.management.dns_servers', $dns)) } }
        if ($mgmt['infrastructure_pool'] -is [System.Collections.IDictionary]) {
            foreach ($k in 'start', 'end') { if (Test-IsIPv4 $mgmt['infrastructure_pool'][$k]) { $checked.Add(@("networking.management.infrastructure_pool.$k", $mgmt['infrastructure_pool'][$k])) } }
        }
    }
    foreach ($lnet in (Get-List (& $v 'networking.logical_networks'))) {
        if ($lnet -is [System.Collections.IDictionary] -and (Test-IsCidr $lnet['address_prefix'])) { $checked.Add(@('networking.logical_networks[].address_prefix', ($lnet['address_prefix'].Split('/')[0]))) }
    }
    foreach ($item in $checked) {
        if ((Test-AddressInSubnet $item[1] '10.244.0.0/16') -or (Test-AddressInSubnet $item[1] '10.96.0.0/24')) {
            New-Finding 'AZL-006' error $item[0] "$($item[1]) is in a range the Arc resource bridge reserves (10.244.0.0/16, 10.96.0.0/24)." "$($script:Learn.Decision8)"
        } elseif (Test-AddressInSubnet $item[1] '10.96.0.0/12') {
            New-Finding 'AZL-006' warning $item[0] "$($item[1]) is in 10.96.0.0/12, which AKS on Azure Local and deployments created before 2610 reserve." "$($script:Learn.Decision8)"
        }
    }

    # Public DNS servers aren't supported.
    foreach ($dns in (Get-List (Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'networking.management.dns_servers'))) {
        if ($dns -in @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220')) {
            New-Finding 'AZL-014' error 'networking.management.dns_servers' "$dns is a public DNS server. The DNS servers must resolve the on-premises domains; public DNS servers aren't supported." $script:Learn.Decision8
        }
    }

    # Node counts per architecture and storage connectivity.
    if ($usesS2d -and $nodeCount -gt 16) {
        New-Finding 'AZL-007' error 'nodes' "$nodeCount nodes: a cluster with Storage Spaces Direct supports up to 16." $script:Learn.Decision4
    }
    if ($scenario['storage_connectivity'] -eq 'switchless' -and $nodeCount -gt 4) {
        New-Finding 'AZL-007' error 'nodes' "$nodeCount nodes: switchless storage supports 1 to 4 machines." $script:Learn.Topologies
    }
    if ($scenario['topology'] -eq 'rack_aware') {
        $perZoneMax = if ($usesS2d) { 4 } else { 8 }
        $zones = @($nodes | Group-Object { $_['zone'] })
        if ($zones.Count -ne 2) {
            New-Finding 'AZL-007' error 'nodes[].zone' "A rack aware cluster has exactly two local availability zones; this file has $($zones.Count)." $script:Learn.RackAware
        } elseif ($zones[0].Count -ne $zones[1].Count) {
            New-Finding 'AZL-007' error 'nodes[].zone' "The two zones must hold the same number of machines ($($zones[0].Name): $($zones[0].Count), $($zones[1].Name): $($zones[1].Count))." $script:Learn.RackAware
        } elseif ($zones[0].Count -gt $perZoneMax) {
            New-Finding 'AZL-007' error 'nodes[].zone' "$($zones[0].Count) machines per zone: the maximum is $perZoneMax." $script:Learn.RackAware
        }
        foreach ($vol in (Get-List (& $v 'storage.volumes'))) {
            if ($vol -is [System.Collections.IDictionary] -and $vol['resiliency'] -eq 'three_way') {
                New-Finding 'AZL-012' error 'storage.volumes' "Volume '$($vol['name'])': a rack aware cluster supports two-way or four-way mirror volumes, not three-way." $script:Learn.RackAware
            }
        }
    }

    # Witness.
    $witness = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'cluster.witness.type'
    if ($witness -eq 'none' -and ($nodeCount -eq 2 -or $scenario['topology'] -eq 'rack_aware')) {
        New-Finding 'AZL-008' error 'cluster.witness.type' 'A two-machine or rack aware cluster needs a witness.' $script:Learn.Quorum
    }
    if ($witness -eq 'file_share' -and $scenario['connectivity'] -eq 'connected') {
        New-Finding 'AZL-008' error 'cluster.witness.type' 'A connected deployment uses a cloud witness. A file share witness is for disconnected operations.' $script:Learn.Arm
    }
    if ($witness -eq 'cloud' -and $scenario['connectivity'] -eq 'disconnected') {
        New-Finding 'AZL-008' error 'cluster.witness.type' 'Disconnected operations use a file share witness, not a cloud witness.' $script:Learn.Arm
    }

    # Intents.
    $intents = @(Get-List (& $v 'networking.intents') | Where-Object { $_ -is [System.Collections.IDictionary] })
    if ($intents.Count -gt 0) {
        $mgmtIntents = @($intents | Where-Object { 'management' -in (Get-List $_['traffic']) })
        if ($mgmtIntents.Count -ne 1) {
            New-Finding 'AZL-009' error 'networking.intents' "Exactly one intent carries management traffic; this file has $($mgmtIntents.Count)." $script:Learn.Intents
        }
        $storageIntents = @($intents | Where-Object { 'storage' -in (Get-List $_['traffic']) })
        if ($usesS2d -and $nodeCount -gt 1 -and $storageIntents.Count -eq 0) {
            New-Finding 'AZL-009' error 'networking.intents' 'A multi-machine Storage Spaces Direct cluster needs an intent with storage traffic.' $script:Learn.Intents
        }
        if ($scenario['storage_connectivity'] -eq 'switchless') {
            foreach ($si in $storageIntents) {
                if (@(Get-List $si['traffic']).Count -gt 1) {
                    New-Finding 'AZL-009' error 'networking.intents' "Intent '$($si['name'])': switchless storage needs storage in its own intent, apart from management and compute." $script:Learn.Intents
                }
            }
        }
        foreach ($group in ($intents | ForEach-Object { Get-List $_['adapters'] } | Group-Object | Where-Object Count -gt 1)) {
            New-Finding 'AZL-009' error 'networking.intents' "Adapter '$($group.Name)' is in more than one intent." $script:Learn.Intents
        }
        foreach ($group in ($intents | Group-Object { $_['name'] } | Where-Object Count -gt 1)) {
            New-Finding 'AZL-009' error 'networking.intents' "Intent name '$($group.Name)' is used more than once."
        }

        # Adapters exist on the cards, when the cards are described.
        $ports = @(Get-List (& $v 'hardware.network_cards') | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { Get-List $_['ports'] } } | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_['name'] } })
        if ($ports.Count -gt 0) {
            foreach ($adapter in ($intents | ForEach-Object { Get-List $_['adapters'] })) {
                if ($adapter -notin $ports) {
                    New-Finding 'AZL-011' error 'networking.intents' "Adapter '$adapter' isn't a port in hardware.network_cards."
                }
            }
        }

        # Storage networks sit on storage-intent adapters; custom storage addresses are complete.
        $storageAdapters = @($storageIntents | ForEach-Object { Get-List $_['adapters'] })
        $storageNets = @(Get-List (& $v 'networking.storage.networks') | Where-Object { $_ -is [System.Collections.IDictionary] })
        foreach ($net in $storageNets) {
            if ($net['adapter'] -notin $storageAdapters) {
                New-Finding 'AZL-010' error 'networking.storage.networks' "Storage network '$($net['name'])' uses adapter '$($net['adapter'])', which isn't in an intent with storage traffic."
            }
        }
        if ((Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'networking.storage.auto_ip') -eq $false) {
            foreach ($net in $storageNets) {
                if (-not $net.Contains('subnet')) { New-Finding 'AZL-010' error 'networking.storage.networks' "Storage network '$($net['name'])' needs a subnet when auto_ip is false." $script:Learn.CustomIp }
            }
            for ($i = 0; $i -lt $nodeCount; $i++) {
                $count = @(Get-List $nodes[$i]['storage_ips']).Count
                if ($count -ne $storageNets.Count) {
                    New-Finding 'AZL-010' error "nodes[$i].storage_ips" "Node '$($nodes[$i]['name'])' lists $count storage addresses; auto_ip is false, so it needs one per storage network ($($storageNets.Count))." $script:Learn.CustomIp
                }
            }
        }
    }

    # Provisioning.
    $osVersion = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'provisioning.os_version'
    if ($osVersion -in @('latest', 'latest-preview')) {
        New-Finding 'AZL-013' warning 'provisioning.os_version' "os_version is '$osVersion'. Pin a version so every run installs the same OS and the SBE can be checked against it."
    }
    if ((Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'hardware.sbe.allow_unvalidated') -eq $true) {
        New-Finding 'AZL-013' warning 'hardware.sbe.allow_unvalidated' 'allow_unvalidated is true: the SBE is used even though the OEM has not validated it with os_version. Test only.'
    }
    # Arc gateway (and the private path, which uses it): not with simplified provisioning, and only in the public cloud.
    if ($scenario['outbound_path'] -in @('arc_gateway', 'proxy_arc_gateway', 'private_path')) {
        if ($scenario['os_install'] -eq 'simplified') {
            New-Finding 'AZL-016' error 'scenario.outbound_path' "Arc gateway isn't supported with simplified machine provisioning; use direct or proxy." $script:Learn.Simplified
        }
        if ($scenario['cloud'] -eq 'government') {
            New-Finding 'AZL-016' error 'scenario.outbound_path' 'Arc gateway is available only in the Azure public cloud.' 'https://learn.microsoft.com/azure/azure-arc/servers/arc-gateway#current-limitations'
        }
    }
    if ($scenario['os_install'] -eq 'simplified') {
        $defaultBmc = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'hardware.bmc'
        for ($i = 0; $i -lt $nodeCount; $i++) {
            $bmc = $nodes[$i]['bmc']
            $own = $bmc -is [System.Collections.IDictionary] -and $bmc.Contains('password')
            if (-not $own -and $defaultBmc -isnot [System.Collections.IDictionary]) {
                New-Finding 'AZL-015' error "nodes[$i].bmc" "Node '$($nodes[$i]['name'])' has no BMC login: set nodes[].bmc.username and password, or hardware.bmc. Simplified provisioning mounts the image through the BMC." $script:Learn.Simplified
            }
        }
        if (-not (Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'hardware.sbe.bundle_path')) {
            New-Finding 'AZL-015' error 'hardware.sbe.bundle_path' 'Simplified provisioning prepares each machine with the OEM SBE before Validate: set the folder holding the SBE files.'
        }
    }
    if ($scenario['os_install'] -eq 'simplified' -and (Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'azure.location') -ne 'eastus') {
        New-Finding 'AZL-013' warning 'azure.location' 'Simplified machine provisioning works only in eastus in the preview.' $script:Learn.Simplified
    }

    # The management port: each MAC names one machine's port, and with DHCP each address needs a reservation.
    # (With simplified provisioning the schema already requires management.mac_address on every node, in every mode.)
    # (Nodes described with network_adapters: every port's MAC is checked by AZL-019 instead.)
    $macs = @(for ($i = 0; $i -lt $nodeCount; $i++) {
            if ($nodes[$i].Contains('network_adapters')) { continue }
            $m = $nodes[$i]['management']
            if ($m -is [System.Collections.IDictionary] -and $m['mac_address'] -is [string]) { ConvertTo-AzlMac $m['mac_address'] }
        })
    foreach ($group in ($macs | Group-Object | Where-Object Count -gt 1)) {
        New-Finding 'AZL-017' error 'nodes' "Management MAC $($group.Name) is used by $($group.Count) nodes. Each node's management.mac_address names its own management port."
    }
    for ($i = 0; $i -lt $nodeCount; $i++) {
        $o = $ownerOf[$i]
        if (-not $o -or $o.IpAssignment -ne 'dhcp_reservation' -or -not $o.IpAddress) { continue }
        $mode = if ($o.Source -eq 'management') { 'ip_assignment is dhcp' } else { 'the management port is dhcp_reservation' }
        $for = if ($o.MacAddress) { "MAC $($o.MacAddress)" } else { 'its management MAC (set management.mac_address)' }
        New-Finding 'AZL-017' warning $o.Path "Node '$($nodes[$i]['name'])': $mode (Mode A, Reserved), so the port keeps DHCP. Reserve $($o.IpAddress) in DHCP for $for, or the machine gets another address." $script:Learn.Decision8
    }

    Get-AdapterFinding -Infra $Infra -Nodes $nodes -OwnerOf $ownerOf -Intents @(Get-List (& $v 'networking.intents') | Where-Object { $_ -is [System.Collections.IDictionary] })
    Get-BiosPhaseFinding -Infra $Infra -Nodes $nodes
    Get-ProvisioningNetworkFinding -Infra $Infra -Nodes $nodes -OwnerOf $ownerOf
    Get-SanFinding -Infra $Infra -Nodes $nodes
    Get-ZtpActionFinding -Infra $Infra -Nodes $nodes
    Get-SbeDeliveryFinding -Infra $Infra -Nodes $nodes -OwnerOf $ownerOf
    Get-OsConfigurationFinding -Infra $Infra
    Get-DeploymentOptionFinding -Infra $Infra
    Get-CicdFinding -Infra $Infra
    Get-DomainJoinFinding -Infra $Infra -Nodes $nodes # AZL-050 to AZL-053 (domain join, schema 5.5)
    # HOOK remoting-profiles (schema 5.6): AZL-060 to AZL-068, the environment class and os_configuration.remoting.
    Get-AzlRemotingFinding -Infrastructure $Infra

    # Arc machine names: unique, and arc_machine_name rather than the deprecated arc_resource_name.
    for ($i = 0; $i -lt $nodeCount; $i++) {
        $n = $nodes[$i]
        if (-not $n.Contains('arc_resource_name')) { continue }
        if ($n.Contains('arc_machine_name') -and [string]$n['arc_machine_name'] -ne [string]$n['arc_resource_name']) {
            New-Finding 'AZL-018' error "nodes[$i].arc_resource_name" "Node '$($n['name'])' sets arc_machine_name '$($n['arc_machine_name'])' and arc_resource_name '$($n['arc_resource_name'])'. Keep arc_machine_name only."
        } else {
            New-Finding 'AZL-018' warning "nodes[$i].arc_resource_name" "arc_resource_name is deprecated: rename it to arc_machine_name."
        }
    }
    $arcNames = @($nodes | ForEach-Object { Get-AzlArcMachineName -Node $_ } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($group in ($arcNames | Group-Object | Where-Object Count -gt 1)) {
        New-Finding 'AZL-018' error 'nodes' "Arc machine name '$($group.Name)' is used by $($group.Count) nodes. Arc machine names are unique in the resource group."
    }
    if ($scenario['os_install'] -eq 'iso') {
        for ($i = 0; $i -lt $nodeCount; $i++) {
            $n = $nodes[$i]
            if ($n['arc_machine_name'] -and [string]$n['arc_machine_name'] -ne [string]$n['name']) {
                New-Finding 'AZL-018' warning "nodes[$i].arc_machine_name" "An ISO install registers the Arc machine under its host name '$($n['name'])'. arc_machine_name '$($n['arc_machine_name'])' applies to simplified provisioning only."
            }
        }
    }
}

# Schema 5.2: the ports of each node (nodes[].network_adapters), checked against each other, the intents and the networks.
function Get-AdapterFinding {
    param([System.Collections.IDictionary]$Infra, [object[]]$Nodes, [hashtable]$OwnerOf, [object[]]$Intents)
    $v = { param($p) Get-AzlInfrastructureValue -Infrastructure $Infra -Path $p }
    $listed = @(for ($i = 0; $i -lt $Nodes.Count; $i++) { if ($Nodes[$i].Contains('network_adapters')) { $i } })
    $mgmt = & $v 'networking.management'
    if ($mgmt -isnot [System.Collections.IDictionary]) { $mgmt = @{} }
    $subnet = if (Test-IsCidr $mgmt['subnet']) { [string]$mgmt['subnet'] } else { $null }
    $simplified = (& $v 'scenario.os_install') -eq 'simplified'

    # The site range applies with or without network_adapters.
    Get-SiteRangeFinding -Infra $Infra -Nodes $Nodes -OwnerOf $OwnerOf -Subnet $subnet -Simplified $simplified
    # AZL-024: provisioning_network static means no DHCP on the provisioning network. A static management port (Mode C,
    # Static without management DHCP) then needs another port with role provisioning on DHCP, or the maintenance
    # environment never reaches Azure (G23): an error, so validation stops before the hardware is touched.
    if ($simplified -and [string]$mgmt['provisioning_network'] -eq 'static') {
        $unresearched = $false
        for ($i = 0; $i -lt $Nodes.Count; $i++) {
            if (Test-AzlProvisioningDhcpPort -Infrastructure $Infra -Node $Nodes[$i]) { continue }
            $o = $OwnerOf[$i]
            if ($o -and $o.IpAssignment -eq 'static') {
                $at = if ($Nodes[$i].Contains('network_adapters')) { "nodes[$i].network_adapters" } else { $o.Path }
                New-Finding 'AZL-024' error $at "Node '$($Nodes[$i]['name'])': Mode C (Static without management DHCP): the maintenance environment can't reach Azure: no DHCP anywhere (G23); give a provisioning port with DHCP (a port with role provisioning and ip_assignment dhcp or dhcp_reservation, on a network a DHCP server answers). provisioning_network is static, and azurelocal-ztp can't give the maintenance environment a static address." $script:Learn.Simplified
            }
            else { $unresearched = $true }
        }
        if ($unresearched) {
            New-Finding 'AZL-024' warning 'networking.management.provisioning_network' 'provisioning_network is static: the maintenance environment needs a static address to reach Azure before the machine is claimed. Learn documents only the Configurator app for that; whether the bootable image can carry a preset address is an open research item, so azurelocal-ztp does not set it.' $script:Learn.Simplified
        }
    }
    if ($listed.Count -eq 0) { return }

    # AZL-019: every node or none, unique names on a node, unique MACs in the file.
    if ($listed.Count -ne $Nodes.Count) {
        New-Finding 'AZL-019' error 'nodes' "$($listed.Count) of $($Nodes.Count) nodes list network_adapters. List the ports on every node or on none: tools read one shape for the whole instance."
    }
    $ports = @{}
    $allMacs = [System.Collections.Generic.List[object]]::new()
    foreach ($i in $listed) {
        $ports[$i] = @(Get-AzlNodeNetworkAdapter -Infrastructure $Infra -Node $Nodes[$i])
        foreach ($group in ($ports[$i] | Group-Object { ([string]$_['name']).ToLowerInvariant() } | Where-Object Count -gt 1)) {
            New-Finding 'AZL-019' error "nodes[$i].network_adapters" "Node '$($Nodes[$i]['name'])' has $($group.Count) ports named '$($group.Group[0]['name'])'. Port names are unique on a machine."
        }
        foreach ($p in $ports[$i]) { if ($p['mac_address']) { $allMacs.Add([pscustomobject]@{ Mac = ConvertTo-AzlMac $p['mac_address']; Path = $p['_path'] }) } }
    }
    foreach ($group in ($allMacs | Group-Object Mac | Where-Object Count -gt 1)) {
        New-Finding 'AZL-019' error 'nodes' "MAC $($group.Name) is used by $($group.Count) ports ($(@($group.Group.Path) -join ', ')). Each MAC names one port."
    }

    # AZL-024: with simplified provisioning, every node names the port its maintenance environment reaches Azure through.
    if ($simplified) {
        foreach ($i in $listed) {
            if (-not ($ports[$i] | Where-Object { 'provisioning' -in @(Get-List $_['roles']) })) {
                New-Finding 'AZL-024' error "nodes[$i].network_adapters" "Node '$($Nodes[$i]['name'])' has no port with role provisioning. Simplified provisioning needs the port the maintenance environment reaches Azure through, before the machine is claimed (networking.management.provisioning_network says how it gets its address)." $script:Learn.Simplified
            }
        }
    }

    # AZL-020: the management port.
    $siteMode = $mgmt['ip_assignment']
    $siteDeprecated = $false
    $mgmtIntent = @($Intents | Where-Object { 'management' -in @(Get-List $_['traffic']) }) | Select-Object -First 1
    $useDhcp = $mgmt['use_dhcp'] -eq $true
    foreach ($i in $listed) {
        $n = $Nodes[$i]
        $name = $n['name']
        $count = @($ports[$i] | Where-Object { Test-IsManagementOwner $_ }).Count
        if ($count -ne 1) {
            New-Finding 'AZL-020' error "nodes[$i].network_adapters" "Node '$name': $count ports own the management address. Exactly one port with role management has an ip_assignment other than none; give a second management port (its team partner) ip_assignment none."
            continue
        }
        $o = $OwnerOf[$i]
        $legacy = $n['management']
        if ($legacy -is [System.Collections.IDictionary]) {
            $diff = @()
            if ($legacy['ip_address'] -and [string]$legacy['ip_address'] -ne [string]$o.IpAddress) { $diff += "ip_address $($legacy['ip_address']) vs $($o.IpAddress)" }
            if ($legacy['mac_address'] -and (ConvertTo-AzlMac $legacy['mac_address']) -ne $o.MacAddress) { $diff += "mac_address $($legacy['mac_address']) vs $($o.MacAddress)" }
            if ($legacy['adapter_name'] -and [string]$legacy['adapter_name'] -ne $o.Name) { $diff += "adapter_name '$($legacy['adapter_name'])' vs '$($o.Name)'" }
            if ($diff) { New-Finding 'AZL-020' error "nodes[$i].management" "Node '$name': management disagrees with its management port $($o.Path): $($diff -join '; '). Keep network_adapters only." }
            else { New-Finding 'AZL-020' warning "nodes[$i].management" "Node '$name': management repeats the management port in network_adapters; remove it, network_adapters is read." }
        }
        if ($siteMode -is [string] -and $siteMode) {
            $allowed = switch ($siteMode.ToLowerInvariant()) { 'static' { @('static') } 'dhcp' { @('dhcp_reservation', 'dhcp') } 'preconfigured' { @('preconfigured') } default { @() } }
            if ($o.IpAssignment -notin $allowed) { New-Finding 'AZL-020' error 'networking.management.ip_assignment' "networking.management.ip_assignment is $siteMode, but node '$name''s management port is $($o.IpAssignment). Set each port's ip_assignment and remove the site-wide key." }
            else { $siteDeprecated = $true }
        }
        if ($o.Source -eq 'network_adapters') {
            $raw = $ports[$i] | Where-Object { Test-IsManagementOwner $_ } | Select-Object -First 1
            if ($subnet -and $raw.Contains('prefix_length') -and [int]$raw['prefix_length'] -ne [int]$subnet.Split('/')[1]) {
                New-Finding 'AZL-020' error "$($o.Path).prefix_length" "Node '$name': the management port's prefix_length $($raw['prefix_length']) doesn't match networking.management.subnet $subnet. The instance has one management network." $script:Learn.Decision8
            }
            if ($raw.Contains('gateway') -and $mgmt['gateway'] -and [string]$raw['gateway'] -ne [string]$mgmt['gateway']) {
                New-Finding 'AZL-020' error "$($o.Path).gateway" "Node '$name': the management port's gateway $($raw['gateway']) isn't networking.management.gateway $($mgmt['gateway'])." $script:Learn.Decision8
            }
            if ($raw.Contains('dns_servers') -and (@(Get-List $raw['dns_servers']) -join ',') -ne (@(Get-List $mgmt['dns_servers']) -join ',')) {
                New-Finding 'AZL-020' error "$($o.Path).dns_servers" "Node '$name': the management port's DNS servers aren't networking.management.dns_servers. The deployment sets the same DNS servers on every machine, and they can't change afterwards." $script:Learn.Decision8
            }
        }
        # The deployment needs the address (a file with scope ztp doesn't deploy, so it doesn't need it).
        if (-not $o.IpAddress -and -not $useDhcp -and (Get-AzlInfrastructureScope -Infrastructure $Infra) -ne 'ztp') {
            New-Finding 'AZL-020' error "$($o.Path)" "Node '$name': the management port has no ip_address. The deployment needs each node's management address (ARM physicalNodesSettings[].ipv4Address) unless networking.management.use_dhcp is true." $script:Learn.Arm
        }
        elseif (-not $o.IpAddress -and $o.IpAssignment -eq 'dhcp_reservation') {
            New-Finding 'AZL-020' warning "$($o.Path).ip_address" "Node '$name': Mode A (Reserved) without ip_address: the expected reserved IP can't be verified. azurelocal-ztp and OS configuration can only check that the management port has a DHCP address; give the reserved address in ip_address." $script:Learn.Decision8
        }
        if ($o.IpAssignment -eq 'dhcp') {
            New-Finding 'AZL-020' warning "$($o.Path).ip_assignment" "Node '$name': the management port is dhcp without a reservation (not Mode A, B or C): the node's management IP can change, and Azure Local needs a stable IP. Use dhcp_reservation (Mode A, recommended) or static (Mode B or C)." $script:Learn.Decision8
        }
        if ($o.Source -eq 'network_adapters' -and $mgmtIntent) {
            $members = @(Get-List $mgmtIntent['adapters'])
            if ($o.Name -notin $members) {
                New-Finding 'AZL-020' error "$($o.Path).name" "Node '$name': the management port '$($o.Name)' isn't in the management intent '$($mgmtIntent['name'])' ($($members -join ', ')). The management address moves to that intent's virtual adapter." $script:Learn.Decision8
            }
            elseif ($members[0] -ne $o.Name) {
                # An error for a static plan too: the management virtual adapter takes the first adapter's MAC, so an address (static or reserved) on any other port of the intent
                # leaves the management adapter without its gateway and DNS (the real failure: an IP on a Compute port, 'Embedded NIC 1 has 0 gateways, 0 DNS').
                $why = if ($o.IpAssignment -in 'dhcp', 'dhcp_reservation') { 'so the DHCP reservation must be for that MAC' } else { 'so the static address, gateway and DNS must be on that port: on any other port of the intent the management adapter comes up with 0 gateways and 0 DNS' }
                New-Finding 'AZL-020' error "$($o.Path).name" "Node '$name': the management port '$($o.Name)' isn't the first adapter of the management intent ('$($members[0])'). The management virtual adapter takes the first adapter's MAC, $why. List '$($o.Name)' first, or move the address to '$($members[0])'." $script:Learn.Decision8
            }
        }
    }
    if ($siteDeprecated) {
        New-Finding 'AZL-020' warning 'networking.management.ip_assignment' 'networking.management.ip_assignment is deprecated in 5.2: each port in nodes[].network_adapters has its own ip_assignment. Remove the site-wide key.'
    }

    # AZL-021: intents and storage networks name ports that exist on every node, with matching roles, symmetric.
    $inIntent = @{}
    foreach ($intent in $Intents) {
        $traffic = @(Get-List $intent['traffic'] | Sort-Object)
        $members = @(Get-List $intent['adapters'])
        foreach ($a in $members) { $inIntent[([string]$a).ToLowerInvariant()] = $intent }
        $shape = @{}
        foreach ($i in $listed) {
            $mine = @()
            foreach ($a in $members) {
                $p = $ports[$i] | Where-Object { ([string]$_['name']) -eq $a } | Select-Object -First 1
                if (-not $p) { New-Finding 'AZL-021' error "nodes[$i].network_adapters" "Intent '$($intent['name'])' uses adapter '$a', which isn't a port of node '$($Nodes[$i]['name'])'. Every adapter of an intent is on every machine, with the same name." $script:Learn.AtcPrereq; continue }
                $mine += $p
                $roles = @(Get-List $p['roles'])
                if ('unused' -in $roles) { New-Finding 'AZL-021' error "$($p['_path']).roles" "Port '$a' of node '$($Nodes[$i]['name'])' is in intent '$($intent['name'])' but its role is unused."; continue }
                $carries = @($roles | Where-Object { $_ -in 'management', 'compute', 'storage' } | Sort-Object)
                if (($carries -join ',') -ne ($traffic -join ',')) {
                    New-Finding 'AZL-021' warning "$($p['_path']).roles" "Port '$a' of node '$($Nodes[$i]['name'])' has roles [$($roles -join ', ')], but its intent '$($intent['name'])' carries [$($traffic -join ', ')]."
                }
                foreach ($k in 'model', 'speed_gbps') {
                    if ($null -ne $p[$k] -and "$($p[$k])" -ne '') {
                        $key = "$a|$k"
                        if ($shape.ContainsKey($key) -and $shape[$key].Value -ne "$($p[$k])") {
                            New-Finding 'AZL-021' error "$($p['_path']).$k" "Port '$a' is $k '$($p[$k])' on node '$($Nodes[$i]['name'])' and '$($shape[$key].Value)' on node '$($shape[$key].Node)'. Intent adapters are symmetric on every machine." $script:Learn.AtcPrereq
                        }
                        elseif (-not $shape.ContainsKey($key)) { $shape[$key] = [pscustomobject]@{ Value = "$($p[$k])"; Node = $Nodes[$i]['name'] } }
                    }
                }
            }
            foreach ($k in 'model', 'speed_gbps') {
                $values = @($mine | Where-Object { $null -ne $_[$k] -and "$($_[$k])" -ne '' } | ForEach-Object { "$($_[$k])" } | Select-Object -Unique)
                if ($values.Count -gt 1) {
                    New-Finding 'AZL-021' error "nodes[$i].network_adapters" "Intent '$($intent['name'])' on node '$($Nodes[$i]['name'])' mixes $k values ($($values -join ', ')). The adapters of one intent are the same make, model and speed." $script:Learn.Symmetry
                }
            }
        }
    }
    $named = @(Get-List (& $v 'networking.storage.networks')) + @(Get-List (& $v 'networking.cluster_networks')) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['adapter'] }
    foreach ($net in $named) {
        foreach ($i in $listed) {
            if (-not ($ports[$i] | Where-Object { [string]$_['name'] -eq [string]$net['adapter'] })) {
                New-Finding 'AZL-021' error "nodes[$i].network_adapters" "Network '$($net['name'])' uses adapter '$($net['adapter'])', which isn't a port of node '$($Nodes[$i]['name'])'."
            }
        }
    }
    foreach ($i in $listed) {
        foreach ($p in $ports[$i]) {
            $traffic = @(Get-List $p['roles'] | Where-Object { $_ -in 'management', 'compute', 'storage' })
            if ($traffic -and (Get-AzlInfrastructureScope -Infrastructure $Infra) -ne 'ztp' -and -not $inIntent.ContainsKey(([string]$p['name']).ToLowerInvariant())) {
                New-Finding 'AZL-021' warning "$($p['_path'])" "Port '$($p['name'])' of node '$($Nodes[$i]['name'])' has roles [$($traffic -join ', ')] but isn't in any intent, so Network ATC doesn't configure it." $script:Learn.Intents
            }
        }
    }

    # AZL-022: addresses on the other ports; AZL-023: VLANs.
    $siteVlan = if ($null -ne $mgmt['vlan_id']) { [int]$mgmt['vlan_id'] } else { 0 }
    $addresses = [System.Collections.Generic.List[object]]::new()
    $storageVlan = @{}
    foreach ($net in @(Get-List (& $v 'networking.storage.networks') | Where-Object { $_ -is [System.Collections.IDictionary] })) { $storageVlan[[string]$net['adapter']] = $net }
    foreach ($i in $listed) {
        $nodeName = $Nodes[$i]['name']
        foreach ($p in $ports[$i]) {
            $owner = Test-IsManagementOwner $p
            $mode = [string]$p['ip_assignment']
            $roles = @(Get-List $p['roles'])
            if (Test-IsIPv4 $p['ip_address']) { $addresses.Add([pscustomobject]@{ Ip = [string]$p['ip_address']; Path = $p['_path']; Owner = $owner }) }
            if (-not $owner) {
                if ($mode -eq 'static' -and $p['gateway']) {
                    New-Finding 'AZL-022' error "$($p['_path']).gateway" "Port '$($p['name'])' of node '$nodeName' has a default gateway, and so does the management port. Validation fails when more than one physical adapter has a default gateway." $script:Learn.Decision8
                }
                if ($mode -in 'dhcp', 'dhcp_reservation') {
                    New-Finding 'AZL-022' warning "$($p['_path']).ip_assignment" "Port '$($p['name'])' of node '$nodeName' keeps DHCP ($mode), and node preparation leaves it on. If the DHCP server hands it a default gateway, the node has two and validation fails." $script:Learn.Decision8
                }
                if ($mode -eq 'static' -and -not $p['prefix_length']) {
                    New-Finding 'AZL-022' error "$($p['_path']).prefix_length" "Port '$($p['name'])' of node '$nodeName' has a static address without prefix_length; only the management port takes it from networking.management.subnet."
                }
                if ($mode -ne 'none' -and $mode -ne 'preconfigured' -and ($roles -join ',') -eq 'storage') {
                    New-Finding 'AZL-022' warning "$($p['_path']).ip_assignment" "Storage port '$($p['name'])' of node '$nodeName' has a host address ($mode). Network ATC assigns the storage addresses (or nodes[].storage_ips with auto_ip false); set ip_assignment none." $script:Learn.CustomIp
                }
                if ($mode -eq 'none' -and $p['ip_address']) {
                    New-Finding 'AZL-022' warning "$($p['_path']).ip_address" "Port '$($p['name'])' of node '$nodeName' lists $($p['ip_address']) but its ip_assignment is none, so the address is ignored. Set ip_assignment, or remove ip_address."
                }
                elseif ($mode -in 'static', 'dhcp_reservation' -and $subnet -and (Test-IsIPv4 $p['ip_address']) -and (Test-AddressInSubnet $p['ip_address'] $subnet)) {
                    New-Finding 'AZL-022' warning "$($p['_path']).ip_address" "Port '$($p['name'])' of node '$nodeName' has $($p['ip_address']), in the management subnet $subnet, besides the management port. Two ports on one subnet make the route the node takes unpredictable."
                }
            }
            $hostTag = Get-HostVlan $p $null
            if ($mode -in 'static', 'dhcp_reservation', 'dhcp' -and [string]$p['vlan_mode'] -eq 'tagged' -and -not $hostTag) {
                New-Finding 'AZL-023' error "$($p['_path']).vlan_id" "Port '$($p['name'])' of node '$nodeName' is tagged and has a host address, but no vlan_id to tag."
            }
            if ($owner -and $p['_source'] -eq 'network_adapters') {
                $tag = Get-HostVlan $p $siteVlan
                if ([int]$tag -ne $siteVlan) {
                    New-Finding 'AZL-023' error "$($p['_path'])" "Node '$nodeName': the management port tags VLAN $tag, but networking.management.vlan_id is $siteVlan. With an access port use vlan_mode access (the host sends VLAN 0)."
                }
            }
            if ('storage' -in $roles) {
                if ([string]$p['vlan_mode'] -eq 'access') {
                    New-Finding 'AZL-023' warning "$($p['_path']).vlan_mode" "Storage port '$($p['name'])' of node '$nodeName' is on an access port. Network ATC tags the storage VLANs, so the switch port must be a trunk that carries them." $script:Learn.Intents
                }
                $net = $storageVlan[[string]$p['name']]
                if ($net -and $null -ne $p['vlan_id'] -and [int]$p['vlan_id'] -ne [int]$net['vlan_id']) {
                    New-Finding 'AZL-023' error "$($p['_path']).vlan_id" "Storage port '$($p['name'])' of node '$nodeName' is VLAN $($p['vlan_id']), but storage network '$($net['name'])' on it is VLAN $($net['vlan_id'])."
                }
            }
            # AZL-024: the maintenance environment's port.
            if ($simplified -and 'provisioning' -in $roles -and $owner -and $mode -eq 'static' -and [string]$mgmt['provisioning_network'] -ne 'static') {
                New-Finding 'AZL-024' warning "$($p['_path']).roles" "Port '$($p['name'])' of node '$nodeName' is the static management port and also the maintenance environment's way to Azure, which takes DHCP there (provisioning_network dhcp): Mode B (Static with DHCP). A DHCP server must answer on that network while the machine is in the maintenance environment. The OS install then resets the port to DHCP, so OS configuration sets the static address again after ZTP." $script:Learn.Simplified
            }
        }
    }
    foreach ($group in ($addresses | Group-Object Ip | Where-Object { $_.Count -gt 1 -and @($_.Group | Where-Object { -not $_.Owner }).Count -gt 0 })) {
        New-Finding 'AZL-022' error 'nodes' "Address $($group.Name) is on $($group.Count) ports ($(@($group.Group.Path) -join ', '))."
    }
}

# AZL-026: the BIOS phases (schema 5.3). A key that holds for the OS install only (bios_during_provisioning) should also
# be in bios, so the final state is explicit; otherwise the Restore stage sets it back to the original value it saved.
function Get-BiosPhaseFinding {
    param([System.Collections.IDictionary]$Infra, [object[]]$Nodes)
    $hardware = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'hardware.bios_during_provisioning'
    $hardwareKeys = if ($hardware -is [System.Collections.IDictionary]) { @($hardware.Keys | ForEach-Object { [string]$_ }) } else { @() }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $passes = if ($Nodes.Count -gt 0) { 0..($Nodes.Count - 1) } else { @(-1) }
    foreach ($i in $passes) {
        $node = if ($i -ge 0) { $Nodes[$i] } else { $null }
        $final = Get-AzlBiosSetting -Infrastructure $Infra -Node $node
        $own = if ($node -and $node['bios_during_provisioning'] -is [System.Collections.IDictionary]) { @($node['bios_during_provisioning'].Keys | ForEach-Object { [string]$_ }) } else { @() }
        foreach ($key in (@($hardwareKeys) + @($own) | Select-Object -Unique)) {
            if ($final.Contains($key)) { continue }
            $path = if ($key -in $own) { "nodes[$i].bios_during_provisioning.$key" } else { "hardware.bios_during_provisioning.$key" }
            if ($seen.Add($path)) {
                New-Finding 'AZL-026' warning $path "BIOS key '$key' is set for the OS install only (bios_during_provisioning) but isn't in bios, so the final state isn't explicit. azurelocal-ztp's Restore stage then sets it back to the original value it saved at Boot. Add '$key' to bios with the value the machine should end with."
            }
        }
    }
}

# AZL-027: the maintenance environment's network (schema 5.3): the DHCP range ZTP scans, the per-node address, and the
# older site method for static addresses.
function Get-ProvisioningNetworkFinding {
    param([System.Collections.IDictionary]$Infra, [object[]]$Nodes, [hashtable]$OwnerOf)
    $mgmt = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'networking.management'
    if ($mgmt -isnot [System.Collections.IDictionary]) { return }
    $subnet = if (Test-IsCidr $mgmt['subnet']) { [string]$mgmt['subnet'] } else { $null }
    $range = $mgmt['provisioning_dhcp_range']
    $at = 'networking.management.provisioning_dhcp_range'
    if ($range -is [System.Collections.IDictionary] -and (Test-IsIPv4 $range['start']) -and (Test-IsIPv4 $range['end'])) {
        if ((ConvertTo-UInt32Address $range['start']) -gt (ConvertTo-UInt32Address $range['end'])) {
            New-Finding 'AZL-027' error $at "The provisioning DHCP range starts at $($range['start']), after its end $($range['end'])."
        }
        if ($subnet -and -not ((Test-AddressInSubnet $range['start'] $subnet) -and (Test-AddressInSubnet $range['end'] $subnet))) {
            New-Finding 'AZL-027' error $at "The provisioning DHCP range $($range['start'])-$($range['end']) isn't inside the management subnet $subnet." $script:Learn.Simplified
        }
    }
    $addresses = @(for ($i = 0; $i -lt $Nodes.Count; $i++) {
            if (Test-IsIPv4 $Nodes[$i]['maintenance_address']) { [pscustomobject]@{ Ip = [string]$Nodes[$i]['maintenance_address']; Path = "nodes[$i].maintenance_address" } }
        })
    foreach ($group in ($addresses | Group-Object Ip | Where-Object Count -gt 1)) {
        New-Finding 'AZL-027' error 'nodes' "Maintenance address $($group.Name) is used by $($group.Count) nodes ($(@($group.Group.Path) -join ', ')). Each machine's maintenance environment has its own address."
    }
    $staticNodes = @(for ($i = 0; $i -lt $Nodes.Count; $i++) { if ($OwnerOf[$i] -and $OwnerOf[$i].IpAssignment -eq 'static') { $i } })
    if ((Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'scenario.os_install') -eq 'simplified' -and $mgmt['static_method'] -eq 'site' -and $staticNodes.Count -gt 0) {
        New-Finding 'AZL-027' warning 'networking.management.static_method' "static_method is site: Microsoft's OS install assigns the static address and ignores the MAC, using the first ready port (observed on Dell AX-760). The address lands on the management port only when that is the first ready port. static_method device sets it on the port with the MAC, before the claim." $script:Learn.Simplified
    }
}

# AZL-028: the SAN (schema 5.3): the fabrics, the targets, and every machine's HBA ports or initiator name.
function Get-SanFinding {
    param([System.Collections.IDictionary]$Infra, [object[]]$Nodes)
    $san = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'storage.san'
    if ($san -isnot [System.Collections.IDictionary]) { return }
    $type = [string]$san['type']
    $names = [System.Collections.Generic.List[object]]::new()   # WWPNs or IQNs, with where each is
    $nodeSan = { param([int]$i) if ($Nodes[$i]['san'] -is [System.Collections.IDictionary]) { $Nodes[$i]['san'] } else { @{} } }

    if ($type -eq 'fibre_channel') {
        $fc = $san['fibre_channel']
        if ($fc -isnot [System.Collections.IDictionary]) { return }
        $fabrics = @(Get-List $fc['fabrics'] | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['name'] })
        foreach ($group in ($fabrics | Group-Object { $_.ToLowerInvariant() } | Where-Object Count -gt 1)) {
            New-Finding 'AZL-028' error 'storage.san.fibre_channel.fabrics' "Fabric '$($group.Group[0])' is listed $($group.Count) times. Fabric names are unique."
        }
        $fabricMissing = {
            param([object]$Fabric, [string]$Path)
            if ([string]$Fabric -and [string]$Fabric -notin $fabrics) {
                New-Finding 'AZL-028' error $Path "Fabric '$Fabric' isn't defined in storage.san.fibre_channel.fabrics ($(if ($fabrics) { $fabrics -join ', ' } else { 'none are listed' }))."
            }
        }
        $targets = @(Get-List $fc['target_wwpns'] | Where-Object { $_ -is [System.Collections.IDictionary] })
        if ($targets.Count -eq 0) {
            New-Finding 'AZL-028' error 'storage.san.fibre_channel.target_wwpns' "A Fibre Channel SAN needs the array's target WWPNs: list them with the fabric each is cabled to."
        }
        for ($t = 0; $t -lt $targets.Count; $t++) {
            & $fabricMissing $targets[$t]['fabric'] "storage.san.fibre_channel.target_wwpns[$t].fabric"
            if ($targets[$t]['wwpn']) { $names.Add([pscustomobject]@{ Key = ([string]$targets[$t]['wwpn']).Replace(':', '').ToUpperInvariant(); Display = [string]$targets[$t]['wwpn']; Path = "storage.san.fibre_channel.target_wwpns[$t]" }) }
        }
        for ($i = 0; $i -lt $Nodes.Count; $i++) {
            $mine = & $nodeSan $i
            $hbas = @(Get-List $mine['hbas'] | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['type'] -ne 'iscsi_offload' })
            $portCount = 0
            for ($h = 0; $h -lt $hbas.Count; $h++) {
                $ports = @(Get-List $hbas[$h]['ports'] | Where-Object { $_ -is [System.Collections.IDictionary] })
                for ($p = 0; $p -lt $ports.Count; $p++) {
                    if (-not $ports[$p]['wwpn']) { continue }
                    $portCount++
                    & $fabricMissing $ports[$p]['fabric'] "nodes[$i].san.hbas[$h].ports[$p].fabric"
                    $names.Add([pscustomobject]@{ Key = ([string]$ports[$p]['wwpn']).Replace(':', '').ToUpperInvariant(); Display = [string]$ports[$p]['wwpn']; Path = "nodes[$i].san.hbas[$h].ports[$p]" })
                }
            }
            if ($portCount -eq 0) {
                New-Finding 'AZL-028' error "nodes[$i].san" "Node '$($Nodes[$i]['name'])' has no HBA port WWPNs. A Fibre Channel SAN needs every machine's HBAs (nodes[].san.hbas[].ports[].wwpn) for zoning and LUN masking."
            }
            if ($mine['initiator_iqn']) { New-Finding 'AZL-028' warning "nodes[$i].san.initiator_iqn" "Node '$($Nodes[$i]['name'])' lists an iSCSI initiator_iqn, but storage.san.type is fibre_channel; it is ignored." }
        }
    }
    elseif ($type -eq 'iscsi') {
        $iscsi = $san['iscsi']
        if ($iscsi -isnot [System.Collections.IDictionary]) { return }
        $targets = @(Get-List $iscsi['targets'] | Where-Object { $_ -is [System.Collections.IDictionary] })
        if ($targets.Count -eq 0) {
            New-Finding 'AZL-028' error 'storage.san.iscsi.targets' "An iSCSI SAN needs the array's targets: list each target IQN with its portals."
        }
        for ($t = 0; $t -lt $targets.Count; $t++) {
            if ($targets[$t]['iqn']) { $names.Add([pscustomobject]@{ Key = ([string]$targets[$t]['iqn']).ToLowerInvariant(); Display = [string]$targets[$t]['iqn']; Path = "storage.san.iscsi.targets[$t]" }) }
        }
        for ($i = 0; $i -lt $Nodes.Count; $i++) {
            $mine = & $nodeSan $i
            if ($mine['initiator_iqn']) {
                $names.Add([pscustomobject]@{ Key = ([string]$mine['initiator_iqn']).ToLowerInvariant(); Display = [string]$mine['initiator_iqn']; Path = "nodes[$i].san.initiator_iqn" })
            } else {
                New-Finding 'AZL-028' error "nodes[$i].san" "Node '$($Nodes[$i]['name'])' has no initiator_iqn. An iSCSI SAN needs every machine's initiator name (nodes[].san.initiator_iqn) for LUN masking."
            }
            if ($mine['hbas']) { New-Finding 'AZL-028' warning "nodes[$i].san.hbas" "Node '$($Nodes[$i]['name'])' lists Fibre Channel HBAs, but storage.san.type is iscsi; they are ignored." }
            $iscsiPorts = @(Get-AzlNodeNetworkAdapter -Infrastructure $Infra -Node $Nodes[$i] | Where-Object { @(Get-List $_['roles'] | Where-Object { $_ -in 'iscsi:a', 'iscsi:b' }).Count -gt 0 })
            if ($iscsiPorts.Count -eq 0) {
                New-Finding 'AZL-028' warning "nodes[$i].network_adapters" "Node '$($Nodes[$i]['name'])' has no port with role iscsi:a or iscsi:b. List the iSCSI ports in network_adapters, with their addresses, so the SAN deployment knows where the sessions start."
            }
            foreach ($port in $iscsiPorts) {
                if ([string]$port['ip_assignment'] -eq 'none') {
                    New-Finding 'AZL-028' error "$($port['_path']).ip_assignment" "iSCSI port '$($port['name'])' of node '$($Nodes[$i]['name'])' has ip_assignment none. An iSCSI port needs a host address: static (with ip_address and prefix_length), or a DHCP reservation."
                }
            }
        }
    }
    foreach ($group in ($names | Group-Object Key | Where-Object Count -gt 1)) {
        $what = if ($type -eq 'iscsi') { 'IQN' } else { 'WWPN' }
        New-Finding 'AZL-028' error $group.Group[1].Path "$what $($group.Group[0].Display) is listed $($group.Count) times ($(@($group.Group.Path) -join ', ')). Each is unique in the SAN."
    }
}

# AZL-031: the OS configuration run (schema 5.4.3). os_configuration.clear_storage wipes local disks. The schema makes it a
# boolean; on a SAN design it is worth saying that only the machines' local disks are touched.
function Get-OsConfigurationFinding {
    param([System.Collections.IDictionary]$Infra)
    $value = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'os_configuration.clear_storage'
    if ($value -isnot [bool] -or -not $value) { return }
    if ((Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'scenario.storage_architecture') -in 'san', 'hybrid') {
        New-Finding 'AZL-031' warning 'os_configuration.clear_storage' 'clear_storage is true on a SAN design. Only the machines'' local disks are wiped; Fibre Channel and iSCSI LUNs, USB, boot and system disks are never touched. Check the wipe list the Plan mode prints before you approve.'
    }
}

# AZL-050 to AZL-053: the domain join (schema 5.5). With scenario.identity active_directory the OS configuration run joins each
# machine to the domain and the OU, before the cluster validation and deployment, with identity.active_directory.domain_join_account.
function Get-DomainJoinFinding {
    param([System.Collections.IDictionary]$Infra, [object[]]$Nodes)
    $identity = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'scenario.identity'
    $ad = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'identity.active_directory'
    $account = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'identity.active_directory.domain_join_account'
    if ($identity -eq 'local_identity') {
        foreach ($key in 'domain_join_account', 'local_admin_members') {
            if (Get-AzlInfrastructureValue -Infrastructure $Infra -Path "identity.active_directory.$key") { New-Finding 'AZL-053' warning "identity.active_directory.$key" "scenario.identity is local_identity, so no machine joins a domain and $key is not used. Remove it, or set scenario.identity to active_directory." }
        }
        return
    }
    if ($identity -ne 'active_directory' -or $ad -isnot [System.Collections.IDictionary]) { return }
    if ((Get-AzlInfrastructureScope -Infrastructure $Infra) -eq 'ztp') { return }

    # AZL-050: the join credential. Default: the LCM user (Microsoft's AD preparation gives it the right to create and delete computer
    # objects in the dedicated OU); domain_join_account overrides it. One of them must have a username and a Key Vault password.
    $lcm = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'identity.active_directory.lcm_user'
    $hasLcm = $lcm -is [System.Collections.IDictionary] -and $lcm['username'] -and $lcm['password']
    $hasAccount = $account -is [System.Collections.IDictionary] -and $account['username'] -and $account['password']
    if (-not $hasLcm -and -not $hasAccount) {
        New-Finding 'AZL-050' error 'identity.active_directory.lcm_user' 'scenario.identity is active_directory, so the OS configuration run joins each machine to the domain and needs a join credential: identity.active_directory.lcm_user (username and a keyvault:// password; the default) or domain_join_account.'
    }
    if ($hasLcm) {
        $lcmName = [string]$lcm['username']
        if ($lcmName -notmatch '^[A-Za-z_][A-Za-z0-9_-]{0,19}$') {
            New-Finding 'AZL-050' error 'identity.active_directory.lcm_user.username' "The LCM user name '$lcmName' is not valid for Azure Local: 1 to 20 characters, letters, numbers, hyphens and underscores only, not starting with a hyphen or a number."
        }
        $localAdmin = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'identity.local_admin.username'
        if ($localAdmin -and $lcmName -ieq [string]$localAdmin) {
            New-Finding 'AZL-050' error 'identity.active_directory.lcm_user.username' "The LCM user name '$lcmName' is the local administrator's name. Microsoft requires them to differ."
        }
    }
    # AZL-051: ou_path is a distinguished name inside the domain: OU=...,DC=<each label of domain_fqdn>.
    $ou = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'identity.active_directory.ou_path'
    $fqdn = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'identity.active_directory.domain_fqdn'
    if ($ou -is [string] -and $ou -and $fqdn -is [string] -and $fqdn) {
        $rdns = @([regex]::Split($ou, '(?<!\\),') | ForEach-Object { $_.Trim() })
        if ($ou -match '[&"''<>]') { New-Finding 'AZL-051' error 'identity.active_directory.ou_path' "'$ou' contains a character Azure Local does not support in the OU path: & , ' < > and the double quote." }
        $bad = @($rdns | Where-Object { $_ -notmatch '^(OU|CN|DC)=[^=]+$' })
        $dcs = @($rdns | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3).ToLowerInvariant() })
        $firstDc = -1
        for ($k = 0; $k -lt $rdns.Count; $k++) { if ($firstDc -lt 0 -and $rdns[$k] -match '^DC=') { $firstDc = $k } }
        $afterDc = $firstDc -ge 0 -and @($rdns[$firstDc..($rdns.Count - 1)] | Where-Object { $_ -notmatch '^DC=' }).Count -gt 0
        if ($bad.Count) { New-Finding 'AZL-051' error 'identity.active_directory.ou_path' "'$ou' is not a distinguished name: '$($bad[0])' is not OU=, CN= or DC= followed by a value." }
        elseif ($afterDc) { New-Finding 'AZL-051' error 'identity.active_directory.ou_path' "'$ou' has an OU or CN after a DC component. A distinguished name lists the OUs first (leaf to root) and the DC components of the domain last." }
        elseif (($dcs -join '.') -ne $fqdn.ToLowerInvariant()) { New-Finding 'AZL-051' error 'identity.active_directory.ou_path' "'$ou' ends in DC=$($dcs -join ',DC='), which is the domain '$($dcs -join '.')', not domain_fqdn '$fqdn'. The OU must be inside the domain the machines join." }
    }

    # AZL-052: the domain controllers are the DNS servers the nodes use, because the join finds the domain through DNS.
    $dcList = @(Get-List (Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'identity.active_directory.domain_controllers') | ForEach-Object { [string]$_ })
    if ($dcList.Count) {
        for ($i = 0; $i -lt $Nodes.Count; $i++) {
            $o = Get-AzlManagementAdapter -Infrastructure $Infra -Node $Nodes[$i]
            if (-not $o) { continue }
            $dns = @($o.DnsServers | ForEach-Object { [string]$_ })
            if (-not $dns.Count) { continue }
            $missing = @($dcList | Where-Object { $_ -notin $dns })
            $extra = @($dns | Where-Object { $_ -notin $dcList })
            if ($missing.Count -or $extra.Count) {
                $why = @()
                if ($missing.Count) { $why += "domain controller(s) $($missing -join ', ') not among the DNS servers of the management port" }
                if ($extra.Count) { $why += "DNS server $($extra -join ', ') is not listed in domain_controllers" }
                New-Finding 'AZL-052' error 'identity.active_directory.domain_controllers' "Node '$($Nodes[$i]['name'])': $($why -join '; '). domain_controllers must be the DNS servers of the management port: the machines find the domain, and so join it, through them."
                break
            }
        }
    }
}

# AZL-029: what azurelocal-ztp derives from the hardware inventory and the Azure choices it makes (schema 5.4): the SAN
# adapters whose PCIe slots it turns off for the OS install, the embedded NICs it enables, the site's time setting and the
# stage budgets. Only for simplified provisioning, the path ZTP runs.
function Get-ZtpActionFinding {
    param([System.Collections.IDictionary]$Infra, [object[]]$Nodes)
    if ((Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'scenario.os_install') -ne 'simplified') { return }
    $simplified = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'provisioning.simplified'
    if ($simplified -isnot [System.Collections.IDictionary]) { return }
    $slotNumber = { param([object]$Label) if (([string]$Label) -match '^\s*slot[\s_-]*(\d+)\s*$') { [int]$Matches[1] } else { $null } }
    # A port's label is read loosely (Slot 2 Port 1, PCIe Slot 2, Riser 1 Slot 2): missing a shared slot would cut the port.
    $looseSlot = { param([object]$Label) if (([string]$Label) -match '(?i)slot\s*[_-]?\s*(\d+)') { [int]$Matches[1] } else { $null } }

    $listed = @($(for ($i = 0; $i -lt $Nodes.Count; $i++) {
                $san = $Nodes[$i]['san']
                if ($san -is [System.Collections.IDictionary]) { for ($h = 0; $h -lt @(Get-List $san['hbas']).Count; $h++) { [pscustomobject]@{ Node = $i; Hba = $h; Item = @(Get-List $san['hbas'])[$h] } } }
            }) | Where-Object { $_.Item -is [System.Collections.IDictionary] })
    $switch = $simplified['isolate_san_adapters']
    $isolate = if ($null -ne $switch) { [bool]$switch } else { $listed.Count -gt 0 }
    if ($switch -eq $true -and $listed.Count -eq 0) {
        New-Finding 'AZL-029' warning 'provisioning.simplified.isolate_san_adapters' 'isolate_san_adapters is true but no node lists san.hbas, so there is nothing to turn off for the OS install. List each machine''s HBAs in nodes[].san.hbas[] (slot is enough), or remove the switch.' $script:Learn.Simplified
    }
    if ($isolate) {
        foreach ($x in $listed) {
            $at = "nodes[$($x.Node)].san.hbas[$($x.Hba)].slot"
            $label = [string]$x.Item['slot']
            $n = & $slotNumber $label
            if ($null -eq $n) {
                if (-not $x.Item['bios_attribute']) {
                    New-Finding 'AZL-029' error $at "The slot '$label' isn't a PCIe slot label such as 'Slot 2', so azurelocal-ztp can't derive the BIOS attribute that turns it off for the OS install. Use 'Slot <n>', give the adapter its bios_attribute, or set isolate_san_adapters to false." $script:Learn.Simplified
                }
                continue
            }
            # A card in that slot that also carries network ports must stay on: the management port could be on it.
            foreach ($port in @(Get-List $Nodes[$x.Node]['network_adapters'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
                if ((& $looseSlot $port['slot']) -eq $n -and (@(Get-List $port['roles']) | Where-Object { $_ -ne 'unused' })) {
                    New-Finding 'AZL-029' error $at "Slot $n holds the SAN adapter and also the network port '$($port['name'])' (roles $(@(Get-List $port['roles']) -join ', ')). Turning the slot off for the OS install would cut that port. Fix the slot of one of them, or set isolate_san_adapters to false and use a BIOS setting that hides the SAN LUN from the installer only." $script:Learn.Simplified
                }
            }
        }
        $twice = $listed | Group-Object { "$($_.Node)/$(& $slotNumber $_.Item['slot'])" } | Where-Object { $_.Count -gt 1 -and $_.Name -notmatch '/$' }
        foreach ($g in $twice) { New-Finding 'AZL-029' warning "nodes[$($g.Group[0].Node)].san.hbas" "Two adapters are in the same slot ($($g.Group[0].Item['slot'])); a slot holds one card." }
    }

    $ntp = $simplified['ntp']
    if ($ntp -is [System.Collections.IDictionary] -and $ntp['configuration'] -eq 'Manual' -and -not $ntp['server']) {
        New-Finding 'AZL-029' error 'provisioning.simplified.ntp.server' 'ntp.configuration is Manual but ntp.server is empty. Name the NTP server, or use Automatic.' $script:Learn.Simplified
    }
    if ($ntp -is [System.Collections.IDictionary] -and $ntp['configuration'] -ne 'Manual' -and ($ntp['server'] -or $ntp['alternate_server'])) {
        New-Finding 'AZL-029' warning 'provisioning.simplified.ntp' 'ntp.server is set but ntp.configuration is not Manual, so the site uses Automatic time and ignores the server.' $script:Learn.Simplified
    }
    $timeouts = $simplified['timeouts']
    if ($timeouts -is [System.Collections.IDictionary] -and $timeouts['bootstrap_voucher_minutes'] -and $timeouts['bootstrap_minutes'] -and [int]$timeouts['bootstrap_voucher_minutes'] -gt [int]$timeouts['bootstrap_minutes']) {
        New-Finding 'AZL-029' warning 'provisioning.simplified.timeouts.bootstrap_voucher_minutes' "The voucher budget ($($timeouts['bootstrap_voucher_minutes']) minutes) is longer than the overall Bootstrap budget ($($timeouts['bootstrap_minutes']) minutes), so the overall one ends first."
    }
}

# AZL-030: how the SBE package reaches the nodes during OS configuration (schema 5.4.2): hardware.sbe.delivery is winrm_copy,
# node_pull or skip. There is no storage account route (Azure Arc Run Command can't carry a file).
function Get-SbeDeliveryFinding {
    param([System.Collections.IDictionary]$Infra, [object[]]$Nodes, [hashtable]$OwnerOf)
    $sbe = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'hardware.sbe'
    if ($sbe -isnot [System.Collections.IDictionary]) { return }
    $delivery = [string]$sbe['delivery']
    $url = [string]$sbe['node_pull_url']
    if ($delivery -in 'winrm_copy', 'node_pull' -and -not $sbe['bundle_path']) {
        New-Finding 'AZL-030' error 'hardware.sbe.delivery' "delivery is $delivery but hardware.sbe.bundle_path is empty: there is no package to deliver."
    }
    if ($delivery -eq 'node_pull') {
        if (-not $url) { New-Finding 'AZL-030' error 'hardware.sbe.node_pull_url' 'delivery is node_pull: give the folder the nodes download the SBE files from (https://host/sbe/dell, or a UNC folder \\server\share\sbe).' }
    }
    elseif ($url) {
        New-Finding 'AZL-030' warning 'hardware.sbe.node_pull_url' "node_pull_url is set but delivery is '$(if ($delivery) { $delivery } else { 'skip' })', so it is not used. Set delivery to node_pull, or remove the address."
    }
    if ($url) {
        if ($url -notmatch '^(https?://|\\\\)\S+$') {
            New-Finding 'AZL-030' error 'hardware.sbe.node_pull_url' "'$url' is not an https:// (or http://) address or a UNC folder (\\server\share\folder)."
        }
        else {
            if ($url -match '^https?://[^/]*@' -or $url -match '[?#]' ) {
                New-Finding 'AZL-030' error 'hardware.sbe.node_pull_url' 'The address carries a user name, password, token or query string. infrastructure.yml holds no credential: serve the folder read-only without one (the SHA-256 is checked on the node).'
            }
            if ($url -match '^http://') {
                New-Finding 'AZL-030' warning 'hardware.sbe.node_pull_url' 'http:// is not encrypted. The SHA-256 is checked on the node after the download, but serve the folder over https:// where you can.'
            }
        }
    }
    if ($delivery -eq 'winrm_copy') {
        for ($i = 0; $i -lt $Nodes.Count; $i++) {
            $o = $OwnerOf[$i]
            if (-not $o -or -not $o.IpAddress) {
                New-Finding 'AZL-030' warning "nodes[$i]" "delivery is winrm_copy and node '$($Nodes[$i]['name'])' has no management ip_address in the file, so the toolkit has no address to open the WinRM session to. Give it one (a DHCP reservation address counts)."
            }
        }
    }
}

# AZL-040: the ARM Validate and Deploy options (schema 5.6, the deployment block): polling, time limits, approval, and the names
# the skip and acknowledge lists use.
function Get-DeploymentOptionFinding {
    param([System.Collections.IDictionary]$Infra)
    $d = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'deployment'
    if ($d -isnot [System.Collections.IDictionary]) { return }
    $poll = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'deployment.poll_seconds'
    $max = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'deployment.poll_max_seconds'
    if ($null -ne $poll -and $null -ne $max -and [int]$max -lt [int]$poll) {
        New-Finding 'AZL-040' error 'deployment.poll_max_seconds' "poll_max_seconds ($max) is less than poll_seconds ($poll); the longest delay can't be shorter than the first."
    }
    $validate = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'deployment.validate_timeout_minutes'
    if ($null -ne $validate -and [int]$validate -lt 30) {
        New-Finding 'AZL-040' warning 'deployment.validate_timeout_minutes' "A Validate takes about 10 to 30 minutes (Microsoft); $validate minutes may stop the wait while Azure is still working. The next run attaches to it, so nothing is lost, but the run reports a time-out."
    }
    $deploy = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'deployment.deploy_timeout_minutes'
    if ($null -ne $deploy -and [int]$deploy -lt 240) {
        New-Finding 'AZL-040' warning 'deployment.deploy_timeout_minutes' "A Deploy takes 2.5 to 3 hours (Microsoft) and some steps 40 to 50 minutes or more; $deploy minutes will usually stop the wait early. Azure keeps working and the next run attaches to it."
    }
    if ((Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'deployment.approval') -eq 'none') {
        New-Finding 'AZL-040' warning 'deployment.approval' 'approval none starts the Deploy right after a good Validate, with nobody reading it. Use it in a lab only; pipelines should keep an approval between the two.'
    }
    $known = $null
    foreach ($id in @(Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'deployment.acknowledge_known_issues')) {
        if (-not $id) { continue }
        if ($null -eq $known) {
            $file = [IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'config', 'known-issues', 'arm-deployment.json')
            $known = if (Test-Path -LiteralPath $file -PathType Leaf) { @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -Depth 20)['issues'] | ForEach-Object { $_['id'] }) } else { @() }
        }
        if ($known.Count -and $id -ne '*' -and $id -notin $known) {
            New-Finding 'AZL-040' warning 'deployment.acknowledge_known_issues' "'$id' is not an id in config/known-issues/arm-deployment.json ($($known -join ', ')), so it acknowledges nothing."
        }
    }
}
# AZL-070: the CI/CD infrastructure in devops (schema 5.5), which tasks 01 to 06 of automation / 01-cicd-infra read: the
# runners (one Linux general pool and at most one Windows ztp runner), their subnets, the hub peering, the environments and
# the sign-in method.
function Get-CicdFinding {
    param([System.Collections.IDictionary]$Infra)
    $devops = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'devops'
    if ($devops -isnot [System.Collections.IDictionary]) { return }
    $net = $devops['runner_network']
    $runners = @(Get-List $devops['runners'] | Where-Object { $_ -is [System.Collections.IDictionary] })

    foreach ($group in ($runners | Group-Object { $_['name'] } | Where-Object Count -gt 1)) {
        New-Finding 'AZL-070' error 'devops.runners' "Runner name '$($group.Name)' is used $($group.Count) times."
    }
    $ztp = @($runners | Where-Object { $_['purpose'] -eq 'ztp' })
    $linuxGeneral = @($runners | Where-Object { $_['os_type'] -eq 'linux' -and $_['purpose'] -ne 'ztp' })
    $windowsGeneral = @($runners | Where-Object { $_['os_type'] -eq 'windows' -and $_['purpose'] -ne 'ztp' })
    if ($ztp.Count -gt 1) {
        New-Finding 'AZL-070' error 'devops.runners' 'Task 06 deploys one ztp runner: azurelocal-ztp keeps its state on the runner''s disk and a second runner would not share it. Use the cicd-runner module directly for more.'
    }
    if ($linuxGeneral.Count -gt 1) {
        New-Finding 'AZL-070' error 'devops.runners' 'Task 06 deploys one Linux general pool. Raise count on it, or use the cicd-runner module directly for more pools.'
    }
    if ($windowsGeneral.Count -gt 0) {
        New-Finding 'AZL-070' error 'devops.runners' 'Task 06 deploys a Windows runner for the ztp purpose only. Set purpose: ztp, or use the cicd-runner module directly for a general Windows runner.'
    }
    for ($i = 0; $i -lt $runners.Count; $i++) {
        $r = $runners[$i]
        $at = "devops.runners[$i]"
        if ($r['purpose'] -eq 'ztp') {
            if ($r['os_type'] -ne 'windows') {
                New-Finding 'AZL-070' error "$at.os_type" 'A ztp runner must be Windows: azurelocal-ztp shares the virtual USB images over SMB with Windows commands.' $script:Learn.Simplified
            }
            if ($r['compute_type'] -eq 'vmss' -or ($r['count'] -and [int]$r['count'] -gt 1)) {
                New-Finding 'AZL-070' error "$at.count" 'A ztp runner is one VM, not a scale set: the run keeps its state on the runner''s disk.'
            }
            if (@(Get-List $(if ($net -is [System.Collections.IDictionary]) { $net['bmc_cidrs'] })).Count -eq 0) {
                New-Finding 'AZL-070' error 'devops.runner_network.bmc_cidrs' 'A ztp runner needs bmc_cidrs: the network security group allows inbound TCP 445 from those ranges only, and the BMCs connect to the runner there.' $script:Learn.Simplified
            }
            if (-not $r['data_disk_gb'] -or [int]$r['data_disk_gb'] -lt 128) {
                New-Finding 'AZL-070' warning "$at.data_disk_gb" 'A ztp runner holds the maintenance ISO, the SBE and one image per machine. Give it a data disk of 512 GB or more.'
            }
        }
        if ($r['os_type'] -eq 'windows' -and $r['compute_type'] -eq 'vmss') {
            New-Finding 'AZL-070' error "$at.compute_type" 'A Windows runner must be a VM: its bootstrap runs through Run Command, which scale sets do not support.'
        }
        if (-not $r['registration_secret']) {
            New-Finding 'AZL-070' error "$at.registration_secret" 'A runner needs registration_secret, the Key Vault reference it reads at boot. Only the reference is in the file.'
        }
        if ($devops['platform'] -eq 'gitlab' -and @(Get-List $r['labels']).Count -gt 0) {
            New-Finding 'AZL-070' warning "$at.labels" 'GitLab fixes a runner''s tags when the runner authentication token is created, so labels here only apply to a legacy registration token. Set the tags where you create the token.'
        }
    }
    if ($runners.Count -gt 0 -and -not $devops['resource_group']) {
        New-Finding 'AZL-070' error 'devops.resource_group' 'Runners need devops.resource_group, the resource group that holds them, their identity and their network.'
    }
    if ($runners.Count -gt 0 -and $net -isnot [System.Collections.IDictionary]) {
        New-Finding 'AZL-070' error 'devops.runner_network' 'Runners need devops.runner_network: the VNet address space and a subnet for each runner.'
    }

    if ($net -is [System.Collections.IDictionary]) {
        $spaces = @(Get-List $net['address_space'] | Where-Object { Test-IsCidr $_ })
        $ranges = @()
        for ($i = 0; $i -lt $runners.Count; $i++) {
            $subnet = $runners[$i]['subnet']
            if ($subnet -isnot [System.Collections.IDictionary] -or -not (Test-IsCidr $subnet['prefix'])) {
                New-Finding 'AZL-070' error "devops.runners[$i].subnet" 'Each runner needs a subnet with a name and a CIDR prefix.'
                continue
            }
            $range = Get-SubnetRange $subnet['prefix']
            $inside = @($spaces | Where-Object { $space = Get-SubnetRange $_; $range.First -ge $space.First -and $range.Last -le $space.Last })
            if ($spaces.Count -gt 0 -and $inside.Count -eq 0) {
                New-Finding 'AZL-070' error "devops.runners[$i].subnet.prefix" "The subnet $($subnet['prefix']) isn't inside runner_network.address_space ($($spaces -join ', '))."
            }
            $ranges += [pscustomobject]@{ Index = $i; Prefix = $subnet['prefix']; First = $range.First; Last = $range.Last }
        }
        for ($a = 0; $a -lt $ranges.Count; $a++) {
            for ($b = $a + 1; $b -lt $ranges.Count; $b++) {
                if ($ranges[$a].First -le $ranges[$b].Last -and $ranges[$b].First -le $ranges[$a].Last) {
                    New-Finding 'AZL-070' error "devops.runners[$($ranges[$b].Index)].subnet.prefix" "The subnet $($ranges[$b].Prefix) overlaps $($ranges[$a].Prefix) of devops.runners[$($ranges[$a].Index)]."
                }
            }
        }
        $peering = $net['hub_peering']
        if ($peering -is [System.Collections.IDictionary] -and $peering['enabled'] -eq $true) {
            $hubName = [string]$peering['hub_network']
            $hubs = @(Get-List (Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'landing_zone.networks') | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -eq $hubName })
            if (-not $peering['hub_vnet_id'] -and $hubs.Count -eq 0) {
                New-Finding 'AZL-070' error 'devops.runner_network.hub_peering' 'Peering needs hub_vnet_id, or hub_network naming a network in landing_zone.networks.'
            }
        }
    }

    $environments = @(Get-List $devops['environments'] | Where-Object { $_ -is [System.Collections.IDictionary] })
    foreach ($group in ($environments | Group-Object { $_['name'] } | Where-Object Count -gt 1)) {
        New-Finding 'AZL-070' error 'devops.environments' "Environment name '$($group.Name)' is used $($group.Count) times."
    }
    for ($i = 0; $i -lt $environments.Count; $i++) {
        $e = $environments[$i]
        if ($e['approval_required'] -eq $true -and @(Get-List $e['approvers']).Count -eq 0) {
            New-Finding 'AZL-070' warning "devops.environments[$i].approvers" "Environment '$($e['name'])' requires approval but lists no approvers, so no one can approve."
        }
    }
    $auth = $devops['authentication']
    if ($auth -is [System.Collections.IDictionary] -and $auth['method'] -eq 'client_secret' -and -not $auth['client_secret']) {
        New-Finding 'AZL-070' error 'devops.authentication.client_secret' 'method client_secret needs client_secret, the Key Vault reference where task 01 stores the secret.'
    }
}

# AZL-025: the site's management address range (simplified provisioning, static management addresses).
function Get-SiteRangeFinding {
    param([System.Collections.IDictionary]$Infra, [object[]]$Nodes, [hashtable]$OwnerOf, [string]$Subnet, [bool]$Simplified)
    $set = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'networking.management.site_ip_range'
    if (-not $Simplified -and $set -isnot [System.Collections.IDictionary]) { return }
    $range = Get-AzlSiteIpRange -Infrastructure $Infra
    if (-not $range) { return }
    $at = if ($range.Source -eq 'site_ip_range') { 'networking.management.site_ip_range' } else { 'nodes' }
    $start = ConvertTo-UInt32Address $range.Start
    $end = ConvertTo-UInt32Address $range.End
    if ($start -gt $end) { New-Finding 'AZL-025' error $at "The site range starts at $($range.Start), after its end $($range.End)."; return }
    if ($Subnet -and -not ((Test-AddressInSubnet $range.Start $Subnet) -and (Test-AddressInSubnet $range.End $Subnet))) {
        New-Finding 'AZL-025' error $at "The site range $($range.Start)-$($range.End) isn't inside the management subnet $Subnet."
    }
    $modes = @()
    for ($i = 0; $i -lt $Nodes.Count; $i++) {
        $o = $OwnerOf[$i]
        if (-not $o) { continue }
        $modes += $o.IpAssignment
        if ($o.IpAssignment -eq 'static' -and (Test-IsIPv4 $o.IpAddress)) {
            $ip = ConvertTo-UInt32Address $o.IpAddress
            if ($ip -lt $start -or $ip -gt $end) { New-Finding 'AZL-025' error "$($o.Path).ip_address" "Node '$($Nodes[$i]['name'])': its static management address $($o.IpAddress) is outside the site range $($range.Start)-$($range.End)." }
        }
    }
    $pool = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'networking.management.infrastructure_pool'
    if ($pool -is [System.Collections.IDictionary] -and (Test-IsIPv4 $pool['start']) -and (Test-IsIPv4 $pool['end'])) {
        if ((ConvertTo-UInt32Address $pool['start']) -le $end -and (ConvertTo-UInt32Address $pool['end']) -ge $start) {
            New-Finding 'AZL-025' warning $at "The site range $($range.Start)-$($range.End) overlaps the infrastructure pool $($pool['start'])-$($pool['end']), which must hold no node address." $script:Learn.Decision8
        }
    }
    if ($Simplified -and (Get-AzlManagementStaticMethod -Infrastructure $Infra) -eq 'site' -and @($modes | Select-Object -Unique).Count -gt 1) {
        New-Finding 'AZL-025' warning 'nodes' "The management ports mix $(@($modes | Select-Object -Unique) -join ', '). The site's network setting is one for every machine: Manual for the static addresses."
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------------------------------------------------

function Test-AzlInfrastructure {
    <#
    .SYNOPSIS
        Checks an infrastructure.yml file and returns every finding.
    .PARAMETER Path
        The infrastructure file.
    .PARAMETER SchemaPath
        The JSON schema. Defaults to config/variables/schema/infrastructure.schema.json in this toolkit.
    .OUTPUTS
        One object per finding: Id, Severity (error, warning, info), Path, Message, LearnUrl. Nothing when the file is clean.
    .EXAMPLE
        Test-AzlInfrastructure -Path .\infrastructure.yml | Format-Table Severity, Id, Path, Message -Wrap
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SchemaPath = $script:DefaultSchemaPath
    )
    $infra = Read-InfrastructureFile $Path

    $version = Get-AzlInfrastructureValue -Infrastructure $infra -Path '_metadata.schema_version'
    if ($version -isnot [string] -or $version -notmatch "^$script:SupportedMajor\.") {
        New-Finding 'AZL-000' error '_metadata.schema_version' "schema_version is '$version'. This toolkit reads schema $script:SupportedMajor.x; see config/variables/docs/MIGRATION.md."
        return
    }

    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) { throw "Schema not found: $SchemaPath" }
    $json = $infra | ConvertTo-Json -Depth 100
    Get-SchemaFinding -Json $json -SchemaText (Get-Content -LiteralPath $SchemaPath -Raw)

    Get-SemanticFinding -Infra $infra
}

function Import-AzlInfrastructure {
    <#
    .SYNOPSIS
        Reads infrastructure.yml, checks it, and returns it as an ordered hashtable. Stops when the file has errors.
    .PARAMETER Path
        The infrastructure file. When omitted: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml, then .\config\infrastructure.yml.
    .PARAMETER SkipValidation
        Return the file without checking it. For tools that only display it.
    .EXAMPLE
        $infra = Import-AzlInfrastructure -Path .\infrastructure.yml
        $infra.networking.management.gateway
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [string]$Path,
        [string]$SchemaPath = $script:DefaultSchemaPath,
        [switch]$SkipValidation
    )
    if (-not $Path) {
        $candidates = @($env:AZL_INFRASTRUCTURE_FILE, (Join-Path '.' 'infrastructure.yml'), (Join-Path (Join-Path '.' 'config') 'infrastructure.yml')) | Where-Object { $_ }
        $Path = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $Path) { throw 'No infrastructure file given, and none found at $env:AZL_INFRASTRUCTURE_FILE, .\infrastructure.yml or .\config\infrastructure.yml.' }
    }
    if (-not $SkipValidation) {
        $findings = @(Test-AzlInfrastructure -Path $Path -SchemaPath $SchemaPath)
        foreach ($w in ($findings | Where-Object Severity -eq 'warning')) { Write-Warning "$($w.Id) $($w.Path): $($w.Message)" }
        $errors = @($findings | Where-Object Severity -eq 'error')
        if ($errors.Count -gt 0) {
            $list = ($errors | ForEach-Object { "  $($_.Id) $($_.Path): $($_.Message)" }) -join [Environment]::NewLine
            throw "$Path has $($errors.Count) error(s):$([Environment]::NewLine)$list"
        }
    }
    return Read-InfrastructureFile $Path
}

Export-ModuleMember -Function Import-AzlInfrastructure, Test-AzlInfrastructure, Get-AzlInfrastructureValue, Get-AzlManagementIpAssignment, Get-AzlManagementMode, Test-AzlProvisioningDhcpPort, Get-AzlArcMachineName, Get-AzlNodeNetworkAdapter, Get-AzlManagementAdapter, Get-AzlBiosSetting, Get-AzlBiosProvisioningOverride, Get-AzlManagementStaticMethod, Get-AzlInfrastructureScope, Get-AzlSiteIpRange
