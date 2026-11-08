#Requires -Version 7.0
# Fakes for the adapter model tests: three machines of different NIC brands, whose operating systems name the same physical adapters differently
# from node to node (the install method, the BIOS and the driver decide the names). Nothing here touches a node, Azure or Active Directory.
#
# A port is identified by its MAC. Its key (Key) is the name in nodes[].network_adapters[].name that intents and storage networks use. Its OS name differs per node
# (OsNames, in the order of Ports, and deliberately not in the order the BMC lists them: names must never be matched by position).
# MACs use the documentation range 00:00:5E:00:5x:yy: x the fixture, yy node and port.
Set-StrictMode -Version Latest

function Get-NicMac {
    param([int]$Fixture, [int]$Node, [int]$Port)
    '00:00:5E:00:5{0:X}:{1:X}{2:X}' -f $Fixture, $Node, $Port
}

function Get-NicBrandFixture {
    <#
    .SYNOPSIS
        The brand fixtures: Id, Title, Ports (Key, Slot, PortIndex, Vendor, Model, Speed, Rdma, Roles, Pci), Intents, Storage, OsNames (node -> names in Ports order),
        Override (key -> the name the user wants, for the opt-in rename).
    #>
    [CmdletBinding()]
    param()
    @(
        @{
            Id = 'dell-mellanox-broadcom'; Index = 1
            Title = 'A Dell server: two Mellanox cards and a Broadcom LOM'
            Ports = @(
                @{ Key = 'Embedded NIC 1'; Slot = 'Embedded'; PortIndex = 1; Vendor = 'Broadcom Inc.'; Model = 'Broadcom 5720 1GbE LOM'; Speed = 1; Roles = @('unused'); Pci = @(25, 0, 0) }
                @{ Key = 'Embedded NIC 2'; Slot = 'Embedded'; PortIndex = 2; Vendor = 'Broadcom Inc.'; Model = 'Broadcom 5720 1GbE LOM'; Speed = 1; Roles = @('unused'); Pci = @(25, 0, 1) }
                @{ Key = 'Slot 3 Port 1'; Slot = 'Slot 3'; PortIndex = 1; Vendor = 'Mellanox Technologies'; Model = 'ConnectX-6 Lx'; Speed = 25; Roles = @('management', 'compute'); Pci = @(59, 0, 0) }
                @{ Key = 'Slot 3 Port 2'; Slot = 'Slot 3'; PortIndex = 2; Vendor = 'Mellanox Technologies'; Model = 'ConnectX-6 Lx'; Speed = 25; Roles = @('management', 'compute'); Pci = @(59, 0, 1) }
                @{ Key = 'Slot 6 Port 1'; Slot = 'Slot 6'; PortIndex = 1; Vendor = 'Mellanox Technologies'; Model = 'ConnectX-6 Dx'; Speed = 100; Rdma = 'roce_v2'; Roles = @('storage'); Pci = @(94, 0, 0) }
                @{ Key = 'Slot 6 Port 2'; Slot = 'Slot 6'; PortIndex = 2; Vendor = 'Mellanox Technologies'; Model = 'ConnectX-6 Dx'; Speed = 100; Rdma = 'roce_v2'; Roles = @('storage'); Pci = @(94, 0, 1) }
            )
            Intents = @(@{ Name = 'mgmt_compute'; Traffic = @('management', 'compute'); Ports = @('Slot 3 Port 1', 'Slot 3 Port 2') }, @{ Name = 'storage'; Traffic = @('storage'); Ports = @('Slot 6 Port 1', 'Slot 6 Port 2') })
            Storage = @(@{ Name = 'StorageNetwork1'; Port = 'Slot 6 Port 1'; Vlan = 711 }, @{ Name = 'StorageNetwork2'; Port = 'Slot 6 Port 2'; Vlan = 712 })
            # Node 1 was installed from the ISO (names by position), node 2 by ZTP (names by slot): the order differs from the BMC's.
            OsNames = @{
                'iic-n01' = @('NIC2', 'NIC1', 'Port1', 'Port2', 'Port3', 'Port4')
                'iic-n02' = @('Embedded NIC 2', 'Embedded NIC 1', 'SLOT 3 Port 1', 'SLOT 3 Port 2', 'SLOT 6 Port 1', 'SLOT 6 Port 2')
            }
            Override = @{ 'Slot 3 Port 1' = 'Mgmt1'; 'Slot 3 Port 2' = 'Mgmt2'; 'Slot 6 Port 1' = 'Storage1'; 'Slot 6 Port 2' = 'Storage2' }
        }
        @{
            Id = 'intel-2port'; Index = 2
            Title = 'An Intel-only machine with two ports, one converged intent'
            Ports = @(
                @{ Key = 'Slot 1 Port 1'; Slot = 'Slot 1'; PortIndex = 1; Vendor = 'Intel Corporation'; Model = 'Intel E810-XXVDA2'; Speed = 25; Rdma = 'iwarp'; Roles = @('management', 'compute', 'storage'); Pci = @(65, 0, 0) }
                @{ Key = 'Slot 1 Port 2'; Slot = 'Slot 1'; PortIndex = 2; Vendor = 'Intel Corporation'; Model = 'Intel E810-XXVDA2'; Speed = 25; Rdma = 'iwarp'; Roles = @('management', 'compute', 'storage'); Pci = @(65, 0, 1) }
            )
            Intents = @(@{ Name = 'converged'; Traffic = @('management', 'compute', 'storage'); Ports = @('Slot 1 Port 1', 'Slot 1 Port 2') })
            Storage = @(@{ Name = 'StorageNetwork1'; Port = 'Slot 1 Port 1'; Vlan = 711 }, @{ Name = 'StorageNetwork2'; Port = 'Slot 1 Port 2'; Vlan = 712 })
            OsNames = @{
                'iic-n01' = @('Ethernet', 'Ethernet 2')
                'iic-n02' = @('Ethernet 4', 'Ethernet 3')
            }
            Override = @{ 'Slot 1 Port 1' = 'Port-A'; 'Slot 1 Port 2' = 'Port-B' }
        }
        @{
            Id = 'marvell-qlogic-six-port-mix'; Index = 3
            Title = 'Six ports from three makes (Marvell/QLogic, Chelsio, Intel), keys that follow no vendor pattern'
            Ports = @(
                @{ Key = 'lom-p1'; Slot = 'Embedded'; PortIndex = 1; Vendor = 'Intel Corporation'; Model = 'Intel I350'; Speed = 1; Roles = @('unused'); Pci = @(3, 0, 0) }
                @{ Key = 'lom-p2'; Slot = 'Embedded'; PortIndex = 2; Vendor = 'Intel Corporation'; Model = 'Intel I350'; Speed = 1; Roles = @('unused'); Pci = @(3, 0, 1) }
                @{ Key = 'ocp-p1'; Slot = 'OCP 1'; PortIndex = 1; Vendor = 'Marvell Technology'; Model = 'QLogic FastLinQ QL41262'; Speed = 25; Roles = @('management', 'compute'); Pci = @(26, 0, 0) }
                @{ Key = 'ocp-p2'; Slot = 'OCP 1'; PortIndex = 2; Vendor = 'Marvell Technology'; Model = 'QLogic FastLinQ QL41262'; Speed = 25; Roles = @('management', 'compute'); Pci = @(26, 0, 1) }
                @{ Key = 'pcie2-p1'; Slot = 'Slot 2'; PortIndex = 1; Vendor = 'Chelsio Communications'; Model = 'Chelsio T6225-CR'; Speed = 25; Rdma = 'iwarp'; Roles = @('storage'); Pci = @(130, 0, 0) }
                @{ Key = 'pcie2-p2'; Slot = 'Slot 2'; PortIndex = 2; Vendor = 'Chelsio Communications'; Model = 'Chelsio T6225-CR'; Speed = 25; Rdma = 'iwarp'; Roles = @('storage'); Pci = @(130, 0, 1) }
            )
            Intents = @(@{ Name = 'mgmt_compute'; Traffic = @('management', 'compute'); Ports = @('ocp-p1', 'ocp-p2') }, @{ Name = 'storage'; Traffic = @('storage'); Ports = @('pcie2-p1', 'pcie2-p2') })
            Storage = @(@{ Name = 'StorageNetwork1'; Port = 'pcie2-p1'; Vlan = 711 }, @{ Name = 'StorageNetwork2'; Port = 'pcie2-p2'; Vlan = 712 })
            OsNames = @{
                'iic-n01' = @('Ethernet 5', 'Ethernet 6', 'Ethernet', 'Ethernet 2', 'Ethernet 3', 'Ethernet 4')
                'iic-n02' = @('Port5', 'Port4', 'Port2', 'Port3', 'Port0', 'Port1')
            }
            Override = @{ 'ocp-p1' = 'Mgmt 1'; 'ocp-p2' = 'Mgmt 2'; 'pcie2-p1' = 'Storage 1'; 'pcie2-p2' = 'Storage 2' }
        }
    )
}

