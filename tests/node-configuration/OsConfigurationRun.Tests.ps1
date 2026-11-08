#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the one-run OS configuration (Invoke-AzureLocalOsConfiguration.ps1 and AzlOsConfigurationRun.psm1). The OS configuration
# script, Azure and the nodes are all mocked: no network, no Azure, no node is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/OsConfigurationRun.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester runs a module mock in the module scope; a global is how the mock reports back to the test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Repo = $repo
    $common = Join-Path $repo 'scripts'
    $common = Join-Path $common 'common'
    $script:ModulePath = Join-Path (Join-Path $common 'node-configuration') 'AzlOsConfigurationRun.psm1'
    Import-Module $script:ModulePath -Force
    Import-Module powershell-yaml
    $script:Fixture = Join-Path (Join-Path $repo 'tests') (Join-Path 'fixtures' 'infrastructure.fc-san.yml')
    $script:HandoffFixture = Join-Path (Join-Path $repo 'tests') (Join-Path 'fixtures' 'handoff.v2.json')
    $script:EntryScript = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $repo 'scripts') 'deploy') '04-cluster-deployment') 'phase-03-os-configuration') 'Invoke-AzureLocalOsConfiguration.ps1'

    # A copy of the fixture with a change, in the test drive.
    function Get-TestInfra([scriptblock]$Change, [string]$Name = 'infra') {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Fixture -Raw) -Ordered
        if ($Change) { & $Change $doc }
        $file = Join-Path $TestDrive "$Name-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        return $file
    }

    # The fixture handoff split one node per file in a directory, optionally with the n02 file duplicated.
    function Get-TestHandoffDirectory([string[]]$Nodes = @('iic-n01', 'iic-n02'), [switch]$Duplicate, [scriptblock]$Change) {
        $dir = Join-Path $TestDrive "handoffs-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $null = New-Item -ItemType Directory -Path $dir
        $json = Get-Content -LiteralPath $script:HandoffFixture -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
        foreach ($n in $Nodes) {
            $copy = Get-Content -LiteralPath $script:HandoffFixture -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
            $copy.nodes = @($copy.nodes | Where-Object { $_.name -eq $n })
            if ($Change) { & $Change $copy }
            $copy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $dir "$n.ztp-handoff.json")
        }
        if ($Duplicate) { Copy-Item -LiteralPath (Join-Path $dir "$($Nodes[0]).ztp-handoff.json") -Destination (Join-Path $dir 'again.ztp-handoff.json') }
        'not a handoff' | Set-Content -LiteralPath (Join-Path $dir 'notes.txt')
        return $dir
    }

    # What the OS configuration script would report for one node, from the parameters it was called with.
    function global:New-FakeSetResult($Parameters) {
        $name = $Parameters.Node[0]
        $phase = if ($Parameters.ContainsKey('Execute')) { 'Apply' } else { 'Plan' }
        $global:AzlCalls.Add([pscustomobject]@{ Node = $name; Phase = $phase; Params = $Parameters })
        $global:AzlTrustedHostsDuring = $global:AzlTrustedHosts
        $failed = $global:AzlFail -contains $name
        if ($phase -eq 'Apply') {
            if ($failed) { return [pscustomobject]@{ ExitCode = 1; Error = 'boom'; Unknown = $false; Report = $null } }
            [void]$global:AzlApplied.Add($name)
        }
        $done = $global:AzlApplied.Contains($name) -or $global:AzlConverged -contains $name
        $plan = @()
        $plan += [pscustomobject]@{ step = 'Dns'; item = 'DNS servers'; current = 'x'; desired = 'y'; action = $(if ($done) { 'Ok' } else { 'Change' }); note = '' }
        if ($Parameters.ContainsKey('ClearStorage') -and 'ClearStorage' -in $Parameters.Step) {
            $plan += [pscustomobject]@{ step = 'ClearStorage'; item = 'local storage'; current = "1 pool(s), 2 virtual disk(s), disks: 3 (1000 GB) $name"; desired = 'clean'; action = $(if ($done) { 'Ok' } else { 'Change' }); note = 'DESTROYS the data on these local disks.' }
        }
        $hostName = if ($global:AzlHostname.ContainsKey($name)) { $global:AzlHostname[$name] } else { $name }
        $entry = [pscustomobject]@{
            name = $name; hostname = $hostName; osVersion = '10.0.26100.1'; converged = $done; restarted = $false; ports = @(); sanDisks = @([pscustomobject]@{ uid = 'UID1' })
            changes = @(if ($phase -eq 'Apply') { [pscustomobject]@{ Pass = 1; Id = 'Dns'; Status = 'changed'; Detail = 'set' } }); plan = $plan
        }
        [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Report = [pscustomobject]@{ nodes = @($entry) } }
    }

    function Clear-Fake {
        $global:AzlCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlApplied = [System.Collections.Generic.HashSet[string]]::new()
        $global:AzlFail = @()
        $global:AzlConverged = @()
        $global:AzlHostname = @{}
        $global:AzlPortAnswers = $true
        $global:AzlOpened = @()
        $global:AzlArcStatus = 'Connected'
        $global:AzlArcNone = @()
        $global:AzlRegistered = [System.Collections.Generic.List[string]]::new()
        $global:AzlTrustedHostsInitial = ''
        $global:AzlTrustedHostsDuring = $null
    }

    function Invoke-Run {
        param([string]$Infra, [string[]]$Handoff, [string]$Mode = 'Plan', [hashtable]$Extra = @{})
        $out = Join-Path $TestDrive "out-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        # A fake TrustedHosts store: a test never changes the setting of the machine it runs on.
        $global:AzlTrustedHosts = $global:AzlTrustedHostsInitial
        $store = [pscustomobject]@{ Supported = $true; Get = { $global:AzlTrustedHosts }; Set = { param($Value) $global:AzlTrustedHosts = $Value } }
        $arguments = @{ InfrastructureFile = $Infra; Mode = $Mode; ReportDirectory = $out; SkipValidation = $true; TrustedHostsStore = $store } + $Extra
        if ($Handoff) { $arguments.HandoffPath = $Handoff }
        $result = Invoke-AzlOsConfiguration @arguments 6>$null 3>$null
        $result | Add-Member -NotePropertyName Out -NotePropertyValue $out -Force
        return $result
    }
}

Describe 'OS configuration run' {
BeforeEach {
    Clear-Fake
    Mock -ModuleName AzlOsConfigurationRun Invoke-AzlSetNodeConfiguration { New-FakeSetResult $Parameters }
    Mock -ModuleName AzlOsConfigurationRun Test-AzlAzureSignedIn { $true }
    Mock -ModuleName AzlOsConfigurationRun Test-AzlWinRmPort { [bool]$global:AzlPortAnswers -or ($global:AzlOpened -contains $Address) }
    Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
        foreach ($c in $Candidate) { [pscustomobject]@{ Node = $c.Name; Reachable = ([bool]$global:AzlPortAnswers -or (@($c.Addresses) | Where-Object { $_ -in $global:AzlOpened })); Address = @($c.Addresses)[0]; Port = 5985; Result = $(if ($global:AzlPortAnswers -or (@($c.Addresses) | Where-Object { $_ -in $global:AzlOpened })) { 'Open' } else { 'TimedOut' }); Credential = 'vault'; Diagnosis = 'no answer'; Tried = @($c.Addresses) } }
    }
    Mock -ModuleName AzlOsConfigurationRun Get-AzlSecret { 'P@ssw0rd-from-the-vault-not-printed' }
    Mock -ModuleName AzlOsConfigurationRun Find-AzlArcMachine {
        if ($HostName -in $global:AzlArcNone) { return $null }
        [pscustomobject]@{ Name = $ArcMachineName; ResourceId = "/subscriptions/x/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ArcMachineName"; Location = 'eastus'; Status = $global:AzlArcStatus; Interfaces = @() }
    }
    Mock -ModuleName AzlOsConfigurationRun New-AzlWinRmTransport { [pscustomobject]@{ Kind = 'WinRM' } }
    Mock -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript { [pscustomobject]@{ caption = 'Microsoft Azure Stack HCI'; build = 26100; host = 'WIN-X' } }
    Mock -ModuleName AzlOsConfigurationRun Invoke-AzlArcRegistration {
        $global:AzlRegistered.Add($Record.name)
        [pscustomobject]@{ Name = $Record.name; Status = 'Connected'; ResourceId = '/x' }
    }
}

