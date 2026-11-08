#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The ARM parameters per scenario (Active Directory or local identity; S2D or SAN; switchless or switched; 1, 2, 4 and 16 nodes),
# the key check that names the missing infrastructure.yml key, and the parameter-source map. No Azure call.

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'ArmDeploymentRun.Helpers.ps1'))
    $script:Catalog = Get-AzlArmTemplateCatalog
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
}

Describe 'Parameters per scenario' {
    It '<Identity> + <Storage> <Connectivity>, <Nodes> node(s): <Template>' -ForEach @(
        foreach ($n in 1, 2, 4, 16) {
            @{ Identity = 'active_directory'; Storage = 's2d'; Switchless = $false; Connectivity = 'switched'; Nodes = $n; Template = 'create-cluster'; NetType = $(if ($n -eq 1) { 'singleServerDeployment' } else { 'switchedMultiServerDeployment' }) }
            @{ Identity = 'local_identity'; Storage = 's2d'; Switchless = $false; Connectivity = 'switched'; Nodes = $n; Template = 'create-adless-cluster-external-dns-public-preview'; NetType = $(if ($n -eq 1) { 'singleServerDeployment' } else { 'switchedMultiServerDeployment' }) }
            @{ Identity = 'active_directory'; Storage = 's2d'; Switchless = $true; Connectivity = 'switchless'; Nodes = $n; Template = 'create-cluster'; NetType = $(if ($n -eq 1) { 'singleServerDeployment' } else { 'switchlessMultiServerDeployment' }) }
            @{ Identity = 'local_identity'; Storage = 's2d'; Switchless = $true; Connectivity = 'switchless'; Nodes = $n; Template = 'create-adless-cluster-external-dns-public-preview'; NetType = $(if ($n -eq 1) { 'singleServerDeployment' } else { 'switchlessMultiServerDeployment' }) }
            @{ Identity = 'active_directory'; Storage = 'san'; Switchless = $false; Connectivity = 'switched'; Nodes = $n; Template = 'create-cluster-san'; NetType = $(if ($n -eq 1) { 'singleServerDeployment' } else { 'switchedMultiServerDeployment' }) }
            @{ Identity = 'local_identity'; Storage = 'san'; Switchless = $false; Connectivity = 'switched'; Nodes = $n; Template = 'create-cluster-adless-san'; NetType = $(if ($n -eq 1) { 'singleServerDeployment' } else { 'switchedMultiServerDeployment' }) }
        }
    ) {
        $infra = Get-TestInfra -Identity $Identity -Storage $Storage -Switchless:$Switchless -Nodes $Nodes
        $report = Get-TestOsReport -Infra $infra
        Test-AzlArmRequiredKey -Infrastructure $infra -TemplateName $Template | Should -BeNullOrEmpty
        $set = New-AzlArmParameterSet -Infrastructure $infra -Mode Validate -AdapterMap (Get-AzlAdapterMapFromReport -Report $report) -NodeReport @($report.nodes)
        $set.Template.Name | Should -Be $Template
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $script:Catalog.templates[$Template].parameters | Where-Object { $_ -notmatch '^hciResourceProviderObjectID' }) | Should -BeNullOrEmpty
        $p = $set.Parameters
        $p.networkingType | Should -Be $NetType
        @($p.physicalNodesSettings).Count | Should -Be $Nodes
        @($p.arcNodeResourceIds).Count | Should -Be $Nodes
        $p.physicalNodesSettings[-1].name | Should -Be ('iic-n{0:00}' -f $Nodes)
        $p.storageConnectivitySwitchless | Should -Be ($Connectivity -eq 'switchless')
        $p.localAdminPassword.KeyVault | Should -Match '^keyvault://'
        if ($Identity -eq 'active_directory') {
            $p.domainFqdn | Should -Be 'improbability.cloud'
            $p.adouPath | Should -Match '^OU='
            $p.AzureStackLCMAdminPassword.KeyVault | Should -Match '^keyvault://'
            $p.Contains('identityProvider') | Should -BeFalse
        }
        else {
            $p.identityProvider | Should -Be 'LocalIdentity'
            $p.dnsZones[0].dnsZoneName | Should -Be 'improbability.cloud'
            $p.Contains('domainFqdn') | Should -BeFalse
            $p.Contains('AzureStackLCMAdminPassword') | Should -BeFalse
        }
        if ($Storage -eq 'san') {
            $p.infraVolLunId | Should -Be 'UID-INFRA'
            $p.infraPerfLunId | Should -Be 'UID-PERF'
            $p.sanNetworkList.clusterNetworkConfig.adapterIPConfig.Count | Should -Be 2
            $p.Contains('storageNetworkList') | Should -BeFalse
        }
        else {
            $p.storageNetworkList.Count | Should -Be 2
            $p.Contains('sanNetworkList') | Should -BeFalse
        }
    }
    It 'the same file gives the same parameter hash; a changed value gives another; deploymentMode does not count' {
        $infra = Get-TestInfra
        $a = Get-AzlArmParameterHash -ParameterSet (New-AzlArmParameterSet -Infrastructure $infra -Mode Validate -AllowUnresolvedSanLun)
        $b = Get-AzlArmParameterHash -ParameterSet (New-AzlArmParameterSet -Infrastructure (Get-TestInfra) -Mode Deploy -AllowUnresolvedSanLun)
        $a | Should -Be $b
        $a | Should -Match '^[0-9a-f]{12}$'
        $infra.networking.management.gateway = '192.0.2.2'
        Get-AzlArmParameterHash -ParameterSet (New-AzlArmParameterSet -Infrastructure $infra -Mode Validate -AllowUnresolvedSanLun) | Should -Not -Be $a
    }
    It 'a secret never appears as a value in the parameter set or its hash input' {
        $set = New-AzlArmParameterSet -Infrastructure (Get-TestInfra) -Mode Validate -AllowUnresolvedSanLun
        $set.Parameters.localAdminPassword | Should -BeOfType [System.Collections.IDictionary]
        (ConvertTo-AzlArmParameterFile -ParameterSet $set) | Should -Not -Match 'keyvault://'
    }
}

