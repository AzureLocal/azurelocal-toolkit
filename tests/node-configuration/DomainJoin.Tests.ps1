#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the DomainJoin step of the OS configuration, host side: the spec, the comparison, the step order, the join with its restart
# and verification, the events, the secrets. No node, no Active Directory and no Azure is touched; a fake transport answers.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/DomainJoin.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transport and wait blocks keep the real signatures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mocks run in the module scope and read these through the global scope; AfterAll removes them.')]
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

    function Get-DjInfra([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Fixture -Raw) -Ordered
        if ($Change) { & $Change $doc }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        Import-AzlInfrastructure -Path $file -SkipValidation
    }
    function Get-DjSpec([scriptblock]$Change, [int]$Node = 0) {
        $infra = Get-DjInfra $Change
        Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[$Node]
    }
    # What the Read script's domainJoin section returns.
    function Get-DjState([hashtable]$Set = @{}, [object]$Spec) {
        $ds = [ordered]@{
            partOfDomain = $false; domain = 'WORKGROUP'; host = 'iic-n01'; boot = '2026-11-07T10:00:00Z'; dn = ''
            dnsOk = $true; dnsAddresses = @('192.0.2.4'); dnsError = ''; srvOk = $true; srvTargets = @('dc1.improbability.cloud'); dcReachable = $true; dcUsed = 'dc1.improbability.cloud'
            skewSeconds = 0.4; secureChannel = $null; inCluster = $false; localAdmins = @('azl-admin', 'Administrator'); marker = $null
        }
        foreach ($k in $Set.Keys) { $ds[$k] = $Set[$k] }
        [pscustomobject]@{ host = 'iic-n01'; boot = [string]$ds.boot; domainJoin = [pscustomobject]$ds; err = [pscustomobject]@{} }
    }
    function Get-JoinedState([hashtable]$Set = @{}) {
        $base = @{ partOfDomain = $true; domain = 'improbability.cloud'; dn = 'CN=iic-n01,OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'; secureChannel = $true
            localAdmins = @('azl-admin', 'IMPROBABILITY\sg-none', 'IMPROBABILITY\lcm-iic-clus01') }
        foreach ($k in $Set.Keys) { $base[$k] = $Set[$k] }
        Get-DjState $base
    }
    function Add-DjOu([object]$State, [hashtable]$Set = @{}) {
        $ou = [ordered]@{ checked = $true; exists = $true; gpOptions = 1; blockInheritance = $true; enforcedLinks = @(); error = '' }
        foreach ($k in $Set.Keys) { $ou[$k] = $Set[$k] }
        Add-Member -InputObject $State.domainJoin -NotePropertyName ou -NotePropertyValue ([pscustomobject]$ou) -Force
        $State
    }
    function Get-DjItem([object]$Spec, [object]$State, [string[]]$Step = @('Hostname', 'DomainJoin'), [object[]]$Prior = @()) {
        @(Get-AzlDomainJoinPlanItem -Spec $Spec -State $State -Step $Step -Prior $Prior)
    }

    # A fake transport. Each script is recognised by its text. Calls are recorded WITH the secrets (the only place the password is allowed).
    function Get-DjTransport([hashtable]$Answer, [object[]]$Reads = @()) {
        $texts = @{ Apply = (Get-AzlNodePayload -Name DomainJoinApply); Restart = (Get-AzlNodePayload -Name DomainJoinRestart); OuCheck = (Get-AzlNodePayload -Name DomainJoinOuCheck) }
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
            $kind = if ($Script -eq $texts.Apply) { "Apply:$($Parameters.mode)" } elseif ($Script -eq $texts.Restart) { 'Restart' } elseif ($Script -eq $texts.OuCheck) { 'OuCheck' } else { 'Read' }
            $plainSecrets = @{}
            if ($Secrets) { foreach ($k in $Secrets.Keys) { $plainSecrets[$k] = $Secrets[$k] } }
            $log.Add([pscustomobject]@{ Kind = $kind; Parameters = $Parameters; Secrets = $plainSecrets })
            $answerKey = $kind
            if ($Answer.ContainsKey($answerKey) -and $Answer[$answerKey] -is [scriptblock]) { throw (& $Answer[$answerKey]) }
            if ($kind -eq 'Read') {
                if ($queue.Count -gt 0) { $Answer['_lastRead'] = $queue.Dequeue() }
                $out = $Answer['_lastRead']
            }
            else { $out = $Answer[$answerKey] }
            [pscustomobject]@{ Output = (& $encode $out); Failed = $false; Error = ''; State = 'Succeeded' }
        }.GetNewClosure()
        $transport.Stage = { throw 'no files' }
        $transport
    }
    function Get-DjFeed([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        @(Get-Content -LiteralPath $Path -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'Spec: who joins, where, with what' {
    It 'is applicable for an Active Directory design and uses the LCM user by default' {
        $dj = (Get-DjSpec).DomainJoin
        $dj.Applicable | Should -BeTrue
        $dj.Domain | Should -Be 'improbability.cloud'
        $dj.OuPath | Should -Be 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $dj.CredentialSource | Should -Be 'lcm_user'
        $dj.Username | Should -Be 'lcm-iic-clus01'
        $dj.PasswordRef | Should -Be 'keyvault://kv-iic-mgmt-01/lcm-password'
        $dj.HasAccount | Should -BeTrue
        $dj.AllowOuMove | Should -BeFalse
        $dj.RenameAfterJoin | Should -BeFalse
    }
    It 'uses domain_join_account when the file sets it (the optional override)' {
        $dj = (Get-DjSpec { param($d) $d.identity.active_directory.domain_join_account = [ordered]@{ username = 'svc-azl-join'; password = 'keyvault://kv-iic-mgmt-01/join-password' } }).DomainJoin
        $dj.CredentialSource | Should -Be 'domain_join_account'
        $dj.Username | Should -Be 'svc-azl-join'
        $dj.PasswordRef | Should -Be 'keyvault://kv-iic-mgmt-01/join-password'
    }
    It 'is not applicable for a local identity design, and asks the Read script nothing' {
        $spec = Get-DjSpec { param($d) $d.scenario.identity = 'local_identity' }
        $spec.DomainJoin.Applicable | Should -BeFalse
        (Get-AzlNodeReadParameter -Spec $spec).ContainsKey('domainJoin') | Should -BeFalse
    }
    It 'asks the Read script for the membership, with no secret' {
        $p = Get-AzlNodeReadParameter -Spec (Get-DjSpec)
        $p.domainJoin.domain | Should -Be 'improbability.cloud'
        $p.domainJoin.ou | Should -Be 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        ($p | ConvertTo-Json -Depth 6) | Should -Not -Match 'keyvault|password'
    }
    It 'the local administrators default to the group that administers the instance, and the LCM user, qualified with the NetBIOS name' {
        $spec = Get-DjSpec { param($d)
            $d.identity.active_directory.netbios_name = 'IIC'
            $d.identity.active_directory.security_groups = @([ordered]@{ name = 'sg-iic-admins'; purpose = 'Administrators of the instance' }, [ordered]@{ name = 'sg-readers'; purpose = 'Read only' })
        }
        $spec.DomainJoin.LocalAdminMembers | Should -Be @('IIC\sg-iic-admins', 'IIC\lcm-iic-clus01')
    }
    It 'takes local_admin_members from the file when it lists them, and falls back to the first label of the domain without a NetBIOS name' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.local_admin_members = @('ops-team', 'CORP\other') }
        $spec.DomainJoin.LocalAdminMembers | Should -Be @('IMPROBABILITY\ops-team', 'CORP\other')
    }
    It 'reads the environment class; missing or unknown is production' {
        (Get-DjSpec).DomainJoin.EnvironmentClass | Should -Be 'production'
        (Get-DjSpec { param($d) $d.scenario.environment_class = 'lab' }).DomainJoin.EnvironmentClass | Should -Be 'lab'
        (Get-DjSpec { param($d) $d.scenario.environment_class = 'nonsense' }).DomainJoin.EnvironmentClass | Should -Be 'production'
    }
}

Describe 'Comparison: the plan and compare matrix' {
    It 'not joined: Change (join), with the LCM user' {
        $spec = Get-DjSpec
        $i = Get-DjItem $spec (Get-DjState) | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Change'
        $i.Apply.kind | Should -Be 'domain-join'
        $i.Apply.ou | Should -Be 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $i.Note | Should -Match 'lcm_user'
        $i.Current | Should -Be 'workgroup WORKGROUP'
    }
    It 'joined to the right domain and OU: Ok, and the secure channel is Ok' {
        $items = Get-DjItem (Get-DjSpec) (Get-JoinedState)
        ($items | Where-Object Item -eq 'domain membership').Action | Should -Be 'Ok'
        ($items | Where-Object Item -eq 'secure channel').Action | Should -Be 'Ok'
        @($items | Where-Object { $_.Action -in 'Change', 'Blocked' }) | Should -BeNullOrEmpty
    }
    It 'compares the OU without case and without spaces after the commas' {
        $state = Get-JoinedState @{ dn = 'CN=iic-n01, ou=IIC-CLUS01, OU=azurelocal, dc=Improbability, DC=cloud' }
        ($state | ForEach-Object { Get-DjItem (Get-DjSpec) $_ } | Where-Object Item -eq 'domain membership').Action | Should -Be 'Ok'
    }
    It 'joined, wrong OU, allow_ou_move false: Blocked (nothing is moved by default)' {
        $state = Get-JoinedState @{ dn = 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud' }
        $i = Get-DjItem (Get-DjSpec) $state | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Blocked'
        $i.Note | Should -Match 'allow_ou_move'
        $i.Apply | Should -BeNullOrEmpty
    }
    It 'joined, wrong OU, allow_ou_move true, before the deployment: Change (move)' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.join_options = [ordered]@{ allow_ou_move = $true } }
        $i = Get-DjItem $spec (Get-JoinedState @{ dn = 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud' }) | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Change'
        $i.Apply.kind | Should -Be 'domain-move'
        $i.Apply.dn | Should -Be 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud'
    }
    It 'joined, wrong OU, the node is in a cluster (after the deployment): Blocked even with allow_ou_move true (Microsoft: a move is not supported)' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.join_options = [ordered]@{ allow_ou_move = $true } }
        $i = Get-DjItem $spec (Get-JoinedState @{ dn = 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud'; inCluster = $true }) | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Blocked'
        $i.Note | Should -Match 'not support'
        $i.Apply | Should -BeNullOrEmpty
    }
    It 'joined to a different domain: Blocked, never unjoined' {
        $i = Get-DjItem (Get-DjSpec) (Get-JoinedState @{ domain = 'contoso.com' }) | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Blocked'
        $i.Note | Should -Match 'never unjoined|never be unjoined|never.*automatically'
        $i.Apply | Should -BeNullOrEmpty
    }
    It 'host name differs and the Hostname step is not in the run: Blocked, the Hostname step must run first' {
        $i = Get-DjItem (Get-DjSpec) (Get-DjState @{ host = 'WIN-ABC123' }) @('DomainJoin') | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Blocked'
        $i.Note | Should -Match 'Hostname step must run first'
        $i.Note | Should -Match 'WIN-ABC123'
    }
    It 'host name differs and the Hostname step changes it in this pass: Skipped, it waits' {
        $prior = @([pscustomobject]@{ Step = 'Hostname'; Action = 'Change' })
        $i = Get-DjItem (Get-DjSpec) (Get-DjState @{ host = 'WIN-ABC123' }) @('Hostname', 'DomainJoin') $prior | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Skipped'
        $i.Note | Should -Match 'Waits for the Hostname step'
    }
    It 'waits for a pending Network, Dns or Time change: Skipped' -ForEach @('Network', 'Dns', 'Time', 'UnusedAdapters') {
        $prior = @([pscustomobject]@{ Step = $_; Action = 'Change' })
        $i = Get-DjItem (Get-DjSpec) (Get-DjState @{ dnsOk = $false }) @('DomainJoin') $prior | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Skipped'
        $i.Note | Should -Match $_
    }
    It 'DNS cannot resolve the domain: Blocked with the reason' {
        $i = Get-DjItem (Get-DjSpec) (Get-DjState @{ dnsOk = $false; dnsError = 'DNS name does not exist' }) @('DomainJoin') | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Blocked'
        $i.Note | Should -Match 'cannot resolve improbability.cloud'
        $i.Note | Should -Match 'DNS name does not exist'
    }
    It 'no domain controller SRV record: Blocked' {
        $i = Get-DjItem (Get-DjSpec) (Get-DjState @{ srvOk = $false }) @('DomainJoin') | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Blocked'
        $i.Note | Should -Match 'SRV'
    }
    It 'SRV discovery failed but every controller of the file answers on TCP 389 and resolves by name: the join is a Change with -Server, and a Warning item says why SRV failed' {
        $srvReason = '192.168.211.30 UDP 4012 ms: This operation returned because the timeout period expired [ERROR_TIMEOUT,Microsoft.DnsClient.Commands.ResolveDnsName]; 192.168.211.30 TCP 15 ms: Server failure'
        $state = Get-DjState @{
            srvOk = $false; srvTargets = @(); srvReason = $srvReason; srvServers = @('192.168.211.30', '192.168.211.31'); dcAllOk = $true; dcServer = 'mgmt-ral-dc-01.haas.mgmt'
            dcChecks = @([pscustomobject]@{ address = '192.168.211.30'; tcp389 = $true; name = 'mgmt-ral-dc-01.haas.mgmt'; resolves = $true; ok = $true; error = '' }, [pscustomobject]@{ address = '192.168.211.31'; tcp389 = $true; name = 'mgmt-ral-dc-02.haas.mgmt'; resolves = $true; ok = $true; error = '' })
        }
        $items = Get-DjItem (Get-DjSpec) $state @('DomainJoin')
        $join = $items | Where-Object Item -eq 'domain membership'
        $join.Action | Should -Be 'Change'
        $join.Apply.kind | Should -Be 'domain-join'
        $join.Apply.server | Should -Be 'mgmt-ral-dc-01.haas.mgmt'
        $join.Note | Should -Match '-Server'
        $warn = $items | Where-Object Item -eq 'domain controller discovery'
        $warn.Action | Should -Be 'Info'
        $warn.Note | Should -Match '^WARNING'
        $warn.Note | Should -Match 'SRV'
        $warn.Note | Should -Match 'timeout period expired'
        $warn.Note | Should -Match 'DNS servers asked: 192\.168\.211\.30, 192\.168\.211\.31'
        $warn.Note | Should -Match 'mgmt-ral-dc-01\.haas\.mgmt'
        @($items | Where-Object Action -eq 'Blocked') | Should -BeNullOrEmpty
    }
    It 'a join where SRV worked has no -Server and no discovery warning' {
        $items = Get-DjItem (Get-DjSpec) (Get-DjState) @('DomainJoin')
        ($items | Where-Object Item -eq 'domain membership').Apply.server | Should -BeNullOrEmpty
        @($items | Where-Object Item -eq 'domain controller discovery') | Should -BeNullOrEmpty
    }
    It 'neither SRV nor the explicit controllers work: Blocked, and the note carries the real reason from the node and what each controller did' {
        $state = Get-DjState @{
            srvOk = $false; srvTargets = @(); srvReason = '192.168.211.30 UDP 4012 ms: This operation returned because the timeout period expired'; srvServers = @('192.168.211.30'); dcAllOk = $false; dcServer = ''
            dcChecks = @([pscustomobject]@{ address = '192.168.211.30'; tcp389 = $false; name = ''; resolves = $false; ok = $false; error = 'TCP 389 does not answer' })
        }
        $items = Get-DjItem (Get-DjSpec) $state @('DomainJoin')
        $join = $items | Where-Object Item -eq 'domain membership'
        $join.Action | Should -Be 'Blocked'
        $join.Note | Should -Match 'timeout period expired'
        $join.Note | Should -Match '192\.168\.211\.30: TCP 389 closed'
        $join.Note | Should -Match 'TCP 389 does not answer'
        @($items | Where-Object Item -eq 'domain controller discovery') | Should -BeNullOrEmpty
    }
    It 'one controller of the file works and another does not: still Blocked (every address must work for the fall-back)' {
        $state = Get-DjState @{
            srvOk = $false; srvTargets = @(); srvReason = 'x'; dcAllOk = $false; dcServer = 'mgmt-ral-dc-01.haas.mgmt'
            dcChecks = @([pscustomobject]@{ address = '192.168.211.30'; tcp389 = $true; name = 'mgmt-ral-dc-01.haas.mgmt'; resolves = $true; ok = $true; error = '' }, [pscustomobject]@{ address = '192.168.211.31'; tcp389 = $true; name = ''; resolves = $false; ok = $false; error = 'no PTR record' })
        }
        (Get-DjItem (Get-DjSpec) $state @('DomainJoin') | Where-Object Item -eq 'domain membership').Action | Should -Be 'Blocked'
    }
    It 'the fall-back never relaxes the other protections: no credential, the OU, and another domain still block' {
        $fallback = @{
            srvOk = $false; srvTargets = @(); srvReason = 'x'; dcAllOk = $true; dcServer = 'mgmt-ral-dc-01.haas.mgmt'
            dcChecks = @([pscustomobject]@{ address = '192.168.211.30'; tcp389 = $true; name = 'mgmt-ral-dc-01.haas.mgmt'; resolves = $true; ok = $true; error = '' })
        }
        $noAccount = Get-DjSpec { param($d) $d.identity.active_directory.lcm_user.password = '' }
        (Get-DjItem $noAccount (Get-DjState $fallback) @('DomainJoin') | Where-Object Item -eq 'domain membership').Action | Should -Be 'Blocked'
        $badOu = Add-DjOu (Get-DjState $fallback) @{ checked = $false; exists = $false; error = 'There is no such object on the server.' }
        $ouItems = Get-DjItem (Get-DjSpec) $badOu @('DomainJoin')
        ($ouItems | Where-Object Item -eq 'domain membership').Action | Should -Be 'Blocked'
        ($ouItems | Where-Object Item -eq 'domain membership').Note | Should -Match 'Not done'
        $other = Get-DjState ($fallback + @{ partOfDomain = $true; domain = 'other.example' })
        (Get-DjItem (Get-DjSpec) $other @('DomainJoin') | Where-Object Item -eq 'domain membership').Action | Should -Be 'Blocked'
    }
    It 'the report summary carries the SRV result and the controller the join names' {
        $state = Get-DjState @{ srvOk = $false; srvReason = 'why'; srvTransport = ''; dcAllOk = $true; dcServer = 'mgmt-ral-dc-01.haas.mgmt' }
        $s = Get-AzlDomainJoinSummary -Spec (Get-DjSpec) -State $state
        $s.srvDiscovery.ok | Should -BeFalse
        $s.srvDiscovery.reason | Should -Be 'why'
        $s.srvDiscovery.joinServer | Should -Be 'mgmt-ral-dc-01.haas.mgmt'
        $ok = Get-AzlDomainJoinSummary -Spec (Get-DjSpec) -State (Get-DjState @{ srvServer = '192.168.211.30'; srvTransport = 'tcp'; srvElapsedMs = 12 })
        $ok.srvDiscovery.transport | Should -Be 'tcp'
    }
    It 'no domain controller reachable: Blocked' {
        $i = Get-DjItem (Get-DjSpec) (Get-DjState @{ dcReachable = $false; dcUsed = '' }) @('DomainJoin') | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Blocked'
        $i.Note | Should -Match 'TCP 389'
    }
    It 'clock skew over 5 minutes: Blocked; 299 seconds and an unmeasured skew are not' {
        (Get-DjItem (Get-DjSpec) (Get-DjState @{ skewSeconds = 301.5 }) @('DomainJoin') | Where-Object Item -eq 'domain membership').Action | Should -Be 'Blocked'
        (Get-DjItem (Get-DjSpec) (Get-DjState @{ skewSeconds = 301.5 }) @('DomainJoin') | Where-Object Item -eq 'domain membership').Note | Should -Match 'Kerberos allows 300'
        (Get-DjItem (Get-DjSpec) (Get-DjState @{ skewSeconds = 299 }) @('DomainJoin') | Where-Object Item -eq 'domain membership').Action | Should -Be 'Change'
        $unknown = Get-DjItem (Get-DjSpec) (Get-DjState @{ skewSeconds = $null }) @('DomainJoin') | Where-Object Item -eq 'domain membership'
        $unknown.Action | Should -Be 'Change'
        $unknown.Note | Should -Match 'not measured'
    }
    It 'reports every blocking reason together' {
        $i = Get-DjItem (Get-DjSpec) (Get-DjState @{ dnsOk = $false; dcReachable = $false; skewSeconds = 900 }) @('DomainJoin') | Where-Object Item -eq 'domain membership'
        $i.Note | Should -Match 'cannot resolve'
        $i.Note | Should -Match 'TCP 389'
        $i.Note | Should -Match '900'
    }
    It 'joined but the restart is still due (the durable marker, same boot): Change (restart)' {
        $state = Get-JoinedState @{ marker = [pscustomobject]@{ state = 'RebootExpected'; changeId = 'x'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
        $i = Get-DjItem (Get-DjSpec) $state | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Change'
        $i.Apply.kind | Should -Be 'domain-restart'
    }
    It 'a marker from before the last boot does not ask for another restart' {
        $state = Get-JoinedState @{ marker = [pscustomobject]@{ state = 'RebootExpected'; changeId = 'x'; bootBefore = '2026-11-06T08:00:00Z'; domain = 'improbability.cloud'; error = '' } }
        (Get-DjItem (Get-DjSpec) $state | Where-Object Item -eq 'domain membership').Action | Should -Be 'Ok'
    }
    It 'the restart item carries the changeId of the marker, so the node accepts the restart of that change' {
        $state = Get-JoinedState @{ marker = [pscustomobject]@{ state = 'RebootExpected'; changeId = 'abc123'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
        (Get-DjItem (Get-DjSpec) $state | Where-Object Item -eq 'domain membership').Apply.changeId | Should -Be 'abc123'
    }
    It 'a marker at <State> with the same boot is a restart still due' -ForEach @(@{ State = 'Restarting' }, @{ State = 'Joining' }) {
        $state = Get-JoinedState @{ marker = [pscustomobject]@{ state = $State; changeId = 'x'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
        $i = Get-DjItem (Get-DjSpec) $state | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Change'
        $i.Apply.kind | Should -Be 'domain-restart'
    }
    It 'a marker at Joining on a node that is not a member is not a restart (the join failed or never happened)' {
        $state = Get-DjState @{ marker = [pscustomobject]@{ state = 'Joining'; changeId = 'x'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
        (Get-DjItem (Get-DjSpec) $state | Where-Object Item -eq 'domain membership').Apply.kind | Should -Be 'domain-join'
    }
    It 'a boot time that moved a few seconds (the clock was stepped) is still the same boot: the restart is still due' {
        $state = Get-JoinedState @{ boot = '2026-11-07T10:00:07Z'; marker = [pscustomobject]@{ state = 'RebootExpected'; changeId = 'x'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
        (Get-DjItem (Get-DjSpec) $state | Where-Object Item -eq 'domain membership').Apply.kind | Should -Be 'domain-restart'
        $moved = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; marker = [pscustomobject]@{ state = 'RebootExpected'; changeId = 'x'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
        (Get-DjItem (Get-DjSpec) $moved | Where-Object Item -eq 'domain membership').Action | Should -Be 'Ok'
    }
    It 'the secure channel is broken: Blocked' {
        $i = Get-DjItem (Get-DjSpec) (Get-JoinedState @{ secureChannel = $false }) | Where-Object Item -eq 'secure channel'
        $i.Action | Should -Be 'Blocked'
    }
    It 'joined but the OU is unknown to the node yet: Info, not a guess' {
        $i = Get-DjItem (Get-DjSpec) (Get-JoinedState @{ dn = '' }) | Where-Object Item -eq 'domain membership'
        $i.Action | Should -Be 'Info'
    }
    It 'the node reported nothing: Info (unreadable)' {
        $i = Get-DjItem (Get-DjSpec) ([pscustomobject]@{ host = 'iic-n01'; err = [pscustomobject]@{ domainJoin = 'boom' } })
        $i.Action | Should -Be 'Info'
        $i.Note | Should -Be 'boom'
    }
    It 'a local identity design gets an explicit item: not applicable' {
        $spec = Get-DjSpec { param($d) $d.scenario.identity = 'local_identity' }
        $i = Get-DjItem $spec (Get-DjState)
        $i.Count | Should -Be 1
        $i.Action | Should -Be 'Skipped'
        $i.Note | Should -Match 'not applicable: local identity'
    }

    Context 'the dedicated OU (Group Policy inheritance blocked)' {
        It 'blocked inheritance: Ok, and the join is a Change' {
            $items = Get-DjItem (Get-DjSpec) (Add-DjOu (Get-DjState)) @('DomainJoin')
            ($items | Where-Object Item -eq 'OU Group Policy inheritance').Action | Should -Be 'Ok'
            ($items | Where-Object Item -eq 'domain membership').Action | Should -Be 'Change'
        }
        It 'not blocked in <Class>: Blocked, and the join is Blocked with it' -ForEach @(@{ Class = 'production' }, @{ Class = 'dev' }, @{ Class = 'dmz' }) {
            $class = $Class
            $spec = Get-DjSpec { param($d) $d.scenario.environment_class = $class }
            $items = Get-DjItem $spec (Add-DjOu (Get-DjState) @{ gpOptions = 0; blockInheritance = $false }) @('DomainJoin')
            $ou = $items | Where-Object Item -eq 'OU Group Policy inheritance'
            $ou.Action | Should -Be 'Blocked'
            $ou.Note | Should -Match 'Set-GPInheritance|New-HciAdObjectsPreCreation'
            $join = $items | Where-Object Item -eq 'domain membership'
            $join.Action | Should -Be 'Blocked'
            $join.Apply | Should -BeNullOrEmpty
        }
        It 'not blocked with no environment class (missing means production): Blocked' {
            $items = Get-DjItem (Get-DjSpec) (Add-DjOu (Get-DjState) @{ gpOptions = 0; blockInheritance = $false }) @('DomainJoin')
            ($items | Where-Object Item -eq 'OU Group Policy inheritance').Action | Should -Be 'Blocked'
        }
        It 'not blocked in <Class>: a warning (Info), the join still goes ahead' -ForEach @(@{ Class = 'lab' }, @{ Class = 'test' }) {
            $class = $Class
            $spec = Get-DjSpec { param($d) $d.scenario.environment_class = $class }
            $items = Get-DjItem $spec (Add-DjOu (Get-DjState) @{ gpOptions = 0; blockInheritance = $false }) @('DomainJoin')
            $ou = $items | Where-Object Item -eq 'OU Group Policy inheritance'
            $ou.Action | Should -Be 'Info'
            $ou.Note | Should -Match '^WARNING'
            ($items | Where-Object Item -eq 'domain membership').Action | Should -Be 'Change'
        }
        It 'enforced GPO links above the OU: a warning that names them and suggests a WMI filter; nothing is blocked' {
            $links = @('cn={31B2F340-016D-11D2-945F-00C04FB984F9},cn=policies,cn=system,DC=improbability,DC=cloud (linked at OU=AzureLocal,DC=improbability,DC=cloud)')
            $items = Get-DjItem (Get-DjSpec) (Add-DjOu (Get-DjState) @{ enforcedLinks = $links }) @('DomainJoin')
            $w = $items | Where-Object Item -eq 'enforced GPO links above the OU'
            $w.Action | Should -Be 'Info'
            $w.Note | Should -Match 'WARNING'
            $w.Note | Should -Match 'WMI filter'
            $w.Note | Should -Match '31B2F340'
            ($items | Where-Object Item -eq 'domain membership').Action | Should -Be 'Change'
        }
        It 'no enforced link: no warning item' {
            @(Get-DjItem (Get-DjSpec) (Add-DjOu (Get-DjState)) @('DomainJoin') | Where-Object Item -eq 'enforced GPO links above the OU') | Should -BeNullOrEmpty
        }
        It 'the OU does not exist: Blocked' {
            $items = Get-DjItem (Get-DjSpec) (Add-DjOu (Get-DjState) @{ checked = $false; exists = $false; error = 'There is no such object on the server.' }) @('DomainJoin')
            ($items | Where-Object Item -eq 'organizational unit').Action | Should -Be 'Blocked'
            ($items | Where-Object Item -eq 'domain membership').Action | Should -Be 'Blocked'
        }
        It 'the OU could not be read yet: Info, the join is not blocked by it' {
            $items = Get-DjItem (Get-DjSpec) (Add-DjOu (Get-DjState) @{ checked = $false; error = 'no domain controller is reachable from the node yet' }) @('DomainJoin')
            ($items | Where-Object Item -eq 'organizational unit').Action | Should -Be 'Info'
        }
        It 'the OU check was rejected by the domain controller (authFailed): Blocked, and the join is Blocked with it' {
            $items = Get-DjItem (Get-DjSpec) (Add-DjOu (Get-DjState) @{ checked = $false; authFailed = $true; error = 'Logon failure: unknown user name or bad password.' }) @('DomainJoin')
            $ou = $items | Where-Object Item -eq 'organizational unit'
            $ou.Action | Should -Be 'Blocked'
            $ou.Note | Should -Match 'Logon failure'
            $ou.Note | Should -Match 'not (sent|used|tried) again'
            ($items | Where-Object Item -eq 'domain membership').Action | Should -Be 'Blocked'
        }
        It 'a bad password is not mistaken for a missing OU, whatever the error text says' {
            $items = Get-DjItem (Get-DjSpec) (Add-DjOu (Get-DjState) @{ checked = $false; exists = $false; authFailed = $true; error = 'no such object' }) @('DomainJoin')
            ($items | Where-Object Item -eq 'organizational unit').Note | Should -Not -Match 'does not exist'
        }
        It 'a blocked OU blocks the move too' {
            $spec = Get-DjSpec { param($d) $d.identity.active_directory.join_options = [ordered]@{ allow_ou_move = $true } }
            $state = Add-DjOu (Get-JoinedState @{ dn = 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud' }) @{ gpOptions = 0; blockInheritance = $false }
            (Get-DjItem $spec $state | Where-Object Item -eq 'domain membership').Action | Should -Be 'Blocked'
        }
    }

    Context 'the local administrators after the join' {
        It 'a missing principal: Change, the missing ones only' {
            $spec = Get-DjSpec { param($d) $d.identity.active_directory.netbios_name = 'IIC'; $d.identity.active_directory.local_admin_members = @('sg-a', 'lcm-iic-clus01') }
            $state = Get-JoinedState @{ localAdmins = @('azl-admin', 'IIC\lcm-iic-clus01') }
            $i = Get-DjItem $spec $state | Where-Object Item -eq 'local administrators'
            $i.Action | Should -Be 'Change'
            $i.Apply.kind | Should -Be 'domain-admins'
            $i.Apply.members | Should -Be @('IIC\sg-a')
        }
        It 'all present (the qualified names): Ok, nothing to do (idempotent)' {
            $spec = Get-DjSpec { param($d) $d.identity.active_directory.netbios_name = 'IIC'; $d.identity.active_directory.local_admin_members = @('sg-a', 'lcm-iic-clus01') }
            $state = Get-JoinedState @{ localAdmins = @('azl-admin', 'iic\SG-A', 'IIC\lcm-iic-clus01') }
            (Get-DjItem $spec $state | Where-Object Item -eq 'local administrators').Action | Should -Be 'Ok'
        }
        It 'a LOCAL account with the same short name is not the domain principal: still missing' {
            $spec = Get-DjSpec { param($d) $d.identity.active_directory.netbios_name = 'IIC'; $d.identity.active_directory.local_admin_members = @('sg-a') }
            $i = Get-DjItem $spec (Get-JoinedState @{ localAdmins = @('azl-admin', 'sg-a') }) | Where-Object Item -eq 'local administrators'
            $i.Action | Should -Be 'Change'
            $i.Apply.members | Should -Be @('IIC\sg-a')
        }
        It 'the summary counts the same way: a bare local name is not present, the qualified one is' {
            $spec = Get-DjSpec { param($d) $d.identity.active_directory.netbios_name = 'IIC'; $d.identity.active_directory.local_admin_members = @('sg-a') }
            (Get-AzlDomainJoinSummary -Spec $spec -State (Get-JoinedState @{ localAdmins = @('azl-admin', 'sg-a') })).localAdminsPresent | Should -BeFalse
            (Get-AzlDomainJoinSummary -Spec $spec -State (Get-JoinedState @{ localAdmins = @('azl-admin', 'IIC\sg-a') })).localAdminsPresent | Should -BeTrue
        }
        It 'not joined yet: no administrators item' {
            @(Get-DjItem (Get-DjSpec) (Get-DjState) | Where-Object Item -eq 'local administrators') | Should -BeNullOrEmpty
        }
        It 'while the restart is still due: no administrators item (it comes after the restart)' {
            $state = Get-JoinedState @{ marker = [pscustomobject]@{ state = 'RebootExpected'; changeId = 'x'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
            @(Get-DjItem (Get-DjSpec) $state | Where-Object Item -eq 'local administrators') | Should -BeNullOrEmpty
        }
    }

    Context 'inside Compare-AzlNodeState' {
        It 'the DomainJoin items come after Hostname and UnusedAdapters and before LocalAdmin' {
            $spec = Get-DjSpec
            $state = Get-JoinedState
            $state | Add-Member -NotePropertyName host -NotePropertyValue 'iic-n01' -Force
            $plan = @(Compare-AzlNodeState -Spec $spec -State $state -Step @('Hostname', 'UnusedAdapters', 'DomainJoin', 'LocalAdmin'))
            $steps = @($plan | ForEach-Object Step)
            $steps.IndexOf('DomainJoin') | Should -BeGreaterThan $steps.IndexOf('Hostname')
            $steps.LastIndexOf('DomainJoin') | Should -BeLessThan $steps.IndexOf('LocalAdmin')
        }
        It 'a hostname Change in the same comparison makes the join wait' {
            $spec = Get-DjSpec
            $state = Get-DjState @{ host = 'WIN-ABC123' }
            $state.host = 'WIN-ABC123'
            $plan = @(Compare-AzlNodeState -Spec $spec -State $state -Step @('Hostname', 'DomainJoin'))
            ($plan | Where-Object Step -eq 'Hostname').Action | Should -Be 'Change'
            ($plan | Where-Object { $_.Step -eq 'DomainJoin' -and $_.Item -eq 'domain membership' }).Action | Should -Be 'Skipped'
        }
        It 'a local identity design: one explicit not-applicable item in the plan' {
            $spec = Get-DjSpec { param($d) $d.scenario.identity = 'local_identity' }
            $plan = @(Compare-AzlNodeState -Spec $spec -State (Get-DjState) -Step @('DomainJoin'))
            $plan.Count | Should -Be 1
            $plan[0].Note | Should -Match 'not applicable: local identity'
        }
    }
}

Describe 'Step order in both methods' {
    BeforeAll {
        $script:Order = @('RemoteManagement', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'DomainJoin', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe')
    }
    It 'the toolkit step list puts DomainJoin after Network, Dns, Time and Hostname and before LocalAdmin, Mpio, SanVerify, ClearStorage and Sbe' {
        $all = InModuleScope AzlNodeConfiguration { $script:AllSteps }
        $all | Should -Be $script:Order
        foreach ($before in 'Network', 'Dns', 'Time', 'Hostname') { $all.IndexOf('DomainJoin') | Should -BeGreaterThan $all.IndexOf($before) }
        foreach ($after in 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe') { $all.IndexOf('DomainJoin') | Should -BeLessThan $all.IndexOf($after) }
    }
    It 'the Ztp method runs DomainJoin after Network, Dns and Time, before LocalAdmin and the rest (ZTP already named the machine)' {
        $steps = Get-AzlNodeStepList -Method Ztp
        $steps | Should -Contain 'DomainJoin'
        $steps | Should -Not -Contain 'Hostname'
        foreach ($before in 'Network', 'Dns', 'Time') { $steps.IndexOf('DomainJoin') | Should -BeGreaterThan $steps.IndexOf($before) }
        foreach ($after in 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe') { $steps.IndexOf('DomainJoin') | Should -BeLessThan $steps.IndexOf($after) }
    }
    It 'the Iso method runs DomainJoin after Hostname, before LocalAdmin and the rest, and before the Arc registration' {
        $steps = Get-AzlNodeStepList -Method Iso
        foreach ($before in 'Network', 'Dns', 'Time', 'Hostname') { $steps.IndexOf('DomainJoin') | Should -BeGreaterThan $steps.IndexOf($before) }
        foreach ($after in 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe', 'ArcRegistration') { $steps.IndexOf('DomainJoin') | Should -BeLessThan $steps.IndexOf($after) }
    }
    It '-Step limits the list and keeps the order' {
        Get-AzlNodeStepList -Method Iso -Step 'LocalAdmin', 'DomainJoin', 'Hostname' | Should -Be @('Hostname', 'DomainJoin', 'LocalAdmin')
    }
    It 'the node script and the entry script accept DomainJoin as a step' {
        $set = Join-Path ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration')) 'Set-AzureLocalNodeConfiguration.ps1'
        $entry = Join-Path ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration')) 'Invoke-AzureLocalOsConfiguration.ps1'
        (Get-Command $set).Parameters['Step'].Attributes.ValidValues | Should -Contain 'DomainJoin'
        (Get-Command $entry).Parameters['Step'].Attributes.ValidValues | Should -Contain 'DomainJoin'
        (Get-Command $set).Parameters.ContainsKey('EventLogPath') | Should -BeTrue
        (Get-Command $set).Parameters.ContainsKey('EventMethod') | Should -BeTrue
        (Get-Command $set).Parameters.ContainsKey('EventPhase') | Should -BeTrue
    }
}

Describe 'Verification after the restart' {
    It 'passes: member, right domain, secure channel, right OU' {
        $checks = Test-AzlDomainJoinVerification -Spec (Get-DjSpec) -State (Get-JoinedState)
        @($checks | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        @($checks).Count | Should -Be 4
    }
    It 'an empty distinguished name is unverified, never OK (the computer account may have been reused in another OU)' {
        $bad = @(Test-AzlDomainJoinVerification -Spec (Get-DjSpec) -State (Get-JoinedState @{ dn = '' }) | Where-Object { -not $_.Ok })
        $bad.Check | Should -Contain 'OU'
        ($bad | Where-Object Check -eq 'OU').Detail | Should -Match 'unverified'
    }
    It 'fails on <Name>' -ForEach @(
        @{ Name = 'not a member'; Set = @{ partOfDomain = $false; domain = 'WORKGROUP' }; Check = 'PartOfDomain' }
        @{ Name = 'another domain'; Set = @{ domain = 'contoso.com' }; Check = 'Domain' }
        @{ Name = 'a broken secure channel'; Set = @{ secureChannel = $false }; Check = 'SecureChannel' }
        @{ Name = 'the wrong OU'; Set = @{ dn = 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud' }; Check = 'OU' }
    ) {
        $bad = @(Test-AzlDomainJoinVerification -Spec (Get-DjSpec) -State (Get-JoinedState $Set) | Where-Object { -not $_.Ok })
        $bad.Check | Should -Contain $Check
    }
}

Describe 'The step: join, restart, reconnect, verify' {
    BeforeEach {
        $script:Feed = Join-Path $TestDrive "feed-$([guid]::NewGuid().ToString('N').Substring(0, 6)).jsonl"
        $script:Ctx = @{ Path = $script:Feed; Method = 'Iso'; SchemaVersion = '5.5.0' }
        $script:Spec = Get-DjSpec
        $script:JoinItem = Get-DjItem $script:Spec (Get-DjState) @('DomainJoin') | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-join' }
        $script:Joined = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z' }
        $script:Wait = { param($PreviousBoot) $script:Joined }
    }

    It 'joins with the LCM user, restarts, reconnects, verifies, completes the marker, and says so in the feed' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'joined improbability.cloud; restart expected' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart $script:Wait -EventContext $script:Ctx
        $r.Failed | Should -BeFalse
        $r.Joined | Should -BeTrue
        $r.Restarted | Should -BeTrue
        @($t.Log | ForEach-Object Kind) | Should -Be @('Apply:join', 'Restart', 'Apply:finalize')
        $join = $t.Log[0]
        $join.Secrets.joinUser | Should -Be 'lcm-iic-clus01'
        $join.Secrets.joinPassword | Should -Be $script:Password
        $join.Parameters.domain | Should -Be 'improbability.cloud'
        $join.Parameters.ou | Should -Be 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $join.Parameters.expectedHost | Should -Be 'iic-n01'
        $join.Parameters.resumeScript | Should -Match 'AzureLocal-OSConfig-DomainJoinResume'
        $t.Log[1].Parameters.changeId | Should -Be $join.Parameters.changeId
        @(Get-DjFeed $script:Feed | ForEach-Object state) | Should -Be @('DomainJoinApplying', 'NodeRestarting', 'NodeReconnected', 'DomainJoined')
    }
    It 'a join planned with -Server hands the domain controller to the node, and a join without it passes an empty server' {
        $state = Get-DjState @{ srvOk = $false; srvReason = 'x'; dcAllOk = $true; dcServer = 'mgmt-ral-dc-01.haas.mgmt' }
        $item = Get-DjItem $script:Spec $state @('DomainJoin') | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-join' }
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        $null = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State $state -Item $item -SecretResolver $script:Resolver -WaitForRestart $script:Wait
        $t.Log[0].Parameters.server | Should -Be 'mgmt-ral-dc-01.haas.mgmt'
        $t2 = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        $null = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t2 -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart $script:Wait
        $t2.Log[0].Parameters.server | Should -BeNullOrEmpty
    }
    It 'with the override account, the node gets the override user' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.domain_join_account = [ordered]@{ username = 'svc-azl-join'; password = 'keyvault://kv-iic-mgmt-01/join-password' } }
        $item = Get-DjItem $spec (Get-DjState) @('DomainJoin') | Where-Object { $_.Apply }
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        $resolved = [System.Collections.Generic.List[string]]::new()
        $resolver = { param($Ref) $resolved.Add($Ref); 'pw' }.GetNewClosure()
        $null = Invoke-AzlDomainJoinStep -Spec $spec -Transport $t -State (Get-DjState) -Item $item -SecretResolver $resolver -WaitForRestart $script:Wait
        $t.Log[0].Secrets.joinUser | Should -Be 'svc-azl-join'
        $resolved | Should -Be @('keyvault://kv-iic-mgmt-01/join-password')
    }
    It 'the events follow the contract: stage, step, level, UTC timestamps, method, transport, schema version' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        $null = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart $script:Wait -EventContext $script:Ctx
        $events = Get-DjFeed $script:Feed
        foreach ($e in $events) {
            $e.node | Should -Be 'iic-n01'
            $e.stage | Should -Be 'OsConfiguration'
            $e.step | Should -Be 'DomainJoin'
            $e.level | Should -Be 'Info'
            $e.method | Should -Be 'Iso'
            $e.transport | Should -Be 'WinRM'
            $e.schemaVersion | Should -Be '5.5.0'
            $e.payloadVersion | Should -Be '1'
        }
        (Get-Content -LiteralPath $script:Feed -Raw) | Should -Match '"timestamp":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z"'
        (Get-Content -LiteralPath $script:Feed -Raw) | Should -Match '"timestamp":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z"'
        (Get-Content -LiteralPath $script:Feed -Raw) | Should -Match '"timestamp":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z"'
        ($events | Where-Object state -eq 'DomainJoined').domain | Should -Be 'improbability.cloud'
        ($events | Where-Object state -eq 'DomainJoined').dn | Should -Match '^CN=iic-n01'
    }
    It 'writes no event without a feed path' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        { Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart $script:Wait } | Should -Not -Throw
        Test-Path $script:Feed | Should -BeFalse
    }
    It 'maps the AD error the node returns: <Name>' -ForEach @(
        @{ Name = '1326 bad credential'; Code = '1326'; Label = 'bad credential'; Text = 'The user name or password is incorrect.' }
        @{ Name = '1355 domain not found'; Code = '1355'; Label = 'domain not found'; Text = 'The specified domain either does not exist or could not be contacted.' }
        @{ Name = '2224 account exists'; Code = '2224'; Label = 'account exists'; Text = 'The account already exists.' }
        @{ Name = '5 access denied'; Code = '5'; Label = 'access denied'; Text = 'Access is denied.' }
        @{ Name = '53 network path'; Code = '53'; Label = 'network path not found'; Text = 'The network path was not found.' }
        @{ Name = '1722 RPC'; Code = '1722'; Label = 'RPC server unavailable'; Text = 'The RPC server is unavailable.' }
        @{ Name = 'clock skew'; Code = '37'; Label = 'clock skew'; Text = 'The time difference between the client and server is too great.' }
    ) {
        $answer = @{ status = 'failed'; code = $Code; label = $Label; errorText = "Computer 'iic-n01' failed to join domain 'improbability.cloud' with the following error message: $Text"; nextAction = 'Do the thing.'; stillWorkgroup = $true }
        $t = Get-DjTransport @{ 'Apply:join' = $answer }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart $script:Wait -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match ([regex]::Escape($Text))
        $r.Error | Should -Match "error $Code"
        $r.NextAction | Should -Be 'Do the thing.'
        $r.Changes[0].Status | Should -Be 'failed'
        $r.Changes[0].Detail | Should -Match 'stays in its workgroup'
        @($t.Log | ForEach-Object Kind) | Should -Be @('Apply:join')
        $failed = Get-DjFeed $script:Feed | Where-Object state -eq 'DomainJoinFailed'
        $failed.level | Should -Be 'Error'
        $failed.evidence | Should -Match ([regex]::Escape($Text))
        $failed.nextAction | Should -Be 'Do the thing.'
        $failed.code | Should -Be $Code
    }
    It 'a join that the node says is not needed (already a member) goes straight to nothing to restart' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'unchanged'; reboot = $false; detail = 'already a member' } }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart $script:Wait
        $r.Failed | Should -BeFalse
        @($t.Log).Count | Should -Be 1
    }
    It 'cannot read the secret: Failed before anything is sent to the node, and the message has no secret' {
        $t = Get-DjTransport @{}
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver { throw 'Forbidden: no get permission' } -WaitForRestart $script:Wait -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match "Can't read the join account's password"
        @($t.Log).Count | Should -Be 0
        (Get-DjFeed $script:Feed).state | Should -Contain 'DomainJoinFailed'
    }
    It '-NoRestart: joined, no restart, the result says the restart is pending' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' } }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -NoRestart -WaitForRestart $script:Wait
        $r.Restarted | Should -BeFalse
        @($t.Log | ForEach-Object Kind) | Should -Be @('Apply:join')
        $r.Changes[-1].Status | Should -Be 'pending'
        $r.Changes[-1].Detail | Should -Match 'restart'
    }
    It 'a tripped latch (an earlier node had the credential rejected): Failed before the password is read or anything is sent' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'must not run' } }
        $latch = @{ Tripped = $true; Reason = 'iic-n01: Logon failure' }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver { throw 'must not read the secret' } -Latch $latch -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match 'iic-n01'
        @($t.Log).Count | Should -Be 0
    }
    It 'a join the domain rejects with <Code> trips the latch; another error does not' -ForEach @(
        @{ Code = '1326'; Trips = $true }, @{ Code = '1331'; Trips = $true }, @{ Code = '1909'; Trips = $true }, @{ Code = '1355'; Trips = $false }, @{ Code = '5'; Trips = $false }
    ) {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'failed'; code = $Code; label = 'x'; errorText = 'rejected'; nextAction = 'fix it'; stillWorkgroup = $true } }
        $latch = @{ Tripped = $false; Reason = '' }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -Latch $latch -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $latch.Tripped | Should -Be $Trips
    }
    It 'the node refuses to restart without its marker: Failed, nothing waits' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $false; reason = 'No durable restart marker' } }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { throw 'must not wait' }
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match 'No durable restart marker'
    }
    It 'the node does not come back: Failed with a next action' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true } }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { throw 'timed out after 30 minutes' } -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match 'did not come back'
        (Get-DjFeed $script:Feed).state | Should -Contain 'NodeRestarting'
    }
    It 'verification fails after the restart (broken secure channel): DomainJoinFailed, the marker is not completed' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        $bad = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; secureChannel = $false }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { $bad }.GetNewClosure() -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match 'SecureChannel'
        @($t.Log | ForEach-Object Kind) | Should -Not -Contain 'Apply:finalize'
        (Get-DjFeed $script:Feed).state | Should -Not -Contain 'DomainJoined'
    }
    It 'no distinguished name after the restart yet: the node refreshes Group Policy and reads it again, then the join completes' {
        $dnRight = 'CN=iic-n01,OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true }; 'Apply:locate' = @{ status = 'located'; dn = $dnRight }; 'Apply:finalize' = @{ status = 'finalized' } }
        $noDn = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; dn = '' }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { $noDn }.GetNewClosure() -EventContext $script:Ctx
        $r.Failed | Should -BeFalse
        @($t.Log | ForEach-Object Kind) | Should -Be @('Apply:join', 'Restart', 'Apply:locate', 'Apply:finalize')
        $r.Joined | Should -BeTrue
    }
    It 'the DN stays unknown after the refresh: the OU is unverified, so the step fails and the marker is not completed' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true }; 'Apply:locate' = @{ status = 'unverified'; dn = '' }; 'Apply:finalize' = @{ status = 'finalized' } }
        $noDn = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; dn = '' }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { $noDn }.GetNewClosure() -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match 'OU.*unverified'
        @($t.Log | ForEach-Object Kind) | Should -Not -Contain 'Apply:finalize'
        (Get-DjFeed $script:Feed).state | Should -Not -Contain 'DomainJoined'
    }
    It 'the account turns out to be in another OU (reused): the step fails with the OU it is in' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'x' }; Restart = @{ restartScheduled = $true }; 'Apply:locate' = @{ status = 'located'; dn = 'CN=iic-n01,OU=Old,DC=improbability,DC=cloud' }; 'Apply:finalize' = @{ status = 'finalized' } }
        $noDn = Get-JoinedState @{ boot = '2026-11-07T10:09:00Z'; dn = '' }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { $noDn }.GetNewClosure() -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match 'OU=Old'
        @($t.Log | ForEach-Object Kind) | Should -Not -Contain 'Apply:finalize'
    }
    It 'a pending restart (restart item): restarts and verifies without joining again' {
        $state = Get-JoinedState @{ marker = [pscustomobject]@{ state = 'RebootExpected'; changeId = 'x'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
        $item = Get-DjItem $script:Spec $state | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-restart' }
        $t = Get-DjTransport @{ Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State $state -Item $item -SecretResolver { throw 'no secret needed' } -WaitForRestart $script:Wait
        $r.Failed | Should -BeFalse
        @($t.Log | ForEach-Object Kind) | Should -Be @('Restart', 'Apply:finalize')
    }
    It 'a pending restart is asked with the changeId of the marker (not a fresh one), and the marker is completed with it' {
        $state = Get-JoinedState @{ marker = [pscustomobject]@{ state = 'Restarting'; changeId = 'abc123'; bootBefore = '2026-11-07T10:00:00Z'; domain = 'improbability.cloud'; error = '' } }
        $item = Get-DjItem $script:Spec $state | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-restart' }
        $t = Get-DjTransport @{ Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State $state -Item $item -SecretResolver { throw 'no secret needed' } -WaitForRestart $script:Wait
        $r.Failed | Should -BeFalse
        $t.Log[0].Parameters.changeId | Should -Be 'abc123'
        $t.Log[1].Parameters.changeId | Should -Be 'abc123'
    }
    It 'a restart script that fails (not state Unknown) is a failed step with the changes kept, not an exception that ends the run' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'joined' }; Restart = { 'the restart script crashed' } }
        $r = Invoke-AzlDomainJoinStep -Spec $script:Spec -Transport $t -State (Get-DjState) -Item $script:JoinItem -SecretResolver $script:Resolver -WaitForRestart { throw 'must not wait' } -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match 'restart'
        @($r.Changes | Where-Object Status -eq 'changed').Count | Should -Be 1 -Because 'the join itself is kept in the report'
    }
    It 'the OU move (before the deployment, allow_ou_move) sends the DN and the target, and says DomainJoined with moved' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.join_options = [ordered]@{ allow_ou_move = $true } }
        $state = Get-JoinedState @{ dn = 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud' }
        $item = Get-DjItem $spec $state | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-move' }
        $t = Get-DjTransport @{ 'Apply:move' = @{ status = 'moved'; detail = 'moved' } }
        $r = Invoke-AzlDomainJoinStep -Spec $spec -Transport $t -State $state -Item $item -SecretResolver $script:Resolver -EventContext $script:Ctx
        $r.Moved | Should -BeTrue
        $t.Log[0].Parameters.dn | Should -Be 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud'
        $t.Log[0].Parameters.ou | Should -Be 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        @(Get-DjFeed $script:Feed | Where-Object state -eq 'DomainJoined').moved | Should -BeTrue
    }
    It 'adds the local administrators without a credential and says DomainAdminsConfigured' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.local_admin_members = @('sg-a') }
        $item = Get-DjItem $spec (Get-JoinedState) | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-admins' }
        $t = Get-DjTransport @{ 'Apply:admins' = @{ status = 'configured'; detail = 'added to Administrators: IMPROBABILITY\sg-a'; added = @('IMPROBABILITY\sg-a') } }
        $r = Invoke-AzlDomainJoinStep -Spec $spec -Transport $t -State (Get-JoinedState) -Item $item -SecretResolver { throw 'no secret needed' } -EventContext $script:Ctx
        $r.Failed | Should -BeFalse
        $t.Log[0].Secrets.Count | Should -Be 0
        $t.Log[0].Parameters.members | Should -Be @('IMPROBABILITY\sg-a')
        $e = Get-DjFeed $script:Feed | Where-Object state -eq 'DomainAdminsConfigured'
        $e | Should -Not -BeNullOrEmpty
        $e.step | Should -Be 'DomainJoin'
    }
    It 'a local administrator that cannot be added: Failed with the exact text' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.local_admin_members = @('sg-a') }
        $item = Get-DjItem $spec (Get-JoinedState) | Where-Object { $_.Apply -and $_.Apply.kind -eq 'domain-admins' }
        $t = Get-DjTransport @{ 'Apply:admins' = @{ status = 'failed'; errorText = 'IMPROBABILITY\sg-a: Principal sg-a was not found.'; nextAction = 'fix local_admin_members' } }
        $r = Invoke-AzlDomainJoinStep -Spec $spec -Transport $t -State (Get-JoinedState) -Item $item -EventContext $script:Ctx
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match 'was not found'
    }
}

