#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-cluster verification, category STORAGE (ST-): the local data disks Storage Spaces Direct will take, and the SAN (Fibre Channel
    or iSCSI) LUNs the nodes see with Multipath I/O.

.DESCRIPTION
    Harvested, not written from scratch: azl-toolkit 04-cluster-deployment phase-03-os-configuration task-11 Clear-StorageConfiguration.ps1
    and task-13 Task11_Storage (S2D readiness: pools, virtual disks, RAW disks), tasks 12-14 (MPIO and SAN LUN), the node payload of the
    OS configuration (the san read), the toolkit's scripts/validation/storage-tests, config/san/msdsm-vendors.json, and Microsoft Learn
    (azloc-2610) enable-external-storage, deployment-install-os-disaggregated and system-requirements-23h2.

    Real failure of the lab that is a check here (ST-004, ST-006, ST-007): Azure's Test-Cluster failed with 'Two disks have been found
    on node X that cannot be distinguished from one another'. Two Pure FlashArray FC LUNs, four paths each, were visible as EIGHT disks
    because MPIO did not claim the array. The proven fix is  mpclaim -n -i -d "<VendorId padded to 8><ProductId padded to 16>"  and a
    restart of the node. When the file declares no SAN (storage_architecture s2d, no storage.san) the finding is still Failed, with the
    evidence: the disks must not be there, or the file must say so.

    Contract with the engine: see AzlVerification.NodeCommon.psm1. Read only.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AzlVerification.NodeCommon.psm1'))

$script:Src = Get-AzlVerConstant Source
$script:SanBus = @('Fibre Channel', 'FibreChannel', 'iSCSI')
$script:NotLocalBus = @('USB', 'SD', 'MMC', 'Fibre Channel', 'FibreChannel', 'iSCSI', 'Virtual', 'File Backed Virtual', 'Spaces')

function Get-AzlVerSanDisk {
    # The Fibre Channel and iSCSI disks of a node (Get-Disk BusType).
    param($Disk)
    @(ConvertTo-AzlVerList $Disk | Where-Object { [string](Get-AzlProp $_ 'bus' '') -in $script:SanBus })
}

function Get-AzlVerSanGroup {
    # SAN disks grouped by SerialNumber (else UniqueId): one group per LUN; a group of more than one is one LUN seen several times.
    param($Disk)
    $rows = @(Get-AzlVerSanDisk $Disk)
    $rows | Group-Object { $s = [string](Get-AzlProp $_ 'serial' ''); if ($s) { $s } else { [string](Get-AzlProp $_ 'uid' '') } }
}

function Get-AzlVerLocalDataDisk {
    # The local data disks from Get-PhysicalDisk rows: not boot, not system, not a SAN, USB or virtual disk. The boot device (BOSS) is excluded.
    param($Physical)
    @(ConvertTo-AzlVerList $Physical | Where-Object { -not [bool](Get-AzlProp $_ 'boot' $false) -and -not [bool](Get-AzlProp $_ 'system' $false) -and [string](Get-AzlProp $_ 'bus' '') -notin $script:NotLocalBus })
}

