#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the host-side check of the computer object's OU over LDAP after the DomainJoin restart (the node cannot always read its own distinguished name right after
# the join): the lookup, the verification, the plan, the step, the finalize of an open marker, and the steps that go on after an unverified OU. No node, no domain
# controller and no Azure is touched: the LDAP query and the transport are fakes.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/DomainJoinVerify.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fakes keep the real signatures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mocks run in the module scope and read these through the global scope; AfterAll removes them.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Repo = $repo
    $nc = [IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration')
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module (Join-Path $nc 'AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $nc 'AzlNodeTransport.psm1') -Force
    Import-Module (Join-Path $nc 'AzlDomainJoin.psm1') -Force
    Import-Module (Join-Path $nc 'AzlNodeConfiguration.psm1') -Force
    Import-Module (Join-Path $nc 'AzlOsConfigurationRun.psm1') -Force
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    $script:Password = 'Zq9!SentinelJoinPw-4711'
    $script:Resolver = { param($Ref) 'Zq9!SentinelJoinPw-4711' }
    $script:OuPath = 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
    $script:DnRight = 'CN=iic-n01,OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
    $script:DnWrong = 'CN=iic-n01,OU=Old,DC=improbability,DC=cloud'

    function Get-DjInfra([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Fixture -Raw) -Ordered
        # The domain controllers the host-side lookup may ask (the fixture lists none).
        $doc.identity.active_directory.domain_controllers = @('192.0.2.4', '192.0.2.5')
        if ($Change) { & $Change $doc }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        Import-AzlInfrastructure -Path $file -SkipValidation
    }
    function Get-DjSpec([scriptblock]$Change, [int]$Node = 0) {
        $infra = Get-DjInfra $Change
        Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[$Node]
    }
    function Get-DjState([hashtable]$Set = @{}) {
        $ds = [ordered]@{
            partOfDomain = $false; domain = 'WORKGROUP'; host = 'iic-n01'; boot = '2026-11-07T10:00:00Z'; dn = ''
            dnsOk = $true; dnsAddresses = @('192.0.2.4'); dnsError = ''; srvOk = $true; srvTargets = @('dc1.improbability.cloud'); dcReachable = $true; dcUsed = 'dc1.improbability.cloud'
            skewSeconds = 0.4; secureChannel = $null; inCluster = $false; localAdmins = @('azl-admin', 'Administrator'); marker = $null
        }
        foreach ($k in $Set.Keys) { $ds[$k] = $Set[$k] }
        [pscustomobject]@{ host = 'iic-n01'; boot = [string]$ds.boot; domainJoin = [pscustomobject]$ds; err = [pscustomobject]@{} }
    }
    # A node that joined and restarted, whose Group Policy has not stored its distinguished name yet (what the real node reported).
    function Get-JoinedState([hashtable]$Set = @{}) {
        $base = @{ partOfDomain = $true; domain = 'improbability.cloud'; dn = ''; secureChannel = $true
            localAdmins = @('azl-admin', 'IMPROBABILITY\sg-none', 'IMPROBABILITY\lcm-iic-clus01') }
        foreach ($k in $Set.Keys) { $base[$k] = $Set[$k] }
        Get-DjState $base
    }
    function Add-DjLdap([object]$State, [hashtable]$Set = @{}) {
        $l = [ordered]@{ checked = $true; found = $true; dn = $script:DnRight; dnsHostName = 'iic-n01.improbability.cloud'; ou = $script:OuPath; server = '192.0.2.4'; count = 1; authFailed = $false; error = '' }
        foreach ($k in $Set.Keys) { $l[$k] = $Set[$k] }
        Add-Member -InputObject $State.domainJoin -NotePropertyName ldap -NotePropertyValue ([pscustomobject]$l) -Force
        $State
    }
    function Add-DjOu([object]$State) {
        $ou = [pscustomobject]@{ checked = $true; exists = $true; gpOptions = 1; blockInheritance = $true; enforcedLinks = @(); error = '' }
        Add-Member -InputObject $State.domainJoin -NotePropertyName ou -NotePropertyValue $ou -Force
        $State
    }
    function Get-OpenMarker([string]$State = 'Restarting') { [pscustomobject]@{ state = $State; changeId = 'chg-open'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
    function Get-DjFeed([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        @(Get-Content -LiteralPath $Path -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    # The host-side LDAP query as a fake: records the request (and the password the seam was handed) and answers from $Answer.
    function New-LdapFake([hashtable]$Answer) {
        $log = [System.Collections.Generic.List[object]]::new()
        $block = {
            param($Request)
            $log.Add([pscustomobject]@{ Servers = @($Request.Servers); Port = $Request.Port; SearchRoot = $Request.SearchRoot; Filter = $Request.Filter; Properties = @($Request.Properties); TimeoutSeconds = $Request.TimeoutSeconds
                    User = $Request.Credential.UserName; Password = $Request.Credential.GetNetworkCredential().Password })
            if ($Answer.ContainsKey('Throw')) { throw $Answer.Throw }
            [pscustomobject]@{ Reachable = $(if ($Answer.ContainsKey('Reachable')) { $Answer.Reachable } else { $true }); Server = $(if ($Answer.ContainsKey('Server')) { $Answer.Server } else { '192.0.2.4' })
                Entries = @($Answer.Entries); AuthFailed = [bool]$Answer.AuthFailed; Error = [string]$Answer.Error }
        }.GetNewClosure()
        [pscustomobject]@{ Block = $block; Log = $log }
    }
    function New-Entry([string]$Dn, [string]$HostName = 'iic-n01.improbability.cloud') { [pscustomobject]@{ distinguishedName = $Dn; dnsHostName = $HostName } }

    # A fake transport. Each script is recognised by its text; the generic Apply script answers a Mpio feature change.
    function Get-DjTransport([hashtable]$Answer, [object[]]$Reads = @()) {
        $texts = @{ Apply = (Get-AzlNodePayload -Name DomainJoinApply); Restart = (Get-AzlNodePayload -Name DomainJoinRestart); OuCheck = (Get-AzlNodePayload -Name DomainJoinOuCheck); Generic = (Get-AzlNodePayload -Name Apply) }
        $log = [System.Collections.Generic.List[object]]::new()
        $queue = [System.Collections.Generic.Queue[object]]::new()
        foreach ($r in $Reads) { $queue.Enqueue($r) }
        $encode = {
            param($o)
            $bytes = [Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Depth 10 -Compress))
            $ms = [IO.MemoryStream]::new(); $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress); $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
            'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
        }.GetNewClosure()
        $transport = [pscustomobject]@{ Kind = 'WinRM'; Invoke = $null; Stage = $null; Log = $log }
        $transport.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            $kind = if ($Script -eq $texts.Apply) { "Apply:$($Parameters.mode)" } elseif ($Script -eq $texts.Restart) { 'Restart' } elseif ($Script -eq $texts.OuCheck) { 'OuCheck' } elseif ($Script -eq $texts.Generic) { 'Generic' } else { 'Read' }
            $plainSecrets = @{}
            if ($Secrets) { foreach ($k in $Secrets.Keys) { $plainSecrets[$k] = $Secrets[$k] } }
            $log.Add([pscustomobject]@{ Kind = $kind; Parameters = $Parameters; Secrets = $plainSecrets })
            if ($Answer.ContainsKey($kind) -and $Answer[$kind] -is [scriptblock]) { throw (& $Answer[$kind]) }
            if ($kind -eq 'Read') {
                if ($queue.Count -gt 0) { $Answer['_lastRead'] = $queue.Dequeue() }
                $out = $Answer['_lastRead']
            }
            else { $out = $Answer[$kind] }
            [pscustomobject]@{ Output = (& $encode $out); Failed = $false; Error = ''; State = 'Succeeded' }
        }.GetNewClosure()
        $transport.Stage = { throw 'no files' }
        $transport
    }
}

Describe 'Verification with the host-side LDAP answer' {
    It 'no node DN and LDAP says the right OU: the OU check passes and says where it was read' {
        $state = Add-DjLdap (Get-JoinedState)
        $checks = Test-AzlDomainJoinVerification -Spec (Get-DjSpec) -State $state
        @($checks | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        ($checks | Where-Object Check -eq 'OU').Detail | Should -Match 'LDAP'
    }
    It 'no node DN and LDAP says another OU: the OU check fails and names the distinguished name' {
        $state = Add-DjLdap (Get-JoinedState) @{ dn = $script:DnWrong }
        $bad = @(Test-AzlDomainJoinVerification -Spec (Get-DjSpec) -State $state | Where-Object { -not $_.Ok })
        $bad.Check | Should -Be @('OU')
        $bad[0].Detail | Should -Match ([regex]::Escape($script:DnWrong))
        $bad[0].Unverified | Should -BeFalse
    }
    It 'the node''s own DN wins when it has data, even if LDAP disagrees' {
        $state = Add-DjLdap (Get-JoinedState @{ dn = $script:DnRight }) @{ dn = $script:DnWrong }
        @(Test-AzlDomainJoinVerification -Spec (Get-DjSpec) -State $state | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
    }
    It 'no node DN and no LDAP answer: unverified, flagged as only unverified, with the reason of the host-side check' {
        $state = Add-DjLdap (Get-JoinedState) @{ checked = $false; found = $false; dn = ''; ou = ''; server = ''; count = 0; error = 'no domain controller answered on TCP 389 from this host' }
        $bad = @(Test-AzlDomainJoinVerification -Spec (Get-DjSpec) -State $state | Where-Object { -not $_.Ok })
        $bad.Check | Should -Be @('OU')
        $bad[0].Detail | Should -Match 'unverified'
        $bad[0].Detail | Should -Match 'no domain controller answered on TCP 389'
        $bad[0].Unverified | Should -BeTrue
    }
    It 'LDAP found no computer object: unverified, not OK' {
        $state = Add-DjLdap (Get-JoinedState) @{ found = $false; dn = ''; ou = ''; count = 0; error = 'no computer object named iic-n01 on 192.0.2.4' }
        $bad = @(Test-AzlDomainJoinVerification -Spec (Get-DjSpec) -State $state | Where-Object { -not $_.Ok })
        $bad[0].Unverified | Should -BeTrue
    }
}

Describe 'Get-AzlDomainJoinLdapComputer: the read-only lookup of the computer object' {
    BeforeEach { $script:Spec = Get-DjSpec }
    It 'asks the domain controllers of the file, in order, on 389, with the exact filter and the join credential, for 15 seconds' {
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnRight); Server = '192.0.2.5' }
        $r = Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver $script:Resolver -LdapQuery $fake.Block
        $call = $fake.Log[0]
        $call.Servers | Should -Be @($script:Spec.DomainJoin.DomainControllers)
        $call.Port | Should -Be 389
        $call.Filter | Should -Be '(&(objectCategory=computer)(cn=iic-n01))'
        $call.Properties | Should -Contain 'distinguishedname'
        $call.Properties | Should -Contain 'dnshostname'
        $call.SearchRoot | Should -Be 'DC=improbability,DC=cloud'
        $call.TimeoutSeconds | Should -Be 15
        $call.User | Should -Be 'IMPROBABILITY\lcm-iic-clus01'
        $call.Password | Should -Be $script:Password
        $r.checked | Should -BeTrue
        $r.found | Should -BeTrue
        $r.dn | Should -Be $script:DnRight
        $r.ou | Should -Be $script:OuPath
        $r.server | Should -Be '192.0.2.5'
        $r.dnsHostName | Should -Be 'iic-n01.improbability.cloud'
    }
    It 'escapes the filter characters of a name' {
        $spec = Get-DjSpec
        $spec.Name = 'a(b)*\c'
        $fake = New-LdapFake @{ Entries = @() }
        $null = Get-AzlDomainJoinLdapComputer -Spec $spec -SecretResolver $script:Resolver -LdapQuery $fake.Block
        $fake.Log[0].Filter | Should -Be '(&(objectCategory=computer)(cn=a\28b\29\2a\5cc))'
    }
    It 'uses the override account when the file sets domain_join_account' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.domain_join_account = [ordered]@{ username = 'svc-azl-join'; password = 'keyvault://kv-iic-mgmt-01/join-password' } }
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnRight) }
        $refs = [System.Collections.Generic.List[string]]::new()
        $resolver = { param($Ref) $refs.Add($Ref); 'pw' }.GetNewClosure()
        $null = Get-AzlDomainJoinLdapComputer -Spec $spec -SecretResolver $resolver -LdapQuery $fake.Block
        $fake.Log[0].User | Should -Be 'IMPROBABILITY\svc-azl-join'
        $refs | Should -Be @('keyvault://kv-iic-mgmt-01/join-password')
    }
    It 'no computer object: checked, not found, with the reason' {
        $fake = New-LdapFake @{ Entries = @() }
        $r = Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver $script:Resolver -LdapQuery $fake.Block
        $r.checked | Should -BeTrue
        $r.found | Should -BeFalse
        $r.error | Should -Match 'no computer object named iic-n01'
    }
    It 'two objects with the name: the one whose dnsHostName is the node''s wins; otherwise it is ambiguous and not found' {
        $fake = New-LdapFake @{ Entries = @((New-Entry $script:DnWrong 'other.improbability.cloud'), (New-Entry $script:DnRight)) }
        (Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver $script:Resolver -LdapQuery $fake.Block).dn | Should -Be $script:DnRight
        $fake2 = New-LdapFake @{ Entries = @((New-Entry $script:DnWrong ''), (New-Entry $script:DnRight '')) }
        $r2 = Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver $script:Resolver -LdapQuery $fake2.Block
        $r2.found | Should -BeFalse
        $r2.error | Should -Match 'OU=Old'
        $r2.error | Should -Match 'OU=iic-clus01'
    }
    It 'an object whose dnsHostName is another machine''s is not this node''s' {
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnRight 'someone-else.improbability.cloud') }
        $r = Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver $script:Resolver -LdapQuery $fake.Block
        $r.found | Should -BeFalse
        $r.error | Should -Match 'someone-else'
    }
    It 'no domain controller reachable from this host: unverified (not checked), nothing thrown, latch untouched' {
        $fake = New-LdapFake @{ Reachable = $false; Entries = @() }
        $latch = @{ Tripped = $false; Reason = '' }
        $r = Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver $script:Resolver -LdapQuery $fake.Block -Latch $latch
        $r.checked | Should -BeFalse
        $r.found | Should -BeFalse
        $r.error | Should -Match 'TCP 389'
        $latch.Tripped | Should -BeFalse
    }
    It 'a rejected bind latches the credential for the whole run, and says so; the latch text carries no password' {
        $fake = New-LdapFake @{ AuthFailed = $true; Error = 'Logon failure: unknown user name or bad password.'; Entries = @() }
        $latch = @{ Tripped = $false; Reason = '' }
        $r = Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver $script:Resolver -LdapQuery $fake.Block -Latch $latch
        $r.authFailed | Should -BeTrue
        $r.checked | Should -BeFalse
        $latch.Tripped | Should -BeTrue
        $latch.Reason | Should -Match 'iic-n01'
        $latch.Reason | Should -Not -Match ([regex]::Escape($script:Password))
    }
    It 'a tripped latch: no secret read, no bind' {
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnRight) }
        $latch = @{ Tripped = $true; Reason = 'iic-n02: Logon failure' }
        $r = Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver { throw 'must not read the secret' } -LdapQuery $fake.Block -Latch $latch
        $fake.Log.Count | Should -Be 0
        $r.authFailed | Should -BeTrue
        $r.checked | Should -BeFalse
    }
    It 'a secret that cannot be read, or a query that throws, is an unverified answer, never an exception, and never carries the password' {
        $fake = New-LdapFake @{ Throw = 'the directory service is unavailable' }
        $r = Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver $script:Resolver -LdapQuery $fake.Block
        $r.checked | Should -BeFalse
        $r.error | Should -Match 'unavailable'
        $r2 = Get-AzlDomainJoinLdapComputer -Spec $script:Spec -SecretResolver { throw 'Forbidden: no get permission' } -LdapQuery $fake.Block
        $r2.checked | Should -BeFalse
        $r2.error | Should -Match "Can't read the join account's password"
        ($r, $r2 | ConvertTo-Json -Depth 5) | Should -Not -Match ([regex]::Escape($script:Password))
    }
    It 'a file without domain controllers has nothing to ask' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.domain_controllers = @() }
        $fake = New-LdapFake @{ Entries = @() }
        $r = Get-AzlDomainJoinLdapComputer -Spec $spec -SecretResolver $script:Resolver -LdapQuery $fake.Block
        $r.checked | Should -BeFalse
        $r.error | Should -Match 'domain_controllers'
        $fake.Log.Count | Should -Be 0
    }
}

