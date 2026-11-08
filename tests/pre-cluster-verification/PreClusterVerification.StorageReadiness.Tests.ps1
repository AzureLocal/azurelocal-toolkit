#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Categories storage and readiness: Storage Spaces Direct disks, the SAN (declared and visible, MPIO, the vendor claim, duplicate paths, LUN sets,
# the system LUNs, hybrid zoning, iSCSI) and Microsoft's Environment Checker validators. The duplicate-disk case is the real Azure Test-Cluster
# failure of the lab ("Two disks have been found ... that cannot be distinguished from one another"). Fakes only.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake adapter members and mock script blocks keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    foreach ($m in 'infrastructure\AzlInfrastructure.psm1', 'azure-local\AzlAzure.psm1', 'arm-deployment\AzlArmDeployment.psm1', 'arm-deployment\AzlArmDeploymentRun.psm1', 'arm-deployment\AzlPreClusterGate.psm1', 'arm-deployment\AzlPreClusterVerification.psm1') {
        Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Force
    }
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'PreClusterVerification.Helpers.ps1'))
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    function New-SanDisk([int]$Number, [string]$Uid, [int]$Lun, [double]$Gb = 300, [string]$Style = 'RAW', [string]$Bus = 'Fibre Channel') {
        [pscustomobject]@{ n = $Number; bus = $Bus; gb = $Gb; ps = $Style; sn = "SN-$Uid"; uid = $Uid; lun = $Lun; paths = 4; st = 'Offline' }
    }
    function Invoke-StorageRun([System.Collections.IDictionary]$Infra, [scriptblock]$Mutate, [string[]]$Nodes = @('iic-n01', 'iic-n02')) {
        $w = Initialize-PclWorld -Infra $Infra
        if ($Mutate) { foreach ($n in $Nodes) { $w.Mutate[$n] = $Mutate } }
        Invoke-PclRun -World $w -Infra $Infra -Category storage
    }
    # The disaggregated design: two LUNs (infra 300 GiB, performance history 50 GiB) visible once on both nodes, the array claimed by MPIO.
    function Get-SanInfra {
        $i = Get-PclInfra -Storage san
        $i.storage.san.infra_volume_lun_id = '0'; $i.storage.san.performance_history_lun_id = '1'
        $i
    }
    $script:GoodSan = {
        param($d, $q)
        $d.Read.san.disks = @((New-SanDisk 5 'UID-INFRA' 0 300), (New-SanDisk 6 'UID-PERF' 1 50))
        $d.Read.san.hw = @('DellEMC|PowerStore')
        $d.Read.san.fc = @([pscustomobject]@{ wwpn = '1000000000000011'; up = 'Online' }, [pscustomobject]@{ wwpn = '1000000000000012'; up = 'Online' })
    }
}

Describe 'Storage Spaces Direct disks' {
    It 'passes four clean NVMe disks per node' {
        $r = Invoke-StorageRun (Get-PclInfra)
        foreach ($id in 'STO-001', 'STO-002', 'STO-003') { (Get-PclCheck $r $id 'iic-n01').Status | Should -Be 'Passed' -Because $id }
        (Get-PclCheck $r 'STO-004').Status | Should -Be 'Passed'
    }
    It 'fails data disks with partitions, naming the disk, with the clear command' {
        $r = Invoke-StorageRun (Get-PclInfra) { param($d, $q) $x = $d.Pcl.phys[1]; $x.parts = 2; $x.style = 'GPT'; $x.canPool = $false; $x.reason = 'In a Pool' } @('iic-n02')
        $c = Get-PclCheck $r 'STO-002' 'iic-n02'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'disk 1 NVMe 1'
        $c.Message | Should -Match '2 partition'
        $c.Remedy | Should -Match 'ClearStorage'
        (Get-PclCheck $r 'STO-002' 'iic-n01').Status | Should -Be 'Passed'
    }
    It 'fails fewer than two data disks of 500 GB, and nodes with different drives' {
        $r = Invoke-StorageRun (Get-PclInfra) { param($d, $q) $d.Pcl.phys = @($d.Pcl.phys | Select-Object -First 2) } @('iic-n01')
        (Get-PclCheck $r 'STO-001' 'iic-n01').Status | Should -Be 'Failed'
        @(Get-PclCheck $r 'STO-001' '*')[0].Message | Should -Match 'same number and type of drives'
    }
    It 'fails a storage pool left on a node' {
        $r = Invoke-StorageRun (Get-PclInfra) { param($d, $q) $d.Pcl.pools = @('S2D on old'); $d.Pcl.vdisks = 3 } @('iic-n01')
        $c = Get-PclCheck $r 'STO-003' 'iic-n01'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'S2D on old'
    }
    It 'does not apply the S2D disk checks to a disaggregated design' {
        $r = Invoke-StorageRun (Get-SanInfra) $script:GoodSan
        (Get-PclCheck $r 'STO-001').Status | Should -Be 'NotApplicable'
        (Get-PclCheck $r 'STO-002').Status | Should -Be 'NotApplicable'
    }
}

