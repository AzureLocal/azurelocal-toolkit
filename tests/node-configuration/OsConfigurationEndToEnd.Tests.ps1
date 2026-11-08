#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# End to end: Invoke-AzureLocalOsConfiguration.ps1 runs in Plan mode with -Transport ArcRunCommand (the explicit exception; the default is WinRM) and with the REAL wrapper, the REAL Set-AzureLocalNodeConfiguration.ps1 and the
# REAL Arc Run Command transport. Only Azure is replaced: a fake Invoke-AzRestMethod (a global function, so the modules the scripts import with
# -Force still find it) plays the Arc machines and their run commands, and answers each Read with the state of a node that already matches the
# master file. Nothing here reaches the network, Azure or a node.
#
# Why this test exists: the wrapper once called a module-private function from a callback that ran outside the module, and died on the first
# read of the first node. The mocked-script tests didn't run that path. This one does: the retry of a run command that ends in state Unknown
# goes through the real transport, the real Set script and the wrapper's event feed.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/OsConfigurationEndToEnd.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The fake Azure is a global function (the scripts re-import their modules with -Force) and reports back through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test doubles.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Repo = $repo
    $common = Join-Path (Join-Path $repo 'scripts') 'common'
    Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodeConfiguration.psm1') -Force
    $script:Fixture = Join-Path (Join-Path $repo 'tests') (Join-Path 'fixtures' 'infrastructure.fc-san.yml')
    $script:HandoffFixture = Join-Path (Join-Path $repo 'tests') (Join-Path 'fixtures' 'handoff.v2.json')
    $script:EntryScript = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Invoke-AzureLocalOsConfiguration.ps1')

    function ConvertTo-ResultLine([object]$Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
    }

    # What the Read script returns for a node that already matches its spec (as in NodeConfiguration.Tests.ps1).
    function New-ConfiguredState([object]$Spec) {
        $nics = foreach ($p in $Spec.Ports) {
            $isMgmt = $p.IsManagement
            [pscustomobject]@{
                n = "OS$($p.Name)"; mac = $p.Mac; st = $(if ($p.Roles -contains 'unused') { 'Disabled' } else { 'Up' }); pci = 'PCI\VEN_15B3&DEV_101D'; drv = '24.4.1.0'; desc = 'x'
                dhcp = 'Disabled'; ips = $(if ($isMgmt) { @("$($Spec.Management.Ip)/$($Spec.Management.Prefix)/Manual") } else { @() })
                gw = $(if ($isMgmt) { @($Spec.Management.Gateway) } else { @() }); dns = $(if ($isMgmt) { @($Spec.Management.Dns) } else { @() }); vlan = $null
            }
        }
        [pscustomobject]@{
            v = 1; host = $Spec.Hostname; boot = '2026-11-07T01:00:00Z'; os = '10.0.26100.1'; reboot = $false; nics = @($nics)
            remote = [pscustomobject]@{ winrm = 'Running'; winrmStart = 'Automatic'; listeners = 1; rdpDeny = 0; rdpRules = 3; icmp4 = 1; icmp6 = 1 }
            time = [pscustomobject]@{ type = 'NTP'; peers = ($Spec.Ntp | ForEach-Object { "$_,0x8" }) -join ' '; src = $Spec.Ntp[0] }
            sbe = @(); drv = @()
            admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $true }
            stor = [pscustomobject]@{ pools = 0; vdisks = 0; dirty = @() }
            san = [pscustomobject]@{
                feature = 'Enabled'; hw = @('DellEMC|PowerStore'); lb = 'RR'
                set = [pscustomobject]@{ RetryCount = '3'; UseCustomPathRecoveryTime = 'Enabled'; CustomPathRecoveryTime = '10'; DiskTimeoutValue = '30' }
                fc = @($Spec.San.ExpectedWwpn | ForEach-Object { [pscustomobject]@{ wwpn = $_; up = 'Online' } }); iqn = @(); iscsiSvc = ''; iscsiClaim = ''
                disks = @(
                    [pscustomobject]@{ n = 1; bus = 'Fibre Channel'; gb = 300; ps = 'RAW'; sn = 'SERIAL-INFRA'; uid = 'UID-INFRA'; lun = 0; paths = 4; st = 'Online' }
                    [pscustomobject]@{ n = 2; bus = 'Fibre Channel'; gb = 50; ps = 'RAW'; sn = 'SERIAL-PERF'; uid = 'UID-PERF'; lun = 1; paths = 4; st = 'Online' })
            }
            err = [pscustomobject]@{}
        }
    }

    function Get-E2eInfra {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Fixture -Raw) -Ordered
        # declared 'iso': node 1 has a ZTP handoff (so it is Ztp, with a warning that the declaration disagrees), node 2 has only its Arc machine (Iso, over Arc)
        $doc.scenario.os_install = 'iso'
        $doc.hardware.sbe.bundle_path = ''
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        return $file
    }

    function Get-E2eHandoffDirectory {
        $dir = Join-Path $TestDrive "handoffs-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $null = New-Item -ItemType Directory -Path $dir
        $copy = Get-Content -LiteralPath $script:HandoffFixture -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
        $copy.nodes = @($copy.nodes | Where-Object { $_.name -eq 'iic-n01' })
        $copy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $dir 'iic-n01.ztp-handoff.json')
        return $dir
    }

    # The fake Azure. $global:AzlE2e: States (node -> Read state), Runs (run command name -> node, unknown), UnknownLeft (node -> run commands to lose), Calls.
    function global:Get-AzContext { [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'operator@example.com' }; Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' } } }
    function global:Start-Sleep { param([double]$Seconds, [int]$Milliseconds) $null = $Seconds, $Milliseconds }
    function global:Invoke-AzRestMethod {
        param([string]$Method, [string]$Path, [string]$Payload)
        $global:AzlE2e.Calls.Add("$Method $Path")
        $reply = { param($Body, [int]$Code = 200) [pscustomobject]@{ StatusCode = $Code; Content = ($Body | ConvertTo-Json -Depth 20 -Compress) } }
        $clean = $Path.Split('?')[0]
        if ($clean -match '/machines/(?<machine>[^/]+)/runCommands/(?<run>[^/]+)$') {
            $node = $Matches['machine']; $run = $Matches['run']
            switch ($Method) {
                'PUT' {
                    $lost = $global:AzlE2e.UnknownLeft.ContainsKey($node) -and $global:AzlE2e.UnknownLeft[$node] -gt 0
                    if ($lost) { $global:AzlE2e.UnknownLeft[$node]-- }
                    $script = [string](($Payload | ConvertFrom-Json -Depth 20).properties.source.script)
                    if ($script -match 'function Invoke-Action|shutdown\.exe') { throw 'The end-to-end Plan test must not run an apply or a restart on a node.' }
                    $global:AzlE2e.Runs[$run] = @{ Node = $node; Unknown = $lost; RemotingRead = ($script -match 'Get-ListenerState') }
                    return (& $reply @{ name = $run } 200)
                }
                'GET' {
                    $info = $global:AzlE2e.Runs[$run]
                    if ($info.Unknown) { return (& $reply @{ properties = @{ provisioningState = 'Succeeded'; instanceView = @{ executionState = 'Unknown' } } }) }
                    # The RemoteManagement step reads its own state with a script of its own: an empty one that knows the node's addresses (so the plan has changes, nothing is blocked).
                    $body = if ($info.RemotingRead) { [pscustomobject]@{ v = 1; host = $info.Node; addresses = @($global:AzlE2e.States[$info.Node].nics | ForEach-Object { $_.ips } | ForEach-Object { ($_ -split '/')[0] }) } } else { $global:AzlE2e.States[$info.Node] }
                    return (& $reply @{ properties = @{ provisioningState = 'Succeeded'; instanceView = @{ executionState = 'Succeeded'; exitCode = 0; output = (ConvertTo-ResultLine $body); error = '' } } })
                }
                'DELETE' { return (& $reply @{} 200) }
            }
        }
        if ($clean -match '/machines/(?<machine>[^/]+)$' -and $Method -eq 'GET') {
            $name = $Matches['machine']
            return (& $reply @{ name = $name; id = $clean; location = 'eastus'; properties = @{ status = 'Connected'; osProfile = @{ computerName = $name } } })
        }
        throw "The fake Azure has no answer for $Method $Path."
    }
}

