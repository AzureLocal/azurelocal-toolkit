#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 01: Deploy-VirtualNetworks.ps1 creates the virtual networks, subnets and peerings of
# landing_zone.networks. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids are generated per run; the address ranges and DNS servers
# are documentation values (RFC 5737).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/VirtualNetworks.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-01-virtual-network', 'powershell', 'Deploy-VirtualNetworks.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzVirtualNetwork { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzVirtualNetwork { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string[]]$AddressPrefix, [object[]]$Subnet, [string[]]$DnsServer, [hashtable]$Tag, [switch]$Force) }
    function New-AzVirtualNetworkSubnetConfig { [CmdletBinding()] param([string]$Name, [string]$AddressPrefix, [object]$NetworkSecurityGroup, [object]$RouteTable) }
    function Add-AzVirtualNetworkSubnetConfig { [CmdletBinding()] param([string]$Name, [string]$AddressPrefix, [object]$VirtualNetwork, [object]$NetworkSecurityGroup, [object]$RouteTable) }
    function Set-AzVirtualNetworkSubnetConfig { [CmdletBinding()] param([string]$Name, [string]$AddressPrefix, [object]$VirtualNetwork, [object]$NetworkSecurityGroup, [object]$RouteTable) }
    function Set-AzVirtualNetwork { [CmdletBinding()] param([object]$VirtualNetwork) }
    function Get-AzNetworkSecurityGroup { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzRouteTable { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzVirtualNetworkPeering { [CmdletBinding()] param([string]$ResourceGroupName, [string]$VirtualNetworkName, [string]$Name) }
    function Add-AzVirtualNetworkPeering { [CmdletBinding()] param([string]$Name, [object]$VirtualNetwork, [string]$RemoteVirtualNetworkId, [switch]$AllowForwardedTraffic) }

    $global:AzlVnetTestTenant = [guid]::NewGuid().ToString()
    $global:AzlVnetTestSubHub = [guid]::NewGuid().ToString()
    $global:AzlVnetTestSubMgmt = [guid]::NewGuid().ToString()
    $global:AzlVnetTestHome = [guid]::NewGuid().ToString()

    function New-Subnet([string]$Name, [string]$Prefix, [string]$Nsg, [string]$RouteTable) {
        $s = [ordered]@{ name = $Name; prefix = $Prefix }
        if ($Nsg) { $s.network_security_group = $Nsg }
        if ($RouteTable) { $s.route_table = $RouteTable }
        $s
    }
    function New-Hub([hashtable]$Override = @{}) {
        $n = [ordered]@{
            name = 'vnet-hub-01'; subscription = 'sub-connectivity'; resource_group = 'rg-conn-01'; location = 'eastus'; role = 'hub'
            address_space = @('198.51.100.0/24'); dns_servers = @('192.0.2.4', '192.0.2.5')
            subnets = @((New-Subnet 'GatewaySubnet' '198.51.100.0/27'), (New-Subnet 'snet-shared' '198.51.100.32/27'))
        }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $n.Remove($k) } else { $n[$k] = $Override[$k] } }
        $n
    }
    function New-Spoke([hashtable]$Override = @{}) {
        $n = [ordered]@{
            name = 'vnet-mgmt-01'; subscription = 'sub-management'; resource_group = 'rg-mgmt-01'; location = 'eastus'; role = 'spoke'
            address_space = @('203.0.113.0/24'); subnets = @((New-Subnet 'snet-mgmt' '203.0.113.0/26' 'nsg-mgmt')); peer_with = @('vnet-hub-01')
        }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $n.Remove($k) } else { $n[$k] = $Override[$k] } }
        $n
    }
    function New-InfraFile {
        param([object]$Networks = @((New-Hub), (New-Spoke)), [object]$TenantId = $global:AzlVnetTestTenant, [string]$Location = 'eastus', [object]$Tags = $null, [object]$Subscriptions = $null)
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($Location) { $doc.azure.location = $Location }
        if ($Tags) { $doc.tags = $Tags }
        $lz = [ordered]@{}
        $lz.subscriptions = if ($null -ne $Subscriptions) { @($Subscriptions) } else {
            @([ordered]@{ name = 'sub-connectivity'; id = $global:AzlVnetTestSubHub; role = 'connectivity' }, [ordered]@{ name = 'sub-management'; id = $global:AzlVnetTestSubMgmt; role = 'management' })
        }
        if ($null -ne $Networks) { $lz.networks = @($Networks) }
        $doc.landing_zone = $lz
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }

    # An existing network as Azure returns it.
    function New-Existing([string]$Name, [string[]]$Space, [object[]]$Subnets, [string[]]$Dns = @()) {
        [pscustomobject]@{
            Name = $Name; Id = "/vnets/$Name"; AddressSpace = [pscustomobject]@{ AddressPrefixes = $Space }
            DhcpOptions = [pscustomobject]@{ DnsServers = $Dns }; Subnets = @($Subnets)
        }
    }
    function New-ExistingSubnet([string]$Name, [string]$Prefix, [string]$NsgId, [string]$RouteTableId) {
        [pscustomobject]@{
            Name = $Name; AddressPrefix = @($Prefix)
            NetworkSecurityGroup = $(if ($NsgId) { [pscustomobject]@{ Id = $NsgId } })
            RouteTable = $(if ($RouteTableId) { [pscustomobject]@{ Id = $RouteTableId } })
        }
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Vnet([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['NetworksCreated'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Deploy-VirtualNetworks.ps1' {
    AfterAll {
        Remove-Variable -Name AzlVnetTestTenant, AzlVnetTestSubHub, AzlVnetTestSubMgmt, AzlVnetTestHome -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlVnetTestTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlVnetTestHome } } }
        Mock Set-AzContext { }
        Mock Get-AzVirtualNetwork { throw 'Resource not found (404 NotFound).' }
        Mock New-AzVirtualNetwork { [pscustomobject]@{ Name = $Name; Id = "/vnets/$Name"; Subnets = @() } }
        Mock New-AzVirtualNetworkSubnetConfig { [pscustomobject]@{ Name = $Name; AddressPrefix = $AddressPrefix; NetworkSecurityGroup = $NetworkSecurityGroup; RouteTable = $RouteTable } }
        Mock Add-AzVirtualNetworkSubnetConfig { $VirtualNetwork }
        Mock Set-AzVirtualNetworkSubnetConfig { $VirtualNetwork }
        Mock Set-AzVirtualNetwork { $VirtualNetwork }
        Mock Get-AzNetworkSecurityGroup { [pscustomobject]@{ Name = $Name; Id = "/nsgs/$Name" } }
        Mock Get-AzRouteTable { [pscustomobject]@{ Name = $Name; Id = "/routetables/$Name" } }
        Mock Get-AzVirtualNetworkPeering { throw 'Peering not found (404 NotFound).' }
        Mock Add-AzVirtualNetworkPeering { [pscustomobject]@{ Name = $Name } }
    }

    Context 'creating the networks (happy path)' {
        It 'creates each network with its address space, DNS servers and subnets, in its resource group and region' {
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Result.NetworksCreated | Should -Be 2
            Should -Invoke New-AzVirtualNetwork -Times 1 -Exactly -ParameterFilter { $Name -eq 'vnet-hub-01' -and $ResourceGroupName -eq 'rg-conn-01' -and $Location -eq 'eastus' -and ($AddressPrefix -join ',') -eq '198.51.100.0/24' -and ($DnsServer -join ',') -eq '192.0.2.4,192.0.2.5' -and @($Subnet).Count -eq 2 }
            Should -Invoke New-AzVirtualNetwork -Times 1 -Exactly -ParameterFilter { $Name -eq 'vnet-mgmt-01' -and $ResourceGroupName -eq 'rg-mgmt-01' -and @($Subnet).Count -eq 1 -and -not $DnsServer }
            Should -Invoke New-AzVirtualNetworkSubnetConfig -Times 3 -Exactly
        }

        It 'works in the subscription of each network and puts the original subscription back' {
            $null = Invoke-Vnet (New-InfraFile)
            Should -Invoke Set-AzContext -Times 1 -ParameterFilter { $SubscriptionId -eq $global:AzlVnetTestSubHub }
            Should -Invoke Set-AzContext -Times 1 -ParameterFilter { $SubscriptionId -eq $global:AzlVnetTestSubMgmt }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVnetTestHome }
        }

        It 'attaches the network security group and the route table a subnet names when they exist' {
            $file = New-InfraFile @((New-Hub), (New-Spoke @{ subnets = @(, (New-Subnet 'snet-mgmt' '203.0.113.0/26' 'nsg-mgmt' 'rt-mgmt')) }))
            $null = Invoke-Vnet $file
            Should -Invoke New-AzVirtualNetworkSubnetConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'snet-mgmt' -and $NetworkSecurityGroup.Id -eq '/nsgs/nsg-mgmt' -and $RouteTable.Id -eq '/routetables/rt-mgmt' }
            Should -Invoke Get-AzNetworkSecurityGroup -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-mgmt-01' -and $Name -eq 'nsg-mgmt' }
        }

        It 'creates the subnet without a group that does not exist yet, and says to run the script again' {
            Mock Get-AzNetworkSecurityGroup { throw 'The Resource ''Microsoft.Network/networkSecurityGroups/nsg-mgmt'' was not found (NotFound).' }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.NetworksCreated | Should -Be 2
            Should -Invoke New-AzVirtualNetworkSubnetConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'snet-mgmt' -and -not $NetworkSecurityGroup }
            $r.Text | Should -Match 'Not attached yet, the resource does not exist: nsg-mgmt'
        }

        It 'puts the file-level tags on the networks' {
            $null = Invoke-Vnet (New-InfraFile -Tags ([ordered]@{ environment = 'lab'; owner = 'team' }))
            Should -Invoke New-AzVirtualNetwork -Times 2 -Exactly -ParameterFilter { $Tag -and $Tag['environment'] -eq 'lab' -and $Tag['owner'] -eq 'team' }
        }

        It 'uses azure.location when a network has none' {
            $null = Invoke-Vnet (New-InfraFile @((New-Hub @{ location = $null }), (New-Spoke @{ location = $null })) -Location 'westus2')
            Should -Invoke New-AzVirtualNetwork -Times 2 -Exactly -ParameterFilter { $Location -eq 'westus2' }
        }

        It 'creates a network that has no subnets' {
            $r = Invoke-Vnet (New-InfraFile @(, (New-Hub @{ subnets = $null; peer_with = $null })))
            $r.ExitCode | Should -Be 0
            Should -Invoke New-AzVirtualNetwork -Times 1 -Exactly -ParameterFilter { -not $Subnet }
        }

        It 'peers the networks that list each other, in both directions, with forwarded traffic allowed and no gateway transit' {
            $r = Invoke-Vnet (New-InfraFile)
            $r.Result.PeeringsCreated | Should -Be 2
            Should -Invoke Add-AzVirtualNetworkPeering -Times 1 -Exactly -ParameterFilter { $Name -eq 'peer-vnet-mgmt-01-to-vnet-hub-01' -and $RemoteVirtualNetworkId -eq '/vnets/vnet-hub-01' -and $AllowForwardedTraffic }
            Should -Invoke Add-AzVirtualNetworkPeering -Times 1 -Exactly -ParameterFilter { $Name -eq 'peer-vnet-hub-01-to-vnet-mgmt-01' -and $RemoteVirtualNetworkId -eq '/vnets/vnet-mgmt-01' }
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'AllowGatewayTransit|UseRemoteGateways'
        }

        It 'makes one pair of peerings when both networks list each other' {
            $file = New-InfraFile @((New-Hub @{ peer_with = @('vnet-mgmt-01') }), (New-Spoke))
            (Invoke-Vnet $file).Result.PeeringsCreated | Should -Be 2
        }

        It 'peers across subscriptions, each side in its own subscription' {
            $null = Invoke-Vnet (New-InfraFile)
            Should -Invoke Get-AzVirtualNetworkPeering -Times 1 -Exactly -ParameterFilter { $VirtualNetworkName -eq 'vnet-hub-01' -and $ResourceGroupName -eq 'rg-conn-01' }
            Should -Invoke Get-AzVirtualNetworkPeering -Times 1 -Exactly -ParameterFilter { $VirtualNetworkName -eq 'vnet-mgmt-01' -and $ResourceGroupName -eq 'rg-mgmt-01' }
        }

        It 'a peering name stays within the 80 characters Azure allows' {
            $long = 'v' * 50
            $file = New-InfraFile @((New-Hub @{ name = $long; peer_with = $null }), (New-Spoke @{ name = ($long + 'x'); peer_with = @($long) }))
            $null = Invoke-Vnet $file
            Should -Invoke Add-AzVirtualNetworkPeering -Times 2 -Exactly -ParameterFilter { $Name.Length -le 80 }
        }
    }

    Context 'the networks already exist (idempotent, additive)' {
        BeforeEach {
            Mock Get-AzVirtualNetwork {
                if ($Name -eq 'vnet-hub-01') { New-Existing 'vnet-hub-01' @('198.51.100.0/24') @((New-ExistingSubnet 'GatewaySubnet' '198.51.100.0/27'), (New-ExistingSubnet 'snet-shared' '198.51.100.32/27')) @('192.0.2.4', '192.0.2.5') }
                else { New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26' '/nsgs/nsg-mgmt')) }
            }
            Mock Get-AzVirtualNetworkPeering { [pscustomobject]@{ Name = $Name; PeeringState = 'Connected' } }
        }

        It 'creates and changes nothing and says so' {
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Result.NetworksExisting | Should -Be 2
            $r.Result.NetworksCreated | Should -Be 0
            $r.Result.PeeringsExisting | Should -Be 2
            Should -Invoke New-AzVirtualNetwork -Times 0 -Exactly
            Should -Invoke Add-AzVirtualNetworkSubnetConfig -Times 0 -Exactly
            Should -Invoke Set-AzVirtualNetworkSubnetConfig -Times 0 -Exactly
            Should -Invoke Set-AzVirtualNetwork -Times 0 -Exactly
            Should -Invoke Add-AzVirtualNetworkPeering -Times 0 -Exactly
            $r.Text | Should -Match 'Nothing to do'
        }

        It 'adds a subnet the network lacks, and saves the network once' {
            Mock Get-AzVirtualNetwork {
                if ($Name -eq 'vnet-hub-01') { New-Existing 'vnet-hub-01' @('198.51.100.0/24') @(, (New-ExistingSubnet 'GatewaySubnet' '198.51.100.0/27')) @('192.0.2.4', '192.0.2.5') }
                else { New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26' '/nsgs/nsg-mgmt')) }
            }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.NetworksUpdated | Should -Be 1
            Should -Invoke Add-AzVirtualNetworkSubnetConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'snet-shared' -and $AddressPrefix -eq '198.51.100.32/27' }
            Should -Invoke Set-AzVirtualNetwork -Times 1 -Exactly
        }

        It 'attaches a network security group to a subnet that has none, once the group exists' {
            Mock Get-AzVirtualNetwork {
                if ($Name -eq 'vnet-hub-01') { New-Existing 'vnet-hub-01' @('198.51.100.0/24') @((New-ExistingSubnet 'GatewaySubnet' '198.51.100.0/27'), (New-ExistingSubnet 'snet-shared' '198.51.100.32/27')) @('192.0.2.4', '192.0.2.5') }
                else { New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26')) }
            }
            $r = Invoke-Vnet (New-InfraFile)
            $r.Result.NetworksUpdated | Should -Be 1
            Should -Invoke Set-AzVirtualNetworkSubnetConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'snet-mgmt' -and $NetworkSecurityGroup.Id -eq '/nsgs/nsg-mgmt' -and $AddressPrefix -eq '203.0.113.0/26' }
            Should -Invoke Set-AzVirtualNetwork -Times 1 -Exactly
        }

        It 'keeps the route table of a subnet when it attaches the group' {
            Mock Get-AzVirtualNetwork {
                if ($Name -eq 'vnet-hub-01') { New-Existing 'vnet-hub-01' @('198.51.100.0/24') @((New-ExistingSubnet 'GatewaySubnet' '198.51.100.0/27'), (New-ExistingSubnet 'snet-shared' '198.51.100.32/27')) @('192.0.2.4', '192.0.2.5') }
                else { New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26' $null '/routetables/rt-old')) }
            }
            $null = Invoke-Vnet (New-InfraFile)
            Should -Invoke Set-AzVirtualNetworkSubnetConfig -Times 1 -Exactly -ParameterFilter { $NetworkSecurityGroup.Id -eq '/nsgs/nsg-mgmt' -and $RouteTable.Id -eq '/routetables/rt-old' }
        }

        It 'does not attach a group that still does not exist, and says so' {
            Mock Get-AzNetworkSecurityGroup { throw 'was not found (NotFound).' }
            Mock Get-AzVirtualNetwork {
                if ($Name -eq 'vnet-hub-01') { New-Existing 'vnet-hub-01' @('198.51.100.0/24') @((New-ExistingSubnet 'GatewaySubnet' '198.51.100.0/27'), (New-ExistingSubnet 'snet-shared' '198.51.100.32/27')) @('192.0.2.4', '192.0.2.5') }
                else { New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26')) }
            }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 0
            Should -Invoke Set-AzVirtualNetworkSubnetConfig -Times 0 -Exactly
            $r.Text | Should -Match 'Not attached yet'
        }

        It 'reports a subnet range that differs and leaves it alone' {
            Mock Get-AzVirtualNetwork {
                if ($Name -eq 'vnet-hub-01') { New-Existing 'vnet-hub-01' @('198.51.100.0/24') @((New-ExistingSubnet 'GatewaySubnet' '198.51.100.0/28'), (New-ExistingSubnet 'snet-shared' '198.51.100.32/27')) @('192.0.2.4', '192.0.2.5') }
                else { New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26' '/nsgs/nsg-mgmt')) }
            }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 0
            ($r.Result.Networks | Where-Object Network -EQ 'vnet-hub-01').Differences | Should -Match "subnet 'GatewaySubnet' is 198.51.100.0/28"
            Should -Invoke Set-AzVirtualNetwork -Times 0 -Exactly
        }

        It 'reports DNS servers and an address space that differ and leaves them alone' {
            Mock Get-AzVirtualNetwork {
                if ($Name -eq 'vnet-hub-01') { New-Existing 'vnet-hub-01' @('198.51.100.0/25') @((New-ExistingSubnet 'GatewaySubnet' '198.51.100.0/27'), (New-ExistingSubnet 'snet-shared' '198.51.100.32/27')) @('192.0.2.99') }
                else { New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26' '/nsgs/nsg-mgmt')) }
            }
            $r = Invoke-Vnet (New-InfraFile)
            $diff = ($r.Result.Networks | Where-Object Network -EQ 'vnet-hub-01').Differences -join '|'
            $diff | Should -Match 'address space lacks 198.51.100.0/24'
            $diff | Should -Match 'DNS servers are'
            Should -Invoke Set-AzVirtualNetwork -Times 0 -Exactly
        }

        It 'reports another group attached to a subnet and does not replace it' {
            Mock Get-AzVirtualNetwork {
                if ($Name -eq 'vnet-hub-01') { New-Existing 'vnet-hub-01' @('198.51.100.0/24') @((New-ExistingSubnet 'GatewaySubnet' '198.51.100.0/27'), (New-ExistingSubnet 'snet-shared' '198.51.100.32/27')) @('192.0.2.4', '192.0.2.5') }
                else { New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26' '/nsgs/nsg-other')) }
            }
            $r = Invoke-Vnet (New-InfraFile)
            ($r.Result.Networks | Where-Object Network -EQ 'vnet-mgmt-01').Differences | Should -Match 'another NetworkSecurityGroup attached'
            Should -Invoke Set-AzVirtualNetworkSubnetConfig -Times 0 -Exactly
        }

        It 'creates the peering that is missing and leaves the one that exists' {
            Mock Get-AzVirtualNetworkPeering { if ($VirtualNetworkName -eq 'vnet-hub-01') { [pscustomobject]@{ Name = $Name; PeeringState = 'Initiated' } } else { throw 'Peering not found (404 NotFound).' } }
            $r = Invoke-Vnet (New-InfraFile)
            $r.Result.PeeringsCreated | Should -Be 1
            $r.Result.PeeringsExisting | Should -Be 1
            Should -Invoke Add-AzVirtualNetworkPeering -Times 1 -Exactly -ParameterFilter { $Name -eq 'peer-vnet-mgmt-01-to-vnet-hub-01' }
        }

        It 'never removes anything' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'Remove-Az'
        }
    }

    Context '-WhatIf' {
        It 'plans the networks and the peerings and creates nothing' {
            $r = Invoke-Vnet (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.NetworksPlanned | Should -Be 2
            $r.Result.PeeringsPlanned | Should -Be 2
            Should -Invoke New-AzVirtualNetwork -Times 0 -Exactly
            Should -Invoke Add-AzVirtualNetworkPeering -Times 0 -Exactly
            $r.Text | Should -Match 'would be created'
        }

        It 'plans a missing subnet of an existing network and changes nothing' {
            Mock Get-AzVirtualNetwork {
                if ($Name -eq 'vnet-hub-01') { New-Existing 'vnet-hub-01' @('198.51.100.0/24') @(, (New-ExistingSubnet 'GatewaySubnet' '198.51.100.0/27')) @('192.0.2.4', '192.0.2.5') }
                else { New-Existing 'vnet-mgmt-01' @('203.0.113.0/24') @(, (New-ExistingSubnet 'snet-mgmt' '203.0.113.0/26' '/nsgs/nsg-mgmt')) }
            }
            $r = Invoke-Vnet (New-InfraFile) -DryRun
            $r.Result.NetworksPlanned | Should -Be 1
            Should -Invoke Add-AzVirtualNetworkSubnetConfig -Times 0 -Exactly
            Should -Invoke Set-AzVirtualNetwork -Times 0 -Exactly
            $r.Text | Should -Match 'would add snet-shared'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'vnet.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
            Should -Invoke New-AzVirtualNetwork -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without landing_zone.networks' {
            $r = Invoke-Vnet (New-InfraFile -Networks $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'landing_zone.networks is empty'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Vnet (New-InfraFile -TenantId $null)
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
            $r = Invoke-Vnet (New-InfraFile @((New-Hub $Override)))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            Should -Invoke New-AzVirtualNetwork -Times 0 -Exactly
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a subscription whose id is the all-zero placeholder' {
            $subs = @([ordered]@{ name = 'sub-connectivity'; id = [guid]::Empty.ToString(); role = 'connectivity' })
            $r = Invoke-Vnet (New-InfraFile @(, (New-Hub @{ peer_with = $null })) -Subscriptions $subs)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no usable id'
        }

        It 'refuses a network with no location anywhere' {
            $r = Invoke-Vnet (New-InfraFile @(, (New-Hub @{ location = $null })) -Location '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no location'
        }

        It 'refuses the same network twice' {
            $r = Invoke-Vnet (New-InfraFile @((New-Hub), (New-Hub)))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'more than once'
        }

        It 'accepts subnets that fill the address space exactly and a /32 at the edge' {
            $hub = New-Hub @{ address_space = @('198.51.100.0/24'); subnets = @((New-Subnet 'snet-a' '198.51.100.0/25'), (New-Subnet 'snet-b' '198.51.100.128/26'), (New-Subnet 'snet-c' '198.51.100.255/32')) }
            (Invoke-Vnet (New-InfraFile @(, $hub))).ExitCode | Should -Be 0
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Vnet (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzVirtualNetwork -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke Set-AzContext -Times 0 -Exactly
        }

        It 'reports a network that cannot be created, still creates the other, and skips the peerings of the failed one' {
            Mock New-AzVirtualNetwork { if ($Name -eq 'vnet-hub-01') { throw 'QuotaExceeded' } else { [pscustomobject]@{ Name = $Name; Id = "/vnets/$Name"; Subnets = @() } } }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.NetworksFailed | Should -Be 1
            $r.Result.NetworksCreated | Should -Be 1
            ($r.Result.Networks | Where-Object Action -EQ 'Failed').Detail | Should -Match 'QuotaExceeded'
            Should -Invoke Add-AzVirtualNetworkPeering -Times 0 -Exactly
            @($r.Result.Peerings | Where-Object Action -EQ 'Skipped').Count | Should -Be 2
        }

        It 'does not hide a network lookup error that is not a not-found' {
            Mock Get-AzVirtualNetwork { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.NetworksFailed | Should -Be 2
            Should -Invoke New-AzVirtualNetwork -Times 0 -Exactly
        }

        It 'does not hide a group lookup error that is not a not-found' {
            Mock Get-AzNetworkSecurityGroup { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            ($r.Result.Networks | Where-Object Network -EQ 'vnet-mgmt-01').Detail | Should -Match 'authorization'
            Should -Invoke New-AzVirtualNetwork -Times 0 -Exactly -ParameterFilter { $Name -eq 'vnet-mgmt-01' }
        }

        It 'reports a failed peering and exits 1' {
            Mock Add-AzVirtualNetworkPeering { if ($Name -match 'mgmt-01-to') { throw 'RemoteVnetNotAccessible' } else { [pscustomobject]@{ Name = $Name } } }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.PeeringsFailed | Should -Be 1
            $r.Result.PeeringsCreated | Should -Be 1
            ($r.Result.Peerings | Where-Object Action -EQ 'Failed').Detail | Should -Match 'RemoteVnetNotAccessible'
        }

        It 'does not hide a peering lookup error that is not a not-found' {
            Mock Get-AzVirtualNetworkPeering { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Vnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.PeeringsFailed | Should -Be 2
            Should -Invoke Add-AzVirtualNetworkPeering -Times 0 -Exactly
        }

        It 'puts the session subscription back even when a network fails' {
            Mock New-AzVirtualNetwork { throw 'QuotaExceeded' }
            $null = Invoke-Vnet (New-InfraFile)
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVnetTestHome }
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
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

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Deploy_VirtualNetworks_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'azure.location', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id', 'landing_zone.networks[].name', 'landing_zone.networks[].subscription',
                'landing_zone.networks[].resource_group', 'landing_zone.networks[].location', 'landing_zone.networks[].address_space', 'landing_zone.networks[].dns_servers', 'landing_zone.networks[].peer_with',
                'landing_zone.networks[].subnets[].name', 'landing_zone.networks[].subnets[].prefix', 'landing_zone.networks[].subnets[].network_security_group', 'landing_zone.networks[].subnets[].route_table') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
        }
    }
}