Describe 'The password never leaves the secret channel' {
    It 'is not in the events, the changes, the summary, the plan, the Read parameters or the payload text; only the secret table holds it' {
        $feed = Join-Path $TestDrive 'secret-feed.jsonl'
        $ctx = @{ Path = $feed; Method = 'Ztp'; SchemaVersion = '5.5.0' }
        $spec = Get-DjSpec
        $plan = Get-DjItem $spec (Get-DjState) @('DomainJoin')
        $item = $plan | Where-Object { $_.Apply }
        $joinedNow = Get-JoinedState
        $waitJoined = { param($b) $joinedNow }.GetNewClosure()
        $joinedNow = Get-JoinedState
        $waitJoined = { param($b) $joinedNow }.GetNewClosure()
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'joined' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }
        $r = Invoke-AzlDomainJoinStep -Spec $spec -Transport $t -State (Get-DjState) -Item $item -SecretResolver $script:Resolver -WaitForRestart $waitJoined -EventContext $ctx
        $t.Log[0].Secrets.joinPassword | Should -Be $script:Password
        # a failed join as well
        $feed2 = Join-Path $TestDrive 'secret-feed2.jsonl'
        $t2 = Get-DjTransport @{ 'Apply:join' = @{ status = 'failed'; code = '1326'; label = 'bad credential'; errorText = 'The user name or password is incorrect.'; nextAction = 'x'; stillWorkgroup = $true } }
        $r2 = Invoke-AzlDomainJoinStep -Spec $spec -Transport $t2 -State (Get-DjState) -Item $item -SecretResolver $script:Resolver -EventContext @{ Path = $feed2; Method = 'Ztp' }
        $artifacts = @{
            events      = (Get-Content -LiteralPath $feed -Raw) + (Get-Content -LiteralPath $feed2 -Raw)
            result      = ($r | ConvertTo-Json -Depth 8) + ($r2 | ConvertTo-Json -Depth 8)
            plan        = ($plan | ConvertTo-Json -Depth 8)
            summary     = (Get-AzlDomainJoinSummary -Spec $spec -State (Get-JoinedState) -Change $r2.Changes | ConvertTo-Json -Depth 6)
            readParams  = (Get-AzlNodeReadParameter -Spec $spec | ConvertTo-Json -Depth 6)
            parameters  = (($t.Log + $t2.Log) | ForEach-Object { $_.Parameters | ConvertTo-Json -Depth 6 }) -join "`n"
        }
        foreach ($name in 'Read', 'DomainJoinProbe', 'DomainJoinApply', 'DomainJoinOuCheck', 'DomainJoinRestart', 'DomainJoinResume') { $artifacts[$name] = Get-AzlNodePayload -Name $name }
        foreach ($k in $artifacts.Keys) { $artifacts[$k] | Should -Not -Match ([regex]::Escape($script:Password)) -Because "the $k must not hold the join password" }
        foreach ($k in 'events', 'result', 'plan', 'summary', 'readParams', 'parameters') { $artifacts[$k] | Should -Not -Match 'joinPassword' }
        # the Key Vault reference is not a secret, but the value it points to is nowhere
        $r.Failed | Should -BeFalse
    }
    It 'the join script gets the password only through the secrets, never through the parameters' {
        $t = Get-DjTransport @{ 'Apply:join' = @{ status = 'joined'; reboot = $false; detail = 'x' } }
        $spec = Get-DjSpec
        $item = Get-DjItem $spec (Get-DjState) @('DomainJoin') | Where-Object { $_.Apply }
        $null = Invoke-AzlDomainJoinStep -Spec $spec -Transport $t -State (Get-DjState) -Item $item -SecretResolver $script:Resolver
        $t.Log[0].Parameters.Keys | Should -Not -Contain 'joinPassword'
        $t.Log[0].Secrets.Keys | Should -Contain 'joinPassword'
        $script:Password | Should -Not -BeIn @($t.Log[0].Parameters.Values | ForEach-Object { [string]$_ })
    }
}

