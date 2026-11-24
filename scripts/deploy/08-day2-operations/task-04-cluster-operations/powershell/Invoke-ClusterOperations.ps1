<#
.SYNOPSIS
    Day 2 operations on an Azure Local cluster: health check, maintenance mode of a node, live migration, CSV ownership, capacity and alerts.

.DESCRIPTION
    Day 2, stage 08 task 04. One action per run. The script connects to the cluster (cluster.name) or to one node with PowerShell remoting and runs the cluster cmdlets
    there, so the machine that runs the script needs no failover clustering tools. HealthCheck, Capacity and Alerts only read. MaintenanceMode, LiveMigrate and
    Rebalance change the cluster; each change is behind -WhatIf and -Confirm. The script does not sign in anywhere and asks nothing. It connects as the account that runs
    it, or as -Credential.

    Actions, and what Microsoft Learn says about each (Suspend and resume Azure Local machines for maintenance; Failover cluster maintenance procedures; Storage Spaces Direct):

      HealthCheck       cluster nodes (all Up), storage pools and virtual disks (Healthy, OK), storage repair jobs (Get-StorageJob: no repair running), cluster networks (Up) and the
                        Azure Arc agent of every node that is Up (azcmagent show). Exit code 1 when anything is not healthy.
      MaintenanceMode   -Enable: checks that it is safe (the other nodes are Up, every virtual disk is Healthy and OK, no storage repair job is running, and the node has
                        Remove-MocPhysicalNode and New-MocPhysicalNode: if not, the run stops before anything is changed), then
                        Suspend-ClusterNode -Drain -Wait (the roles and virtual machines move to the other nodes and the node shows Paused), then Remove-MocPhysicalNode on that
                        node, so that no new virtual machine is placed on it (the Azure Local step of Learn; it exists on 2311.2 or later and is done from PowerShell only).
                        Without -Enable: first checks that the node has New-MocPhysicalNode (if not, nothing is resumed), then Resume-ClusterNode -Failback Immediate,
                        New-MocPhysicalNode (the node takes virtual machines again), and a read of the storage repair
                        jobs: wait until they have finished before another node is taken offline (Get-StorageJob; Learn: it is not safe to take another server offline until the
                        repair jobs finish). To reboot a node in one run, use task 03 (Invoke-NodeMaintenanceReboot.ps1), which also waits for the repair.
      LiveMigrate       moves the clustered virtual machines of -NodeName to the other nodes that are Up, each to the node with the fewest virtual machines, with
                        Move-ClusterVirtualMachineRole -MigrationType Live (the cmdlet for a clustered virtual machine; Move-VM is not used on a clustered one).
      Rebalance         spreads the cluster shared volumes evenly over the nodes that are Up with Move-ClusterSharedVolume: one volume at a time moves from the node that owns the most
                        to the node that owns the fewest, until no two nodes differ by more than one volume (every node owns the floor or the ceiling of volumes divided by nodes). A
                        node with fewer than the floor gets volumes when others are above it; 2, 2 and 0 volumes become 1, 2 and 1. A balanced cluster moves nothing. A failed move stops the run (exit code 1).
      Capacity          size and used space of the storage pools, memory and virtual processors assigned on every node that is Up.
      Alerts            the faults of the Health Service (Debug-StorageSubSystem on the clustered subsystem), the storage health actions, and the Critical, Error and Warning events of the
                        failover clustering operational log of the last 24 hours (at most 20).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name                                  the cluster to connect to
        nodes[].name                                  -NodeName is matched against it (a name, a fully qualified name with identity.active_directory.domain_fqdn, or an address);
                                                      a name that is not in the file is used as it is, with a warning (exit code 2 with -RequireNodeInFile)

    Output: one row per finding or step (Item, Action, Detail). With -OutputPath the rows are also written as JSON.

    Exit codes: 0 the action finished (or is planned under -WhatIf) and HealthCheck or Alerts found nothing wrong; 1 a step failed, or HealthCheck or Alerts found something;
    2 cluster.name is missing, the file cannot be read, an action that needs -NodeName has none, or -RequireNodeInFile is given and the node is not in nodes[]. Nothing is sent to the cluster on exit code 2.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Reads cluster.name and nodes[] (name, management address) and identity.active_directory.domain_fqdn (to match a fully qualified -NodeName); the whole file is not validated here.

