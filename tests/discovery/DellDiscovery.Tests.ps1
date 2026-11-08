#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for Dell hardware discovery and the iDRAC tools. A fake iDRAC answers from a table of Redfish responses; no BMC,
# node or Azure resource is touched. Values are documentation values (MACs 00:00:5E:00:53:xx, host names under .invalid).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/discovery

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks run in module scope and read the fake iDRAC through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test values only.')]
param()

BeforeDiscovery {
    $repoRoot = (Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    $script:Shipped = @(
        'scripts/common/idrac-management/AzlDellRedfish.psm1'
        'scripts/common/infrastructure/AzlInfrastructureEdit.psm1'
        'scripts/common/discovery/Get-DellServerInventory-FromiDRAC.ps1'
        'scripts/common/idrac-management/Enable-IdracVnc.ps1'
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Invoke-HardwareDiscovery.ps1'
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Get-HardwareDiscovery-Standalone.ps1'
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Update-InfrastructureYml-FromDiscovery.ps1'
        'config/oem/dell-endpoints.md'
    ) | ForEach-Object { @{ Relative = $_; Full = (Join-Path $repoRoot $_) } }
}

BeforeAll {
    $repo = (Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    $script:Redfish = [System.IO.Path]::Combine($repo, 'scripts', 'common', 'idrac-management', 'AzlDellRedfish.psm1')
    Import-Module $script:Redfish -Force
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructureEdit.psm1')) -Force
    Import-Module powershell-yaml
    $task = [System.IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-01-hardware-provisioning', 'task-02-hardware-discovery-via-dell-redfish-api', 'powershell')
    $script:InvokeScript = Join-Path $task 'Invoke-HardwareDiscovery.ps1'
    $script:UpdateScript = Join-Path $task 'Update-InfrastructureYml-FromDiscovery.ps1'
    $script:StandaloneScript = Join-Path $task 'Get-HardwareDiscovery-Standalone.ps1'
    $script:VncScript = [System.IO.Path]::Combine($repo, 'scripts', 'common', 'idrac-management', 'Enable-IdracVnc.ps1')
    $script:InventoryScript = [System.IO.Path]::Combine($repo, 'scripts', 'common', 'discovery', 'Get-DellServerInventory-FromiDRAC.ps1')
    $script:Cred = [pscredential]::new('admin', (ConvertTo-SecureString 'not-a-real-secret' -AsPlainText -Force))

    # The fake iDRAC: Redfish path -> response. Dell shapes: a LOM port that reports its MAC, and a slot card whose ports do not
    # (the MAC is on the network device function). BOSS-S2 with two M.2 drives and no virtual disk.
    function Get-FakeIdrac([switch]$BossHasVolume) {
        $o = { param($Id) @{ '@odata.id' = $Id } }
        $t = @{}
        $t['/redfish/v1/Systems/System.Embedded.1'] = @{ Id = 'System.Embedded.1'; SKU = 'SVCTAG1'; SerialNumber = 'CHASSIS1'; Model = 'AX-760'; Manufacturer = 'Dell Inc.'; UUID = '00000000-0000-0000-0000-000000000001'; HostName = ''; BiosVersion = '1.2.3'; PowerState = 'On'; ProcessorSummary = @{ Count = 2; Model = 'Test CPU' }; MemorySummary = @{ TotalSystemMemoryGiB = 512 } }
        $t['/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces'] = @{ Members = @(& $o '/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces/NIC.1') }
        $t['/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces/NIC.1'] = @{ Id = 'NIC.1'; MACAddress = '00:00:5E:00:53:01'; SpeedMbps = 1000 }
        $a = '/redfish/v1/Systems/System.Embedded.1/NetworkAdapters'
        $t[$a] = @{ Members = @((& $o "$a/NIC.Embedded.1"), (& $o "$a/NIC.Slot.3")) }
        $t["$a/NIC.Embedded.1"] = @{ Id = 'NIC.Embedded.1'; Model = 'Test LOM'; Manufacturer = 'Test Vendor'; NetworkPorts = (& $o "$a/NIC.Embedded.1/NetworkPorts") }
        $t["$a/NIC.Embedded.1/NetworkPorts"] = @{ Members = @(& $o "$a/NIC.Embedded.1/NetworkPorts/NIC.Embedded.1-1-1") }
        $t["$a/NIC.Embedded.1/NetworkPorts/NIC.Embedded.1-1-1"] = @{ Id = 'NIC.Embedded.1-1-1'; LinkStatus = 'Up'; CurrentLinkSpeedMbps = 1000; AssociatedNetworkAddresses = @('00:00:5E:00:53:10') }
        $t["$a/NIC.Slot.3"] = @{ Id = 'NIC.Slot.3'; Model = 'Test 25G Card'; Manufacturer = 'Test Vendor'; NetworkPorts = (& $o "$a/NIC.Slot.3/NetworkPorts"); NetworkDeviceFunctions = (& $o "$a/NIC.Slot.3/NetworkDeviceFunctions") }
        $t["$a/NIC.Slot.3/NetworkPorts"] = @{ Members = @((& $o "$a/NIC.Slot.3/NetworkPorts/NIC.Slot.3-1"), (& $o "$a/NIC.Slot.3/NetworkPorts/NIC.Slot.3-2")) }
        $t["$a/NIC.Slot.3/NetworkPorts/NIC.Slot.3-1"] = @{ Id = 'NIC.Slot.3-1'; LinkStatus = 'Up'; CurrentLinkSpeedMbps = 25000; AssociatedNetworkAddresses = @() }
        $t["$a/NIC.Slot.3/NetworkPorts/NIC.Slot.3-2"] = @{ Id = 'NIC.Slot.3-2'; LinkStatus = 'Down'; CurrentLinkSpeedMbps = 0; AssociatedNetworkAddresses = @() }
        $t["$a/NIC.Slot.3/NetworkDeviceFunctions"] = @{ Members = @((& $o "$a/NIC.Slot.3/NetworkDeviceFunctions/NIC.Slot.3-1-1"), (& $o "$a/NIC.Slot.3/NetworkDeviceFunctions/NIC.Slot.3-2-1")) }
        $t["$a/NIC.Slot.3/NetworkDeviceFunctions/NIC.Slot.3-1-1"] = @{ Id = 'NIC.Slot.3-1-1'; Ethernet = @{ MACAddress = '00:00:5E:00:53:21' } }
        $t["$a/NIC.Slot.3/NetworkDeviceFunctions/NIC.Slot.3-2-1"] = @{ Id = 'NIC.Slot.3-2-1'; Ethernet = @{ PermanentMACAddress = '00-00-5E-00-53-22' } }
        $s = '/redfish/v1/Systems/System.Embedded.1/Storage'
        $t[$s] = @{ Members = @((& $o "$s/AHCI.Slot.6-1"), (& $o "$s/RAID.Integrated.1-1")) }
        $t["$s/AHCI.Slot.6-1"] = @{ Id = 'AHCI.Slot.6-1'; Name = 'BOSS-S2'; StorageControllers = @(@{ Model = 'BOSS-S2'; Manufacturer = 'Dell'; FirmwareVersion = '2.5' }); Drives = @((& $o '/redfish/v1/Drives/M2.0'), (& $o '/redfish/v1/Drives/M2.1')); Volumes = (& $o "$s/AHCI.Slot.6-1/Volumes") }
        $t["$s/AHCI.Slot.6-1/Volumes"] = @{ Members = $(if ($BossHasVolume) { @(& $o "$s/AHCI.Slot.6-1/Volumes/Disk.Virtual.0") } else { @() }) }
        $t["$s/AHCI.Slot.6-1/Volumes/Disk.Virtual.0"] = @{ Id = 'Disk.Virtual.0'; Name = 'VD0'; RAIDType = 'RAID1'; VolumeType = 'Mirrored'; CapacityBytes = 480000000000 }
        $t['/redfish/v1/Drives/M2.0'] = @{ Id = 'M2.0'; Name = 'M.2 0'; Model = 'Test M.2'; SerialNumber = 'M2SERIAL0'; CapacityBytes = 480000000000; MediaType = 'SSD'; Protocol = 'SATA' }
        $t['/redfish/v1/Drives/M2.1'] = @{ Id = 'M2.1'; Name = 'M.2 1'; Model = 'Test M.2'; SerialNumber = 'M2SERIAL1'; CapacityBytes = 480000000000; MediaType = 'SSD'; Protocol = 'SATA' }
        $t["$s/RAID.Integrated.1-1"] = @{ Id = 'RAID.Integrated.1-1'; Name = 'Test RAID'; StorageControllers = @(@{ Model = 'Test RAID'; Manufacturer = 'Dell' }); Drives = @() }
        $table = @{}
        foreach ($k in $t.Keys) { $table[$k] = ($t[$k] | ConvertTo-Json -Depth 20) }
        $table
    }

    $script:NodeYaml = @'
# Test file. Comments must survive an edit.
scenario:
  name: "test"
nodes:
  - name: "node-1"   # first machine
    serial_number: "OLDTAG"
    bmc:
      ip_address: "bmc-1.invalid"
      type: idrac
    network_adapters:
      - name: "Embedded NIC 1"
        mac_address: "00:00:5E:00:53:10" # already right
        roles: [management]
        ip_assignment: dhcp_reservation
      - name: "Slot 3 Port 1"
        roles: [storage]
        ip_assignment: none
      - name: "Slot 3 Port 2"
        mac_address: "00:00:5E:00:53:99"
        roles: [storage]
        ip_assignment: none
  - name: "node-2"
    serial_number: "TAG2"
    management:
      ip_address: "x"
    bmc:
      ip_address: "bmc-2.invalid"
'@
}

Describe 'MAC and port naming' {
    It 'normalises <In>' -ForEach @(
        @{ In = '00-00-5e-00-53-0a'; Out = '00:00:5E:00:53:0A' }
        @{ In = '00005E00530A'; Out = '00:00:5E:00:53:0A' }
        @{ In = '0000.5E00.530A'; Out = '00:00:5E:00:53:0A' }
    ) { ConvertTo-AzlMacAddress $In | Should -Be $Out }
    It 'rejects <In>' -ForEach @(@{ In = '' }, @{ In = 'not a mac' }, @{ In = '00:00:5E:00:53' }, @{ In = '00:00:5E:00:53:0G' }) { ConvertTo-AzlMacAddress $In | Should -BeNullOrEmpty }
    It 'labels <Adapter> / <Port>' -ForEach @(
        @{ Adapter = 'NIC.Slot.3'; Port = 'NIC.Slot.3-2-1'; Name = 'Slot 3 Port 2'; Slot = 'Slot 3' }
        @{ Adapter = 'NIC.Slot.3'; Port = 'NIC.Slot.3-1'; Name = 'Slot 3 Port 1'; Slot = 'Slot 3' }
        @{ Adapter = 'NIC.Embedded.2'; Port = 'NIC.Embedded.2-1-1'; Name = 'Embedded NIC 2'; Slot = 'Embedded' }
        # Real lab shape: ONE embedded adapter carries both LOM ports and the NIC number is in the port id.
        @{ Adapter = 'NIC.Embedded.1'; Port = 'NIC.Embedded.1-1'; Name = 'Embedded NIC 1'; Slot = 'Embedded' }
        @{ Adapter = 'NIC.Embedded.1'; Port = 'NIC.Embedded.2-1'; Name = 'Embedded NIC 2'; Slot = 'Embedded' }
        @{ Adapter = 'NIC.Integrated.1'; Port = 'NIC.Integrated.1-2-1'; Name = 'Integrated NIC 1 Port 2'; Slot = 'Integrated 1' }
    ) {
        $l = Get-AzlDellPortLabel -AdapterId $Adapter -PortId $Port
        $l.Name | Should -Be $Name
        $l.Slot | Should -Be $Slot
    }
}

Describe 'Get-AzlDellAdapterModel' {
    It 'uses the adapter Model when there is one' {
        Get-AzlDellAdapterModel -Adapter ([pscustomobject]@{ Model = 'MLNX 100GbE 2P ConnectX6 Adpt'; Name = 'x' }) | Should -Be 'MLNX 100GbE 2P ConnectX6 Adpt'
    }
    It 'falls back to the adapter Name without the MAC suffix when the embedded card has an empty Model (lab defect)' {
        Get-AzlDellAdapterModel -Adapter ([pscustomobject]@{ Model = ''; Name = 'Broadcom Gigabit Ethernet BCM5720 - C4:CB:E1:B3:6F:C6' }) | Should -Be 'Broadcom Gigabit Ethernet BCM5720'
    }
    It 'does not take a bare adapter id as a model' {
        Get-AzlDellAdapterModel -Adapter ([pscustomobject]@{ Model = $null; Name = 'NIC.Embedded.1' }) -Function ([pscustomobject]@{ Name = 'Broadcom NetXtreme Gigabit Ethernet' }) | Should -Be 'Broadcom NetXtreme Gigabit Ethernet'
    }
    It 'returns an empty string when nothing names the card' {
        Get-AzlDellAdapterModel -Adapter ([pscustomobject]@{ Model = $null; Name = $null }) | Should -Be ''
    }
}

Describe 'Get-AzlDellNodeDiscovery' {
    BeforeEach {
        $global:AzlTestIdrac = Get-FakeIdrac
        Mock -ModuleName AzlDellRedfish Invoke-AzlRedfish {
            if (-not $global:AzlTestIdrac.ContainsKey($Path)) { throw "404 $Path" }
            $global:AzlTestIdrac[$Path] | ConvertFrom-Json -Depth 20
        }
    }
    AfterAll { Remove-Variable -Name AzlTestIdrac -Scope Global -ErrorAction SilentlyContinue }

    It 'reads the identity: the service tag is the SKU' {
        $d = Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary
        $d.Identity.ServiceTag | Should -Be 'SVCTAG1'
        $d.Identity.SerialNumber | Should -Be 'CHASSIS1'
        $d.Identity.Model | Should -Be 'AX-760'
        $d.Bmc.MacAddress | Should -Be '00:00:5E:00:53:01'
    }
    It 'returns one entry per port with its MAC, from the port or from the device function' {
        $d = Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary
        $d.NetworkPorts.Count | Should -Be 3
        $byName = @{}; foreach ($p in $d.NetworkPorts) { $byName[$p.Name] = $p }
        $byName['Embedded NIC 1'].MacAddress | Should -Be '00:00:5E:00:53:10'
        $byName['Embedded NIC 1'].MacSource | Should -Be 'Port'
        $byName['Slot 3 Port 1'].MacAddress | Should -Be '00:00:5E:00:53:21'
        $byName['Slot 3 Port 1'].MacSource | Should -Be 'Function'
        $byName['Slot 3 Port 2'].MacAddress | Should -Be '00:00:5E:00:53:22'
        $byName['Slot 3 Port 1'].LinkUp | Should -BeTrue
        $byName['Slot 3 Port 2'].LinkUp | Should -BeFalse
        $byName['Slot 3 Port 1'].Slot | Should -Be 'Slot 3'
        $byName['Embedded NIC 1'].Slot | Should -Be 'Embedded'
    }
    It 'finds the BOSS card and that it has no virtual disk' {
        $d = Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary
        $d.Boss.Present | Should -BeTrue
        $d.Boss.ControllerId | Should -Be 'AHCI.Slot.6-1'
        $d.Boss.DriveCount | Should -Be 2
        $d.Boss.HasVirtualDisk | Should -BeFalse
        $d.Boss.NeedsVirtualDisk | Should -BeTrue
        $d.Boss.Drives[0].SerialNumber | Should -Be 'M2SERIAL0'
    }
    It 'sees a BOSS virtual disk' {
        $global:AzlTestIdrac = Get-FakeIdrac -BossHasVolume
        $d = Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary
        $d.Boss.HasVirtualDisk | Should -BeTrue
        $d.Boss.NeedsVirtualDisk | Should -BeFalse
        $d.Boss.Volumes[0].RaidType | Should -Be 'RAID1'
    }
    It 'reports no BOSS when there is no such controller' {
        $global:AzlTestIdrac['/redfish/v1/Systems/System.Embedded.1/Storage'] = (@{ Members = @(@{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1/Storage/RAID.Integrated.1-1' }) } | ConvertTo-Json -Depth 5)
        $d = Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary
        $d.Boss.Present | Should -BeFalse
        $d.Boss.NeedsVirtualDisk | Should -BeFalse
    }
    It 'records a failing optional section as a warning and keeps going' {
        $d = Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Full
        $d.Identity.ServiceTag | Should -Be 'SVCTAG1'
        ($d.Warnings -join ' ') | Should -Match 'Chassis'
        ($d.Warnings -join ' ') | Should -Match 'Firmware'
    }
    It 'warns about a port without a MAC instead of dropping it silently' {
        $global:AzlTestIdrac['/redfish/v1/Systems/System.Embedded.1/NetworkAdapters/NIC.Slot.3/NetworkDeviceFunctions/NIC.Slot.3-1-1'] = (@{ Id = 'NIC.Slot.3-1-1' } | ConvertTo-Json)
        $d = Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary
        $d.NetworkPorts.Count | Should -Be 2
        ($d.Warnings -join ' ') | Should -Match 'NIC.Slot.3-1 .*no MAC'
    }
    It 'throws when the system cannot be read' {
        $global:AzlTestIdrac.Remove('/redfish/v1/Systems/System.Embedded.1')
        { Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary } | Should -Throw '*404*'
    }
    It 'only reads: no PATCH, POST or other method is issued' {
        Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Full | Out-Null
        Should -Invoke -ModuleName AzlDellRedfish Invoke-AzlRedfish -Times 0 -ParameterFilter { $Method -and $Method -ne 'Get' }
    }
}

Describe 'Select-AzlManagementPort' {
    BeforeAll {
        $script:Ports = @(
            [ordered]@{ Name = 'Embedded NIC 1'; Slot = 'Embedded'; MacAddress = '00:00:5E:00:53:10'; LinkUp = $false }
            [ordered]@{ Name = 'Slot 3 Port 1'; Slot = 'Slot 3'; MacAddress = '00:00:5E:00:53:21'; LinkUp = $true }
            [ordered]@{ Name = 'Embedded NIC 2'; Slot = 'Embedded'; MacAddress = '00:00:5E:00:53:11'; LinkUp = $true }
        )
    }
    It 'honours the name given, by name or MAC' {
        (Select-AzlManagementPort -Ports $script:Ports -Name 'Slot 3 Port 1').Port.MacAddress | Should -Be '00:00:5E:00:53:21'
        $r = Select-AzlManagementPort -Ports $script:Ports -Name '00-00-5e-00-53-11'
        $r.Port.Name | Should -Be 'Embedded NIC 2'
        $r.Confirmed | Should -BeTrue
    }
    It 'throws for an unknown name' { { Select-AzlManagementPort -Ports $script:Ports -Name 'Nope' } | Should -Throw '*No discovered port*' }
    It 'uses the MAC already in the file, confirmed' {
        $r = Select-AzlManagementPort -Ports $script:Ports -ExistingMac '00:00:5E:00:53:21'
        $r.Port.Name | Should -Be 'Slot 3 Port 1'
        $r.Confirmed | Should -BeTrue
    }
    It 'guesses the first embedded port with link, unconfirmed' {
        $r = Select-AzlManagementPort -Ports $script:Ports
        $r.Port.Name | Should -Be 'Embedded NIC 2'
        $r.Confirmed | Should -BeFalse
    }
    It 'guesses nothing when no port has link' {
        $down = @($script:Ports | ForEach-Object { $c = [ordered]@{} + $_; $c.LinkUp = $false; $c })
        (Select-AzlManagementPort -Ports $down).Port | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-AzlDiscoveryProposal' {
    BeforeAll {
        $global:AzlTestIdrac = Get-FakeIdrac
        Mock -ModuleName AzlDellRedfish Invoke-AzlRedfish { $global:AzlTestIdrac[$Path] | ConvertFrom-Json -Depth 20 }
        $d = Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary
        $script:Proposal = ConvertTo-AzlDiscoveryProposal -Item @([pscustomobject]@{ NodeName = 'node-1'; Discovery = $d; ManagementPort = 'Slot 3 Port 1'; ExistingManagementMac = '' })
        $script:ProposalYaml = ConvertFrom-Yaml $script:Proposal -Ordered
    }
    AfterAll { Remove-Variable -Name AzlTestIdrac -Scope Global -ErrorAction SilentlyContinue }
    It 'is valid YAML with the service tag as serial_number' {
        $script:ProposalYaml.nodes[0].name | Should -Be 'node-1'
        $script:ProposalYaml.nodes[0].serial_number | Should -Be 'SVCTAG1'
    }
    It 'lists every port with its MAC, slot and model' {
        $ports = @($script:ProposalYaml.nodes[0].network_adapters)
        $ports.Count | Should -Be 3
        ($ports | ForEach-Object { $_.mac_address }) | Should -Contain '00:00:5E:00:53:22'
        ($ports | Where-Object name -eq 'Slot 3 Port 1').slot | Should -Be 'Slot 3'
        ($ports | Where-Object name -eq 'Slot 3 Port 1').model | Should -Be 'Test 25G Card'
    }
    It 'marks only the chosen port management and leaves roles for the others as unused' {
        $ports = @($script:ProposalYaml.nodes[0].network_adapters)
        ($ports | Where-Object { $_.roles -contains 'management' }).name | Should -Be 'Slot 3 Port 1'
        @($ports | Where-Object { $_.roles -contains 'unused' }).Count | Should -Be 2
        $script:Proposal | Should -Match 'BOSS: controller AHCI.Slot.6-1, 2 drive\(s\), no virtual disk yet'
    }
    It 'says in a comment that nothing is applied' { $script:Proposal | Should -Match 'Nothing is applied' }
}

Describe 'Resolve-AzlBmcCredential' {
    BeforeAll {
        $script:Infra = [ordered]@{ hardware = [ordered]@{ bmc = [ordered]@{ username = 'keyvault://vault-test/bmc-user'; password = 'keyvault://vault-test/bmc-pass' } } }
    }
    BeforeEach {
        Mock -ModuleName AzlDellRedfish Get-AzlBmcKeyVaultSecret {
            if ($AsPlainText) { return "user-of-$($Reference.Split('/')[-1])" }
            return (ConvertTo-SecureString "pw-of-$($Reference.Split('/')[-1])" -AsPlainText -Force)
        }
        Mock -ModuleName AzlDellRedfish Get-Credential { [pscredential]::new('prompted', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }
    }
    It 'prefers the credential parameter and never calls Key Vault' {
        (Resolve-AzlBmcCredential -Credential $script:Cred -Infrastructure $script:Infra).UserName | Should -Be 'admin'
        Should -Invoke -ModuleName AzlDellRedfish Get-AzlBmcKeyVaultSecret -Times 0
    }
    It 'reads hardware.bmc from Key Vault' {
        $c = Resolve-AzlBmcCredential -Infrastructure $script:Infra
        $c.UserName | Should -Be 'user-of-bmc-user'
        $c.GetNetworkCredential().Password | Should -Be 'pw-of-bmc-pass'
        Should -Invoke -ModuleName AzlDellRedfish Get-Credential -Times 0
    }
    It 'lets the node block win over hardware.bmc and accepts a plain user name' {
        $node = [ordered]@{ bmc = [ordered]@{ username = 'plainuser'; password = 'keyvault://vault-test/node-pass' } }
        $c = Resolve-AzlBmcCredential -Infrastructure $script:Infra -Node $node
        $c.UserName | Should -Be 'plainuser'
        $c.GetNetworkCredential().Password | Should -Be 'pw-of-node-pass'
    }
    It 'prompts when the file has no reference' {
        (Resolve-AzlBmcCredential -Infrastructure ([ordered]@{})).UserName | Should -Be 'prompted'
    }
    It 'warns and prompts when Key Vault fails, without printing a secret' {
        Mock -ModuleName AzlDellRedfish Get-AzlBmcKeyVaultSecret { throw 'vault unreachable' }
        $c = Resolve-AzlBmcCredential -Infrastructure $script:Infra -WarningVariable w -WarningAction SilentlyContinue
        $c.UserName | Should -Be 'prompted'
        ($w -join ' ') | Should -Match 'vault unreachable'
    }
    It 'throws instead of prompting with -NoPrompt' { { Resolve-AzlBmcCredential -Infrastructure ([ordered]@{}) -NoPrompt } | Should -Throw '*No BMC credential*' }
}

Describe 'Set-AzlDellIdracVnc' {
    BeforeEach {
        $global:AzlTestPatch = $null
        Mock -ModuleName AzlDellRedfish Invoke-AzlRedfish {
            if ($Method -eq 'Patch') { $global:AzlTestPatch = @{ Path = $Path; Body = $Body }; return [pscustomobject]@{} }
            [pscustomobject]@{ Attributes = [pscustomobject]@{ 'VNCServer.1.Enable' = 'Disabled'; 'VNCServer.1.Port' = 5901; 'VNCServer.1.Timeout' = 300 } }
        }
    }
    AfterAll { Remove-Variable -Name AzlTestPatch -Scope Global -ErrorAction SilentlyContinue }
    It 'patches the VNC attributes' {
        $r = Set-AzlDellIdracVnc -BmcAddress 'bmc.invalid' -Credential $script:Cred -State Enabled -Port 5902 -TimeoutSeconds 600
        $r.Status | Should -Be 'Applied'
        $r.Before | Should -Match 'Disabled'
        $a = $global:AzlTestPatch.Body.Attributes
        $a['VNCServer.1.Enable'] | Should -Be 'Enabled'
        $a['VNCServer.1.Port'] | Should -Be 5902
        $a['VNCServer.1.Timeout'] | Should -Be 600
        $a.Contains('VNCServer.1.Password') | Should -BeFalse
    }
    It 'sends the password only when given, and checks its length' {
        $ok = ConvertTo-SecureString 'abcd1234' -AsPlainText -Force
        (Set-AzlDellIdracVnc -BmcAddress 'bmc.invalid' -Credential $script:Cred -Password $ok).PasswordSet | Should -BeTrue
        $global:AzlTestPatch.Body.Attributes['VNCServer.1.Password'] | Should -Be 'abcd1234'
        { Set-AzlDellIdracVnc -BmcAddress 'bmc.invalid' -Credential $script:Cred -Password (ConvertTo-SecureString 'toolongpassword' -AsPlainText -Force) } | Should -Throw '*4 to 8*'
    }
    It 'changes nothing with -WhatIf' {
        $r = Set-AzlDellIdracVnc -BmcAddress 'bmc.invalid' -Credential $script:Cred -WhatIf
        $r.Status | Should -Be 'WhatIf'
        $global:AzlTestPatch | Should -BeNullOrEmpty
    }
}

Describe 'Edit-AzlYamlValue' {
    BeforeEach { $script:Lines = [System.Collections.Generic.List[string]]::new([string[]]($script:NodeYaml -split '\r?\n')) }
    It 'changes a scalar and keeps its comment' {
        $r = Edit-AzlYamlValue -Lines $script:Lines -Path 'nodes', '[name=node-1]', 'serial_number' -Value 'SVCTAG1'
        $r.Result | Should -Be 'Changed'
        $r.Old | Should -Be 'OLDTAG'
        $script:Lines | Should -Contain '    serial_number: "SVCTAG1"'
        ($script:Lines -join "`n") | Should -Match 'name: "node-1"   # first machine'
    }
    It 'reports Unchanged for the same value' {
        (Edit-AzlYamlValue -Lines $script:Lines -Path 'nodes', '[name=node-1]', 'serial_number' -Value 'OLDTAG').Result | Should -Be 'Unchanged'
    }
    It 'edits the MAC of one adapter selected by name, and keeps the trailing comment' {
        $r = Edit-AzlYamlValue -Lines $script:Lines -Path 'nodes', '[name=node-1]', 'network_adapters', '[name=Embedded NIC 1]', 'mac_address' -Value '00:00:5E:00:53:AA'
        $r.Result | Should -Be 'Changed'
        ($script:Lines -join "`n") | Should -Match 'mac_address: "00:00:5E:00:53:AA" # already right'
    }
    It 'inserts a missing key under its adapter and nowhere else' {
        $r = Edit-AzlYamlValue -Lines $script:Lines -Path 'nodes', '[name=node-1]', 'network_adapters', '[name=Slot 3 Port 1]', 'mac_address' -Value '00:00:5E:00:53:21' -InsertIfMissing
        $r.Result | Should -Be 'Inserted'
        $doc = ConvertFrom-Yaml ($script:Lines -join "`n") -Ordered
        ($doc.nodes[0].network_adapters | Where-Object name -eq 'Slot 3 Port 1').mac_address | Should -Be '00:00:5E:00:53:21'
        ($doc.nodes[0].network_adapters | Where-Object name -eq 'Slot 3 Port 2').mac_address | Should -Be '00:00:5E:00:53:99'
        $doc.nodes[1].serial_number | Should -Be 'TAG2'
    }
    It 'never creates a missing parent' {
        (Edit-AzlYamlValue -Lines $script:Lines -Path 'nodes', '[name=node-2]', 'network_adapters', '[name=X]', 'mac_address' -Value 'a' -InsertIfMissing).Result | Should -Be 'NotFound'
        (Edit-AzlYamlValue -Lines $script:Lines -Path 'nodes', '[name=node-9]', 'serial_number' -Value 'a').Result | Should -Be 'NotFound'
    }
    It 'refuses to overwrite a key that holds a block' {
        (Edit-AzlYamlValue -Lines $script:Lines -Path 'nodes', '[name=node-1]', 'bmc' -Value 'a').Result | Should -Be 'NotScalar'
    }
}

Describe 'Get-AzlDiscoveryChange and Invoke-AzlYamlEdit' {
    BeforeAll {
        $global:AzlTestIdrac = Get-FakeIdrac
        Mock -ModuleName AzlDellRedfish Invoke-AzlRedfish { $global:AzlTestIdrac[$Path] | ConvertFrom-Json -Depth 20 }
        $script:Discovery = Get-AzlDellNodeDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary
        $script:Infra = ConvertFrom-Yaml $script:NodeYaml -Ordered
    }
    AfterAll { Remove-Variable -Name AzlTestIdrac -Scope Global -ErrorAction SilentlyContinue }
    It 'plans the serial number and the MAC of the adapter that has none or a wrong one' {
        $plan = Get-AzlDiscoveryChange -Infrastructure $script:Infra -Item @([pscustomobject]@{ NodeName = 'node-1'; Discovery = $script:Discovery })
        ($plan.Changes | ForEach-Object { $_.Display }) | Should -Contain 'nodes[node-1].serial_number'
        ($plan.Changes | Where-Object Display -like '*Slot 3 Port 1*').New | Should -Be '00:00:5E:00:53:21'
        ($plan.Changes | Where-Object Display -like '*Slot 3 Port 2*').New | Should -Be '00:00:5E:00:53:22'
        ($plan.Changes | Where-Object Display -like '*Embedded NIC 1*') | Should -BeNullOrEmpty
    }
    It 'notes a management-only node whose management port is only guessed' {
        $plan = Get-AzlDiscoveryChange -Infrastructure $script:Infra -Item @([pscustomobject]@{ NodeName = 'node-2'; Discovery = $script:Discovery })
        ($plan.Changes | Where-Object Display -like '*management.mac_address') | Should -BeNullOrEmpty
        ($plan.Notes -join ' ') | Should -Match 'suggested management port'
    }
    It 'writes management.mac_address of a management-only node when the port is given' {
        $infra = ConvertFrom-Yaml $script:NodeYaml -Ordered
        $plan = Get-AzlDiscoveryChange -Infrastructure $infra -Item @([pscustomobject]@{ NodeName = 'node-2'; Discovery = $script:Discovery; ManagementPort = 'Embedded NIC 1' })
        ($plan.Changes | Where-Object Display -like '*management.mac_address').New | Should -Be '00:00:5E:00:53:10'
    }
    It 'applies the plan to a file with a backup, keeping comments and CRLF' {
        $file = Join-Path $TestDrive 'infrastructure.yml'
        [System.IO.File]::WriteAllText($file, ($script:NodeYaml -replace "`r?`n", "`r`n"), [System.Text.UTF8Encoding]::new($false))
        $plan = Get-AzlDiscoveryChange -Infrastructure (ConvertFrom-Yaml $script:NodeYaml -Ordered) -Item @([pscustomobject]@{ NodeName = 'node-1'; Discovery = $script:Discovery })
        $edit = Invoke-AzlYamlEdit -Path $file -Change $plan.Changes -Confirm:$false
        Test-Path $edit.Backup | Should -BeTrue
        $text = Get-Content $file -Raw
        $text | Should -Match "`r`n"
        $text | Should -Match '# first machine'
        $text | Should -Match '# Test file'
        $doc = ConvertFrom-Yaml $text -Ordered
        $doc.nodes[0].serial_number | Should -Be 'SVCTAG1'
        ($doc.nodes[0].network_adapters | Where-Object name -eq 'Slot 3 Port 2').mac_address | Should -Be '00:00:5E:00:53:22'
        (Get-Content $edit.Backup -Raw) | Should -Match 'OLDTAG'
    }
    It 'writes nothing with -WhatIf' {
        $file = Join-Path $TestDrive 'whatif.yml'
        Set-Content $file $script:NodeYaml
        $before = Get-Content $file -Raw
        $plan = Get-AzlDiscoveryChange -Infrastructure (ConvertFrom-Yaml $script:NodeYaml -Ordered) -Item @([pscustomobject]@{ NodeName = 'node-1'; Discovery = $script:Discovery })
        (Invoke-AzlYamlEdit -Path $file -Change $plan.Changes -WhatIf).Backup | Should -BeNullOrEmpty
        (Get-Content $file -Raw) | Should -Be $before
    }
}

Describe 'Scripts end to end (fake iDRAC)' {
    BeforeAll {
        $global:AzlTestIdrac = Get-FakeIdrac
        Mock -ModuleName AzlDellRedfish Invoke-AzlRedfish { $global:AzlTestIdrac[$Path] | ConvertFrom-Json -Depth 20 }
        $script:Cfg = Join-Path $TestDrive 'infrastructure.yml'
        Set-Content $script:Cfg $script:NodeYaml
        $script:Out = Join-Path $TestDrive 'discovery'
    }
    AfterAll { Remove-Variable -Name AzlTestIdrac -Scope Global -ErrorAction SilentlyContinue }

    It 'Invoke-HardwareDiscovery writes the node file, the summary and the proposal, and leaves infrastructure.yml alone' {
        $before = Get-Content $script:Cfg -Raw
        & $script:InvokeScript -ConfigPath $script:Cfg -OutputPath $script:Out -Credential $script:Cred -TargetNode 'node-1' -Detail Summary -ManagementPort 'Embedded NIC 1' -InformationAction SilentlyContinue
        Test-Path (Join-Path $script:Out 'SVCTAG1.json') | Should -BeTrue
        $summary = Get-Content (Join-Path $script:Out 'discovery-summary.json') -Raw | ConvertFrom-Json
        $summary[0].ServiceTag | Should -Be 'SVCTAG1'
        $summary[0].ManagementMac | Should -Be '00:00:5E:00:53:10'
        $summary[0].Boss.NeedsVirtualDisk | Should -BeTrue
        (Get-Content (Join-Path $script:Out 'infrastructure.discovered.yml') -Raw) | Should -Match 'serial_number: "SVCTAG1"'
        (Get-Content $script:Cfg -Raw) | Should -Be $before
    }
    It 'the node file holds no password' {
        (Get-Content (Join-Path $script:Out 'SVCTAG1.json') -Raw) | Should -Not -Match 'not-a-real-secret'
    }
    It 'Update-InfrastructureYml-FromDiscovery previews without -Apply' {
        $before = Get-Content $script:Cfg -Raw
        & $script:UpdateScript -ConfigPath $script:Cfg -DiscoveryPath $script:Out -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        (Get-Content $script:Cfg -Raw) | Should -Be $before
    }
    It 'Update-InfrastructureYml-FromDiscovery -Apply -Force writes serial and MACs' {
        & $script:UpdateScript -ConfigPath $script:Cfg -DiscoveryPath $script:Out -Apply -Force -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $doc = ConvertFrom-Yaml (Get-Content $script:Cfg -Raw) -Ordered
        $doc.nodes[0].serial_number | Should -Be 'SVCTAG1'
        ($doc.nodes[0].network_adapters | Where-Object name -eq 'Slot 3 Port 1').mac_address | Should -Be '00:00:5E:00:53:21'
        (Get-ChildItem (Split-Path $script:Cfg) -Filter 'infrastructure.yml.bak.*').Count | Should -BeGreaterThan 0
    }
    It 'Get-DellServerInventory-FromiDRAC keeps one consolidated file keyed by service tag' {
        $dir = Join-Path $TestDrive 'inventory'
        & $script:InventoryScript -BmcAddress 'bmc.invalid' -Credential $script:Cred -OutputPath $dir -Detail Summary -InformationAction SilentlyContinue | Out-Null
        & $script:InventoryScript -BmcAddress 'bmc.invalid' -Credential $script:Cred -OutputPath $dir -Detail Summary -InformationAction SilentlyContinue | Out-Null
        $inv = Get-Content (Join-Path $dir 'idrac-inventory.json') -Raw | ConvertFrom-Json
        $inv.Metadata.NodeCount | Should -Be 1
        $inv.Nodes.SVCTAG1.NetworkPorts.Count | Should -Be 3
    }
    It 'Invoke-HardwareDiscovery fails (after writing the others) when a node cannot be read' {
        $global:AzlTestIdrac.Remove('/redfish/v1/Systems/System.Embedded.1')
        { & $script:InvokeScript -ConfigPath $script:Cfg -OutputPath (Join-Path $TestDrive 'fail') -Credential $script:Cred -Detail Summary -InformationAction SilentlyContinue -ErrorAction SilentlyContinue } | Should -Throw '*could not be discovered*'
    }
    It 'Enable-IdracVnc -WhatIf touches no iDRAC' {
        $global:AzlTestIdrac = Get-FakeIdrac
        $global:AzlTestIdrac['/redfish/v1/Managers/iDRAC.Embedded.1/Attributes'] = (@{ Attributes = @{ 'VNCServer.1.Enable' = 'Disabled' } } | ConvertTo-Json -Depth 5)
        $r = & $script:VncScript -BmcAddress 'bmc.invalid' -Credential $script:Cred -WhatIf -InformationAction SilentlyContinue
        $r.Status | Should -Be 'WhatIf'
    }
}

Describe 'Standalone script' {
    It 'prints the MAC of every port and saves the file, with Invoke-RestMethod mocked' {
        $global:AzlTestIdrac = Get-FakeIdrac
        $global:AzlTestIdrac['/redfish/v1/Systems/System.Embedded.1/Bios'] = (@{ Attributes = @{ ProcCStates = 'Disabled' } } | ConvertTo-Json -Depth 5)
        $global:AzlTestIdrac['/redfish/v1/Managers/iDRAC.Embedded.1/Attributes'] = (@{ Attributes = @{ 'IPv4.1.Enable' = 'Enabled' } } | ConvertTo-Json -Depth 5)
        Mock Invoke-RestMethod {
            $path = ([uri]$Uri).AbsolutePath
            if (-not $global:AzlTestIdrac.ContainsKey($path)) { throw "404 $path" }
            $global:AzlTestIdrac[$path] | ConvertFrom-Json -Depth 20
        }
        $out = Join-Path $TestDrive 'standalone'
        $rows = & $script:StandaloneScript -BmcAddress 'bmc.invalid' -Credential $script:Cred -OutputPath $out -InformationAction SilentlyContinue
        @($rows).Count | Should -Be 3
        ($rows | ForEach-Object Mac) | Should -Contain '00:00:5E:00:53:10'
        ($rows | Select-Object -First 1).ServiceTag | Should -Be 'SVCTAG1'
        Test-Path (Join-Path $out 'SVCTAG1.json') | Should -BeTrue
        Remove-Variable -Name AzlTestIdrac -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Standards' {
    It '<Relative> has no tenant or company name, no IPv4 address and no plain-text secret' -ForEach $script:Shipped {
        $text = Get-Content -LiteralPath $Full -Raw
        $text | Should -Not -Match '(?i)tierpoint|tplabs|prodtech|product technology|hybrid cloud solutions'
        $text | Should -Not -Match '\b(?:\d{1,3}\.){3}\d{1,3}\b'
        $text | Should -Not -Match '(?i)ConvertTo-SecureString\s+.*-AsPlainText'
        $text | Should -Not -Match '(?i)password\s*[:=]\s*["''][^"''<$]'
    }
    It '<Relative> is PowerShell 7 with strict mode and stop on error' -ForEach ($script:Shipped | Where-Object { $_.Relative -match '\.ps1$|\.psm1$' }) {
        $text = Get-Content -LiteralPath $Full -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
    }
}
