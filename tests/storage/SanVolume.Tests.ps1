#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 05: New-SanVolume.ps1 turns the SAN LUNs of storage.san.luns into NTFS Cluster Shared Volumes. Invoke-Command is mocked and the
# remote PrepareDisk block is run against stub storage cmdlets: no cluster, no SAN, no disk and no credential is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/storage/SanVolume.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the cluster state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub functions keep the parameters of the cmdlets they stand for.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-SanVolume.ps1')
    Import-Module powershell-yaml

    function New-Id { [guid]::NewGuid().ToString('N').ToUpperInvariant() }
    function New-Lun([hashtable]$Override = @{}) {
        $l = [ordered]@{ name = 'san-vol-01'; unique_id = $script:IdA; size_gib = 1024 }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $l.Remove($k) } else { $l[$k] = $Override[$k] } }
        $l
    }
    function New-InfraFile {
        param([object[]]$Luns = @((New-Lun)), [string]$Architecture = 'hybrid', [string]$Type = 'fibre_channel', [string]$Cluster = 'iic-cluster-01', [hashtable]$San = @{})
        $doc = [ordered]@{ scenario = [ordered]@{ storage_architecture = $Architecture }; cluster = [ordered]@{}; storage = [ordered]@{ san = [ordered]@{} } }
        if ($Cluster) { $doc.cluster.name = $Cluster }
        if ($Type) { $doc.storage.san.type = $Type }
        if ($Luns) { $doc.storage.san.luns = @($Luns) }
        foreach ($k in $San.Keys) { $doc.storage.san[$k] = $San[$k] }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    # One SAN disk as ReadState returns it.
    function New-Disk([string]$UniqueId, [int]$Number = 3, [int]$Paths = 2, [string]$Style = 'RAW', [int]$Partitions = 0, [string]$Bus = 'Fibre Channel', [long]$SizeGib = 1024, [string]$Guid = '', [int]$Lun = -1, [bool]$InUse = $false) {
        @{ Number = $Number; UniqueId = $UniqueId; Serial = "SN$Number"; BusType = $Bus; Size = ($SizeGib * 1GB); PartitionStyle = $Style; Partitions = $Partitions; Offline = $true; Guid = $Guid; Lun = $Lun; InUse = $InUse; Paths = $Paths }
    }
    function Reset-Cluster {
        $script:IdA = New-Id
        $script:IdB = New-Id
        $global:AzlSanCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlSanState = @{ Computer = 'iic-n01'; MpioRead = $true; Disks = @((New-Disk $script:IdA)); Resources = @(@{ Name = 'Cluster Pool 1'; Type = 'Storage Pool'; Group = 'Cluster Group'; DiskIdGuid = '' }); Csvs = @() }
        $global:AzlSanFail = @{}
    }
    function Invoke-San([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Step) { @($global:AzlSanCalls | Where-Object Step -EQ $Step) }
    function Get-RemoteBlock([string]$Name) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
        $assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Remote' }, $true)
        $pair = $assign.Right.Expression.KeyValuePairs | Where-Object { $_.Item1.Value -eq $Name }
        [scriptblock]::Create($pair.Item2.PipelineElements[0].Expression.ScriptBlock.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
    }
    Reset-Cluster
}

Describe 'New-SanVolume.ps1' {
    AfterAll { Remove-Variable -Name AzlSanCalls, AzlSanState, AzlSanFail -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-Cluster
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlSanCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Arguments = @($ArgumentList | Select-Object -Skip 1); Credential = $Credential })
            if ($global:AzlSanFail.ContainsKey($step)) { throw $global:AzlSanFail[$step] }
            switch ($step) {
                'ReadState' { $global:AzlSanState }
                'PrepareDisk' { @{ Number = 3 } }
                'AddClusterDisk' { @{ Resource = [string]$ArgumentList[2] } }
                'AddCsv' { @{ Path = "C:\ClusterStorage\$($ArgumentList[1])" } }
            }
        }
    }

    Context 'preparing a LUN' {
        It 'prepares a LUN that is no CSV: online, GPT, one NTFS partition with 64 KB units, cluster disk, name, CSV - in that order' {
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            $r.Rows[0].Detail | Should -Match 'GPT'
            $r.Rows[0].Detail | Should -Match 'NTFS, allocation unit 64 KB'
            @($global:AzlSanCalls.Step) | Should -Be @('ReadState', 'PrepareDisk', 'AddClusterDisk', 'AddCsv')
            $a = (Get-Call 'PrepareDisk')[0].Arguments
            $a[0] | Should -Be $script:IdA
            $a[1] | Should -Be 'Fibre Channel'
            $a[2] | Should -Be (1024 * 1GB)
            $a[4] | Should -Be 'san-vol-01'
            $a[5] | Should -Be 65536
            (Get-Call 'AddClusterDisk')[0].Arguments | Should -Be @($script:IdA, 'san-vol-01', '')
            (Get-Call 'AddCsv')[0].Arguments | Should -Be @('san-vol-01')
        }

        It 'connects to cluster.name, or to -ComputerName with -Credential when given' {
            $null = Invoke-San (New-InfraFile)
            (Get-Call 'ReadState')[0].Computer | Should -Be 'iic-cluster-01'
            Reset-Cluster
            $cred = [pscredential]::new('user', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force))
            $null = Invoke-San (New-InfraFile) -Extra @{ ComputerName = 'iic-n02'; Credential = $cred }
            (Get-Call 'ReadState')[0].Computer | Should -Be 'iic-n02'
            (Get-Call 'PrepareDisk')[0].Credential.UserName | Should -Be 'user'
        }

        It 'sends every change to the machine that answered the read, never to the cluster name again' {
            $null = Invoke-San (New-InfraFile)
            (Get-Call 'ReadState')[0].Computer | Should -Be 'iic-cluster-01'
            foreach ($step in 'PrepareDisk', 'AddClusterDisk', 'AddCsv') {
                @(Get-Call $step).Count | Should -Be 1
                (Get-Call $step)[0].Computer | Should -Be $global:AzlSanState.Computer
            }
        }

        It 'changes nothing when the read does not say which machine answered' {
            $global:AzlSanState.Computer = ''
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            @(Get-Call 'PrepareDisk').Count | Should -Be 0
            @(Get-Call 'AddClusterDisk').Count | Should -Be 0
            @(Get-Call 'AddCsv').Count | Should -Be 0
        }

        It 'looks for iSCSI disks when storage.san.type is iscsi' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdA -Bus 'iSCSI'))
            $r = Invoke-San (New-InfraFile -Type iscsi)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'PrepareDisk')[0].Arguments[1] | Should -Be 'iSCSI'
        }

        It 'prepares every LUN of the list, each by its own UniqueId' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdA -Number 3), (New-Disk $script:IdB -Number 4))
            $r = Invoke-San (New-InfraFile -Luns (New-Lun), (New-Lun @{ name = 'san-vol-02'; unique_id = $script:IdB }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('Created', 'Created')
            @((Get-Call 'PrepareDisk').ForEach({ $_.Arguments[0] })) | Should -Be @($script:IdA, $script:IdB)
        }

        It 'accepts a UniqueId in another letter case, and a size inside 1 percent' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdA.ToLowerInvariant() -SizeGib 1020))
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
        }

        It 'accepts a lun_id that agrees with the LUN number the disk shows' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdA -Lun 7))
            (Invoke-San (New-InfraFile -Luns (New-Lun @{ lun_id = '7' }))).Rows[0].Action | Should -Be 'Created'
        }
    }

    Context 'the disk is found by its UniqueId only' {
        It 'does not touch a disk of the right size and number when its UniqueId is not the one in the file' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdB -Number 3 -SizeGib 1024))
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'No Fibre Channel disk with UniqueId'
            @($global:AzlSanCalls.Step) | Should -Be @('ReadState')
        }

        It 'prepares the disk with the UniqueId and leaves the other disks alone' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdB -Number 3), (New-Disk $script:IdA -Number 9))
            $null = Invoke-San (New-InfraFile)
            (Get-Call 'PrepareDisk').Count | Should -Be 1
            (Get-Call 'PrepareDisk')[0].Arguments[0] | Should -Be $script:IdA
        }

        It 'refuses a LUN whose paths MPIO has not claimed (several disks, one UniqueId), and changes nothing' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdA -Number 3 -Paths 0), (New-Disk $script:IdA -Number 4 -Paths 0))
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Refused'
            $r.Rows[0].Detail | Should -Match 'MPIO has not claimed'
            (Get-Call 'PrepareDisk').Count | Should -Be 0
        }
    }

    Context 'safety: a disk that is not the described, empty LUN is never initialized or formatted (exit 1)' {
        It 'refuses <Why>, reports it, changes nothing and goes on with the next LUN' -ForEach @(
            @{ Why = 'a disk that has a partition'; Disk = @{ Partitions = 1 }; Match = 'it is not empty' }
            @{ Why = 'a GPT disk without a partition'; Disk = @{ Style = 'GPT' }; Match = 'partition style GPT' }
            @{ Why = 'an MBR disk'; Disk = @{ Style = 'MBR'; Partitions = 2 }; Match = 'partition style MBR' }
            @{ Why = 'a disk that MPIO does not report (no path)'; Disk = @{ Paths = 0 }; Match = 'MPIO does not report' }
            @{ Why = 'a disk of another size'; Disk = @{ SizeGib = 512 }; Match = 'GiB' }
            @{ Why = 'a disk that shows another LUN number'; Disk = @{ Lun = 5 }; Lun = @{ lun_id = '7' }; Match = 'shows LUN 5' }
            @{ Why = 'a disk on another bus'; Disk = @{ Bus = 'iSCSI' }; Match = "bus 'iSCSI'" }
            @{ Why = 'a boot, system or clustered disk'; Disk = @{ InUse = $true }; Match = 'boot, system or clustered' }
        ) {
            $disk = New-Disk -UniqueId $script:IdA @Disk
            $other = New-Disk $script:IdB -Number 4
            $global:AzlSanState.Disks = @($disk, $other)
            $lunA = if ($Lun) { New-Lun $Lun } else { New-Lun }
            $r = Invoke-San (New-InfraFile -Luns $lunA, (New-Lun @{ name = 'san-vol-02'; unique_id = $script:IdB }))
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Refused'
            $r.Rows[0].Detail | Should -Match $Match
            $r.Rows[0].Detail | Should -Match 'not initialized, formatted or changed'
            $r.Rows[1].Action | Should -Be 'Created'
            @((Get-Call 'PrepareDisk').ForEach({ $_.Arguments[0] })) | Should -Be @($script:IdB)
        }

        It 'refuses every LUN when MPIO could not be read' {
            $global:AzlSanState.MpioRead = $false
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'MPIO could not be read'
            (Get-Call 'PrepareDisk').Count | Should -Be 0
        }

        It 'refuses a LUN whose name another cluster resource already uses' {
            $global:AzlSanState.Resources = @(@{ Name = 'san-vol-01'; Type = 'Physical Disk'; Group = 'Cluster Group'; DiskIdGuid = [guid]::NewGuid().ToString() })
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'already has a resource named'
            (Get-Call 'PrepareDisk').Count | Should -Be 0
        }

        It 'stops when the machine itself refuses at the last moment (REFUSED), and does not add the disk to the cluster' {
            $global:AzlSanFail = @{ PrepareDisk = 'REFUSED: disk 3 has partition style GPT and 1 partition(s). It is not empty, so it is not touched.' }
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Refused'
            $r.Rows[0].Detail | Should -Match 'not empty'
            (Get-Call 'AddClusterDisk').Count | Should -Be 0
            (Get-Call 'AddCsv').Count | Should -Be 0
        }

        It 'warns when MPIO reports one path only, and still prepares the LUN' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdA -Paths 1))
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'one path'
        }
    }

    Context 'idempotent' {
        BeforeEach {
            $script:Guid = [guid]::NewGuid().ToString()
            $global:AzlSanState.Disks = @((New-Disk $script:IdA -Style GPT -Partitions 1 -Guid "{$script:Guid}"))
        }

        It 'reports a LUN that is a CSV with the right name and does nothing' {
            $global:AzlSanState.Resources = @(@{ Name = 'san-vol-01'; Type = 'Physical Disk'; Group = 'Cluster Group'; DiskIdGuid = $script:Guid })
            $global:AzlSanState.Csvs = @(@{ Name = 'san-vol-01'; Path = 'C:\ClusterStorage\Volume1' })
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            @($global:AzlSanCalls.Step) | Should -Be @('ReadState')
        }

        It 'reports a CSV with another name and does not rename it (exit 1)' {
            $global:AzlSanState.Resources = @(@{ Name = 'Cluster Disk 4'; Type = 'Physical Disk'; Group = 'Cluster Group'; DiskIdGuid = $script:Guid })
            $global:AzlSanState.Csvs = @(@{ Name = 'Cluster Disk 4'; Path = 'C:\ClusterStorage\Volume1' })
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Refused'
            @($global:AzlSanCalls.Step) | Should -Be @('ReadState')
        }

        It 'finishes a cluster disk that waits in Available Storage: names it and adds it to the CSVs, without touching the disk' {
            $global:AzlSanState.Resources = @(@{ Name = 'Cluster Disk 4'; Type = 'Physical Disk'; Group = 'Available Storage'; DiskIdGuid = $script:Guid })
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AddedToCsv'
            @($global:AzlSanCalls.Step) | Should -Be @('ReadState', 'AddClusterDisk', 'AddCsv')
            (Get-Call 'AddClusterDisk')[0].Arguments | Should -Be @($script:IdA, 'san-vol-01', 'Cluster Disk 4')
        }

        It 'only adds the CSV when the cluster disk already has the right name' {
            $global:AzlSanState.Resources = @(@{ Name = 'san-vol-01'; Type = 'Physical Disk'; Group = 'Available Storage'; DiskIdGuid = $script:Guid })
            $null = Invoke-San (New-InfraFile)
            @($global:AzlSanCalls.Step) | Should -Be @('ReadState', 'AddCsv')
        }

        It 'does not touch a cluster disk that is in use in another cluster group (exit 1)' {
            $global:AzlSanState.Resources = @(@{ Name = 'Cluster Disk 1'; Type = 'Physical Disk'; Group = 'Cluster Group'; DiskIdGuid = $script:Guid })
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'in use'
            @($global:AzlSanCalls.Step) | Should -Be @('ReadState')
        }

        It 'refuses a clustered disk whose cluster resource cannot be matched' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdA -Style GPT -Partitions 1 -InUse $true))
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            @($global:AzlSanCalls.Step) | Should -Be @('ReadState')
        }

        It 'does not initialize or format a disk it formatted itself in an earlier run that stopped (it has a partition)' {
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Refused'
            (Get-Call 'PrepareDisk').Count | Should -Be 0
        }
    }

    Context '-WhatIf' {
        It 'reads the cluster, prints the whole plan, and changes nothing' {
            $r = Invoke-San (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('WouldCreate')
            $r.Rows[0].Detail | Should -Match 'bring disk #3 online; initialize disk #3 as GPT; create one partition with all the space and format it NTFS, allocation unit 64 KB, label ''san-vol-01''; add the disk to the failover cluster; name the cluster disk ''san-vol-01''; add it to Cluster Shared Volumes'
            @($global:AzlSanCalls.Step | Sort-Object -Unique) | Should -Be @('ReadState')
        }

        It 'plans the finishing steps of a cluster disk in Available Storage' {
            $guid = [guid]::NewGuid().ToString()
            $global:AzlSanState.Disks = @((New-Disk $script:IdA -Style GPT -Partitions 1 -Guid $guid))
            $global:AzlSanState.Resources = @(@{ Name = 'Cluster Disk 4'; Type = 'Physical Disk'; Group = 'Available Storage'; DiskIdGuid = $guid })
            $r = Invoke-San (New-InfraFile) -DryRun
            $r.Rows[0].Action | Should -Be 'WouldAddToCsv'
            $r.Rows[0].Detail | Should -Not -Match 'GPT'
        }

        It 'still refuses a disk that is not empty' {
            $global:AzlSanState.Disks = @((New-Disk $script:IdA -Partitions 2 -Style GPT))
            $r = Invoke-San (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Refused'
        }
    }

    Context 'nothing to do (exit 0, the cluster is not contacted)' {
        It 'does nothing for <Architecture>' -ForEach @(@{ Architecture = 's2d' }, @{ Architecture = '' }) {
            $r = Invoke-San (New-InfraFile -Architecture $Architecture)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'no external SAN'
            $global:AzlSanCalls.Count | Should -Be 0
        }

        It 'does nothing when the file lists no LUN' {
            $r = Invoke-San (New-InfraFile -Luns @())
            $r.ExitCode | Should -Be 0
            $global:AzlSanCalls.Count | Should -Be 0
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, the cluster is not contacted)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a LUN without a unique_id (never a disk by size or number)'; Lun = @{ unique_id = $null } }
            @{ Why = 'a unique_id that is too short'; Lun = @{ unique_id = 'abc' } }
            @{ Why = 'a unique_id with a space'; Lun = @{ unique_id = 'ABCD EFGH1234' } }
            @{ Why = 'a name with a space'; Lun = @{ name = 'my lun' } }
            @{ Why = 'a missing name'; Lun = @{ name = $null } }
            @{ Why = 'a name the deployment manages'; Lun = @{ name = 'UserStorage_1' } }
            @{ Why = 'a size of 0'; Lun = @{ size_gib = 0 } }
            @{ Why = 'a missing size'; Lun = @{ size_gib = $null } }
            @{ Why = 'a lun_id that is not a number'; Lun = @{ lun_id = 'two' } }
        ) {
            $r = Invoke-San (New-InfraFile -Luns (New-Lun $Lun))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $global:AzlSanCalls.Count | Should -Be 0
        }

        It 'refuses the same name or the same unique_id twice, and a missing or unknown storage.san.type or a missing cluster name' {
            (Invoke-San (New-InfraFile -Luns (New-Lun), (New-Lun @{ unique_id = $script:IdB }))).ExitCode | Should -Be 2
            (Invoke-San (New-InfraFile -Luns (New-Lun), (New-Lun @{ name = 'san-vol-02' }))).ExitCode | Should -Be 2
            (Invoke-San (New-InfraFile -Type '')).ExitCode | Should -Be 2
            (Invoke-San (New-InfraFile -Type 'nvme_of')).ExitCode | Should -Be 2
            (Invoke-San (New-InfraFile -Cluster '')).ExitCode | Should -Be 2
            $global:AzlSanCalls.Count | Should -Be 0
        }

        It 'refuses the LUN of the infrastructure or performance history volume, which the deployment owns' {
            (Invoke-San (New-InfraFile -San @{ infra_volume_lun_id = $script:IdA.ToLowerInvariant() })).ExitCode | Should -Be 2
            (Invoke-San (New-InfraFile -San @{ performance_history_lun_id = $script:IdA })).ExitCode | Should -Be 2
            $global:AzlSanCalls.Count | Should -Be 0
        }

        It 'refuses a file that does not exist' {
            (Invoke-San (Join-Path $TestDrive 'nowhere.yml')).ExitCode | Should -Be 2
        }
    }

    Context 'failures (exit 1)' {
        It 'stops when the cluster cannot be read' {
            $global:AzlSanFail = @{ ReadState = 'simulated failure' }
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
        }

        It 'reports a step that fails, says how far it got, and does not go on to the next step of that LUN' {
            $global:AzlSanFail = @{ AddClusterDisk = 'simulated failure' }
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'formatted but not in the cluster yet'
            (Get-Call 'AddCsv').Count | Should -Be 0
        }

        It 'reports a CSV that could not be added and says the cluster disk exists' {
            $global:AzlSanFail = @{ AddCsv = 'simulated failure' }
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match "is named 'san-vol-01' but is not a CSV yet"
        }

        It 'does not add anything to the cluster when the disk could not be prepared' {
            $global:AzlSanFail = @{ PrepareDisk = 'simulated failure' }
            $r = Invoke-San (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            (Get-Call 'AddClusterDisk').Count | Should -Be 0
        }
    }

    Context 'the PrepareDisk block on the machine (run against stub storage cmdlets)' {
        BeforeAll {
            # Stubs with the signatures of the storage cmdlets, so the mocks bind on any machine.
            function Get-Disk { [CmdletBinding()] param([int]$Number) }
            function Set-Disk { [CmdletBinding()] param([int]$Number, [object]$IsOffline, [object]$IsReadOnly) }
            function Initialize-Disk { [CmdletBinding(SupportsShouldProcess)] param([int]$Number, [string]$PartitionStyle) }
            function Get-Partition { [CmdletBinding()] param([int]$DiskNumber) }
            function New-Partition { [CmdletBinding()] param([int]$DiskNumber, [switch]$UseMaximumSize, [switch]$AssignDriveLetter) }
            function Format-Volume { [CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$InputObject, [string]$FileSystem, [int]$AllocationUnitSize, [string]$NewFileSystemLabel) process { } }
            $script:Prepare = Get-RemoteBlock 'PrepareDisk'
            function New-RealDisk([hashtable]$Override = @{}) {
                $d = [ordered]@{ Number = 3; UniqueId = $script:IdA; BusType = 'Fibre Channel'; Size = (1024 * 1GB); PartitionStyle = 'RAW'; NumberOfPartitions = 0; IsOffline = $true; IsReadOnly = $true
                    IsBoot = $false; IsSystem = $false; IsClustered = $false; IsHighlyAvailable = $false; IsScaleOut = $false }
                foreach ($k in $Override.Keys) { $d[$k] = $Override[$k] }
                [pscustomobject]$d
            }
            function Invoke-Prepare([string]$UniqueId = $script:IdA) { & $script:Prepare 'PrepareDisk' $UniqueId 'Fibre Channel' (1024 * 1GB) 0.01 'san-vol-01' 65536 }
        }
        BeforeEach {
            $global:AzlDiskReads = 0
            $global:AzlDiskFirst = New-RealDisk
            $global:AzlDiskAfterOnline = New-RealDisk @{ IsOffline = $false }
            Mock Get-Disk { $global:AzlDiskReads++; if ($Number -gt 0) { $global:AzlDiskAfterOnline } else { $global:AzlDiskFirst } }
            Mock Set-Disk { }
            Mock Initialize-Disk { }
            Mock Get-Partition { }
            Mock New-Partition { [pscustomobject]@{ DriveLetter = 'E' } }
            Mock Format-Volume { }
        }
        AfterAll { Remove-Variable -Name AzlDiskReads, AzlDiskFirst, AzlDiskAfterOnline -Scope Global -ErrorAction SilentlyContinue }

        It 'brings the disk online, clears read-only, initializes GPT, makes one partition and formats NTFS with 64 KB units and the LUN name as label' {
            $global:AzlDiskAfterOnline = New-RealDisk @{ IsOffline = $false; IsReadOnly = $true }
            $result = Invoke-Prepare
            $result.Number | Should -Be 3
            Should -Invoke Set-Disk -Times 1 -ParameterFilter { $null -ne $IsOffline -and $IsOffline -eq $false }
            Should -Invoke Set-Disk -Times 1 -ParameterFilter { $null -ne $IsReadOnly -and $IsReadOnly -eq $false }
            Should -Invoke Initialize-Disk -Times 1 -ParameterFilter { $Number -eq 3 -and $PartitionStyle -eq 'GPT' }
            Should -Invoke New-Partition -Times 1 -ParameterFilter { $DiskNumber -eq 3 -and $UseMaximumSize }
            Should -Invoke Format-Volume -Times 1 -ParameterFilter { $FileSystem -eq 'NTFS' -and $AllocationUnitSize -eq 65536 -and $NewFileSystemLabel -eq 'san-vol-01' }
        }

        It 'never writes to a disk that has a partition (seen at the start)' {
            $global:AzlDiskFirst = New-RealDisk @{ PartitionStyle = 'GPT'; NumberOfPartitions = 1 }
            { Invoke-Prepare } | Should -Throw '*REFUSED*not empty*'
            Should -Invoke Set-Disk -Times 0
            Should -Invoke Initialize-Disk -Times 0
            Should -Invoke Format-Volume -Times 0
        }

        It 'never writes to a disk whose partitions only show after it is online' {
            $global:AzlDiskAfterOnline = New-RealDisk @{ IsOffline = $false; PartitionStyle = 'GPT'; NumberOfPartitions = 2 }
            { Invoke-Prepare } | Should -Throw '*REFUSED*not empty*'
            Should -Invoke Initialize-Disk -Times 0
            Should -Invoke New-Partition -Times 0
            Should -Invoke Format-Volume -Times 0
        }

        It 'never writes when Get-Partition finds a partition on a disk that says it has none' {
            Mock Get-Partition { [pscustomobject]@{ PartitionNumber = 1 } }
            { Invoke-Prepare } | Should -Throw '*REFUSED*not empty*'
            Should -Invoke Initialize-Disk -Times 0
            Should -Invoke Format-Volume -Times 0
        }

        It 'never writes when the partitions cannot be read (a failed query is not an empty disk)' {
            Mock Get-Partition { throw 'The storage service did not answer.' }
            { Invoke-Prepare } | Should -Throw '*REFUSED*could not be read*'
            Should -Invoke Initialize-Disk -Times 0
            Should -Invoke New-Partition -Times 0
            Should -Invoke Format-Volume -Times 0
        }

        It 'goes on when Windows says the disk has no partition objects' {
            Mock Get-Partition { throw "No MSFT_Partition objects found with property 'DiskNumber' equal to '3'." }
            (Invoke-Prepare).Number | Should -Be 3
            Should -Invoke Format-Volume -Times 1
        }

        It 'never writes when the disk number shows another UniqueId after it is online' {
            $global:AzlDiskAfterOnline = New-RealDisk @{ IsOffline = $false; UniqueId = (New-Id) }
            { Invoke-Prepare } | Should -Throw '*REFUSED*no longer reports*'
            Should -Invoke Initialize-Disk -Times 0
            Should -Invoke Format-Volume -Times 0
        }

        It 'never writes when the disk shows as clustered after it is online' {
            $global:AzlDiskAfterOnline = New-RealDisk @{ IsOffline = $false; IsClustered = $true }
            { Invoke-Prepare } | Should -Throw '*REFUSED*clustered*'
            Should -Invoke Initialize-Disk -Times 0
            Should -Invoke Format-Volume -Times 0
        }

        It 'never writes when the UniqueId is on no disk, or on more than one' {
            { Invoke-Prepare (New-Id) } | Should -Throw '*REFUSED*0 disks*'
            Mock Get-Disk { (New-RealDisk), (New-RealDisk @{ Number = 4 }) }
            { Invoke-Prepare } | Should -Throw '*REFUSED*2 disks*'
            Should -Invoke Set-Disk -Times 0
            Should -Invoke Initialize-Disk -Times 0
        }

        It 'never writes to <Why>' -ForEach @(
            @{ Why = 'a boot disk'; Override = @{ IsBoot = $true } }
            @{ Why = 'a system disk'; Override = @{ IsSystem = $true } }
            @{ Why = 'a clustered disk'; Override = @{ IsClustered = $true } }
            @{ Why = 'a highly available disk'; Override = @{ IsHighlyAvailable = $true } }
            @{ Why = 'a disk on another bus'; Override = @{ BusType = 'SAS' } }
            @{ Why = 'a disk of another size'; Override = @{ Size = (512 * 1GB) } }
        ) {
            $global:AzlDiskFirst = New-RealDisk $Override
            { Invoke-Prepare } | Should -Throw '*REFUSED*'
            Should -Invoke Set-Disk -Times 0
            Should -Invoke Initialize-Disk -Times 0
            Should -Invoke Format-Volume -Times 0
        }

        It 'leaves a disk that is already online and writable as it is, and still formats it' {
            $global:AzlDiskFirst = New-RealDisk @{ IsOffline = $false; IsReadOnly = $false }
            $global:AzlDiskAfterOnline = New-RealDisk @{ IsOffline = $false; IsReadOnly = $false }
            $null = Invoke-Prepare
            Should -Invoke Set-Disk -Times 0
            Should -Invoke Initialize-Disk -Times 1
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header, never prompts, reads no secret and names no vault' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|KeyVault|keyvault://|Connect-AzAccount'
        }

        It 'reads its values through the toolkit loader and holds no address, name, size or identifier of its own' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            $script:Text | Should -Not -Match '(?i)SU1_Pool|\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|iic-|improbability'
        }

        It 'never uses the blanket Learn pipeline that adds every available disk, and never clears, removes, resizes or converts a disk' {
            $code = $script:Text -replace '(?s)<#.*?#>', ''   # the help may name what the script does not do
            $code | Should -Not -Match 'Get-ClusterAvailableDisk'
            $code | Should -Not -Match 'Clear-Disk|Remove-Partition|Remove-Disk|Resize-Partition|Remove-ClusterResource|Remove-ClusterSharedVolume|Convert-Disk|Set-Disk\s+-Number\s+\S+\s+-IsOffline\s+\$true|-PartitionStyle\s+MBR|ReFS|REFS'
        }

        It 'formats only as NTFS with a 64 KB allocation unit and writes to a disk only inside PrepareDisk, after its checks' {
            $script:Text | Should -Match 'Format-Volume -FileSystem NTFS -AllocationUnitSize \$AllocationUnit'
            $script:Text | Should -Match '\$AllocationUnitBytes = 65536'
            ([regex]::Matches($script:Text, 'Initialize-Disk -Number')).Count | Should -Be 1
            ([regex]::Matches($script:Text, 'Format-Volume -FileSystem')).Count | Should -Be 1
            $init = $script:Text.IndexOf('Initialize-Disk -Number')
            $check = $script:Text.IndexOf("It is not empty, so it is not touched. The disk was brought online")
            $check | Should -BeGreaterThan 0
            $init | Should -BeGreaterThan $check
            $script:Text.IndexOf('Set-Disk -Number $number -IsReadOnly $false') | Should -BeGreaterThan $check
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_SanVolume_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach @(
            'cluster.name', 'scenario.storage_architecture', 'storage.san.type', 'storage.san.infra_volume_lun_id', 'storage.san.performance_history_lun_id',
            'storage.san.luns[].name', 'storage.san.luns[].unique_id', 'storage.san.luns[].size_gib', 'storage.san.luns[].lun_id'
        ) {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }

        It 'names every key it reads in its help' {
            foreach ($key in 'cluster.name', 'scenario.storage_architecture', 'storage.san.type', 'storage.san.infra_volume_lun_id', 'storage.san.performance_history_lun_id', 'name, unique_id, size_gib, lun_id') {
                $script:Text | Should -Match ([regex]::Escape($key))
            }
        }

        It 'registers unique_id as an optional string added in schema 5.6.16' {
            $key = $script:Registry | Where-Object Path -EQ 'storage.san.luns[].unique_id'
            $key.Node['since'] | Should -Be '5.6.16'
            $key.Node['type'] | Should -Be 'string'
            $key.Node['required'] | Should -BeFalse
        }
    }
}
