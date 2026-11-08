#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The verification after a node restart. The lab case (node tplabs-azl-n03, apply-n03-pass5): every step applied, the drivers asked for a restart (pnputil 3010),
# the node went down, and the run's final verify opened its session while the node was still restarting. WinRM said "Access is denied" after 0.1 s, the run called that
# a refused credential, ended with status failed and exit 1, and a verification 20 minutes later found the node converged. These tests fake the node's restart
# (the port is closed for a while, then a session is refused for a while, then the node answers) and a clock that moves only when the run sleeps: no network, no Azure,
# no node, no real waiting.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/RestartVerify.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester runs a module mock in the module scope; a global is how the mock reports back to the test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mocks keep the signature of the real functions.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $node = Join-Path (Join-Path (Join-Path $repo 'scripts') 'common') 'node-configuration'
    Import-Module (Join-Path $node 'AzlNodeAddress.psm1') -Force
    Import-Module (Join-Path $node 'AzlOsConfigurationRun.psm1') -Force
    Import-Module powershell-yaml
    $fixtures = Join-Path (Join-Path $repo 'tests') 'fixtures'
    $script:Fixture = Join-Path $fixtures 'infrastructure.fc-san.yml'
    $script:HandoffFixture = Join-Path $fixtures 'handoff.v2.json'

    function Get-TestInfra {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Fixture -Raw) -Ordered
        $doc.scenario.os_install = 'simplified'
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        return $file
    }
    function Get-TestHandoffDirectory {
        $dir = Join-Path $TestDrive "handoffs-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $null = New-Item -ItemType Directory -Path $dir
        $copy = Get-Content -LiteralPath $script:HandoffFixture -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
        $copy.nodes = @($copy.nodes | Where-Object { $_.name -eq 'iic-n01' })
        $copy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $dir 'iic-n01.ztp-handoff.json')
        return $dir
    }

    # The text WinRM gave in the lab while the node was restarting, and what a node that is still down gives.
    $script:DeniedText = 'Connecting to remote server 192.0.2.11 failed with the following error message : Access is denied. For more information, see the about_Remote_Troubleshooting Help topic.'

    # What the OS configuration script reports for the node. The Apply restarts the node (when the test says so); until the run has seen the node answer again, a
    # Plan or Verify call fails the way the lab run did.
    function global:New-RsSetResult($Parameters) {
        $name = $Parameters.Node[0]
        $phase = [string]$Parameters.EventPhase
        $rs = $global:AzlRs
        $rs.Calls.Add([pscustomobject]@{ Phase = $phase; NodeActive = $rs.Active; Params = $Parameters })
        if ($phase -ne 'Apply' -and $rs.Active) {
            return [pscustomobject]@{ ExitCode = 1; Error = "$phase of ${name} failed: ADDRESS IDENTITY: The address you gave for $name answered, but its identity could not be proven: the local administrator was refused at 192.0.2.11 (override): Opening a session to $name at 192.0.2.11:5985 failed after 0.1 s (open timeout 30 s): $($rs.DeniedText)"; Unknown = $false; Report = $null }
        }
        if ($phase -eq 'Apply') { $rs.Applied = $true; if ($rs.Restart) { $rs.Active = $true } }
        $plan = @([pscustomobject]@{ step = 'Dns'; item = 'DNS servers'; current = 'x'; desired = 'y'; action = $(if ($rs.Applied) { 'Ok' } else { 'Change' }); note = '' })
        $entry = [pscustomobject]@{
            name = $name; hostname = $name; osVersion = '10.0.26100.1'; converged = $rs.Applied; restarted = [bool]($phase -eq 'Apply' -and $rs.Restart); restartRequired = [bool]($phase -eq 'Apply' -and $rs.RestartRequiredOnly); ports = @(); sanDisks = @([pscustomobject]@{ uid = 'UID1' })
            changes = @(if ($phase -eq 'Apply') { [pscustomobject]@{ Pass = 1; Id = 'Drivers/b57nd60a.inf'; Status = 'changed'; Detail = 'driver b57nd60a.inf 221.0.8.0 installed (pnputil 3010)' } }); plan = $plan; wipe = @(); guard = @(); pendingGuard = @()
        }
        [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Report = [pscustomobject]@{ nodes = @($entry) } }
    }
    function Reset-RestartFake {
        $global:AzlRs = @{
            Restart = $true; RestartRequiredOnly = $false; Active = $false; Applied = $false; DeniedText = $script:DeniedText
            PortDown = 3        # port probes that find the port closed while the node restarts
            Denied = 2          # session opens that are refused ("Access is denied") once the port is open again
            Now = [datetime]::SpecifyKind([datetime]'2026-11-08T10:00:00', [DateTimeKind]::Utc)
            Calls = [System.Collections.Generic.List[object]]::new()
            Sessions = [System.Collections.Generic.List[string]]::new()
            Ports = [System.Collections.Generic.List[string]]::new()
        }
    }
    function Invoke-Run {
        param([hashtable]$Extra = @{})
        $out = Join-Path $TestDrive "out-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $hosts = [pscustomobject]@{ Value = '' }
        $store = [pscustomobject]@{ Supported = $true; Get = { $hosts.Value }.GetNewClosure(); Set = { param($Value) $hosts.Value = $Value }.GetNewClosure() }
        $arguments = @{ InfrastructureFile = (Get-TestInfra); HandoffPath = (Get-TestHandoffDirectory); Node = 'iic-n01'; Mode = 'Apply'; ReportDirectory = $out; SkipValidation = $true; TrustedHostsStore = $store; NodeAddress = @{ 'iic-n01' = '192.0.2.11' } } + $Extra
        $result = Invoke-AzlOsConfiguration @arguments 6>$null 3>$null | Select-Object -Last 1
        $result | Add-Member -NotePropertyName Out -NotePropertyValue $out -Force
        return $result
    }
    function Read-RunEvent([object]$Run) { @(Get-Content -LiteralPath (Join-Path $Run.Out 'os-configuration-events.jsonl') -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
}

Describe 'The final verify waits for a node that was asked to restart' {
    BeforeEach {
        Reset-RestartFake
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlSetNodeConfiguration { New-RsSetResult $Parameters }
        Mock -ModuleName AzlOsConfigurationRun Test-AzlAzureSignedIn { $true }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlSecret { 'P@ssw0rd-from-the-vault-not-printed' }
        Mock -ModuleName AzlOsConfigurationRun Find-AzlArcMachine { [pscustomobject]@{ Name = $ArcMachineName; ResourceId = "/subscriptions/x/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ArcMachineName"; Location = 'eastus'; Status = 'Connected'; Interfaces = @() } }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
            foreach ($c in $Candidate) { [pscustomobject]@{ Node = $c.Name; Reachable = $true; Address = @($c.Addresses)[0]; Port = 5985; Result = 'Open'; Credential = 'vault'; Diagnosis = ''; Tried = @() } }
        }
        Mock -ModuleName AzlOsConfigurationRun Test-AzlWinRmPort {
            $global:AzlRs.Ports.Add($Address)
            if ($global:AzlRs.Active -and $global:AzlRs.PortDown -gt 0) { $global:AzlRs.PortDown--; return $false }
            return $true
        }
        # The session: refused ("Access is denied") for a while once the port is open, then the node answers and is back.
        Mock -ModuleName AzlOsConfigurationRun Get-AzlRunNodeIdentity {
            $rs = $global:AzlRs
            $rs.Sessions.Add($Address)
            if ($rs.Active) {
                if ($rs.Denied -gt 0) { $rs.Denied--; throw "Opening a session to $Name at ${Address}:5985 failed after 0.1 s (open timeout 30 s): $($rs.DeniedText)" }
                $rs.Active = $false
            }
            [pscustomobject]@{ ComputerName = $Name.ToUpperInvariant(); Mac = @('00:00:5E:00:53:10', '00:00:5E:00:53:20') }
        }
        Mock -ModuleName AzlOsConfigurationRun New-AzlWinRmTransport { [pscustomobject]@{ Kind = 'WinRM' } }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript { [pscustomobject]@{ caption = 'Microsoft Azure Stack HCI'; build = 26100; host = 'WIN-X' } }
        # The clock moves only when the run sleeps.
        Mock -ModuleName AzlOsConfigurationRun Start-Sleep { $global:AzlRs.Now = $global:AzlRs.Now.AddSeconds([double]$Seconds) }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlRunUtcNow { $global:AzlRs.Now }
    }
    AfterAll { Remove-Variable -Name AzlRs -Scope Global -ErrorAction SilentlyContinue }

    It 'restart, then verify: the run waits for the port, then for a session, and only then verifies; converged, exit 0' {
        $r = Invoke-Run
        $r.ExitCode | Should -Be 0
        $r.Records[0].converged | Should -BeTrue
        $r.Records[0].errors | Should -BeNullOrEmpty
        $verify = @($global:AzlRs.Calls | Where-Object Phase -eq 'Verify')
        $verify.Count | Should -Be 1
        $verify[0].NodeActive | Should -BeFalse
        # the port was asked until it answered, then a session was opened until the node accepted it
        $global:AzlRs.PortDown | Should -Be 0
        $global:AzlRs.Denied | Should -Be 0
    }

    It 'says it is waiting: a NodeWaiting event that names "waiting for restart", then NodeReconnected' {
        $r = Invoke-Run
        $events = Read-RunEvent $r
        $waiting = @($events | Where-Object state -eq 'NodeWaiting')
        $waiting.Count | Should -BeGreaterOrEqual 1
        $waiting[0].evidence | Should -Match 'waiting for restart'
        $waiting[0].waiting | Should -Be 'restart'
        @($events | Where-Object { $_.state -eq 'NodeReconnected' }).Count | Should -BeGreaterOrEqual 1
        @($events | Where-Object state -eq 'NodeFailed') | Should -BeNullOrEmpty
    }

    It 'a refused session while the node starts up is not a refused credential: it is waited out (the lab case)' {
        $global:AzlRs.PortDown = 0
        $global:AzlRs.Denied = 4
        $r = Invoke-Run
        $r.ExitCode | Should -Be 0
        $global:AzlRs.Denied | Should -Be 0
    }

    It 'a node that never comes back: honest message "did not come back within 15 minutes", status failed, exit 1, and no verify against a node that is down' {
        $global:AzlRs.PortDown = 100000
        $r = Invoke-Run
        $r.ExitCode | Should -Be 1
        $r.Records[0].status | Should -Be 'failed'
        $r.Records[0].converged | Should -BeFalse
        $text = @($r.Records[0].errors) -join ' '
        $text | Should -Match 'did not come back within 15 minutes'
        $text | Should -Not -Match 'refused'
        @($global:AzlRs.Calls | Where-Object Phase -eq 'Verify') | Should -BeNullOrEmpty
        $events = Read-RunEvent $r
        @($events | Where-Object state -eq 'NodeWaiting').Count | Should -BeGreaterThan 5
        (@($events | Where-Object state -eq 'NodeFailed')[0]).evidence | Should -Match 'did not come back within 15 minutes'
        # the wait was bounded by the clock the run sleeps on: 15 minutes, not an hour
        ($global:AzlRs.Now - [datetime]::SpecifyKind([datetime]'2026-11-08T10:00:00', [DateTimeKind]::Utc)).TotalMinutes | Should -BeLessThan 20
    }

    It 'the wait is the run setting restartWaitMinutes' {
        $global:AzlRs.PortDown = 100000
        $r = Invoke-Run -Extra @{ Settings = @{ restartWaitMinutes = 2 } }
        $r.ExitCode | Should -Be 1
        (@($r.Records[0].errors) -join ' ') | Should -Match 'did not come back within 2 minutes'
    }

    It 'a port that answers while every session is refused is said as it is: the session is refused, after N minutes' {
        $global:AzlRs.PortDown = 0
        $global:AzlRs.Denied = 100000
        $r = Invoke-Run -Extra @{ Settings = @{ restartWaitMinutes = 1 } }
        $r.ExitCode | Should -Be 1
        $text = @($r.Records[0].errors) -join ' '
        $text | Should -Match 'did not come back within 1 minute'
        $text | Should -Match 'Access is denied'
    }

    It 'a restart that is required but switched off (noRestart) is not waited for, and the record and the report say it is still required' {
        $global:AzlRs.Restart = $false
        $global:AzlRs.RestartRequiredOnly = $true
        $r = Invoke-Run -Extra @{ Settings = @{ noRestart = $true } }
        @(Read-RunEvent $r | Where-Object state -eq 'NodeWaiting') | Should -BeNullOrEmpty
        $r.Records[0].restartRequired | Should -BeTrue
        $r.Records[0].restarted | Should -BeFalse
        (@($r.Records[0].warnings) -join ' ') | Should -Match 'a restart is required.*NOT done'
        $report = Get-Content -LiteralPath (Join-Path $r.Out 'report.json') -Raw | ConvertFrom-Json
        $report.nodes[0].restartRequired | Should -BeTrue
    }

    It 'a node that was not asked to restart is verified at once: no wait, no NodeWaiting' {
        $global:AzlRs.Restart = $false
        $r = Invoke-Run
        $r.ExitCode | Should -Be 0
        @(Read-RunEvent $r | Where-Object state -eq 'NodeWaiting') | Should -BeNullOrEmpty
        @($global:AzlRs.Calls | Where-Object Phase -eq 'Verify').Count | Should -Be 1
    }
}

Describe 'Run setting restartWaitMinutes' {
    It 'is a known run setting' {
        (Get-AzlRunSetting -Settings @{ restartWaitMinutes = 5 }).restartWaitMinutes | Should -Be 5
    }
    It 'has to be a whole number of minutes, at least 1' {
        { Get-AzlRunSetting -Settings @{ restartWaitMinutes = 0 } } | Should -Throw '*restartWaitMinutes*'
        { Get-AzlRunSetting -Settings @{ restartWaitMinutes = 'soon' } } | Should -Throw '*restartWaitMinutes*'
    }
    It 'is registered in the master variable registry (tools.os_configuration run settings), where the run reads it from' {
        $registry = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') 'config') 'variables') (Join-Path 'schema' 'master-registry.yaml')) -Raw
        $registry | Should -Match 'restartWaitMinutes: \{"name":"restartWaitMinutes","type":"integer"'
    }
}
