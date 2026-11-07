#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Contract tests for infrastructure.yml schema 5: every example is clean, and each rule catches what it should.
# Run: Invoke-Pester ./tests/infrastructure

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module powershell-yaml
    $script:ExamplePath = Join-Path $repo 'config\infrastructure\infrastructure.example.yml'

    # Loads the main example, applies a change, writes it to TestDrive and returns the findings.
    function Get-FindingFor([scriptblock]$Change, [string]$From = $script:ExamplePath) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $From -Raw) -Ordered
        & $Change $doc
        $file = Join-Path $TestDrive ("case-{0}.yml" -f [guid]::NewGuid())
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        @(Test-AzlInfrastructure -Path $file)
    }
}

Describe 'Examples' {
    It '<_> has no errors' -ForEach @(
        Get-ChildItem (Join-Path $PSScriptRoot '..\..\config\infrastructure') -Recurse -Filter '*.yml' | ForEach-Object FullName
    ) {
        @(Test-AzlInfrastructure -Path $_ | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
    }
}

Describe 'Schema rules' {
    It 'rejects an unknown key' {
        $f = Get-FindingFor { param($d) $d.networking.management['typo_key'] = 1 }
        $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'networking.management.typo_key' } | Should -Not -BeNullOrEmpty
    }
    It 'needs identity.local_identity for local identity' {
        $f = Get-FindingFor { param($d) $d.scenario.identity = 'local_identity' }
        $f | Where-Object { $_.Path -eq 'identity' -and $_.Message -match 'local_identity' } | Should -Not -BeNullOrEmpty
    }
    It 'needs storage.san and cluster_networks for a SAN' {
        $f = Get-FindingFor { param($d) $d.scenario.storage_architecture = 'san' }
        $f | Where-Object { $_.Message -match 'san' } | Should -Not -BeNullOrEmpty
        $f | Where-Object { $_.Message -match 'cluster_networks' } | Should -Not -BeNullOrEmpty
    }
    It 'needs switchless_links for switchless storage' {
        $f = Get-FindingFor { param($d) $d.scenario.storage_connectivity = 'switchless' }
        $f | Where-Object { $_.Path -eq 'networking.storage' -and $_.Message -match 'switchless_links' } | Should -Not -BeNullOrEmpty
    }
    It 'needs a zone on every node for rack aware' {
        $f = Get-FindingFor { param($d) $d.scenario.topology = 'rack_aware' }
        $f | Where-Object { $_.Path -eq 'nodes[0]' -and $_.Message -match 'zone' } | Should -Not -BeNullOrEmpty
    }
    It 'needs the disconnected section for disconnected operations' {
        $f = Get-FindingFor { param($d) $d.scenario.connectivity = 'disconnected' }
        $f | Where-Object { $_.Message -match 'disconnected' } | Should -Not -BeNullOrEmpty
    }
    It 'needs a proxy for the proxy path' {
        $f = Get-FindingFor { param($d) $d.scenario.outbound_path = 'proxy' }
        $f | Where-Object { $_.Message -match 'outbound' } | Should -Not -BeNullOrEmpty
    }
    It 'needs a serial number on every node for simplified provisioning' {
        $f = Get-FindingFor { param($d) $d.nodes[0].Remove('serial_number') }
        $f | Where-Object { $_.Path -eq 'nodes[0]' -and $_.Message -match 'serial_number' } | Should -Not -BeNullOrEmpty
    }
    It 'limits the LCM user name to 20 characters' {
        $f = Get-FindingFor { param($d) $d.identity.active_directory.lcm_user.username = 'lcm-a-name-longer-than-20' }
        $f | Where-Object { $_.Path -eq 'identity.active_directory.lcm_user.username' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses the built-in Administrator as the deployment admin' {
        $f = Get-FindingFor { param($d) $d.identity.local_admin.username = 'Administrator' }
        $f | Where-Object { $_.Path -eq 'identity.local_admin.username' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses a password value instead of a Key Vault reference' {
        $f = Get-FindingFor { param($d) $d.identity.local_admin.password = 'P@ssw0rd-in-a-file' }
        $f | Where-Object { $_.Path -eq 'identity.local_admin.password' } | Should -Not -BeNullOrEmpty
    }
    It 'limits the cluster name to 15 characters' {
        $f = Get-FindingFor { param($d) $d.cluster.name = 'a-cluster-name-too-long' }
        $f | Where-Object { $_.Path -eq 'cluster.name' } | Should -Not -BeNullOrEmpty
    }
}

Describe 'Semantic rules' {
    It 'AZL-000 refuses another schema major version' {
        (Get-FindingFor { param($d) $d._metadata.schema_version = '4.0.0' }).Id | Should -Contain 'AZL-000'
    }
    It 'AZL-001 needs every referenced vault in key_vaults' {
        (Get-FindingFor { param($d) $d.identity.local_admin.password = 'keyvault://kv-unlisted-01/local-admin-password' }).Id | Should -Contain 'AZL-001'
    }
    It 'AZL-002 refuses duplicate node names' {
        (Get-FindingFor { param($d) $d.nodes[1].name = $d.nodes[0].name }).Id | Should -Contain 'AZL-002'
    }
    It 'AZL-004 needs node addresses in the management subnet' {
        (Get-FindingFor { param($d) $d.nodes[0].management.ip_address = '203.0.113.11' }).Id | Should -Contain 'AZL-004'
    }
    It 'AZL-005 needs at least six addresses in the pool' {
        (Get-FindingFor { param($d) $d.networking.management.infrastructure_pool.end = '192.0.2.24' }).Id | Should -Contain 'AZL-005'
    }
    It 'AZL-005 keeps node addresses out of the pool' {
        (Get-FindingFor { param($d) $d.nodes[0].management.ip_address = '192.0.2.21' }).Id | Should -Contain 'AZL-005'
    }
    It 'AZL-006 refuses the Arc resource bridge pod range' {
        $f = Get-FindingFor {
            param($d)
            $d.networking.management.subnet = '10.244.1.0/24'; $d.networking.management.gateway = '10.244.1.1'
            $d.networking.management.infrastructure_pool.start = '10.244.1.20'; $d.networking.management.infrastructure_pool.end = '10.244.1.29'
            $d.nodes[0].management.ip_address = '10.244.1.11'; $d.nodes[1].management.ip_address = '10.244.1.12'
        }
        $f | Where-Object { $_.Id -eq 'AZL-006' -and $_.Severity -eq 'error' } | Should -Not -BeNullOrEmpty
    }
    It 'AZL-007 limits switchless storage to four machines' {
        $f = Get-FindingFor {
            param($d)
            $d.scenario.storage_connectivity = 'switchless'; $d.networking.storage['switchless_links'] = 'dual'
            foreach ($n in 3..5) { $d.nodes.Add([ordered]@{ name = "iic-azl-n0$n"; serial_number = "SERIAL0$n"; management = [ordered]@{ ip_address = "192.0.2.1$n"; mac_address = "00:00:5E:00:53:1$n" }; bmc = [ordered]@{ ip_address = "198.51.100.1$n" } }) }
        }
        $f.Id | Should -Contain 'AZL-007'
    }
    It 'AZL-007 needs two zones of the same size for rack aware' {
        $f = Get-FindingFor {
            param($d)
            $d.scenario.topology = 'rack_aware'; $d.nodes[0]['zone'] = 'A'; $d.nodes[1]['zone'] = 'A'
        }
        $f.Id | Should -Contain 'AZL-007'
    }
    It 'AZL-008 needs a witness for two machines' {
        (Get-FindingFor { param($d) $d.cluster.witness = [ordered]@{ type = 'none' } }).Id | Should -Contain 'AZL-008'
    }
    It 'AZL-009 allows one management intent only' {
        (Get-FindingFor { param($d) $d.networking.intents[1].traffic.Add('management') }).Id | Should -Contain 'AZL-009'
    }
    It 'AZL-009 refuses an adapter in two intents' {
        (Get-FindingFor { param($d) $d.networking.intents[1].adapters[0] = 'Port1' }).Id | Should -Contain 'AZL-009'
    }
    It 'AZL-010 needs storage addresses on every node when auto_ip is off' {
        (Get-FindingFor { param($d) $d.networking.storage.auto_ip = $false }).Id | Should -Contain 'AZL-010'
    }
    It 'AZL-013 warns when the OS version is not pinned' {
        $f = Get-FindingFor { param($d) $d.provisioning.os_version = 'latest' }
        $f | Where-Object { $_.Id -eq 'AZL-013' -and $_.Severity -eq 'warning' } | Should -Not -BeNullOrEmpty
    }
    It 'AZL-014 refuses public DNS servers' {
        (Get-FindingFor { param($d) $d.networking.management.dns_servers = @('8.8.8.8') }).Id | Should -Contain 'AZL-014'
    }
    It 'AZL-016 refuses Arc gateway with simplified provisioning' {
        $f = Get-FindingFor { param($d) $d.scenario.outbound_path = 'arc_gateway'; $d.networking['outbound'] = [ordered]@{ arc_gateway = [ordered]@{ name = 'arcgw-iic-01' } } }
        $f.Id | Should -Contain 'AZL-016'
    }
    It 'AZL-016 refuses Arc gateway in Azure Government' {
        $f = Get-FindingFor -From (Join-Path $repo 'config\infrastructure\examples\local-identity-switchless-iso.yml') { param($d) $d.scenario.cloud = 'government' }
        $f.Id | Should -Contain 'AZL-016'
    }
    It 'AZL-015 needs a BMC login for simplified provisioning' {
        (Get-FindingFor { param($d) $d.hardware.Remove('bmc') }).Id | Should -Contain 'AZL-015'
    }
    It 'AZL-017 refuses one management MAC on two nodes, in either notation' {
        $f = Get-FindingFor { param($d) $d.nodes[1].management.mac_address = $d.nodes[0].management.mac_address.Replace(':', '-').ToLowerInvariant() }
        $f | Where-Object { $_.Id -eq 'AZL-017' -and $_.Severity -eq 'error' } | Should -Not -BeNullOrEmpty
    }
    It 'AZL-017 warns that every node needs a DHCP reservation with ip_assignment dhcp' {
        $f = Get-FindingFor { param($d) $d.networking.management.ip_assignment = 'dhcp' }
        $w = @($f | Where-Object { $_.Id -eq 'AZL-017' -and $_.Severity -eq 'warning' })
        $w.Count | Should -Be 2
        $w[0].Path | Should -Be 'nodes[0].management'
        $w[0].Message | Should -Match '192\.0\.2\.11.*00:00:5E:00:53:11'
        @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
    }
    It 'AZL-017 says nothing with static or preconfigured' {
        foreach ($mode in 'static', 'preconfigured') {
            $f = Get-FindingFor { param($d) $d.networking.management.ip_assignment = $mode }
            @($f | Where-Object Id -eq 'AZL-017') | Should -BeNullOrEmpty -Because $mode
        }
    }
    It 'AZL-018 refuses two nodes with the same Arc machine name' {
        $f = Get-FindingFor { param($d) $d.nodes[1].arc_machine_name = $d.nodes[0].arc_machine_name.ToUpperInvariant() }
        $f | Where-Object { $_.Id -eq 'AZL-018' -and $_.Severity -eq 'error' -and $_.Path -eq 'nodes' } | Should -Not -BeNullOrEmpty
    }
    It 'AZL-018 counts the node name as the Arc machine name when arc_machine_name is left out' {
        $f = Get-FindingFor { param($d) $d.nodes[0].Remove('arc_machine_name'); $d.nodes[1].arc_machine_name = $d.nodes[0].name }
        $f | Where-Object { $_.Id -eq 'AZL-018' -and $_.Path -eq 'nodes' } | Should -Not -BeNullOrEmpty
    }
    It 'AZL-018 warns about the deprecated arc_resource_name, and refuses it when it disagrees with arc_machine_name' {
        $f = Get-FindingFor { param($d) $d.nodes[0].Remove('arc_machine_name'); $d.nodes[0]['arc_resource_name'] = 'iic-azl-n01' }
        $f | Where-Object { $_.Id -eq 'AZL-018' -and $_.Severity -eq 'warning' -and $_.Path -eq 'nodes[0].arc_resource_name' } | Should -Not -BeNullOrEmpty
        $f = Get-FindingFor { param($d) $d.nodes[0]['arc_resource_name'] = 'iic-azl-other' }
        $f | Where-Object { $_.Id -eq 'AZL-018' -and $_.Severity -eq 'error' -and $_.Path -eq 'nodes[0].arc_resource_name' } | Should -Not -BeNullOrEmpty
    }
    It 'AZL-018 warns that an ISO install names the Arc machine after the host' {
        $f = Get-FindingFor -From (Join-Path $repo 'config\infrastructure\examples\single-machine-iso.yml') { param($d) $d.nodes[0]['arc_machine_name'] = 'iic-edge-07-arc' }
        $f | Where-Object { $_.Id -eq 'AZL-018' -and $_.Severity -eq 'warning' -and $_.Path -eq 'nodes[0].arc_machine_name' } | Should -Not -BeNullOrEmpty
    }
}

Describe 'Management address and Arc machine name' {
    It 'rejects an unknown ip_assignment' {
        $f = Get-FindingFor { param($d) $d.networking.management.ip_assignment = 'auto' }
        $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'networking.management.ip_assignment' } | Should -Not -BeNullOrEmpty
    }
    It 'accepts ip_assignment <_>' -ForEach @('static', 'dhcp', 'preconfigured') {
        $mode = $_
        $f = Get-FindingFor { param($d) $d.networking.management.ip_assignment = $mode }
        @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
    }
    It 'needs the management MAC on every node with simplified provisioning, also with <_>' -ForEach @('static', 'dhcp', 'preconfigured') {
        $mode = $_
        $f = Get-FindingFor { param($d) $d.networking.management.ip_assignment = $mode; $d.nodes[0].management.Remove('mac_address') }
        $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].management' -and $_.Message -match 'mac_address' } | Should -Not -BeNullOrEmpty
    }
    It 'rejects an Arc machine name that <Case>' -ForEach @(
        @{ Case = 'has a space'; Name = 'node 01' }
        @{ Case = 'ends in a dot'; Name = 'node-01.' }
        @{ Case = 'is longer than 54 characters'; Name = ('a' * 55) }
        @{ Case = 'is empty'; Name = '' }
    ) {
        $n = $Name
        $f = Get-FindingFor { param($d) $d.nodes[0].arc_machine_name = $n }
        $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].arc_machine_name' } | Should -Not -BeNullOrEmpty
    }
    It 'accepts an Arc machine name of 54 characters with dots and underscores' {
        $n = 'iic_azl.n01-' + ('a' * 42)
        $f = Get-FindingFor { param($d) $d.nodes[0].arc_machine_name = $n }
        @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
    }
    It 'reads the IP assignment mode, static by default' {
        $infra = Import-AzlInfrastructure -Path $script:ExamplePath -SkipValidation
        Get-AzlManagementIpAssignment -Infrastructure $infra | Should -Be 'static'
        $infra.networking.management.Remove('ip_assignment')
        Get-AzlManagementIpAssignment -Infrastructure $infra | Should -Be 'static'
        $infra.networking.management['ip_assignment'] = 'dhcp'
        Get-AzlManagementIpAssignment -Infrastructure $infra | Should -Be 'dhcp'
    }
    It 'reads the Arc machine name: arc_machine_name, then arc_resource_name, then the node name' {
        Get-AzlArcMachineName -Node ([ordered]@{ name = 'n01'; arc_machine_name = 'arc-01'; arc_resource_name = 'old-01' }) | Should -Be 'arc-01'
        Get-AzlArcMachineName -Node ([ordered]@{ name = 'n01'; arc_resource_name = 'old-01' }) | Should -Be 'old-01'
        Get-AzlArcMachineName -Node ([ordered]@{ name = 'n01' }) | Should -Be 'n01'
    }
}