Describe 'Handoff merge' {
    It 'reads one file' {
        $m = Merge-AzlHandoff -Path $script:HandoffFixture
        $m.Files.Count | Should -Be 1
        @($m.Map.Keys | Sort-Object) | Should -Be @('iic-n01', 'iic-n02')
    }
    It 'reads a list of files and merges the nodes' {
        $dir = Get-TestHandoffDirectory
        $m = Merge-AzlHandoff -Path @((Join-Path $dir 'iic-n01.ztp-handoff.json'), (Join-Path $dir 'iic-n02.ztp-handoff.json'))
        $m.Files.Count | Should -Be 2
        @($m.Map.Keys | Sort-Object) | Should -Be @('iic-n01', 'iic-n02')
        $m.Map['iic-n02'].File | Should -BeLike '*iic-n02.ztp-handoff.json'
    }
    It 'reads a directory: every *.ztp-handoff.json and nothing else' {
        $dir = Get-TestHandoffDirectory
        $m = Merge-AzlHandoff -Path $dir
        $m.Files.Count | Should -Be 2
        $m.Files | ForEach-Object { $_ | Should -BeLike '*.ztp-handoff.json' }
    }
    It 'rejects a node that is in two files, naming both' {
        $dir = Get-TestHandoffDirectory -Duplicate
        $caught = $null
        try { Merge-AzlHandoff -Path $dir } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['AzlInput'] | Should -BeTrue
        $caught.Exception.Message | Should -Match "iic-n01.*two handoff files"
        $caught.Exception.Message | Should -Match 'again\.ztp-handoff\.json'
    }
    It 'rejects a path that does not exist and a directory with no handoff' {
        { Merge-AzlHandoff -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
        $empty = Join-Path $TestDrive 'empty-dir'
        $null = New-Item -ItemType Directory -Path $empty
        { Merge-AzlHandoff -Path $empty } | Should -Throw '*No *.ztp-handoff.json*'
    }
    It 'finds a node by name and returns $null for a node no file names' {
        $m = Merge-AzlHandoff -Path (Get-TestHandoffDirectory -Nodes @('iic-n01'))
        (Find-AzlMergedHandoff -Merged $m -Name 'iic-n01').File | Should -BeLike '*iic-n01.ztp-handoff.json'
        Find-AzlMergedHandoff -Merged $m -Name 'iic-n02' | Should -BeNullOrEmpty
        Find-AzlMergedHandoff -Merged $null -Name 'iic-n01' | Should -BeNullOrEmpty
    }
}

Describe 'Which method?' {
    BeforeAll {
        function Get-TestEvidence([hashtable]$With = @{}) {
            $base = @{ HandoffPresent = $false; HandoffReady = $false; HandoffNote = ''; HandoffFile = ''; HandoffContradiction = ''; ArcFound = $false; ArcStatus = ''; ArcResourceId = ''; ArcError = ''; WinRmAnswers = $null; WinRmAddress = ''; WinRmNote = ''; Addresses = @() }
            foreach ($k in $With.Keys) { $base[$k] = $With[$k] }
            [pscustomobject]$base
        }
    }
    It 'declared simplified with a ready handoff: the ZTP path over WinRM, no warning' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared simplified -Evidence (Get-TestEvidence @{ HandoffPresent = $true; HandoffReady = $true; ArcFound = $true; ArcStatus = 'Connected' })
        $r.Method | Should -Be 'Ztp'
        $r.Source | Should -Be 'declared'
        $r.Transport | Should -Be 'WinRM'
        $r.Warnings | Should -BeNullOrEmpty
        $r.Errors | Should -BeNullOrEmpty
    }
    It 'declared simplified with only a Connected Arc machine: the ZTP path' {
        (Resolve-AzlNodeMethod -Node n1 -Declared simplified -Evidence (Get-TestEvidence @{ ArcFound = $true; ArcStatus = 'Connected' })).Method | Should -Be 'Ztp'
    }
    It 'declared iso and no handoff, answering on WinRM: the ISO path over WinRM' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared iso -Evidence (Get-TestEvidence @{ WinRmAnswers = $true; WinRmAddress = '192.0.2.11' })
        $r.Method | Should -Be 'Iso'
        $r.Transport | Should -Be 'WinRM'
        $r.Warnings | Should -BeNullOrEmpty
    }
    It 'declared iso and already a Connected Arc machine: the ISO path, still reached over WinRM (Arc is never chosen automatically)' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared iso -Evidence (Get-TestEvidence @{ ArcFound = $true; ArcStatus = 'Connected' })
        $r.Method | Should -Be 'Iso'
        $r.Transport | Should -Be 'WinRM'
    }
    It 'declared iso but a ready handoff exists: the evidence wins, with a warning naming both' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared iso -Evidence (Get-TestEvidence @{ HandoffPresent = $true; HandoffReady = $true })
        $r.Method | Should -Be 'Ztp'
        $r.Source | Should -Be 'evidence'
        $r.Warnings.Count | Should -Be 1
        $r.Warnings[0] | Should -Match "'iso'"
        $r.Warnings[0] | Should -Match 'handoff'
    }
    It 'declared simplified but no handoff and no Arc, answering on WinRM: the ISO path, with a warning naming both' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared simplified -Evidence (Get-TestEvidence @{ WinRmAnswers = $true })
        $r.Method | Should -Be 'Iso'
        $r.Source | Should -Be 'evidence'
        $r.Warnings[0] | Should -Match "'simplified'"
        $r.Warnings[0] | Should -Match 'WinRM'
    }
    It 'declared simplified, no evidence, nothing reachable: an error (exit 2 in the run)' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared simplified -Evidence (Get-TestEvidence @{ WinRmAnswers = $false; WinRmNote = 'no answer on TCP 5985 at 192.0.2.11' })
        $r.Method | Should -BeNullOrEmpty
        $r.Errors.Count | Should -Be 1
        $r.Errors[0] | Should -Match 'nothing reachable'
        $r.Errors[0] | Should -Match '192.0.2.11'
    }
    It 'declared iso, no Arc and nothing answering: an error that says what to do' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared iso -Evidence (Get-TestEvidence @{ WinRmAnswers = $false; WinRmNote = 'no answer' })
        $r.Errors.Count | Should -Be 1
        $r.Errors[0] | Should -Match 'WinRM'
    }
    It 'a handoff that is not ready does not count as ZTP evidence' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared simplified -Evidence (Get-TestEvidence @{ HandoffPresent = $true; HandoffReady = $false; HandoffNote = 'ready is false' })
        $r.Method | Should -BeNullOrEmpty
        $r.Errors[0] | Should -Match 'ready is false'
    }
    It 'contradictory evidence (the handoff is for another resource group) is an error even with a forced method' {
        foreach ($force in 'Auto', 'Ztp', 'Iso') {
            $r = Resolve-AzlNodeMethod -Node n1 -Declared simplified -Force $force -Evidence (Get-TestEvidence @{ HandoffPresent = $true; HandoffReady = $true; HandoffContradiction = 'the handoff is for resource group other' })
            $r.Method | Should -BeNullOrEmpty
            $r.Errors[0] | Should -Match 'Contradictory'
        }
    }
    It '-Method Iso is taken as given; -Method Ztp needs a handoff or an Arc machine' {
        $iso = Resolve-AzlNodeMethod -Node n1 -Declared simplified -Force Iso -Evidence (Get-TestEvidence @{ HandoffPresent = $true; HandoffReady = $true })
        $iso.Method | Should -Be 'Iso'
        $iso.Source | Should -Be 'forced'
        (Resolve-AzlNodeMethod -Node n1 -Declared iso -Force Ztp -Evidence (Get-TestEvidence @{ ArcFound = $true; ArcStatus = 'Connected' })).Method | Should -Be 'Ztp'
        $none = Resolve-AzlNodeMethod -Node n1 -Declared iso -Force Ztp -Evidence (Get-TestEvidence)
        $none.Errors[0] | Should -Match 'Method Ztp'
    }
    It 'gives the ZTP path without Hostname and Arc registration, the ISO path with both' {
        (Get-AzlNodeStepList -Method Ztp) | Should -Not -Contain 'Hostname'
        (Get-AzlNodeStepList -Method Ztp) | Should -Not -Contain 'ArcRegistration'
        (Get-AzlNodeStepList -Method Ztp) | Should -Contain 'ClearStorage'
        (Get-AzlNodeStepList -Method Iso) | Should -Contain 'Hostname'
        (Get-AzlNodeStepList -Method Iso) | Should -Contain 'ArcRegistration'
        (Get-AzlNodeStepList -Method Iso) | Should -Contain 'Network'
        (Get-AzlNodeStepList -Method Iso -Step Hostname, Dns) | Should -Be @('Dns', 'Hostname')
        (Get-AzlNodeStepList -Method Ztp -Step Hostname) | Should -BeNullOrEmpty
    }
}

Describe 'The run: order of operations' {
    It 'Plan mode: plans every node, applies nothing, writes the plan report, exits 0 with changes pending' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        @($global:AzlCalls | ForEach-Object { "$($_.Node)/$($_.Phase)" }) | Should -Be @('iic-n01/Plan', 'iic-n02/Plan')
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $r.Out 'plan-report.json') | Should -BeTrue
        Test-Path (Join-Path $r.Out 'report.json') | Should -BeTrue
        Test-Path (Join-Path $r.Out 'summary.md') | Should -BeTrue
        @($r.Records | Where-Object { $_.pendingChanges -gt 0 }).Count | Should -Be 2
    }
    It 'Apply mode: plan for ALL nodes, then apply node by node, then a verification plan per node' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply
        @($global:AzlCalls | ForEach-Object { "$($_.Node)/$($_.Phase)" }) | Should -Be @('iic-n01/Plan', 'iic-n02/Plan', 'iic-n01/Apply', 'iic-n02/Apply', 'iic-n01/Plan', 'iic-n02/Plan')
        $r.ExitCode | Should -Be 0
        @($r.Records | Where-Object converged).Count | Should -Be 2
        $report = Get-Content -LiteralPath (Join-Path $r.Out 'report.json') -Raw | ConvertFrom-Json
        $report.nodes[0].converged | Should -BeTrue
        $report.nodes[0].changes.Count | Should -BeGreaterThan 0
    }
    It 'Apply mode: a node with nothing to change is not applied and counts as converged' {
        $global:AzlConverged = @('iic-n01')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply
        @($global:AzlCalls | Where-Object { $_.Phase -eq 'Apply' } | ForEach-Object Node) | Should -Be @('iic-n02')
        $r.ExitCode | Should -Be 0
    }
    It 'the step list follows the method: the ZTP nodes skip Hostname' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        foreach ($c in $global:AzlCalls) {
            $c.Params.Step | Should -Not -Contain 'Hostname'
            $c.Params.Transport | Should -Be 'WinRM'
            $c.Params.HandoffFile | Should -BeLike '*.ztp-handoff.json'
        }
    }
    It '-Node limits the run, and an unknown node is bad input (exit 2)' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Node = @('iic-n02') }
        @($global:AzlCalls | ForEach-Object Node | Select-Object -Unique) | Should -Be @('iic-n02')
        (Invoke-Run -Infra $infra -Extra @{ Node = @('iic-n09') }).ExitCode | Should -Be 2
    }
    It '-Step limits the steps' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Step = @('Dns', 'Time', 'Hostname') }
        $global:AzlCalls[0].Params.Step | Should -Be @('Dns', 'Time') -Because 'Hostname is not a ZTP-path step'
    }
}

