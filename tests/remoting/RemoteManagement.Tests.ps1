#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the RemoteManagement step: the node scripts (as text), the spec, the comparison (Ok, Change, Blocked), the guarded apply
# with injected node commands, the certificate trust helpers, and the step order. No node, no Azure, no machine setting is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/RemoteManagement.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A mock or a script block run by the module reports back through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake script blocks take the parameters the real ones are called with.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $common = Join-Path (Join-Path $repo 'scripts') 'common'
    Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodePayload.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodeTransport.psm1') -Force
    # The remoting modules first: the node configuration module then binds to these instances, which is what a mock of them needs.
    foreach ($m in 'AzlRemotingProfile', 'AzlRemotingPayload', 'AzlRemotingSession', 'AzlRemoteManagement') { Import-Module (Join-Path (Join-Path $common 'remoting') "$m.psm1") -Force }
    Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodeConfiguration.psm1') -Force
    Import-Module powershell-yaml
    $script:Fixture = Join-Path (Join-Path (Join-Path $repo 'tests') 'fixtures') 'infrastructure.fc-san.yml'
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    function Get-FixtureInfra([string]$Class, [scriptblock]$Change) {
        $infra = Import-AzlInfrastructure -Path $script:Fixture -SkipValidation
        if (-not $infra.Contains('os_configuration')) { $infra['os_configuration'] = [ordered]@{} }
        if (-not $infra['os_configuration'].Contains('remoting')) { $infra['os_configuration']['remoting'] = [ordered]@{} }
        if ($Class) { $infra['scenario']['environment_class'] = $Class }
        if ($Change) { & $Change $infra }
        $infra
    }
    function Get-ProfileFor([string]$Class, [scriptblock]$Change) { Resolve-AzlRemotingProfile -Infrastructure (Get-FixtureInfra $Class $Change) }
    function Get-NodeSpecFor([string]$Class, [scriptblock]$Change, [string]$Current = '192.0.2.11') {
        $p = Get-ProfileFor $Class $Change
        New-AzlRemotingNodeSpec -RemotingProfile $p -Name 'iic-n01' -ManagementIp '192.0.2.11' -DnsNames @('iic-n01', 'iic-n01.example.invalid') -CurrentAddress $Current
    }
    # What the Read script returns for a node that already matches the spec.
    function Get-MatchingState([object]$Spec) {
        $local = @("$($Spec.ManagementIp)/32")
        $rules = foreach ($r in $Spec.Rules) {
            if ($r.kind -eq 'managed' -and $r.desired -eq 'present') {
                [pscustomobject]@{ name = $r.name; enabled = $true; profile = 'Any'; remote = @($r.remote); local = $local; protocol = $r.protocol; port = [string]$r.port }
            }
        }
        $listeners = @()
        $listenAddr = "IP:$($Spec.ManagementIp)"
        if ($Spec.HttpsListener) { $listeners += [pscustomobject]@{ transport = 'HTTPS'; address = $listenAddr; port = '5986'; thumbprint = ('AB' * 20); hostname = 'iic-n01' } }
        if ($Spec.HttpListener) { $listeners += [pscustomobject]@{ transport = 'HTTP'; address = $(if ($Spec.ListenerBind -eq 'managementIp') { $listenAddr } else { '*' }); port = '5985'; thumbprint = ''; hostname = '' } }
        $winrm = @()
        $discover = @($Spec.Rules | Where-Object { $_.kind -eq 'discoverWinRm' })[0]
        if ($discover.desired -eq 'present') { $winrm = @('WINRM-HTTP-In-TCP', 'WINRM-HTTP-In-TCP-PUBLIC' | ForEach-Object { [pscustomobject]@{ name = $_; enabled = $true; profile = 'Any'; remote = @($discover.remote); local = @('Any'); protocol = 'TCP'; port = '5985' } }) }
        else { $winrm = @('WINRM-HTTP-In-TCP', 'WINRM-HTTP-In-TCP-PUBLIC' | ForEach-Object { [pscustomobject]@{ name = $_; enabled = $false; profile = 'Any'; remote = @('Any'); local = @('Any'); protocol = 'TCP'; port = '5985' } }) }
        [pscustomobject]@{
            v = 1; host = 'iic-n01'; domainJoined = $false
            service = [pscustomobject]@{ running = $true; allowUnencrypted = 'false'; basic = 'false'; credSsp = 'false'; cbt = 'Strict'; compatHttp = 'false'; compatHttps = 'false' }
            listeners = $listeners; rules = @($rules); winrmRules = $winrm
            certs = @([pscustomobject]@{ thumbprint = ('AB' * 20); subject = 'CN=iic-n01'; dns = @('iic-n01'); ips = @($Spec.ManagementIp); serverAuth = $true; privateKey = $true; selfSigned = $true; notAfter = '2030-01-01T00:00:00.0000000Z' })
            wantCert = $null; categories = @([pscustomobject]@{ alias = 'Port0'; category = 'Public' })
            rdp = [pscustomobject]@{ deny = $(if ($Spec.RdpEnabled) { 0 } else { 1 }); nla = $(if ($Spec.RdpEnabled) { 1 } else { $null }) }
            tls = [pscustomobject]@{ tls12ServerEnabled = $null }; addresses = @($Spec.ManagementIp); pending = $null; err = [pscustomobject]@{}
        }
    }
    function Copy-State([object]$State) { $State | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10 }
    function Get-Item2([object[]]$Plan, [string]$Like) { @($Plan | Where-Object { $_.Item -like $Like }) }

    function ConvertTo-ResultLine([object]$Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
    }
}