Describe 'A SAN that is visible but not declared (the lab Test-Cluster failure)' {
    It 'fails with the evidence "Two disks ... cannot be distinguished" when MPIO has not claimed the paths' {
        $r = Invoke-StorageRun (Get-PclInfra) {
            param($d, $q)
            $d.Read.san.disks = @((New-SanDisk 5 'UID-PURE-1' 0 2048), (New-SanDisk 6 'UID-PURE-1' 0 2048), (New-SanDisk 7 'UID-PURE-1' 0 2048), (New-SanDisk 8 'UID-PURE-1' 0 2048), (New-SanDisk 9 'UID-PURE-2' 1 2048), (New-SanDisk 10 'UID-PURE-2' 1 2048))
            $d.Read.san.feature = 'Disabled'
        }
        $c = Get-PclCheck $r 'STO-004'
        $c.Status | Should -Be 'Failed'
        $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'SAN LUNs are visible but the file declares no SAN'
        $c.Message | Should -Match "Two disks have been found on node iic-n01 that cannot be distinguished from one another"
        $c.Message | Should -Match 'UID-PURE-1'
        $c.Message | Should -Match 'Test-Cluster'
        $c.Remedy | Should -Match 'storage_architecture hybrid or san'
        (Get-PclCheck $r 'STO-007' 'iic-n01').Status | Should -Be 'Failed'
        (Get-PclCheck $r 'STO-005' 'iic-n01').Status | Should -Be 'Failed'
        $r.Verdict | Should -Be 'Fail'
    }
    It 'fails even when each LUN is seen once: an undeclared SAN is a finding' {
        $r = Invoke-StorageRun (Get-PclInfra) { param($d, $q) $d.Read.san.disks = @((New-SanDisk 5 'UID-A' 0 500)) }
        (Get-PclCheck $r 'STO-004').Status | Should -Be 'Failed'
        (Get-PclCheck $r 'STO-007' 'iic-n01').Status | Should -Be 'Passed'
    }
}

