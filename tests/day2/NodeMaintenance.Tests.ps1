#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Day 2, stage 08 task 03: Invoke-NodeMaintenanceReboot.ps1 follows Microsoft Learn (Suspend and resume Azure Local machines for maintenance; Failover cluster maintenance
# procedures): check that it is safe, Suspend-ClusterNode -Drain, Remove-MocPhysicalNode, reboot, wait, Resume-ClusterNode, New-MocPhysicalNode, then wait for the storage
# repair jobs before the next node. Invoke-Command, Test-Connection, Start-Sleep and Get-Date are mocked: no cluster, no machine, no vault and no credential is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/day2/NodeMaintenance.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test credentials are random values made for the run.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock parameters mirror the commands they replace.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '08-day2-operations', 'task-03-node-maintenance', 'powershell', 'Invoke-NodeMaintenanceReboot.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))

    function New-TestSecret { [guid]::NewGuid().ToString('N') }
    function New-TestCredential([string]$User = 'user') { [pscredential]::new($User, (ConvertTo-SecureString -String (New-TestSecret) -AsPlainText -Force)) }
    function New-InfraFile {
        param([switch]$NoReference)
        $doc = [ordered]@{
            cluster  = [ordered]@{ name = 'iic-clus-01' }
            nodes    = @(1..2 | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.1$_" } } })
            identity = [ordered]@{
                local_admin      = [ordered]@{ username = 'azl-admin'; password = 'env://AZL_TEST_LOCAL_ADMIN' }
                active_directory = [ordered]@{
                    domain_fqdn = 'improbability.cloud'; netbios_name = 'IIC'
                    lcm_user = [ordered]@{ username = 'lcm-iic-01'; password = 'env://AZL_TEST_LCM' }
                }
            }
        }
        if ($NoReference) { $doc.identity.local_admin.Remove('password'); $doc.identity.active_directory.Remove('lcm_user') }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Cluster {
        $global:AzlNmCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlNmPings = 0
        $global:AzlNmNow = [datetime]'2026-01-01T00:00:00Z'
        $global:AzlNmSafe = @{ Problems = @(); MissingCmdlet = @(); NodeState = 'Up' }
        $global:AzlNmBootBefore = [datetime]'2025-12-31T00:00:00Z'
        $global:AzlNmBootAfter = [datetime]'2026-01-01T00:00:30Z'
        $global:AzlNmRestarted = $false
        $global:AzlNmRebootWorks = $true
        $global:AzlNmRestartFails = ''
        $global:AzlNmAlwaysUp = $false
        $global:AzlNmResumeMissing = @()
        $global:AzlNmSuspendState = 'Paused'
        $global:AzlNmStorageBusyReads = 0
        $global:AzlNmStorageReads = 0
        $global:AzlNmFinalState = 'Up'
        $global:AzlNmNeverBack = $false
    }
    function Get-Call([string]$Pattern) { @($global:AzlNmCalls | Where-Object { $_.Text -match $Pattern }) }
    function Invoke-Tool([hashtable]$Arguments, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script @Arguments -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script @Arguments 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Text     = (@($all | ForEach-Object { "$_" }) -join "`n")
            Result   = @($all | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['StorageRepair'] })
        }
    }
}