Describe 'The run: failures' {
    It 'a failed node does not stop the others, is recorded, and the exit code is 1' {
        $global:AzlFail = @('iic-n01')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply
        @($global:AzlApplied) | Should -Be @('iic-n02')
        $n1 = $r.Records | Where-Object { $_.name -eq 'iic-n01' }
        $n1.converged | Should -BeFalse
        ($n1.errors -join ' ') | Should -Match 'boom'
        ($r.Records | Where-Object { $_.name -eq 'iic-n02' }).converged | Should -BeTrue
        $r.ExitCode | Should -Be 1
        $report = Get-Content -LiteralPath (Join-Path $r.Out 'report.json') -Raw | ConvertFrom-Json
        $report.exitCode | Should -Be 1
        $report.nodes[0].errors.Count | Should -BeGreaterThan 0
    }
    It '-ContinueOnNodeFailure:$false stops at the first failed node and skips the rest' {
        $global:AzlFail = @('iic-n01')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply -Extra @{ ContinueOnNodeFailure = $false }
        @($global:AzlApplied).Count | Should -Be 0
        ($r.Records | Where-Object { $_.name -eq 'iic-n02' }).status | Should -Be 'skipped'
        $r.ExitCode | Should -Be 1
    }
    It 'a ZTP node whose computer name differs is not renamed; the verification fails it' {
        $global:AzlHostname = @{ 'iic-n01' = 'WIN-WRONG' }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        ($r.Records[0].errors -join ' ') | Should -Match 'computer name'
        $r.ExitCode | Should -Be 1
    }
    It 'a node that cannot be read in the plan fails and the exit code is 1; the other node is still planned' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlSetNodeConfiguration {
            if ($Parameters.Node[0] -eq 'iic-n01') { return [pscustomobject]@{ ExitCode = 1; Error = 'no Arc machine'; Unknown = $false; Report = $null } }
            New-FakeSetResult $Parameters
        }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        $r.ExitCode | Should -Be 1
        $r.Records[0].status | Should -Be 'failed'
        $r.Records[1].status | Should -Be 'planned'
    }
}

Describe 'Exit codes' {
    BeforeAll {
        function Get-TestRec($Status = 'planned', $Errors = @(), $Converged = $true, $Blocked = 0, $Pending = 0) { [pscustomobject]@{ status = $Status; errors = $Errors; converged = $Converged; blocked = $Blocked; pendingChanges = $Pending } }
    }
    It '0 when every node converged' { Get-AzlOsConfigurationExitCode -Record @((Get-TestRec), (Get-TestRec)) -Mode Apply | Should -Be 0 }
    It '1 when a node did not converge in Apply' { Get-AzlOsConfigurationExitCode -Record @((Get-TestRec), (Get-TestRec -Converged $false -Pending 1)) -Mode Apply | Should -Be 1 }
    It '1 when a node failed or was skipped' {
        Get-AzlOsConfigurationExitCode -Record @((Get-TestRec -Status failed -Converged $false)) -Mode Plan | Should -Be 1
        Get-AzlOsConfigurationExitCode -Record @((Get-TestRec -Status skipped -Converged $false)) -Mode Plan | Should -Be 1
    }
    It '1 when a node is blocked, in Plan too' { Get-AzlOsConfigurationExitCode -Record @((Get-TestRec -Blocked 1 -Converged $false)) -Mode Plan | Should -Be 1 }
    It 'Plan: pending changes are expected (0), unless -FailOnPendingChanges' {
        Get-AzlOsConfigurationExitCode -Record @((Get-TestRec -Converged $false -Pending 2)) -Mode Plan | Should -Be 0
        Get-AzlOsConfigurationExitCode -Record @((Get-TestRec -Converged $false -Pending 2)) -Mode Plan -FailOnPendingChanges | Should -Be 1
    }
    It '1 for a cluster problem (the nodes do not see the same SAN disks); 2 for bad input' {
        Get-AzlOsConfigurationExitCode -Record @((Get-TestRec)) -ClusterProblem @('SAN differs') | Should -Be 1
        Get-AzlOsConfigurationExitCode -Record @() -InputError | Should -Be 2
    }
    It 'the entry script exits 2 on bad input (missing infrastructure file) without touching anything' {
        $out = Join-Path $TestDrive 'exit2'
        $null = & pwsh -NoProfile -File $script:EntryScript -InfrastructureFile (Join-Path $TestDrive 'missing.yml') -ReportDirectory $out 2>&1
        $LASTEXITCODE | Should -Be 2
    }
    It 'the entry script exits 2 for duplicate handoffs' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $dir = Get-TestHandoffDirectory -Duplicate
        $null = & pwsh -NoProfile -File $script:EntryScript -InfrastructureFile $infra -HandoffPath $dir -SkipValidation -ReportDirectory (Join-Path $TestDrive 'exit2b') 2>&1
        $LASTEXITCODE | Should -Be 2
    }
}

Describe 'Bad input stops the run before anything is planned' {
    It 'duplicate handoffs: exit 2, no node called' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory -Duplicate)
        $r.ExitCode | Should -Be 2
        $global:AzlCalls.Count | Should -Be 0
    }
    It 'contradictory evidence (handoff for another resource group): exit 2' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory -Change { param($h) $h.resourceGroup = 'rg-other' })
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'Contradictory'
        $global:AzlCalls.Count | Should -Be 0
    }
    It 'declared simplified, no handoff, no Arc machine, nothing answering: exit 2 with the reason' {
        $global:AzlArcNone = @('iic-n01', 'iic-n02'); $global:AzlPortAnswers = $false
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'nothing reachable'
        $global:AzlCalls.Count | Should -Be 0
    }
    It 'an Arc node (explicit -Transport ArcRunCommand) without an Azure sign-in: exit 2' {
        Mock -ModuleName AzlOsConfigurationRun Test-AzlAzureSignedIn { $false }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Transport = 'ArcRunCommand' }
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'sign-in'
    }
    It 'an unknown run setting is bad input' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        (Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Settings = @{ retries = 5 } }).ExitCode | Should -Be 2
    }
}

