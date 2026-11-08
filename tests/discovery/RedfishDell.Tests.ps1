#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the Dell iDRAC adapter (scripts/common/redfish/AzlRedfishDell.psm1) through the core, against the SYNTHETIC Dell
# fixture trees in tests/fixtures/redfish/dell (not real captures; documentation values only). The two lab defects are covered
# here: port naming from the Port resource, and the embedded card model (never a generic Dell label such as
# 'Network Adapter View'). No BMC, node or Azure resource is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/discovery

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks run in module scope and read the fake BMC through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test values only.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    . (Join-Path $PSScriptRoot 'RedfishFakeBmc.ps1')
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')) -Force
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishDell.psm1')) -Force
    $script:Cred = [pscredential]::new('doc-user', (ConvertTo-SecureString 'doc-pass-123' -AsPlainText -Force))
    function Invoke-Scan {
        param([string]$Detail = 'Full')
        Invoke-AzlRedfishDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail $Detail -RetryDelaySeconds 0
    }
    function Get-Port { param($Report) @($Report.network.adapters | ForEach-Object { $_.ports } | ForEach-Object { $_ }) }
    function Get-Walk {
        # Every string value of the report outside raw and settings (values there are the BMC's own).
        param($Node, [string]$Path = '')
        if ($null -eq $Node) { return }
        if ($Node -is [string]) { [pscustomobject]@{ Path = $Path; Value = $Node }; return }
        if ($Node -is [System.Collections.IDictionary]) { foreach ($k in $Node.Keys) { if ($Path -eq '' -and $k -in 'raw', 'settings') { continue }; Get-Walk $Node[$k] "$Path.$k" }; return }
        if ($Node -is [System.Collections.IEnumerable]) { $i = 0; foreach ($e in $Node) { Get-Walk $e "$Path[$i]"; $i++ } }
    }
}

Describe 'Get-AzlDellPortLabel' {
    It 'labels adapter <Adapter> / port <Port> as <Name>' -ForEach @(
        @{ Adapter = 'NIC.Slot.3'; Port = 'NIC.Slot.3-2-1'; Phys = $null; Name = 'Slot 3 Port 2'; Slot = 'Slot 3' }
        @{ Adapter = 'NIC.Slot.3'; Port = 'NIC.Slot.3-1'; Phys = '1'; Name = 'Slot 3 Port 1'; Slot = 'Slot 3' }
        @{ Adapter = 'NIC.Embedded.2'; Port = 'NIC.Embedded.2-1-1'; Phys = $null; Name = 'Embedded NIC 2'; Slot = 'Embedded' }
        # The lab defect: ONE embedded adapter carries both LOM ports; the NIC number is in the PORT id and PhysicalPortNumber.
        @{ Adapter = 'NIC.Embedded.1'; Port = 'NIC.Embedded.1-1'; Phys = '1'; Name = 'Embedded NIC 1'; Slot = 'Embedded' }
        @{ Adapter = 'NIC.Embedded.1'; Port = 'NIC.Embedded.2-1'; Phys = '2'; Name = 'Embedded NIC 2'; Slot = 'Embedded' }
        @{ Adapter = 'NIC.Embedded.1'; Port = 'NIC.Embedded.2-1'; Phys = $null; Name = 'Embedded NIC 2'; Slot = 'Embedded' }
        @{ Adapter = 'NIC.Integrated.1'; Port = 'NIC.Integrated.1-2-1'; Phys = $null; Name = 'Integrated NIC 1 Port 2'; Slot = 'Integrated 1' }
        @{ Adapter = 'NIC.Slot.3'; Port = 'weird'; Phys = '2'; Name = 'Slot 3 Port 2'; Slot = 'Slot 3' }
        @{ Adapter = 'Odd.Adapter'; Port = 'Odd.Port.1'; Phys = $null; Name = 'Odd.Port.1'; Slot = 'Odd.Adapter' }
    ) {
        $l = Get-AzlDellPortLabel -AdapterId $Adapter -PortId $Port -PhysicalPortNumber $Phys
        $l.Name | Should -Be $Name
        $l.Slot | Should -Be $Slot
    }
}

