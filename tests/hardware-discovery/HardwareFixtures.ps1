#Requires -Version 7.0
# Test helper (dot-sourced by the hardware inventory tests): synthetic Redfish trees for three differently shaped BMCs, and a fake
# Invoke-WebRequest answer. Everything here is made up: neutral serial numbers (TESTSN-...), MAC addresses from the documentation
# range 00:00:5E:00:53:xx, documentation addresses (192.0.2.x). Nothing is copied from a real system. Nothing touches a network.
#
#   Get-DellShapeTree   iDRAC-like. Systems/System.Embedded.1. NetworkPorts (older schema), MAC on the port. Storage controllers
#                       listed inline, a RAID1 boot volume (BOSS-like) with two SATA SSD, four NVMe, six SAS HDD behind a
#                       pass-through controller (NVMe + HDD: NVMe is cache). TrustedModules TPM2_0. Secure Boot on.
#   Get-HpeShapeTree    iLO-like. Systems/1. Ports (newer schema) with Controllers[] inside the adapter, MAC on the network device
#                       function. Storage Controllers link. Eight NVMe only (no cache tier). A GPU as a Processor of type GPU
#                       with ProcessorMemory. TrustedModules TPM2_0.
#   Get-AmiShapeTree    AMI/ODM-like (DataON and others). Systems/Self. NetworkAdapters under the Chassis, not the System. Two SATA
#                       SSD and six HDD with no BlockSizeBytes. No TPM resource, no ECC property, no firmware inventory (404).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks run in module scope and read the fake BMCs through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers that edit an in-memory fixture.')]
param()

Set-StrictMode -Version Latest

function New-RfLink([string]$Path) { return @{ '@odata.id' = $Path } }

function Set-RfResource {
    param([hashtable]$Tree, [string]$Path, [hashtable]$Body)
    $Tree[$Path] = $Body
}

function Set-RfCollection {
    # A collection at Path whose members are the given paths (each member body is set separately).
    param([hashtable]$Tree, [string]$Path, [string[]]$Member)
    $Tree[$Path] = @{ Name = 'Collection'; 'Members@odata.count' = $Member.Count; Members = @($Member | ForEach-Object { New-RfLink $_ }) }
}

function Add-RfDrive {
    param([hashtable]$Tree, [string]$Path, [string]$Id, [string]$Model, [string]$Serial, [string]$Revision, [double]$Bytes, [string]$Media, [string]$Protocol, [string]$Bay, [int]$Block = 0, [string]$State = 'Enabled')
    $body = @{ Id = $Id; Name = $Id; Model = $Model; SerialNumber = $Serial; Revision = $Revision; CapacityBytes = $Bytes; MediaType = $Media; Protocol = $Protocol; Status = @{ State = $State; Health = 'OK' }
        PhysicalLocation = @{ PartLocation = @{ ServiceLabel = $Bay; LocationOrdinalValue = 0 } } }
    if ($Block -gt 0) { $body.BlockSizeBytes = $Block }
    $Tree[$Path] = $body
}

function Add-RfCpu {
    param([hashtable]$Tree, [string]$Base, [int]$Count, [string]$Model, [string]$Maker, [int]$Cores, [int]$Threads)
    $paths = 1..$Count | ForEach-Object { "$Base/CPU.$_" }
    Set-RfCollection $Tree $Base $paths
    for ($i = 1; $i -le $Count; $i++) {
        $Tree["$Base/CPU.$i"] = @{ Id = "CPU.$i"; Name = "CPU $i"; Socket = "CPU.Socket.$i"; ProcessorType = 'CPU'; Model = $Model; Manufacturer = $Maker; TotalCores = $Cores; TotalThreads = $Threads; MaxSpeedMHz = 4000; Status = @{ State = 'Enabled'; Health = 'OK' } }
    }
}