Describe 'The node scripts' {
    BeforeAll {
        $script:Read = Get-AzlRemotingPayload -Name Read
        $script:Change = Get-AzlRemotingPayload -Name Change
        function Get-Ast([string]$Text) { $e = $null; $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$e); [pscustomobject]@{ Ast = $ast; Errors = $e } }
    }
    It '<_> parses, with no 7-only syntax (ternary, ??, &&, ||)' -ForEach 'Read', 'Change' {
        $text = Get-AzlRemotingPayload -Name $_
        (Get-Ast $text).Errors | Should -BeNullOrEmpty
        $text | Should -Not -Match '\?\?|\s\?\s.+\s:\s|&&|\|\|'
        $text | Should -Not -Match 'ForEach-Object -Parallel|\$IsWindows|ConvertFrom-Json -AsHashtable'
    }
    It '<_> parses in Windows PowerShell 5.1' -ForEach 'Read', 'Change' -Skip:(-not ($IsWindows -and (Get-Command powershell.exe -ErrorAction SilentlyContinue))) {
        $file = Join-Path $TestDrive "$_.ps1"
        Set-Content -LiteralPath $file -Value (Get-AzlRemotingPayload -Name $_)
        $out = & powershell.exe -NoProfile -Command "`$e=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$file',[ref]`$null,[ref]`$e);`$e.Count"
        [int]($out | Select-Object -Last 1) | Should -Be 0
    }
    It 'Read changes nothing: no Set, New, Remove, Enable, Disable, Add, Start or Stop command' {
        $commands = (Get-Ast $script:Read).Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
        $bad = @($commands | Where-Object { $_ -match '^(Set|New|Remove|Enable|Disable|Add|Start|Stop|Restart|Import|Install)-' -and $_ -notin 'Set-StrictMode', 'New-Object' })
        $bad | Should -BeNullOrEmpty
    }
    It 'Change sets the WinRM baseline: AllowUnencrypted false, Basic and CredSSP off, CBT Strict, no HTTP.sys compatibility listener' {
        $script:Change | Should -Match 'Service\\AllowUnencrypted'', ''false'''
        $script:Change | Should -Match 'Service\\Auth\\Basic'', ''false'''
        $script:Change | Should -Match 'Service\\Auth\\CredSSP'', ''false'''
        $script:Change | Should -Match 'CbtHardeningLevel'', ''Strict'''
        $script:Change | Should -Match 'EnableCompatibilityHttpListener'', ''false'''
        $script:Change | Should -Match 'EnableCompatibilityHttpsListener'', ''false'''
    }
    It 'Change enables PSRemoting itself and opens the rules on every profile' {
        $script:Change | Should -Match 'Enable-PSRemoting -Force -SkipNetworkProfileCheck'
        $script:Change | Should -Match 'Set-NetFirewallRule -Name \$name -Enabled True -Profile Any -RemoteAddress'
        $script:Change | Should -Match "-Profile = 'Any'|Profile = 'Any'"
    }
    It 'finds the WinRM rules by port (5985, 5986, inbound), not by a name' {
        $script:Change | Should -Match "Get-NetFirewallPortFilter -Protocol TCP"
        $script:Change | Should -Match "'5985'.*'5986'|'5986'"
        $script:Change | Should -Match "Direction -eq 'Inbound'"
        $script:Change | Should -Not -Match 'WINRM-HTTP-In-TCP'
        $script:Read | Should -Not -Match 'WINRM-HTTP-In-TCP'
    }
    It 'never skips the certificate check and never allows unencrypted traffic' {
        foreach ($text in $script:Read, $script:Change) {
            $text | Should -Not -Match 'SkipCACheck|SkipCNCheck|SkipRevocationCheck'
            $text | Should -Not -Match "AllowUnencrypted'', ''true|-Basic|Auth\\Basic'', ''true|Auth\\CredSSP'', ''true"
        }
    }
    It 'the self-signed certificate has DNS names and IP addresses as subject alternative names, Server Authentication, and a key that cannot be exported' {
        $script:Change | Should -Match 'New-SelfSignedCertificate'
        $script:Change | Should -Match "'DNS=' \+"
        $script:Change | Should -Match "'IPAddress=' \+"
        $script:Change | Should -Match '1\.3\.6\.1\.5\.5\.7\.3\.1'
        $script:Change | Should -Match 'KeyExportPolicy NonExportable'
        $script:Change | Should -Match 'AzlOsConfig WinRM bootstrap'
    }
    It 'stage unions the old and the new scope, the commit sets the exact one; the HTTP side goes only when verified' {
        $script:Change | Should -Match 'Set-ManagedRule \$r \$true'
        $script:Change | Should -Match 'Set-ManagedRule \$r \$false'
        $script:Change | Should -Match 'Set-DiscoveredWinRmScope \$r \$true'
        $script:Change | Should -Match 'Set-DiscoveredWinRmScope \$r \$false'
        $script:Change | Should -Match "absentAfterVerify' -and \`$verified"
        $script:Change | Should -Match 'Restore-Snapshot'
        $script:Change | Should -Match 'New-Snapshot'
    }
    It 'the snapshot is taken before the first change, and the pending marker is written and cleared' {
        $i = $script:Change.IndexOf('$null = New-Snapshot $changeId')
        $j = $script:Change.IndexOf("Add-Result 'baseline' 'changed' (Set-Baseline)")
        $i | Should -BeGreaterThan 0
        $i | Should -BeLessThan $j
        $script:Change | Should -Match 'pending\.json'
    }
    It 'the certificate PFX is read from the secrets only and never written to disk or printed' {
        ([regex]::Matches($script:Change, 'certificatePfx')).Count | Should -Be 1
        $script:Change | Should -Not -Match 'Set-Content[^\n]*\$pfx|Out-File[^\n]*\$pfx|Write-Output[^\n]*\$pfx'
        $script:Change | Should -Not -Match 'adminPassword|ConvertTo-SecureString'
    }
    It 'the pure helpers on the node normalise firewall addresses (run here in pwsh)' {
        $fn = (Get-Ast $script:Change).Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'ConvertTo-Cidr', 'Get-NormalProfile' }, $true)
        $fn.Count | Should -Be 2
        foreach ($f in $fn) { . ([scriptblock]::Create($f.Extent.Text)) }
        ConvertTo-Cidr '192.0.2.0/255.255.255.0' | Should -Be '192.0.2.0/24'
        ConvertTo-Cidr '192.0.2.5' | Should -Be '192.0.2.5/32'
        ConvertTo-Cidr 'Any' | Should -Be 'Any'
        ConvertTo-Cidr 'LocalSubnet' | Should -Be 'LocalSubnet'
        ConvertTo-Cidr '2001:db8::5' | Should -Be '2001:db8::5/128'
        Get-NormalProfile 'Domain, Private, Public' | Should -Be 'Any'
        Get-NormalProfile 'Public' | Should -Be 'Public'
    }
}

