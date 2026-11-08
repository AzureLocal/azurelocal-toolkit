#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The IDENTITY checks of the pre-cluster verification gate (scripts/common/arm-deployment/verification/AzlVerification.Identity.psm1), with fake adapters
# only: no Azure, no Active Directory, no DNS server and no node is touched. Both identity modes, and for every check a pass, a failure and a skip.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pre-cluster-verification/Verification.Identity.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake adapters keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory objects.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test values only.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'verification', 'AzlVerification.Identity.psm1')) -Force
    $script:Defs = @(Get-AzlVerificationCheckDefinition)
    # Test values, never real: the passwords are generated here and must never show up in any result text.
    $script:LcmPassword = 'Lcm-T3st-Passw0rd!x'
    $script:LocalPassword = 'Loc4l-T3st-Passw0rd!y'
    $script:SidText = 'S-1-5-21-111-222-333-1105'
    $script:ComputerGuid = [guid]'bf967a86-0de6-11d0-a285-00aa00302ce8'

    function Get-Def([string]$Id) { return @($script:Defs | Where-Object { $_.Id -eq $Id })[0] }

    function New-Descriptor {
        param([switch]$NoCreate, [switch]$NoRecovery, [switch]$Deny)
        $sid = [System.Security.Principal.SecurityIdentifier]::new($script:SidText)
        $sec = [System.DirectoryServices.ActiveDirectorySecurity]::new()
        $A = [System.DirectoryServices.ActiveDirectoryAccessRule]
        $none = [guid]::Empty
        $sec.AddAccessRule($A::new($sid, [System.DirectoryServices.ActiveDirectoryRights]'ListChildren,ReadProperty,ReadControl', 'Allow', $none, 'All'))
        if (-not $NoCreate) { $sec.AddAccessRule($A::new($sid, [System.DirectoryServices.ActiveDirectoryRights]'CreateChild,DeleteChild', 'Allow', $script:ComputerGuid, 'All')) }
        if (-not $NoRecovery) { $sec.AddAccessRule($A::new($sid, [System.DirectoryServices.ActiveDirectoryRights]::GenericAll, 'Allow', $none, 'Descendents', [guid]'ea715d30-8f4c-4a6e-9b26-5d3b4e7a2f10')) }
        if ($Deny) { $sec.AddAccessRule($A::new($sid, [System.DirectoryServices.ActiveDirectoryRights]'CreateChild,DeleteChild', 'Deny', $script:ComputerGuid, 'All')) }
        return [Convert]::ToBase64String($sec.GetSecurityDescriptorBinaryForm())
    }

    function ConvertTo-SidBase64([string]$Text) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($Text)
        $b = New-Object byte[] $sid.BinaryLength
        $sid.GetBinaryForm($b, 0)
        return [Convert]::ToBase64String($b)
    }

    function New-Infra {
        param([ValidateSet('active_directory', 'local_identity')][string]$Identity = 'active_directory', [string[]]$Dns = @('192.0.2.4'), [string]$DnsConfig = 'use_dns_server')
        $infra = @{
            scenario   = @{ identity = $Identity }
            cluster    = @{ name = 'azl01' }
            identity   = @{ local_admin = @{ username = 'azl-admin'; password = 'keyvault://kv-test/local-admin' } }
            networking = @{ management = @{ dns_servers = $Dns; use_dhcp = $false; infrastructure_pool = @{ start = '192.0.2.20'; end = '192.0.2.29' } } }
            nodes      = @(
                @{ name = 'azl-n01'; management = @{ ip_address = '192.0.2.11' } }
                @{ name = 'azl-n02'; management = @{ ip_address = '192.0.2.12' } }
            )
        }
        if ($Identity -eq 'active_directory') {
            $infra.identity.active_directory = @{
                domain_fqdn = 'lab.example'; netbios_name = 'LAB'; ou_path = 'OU=azl01,DC=lab,DC=example'
                lcm_user = @{ username = 'lcm-azl01'; password = 'keyvault://kv-test/lcm' }; domain_controllers = @('192.0.2.4')
            }
        }
        else { $infra.identity.local_identity = @{ dns_server_config = $DnsConfig; dns_zone = 'lab.example' } }
        return $infra
    }

    function New-GoodNode([string]$Name, [string[]]$Dns = @('192.0.2.4'), [string]$Zone = 'lab.example', [bool]$Joined = $false) {
        $q = @()
        foreach ($s in $Dns) {
            $q += [pscustomobject]@{ name = $Zone; type = 'A'; server = $s; ok = $true; addrs = @('192.0.2.4'); error = '' }
            $q += [pscustomobject]@{ name = "_ldap._tcp.dc._msdcs.$Zone"; type = 'SRV'; server = $s; ok = $true; addrs = @('dc01.lab.example'); error = '' }
            foreach ($n in 'azl-n01', 'azl-n02') { $q += [pscustomobject]@{ name = "$n.$Zone"; type = 'A'; server = $s; ok = $true; addrs = @('192.0.2.11'); error = '' } }
            foreach ($e in 'management.azure.com', 'login.microsoftonline.com', 'guestnotificationservice.azure.com', 'dp.kubernetesconfiguration.azure.com') { $q += [pscustomobject]@{ name = $e; type = 'A'; server = $s; ok = $true; addrs = @('203.0.113.9'); error = '' } }
        }
        [pscustomobject]@{
            computer = $Name; partOfDomain = $Joined; domain = $(if ($Joined) { 'lab.example' } else { 'WORKGROUP' }); primarySuffix = $(if ($Joined) { 'lab.example' } else { '' })
            admins = @("$Name\azl-admin", "$Name\Administrator"); admin = [pscustomobject]@{ exists = $true; enabled = $true; sid = 'S-1-5-21-1-2-3-1001' }
            dnsClient = @([pscustomobject]@{ alias = 'Port1'; servers = $Dns }); dnsq = $q
            tcp = @(9389, 389, 88 | ForEach-Object { [pscustomobject]@{ host = '192.0.2.4'; port = $_; ok = $true } })
            sshd = [pscustomobject]@{ status = 'Running'; start = 'Automatic' }; secureChannel = $(if ($Joined) { $true } else { $null })
        }
    }

    function Add-AdRoute($State, [string]$Pattern, [object[]]$Entry = @(), [switch]$AuthFailed, [switch]$Unreachable, [switch]$NoProperties, [string]$ErrorText = '') {
        $State.Ad.Insert(0, @{ Pattern = $Pattern; Entry = @($Entry); AuthFailed = [bool]$AuthFailed; Unreachable = [bool]$Unreachable; NoProperties = [bool]$NoProperties; Error = $ErrorText })
    }

    function New-AdEntry([string]$Dn, [hashtable]$Data = @{}) { return @{ dn = $Dn; data = $Data } }

    function New-State {
        $state = @{
            Secrets = @{ 'keyvault://kv-test/lcm' = $script:LcmPassword; 'keyvault://kv-test/local-admin' = $script:LocalPassword }
            Ad      = [System.Collections.Generic.List[hashtable]]::new()
            Dns     = @{}
            Nodes   = @{}
            Calls   = [System.Collections.Generic.List[string]]::new()
        }
        # A directory where everything is right.
        $ouDn = 'OU=azl01,DC=lab,DC=example'
        $lcmDn = "CN=lcm-azl01,$ouDn"
        Add-AdRoute $state 'domainDNS' @(New-AdEntry 'DC=lab,DC=example')
        Add-AdRoute $state 'organizationalUnit' @(New-AdEntry $ouDn @{ gpoptions = @('1'); gplink = @(''); ntsecuritydescriptor = @((New-Descriptor)) })
        Add-AdRoute $state 'sAMAccountName=lcm-azl01' @(New-AdEntry $lcmDn @{ useraccountcontrol = @('512'); accountexpires = @('0'); objectsid = @((ConvertTo-SidBase64 $script:SidText)) })
        Add-AdRoute $state '\(objectClass=\*\)' @(New-AdEntry $lcmDn @{ tokengroups = @() })
        Add-AdRoute $state 'distinguishedName=DC=lab' @(New-AdEntry 'DC=lab,DC=example' @{ gplink = @('') })
        # Nothing pre-created.
        Add-AdRoute $state 'objectCategory=computer' @()
        $state.Dns = @{ 'azl-n01.lab.example' = @('192.0.2.11'); 'azl-n02.lab.example' = @('192.0.2.12'); 'azl01.lab.example' = @('192.0.2.20') }
        foreach ($n in 'azl-n01', 'azl-n02') { $state.Nodes[$n] = (New-GoodNode $n) }
        return $state
    }

    function New-Adapter($State) {
        $ad = {
            param($Filter, $SearchRoot, $Options)
            $State.Calls.Add("ad:$Filter")
            foreach ($r in $State.Ad) {
                if ("$Filter $SearchRoot" -notmatch $r.Pattern) { continue }
                if ($r.Unreachable) { return [pscustomobject]@{ Reachable = $false; Server = ''; Entries = @(); AuthFailed = $false; Error = 'no domain controller answered on TCP 389 from this host' } }
                if ($r.AuthFailed) { return [pscustomobject]@{ Reachable = $true; Server = '192.0.2.4'; Entries = @(); AuthFailed = $true; Error = 'logon failure: the user name or password is incorrect' } }
                $entries = foreach ($e in $r.Entry) {
                    if ($r.NoProperties) { [pscustomobject]@{ distinguishedName = $e.dn; dnsHostName = '' }; continue }
                    $props = [ordered]@{}
                    foreach ($p in @($Options.Properties)) { $props[$p] = $(if ($e.data.ContainsKey($p)) { @($e.data[$p]) } else { @() }) }
                    [pscustomobject]@{ distinguishedName = $e.dn; dnsHostName = ''; Properties = $props }
                }
                return [pscustomobject]@{ Reachable = $true; Server = '192.0.2.4'; Entries = @($entries); AuthFailed = $false; Error = $r.Error }
            }
            return [pscustomobject]@{ Reachable = $true; Server = '192.0.2.4'; Entries = @(); AuthFailed = $false; Error = '' }
        }.GetNewClosure()
        $resolve = {
            param($Name, $Server)
            $State.Calls.Add("dns:$Name@$Server")
            if ($State.Dns.ContainsKey('__silent') -and $Server -in $State.Dns['__silent']) { return [pscustomobject]@{ Ok = $false; Addresses = @(); Error = 'timeout' } }
            [pscustomobject]@{ Ok = $true; Addresses = $(if ($State.Dns.ContainsKey($Name)) { @($State.Dns[$Name]) } else { @() }); Error = '' }
        }.GetNewClosure()
        $remote = {
            param($Request)
            $State.Calls.Add("remote:$($Request.Node)")
            $n = $State.Nodes[$Request.Node]
            if ($n -is [string]) { return [pscustomobject]@{ Ok = $false; Address = ''; Result = $null; Error = $n; AuthFailed = ($n -match 'denied') } }
            if ($null -eq $n) { return [pscustomobject]@{ Ok = $false; Address = ''; Result = $null; Error = 'connection refused'; AuthFailed = $false } }
            [pscustomobject]@{ Ok = $true; Address = $Request.Addresses[0]; Result = $n; Error = ''; AuthFailed = $false }
        }.GetNewClosure()
        $secret = { param($Reference) $State.Calls.Add("secret:$Reference"); if (-not $State.Secrets.ContainsKey($Reference)) { throw "secret $Reference not found" }; $State.Secrets[$Reference] }.GetNewClosure()
        return @{ Ad = @{ Search = $ad }; Dns = @{ Resolve = $resolve }; Remote = @{ Invoke = $remote }; KeyVault = @{ GetSecret = $secret }; Clock = @{ Now = { [datetime]'2026-11-08' } } }
    }

    function New-Ctx {
        param([ValidateSet('active_directory', 'local_identity')][string]$Identity = 'active_directory', [hashtable]$Infra, $State, [hashtable]$Settings = @{})
        if (-not $State) { $State = New-State }
        if (-not $Infra) { $Infra = New-Infra -Identity $Identity }
        $ctx = @{ Infrastructure = $Infra; Handoff = $null; OsReport = $null; Settings = $Settings; Adapters = (New-Adapter $State) }
        $ctx.State = $State
        return $ctx
    }

    function Invoke-Id([string]$Id, [hashtable]$Ctx) {
        $def = Get-Def $Id
        return @(& $def.Run $Ctx)
    }

    function Get-Status($Results) { return @($Results | ForEach-Object { $_.Status }) }
}

