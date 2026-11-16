#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 02: Deploy-VpnGateway.azcli.ps1 creates the VPN gateway that
# landing_zone.connectivity.vpn_gateway describes, with az commands. "az" is mocked: no Azure, no tenant and no sign-in is used. Ids and ASNs are generated
# or documentation values; the address prefixes use the documentation ranges.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/VpnGateway.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-02-vpn-gateway', 'azurecli', 'Deploy-VpnGateway.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlVpnSub = [guid]::NewGuid().ToString()

    function New-Gateway([hashtable]$Override = @{}) {
        Set-AzOverride ([ordered]@{ name = 'vpng-hub-01'; resource_group = 'rg-conn-01'; network = 'vnet-hub-01'; sku = 'VpnGw2AZ'; bgp_asn = 65010 }) $Override
    }
    function New-Network([hashtable]$Override = @{}) {
        Set-AzOverride ([ordered]@{ name = 'vnet-hub-01'; subscription = 'sub-connectivity'; resource_group = 'rg-net-01'; location = 'westus2'; role = 'hub'; address_space = @('198.51.100.0/24') }) $Override
    }
    function New-InfraFile {
        param([object]$Gateway = (New-Gateway), [object]$Network = (New-Network), [object]$Subscriptions = @([ordered]@{ name = 'sub-connectivity'; id = $global:AzlVpnSub; role = 'connectivity' }),
            [object]$TenantId = $global:AzlFakeTenant, [string]$Location = 'eastus', [object]$Tags = $null)
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($Location) { $doc.azure.location = $Location }
        if ($Tags) { $doc.tags = $Tags }
        $lz = [ordered]@{}
        if ($null -ne $Subscriptions) { $lz.subscriptions = @($Subscriptions) }
        if ($null -ne $Network) { $lz.networks = @($Network) }
        if ($null -ne $Gateway) { $lz.connectivity = [ordered]@{ vpn_gateway = $Gateway } }
        $doc.landing_zone = $lz
        Save-AzInfraFile $doc
    }
    function New-FakeVnet([object[]]$Subnets = @([ordered]@{ name = 'GatewaySubnet'; addressPrefix = '198.51.100.0/27' })) { [ordered]@{ name = 'vnet-hub-01'; id = '/vnets/vnet-hub-01'; subnets = @($Subnets) } }
}

