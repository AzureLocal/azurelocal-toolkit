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
