#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# What the Arc registration of an ISO-installed node passes: the proxy and its bypass list (scenario.outbound_path proxy, proxy_arc_gateway or private_path),
# the Arc gateway of the private path, and the solution version. No node, no Azure: Invoke-AzlNodeScript, the token and the Arc lookup are replaced, and the
# node payload runs in this session against a stand-in for Invoke-AzStackHciArcInitialization.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/ArcRegistrationSetting.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A module mock runs in the module scope; a global is how it reports back to the test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test fixture credential, not a secret.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The stand-in cmdlet keeps the parameters of the real one.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $dir = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'common', 'node-configuration')
    Import-Module (Join-Path $dir 'AzlOsConfigurationRun.psm1') -Force
    Import-Module (Join-Path $dir 'AzlNodePayload.psm1') -Force

    # An infrastructure file reduced to what the registration reads.
    function New-Infra([string]$Path, [hashtable]$Outbound = @{}, [string]$Version = '') {
        $infra = [ordered]@{
            azure      = [ordered]@{ subscription_id = '00000000-0000-0000-0000-000000000000'; resource_group = 'rg-iic-azl-01'; tenant_id = '00000000-0000-0000-0000-000000000001'; location = 'eastus' }
            scenario   = [ordered]@{ outbound_path = $Path }
            networking = [ordered]@{ outbound = $Outbound }
        }
        if ($Version) { $infra['deployment'] = [ordered]@{ solution_version = $Version } }
        $infra
    }
    $script:Gateway = @{ name = 'iic-arcgw-01'; resource_group = 'rg-iic-azl-01' }
}

Describe 'Get-AzlArcRegistrationSetting' {
    It 'passes nothing for a direct path' {
        $s = InModuleScope AzlOsConfigurationRun -Parameters @{ I = (New-Infra 'direct' @{ proxy = @{ url = 'http://proxy.example.test:3128' } }) } { Get-AzlArcRegistrationSetting -Infrastructure $I }
        $s.Proxy | Should -Be ''
        $s.ProxyBypass | Should -Be ''
        $s.Problem | Should -Be ''
    }
    It 'passes the proxy url and the bypass list joined with commas for a proxy path' -ForEach @('proxy', 'proxy_arc_gateway') {
        $infra = New-Infra $_ @{ proxy = @{ url = 'http://proxy.example.test:3128'; bypass = @('localhost', '192.0.2.*', '*.example.test') } }
        $s = InModuleScope AzlOsConfigurationRun -Parameters @{ I = $infra } { Get-AzlArcRegistrationSetting -Infrastructure $I }
        $s.Proxy | Should -Be 'http://proxy.example.test:3128'
        $s.ProxyBypass | Should -Be 'localhost,192.0.2.*,*.example.test'
        $s.Problem | Should -Be ''
    }
    It 'names the key when a proxy path has no url' {
        $s = InModuleScope AzlOsConfigurationRun -Parameters @{ I = (New-Infra 'proxy' @{}) } { Get-AzlArcRegistrationSetting -Infrastructure $I }
        $s.Problem | Should -Match 'networking\.outbound\.proxy\.url'
        $s.Proxy | Should -Be ''
    }
    It 'uses the firewall address and port as the proxy server of the private path, with the bypass list of the private path' {
        $infra = New-Infra 'private_path' @{ private_path = @{ firewall_private_ip = '198.51.100.4'; firewall_port = 8080; proxy_bypass = @('localhost', '192.0.2.*') } }
        $s = InModuleScope AzlOsConfigurationRun -Parameters @{ I = $infra } { Get-AzlArcRegistrationSetting -Infrastructure $I }
        $s.Proxy | Should -Be 'http://198.51.100.4:8080'
        $s.ProxyBypass | Should -Be 'localhost,192.0.2.*'
        $s.Problem | Should -Be ''
    }
    It 'names the keys when the private path has no firewall address or port' -ForEach @(@{ Missing = 'ip' }, @{ Missing = 'port' }) {
        $pp = @{ firewall_private_ip = '198.51.100.4'; firewall_port = 8080 }
        if ($Missing -eq 'ip') { $pp.Remove('firewall_private_ip') } else { $pp.Remove('firewall_port') }
        $s = InModuleScope AzlOsConfigurationRun -Parameters @{ I = (New-Infra 'private_path' @{ private_path = $pp }) } { Get-AzlArcRegistrationSetting -Infrastructure $I }
        $s.Problem | Should -Match 'firewall_private_ip or firewall_port'
        $s.Proxy | Should -Be ''
    }
    It 'passes deployment.solution_version only when it has four numeric parts' -ForEach @(
        @{ Version = '12.2610.1004.50'; Expected = '12.2610.1004.50' }
        @{ Version = 'latest'; Expected = '' }
        @{ Version = ''; Expected = '' }
    ) {
        $s = InModuleScope AzlOsConfigurationRun -Parameters @{ I = (New-Infra 'direct' @{} $Version) } { Get-AzlArcRegistrationSetting -Infrastructure $I }
        $s.TargetSolutionVersion | Should -Be $Expected
    }
}

