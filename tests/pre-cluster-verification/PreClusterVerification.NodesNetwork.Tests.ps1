#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Categories nodes and network: OS build, time, DNS, features, reboot, hardware, firmware, cluster leftovers, the intents against the real adapters
# (RDMA, speed, MTU), the management network, the infrastructure pool, reserved ranges, outbound connectivity, the proxy. Fakes only.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake adapter members and mock script blocks keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    foreach ($m in 'infrastructure\AzlInfrastructure.psm1', 'azure-local\AzlAzure.psm1', 'arm-deployment\AzlArmDeployment.psm1', 'arm-deployment\AzlArmDeploymentRun.psm1', 'arm-deployment\AzlPreClusterGate.psm1', 'arm-deployment\AzlPreClusterVerification.psm1') {
        Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Force
    }
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'PreClusterVerification.Helpers.ps1'))
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
    function Invoke-NodeRun([scriptblock]$Mutate, [string]$NodeName = 'iic-n01', [string[]]$Category = @('nodes', 'network'), [System.Collections.IDictionary]$Infra) {
        if (-not $Infra) { $Infra = Get-PclInfra }
        $w = Initialize-PclWorld -Infra $Infra
        if ($Mutate) { $w.Mutate[$NodeName] = $Mutate }
        Invoke-PclRun -World $w -Infra $Infra -Category $Category
    }
}

Describe 'A healthy pair of nodes' {
    It 'passes the nodes and network categories' {
        $r = Invoke-NodeRun
        $r.Verdict | Should -Be 'Pass'
        @($r.Checks | Where-Object { $_.Blocking }).Count | Should -Be 0
        (Get-PclCheck $r 'NOD-001' 'iic-n01').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'NET-003' 'iic-n01').Status | Should -Be 'Passed'
    }
}

Describe 'NOD-001 a node that cannot be read' {
    It 'fails NOD-001 with the reason, and every other node check of that node is Skipped (and blocks)' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.NodeFailures['iic-n02'] = 'WinRM cannot process the request: the host did not answer'
        $r = Invoke-PclRun -World $w -Infra $infra -Category nodes, network
        $c = Get-PclCheck $r 'NOD-001' 'iic-n02'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'did not answer'
        (Get-PclCheck $r 'NOD-001' 'iic-n01').Status | Should -Be 'Passed'
        foreach ($id in 'NOD-002', 'NOD-008', 'NET-001', 'NET-013') {
            $x = Get-PclCheck $r $id 'iic-n02'
            $x.Status | Should -Be 'Skipped' -Because $id
            $x.Blocking | Should -BeTrue
        }
        (Get-PclCheck $r 'NET-006').Status | Should -Be 'Skipped'
    }
}

Describe 'NOD-002 to NOD-006 name, OS build, time and DNS' {
    It 'fails a computer name that differs from the file' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.host = 'WIN-X1' }) 'NOD-002' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match "'WIN-X1'"
    }
    It 'fails when the nodes run different OS builds' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.os.build = '10.0.26100.32230' }) 'NOD-003'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'iic-n01=10\.0\.26100\.32230'
        $c.Message | Should -Match 'iic-n02=10\.0\.26100\.33650'
    }
    It 'compares the OS build with the target solution line' {
        $infra = Get-PclInfra
        $infra['provisioning'] = [ordered]@{ os_version = '12.2610.1004.50' }
        (Get-PclCheck (Invoke-NodeRun -Infra $infra) 'NOD-004' 'iic-n01').Status | Should -Be 'Passed'
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.os.build = '10.0.26100.99999' } -Infra $infra) 'NOD-004' 'iic-n01'
        $c.Status | Should -Be 'Warning'
        $infra2 = Get-PclInfra; $infra2['provisioning'] = [ordered]@{ os_version = '12.2609.1002.10' }
        (Get-PclCheck (Invoke-NodeRun -Infra $infra2) 'NOD-004' 'iic-n01').Status | Should -Be 'Failed'
        $infra3 = Get-PclInfra; $infra3.provisioning.Remove('os_version')
        (Get-PclCheck (Invoke-NodeRun -Infra $infra3) 'NOD-004').Status | Should -Be 'NotApplicable'
    }
    It 'fails the local CMOS clock and a clock far from this host' {
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.time.src = 'Local CMOS Clock' }) 'NOD-005' 'iic-n01').Message | Should -Match 'CMOS'
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.utc = '2026-11-08T12:20:00.0000000Z' }) 'NOD-005' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match '1200 seconds'
    }
    It 'warns when the NTP peers carry no 0x8 flag' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Read.time.peers = '192.0.2.4 192.0.2.5' }) 'NOD-005' 'iic-n01'
        $c.Status | Should -Be 'Warning'
        $c.Message | Should -Match '0x8'
    }
    It 'fails DNS servers that differ from the file, and public resolvers' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.dns[0].servers = @('192.0.2.4') }) 'NOD-006' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match "can't be changed after the deployment"
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.dns[0].servers = @('8.8.8.8', '192.0.2.4') }) 'NOD-006' 'iic-n01').Message | Should -Match 'public resolver 8\.8\.8\.8'
    }
}