Describe 'Test-AzlDellGenericLabel' {
    It '<Text> is a generic Dell label, not a model' -ForEach @(
        @{ Text = 'Network Adapter View' }, @{ Text = 'network adapter view' }, @{ Text = 'Network Adapter' }, @{ Text = 'NIC in Slot 3' }, @{ Text = 'NIC in Slot 3 Port 2' }
        @{ Text = 'Embedded NIC 1' }, @{ Text = 'Embedded NIC 2 Port 1' }, @{ Text = 'Integrated NIC 1' }, @{ Text = 'NIC.Embedded.1' }, @{ Text = 'NIC.Slot.3-1-1' }
        @{ Text = 'Network Adapter - NIC.Embedded.1' }, @{ Text = 'Network Port - NIC.Slot.3-1' }, @{ Text = '' }, @{ Text = '   ' }
    ) { Test-AzlDellGenericLabel -Text $Text | Should -BeTrue }
    It '<Text> is a real model' -ForEach @(
        @{ Text = 'MLNX 100GbE 2P ConnectX6 Adpt' }, @{ Text = 'Broadcom NetXtreme Gigabit Ethernet (BCM5720)' }, @{ Text = 'Broadcom Gigabit Ethernet BCM5720' }, @{ Text = 'Intel(R) Ethernet 25G 2P E810-XXV OCP' }
    ) { Test-AzlDellGenericLabel -Text $Text | Should -BeFalse }
}

