#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The ARM parameters of an iSCSI SAN deployment (Microsoft's create-cluster-san-iscsi template) and the cluster network adapter properties of a SAN
# deployment. No Azure call is made.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/arm-deployment/ArmDeployment.Iscsi.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\azure-local\AzlAzure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\arm-deployment\AzlArmDeployment.psm1') -Force
    Import-Module powershell-yaml
    $script:Fixture = Join-Path $repo 'tests\fixtures\infrastructure.fc-san.yml'
    $script:Catalog = Get-AzlArmTemplateCatalog
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    function Get-FcInfra { Import-AzlInfrastructure -Path $script:Fixture -SkipValidation }
    # The Fibre Channel fixture turned into an iSCSI design: two dedicated iSCSI ports and an initiator name per node, two iSCSI networks, two targets.
    function Get-IscsiInfra {
        $infra = Get-FcInfra
        $infra.storage.san.type = 'iscsi'
        $infra.storage.san.Remove('fibre_channel')
        $infra.storage.san['iscsi'] = [ordered]@{
            targets  = @([ordered]@{ iqn = 'iqn.2015-10.example:array-a'; portals = @('198.51.100.130:3260', '198.51.100.131'); fabric = 'A' }, [ordered]@{ iqn = 'iqn.2015-10.example:array-b'; portals = @('198.51.100.194'); fabric = 'B' })
            chap     = [ordered]@{ enabled = $false }
            networks = @([ordered]@{ fabric = 'A'; subnet = '198.51.100.128/26'; vlan_id = 500 }, [ordered]@{ fabric = 'B'; subnet = '198.51.100.192/26' })
        }
        $number = 0
        foreach ($node in $infra.nodes) {
            $number++
            $node.san = [ordered]@{ initiator_iqn = "iqn.1991-05.com.microsoft:iic-n0$number" }
            $ports = [System.Collections.Generic.List[object]]::new()
            foreach ($port in $node.network_adapters) { if ($port.name -ne 'Port4') { $ports.Add($port) } }
            $ports.Add([ordered]@{ name = 'Port4'; mac_address = "00:00:5E:00:53:${number}4"; roles = @('iscsi:a'); ip_assignment = 'none' })
            $ports.Add([ordered]@{ name = 'Port5'; mac_address = "00:00:5E:00:53:${number}5"; roles = @('iscsi:b'); ip_assignment = 'none' })
            $node.network_adapters = $ports.ToArray()
        }
        $infra
    }
    function New-Set([System.Collections.IDictionary]$Infra) { New-AzlArmParameterSet -Infrastructure $Infra -AllowUnresolvedSanLun -Catalog $script:Catalog }
}

Describe 'Template for an iSCSI SAN' {
    It 'picks create-cluster-san-iscsi with Active Directory' {
        (Select-AzlArmTemplate -Infrastructure (Get-IscsiInfra) -Catalog $script:Catalog).Name | Should -Be 'create-cluster-san-iscsi'
    }
    It 'refuses local identity and rack aware: Microsoft has no template' {
        $infra = Get-IscsiInfra; $infra.scenario.identity = 'local_identity'
        { Select-AzlArmTemplate -Infrastructure $infra -Catalog $script:Catalog } | Should -Throw '*iSCSI SAN with local identity*'
        $infra = Get-IscsiInfra; $infra.scenario.topology = 'rack_aware'
        { Select-AzlArmTemplate -Infrastructure $infra -Catalog $script:Catalog } | Should -Throw '*Rack aware*'
    }
}