.PARAMETER Action
    The action: HealthCheck, MaintenanceMode, LiveMigrate, Rebalance, Capacity or Alerts.

.PARAMETER NodeName
    The node of MaintenanceMode and LiveMigrate: host name, fully qualified name or management address.

.PARAMETER Enable
    With MaintenanceMode: put the node into maintenance (suspend, drain, remove from the virtual machine configuration). Without it the node leaves maintenance.

.PARAMETER RequireNodeInFile
    Refuse a -NodeName that is not a node of nodes[] in the file (exit code 2, before anything is sent to the cluster): a pipeline passes it so that a mistyped node name or an
    address from outside the file never reaches a machine. Without it a name that is not in the file is used as it is, with a warning.

.PARAMETER Credential
    Optional. The account for the remoting sessions (an administrator of the cluster). Without it the account that runs the script is used.

.PARAMETER OutputPath
    Optional. Also write the rows as JSON to this file. Keep it out of the repository.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Invoke-ClusterOperations.ps1 -InfrastructureFile ./infrastructure.yml -Action HealthCheck -OutputPath ./health.json

.EXAMPLE
    ./Invoke-ClusterOperations.ps1 -InfrastructureFile ./infrastructure.yml -Action MaintenanceMode -NodeName node01 -Enable -WhatIf

    Shows what entering maintenance mode would do. Changes nothing.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [Parameter(Mandatory)][ValidateSet('HealthCheck', 'MaintenanceMode', 'LiveMigrate', 'Rebalance', 'Capacity', 'Alerts')][string]$Action,
    [string]$NodeName,
    [switch]$Enable,
    [switch]$RequireNodeInFile,
    [string]$ComputerName,
    [pscredential]$Credential,
    [string]$OutputPath,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath
$enterMaintenance = $Enable.IsPresent

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'remoting', 'AzlClusterConnection.psm1'))) -Force

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch -Regex ($Action) { '^(Failed|Critical)$' { '[failed] ' } '^Warning$' { '[warning]' } '^Would' { '[plan]    ' } '^(Healthy|OK|Info)$' { '[ok]      ' } default { '[done]    ' } }
    Write-Line ('{0}{1}: {2}{3}' -f $tag, $Item, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}

# One remote call. Every block runs in the remote session: Windows PowerShell on the node, so no PowerShell 7 syntax inside.
function Invoke-Remote([string]$Computer, [scriptblock]$Block, [object[]]$Arguments = @()) {
    # The cluster name means the cluster target of the connection (a node of the file at its management address; the next one when it cannot be
    # reached). Any other name is a node: it is asked at its management address of the file.
    $node = if ($Computer -eq $script:clusterName) { '' } else { $Computer }
    Invoke-AzlClusterCommand -Connection $script:connection -Node $node -ScriptBlock $Block -ArgumentList $Arguments
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }
$clusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing in the infrastructure file. It is the name of the cluster to operate on.' }
$connection = Resolve-AzlClusterConnection -Infrastructure $infra -ComputerName $ComputerName -Credential $Credential -RemoteCommand { param([hashtable]$Call) Invoke-Command @Call }
foreach ($note in $connection.Notes) { Write-Warning $note }
if ($Action -in 'MaintenanceMode', 'LiveMigrate' -and -not $NodeName) { Exit-InputProblem "The action $Action needs -NodeName." }

$node = $null
if ($NodeName) {
    $domain = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory.domain_fqdn')).Trim()
    $wanted = $NodeName.Trim()
    $found = @(Get-AzlInfrastructureNode -Infrastructure $infra | Where-Object { $_.Name -eq $wanted -or ($_.ManagementIp -and $_.ManagementIp -eq $wanted) -or ($domain -and "$($_.Name).$domain" -eq $wanted) } | Select-Object -First 1)
    if ($found.Count -gt 0) { $node = [string]$found[0].Name }
    elseif ($RequireNodeInFile) { Exit-InputProblem "Node '$wanted' is not a node of nodes[] in the infrastructure file, and -RequireNodeInFile is set. Nothing was sent to the cluster." }
    else { $node = $wanted; Write-Line "Node '$wanted' is not in nodes[] of the file: it is used as it is." }
}
$failed = $false

