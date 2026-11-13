#Requires -Version 7.0
<#
.SYNOPSIS
    Vendor-neutral hardware inventory of one machine, built from what its BMC says over the standard DMTF Redfish API.

.DESCRIPTION
    The reader is AzlRedfishCore.psm1, run with -Vendor None -Detail Inventory: standard resources only (Systems, Processors,
    Memory, Storage and Drives, NetworkAdapters and Ports, Chassis, Managers, UpdateService FirmwareInventory, TrustedModules).
    No vendor (OEM) extension and no vendor adapter is used, for any BMC. A fact that a vendor shows only under an OEM path is
    written as "not reported". This module turns that report into the inventory of one node, compares the nodes with each other,
    and compares them with what infrastructure.yml says. Nothing here talks to a BMC.

    Fields that need a rule are stated in the file itself (rules):

      Drive media type   NVMe when the drive Protocol is NVMe. Otherwise the Redfish MediaType: SSD is SSD, HDD and SMR are HDD.
      Drive role         Storage Spaces Direct rule (Microsoft Learn, "Understanding the storage pool cache"): when more than one
                         media type is present, all drives of the fastest type (NVMe, then SSD, then HDD) are cache and the rest
                         are capacity. When all drives are one type, no cache is set up and every drive is capacity.
                         Not counted: a drive that is not present, and a drive that is a member of a RAID volume of its controller
                         (Azure Local does not support RAID for these drives). Role excluded, with the reason.
      Port order         The order in which the BMC lists the network adapters, then the port number on the adapter.

    The role is what Storage Spaces Direct will do with the drives by default. It is not read from the machine: nothing is
    configured yet when this runs.

    Functions
        ConvertTo-AzlHardwareInventoryNode   report of Invoke-AzlRedfishDiscovery -> the inventory entry of one node
        Get-AzlHardwareDriveList             drives with media type and role, and a summary
        Get-AzlHardwareSymmetry              the checks across nodes (Microsoft Learn: same model, processors, adapters, drives)
        Compare-AzlHardwarePlan              what infrastructure.yml says against what the BMC reported
        Get-AzlHardwareInventoryRule         the rule text written into the file

    Keys read (Compare-AzlHardwarePlan): hardware.vendor, hardware.model, hardware.cpu_cores, hardware.memory_gib,
    hardware.gpu.enabled, hardware.gpu.model, hardware.gpu.count_per_node, hardware.drives.capacity.media, .count, .size_tb,
    hardware.drives.cache.media, .count, .size_tb, nodes[].bmc.type, nodes[].serial_number.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([System.IO.Path]::Combine($PSScriptRoot, 'AzlRedfishCore.psm1'))
Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))

$script:ToolVersion = '1.0.0'
$script:SchemaVersion = '1.0'
$script:NotReportedText = 'not reported'
# The Storage Spaces Direct drive hierarchy, fastest first (Microsoft Learn, Understanding the storage pool cache).
$script:MediaOrder = @('NVMe', 'SSD', 'HDD')

function Get-AzlHardwareInventoryRule {
    <#
    .SYNOPSIS
        The rules the inventory applies, as text for the file.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return [ordered]@{
        source      = 'DMTF Redfish standard resources only. No vendor (OEM) path is read. A fact the BMC does not give in a standard resource is "not reported".'
        mediaType   = 'NVMe when the drive Protocol is NVMe. Otherwise the Redfish MediaType: SSD is SSD; HDD and SMR are HDD. Neither given: not reported.'
        driveRole   = 'Storage Spaces Direct default (Microsoft Learn, Understanding the storage pool cache). More than one media type present: every drive of the fastest type (NVMe, then SSD, then HDD) is cache, the others are capacity. One media type only: no cache is set up, every drive is capacity. Not counted (role excluded): a drive that is not present, and a drive that is a member of a RAID volume of its controller.'
        portOrder   = 'The order in which the BMC lists the network adapters, then the port number on the adapter. It is not the PCI bus order.'
        driveSizeTB = 'Decimal terabytes (bytes divided by 10^12), as drives are sold.'
    }
}

function ConvertTo-AzlReportedValue {
    # The value, or "not reported" when the BMC gave none (null, empty or blank text).
    param($Value)
    if ($null -eq $Value) { return $script:NotReportedText }
    if ($Value -is [string] -and $Value.Trim().Length -eq 0) { return $script:NotReportedText }
    return $Value
}