Describe 'The default LDAP query: first reachable domain controller' {
    It 'takes the first address that answers on the port, in the order of the file, and none when nothing answers' {
        InModuleScope AzlDomainJoin {
            $probe = { param($Address, $Port, $Milliseconds) $Address -eq '192.0.2.6' -or $Address -eq '192.0.2.7' }
            Find-DjReachableServer -Server @('192.0.2.5', '192.0.2.6', '192.0.2.7') -Port 389 -Probe $probe | Should -Be '192.0.2.6'
            Find-DjReachableServer -Server @('192.0.2.5') -Port 389 -Probe $probe | Should -BeNullOrEmpty
        }
    }
}

Describe 'Plan: the OU of a member whose node cannot read its distinguished name' {
    BeforeEach { $script:Spec = Get-DjSpec }
    It 'LDAP says the right OU: Ok, no join, no move' {
        $items = @(Get-AzlDomainJoinPlanItem -Spec $script:Spec -State (Add-DjLdap (Get-JoinedState)) -Step @('DomainJoin'))
        $main = $items | Where-Object Item -eq 'domain membership'
        $main.Action | Should -Be 'Ok'
        $main.Current | Should -Match 'OU=iic-clus01'
        $main.Note | Should -Match 'LDAP'
        @($items | Where-Object { $_.Apply -and $_.Apply.kind -in 'domain-join', 'domain-move' }) | Should -BeNullOrEmpty
    }
    It 'LDAP says another OU: Blocked with the distinguished name, even with allow_ou_move (the object is never moved from a host-side answer)' {
        foreach ($allow in $false, $true) {
            $spec = Get-DjSpec { param($d) $d.identity.active_directory.join_options = [ordered]@{ allow_ou_move = $allow } }.GetNewClosure()
            $items = @(Get-AzlDomainJoinPlanItem -Spec $spec -State (Add-DjLdap (Get-JoinedState) @{ dn = $script:DnWrong; ou = 'OU=Old,DC=improbability,DC=cloud' }) -Step @('DomainJoin'))
            $main = $items | Where-Object Item -eq 'domain membership'
            $main.Action | Should -Be 'Blocked'
            $main.Note | Should -Match ([regex]::Escape($script:DnWrong))
            @($items | Where-Object { $_.Apply -and $_.Apply.kind -in 'domain-join', 'domain-move' }) | Should -BeNullOrEmpty
        }
    }
    It 'LDAP did not answer: Info as before (OU not read), with the reason of the host-side check, and no join' {
        $state = Add-DjLdap (Get-JoinedState) @{ checked = $false; found = $false; dn = ''; ou = ''; error = 'no domain controller answered on TCP 389 from this host' }
        $items = @(Get-AzlDomainJoinPlanItem -Spec $script:Spec -State $state -Step @('DomainJoin'))
        $main = $items | Where-Object Item -eq 'domain membership'
        $main.Action | Should -Be 'Info'
        $main.Note | Should -Match 'TCP 389'
        @($items | Where-Object { $_.Apply -and $_.Apply.kind -in 'domain-join', 'domain-move' }) | Should -BeNullOrEmpty
    }
    It 'the node''s own DN still wins over an LDAP answer' {
        $state = Add-DjLdap (Get-JoinedState @{ dn = $script:DnRight }) @{ dn = $script:DnWrong }
        (Get-AzlDomainJoinPlanItem -Spec $script:Spec -State $state -Step @('DomainJoin') | Where-Object Item -eq 'domain membership').Action | Should -Be 'Ok'
    }
    It 'right OU by LDAP but the restart marker was never completed: one finalize Change, after the restart has happened' {
        $state = Add-DjLdap (Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; marker = (Get-OpenMarker) })
        $items = @(Get-AzlDomainJoinPlanItem -Spec $script:Spec -State $state -Step @('DomainJoin'))
        $fin = @($items | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-finalize' })
        $fin.Count | Should -Be 1
        $fin[0].Apply.changeId | Should -Be 'chg-open'
        $fin[0].Action | Should -Be 'Change'
        @($items | Where-Object { $_.Apply -and $_.Apply.kind -in 'domain-join', 'domain-restart' }) | Should -BeNullOrEmpty
    }
    It 'a completed marker has nothing to finalize' {
        $done = [pscustomobject]@{ state = 'Completed'; changeId = 'x'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' }
        $state = Add-DjLdap (Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; marker = $done })
        @(Get-AzlDomainJoinPlanItem -Spec $script:Spec -State $state -Step @('DomainJoin') | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-finalize' }) | Should -BeNullOrEmpty
    }
    It 'with the restart still due, the restart comes first (no finalize yet)' {
        $state = Add-DjLdap (Get-JoinedState @{ marker = (Get-OpenMarker 'RebootExpected') })
        $items = @(Get-AzlDomainJoinPlanItem -Spec $script:Spec -State $state -Step @('DomainJoin'))
        @($items | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-restart' }).Count | Should -Be 1
        @($items | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-finalize' }) | Should -BeNullOrEmpty
    }
}

Describe 'The step: join, restart, and the OU read host-side' {
    BeforeEach {
        $script:Feed = Join-Path $TestDrive "feed-$([guid]::NewGuid().ToString('N').Substring(0, 6)).jsonl"
        $script:Ctx = @{ Path = $script:Feed; Method = 'Ztp'; SchemaVersion = '5.5.0' }
        $script:Spec = Get-DjSpec
        $script:JoinItem = Get-AzlDomainJoinPlanItem -Spec $script:Spec -State (Get-DjState) -Step @('DomainJoin') | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-join' }
        $script:NoDn = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z' }
        $script:Wait = { $script:NoDn }.GetNewClosure()
        $script:JoinAnswer = @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'joined' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
    }
    It 'the real run: the node has no DN and the locate call fails; LDAP says the right OU, so the join completes and the marker is finalized' {
        $answer = $script:JoinAnswer + @{ 'Apply:locate' = { 'The I/O operation has been aborted because of either a thread exit or an application request.' } }
        $t = Get-DjTransport $answer
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnRight) }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { $script:NoDn } -EventContext $script:Ctx -LdapQuery $fake.Block
        $r.Failed | Should -BeFalse
        $r.Joined | Should -BeTrue
        $fake.Log.Count | Should -Be 1
        @($t.Log | ForEach-Object Kind) | Should -Be @('Apply:join', 'Restart', 'Apply:locate', 'Apply:finalize')
        $joined = Get-DjFeed $script:Feed | Where-Object state -eq 'DomainJoined'
        $joined.dn | Should -Be $script:DnRight
        $joined.ouVerifiedBy | Should -Be 'ldap'
        (Get-Content -LiteralPath $script:Feed -Raw) | Should -Not -Match ([regex]::Escape($script:Password))
        ($r | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:Password))
    }
    It 'the node refreshes policy and finds its DN: LDAP is not asked at all' {
        $t = Get-DjTransport ($script:JoinAnswer + @{ 'Apply:locate' = @{ status = 'located'; dn = $script:DnRight } })
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnWrong) }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { $script:NoDn } -EventContext $script:Ctx -LdapQuery $fake.Block
        $r.Failed | Should -BeFalse
        $fake.Log.Count | Should -Be 0
    }
    It 'no DN on the node and LDAP says another OU: Failed naming the DN, not unverified, the marker is not completed' {
        $t = Get-DjTransport ($script:JoinAnswer + @{ 'Apply:locate' = @{ status = 'unverified'; dn = '' } })
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnWrong) }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { $script:NoDn } -EventContext $script:Ctx -LdapQuery $fake.Block
        $r.Failed | Should -BeTrue
        $r.Unverified | Should -BeFalse
        $r.Error | Should -Match ([regex]::Escape($script:DnWrong))
        @($t.Log | ForEach-Object Kind) | Should -Not -Contain 'Apply:finalize'
    }
    It 'no DN on the node and LDAP did not answer: Failed, flagged Unverified, the marker is not completed' {
        $t = Get-DjTransport ($script:JoinAnswer + @{ 'Apply:locate' = @{ status = 'unverified'; dn = '' } })
        $fake = New-LdapFake @{ Reachable = $false; Entries = @() }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { $script:NoDn } -EventContext $script:Ctx -LdapQuery $fake.Block
        $r.Failed | Should -BeTrue
        $r.Unverified | Should -BeTrue
        $r.Error | Should -Match 'OU.*unverified'
        $r.Error | Should -Match 'TCP 389'
        @($t.Log | ForEach-Object Kind) | Should -Not -Contain 'Apply:finalize'
    }
    It 'the LDAP bind is the credential''s attempt of the run: a rejected bind trips the latch the join shares' {
        $t = Get-DjTransport ($script:JoinAnswer + @{ 'Apply:locate' = @{ status = 'unverified'; dn = '' } })
        $fake = New-LdapFake @{ AuthFailed = $true; Error = 'Logon failure'; Entries = @() }
        $latch = @{ Tripped = $false; Reason = '' }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { $script:NoDn } -EventContext $script:Ctx -LdapQuery $fake.Block -Latch $latch
        $latch.Tripped | Should -BeTrue
        $r.Failed | Should -BeTrue
    }
    It 'finalize item: completes the marker with the marker''s change id and says DomainJoined with the OU read over LDAP' {
        $state = Add-DjLdap (Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; marker = (Get-OpenMarker) })
        $item = Get-AzlDomainJoinPlanItem -Spec $script:Spec -State $state -Step @('DomainJoin') | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-finalize' }
        $t = Get-DjTransport @{ 'Apply:finalize' = @{ status = 'finalized' } }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State $state -Item $item -SecretResolver { throw 'no secret needed' } -EventContext $script:Ctx
        $r.Failed | Should -BeFalse
        $r.Joined | Should -BeTrue
        @($t.Log | ForEach-Object Kind) | Should -Be @('Apply:finalize')
        $t.Log[0].Parameters.changeId | Should -Be 'chg-open'
        $t.Log[0].Secrets.Count | Should -Be 0
        $r.Changes[0].Status | Should -Be 'changed'
        (Get-DjFeed $script:Feed | Where-Object state -eq 'DomainJoined').ouVerifiedBy | Should -Be 'ldap'
    }
}