# ---- the remote blocks (read only unless the name says otherwise)
$ReadNodes = { @(Get-ClusterNode | ForEach-Object { @{ Name = [string]$_.Name; State = [string]$_.State; DrainStatus = [string]$_.DrainStatus } }) }
$ReadStorage = {
    @{
        Pools   = @(Get-StoragePool -IsPrimordial $false | ForEach-Object { @{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus; Operational = [string]$_.OperationalStatus; Size = [double]$_.Size; Allocated = [double]$_.AllocatedSize } })
        Disks   = @(Get-VirtualDisk | ForEach-Object { @{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus; Operational = [string]$_.OperationalStatus } })
        Jobs    = @(Get-StorageJob | Where-Object { [string]$_.JobState -ne 'Completed' } | ForEach-Object { @{ Name = [string]$_.Name; State = [string]$_.JobState; Percent = [int]$_.PercentComplete } })
    }
}
$ReadNetworks = { @(Get-ClusterNetwork | ForEach-Object { @{ Name = [string]$_.Name; State = [string]$_.State } }) }
$ReadArc = {
    $agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
    if (-not (Test-Path -LiteralPath $agent)) { return 'Not installed' }
    $json = & $agent show --json 2>&1 | Out-String
    $status = ($json | ConvertFrom-Json).status
    [string]$status
}
$ReadCapacity = {
    $vms = @(Get-VM)
    $assigned = ($vms | Measure-Object -Property MemoryAssigned -Sum).Sum
    $vcpu = ($vms | Measure-Object -Property ProcessorCount -Sum).Sum
    @{
        VmCount = $vms.Count
        TotalMemoryGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 1)
        AssignedMemoryGB = [math]::Round([double]$assigned / 1GB, 1)
        LogicalProcessors = [int](Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        AssignedVcpu = [int]$vcpu
    }
}
$ReadFaults = {
    @{
        Faults  = @(Get-StorageSubSystem -FriendlyName 'Clustered*' | Debug-StorageSubSystem | ForEach-Object { @{ Severity = [string]$_.PerceivedSeverity; Reason = [string]$_.Reason; Target = [string]$_.FaultingObjectDescription } })
        Actions = @(Get-StorageSubSystem -FriendlyName 'Clustered*' | Get-StorageHealthAction | ForEach-Object { @{ State = [string]$_.State; Percent = [string]$_.PercentComplete; Reason = [string]$_.Reason; Error = [string]$_.ErrorDescription } })
        Events  = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-FailoverClustering/Operational'; Level = 1, 2, 3; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 20 -ErrorAction SilentlyContinue | ForEach-Object { @{ Time = $_.TimeCreated.ToString('s'); Level = [int]$_.Level; Message = ([string]$_.Message).Substring(0, [Math]::Min(120, ([string]$_.Message).Length)) } })
    }
}
$ReadVmGroups = { param($Node) @(Get-ClusterNode -Name $Node | Get-ClusterGroup | Where-Object { Get-ClusterResource -InputObject $_ | Where-Object ResourceType -Like 'Virtual Machine' } | ForEach-Object { [string]$_.Name }) }
$ReadVmCounts = { @(Get-ClusterGroup | Where-Object { Get-ClusterResource -InputObject $_ | Where-Object ResourceType -Like 'Virtual Machine' } | ForEach-Object { @{ Name = [string]$_.Name; Owner = [string]$_.OwnerNode } }) }
$ReadCsv = { @(Get-ClusterSharedVolume | ForEach-Object { @{ Name = [string]$_.Name; Owner = [string]$_.OwnerNode } }) }
$CheckEnableCmdlet = { @('Remove-MocPhysicalNode', 'New-MocPhysicalNode' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }) }
$CheckResumeCmdlet = { @('New-MocPhysicalNode' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }) }
$MoveVm = { param($Name, $Target) Move-ClusterVirtualMachineRole -Name $Name -Node $Target -MigrationType Live -ErrorAction Stop | Out-Null }
$MoveCsv = { param($Name, $Target) Move-ClusterSharedVolume -Name $Name -Node $Target -ErrorAction Stop | Out-Null }
$SuspendNode = { param($Name) Suspend-ClusterNode -Name $Name -Drain -Wait -ErrorAction Stop | Out-Null; [string](Get-ClusterNode -Name $Name).State }
$ResumeNode = { param($Name) Resume-ClusterNode -Name $Name -Failback Immediate -ErrorAction Stop | Out-Null; [string](Get-ClusterNode -Name $Name).State }
$RemoveMoc = { param($Name) Remove-MocPhysicalNode -NodeName $Name -ErrorAction Stop | Out-Null; @(Get-MocPhysicalNode | ForEach-Object { [string]$_.NodeName }) }
$AddMoc = { param($Name) New-MocPhysicalNode -NodeName $Name -ErrorAction Stop | Out-Null; @(Get-MocPhysicalNode | ForEach-Object { [string]$_.NodeName }) }

