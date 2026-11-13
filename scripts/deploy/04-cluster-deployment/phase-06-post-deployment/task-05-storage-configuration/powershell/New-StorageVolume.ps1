<#
.SYNOPSIS
    Creates the Storage Spaces Direct volumes that storage.volumes of infrastructure.yml lists, and sets the two cluster storage settings the file names.

.DESCRIPTION
    Phase 06 (post-deployment), Task 05 (storage configuration), part 1. For an instance that has Storage Spaces Direct (scenario.storage_architecture
    s2d or hybrid) the script connects to the cluster with PowerShell remoting and:

      1. creates every volume of storage.volumes that does not exist yet, with New-Volume, the way Microsoft Learn describes it
         (Create volumes on Azure Local; Perform post deployment tasks on rack aware cluster):
             two_way                           -ResiliencySettingName Mirror -PhysicalDiskRedundancy 1
             three_way                         -ResiliencySettingName Mirror -PhysicalDiskRedundancy 2
             four_way (rack aware)             -ResiliencySettingName Mirror -PhysicalDiskRedundancy 3
             parity (dual parity)              -ResiliencySettingName Parity -PhysicalDiskRedundancy 2
             nested_two_way                    the tier NestedMirrorOn<media>
             mirror_accelerated_parity         the tiers MirrorOn<media> and ParityOn<media>
             nested_mirror_accelerated_parity  the tiers NestedMirrorOn<media> and NestedParityOn<media>
             no resiliency in the file         nothing is passed: Storage Spaces Direct chooses (two-way with 1 or 2 machines, three-way with 3 or more)
      2. turns on ReFS deduplication or compression for a volume whose deduplication.type says so (off unless the file says otherwise), and sets its
         schedule when the file gives one;
      3. sets the size of the CSV in-memory read cache when storage.csv.read_cache_size_mib is in the file;
      4. sets the thin provisioning alert threshold of the pool when storage.pool.thin_provisioning_alert_threshold_percent is in the file.

    A setting that is not in the file is not touched. The script never deletes, resizes or changes a volume that exists, never touches a volume the
    deployment made (Infrastructure_1, UserStorage_<n>) and refuses those names in the file.

    With scenario.storage_architecture san there is no Storage Spaces Direct pool: the script does nothing and exits 0.

    Idempotent. A volume that exists is reported as AlreadyExists and left as it is. -WhatIf reads the cluster and changes nothing.

    The script does not sign in anywhere and reads no secret. It connects as the account that runs it, or as -Credential.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name                                              the cluster to connect to (unless -ComputerName is given)
        scenario.storage_architecture, nodes                      whether there is a pool, and how many machines
        hardware.drives.capacity.media                            the media type of the tiers, unless a volume names its own media_type
        storage.pool.name                                         the pool; empty means the one Storage Spaces Direct pool of the cluster
        storage.pool.thin_provisioning_alert_threshold_percent
        storage.csv.read_cache_size_mib
        storage.volumes[]: name, size_gib, resiliency, provisioning_type, file_system, parity_percent, media_type,
                           deduplication.type, deduplication.schedule.start_time, days, duration_hours

    Exit codes: 0 everything the file asks for is there (created now, already there, planned under -WhatIf) or there is nothing to do; 1 the cluster
    could not be reached or a step failed; 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to connect to instead of cluster.name, for example one node when the cluster name does not resolve from where you run this.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Without it the account that runs the script is used.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-StorageVolume.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Reads the cluster and shows what would be created or set. Changes nothing.

.EXAMPLE
    ./New-StorageVolume.ps1 -InfrastructureFile ./infrastructure.yml -Credential (Get-Secret lcm-user)

    Creates the volumes that are missing. Run it again: they are reported as AlreadyExists.
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

