#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Invoke-AzureLocalPostDeployment.ps1 and its engine (scripts/common/post-deployment/AzlPostDeploymentRun.psm1): which steps run, in which order, which are
# skipped and why, the selection (-Only, -From, -To), Plan against Apply, the stop at the first failure and at warnings, the refusal of SDN without its
# acknowledgement keys, the connection check, the report and the events. The real step table is used with STUB scripts at the paths of the real ones in a
# temporary root: nothing reaches a cluster or Azure, and each stub records how it was called.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/PostDeploymentRun.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A throwaway test credential.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    $script:Module = Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'post-deployment', 'AzlPostDeploymentRun.psm1')) -Force -PassThru
    $script:TablePath = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'PostDeploymentSteps.psd1')
    $script:Table = Import-PowerShellDataFile -LiteralPath $script:TablePath
    $script:Ids = @($script:Table.Steps | ForEach-Object { $_.Id })

    # A root with a stub at the path of every script of the table (and of every Azure CLI twin). A stub has the parameters of the real script it stands for.
    function New-StubRoot {
        $root = Join-Path $TestDrive ('root-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        foreach ($s in $script:Table.Steps) {
            foreach ($relative in @($s.Script, $(if ($s.ContainsKey('AzureCliScript')) { $s.AzureCliScript }))) {
                if (-not $relative) { continue }
                $path = Join-Path $root $relative
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path)
                $binding = if ($s.Plan -eq 'WhatIf') { '[CmdletBinding(SupportsShouldProcess)]' } else { '[CmdletBinding()]' }
                $extraParams = @(if ($s.Plan -eq 'WhatIf') { '[string]$LogPath', '[string]$ComputerName', '[pscredential]$Credential' })
                if ($s.ContainsKey('Arguments')) { foreach ($a in $s.Arguments) { $extraParams += "[switch]`$$($a.Name)" } }
                $text = @"
$binding
param([Parameter(Mandatory)][string]`$InfrastructureFile$(if ($extraParams) { ', ' + ($extraParams -join ', ') }))
`$what = if (`$env:AZL_PD_AZCLI -and '$relative' -like '*azcli*') { '$($s.Id)#azcli' } else { '$($s.Id)' }
`$entry = [ordered]@{ step = `$what; whatif = [bool]`$WhatIfPreference; bound = @(`$PSBoundParameters.Keys | Sort-Object) }
Add-Content -LiteralPath `$env:AZL_PD_RECORD -Value (ConvertTo-Json -InputObject `$entry -Compress) -WhatIf:`$false
`$behaviour = @{}; foreach (`$pair in (`$env:AZL_PD_BEHAVIOUR -split ';')) { if (`$pair -match '^(.+?)=(.+)$') { `$behaviour[`$Matches[1]] = `$Matches[2] } }
`$mode = `$behaviour['$($s.Id)']
Write-Information 'found: $($s.Id) looked at the file' -InformationAction Continue
if (`$mode -eq 'warn') { Write-Warning 'a warning of $($s.Id)' }
if (`$mode -eq 'fail') { Write-Error 'the failure of $($s.Id)' -ErrorAction Continue; exit 1 }
if (`$mode -eq 'input') { Write-Error 'a value is missing for $($s.Id)' -ErrorAction Continue; exit 2 }
if (`$mode -eq 'secret') { Write-Information 'connected with password = hunter2 and token: abc123' -InformationAction Continue }
if (`$mode -eq 'errorok') { Write-Error 'an error the script went on from' -ErrorAction Continue }
if (`$mode -eq 'throw') { throw 'an unhandled error of $($s.Id)' }
exit 0
"@
                Set-Content -LiteralPath $path -Value $text
            }
        }
        $root
    }

    function New-Infra([hashtable]$Change = @{}, [string[]]$Remove = @()) {
        $d = [ordered]@{
            cluster = [ordered]@{ name = 'clus01'; witness = [ordered]@{ type = 'cloud'; storage_account = 'stwit01' } }
            scenario = [ordered]@{ storage_architecture = 'hybrid' }
            sdn = [ordered]@{ enabled = $true; prefix = 'iic'; dns_records = 'dynamic'; acknowledge_maintenance_window = $true }
            identity = [ordered]@{ active_directory = [ordered]@{ security_groups = @([ordered]@{ name = 'g1'; local_groups = @('Administrators') }) } }
            storage = [ordered]@{ volumes = @([ordered]@{ name = 'vol1'; size_gib = 100 }); paths = @([ordered]@{ name = 'sp1'; path = 'C:\ClusterStorage\vol1' }); vm_images = @([ordered]@{ name = 'img1' }) }
            networking = [ordered]@{ network_security_groups = @([ordered]@{ name = 'nsg1' }); logical_networks = @([ordered]@{ name = 'lnet1' }) }
            hardware = [ordered]@{ sbe = [ordered]@{ requirement = 'required'; source_path = '\\share\sbe' } }
        }
        foreach ($k in $Change.Keys) {
            $parts = $k -split '\.'
            $node = $d
            for ($i = 0; $i -lt $parts.Count - 1; $i++) { if (-not $node.Contains($parts[$i])) { $node[$parts[$i]] = [ordered]@{} }; $node = $node[$parts[$i]] }
            $node[$parts[-1]] = $Change[$k]
        }
        foreach ($k in $Remove) {
            $parts = $k -split '\.'
            $node = $d
            for ($i = 0; $i -lt $parts.Count - 1; $i++) { $node = $node[$parts[$i]] }
            $node.Remove($parts[-1])
        }
        $file = Join-Path $TestDrive ('infra-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $d)
        $file
    }

    # Runs the engine with the stub root; returns the result, the calls the stubs recorded and the files of the run.
    function Invoke-Run {
        param([string]$File, [hashtable]$Parameters = @{}, [string]$Behaviour = '', [switch]$Azcli)
        $root = New-StubRoot
        $log = Join-Path $TestDrive ('log-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $record = Join-Path $TestDrive ('rec-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
        $events = Join-Path $TestDrive ('ev-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
        $env:AZL_PD_RECORD = $record; $env:AZL_PD_BEHAVIOUR = $Behaviour
        if ($Azcli) { $env:AZL_PD_AZCLI = '1' } else { Remove-Item Env:AZL_PD_AZCLI -ErrorAction SilentlyContinue }
        $arguments = @{ InfrastructureFile = $File; LogPath = $log; RepositoryRoot = $root; StepTablePath = $script:TablePath; EventLogPath = $events; SkipValidation = $true; RemoteCommand = { param([hashtable]$Call) $true } }
        foreach ($k in $Parameters.Keys) { $arguments[$k] = $Parameters[$k] }
        $result = Invoke-AzlPostDeployment @arguments 6>$null 3>$null 2>$null
        $calls = if (Test-Path -LiteralPath $record) { @(Get-Content -LiteralPath $record | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
        $eventLines = if (Test-Path -LiteralPath $events) { @(Get-Content -LiteralPath $events | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
        [pscustomobject]@{ Result = $result; Code = $result.ExitCode; Calls = $calls; Ran = @($calls | ForEach-Object { $_.step }); Events = $eventLines; Log = $log; Steps = @($result.Steps) }
    }
    function Get-StepRow($Run, [string]$Id) { @($Run.Steps | Where-Object id -EQ $Id)[0] }
}

AfterAll { Remove-Item Env:AZL_PD_RECORD, Env:AZL_PD_BEHAVIOUR, Env:AZL_PD_AZCLI -ErrorAction SilentlyContinue }

Describe 'A full Plan run' {
    BeforeAll { $script:Plan = Invoke-Run -File (New-Infra) }
    It 'runs every step once, in the order of the table, and exits 0' {
        $script:Plan.Code | Should -Be 0
        $script:Plan.Ran | Should -Be $script:Ids
    }
    It 'passes -WhatIf to every step whose script has it, and runs every step, the SBE import included (it imports only with -Execute)' {
        foreach ($c in $script:Plan.Calls) {
            $step = @($script:Table.Steps | Where-Object Id -EQ $c.step)[0]
            $c.whatif | Should -Be ($step.Plan -eq 'WhatIf') -Because $c.step
        }
        (Get-StepRow $script:Plan 'sbe-import-plan').result | Should -Be 'Planned'
        (Get-StepRow $script:Plan 'quorum').result | Should -Be 'Planned'
    }
    It 'passes only the public parameters: InfrastructureFile, WhatIf, Confirm, LogPath (and -Execute of the SBE import, which -WhatIf keeps a plan)' {
        foreach ($c in $script:Plan.Calls) { @($c.bound | Where-Object { $_ -notin 'InfrastructureFile', 'LogPath', 'WhatIf', 'Confirm', 'Execute' }) | Should -BeNullOrEmpty -Because $c.step }
    }
    It 'gives each step its own log file in the log folder' {
        foreach ($c in @($script:Plan.Calls | Where-Object { $_.bound -contains 'LogPath' })) { $c.step | Should -Not -BeNullOrEmpty }
        @($script:Plan.Calls | Where-Object { $_.bound -contains 'LogPath' }).Count | Should -BeGreaterThan 8
    }
    It 'writes run.log, report.json and summary.md, and the report says what each step found' {
        foreach ($f in 'run.log', 'report.json', 'summary.md') { Join-Path $script:Plan.Log $f | Should -Exist }
        $report = Get-Content -LiteralPath (Join-Path $script:Plan.Log 'report.json') -Raw | ConvertFrom-Json
        $report.exitCode | Should -Be 0
        $report.mode | Should -Be 'Plan'
        @($report.steps).Count | Should -Be $script:Ids.Count
        (@($report.steps | Where-Object id -EQ 'ssh')[0].found -join ' ') | Should -Match 'ssh looked at the file'
        (Get-Content -LiteralPath (Join-Path $script:Plan.Log 'summary.md') -Raw) | Should -Match '\| sdn \|'
    }
    It 'writes events in the envelope Sonar reads: RunStarted first, one per step, RunCompleted last' {
        $e = $script:Plan.Events
        $e[0].state | Should -Be 'RunStarted'
        $e[-1].state | Should -Be 'RunCompleted'
        $e[-1].exitCode | Should -Be 0
        foreach ($line in $e) {
            $line.stage | Should -Be 'PostDeployment'
            $line.mode | Should -Be 'Plan'
            $line.cluster | Should -Be 'clus01'
            foreach ($f in 'timestamp', 'node', 'step', 'state', 'evidence', 'level', 'nextAction', 'runId') { $line.PSObject.Properties.Name | Should -Contain $f }
        }
        @($e | Where-Object state -EQ 'StepPlanned').Count | Should -Be 13
        ($e | Where-Object { $_.step -eq 'sdn' -and $_.state -eq 'StepStarted' }) | Should -Not -BeNullOrEmpty
    }
    It 'copies the events of this run (and only this run) next to the report, so a pipeline that publishes the log folder publishes the feed' {
        $file = New-Infra
        $first = Invoke-Run -File $file
        $copy = Join-Path $first.Log 'post-deployment-events.jsonl'
        $copy | Should -Exist
        $lines = @(Get-Content -LiteralPath $copy | ForEach-Object { $_ | ConvertFrom-Json })
        $lines.Count | Should -Be $first.Events.Count
        @($lines | ForEach-Object { $_.runId } | Sort-Object -Unique) | Should -Be @($first.Result.RunId)
        $lines[0].state | Should -Be 'RunStarted'
        $lines[-1].state | Should -Be 'RunCompleted'
    }
}

Describe 'Apply' {
    It 'passes no -WhatIf, and never prompts (-Confirm:$false)' {
        $r = Invoke-Run -File (New-Infra) -Parameters @{ Mode = 'Apply' }
        $r.Code | Should -Be 0
        @($r.Calls | Where-Object whatif).Count | Should -Be 0
        (Get-StepRow $r 'quorum').result | Should -Be 'Passed'
        ($r.Calls | Where-Object step -EQ 'quorum').bound | Should -Contain 'Confirm'
    }
    It 'asks for the node restarts of the external storage step only when operations.post_cluster.allow_node_restarts is true' {
        $without = Invoke-Run -File (New-Infra) -Parameters @{ Mode = 'Apply' }
        ($without.Calls | Where-Object step -EQ 'external-storage').bound | Should -Not -Contain 'RollingRestart'
        $with = Invoke-Run -File (New-Infra @{ 'operations.post_cluster.allow_node_restarts' = $true }) -Parameters @{ Mode = 'Apply' }
        ($with.Calls | Where-Object step -EQ 'external-storage').bound | Should -Contain 'RollingRestart'
    }
}

Describe 'A step the file does not enable is skipped with the reason' {
    It 'skips by the keys of the step, runs nothing for it, and says why' {
        $file = New-Infra -Remove 'storage.volumes', 'storage.paths', 'storage.vm_images', 'networking.logical_networks', 'networking.network_security_groups' -Change @{ 'sdn.enabled' = $false; 'scenario.storage_architecture' = 's2d' }
        $r = Invoke-Run -File $file
        $r.Code | Should -Be 0
        $r.Ran | Should -Be @('quorum', 'security-groups', 'ssh', 'verification', 'sbe-import-plan')
        (Get-StepRow $r 'sdn').reason | Should -Be 'sdn.enabled is not true (the file has it false)'
        (Get-StepRow $r 'storage-volumes').reason | Should -Be 'storage.volumes is empty or absent'
        (Get-StepRow $r 'storage-paths').result | Should -Be 'Skipped'
        (Get-StepRow $r 'vm-images').reason | Should -Match 'storage.vm_images'
        (Get-StepRow $r 'nsgs').reason | Should -Match 'network_security_groups'
        (Get-StepRow $r 'logical-networks').reason | Should -Match 'logical_networks'
        (Get-StepRow $r 'external-storage').reason | Should -Match "scenario.storage_architecture is not 'hybrid'"
        @($r.Events | Where-Object state -EQ 'StepSkipped').Count | Should -Be 8
    }
    It 'checks the Network Controller (sdn-test) right after the sdn step, with -WhatIf in Plan, and skips it with the sdn step when SDN is off' {
        $on = Invoke-Run -File (New-Infra)
        $on.Ran[0..1] | Should -Be @('sdn', 'sdn-test')
        (Get-StepRow $on 'sdn-test').result | Should -Be 'Planned'
        @($on.Calls | Where-Object step -EQ 'sdn-test')[0].whatif | Should -BeTrue
        $off = Invoke-Run -File (New-Infra @{ 'sdn.enabled' = $false })
        (Get-StepRow $off 'sdn-test').reason | Should -Match 'sdn.enabled is not true'
        $off.Ran | Should -Not -Contain 'sdn-test'
    }
    It 'runs sdn-test in Apply mode after the sdn step, and not after a failed sdn step' {
        (Invoke-Run -File (New-Infra) -Parameters @{ Mode = 'Apply' }).Ran[0..1] | Should -Be @('sdn', 'sdn-test')
        $failed = Invoke-Run -File (New-Infra) -Parameters @{ Mode = 'Apply' } -Behaviour 'sdn=fail'
        $failed.Code | Should -Be 1
        $failed.Ran | Should -Be @('sdn')
        (Get-StepRow $failed 'sdn-test').result | Should -Be 'NotRun'
    }
    It 'does not create the network security groups when SDN is off, whatever the file lists' {
        $r = Invoke-Run -File (New-Infra @{ 'sdn.enabled' = $false })
        (Get-StepRow $r 'nsgs').reason | Should -Match 'sdn.enabled is not true'
        $r.Ran | Should -Not -Contain 'nsgs'
    }
    It 'skips the SBE plan when the package is not applicable or no share is set' {
        (Get-StepRow (Invoke-Run -File (New-Infra @{ 'hardware.sbe.requirement' = 'not_applicable' })) 'sbe-import-plan').reason | Should -Match 'not_applicable'
        (Get-StepRow (Invoke-Run -File (New-Infra -Remove 'hardware.sbe.source_path')) 'sbe-import-plan').reason | Should -Match 'none of hardware.sbe.source_path, hardware.sbe.bundle_path is set'
        (Invoke-Run -File (New-Infra -Remove 'hardware.sbe.source_path' -Change @{ 'hardware.sbe.bundle_path' = 'D:\sbe' })).Ran | Should -Contain 'sbe-import-plan'
    }
    It 'skips the security groups when no group has local_groups, and the quorum when the file sets no witness' {
        $r = Invoke-Run -File (New-Infra -Change @{ 'identity.active_directory.security_groups' = @([ordered]@{ name = 'g1' }) } -Remove 'cluster.witness')
        (Get-StepRow $r 'security-groups').reason | Should -Be 'no entry of identity.active_directory.security_groups has local_groups'
        (Get-StepRow $r 'quorum').reason | Should -Be 'cluster.witness.type is empty or absent'
    }
    It 'leaves out the steps of operations.post_cluster.skip_steps, naming the key as the reason' {
        $r = Invoke-Run -File (New-Infra @{ 'operations.post_cluster.skip_steps' = @('ssh', 'quorum') })
        $r.Ran | Should -Not -Contain 'ssh'
        $r.Ran | Should -Not -Contain 'quorum'
        (Get-StepRow $r 'ssh').reason | Should -Match 'operations.post_cluster.skip_steps'
    }
    It 'refuses (exit 2, nothing run) a skip_steps entry that is not a step' {
        $r = Invoke-Run -File (New-Infra @{ 'operations.post_cluster.skip_steps' = @('nonsense') })
        $r.Code | Should -Be 2
        $r.Ran | Should -BeNullOrEmpty
    }
    It 'does nothing and exits 0 when operations.post_cluster.enabled is false' {
        $r = Invoke-Run -File (New-Infra @{ 'operations.post_cluster.enabled' = $false })
        $r.Code | Should -Be 0
        $r.Ran | Should -BeNullOrEmpty
    }
}

Describe 'The selection: one task, one step, or a range' {
    It '-Only runs exactly that script and no other' {
        $r = Invoke-Run -File (New-Infra) -Parameters @{ Only = @('vm-images') }
        $r.Ran | Should -Be @('vm-images')
        (Get-StepRow $r 'quorum').result | Should -Be 'NotSelected'
    }
    It '-Only task-05 runs the two storage steps, in order; the long name of the task works too' {
        (Invoke-Run -File (New-Infra) -Parameters @{ Only = @('task-05') }).Ran | Should -Be @('storage-volumes', 'storage-paths')
        (Invoke-Run -File (New-Infra) -Parameters @{ Only = @('task-08-logical-network-creation') }).Ran | Should -Be @('logical-networks')
    }
    It '-Only takes several steps and a comma list, and runs them in the order of the guide' {
        (Invoke-Run -File (New-Infra) -Parameters @{ Only = @('verification', 'quorum') }).Ran | Should -Be @('quorum', 'verification')
        (Invoke-Run -File (New-Infra) -Parameters @{ Only = @('ssh,sdn') }).Ran | Should -Be @('sdn', 'ssh')
    }
    It '-From and -To run the range, both ends included' {
        (Invoke-Run -File (New-Infra) -Parameters @{ From = 'storage-paths'; To = 'nsgs' }).Ran | Should -Be @('storage-paths', 'vm-images', 'nsgs')
        (Invoke-Run -File (New-Infra) -Parameters @{ From = 'task-09' }).Ran | Should -Be @('verification', 'external-storage', 'sbe-import-plan')
        (Invoke-Run -File (New-Infra) -Parameters @{ To = 'quorum' }).Ran | Should -Be @('sdn', 'sdn-test', 'quorum')
    }
    It 'a skipped step inside the selection is still skipped' {
        $r = Invoke-Run -File (New-Infra -Remove 'storage.vm_images') -Parameters @{ Only = @('vm-images') }
        $r.Code | Should -Be 0
        $r.Ran | Should -BeNullOrEmpty
        (Get-StepRow $r 'vm-images').result | Should -Be 'Skipped'
    }
    It 'refuses an unknown name, -Only with -From, and a range backwards (exit 2, nothing run)' {
        foreach ($p in @{ Only = @('nope') }, @{ Only = @('ssh'); From = 'sdn' }, @{ From = 'nsgs'; To = 'sdn' }, @{ From = 'nope' }) {
            $r = Invoke-Run -File (New-Infra) -Parameters $p
            $r.Code | Should -Be 2 -Because ($p | ConvertTo-Json -Compress)
            $r.Ran | Should -BeNullOrEmpty
        }
    }
    It 'Resolve-AzlPostDeploymentSelection returns the steps of a task in table order' {
        $steps = @($script:Table.Steps)
        @(Resolve-AzlPostDeploymentSelection -Steps $steps -Only 'task-05').Id | Should -Be @('storage-volumes', 'storage-paths')
    }
}

Describe 'The run stops at the first failure and never goes past it' {
    It 'a failed step ends the run with exit 1, and the steps after it are NotRun' {
        $r = Invoke-Run -File (New-Infra) -Parameters @{ Mode = 'Apply' } -Behaviour 'storage-paths=fail'
        $r.Code | Should -Be 1
        $r.Ran | Should -Be @('sdn', 'sdn-test', 'quorum', 'security-groups', 'ssh', 'storage-volumes', 'storage-paths')
        (Get-StepRow $r 'storage-paths').result | Should -Be 'Failed'
        (Get-StepRow $r 'vm-images').result | Should -Be 'NotRun'
        (Get-StepRow $r 'sbe-import-plan').result | Should -Be 'NotRun'
        (Get-StepRow $r 'storage-paths').reason | Should -Match 'the failure of storage-paths'
        ($r.Events | Where-Object state -EQ 'StepFailed').level | Should -Be 'Error'
        $r.Events[-1].exitCode | Should -Be 1
    }
    It 'a step that ends with exit code 2 ends the run with exit 2' {
        $r = Invoke-Run -File (New-Infra) -Behaviour 'vm-images=input'
        $r.Code | Should -Be 2
        (Get-StepRow $r 'vm-images').result | Should -Be 'InputProblem'
        $r.Ran | Should -Not -Contain 'nsgs'
    }
    It 'a script that throws is a failed step, with the message' {
        $r = Invoke-Run -File (New-Infra) -Behaviour 'ssh=throw'
        $r.Code | Should -Be 1
        (Get-StepRow $r 'ssh').reason | Should -Match 'an unhandled error of ssh'
        $r.Ran | Should -Not -Contain 'storage-volumes'
    }
    It 'the SDN step failing stops everything after it' {
        $r = Invoke-Run -File (New-Infra) -Parameters @{ Mode = 'Apply' } -Behaviour 'sdn=fail'
        $r.Code | Should -Be 1
        $r.Ran | Should -Be @('sdn')
    }
    It 'repeating from the failed step runs the rest (-From)' {
        (Invoke-Run -File (New-Infra) -Parameters @{ Mode = 'Apply'; From = 'storage-paths' }).Code | Should -Be 0
    }
}

Describe 'Warnings' {
    It 'stop the run after the step with exit 3, unless -ContinueOnWarning is given' {
        $stop = Invoke-Run -File (New-Infra) -Behaviour 'ssh=warn'
        $stop.Code | Should -Be 3
        (Get-StepRow $stop 'ssh').result | Should -Be 'Warning'
        $stop.Ran | Should -Be @('sdn', 'sdn-test', 'quorum', 'security-groups', 'ssh')
        $go = Invoke-Run -File (New-Infra) -Parameters @{ ContinueOnWarning = $true } -Behaviour 'ssh=warn'
        $go.Code | Should -Be 0
        (Get-StepRow $go 'ssh').result | Should -Be 'Warning'
        $go.Ran.Count | Should -Be 13
    }
}

Describe 'What a step prints' {
    It 'is masked when it looks like a secret, in the report and in the run log' {
        $r = Invoke-Run -File (New-Infra) -Behaviour 'ssh=secret' -Parameters @{ ContinueOnWarning = $true }
        $report = Get-Content -LiteralPath (Join-Path $r.Log 'report.json') -Raw
        $report | Should -Not -Match 'hunter2|abc123'
        $report | Should -Match 'password = \*\*\*'
        (Get-Content -LiteralPath (Join-Path $r.Log 'run.log') -Raw) | Should -Not -Match 'hunter2|abc123'
    }
    It 'an error the script reported and went on from (exit 0) is a warning of the step: the run stops after it' {
        $r = Invoke-Run -File (New-Infra) -Behaviour 'quorum=errorok'
        $r.Code | Should -Be 3
        (Get-StepRow $r 'quorum').result | Should -Be 'Warning'
    }
}
Describe 'SDN enabled by Azure Arc cannot be undone: it is refused without its acknowledgement keys' {
    It 'refuses without sdn.acknowledge_maintenance_window, in Plan and Apply, and runs nothing at all' {
        foreach ($mode in 'Plan', 'Apply') {
            $r = Invoke-Run -File (New-Infra -Remove 'sdn.acknowledge_maintenance_window') -Parameters @{ Mode = $mode }
            $r.Code | Should -Be 2 -Because $mode
            $r.Ran | Should -BeNullOrEmpty
            (Get-StepRow $r 'sdn').result | Should -Be 'Refused'
            ($r.Events | Where-Object state -EQ 'StepRefused').step | Should -Be 'sdn'
        }
    }
    It 'refuses a false acknowledgement' {
        (Invoke-Run -File (New-Infra @{ 'sdn.acknowledge_maintenance_window' = $false })).Code | Should -Be 2
    }
    It 'needs sdn.acknowledge_dns_record as well with static DNS records' {
        (Invoke-Run -File (New-Infra @{ 'sdn.dns_records' = 'static' })).Code | Should -Be 2
        (Invoke-Run -File (New-Infra @{ 'sdn.dns_records' = 'static'; 'sdn.acknowledge_dns_record' = $true })).Code | Should -Be 0
    }
    It 'does not refuse when SDN is off, when the step is not selected, or when it is skipped by the file' {
        (Invoke-Run -File (New-Infra -Remove 'sdn.acknowledge_maintenance_window' -Change @{ 'sdn.enabled' = $false })).Code | Should -Be 0
        (Invoke-Run -File (New-Infra -Remove 'sdn.acknowledge_maintenance_window') -Parameters @{ From = 'quorum' }).Code | Should -Be 0
        (Invoke-Run -File (New-Infra -Remove 'sdn.acknowledge_maintenance_window' -Change @{ 'operations.post_cluster.skip_steps' = @('sdn') })).Code | Should -Be 0
    }
}

Describe 'The connection to the cluster' {
    It 'is checked once, before the first step, through the shared connection module, and an unreachable cluster stops the run (exit 2) before any step' {
        $down = { param([hashtable]$Call) throw [System.Management.Automation.Remoting.PSRemotingTransportException]::new('no route to the node') }
        $r = Invoke-Run -File (New-Infra) -Parameters @{ RemoteCommand = $down }
        $r.Code | Should -Be 2
        $r.Ran | Should -BeNullOrEmpty
        ($r.Events | Where-Object state -EQ 'ClusterUnreachable') | Should -Not -BeNullOrEmpty
    }
    It 'is not checked when no selected step connects to a machine, or with -SkipClusterProbe' {
        $down = { param([hashtable]$Call) throw [System.Management.Automation.Remoting.PSRemotingTransportException]::new('no route to the node') }
        (Invoke-Run -File (New-Infra) -Parameters @{ RemoteCommand = $down; Only = @('vm-images', 'storage-paths') }).Code | Should -Be 0
        (Invoke-Run -File (New-Infra) -Parameters @{ RemoteCommand = $down; SkipClusterProbe = $true }).Code | Should -Be 0
    }
    It 'says in the events that the cluster answers' {
        (Invoke-Run -File (New-Infra)).Events.state | Should -Contain 'ClusterReachable'
    }
}

Describe 'What is passed to a script' {
    It 'passes -ComputerName and -Credential only when the operator gave them, and only to scripts that take them' {
        $credential = [pscredential]::new('ops', (ConvertTo-SecureString 'not-a-secret' -AsPlainText -Force))
        $r = Invoke-Run -File (New-Infra) -Parameters @{ ComputerName = 'node01'; Credential = $credential }
        ($r.Calls | Where-Object step -EQ 'quorum').bound | Should -Contain 'ComputerName'
        ($r.Calls | Where-Object step -EQ 'quorum').bound | Should -Contain 'Credential'
        ($r.Calls | Where-Object step -EQ 'sbe-import-plan').bound | Should -Contain 'ComputerName'
        $alone = Invoke-Run -File (New-Infra)
        ($alone.Calls | Where-Object step -EQ 'quorum').bound | Should -Not -Contain 'ComputerName'
        ($alone.Calls | Where-Object step -EQ 'quorum').bound | Should -Not -Contain 'Credential'
    }
    It '-Route AzureCli runs the Azure CLI twin of the steps that have one and the PowerShell script of the others' {
        $r = Invoke-Run -File (New-Infra) -Parameters @{ Route = 'AzureCli' } -Azcli
        $twins = @($script:Table.Steps | Where-Object { $_.ContainsKey('AzureCliScript') } | ForEach-Object { "$($_.Id)#azcli" })
        @($r.Ran | Where-Object { $_ -like '*#azcli' }) | Should -Be $twins
        $r.Ran | Should -Contain 'quorum'
    }
    It 'stops with exit 2 and runs nothing when a script of a selected step is missing' {
        $root = New-StubRoot
        Remove-Item -LiteralPath (Join-Path $root $script:Table.Steps[3].Script)
        $log = Join-Path $TestDrive 'missing-log'
        $env:AZL_PD_RECORD = Join-Path $TestDrive 'missing-rec.jsonl'
        $r = Invoke-AzlPostDeployment -InfrastructureFile (New-Infra) -LogPath $log -RepositoryRoot $root -StepTablePath $script:TablePath -EventLogPath (Join-Path $TestDrive 'missing-ev.jsonl') -SkipValidation -RemoteCommand { param($Call) $true } 6>$null 3>$null 2>$null
        $r.ExitCode | Should -Be 2
        $env:AZL_PD_RECORD | Should -Not -Exist
    }
    It 'exits 2 for a file that is not there' {
        $r = Invoke-Run -File (Join-Path $TestDrive 'no-such-file.yml')
        $r.Code | Should -Be 2
    }
}

Describe 'Test-AzlPostDeploymentCondition' {
    BeforeAll { $script:Doc = [ordered]@{ a = [ordered]@{ flag = $true; text = 'Hybrid'; empty = ''; list = @(); items = @([ordered]@{ x = ''; y = 1 }, [ordered]@{ x = 'v' }) } } }
    It '<Name>' -ForEach @(
        @{ Name = 'Is true: met'; Cond = @{ Key = 'a.flag'; Is = $true }; Met = $true }
        @{ Name = 'Is true: an absent key is not met'; Cond = @{ Key = 'a.nope'; Is = $true }; Met = $false }
        @{ Name = 'Is a string, without regard to case'; Cond = @{ Key = 'a.text'; Is = 'hybrid' }; Met = $true }
        @{ Name = 'IsNot: another value passes'; Cond = @{ Key = 'a.text'; IsNot = 's2d' }; Met = $true }
        @{ Name = 'IsNot: an absent key passes'; Cond = @{ Key = 'a.nope'; IsNot = 'x' }; Met = $true }
        @{ Name = 'IsNot: the value fails'; Cond = @{ Key = 'a.text'; IsNot = 'HYBRID' }; Met = $false }
        @{ Name = 'NotEmpty: an empty string fails'; Cond = @{ Key = 'a.empty'; NotEmpty = $true }; Met = $false }
        @{ Name = 'NotEmpty: an empty list fails'; Cond = @{ Key = 'a.list'; NotEmpty = $true }; Met = $false }
        @{ Name = 'NotEmpty: a list of items passes'; Cond = @{ Key = 'a.items'; NotEmpty = $true }; Met = $true }
        @{ Name = 'AnyItemHas: one item with the field passes'; Cond = @{ Key = 'a.items'; AnyItemHas = 'x' }; Met = $true }
        @{ Name = 'AnyItemHas: no item with the field fails'; Cond = @{ Key = 'a.items'; AnyItemHas = 'z' }; Met = $false }
        @{ Name = 'AnyNotEmpty: one key set passes'; Cond = @{ Keys = @('a.empty', 'a.text'); AnyNotEmpty = $true }; Met = $true }
        @{ Name = 'AnyNotEmpty: none set fails'; Cond = @{ Keys = @('a.empty', 'a.nope'); AnyNotEmpty = $true }; Met = $false }
    ) {
        (Test-AzlPostDeploymentCondition -Infrastructure $script:Doc -Condition $Cond).Met | Should -Be $Met
    }
    It 'a condition without an operator is an error' {
        { Test-AzlPostDeploymentCondition -Infrastructure $script:Doc -Condition @{ Key = 'a.flag' } } | Should -Throw '*no operator*'
    }
}

Describe 'Invoke-AzureLocalPostDeployment.ps1 (the entry script)' {
    It 'exits with the code of the run and writes the report, with the real table and a file that skips every step' {
        $file = New-Infra -Remove 'storage.volumes', 'storage.paths', 'storage.vm_images', 'networking.logical_networks', 'networking.network_security_groups', 'identity.active_directory.security_groups', 'cluster.witness', 'hardware.sbe' -Change @{ 'sdn.enabled' = $false; 'scenario.storage_architecture' = 's2d'; 'operations.post_cluster.skip_steps' = @('ssh', 'verification') }
        $log = Join-Path $TestDrive 'entry-log'
        $events = Join-Path $TestDrive 'entry-events.jsonl'
        $entry = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'Invoke-AzureLocalPostDeployment.ps1')
        $null = & pwsh -NoProfile -NonInteractive -File $entry -InfrastructureFile $file -LogPath $log -EventLogPath $events -SkipValidation 2>&1
        $LASTEXITCODE | Should -Be 0
        $report = Get-Content -LiteralPath (Join-Path $log 'report.json') -Raw | ConvertFrom-Json
        @($report.steps | Where-Object result -EQ 'Skipped').Count | Should -Be 13
        $events | Should -Exist
    }
}