Describe 'The node spec' {
    It 'production: own rules for HTTPS, RDP and ICMP, SMB between the nodes, HTTP going away after HTTPS is verified' {
        $s = Get-NodeSpecFor 'production'
        $byName = @{}; foreach ($r in $s.Rules | Where-Object { $_.Contains('name') }) { $byName[$r.name] = $r }
        $byName['AzlOsConfig-WinRM-HTTPS-In'].desired | Should -Be 'present'
        $byName['AzlOsConfig-WinRM-HTTP-In'].desired | Should -Be 'absentAfterVerify'
        $byName['AzlOsConfig-Node-SMB-In'].desired | Should -Be 'present'
        @($byName['AzlOsConfig-Node-SMB-In'].remote) | Should -Be @('192.0.2.11/32', '192.0.2.12/32')
        $byName['AzlOsConfig-ICMPv4-Echo-In'].icmpType | Should -Be '8'
        $byName['AzlOsConfig-ICMPv6-Echo-In'].icmpType | Should -Be '128'
        @($s.Rules | Where-Object kind -eq 'discoverWinRm').Count | Should -Be 1
        @($s.Rules | Where-Object kind -eq 'disableRule').Count | Should -BeGreaterThan 0
        $s.RuleNames | Should -Contain 'AzlOsConfig-Node-SMB-In'
        $s.ListenerBind | Should -Be 'managementIp'
    }
    It 'lab: every scope is Any, built-in rules are left alone, the HTTP listener stays' {
        $s = Get-NodeSpecFor 'lab'
        @($s.Rules | Where-Object kind -eq 'disableRule') | Should -BeNullOrEmpty
        (@($s.Rules | Where-Object { $_.Contains('name') -and $_.name -eq 'AzlOsConfig-WinRM-HTTP-In' })[0]).desired | Should -Be 'present'
        (@($s.Rules | Where-Object { $_.Contains('name') -and $_.name -eq 'AzlOsConfig-WinRM-HTTP-In' })[0]).remote | Should -Be @('Any')
        (@($s.Rules | Where-Object kind -eq 'discoverWinRm')[0]).remote | Should -Be @('Any')
        $s.ListenerBind | Should -Be 'any'
        $s.HttpListener | Should -BeTrue
        $s.HttpsListener | Should -BeFalse
    }
    It 'dmz: RDP rules are removed' {
        $s = Get-NodeSpecFor 'dmz' { param($d) $d['os_configuration']['remoting']['certificate'] = ('AB' * 20) }
        (@($s.Rules | Where-Object { $_.Contains('name') -and $_.name -eq 'AzlOsConfig-RDP-TCP-In' })[0]).desired | Should -Be 'absent'
        $s.RdpEnabled | Should -BeFalse
    }
    It 'the change parameters carry the rules and no secret' {
        $s = Get-NodeSpecFor 'production' { param($d) $d['os_configuration']['remoting']['certificate'] = 'keyvault://kv-example/node-cert' }
        $p = Get-AzlRemotingChangeParameter -Spec $s -Mode stage -ChangeId 'rm-1'
        $p.mode | Should -Be 'stage'
        $p.certMode | Should -Be 'keyVault'
        ($p | ConvertTo-Json -Depth 8) | Should -Not -Match 'certificatePfx'
    }
    It 'a Key Vault certificate travels as a secret, read through the resolver, and only when HTTPS is used' {
        $s = Get-NodeSpecFor 'production' { param($d) $d['os_configuration']['remoting']['certificate'] = 'keyvault://kv-example/node-cert' }
        (Get-AzlRemotingSecret -Spec $s -SecretResolver { param($Ref) "PFX-for-$Ref" }).certificatePfx | Should -Be 'PFX-for-keyvault://kv-example/node-cert'
        (Get-AzlRemotingSecret -Spec (Get-NodeSpecFor 'lab') -SecretResolver { throw 'no' }).Count | Should -Be 0
        { Get-AzlRemotingSecret -Spec $s -SecretResolver { throw 'denied' } } | Should -Throw '*Can''t read the server certificate*'
    }
}