function Get-StorageProblem($Storage) {
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($pool in @($Storage.Pools)) { if ($pool.Health -ne 'Healthy' -or $pool.Operational -ne 'OK') { $problems.Add("storage pool $($pool.Name) is $($pool.Health)/$($pool.Operational)") } }
    foreach ($disk in @($Storage.Disks)) { if ($disk.Health -ne 'Healthy' -or $disk.Operational -ne 'OK') { $problems.Add("virtual disk $($disk.Name) is $($disk.Health)/$($disk.Operational)") } }
    foreach ($job in @($Storage.Jobs)) { $problems.Add("storage job $($job.Name) is $($job.State) at $($job.Percent) percent") }
    @($problems)
}

# ---- the actions
function Invoke-HealthCheck {
    $nodes = @(Invoke-Remote $clusterName $ReadNodes)
    $up = @($nodes | Where-Object { $_.State -eq 'Up' })
    Add-Row 'Cluster nodes' $(if ($up.Count -eq $nodes.Count -and $nodes.Count -gt 0) { 'Healthy' } else { 'Warning' }) "$($up.Count) of $($nodes.Count) nodes are Up ($(@($nodes | ForEach-Object { "$($_.Name) $($_.State)" }) -join ', '))"
    $storage = Invoke-Remote $clusterName $ReadStorage
    $pools = @($storage.Pools); $disks = @($storage.Disks)
    $badPools = @($pools | Where-Object { $_.Health -ne 'Healthy' -or $_.Operational -ne 'OK' })
    $badDisks = @($disks | Where-Object { $_.Health -ne 'Healthy' -or $_.Operational -ne 'OK' })
    Add-Row 'Storage pools' $(if ($badPools.Count -eq 0 -and $pools.Count -gt 0) { 'Healthy' } else { 'Warning' }) "$($pools.Count - $badPools.Count) of $($pools.Count) healthy"
    Add-Row 'Virtual disks' $(if ($badDisks.Count -eq 0 -and $disks.Count -gt 0) { 'Healthy' } else { 'Warning' }) "$($disks.Count - $badDisks.Count) of $($disks.Count) healthy$(if ($badDisks.Count) { ': ' + (@($badDisks | ForEach-Object { "$($_.Name) $($_.Health)" }) -join ', ') })"
    $jobs = @($storage.Jobs)
    Add-Row 'Storage repair jobs' $(if ($jobs.Count -eq 0) { 'Healthy' } else { 'Warning' }) $(if ($jobs.Count -eq 0) { 'none running' } else { "$($jobs.Count) running or suspended: wait for them before another node is taken offline" })
    $networks = @(Invoke-Remote $clusterName $ReadNetworks)
    $upNet = @($networks | Where-Object { $_.State -eq 'Up' })
    Add-Row 'Cluster networks' $(if ($upNet.Count -eq $networks.Count -and $networks.Count -gt 0) { 'Healthy' } else { 'Warning' }) "$($upNet.Count) of $($networks.Count) up"
    foreach ($n in $up) {
        try {
            $arc = [string](Invoke-Remote $n.Name $ReadArc)
            Add-Row "Azure Arc agent on $($n.Name)" $(if ($arc -eq 'Connected') { 'Healthy' } else { 'Warning' }) $arc
        }
        catch { Add-Row "Azure Arc agent on $($n.Name)" 'Warning' "could not be read: $($_.Exception.Message)" }
    }
    $bad = @($rows | Where-Object { $_.Action -ne 'Healthy' })
    Write-Line "Overall: $(if ($bad.Count -eq 0) { 'Healthy' } else { "$($bad.Count) finding(s) need a look" })"
    if ($bad.Count -gt 0) { $script:failed = $true }
}

