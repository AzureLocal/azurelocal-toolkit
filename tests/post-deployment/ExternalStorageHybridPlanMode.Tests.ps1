#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 10 (enable external storage, hybrid): Invoke-ExternalStorageHybrid-Orchestrated.ps1 runs ALONE, with only its own parameters, against
# the toolkit example file, and plans: it checks the design and the instance (read only), and runs the step scripts of the page with -WhatIf. The orchestrator is copied into a
# tree under TestDrive with fake step scripts (the real ones are tested on their own: Set-AzureLocalNodeConfiguration, New-SanVolume, New-StoragePath, the reboot script);
# Invoke-Command is a fake. No cluster, no machine and no Azure is used. The file is config/variables/examples/infrastructure.example.yml, as it is (storage architecture
# s2d: nothing to attach), and with the hybrid values added in memory.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/ExternalStorageHybridPlanMode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body and the fake steps run in other scopes; a global is how the test hands them the state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    Import-Module powershell-yaml
    function az { $global:LASTEXITCODE = 1 }
    $script:PasswordVariable = 'AZL_TEST_HYB_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($script:PasswordVariable, [guid]::NewGuid().ToString())

    $root = Join-Path $TestDrive 'tree'
    foreach ($m in 'infrastructure', 'secrets', 'remoting') { Copy-Item -Recurse -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Destination ([IO.Path]::Combine($root, 'scripts', 'common', $m)) }
    $deploy = [IO.Path]::Combine($root, 'scripts', 'deploy')
    $task = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-06-post-deployment', 'task-10-enable-external-storage-hybrid', 'powershell')
    New-Item -ItemType Directory -Path $task -Force | Out-Null
    Copy-Item -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-10-enable-external-storage-hybrid', 'powershell', 'Invoke-ExternalStorageHybrid-Orchestrated.ps1')) -Destination $task
    $fake = @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$InfrastructureFile, [string[]]$Step, [switch]$NoRestart, [switch]$Execute, [pscredential]$Credential, [string]$TargetNode, [string]$LogPath)
