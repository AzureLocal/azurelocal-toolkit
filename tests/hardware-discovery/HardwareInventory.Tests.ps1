#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The vendor-neutral hardware inventory (scripts/common/redfish/AzlRedfishInventory.psm1 on top of AzlRedfishCore.psm1). Every HTTP call is
# mocked (Invoke-WebRequest in the Redfish core; Invoke-RestMethod must never be called). The fixtures are made-up trees in three
# different shapes (iDRAC-like, iLO-like, AMI/ODM-like); no BMC, node or cluster is contacted.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/hardware-discovery
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks run in module scope and read the fake BMCs through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test values only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes and files in TestDrive.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    . (Join-Path $PSScriptRoot 'HardwareFixtures.ps1')
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishInventory.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    $script:Cred = [pscredential]::new('admin-test', (ConvertTo-SecureString ([guid]::NewGuid().ToString()) -AsPlainText -Force))

    function Read-Node([string]$BmcHost, [string]$Name = 'node-1') {
        $report = Invoke-AzlRedfishDiscovery -BmcAddress $BmcHost -Credential $script:Cred -Vendor None -Detail Inventory -RetryDelaySeconds 0
        return @{ Report = $report; Node = (ConvertTo-AzlHardwareInventoryNode -Report $report -Name $Name) }
    }
    function New-Storage([object[]]$Drive, [object[]]$Volume = @()) { [ordered]@{ drives = $Drive; volumes = $Volume; controllers = @() } }
    function New-Drive([string]$Id, [string]$Media, [string]$Protocol, [string]$State = 'Enabled', [double]$Bytes = 1e12) {
        [ordered]@{ id = $Id; controllerId = 'C1'; model = 'M'; serialNumber = "S-$Id"; firmwareVersion = 'F'; capacityBytes = $Bytes; mediaType = $Media; protocol = $Protocol; health = [ordered]@{ health = 'OK'; state = $State } }
    }
}

Describe 'the Redfish core reads the standard resources only' {
    BeforeEach {
        Use-FakeBmcSet @{ 'dell.test' = (Get-DellShapeTree); 'hpe.test' = (Get-HpeShapeTree); 'ami.test' = (Get-AmiShapeTree) }
        Mock Invoke-WebRequest -ModuleName AzlRedfishCore -MockWith $script:HwResponder
        Mock Invoke-RestMethod -ModuleName AzlRedfishCore { throw 'Invoke-RestMethod must not be called.' }
    }
    AfterAll { Remove-FakeBmcSet }

    It 'reads <Name> without a vendor adapter, a vendor path or a write' -ForEach @(
        @{ Name = 'an iDRAC-shaped BMC'; Bmc = 'dell.test' }, @{ Name = 'an iLO-shaped BMC'; Bmc = 'hpe.test' }, @{ Name = 'an AMI-shaped BMC'; Bmc = 'ami.test' }
    ) {
        $r = Read-Node $Bmc
        $r.Report.capabilities.vendorAdapter | Should -Be 'none'
        @($r.Report.capabilities.oemPaths).Count | Should -Be 0
        $calls = @($global:AzlHwBmc.Calls)
        $calls.Count | Should -BeGreaterThan 10
        @($calls | Where-Object { $_.Method -ne 'Get' }).Count | Should -Be 0
        @($calls | Where-Object { $_.Path -cmatch '/Oem|Dell|Hpe|Lenovo|Ami' }).Count | Should -Be 0
        @($calls | Where-Object { $_.Path -cmatch '/(Bios|LogServices|Thermal|Power|Sensors)' }).Count | Should -Be 0 -Because 'Inventory detail does not read BIOS attributes, sensors or logs'
        Should -Invoke Invoke-RestMethod -ModuleName AzlRedfishCore -Times 0 -Exactly
    }

    It 'does not stop at a vendor the old discovery had no adapter for, and still says what it detected' {
        (Read-Node 'hpe.test').Node.vendor.detected | Should -Be 'Hpe'
        (Read-Node 'ami.test').Node.vendor.detected | Should -Be 'Ami'
        (Read-Node 'dell.test').Node.vendor.detected | Should -Be 'Dell'
    }

    It 'keeps the older behaviour for -Vendor Auto (Dell only), so the Dell proposal flow is unchanged' {
        { Invoke-AzlRedfishDiscovery -BmcAddress 'hpe.test' -Credential $script:Cred -Vendor Auto -Detail Summary -RetryDelaySeconds 0 } | Should -Throw '*Unsupported vendor*'
    }
}

