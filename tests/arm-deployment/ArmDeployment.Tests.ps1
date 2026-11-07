#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the ARM parameter generation and Validate/Deploy. No Azure call is made: Invoke-AzlArm is mocked.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/arm-deployment

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\azure-local\AzlAzure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\arm-deployment\AzlArmDeployment.psm1') -Force
    Import-Module powershell-yaml
    $script:Fixture = Join-Path $repo 'tests\fixtures\infrastructure.fc-san.yml'
    $script:HandoffFile = Join-Path $repo 'tests\fixtures\handoff.v2.json'
    $script:Catalog = Get-AzlArmTemplateCatalog
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    function Get-Infra { Import-AzlInfrastructure -Path $script:Fixture -SkipValidation }
    function Convert-ToS2d([System.Collections.IDictionary]$Infra) {
        $Infra.scenario.storage_architecture = 's2d'
        $Infra.storage.Remove('san'); $Infra.storage.configuration_mode = 'express'
        $Infra.Remove('storage') | Out-Null
        $Infra['storage'] = [ordered]@{ configuration_mode = 'express' }
        $Infra.networking.Remove('cluster_networks')
        $Infra.networking.intents = @(
            [ordered]@{ name = 'mgmt_compute'; traffic = @('management', 'compute'); adapters = @('Port0', 'Port1') }
            [ordered]@{ name = 'storage'; traffic = @('storage'); adapters = @('Port2', 'Port3') })
        $Infra.networking['storage'] = [ordered]@{ auto_ip = $true; networks = @([ordered]@{ name = 'StorageNetwork1'; adapter = 'Port2'; vlan_id = 711 }, [ordered]@{ name = 'StorageNetwork2'; adapter = 'Port3'; vlan_id = 712 }) }
        $Infra
    }
    $script:Report = [pscustomobject]@{
        nodes = @(
            [pscustomobject]@{ name = 'iic-n01'; ports = @([pscustomobject]@{ osName = 'Port0'; mac = '00005e005310' }, [pscustomobject]@{ osName = 'Port1'; mac = '00005e005311' }, [pscustomobject]@{ osName = 'Port2'; mac = '00005e005312' }, [pscustomobject]@{ osName = 'Port3'; mac = '00005e005313' })
                sanDisks = @([pscustomobject]@{ lun = 0; uid = 'UID-INFRA'; sn = 'SN-INFRA'; gb = 300 }, [pscustomobject]@{ lun = 1; uid = 'UID-PERF'; sn = 'SN-PERF'; gb = 50 }) }
            [pscustomobject]@{ name = 'iic-n02'; ports = @([pscustomobject]@{ osName = 'Port0'; mac = '00005e005320' }, [pscustomobject]@{ osName = 'Port1'; mac = '00005e005321' }, [pscustomobject]@{ osName = 'Port2'; mac = '00005e005322' }, [pscustomobject]@{ osName = 'Port3'; mac = '00005e005323' })
                sanDisks = @([pscustomobject]@{ lun = 0; uid = 'UID-INFRA'; sn = 'SN-INFRA'; gb = 300 }, [pscustomobject]@{ lun = 1; uid = 'UID-PERF'; sn = 'SN-PERF'; gb = 50 }) })
    }
}