function Invoke-MaintenanceMode {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($enterMaintenance) {
        $nodes = @(Invoke-Remote $clusterName $ReadNodes)
        $self = @($nodes | Where-Object { $_.Name -eq $node })
        if ($self.Count -eq 0) { throw "The cluster has no node '$node' (it has: $(@($nodes | ForEach-Object { $_.Name }) -join ', '))." }
        $others = @($nodes | Where-Object { $_.Name -ne $node -and $_.State -ne 'Up' })
        if ($others.Count -gt 0) { throw "Not safe: node $($others[0].Name) is $($others[0].State). Every other node must be Up before $node is taken out." }
        $problems = @(Get-StorageProblem (Invoke-Remote $clusterName $ReadStorage))
        if ($problems.Count -gt 0) { throw "Not safe: $($problems -join '; '). Wait for the storage to be healthy and the repair jobs to finish (Get-StorageJob), then try again." }
        # Both Azure Local cmdlets of the procedure must exist before anything is drained (Learn: 2311.2 or later); a drained node that cannot be taken out of the VM configuration is left half way.
        $missing = @(Invoke-Remote $node $CheckEnableCmdlet)
        if ($missing.Count -gt 0) { throw "The node $node does not have $($missing -join ', ') (Azure Local 2311.2 or later); nothing was changed." }
        if ($PSCmdlet.ShouldProcess($node, 'Suspend-ClusterNode -Drain (the roles and virtual machines move to the other nodes)')) {
            $state = [string](Invoke-Remote $clusterName $SuspendNode @($node))
            if ($state -ne 'Paused') { throw "Node $node is $state after the drain; it should be Paused." }
            Add-Row "Node $node" 'Suspended' 'drained, state Paused'
            if ($PSCmdlet.ShouldProcess($node, 'Remove-MocPhysicalNode (no new virtual machine is placed on it)')) {
                $members = @(Invoke-Remote $node $RemoveMoc @($node))
                if ($members -contains $node) { throw "Node $node is still in the virtual machine configuration after Remove-MocPhysicalNode." }
                Add-Row "Node $node" 'RemovedFromVmConfiguration' 'no new virtual machine is placed on it. The node can be updated or restarted.'
            }
            else { Add-Row "Node $node" 'WouldRemoveFromVmConfiguration' 'Remove-MocPhysicalNode' }
        }
        else { Add-Row "Node $node" 'WouldSuspend' 'drain, then Remove-MocPhysicalNode' }
    }
    else {
        $missing = @(Invoke-Remote $node $CheckResumeCmdlet)
        if ($missing.Count -gt 0) { throw "The node $node does not have $($missing -join ', ') (Azure Local 2311.2 or later); nothing was resumed." }
        if ($PSCmdlet.ShouldProcess($node, 'Resume-ClusterNode -Failback Immediate')) {
            $state = [string](Invoke-Remote $clusterName $ResumeNode @($node))
            if ($state -ne 'Up') { throw "Node $node is $state after the resume; it should be Up." }
            Add-Row "Node $node" 'Resumed' 'state Up, roles fail back'
            if ($PSCmdlet.ShouldProcess($node, 'New-MocPhysicalNode (the node takes virtual machines again)')) {
                $members = @(Invoke-Remote $node $AddMoc @($node))
                if ($members -notcontains $node) { throw "Node $node is not in the virtual machine configuration after New-MocPhysicalNode." }
                Add-Row "Node $node" 'AddedToVmConfiguration' 'it takes virtual machines again'
            }
            else { Add-Row "Node $node" 'WouldAddToVmConfiguration' 'New-MocPhysicalNode' }
            $problems = @(Get-StorageProblem (Invoke-Remote $clusterName $ReadStorage))
            if ($problems.Count -eq 0) { Add-Row 'Storage' 'Healthy' 'pools and virtual disks are healthy and no repair job is running: it is safe to take another node offline' }
            else { Add-Row 'Storage' 'Warning' "$($problems -join '; '). Do not take another node offline until the repair jobs have finished (Get-StorageJob)." }
        }
        else { Add-Row "Node $node" 'WouldResume' 'Resume-ClusterNode, then New-MocPhysicalNode' }
    }
}