function Get-AzlDriveMedia {
    <#
    .SYNOPSIS
        NVMe, SSD or HDD for one drive; $null when the BMC gives neither a Protocol nor a MediaType.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$MediaType, [AllowNull()][string]$Protocol)
    if ($Protocol -and $Protocol -match '^(?i)NVMe') { return 'NVMe' }
    switch -Regex ($MediaType) {
        '^(?i)SSD$' { return 'SSD' }
        '^(?i)(HDD|SMR)$' { return 'HDD' }
    }
    return $null
}

function Get-AzlHardwareDriveList {
    <#
    .SYNOPSIS
        The drives of one machine with media type, size and role (cache, capacity, excluded or unclassified), and a summary.
    .PARAMETER Storage
        The storage block of the Redfish report (controllers, drives, volumes).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()]$Storage)
    $rawDrives = @(Get-RfArray $Storage 'drives')
    $raidMember = @{}
    foreach ($v in @(Get-RfArray $Storage 'volumes')) {
        $raid = Get-RfText $v 'raidType'
        if (-not $raid -or $raid -eq 'None') { continue }
        foreach ($driveId in @(Get-RfArray $v 'driveIds')) { $raidMember[[string]$driveId] = $raid }
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $rawDrives) {
        $id = Get-RfText $d 'id'
        $media = Get-AzlDriveMedia -MediaType (Get-RfText $d 'mediaType') -Protocol (Get-RfText $d 'protocol')
        $state = Get-RfText (Get-RfProp $d 'health') 'state'
        $role = $null
        $reason = $null
        if ($state -eq 'Absent') { $role = 'excluded'; $reason = 'The drive is not present (Status.State Absent).' }
        elseif ($id -and $raidMember.ContainsKey($id)) { $role = 'excluded'; $reason = "The drive is a member of a $($raidMember[$id]) volume of its controller. Azure Local does not support RAID for Storage Spaces Direct drives." }
        elseif (-not $media) { $role = 'unclassified'; $reason = 'The BMC gives neither a Protocol nor a usable MediaType.' }
        $bytes = Get-RfProp $d 'capacityBytes'
        $entries.Add([pscustomobject][ordered]@{
                id = ConvertTo-AzlReportedValue $id; controller = ConvertTo-AzlReportedValue (Get-RfText $d 'controllerId')
                bay = ConvertTo-AzlReportedValue (Get-RfText $d 'bay'); model = ConvertTo-AzlReportedValue (Get-RfText $d 'model')
                manufacturer = ConvertTo-AzlReportedValue (Get-RfText $d 'manufacturer'); serialNumber = ConvertTo-AzlReportedValue (Get-RfText $d 'serialNumber')
                firmware = ConvertTo-AzlReportedValue (Get-RfText $d 'firmwareVersion')
                mediaType = $(if ($media) { $media } else { $script:NotReportedText })
                bus = ConvertTo-AzlReportedValue (Get-RfText $d 'protocol')
                sizeBytes = ConvertTo-AzlReportedValue $bytes
                sizeTB = $(if ($null -ne $bytes) { [math]::Round(([double]$bytes) / 1e12, 3) } else { $script:NotReportedText })
                sizeGiB = $(if ($null -ne $bytes) { [math]::Round(([double]$bytes) / 1GB, 2) } else { $script:NotReportedText })
                blockSizeBytes = ConvertTo-AzlReportedValue (Get-RfProp $d 'blockSizeBytes')
                health = ConvertTo-AzlReportedValue (Get-RfText (Get-RfProp $d 'health') 'health')
                lifeLeftPercent = ConvertTo-AzlReportedValue (Get-RfProp $d 'predictedLifeLeftPercent')
                role = $role; roleReason = $reason
            })
    }

    # The role rule, over the drives that count.
    $counted = @($entries | Where-Object { $null -eq $_.role })
    $present = @($script:MediaOrder | Where-Object { $m = $_; @($counted | Where-Object { $_.mediaType -eq $m }).Count -gt 0 })
    $cacheMedia = $null
    if ($present.Count -gt 1) { $cacheMedia = $present[0] }
    foreach ($e in $counted) {
        if ($cacheMedia -and $e.mediaType -eq $cacheMedia) {
            $e.role = 'cache'
            $e.roleReason = "$cacheMedia is the fastest of the media types present ($($present -join ', ')); Storage Spaces Direct uses these drives for cache."
        }
        else {
            $e.role = 'capacity'
            $e.roleReason = $(if ($present.Count -gt 1) { "$($e.mediaType) is not the fastest media type present ($($present -join ', ')), so it is capacity." } else { "Only one media type ($($e.mediaType)) is present, so no cache is set up and every drive is capacity." })
        }
    }
    $byMedia = @(foreach ($m in $script:MediaOrder) {
            $all = @($entries | Where-Object { $_.mediaType -eq $m -and $_.role -ne 'excluded' })
            if ($all.Count -gt 0) { [ordered]@{ mediaType = $m; count = $all.Count; cache = @($all | Where-Object { $_.role -eq 'cache' }).Count; capacity = @($all | Where-Object { $_.role -eq 'capacity' }).Count } }
        })
    $summary = [ordered]@{
        listed       = $entries.Count
        counted      = $counted.Count
        excluded     = @($entries | Where-Object { $_.role -eq 'excluded' }).Count
        unclassified = @($entries | Where-Object { $_.role -eq 'unclassified' }).Count
        cacheMedia   = $(if ($cacheMedia) { $cacheMedia } else { 'none' })
        cacheCount   = @($entries | Where-Object { $_.role -eq 'cache' }).Count
        capacityCount = @($entries | Where-Object { $_.role -eq 'capacity' }).Count
        byMedia      = $byMedia
    }
    return [pscustomobject]@{ Drives = $entries.ToArray(); Summary = $summary }
}

