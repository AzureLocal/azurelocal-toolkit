#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the SYNTHETIC Dell iDRAC9 Redfish fixture trees used by the discovery tests (tests/discovery/Redfish*.Tests.ps1).

.DESCRIPTION
    These fixtures are NOT captures from real hardware. They are hand-built, DMTF-shaped Redfish trees, modelled on the shape
    of the lab's first Dell scan (an AX-760 with an embedded Broadcom LOM, Mellanox ConnectX-6 cards, NVMe data drives and a
    BOSS-N1 card), with documentation values only: MACs 00:00:5E:00:53:xx (RFC 7042), IP addresses from 192.0.2.0/24,
    host names under .invalid, serials and service tags that start with DOC. No value comes from a real machine.

    Two trees are written, each as one tree.json (Redfish path -> response body; the key '_fixture' labels it):

      idrac9-ax760-synthetic        the classic iDRAC9 schema: NetworkPorts, Power and Thermal. Reproduces both lab defects:
                                    the embedded LOM lists port NIC.Embedded.2-1 under adapter NIC.Embedded.1, and that
                                    adapter has an empty Model.
      idrac9-newschema-synthetic    the newer schema variant: Ports, PowerSubsystem, ThermalSubsystem and Sensors.

    Run it to regenerate the files after changing the shape. The tests read the committed tree.json files; they never run this.

.EXAMPLE
    pwsh -File ./tests/fixtures/redfish/dell/New-DellFixture.ps1
