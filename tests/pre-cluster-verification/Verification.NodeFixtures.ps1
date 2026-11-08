# Fixtures for the node, network, storage and readiness verification tests. Dot-sourced inside BeforeAll. Fakes only: no Azure, no
# Active Directory, no node. The "world" is what the nodes would say; Remote.Invoke answers from it as the JSON the real payload returns,
# so the real Node.* adapter members (the parsing, the sections, the one-call-per-node cache) are exercised too.

$script:VerDir = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'common', 'arm-deployment', 'verification'))

function Import-VerModule {
    <# Imports one category module and returns it; its two commands are called as & $mod.ExportedCommands[...]. #>
    param([Parameter(Mandatory)][ValidateSet('Nodes', 'Network', 'Storage')][string]$Name)
    Import-Module ([IO.Path]::Combine($script:VerDir, "AzlVerification.$Name.psm1")) -Force -PassThru
}

function New-VerInfra {
    <# The infrastructure file of the lab shape: two nodes, a management+compute intent and a storage intent, Active Directory, S2D. #>
    param([string]$Architecture = 's2d', [switch]$WithSan)
    $infra = [ordered]@{
        scenario     = [ordered]@{ identity = 'active_directory'; storage_architecture = $Architecture; connectivity = 'connected'; cloud = 'public'; outbound_path = 'direct' }
        azure        = [ordered]@{ location = 'eastus' }
        provisioning = [ordered]@{ os_version = '12.2610.1004.50' }
        hardware     = [ordered]@{ cpu_cores = 32; memory_gib = 256 }
        nodes        = @(
            [ordered]@{ name = 'n01'; network_adapters = @(
                    [ordered]@{ name = 'Port0'; roles = @('management', 'compute'); ip_address = '192.0.2.11' }, [ordered]@{ name = 'Port1'; roles = @('management', 'compute') },
                    [ordered]@{ name = 'Port2'; roles = @('storage') }, [ordered]@{ name = 'Port3'; roles = @('storage') }) }
            [ordered]@{ name = 'n02'; network_adapters = @(
                    [ordered]@{ name = 'Port0'; roles = @('management', 'compute'); ip_address = '192.0.2.12' }, [ordered]@{ name = 'Port1'; roles = @('management', 'compute') },
                    [ordered]@{ name = 'Port2'; roles = @('storage') }, [ordered]@{ name = 'Port3'; roles = @('storage') }) }
        )
        networking   = [ordered]@{
            management  = [ordered]@{ subnet = '192.0.2.0/24'; gateway = '192.0.2.1'; dns_servers = @('192.0.2.4', '192.0.2.5'); infrastructure_pool = [ordered]@{ start = '192.0.2.20'; end = '192.0.2.29' } }
            ntp_servers = @('192.0.2.4', '192.0.2.5')
            intents     = @(
                [ordered]@{ name = 'mgmt_compute'; traffic = @('management', 'compute'); adapters = @('Port0', 'Port1') }
                [ordered]@{ name = 'storage'; traffic = @('storage'); adapters = @('Port2', 'Port3') })
        }
        identity     = [ordered]@{ local_admin = [ordered]@{ username = 'azl-admin' } }
    }
    if ($WithSan) {
        $infra.storage = [ordered]@{ san = [ordered]@{ type = 'fibre_channel'; array = [ordered]@{ vendor = 'Pure'; model = 'FlashArray' }; infra_volume_lun_id = '0'; performance_history_lun_id = '1' } }
        foreach ($n in $infra.nodes) { $n.san = [ordered]@{ hbas = @([ordered]@{ slot = 'Slot2'; ports = @([ordered]@{ wwpn = '10:00:00:00:00:00:00:11' }, [ordered]@{ wwpn = '10:00:00:00:00:00:00:12' }) }) } }
    }
    return $infra
}