function Add-RfMemory {
    param([hashtable]$Tree, [string]$Base, [int]$Count, [int]$MiB, [string]$Ecc)
    $paths = 1..($Count + 1) | ForEach-Object { "$Base/DIMM.$_" }
    Set-RfCollection $Tree $Base $paths
    for ($i = 1; $i -le $Count; $i++) {
        $m = @{ Id = "DIMM.$i"; Name = "DIMM $i"; DeviceLocator = "DIMM.A$i"; CapacityMiB = $MiB; MemoryDeviceType = 'DDR5'; OperatingSpeedMhz = 4800; Manufacturer = 'Test Memory Co'; PartNumber = "TESTMEM-$MiB"; Status = @{ State = 'Enabled'; Health = 'OK' } }
        if ($Ecc) { $m.ErrorCorrection = $Ecc }
        $Tree["$Base/DIMM.$i"] = $m
    }
    $Tree["$Base/DIMM.$($Count + 1)"] = @{ Id = "DIMM.$($Count + 1)"; Name = 'empty slot'; DeviceLocator = "DIMM.A$($Count + 1)"; Status = @{ State = 'Absent' } }
}

function Get-DellShapeTree {
    param([string]$Serial = 'TESTSN-D-0001', [string]$Sku = 'TESTSKU1', [string]$Mac = '00:00:5E:00:53:10')
    $t = @{}
    $sys = '/redfish/v1/Systems/System.Embedded.1'
    $chs = '/redfish/v1/Chassis/System.Embedded.1'
    $mgr = '/redfish/v1/Managers/iDRAC.Embedded.1'
    Set-RfResource $t '/redfish/v1' @{ Product = 'Integrated Remote Access Controller'; Vendor = 'Dell'; Systems = (New-RfLink '/redfish/v1/Systems'); Chassis = (New-RfLink '/redfish/v1/Chassis'); Managers = (New-RfLink '/redfish/v1/Managers'); UpdateService = (New-RfLink '/redfish/v1/UpdateService'); Oem = @{ Dell = @{} } }
    Set-RfCollection $t '/redfish/v1/Systems' @($sys)
    Set-RfResource $t $sys @{
        Id = 'System.Embedded.1'; Manufacturer = 'Dell Inc.'; Model = 'Test Model D1'; SKU = $Sku; SerialNumber = $Serial; UUID = '00000000-0000-4000-8000-0000000000d1'; BiosVersion = '9.9.9'; PowerState = 'On'
        ProcessorSummary = @{ Count = 2; Model = 'Test CPU 100'; CoreCount = 64; LogicalProcessorCount = 128 }; MemorySummary = @{ TotalSystemMemoryGiB = 256 }
        Processors = (New-RfLink "$sys/Processors"); Memory = (New-RfLink "$sys/Memory"); Storage = (New-RfLink "$sys/Storage"); NetworkAdapters = (New-RfLink "$sys/NetworkAdapters"); SecureBoot = (New-RfLink "$sys/SecureBoot")
        TrustedModules = @(@{ InterfaceType = 'TPM2_0'; FirmwareVersion = '7.2.3.1'; Status = @{ State = 'Enabled' } })
        Links = @{ Chassis = @(New-RfLink $chs); ManagedBy = @(New-RfLink $mgr) }; Oem = @{ Dell = @{} }
    }
    Set-RfResource $t "$sys/SecureBoot" @{ SecureBootEnable = $true; SecureBootCurrentBoot = 'Enabled'; SecureBootMode = 'DeployedMode' }
    Set-RfCollection $t '/redfish/v1/Chassis' @($chs)
    Set-RfResource $t $chs @{ Id = 'System.Embedded.1'; Model = 'Test Chassis D1'; SerialNumber = 'TESTCH-D-0001'; ChassisType = 'RackMount' }
    Set-RfCollection $t '/redfish/v1/Managers' @($mgr)
    Set-RfResource $t $mgr @{ Id = 'iDRAC.Embedded.1'; Name = 'Manager'; Model = '16G Monolithic'; FirmwareVersion = '7.10.50.00'; ManagerType = 'BMC'; EthernetInterfaces = (New-RfLink "$mgr/EthernetInterfaces"); Oem = @{ Dell = @{} } }
    Set-RfCollection $t "$mgr/EthernetInterfaces" @("$mgr/EthernetInterfaces/NIC.1")
    Set-RfResource $t "$mgr/EthernetInterfaces/NIC.1" @{ Id = 'NIC.1'; MACAddress = '00:00:5E:00:53:01'; SpeedMbps = 1000 }
    Add-RfCpu $t "$sys/Processors" 2 'Test CPU 100' 'Test Silicon' 32 64
    Add-RfMemory $t "$sys/Memory" 4 65536 'MultiBitECC'

    # network: a LOM with two ports and a slot card with two ports; older schema (NetworkPorts)
    $a = "$sys/NetworkAdapters"
    Set-RfCollection $t $a @("$a/NIC.Embedded.1", "$a/NIC.Slot.3")
    Set-RfResource $t "$a/NIC.Embedded.1" @{ Id = 'NIC.Embedded.1'; Name = 'Network Adapter'; Manufacturer = 'Test NIC Co'; Model = 'Test LOM 1G'; NetworkPorts = (New-RfLink "$a/NIC.Embedded.1/NetworkPorts") }
    Set-RfCollection $t "$a/NIC.Embedded.1/NetworkPorts" @("$a/NIC.Embedded.1/NetworkPorts/NIC.Embedded.1-1-1", "$a/NIC.Embedded.1/NetworkPorts/NIC.Embedded.2-1-1")
    Set-RfResource $t "$a/NIC.Embedded.1/NetworkPorts/NIC.Embedded.1-1-1" @{ Id = 'NIC.Embedded.1-1-1'; PhysicalPortNumber = '1'; LinkStatus = 'Up'; CurrentLinkSpeedMbps = 1000; AssociatedNetworkAddresses = @($Mac) }
    Set-RfResource $t "$a/NIC.Embedded.1/NetworkPorts/NIC.Embedded.2-1-1" @{ Id = 'NIC.Embedded.2-1-1'; PhysicalPortNumber = '2'; LinkStatus = 'Down'; CurrentLinkSpeedMbps = 0; AssociatedNetworkAddresses = @('00:00:5E:00:53:11') }
    Set-RfResource $t "$a/NIC.Slot.3" @{ Id = 'NIC.Slot.3'; Name = 'Network Adapter'; Manufacturer = 'Test NIC Co'; Model = 'Test 25G Card'; NetworkPorts = (New-RfLink "$a/NIC.Slot.3/NetworkPorts")
        Controllers = @(@{ FirmwarePackageVersion = '22.31.6'; Location = @{ PartLocation = @{ ServiceLabel = 'Slot 3' } } }) }
    Set-RfCollection $t "$a/NIC.Slot.3/NetworkPorts" @("$a/NIC.Slot.3/NetworkPorts/NIC.Slot.3-2", "$a/NIC.Slot.3/NetworkPorts/NIC.Slot.3-1")
    Set-RfResource $t "$a/NIC.Slot.3/NetworkPorts/NIC.Slot.3-1" @{ Id = 'NIC.Slot.3-1'; PhysicalPortNumber = '1'; LinkStatus = 'Up'; CurrentLinkSpeedMbps = 25000; AssociatedNetworkAddresses = @('00:00:5E:00:53:21') }
    Set-RfResource $t "$a/NIC.Slot.3/NetworkPorts/NIC.Slot.3-2" @{ Id = 'NIC.Slot.3-2'; PhysicalPortNumber = '2'; LinkStatus = 'Up'; CurrentLinkSpeedMbps = 25000; AssociatedNetworkAddresses = @('00:00:5E:00:53:22') }

    # storage: BOSS-like RAID1 boot volume, a pass-through controller with NVMe and one with HDD
    $s = "$sys/Storage"
    Set-RfCollection $t $s @("$s/BOSS.1", "$s/NVME.1", "$s/HBA.1")
    Set-RfResource $t "$s/BOSS.1" @{ Id = 'BOSS.1'; Name = 'Test boot card'; StorageControllers = @(@{ Model = 'Test boot card'; Manufacturer = 'Test Storage Co'; FirmwareVersion = '2.5' }); Drives = @((New-RfLink '/redfish/v1/Drives/M2.0'), (New-RfLink '/redfish/v1/Drives/M2.1')); Volumes = (New-RfLink "$s/BOSS.1/Volumes") }
    Set-RfCollection $t "$s/BOSS.1/Volumes" @("$s/BOSS.1/Volumes/Virtual.0")
    Set-RfResource $t "$s/BOSS.1/Volumes/Virtual.0" @{ Id = 'Virtual.0'; Name = 'boot mirror'; RAIDType = 'RAID1'; VolumeType = 'Mirrored'; CapacityBytes = 480000000000; Links = @{ Drives = @((New-RfLink '/redfish/v1/Drives/M2.0'), (New-RfLink '/redfish/v1/Drives/M2.1')) } }
    Add-RfDrive $t '/redfish/v1/Drives/M2.0' 'M2.0' 'TEST-M2-480' 'TESTDRV-M20' 'FW1' 480000000000 'SSD' 'SATA' 'Boot 0' 512
    Add-RfDrive $t '/redfish/v1/Drives/M2.1' 'M2.1' 'TEST-M2-480' 'TESTDRV-M21' 'FW1' 480000000000 'SSD' 'SATA' 'Boot 1' 512
    Set-RfResource $t "$s/NVME.1" @{ Id = 'NVME.1'; Name = 'NVMe'; StorageControllers = @(@{ Model = 'PCIe SSD backplane'; Manufacturer = 'Test Storage Co' }); Drives = @(0..3 | ForEach-Object { New-RfLink "/redfish/v1/Drives/NVMe.$_" }) }
    0..3 | ForEach-Object { Add-RfDrive $t "/redfish/v1/Drives/NVMe.$_" "NVMe.$_" 'TEST-NVME-1600' "TESTDRV-N$_" 'NF1' 1600000000000 'SSD' 'NVMe' "Bay $_" 4096 }
    Set-RfResource $t "$s/HBA.1" @{ Id = 'HBA.1'; Name = 'Test pass-through HBA'; StorageControllers = @(@{ Model = 'Test HBA'; Manufacturer = 'Test Storage Co'; FirmwareVersion = '16.0' }); Drives = @(0..5 | ForEach-Object { New-RfLink "/redfish/v1/Drives/HDD.$_" }) }
    0..5 | ForEach-Object { Add-RfDrive $t "/redfish/v1/Drives/HDD.$_" "HDD.$_" 'TEST-HDD-8000' "TESTDRV-H$_" 'HF1' 8000000000000 'HDD' 'SAS' "Bay $($_ + 4)" 4096 }

    Set-RfResource $t '/redfish/v1/UpdateService' @{ FirmwareInventory = (New-RfLink '/redfish/v1/UpdateService/FirmwareInventory') }
    Set-RfCollection $t '/redfish/v1/UpdateService/FirmwareInventory' @('/redfish/v1/UpdateService/FirmwareInventory/Installed-1', '/redfish/v1/UpdateService/FirmwareInventory/Installed-2', '/redfish/v1/UpdateService/FirmwareInventory/Installed-3')
    Set-RfResource $t '/redfish/v1/UpdateService/FirmwareInventory/Installed-1' @{ Id = 'Installed-1'; Name = 'BIOS'; Version = '9.9.9'; Updateable = $true }
    Set-RfResource $t '/redfish/v1/UpdateService/FirmwareInventory/Installed-2' @{ Id = 'Installed-2'; Name = 'Integrated Remote Access Controller'; Version = '7.10.50.00'; Updateable = $true }
    Set-RfResource $t '/redfish/v1/UpdateService/FirmwareInventory/Installed-3' @{ Id = 'Installed-3'; Name = 'Test 25G Card'; Version = '22.31.6'; Updateable = $true }
    return $t
}

