#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the one-time WinRM bootstrap: the script, the smb route (sc.exe and net use are fakes: no real SMB), the Arc route (the ARM
# calls and the clock are fakes: no Azure), the routes in order, the gating by class and approval, and that the password never shows up.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/RemotingBootstrap.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A made-up test password.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake script blocks take the parameters the real ones are called with.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $common = Join-Path (Join-Path $repo 'scripts') 'common'
    foreach ($m in 'AzlRemotingProfile', 'AzlRemotingSession', 'AzlRemotingBootstrap') { Import-Module (Join-Path (Join-Path $common 'remoting') "$m.psm1") -Force }
    Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
    Import-Module powershell-yaml
    $script:Example = Join-Path (Join-Path (Join-Path (Join-Path $repo 'config') 'variables') 'examples') 'infrastructure.example.yml'
    $script:Password = 'Tr0ub4dor&3-test-only'
    $script:Credential = [pscredential]::new('Administrator', (ConvertTo-SecureString $script:Password -AsPlainText -Force))
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    function Resolve-For([string]$Class, [string]$Bootstrap = 'none', [hashtable]$Override = @{}) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        $doc.scenario.environment_class = $Class
        $doc.os_configuration.remoting.bootstrap_transport = $Bootstrap
        $doc.os_configuration.remoting.certificate = ('AB' * 20)
        Resolve-AzlRemotingProfile -Infrastructure $doc -Override $Override
    }
    function Get-ScriptAst([string]$Text) { $e = $null; [pscustomobject]@{ Ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$e); Errors = $e } }
    function Get-FakeResult([bool]$Ok, [string]$Why = '') { [pscustomobject]@{ Ok = $Ok; Reason = $Why; Result = $(if ($Ok) { [pscustomobject]@{ ok = $true } } else { $null }) } }
}