Describe 'Dell scan of the synthetic AX-760 fixture' {
    BeforeAll {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $script:Full = Invoke-Scan -Detail Full
        $script:Sum = Invoke-Scan -Detail Summary
    }
    AfterAll { Remove-FakeBmc }

    Context 'schema' {
        It 'has the schema 2.0 top-level blocks' {
            $script:Full.schemaVersion | Should -Be '2.0'
            foreach ($k in 'tool', 'collectedAt', 'durationSeconds', 'bmcAddress', 'detail', 'vendor', 'identity', 'bmc', 'system', 'processors', 'memory', 'pcie', 'gpus', 'network', 'storage', 'firmware', 'settings', 'health', 'events', 'raw', 'capabilities', 'readErrors', 'warnings') {
                $script:Full.Keys | Should -Contain $k
            }
            $script:Full.detail | Should -Be 'full'
            $script:Sum.detail | Should -Be 'summary'
        }
        It 'survives a JSON round trip' {
            $json = $script:Full | ConvertTo-Json -Depth 40
            $back = $json | ConvertFrom-Json
            $back.schemaVersion | Should -Be '2.0'
            @($back.network.adapters).Count | Should -Be 3
        }
        It 'uses null for unknown, never an empty string' {
            $empty = @(Get-Walk $script:Full | Where-Object { $_.Value.Trim().Length -eq 0 })
            $empty.Count | Should -Be 0
        }
        It 'writes MACs as AA:BB:CC:DD:EE:FF' {
            $macs = @(Get-Port $script:Full | ForEach-Object { $_.mac }) + @($script:Full.bmc.mac)
            foreach ($m in $macs) { $m | Should -Match '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' }
        }
    }

    Context 'identity' {
        It 'takes the service tag from the SKU and offers every serial a voucher might use' {
            $script:Full.identity.serviceTag | Should -Be 'DOCTAG1'
            $script:Full.identity.serialNumber | Should -Be 'DOCSERIAL0001'
            $script:Full.identity.model | Should -Be 'AX-760'
            $script:Full.identity.uuid | Should -Be '00000000-0000-4000-8000-000000000001'
            $script:Full.identity.assetTag | Should -BeNullOrEmpty
            ($script:Full.identity.voucherSerialCandidates | ForEach-Object value) | Should -Contain 'DOCTAG1'
            ($script:Full.identity.voucherSerialCandidates | ForEach-Object value) | Should -Contain 'DOCSERIAL0001'
            $script:Full.identity.expressServiceCode | Should -Be '00000000001'
            $script:Full.identity.chassis.type | Should -Be 'RackMount'
        }
        It 'warns when the SKU is empty' {
            $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
            $sys.SKU = ''
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
            $r = Invoke-Scan -Detail Summary
            $r.identity.serviceTag | Should -BeNullOrEmpty
            ($r.warnings -join ' ') | Should -Match 'SKU'
            Use-FakeBmc
        }
    }

    Context 'BMC' {
        It 'reads the iDRAC, its interface, protocols and certificate' {
            $script:Full.bmc.model | Should -Be '16G Monolithic'
            $script:Full.bmc.firmwareVersion | Should -Be '7.20.30.00'
            $script:Full.bmc.mac | Should -Be '00:00:5E:00:53:01'
            $script:Full.bmc.interfaces[0].ipv4[0].origin | Should -Be 'DHCP'
            $script:Full.bmc.interfaces[0].speedMbps | Should -Be 1000
            $script:Full.bmc.protocols.HTTPS.port | Should -Be 443
            $script:Full.bmc.protocols.SSH.enabled | Should -BeTrue
            $script:Full.bmc.certificates[0].validNotAfter | Should -Be '2036-01-01T00:00:00Z'
        }
        It 'reads the iDRAC attributes with secrets redacted, at Full only' {
            $script:Full.settings.bmc.attributes.'VNCServer.1.Enable' | Should -Be 'Disabled'
            $script:Full.settings.bmc.attributes.'Users.2.Password' | Should -Be '<redacted>'
            $script:Full.settings.bmc.source | Should -Match 'Attributes'
            $script:Sum.settings.bmc.attributes | Should -BeNullOrEmpty
        }
    }

    Context 'network: port naming comes from the Port resource (lab defect 1)' {
        It 'names the two LOM ports Embedded NIC 1 and Embedded NIC 2, never Embedded NIC 1 (2)' {
            $names = @(Get-Port $script:Full | ForEach-Object { $_.name })
            $names | Should -Contain 'Embedded NIC 1'
            $names | Should -Contain 'Embedded NIC 2'
            ($names -join '|') | Should -Not -Match '\(\d\)'
            $names.Count | Should -Be 6
            ($names | Select-Object -Unique).Count | Should -Be 6
        }
        It 'gives each port its MAC, slot, link and speed' {
            $p = @{}; foreach ($x in (Get-Port $script:Full)) { $p[$x.name] = $x }
            $p['Embedded NIC 1'].mac | Should -Be '00:00:5E:00:53:10'
            $p['Embedded NIC 2'].mac | Should -Be '00:00:5E:00:53:11'
            $p['Embedded NIC 2'].id | Should -Be 'NIC.Embedded.2-1'
            $p['Embedded NIC 2'].adapterId | Should -Be 'NIC.Embedded.1'
            $p['Embedded NIC 2'].slot | Should -Be 'Embedded'
            $p['Embedded NIC 2'].portNumber | Should -Be '2'
            $p['Embedded NIC 2'].macSource | Should -Be 'Port'
            $p['Embedded NIC 2'].linkUp | Should -BeTrue
            $p['Embedded NIC 2'].speedMbps | Should -Be 1000
            $p['Embedded NIC 2'].maxSpeedMbps | Should -Be 1000
            $p['Slot 3 Port 1'].mac | Should -Be '00:00:5E:00:53:21'
            $p['Slot 3 Port 1'].speedMbps | Should -Be 100000
            $p['Slot 3 Port 1'].slot | Should -Be 'Slot 3'
            $p['Slot 6 Port 2'].mac | Should -Be '00:00:5E:00:53:32'
            $p['Slot 6 Port 2'].macSource | Should -Be 'Function'
            $p['Slot 6 Port 2'].permanentMac | Should -Be '00:00:5E:00:53:32'
            $p['Slot 6 Port 2'].mtu | Should -Be 9000
        }
        It 'builds ports from functions on firmware that lists only functions' {
            Use-FakeBmc
            foreach ($a in 'NIC.Slot.3', 'NIC.Slot.6') {
                $ad = Get-FakeResource "/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/$a"
                $ad.Remove('NetworkPorts')
                Set-FakeResource "/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/$a" $ad
            }
            $r = Invoke-Scan -Detail Summary
            $names = @(Get-Port $r | ForEach-Object { $_.name })
            $names | Should -Contain 'Slot 6 Port 1'
            $names | Should -Contain 'Slot 3 Port 2'
            (Get-Port $r | Where-Object name -eq 'Slot 6 Port 1').mac | Should -Be '00:00:5E:00:53:31'
            $r.capabilities.areas.network.schemaVariant | Should -Match 'functions-only'
            Use-FakeBmc
        }
        It 'keeps a port that has no MAC and warns instead of dropping it silently' {
            Use-FakeBmc
            $f = '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Slot.6/NetworkDeviceFunctions/NIC.Slot.6-1-1'
            Set-FakeResource $f @{ Id = 'NIC.Slot.6-1-1' }
            $r = Invoke-Scan -Detail Summary
            $port = Get-Port $r | Where-Object name -eq 'Slot 6 Port 1'
            $port.mac | Should -BeNullOrEmpty
            ($r.warnings -join ' ') | Should -Match 'NIC.Slot.6-1 .*no MAC'
            Use-FakeBmc
        }
    }

    Context 'network: the embedded card model is a real model (lab defect 2)' {
        It 'fills the embedded card from the Dell NIC product name, without the MAC suffix' {
            $lom = $script:Full.network.adapters | Where-Object id -eq 'NIC.Embedded.1'
            $lom.model | Should -Be 'Broadcom Gigabit Ethernet BCM5720'
            $lom.modelSource | Should -Be 'dell-nic-oem'
            $lom.manufacturer | Should -Be 'Broadcom Inc. and subsidiaries'
            $lom.firmwarePackage | Should -Be '23.31.1'
        }
        It 'never reports the generic adapter Name (Network Adapter View) as the model' {
            (Get-Walk $script:Full | Where-Object { $_.Path -like '*.model' -or $_.Path -like '*.Model' } | ForEach-Object Value) | Should -Not -Contain 'Network Adapter View'
            ($script:Full.network.adapters | ForEach-Object model) | Should -Not -Contain 'Network Adapter View'
        }
        It 'keeps a real adapter Model as it is' {
            ($script:Full.network.adapters | Where-Object id -eq 'NIC.Slot.3').model | Should -Be 'DOC 100GbE 2P ConnectX6 Adpt'
            ($script:Full.network.adapters | Where-Object id -eq 'NIC.Slot.3').modelSource | Should -Be 'adapter'
        }
        It 'rejects a generic adapter Model and falls through the chain' {
            Use-FakeBmc
            $ad = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Slot.3'
            $ad.Model = 'NIC in Slot 3'
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Slot.3' $ad
            $r = Invoke-Scan -Detail Summary
            $m = $r.network.adapters | Where-Object id -eq 'NIC.Slot.3'
            $m.model | Should -Be 'DOC 100GbE 2P ConnectX6 Adpt'
            $m.modelSource | Should -Be 'pcie-device-description'
            Use-FakeBmc
        }
        It 'falls back to the linked PCIe device when the Dell NIC product name is missing' {
            Use-FakeBmc
            foreach ($n in 1, 2) { Set-FakeResource "/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1/NetworkDeviceFunctions/NIC.Embedded.$n-1-1" @{ Id = "NIC.Embedded.$n-1-1"; Ethernet = @{ MACAddress = "00:00:5E:00:53:1$($n - 1)" } } }
            $r = Invoke-Scan -Detail Summary
            $lom = $r.network.adapters | Where-Object id -eq 'NIC.Embedded.1'
            $lom.model | Should -Be 'Broadcom Gigabit Ethernet BCM5720'
            $lom.modelSource | Should -Be 'pcie-device-description'
            Use-FakeBmc
        }
        It 'falls back to the controller description when the function and the PCIe device give nothing' {
            Use-FakeBmc
            foreach ($n in 1, 2) { Set-FakeResource "/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1/NetworkDeviceFunctions/NIC.Embedded.$n-1-1" @{ Id = "NIC.Embedded.$n-1-1"; Ethernet = @{ MACAddress = "00:00:5E:00:53:1$($n - 1)" } } }
            $ad = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1'
            $ad.Controllers[0].Description = 'Broadcom NetXtreme Gigabit Ethernet (BCM5720)'
            $ad.Controllers[0].Links = @{}
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1' $ad
            $r = Invoke-Scan -Detail Summary
            $lom = $r.network.adapters | Where-Object id -eq 'NIC.Embedded.1'
            $lom.model | Should -Be 'Broadcom NetXtreme Gigabit Ethernet (BCM5720)'
            $lom.modelSource | Should -Be 'controller'
            Use-FakeBmc
        }
        It 'takes the model from the firmware inventory at Full detail (the shape the lab scan showed)' {
            Use-FakeBmc
            foreach ($n in 1, 2) { Set-FakeResource "/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1/NetworkDeviceFunctions/NIC.Embedded.$n-1-1" @{ Id = "NIC.Embedded.$n-1-1"; Ethernet = @{ MACAddress = "00:00:5E:00:53:1$($n - 1)" } } }
            $ad = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1'
            $ad.Controllers[0].Links = @{}
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1' $ad
            $r = Invoke-Scan -Detail Full
            $lom = $r.network.adapters | Where-Object id -eq 'NIC.Embedded.1'
            $lom.model | Should -Be 'Broadcom NetXtreme Gigabit Ethernet (BCM5720)'
            $lom.modelSource | Should -Be 'firmware-inventory'
            ($r.capabilities.oemPaths | Where-Object { $_.path -like '*FirmwareInventory*' -and $_.area -eq 'network' }).basis | Should -Be 'lab-observed'
            Use-FakeBmc
        }
        It 'leaves the model empty and says so in the capability report when nothing names the card' {
            Use-FakeBmc
            foreach ($n in 1, 2) { Set-FakeResource "/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1/NetworkDeviceFunctions/NIC.Embedded.$n-1-1" @{ Id = "NIC.Embedded.$n-1-1"; Ethernet = @{ MACAddress = "00:00:5E:00:53:1$($n - 1)" } } }
            $ad = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1'
            $ad.Controllers[0].Links = @{}
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Embedded.1' $ad
            $r = Invoke-Scan -Detail Summary
            $lom = $r.network.adapters | Where-Object id -eq 'NIC.Embedded.1'
            $lom.model | Should -BeNullOrEmpty
            $lom.modelSource | Should -Be 'none'
            ($r.capabilities.areas.network.notes -join ' ') | Should -Match 'NIC.Embedded.1: no real model found'
            ($r.capabilities.areas.network.notes -join ' ') | Should -Match 'Network Adapter View'
            Use-FakeBmc
        }
    }

    Context 'processors, memory, PCIe and GPUs' {
        It 'reads both CPUs and the memory modules, including an empty slot' {
            @($script:Full.processors).Count | Should -Be 2
            $script:Full.processors[0].cores | Should -Be 32
            $script:Full.processors[0].microcodeVersion | Should -Be '0x2b000461'
            $script:Full.system.processorSummary.count | Should -Be 2
            @($script:Full.memory.modules).Count | Should -Be 5
            @($script:Full.memory.modules | Where-Object present).Count | Should -Be 4
            ($script:Full.memory.modules | Where-Object { -not $_.present }).slot | Should -Be 'DIMM A3'
            $script:Full.memory.totalGiB | Should -Be 256
            $script:Full.memory.modules[0].capacityMiB | Should -Be 65536
        }
        It 'reads the PCIe devices with their functions and derives the GPU' {
            @($script:Full.pcie).Count | Should -Be 3
            $gpu = @($script:Full.gpus)
            $gpu.Count | Should -Be 1
            $gpu[0].name | Should -Be 'Slot 7 GPU'
            $gpu[0].vendorId | Should -Be '0x10de'
            ($script:Full.pcie | Where-Object id -eq '59-0').lanesInUse | Should -Be 16
            ($script:Full.pcie | Where-Object id -eq '59-0').functions[0].classCode | Should -Be '0x020000'
        }
        It 'reads PCIe devices from the Chassis path and records that path (lab defect: the Systems path is a 404 on iDRAC9)' {
            Use-FakeBmc
            $global:AzlTestBmc.Status['/redfish/v1/Systems/System.Embedded.1/PCIeDevices'] = 404
            $r = Invoke-Scan -Detail Full
            @($r.pcie).Count | Should -Be 3
            $r.capabilities.areas.pcie.status | Should -Be 'ok'
            $r.capabilities.areas.pcie.schemaVariant | Should -Be 'Chassis/PCIeDevices'
            $r.capabilities.areas.pcie.paths | Should -Contain '/redfish/v1/Chassis/System.Embedded.1/PCIeDevices'
            @($r.readErrors | Where-Object path -like '*Systems/System.Embedded.1/PCIeDevices').Count | Should -Be 0
            @(Get-FakeCall | Where-Object Path -eq '/redfish/v1/Systems/System.Embedded.1/PCIeDevices').Count | Should -Be 0
            Use-FakeBmc
        }
        It 'finds the Chassis collection by its well-known path when the chassis does not link it' {
            Use-FakeBmc
            $ch = Get-FakeResource '/redfish/v1/Chassis/System.Embedded.1'
            $ch.Remove('PCIeDevices')
            Set-FakeResource '/redfish/v1/Chassis/System.Embedded.1' $ch
            $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
            $sys.Links.Remove('PCIeDevices')
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
            $r = Invoke-Scan -Detail Full
            @($r.pcie).Count | Should -Be 3
            $r.capabilities.areas.pcie.schemaVariant | Should -Be 'Chassis/PCIeDevices'
            Use-FakeBmc
        }
        It 'falls back to the Systems path when the Chassis has none' {
            Use-FakeBmc
            $ch = Get-FakeResource '/redfish/v1/Chassis/System.Embedded.1'
            $ch.Remove('PCIeDevices')
            Set-FakeResource '/redfish/v1/Chassis/System.Embedded.1' $ch
            Remove-FakeResource '/redfish/v1/Chassis/System.Embedded.1/PCIeDevices'
            $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
            $sys.Links.Remove('PCIeDevices')
            $sys.PCIeDevices = @{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1/PCIeDevices' }
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1/PCIeDevices' @{ Members = @(@{ '@odata.id' = '/redfish/v1/Chassis/System.Embedded.1/PCIeDevices/59-0' }) }
            $r = Invoke-Scan -Detail Full
            @($r.pcie).Count | Should -Be 1
            $r.capabilities.areas.pcie.schemaVariant | Should -Be 'Systems/PCIeDevices'
            Use-FakeBmc
        }
        It 'reports PCIe as notSupported (both paths tried) when neither answers' {
            Use-FakeBmc
            $ch = Get-FakeResource '/redfish/v1/Chassis/System.Embedded.1'
            $ch.Remove('PCIeDevices')
            Set-FakeResource '/redfish/v1/Chassis/System.Embedded.1' $ch
            Remove-FakeResource '/redfish/v1/Chassis/System.Embedded.1/PCIeDevices'
            $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
            $sys.Links.Remove('PCIeDevices')
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
            $r = Invoke-Scan -Detail Full
            @($r.pcie).Count | Should -Be 0
            $r.capabilities.areas.pcie.status | Should -Be 'notSupported'
            (@($r.readErrors | Where-Object area -eq 'pcie') | ForEach-Object path) | Should -Contain '/redfish/v1/Chassis/System.Embedded.1/PCIeDevices'
            (@($r.readErrors | Where-Object area -eq 'pcie') | ForEach-Object path) | Should -Contain '/redfish/v1/Systems/System.Embedded.1/PCIeDevices'
            Use-FakeBmc
        }
        It 'matches PCIe functions listed on the system to their device' {
            Use-FakeBmc
            $dev = Get-FakeResource '/redfish/v1/Chassis/System.Embedded.1/PCIeDevices/59-0'
            $dev.Links.Remove('PCIeFunctions')
            Set-FakeResource '/redfish/v1/Chassis/System.Embedded.1/PCIeDevices/59-0' $dev
            $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
            $sys.PCIeFunctions = @{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1/PCIeFunctions' }
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1/PCIeFunctions' @{ Members = @(@{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1/PCIeFunctions/59-0-0' }) }
            Set-FakeResource '/redfish/v1/Systems/System.Embedded.1/PCIeFunctions/59-0-0' @{ Id = '59-0-0'; DeviceId = '0x101d'; VendorId = '0x15b3'; ClassCode = '0x020000'; Links = @{ PCIeDevice = @{ '@odata.id' = '/redfish/v1/Chassis/System.Embedded.1/PCIeDevices/59-0' } } }
            $r = Invoke-Scan -Detail Full
            ($r.pcie | Where-Object id -eq '59-0').functions[0].id | Should -Be '59-0-0'
            Use-FakeBmc
        }
    }

    Context 'storage and the BOSS boot device' {
        It 'reads controllers, drives and volumes' {
            @($script:Full.storage.controllers).Count | Should -Be 3
            @($script:Full.storage.drives).Count | Should -Be 6
            @($script:Full.storage.volumes).Count | Should -Be 5
            ($script:Full.storage.drives | Where-Object id -like 'Disk.Bay.0*').serialNumber | Should -Be 'DOCDRV0000'
            ($script:Full.storage.drives | Where-Object id -like 'Disk.Bay.0*').capacityBytes | Should -Be 3840755982336
            ($script:Full.storage.drives | Where-Object id -like 'Disk.Bay.0*').mediaType | Should -Be 'SSD'
            ($script:Full.storage.drives | Where-Object id -like 'Disk.Bay.0*').predictedLifeLeftPercent | Should -Be 100
        }
        It 'finds the BOSS card, marks its drives as boot drives, and sees its virtual disk' {
            $b = $script:Full.storage.bootDevice
            $b.kind | Should -Be 'boss'
            $b.controllerId | Should -Be 'BOSS.SL.12-1'
            $b.detection | Should -Be 'name'
            @($b.driveIds).Count | Should -Be 2
            $b.hasVirtualDisk | Should -BeTrue
            $b.needsVirtualDisk | Should -BeFalse
            $b.volumeId | Should -Be 'Disk.Virtual.0:BOSS.SL.12-1'
            ($script:Full.storage.controllers | Where-Object id -eq 'BOSS.SL.12-1').isBootController | Should -BeTrue
            @($script:Full.storage.drives | Where-Object isBoot).Count | Should -Be 2
            ($script:Full.storage.volumes | Where-Object id -like 'Disk.Virtual.0*').raidType | Should -Be 'RAID1'
        }
        It 'says a BOSS card without a virtual disk needs one' {
            Use-FakeBmc
            $vols = '/redfish/v1/Systems/System.Embedded.1/Storage/BOSS.SL.12-1/Volumes'
            Set-FakeResource $vols @{ Members = @() }
            $r = Invoke-Scan -Detail Summary
            $r.storage.bootDevice.hasVirtualDisk | Should -BeFalse
            $r.storage.bootDevice.needsVirtualDisk | Should -BeTrue
            Use-FakeBmc
        }
        It 'reports no boot device when there is no BOSS, and never takes the onboard SATA controller for one' {
            Use-FakeBmc
            $st = '/redfish/v1/Systems/System.Embedded.1/Storage'
            Set-FakeResource $st @{ Members = @(@{ '@odata.id' = "$st/CPU.1" }, @{ '@odata.id' = "$st/AHCI.Embedded.1-1" }) }
            $r = Invoke-Scan -Detail Summary
            $r.storage.bootDevice.kind | Should -BeNullOrEmpty
            $r.storage.bootDevice.detection | Should -Be 'no-boss-found'
            $r.storage.bootDevice.needsVirtualDisk | Should -BeFalse
            Use-FakeBmc
        }
        It 'finds a BOSS reported as AHCI.Slot by controller id' {
            Use-FakeBmc
            $st = '/redfish/v1/Systems/System.Embedded.1/Storage'
            $b = Get-FakeResource "$st/BOSS.SL.12-1"
            $b.Name = 'Storage controller'; $b.StorageControllers[0].Model = 'M.2 mirror'; $b.Id = 'AHCI.Slot.6-1'
            Set-FakeResource "$st/BOSS.SL.12-1" $b
            $r = Invoke-Scan -Detail Summary
            $r.storage.bootDevice.kind | Should -Be 'boss'
            $r.storage.bootDevice.detection | Should -Be 'controller-id'
            Use-FakeBmc
        }
    }

    Context 'firmware, BIOS, security' {
        It 'reads the firmware inventory with a category and the installed / current / previous state' {
            @($script:Full.firmware).Count | Should -Be 12
            ($script:Full.firmware | Where-Object id -like 'Previous-*').entryState | Should -Be 'previous'
            ($script:Full.firmware | Where-Object id -like 'Current-*').entryState | Should -Be 'current'
            ($script:Full.firmware | Where-Object id -like 'Installed-*' | Select-Object -First 1).entryState | Should -Be 'installed'
            ($script:Full.firmware | Where-Object { $_.id -like 'Installed-*__BIOS*' }).category | Should -Be 'bios'
            ($script:Full.firmware | Where-Object { $_.id -like 'Installed-*iDRAC*' }).category | Should -Be 'bmc'
            ($script:Full.firmware | Where-Object { $_.id -like 'Installed-*PSU*' }).category | Should -Be 'psu'
            ($script:Full.firmware | Where-Object { $_.id -like 'Installed-*CPLD*' }).category | Should -Be 'cpld'
            ($script:Full.firmware | Where-Object { $_.id -like 'Installed-*Slot.3*' }).category | Should -Be 'nic'
            ($script:Full.firmware | Where-Object { $_.id -like 'Installed-*BOSS*' }).category | Should -Be 'storage'
            ($script:Full.firmware | Where-Object { $_.id -like 'Installed-*GPU*' }).category | Should -Be 'gpu'
        }
        It 'reads BIOS attributes, pending attributes and the virtualization switches' {
            $script:Full.settings.bios.attributes.ProcVirtualization | Should -Be 'Enabled'
            $script:Full.settings.bios.pendingAttributes.ProcCStates | Should -Be 'Enabled'
            $script:Full.settings.bios.registryVersion | Should -Be 'BiosAttributeRegistry2.0.0'
            $script:Full.system.virtualization.vtx | Should -BeTrue
            $script:Full.system.virtualization.sriov | Should -BeTrue
            $script:Full.system.virtualization.iommu | Should -BeNullOrEmpty
            $script:Full.system.virtualization.source | Should -Be 'bios-attributes'
        }
        It 'reads Secure Boot, the TPM and the boot configuration' {
            $script:Full.system.secureBoot.supported | Should -BeTrue
            $script:Full.system.secureBoot.enabled | Should -BeTrue
            $script:Full.system.secureBoot.mode | Should -Be 'DeployedMode'
            $script:Full.system.tpm[0].interfaceType | Should -Be 'TPM2_0'
            $script:Full.system.tpm[0].state | Should -Be 'Enabled'
            $script:Full.system.bootMode | Should -Be 'UEFI'
            @($script:Full.system.boot.order).Count | Should -Be 2
        }
    }

    Context 'sensors, power, thermal and events' {
        It 'reads power supplies, temperatures and fans' {
            $script:Full.health.power.consumedWatts | Should -Be 350
            @($script:Full.health.power.supplies).Count | Should -Be 2
            $script:Full.health.power.supplies[0].serialNumber | Should -Be 'DOCPSU0001'
            $script:Full.health.thermal.temperatures[0].readingCelsius | Should -Be 22
            @($script:Full.health.thermal.fans).Count | Should -Be 1
            @($script:Full.health.sensors).Count | Should -Be 3
        }
        It 'summarises the event log without storing it whole' {
            $e = $script:Full.events
            @($e.logServices).Count | Should -Be 2
            $e.summary.total | Should -Be 12
            $e.summary.critical | Should -Be 1
            $e.summary.warning | Should -Be 2
            $e.summary.lastCritical.id | Should -Be '5'
            $e.summary.lastEntryAt | Should -Be '2026-01-01T00:11:00+00:00'
            @($e.summary.sample).Count | Should -Be 10
            $e.summary.sample[0].id | Should -Be '12'
        }
        It 'reads none of this at summary detail' {
            @($script:Sum.firmware).Count | Should -Be 0
            @($script:Sum.pcie).Count | Should -Be 0
            $script:Sum.events.summary | Should -BeNullOrEmpty
            $script:Sum.settings.bios | Should -BeNullOrEmpty
            @($script:Sum.network.adapters).Count | Should -Be 3
            $script:Sum.storage.bootDevice.kind | Should -Be 'boss'
        }
    }

    Context 'raw Dell blocks' {
        It 'keeps the Oem.Dell blocks verbatim under raw.dell, size capped' {
            $script:Full.raw.dell.system.DellSystem.SystemGeneration | Should -Be '16G Monolithic'
            $script:Full.raw.dell.manager.'@odata.type' | Should -Be '#DellManager.v1_0_0.DellManager'
        }
    }
}

