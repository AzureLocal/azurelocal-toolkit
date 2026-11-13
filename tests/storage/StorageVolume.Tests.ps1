#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 05: New-StorageVolume.ps1 creates the Storage Spaces Direct volumes of storage.volumes and sets the CSV read cache and
# the pool alert threshold. Invoke-Command is mocked: no cluster, no machine, no credential is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/storage/StorageVolume.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the cluster state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-StorageVolume.ps1')
    Import-Module powershell-yaml

    function New-Volume([hashtable]$Override = @{}) {
        $v = [ordered]@{ name = 'vol-workloads-01'; size_gib = 100 }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $v.Remove($k) } else { $v[$k] = $Override[$k] } }
        $v
    }
    function New-InfraFile {
        param([object[]]$Volumes = @((New-Volume)), [int]$Nodes = 4, [string]$Architecture = 's2d', [string]$Media = 'nvme', [object]$Pool = $null, [object]$Csv = $null, [string]$Cluster = 'azl-cluster-01')
        $doc = [ordered]@{
            scenario = [ordered]@{ storage_architecture = $Architecture }
            cluster  = [ordered]@{}
            nodes    = @(1..$Nodes | ForEach-Object { [ordered]@{ name = "node0$_" } })
            hardware = [ordered]@{ drives = [ordered]@{ capacity = [ordered]@{ media = $Media } } }
            storage  = [ordered]@{}
        }
        if ($Cluster) { $doc.cluster.name = $Cluster }
        if ($Volumes) { $doc.storage.volumes = @($Volumes) }
        if ($Pool) { $doc.storage.pool = $Pool }
        if ($Csv) { $doc.storage.csv = $Csv }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Cluster {
        $global:AzlVolCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlVolState = @{
            Pools = @(@{ Name = 'SU1_Pool'; Thresholds = @(70) }); Volumes = @('Infrastructure_1'); BlockCacheSize = 1024; Nodes = @('node01', 'node02', 'node03', 'node04')
            Tiers = @('MirrorOnSSD', 'ParityOnSSD', 'NestedMirrorOnSSD', 'NestedParityOnSSD', 'MirrorOnHDD', 'ParityOnHDD')
        }
        $global:AzlVolDedup = @{ Enabled = $false; Type = '' }
        $global:AzlVolFail = ''
    }
    # Runs the script and returns its exit code, its rows and every message as text.
    function Invoke-Volume([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Step) { @($global:AzlVolCalls | Where-Object Step -EQ $Step) }
}

Describe 'New-StorageVolume.ps1' {
    AfterAll { Remove-Variable -Name AzlVolCalls, AzlVolState, AzlVolDedup, AzlVolFail -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-Cluster
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlVolCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Arguments = @($ArgumentList | Select-Object -Skip 1); Credential = $Credential })
            if ($global:AzlVolFail -eq $step) { throw "simulated failure of $step" }
            switch ($step) {
                'ReadState' { $global:AzlVolState }
                'GetOwner' { @{ Owner = 'node02'; Path = "C:\ClusterStorage\$($ArgumentList[1])" } }
                'ReadDedup' { $global:AzlVolDedup }
            }
        }
    }

    Context 'creating volumes' {
        It 'creates a volume that is missing, in the one pool of the cluster, as ReFS, and lets Storage Spaces Direct choose the resiliency when the file names none' {
            $r = Invoke-Volume (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            $p = (Get-Call 'NewVolume')[0].Arguments[0]
            $p.FriendlyName | Should -Be 'vol-workloads-01'
            $p.StoragePoolFriendlyName | Should -Be 'SU1_Pool'
            $p.FileSystem | Should -Be 'CSVFS_ReFS'
            $p.Size | Should -Be (100 * 1GB)
            $p.ContainsKey('ResiliencySettingName') | Should -BeFalse
            $p.ContainsKey('ProvisioningType') | Should -BeFalse
        }

        It 'connects to cluster.name, or to -ComputerName when given, with -Credential when given' {
            $null = Invoke-Volume (New-InfraFile)
            (Get-Call 'ReadState')[0].Computer | Should -Be 'azl-cluster-01'
            Reset-Cluster
            $cred = [pscredential]::new('user', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force))
            $null = Invoke-Volume (New-InfraFile) -Extra @{ ComputerName = 'node03'; Credential = $cred }
            (Get-Call 'NewVolume')[0].Computer | Should -Be 'node03'
            (Get-Call 'NewVolume')[0].Credential.UserName | Should -Be 'user'
        }

        It 'maps <Resiliency> to <Setting> with physical disk redundancy <Redundancy>' -ForEach @(
            @{ Resiliency = 'two_way'; Setting = 'Mirror'; Redundancy = 1 }, @{ Resiliency = 'three_way'; Setting = 'Mirror'; Redundancy = 2 }
            @{ Resiliency = 'four_way'; Setting = 'Mirror'; Redundancy = 3 }, @{ Resiliency = 'parity'; Setting = 'Parity'; Redundancy = 2 }
        ) {
            $null = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ resiliency = $Resiliency }))
            $p = (Get-Call 'NewVolume')[0].Arguments[0]
            $p.ResiliencySettingName | Should -Be $Setting
            $p.PhysicalDiskRedundancy | Should -Be $Redundancy
        }

        It 'passes provisioning_type, file_system ntfs and media_type when the file gives them' {
            $null = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ provisioning_type = 'fixed'; file_system = 'ntfs'; media_type = 'hdd' }))
            $p = (Get-Call 'NewVolume')[0].Arguments[0]
            $p.ProvisioningType | Should -Be 'Fixed'
            $p.FileSystem | Should -Be 'CSVFS_NTFS'
            $p.MediaType | Should -Be 'HDD'
        }

        It 'creates a mirror-accelerated parity volume from the mirror and parity tiers, 20 percent mirror by default' {
            $null = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ resiliency = 'mirror_accelerated_parity' }))
            $p = (Get-Call 'NewVolume')[0].Arguments[0]
            $p.StorageTierFriendlyNames | Should -Be @('MirrorOnSSD', 'ParityOnSSD')
            $p.StorageTierSizes | Should -Be @((20 * 1GB), (80 * 1GB))
            $p.ContainsKey('Size') | Should -BeFalse
        }

        It 'uses parity_percent and the media type of the volume for the tiers' {
            $null = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ resiliency = 'mirror_accelerated_parity'; parity_percent = 90; media_type = 'hdd' }))
            $p = (Get-Call 'NewVolume')[0].Arguments[0]
            $p.StorageTierFriendlyNames | Should -Be @('MirrorOnHDD', 'ParityOnHDD')
            $p.StorageTierSizes | Should -Be @((10 * 1GB), (90 * 1GB))
        }

        It 'creates nested volumes on a two-machine cluster from the nested tiers' {
            $null = Invoke-Volume (New-InfraFile -Nodes 2 -Volumes (New-Volume @{ resiliency = 'nested_two_way' }), (New-Volume @{ name = 'vol-02'; resiliency = 'nested_mirror_accelerated_parity' }))
            $calls = Get-Call 'NewVolume'
            $calls[0].Arguments[0].StorageTierFriendlyNames | Should -Be @('NestedMirrorOnSSD')
            $calls[0].Arguments[0].StorageTierSizes | Should -Be @((100 * 1GB))
            $calls[1].Arguments[0].StorageTierFriendlyNames | Should -Be @('NestedMirrorOnSSD', 'NestedParityOnSSD')
        }

        It 'sets the provisioning type on the tiers of a tiered volume only when the file gives one' {
            $null = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ resiliency = 'mirror_accelerated_parity' }), (New-Volume @{ name = 'vol-02'; resiliency = 'mirror_accelerated_parity'; provisioning_type = 'thin' }))
            $calls = Get-Call 'NewVolume'
            $calls[0].Arguments[1] | Should -BeNullOrEmpty
            $calls[1].Arguments[1] | Should -Be 'Thin'
            $calls[1].Arguments[0].ContainsKey('ProvisioningType') | Should -BeFalse
        }

        It 'stops for a tier the pool does not have, and creates nothing for that volume' {
            $global:AzlVolState.Tiers = @('MirrorOnSSD')
            $r = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ resiliency = 'mirror_accelerated_parity' }))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'ParityOnSSD do not exist'
            (Get-Call 'NewVolume').Count | Should -Be 0
        }

        It 'uses storage.pool.name when the file names the pool' {
            $global:AzlVolState.Pools = @(@{ Name = 'pool-a'; Thresholds = @(70) })
            $null = Invoke-Volume (New-InfraFile -Pool ([ordered]@{ name = 'pool-a' }))
            (Get-Call 'ReadState')[0].Arguments[0] | Should -Be 'pool-a'
            (Get-Call 'NewVolume')[0].Arguments[0].StoragePoolFriendlyName | Should -Be 'pool-a'
        }
    }

    Context 'idempotent' {
        It 'leaves a volume that exists as it is' {
            $global:AzlVolState.Volumes = @('Infrastructure_1', 'vol-workloads-01')
            $r = Invoke-Volume (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            (Get-Call 'NewVolume').Count | Should -Be 0
        }

        It 'never deletes, resizes or changes a volume' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'Remove-VirtualDisk|Remove-Volume|Resize-VirtualDisk|Resize-StorageTier|Remove-StoragePool|Clear-Disk|Format-Volume|Enable-DedupVolume'
        }
    }

    Context 'deduplication and compression (off unless the file says otherwise)' {
        It 'does not touch deduplication when the file does not ask for it' {
            $null = Invoke-Volume (New-InfraFile)
            (Get-Call 'GetOwner').Count | Should -Be 0
            (Get-Call 'SetDedup').Count | Should -Be 0
        }

        It 'turns on <Type> on the machine that owns the volume' -ForEach @(
            @{ Type = 'dedup'; Name = 'Dedup' }, @{ Type = 'compress'; Name = 'Compress' }, @{ Type = 'dedup_and_compress'; Name = 'DedupAndCompress' }
        ) {
            $r = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ deduplication = [ordered]@{ type = $Type } }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $call = (Get-Call 'SetDedup')[0]
            $call.Computer | Should -Be 'node02'
            $call.Arguments[0] | Should -Be 'C:\ClusterStorage\vol-workloads-01'
            $call.Arguments[1] | Should -Be $Name
            $call.Arguments[2] | Should -BeNullOrEmpty
        }

        It 'sets the schedule the file gives' {
            $dedup = [ordered]@{ type = 'dedup'; schedule = [ordered]@{ start_time = '22:00'; days = @('friday', 'Saturday'); duration_hours = 2 } }
            $null = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ deduplication = $dedup }))
            $s = (Get-Call 'SetDedup')[0].Arguments[2]
            $s.StartTime | Should -Be '22:00'
            $s.Days | Should -Be 'Friday,Saturday'
            $s.Hours | Should -Be 2
        }

        It 'leaves deduplication that is already on, and reports a type that differs' {
            $global:AzlVolState.Volumes = @('vol-workloads-01')
            $global:AzlVolDedup = @{ Enabled = $true; Type = 'Compress' }
            $r = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ deduplication = [ordered]@{ type = 'dedup' } }))
            $r.ExitCode | Should -Be 0
            ($r.Rows | Where-Object Item -Like 'deduplication*').Detail | Should -Match 'is Compress, the file says Dedup'
            (Get-Call 'SetDedup').Count | Should -Be 0
        }

        It 'refuses deduplication on NTFS, a schedule without a type, and a bad schedule' {
            (Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ file_system = 'ntfs'; deduplication = [ordered]@{ type = 'dedup' } }))).ExitCode | Should -Be 2
            (Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ deduplication = [ordered]@{ schedule = [ordered]@{ start_time = '22:00'; days = @('Friday'); duration_hours = 2 } } }))).ExitCode | Should -Be 2
            (Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ deduplication = [ordered]@{ type = 'dedup'; schedule = [ordered]@{ start_time = '10pm'; days = @('Friday'); duration_hours = 2 } } }))).ExitCode | Should -Be 2
            (Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ deduplication = [ordered]@{ type = 'dedup'; schedule = [ordered]@{ start_time = '22:00'; days = @('Someday'); duration_hours = 2 } } }))).ExitCode | Should -Be 2
            (Get-Call 'ReadState').Count | Should -Be 0
        }
    }

    Context 'CSV read cache and pool alert threshold (only when the file names them)' {
        It 'touches neither when the file names neither' {
            $null = Invoke-Volume (New-InfraFile)
            (Get-Call 'SetCache').Count | Should -Be 0
            (Get-Call 'SetThreshold').Count | Should -Be 0
        }

        It 'sets the cache size and the threshold when they differ' {
            $r = Invoke-Volume (New-InfraFile -Volumes @() -Csv ([ordered]@{ read_cache_size_mib = 2048 }) -Pool ([ordered]@{ thin_provisioning_alert_threshold_percent = 80 }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'SetCache')[0].Arguments[0] | Should -Be 2048
            (Get-Call 'SetThreshold')[0].Arguments | Should -Be @('SU1_Pool', 80)
        }

        It 'leaves a value that is already right, and accepts 0 to switch the cache off' {
            $null = Invoke-Volume (New-InfraFile -Volumes @() -Csv ([ordered]@{ read_cache_size_mib = 1024 }) -Pool ([ordered]@{ thin_provisioning_alert_threshold_percent = 70 }))
            (Get-Call 'SetCache').Count | Should -Be 0
            (Get-Call 'SetThreshold').Count | Should -Be 0
            $null = Invoke-Volume (New-InfraFile -Volumes @() -Csv ([ordered]@{ read_cache_size_mib = 0 }))
            (Get-Call 'SetCache')[0].Arguments[0] | Should -Be 0
        }
    }

    Context '-WhatIf' {
        It 'reads the cluster, plans, and changes nothing' {
            $r = Invoke-Volume (New-InfraFile -Volumes (New-Volume @{ deduplication = [ordered]@{ type = 'dedup' } }) -Csv ([ordered]@{ read_cache_size_mib = 2048 })) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('WouldCreate', 'WouldSet', 'WouldSet')
            @($global:AzlVolCalls.Step | Sort-Object -Unique) | Should -Be @('ReadState')
        }
    }

    Context 'nothing to do (exit 0, the cluster is not contacted)' {
        It 'does nothing for a SAN-only instance' {
            $r = Invoke-Volume (New-InfraFile -Architecture 'san')
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'no Storage Spaces Direct pool'
            $global:AzlVolCalls.Count | Should -Be 0
        }

        It 'does nothing when the file lists no volume and no setting' {
            $r = Invoke-Volume (New-InfraFile -Volumes @())
            $r.ExitCode | Should -Be 0
            $global:AzlVolCalls.Count | Should -Be 0
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, the cluster is not contacted)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a name the deployment manages'; Volume = @{ name = 'UserStorage_1' } }
            @{ Why = 'the infrastructure volume name'; Volume = @{ name = 'Infrastructure_1' } }
            @{ Why = 'a name with a space'; Volume = @{ name = 'my volume' } }
            @{ Why = 'a size of 0'; Volume = @{ size_gib = 0 } }
            @{ Why = 'an unknown resiliency'; Volume = @{ resiliency = 'raid5' } }
            @{ Why = 'an unknown file system'; Volume = @{ file_system = 'fat32' } }
            @{ Why = 'an unknown provisioning type'; Volume = @{ provisioning_type = 'sparse' } }
            @{ Why = 'an unknown media type'; Volume = @{ media_type = 'tape' } }
            @{ Why = 'parity_percent on a mirror volume'; Volume = @{ resiliency = 'two_way'; parity_percent = 80 } }
            @{ Why = 'mirror-accelerated parity on NTFS'; Volume = @{ resiliency = 'mirror_accelerated_parity'; file_system = 'ntfs' } }
            @{ Why = 'parity_percent of 100'; Volume = @{ resiliency = 'mirror_accelerated_parity'; parity_percent = 100 } }
        ) {
            $r = Invoke-Volume (New-InfraFile -Volumes (New-Volume $Volume))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $global:AzlVolCalls.Count | Should -Be 0
        }

        It 'refuses <Resiliency> on <Nodes> machine(s)' -ForEach @(
            @{ Resiliency = 'three_way'; Nodes = 2 }, @{ Resiliency = 'parity'; Nodes = 3 }, @{ Resiliency = 'mirror_accelerated_parity'; Nodes = 3 }
            @{ Resiliency = 'four_way'; Nodes = 3 }, @{ Resiliency = 'nested_two_way'; Nodes = 3 }, @{ Resiliency = 'nested_mirror_accelerated_parity'; Nodes = 4 }
        ) {
            $r = Invoke-Volume (New-InfraFile -Nodes $Nodes -Volumes (New-Volume @{ resiliency = $Resiliency }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'machines'
        }

        It 'refuses the same volume name twice, a tiered volume without a media type, and a missing cluster name' {
            (Invoke-Volume (New-InfraFile -Volumes (New-Volume), (New-Volume))).ExitCode | Should -Be 2
            (Invoke-Volume (New-InfraFile -Media '' -Volumes (New-Volume @{ resiliency = 'mirror_accelerated_parity' }))).ExitCode | Should -Be 2
            (Invoke-Volume (New-InfraFile -Cluster '')).ExitCode | Should -Be 2
        }

        It 'refuses a threshold or a cache size that is not a usable number' {
            (Invoke-Volume (New-InfraFile -Pool ([ordered]@{ thin_provisioning_alert_threshold_percent = 0 }))).ExitCode | Should -Be 2
            (Invoke-Volume (New-InfraFile -Csv ([ordered]@{ read_cache_size_mib = -1 }))).ExitCode | Should -Be 2
        }

        It 'refuses a file that does not exist' {
            (Invoke-Volume (Join-Path $TestDrive 'nowhere.yml')).ExitCode | Should -Be 2
        }
    }

    Context 'failures (exit 1)' {
        It 'stops when the cluster cannot be read' {
            $global:AzlVolFail = 'ReadState'
            $r = Invoke-Volume (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
        }

        It 'stops when there is no pool, or more than one and the file names none' {
            $global:AzlVolState.Pools = @()
            (Invoke-Volume (New-InfraFile)).ExitCode | Should -Be 1
            $global:AzlVolState.Pools = @(@{ Name = 'a'; Thresholds = @(70) }, @{ Name = 'b'; Thresholds = @(70) })
            $r = Invoke-Volume (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'storage.pool.name'
            (Get-Call 'NewVolume').Count | Should -Be 0
        }

        It 'reports a volume that fails, goes on with the next one, and exits 1' {
            $global:AzlVolFail = 'NewVolume'
            $r = Invoke-Volume (New-InfraFile -Volumes (New-Volume), (New-Volume @{ name = 'vol-02' }))
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed', 'Failed')
            (Get-Call 'NewVolume').Count | Should -Be 2
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
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|KeyVault|keyvault://'
        }

        It 'reads its values through the toolkit loader and holds no address and no pool or cluster name' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml|cluster_shared_volumes'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            $script:Text | Should -Not -Match 'SU1_Pool|S2D on '
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_StorageVolume_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach @(
            'cluster.name', 'scenario.storage_architecture', 'hardware.drives.capacity.media', 'storage.pool.name', 'storage.pool.thin_provisioning_alert_threshold_percent',
            'storage.csv.read_cache_size_mib', 'storage.volumes[].name', 'storage.volumes[].size_gib', 'storage.volumes[].resiliency', 'storage.volumes[].provisioning_type',
            'storage.volumes[].file_system', 'storage.volumes[].parity_percent', 'storage.volumes[].media_type', 'storage.volumes[].deduplication.type',
            'storage.volumes[].deduplication.schedule.start_time', 'storage.volumes[].deduplication.schedule.days', 'storage.volumes[].deduplication.schedule.duration_hours'
        ) {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }

        It 'accepts exactly the resiliency values the registry lists' {
            $enum = @(($script:Registry | Where-Object Path -EQ 'storage.volumes[].resiliency').Node['enum'])
            $inScript = @([regex]::Matches($script:Text, '(?m)^    ([a-z_]+)\s+= @\{ (Setting|Tiers)') | ForEach-Object { $_.Groups[1].Value })
            ($inScript | Sort-Object) | Should -Be ($enum | Sort-Object)
        }
    }
}