function Get-AzlVerMsdsmTarget {
    <#
    .SYNOPSIS
        The MSDSM hardware IDs that should be claimed, with the exact mpclaim command: what the node shows for its FC/iSCSI buses
        (Get-MPIOAvailableHW), else config/san/msdsm-vendors.json for the array of the file, else the first word of the disk model.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, $Mpio, $Disk)
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($h in (ConvertTo-AzlVerList (Get-AzlProp $Mpio 'availableHw' @()))) {
        if ([string](Get-AzlProp $h 'bus' '') -in $script:SanBus -or [string](Get-AzlProp $h 'bus' '') -match 'Fibre|iSCSI|FC') { $found.Add([pscustomobject]@{ Vendor = [string]$h.vendor; Product = [string]$h.product; Source = 'Get-MPIOAvailableHW' }) }
    }
    if (-not $found.Count) {
        $array = Get-AzlProp (Get-AzlVerInfra $Context) 'storage.san.array' $null
        $row = $null
        if ($array) { try { $row = Get-AzlVerSanVendor -Vendor ([string](Get-AzlProp $array 'vendor' '')) -Model ([string](Get-AzlProp $array 'model' '')) } catch { $row = $null } }
        if ($row) { foreach ($hw in $row.Hardware) { $found.Add([pscustomobject]@{ Vendor = [string]$hw.vendorId; Product = [string]$hw.productId; Source = 'config/san/msdsm-vendors.json' }) } }
    }
    if (-not $found.Count) {
        $m = [string](Get-AzlProp (@(Get-AzlVerSanDisk $Disk) | Select-Object -First 1) 'model' '')
        if ($m) { $parts = $m -split '\s+', 2; $found.Add([pscustomobject]@{ Vendor = $parts[0]; Product = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }); Source = 'the disk model' }) }
    }
    @($found | Group-Object { "$($_.Vendor)|$($_.Product)" } | ForEach-Object { $_.Group[0] } | ForEach-Object {
            [pscustomobject]@{ Vendor = $_.Vendor; Product = $_.Product; Source = $_.Source; Command = "mpclaim -n -i -d `"$(Format-AzlVerMsdsmId -VendorId $_.Vendor -ProductId $_.Product)`"" }
        })
}

function Format-AzlVerDuplicateEvidence {
    # The text Azure's Test-Cluster prints for it, built from what the node showed.
    param([string]$Node, $Group)
    $numbers = @($Group.Group | ForEach-Object { "Disk $($_.num)" }) -join ', '
    "Two disks have been found on node $Node that cannot be distinguished from one another: $numbers present the same LUN (serial/UniqueId $($Group.Name), $($Group.Count) paths seen as $($Group.Count) disks)"
}

function Get-AzlVerificationCheckDefinition {
    <#
    .SYNOPSIS
        The check definitions of the STORAGE category (ST-001 to ST-011).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The per node script blocks take the one signature (Name, Data, NodeInfo) whether a check needs all three or not.')]
    [CmdletBinding()]
    param()
    $defs = [System.Collections.Generic.List[object]]::new()
    $isS2d = { param($Context) if ((Get-AzlVerArchitecture $Context) -in 's2d', 'hybrid') { $true } else { $false } }
    $isSan = { param($Context) if ((Get-AzlVerArchitecture $Context) -eq 'san') { $true } else { $false } }

    $defs.Add((New-AzlVerDefinition -Id 'ST-001' -Category storage -Title 'Storage Spaces Direct: at least two local data disks of the minimum size per node, the same number and size on every node' `
                -Source "$($script:Src.SysReq) (Machine and storage requirements)" -Applies $isS2d -Run {
                param($Context)
                $minGb = [double](Get-AzlVerSetting $Context 'verificationMinDataDiskGB')
                $declared = [int](Get-AzlProp (Get-AzlVerInfra $Context) 'hardware.drives.capacity.count' 0)
                $summary = [ordered]@{}
                Invoke-AzlVerPerNode -Context $Context -Section 'GetDisks' -Body {
                    param($Name, $D, $N)
                    $data = @(Get-AzlVerLocalDataDisk (Get-AzlProp $D 'physical' @()))
                    $big = @($data | Where-Object { [int64]$_.size -ge ($minGb * 1e9 * 0.95) })
                    $raid = @($data | Where-Object { [string]$_.bus -eq 'RAID' })
                    $summary[$Name] = "$($data.Count) disks: " + ((@($data | ForEach-Object { "$([math]::Round([int64]$_.size / 1e9))GB $($_.media)/$($_.bus)" } | Sort-Object)) -join ', ')
                    if ($raid) { New-AzlVerResult Failed "$Name presents $($raid.Count) disk(s) through a RAID controller (bus type RAID). Learn: RAID controllers are not supported, the drives must be in HBA / pass-through mode." 'Put the storage controller (PERC) in HBA mode and expose the drives directly.' -Node $Name -Evidence (($raid | ForEach-Object { $_.name }) -join ',') }
                    elseif ($big.Count -lt 2) { New-AzlVerResult Failed "$Name has $($big.Count) data disk(s) of at least $minGb GB ($($data.Count) non-boot local disks). Learn: at least two disks per machine with a minimum capacity of $minGb GB." 'Install the missing drives, or check that the controller is in HBA / pass-through mode.' -Node $Name -Evidence $summary[$Name] }
                    elseif ($declared -gt 0 -and $data.Count -ne $declared) { New-AzlVerResult Warning "$Name has $($data.Count) local data disks, the file declares hardware.drives.capacity.count $declared." 'Check the drive count in the file against the node.' -Node $Name -Evidence $summary[$Name] }
                    else { New-AzlVerResult Passed "$Name has $($data.Count) local data disks ($($big.Count) of them $minGb GB or more); the boot device is excluded." -Node $Name -Evidence $summary[$Name] }
                }
                if (@($summary.Values | Select-Object -Unique).Count -gt 1) { New-AzlVerResult Failed ('The nodes do not have the same drives (Learn: same number and type of drives, with the same capacity, on every server): ' + (($summary.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join ' | ')) 'Use the same drive configuration on every node.' }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-002' -Category storage -Title 'Local data disks are eligible for Storage Spaces Direct: clean, poolable, no partitions (the boot device is excluded)' `
                -Source "$($script:Src.Install) (Clean all the non-OS drives); azl-toolkit phase-03-os-configuration task-11 Clear-StorageConfiguration.ps1 / task-13 Task11_Storage; $($script:Src.EnvChecker) (hardware validator)" -Applies $isS2d -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetDisks' -Body {
                    param($Name, $D, $N)
                    $data = @(Get-AzlVerLocalDataDisk (Get-AzlProp $D 'physical' @()))
                    $dirty = @($data | Where-Object { -not [bool]$_.canPool -or [int]$_.parts -gt 0 -or ([string]$_.style -notin 'RAW', '') })
                    if ($dirty) {
                        $list = @($dirty | ForEach-Object { "disk $($_.num) $($_.name) ($([math]::Round([int64]$_.size / 1e9)) GB, $(if ([int]$_.parts -gt 0) { "$($_.parts) partition(s), $($_.style)" } else { $_.style }), canPool=$($_.canPool)$(if ($_.reason) { ", $($_.reason)" }))" })
                        New-AzlVerResult Failed "$Name has $($dirty.Count) local disk(s) that Storage Spaces Direct cannot take as they are: $($list -join '; '). Learn: clean all the non-OS drives of each machine before the deployment." 'The OS configuration ClearStorage step cleans them (os_configuration.clear_storage; it never touches SAN LUNs), or on the node, destroying the data on them: Clear-Disk -Number <n> -RemoveData -RemoveOEM -Confirm:$false' -Node $Name -Evidence ($list -join ' | ')
                    }
                    else { New-AzlVerResult Passed "All $($data.Count) local data disks of $Name are clean and poolable." -Node $Name -Evidence "disks=$($data.Count)" }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-003' -Category storage -Title 'No storage pool or virtual disk left on the nodes' `
                -Source "$($script:Src.EnvChecker) (hardware validator: No storage pools exist, Critical); azl-toolkit task-13 Task11_Storage" -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetDisks' -Body {
                    param($Name, $D, $N)
                    $pools = @(ConvertTo-AzlVerList (Get-AzlProp $D 'pools' @()))
                    $vd = [int](Get-AzlProp $D 'vdisks' 0)
                    if ($pools.Count -or $vd) { New-AzlVerResult Failed "$Name has $($pools.Count) storage pool(s) ($(Join-AzlVerList $pools)) and $vd virtual disk(s). The hardware validator fails when a storage pool exists: the deployment creates the pool." 'The OS configuration ClearStorage step, or on the node (destroys the data): Get-StoragePool -IsPrimordial $false | Set-StoragePool -IsReadOnly $false; Get-VirtualDisk | Remove-VirtualDisk -Confirm:$false; Get-StoragePool -IsPrimordial $false | Remove-StoragePool -Confirm:$false' -Node $Name -Evidence "pools=$($pools.Count) vdisks=$vd" }
                    else { New-AzlVerResult Passed "$Name has no storage pool or virtual disk." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-004' -Category storage -Title 'Each SAN LUN is one disk: no Fibre Channel or iSCSI LUN is visible more than once (the Test-Cluster failure "Two disks ... cannot be distinguished")' `
                -Source "$($script:Src.ExtStorage) (Verify SAN disks); Azure Test-Cluster 'List Disks'; lab failure 2026-11-08 (Pure FlashArray, 2 LUNs x 4 paths = 8 disks)" -Run {
                param($Context)
                $declared = Test-AzlVerSanDeclared $Context
                Invoke-AzlVerPerNode -Context $Context -Section 'GetMpio' -Body {
                    param($Name, $D, $N)
                    $san = @(Get-AzlVerSanDisk (Get-AzlProp $D 'disks' @()))
                    if (-not $san.Count) { return New-AzlVerResult Passed "$Name sees no Fibre Channel or iSCSI disk." -Node $Name }
                    $groups = @(Get-AzlVerSanGroup (Get-AzlProp $D 'disks' @()))
                    $dups = @($groups | Where-Object { $_.Count -gt 1 })
                    if (-not $dups.Count) { return New-AzlVerResult Passed "$Name sees $($san.Count) SAN disk(s), each LUN once." -Node $Name -Evidence "luns=$($groups.Count) disks=$($san.Count)" }
                    $targets = @(Get-AzlVerMsdsmTarget -Context $Context -Mpio (Get-AzlProp $D 'mpio' $null) -Disk $san)
                    $evidence = @($dups | ForEach-Object { Format-AzlVerDuplicateEvidence -Node $Name -Group $_ })
                    $fix = if ($targets.Count) { 'Have MPIO claim the array, then restart the node and rescan: ' + (($targets | ForEach-Object { $_.Command }) -join '; ') + '; Restart-Computer; Update-HostStorageCache' } else { 'Have MPIO claim the array (mpclaim -n -i -d "<VendorId padded to 8><ProductId padded to 16>"), restart the node and rescan with Update-HostStorageCache.' }
                    if ($declared) { $why = "The file declares a SAN, but MPIO does not merge the paths ($($san.Count) disks for $($groups.Count) LUN(s))." }
                    else {
                        $why = "The file declares no SAN (scenario.storage_architecture $(Get-AzlVerArchitecture $Context), no storage.san) yet the node sees $($san.Count) SAN disk(s) for $($groups.Count) LUN(s)."
                        $fix += ' Or, for a design without a SAN, unmask/unzone the LUNs from the nodes (Learn hybrid: do not zone Fibre Channel HBAs until after the deployment), or declare the SAN in the file.'
                    }
                    New-AzlVerResult Failed "${Name}: $why $($evidence -join ' | ')." $fix -Node $Name -Evidence ($evidence -join ' | ')
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-005' -Category storage -Title 'Multipath I/O (MultipathIO feature) is on wherever SAN LUNs are declared or visible' `
                -Source "$($script:Src.ExtStorage) (Step 1.1: Verify Multipath I/O); azl-toolkit phase-03-os-configuration MPIO task" -Run {
                param($Context)
                $declared = Test-AzlVerSanDeclared $Context
                Invoke-AzlVerPerNode -Context $Context -Section 'GetMpio' -Body {
                    param($Name, $D, $N)
                    $san = @(Get-AzlVerSanDisk (Get-AzlProp $D 'disks' @()))
                    if (-not $declared -and -not $san.Count) { return New-AzlVerResult NotApplicable "No SAN is declared and $Name sees no SAN disk: MPIO is not needed." -Node $Name }
                    $state = [string](Get-AzlProp $D 'mpio.feature' '')
                    if ($state -eq 'Enabled') { New-AzlVerResult Passed "MPIO (MultipathIO) is Enabled on $Name." -Node $Name -Evidence 'MultipathIO=Enabled' }
                    else { New-AzlVerResult Failed "MPIO is '$state' on $Name. Learn: Azure Local 2604 and later enables Multipath I/O by default; verify it is enabled on all nodes. Without MPIO each path to a LUN is a separate disk." 'On the node: Enable-WindowsOptionalFeature -Online -FeatureName MultipathIO -NoRestart, then restart the node (or the OS configuration Mpio step).' -Node $Name -Evidence "MultipathIO=$state" }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-006' -Category storage -Title 'The array is claimed by MPIO: Get-MPIOAvailableHW shows IsMultipathed and the MSDSM supported hardware lists the vendor and product' `
                -Source "$($script:Src.ExtStorage) (Step 2.2: Register vendor device with MSDSM); config/san/msdsm-vendors.json" -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetMpio' -Body {
                    param($Name, $D, $N)
                    $san = @(Get-AzlVerSanDisk (Get-AzlProp $D 'disks' @()))
                    if (-not $san.Count) { return New-AzlVerResult NotApplicable "$Name sees no SAN disk, so there is no array to be claimed." -Node $Name }
                    $mpio = Get-AzlProp $D 'mpio' $null
                    $avail = @(ConvertTo-AzlVerList (Get-AzlProp $mpio 'availableHw' @()) | Where-Object { [string]$_.bus -in $script:SanBus -or [string]$_.bus -match 'Fibre|iSCSI|FC' })
                    $supported = @(ConvertTo-AzlVerList (Get-AzlProp $mpio 'supportedHw' @()) | ForEach-Object { "$($_.vendor)|$($_.product)".ToLowerInvariant() })
                    $targets = @(Get-AzlVerMsdsmTarget -Context $Context -Mpio $mpio -Disk $san)
                    $unclaimed = @($avail | Where-Object { -not [bool]$_.multipathed })
                    # MPIO's own list (the OS configuration writes it with mpclaim -n -i -d): a device in the MSDSM list but not in this one is not claimed. Only judged when the key could be read.
                    $mpdevRead = [bool](Get-AzlProp $mpio 'mpdevRead' $false)
                    $mpdev = @(ConvertTo-AzlVerList (Get-AzlProp $mpio 'mpdev' @()) | ForEach-Object { "$($_.vendor)|$($_.product)".ToLowerInvariant() })
                    $notInMpdev = @(if ($mpdevRead) { $targets | Where-Object { "$($_.Vendor)|$($_.Product)".ToLowerInvariant() -notin $mpdev } })
                    $notRegistered = @($targets | Where-Object { "$($_.Vendor)|$($_.Product)".ToLowerInvariant() -notin $supported })
                    $fix = if ($targets.Count) { (($targets | ForEach-Object { "$($_.Command)   (or New-MSDSMSupportedHW -VendorId '$($_.Vendor)' -ProductId '$($_.Product)')" }) -join '; ') + '; then Restart-Computer' } else { 'mpclaim -n -i -d "<VendorId padded to 8><ProductId padded to 16>" then Restart-Computer (add the vendor to config/san/msdsm-vendors.json)' }
                    $seen = (@($avail | ForEach-Object { "$($_.vendor) $($_.product) multipathed=$($_.multipathed)" }) -join '; ')
                    if ($notInMpdev.Count -and -not $unclaimed.Count) { New-AzlVerResult Failed "On $Name $(Join-AzlVerList @($notInMpdev | ForEach-Object { "$($_.Vendor) $($_.Product)" })) is not in MPIO's own list (HKLM:\SYSTEM\CurrentControlSet\Control\MPDEV, MPIOSupportedDeviceList), so MPIO does not claim it and every path stays a separate disk." $fix -Node $Name -Evidence "mpdev=$($mpdev -join ',')" }
                    elseif ($unclaimed.Count) { New-AzlVerResult Failed "On $Name MPIO does not claim $(Join-AzlVerList @($unclaimed | ForEach-Object { "$($_.vendor) $($_.product)" })) (IsMultipathed is False). Unclaimed, every path to a LUN is a separate disk and Azure's Test-Cluster fails with 'Two disks ... cannot be distinguished'." $fix -Node $Name -Evidence $seen }
                    elseif ($notRegistered.Count -and -not $avail.Count) { New-AzlVerResult Failed "On $Name MSDSM does not list $(Join-AzlVerList @($notRegistered | ForEach-Object { "$($_.Vendor) $($_.Product)" })) as supported hardware (Get-MSDSMSupportedHW: $(if ($supported.Count) { $supported -join ', ' } else { 'nothing registered' }))." $fix -Node $Name -Evidence "supported=$($supported -join ',')" }
                    elseif ($notRegistered.Count) { New-AzlVerResult Warning "On $Name $(Join-AzlVerList @($notRegistered | ForEach-Object { "$($_.Vendor) $($_.Product)" })) is multipathed but not in the MSDSM supported hardware list (Get-MSDSMSupportedHW)." $fix -Node $Name -Evidence $seen }
                    elseif (-not $avail.Count) { New-AzlVerResult Skipped "$Name lists no Fibre Channel or iSCSI hardware in Get-MPIOAvailableHW although it sees SAN disks (the MPIO cmdlets may be missing)." 'Install the MPIO feature (ST-005) and run Get-MPIOAvailableHW on the node.' -Node $Name }
                    else { New-AzlVerResult Passed "${Name}: MPIO claims $(Join-AzlVerList @($avail | ForEach-Object { "$($_.vendor) $($_.product)" }))." -Node $Name -Evidence $seen }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-007' -Category storage -Title 'mpclaim -s -d shows one MPIO disk per SAN LUN' `
                -Source "$($script:Src.ExtStorage) (Step 7: Verify SAN disks); azl-toolkit phase-03-os-configuration MPIO / SAN LUN tasks" -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetMpio' -Body {
                    param($Name, $D, $N)
                    $san = @(Get-AzlVerSanDisk (Get-AzlProp $D 'disks' @()))
                    if (-not $san.Count) { return New-AzlVerResult NotApplicable "$Name sees no SAN disk." -Node $Name }
                    $claims = @(ConvertTo-AzlVerList (Get-AzlProp $D 'mpio.claims' @()))
                    $luns = @(Get-AzlVerSanGroup (Get-AzlProp $D 'disks' @())).Count
                    $targets = @(Get-AzlVerMsdsmTarget -Context $Context -Mpio (Get-AzlProp $D 'mpio' $null) -Disk $san)
                    $fix = 'Claim the array (ST-006: ' + $(if ($targets.Count) { ($targets | ForEach-Object { $_.Command }) -join '; ' } else { 'mpclaim -n -i -d "<VendorId padded to 8><ProductId padded to 16>"' }) + '), restart the node, then check: mpclaim -s -d'
                    if (-not $claims.Count) { New-AzlVerResult Failed "mpclaim -s -d shows no MPIO disk on $Name although it sees $($san.Count) SAN disk(s) for $luns LUN(s): MPIO has claimed nothing." $fix -Node $Name -Evidence "mpioDisks=0 sanDisks=$($san.Count) luns=$luns" }
                    elseif ($claims.Count -lt $luns) { New-AzlVerResult Failed "mpclaim -s -d shows $($claims.Count) MPIO disk(s) on $Name for $luns LUN(s): some LUNs are not claimed." $fix -Node $Name -Evidence "mpioDisks=$($claims.Count) luns=$luns" }
                    else { New-AzlVerResult Passed "mpclaim -s -d shows $($claims.Count) MPIO disk(s) on $Name for $luns LUN(s)." -Node $Name -Evidence "mpioDisks=$($claims.Count) luns=$luns" }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-008' -Category storage -Title 'Hybrid: do not zone the Fibre Channel HBAs until after the deployment (LUNs must not be visible before it)' `
                -Source "$($script:Src.ExtStorage) (Fibre Channel prerequisites: Important)" -Blocking $false -Applies { param($Context) if ((Get-AzlVerArchitecture $Context) -ne 'san') { $true } else { $false } } -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetMpio' -Body {
                    param($Name, $D, $N)
                    $fcDisks = @(Get-AzlVerSanDisk (Get-AzlProp $D 'disks' @()) | Where-Object { [string]$_.bus -match 'Fibre' })
                    if ($fcDisks.Count) { New-AzlVerResult Warning "$Name sees $($fcDisks.Count) Fibre Channel disk(s) before the deployment. Learn (hybrid): do not zone the Fibre Channel HBA WWNs to the array until after the deployment; visible LUNs are claimed by the cluster validation and make Test-Cluster fail." 'Remove the zoning of the node HBA WWPNs (or unmask the LUNs on the array) until the deployment has finished; add the external storage afterwards (Learn: Connect an external storage array to Azure Local).' -Node $Name -Evidence "fcDisks=$($fcDisks.Count)" }
                    else { New-AzlVerResult Passed "$Name sees no Fibre Channel LUN before the deployment." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-009' -Category storage -Title 'Every node sees the same SAN LUNs, with the same LUN IDs' `
                -Source "$($script:Src.ExtStorage) (consistent LUN IDs; Step 7)" -Applies { param($Context) if (Test-AzlVerSanDeclared $Context) { $true } else { $false } } -Run {
                param($Context)
                $all = Get-AzlVerAllNodeData -Context $Context -Section 'GetMpio'
                if (-not $all.Data.Count) { Stop-AzlVerSkip "No node could be read (ND-001): $(Join-AzlVerList @($all.Unread.Keys))." 'Make the nodes reachable, then run the verification again.' }
                $sets = [ordered]@{}; $luns = @{}
                foreach ($k in $all.Data.Keys) {
                    $groups = @(Get-AzlVerSanGroup (Get-AzlProp $all.Data[$k] 'disks' @()))
                    $sets[$k] = @($groups | ForEach-Object { $_.Name } | Sort-Object -Unique)
                    foreach ($g in $groups) { if (-not $luns.ContainsKey($g.Name)) { $luns[$g.Name] = @{} }; $luns[$g.Name][$k] = [string](Get-AzlProp $g.Group[0] 'lun' '') }
                }
                if (-not @($sets.Values | ForEach-Object { $_ }).Count) { return New-AzlVerResult Warning 'The file declares a SAN but no node sees a LUN yet. Expected when the zoning is done after the deployment (hybrid); for a SAN-only design the LUNs must be visible.' 'For storage_architecture san: zone and unmask the LUNs to every node (ST-010).' }
                $problems = @()
                $union = @($sets.Values | ForEach-Object { $_ } | Select-Object -Unique)
                foreach ($k in $sets.Keys) { $absent = @($union | Where-Object { $_ -notin $sets[$k] }); if ($absent) { $problems += "$k does not see LUN(s) $((@($absent | Select-Object -First 3)) -join ', ')$(if ($absent.Count -gt 3) { " and $($absent.Count - 3) more" })" } }
                foreach ($uid in $luns.Keys) { $ids = @($luns[$uid].Values | Where-Object { $_ -ne '' } | Select-Object -Unique); if ($ids.Count -gt 1) { $problems += "LUN $uid has different LUN IDs: $(($luns[$uid].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')" } }
                if ($all.Unread.Count) { $problems += "$(Join-AzlVerList @($all.Unread.Keys)) could not be read" }
                if ($problems) { return New-AzlVerResult Failed ('The nodes do not agree on the LUNs: ' + ($problems -join '; ') + '. Learn: all nodes must see the same set of LUNs (compare serial / UniqueId; disk numbers may differ) with consistent LUN IDs.') 'On the array, map every LUN to all node initiators with the same LUN ID; rescan with Update-HostStorageCache.' -Evidence ($problems -join ' | ') }
                New-AzlVerResult Passed "All $($sets.Count) node(s) see the same $($union.Count) LUN(s) with the same LUN IDs." -Evidence "luns=$($union.Count)"
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-010' -Category storage -Title 'Disaggregated: the infrastructure LUN (250 GB) and the performance history LUN (20 GB) are visible on every node and still RAW' `
                -Source "$($script:Src.InstallDa) (Prerequisites, Connect to SAN); $($script:Src.SysReq)" -Applies $isSan -Run {
                param($Context)
                $wants = @(@{ Key = 'infra_volume_lun_id'; Label = 'infrastructure'; MinGb = 250 }, @{ Key = 'performance_history_lun_id'; Label = 'performance history'; MinGb = 20 })
                Invoke-AzlVerPerNode -Context $Context -Section 'GetMpio' -Body {
                    param($Name, $D, $N)
                    $groups = @(Get-AzlVerSanGroup (Get-AzlProp $D 'disks' @()))
                    $problems = @()
                    foreach ($w in $wants) {
                        $id = [string](Get-AzlProp (Get-AzlVerInfra $Context) "storage.san.$($w.Key)" '')
                        if ($id -eq '') { $problems += "storage.san.$($w.Key) is empty"; continue }
                        $g = @($groups | Where-Object { $d0 = $_.Group[0]; if ($id -match '^\d{1,4}$') { [string](Get-AzlProp $d0 'lun' '') -eq $id } else { [string](Get-AzlProp $d0 'uid' '') -ieq $id -or [string](Get-AzlProp $d0 'serial' '') -ieq $id } }) | Select-Object -First 1
                        if (-not $g) { $problems += "the $($w.Label) LUN $id is not visible"; continue }
                        $disk = $g.Group[0]
                        if ([double]$disk.size * 1.0 / 1e9 * 1.073741824 -lt ($w.MinGb * 0.95)) { $problems += "the $($w.Label) LUN $id is $([math]::Round([double]$disk.size / 1e9)) GB, smaller than the $($w.MinGb) GB Learn asks for" }
                        if ([string]$disk.style -ne 'RAW') { $problems += "the $($w.Label) LUN $id has partition style $($disk.style): it was initialized. Learn: don't initialize the drives, the deployment expects RAW" }
                    }
                    if ($problems) { New-AzlVerResult Failed "${Name}: $($problems -join '; ')." 'Present the two LUNs to every node (infrastructure 250 GB, performance history 20 GB), leave them RAW (a wrongly initialized LUN: Clear-Disk -Number <n> -RemoveData on ONE node after checking it is not in use), rescan with Update-HostStorageCache.' -Node $Name -Evidence ($problems -join ' | ') }
                    else { New-AzlVerResult Passed "$Name sees both system LUNs, large enough and RAW." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ST-011' -Category storage -Title 'Fibre Channel: the HBA ports of the file are present on the nodes' `
                -Source "$($script:Src.InstallDa) (Connect to SAN, Fibre Channel)" -Blocking $false -Applies {
                param($Context) if ((Test-AzlVerSanDeclared $Context) -and ([string](Get-AzlProp (Get-AzlVerInfra $Context) 'storage.san.type' '') -eq 'fibre_channel')) { $true } else { $false } } -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetMpio' -Body {
                    param($Name, $D, $N)
                    $wanted = @()
                    foreach ($hba in (ConvertTo-AzlVerList (Get-AzlProp (Get-AzlVerInfra $Context) 'nodes' @()) | Where-Object { [string](Get-AzlProp $_ 'name' '') -eq $Name } | ForEach-Object { ConvertTo-AzlVerList (Get-AzlProp $_ 'san.hbas' @()) })) {
                        foreach ($p in (ConvertTo-AzlVerList (Get-AzlProp $hba 'ports' @()))) { $wanted += ([string](Get-AzlProp $p 'wwpn' '') -replace '[:\-]', '').ToLowerInvariant() }
                    }
                    $have = @(ConvertTo-AzlVerList (Get-AzlProp $D 'fc' @()) | ForEach-Object { ([string]$_.wwpn -replace '[:\-]', '').ToLowerInvariant() })
                    if (-not $wanted.Count) { return New-AzlVerResult Skipped "The file lists no HBA port (nodes[].san.hbas[].ports[].wwpn) for $Name." 'Record the WWPNs: Get-InitiatorPort on the node.' -Node $Name }
                    $missing = @($wanted | Where-Object { $_ -notin $have })
                    if ($missing) { New-AzlVerResult Failed "$Name does not show the HBA port(s) $(Join-AzlVerList $missing) of the file (it shows $(if ($have.Count) { $have -join ', ' } else { 'none' }))." 'Check the HBA, its driver and the WWPNs in the file (Get-InitiatorPort).' -Node $Name -Evidence "have=$($have -join ',')" }
                    else { New-AzlVerResult Passed "$Name shows all $($wanted.Count) HBA port(s) of the file." -Node $Name }
                }
            }))

    return $defs.ToArray()
}

function Get-AzlVerificationAdapterDefault {
    <#
    .SYNOPSIS
        The real, read only adapter members of the STORAGE checks: Remote.Invoke and the Node.* members they read (one remote call
        per node, cached in the Context). The engine merges them with the other categories' members; tests replace any of them.
    #>
    [CmdletBinding()]
    param([pscredential]$Credential, [hashtable]$Address = @{}, [switch]$UseSsl, [string]$Authentication = 'Default')
    @{
        Remote = @{ Invoke = (New-AzlVerRemoteDefault -Credential $Credential -Address $Address -UseSsl:$UseSsl -Authentication $Authentication) }
        Node   = (New-AzlVerNodeAdapterDefault)
    }
}

Export-ModuleMember -Function Get-AzlVerificationCheckDefinition, Get-AzlVerificationAdapterDefault