Describe 'Schema 5.2: network adapters' {
    BeforeAll {
        $script:Lom = Join-Path $repo 'config\infrastructure\examples\lom-management-ztp.yml'
        $script:NoDhcp = Join-Path $repo 'config\infrastructure\examples\no-dhcp-switchless.yml'
        # Findings for a change to the LOM-management example (two nodes, six ports each, simplified provisioning).
        function Get-LomFinding([scriptblock]$Change) { Get-FindingFor -From $script:Lom $Change }
        function Get-Port($Doc, [int]$Node, [string]$Name) { $Doc.nodes[$Node].network_adapters | Where-Object { $_.name -eq $Name } | Select-Object -First 1 }
    }

    Context 'schema' {
        It 'needs ip_address for <_>' -ForEach @('static', 'dhcp_reservation') {
            $mode = $_
            $f = Get-LomFinding { param($d) $p = Get-Port $d 0 'Embedded NIC 1'; $p.ip_assignment = $mode; $p.Remove('ip_address') }
            $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].network_adapters[0]' -and $_.Message -match 'ip_address' } | Should -Not -BeNullOrEmpty
        }
        It 'needs mac_address for a DHCP reservation' {
            $f = Get-FindingFor -From (Join-Path $repo 'config\infrastructure\examples\single-machine-iso.yml') { param($d) $d.nodes[0].network_adapters[0].Remove('mac_address') }
            $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].network_adapters[0]' -and $_.Message -match 'mac_address' } | Should -Not -BeNullOrEmpty
        }
        It 'needs a MAC on every management port with simplified provisioning, the team partner too' {
            $f = Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 2').Remove('mac_address') }
            @($f | Where-Object Severity -eq 'error') | ForEach-Object { "$($_.Path) $($_.Message)" } | Should -Be @('nodes[0].network_adapters[1] Missing required key(s): mac_address')
        }
        It 'needs a provisioning port on every node with simplified provisioning' {
            $f = Get-LomFinding { param($d) foreach ($p in $d.nodes[1].network_adapters) { $p.roles = @($p.roles | Where-Object { $_ -ne 'provisioning' }) } }
            $f | Where-Object { $_.Id -eq 'AZL-024' -and $_.Path -eq 'nodes[1].network_adapters' -and $_.Message -match 'no port with role provisioning' } | Should -Not -BeNullOrEmpty
            $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[1].network_adapters' } | Should -Not -BeNullOrEmpty
        }
        It 'allows exactly one port to own the management address: <Case>' -ForEach @(
            @{ Case = 'two'; Edit = { param($d) $p = Get-Port $d 0 'Embedded NIC 2'; $p.ip_assignment = 'static'; $p['ip_address'] = '192.0.2.13' }; Count = 2 }
            @{ Case = 'none'; Edit = { param($d) (Get-Port $d 0 'Embedded NIC 1').ip_assignment = 'none' }; Count = 0 }
        ) {
            $f = Get-LomFinding $Edit
            $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].network_adapters' -and $_.Message -match 'contains' } | Should -Not -BeNullOrEmpty
            $f | Where-Object { $_.Id -eq 'AZL-020' -and $_.Message -match "$Count ports own the management address" } | Should -Not -BeNullOrEmpty
            # Only the list is named, not every port the rule didn't match.
            @($f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -match '^nodes\[0\]\.network_adapters\[' }) | Should -BeNullOrEmpty
        }
        It 'rejects an unknown role, an unused port with another role, and an unknown ip_assignment' {
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 3 Port 1').roles = @('compute', 'backup') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].network_adapters[2].roles[1]' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 3 Port 1').roles = @('compute', 'unused') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].network_adapters[2].roles' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 3 Port 1').ip_assignment = 'auto' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].network_adapters[2].ip_assignment' } | Should -Not -BeNullOrEmpty
        }
        It 'needs management or network_adapters on a node' {
            $f = Get-LomFinding { param($d) $d.nodes[0].Remove('network_adapters') }
            $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0]' } | Should -Not -BeNullOrEmpty
        }
        It 'takes BIOS values as strings with attribute-like names' {
            (Get-LomFinding { param($d) $d.hardware.bios['Slot2'] = 0 }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'hardware.bios.Slot2' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $d.nodes[0]['bios'] = [ordered]@{ 'Slot 2' = 'Disabled' } }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].bios.Slot 2' } | Should -Not -BeNullOrEmpty
            @(Get-LomFinding { param($d) $d.nodes[1]['bios'] = [ordered]@{ Slot2 = 'Enabled' } } | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
        }
        It 'rejects an unknown provisioning_network and a site range without an end' {
            (Get-LomFinding { param($d) $d.networking.management.provisioning_network = 'wifi' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'networking.management.provisioning_network' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $d.networking.management.site_ip_range.Remove('end') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'networking.management.site_ip_range' } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'rules' {
        It 'AZL-004 and AZL-005 check the management port''s address' {
            (Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 1').ip_address = '203.0.113.11'; $d.networking.management.Remove('site_ip_range') }) | Where-Object { $_.Id -eq 'AZL-004' -and $_.Path -eq 'nodes[0].network_adapters[0].ip_address' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 1').ip_address = '192.0.2.21'; $d.networking.management.Remove('site_ip_range') }).Id | Should -Contain 'AZL-005'
        }
        It 'AZL-019 refuses a MAC on two ports, two ports with one name, and lists on some nodes only' {
            (Get-LomFinding { param($d) (Get-Port $d 1 'Slot 6 Port 2').mac_address = (Get-Port $d 0 'Slot 3 Port 1').mac_address.ToLowerInvariant().Replace(':', '-') }) | Where-Object { $_.Id -eq 'AZL-019' -and $_.Message -match '00:00:5E:00:53:13' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 6 Port 2').name = 'slot 3 port 1' }) | Where-Object { $_.Id -eq 'AZL-019' -and $_.Path -eq 'nodes[0].network_adapters' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $d.nodes[1].Remove('network_adapters'); $d.nodes[1]['management'] = [ordered]@{ ip_address = '192.0.2.12'; mac_address = '00:00:5E:00:53:21' } }) | Where-Object { $_.Id -eq 'AZL-019' -and $_.Message -match '1 of 2 nodes' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-020 compares a repeated nodes[].management with the port: <Case>' -ForEach @(
            @{ Case = 'agrees'; Ip = '192.0.2.11'; Severity = 'warning' }
            @{ Case = 'disagrees'; Ip = '192.0.2.99'; Severity = 'error' }
        ) {
            $ip = $Ip
            $f = Get-LomFinding { param($d) $d.nodes[0]['management'] = [ordered]@{ ip_address = $ip; mac_address = '00:00:5E:00:53:11' } }
            $f | Where-Object { $_.Id -eq 'AZL-020' -and $_.Severity -eq $Severity -and $_.Path -eq 'nodes[0].management' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-020 compares the deprecated site-wide ip_assignment with every management port' {
            (Get-LomFinding { param($d) $d.networking.management['ip_assignment'] = 'dhcp' }) | Where-Object { $_.Id -eq 'AZL-020' -and $_.Severity -eq 'error' -and $_.Path -eq 'networking.management.ip_assignment' } | Should -Not -BeNullOrEmpty
            $f = Get-LomFinding { param($d) $d.networking.management['ip_assignment'] = 'static' }
            $f | Where-Object { $_.Id -eq 'AZL-020' -and $_.Severity -eq 'warning' -and $_.Message -match 'deprecated' } | Should -Not -BeNullOrEmpty
            @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
        }
        It 'AZL-020 keeps the management port on the one management network' {
            (Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 1')['gateway'] = '192.0.2.254' }) | Where-Object { $_.Id -eq 'AZL-020' -and $_.Path -eq 'nodes[0].network_adapters[0].gateway' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 1')['prefix_length'] = 25 }) | Where-Object { $_.Id -eq 'AZL-020' -and $_.Path -eq 'nodes[0].network_adapters[0].prefix_length' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 1')['dns_servers'] = @('192.0.2.30') }) | Where-Object { $_.Id -eq 'AZL-020' -and $_.Path -eq 'nodes[0].network_adapters[0].dns_servers' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-020 wants the management port first in the management intent: a warning when static, an error with a reservation' {
            $f = Get-LomFinding { param($d) $d.networking.intents[0].adapters = @('Embedded NIC 2', 'Embedded NIC 1') }
            @($f | Where-Object { $_.Id -eq 'AZL-020' -and $_.Message -match 'first adapter' } | ForEach-Object Severity | Select-Object -Unique) | Should -Be @('warning')
            $f = Get-FindingFor -From (Join-Path $repo 'config\infrastructure\examples\single-machine-iso.yml') { param($d) $d.networking.intents[0].adapters = @('NIC2', 'NIC1') }
            $f | Where-Object { $_.Id -eq 'AZL-020' -and $_.Severity -eq 'error' -and $_.Message -match 'DHCP reservation must be for that MAC' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-020 refuses a management port outside the management intent, and warns about plain DHCP' {
            (Get-LomFinding { param($d) $d.networking.intents[0].adapters = @('Embedded NIC 2') }) | Where-Object { $_.Id -eq 'AZL-020' -and $_.Severity -eq 'error' -and $_.Message -match "isn't in the management intent" } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 1').ip_assignment = 'dhcp' }) | Where-Object { $_.Id -eq 'AZL-020' -and $_.Severity -eq 'warning' -and $_.Message -match 'without a reservation' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-021 needs every intent adapter on every node, with a role that fits and the same make and speed' {
            (Get-LomFinding { param($d) (Get-Port $d 1 'Slot 6 Port 2').name = 'Slot 7 Port 2' }) | Where-Object { $_.Id -eq 'AZL-021' -and $_.Severity -eq 'error' -and $_.Message -match "'Slot 6 Port 2', which isn't a port of node 'iic-lab-n02'" } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 3 Port 1').roles = @('unused') }) | Where-Object { $_.Id -eq 'AZL-021' -and $_.Severity -eq 'error' -and $_.Message -match 'role is unused' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 6 Port 2').speed_gbps = 25 }) | Where-Object { $_.Id -eq 'AZL-021' -and $_.Severity -eq 'error' -and $_.Message -match 'speed_gbps' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 1 'Slot 3 Port 2').model = 'Intel E810' }) | Where-Object { $_.Id -eq 'AZL-021' -and $_.Severity -eq 'error' -and $_.Message -match "model 'Intel E810' on node 'iic-lab-n02'" } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 3 Port 2').roles = @('compute') }) | Where-Object { $_.Id -eq 'AZL-021' -and $_.Severity -eq 'warning' -and $_.Message -match "carries \[storage\]" } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $d.networking.storage.networks[0].adapter = 'Slot 9 Port 1' }) | Where-Object { $_.Id -eq 'AZL-021' -and $_.Message -match "'Slot 9 Port 1', which isn't a port" } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-021 warns about a compute, storage or management port in no intent' {
            $f = Get-LomFinding { param($d) foreach ($n in $d.nodes) { $n.network_adapters.Add([ordered]@{ name = 'OCP 1'; mac_address = "00:00:5E:00:54:$($d.nodes.IndexOf($n))1"; roles = @('compute'); ip_assignment = 'none' }) } }
            $f | Where-Object { $_.Id -eq 'AZL-021' -and $_.Severity -eq 'warning' -and $_.Message -match "'OCP 1'.*isn't in any intent" } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-022 keeps one default gateway and warns about DHCP left on other ports' {
            (Get-LomFinding { param($d) $p = Get-Port $d 0 'Slot 3 Port 1'; $p.ip_assignment = 'static'; $p['ip_address'] = '198.51.100.50'; $p['prefix_length'] = 24; $p['gateway'] = '198.51.100.1' }) | Where-Object { $_.Id -eq 'AZL-022' -and $_.Severity -eq 'error' -and $_.Path -eq 'nodes[0].network_adapters[2].gateway' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 3 Port 1').ip_assignment = 'dhcp' }) | Where-Object { $_.Id -eq 'AZL-022' -and $_.Severity -eq 'warning' -and $_.Message -match 'two and validation fails' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $p = Get-Port $d 0 'Slot 3 Port 1'; $p.ip_assignment = 'static'; $p['ip_address'] = '198.51.100.50' }) | Where-Object { $_.Id -eq 'AZL-022' -and $_.Path -eq 'nodes[0].network_adapters[2].prefix_length' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $p = Get-Port $d 1 'Slot 3 Port 1'; $p.ip_assignment = 'static'; $p['ip_address'] = '192.0.2.11'; $p['prefix_length'] = 24 }) | Where-Object { $_.Id -eq 'AZL-022' -and $_.Severity -eq 'error' -and $_.Message -match 'Address 192.0.2.11 is on 2 ports' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $p = Get-Port $d 0 'Slot 3 Port 2'; $p.ip_assignment = 'static'; $p['ip_address'] = '198.51.100.60'; $p['prefix_length'] = 24 }) | Where-Object { $_.Id -eq 'AZL-022' -and $_.Message -match 'Network ATC assigns the storage addresses' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-023 matches the VLANs: the management tag, tagged ports with an address, and the storage networks' {
            (Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 1').vlan_mode = 'tagged' }) | Where-Object { $_.Id -eq 'AZL-023' -and $_.Severity -eq 'error' -and $_.Message -match 'tags VLAN 711, but networking.management.vlan_id is 0' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $p = Get-Port $d 0 'Slot 3 Port 1'; $p.ip_assignment = 'dhcp' }) | Where-Object { $_.Id -eq 'AZL-023' -and $_.Message -match 'no vlan_id to tag' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 3 Port 2').vlan_id = 799 }) | Where-Object { $_.Id -eq 'AZL-023' -and $_.Severity -eq 'error' -and $_.Message -match "storage network 'StorageNetwork1' on it is VLAN 712" } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Slot 3 Port 2').vlan_mode = 'access' }) | Where-Object { $_.Id -eq 'AZL-023' -and $_.Severity -eq 'warning' -and $_.Message -match 'trunk' } | Should -Not -BeNullOrEmpty
            @(Get-FindingFor -From $script:NoDhcp {} | Where-Object Id -eq 'AZL-023') | Should -BeNullOrEmpty -Because 'a tagged management port that matches networking.management.vlan_id is right'
        }
        It 'AZL-024 warns that a static maintenance-environment address is unresearched, and that a static management port used for provisioning needs DHCP there' {
            (Get-LomFinding { param($d) $d.networking.management.provisioning_network = 'static' }) | Where-Object { $_.Id -eq 'AZL-024' -and $_.Severity -eq 'warning' -and $_.Message -match 'open research item' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 1').roles = @('management', 'provisioning') }) | Where-Object { $_.Id -eq 'AZL-024' -and $_.Severity -eq 'warning' -and $_.Message -match 'A DHCP server must answer' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-025 checks the site range: <Case>' -ForEach @(
            @{ Case = 'a node outside it'; Range = @('192.0.2.11', '192.0.2.11'); Expect = 'outside the site range'; Severity = 'error' }
            @{ Case = 'outside the subnet'; Range = @('192.0.2.11', '192.0.3.12'); Expect = "isn't inside the management subnet"; Severity = 'error' }
            @{ Case = 'reversed'; Range = @('192.0.2.12', '192.0.2.11'); Expect = 'after its end'; Severity = 'error' }
            @{ Case = 'over the pool'; Range = @('192.0.2.11', '192.0.2.22'); Expect = 'overlaps the infrastructure pool'; Severity = 'warning' }
        ) {
            $r = $Range
            $f = Get-LomFinding { param($d) $d.networking.management.site_ip_range = [ordered]@{ start = $r[0]; end = $r[1] } }
            $f | Where-Object { $_.Id -eq 'AZL-025' -and $_.Severity -eq $Severity -and $_.Message -match $Expect } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'readers' {
        It 'reads the management port of a 5.2 node, with the defaults from networking.management' {
            $infra = Import-AzlInfrastructure -Path $script:Lom
            $o = Get-AzlManagementAdapter -Infrastructure $infra -Node $infra.nodes[1]
            $o.Name | Should -Be 'Embedded NIC 1'
            $o.MacAddress | Should -Be '00:00:5E:00:53:21'
            $o.IpAddress | Should -Be '192.0.2.12'
            $o.PrefixLength | Should -Be 24
            $o.SubnetMask | Should -Be '255.255.255.0'
            $o.Gateway | Should -Be '192.0.2.1'
            @($o.DnsServers) | Should -Be @('192.0.2.30', '192.0.2.31')
            $o.VlanId | Should -Be 0 -Because 'an access port in VLAN 711 is untagged on the host'
            $o.IpAssignment | Should -Be 'static'
            $o.Source | Should -Be 'network_adapters'
            @(Get-AzlNodeNetworkAdapter -Infrastructure $infra -Node $infra.nodes[0]).Count | Should -Be 6
            (Get-AzlManagementAdapter -Infrastructure (Import-AzlInfrastructure -Path $script:NoDhcp) -Node (Import-AzlInfrastructure -Path $script:NoDhcp).nodes[0]).VlanId | Should -Be 2203
        }
        It 'reads the management port of a 5.0 node from nodes[].management, 5.1''s dhcp as dhcp_reservation' {
            $infra = Import-AzlInfrastructure -Path $script:ExamplePath -SkipValidation
            $o = Get-AzlManagementAdapter -Infrastructure $infra -Node $infra.nodes[0]
            $o.Name | Should -Be 'Port1'; $o.IpAddress | Should -Be '192.0.2.11'; $o.Source | Should -Be 'management'; $o.IpAssignment | Should -Be 'static'
            $infra.networking.management.ip_assignment = 'dhcp'
            (Get-AzlManagementAdapter -Infrastructure $infra -Node $infra.nodes[0]).IpAssignment | Should -Be 'dhcp_reservation'
            Get-AzlManagementIpAssignment -Infrastructure $infra | Should -Be 'dhcp' -Because 'without -Node the site-wide key is read as it is'
        }
        It 'reads the IP assignment per node, and for the instance from the ports' {
            $infra = Import-AzlInfrastructure -Path $script:Lom
            Get-AzlManagementIpAssignment -Infrastructure $infra -Node $infra.nodes[0] | Should -Be 'static'
            Get-AzlManagementIpAssignment -Infrastructure $infra | Should -Be 'static'
            $infra.nodes[1].network_adapters[0].ip_assignment = 'dhcp_reservation'
            Get-AzlManagementIpAssignment -Infrastructure $infra | Should -Be 'mixed'
        }
        It 'merges a node''s BIOS settings over hardware.bios' {
            $infra = Import-AzlInfrastructure -Path $script:Lom
            $infra.nodes[1]['bios'] = [ordered]@{ Slot2 = 'Enabled'; SriovGlobalEnable = 'Enabled' }
            $b = Get-AzlBiosSetting -Infrastructure $infra -Node $infra.nodes[1]
            $b['Slot2'] | Should -Be 'Enabled'; $b['EmbNic1Nic2'] | Should -Be 'Enabled'; $b['SriovGlobalEnable'] | Should -Be 'Enabled'
            (Get-AzlBiosSetting -Infrastructure $infra -Node $infra.nodes[0])['Slot2'] | Should -Be 'Disabled'
        }
        It 'reads the site range from site_ip_range, else from the lowest to the highest static address' {
            $infra = Import-AzlInfrastructure -Path $script:Lom
            (Get-AzlSiteIpRange -Infrastructure $infra).Source | Should -Be 'site_ip_range'
            $infra.networking.management.Remove('site_ip_range')
            $infra.nodes[0].network_adapters[0].ip_address = '192.0.2.15'
            $r = Get-AzlSiteIpRange -Infrastructure $infra
            "$($r.Start)-$($r.End) $($r.Source)" | Should -Be '192.0.2.12-192.0.2.15 derived'
            Get-AzlSiteIpRange -Infrastructure (Import-AzlInfrastructure -Path (Join-Path $repo 'config\infrastructure\examples\single-machine-iso.yml') -SkipValidation) | Should -BeNullOrEmpty -Because 'a reserved address is not static'
        }
    }
}

Describe 'Import-AzlInfrastructure' {
    It 'returns the file when it is clean' {
        $infra = Import-AzlInfrastructure -Path $script:ExamplePath
        $infra.networking.management.gateway | Should -Be '192.0.2.1'
    }
    It 'stops with every error listed when it is not' {
        $file = Join-Path $TestDrive 'broken.yml'
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:ExamplePath -Raw) -Ordered
        $doc.cluster.name = 'a-cluster-name-too-long'
        $doc.networking.management.dns_servers = @('8.8.8.8')
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        { Import-AzlInfrastructure -Path $file } | Should -Throw -ExpectedMessage '*2 error(s)*'
    }
    It 'reads a value by path' {
        $infra = Import-AzlInfrastructure -Path $script:ExamplePath -SkipValidation
        Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.os_install' | Should -Be 'simplified'
        Get-AzlInfrastructureValue -Infrastructure $infra -Path 'no.such.key' | Should -BeNullOrEmpty
    }
}
