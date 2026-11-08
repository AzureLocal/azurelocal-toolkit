#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The NicNames step of the OS configuration: an OPT-IN rename of the adapters whose port has os_name_override, each found by MAC. Without an override the step does
# nothing and the adapters keep the names the OS gave them. Three machines of different NIC brands (tests/fixtures/nic-model) whose nodes name the same adapters differently.
# No node, no Azure, no Active Directory is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/NicNames.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    . ([IO.Path]::Combine($PSScriptRoot, '..', 'fixtures', 'nic-model', 'NicFixtures.ps1'))
    $script:Brands = @(Get-NicBrandFixture | ForEach-Object { @{ Fixture = $_; Id = $_.Id } })
}

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\azure-local\AzlAzure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodeTransport.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodeConfiguration.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlGuardedChange.psm1') -Force
    Import-Module powershell-yaml
    . (Join-Path $repo 'tests\fixtures\nic-model\NicFixtures.ps1')
    $script:Base = Join-Path $repo 'tests\fixtures\infrastructure.fc-san.yml'

    function Get-NicSpec([hashtable]$Fixture, [int]$NodeIndex = 1, [switch]$WithOverride, [scriptblock]$Change) {
        $infra = Import-AzlInfrastructure -Path $script:Base -SkipValidation
        $null = Set-NicFixtureOnInfra -Infra $infra -Fixture $Fixture -WithOverride:$WithOverride
        if ($Change) { & $Change $infra }
        Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[$NodeIndex - 1]
    }
    function Get-NicPlan($Spec, $Nics) {
        @(Compare-AzlNodeState -Spec $Spec -State ([pscustomobject]@{ nics = @($Nics) }) -Step @('NicNames'))
    }
    function Get-MacOf([hashtable]$Fixture, [int]$Node, [string]$Key) {
        $i = [array]::IndexOf(@($Fixture.Ports | ForEach-Object { $_.Key }), $Key) + 1
        ((Get-NicMac $Fixture.Index $Node $i) -replace ':', '').ToLowerInvariant()
    }
}

Describe 'NicNames is a step of the OS configuration' {
    It 'is in the step list, after Drivers and before Network' {
        $all = InModuleScope AzlNodeConfiguration { $script:AllSteps }
        $all | Should -Contain 'NicNames'
        [array]::IndexOf($all, 'NicNames') | Should -BeGreaterThan ([array]::IndexOf($all, 'Drivers'))
        [array]::IndexOf($all, 'NicNames') | Should -BeLessThan ([array]::IndexOf($all, 'Network'))
    }
    It 'is in the event stage order' {
        Import-Module (Join-Path $PSScriptRoot '..\..\scripts\common\node-configuration\AzlOsConfigurationEvents.psm1') -Force
        (Get-AzlOsConfigurationStepOrder) | Should -Contain 'NicNames'
    }
    It 'puts a rename in the guarded Network group' {
        $parts = Split-AzlGuardedAction -Todo @([pscustomobject]@{ Apply = @{ id = 'NicNames/aa'; kind = 'nic-rename'; mac = 'aa'; name = 'X' } })
        @($parts.Network).Count | Should -Be 1
        @($parts.Inline).Count | Should -Be 0
    }
}

Describe 'Without os_name_override nothing is renamed: <Id>' -ForEach $script:Brands {
    It 'plans nothing for NicNames on either node, whatever the OS calls the adapters' {
        foreach ($n in 1, 2) {
            $spec = Get-NicSpec $Fixture $n
            @(Get-NicPlan $spec (Get-NicNodeState $Fixture $n)).Count | Should -Be 0
        }
    }
    It 'plans no Change and no Apply from any step list that includes NicNames' {
        $spec = Get-NicSpec $Fixture 1
        $plan = @(Compare-AzlNodeState -Spec $spec -State ([pscustomobject]@{ nics = @(Get-NicNodeState $Fixture 1) }) -Step @('NicNames'))
        @($plan | Where-Object { $_.Apply }).Count | Should -Be 0
    }
}