Describe 'NOD-007 to NOD-014 features, restart, hardware, firmware, leftovers' {
    It 'fails a missing Windows feature and warns for one the node does not list by name' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.features | Where-Object { $_.n -eq 'Data-Center-Bridging' }).installed = $false }) 'NOD-007' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'Data-Center-Bridging'
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.features | Where-Object { $_.n -eq 'NetworkATC' }).found = $false }) 'NOD-007' 'iic-n01').Status | Should -Be 'Warning'
    }
    It 'fails a pending restart' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.reboot.cbs = $true }) 'NOD-008' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'component servicing'
    }
    It 'fails memory below 32 GB, and different processors on the nodes' {
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.cs.memBytes = [int64]16GB }) 'NOD-009' 'iic-n01').Message | Should -Match 'at least 32 GB'
        $c = @(Get-PclCheck (Invoke-NodeRun { param($d, $q) foreach ($x in $d.Pcl.cpu) { $x.maxClock = 3000 } }) 'NOD-009') | Where-Object { $_.Node -eq '*' }
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'MaxClockSpeed'
    }
    It 'fails virtualization that is off in the BIOS' {
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) foreach ($x in $d.Pcl.cpu) { $x.vt = $false }; $d.Pcl.cs.hypervisor = $false }) 'NOD-009' 'iic-n01').Message | Should -Match 'virtualization'
    }
    It 'fails Secure Boot off and a TPM that is not 2.0' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.fw.secureBoot = $false }) 'NOD-010' 'iic-n01'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'Secure Boot is off'
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.fw.tpmSpec = '1.2, 2, 1.16' }) 'NOD-010' 'iic-n01').Message | Should -Match 'not 2\.0'
    }
    It 'warns when the BIOS versions differ' {
        $c = @(Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.fw.biosVersion = '1.0.0' }) 'NOD-010') | Where-Object { $_.Node -eq '*' }
        $c.Status | Should -Be 'Warning'
    }
    It 'fails a boot disk under 200 GB' {
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.phys[0].size = 120000000000 }) 'NOD-011' 'iic-n01').Status | Should -Be 'Failed'
    }
    It 'fails a node that is already in a cluster, or shows evidence of one' {
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.cluster.svc = 'Running'; $d.Pcl.cluster.name = 'old-cluster' }) 'NOD-012' 'iic-n01').Message | Should -Match "old-cluster"
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Read.stor.cluster.deployed = $true; $d.Read.stor.cluster.why = @('C:\ClusterStorage exists') }) 'NOD-012' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'ClusterStorage'
    }
    It 'fails the Environment Checker module on a node, with the uninstall commands' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.ec = @([pscustomobject]@{ name = 'AzStackHci.EnvironmentChecker'; version = '1.2.3' }) }) 'NOD-013' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Remedy | Should -Match 'Uninstall-Module'
    }
    It 'fails an SBE package in C:\SBE when none is configured (step 0.60 would trip), and passes without one' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Read.sbeHeld = @('SBE_Dell_AX-760.zip', 'SBE_Discovery_Dell.xml') }) 'NOD-014' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'ErrorUnvalidatedSolutionAndSbeCombination'
        (Get-PclCheck (Invoke-NodeRun) 'NOD-014' 'iic-n01').Status | Should -Be 'Passed'
        (Get-PclCheck (Invoke-NodeRun) 'NOD-015').Status | Should -Be 'NotApplicable'
    }
}