function Invoke-LiveMigration {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $nodes = @(Invoke-Remote $clusterName $ReadNodes)
    if (@($nodes | Where-Object { $_.Name -eq $node }).Count -eq 0) { throw "The cluster has no node '$node'." }
    $targets = @($nodes | Where-Object { $_.Name -ne $node -and $_.State -eq 'Up' } | ForEach-Object { $_.Name })
    if ($targets.Count -eq 0) { throw 'No other node is Up to take the virtual machines.' }
    $mine = @(Invoke-Remote $clusterName $ReadVmGroups @($node))
    if ($mine.Count -eq 0) { Add-Row "Node $node" 'Info' 'it owns no clustered virtual machine'; return }
    $counts = @{}
    foreach ($t in $targets) { $counts[$t] = 0 }
    foreach ($vm in @(Invoke-Remote $clusterName $ReadVmCounts)) { if ($counts.ContainsKey([string]$vm.Owner)) { $counts[[string]$vm.Owner]++ } }
    foreach ($vm in $mine) {
        $target = ($counts.GetEnumerator() | Sort-Object Value, Name | Select-Object -First 1).Key
        if ($PSCmdlet.ShouldProcess($vm, "Live migrate from $node to $target")) {
            try { Invoke-Remote $clusterName $MoveVm @($vm, $target); $counts[$target]++; Add-Row $vm 'Migrated' "$node to $target (live)" }
            catch { Add-Row $vm 'Failed' $_.Exception.Message; $script:failed = $true }
        }
        else { Add-Row $vm 'WouldMigrate' "$node to $target (live)"; $counts[$target]++ }
    }
}

function Invoke-StorageRebalance {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $nodes = @(Invoke-Remote $clusterName $ReadNodes | Where-Object { $_.State -eq 'Up' } | ForEach-Object { $_.Name })
    $csvs = @(Invoke-Remote $clusterName $ReadCsv)
    if ($nodes.Count -eq 0 -or $csvs.Count -eq 0) { Add-Row 'Cluster shared volumes' 'Info' 'nothing to balance'; return }
    $owned = @{}
    foreach ($n in $nodes) { $owned[$n] = [System.Collections.Generic.List[string]]::new() }
    foreach ($csv in $csvs) { if ($owned.ContainsKey([string]$csv.Owner)) { $owned[[string]$csv.Owner].Add([string]$csv.Name) } }
    # Every node ends with the floor or the ceiling of volumes / nodes: the node that owns the most gives one volume to the node that owns the fewest until the two differ by one at most.
    # (A rule of "only a node above the ceiling gives" leaves 2, 2 and 0 as they are.)
    $total = 0
    foreach ($n in $nodes) { $total += $owned[$n].Count }
    $floor = [math]::Floor($total / $nodes.Count)
    $ceiling = [math]::Ceiling($total / $nodes.Count)
    Add-Row 'Cluster shared volumes' 'Info' "$total volume(s) on $($nodes.Count) node(s): $(@($nodes | ForEach-Object { "$_ $($owned[$_].Count)" }) -join ', '); each node should own $(if ($floor -eq $ceiling) { $floor } else { "$floor or $ceiling" })"
    $moves = 0
    while ($moves -lt $total) {
        $from = @($nodes | Sort-Object @{ Expression = { $owned[$_].Count }; Descending = $true }, @{ Expression = { $_ } })[0]
        $to = @($nodes | Sort-Object @{ Expression = { $owned[$_].Count } }, @{ Expression = { $_ } })[0]
        if ($owned[$from].Count - $owned[$to].Count -le 1) { break }
        $csv = $owned[$from][0]
        if ($PSCmdlet.ShouldProcess($csv, "Move the volume from $from to $to")) {
            try { Invoke-Remote $clusterName $MoveCsv @($csv, $to); Add-Row $csv 'Moved' "$from to $to" }
            catch { Add-Row $csv 'Failed' $_.Exception.Message; $script:failed = $true; break }
        }
        else { Add-Row $csv 'WouldMove' "$from to $to" }
        $owned[$from].RemoveAt(0); $owned[$to].Add($csv); $moves++
    }
    if ($moves -eq 0 -and -not $script:failed) { Add-Row 'Cluster shared volumes' 'Healthy' 'ownership is balanced' }
}

