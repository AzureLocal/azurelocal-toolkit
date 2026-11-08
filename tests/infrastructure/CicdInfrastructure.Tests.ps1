#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Schema 5.5: the CI/CD infrastructure in devops, and rule AZL-070.
# Run: Invoke-Pester ./tests/infrastructure

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module powershell-yaml
    $script:ExamplePath = Join-Path $repo 'config\infrastructure\infrastructure.example.yml'

    function Get-CicdFinding([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:ExamplePath -Raw) -Ordered
        & $Change $doc
        $file = Join-Path $TestDrive ("case-{0}.yml" -f [guid]::NewGuid())
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        @(Test-AzlInfrastructure -Path $file)
    }
}

Describe 'Schema 5.5: devops' {
    It 'the example is schema 5.5.0 and clean, with the runners and environments' {
        $infra = Import-AzlInfrastructure -Path $script:ExamplePath
        $infra._metadata.schema_version | Should -Be '5.5.0'
        @(Test-AzlInfrastructure -Path $script:ExamplePath) | Should -BeNullOrEmpty
        @($infra.devops.runners).Count | Should -Be 2
        $infra.devops.runners[1].purpose | Should -Be 'ztp'
    }
    It 'still reads a 5.4 file that has only devops.runner' {
        $f = Get-CicdFinding { param($d) $d._metadata.schema_version = '5.4.0'; $d.devops = [ordered]@{ platform = 'github'; runner = [ordered]@{ name = 'vm-r'; type = 'vm' } } }
        @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
    }
    It 'rejects an unknown devops key' {
        $f = Get-CicdFinding { param($d) $d.devops['typo_key'] = 1 }
        $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'devops.typo_key' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses a plain value for registration_secret (a secret is only a Key Vault reference)' {
        $f = Get-CicdFinding { param($d) $d.devops.runners[0].registration_secret = 'ghp_notAReference' }
        @($f | Where-Object Severity -eq 'error') | Should -Not -BeNullOrEmpty
    }
    It 'refuses a plain value for api_token and for the client secret' {
        (Get-CicdFinding { param($d) $d.devops.api_token = 'ghp_value' } | Where-Object Severity -eq 'error') | Should -Not -BeNullOrEmpty
        (Get-CicdFinding { param($d) $d.devops.authentication.client_secret = 'value' } | Where-Object Severity -eq 'error') | Should -Not -BeNullOrEmpty
    }
    It 'needs registration secrets to name a listed vault (AZL-001)' {
        $f = Get-CicdFinding { param($d) $d.devops.runners[0].registration_secret = 'keyvault://kv-unlisted/x' }
        $f | Where-Object { $_.Id -eq 'AZL-001' } | Should -Not -BeNullOrEmpty
    }
}