Describe 'Invoke-AzlNodeConfiguration with the DomainJoin step' {
    BeforeEach {
        Mock -ModuleName AzlNodeConfiguration Start-Sleep {}
        $script:Feed = Join-Path $TestDrive "loop-$([guid]::NewGuid().ToString('N').Substring(0, 6)).jsonl"
        $script:Ctx = @{ Path = $script:Feed; Method = 'Iso'; SchemaVersion = '5.5.0'; Phase = 'Apply' }
        $script:Spec = Get-DjSpec
        $script:Before = Add-DjOu (Get-DjState)
        $script:After = Add-DjOu (Get-JoinedState @{ boot = '2026-11-07T10:09:00Z' })
        $script:After.boot = '2026-11-07T10:09:00Z'
    }
    It 'Plan mode: reads once, writes DomainJoinPlanned, changes nothing, never sends the join, and never sends the credential (OU not verified)' {
        $t = Get-DjTransport @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $true; exists = $true; gpOptions = 1; blockInheritance = $true; enforcedLinks = @(); error = '' } } } @($script:Before)
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Step 'DomainJoin' -SecretResolver { throw 'a plan must not read the join secret' } -EventContext @{ Path = $script:Feed; Method = 'Iso'; Phase = 'Plan' }
        # The Read, and the read-only status of the last guarded change that every Plan and Apply ends with (the fake counts it as a Read).
        @($t.Log | ForEach-Object Kind) | Should -Be @('Read', 'Read')
        ($r.Plan | Where-Object Item -eq 'domain membership').Action | Should -Be 'Change'
        $ou = $r.Plan | Where-Object Item -eq 'organizational unit'
        $ou.Action | Should -Be 'Info'
        $ou.Current | Should -Be 'not verified'
        $ou.Note | Should -Match 'OU not verified'
        $r.Executed | Should -BeFalse
        @(Get-DjFeed $script:Feed | ForEach-Object state) | Should -Be @('DomainJoinPlanned')
    }
    It 'Execute: a join credential the domain controller rejects at the OU check is sent once, the join is Blocked and nothing is sent to join' {
        $rejected = @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $false; exists = $true; authFailed = $true; gpOptions = $null; blockInheritance = $false; enforcedLinks = @(); error = 'Logon failure: unknown user name or bad password.' } }; 'Apply:join' = @{ status = 'joined'; reboot = $false; detail = 'must not run' } }
        $t = Get-DjTransport $rejected @($script:Before, $script:Before, $script:Before)
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -EventContext $script:Ctx
        @($t.Log | Where-Object Kind -eq 'OuCheck').Count | Should -Be 1
        @($t.Log | Where-Object Kind -like 'Apply:*') | Should -BeNullOrEmpty
        $r.Converged | Should -BeFalse
        @($r.Blocked | Where-Object Item -eq 'organizational unit').Count | Should -Be 1
        @($r.Blocked | Where-Object Item -eq 'domain membership').Count | Should -Be 1
    }
    It 'a run-wide latch: after the first rejected credential no later node gets an OU check or a join, and a second pass asks again for nothing' {
        $rejected = @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $false; exists = $true; authFailed = $true; gpOptions = $null; blockInheritance = $false; enforcedLinks = @(); error = 'Logon failure: unknown user name or bad password.' } }; 'Apply:join' = @{ status = 'joined'; reboot = $false; detail = 'must not run' } }
        $latch = @{ Tripped = $false; Reason = '' }
        $logs = foreach ($i in 0..1) {
            $spec = Get-DjSpec -Node $i
            $read = Get-DjState @{ host = $spec.Name }
            $t = Get-DjTransport $rejected @($read, $read, $read)
            $null = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -DomainJoinLatch $latch
            , @($t.Log | ForEach-Object Kind)
        }
        $latch.Tripped | Should -BeTrue
        @($logs | ForEach-Object { $_ | Where-Object { $_ -eq 'OuCheck' } }).Count | Should -Be 1 -Because 'two nodes, one bad password, one attempt'
        @($logs | ForEach-Object { $_ | Where-Object { $_ -like 'Apply:*' } }) | Should -BeNullOrEmpty
        for ($i = 1; $i -lt $logs.Count; $i++) { $logs[$i] | Should -Be @('Read', 'Read') -Because 'the Read and the read-only status of the last guarded change; no OU check, no join' }
    }
    It 'a join that fails with a bad credential (1326) trips the latch, so the next node is not sent the same password' {
        $ou = @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $true; exists = $true; gpOptions = 1; blockInheritance = $true; enforcedLinks = @(); error = '' } } }
        $failed = @{ status = 'failed'; code = '1326'; label = 'bad credential'; errorText = 'The user name or password is incorrect.'; nextAction = 'Check the secret.'; stillWorkgroup = $true }
        $latch = @{ Tripped = $false; Reason = '' }
        $spec1 = Get-DjSpec -Node 0; $spec2 = Get-DjSpec -Node 1
        $r1state = Get-DjState @{ host = $spec1.Name }; $r2state = Get-DjState @{ host = $spec2.Name }
        $t1 = Get-DjTransport ($ou + @{ 'Apply:join' = $failed }) @($r1state, $r1state)
        $t2 = Get-DjTransport ($ou + @{ 'Apply:join' = $failed }) @($r2state, $r2state)
        $null = Invoke-AzlNodeConfiguration -Spec $spec1 -Transport $t1 -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -DomainJoinLatch $latch
        $r2 = Invoke-AzlNodeConfiguration -Spec $spec2 -Transport $t2 -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -DomainJoinLatch $latch
        @($t1.Log | Where-Object Kind -eq 'Apply:join').Count | Should -Be 1
        $latch.Tripped | Should -BeTrue
        @($t2.Log | ForEach-Object Kind) | Should -Be @('Read', 'Read')
        $r2.Converged | Should -BeFalse
    }
    It 'without a latch from the caller a run still keeps its own: the credential is not asked again in a later pass' {
        $rejected = @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $false; exists = $true; authFailed = $true; error = 'Logon failure' } } }
        $t = Get-DjTransport $rejected @($script:Before, $script:Before, $script:Before)
        $null = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver
        @($t.Log | Where-Object Kind -eq 'OuCheck').Count | Should -Be 1
    }
    It 'Execute: joins first, restarts, re-reads, converges; the OU is read with the credential before the join' {
        $ou = @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $true; exists = $true; gpOptions = 1; blockInheritance = $true; enforcedLinks = @(); error = '' } } }
        $t = Get-DjTransport ($ou + @{ 'Apply:join' = @{ status = 'joined'; reboot = $true; detail = 'joined' }; Restart = @{ restartScheduled = $true }; 'Apply:finalize' = @{ status = 'finalized' } }) @($script:Before, $script:Before, $script:After, $script:After)
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -EventContext $script:Ctx
        $r.Converged | Should -BeTrue
        $r.Restarted | Should -BeTrue
        $r.DomainJoin.domainJoined | Should -BeTrue
        $r.DomainJoin.domain | Should -Be 'improbability.cloud'
        $r.DomainJoin.ou | Should -Be 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $r.DomainJoin.credential | Should -Be 'lcm_user'
        @($t.Log | ForEach-Object Kind | Where-Object { $_ -ne 'Read' }) | Should -Be @('OuCheck', 'Apply:join', 'Restart', 'Apply:finalize')
        ($r.Changes | Where-Object Id -eq 'DomainJoin/join').Status | Should -Be 'changed'
        $states = @(Get-DjFeed $script:Feed | ForEach-Object state)
        $states | Should -Contain 'DomainJoined'
        $states.IndexOf('DomainJoinApplying') | Should -BeLessThan $states.IndexOf('NodeRestarting')
        $states.IndexOf('NodeRestarting') | Should -BeLessThan $states.IndexOf('NodeReconnected')
        $states.IndexOf('NodeReconnected') | Should -BeLessThan $states.IndexOf('DomainJoined')
    }
    It 'a failed join is tried once, the plan shows it Blocked with the exact error, and the node is not converged' {
        $ou = @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $true; exists = $true; gpOptions = 1; blockInheritance = $true; enforcedLinks = @(); error = '' } } }
        $failed = @{ status = 'failed'; code = '1326'; label = 'bad credential'; errorText = 'The user name or password is incorrect.'; nextAction = 'Check the secret.'; stillWorkgroup = $true }
        $t = Get-DjTransport ($ou + @{ 'Apply:join' = $failed }) @($script:Before, $script:Before, $script:Before)
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -EventContext $script:Ctx
        @($t.Log | Where-Object Kind -eq 'Apply:join').Count | Should -Be 1
        $r.Converged | Should -BeFalse
        $blocked = $r.Blocked | Where-Object Item -eq 'domain membership'
        $blocked.Note | Should -Match 'user name or password is incorrect'
        $blocked.Note | Should -Match 'not tried again'
        $r.DomainJoin.domainJoined | Should -BeFalse
        $r.DomainJoin.error | Should -Match '1326'
        (Get-DjFeed $script:Feed | Where-Object state -eq 'DomainJoinFailed').code | Should -Be '1326'
    }
    It 'an OU without blocked inheritance in production: nothing is sent to the node to join' {
        $ou = @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $true; exists = $true; gpOptions = 0; blockInheritance = $false; enforcedLinks = @(); error = '' } } }
        $t = Get-DjTransport ($ou + @{ 'Apply:join' = @{ status = 'joined'; reboot = $false; detail = 'must not run' } }) @($script:Before, $script:Before)
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -EventContext $script:Ctx
        @($t.Log | Where-Object Kind -like 'Apply:*') | Should -BeNullOrEmpty
        $r.Converged | Should -BeFalse
        @($r.Blocked | Where-Object Item -eq 'OU Group Policy inheritance').Count | Should -Be 1
    }
    It 'an already joined node in the right OU with the administrators present: one Read, no change' {
        $joined = Add-DjOu (Get-JoinedState)
        $t = Get-DjTransport @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $true; exists = $true; gpOptions = 1; blockInheritance = $true; enforcedLinks = @(); error = '' } } } @($joined)
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver
        $r.Converged | Should -BeTrue
        @($t.Log | Where-Object Kind -like 'Apply:*') | Should -BeNullOrEmpty
        @($r.Changes).Count | Should -Be 0
    }
    It 'a joined node that lacks the local administrators gets them, once, and a second run changes nothing' {
        $spec = Get-DjSpec { param($d) $d.identity.active_directory.netbios_name = 'IIC'; $d.identity.active_directory.local_admin_members = @('sg-a') }
        $missing = Add-DjOu (Get-JoinedState @{ localAdmins = @('azl-admin') })
        $present = Add-DjOu (Get-JoinedState @{ localAdmins = @('azl-admin', 'IIC\sg-a') })
        $ouAnswer = @{ OuCheck = @{ ou = [pscustomobject]@{ checked = $true; exists = $true; gpOptions = 1; blockInheritance = $true; enforcedLinks = @(); error = '' } } }
        $t = Get-DjTransport ($ouAnswer + @{ 'Apply:admins' = @{ status = 'configured'; detail = 'added'; added = @('IIC\sg-a') } }) @($missing, $present, $present)
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver -EventContext $script:Ctx
        $r.Converged | Should -BeTrue
        @($t.Log | Where-Object Kind -eq 'Apply:admins').Count | Should -Be 1
        $t2 = Get-DjTransport $ouAnswer @($present)
        $r2 = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t2 -Execute -Step 'DomainJoin' -SecretResolver $script:Resolver
        @($t2.Log | Where-Object Kind -like 'Apply:*') | Should -BeNullOrEmpty
        $r2.Converged | Should -BeTrue
    }
    It 'a local identity design: nothing is asked of the node, the item says not applicable, and it converges' {
        $spec = Get-DjSpec { param($d) $d.scenario.identity = 'local_identity' }
        $t = Get-DjTransport @{} @([pscustomobject]@{ host = 'iic-n01'; boot = 'b'; err = [pscustomobject]@{} })
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -Step 'DomainJoin'
        $r.Converged | Should -BeTrue
        @($t.Log).Count | Should -Be 2 -Because 'the Read, and the read-only status of the last guarded change'
        ($r.Plan | Where-Object Step -eq 'DomainJoin').Note | Should -Match 'not applicable: local identity'
        $r.DomainJoin.applicable | Should -BeFalse
    }
}

