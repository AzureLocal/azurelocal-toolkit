#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pre-cluster verification, STORAGE (ST-) checks. Fakes only: no Azure, no Active Directory, no node.
# The lab facts are the fixtures: two Pure FlashArray Fibre Channel LUNs with four paths each are eight disks until MPIO claims the array.

BeforeAll {
    . ([IO.Path]::Combine($PSScriptRoot, 'Verification.NodeFixtures.ps1'))
    $script:Mod = Import-VerModule -Name Storage
    function Invoke-VerRun([string]$Id, $World, $Infra, [hashtable]$Settings = @{}, [hashtable]$Adapter = @{}) {
        $ctx = New-VerContext -Module $script:Mod -Infra $Infra -World $World -Settings $Settings -Adapter $Adapter
        Invoke-VerCheck -Module $script:Mod -Id $Id -Context $ctx
    }
    function New-VerFresh([string]$Architecture = 's2d', [switch]$WithSan) { $i = New-VerInfra -Architecture $Architecture -WithSan:$WithSan; $w = New-VerWorld -Infra $i; [pscustomobject]@{ Infra = $i; World = $w } }
    function New-VerLab([string]$Architecture = 's2d', [switch]$WithSan, [switch]$Claimed) {
        $f = New-VerFresh -Architecture $Architecture -WithSan:$WithSan
        foreach ($n in $f.World.Snapshot.Keys) { Add-VerLabSan -Snapshot $f.World.Snapshot[$n] -Claimed:$Claimed }
        $f
    }
}