Describe 'A declared SAN (disaggregated)' {
    It 'passes when both system LUNs are visible once, claimed, RAW and consistent' {
        $r = Invoke-StorageRun (Get-SanInfra) $script:GoodSan
        foreach ($id in 'STO-004', 'STO-005', 'STO-006', 'STO-007', 'STO-008', 'STO-009', 'STO-010') {
            @(Get-PclCheck $r $id | Where-Object { $_.Status -ne 'Passed' }).Count | Should -Be 0 -Because $id
        }
        $r.Verdict | Should -Be 'Pass'
    }
    It 'fails when no LUN is visible before the Arc registration' {
        $r = Invoke-StorageRun (Get-SanInfra)
        $c = Get-PclCheck $r 'STO-004'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'must be visible, unmasked to the HBAs and left RAW'
    }
    It 'fails when MPIO does not claim the array, and gives the mpclaim command with the vendor padded to 8 and the product to 16' {
        $r = Invoke-StorageRun (Get-SanInfra) { param($d, $q) & $script:GoodSan $d $q; $d.Read.san.hw = @('MSFT|Virtual') }
        $c = Get-PclCheck $r 'STO-006' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'DellEMC PowerStore'
        $c.Remedy | Should -Be 'mpclaim -n -i -d "DellEMC PowerStore      "   (or New-MSDSMSupportedHW -VendorId ''DellEMC'' -ProductId ''PowerStore'')'
    }
    It 'is Skipped (and blocks) for an array that is not in config/san/msdsm-vendors.json' {
        $infra = Get-SanInfra; $infra.storage.san.array.vendor = 'Acme'; $infra.storage.san.array.model = 'Z9'
        $r = Invoke-StorageRun $infra $script:GoodSan
        $c = Get-PclCheck $r 'STO-006'
        $c.Status | Should -Be 'Skipped'
        $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'not in config/san/msdsm-vendors.json'
    }
    It 'fails a LUN that is seen more than once (duplicate paths), with the evidence' {
        $r = Invoke-StorageRun (Get-SanInfra) { param($d, $q) & $script:GoodSan $d $q; $d.Read.san.disks += (New-SanDisk 7 'UID-INFRA' 0 300) }
        $c = Get-PclCheck $r 'STO-007' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'cannot be distinguished from one another'
        $c.Message | Should -Match 'UID-INFRA'
    }
    It 'fails nodes that see different LUNs or different LUN IDs' {
        $r = Invoke-StorageRun (Get-SanInfra) { param($d, $q) & $script:GoodSan $d $q; if ($d.Pcl.host -eq 'iic-n02') { $d.Read.san.disks = @($d.Read.san.disks | Select-Object -First 1) } }
        $c = Get-PclCheck $r 'STO-008'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'iic-n02 does not see LUN'
        $r2 = Invoke-StorageRun (Get-SanInfra) { param($d, $q) & $script:GoodSan $d $q; if ($d.Pcl.host -eq 'iic-n02') { $d.Read.san.disks[0].lun = 9 } }
        (Get-PclCheck $r2 'STO-008').Message | Should -Match 'different LUN IDs'
    }
    It 'fails a system LUN that was initialized, and one that is too small' {
        $r = Invoke-StorageRun (Get-SanInfra) { param($d, $q) & $script:GoodSan $d $q; $d.Read.san.disks[0].ps = 'GPT'; $d.Read.san.disks[1].gb = 5 }
        $c = Get-PclCheck $r 'STO-009' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'was initialized'
        $c.Message | Should -Match 'smaller than the 20 GB'
    }
    It 'fails MPIO that is not enabled' {
        $r = Invoke-StorageRun (Get-SanInfra) { param($d, $q) & $script:GoodSan $d $q; $d.Read.san.feature = 'Disabled' }
        $c = Get-PclCheck $r 'STO-005' 'iic-n01'
        $c.Status | Should -Be 'Failed'; $c.Remedy | Should -Match 'Enable-WindowsOptionalFeature -Online -FeatureName MultipathIO'
    }
    It 'fails an HBA port of the file that the node does not show' {
        $r = Invoke-StorageRun (Get-SanInfra) { param($d, $q) & $script:GoodSan $d $q; $d.Read.san.fc = @() } @('iic-n01')
        (Get-PclCheck $r 'STO-010' 'iic-n01').Status | Should -Be 'Failed'
    }
}