# What each resiliency value means for New-Volume. Tiers: the name is completed with the media type (MirrorOnSSD, ParityOnHDD).
$ResiliencyRule = @{
    two_way                          = @{ Setting = 'Mirror'; Redundancy = 1; MinNodes = 1 }
    three_way                        = @{ Setting = 'Mirror'; Redundancy = 2; MinNodes = 3 }
    four_way                         = @{ Setting = 'Mirror'; Redundancy = 3; MinNodes = 4 }
    parity                           = @{ Setting = 'Parity'; Redundancy = 2; MinNodes = 4 }
    nested_two_way                   = @{ Tiers = @('NestedMirrorOn'); MinNodes = 2; MaxNodes = 2 }
    mirror_accelerated_parity        = @{ Tiers = @('MirrorOn', 'ParityOn'); MinNodes = 4 }
    nested_mirror_accelerated_parity = @{ Tiers = @('NestedMirrorOn', 'NestedParityOn'); MinNodes = 2; MaxNodes = 2 }
}
$ProvisioningMap = @{ thin = 'Thin'; fixed = 'Fixed' }
$DedupType = @{ dedup = 'Dedup'; compress = 'Compress'; dedup_and_compress = 'DedupAndCompress' }
$Days = 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'EveryDay'
$DefaultParityPercent = 80   # Microsoft Learn, Mirror-accelerated parity: 20 percent mirror and 80 percent parity is the recommended ratio.

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
function ConvertTo-WholeNumber($Value, [string]$What, [long]$Min, [long]$Max) {
    $n = 0L
    if (-not [long]::TryParse("$Value", [ref]$n) -or $n -lt $Min -or $n -gt $Max) { Exit-InputProblem "$What must be a whole number from $Min to $Max; found '$Value'." }
    $n
}