function Get-AzlHardwareGpu {
    # GPUs: Processors of type GPU first (standard, carries memory), else the PCIe devices the core classed as display controllers.
    param($Report)
    $fromProcessor = @(foreach ($p in @(Get-RfArray $Report 'processors')) {
            if ((Get-RfText $p 'processorType') -ne 'GPU') { continue }
            $mib = Get-RfProp $p 'memoryMiB'
            [ordered]@{
                source = 'Processors'; model = ConvertTo-AzlReportedValue (Get-RfText $p 'model'); manufacturer = ConvertTo-AzlReportedValue (Get-RfText $p 'manufacturer')
                slot = ConvertTo-AzlReportedValue (Get-RfText $p 'socket'); memoryGiB = $(if ($null -ne $mib) { [math]::Round(([double]$mib) / 1024, 2) } else { $script:NotReportedText })
                serialNumber = ConvertTo-AzlReportedValue (Get-RfText $p 'serialNumber')
            }
        })
    if ($fromProcessor.Count -gt 0) { return $fromProcessor }
    return @(foreach ($g in @(Get-RfArray $Report 'gpus')) {
            [ordered]@{
                source = 'PCIeDevices'; model = ConvertTo-AzlReportedValue (Get-RfText $g 'model'); manufacturer = ConvertTo-AzlReportedValue (Get-RfText $g 'manufacturer')
                slot = ConvertTo-AzlReportedValue (Get-RfText $g 'slot'); memoryGiB = $script:NotReportedText; serialNumber = $script:NotReportedText
            }
        })
}

function Get-AzlHardwareTpm {
    param($Report)
    $modules = @(Get-RfArray (Get-RfProp $Report 'system') 'tpm')
    $items = @(foreach ($m in $modules) {
            $type = Get-RfText $m 'interfaceType'
            $version = switch ($type) { 'TPM2_0' { '2.0' } 'TPM1_2' { '1.2' } 'TCM1_0' { 'TCM 1.0' } default { $script:NotReportedText } }
            [ordered]@{
                version = $version; interfaceType = ConvertTo-AzlReportedValue $type; state = ConvertTo-AzlReportedValue (Get-RfText $m 'state')
                firmwareVersion = ConvertTo-AzlReportedValue (Get-RfText $m 'firmwareVersion'); source = ConvertTo-AzlReportedValue (Get-RfText $m 'source')
            }
        })
    $present = $script:NotReportedText
    if ($items.Count -gt 0) { $present = (@($items | Where-Object { $_.state -ne 'Absent' }).Count -gt 0) }
    return [ordered]@{ present = $present; modules = $items }
}