Describe 'Compare-AzlRemotingState' {
    It '<_>: a node that matches the profile is Ok everywhere (information aside)' -ForEach 'lab', 'dev', 'production' {
        $s = Get-NodeSpecFor $_
        $plan = @(Compare-AzlRemotingState -Spec $s -State (Get-MatchingState $s))
        @($plan | Where-Object { $_.Action -in 'Change', 'Blocked' }) | Should -BeNullOrEmpty
        @($plan | Where-Object Action -eq 'Ok').Count | Should -BeGreaterThan 4
        ($plan | ForEach-Object Step | Select-Object -Unique) | Should -Be 'RemoteManagement'
    }
    Context 'production' {
        BeforeEach { $script:S = Get-NodeSpecFor 'production'; $script:State = Get-MatchingState $script:S }
        It 'WinRM off the baseline is a Change' {
            $script:State.service.allowUnencrypted = 'true'
            $i = Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'WinRM baseline'
            $i.Action | Should -Be 'Change'
            $i.Current | Should -Match 'AllowUnencrypted'
            $i.Apply.kind | Should -Be 'remoting'
        }
        It 'Basic, CredSSP, CBT and the compatibility listener each count' -ForEach @(@{ k = 'basic'; v = 'true' }, @{ k = 'credSsp'; v = 'true' }, @{ k = 'cbt'; v = 'Relaxed' }, @{ k = 'compatHttp'; v = 'true' }) {
            $script:State.service.($_.k) = $_.v
            (Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'WinRM baseline').Action | Should -Be 'Change'
        }
        It 'a stopped WinRM service is a Change' {
            $script:State.service.running = $false
            (Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'WinRM baseline').Action | Should -Be 'Change'
        }
        It 'a missing HTTPS listener is a Change; the wrong certificate is a Change' {
            $script:State.listeners = @()
            (Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'HTTPS listener').Action | Should -Be 'Change'
        }
        It 'a certificate without the node IP as a subject alternative name is a Change' {
            $script:State.certs[0].ips = @('203.0.113.9')
            $i = Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'HTTPS listener'
            $i.Action | Should -Be 'Change'
            $i.Note | Should -Match 'IP subject alternative name'
        }
        It 'the HTTP listener and the * listener left over are a Change that says they go after HTTPS is verified' {
            $script:State.listeners = @($script:State.listeners) + [pscustomobject]@{ transport = 'HTTP'; address = '*'; port = '5985'; thumbprint = ''; hostname = '' }
            $i = Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'HTTP listener to remove*'
            $i.Action | Should -Be 'Change'
            $i.Note | Should -Match 'verified'
        }
        It 'a firewall rule with the wrong scope, off, on one profile only, or missing is a Change' {
            $script:State.rules[0].remote = @('Any')
            @(Compare-AzlRemotingState -Spec $script:S -State $script:State | Where-Object { $_.Item -eq "firewall $($script:State.rules[0].name)" -and $_.Action -eq 'Change' }).Count | Should -Be 1
            $script:State = Get-MatchingState $script:S
            $script:State.rules[0].profile = 'Public'
            @(Compare-AzlRemotingState -Spec $script:S -State $script:State | Where-Object { $_.Item -eq "firewall $($script:State.rules[0].name)" -and $_.Action -eq 'Change' }).Count | Should -Be 1
            $script:State = Get-MatchingState $script:S
            $script:State.rules[0].enabled = $false
            @(Compare-AzlRemotingState -Spec $script:S -State $script:State | Where-Object { $_.Item -eq "firewall $($script:State.rules[0].name)" -and $_.Action -eq 'Change' }).Count | Should -Be 1
            $script:State = Get-MatchingState $script:S
            $gone = $script:State.rules[0].name
            $script:State.rules = @($script:State.rules | Select-Object -Skip 1)
            @(Compare-AzlRemotingState -Spec $script:S -State $script:State | Where-Object { $_.Item -eq "firewall $gone" -and $_.Action -eq 'Change' }).Count | Should -Be 1
        }
        It 'the local address must be the management IP' {
            $script:State.rules[0].local = @('Any')
            @(Compare-AzlRemotingState -Spec $script:S -State $script:State | Where-Object { $_.Item -eq "firewall $($script:State.rules[0].name)" -and $_.Action -eq 'Change' }).Count | Should -Be 1
        }
        It 'the Public built-in WinRM rule found by port, still limited to the local subnet or enabled, is a Change' {
            $script:State.winrmRules[1].enabled = $true
            @(Compare-AzlRemotingState -Spec $script:S -State $script:State | Where-Object { $_.Item -like 'firewall WINRM*' -and $_.Action -eq 'Change' }).Count | Should -Be 1
        }
        It 'no built-in WinRM rule found at all is a Change (Enable-PSRemoting creates them)' {
            $script:State.winrmRules = @()
            (Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'firewall built-in WinRM rules').Action | Should -Be 'Change'
        }
        It 'an open built-in rule outside WinRM (RDP, ICMP) is a Change' {
            $script:State.rules = @($script:State.rules) + [pscustomobject]@{ name = 'FPS-ICMP4-ERQ-In'; enabled = $true; profile = 'Domain,Private'; remote = @('Any'); local = @('Any'); protocol = 'ICMPv4'; port = '' }
            @(Compare-AzlRemotingState -Spec $script:S -State $script:State | Where-Object { $_.Item -eq 'firewall FPS-ICMP4-ERQ-In' -and $_.Action -eq 'Change' }).Count | Should -Be 1
        }
        It 'RDP denied or without NLA is a Change' {
            $script:State.rdp.nla = 0
            (Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'RDP').Action | Should -Be 'Change'
        }
        It 'the management IP not on the node is Info (the listener stays on *), not Blocked: the Network step sets it later' {
            $script:State.addresses = @('203.0.113.99')
            $i = Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'listener address'
            $i.Action | Should -Be 'Info'
            $i.Note | Should -Match 'Network step'
        }
        It 'the address in use does not count as the bind address: the listener stays on * until the node holds the file address' {
            $s = Get-NodeSpecFor 'production' $null '203.0.113.99'
            $st = Get-MatchingState $s
            $st.addresses = @('203.0.113.99')
            (Get-Item2 (Compare-AzlRemotingState -Spec $s -State $st) 'listener address').Action | Should -Be 'Info'
        }
        It 'TLS 1.2 disabled on the node is Blocked (the step does not touch cipher settings)' {
            $script:State.tls.tls12ServerEnabled = 0
            (Get-Item2 (Compare-AzlRemotingState -Spec $script:S -State $script:State) 'TLS 1.2').Action | Should -Be 'Blocked'
        }
        It 'the network category is information only; a joined node gets the Kerberos hint; a staged change is reported' {
            $script:State.domainJoined = $true
            $script:State.pending = [pscustomobject]@{ changeId = 'rm-old'; taken = '2026-11-07T00:00:00Z' }
            $plan = @(Compare-AzlRemotingState -Spec $script:S -State $script:State)
            (Get-Item2 $plan 'network category').Action | Should -Be 'Info'
            (Get-Item2 $plan 'authentication').Note | Should -Match 'Kerberos'
            (Get-Item2 $plan 'staged change').Note | Should -Match 'snapshot'
        }
        It 'no state at all is reported, not guessed' {
            @(Compare-AzlRemotingState -Spec $script:S -State $null)[0].Action | Should -Be 'Info'
        }
    }
    Context 'lab: the rules are found by port and get the wildcard scope' {
        It 'the OS-install state (Public rule limited to the local subnet) is a Change in lab' {
            $s = Get-NodeSpecFor 'lab'
            $st = Get-MatchingState $s
            $st.winrmRules[1].remote = @('LocalSubnet')
            $i = @(Compare-AzlRemotingState -Spec $s -State $st | Where-Object { $_.Item -eq 'firewall WINRM-HTTP-In-TCP-PUBLIC' })
            $i.Action | Should -Be 'Change'
            $i.Note | Should -Match 'LocalSubnet'
            $i.Desired | Should -Match 'Any'
        }
        It 'a group-policy-widened scope is caught the same way after the join' {
            $s = Get-NodeSpecFor 'dev'
            $st = Get-MatchingState $s
            $st.domainJoined = $true
            $st.rules[0].remote = @('Any')
            @(Compare-AzlRemotingState -Spec $s -State $st | Where-Object { $_.Action -eq 'Change' }).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Invoke-AzlRemotingApply: the guarded change with injected commands' {
    BeforeAll {
        # A node that records what it was asked and answers from a script.
        function Get-FakeNode([scriptblock]$Answer) {
            $log = [System.Collections.Generic.List[object]]::new()
            $invoke = { param($Mode, $Parameters, $Secrets) $log.Add([pscustomobject]@{ Mode = $Mode; Parameters = $Parameters; Secrets = $Secrets }); & $Answer $Mode $Parameters }.GetNewClosure()
            [pscustomobject]@{ Log = $log; Invoke = $invoke }
        }
        $script:Good = { param($Mode, $Parameters)
            $null = $Parameters
            [pscustomobject]@{ ok = $true; reverted = $false; thumbprint = ('AB' * 20); certPublic = 'cHVibGlj'; results = @([pscustomobject]@{ id = 'AzlOsConfig-WinRM-HTTPS-In'; status = 'changed'; detail = "$Mode ok" }) }
        }
        function Get-PlanItem([object]$Spec) { @([pscustomobject]@{ Apply = @{ id = 'RemoteManagement/baseline'; kind = 'remoting' } }, [pscustomobject]@{ Apply = @{ id = 'RemoteManagement/rule-x'; kind = 'remoting' } }) }
    }
    BeforeEach { Set-AzlRemotingEventSink -Reset -Confirm:$false }

    It 'stage, confirm, commit: in that order, the commit told whether the HTTPS path was verified' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } }
        @($node.Log.Mode) | Should -Be @('stage', 'commit', 'disarm')
        $node.Log[1].Parameters.verified | Should -BeTrue
        $r.Status | Should -Be 'committed'
        $r.Verified | Should -BeTrue
        $r.HttpKept | Should -BeFalse
        $r.Thumbprint | Should -Be ('AB' * 20)
        @($r.Changes.Status | Select-Object -Unique) | Should -Be 'changed'
        @($r.Changes.Id).Count | Should -Be 2
    }
    It 'the HTTP side is KEPT when the HTTPS path is not verified' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $false; Reason = 'not trusted' } }
        $node.Log[1].Parameters.verified | Should -BeFalse
        $r.Status | Should -Be 'committed'
        $r.HttpKept | Should -BeTrue
        $r.Detail | Should -Match 'KEPT'
    }
    It 'a stage that fails on the node is reverted (the node restored itself, so no second revert is sent)' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode { param($Mode, $Parameters) $null = $Parameters; [pscustomobject]@{ ok = $false; reverted = $true; thumbprint = ''; certPublic = ''; results = @([pscustomobject]@{ id = 'stage'; status = 'failed'; detail = 'boom' }) } }
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -ConfirmPath { throw 'confirm must not run' }
        @($node.Log.Mode) | Should -Be @('stage')
        $r.Status | Should -Be 'reverted'
        $r.Reason | Should -Match 'boom'
        @($r.Changes.Status | Select-Object -Unique) | Should -Be 'failed'
    }
    It 'a stage call that throws (the path was lost) is reverted' {
        $s = Get-NodeSpecFor 'production'
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $invoke = { param($Mode, $Parameters, $Secrets) $null = $Parameters, $Secrets; $script:calls.Add($Mode); if ($Mode -eq 'stage') { throw 'connection lost' }; [pscustomobject]@{ ok = $true; results = @() } }
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $invoke -ConfirmPath { throw 'no' }
        @($script:calls) | Should -Be @('stage', 'revert')
        $r.Status | Should -Be 'reverted'
        $r.Reason | Should -Match 'connection lost'
    }
    It 'a confirmation that fails reverts, and nothing is committed' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $false; Verified = $false; Reason = 'the node does not answer' } }
        @($node.Log.Mode) | Should -Be @('stage', 'revert')
        $r.Status | Should -Be 'reverted'
        $r.Reason | Should -Match 'does not answer'
    }
    It 'a commit that fails reverts' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode { param($Mode, $Parameters) $null = $Parameters; if ($Mode -eq 'commit') { [pscustomobject]@{ ok = $false; results = @([pscustomobject]@{ id = 'commit'; status = 'failed'; detail = 'denied' }) } } else { [pscustomobject]@{ ok = $true; reverted = $false; results = @() } } }
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } }
        @($node.Log.Mode) | Should -Be @('stage', 'commit', 'revert')
        $r.Status | Should -Be 'reverted'
    }
    It 'a change an earlier run staged and never committed is put back first' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $null = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } } -State ([pscustomobject]@{ pending = [pscustomobject]@{ changeId = 'rm-old' } })
        @($node.Log.Mode) | Should -Be @('revert', 'stage', 'commit', 'disarm')
        $node.Log[0].Parameters.changeId | Should -Be 'rm-old'
    }
    It 'every call carries the same change id, and the secrets only travel as secrets' {
        $s = Get-NodeSpecFor 'production' { param($d) $d['os_configuration']['remoting']['certificate'] = 'keyvault://kv-example/node-cert' }
        $node = Get-FakeNode $script:Good
        $null = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -Secrets @{ certificatePfx = 'UNIQUE-PFX-MARKER' } -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } } -ChangeId 'rm-fixed'
        @($node.Log.Parameters.changeId | Select-Object -Unique) | Should -Be 'rm-fixed'
        ($node.Log.Parameters | ConvertTo-Json -Depth 8) | Should -Not -Match 'UNIQUE-PFX-MARKER'
        $node.Log[0].Secrets.certificatePfx | Should -Be 'UNIQUE-PFX-MARKER'
        ((Get-AzlRemotingEvent) | ConvertTo-Json -Depth 6) | Should -Not -Match 'UNIQUE-PFX-MARKER'
    }
    It 'writes RemotingFirewallChange and RemotingListenerChange with the class and the thumbprint' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $null = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } }
        $events = @(Get-AzlRemotingEvent)
        ($events | Where-Object state -eq 'RemotingFirewallChange').class | Should -Be 'production'
        ($events | Where-Object state -eq 'RemotingListenerChange').thumbprint | Should -Be ('AB' * 20)
        @($events | Where-Object { $_.step -ne 'RemoteManagement' -or $_.stage -ne 'OsConfiguration' }) | Should -BeNullOrEmpty
    }
    It 'a reverted change writes the events at Warning level' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $null = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $false; Verified = $false; Reason = 'x' } }
        (Get-AzlRemotingEvent | Where-Object state -eq 'RemotingFirewallChange').level | Should -Be 'Warning'
    }
    It 'the guarded change protocol can wrap it: a guard gets the change object and its four steps' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $script:seen = $null
        $guard = { param($Change)
            $script:seen = @($Change.PSObject.Properties.Name)
            $stage = & $Change.Stage $Change
            $revert = & $Change.Revert $Change
            [pscustomobject]@{ Status = 'reverted'; Stage = $stage; Confirm = $null; Commit = $null; Revert = $revert; Reason = 'the guard decided' }
        }
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem $s) -Invoke $node.Invoke -Guard $guard
        $script:seen | Should -Contain 'Stage'
        $script:seen | Should -Contain 'Confirm'
        $script:seen | Should -Contain 'Commit'
        $script:seen | Should -Contain 'Revert'
        @($node.Log.Mode) | Should -Be @('stage', 'revert')
        $r.Status | Should -Be 'reverted'
        $r.Reason | Should -Be 'the guard decided'
    }
    It 'after a verified commit that removes HTTP, a WinRM transport switches to HTTPS' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $transport = [pscustomobject]@{ Kind = 'WinRM'; State = @{ Ssl = $false; Sessions = @{}; Addresses = @{ 'iic-n01' = '192.0.2.11' } } }
        $r = Invoke-AzlRemotingApply -Spec $s -Transport $transport -Item (Get-PlanItem $s) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } }
        $r.TransportChanged | Should -BeTrue
        $transport.State.Ssl | Should -BeTrue
    }
    It 'but not when HTTP stays (lab) or the HTTPS path is not verified' {
        $transport = [pscustomobject]@{ Kind = 'WinRM'; State = @{ Ssl = $false; Sessions = @{}; Addresses = @{} } }
        $node = Get-FakeNode $script:Good
        $null = Invoke-AzlRemotingApply -Spec (Get-NodeSpecFor 'lab') -Transport $transport -Item (Get-PlanItem $null) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } }
        $transport.State.Ssl | Should -BeFalse
        $null = Invoke-AzlRemotingApply -Spec (Get-NodeSpecFor 'production') -Transport $transport -Item (Get-PlanItem $null) -Invoke $node.Invoke -ConfirmPath { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $false; Reason = '' } }
        $transport.State.Ssl | Should -BeFalse
    }
}