# The commands that run on the cluster. Each takes the step name first, so one remoting call shape serves all of them.
$Remote = @{
    ReadState   = {
        param($Step, $PoolName)
        $pools = @(Get-StoragePool -IsPrimordial $false -ErrorAction Stop)
        if ($PoolName) { $pools = @($pools | Where-Object FriendlyName -EQ $PoolName) }
        @{
            Pools          = @($pools | ForEach-Object { @{ Name = [string]$_.FriendlyName; Thresholds = @($_.ThinProvisioningAlertThresholds | ForEach-Object { [int]$_ }) } })
            Volumes        = @(Get-VirtualDisk | ForEach-Object { [string]$_.FriendlyName })
            Tiers          = @(Get-StorageTier | ForEach-Object { [string]$_.FriendlyName })
            BlockCacheSize = [int](Get-Cluster).BlockCacheSize
            Nodes          = @(Get-ClusterNode | ForEach-Object { [string]$_.Name })
        }
    }
    NewVolume   = {
        param($Step, $Parameters, $TierProvisioning)
        # A tiered volume takes its provisioning type from the tier templates of the pool (Microsoft Learn, Storage thin provisioning in Azure Local).
        # The templates are shared, so they are set for this volume only and put back afterwards, whether the creation worked or not.
        $before = @{}
        try {
            if ($TierProvisioning) {
                foreach ($name in $Parameters.StorageTierFriendlyNames) {
                    $tier = Get-StorageTier -FriendlyName $name -ErrorAction Stop
                    if ([string]$tier.ProvisioningType -ne $TierProvisioning) {
                        $before[$name] = [string]$tier.ProvisioningType
                        $tier | Set-StorageTier -ProvisioningType $TierProvisioning -ErrorAction Stop
                    }
                }
            }
            $null = New-Volume @Parameters -ErrorAction Stop
        }
        finally {
            foreach ($name in $before.Keys) { Get-StorageTier -FriendlyName $name -ErrorAction Stop | Set-StorageTier -ProvisioningType $before[$name] -ErrorAction Stop }
        }
    }
    GetOwner    = {
        param($Step, $VolumeName)
        $csv = Get-ClusterSharedVolume -ErrorAction Stop | Where-Object { $_.Name -eq "Cluster Virtual Disk ($VolumeName)" } | Select-Object -First 1
        if (-not $csv) { return $null }
        @{ Owner = [string]$csv.OwnerNode.Name; Path = [string]@($csv.SharedVolumeInfo)[0].FriendlyVolumeName }
    }
    ReadDedup   = {
        param($Step, $Path)
        $status = Get-ReFSDedupStatus -Volume $Path -ErrorAction Stop
        @{ Enabled = [bool]$status.Enabled; Type = [string]$status.Type }
    }
    SetDedup    = {
        param($Step, $Path, $Type, $Schedule)
        if ($Type) { Enable-ReFSDedup -Volume $Path -Type $Type -ErrorAction Stop }
        if ($Schedule) {
            Set-ReFSDedupSchedule -Volume $Path -Start ([datetime]::Today.Add([timespan]::Parse($Schedule.StartTime))) -Days $Schedule.Days -Duration (New-TimeSpan -Hours $Schedule.Hours) -ErrorAction Stop
        }
    }
    SetCache    = { param($Step, $SizeMib) (Get-Cluster).BlockCacheSize = $SizeMib }
    SetThreshold = { param($Step, $PoolName, $Percent) Set-StoragePool -FriendlyName $PoolName -ThinProvisioningAlertThresholds $Percent -ErrorAction Stop }
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
if ($architecture -eq 'san') {
    Write-Line 'scenario.storage_architecture is san: the instance has no Storage Spaces Direct pool, so there is no volume to create here.'
    exit 0
}
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$pool = Get-Field $storage 'pool'
$poolName = ([string](Get-Field $pool 'name' '')).Trim()
$thresholdRaw = Get-Field $pool 'thin_provisioning_alert_threshold_percent'
$cacheRaw = Get-Field (Get-Field $storage 'csv') 'read_cache_size_mib'
$volumeList = @(@(Get-Field $storage 'volumes' @()) | Where-Object { $null -ne $_ })
if ($volumeList.Count -eq 0 -and $null -eq $thresholdRaw -and $null -eq $cacheRaw) {
    Write-Line 'The file lists no storage.volumes and no pool or CSV cache setting: nothing to do.'
    exit 0
}

$target = if ($ComputerName) { $ComputerName.Trim() } else { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim() }
if (-not $target) { Exit-InputProblem 'cluster.name is missing. It is the cluster the script connects to (or give -ComputerName).' }
$nodeList = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'nodes'
$nodeCount = @(@($nodeList) | Where-Object { $null -ne $_ }).Count
$capacityMedia = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'hardware.drives.capacity.media')).Trim().ToLowerInvariant()

$threshold = if ($null -ne $thresholdRaw) { ConvertTo-WholeNumber $thresholdRaw 'storage.pool.thin_provisioning_alert_threshold_percent' 1 100 }
$cacheSize = if ($null -ne $cacheRaw) { ConvertTo-WholeNumber $cacheRaw 'storage.csv.read_cache_size_mib' 0 1048576 }