Describe 'Mixed cluster and the ISO path' {
    BeforeEach {
        # n01 came from ZTP (handoff, Arc connected); n02 was installed from an ISO: no handoff, no Arc machine yet, answers on WinRM.
        $global:AzlArcNone = @('iic-n02')
        $script:MixedInfra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.nodes[1].maintenance_address = '192.0.2.112' }
        $script:MixedHandoff = Get-TestHandoffDirectory -Nodes @('iic-n01')
    }
    It 'resolves each node on its own and records method and evidence in the report' {
        $r = Invoke-Run -Infra $script:MixedInfra -Handoff $script:MixedHandoff
        $r.ExitCode | Should -Be 0
        $n1 = $r.Records | Where-Object { $_.name -eq 'iic-n01' }
        $n2 = $r.Records | Where-Object { $_.name -eq 'iic-n02' }
        $n1.method | Should -Be 'Ztp'
        $n2.method | Should -Be 'Iso'
        $n2.methodSource | Should -Be 'evidence'
        $n2.transport | Should -Be 'WinRM'
        $n2.methodWarnings.Count | Should -Be 1
        $report = Get-Content -LiteralPath (Join-Path $r.Out 'report.json') -Raw | ConvertFrom-Json
        $report.nodes[0].method.resolved | Should -Be 'Ztp'
        $report.nodes[0].evidence.handoff.ready | Should -BeTrue
        $report.nodes[0].evidence.arc.status | Should -Be 'Connected'
        $report.nodes[1].method.resolved | Should -Be 'Iso'
        $report.nodes[1].method.declared | Should -Be 'simplified'
        $report.nodes[1].evidence.winrm.answers | Should -BeTrue
        $report.nodes[1].evidence.handoff.present | Should -BeFalse
    }
    It 'the ISO node gets the ISO steps (Hostname, Arc registration) over WinRM with the vault credential, never in a report' {
        $r = Invoke-Run -Infra $script:MixedInfra -Handoff $script:MixedHandoff
        $call = $global:AzlCalls | Where-Object Node -eq 'iic-n02' | Select-Object -First 1
        $call.Params.Transport | Should -Be 'WinRM'
        $call.Params.Step | Should -Contain 'Hostname'
        $call.Params.Credential | Should -BeOfType [pscredential]
        $call.Params.Credential.UserName | Should -Be 'azl-admin'
        $call.Params.NodeAddress['iic-n02'] | Should -Not -BeNullOrEmpty
        ($r.Records | Where-Object { $_.name -eq 'iic-n02' }).steps | Should -Contain 'ArcRegistration'
        $text = (Get-Content -LiteralPath (Join-Path $r.Out 'report.json') -Raw) + (Get-Content -LiteralPath (Join-Path $r.Out 'summary.md') -Raw)
        $text | Should -Not -Match 'P@ssw0rd'
    }
    It 'plans the Arc registration of the ISO node and registers it only in Apply, once' {
        $plan = Invoke-Run -Infra $script:MixedInfra -Handoff $script:MixedHandoff
        $item = ($plan.Records | Where-Object { $_.name -eq 'iic-n02' }).plan | Where-Object Step -eq 'ArcRegistration'
        $item.Action | Should -Be 'Change'
        $global:AzlRegistered.Count | Should -Be 0
        $null = Invoke-Run -Infra $script:MixedInfra -Handoff $script:MixedHandoff -Mode Apply
        @($global:AzlRegistered) | Should -Be @('iic-n02')
    }
    It 'an ISO node that is already a Connected Arc machine needs no registration' {
        $global:AzlArcNone = @()
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra
        foreach ($rec in $r.Records) {
            $rec.method | Should -Be 'Iso'
            $rec.transport | Should -Be 'WinRM'
            ($rec.plan | Where-Object Step -eq 'ArcRegistration').Action | Should -Be 'Ok'
        }
    }
    It 'a precondition failure on the ISO path (wrong OS build) is exit 2 with the node named' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript { [pscustomobject]@{ caption = 'Windows Server 2016'; build = 14393; host = 'X' } }
        $r = Invoke-Run -Infra $script:MixedInfra -Handoff $script:MixedHandoff
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'iic-n02'
        $r.Message | Should -Match '25398'
        $global:AzlCalls.Count | Should -Be 0
    }
    It 'a refused credential is reported as a credential problem' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript { throw 'Access is denied.' }
        $r = Invoke-Run -Infra $script:MixedInfra -Handoff $script:MixedHandoff
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'refused'
        $r.Message | Should -Not -Match 'P@ssw0rd'
    }
    It 'no route to the node is reported with the address' {
        $global:AzlPortAnswers = $true
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso'; $d.scenario.environment_class = 'lab' }
        $global:AzlArcNone = @('iic-n01', 'iic-n02')
        $calls = 0
        Mock -ModuleName AzlOsConfigurationRun Test-AzlWinRmPort { $global:AzlPortCalls++; $global:AzlPortCalls -le 2 }
        $global:AzlPortCalls = 0
        $r = Invoke-Run -Infra $infra
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match '5985'
    }
    It 'forcing -Method Iso on a ZTP cluster uses the ISO steps' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Method = 'Iso' }
        ($r.Records | ForEach-Object method | Select-Object -Unique) | Should -Be 'Iso'
        $r.Records[0].methodSource | Should -Be 'forced'
    }
}

Describe 'Storage wipe (os_configuration.clear_storage)' {
    It 'is off by default: no ClearStorage switch reaches the script and the list says nothing is wiped' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply
        foreach ($c in $global:AzlCalls) { $c.Params.ContainsKey('ClearStorage') | Should -BeFalse }
        Get-Content -LiteralPath (Join-Path $r.Out 'wipe-list.txt') -Raw | Should -Match 'Storage wipe: off'
    }
    It 'the key in the master file turns it on for every call and the plan lists the disks per node' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.os_configuration = [ordered]@{ clear_storage = $true } }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        foreach ($c in $global:AzlCalls) { $c.Params.ClearStorage | Should -BeTrue }
        $text = Get-Content -LiteralPath (Join-Path $r.Out 'wipe-list.txt') -Raw
        $text | Should -Match 'WOULD BE WIPED'
        $text | Should -Match 'iic-n01: .*3 \(1000 GB\) iic-n01'
        $text | Should -Match 'iic-n02: .*3 \(1000 GB\) iic-n02'
        $text | Should -Match 'os_configuration.clear_storage in the master file'
        @($r.WipeList).Count | Should -Be 2
        $report = Get-Content -LiteralPath (Join-Path $r.Out 'report.json') -Raw | ConvertFrom-Json
        $report.clearStorage.enabled | Should -BeTrue
        $report.wipeList.Count | Should -Be 2
        (Get-Content -LiteralPath (Join-Path $r.Out 'summary.md') -Raw) | Should -Match 'iic-n01'
    }
    It 'in Apply mode the wipe list is printed before anything is applied, and is the list from the plan' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.os_configuration = [ordered]@{ clear_storage = $true } }
        $lines = [System.Collections.Generic.List[string]]::new()
        $out = Join-Path $TestDrive 'applyout'
        $info = Invoke-AzlOsConfiguration -InfrastructureFile $infra -HandoffPath (Get-TestHandoffDirectory) -Mode Apply -ReportDirectory $out -SkipValidation 6>&1 3>$null
        $text = @($info | ForEach-Object { [string]$_ })
        $wipeAt = ($text | Select-String -Pattern 'WILL BE WIPED NOW').LineNumber | Select-Object -First 1
        $applyAt = ($text | Select-String -Pattern '== Apply').LineNumber | Select-Object -First 1
        $wipeAt | Should -Not -BeNullOrEmpty
        $wipeAt | Should -BeLessThan $applyAt
    }
    It '-ClearStorage forces it on although the file says nothing' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ ClearStorage = $true }
        $global:AzlCalls[0].Params.ClearStorage | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $r.Out 'wipe-list.txt') -Raw) | Should -Match '-ClearStorage switch'
    }
    It 'a node with nothing to wipe is not on the list' {
        $global:AzlConverged = @('iic-n01')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.os_configuration = [ordered]@{ clear_storage = $true } }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        @($r.WipeList | ForEach-Object Node) | Should -Be @('iic-n02')
    }
}

Describe 'Run settings' {
    It 'reads a JSON file and lets -Settings win' {
        $file = Join-Path $TestDrive 'settings.json'
        '{ "retryTries": 5, "maxPasses": 2 }' | Set-Content -LiteralPath $file
        $s = Get-AzlRunSetting -ConfigPath $file -Settings @{ retryTries = 4 }
        $s.retryTries | Should -Be 4
        $s.maxPasses | Should -Be 2
    }
    It 'passes the retry policy and the pass limit on to the script' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Settings = @{ retryTries = 5; retryDelaySeconds = @(1, 2); maxPasses = 4 } }
        $global:AzlCalls[0].Params.RetryTries | Should -Be 5
        $global:AzlCalls[0].Params.RetryDelaySeconds | Should -Be @(1, 2)
        $global:AzlCalls[0].Params.MaxPasses | Should -Be 4
    }
}

Describe 'Summary' {
    It 'is a table with one row per node, and markdown for a job summary' {
        $recs = @(
            [pscustomobject]@{ name = 'n1'; method = 'Ztp'; methodSource = 'declared'; transport = 'ArcRunCommand'; changes = @(); pendingChanges = 0; blocked = 0; status = 'planned'; converged = $true; restarted = $false; errors = @() }
            [pscustomobject]@{ name = 'n2'; method = 'Iso'; methodSource = 'evidence'; transport = 'WinRM'; changes = @(); pendingChanges = 3; blocked = 0; status = 'planned'; converged = $false; restarted = $false; errors = @() }
        )
        $text = Format-AzlOsConfigurationSummary -Record $recs -Mode Plan -ExitCode 0
        $text | Should -Match 'n1'
        $text | Should -Match 'Iso \(evidence\)'
        $text | Should -Match 'Exit code: 0'
        (Format-AzlOsConfigurationSummary -Record $recs -Mode Plan -Markdown) | Should -Match '\| n2 \| Iso \(evidence\) \| WinRM \|'
    }
}