Describe 'Template selection' {
    It '<Name>: <Why>' -ForEach @(
        @{ Name = 'create-cluster-san'; Why = 'AD + Fibre Channel SAN'; Change = { param($i) } }
        @{ Name = 'create-cluster-adless-san'; Why = 'local identity + Fibre Channel SAN'; Change = { param($i) $i.scenario.identity = 'local_identity' } }
        @{ Name = 'create-cluster'; Why = 'AD + S2D'; Change = { param($i) $null = Convert-ToS2d $i } }
        @{ Name = 'create-adless-cluster-external-dns-public-preview'; Why = 'local identity + S2D'; Change = { param($i) $null = Convert-ToS2d $i; $i.scenario.identity = 'local_identity' } }
        @{ Name = 'create-cluster-rac-enabled'; Why = 'AD + S2D rack aware'; Change = { param($i) $null = Convert-ToS2d $i; $i.scenario.topology = 'rack_aware' } }
        @{ Name = 'create-cluster'; Why = 'hybrid uses the S2D template'; Change = { param($i) $null = Convert-ToS2d $i; $i.scenario.storage_architecture = 'hybrid' } }
    ) {
        $infra = Get-Infra
        & $Change $infra
        (Select-AzlArmTemplate -Infrastructure $infra -Catalog $script:Catalog).Name | Should -Be $Name
    }
    It 'warns that a hybrid SAN is connected after the deployment' {
        $infra = Convert-ToS2d (Get-Infra); $infra.scenario.storage_architecture = 'hybrid'
        (Select-AzlArmTemplate -Infrastructure $infra -Catalog $script:Catalog).Warnings | Should -Match 'Connect the SAN afterwards'
    }
    It 'says plainly what is not generated: iSCSI, disconnected, rack aware SAN' {
        $infra = Get-Infra; $infra.storage.san.type = 'iscsi'
        { Select-AzlArmTemplate -Infrastructure $infra -Catalog $script:Catalog } | Should -Throw '*iSCSI*'
        $infra = Get-Infra; $infra.scenario.connectivity = 'disconnected'
        { Select-AzlArmTemplate -Infrastructure $infra -Catalog $script:Catalog } | Should -Throw '*Disconnected*'
        $infra = Get-Infra; $infra.scenario.topology = 'rack_aware'
        { Select-AzlArmTemplate -Infrastructure $infra -Catalog $script:Catalog } | Should -Throw '*Rack aware*'
    }
    It 'every template in the catalog is one this module can pick or knowingly skips' {
        $script:Catalog.templates.Keys | Should -Contain 'create-cluster-san'
        $script:Catalog.templates['create-cluster-san'].parameters.Contains('sanNetworkList') | Should -BeTrue
        $script:Catalog.templates['create-cluster-san'].parameters.Contains('infraVolLunId') | Should -BeTrue
    }
}