Describe 'contract' {
    It 'exports the definitions and the default adapters' {
        $script:Defs.Count | Should -BeGreaterThan 20
        $ad = Get-AzlVerificationAdapterDefault
        foreach ($k in 'Ad', 'Dns', 'Remote', 'KeyVault', 'Clock') { $ad.Keys | Should -Contain $k }
        $ad.Ad.Search | Should -BeOfType [scriptblock]
        $ad.Dns.Resolve | Should -BeOfType [scriptblock]
        $ad.Remote.Invoke | Should -BeOfType [scriptblock]
        $ad.KeyVault.GetSecret | Should -BeOfType [scriptblock]
    }
    It 'every definition has the fields of the contract' {
        foreach ($d in $script:Defs) {
            $d.Id | Should -Match '^ID-[A-Z]+-\d{3}$'
            $d.Category | Should -Be 'identity'
            $d.Title | Should -Not -BeNullOrEmpty
            $d.Source | Should -Match 'https://'
            $d.Blocking | Should -BeOfType [bool]
            $d.Applies | Should -BeOfType [scriptblock]
            $d.Run | Should -BeOfType [scriptblock]
        }
        ($script:Defs.Id | Select-Object -Unique).Count | Should -Be $script:Defs.Count
    }
    It 'the Applies blocks split the checks by identity mode' {
        $ad = New-Ctx -Identity active_directory
        $li = New-Ctx -Identity local_identity
        foreach ($d in $script:Defs) {
            $inAd = [bool](& $d.Applies $ad); $inLi = [bool](& $d.Applies $li)
            if ($d.Id -like 'ID-AD-*' -or $d.Id -eq 'ID-DNS-002') { $inAd | Should -BeTrue -Because $d.Id; $inLi | Should -BeFalse -Because $d.Id }
            elseif ($d.Id -like 'ID-LI-*') { $inLi | Should -BeTrue -Because $d.Id; $inAd | Should -BeFalse -Because $d.Id }
            else { $inAd | Should -BeTrue -Because $d.Id }
        }
        # Host records: local identity with a forwarder lets the internal DNS service create them.
        $fwd = New-Ctx -Infra (New-Infra -Identity local_identity -DnsConfig use_forwarder)
        [bool](& (Get-Def 'ID-DNS-001').Applies $fwd) | Should -BeFalse
        [bool](& (Get-Def 'ID-DNS-001').Applies $li) | Should -BeTrue
    }
    It 'with every thing right in both modes nothing fails, and no password is in any text' {
        foreach ($mode in 'active_directory', 'local_identity') {
            $ctx = New-Ctx -Identity $mode
            if ($mode -eq 'local_identity') { $ctx.State.Dns = @{ 'azl-n01.lab.example' = @('192.0.2.11'); 'azl-n02.lab.example' = @('192.0.2.12'); 'azl01.lab.example' = @('192.0.2.20') } }
            $texts = [System.Collections.Generic.List[string]]::new()
            foreach ($d in $script:Defs) {
                if (-not (& $d.Applies $ctx)) { continue }
                foreach ($r in @(& $d.Run $ctx)) {
                    $r.Status | Should -BeIn 'Passed', 'Warning', 'NotApplicable' -Because "$mode $($d.Id): $($r.Message)"
                    $texts.Add("$($r.Message) $($r.Remedy) $($r.Evidence)")
                }
            }
            $all = $texts -join "`n"
            $all | Should -Not -Match ([regex]::Escape($script:LcmPassword))
            $all | Should -Not -Match ([regex]::Escape($script:LocalPassword))
        }
    }
    It 'a library error that carries a secret is scrubbed' {
        $ctx = New-Ctx
        $ctx.Adapters.Ad.Search = { param($Filter, $SearchRoot, $Options) throw "boom with $($Options.Credential.GetNetworkCredential().Password) inside" }
        $r = Invoke-Id 'ID-AD-003' $ctx
        $r[0].Status | Should -Be 'Skipped'
        ($r[0].Message + $r[0].Remedy + $r[0].Evidence) | Should -Not -Match ([regex]::Escape($script:LcmPassword))
    }
}

