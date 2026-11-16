#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Day 2, stage 08 task 04: Invoke-ClusterOperations.ps1 reads cluster.name and nodes[] from infrastructure.yml and runs the cluster cmdlets on the cluster with PowerShell
# remoting. HealthCheck, Capacity and Alerts only read; MaintenanceMode, LiveMigrate and Rebalance change the cluster behind -WhatIf. Invoke-Command is mocked: no cluster,
# no machine and no credential is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/day2/ClusterOperations.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the cluster state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test credentials are random values made for the run.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '08-day2-operations', 'task-04-cluster-operations', 'powershell', 'Invoke-ClusterOperations.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))

    function New-InfraFile {
        param([switch]$NoCluster)
        $doc = [ordered]@{
            nodes    = @(1..3 | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.1$_" } } })
            identity = [ordered]@{ active_directory = [ordered]@{ domain_fqdn = 'improbability.cloud' } }
        }
        if (-not $NoCluster) { $doc.cluster = [ordered]@{ name = 'iic-clus-01' } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Cluster {
        $global:AzlOpCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlOpNodes = @(@{ Name = 'iic-n01'; State = 'Up'; DrainStatus = 'NotInitiated' }, @{ Name = 'iic-n02'; State = 'Up'; DrainStatus = 'NotInitiated' }, @{ Name = 'iic-n03'; State = 'Up'; DrainStatus = 'NotInitiated' })
        $global:AzlOpStorage = @{
            Pools = @(@{ Name = 'SU1_Pool'; Health = 'Healthy'; Operational = 'OK'; Size = 100TB; Allocated = 20TB })
            Disks = @(@{ Name = 'Infrastructure_1'; Health = 'Healthy'; Operational = 'OK' }, @{ Name = 'Volume1'; Health = 'Healthy'; Operational = 'OK' })
            Jobs  = @()
        }
        $global:AzlOpNetworks = @(@{ Name = 'Cluster Network 1'; State = 'Up' })
        $global:AzlOpArc = 'Connected'
        $global:AzlOpSuspendState = 'Paused'
        $global:AzlOpResumeState = 'Up'
        $global:AzlOpVmGroups = @('vm-a', 'vm-b', 'vm-c')
        $global:AzlOpVmOwners = @(@{ Name = 'vm-a'; Owner = 'iic-n01' }, @{ Name = 'vm-b'; Owner = 'iic-n01' }, @{ Name = 'vm-c'; Owner = 'iic-n01' }, @{ Name = 'vm-d'; Owner = 'iic-n02' })
        $global:AzlOpCsv = @(@{ Name = 'Volume1'; Owner = 'iic-n01' }, @{ Name = 'Volume2'; Owner = 'iic-n01' }, @{ Name = 'Volume3'; Owner = 'iic-n01' })
        $global:AzlOpFaults = @{ Faults = @(); Actions = @(); Events = @() }
        $global:AzlOpFail = ''
        $global:AzlOpMocMissing = @()
    }
    function Get-Call([string]$Pattern) { @($global:AzlOpCalls | Where-Object { $_.Text -match $Pattern }) }
    function Invoke-Operation([string]$File, [hashtable]$Extra = @{}, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] -and $_ -isnot [string] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Invoke-ClusterOperations.ps1' {
    AfterAll { Remove-Variable -Name AzlOpMocMissing, AzlOpCalls, AzlOpNodes, AzlOpStorage, AzlOpNetworks, AzlOpArc, AzlOpSuspendState, AzlOpResumeState, AzlOpVmGroups, AzlOpVmOwners, AzlOpCsv, AzlOpFaults, AzlOpFail -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-Cluster
        Mock Invoke-Command {
            $text = $ScriptBlock.ToString()
            $global:AzlOpCalls.Add([pscustomobject]@{ Text = $text; Computer = [string]$ComputerName; Credential = $Credential; Arguments = @($ArgumentList) })
            if ($global:AzlOpFail -and $text -match $global:AzlOpFail) { throw "simulated failure of $($global:AzlOpFail)" }
            switch -Regex ($text) {
                'Get-Command' { return $global:AzlOpMocMissing }
                'Suspend-ClusterNode' { return $global:AzlOpSuspendState }
                'Resume-ClusterNode' { return $global:AzlOpResumeState }
                'Remove-MocPhysicalNode' { return @('iic-n02', 'iic-n03') }
                'New-MocPhysicalNode' { return @('iic-n01', 'iic-n02', 'iic-n03') }
                'Move-ClusterVirtualMachineRole' { return }
                'Move-ClusterSharedVolume' { return }
                'Get-ClusterNode -Name \$Node' { return $global:AzlOpVmGroups }
                'OwnerNode.*Owner|Owner = .*OwnerNode' { if ($text -match 'Get-ClusterSharedVolume') { return $global:AzlOpCsv } else { return $global:AzlOpVmOwners } }
                'Get-ClusterSharedVolume' { return $global:AzlOpCsv }
                'Get-StoragePool' { return $global:AzlOpStorage }
                'Get-ClusterNetwork' { return $global:AzlOpNetworks }
                'azcmagent' { return $global:AzlOpArc }
                'Win32_OperatingSystem' { return @{ VmCount = 4; TotalMemoryGB = 256.0; AssignedMemoryGB = 64.0; LogicalProcessors = 64; AssignedVcpu = 16 } }
                'Debug-StorageSubSystem' { return $global:AzlOpFaults }
                'Get-ClusterNode \| ForEach-Object' { return $global:AzlOpNodes }
            }
            return $null
        }
    }

    Context 'values that are not usable (exit 2, nothing sent)' {
        It 'ends with exit code 2 when cluster.name is missing' {
            $r = Invoke-Operation (New-InfraFile -NoCluster) @{ Action = 'HealthCheck' }
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'cluster.name is missing'
            $global:AzlOpCalls.Count | Should -Be 0
        }

        It 'ends with exit code 2 when <Action> has no -NodeName' -ForEach @(@{ Action = 'MaintenanceMode' }, @{ Action = 'LiveMigrate' }) {
            $r = Invoke-Operation (New-InfraFile) @{ Action = $Action }
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'needs -NodeName'
            $global:AzlOpCalls.Count | Should -Be 0
        }

        It 'with -RequireNodeInFile, ends with exit code 2 for a node that is not in nodes[] and sends nothing' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n09'; Enable = $true; RequireNodeInFile = $true }
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match "Node 'iic-n09' is not a node of nodes\[\]"
            $global:AzlOpCalls.Count | Should -Be 0
        }

        It 'with -RequireNodeInFile, a node of nodes[] (by name, address or fully qualified name) goes on as before' -ForEach @(@{ Name = 'iic-n01' }, @{ Name = '192.0.2.12' }, @{ Name = 'iic-n03.improbability.cloud' }) {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = $Name; Enable = $true; RequireNodeInFile = $true } -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
        }

        It 'the script has the switch, and without it a node outside the file is still used as it is' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Match '\[switch\]\$RequireNodeInFile'
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n09'; Enable = $true } -DryRun
            $r.Text | Should -Match 'not in nodes\[\] of the file: it is used as it is'
        }

        It 'ends with exit code 2 for a file that does not exist' {
            (Invoke-Operation (Join-Path $TestDrive 'nowhere.yml') @{ Action = 'HealthCheck' }).ExitCode | Should -Be 2
        }
    }

    Context 'HealthCheck (read only)' {
        It 'reports a healthy cluster and exits 0' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'HealthCheck' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -NE 'Healthy').Count | Should -Be 0
            ($r.Rows | Where-Object Item -EQ 'Cluster nodes').Detail | Should -Match '3 of 3 nodes are Up'
            @($r.Rows | Where-Object Item -Like 'Azure Arc agent on *').Count | Should -Be 3
            $global:AzlOpCalls[0].Computer | Should -Be 'iic-clus-01'
        }

        It 'changes nothing: it runs none of the cmdlets that change the cluster' {
            $null = Invoke-Operation (New-InfraFile) @{ Action = 'HealthCheck' }
            (Get-Call 'Suspend-ClusterNode|Resume-ClusterNode|Move-Cluster|MocPhysicalNode').Count | Should -Be 0
        }

        It 'exits 1 for <Case>' -ForEach @(
            @{ Case = 'a node that is not Up'; Set = { $global:AzlOpNodes[2].State = 'Down' }; Item = 'Cluster nodes' }
            @{ Case = 'a virtual disk that is not healthy'; Set = { $global:AzlOpStorage.Disks[1].Health = 'Warning' }; Item = 'Virtual disks' }
            @{ Case = 'a storage pool that is not healthy'; Set = { $global:AzlOpStorage.Pools[0].Health = 'Unhealthy' }; Item = 'Storage pools' }
            @{ Case = 'a storage repair job that is running'; Set = { $global:AzlOpStorage.Jobs = @(@{ Name = 'Repair'; State = 'Running'; Percent = 40 }) }; Item = 'Storage repair jobs' }
            @{ Case = 'a cluster network that is down'; Set = { $global:AzlOpNetworks = @(@{ Name = 'n'; State = 'Down' }) }; Item = 'Cluster networks' }
            @{ Case = 'an Arc agent that is not connected'; Set = { $global:AzlOpArc = 'Disconnected' }; Item = 'Azure Arc agent on iic-n01' }
        ) {
            & $Set
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'HealthCheck' }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            ($r.Rows | Where-Object Item -EQ $Item).Action | Should -Be 'Warning'
        }

        It 'exits 1 when the cluster cannot be read' {
            $global:AzlOpFail = 'Get-ClusterNode \| ForEach-Object'
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'HealthCheck' }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'simulated failure'
        }

        It 'writes the rows as JSON with -OutputPath' {
            $out = Join-Path $TestDrive 'reports/health.json'
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'HealthCheck'; OutputPath = $out }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $json = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $json.Action | Should -Be 'HealthCheck'
            $json.Cluster | Should -Be 'iic-clus-01'
            @($json.Rows).Count | Should -BeGreaterThan 3
        }
    }

    Context 'MaintenanceMode -Enable' {
        It 'checks, drains the node (Suspend-ClusterNode -Drain -Wait) and removes it from the VM configuration, in that order, with the node from the file' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01.improbability.cloud'; Enable = $true }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'Suspend-ClusterNode')[0].Text | Should -Match 'Suspend-ClusterNode -Name \$Name -Drain -Wait'
            (Get-Call 'Suspend-ClusterNode')[0].Arguments | Should -Contain 'iic-n01'
            (Get-Call 'Suspend-ClusterNode')[0].Computer | Should -Be 'iic-clus-01'
            (Get-Call 'Remove-MocPhysicalNode -NodeName')[0].Computer | Should -Be 'iic-n01'
            $order = @($global:AzlOpCalls | ForEach-Object { [regex]::Match($_.Text, 'Suspend-ClusterNode|Remove-MocPhysicalNode -NodeName').Value } | Where-Object { $_ })
            $order | Should -Be @('Suspend-ClusterNode', 'Remove-MocPhysicalNode -NodeName')
            @($r.Rows | ForEach-Object Action) | Should -Contain 'Suspended'
        }

        It 'finds the node by its management address as well' {
            $null = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = '192.0.2.12'; Enable = $true }
            (Get-Call 'Suspend-ClusterNode')[0].Arguments | Should -Contain 'iic-n02'
        }

        It 'plans under -WhatIf: it reads, and changes nothing' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01'; Enable = $true } -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'Suspend-ClusterNode|Remove-MocPhysicalNode -NodeName|Resume-ClusterNode').Count | Should -Be 0
            $r.Rows[-1].Action | Should -Be 'WouldSuspend'
        }

        It 'does not drain when <Case>, and exits 1' -ForEach @(
            @{ Case = 'another node is not Up'; Set = { $global:AzlOpNodes[1].State = 'Down' } }
            @{ Case = 'a virtual disk is not healthy'; Set = { $global:AzlOpStorage.Disks[0].Health = 'Warning' } }
            @{ Case = 'a storage repair job is running'; Set = { $global:AzlOpStorage.Jobs = @(@{ Name = 'Repair'; State = 'Running'; Percent = 10 }) } }
        ) {
            & $Set
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01'; Enable = $true }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'Not safe'
            (Get-Call 'Suspend-ClusterNode').Count | Should -Be 0
        }

        It 'refuses before it changes anything when the node lacks <Missing>: no drain, also under -WhatIf, exit 1' -ForEach @(
            @{ Missing = 'Remove-MocPhysicalNode'; DryRun = $false }
            @{ Missing = 'New-MocPhysicalNode'; DryRun = $false }
            @{ Missing = 'Remove-MocPhysicalNode'; DryRun = $true }
        ) {
            $global:AzlOpMocMissing = @($Missing)
            $r = if ($DryRun) { Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01'; Enable = $true } -DryRun } else { Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01'; Enable = $true } }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match ([regex]::Escape($Missing))
            $r.Text | Should -Match '2311\.2'
            (Get-Call 'Suspend-ClusterNode|Remove-MocPhysicalNode -NodeName|Resume-ClusterNode').Count | Should -Be 0
            (Get-Call 'Get-Command')[0].Computer | Should -Be 'iic-n01'
        }

        It 'stops when the node is not Paused after the drain, and does not remove it from the VM configuration' {
            $global:AzlOpSuspendState = 'Up'
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01'; Enable = $true }
            $r.ExitCode | Should -Be 1
            (Get-Call 'Remove-MocPhysicalNode -NodeName').Count | Should -Be 0
        }

        It 'ends with exit code 1 when the drain fails' {
            $global:AzlOpFail = 'Suspend-ClusterNode'
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01'; Enable = $true }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'simulated failure'
        }

        It 'refuses a node that the cluster does not have' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n09'; Enable = $true }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match "no node 'iic-n09'"
            $r.Text | Should -Match 'not in nodes\[\]'
        }
    }

    Context 'MaintenanceMode (leave)' {
        It 'resumes the node with failback, adds it to the VM configuration, and reports the storage' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'Resume-ClusterNode')[0].Text | Should -Match 'Failback Immediate'
            (Get-Call 'New-MocPhysicalNode -NodeName')[0].Computer | Should -Be 'iic-n01'
            ($r.Rows | Where-Object Item -EQ 'Storage').Action | Should -Be 'Healthy'
        }

        It 'does not resume the node when it lacks New-MocPhysicalNode: exit 1, nothing resumed' {
            $global:AzlOpMocMissing = @('New-MocPhysicalNode')
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01' }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'New-MocPhysicalNode'
            (Get-Call 'Resume-ClusterNode').Count | Should -Be 0
        }

        It 'warns that another node must wait while a repair job runs' {
            $global:AzlOpStorage.Jobs = @(@{ Name = 'Repair'; State = 'Running'; Percent = 5 })
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01' }
            $r.ExitCode | Should -Be 0
            $storage = $r.Rows | Where-Object Item -EQ 'Storage'
            $storage.Action | Should -Be 'Warning'
            $storage.Detail | Should -Match 'Do not take another node offline'
        }

        It 'plans under -WhatIf and resumes nothing' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01' } -DryRun
            (Get-Call 'Resume-ClusterNode|New-MocPhysicalNode -NodeName').Count | Should -Be 0
            $r.Rows[-1].Action | Should -Be 'WouldResume'
        }

        It 'ends with exit code 1 when the node is not Up after the resume' {
            $global:AzlOpResumeState = 'Paused'
            (Invoke-Operation (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-n01' }).ExitCode | Should -Be 1
            (Get-Call 'New-MocPhysicalNode -NodeName').Count | Should -Be 0
        }
    }

    Context 'LiveMigrate' {
        It 'moves every clustered VM of the node, live, to the other node with the fewest VMs' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'LiveMigrate'; NodeName = 'iic-n01' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $moves = @(Get-Call 'Move-ClusterVirtualMachineRole')
            $moves.Count | Should -Be 3
            $moves[0].Text | Should -Match '-MigrationType Live'
            $moves[0].Arguments[1] | Should -Be 'iic-n03' -Because 'iic-n03 has no VM, iic-n02 has one'
            @($moves | ForEach-Object { $_.Arguments[0] }) | Should -Be @('vm-a', 'vm-b', 'vm-c')
            (Get-Call 'Move-VM\b').Count | Should -Be 0
        }

        It 'moves nothing under -WhatIf' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'LiveMigrate'; NodeName = 'iic-n01' } -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'Move-ClusterVirtualMachineRole').Count | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'WouldMigrate').Count | Should -Be 3
        }

        It 'says so when the node owns no VM' {
            $global:AzlOpVmGroups = @()
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'LiveMigrate'; NodeName = 'iic-n01' }
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Detail | Should -Match 'no clustered virtual machine'
        }

        It 'ends with exit code 1 when no other node is Up' {
            $global:AzlOpNodes[1].State = 'Down'; $global:AzlOpNodes[2].State = 'Down'
            (Invoke-Operation (New-InfraFile) @{ Action = 'LiveMigrate'; NodeName = 'iic-n01' }).ExitCode | Should -Be 1
            (Get-Call 'Move-ClusterVirtualMachineRole').Count | Should -Be 0
        }

        It 'goes on after a failed move and ends with exit code 1' {
            $global:AzlOpFail = 'Move-ClusterVirtualMachineRole'
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'LiveMigrate'; NodeName = 'iic-n01' }
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed').Count | Should -Be 3
        }
    }

    Context 'Rebalance' {
        It 'moves volumes from the node that owns more than its share to the nodes with fewer' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'Rebalance' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $moves = @(Get-Call 'Move-ClusterSharedVolume')
            $moves.Count | Should -Be 2
            @($moves | ForEach-Object { $_.Arguments[1] } | Sort-Object) | Should -Be @('iic-n02', 'iic-n03')
        }

        It 'moves nothing when ownership is balanced, and nothing under -WhatIf' {
            $global:AzlOpCsv = @(@{ Name = 'Volume1'; Owner = 'iic-n01' }, @{ Name = 'Volume2'; Owner = 'iic-n02' }, @{ Name = 'Volume3'; Owner = 'iic-n03' })
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'Rebalance' }
            $r.ExitCode | Should -Be 0
            (Get-Call 'Move-ClusterSharedVolume').Count | Should -Be 0
            $r.Rows[-1].Detail | Should -Match 'balanced'
            Reset-Cluster
            $null = Invoke-Operation (New-InfraFile) @{ Action = 'Rebalance' } -DryRun
            (Get-Call 'Move-ClusterSharedVolume').Count | Should -Be 0
        }
    }

    Context 'Rebalance ownership (the floor and the ceiling of volumes per node)' {
        It 'moves one volume to the node that owns none when ownership is <Owners> (the old share of ceiling(n/m) moved nothing for 2, 2, 0)' -ForEach @(
            @{ Owners = @('iic-n01', 'iic-n01', 'iic-n02', 'iic-n02'); Moves = 1; To = @('iic-n03') }
            @{ Owners = @('iic-n01', 'iic-n01', 'iic-n01', 'iic-n01', 'iic-n02'); Moves = 2; To = @('iic-n02', 'iic-n03') }
            @{ Owners = @('iic-n01', 'iic-n01', 'iic-n02', 'iic-n02', 'iic-n03', 'iic-n03', 'iic-n03', 'iic-n03'); Moves = 1; To = @('iic-n01') }
        ) {
            $global:AzlOpCsv = @(for ($i = 0; $i -lt $Owners.Count; $i++) { @{ Name = "Volume$($i + 1)"; Owner = $Owners[$i] } })
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'Rebalance' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $issued = @(Get-Call 'Move-ClusterSharedVolume')
            $issued.Count | Should -Be $Moves
            @($issued | ForEach-Object { $_.Arguments[1] } | Sort-Object) | Should -Be $To
            @($r.Rows | Where-Object Action -EQ 'Moved').Count | Should -Be $Moves
        }

        It 'reports what it would move under -WhatIf for 2, 2, 0 and changes nothing' {
            $global:AzlOpCsv = @(@{ Name = 'V1'; Owner = 'iic-n01' }, @{ Name = 'V2'; Owner = 'iic-n01' }, @{ Name = 'V3'; Owner = 'iic-n02' }, @{ Name = 'V4'; Owner = 'iic-n02' })
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'Rebalance' } -DryRun
            (Get-Call 'Move-ClusterSharedVolume').Count | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'WouldMove').Count | Should -Be 1
        }

        It 'moves nothing when the counts differ by one at most: <Owners>' -ForEach @(
            @{ Owners = @('iic-n01', 'iic-n02', 'iic-n03') }
            @{ Owners = @('iic-n01', 'iic-n01', 'iic-n02', 'iic-n03') }
            @{ Owners = @('iic-n01', 'iic-n01', 'iic-n02', 'iic-n02', 'iic-n03') }
        ) {
            $global:AzlOpCsv = @(for ($i = 0; $i -lt $Owners.Count; $i++) { @{ Name = "Volume$($i + 1)"; Owner = $Owners[$i] } })
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'Rebalance' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'Move-ClusterSharedVolume').Count | Should -Be 0
            $r.Rows[-1].Detail | Should -Match 'balanced'
        }

        It 'stops after a failed move and ends with exit code 1' {
            $global:AzlOpFail = 'Move-ClusterSharedVolume'
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'Rebalance' }
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed').Count | Should -Be 1
            @($r.Rows | Where-Object Detail -Match 'balanced').Count | Should -Be 0 -Because 'a failed first move is not "balanced"'
        }
    }

    Context 'Capacity and Alerts (read only)' {
        It 'Capacity reports the pools and every node that is Up, and changes nothing' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'Capacity' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            ($r.Rows | Where-Object Item -EQ 'Storage pool SU1_Pool').Detail | Should -Match '20 percent'
            @($r.Rows | Where-Object Item -Like 'Node iic-n0*').Count | Should -Be 3
            (Get-Call 'Suspend-ClusterNode|Move-Cluster').Count | Should -Be 0
        }

        It 'Capacity warns about a pool that is 85 percent full' {
            $global:AzlOpStorage.Pools[0].Allocated = 90TB
            ((Invoke-Operation (New-InfraFile) @{ Action = 'Capacity' }).Rows | Where-Object Item -EQ 'Storage pool SU1_Pool').Action | Should -Be 'Warning'
        }

        It 'Alerts exits 0 and says so when there is nothing' {
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'Alerts' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Healthy'
        }

        It 'Alerts exits 1 with a Health Service fault, a storage health action or a cluster event' {
            $global:AzlOpFaults = @{
                Faults  = @(@{ Severity = 'Critical'; Reason = 'The physical disk failed'; Target = 'Disk 3' })
                Actions = @(@{ State = 'Running'; Description = 'Disk 3'; Reason = 'Retire' })
                Events  = @(@{ Time = '2026-01-01T00:00:00'; Level = 2; Message = 'Cluster node was removed' })
            }
            $r = Invoke-Operation (New-InfraFile) @{ Action = 'Alerts' }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            @($r.Rows).Count | Should -Be 3
            $r.Rows[0].Action | Should -Be 'Critical'
        }
    }

    Context 'the credential and the script text' {
        It 'passes -Credential on to every remote call' {
            $cred = [pscredential]::new('IIC\tester', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString('N')) -AsPlainText -Force))
            $null = Invoke-Operation (New-InfraFile) @{ Action = 'HealthCheck'; Credential = $cred }
            @($global:AzlOpCalls | Where-Object { $_.Credential.UserName -ne 'IIC\tester' }).Count | Should -Be 0
        }

        It 'takes -InfrastructureFile (mandatory) and no -ClusterName, has the standard header and never prompts' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
            $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $names | Should -Contain 'InfrastructureFile'
            $names | Should -Not -Contain 'ClusterName'
            $text = Get-Content -LiteralPath $script:Script -Raw
            $text | Should -Match '(?m)^#Requires -Version 7\.0'
            $text | Should -Match 'Set-StrictMode -Version Latest'
            $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $text | Should -Match 'SupportsShouldProcess'
            $text | Should -Not -Match 'Read-Host|Get-Credential'
            $text | Should -Not -Match 'AutoReplace'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $names = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Invoke_ClusterOperations_ps1' } | ForEach-Object { $_.Node['name'] })
            $declared = @([System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null).ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            foreach ($p in $declared) { $names | Should -Contain $p -Because $p }
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'cluster.name', 'nodes[].name', 'nodes[].management.ip_address', 'identity.active_directory.domain_fqdn' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