Describe 'the inventory of a node' {
    BeforeEach {
        Use-FakeBmcSet @{ 'dell.test' = (Get-DellShapeTree); 'hpe.test' = (Get-HpeShapeTree); 'ami.test' = (Get-AmiShapeTree) }
        Mock Invoke-WebRequest -ModuleName AzlRedfishCore -MockWith $script:HwResponder
    }
    AfterAll { Remove-FakeBmcSet }

    Context 'an iDRAC-shaped BMC' {
        BeforeEach { $script:N = (Read-Node 'dell.test').Node }

        It 'reports identity, processors, memory, BIOS and BMC' {
            $n = $script:N
            $n.identity.manufacturer | Should -Be 'Dell Inc.'
            $n.identity.model | Should -Be 'Test Model D1'
            $n.identity.serialNumber | Should -Be 'TESTSN-D-0001'
            $n.identity.sku | Should -Be 'TESTSKU1'
            $n.identity.chassisSerialNumber | Should -Be 'TESTCH-D-0001'
            $n.cpu.sockets | Should -Be 2
            $n.cpu.cores | Should -Be 64
            $n.cpu.threads | Should -Be 128
            $n.cpu.model | Should -Be 'Test CPU 100'
            $n.memory.totalGiB | Should -Be 256
            $n.memory.moduleCount | Should -Be 4
            $n.memory.ecc | Should -BeTrue
            $n.bios.version | Should -Be '9.9.9'
            $n.bmc.model | Should -Be '16G Monolithic'
            $n.bmc.firmwareVersion | Should -Be '7.10.50.00'
            $n.bmc.mac | Should -Be '00:00:5E:00:53:01'
        }

        It 'reports the TPM, Secure Boot and the firmware inventory' {
            $script:N.tpm.present | Should -BeTrue
            $script:N.tpm.modules[0].version | Should -Be '2.0'
            $script:N.tpm.modules[0].firmwareVersion | Should -Be '7.2.3.1'
            $script:N.secureBoot | Should -BeTrue
            @($script:N.firmware).Count | Should -Be 3
            (@($script:N.firmware | Where-Object category -EQ 'bios')[0]).version | Should -Be '9.9.9'
        }

        It 'classes the drives: the boot mirror is excluded, NVMe is cache, HDD is capacity' {
            $d = @($script:N.drives)
            $d.Count | Should -Be 12
            @($d | Where-Object role -EQ 'excluded').Count | Should -Be 2
            @($d | Where-Object { $_.role -eq 'excluded' } | ForEach-Object roleReason) | Should -Match 'RAID1'
            @($d | Where-Object role -EQ 'cache' | ForEach-Object mediaType) | Should -Not -Contain 'HDD'
            @($d | Where-Object role -EQ 'cache').Count | Should -Be 4
            @($d | Where-Object role -EQ 'capacity').Count | Should -Be 6
            $script:N.driveSummary.cacheMedia | Should -Be 'NVMe'
            $nvme = $d | Where-Object id -EQ 'NVMe.0'
            $nvme.mediaType | Should -Be 'NVMe'
            $nvme.bus | Should -Be 'NVMe'
            $nvme.sizeTB | Should -Be 1.6
            $nvme.blockSizeBytes | Should -Be 4096
            ($d | Where-Object id -EQ 'HDD.0').mediaType | Should -Be 'HDD'
            ($d | Where-Object id -EQ 'HDD.0').sizeTB | Should -Be 8
        }

        It 'lists the network ports in the BMC order with normalised MAC addresses and the port number' {
            $p = @($script:N.network.ports)
            $p.Count | Should -Be 4
            @($p.order) | Should -Be @(1, 2, 3, 4)
            @($p.adapter) | Should -Be @('NIC.Embedded.1', 'NIC.Embedded.1', 'NIC.Slot.3', 'NIC.Slot.3')
            @($p.portNumber) | Should -Be @(1, 2, 1, 2)
            @($p.mac) | Should -Be @('00:00:5E:00:53:10', '00:00:5E:00:53:11', '00:00:5E:00:53:21', '00:00:5E:00:53:22')
            $p[2].model | Should -Be 'Test 25G Card'
            $p[2].firmware | Should -Be '22.31.6'
            $p[2].speedMbps | Should -Be 25000
            $p[0].linkStatus | Should -Be 'Up'
        }

        It 'reports no GPU as a count of zero, not as "not reported"' {
            $script:N.gpu.count | Should -Be 0
        }
    }

    Context 'an iLO-shaped BMC (newer Ports schema, GPU as a processor, NVMe only)' {
        BeforeEach { $script:N = (Read-Node 'hpe.test').Node }

        It 'reads the controller from the Controllers link and the drives behind it' {
            @($script:N.drives).Count | Should -Be 8
            @($script:N.drives | Where-Object role -EQ 'capacity').Count | Should -Be 8
            @($script:N.drives | Where-Object role -EQ 'cache').Count | Should -Be 0
            $script:N.driveSummary.cacheMedia | Should -Be 'none'
            (@($script:N.drives)[0]).roleReason | Should -Match 'no cache is set up'
        }

        It 'reports the GPU from the processors with its memory' {
            $script:N.gpu.count | Should -Be 1
            $script:N.gpu.devices[0].model | Should -Be 'Test GPU 24G'
            $script:N.gpu.devices[0].memoryGiB | Should -Be 24
            $script:N.gpu.devices[0].source | Should -Be 'Processors'
            $script:N.cpu.sockets | Should -Be 2 -Because 'the GPU is not a socket'
            $script:N.cpu.cores | Should -Be 48
        }

        It 'takes the MAC from the network device function and the speed from the Ports resource' {
            $p = @($script:N.network.ports)
            @($p.mac) | Should -Be @('00:00:5E:00:53:30', '00:00:5E:00:53:32')
            $p[0].speedMbps | Should -Be 25000
            $p[0].adapterLocation | Should -Be 'Slot 1'
            $p[0].firmware | Should -Be '14.32.1010'
        }

        It 'reports the BIOS and BMC version and the TPM' {
            $script:N.bios.version | Should -Be 'T99 v9.99 (01/01/2030)'
            $script:N.bmc.firmwareVersion | Should -Be 'Test BMC 6 v1.60'
            $script:N.tpm.modules[0].version | Should -Be '2.0'
        }
    }

    Context 'an AMI-shaped BMC (adapters under the chassis, little reported)' {
        BeforeEach { $script:N = (Read-Node 'ami.test').Node }

        It 'reads the network adapters from the Chassis' {
            $script:N.network.portCount | Should -Be 2
            $script:N.network.ports[0].adapter | Should -Be 'OCP1'
            $script:N.network.ports[0].model | Should -Be 'Test 10G OCP'
        }

        It 'classes SATA SSD as cache for HDD, and says not reported where the BMC says nothing' {
            @($script:N.drives | Where-Object role -EQ 'cache').Count | Should -Be 2
            $script:N.driveSummary.cacheMedia | Should -Be 'SSD'
            (@($script:N.drives)[0]).blockSizeBytes | Should -Be 'not reported'
            $script:N.tpm.present | Should -Be 'not reported'
            $script:N.secureBoot | Should -Be 'not reported'
            $script:N.memory.ecc | Should -Be 'not reported'
            $script:N.identity.sku | Should -Be 'not reported'
            $script:N.bios.version | Should -Be 'not reported'
            @($script:N.firmware).Count | Should -Be 0
        }

        It 'lists every "not reported" field by path' {
            $script:N.notReported | Should -Contain 'tpm.present'
            $script:N.notReported | Should -Contain 'memory.ecc'
            $script:N.notReported | Should -Contain 'drives[0].blockSizeBytes'
            $script:N.notReported | Should -Not -Contain 'identity.model'
            @($script:N.notReported | Where-Object { $_ -match 'notReported|readErrors' }).Count | Should -Be 0
        }

        It 'records what could not be read, without stopping' {
            @($script:N.readErrors | Where-Object path -Match 'UpdateService').Count | Should -BeGreaterThan 0
        }
    }

    It 'writes nothing that looks like a secret' {
        $json = (Read-Node 'dell.test').Node | ConvertTo-Json -Depth 20
        $json | Should -Not -Match $script:Cred.GetNetworkCredential().Password
        $json | Should -Not -Match '(?i)authorization|x-auth-token'
    }
}