Describe 'Hybrid Fibre Channel: do not zone the HBA WWNs until after the deployment' {
    BeforeAll {
        $script:Hybrid = { $i = Get-PclInfra; $i.scenario.storage_architecture = 'hybrid'; $i['storage'] = [ordered]@{ configuration_mode = 'express'; san = [ordered]@{ type = 'fibre_channel'; array = [ordered]@{ name = 'p'; vendor = 'Pure'; model = 'FlashArray X' } } }; $i }
    }
    It 'passes when no LUN is visible before the deployment' {
        $r = Invoke-StorageRun (& $script:Hybrid)
        (Get-PclCheck $r 'STO-011').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'STO-004').Status | Should -Be 'Passed'
    }
    It 'warns, with the three workarounds, when LUNs are visible once each (MPIO claimed first)' {
        $r = Invoke-StorageRun (& $script:Hybrid) { param($d, $q) $d.Read.san.disks = @((New-SanDisk 5 'UID-P1' 0 2048)); $d.Read.san.hw = @('PURE|FlashArray') }
        $c = Get-PclCheck $r 'STO-011'
        $c.Status | Should -Be 'Warning'
        $c.Message | Should -Match "don't zone in FC HBA World Wide Names until after the Azure Local deployment"
        $c.Message | Should -Match 'MPIO claim the array first'
        $c.Message | Should -Match 'disable the FC HBA for the deployment window'
        $c.Message | Should -Match 'unzoned'
    }
    It 'fails when the visible LUNs are not claimed and show up as several disks' {
        $r = Invoke-StorageRun (& $script:Hybrid) { param($d, $q) $d.Read.san.disks = @((New-SanDisk 5 'UID-P1' 0 2048), (New-SanDisk 6 'UID-P1' 0 2048)) }
        $c = Get-PclCheck $r 'STO-011'
        $c.Status | Should -Be 'Failed'
        $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'cannot be distinguished'
        (Get-PclCheck $r 'STO-006' 'iic-n01').Remedy | Should -Match 'mpclaim -n -i -d "PURE    FlashArray      "'
    }
}

Describe 'iSCSI' {
    It 'fails the inbox driver on an iSCSI adapter and warns about the iSCSI service on a 2610 deployment' {
        $infra = Get-SanInfra; $infra.storage.san.type = 'iscsi'
        $infra.provisioning = [ordered]@{ os_version = '12.2610.1004.50' }
        foreach ($n in $infra.nodes) { $n.network_adapters += [ordered]@{ name = 'Port4'; mac_address = '00:00:5E:00:99:99'; roles = @('iscsi:a'); ip_assignment = 'none' } }
        $r = Invoke-StorageRun $infra { param($d, $q) $d.Pcl.nics += [pscustomobject]@{ n = 'Port4'; desc = 'Inbox'; st = 'Up'; speed = 25000000000; mac = 'x'; drvProv = 'Microsoft'; drvVer = '1'; idx = 9; mtu = 1514; jumbo = '1514'; rdmaCapable = $false; rdmaEnabled = $false; rdmaOp = $null; ips = @(); gw = @() }; $d.Read.san.iscsiSvc = 'Running/Automatic'; $d.Read.san.disks = @((New-SanDisk 5 'UID-A' 0 300 'RAW' 'iSCSI'), (New-SanDisk 6 'UID-B' 1 50 'RAW' 'iSCSI')); $d.Read.san.hw = @('DellEMC|PowerStore') }
        $c = Get-PclCheck $r 'STO-012' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'inbox Microsoft driver'
    }
}

