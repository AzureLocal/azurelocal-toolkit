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
    It 'exports the two commands and twelve well formed definitions' {
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationCheckDefinition'
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationAdapterDefault'
        $defs = Get-VerDefinition -Module $script:Mod
        $defs.Count | Should -Be 12
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
    It 'Failed when an adapter of an intent has another name on one node' {
        $f = New-VerFresh; (Get-VerNic $f.World 'n02' 'Port3').n = 'SLOT 6 Port 2'
        $r = Invoke-VerRun 'NW-001' $f.World $f.Infra
        ($r | Where-Object Node -EQ 'n02').Status | Should -Be 'Failed'
        ($r | Where-Object Node -EQ 'n02').Message | Should -Match "adapter 'Port3'"
        ($r | Where-Object Node -EQ 'n01').Status | Should -Be 'Passed'
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
    It 'NW-005 Failed for an endpoint that does not answer' {
        $f = New-VerFresh; $e = $f.World.Snapshot['n01'].https[1]; $e.ok = $false; $e.err = 'The operation timed out'
        $r = Invoke-VerRun 'NW-005' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'management.azure.com'
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