function ConvertTo-AzlHardwareInventoryNode {
    <#
    .SYNOPSIS
        The inventory entry of one node from the report of Invoke-AzlRedfishDiscovery (-Vendor None -Detail Inventory).
    .PARAMETER Report
        The report.
    .PARAMETER Name
        The node name in infrastructure.yml.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$Report, [Parameter(Mandatory)][string]$Name)
    $identity = Get-RfProp $Report 'identity'
    $bmc = Get-RfProp $Report 'bmc'
    $system = Get-RfProp $Report 'system'
    $vendor = Get-RfProp $Report 'vendor'
    $firmware = @(Get-RfArray $Report 'firmware')

    $cpus = @(Get-RfArray $Report 'processors' | Where-Object { (Get-RfText $_ 'processorType') -notin 'GPU', 'FPGA', 'DSP', 'Accelerator' })
    $summaryCpu = Get-RfProp $system 'processorSummary'
    $coreSum = if ($cpus.Count -gt 0 -and @($cpus | Where-Object { $null -ne (Get-RfProp $_ 'cores') }).Count -gt 0) { [int](@($cpus | ForEach-Object { Get-RfProp $_ 'cores' } | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum) } else { Get-RfProp $summaryCpu 'cores' }
    $threadSum = if ($cpus.Count -gt 0 -and @($cpus | Where-Object { $null -ne (Get-RfProp $_ 'threads') }).Count -gt 0) { [int](@($cpus | ForEach-Object { Get-RfProp $_ 'threads' } | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum) } else { Get-RfProp $summaryCpu 'threads' }
    $firstCpu = $cpus | Select-Object -First 1
    $cpu = [ordered]@{
        sockets = $(if ($cpus.Count -gt 0) { $cpus.Count } else { ConvertTo-AzlReportedValue (Get-RfProp $summaryCpu 'count') })
        model = ConvertTo-AzlReportedValue $(if ($firstCpu -and (Get-RfText $firstCpu 'model')) { Get-RfText $firstCpu 'model' } else { Get-RfText $summaryCpu 'model' })
        manufacturer = ConvertTo-AzlReportedValue (Get-RfText $firstCpu 'manufacturer')
        cores = ConvertTo-AzlReportedValue $coreSum; threads = ConvertTo-AzlReportedValue $threadSum
        maxSpeedMHz = ConvertTo-AzlReportedValue (Get-RfProp $firstCpu 'maxSpeedMHz')
        processors = @(foreach ($p in $cpus) {
                [ordered]@{ socket = ConvertTo-AzlReportedValue (Get-RfText $p 'socket'); model = ConvertTo-AzlReportedValue (Get-RfText $p 'model'); cores = ConvertTo-AzlReportedValue (Get-RfProp $p 'cores'); threads = ConvertTo-AzlReportedValue (Get-RfProp $p 'threads'); maxSpeedMHz = ConvertTo-AzlReportedValue (Get-RfProp $p 'maxSpeedMHz') }
            })
    }

    $memory = Get-RfProp $Report 'memory'
    $modules = @(Get-RfArray $memory 'modules' | Where-Object { (Get-RfProp $_ 'present') -ne $false })
    $eccValues = @($modules | ForEach-Object { Get-RfText $_ 'ecc' } | Where-Object { $_ })
    $eccState = if ($eccValues.Count -eq 0) { $script:NotReportedText } else { (@($eccValues | Where-Object { $_ -eq 'NoECC' }).Count -eq 0) }
    $memTotal = Get-RfProp $memory 'totalGiB'
    if ($null -eq $memTotal -and $modules.Count -gt 0 -and @($modules | Where-Object { $null -eq (Get-RfProp $_ 'capacityMiB') }).Count -eq 0) { $memTotal = [math]::Round((@($modules | ForEach-Object { [double](Get-RfProp $_ 'capacityMiB') } | Measure-Object -Sum).Sum) / 1024, 2) }
    $memoryEntry = [ordered]@{
        totalGiB = ConvertTo-AzlReportedValue $memTotal; moduleCount = $modules.Count; ecc = $eccState
        modules = @(foreach ($m in $modules) {
                [ordered]@{
                    slot = ConvertTo-AzlReportedValue (Get-RfText $m 'slot'); sizeGiB = $(if ($null -ne (Get-RfProp $m 'capacityMiB')) { [math]::Round(([double](Get-RfProp $m 'capacityMiB')) / 1024, 2) } else { $script:NotReportedText })
                    type = ConvertTo-AzlReportedValue (Get-RfText $m 'type'); speedMHz = ConvertTo-AzlReportedValue (Get-RfProp $m 'speedMHz'); ecc = ConvertTo-AzlReportedValue (Get-RfText $m 'ecc')
                    partNumber = ConvertTo-AzlReportedValue (Get-RfText $m 'partNumber')
                }
            })
    }

    $driveResult = Get-AzlHardwareDriveList -Storage (Get-RfProp $Report 'storage')

    $ports = [System.Collections.Generic.List[object]]::new()
    $order = 0
    foreach ($a in @(Get-RfArray (Get-RfProp $Report 'network') 'adapters')) {
        $sorted = @(Get-RfArray $a 'ports' | Sort-Object -Property { $n = Get-RfProp $_ 'portIndex'; if ($null -eq $n) { 0 } else { [int]$n } } -Stable)
        foreach ($p in $sorted) {
            $order++
            $ports.Add([ordered]@{
                    order = $order; adapter = ConvertTo-AzlReportedValue (Get-RfText $a 'id'); adapterLocation = ConvertTo-AzlReportedValue (Get-RfText $a 'location')
                    portNumber = ConvertTo-AzlReportedValue (Get-RfProp $p 'portIndex'); mac = ConvertTo-AzlReportedValue (Get-RfText $p 'mac')
                    manufacturer = ConvertTo-AzlReportedValue (Get-RfText $a 'manufacturer'); model = ConvertTo-AzlReportedValue (Get-RfText $a 'model')
                    firmware = ConvertTo-AzlReportedValue (Get-RfText $a 'firmwarePackage')
                    linkStatus = ConvertTo-AzlReportedValue (Get-RfText $p 'linkStatus'); speedMbps = ConvertTo-AzlReportedValue (Get-RfProp $p 'speedMbps'); maxSpeedMbps = ConvertTo-AzlReportedValue (Get-RfProp $p 'maxSpeedMbps')
                })
        }
    }

    $biosFromInventory = $firmware | Where-Object { (Get-RfText $_ 'category') -eq 'bios' } | Select-Object -First 1
    $biosVersion = Get-RfText $system 'biosVersion'
    if (-not $biosVersion) { $biosVersion = Get-RfText $identity 'biosVersion' }
    if (-not $biosVersion) { $biosVersion = Get-RfText $biosFromInventory 'version' }
    $bmcFromInventory = $firmware | Where-Object { (Get-RfText $_ 'category') -eq 'bmc' } | Select-Object -First 1
    $bmcVersion = Get-RfText $bmc 'firmwareVersion'
    if (-not $bmcVersion) { $bmcVersion = Get-RfText $bmcFromInventory 'version' }

    $secureBoot = Get-RfProp $system 'secureBoot'
    $secureBootState = if ($secureBoot -and (Get-RfProp $secureBoot 'supported') -eq $true) { Get-RfProp $secureBoot 'enabled' } else { $script:NotReportedText }

    $gpus = @(Get-AzlHardwareGpu -Report $Report)
    $node = [ordered]@{
        name = $Name
        bmcAddress = Get-RfText $Report 'bmcAddress'
        status = 'read'
        error = $null
        collectedAt = Get-RfText $Report 'collectedAt'
        vendor = [ordered]@{
            detected = ConvertTo-AzlReportedValue (Get-RfText $vendor 'name'); bmcFamily = ConvertTo-AzlReportedValue (Get-RfText $vendor 'family')
            confidence = ConvertTo-AzlReportedValue (Get-RfText $vendor 'confidence'); evidence = @(Get-RfArray $vendor 'evidence')
        }
        identity = [ordered]@{
            manufacturer = ConvertTo-AzlReportedValue (Get-RfText $identity 'manufacturer'); model = ConvertTo-AzlReportedValue (Get-RfText $identity 'model')
            serialNumber = ConvertTo-AzlReportedValue (Get-RfText $identity 'serialNumber'); sku = ConvertTo-AzlReportedValue (Get-RfText $identity 'skuOrPartNumber')
            chassisSerialNumber = ConvertTo-AzlReportedValue (Get-RfText (Get-RfProp $identity 'chassis') 'serialNumber')
            uuid = ConvertTo-AzlReportedValue (Get-RfText $identity 'uuid'); assetTag = ConvertTo-AzlReportedValue (Get-RfText $identity 'assetTag')
        }
        cpu = $cpu
        memory = $memoryEntry
        drives = $driveResult.Drives
        driveSummary = $driveResult.Summary
        network = [ordered]@{ portCount = $ports.Count; ports = $ports.ToArray() }
        gpu = [ordered]@{ count = $gpus.Count; devices = $gpus }
        tpm = Get-AzlHardwareTpm -Report $Report
        secureBoot = $secureBootState
        bios = [ordered]@{ version = ConvertTo-AzlReportedValue $biosVersion }
        bmc = [ordered]@{
            model = ConvertTo-AzlReportedValue (Get-RfText $bmc 'model'); firmwareVersion = ConvertTo-AzlReportedValue $bmcVersion
            mac = ConvertTo-AzlReportedValue (Get-RfText $bmc 'mac')
        }
        firmware = @(foreach ($f in $firmware) {
                [ordered]@{ component = ConvertTo-AzlReportedValue (Get-RfText $f 'component'); version = ConvertTo-AzlReportedValue (Get-RfText $f 'version'); category = ConvertTo-AzlReportedValue (Get-RfText $f 'category'); updateable = $(if ($null -ne (Get-RfProp $f 'updateable')) { Get-RfProp $f 'updateable' } else { $script:NotReportedText }) }
            })
        readErrors = @(Get-RfArray $Report 'readErrors' | ForEach-Object { [ordered]@{ area = $_['area']; path = $_['path']; status = $_['status']; kind = $_['kind'] } })
        warnings = @(Get-RfArray $Report 'warnings')
    }
    $node['notReported'] = @(Get-AzlNotReportedPath -InputObject $node)
    return $node
}

function Get-AzlNotReportedPath {
    <#
    .SYNOPSIS
        The paths of every field that holds "not reported", for example cpu.maxSpeedMHz or drives[0].blockSizeBytes.
    #>
    [CmdletBinding()]
    param($InputObject, [string]$Prefix = '', [int]$Depth = 0)
    if ($Depth -gt 8 -or $null -eq $InputObject) { return }
    if ($InputObject -is [string]) { if ($InputObject -eq $script:NotReportedText) { $Prefix }; return }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($k in @($InputObject.Keys)) {
            if ($k -in 'notReported', 'readErrors', 'warnings', 'evidence') { continue }
            Get-AzlNotReportedPath -InputObject $InputObject[$k] -Prefix $(if ($Prefix) { "$Prefix.$k" } else { [string]$k }) -Depth ($Depth + 1)
        }
        return
    }
    if ($InputObject -is [pscustomobject]) {
        foreach ($p in $InputObject.PSObject.Properties) { Get-AzlNotReportedPath -InputObject $p.Value -Prefix $(if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }) -Depth ($Depth + 1) }
        return
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($item in $InputObject) { Get-AzlNotReportedPath -InputObject $item -Prefix "$Prefix[$i]" -Depth ($Depth + 1); $i++ }
    }
}

