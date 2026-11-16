#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 03: New-VpnConnection.azcli.ps1 creates the local network gateways and the
# site-to-site connections of landing_zone.connectivity.vpn_gateway.site_to_site with az commands. The shared key is a keyvault:// reference that the
# script reads with "az keyvault secret show" only when a connection is created; the tests give it a value made up at run time (a canary) and check that it
# reaches the one az call that needs it and nowhere else. "az" is mocked: no Azure, no tenant and no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/VpnConnection.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-03-s2s-vpn-connection', 'azurecli', 'New-VpnConnection.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlVcSub = [guid]::NewGuid().ToString()
    $global:AzlVcCanary = 'Canary-' + [guid]::NewGuid().ToString('N')
    $env:AZL_TEST_VPN_KEY = $global:AzlVcCanary

    function New-Site([string]$Connection = 'cn-iic-dal-01', [hashtable]$Override = @{}) {
        Set-AzOverride ([ordered]@{ connection_name = $Connection; local_gateway_name = 'lgw-iic-dal-01'; peer_public_ip = '203.0.113.1'; peer_address_prefixes = @('192.0.2.0/24', '198.51.100.0/24'); shared_key = 'keyvault://kv-iic-mgmt-01/vpn-dal-key' }) $Override
    }
    function New-InfraFile {
        param([object[]]$Sites = @((New-Site)), [hashtable]$Azure = @{}, [object]$Tags = $null, [object]$Gateway = $null, [switch]$NoGateway, [object]$Tenant = $global:AzlFakeTenant, [object]$Vaults = @([ordered]@{ name = 'kv-iic-mgmt-01'; subscription_id = $global:AzlVcSub; resource_group = 'rg-iic-mgmt-01' }))
        $az = [ordered]@{ location = 'eastus' }
        if ($null -ne $Tenant) { $az.tenant_id = $Tenant }
        $null = Set-AzOverride $az $Azure
        $gw = [ordered]@{ name = 'vpng-iic-hub-01'; network = 'vnet-iic-hub-01'; sku = 'VpnGw1AZ'; bgp_asn = 65515 }
        if ($Sites) { $gw.site_to_site = @($Sites) }
        if ($Gateway) { $null = Set-AzOverride $gw $Gateway }
        $doc = [ordered]@{
            azure        = $az
            landing_zone = [ordered]@{
                subscriptions = @([ordered]@{ name = 'sub-iic-connectivity'; id = $global:AzlVcSub; role = 'connectivity' })
                networks      = @([ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; location = 'westeurope'; address_space = @('198.51.100.0/24') })
            }
        }
        if ($Vaults) { $doc.key_vaults = @($Vaults) }
        if (-not $NoGateway) { $doc.landing_zone.connectivity = [ordered]@{ vpn_gateway = $gw } }
        if ($Tags) { $doc.tags = $Tags }
        Save-AzInfraFile $doc
    }
    # Everything the run printed or returned, as text, to look for the canary.
    function Invoke-Conn([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 4>&1 5>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 4>&1 5>&1 }
        $code = $global:LASTEXITCODE
        [pscustomobject]@{
            ExitCode   = $code
            Rows       = @($all | Where-Object { $_ -isnot [string] -and $_.PSObject.Properties['Connection'] -and $_.PSObject.Properties['Action'] })
            Text       = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
            Everything = (@($all | ForEach-Object { "$_" | Out-String }) -join "`n")
        }
    }
}

