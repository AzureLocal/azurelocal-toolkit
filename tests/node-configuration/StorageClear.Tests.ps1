#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The node-side storage clear, run in Windows PowerShell 5.1 (the node's shell) with every storage and cluster cmdlet replaced by a recording stub. The stubs
# are functions in the wrapper script, so they win over the real cmdlets: nothing here reads or changes a disk of this machine, and no node is reached.
# What is proved: the clear refuses a node that belongs to a cluster, touches only the disks the action names, never a SAN, USB, virtual, boot or system
# disk even when the action names it, and the Read script reports the evidence the wipe list needs (serial, size, model, bus, partition style).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/StorageClear.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
param()

BeforeDiscovery {
    $script:HasWindowsPowerShell = [bool](Get-Command powershell.exe -ErrorAction SilentlyContinue)
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = [IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration')
    Import-Module (Join-Path $dir 'AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $dir 'AzlNodeTransport.psm1') -Force

    # The wrapper that plays the node. Windows PowerShell 5.1 syntax.
    $script:Runner = @'
param([string]$Payload, [string]$ParamsB64, [string]$Scenario, [string]$CallsOut)
$ErrorActionPreference = 'Stop'
$sc = Get-Content -LiteralPath $Scenario -Raw | ConvertFrom-Json
$calls = New-Object System.Collections.ArrayList
function Note([string]$what) { [void]$calls.Add($what) }
function Test-Path {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Path, [string]$PathType)
    $p = $LiteralPath; if (-not $p) { $p = $Path }
    if ($p -eq 'HKLM:\Cluster') { return [bool]$sc.registry }
    if ($p -eq 'C:\ClusterStorage') { return [bool]$sc.csv }
    return (Microsoft.PowerShell.Management\Test-Path @PSBoundParameters)
}
function Get-Service {
    [CmdletBinding()] param([string]$Name)
    if ($Name -eq 'ClusSvc') { if ($sc.serviceStatus) { return [pscustomobject]@{ Name = 'ClusSvc'; Status = [string]$sc.serviceStatus } }; return $null }
    return (Microsoft.PowerShell.Management\Get-Service @PSBoundParameters)
}
function Get-ItemProperty {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath)
    $p = $LiteralPath; if (-not $p) { $p = $Path }
    if ($p -eq 'HKLM:\Cluster') { if (-not $sc.registry) { return $null }; if ($sc.registryName) { return [pscustomobject]@{ ClusterName = [string]$sc.registryName } }; return [pscustomobject]@{ SomethingElse = 1 } }
    return (Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters)
}
function Get-ChildItem {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath)
    $p = $LiteralPath; if (-not $p) { $p = $Path }
    if ($p -eq 'C:\ClusterStorage') { foreach ($n in @($sc.csvFiles)) { [pscustomobject]@{ Name = [string]$n } }; return }
    return (Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters)
}
function New-Item { [CmdletBinding()] param($ItemType, [switch]$Force, $Path) }
function Set-Content { [CmdletBinding()] param($LiteralPath, [Parameter(ValueFromPipeline = $true)]$Value, $Encoding) process { } }
function Get-Disk { [CmdletBinding()] param() foreach ($d in @($sc.disks)) { $d } }
function Get-StoragePool { [CmdletBinding()] param() foreach ($p in @($sc.pools)) { $p } }
function Get-PhysicalDisk {
    [CmdletBinding()] param($StoragePool)
    foreach ($p in @($sc.pdisks)) { if (-not $StoragePool -or $p.Pool -eq $StoragePool.FriendlyName) { $p } }
}
function Get-VirtualDisk {
    [CmdletBinding()] param($StoragePool)
    foreach ($v in @($sc.vdisks)) { if (-not $StoragePool -or $v.Pool -eq $StoragePool.FriendlyName) { $v } }
}
function Update-StorageProviderCache { [CmdletBinding()] param() Note 'Update-StorageProviderCache' }
function Set-StoragePool { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, $IsReadOnly) process { Note ('Set-StoragePool ' + $InputObject.FriendlyName) } }
function Remove-VirtualDisk { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, $Confirm) process { Note ('Remove-VirtualDisk ' + $InputObject.FriendlyName) } }
function Remove-StoragePool { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, $Confirm) process { Note ('Remove-StoragePool ' + $InputObject.FriendlyName) } }
function Reset-PhysicalDisk { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject) process { Note ('Reset-PhysicalDisk ' + $InputObject.SerialNumber) } }
function Set-Disk { [CmdletBinding()] param($Number, $IsOffline, $IsReadOnly) Note ('Set-Disk ' + $Number) }
function Clear-Disk { [CmdletBinding()] param($Number, [switch]$RemoveData, [switch]$RemoveOEM, $Confirm) Note ('Clear-Disk ' + $Number) }
& $Payload -ParamsB64 $ParamsB64
[IO.File]::WriteAllText($CallsOut, (ConvertTo-Json -InputObject @($calls) -Compress))
'@

    function New-D([int]$Number, [string]$Serial, [string]$Bus = 'NVMe', [string]$Style = 'GPT', [bool]$Boot = $false) {
        [ordered]@{ Number = $Number; FriendlyName = "Disk $Number"; Model = 'ACME NVMe 1T'; SerialNumber = " $Serial "; UniqueId = "UID-$Serial"; Size = 1000GB; BusType = $Bus; PartitionStyle = $Style
            IsBoot = $Boot; IsSystem = $Boot; IsOffline = $false; IsReadOnly = $false; OperationalStatus = 'Online' }
    }
    function New-PD([string]$Serial, [string]$Pool, [string]$Bus = 'NVMe') {
        [ordered]@{ FriendlyName = "PD $Serial"; SerialNumber = $Serial; UniqueId = "UID-$Serial"; Size = 2000GB; BusType = $Bus; Model = 'ACME SAS 2T'; Pool = $Pool }
    }

    # The node of the scenarios: a boot disk, two leftover data disks, one more data disk nobody approved, a SAN LUN, a USB stick, an old pool with two disks and a
    # virtual disk, and a second pool that holds a disk nobody approved.
    # By default the node is a plain Azure Local node that never joined a cluster: no pool, ClusSvc not installed (serviceStatus ''), no HKLM:\Cluster, no CSV folder.
    # -Pools adds an old pool with two disks and a virtual disk, and a second pool that holds a disk nobody approved (an S2D pool is deployed-cluster evidence).
    function New-Scenario([hashtable]$With = @{}, [switch]$Pools) {
        $s = [ordered]@{
            registry = $false; registryName = ''; serviceStatus = ''; csv = $false; csvFiles = @()
            disks  = @((New-D 0 'BOOT-0' 'SATA' 'GPT' $true), (New-D 3 'SN-3'), (New-D 4 'SN-4'), (New-D 5 'SN-5' 'SAS'), (New-D 6 'SN-SAN' 'Fibre Channel'), (New-D 7 'SN-USB' 'USB'))
            pools  = @([ordered]@{ FriendlyName = 'Primordial'; IsPrimordial = $true; IsClustered = $false })
            pdisks = @((New-PD 'SN-3' 'Primordial'))
            vdisks = @()
        }
        if ($Pools) {
            $s.pools = @([ordered]@{ FriendlyName = 'Primordial'; IsPrimordial = $true; IsClustered = $false }, [ordered]@{ FriendlyName = 'OldPool'; IsPrimordial = $false; IsClustered = $false }, [ordered]@{ FriendlyName = 'OtherPool'; IsPrimordial = $false; IsClustered = $false })
            $s.pdisks = @((New-PD 'SN-P1' 'OldPool' 'SAS'), (New-PD 'SN-P2' 'OldPool' 'SAS'), (New-PD 'SN-P3' 'OtherPool' 'SAS'), (New-PD 'SN-3' 'Primordial'))
            $s.vdisks = @([ordered]@{ FriendlyName = 'OldVD'; Pool = 'OldPool' }, [ordered]@{ FriendlyName = 'OtherVD'; Pool = 'OtherPool' })
        }
        foreach ($k in $With.Keys) { $s[$k] = $With[$k] }
        $s
    }

    # Runs a payload in Windows PowerShell 5.1 against the stubs. Returns the decoded result and the calls the stubs recorded.
    function Invoke-NodePayload([string]$Name, [hashtable]$Scenario, [hashtable]$Parameters = @{}) {
        $id = [guid]::NewGuid().ToString('N').Substring(0, 6)
        $runner = Join-Path $TestDrive "runner-$id.ps1"
        $payload = Join-Path $TestDrive "payload-$id.ps1"
        $scenarioFile = Join-Path $TestDrive "scenario-$id.json"
        $callsFile = Join-Path $TestDrive "calls-$id.json"
        [IO.File]::WriteAllText($runner, $script:Runner, [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText($payload, (Get-AzlNodePayload -Name $Name), [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText($scenarioFile, ($Scenario | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Parameters | ConvertTo-Json -Depth 8 -Compress)))
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Payload $payload -ParamsB64 $b64 -Scenario $scenarioFile -CallsOut $callsFile 2>&1
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        $result = ConvertTo-AzlNodeResult -Text $text
        $calls = if (Test-Path -LiteralPath $callsFile) { @(Get-Content -LiteralPath $callsFile -Raw | ConvertFrom-Json) } else { @() }
        [pscustomobject]@{ Result = $result; Calls = $calls; Text = $text }
    }
    function Invoke-Clear([hashtable]$Scenario, [string[]]$Serial, [bool]$ConfirmCluster = $false) {
        $action = [ordered]@{ id = 'ClearStorage/local'; kind = 'storage-clear'; serials = @($Serial); confirmDeployedCluster = $ConfirmCluster }
        Invoke-NodePayload -Name Apply -Scenario $Scenario -Parameters @{ actions = @($action) }
    }
    function Get-Destructive($Run) { @($Run.Calls | Where-Object { $_ -match '^(Clear-Disk|Remove-|Reset-PhysicalDisk|Set-Disk|Set-StoragePool)' }) }
}

Describe 'storage-clear on the node: a deployed cluster is refused' -Skip:(-not $script:HasWindowsPowerShell) {
    It '<Name>: refused, the detail says which evidence tripped it, nothing is touched' -ForEach @(
        @{ Name = 'ClusSvc is Running'; With = @{ serviceStatus = 'Running' }; Pools = $false; Reason = 'ClusSvc\) is running' }
        @{ Name = 'HKLM:\Cluster names a cluster'; With = @{ registry = $true; registryName = 'tplabs-cl01' }; Pools = $false; Reason = "HKLM:.Cluster names the cluster 'tplabs-cl01'" }
        @{ Name = 'C:\ClusterStorage holds a volume'; With = @{ csv = $true; csvFiles = @('Volume1') }; Pools = $false; Reason = 'C:.ClusterStorage holds' }
        @{ Name = 'an S2D pool exists'; With = @{}; Pools = $true; Reason = 'pool exists.*OldPool' }
    ) {
        $run = Invoke-Clear (New-Scenario $With -Pools:$Pools) @('SN-3', 'SN-4')
        $run.Result.results[0].status | Should -Be 'failed'
        $run.Result.results[0].detail | Should -Match 'deployed cluster'
        $run.Result.results[0].detail | Should -Match $Reason
        Get-Destructive $run | Should -BeNullOrEmpty
    }
    It 'a pool that belongs to a cluster refuses it too, and is named' {
        $s = New-Scenario
        $s.pools = @([ordered]@{ FriendlyName = 'Primordial'; IsPrimordial = $true; IsClustered = $false }, [ordered]@{ FriendlyName = 'S2D on cluster'; IsPrimordial = $false; IsClustered = $true })
        $run = Invoke-Clear $s @('SN-3')
        $run.Result.results[0].status | Should -Be 'failed'
        $run.Result.results[0].detail | Should -Match 'owned by a cluster: S2D on cluster'
        Get-Destructive $run | Should -BeNullOrEmpty
    }
    It 'with the confirmation in the action it goes ahead' {
        $run = Invoke-Clear (New-Scenario @{ serviceStatus = 'Running' }) @('SN-3') $true
        $run.Result.results[0].status | Should -Be 'changed'
        @($run.Calls) | Should -Contain 'Clear-Disk 3'
    }
    It 'an action that names no serial wipes nothing' {
        $run = Invoke-Clear (New-Scenario) @()
        $run.Result.results[0].status | Should -Be 'failed'
        $run.Result.results[0].detail | Should -Match 'no approved disk'
        Get-Destructive $run | Should -BeNullOrEmpty
    }
}

Describe 'storage-clear on the node: a node that never joined a cluster is not a deployed cluster' -Skip:(-not $script:HasWindowsPowerShell) {
    # The Azure Local OS always has the Cluster service installed (Failover Clustering is part of the image). That alone is not membership.
    It '<Name>: the wipe is allowed without the confirmation' -ForEach @(
        @{ Name = 'ClusSvc installed and Stopped, no HKLM:\Cluster'; With = @{ serviceStatus = 'Stopped' } }
        @{ Name = 'ClusSvc installed and Stopped, HKLM:\Cluster without a cluster name'; With = @{ serviceStatus = 'Stopped'; registry = $true } }
        @{ Name = 'an empty C:\ClusterStorage and a stopped ClusSvc'; With = @{ serviceStatus = 'Stopped'; csv = $true; csvFiles = @() } }
        @{ Name = 'no ClusSvc at all'; With = @{} }
    ) {
        $run = Invoke-Clear (New-Scenario $With) @('SN-3', 'SN-4')
        $run.Result.results[0].status | Should -Be 'changed'
        @($run.Calls) | Should -Contain 'Clear-Disk 3'
        @($run.Calls) | Should -Contain 'Clear-Disk 4'
    }
}

Describe 'storage-clear on the node: only what the action names, and never a SAN, USB, virtual, boot or system disk' -Skip:(-not $script:HasWindowsPowerShell) {
    BeforeAll {
        # Every serial of the node is named, the SAN LUN, the USB stick and the boot disk included, except SN-5 and SN-P3. The pools are S2D evidence, so the run confirms.
        $script:Run = Invoke-Clear (New-Scenario -Pools) @('SN-3', 'SN-4', 'SN-SAN', 'SN-USB', 'BOOT-0', 'SN-P1', 'SN-P2') $true
    }
    It 'succeeds' { $script:Run.Result.results[0].status | Should -Be 'changed' }
    It 'clears the named local disks' {
        @($script:Run.Calls) | Should -Contain 'Clear-Disk 3'
        @($script:Run.Calls) | Should -Contain 'Clear-Disk 4'
    }
    It 'does not clear a local disk the action does not name (SN-5)' { @($script:Run.Calls) | Should -Not -Contain 'Clear-Disk 5' }
    It 'does not clear the boot disk, the SAN LUN or the USB stick although the action names them' {
        foreach ($n in 0, 6, 7) { @($script:Run.Calls) | Should -Not -Contain "Clear-Disk $n" }
    }
    It 'removes the pool whose disks are all named, with its own virtual disk' {
        @($script:Run.Calls) | Should -Contain 'Remove-VirtualDisk OldVD'
        @($script:Run.Calls) | Should -Contain 'Remove-StoragePool OldPool'
    }
    It 'leaves the pool that holds a disk the action does not name, and its virtual disk' {
        @($script:Run.Calls) | Should -Not -Contain 'Remove-StoragePool OtherPool'
        @($script:Run.Calls) | Should -Not -Contain 'Remove-VirtualDisk OtherVD'
        $script:Run.Result.results[0].detail | Should -Match 'OtherPool'
    }
    It 'resets only the named physical disks' {
        @($script:Run.Calls) | Should -Contain 'Reset-PhysicalDisk SN-P1'
        @($script:Run.Calls) | Should -Contain 'Reset-PhysicalDisk SN-P2'
        @($script:Run.Calls) | Should -Not -Contain 'Reset-PhysicalDisk SN-P3'
    }
    It 'does not touch a primordial pool' {
        @($script:Run.Calls | Where-Object { $_ -like '*Primordial*' }) | Should -BeNullOrEmpty
    }
}

Describe 'the Read script reports what the wipe list needs' -Skip:(-not $script:HasWindowsPowerShell) {
    It 'names every leftover local disk by serial, size, model, bus and partition style, and lists pool members' {
        $run = Invoke-NodePayload -Name Read -Scenario (New-Scenario -Pools) -Parameters @{ mgmtMac = '' }
        $stor = $run.Result.stor
        $stor | Should -Not -BeNullOrEmpty
        $byId = @{}; foreach ($d in @($stor.dirty)) { $byId[$d.id] = $d }
        # SN-3 appears as a physical disk of the primordial pool and as a partitioned disk: one entry. SN-5 is partitioned. Boot, SAN and USB never appear.
        foreach ($id in 'SN-3', 'SN-4', 'SN-5', 'SN-P1', 'SN-P2', 'SN-P3') { $byId.Keys | Should -Contain $id }
        foreach ($id in 'BOOT-0', 'SN-SAN', 'SN-USB') { $byId.Keys | Should -Not -Contain $id }
        @($stor.dirty).Count | Should -Be 6
        $d = $byId['SN-4']
        $d.sn | Should -Be 'SN-4'
        $d.uid | Should -Be 'UID-SN-4'
        $d.size | Should -Be 1000GB
        $d.model | Should -Be 'ACME NVMe 1T'
        $d.bus | Should -Be 'NVMe'
        $d.ps | Should -Be 'GPT'
        $d.n | Should -Be 4
        $byId['SN-P1'].why | Should -Match 'OldPool'
    }
    It 'a node that never joined a cluster is not deployed, whatever the image has installed (ClusSvc Stopped, an HKLM:\Cluster key without a name, an empty CSV folder)' {
        foreach ($with in @{}, @{ serviceStatus = 'Stopped' }, @{ serviceStatus = 'Stopped'; registry = $true }, @{ serviceStatus = 'Stopped'; csv = $true; csvFiles = @() }) {
            $stor = (Invoke-NodePayload -Name Read -Scenario (New-Scenario $with) -Parameters @{ mgmtMac = '' }).Result.stor
            $stor.cluster.deployed | Should -BeFalse -Because ($with | ConvertTo-Json -Compress)
            @($stor.cluster.why) | Should -BeNullOrEmpty
        }
    }
    It '<Name> is deployed, and says which evidence' -ForEach @(
        @{ Name = 'a running ClusSvc'; With = @{ serviceStatus = 'Running' }; Pools = $false; Evidence = 'ClusSvc\) is running' }
        @{ Name = 'HKLM:\Cluster with a cluster name'; With = @{ registry = $true; registryName = 'tplabs-cl01' }; Pools = $false; Evidence = "HKLM:.Cluster names the cluster 'tplabs-cl01'" }
        @{ Name = 'C:\ClusterStorage with a volume'; With = @{ csv = $true; csvFiles = @('Volume1') }; Pools = $false; Evidence = 'C:.ClusterStorage holds' }
        @{ Name = 'an S2D pool'; With = @{}; Pools = $true; Evidence = 'pool exists.*OldPool' }
    ) {
        $stor = (Invoke-NodePayload -Name Read -Scenario (New-Scenario $With -Pools:$Pools) -Parameters @{ mgmtMac = '' }).Result.stor
        $stor.cluster.deployed | Should -BeTrue
        (@($stor.cluster.why) -join ' ') | Should -Match $Evidence
    }
}