Describe 'With os_name_override the adapter is found by MAC and renamed: <Id>' -ForEach $script:Brands {
    It 'plans one rename per port with an override: node <_> current -> desired' -ForEach @(1, 2) {
        $node = $_
        $spec = Get-NicSpec $Fixture $node -WithOverride
        $nics = Get-NicNodeState $Fixture $node
        $plan = Get-NicPlan $spec $nics
        $changes = @($plan | Where-Object Action -eq 'Change')
        $changes.Count | Should -Be $Fixture.Override.Count
        foreach ($key in $Fixture.Override.Keys) {
            $mac = Get-MacOf $Fixture $node $key
            $item = $changes | Where-Object { $_.Apply.mac -eq $mac }
            $item | Should -Not -BeNullOrEmpty -Because "$key is found by its MAC $mac"
            $item.Desired | Should -Be $Fixture.Override[$key] -Because 'the desired name is the same on every node'
            $item.Current | Should -Be ($nics | Where-Object mac -eq $mac).n -Because 'the current name is what the node reports'
            $item.Apply.kind | Should -Be 'nic-rename'
            $item.Apply.name | Should -Be $Fixture.Override[$key]
        }
    }
    It 'does not touch an adapter whose port has no override' {
        $spec = Get-NicSpec $Fixture 1 -WithOverride
        $plan = Get-NicPlan $spec (Get-NicNodeState $Fixture 1)
        $withoutOverride = @($Fixture.Ports | Where-Object { -not $Fixture.Override.ContainsKey($_.Key) })
        foreach ($p in $withoutOverride) { @($plan | Where-Object { $_.Apply -and $_.Apply.mac -eq (Get-MacOf $Fixture 1 $p.Key) }).Count | Should -Be 0 }
    }
    It 'renames the management adapter last' {
        $spec = Get-NicSpec $Fixture 1 -WithOverride
        $changes = @(Get-NicPlan $spec (Get-NicNodeState $Fixture 1) | Where-Object Action -eq 'Change')
        $mgmtMac = $spec.Management.Mac
        if (@($changes | Where-Object { $_.Apply.mac -eq $mgmtMac }).Count) {
            $changes[-1].Apply.mac | Should -Be $mgmtMac
            $changes[-1].Apply.managementAdapter | Should -BeTrue
        }
    }
    It 'is idempotent: when the names are right, every item is Ok and nothing is applied' {
        $spec = Get-NicSpec $Fixture 1 -WithOverride
        $byMac = @{}
        foreach ($key in $Fixture.Override.Keys) { $byMac[(Get-MacOf $Fixture 1 $key)] = $Fixture.Override[$key] }
        $plan = Get-NicPlan $spec (Get-NicNodeState $Fixture 1 -NameByMac $byMac)
        @($plan | Where-Object Action -ne 'Ok').Count | Should -Be 0
        @($plan | Where-Object { $_.Apply }).Count | Should -Be 0
        @($plan).Count | Should -Be $Fixture.Override.Count
    }
    It 'verifies after the apply: the read after the rename shows the new names' {
        $spec = Get-NicSpec $Fixture 2 -WithOverride
        $before = Get-NicPlan $spec (Get-NicNodeState $Fixture 2)
        $byMac = @{}
        foreach ($c in @($before | Where-Object Action -eq 'Change')) { $byMac[$c.Apply.mac] = $c.Apply.name }
        $after = Get-NicPlan $spec (Get-NicNodeState $Fixture 2 -NameByMac $byMac)
        @($after | Where-Object Action -eq 'Ok').Count | Should -Be $Fixture.Override.Count
    }
    It 'asks for the same desired names on both nodes although the OS names differ per node' {
        $d1 = @(Get-NicPlan (Get-NicSpec $Fixture 1 -WithOverride) (Get-NicNodeState $Fixture 1) | Where-Object Action -eq 'Change' | ForEach-Object { $_.Desired } | Sort-Object)
        $d2 = @(Get-NicPlan (Get-NicSpec $Fixture 2 -WithOverride) (Get-NicNodeState $Fixture 2) | Where-Object Action -eq 'Change' | ForEach-Object { $_.Desired } | Sort-Object)
        ($d1 -join ',') | Should -Be ($d2 -join ',')
        $c1 = @(Get-NicNodeState $Fixture 1 | ForEach-Object { $_.n } | Sort-Object)
        $c2 = @(Get-NicNodeState $Fixture 2 | ForEach-Object { $_.n } | Sort-Object)
        ($c1 -join ',') | Should -Not -Be ($c2 -join ',') -Because 'the nodes really name the adapters differently'
    }
    It 'leaves an adapter the file does not list alone, and a MAC that no adapter has is only noted' {
        $spec = Get-NicSpec $Fixture 1 -WithOverride
        $extra = [pscustomobject]@{ n = 'Ethernet 99'; mac = '0ee0e0e0e0e0'; st = 'Up'; pci = ''; drv = '1'; desc = 'Some other NIC'; dhcp = 'Enabled'; ips = @(); gw = @(); dns = @(); vlan = $null; hwif = $true }
        $nics = @(Get-NicNodeState $Fixture 1 -Extra @($extra))
        $plan = Get-NicPlan $spec $nics
        @($plan | Where-Object { $_.Apply -and $_.Apply.mac -eq '0ee0e0e0e0e0' }).Count | Should -Be 0
        $gone = @($nics | Where-Object { $_.mac -ne (Get-MacOf $Fixture 1 ($Fixture.Override.Keys | Select-Object -First 1)) })
        $plan2 = Get-NicPlan $spec $gone
        @($plan2 | Where-Object { $_.Action -eq 'Info' -and $_.Current -eq 'not found' }).Count | Should -Be 1
        @($plan2 | Where-Object Action -eq 'Blocked').Count | Should -Be 0
    }
}