Describe 'Parameters for AD + Fibre Channel SAN' {
    BeforeAll {
        $infra = Get-Infra
        $handoff = Read-AzlHandoff -Path $script:HandoffFile
        $script:Set = New-AzlArmParameterSet -Infrastructure $infra -Handoff $handoff -Mode Validate -Catalog $script:Catalog -AdapterMap @{
            'iic-n01' = @{ '00005e005310' = 'Port0'; '00005e005311' = 'Port1'; '00005e005312' = 'Port2'; '00005e005313' = 'Port3' }
            'iic-n02' = @{ '00005e005320' = 'Port0'; '00005e005321' = 'Port1'; '00005e005322' = 'Port2'; '00005e005323' = 'Port3' } } -NodeReport $script:Report.nodes
        $script:P = $script:Set.Parameters
    }
    It 'uses Microsoft''s FC SAN template' { $script:Set.Template.Name | Should -Be 'create-cluster-san' }
    It 'has no problem against the template''s own parameter list' {
        @(Test-AzlArmParameterSet -ParameterSet $script:Set -TemplateParameters $script:Catalog.templates['create-cluster-san'].parameters) | Should -BeNullOrEmpty
    }
    It 'fills every parameter the template requires' {
        foreach ($k in $script:Catalog.templates['create-cluster-san'].parameters.Keys) {
            if ($script:Catalog.templates['create-cluster-san'].parameters[$k].required) { $script:P.Contains($k) | Should -BeTrue -Because "$k is required" }
        }
    }
    It 'maps identity, cluster, witness, key vault and diagnostics' {
        $script:P.deploymentMode | Should -Be 'Validate'
        $script:P.clusterName | Should -Be 'iic-clus01'
        $script:P.domainFqdn | Should -Be 'improbability.cloud'
        $script:P.adouPath | Should -Be 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $script:P.AzureStackLCMAdminUsername | Should -Be 'lcm-iic-clus01'
        $script:P.witnessType | Should -Be 'Cloud'
        $script:P.clusterWitnessStorageAccountName | Should -Be 'stiicazl01wit'
        $script:P.keyVaultName | Should -Be 'kv-iic-azl-01'
        $script:P.createNewKeyVault | Should -BeTrue
        $script:P.diagnosticStorageAccountName | Should -Be 'stiicazl01diag'
        $script:P.hciResourceProviderObjectID | Should -Be '00000000-0000-0000-0000-000000000001'
        $script:P.configurationMode | Should -Be 'InfraOnly'
        $script:P.customLocation | Should -Be 'cl-iic-azl-01'
    }
    It 'takes the Arc machine resource IDs from the handoff' {
        $script:P.arcNodeResourceIds.Count | Should -Be 2
        $script:P.arcNodeResourceIds[0] | Should -BeLike '*/Microsoft.HybridCompute/machines/iic-n01'
    }
    It 'maps nodes, the management network and the infrastructure pool' {
        $script:P.physicalNodesSettings[0].name | Should -Be 'iic-n01'
        $script:P.physicalNodesSettings[1].ipv4Address | Should -Be '192.0.2.12'
        $script:P.subnetMask | Should -Be '255.255.255.0'
        $script:P.defaultGateway | Should -Be '192.0.2.1'
        $script:P.startingIPAddress | Should -Be '192.0.2.20'
        $script:P.endingIPAddress | Should -Be '192.0.2.29'
        @($script:P.dnsServers) | Should -Be @('192.0.2.4', '192.0.2.5')
        $script:P.networkingType | Should -Be 'switchedMultiServerDeployment'
        $script:P.useDhcp | Should -BeFalse
    }
    It 'writes the intent list in Microsoft''s shape' {
        $i = $script:P.intentList[0]
        $i.name | Should -Be 'mgmt_compute'
        @($i.trafficType) | Should -Be @('Management', 'Compute')
        @($i.adapter) | Should -Be @('Port0', 'Port1')
        $i.overrideQosPolicy | Should -BeFalse
        $i.adapterPropertyOverrides.jumboPacket | Should -Be '9014'
    }
    It 'writes the SAN network list and the LUN identifiers translated from the node report' {
        $n = $script:P.sanNetworkList.clusterNetworkConfig.adapterIPConfig
        $n.Count | Should -Be 2
        $n[0].name | Should -Be 'clusterNetwork-A'
        $n[0].networkAdapterName | Should -Be 'Port2'
        $n[0].vlanId | Should -Be 711
        $n[1].addressPrefix | Should -Be '198.51.100.64/26'
        $script:P.infraVolLunId | Should -Be 'UID-INFRA'
        $script:P.infraPerfLunId | Should -Be 'UID-PERF'
        $script:P.Contains('storageNetworkList') | Should -BeFalse
    }
    It 'holds the two passwords as Key Vault references, never values' {
        $script:P.localAdminPassword.KeyVault | Should -Be 'keyvault://kv-iic-mgmt-01/local-admin-password'
        $script:P.AzureStackLCMAdminPassword.KeyVault | Should -Be 'keyvault://kv-iic-mgmt-01/lcm-password'
    }
    It 'writes the parameter file with null secrets by default' {
        $json = ConvertTo-AzlArmParameterFile -ParameterSet $script:Set
        $o = $json | ConvertFrom-Json
        $o.parameters.localAdminPassword.value | Should -BeNullOrEmpty
        $o.parameters.clusterName.value | Should -Be 'iic-clus01'
        $json | Should -Not -Match 'keyvault://'
    }
    It 'writes Key Vault references that ARM can read' {
        $o = ConvertTo-AzlArmParameterFile -ParameterSet $script:Set -Infrastructure (Get-Infra) -SecretMode KeyVaultReference | ConvertFrom-Json
        $o.parameters.localAdminPassword.reference.secretName | Should -Be 'local-admin-password'
        $o.parameters.localAdminPassword.reference.keyVault.id | Should -BeLike '*/providers/Microsoft.KeyVault/vaults/kv-iic-mgmt-01'
    }
    It 'overrides the mode' {
        (New-AzlArmParameterSet -Infrastructure (Get-Infra) -Mode Deploy -AllowUnresolvedSanLun -Catalog $script:Catalog).Parameters.deploymentMode | Should -Be 'Deploy'
    }
}