Describe 'Invoke-AzlArcRegistration passes the settings to the node' {
    BeforeEach {
        $global:ArcSettingParameters = $null
        Mock -ModuleName AzlOsConfigurationRun Start-Sleep { }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlArmToken { [pscustomobject]@{ Token = 'token-1'; AccountId = 'operator@example.invalid' } }
        Mock -ModuleName AzlOsConfigurationRun New-AzlWinRmTransport { [pscustomobject]@{ Kind = 'WinRM' } }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlNodePayload { 'arc-registration-script' }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript { $global:ArcSettingParameters = $Parameters }
        Mock -ModuleName AzlOsConfigurationRun Find-AzlArcMachine { [pscustomobject]@{ Name = 'iic-n02'; ResourceId = '/subscriptions/x/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/iic-n02'; Status = 'Connected' } }
        Mock -ModuleName AzlOsConfigurationRun Send-AzlRunEvent { }
        $script:Record = [ordered]@{ name = 'iic-n02'; address = '192.0.2.12' }
        $script:Node = [ordered]@{ name = 'iic-n02' }
    }
    AfterAll { Remove-Variable ArcSettingParameters -Scope Global -ErrorAction SilentlyContinue }

    It 'sends the proxy, the bypass list, the solution version and the Arc gateway for a proxy with an Arc gateway' {
        $infra = New-Infra 'proxy_arc_gateway' @{ proxy = @{ url = 'http://proxy.example.test:3128'; bypass = @('localhost', '192.0.2.*') }; arc_gateway = $script:Gateway } '12.2610.1004.50'
        $context = [pscustomobject]@{ Infra = $infra; CredentialInfo = [pscustomobject]@{ Credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }; EventLogPath = '' }
        $null = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N }
        $p = $global:ArcSettingParameters
        $p.proxy | Should -Be 'http://proxy.example.test:3128'
        $p.proxyBypass | Should -Be 'localhost,192.0.2.*'
        $p.targetSolutionVersion | Should -Be '12.2610.1004.50'
        $p.arcGatewayId | Should -Match '/providers/Microsoft\.HybridCompute/gateways/iic-arcgw-01$'
    }
    It 'sends the firewall as the proxy and the Arc gateway for the private path' {
        $infra = New-Infra 'private_path' @{ private_path = @{ firewall_private_ip = '198.51.100.4'; firewall_port = 8080; proxy_bypass = @('localhost') }; arc_gateway = $script:Gateway }
        $context = [pscustomobject]@{ Infra = $infra; CredentialInfo = [pscustomobject]@{ Credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }; EventLogPath = '' }
        $null = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N }
        $p = $global:ArcSettingParameters
        $p.proxy | Should -Be 'http://198.51.100.4:8080'
        $p.proxyBypass | Should -Be 'localhost'
        $p.arcGatewayId | Should -Match 'gateways/iic-arcgw-01$'
    }
    It 'sends no proxy for a direct path' {
        $context = [pscustomobject]@{ Infra = (New-Infra 'direct' @{}); CredentialInfo = [pscustomobject]@{ Credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }; EventLogPath = '' }
        $null = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N }
        $global:ArcSettingParameters.proxy | Should -Be ''
        $global:ArcSettingParameters.targetSolutionVersion | Should -Be ''
    }
    It 'refuses before it touches the node when the private path has no firewall address' {
        $context = [pscustomobject]@{ Infra = (New-Infra 'private_path' @{ arc_gateway = $script:Gateway }); CredentialInfo = [pscustomobject]@{ Credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }; EventLogPath = '' }
        { InModuleScope AzlOsConfigurationRun -Parameters @{ C = $context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N } } | Should -Throw '*firewall_private_ip*'
        Should -Invoke -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript -Times 0 -Exactly
    }
}

