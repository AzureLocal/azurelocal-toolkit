#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 04: Configure-P2sVpn.azcli.ps1 sets the point-to-site configuration of the hub VPN
# gateway (landing_zone.connectivity.vpn_gateway.point_to_site) with az commands. The root certificate is a keyvault:// reference that the script reads with
# "az keyvault secret show" only when it configures a certificate gateway; the tests give it text made up at run time. "az" is mocked: no Azure, no tenant and
# no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/P2sVpn.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-04-p2s-vpn-connection', 'azurecli', 'Configure-P2sVpn.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlPsSub = [guid]::NewGuid().ToString()
    $bytes = [byte[]]::new(48); [Random]::new().NextBytes($bytes)
    $global:AzlPsCert = [Convert]::ToBase64String($bytes)

    function New-P2sSetting([hashtable]$Override = @{}) {
        Set-AzOverride ([ordered]@{ address_pool = '192.0.2.0/24'; authentication = 'entra_id' }) $Override
    }
    function New-CertificateP2sSetting([hashtable]$Override = @{}) {
        $merged = @{ authentication = 'certificate'; root_certificate_name = 'rootcert-iic-01'; root_certificate = 'keyvault://kv-iic-mgmt-01/p2s-root-cert' }
        foreach ($k in $Override.Keys) { $merged[$k] = $Override[$k] }
        New-P2sSetting $merged
    }
    function New-InfraFile {
        param([object]$P2s = (New-P2sSetting), [object]$Tenant = $global:AzlFakeTenant, [switch]$NoGateway, [hashtable]$Network = @{}, [hashtable]$Gateway = @{})
        $gw = Set-AzOverride ([ordered]@{ name = 'vpng-iic-hub-01'; network = 'vnet-iic-hub-01'; sku = 'VpnGw1AZ'; bgp_asn = 65515 }) $Gateway
        if ($P2s) { $gw.point_to_site = $P2s }
        $net = Set-AzOverride ([ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; location = 'westeurope'; address_space = @('198.51.100.0/24') }) $Network
        $az = [ordered]@{ location = 'eastus' }
        if ($null -ne $Tenant) { $az.tenant_id = $Tenant }
        $doc = [ordered]@{
            azure        = $az
            key_vaults   = @([ordered]@{ name = 'kv-iic-mgmt-01'; subscription_id = $global:AzlPsSub; resource_group = 'rg-iic-mgmt-01' })
            landing_zone = [ordered]@{ subscriptions = @([ordered]@{ name = 'sub-iic-connectivity'; id = $global:AzlPsSub; role = 'connectivity' }); networks = @($net) }
        }
        if (-not $NoGateway) { $doc.landing_zone.connectivity = [ordered]@{ vpn_gateway = $gw } }
        Save-AzInfraFile $doc
    }
    # A gateway as az returns it, with or without a client configuration.
    function New-FakeGateway([string[]]$Pool = @(), [string[]]$Protocols = @()) {
        $g = [ordered]@{ name = 'vpng-iic-hub-01'; id = '/gateways/vpng-iic-hub-01' }
        if ($Pool.Count) { $g.vpnClientConfiguration = [ordered]@{ vpnClientAddressPool = [ordered]@{ addressPrefixes = $Pool }; vpnClientProtocols = $Protocols } }
        $g
    }
}