Describe 'Test-AzlRemotingPath: the default confirmation' {
    BeforeAll {
        function Get-ReadTransport([bool]$Answers) {
            $t = [pscustomobject]@{ Kind = 'WinRM'; Invoke = $null; Stage = $null; State = @{ Credential = $null; Addresses = @{}; Sessions = @{}; Ssl = $false } }
            $answer = $Answers
            $encode = ${function:ConvertTo-ResultLine}
            $t.Invoke = { param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
                $null = $Self, $Node, $Script, $Parameters, $Secrets, $TimeoutSeconds
                if ($answer) { [pscustomobject]@{ Output = (& $encode ([pscustomobject]@{ v = 1 })); Failed = $false; Error = ''; State = 'Succeeded' } }
                else { [pscustomobject]@{ Output = ''; Failed = $true; Error = 'unreachable'; State = 'Failed' } }
            }.GetNewClosure()
            $t
        }
    }
    It 'a node that no longer answers on the path in use is not confirmed' {
        $r = Test-AzlRemotingPath -Spec (Get-NodeSpecFor 'production') -Transport (Get-ReadTransport $false)
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'does not answer'
    }
    It 'HTTPS is verified only when 5986 answers and a full-check read works' {
        $s = Get-NodeSpecFor 'production'
        $t = Get-ReadTransport $true
        (Test-AzlRemotingPath -Spec $s -Transport $t -PortTest { $true } -HttpsRead { [pscustomobject]@{ Ok = $true; Reason = '' } }).Verified | Should -BeTrue
        $closed = Test-AzlRemotingPath -Spec $s -Transport $t -PortTest { $false } -HttpsRead { throw 'no' }
        $closed.Ok | Should -BeTrue
        $closed.Verified | Should -BeFalse
        $closed.Reason | Should -Match '5986'
        $untrusted = Test-AzlRemotingPath -Spec $s -Transport $t -PortTest { $true } -HttpsRead { [pscustomobject]@{ Ok = $false; Reason = 'the certificate is not trusted' } }
        $untrusted.Verified | Should -BeFalse
        $untrusted.Reason | Should -Match 'trust'
    }
    It 'with no HTTPS in the profile (lab), the confirmation is the read alone' {
        (Test-AzlRemotingPath -Spec (Get-NodeSpecFor 'lab') -Transport (Get-ReadTransport $true)).Verified | Should -BeTrue
    }
    It 'a node reached over Arc cannot verify HTTPS from here, and says why' {
        $arc = [pscustomobject]@{ Kind = 'ArcRunCommand'; Invoke = (Get-ReadTransport $true).Invoke; Stage = $null }
        $r = Test-AzlRemotingPath -Spec (Get-NodeSpecFor 'production') -Transport $arc -PortTest { $true }
        $r.Ok | Should -BeTrue
        $r.Verified | Should -BeFalse
        $r.Reason | Should -Match 'Arc Run Command'
    }
}