function Get-HpeShapeTree {
    param([string]$Serial = 'TESTSN-H-0001', [string]$Mac = '00:00:5E:00:53:30')
    $t = @{}
    $sys = '/redfish/v1/Systems/1'
    $chs = '/redfish/v1/Chassis/1'
    $mgr = '/redfish/v1/Managers/1'
    Set-RfResource $t '/redfish/v1' @{ Product = 'Test BMC'; Vendor = 'HPE'; Systems = (New-RfLink '/redfish/v1/Systems'); Chassis = (New-RfLink '/redfish/v1/Chassis'); Managers = (New-RfLink '/redfish/v1/Managers'); UpdateService = (New-RfLink '/redfish/v1/UpdateService'); Oem = @{ Hpe = @{} } }
    Set-RfCollection $t '/redfish/v1/Systems' @($sys)
    Set-RfResource $t $sys @{
        Id = '1'; Manufacturer = 'HPE'; Model = 'Test Model H1'; SKU = 'TESTSKU-H1'; SerialNumber = $Serial; UUID = '00000000-0000-4000-8000-0000000000b1'; BiosVersion = 'T99 v9.99 (01/01/2030)'; PowerState = 'On'
        ProcessorSummary = @{ Count = 2; Model = 'Test CPU 200'; CoreCount = 48; LogicalProcessorCount = 96 }; MemorySummary = @{ TotalSystemMemoryGiB = 512 }
        Processors = (New-RfLink "$sys/Processors"); Memory = (New-RfLink "$sys/Memory"); Storage = (New-RfLink "$sys/Storage"); NetworkAdapters = (New-RfLink "$chs/NetworkAdapters")
        TrustedModules = @(@{ InterfaceType = 'TPM2_0'; FirmwareVersion = '1.2.3.4'; Status = @{ State = 'Enabled' } })
        Links = @{ Chassis = @(New-RfLink $chs); ManagedBy = @(New-RfLink $mgr) }; Oem = @{ Hpe = @{} }
    }
    Set-RfCollection $t '/redfish/v1/Chassis' @($chs)
    Set-RfResource $t $chs @{ Id = '1'; Model = 'Test Chassis H1'; SerialNumber = 'TESTCH-H-0001'; ChassisType = 'RackMount'; NetworkAdapters = (New-RfLink "$chs/NetworkAdapters") }
    Set-RfCollection $t '/redfish/v1/Managers' @($mgr)
    Set-RfResource $t $mgr @{ Id = '1'; Name = 'Manager'; Model = 'Test BMC 6'; FirmwareVersion = 'Test BMC 6 v1.60'; ManagerType = 'BMC'; EthernetInterfaces = (New-RfLink "$mgr/EthernetInterfaces"); Oem = @{ Hpe = @{} } }
    Set-RfCollection $t "$mgr/EthernetInterfaces" @("$mgr/EthernetInterfaces/1")
    Set-RfResource $t "$mgr/EthernetInterfaces/1" @{ Id = '1'; MACAddress = '00:00:5E:00:53:31'; SpeedMbps = 1000 }
    Add-RfCpu $t "$sys/Processors" 2 'Test CPU 200' 'Test Silicon' 24 48
    $t["$sys/Processors"].Members += (New-RfLink "$sys/Processors/GPU.1")
    $t["$sys/Processors"]['Members@odata.count'] = 3
    Set-RfResource $t "$sys/Processors/GPU.1" @{ Id = 'GPU.1'; Name = 'GPU 1'; Socket = 'Slot 2'; ProcessorType = 'GPU'; Model = 'Test GPU 24G'; Manufacturer = 'Test GPU Co'; ProcessorMemory = @(@{ CapacityMiB = 24576 }); Status = @{ State = 'Enabled' } }
    Add-RfMemory $t "$sys/Memory" 8 65536 'MultiBitECC'

    # network: the adapters are under the Chassis, ports use the newer Ports resource, the MAC is on the network device function
    $a = "$chs/NetworkAdapters"
    Set-RfCollection $t $a @("$a/Slot1")
    Set-RfResource $t "$a/Slot1" @{ Id = 'Slot1'; Name = 'Test dual-port 25G adapter'; Manufacturer = 'Test NIC Co'; Model = 'Test 25G Dual'; PartNumber = 'TESTNIC-25'
        Controllers = @(@{ FirmwarePackageVersion = '14.32.1010'; Location = @{ PartLocation = @{ ServiceLabel = 'Slot 1' } }; Links = @{ Ports = @((New-RfLink "$a/Slot1/Ports/1"), (New-RfLink "$a/Slot1/Ports/2")) } })
        Ports = (New-RfLink "$a/Slot1/Ports"); NetworkDeviceFunctions = (New-RfLink "$a/Slot1/NetworkDeviceFunctions") }
    Set-RfCollection $t "$a/Slot1/Ports" @("$a/Slot1/Ports/1", "$a/Slot1/Ports/2")
    Set-RfResource $t "$a/Slot1/Ports/1" @{ Id = '1'; PortId = '1'; PhysicalPortNumber = '1'; LinkStatus = 'LinkUp'; CurrentSpeedGbps = 25; MaxSpeedGbps = 25 }
    Set-RfResource $t "$a/Slot1/Ports/2" @{ Id = '2'; PortId = '2'; PhysicalPortNumber = '2'; LinkStatus = 'LinkDown'; CurrentSpeedGbps = 0; MaxSpeedGbps = 25 }
    Set-RfCollection $t "$a/Slot1/NetworkDeviceFunctions" @("$a/Slot1/NetworkDeviceFunctions/1", "$a/Slot1/NetworkDeviceFunctions/2")
    Set-RfResource $t "$a/Slot1/NetworkDeviceFunctions/1" @{ Id = '1'; Ethernet = @{ MACAddress = $Mac }; Links = @{ Ports = @(New-RfLink "$a/Slot1/Ports/1") } }
    Set-RfResource $t "$a/Slot1/NetworkDeviceFunctions/2" @{ Id = '2'; Ethernet = @{ MACAddress = '00:00:5E:00:53:32' }; Links = @{ Ports = @(New-RfLink "$a/Slot1/Ports/2") } }

    # storage: the controller is linked (Controllers), eight NVMe drives only
    $s = "$sys/Storage"
    Set-RfCollection $t $s @("$s/DE0001")
    Set-RfResource $t "$s/DE0001" @{ Id = 'DE0001'; Name = 'Test NVMe backplane'; Controllers = (New-RfLink "$s/DE0001/Controllers"); Drives = @(0..7 | ForEach-Object { New-RfLink "$s/DE0001/Drives/$_" }); Volumes = (New-RfLink "$s/DE0001/Volumes") }
    Set-RfCollection $t "$s/DE0001/Controllers" @("$s/DE0001/Controllers/0")
    Set-RfResource $t "$s/DE0001/Controllers/0" @{ Id = '0'; Model = 'Test NVMe backplane'; Manufacturer = 'Test Storage Co'; FirmwareVersion = '1.0' }
    Set-RfCollection $t "$s/DE0001/Volumes" @()
    0..7 | ForEach-Object { Add-RfDrive $t "$s/DE0001/Drives/$_" "$_" 'TEST-NVME-3200' "TESTDRV-HN$_" 'NF2' 3200000000000 'SSD' 'NVMe' "Box 1 Bay $($_ + 1)" 4096 }

    Set-RfResource $t '/redfish/v1/UpdateService' @{ FirmwareInventory = (New-RfLink '/redfish/v1/UpdateService/FirmwareInventory') }
    Set-RfCollection $t '/redfish/v1/UpdateService/FirmwareInventory' @('/redfish/v1/UpdateService/FirmwareInventory/bios', '/redfish/v1/UpdateService/FirmwareInventory/bmc')
    Set-RfResource $t '/redfish/v1/UpdateService/FirmwareInventory/bios' @{ Id = 'bios'; Name = 'System ROM'; Version = 'T99 v9.99'; Updateable = $true }
    Set-RfResource $t '/redfish/v1/UpdateService/FirmwareInventory/bmc' @{ Id = 'bmc'; Name = 'BMC firmware'; Version = '1.60'; Updateable = $true }
    return $t
}