Describe 'NET-001 to NET-004 the intents against the adapters (RDMA on a management intent)' {
    It 'fails an intent adapter that does not exist on a node, or has no link' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.nics = @($d.Pcl.nics | Where-Object { $_.n -ne 'Port3' }) }) 'NET-001' 'iic-n01'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match "adapter 'Port3'"
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.nics | Where-Object { $_.n -eq 'Port2' }).st = 'Disconnected' }) 'NET-001' 'iic-n01').Message | Should -Match 'Disconnected, not Up'
    }
    It 'fails storage adapters under 10 Gbps and an intent with adapters of different speeds' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.nics | Where-Object { $_.n -eq 'Port2' }).speed = 1000000000 }) 'NET-002' 'iic-n01'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'at least 10 Gbps'
        $c.Message | Should -Match 'different speeds'
    }
    It 'passes RDMA off on the management and compute intent, whose adapters are not RDMA capable (the intent builder sends it off)' {
        $r = Invoke-NodeRun
        (Get-PclCheck $r 'NET-003' 'iic-n01').Status | Should -Be 'Passed'
    }
    It 'fails RDMA that the file asks for on a management intent while RDMA is not operational on the adapter (the Azure failure)' {
        $infra = Get-PclInfra
        $infra.networking.intents[0]['overrides'] = [ordered]@{ adapter = [ordered]@{ network_direct = $true; network_direct_technology = 'roce_v2' } }
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) foreach ($n in $d.Pcl.nics) { if ($n.n -in 'Port0', 'Port1') { $n.rdmaCapable = $true; $n.rdmaOp = $false } } } -Infra $infra) 'NET-003' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'carries no storage traffic but asks for RDMA'
        $c.Message | Should -Match 'Azure''s network validation fails on exactly this'
    }
    It 'fails a storage intent whose adapter is not RDMA capable' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.nics | Where-Object { $_.n -eq 'Port3' }).rdmaCapable = $false }) 'NET-003' 'iic-n01'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'not RDMA capable'
    }
    It 'warns about jumbo frames on a management intent and about different MTUs on the nodes' {
        $infra = Get-PclInfra
        $infra.networking.intents[0]['overrides'] = [ordered]@{ adapter = [ordered]@{ jumbo_packet = 9014 } }
        (Get-PclCheck (Invoke-NodeRun -Infra $infra) 'NET-004').Message | Should -Match 'keeps jumbo frames for the storage traffic'
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.nics | Where-Object { $_.n -eq 'Port2' }).jumbo = '1514' }) 'NET-004'
        $c.Status | Should -Be 'Warning'; $c.Message | Should -Match "'Port2' has different jumbo packet values"
    }
}

Describe 'NET-005 to NET-009 the management network, the pool, the reserved ranges, the storage plan' {
    It 'fails two physical adapters that both have a default gateway' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.nics | Where-Object { $_.n -eq 'Port2' }).gw = @('198.51.100.1') }) 'NET-005' 'iic-n01'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'more than one does'
    }
    It 'fails an adapter with two IPv4 addresses' {
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.nics | Where-Object { $_.n -eq 'Port0' }).ips = @('192.0.2.11', '192.0.2.12') }) 'NET-005' 'iic-n01').Message | Should -Match 'more than one IPv4 address'
    }
    It 'fails a pool of fewer than six addresses, a pool with a node in it, and a pool that answers ping' {
        $infra = Get-PclInfra; $infra.networking.management.infrastructure_pool = [ordered]@{ start = '192.0.2.20'; end = '192.0.2.23' }
        (Get-PclCheck (Invoke-NodeRun -Infra $infra) 'NET-006').Message | Should -Match 'at least six'
        $infra2 = Get-PclInfra; $infra2.networking.management.infrastructure_pool = [ordered]@{ start = '192.0.2.8'; end = '192.0.2.14' }
        (Get-PclCheck (Invoke-NodeRun -Infra $infra2) 'NET-006').Message | Should -Match '192\.0\.2\.11'
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.ping | Where-Object { $_.a -eq '192.0.2.25' }).ok = $true }) 'NET-006'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match '192\.0\.2\.25 \(answers ping from iic-n01\)'
    }
    It 'fails addresses in the Arc resource bridge ranges and warns about the wider AKS range' {
        $infra = Get-PclInfra; $infra.networking.management.dns_servers = @('10.96.0.10', '192.0.2.5')
        $c = Get-PclCheck (Invoke-NodeRun -Infra $infra) 'NET-008'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match '10\.96\.0\.0/24'
        $infra2 = Get-PclInfra; $infra2.networking.management.dns_servers = @('10.100.0.10', '192.0.2.5')
        (Get-PclCheck (Invoke-NodeRun -Infra $infra2) 'NET-008').Status | Should -Be 'Warning'
        $infra3 = Get-PclInfra; $infra3.networking.management.gateway = '10.244.1.1'
        (Get-PclCheck (Invoke-NodeRun -Infra $infra3) 'NET-008').Message | Should -Match '10\.244\.0\.0/16'
    }
    It 'fails public DNS and a DNS server that is a node' {
        $infra = Get-PclInfra; $infra.networking.management.dns_servers = @('8.8.8.8', '192.0.2.11')
        $c = Get-PclCheck (Invoke-NodeRun -Infra $infra) 'NET-007'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'public resolver'
        $c.Message | Should -Match 'inside the Azure Local instance'
    }
    It 'fails duplicate storage VLANs and a switchless three-node design with Storage Auto IP' {
        $infra = Get-PclInfra
        $infra.networking.storage.networks[1].vlan_id = 711
        (Get-PclCheck (Invoke-NodeRun -Infra $infra) 'NET-009').Message | Should -Match 'not unique'
        $infra3 = Get-PclInfra -Nodes 3; $infra3.scenario.storage_connectivity = 'switchless'
        $w = Initialize-PclWorld -Infra $infra3
        (Get-PclCheck (Invoke-PclRun -World $w -Infra $infra3 -Category network) 'NET-009').Message | Should -Match 'Storage Auto IP must be disabled'
    }
}

