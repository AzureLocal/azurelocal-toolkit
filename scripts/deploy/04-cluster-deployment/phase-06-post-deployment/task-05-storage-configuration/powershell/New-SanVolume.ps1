<#
.SYNOPSIS
    Turns the SAN LUNs that storage.san.luns of infrastructure.yml lists into NTFS Cluster Shared Volumes.

.DESCRIPTION
    Phase 06 (post-deployment), Task 05 (storage configuration), part 2. For an instance with an external SAN (scenario.storage_architecture san or hybrid)
    the script connects to the cluster with PowerShell remoting and, for every LUN of storage.san.luns that is not a Cluster Shared Volume yet:

      1. finds the disk the LUN presents by its UniqueId (storage.san.luns[].unique_id), never by size or disk number;
      2. checks, before it changes anything, that the disk is the right one (see Safety) and that MPIO reports it;
      3. brings the disk online and clears read-only;
      4. initializes it as GPT, creates one partition that uses the whole disk, and formats it NTFS with a 64 KB allocation unit
         (Microsoft Learn, Connect an external storage array to Azure Local, step 8: SAN volumes are GPT and NTFS; ReFS is not supported on a SAN LUN);
      5. adds the disk to the failover cluster and renames the cluster disk to storage.san.luns[].name;
      6. adds it to Cluster Shared Volumes (step 9 of the same article).

    This follows the Learn procedure with two differences. Learn adds every available disk with Get-ClusterAvailableDisk | Add-ClusterDisk; this script adds only
    the one disk it has checked (Add-ClusterDisk takes a single disk from Get-Disk, as its Example 3 shows), so a disk the file does not list can never be clustered
    by it. Learn says to run step 9 on every machine; the cluster commands act on the whole cluster, so they run once. The disk is formatted on one machine only,
    as step 8 asks.

    Safety. A disk is initialized and formatted only when all of this is true; otherwise the LUN is reported as Refused, nothing on the disk is changed,
    and the script ends with exit code 1:
      - exactly one disk reports the UniqueId (when several do, MPIO has not claimed the paths);
      - MPIO reports the disk (at least one path in MPIO_DISK_INFO, the data behind mpclaim -s -d);
      - the bus is the one storage.san.type names (Fibre Channel or iSCSI);
      - the size is within 1 percent of storage.san.luns[].size_gib, and, when the file gives lun_id and the disk shows a LUN number, they agree;
      - the disk is not a boot, system or clustered disk, is RAW, and has no partition (the script checks again on the machine, after it brings the disk online,
        and before it writes anything);
      - the UniqueId is not the infrastructure or the performance history volume LUN of the deployment.
    A disk that already has a partition or data is never initialized, formatted or cleared. If a run stops after the disk was formatted and before it was clustered,
    the next run refuses that disk (it has a partition). Add it by hand with: Get-Disk -Number <n> | Add-ClusterDisk, then run the script again; the script then
    renames the cluster disk and adds it to the CSVs.

    Idempotent. A LUN whose disk is already a CSV with the right name is reported as AlreadyExists and left alone. A disk that is a cluster disk in Available Storage
    (an earlier run stopped) is renamed if needed and added to the CSVs. A cluster disk or CSV with another name, or in another cluster group, is reported and not changed.
    -WhatIf reads the cluster, prints the whole plan for every LUN, and changes nothing.

    The script does not zone, mask or map LUNs (that is done on the fabric and the array), does not configure MPIO or iSCSI (the OS configuration does), does not
    create the storage path in Azure (New-StoragePath.ps1 does), and does not sign in anywhere or read a secret. It connects as the account that runs it, or as -Credential.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name                              the cluster to connect to (unless -ComputerName is given)
        scenario.storage_architecture             san or hybrid; anything else means there is no SAN and nothing to do
        storage.san.type                          fibre_channel or iscsi: the bus the disk must be on
        storage.san.infra_volume_lun_id,
        storage.san.performance_history_lun_id    LUNs the deployment owns; a LUN with one of these ids is refused
        storage.san.luns[]: name, unique_id, size_gib, lun_id

    Exit codes: 0 everything the file asks for is there (done now, already there, planned under -WhatIf) or there is nothing to do; 1 the cluster could not be
    reached, a step failed, or a LUN was refused; 2 a value in the file is missing or not usable (nothing is sent to the cluster).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to connect to instead of cluster.name, for example one node when the cluster name does not resolve from where you run this.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Without it the account that runs the script is used.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-SanVolume.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Reads the cluster and prints the plan for every LUN. Changes nothing.