Describe 'Integration with the SBE delivery routes and the node script' {
    It 'every parameter the run passes to Set-AzureLocalNodeConfiguration.ps1 is one the script has' {
        $setScript = Join-Path (Split-Path $script:EntryScript -Parent) 'Set-AzureLocalNodeConfiguration.ps1'
        $known = @((Get-Command $setScript).Parameters.Keys)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ModulePath, [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-AzlNodeRun' }, $true)
        $passed = @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Expression.Extent.Text -eq '$parameters' }, $true) | ForEach-Object { $_.Member.Value })
        $passed += @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and $n.Extent.Text -match 'InfrastructureFile\s*=' }, $true) | Select-Object -First 1 | ForEach-Object { $_.KeyValuePairs | ForEach-Object { $_.Item1.Value } })
        $passed.Count | Should -BeGreaterThan 8
        foreach ($name in $passed) { $known | Should -Contain $name -Because "the run passes -$name" }
    }
    It 'the step list of the run is the step list of the node script, Sbe last' {
        $setScript = Join-Path (Split-Path $script:EntryScript -Parent) 'Set-AzureLocalNodeConfiguration.ps1'
        $validSet = @((Get-Command $setScript).Parameters.Step.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues })
        $moduleOrder = @(InModuleScope AzlNodeConfiguration { $script:AllSteps })
        $moduleOrder[-1] | Should -Be 'Sbe'
        (Get-AzlNodeStepList -Method Ztp)[-1] | Should -Be 'Sbe'
        (Get-AzlNodeStepList -Method Iso -Step Sbe, Dns, ArcRegistration, Hostname) | Should -Be @('Dns', 'Hostname', 'Sbe', 'ArcRegistration')
        @(Get-AzlNodeStepList -Method Iso | Where-Object { $_ -ne 'ArcRegistration' }) | Should -Be $moduleOrder
        @($validSet | Sort-Object) | Should -Be @($moduleOrder | Sort-Object)
        $entry = Get-Command $script:EntryScript
        @($entry.Parameters.Step.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues } | Sort-Object) | Should -Be @(($moduleOrder + 'ArcRegistration') | Sort-Object)
    }
    It 'winrm_copy on a ZTP node reached over Arc (explicit -Transport ArcRunCommand): the run hands the script the local administrator for the copy, the other steps stay on Arc' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.hardware.sbe.delivery = 'winrm_copy' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Transport = 'ArcRunCommand' }
        $call = $global:AzlCalls[0]
        $call.Params.Transport | Should -Be 'ArcRunCommand'
        $call.Params.Credential | Should -Not -BeNullOrEmpty
        $call.Params.Credential.UserName | Should -Not -BeNullOrEmpty
        'Sbe' | Should -BeIn $call.Params.Step
    }
    It 'a plan that says the SBE package is NOT DELIVERED (skip) puts one warning in the node record and does not fail the node' {
        $warnings = InModuleScope AzlOsConfigurationRun {
            $record = [ordered]@{ name = 'n1'; phases = [ordered]@{}; plan = @(); errors = @(); warnings = @(); ports = @(); sanDisks = @(); hostname = ''; osVersion = '' }
            $entry = [pscustomobject]@{ plan = @([pscustomobject]@{ step = 'Sbe'; item = 'C:\SBE\x.zip'; current = 'absent'; desired = 'present'; action = 'Info'; note = 'NOT DELIVERED: hardware.sbe.delivery is skip' }); ports = @(); sanDisks = @(); hostname = 'n1'; osVersion = '10.0' }
            $run = [pscustomobject]@{ ExitCode = 0; Error = ''; Skipped = $false; Entry = $entry }
            $ok = Merge-AzlRunResult -Record $record -Run $run -Phase Plan
            [pscustomobject]@{ Ok = $ok; Warnings = @($record.warnings); Errors = @($record.errors) }
        }
        $warnings.Ok | Should -BeTrue
        $warnings.Errors | Should -BeNullOrEmpty
        $warnings.Warnings.Count | Should -Be 1
        $warnings.Warnings[0] | Should -Match 'NOT DELIVERED'
    }
    It '<_> on a ZTP node reached over Arc (explicit) needs no credential' -ForEach 'skip', 'node_pull' {
        $route = $_
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.hardware.sbe.delivery = $route; $d.hardware.sbe.node_pull_url = 'https://files.example.invalid/sbe' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Transport = 'ArcRunCommand' }
        $global:AzlCalls[0].Params.ContainsKey('Credential') | Should -BeFalse
    }
    It 'the default transport is WinRM on a ZTP node as well, never a silent Arc fallback (Resolve-AzlNodeMethod, the run, the script call)' {
        $r = Resolve-AzlNodeMethod -Node 'n1' -Declared 'simplified' -Evidence ([pscustomobject]@{ HandoffPresent = $true; HandoffReady = $true; HandoffNote = ''; HandoffContradiction = ''; ArcFound = $true; ArcStatus = 'Connected'; ArcError = ''; WinRmAnswers = $false; WinRmNote = '' })
        $r.Method | Should -Be 'Ztp'
        $r.Transport | Should -Be 'WinRM'
        $global:AzlPortAnswers = $true
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.hardware.sbe.delivery = 'winrm_copy' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        $call = $global:AzlCalls[0]
        $call.Params.Transport | Should -Be 'WinRM'
        $call.Params.Credential | Should -Not -BeNullOrEmpty
        'Sbe' | Should -BeIn $call.Params.Step
    }
    It 'a ZTP node whose remoting port does not answer fails before anything is changed; Arc is not tried instead' {
        $global:AzlPortAnswers = $false
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply
        $r.ExitCode | Should -Be 2
        @($global:AzlCalls).Count | Should -Be 0
    }
}