Describe 'NET-010 to NET-014 outbound, proxy, DNS reach, drivers, leftovers' {
    It 'fails endpoints the node cannot reach, and recognises a TLS inspection error' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $x = $d.Pcl.https[0]; $x.ok = $false; $x.err = 'The underlying connection was closed: Could not establish trust relationship for the SSL/TLS secure channel.' }) 'NET-010' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'SSL inspection'
        $c.Message | Should -Match 'login\.microsoftonline\.com'
    }
    It 'does not probe the endpoints for a disconnected design' {
        $infra = Get-PclInfra; $infra.scenario.connectivity = 'disconnected'
        (Get-PclCheck (Invoke-NodeRun -Infra $infra) 'NET-010').Status | Should -Be 'NotApplicable'
    }
    It 'fails a proxy with credentials, a .local name, a PAC file or CIDR in the bypass list' {
        $infra = Get-PclInfra; $infra.scenario.outbound_path = 'proxy'
        $infra.networking['outbound'] = [ordered]@{ proxy = [ordered]@{ url = 'http://user:pw@proxy.contoso.local:8080'; bypass = @('192.0.2.0/24') } }
        $c = Get-PclCheck (Invoke-NodeRun -Infra $infra) 'NET-011'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'without credentials'
        $c.Message | Should -Match 'CIDR notation'
    }
    It 'passes a plain proxy with a bypass list that covers the nodes and the cluster' {
        $infra = Get-PclInfra; $infra.scenario.outbound_path = 'proxy'
        $infra.networking['outbound'] = [ordered]@{ proxy = [ordered]@{ url = 'http://proxy.contoso.com:8080'; bypass = @('192.0.2.*', 'iic-clus01', 'iic-n01', 'iic-n02') } }
        (Get-PclCheck (Invoke-NodeRun -Infra $infra) 'NET-011').Status | Should -Be 'Passed'
    }
    It 'fails a node that reaches no DNS server on TCP 53, and warns about a gateway that does not answer ping' {
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) foreach ($x in $d.Pcl.tcp) { if ($x.p -eq 53) { $x.ok = $false } } }) 'NET-012' 'iic-n01').Status | Should -Be 'Failed'
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.ping | Where-Object { $_.a -eq '192.0.2.1' }).ok = $false }) 'NET-012' 'iic-n01'
        $c.Status | Should -Be 'Warning'; $c.Message | Should -Match 'ICMP'
    }
    It 'fails the inbox Microsoft driver on an intent adapter' {
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) ($d.Pcl.nics | Where-Object { $_.n -eq 'Port2' }).drvProv = 'Microsoft' }) 'NET-013' 'iic-n01'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'inbox Microsoft driver on: Port2'
    }
    It 'fails an existing Network ATC intent and warns about a virtual switch on an intent adapter' {
        (Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.vms.intents = @('management') }) 'NET-014' 'iic-n01').Status | Should -Be 'Failed'
        $c = Get-PclCheck (Invoke-NodeRun { param($d, $q) $d.Pcl.vms.switches = @([pscustomobject]@{ n = 'ConvergedSwitch'; uplinks = @('Dell LOM 25G') }) }) 'NET-014' 'iic-n01'
        $c.Status | Should -Be 'Warning'; $c.Message | Should -Match 'not bound'
    }
}
