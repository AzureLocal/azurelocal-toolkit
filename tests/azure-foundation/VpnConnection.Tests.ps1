#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 03: New-VpnConnection.ps1 creates the local network gateway and the IPsec
# connection of each landing_zone.connectivity.vpn_gateway.site_to_site entry. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used.
# The shared key is read from an environment variable the test sets; its value is a per-run canary that must not appear in any output.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/VpnConnection.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-03-s2s-vpn-connection', 'powershell', 'New-VpnConnection.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzVirtualNetworkGateway { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzLocalNetworkGateway { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzLocalNetworkGateway { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$GatewayIpAddress, [string[]]$AddressPrefix, [uint32]$Asn, [string]$BgpPeeringAddress, [hashtable]$Tag) }
    function Get-AzVirtualNetworkGatewayConnection { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzVirtualNetworkGatewayConnection { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [object]$VirtualNetworkGateway1, [object]$LocalNetworkGateway2, [string]$ConnectionType, [string]$SharedKey, [bool]$EnableBgp, [hashtable]$Tag) }

    $global:AzlVcTestTenant = [guid]::NewGuid().ToString()
    $global:AzlVcTestSub = [guid]::NewGuid().ToString()
    $global:AzlVcTestHome = [guid]::NewGuid().ToString()
    $global:AzlVcCanary = 'Canary-' + [guid]::NewGuid().ToString('N')
    $env:AZL_TEST_VPN_KEY = $global:AzlVcCanary

    function New-Site([string]$Connection = 'cn-iic-dal-01', [hashtable]$Override = @{}) {
        $s = [ordered]@{ connection_name = $Connection; local_gateway_name = 'lgw-iic-dal-01'; peer_public_ip = '203.0.113.1'; peer_address_prefixes = @('192.0.2.0/24', '198.51.100.0/24'); shared_key = 'env://AZL_TEST_VPN_KEY' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $s.Remove($k) } else { $s[$k] = $Override[$k] } }
        $s
    }
    function New-InfraFile {
        param([object[]]$Sites = @((New-Site)), [hashtable]$Azure = @{}, [object]$Tags = $null, [switch]$NoGateway)
        $az = [ordered]@{ tenant_id = $global:AzlVcTestTenant; location = 'eastus' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $gw = [ordered]@{ name = 'vpng-iic-hub-01'; network = 'vnet-iic-hub-01'; sku = 'VpnGw1AZ'; bgp_asn = 65515 }
        if ($Sites) { $gw.site_to_site = @($Sites) }
        $doc = [ordered]@{
            azure        = $az
            landing_zone = [ordered]@{
                subscriptions = @([ordered]@{ name = 'sub-iic-connectivity'; id = $global:AzlVcTestSub; role = 'connectivity' })
                networks      = @([ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; location = 'westeurope'; address_space = @('10.20.0.0/22') })
            }
        }
        if (-not $NoGateway) { $doc.landing_zone.connectivity = [ordered]@{ vpn_gateway = $gw } }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Conn([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Connection'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
            Everything = (@($all | ForEach-Object { "$_" | Out-String }) -join "`n")
        }
    }
}

Describe 'New-VpnConnection.ps1' {
    AfterAll { Remove-Variable -Name AzlVcTestTenant, AzlVcTestSub, AzlVcTestHome, AzlVcCanary -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_VPN_KEY -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlVcTestTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlVcTestHome } } }
        Mock Set-AzContext { }
        Mock Get-AzVirtualNetworkGateway { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Succeeded' } }
        Mock Get-AzLocalNetworkGateway { throw "The Resource 'Microsoft.Network/localNetworkGateways/$Name' was not found (404 NotFound)." }
        Mock New-AzLocalNetworkGateway { [pscustomobject]@{ Name = $Name; GatewayIpAddress = $GatewayIpAddress } }
        Mock Get-AzVirtualNetworkGatewayConnection { throw "The Resource 'Microsoft.Network/connections/$Name' was not found (404 NotFound)." }
        Mock New-AzVirtualNetworkGatewayConnection { [pscustomobject]@{ Name = $Name; ConnectionStatus = 'Unknown' } }
    }

    Context 'creating the connection' {
        It 'creates the local network gateway and the IPsec connection in the resource group, region and subscription of the hub network' {
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVcTestSub }
            Should -Invoke New-AzLocalNetworkGateway -Times 1 -Exactly -ParameterFilter {
                $ResourceGroupName -eq 'rg-iic-conn-01' -and $Name -eq 'lgw-iic-dal-01' -and $Location -eq 'westeurope' -and $GatewayIpAddress -eq '203.0.113.1' -and
                @($AddressPrefix) -contains '192.0.2.0/24' -and @($AddressPrefix) -contains '198.51.100.0/24' -and -not $BgpPeeringAddress
            }
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 1 -Exactly -ParameterFilter {
                $ResourceGroupName -eq 'rg-iic-conn-01' -and $Name -eq 'cn-iic-dal-01' -and $ConnectionType -eq 'IPsec' -and $SharedKey -eq $global:AzlVcCanary -and
                $VirtualNetworkGateway1.Name -eq 'vpng-iic-hub-01' -and $LocalNetworkGateway2.Name -eq 'lgw-iic-dal-01' -and -not $EnableBgp
            }
        }

        It 'turns BGP on, on the local network gateway and the connection, when the entry has an ASN and a BGP address' {
            $site = New-Site -Override @{ peer_asn = 65010; peer_bgp_address = '192.0.2.254' }
            $null = Invoke-Conn (New-InfraFile -Sites @($site))
            Should -Invoke New-AzLocalNetworkGateway -Times 1 -Exactly -ParameterFilter { $Asn -eq 65010 -and $BgpPeeringAddress -eq '192.0.2.254' }
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 1 -Exactly -ParameterFilter { $EnableBgp -eq $true }
        }

        It 'names the local network gateway after the connection when the entry gives no name, and puts the file-level tags on both' {
            $site = New-Site -Override @{ local_gateway_name = $null }
            $null = Invoke-Conn (New-InfraFile -Sites @($site) -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzLocalNetworkGateway -Times 1 -Exactly -ParameterFilter { $Name -eq 'cn-iic-dal-01-lgw' -and $Tag['environment'] -eq 'lab' }
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 1 -Exactly -ParameterFilter { $Tag['environment'] -eq 'lab' }
        }

        It 'creates every connection of the list, and puts the original subscription back' {
            $r = Invoke-Conn (New-InfraFile -Sites @((New-Site), (New-Site 'cn-iic-fra-01' @{ local_gateway_name = 'lgw-iic-fra-01'; peer_public_ip = '203.0.113.2' })))
            $r.Rows.Count | Should -Be 2
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 2 -Exactly
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVcTestHome }
        }

        It 'never prints, returns or logs the shared key' {
            $r = Invoke-Conn (New-InfraFile)
            $r.Everything | Should -Not -Match ([regex]::Escape($global:AzlVcCanary))
        }

        It 'creates only local network gateways and connections and never removes or changes one' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-Az|Set-AzLocalNetworkGateway|Set-AzVirtualNetworkGatewayConnection|Reset-Az|Update-Az'
        }
    }

    Context 'things that exist already (idempotent)' {
        It 'creates nothing and says so, and reports a peer that differs from the file' {
            Mock Get-AzLocalNetworkGateway { [pscustomobject]@{ Name = $Name; GatewayIpAddress = '203.0.113.99'; LocalNetworkAddressSpace = [pscustomobject]@{ AddressPrefixes = @('192.0.2.0/24') } } }
            Mock Get-AzVirtualNetworkGatewayConnection { [pscustomobject]@{ Name = $Name; ConnectionStatus = 'Connected' } }
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].ConnectionStatus | Should -Be 'Connected'
            $r.Rows[0].Detail | Should -Match 'peer address 203\.0\.113\.99'
            $r.Rows[0].Detail | Should -Match 'ranges 192\.0\.2\.0/24'
            Should -Invoke New-AzLocalNetworkGateway -Times 0 -Exactly
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 0 -Exactly
        }

        It 'creates only the connection when the local network gateway is there' {
            Mock Get-AzLocalNetworkGateway { [pscustomobject]@{ Name = $Name; GatewayIpAddress = '203.0.113.1'; LocalNetworkAddressSpace = [pscustomobject]@{ AddressPrefixes = @('192.0.2.0/24', '198.51.100.0/24') } } }
            $r = Invoke-Conn (New-InfraFile)
            $r.Rows[0].Action | Should -Be 'Created'
            $r.Rows[0].Detail | Should -BeNullOrEmpty
            Should -Invoke New-AzLocalNetworkGateway -Times 0 -Exactly
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 1 -Exactly
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans the connection, creates nothing and does not read the secret' {
            $env:AZL_TEST_VPN_KEY = $null
            try {
                $r = Invoke-Conn (New-InfraFile) -DryRun
                $r.ExitCode | Should -Be 0 -Because $r.Text
                $r.Rows[0].Action | Should -Be 'WouldCreate'
            }
            finally { $env:AZL_TEST_VPN_KEY = $global:AzlVcCanary }
            Should -Invoke New-AzLocalNetworkGateway -Times 0 -Exactly
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the file lists no connection' {
            $r = Invoke-Conn (New-InfraFile -Sites @())
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.<Key>' -ForEach @(@{ Key = 'tenant_id' }) {
            $r = Invoke-Conn (New-InfraFile -Azure @{ $Key = $null })
            $r.ExitCode | Should -Be 2
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a file with no VPN gateway' {
            (Invoke-Conn (New-InfraFile -NoGateway)).ExitCode | Should -Be 2
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a connection with no name'; Override = @{ connection_name = $null } }
            @{ Why = 'a peer address that is not IPv4'; Override = @{ peer_public_ip = 'vpn.example.com' } }
            @{ Why = 'no address range behind the peer'; Override = @{ peer_address_prefixes = $null } }
            @{ Why = 'a range that is not CIDR'; Override = @{ peer_address_prefixes = @('192.0.2.0') } }
            @{ Why = 'an ASN without a BGP address'; Override = @{ peer_asn = 65010 } }
            @{ Why = 'a BGP address without an ASN'; Override = @{ peer_bgp_address = '192.0.2.254' } }
            @{ Why = 'no shared key'; Override = @{ shared_key = $null } }
            @{ Why = 'a shared key that is the key itself and not a reference'; Override = @{ shared_key = 'P@ssw0rd-in-the-file' } }
        ) {
            $r = Invoke-Conn (New-InfraFile -Sites @((New-Site -Override $Override)))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 0 -Exactly
        }

        It 'refuses the same connection twice' {
            (Invoke-Conn (New-InfraFile -Sites @((New-Site), (New-Site 'CN-IIC-DAL-01')))).ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Conn (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 0 -Exactly
        }

        It 'stops when the VPN gateway does not exist' {
            Mock Get-AzVirtualNetworkGateway { throw "The Resource 'Microsoft.Network/virtualNetworkGateways/x' was not found (404 NotFound)." }
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Deploy-VpnGateway'
            Should -Invoke New-AzLocalNetworkGateway -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzLocalNetworkGateway { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 0 -Exactly
        }

        It 'reports a secret that cannot be read, creates no connection for it, and goes on with the next one' {
            $site = New-Site 'cn-iic-fra-01' @{ local_gateway_name = 'lgw-iic-fra-01'; shared_key = 'env://AZL_TEST_VPN_KEY_MISSING' }
            $r = Invoke-Conn (New-InfraFile -Sites @($site, (New-Site)))
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed', 'Created')
            Should -Invoke New-AzVirtualNetworkGatewayConnection -Times 1 -Exactly -ParameterFilter { $Name -eq 'cn-iic-dal-01' }
        }

        It 'reports a failed creation, puts the subscription back, and exits 1' {
            Mock New-AzVirtualNetworkGatewayConnection { throw 'AuthorizationFailed' }
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVcTestHome }
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, never the old layout, and holds no GUID or address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml|azure_platform|vpngw-|lgw-onprem|conn-onprem'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_VpnConnection_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.location', 'tags', 'landing_zone.connectivity.vpn_gateway.name', 'landing_zone.connectivity.vpn_gateway.resource_group', 'landing_zone.connectivity.vpn_gateway.network', 'landing_zone.connectivity.vpn_gateway.site_to_site[].connection_name', 'landing_zone.connectivity.vpn_gateway.site_to_site[].local_gateway_name', 'landing_zone.connectivity.vpn_gateway.site_to_site[].peer_public_ip', 'landing_zone.connectivity.vpn_gateway.site_to_site[].peer_address_prefixes', 'landing_zone.connectivity.vpn_gateway.site_to_site[].peer_bgp_address', 'landing_zone.connectivity.vpn_gateway.site_to_site[].peer_asn', 'landing_zone.connectivity.vpn_gateway.site_to_site[].shared_key', 'landing_zone.networks[].name', 'landing_zone.networks[].subscription', 'landing_zone.networks[].resource_group', 'landing_zone.networks[].location', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