Describe 'Event feed (os-configuration-events.jsonl)' {
    BeforeAll {
        function Read-RunEvent([string]$Path) { @(Get-Content -LiteralPath $Path -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
        function Get-NodeState($Events, [string]$Node) { @($Events | Where-Object { $_.node -eq $Node } | ForEach-Object { $_.state }) }
    }
    It 'Plan, two ZTP nodes: RunStarted with the nodes array first, per node NodeStarted then MethodResolved, the plan, PlanCompleted, WipeListPublished, RunCompleted last' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Transport = 'ArcRunCommand' }
        $file = Join-Path $r.Out 'os-configuration-events.jsonl'
        Test-Path -LiteralPath $file | Should -BeTrue
        $raw = Get-Content -LiteralPath $file -Encoding utf8
        $e = Read-RunEvent $file
        $e[0].state | Should -Be 'RunStarted'
        $e[0].node | Should -Be '*'
        @($e[0].nodes) | Should -Be @('iic-n01', 'iic-n02')
        $e[0].evidence | Should -Match 'iic-n01, iic-n02'
        $e[0].mode | Should -Be 'Plan'
        $e[0].wrapperVersion | Should -Not -BeNullOrEmpty
        $e[0].schemaVersion | Should -Not -BeNullOrEmpty
        $e[-1].state | Should -Be 'RunCompleted'
        $e[-1].exitCode | Should -Be 0
        $e[-1].total | Should -Be 2
        $names = @($e | ForEach-Object { $_.state })
        $names.IndexOf('PlanCompleted') | Should -BeLessThan $names.IndexOf('WipeListPublished')
        $names.IndexOf('WipeListPublished') | Should -BeLessThan $names.IndexOf('RunCompleted')
        (Get-NodeState $e 'iic-n01')[0..2] | Should -Be @('NodeStarted', 'MethodResolved', 'TransportResolved')
        $e[0].payloadVersion | Should -Be '1'
        $e[0].schemaVersion | Should -Be '5.3.0'
        ($e | Where-Object { $_.node -eq 'iic-n01' -and $_.state -eq 'TransportResolved' }).transport | Should -Be 'ArcRunCommand'
        foreach ($line in $raw) { $line | Should -Match '"timestamp":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z"' }
        foreach ($x in $e) { $x.stage | Should -Be 'OsConfiguration'; $x.level | Should -BeIn @('Info', 'Warning', 'Error') }
        [IO.File]::ReadAllBytes($file)[0] | Should -Not -Be 0xEF
        # every step is accounted for on every node: planned, or skipped with its reason
        foreach ($n in 'iic-n01', 'iic-n02') {
            $steps = @($e | Where-Object { $_.node -eq $n -and $_.state -in 'StepPlanned', 'StepSkipped' } | ForEach-Object { $_.step } | Select-Object -Unique)
            $steps.Count | Should -Be 14
        }
    }
    It 'MethodResolved carries the method, the declaration, the evidence and the versions; a ZTP node verifies Hostname and Arc registration instead of changing them' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Transport = 'ArcRunCommand' }
        $e = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $m = @($e | Where-Object { $_.node -eq 'iic-n01' -and $_.state -eq 'MethodResolved' })
        $m.Count | Should -Be 2 -Because 'once when the method is decided, once after the first read adds the OS'
        $m[0].method | Should -Be 'Ztp'
        $m[0].transport | Should -Be 'ArcRunCommand'
        $m[0].declared | Should -Be 'simplified'
        $m[0].declaredMethod | Should -Be 'Ztp'
        $m[0].mismatch | Should -BeFalse
        $m[0].handoff | Should -Be 'ready'
        $m[0].arc | Should -Be 'Connected'
        $m[0].sbePublisher | Should -Be 'Dell'
        $m[0].sbeDelivery | Should -Be 'skip' -Because 'the fixture names no hardware.sbe.delivery, so the package is not delivered'
        $m[0].PSObject.Properties.Name | Should -Not -Contain 'osVersion'
        $m[1].osVersion | Should -Be '10.0.26100.1'
        $m[1].build | Should -Be 26100
        $m[1].hostname | Should -Be 'iic-n01'
        $host1 = $e | Where-Object { $_.node -eq 'iic-n01' -and $_.step -eq 'Hostname' }
        $host1.state | Should -Be 'StepPlanned'
        $host1.verifyOnly | Should -BeTrue
        $host1.action | Should -Be 'Ok'
        $arc1 = $e | Where-Object { $_.node -eq 'iic-n01' -and $_.step -eq 'ArcRegistration' }
        $arc1.verifyOnly | Should -BeTrue
        $dns = $e | Where-Object { $_.node -eq 'iic-n01' -and $_.step -eq 'Dns' }
        $dns.state | Should -Be 'StepPlanned'
        $dns.action | Should -Be 'Change'
        $dns.current | Should -Be 'x'
        $dns.desired | Should -Be 'y'
        $dns.evidence | Should -Match 'x -> y'
    }
    It 'a mixed cluster: the ISO node says Iso over WinRM, warns that the declaration disagrees, plans a real Arc registration' {
        $global:AzlArcNone = @('iic-n02')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.nodes[1].maintenance_address = '192.0.2.112'; $d.hardware.sbe.delivery = 'winrm_copy' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory -Nodes @('iic-n01'))
        $e = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $m1 = @($e | Where-Object { $_.node -eq 'iic-n01' -and $_.state -eq 'MethodResolved' })[0]
        $m2 = @($e | Where-Object { $_.node -eq 'iic-n02' -and $_.state -eq 'MethodResolved' })[-1]
        $m1.method | Should -Be 'Ztp'
        $m2.method | Should -Be 'Iso'
        $m2.transport | Should -Be 'WinRM'
        $m2.mismatch | Should -BeTrue
        $m2.declaredMethod | Should -Be 'Ztp'
        $m2.level | Should -Be 'Warning'
        @($e | Where-Object { $_.node -eq 'iic-n02' -and $_.state -eq 'MethodResolved' })[0].evidence | Should -Match 'declared'
        @($m2.warnings).Count | Should -Be 1
        $m2.osCaption | Should -Be 'Microsoft Azure Stack HCI'
        $m2.build | Should -Be 26100
        $m2.sbeDelivery | Should -Be 'winrm_copy'
        $arc2 = $e | Where-Object { $_.node -eq 'iic-n02' -and $_.step -eq 'ArcRegistration' }
        $arc2.action | Should -Be 'Change'
        $arc2.PSObject.Properties.Name | Should -Not -Contain 'verifyOnly'
        $host2 = $e | Where-Object { $_.node -eq 'iic-n02' -and $_.step -eq 'Hostname' }
        $host2.state | Should -Be 'StepSkipped' -Because 'the fake script reports no Hostname item; the reason is given'
        $host2.evidence | Should -Match '^Not applicable'
    }
    It 'Apply: StepApplying, StepApplied, StepVerified in order, then NodeConverged, and RunCompleted counts the converged nodes' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply
        $e = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $dns = @($e | Where-Object { $_.node -eq 'iic-n01' -and $_.step -eq 'Dns' } | ForEach-Object { $_.state })
        $dns | Should -Be @('StepPlanned', 'StepApplying', 'StepApplied', 'StepVerified')
        $states = Get-NodeState $e 'iic-n01'
        $states[-1] | Should -Be 'NodeConverged'
        @($states | Where-Object { $_ -eq 'NodeConverged' }).Count | Should -Be 1
        $e[-1].state | Should -Be 'RunCompleted'
        $e[-1].converged | Should -Be 2
        $e[-1].mode | Should -Be 'Apply'
    }
    It 'a node whose apply fails gets NodeFailed (Error) once, the other node converges, and the run ends with exit code 1 as an Error' {
        $global:AzlFail = @('iic-n01')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply
        $e = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $f = @($e | Where-Object { $_.node -eq 'iic-n01' -and $_.state -in 'NodeFailed', 'NodeConverged', 'NodeBlocked' })
        $f.Count | Should -Be 1
        $f[0].state | Should -Be 'NodeFailed'
        $f[0].level | Should -Be 'Error'
        $f[0].evidence | Should -Match 'boom'
        $f[0].nextAction | Should -Not -BeNullOrEmpty
        (Get-NodeState $e 'iic-n02')[-1] | Should -Be 'NodeConverged'
        $e[-1].exitCode | Should -Be 1
        $e[-1].level | Should -Be 'Error'
        $e[-1].converged | Should -Be 1
    }
    It 'Plan mode on a node that already matches: NodeConverged; a node with changes pending has no outcome yet' {
        $global:AzlConverged = @('iic-n01')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        $e = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        (Get-NodeState $e 'iic-n01') | Should -Contain 'NodeConverged'
        (Get-NodeState $e 'iic-n02') | Should -Not -Contain 'NodeConverged'
        $e[-1].converged | Should -Be 1
    }
    It 'bad input ends with RunCompleted exit code 2 and a NodeFailed for a node nothing reaches' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $global:AzlPortAnswers = $false
        $global:AzlArcNone = @('iic-n01', 'iic-n02')
        $r = Invoke-Run -Infra $infra
        $r.ExitCode | Should -Be 2
        $e = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $e[-1].state | Should -Be 'RunCompleted'
        $e[-1].exitCode | Should -Be 2
        @($e | Where-Object { $_.state -eq 'NodeFailed' }).Count | Should -BeGreaterThan 0
    }
    It 'WipeListPublished lists the disks of the plan when the storage wipe is on' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.os_configuration = @{ clear_storage = $true } }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        $e = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $w = $e | Where-Object { $_.state -eq 'WipeListPublished' }
        $w.level | Should -Be 'Warning'
        $w.wipeCount | Should -Be 2
        @($w.wipe).Count | Should -Be 2
        @($w.wipe)[0].node | Should -Be 'iic-n01'
        $w.evidence | Should -Match 'WOULD BE WIPED'
    }
    It '-EventLogPath puts the feed elsewhere and appends to what is there' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $shared = Join-Path $TestDrive 'shared\events.jsonl'
        $r1 = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ EventLogPath = $shared }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ EventLogPath = $shared }
        Test-Path (Join-Path $r1.Out 'os-configuration-events.jsonl') | Should -BeFalse
        $e = Read-RunEvent $shared
        @($e | Where-Object { $_.state -eq 'RunStarted' }).Count | Should -Be 2
        @($e | Where-Object { $_.state -eq 'RunCompleted' }).Count | Should -Be 2
    }
    It 'a feed that cannot be written never fails the run' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ EventLogPath = $TestDrive }
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $r.Out 'report.json') | Should -BeTrue
    }
    It 'a retry of an Unknown run command is written as NodeRetry with the try number, while the call runs' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlSetNodeConfiguration {
            & (Get-Module AzlOsConfigurationRun) { param($c, $r, $p, $retry) Send-AzlRetryEvent -Context $c -Record $r -Phase $p -Retry $retry } $EventContext $EventRecord $EventPhase ([pscustomobject]@{ Node = $Parameters.Node[0]; Try = 2; Tries = 3; WaitSeconds = 45 })
            New-FakeSetResult $Parameters
        }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Node = @('iic-n01'); Transport = 'ArcRunCommand' }
        $e = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $retry = @($e | Where-Object { $_.state -eq 'NodeRetry' })
        $retry.Count | Should -Be 1
        $retry[0].node | Should -Be 'iic-n01'
        $retry[0].try | Should -Be 2
        $retry[0].tries | Should -Be 3
        $retry[0].level | Should -Be 'Warning'
        $retry[0].transport | Should -Be 'ArcRunCommand'
    }
}