AfterAll {
    foreach ($f in 'Get-AzContext', 'Start-Sleep', 'Invoke-AzRestMethod') { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
    Remove-Variable -Name AzlE2e -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-AzureLocalOsConfiguration.ps1, Plan, end to end (fake Azure only)' {
    BeforeAll {
        $infraFile = Get-E2eInfra
        $handoffDir = Get-E2eHandoffDirectory
        $infra = Import-AzlInfrastructure -Path $infraFile -SkipValidation
        $states = @{}
        foreach ($n in @($infra.nodes)) {
            $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $n
            $states[[string]$n['name']] = New-ConfiguredState $spec
        }
        # node 2 has the wrong DNS server, so its plan has a change
        $mgmt = @($states['iic-n02'].nics | Where-Object { @($_.dns).Count })[0]
        $mgmt.dns = @('198.51.100.53')
        $global:AzlE2e = @{ States = $states; Runs = @{}; UnknownLeft = @{ 'iic-n01' = 1 }; Calls = [System.Collections.Generic.List[string]]::new() }
        $out = Join-Path $TestDrive 'report'
        $script:Output = & $script:EntryScript -InfrastructureFile $infraFile -HandoffPath $handoffDir -Mode Plan -Transport ArcRunCommand -ReportDirectory $out -SkipValidation 6>&1 3>&1
        $script:ExitCode = $LASTEXITCODE
        $script:Out = $out
        $script:Events = @(Get-Content -LiteralPath (Join-Path $out 'os-configuration-events.jsonl') -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $script:Text = ($script:Output | ForEach-Object { "$_" }) -join "`n"
    }
    It 'exits 0 and the output has no "not recognized" error' {
        $script:ExitCode | Should -Be 0 -Because $script:Text
        $script:Text | Should -Not -Match 'is not recognized'
        $script:Text | Should -Not -Match 'BAD INPUT|FAILED:'
    }
    It 'went through the real transport: run commands were created, read and deleted, and nothing but reads were asked of the nodes' {
        @($global:AzlE2e.Calls | Where-Object { $_ -like 'PUT *runCommands*' }).Count | Should -BeGreaterThan 2
        @($global:AzlE2e.Calls | Where-Object { $_ -like 'DELETE *runCommands*' }).Count | Should -BeGreaterThan 2
    }
    It 'resolved one Ztp and one Iso node, side by side, with the method, transport and declaration in the events' {
        $m = @($script:Events | Where-Object { $_.state -eq 'MethodResolved' })
        $n1 = @($m | Where-Object node -eq 'iic-n01')[0]
        $n2 = @($m | Where-Object node -eq 'iic-n02')[0]
        $n1.method | Should -Be 'Ztp'
        $n1.mismatch | Should -BeTrue
        $n1.level | Should -Be 'Warning'
        $n2.method | Should -Be 'Iso'
        $n2.transport | Should -Be 'ArcRunCommand'
        $n2.declaredMethod | Should -Be 'Iso'
        $n2.mismatch | Should -BeFalse
        $n2.arc | Should -Be 'Connected'
        $n1.schemaVersion | Should -Be '5.3.0'
    }
    It 'has a step event for every one of the 14 steps (13 and the Arc registration) on every node' {
        foreach ($n in 'iic-n01', 'iic-n02') {
            $steps = @($script:Events | Where-Object { $_.node -eq $n -and $_.state -in 'StepPlanned', 'StepSkipped' } | ForEach-Object { $_.step } | Select-Object -Unique)
            $steps.Count | Should -Be 14 -Because "node $n : $($steps -join ',')"
        }
        $dns2 = $script:Events | Where-Object { $_.node -eq 'iic-n02' -and $_.step -eq 'Dns' }
        $dns2.state | Should -Be 'StepPlanned'
        $dns2.action | Should -Be 'Change'
        $dns2.current | Should -Match '198.51.100.53'
        ($script:Events | Where-Object { $_.node -eq 'iic-n01' -and $_.step -eq 'Dns' }).action | Should -Be 'Ok'
    }
    It 'verifies Hostname and Arc registration on the Ztp node and plans them as steps on the Iso node' {
        $h1 = $script:Events | Where-Object { $_.node -eq 'iic-n01' -and $_.step -eq 'Hostname' }
        $h1.verifyOnly | Should -BeTrue
        $h2 = $script:Events | Where-Object { $_.node -eq 'iic-n02' -and $_.step -eq 'Hostname' }
        $h2.state | Should -Be 'StepPlanned'
        $h2.PSObject.Properties.Name | Should -Not -Contain 'verifyOnly'
    }
    It 'the retry of the lost run command is in the feed with its try number (the path that once died)' {
        $r = @($script:Events | Where-Object { $_.state -eq 'NodeRetry' })
        $r.Count | Should -Be 1
        $r[0].node | Should -Be 'iic-n01'
        $r[0].try | Should -Be 1
        $r[0].level | Should -Be 'Warning'
    }
    It 'starts with RunStarted (the nodes), ends with RunCompleted (exit code 0), and has the plan events between' {
        $script:Events[0].state | Should -Be 'RunStarted'
        @($script:Events[0].nodes) | Should -Be @('iic-n01', 'iic-n02')
        $script:Events[-1].state | Should -Be 'RunCompleted'
        $script:Events[-1].exitCode | Should -Be 0
        $names = @($script:Events | ForEach-Object { $_.state })
        $names | Should -Contain 'PlanCompleted'
        $names | Should -Contain 'WipeListPublished'
        $names.IndexOf('PlanCompleted') | Should -BeLessThan $names.IndexOf('RunCompleted')
        # The fake nodes hold none of the RemoteManagement profile (rules, listeners), so neither node is converged in a plan: n01 has only those changes, n02 also its DNS server.
        (@($script:Events | Where-Object { $_.node -eq 'iic-n01' -and $_.state -eq 'NodeConverged' })).Count | Should -Be 0
        (@($script:Events | Where-Object { $_.node -eq 'iic-n02' -and $_.state -eq 'NodeConverged' })).Count | Should -Be 0
    }
    It 'wrote the report next to the events' {
        Test-Path (Join-Path $script:Out 'report.json') | Should -BeTrue
        Test-Path (Join-Path $script:Out 'plan-report.json') | Should -BeTrue
    }
}