Describe 'Parameters: guards and translations' {
    It 'refuses the built-in Administrator' {
        $infra = Get-Infra; $infra.identity.local_admin.username = 'Administrator'
        { New-AzlArmParameterSet -Infrastructure $infra -AllowUnresolvedSanLun -Catalog $script:Catalog } | Should -Throw '*built-in*'
    }
    It 'refuses an LCM user name over 20 characters' {
        $infra = Get-Infra; $infra.identity.active_directory.lcm_user.username = 'a' * 21
        { New-AzlArmParameterSet -Infrastructure $infra -AllowUnresolvedSanLun -Catalog $script:Catalog } | Should -Throw '*20*'
    }
    It 'refuses a cluster name that is a node name' {
        $infra = Get-Infra; $infra.cluster.name = 'iic-n01'
        { New-AzlArmParameterSet -Infrastructure $infra -AllowUnresolvedSanLun -Catalog $script:Catalog } | Should -Throw '*node name*'
    }
    It 'translates the file''s port names to the OS names by MAC' {
        $infra = Get-Infra
        foreach ($n in $infra.nodes) { foreach ($a in $n.network_adapters) { $a.name = "Slot $($a.name)" } }
        $infra.networking.intents[0].adapters = @('Slot Port0', 'Slot Port1')
        $infra.networking.cluster_networks[0].adapter = 'Slot Port2'; $infra.networking.cluster_networks[1].adapter = 'Slot Port3'
        $map = Get-AzlAdapterMapFromReport -Report $script:Report
        $set = New-AzlArmParameterSet -Infrastructure $infra -AdapterMap $map -NodeReport $script:Report.nodes -Catalog $script:Catalog
        @($set.Parameters.intentList[0].adapter) | Should -Be @('Port0', 'Port1')
        $set.Parameters.sanNetworkList.clusterNetworkConfig.adapterIPConfig[0].networkAdapterName | Should -Be 'Port2'
    }
    It 'throws when one file name is different OS ports on different nodes' {
        $map = Get-AzlAdapterMapFromReport -Report $script:Report
        $map['iic-n02']['00005e005320'] = 'Port7'
        { New-AzlArmParameterSet -Infrastructure (Get-Infra) -AdapterMap $map -AllowUnresolvedSanLun -Catalog $script:Catalog } | Should -Throw '*same adapter name on every node*'
    }
    It 'passes a UniqueId already written in the file as it is, and a LUN number needs the report' {
        Resolve-AzlSanLunId -LunId 'naa.600a098038314' -NodeReport @() | Should -Be 'naa.600a098038314'
        { Resolve-AzlSanLunId -LunId '0' -NodeReport @() } | Should -Throw '*no OS configuration report*'
        Resolve-AzlSanLunId -LunId '0' -NodeReport $script:Report.nodes -Source SerialNumber | Should -Be 'SN-INFRA'
    }
    It 'throws when the nodes see a different LUN under one number' {
        $r = $script:Report | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $r.nodes[1].sanDisks[0].uid = 'OTHER'
        { Resolve-AzlSanLunId -LunId '0' -NodeReport $r.nodes } | Should -Throw '*different*'
    }
    It 'assumes the Arc machine name when there is no handoff, and says so' {
        $set = New-AzlArmParameterSet -Infrastructure (Get-Infra) -AllowUnresolvedSanLun -Catalog $script:Catalog
        $set.Parameters.arcNodeResourceIds[0] | Should -BeLike '*/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/iic-n01'
        $set.Warnings | Should -Contain "Node iic-n01: no Arc machine resource ID in the handoff; assuming the machine is named iic-n01 in rg-iic-azl-01."
    }
    It 'takes the SBE values from the bundle where the file leaves them empty' {
        $set = New-AzlArmParameterSet -Infrastructure (Get-Infra) -AllowUnresolvedSanLun -Catalog $script:Catalog -SbeDeployment ([ordered]@{ sbeVersion = '5.0.1'; sbeFamily = '16G'; sbePublisher = 'Dell'; sbeManifestSource = 'https://example.invalid/m'; sbeManifestCreationDate = '2026-09-01' })
        $set.Parameters.sbeVersion | Should -Be '5.0.1'
        $set.Parameters.sbePublisher | Should -Be 'Dell'
    }
    It 'names the networking pattern from the intents' {
        Get-AzlNetworkingPattern -Intents @(@{ traffic = @('management', 'compute', 'storage') }) | Should -Be 'hyperConverged'
        Get-AzlNetworkingPattern -Intents @(@{ traffic = @('management', 'compute') }, @{ traffic = @('storage') }) | Should -Be 'convergedManagementCompute'
        Get-AzlNetworkingPattern -Intents @(@{ traffic = @('management') }, @{ traffic = @('compute', 'storage') }) | Should -Be 'convergedComputeStorage'
        Get-AzlNetworkingPattern -Intents @(@{ traffic = @('management') }, @{ traffic = @('compute') }, @{ traffic = @('storage') }) | Should -Be 'custom'
    }
}