Describe 'Transport: PowerShell remoting by default, Arc only when asked' {
    BeforeEach {
        $global:AzlBootstrap = [System.Collections.Generic.List[object]]::new()
        # The one bootstrap there is: the profile-driven one. The fake records what the profile gave it (sources, RDP, HTTP window) and opens the node.
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlWinRmBootstrap {
            $global:AzlBootstrap.Add([pscustomobject]@{ Node = $Node; Address = $Address; Cidr = @($RemotingProfile.Firewall.RemoteAddress); Rdp = [bool]$RemotingProfile.Firewall.RdpEnabled; Http = [bool]$RemotingProfile.Transport.BootstrapWindowHttp; Approved = $ApprovedBootstrap.IsPresent })
            $global:AzlOpened += $Address
            [pscustomobject]@{ Node = $Node; Ok = $true; Route = 'arc'; Attempts = @(); Reason = ''; Result = $null }
        }
        Mock -ModuleName AzlOsConfigurationRun New-AzlArcRunCommandTransport { [pscustomobject]@{ Kind = 'ArcRunCommand' } }
        Mock -ModuleName AzlOsConfigurationRun Start-Sleep {}
    }
    AfterEach { Remove-Variable -Name AzlBootstrap -Scope Global -ErrorAction SilentlyContinue }

    It 'a node that does not answer on the remoting port fails the run before anything is changed, with the diagnosis, and Arc is not tried' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
            foreach ($c in $Candidate) { [pscustomobject]@{ Node = $c.Name; Reachable = $false; Address = @($c.Addresses)[0]; Port = 5985; Result = 'TimedOut'; Credential = 'vault'; Diagnosis = $global:AzlDiag; Tried = @($c.Addresses) } }
        }
        Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'node-configuration', 'AzlNodeTransport.psm1')) -Force
        $global:AzlDiag = Get-AzlRemotingDiagnosis -Reason TimedOut -Address 192.0.2.11 -Port 5985 -Detail 'no answer' -ArcAvailable $true
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match "can't reach 2 node"
        $r.Message | Should -Match 'TimedOut'
        $r.Message | Should -Match 'limited to the local subnet'
        $r.Message | Should -Match "bootstrapTransport = 'arc'"
        $global:AzlCalls.Count | Should -Be 0
        $global:AzlBootstrap.Count | Should -Be 0
        Should -Invoke -ModuleName AzlOsConfigurationRun New-AzlArcRunCommandTransport -Times 0
    }

    It 'bootstrapTransport arc, plan: nothing is opened, the plan says what Arc will do once' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
            foreach ($c in $Candidate) { [pscustomobject]@{ Node = $c.Name; Reachable = $false; Address = @($c.Addresses)[0]; Port = 5985; Result = 'TimedOut'; Credential = 'vault'; Diagnosis = 'closed'; Tried = @($c.Addresses) } }
        }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ ApprovedBootstrap = $true; Settings = @{ remoting = @{ bootstrapTransport = 'arc'; allowedSourceCidrs = @('198.51.100.0/24') } } }
        $r.ExitCode | Should -Be 0 -Because $r.Message
        $global:AzlBootstrap.Count | Should -Be 0
        $global:AzlCalls.Count | Should -Be 0
        foreach ($rec in $r.Records) {
            $item = @($rec.plan | Where-Object Item -eq 'remote management bootstrap')
            $item.Count | Should -Be 1
            $item[0].Desired | Should -Match '198\.51\.100\.0/24'
            $item[0].Desired | Should -Match '192\.0\.2\.0/24'
        }
    }

    It 'bootstrapTransport arc, apply: Arc opens the firewall once per node, then everything else goes over WinRM' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
            foreach ($c in $Candidate) { [pscustomobject]@{ Node = $c.Name; Reachable = $false; Address = @($c.Addresses)[0]; Port = 5985; Result = 'TimedOut'; Credential = 'vault'; Diagnosis = 'closed'; Tried = @($c.Addresses) } }
        }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply -Extra @{ ApprovedBootstrap = $true; Settings = @{ remoting = @{ bootstrapTransport = 'arc'; allowedSourceCidrs = @('198.51.100.0/24') } } }
        $global:AzlBootstrap.Count | Should -Be 2
        @($global:AzlBootstrap.Node | Sort-Object) | Should -Be @('iic-n01', 'iic-n02')
        foreach ($b in $global:AzlBootstrap) { $b.Cidr | Should -Contain '198.51.100.0/24'; $b.Cidr | Should -Contain '192.0.2.0/24'; $b.Cidr | Should -Not -Contain 'LocalSubnet'; $b.Http | Should -BeTrue }
        # the bootstrap happens before the node is read or changed, and every call of the script after it uses WinRM
        $global:AzlCalls.Count | Should -BeGreaterThan 0
        foreach ($c in $global:AzlCalls) { $c.Params.Transport | Should -Be 'WinRM' }
        foreach ($rec in $r.Records) {
            $rec.bootstrap.used | Should -BeTrue
            $rec.bootstrap.transport | Should -Be 'arc'
            ($rec.changes | Where-Object id -eq 'RemoteManagement/bootstrap').status | Should -Be 'changed'
        }
        $report = Get-Content -LiteralPath $r.ReportPath -Raw | ConvertFrom-Json -Depth 20
        $report.nodes[0].stepTransports.all | Should -Be 'WinRM'
        $report.nodes[0].stepTransports.bootstrap | Should -Be 'arc'
        $report.nodes[0].bootstrap.used | Should -BeTrue
    }

    It 'bootstrapTransport smb, apply: the pre-check path uses the profile bootstrap for smb too (no separate Arc-only bootstrap)' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
            foreach ($c in $Candidate) { [pscustomobject]@{ Node = $c.Name; Reachable = $false; Address = @($c.Addresses)[0]; Port = 5985; Result = 'TimedOut'; Credential = 'vault'; Diagnosis = 'closed'; Tried = @($c.Addresses) } }
        }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply -Extra @{ ApprovedBootstrap = $true; Settings = @{ remoting = @{ bootstrapTransport = 'smb' } } }
        $global:AzlBootstrap.Count | Should -Be 2
        foreach ($b in $global:AzlBootstrap) { $b.Approved | Should -BeTrue; $b.Cidr | Should -Not -Contain 'LocalSubnet' }
    }

    It 'the legacy Arc bootstrap is gone: no OpenRemoting node script, no Invoke-AzlRemotingBootstrap, no Get-AzlRemotingAllowedCidr' {
        { Get-AzlNodePayload -Name OpenRemoting } | Should -Throw
        Get-Command Invoke-AzlRemotingBootstrap -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command Get-AzlRemotingAllowedCidr -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $script:ModulePath -Raw) | Should -Not -Match 'Invoke-AzlRemotingBootstrap|Get-AzlRemotingAllowedCidr|OpenRemoting'
        $setScript = Join-Path (Split-Path $script:EntryScript -Parent) 'Set-AzureLocalNodeConfiguration.ps1'
        (Get-Content -LiteralPath $setScript -Raw) | Should -Not -Match 'Invoke-AzlRemotingBootstrap|Get-AzlRemotingAllowedCidr|OpenRemoting'
    }

    It 'a node whose Arc machine is not Connected is not bootstrapped: the run fails with the diagnosis' {
        $global:AzlArcStatus = 'Disconnected'
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
            foreach ($c in $Candidate) { [pscustomobject]@{ Node = $c.Name; Reachable = $false; Address = @($c.Addresses)[0]; Port = 5985; Result = 'TimedOut'; Credential = 'vault'; Diagnosis = 'closed'; Tried = @($c.Addresses) } }
        }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply -Extra @{ ApprovedBootstrap = $true; Settings = @{ remoting = @{ bootstrapTransport = 'arc' } } }
        $r.ExitCode | Should -Be 2
        $global:AzlBootstrap.Count | Should -Be 0
    }

    It 'explicit -Transport ArcRunCommand runs everything over Arc, with no remoting pre-check' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Mode Apply -Extra @{ Transport = 'ArcRunCommand' }
        $global:AzlCalls.Count | Should -BeGreaterThan 0
        foreach ($c in $global:AzlCalls) { $c.Params.Transport | Should -Be 'ArcRunCommand' }
        Should -Invoke -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck -Times 0
        $global:AzlBootstrap.Count | Should -Be 0
        foreach ($rec in $r.Records) { $rec.transport | Should -Be 'ArcRunCommand' }
    }

    It 'the settings reach the script: confirmation window, stable period, reconnect wait, stale age, probe, remoting' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Settings = @{ networkRollbackMinutes = 20; networkStableSeconds = 30; reconnectWaitMinutes = 25; staleRunCommandMinutes = 45; addressProbe = $false } }
        $s = $global:AzlCalls[0].Params.Settings
        $s.networkRollbackMinutes | Should -Be 20
        $s.networkStableSeconds | Should -Be 30
        $s.reconnectWaitMinutes | Should -Be 25
        $s.staleRunCommandMinutes | Should -Be 45
        $s.addressProbe | Should -BeFalse
        $global:AzlCalls[0].Params.EventLogPath | Should -BeLike '*os-configuration-events.jsonl'
    }

    It 'invalid new settings are bad input (exit 2)' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        (Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Settings = @{ networkRollbackMinutes = 0 } }).ExitCode | Should -Be 2
        (Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Settings = @{ remoting = @{ bootstrapTransport = 'maybe' } } }).ExitCode | Should -Be 2
    }

    It 'the master file keys os_configuration.network.* and os_configuration.remoting.* are read' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.os_configuration = [ordered]@{ network = [ordered]@{ confirm_minutes = 12; stable_seconds = 5 }; remoting = [ordered]@{ transport = 'winrm_https'; allowed_source_cidrs = @('198.51.100.0/24') } } }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        $global:AzlCalls[0].Params.Settings.networkRollbackMinutes | Should -Be 12
        $global:AzlCalls[0].Params.Settings.networkStableSeconds | Should -Be 5
        $global:AzlCalls[0].Params.UseSsl | Should -BeTrue
    }
}

