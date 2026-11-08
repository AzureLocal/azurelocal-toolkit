#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the vendor-neutral Redfish discovery core (scripts/common/redfish/AzlRedfishCore.psm1): the read-only HTTP layer,
# error classification, retries, session handling, secret redaction, vendor detection, the capability report and bounded
# parallelism. A fake BMC answers from the SYNTHETIC fixture trees in tests/fixtures/redfish/dell; no BMC, node or Azure
# resource is touched. Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/discovery

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks run in module scope and read the fake BMC through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test values only.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    . (Join-Path $PSScriptRoot 'RedfishFakeBmc.ps1')
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')) -Force
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishDell.psm1')) -Force
    $script:Password = 'doc-pass-123'
    $script:Cred = [pscredential]::new('doc-user', (ConvertTo-SecureString $script:Password -AsPlainText -Force))
    function Invoke-Scan {
        param([string]$Detail = 'Full', [string]$Vendor = 'Auto', [switch]$UseSession, [switch]$VerifyCertificate)
        Invoke-AzlRedfishDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail $Detail -Vendor $Vendor -UseSession:$UseSession -VerifyCertificate:$VerifyCertificate -RetryDelaySeconds 0
    }
}

Describe 'HTTP layer is read only' {
    BeforeEach {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
    }
    AfterAll { Remove-FakeBmc }

    It 'has no way to ask for another method' {
        (Get-Command Invoke-AzlRedfishRequest).Parameters.Keys | Should -Not -Contain 'Method'
        (Get-Command Invoke-AzlRedfishRequest).Parameters.Keys | Should -Not -Contain 'Body'
        (Get-Command Read-AzlRedfishResource).Parameters.Keys | Should -Not -Contain 'Method'
    }
    It 'sends only GET for a full scan: no PATCH, POST, PUT or DELETE reaches the HTTP layer (<Fixture>)' -ForEach @(
        @{ Fixture = 'idrac9-ax760-synthetic' }, @{ Fixture = 'idrac9-newschema-synthetic' }
    ) {
        Use-FakeBmc -Fixture $Fixture
        Invoke-Scan -Detail Full | Out-Null
        $calls = Get-FakeCall
        $calls.Count | Should -BeGreaterThan 50
        @($calls | Where-Object Method -ne 'Get').Count | Should -Be 0
    }
    It 'sends only GET for a summary scan' {
        Invoke-Scan -Detail Summary | Out-Null
        @(Get-FakeCall | Where-Object Method -ne 'Get').Count | Should -Be 0
    }
    It 'fails the check if a non-GET request were made (the guard itself works)' {
        # Prove the assertion above can fail: issue a Delete through the HTTP function and see it recorded.
        InModuleScope AzlRedfishCore {
            $ctx = New-AzlRedfishContext -BmcAddress 'bmc.invalid' -Credential ([pscredential]::new('u', (ConvertTo-SecureString 'doc-pass-123' -AsPlainText -Force)))
            Send-AzlRedfishHttp -Context $ctx -Path '/redfish/v1/x' -Method Delete | Out-Null
        }
        @(Get-FakeCall | Where-Object Method -ne 'Get').Count | Should -Be 1
    }
    It 'uses Basic auth with the credential object and a self-signed certificate is accepted unless asked' {
        Invoke-Scan -Detail Summary | Out-Null
        $c = Get-FakeCall 'Get'
        @($c | Where-Object { -not $_.Basic }).Count | Should -Be 0
        @($c | Where-Object { -not $_.SkipCertificateCheck }).Count | Should -Be 0
        @($c | Where-Object { -not $_.SkipHttpErrorCheck }).Count | Should -Be 0
        $global:AzlTestBmc.Calls.Clear()
        Invoke-Scan -Detail Summary -VerifyCertificate | Out-Null
        @(Get-FakeCall | Where-Object SkipCertificateCheck).Count | Should -Be 0
    }
    It 'sets the request timeout' {
        Invoke-Scan -Detail Summary | Out-Null
        $first = Get-FakeCall | Select-Object -First 1
        $first.OperationTimeoutSeconds | Should -Be 60
        $first.ConnectTimeoutSeconds | Should -Be 10
    }
    It 'reads each path once (the cache)' {
        Invoke-Scan -Detail Full | Out-Null
        $paths = Get-FakeCall | ForEach-Object Path
        @($paths | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
    }
    It 'never follows a link to another host' {
        Set-FakeResource '/redfish/v1/Systems' @{ Members = @(@{ '@odata.id' = 'https://other.invalid/redfish/v1/Systems/1' }) }
        { Invoke-Scan -Detail Summary } | Should -Throw '*could not be read*'
        @(Get-FakeCall | Where-Object { $_.Uri -match 'other.invalid' }).Count | Should -Be 0
    }
}

Describe 'Errors become capabilities and readErrors' {
    BeforeEach {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
    }
    AfterAll { Remove-FakeBmc }

    It 'maps <Code> on a resource to <Kind>' -ForEach @(
        @{ Code = 404; Kind = 'notSupported' }, @{ Code = 501; Kind = 'notSupported' }, @{ Code = 401; Kind = 'denied' }, @{ Code = 403; Kind = 'denied' }, @{ Code = 500; Kind = 'error' }, @{ Code = 503; Kind = 'error' }
    ) {
        $global:AzlTestBmc.Status['/redfish/v1/Systems/System.Embedded.1/Bios'] = $Code
        if ($Code -eq 401) { $global:AzlTestBmc.Status['/redfish/v1/Systems/System.Embedded.1/Bios'] = 401 }
        $r = Invoke-Scan -Detail Full
        $e = @($r.readErrors | Where-Object path -like '*/Bios')
        $e.Count | Should -Be 1
        $e[0].kind | Should -Be $Kind
        $e[0].status | Should -Be $Code
        $r.capabilities.areas.bios.status | Should -Be $Kind
        $r.capabilities.areas.bios.reason | Should -Match 'Bios'
        $r.capabilities.complete | Should -Be ($Kind -eq 'notSupported')
    }
    It 'marks an area partial when only some of its resources fail' {
        $global:AzlTestBmc.Status['/redfish/v1/Systems/System.Embedded.1/Storage/CPU.1/Drives/Disk.Bay.0:Enclosure.Internal.0-1'] = 500
        $r = Invoke-Scan -Detail Full
        $r.capabilities.areas.storage.status | Should -Be 'partial'
        $r.capabilities.complete | Should -BeFalse
        @($r.storage.drives).Count | Should -Be 5
        @($r.readErrors | Where-Object { $_.area -eq 'storage' -and $_.kind -eq 'error' }).Count | Should -Be 1
    }
    It 'carries on after a failed section and still reports the rest' {
        $global:AzlTestBmc.Status['/redfish/v1/UpdateService/FirmwareInventory'] = 403
        $r = Invoke-Scan -Detail Full
        $r.capabilities.areas.firmware.status | Should -Be 'denied'
        @($r.firmware).Count | Should -Be 0
        $r.identity.serviceTag | Should -Be 'DOCTAG1'
        @($r.network.adapters).Count | Should -Be 3
    }
    It 'marks an area notSupported when the BMC does not link the resource' {
        $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
        $sys.Remove('Bios')
        Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
        $r = Invoke-Scan -Detail Full
        $r.capabilities.areas.bios.status | Should -Be 'notSupported'
        $r.capabilities.areas.bios.reason | Should -Match 'Bios'
        $r.settings.bios | Should -BeNullOrEmpty
    }
    It 'retries a timeout once and reports it as retried' {
        $global:AzlTestBmc.Throw['/redfish/v1/UpdateService'] = @{ Message = 'The request was canceled due to the configured HttpClient.Timeout'; Times = 1 }
        $r = Invoke-Scan -Detail Full
        $r.capabilities.areas.firmware.status | Should -Be 'ok'
        @(Get-FakeCall | Where-Object Path -eq '/redfish/v1/UpdateService').Count | Should -Be 2
    }
    It 'reports a timeout that persists as error with the retry noted' {
        $global:AzlTestBmc.Throw['/redfish/v1/UpdateService'] = @{ Message = 'The request was canceled due to the configured HttpClient.Timeout'; Times = 9 }
        $r = Invoke-Scan -Detail Full
        $e = @($r.readErrors | Where-Object path -eq '/redfish/v1/UpdateService')
        $e[0].kind | Should -Be 'error'
        $e[0].retried | Should -BeTrue
        $e[0].message | Should -Match 'Timeout'
    }
    It 'stops after three rejected logins in a row, without printing the password' {
        $ctx = New-AzlRedfishContext -BmcAddress 'bmc.invalid' -Credential $script:Cred -MaxRetries 0
        '/redfish/v1/A', '/redfish/v1/B', '/redfish/v1/C' | ForEach-Object { $global:AzlTestBmc.Status[$_] = 401 }
        Invoke-AzlRedfishRequest -Context $ctx -Path '/redfish/v1/A' | Out-Null
        Invoke-AzlRedfishRequest -Context $ctx -Path '/redfish/v1/B' | Out-Null
        $err = $null
        try { Invoke-AzlRedfishRequest -Context $ctx -Path '/redfish/v1/C' | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Match 'Authentication was rejected 3 times'
        $err | Should -Not -Match $script:Password
    }
    It 'a success resets the rejected-login count' {
        $ctx = New-AzlRedfishContext -BmcAddress 'bmc.invalid' -Credential $script:Cred -MaxRetries 0
        '/redfish/v1/A', '/redfish/v1/B' | ForEach-Object { $global:AzlTestBmc.Status[$_] = 401 }
        Invoke-AzlRedfishRequest -Context $ctx -Path '/redfish/v1/A' | Out-Null
        Invoke-AzlRedfishRequest -Context $ctx -Path '/redfish/v1/B' | Out-Null
        Invoke-AzlRedfishRequest -Context $ctx -Path '/redfish/v1' | Out-Null
        $global:AzlTestBmc.Status['/redfish/v1/C'] = 401
        { Invoke-AzlRedfishRequest -Context $ctx -Path '/redfish/v1/C' } | Should -Not -Throw
    }
    It 'says the credentials were rejected when the service root answers 401' {
        $global:AzlTestBmc.Status['/redfish/v1'] = 401
        { Invoke-Scan } | Should -Throw '*rejected the credentials (HTTP 401)*'
    }
    It 'explains a rejected system collection instead of saying there is no system' {
        $global:AzlTestBmc.Status['/redfish/v1/Systems'] = 403
        { Invoke-Scan } | Should -Throw '*could not be read: denied (HTTP 403)*'
    }
    It 'throws when the service root cannot be read' {
        Remove-FakeResource '/redfish/v1'
        { Invoke-Scan } | Should -Throw '*did not return the Redfish service root*'
    }
    It 'throws when the system cannot be read' {
        Remove-FakeResource '/redfish/v1/Systems/System.Embedded.1'
        { Invoke-Scan } | Should -Throw '*could not be read*'
    }
}

Describe 'Secrets never reach the output' {
    BeforeAll {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $script:Json = (Invoke-Scan -Detail Full | ConvertTo-Json -Depth 40)
    }
    AfterAll { Remove-FakeBmc }
    It 'holds neither the login password nor a session token' {
        $script:Json | Should -Not -Match $script:Password
        $script:Json | Should -Not -Match 'doc-session-token'
        $script:Json | Should -Not -Match '(?i)authorization'
    }
    It 'redacts secret-looking BIOS and BMC attribute values but keeps the keys' {
        $r = $script:Json | ConvertFrom-Json
        $r.settings.bios.attributes.SysPassword | Should -Be '<redacted>'
        $r.settings.bmc.attributes.'SNMP.1.AgentCommunity' | Should -Be '<redacted>'
        $r.settings.bmc.attributes.'Users.2.Password' | Should -Be '<redacted>'
        $r.settings.bios.attributes.ProcVirtualization | Should -Be 'Enabled'
        $script:Json | Should -Not -Match 'doc-redaction-check'
    }
    It 'Remove-AzlRedfishSecret keeps null secrets null and does not touch other values' {
        $o = Remove-AzlRedfishSecret -InputObject ([ordered]@{ Password = $null; ApiToken = 'x'; Name = 'n'; Nested = @(@{ Secret = 's'; Ok = 1 }) })
        $o.Password | Should -BeNullOrEmpty
        $o.ApiToken | Should -Be '<redacted>'
        $o.Name | Should -Be 'n'
        $o.Nested[0].Secret | Should -Be '<redacted>'
        $o.Nested[0].Ok | Should -Be 1
    }
    It 'Hide-AzlRedfishSecretText removes headers and the known password' {
        $ctx = New-AzlRedfishContext -BmcAddress 'bmc.invalid' -Credential $script:Cred
        $t = Hide-AzlRedfishSecretText -Text "failed with doc-pass-123 and Authorization: Basic ZG9jLXVzZXI6ZG9jLXBhc3MtMTIz and X-Auth-Token: abcdef123456" -Context $ctx
        $t | Should -Not -Match 'doc-pass-123'
        $t | Should -Not -Match 'ZG9jLXVzZXI6'
        $t | Should -Not -Match 'abcdef123456'
    }
    It 'caps a raw block that is too large' {
        $big = [ordered]@{ blob = ('x' * 5000) }
        (Limit-AzlRedfishRaw -Block $big -MaxBytes 1000).truncated | Should -BeTrue
        (Limit-AzlRedfishRaw -Block @{ a = 1 } -MaxBytes 1000).a | Should -Be 1
    }
}

Describe 'Session authentication (opt-in)' {
    BeforeEach {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
    }
    AfterAll { Remove-FakeBmc }
    It 'logs in once, reads with the token only, and deletes the session' {
        $r = Invoke-Scan -Detail Summary -UseSession
        $r.identity.serviceTag | Should -Be 'DOCTAG1'
        $posts = Get-FakeCall 'Post'
        $posts.Count | Should -Be 1
        $posts[0].Path | Should -Be '/redfish/v1/SessionService/Sessions'
        $deletes = Get-FakeCall 'Delete'
        $deletes.Count | Should -Be 1
        $deletes[0].Path | Should -Be '/redfish/v1/SessionService/Sessions/1'
        @(Get-FakeCall 'Get' | Where-Object { -not $_.Token }).Count | Should -Be 0
        @(Get-FakeCall 'Get' | Where-Object Basic).Count | Should -Be 0
        @(Get-FakeCall | Where-Object Method -notin 'Get', 'Post', 'Delete').Count | Should -Be 0
    }
    It 'deletes the session even when the scan fails' {
        Remove-FakeResource '/redfish/v1/Systems/System.Embedded.1'
        { Invoke-Scan -Detail Summary -UseSession } | Should -Throw
        @(Get-FakeCall 'Delete').Count | Should -Be 1
    }
    It 'does not put the token in the report' {
        (Invoke-Scan -Detail Summary -UseSession | ConvertTo-Json -Depth 30) | Should -Not -Match 'doc-session-token'
    }
    It 'sends no POST or DELETE unless -UseSession is given' {
        Invoke-Scan -Detail Summary | Out-Null
        @(Get-FakeCall 'Post').Count | Should -Be 0
        @(Get-FakeCall 'Delete').Count | Should -Be 0
    }
}

Describe 'Collections' {
    BeforeEach {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $script:Ctx = New-AzlRedfishContext -BmcAddress 'bmc.invalid' -Credential $script:Cred -RetryDelaySeconds 0
    }
    AfterAll { Remove-FakeBmc }
    It 'walks @odata.nextLink pages and returns every member' {
        Set-FakeResource '/redfish/v1/Test' @{ Members = @(@{ '@odata.id' = '/redfish/v1/Test/1' }); 'Members@odata.nextLink' = '/redfish/v1/Test?$skip=1' }
        $global:AzlTestBmc.Tree['/redfish/v1/Test'] = (@{ Members = @(@{ '@odata.id' = '/redfish/v1/Test/1' }) } | ConvertTo-Json -Compress -Depth 5)
        Set-FakeResource '/redfish/v1/Test/1' @{ Id = 'one' }
        $first = @{ Members = @(@{ '@odata.id' = '/redfish/v1/Test/1' }); 'Members@odata.nextLink' = '/redfish/v1/Test2' }
        Set-FakeResource '/redfish/v1/Test' $first
        Set-FakeResource '/redfish/v1/Test2' @{ Members = @(@{ '@odata.id' = '/redfish/v1/Test/2' }) }
        Set-FakeResource '/redfish/v1/Test/2' @{ Id = 'two' }
        $m = @(Get-AzlRedfishMember -Context $script:Ctx -Path '/redfish/v1/Test')
        ($m | ForEach-Object Id) | Should -Be @('one', 'two')
    }
    It 'stops at MaxMembers' {
        $ctx = New-AzlRedfishContext -BmcAddress 'bmc.invalid' -Credential $script:Cred -MaxMembers 2
        Set-FakeResource '/redfish/v1/Big' @{ Members = @(1..5 | ForEach-Object { @{ '@odata.id' = "/redfish/v1/Big/$_" } }) }
        1..5 | ForEach-Object { Set-FakeResource "/redfish/v1/Big/$_" @{ Id = "$_" } }
        @(Get-AzlRedfishMember -Context $ctx -Path '/redfish/v1/Big').Count | Should -Be 2
    }
    It 'records a member that fails and keeps the others' {
        Set-FakeResource '/redfish/v1/Mix' @{ Members = @(@{ '@odata.id' = '/redfish/v1/Mix/1' }, @{ '@odata.id' = '/redfish/v1/Mix/2' }) }
        Set-FakeResource '/redfish/v1/Mix/1' @{ Id = 'a' }
        $m = @(Get-AzlRedfishMember -Context $script:Ctx -Path '/redfish/v1/Mix')
        $m.Count | Should -Be 1
        $script:Ctx.ReadErrors.Count | Should -Be 1
        $script:Ctx.ReadErrors[0].kind | Should -Be 'notSupported'
    }
}

Describe 'Vendor detection' {
    It 'detects <Name> from <Basis>' -ForEach @(
        @{ Name = 'Dell'; Basis = 'the Oem namespace'; Root = @{ Oem = @{ Dell = @{} } }; Sys = @{ Manufacturer = 'Whatever' }; Mgr = @{}; Confidence = 'high' }
        @{ Name = 'Hpe'; Basis = 'the Oem namespace'; Root = @{}; Sys = @{ Oem = @{ Hpe = @{} }; Manufacturer = 'HPE' }; Mgr = @{ Model = 'iLO 5' }; Confidence = 'high' }
        @{ Name = 'Lenovo'; Basis = 'the Oem namespace'; Root = @{}; Sys = @{ Oem = @{ Lenovo = @{} } }; Mgr = @{}; Confidence = 'high' }
        @{ Name = 'Supermicro'; Basis = 'the Oem namespace'; Root = @{}; Sys = @{}; Mgr = @{ Oem = @{ Supermicro = @{} } }; Confidence = 'high' }
        @{ Name = 'Fujitsu'; Basis = 'the ts_fujitsu namespace'; Root = @{}; Sys = @{ Oem = @{ ts_fujitsu = @{} } }; Mgr = @{}; Confidence = 'high' }
        @{ Name = 'Ami'; Basis = 'an Ami namespace even when Manufacturer names a re-badger'; Root = @{}; Sys = @{ Manufacturer = 'DataON'; Oem = @{ Ami = @{} } }; Mgr = @{}; Confidence = 'high' }
        @{ Name = 'Dell'; Basis = 'Manufacturer only'; Root = @{}; Sys = @{ Manufacturer = 'Dell Inc.' }; Mgr = @{}; Confidence = 'medium' }
        @{ Name = 'DataON'; Basis = 'Manufacturer only'; Root = @{}; Sys = @{ Manufacturer = 'DataON' }; Mgr = @{}; Confidence = 'medium' }
        @{ Name = 'Lenovo'; Basis = 'the manager text'; Root = @{}; Sys = @{}; Mgr = @{ Model = 'XClarity Controller 2' }; Confidence = 'low' }
        @{ Name = 'Unknown'; Basis = 'nothing'; Root = @{}; Sys = @{ Manufacturer = 'Contoso' }; Mgr = @{}; Confidence = 'none' }
    ) {
        $v = Resolve-AzlRedfishVendor -ServiceRoot ([pscustomobject]$Root) -System ([pscustomobject]$Sys) -Manager ([pscustomobject]$Mgr)
        $v.Name | Should -Be $Name
        $v.Confidence | Should -Be $Confidence
        if ($Name -ne 'Unknown') { $v.Evidence.Count | Should -BeGreaterThan 0 }
    }
    It 'only Dell is supported in this version' {
        (Resolve-AzlRedfishVendor -ServiceRoot @{ Oem = @{ Dell = @{} } } -System @{} -Manager @{}).Supported | Should -BeTrue
        foreach ($oem in 'Hpe', 'Lenovo', 'Supermicro', 'ts_fujitsu', 'Ami') {
            (Resolve-AzlRedfishVendor -ServiceRoot @{} -System @{ Oem = @{ $oem = @{} } } -Manager @{}).Supported | Should -BeFalse
        }
    }
    It 'tells the iDRAC generation from the manager model and from the firmware version' {
        (Resolve-AzlRedfishVendor -ServiceRoot @{ Oem = @{ Dell = @{} } } -System @{} -Manager @{ Model = '16G Monolithic'; FirmwareVersion = '7.20.30.00' }).Family | Should -Be 'idrac9'
        (Resolve-AzlRedfishVendor -ServiceRoot @{ Oem = @{ Dell = @{} } } -System @{} -Manager @{ Model = '13G Monolithic' }).Family | Should -Be 'idrac8'
        (Resolve-AzlRedfishVendor -ServiceRoot @{ Oem = @{ Dell = @{} } } -System @{} -Manager @{ FirmwareVersion = '6.10.00.00' }).Family | Should -Be 'idrac9'
        (Resolve-AzlRedfishVendor -ServiceRoot @{ Oem = @{ Dell = @{} } } -System @{} -Manager @{ Model = '17G Monolithic' }).Family | Should -Be 'idrac10'
    }

    Context 'in a scan' {
        BeforeEach {
            Use-FakeBmc
            Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        }
        AfterAll { Remove-FakeBmc }
        It 'reports the detected Dell vendor with its evidence' {
            $r = Invoke-Scan
            $r.vendor.name | Should -Be 'Dell'
            $r.vendor.family | Should -Be 'idrac9'
            $r.vendor.generation | Should -Be '16G'
            $r.vendor.confidence | Should -Be 'high'
            $r.vendor.adapter | Should -Be 'AzlRedfishDell'
            $r.vendor.evidence | Should -Contain "ServiceRoot Oem namespace 'Dell'"
            $r.capabilities.vendorAdapter | Should -Be 'dell'
        }
        It 'says "Unsupported vendor in this version" for a non-Dell BMC and collects nothing else' {
            $root = Get-FakeResource '/redfish/v1'
            $root.Oem = @{ Hpe = @{} }; $root.Vendor = 'HPE'; $root.Product = 'HPE iLO'
            Set-FakeResource '/redfish/v1' $root
            $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
            $sys.Oem = @{ Hpe = @{} }; $sys.Manufacturer = 'HPE'
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
            $mgr = Get-FakeResource '/redfish/v1/Managers/iDRAC.Embedded.1'
            $mgr.Oem = @{ Hpe = @{} }; $mgr.Model = 'iLO 5'
            Set-FakeResource '/redfish/v1/Managers/iDRAC.Embedded.1' $mgr
            { Invoke-Scan } | Should -Throw '*Unsupported vendor in this version*Hpe*'
            { Invoke-Scan } | Should -Throw '*supports Dell iDRAC only*'
            @(Get-FakeCall | Where-Object Path -like '*NetworkAdapters*').Count | Should -Be 0
            @(Get-FakeCall | Where-Object Path -like '*Storage*').Count | Should -Be 0
        }
        It '-Vendor Dell forces the Dell adapter when the identity is hidden, and says so' {
            $root = Get-FakeResource '/redfish/v1'
            $root.Remove('Oem'); $root.Remove('Vendor'); $root.Product = 'BMC'
            Set-FakeResource '/redfish/v1' $root
            $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
            $sys.Remove('Oem'); $sys.Manufacturer = 'Contoso'
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
            $mgr = Get-FakeResource '/redfish/v1/Managers/iDRAC.Embedded.1'
            $mgr.Remove('Oem'); $mgr.Model = 'BMC'
            Set-FakeResource '/redfish/v1/Managers/iDRAC.Embedded.1' $mgr
            { Invoke-Scan } | Should -Throw '*Unsupported vendor*Unknown*'
            $r = Invoke-Scan -Vendor Dell
            $r.vendor.name | Should -Be 'Dell'
            $r.vendor.confidence | Should -Be 'override'
            ($r.vendor.evidence -join ' ') | Should -Match 'vendor override: -Vendor Dell \(detection said Unknown\)'
            $r.identity.serviceTag | Should -Be 'DOCTAG1'
        }
        It '-Vendor Dell falls back to the well-known iDRAC paths when the root links nothing' {
            $root = Get-FakeResource '/redfish/v1'
            $root.Remove('Systems'); $root.Remove('Chassis'); $root.Remove('Managers')
            Set-FakeResource '/redfish/v1' $root
            $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
            $sys.Links = @{}
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
            $r = Invoke-Scan -Vendor Dell
            $r.identity.serviceTag | Should -Be 'DOCTAG1'
            $r.bmc.model | Should -Be '16G Monolithic'
            { Invoke-Scan -Vendor Auto } | Should -Throw '*lists no computer system*'
        }
    }
}

Describe 'Capability report' {
    BeforeAll {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $script:Full = Invoke-Scan -Detail Full
        $script:Sum = Invoke-Scan -Detail Summary
        Use-FakeBmc -Fixture 'idrac9-newschema-synthetic'
        $script:New = Invoke-Scan -Detail Full
    }
    AfterAll { Remove-FakeBmc }
    It 'lists every area with a status, paths and a reason where not ok' {
        $names = @($script:Full.capabilities.areas.Keys)
        foreach ($a in 'identity', 'bmc', 'processors', 'memory', 'pcie', 'network', 'storage', 'firmware', 'bios', 'sensors', 'events', 'security') { $names | Should -Contain $a }
        foreach ($a in $names) { $script:Full.capabilities.areas[$a].status | Should -BeIn 'ok', 'partial', 'notSupported', 'denied', 'error', 'skipped' }
        $script:Full.capabilities.areas.network.paths | Should -Contain '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters'
    }
    It 'is complete with all areas ok on the full fixture' {
        $script:Full.capabilities.complete | Should -BeTrue
        $script:Full.capabilities.summary.ok | Should -Be 12
        $script:Full.capabilities.requestCount | Should -BeGreaterThan 50
    }
    It 'says why an area was skipped at summary detail' {
        $script:Sum.capabilities.detail | Should -Be 'summary'
        foreach ($a in 'processors', 'memory', 'pcie', 'firmware', 'bios', 'sensors', 'events', 'security') {
            $script:Sum.capabilities.areas[$a].status | Should -Be 'skipped'
            $script:Sum.capabilities.areas[$a].reason | Should -Match 'Summary'
        }
        $script:Sum.capabilities.areas.network.status | Should -Be 'ok'
        $script:Sum.capabilities.areas.storage.status | Should -Be 'ok'
    }
    It 'records which schema variant was used' {
        $script:Full.capabilities.areas.network.schemaVariant | Should -Match 'NetworkPorts'
        $script:Full.capabilities.areas.sensors.schemaVariant | Should -Be 'Power, Thermal'
        $script:New.capabilities.areas.network.schemaVariant | Should -Match 'Ports'
        $script:New.capabilities.areas.network.schemaVariant | Should -Not -Match 'NetworkPorts'
        $script:New.capabilities.areas.sensors.schemaVariant | Should -Be 'PowerSubsystem, ThermalSubsystem, Sensors'
        $script:New.health.power.capacityWatts | Should -Be 2800
        @($script:New.health.power.supplies).Count | Should -Be 2
        @($script:New.health.sensors).Count | Should -Be 2
        @($script:New.network.adapters | ForEach-Object { $_.ports } | ForEach-Object { $_ }).Count | Should -Be 6
        ($script:New.network.adapters | ForEach-Object { $_.ports } | ForEach-Object { $_ } | Where-Object name -eq 'Embedded NIC 2').mac | Should -Be '00:00:5E:00:53:11'
    }
    It 'marks every OEM path as lab-observed, documented or inferred, and lists the inferred ones as needing hardware verification' {
        $oem = @($script:Full.capabilities.oemPaths)
        $oem.Count | Should -BeGreaterThan 3
        foreach ($p in $oem) { $p.basis | Should -BeIn 'lab-observed', 'documented', 'inferred'; $p.source | Should -Not -BeNullOrEmpty }
        ($oem | Where-Object basis -eq 'inferred').Count | Should -BeGreaterThan 0
        ($oem | Where-Object basis -eq 'lab-observed').Count | Should -BeGreaterThan 0
        $script:Full.capabilities.needsHardwareVerification.Count | Should -Be @($oem | Where-Object basis -eq 'inferred').Count
    }
}

Describe 'Bounded parallelism' {
    It 'runs one after another with a throttle of 1' {
        $r = Invoke-AzlRedfishBatch -Item 1, 2, 3 -ScriptBlock { param($i) $i * 2 } -ThrottleLimit 1
        ($r | ForEach-Object Result) | Should -Be @(2, 4, 6)
    }
    It 'never runs more than ThrottleLimit at once' {
        $shared = [pscustomobject]@{ Now = [ref]0; Max = [ref]0; Lock = [object]::new() }
        $work = {
            param($i, $s)
            [System.Threading.Monitor]::Enter($s.Lock); try { $s.Now.Value++; if ($s.Now.Value -gt $s.Max.Value) { $s.Max.Value = $s.Now.Value } } finally { [System.Threading.Monitor]::Exit($s.Lock) }
            Start-Sleep -Milliseconds 250
            [System.Threading.Monitor]::Enter($s.Lock); try { $s.Now.Value-- } finally { [System.Threading.Monitor]::Exit($s.Lock) }
            $i
        }
        $r = Invoke-AzlRedfishBatch -Item (1..6) -ScriptBlock $work -Shared $shared -ThrottleLimit 2
        @($r).Count | Should -Be 6
        $shared.Max.Value | Should -BeLessOrEqual 2
        $shared.Max.Value | Should -BeGreaterThan 1
    }
    It 'a failing item does not stop the others' {
        $r = Invoke-AzlRedfishBatch -Item 1, 2, 3 -ScriptBlock { param($i) if ($i -eq 2) { throw 'node 2 unreachable' }; $i } -ThrottleLimit 3
        @($r | Where-Object Error).Count | Should -Be 1
        ($r | Where-Object Error).Error | Should -Match 'node 2 unreachable'
        @($r | Where-Object { -not $_.Error }).Count | Should -Be 2
    }
}
