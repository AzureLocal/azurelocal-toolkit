#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 05 (storage configuration): the scripts of the task each run ALONE, with only their own parameters, and plan against the
# toolkit example file:
#   New-StorageVolume.ps1              the Storage Spaces Direct volumes of storage.volumes (and the CSV cache and pool threshold), then the check of the page
#   New-SanVolume.ps1                  the SAN LUNs of storage.san.luns as NTFS cluster shared volumes (hybrid or SAN instances)
#   New-StoragePath.ps1                the Azure Local storage paths of storage.paths (Az.StackHCIVM)
#   New-StoragePath.azcli.ps1          the same with the Azure CLI
# Each script checks its own preconditions from the file and from the cluster or Azure; none needs another to have run. Invoke-Command, every Az cmdlet and az
# are fakes, so no cluster and no Azure is used, and a test fails when a plan sends anything that changes a disk, a volume, the cluster or a resource.
# The file is config/variables/examples/infrastructure.example.yml, as it is, and with the values the task needs added in memory.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/StorageScriptsPlanMode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake cluster and Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeDiscovery {
    $script:Cases = @(
        @{ Name = 'New-StorageVolume.ps1'; Own = @('ComputerName', 'Credential') }
        @{ Name = 'New-SanVolume.ps1'; Own = @('ComputerName', 'Credential') }
        @{ Name = 'New-StoragePath.ps1'; Own = @() }
        @{ Name = 'New-StoragePath.azcli.ps1'; Own = @() }
    )
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $task = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration')
    $script:Paths = @{
        'New-StorageVolume.ps1'     = [IO.Path]::Combine($task, 'powershell', 'New-StorageVolume.ps1')
        'New-SanVolume.ps1'         = [IO.Path]::Combine($task, 'powershell', 'New-SanVolume.ps1')
        'New-StoragePath.ps1'       = [IO.Path]::Combine($task, 'powershell', 'New-StoragePath.ps1')
        'New-StoragePath.azcli.ps1' = [IO.Path]::Combine($task, 'azurecli', 'New-StoragePath.azcli.ps1')
    }
    Import-Module powershell-yaml

    function az { }
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzStackHCIVMStoragePath { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function New-AzStackHCIVMStoragePath { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$CustomLocationId, [string]$Path, [hashtable]$Tag) }

    $global:AzlPlanTenant = [guid]::NewGuid().ToString()
    $global:AzlPlanSub = [guid]::NewGuid().ToString()
    $script:IdA = [guid]::NewGuid().ToString('N').ToUpperInvariant()

    function New-PlanFile {
        param([switch]$Values, [scriptblock]$Edit)
        $text = Get-Content -LiteralPath $script:Example -Raw
        if (-not $Values -and -not $Edit) {
            $file = Join-Path $TestDrive "example-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            Set-Content -LiteralPath $file -Value $text
            return $file
        }
        $doc = ConvertFrom-Yaml -Ordered $text
        if ($Values) {
            $doc.azure.tenant_id = $global:AzlPlanTenant; $doc.azure.subscription_id = $global:AzlPlanSub
            # The example lists no storage path: the task needs one, on the volume of the example.
            $doc.storage.paths = @([ordered]@{ name = 'sp-workloads-01'; path = 'C:\ClusterStorage\vol-workloads-01\vms' })
        }
        if ($Edit) { & $Edit $doc }
        $file = Join-Path $TestDrive "plan-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    # The example with a SAN: hybrid, one Fibre Channel LUN.
    $script:AddSan = { param($doc) $doc.scenario.storage_architecture = 'hybrid'; $doc.storage.san = [ordered]@{ type = 'fibre_channel'; luns = @([ordered]@{ name = 'san-vol-01'; unique_id = $script:IdA; size_gib = 1024 }) } }
    function Reset-World {
        $global:AzlPlanCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlPlanRemote = [System.Collections.Generic.List[object]]::new()
        $global:AzlPlanState = @{
            Volumes = @('Infrastructure_1'); StoragePath = $null; StoragePathState = 'Succeeded'; PoolHealth = 'Healthy'; PeerSeesLun = $true
            VdSize  = (4096 * 1GB); VdProvisioning = 'Thin'; VdSetting = 'Mirror'; VdRedundancy = 1; SanCsv = $false; SanHealth = 'Healthy'; SanPaths = 2; SanCsvState = 'Online'
            Disk    = @{ Number = 3; UniqueId = $script:IdA; Serial = 'SN3'; BusType = 'Fibre Channel'; Size = (1024 * 1GB); PartitionStyle = 'RAW'; Partitions = 0; Offline = $true; Guid = ''; Lun = -1; InUse = $false; Paths = 2 }
        }
    }
    function Invoke-Alone([string]$Script, [string]$File, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = & $Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    # Anything that writes: a cluster step that creates, formats, adds or sets; an Az or az call that creates.
    function Get-Change {
        @($global:AzlPlanRemote | Where-Object { $_.Step -in 'NewVolume', 'SetDedup', 'SetCache', 'SetThreshold', 'PrepareDisk', 'AddClusterDisk', 'AddCsv' }) +
        @($global:AzlPlanCalls | Where-Object { $_.Command -in 'New-AzStackHCIVMStoragePath', 'stack-hci-vm storagepath create' })
    }
}

Describe 'The storage scripts of phase 06 run alone in Plan mode' {
    AfterAll { Remove-Variable -Name AzlPlanTenant, AzlPlanSub, AzlPlanCalls, AzlPlanRemote, AzlPlanState -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-World
        Mock Invoke-Command {
            # a connection probes the machine first with a block that does nothing
            if ($ScriptBlock.ToString().Trim() -eq '$true') { return $true }
            $step = [string]$ArgumentList[0]
            $global:AzlPlanRemote.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName })
            switch ($step) {
                'ReadState' {
                    if ($ScriptBlock.ToString() -match 'MPIO_DISK_INFO') {
                        $resources = @(@{ Name = 'Cluster Pool 1'; Type = 'Storage Pool'; Group = 'Cluster Group'; DiskIdGuid = '' })
                        $csvs = @()
                        $disk = $global:AzlPlanState.Disk.Clone()
                        if ($global:AzlPlanState.SanCsv) {
                            $disk.Guid = '{11111111-2222-3333-4444-555555555555}'; $disk.PartitionStyle = 'GPT'; $disk.Partitions = 1; $disk.Offline = $false; $disk.InUse = $true
                            $resources += @{ Name = 'san-vol-01'; Type = 'Physical Disk'; Group = 'san-vol-01'; DiskIdGuid = $disk.Guid }
                            $csvs = @(@{ Name = 'san-vol-01'; Path = 'C:\ClusterStorage\Volume1' })
                        }
                        return @{ Computer = 'iic-azl-n01'; MpioRead = $true; Disks = @($disk); Resources = $resources; Csvs = $csvs }
                    }
                    return @{ Pools = @(@{ Name = 'SU1_Pool'; Thresholds = @(70) }); Volumes = @($global:AzlPlanState.Volumes); Tiers = @('MirrorOnSSD', 'ParityOnSSD'); BlockCacheSize = 1024; Nodes = @('iic-azl-n01', 'iic-azl-n02') }
                }
                'ReadDisks' { return @{ Computer = [string]$ComputerName; UniqueIds = $(if ($global:AzlPlanState.PeerSeesLun) { @($global:AzlPlanState.Disk.UniqueId) } else { @() }) } }
                'Verify' {
                    $names = @($global:AzlPlanState.Volumes | Where-Object { $_ -notmatch '^Infrastructure_' })
                    $s = $global:AzlPlanState
                    return @{ PoolHealth = $s.PoolHealth; PoolOperational = 'OK'
                        VirtualDisks = @($names | ForEach-Object { @{ Name = $_; Health = 'Healthy'; Operational = 'OK'; Size = [long]$s.VdSize; Provisioning = $s.VdProvisioning; Setting = $s.VdSetting; Redundancy = $s.VdRedundancy; Tiers = @() } })
                        Csvs = @($names | ForEach-Object { @{ Name = "Cluster Virtual Disk ($_)"; State = 'Online' } }) }
                }
                'VerifySan' {
                    $s = $global:AzlPlanState
                    return @{ MpioRead = $true; Disks = @(@{ UniqueId = $s.Disk.UniqueId; Health = $s.SanHealth; Operational = 'OK'; Paths = $s.SanPaths }); Csvs = @(@{ Name = 'san-vol-01'; State = $s.SanCsvState }) }
                }
                default { return $null }
            }
        }
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlPlanTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlPlanSub } } }
        Mock Set-AzContext { }
        Mock Get-AzStackHCIVMStoragePath {
            if (-not $global:AzlPlanState.StoragePath) { throw "(ResourceNotFound) The Resource 'storagecontainers/$Name' was not found." }
            [pscustomobject]@{ Name = $Name; Path = $global:AzlPlanState.StoragePath; ProvisioningState = $global:AzlPlanState.StoragePathState }
        }
        Mock New-AzStackHCIVMStoragePath { $global:AzlPlanCalls.Add([pscustomobject]@{ Command = 'New-AzStackHCIVMStoragePath' }) }
        Mock az {
            $a = @($args | ForEach-Object { [string]$_ })
            $words = @(); foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
            $command = $words -join ' '
            $global:AzlPlanCalls.Add([pscustomobject]@{ Command = $command; Arguments = $a })
            $fail = { param($code, $message) $global:LASTEXITCODE = $code; [Management.Automation.ErrorRecord]::new([Exception]::new($message), 'az', 'NotSpecified', $null) }
            $global:LASTEXITCODE = 0
            switch ($command) {
                'account show' { return ('{"tenantId":"' + $global:AzlPlanTenant + '","id":"' + $global:AzlPlanSub + '"}') }
                'extension show' { return '{"name":"stack-hci-vm"}' }
                'stack-hci-vm storagepath show' {
                    if (-not $global:AzlPlanState.StoragePath) { return (& $fail 3 "(ResourceNotFound) The Resource 'storagecontainers/x' was not found.") }
                    return ('{"name":"x","properties":{"path":"' + ($global:AzlPlanState.StoragePath -replace '\\', '\\') + '","provisioningState":"' + $global:AzlPlanState.StoragePathState + '"}}')
                }
                default { return (& $fail 2 "unexpected az call: $command") }
            }
        }
    }

    Context '<Name>' -ForEach $script:Cases {
        BeforeAll { $script:This = $script:Paths[$Name] }

        It 'takes -InfrastructureFile as its only mandatory parameter, and -WhatIf and -LogPath' {
            $command = Get-Command -Name $script:This
            @($command.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory } } | ForEach-Object Name) | Should -Be @('InfrastructureFile')
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $command.Parameters.ContainsKey('LogPath') | Should -BeTrue
            @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters -and $_ -notin 'InfrastructureFile', 'LogPath' } | Sort-Object) | Should -Be @($Own | Sort-Object)
        }

        It 'plans against the toolkit example as it is, alone: exit 0, and nothing is changed' {
            # The example plans one volume (the volume script plans it), has no SAN (nothing to do) and lists no storage path (nothing to do).
            $r = Invoke-Alone $script:This (New-PlanFile) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-Change | Should -BeNullOrEmpty
        }
    }

    Context 'New-StorageVolume.ps1 reads the cluster, plans the volume and checks what exists' {
        It 'plans the volume of the example as WouldCreate (two machines, two-way), with the log written' {
            $log = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
            $r = Invoke-Alone $script:Paths['New-StorageVolume.ps1'] (New-PlanFile -Values) @{ LogPath = $log }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Item -EQ 'volume vol-workloads-01').Action | Should -Be 'WouldCreate'
            @($global:AzlPlanRemote | Where-Object Step -EQ 'ReadState').Count | Should -Be 1
            (Get-Content -LiteralPath $log -Raw).Trim() | Should -Not -BeNullOrEmpty
            Get-Change | Should -BeNullOrEmpty
        }

        It 'is idempotent: a volume that exists is AlreadyExists and its pool, virtual disk and CSV are verified' {
            $global:AzlPlanState.Volumes = @('Infrastructure_1', 'vol-workloads-01')
            $r = Invoke-Alone $script:Paths['New-StorageVolume.ps1'] (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Item -EQ 'volume vol-workloads-01').Action | Should -Be 'AlreadyExists'
            @($r.Rows | Where-Object Item -Like 'check *').Action | Should -Be @('Verified', 'Verified')
            Get-Change | Should -BeNullOrEmpty
        }

        It 'fails (exit 1) when the pool is not Healthy' {
            $global:AzlPlanState.Volumes = @('Infrastructure_1', 'vol-workloads-01'); $global:AzlPlanState.PoolHealth = 'Warning'
            $r = Invoke-Alone $script:Paths['New-StorageVolume.ps1'] (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Item -Like 'check storage pool*').Action | Should -Be 'Failed'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'fails (exit 1) when an existing volume is not the size, the provisioning or the resiliency of the file, and says which; it changes nothing' {
            $global:AzlPlanState.Volumes = @('Infrastructure_1', 'vol-workloads-01')
            $file = New-PlanFile -Values -Edit { param($doc) $doc.storage.volumes[0].provisioning_type = 'thin' }
            $global:AzlPlanState.VdSize = 2048 * 1GB; $global:AzlPlanState.VdProvisioning = 'Fixed'; $global:AzlPlanState.VdRedundancy = 2
            $r = Invoke-Alone $script:Paths['New-StorageVolume.ps1'] $file @{}
            $r.ExitCode | Should -Be 1
            $row = @($r.Rows | Where-Object Item -EQ 'check volume vol-workloads-01')
            $row.Action | Should -Be 'Failed'
            $row.Detail | Should -Match 'size is 2048 GiB, the file says 4096 GiB'
            $row.Detail | Should -Match 'provisioning is Fixed, the file says Thin'
            $row.Detail | Should -Match 'resiliency is Mirror with redundancy 2'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'verifies an existing volume that is the size, the provisioning and the resiliency of the file' {
            $global:AzlPlanState.Volumes = @('Infrastructure_1', 'vol-workloads-01')
            $file = New-PlanFile -Values -Edit { param($doc) $doc.storage.volumes[0].provisioning_type = 'thin' }
            $r = Invoke-Alone $script:Paths['New-StorageVolume.ps1'] $file @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Item -EQ 'check volume vol-workloads-01').Action | Should -Be 'Verified'
        }

        It 'refuses a volume name the deployment manages with exit code 2, before the cluster is asked' {
            $file = New-PlanFile -Values -Edit { param($doc) $doc.storage.volumes[0].name = 'UserStorage_9' }
            $r = Invoke-Alone $script:Paths['New-StorageVolume.ps1'] $file @{}
            $r.ExitCode | Should -Be 2
            $global:AzlPlanRemote | Where-Object Step -EQ 'ReadState' | Should -BeNullOrEmpty
        }
    }

    Context 'New-SanVolume.ps1 reads every node and plans the LUN' {
        It 'has nothing to do for the example as it is (s2d, no SAN)' {
            $r = Invoke-Alone $script:Paths['New-SanVolume.ps1'] (New-PlanFile) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlPlanRemote.Count | Should -Be 0
        }

        It 'plans the LUN as WouldCreate when every node sees it, and prepares nothing' {
            $r = Invoke-Alone $script:Paths['New-SanVolume.ps1'] (New-PlanFile -Values -Edit $script:AddSan) @{}
            $r.ExitCode | Should -Be 0 -Because ($r.Text -replace "`n", " | ")
            @($r.Rows | Where-Object Item -EQ 'LUN san-vol-01').Action | Should -Be 'WouldCreate'
            @($global:AzlPlanRemote | Where-Object Step -EQ 'ReadDisks').Count | Should -Be 2
            Get-Change | Should -BeNullOrEmpty
        }

        It 'verifies a LUN that is a CSV already (AlreadyExists, then the check of the page), and changes nothing' {
            $global:AzlPlanState.SanCsv = $true
            $r = Invoke-Alone $script:Paths['New-SanVolume.ps1'] (New-PlanFile -Values -Edit $script:AddSan) @{}
            $r.ExitCode | Should -Be 0 -Because ($r.Text -replace "`n", ' | ')
            @($r.Rows | Where-Object Item -EQ 'LUN san-vol-01').Action | Should -Be 'AlreadyExists'
            @($r.Rows | Where-Object Item -EQ 'check LUN san-vol-01').Action | Should -Be 'Verified'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'fails the check (exit 1) when the disk is not Healthy or the CSV is not Online, and only warns about one MPIO path' {
            $global:AzlPlanState.SanCsv = $true; $global:AzlPlanState.SanHealth = 'Warning'; $global:AzlPlanState.SanPaths = 1; $global:AzlPlanState.SanCsvState = 'Offline'
            $r = Invoke-Alone $script:Paths['New-SanVolume.ps1'] (New-PlanFile -Values -Edit $script:AddSan) @{}
            $r.ExitCode | Should -Be 1
            $row = @($r.Rows | Where-Object Item -EQ 'check LUN san-vol-01')
            $row.Action | Should -Be 'Failed'
            $row.Detail | Should -Match 'disk health Warning'
            $r.Text | Should -Match 'MPIO reports 1 path'
            $row.Detail | Should -Match 'state Offline'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'refuses the LUN (exit 1) when a node does not see it, and prepares nothing' {
            $global:AzlPlanState.PeerSeesLun = $false
            $r = Invoke-Alone $script:Paths['New-SanVolume.ps1'] (New-PlanFile -Values -Edit $script:AddSan) @{}
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Item -EQ 'LUN san-vol-01').Action | Should -Be 'Refused'
            $r.Text | Should -Match 'does not see'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'refuses a disk that is not empty (exit 1) and never plans to format it' {
            $global:AzlPlanState.Disk.PartitionStyle = 'GPT'; $global:AzlPlanState.Disk.Partitions = 2
            $r = Invoke-Alone $script:Paths['New-SanVolume.ps1'] (New-PlanFile -Values -Edit $script:AddSan) @{}
            $r.ExitCode | Should -Be 1
            Get-Change | Should -BeNullOrEmpty
        }

        It 'stops with exit code 2 for a LUN without a UniqueId' {
            $file = New-PlanFile -Values -Edit { param($doc) & $script:AddSan $doc; $doc.storage.san.luns[0].Remove('unique_id') }
            $r = Invoke-Alone $script:Paths['New-SanVolume.ps1'] $file @{}
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'unique_id'
        }
    }

    Context 'the storage path scripts' {
        It '<Script> plans the path of the example as WouldCreate, alone, and creates nothing' -ForEach @(@{ Script = 'New-StoragePath.ps1' }, @{ Script = 'New-StoragePath.azcli.ps1' }) {
            $r = Invoke-Alone $script:Paths[$Script] (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('WouldCreate')
            Get-Change | Should -BeNullOrEmpty
        }

        It '<Script> is idempotent: a path that exists and Succeeded is AlreadyExists; one in the Failed state fails the run' -ForEach @(@{ Script = 'New-StoragePath.ps1' }, @{ Script = 'New-StoragePath.azcli.ps1' }) {
            $global:AzlPlanState.StoragePath = 'C:\ClusterStorage\vol-workloads-01\vms'
            $r = Invoke-Alone $script:Paths[$Script] (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('AlreadyExists')
            $global:AzlPlanState.StoragePathState = 'Failed'
            $r = Invoke-Alone $script:Paths[$Script] (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 1
            Get-Change | Should -BeNullOrEmpty
        }

        It '<Script> stops with exit code 2 on the all-zero placeholder ids of the example when it lists a path, and sends nothing' -ForEach @(@{ Script = 'New-StoragePath.ps1' }, @{ Script = 'New-StoragePath.azcli.ps1' }) {
            $file = New-PlanFile -Edit { param($doc) $doc.storage.paths = @([ordered]@{ name = 'sp-workloads-01'; path = 'C:\ClusterStorage\vol-workloads-01\vms' }) }
            $r = Invoke-Alone $script:Paths[$Script] $file @{}
            $r.ExitCode | Should -Be 2
            $global:AzlPlanCalls.Count | Should -Be 0
        }

        It '<Script> refuses a path on the infrastructure volume with exit code 2' -ForEach @(@{ Script = 'New-StoragePath.ps1' }, @{ Script = 'New-StoragePath.azcli.ps1' }) {
            $file = New-PlanFile -Values -Edit { param($doc) $doc.storage.paths[0].path = 'C:\ClusterStorage\Infrastructure_1\vms' }
            $r = Invoke-Alone $script:Paths[$Script] $file @{}
            $r.ExitCode | Should -Be 2
            Get-Change | Should -BeNullOrEmpty
        }
    }
}