Describe 'The pre-join certificate trust procedure' {
    BeforeAll {
        $script:Bytes = [byte[]](1..64)
        $script:Thumb = [BitConverter]::ToString([Security.Cryptography.SHA1]::HashData($script:Bytes)).Replace('-', '')
    }
    It 'Save-AzlNodeCertificate writes the .cer and recomputes the thumbprint from the bytes' {
        $r = Save-AzlNodeCertificate -Node 'iic-n01' -CertPublic ([Convert]::ToBase64String($script:Bytes)) -ClaimedThumbprint $script:Thumb.ToLowerInvariant() -Path $TestDrive
        $r.Thumbprint | Should -Be $script:Thumb
        [IO.File]::ReadAllBytes($r.Path) | Should -Be $script:Bytes
    }
    It 'a thumbprint the node claimed but the bytes do not have is an error' {
        { Save-AzlNodeCertificate -Node 'iic-n01' -CertPublic ([Convert]::ToBase64String($script:Bytes)) -ClaimedThumbprint ('00' * 20) -Path $TestDrive } | Should -Throw '*hashes to*'
    }
    It 'trust is imported only when the thumbprint equals the one given through an authenticated channel' {
        $file = (Save-AzlNodeCertificate -Node 'iic-n02' -CertPublic ([Convert]::ToBase64String($script:Bytes)) -Path $TestDrive).Path
        $script:imported = $null
        $r = Import-AzlNodeCertificateTrust -Path $file -ExpectedThumbprint ($script:Thumb -replace '(..)', '$1:').TrimEnd(':') -Importer { param($Path, $StoreName, $StoreLocation) $script:imported = "$StoreLocation\$StoreName $Path" } -Confirm:$false
        $r.Imported | Should -BeTrue
        $script:imported | Should -Match 'CurrentUser\\Root'
        $script:imported = $null
        { Import-AzlNodeCertificateTrust -Path $file -ExpectedThumbprint ('00' * 20) -Importer { $script:imported = 'x' } -Confirm:$false } | Should -Throw '*not imported*'
        $script:imported | Should -BeNullOrEmpty
    }
    It 'trust can be removed again, by thumbprint' {
        $script:removed = $null
        Remove-AzlNodeCertificateTrust -Thumbprint $script:Thumb -Remover { param($Thumbprint, $StoreLocation) $script:removed = "$StoreLocation $Thumbprint" } -Confirm:$false
        $script:removed | Should -Be "CurrentUser $($script:Thumb)"
    }
}