Describe 'The rename is refused or ordered when names collide' {
    BeforeAll {
        $script:A = (Get-NicBrandFixture)[0]   # Dell with Mellanox and Broadcom
    }
    It 'moves a name that another adapter of this run holds through a temporary name (a swap)' {
        $spec = Get-NicSpec $script:A 1 -WithOverride -Change {
            param($infra)
            # The user wants Slot 3 Port 1 to be called 'Storage1' and Slot 6 Port 1 'Mgmt1': each name is held by the other adapter on this node.
            foreach ($a in $infra.nodes[0].network_adapters) { if ($a.name -eq 'Slot 3 Port 1') { $a.os_name_override = 'Storage1' }; if ($a.name -eq 'Slot 6 Port 1') { $a.os_name_override = 'Mgmt1' } }
        }
        $s31 = Get-MacOf $script:A 1 'Slot 3 Port 1'; $s61 = Get-MacOf $script:A 1 'Slot 6 Port 1'
        $names = @{ $s31 = 'Mgmt1'; $s61 = 'Storage1' }
        $plan = Get-NicPlan $spec (Get-NicNodeState $script:A 1 -NameByMac $names)
        $a = $plan | Where-Object { $_.Apply -and $_.Apply.mac -eq $s31 }
        $b = $plan | Where-Object { $_.Apply -and $_.Apply.mac -eq $s61 }
        $a.Action | Should -Be 'Change'; $b.Action | Should -Be 'Change'
        $a.Note | Should -Match 'temporary name'
        $b.Note | Should -Match 'temporary name'
    }
    It 'blocks a name that an adapter this run does not rename already has' {
        $spec = Get-NicSpec $script:A 1 -WithOverride
        # Embedded NIC 1 (no override) is called 'Mgmt1' on this node, and Slot 3 Port 1 wants 'Mgmt1'.
        $names = @{ (Get-MacOf $script:A 1 'Embedded NIC 1') = 'Mgmt1' }
        $plan = Get-NicPlan $spec (Get-NicNodeState $script:A 1 -NameByMac $names)
        $item = $plan | Where-Object { $_.Desired -eq 'Mgmt1' }
        $item.Action | Should -Be 'Blocked'
        $item.Note | Should -Match 'already used'
        $item.Apply | Should -BeNullOrEmpty
    }
    It 'refuses two ports that ask for one name' {
        $spec = Get-NicSpec $script:A 1 -WithOverride -Change { param($infra) foreach ($a in $infra.nodes[0].network_adapters) { if ($a.name -in 'Slot 3 Port 2', 'Slot 6 Port 1') { $a.os_name_override = 'Same' } } }
        $plan = Get-NicPlan $spec (Get-NicNodeState $script:A 1)
        @($plan | Where-Object { $_.Desired -eq 'Same' -and $_.Action -eq 'Blocked' }).Count | Should -Be 2
        @($plan | Where-Object { $_.Desired -eq 'Same' -and $_.Apply }).Count | Should -Be 0
    }
    It 'refuses two adapters that report one MAC' {
        $spec = Get-NicSpec $script:A 1 -WithOverride
        $nics = @(Get-NicNodeState $script:A 1)
        $dupOf = $nics | Where-Object mac -eq (Get-MacOf $script:A 1 'Slot 6 Port 1')
        $dup = $dupOf.PSObject.Copy(); $dup.n = 'Ethernet 77'
        $plan = Get-NicPlan $spec (@($nics) + @($dup))
        $item = $plan | Where-Object { $_.Desired -eq 'Storage1' }
        $item.Action | Should -Be 'Blocked'
        $item.Note | Should -Match 'report MAC'
        $item.Apply | Should -BeNullOrEmpty
    }
    It 'refuses a Remote NDIS, USB or virtual device, whatever the brand' -ForEach @('Remote NDIS Compatible Device', 'USB Ethernet Adapter', 'Hyper-V Virtual Ethernet Adapter') {
        $spec = Get-NicSpec $script:A 1 -WithOverride
        $nics = @(Get-NicNodeState $script:A 1)
        ($nics | Where-Object mac -eq (Get-MacOf $script:A 1 'Slot 6 Port 1')).desc = $_
        $plan = Get-NicPlan $spec $nics
        $item = $plan | Where-Object { $_.Desired -eq 'Storage1' }
        $item.Action | Should -Be 'Blocked'
        $item.Apply | Should -BeNullOrEmpty
    }
    It 'refuses a device the node says has no hardware interface' {
        $spec = Get-NicSpec $script:A 1 -WithOverride
        $nics = @(Get-NicNodeState $script:A 1)
        ($nics | Where-Object mac -eq (Get-MacOf $script:A 1 'Slot 6 Port 1')).hwif = $false
        ((Get-NicPlan $spec $nics) | Where-Object { $_.Desired -eq 'Storage1' }).Action | Should -Be 'Blocked'
    }
    It 'treats a name that differs only in letter case as already right' {
        $spec = Get-NicSpec $script:A 1 -WithOverride
        $names = @{ (Get-MacOf $script:A 1 'Slot 6 Port 1') = 'STORAGE1' }
        $item = (Get-NicPlan $spec (Get-NicNodeState $script:A 1 -NameByMac $names)) | Where-Object { $_.Desired -eq 'Storage1' }
        $item.Action | Should -Be 'Ok'
    }
}