function Get-AmiShapeTree {
    param([string]$Serial = 'TESTSN-A-0001')
    $t = @{}
    $sys = '/redfish/v1/Systems/Self'
    $chs = '/redfish/v1/Chassis/Self'
    $mgr = '/redfish/v1/Managers/Self'
    Set-RfResource $t '/redfish/v1' @{ Product = 'Test ODM BMC'; Systems = (New-RfLink '/redfish/v1/Systems'); Chassis = (New-RfLink '/redfish/v1/Chassis'); Managers = (New-RfLink '/redfish/v1/Managers'); UpdateService = (New-RfLink '/redfish/v1/UpdateService'); Oem = @{ Ami = @{} } }
    Set-RfCollection $t '/redfish/v1/Systems' @($sys)
    Set-RfResource $t $sys @{
        Id = 'Self'; Manufacturer = 'DataON'; Model = 'Test Model A1'; SerialNumber = $Serial; UUID = '00000000-0000-4000-8000-0000000000a1'; PowerState = 'On'
        ProcessorSummary = @{ Count = 1; Model = 'Test CPU 300' }; MemorySummary = @{ TotalSystemMemoryGiB = 128 }
        Processors = (New-RfLink "$sys/Processors"); Memory = (New-RfLink "$sys/Memory"); Storage = (New-RfLink "$sys/Storage")
        Links = @{ Chassis = @(New-RfLink $chs); ManagedBy = @(New-RfLink $mgr) }
    }
    Set-RfCollection $t '/redfish/v1/Chassis' @($chs)
    Set-RfResource $t $chs @{ Id = 'Self'; Model = 'Test Chassis A1'; SerialNumber = 'TESTCH-A-0001'; NetworkAdapters = (New-RfLink "$chs/NetworkAdapters") }
    Set-RfCollection $t '/redfish/v1/Managers' @($mgr)
    Set-RfResource $t $mgr @{ Id = 'Self'; Name = 'Manager'; FirmwareVersion = '12.34.56'; ManagerType = 'BMC'; EthernetInterfaces = (New-RfLink "$mgr/EthernetInterfaces"); Oem = @{ Ami = @{} } }
    Set-RfCollection $t "$mgr/EthernetInterfaces" @("$mgr/EthernetInterfaces/eth0")
    Set-RfResource $t "$mgr/EthernetInterfaces/eth0" @{ Id = 'eth0'; MACAddress = '00:00:5E:00:53:41'; SpeedMbps = 1000 }
    Add-RfCpu $t "$sys/Processors" 1 'Test CPU 300' 'Test Silicon' 16 32
    Add-RfMemory $t "$sys/Memory" 4 32768 ''

    $a = "$chs/NetworkAdapters"
    Set-RfCollection $t $a @("$a/OCP1")
    Set-RfResource $t "$a/OCP1" @{ Id = 'OCP1'; Name = 'Test OCP card'; Manufacturer = 'Test NIC Co'; Model = 'Test 10G OCP'; NetworkPorts = (New-RfLink "$a/OCP1/NetworkPorts") }
    Set-RfCollection $t "$a/OCP1/NetworkPorts" @("$a/OCP1/NetworkPorts/1", "$a/OCP1/NetworkPorts/2")
    Set-RfResource $t "$a/OCP1/NetworkPorts/1" @{ Id = '1'; PhysicalPortNumber = '1'; LinkStatus = 'Up'; CurrentLinkSpeedMbps = 10000; AssociatedNetworkAddresses = @('00:00:5E:00:53:42') }
    Set-RfResource $t "$a/OCP1/NetworkPorts/2" @{ Id = '2'; PhysicalPortNumber = '2'; LinkStatus = 'Up'; CurrentLinkSpeedMbps = 10000; AssociatedNetworkAddresses = @('00:00:5E:00:53:43') }

    $s = "$sys/Storage"
    Set-RfCollection $t $s @("$s/Backplane")
    Set-RfResource $t "$s/Backplane" @{ Id = 'Backplane'; Name = 'Test backplane'; StorageControllers = @(@{ Model = 'Test SATA/SAS backplane'; Manufacturer = 'Test Storage Co' }); Drives = @(0..7 | ForEach-Object { New-RfLink "/redfish/v1/Drives/D$_" }) }
    0..1 | ForEach-Object { Add-RfDrive $t "/redfish/v1/Drives/D$_" "D$_" 'TEST-SSD-960' "TESTDRV-AS$_" 'SF1' 960000000000 'SSD' 'SATA' "Slot $_" }
    2..7 | ForEach-Object { Add-RfDrive $t "/redfish/v1/Drives/D$_" "D$_" 'TEST-HDD-4000' "TESTDRV-AH$_" 'HF9' 4000000000000 'HDD' 'SAS' "Slot $_" }
    # No UpdateService: the firmware inventory is not offered.
    return $t
}