Describe 'Configure-P2sVpn.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlPsSub, AzlPsCert, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
        Add-AzRoute 'network vnet-gateway show*' (New-FakeGateway)
        Add-AzRoute 'keyvault secret show*' $global:AzlPsCert
    }

    Context 'Microsoft Entra ID sign-in' {
        It 'sets the pool, the OpenVPN tunnel type and the tenant, issuer and audience, on the gateway of the hub' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Configured'
            Get-AzCall "network vnet-gateway update --name vpng-iic-hub-01 --resource-group rg-iic-conn-01 --subscription $($global:AzlPsSub) --address-prefixes 192.0.2.0/24 --client-protocol OpenVPN --vpn-auth-type AAD --aad-tenant https://login.microsoftonline.com/$($global:AzlFakeTenant) --aad-issuer https://sts.windows.net/$($global:AzlFakeTenant)/ --aad-audience c632b3df-fb67-4d84-bdcf-b95ad541b5c8" | Should -HaveCount 1
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
            Get-AzCall 'account set*' | Should -BeNullOrEmpty
        }

        It 'refuses a tunnel type other than OpenVPN with exit code 2' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile (New-P2sSetting @{ protocols = @('OpenVPN', 'IkeV2') }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'OpenVPN tunnel type only'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }
    }

    Context 'certificate sign-in' {
        It 'sets the pool, both tunnel types by default and the root certificate read from the vault' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile (New-CertificateP2sSetting))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Configured'
            Get-AzCall 'keyvault secret show --vault-name kv-iic-mgmt-01 --name p2s-root-cert --query value --output tsv' | Should -HaveCount 1
            Get-AzCall "network vnet-gateway update --name vpng-iic-hub-01 --resource-group rg-iic-conn-01 --subscription $($global:AzlPsSub) --address-prefixes 192.0.2.0/24 --client-protocol OpenVPN IkeV2 --vpn-auth-type Certificate --root-cert-name rootcert-iic-01 --root-cert-data $($global:AzlPsCert)" | Should -HaveCount 1
        }

        It 'takes the tunnel types of the file' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile (New-CertificateP2sSetting @{ protocols = @('SSTP') }))
            Get-AzCall 'network vnet-gateway update*--client-protocol SSTP --vpn-auth-type Certificate*' | Should -HaveCount 1
        }

        It 'does not print, log or return the certificate data, and cleans it out of an az error text' {
            Add-AzRoute 'network vnet-gateway update*' { "ERROR: (InvalidCertificate) The data $($global:AzlPsCert) is not a certificate." } 1
            $log = Join-Path $TestDrive 'p2s.log'
            $global:LASTEXITCODE = $null
            $all = & $script:Script -InfrastructureFile (New-InfraFile (New-CertificateP2sSetting)) -LogPath $log 6>&1 3>&1 2>&1 4>&1 5>&1
            $global:LASTEXITCODE | Should -Be 1
            (@($all | ForEach-Object { "$_" | Out-String }) -join "`n") | Should -Not -Match ([regex]::Escape($global:AzlPsCert))
            (Get-Content -LiteralPath $log -Raw) | Should -Not -Match ([regex]::Escape($global:AzlPsCert))
            (@($all | ForEach-Object { "$_" }) -join "`n") | Should -Match 'InvalidCertificate'
        }

        It 'refuses <Case> with exit code 2' -ForEach @(
            @{ Case = 'no certificate name'; Override = @{ root_certificate_name = $null }; Match = 'root_certificate_name is missing' }
            @{ Case = 'no certificate reference'; Override = @{ root_certificate = $null }; Match = 'root_certificate is missing' }
            @{ Case = 'a certificate that is data, not a reference'; Override = @{ root_certificate = 'MIIBIjANBgkqhkiG9w0B' }; Match = 'not a secret reference' }
        ) {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile (New-CertificateP2sSetting $Override))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }
    }

    Context 'the gateway already has a point-to-site configuration (idempotent)' {
        It 'changes nothing and says so when the pool and the tunnel types match' {
            Add-AzRoute 'network vnet-gateway show*' (New-FakeGateway @('192.0.2.0/24') @('OpenVPN'))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyConfigured'
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'nothing changed'
        }

        It 'reports a pool or tunnel types that differ and leaves the gateway alone, without reading the certificate' {
            Add-AzRoute 'network vnet-gateway show*' (New-FakeGateway @('198.51.100.0/24') @('IkeV2'))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile (New-CertificateP2sSetting))
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Detail | Should -Match 'address pool is 198.51.100.0/24, the file says 192.0.2.0/24'
            $r.Rows[0].Detail | Should -Match 'tunnel types are IkeV2'
            Get-AzWriteCall | Should -BeNullOrEmpty
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf' {
        It 'plans the configuration, reads no certificate and writes nothing to Azure' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile (New-CertificateP2sSetting)) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldConfigure'
            Get-AzWriteCall | Should -BeNullOrEmpty
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would be set'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'p2s2.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be set'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'does nothing and exits 0 when the file has no point_to_site' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -P2s $null)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses a missing tenant, and a file without the gateway' {
            (Invoke-AzCliScript $script:Script (New-InfraFile -Tenant $null)).ExitCode | Should -Be 2
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoGateway)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'vpn_gateway is missing'
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a missing pool'; Override = @{ address_pool = $null }; Match = 'address_pool' }
            @{ Case = 'a pool that is not CIDR'; Override = @{ address_pool = '192.0.2.0' }; Match = 'address_pool' }
            @{ Case = 'a missing authentication'; Override = @{ authentication = $null }; Match = 'missing or not usable' }
            @{ Case = 'RADIUS, which this script does not build'; Override = @{ authentication = 'radius' }; Match = 'radius is not built' }
            @{ Case = 'an unknown authentication'; Override = @{ authentication = 'kerberos' }; Match = 'missing or not usable' }
            @{ Case = 'an unknown tunnel type'; Override = @{ protocols = @('PPTP') }; Match = 'is not OpenVPN, IkeV2 or SSTP' }
        ) {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile (New-P2sSetting $Override))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses a gateway whose network is not in the file, or has no subscription id' {
            (Invoke-AzCliScript $script:Script (New-InfraFile -Gateway @{ network = 'vnet-nowhere' })).Text | Should -Match 'not an entry of landing_zone.networks'
            (Invoke-AzCliScript $script:Script (New-InfraFile -Network @{ subscription = 'sub-unknown' })).Text | Should -Match 'no usable id'
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

        It 'stops when the VPN gateway does not exist' {
            Add-AzNotFound 'network vnet-gateway show*'
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Create it first'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'fails, and does not update the gateway, when the certificate cannot be read' {
            Add-AzRoute 'keyvault secret show*' 'ERROR: (SecretNotFound) not found' 3
            $r = Invoke-AzCliScript $script:Script (New-InfraFile (New-CertificateP2sSetting))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            Get-AzCall 'network vnet-gateway update*' | Should -BeNullOrEmpty
        }

        It 'refuses, with exit code 2, certificate data that holds a character az.cmd cannot carry, and does not update the gateway' -ForEach @(
            @{ Name = 'an ampersand'; Data = 'Canary&calc' }
            @{ Name = 'a percent sign'; Data = 'Canary%PATH%x' }
            @{ Name = 'a line break'; Data = "Canary`nx" }
        ) {
            Add-AzRoute 'keyvault secret show*' $Data
            $r = Invoke-AzCliScript $script:Script (New-InfraFile (New-CertificateP2sSetting))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'keyvault://kv-iic-mgmt-01/p2s-root-cert'
            ($r.Text + ($r.Rows | Out-String)) | Should -Not -Match 'Canary'
            Get-AzCall 'network vnet-gateway update*' | Should -BeNullOrEmpty
            @($global:AzlFakeCalls | Where-Object { $_ -match 'Canary' }) | Should -BeNullOrEmpty
        }

        It 'refuses, at plan time and also under -WhatIf, a certificate reference whose vault is not listed under key_vaults, and a root certificate name with an ampersand' {
            foreach ($dry in $false, $true) {
                $global:AzlFakeCalls.Clear()
                $file = New-InfraFile (New-CertificateP2sSetting @{ root_certificate = 'keyvault://kv-iic-other-01/p2s-root-cert' })
                $r = if ($dry) { Invoke-AzCliScript $script:Script $file -DryRun } else { Invoke-AzCliScript $script:Script $file }
                $r.ExitCode | Should -Be 2 -Because $r.Text
                $r.Text | Should -Match 'not listed under key_vaults'
                $global:AzlFakeCalls | Should -BeNullOrEmpty
                $file = New-InfraFile (New-CertificateP2sSetting @{ root_certificate_name = 'root&cert' })
                $r = if ($dry) { Invoke-AzCliScript $script:Script $file -DryRun } else { Invoke-AzCliScript $script:Script $file }
                $r.ExitCode | Should -Be 2 -Because $r.Text
                $r.Text | Should -Match "root_certificate_name holds the value 'root&cert'"
                $global:AzlFakeCalls | Should -BeNullOrEmpty
            }
        }

        It 'reports an update that fails and exits 1' {
            Add-AzRoute 'network vnet-gateway update*' 'ERROR: (GatewayNotReady) The gateway is not ready.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'GatewayNotReady'
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

        It 'reads its values through the toolkit loader and holds no GUID but the Azure VPN Client application of Microsoft' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $guids = [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}') | ForEach-Object { $_.Value } | Select-Object -Unique
            @($guids | Where-Object { $_ -ne 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8' }) | Should -BeNullOrEmpty
        }

        It 'has every parameter registered' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($p in 'InfrastructureFile', 'LogPath') {
                ($registry -match ('Configure_P2sVpn_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