$plans = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($volume in $volumeList) {
    $index++
    $at = "storage.volumes[$index]"
    if ($volume -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a volume (a map with name and size_gib)." }
    $name = ([string](Get-Field $volume 'name' '')).Trim()
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { Exit-InputProblem "$at.name '$name' is not usable: 1 to 63 letters, digits, dot, underscore or hyphen, starting with a letter or digit." }
    if ($name -match '^(UserStorage|Infrastructure)_\d+$') { Exit-InputProblem "$at.name '$name' is a name the deployment manages. Choose another name." }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seen[$name.ToLowerInvariant()] = $true

    $sizeGib = 0.0
    if (-not [double]::TryParse("$(Get-Field $volume 'size_gib' '')", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sizeGib) -or $sizeGib -le 0) { Exit-InputProblem "$at.size_gib must be a number above 0." }
    $sizeBytes = [long][math]::Round($sizeGib * 1GB)

    $fileSystem = ([string](Get-Field $volume 'file_system' 'refs')).ToLowerInvariant()
    if ($fileSystem -notin 'refs', 'ntfs') { Exit-InputProblem "$at.file_system must be refs or ntfs; found '$fileSystem'." }
    $provisioning = ([string](Get-Field $volume 'provisioning_type' '')).ToLowerInvariant()
    if ($provisioning -and $provisioning -notin 'thin', 'fixed') { Exit-InputProblem "$at.provisioning_type must be thin or fixed; found '$provisioning'." }
    $provisioningName = if ($provisioning) { $ProvisioningMap[$provisioning] } else { '' }
    $mediaRaw = ([string](Get-Field $volume 'media_type' '')).ToLowerInvariant()
    if ($mediaRaw -and $mediaRaw -notin 'ssd', 'hdd') { Exit-InputProblem "$at.media_type must be ssd or hdd; found '$mediaRaw'." }

    $parameters = @{ FriendlyName = $name; FileSystem = if ($fileSystem -eq 'refs') { 'CSVFS_ReFS' } else { 'CSVFS_NTFS' } }
    $tierProvisioning = ''
    $resiliency = ([string](Get-Field $volume 'resiliency' '')).ToLowerInvariant()
    if ($resiliency -and -not $ResiliencyRule.ContainsKey($resiliency)) { Exit-InputProblem "$at.resiliency '$resiliency' is not one of: $(($ResiliencyRule.Keys | Sort-Object) -join ', ')." }
    $rule = if ($resiliency) { $ResiliencyRule[$resiliency] } else { @{} }
    if ($rule.ContainsKey('MinNodes') -and $nodeCount -lt $rule.MinNodes) { Exit-InputProblem "$at.resiliency $resiliency needs at least $($rule.MinNodes) machines; the file lists $nodeCount." }
    if ($rule.ContainsKey('MaxNodes') -and $nodeCount -gt $rule.MaxNodes) { Exit-InputProblem "$at.resiliency $resiliency is for a cluster of $($rule.MaxNodes) machines; the file lists $nodeCount." }

    if ($rule.ContainsKey('Tiers')) {
        $media = if ($mediaRaw) { $mediaRaw } elseif ($capacityMedia -in 'nvme', 'ssd') { 'ssd' } elseif ($capacityMedia -eq 'hdd') { 'hdd' } else { '' }
        if (-not $media) { Exit-InputProblem "$at.resiliency $resiliency uses storage tiers, which are named after the media type. Set $at.media_type (ssd or hdd) or hardware.drives.capacity.media." }
        $parameters.StorageTierFriendlyNames = @($rule.Tiers | ForEach-Object { $_ + $media.ToUpperInvariant() })
        if ($rule.Tiers.Count -eq 2) {
            if ($fileSystem -ne 'refs') { Exit-InputProblem "$at.resiliency $resiliency needs file_system refs." }
            $parityPercent = ConvertTo-WholeNumber (Get-Field $volume 'parity_percent' $DefaultParityPercent) "$at.parity_percent" 1 99
            $parityBytes = [long][math]::Round($sizeBytes * $parityPercent / 100)
            $parameters.StorageTierSizes = @(($sizeBytes - $parityBytes), $parityBytes)
        }
        else { $parameters.StorageTierSizes = @($sizeBytes) }
        $tierProvisioning = $provisioningName
    }
    else {
        if ($null -ne (Get-Field $volume 'parity_percent')) { Exit-InputProblem "$at.parity_percent only applies to mirror_accelerated_parity and nested_mirror_accelerated_parity." }
        $parameters.Size = $sizeBytes
        if ($resiliency) { $parameters.ResiliencySettingName = $rule.Setting; $parameters.PhysicalDiskRedundancy = $rule.Redundancy }
        if ($provisioningName) { $parameters.ProvisioningType = $provisioningName }
        if ($mediaRaw) { $parameters.MediaType = $mediaRaw.ToUpperInvariant() }
    }

    $dedup = Get-Field $volume 'deduplication'
    $dedupKey = ([string](Get-Field $dedup 'type' 'none')).ToLowerInvariant()
    if ($dedupKey -ne 'none' -and -not $DedupType.ContainsKey($dedupKey)) { Exit-InputProblem "$at.deduplication.type must be none, dedup, compress or dedup_and_compress; found '$dedupKey'." }
    $schedule = $null
    $scheduleMap = Get-Field $dedup 'schedule'
    if ($dedupKey -ne 'none') {
        if ($fileSystem -ne 'refs') { Exit-InputProblem "$at.deduplication needs file_system refs (ReFS deduplication and compression)." }
        if ($null -ne $scheduleMap) {
            $start = ([string](Get-Field $scheduleMap 'start_time' '')).Trim()
            if ($start -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Exit-InputProblem "$at.deduplication.schedule.start_time must be a time as HH:mm, for example 22:00." }
            $dayList = @(Get-Field $scheduleMap 'days' @()) | ForEach-Object { $match = $Days -eq "$_"; if (-not $match) { Exit-InputProblem "$at.deduplication.schedule.days holds '$_'. Use: $($Days -join ', ')." }; $match[0] }
            if (-not $dayList) { Exit-InputProblem "$at.deduplication.schedule.days is empty. List the days the job runs, or EveryDay." }
            $hours = ConvertTo-WholeNumber (Get-Field $scheduleMap 'duration_hours' '') "$at.deduplication.schedule.duration_hours" 1 24
            $schedule = @{ StartTime = $start; Days = (@($dayList) -join ','); Hours = [int]$hours }
        }
    }
    elseif ($null -ne $scheduleMap) { Exit-InputProblem "$at.deduplication.schedule is set but deduplication.type is none." }

    $plans.Add([pscustomobject]@{ Name = $name; Parameters = $parameters; TierProvisioning = $tierProvisioning; Dedup = if ($dedupKey -ne 'none') { $DedupType[$dedupKey] } else { '' }; Schedule = $schedule; Summary = "$sizeGib GiB, $(if ($resiliency) { $resiliency } else { 'default resiliency' }), $fileSystem" })
}

# ---- the cluster as it is (read only)
Write-Line "Cluster '$target': reading the storage pool and the volumes"
try { $state = Invoke-Cluster 'ReadState' @($poolName) }
catch { Exit-Failed "The cluster '$target' could not be read: $($_.Exception.Message)" }
$pools = @($state.Pools)
if ($pools.Count -eq 0) { Exit-Failed $(if ($poolName) { "The storage pool '$poolName' (storage.pool.name) does not exist on '$target'." } else { "No Storage Spaces Direct pool was found on '$target'." }) }
if ($pools.Count -gt 1) { Exit-Failed "More than one storage pool was found on '$target' ($(@($pools | ForEach-Object { $_.Name }) -join ', ')). Name the one to use in storage.pool.name." }
$poolName = [string]$pools[0].Name
$liveNodes = @($state.Nodes).Count
if ($nodeCount -and $liveNodes -and $liveNodes -ne $nodeCount) { Write-Warning "The file lists $nodeCount machines; the cluster has $liveNodes. The resiliency rules were checked against the file." }
Write-Line "Storage pool '$poolName', $liveNodes machine(s)"

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed] ' } 'AlreadyExists' { '[exists] ' } 'AlreadySet' { '[exists] ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[done]   ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Item, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}