Describe 'Parameters for an iSCSI SAN' {
    BeforeAll { $script:Set = New-Set (Get-IscsiInfra); $script:P = $script:Set.Parameters }

    It 'passes the template check: every parameter is one the template has, with the right type' {
        @(Test-AzlArmParameterSet -ParameterSet $script:Set -TemplateParameters $script:Catalog.templates['create-cluster-san-iscsi'].parameters) | Should -BeNullOrEmpty
    }
    It 'sends one object per node with its Arc ID, name, management address and initiator name' {
        $script:P.nodes.Count | Should -Be 2
        $script:P.nodes[0].name | Should -Be 'iic-n01'
        $script:P.nodes[0].ipv4Address | Should -Be '192.0.2.11'
        $script:P.nodes[0].initiatorIqn | Should -Be 'iqn.1991-05.com.microsoft:iic-n01'
        $script:P.nodes[1].arcNodeResourceId | Should -Match '/providers/Microsoft.HybridCompute/machines/'
    }
    It 'sends the iSCSI ports of the node (role iscsi:a and iscsi:b) with the VLAN and subnet of their network' {
        $c = $script:P.nodes[0].iScsiNetworkConfig.adapterIPConfig
        $c.Count | Should -Be 2
        $c[0].networkAdapterName | Should -Be 'Port4'
        $c[0].vlanId | Should -Be 500
        $c[0].addressPrefix | Should -Be '198.51.100.128/26'
        $c[1].networkAdapterName | Should -Be 'Port5'
        $c[1].vlanId | Should -Be 0
        $c[1].addressPrefix | Should -Be '198.51.100.192/26'
    }
    It 'sends the target portals of each path, each as its own next hop when the network names no router' {
        $c = $script:P.nodes[0].iScsiNetworkConfig.adapterIPConfig
        @($c[0].targetPortalAddresses | ForEach-Object { "$($_.ipAddress)>$($_.nextHop)" }) | Should -Be @('198.51.100.130>198.51.100.130', '198.51.100.131>198.51.100.131')
        @($c[1].targetPortalAddresses | ForEach-Object { $_.ipAddress }) | Should -Be @('198.51.100.194')
    }
    It 'stops when a path has no target portal' {
        $infra = Get-IscsiInfra
        $infra.storage.san.iscsi.targets = @($infra.storage.san.iscsi.targets[0])
        { New-Set $infra } | Should -Throw '*no portal for fabric B*'
    }
    It 'sends the router as the next hop of each target portal when the network names one' {
        $infra = Get-IscsiInfra
        $infra.storage.san.iscsi.networks[0]['next_hop'] = '198.51.100.129'
        $c = (New-Set $infra).Parameters.nodes[1].iScsiNetworkConfig.adapterIPConfig
        @($c[0].targetPortalAddresses | ForEach-Object { $_.ipAddress }) | Should -Be @('198.51.100.130', '198.51.100.131')
        @($c[0].targetPortalAddresses | ForEach-Object { $_.nextHop } | Select-Object -Unique) | Should -Be @('198.51.100.129')
        @($c[1].targetPortalAddresses | ForEach-Object { $_.nextHop }) | Should -Be @('198.51.100.194')
    }
    It 'sends the jumbo packet size of the file, and the standard frame when the file has none' {
        $script:P.nodes[0].iScsiNetworkConfig.adapterProperties.jumboPacket | Should -Be 1514
        $infra = Get-IscsiInfra; $infra.storage.san.iscsi['jumbo_packet'] = 9014
        (New-Set $infra).Parameters.nodes[0].iScsiNetworkConfig.adapterProperties.jumboPacket | Should -Be 9014
    }
    It 'leaves out the parameters this template does not have, without a warning' {
        foreach ($k in 'arcNodeResourceIds', 'physicalNodesSettings', 'networkingType', 'networkingPattern', 'securityLevel') { $script:P.Contains($k) | Should -BeFalse -Because $k }
        ($script:Set.Warnings -join ' ') | Should -Not -Match 'Dropped'
    }
    It 'still sends the cluster networks and the LUN parameters of a SAN deployment' {
        $script:P.sanNetworkList.clusterNetworkConfig.adapterIPConfig.Count | Should -Be 2
        $script:P.Contains('infraVolLunId') | Should -BeTrue
        $script:P.configurationMode | Should -Be 'InfraOnly'
    }

    Context 'CHAP' {
        It 'is None without CHAP, and sends no user name or credential' {
            $script:P.chapType | Should -Be 'None'
            $script:P.Contains('chapUsername') | Should -BeFalse
            $script:P.Contains('chapCredential') | Should -BeFalse
        }
        It 'is OneWay with CHAP, with the user name and the credential as a Key Vault reference' {
            $infra = Get-IscsiInfra
            $infra.storage.san.iscsi.chap = [ordered]@{ enabled = $true; username = 'azl-initiator'; secret = 'keyvault://kv-iic-mgmt-01/iscsi-chap' }
            $p = (New-Set $infra).Parameters
            $p.chapType | Should -Be 'OneWay'
            $p.chapUsername | Should -Be 'azl-initiator'
            $p.chapCredential.KeyVault | Should -Be 'keyvault://kv-iic-mgmt-01/iscsi-chap'
        }
        It 'is Mutual when chap.mutual is true' {
            $infra = Get-IscsiInfra
            $infra.storage.san.iscsi.chap = [ordered]@{ enabled = $true; mutual = $true; username = 'azl-initiator'; secret = 'keyvault://kv-iic-mgmt-01/iscsi-chap' }
            (New-Set $infra).Parameters.chapType | Should -Be 'Mutual'
        }
        It 'stops when CHAP is on and the user name or the secret is missing' {
            $infra = Get-IscsiInfra
            $infra.storage.san.iscsi.chap = [ordered]@{ enabled = $true; username = 'azl-initiator' }
            { New-Set $infra } | Should -Throw '*chap.username and chap.secret*'
        }
        It 'treats a CHAP credential given as a value as a problem' {
            $set = New-Set (Get-IscsiInfra)
            $set.Parameters['chapCredential'] = 'not-a-reference'
            (@(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $script:Catalog.templates['create-cluster-san-iscsi'].parameters) -join ' ') | Should -Match 'chapCredential holds a value'
        }
    }

    Context 'what the file must give' {
        It 'stops without storage.san.iscsi.networks' {
            $infra = Get-IscsiInfra; $infra.storage.san.iscsi.Remove('networks')
            { New-Set $infra } | Should -Throw '*storage.san.iscsi.networks*'
        }
        It 'stops for a node without an initiator name' {
            $infra = Get-IscsiInfra; $infra.nodes[1].san.Remove('initiator_iqn')
            { New-Set $infra } | Should -Throw '*iic-n02 has no san.initiator_iqn*'
        }
        It 'stops for a node without an iSCSI port' {
            $infra = Get-IscsiInfra
            $infra.nodes[0].network_adapters = @($infra.nodes[0].network_adapters | Where-Object { $_.name -notin 'Port4', 'Port5' })
            { New-Set $infra } | Should -Throw '*iic-n01 has no port with the role iscsi:a or iscsi:b*'
        }
        It 'stops for an iSCSI port whose path has no network' {
            $infra = Get-IscsiInfra
            $infra.storage.san.iscsi.networks = @($infra.storage.san.iscsi.networks[0])
            { New-Set $infra } | Should -Throw '*no entry for fabric B*'
        }
    }
}