Describe 'The bootstrap script' {
    BeforeAll {
        $script:Full = New-AzlRemotingBootstrapScript -RemoteAddress @('Any') -Rdp $true -RdpRemoteAddress @('Any') -Icmp $true -IcmpRemoteAddress @('Any') -Thumbprint ('AB' * 20)
        $script:Plain = New-AzlRemotingBootstrapScript -RemoteAddress @('192.0.2.0/24', '198.51.100.10/32')
    }
    It 'is small enough for a service command line (cmd.exe takes 8191 characters), even with everything on' {
        $script:Full.Length | Should -BeLessThan 3000
        (Get-AzlBootstrapCommandLine -Script $script:Full).Length | Should -BeLessThan 7800
    }
    It 'parses, and uses no 7-only syntax' {
        (Get-ScriptAst $script:Full).Errors | Should -BeNullOrEmpty
        $script:Full | Should -Not -Match '\?\?|&&|\|\|'
    }
    It 'parses in Windows PowerShell 5.1' -Skip:(-not ($IsWindows -and (Get-Command powershell.exe -ErrorAction SilentlyContinue))) {
        $file = Join-Path $TestDrive 'boot.ps1'
        Set-Content -LiteralPath $file -Value $script:Full
        [int](& powershell.exe -NoProfile -Command "`$e=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$file',[ref]`$null,[ref]`$e);`$e.Count" | Select-Object -Last 1) | Should -Be 0
    }
    It 'does only the RemoteManagement firewall and listener step: starts WinRM, Enable-PSRemoting, rule scope, optional RDP, ICMP and HTTPS, one result line' {
        $allowed = 'Set-Service', 'Get-Service', 'Start-Service', 'Get-ChildItem', 'Enable-PSRemoting', 'Out-Null', 'Get-NetFirewallPortFilter', 'Where-Object', 'ForEach-Object', 'Get-NetFirewallRule', 'Select-Object',
        'Set-NetFirewallRule', 'Get-Item', 'New-WSManInstance', 'New-NetFirewallRule', 'Set-ItemProperty', 'Get-NetFirewallAddressFilter', 'ConvertTo-Json', 'Set-Content', 'Write-Output', '?', '%'
        $commands = (Get-ScriptAst $script:Full).Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Select-Object -Unique
        @($commands | Where-Object { $_ -notin $allowed }) | Should -BeNullOrEmpty
        $script:Full | Should -Not -Match 'Rename-Computer|Add-Computer|IPAddress|Restart|Stop-Computer|Remove-|Invoke-WebRequest|DnsClient|w32tm|Disable-|sc\.exe|net use|Password'
    }
    It 'sets Enabled, every profile and the scope on the rules it finds by port, not by name' {
        $script:Plain | Should -Match 'Enable-PSRemoting -Force -SkipNetworkProfileCheck'
        $script:Plain | Should -Match 'LocalPort\)\.Count -eq 1'
        $script:Plain | Should -Match 'Set-NetFirewallRule -Name \$r -Enabled True -Profile Any -RemoteAddress \$ra'
        $script:Plain | Should -Match "\`$ra=@\('192\.0\.2\.0/24','198\.51\.100\.10/32'\)"
        $script:Plain | Should -Not -Match 'WINRM-HTTP-In-TCP'
    }
    It 'lab and test: the scope is Any' {
        (New-AzlRemotingBootstrapScript -RemoteAddress @('Any')) | Should -Match "\`$ra=@\('Any'\)"
    }
    It 'RDP, ICMP and the HTTPS listener are in only when asked for' {
        $script:Plain | Should -Not -Match 'fDenyTSConnections|FPS-ICMP|New-WSManInstance'
        $script:Full | Should -Match 'fDenyTSConnections'
        $script:Full | Should -Match 'FPS-ICMP4-ERQ-In'
        $script:Full | Should -Match ('Cert:\\LocalMachine\\My')
        $script:Full | Should -Match ('AB' * 20)
    }
    It 'writes one AZLBOOT line to the result file for smb, and only to the output for Arc' {
        $script:Plain | Should -Match 'azl-bootstrap-[0-9a-f]{32}\.txt'
        $arc = New-AzlRemotingBootstrapScript -RemoteAddress @('Any') -ResultPath ''
        $arc | Should -Not -Match 'Set-Content'
        $arc | Should -Match 'Write-Output \$j'
        $arc | Should -Match 'AZLBOOT:'
    }
    It 'nothing typed becomes code: an address, a thumbprint or a path that is not plain is refused' {
        { New-AzlRemotingBootstrapScript -RemoteAddress @("1.2.3.4'; calc; '") } | Should -Throw "*isn't an address*"
        { New-AzlRemotingBootstrapScript -RemoteAddress @('Any') -Rdp $true -RdpRemoteAddress @('$(calc)') } | Should -Throw "*isn't an address*"
        { New-AzlRemotingBootstrapScript -RemoteAddress @('Any') -Thumbprint 'XYZ' } | Should -Throw '*40 hex*'
        { New-AzlRemotingBootstrapScript -RemoteAddress @('Any') -ResultPath 'C:\x";calc;"' } | Should -Throw '*plain Windows path*'
    }
    It 'the encoded command decodes to the script' {
        $line = Get-AzlBootstrapCommandLine -Script $script:Plain
        $b64 = $line.Substring($line.IndexOf('-EncodedCommand ') + 16)
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64)) | Should -Be $script:Plain
    }
    It 'a script too long for cmd.exe is refused, not truncated' {
        { Get-AzlBootstrapCommandLine -Script ('x' * 4000) } | Should -Throw '*too long*'
    }
    It 'reads its own result line, and nothing else' {
        (Read-AzlBootstrapResult -Text "noise`nAZLBOOT:{`"ok`":true,`"rules`":[`"a|True|Any|Any`"]}").ok | Should -BeTrue
        Read-AzlBootstrapResult -Text 'no result here' | Should -BeNullOrEmpty
        Read-AzlBootstrapResult -Text 'AZLBOOT:{broken' | Should -BeNullOrEmpty
        Read-AzlBootstrapResult -Text $null | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-AzlSmbBootstrap (sc.exe and net use are fakes)' {
    BeforeAll {
        # A fake world: records every call in order, answers from a table.
        function Get-FakeSmb([int]$StartExit = 1053, [int]$CreateExit = 0, [int]$NetUseExit = 0, [bool]$ResultAppears = $true, [string]$Result = 'AZLBOOT:{"ok":true,"rules":["x|True|Any|Any"]}', [bool]$PortOpen = $true) {
            $w = @{ Log = [System.Collections.Generic.List[string]]::new(); Args = [System.Collections.Generic.List[object]]::new(); FileExists = $false; Slept = 0; Result = $Result; Appears = $ResultAppears }
            $w.Sc = { param($Arguments) $w.Args.Add($Arguments); $verb = $Arguments[1]; $w.Log.Add("sc $verb")
                switch ($verb) {
                    'create' { [pscustomobject]@{ ExitCode = $CreateExit; Output = $(if ($CreateExit) { 'create failed' } else { '[SC] CreateService SUCCESS' }) } }
                    'start' { if ($w.Appears) { $w.FileExists = $true }; [pscustomobject]@{ ExitCode = $StartExit; Output = $(if ($StartExit) { "FAILED $StartExit" } else { '' }) } }
                    default { [pscustomobject]@{ ExitCode = 0; Output = '' } }
                } }.GetNewClosure()
            $w.NetUse = { param($Arguments) $w.Args.Add($Arguments); $w.Log.Add($(if ($Arguments -contains '/delete') { 'net use /delete' } else { 'net use' })); [pscustomobject]@{ ExitCode = $(if ($Arguments -contains '/delete') { 0 } else { $NetUseExit }); Output = $(if ($NetUseExit -and $Arguments -notcontains '/delete') { 'System error 1326' } else { '' }) } }.GetNewClosure()
            $w.PortTest = { param($a, $p) $null = $a; $w.Log.Add("port $p"); $PortOpen }.GetNewClosure()
            $w.TestFile = { param($Path) $null = $Path; $w.FileExists }.GetNewClosure()
            $w.ReadFile = { param($Path) $w.Log.Add("read $Path"); $w.Result }.GetNewClosure()
            $w.DeleteFile = { param($Path) $w.Log.Add("delete $Path"); $w.FileExists = $false }.GetNewClosure()
            $w.Sleep = { param($Seconds) $w.Slept += $Seconds }.GetNewClosure()
            $w
        }
        function Invoke-Smb($W, [int]$Wait = 60) {
            Invoke-AzlSmbBootstrap -Node 'n1' -Address '192.0.2.11' -Script 'Write-Output ok' -Credential $script:Credential -WaitSeconds $Wait -Sc $W.Sc -NetUse $W.NetUse -PortTest $W.PortTest -TestFile $W.TestFile -ReadFile $W.ReadFile -DeleteFile $W.DeleteFile -Sleep $W.Sleep -SkipPlatformCheck
        }
    }
    It 'runs the steps in the order that worked live: net use, create, start, delete the service, read the file, delete the file, net use /delete' {
        $w = Get-FakeSmb
        $r = Invoke-Smb $w
        $r.Ok | Should -BeTrue
        $log = @($w.Log)
        $log[0..4] | Should -Be @('port 445', 'net use', 'sc create', 'sc start', 'sc delete')
        $log[5] | Should -Match '^read \\\\192\.0\.2\.11\\C\$\\Windows\\Temp\\azl-bootstrap-[0-9a-f]{32}\.txt$'
        $log[6] | Should -Match '^delete \\\\192\.0\.2\.11\\C\$\\Windows\\Temp\\azl-bootstrap-[0-9a-f]{32}\.txt$'
        $log[7] | Should -Be 'net use /delete'
        $log.Count | Should -Be 8
    }
    It 'authenticates to IPC$ as the local Administrator, and creates a LocalSystem service on demand that runs powershell with the encoded script' {
        $w = Get-FakeSmb
        $null = Invoke-Smb $w
        $net = $w.Args[0]
        $net[1] | Should -Be '\\192.0.2.11\IPC$'
        $net | Should -Contain '/user:Administrator'
        $create = $w.Args | Where-Object { $_[1] -eq 'create' } | Select-Object -First 1
        $create[0] | Should -Be '\\192.0.2.11'
        $create | Should -Contain 'binPath='
        $create | Should -Contain 'LocalSystem'
        $create[($create.IndexOf('start=') + 1)] | Should -Be 'demand'
        $bin = $create[($create.IndexOf('binPath=') + 1)]
        $bin | Should -Match '^cmd\.exe /c powershell\.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '
    }
    It 'sc start returning 1053 is expected and is not a failure' {
        (Invoke-Smb (Get-FakeSmb -StartExit 1053)).Ok | Should -BeTrue
        $r = Invoke-Smb (Get-FakeSmb -StartExit 0)
        $r.Ok | Should -BeTrue
        ($r.Steps -join ' ') | Should -Not -Match 'expected for a command'
        ((Invoke-Smb (Get-FakeSmb -StartExit 1053)).Steps -join ' ') | Should -Match 'expected for a command that is not a service'
    }
    It 'any other sc start error fails the route, and the service, the share connection and the result file are still cleaned up' {
        $w = Get-FakeSmb -StartExit 5
        $r = Invoke-Smb $w
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'sc start failed \(exit 5\)'
        @($w.Log) | Should -Contain 'sc delete'
        @($w.Log)[-1] | Should -Be 'net use /delete'
    }
    It 'a failed create or a failed net use leaves nothing behind' {
        $w = Get-FakeSmb -CreateExit 1
        (Invoke-Smb $w).Ok | Should -BeFalse
        @($w.Log) | Should -Not -Contain 'sc delete'
        @($w.Log)[-1] | Should -Be 'net use /delete'
        $w2 = Get-FakeSmb -NetUseExit 2
        $r2 = Invoke-Smb $w2
        $r2.Reason | Should -Match 'net use .* failed'
        @($w2.Log) | Should -Not -Contain 'sc create'
    }
    It 'TCP 445 closed fails at once, before any credential is used' {
        $w = Get-FakeSmb -PortOpen $false
        $r = Invoke-Smb $w
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match '445'
        @($w.Log) | Should -Be @('port 445')
    }
    It 'waits for the result file, no longer than the cap, and says so' {
        $w = Get-FakeSmb -ResultAppears $false
        $r = Invoke-Smb $w 10
        $r.Ok | Should -BeFalse
        $w.Slept | Should -BeGreaterOrEqual 10
        $w.Slept | Should -BeLessThan 14
        $r.Reason | Should -Match 'No result from the node within 10 s'
        @($w.Log) | Should -Contain 'sc delete'
    }
    It 'the script failing on the node is reported with its message' {
        $r = Invoke-Smb (Get-FakeSmb -Result 'AZLBOOT:{"ok":false,"err":"Set-NetFirewallRule denied"}')
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'denied'
    }
    It 'the password appears in no result, reason or step, only as the one argument of net use' {
        foreach ($w in (Get-FakeSmb), (Get-FakeSmb -StartExit 5), (Get-FakeSmb -NetUseExit 2), (Get-FakeSmb -CreateExit 1), (Get-FakeSmb -ResultAppears $false)) {
            $r = Invoke-Smb $w 6
            ($r | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:Password))
            $withPassword = @($w.Args | Where-Object { $_ -contains $script:Password })
            $withPassword.Count | Should -BeLessOrEqual 1
            if ($withPassword.Count) { $withPassword[0][0] | Should -Be 'use' }
        }
    }
    It 'an error text that echoes the password is redacted' {
        $w = Get-FakeSmb -NetUseExit 2
        $w.NetUse = { param($Arguments) $null = $Arguments; [pscustomobject]@{ ExitCode = 2; Output = "logon failed for $($script:Password)" } }
        $r = Invoke-Smb $w
        $r.Reason | Should -Not -Match ([regex]::Escape($script:Password))
        $r.Reason | Should -Match '\*\*\*'
    }
    It 'refuses on a platform that is not Windows (sc.exe is Windows only), and says what to use instead' -Skip:$IsWindows {
        $r = Invoke-AzlSmbBootstrap -Node 'n1' -Address '192.0.2.11' -Script 'x' -Credential $script:Credential
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'Windows orchestrator'
    }
}

