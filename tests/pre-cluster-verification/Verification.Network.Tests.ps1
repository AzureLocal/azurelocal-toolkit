#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pre-cluster verification, NETWORK (NW-) checks. Fakes only: no Azure, no Active Directory, no node.

BeforeAll {
    . ([IO.Path]::Combine($PSScriptRoot, 'Verification.NodeFixtures.ps1'))
    $script:Mod = Import-VerModule -Name Network
    function Invoke-VerRun([string]$Id, $World, $Infra, [hashtable]$Settings = @{}, [hashtable]$Adapter = @{}) {
        $ctx = New-VerContext -Module $script:Mod -Infra $Infra -World $World -Settings $Settings -Adapter $Adapter
        Invoke-VerCheck -Module $script:Mod -Id $Id -Context $ctx
    }
    function New-VerFresh { $i = New-VerInfra; $w = New-VerWorld -Infra $i; [pscustomobject]@{ Infra = $i; World = $w } }
    function Get-VerNic($World, [string]$Node, [string]$Name) { $World.Snapshot[$Node].nics | Where-Object n -EQ $Name }
}

Describe 'Contract' {
    It 'exports the two commands and sixteen well formed definitions' {
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationCheckDefinition'
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationAdapterDefault'
        $defs = Get-VerDefinition -Module $script:Mod
        $defs.Count | Should -Be 16
        foreach ($d in $defs) {
            $d.Id | Should -Match '^NW-\d{3}$'; $d.Category | Should -Be 'network'; $d.Title | Should -Not -BeNullOrEmpty; $d.Source | Should -Not -BeNullOrEmpty
            $d.Blocking | Should -BeOfType [bool]; $d.Applies | Should -BeOfType [scriptblock]; $d.Run | Should -BeOfType [scriptblock]
        }
    }
    It 'a healthy world passes every NETWORK check with ONE remote call per node' {
        $f = New-VerFresh
        $ctx = New-VerContext -Module $script:Mod -Infra $f.Infra -World $f.World
        $bad = foreach ($d in (Get-VerDefinition -Module $script:Mod)) { foreach ($r in (Invoke-VerCheck -Module $script:Mod -Id $d.Id -Context $ctx)) { if ($r.Status -notin 'Passed', 'NotApplicable') { "$($d.Id) $($r.Status): $($r.Message)" } } }
        $bad | Should -BeNullOrEmpty
        $f.World.Calls.Count | Should -Be 2
    }
}