Describe 'ID-AD-001 file settings' {
    It 'passes for a good file' { (Invoke-Id 'ID-AD-001' (New-Ctx))[0].Status | Should -Be 'Passed' }
    It 'fails for <Name>' -ForEach @(
        @{ Name = 'a user with a domain'; Path = 'lcm_user'; Value = @{ username = 'LAB\lcm'; password = 'keyvault://kv-test/lcm' } }
        @{ Name = 'a user name over 20 characters'; Path = 'lcm_user'; Value = @{ username = 'lcm-user-name-that-is-too-long'; password = 'keyvault://kv-test/lcm' } }
        @{ Name = 'a user that starts with a number'; Path = 'lcm_user'; Value = @{ username = '1lcm'; password = 'keyvault://kv-test/lcm' } }
        @{ Name = 'the same name as the local admin'; Path = 'lcm_user'; Value = @{ username = 'azl-admin'; password = 'keyvault://kv-test/lcm' } }
        @{ Name = 'an OU path without OU='; Path = 'ou_path'; Value = 'DC=lab,DC=example' }
        @{ Name = 'an OU path without DC parts'; Path = 'ou_path'; Value = 'OU=azl01' }
        @{ Name = 'a forbidden character in the OU path'; Path = 'ou_path'; Value = 'OU=azl&01,DC=lab,DC=example' }
    ) {
        $infra = New-Infra
        $infra.identity.active_directory[$Path] = $Value
        (Invoke-Id 'ID-AD-001' (New-Ctx -Infra $infra))[0].Status | Should -Be 'Failed'
    }
    It 'warns when no domain controller address is listed' {
        $infra = New-Infra; $infra.identity.active_directory.domain_controllers = @()
        (Invoke-Id 'ID-AD-001' (New-Ctx -Infra $infra))[0].Status | Should -Be 'Warning'
    }
}

Describe 'ID-AD-002 domain controller and credential' {
    It 'passes' { (Invoke-Id 'ID-AD-002' (New-Ctx))[0].Status | Should -Be 'Passed' }
    It 'fails when the credential is rejected, and the credential is not sent again' {
        $ctx = New-Ctx
        Add-AdRoute $ctx.State 'domainDNS' -AuthFailed
        (Invoke-Id 'ID-AD-002' $ctx)[0].Status | Should -Be 'Failed'
        $before = @($ctx.State.Calls | Where-Object { $_ -like 'ad:*' }).Count
        (Invoke-Id 'ID-AD-003' $ctx)[0].Status | Should -Be 'Skipped'
        (Invoke-Id 'ID-AD-002' $ctx)[0].Status | Should -Be 'Failed'
        @($ctx.State.Calls | Where-Object { $_ -like 'ad:*' }).Count | Should -Be $before
    }
    It 'is skipped, with the reason, when no domain controller answers' {
        $ctx = New-Ctx
        Add-AdRoute $ctx.State 'domainDNS' -Unreachable
        $r = Invoke-Id 'ID-AD-002' $ctx
        $r[0].Status | Should -Be 'Skipped'
        $r[0].Message | Should -Match '389'
    }
}