Describe 'Invoke-AzlNodeConfiguration: the run after a join whose verification failed' {
    BeforeEach {
        Mock -ModuleName AzlNodeConfiguration Start-Sleep {}
        $script:Feed = Join-Path $TestDrive "loop-$([guid]::NewGuid().ToString('N').Substring(0, 6)).jsonl"
        $script:Ctx = @{ Path = $script:Feed; Method = 'Ztp'; SchemaVersion = '5.5.0'; Phase = 'Apply' }
        $script:Spec = Get-DjSpec { param($d) $d.identity.active_directory.local_admin_members = @('sg-none') }
        $script:OuOk = @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $true; exists = $true; gpOptions = 1; blockInheritance = $true; enforcedLinks = @(); error = '' } } }
    }
    It 'joined, restart done, DN unreadable on the node, LDAP says the right OU: the marker is finalized, nothing is joined again, converged' {
        $stuck = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; marker = (Get-OpenMarker) }
        $done = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; marker = [pscustomobject]@{ state = 'Completed'; changeId = 'chg-open'; bootBefore = ''; domain = 'improbability.cloud'; error = '' } }
        $t = Get-DjTransport ($script:OuOk + @{ 'Apply:finalize' = @{ status = 'finalized' }; 'Apply:locate' = @{ status = 'unverified'; dn = '' } }) @($stuck, $done, $done)
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnRight) }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -EventContext $script:Ctx -LdapQuery $fake.Block
        $r.Converged | Should -BeTrue
        $kinds = @($t.Log | ForEach-Object Kind)
        $kinds | Should -Not -Contain 'Apply:join'
        $kinds | Should -Not -Contain 'Restart'
        $kinds | Should -Contain 'Apply:finalize'
        $t.Log | Where-Object Kind -eq 'Apply:finalize' | ForEach-Object { $_.Parameters.changeId | Should -Be 'chg-open' }
        $fake.Log.Count | Should -Be 1 -Because 'one bind for the node in this call'
        (Get-DjFeed $script:Feed | Where-Object state -eq 'DomainJoined').dn | Should -Be $script:DnRight
        $r.DomainJoin.domainJoined | Should -BeTrue
    }
    It 'joined, DN unreadable on the node, LDAP says another OU: Blocked with the DN named, nothing moved, not converged' {
        $stuck = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; marker = (Get-OpenMarker) }
        $t = Get-DjTransport ($script:OuOk + @{ 'Apply:finalize' = @{ status = 'finalized' }; 'Apply:move' = @{ status = 'moved' } }) @($stuck)
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnWrong) }
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.join_options = [ordered]@{ allow_ou_move = $true } }
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -EventContext $script:Ctx -LdapQuery $fake.Block
        $r.Converged | Should -BeFalse
        $blocked = $r.Blocked | Where-Object Item -eq 'domain membership'
        $blocked.Note | Should -Match ([regex]::Escape($script:DnWrong))
        @($t.Log | Where-Object Kind -like 'Apply:*') | Should -BeNullOrEmpty
    }
    It 'a plan (no -Execute) with the node unable to read its DN and LDAP saying the right OU: Ok, no change' {
        $stuck = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z' }
        $t = Get-DjTransport $script:OuOk @($stuck)
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnRight) }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Step 'DomainJoin' -SecretResolver $script:Resolver -EventContext @{ Path = $script:Feed; Method = 'Ztp'; Phase = 'Plan' } -LdapQuery $fake.Block
        ($r.Plan | Where-Object Item -eq 'domain membership').Action | Should -Be 'Ok'
        $r.Converged | Should -BeTrue
        @($t.Log | Where-Object Kind -like 'Apply:*') | Should -BeNullOrEmpty
    }
    It 'a member that is not in the domain of the file never asks LDAP' {
        $other = Get-JoinedState @{ domain = 'contoso.com' }
        $t = Get-DjTransport $script:OuOk @($other)
        $fake = New-LdapFake @{ Entries = @() }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Step 'DomainJoin' -SecretResolver $script:Resolver -LdapQuery $fake.Block
        $fake.Log.Count | Should -Be 0
        ($r.Plan | Where-Object Item -eq 'domain membership').Action | Should -Be 'Blocked'
    }
    It 'a tripped latch: the plan asks LDAP for nothing' {
        $stuck = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z' }
        $t = Get-DjTransport $script:OuOk @($stuck)
        $fake = New-LdapFake @{ Entries = @(New-Entry $script:DnRight) }
        $latch = @{ Tripped = $true; Reason = 'iic-n02: Logon failure' }
        $null = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Step 'DomainJoin' -SecretResolver { throw 'must not read' } -DomainJoinLatch $latch -LdapQuery $fake.Block
        $fake.Log.Count | Should -Be 0
    }
    It 'a join whose OU stays unverified does not skip the independent steps: MPIO is still applied after it, and the node stays not converged with the DomainJoin item Blocked' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.local_admin_members = @('sg-none') }
        $before = Add-DjOu (Get-DjState @{ san = $null })
        $before | Add-Member -NotePropertyName san -NotePropertyValue ([pscustomobject]@{ feature = 'Disabled'; hw = @(); lb = ''; set = [pscustomobject]@{}; iscsiSvc = ''; iscsiClaim = '' }) -Force
        $after = Add-DjOu (Get-JoinedState @{ boot = '2026-11-07T10:09:00Z' })
        $after | Add-Member -NotePropertyName san -NotePropertyValue ([pscustomobject]@{ feature = 'Disabled'; hw = @(); lb = ''; set = [pscustomobject]@{}; iscsiSvc = ''; iscsiClaim = '' }) -Force
        $enabled = Add-DjOu (Get-JoinedState @{ boot = '2026-11-07T10:09:00Z' })
        $enabled | Add-Member -NotePropertyName san -NotePropertyValue ([pscustomobject]@{ feature = 'Enabled'; hw = @(); lb = ''; set = [pscustomobject]@{}; iscsiSvc = ''; iscsiClaim = '' }) -Force
        $answer = $script:OuOk + @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'joined' }; Restart = @{ restartScheduled = $true }; 'Apply:locate' = @{ status = 'unverified'; dn = '' }; 'Apply:finalize' = @{ status = 'finalized' }
            Generic = @{ results = @([pscustomobject]@{ id = 'Mpio/feature'; status = 'changed'; detail = 'MultipathIO enabled' }); reboot = $false } }
        $t = Get-DjTransport $answer @($before, $before, $after, $after, $enabled)
        $fake = New-LdapFake @{ Reachable = $false; Entries = @() }
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -Step @('DomainJoin', 'Mpio') -SecretResolver $script:Resolver -EventContext $script:Ctx -LdapQuery $fake.Block
        @($t.Log | Where-Object Kind -eq 'Apply:join').Count | Should -Be 1
        $kinds = @($t.Log | ForEach-Object Kind)
        $kinds | Should -Contain 'Generic' -Because 'the MPIO change is applied after the join failed only as unverified'
        $kinds.IndexOf('Generic') | Should -BeGreaterThan $kinds.IndexOf('Apply:locate')
        @($t.Log | Where-Object Kind -eq 'Apply:finalize') | Should -BeNullOrEmpty
        @($r.Changes | Where-Object Id -eq 'Mpio/feature')[0].Status | Should -Be 'changed'
        ($r.Changes | Where-Object Status -eq 'failed').Count | Should -Be 1
        $r.Converged | Should -BeFalse
        $blocked = $r.Blocked | Where-Object Item -eq 'domain membership'
        $blocked | Should -Not -BeNullOrEmpty
        $blocked.Note | Should -Match 'unverified'
        $fake.Log.Count | Should -Be 1 -Because 'the answer of the step is reused in the later passes, one attempt per node'
    }
    It 'a join that fails for another reason (wrong OU, broken secure channel) still stops the node: the independent steps are not run' {
        $spec = Get-DjSpec
        $before = Add-DjOu (Get-DjState)
        $before | Add-Member -NotePropertyName san -NotePropertyValue ([pscustomobject]@{ feature = 'Disabled'; hw = @(); lb = ''; set = [pscustomobject]@{}; iscsiSvc = ''; iscsiClaim = '' }) -Force
        $after = Add-DjOu (Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; secureChannel = $false; dn = $script:DnRight })
        $answer = $script:OuOk + @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'joined' }; Restart = @{ restartScheduled = $true }; Generic = @{ results = @(); reboot = $false } }
        $t = Get-DjTransport $answer @($before, $before, $after)
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -Step @('DomainJoin', 'Mpio') -SecretResolver $script:Resolver -EventContext $script:Ctx -LdapQuery (New-LdapFake @{ Entries = @() }).Block
        @($t.Log | Where-Object Kind -eq 'Generic') | Should -BeNullOrEmpty
        $r.Converged | Should -BeFalse
    }
}