Describe 'the drive roles' {
    It 'maps media type and protocol to NVMe, SSD or HDD' -ForEach @(
        @{ Media = 'SSD'; Protocol = 'NVMe'; Expected = 'NVMe' }
        @{ Media = $null; Protocol = 'NVMe'; Expected = 'NVMe' }
        @{ Media = 'SSD'; Protocol = 'SATA'; Expected = 'SSD' }
        @{ Media = 'SSD'; Protocol = 'SAS'; Expected = 'SSD' }
        @{ Media = 'HDD'; Protocol = 'SAS'; Expected = 'HDD' }
        @{ Media = 'SMR'; Protocol = 'SATA'; Expected = 'HDD' }
        @{ Media = $null; Protocol = 'SATA'; Expected = $null }
        @{ Media = $null; Protocol = $null; Expected = $null }
    ) {
        Get-AzlDriveMedia -MediaType $Media -Protocol $Protocol | Should -Be $Expected
    }

    It 'follows the Storage Spaces Direct table: <Name>' -ForEach @(
        @{ Name = 'all NVMe: no cache'; Types = @('NVMe', 'NVMe', 'NVMe'); Cache = @(); Capacity = @('NVMe', 'NVMe', 'NVMe'); CacheMedia = 'none' }
        @{ Name = 'all SSD: no cache'; Types = @('SSD', 'SSD'); Cache = @(); Capacity = @('SSD', 'SSD'); CacheMedia = 'none' }
        @{ Name = 'NVMe + SSD: NVMe is cache'; Types = @('NVMe', 'NVMe', 'SSD', 'SSD', 'SSD'); Cache = @('NVMe', 'NVMe'); Capacity = @('SSD', 'SSD', 'SSD'); CacheMedia = 'NVMe' }
        @{ Name = 'NVMe + HDD: NVMe is cache'; Types = @('NVMe', 'HDD', 'HDD'); Cache = @('NVMe'); Capacity = @('HDD', 'HDD'); CacheMedia = 'NVMe' }
        @{ Name = 'SSD + HDD: SSD is cache'; Types = @('SSD', 'SSD', 'HDD', 'HDD'); Cache = @('SSD', 'SSD'); Capacity = @('HDD', 'HDD'); CacheMedia = 'SSD' }
        @{ Name = 'NVMe + SSD + HDD: NVMe is cache for both'; Types = @('NVMe', 'SSD', 'HDD'); Cache = @('NVMe'); Capacity = @('SSD', 'HDD'); CacheMedia = 'NVMe' }
        @{ Name = 'all HDD: capacity only (the file does not judge)'; Types = @('HDD', 'HDD'); Cache = @(); Capacity = @('HDD', 'HDD'); CacheMedia = 'none' }
    ) {
        $drives = @(for ($i = 0; $i -lt $Types.Count; $i++) {
                $t = $Types[$i]
                New-Drive "d$i" $(if ($t -eq 'HDD') { 'HDD' } else { 'SSD' }) $(if ($t -eq 'NVMe') { 'NVMe' } elseif ($t -eq 'SSD') { 'SATA' } else { 'SAS' })
            })
        $r = Get-AzlHardwareDriveList -Storage (New-Storage $drives)
        @($r.Drives | Where-Object role -EQ 'cache' | ForEach-Object mediaType) | Should -Be $Cache
        @($r.Drives | Where-Object role -EQ 'capacity' | ForEach-Object mediaType) | Should -Be $Capacity
        $r.Summary.cacheMedia | Should -Be $CacheMedia
    }

    It 'leaves out a drive that is not present, a RAID member and a drive of unknown type, and says why' {
        $drives = @(
            (New-Drive 'a' 'SSD' 'NVMe'), (New-Drive 'b' 'SSD' 'NVMe'), (New-Drive 'gone' 'SSD' 'NVMe' 'Absent'), (New-Drive 'raid' 'HDD' 'SAS'), (New-Drive 'mystery' $null $null)
        )
        $volumes = @([ordered]@{ id = 'v'; controllerId = 'C1'; raidType = 'RAID5'; driveIds = @('raid') })
        $r = Get-AzlHardwareDriveList -Storage (New-Storage $drives $volumes)
        ($r.Drives | Where-Object id -EQ 'gone').role | Should -Be 'excluded'
        ($r.Drives | Where-Object id -EQ 'gone').roleReason | Should -Match 'not present'
        ($r.Drives | Where-Object id -EQ 'raid').role | Should -Be 'excluded'
        ($r.Drives | Where-Object id -EQ 'raid').roleReason | Should -Match 'RAID5'
        ($r.Drives | Where-Object id -EQ 'mystery').role | Should -Be 'unclassified'
        ($r.Drives | Where-Object id -EQ 'mystery').mediaType | Should -Be 'not reported'
        @($r.Drives | Where-Object role -EQ 'capacity').Count | Should -Be 2
        $r.Summary.excluded | Should -Be 2
        $r.Summary.unclassified | Should -Be 1
    }

    It 'does not exclude a drive that a volume lists with no RAID type (pass-through)' {
        $volumes = @([ordered]@{ id = 'v'; controllerId = 'C1'; raidType = $null; driveIds = @('a') })
        $r = Get-AzlHardwareDriveList -Storage (New-Storage @((New-Drive 'a' 'SSD' 'NVMe')) $volumes)
        ($r.Drives | Where-Object id -EQ 'a').role | Should -Be 'capacity'
    }

    It 'handles a machine with no storage block' {
        $r = Get-AzlHardwareDriveList -Storage $null
        @($r.Drives).Count | Should -Be 0
        $r.Summary.cacheMedia | Should -Be 'none'
    }

    It 'states the rule in the file' {
        $rule = Get-AzlHardwareInventoryRule
        $rule.driveRole | Should -Match 'fastest type \(NVMe, then SSD, then HDD\)'
        $rule.driveRole | Should -Match 'no cache is set up'
        $rule.source | Should -Match 'No vendor \(OEM\) path'
    }
}