function Set-NicFixtureOnInfra {
    <#
    .SYNOPSIS
        Puts a brand fixture on an infrastructure (the S2D shape of tests/fixtures/infrastructure.fc-san.yml): every node's network_adapters, the intents and the storage networks.
        -WithOverride adds os_name_override to the fixture's ports that have one. The management port is the first port with the management role, on the first IP of the node.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infra, [Parameter(Mandatory)][hashtable]$Fixture, [switch]$WithOverride)
    $Infra.scenario.storage_architecture = 's2d'
    $Infra.Remove('storage') | Out-Null
    $Infra['storage'] = [ordered]@{ configuration_mode = 'express' }
    $Infra.networking.Remove('cluster_networks')
    $Infra.networking.intents = @($Fixture.Intents | ForEach-Object { [ordered]@{ name = $_.Name; traffic = @($_.Traffic); adapters = @($_.Ports) } })
    $Infra.networking['storage'] = [ordered]@{ auto_ip = $true; networks = @($Fixture.Storage | ForEach-Object { [ordered]@{ name = $_.Name; adapter = $_.Port; vlan_id = $_.Vlan } }) }
    $ips = @{ 'iic-n01' = '192.0.2.11'; 'iic-n02' = '192.0.2.12' }
    $nodeIndex = 0
    foreach ($node in @($Infra.nodes)) {
        $nodeIndex++
        $mgmtKey = ($Fixture.Ports | Where-Object { 'management' -in $_.Roles } | Select-Object -First 1).Key
        $list = [System.Collections.Generic.List[object]]::new()
        $portIndex = 0
        foreach ($p in $Fixture.Ports) {
            $portIndex++
            $a = [ordered]@{ name = $p.Key; mac_address = (Get-NicMac $Fixture.Index $nodeIndex $portIndex); slot = $p.Slot; port_index = $p.PortIndex; pci_location = [ordered]@{ bus = $p.Pci[0]; device = $p.Pci[1]; function = $p.Pci[2] }
                vendor = $p.Vendor; model = $p.Model; speed_gbps = $p.Speed }
            if ($p.ContainsKey('Rdma')) { $a.rdma = $p.Rdma }
            $a.roles = @($p.Roles)
            if ($p.Key -eq $mgmtKey) { $a.ip_assignment = 'static'; $a.ip_address = $ips[[string]$node.name] } else { $a.ip_assignment = 'none' }
            if ($WithOverride -and $Fixture.Override.ContainsKey($p.Key)) { $a.os_name_override = $Fixture.Override[$p.Key] }
            $list.Add($a)
        }
        $node['network_adapters'] = $list.ToArray()
        if ($node.Contains('san')) { $node.Remove('san') }
    }
    $Infra
}