Describe 'Cluster network adapter properties of a SAN deployment' {
    It 'sends the values of Microsoft''s template when the file has none, without a warning about sample values' {
        $set = New-Set (Get-FcInfra)
        $a = $set.Parameters.sanNetworkList.clusterNetworkConfig.adapterProperties
        $a.bandwidthPercentageSmb | Should -Be 50
        $a.jumboPacket | Should -Be 9014
        $a.priorityValue8021ActionCluster | Should -Be 7
        $a.priorityValue8021ActionSmb | Should -Be 3
        ($set.Warnings -join ' ') | Should -Not -Match 'sample values'
    }
    It 'sends networking.cluster_network_properties when the file has them' {
        $infra = Get-FcInfra
        $infra.networking['cluster_network_properties'] = [ordered]@{ bandwidth_percentage_smb = 60; jumbo_packet = 1514; priority_cluster = 6; priority_smb = 4 }
        $a = (New-Set $infra).Parameters.sanNetworkList.clusterNetworkConfig.adapterProperties
        $a.bandwidthPercentageSmb | Should -Be 60
        $a.jumboPacket | Should -Be 1514
        $a.priorityValue8021ActionCluster | Should -Be 6
        $a.priorityValue8021ActionSmb | Should -Be 4
    }
    It 'holds no fixed adapter property in the generator' {
        (Get-Content -LiteralPath (Join-Path $repo 'scripts\common\arm-deployment\AzlArmDeployment.psm1') -Raw) | Should -Not -Match 'bandwidthPercentageSmb = \d|jumboPacket = \d'
    }
    It 'reads only registry keys that exist: <_>' -ForEach @(
        'networking.cluster_network_properties.bandwidth_percentage_smb', 'networking.cluster_network_properties.jumbo_packet', 'networking.cluster_network_properties.priority_cluster',
        'networking.cluster_network_properties.priority_smb', 'storage.san.iscsi.networks[].fabric', 'storage.san.iscsi.networks[].vlan_id', 'storage.san.iscsi.networks[].subnet',
        'storage.san.iscsi.networks[].next_hop', 'storage.san.iscsi.jumbo_packet', 'storage.san.iscsi.chap.mutual', 'storage.san.iscsi.chap.username', 'storage.san.iscsi.chap.secret', 'nodes[].san.initiator_iqn'
    ) {
        Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
        $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        @($registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
    }
}