Describe 'the symmetry checks across nodes' {
    BeforeEach {
        Use-FakeBmcSet @{ 'dell.test' = (Get-DellShapeTree); 'dell2.test' = (Get-DellShapeTree -Serial 'TESTSN-D-0002' -Sku 'TESTSKU2' -Mac '00:00:5E:00:53:50'); 'hpe.test' = (Get-HpeShapeTree) }
        Mock Invoke-WebRequest -ModuleName AzlRedfishCore -MockWith $script:HwResponder
    }
    AfterAll { Remove-FakeBmcSet }

    It 'finds two identical machines the same' {
        $a = (Read-Node 'dell.test' 'n1').Node
        $b = (Read-Node 'dell2.test' 'n2').Node
        $checks = @(Get-AzlHardwareSymmetry -Node @($a, $b))
        $checks.Count | Should -BeGreaterThan 8
        @($checks | Where-Object { $_.requirement -eq 'required' -and $_.result -ne 'same' }) | Should -BeNullOrEmpty
        @($checks | Where-Object { $_.check -eq 'model' }).values.Keys | Should -Contain 'n1'
    }

    It 'finds machines of two makers different where Microsoft requires the same' {
        $a = (Read-Node 'dell.test' 'n1').Node
        $b = (Read-Node 'hpe.test' 'n2').Node
        $checks = @(Get-AzlHardwareSymmetry -Node @($a, $b))
        foreach ($name in 'manufacturer', 'model', 'processor', 'networkAdapters', 'driveTypeAndCount') { ($checks | Where-Object check -EQ $name).result | Should -Be 'differs' -Because $name }
        ($checks | Where-Object check -EQ 'model').source | Should -Match 'Azure Local system requirements'
    }

    It 'sees a missing drive' {
        $a = (Read-Node 'dell.test' 'n1').Node
        $tree = Get-DellShapeTree
        $tree['/redfish/v1/Systems/System.Embedded.1/Storage/HBA.1'].Drives = @($tree['/redfish/v1/Systems/System.Embedded.1/Storage/HBA.1'].Drives | Select-Object -First 5)
        Use-FakeBmcSet @{ 'dell.test' = (Get-DellShapeTree); 'short.test' = $tree }
        $b = (Read-Node 'short.test' 'n2').Node
        $checks = @(Get-AzlHardwareSymmetry -Node @($a, $b))
        ($checks | Where-Object check -EQ 'driveTypeAndCount').result | Should -Be 'differs'
        ($checks | Where-Object check -EQ 'driveRoles').result | Should -Be 'differs'
        ($checks | Where-Object check -EQ 'driveCapacity').result | Should -Be 'differs'
        ($checks | Where-Object check -EQ 'manufacturer').result | Should -Be 'same'
    }

    It 'says not reported when a node does not give the fact' {
        $a = (Read-Node 'dell.test' 'n1').Node
        $b = (Read-Node 'dell2.test' 'n2').Node
        $b.bios.version = 'not reported'
        ((Get-AzlHardwareSymmetry -Node @($a, $b)) | Where-Object check -EQ 'biosVersion').result | Should -Be 'not reported'
    }

    It 'makes no checks for fewer than two nodes read' {
        $a = (Read-Node 'dell.test' 'n1').Node
        @(Get-AzlHardwareSymmetry -Node @($a)).Count | Should -Be 0
        @(Get-AzlHardwareSymmetry -Node @($a, [ordered]@{ name = 'n2'; status = 'failed' })).Count | Should -Be 0
    }
}