Describe 'Remove-AzlBootstrapStaleRunCommand and Invoke-AzlArcBootstrap (the ARM calls and the clock are fakes)' {
    BeforeAll {
        $script:Machine = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.HybridCompute/machines/n1'
        $script:Now = [datetime]::Parse('2026-11-07T20:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        # A fake ARM: a list of existing run commands, the calls made, and a script for the polled run.
        function Get-FakeArm([object[]]$Existing = @(), [scriptblock]$Poll) {
            $a = @{ Calls = [System.Collections.Generic.List[string]]::new(); Deleted = [System.Collections.Generic.List[string]]::new(); Puts = [System.Collections.Generic.List[object]]::new(); Polls = 0 }
            $a.Arm = { param($Method, $Path, $ApiVersion, $Body)
                $null = $ApiVersion
                $a.Calls.Add("$Method $Path")
                if ($Method -eq 'DELETE') { $a.Deleted.Add(($Path -split '/')[-1]); return $null }
                if ($Method -eq 'PUT') { $a.Puts.Add($Body); return $null }
                if ($Path -like '*/runCommands') { return [pscustomobject]@{ value = @($Existing) } }
                if ($Path -like '*/runCommands/*') { $a.Polls++; return (& $Poll $a.Polls) }
                [pscustomobject]@{ location = 'eastus' }
            }.GetNewClosure()
            $a
        }
        function Get-FakeRun([string]$Name, [string]$Created, [string]$State = 'Succeeded') { [pscustomobject]@{ name = $Name; systemData = [pscustomobject]@{ createdAt = $Created }; properties = [pscustomobject]@{ provisioningState = $State } } }
        # A clock that moves only when the code sleeps.
        function Get-FakeClock { $c = @{ T = $script:Now }; $c.Clock = { $c.T }.GetNewClosure(); $c.Sleep = { param($Seconds) $c.T = $c.T.AddSeconds($Seconds) }.GetNewClosure(); $c }
    }
    It 'deletes only this tool''s own azl-osconfig-* run commands older than 15 minutes' {
        $existing = @(
            (Get-FakeRun 'azl-osconfig-old1' '2026-11-07T19:30:00Z' 'Creating')
            (Get-FakeRun 'azl-osconfig-new1' '2026-11-07T19:50:00Z' 'Creating')
            (Get-FakeRun 'azl-osconfig-edge' '2026-11-07T19:45:00Z')
            (Get-FakeRun 'someone-elses-old' '2026-11-07T10:00:00Z')
            (Get-FakeRun 'azl-other-tool-old' '2026-11-07T10:00:00Z'))
        $arm = Get-FakeArm $existing
        $gone = @(Remove-AzlBootstrapStaleRunCommand -MachineId $script:Machine -Arm $arm.Arm -Now $script:Now -Confirm:$false)
        $gone | Should -Be @('azl-osconfig-old1')
        @($arm.Deleted) | Should -Be @('azl-osconfig-old1')
    }
    It 'a command with no timestamp is stale only when it did not succeed' {
        $stuck = [pscustomobject]@{ name = 'azl-osconfig-stuck'; properties = [pscustomobject]@{ provisioningState = 'Creating' } }
        $fine = [pscustomobject]@{ name = 'azl-osconfig-fine'; properties = [pscustomobject]@{ provisioningState = 'Succeeded' } }
        $arm = Get-FakeArm @($stuck, $fine)
        @(Remove-AzlBootstrapStaleRunCommand -MachineId $script:Machine -Arm $arm.Arm -Now $script:Now -Confirm:$false) | Should -Be @('azl-osconfig-stuck')
    }
    It 'WhatIf deletes nothing' {
        $arm = Get-FakeArm @((Get-FakeRun 'azl-osconfig-old1' '2026-11-07T10:00:00Z'))
        $null = Remove-AzlBootstrapStaleRunCommand -MachineId $script:Machine -Arm $arm.Arm -Now $script:Now -WhatIf
        $arm.Deleted.Count | Should -Be 0
    }
    It 'one run command: created, polled, read, deleted' {
        $clock = Get-FakeClock
        $arm = Get-FakeArm @() { param($n) $null = $n; [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; instanceView = [pscustomobject]@{ executionState = 'Succeeded'; output = "x`nAZLBOOT:{`"ok`":true,`"rules`":[]}" } } } }
        $r = Invoke-AzlArcBootstrap -Node 'n1' -ArcResourceId $script:Machine -Script 'Write-Output ok' -Arm $arm.Arm -Sleep $clock.Sleep -Clock $clock.Clock
        $r.Ok | Should -BeTrue
        $arm.Puts.Count | Should -Be 1
        $arm.Puts[0].properties.source.script | Should -Be 'Write-Output ok'
        $arm.Puts[0].properties.asyncExecution | Should -BeTrue
        $arm.Deleted.Count | Should -Be 1
        $arm.Deleted[0] | Should -Match '^azl-osconfig-boot-[0-9a-f]{8}$'
        $r.Steps -join ' ' | Should -Match 'deleted'
    }
    It 'the wait is capped at 3 minutes: a run command that never finishes fails the route cleanly and is deleted' {
        $clock = Get-FakeClock
        $arm = Get-FakeArm @() { param($n) $null = $n; [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Creating'; instanceView = [pscustomobject]@{ executionState = '' } } } }
        $r = Invoke-AzlArcBootstrap -Node 'n1' -ArcResourceId $script:Machine -Script 'x' -Arm $arm.Arm -Sleep $clock.Sleep -Clock $clock.Clock
        $r.Ok | Should -BeFalse
        $r.TimedOut | Should -BeTrue
        $r.Reason | Should -Match 'did not finish within 180 s'
        ($clock.T - $script:Now).TotalSeconds | Should -BeLessOrEqual 200
        ($clock.T - $script:Now).TotalSeconds | Should -BeGreaterOrEqual 180
        $arm.Deleted.Count | Should -Be 1
        $arm.Puts[0].properties.timeoutInSeconds | Should -Be 180
    }
    It 'the cap can be set' {
        $clock = Get-FakeClock
        $arm = Get-FakeArm @() { param($n) $null = $n; [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Creating' } } }
        $r = Invoke-AzlArcBootstrap -Node 'n1' -ArcResourceId $script:Machine -Script 'x' -WaitSeconds 30 -PollSeconds 5 -Arm $arm.Arm -Sleep $clock.Sleep -Clock $clock.Clock
        $r.TimedOut | Should -BeTrue
        ($clock.T - $script:Now).TotalSeconds | Should -BeLessOrEqual 35
    }
    It 'stale commands are deleted before a new one is created' {
        $clock = Get-FakeClock
        $arm = Get-FakeArm @((Get-FakeRun 'azl-osconfig-stuck1' '2026-11-07T19:00:00Z' 'Creating')) { param($n) $null = $n; [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; instanceView = [pscustomobject]@{ executionState = 'Succeeded'; output = 'AZLBOOT:{"ok":true}' } } } }
        $r = Invoke-AzlArcBootstrap -Node 'n1' -ArcResourceId $script:Machine -Script 'x' -Arm $arm.Arm -Sleep $clock.Sleep -Clock $clock.Clock
        $r.Ok | Should -BeTrue
        $arm.Deleted[0] | Should -Be 'azl-osconfig-stuck1'
        $arm.Deleted.Count | Should -Be 2
        $deleteIndex = [array]::IndexOf(@($arm.Calls), (@($arm.Calls) | Where-Object { $_ -like 'DELETE*stuck1' } | Select-Object -First 1))
        $putIndex = [array]::IndexOf(@($arm.Calls), (@($arm.Calls) | Where-Object { $_ -like 'PUT*' } | Select-Object -First 1))
        $deleteIndex | Should -BeLessThan $putIndex
    }
    It 'a run that ends in a failed state, or writes no result line, or reports a script error, fails the route and still deletes its command' {
        foreach ($case in @{ s = 'Failed'; o = ''; why = 'ended in state' }, @{ s = 'Succeeded'; o = 'no result'; why = 'no result line' }, @{ s = 'Succeeded'; o = 'AZLBOOT:{"ok":false,"err":"denied"}'; why = 'denied' }) {
            $script:c = $case
            $clock = Get-FakeClock
            $arm = Get-FakeArm @() { param($n) $null = $n; [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; instanceView = [pscustomobject]@{ executionState = $script:c.s; output = $script:c.o; error = '' } } } }
            $r = Invoke-AzlArcBootstrap -Node 'n1' -ArcResourceId $script:Machine -Script 'x' -Arm $arm.Arm -Sleep $clock.Sleep -Clock $clock.Clock
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Match $case.why
            $arm.Deleted.Count | Should -Be 1
        }
    }
    It 'an ARM error is a failed route, not an exception' {
        $clock = Get-FakeClock
        $arm = { param($Method, $Path, $ApiVersion, $Body) $null = $Path, $ApiVersion, $Body; if ($Method -eq 'PUT') { throw 'Forbidden' }; [pscustomobject]@{ value = @(); location = 'eastus' } }
        $r = Invoke-AzlArcBootstrap -Node 'n1' -ArcResourceId $script:Machine -Script 'x' -Arm $arm -Sleep $clock.Sleep -Clock $clock.Clock
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'Forbidden'
    }
}

Describe 'Invoke-AzlWinRmBootstrap: the routes, in order, behind the gate' {
    BeforeEach { Set-AzlRemotingEventSink -Reset -Confirm:$false }

    It 'lab, smb chosen: the smb route runs once, with the events' {
        $script:smb = 0
        $r = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'lab' 'smb') -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -SmbCommand { param($Node, $Address, $Script, $Account) $null = $Node, $Address, $Script, $Account; $script:smb++; Get-FakeResult $true }
        $r.Ok | Should -BeTrue
        $r.Route | Should -Be 'smb'
        $script:smb | Should -Be 1
        @((Get-AzlRemotingEvent).state) | Should -Be @('RemotingBootstrapStarted', 'RemotingBootstrapSucceeded')
        (Get-AzlRemotingEvent)[0].route | Should -Be 'smb'
    }
    It 'auto: smb first; when it fails, arc; both events for each, the failure with its reason' {
        $script:order = [System.Collections.Generic.List[string]]::new()
        $r = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'lab' 'auto') -Node 'n1' -Address '192.0.2.11' -ArcResourceId '/x/machines/n1' -Credential $script:Credential `
            -SmbCommand { param($Node, $Address, $Script, $Account) $null = $Node, $Address, $Script, $Account; $script:order.Add('smb'); Get-FakeResult $false 'TCP 445 is closed' } `
            -ArcCommand { param($Node, $Id, $Script) $null = $Node, $Id, $Script; $script:order.Add('arc'); Get-FakeResult $true }
        @($script:order) | Should -Be @('smb', 'arc')
        $r.Ok | Should -BeTrue
        $r.Route | Should -Be 'arc'
        @($r.Attempts.Route) | Should -Be @('smb', 'arc')
        @((Get-AzlRemotingEvent).state) | Should -Be @('RemotingBootstrapStarted', 'RemotingBootstrapFailed', 'RemotingBootstrapStarted', 'RemotingBootstrapSucceeded')
        $failed = (Get-AzlRemotingEvent)[1]
        $failed.route | Should -Be 'smb'
        $failed.reason | Should -Be 'TCP 445 is closed'
        $failed.level | Should -Be 'Warning'
    }
    It 'every route failing is a failed bootstrap that lists each reason' {
        $r = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'lab' 'auto') -Node 'n1' -Address '192.0.2.11' -ArcResourceId '/x/machines/n1' -Credential $script:Credential `
            -SmbCommand { param($Node, $Address, $Script, $Account) $null = $Node, $Address, $Script, $Account; Get-FakeResult $false 'smb broke' } `
            -ArcCommand { param($Node, $Id, $Script) $null = $Node, $Id, $Script; Get-FakeResult $false 'arc wedged' }
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'smb: smb broke \| arc: arc wedged'
    }
    It 'none: nothing runs, and the reason says it was not chosen' {
        $script:ran = $false
        $r = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'lab' 'none') -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -SmbCommand { $script:ran = $true; Get-FakeResult $true }
        $r.Ok | Should -BeFalse
        $script:ran | Should -BeFalse
        $r.Attempts.Count | Should -Be 0
        @(Get-AzlRemotingEvent) | Should -BeNullOrEmpty
    }
    It '<_>: needs -ApprovedBootstrap, and runs with it' -ForEach 'production', 'dmz' {
        $script:ran = 0
        $p = Resolve-For $_ 'smb'
        $without = Invoke-AzlWinRmBootstrap -RemotingProfile $p -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -SmbCommand { $script:ran++; Get-FakeResult $true }
        $without.Ok | Should -BeFalse
        $without.Reason | Should -Match 'ApprovedBootstrap'
        $script:ran | Should -Be 0
        $with = Invoke-AzlWinRmBootstrap -RemotingProfile $p -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -ApprovedBootstrap -Thumbprint ('AB' * 20) -SmbCommand { $script:ran++; Get-FakeResult $true }
        $with.Ok | Should -BeTrue
        $script:ran | Should -Be 1
    }
    It 'lab, test and dev need no approval' -ForEach 'lab', 'test', 'dev' {
        $script:ran = 0
        $r = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For $_ 'smb') -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -SmbCommand { $script:ran++; Get-FakeResult $true }
        $r.Ok | Should -BeTrue
        $script:ran | Should -Be 1
    }
    It 'the smb route without a credential, and the arc route without an Arc machine, fail with a reason and let the next route try' {
        $r = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'lab' 'auto') -Node 'n1' -Address '192.0.2.11' -ArcResourceId '/x/machines/n1' -ArcCommand { Get-FakeResult $true }
        $r.Ok | Should -BeTrue
        $r.Attempts[0].Reason | Should -Match 'credential'
        $r2 = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'lab' 'arc') -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential
        $r2.Ok | Should -BeFalse
        $r2.Reason | Should -Match 'Arc machine'
    }
    It 'the script handed to a route carries the profile''s scope (Any in lab, the allowed sources in dev), and the thumbprint when given' {
        $script:text = $null
        $null = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'lab' 'smb') -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -SmbCommand { param($Node, $Address, $Script, $Account) $null = $Node, $Address, $Account; $script:text = $Script; Get-FakeResult $true }
        $script:text | Should -Match "\`$ra=@\('Any'\)"
        $null = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'dev' 'smb') -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -Thumbprint ('CD' * 20) -SmbCommand { param($Node, $Address, $Script, $Account) $null = $Node, $Address, $Account; $script:text = $Script; Get-FakeResult $true }
        $script:text | Should -Match '198\.51\.100\.10/32'
        $script:text | Should -Match ('CD' * 20)
        $script:text | Should -Not -Match "\`$ra=@\('Any'\)"
    }
    It 'the password appears in no event and no result, even when a route''s reason echoes it' {
        $r = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'lab' 'smb') -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -SmbCommand { Get-FakeResult $false "net use failed for $($script:Password)" }
        $all = ($r | ConvertTo-Json -Depth 8) + ((Get-AzlRemotingEvent) | ConvertTo-Json -Depth 8)
        $all | Should -Not -Match ([regex]::Escape($script:Password))
        $all | Should -Match '\*\*\*'
    }
}