function Get-NicNodeState {
    <#
    .SYNOPSIS
        What the Read script would return for the nics of one node of a fixture: the adapters with the node's own OS names (-Name overrides them per MAC), no address
        except the management port's. -Extra adds adapters the file does not list.
    #>
    param([Parameter(Mandatory)][hashtable]$Fixture, [Parameter(Mandatory)][int]$NodeIndex, [string[]]$OsName, [hashtable]$NameByMac = @{}, [object[]]$Extra = @(), [string]$ManagementIp = '192.0.2.11')
    $names = if ($OsName) { $OsName } else { $Fixture.OsNames["iic-n0$NodeIndex"] }
    $mgmtKey = ($Fixture.Ports | Where-Object { 'management' -in $_.Roles } | Select-Object -First 1).Key
    $rows = for ($i = 0; $i -lt $Fixture.Ports.Count; $i++) {
        $p = $Fixture.Ports[$i]
        $mac = ((Get-NicMac $Fixture.Index $NodeIndex ($i + 1)) -replace ':', '').ToLowerInvariant()
        $isMgmt = $p.Key -eq $mgmtKey
        [pscustomobject]@{
            n = $(if ($NameByMac.ContainsKey($mac)) { $NameByMac[$mac] } else { $names[$i] }); mac = $mac; st = $(if ($p.Roles -contains 'unused') { 'Disconnected' } else { 'Up' }); pci = 'PCI\VEN_0000&DEV_0000'; drv = '1.0'
            desc = "$($p.Vendor) $($p.Model)"; dhcp = 'Disabled'; ips = $(if ($isMgmt) { @("$ManagementIp/24/Manual") } else { @() }); gw = $(if ($isMgmt) { @('192.0.2.1') } else { @() })
            dns = $(if ($isMgmt) { @('192.0.2.4', '192.0.2.5') } else { @() }); vlan = $null; hwif = $true
            loc = [pscustomobject]@{ bus = $p.Pci[0]; device = $p.Pci[1]; function = $p.Pci[2] }
        }
    }
    @($rows) + @($Extra)
}