Describe 'The wrapper: record, report, summary and the event feed' {
    It 'Merge-AzlDomainJoinResult notes domainJoined, domain and OU in the record' {
        $text = InModuleScope AzlOsConfigurationRun {
            $record = [ordered]@{ domainJoin = [ordered]@{ applicable = $false; domainJoined = $false; domain = ''; ou = ''; secureChannel = $null; error = '' } }
            $entry = [pscustomobject]@{ domainJoin = [pscustomobject]@{ applicable = $true; domainJoined = $true; domain = 'improbability.cloud'; ou = 'OU=x,DC=improbability,DC=cloud'; secureChannel = $true; error = '' } }
            Merge-AzlDomainJoinResult -Record $record -Entry $entry
            $record.domainJoin | ConvertTo-Json
        }
        $d = $text | ConvertFrom-Json
        $d.domainJoined | Should -BeTrue
        $d.domain | Should -Be 'improbability.cloud'
        $d.ou | Should -Be 'OU=x,DC=improbability,DC=cloud'
    }
    It 'the verification pass keeps the failure text of the apply, until the node is joined' {
        $out = InModuleScope AzlOsConfigurationRun {
            $record = [ordered]@{ domainJoin = [ordered]@{ applicable = $true; domainJoined = $false; domain = 'd'; ou = 'o'; secureChannel = $null; error = '' } }
            Merge-AzlDomainJoinResult -Record $record -Entry ([pscustomobject]@{ domainJoin = [pscustomobject]@{ applicable = $true; domainJoined = $false; domain = 'd'; ou = 'o'; error = 'error 1326' } })
            Merge-AzlDomainJoinResult -Record $record -Entry ([pscustomobject]@{ domainJoin = [pscustomobject]@{ applicable = $true; domainJoined = $false; domain = 'd'; ou = 'o'; error = '' } })
            [string]$record.domainJoin.error
        }
        $out | Should -Be 'error 1326'
    }
    It 'the summary shows a Domain column for an AD design, in the table and in Markdown, and none otherwise' {
        $rec = {
            param($applicable, $joined)
            [pscustomobject]@{ name = 'n1'; method = 'Iso'; methodSource = 'declared'; transport = 'WinRM'; changes = @(); pendingChanges = 0; blocked = 0; status = 'planned'; converged = $true; restarted = $false; errors = @()
                domainJoin = [ordered]@{ applicable = $applicable; domainJoined = $joined; domain = 'improbability.cloud' } }
        }
        $joinedText = Format-AzlOsConfigurationSummary -Record @(& $rec $true $true) -Mode Plan -ExitCode 0
        $joinedText | Should -Match 'Domain'
        $joinedText | Should -Match 'joined improbability.cloud'
        (Format-AzlOsConfigurationSummary -Record @(& $rec $true $false) -Mode Plan -ExitCode 0) | Should -Match 'not joined'
        (Format-AzlOsConfigurationSummary -Record @(& $rec $true $true) -Mode Plan -ExitCode 0 -Markdown) | Should -Match '\| Domain \|'
        $local = Format-AzlOsConfigurationSummary -Record @(& $rec $false $false) -Mode Plan -ExitCode 0
        $local | Should -Not -Match 'Domain'
    }
}