Describe 'The step in the node configuration loop' {
    BeforeAll {
        # A stateful fake node: the remoting Read shows the OS-install state until the commit, then the matching state.
        function Get-StepNode([object]$Spec) {
            $log = [System.Collections.Generic.List[string]]::new()
            $flag = @{ committed = $false }
            $matching = Get-MatchingState $Spec
            $before = Copy-State $matching
            $before.service.allowUnencrypted = 'true'
            $before.winrmRules[1].remote = @('LocalSubnet')
            $before.winrmRules[1].enabled = $true
            $t = [pscustomobject]@{ Kind = 'Fake'; Invoke = $null; Stage = $null; Log = $log }
            $encode = ${function:ConvertTo-ResultLine}
            $t.Invoke = { param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
                $null = $Self, $Node, $Secrets, $TimeoutSeconds
                if ($Parameters.ContainsKey('mode')) { $log.Add("remoting:$($Parameters.mode)"); if ($Parameters.mode -eq 'commit') { $flag.committed = $true }; $out = [pscustomobject]@{ ok = $true; reverted = $false; thumbprint = ('AB' * 20); certPublic = ''; results = @() } }
                elseif ($Parameters.ContainsKey('ruleNames')) { $log.Add('remoting:read'); $out = $(if ($flag.committed) { $matching } else { $before }) }
                elseif ($Script -match 'function Invoke-Action') { $log.Add('apply'); $out = [pscustomobject]@{ reboot = $false; results = @() } }
                else { $log.Add('read'); $out = [pscustomobject]@{ v = 1; host = 'iic-n01'; boot = 'b'; os = '10.0'; nics = @(); remote = $null; err = [pscustomobject]@{} } }
                [pscustomobject]@{ Output = (& $encode $out); Failed = $false; Error = ''; State = 'Succeeded' }
            }.GetNewClosure()
            $t
        }
    }
    It 'RemoteManagement is the first step, before Network' {
        $order = InModuleScope AzlNodeConfiguration { $script:AllSteps }
        $order[0] | Should -Be 'RemoteManagement'
        [array]::IndexOf($order, 'RemoteManagement') | Should -BeLessThan ([array]::IndexOf($order, 'Network'))
    }
    It 'Plan reads (twice) and changes nothing' {
        $infra = Get-FixtureInfra 'production'
        $p = Resolve-AzlRemotingProfile -Infrastructure $infra
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0] -RemotingProfile $p
        $t = Get-StepNode $spec.Remoting
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Step RemoteManagement
        @($t.Log) | Should -Be @('read', 'remoting:read')
        @($r.Plan | Where-Object { $_.Action -eq 'Change' }).Count | Should -BeGreaterThan 1
        $r.Converged | Should -BeFalse
    }
    It 'Execute stages, confirms and commits before anything else, then finds the node converged' {
        $infra = Get-FixtureInfra 'production'
        $p = Resolve-AzlRemotingProfile -Infrastructure $infra
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0] -RemotingProfile $p
        $t = Get-StepNode $spec.Remoting
        Mock -ModuleName AzlRemoteManagement Test-AzlRemotingPath { [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } }
        Set-AzlRemotingEventSink -Reset -Confirm:$false
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Step RemoteManagement -Execute
        $firstChange = [array]::IndexOf(@($t.Log), 'remoting:stage')
        $firstChange | Should -BeGreaterThan 0
        # stage, then (the confirmation is mocked) the commit
        @($t.Log)[$firstChange..($firstChange + 1)] | Should -Be @('remoting:stage', 'remoting:commit')
        @($t.Log | Where-Object { $_ -eq 'apply' }).Count | Should -Be 0
        $r.Converged | Should -BeTrue
        @($r.Changes | Where-Object { $_.Id -like 'RemoteManagement/*' -and $_.Status -eq 'changed' }).Count | Should -BeGreaterThan 0
        @((Get-AzlRemotingEvent).state) | Should -Contain 'RemotingFirewallChange'
        @((Get-AzlRemotingEvent).state) | Should -Contain 'RemotingListenerChange'
    }
    It 'a reverted change leaves the node not converged and stops the loop' {
        $infra = Get-FixtureInfra 'production'
        $p = Resolve-AzlRemotingProfile -Infrastructure $infra
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0] -RemotingProfile $p
        $t = Get-StepNode $spec.Remoting
        Mock -ModuleName AzlRemoteManagement Test-AzlRemotingPath { [pscustomobject]@{ Ok = $false; Verified = $false; Reason = 'lost' } }
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Step RemoteManagement -Execute
        @($t.Log) | Should -Contain 'remoting:revert'
        @($t.Log | Where-Object { $_ -eq 'remoting:commit' }).Count | Should -Be 0
        $r.Converged | Should -BeFalse
        @($r.Changes | Where-Object { $_.Status -eq 'failed' }).Count | Should -BeGreaterThan 0
    }
    It 'without a profile the plain step is unchanged: no remoting call is made' {
        $infra = Get-FixtureInfra $null
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        $spec.Remoting | Should -BeNullOrEmpty
        $t = Get-StepNode (New-AzlRemotingNodeSpec -RemotingProfile (Get-ProfileFor 'production') -Name 'iic-n01' -ManagementIp '192.0.2.11')
        $null = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Step RemoteManagement
        @($t.Log | Where-Object { $_ -like 'remoting:*' }) | Should -BeNullOrEmpty
    }
}