function Get-AzlHardwareSymmetry {
    <#
    .SYNOPSIS
        The checks across nodes: is each fact the same on every machine? Report only.
    .DESCRIPTION
        The requirements come from Microsoft Learn: Azure Local system requirements (each machine the same model and manufacturer, the
        same processor types, the same network adapters, and the same number, type, capacity and firmware of drives) and Drive symmetry
        considerations for Storage Spaces Direct (the same model of drive is recommended). Result per check: same, differs, or
        not reported (a node did not give the fact). Fewer than two nodes read: no checks.
    .PARAMETER Node
        The inventory entries (status read).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()][object[]]$Node)
    $nodes = @($Node | Where-Object { $_.status -eq 'read' })
    if ($nodes.Count -lt 2) { return @() }
    $nr = $script:NotReportedText
    $join = { param($items) (@($items) | ForEach-Object { [string]$_ } | Sort-Object) -join ' | ' }
    $checks = @(
        @{ Check = 'manufacturer'; Requirement = 'required'; Source = 'Azure Local system requirements: same manufacturer'; Value = { param($n) "$($n.identity.manufacturer)" } }
        @{ Check = 'model'; Requirement = 'required'; Source = 'Azure Local system requirements: same model'; Value = { param($n) "$($n.identity.model)" } }
        @{ Check = 'processor'; Requirement = 'required'; Source = 'Azure Local system requirements: same processor types'; Value = { param($n) "$($n.cpu.manufacturer) / $($n.cpu.model) / $($n.cpu.maxSpeedMHz) MHz / sockets $($n.cpu.sockets) / cores $($n.cpu.cores) / threads $($n.cpu.threads)" } }
        @{ Check = 'memoryGiB'; Requirement = 'information'; Source = 'Not stated by Microsoft'; Value = { param($n) "$($n.memory.totalGiB)" } }
        @{ Check = 'networkAdapters'; Requirement = 'required'; Source = 'Azure Local system requirements: same network adapters'; Value = { param($n) & $join @($n.network.ports | ForEach-Object { "$($_.manufacturer) $($_.model)" }) } }
        @{ Check = 'driveTypeAndCount'; Requirement = 'required'; Source = 'Azure Local system requirements and Drive symmetry considerations: same types, same number of each type'; Value = { param($n) & $join @($n.driveSummary.byMedia | ForEach-Object { "$($_.mediaType) x$($_.count)" }) } }
        @{ Check = 'driveRoles'; Requirement = 'required'; Source = 'Drive symmetry considerations: same number of cache and capacity drives'; Value = { param($n) "cache $($n.driveSummary.cacheCount) / capacity $($n.driveSummary.capacityCount)" } }
        @{ Check = 'driveCapacity'; Requirement = 'required'; Source = 'Azure Local system requirements: same capacity of drives'; Value = { param($n) & $join @($n.drives | Where-Object { $_.role -in 'cache', 'capacity' } | ForEach-Object { "$($_.role) $($_.sizeTB) TB" }) } }
        @{ Check = 'driveFirmware'; Requirement = 'required'; Source = 'Azure Local system requirements: same firmware of drives at deployment'; Value = { param($n) & $join @($n.drives | Where-Object { $_.role -in 'cache', 'capacity' } | ForEach-Object { "$($_.model) $($_.firmware)" }) } }
        @{ Check = 'driveModel'; Requirement = 'recommended'; Source = 'Drive symmetry considerations: same drive models are recommended'; Value = { param($n) & $join @($n.drives | Where-Object { $_.role -in 'cache', 'capacity' } | ForEach-Object { "$($_.model)" }) } }
        @{ Check = 'biosVersion'; Requirement = 'information'; Source = 'Not stated by Microsoft; the OEM firmware matrix decides'; Value = { param($n) "$($n.bios.version)" } }
        @{ Check = 'bmcFirmware'; Requirement = 'information'; Source = 'Not stated by Microsoft; the OEM firmware matrix decides'; Value = { param($n) "$($n.bmc.firmwareVersion)" } }
    )
    return @(foreach ($c in $checks) {
            $values = [ordered]@{}
            foreach ($n in $nodes) { $values[[string]$n.name] = [string](& $c.Value $n) }
            $distinct = @($values.Values | Select-Object -Unique)
            $result = if (@($values.Values | Where-Object { $_ -match [regex]::Escape($nr) -or $_.Trim().Length -eq 0 }).Count -gt 0) { 'not reported' } elseif ($distinct.Count -eq 1) { 'same' } else { 'differs' }
            [ordered]@{ check = $c.Check; requirement = $c.Requirement; source = $c.Source; result = $result; values = $values }
        })
}