Describe 'The key check names the infrastructure.yml key' {
    It 'AD: an empty ou_path is "ARM parameter adouPath ... needs identity.active_directory.ou_path"' {
        $infra = Get-TestInfra
        $infra.identity.active_directory.ou_path = ''
        $problems = @(Test-AzlArmRequiredKey -Infrastructure $infra -TemplateName 'create-cluster')
        $problems | Should -Match 'ARM parameter adouPath .*identity\.active_directory\.ou_path'
        $problems | Should -Match 'required when scenario\.identity is active_directory'
    }
    It 'local identity: an empty dns_zone is named, and the AD keys are not asked for' {
        $infra = Get-TestInfra -Identity local_identity
        $infra.identity.local_identity.dns_zone = ''
        $problems = @(Test-AzlArmRequiredKey -Infrastructure $infra -TemplateName 'create-adless-cluster-external-dns-public-preview')
        $problems | Should -Match 'identity\.local_identity\.dns_zone'
        $problems | Should -Not -Match 'active_directory'
    }
    It 'lists every missing value at once' {
        $infra = Get-TestInfra
        $infra.cluster.key_vault.name = ''; $infra.azure.location = ''; $infra.networking.management.infrastructure_pool = @{}
        $problems = @(Test-AzlArmRequiredKey -Infrastructure $infra -TemplateName 'create-cluster')
        ($problems -join "`n") | Should -Match 'cluster\.key_vault\.name'
        ($problems -join "`n") | Should -Match 'azure\.location'
        ($problems -join "`n") | Should -Match 'infrastructure_pool\.start'
        ($problems -join "`n") | Should -Match 'infrastructure_pool\.end'
    }
    It 'a witness storage account is required only for a cloud witness' {
        $infra = Get-TestInfra
        $infra.cluster.witness = [ordered]@{ type = 'none' }
        Test-AzlArmRequiredKey -Infrastructure $infra -TemplateName 'create-cluster' | Should -BeNullOrEmpty
        $infra.cluster.witness = [ordered]@{ type = 'cloud'; storage_account = '' }
        @(Test-AzlArmRequiredKey -Infrastructure $infra -TemplateName 'create-cluster') | Should -Match 'cluster\.witness\.storage_account'
    }
    It 'a SAN needs the LUN keys and the cluster networks' {
        $infra = Get-TestInfra -Storage san
        $infra.storage.san.infra_volume_lun_id = ''; $infra.networking.cluster_networks = @()
        $problems = @(Test-AzlArmRequiredKey -Infrastructure $infra -TemplateName 'create-cluster-san') -join "`n"
        $problems | Should -Match 'storage\.san\.infra_volume_lun_id'
        $problems | Should -Match 'networking\.cluster_networks'
    }
    It 'the run stops with exit 2 and the key name, before anything else' {
        $infra = Get-TestInfra
        $infra.identity.active_directory.ou_path = ''
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'identity\.active_directory\.ou_path'
    }
}

Describe 'The parameter-source map' {
    It 'has an entry for every parameter of every template in the catalog' {
        $sources = Get-AzlArmParameterSource
        $missing = foreach ($t in $script:Catalog.templates.Keys) { foreach ($p in $script:Catalog.templates[$t].parameters.Keys) { if (-not $sources.Contains($p)) { "$t/$p" } } }
        @($missing) | Should -BeNullOrEmpty
    }
    It 'every infrastructure.yml key it names exists in the schema or is a documented generated value' {
        $schemaText = Get-Content -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw
        $sources = Get-AzlArmParameterSource
        $unknown = foreach ($name in $sources.Keys) {
            foreach ($key in @($sources[$name]['keys'])) {
                $leaf = ($key -replace '\[\]', '').Split('.')[-1]
                if ($schemaText -notmatch ('"' + [regex]::Escape($leaf) + '"')) { "$name -> $key" }
            }
        }
        @($unknown) | Should -BeNullOrEmpty
    }
    It 'the markdown table lists each parameter with its keys' {
        $set = New-AzlArmParameterSet -Infrastructure (Get-TestInfra) -Mode Validate -AllowUnresolvedSanLun
        $md = Format-AzlArmParameterSource -ParameterSet $set
        $md | Should -Match '\| adouPath \| `identity\.active_directory\.ou_path`'
        $md | Should -Match '\| localAdminPassword \| `identity\.local_admin\.password` .* secret'
    }
}