Describe 'Deploy-VpnGateway.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlVpnSub, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
        Add-AzRoute 'network vnet show*' (New-FakeVnet)
        Add-AzRoute 'network vnet-gateway create*' ([ordered]@{ vnetGateway = [ordered]@{ provisioningState = 'Succeeded' } })
        # The address exists after it is created.
        Add-AzRoute 'network public-ip create*' ([ordered]@{ publicIp = [ordered]@{ ipAddress = '203.0.113.10' } })
    }

    Context 'creating the gateway (happy path)' {
        It 'creates a Standard static public IP address without zones and the gateway, from the file' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            Get-AzCall "network public-ip create --name vpng-hub-01-pip --resource-group rg-conn-01 --location westus2 --subscription $($global:AzlVpnSub) --sku Standard --allocation-method Static" | Should -HaveCount 1
            Get-AzCall 'network public-ip create *--zone*' | Should -HaveCount 0
            Get-AzCall "network vnet-gateway create --name vpng-hub-01 --resource-group rg-conn-01 --location westus2 --subscription $($global:AzlVpnSub) --vnet /vnets/vnet-hub-01 --public-ip-address vpng-hub-01-pip --gateway-type Vpn --vpn-type RouteBased --sku VpnGw2AZ --vpn-gateway-generation Generation2 --asn 65010" | Should -HaveCount 1
        }

        It 'reads the network in its own group and the gateway state from the answer' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall 'network vnet show --name vnet-hub-01 --resource-group rg-net-01*' | Should -HaveCount 1
            $r.Rows[0].ProvisioningState | Should -Be 'Succeeded'
        }

        It 'reports the public IP address of the gateway after it is created' {
            Add-AzRoute 'network public-ip show*' { [ordered]@{ ipAddress = '203.0.113.10' } | ConvertTo-Json -Compress }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.Rows[0].PublicIpAddress | Should -Be '203.0.113.10'
            $r.Text | Should -Match 'Gateway public IP address: 203\.0\.113\.10'
        }

        It 'works in the subscription of the network and never changes the subscription of the az session' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall "network vnet-gateway create*--subscription $($global:AzlVpnSub)*" | Should -HaveCount 1
            Get-AzCall 'account set*' | Should -BeNullOrEmpty
        }

        It 'puts the file-level tags on both resources, and sends no tags when the file has none' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Tags ([ordered]@{ environment = 'lab'; owner = 'team' }))
            Get-AzCall 'network public-ip create*--tags environment=lab owner=team' | Should -HaveCount 1
            Get-AzCall 'network vnet-gateway create*--tags environment=lab owner=team' | Should -HaveCount 1
            Initialize-AzFake
            Add-AzRoute 'network vnet show*' (New-FakeVnet)
            $null = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall '*--tags*' | Should -BeNullOrEmpty
        }

        It 'VpnGw1AZ is Generation1 and VpnGw2AZ and above are Generation2: <Sku>' -ForEach @(
            @{ Sku = 'VpnGw1AZ'; Generation = 'Generation1' }, @{ Sku = 'VpnGw2AZ'; Generation = 'Generation2' }, @{ Sku = 'VpnGw3AZ'; Generation = 'Generation2' }, @{ Sku = 'VpnGw5AZ'; Generation = 'Generation2' }
        ) {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Gateway (New-Gateway @{ sku = $Sku }))
            Get-AzCall "network vnet-gateway create*--sku $Sku --vpn-gateway-generation $Generation --asn 65010" | Should -HaveCount 1
        }

        It 'uses the resource group of the network when the gateway names none, and azure.location when the network has none' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Gateway (New-Gateway @{ resource_group = $null }) -Network (New-Network @{ location = $null }))
            Get-AzCall 'network vnet-gateway create --name vpng-hub-01 --resource-group rg-net-01 --location eastus*' | Should -HaveCount 1
        }

        It 'accepts the Azure default ASN 65515 for the gateway' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Gateway (New-Gateway @{ bgp_asn = 65515 }))
            $r.ExitCode | Should -Be 0
            Get-AzCall 'network vnet-gateway create*--asn 65515' | Should -HaveCount 1
        }

        It 'reuses a public IP address that is already there and creates only the gateway' {
            Add-AzRoute 'network public-ip show*' ([ordered]@{ name = 'vpng-hub-01-pip'; ipAddress = '203.0.113.11' })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            Get-AzCall 'network public-ip create*' | Should -BeNullOrEmpty
            Get-AzCall 'network vnet-gateway create*' | Should -HaveCount 1
        }
    }

    Context 'the gateway already exists (idempotent)' {
        BeforeEach {
            Add-AzRoute 'network vnet-gateway show*' ([ordered]@{ name = 'vpng-hub-01'; provisioningState = 'Succeeded'; sku = [ordered]@{ name = 'VpnGw2AZ' }; bgpSettings = [ordered]@{ asn = 65010 } })
            Add-AzRoute 'network public-ip show*' ([ordered]@{ name = 'vpng-hub-01-pip'; ipAddress = '203.0.113.12' })
        }

        It 'creates nothing and reports the public IP address' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].PublicIpAddress | Should -Be '203.0.113.12'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'warns, and still changes nothing, when the SKU or the ASN differs from the file' {
            Add-AzRoute 'network vnet-gateway show*' ([ordered]@{ name = 'vpng-hub-01'; provisioningState = 'Succeeded'; sku = [ordered]@{ name = 'VpnGw1AZ' }; bgpSettings = [ordered]@{ asn = 65099 } })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Detail | Should -Match 'SKU is VpnGw1AZ, the file says VpnGw2AZ'
            $r.Rows[0].Detail | Should -Match 'BGP ASN is 65099, the file says 65010'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'warns when the gateway is not in the Succeeded state' {
            Add-AzRoute 'network vnet-gateway show*' ([ordered]@{ name = 'vpng-hub-01'; provisioningState = 'Updating'; sku = [ordered]@{ name = 'VpnGw2AZ' }; bgpSettings = [ordered]@{ asn = 65010 } })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.Text | Should -Match "provisioning state is 'Updating'"
            Get-AzWriteCall | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf' {
        It 'plans the public IP address and the gateway and creates neither' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'vpngw.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'refuses a file without landing_zone.connectivity.vpn_gateway' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Gateway $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'vpn_gateway is missing'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a missing name'; Gateway = @{ name = $null }; Network = @{}; Match = 'vpn_gateway.name is missing' }
            @{ Case = 'a missing network'; Gateway = @{ network = $null }; Network = @{}; Match = 'vpn_gateway.network is missing' }
            @{ Case = 'a gateway name Azure does not accept'; Gateway = @{ name = 'bad name!' }; Network = @{}; Match = 'is not a valid name' }
            @{ Case = 'a SKU that is not of the AZ family'; Gateway = @{ sku = 'VpnGw1' }; Network = @{}; Match = 'missing or not allowed' }
            @{ Case = 'a missing SKU'; Gateway = @{ sku = $null }; Network = @{}; Match = 'missing or not allowed' }
            @{ Case = 'an ASN Azure reserves'; Gateway = @{ bgp_asn = 8075 }; Network = @{}; Match = 'reserved by Azure or IANA' }
            @{ Case = 'an ASN IANA reserves'; Gateway = @{ bgp_asn = 64500 }; Network = @{}; Match = 'reserved by Azure or IANA' }
            @{ Case = 'the largest ASN, which is reserved'; Gateway = @{ bgp_asn = 4294967295 }; Network = @{}; Match = 'reserved by Azure or IANA' }
            @{ Case = 'an ASN of zero'; Gateway = @{ bgp_asn = 0 }; Network = @{}; Match = 'not a number from 1 to 4294967295' }
            @{ Case = 'an ASN that is not a number'; Gateway = @{ bgp_asn = 'abc' }; Network = @{}; Match = 'not a number from 1 to 4294967295' }
            @{ Case = 'an ASN above the range'; Gateway = @{ bgp_asn = 4294967296 }; Network = @{}; Match = 'not a number from 1 to 4294967295' }
            @{ Case = 'a network that is not an entry of landing_zone.networks'; Gateway = @{ network = 'vnet-nowhere' }; Network = @{}; Match = 'not an entry of landing_zone.networks' }
            @{ Case = 'a network with no subscription'; Gateway = @{}; Network = @{ subscription = $null }; Match = 'has no subscription' }
            @{ Case = 'a subscription that has no id'; Gateway = @{}; Network = @{ subscription = 'sub-unknown' }; Match = 'no usable id' }
            @{ Case = 'a network with no resource group'; Gateway = @{}; Network = @{ resource_group = $null }; Match = 'no resource_group' }
        ) {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Gateway (New-Gateway $Gateway) -Network (New-Network $Network))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses the all-zero subscription, and a file with no region anywhere' {
            $zero = @([ordered]@{ name = 'sub-connectivity'; id = [guid]::Empty.ToString(); role = 'connectivity' })
            (Invoke-AzCliScript $script:Script (New-InfraFile -Subscriptions $zero)).Text | Should -Match 'no usable id'
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Network (New-Network @{ location = $null }) -Location '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'No region'
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-AzCliScript $script:Script (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when az is not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Azure CLI \(az\) was not found'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'stops when nobody is signed in' {
            Add-AzRoute 'account show*' 'ERROR: Please run ''az login'' to setup account.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the sign-in is to another tenant' {
            Add-AzRoute 'account show*' ([guid]::NewGuid().ToString())
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the virtual network does not exist, and creates nothing' {
            Add-AzNotFound 'network vnet show*'
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Create it first'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the network has no GatewaySubnet' {
            Add-AzRoute 'network vnet show*' (New-FakeVnet @([ordered]@{ name = 'snet-shared'; addressPrefix = '198.51.100.32/27' }))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'no subnet named GatewaySubnet'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the GatewaySubnet is smaller than /27' {
            Add-AzRoute 'network vnet show*' (New-FakeVnet @([ordered]@{ name = 'GatewaySubnet'; addressPrefix = '198.51.100.0/28' }))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'recommends /27 or larger'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports a gateway creation that fails and exits 1' {
            Add-AzRoute 'network vnet-gateway create*' 'ERROR: (VmSkuNotSupported) The SKU is not supported.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'VmSkuNotSupported'
        }

        It 'does not create the gateway when the public IP address cannot be created' {
            Add-AzRoute 'network public-ip create*' 'ERROR: (PublicIPCountLimitReached) Cannot create more public IP addresses.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Get-AzCall 'network vnet-gateway create*' | Should -BeNullOrEmpty
        }

        It 'does not hide a read error that is not a not-found' {
            Add-AzRoute 'network vnet-gateway show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, never variables.yml, and holds no GUID' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter registered' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($p in 'InfrastructureFile', 'LogPath') {
                ($registry -match ('Deploy_VpnGateway_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
