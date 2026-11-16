#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 01: Deploy-VirtualNetworks.azcli.ps1 creates the virtual networks, subnets and
# peerings of landing_zone.networks with az commands. "az" is mocked: no Azure, no tenant and no sign-in is used. Ids are generated per run; the address
# ranges and DNS servers are documentation values (RFC 5737).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/VirtualNetworks.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-01-virtual-network', 'azurecli', 'Deploy-VirtualNetworks.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlVnetSubHub = [guid]::NewGuid().ToString()
    $global:AzlVnetSubMgmt = [guid]::NewGuid().ToString()

    function New-Subnet([string]$Name, [string]$Prefix, [string]$Nsg, [string]$RouteTable) {
        $s = [ordered]@{ name = $Name; prefix = $Prefix }
        if ($Nsg) { $s.network_security_group = $Nsg }
        if ($RouteTable) { $s.route_table = $RouteTable }
        $s
    }
    function New-Hub([hashtable]$Override = @{}) {
        Set-AzOverride ([ordered]@{
                name = 'vnet-hub-01'; subscription = 'sub-connectivity'; resource_group = 'rg-conn-01'; location = 'eastus'; role = 'hub'
                address_space = @('198.51.100.0/24'); dns_servers = @('192.0.2.4', '192.0.2.5')
                subnets = @((New-Subnet 'GatewaySubnet' '198.51.100.0/27'), (New-Subnet 'snet-shared' '198.51.100.32/27'))
            }) $Override
    }
    function New-Spoke([hashtable]$Override = @{}) {
        Set-AzOverride ([ordered]@{
                name = 'vnet-mgmt-01'; subscription = 'sub-management'; resource_group = 'rg-mgmt-01'; location = 'eastus'; role = 'spoke'
                address_space = @('203.0.113.0/24'); subnets = @((New-Subnet 'snet-mgmt' '203.0.113.0/26' 'nsg-mgmt')); peer_with = @('vnet-hub-01')
            }) $Override
    }
    function New-InfraFile {
        param([object]$Networks = @((New-Hub), (New-Spoke)), [object]$TenantId = $global:AzlFakeTenant, [string]$Location = 'eastus', [object]$Tags = $null, [object]$Subscriptions = $null)
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($Location) { $doc.azure.location = $Location }
        if ($Tags) { $doc.tags = $Tags }
        $lz = [ordered]@{}
        $lz.subscriptions = if ($null -ne $Subscriptions) { @($Subscriptions) } else {
            @([ordered]@{ name = 'sub-connectivity'; id = $global:AzlVnetSubHub; role = 'connectivity' }, [ordered]@{ name = 'sub-management'; id = $global:AzlVnetSubMgmt; role = 'management' })
        }
        if ($null -ne $Networks) { $lz.networks = @($Networks) }
        $doc.landing_zone = $lz
        Save-AzInfraFile $doc
    }

    # An existing network and subnet as az returns them.
    function New-Existing([string]$Name, [string[]]$Space, [object[]]$Subnets, [string[]]$Dns = @()) {
        [ordered]@{ name = $Name; id = "/vnets/$Name"; addressSpace = [ordered]@{ addressPrefixes = $Space }; dhcpOptions = [ordered]@{ dnsServers = $Dns }; subnets = @($Subnets) }
    }
    function New-ExistingSubnet([string]$Name, [string]$Prefix, [string]$NsgId, [string]$RouteTableId) {
        $s = [ordered]@{ name = $Name; addressPrefix = $Prefix }
        if ($NsgId) { $s.networkSecurityGroup = [ordered]@{ id = $NsgId } }
        if ($RouteTableId) { $s.routeTable = [ordered]@{ id = $RouteTableId } }
        $s
    }
    # The peering list of a network of the default file: its peering to the other one (named as the script names it unless -Name says otherwise).
    function New-ExistingPeeringList([string]$Network, [string]$State, [string]$Name) {
        $remote = if ($Network -eq 'vnet-hub-01') { 'vnet-mgmt-01' } else { 'vnet-hub-01' }
        ConvertTo-Json -InputObject @([ordered]@{ name = $(if ($Name) { $Name } else { "peer-$Network-to-$remote" }); remoteVirtualNetwork = [ordered]@{ id = "/vnets/$remote" }; peeringState = $State }) -Depth 5 -Compress
    }
    # The routes of a landing zone whose networks all exist.
    function Add-ExistingRoute([switch]$HubLacksSharedSubnet, [object]$MgmtSubnet = (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26' '/nsgs/nsg-mgmt'), [string[]]$HubDns = @('192.0.2.4', '192.0.2.5'), [string[]]$HubSpace = @('198.51.100.0/24'), [string]$GatewayPrefix = '198.51.100.0/27') {
        $hubSubnets = @((New-ExistingSubnet 'GatewaySubnet' $GatewayPrefix))
        if (-not $HubLacksSharedSubnet) { $hubSubnets += (New-ExistingSubnet 'snet-shared' '198.51.100.32/27') }
        Add-AzRoute 'network vnet show --name vnet-hub-01*' (New-Existing 'vnet-hub-01' $HubSpace $hubSubnets $HubDns)
        Add-AzRoute 'network vnet show --name vnet-mgmt-01*' (New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, $MgmtSubnet))
    }
}