Describe 'The Arc registration plan item' {
    BeforeEach { Mock -ModuleName AzlOsConfigurationRun Find-AzlArcMachine { $null } }
    It 'is blocked, with the key named, when the path needs a proxy value the file does not give' {
        $context = [pscustomobject]@{ Infra = (New-Infra 'proxy' @{}) }
        $record = [ordered]@{ name = 'iic-n02'; evidence = [pscustomobject]@{ ArcResourceId = '' } }
        $item = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $context; R = $record } { Get-AzlArcRegistrationItem -Context $C -Record $R -Node ([ordered]@{ name = 'iic-n02' }) }
        $item.Action | Should -Be 'Blocked'
        $item.Note | Should -Match 'networking\.outbound\.proxy\.url'
    }
    It 'says which proxy it passes' {
        $context = [pscustomobject]@{ Infra = (New-Infra 'proxy' @{ proxy = @{ url = 'http://proxy.example.test:3128' } }) }
        $record = [ordered]@{ name = 'iic-n02'; evidence = [pscustomobject]@{ ArcResourceId = '' } }
        $item = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $context; R = $record } { Get-AzlArcRegistrationItem -Context $C -Record $R -Node ([ordered]@{ name = 'iic-n02' }) }
        $item.Action | Should -Be 'Change'
        $item.Note | Should -Match 'http://proxy\.example\.test:3128'
    }
}

Describe 'The ArcRegistration node script' {
    BeforeAll {
        # A stand-in for the cmdlet the Azure Local OS ships; it records what it was called with.
        function global:Invoke-AzStackHciArcInitialization {
            [CmdletBinding()]
            param($SubscriptionID, $ResourceGroup, $TenantID, $Region, $Cloud, $ArmAccessToken, $AccountID, $ArcGatewayID, $Proxy, $ProxyBypass, $TargetSolutionVersion)
            $global:ArcPayloadCall = $PSBoundParameters
        }
        function Invoke-Payload([hashtable]$Parameters) {
            $encode = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))) }
            $global:ArcPayloadCall = $null
            $block = [scriptblock]::Create((Get-AzlNodePayload -Name ArcRegistration))
            $null = & $block -ParamsB64 (& $encode $Parameters) -SecretsB64 (& $encode @{ armToken = 'token-1' })
            $global:ArcPayloadCall
        }
    }
    AfterAll {
        Remove-Item Function:\global:Invoke-AzStackHciArcInitialization -ErrorAction SilentlyContinue
        Remove-Variable ArcPayloadCall -Scope Global -ErrorAction SilentlyContinue
    }
    It 'passes Proxy, ProxyBypass and TargetSolutionVersion when they are given' {
        $call = Invoke-Payload @{ subscriptionId = 's'; resourceGroup = 'g'; tenantId = 't'; region = 'r'; accountId = 'a'; proxy = 'http://proxy.example.test:3128'; proxyBypass = 'localhost,192.0.2.*'; targetSolutionVersion = '12.2610.1004.50'; arcGatewayId = '' }
        $call['Proxy'] | Should -Be 'http://proxy.example.test:3128'
        $call['ProxyBypass'] | Should -Be 'localhost,192.0.2.*'
        $call['TargetSolutionVersion'] | Should -Be '12.2610.1004.50'
        $call.ContainsKey('ArcGatewayID') | Should -BeFalse
    }
    It 'passes none of them when they are empty' {
        $call = Invoke-Payload @{ subscriptionId = 's'; resourceGroup = 'g'; tenantId = 't'; region = 'r'; accountId = 'a'; proxy = ''; proxyBypass = 'ignored'; targetSolutionVersion = ''; arcGatewayId = '' }
        $call.ContainsKey('Proxy') | Should -BeFalse
        $call.ContainsKey('ProxyBypass') | Should -BeFalse -Because 'a bypass list without a proxy means nothing'
        $call.ContainsKey('TargetSolutionVersion') | Should -BeFalse
    }
}