function New-VerSnapshot {
    <# What a healthy node says (the shape of the real payload). #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][datetime]$Now)
    $nic = { param($n, $i, $ips, $gw, $rdma, $drv, $desc) @{ n = $n; desc = $desc; st = 'Up'; admin = 'Up'; speed = 25000000000; mac = ('0000000000{0:x2}' -f $i); drvProv = $drv; drvVer = '2.0'; idx = ($i + 4); mtu = 1514; jumbo = $(if ($rdma) { '9014' } else { '1514' })
            rdmaCapable = $rdma; rdmaEnabled = $rdma; rdmaOp = $(if ($rdma) { $true } else { $null }); ips = $ips; gw = $gw; dhcp = 'Disabled' } }
    $disks = @(@{ num = 0; name = 'BOSS-N1'; model = 'BOSS-N1'; serial = 'B0'; uid = 'B0'; uidFormat = 'SCSI'; bus = 'SATA'; size = 480000000000; style = 'GPT'; parts = 3; offline = $false; boot = $true; system = $true; lun = 0; port = 0; target = 0 })
    $phys = @(@{ num = 0; name = 'BOSS-N1'; serial = 'B0'; size = 480000000000; bus = 'SATA'; media = 'SSD'; canPool = $false; reason = 'Not Healthy'; health = 'Healthy'; boot = $true; system = $true; style = 'GPT'; parts = 3 })
    foreach ($i in 1..4) {
        $disks += @{ num = $i; name = "NVMe $i"; model = 'NVMe'; serial = "N$i"; uid = "N$i"; uidFormat = 'EUI64'; bus = 'NVMe'; size = 3840000000000; style = 'RAW'; parts = 0; offline = $false; boot = $false; system = $false; lun = $null; port = $null; target = $null }
        $phys += @{ num = $i; name = "NVMe $i"; serial = "N$i"; size = 3840000000000; bus = 'NVMe'; media = 'SSD'; canPool = $true; reason = ''; health = 'Healthy'; boot = $false; system = $false; style = 'RAW'; parts = 0 }
    }
    @{
        host = $Name; utc = $Now.ToString('o'); err = @{}
        os = @{ caption = 'Azure Local'; version = '10.0.26100'; ubr = '33650'; build = '10.0.26100.33650' }
        cs = @{ partOfDomain = $false; domain = 'WORKGROUP'; memBytes = [int64]274877906944; manufacturer = 'Dell'; model = 'AX-760'; hypervisor = $true }
        cpu = @(1..2 | ForEach-Object { @{ caption = 'Intel64 Family 6'; family = 179; manufacturer = 'GenuineIntel'; maxClock = 2000; cores = 16; logical = 32; threads = 32; vt = $true; slat = $true } })
        mem = @(1..8 | ForEach-Object { [int64]34359738368 })
        fw = @{ biosVersion = '2.1.0'; secureBoot = $true; tpmPresent = $true; tpmReady = $true; tpmSpec = '2.0, 0, 1.38' }
        features = @(@('Hyper-V', 'Failover-Clustering', 'Data-Center-Bridging', 'NetworkATC', 'BitLocker', 'FS-Data-Deduplication', 'RSAT-AD-PowerShell', 'RSAT-Clustering-PowerShell', 'Multipath-IO') | ForEach-Object { @{ n = $_; found = $true; installed = $true } })
        reboot = @{ cbs = $false; wu = $false; files = $false; rename = $false }
        time = @{ src = '192.0.2.4'; type = 'NTP'; peers = '192.0.2.4,0x8 192.0.2.5,0x8' }
        dns = @(@{ n = 'Port0'; idx = 4; servers = @('192.0.2.4', '192.0.2.5') }, @{ n = 'Port1'; idx = 5; servers = @() })
        disks = $disks; physical = $phys; pools = @(); vdisks = 0; cluster = @{ svc = 'Stopped'; name = '' }
        nics = @(
            (& $nic 'Port0' 0 @($Ip) @('192.0.2.1') $false 'Dell' 'Dell LOM 25G'), (& $nic 'Port1' 1 @() @() $false 'Dell' 'Dell LOM 25G'),
            (& $nic 'Port2' 2 @() @() $true 'Mellanox Technologies Ltd.' 'Mellanox ConnectX-6'), (& $nic 'Port3' 3 @() @() $true 'Mellanox Technologies Ltd.' 'Mellanox ConnectX-6'))
        remoteNdis = @(); clusSvc = @{}
        proxy = @{ winhttp = 'Direct access (no proxy server).'; wininet = ''; envHttps = ''; envHttp = ''; envNo = '' }
        vms = @{ switches = @(); intents = @() }
        mpio = @{ feature = 'Enabled'; availableHw = @(); supportedHw = @(); claims = @(); lb = 'RR'; mpclaimLines = 3 }
        fc = @(); iscsi = $null; ec = @(@{ name = 'AzStackHci.EnvironmentChecker'; version = '1.2605.1' })
        tcp = @(@{ h = '192.0.2.4'; p = 53; ok = $true }, @{ h = '192.0.2.5'; p = 53; ok = $true })
        https = @('https://login.microsoftonline.com', 'https://management.azure.com', 'https://gbl.his.arc.azure.com', 'https://mcr.microsoft.com', 'https://eastus.his.arc.azure.com' | ForEach-Object { @{ u = $_; ok = $true; status = '404'; err = '' } })
        ping = @(@{ a = '192.0.2.1'; ok = $true })
    }
}