Describe 'Remote management profile in the run' {
    BeforeAll {
        $script:VaultPassword = 'P@ssw0rd-from-the-vault-not-printed'
        function Set-Class([string]$Class, [scriptblock]$More) {
            $c = $Class; $m = $More
            Get-TestInfra { param($d) if ($c) { $d.scenario.environment_class = $c }; if ($m) { & $m $d } }
        }
        function Add-Remoting([object]$Doc, [hashtable]$Values) {
            if (-not $Doc.Contains('os_configuration')) { $Doc['os_configuration'] = [ordered]@{} }
            if (-not $Doc['os_configuration'].Contains('remoting')) { $Doc['os_configuration']['remoting'] = [ordered]@{} }
            foreach ($k in $Values.Keys) { $Doc['os_configuration']['remoting'][$k] = $Values[$k] }
        }
        function Get-Report([object]$Run) { Get-Content -LiteralPath (Join-Path $Run.Out 'report.json') -Raw | ConvertFrom-Json -Depth 20 }
    }

    It 'lab: TrustedHosts is * while the nodes are handled, and the previous value is back afterwards and in the report' {
        $global:AzlTrustedHostsInitial = 'prior.example.invalid'
        $r = Invoke-Run -Infra (Set-Class 'lab') -Handoff (Get-TestHandoffDirectory)
        $r.ExitCode | Should -Be 0
        $global:AzlTrustedHostsDuring | Should -Be '*'
        $global:AzlTrustedHosts | Should -Be 'prior.example.invalid'
        $policy = (Get-Report $r).remoting.trustedHostsPolicy
        $policy.mode | Should -Be 'wildcard'
        $policy.previous | Should -Be 'prior.example.invalid'
        $policy.applied | Should -Be '*'
        $policy.restored | Should -BeTrue
    }
    It 'lab: the report holds the class, the posture, the firewall scope Any and the relaxed warning' {
        $r = Invoke-Run -Infra (Set-Class 'lab') -Handoff (Get-TestHandoffDirectory)
        $remoting = (Get-Report $r).remoting
        $remoting.class | Should -Be 'lab'
        $remoting.posture | Should -Be 'relaxed-wildcard'
        @($remoting.firewall.remoteAddress) | Should -Be @('Any')
        ($remoting.warnings -join ' ') | Should -Match 'Relaxed remote management posture'
        $remoting.baseline.allowUnencrypted | Should -BeFalse
        @($remoting.events.state) | Should -Contain 'RemotingProfileResolved'
        @($remoting.events.state) | Should -Contain 'TrustedHostsChanged'
        @($remoting.events.state) | Should -Contain 'TrustedHostsRestored'
        $feed = @(Get-Content -LiteralPath (Join-Path $r.Out 'remoting-events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        ($feed | Where-Object state -eq 'RemotingProfileResolved').class | Should -Be 'lab'
    }
    It 'prints the effective profile and its warnings before anything changes' {
        $infra = Set-Class 'lab'
        $out = Join-Path $TestDrive 'printed'
        $lines = @(Invoke-AzlOsConfiguration -InfrastructureFile $infra -Mode Plan -ReportDirectory $out -SkipValidation -HandoffPath (Get-TestHandoffDirectory) -TrustedHostsStore ([pscustomobject]@{ Supported = $true; Get = { '' }; Set = { param($Value) $null = $Value } }) 6>&1 3>$null | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $text = $lines -join "`n"
        $text | Should -Match 'Remote management profile: class lab'
        $text | Should -Match 'WARNING: Relaxed remote management posture'
        $text.IndexOf('Remote management profile') | Should -BeLessThan $text.IndexOf('== Plan')
    }
    It 'production: TrustedHosts is not touched, and the report says production' {
        $global:AzlTrustedHostsInitial = 'prior.example.invalid'
        $r = Invoke-Run -Infra (Set-Class 'production') -Handoff (Get-TestHandoffDirectory)
        $global:AzlTrustedHostsDuring | Should -Be 'prior.example.invalid'
        $global:AzlTrustedHosts | Should -Be 'prior.example.invalid'
        $remoting = (Get-Report $r).remoting
        $remoting.class | Should -Be 'production'
        @($remoting.firewall.remoteAddress) | Should -Not -Contain 'Any'
        $remoting.trustedHostsPolicy.changed | Should -BeFalse
    }
    It 'a missing class is production' {
        $r = Invoke-Run -Infra (Set-Class '') -Handoff (Get-TestHandoffDirectory)
        (Get-Report $r).remoting.class | Should -Be 'production'
        (Get-Report $r).remoting.classSource | Should -Match 'missing'
    }
    It 'dev: only the nodes'' addresses are added to TrustedHosts, and removed again' {
        $global:AzlTrustedHostsInitial = 'prior.example.invalid'
        $null = Invoke-Run -Infra (Set-Class 'dev') -Handoff (Get-TestHandoffDirectory)
        $global:AzlTrustedHostsDuring | Should -Be 'prior.example.invalid,192.0.2.11,192.0.2.12'
        $global:AzlTrustedHosts | Should -Be 'prior.example.invalid'
    }
    It 'an unknown class is exit code 2, names the allowed values, and changes nothing' {
        $global:AzlTrustedHostsInitial = 'prior.example.invalid'
        $r = Invoke-Run -Infra (Set-Class 'staging') -Handoff (Get-TestHandoffDirectory)
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'lab, test, dev, production, dmz'
        $global:AzlCalls.Count | Should -Be 0
        $global:AzlTrustedHosts | Should -Be 'prior.example.invalid'
    }
    It 'TrustedHosts is put back when the run fails half way' {
        Mock -ModuleName AzlOsConfigurationRun Test-AzlSanConsistency { throw 'something broke' }
        $global:AzlTrustedHostsInitial = 'prior.example.invalid'
        $r = Invoke-Run -Infra (Set-Class 'lab') -Handoff (Get-TestHandoffDirectory)
        $r.ExitCode | Should -Be 1
        $global:AzlTrustedHostsDuring | Should -Be '*'
        $global:AzlTrustedHosts | Should -Be 'prior.example.invalid'
    }
    It 'WinRM unreachable: the message says the node firewall probably limits WinRM to its own subnet, and names the bootstrap options' {
        $global:AzlPortAnswers = $false
        $global:AzlArcNone = @('iic-n01', 'iic-n02')
        $r = Invoke-Run -Infra (Set-Class 'lab' { param($d) $d.scenario.os_install = 'iso' })
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'the node firewall probably limits WinRM to its own subnet'
        $r.Message | Should -Match 'bootstrap_transport'
        $r.Message | Should -Match 'console or the BMC'
    }
    It 'the entry script takes -ApprovedBootstrap' {
        (Get-Command $script:EntryScript).Parameters.ContainsKey('ApprovedBootstrap') | Should -BeTrue
    }

    Context 'the one-time bootstrap in the pre-check' {
        BeforeEach {
            $global:AzlPortAnswers = $false
            $global:AzlArcNone = @('iic-n01', 'iic-n02')
            Mock -ModuleName AzlOsConfigurationRun Invoke-AzlWinRmBootstrap {
                $global:AzlOpened += $Address
                [pscustomobject]@{ Node = $Node; Ok = $true; Route = 'smb'; Attempts = @([pscustomobject]@{ Route = 'smb'; Ok = $true; Reason = '' }); Reason = ''; Result = $null }
            }
        }
        It 'lab, smb: WinRM closed, Apply runs the bootstrap once per node as Administrator, and the run goes on' {
            $infra = Set-Class 'lab' { param($d) $d.scenario.os_install = 'iso'; Add-Remoting $d @{ bootstrap_transport = 'smb' } }
            $r = Invoke-Run -Infra $infra -Mode Apply
            $r.ExitCode | Should -Not -Be 2
            Should -Invoke -ModuleName AzlOsConfigurationRun Invoke-AzlWinRmBootstrap -Times 2 -Exactly -ParameterFilter { $Credential.UserName -eq 'Administrator' -and -not $ApprovedBootstrap }
            $bootstraps = (Get-Report $r).remoting.bootstraps
            @($bootstraps).Count | Should -Be 2
            $bootstraps[0].route | Should -Be 'smb'
        }
        It 'Plan mode never bootstraps; it says what Apply would do' {
            $infra = Set-Class 'lab' { param($d) $d.scenario.os_install = 'iso'; Add-Remoting $d @{ bootstrap_transport = 'smb' } }
            $r = Invoke-Run -Infra $infra -Mode Plan
            Should -Invoke -ModuleName AzlOsConfigurationRun Invoke-AzlWinRmBootstrap -Times 0 -Exactly
            $r.ExitCode | Should -Be 2
            $r.Message | Should -Match 'Plan mode changes nothing'
        }
        It 'bootstrap_transport none: nothing is bootstrapped' {
            $infra = Set-Class 'lab' { param($d) $d.scenario.os_install = 'iso' }
            $null = Invoke-Run -Infra $infra -Mode Apply
            Should -Invoke -ModuleName AzlOsConfigurationRun Invoke-AzlWinRmBootstrap -Times 0 -Exactly
        }
        It 'production: smb chosen but not approved does not run, and the message asks for -ApprovedBootstrap' {
            $infra = Set-Class 'production' { param($d) $d.scenario.os_install = 'iso'; Add-Remoting $d @{ bootstrap_transport = 'smb' } }
            $r = Invoke-Run -Infra $infra -Mode Apply
            Should -Invoke -ModuleName AzlOsConfigurationRun Invoke-AzlWinRmBootstrap -Times 0 -Exactly
            $r.ExitCode | Should -Be 2
            $r.Message | Should -Match 'ApprovedBootstrap'
        }
        It 'production: with -ApprovedBootstrap it runs' {
            $infra = Set-Class 'production' { param($d) $d.scenario.os_install = 'iso'; Add-Remoting $d @{ bootstrap_transport = 'smb' } }
            $null = Invoke-Run -Infra $infra -Mode Apply -Extra @{ ApprovedBootstrap = $true }
            Should -Invoke -ModuleName AzlOsConfigurationRun Invoke-AzlWinRmBootstrap -Times 2 -Exactly -ParameterFilter { $ApprovedBootstrap }
        }
        It 'dmz: an approval in the run settings file does not count' {
            $infra = Set-Class 'dmz' { param($d) $d.scenario.os_install = 'iso'; Add-Remoting $d @{ bootstrap_transport = 'smb'; certificate = ('AB' * 20); allowed_source_cidrs = @('198.51.100.10/32') } }
            $r = Invoke-Run -Infra $infra -Mode Apply -Extra @{ Settings = @{ approvedBootstrap = $true } }
            Should -Invoke -ModuleName AzlOsConfigurationRun Invoke-AzlWinRmBootstrap -Times 0 -Exactly
            $r.ExitCode | Should -Be 2
        }
        It 'the password never appears in the report, the events, the summary or the printed output' {
            $infra = Set-Class 'lab' { param($d) $d.scenario.os_install = 'iso'; Add-Remoting $d @{ bootstrap_transport = 'auto' } }
            $out = Join-Path $TestDrive 'secret-check'
            $printed = (Invoke-AzlOsConfiguration -InfrastructureFile $infra -Mode Apply -ReportDirectory $out -SkipValidation -TrustedHostsStore ([pscustomobject]@{ Supported = $true; Get = { '' }; Set = { param($Value) $null = $Value } }) 6>&1 3>&1 | Out-String)
            $files = Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
            ($files -join "`n") + $printed | Should -Not -Match ([regex]::Escape($script:VaultPassword))
            ($files -join "`n") | Should -Match 'bootstraps'
        }
    }
}
}
