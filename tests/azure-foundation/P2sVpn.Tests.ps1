#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 04: Configure-P2sVpn.ps1 sets the point-to-site configuration of
# landing_zone.connectivity.vpn_gateway.point_to_site on the hub VPN gateway. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used.
# Ids are generated per run; the certificate data is an environment variable the test sets.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/P2sVpn.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-04-p2s-vpn-connection', 'powershell', 'Configure-P2sVpn.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzVirtualNetworkGateway { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzVpnClientRootCertificate { [CmdletBinding()] param([string]$Name, [string]$PublicCertData) }
    function Set-AzVirtualNetworkGateway {
        [CmdletBinding(SupportsShouldProcess)]
        param([object]$VirtualNetworkGateway, [string[]]$VpnClientAddressPool, [string[]]$VpnClientProtocol, [string[]]$VpnAuthenticationType, [object[]]$VpnClientRootCertificates, [string]$AadTenantUri, [string]$AadAudienceId, [string]$AadIssuerUri)
    }

    $global:AzlP2sTenant = [guid]::NewGuid().ToString()
    $global:AzlP2sSub = [guid]::NewGuid().ToString()
    $global:AzlP2sHome = [guid]::NewGuid().ToString()
    $global:AzlP2sCert = 'MIIC' + [guid]::NewGuid().ToString('N')
    $env:AZL_TEST_P2S_CERT = $global:AzlP2sCert

    function New-InfraFile {
        param([hashtable]$PointToSite = @{ address_pool = '172.16.201.0/24'; authentication = 'entra_id' }, [hashtable]$Azure = @{}, [switch]$NoPointToSite)
        $az = [ordered]@{ tenant_id = $global:AzlP2sTenant; location = 'eastus' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $gw = [ordered]@{ name = 'vpng-iic-hub-01'; network = 'vnet-iic-hub-01'; sku = 'VpnGw1AZ'; bgp_asn = 65515 }
        if (-not $NoPointToSite) { $p = [ordered]@{}; foreach ($k in $PointToSite.Keys) { if ($null -ne $PointToSite[$k]) { $p[$k] = $PointToSite[$k] } }; $gw.point_to_site = $p }
        $doc = [ordered]@{
            azure        = $az
            landing_zone = [ordered]@{
                subscriptions = @([ordered]@{ name = 'sub-iic-connectivity'; id = $global:AzlP2sSub; role = 'connectivity' })
                networks      = @([ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; address_space = @('10.20.0.0/22') })
                connectivity  = [ordered]@{ vpn_gateway = $gw }
            }
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-P2s([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode   = $code
            Row        = @($all | Where-Object { $_.PSObject.Properties['Authentication'] -and $_.PSObject.Properties['Action'] })[0]
            Text       = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
            Everything = (@($all | ForEach-Object { "$_" | Out-String }) -join "`n")
        }
    }
    $script:Cert = @{ address_pool = '172.16.201.0/24'; authentication = 'certificate'; root_certificate_name = 'P2SRootCert'; root_certificate = 'env://AZL_TEST_P2S_CERT' }
}

Describe 'Configure-P2sVpn.ps1' {
    AfterAll { Remove-Variable -Name AzlP2sTenant, AzlP2sSub, AzlP2sHome, AzlP2sCert -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_P2S_CERT -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlP2sTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlP2sHome } } }
        Mock Set-AzContext { }
        Mock Get-AzVirtualNetworkGateway { [pscustomobject]@{ Name = $Name; VpnClientConfiguration = $null } }
        Mock New-AzVpnClientRootCertificate { [pscustomobject]@{ Name = $Name; PublicCertData = $PublicCertData } }
        Mock Set-AzVirtualNetworkGateway { }
    }

    Context 'Microsoft Entra ID sign-in' {
        It 'sets the pool, the OpenVPN tunnel type and the tenant, issuer and audience Learn names' {
            $r = Invoke-P2s (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Row.Action | Should -Be 'Configured'
            Should -Invoke Set-AzVirtualNetworkGateway -Times 1 -Exactly -ParameterFilter {
                @($VpnClientAddressPool) -contains '172.16.201.0/24' -and @($VpnClientProtocol) -contains 'OpenVPN' -and @($VpnClientProtocol).Count -eq 1 -and @($VpnAuthenticationType) -contains 'AAD' -and
                $AadTenantUri -eq "https://login.microsoftonline.com/$($global:AzlP2sTenant)" -and $AadIssuerUri -eq "https://sts.windows.net/$($global:AzlP2sTenant)/" -and $AadAudienceId -eq 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'
            }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlP2sHome }
        }

        It 'refuses a tunnel type other than OpenVPN' {
            $r = Invoke-P2s (New-InfraFile @{ address_pool = '172.16.201.0/24'; authentication = 'entra_id'; protocols = @('IkeV2') })
            $r.ExitCode | Should -Be 2
            Should -Invoke Set-AzVirtualNetworkGateway -Times 0 -Exactly
        }
    }

    Context 'certificate sign-in' {
        It 'sets the pool, the default tunnel types and the root certificate read from its secret reference' {
            $r = Invoke-P2s (New-InfraFile $script:Cert)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke New-AzVpnClientRootCertificate -Times 1 -Exactly -ParameterFilter { $Name -eq 'P2SRootCert' -and $PublicCertData -eq $global:AzlP2sCert }
            Should -Invoke Set-AzVirtualNetworkGateway -Times 1 -Exactly -ParameterFilter { @($VpnAuthenticationType) -contains 'Certificate' -and @($VpnClientProtocol) -contains 'OpenVPN' -and @($VpnClientProtocol) -contains 'IkeV2' -and @($VpnClientRootCertificates).Count -eq 1 }
        }

        It 'uses the tunnel types of the file' {
            $null = Invoke-P2s (New-InfraFile ($script:Cert + @{ protocols = @('SSTP', 'OpenVPN') }))
            Should -Invoke Set-AzVirtualNetworkGateway -Times 1 -Exactly -ParameterFilter { @($VpnClientProtocol) -contains 'SSTP' -and @($VpnClientProtocol) -contains 'OpenVPN' -and @($VpnClientProtocol) -notcontains 'IkeV2' }
        }

        It 'does not print or return the certificate data' {
            (Invoke-P2s (New-InfraFile $script:Cert)).Everything | Should -Not -Match ([regex]::Escape($global:AzlP2sCert))
        }
    }

    Context 'a gateway that has a point-to-site configuration (idempotent, never destructive)' {
        It 'changes nothing when it matches the file' {
            Mock Get-AzVirtualNetworkGateway { [pscustomobject]@{ Name = $Name; VpnClientConfiguration = [pscustomobject]@{ VpnClientAddressPool = [pscustomobject]@{ AddressPrefixes = @('172.16.201.0/24') }; VpnClientProtocols = @('OpenVPN') } } }
            $r = Invoke-P2s (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'AlreadyConfigured'
            $r.Row.Detail | Should -BeNullOrEmpty
            Should -Invoke Set-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'reports a difference and changes nothing' {
            Mock Get-AzVirtualNetworkGateway { [pscustomobject]@{ Name = $Name; VpnClientConfiguration = [pscustomobject]@{ VpnClientAddressPool = [pscustomobject]@{ AddressPrefixes = @('172.16.9.0/24') }; VpnClientProtocols = @('IkeV2') } } }
            $r = Invoke-P2s (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Row.Detail | Should -Match 'address pool is 172\.16\.9\.0/24'
            $r.Row.Detail | Should -Match 'tunnel types are IkeV2'
            Should -Invoke Set-AzVirtualNetworkGateway -Times 0 -Exactly
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans the change, changes nothing and does not read the certificate' {
            $env:AZL_TEST_P2S_CERT = $null
            try { $r = Invoke-P2s (New-InfraFile $script:Cert) -DryRun }
            finally { $env:AZL_TEST_P2S_CERT = $global:AzlP2sCert }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Row.Action | Should -Be 'WouldConfigure'
            Should -Invoke Set-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the file has no point_to_site' {
            $r = Invoke-P2s (New-InfraFile -NoPointToSite)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'no address pool'; P2s = @{ authentication = 'entra_id' } }
            @{ Why = 'an address pool that is not CIDR'; P2s = @{ address_pool = '172.16.201.0'; authentication = 'entra_id' } }
            @{ Why = 'no authentication'; P2s = @{ address_pool = '172.16.201.0/24' } }
            @{ Why = 'RADIUS, which is not built'; P2s = @{ address_pool = '172.16.201.0/24'; authentication = 'radius' } }
            @{ Why = 'a tunnel type that does not exist'; P2s = @{ address_pool = '172.16.201.0/24'; authentication = 'certificate'; root_certificate_name = 'x'; root_certificate = 'env://X'; protocols = @('L2TP') } }
            @{ Why = 'certificate sign-in without a certificate name'; P2s = @{ address_pool = '172.16.201.0/24'; authentication = 'certificate'; root_certificate = 'env://AZL_TEST_P2S_CERT' } }
            @{ Why = 'certificate sign-in without a certificate'; P2s = @{ address_pool = '172.16.201.0/24'; authentication = 'certificate'; root_certificate_name = 'x' } }
            @{ Why = 'certificate data that is not a secret reference'; P2s = @{ address_pool = '172.16.201.0/24'; authentication = 'certificate'; root_certificate_name = 'x'; root_certificate = 'MIICabc' } }
        ) {
            $r = Invoke-P2s (New-InfraFile $P2s)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke Set-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            (Invoke-P2s (New-InfraFile -Azure @{ tenant_id = $null })).ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-P2s (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-P2s (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke Set-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'stops when the VPN gateway does not exist' {
            Mock Get-AzVirtualNetworkGateway { throw "The Resource 'Microsoft.Network/virtualNetworkGateways/x' was not found (404 NotFound)." }
            $r = Invoke-P2s (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Deploy-VpnGateway'
            Should -Invoke Set-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'reports a certificate that cannot be read and changes nothing' {
            $missing = $script:Cert.Clone(); $missing.root_certificate = 'env://AZL_TEST_P2S_CERT_MISSING'
            $r = Invoke-P2s (New-InfraFile $missing)
            $r.ExitCode | Should -Be 1
            $r.Row.Action | Should -Be 'Failed'
            Should -Invoke Set-AzVirtualNetworkGateway -Times 0 -Exactly
        }

        It 'reports a failed change and puts the subscription back' {
            Mock Set-AzVirtualNetworkGateway { throw 'AuthorizationFailed' }
            $r = Invoke-P2s (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Row.Action | Should -Be 'Failed'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlP2sHome }
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

        It 'reads its values through the toolkit loader, never the old layout, and holds no address and no GUID but the Microsoft-registered Azure VPN Client application' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml|azure\.vpn_gateway|root_cert_secret_name'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            @([regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Value | Select-Object -Unique) | Should -Be @('c632b3df-fb67-4d84-bdcf-b95ad541b5c8')
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Configure_P2sVpn_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'landing_zone.connectivity.vpn_gateway.name', 'landing_zone.connectivity.vpn_gateway.resource_group', 'landing_zone.connectivity.vpn_gateway.network', 'landing_zone.connectivity.vpn_gateway.point_to_site.address_pool', 'landing_zone.connectivity.vpn_gateway.point_to_site.authentication', 'landing_zone.connectivity.vpn_gateway.point_to_site.protocols', 'landing_zone.connectivity.vpn_gateway.point_to_site.root_certificate_name', 'landing_zone.connectivity.vpn_gateway.point_to_site.root_certificate', 'landing_zone.networks[].name', 'landing_zone.networks[].subscription', 'landing_zone.networks[].resource_group', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