Describe 'The wrapper run with the DomainJoin step (the OS configuration script is mocked)' {
    BeforeAll {
        $global:DjCalls = [System.Collections.Generic.List[object]]::new()
        $global:DjApplied = [System.Collections.Generic.HashSet[string]]::new()
        function global:Get-DjFakeSetResult($Parameters) {
            $global:DjCalls.Add($Parameters)
            $name = $Parameters.Node[0]
            if ($Parameters.ContainsKey('Execute')) { [void]$global:DjApplied.Add($name) }
            $joined = $global:DjApplied.Contains($name)
            $domainJoin = [pscustomobject]@{ applicable = $true; domainJoined = $joined; domain = 'improbability.cloud'; ou = 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'; secureChannel = $joined; credential = 'lcm_user'; error = '' }
            $entry = [pscustomobject]@{
                name = $Parameters.Node[0]; hostname = $Parameters.Node[0]; osVersion = '10.0.26100.1'; converged = $joined; restarted = $joined; ports = @(); sanDisks = @()
                changes = @(if ($joined) { [pscustomobject]@{ Pass = 1; Id = 'DomainJoin/join'; Status = 'changed'; Detail = 'joined' } })
                plan = @([pscustomobject]@{ step = 'DomainJoin'; item = 'domain membership'; current = 'workgroup WORKGROUP'; desired = 'improbability.cloud'; action = $(if ($joined) { 'Ok' } else { 'Change' }); note = '' })
                domainJoin = $domainJoin
            }
            [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Report = [pscustomobject]@{ nodes = @($entry) } }
        }
        $script:Infra = Join-Path $TestDrive 'wrap.yml'
        Copy-Item -LiteralPath $script:Fixture -Destination $script:Infra
    }
    AfterAll { Remove-Item Function:\Get-DjFakeSetResult -ErrorAction SilentlyContinue; Remove-Variable DjCalls, DjApplied -Scope Global -ErrorAction SilentlyContinue }
    BeforeEach {
        $global:DjCalls.Clear()
        $global:DjApplied.Clear()
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlSetNodeConfiguration { Get-DjFakeSetResult $Parameters }
        Mock -ModuleName AzlOsConfigurationRun Test-AzlAzureSignedIn { $true }
        Mock -ModuleName AzlOsConfigurationRun Test-AzlWinRmPort { $true }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
            foreach ($c in $Candidate) { [pscustomobject]@{ Node = $c.Name; Reachable = $true; Address = @($c.Addresses)[0]; Port = 5985; Result = 'Open'; Credential = 'vault'; Diagnosis = ''; Tried = @($c.Addresses) } }
        }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlSecret { 'not-the-join-password' }
        Mock -ModuleName AzlOsConfigurationRun Find-AzlArcMachine { [pscustomobject]@{ Name = $ArcMachineName; ResourceId = "/subscriptions/x/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ArcMachineName"; Location = 'eastus'; Status = 'Connected'; Interfaces = @() } }
        Mock -ModuleName AzlOsConfigurationRun New-AzlWinRmTransport { [pscustomobject]@{ Kind = 'WinRM' } }
        # The identity read (the first authenticated connection): the machine at the address is the node itself (its name and the fixture's management MACs).
        Mock -ModuleName AzlOsConfigurationRun Get-AzlRunNodeIdentity { [pscustomobject]@{ ComputerName = $Name.ToUpperInvariant(); Mac = @('00:00:5E:00:53:10', '00:00:5E:00:53:20') } }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript { [pscustomobject]@{ caption = 'Microsoft Azure Stack HCI'; build = 26100; host = 'WIN-X' } }
    }
    It '<Method> run: passes DomainJoin in the steps and the event feed to the node script, notes domainJoined, domain and OU in the record and the report' -ForEach @(@{ Method = 'Iso' }, @{ Method = 'Ztp' }) {
        $out = Join-Path $TestDrive "out-$Method-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $handoff = @{}
        if ($Method -eq 'Ztp') { $handoff.HandoffPath = Join-Path ([IO.Path]::Combine($script:Repo, 'tests', 'fixtures')) 'handoff.v2.json' }
        $result = Invoke-AzlOsConfiguration -InfrastructureFile $script:Infra -Mode Apply -ReportDirectory $out -SkipValidation -Method $Method -Step DomainJoin -Node 'iic-n01' @handoff 6>$null 3>$null
        $result.ExitCode | Should -Be 0
        $call = $global:DjCalls | Select-Object -Last 1
        'DomainJoin' | Should -BeIn $call.Step
        $call.EventLogPath | Should -Be (Join-Path $out 'os-configuration-events.jsonl')
        $call.EventMethod | Should -Be $Method
        $call.EventPhase | Should -BeIn 'Plan', 'Apply', 'Verify'
        $record = $result.Records[0]
        $record.domainJoin.domainJoined | Should -BeTrue
        $record.domainJoin.domain | Should -Be 'improbability.cloud'
        $record.domainJoin.ou | Should -Be 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $report = Get-Content -LiteralPath $result.ReportPath -Raw | ConvertFrom-Json
        $report.nodes[0].domainJoin.domainJoined | Should -BeTrue
        $report.nodes[0].domainJoin.domain | Should -Be 'improbability.cloud'
        (Get-Content -LiteralPath (Join-Path $out 'summary.md') -Raw) | Should -Match 'joined improbability.cloud'
    }
    It 'a Plan run shows the node as not joined and passes the Plan phase to the node script' {
        $out = Join-Path $TestDrive "out-plan-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $result = Invoke-AzlOsConfiguration -InfrastructureFile $script:Infra -Mode Plan -ReportDirectory $out -SkipValidation -Method Iso -Step DomainJoin -Node 'iic-n01' 6>$null 3>$null
        $result.Records[0].domainJoin.domainJoined | Should -BeFalse
        $result.Records[0].domainJoin.applicable | Should -BeTrue
        ($global:DjCalls | Select-Object -First 1).EventPhase | Should -Be 'Plan'
        (Get-Content -LiteralPath (Join-Path $out 'summary.md') -Raw) | Should -Match 'not joined'
    }
    It 'the exit code semantics are unchanged: a blocked DomainJoin item makes the run exit 1' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlSetNodeConfiguration {
            $r = Get-DjFakeSetResult $Parameters
            $r.Report.nodes[0].plan = @([pscustomobject]@{ step = 'DomainJoin'; item = 'domain membership'; current = 'member of contoso.com'; desired = 'improbability.cloud'; action = 'Blocked'; note = 'joined to a different domain' })
            $r
        }
        $out = Join-Path $TestDrive "out-blocked-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $result = Invoke-AzlOsConfiguration -InfrastructureFile $script:Infra -Mode Plan -ReportDirectory $out -SkipValidation -Method Iso -Step DomainJoin -Node 'iic-n01' 6>$null 3>$null
        $result.ExitCode | Should -Be 1
    }
}