Describe 'ID-AD-003 OU exists' {
    It 'passes' { (Invoke-Id 'ID-AD-003' (New-Ctx))[0].Status | Should -Be 'Passed' }
    It 'fails with the preparation command when the OU is missing' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'organizationalUnit' @()
        $r = Invoke-Id 'ID-AD-003' $ctx
        $r[0].Status | Should -Be 'Failed'
        $r[0].Remedy | Should -Match 'New-HciAdObjectsPreCreation'
    }
    It 'is skipped when there is no LDAP adapter' {
        $ctx = New-Ctx; $ctx.Adapters.Remove('Ad')
        $r = Invoke-Id 'ID-AD-003' $ctx
        $r[0].Status | Should -Be 'Skipped'
        $r[0].Message | Should -Match 'Ad.Search'
    }
}

Describe 'ID-AD-004 LCM user' {
    It 'passes' { (Invoke-Id 'ID-AD-004' (New-Ctx))[0].Status | Should -Be 'Passed' }
    It 'fails for <Name>' -ForEach @(
        @{ Name = 'a disabled account'; Data = @{ useraccountcontrol = @('514'); accountexpires = @('0'); objectsid = @() } }
        @{ Name = 'a locked account'; Data = @{ useraccountcontrol = @('512'); 'msds-user-account-control-computed' = @('16'); accountexpires = @('0') } }
        @{ Name = 'a smart card account'; Data = @{ useraccountcontrol = @('262656'); accountexpires = @('0') } }
        @{ Name = 'an expired account'; Data = @{ useraccountcontrol = @('512'); accountexpires = @(([datetime]'2026-01-01').ToFileTimeUtc().ToString()) } }
    ) {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'sAMAccountName=lcm-azl01' @(New-AdEntry 'CN=lcm-azl01,OU=azl01,DC=lab,DC=example' $Data)
        (Invoke-Id 'ID-AD-004' $ctx)[0].Status | Should -Be 'Failed'
    }
    It 'fails when the user does not exist' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'sAMAccountName=lcm-azl01' @()
        (Invoke-Id 'ID-AD-004' $ctx)[0].Status | Should -Be 'Failed'
    }
    It 'warns when the user is outside the OU (Learn allows it anywhere)' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'sAMAccountName=lcm-azl01' @(New-AdEntry 'CN=lcm-azl01,CN=Users,DC=lab,DC=example' @{ useraccountcontrol = @('512'); accountexpires = @('0') })
        $r = Invoke-Id 'ID-AD-004' $ctx
        $r[0].Status | Should -Be 'Warning'
        $r[0].Message | Should -Match 'anywhere'
    }
    It 'is skipped when the LDAP helper returns no properties' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'sAMAccountName=lcm-azl01' @(New-AdEntry 'CN=lcm-azl01,OU=azl01,DC=lab,DC=example') -NoProperties
        $r = Invoke-Id 'ID-AD-004' $ctx
        $r[0].Status | Should -Be 'Skipped'
        $r[0].Message | Should -Match 'Properties'
    }
}

Describe 'ID-AD-005 LCM password policy' {
    It 'passes' { (Invoke-Id 'ID-AD-005' (New-Ctx))[0].Status | Should -Be 'Passed' }
    It 'fails for the weak password <Name>' -ForEach @(
        @{ Name = 'too short'; Value = 'Sh0rt!pw' }
        @{ Name = 'no special character'; Value = 'NoSpecialCharacter123' }
        @{ Name = 'no digit'; Value = 'No-Digit-Anywhere-Here' }
        @{ Name = 'no upper case'; Value = 'no-upper-case-1234567' }
    ) {
        $ctx = New-Ctx; $ctx.State.Secrets['keyvault://kv-test/lcm'] = $Value
        $r = Invoke-Id 'ID-AD-005' $ctx
        $r[0].Status | Should -Be 'Failed'
        ($r[0].Message + $r[0].Evidence) | Should -Not -Match ([regex]::Escape($Value))
    }
    It 'fails for the user name admin' {
        $infra = New-Infra; $infra.identity.active_directory.lcm_user.username = 'admin'
        (Invoke-Id 'ID-AD-005' (New-Ctx -Infra $infra))[0].Status | Should -Be 'Failed'
    }
    It 'is skipped when the secret cannot be read' {
        $ctx = New-Ctx; $ctx.State.Secrets.Clear()
        (Invoke-Id 'ID-AD-005' $ctx)[0].Status | Should -Be 'Skipped'
    }
}

Describe 'ID-AD-006 Block Inheritance' {
    It 'passes when gPOptions has the block bit' { (Invoke-Id 'ID-AD-006' (New-Ctx))[0].Status | Should -Be 'Passed' }
    It 'fails when inheritance is not blocked, with the Set-GPInheritance command' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'organizationalUnit' @(New-AdEntry 'OU=azl01,DC=lab,DC=example' @{ gpoptions = @('0') })
        $r = Invoke-Id 'ID-AD-006' $ctx
        $r[0].Status | Should -Be 'Failed'
        $r[0].Remedy | Should -Match 'Set-GPInheritance'
    }
    It 'fails when gPOptions was never set (an absent attribute is not blocked)' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'organizationalUnit' @(New-AdEntry 'OU=azl01,DC=lab,DC=example' @{})
        (Invoke-Id 'ID-AD-006' $ctx)[0].Status | Should -Be 'Failed'
    }
    It 'warns about an enforced GPO link above the OU' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'distinguishedName=DC=lab' @(New-AdEntry 'DC=lab,DC=example' @{ gplink = @('[LDAP://CN={11111111-1111-1111-1111-111111111111},CN=Policies,CN=System,DC=lab,DC=example;2]') })
        $r = Invoke-Id 'ID-AD-006' $ctx
        $r[0].Status | Should -Be 'Warning'
        $r[0].Message | Should -Match 'enforced'
    }
    It 'is skipped, with the reason, when the helper cannot return gPOptions' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'organizationalUnit' @(New-AdEntry 'OU=azl01,DC=lab,DC=example') -NoProperties
        $r = Invoke-Id 'ID-AD-006' $ctx
        $r[0].Status | Should -Be 'Skipped'
        $r[0].Message | Should -Match 'gpoptions'
    }
    It 'is skipped when the OU does not exist' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'organizationalUnit' @()
        (Invoke-Id 'ID-AD-006' $ctx)[0].Status | Should -Be 'Skipped'
    }
}