function Use-FakeBmcSet {
    # Host name -> tree. Pester mocks run in module scope and read the set through a global.
    param([hashtable]$Tree)
    $global:AzlHwBmc = @{ Tree = @{}; Status = @{}; Calls = [System.Collections.Generic.List[object]]::new() }
    foreach ($h in $Tree.Keys) {
        $bodies = @{}
        foreach ($k in $Tree[$h].Keys) { $bodies[$k] = ($Tree[$h][$k] | ConvertTo-Json -Depth 30 -Compress) }
        $global:AzlHwBmc.Tree[$h] = $bodies
    }
}

function Remove-FakeBmcSet { Remove-Variable -Name AzlHwBmc -Scope Global -ErrorAction SilentlyContinue }

# The mock body for Invoke-WebRequest in the Redfish core. $global:AzlHwBmc.Status["host/path"] = 401 answers that status.
$script:HwResponder = {
    $bmc = $global:AzlHwBmc
    $u = [uri]$Uri
    $bound = $PesterBoundParameters
    $bmc.Calls.Add([pscustomobject]@{
            Method = "$($bound['Method'])"; Host = $u.Host; Path = $u.AbsolutePath
            Basic = ($bound.ContainsKey('Authentication') -and "$($bound['Authentication'])" -eq 'Basic' -and $bound.ContainsKey('Credential'))
            SkipCertificateCheck = ($bound.ContainsKey('SkipCertificateCheck') -and [bool]$bound['SkipCertificateCheck'])
            OperationTimeoutSeconds = $bound['OperationTimeoutSeconds']
            User = $(if ($bound.ContainsKey('Credential') -and $bound['Credential']) { $bound['Credential'].UserName })
        })
    $key = "$($u.Host)$($u.AbsolutePath)"
    if ($bmc.Status.ContainsKey($key)) { return [pscustomobject]@{ StatusCode = [int]$bmc.Status[$key]; Content = '{"error":{"message":"synthetic answer for the test"}}'; Headers = @{} } }
    if (-not $bmc.Tree.ContainsKey($u.Host)) { throw "No route to host $($u.Host) (synthetic)." }
    $tree = $bmc.Tree[$u.Host]
    $path = $u.AbsolutePath
    if ($path.Length -gt 1) { $path = $path.TrimEnd('/') }
    if ($tree.ContainsKey($path)) { return [pscustomobject]@{ StatusCode = 200; Content = $tree[$path]; Headers = @{} } }
    return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"message":"The resource was not found"}}'; Headers = @{} }
}