foreach ($plan in $plans) {
    $item = "volume $($plan.Name)"
    $exists = @($state.Volumes) -contains $plan.Name
    try {
        if ($exists) { Add-Row $item 'AlreadyExists' 'left as it is' }
        else {
            $missingTiers = @(@($plan.Parameters['StorageTierFriendlyNames']) | Where-Object { $_ -and @($state.Tiers) -notcontains $_ })
            if ($missingTiers) { throw "The storage tier(s) $($missingTiers -join ', ') do not exist in the pool. Tiers the cluster has: $(@($state.Tiers) -join ', ')." }
            if ($PSCmdlet.ShouldProcess("$item on '$target'", "Create ($($plan.Summary))")) {
                $parameters = $plan.Parameters.Clone()
                $parameters.StoragePoolFriendlyName = $poolName
                Invoke-Cluster 'NewVolume' @($parameters, $plan.TierProvisioning)
                Add-Row $item 'Created' $plan.Summary
                $exists = $true
            }
            else { Add-Row $item 'WouldCreate' $plan.Summary }
        }

        if ($plan.Dedup) {
            $dedupItem = "deduplication of $($plan.Name)"
            if (-not $exists) { Add-Row $dedupItem 'WouldSet' $plan.Dedup; continue }
            $where = Invoke-Cluster 'GetOwner' @($plan.Name)
            if (-not $where -or -not $where.Owner) { throw "The cluster shared volume of '$($plan.Name)' was not found, so deduplication could not be set." }
            # ReFS deduplication is set on the machine that owns the volume (Microsoft Learn, Optimize storage with ReFS deduplication in Azure Local).
            $current = Invoke-Cluster 'ReadDedup' @($where.Path) -Target $where.Owner
            if ($current.Enabled -and $current.Type -ne $plan.Dedup) { Add-Row $dedupItem 'AlreadySet' "is $($current.Type), the file says $($plan.Dedup); left as it is"; continue }
            if ($current.Enabled -and -not $plan.Schedule) { Add-Row $dedupItem 'AlreadySet' $current.Type; continue }
            if ($PSCmdlet.ShouldProcess("$dedupItem on '$($where.Owner)'", "Set $($plan.Dedup)")) {
                Invoke-Cluster 'SetDedup' @($where.Path, $(if ($current.Enabled) { '' } else { $plan.Dedup }), $plan.Schedule) -Target $where.Owner
                Add-Row $dedupItem 'Set' $(if ($plan.Schedule) { "$($plan.Dedup); $($plan.Schedule.Days) at $($plan.Schedule.StartTime) for $($plan.Schedule.Hours) h" } else { "$($plan.Dedup); no schedule, so a job runs only when someone starts one" })
            }
            else { Add-Row $dedupItem 'WouldSet' $plan.Dedup }
        }
    }
    catch { Add-Row $item 'Failed' $_.Exception.Message }
}