Describe 'NW-001 intents against adapters' {
    It 'Passed when every adapter exists on every node and is Up' { $f = New-VerFresh; (Invoke-VerRun 'NW-001' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'finds the NIC of a file port by MAC, so a different OS name on one node is not a missing adapter here (NW-013 reports the names)' {
        $f = New-VerFresh; (Get-VerNic $f.World 'n02' 'Port3').n = 'SLOT 6 Port 2'
        $r = Invoke-VerRun 'NW-001' $f.World $f.Infra
        ($r | Where-Object Node -EQ 'n02').Status | Should -Be 'Passed'
    }
    It 'Failed when the link is down' { $f = New-VerFresh; (Get-VerNic $f.World 'n01' 'Port2').st = 'Disconnected'; (Invoke-VerRun 'NW-001' $f.World $f.Infra | Where-Object Node -EQ 'n01').Message | Should -Match 'Disconnected' }
    It 'Warning for an intent with one adapter' {
        $f = New-VerFresh; $f.Infra.networking.intents[0].adapters = @('Port0')
        @(Invoke-VerRun 'NW-001' $f.World $f.Infra | Where-Object { $_.Status -eq 'Warning' -and $_.Node -eq '*' }).Count | Should -Be 1
    }
    It 'Failed when an adapter is in two intents' { $f = New-VerFresh; $f.Infra.networking.intents[1].adapters = @('Port1', 'Port2'); @(Invoke-VerRun 'NW-001' $f.World $f.Infra | Where-Object { $_.Status -eq 'Failed' -and $_.Node -eq '*' }).Count | Should -Be 1 }
    It 'Failed when the file has no intent' { $f = New-VerFresh; $f.Infra.networking.intents = @(); (Invoke-VerRun 'NW-001' $f.World $f.Infra)[0].Status | Should -Be 'Failed' }
}

Describe 'NW-002 RDMA only for storage (the lab failure: RDMA operational check on a management intent)' {
    It 'Passed: management asks for no RDMA, storage adapters are RDMA capable' { $f = New-VerFresh; (Invoke-VerRun 'NW-002' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'Failed when a management intent asks for Network Direct on adapters that are not RDMA capable, with the file setting as the fix' {
        $f = New-VerFresh; $f.Infra.networking.intents[0].overrides = @{ adapter = @{ network_direct = $true } }
        $r = Invoke-VerRun 'NW-002' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'RDMA operational check'
        $r.Remedy | Should -Match 'network_direct: false'
    }
    It 'Warning when a management intent asks for RDMA on capable adapters (not needed)' {
        $f = New-VerFresh; $f.Infra.networking.intents[0].overrides = @{ adapter = @{ network_direct = $true } }
        foreach ($n in 'Port0', 'Port1') { (Get-VerNic $f.World 'n01' $n).rdmaCapable = $true }
        (Invoke-VerRun 'NW-002' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning'
    }
    It 'Warning when RDMA is enabled but not operational on a management adapter' {
        $f = New-VerFresh; $n = Get-VerNic $f.World 'n01' 'Port0'; $n.rdmaCapable = $true; $n.rdmaEnabled = $true; $n.rdmaOp = $false
        (Invoke-VerRun 'NW-002' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning'
    }
    It 'Failed when a storage adapter is not RDMA capable' {
        $f = New-VerFresh; (Get-VerNic $f.World 'n02' 'Port3').rdmaCapable = $false
        $r = Invoke-VerRun 'NW-002' $f.World $f.Infra | Where-Object Node -EQ 'n02'
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'Port3'
    }
    It 'Warning when storage has Network Direct switched off' {
        $f = New-VerFresh; $f.Infra.networking.intents[1].overrides = @{ adapter = @{ network_direct = $false } }
        (Invoke-VerRun 'NW-002' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning'
    }
}

Describe 'NW-003 link speed' {
    It 'Passed at 25 Gbps' { $f = New-VerFresh; (Invoke-VerRun 'NW-003' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'Failed for a storage adapter at 1 Gbps' { $f = New-VerFresh; (Get-VerNic $f.World 'n01' 'Port2').speed = 1000000000; (Invoke-VerRun 'NW-003' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'the minimum is a setting' { $f = New-VerFresh; (Invoke-VerRun 'NW-003' $f.World $f.Infra -Settings @{ verificationMinLinkGbps = 40 } | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'Failed for asymmetric adapters in one intent' { $f = New-VerFresh; (Get-VerNic $f.World 'n01' 'Port3').speed = 10000000000; (Invoke-VerRun 'NW-003' $f.World $f.Infra | Where-Object Node -EQ 'n01').Message | Should -Match 'different speeds' }
}

Describe 'NW-004 management network' {
    It 'Passed' { $f = New-VerFresh; (Invoke-VerRun 'NW-004' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'Failed when no adapter holds the address of the file' { $f = New-VerFresh; (Get-VerNic $f.World 'n01' 'Port0').ips = @('192.0.2.99'); (Invoke-VerRun 'NW-004' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'Failed when DHCP is enabled on the management adapter' { $f = New-VerFresh; (Get-VerNic $f.World 'n01' 'Port0').dhcp = 'Enabled'; (Invoke-VerRun 'NW-004' $f.World $f.Infra | Where-Object Node -EQ 'n01').Message | Should -Match 'DHCP' }
    It 'Failed on another default gateway' { $f = New-VerFresh; (Get-VerNic $f.World 'n02' 'Port0').gw = @('192.0.2.254'); (Invoke-VerRun 'NW-004' $f.World $f.Infra | Where-Object Node -EQ 'n02').Status | Should -Be 'Failed' }
    It 'Failed when no DNS server answers on 53; Warning when only the gateway does not ping' {
        $f = New-VerFresh; foreach ($t in $f.World.Snapshot['n01'].tcp) { $t.ok = $false }
        (Invoke-VerRun 'NW-004' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed'
        $g = New-VerFresh; $g.World.Snapshot['n01'].ping[0].ok = $false
        (Invoke-VerRun 'NW-004' $g.World $g.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning'
    }
}

Describe 'NW-005 outbound endpoints and NW-006 proxy' {
    It 'NW-005 Passed when every documented endpoint answers, and says what it did not test (wildcards)' {
        $f = New-VerFresh
        $r = Invoke-VerRun 'NW-005' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Passed'; $r.Message | Should -Match 'wildcards'
    }
    It 'NW-005 Failed for a documented required endpoint that does not answer' {
        $f = New-VerFresh; $e = $f.World.Snapshot['n01'].https | Where-Object { $_.u -eq 'https://management.azure.com' }; $e.ok = $false; $e.err = 'The operation timed out'
        $r = Invoke-VerRun 'NW-005' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'management.azure.com'
    }
    It 'NW-005 only warns for a documented optional endpoint (a revocation list host)' {
        $f = New-VerFresh; $e = $f.World.Snapshot['n01'].tcp | Where-Object { $_.p -eq 80 } | Select-Object -First 1; $e.ok = $false
        $r = Invoke-VerRun 'NW-005' $f.World $f.Infra | Where-Object Node -EQ 'n01'; $r.Status | Should -Be 'Warning' -Because $r.Message
    }
    It 'NW-005 never asks for a host that is not in the documented list (eastus.his.arc.azure.com, dp.kubernetesconfiguration.azure.com)' {
        $hosts = @(Get-AzlEndpointSet -Location 'eastus' | ForEach-Object Host)
        $hosts | Should -Contain 'eus.his.arc.azure.com'
        $hosts | Should -Not -Contain 'eastus.his.arc.azure.com'
        $hosts | Should -Not -Contain 'dp.kubernetesconfiguration.azure.com'
        @($hosts | Where-Object { $_ -like '*`**' }) | Should -BeNullOrEmpty
    }
    It 'NW-005 is Skipped when the node did not probe a documented endpoint' {
        $f = New-VerFresh; $s = $f.World.Snapshot['n01']; $s.https = @($s.https | Select-Object -First 3)
        (Invoke-VerRun 'NW-005' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Skipped'
    }
    It 'NW-005 NotApplicable for a disconnected design' { $f = New-VerFresh; $f.Infra.scenario.connectivity = 'disconnected'; (Invoke-VerRun 'NW-005' $f.World $f.Infra).Status | Should -Be 'NotApplicable' }
    It 'NW-006 Passed with no proxy on a direct path' { $f = New-VerFresh; (Invoke-VerRun 'NW-006' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'NW-006 Warning for a proxy on the node while the path is direct' { $f = New-VerFresh; $f.World.Snapshot['n01'].proxy.winhttp = 'Current WinHTTP proxy settings: Proxy Server(s) : proxy.example.test:3128'; (Invoke-VerRun 'NW-006' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning' }
    It 'NW-006 Failed when the path is proxy and the file has no URL; Failed for a PAC file' {
        $f = New-VerFresh; $f.Infra.scenario.outbound_path = 'proxy'
        (Invoke-VerRun 'NW-006' $f.World $f.Infra | Where-Object { $_.Node -eq '*' })[0].Status | Should -Be 'Failed'
        $g = New-VerFresh; $g.Infra.scenario.outbound_path = 'proxy'; $g.Infra.networking.outbound = @{ proxy = @{ url = 'http://proxy.example.test/proxy.pac' } }
        (Invoke-VerRun 'NW-006' $g.World $g.Infra | Where-Object { $_.Node -eq '*' })[0].Message | Should -Match 'PAC'
    }
    It 'NW-006 Passed when the WinHTTP proxy is the file''s, Failed when it is not' {
        $f = New-VerFresh; $f.Infra.scenario.outbound_path = 'proxy'; $f.Infra.networking.outbound = @{ proxy = @{ url = 'http://proxy.example.test:3128' } }
        $f.World.Snapshot['n01'].proxy.winhttp = 'Proxy Server(s) : proxy.example.test:3128'
        (Invoke-VerRun 'NW-006' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Passed'
        (Invoke-VerRun 'NW-006' $f.World $f.Infra | Where-Object Node -EQ 'n02').Status | Should -Be 'Failed'
    }
}

Describe 'NW-007 ClusSvc exclusions, NW-008 Remote NDIS' {
    It 'NW-007 Warning (not blocking) when the cluster service excludes adapters' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].clusSvc = @{ ExcludeAdaptersByDescription = 'Mellanox ConnectX-6' }
        (Invoke-VerRun 'NW-007' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning'
        (Get-VerDefinition -Module $script:Mod -Id 'NW-007').Blocking | Should -BeFalse
    }
    It 'NW-008 Warning for a Remote NDIS device that is Up and not excluded' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].remoteNdis = @(@{ n = 'Ethernet 3'; desc = 'Remote NDIS Compatible Device'; st = 'Up'; admin = 'Up' })
        $r = Invoke-VerRun 'NW-008' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Warning'; $r.Remedy | Should -Match 'ExcludeAdaptersByDescription'
    }
    It 'NW-008 Passed when the Remote NDIS device is excluded from the cluster service' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].remoteNdis = @(@{ n = 'Ethernet 3'; desc = 'Remote NDIS Compatible Device'; st = 'Up'; admin = 'Up' }); $f.World.Snapshot['n01'].clusSvc = @{ ExcludeAdaptersByDescription = 'Remote NDIS Compatible Device' }
        (Invoke-VerRun 'NW-008' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Passed'
    }
}

Describe 'NW-009 to NW-012' {
    It 'NW-009 Failed for the inbox Microsoft driver on an intent adapter' { $f = New-VerFresh; (Get-VerNic $f.World 'n01' 'Port2').drvProv = 'Microsoft'; (Invoke-VerRun 'NW-009' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'NW-010 Failed when a Network ATC intent is left' { $f = New-VerFresh; $f.World.Snapshot['n01'].vms.intents = @('old'); (Invoke-VerRun 'NW-010' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'NW-010 Warning for a stray virtual switch on an intent adapter' { $f = New-VerFresh; $f.World.Snapshot['n01'].vms.switches = @(@{ n = 'ConvergedSwitch(mgmt)'; uplinks = @('Dell LOM 25G') }); (Invoke-VerRun 'NW-010' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning' }
    It 'NW-011 Warning for a disconnected adapter that is still enabled' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].nics += @{ n = 'Port4'; desc = 'Dell LOM'; st = 'Disconnected'; admin = 'Up'; speed = 0; mac = 'x'; drvProv = 'Dell'; drvVer = '1'; idx = 9; mtu = 1514; jumbo = '1514'; rdmaCapable = $false; rdmaEnabled = $false; rdmaOp = $null; ips = @(); gw = @(); dhcp = 'Disabled' }
        (Invoke-VerRun 'NW-011' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning'
    }
    It 'NW-012 Warning for jumbo frames on a management adapter' { $f = New-VerFresh; (Get-VerNic $f.World 'n01' 'Port0').jumbo = '9014'; (Invoke-VerRun 'NW-012' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning' }
    It 'a node that cannot be read is Skipped with the reason, not Failed' {
        $f = New-VerFresh; $f.World.Down['n02'] = 'connection refused'
        $r = Invoke-VerRun 'NW-009' $f.World $f.Infra
        ($r | Where-Object Node -EQ 'n02').Status | Should -Be 'Skipped'; ($r | Where-Object Node -EQ 'n02').Message | Should -Match 'connection refused'
        $f.World.Calls.Count | Should -Be 2
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# NW-013: the physical ports against the file. Nothing here may depend on how a port is named: two layouts with completely different names.
# ---------------------------------------------------------------------------------------------------------------------
Describe 'NW-013 physical ports against the file (found by MAC, name-agnostic)' {
    BeforeAll {
        function New-PortWorld {
            <# A cluster of -Names (one file name per port, the same on every node), -OsNames per node (the names the OS gave the NICs), roles per port. #>
            param([string[]]$Nodes, [string[]]$Names, [hashtable]$OsNames, [string[]]$Roles, [string[]]$Macs, [System.Collections.IDictionary]$Intents, [switch]$ClusterNets)
            $f = New-VerFresh
            $f.Infra.nodes = @(foreach ($n in $Nodes) {
                    $k = 0
                    [ordered]@{ name = $n; network_adapters = @(foreach ($name in $Names) {
                                $r = $Roles[$k]; $mac = $Macs[$k]; $k++
                                $o = [ordered]@{ name = $name; mac_address = $mac; roles = @($r -split '\+'); speed_gbps = 25 }
                                if ('management' -in $o.roles) { $o.ip_address = "192.0.2.$(10 + [array]::IndexOf($Nodes, $n))" }
                                $o
                            }) }
                })
            # management ip only on the first management port of each node
            foreach ($n in $f.Infra.nodes) { $seen = $false; foreach ($pt in $n.network_adapters) { if ('management' -in $pt.roles) { if ($seen) { $pt.Remove('ip_address') } else { $seen = $true } } elseif ($pt.Contains('ip_address')) { $pt.Remove('ip_address') } } }
            $f.Infra.networking.intents = @(foreach ($k in $Intents.Keys) { [ordered]@{ name = $k; traffic = @($Intents[$k].Traffic); adapters = @($Intents[$k].Adapters) } })
            $f.Infra.networking.storage = [ordered]@{ networks = @() }; $f.Infra.networking.management.vlan_id = 0
            if ($ClusterNets) { $f.Infra.networking.cluster_networks = @() }
            $f.World = New-VerWorld -Infra $f.Infra
            foreach ($n in $Nodes) {
                $snap = $f.World.Snapshot[$n]
                $ip = ($f.Infra.nodes | Where-Object name -EQ $n).network_adapters | Where-Object { $_.Contains('ip_address') } | Select-Object -First 1
                $snap.nics = @(for ($k = 0; $k -lt $Names.Count; $k++) {
                        @{ n = $OsNames[$n][$k]; desc = 'Vendor 25G NIC'; st = 'Up'; admin = 'Up'; speed = 25000000000; mac = (($Macs[$k]) -replace '[^0-9A-Fa-f]', '').ToLowerInvariant(); drvProv = 'Vendor'; drvVer = '1'; idx = $k + 4; mtu = 1514; jumbo = '1514'
                            rdmaCapable = ('storage' -in ($Roles[$k] -split '\+')); rdmaEnabled = ('storage' -in ($Roles[$k] -split '\+')); rdmaOp = $true; ips = @($(if ($k -eq 0 -and $ip) { $ip.ip_address })); gw = @($(if ($k -eq 0) { '192.0.2.1' })); dhcp = 'Disabled'; vlan = '0' }
                    })
                $snap.dns = @(@{ n = $OsNames[$n][0]; idx = 4; servers = @('192.0.2.4', '192.0.2.5') })
            }
            $f
        }
        $script:LabNames = 'Port1', 'Port2', 'Port3', 'Port4', 'Port5', 'Port6'
        $script:LabRoles = 'management', 'management', 'compute', 'storage', 'storage', 'compute'
        $script:LabMacs = 'aa:bb:cc:00:00:01', 'aa:bb:cc:00:00:02', 'aa:bb:cc:00:00:03', 'aa:bb:cc:00:00:04', 'aa:bb:cc:00:00:05', 'aa:bb:cc:00:00:06'
        $script:LabIntents = [ordered]@{
            mgmt    = @{ Traffic = @('management'); Adapters = @('Port1', 'Port2') }
            compute = @{ Traffic = @('compute'); Adapters = @('Port3', 'Port6') }
            storage = @{ Traffic = @('storage'); Adapters = @('Port4', 'Port5') }
        }
        $script:AlienNames = 'Slot 3 Port 1', 'NIC1', 'Embedded NIC 2', 'SLOT 6 PORT 2', 'Ethernet 3', 'OCP 1 Port 1'
        $script:AlienIntents = [ordered]@{
            mgmt    = @{ Traffic = @('management'); Adapters = @('Slot 3 Port 1', 'NIC1') }
            compute = @{ Traffic = @('compute'); Adapters = @('Embedded NIC 2', 'OCP 1 Port 1') }
            storage = @{ Traffic = @('storage'); Adapters = @('SLOT 6 PORT 2', 'Ethernet 3') }
        }
        function New-Lab { New-PortWorld -Nodes 'lab-n01', 'lab-n02', 'lab-n03' -Names $script:LabNames -OsNames @{ 'lab-n01' = $script:LabNames; 'lab-n02' = $script:LabNames; 'lab-n03' = $script:LabNames } -Roles $script:LabRoles -Macs $script:LabMacs -Intents $script:LabIntents }
        function New-Alien { New-PortWorld -Nodes 'x1', 'x2' -Names $script:AlienNames -OsNames @{ x1 = 'Port0', 'Port1', 'Port2', 'Port3', 'Port4', 'Port5'; x2 = 'Port0', 'Port1', 'Port2', 'Port3', 'Port4', 'Port5' } -Roles $script:LabRoles -Macs $script:LabMacs -Intents $script:AlienIntents }
    }
    It 'the lab layout (3 nodes, management Port1+Port2, compute Port3+Port6, storage Port4+Port5) passes, with a table of every port' {
        $f = New-Lab
        $r = @(Invoke-VerRun 'NW-013' $f.World $f.Infra)
        ($r | ForEach-Object Status | Select-Object -Unique) | Should -Be 'Passed'
        $r.Count | Should -Be 3
        $r[0].Message | Should -Match "file 'Port1' \| MAC AA:BB:CC:00:00:01 \| OS 'Port1' \| Up \| 25G \| roles management \| intent mgmt"
        $r[0].Message | Should -Match "file 'Port5'"
    }
    It 'a layout with completely different names passes too: the file name and the OS name are reported side by side, never assumed equal' {
        $f = New-Alien
        $r = @(Invoke-VerRun 'NW-013' $f.World $f.Infra)
        ($r | ForEach-Object Status | Select-Object -Unique) | Should -Be 'Passed'
        $r[0].Message | Should -Match "file 'Slot 3 Port 1' \| MAC AA:BB:CC:00:00:01 \| OS 'Port0'"
        $r[0].Message | Should -Match "file 'Ethernet 3' \| MAC AA:BB:CC:00:00:05 \| OS 'Port4'"
        # and the other checks that go by intent adapters resolve through the MAC too
        (@(Invoke-VerRun 'NW-001' $f.World $f.Infra) | ForEach-Object Status | Select-Object -Unique) | Should -Be 'Passed'
    }
    It 'MACs match but the OS names differ per node: Failed across the nodes, naming the file port and both names' {
        $f = New-Alien
        (Get-VerNic $f.World 'x2' 'Port1').n = 'NIC-B'
        $r = @(Invoke-VerRun 'NW-013' $f.World $f.Infra)
        $cross = @($r | Where-Object { $_.Node -eq '*' -and $_.Status -eq 'Failed' })
        $cross.Count | Should -Be 1
        $cross[0].Message | Should -Match "File port 'NIC1' is 'Port1' on x1, 'NIC-B' on x2"
    }
    It 'names match but the MACs differ: the port is not on the node, Failed with the MACs the node has' {
        $f = New-Lab
        (Get-VerNic $f.World 'lab-n02' 'Port2').mac = 'ffeeddccbbaa'
        $r = @(Invoke-VerRun 'NW-013' $f.World $f.Infra | Where-Object Node -EQ 'lab-n02')
        $r[0].Status | Should -Be 'Failed'
        $r[0].Message | Should -Match "file port 'Port2' \(MAC AA:BB:CC:00:00:02\) is not on the node"
        $r[0].Message | Should -Match 'FF:EE:DD:CC:BB:AA'
        $r[0].Message | Should -Match 'NOT ON THE NODE'
    }
    It 'a port whose link is down is Failed when it is in an intent, and its speed must fit the role' {
        $f = New-Lab; (Get-VerNic $f.World 'lab-n01' 'Port4').st = 'Disconnected'
        (@(Invoke-VerRun 'NW-013' $f.World $f.Infra | Where-Object Node -EQ 'lab-n01')[0]).Message | Should -Match "'Port4' \('Port4'\) is Disconnected, not Up \(it is in intent storage\)"
        $g = New-Lab; (Get-VerNic $g.World 'lab-n03' 'Port3').speed = 1000000000
        (@(Invoke-VerRun 'NW-013' $g.World $g.Infra | Where-Object Node -EQ 'lab-n03')[0]).Message | Should -Match 'runs at 1 Gbps; intent compute'
    }
    It 'a virtual, USB or Remote NDIS device is not a physical port' {
        $f = New-Lab; (Get-VerNic $f.World 'lab-n01' 'Port6').desc = 'Remote NDIS Compatible Device'
        (@(Invoke-VerRun 'NW-013' $f.World $f.Infra | Where-Object Node -EQ 'lab-n01')[0]).Message | Should -Match 'virtual, USB or Remote NDIS'
    }
    It 'an intent that names a port the file does not list, an unused port in an intent, and a role without an intent are Failed' {
        $f = New-Lab; $f.Infra.networking.intents[2].adapters = @('Port4', 'PortX')
        (@(Invoke-VerRun 'NW-013' $f.World $f.Infra | Where-Object Node -EQ 'lab-n01')[0]).Message | Should -Match "intent storage names 'PortX', which the file does not list for lab-n01"
        $g = New-Lab; $g.Infra.networking.intents[2].adapters = @('Port4');
        (@(Invoke-VerRun 'NW-013' $g.World $g.Infra | Where-Object Node -EQ 'lab-n01')[0]).Message | Should -Match "port 'Port5' has the role storage in the file but is in no intent that carries storage"
        $h = New-Lab; foreach ($n in $h.Infra.nodes) { $n.network_adapters[5].roles = @('unused') }
        (@(Invoke-VerRun 'NW-013' $h.World $h.Infra | Where-Object Node -EQ 'lab-n01')[0]).Message | Should -Match "uses 'Port6', but the file marks that port unused"
    }
    It 'an intent whose port has other roles in the file, and an adapter in two intents, are Failed' {
        $f = New-Lab; $f.Infra.networking.intents[0].adapters = @('Port1', 'Port4')
        $m = (@(Invoke-VerRun 'NW-013' $f.World $f.Infra | Where-Object Node -EQ 'lab-n01')[0]).Message
        $m | Should -Match "port 'Port4' is in intent mgmt \(traffic management\) but the file gives it the roles storage"
        (@(Invoke-VerRun 'NW-013' $f.World $f.Infra) | Where-Object { $_.Node -eq '*' -and $_.Status -eq 'Failed' -and $_.Message -match 'more than one intent' }).Count | Should -Be 1
    }
    It 'the management address must be on the NIC the file puts it on' {
        $f = New-Lab
        $nics = $f.World.Snapshot['lab-n01'].nics
        $ip = $nics[0].ips; $nics[0].ips = @(); $nics[1].ips = $ip
        (@(Invoke-VerRun 'NW-013' $f.World $f.Infra | Where-Object Node -EQ 'lab-n01')[0]).Message | Should -Match 'is on .Port2., but the file puts it on port .Port1.'
    }
    It 'is Skipped, with the reason, for a port with no MAC in the file and when no OS configuration report is given' {
        $f = New-Lab; $f.Infra.nodes[0].network_adapters[2].Remove('mac_address')
        $r = @(Invoke-VerRun 'NW-013' $f.World $f.Infra | Where-Object Node -EQ 'lab-n01')[0]
        $r.Status | Should -Be 'Skipped'; $r.Message | Should -Match "file port 'Port3' has no mac_address"
        $g = New-Lab
        $ctx = New-VerContext -Module $script:Mod -Infra $g.Infra -World $g.World
        $ctx.OsReport = $null
        $x = @(Invoke-VerCheck -Module $script:Mod -Id 'NW-013' -Context $ctx | Where-Object Node -EQ 'lab-n01')[0]
        $x.Status | Should -Be 'Skipped'; $x.Message | Should -Match 'no OS configuration report was given'
    }
    It 'fails when the OS configuration report names the NIC differently from the node' {
        $f = New-Alien
        $ctx = New-VerContext -Module $script:Mod -Infra $f.Infra -World $f.World
        $ctx.OsReport.nodes[0].ports[0].osName = 'Renamed Since'
        $r = @(Invoke-VerCheck -Module $script:Mod -Id 'NW-013' -Context $ctx | Where-Object Node -EQ 'x1')[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match "the node calls the NIC 'Port0' but the OS configuration report says 'Renamed Since'"
    }
    It 'storage networks must sit on ports of the storage intent; a VLAN that differs from the file port is Failed' {
        $f = New-Alien
        $f.Infra.networking.cluster_networks = @([ordered]@{ name = 'cn-a'; adapter = 'SLOT 6 PORT 2'; vlan_id = 711 }, [ordered]@{ name = 'cn-b'; adapter = 'Slot 3 Port 1'; vlan_id = 712 })
        $m = (@(Invoke-VerRun 'NW-013' $f.World $f.Infra | Where-Object Node -EQ 'x1')[0]).Message
        $m | Should -Match "storage network 'cn-b' is on 'Slot 3 Port 1', which is not a port of the storage intent"
        $m | Should -Not -Match "storage network 'cn-a'"
        $g = New-Alien
        $g.Infra.nodes[0].network_adapters[3].vlan_id = 700
        $g.Infra.networking.cluster_networks = @([ordered]@{ name = 'cn-a'; adapter = 'SLOT 6 PORT 2'; vlan_id = 711 })
        (@(Invoke-VerRun 'NW-013' $g.World $g.Infra | Where-Object Node -EQ 'x1')[0]).Message | Should -Match "storage network 'cn-a' says VLAN 711, the file's port 'SLOT 6 PORT 2' says VLAN 700"
    }
    It 'no code path of the network or node modules assumes a port name (Port<n>, Slot, NIC ...)' {
        $dir = Join-Path $PSScriptRoot '..\..\scripts\common\arm-deployment\verification'
        foreach ($f in Get-ChildItem $dir -Filter 'AzlVerification.*.psm1') {
            $code = (Get-Content -LiteralPath $f.FullName -Raw)
            $code | Should -Not -Match "-(match|like|eq|ieq|ne)\s+['""]\^?Port\\d" -Because $f.Name
            $code | Should -Not -Match "\[regex\]::.*Port\\d" -Because $f.Name
        }
    }
}
Describe 'NW-014 storage adapters are bare (Azure Validate: StorageAdapterReadiness)' {
    It 'passes when the storage NICs carry no VLAN, no address and no gateway, and says Network ATC applies the storage VLANs' {
        $f = New-VerFresh
        $r = @(Invoke-VerRun 'NW-014' $f.World $f.Infra | Where-Object Node -EQ 'n01')[0]
        $r.Status | Should -Be 'Passed'
        $r.Message | Should -Match 'Network ATC applies the storage VLANs itself'
        $r.Message | Should -Match 'networking.storage.networks\[\].vlan_id'
    }
    It 'fails for a VLAN ID on the NIC (Get-NetAdapter or the advanced property), with the exact commands' {
        $f = New-VerFresh; (Get-VerNic $f.World 'n01' 'Port2').vlan = '712'; (Get-VerNic $f.World 'n01' 'Port3').vlanAdv = '713'
        $r = @(Invoke-VerRun 'NW-014' $f.World $f.Infra | Where-Object Node -EQ 'n01')[0]
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match "'Port2' \(file 'Port2'\) has a VLAN ID configured on the NIC \(vlan=712\)"
        $r.Message | Should -Match 'vlanAdv=713'
        $r.Remedy | Should -Match "Set-NetAdapterAdvancedProperty -Name 'Port2' -RegistryKeyword VlanID -RegistryValue 0; Restart-NetAdapter -Name 'Port2'"
        (@(Invoke-VerRun 'NW-014' $f.World $f.Infra | Where-Object Node -EQ 'n02')[0]).Status | Should -Be 'Passed'
    }
    It 'fails for a manual address, DHCP and a default gateway on a storage adapter, and for duplicate adapter names' {
        $f = New-VerFresh
        $n = Get-VerNic $f.World 'n01' 'Port2'; $n.ips = @('198.51.100.5'); $n.gw = @('198.51.100.1')
        (Get-VerNic $f.World 'n01' 'Port3').dhcp = 'Enabled'
        $m = (@(Invoke-VerRun 'NW-014' $f.World $f.Infra | Where-Object Node -EQ 'n01')[0]).Message
        $m | Should -Match 'has the IPv4 address 198.51.100.5 \(manual\)'
        $m | Should -Match 'has the default gateway 198.51.100.1'
        $m | Should -Match 'has DHCP enabled'
        $g = New-VerFresh; $dup = @{} + (Get-VerNic $g.World 'n02' 'Port2'); $g.World.Snapshot['n02'].nics = @($g.World.Snapshot['n02'].nics) + @($dup)
        (@(Invoke-VerRun 'NW-014' $g.World $g.Infra | Where-Object Node -EQ 'n02')[0]).Message | Should -Match 'exist\(s\) more than once on the node'
    }
    It 'resolves the storage adapters by MAC, whatever the names are' {
        $f = New-VerFresh
        foreach ($n in $f.Infra.nodes) { foreach ($a in $n.network_adapters) { $a.name = 'Slot 3 ' + $a.name } }
        foreach ($i in $f.Infra.networking.intents) { $i.adapters = @($i.adapters | ForEach-Object { 'Slot 3 ' + $_ }) }
        (Get-VerNic $f.World 'n01' 'Port3').vlan = '713'
        $r = @(Invoke-VerRun 'NW-014' $f.World $f.Infra | Where-Object Node -EQ 'n01')[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match "file 'Slot 3 Port3'"
    }
}

Describe 'NW-015 the VLAN plan of the file' {
    It 'is Skipped (blocking) when the file has no networking.vlans[]' {
        $f = New-VerFresh; $f.Infra.networking.Remove('vlans')
        $r = @(Invoke-VerRun 'NW-015' $f.World $f.Infra)[0]
        $r.Status | Should -Be 'Skipped'; $r.Message | Should -Match 'no networking.vlans'
    }
    It 'passes for the lab plan: management 711, storage 712 and 713, compute 717 allowed on the compute ports' {
        $f = New-VerFresh
        $r = @(Invoke-VerRun 'NW-015' $f.World $f.Infra)
        ($r | ForEach-Object Status | Select-Object -Unique) | Should -Be 'Passed'
        $r[0].Message | Should -Match 'management VLAN 711'
        $r[0].Message | Should -Match 'compute VLANs 717'
    }
    It 'fails on a VLAN id, a name and a subnet used twice, and on overlapping subnets' {
        $f = New-VerFresh; $v = $f.Infra.networking.vlans
        $v[2].id = 712; $v[3].name = 'Storage-A'; $v[3].subnet = '198.51.100.0/26'
        $m = (@(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object Status -EQ 'Failed')[0]).Message
        $m | Should -Match 'VLAN id 712 is used by more than one vlans'
        $m | Should -Match "the VLAN name 'storage-a' is used more than once"
        $m | Should -Match 'the subnet 198.51.100.0/26 is used by more than one'
        $g = New-VerFresh; $g.Infra.networking.vlans[3].subnet = '198.51.100.0/25'
        (@(Invoke-VerRun 'NW-015' $g.World $g.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match 'overlap'
    }
    It 'fails when the management subnet is in no VLAN, or in two' {
        $f = New-VerFresh; $f.Infra.networking.management.subnet = '10.9.9.0/24'; $f.Infra.networking.management.gateway = '10.9.9.1'
        (@(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match 'is in no vlans\[\] entry'
        $g = New-VerFresh; $g.Infra.networking.vlans = @($g.Infra.networking.vlans) + @([ordered]@{ name = 'wide'; id = 800; subnet = '192.0.0.0/16'; purpose = 'other' })
        (@(Invoke-VerRun 'NW-015' $g.World $g.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match 'belongs to more than one vlans'
    }
    It 'fails when a management port disagrees with the management VLAN, or networking.management.vlan_id disagrees with the ports' {
        $f = New-VerFresh; $f.Infra.nodes[0].network_adapters[0].vlan_id = 799
        (@(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match "management port 'Port0' of n01 says VLAN 799"
        $g = New-VerFresh; $g.Infra.networking.management.vlan_id = 0
        (@(Invoke-VerRun 'NW-015' $g.World $g.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match 'networking.management.vlan_id is 0'
    }
    It 'access ports mean untagged: the NIC VLAN must be 0, and the switch VLAN is the management VLAN' {
        $f = New-VerFresh
        foreach ($n in $f.Infra.nodes) { foreach ($a in @($n.network_adapters)[0..1]) { $a.vlan_mode = 'access'; $a.vlan_id = 711; $a.Remove('allowed_vlans') } }
        $f.Infra.networking.management.vlan_id = 0
        foreach ($s in $f.World.Snapshot.Values) { foreach ($nic in @($s.nics)[0..1]) { $nic.vlan = '0' } }
        $r = @(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object Status -EQ 'Failed')
        # access ports cannot carry the compute VLAN
        ($r | ForEach-Object Message) -join ' ' | Should -Match 'is an access port \(VLAN 711\), but the compute VLAN\(s\) 717 must reach it'
        ($r | ForEach-Object Message) -join ' ' | Should -Not -Match 'carries VLAN'
        (Get-VerNic $f.World 'n01' 'Port0').vlan = '711'
        (@(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object { $_.Node -eq 'n01' -and $_.Status -eq 'Failed' })[0]).Message | Should -Match "carries VLAN 711 on the NIC, the file says the host tags 0 \(access, untagged\)"
    }
    It 'fails when the NIC VLAN of a tagged management port is not the file''s' {
        $f = New-VerFresh; (Get-VerNic $f.World 'n02' 'Port0').vlan = '0'
        (@(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object { $_.Node -eq 'n02' -and $_.Status -eq 'Failed' })[0]).Message | Should -Match "carries VLAN 0 on the NIC, the file says the host tags 711"
    }
    It 'fails when a storage network VLAN is not in the plan, repeats, or is the management VLAN' {
        $f = New-VerFresh; $f.Infra.networking.storage.networks[0].vlan_id = 799
        (@(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match "storage network 'StorageNetwork1' uses VLAN 799, which is not in vlans"
        $g = New-VerFresh; $g.Infra.networking.storage.networks[1].vlan_id = 712
        (@(Invoke-VerRun 'NW-015' $g.World $g.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match 'VLAN 712 is used by more than one storage network'
        $h = New-VerFresh; $h.Infra.networking.storage.networks[0].vlan_id = 711
        (@(Invoke-VerRun 'NW-015' $h.World $h.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match 'uses the management VLAN 711'
    }
    It 'fails for a node address outside the management subnet and only warns for a DNS server outside it' {
        $f = New-VerFresh; $f.Infra.networking.management.gateway = '10.0.0.1'
        (@(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match 'the gateway 10.0.0.1 is outside the management subnet'
        $g = New-VerFresh; $g.Infra.networking.management.dns_servers = @('10.0.0.53')
        $w = @(Invoke-VerRun 'NW-015' $g.World $g.Infra | Where-Object { $_.Node -eq '*' })
        ($w | ForEach-Object Status) | Should -Contain 'Warning'
        ($w | ForEach-Object Status) | Should -Not -Contain 'Failed'
    }
    It 'is Skipped, never Passed, when the compute ports are tagged but the file lists no allowed VLANs' {
        $f = New-VerFresh; foreach ($n in $f.Infra.nodes) { foreach ($a in @($n.network_adapters)[0..1]) { $a.Remove('allowed_vlans') } }
        $r = @(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object Status -EQ 'Skipped')
        $r.Count | Should -Be 1
        $r[0].Message | Should -Match 'are tagged but the file lists no allowed VLANs'
        $r[0].Message | Should -Match 'allowed_vlans'
        (Get-VerDefinition -Module $script:Mod -Id 'NW-015').Blocking | Should -BeTrue
    }
    It 'fails when allowed_vlans misses the compute VLAN; the file is the authority, nothing is hard-coded' {
        $f = New-VerFresh; foreach ($n in $f.Infra.nodes) { foreach ($a in @($n.network_adapters)[0..1]) { $a.allowed_vlans = @(718) } }
        (@(Invoke-VerRun 'NW-015' $f.World $f.Infra | Where-Object Status -EQ 'Failed')[0]).Message | Should -Match "does not allow the compute VLAN\(s\) 717 \(allowed_vlans: 718\)"
        $g = New-VerFresh
        foreach ($v in $g.Infra.networking.vlans) { if ($v.name -eq 'compute') { $v.id = 730 } }
        foreach ($n in $g.Infra.nodes) { foreach ($a in @($n.network_adapters)[0..1]) { $a.allowed_vlans = @(730) } }
        (@(Invoke-VerRun 'NW-015' $g.World $g.Infra) | ForEach-Object Status | Select-Object -Unique) | Should -Be 'Passed'
    }
}

Describe 'NW-016 the switch port checklist (the gate cannot read a switch)' {
    It 'lists every port with switch_port data, with the VLANs the file expects, as a NotApplicable line that says to verify on the switch' {
        $f = New-VerFresh
        $r = @(Invoke-VerRun 'NW-016' $f.World $f.Infra)
        $r.Count | Should -Be 8
        ($r | ForEach-Object Status | Select-Object -Unique) | Should -Be 'NotApplicable'
        $first = $r | Where-Object { $_.Node -eq 'n01' -and $_.Message -match 'tor-a Ethernet1/1:' }
        $first.Message | Should -Match 'switch trunk/access config is not readable from here; verify against tor-a Ethernet1/1'
        $first.Message | Should -Match 'expected trunk, VLANs \[711, 717\]'
        $storage = $r | Where-Object { $_.Node -eq 'n01' -and $_.Message -match 'tor-a Ethernet1/3:' }
        $storage.Message | Should -Match 'VLANs \[712\]'
        (Get-VerDefinition -Module $script:Mod -Id 'NW-016').Blocking | Should -BeFalse
    }
    It 'the checklist function returns the rows the report carries (switch, port, node, file port, mode, VLANs, source)' {
        $f = New-VerFresh
        $ctx = New-VerContext -Module $script:Mod -Infra $f.Infra -World $f.World
        $rows = @(& $script:Mod.ExportedCommands['Get-AzlVerificationSwitchPortChecklist'] -Context $ctx)
        $rows.Count | Should -Be 8
        foreach ($p in 'switch', 'port', 'node', 'filePort', 'mac', 'roles', 'expectedMode', 'expectedVlans', 'hostTag', 'source') { $rows[0].PSObject.Properties.Name | Should -Contain $p }
        ($rows | Where-Object { $_.filePort -eq 'Port0' -and $_.node -eq 'n01' }).expectedVlans | Should -Be @(711, 717)
    }
    It 'says there is no checklist when the file has no switch_port data' {
        $f = New-VerFresh; foreach ($n in $f.Infra.nodes) { foreach ($a in $n.network_adapters) { $a.Remove('switch_port') } }
        $r = @(Invoke-VerRun 'NW-016' $f.World $f.Infra)
        $r.Count | Should -Be 1; $r[0].Message | Should -Match 'no switch_port data'
    }
}