Describe 'New-VpnConnection.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlVcSub, AzlVcCanary, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_VPN_KEY -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
        Add-AzRoute 'network vnet-gateway show*' ([ordered]@{ name = 'vpng-iic-hub-01'; id = '/gateways/vpng-iic-hub-01'; provisioningState = 'Succeeded' })
        # The vault answers with the canary; the connection answer holds the key, as the Azure CLI's does.
        Add-AzRoute 'keyvault secret show*' $global:AzlVcCanary
        Add-AzRoute 'network vpn-connection create*' { [ordered]@{ name = 'cn'; connectionStatus = 'Unknown'; sharedKey = $global:AzlVcCanary } | ConvertTo-Json -Compress }
    }

    Context 'creating the connection' {
        It 'creates the local network gateway and the IPsec connection in the group, region and subscription of the hub network' {
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            Get-AzCall "network local-gateway create --name lgw-iic-dal-01 --resource-group rg-iic-conn-01 --location westeurope --subscription $($global:AzlVcSub) --gateway-ip-address 203.0.113.1 --local-address-prefixes 192.0.2.0/24 198.51.100.0/24" | Should -HaveCount 1
            Get-AzCall "network vpn-connection create --name cn-iic-dal-01 --resource-group rg-iic-conn-01 --location westeurope --subscription $($global:AzlVcSub) --vnet-gateway1 /gateways/vpng-iic-hub-01 --local-gateway2 lgw-iic-dal-01 --shared-key *" | Should -HaveCount 1
            Get-AzCall 'account set*' | Should -BeNullOrEmpty
        }

        It 'reads the shared key from the vault of the reference with az, once, and only then' {
            $null = Invoke-Conn (New-InfraFile)
            Get-AzCall 'keyvault secret show --vault-name kv-iic-mgmt-01 --name vpn-dal-key --query value --output tsv' | Should -HaveCount 1
        }

        It 'passes the key to the connection and to nothing else, and prints, logs and returns it nowhere' {
            $log = Join-Path $TestDrive 'vpn.log'
            $global:LASTEXITCODE = $null
            $all = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -Verbose 6>&1 3>&1 2>&1 4>&1 5>&1
            $out = (@($all | ForEach-Object { "$_" | Out-String }) -join "`n")
            $out | Should -Not -Match ([regex]::Escape($global:AzlVcCanary))
            (Get-Content -LiteralPath $log -Raw) | Should -Not -Match ([regex]::Escape($global:AzlVcCanary))
            @($global:AzlFakeCalls | Where-Object { $_.Contains($global:AzlVcCanary) }).Count | Should -Be 1
            @(Get-AzCall "*$($global:AzlVcCanary)*")[0] | Should -BeLike 'network vpn-connection create*'
        }

        It 'cleans the shared key out of an az error text before it is shown' {
            Add-AzRoute 'network vpn-connection create*' { "ERROR: (InvalidSharedKey) The key $($global:AzlVcCanary) is not valid." } 1
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Everything | Should -Not -Match ([regex]::Escape($global:AzlVcCanary))
            $r.Text | Should -Match 'InvalidSharedKey'
        }

        It 'reads an env:// reference through the toolkit resolver, without az' {
            $r = Invoke-Conn (New-InfraFile -Sites @(New-Site 'cn-iic-dal-01' @{ shared_key = 'env://AZL_TEST_VPN_KEY' }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
            @($global:AzlFakeCalls | Where-Object { $_.Contains($global:AzlVcCanary) }).Count | Should -Be 1
        }

        It 'turns BGP on for a site with a peer ASN and a BGP address, and passes them to the local network gateway' {
            $null = Invoke-Conn (New-InfraFile -Sites @(New-Site 'cn-iic-dal-01' @{ peer_asn = 65050; peer_bgp_address = '192.0.2.254' }))
            Get-AzCall 'network local-gateway create*--asn 65050 --bgp-peering-address 192.0.2.254' | Should -HaveCount 1
            Get-AzCall 'network vpn-connection create*--enable-bgp' | Should -HaveCount 1
        }

        It 'creates no BGP settings for a site without them' {
            $null = Invoke-Conn (New-InfraFile)
            Get-AzCall '*--asn*' | Should -BeNullOrEmpty
            Get-AzCall '*--enable-bgp*' | Should -BeNullOrEmpty
        }

        It 'names the local network gateway after the connection when the entry names none' {
            $site = New-Site 'cn-iic-dal-01' @{ local_gateway_name = $null }
            $null = Invoke-Conn (New-InfraFile -Sites @($site))
            Get-AzCall 'network local-gateway create --name cn-iic-dal-01-lgw*' | Should -HaveCount 1
        }

        It 'puts the file-level tags on both resources' {
            $null = Invoke-Conn (New-InfraFile -Tags ([ordered]@{ environment = 'lab' }))
            Get-AzCall 'network local-gateway create*--tags environment=lab' | Should -HaveCount 1
            Get-AzCall 'network vpn-connection create*--tags environment=lab' | Should -HaveCount 1
        }

        It 'creates each site of the file' {
            $r = Invoke-Conn (New-InfraFile -Sites @((New-Site 'cn-iic-dal-01'), (New-Site 'cn-iic-hou-01' @{ local_gateway_name = 'lgw-iic-hou-01'; peer_public_ip = '203.0.113.2' })))
            @($r.Rows | Where-Object Action -EQ 'Created').Count | Should -Be 2
            Get-AzCall 'network vpn-connection create*' | Should -HaveCount 2
        }

        It 'does nothing and exits 0 when the file lists no site' {
            $r = Invoke-Conn (New-InfraFile -Sites @())
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }
    }

    Context 'the connection already exists (idempotent)' {
        It 'creates nothing, reads no secret, and reports the status' {
            Add-AzRoute 'network local-gateway show*' ([ordered]@{ name = 'lgw-iic-dal-01'; gatewayIpAddress = '203.0.113.1'; localNetworkAddressSpace = [ordered]@{ addressPrefixes = @('192.0.2.0/24', '198.51.100.0/24') } })
            Add-AzRoute 'network vpn-connection show*' ([ordered]@{ name = 'cn-iic-dal-01'; connectionStatus = 'Connected' })
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].ConnectionStatus | Should -Be 'Connected'
            Get-AzWriteCall | Should -BeNullOrEmpty
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
        }

        It 'reports a different peer address or range and leaves the local network gateway alone' {
            Add-AzRoute 'network local-gateway show*' ([ordered]@{ name = 'lgw-iic-dal-01'; gatewayIpAddress = '203.0.113.99'; localNetworkAddressSpace = [ordered]@{ addressPrefixes = @('192.0.2.0/25') } })
            Add-AzRoute 'network vpn-connection show*' ([ordered]@{ name = 'cn-iic-dal-01'; connectionStatus = 'Connected' })
            $r = Invoke-Conn (New-InfraFile)
            $r.Rows[0].Detail | Should -Match 'peer address 203.0.113.99, the file says 203.0.113.1'
            $r.Rows[0].Detail | Should -Match 'ranges 192.0.2.0/25'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports a different ASN or BGP peering address of the existing local network gateway, and one that has no ranges' {
            Add-AzRoute 'network local-gateway show*' ([ordered]@{ name = 'lgw-iic-dal-01'; gatewayIpAddress = '203.0.113.1'; localNetworkAddressSpace = [ordered]@{ addressPrefixes = @() }; bgpSettings = [ordered]@{ asn = 65099; bgpPeeringAddress = '192.0.2.1' } })
            Add-AzRoute 'network vpn-connection show*' ([ordered]@{ name = 'cn-iic-dal-01'; connectionStatus = 'Connected' })
            $r = Invoke-Conn (New-InfraFile -Sites @(New-Site 'cn-iic-dal-01' @{ peer_asn = 65050; peer_bgp_address = '192.0.2.254' }))
            $r.Rows[0].Detail | Should -Match "ASN '65099', the file says 65050"
            $r.Rows[0].Detail | Should -Match "BGP peering address '192.0.2.1', the file says 192.0.2.254"
            $r.Rows[0].Detail | Should -Match 'has no address ranges'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports BGP settings on the gateway that the file does not have' {
            Add-AzRoute 'network local-gateway show*' ([ordered]@{ name = 'lgw-iic-dal-01'; gatewayIpAddress = '203.0.113.1'; localNetworkAddressSpace = [ordered]@{ addressPrefixes = @('192.0.2.0/24', '198.51.100.0/24') }; bgpSettings = [ordered]@{ asn = 65099; bgpPeeringAddress = '192.0.2.1' } })
            Add-AzRoute 'network vpn-connection show*' ([ordered]@{ name = 'cn-iic-dal-01'; connectionStatus = 'Connected' })
            (Invoke-Conn (New-InfraFile)).Rows[0].Detail | Should -Match 'has BGP settings, the file has none'
        }

        It 'does not create a connection to a local network gateway that differs from the file, and fails that row with the reason' {
            Add-AzRoute 'network local-gateway show*' ([ordered]@{ name = 'lgw-iic-dal-01'; gatewayIpAddress = '203.0.113.99'; localNetworkAddressSpace = [ordered]@{ addressPrefixes = @('192.0.2.0/24', '198.51.100.0/24') } })
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'was not created because the existing local network gateway differs from the file'
            $r.Rows[0].Detail | Should -Match 'peer address 203.0.113.99'
            Get-AzCall 'network vpn-connection create*' | Should -BeNullOrEmpty
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
        }

        It 'creates only the connection when the local network gateway is there and the connection is not' {
            Add-AzRoute 'network local-gateway show*' ([ordered]@{ name = 'lgw-iic-dal-01'; gatewayIpAddress = '203.0.113.1'; localNetworkAddressSpace = [ordered]@{ addressPrefixes = @('192.0.2.0/24', '198.51.100.0/24') } })
            $r = Invoke-Conn (New-InfraFile)
            $r.Rows[0].Action | Should -Be 'Created'
            Get-AzCall 'network local-gateway create*' | Should -BeNullOrEmpty
            Get-AzCall 'network vpn-connection create*' | Should -HaveCount 1
        }
    }

    Context '-WhatIf' {
        It 'plans the local network gateway and the connection, reads no secret and writes nothing to Azure' {
            $r = Invoke-Conn (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Get-AzWriteCall | Should -BeNullOrEmpty
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would be created'
            $r.Everything | Should -Not -Match ([regex]::Escape($global:AzlVcCanary))
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'vpn2.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'refuses a missing tenant, and a file without the gateway' {
            (Invoke-Conn (New-InfraFile -Tenant $null)).ExitCode | Should -Be 2
            $r = Invoke-Conn (New-InfraFile -NoGateway)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'vpn_gateway is missing'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a connection with no name'; Override = @{ connection_name = $null }; Match = 'connection_name' }
            @{ Case = 'a connection name Azure does not accept'; Override = @{ connection_name = 'bad name!' }; Match = 'connection_name' }
            @{ Case = 'a bad local gateway name'; Override = @{ local_gateway_name = 'bad name!' }; Match = 'local_gateway_name' }
            @{ Case = 'a peer address that is not an IPv4 address'; Override = @{ peer_public_ip = 'nowhere' }; Match = 'peer_public_ip' }
            @{ Case = 'a peer address with an octet above 255'; Override = @{ peer_public_ip = '203.0.113.256' }; Match = 'peer_public_ip' }
            @{ Case = 'no address prefixes'; Override = @{ peer_address_prefixes = $null }; Match = 'peer_address_prefixes is missing' }
            @{ Case = 'a prefix that is not CIDR'; Override = @{ peer_address_prefixes = @('192.0.2.0') }; Match = 'not an IPv4 range in CIDR form' }
            @{ Case = 'an ASN without a BGP address'; Override = @{ peer_asn = 65050 }; Match = 'both peer_asn and peer_bgp_address' }
            @{ Case = 'a BGP address without an ASN'; Override = @{ peer_bgp_address = '192.0.2.254' }; Match = 'both peer_asn and peer_bgp_address' }
            @{ Case = 'an ASN out of range'; Override = @{ peer_asn = 0; peer_bgp_address = '192.0.2.254' }; Match = 'peer_asn' }
            @{ Case = 'no shared key'; Override = @{ shared_key = $null }; Match = 'shared_key is missing' }
            @{ Case = 'a shared key that is a value, not a reference'; Override = @{ shared_key = 'not-a-reference-value' }; Match = 'not a secret reference' }
        ) {
            $r = Invoke-Conn (New-InfraFile -Sites @(New-Site 'cn-iic-dal-01' $Override))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $r.Everything | Should -Not -Match 'not-a-reference-value.*not-a-reference-value'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses two connections that share a local network gateway, with exit code 2 and no az call' {
            $r = Invoke-Conn (New-InfraFile -Sites @((New-Site 'cn-iic-dal-01'), (New-Site 'cn-iic-hou-01' @{ local_gateway_name = 'LGW-IIC-DAL-01'; peer_public_ip = '203.0.113.2' })))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'used by two connections'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses a tag, the gateway name or the location with a character az.cmd cannot carry, naming the key and the value, with no az call' -ForEach @(
            @{ Tags = [ordered]@{ owner = 'a&b' }; Gateway = $null; Match = "tags.owner holds the value 'a&b'" }
            @{ Tags = [ordered]@{ 'k|ey' = 'x' }; Gateway = $null; Match = "key 'k\|ey'" }
            @{ Tags = $null; Gateway = @{ resource_group = 'rg^x' }; Match = "rg\^x" }
        ) {
            $file = New-InfraFile -Tags $Tags -Gateway $Gateway
            foreach ($dry in $false, $true) {
                $r = if ($dry) { Invoke-Conn $file -DryRun } else { Invoke-Conn $file }
                $r.ExitCode | Should -Be 2 -Because $r.Text
                $r.Text | Should -Match $Match
                Get-AzWriteCall | Should -BeNullOrEmpty
                $global:AzlFakeCalls | Should -BeNullOrEmpty
            }
        }

        It 'refuses the same connection twice' {
            $r = Invoke-Conn (New-InfraFile -Sites @((New-Site 'cn-iic-dal-01'), (New-Site 'CN-IIC-DAL-01')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'listed twice'
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Conn (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when az is not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Azure CLI \(az\) was not found'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'stops when nobody is signed in' {
            Add-AzRoute 'account show*' 'ERROR: Please run ''az login'' to setup account.' 1
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the sign-in is to another tenant' {
            Add-AzRoute 'account show*' ([guid]::NewGuid().ToString())
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the VPN gateway does not exist' {
            Add-AzNotFound 'network vnet-gateway show*'
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Create it first'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'fails the connection, without a secret in the message, when the secret cannot be read, and creates no connection' {
            Add-AzRoute 'keyvault secret show*' 'ERROR: (SecretNotFound) A secret with (name/id) vpn-dal-key was not found in this key vault.' 3
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'could not be read with az'
            Get-AzCall 'network vpn-connection create*' | Should -BeNullOrEmpty
        }

        It 'refuses, with exit code 2 at plan time, a vault that is not listed under key_vaults, also under -WhatIf, before any az call' {
            foreach ($dry in $false, $true) {
                $global:AzlFakeCalls.Clear()
                $file = New-InfraFile -Vaults @([ordered]@{ name = 'kv-iic-other-01'; subscription_id = $global:AzlVcSub; resource_group = 'rg-iic-mgmt-01' })
                $r = if ($dry) { Invoke-Conn $file -DryRun } else { Invoke-Conn $file }
                $r.ExitCode | Should -Be 2 -Because $r.Text
                $r.Text | Should -Match 'not listed under key_vaults'
                $global:AzlFakeCalls | Should -BeNullOrEmpty
            }
        }

        It 'fails the connection when the secret is empty' {
            Add-AzRoute 'keyvault secret show*' ''
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'is empty'
        }

        It 'reports a local network gateway that cannot be created, goes on with the next site, and exits 1' {
            Add-AzRoute 'network local-gateway create --name lgw-iic-dal-01*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-Conn (New-InfraFile -Sites @((New-Site 'cn-iic-dal-01'), (New-Site 'cn-iic-hou-01' @{ local_gateway_name = 'lgw-iic-hou-01'; peer_public_ip = '203.0.113.2' })))
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed').Count | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Created').Count | Should -Be 1
        }

        It 'does not hide a read error that is not a not-found' {
            Add-AzRoute 'network local-gateway show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Get-AzWriteCall | Should -BeNullOrEmpty
        }
    }

    Context 'a shared key that az.cmd cannot carry' {
        It 'refuses a key with <Name>, with exit code 2, creates nothing, and prints the key nowhere' -ForEach @(
            @{ Name = 'an ampersand'; Key = 'Canary&calc' }
            @{ Name = 'a percent sign'; Key = 'Canary%PATH%x' }
            @{ Name = 'a pipe'; Key = 'Canary|x' }
            @{ Name = 'a line break'; Key = "Canary`nx" }
        ) {
            Add-AzRoute 'keyvault secret show*' $Key
            $r = Invoke-Conn (New-InfraFile)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'keyvault://kv-iic-mgmt-01/vpn-dal-key'
            $r.Everything | Should -Not -Match 'Canary'
            Get-AzCall 'network vpn-connection create*' | Should -BeNullOrEmpty
            @($global:AzlFakeCalls | Where-Object { $_ -match 'Canary' }) | Should -BeNullOrEmpty
        }

        It 'refuses an env:// key with an unsafe character the same way' {
            $env:AZL_TEST_VPN_KEY = 'Canary&env'
            try {
                $r = Invoke-Conn (New-InfraFile -Sites @(New-Site 'cn-iic-dal-01' @{ shared_key = 'env://AZL_TEST_VPN_KEY' }))
                $r.ExitCode | Should -Be 2 -Because $r.Text
                $r.Everything | Should -Not -Match 'Canary'
                Get-AzCall 'network vpn-connection create*' | Should -BeNullOrEmpty
            }
            finally { $env:AZL_TEST_VPN_KEY = $global:AzlVcCanary }
        }
    }

    Context 'the answer of az network vpn-connection create' {
        It 'reads the status from resource.connectionStatus, and from the top level when there is no resource' {
            Add-AzRoute 'network vpn-connection create*' { [ordered]@{ resource = [ordered]@{ name = 'cn'; connectionStatus = 'Connecting'; sharedKey = $global:AzlVcCanary } } | ConvertTo-Json -Compress }
            (Invoke-Conn (New-InfraFile)).Rows[0].ConnectionStatus | Should -Be 'Connecting'
            Add-AzRoute 'network vpn-connection create*' { [ordered]@{ name = 'cn'; connectionStatus = 'Unknown' } | ConvertTo-Json -Compress }
            (Invoke-Conn (New-InfraFile)).Rows[0].ConnectionStatus | Should -Be 'Unknown'
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

        It 'reads its values through the toolkit loader, holds no GUID, and never uses the Az keyvault cmdlets' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
            $script:Text | Should -Not -Match 'Get-AzKeyVaultSecret|ConvertTo-SecureString|Write-Host'
        }

        It 'has every parameter registered' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($p in 'InfrastructureFile', 'LogPath') {
                ($registry -match ('New_VpnConnection_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