Describe 'ID-AD-007 delegated rights' {
    It 'passes when the user holds every right of Learn''s table' {
        $r = Invoke-Id 'ID-AD-007' (New-Ctx)
        $r[0].Status | Should -Be 'Passed'
    }
    It 'fails when create and delete computer objects are missing' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'ntsecuritydescriptor|organizationalUnit' @(New-AdEntry 'OU=azl01,DC=lab,DC=example' @{ gpoptions = @('1'); ntsecuritydescriptor = @((New-Descriptor -NoCreate)) })
        $r = Invoke-Id 'ID-AD-007' $ctx
        $r[0].Status | Should -Be 'Failed'
        $r[0].Message | Should -Match 'create computer objects'
    }
    It 'warns when the BitLocker recovery entry is missing' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'organizationalUnit' @(New-AdEntry 'OU=azl01,DC=lab,DC=example' @{ gpoptions = @('1'); ntsecuritydescriptor = @((New-Descriptor -NoRecovery)) })
        (Invoke-Id 'ID-AD-007' $ctx)[0].Status | Should -Be 'Warning'
    }
    It 'warns about a deny entry' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'organizationalUnit' @(New-AdEntry 'OU=azl01,DC=lab,DC=example' @{ gpoptions = @('1'); ntsecuritydescriptor = @((New-Descriptor -Deny)) })
        (Invoke-Id 'ID-AD-007' $ctx)[0].Status | Should -Be 'Warning'
    }
    It 'counts a right the user holds through a group' {
        $groupSid = 'S-1-5-21-111-222-333-2200'
        $sid = [System.Security.Principal.SecurityIdentifier]::new($groupSid)
        $sec = [System.DirectoryServices.ActiveDirectorySecurity]::new()
        $sec.AddAccessRule([System.DirectoryServices.ActiveDirectoryAccessRule]::new($sid, [System.DirectoryServices.ActiveDirectoryRights]::GenericAll, 'Allow', [guid]::Empty, 'All'))
        $ctx = New-Ctx
        Add-AdRoute $ctx.State 'organizationalUnit' @(New-AdEntry 'OU=azl01,DC=lab,DC=example' @{ gpoptions = @('1'); ntsecuritydescriptor = @([Convert]::ToBase64String($sec.GetSecurityDescriptorBinaryForm())) })
        Add-AdRoute $ctx.State '\(objectClass=\*\)' @(New-AdEntry 'CN=lcm-azl01,OU=azl01,DC=lab,DC=example' @{ tokengroups = @((ConvertTo-SidBase64 $groupSid)) })
        (Invoke-Id 'ID-AD-007' $ctx)[0].Status | Should -Be 'Passed'
    }
    It 'is skipped when the security descriptor is not returned' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'organizationalUnit' @(New-AdEntry 'OU=azl01,DC=lab,DC=example' @{ gpoptions = @('1') })
        $r = Invoke-Id 'ID-AD-007' $ctx
        $r[0].Status | Should -Be 'Skipped'
        $r[0].Remedy | Should -Not -BeNullOrEmpty
    }
}

Describe 'ID-AD-008 pre-created computer objects' {
    It 'passes when nothing exists (the deployment creates them)' {
        $r = Invoke-Id 'ID-AD-008' (New-Ctx)
        $r.Count | Should -Be 3
        Get-Status $r | Select-Object -Unique | Should -Be 'Passed'
    }
    It 'passes for objects already in the OU' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'cn=azl-n01' @(New-AdEntry 'CN=azl-n01,OU=azl01,DC=lab,DC=example')
        $r = Invoke-Id 'ID-AD-008' $ctx
        ($r | Where-Object Node -eq 'azl-n01').Message | Should -Match 'pre-created'
    }
    It 'fails for an object outside the OU, with the Move-ADObject command' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'cn=azl01\)' @(New-AdEntry 'CN=azl01,CN=Computers,DC=lab,DC=example')
        $r = Invoke-Id 'ID-AD-008' $ctx
        $bad = @($r | Where-Object Status -eq 'Failed')
        $bad.Count | Should -Be 1
        $bad[0].Remedy | Should -Match 'Move-ADObject'
    }
    It 'is skipped when the directory cannot be reached' {
        $ctx = New-Ctx; Add-AdRoute $ctx.State 'objectCategory=computer' -Unreachable
        (Invoke-Id 'ID-AD-008' $ctx)[0].Status | Should -Be 'Skipped'
    }
}

