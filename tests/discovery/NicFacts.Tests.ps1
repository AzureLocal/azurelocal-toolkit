#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The hardware facts hardware discovery writes for every network port (the identity of the adapter in the file): MAC, slot, port index, PCI location, vendor, model, speed, RDMA.
# The Redfish core carries them for any vendor through the same keys; a vendor adapter only fills them through its hooks. Fakes only (the synthetic Dell tree and a fake vendor adapter);
# no BMC, node or Azure resource is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/discovery/NicFacts.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks run in module scope and read the fake BMC through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test values only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake adapter hooks take the parameters of the real ones.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    . (Join-Path $PSScriptRoot 'RedfishFakeBmc.ps1')
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')) -Force
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishDell.psm1')) -Force
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'idrac-management', 'AzlDellRedfish.psm1')) -Force
    Import-Module powershell-yaml
    $script:Cred = [pscredential]::new('doc-user', (ConvertTo-SecureString 'doc-pass-123' -AsPlainText -Force))
    $script:Schema = Get-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $script:AdapterKeys = @($script:Schema['$defs']['network_adapter']['properties'].Keys)

    function Invoke-Scan { Invoke-AzlRedfishDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary -RetryDelaySeconds 0 }
    function Get-Port { param($Report) @($Report.network.adapters | ForEach-Object { $_.ports } | ForEach-Object { $_ }) }
    function Get-ProposedPort {
        param($Report)
        $view = ConvertTo-AzlDiscoveryLegacyView -Report $Report
        $view['NodeName'] = 'node-1'
        $yaml = ConvertTo-AzlDiscoveryProposal -Item @([pscustomobject]@{ NodeName = 'node-1'; Discovery = $view; ManagementPort = ''; ExistingManagementMac = '' })
        [pscustomobject]@{ View = $view; Text = $yaml; Ports = @((ConvertFrom-Yaml $yaml -Ordered).nodes[0].network_adapters) }
    }
}

Describe 'Dell discovery: the facts of every port' {
    BeforeAll {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $script:Report = Invoke-Scan
        $script:Proposed = Get-ProposedPort $script:Report
    }
    AfterAll { Remove-FakeBmc }
    It 'gives every port a MAC, a slot, a port index and a vendor (the identity of the adapter)' {
        $ports = Get-Port $script:Report
        $ports.Count | Should -BeGreaterThan 3
        foreach ($p in $ports) {
            $p.mac | Should -Match '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'
            $p.slot | Should -Not -BeNullOrEmpty
            $p.portIndex | Should -BeOfType [int]
            $p.portIndex | Should -BeGreaterThan 0
        }
    }
    It 'writes the same facts in the proposed file, one entry per port, MAC first and keyed by slot and port, not by an OS name' {
        $script:Proposed.Ports.Count | Should -Be (Get-Port $script:Report).Count
        foreach ($p in $script:Proposed.Ports) {
            $p.mac_address | Should -Match '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'
            $p.Contains('slot') | Should -BeTrue
            $p.Contains('port_index') | Should -BeTrue
            $p.port_index | Should -BeOfType [int]
            $p.name | Should -Match '^(Slot \d+ Port \d+|Embedded NIC \d+|Integrated NIC \d+ Port \d+)$' -Because 'the key comes from the slot and the port the BMC reports'
        }
        ($script:Proposed.Ports | Where-Object name -eq 'Slot 3 Port 1').port_index | Should -Be 1
        ($script:Proposed.Ports | Where-Object name -eq 'Slot 3 Port 1').vendor | Should -Not -BeNullOrEmpty
    }
    It 'writes a speed in Gbit/s (the link speed now, or the highest the port supports when it has no link) and never an RDMA value the BMC did not report' {
        $withSpeed = @($script:Proposed.Ports | Where-Object { $_.Contains('speed_gbps') })
        $withSpeed.Count | Should -BeGreaterThan 0
        foreach ($p in $withSpeed) { $p.speed_gbps | Should -BeGreaterThan 0 }
        @($script:Proposed.Ports | Where-Object { $_.Contains('rdma') }).Count | Should -Be 0
    }
    It 'writes only keys the schema knows for a port' {
        foreach ($p in $script:Proposed.Ports) { foreach ($k in $p.Keys) { $script:AdapterKeys | Should -Contain $k -Because "$k is a key of nodes[].network_adapters[]" } }
    }
    It 'writes no pci_location when the BMC does not report one' {
        @($script:Proposed.Ports | Where-Object { $_.Contains('pci_location') }).Count | Should -Be 0
    }
}

