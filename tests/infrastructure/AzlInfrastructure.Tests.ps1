#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Contract tests for infrastructure.yml schema 5: every example is clean, and each rule catches what it should.
# Run: Invoke-Pester ./tests/infrastructure

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transport and mock script blocks keep the signature of the real ones.')]
param()

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module powershell-yaml
    $script:ExamplePath = Join-Path $repo 'config\variables\examples\infrastructure.example.yml'

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
        Get-ChildItem (Join-Path $PSScriptRoot '..\..\config\variables\examples') -Recurse -Filter '*.yml' | ForEach-Object FullName
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
        $f = Get-FindingFor -From (Join-Path $repo 'config\variables\examples\scenarios\local-identity-switchless-iso.yml') { param($d) $d.scenario.cloud = 'government' }
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
        $f = Get-FindingFor -From (Join-Path $repo 'config\variables\examples\scenarios\single-machine-iso.yml') { param($d) $d.nodes[0]['arc_machine_name'] = 'iic-edge-07-arc' }
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
        $script:Lom = Join-Path $repo 'config\variables\examples\scenarios\lom-management-ztp.yml'
        $script:NoDhcp = Join-Path $repo 'config\variables\examples\scenarios\no-dhcp-switchless.yml'
        # Findings for a change to the LOM-management example (two nodes, six ports each, simplified provisioning).
        function Get-LomFinding([scriptblock]$Change) { Get-FindingFor -From $script:Lom $Change }
        function Get-Port($Doc, [int]$Node, [string]$Name) { $Doc.nodes[$Node].network_adapters | Where-Object { $_.name -eq $Name } | Select-Object -First 1 }
    }

    Context 'schema' {
        It 'needs ip_address for static' {
            $f = Get-LomFinding { param($d) $p = Get-Port $d 0 'Embedded NIC 1'; $p.Remove('ip_address') }
            $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].network_adapters[0]' -and $_.Message -match 'ip_address' } | Should -Not -BeNullOrEmpty
        }
        It 'takes Mode A (dhcp_reservation) without ip_address: an error only where the deployment needs it, otherwise a warning' {
            $edit = { param($d) foreach ($n in 0, 1) { $p = Get-Port $d $n 'Embedded NIC 1'; $p.ip_assignment = 'dhcp_reservation'; $p.Remove('ip_address') } }
            $f = Get-LomFinding $edit
            @($f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Message -match 'ip_address' }) | Should -BeNullOrEmpty -Because 'only static requires it in the schema'
            $f | Where-Object { $_.Id -eq 'AZL-020' -and $_.Severity -eq 'error' -and $_.Path -eq 'nodes[0].network_adapters[0]' -and $_.Message -match 'The deployment needs' } | Should -Not -BeNullOrEmpty
            $ztp = Get-LomFinding { param($d) & $edit $d; $d._metadata['scope'] = 'ztp' }
            @($ztp | Where-Object { $_.Id -eq 'AZL-020' -and $_.Message -match 'The deployment needs' }) | Should -BeNullOrEmpty -Because 'a file with scope ztp does not deploy'
            $w = @($ztp | Where-Object { $_.Id -eq 'AZL-020' -and $_.Severity -eq 'warning' -and $_.Message -match "Mode A \(Reserved\) without ip_address: the expected reserved IP can't be verified" })
            $w.Count | Should -Be 2
            $w[0].Path | Should -Be 'nodes[0].network_adapters[0].ip_address'
            $dhcp = Get-LomFinding { param($d) & $edit $d; $d.networking.management['use_dhcp'] = $true }
            @($dhcp | Where-Object { $_.Id -eq 'AZL-020' -and $_.Message -match "can't be verified" }).Count | Should -Be 2 -Because 'use_dhcp needs no address, so only the warning stays'
        }
        It 'needs mac_address for a DHCP reservation' {
            $f = Get-FindingFor -From (Join-Path $repo 'config\variables\examples\scenarios\single-machine-iso.yml') { param($d) $d.nodes[0].network_adapters[0].Remove('mac_address') }
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
            (Get-LomFinding { param($d) $d.networking.management['site_ip_range'] = [ordered]@{ start = '192.0.2.11' } }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'networking.management.site_ip_range' } | Should -Not -BeNullOrEmpty
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
        It 'AZL-020 wants the management port first in the management intent: an error for a static plan and for a reservation' {
            $f = Get-LomFinding { param($d) $d.networking.intents[0].adapters = @('Embedded NIC 2', 'Embedded NIC 1') }
            @($f | Where-Object { $_.Id -eq 'AZL-020' -and $_.Message -match 'first adapter' } | ForEach-Object Severity | Select-Object -Unique) | Should -Be @('error')
            $f | Where-Object { $_.Id -eq 'AZL-020' -and $_.Message -match 'first adapter' } | ForEach-Object { $_.Message } | Select-Object -First 1 | Should -Match '0 gateways and 0 DNS'
            $f = Get-FindingFor -From (Join-Path $repo 'config\variables\examples\scenarios\single-machine-iso.yml') { param($d) $d.networking.intents[0].adapters = @('NIC2', 'NIC1') }
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
        It 'AZL-024 stops Mode C with no DHCP anywhere (G23), and warns that a static management port used for provisioning needs DHCP there (Mode B)' {
            $f = Get-LomFinding { param($d) $d.networking.management.provisioning_network = 'static' }
            $e = @($f | Where-Object { $_.Id -eq 'AZL-024' -and $_.Severity -eq 'error' })
            $e.Count | Should -Be 2
            $e[0].Path | Should -Be 'nodes[0].network_adapters'
            $e[0].Message | Should -Match "Mode C \(Static without management DHCP\): the maintenance environment can't reach Azure: no DHCP anywhere \(G23\); give a provisioning port with DHCP"
            @($f | Where-Object { $_.Id -eq 'AZL-024' -and $_.Message -match 'open research item' }) | Should -BeNullOrEmpty -Because 'the error says it'
            (Get-LomFinding { param($d) (Get-Port $d 0 'Embedded NIC 1').roles = @('management', 'provisioning') }) | Where-Object { $_.Id -eq 'AZL-024' -and $_.Severity -eq 'warning' -and $_.Message -match 'Mode B \(Static with DHCP\)\. A DHCP server must answer' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-024 takes Mode C with provisioning_network static when every node has a provisioning port on DHCP' {
            $f = Get-LomFinding { param($d) $d.networking.management.provisioning_network = 'static'; foreach ($n in 0, 1) { (Get-Port $d $n 'Slot 3 Port 1').ip_assignment = 'dhcp' } }
            @($f | Where-Object { $_.Id -eq 'AZL-024' -and $_.Severity -eq 'error' }) | Should -BeNullOrEmpty
            @($f | Where-Object { $_.Id -eq 'AZL-024' -and $_.Message -match 'open research item' }) | Should -BeNullOrEmpty
            # One node without it is still stopped.
            $one = Get-LomFinding { param($d) $d.networking.management.provisioning_network = 'static'; (Get-Port $d 0 'Slot 3 Port 1').ip_assignment = 'dhcp' }
            @($one | Where-Object { $_.Id -eq 'AZL-024' -and $_.Severity -eq 'error' } | ForEach-Object Path) | Should -Be @('nodes[1].network_adapters')
        }
        It 'AZL-024 still only warns about a static provisioning network when the management port is not static' {
            $f = Get-LomFinding { param($d) $d.networking.management.provisioning_network = 'static'; foreach ($n in 0, 1) { (Get-Port $d $n 'Embedded NIC 1').ip_assignment = 'dhcp_reservation' } }
            @($f | Where-Object { $_.Id -eq 'AZL-024' -and $_.Severity -eq 'error' }) | Should -BeNullOrEmpty
            $f | Where-Object { $_.Id -eq 'AZL-024' -and $_.Severity -eq 'warning' -and $_.Message -match 'open research item' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-024 stops Mode C on a node described with management only (schema 5.0/5.1)' {
            $f = Get-FindingFor { param($d) $d.networking.management.provisioning_network = 'static' }
            $f | Where-Object { $_.Id -eq 'AZL-024' -and $_.Severity -eq 'error' -and $_.Path -eq 'nodes[0].management' -and $_.Message -match 'G23' } | Should -Not -BeNullOrEmpty
        }
        It 'names each node''s management address mode: <Case>' -ForEach @(
            @{ Case = 'static on a port without role provisioning is Mode C'; Edit = { param($d) }; Mode = 'C'; Label = 'Mode C (Static without management DHCP)' }
            @{ Case = 'static on a port that is also the provisioning port is Mode B'; Edit = { param($d) (Get-Port $d 0 'Embedded NIC 1').roles = @('management', 'provisioning') }; Mode = 'B'; Label = 'Mode B (Static with DHCP)' }
            @{ Case = 'static with provisioning_network static is Mode C'; Edit = { param($d) (Get-Port $d 0 'Embedded NIC 1').roles = @('management', 'provisioning'); $d.networking.management.provisioning_network = 'static' }; Mode = 'C'; Label = 'Mode C (Static without management DHCP)' }
            @{ Case = 'dhcp_reservation is Mode A'; Edit = { param($d) (Get-Port $d 0 'Embedded NIC 1').ip_assignment = 'dhcp_reservation' }; Mode = 'A'; Label = 'Mode A (Reserved)' }
            @{ Case = 'dhcp is none of the three'; Edit = { param($d) (Get-Port $d 0 'Embedded NIC 1').ip_assignment = 'dhcp' }; Mode = ''; Label = 'dhcp without a reservation (not Mode A, B or C)' }
        ) {
            $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Lom -Raw) -Ordered
            & $Edit $doc
            $m = Get-AzlManagementMode -Infrastructure $doc -Node $doc.nodes[0]
            $m.Mode | Should -Be $Mode
            $m.Label | Should -Be $Label
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
            $infra.nodes[1]['bios'] = [ordered]@{ Slot2 = 'Disabled'; SriovGlobalEnable = 'Enabled' }
            $b = Get-AzlBiosSetting -Infrastructure $infra -Node $infra.nodes[1]
            $b['Slot2'] | Should -Be 'Disabled'; $b['EmbNic1Nic2'] | Should -Be 'Enabled'; $b['SriovGlobalEnable'] | Should -Be 'Enabled'
            (Get-AzlBiosSetting -Infrastructure $infra -Node $infra.nodes[0])['Slot2'] | Should -Be 'Enabled'
        }
        It 'reads the site range from site_ip_range, else from the lowest to the highest static address' {
            $infra = Import-AzlInfrastructure -Path $script:Lom
            $infra.networking.management['site_ip_range'] = [ordered]@{ start = '192.0.2.11'; end = '192.0.2.12' }
            (Get-AzlSiteIpRange -Infrastructure $infra).Source | Should -Be 'site_ip_range'
            $infra.networking.management.Remove('site_ip_range')
            $infra.nodes[0].network_adapters[0].ip_address = '192.0.2.15'
            $r = Get-AzlSiteIpRange -Infrastructure $infra
            "$($r.Start)-$($r.End) $($r.Source)" | Should -Be '192.0.2.12-192.0.2.15 derived'
            Get-AzlSiteIpRange -Infrastructure (Import-AzlInfrastructure -Path (Join-Path $repo 'config\variables\examples\scenarios\single-machine-iso.yml') -SkipValidation) | Should -BeNullOrEmpty -Because 'a reserved address is not static'
        }
    }
}

Describe 'Schema 5.3: BIOS phases, static method, maintenance environment' {
    BeforeAll {
        $script:Lom = Join-Path $repo 'config\variables\examples\scenarios\lom-management-ztp.yml'
        function Get-LomFinding([scriptblock]$Change) { Get-FindingFor -From $script:Lom $Change }
    }

    Context 'BIOS phases' {
        It 'reads the final state, the install-time state, and the keys to set back' {
            $infra = Import-AzlInfrastructure -Path $script:Lom
            $node = $infra.nodes[0]
            (Get-AzlBiosSetting -Infrastructure $infra -Node $node)['Slot2'] | Should -Be 'Enabled'
            (Get-AzlBiosSetting -Infrastructure $infra -Node $node -Phase DuringProvisioning)['Slot2'] | Should -Be 'Disabled' -Because 'during-provisioning wins over bios'
            (Get-AzlBiosSetting -Infrastructure $infra -Node $node -Phase DuringProvisioning)['EmbNic1Nic2'] | Should -Be 'Enabled' -Because 'bios still applies to the keys it names'
            $o = @(Get-AzlBiosProvisioningOverride -Infrastructure $infra -Node $node)
            $o.Count | Should -Be 1
            "$($o[0].Name) $($o[0].ProvisioningValue) $($o[0].FinalValue)" | Should -Be 'Slot2 Disabled Enabled'
        }
        It 'merges a node''s bios_during_provisioning over the hardware one' {
            $infra = Import-AzlInfrastructure -Path $script:Lom
            $infra.nodes[1]['bios_during_provisioning'] = [ordered]@{ Slot2 = 'BootDriverDisabled'; SriovGlobalEnable = 'Disabled' }
            $b = Get-AzlBiosSetting -Infrastructure $infra -Node $infra.nodes[1] -Phase DuringProvisioning
            $b['Slot2'] | Should -Be 'BootDriverDisabled'
            $b['SriovGlobalEnable'] | Should -Be 'Disabled'
            (Get-AzlBiosSetting -Infrastructure $infra -Node $infra.nodes[0] -Phase DuringProvisioning)['Slot2'] | Should -Be 'Disabled'
            (Get-AzlBiosProvisioningOverride -Infrastructure $infra -Node $infra.nodes[1] | Where-Object Name -eq 'SriovGlobalEnable').FinalValue | Should -BeNullOrEmpty
        }
        It 'AZL-026 warns about a temporary key that bios does not name' {
            $f = Get-LomFinding { param($d) $d.hardware.bios_during_provisioning['SriovGlobalEnable'] = 'Disabled' }
            $f | Where-Object { $_.Id -eq 'AZL-026' -and $_.Severity -eq 'warning' -and $_.Path -eq 'hardware.bios_during_provisioning.SriovGlobalEnable' } | Should -Not -BeNullOrEmpty
            @($f | Where-Object { $_.Id -eq 'AZL-026' }).Count | Should -Be 1 -Because 'a hardware-level key is reported once, not once per node'
        }
        It 'AZL-026 accepts a key that the node''s own bios names, and warns for a node key that nothing names' {
            $f = Get-LomFinding { param($d) $d.nodes[0]['bios_during_provisioning'] = [ordered]@{ SriovGlobalEnable = 'Disabled' }; $d.nodes[0]['bios'] = [ordered]@{ SriovGlobalEnable = 'Enabled' } }
            @($f | Where-Object Id -eq 'AZL-026') | Should -BeNullOrEmpty
            $f = Get-LomFinding { param($d) $d.nodes[1]['bios_during_provisioning'] = [ordered]@{ SriovGlobalEnable = 'Disabled' } }
            $f | Where-Object { $_.Id -eq 'AZL-026' -and $_.Path -eq 'nodes[1].bios_during_provisioning.SriovGlobalEnable' } | Should -Not -BeNullOrEmpty
        }
        It 'takes during-provisioning values as strings with attribute-like names' {
            (Get-LomFinding { param($d) $d.hardware.bios_during_provisioning['Slot2'] = 0 }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'hardware.bios_during_provisioning.Slot2' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $d.nodes[0]['bios_during_provisioning'] = [ordered]@{ 'Slot 2' = 'Disabled' } }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].bios_during_provisioning.Slot 2' } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'static method and the maintenance environment' {
        It 'defaults to device, and reads site' {
            $infra = Import-AzlInfrastructure -Path $script:Lom
            Get-AzlManagementStaticMethod -Infrastructure $infra | Should -Be 'device'
            $infra.networking.management['static_method'] = 'site'
            Get-AzlManagementStaticMethod -Infrastructure $infra | Should -Be 'site'
            $infra.networking.management.Remove('static_method')
            Get-AzlManagementStaticMethod -Infrastructure $infra | Should -Be 'device'
        }
        It 'rejects an unknown static_method' {
            (Get-LomFinding { param($d) $d.networking.management.static_method = 'hybrid' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'networking.management.static_method' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-027 warns that the site method uses the first ready port, not the MAC' {
            $f = Get-LomFinding { param($d) $d.networking.management.static_method = 'site' }
            $f | Where-Object { $_.Id -eq 'AZL-027' -and $_.Severity -eq 'warning' -and $_.Message -match 'first ready port' } | Should -Not -BeNullOrEmpty
            @(Get-LomFinding { param($d) }) | Where-Object Id -eq 'AZL-027' | Should -BeNullOrEmpty
        }
        It 'AZL-027 checks provisioning_dhcp_range: <Case>' -ForEach @(
            @{ Case = 'reversed'; Range = @('192.0.2.150', '192.0.2.100'); Expect = 'after its end' }
            @{ Case = 'outside the subnet'; Range = @('192.0.2.200', '192.0.3.10'); Expect = "isn't inside the management subnet" }
            @{ Case = 'start outside the subnet'; Range = @('198.51.100.10', '192.0.2.10'); Expect = "isn't inside the management subnet" }
        ) {
            $r = $Range
            $f = Get-LomFinding { param($d) $d.networking.management.provisioning_dhcp_range = [ordered]@{ start = $r[0]; end = $r[1] } }
            $f | Where-Object { $_.Id -eq 'AZL-027' -and $_.Severity -eq 'error' -and $_.Message -match $Expect } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-027 accepts a range with start equal to end' {
            $f = Get-LomFinding { param($d) $d.networking.management.provisioning_dhcp_range = [ordered]@{ start = '192.0.2.100'; end = '192.0.2.100' } }
            @($f | Where-Object Id -eq 'AZL-027') | Should -BeNullOrEmpty
        }
        It 'needs both ends of provisioning_dhcp_range, and IPv4 addresses' {
            (Get-LomFinding { param($d) $d.networking.management.provisioning_dhcp_range.Remove('end') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'networking.management.provisioning_dhcp_range' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $d.nodes[0]['maintenance_address'] = 'not-an-address' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].maintenance_address' } | Should -Not -BeNullOrEmpty
        }
        It 'AZL-027 refuses one maintenance address on two nodes' {
            $f = Get-LomFinding { param($d) $d.nodes[0]['maintenance_address'] = '192.0.2.102' }
            $f | Where-Object { $_.Id -eq 'AZL-027' -and $_.Severity -eq 'error' -and $_.Message -match 'Maintenance address 192.0.2.102 is used by 2 nodes' } | Should -Not -BeNullOrEmpty
        }
        It 'takes maintenance_password only as a Key Vault reference, from a listed vault' {
            (Get-LomFinding { param($d) $d.provisioning.simplified.maintenance_password = 'Password1' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'provisioning.simplified.maintenance_password' } | Should -Not -BeNullOrEmpty
            (Get-LomFinding { param($d) $d.provisioning.simplified.maintenance_password = 'keyvault://kv-unlisted-01/maintenance-password' }).Id | Should -Contain 'AZL-001'
        }
        It 'does not warn about mixed static and DHCP management ports with the device method' {
            $f = Get-LomFinding { param($d) $p = $d.nodes[1].network_adapters[0]; $p.ip_assignment = 'dhcp_reservation' }
            @($f | Where-Object { $_.Id -eq 'AZL-025' -and $_.Message -match 'mix' }) | Should -BeNullOrEmpty
            $f = Get-LomFinding { param($d) $d.networking.management.static_method = 'site'; $d.nodes[1].network_adapters[0].ip_assignment = 'dhcp_reservation' }
            @($f | Where-Object { $_.Id -eq 'AZL-025' -and $_.Message -match 'mix' }) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Schema 5.3: SAN' {
    BeforeAll {
        $script:Fc = Join-Path $repo 'config\variables\examples\scenarios\disaggregated-fibre-channel-proxy.yml'
        $script:Iscsi = Join-Path $repo 'config\variables\examples\scenarios\disaggregated-iscsi.yml'
        function Get-FcFinding([scriptblock]$Change) { Get-FindingFor -From $script:Fc $Change }
        function Get-IscsiFinding([scriptblock]$Change) { Get-FindingFor -From $script:Iscsi $Change }
    }

    Context 'schema' {
        It 'needs storage.san for a SAN or hybrid; the block that goes with its type is not a schema requirement (a hybrid file may leave it out: AZL-028 says what is missing)' {
            (Get-FcFinding { param($d) $d.storage.Remove('san') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Message -match 'san' } | Should -Not -BeNullOrEmpty
            (Get-FcFinding { param($d) $d.scenario.storage_architecture = 'hybrid'; $d.storage.Remove('san') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Message -match 'san' } | Should -Not -BeNullOrEmpty
            # Not a schema error any more (only storage.san.type is required): the rule says what is missing, an error for a disaggregated design and a warning for hybrid.
            (Get-FcFinding { param($d) $d.storage.san.Remove('fibre_channel') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'storage.san' } | Should -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.storage.san.Remove('iscsi') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'storage.san' } | Should -BeNullOrEmpty
            (Get-FcFinding { param($d) $d.storage.san.Remove('fibre_channel') }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' -and $_.Path -eq 'storage.san.fibre_channel.target_wwpns' } | Should -Not -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.storage.san.Remove('iscsi') }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' -and $_.Path -eq 'storage.san.iscsi.targets' } | Should -Not -BeNullOrEmpty
            (Get-FcFinding { param($d) $d.scenario.storage_architecture = 'hybrid'; $d.storage.san.Remove('fibre_channel') }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'warning' -and $_.Path -eq 'storage.san.fibre_channel.target_wwpns' } | Should -Not -BeNullOrEmpty
        }
        It 'checks the WWPN form: 16 hex digits, with or without colons' {
            (Get-FcFinding { param($d) $d.storage.san.fibre_channel.target_wwpns[0].wwpn = '5000000000000AAA' }) | Where-Object Severity -eq 'error' | Should -BeNullOrEmpty
            (Get-FcFinding { param($d) $d.storage.san.fibre_channel.target_wwpns[0].wwpn = '50:00:00:00:00:00:01' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'storage.san.fibre_channel.target_wwpns[0].wwpn' } | Should -Not -BeNullOrEmpty
            (Get-FcFinding { param($d) $d.nodes[0].san.hbas[0].ports[0].wwpn = '10:00:00:00:00:00:00:1G' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].san.hbas[0].ports[0].wwpn' } | Should -Not -BeNullOrEmpty
        }
        It 'needs the array''s name, vendor and model, and an IPv4 management address' {
            (Get-FcFinding { param($d) $d.storage.san.array.Remove('model') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'storage.san.array' -and $_.Message -match 'model' } | Should -Not -BeNullOrEmpty
            (Get-FcFinding { param($d) $d.storage.san.array.management_address = 'san-01' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'storage.san.array.management_address' } | Should -Not -BeNullOrEmpty
        }
        It 'checks iSCSI portals (ipv4 or ipv4:port), IQNs and CHAP' {
            (Get-IscsiFinding { param($d) $d.storage.san.iscsi.targets[0].portals = @('198.51.100.4:65535', '198.51.100.5') }) | Where-Object Severity -eq 'error' | Should -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.storage.san.iscsi.targets[0].portals = @('198.51.100.4:70000') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'storage.san.iscsi.targets[0].portals[0]' } | Should -Not -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.storage.san.iscsi.targets[0].portals = @('san-01.improbability.cloud') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'storage.san.iscsi.targets[0].portals[0]' } | Should -Not -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.nodes[0].san.initiator_iqn = 'initiator-one' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].san.initiator_iqn' } | Should -Not -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.storage.san.iscsi.chap.Remove('secret') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'storage.san.iscsi.chap' -and $_.Message -match 'secret' } | Should -Not -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.storage.san.iscsi.chap = [ordered]@{ enabled = $false } }) | Where-Object Severity -eq 'error' | Should -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.storage.san.iscsi.chap.secret = 'a-plain-secret' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'storage.san.iscsi.chap.secret' } | Should -Not -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.storage.san.iscsi.chap.secret = 'keyvault://kv-unlisted-01/chap' }).Id | Should -Contain 'AZL-001'
        }
        It 'takes iscsi:a and iscsi:b as port roles' {
            (Get-IscsiFinding { param($d) $d.nodes[0].network_adapters[2].roles = @('iscsi:c') }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -like 'nodes[[]0].network_adapters[[]2].roles*' } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'rules (AZL-028)' {
        It 'needs the target WWPNs' {
            (Get-FcFinding { param($d) $d.storage.san.fibre_channel.Remove('target_wwpns') }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Path -eq 'storage.san.fibre_channel.target_wwpns' } | Should -Not -BeNullOrEmpty
        }
        It 'needs every node''s HBA WWPNs' {
            $f = Get-FcFinding { param($d) $d.nodes[2].Remove('san') }
            $f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' -and $_.Path -eq 'nodes[2].san' -and $_.Message -match 'iic-dc02-n03' } | Should -Not -BeNullOrEmpty
            @($f | Where-Object { $_.Id -eq 'AZL-028' }).Count | Should -Be 1
        }
        It 'needs every WWPN''s fabric to be a defined fabric' {
            $f = Get-FcFinding { param($d) $d.nodes[0].san.hbas[0].ports[1].fabric = 'C'; $d.storage.san.fibre_channel.target_wwpns[0].fabric = 'D' }
            $f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Path -eq 'nodes[0].san.hbas[0].ports[1].fabric' -and $_.Message -match "'C'" } | Should -Not -BeNullOrEmpty
            $f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Path -eq 'storage.san.fibre_channel.target_wwpns[0].fabric' } | Should -Not -BeNullOrEmpty
            $f = Get-FcFinding { param($d) $d.storage.san.fibre_channel.Remove('fabrics') }
            $f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Message -match 'none are listed' } | Should -Not -BeNullOrEmpty
        }
        It 'refuses a duplicate WWPN, whatever the notation' {
            $f = Get-FcFinding { param($d) $d.nodes[1].san.hbas[0].ports[0].wwpn = '1000000000000011' }
            $f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' -and $_.Message -match 'WWPN .* is listed 2 times' } | Should -Not -BeNullOrEmpty
            $f = Get-FcFinding { param($d) $d.nodes[0].san.hbas[0].ports[0].wwpn = $d.storage.san.fibre_channel.target_wwpns[0].wwpn.ToLowerInvariant() }
            $f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Message -match 'listed 2 times' } | Should -Not -BeNullOrEmpty
        }
        It 'refuses a duplicate fabric name' {
            (Get-FcFinding { param($d) $d.storage.san.fibre_channel.fabrics[1].name = 'a' }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Path -eq 'storage.san.fibre_channel.fabrics' } | Should -Not -BeNullOrEmpty
        }
        It 'warns about an iSCSI initiator on a Fibre Channel SAN' {
            (Get-FcFinding { param($d) $d.nodes[0].san['initiator_iqn'] = 'iqn.1991-05.com.microsoft:iic-dc02-n01' }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'warning' } | Should -Not -BeNullOrEmpty
        }
        It 'needs the iSCSI targets and every node''s initiator IQN' {
            (Get-IscsiFinding { param($d) $d.storage.san.iscsi.Remove('targets') }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Path -eq 'storage.san.iscsi.targets' } | Should -Not -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.nodes[1].san.Remove('initiator_iqn') }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' -and $_.Path -eq 'nodes[1].san' } | Should -Not -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.nodes[1].Remove('san') }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Path -eq 'nodes[1].san' } | Should -Not -BeNullOrEmpty
        }
        It 'refuses a duplicate IQN, case aside, among the targets and the initiators' {
            $f = Get-IscsiFinding { param($d) $d.nodes[1].san.initiator_iqn = $d.nodes[0].san.initiator_iqn.ToUpperInvariant().Replace('IQN.', 'iqn.') }
            $f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' -and $_.Message -match 'IQN .* is listed 2 times' } | Should -Not -BeNullOrEmpty
            $f = Get-IscsiFinding { param($d) $d.nodes[0].san.initiator_iqn = $d.storage.san.iscsi.targets[0].iqn }
            $f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Message -match 'listed 2 times' } | Should -Not -BeNullOrEmpty
        }
        It 'wants the iSCSI ports listed with an address' {
            (Get-IscsiFinding { param($d) $d.nodes[0].network_adapters[2].roles = @('compute') ; $d.nodes[0].network_adapters[3].roles = @('compute') }) | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'warning' -and $_.Path -eq 'nodes[0].network_adapters' } | Should -Not -BeNullOrEmpty
            $f = Get-IscsiFinding { param($d) $p = $d.nodes[0].network_adapters[2]; $p.ip_assignment = 'none'; $p.Remove('ip_address'); $p.Remove('prefix_length') }
            $f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' -and $_.Path -eq 'nodes[0].network_adapters[2].ip_assignment' } | Should -Not -BeNullOrEmpty
        }
        It 'keeps the iSCSI ports on the shared port rules: a static address needs a prefix_length, and no second gateway' {
            (Get-IscsiFinding { param($d) $d.nodes[0].network_adapters[2].Remove('prefix_length') }) | Where-Object { $_.Id -eq 'AZL-022' -and $_.Path -eq 'nodes[0].network_adapters[2].prefix_length' } | Should -Not -BeNullOrEmpty
            (Get-IscsiFinding { param($d) $d.nodes[0].network_adapters[2].gateway = '198.51.100.1' }) | Where-Object { $_.Id -eq 'AZL-022' -and $_.Severity -eq 'error' } | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Schema 5.3: file scope (full and ztp templates)' {
    BeforeAll {
        $script:Full = Join-Path $repo 'config\variables\examples\infrastructure.example.yml'
        $script:Ztp = Join-Path $repo 'config\variables\examples\infrastructure.ztp.example.yml'
        function Get-ZtpFinding([scriptblock]$Change) { Get-FindingFor -From $script:Ztp $Change }
    }

    It 'validates both templates with no errors and no warnings' {
        @(Test-AzlInfrastructure -Path $script:Full) | Should -BeNullOrEmpty
        @(Test-AzlInfrastructure -Path $script:Ztp) | Should -BeNullOrEmpty
    }
    It 'reads the scope: full by default, ztp when set' {
        Get-AzlInfrastructureScope -Infrastructure (Import-AzlInfrastructure -Path $script:Full) | Should -Be 'full'
        Get-AzlInfrastructureScope -Infrastructure (Import-AzlInfrastructure -Path $script:Ztp) | Should -Be 'ztp'
    }
    It 'accepts a ztp file with no cluster, environment, intents, storage or scenario choices' {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Ztp -Raw) -Ordered
        foreach ($k in 'cluster', 'environment', 'storage', 'sdn', 'security') { $doc.Keys | Should -Not -Contain $k }
        $doc.networking.Keys | Should -Not -Contain 'intents'
        $doc.identity.Keys | Should -Be @('local_admin')
        @($doc.scenario.Keys) | Should -Be @('os_install')
    }
    It 'rejects a full-scope file without the cluster keys: <Case>' -ForEach @(
        @{ Case = 'the ztp template with scope full'; Change = { param($d) $d._metadata.scope = 'full' }; Expect = 'cluster' }
        @{ Case = 'the ztp template with the scope removed'; Change = { param($d) $d._metadata.Remove('scope') }; Expect = 'environment' }
        @{ Case = 'the ztp template with scope full, intents missing'; Change = { param($d) $d._metadata.scope = 'full' }; Expect = 'intents' }
    ) {
        $f = Get-ZtpFinding $Change
        @($f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Message -match $Expect }) | Should -Not -BeNullOrEmpty
        $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Message -match 'scenario|identity|environment|cluster' } | Should -Not -BeNullOrEmpty
    }
    It 'rejects the full template without cluster, and still enforces the scenario switches' {
        $f = Get-FindingFor -From $script:Full { param($d) $d.Remove('cluster'); $d.networking.Remove('intents') }
        @($f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Message -match 'cluster' }) | Should -Not -BeNullOrEmpty
        @($f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Message -match 'intents' }) | Should -Not -BeNullOrEmpty
        (Get-FindingFor -From $script:Full { param($d) $d.scenario.identity = 'local_identity' }) | Where-Object { $_.Path -eq 'identity' -and $_.Message -match 'local_identity' } | Should -Not -BeNullOrEmpty
        (Get-FindingFor -From $script:Full { param($d) $d.networking.management.Remove('infrastructure_pool') }) | Where-Object { $_.Message -match 'infrastructure_pool' } | Should -Not -BeNullOrEmpty
    }
    It 'rejects a ztp file missing the ZTP key <Case>' -ForEach @(
        @{ Case = 'azure.tenant_id'; Change = { param($d) $d.azure.Remove('tenant_id') }; Path = 'azure' }
        @{ Case = 'azure.resource_group'; Change = { param($d) $d.azure.Remove('resource_group') }; Path = 'azure' }
        @{ Case = 'site.time_zone'; Change = { param($d) $d.site.Remove('time_zone') }; Path = 'site' }
        @{ Case = 'key_vaults'; Change = { param($d) $d.Remove('key_vaults') }; Path = '' }
        @{ Case = 'hardware.bmc'; Change = { param($d) $d.hardware.Remove('bmc') }; Path = 'hardware' }
        @{ Case = 'nodes[].serial_number'; Change = { param($d) $d.nodes[0].Remove('serial_number') }; Path = 'nodes[0]' }
        @{ Case = 'nodes[].bmc.ip_address'; Change = { param($d) $d.nodes[1].bmc.Remove('ip_address') }; Path = 'nodes[1].bmc' }
        @{ Case = 'the management port MAC'; Change = { param($d) $d.nodes[0].network_adapters[0].Remove('mac_address') }; Path = 'nodes[0].network_adapters[0]' }
        @{ Case = 'the provisioning port'; Change = { param($d) $d.nodes[1].network_adapters.RemoveAt(2) }; Path = 'nodes[1].network_adapters' }
        @{ Case = 'networking.management.gateway'; Change = { param($d) $d.networking.management.Remove('gateway') }; Path = 'networking.management' }
        @{ Case = 'identity.local_admin'; Change = { param($d) $d.identity.Remove('local_admin') }; Path = 'identity' }
        @{ Case = 'provisioning.simplified'; Change = { param($d) $d.provisioning.Remove('simplified') }; Path = 'provisioning' }
        @{ Case = 'provisioning.simplified.site_name'; Change = { param($d) $d.provisioning.simplified.Remove('site_name') }; Path = 'provisioning.simplified' }
        @{ Case = 'scenario.os_install'; Change = { param($d) $d.scenario.Remove('os_install') }; Path = 'scenario' }
        @{ Case = 'scenario.os_install simplified'; Change = { param($d) $d.scenario.os_install = 'iso' }; Path = 'scenario.os_install' }
    ) {
        $f = Get-ZtpFinding $Change
        @($f | Where-Object { $_.Severity -eq 'error' -and ($_.Path -eq $Path -or $_.Path -like "$Path*") }) | Should -Not -BeNullOrEmpty -Because "removing $Case must fail"
    }
    It 'applies the shared rules to a ztp file: the 5.3 keys, the ports and the vaults' {
        (Get-ZtpFinding { param($d) $d.networking.management.provisioning_dhcp_range.end = '192.0.3.9' }).Id | Should -Contain 'AZL-027'
        (Get-ZtpFinding { param($d) $d.hardware['bios_during_provisioning'] = [ordered]@{ SriovGlobalEnable = 'Disabled' } }).Id | Should -Contain 'AZL-026'
        (Get-ZtpFinding { param($d) $d.nodes[1].network_adapters[0].mac_address = $d.nodes[0].network_adapters[0].mac_address }).Id | Should -Contain 'AZL-019'
        (Get-ZtpFinding { param($d) $d.hardware.bmc.password = 'keyvault://kv-unlisted-01/bmc-password' }).Id | Should -Contain 'AZL-001'
    }
    It 'does not warn about ports in no intent in a ztp file, but does in a full file' {
        $f = Get-ZtpFinding { param($d) foreach ($n in $d.nodes) { $n.network_adapters.Add([ordered]@{ name = 'OCP 1'; roles = @('compute'); ip_assignment = 'none' }) } }
        @($f | Where-Object { $_.Id -eq 'AZL-021' }) | Should -BeNullOrEmpty
        $f = Get-ZtpFinding { param($d) $d._metadata.scope = 'full'; foreach ($n in $d.nodes) { $n.network_adapters.Add([ordered]@{ name = 'OCP 1'; roles = @('compute'); ip_assignment = 'none' }) } }
        @($f | Where-Object { $_.Id -eq 'AZL-021' -and $_.Message -match "isn't in any intent" }) | Should -Not -BeNullOrEmpty
    }
    It 'rejects an unknown scope' {
        (Get-ZtpFinding { param($d) $d._metadata.scope = 'cluster' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq '_metadata.scope' } | Should -Not -BeNullOrEmpty
    }
}

Describe 'Variables reference (VARIABLES.md)' {
    BeforeAll {
        $script:Config = Join-Path $repo 'config\variables'
        $script:Page = Join-Path $script:Config 'docs\VARIABLES.md'
        $script:Generator = Join-Path $repo 'scripts\common\infrastructure\New-InfrastructureVariablesReference.ps1'
        $script:PageText = (Get-Content -LiteralPath $script:Page -Raw).Replace("`r`n", "`n")
        $script:PagePaths = @([regex]::Matches($script:PageText, '(?m)^\| `([^`|]+)`') | ForEach-Object { $_.Groups[1].Value })

        function Get-LeafPath($Obj, [string]$Path) {
            if ($Obj -is [System.Collections.IDictionary]) {
                foreach ($k in $Obj.Keys) { Get-LeafPath $Obj[$k] $(if ($Path) { "$Path.$k" } else { [string]$k }) }
            } elseif ($Obj -is [System.Collections.IList] -and @($Obj | Where-Object { $_ -is [System.Collections.IDictionary] }).Count -gt 0) {
                foreach ($item in $Obj) { Get-LeafPath $item "$Path[]" }
            } else { $Path }
        }
    }

    It 'is current: regenerating it from the schema gives the same page' {
        $out = Join-Path $TestDrive 'VARIABLES.md'
        & $script:Generator -OutputPath $out | Out-Null
        (Get-Content -LiteralPath $out -Raw).Replace("`r`n", "`n") | Should -BeExactly $script:PageText -Because 'run ./scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1 and commit the result'
    }
    It 'has a row for every key used in <_>' -ForEach @(
        'examples\infrastructure.example.yml', 'examples\infrastructure.ztp.example.yml',
        'examples\scenarios\disaggregated-fibre-channel-proxy.yml', 'examples\scenarios\disaggregated-iscsi.yml', 'examples\scenarios\lom-management-ztp.yml', 'examples\scenarios\no-dhcp-switchless.yml'
    ) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $script:Config $_) -Raw) -Ordered
        $missing = @(Get-LeafPath $doc '' | Where-Object { $_ -notmatch '^extensions' } | Where-Object {
                $path = $_
                $isMapKey = $path -match '^(.*)\.[^.\[\]]+$' -and ($script:PagePaths -contains "$($Matches[1]).<attribute>")
                -not $isMapKey -and ($script:PagePaths -notcontains $path)
            })
        $missing | Should -BeNullOrEmpty
    }
    It 'covers the 5.3 keys, with their required and default columns' {
        foreach ($p in 'hardware.bios_during_provisioning', 'nodes[].bios_during_provisioning', 'networking.management.static_method', 'networking.management.provisioning_dhcp_range', 'nodes[].maintenance_address', 'provisioning.simplified.maintenance_password', 'storage.san.array', 'storage.san.fibre_channel.target_wwpns', 'storage.san.iscsi.targets', 'nodes[].san.hbas', 'nodes[].san.initiator_iqn', '_metadata.scope') {
            $script:PagePaths | Should -Contain $p
        }
        $script:PageText | Should -Match '(?m)^\| `networking.management.static_method` .*\| `device` \|'
        $script:PageText | Should -Match '(?m)^\| `site.time_zone` .*\| no / yes \|'
        $script:PageText | Should -Match '(?m)^\| `cluster.name` .*\| yes / if section is set \|'
        $script:PageText | Should -Match '(?m)^\| `nodes\[\].serial_number` .*\| when scenario.os_install is simplified / yes \|'
    }
    It 'groups the rows by section, in the schema''s order' {
        $schema = Get-Content -LiteralPath (Join-Path $script:Config 'schema\infrastructure.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $headings = @([regex]::Matches($script:PageText, '(?m)^### (\S+)$') | ForEach-Object { $_.Groups[1].Value })
        $headings | Should -Be @($schema.properties.Keys)
    }
    It 'lists the keyvault:// secrets by vault and secret name, and says no value goes in the file' {
        $script:PageText | Should -Match '## Secrets: keyvault:// references'
        $script:PageText | Should -Match 'No secret value is ever written in the file'
        $script:PageText | Should -Match '(?m)^\| `identity.local_admin.password` \| `kv-iic-mgmt-01` \| `local-admin-password` \|'
        $script:PageText | Should -Match '(?m)^\| `hardware.bmc.password` \| `kv-iic-mgmt-01` \| `bmc-password` \|'
    }
    It 'says where the folders go: outside every git repository, with the disk space' {
        $section = [regex]::Match($script:PageText, '(?s)## Folders on the management host.*?(?=\n## )').Value
        $section | Should -Match 'outside every git working tree'
        foreach ($p in 'provisioning.simplified.media_path', 'provisioning.simplified.evidence_path', 'hardware.sbe.bundle_path') { $section | Should -Match ([regex]::Escape($p)) }
        $section | Should -Match 'GB'
    }
    It 'is linked from the README and from both templates' {
        (Get-Content -LiteralPath (Join-Path $script:Config 'docs\infrastructure-file.md') -Raw) | Should -Match '\]\(VARIABLES\.md\)'
        (Get-Content -LiteralPath (Join-Path $script:Config 'examples\infrastructure.example.yml') -Raw) | Should -Match 'Variables: config/variables/docs/VARIABLES\.md'
        (Get-Content -LiteralPath (Join-Path $script:Config 'examples\infrastructure.ztp.example.yml') -Raw) | Should -Match 'Variables: config/variables/docs/VARIABLES\.md'
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
        $doc.identity.active_directory.Remove('domain_controllers') # AZL-052 would add a third error
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        { Import-AzlInfrastructure -Path $file } | Should -Throw -ExpectedMessage '*2 error(s)*'
    }
    It 'reads a value by path' {
        $infra = Import-AzlInfrastructure -Path $script:ExamplePath -SkipValidation
        Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.os_install' | Should -Be 'simplified'
        Get-AzlInfrastructureValue -Infrastructure $infra -Path 'no.such.key' | Should -BeNullOrEmpty
    }
}

Describe 'Schema 5.4: ZTP settings and the BIOS actions derived from the inventory' {
    BeforeAll {
        $script:Ztp54 = Join-Path $repo 'config\variables\examples\infrastructure.ztp.example.yml'
        $script:Full54 = Join-Path $repo 'config\variables\examples\infrastructure.example.yml'
        function Get-Ztp54Finding([scriptblock]$Change) { Get-FindingFor -From $script:Ztp54 $Change }
    }

    Context 'the templates' {
        It 'are schema 5.6.0 and clean' {
            foreach ($f in $script:Ztp54, $script:Full54) {
                (Import-AzlInfrastructure -Path $f)._metadata.schema_version | Should -Be '5.6.0'
                @(Test-AzlInfrastructure -Path $f) | Should -BeNullOrEmpty
            }
        }
        It 'use the new keys with the values ZTP always used' {
            $s = (Import-AzlInfrastructure -Path $script:Full54).provisioning.simplified
            $s.usb_image.size_gb | Should -Be 4
            $s.maintenance_environment.port | Should -Be 20001
            $s.maintenance_environment.username | Should -Be 'edgeuser'
            $s.timeouts.bootstrap_minutes | Should -Be 120
            $s.timeouts.adapters_minutes | Should -Be 10
            $s.timeouts.ready_minutes | Should -Be 180
            $s.configuration_name | Should -Be 'default'
            $s.network_kind | Should -Be 'LAN'
            $s.media_share.account_name | Should -Be 'svc-ztp-media'
        }
        It 'list a server with two adapter types: an embedded LOM, a PCIe NIC, and a Fibre Channel HBA in its own slot' {
            $n = (Import-AzlInfrastructure -Path $script:Ztp54).nodes[0]
            @($n.network_adapters | ForEach-Object slot | Select-Object -Unique) | Should -Contain 'Embedded'
            @($n.network_adapters | ForEach-Object slot | Select-Object -Unique) | Should -Contain 'Slot 3'
            $n.san.hbas[0].slot | Should -Be 'Slot 2'
        }
        It 'still accepts a 5.3.0 file that uses none of the new keys' {
            $f = Get-Ztp54Finding { param($d) $d._metadata.schema_version = '5.3.0'; foreach ($k in 'isolate_san_adapters', 'enable_embedded_nics') { $d.provisioning.simplified.Remove($k) } }
            @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
        }
    }

    Context 'schema' {
        It 'rejects <Name>' -ForEach @(
            @{ Name = 'a zero Bootstrap budget'; Change = { param($d) $d.provisioning.simplified['timeouts'] = @{ bootstrap_minutes = 0 } }; Path = 'provisioning.simplified.timeouts.bootstrap_minutes' }
            @{ Name = 'a port above 65535'; Change = { param($d) $d.provisioning.simplified['maintenance_environment'] = @{ port = 70000 } }; Path = 'provisioning.simplified.maintenance_environment.port' }
            @{ Name = 'a network kind that is neither LAN nor WLAN'; Change = { param($d) $d.provisioning.simplified['network_kind'] = 'WAN' }; Path = 'provisioning.simplified.network_kind' }
            @{ Name = 'a site mode that is not Auto, Create or Reuse'; Change = { param($d) $d.provisioning.simplified['site_mode'] = 'Maybe' }; Path = 'provisioning.simplified.site_mode' }
            @{ Name = 'an unknown timeout'; Change = { param($d) $d.provisioning.simplified['timeouts'] = @{ forever = 1 } }; Path = 'provisioning.simplified.timeouts.forever' }
            @{ Name = 'an image under 2 GiB'; Change = { param($d) $d.provisioning.simplified['usb_image'] = @{ size_gb = 1 } }; Path = 'provisioning.simplified.usb_image.size_gb' }
            @{ Name = 'a text switch'; Change = { param($d) $d.provisioning.simplified['isolate_san_adapters'] = 'yes please' }; Path = 'provisioning.simplified.isolate_san_adapters' }
            @{ Name = 'an HBA type that is not fibre_channel or iscsi_offload'; Change = { param($d) $d.nodes[0].san.hbas[0]['type'] = 'infiniband' }; Path = 'nodes[0].san.hbas[0].type' }
            @{ Name = 'a BMC certificate switch that is not boolean'; Change = { param($d) $d.hardware.bmc['verify_certificate'] = 'sometimes' }; Path = 'hardware.bmc.verify_certificate' }
        ) {
            $f = Get-Ztp54Finding $Change
            @($f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq $Path }) | Should -Not -BeNullOrEmpty
        }
        It 'accepts an HBA with only its slot (ports are for zoning, not for the BIOS action)' {
            @(Get-Ztp54Finding { param($d) $d.nodes[0].san.hbas[0] = @{ slot = 'Slot 2' } } | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
        }
        It 'accepts an iSCSI offload adapter with no ports' {
            @(Get-Ztp54Finding { param($d) $d.nodes[0].san.hbas[0] = @{ slot = 'Slot 4'; type = 'iscsi_offload' } } | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
        }
    }

    Context 'rules (AZL-029)' {
        It 'is quiet for the template: one FC HBA in a slot of its own' {
            @(Get-Ztp54Finding { param($d) } | Where-Object Id -eq 'AZL-029') | Should -BeNullOrEmpty
        }
        It 'refuses an HBA slot that is not a PCIe slot label while isolation is on' {
            $f = Get-Ztp54Finding { param($d) $d.nodes[0].san.hbas[0].slot = 'OCP 1' }
            $f | Where-Object { $_.Id -eq 'AZL-029' -and $_.Severity -eq 'error' -and $_.Path -eq 'nodes[0].san.hbas[0].slot' -and $_.Message -match 'OCP 1' } | Should -Not -BeNullOrEmpty
        }
        It 'accepts Slot2, slot 2 and SLOT-2 as the same label' {
            foreach ($label in 'Slot2', 'slot 2', 'SLOT-2') {
                @(Get-Ztp54Finding { param($d) $d.nodes[0].san.hbas[0].slot = $label } | Where-Object Id -eq 'AZL-029') | Should -BeNullOrEmpty
            }
        }
        It 'lets an odd label through when isolation is off' {
            @(Get-Ztp54Finding { param($d) $d.nodes[0].san.hbas[0].slot = 'OCP 1'; $d.provisioning.simplified.isolate_san_adapters = $false } | Where-Object Id -eq 'AZL-029') | Should -BeNullOrEmpty
        }
        It 'refuses to turn off a slot that also carries a network port' {
            $f = Get-Ztp54Finding { param($d) $d.nodes[0].san.hbas[0].slot = 'Slot 3' }
            $f | Where-Object { $_.Id -eq 'AZL-029' -and $_.Severity -eq 'error' -and $_.Message -match 'Slot 3 Port 1' } | Should -Not -BeNullOrEmpty
        }
        It 'warns when isolation is on and no node lists an adapter' {
            $f = Get-Ztp54Finding { param($d) foreach ($n in $d.nodes) { $n.Remove('san') } }
            $f | Where-Object { $_.Id -eq 'AZL-029' -and $_.Severity -eq 'warning' -and $_.Path -eq 'provisioning.simplified.isolate_san_adapters' } | Should -Not -BeNullOrEmpty
        }
        It 'needs nothing from a server with no SAN and the switch left out' {
            $f = Get-Ztp54Finding { param($d) foreach ($n in $d.nodes) { $n.Remove('san') }; $d.provisioning.simplified.Remove('isolate_san_adapters') }
            @($f | Where-Object Id -eq 'AZL-029') | Should -BeNullOrEmpty
        }
        It 'needs an NTP server when the site time is Manual' {
            $f = Get-Ztp54Finding { param($d) $d.provisioning.simplified['ntp'] = @{ configuration = 'Manual' } }
            $f | Where-Object { $_.Id -eq 'AZL-029' -and $_.Severity -eq 'error' -and $_.Path -eq 'provisioning.simplified.ntp.server' } | Should -Not -BeNullOrEmpty
        }
        It 'warns about an NTP server that Automatic ignores' {
            $f = Get-Ztp54Finding { param($d) $d.provisioning.simplified['ntp'] = @{ configuration = 'Automatic'; server = '192.0.2.30' } }
            $f | Where-Object { $_.Id -eq 'AZL-029' -and $_.Severity -eq 'warning' -and $_.Path -eq 'provisioning.simplified.ntp' } | Should -Not -BeNullOrEmpty
        }
        It 'warns when the voucher budget is longer than the Bootstrap budget' {
            $f = Get-Ztp54Finding { param($d) $d.provisioning.simplified['timeouts'] = @{ bootstrap_minutes = 60; bootstrap_voucher_minutes = 90 } }
            $f | Where-Object { $_.Id -eq 'AZL-029' -and $_.Severity -eq 'warning' } | Should -Not -BeNullOrEmpty
        }
        It 'does not apply to an ISO install, which has no ZTP BIOS action' {
            $f = Get-FindingFor -From $script:Full54 { param($d) $d.scenario.os_install = 'iso'; $d.nodes[0]['san'] = @{ hbas = @(@{ slot = 'OCP 1' }) } }
            @($f | Where-Object Id -eq 'AZL-029') | Should -BeNullOrEmpty
        }
        It 'does not ask an iSCSI offload adapter for WWPNs' {
            $f = Get-Ztp54Finding { param($d) $d.nodes[0].san.hbas[0] = @{ slot = 'Slot 4'; type = 'iscsi_offload' } }
            @($f | Where-Object Id -eq 'AZL-028') | Should -BeNullOrEmpty
        }
    }
}

Describe 'Schema 5.4: an adapter that names its own BIOS attribute, and port labels read loosely' {
    BeforeAll {
        $script:Ztp55 = Join-Path $repo 'config\variables\examples\infrastructure.ztp.example.yml'
        function Get-Ztp55Finding([scriptblock]$Change) { Get-FindingFor -From $script:Ztp55 $Change }
    }

    It 'accepts bios_attribute with its two values, and rejects a bad attribute name or an empty value' {
        @(Get-Ztp55Finding { param($d) $d.nodes[0].san.hbas[0]['bios_attribute'] = 'PciSlot2'; $d.nodes[0].san.hbas[0]['bios_disabled_value'] = 'Off'; $d.nodes[0].san.hbas[0]['bios_enabled_value'] = 'On' } | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
        (Get-Ztp55Finding { param($d) $d.nodes[0].san.hbas[0]['bios_attribute'] = 'Pci Slot 2' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].san.hbas[0].bios_attribute' } | Should -Not -BeNullOrEmpty
        (Get-Ztp55Finding { param($d) $d.nodes[0].san.hbas[0]['bios_enabled_value'] = '' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].san.hbas[0].bios_enabled_value' } | Should -Not -BeNullOrEmpty
    }

    It 'takes a label that is not a PCIe slot when the adapter names its attribute, and still refuses it otherwise' {
        @(Get-Ztp55Finding { param($d) $d.nodes[0].san.hbas[0].slot = 'OCP 1'; $d.nodes[0].san.hbas[0]['bios_attribute'] = 'PciSlotOcp1' } | Where-Object Id -eq 'AZL-029') | Should -BeNullOrEmpty
        (Get-Ztp55Finding { param($d) $d.nodes[0].san.hbas[0].slot = 'OCP 1' }) | Where-Object { $_.Id -eq 'AZL-029' -and $_.Severity -eq 'error' } | Should -Not -BeNullOrEmpty
    }

    It 'refuses to isolate a slot that a network port''s label merely contains: <Label>' -ForEach @(
        @{ Label = 'Slot 2 Port 1' }, @{ Label = 'PCIe Slot 2' }, @{ Label = 'Riser 1 Slot 2' }
    ) {
        $script:portLabel = $Label
        $f = Get-Ztp55Finding { param($d) $d.nodes[0].network_adapters.Add([ordered]@{ name = 'Extra Port'; slot = $script:portLabel; roles = @('compute'); ip_assignment = 'none' }) }
        $f | Where-Object { $_.Id -eq 'AZL-029' -and $_.Severity -eq 'error' -and $_.Message -match 'Extra Port' } | Should -Not -BeNullOrEmpty
    }

    It 'lets a port in Slot 22 or Slot 3 through' {
        foreach ($label in 'Slot 22 Port 1', 'Slot 3 Port 2') {
            $script:portLabel = $label
            @(Get-Ztp55Finding { param($d) $d.nodes[0].network_adapters.Add([ordered]@{ name = 'Extra Port'; slot = $script:portLabel; roles = @('compute'); ip_assignment = 'none' }) } | Where-Object Id -eq 'AZL-029') | Should -BeNullOrEmpty
        }
    }
}

Describe 'Schema 5.4.2: how the SBE package reaches the nodes (AZL-030)' {
    BeforeAll {
        $script:Full542 = Join-Path $repo 'config\variables\examples\infrastructure.example.yml'
        function Get-Sbe542Finding([scriptblock]$Change) { Get-FindingFor -From $script:Full542 $Change }
    }

    It 'the full template (node_pull with an address) is clean' {
        @(Get-Sbe542Finding { } | Where-Object Id -eq 'AZL-030') | Should -BeNullOrEmpty
    }
    It 'skip, and no delivery key at all, are clean and need no address' {
        @(Get-Sbe542Finding { param($d) $d.hardware.sbe.delivery = 'skip'; $d.hardware.sbe.Remove('node_pull_url') } | Where-Object Id -in 'AZL-030', 'SCHEMA') | Should -BeNullOrEmpty
        @(Get-Sbe542Finding { param($d) $d.hardware.sbe.Remove('delivery'); $d.hardware.sbe.Remove('node_pull_url') } | Where-Object Id -in 'AZL-030', 'SCHEMA') | Should -BeNullOrEmpty
    }
    It 'rejects a delivery route the toolkit does not have (there is no storage account route)' {
        (Get-Sbe542Finding { param($d) $d.hardware.sbe.delivery = 'storage_account' }) | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'hardware.sbe.delivery' } | Should -Not -BeNullOrEmpty
    }
    It 'node_pull needs an address' {
        (Get-Sbe542Finding { param($d) $d.hardware.sbe.Remove('node_pull_url') }) | Where-Object { $_.Id -eq 'AZL-030' -and $_.Severity -eq 'error' -and $_.Path -eq 'hardware.sbe.node_pull_url' } | Should -Not -BeNullOrEmpty
    }
    It 'accepts an https folder and a UNC folder' {
        foreach ($url in 'https://files.example.invalid/sbe/dell', '\\files.example.invalid\sbe\dell') {
            $script:u = $url
            @(Get-Sbe542Finding { param($d) $d.hardware.sbe.node_pull_url = $script:u } | Where-Object { $_.Id -eq 'AZL-030' }) | Should -BeNullOrEmpty
        }
    }
    It 'refuses an address that is neither, and one that carries a credential' {
        foreach ($url in 'ftp://files.example.invalid/sbe', 'D:\sbe\dell', 'https://user:pass@files.example.invalid/sbe', 'https://files.example.invalid/sbe?sv=2024&sig=abc') {
            $script:u = $url
            (Get-Sbe542Finding { param($d) $d.hardware.sbe.node_pull_url = $script:u }) | Where-Object { $_.Id -eq 'AZL-030' -and $_.Severity -eq 'error' -and $_.Path -eq 'hardware.sbe.node_pull_url' } | Should -Not -BeNullOrEmpty -Because $url
        }
    }
    It 'warns about plain http' {
        (Get-Sbe542Finding { param($d) $d.hardware.sbe.node_pull_url = 'http://files.example.invalid/sbe' }) | Where-Object { $_.Id -eq 'AZL-030' -and $_.Severity -eq 'warning' } | Should -Not -BeNullOrEmpty
    }
    It 'warns when an address is given but the route is not node_pull' {
        (Get-Sbe542Finding { param($d) $d.hardware.sbe.delivery = 'skip' }) | Where-Object { $_.Id -eq 'AZL-030' -and $_.Severity -eq 'warning' -and $_.Message -match 'not used' } | Should -Not -BeNullOrEmpty
    }
    It 'a route that delivers needs a bundle_path' {
        (Get-Sbe542Finding { param($d) $d.hardware.sbe.delivery = 'winrm_copy'; $d.hardware.sbe.Remove('node_pull_url'); $d.hardware.sbe.Remove('bundle_path') }) | Where-Object { $_.Id -eq 'AZL-030' -and $_.Severity -eq 'error' -and $_.Path -eq 'hardware.sbe.delivery' } | Should -Not -BeNullOrEmpty
    }
    It 'winrm_copy is clean when every node has a management address' {
        @(Get-Sbe542Finding { param($d) $d.hardware.sbe.delivery = 'winrm_copy'; $d.hardware.sbe.Remove('node_pull_url') } | Where-Object Id -eq 'AZL-030') | Should -BeNullOrEmpty
    }
}
Describe 'Schema 5.6.4: the SBE package as a requirement (AZL-033)' {
    BeforeAll {
        $script:Full564 = Join-Path $repo 'config\variables\examples\infrastructure.example.yml'
        function Get-Sbe564Finding([scriptblock]$Change) { Get-FindingFor -From $script:Full564 $Change }
    }
    It 'a source on a share with a Key Vault credential, and the pinned hash and size, are clean' {
        $f = Get-Sbe564Finding { param($d) $d.hardware.sbe.source_path = '\files.example.invalid\sbe\dell'; $d.hardware.sbe.source_username = 'EXAMPLE\svc-sbe-read'; $d.hardware.sbe.source_password = 'keyvault://kv-iic-mgmt-01/sbe-share-reader'; $d.hardware.sbe.package_sha256 = ('A' * 64); $d.hardware.sbe.package_size_bytes = 1048576 }
        @($f | Where-Object { $_.Id -in 'AZL-033', 'AZL-015', 'AZL-030' -and $_.Severity -eq 'error' }) | Should -BeNullOrEmpty
        @($f | Where-Object Severity -EQ 'error') | Should -BeNullOrEmpty
    }
    It 'requirement not_applicable with a reason names no package and is clean' {
        $f = Get-Sbe564Finding { param($d) $d.hardware.sbe = [ordered]@{ requirement = 'not_applicable'; not_applicable_reason = 'The cluster downloads the package with the vendor credential' } }
        @($f | Where-Object Severity -EQ 'error') | Should -BeNullOrEmpty
    }
    It 'requirement not_applicable without a reason is AZL-033' {
        $f = Get-Sbe564Finding { param($d) $d.hardware.sbe = [ordered]@{ requirement = 'not_applicable' } }
        $f | Where-Object { $_.Id -eq 'AZL-033' -and $_.Severity -eq 'error' -and $_.Path -eq 'hardware.sbe.not_applicable_reason' } | Should -Not -BeNullOrEmpty
    }
    It 'requirement required without a source is AZL-033' {
        $f = Get-Sbe564Finding { param($d) $d.hardware.sbe = [ordered]@{ requirement = 'required' } }
        $f | Where-Object { $_.Id -eq 'AZL-033' -and $_.Severity -eq 'error' -and $_.Path -eq 'hardware.sbe.source_path' } | Should -Not -BeNullOrEmpty
    }
    It 'a user name without a password reference (or the other way round) is AZL-033' {
        (Get-Sbe564Finding { param($d) $d.hardware.sbe.source_path = '\files.example.invalid\sbe'; $d.hardware.sbe.source_username = 'EXAMPLE\svc-sbe-read' }) | Where-Object { $_.Id -eq 'AZL-033' -and $_.Path -eq 'hardware.sbe.source_password' } | Should -Not -BeNullOrEmpty
        (Get-Sbe564Finding { param($d) $d.hardware.sbe.source_path = '\files.example.invalid\sbe'; $d.hardware.sbe.source_password = 'keyvault://kv-iic-mgmt-01/sbe-share-reader' }) | Where-Object { $_.Id -eq 'AZL-033' -and $_.Path -eq 'hardware.sbe.source_password' } | Should -Not -BeNullOrEmpty
    }
    It 'a path with a query string is AZL-033 (no credential in the file)' {
        (Get-Sbe564Finding { param($d) $d.hardware.sbe.source_path = 'https://files.example.invalid/sbe?sig=abc' }) | Where-Object { $_.Id -eq 'AZL-033' -and $_.Path -eq 'hardware.sbe.source_path' } | Should -Not -BeNullOrEmpty
    }
    It 'delivery is satisfied by source_path alone' {
        $f = Get-Sbe564Finding { param($d) $d.hardware.sbe.Remove('bundle_path'); $d.hardware.sbe.source_path = '\files.example.invalid\sbe\dell'; $d.hardware.sbe.delivery = 'winrm_copy'; $d.hardware.sbe.Remove('node_pull_url') }
        @($f | Where-Object { $_.Id -eq 'AZL-030' -and $_.Path -eq 'hardware.sbe.delivery' }) | Should -BeNullOrEmpty
    }
    It 'a block with source_path and no publisher, family or version is not AZL-015' {
        $f = Get-Sbe564Finding { param($d) $d.hardware.sbe = [ordered]@{ source_path = '\files.example.invalid\sbe\dell' } }
        @($f | Where-Object { $_.Id -eq 'AZL-015' -and $_.Path -like 'hardware.sbe*' }) | Should -BeNullOrEmpty
    }
    It 'the schema refuses a requirement other than required or not_applicable' {
        (Get-Sbe564Finding { param($d) $d.hardware.sbe.requirement = 'maybe' }) | Where-Object Severity -EQ 'error' | Should -Not -BeNullOrEmpty
    }
}
Describe 'Schema 5.4.3: os_configuration.clear_storage' {
    BeforeAll { $script:Full543 = Join-Path $repo 'config\variables\examples\infrastructure.example.yml' }

    It 'is in the example, false, and the schema defaults it to false' {
        (Import-AzlInfrastructure -Path $script:Full543).os_configuration.clear_storage | Should -BeFalse
        $schema = Get-Content -LiteralPath (Join-Path $repo 'config\variables\schema\infrastructure.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties.os_configuration.properties.clear_storage.default | Should -BeFalse
        $schema.properties.os_configuration.properties.clear_storage.type | Should -Be 'boolean'
    }
    It 'accepts true on a storage-spaces-direct design without a finding' {
        @(Get-FindingFor -From $script:Full543 { param($d) $d.os_configuration.clear_storage = $true }) | Should -BeNullOrEmpty
    }
    It 'rejects a value that is not a boolean' -ForEach @('yes', 'wipe', 1) {
        $v = $_
        @(Get-FindingFor -From $script:Full543 { param($d) $d.os_configuration.clear_storage = $v } | Where-Object Severity -eq 'error').Count | Should -BeGreaterThan 0
    }
    It 'rejects an unknown key in the section' {
        @(Get-FindingFor -From $script:Full543 { param($d) $d.os_configuration.wipe_everything = $true } | Where-Object Severity -eq 'error').Count | Should -BeGreaterThan 0
    }
    It 'warns (AZL-031) when it is true on a SAN design' {
        $f = @(Get-FindingFor -From $script:Full543 { param($d) $d.os_configuration.clear_storage = $true; $d.scenario.storage_architecture = 'hybrid' } | Where-Object Id -eq 'AZL-031')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'warning'
    }
}

Describe 'Schema 5.5: the domain join (AZL-050 to AZL-053)' {
    BeforeAll {
        $script:Full550 = Join-Path $repo 'config\variables\examples\infrastructure.example.yml'
        $script:Local550 = Join-Path $repo 'config\variables\examples\scenarios\local-identity-switchless-iso.yml'
        function Get-Dj550Finding([scriptblock]$Change, [string]$Rule) { @(Get-FindingFor -From $script:Full550 $Change | Where-Object { -not $Rule -or $_.Id -eq $Rule }) }
    }

    It 'the example joins with the LCM user by default (no domain_join_account), and has no finding' {
        $ad = (Import-AzlInfrastructure -Path $script:Full550).identity.active_directory
        $ad.Contains('domain_join_account') | Should -BeFalse
        $ad.lcm_user.password | Should -Match '^keyvault://'
        $ad.join_options.rename_after_join | Should -BeFalse
        $ad.join_options.allow_ou_move | Should -BeFalse
        @(Test-AzlInfrastructure -Path $script:Full550) | Should -BeNullOrEmpty
    }
    It 'the schema: domain_join_account is an optional override, allow_ou_move defaults to false, rename_after_join is fixed to false' {
        $schema = Get-Content -LiteralPath (Join-Path $repo 'config\variables\schema\infrastructure.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $ad = $schema.properties.identity.properties.active_directory
        $ad.required | Should -Not -Contain 'domain_join_account'
        $ad.properties.join_options.properties.allow_ou_move.default | Should -BeFalse
        $ad.properties.join_options.properties.rename_after_join.const | Should -BeFalse
        $ad.properties.domain_join_account.required | Should -Be @('username', 'password')
        $ad.properties.local_admin_members.type | Should -Be 'array'
    }
    It 'accepts the optional override and local_admin_members' {
        @(Get-Dj550Finding { param($d) $d.identity.active_directory.domain_join_account = [ordered]@{ username = 'svc-azl-join'; password = 'keyvault://kv-iic-mgmt-01/join' }; $d.identity.active_directory.local_admin_members = @('sg-iic-azl-01-admins') }) | Should -BeNullOrEmpty
    }
    It 'rejects rename_after_join true, an override password that is not a Key Vault reference, and an unknown key' {
        @(Get-Dj550Finding { param($d) $d.identity.active_directory.join_options.rename_after_join = $true } | Where-Object Severity -eq 'error').Count | Should -BeGreaterThan 0
        @(Get-Dj550Finding { param($d) $d.identity.active_directory.domain_join_account = [ordered]@{ username = 'x'; password = 'P@ssw0rd-in-clear' } } | Where-Object Severity -eq 'error').Count | Should -BeGreaterThan 0
        @(Get-Dj550Finding { param($d) $d.identity.active_directory.join_options.rename_machines = $true } | Where-Object Severity -eq 'error').Count | Should -BeGreaterThan 0
    }

    Context 'AZL-050: an AD design has a join credential (the LCM user, or the override)' {
        It 'is an error when the LCM user is not valid for Azure Local (Microsoft Learn: 1 to 20 characters, letters, numbers, hyphens, underscores, not first a hyphen or number)' -ForEach @('1lcm', '-lcm', 'lcm.user', 'a-name-that-is-longer-than-20') {
            $name = $_
            $f = Get-Dj550Finding { param($d) $d.identity.active_directory.lcm_user.username = $name } 'AZL-050'
            @($f | Where-Object Severity -eq 'error').Count | Should -BeGreaterThan 0
        }
        It 'is an error when the LCM user has the name of the local administrator' {
            $f = Get-Dj550Finding { param($d) $d.identity.active_directory.lcm_user.username = 'azl-admin' } 'AZL-050'
            $f.Count | Should -Be 1
            $f[0].Message | Should -Match 'local administrator'
        }
        It 'does not apply to a ztp-scope file' {
            $f = Get-FindingFor -From (Join-Path $repo 'config\variables\examples\infrastructure.ztp.example.yml') { param($d) $d.scenario = @{ identity = 'active_directory' } } | Where-Object Id -eq 'AZL-050'
            @($f) | Should -BeNullOrEmpty
        }
    }
    Context 'AZL-051: ou_path is a valid distinguished name inside the domain' {
        It 'is an error when the DC components are another domain' {
            $f = Get-Dj550Finding { param($d) $d.identity.active_directory.ou_path = 'OU=iic-azl-01,OU=AzureLocal,DC=contoso,DC=com' } 'AZL-051'
            $f.Count | Should -Be 1
            $f[0].Severity | Should -Be 'error'
            $f[0].Message | Should -Match 'contoso.com'
        }
        It 'is an error when a DC component is missing or an OU comes after the DC components' {
            @(Get-Dj550Finding { param($d) $d.identity.active_directory.ou_path = 'OU=iic-azl-01,DC=improbability' } 'AZL-051').Count | Should -Be 1
            @(Get-Dj550Finding { param($d) $d.identity.active_directory.ou_path = 'OU=a,DC=improbability,OU=b,DC=cloud' } 'AZL-051').Count | Should -Be 1
        }
        It 'is an error when a part is not OU=, CN= or DC=' {
            @(Get-Dj550Finding { param($d) $d.identity.active_directory.ou_path = 'OU=a,XX=b,DC=improbability,DC=cloud' } 'AZL-051').Count | Should -Be 1
        }
        It 'is an error for the unsupported character <Name>' -ForEach @(
            @{ Name = 'ampersand'; Char = '&' }, @{ Name = 'double quote'; Char = '"' }, @{ Name = 'apostrophe'; Char = "'" }, @{ Name = 'less-than'; Char = '<' }, @{ Name = 'greater-than'; Char = '>' }) {
            $ch = $Char
            @(Get-Dj550Finding { param($d) $d.identity.active_directory.ou_path = "OU=iic${ch}01,OU=AzureLocal,DC=improbability,DC=cloud" } 'AZL-051').Count | Should -BeGreaterThan 0
        }
        It 'accepts a nested OU path and different letter case' {
            @(Get-Dj550Finding { param($d) $d.identity.active_directory.ou_path = 'ou=Leaf,OU=Mid,OU=Top,dc=Improbability,dc=CLOUD' } 'AZL-051') | Should -BeNullOrEmpty
        }
    }
    Context 'AZL-052: domain_controllers are the DNS servers of the management port' {
        It 'is an error when a domain controller is not a DNS server' {
            $f = Get-Dj550Finding { param($d) $d.identity.active_directory.domain_controllers = @('192.0.2.4', '192.0.2.99') } 'AZL-052'
            $f.Count | Should -Be 1
            $f[0].Severity | Should -Be 'error'
            $f[0].Message | Should -Match '192\.0\.2\.99'
        }
        It 'is an error when a DNS server is not a domain controller' {
            $f = Get-Dj550Finding { param($d) $d.identity.active_directory.domain_controllers = @('192.0.2.4') } 'AZL-052'
            $f.Count | Should -Be 1
            $f[0].Message | Should -Match '192\.0\.2\.5'
        }
        It 'is clean in any order, and when domain_controllers is not set' {
            @(Get-Dj550Finding { param($d) $d.identity.active_directory.domain_controllers = @('192.0.2.5', '192.0.2.4') } 'AZL-052') | Should -BeNullOrEmpty
            @(Get-Dj550Finding { param($d) $d.identity.active_directory.Remove('domain_controllers') } 'AZL-052') | Should -BeNullOrEmpty
        }
    }
    Context 'AZL-053: a local identity design with join keys' {
        It 'warns for domain_join_account and for local_admin_members; the local identity file without them is clean' {
            @(Get-FindingFor -From $script:Local550 { param($d) $null = $d } | Where-Object Severity -ne 'info') | Should -BeNullOrEmpty # AZL-032 (Info) says the file has no SBE
            $f = @(Get-FindingFor -From $script:Local550 { param($d) $d.identity.active_directory = [ordered]@{ domain_fqdn = 'improbability.cloud'; ou_path = 'OU=x,DC=improbability,DC=cloud'; lcm_user = [ordered]@{ username = 'lcm'; password = 'keyvault://kv-iic-edge-mgmt/lcm-password' }; domain_join_account = [ordered]@{ username = 'svc-j'; password = 'keyvault://kv-iic-edge-mgmt/join' }; local_admin_members = @('g1') } } | Where-Object Id -eq 'AZL-053')
            $f.Count | Should -Be 2
            $f[0].Severity | Should -Be 'warning'
        }
    }
}

Describe 'The Solution Builder Extension is optional (AZL-013, AZL-015, AZL-032)' {
    $ztpExampleFiles = @(
        Join-Path $PSScriptRoot '..\..\config\variables\examples\infrastructure.ztp.example.yml'
        Join-Path $PSScriptRoot '..\..\config\variables\examples\scenarios\lom-management-ztp.yml'
        Join-Path $PSScriptRoot '..\..\config\variables\examples\scenarios\rack-aware-ztp.yml'
    )
    BeforeAll {
        # The lab file: the repo example with the hardware.sbe block deleted (the owner removed it).
        function Get-NoSbeFinding([scriptblock]$Extra = {}, [string]$From = $script:ExamplePath) {
            $apply = { param($d) $d.hardware.Remove('sbe'); & $Extra $d }.GetNewClosure()
            Get-FindingFor -From $From $apply
        }
        $script:ZtpExample = Join-Path $repo 'config\variables\examples\infrastructure.ztp.example.yml'
    }
    It 'a file with no hardware.sbe has no errors and no warning about the SBE' {
        $f = Get-NoSbeFinding
        @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
        @($f | Where-Object { $_.Id -eq 'AZL-015' -and $_.Path -like 'hardware.sbe*' }) | Should -BeNullOrEmpty
        @($f | Where-Object { $_.Severity -eq 'warning' -and $_.Message -match '\bSBE\b' }) | Should -BeNullOrEmpty
    }
    It 'a file with no hardware.sbe says so once, as an Info (not a warning, not an error)' {
        $i = @(Get-NoSbeFinding | Where-Object { $_.Id -eq 'AZL-032' })
        $i.Count | Should -Be 1
        $i[0].Severity | Should -Be 'info'
        $i[0].Message | Should -Match 'no hardware.sbe block: no package source is configured and nothing is side-loaded at build time'
        $i[0].Message | Should -Match 'SB-001'
    }
    It 'the ZTP example <_> without hardware.sbe has no errors' -ForEach $ztpExampleFiles {
        @(Get-NoSbeFinding -From $_ | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
    }
    It 'a complete hardware.sbe gives neither AZL-015 nor the no-SBE Info' {
        $f = Get-FindingFor { param($d) $d.hardware.sbe.version = '5.0.2609.1611'; $d.hardware.sbe.family = '16G-45n0c-Intel' }
        @($f | Where-Object { $_.Id -in 'AZL-015', 'AZL-032' -and ($_.Id -eq 'AZL-032' -or $_.Path -like 'hardware.sbe*') }) | Should -BeNullOrEmpty
        @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
    }
    It 'family and version may be empty when bundle_path names the package (they are read from it): today''s example' {
        $f = Get-FindingFor { }
        @($f | Where-Object { $_.Id -eq 'AZL-015' -and $_.Path -like 'hardware.sbe*' }) | Should -BeNullOrEmpty
    }
    It 'a hardware.sbe with neither bundle_path nor publisher, family and version is AZL-015' {
        $f = Get-FindingFor { param($d) $d.hardware.sbe = [ordered]@{ delivery = 'skip' } }
        foreach ($k in 'publisher', 'family', 'version') {
            $f | Where-Object { $_.Id -eq 'AZL-015' -and $_.Severity -eq 'error' -and $_.Path -eq "hardware.sbe.$k" } | Should -Not -BeNullOrEmpty -Because $k
        }
    }
    It 'publisher, family and version alone name an SBE placed in C:\SBE by hand: no AZL-015' {
        $f = Get-FindingFor { param($d) $d.hardware.sbe = [ordered]@{ publisher = 'Dell'; family = '16G-45n0c-Intel'; version = '5.0.2609.1611' } }
        @($f | Where-Object { $_.Id -eq 'AZL-015' -and $_.Path -like 'hardware.sbe*' }) | Should -BeNullOrEmpty
        @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
    }
    It 'bundle_path alone is complete (the identity is read from the package): the ZTP scenario examples' {
        $f = Get-FindingFor { param($d) $d.hardware.sbe = [ordered]@{ bundle_path = 'D:\sbe\dell' } }
        @($f | Where-Object { $_.Id -in 'AZL-015', 'SCHEMA' -and $_.Path -like 'hardware.sbe*' }) | Should -BeNullOrEmpty
    }
    It 'the schema asks for bundle_path, or publisher, family and version, only when hardware.sbe is there' {
        $f = Get-FindingFor { param($d) $d.hardware.sbe = [ordered]@{ publisher = 'Dell' } }
        @($f | Where-Object Id -eq 'SCHEMA' | Where-Object { $_.Path -like 'hardware.sbe*' -or $_.Message -match 'family|version|bundle_path' }) | Should -Not -BeNullOrEmpty
        @(Get-NoSbeFinding | Where-Object Id -eq 'SCHEMA') | Should -BeNullOrEmpty
    }
    It 'a ZTP file with only bundle_path is still complete' {
        $f = Get-FindingFor -From $script:ZtpExample { }
        @($f | Where-Object { $_.Severity -eq 'error' }) | Should -BeNullOrEmpty
    }
    It 'AZL-013 about an unpinned OS version mentions the SBE only when an SBE is configured' {
        $with = @(Get-FindingFor { param($d) $d.provisioning.os_version = 'latest' } | Where-Object { $_.Id -eq 'AZL-013' -and $_.Path -eq 'provisioning.os_version' })
        $without = @(Get-NoSbeFinding { param($d) $d.provisioning.os_version = 'latest' } | Where-Object { $_.Id -eq 'AZL-013' -and $_.Path -eq 'provisioning.os_version' })
        $with.Count | Should -Be 1
        $with[0].Message | Should -Match 'SBE'
        $without.Count | Should -Be 1
        $without[0].Message | Should -Not -Match 'SBE'
    }
    It 'the validator never adds a delivery setting to the file it reads' {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:ExamplePath -Raw) -Ordered
        $doc.hardware.sbe.Remove('delivery'); $doc.hardware.sbe.Remove('node_pull_url')
        $file = Join-Path $TestDrive 'nodelivery.yml'
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $infra = Import-AzlInfrastructure -Path $file -WarningAction SilentlyContinue
        $infra.hardware.sbe.Contains('delivery') | Should -BeFalse
    }
}