#>
[CmdletBinding()]
param([string]$OutputRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function L([string]$Uri) { return [ordered]@{ '@odata.id' = $Uri } }
function Collection($Tree, [string]$Uri, [string[]]$Member, [string]$Name = 'Collection') {
    $Tree[$Uri] = [ordered]@{ '@odata.id' = $Uri; Name = $Name; 'Members@odata.count' = $Member.Count; Members = @($Member | ForEach-Object { L $_ }) }
}
$ok = [ordered]@{ Health = 'OK'; HealthRollup = 'OK'; State = 'Enabled' }

function New-ClassicTree {
    $t = [ordered]@{}
    $t['_fixture'] = [ordered]@{
        kind = 'synthetic'; vendor = 'Dell'; bmc = 'iDRAC9'; schemaVariant = 'classic (NetworkPorts, Power, Thermal)'
        note = 'NOT a real capture. Built by New-DellFixture.ps1 in the shape of the lab AX-760 scan, documentation values only.'
    }
    $r = '/redfish/v1'; $sys = "$r/Systems/System.Embedded.1"; $ch = "$r/Chassis/System.Embedded.1"; $mgr = "$r/Managers/iDRAC.Embedded.1"

    $t[$r] = [ordered]@{
        '@odata.id' = $r; Id = 'RootService'; Name = 'Root Service'; RedfishVersion = '1.17.0'; Vendor = 'Dell'; Product = 'Integrated Dell Remote Access Controller'
        Systems = L "$r/Systems"; Chassis = L "$r/Chassis"; Managers = L "$r/Managers"; UpdateService = L "$r/UpdateService"
        SessionService = L "$r/SessionService"; AccountService = L "$r/AccountService"
        Oem = [ordered]@{ Dell = [ordered]@{ '@odata.type' = '#DellServiceRoot.v1_0_0.ServiceRootExtensions'; IsBranded = 0; ManagerMACAddress = '00:00:5E:00:53:01'; ServiceTag = 'DOCTAG1' } }
    }
    Collection $t "$r/Systems" @($sys) 'Computer System Collection'
    Collection $t "$r/Chassis" @($ch) 'Chassis Collection'
    Collection $t "$r/Managers" @($mgr) 'Manager Collection'

    $t[$sys] = [ordered]@{
        '@odata.id' = $sys; Id = 'System.Embedded.1'; Name = 'System'; SKU = 'DOCTAG1'; SerialNumber = 'DOCSERIAL0001'; Model = 'AX-760'; Manufacturer = 'Dell Inc.'
        PartNumber = '0DOC00A00'; UUID = '00000000-0000-4000-8000-000000000001'; HostName = 'doc-node-1.invalid'; BiosVersion = '2.0.0'; PowerState = 'On'
        AssetTag = ''; IndicatorLED = 'Off'; LocationIndicatorActive = $false
        Status = [ordered]@{ Health = 'OK'; HealthRollup = 'OK'; State = 'Enabled' }
        ProcessorSummary = [ordered]@{ Count = 2; Model = 'Intel(R) Xeon(R) Gold 6430'; CoreCount = 64; LogicalProcessorCount = 128; Status = $ok }
        MemorySummary = [ordered]@{ TotalSystemMemoryGiB = 256; MemoryMirroring = 'System'; Status = $ok }
        Boot = [ordered]@{ BootSourceOverrideEnabled = 'Disabled'; BootSourceOverrideTarget = 'None'; BootSourceOverrideMode = 'UEFI'; BootOrder = @('HardDisk.List.1-1', 'NIC.Slot.3-1-1'); TrustedModuleRequiredToBoot = 'Disabled' }
        TrustedModules = @([ordered]@{ FirmwareVersion = '7.2.3.1'; InterfaceType = 'TPM2_0'; Status = [ordered]@{ State = 'Enabled' } })
        Processors = L "$sys/Processors"; Memory = L "$sys/Memory"; Storage = L "$sys/Storage"; NetworkAdapters = L "$sys/NetworkAdapters"
        EthernetInterfaces = L "$sys/EthernetInterfaces"; Bios = L "$sys/Bios"; SecureBoot = L "$sys/SecureBoot"
        Links = [ordered]@{ Chassis = @(L $ch); ManagedBy = @(L $mgr); PCIeDevices = @((L "$ch/PCIeDevices/0-25"), (L "$ch/PCIeDevices/59-0"), (L "$ch/PCIeDevices/7-0")) }
        Oem = [ordered]@{ Dell = [ordered]@{ DellSystem = [ordered]@{
                        '@odata.type' = '#DellSystem.v1_0_0.DellSystem'; ChassisServiceTag = 'DOCTAG1'; ExpressServiceCode = '00000000001'; BIOSReleaseDate = '01/01/2026'
                        SystemGeneration = '16G Monolithic'; MaxDIMMSlots = 32; MaxPCIeSlots = 8; NodeID = 'DOCTAG1' } } }
    }
    Collection $t "$sys/Processors" @("$sys/Processors/CPU.Socket.1", "$sys/Processors/CPU.Socket.2") 'Processors Collection'
    foreach ($i in 1, 2) {
        $t["$sys/Processors/CPU.Socket.$i"] = [ordered]@{
            '@odata.id' = "$sys/Processors/CPU.Socket.$i"; Id = "CPU.Socket.$i"; Name = "CPU $i"; Socket = "CPU.Socket.$i"; Model = 'Intel(R) Xeon(R) Gold 6430'; Manufacturer = 'Intel'
            ProcessorType = 'CPU'; ProcessorArchitecture = 'x86'; InstructionSet = 'x86-64'; TotalCores = 32; TotalThreads = 64; MaxSpeedMHz = 4100
            ProcessorId = [ordered]@{ VendorId = 'GenuineIntel'; MicrocodeInfo = '0x2b000461' }; Status = $ok
        }
    }
    $dimms = 'A1', 'A2', 'B1', 'B2', 'A3'
    Collection $t "$sys/Memory" @($dimms | ForEach-Object { "$sys/Memory/DIMM.Socket.$_" }) 'Memory Collection'
    foreach ($d in $dimms) {
        $present = $d -ne 'A3'
        $t["$sys/Memory/DIMM.Socket.$d"] = [ordered]@{
            '@odata.id' = "$sys/Memory/DIMM.Socket.$d"; Id = "DIMM.Socket.$d"; Name = "DIMM $d"; DeviceLocator = "DIMM $d"
            CapacityMiB = $(if ($present) { 65536 } else { 0 }); MemoryDeviceType = 'DDR5'; BaseModuleType = 'RDIMM'; OperatingSpeedMhz = $(if ($present) { 4800 } else { $null })
            Manufacturer = $(if ($present) { 'Doc Memory Co' } else { $null }); PartNumber = $(if ($present) { 'DOC-PART-64G' } else { $null }); SerialNumber = $(if ($present) { "DOCDIMM000$($dimms.IndexOf($d))" } else { $null })
            ErrorCorrection = 'MultiBitECC'; RankCount = 2
            MemoryLocation = [ordered]@{ Socket = 1; MemoryController = 1; Channel = 1; Slot = 1 }
            Status = $(if ($present) { $ok } else { [ordered]@{ Health = $null; State = 'Absent' } })
        }
    }

    # Network adapters (classic: NetworkPorts). Lab defects: the LOM adapter NIC.Embedded.1 has no Model, and its second port is
    # named NIC.Embedded.2-1 (PhysicalPortNumber 2) although it sits under adapter NIC.Embedded.1.
    $na = "$sys/NetworkAdapters"
    Collection $t $na @("$na/NIC.Embedded.1", "$na/NIC.Slot.3", "$na/NIC.Slot.6") 'Network Adapter Collection'
    $t["$na/NIC.Embedded.1"] = [ordered]@{
        '@odata.id' = "$na/NIC.Embedded.1"; Id = 'NIC.Embedded.1'; Name = 'Network Adapter - NIC.Embedded.1'; Manufacturer = 'Broadcom Inc. and subsidiaries'; Model = ''; Description = ''
        Controllers = @([ordered]@{ FirmwarePackageVersion = '23.31.1'; ControllerCapabilities = [ordered]@{ NetworkPortCount = 2; NetworkDeviceFunctionCount = 2 }; Links = [ordered]@{ PCIeDevices = @(L "$ch/PCIeDevices/0-25") } })
        NetworkPorts = L "$na/NIC.Embedded.1/NetworkPorts"; NetworkDeviceFunctions = L "$na/NIC.Embedded.1/NetworkDeviceFunctions"
    }
    Collection $t "$na/NIC.Embedded.1/NetworkPorts" @("$na/NIC.Embedded.1/NetworkPorts/NIC.Embedded.1-1", "$na/NIC.Embedded.1/NetworkPorts/NIC.Embedded.2-1") 'Network Port Collection'
    Collection $t "$na/NIC.Embedded.1/NetworkDeviceFunctions" @("$na/NIC.Embedded.1/NetworkDeviceFunctions/NIC.Embedded.1-1-1", "$na/NIC.Embedded.1/NetworkDeviceFunctions/NIC.Embedded.2-1-1") 'Network Device Function Collection'
    $lom = @{ 1 = '00:00:5E:00:53:10'; 2 = '00:00:5E:00:53:11' }
    foreach ($n in 1, 2) {
        $t["$na/NIC.Embedded.1/NetworkPorts/NIC.Embedded.$n-1"] = [ordered]@{
            '@odata.id' = "$na/NIC.Embedded.1/NetworkPorts/NIC.Embedded.$n-1"; Id = "NIC.Embedded.$n-1"; Name = "Network Port - NIC.Embedded.$n-1"; PhysicalPortNumber = "$n"; LinkStatus = 'Up'
            CurrentLinkSpeedMbps = 1000; ActiveLinkTechnology = 'Ethernet'; AssociatedNetworkAddresses = @($lom[$n]); FlowControlStatus = 'None'
            SupportedLinkCapabilities = @([ordered]@{ LinkNetworkTechnology = 'Ethernet'; LinkSpeedMbps = 1000 })
        }
        $t["$na/NIC.Embedded.1/NetworkDeviceFunctions/NIC.Embedded.$n-1-1"] = [ordered]@{
            '@odata.id' = "$na/NIC.Embedded.1/NetworkDeviceFunctions/NIC.Embedded.$n-1-1"; Id = "NIC.Embedded.$n-1-1"; DeviceEnabled = $true; NetDevFuncType = 'Ethernet'; NetDevFuncCapabilities = @('Ethernet')
            Ethernet = [ordered]@{ MACAddress = $lom[$n]; PermanentMACAddress = $lom[$n]; MTUSize = 1500 }
            Oem = [ordered]@{ Dell = [ordered]@{ DellNIC = [ordered]@{ ProductName = "Broadcom Gigabit Ethernet BCM5720 - $($lom[$n])"; VendorName = 'Broadcom'; FamilyVersion = '23.31.1' } } }
        }
    }
    # Slot 3: a 100G card whose ports report their MAC (as in the lab). Slot 6: a card whose MAC is only on the device function.
    $cards = @(
        @{ Id = 'NIC.Slot.3'; Mac = @('00:00:5E:00:53:21', '00:00:5E:00:53:22'); MacOnPort = $true; Pcie = '59-0' }
        @{ Id = 'NIC.Slot.6'; Mac = @('00:00:5E:00:53:31', '00:00:5E:00:53:32'); MacOnPort = $false; Pcie = '' }
    )
    foreach ($c in $cards) {
        $a = "$na/$($c.Id)"; $id = $c.Id
        $t[$a] = [ordered]@{
            '@odata.id' = $a; Id = $id; Name = "Network Adapter - $id"; Manufacturer = 'Doc Networks'; Model = 'DOC 100GbE 2P ConnectX6 Adpt'; PartNumber = 'DOC-NIC-100G'; SerialNumber = "DOCNIC-$id"
            Controllers = @([ordered]@{ FirmwarePackageVersion = '22.44.10.36'; Links = [ordered]@{ PCIeDevices = $(if ($c.Pcie) { @(L "$ch/PCIeDevices/$($c.Pcie)") } else { @() }) } })
            NetworkPorts = L "$a/NetworkPorts"; NetworkDeviceFunctions = L "$a/NetworkDeviceFunctions"
        }
        Collection $t "$a/NetworkPorts" @("$a/NetworkPorts/$id-1", "$a/NetworkPorts/$id-2") 'Network Port Collection'
        Collection $t "$a/NetworkDeviceFunctions" @("$a/NetworkDeviceFunctions/$id-1-1", "$a/NetworkDeviceFunctions/$id-2-1") 'Network Device Function Collection'
        foreach ($n in 1, 2) {
            $t["$a/NetworkPorts/$id-$n"] = [ordered]@{
                '@odata.id' = "$a/NetworkPorts/$id-$n"; Id = "$id-$n"; Name = "Network Port - $id-$n"; PhysicalPortNumber = "$n"; LinkStatus = 'Up'; CurrentLinkSpeedMbps = 100000
                ActiveLinkTechnology = 'Ethernet'; AssociatedNetworkAddresses = $(if ($c.MacOnPort) { @($c.Mac[$n - 1]) } else { @() })
                SupportedLinkCapabilities = @([ordered]@{ LinkNetworkTechnology = 'Ethernet'; LinkSpeedMbps = 100000 })
            }
            $t["$a/NetworkDeviceFunctions/$id-$n-1"] = [ordered]@{
                '@odata.id' = "$a/NetworkDeviceFunctions/$id-$n-1"; Id = "$id-$n-1"; DeviceEnabled = $true; NetDevFuncType = 'Ethernet'; NetDevFuncCapabilities = @('Ethernet')
                Ethernet = [ordered]@{ PermanentMACAddress = $c.Mac[$n - 1]; MTUSize = 9000 }
            }
        }
    }
    Collection $t "$sys/EthernetInterfaces" @("$sys/EthernetInterfaces/NIC.Embedded.1-1-1") 'Ethernet Interface Collection'
    $t["$sys/EthernetInterfaces/NIC.Embedded.1-1-1"] = [ordered]@{ '@odata.id' = "$sys/EthernetInterfaces/NIC.Embedded.1-1-1"; Id = 'NIC.Embedded.1-1-1'; MACAddress = '00:00:5E:00:53:10'; PermanentMACAddress = '00:00:5E:00:53:10'; SpeedMbps = 1000; LinkStatus = 'LinkUp'; Status = $ok }

    # Storage: NVMe direct-attach (CPU.1, raw devices), the onboard SATA controller (empty) and a BOSS-N1 with a RAID1 virtual disk.
    $st = "$sys/Storage"
    Collection $t $st @("$st/CPU.1", "$st/AHCI.Embedded.1-1", "$st/BOSS.SL.12-1") 'Storage Collection'
    $nvme = 0..3 | ForEach-Object { "Disk.Bay.${_}:Enclosure.Internal.0-1" }
    $t["$st/CPU.1"] = [ordered]@{
        '@odata.id' = "$st/CPU.1"; Id = 'CPU.1'; Name = 'CPU.1'; Status = $ok; StorageControllers = @([ordered]@{ Model = ''; Manufacturer = ''; FirmwareVersion = '' })
        Drives = @($nvme | ForEach-Object { L "$st/CPU.1/Drives/$_" }); Volumes = L "$st/CPU.1/Volumes"
    }
    Collection $t "$st/CPU.1/Volumes" @($nvme | ForEach-Object { "$st/CPU.1/Volumes/$_" }) 'Volume Collection'
    $i = 0
    foreach ($d in $nvme) {
        $t["$st/CPU.1/Drives/$d"] = [ordered]@{
            '@odata.id' = "$st/CPU.1/Drives/$d"; Id = $d; Name = "PCIe SSD in Slot $i in Bay 1"; Model = 'Doc NVMe RI U.2 3.84TB'; Manufacturer = 'Doc Flash'; SerialNumber = "DOCDRV000$i"; PartNumber = 'DOC-U2-3840'
            Revision = 'DOC1'; CapacityBytes = 3840755982336; MediaType = 'SSD'; Protocol = 'PCIe'; PredictedMediaLifeLeftPercent = 100; Status = $ok
            PhysicalLocation = [ordered]@{ PartLocation = [ordered]@{ ServiceLabel = "PCIe SSD in Slot $i in Bay 1"; LocationOrdinalValue = $i } }
        }
        $t["$st/CPU.1/Volumes/$d"] = [ordered]@{ '@odata.id' = "$st/CPU.1/Volumes/$d"; Id = $d; Name = "PCIe SSD in Slot $i in Bay 1"; VolumeType = 'RawDevice'; RAIDType = $null; CapacityBytes = 3840755982336; Status = $ok }
        $i++
    }
    $t["$st/AHCI.Embedded.1-1"] = [ordered]@{ '@odata.id' = "$st/AHCI.Embedded.1-1"; Id = 'AHCI.Embedded.1-1'; Name = 'Doc SATA AHCI Controller'; Status = $ok; StorageControllers = @([ordered]@{ Model = 'Doc SATA AHCI Controller'; Manufacturer = 'DELL'; FirmwareVersion = '' }); Drives = @(); Volumes = L "$st/AHCI.Embedded.1-1/Volumes" }
    Collection $t "$st/AHCI.Embedded.1-1/Volumes" @() 'Volume Collection'
    $boss = "$st/BOSS.SL.12-1"
    $t[$boss] = [ordered]@{
        '@odata.id' = $boss; Id = 'BOSS.SL.12-1'; Name = 'BOSS-N1 Monolithic'; Status = $ok
        StorageControllers = @([ordered]@{ Model = 'BOSS-N1 Monolithic'; Manufacturer = 'DELL'; FirmwareVersion = '2.1.13.2037'; SupportedRAIDTypes = @('RAID1'); SupportedDeviceProtocols = @('PCIe') })
        Drives = @((L "$boss/Drives/Disk.Direct.0-0:BOSS.SL.12-1"), (L "$boss/Drives/Disk.Direct.1-1:BOSS.SL.12-1")); Volumes = L "$boss/Volumes"
    }
    foreach ($n in 0, 1) {
        $t["$boss/Drives/Disk.Direct.$n-${n}:BOSS.SL.12-1"] = [ordered]@{
            '@odata.id' = "$boss/Drives/Disk.Direct.$n-${n}:BOSS.SL.12-1"; Id = "Disk.Direct.$n-${n}:BOSS.SL.12-1"; Name = "NVMe $n"; Model = 'Doc NVMe RI M.2 960GB'; Manufacturer = 'Doc Flash'; SerialNumber = "DOCM2000$n"
            CapacityBytes = 960197124096; MediaType = 'SSD'; Protocol = 'PCIe'; Status = $ok
        }
    }
    Collection $t "$boss/Volumes" @("$boss/Volumes/Disk.Virtual.0:BOSS.SL.12-1") 'Volume Collection'
    $t["$boss/Volumes/Disk.Virtual.0:BOSS.SL.12-1"] = [ordered]@{
        '@odata.id' = "$boss/Volumes/Disk.Virtual.0:BOSS.SL.12-1"; Id = 'Disk.Virtual.0:BOSS.SL.12-1'; Name = 'BOSS_RAID1'; RAIDType = 'RAID1'; VolumeType = 'Mirrored'; CapacityBytes = 960129662976; Status = $ok
        Links = [ordered]@{ Drives = @((L "$boss/Drives/Disk.Direct.0-0:BOSS.SL.12-1"), (L "$boss/Drives/Disk.Direct.1-1:BOSS.SL.12-1")) }
    }

    # BIOS, Secure Boot
    $t["$sys/Bios"] = [ordered]@{
        '@odata.id' = "$sys/Bios"; Id = 'BIOS'; Name = 'BIOS Configuration Current Settings'; AttributeRegistry = 'BiosAttributeRegistry2.0.0'
        '@Redfish.Settings' = [ordered]@{ SettingsObject = L "$sys/Bios/Settings" }
        Attributes = [ordered]@{ ProcVirtualization = 'Enabled'; SriovGlobalEnable = 'Enabled'; BootMode = 'Uefi'; SecureBoot = 'Enabled'; SysProfile = 'PerfOptimized'; ProcCStates = 'Disabled'; SetupPassword = $null; SysPassword = 'doc-redaction-check'; MemTest = 'Disabled' }
    }
    $t["$sys/Bios/Settings"] = [ordered]@{ '@odata.id' = "$sys/Bios/Settings"; Id = 'Settings'; Name = 'Pending BIOS settings'; Attributes = [ordered]@{ ProcCStates = 'Enabled' } }
    $t["$sys/SecureBoot"] = [ordered]@{ '@odata.id' = "$sys/SecureBoot"; Id = 'SecureBoot'; SecureBootEnable = $true; SecureBootCurrentBoot = 'Enabled'; SecureBootMode = 'DeployedMode' }

    # Chassis, PCIe, power, thermal
    $t[$ch] = [ordered]@{
        '@odata.id' = $ch; Id = 'System.Embedded.1'; Name = 'Computer System Chassis'; ChassisType = 'RackMount'; Manufacturer = 'Dell Inc.'; Model = 'AX-760'; SerialNumber = 'DOCSERIAL0001'; SKU = 'DOCTAG1'
        AssetTag = ''; PartNumber = '0DOC00A00'; IndicatorLED = 'Off'; Status = $ok; Power = L "$ch/Power"; Thermal = L "$ch/Thermal"; PCIeDevices = L "$ch/PCIeDevices"
        Links = [ordered]@{ ComputerSystems = @(L $sys); ManagedBy = @(L $mgr) }
    }
    Collection $t "$ch/PCIeDevices" @("$ch/PCIeDevices/0-25", "$ch/PCIeDevices/59-0", "$ch/PCIeDevices/7-0") 'PCIe Device Collection'
    $pcie = @(
        @{ Id = '0-25'; Name = 'Embedded NIC 1'; Description = 'Broadcom Gigabit Ethernet BCM5720'; Mfr = 'Broadcom'; Dev = '0x165f'; Ven = '0x14e4'; Class = '0x020000'; DevClass = 'NetworkController'; Lanes = 1 }
        @{ Id = '59-0'; Name = 'Slot 3 NIC'; Description = 'DOC 100GbE 2P ConnectX6 Adpt'; Mfr = 'Doc Networks'; Dev = '0x101d'; Ven = '0x15b3'; Class = '0x020000'; DevClass = 'NetworkController'; Lanes = 16 }
        @{ Id = '7-0'; Name = 'Slot 7 GPU'; Description = 'DOC A2 16GB Accelerator'; Mfr = 'Doc Graphics'; Dev = '0x25b6'; Ven = '0x10de'; Class = '0x030200'; DevClass = 'DisplayController'; Lanes = 8 }
    )
    foreach ($p in $pcie) {
        $t["$ch/PCIeDevices/$($p.Id)"] = [ordered]@{
            '@odata.id' = "$ch/PCIeDevices/$($p.Id)"; Id = $p.Id; Name = $p.Name; Description = $p.Description; Manufacturer = $p.Mfr; FirmwareVersion = '1.0.0'; DeviceType = 'MultiFunction'
            PCIeInterface = [ordered]@{ LanesInUse = $p.Lanes; MaxLanes = $p.Lanes; PCIeType = 'Gen4'; MaxPCIeType = 'Gen4' }; Status = $ok
            Links = [ordered]@{ PCIeFunctions = @(L "$ch/PCIeDevices/$($p.Id)/PCIeFunctions/$($p.Id)-0") }
        }
        $t["$ch/PCIeDevices/$($p.Id)/PCIeFunctions/$($p.Id)-0"] = [ordered]@{
            '@odata.id' = "$ch/PCIeDevices/$($p.Id)/PCIeFunctions/$($p.Id)-0"; Id = "$($p.Id)-0"; Name = $p.Description; DeviceId = $p.Dev; VendorId = $p.Ven; SubsystemId = '0x0001'; SubsystemVendorId = $p.Ven
            ClassCode = $p.Class; DeviceClass = $p.DevClass; FunctionType = 'Physical'; FunctionId = 0; Status = $ok
        }
    }
    $t["$ch/Thermal"] = [ordered]@{
        '@odata.id' = "$ch/Thermal"; Id = 'Thermal'; Name = 'Thermal'
        Temperatures = @([ordered]@{ Name = 'System Board Inlet Temp'; ReadingCelsius = 22; UpperThresholdCritical = 42; UpperThresholdNonCritical = 38; Status = [ordered]@{ Health = 'OK'; State = 'Enabled' } })
        Fans = @([ordered]@{ Name = 'System Board Fan1A'; Reading = 7000; ReadingUnits = 'RPM'; Status = [ordered]@{ Health = 'OK'; State = 'Enabled' } })
    }
    $t["$ch/Power"] = [ordered]@{
        '@odata.id' = "$ch/Power"; Id = 'Power'; Name = 'Power'
        PowerControl = @([ordered]@{ Name = 'System Power Control'; PowerConsumedWatts = 350; PowerCapacityWatts = 1400 })
        PowerSupplies = @(1, 2 | ForEach-Object { [ordered]@{ Name = "PS$_ Status"; Model = 'DOC PWR SPLY,1400W'; SerialNumber = "DOCPSU000$_"; FirmwareVersion = '00.1B.7D'; PowerCapacityWatts = 1400; LineInputVoltage = 230; Status = [ordered]@{ Health = 'OK'; State = 'Enabled' } } })
        Voltages = @([ordered]@{ Name = 'CPU1 VCORE PG'; ReadingVolts = 1; Status = [ordered]@{ Health = 'OK'; State = 'Enabled' } })
        Redundancy = @([ordered]@{ Name = 'System Board PS Redundancy'; Mode = 'N+1'; MinNumNeeded = 1; Status = [ordered]@{ Health = 'OK'; State = 'Enabled' } })
    }

    # Manager (iDRAC)
    $t[$mgr] = [ordered]@{
        '@odata.id' = $mgr; Id = 'iDRAC.Embedded.1'; Name = 'Manager'; Model = '16G Monolithic'; FirmwareVersion = '7.20.30.00'; ManagerType = 'BMC'; UUID = '00000000-0000-4000-8000-0000000000a1'
        DateTime = '2026-01-01T00:00:00+00:00'; DateTimeLocalOffset = '+00:00'; Status = $ok
        EthernetInterfaces = L "$mgr/EthernetInterfaces"; NetworkProtocol = L "$mgr/NetworkProtocol"; LogServices = L "$mgr/LogServices"; Attributes = L "$mgr/Attributes"
        Links = [ordered]@{ ManagerForServers = @(L $sys) }
        Oem = [ordered]@{ Dell = [ordered]@{ '@odata.type' = '#DellManager.v1_0_0.DellManager'; DelliDRACCard = L "$mgr/Oem/Dell/DelliDRACCardService" } }
    }
    Collection $t "$mgr/EthernetInterfaces" @("$mgr/EthernetInterfaces/NIC.1") 'Ethernet Interface Collection'
    $t["$mgr/EthernetInterfaces/NIC.1"] = [ordered]@{
        '@odata.id' = "$mgr/EthernetInterfaces/NIC.1"; Id = 'NIC.1'; Name = 'Manager Ethernet Interface'; MACAddress = '00:00:5E:00:53:01'; PermanentMACAddress = '00:00:5E:00:53:01'; SpeedMbps = 1000; LinkStatus = 'LinkUp'
        HostName = 'doc-idrac-1'; FQDN = 'doc-idrac-1.invalid'; VLAN = [ordered]@{ VLANEnable = $false; VLANId = 1 }
        IPv4Addresses = @([ordered]@{ Address = '192.0.2.21'; SubnetMask = '255.255.255.0'; AddressOrigin = 'DHCP'; Gateway = '192.0.2.1' }); Status = $ok
    }
    $t["$mgr/NetworkProtocol"] = [ordered]@{
        '@odata.id' = "$mgr/NetworkProtocol"; Id = 'ManagerNetworkProtocol'; HostName = 'doc-idrac-1'; FQDN = 'doc-idrac-1.invalid'; Status = $ok
        HTTPS = [ordered]@{ ProtocolEnabled = $true; Port = 443; Certificates = L "$mgr/NetworkProtocol/HTTPS/Certificates" }
        HTTP = [ordered]@{ ProtocolEnabled = $false; Port = 80 }; IPMI = [ordered]@{ ProtocolEnabled = $true; Port = 623 }; SSH = [ordered]@{ ProtocolEnabled = $true; Port = 22 }
        SNMP = [ordered]@{ ProtocolEnabled = $true; Port = 161 }; KVMIP = [ordered]@{ ProtocolEnabled = $true; Port = 5900 }; NTP = [ordered]@{ ProtocolEnabled = $false; NTPServers = @() }
    }
    Collection $t "$mgr/NetworkProtocol/HTTPS/Certificates" @("$mgr/NetworkProtocol/HTTPS/Certificates/SecurityCertificate.1") 'Certificate Collection'
    $t["$mgr/NetworkProtocol/HTTPS/Certificates/SecurityCertificate.1"] = [ordered]@{
        '@odata.id' = "$mgr/NetworkProtocol/HTTPS/Certificates/SecurityCertificate.1"; Id = 'SecurityCertificate.1'; CertificateType = 'PEM'
        Subject = [ordered]@{ CommonName = 'doc-idrac-1.invalid'; Organization = 'Doc Org' }; Issuer = [ordered]@{ CommonName = 'doc-idrac-1.invalid' }
        ValidNotBefore = '2026-01-01T00:00:00Z'; ValidNotAfter = '2036-01-01T00:00:00Z'
    }
    $t["$mgr/Attributes"] = [ordered]@{
        '@odata.id' = "$mgr/Attributes"; Id = 'iDRACAttributes'; Name = 'Manager Attributes'
        Attributes = [ordered]@{ 'Info.1.Product' = 'Integrated Dell Remote Access Controller'; 'IPv4.1.Enable' = 'Enabled'; 'VNCServer.1.Enable' = 'Disabled'; 'VNCServer.1.Port' = 5901; 'VNCServer.1.Password' = $null
            'SNMP.1.AgentCommunity' = 'doc-redaction-check'; 'Users.2.UserName' = 'doc-user'; 'Users.2.Password' = 'doc-redaction-check'; 'NTPConfigGroup.1.NTPEnable' = 'Disabled' }
    }
    Collection $t "$mgr/LogServices" @("$mgr/LogServices/Sel", "$mgr/LogServices/Lclog") 'Log Service Collection'
    $t["$mgr/LogServices/Sel"] = [ordered]@{ '@odata.id' = "$mgr/LogServices/Sel"; Id = 'Sel'; Name = 'System Event Log'; MaxNumberOfRecords = 512; OverWritePolicy = 'WrapsWhenFull'; DateTime = '2026-01-01T00:00:00+00:00'; Entries = L "$mgr/LogServices/Sel/Entries" }
    $t["$mgr/LogServices/Lclog"] = [ordered]@{ '@odata.id' = "$mgr/LogServices/Lclog"; Id = 'Lclog'; Name = 'Lifecycle Log'; MaxNumberOfRecords = 20000; OverWritePolicy = 'WrapsWhenFull'; Entries = L "$mgr/LogServices/Lclog/Entries" }
    $sev = 'OK', 'OK', 'Warning', 'OK', 'Critical', 'OK', 'OK', 'Warning', 'OK', 'OK', 'OK', 'OK'
    $entries = 0..11 | ForEach-Object {
        [ordered]@{ '@odata.id' = "$mgr/LogServices/Sel/Entries/$($_ + 1)"; Id = "$($_ + 1)"; EntryType = 'SEL'; Severity = $sev[$_]; Created = ('2026-01-01T00:{0:d2}:00+00:00' -f $_); Message = "Doc event $($_ + 1)"; MessageId = 'DOC0001' }
    }
    $t["$mgr/LogServices/Sel/Entries"] = [ordered]@{ '@odata.id' = "$mgr/LogServices/Sel/Entries"; Name = 'System Event Log Entries'; 'Members@odata.count' = 12; Members = @($entries) }
    $t["$mgr/LogServices/Lclog/Entries"] = [ordered]@{ '@odata.id' = "$mgr/LogServices/Lclog/Entries"; Name = 'Lifecycle Log Entries'; 'Members@odata.count' = 0; Members = @() }

    # Firmware inventory
    $us = "$r/UpdateService"
    $t[$us] = [ordered]@{ '@odata.id' = $us; Id = 'UpdateService'; FirmwareInventory = L "$us/FirmwareInventory"; ServiceEnabled = $true }
    $fw = @(
        @{ Id = 'Installed-0-2.0.0__BIOS.Setup.1-1'; Name = 'BIOS'; V = '2.0.0'; U = $true }
        @{ Id = 'Installed-0-7.20.30.00__iDRAC.Embedded.1-1'; Name = 'Integrated Dell Remote Access Controller'; V = '7.20.30.00'; U = $true }
        @{ Id = 'Previous-0-7.10.00.00__iDRAC.Embedded.1-1'; Name = 'Integrated Dell Remote Access Controller'; V = '7.10.00.00'; U = $true }
        @{ Id = 'Installed-0-22.44.10.36__NIC.Slot.3-1-1'; Name = 'Mellanox ConnectX-6 Network Adapter - 00:00:5E:00:53:21'; V = '22.44.10.36'; U = $true }
        @{ Id = 'Installed-0-23.31.1__NIC.Embedded.1-1-1'; Name = 'Broadcom Gigabit Ethernet BCM5720 - 00:00:5E:00:53:10'; V = '23.31.1'; U = $true }
        @{ Id = 'Installed-0-2.1.13.2037__BOSS.SL.12-1'; Name = 'BOSS-N1 Monolithic'; V = '2.1.13.2037'; U = $true }
        @{ Id = 'Installed-0-DOC1__Disk.Bay.0:Enclosure.Internal.0-1'; Name = 'PCIe SSD in Slot 0 in Bay 1'; V = 'DOC1'; U = $true }
        @{ Id = 'Installed-0-00.1B.7D__PSU.Slot.1'; Name = 'PS1 Status'; V = '00.1B.7D'; U = $true }
        @{ Id = 'Installed-0-1.0.5__CPLD.Embedded.1'; Name = 'System CPLD'; V = '1.0.5'; U = $false }
        @{ Id = 'Installed-0-1.0.0__GPU.Slot.7'; Name = 'DOC A2 16GB Accelerator'; V = '1.0.0'; U = $false }
    )
    Collection $t "$us/FirmwareInventory" @($fw | ForEach-Object { "$us/FirmwareInventory/$($_.Id)" }) 'Software Inventory Collection'
    foreach ($f in $fw) {
        $t["$us/FirmwareInventory/$($f.Id)"] = [ordered]@{
            '@odata.id' = "$us/FirmwareInventory/$($f.Id)"; Id = $f.Id; Name = $f.Name; Version = $f.V; Updateable = $f.U; Status = [ordered]@{ Health = 'OK'; State = 'Enabled' }
            ReleaseDate = '2026-01-01T00:00:00Z'; SoftwareId = $f.Id -replace '^[A-Za-z]+-\d+-', ''; RelatedItem = @()
        }
    }
    return $t
}

function New-NewSchemaTree($Classic) {
    # Same node, newer schema: Ports (not NetworkPorts), PowerSubsystem, ThermalSubsystem and Sensors (not Power and Thermal).
    $t = [ordered]@{}
    foreach ($k in $Classic.Keys) { $t[$k] = ($Classic[$k] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -Depth 30) }
    $t['_fixture'] = [ordered]@{
        kind = 'synthetic'; vendor = 'Dell'; bmc = 'iDRAC9'; schemaVariant = 'newer (Ports, PowerSubsystem, ThermalSubsystem, Sensors)'
        note = 'NOT a real capture. Derived from the classic synthetic tree by New-DellFixture.ps1; documentation values only.'
    }
    $r = '/redfish/v1'; $ch = "$r/Chassis/System.Embedded.1"; $na = "$r/Systems/System.Embedded.1/NetworkAdapters"
    foreach ($k in @($t.Keys)) {
        if ($k -like '*/NetworkPorts') {
            $nk = $k.Replace('/NetworkPorts', '/Ports'); $b = $t[$k]; $b['@odata.id'] = $nk
            $b['Members'] = @($b['Members'] | ForEach-Object { L $_['@odata.id'].Replace('/NetworkPorts/', '/Ports/') })
            $t[$nk] = $b; $t.Remove($k)
        }
    }
    foreach ($k in @($t.Keys)) {
        if ($k -like '*/NetworkPorts/*') {
            $new = $k.Replace('/NetworkPorts/', '/Ports/'); $b = $t[$k]; $b['@odata.id'] = $new
            $speed = $b['CurrentLinkSpeedMbps']; $mac = @($b['AssociatedNetworkAddresses'])
            foreach ($drop in 'CurrentLinkSpeedMbps', 'AssociatedNetworkAddresses', 'SupportedLinkCapabilities', 'FlowControlStatus') { $b.Remove($drop) }
            $b['CurrentSpeedGbps'] = $speed / 1000; $b['MaxSpeedGbps'] = $speed / 1000; $b['PortProtocol'] = 'Ethernet'; $b['PortType'] = 'BidirectionalPort'
            $b['Ethernet'] = [ordered]@{ AssociatedMACAddresses = @($mac | Where-Object { $_ }); LLDPEnabled = $true }
            $t[$new] = $b; $t.Remove($k)
        }
    }
    foreach ($k in @($t.Keys)) {
        if ($k -like "$na/*" -and $t[$k] -is [System.Collections.IDictionary] -and $t[$k].Contains('NetworkPorts')) {
            $t[$k]['Ports'] = L ($t[$k]['NetworkPorts']['@odata.id'].Replace('/NetworkPorts', '/Ports')); $t[$k].Remove('NetworkPorts')
        }
    }
    $t[$ch].Remove('Power'); $t[$ch].Remove('Thermal'); $t.Remove("$ch/Power"); $t.Remove("$ch/Thermal")
    $t[$ch]['PowerSubsystem'] = L "$ch/PowerSubsystem"; $t[$ch]['ThermalSubsystem'] = L "$ch/ThermalSubsystem"; $t[$ch]['Sensors'] = L "$ch/Sensors"
    $t["$ch/PowerSubsystem"] = [ordered]@{ '@odata.id' = "$ch/PowerSubsystem"; Id = 'PowerSubsystem'; CapacityWatts = 2800; Allocation = [ordered]@{ AllocatedWatts = 700; RequestedWatts = 700 }; PowerSupplies = L "$ch/PowerSubsystem/PowerSupplies"; Status = $ok }
    Collection $t "$ch/PowerSubsystem/PowerSupplies" @("$ch/PowerSubsystem/PowerSupplies/PSU.Slot.1", "$ch/PowerSubsystem/PowerSupplies/PSU.Slot.2") 'Power Supply Collection'
    foreach ($n in 1, 2) {
        $t["$ch/PowerSubsystem/PowerSupplies/PSU.Slot.$n"] = [ordered]@{ '@odata.id' = "$ch/PowerSubsystem/PowerSupplies/PSU.Slot.$n"; Id = "PSU.Slot.$n"; Name = "PS$n Status"; Model = 'DOC PWR SPLY,1400W'; SerialNumber = "DOCPSU000$n"; FirmwareVersion = '00.1B.7D'; PowerCapacityWatts = 1400; Status = $ok }
    }
    $t["$ch/ThermalSubsystem"] = [ordered]@{ '@odata.id' = "$ch/ThermalSubsystem"; Id = 'ThermalSubsystem'; Fans = L "$ch/ThermalSubsystem/Fans"; ThermalMetrics = L "$ch/ThermalSubsystem/ThermalMetrics"; Status = $ok }
    Collection $t "$ch/ThermalSubsystem/Fans" @("$ch/ThermalSubsystem/Fans/Fan.Embedded.1A") 'Fan Collection'
    $t["$ch/ThermalSubsystem/Fans/Fan.Embedded.1A"] = [ordered]@{ '@odata.id' = "$ch/ThermalSubsystem/Fans/Fan.Embedded.1A"; Id = 'Fan.Embedded.1A'; Name = 'System Board Fan1A'; SpeedPercent = [ordered]@{ Reading = 40; SpeedRPM = 7000 }; Status = $ok }
    $t["$ch/ThermalSubsystem/ThermalMetrics"] = [ordered]@{ '@odata.id' = "$ch/ThermalSubsystem/ThermalMetrics"; Id = 'ThermalMetrics'; TemperatureReadingsCelsius = @([ordered]@{ DeviceName = 'System Board Inlet Temp'; Reading = 22 }) }
    Collection $t "$ch/Sensors" @("$ch/Sensors/SystemBoardInletTemp", "$ch/Sensors/PS1Voltage") 'Sensor Collection'
    $t["$ch/Sensors/SystemBoardInletTemp"] = [ordered]@{ '@odata.id' = "$ch/Sensors/SystemBoardInletTemp"; Id = 'SystemBoardInletTemp'; Name = 'System Board Inlet Temp'; Reading = 22; ReadingUnits = 'Cel'; ReadingType = 'Temperature'; Thresholds = [ordered]@{ UpperCritical = [ordered]@{ Reading = 42 }; UpperCaution = [ordered]@{ Reading = 38 } }; Status = $ok }
    $t["$ch/Sensors/PS1Voltage"] = [ordered]@{ '@odata.id' = "$ch/Sensors/PS1Voltage"; Id = 'PS1Voltage'; Name = 'PS1 Voltage 1'; Reading = 230; ReadingUnits = 'V'; ReadingType = 'Voltage'; Status = $ok }
    return $t
}

function Write-Tree([string]$Name, $Tree) {
    $dir = Join-Path $OutputRoot $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $json = $Tree | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText((Join-Path $dir 'tree.json'), $json + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Information "$Name : $($Tree.Count) entries" -InformationAction Continue
}

$classic = New-ClassicTree
Write-Tree 'idrac9-ax760-synthetic' $classic
Write-Tree 'idrac9-newschema-synthetic' (New-NewSchemaTree $classic)