$settings = @(
    @{ Item = 'CSV in-memory read cache'; Wanted = $cacheSize; Current = [int]$state.BlockCacheSize; Step = 'SetCache'; Arguments = @($cacheSize); Unit = 'MiB per machine'; Note = 'takes effect when the volumes next move or come online' }
    @{ Item = "thin provisioning alert threshold of '$poolName'"; Wanted = $threshold; Current = $(if (@($pools[0].Thresholds).Count) { [int]@($pools[0].Thresholds)[0] } else { -1 }); Step = 'SetThreshold'; Arguments = @($poolName, $threshold); Unit = 'percent'; Note = '' }
)
foreach ($setting in $settings) {
    if ($null -eq $setting.Wanted) { continue }
    try {
        if ([long]$setting.Current -eq [long]$setting.Wanted) { Add-Row $setting.Item 'AlreadySet' "$($setting.Wanted) $($setting.Unit)" }
        elseif ($PSCmdlet.ShouldProcess("$($setting.Item) on '$target'", "Set to $($setting.Wanted) $($setting.Unit)")) {
            Invoke-Cluster $setting.Step $setting.Arguments
            Add-Row $setting.Item 'Set' (("$($setting.Wanted) $($setting.Unit), was $($setting.Current)", $setting.Note | Where-Object { $_ }) -join '; ')
        }
        else { Add-Row $setting.Item 'WouldSet' "$($setting.Wanted) $($setting.Unit), is $($setting.Current)" }
    }
    catch { Add-Row $setting.Item 'Failed' $_.Exception.Message }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