function Get-CapacityReport {
    $storage = Invoke-Remote $clusterName $ReadStorage
    foreach ($pool in @($storage.Pools)) {
        $pct = if ($pool.Size -gt 0) { [math]::Round($pool.Allocated / $pool.Size * 100, 1) } else { 0 }
        Add-Row "Storage pool $($pool.Name)" $(if ($pct -ge 85) { 'Warning' } else { 'OK' }) "used $([math]::Round($pool.Allocated / 1TB, 2)) TB of $([math]::Round($pool.Size / 1TB, 2)) TB ($pct percent), free $([math]::Round(($pool.Size - $pool.Allocated) / 1TB, 2)) TB"
    }
    foreach ($n in @(Invoke-Remote $clusterName $ReadNodes | Where-Object { $_.State -eq 'Up' })) {
        $c = Invoke-Remote $n.Name $ReadCapacity
        $memPct = if ($c.TotalMemoryGB -gt 0) { [math]::Round($c.AssignedMemoryGB / $c.TotalMemoryGB * 100, 1) } else { 0 }
        $cpuPct = if ($c.LogicalProcessors -gt 0) { [math]::Round($c.AssignedVcpu / $c.LogicalProcessors * 100, 1) } else { 0 }
        Add-Row "Node $($n.Name)" 'OK' "$($c.VmCount) VMs; memory $($c.AssignedMemoryGB) of $($c.TotalMemoryGB) GB ($memPct percent); vCPU $($c.AssignedVcpu) of $($c.LogicalProcessors) ($cpuPct percent)"
    }
}

function Get-ClusterAlert {
    $r = Invoke-Remote $clusterName $ReadFaults
    foreach ($f in @($r.Faults)) { Add-Row 'Health Service fault' $(if ($f.Severity -match 'Critical|Major|Fatal') { 'Critical' } else { 'Warning' }) "$($f.Severity): $($f.Reason) ($($f.Target))" }
    # The health actions are a history (the properties of MSFT_HealthAction: State, PercentComplete, Reason, ErrorDescription). An action that Succeeded or
    # was Canceled is not a finding; one that still runs, or Failed, is reported.
    foreach ($a in @(@($r.Actions) | Where-Object { [string]$_.State -notin 'Succeeded', 'Canceled' })) {
        Add-Row 'Storage health action' 'Warning' "$($a.State)$(if ($a.Percent -and [string]$a.State -ne 'Failed') { " ($($a.Percent) percent)" }), $($a.Reason)$(if ($a.Error) { " ($($a.Error))" })"
    }
    foreach ($e in @($r.Events)) { Add-Row "Cluster event $($e.Time)" $(if ($e.Level -le 2) { 'Critical' } else { 'Warning' }) $e.Message }
    if ($rows.Count -eq 0) { Add-Row 'Alerts' 'Healthy' 'no Health Service fault, no storage health action and no Critical, Error or Warning cluster event in the last 24 hours' }
    else { $script:failed = $true }
}

# ---- main
Write-Line "Cluster '$clusterName': action $Action$(if ($node) { " on node '$node'" })"
try {
    switch ($Action) {
        'HealthCheck' { Invoke-HealthCheck }
        'MaintenanceMode' { Invoke-MaintenanceMode }
        'LiveMigrate' { Invoke-LiveMigration }
        'Rebalance' { Invoke-StorageRebalance }
        'Capacity' { Get-CapacityReport }
        'Alerts' { Get-ClusterAlert }
    }
}
catch { Add-Row "Action $Action" 'Failed' $_.Exception.Message; $failed = $true }

if ($OutputPath) {
    try {
        $folder = Split-Path -Path $OutputPath -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        Set-Content -LiteralPath $OutputPath -Value ([ordered]@{ Cluster = $clusterName; Action = $Action; Node = $node; AtUtc = (Get-Date).ToUniversalTime().ToString('o'); Failed = $failed; Rows = @($rows) } | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM
        Write-Line "Report written to $OutputPath"
    }
    catch { Write-Error "The report could not be written to ${OutputPath}: $($_.Exception.Message)" -ErrorAction Continue; $failed = $true }
}

$rows
if ($failed) { Write-Line 'Finished with findings or errors.'; exit 1 }
Write-Line 'Finished.'
exit 0