function Add-VerLabSan {
    <# The lab failure: two Pure FlashArray Fibre Channel LUNs, four paths each, seen as eight disks because MPIO claims nothing. -Claimed gives the fixed state. #>
    param([Parameter(Mandatory)]$Snapshot, [switch]$Claimed)
    $lunSerial = @('6B10C3E4A11F0001', '6B10C3E4A11F0002')
    if ($Claimed) {
        foreach ($l in 0..1) { $Snapshot.disks += @{ num = (10 + $l); name = 'PURE FlashArray Multi-Path Disk Device'; model = 'FlashArray'; serial = $lunSerial[$l]; uid = "624A9370$($lunSerial[$l])"; uidFormat = 'NAA'; bus = 'Fibre Channel'; size = $(if ($l -eq 0) { 268435456000 } else { 21474836480 }); style = 'RAW'; parts = 0; offline = $true; boot = $false; system = $false; lun = $l; port = 1; target = 0 } }
        $Snapshot.mpio.claims = @(@{ mpio = 0; disk = '10'; policy = 'RR'; dsm = 'Microsoft DSM' }, @{ mpio = 1; disk = '11'; policy = 'RR'; dsm = 'Microsoft DSM' })
        $Snapshot.mpio.availableHw = @(@{ vendor = 'PURE'; product = 'FlashArray'; bus = 'Fibre Channel'; multipathed = $true; spc3 = $true })
        $Snapshot.mpio.supportedHw = @(@{ vendor = 'PURE'; product = 'FlashArray' })
    }
    else {
        $n = 10
        foreach ($path in 0..3) { foreach ($l in 0..1) {
                $Snapshot.disks += @{ num = $n++; name = 'PURE FlashArray'; model = 'FlashArray'; serial = $lunSerial[$l]; uid = "624A9370$($lunSerial[$l])"; uidFormat = 'NAA'; bus = 'Fibre Channel'; size = $(if ($l -eq 0) { 268435456000 } else { 21474836480 }); style = 'RAW'; parts = 0; offline = $true; boot = $false; system = $false; lun = $l; port = $path; target = 0 } } }
        $Snapshot.mpio.availableHw = @(@{ vendor = 'PURE'; product = 'FlashArray'; bus = 'Fibre Channel'; multipathed = $false; spc3 = $true })
    }
    $Snapshot.fc = @(@{ wwpn = '10:00:00:00:00:00:00:11'; wwnn = '20:00:00:00:00:00:00:11' }, @{ wwpn = '10:00:00:00:00:00:00:12'; wwnn = '20:00:00:00:00:00:00:12' })
}

function New-VerWorld {
    <# The nodes of an infrastructure object, healthy. World.Snapshot[node] is changed by the tests. Calls counts the Remote.Invoke calls per node. #>
    param([Parameter(Mandatory)]$Infra, [datetime]$Now = [datetime]::Parse('2026-11-08T12:00:00Z', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal))
    $snap = [ordered]@{}
    foreach ($n in $Infra.nodes) { $snap[$n.name] = New-VerSnapshot -Name $n.name -Ip ($n.network_adapters | Where-Object { $_.ip_address } | Select-Object -First 1).ip_address -Now $Now }
    [pscustomobject]@{ Now = $Now; Snapshot = $snap; Down = @{}; Calls = [System.Collections.Generic.List[string]]::new(); Ec = $null }
}

function New-VerContext {
    <#
    .SYNOPSIS
        A context for the checks: the REAL default adapter of the module, with Remote.Invoke replaced by a fake that answers from the world
        as the JSON of the real payload, and Readiness.Run replaced by a fake. -Adapter replaces any member after that.
    #>
    param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)]$Infra, [Parameter(Mandatory)]$World, [hashtable]$Settings = @{}, [hashtable]$Adapter = @{})
    $adapters = & $Module.ExportedCommands['Get-AzlVerificationAdapterDefault']
    $w = $World
    $adapters['Remote'] = @{ Invoke = {
            param($Node, $ScriptBlock, $ArgumentList)
            $w.Calls.Add($Node)
            if ($w.Down.ContainsKey($Node)) { throw $w.Down[$Node] }
            return ($w.Snapshot[$Node] | ConvertTo-Json -Depth 10 -Compress)
        }.GetNewClosure()
    }
    $adapters['Now'] = { $w.Now }.GetNewClosure()
    $adapters['Readiness'] = @{ Run = {
            param($Validator, $Context)
            if ($w.Ec -and $w.Ec.ContainsKey($Validator)) { return $w.Ec[$Validator] }
            return @{ Available = $true; Results = @(foreach ($n in $w.Snapshot.Keys) { @{ Node = $n; Name = "Test-$Validator"; Title = "$Validator test"; Status = 'SUCCESS'; Severity = 'CRITICAL'; Description = 'ok'; Remediation = ''; Target = $n } }) }
        }.GetNewClosure()
    }
    foreach ($k in $Adapter.Keys) { $adapters[$k] = $Adapter[$k] }
    @{ Infrastructure = $Infra; Handoff = $null; OsReport = $null; Settings = $Settings; Adapters = $adapters }
}

function Get-VerDefinition {
    param([Parameter(Mandatory)]$Module, [string]$Id)
    $defs = @(& $Module.ExportedCommands['Get-AzlVerificationCheckDefinition'])
    if ($Id) { return @($defs | Where-Object { $_.Id -eq $Id })[0] }
    return $defs
}

function Invoke-VerCheck {
    <# Runs one check by id: the results as an array. NotApplicable when Applies says no, as the engine does. #>
    param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)]$Context)
    $d = Get-VerDefinition -Module $Module -Id $Id
    if (-not $d) { throw "no check $Id" }
    if (-not (& $d.Applies $Context)) { return @([pscustomobject]@{ Status = 'NotApplicable'; Node = '*'; Message = 'does not apply'; Remedy = ''; Evidence = '' }) }
    return @(& $d.Run $Context)
}