Describe 'the plan against what the BMC reported' {
    BeforeEach {
        Use-FakeBmcSet @{ 'dell.test' = (Get-DellShapeTree); 'ami.test' = (Get-AmiShapeTree) }
        Mock Invoke-WebRequest -ModuleName AzlRedfishCore -MockWith $script:HwResponder
        $script:Dell = (Read-Node 'dell.test' 'n1').Node
    }
    AfterAll { Remove-FakeBmcSet }

    It 'matches the keys that are right and says which differ' {
        $infra = [ordered]@{
            hardware = [ordered]@{
                vendor = 'Dell'; model = 'Test Model D1'; cpu_cores = 64; memory_gib = 512
                gpu = [ordered]@{ enabled = $true; count_per_node = 2; model = 'Some GPU' }
                drives = [ordered]@{ capacity = [ordered]@{ media = 'hdd'; count = 6; size_tb = 8 }; cache = [ordered]@{ media = 'nvme'; count = 2; size_tb = 1.6 } }
            }
        }
        $entry = [ordered]@{ name = 'n1'; serial_number = 'TESTSKU1'; bmc = [ordered]@{ type = 'idrac' } }
        $rows = @(Compare-AzlHardwarePlan -Node $script:Dell -Infrastructure $infra -NodeEntry $entry)
        $by = @{}; foreach ($r in $rows) { $by[$r.key] = $r }
        $by['hardware.vendor'].result | Should -Be 'match'
        $by['hardware.model'].result | Should -Be 'match'
        $by['hardware.cpu_cores'].result | Should -Be 'match'
        $by['hardware.memory_gib'].result | Should -Be 'differs'
        $by['hardware.memory_gib'].found | Should -Be 256
        $by['hardware.gpu.enabled'].result | Should -Be 'differs'
        $by['hardware.gpu.count_per_node'].result | Should -Be 'differs'
        $by['hardware.drives.capacity.media'].result | Should -Be 'match'
        $by['hardware.drives.capacity.count'].result | Should -Be 'match'
        $by['hardware.drives.capacity.size_tb'].result | Should -Be 'match'
        $by['hardware.drives.cache.media'].result | Should -Be 'match'
        $by['hardware.drives.cache.count'].result | Should -Be 'differs'
        $by['hardware.drives.cache.count'].found | Should -Be 4
        $by['nodes[].bmc.type'].result | Should -Be 'match'
        $by['nodes[].serial_number'].result | Should -Be 'match' -Because 'the SKU is one of the serial candidates'
    }

    It 'writes a row only for a key that has a value' {
        @(Compare-AzlHardwarePlan -Node $script:Dell -Infrastructure ([ordered]@{ hardware = [ordered]@{ vendor = 'Dell' } }) -NodeEntry $null).Count | Should -Be 1
        @(Compare-AzlHardwarePlan -Node $script:Dell -Infrastructure ([ordered]@{}) -NodeEntry ([ordered]@{ name = 'n1' })).Count | Should -Be 0
    }

    It 'reports a wrong BMC type and a serial that no field has' {
        $entry = [ordered]@{ name = 'n1'; serial_number = 'NOPE'; bmc = [ordered]@{ type = 'ilo' } }
        $rows = @(Compare-AzlHardwarePlan -Node $script:Dell -Infrastructure ([ordered]@{}) -NodeEntry $entry)
        ($rows | Where-Object key -EQ 'nodes[].bmc.type').result | Should -Be 'differs'
        ($rows | Where-Object key -EQ 'nodes[].serial_number').result | Should -Be 'differs'
    }

    It 'leaves bmc.type other alone' {
        @(Compare-AzlHardwarePlan -Node $script:Dell -Infrastructure ([ordered]@{}) -NodeEntry ([ordered]@{ name = 'n1'; bmc = [ordered]@{ type = 'other' } })).Count | Should -Be 0
    }

    It 'says not reported where the BMC gave nothing' {
        $ami = (Read-Node 'ami.test' 'n2').Node
        $infra = [ordered]@{ hardware = [ordered]@{ drives = [ordered]@{ capacity = [ordered]@{ media = 'hdd'; count = 6; size_tb = 4 } } } }
        $rows = @(Compare-AzlHardwarePlan -Node $ami -Infrastructure $infra -NodeEntry ([ordered]@{ name = 'n2'; serial_number = 'X'; bmc = [ordered]@{ type = 'xcc' } }))
        ($rows | Where-Object key -EQ 'hardware.drives.capacity.size_tb').result | Should -Be 'match'
        ($rows | Where-Object key -EQ 'nodes[].bmc.type').result | Should -Be 'differs'
    }
}
