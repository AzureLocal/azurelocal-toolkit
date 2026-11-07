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
        $global:AzlArcStatus = 'Connected'
        $global:AzlArcNone = @()
        $global:AzlRegistered = [System.Collections.Generic.List[string]]::new()
    }

    function Invoke-Run {
        param([string]$Infra, [string[]]$Handoff, [string]$Mode = 'Plan', [hashtable]$Extra = @{})
        $out = Join-Path $TestDrive "out-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $arguments = @{ InfrastructureFile = $Infra; Mode = $Mode; ReportDirectory = $out; SkipValidation = $true } + $Extra
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
    Mock -ModuleName AzlOsConfigurationRun Test-AzlWinRmPort { [bool]$global:AzlPortAnswers }
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
    It 'declared simplified with a ready handoff: the ZTP path over Arc, no warning' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared simplified -Evidence (Get-TestEvidence @{ HandoffPresent = $true; HandoffReady = $true; ArcFound = $true; ArcStatus = 'Connected' })
        $r.Method | Should -Be 'Ztp'
        $r.Source | Should -Be 'declared'
        $r.Transport | Should -Be 'ArcRunCommand'
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
    It 'declared iso and already a Connected Arc machine: the ISO path, reached over Arc' {
        $r = Resolve-AzlNodeMethod -Node n1 -Declared iso -Evidence (Get-TestEvidence @{ ArcFound = $true; ArcStatus = 'Connected' })
        $r.Method | Should -Be 'Iso'
        $r.Transport | Should -Be 'ArcRunCommand'
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
            $c.Params.Transport | Should -Be 'ArcRunCommand'
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
    It 'an Arc node without an Azure sign-in: exit 2' {
        Mock -ModuleName AzlOsConfigurationRun Test-AzlAzureSignedIn { $false }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
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
            $rec.transport | Should -Be 'ArcRunCommand'
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
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
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
    It 'winrm_copy on a ZTP node reached over Arc: the run hands the script the local administrator for the copy, the other steps stay on Arc' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.hardware.sbe.delivery = 'winrm_copy' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        $call = $global:AzlCalls[0]
        $call.Params.Transport | Should -Be 'ArcRunCommand'
        $call.Params.Credential | Should -Not -BeNullOrEmpty
        $call.Params.Credential.UserName | Should -Not -BeNullOrEmpty
        'Sbe' | Should -BeIn $call.Params.Step
    }
    It '<_> on a ZTP node needs no credential' -ForEach 'skip', 'node_pull' {
        $route = $_
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified'; $d.hardware.sbe.delivery = $route; $d.hardware.sbe.node_pull_url = 'https://files.example.invalid/sbe' }
        $null = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        $global:AzlCalls[0].Params.ContainsKey('Credential') | Should -BeFalse
    }
}
}