function Test-AzlTextRelated {
    # Two names for the same thing: one contains the other, ignoring case ("Dell" and "Dell Inc.").
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $x = $A.Trim().ToLowerInvariant(); $y = $B.Trim().ToLowerInvariant()
    return ($x.Contains($y) -or $y.Contains($x))
}

function Compare-AzlHardwarePlan {
    <#
    .SYNOPSIS
        What infrastructure.yml says about the hardware, against what the BMC reported. One row per key that has a value. Report only.
    .PARAMETER Node
        One inventory entry (status read).
    .PARAMETER Infrastructure
        The loaded infrastructure file.
    .PARAMETER NodeEntry
        The nodes[] entry of this node (for nodes[].bmc.type and nodes[].serial_number).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Infrastructure is read inside the scriptblocks of this function, which the analyzer does not follow.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$Node, [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [System.Collections.IDictionary]$NodeEntry)
    $rows = [System.Collections.Generic.List[object]]::new()
    $nr = $script:NotReportedText
    $row = {
        param([string]$Key, $Planned, $Found, [string]$Result, [string]$Note)
        $rows.Add([ordered]@{ node = $Node.name; key = $Key; planned = $Planned; found = $Found; result = $Result; note = $Note })
    }
    $planned = { param([string]$Path) $v = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path $Path; if ($null -ne $v -and "$v".Trim().Length -gt 0) { $v } else { $null } }
    $judge = { param($plannedValue, $foundValue, [scriptblock]$Equal)
        if ("$foundValue" -eq $nr -or $null -eq $foundValue) { return 'not reported' }
        if (& $Equal $plannedValue $foundValue) { return 'match' }
        return 'differs'
    }

    $p = & $planned 'hardware.vendor'
    if ($null -ne $p) { & $row 'hardware.vendor' $p $Node.identity.manufacturer (& $judge $p $Node.identity.manufacturer { param($a, $b) Test-AzlTextRelated "$a" "$b" }) '' }
    $p = & $planned 'hardware.model'
    if ($null -ne $p) { & $row 'hardware.model' $p $Node.identity.model (& $judge $p $Node.identity.model { param($a, $b) Test-AzlTextRelated "$a" "$b" }) '' }
    $p = & $planned 'hardware.cpu_cores'
    if ($null -ne $p) { & $row 'hardware.cpu_cores' $p $Node.cpu.cores (& $judge $p $Node.cpu.cores { param($a, $b) [int]$a -eq [int]$b }) 'Physical cores of all processors.' }
    $p = & $planned 'hardware.memory_gib'
    if ($null -ne $p) { & $row 'hardware.memory_gib' $p $Node.memory.totalGiB (& $judge $p $Node.memory.totalGiB { param($a, $b) [math]::Round([double]$a) -eq [math]::Round([double]$b) }) '' }

    $gpuEnabled = & $planned 'hardware.gpu.enabled'
    $gpuCount = & $planned 'hardware.gpu.count_per_node'
    $gpuModel = & $planned 'hardware.gpu.model'
    $foundGpu = [int]$Node.gpu.count
    if ($null -ne $gpuEnabled) { & $row 'hardware.gpu.enabled' $gpuEnabled ($foundGpu -gt 0) $(if ([bool]$gpuEnabled -eq ($foundGpu -gt 0)) { 'match' } else { 'differs' }) '' }
    if ($null -ne $gpuCount) { & $row 'hardware.gpu.count_per_node' $gpuCount $foundGpu $(if ([int]$gpuCount -eq $foundGpu) { 'match' } else { 'differs' }) '' }
    if ($null -ne $gpuModel) {
        $models = @($Node.gpu.devices | ForEach-Object { $_.model } | Where-Object { $_ -and $_ -ne $nr })
        $res = if ($models.Count -eq 0) { 'not reported' } elseif (@($models | Where-Object { Test-AzlTextRelated "$gpuModel" "$_" }).Count -eq $models.Count) { 'match' } else { 'differs' }
        & $row 'hardware.gpu.model' $gpuModel (($models | Select-Object -Unique) -join ', ') $res ''
    }

    foreach ($group in @(@{ Name = 'capacity'; Role = 'capacity' }, @{ Name = 'cache'; Role = 'cache' })) {
        $found = @($Node.drives | Where-Object { $_.role -eq $group.Role })
        $pm = & $planned "hardware.drives.$($group.Name).media"
        if ($null -ne $pm) {
            $fm = (@($found | ForEach-Object { $_.mediaType } | Select-Object -Unique) -join ', ')
            & $row "hardware.drives.$($group.Name).media" $pm $fm $(if (-not $fm) { 'differs' } elseif ($fm -eq $nr) { 'not reported' } elseif ($fm -ieq "$pm") { 'match' } else { 'differs' }) "Found: the drives with role $($group.Role)."
        }
        $pc = & $planned "hardware.drives.$($group.Name).count"
        if ($null -ne $pc) { & $row "hardware.drives.$($group.Name).count" $pc $found.Count $(if ([int]$pc -eq $found.Count) { 'match' } else { 'differs' }) "Found: the drives with role $($group.Role)." }
        $ps = & $planned "hardware.drives.$($group.Name).size_tb"
        if ($null -ne $ps) {
            $sizes = @($found | ForEach-Object { $_.sizeTB } | Select-Object -Unique)
            $res = if ($sizes.Count -eq 0) { 'differs' } elseif (@($sizes | Where-Object { $_ -eq $nr }).Count -gt 0) { 'not reported' } elseif (@($sizes | Where-Object { [math]::Abs([double]$_ - [double]$ps) / [double]$ps -gt 0.05 }).Count -eq 0) { 'match' } else { 'differs' }
            & $row "hardware.drives.$($group.Name).size_tb" $ps ($sizes -join ', ') $res 'Match means within 5 percent.'
        }
    }

    if ($NodeEntry) {
        $bmc = $NodeEntry['bmc']
        $type = if ($bmc -is [System.Collections.IDictionary] -and $bmc.Contains('type')) { [string]$bmc['type'] } else { $null }
        if ($type -and $type -ne 'other') {
            $expected = switch ($type) { 'idrac' { 'Dell' } 'ilo' { 'Hpe' } 'xcc' { 'Lenovo' } default { $null } }
            if ($expected) { & $row 'nodes[].bmc.type' $type $Node.vendor.detected $(if ($Node.vendor.detected -eq $nr) { 'not reported' } elseif ($Node.vendor.detected -ieq $expected) { 'match' } else { 'differs' }) "Detected from the Redfish service root, system and manager." }
        }
        if ($NodeEntry.Contains('serial_number') -and "$($NodeEntry['serial_number'])".Trim().Length -gt 0) {
            $serialPlanned = ([string]$NodeEntry['serial_number']).Trim()
            $candidates = @($Node.identity.serialNumber, $Node.identity.sku, $Node.identity.chassisSerialNumber) | Where-Object { $_ -and $_ -ne $nr }
            $res = if ($candidates.Count -eq 0) { 'not reported' } elseif (@($candidates | Where-Object { $_ -ieq $serialPlanned }).Count -gt 0) { 'match' } else { 'differs' }
            & $row 'nodes[].serial_number' $serialPlanned ($candidates -join ', ') $res 'Found: the system serial number, the SKU and the chassis serial number. Which one a vendor calls the service tag is not in the standard.'
        }
    }
    return $rows.ToArray()
}

Export-ModuleMember -Function Get-AzlHardwareInventoryRule, Get-AzlDriveMedia, Get-AzlHardwareDriveList, ConvertTo-AzlHardwareInventoryNode, Get-AzlNotReportedPath, Get-AzlHardwareSymmetry, Compare-AzlHardwarePlan
