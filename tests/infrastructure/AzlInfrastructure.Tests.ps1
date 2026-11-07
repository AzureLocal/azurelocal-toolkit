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