Describe 'Readiness: the Environment Checker validators' {
    It 'passes when every validator succeeds, and runs the checker once for all six' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $r = Invoke-PclRun -World $w -Infra $infra -Category readiness
        foreach ($id in 'RDY-001', 'RDY-002', 'RDY-003', 'RDY-004', 'RDY-005', 'RDY-006') { (Get-PclCheck $r $id).Status | Should -Be 'Passed' -Because $id }
        $w.EcCalls | Should -Be 1
    }
    It 'imports a critical failure of a validator with its test, description and remediation, and blocks' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Ec = @{ available = $true; reason = ''; validators = @{
                Connectivity = @{ ran = $true; reason = ''; results = @(@{ name = 'C1'; title = 'Arc For Servers'; status = 'FAILURE'; severity = 'CRITICAL'; description = 'https://gbl.his.arc.azure.com is not reachable'; remediation = 'https://learn.microsoft.com/fw'; target = 'iic-n01' }, @{ name = 'C2'; title = 'Login'; status = 'SUCCESS'; severity = 'CRITICAL'; description = 'ok'; remediation = ''; target = 'iic-n01' }) }
                Hardware = @{ ran = $true; reason = ''; results = @(@{ name = 'H1'; title = 'BIOS'; status = 'FAILURE'; severity = 'WARNING'; description = 'BIOS versions differ'; remediation = ''; target = 'iic-n02' }) }
                Software = @{ ran = $true; reason = ''; results = @(@{ name = 'S1'; title = 'NTP'; status = 'SUCCESS'; severity = 'CRITICAL'; description = 'ok'; remediation = ''; target = 'x' }) }
                ActiveDirectory = @{ ran = $true; reason = ''; results = @(@{ name = 'A1'; title = 'AD OU'; status = 'SUCCESS'; severity = 'CRITICAL'; description = 'ok'; remediation = ''; target = 'x' }) }
                Network = @{ ran = $true; reason = ''; results = @(@{ name = 'N1'; title = 'IP range'; status = 'SUCCESS'; severity = 'CRITICAL'; description = 'ok'; remediation = ''; target = 'x' }) }
                ArcIntegration = @{ ran = $true; reason = ''; results = @(@{ name = 'R1'; title = 'Arc'; status = 'SUCCESS'; severity = 'CRITICAL'; description = 'ok'; remediation = ''; target = 'x' }) } } }
        $r = Invoke-PclRun -World $w -Infra $infra -Category readiness
        $c = Get-PclCheck $r 'RDY-001'
        $c.Status | Should -Be 'Failed'
        $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'Arc For Servers \[iic-n01\]: https://gbl\.his\.arc\.azure\.com is not reachable Remediation: https://learn\.microsoft\.com/fw'
        (Get-PclCheck $r 'RDY-002').Status | Should -Be 'Warning'
    }
    It 'is Skipped, with the reason, when the module is not installed (never installed by the gate), and blocks until accepted' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $v = @{}; foreach ($n in 'Connectivity', 'Hardware', 'Software', 'ActiveDirectory', 'Network', 'ArcIntegration') { $v[$n] = @{ ran = $false; reason = 'The module AzStackHci.EnvironmentChecker is not installed on this host.'; results = @() } }
        $w.Ec = @{ available = $false; reason = 'not installed'; validators = $v }
        $r = Invoke-PclRun -World $w -Infra $infra -Category readiness
        $c = Get-PclCheck $r 'RDY-001'
        $c.Status | Should -Be 'Skipped'
        $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'is not installed on this host'
        $c.Remedy | Should -Match 'never installs it'
        $r.Verdict | Should -Be 'Fail'
        $ok = Invoke-PclRun -World $w -Infra $infra -Category readiness -AcceptSkipped 'RDY-001,RDY-002,RDY-003,RDY-004,RDY-005,RDY-006'
        $ok.Verdict | Should -Be 'Pass'
    }
    It 'does not run the Active Directory validator for a local identity design' {
        $infra = Get-PclInfra -Identity local_identity
        $r = Invoke-PclRun -Infra $infra -Category readiness
        (Get-PclCheck $r 'RDY-004').Status | Should -Be 'NotApplicable'
    }
    It 'builds the request from the file: nodes, pool, subnet and the ARM intents for the network validator' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $seen = [System.Collections.Generic.List[object]]::new()
        $null = Invoke-PclRun -World $w -Infra $infra -Category readiness -Override @{ EnvChecker = { param($Request) $seen.Add($Request); @{ available = $true; reason = ''; validators = @{} } }.GetNewClosure() }
        $seen.Count | Should -Be 1
        $q = $seen[0]
        @($q.Nodes).Count | Should -Be 2
        $q.IpPools[0].StartingAddress | Should -Be '192.0.2.20'
        $q.ManagementSubnet | Should -Be '192.0.2.0/24'
        @($q.Intents).Count | Should -Be 2
        $q.Validators | Should -Contain 'ArcIntegration'
    }
}