.EXAMPLE
    ./New-SanVolume.ps1 -InfrastructureFile ./infrastructure.yml

    Prepares the LUNs that are not CSVs yet. Run it again: they are reported as AlreadyExists.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ComputerName,
    [pscredential]$Credential,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

# Microsoft Learn (Connect an external storage array to Azure Local, step 8): a SAN volume is GPT and NTFS, with a 64 KB allocation unit for a CSV.
$AllocationUnitBytes = 65536
$SizeTolerance = 0.01   # the disk size may differ from storage.san.luns[].size_gib by this share (1 percent)
$BusName = @{ fibre_channel = 'Fibre Channel'; iscsi = 'iSCSI' }   # Get-Disk BusType, as Learn lists it (step 7)
$AvailableStorage = 'Available Storage'   # the cluster group that holds a cluster disk that is not in use yet

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

function Get-Field($Map, [string]$Key, $Default = $null) {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key] -and "$($Map[$Key])" -ne '') { return $Map[$Key] }
    $Default
}
function ConvertTo-GuidKey($Value) { (([string]$Value) -replace '[{}\s]', '').ToLowerInvariant() }

# The commands that run on the cluster. Each takes the step name first, so one remoting call shape serves all of them.
# PrepareDisk is the only one that writes to a disk. It looks at the disk again on the machine, because the state read earlier can be out of date, and it throws a
# message that starts with REFUSED: before it writes anything when the disk is not the one the file describes or is not empty.
$Remote = @{
    ReadState       = {
        param($Step)
        $paths = @{}
        $mpioRead = $false
        try {
            foreach ($d in @((Get-CimInstance -Namespace root/wmi -ClassName MPIO_DISK_INFO -ErrorAction Stop).DriveInfo)) { $paths[([string]$d.SerialNumber).Trim()] = [int]$d.NumberPaths }
            $mpioRead = $true
        }
        catch { $paths = @{} }
        $disks = @(Get-Disk -ErrorAction Stop | Where-Object { [string]$_.BusType -in 'Fibre Channel', 'iSCSI' } | ForEach-Object {
                $serial = ([string]$_.SerialNumber).Trim()
                $lun = -1
                if ([string]$_.Location -match 'L(\d+)\)?$') { $lun = [int]$Matches[1] }
                @{
                    Number = [int]$_.Number; UniqueId = ([string]$_.UniqueId).Trim(); Serial = $serial; BusType = [string]$_.BusType; Size = [long]$_.Size
                    PartitionStyle = [string]$_.PartitionStyle; Partitions = [int]$_.NumberOfPartitions; Offline = [bool]$_.IsOffline; Guid = [string]$_.Guid; Lun = $lun
                    InUse = [bool]($_.IsBoot -or $_.IsSystem -or $_.IsClustered -or $_.IsHighlyAvailable -or $_.IsScaleOut)
                    Paths = $(if ($paths.ContainsKey($serial)) { [int]$paths[$serial] } else { 0 })
                }
            })
        $resources = @(Get-ClusterResource -ErrorAction Stop | ForEach-Object {
                $guid = ''
                if ([string]$_.ResourceType -eq 'Physical Disk') {
                    $parameter = Get-ClusterParameter -InputObject $_ -Name DiskIdGuid -ErrorAction SilentlyContinue
                    if ($parameter) { $guid = [string]$parameter.Value }
                }
                @{ Name = [string]$_.Name; Type = [string]$_.ResourceType; Group = [string]$_.OwnerGroup.Name; DiskIdGuid = $guid }
            })
        $csvs = @(Get-ClusterSharedVolume -ErrorAction Stop | ForEach-Object { @{ Name = [string]$_.Name; Path = [string]@($_.SharedVolumeInfo)[0].FriendlyVolumeName } })
        @{ Computer = [string]$env:COMPUTERNAME; MpioRead = $mpioRead; Disks = $disks; Resources = $resources; Csvs = $csvs }
    }
    PrepareDisk     = {
        param($Step, $UniqueId, $BusType, $SizeBytes, $Tolerance, $Label, $AllocationUnit)
        $found = @(Get-Disk -ErrorAction Stop | Where-Object { ([string]$_.UniqueId).Trim() -ieq $UniqueId })
        if ($found.Count -ne 1) { throw "REFUSED: $($found.Count) disks report the UniqueId $UniqueId on this machine; exactly one is needed (MPIO must claim the paths first). Nothing was changed." }
        $number = [int]$found[0].Number
        if ([string]$found[0].BusType -ne $BusType) { throw "REFUSED: disk $number is on the bus '$($found[0].BusType)', not '$BusType'. Nothing was changed." }
        if ($found[0].IsBoot -or $found[0].IsSystem -or $found[0].IsClustered -or $found[0].IsHighlyAvailable -or $found[0].IsScaleOut) { throw "REFUSED: disk $number is a boot, system or clustered disk. Nothing was changed." }
        if ([math]::Abs([double]$found[0].Size - [double]$SizeBytes) -gt ([double]$SizeBytes * [double]$Tolerance)) { throw "REFUSED: disk $number is $([math]::Round($found[0].Size / 1GB, 2)) GiB, not the size the file gives. Nothing was changed." }
        if ([string]$found[0].PartitionStyle -ne 'RAW' -or [int]$found[0].NumberOfPartitions -gt 0) { throw "REFUSED: disk $number has partition style $($found[0].PartitionStyle) and $($found[0].NumberOfPartitions) partition(s). It is not empty, so it is not touched." }
        if ($found[0].IsOffline) { Set-Disk -Number $number -IsOffline $false -ErrorAction Stop }
        # Look again now that the disk is online: an offline disk can hide its partitions.
        $disk = Get-Disk -Number $number -ErrorAction Stop
        $partitions = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue)
        if ([string]$disk.PartitionStyle -ne 'RAW' -or [int]$disk.NumberOfPartitions -gt 0 -or $partitions.Count -gt 0) { throw "REFUSED: disk $number has partition style $($disk.PartitionStyle) and $([math]::Max([int]$disk.NumberOfPartitions, $partitions.Count)) partition(s). It is not empty, so it is not touched. The disk was brought online and nothing else was changed." }
        if ($disk.IsReadOnly) { Set-Disk -Number $number -IsReadOnly $false -ErrorAction Stop }
        Initialize-Disk -Number $number -PartitionStyle GPT -Confirm:$false -ErrorAction Stop
        $null = New-Partition -DiskNumber $number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop | Format-Volume -FileSystem NTFS -AllocationUnitSize $AllocationUnit -NewFileSystemLabel $Label -Confirm:$false -ErrorAction Stop
        @{ Number = $number }
    }
    AddClusterDisk  = {
        param($Step, $UniqueId, $Name, $Existing)
        $found = @(Get-Disk -ErrorAction Stop | Where-Object { ([string]$_.UniqueId).Trim() -ieq $UniqueId })
        if ($found.Count -ne 1) { throw "$($found.Count) disks report the UniqueId $UniqueId on this machine; exactly one is needed. Nothing was added to the cluster." }
        $resource = if ($Existing) { Get-ClusterResource -Name $Existing -ErrorAction Stop } else { @($found[0] | Add-ClusterDisk -ErrorAction Stop)[0] }
        if ([string]$resource.Name -ne $Name) { $resource.Name = $Name }
        @{ Resource = [string]$resource.Name }
    }
    AddCsv          = {
        param($Step, $Name)
        $null = Add-ClusterSharedVolume -Name $Name -ErrorAction Stop
        $csv = Get-ClusterSharedVolume -Name $Name -ErrorAction Stop
        @{ Path = [string]@($csv.SharedVolumeInfo)[0].FriendlyVolumeName }
    }
}
function Invoke-Cluster([string]$Step, [object[]]$Arguments = @(), [string]$Target = $script:target) {
    $call = @{ ComputerName = $Target; ScriptBlock = $Remote[$Step]; ArgumentList = (, $Step + $Arguments); ErrorAction = 'Stop' }
    if ($Credential) { $call.Credential = $Credential }
    Invoke-Command @call
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$architecture = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.storage_architecture')).Trim().ToLowerInvariant()
if ($architecture -notin 'san', 'hybrid') {
    Write-Line "scenario.storage_architecture is '$architecture': the instance has no external SAN, so there is no SAN volume to prepare here."
    exit 0
}
$san = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage.san'
$lunList = @(@(Get-Field $san 'luns' @()) | Where-Object { $null -ne $_ })
if ($lunList.Count -eq 0) {
    Write-Line 'The file lists no storage.san.luns: nothing to do.'
    exit 0
}
$sanType = ([string](Get-Field $san 'type' '')).Trim().ToLowerInvariant()
if (-not $BusName.ContainsKey($sanType)) { Exit-InputProblem "storage.san.type must be fibre_channel or iscsi; found '$sanType'. It says which bus the LUN disks are on." }
$busType = $BusName[$sanType]
$deploymentOwned = @(foreach ($key in 'infra_volume_lun_id', 'performance_history_lun_id') { $owned = ([string](Get-Field $san $key '')).Trim().ToLowerInvariant(); if ($owned) { $owned } })

$target = if ($ComputerName) { $ComputerName.Trim() } else { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim() }
if (-not $target) { Exit-InputProblem 'cluster.name is missing. It is the cluster the script connects to (or give -ComputerName).' }

$plans = [System.Collections.Generic.List[object]]::new()
$seenName = @{}
$seenId = @{}
$index = -1
foreach ($lun in $lunList) {
    $index++
    $at = "storage.san.luns[$index]"
    if ($lun -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a LUN (a map with name, unique_id and size_gib)." }
    $name = ([string](Get-Field $lun 'name' '')).Trim()
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { Exit-InputProblem "$at.name '$name' is not usable: 1 to 63 letters, digits, dot, underscore or hyphen, starting with a letter or digit. It becomes the name of the cluster disk and of the CSV." }
    if ($name -match '^(UserStorage|Infrastructure)_\d+$') { Exit-InputProblem "$at.name '$name' is a name the deployment manages. Choose another name." }
    if ($seenName.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seenName[$name.ToLowerInvariant()] = $true

    $uniqueId = ([string](Get-Field $lun 'unique_id' '')).Trim()
    if (-not $uniqueId) { Exit-InputProblem "$at.unique_id is missing. The script finds the disk of a LUN only by its UniqueId (Get-Disk, the same on every machine), never by size or disk number. Run Get-Disk | Select-Object Number, SerialNumber, UniqueId on a machine and copy the UniqueId of the LUN." }
    if ($uniqueId -notmatch '^[0-9A-Za-z][0-9A-Za-z._:-]{7,127}$') { Exit-InputProblem "$at.unique_id '$uniqueId' is not a UniqueId: 8 to 128 letters, digits, dot, underscore, colon or hyphen." }
    if ($seenId.ContainsKey($uniqueId.ToLowerInvariant())) { Exit-InputProblem "$at.unique_id '$uniqueId' is listed twice." }
    $seenId[$uniqueId.ToLowerInvariant()] = $true
    if ($uniqueId.ToLowerInvariant() -in $deploymentOwned) { Exit-InputProblem "$at.unique_id '$uniqueId' is the infrastructure or performance history volume LUN of the deployment. The deployment manages it; it is not a volume for this script." }

    $sizeGib = 0.0
    if (-not [double]::TryParse("$(Get-Field $lun 'size_gib' '')", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sizeGib) -or $sizeGib -le 0) { Exit-InputProblem "$at.size_gib must be a number above 0." }
    $lunId = ([string](Get-Field $lun 'lun_id' '')).Trim()
    if ($lunId -and $lunId -notmatch '^\d{1,6}$') { Exit-InputProblem "$at.lun_id '$lunId' must be a whole number (the logical unit number the array presents)." }

    $plans.Add([pscustomobject]@{ Name = $name; UniqueId = $uniqueId; SizeGib = $sizeGib; SizeBytes = [long][math]::Round($sizeGib * 1GB); LunId = $lunId })
}

# ---- the cluster as it is (read only)
Write-Line "Cluster '$target': reading the SAN disks and the cluster disks"
try { $state = Invoke-Cluster 'ReadState' }
catch { Exit-Failed "The cluster '$target' could not be read: $($_.Exception.Message)" }
$disks = @($state.Disks)
$resources = @($state.Resources)
$csvs = @($state.Csvs)
Write-Line "Seen from '$($state.Computer)': $($disks.Count) $busType disk(s), $(@($resources | Where-Object { $_.Type -eq 'Physical Disk' }).Count) cluster disk(s), $($csvs.Count) CSV(s)"

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { { $_ -in 'Failed', 'Refused' } { '[failed] ' } 'AlreadyExists' { '[exists] ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[done]   ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Item, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}

foreach ($plan in $plans) {
    $item = "LUN $($plan.Name)"
    try {
        # 1. the disk, by UniqueId only
        $candidates = @($disks | Where-Object { ([string]$_.UniqueId) -ieq $plan.UniqueId })
        if ($candidates.Count -eq 0) { Add-Row $item 'Failed' "No $busType disk with UniqueId $($plan.UniqueId) is visible from '$($state.Computer)'. Present the LUN to every machine, run Update-HostStorageCache, and check storage.san.luns[].unique_id. Nothing was changed."; continue }
        if ($candidates.Count -gt 1) { Add-Row $item 'Refused' "$($candidates.Count) disks (#$((@($candidates | ForEach-Object { $_.Number }) -join ', #'))) report the UniqueId $($plan.UniqueId): MPIO has not claimed the paths. Claim the array in MPIO (the OS configuration does), restart the machine, and run again. Nothing was changed."; continue }
        $disk = $candidates[0]
        $diskKey = ConvertTo-GuidKey $disk.Guid
        $csv = $null
        $resource = if ($diskKey) { @($resources | Where-Object { $_.Type -eq 'Physical Disk' -and (ConvertTo-GuidKey $_.DiskIdGuid) -eq $diskKey }) | Select-Object -First 1 }

        # 2. a disk the cluster already owns: report it or finish it, never format it
        if ($resource) {
            $csv = @($csvs | Where-Object { $_.Name -eq $resource.Name }) | Select-Object -First 1
            if ($csv) {
                if ($resource.Name -eq $plan.Name) { Add-Row $item 'AlreadyExists' "disk #$($disk.Number) is the CSV '$($resource.Name)' at $($csv.Path); left as it is"; continue }
                Add-Row $item 'Refused' "disk #$($disk.Number) is already the CSV '$($resource.Name)', not '$($plan.Name)'. The script does not rename a CSV; nothing was changed."; continue
            }
            if ($resource.Group -ne $AvailableStorage) { Add-Row $item 'Refused' "disk #$($disk.Number) is the cluster disk '$($resource.Name)' in the group '$($resource.Group)', not in '$AvailableStorage'. It is in use; nothing was changed."; continue }
        }
        elseif ($disk.InUse) { Add-Row $item 'Refused' "disk #$($disk.Number) is a boot, system or clustered disk, and no cluster disk of this cluster matches it. The disk is not initialized, formatted or changed."; continue }

        # 3. checks that come before any change: is this the disk the file describes, and does MPIO report it
        $problems = [System.Collections.Generic.List[string]]::new()
        if (-not $state.MpioRead) { $problems.Add("MPIO could not be read on '$($state.Computer)' (MPIO_DISK_INFO), so it is not known whether MPIO manages the disk") }
        elseif ([int]$disk.Paths -lt 1) { $problems.Add("MPIO does not report disk #$($disk.Number) (no path in MPIO_DISK_INFO, mpclaim -s -d lists no MPIO disk for it)") }
        if ([string]$disk.BusType -ne $busType) { $problems.Add("the disk is on the bus '$($disk.BusType)', storage.san.type says '$busType'") }
        if ([math]::Abs([double]$disk.Size - [double]$plan.SizeBytes) -gt ([double]$plan.SizeBytes * $SizeTolerance)) { $problems.Add("the disk is $([math]::Round($disk.Size / 1GB, 2)) GiB, storage.san.luns[].size_gib is $($plan.SizeGib)") }
        if ($plan.LunId -and [int]$disk.Lun -ge 0 -and [int]$disk.Lun -ne [int]$plan.LunId) { $problems.Add("the disk shows LUN $($disk.Lun), storage.san.luns[].lun_id is $($plan.LunId)") }
        if (-not $resource -and ([string]$disk.PartitionStyle -ne 'RAW' -or [int]$disk.Partitions -gt 0)) { $problems.Add("the disk has partition style $($disk.PartitionStyle) and $($disk.Partitions) partition(s); it is not empty") }
        $other = @($resources | Where-Object { $_.Name -eq $plan.Name -and (-not $resource -or $_.Name -ne $resource.Name) }) | Select-Object -First 1
        if ($other) { $problems.Add("the cluster already has a resource named '$($plan.Name)' that is not this disk") }
        if ($problems.Count) { Add-Row $item 'Refused' ("$($problems -join '; '). The disk is not initialized, formatted or changed."); continue }
        if ($disk.Paths -eq 1) { Write-Warning "$item : MPIO reports one path for disk #$($disk.Number). Azure Local expects redundant paths (two fabrics or two iSCSI networks)." }

        # 4. the plan, then the work
        $steps = [System.Collections.Generic.List[string]]::new()
        if (-not $resource) {
            if ($disk.Offline) { $steps.Add("bring disk #$($disk.Number) online") }
            $steps.Add("initialize disk #$($disk.Number) as GPT")
            $steps.Add("create one partition with all the space and format it NTFS, allocation unit $($AllocationUnitBytes / 1KB) KB, label '$($plan.Name)'")
            $steps.Add('add the disk to the failover cluster')
        }
        if (-not $resource -or $resource.Name -ne $plan.Name) { $steps.Add("name the cluster disk '$($plan.Name)'") }
        $steps.Add('add it to Cluster Shared Volumes')
        $summary = "$($plan.SizeGib) GiB, $($steps -join '; ')"
        $created = $false
        if ($PSCmdlet.ShouldProcess("$item (disk #$($disk.Number), UniqueId $($plan.UniqueId)) on '$target'", $steps -join '; ')) {
            $progress = 'nothing was changed yet'
            try {
                $existing = ''
                if (-not $resource) {
                    $null = Invoke-Cluster 'PrepareDisk' @($plan.UniqueId, $busType, $plan.SizeBytes, $SizeTolerance, $plan.Name, $AllocationUnitBytes)
                    $created = $true
                    $progress = "disk #$($disk.Number) is formatted but not in the cluster yet"
                }
                else { $existing = $resource.Name }
                if (-not $resource -or $resource.Name -ne $plan.Name) {
                    $null = Invoke-Cluster 'AddClusterDisk' @($plan.UniqueId, $plan.Name, $existing)
                    $progress = "the cluster disk is named '$($plan.Name)' but is not a CSV yet"
                }
                $added = Invoke-Cluster 'AddCsv' @($plan.Name)
                Add-Row $item $(if ($created) { 'Created' } else { 'AddedToCsv' }) "$summary; CSV path $($added.Path)"
            }
            catch {
                $message = $_.Exception.Message
                if ($message -match 'REFUSED:') { Add-Row $item 'Refused' ($message -replace '^.*?REFUSED:\s*', '') }
                else { Add-Row $item 'Failed' "$message ($progress)" }
            }
        }
        else { Add-Row $item $(if ($resource) { 'WouldAddToCsv' } else { 'WouldCreate' }) $summary }
    }
    catch { Add-Row $item 'Failed' $_.Exception.Message }
}

$rows
if (@($rows | Where-Object { $_.Action -in 'Failed', 'Refused' })) { exit 1 }
exit 0
