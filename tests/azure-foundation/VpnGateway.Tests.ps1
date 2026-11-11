#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 02: Deploy-VpnGateway.ps1 creates the VPN gateway that
# landing_zone.connectivity.vpn_gateway describes. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids and ASNs are generated or
# documentation values; the address prefixes use the documentation ranges.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/VpnGateway.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-02-vpn-gateway', 'powershell', 'Deploy-VpnGateway.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzVirtualNetwork { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzVirtualNetworkSubnetConfig { [CmdletBinding()] param([string]$Name, [object]$VirtualNetwork) }
    function Get-AzVirtualNetworkGateway { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzPublicIpAddress { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzPublicIpAddress {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$Sku, [string]$AllocationMethod, [string[]]$Zone, [hashtable]$Tag)
    }
    function New-AzVirtualNetworkGatewayIpConfig { [CmdletBinding()] param([string]$Name, [string]$SubnetId, [string]$PublicIpAddressId) }
    function New-AzVirtualNetworkGateway {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$ResourceGroupName, [string]$Name, [string]$Location, [object]$IpConfigurations, [string]$GatewayType, [string]$VpnType, [string]$GatewaySku, [string]$VpnGatewayGeneration, [bool]$EnableBgp, [uint32]$Asn, [hashtable]$Tag)
    }

    $global:AzlVpnTestTenant = [guid]::NewGuid().ToString()
    $global:AzlVpnTestSub = [guid]::NewGuid().ToString()
    $global:AzlVpnTestHome = [guid]::NewGuid().ToString()

    # A file with the gateway, the network it sits in and the subscription of that network. Override a piece with -Gateway, -Network, -Subscriptions.
    function New-InfraFile {
        param([object]$Gateway = (New-Gateway), [object]$Network = (New-Network), [object]$Subscriptions = @([ordered]@{ name = 'sub-connectivity'; id = $global:AzlVpnTestSub; role = 'connectivity' }),
            [object]$TenantId = $global:AzlVpnTestTenant, [string]$Location = 'eastus', [object]$Tags = $null)
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($Location) { $doc.azure.location = $Location }
        if ($Tags) { $doc.tags = $Tags }
        $lz = [ordered]@{}
        if ($null -ne $Subscriptions) { $lz.subscriptions = @($Subscriptions) }
        if ($null -ne $Network) { $lz.networks = @($Network) }
        if ($null -ne $Gateway) { $lz.connectivity = [ordered]@{ vpn_gateway = $Gateway } }
        $doc.landing_zone = $lz
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Gateway([hashtable]$Override = @{}) {
        $g = [ordered]@{ name = 'vpng-hub-01'; resource_group = 'rg-conn-01'; network = 'vnet-hub-01'; sku = 'VpnGw2AZ'; bgp_asn = 65010 }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $g.Remove($k) } else { $g[$k] = $Override[$k] } }
        $g
    }
    function New-Network([hashtable]$Override = @{}) {
        $n = [ordered]@{ name = 'vnet-hub-01'; subscription = 'sub-connectivity'; resource_group = 'rg-net-01'; location = 'westus2'; role = 'hub'; address_space = @('198.51.100.0/24') }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $n.Remove($k) } else { $n[$k] = $Override[$k] } }
        $n
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Gateway([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['PublicIpName'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Deploy-VpnGateway.ps1' {
    AfterAll {
        Remove-Variable -Name AzlVpnTestTenant, AzlVpnTestSub, AzlVpnTestHome -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlVpnTestTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlVpnTestHome } } }
        Mock Set-AzContext { }
        Mock Get-AzVirtualNetwork { [pscustomobject]@{ Name = $Name; Id = "/subscriptions/x/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualNetworks/$Name" } }
        Mock Get-AzVirtualNetworkSubnetConfig { [pscustomobject]@{ Name = 'GatewaySubnet'; Id = '/subnets/gatewaysubnet'; AddressPrefix = @('198.51.100.0/27') } }
        Mock Get-AzVirtualNetworkGateway { $null }
        Mock Get-AzPublicIpAddress { $null }
        Mock New-AzPublicIpAddress { [pscustomobject]@{ Name = $Name; Id = "/publicIPAddresses/$Name"; IpAddress = '203.0.113.10' } }
        Mock New-AzVirtualNetworkGatewayIpConfig { [pscustomobject]@{ Name = $Name; SubnetId = $SubnetId; PublicIpAddressId = $PublicIpAddressId } }
        Mock New-AzVirtualNetworkGateway { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Succeeded' } }
    }

    Context 'creating the gateway (happy path)' {
        It 'creates a zone-redundant Standard static public IP address and the gateway, from the file' {
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Result.Action | Should -Be 'Created'
            Should -Invoke New-AzPublicIpAddress -Times 1 -Exactly -ParameterFilter { $Name -eq 'vpng-hub-01-pip' -and $ResourceGroupName -eq 'rg-conn-01' -and $Location -eq 'westus2' -and $Sku -eq 'Standard' -and $AllocationMethod -eq 'Static' -and ($Zone -join ',') -eq '1,2,3' }
            Should -Invoke New-AzVirtualNetworkGateway -Times 1 -Exactly -ParameterFilter { $Name -eq 'vpng-hub-01' -and $ResourceGroupName -eq 'rg-conn-01' -and $GatewayType -eq 'Vpn' -and $VpnType -eq 'RouteBased' -and $GatewaySku -eq 'VpnGw2AZ' -and $EnableBgp -and $Asn -eq 65010 }
            $r.Text | Should -Match 'Gateway public IP address: 203\.0\.113\.10'
        }

        It 'places the gateway ip configuration in the GatewaySubnet of the network, with the new public IP address' {
            $null = Invoke-Gateway (New-InfraFile)
            Should -Invoke Get-AzVirtualNetwork -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-net-01' -and $Name -eq 'vnet-hub-01' }
            Should -Invoke New-AzVirtualNetworkGatewayIpConfig -Times 1 -Exactly -ParameterFilter { $SubnetId -eq '/subnets/gatewaysubnet' -and $PublicIpAddressId -eq '/publicIPAddresses/vpng-hub-01-pip' }
        }

        It 'works in the subscription of the network, and puts the original subscription back' {
            $null = Invoke-Gateway (New-InfraFile)
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVpnTestSub }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVpnTestHome }
        }

        It 'puts the file-level tags on both resources' {
            $null = Invoke-Gateway (New-InfraFile -Tags ([ordered]@{ environment = 'lab'; owner = 'team' }))
            Should -Invoke New-AzPublicIpAddress -Times 1 -Exactly -ParameterFilter { $Tag -and $Tag['environment'] -eq 'lab' -and $Tag['owner'] -eq 'team' }
            Should -Invoke New-AzVirtualNetworkGateway -Times 1 -Exactly -ParameterFilter { $Tag -and $Tag['environment'] -eq 'lab' }
        }

        It 'sends no tags when the file has none' {
            $null = Invoke-Gateway (New-InfraFile)
            Should -Invoke New-AzVirtualNetworkGateway -Times 1 -Exactly -ParameterFilter { -not $Tag }
        }

        It 'VpnGw1AZ is Generation1 and VpnGw2AZ and above are Generation2: <Sku>' -ForEach @(
            @{ Sku = 'VpnGw1AZ'; Generation = 'Generation1' }, @{ Sku = 'VpnGw2AZ'; Generation = 'Generation2' }, @{ Sku = 'VpnGw3AZ'; Generation = 'Generation2' },
            @{ Sku = 'VpnGw4AZ'; Generation = 'Generation2' }, @{ Sku = 'VpnGw5AZ'; Generation = 'Generation2' }
        ) {
            $r = Invoke-Gateway (New-InfraFile -Gateway (New-Gateway @{ sku = $Sku }))
            $r.ExitCode | Should -Be 0
            Should -Invoke New-AzVirtualNetworkGateway -Times 1 -Exactly -ParameterFilter { $GatewaySku -eq $Sku -and $VpnGatewayGeneration -eq $Generation }
        }

        It 'uses the resource group of the network when the gateway names none' {
            $null = Invoke-Gateway (New-InfraFile -Gateway (New-Gateway @{ resource_group = $null }))
            Should -Invoke New-AzVirtualNetworkGateway -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-net-01' }
        }

        It 'uses azure.location when the network has none' {
            $null = Invoke-Gateway (New-InfraFile -Network (New-Network @{ location = $null }))
            Should -Invoke New-AzVirtualNetworkGateway -Times 1 -Exactly -ParameterFilter { $Location -eq 'eastus' }
        }

        It 'accepts the Azure default ASN 65515 for the gateway' {
            (Invoke-Gateway (New-InfraFile -Gateway (New-Gateway @{ bgp_asn = 65515 }))).ExitCode | Should -Be 0
        }

        It 'reuses a public IP address that is already there and creates only the gateway' {
            Mock Get-AzPublicIpAddress { [pscustomobject]@{ Name = $Name; Id = "/publicIPAddresses/$Name"; IpAddress = '203.0.113.20' } }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'Created'
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
            Should -Invoke New-AzVirtualNetworkGateway -Times 1 -Exactly
            $r.Text | Should -Match 'is reused'
        }
    }

    Context 'the gateway already exists (idempotent)' {
        BeforeEach {
            Mock Get-AzVirtualNetworkGateway { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Succeeded'; Sku = [pscustomobject]@{ Name = 'VpnGw2AZ' }; BgpSettings = [pscustomobject]@{ Asn = 65010 } } }
            Mock Get-AzPublicIpAddress { [pscustomobject]@{ Name = $Name; IpAddress = '203.0.113.30' } }
        }

        It 'creates nothing and reports the public IP address' {
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'AlreadyExists'
            $r.Result.PublicIpAddress | Should -Be '203.0.113.30'
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
            Should -Invoke Get-AzVirtualNetwork -Times 0 -Exactly
            $r.Text | Should -Match 'nothing changed'
        }

        It 'warns, and still changes nothing, when the SKU or the ASN differs from the file' {
            Mock Get-AzVirtualNetworkGateway { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Succeeded'; Sku = [pscustomobject]@{ Name = 'VpnGw3AZ' }; BgpSettings = [pscustomobject]@{ Asn = 65099 } } }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Detail | Should -Match 'SKU is VpnGw3AZ'
            $r.Result.Detail | Should -Match 'BGP ASN is 65099'
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'warns when the gateway is not in the Succeeded state' {
            Mock Get-AzVirtualNetworkGateway { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Updating'; Sku = [pscustomobject]@{ Name = 'VpnGw2AZ' }; BgpSettings = [pscustomobject]@{ Asn = 65010 } } }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match "provisioning state is 'Updating'"
        }
    }

    Context '-WhatIf' {
        It 'plans the public IP address and the gateway and creates neither' {
            $r = Invoke-Gateway (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
            Should -Invoke New-AzVirtualNetworkGatewayIpConfig -Times 0 -Exactly
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'vpn.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without landing_zone.connectivity.vpn_gateway' {
            $r = Invoke-Gateway (New-InfraFile -Gateway $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'vpn_gateway is missing'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Gateway (New-InfraFile -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses a missing <Key>' -ForEach @(@{ Key = 'name'; Match = 'vpn_gateway.name is missing' }, @{ Key = 'network'; Match = 'vpn_gateway.network is missing' }) {
            $r = Invoke-Gateway (New-InfraFile -Gateway (New-Gateway @{ $Key = $null }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match $Match
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'refuses a gateway name Azure does not accept' {
            $r = Invoke-Gateway (New-InfraFile -Gateway (New-Gateway @{ name = 'bad name!' }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'not a valid name'
        }

        It 'refuses a SKU that is not of the AZ family: <_>' -ForEach 'VpnGw1', 'VpnGw3', 'Basic', 'Standard', 'ErGw1AZ' {
            $r = Invoke-Gateway (New-InfraFile -Gateway (New-Gateway @{ sku = $_ }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'AZ SKU'
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'refuses a missing SKU' {
            $r = Invoke-Gateway (New-InfraFile -Gateway (New-Gateway @{ sku = $null }))
            $r.ExitCode | Should -Be 2
        }

        It 'refuses an ASN that Azure or IANA reserves: <_>' -ForEach 8074, 8075, 12076, 65517, 65520, 23456, 64496, 65535, 65551, 4294967295 {
            $r = Invoke-Gateway (New-InfraFile -Gateway (New-Gateway @{ bgp_asn = $_ }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'reserved'
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'refuses an ASN that is not a number in range: <_>' -ForEach '0', 'abc', '-5', '4294967296' {
            $r = Invoke-Gateway (New-InfraFile -Gateway (New-Gateway @{ bgp_asn = $_ }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'bgp_asn'
        }

        It 'refuses a network that is not an entry of landing_zone.networks' {
            $r = Invoke-Gateway (New-InfraFile -Network (New-Network @{ name = 'vnet-other' }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'is not an entry of landing_zone.networks'
        }

        It 'refuses a network with no subscription' {
            $r = Invoke-Gateway (New-InfraFile -Network (New-Network @{ subscription = $null }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'has no subscription'
        }

        It 'refuses a subscription that has no id, or the all-zero placeholder' {
            $r = Invoke-Gateway (New-InfraFile -Subscriptions @([ordered]@{ name = 'sub-connectivity'; role = 'connectivity' }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no usable id'
            $r = Invoke-Gateway (New-InfraFile -Subscriptions @([ordered]@{ name = 'sub-connectivity'; id = [guid]::Empty.ToString(); role = 'connectivity' }))
            $r.ExitCode | Should -Be 2
        }

        It 'refuses a network with no resource group' {
            $r = Invoke-Gateway (New-InfraFile -Network (New-Network @{ resource_group = $null }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no resource_group'
        }

        It 'refuses a file with no region anywhere' {
            $r = Invoke-Gateway (New-InfraFile -Network (New-Network @{ location = $null }) -Location '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'No region'
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Gateway (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke Set-AzContext -Times 0 -Exactly
        }

        It 'stops when the virtual network does not exist, and creates nothing' {
            Mock Get-AzVirtualNetwork { throw 'Resource not found (404 NotFound).' }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'does not exist'
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'stops when the network lookup returns nothing' {
            Mock Get-AzVirtualNetwork { $null }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'does not hide a network lookup error that is not a not-found' {
            Mock Get-AzVirtualNetwork { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'stops when the network has no GatewaySubnet' {
            Mock Get-AzVirtualNetworkSubnetConfig { $null }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'no subnet named GatewaySubnet'
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
        }

        It 'stops when the GatewaySubnet is smaller than a /27' {
            Mock Get-AzVirtualNetworkSubnetConfig { [pscustomobject]@{ Name = 'GatewaySubnet'; Id = '/subnets/gatewaysubnet'; AddressPrefix = @('198.51.100.0/28') } }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match '/27 or larger'
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'accepts a GatewaySubnet larger than a /27' {
            Mock Get-AzVirtualNetworkSubnetConfig { [pscustomobject]@{ Name = 'GatewaySubnet'; Id = '/subnets/gatewaysubnet'; AddressPrefix = @('198.51.100.0/26') } }
            (Invoke-Gateway (New-InfraFile)).ExitCode | Should -Be 0
        }

        It 'does not hide an error other than not-found when it looks for the gateway' {
            Mock Get-AzVirtualNetworkGateway { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
        }

        It 'treats a not-found error when it looks for the gateway as "no gateway yet"' {
            Mock Get-AzVirtualNetworkGateway { throw 'Resource vpng-hub-01 could not be found (404).' }
            (Invoke-Gateway (New-InfraFile)).ExitCode | Should -Be 0
            Should -Invoke New-AzVirtualNetworkGateway -Times 1 -Exactly
        }

        It 'reports a failed gateway creation, keeps the public IP address for the next run, puts the context back, and exits 1' {
            Mock New-AzVirtualNetworkGateway { throw 'QuotaExceeded' }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'QuotaExceeded'
            Should -Invoke New-AzPublicIpAddress -Times 1 -Exactly
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVpnTestHome }
        }

        It 'reports a failed public IP address creation and does not try the gateway' {
            Mock New-AzPublicIpAddress { throw 'PublicIPCountLimitReached' }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'PublicIPCountLimitReached'
            Should -Invoke New-AzVirtualNetworkGateway -Times 0 -Exactly
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

        It 'reads its values through the toolkit loader, never variables.yml, and holds no GUID or address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'does not carry the shared key of a connection or read a secret: the connections are a later task' {
            $script:Text | Should -Not -Match 'shared_key|Get-AzKeyVaultSecret|New-AzVirtualNetworkGatewayConnection|New-AzLocalNetworkGateway'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Deploy_VpnGateway_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'azure.location', 'landing_zone.connectivity.vpn_gateway.name', 'landing_zone.connectivity.vpn_gateway.resource_group',
                'landing_zone.connectivity.vpn_gateway.network', 'landing_zone.connectivity.vpn_gateway.sku', 'landing_zone.connectivity.vpn_gateway.bgp_asn',
                'landing_zone.networks[].name', 'landing_zone.networks[].subscription', 'landing_zone.networks[].resource_group', 'landing_zone.networks[].location',
                'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
            @($registry | Where-Object Path -EQ 'tags').Count | Should -BeGreaterOrEqual 1
        }
    }
}