Describe 'ID-DNS-001 node host records' {
    It 'passes in Active Directory mode when the records match' { Get-Status (Invoke-Id 'ID-DNS-001' (New-Ctx)) | Select-Object -Unique | Should -Be 'Passed' }
    It 'warns for a missing record when the DNS servers are domain controllers (secure dynamic updates)' {
        $ctx = New-Ctx; $ctx.State.Dns.Remove('azl-n01.lab.example')
        $r = Invoke-Id 'ID-DNS-001' $ctx
        ($r | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Warning'
    }
    It 'fails for a missing record when the DNS servers are not domain controllers' {
        $infra = New-Infra -Dns @('192.0.2.53'); $ctx = New-Ctx -Infra $infra; $ctx.State.Dns.Remove('azl-n01.lab.example')
        $r = Invoke-Id 'ID-DNS-001' $ctx
        ($r | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Failed'
        ($r | Where-Object Node -eq 'azl-n01').Remedy | Should -Match 'Add-DnsServerResourceRecordA'
    }
    It 'honours the explicit secure update setting of the file' {
        $infra = New-Infra -Dns @('192.0.2.53'); $infra.identity.active_directory.dns_secure_dynamic_updates = $true
        $ctx = New-Ctx -Infra $infra; $ctx.State.Dns.Remove('azl-n01.lab.example')
        (Invoke-Id 'ID-DNS-001' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Warning'
    }
    It 'fails when a record points to another address' {
        $ctx = New-Ctx; $ctx.State.Dns['azl-n02.lab.example'] = @('192.0.2.99')
        (Invoke-Id 'ID-DNS-001' $ctx | Where-Object Node -eq 'azl-n02').Status | Should -Be 'Failed'
    }
    It 'fails in local identity mode for a missing record (always required)' {
        $ctx = New-Ctx -Identity local_identity; $ctx.State.Dns = @{ 'azl-n02.lab.example' = @('192.0.2.12') }
        (Invoke-Id 'ID-DNS-001' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Failed'
    }
    It 'is skipped when no DNS server answers' {
        $ctx = New-Ctx; $ctx.State.Dns['__silent'] = @('192.0.2.4')
        (Invoke-Id 'ID-DNS-001' $ctx)[0].Status | Should -Be 'Skipped'
    }
}

Describe 'ID-DNS-002 CNO and VCO records' {
    It 'passes when the cluster name resolves and DNS has secure updates' { (Invoke-Id 'ID-DNS-002' (New-Ctx))[0].Status | Should -Be 'Passed' }
    It 'warns for a missing CNO when DNS has secure dynamic updates' {
        $ctx = New-Ctx; $ctx.State.Dns.Remove('azl01.lab.example')
        (Invoke-Id 'ID-DNS-002' $ctx)[0].Status | Should -Be 'Warning'
    }
    It 'fails for a missing CNO when DNS has no secure dynamic updates, and tells about the VCO' {
        $ctx = New-Ctx -Infra (New-Infra -Dns @('192.0.2.53')); $ctx.State.Dns.Remove('azl01.lab.example')
        $r = Invoke-Id 'ID-DNS-002' $ctx
        $r[0].Status | Should -Be 'Failed'
        $r[1].Status | Should -Be 'Warning'
        $r[1].Message | Should -Match 'VCO'
    }
    It 'is skipped when no DNS server answers' {
        $ctx = New-Ctx; $ctx.State.Dns['__silent'] = @('192.0.2.4')
        (Invoke-Id 'ID-DNS-002' $ctx)[0].Status | Should -Be 'Skipped'
    }
}

Describe 'ID-AD-009 nodes resolve the domain and reach the domain controllers' {
    It 'passes' { Get-Status (Invoke-Id 'ID-AD-009' (New-Ctx)) | Select-Object -Unique | Should -Be 'Passed' }
    It 'fails when a node cannot resolve the domain' {
        $ctx = New-Ctx
        $n = New-GoodNode 'azl-n01'; $n.dnsq[0].ok = $false; $n.dnsq[0].error = 'DNS name does not exist'
        $ctx.State.Nodes['azl-n01'] = $n
        (Invoke-Id 'ID-AD-009' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Failed'
    }
    It 'fails when ADWS (9389) is not reachable' {
        $ctx = New-Ctx
        $n = New-GoodNode 'azl-n02'; ($n.tcp | Where-Object port -eq 9389).ok = $false
        $ctx.State.Nodes['azl-n02'] = $n
        (Invoke-Id 'ID-AD-009' $ctx | Where-Object Node -eq 'azl-n02').Status | Should -Be 'Failed'
    }
    It 'warns when only LDAP or Kerberos is blocked' {
        $ctx = New-Ctx
        $n = New-GoodNode 'azl-n02'; ($n.tcp | Where-Object port -eq 88).ok = $false
        $ctx.State.Nodes['azl-n02'] = $n
        (Invoke-Id 'ID-AD-009' $ctx | Where-Object Node -eq 'azl-n02').Status | Should -Be 'Warning'
    }
    It 'is skipped for a node that cannot be read' {
        $ctx = New-Ctx; $ctx.State.Nodes['azl-n01'] = 'connection refused'
        $r = Invoke-Id 'ID-AD-009' $ctx
        ($r | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Skipped'
        ($r | Where-Object Node -eq 'azl-n02').Status | Should -Be 'Passed'
    }
}

Describe 'ID-AD-010 domain join state of the nodes' {
    It 'passes for a workgroup node' { Get-Status (Invoke-Id 'ID-AD-010' (New-Ctx)) | Select-Object -Unique | Should -Be 'Passed' }
    It 'passes for a joined node with the deployment user in local Administrators (2610)' {
        $ctx = New-Ctx -Settings @{ solutionVersion = '12.2610.1004.50' }
        $n = New-GoodNode 'azl-n01' -Joined $true; $n.admins += 'LAB\lcm-azl01'; $ctx.State.Nodes['azl-n01'] = $n
        (Invoke-Id 'ID-AD-010' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Passed'
    }
    It 'fails for a joined node without the deployment user in local Administrators' {
        $ctx = New-Ctx; $ctx.State.Nodes['azl-n01'] = (New-GoodNode 'azl-n01' -Joined $true)
        $r = Invoke-Id 'ID-AD-010' $ctx | Where-Object Node -eq 'azl-n01'
        $r.Status | Should -Be 'Failed'
        $r.Remedy | Should -Match "Add-LocalGroupMember -Group 'Administrators' -Member 'LAB\\lcm-azl01'"
    }
    It 'fails for a node joined to another domain' {
        $ctx = New-Ctx; $n = New-GoodNode 'azl-n01' -Joined $true; $n.domain = 'other.example'; $ctx.State.Nodes['azl-n01'] = $n
        (Invoke-Id 'ID-AD-010' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Failed'
    }
    It 'fails for a joined node when the target version is older than 2604' {
        $ctx = New-Ctx -Settings @{ solutionVersion = '12.2510.1002.10' }
        $n = New-GoodNode 'azl-n01' -Joined $true; $n.admins += 'LAB\lcm-azl01'; $ctx.State.Nodes['azl-n01'] = $n
        $r = Invoke-Id 'ID-AD-010' $ctx | Where-Object Node -eq 'azl-n01'
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match '2604'
    }
    It 'fails for a broken secure channel' {
        $ctx = New-Ctx; $n = New-GoodNode 'azl-n01' -Joined $true; $n.admins += 'LAB\lcm-azl01'; $n.secureChannel = $false; $ctx.State.Nodes['azl-n01'] = $n
        (Invoke-Id 'ID-AD-010' $ctx | Where-Object Node -eq 'azl-n01').Message | Should -Match 'secure channel'
    }
    It 'is skipped for a node that rejects the credential' {
        $ctx = New-Ctx; $ctx.State.Nodes['azl-n01'] = 'Access is denied'
        (Invoke-Id 'ID-AD-010' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Skipped'
    }
}

Describe 'ID-AD-011 disjoint namespace' {
    It 'is not applicable to a workgroup node' { (Invoke-Id 'ID-AD-011' (New-Ctx) | Select-Object -First 1).Status | Should -Be 'NotApplicable' }
    It 'passes when the suffix matches the domain' {
        $ctx = New-Ctx; $ctx.State.Nodes['azl-n01'] = (New-GoodNode 'azl-n01' -Joined $true)
        (Invoke-Id 'ID-AD-011' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Passed'
    }
    It 'fails when the suffix differs' {
        $ctx = New-Ctx; $n = New-GoodNode 'azl-n01' -Joined $true; $n.primarySuffix = 'corp.example'; $ctx.State.Nodes['azl-n01'] = $n
        $r = Invoke-Id 'ID-AD-011' $ctx | Where-Object Node -eq 'azl-n01'
        $r.Status | Should -Be 'Failed'
        $r.Remedy | Should -Match 'ConnectionSpecificSuffix'
    }
    It 'is skipped for an unreadable node' {
        $ctx = New-Ctx; $ctx.State.Nodes.Remove('azl-n01')
        (Invoke-Id 'ID-AD-011' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Skipped'
    }
}

Describe 'ID-AD-012 KDS root key' {
    It 'is not applicable unless the file asks for gMSA, and says why' {
        $r = Invoke-Id 'ID-AD-012' (New-Ctx)
        $r[0].Status | Should -Be 'NotApplicable'
        $r[0].Message | Should -Match 'gMSA'
        (Get-Def 'ID-AD-012').Blocking | Should -BeFalse
    }
    It 'passes when gMSA is asked for and a root key exists' {
        $infra = New-Infra; $infra.identity.active_directory.use_gmsa = $true
        $ctx = New-Ctx -Infra $infra; Add-AdRoute $ctx.State 'msKds-ProvRootKey' @(New-AdEntry 'CN=guid,CN=Master Root Keys,CN=Group Key Distribution Service,CN=Services,CN=Configuration,DC=lab,DC=example')
        (Invoke-Id 'ID-AD-012' $ctx)[0].Status | Should -Be 'Passed'
    }
    It 'fails when gMSA is asked for and there is no root key' {
        $infra = New-Infra; $infra.identity.active_directory.use_gmsa = $true
        $ctx = New-Ctx -Infra $infra; Add-AdRoute $ctx.State 'msKds-ProvRootKey' @()
        (Invoke-Id 'ID-AD-012' $ctx)[0].Status | Should -Be 'Failed'
    }
    It 'is skipped when gMSA is asked for and the directory cannot be read' {
        $infra = New-Infra; $infra.identity.active_directory.use_gmsa = $true
        $ctx = New-Ctx -Infra $infra; Add-AdRoute $ctx.State 'msKds-ProvRootKey' -Unreachable
        (Invoke-Id 'ID-AD-012' $ctx)[0].Status | Should -Be 'Skipped'
    }
}

Describe 'local identity checks' {
    BeforeEach { $script:Li = New-Ctx -Identity local_identity }

    It 'ID-LI-001 passes for a good file' { (Invoke-Id 'ID-LI-001' $script:Li)[0].Status | Should -Be 'Passed' }
    It 'ID-LI-001 fails for <Name>' -ForEach @(
        @{ Name = 'no zone'; Key = 'dns_zone'; Value = '' }
        @{ Name = 'a zone that is not an FQDN'; Key = 'dns_zone'; Value = 'workgroup' }
        @{ Name = 'a bad DNS server configuration'; Key = 'dns_server_config'; Value = 'something' }
        @{ Name = 'a forwarder configuration without forwarders'; Key = 'dns_server_config'; Value = 'use_forwarder' }
    ) {
        $infra = New-Infra -Identity local_identity; $infra.identity.local_identity[$Key] = $Value
        (Invoke-Id 'ID-LI-001' (New-Ctx -Infra $infra))[0].Status | Should -Be 'Failed'
    }

    It 'ID-LI-002 passes with static addresses' { (Invoke-Id 'ID-LI-002' $script:Li)[0].Status | Should -Be 'Passed' }
    It 'ID-LI-002 fails when DHCP is used' {
        $infra = New-Infra -Identity local_identity; $infra.networking.management.use_dhcp = $true
        (Invoke-Id 'ID-LI-002' (New-Ctx -Infra $infra))[0].Status | Should -Be 'Failed'
    }

    It 'ID-LI-003 passes when every node and the system have an A record' { (Invoke-Id 'ID-LI-003' $script:Li)[0].Status | Should -Be 'Passed' }
    It 'ID-LI-003 fails for a missing system record (the first infrastructure address)' {
        $script:Li.State.Dns.Remove('azl01.lab.example')
        $r = Invoke-Id 'ID-LI-003' $script:Li
        $r[0].Status | Should -Be 'Failed'
        $r[0].Message | Should -Match '192.0.2.20'
    }
    It 'ID-LI-003 is skipped when the DNS servers are silent' {
        $script:Li.State.Dns['__silent'] = @('192.0.2.4')
        (Invoke-Id 'ID-LI-003' $script:Li)[0].Status | Should -Be 'Skipped'
    }
    It 'ID-LI-003 does not apply with a forwarder' {
        [bool](& (Get-Def 'ID-LI-003').Applies (New-Ctx -Infra (New-Infra -Identity local_identity -DnsConfig use_forwarder))) | Should -BeFalse
    }

    It 'ID-LI-004 passes for workgroup nodes that resolve the zone' { Get-Status (Invoke-Id 'ID-LI-004' $script:Li) | Select-Object -Unique | Should -Be 'Passed' }
    It 'ID-LI-004 fails for a joined node' {
        $script:Li.State.Nodes['azl-n01'] = (New-GoodNode 'azl-n01' -Joined $true)
        (Invoke-Id 'ID-LI-004' $script:Li | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Failed'
    }
    It 'ID-LI-004 fails when a node cannot resolve the zone names' {
        $n = New-GoodNode 'azl-n02'; ($n.dnsq | Where-Object name -eq 'azl-n01.lab.example')[0].ok = $false; $script:Li.State.Nodes['azl-n02'] = $n
        (Invoke-Id 'ID-LI-004' $script:Li | Where-Object Node -eq 'azl-n02').Status | Should -Be 'Failed'
    }
    It 'ID-LI-004 is skipped for an unreachable node' {
        $script:Li.State.Nodes['azl-n01'] = 'connection refused'
        (Invoke-Id 'ID-LI-004' $script:Li | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Skipped'
    }

    It 'ID-LI-005 passes with sshd running' { Get-Status (Invoke-Id 'ID-LI-005' $script:Li) | Select-Object -Unique | Should -Be 'Passed' }
    It 'ID-LI-005 fails with no sshd or a stopped sshd' {
        $a = New-GoodNode 'azl-n01'; $a.sshd = $null; $script:Li.State.Nodes['azl-n01'] = $a
        $b = New-GoodNode 'azl-n02'; $b.sshd.status = 'Stopped'; $script:Li.State.Nodes['azl-n02'] = $b
        Get-Status (Invoke-Id 'ID-LI-005' $script:Li) | Select-Object -Unique | Should -Be 'Failed'
    }
    It 'ID-LI-005 is skipped for an unreachable node' {
        $script:Li.State.Nodes.Clear()
        Get-Status (Invoke-Id 'ID-LI-005' $script:Li) | Select-Object -Unique | Should -Be 'Skipped'
    }
}

Describe 'local administrator checks (both modes)' {
    It 'ID-LA-001 passes in both modes' {
        foreach ($m in 'active_directory', 'local_identity') { (Invoke-Id 'ID-LA-001' (New-Ctx -Identity $m))[0].Status | Should -Be 'Passed' }
    }
    It 'ID-LA-001 fails for <Name>' -ForEach @(
        @{ Name = 'the built-in Administrator'; User = 'Administrator'; Pw = 'keyvault://kv-test/local-admin' }
        @{ Name = 'an empty name'; User = ''; Pw = 'keyvault://kv-test/local-admin' }
        @{ Name = 'a missing password reference'; User = 'azl-admin'; Pw = '' }
    ) {
        $infra = New-Infra; $infra.identity.local_admin = @{ username = $User; password = $Pw }
        (Invoke-Id 'ID-LA-001' (New-Ctx -Infra $infra))[0].Status | Should -Be 'Failed'
    }

    It 'ID-LA-002 passes, fails for a weak password and is skipped without the secret' {
        (Invoke-Id 'ID-LA-002' (New-Ctx))[0].Status | Should -Be 'Passed'
        $weak = New-Ctx; $weak.State.Secrets['keyvault://kv-test/local-admin'] = 'weak'
        $r = Invoke-Id 'ID-LA-002' $weak
        $r[0].Status | Should -Be 'Failed'
        $r[0].Message | Should -Not -Match 'weak'
        $none = New-Ctx; $none.State.Secrets.Clear()
        (Invoke-Id 'ID-LA-002' $none)[0].Status | Should -Be 'Skipped'
    }

    It 'ID-LA-003 passes when the session opens, in both modes' {
        foreach ($m in 'active_directory', 'local_identity') {
            $ctx = New-Ctx -Identity $m
            Get-Status (Invoke-Id 'ID-LA-003' $ctx) | Select-Object -Unique | Should -Be 'Passed'
            @($ctx.State.Calls | Where-Object { $_ -like 'remote:*' }).Count | Should -Be 2
        }
    }
    It 'ID-LA-003 fails when the node rejects the credential' {
        $ctx = New-Ctx; $ctx.State.Nodes['azl-n01'] = 'Access is denied.'
        $r = Invoke-Id 'ID-LA-003' $ctx
        ($r | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Failed'
        ($r | Where-Object Node -eq 'azl-n02').Status | Should -Be 'Passed'
    }
    It 'ID-LA-003 is skipped when the node cannot be reached' {
        $ctx = New-Ctx; $ctx.State.Nodes.Remove('azl-n01')
        $r = Invoke-Id 'ID-LA-003' $ctx | Where-Object Node -eq 'azl-n01'
        $r.Status | Should -Be 'Skipped'
        $r.Message | Should -Match 'could not be reached'
    }
    It 'ID-LA-003 is skipped when the secret cannot be read' {
        $ctx = New-Ctx; $ctx.State.Secrets.Clear()
        Get-Status (Invoke-Id 'ID-LA-003' $ctx) | Select-Object -Unique | Should -Be 'Skipped'
    }

    It 'ID-LA-004 passes for an enabled local administrator that is not RID 500' {
        foreach ($m in 'active_directory', 'local_identity') { Get-Status (Invoke-Id 'ID-LA-004' (New-Ctx -Identity $m)) | Select-Object -Unique | Should -Be 'Passed' }
    }
    It 'ID-LA-004 fails for <Name>' -ForEach @(
        @{ Name = 'a missing account'; Mutate = { param($n) $n.admin.exists = $false } }
        @{ Name = 'a disabled account'; Mutate = { param($n) $n.admin.enabled = $false } }
        @{ Name = 'the renamed built-in Administrator (RID 500)'; Mutate = { param($n) $n.admin.sid = 'S-1-5-21-1-2-3-500' } }
        @{ Name = 'an account that is not in Administrators'; Mutate = { param($n) $n.admins = @('azl-n01\Administrator') } }
    ) {
        $ctx = New-Ctx; $n = New-GoodNode 'azl-n01'; & $Mutate $n; $ctx.State.Nodes['azl-n01'] = $n
        $r = Invoke-Id 'ID-LA-004' $ctx | Where-Object Node -eq 'azl-n01'
        $r.Status | Should -Be 'Failed'
        $r.Remedy | Should -Match 'Add-LocalGroupMember'
    }
    It 'ID-LA-004 is skipped for an unreadable node' {
        $ctx = New-Ctx; $ctx.State.Nodes['azl-n02'] = 'Access is denied'
        (Invoke-Id 'ID-LA-004' $ctx | Where-Object Node -eq 'azl-n02').Status | Should -Be 'Skipped'
    }
}

Describe 'ID-DNS-003 DNS client of the nodes' {
    It 'passes in both modes' {
        foreach ($m in 'active_directory', 'local_identity') { Get-Status (Invoke-Id 'ID-DNS-003' (New-Ctx -Identity $m)) | Select-Object -Unique | Should -Be 'Passed' }
    }
    It 'fails when a node does not use the file''s DNS server' {
        $ctx = New-Ctx; $n = New-GoodNode 'azl-n01'; $n.dnsClient = @([pscustomobject]@{ alias = 'Port1'; servers = @('8.8.8.8') }); $ctx.State.Nodes['azl-n01'] = $n
        $r = Invoke-Id 'ID-DNS-003' $ctx | Where-Object Node -eq 'azl-n01'
        $r.Status | Should -Be 'Failed'
        $r.Remedy | Should -Match 'Set-DnsClientServerAddress'
    }
    It 'fails when an Azure endpoint does not resolve' {
        $ctx = New-Ctx; $n = New-GoodNode 'azl-n01'; ($n.dnsq | Where-Object name -eq 'management.azure.com')[0].ok = $false; $ctx.State.Nodes['azl-n01'] = $n
        (Invoke-Id 'ID-DNS-003' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Failed'
    }
    It 'is skipped for an unreadable node and fails with no DNS servers in the file' {
        $ctx = New-Ctx; $ctx.State.Nodes.Remove('azl-n01')
        (Invoke-Id 'ID-DNS-003' $ctx | Where-Object Node -eq 'azl-n01').Status | Should -Be 'Skipped'
        (Invoke-Id 'ID-DNS-003' (New-Ctx -Infra (New-Infra -Dns @())))[0].Status | Should -Be 'Failed'
    }
}