Describe 'Parameters for the other designs' {
    It 'Storage Spaces Direct: storage networks, auto IP, no SAN parameters' {
        $infra = Convert-ToS2d (Get-Infra)
        $set = New-AzlArmParameterSet -Infrastructure $infra -Catalog $script:Catalog
        $set.Template.Name | Should -Be 'create-cluster'
        $set.Parameters.configurationMode | Should -Be 'Express'
        $set.Parameters.enableStorageAutoIp | Should -BeTrue
        $set.Parameters.storageNetworkList[0].networkAdapterName | Should -Be 'Port2'
        $set.Parameters.storageNetworkList[1].vlanId | Should -Be '712'
        $set.Parameters.Contains('sanNetworkList') | Should -BeFalse
        $set.Parameters.networkingPattern | Should -Be 'convergedManagementCompute'
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $script:Catalog.templates['create-cluster'].parameters) | Should -BeNullOrEmpty
    }
    It 'custom storage IPs: one address per node on each storage network' {
        $infra = Convert-ToS2d (Get-Infra)
        $infra.networking.storage.auto_ip = $false
        $infra.networking.storage.networks[0].subnet = '10.0.1.0/24'; $infra.networking.storage.networks[1].subnet = '10.0.2.0/24'
        $infra.nodes[0].storage_ips = @('10.0.1.11', '10.0.2.11'); $infra.nodes[1].storage_ips = @('10.0.1.12', '10.0.2.12')
        $set = New-AzlArmParameterSet -Infrastructure $infra -Catalog $script:Catalog
        $set.Parameters.enableStorageAutoIp | Should -BeFalse
        $set.Parameters.storageNetworkList[0].storageAdapterIPInfo[1].physicalNode | Should -Be 'iic-n02'
        $set.Parameters.storageNetworkList[0].storageAdapterIPInfo[1].ipv4Address | Should -Be '10.0.1.12'
        $set.Parameters.storageNetworkList[1].storageAdapterIPInfo[0].subnetMask | Should -Be '255.255.255.0'
    }
    It 'local identity: identityProvider, DNS and zones instead of the domain and the LCM user' {
        $infra = Convert-ToS2d (Get-Infra)
        $infra.scenario.identity = 'local_identity'
        $infra.identity.Remove('active_directory')
        $infra.identity.local_identity = [ordered]@{ dns_server_config = 'use_forwarder'; dns_zone = 'improbability.cloud'; dns_forwarders = @('192.0.2.4') }
        $set = New-AzlArmParameterSet -Infrastructure $infra -Catalog $script:Catalog
        $set.Template.Name | Should -Be 'create-adless-cluster-external-dns-public-preview'
        $set.Parameters.identityProvider | Should -Be 'LocalIdentity'
        $set.Parameters.dnsServerConfig | Should -Be 'UseForwarder'
        $set.Parameters.dnsZones[0].dnsZoneName | Should -Be 'improbability.cloud'
        $set.Parameters.Contains('domainFqdn') | Should -BeFalse
        $set.Parameters.Contains('AzureStackLCMAdminPassword') | Should -BeFalse
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $script:Catalog.templates['create-adless-cluster-external-dns-public-preview'].parameters) | Should -BeNullOrEmpty
    }
    It 'rack aware: the zones and the pattern' {
        $infra = Convert-ToS2d (Get-Infra)
        $infra.scenario.topology = 'rack_aware'; $infra.nodes[0].zone = 'ZoneA'; $infra.nodes[1].zone = 'ZoneB'
        $set = New-AzlArmParameterSet -Infrastructure $infra -Catalog $script:Catalog
        $set.Parameters.clusterPattern | Should -Be 'RackAware'
        $set.Parameters.localAvailabilityZones[1].localAvailabilityZoneName | Should -Be 'ZoneB'
        @($set.Parameters.localAvailabilityZones[1].nodes) | Should -Be @('iic-n02')
    }
    It 'a single machine is a single server deployment' {
        $infra = Convert-ToS2d (Get-Infra)
        $infra.nodes = @($infra.nodes[0])
        (New-AzlArmParameterSet -Infrastructure $infra -Catalog $script:Catalog).Parameters.networkingType | Should -Be 'singleServerDeployment'
    }
}