Describe 'Dell scan of the newer-schema fixture' {
    BeforeAll {
        Use-FakeBmc -Fixture 'idrac9-newschema-synthetic'
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $script:New = Invoke-Scan -Detail Full
    }
    AfterAll { Remove-FakeBmc }
    It 'names ports from the Port resource and reads MAC, speed and LLDP flag from the newer Port schema' {
        $p = @{}; foreach ($x in (Get-Port $script:New)) { $p[$x.name] = $x }
        $p.Keys.Count | Should -Be 6
        $p['Embedded NIC 2'].mac | Should -Be '00:00:5E:00:53:11'
        $p['Slot 3 Port 1'].speedMbps | Should -Be 100000
        $p['Slot 3 Port 1'].maxSpeedMbps | Should -Be 100000
        $p['Slot 6 Port 1'].mac | Should -Be '00:00:5E:00:53:31'
    }
    It 'is a complete scan' { $script:New.capabilities.complete | Should -BeTrue }
}

Describe 'Fixtures are synthetic and scrubbed' {
    BeforeDiscovery {
        $script:Trees = Get-ChildItem -Path ([System.IO.Path]::Combine($PSScriptRoot, '..', 'fixtures', 'redfish')) -Filter tree.json -Recurse | ForEach-Object { @{ Name = $_.Directory.Name; Path = $_.FullName } }
    }
    It '<Name> is labelled synthetic' -ForEach $script:Trees {
        $t = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $t._fixture.kind | Should -Be 'synthetic'
        $t._fixture.note | Should -Match 'NOT a real capture'
    }
    It '<Name> holds only documentation MACs, IPv4 addresses and serials' -ForEach $script:Trees {
        $text = Get-Content -LiteralPath $Path -Raw
        foreach ($m in [regex]::Matches($text, '(?i)\b[0-9a-f]{2}(?::[0-9a-f]{2}){5}\b')) { $m.Value | Should -Match '^00:00:5E:00:53:' }
        foreach ($m in [regex]::Matches($text, '"(?:Address|Gateway|SubnetMask)":\s*"([\d.]+)"')) { $m.Groups[1].Value | Should -Match '^(192\.0\.2\.|255\.255\.255\.)' }
        foreach ($m in [regex]::Matches($text, '"(?:SerialNumber|SKU)":\s*"([^"]+)"')) { $m.Groups[1].Value | Should -Match '^(DOC|0DOC)' }
        $text | Should -Not -Match '(?i)9W7N704|BW7N704|8W7N704|MXWSJ|C4:CB|58:A2:E1|SJC5T|NDC5N|tplabs|tierpoint'
    }
}