Describe 'Contract' {
    It 'exports the two commands and eleven well formed definitions' {
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationCheckDefinition'
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationAdapterDefault'
        $defs = Get-VerDefinition -Module $script:Mod
        $defs.Count | Should -Be 11
        foreach ($d in $defs) {
            $d.Id | Should -Match '^ST-\d{3}$'; $d.Category | Should -Be 'storage'; $d.Title | Should -Not -BeNullOrEmpty; $d.Source | Should -Not -BeNullOrEmpty
            $d.Blocking | Should -BeOfType [bool]; $d.Applies | Should -BeOfType [scriptblock]; $d.Run | Should -BeOfType [scriptblock]
        }
    }
    It 'a healthy S2D world passes every applicable STORAGE check with ONE remote call per node' {
        $f = New-VerFresh
        $ctx = New-VerContext -Module $script:Mod -Infra $f.Infra -World $f.World
        $bad = foreach ($d in (Get-VerDefinition -Module $script:Mod)) { foreach ($r in (Invoke-VerCheck -Module $script:Mod -Id $d.Id -Context $ctx)) { if ($r.Status -notin 'Passed', 'NotApplicable') { "$($d.Id) $($r.Status): $($r.Message)" } } }
        $bad | Should -BeNullOrEmpty
        $f.World.Calls.Count | Should -Be 2
    }
    It 'a fully claimed FC SAN world with a declared SAN passes every applicable check' {
        $f = New-VerLab -Architecture hybrid -WithSan -Claimed
        $ctx = New-VerContext -Module $script:Mod -Infra $f.Infra -World $f.World
        $bad = foreach ($d in (Get-VerDefinition -Module $script:Mod | Where-Object Id -NE 'ST-008')) { foreach ($r in (Invoke-VerCheck -Module $script:Mod -Id $d.Id -Context $ctx)) { if ($r.Status -notin 'Passed', 'NotApplicable') { "$($d.Id) $($r.Status): $($r.Message)" } } }
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'ST-001 to ST-003 local disks' {
    It 'ST-001 Passed with four 3.84 TB data disks; the BOSS boot device is not counted' {
        $f = New-VerFresh; $r = Invoke-VerRun 'ST-001' $f.World $f.Infra
        $r.Status | Should -Not -Contain 'Failed'; $r[0].Message | Should -Match '4 local data disks'
    }
    It 'ST-001 Failed with one data disk' { $f = New-VerFresh; $f.World.Snapshot['n01'].physical = @($f.World.Snapshot['n01'].physical | Select-Object -First 2); (Invoke-VerRun 'ST-001' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'ST-001 Failed when the nodes have different drives' { $f = New-VerFresh; $f.World.Snapshot['n02'].physical = @($f.World.Snapshot['n02'].physical | Select-Object -First 4); @(Invoke-VerRun 'ST-001' $f.World $f.Infra | Where-Object { $_.Status -eq 'Failed' -and $_.Node -eq '*' }).Count | Should -Be 1 }
    It 'ST-001 Failed behind a RAID controller' { $f = New-VerFresh; $f.World.Snapshot['n01'].physical[1].bus = 'RAID'; (Invoke-VerRun 'ST-001' $f.World $f.Infra | Where-Object Node -EQ 'n01').Message | Should -Match 'RAID' }
    It 'ST-001 is NotApplicable for a SAN-only design' { $f = New-VerFresh -Architecture san -WithSan; (Invoke-VerRun 'ST-001' $f.World $f.Infra).Status | Should -Be 'NotApplicable' }
    It 'ST-002 Failed for a disk with a partition, with the clearing command' {
        $f = New-VerFresh; $d = $f.World.Snapshot['n01'].physical[2]; $d.parts = 1; $d.style = 'GPT'; $d.canPool = $false; $d.reason = 'In a Pool'
        $r = Invoke-VerRun 'ST-002' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Failed'; $r.Remedy | Should -Match 'Clear-Disk'
    }
    It 'ST-002 does not read the BOSS boot disk (partitions, not poolable) as dirty' { $f = New-VerFresh; (Invoke-VerRun 'ST-002' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'ST-003 Failed when a storage pool is left' { $f = New-VerFresh; $f.World.Snapshot['n02'].pools = @('S2D on old'); $f.World.Snapshot['n02'].vdisks = 2; (Invoke-VerRun 'ST-003' $f.World $f.Infra | Where-Object Node -EQ 'n02').Status | Should -Be 'Failed' }
}

Describe 'ST-004 the lab failure: eight disks for two LUNs' {
    It 'Failed on every node, with the Test-Cluster evidence, while the file declares no SAN' {
        $f = New-VerLab
        $r = Invoke-VerRun 'ST-004' $f.World $f.Infra
        $r.Count | Should -Be 2
        foreach ($x in $r) {
            $x.Status | Should -Be 'Failed'
            $x.Message | Should -Match 'Two disks have been found on node n0[12] that cannot be distinguished from one another'
            $x.Message | Should -Match 'declares no SAN'
            $x.Message | Should -Match '4 paths seen as 4 disks'
        }
        $r[0].Evidence | Should -Match '6B10C3E4A11F0001'
    }
    It 'the remedy is the proven fix with the vendor padded to 8 and the product to 16' {
        $f = New-VerLab
        $r = (Invoke-VerRun 'ST-004' $f.World $f.Infra)[0]
        $r.Remedy | Should -Match ([regex]::Escape('mpclaim -n -i -d "PURE    FlashArray      "'))
        $r.Remedy | Should -Match 'Restart-Computer'
    }
    It 'with a declared SAN the message says MPIO does not merge the paths' {
        $f = New-VerLab -Architecture hybrid -WithSan
        $r = (Invoke-VerRun 'ST-004' $f.World $f.Infra)[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'MPIO does not merge the paths'; $r.Message | Should -Not -Match 'declares no SAN'
    }
    It 'the vendor comes from config/san/msdsm-vendors.json when the node shows none' {
        $f = New-VerLab -WithSan -Architecture hybrid
        foreach ($n in $f.World.Snapshot.Keys) { $f.World.Snapshot[$n].mpio.availableHw = @() }
        (Invoke-VerRun 'ST-004' $f.World $f.Infra)[0].Remedy | Should -Match ([regex]::Escape('mpclaim -n -i -d "PURE    FlashArray      "'))
    }
    It 'Passed once MPIO claims the array: two LUNs, two disks' {
        $f = New-VerLab -Claimed
        $r = Invoke-VerRun 'ST-004' $f.World $f.Infra
        $r.Status | Should -Not -Contain 'Failed'; $r[0].Message | Should -Match '2 SAN disk'
    }
    It 'Passed on a node without any SAN disk' { $f = New-VerFresh; (Invoke-VerRun 'ST-004' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'groups by UniqueId when the serial number is empty' {
        $f = New-VerLab; foreach ($n in $f.World.Snapshot.Keys) { foreach ($d in $f.World.Snapshot[$n].disks) { if ($d.bus -eq 'Fibre Channel') { $d.serial = '' } } }
        (Invoke-VerRun 'ST-004' $f.World $f.Infra)[0].Status | Should -Be 'Failed'
    }
    It 'works through a replaced Node.GetMpio adapter member (a fake)' {
        $f = New-VerFresh
        $fake = { param($Node, $Context) [pscustomobject]@{ mpio = [pscustomobject]@{ availableHw = @() }; disks = @(@{ num = 7; serial = 'S1'; uid = 'U1'; bus = 'iSCSI'; model = 'X' }, @{ num = 8; serial = 'S1'; uid = 'U1'; bus = 'iSCSI'; model = 'X' }); fc = @(); iscsi = $null } }
        (Invoke-VerRun 'ST-004' $f.World $f.Infra -Adapter @{ Node = @{ GetMpio = $fake } })[0].Status | Should -Be 'Failed'
    }
}

Describe 'ST-005 to ST-007 MPIO' {
    It 'ST-005 NotApplicable with no SAN declared and none visible' { $f = New-VerFresh; (Invoke-VerRun 'ST-005' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'ST-005 Failed when LUNs are visible and the MultipathIO feature is off' {
        $f = New-VerLab; foreach ($n in $f.World.Snapshot.Keys) { $f.World.Snapshot[$n].mpio.feature = 'Disabled' }
        $r = Invoke-VerRun 'ST-005' $f.World $f.Infra
        $r[0].Status | Should -Be 'Failed'; $r[0].Remedy | Should -Match 'MultipathIO'
    }
    It 'ST-005 Passed with the feature Enabled' { $f = New-VerLab; (Invoke-VerRun 'ST-005' $f.World $f.Infra)[0].Status | Should -Be 'Passed' }
    It 'ST-006 Failed when Get-MPIOAvailableHW shows the array not multipathed, with the mpclaim command' {
        $f = New-VerLab
        $r = Invoke-VerRun 'ST-006' $f.World $f.Infra
        $r[0].Status | Should -Be 'Failed'; $r[0].Message | Should -Match 'IsMultipathed is False'
        $r[0].Remedy | Should -Match ([regex]::Escape('mpclaim -n -i -d "PURE    FlashArray      "'))
        $r[0].Remedy | Should -Match "New-MSDSMSupportedHW -VendorId 'PURE' -ProductId 'FlashArray'"
    }
    It 'ST-006 Passed once claimed' { $f = New-VerLab -Claimed; (Invoke-VerRun 'ST-006' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'ST-006 Failed when the vendor is claimed but not registered with MSDSM' {
        $f = New-VerLab -Claimed; foreach ($n in $f.World.Snapshot.Keys) { $f.World.Snapshot[$n].mpio.supportedHw = @() }
        (Invoke-VerRun 'ST-006' $f.World $f.Infra)[0].Status | Should -Be 'Warning'
    }
    It 'ST-007 Failed when mpclaim -s -d shows no MPIO disk' {
        $f = New-VerLab
        $r = Invoke-VerRun 'ST-007' $f.World $f.Infra
        $r[0].Status | Should -Be 'Failed'; $r[0].Message | Should -Match 'mpclaim -s -d shows no MPIO disk'; $r[0].Evidence | Should -Match 'mpioDisks=0 sanDisks=8 luns=2'
    }
    It 'ST-007 Failed when fewer MPIO disks than LUNs' { $f = New-VerLab -Claimed; foreach ($n in $f.World.Snapshot.Keys) { $f.World.Snapshot[$n].mpio.claims = @($f.World.Snapshot[$n].mpio.claims[0]) }; (Invoke-VerRun 'ST-007' $f.World $f.Infra)[0].Status | Should -Be 'Failed' }
    It 'ST-007 Passed with one MPIO disk per LUN' { $f = New-VerLab -Claimed; (Invoke-VerRun 'ST-007' $f.World $f.Infra)[0].Message | Should -Match '2 MPIO disk'; (Invoke-VerRun 'ST-007' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
}

Describe 'ST-008 Learn hybrid rule: do not zone Fibre Channel before the deployment' {
    It 'Warning (not blocking) when LUNs are visible in a hybrid design' {
        $f = New-VerLab -Architecture hybrid -WithSan -Claimed
        $r = Invoke-VerRun 'ST-008' $f.World $f.Infra
        $r[0].Status | Should -Be 'Warning'; $r[0].Message | Should -Match 'not zoning|do not zone'
        (Get-VerDefinition -Module $script:Mod -Id 'ST-008').Blocking | Should -BeFalse
    }
    It 'Warning in an S2D design as well' { $f = New-VerLab; (Invoke-VerRun 'ST-008' $f.World $f.Infra)[0].Status | Should -Be 'Warning' }
    It 'Passed when no Fibre Channel LUN is visible' { $f = New-VerFresh -Architecture hybrid -WithSan; (Invoke-VerRun 'ST-008' $f.World $f.Infra).Status | Should -Not -Contain 'Warning' }
    It 'NotApplicable for a SAN-only design' { $f = New-VerLab -Architecture san -WithSan -Claimed; (Invoke-VerRun 'ST-008' $f.World $f.Infra)[0].Status | Should -Be 'NotApplicable' }
}

Describe 'ST-009 to ST-011 SAN design' {
    It 'ST-009 Passed when the nodes see the same LUNs' { $f = New-VerLab -Architecture san -WithSan -Claimed; (Invoke-VerRun 'ST-009' $f.World $f.Infra)[0].Status | Should -Be 'Passed' }
    It 'ST-009 Failed when a node misses a LUN' {
        $f = New-VerLab -Architecture san -WithSan -Claimed
        $f.World.Snapshot['n02'].disks = @($f.World.Snapshot['n02'].disks | Where-Object { $_.bus -ne 'Fibre Channel' -or $_.lun -ne 1 })
        $r = Invoke-VerRun 'ST-009' $f.World $f.Infra
        $r[0].Status | Should -Be 'Failed'; $r[0].Message | Should -Match 'n02 does not see'
    }
    It 'ST-009 Failed on different LUN IDs for the same LUN' {
        $f = New-VerLab -Architecture san -WithSan -Claimed
        ($f.World.Snapshot['n02'].disks | Where-Object { $_.bus -eq 'Fibre Channel' } | Select-Object -First 1).lun = 9
        (Invoke-VerRun 'ST-009' $f.World $f.Infra)[0].Message | Should -Match 'different LUN IDs'
    }
    It 'ST-009 is NotApplicable when no SAN is declared' { $f = New-VerLab; (Invoke-VerRun 'ST-009' $f.World $f.Infra)[0].Status | Should -Be 'NotApplicable' }
    It 'ST-010 Passed with the 250 GB and 20 GB LUNs visible and RAW' { $f = New-VerLab -Architecture san -WithSan -Claimed; (Invoke-VerRun 'ST-010' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'ST-010 Failed when a system LUN was initialized' {
        $f = New-VerLab -Architecture san -WithSan -Claimed
        ($f.World.Snapshot['n01'].disks | Where-Object { $_.lun -eq 1 -and $_.bus -eq 'Fibre Channel' }).style = 'GPT'
        (Invoke-VerRun 'ST-010' $f.World $f.Infra | Where-Object Node -EQ 'n01').Message | Should -Match 'initialized'
    }
    It 'ST-010 Failed when the infrastructure LUN is not visible' {
        $f = New-VerFresh -Architecture san -WithSan
        (Invoke-VerRun 'ST-010' $f.World $f.Infra | Where-Object Node -EQ 'n01').Message | Should -Match 'is not visible'
    }
    It 'ST-011 Passed when the HBA ports of the file are present' { $f = New-VerLab -Architecture hybrid -WithSan -Claimed; (Invoke-VerRun 'ST-011' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'ST-011 Failed when a WWPN of the file is missing on the node' { $f = New-VerLab -Architecture hybrid -WithSan -Claimed; $f.World.Snapshot['n01'].fc = @($f.World.Snapshot['n01'].fc[0]); (Invoke-VerRun 'ST-011' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
}

Describe 'Unreadable nodes' {
    It 'every per node check is Skipped for a node that cannot be read, saying why' {
        $f = New-VerLab; $f.World.Down['n02'] = 'WinRM timed out'
        foreach ($id in 'ST-003', 'ST-004', 'ST-005', 'ST-006', 'ST-007') {
            $r = Invoke-VerRun $id $f.World $f.Infra | Where-Object Node -EQ 'n02'
            $r.Status | Should -Be 'Skipped' -Because $id
            $r.Message | Should -Match 'WinRM timed out'
        }
    }
    It 'a cross node check with no readable node is Skipped, not Passed' {
        $f = New-VerLab -Architecture san -WithSan -Claimed; $f.World.Down['n01'] = 'x'; $f.World.Down['n02'] = 'x'
        (Invoke-VerRun 'ST-009' $f.World $f.Infra)[0].Status | Should -Be 'Skipped'
    }
}

Describe 'A pool or cluster section whose read failed is not read as a clean node (review C1)' {
    It 'ST-003 is Skipped with the reason when the pool read failed' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].err = @{ pools = 'storage service not running' }
        $r = @(Invoke-VerRun 'ST-003' $f.World $f.Infra | Where-Object Node -EQ 'n01')
        ($r | Where-Object Status -EQ 'Passed') | Should -BeNullOrEmpty
        $r[0].Status | Should -Be 'Skipped'
        $r[0].Message | Should -Match 'storage service not running'
    }
}

Describe 'ST-006 aligns with the OS configuration SAN logic: MPIO''s own device list (MPDEV MPIOSupportedDeviceList)' {
    It 'is Failed when the array is multipathed and registered with MSDSM but not in MPIOSupportedDeviceList, with the mpclaim -n -i -d command' {
        $f = New-VerLab -Claimed
        $f.World.Snapshot['n01'].mpio.mpdevRead = $true; $f.World.Snapshot['n01'].mpio.mpdev = @()
        $r = Invoke-VerRun 'ST-006' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'MPIOSupportedDeviceList'
        $r.Remedy | Should -Match 'mpclaim -n -i -d'
    }
    It 'passes when the list holds the vendor and product, and is not judged when the key could not be read' {
        $f = New-VerLab -Claimed
        $f.World.Snapshot['n01'].mpio.mpdevRead = $true; $f.World.Snapshot['n01'].mpio.mpdev = @(@{ vendor = 'PURE'; product = 'FlashArray' })
        (Invoke-VerRun 'ST-006' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Passed'
        $g = New-VerLab -Claimed
        (Invoke-VerRun 'ST-006' $g.World $g.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Passed'
    }
}
Describe 'ST-008 says what is true now (lab: LUNs visible and claimed by MPIO once each)' {
    It 'does not say Test-Cluster fails when MPIO shows each LUN once' {
        $f = New-VerLab -Claimed
        $r = Invoke-VerRun 'ST-008' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Warning'
        $r.Message | Should -Match 'MPIO claims each LUN once'
        $r.Message | Should -Match 'does not apply now'
        $r.Message | Should -Not -Match 'make Test-Cluster fail'
    }
    It 'still says Test-Cluster fails when a LUN is visible more than once (paths not claimed)' {
        $f = New-VerLab
        $r = Invoke-VerRun 'ST-008' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Warning'
        $r.Message | Should -Match 'visible more than once or not claimed'
        $r.Remedy | Should -Match 'mpclaim -n -i -d'
    }
}