Describe 'AZL-070: runners, network and environments' {
    It 'needs a ztp runner to be Windows' {
        $f = Get-CicdFinding { param($d) $d.devops.runners[0].purpose = 'ztp' }
        $f | Where-Object { $_.Id -eq 'AZL-070' -and $_.Path -eq 'devops.runners[0].os_type' } | Should -Not -BeNullOrEmpty
    }
    It 'needs bmc_cidrs for a ztp runner' {
        $f = Get-CicdFinding { param($d) $d.devops.runner_network.bmc_cidrs = @() }
        $f | Where-Object { $_.Id -eq 'AZL-070' -and $_.Path -eq 'devops.runner_network.bmc_cidrs' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses a ztp runner as a scale set or with more than one VM' {
        $f = Get-CicdFinding { param($d) $d.devops.runners[1].count = 2 }
        $f | Where-Object { $_.Id -eq 'AZL-070' -and $_.Path -eq 'devops.runners[1].count' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses a Windows scale set' {
        $f = Get-CicdFinding { param($d) $d.devops.runners[1].compute_type = 'vmss' }
        $f | Where-Object { $_.Id -eq 'AZL-070' -and $_.Path -eq 'devops.runners[1].compute_type' } | Should -Not -BeNullOrEmpty
    }
    It 'warns that a ztp runner without a big data disk cannot hold the media' {
        $f = Get-CicdFinding { param($d) $d.devops.runners[1].data_disk_gb = 0 }
        $f | Where-Object { $_.Id -eq 'AZL-070' -and $_.Severity -eq 'warning' -and $_.Path -eq 'devops.runners[1].data_disk_gb' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses two ztp runners and two Linux pools (task 06 deploys one of each)' {
        $two = Get-CicdFinding { param($d) $d.devops.runners += [ordered]@{ name = 'vm-ztp-2'; os_type = 'windows'; purpose = 'ztp'; registration_secret = 'keyvault://kv-iic-mgmt-01/x'; subnet = @{ name = 's2'; prefix = '10.20.10.128/26' } } }
        $two | Where-Object { $_.Id -eq 'AZL-070' -and $_.Message -match 'one ztp runner' } | Should -Not -BeNullOrEmpty
        $lin = Get-CicdFinding { param($d) $d.devops.runners += [ordered]@{ name = 'vm-lnx-2'; os_type = 'linux'; registration_secret = 'keyvault://kv-iic-mgmt-01/x'; subnet = @{ name = 's2'; prefix = '10.20.10.128/26' } } }
        $lin | Where-Object { $_.Id -eq 'AZL-070' -and $_.Message -match 'one Linux general pool' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses a runner without registration_secret' {
        $f = Get-CicdFinding { param($d) $d.devops.runners[0].Remove('registration_secret') }
        $f | Where-Object { $_.Id -eq 'AZL-070' -and $_.Path -eq 'devops.runners[0].registration_secret' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses a subnet outside the VNet address space and overlapping subnets' {
        $out = Get-CicdFinding { param($d) $d.devops.runners[0].subnet.prefix = '10.99.0.0/26' }
        $out | Where-Object { $_.Id -eq 'AZL-070' -and $_.Message -match "isn't inside" } | Should -Not -BeNullOrEmpty
        $overlap = Get-CicdFinding { param($d) $d.devops.runners[1].subnet.prefix = '10.20.10.0/25' }
        $overlap | Where-Object { $_.Id -eq 'AZL-070' -and $_.Message -match 'overlaps' } | Should -Not -BeNullOrEmpty
    }
    It 'needs a hub network that resolves when peering is on' {
        $f = Get-CicdFinding { param($d) $d.devops.runner_network.hub_peering.hub_network = 'vnet-nowhere' }
        $f | Where-Object { $_.Id -eq 'AZL-070' -and $_.Path -eq 'devops.runner_network.hub_peering' } | Should -Not -BeNullOrEmpty
    }
    It 'needs devops.resource_group and devops.runner_network when runners are listed' {
        (Get-CicdFinding { param($d) $d.devops.Remove('resource_group') } | Where-Object { $_.Path -eq 'devops.resource_group' }) | Should -Not -BeNullOrEmpty
        (Get-CicdFinding { param($d) $d.devops.Remove('runner_network') } | Where-Object { $_.Path -eq 'devops.runner_network' }) | Should -Not -BeNullOrEmpty
    }
    It 'warns about an environment that needs approval and has no approvers; refuses duplicates' {
        $warn = Get-CicdFinding { param($d) $d.devops.environments[0].approvers = @() }
        $warn | Where-Object { $_.Id -eq 'AZL-070' -and $_.Severity -eq 'warning' } | Should -Not -BeNullOrEmpty
        $dup = Get-CicdFinding { param($d) $d.devops.environments[1].name = 'azr-prod-us' }
        $dup | Where-Object { $_.Id -eq 'AZL-070' -and $_.Severity -eq 'error' -and $_.Message -match 'used 2 times' } | Should -Not -BeNullOrEmpty
    }
    It 'needs the client secret reference for the client_secret method' {
        $f = Get-CicdFinding { param($d) $d.devops.authentication.method = 'client_secret' }
        $f | Where-Object { $_.Id -eq 'AZL-070' -and $_.Path -eq 'devops.authentication.client_secret' } | Should -Not -BeNullOrEmpty
    }
}