Describe 'The PCI location in the file is compared with the node, informational only' {
    It 'reports a different location as Info and changes nothing' {
        $f = (Get-NicBrandFixture)[0]
        $spec = Get-NicSpec $f 1
        $nics = @(Get-NicNodeState $f 1)
        ($nics | Where-Object mac -eq (Get-MacOf $f 1 'Slot 6 Port 1')).loc = [pscustomobject]@{ bus = 200; device = 0; function = 0 }
        $plan = Get-NicPlan $spec $nics
        $info = @($plan | Where-Object { $_.Action -eq 'Info' })
        $info.Count | Should -Be 1
        $info[0].Item | Should -Match 'PCI location'
        @($plan | Where-Object { $_.Apply }).Count | Should -Be 0
    }
    It 'reports nothing when the location is the same, or when the node does not report one' {
        $f = (Get-NicBrandFixture)[1]
        $spec = Get-NicSpec $f 1
        @(Get-NicPlan $spec (Get-NicNodeState $f 1)).Count | Should -Be 0
        $nics = @(Get-NicNodeState $f 1); foreach ($n in $nics) { $n.loc = $null }
        @(Get-NicPlan $spec $nics).Count | Should -Be 0
    }
}

Describe 'The spec carries the hardware identity from the file' {
    It 'keeps the MAC (normalised), the key and the override of each port: <Id>' -ForEach $script:Brands {
        $spec = Get-NicSpec $Fixture 1 -WithOverride
        $spec.Ports.Count | Should -Be $Fixture.Ports.Count
        foreach ($p in $Fixture.Ports) {
            $port = $spec.Ports | Where-Object Name -eq $p.Key
            $port.Mac | Should -Be (Get-MacOf $Fixture 1 $p.Key)
            $port.OsNameOverride | Should -Be $(if ($Fixture.Override.ContainsKey($p.Key)) { $Fixture.Override[$p.Key] } else { '' })
        }
    }
}