Describe 'Dell discovery: the PCI location when the iDRAC reports it (OEM data)' {
    BeforeAll {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $f = '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Slot.3/NetworkDeviceFunctions/NIC.Slot.3-1-1'
        $res = Get-FakeResource $f
        $res['Oem'] = @{ Dell = @{ DellNIC = @{ BusNumber = 59; DeviceNumber = 0; FunctionNumber = 1 } } }
        Set-FakeResource $f $res
        $script:Report = Invoke-Scan
        $script:Proposed = Get-ProposedPort $script:Report
    }
    AfterAll { Remove-FakeBmc }
    It 'carries bus, device and function for that port and only that port' {
        $p = Get-Port $script:Report | Where-Object name -eq 'Slot 3 Port 1'
        $p.pciLocation.bus | Should -Be 59
        $p.pciLocation.device | Should -Be 0
        $p.pciLocation.function | Should -Be 1
        @(Get-Port $script:Report | Where-Object { $_.pciLocation }).Count | Should -Be 1
    }
    It 'writes it into the proposed file as pci_location' {
        $entry = $script:Proposed.Ports | Where-Object name -eq 'Slot 3 Port 1'
        $entry.pci_location.bus | Should -Be 59
        $entry.pci_location.function | Should -Be 1
    }
}

Describe 'Another vendor fills the same keys through the adapter contract' {
    BeforeAll {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        # A fake vendor adapter ("Acme"): its own port naming and its own hooks for the PCI location and the RDMA capability. The core and the rest of the pipeline do not change.
        Mock -ModuleName AzlRedfishCore Get-AzlRedfishAdapter {
            [pscustomobject]@{
                Vendor = 'Acme'; Name = 'Acme BMC'
                FallbackPaths = @{ System = '/redfish/v1/Systems/System.Embedded.1'; Chassis = '/redfish/v1/Chassis/System.Embedded.1'; Manager = '/redfish/v1/Managers/iDRAC.Embedded.1' }
                PortLabel = { param($Adapter, $Port, $Ordinal) [pscustomobject]@{ Name = "PCIe-$($Adapter.Id)-P$Ordinal"; Slot = "PCIe-$($Adapter.Id)"; PortNumber = "$Ordinal" } }
                IsGenericModel = $null
                Hooks = [ordered]@{
                    NicPciLocation = { param($Context, $Function) [ordered]@{ bus = 10; device = 2; function = 3 } }
                    NicRdma = { param($Context, $Function, $Adapter) 'roce_v2' }
                }
            }
        }
        $script:Report = Invoke-AzlRedfishDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Vendor Dell -Detail Summary -RetryDelaySeconds 0
        $script:Proposed = Get-ProposedPort $script:Report
    }
    AfterAll { Remove-FakeBmc }
    It 'reports PCI location and RDMA on every port, through the hooks' {
        foreach ($p in Get-Port $script:Report) {
            $p.pciLocation.bus | Should -Be 10
            $p.rdma | Should -Be 'roce_v2'
            $p.portIndex | Should -BeOfType [int]
        }
    }
    It 'names the ports the vendor way and still gives the file the same keys' {
        foreach ($p in $script:Proposed.Ports) {
            $p.name | Should -Match '^PCIe-'
            $p.pci_location.device | Should -Be 2
            $p.rdma | Should -Be 'roce_v2'
            $p.Contains('port_index') | Should -BeTrue
            $p.Contains('mac_address') | Should -BeTrue
            foreach ($k in $p.Keys) { $script:AdapterKeys | Should -Contain $k }
        }
    }
}

Describe 'A vendor adapter without hooks still gives the identity of the adapter' {
    BeforeAll {
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        Mock -ModuleName AzlRedfishCore Get-AzlRedfishAdapter {
            [pscustomobject]@{ Vendor = 'Plain'; Name = 'Plain BMC'; FallbackPaths = @{ System = '/redfish/v1/Systems/System.Embedded.1'; Chassis = '/redfish/v1/Chassis/System.Embedded.1'; Manager = '/redfish/v1/Managers/iDRAC.Embedded.1' }; PortLabel = $null; IsGenericModel = $null; Hooks = [ordered]@{} }
        }
        $script:Report = Invoke-AzlRedfishDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Vendor Dell -Detail Summary -RetryDelaySeconds 0
        $script:Proposed = Get-ProposedPort $script:Report
    }
    AfterAll { Remove-FakeBmc }
    It 'keeps MAC, slot, port index and model from the standard Redfish resources and leaves PCI location and RDMA empty' {
        foreach ($p in $script:Proposed.Ports) {
            $p.mac_address | Should -Match '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'
            $p.Contains('slot') | Should -BeTrue
            $p.Contains('port_index') | Should -BeTrue
            $p.Contains('pci_location') | Should -BeFalse
            $p.Contains('rdma') | Should -BeFalse
        }
    }
}
