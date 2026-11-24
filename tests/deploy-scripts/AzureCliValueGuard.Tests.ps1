#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# A value of infrastructure.yml that holds one of & | < > ^ % " or a line break must stop an Azure CLI script with exit code 2 before any Azure call, also under
# -WhatIf: on Windows az is a batch file (az.cmd) and cmd.exe would read the character as an operator or a variable. One document that has every section the scripts
# read is changed in one place for each script (a tag value, a resource group, a name ...). Every az command is replaced by a fake (tests/fixtures/AzCliFake.ps1):
# the fake counts the calls, and each run has to make none. The message names the key and shows the value of the file (it is not a secret).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/AzureCliValueGuard.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks and stub parameters.')]
param()

BeforeDiscovery {
    # script name, the key the message must name, the change that puts a bad value there
    $script:Cases = @(
        # tags (a value with &)
        @{ Script = 'Deploy-Subscriptions.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'Deploy-ResourceGroups.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-AutomationManagedIdentity.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'Deploy-VirtualNetworks.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'Deploy-VpnGateway.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-VpnConnection.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-AzureBastion.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-LandingZoneNsg.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-NatGateway.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-ArcGateway.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'Deploy-KeyVaults.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'Deploy-ManagementVMs.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-CloudWitnessStorageAccount.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-StoragePath.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-VmImage.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-NetworkSecurityGroup.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'New-LogicalNetwork.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'Deploy-DataCollectionEndpoint.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'Deploy-LogAnalyticsWorkspace.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'Deploy-ActionGroup.azcli.ps1'; Key = 'tags'; Bad = 'a&b'; Edit = { param($d) $d.tags = [ordered]@{ owner = 'a&b' } } }
        @{ Script = 'Invoke-AzurePolicyTier1-Orchestrated.azcli.ps1'; Key = 'tag name'; Bad = 'a&b'; Edit = { param($d) $d.landing_zone.policy.required_tags = @('a&b') } }
        # tag key with |
        @{ Script = 'Deploy-ResourceGroups.azcli.ps1'; Key = 'key'; Bad = 'k|ey'; Edit = { param($d) $d.tags = [ordered]@{ 'k|ey' = 'x' } } }
        # the resource group, the instance, the location
        @{ Script = 'Test-ArcPrerequisites.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'Test-ArcRegistration.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'Invoke-AzureLocalArmDeployment.azcli.ps1'; Key = 'cluster.name'; Bad = 'cl^x'; Edit = { param($d) $d.cluster.name = 'cl^x' } }
        @{ Script = 'Test-AzureLocalClusterDeployment.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'New-CloudWitnessStorageAccount.azcli.ps1'; Key = 'azure.location'; Bad = 'east%us'; Edit = { param($d) $d.azure.location = 'east%us' } }
        @{ Script = 'Enable-ArcSshConnectivity.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'New-StoragePath.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'New-VmImage.azcli.ps1'; Key = 'azure.custom_location'; Bad = 'cl|x'; Edit = { param($d) $d.azure.custom_location = 'cl|x' } }
        @{ Script = 'New-NetworkSecurityGroup.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'New-LogicalNetwork.azcli.ps1'; Key = 'azure.location'; Bad = 'east<us'; Edit = { param($d) $d.azure.location = 'east<us' } }
        @{ Script = 'Invoke-VerifyPostDeployment.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'Set-NetworkSecurityGroupRule.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'Test-NetworkSecurityGroupRule.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'Install-AzureMonitorAgent.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'Enable-HciInsights.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'Enable-AzureHybridBenefit.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'Enable-WindowsServerSubscription.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'New-ArcGateway.azcli.ps1'; Key = 'azure.location'; Bad = 'east%us'; Edit = { param($d) $d.scenario.outbound_path = 'arc_gateway'; $d.networking.outbound = [ordered]@{ arc_gateway = [ordered]@{ name = 'arcgw-azl-01'; resource_group = 'rg-azl-01' } }; $d.azure.location = 'east%us' } }
        @{ Script = 'New-AutomationManagedIdentity.azcli.ps1'; Key = 'azure.location'; Bad = 'east%us'; Edit = { param($d) $d.azure.location = 'east%us' } }
        # names and display names of the landing zone
        @{ Script = 'Deploy-ManagementGroups.azcli.ps1'; Key = 'display_name'; Bad = 'Root & Co'; Edit = { param($d) $d.landing_zone.management_groups[0].display_name = 'Root & Co' } }
        @{ Script = 'Set-ManagementGroupDisplayNames.azcli.ps1'; Key = 'display_name'; Bad = 'Root & Co'; Edit = { param($d) $d.landing_zone.management_groups[0].display_name = 'Root & Co' } }
        @{ Script = 'Deploy-Subscriptions.azcli.ps1'; Key = '\.name'; Bad = 'sub|new'; Edit = { param($d) $d.landing_zone.subscriptions[1].name = 'sub|new' } }
        @{ Script = 'Deploy-ResourceGroups.azcli.ps1'; Key = 'location'; Bad = 'east&us'; Edit = { param($d) $d.landing_zone.resource_groups[0].location = 'east&us' } }
        @{ Script = 'Deploy-CostBudgets.azcli.ps1'; Key = 'resource_group'; Bad = 'rg&x'; Edit = { param($d) $d.landing_zone.budgets = @([ordered]@{ name = 'budget-azl-01'; scope = 'resource_group'; resource_group = 'rg&x'; amount = 10; contact_emails = @('ops@example.test') }) } }
        @{ Script = 'Deploy-VirtualNetworks.azcli.ps1'; Key = 'subnet names'; Bad = 'snet&x'; Edit = { param($d) $d.landing_zone.networks[0].subnets[2].name = 'snet&x' } }
        @{ Script = 'Deploy-VpnGateway.azcli.ps1'; Key = 'the resource group'; Bad = 'rg^x'; Edit = { param($d) $d.landing_zone.connectivity.vpn_gateway.resource_group = 'rg^x' } }
        @{ Script = 'New-AzureBastion.azcli.ps1'; Key = 'the resource group'; Bad = 'rg^x'; Edit = { param($d) $d.landing_zone.connectivity.bastion.resource_group = 'rg^x' } }
        @{ Script = 'New-NatGateway.azcli.ps1'; Key = 'subnets'; Bad = 'snet|x'; Edit = { param($d) $d.landing_zone.connectivity.nat_gateway.subnets = @('snet|x') } }
        @{ Script = 'New-LandingZoneNsg.azcli.ps1'; Key = 'description'; Bad = 'a&b'; Edit = { param($d) $d.landing_zone.network_security_groups[0].rules[0].description = 'a&b' } }
        @{ Script = 'Deploy-KeyVaults.azcli.ps1'; Key = 'resource_group'; Bad = 'rg&x'; Edit = { param($d) $d.key_vaults[0].resource_group = 'rg&x' } }
        @{ Script = 'Deploy-ManagementVMs.azcli.ps1'; Key = 'admin_username'; Bad = 'adm&in'; Edit = { param($d) $d.landing_zone.virtual_machines[0].admin_username = 'adm&in' } }
        @{ Script = 'New-VpnConnection.azcli.ps1'; Key = 'landing_zone.connectivity.vpn_gateway.name'; Bad = 'vpn&g'; Edit = { param($d) $d.landing_zone.connectivity.vpn_gateway.name = 'vpn&g' } }
        @{ Script = 'Configure-P2sVpn.azcli.ps1'; Key = 'root_certificate_name'; Bad = 'root&cert'; Edit = { param($d) $d.landing_zone.connectivity.vpn_gateway.point_to_site.root_certificate_name = 'root&cert' } }
        @{ Script = 'New-EntraSecurityGroups.azcli.ps1'; Key = 'purpose'; Bad = 'ops & dev'; Edit = { param($d) $d.identity.entra.groups[0].purpose = 'ops & dev' } }
        @{ Script = 'Set-EntraGroupRoleAssignments.azcli.ps1'; Key = 'roles'; Bad = 'Reader|x'; Edit = { param($d) $d.identity.entra.groups[0].roles = @('Reader|x') } }
        @{ Script = 'Test-ManagementResources.azcli.ps1'; Key = 'ResourceGroup'; Bad = 'rg&calc'; Edit = { param($d) $d.landing_zone.resource_groups[0].name = 'rg&calc' } }
        @{ Script = 'Test-ManagementConnectivity.azcli.ps1'; Key = 'bastion'; Bad = 'bas&x'; Edit = { param($d) $d.landing_zone.connectivity.bastion.name = 'bas&x' } }
        @{ Script = 'Test-ManagementConfiguration.azcli.ps1'; Key = 'key_vaults name'; Bad = 'kv&x'; Edit = { param($d) $d.key_vaults[0].name = 'kv&x' } }
        @{ Script = 'Deploy-LogAnalyticsWorkspace.azcli.ps1'; Key = 'workspace_resource_group'; Bad = 'rg&x'; Edit = { param($d) $d.operations.monitoring.workspace_resource_group = 'rg&x' } }
        @{ Script = 'Deploy-DataCollectionEndpoint.azcli.ps1'; Key = 'workspace_resource_group'; Bad = 'rg&x'; Edit = { param($d) $d.operations.monitoring.workspace_resource_group = 'rg&x' } }
        @{ Script = 'Deploy-ActionGroup.azcli.ps1'; Key = 'action_group'; Bad = 'ag&x'; Edit = { param($d) $d.operations.monitoring.action_group = 'ag&x' } }
        @{ Script = 'Invoke-AzurePolicyTier1-Orchestrated.azcli.ps1'; Key = 'management_group'; Bad = 'mg&x'; Edit = { param($d) $d.landing_zone.policy.management_group = 'mg&x' } }
        # day 2 (stage 08 task 01) and handover (stage 07 task 06)
        @{ Script = 'Get-AvailableSolutionUpdate.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' } }
        @{ Script = 'Get-AvailableSolutionUpdate.azcli.ps1'; Key = 'cluster.name'; Bad = 'cl^x'; Edit = { param($d) $d.cluster.name = 'cl^x' } }
        @{ Script = 'Set-CustomerTransfer.azcli.ps1'; Key = 'azure.resource_group'; Bad = 'rg&calc'; Edit = { param($d) $d.azure.resource_group = 'rg&calc' }; AzParams = @{ CustomerTenantId = [guid]::NewGuid().ToString(); CustomerAdminUPN = 'admin@example.test' } }
        @{ Script = 'Set-CustomerTransfer.azcli.ps1'; Key = 'cluster.name'; Bad = 'cl|x'; Edit = { param($d) $d.cluster.name = 'cl|x' }; AzParams = @{ CustomerTenantId = [guid]::NewGuid().ToString(); CustomerAdminUPN = 'admin@example.test' } }
        @{ Script = 'Set-CustomerTransfer.azcli.ps1'; Key = '-CustomerAdminUPN'; Bad = 'a|b@example.test'; Edit = { param($d) $null = $d }; AzParams = @{ CustomerTenantId = [guid]::NewGuid().ToString(); CustomerAdminUPN = 'a|b@example.test' } }
    )
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Scripts = @{}
    foreach ($f in Get-ChildItem -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'deploy')) -Recurse -Filter '*.azcli.ps1') { if (-not $script:Scripts.ContainsKey($f.Name) -or $f.FullName.Length -lt $script:Scripts[$f.Name].Length) { $script:Scripts[$f.Name] = $f.FullName } }
    Import-Module powershell-yaml
    function az { }
    . ([IO.Path]::Combine($repo, 'tests', 'fixtures', 'AzCliFake.ps1'))

    # The base document of the fixtures, with every landing-zone, identity, monitoring and vault section the scripts read.
    function New-GuardDoc {
        $d = New-AzTestDoc
        $sub = $global:AzlTestSubscription
        $d.azure.automation_identity = [ordered]@{ type = 'managed_identity'; name = 'id-azl-auto-01' }
        $d.landing_zone = [ordered]@{
            management_groups       = @([ordered]@{ name = 'mg-azl-root'; display_name = 'Azure Local Root' }, [ordered]@{ name = 'mg-azl-lz'; display_name = 'Landing Zones'; parent = 'mg-azl-root' })
            subscriptions           = @([ordered]@{ name = 'sub-azl-mgmt'; id = $sub; management_group = 'mg-azl-lz' }, [ordered]@{ name = 'sub-azl-new'; billing_scope = '/providers/Microsoft.Billing/billingAccounts/ba-1/enrollmentAccounts/ea-1'; management_group = 'mg-azl-lz' })
            resource_groups         = @([ordered]@{ name = 'rg-azl-mgmt-01'; subscription = 'sub-azl-mgmt'; location = 'eastus' })
            networks                = @([ordered]@{ name = 'vnet-azl-hub-01'; subscription = 'sub-azl-mgmt'; resource_group = 'rg-azl-mgmt-01'; location = 'eastus'; address_space = @('10.10.0.0/16')
                    subnets = @([ordered]@{ name = 'GatewaySubnet'; prefix = '10.10.0.0/27' }, [ordered]@{ name = 'AzureBastionSubnet'; prefix = '10.10.1.0/26' }, [ordered]@{ name = 'snet-azl-mgmt-01'; prefix = '10.10.2.0/24'; network_security_group = 'nsg-azl-mgmt' }) })
            network_security_groups = @([ordered]@{ name = 'nsg-azl-mgmt'; rules = @([ordered]@{ name = 'allow-https'; priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; destination_port_ranges = @('443') }) })
            connectivity            = [ordered]@{
                vpn_gateway = [ordered]@{ name = 'vpng-azl-hub-01'; network = 'vnet-azl-hub-01'; sku = 'VpnGw1AZ'; bgp_asn = 65515
                    site_to_site = @([ordered]@{ connection_name = 'cn-azl-01'; peer_public_ip = '203.0.113.1'; peer_address_prefixes = @('192.0.2.0/24'); shared_key = 'keyvault://kv-azl-01/vpn-key' })
                    point_to_site = [ordered]@{ address_pool = '172.16.0.0/24'; authentication = 'certificate'; root_certificate_name = 'rootcert-azl-01'; root_certificate = 'keyvault://kv-azl-01/p2s-root' } }
                bastion     = [ordered]@{ name = 'bas-azl-01'; network = 'vnet-azl-hub-01'; sku = 'Standard' }
                nat_gateway = [ordered]@{ name = 'nat-azl-01'; network = 'vnet-azl-hub-01'; subnets = @('snet-azl-mgmt-01') }
            }
            virtual_machines        = @([ordered]@{ name = 'vm-azl-dc-01'; role = 'domain_controller'; network = 'vnet-azl-hub-01'; subnet = 'snet-azl-mgmt-01'; private_ip = '10.10.2.10'; size = 'Standard_D2s_v5'; os = 'windows_server_2025'; resource_group = 'rg-azl-mgmt-01'; admin_username = 'azladmin'; admin_password = 'keyvault://kv-azl-01/vm-admin' })
            policy                  = [ordered]@{ management_group = 'mg-azl-lz'; required_tags = @('environment', 'owner') }
        }
        $d.key_vaults = @([ordered]@{ name = 'kv-azl-01'; subscription_id = $sub; resource_group = 'rg-azl-mgmt-01' })
        $d.identity = [ordered]@{ entra = [ordered]@{ groups = @([ordered]@{ name = 'grp-azl-ops'; purpose = 'Operations'; roles = @('Reader'); scope = "/subscriptions/$sub/resourceGroups/rg-azl-mgmt-01" }) } }
        $d.operations = [ordered]@{
            monitoring    = [ordered]@{ enabled = $true; log_analytics_workspace = 'law-azl-01'; workspace_resource_group = 'rg-azl-mgmt-01'; retention_days = 90; data_collection_endpoint = 'dce-azl-01'; data_collection_rule = 'dcr-azl-01'; action_group = 'ag-azl-ops'; alert_email = 'ops@example.test' }
            notifications = [ordered]@{ emails = @('ops@example.test') }
        }
        $d.cluster.witness.storage_account = 'stazlwitness01'
        $d.operations.licensing = [ordered]@{ azure_hybrid_benefit = $true; windows_server_subscription = $true }
        $d.scenario.connectivity = 'connected'
        $d
    }
    function New-GuardFile([scriptblock]$Edit) {
        $d = New-GuardDoc
        & $Edit $d
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $d)
        $file
    }
}

AfterAll { Remove-Variable -Name AzlFake, AzlFakeDispatch, AzlTestTenant, AzlTestSubscription, AzlFakeSignIn -Scope Global -ErrorAction SilentlyContinue }

Describe 'a value of the file that az.cmd cannot carry' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
    }

    It '<Script> refuses <Key> with <Bad> (exit code 2, no az call, also under -WhatIf)' -ForEach $script:Cases {
        $file = New-GuardFile $Edit
        $supportsWhatIf = (Get-Command -Name $script:Scripts[$Script]).Parameters.ContainsKey('WhatIf')
        $extra = @{}
        if (Get-Variable -Name AzParams -ErrorAction Ignore) { $extra = $AzParams }
        foreach ($dry in @($false, $true | Where-Object { -not $_ -or $supportsWhatIf })) {
            $r = if ($dry) { Invoke-AzTool $script:Scripts[$Script] $file $extra -DryRun } else { Invoke-AzTool $script:Scripts[$Script] $file $extra }
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Key
            $r.Text | Should -Match ([regex]::Escape($Bad))
            $global:AzlFake.Calls.Count | Should -Be 0 -Because 'nothing is sent to Azure before the file is accepted'
        }
    }
}