$name = Split-Path -Leaf $PSCommandPath
$global:AzlHybSteps.Add([pscustomobject]@{ Name = $name; Step = ($Step -join ','); Execute = [bool]$Execute; WhatIf = [bool]$WhatIfPreference })
exit 0
'@
    foreach ($p in @(
            [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-03-os-configuration', 'Set-AzureLocalNodeConfiguration.ps1')
            [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-SanVolume.ps1')
            [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-StoragePath.ps1')
            [IO.Path]::Combine($deploy, '08-day2-operations', 'task-03-node-maintenance', 'powershell', 'Invoke-NodeMaintenanceReboot.ps1'))) {
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        Set-Content -LiteralPath $p -Value $fake
    }
    $script:This = Join-Path $task 'Invoke-ExternalStorageHybrid-Orchestrated.ps1'

    function New-PlanFile {
        param([switch]$Hybrid, [scriptblock]$Edit)
        $doc = ConvertFrom-Yaml -Ordered (Get-Content -LiteralPath $script:Example -Raw)
        if ($Hybrid) {
            $doc.scenario.storage_architecture = 'hybrid'
            $doc.storage.san = [ordered]@{ type = 'iscsi' }
            $doc.identity.active_directory.lcm_user.password = "env://$($script:PasswordVariable)"
        }
        if ($Edit) { & $Edit $doc }
        $file = Join-Path $TestDrive "plan-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Alone([hashtable]$Extra, [string]$File) {
        $global:LASTEXITCODE = $null
        $all = & $script:This -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Rows = @($all | Where-Object { $_.PSObject.Properties['Step'] -and $_.PSObject.Properties['Result'] }); Text = (@($all | ForEach-Object { "$_" }) -join "`n") }
    }
}

Describe 'Invoke-ExternalStorageHybrid-Orchestrated.ps1 runs alone in Plan mode' {
    AfterAll {
        Remove-Variable -Name AzlHybSteps, AzlHybState, AzlHybRemote -Scope Global -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable($script:PasswordVariable, $null)
    }
    BeforeEach {
        $global:AzlHybSteps = [System.Collections.Generic.List[object]]::new()
        $global:AzlHybRemote = [System.Collections.Generic.List[string]]::new()
        $global:AzlHybState = @{ Computer = 'IIC-N01'; SolutionVersion = '12.2611.1004.9'; RunningUpdates = @(); Cluster = 'iic-azl-01'; Initiators = @('iSCSI IQN iqn.1991-05.com.microsoft:iic-azl-n01') }
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlHybRemote.Add($step)
            switch ($step) { 'ReadState' { $global:AzlHybState.Clone() } 'ValidateStore' { @{ Report = 'report.htm' } } }
        }
    }

    It 'takes -InfrastructureFile as its only mandatory parameter, and -WhatIf and -LogPath' {
        $command = Get-Command -Name $script:This
        @($command.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory } } | ForEach-Object Name) | Should -Be @('InfrastructureFile')
        $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        $command.Parameters.ContainsKey('LogPath') | Should -BeTrue
        @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters -and $_ -notin 'InfrastructureFile', 'LogPath' } | Sort-Object) |
            Should -Be @('ComputerName', 'Credential', 'RollingRestart', 'ValidateStorage')
    }

    It 'plans against the toolkit example as it is, alone: the example is s2d, so there is no SAN to attach: exit 0, no node is asked, no step runs' {
        $r = Invoke-Alone @{} (New-PlanFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Text | Should -Match 'no external SAN to attach'
        $global:AzlHybRemote.Count | Should -Be 0
        $global:AzlHybSteps.Count | Should -Be 0
    }

    It 'plans against the example with the hybrid values added, alone: exit 0, the node is read, every step runs with -WhatIf and none executes, no restart and no Test-Cluster' {
        $log = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
        $r = Invoke-Alone @{ LogPath = $log; RollingRestart = $true; ValidateStorage = $true } (New-PlanFile -Hybrid)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlHybRemote | Select-Object -Unique) | Should -Be @('ReadState')
        @($global:AzlHybSteps | ForEach-Object { if ($_.Step) { "$($_.Name)|$($_.Step)" } else { $_.Name } }) | Should -Be @('Set-AzureLocalNodeConfiguration.ps1|Mpio', 'Set-AzureLocalNodeConfiguration.ps1|SanVerify', 'New-SanVolume.ps1', 'New-StoragePath.ps1')
        ($global:AzlHybSteps | Where-Object Step -EQ 'Mpio').Execute | Should -BeFalse
        @($global:AzlHybSteps | Where-Object Name -EQ 'Invoke-NodeMaintenanceReboot.ps1').Count | Should -Be 0
        (Get-Content -LiteralPath $log -Raw).Trim() | Should -Not -BeNullOrEmpty
    }

    It 'reads operations.post_cluster.allow_node_restarts itself (no switch passed): the plan says the restarts would run, and still restarts nothing; without the key it says they are not approved' {
        $r = Invoke-Alone @{} (New-PlanFile -Hybrid -Edit { param($doc) $doc.operations = [ordered]@{ post_cluster = [ordered]@{ allow_node_restarts = $true } } })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Text | Should -Match 'drain, restart, resume'
        $r2 = Invoke-Alone @{} (New-PlanFile -Hybrid)
        $r2.Text | Should -Match 'not approved'
        @($global:AzlHybSteps | Where-Object Name -EQ 'Invoke-NodeMaintenanceReboot.ps1').Count | Should -Be 0
    }

    It 'prints the initiator identifiers of the nodes for the storage administrator, and lists Test-Cluster -Include Storage as not selected, or as planned with -ValidateStorage (never run in Plan mode)' {
        $r = Invoke-Alone @{} (New-PlanFile -Hybrid)
        $r.Text | Should -Match 'iSCSI IQN iqn\.1991-05\.com\.microsoft:iic-azl-n01'
        $r.Text | Should -Match 'not selected'
        $r.Text | Should -Not -Match 'would run on'
        (Invoke-Alone @{ ValidateStorage = $true } (New-PlanFile -Hybrid)).Text | Should -Match 'would run on'
        $global:AzlHybRemote | Should -Not -Contain 'ValidateStore'
    }

    It 'checks its own preconditions: a solution before 2604, a running update, and a machine that is not in a cluster each stop it with exit 1 before any step' {
        $global:AzlHybState.SolutionVersion = '11.2601.1001.5'
        (Invoke-Alone @{} (New-PlanFile -Hybrid)).ExitCode | Should -Be 1
        $global:AzlHybState.SolutionVersion = '12.2611.1004.9'; $global:AzlHybState.RunningUpdates = @('12.2611.1004.9 Installing')
        (Invoke-Alone @{} (New-PlanFile -Hybrid)).ExitCode | Should -Be 1
        $global:AzlHybState.RunningUpdates = @(); $global:AzlHybState.Cluster = ''
        (Invoke-Alone @{} (New-PlanFile -Hybrid)).ExitCode | Should -Be 1
        $global:AzlHybSteps.Count | Should -Be 0
    }

    It 'stops with exit code 2 for a rack aware instance, a SAN-only design, a missing SAN type, and when there is no login, and asks no node' {
        (Invoke-Alone @{} (New-PlanFile -Hybrid -Edit { param($doc) $doc.scenario.topology = 'rack_aware' })).ExitCode | Should -Be 2
        (Invoke-Alone @{} (New-PlanFile -Hybrid -Edit { param($doc) $doc.scenario.storage_architecture = 'san' })).ExitCode | Should -Be 2
        (Invoke-Alone @{} (New-PlanFile -Hybrid -Edit { param($doc) $doc.storage.san.Remove('type') })).ExitCode | Should -Be 2
        (Invoke-Alone @{} (New-PlanFile -Hybrid -Edit { param($doc) $doc.identity.active_directory.lcm_user.password = 'keyvault://kv-iic-mgmt-01/lcm-password' })).ExitCode | Should -Be 2
        $global:AzlHybRemote.Count | Should -Be 0
        $global:AzlHybSteps.Count | Should -Be 0
    }
}