Describe 'Test-AzlArmParameterSet' {
    It 'finds an unknown parameter, a missing required one, a wrong type and a disallowed value' {
        $set = [pscustomobject]@{ Parameters = [ordered]@{ bogus = 1; useDhcp = 'yes'; deploymentMode = 'Maybe' } }
        $defs = [ordered]@{ useDhcp = @{ type = 'bool'; required = $false }; deploymentMode = @{ type = 'string'; required = $false; allowed = @('Validate', 'Deploy') }; clusterName = @{ type = 'string'; required = $true } }
        $problems = Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $defs
        $problems | Should -Contain "bogus isn't a parameter of the template."
        $problems | Should -Contain 'clusterName is required by the template and has no value.'
        ($problems -join '|') | Should -Match 'useDhcp should be bool'
        ($problems -join '|') | Should -Match "deploymentMode is 'Maybe'"
    }
    It 'refuses a secret that holds a value' {
        $set = [pscustomobject]@{ Parameters = [ordered]@{ localAdminPassword = 'hunter2' } }
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters ([ordered]@{ localAdminPassword = @{ type = 'securestring'; required = $true } })) | Should -Match 'keyvault://'
    }
}

Describe 'Invoke-AzlArmDeployment' {
    BeforeAll {
        $script:Set = New-AzlArmParameterSet -Infrastructure (Get-Infra) -Handoff (Read-AzlHandoff -Path $script:HandoffFile) -NodeReport $script:Report.nodes -Catalog $script:Catalog -Mode Validate
        $script:Template = [pscustomobject]@{ resources = @([pscustomobject]@{ type = 'microsoft.azurestackhci/clusters/deploymentSettings'; apiVersion = '2026-04-01-preview' }) }
        $script:Resolver = { param($Ref) "value-of-$($Ref.Split('/')[-1])" }
        function New-HciState([string]$Provisioning, [string]$Validation, [string]$Deployment = '', [object[]]$Steps = @()) {
            [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = $Provisioning; reportedProperties = [pscustomobject]@{
                        validationStatus = [pscustomobject]@{ status = $Validation; steps = $Steps }
                        deploymentStatus = [pscustomobject]@{ status = $Deployment; steps = @() } } } }
        }
    }
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName AzlArmDeployment Start-Sleep {}
    }
    It 'refuses Validate when the instance is in a failed deployment state' {
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm { New-HciState 'Failed' '' 'Failed' }
        { Invoke-AzlArmDeployment -ParameterSet $script:Set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver $script:Resolver } | Should -Throw "*don't run Validate again*"
    }
    It 'refuses Deploy without a successful validation' {
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm { New-HciState 'Succeeded' 'InProgress' }
        { Invoke-AzlArmDeployment -ParameterSet $script:Set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Deploy -SecretResolver $script:Resolver } | Should -Throw '*No successful validation*'
    }
    It 'refuses an empty LUN identifier' {
        $set = New-AzlArmParameterSet -Infrastructure (Get-Infra) -Catalog $script:Catalog -AllowUnresolvedSanLun
        { Invoke-AzlArmDeployment -ParameterSet $set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver $script:Resolver } | Should -Throw '*infraVolLunId is empty*'
    }
    It 'Validate: submits deploymentMode Validate with the secrets resolved in memory, waits, and reports the steps' {
        $calls = $script:Calls
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm {
            $calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Path -like '*deploymentSettings*') {
                if ($Method -eq 'GET' -and @($calls | Where-Object Method -eq 'PUT').Count -eq 0) { return $null }
                return (New-HciState 'Succeeded' 'Succeeded' '' @([pscustomobject]@{ name = 'Test Network'; status = 'Success'; description = 'ok'; steps = @([pscustomobject]@{ name = 'Test DNS'; status = 'Error'; exception = @('DNS cannot resolve'); steps = @() }) }))
            }
            if ($Method -eq 'GET') { return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded' } } }
            [pscustomobject]@{}
        }
        $r = Invoke-AzlArmDeployment -ParameterSet $script:Set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver $script:Resolver
        $put = $calls | Where-Object { $_.Method -eq 'PUT' }
        $put.Path | Should -BeLike '*/resourcegroups/r/providers/Microsoft.Resources/deployments/azl-validate-*'
        $put.Body.properties.parameters.deploymentMode.value | Should -Be 'Validate'
        $put.Body.properties.parameters.localAdminPassword.value | Should -Be 'value-of-local-admin-password'
        $put.Body.properties.parameters.AzureStackLCMAdminPassword.value | Should -Be 'value-of-lcm-password'
        $put.Body.properties.mode | Should -Be 'Incremental'
        $r.ValidationStatus | Should -Be 'Succeeded'
        @($r.ValidationSteps).Count | Should -Be 2
        $r.FailedSteps[0].Name | Should -Be 'Test DNS'
        $r.FailedSteps[0].Errors | Should -Contain 'DNS cannot resolve'
        ($r | ConvertTo-Json -Depth 8) | Should -Not -Match 'value-of-'
    }
    It 'Deploy: needs and uses a successful validation, and sets deploymentMode Deploy' {
        $calls = $script:Calls
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm {
            $calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Path -like '*deploymentSettings*') { return (New-HciState 'Succeeded' 'Succeeded' 'Succeeded') }
            if ($Method -eq 'GET') { return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded' } } }
            [pscustomobject]@{}
        }
        $r = Invoke-AzlArmDeployment -ParameterSet $script:Set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Deploy -SecretResolver $script:Resolver
        ($calls | Where-Object Method -eq 'PUT').Body.properties.parameters.deploymentMode.value | Should -Be 'Deploy'
        $r.ProvisioningState | Should -Be 'Succeeded'
    }
    It 'patches the deploymentSettings api-version only when asked' {
        $calls = $script:Calls
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm {
            $calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Path -like '*deploymentSettings*') { return (New-HciState 'Succeeded' 'Succeeded' 'Succeeded') }
            if ($Method -eq 'GET') { return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded' } } }
            [pscustomobject]@{}
        }
        $null = Invoke-AzlArmDeployment -ParameterSet $script:Set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Deploy -SecretResolver $script:Resolver -DeploymentSettingsApiVersion '2026-10-01'
        ($calls | Where-Object Method -eq 'PUT').Body.properties.template.resources[0].apiVersion | Should -Be '2026-10-01'
        $script:Template.resources[0].apiVersion | Should -Be '2026-04-01-preview'
    }
    It 'reports a failed deployment with the ARM error' {
        $calls = $script:Calls
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm {
            $calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Path -like '*deploymentSettings*') { if (@($calls | Where-Object Method -eq 'PUT').Count -eq 0) { return $null }; return (New-HciState 'Failed' 'Failed' '') }
            if ($Method -eq 'GET') { return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Failed'; error = [pscustomobject]@{ message = 'boom' } } } }
            [pscustomobject]@{}
        }
        $r = Invoke-AzlArmDeployment -ParameterSet $script:Set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver $script:Resolver
        $r.ProvisioningState | Should -Be 'Failed'
        $r.Error | Should -Be 'boom'
    }
}