Describe 'Deploy-VirtualNetworks.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlVnetSubHub, AzlVnetSubMgmt, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
        # "az network vnet create" answers with the new network under newVNet. Groups and route tables exist.
        Add-AzRoute 'network vnet create*' { $i = [array]::IndexOf($args, '--name'); ([ordered]@{ newVNet = [ordered]@{ id = "/vnets/$($args[$i + 1])" } } | ConvertTo-Json -Compress) }
        Add-AzRoute 'network nsg show*' { $i = [array]::IndexOf($args, '--name'); ([ordered]@{ id = "/nsgs/$($args[$i + 1])" } | ConvertTo-Json -Compress) }
        Add-AzRoute 'network route-table show*' { $i = [array]::IndexOf($args, '--name'); ([ordered]@{ id = "/routetables/$($args[$i + 1])" } | ConvertTo-Json -Compress) }
        # A network has no peering until a test says otherwise.
        Add-AzRoute 'network vnet peering list*' '[]'
    }

    Context 'creating the networks (happy path)' {
        It 'creates each network with its address space and DNS servers, in its group and region, then each subnet' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].NetworksCreated | Should -Be 2
            Get-AzCall "network vnet create --name vnet-hub-01 --resource-group rg-conn-01 --location eastus --subscription $($global:AzlVnetSubHub) --address-prefixes 198.51.100.0/24 --dns-servers 192.0.2.4 192.0.2.5" | Should -HaveCount 1
            Get-AzCall "network vnet create --name vnet-mgmt-01 --resource-group rg-mgmt-01 --location eastus --subscription $($global:AzlVnetSubMgmt) --address-prefixes 203.0.113.0/24" | Should -HaveCount 1
            Get-AzCall 'network vnet subnet create*' | Should -HaveCount 3
            Get-AzCall "network vnet subnet create --name GatewaySubnet --vnet-name vnet-hub-01 --resource-group rg-conn-01 --subscription $($global:AzlVnetSubHub) --address-prefixes 198.51.100.0/27" | Should -HaveCount 1
        }

        It 'works in the subscription of each network and never changes the subscription of the az session' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall "network vnet create*--subscription $($global:AzlVnetSubHub)*" | Should -HaveCount 1
            Get-AzCall "network vnet create*--subscription $($global:AzlVnetSubMgmt)*" | Should -HaveCount 1
            Get-AzCall 'account set*' | Should -BeNullOrEmpty
        }

        It 'attaches the network security group and the route table a subnet names when they exist' {
            $file = New-InfraFile @((New-Hub), (New-Spoke @{ subnets = @(, (New-Subnet 'snet-mgmt' '203.0.113.0/26' 'nsg-mgmt' 'rt-mgmt')) }))
            $null = Invoke-AzCliScript $script:Script $file
            Get-AzCall 'network vnet subnet create --name snet-mgmt*--network-security-group /nsgs/nsg-mgmt --route-table /routetables/rt-mgmt' | Should -HaveCount 1
            Get-AzCall 'network nsg show --name nsg-mgmt --resource-group rg-mgmt-01*' | Should -HaveCount 1
        }

        It 'creates the subnet without a group that does not exist yet, and says to run the script again' {
            Add-AzNotFound 'network nsg show*'
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].NetworksCreated | Should -Be 2
            Get-AzCall 'network vnet subnet create --name snet-mgmt*' | Should -HaveCount 1
            Get-AzCall 'network vnet subnet create --name snet-mgmt*--network-security-group*' | Should -BeNullOrEmpty
            $r.Text | Should -Match 'Not attached yet, the resource does not exist: nsg-mgmt'
        }

        It 'puts the file-level tags on the networks' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Tags ([ordered]@{ environment = 'lab'; owner = 'team' }))
            Get-AzCall 'network vnet create*--tags environment=lab owner=team' | Should -HaveCount 2
        }

        It 'uses azure.location when a network has none' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile @((New-Hub @{ location = $null }), (New-Spoke @{ location = $null })) -Location 'westus2')
            Get-AzCall 'network vnet create*--location westus2*' | Should -HaveCount 2
        }

        It 'creates a network that has no subnets' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile @(, (New-Hub @{ subnets = $null; peer_with = $null })))
            $r.ExitCode | Should -Be 0
            Get-AzCall 'network vnet create*' | Should -HaveCount 1
            Get-AzCall 'network vnet subnet create*' | Should -BeNullOrEmpty
        }

        It 'peers the networks that list each other, in both directions, with forwarded traffic allowed and no gateway transit by default' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.Rows[0].PeeringsCreated | Should -Be 2
            Get-AzCall "network vnet peering create --name peer-vnet-mgmt-01-to-vnet-hub-01 --vnet-name vnet-mgmt-01 --resource-group rg-mgmt-01 --subscription $($global:AzlVnetSubMgmt) --remote-vnet /vnets/vnet-hub-01 --allow-vnet-access true --allow-forwarded-traffic true --allow-gateway-transit false --use-remote-gateways false" | Should -HaveCount 1
            Get-AzCall "network vnet peering create --name peer-vnet-hub-01-to-vnet-mgmt-01 --vnet-name vnet-hub-01 --resource-group rg-conn-01 --subscription $($global:AzlVnetSubHub) --remote-vnet /vnets/vnet-mgmt-01 --allow-vnet-access true --allow-forwarded-traffic true --allow-gateway-transit false --use-remote-gateways false" | Should -HaveCount 1
        }

        It 'gives each direction the options of the network it starts in: gateway transit on the hub, remote gateways on the spoke' {
            $file = New-InfraFile @((New-Hub @{ allow_gateway_transit = $true }), (New-Spoke @{ use_remote_gateways = $true; allow_forwarded_traffic = $false }))
            $r = Invoke-AzCliScript $script:Script $file
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-AzCall 'network vnet peering create --name peer-vnet-hub-01-to-vnet-mgmt-01*--allow-forwarded-traffic true --allow-gateway-transit true --use-remote-gateways false' | Should -HaveCount 1
            Get-AzCall 'network vnet peering create --name peer-vnet-mgmt-01-to-vnet-hub-01*--allow-forwarded-traffic false --allow-gateway-transit false --use-remote-gateways true' | Should -HaveCount 1
        }

        It 'stops with exit code 2 and creates nothing when use_remote_gateways has no peer that offers its gateway' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile @((New-Hub), (New-Spoke @{ use_remote_gateways = $true })))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'allow_gateway_transit'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'stops with exit code 2 when a network both offers and uses a gateway, or an option is not true or false' {
            (Invoke-AzCliScript $script:Script (New-InfraFile @((New-Hub @{ allow_gateway_transit = $true; use_remote_gateways = $true }), (New-Spoke)))).ExitCode | Should -Be 2
            $r = Invoke-AzCliScript $script:Script (New-InfraFile @((New-Hub), (New-Spoke @{ allow_forwarded_traffic = 'maybe' })))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'allow_forwarded_traffic'
        }

        It 'makes one pair of peerings when both networks list each other' {
            $file = New-InfraFile @((New-Hub @{ peer_with = @('vnet-mgmt-01') }), (New-Spoke))
            (Invoke-AzCliScript $script:Script $file).Rows[0].PeeringsCreated | Should -Be 2
        }

        It 'peers across subscriptions, each side in its own subscription' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall "network vnet peering list --vnet-name vnet-hub-01 --resource-group rg-conn-01 --subscription $($global:AzlVnetSubHub)" | Should -HaveCount 1
            Get-AzCall "network vnet peering list --vnet-name vnet-mgmt-01 --resource-group rg-mgmt-01 --subscription $($global:AzlVnetSubMgmt)" | Should -HaveCount 1
        }

        It 'a peering name stays within the 80 characters Azure allows' {
            $long = 'v' * 50
            $file = New-InfraFile @((New-Hub @{ name = $long; peer_with = $null }), (New-Spoke @{ name = ($long + 'x'); peer_with = @($long) }))
            $null = Invoke-AzCliScript $script:Script $file
            @(Get-AzCall 'network vnet peering create*' | ForEach-Object { ($_ -split ' ')[5] }).Count | Should -Be 2
            foreach ($call in Get-AzCall 'network vnet peering create*') { ($call -split ' ')[5].Length | Should -BeLessOrEqual 80; ($call -split ' ')[5] | Should -Match '^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9_]$' }
        }

        It 'cuts a long peering name so that it still ends with a letter or digit, and keeps two long names that start alike apart' {
            # Cut at 80 characters, the two peerings of the hub would both be "peer-hhh...-to-aaaaaaaaaa-": a name Azure refuses (it ends with a hyphen), and the same name twice.
            $hub = 'h' * 60; $a = ('a' * 10) + '-x'; $b = ('a' * 10) + '-y'
            $file = New-InfraFile @((New-Hub @{ name = $hub; peer_with = $null }), (New-Spoke @{ name = $a; peer_with = @($hub) }), (New-Spoke @{ name = $b; resource_group = 'rg-mgmt-02'; address_space = @('192.0.2.0/24'); subnets = $null; peer_with = @($hub) }))
            $r = Invoke-AzCliScript $script:Script $file
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $names = @(Get-AzCall 'network vnet peering create*' | ForEach-Object { ($_ -split ' ')[5] })
            $names.Count | Should -Be 4
            @($names | Select-Object -Unique).Count | Should -Be 4
            foreach ($n in $names) { $n.Length | Should -BeLessOrEqual 80; $n | Should -Match '^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9_]$' }
        }
    }

    Context 'the networks already exist (idempotent, additive)' {
        BeforeEach {
            Add-ExistingRoute
            Add-AzRoute 'network vnet peering list --vnet-name vnet-hub-01*' (New-ExistingPeeringList 'vnet-hub-01' 'Connected')
            Add-AzRoute 'network vnet peering list --vnet-name vnet-mgmt-01*' (New-ExistingPeeringList 'vnet-mgmt-01' 'Connected')
        }

        It 'creates and changes nothing and says so' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].NetworksExisting | Should -Be 2
            $r.Rows[0].NetworksCreated | Should -Be 0
            $r.Rows[0].PeeringsExisting | Should -Be 2
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'Nothing to do'
        }

        It 'adds a subnet the network lacks' {
            Add-ExistingRoute -HubLacksSharedSubnet
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].NetworksUpdated | Should -Be 1
            Get-AzCall "network vnet subnet create --name snet-shared --vnet-name vnet-hub-01 --resource-group rg-conn-01 --subscription $($global:AzlVnetSubHub) --address-prefixes 198.51.100.32/27" | Should -HaveCount 1
            Get-AzCall 'network vnet create*' | Should -BeNullOrEmpty
        }

        It 'attaches a network security group to a subnet that has none, once the group exists, and updates only that subnet' {
            Add-ExistingRoute -MgmtSubnet (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26')
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.Rows[0].NetworksUpdated | Should -Be 1
            Get-AzCall "network vnet subnet update --name snet-mgmt --vnet-name vnet-mgmt-01 --resource-group rg-mgmt-01 --subscription $($global:AzlVnetSubMgmt) --network-security-group /nsgs/nsg-mgmt" | Should -HaveCount 1
            Get-AzCall 'network vnet subnet update*' | Should -HaveCount 1
        }

        It 'does not attach a group that still does not exist, and says so' {
            Add-AzNotFound 'network nsg show*'
            Add-ExistingRoute -MgmtSubnet (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26')
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            Get-AzCall 'network vnet subnet update*' | Should -BeNullOrEmpty
            $r.Text | Should -Match 'Not attached yet'
        }

        It 'reports a subnet range that differs and leaves it alone' {
            Add-ExistingRoute -GatewayPrefix '198.51.100.0/28'
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            ($r.Rows[0].Networks | Where-Object Network -EQ 'vnet-hub-01').Differences | Should -Match "subnet 'GatewaySubnet' is 198.51.100.0/28"
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports DNS servers and an address space that differ and leaves them alone' {
            Add-ExistingRoute -HubSpace @('198.51.100.0/25') -HubDns @('192.0.2.99')
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $diff = ($r.Rows[0].Networks | Where-Object Network -EQ 'vnet-hub-01').Differences -join '|'
            $diff | Should -Match 'address space lacks 198.51.100.0/24'
            $diff | Should -Match 'DNS servers are'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports another group attached to a subnet and does not replace it' {
            Add-ExistingRoute -MgmtSubnet (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26' '/nsgs/nsg-other')
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            ($r.Rows[0].Networks | Where-Object Network -EQ 'vnet-mgmt-01').Differences | Should -Match 'another NetworkSecurityGroup attached'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'creates the peering that is missing and leaves the one that exists' {
            Add-AzRoute 'network vnet peering list --vnet-name vnet-hub-01*' (New-ExistingPeeringList 'vnet-hub-01' 'Initiated')
            Add-AzRoute 'network vnet peering list --vnet-name vnet-mgmt-01*' '[]'
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.Rows[0].PeeringsCreated | Should -Be 1
            $r.Rows[0].PeeringsExisting | Should -Be 1
            Get-AzCall 'network vnet peering create --name peer-vnet-mgmt-01-to-vnet-hub-01*' | Should -HaveCount 1
        }

        It 'leaves a peering to the remote network that has another name, and makes no second one' {
            Add-AzRoute 'network vnet peering list --vnet-name vnet-hub-01*' (New-ExistingPeeringList 'vnet-hub-01' 'Connected' 'made-by-hand-hub')
            Add-AzRoute 'network vnet peering list --vnet-name vnet-mgmt-01*' (New-ExistingPeeringList 'vnet-mgmt-01' 'Connected' 'made-by-hand-mgmt')
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].PeeringsExisting | Should -Be 2
            Get-AzCall 'network vnet peering create*' | Should -BeNullOrEmpty
            ($r.Rows[0].Peerings | Where-Object Peering -EQ 'peer-vnet-hub-01-to-vnet-mgmt-01').Detail | Should -Match "exists as 'made-by-hand-hub'"
        }

        It 'does not take a peering to a third network for the one it needs' {
            Add-AzRoute 'network vnet peering list*' '[{"name":"peer-to-elsewhere","remoteVirtualNetwork":{"id":"/vnets/vnet-other"},"peeringState":"Connected"}]'
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.Rows[0].PeeringsCreated | Should -Be 2
        }

        It 'never removes anything' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match "'delete'|network vnet delete|subnet delete|peering delete"
        }
    }

    Context '-WhatIf' {
        It 'plans the networks and the peerings and creates nothing' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].NetworksPlanned | Should -Be 2
            $r.Rows[0].PeeringsPlanned | Should -Be 2
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would be created'
        }

        It 'plans a missing subnet of an existing network and changes nothing' {
            Add-ExistingRoute -HubLacksSharedSubnet
            Add-AzRoute 'network vnet peering list --vnet-name vnet-hub-01*' (New-ExistingPeeringList 'vnet-hub-01' 'Connected')
            Add-AzRoute 'network vnet peering list --vnet-name vnet-mgmt-01*' (New-ExistingPeeringList 'vnet-mgmt-01' 'Connected')
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            $r.Rows[0].NetworksPlanned | Should -Be 1
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would add snet-shared'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'vnet.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'refuses a file without landing_zone.networks' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Networks $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'landing_zone.networks is empty'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a network with no name'; Override = @{ name = $null }; Match = 'has no name' }
            @{ Case = 'a network name Azure does not accept'; Override = @{ name = 'bad name!' }; Match = 'not a valid virtual network name' }
            @{ Case = 'a network with no subscription'; Override = @{ subscription = $null }; Match = 'no subscription' }
            @{ Case = 'a subscription that is not in the file'; Override = @{ subscription = 'sub-unknown' }; Match = 'no usable id' }
            @{ Case = 'a network with no resource group'; Override = @{ resource_group = $null }; Match = 'no resource_group' }
            @{ Case = 'an empty address space'; Override = @{ address_space = @() }; Match = 'address_space is empty' }
            @{ Case = 'an address space that is not CIDR'; Override = @{ address_space = @('198.51.100.0') }; Match = 'not an IPv4 range in CIDR form' }
            @{ Case = 'a prefix length above 32'; Override = @{ address_space = @('198.51.100.0/33') }; Match = 'not an IPv4 range in CIDR form' }
            @{ Case = 'an octet above 255'; Override = @{ address_space = @('198.51.300.0/24') }; Match = 'not an IPv4 range in CIDR form' }
            @{ Case = 'a DNS server that is not an IPv4 address'; Override = @{ dns_servers = @('dns.example.test') }; Match = 'not an IPv4 address' }
            @{ Case = 'a subnet outside the address space'; Override = @{ subnets = @(, ([ordered]@{ name = 'snet-x'; prefix = '203.0.113.0/26' })) }; Match = 'outside the address space' }
            @{ Case = 'a subnet with a prefix that is not CIDR'; Override = @{ subnets = @(, ([ordered]@{ name = 'snet-x'; prefix = 'nowhere' })) }; Match = 'not an IPv4 range in CIDR form' }
            @{ Case = 'a subnet with no name'; Override = @{ subnets = @(, ([ordered]@{ name = ''; prefix = '198.51.100.0/27' })) }; Match = 'a subnet has no name' }
            @{ Case = 'overlapping subnets'; Override = @{ subnets = @(([ordered]@{ name = 'snet-a'; prefix = '198.51.100.0/26' }), ([ordered]@{ name = 'snet-b'; prefix = '198.51.100.32/27' })) }; Match = 'overlap' }
            @{ Case = 'the same subnet twice'; Override = @{ subnets = @(([ordered]@{ name = 'snet-a'; prefix = '198.51.100.0/27' }), ([ordered]@{ name = 'SNET-A'; prefix = '198.51.100.32/27' })) }; Match = 'more than once' }
            @{ Case = 'a peer that is not in the file'; Override = @{ peer_with = @('vnet-nowhere') }; Match = 'not an entry of landing_zone.networks' }
            @{ Case = 'a network that peers with itself'; Override = @{ peer_with = @('vnet-hub-01') }; Match = 'the network itself' }
        ) {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile @((New-Hub $Override)))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses a subscription whose id is the all-zero placeholder' {
            $subs = @([ordered]@{ name = 'sub-connectivity'; id = [guid]::Empty.ToString(); role = 'connectivity' })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile @(, (New-Hub @{ peer_with = $null })) -Subscriptions $subs)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no usable id'
        }

        It 'refuses a network with no location anywhere' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile @(, (New-Hub @{ location = $null })) -Location '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no location'
        }

        It 'refuses the same network twice' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile @((New-Hub), (New-Hub)))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'more than once'
        }

        It 'accepts subnets that fill the address space exactly and a /32 at the edge' {
            $hub = New-Hub @{ address_space = @('198.51.100.0/24'); subnets = @((New-Subnet 'snet-a' '198.51.100.0/25'), (New-Subnet 'snet-b' '198.51.100.128/26'), (New-Subnet 'snet-c' '198.51.100.255/32')) }
            (Invoke-AzCliScript $script:Script (New-InfraFile @(, $hub))).ExitCode | Should -Be 0
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

        It 'reports a network that cannot be created, still creates the other, and skips the peerings of the failed one' {
            Add-AzRoute 'network vnet create --name vnet-hub-01*' 'ERROR: (QuotaExceeded) Quota exceeded.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].NetworksFailed | Should -Be 1
            $r.Rows[0].NetworksCreated | Should -Be 1
            ($r.Rows[0].Networks | Where-Object Action -EQ 'Failed').Detail | Should -Match 'QuotaExceeded'
            Get-AzCall 'network vnet peering create*' | Should -BeNullOrEmpty
            @($r.Rows[0].Peerings | Where-Object Action -EQ 'Skipped').Count | Should -Be 2
        }

        It 'does not hide a network lookup error that is not a not-found' {
            Add-AzRoute 'network vnet show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].NetworksFailed | Should -Be 2
            Get-AzCall 'network vnet create*' | Should -BeNullOrEmpty
        }

        It 'does not hide a group lookup error that is not a not-found' {
            Add-AzRoute 'network nsg show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            ($r.Rows[0].Networks | Where-Object Network -EQ 'vnet-mgmt-01').Detail | Should -Match 'authorization'
            Get-AzCall 'network vnet create --name vnet-mgmt-01*' | Should -BeNullOrEmpty
        }

        It 'reports a failed peering and exits 1' {
            Add-AzRoute 'network vnet peering create --name peer-vnet-mgmt-01*' 'ERROR: (RemoteVnetNotAccessible) The remote network is not accessible.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].PeeringsFailed | Should -Be 1
            $r.Rows[0].PeeringsCreated | Should -Be 1
            ($r.Rows[0].Peerings | Where-Object Action -EQ 'Failed').Detail | Should -Match 'RemoteVnetNotAccessible'
        }

        It 'does not hide a peering lookup error that is not a not-found' {
            Add-AzRoute 'network vnet peering list*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].PeeringsFailed | Should -Be 2
            Get-AzCall 'network vnet peering create*' | Should -BeNullOrEmpty
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

        It 'holds no IP address other than documentation ranges in its help text' {
            $addresses = [regex]::Matches($script:Text, '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b') | ForEach-Object { $_.Value } | Select-Object -Unique
            @($addresses | Where-Object { $_ -notmatch '^(192\.0\.2|198\.51\.100|203\.0\.113)\.' }) | Should -BeNullOrEmpty
        }

        It 'has every parameter registered' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($p in 'InfrastructureFile', 'LogPath') {
                ($registry -match ('Deploy_VirtualNetworks_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