Describe 'Invoke-NodeMaintenanceReboot.ps1' {
    BeforeAll {
        $env:AZL_TEST_LOCAL_ADMIN = New-TestSecret
        $env:AZL_TEST_LCM = New-TestSecret
    }
    AfterAll {
        Remove-Item Env:AZL_TEST_LOCAL_ADMIN, Env:AZL_TEST_LCM -ErrorAction SilentlyContinue
        Remove-Variable -Name AzlNmBootBefore, AzlNmBootAfter, AzlNmRestarted, AzlNmRebootWorks, AzlNmRestartFails, AzlNmAlwaysUp, AzlNmCalls, AzlNmPings, AzlNmNow, AzlNmSafe, AzlNmResumeMissing, AzlNmSuspendState, AzlNmStorageBusyReads, AzlNmStorageReads, AzlNmFinalState, AzlNmNeverBack -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Reset-Cluster
        Mock Get-Date { if ($Format) { $global:AzlNmNow.ToString($Format) } else { $global:AzlNmNow } }
        Mock Start-Sleep { $global:AzlNmNow = $global:AzlNmNow.AddSeconds($Seconds) }
        Mock Test-Connection { $global:AzlNmPings++; if ($global:AzlNmAlwaysUp) { return $true }; (-not $global:AzlNmNeverBack) -and $global:AzlNmPings -gt 1 }
        Mock Invoke-Command {
            $text = $ScriptBlock.ToString()
            $global:AzlNmCalls.Add([pscustomobject]@{ Text = $text; Computer = [string]$ComputerName; Credential = $Credential; Arguments = @($ArgumentList) })
            switch -Regex ($text) {
                'LastBootUpTime' { if ($global:AzlNmRestarted) { return $global:AzlNmBootAfter } else { return $global:AzlNmBootBefore } }
                'MissingCmdlet' { return $global:AzlNmSafe }
                'Suspend-ClusterNode' { return $global:AzlNmSuspendState }
                'Remove-MocPhysicalNode -NodeName' { return }
                'Restart-Computer' { if ($global:AzlNmRebootWorks) { $global:AzlNmRestarted = $true }; if ($global:AzlNmRestartFails) { throw $global:AzlNmRestartFails }; return }
                'Resume-ClusterNode' { return }
                'New-MocPhysicalNode -NodeName' { return @('iic-n01', 'iic-n02') }
                'DrainStatus' { return [pscustomobject]@{ Name = 'iic-n01'; State = $global:AzlNmFinalState; DrainStatus = 'NotInitiated' } }
                'Jobs\s*=' {
                    $global:AzlNmStorageReads++
                    if ($global:AzlNmStorageReads -le $global:AzlNmStorageBusyReads) { return @{ Jobs = @('Repair Running 40%'); Disks = @('Mirror Warning/InService') } }
                    return @{ Jobs = @(); Disks = @() }
                }
                'Get-Command' { return $global:AzlNmResumeMissing }
                '\)\.State' { return 'Up' }
            }
            return $null
        }
    }

    Context 'the script text' {
        It 'carries the standard header and never asks a question' {
            $text = Get-Content -LiteralPath $script:Script -Raw
            $text | Should -Match '(?m)^#Requires -Version 7\.0'
            $text | Should -Match 'Set-StrictMode -Version Latest'
            $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $text | Should -Match 'SupportsShouldProcess'
            $text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|cluster_nodes|ConvertFrom-Yaml'
        }
    }

    Context 'values that are not usable (exit 2, nothing sent)' {
        It 'exits 2 when the infrastructure file is missing' {
            $r = Invoke-Tool @{ InfrastructureFile = (Join-Path $TestDrive 'missing.yml'); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'r1.log') }
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $global:AzlNmCalls.Count | Should -Be 0
        }

        It 'exits 2 and sends nothing when no credential can be built, and does not prompt' {
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile -NoReference); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'r2.log') }
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $global:AzlNmCalls.Count | Should -Be 0
        }
    }

    Context '-WhatIf' {
        It 'plans the work, finds the node by name, address and fully qualified name, and sends nothing' {
            foreach ($target in 'iic-n01', '192.0.2.11', 'iic-n01.improbability.cloud') {
                Reset-Cluster
                $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = $target; LogPath = (Join-Path $TestDrive 'w1.log') } -DryRun
                $r.Text | Should -Match 'Node resolved\s+: iic-n01 \(192\.0\.2\.11\)' -Because $target
                $r.Text | Should -Match 'Would check that it is safe'
                $r.Text | Should -Match 'Would suspend cluster node'
                $r.Text | Should -Match 'Remove-MocPhysicalNode'
                $r.Text | Should -Match 'storage repair jobs'
                $global:AzlNmCalls.Count | Should -Be 0
            }
        }

        It 'uses a node that is not in the file as it is' {
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'other-node'; LogPath = (Join-Path $TestDrive 'w2.log') } -DryRun
            $r.Text | Should -Match 'not found in config'
            $global:AzlNmCalls.Count | Should -Be 0
        }

        It 'plans a resume under -ResumeOnly without sending anything' {
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; ResumeOnly = $true; LogPath = (Join-Path $TestDrive 'w3.log') } -DryRun
            $r.Text | Should -Match 'Would resume cluster node'
            $r.Text | Should -Match 'New-MocPhysicalNode'
            $global:AzlNmCalls.Count | Should -Be 0
        }
    }

    Context 'the whole procedure' {
        It 'checks, suspends, removes from the VM configuration, reboots, resumes, adds back and waits for the storage, as the local administrator of the file' {
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'a1.log') }
            $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
            $order = @($global:AzlNmCalls | ForEach-Object { [regex]::Match($_.Text, 'MissingCmdlet|Suspend-ClusterNode|Remove-MocPhysicalNode -NodeName|Restart-Computer|Resume-ClusterNode|New-MocPhysicalNode -NodeName|Jobs\s*=').Value } | Where-Object { $_ })
            ($order | Select-Object -Unique)[0..5] | Should -Be @('MissingCmdlet', 'Suspend-ClusterNode', 'Remove-MocPhysicalNode -NodeName', 'Restart-Computer', 'Resume-ClusterNode', 'New-MocPhysicalNode -NodeName')
            $order[-1] | Should -Match 'Jobs'
            $global:AzlNmCalls[0].Computer | Should -Be '192.0.2.11'
            $global:AzlNmCalls[0].Credential.UserName | Should -Be '.\azl-admin'
            $r.Text | Should -Not -Match ([regex]::Escape($env:AZL_TEST_LOCAL_ADMIN))
            $r.Result[0].State | Should -Be 'Up'
            $r.Result[0].StorageRepair | Should -Be 'Repaired'
        }

        It 'resumes the node with the failback mode that was asked for' {
            $null = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; FailbackMode = 'NoFailback'; LogPath = (Join-Path $TestDrive 'a2.log') }
            (Get-Call 'Resume-ClusterNode')[0].Arguments | Should -Contain 'NoFailback'
        }

        It 'uses -Credential instead of the accounts of the file for every call' {
            $cred = New-TestCredential 'IIC\tester'
            $null = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; Credential = $cred; LogPath = (Join-Path $TestDrive 'a3.log') }
            @($global:AzlNmCalls | Where-Object { $_.Credential.UserName -ne 'IIC\tester' }).Count | Should -Be 0
        }

        It 'waits for the repair jobs to finish: it reads the storage again until no job and no unhealthy disk is left' {
            $global:AzlNmStorageBusyReads = 3
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'a4.log') }
            $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
            $global:AzlNmStorageReads | Should -Be 4
            Should -Invoke Start-Sleep -ParameterFilter { $Seconds -eq 30 } -Times 3
            $r.Result[0].StorageRepair | Should -Be 'Repaired'
            $r.Text | Should -Match 'Storage is repairing'
        }

        It 'exits 1 when the storage has not repaired when -StorageRepairTimeoutMinutes runs out, and says not to take another node offline' {
            $global:AzlNmStorageBusyReads = 9999
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; StorageRepairTimeoutMinutes = 2; StoragePollSeconds = 30; LogPath = (Join-Path $TestDrive 'a5.log') }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Do not take another node offline'
        }

        It 'does not wait for the storage with -StorageRepairTimeoutMinutes 0, and warns' {
            $global:AzlNmStorageBusyReads = 9999
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; StorageRepairTimeoutMinutes = 0; LogPath = (Join-Path $TestDrive 'a6.log') }
            $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
            $global:AzlNmStorageReads | Should -Be 0
            $r.Result[0].StorageRepair | Should -Be 'NotWaited'
            $r.Text | Should -Match 'Do not take another node offline'
        }
    }

    Context 'it stops before it changes anything (exit 1)' {
        It 'when <Case>' -ForEach @(
            @{ Case = 'another node is not Up'; Problem = 'iic-n02 is Down' }
            @{ Case = 'a virtual disk is not healthy'; Problem = 'virtual disk Mirror is Warning/InService' }
            @{ Case = 'a storage repair job is running'; Problem = 'storage job Repair is Running at 40 percent' }
        ) {
            $global:AzlNmSafe = @{ Problems = @($Problem); MissingCmdlet = @() }
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'b1.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'Not safe'
            (Get-Call 'Suspend-ClusterNode|Restart-Computer|Remove-MocPhysicalNode -NodeName').Count | Should -Be 0
        }

        It 'when the node does not have the Azure Local maintenance cmdlets' {
            $global:AzlNmSafe = @{ Problems = @(); MissingCmdlet = @('Remove-MocPhysicalNode') }
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'b2.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match '2311\.2'
            (Get-Call 'Suspend-ClusterNode|Restart-Computer').Count | Should -Be 0
        }

        It 'when the node is not Paused after the drain: it is not rebooted' {
            $global:AzlNmSuspendState = 'Up'
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'b3.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            (Get-Call 'Restart-Computer').Count | Should -Be 0
        }

        It 'when the node does not come back within the timeout' {
            $global:AzlNmNeverBack = $true
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; TimeoutSeconds = 60; LogPath = (Join-Path $TestDrive 'b4.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'did not come back'
            (Get-Call 'Resume-ClusterNode').Count | Should -Be 0
        }

        It 'when the node is not Up after the resume' {
            $global:AzlNmFinalState = 'Paused'
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'b5.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match "expected 'Up'"
        }
    }

    Context 'the switches' {
        It '-ResumeOnly resumes, adds the node back and waits for the storage, and does not suspend or reboot' {
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; ResumeOnly = $true; LogPath = (Join-Path $TestDrive 'c1.log') }
            $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
            (Get-Call 'Resume-ClusterNode').Count | Should -Be 1
            (Get-Call 'New-MocPhysicalNode -NodeName').Count | Should -Be 1
            (Get-Call 'Jobs\s*=').Count | Should -BeGreaterOrEqual 1
            (Get-Call 'Suspend-ClusterNode|Restart-Computer|MissingCmdlet').Count | Should -Be 0
        }

        It '-ResumeOnly stops when the node does not have New-MocPhysicalNode' {
            $global:AzlNmResumeMissing = @('New-MocPhysicalNode')
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; ResumeOnly = $true; LogPath = (Join-Path $TestDrive 'c2.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            (Get-Call 'Resume-ClusterNode').Count | Should -Be 0
        }

        It '-SkipResume leaves the node in maintenance: no resume, no VM configuration change, no storage wait, exit 0' {
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; SkipResume = $true; LogPath = (Join-Path $TestDrive 'c3.log') }
            $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
            (Get-Call 'Resume-ClusterNode|New-MocPhysicalNode -NodeName').Count | Should -Be 0
            (Get-Call 'Restart-Computer').Count | Should -Be 1
        }

        It '-SkipDrain on a node that is already Paused reboots it without the suspend and the VM configuration change, and still reads the node state and the storage first' {
            $global:AzlNmSafe.NodeState = 'Paused'
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; SkipDrain = $true; LogPath = (Join-Path $TestDrive 'c4.log') }
            $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
            (Get-Call 'MissingCmdlet').Count | Should -Be 1
            (Get-Call 'Suspend-ClusterNode|Remove-MocPhysicalNode -NodeName').Count | Should -Be 0
            (Get-Call 'Restart-Computer').Count | Should -Be 1
        }

        It '-SkipDrain refuses a node that is <State>: exit 1 and nothing is rebooted, suspended or resumed' -ForEach @(@{ State = 'Up' }, @{ State = 'Down' }, @{ State = '' }) {
            $global:AzlNmSafe.NodeState = $State
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; SkipDrain = $true; LogPath = (Join-Path $TestDrive 'c5.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'already Paused'
            (Get-Call 'Restart-Computer|Suspend-ClusterNode|Remove-MocPhysicalNode -NodeName|Resume-ClusterNode|New-MocPhysicalNode -NodeName').Count | Should -Be 0
        }

        It '-SkipDrain on a Paused node still stops when another node is not Up or a repair job is running' {
            $global:AzlNmSafe = @{ Problems = @('iic-n02 is Down'); MissingCmdlet = @(); NodeState = 'Paused' }
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; SkipDrain = $true; LogPath = (Join-Path $TestDrive 'c6.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'Not safe'
            (Get-Call 'Restart-Computer').Count | Should -Be 0
        }

        It '-SkipDrain does not ask for Remove-MocPhysicalNode, only for New-MocPhysicalNode (the node is resumed), and for nothing with -SkipResume' {
            $global:AzlNmSafe.NodeState = 'Paused'
            $null = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; SkipDrain = $true; LogPath = (Join-Path $TestDrive 'c7.log') }
            @((Get-Call 'MissingCmdlet')[0].Arguments[1]) | Should -Be @('New-MocPhysicalNode')
            Reset-Cluster
            $global:AzlNmSafe.NodeState = 'Paused'
            $null = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; SkipDrain = $true; SkipResume = $true; LogPath = (Join-Path $TestDrive 'c8.log') }
            @(@((Get-Call 'MissingCmdlet')[0].Arguments[1]) | Where-Object { $_ }).Count | Should -Be 0
        }
    }

    Context 'the reboot must be proven before the node is resumed' {
        It 'a restart command that fails with an unexpected error ends with exit 1, says the node stays Paused, and resumes nothing' {
            $global:AzlNmRestartFails = 'The RPC server is unavailable'
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'd1.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'Restart-Computer failed'
            $r.Text | Should -Match 'stays Paused'
            (Get-Call 'Resume-ClusterNode|New-MocPhysicalNode -NodeName').Count | Should -Be 0
        }

        It 'a connection that drops while the node restarts is expected and is not an error' {
            $global:AzlNmRestartFails = 'The network connection was closed'
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'd2.log') }
            $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
            $r.Text | Should -Match 'The node rebooted'
        }

        It 'a reboot that never happened (the node never goes offline and its boot time is the same) ends with exit 1 and the node is not resumed' {
            $global:AzlNmAlwaysUp = $true
            $global:AzlNmRebootWorks = $false
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'd3.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'no proof'
            (Get-Call 'Resume-ClusterNode|New-MocPhysicalNode -NodeName').Count | Should -Be 0
        }

        It 'a node that was seen offline but whose boot time did not change is not accepted as rebooted' {
            $global:AzlNmRebootWorks = $false
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'd4.log') }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            (Get-Call 'Resume-ClusterNode').Count | Should -Be 0
        }

        It 'a newer boot time is proof of the reboot even when the node was never seen offline' {
            $global:AzlNmAlwaysUp = $true
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'd5.log') }
            $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
            (Get-Call 'Resume-ClusterNode').Count | Should -Be 1
        }
    }

    Context 'what exit code 0 means with the documented opt-outs' {
        It 'the help says what exit 0 means for -SkipResume and for -StorageRepairTimeoutMinutes 0' {
            $help = Get-Help -Full $script:Script
            $description = ($help.description | Out-String)
            $description | Should -Match '(?s)-SkipResume\s+the node was rebooted and came back, and it is still Paused.*NOT resumed'
            $description | Should -Match '(?s)-StorageRepairTimeoutMinutes 0\s+the node was rebooted, resumed and is Up, but the storage repair was NOT waited for'
            $description | Should -Match 'Only a result with Resumed true and StorageRepair Repaired means that the next node is safe'
        }

        It '-SkipResume ends with exit 0, and the result says the node was not resumed' {
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; SkipResume = $true; LogPath = (Join-Path $TestDrive 'e1.log') }
            $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
            $r.Result[0].Resumed | Should -BeFalse
            $r.Result[0].StorageRepair | Should -Be 'NotWaited'
            $r.Text | Should -Match 'NOT resumed'
        }

        It 'a full run says Resumed and Repaired' {
            $r = Invoke-Tool @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'e2.log') }
            $r.Result[0].Resumed | Should -BeTrue
            $r.Result[0].StorageRepair | Should -Be 'Repaired'
        }
    }

    Context 'the master registry' {
        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $names = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Invoke_NodeMaintenanceReboot_ps1' } | ForEach-Object { $_.Node['name'] })
            $declared = @([System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null).ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            foreach ($p in $declared) { $names | Should -Contain $p -Because $p }
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'identity.local_admin.username', 'identity.local_admin.password', 'identity.active_directory.lcm_user.username', 'identity.active_directory.lcm_user.password', 'identity.active_directory.netbios_name', 'identity.active_directory.domain_fqdn', 'nodes[].name', 'nodes[].management.ip_address' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
