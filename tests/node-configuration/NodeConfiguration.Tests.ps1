#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for OS configuration (idempotent, read first, change only what differs). No node and no Azure is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\azure-local\AzlAzure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodeTransport.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodeConfiguration.psm1') -Force
    Import-Module powershell-yaml
    $script:Fixture = Join-Path $repo 'tests\fixtures\infrastructure.fc-san.yml'
    $script:HandoffFile = Join-Path $repo 'tests\fixtures\handoff.v2.json'

    function Get-Infra { Import-AzlInfrastructure -Path $script:Fixture -SkipValidation }

    # One local disk the Read script reports as leftover (n number, id the name the wipe list uses, sn serial, uid unique id, size bytes, model, bus, ps partition style).
    function New-WipeDisk([int]$Number, [string]$Serial, [string]$Bus = 'NVMe', [string]$Style = 'GPT') {
        [pscustomobject]@{ n = $Number; id = $Serial; sn = $Serial; uid = "UID-$Serial"; size = [int64]1000GB; model = 'ACME NVMe 1T'; bus = $Bus; ps = $Style; why = "partition style $Style" }
    }
    # The stor section of a Read: leftover disks, and whether the node belongs to a deployed cluster (Deployed) or says nothing about it (NoClusterEvidence).
    function New-WipeStor([object[]]$Disk, [switch]$Deployed, [switch]$NoClusterEvidence) {
        $s = [pscustomobject]@{ pools = 1; vdisks = 2; dirty = @($Disk) }
        if (-not $NoClusterEvidence) { $s | Add-Member -NotePropertyName cluster -NotePropertyValue ([pscustomobject]@{ deployed = [bool]$Deployed; why = @(if ($Deployed) { 'HKLM:\Cluster exists' }) }) }
        $s
    }
    # A node spec whose infrastructure.yml sets hardware.sbe.delivery (and node_pull_url).
    function Get-SbeSpec([string]$Delivery, [string]$Url = '') {
        $infra = Get-Infra
        $infra['hardware']['sbe']['delivery'] = $Delivery
        if ($PSBoundParameters.ContainsKey('Url')) { $infra['hardware']['sbe']['node_pull_url'] = $Url }
        $bundle = [pscustomobject]@{ Name = 'SBE_Dell_X_1.0'; ZipName = 'SBE_Dell_X_1.0.zip'; HashSource = 'x'; Deployment = [ordered]@{}
            Files = @([pscustomobject]@{ Name = 'SBE_Dell_X_1.0.zip'; Path = 'D:\sbe\SBE_Dell_X_1.0.zip'; Size = 100; Sha256 = 'AA' }, [pscustomobject]@{ Name = 'SBE_Dell_X_1.0.xml'; Path = 'D:\sbe\SBE_Dell_X_1.0.xml'; Size = 10; Sha256 = 'BB' }) }
        Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0] -SbeBundle $bundle
    }

    # One AZLRESULT line, as a node script writes it.
    function ConvertTo-ResultLine([object]$Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
    }

    # A node that already matches the spec: what the Read script would return for it.
    function New-ConfiguredState([object]$Spec, [string]$Boot = '2026-11-07T01:00:00Z') {
        $nics = foreach ($p in $Spec.Ports) {
            $isMgmt = $p.IsManagement
            [pscustomobject]@{
                n = "OS$($p.Name)"; mac = $p.Mac; st = $(if ($p.Roles -contains 'unused') { 'Disabled' } else { 'Up' }); pci = 'PCI\VEN_15B3&DEV_101D'; drv = '24.4.1.0'; desc = 'x'
                dhcp = 'Disabled'; ips = $(if ($isMgmt) { @("$($Spec.Management.Ip)/$($Spec.Management.Prefix)/Manual") } else { @() })
                gw = $(if ($isMgmt) { @($Spec.Management.Gateway) } else { @() }); dns = $(if ($isMgmt) { @($Spec.Management.Dns) } else { @() }); vlan = $null
            }
        }
        [pscustomobject]@{
            v = 1; host = $Spec.Hostname; boot = $Boot; os = '10.0.26100.1'; reboot = $false; nics = @($nics)
            remote = [pscustomobject]@{ winrm = 'Running'; winrmStart = 'Automatic'; listeners = 1; rdpDeny = 0; rdpRules = 3; icmp4 = 1; icmp6 = 1 }
            time = [pscustomobject]@{ type = 'NTP'; peers = ($Spec.Ntp | ForEach-Object { "$_,0x8" }) -join ' '; src = $Spec.Ntp[0] }
            sbe = @(); drv = @()
            admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $true }
            stor = [pscustomobject]@{ pools = 0; vdisks = 0; dirty = @() }
            san = [pscustomobject]@{
                feature = 'Enabled'; hw = @('DellEMC|PowerStore'); lb = 'RR'
                set = [pscustomobject]@{ RetryCount = '3'; UseCustomPathRecoveryTime = 'Enabled'; CustomPathRecoveryTime = '10'; DiskTimeoutValue = '30' }
                fc = @($Spec.San.ExpectedWwpn | ForEach-Object { [pscustomobject]@{ wwpn = $_; up = 'Online' } }); iqn = @(); iscsiSvc = ''; iscsiClaim = ''
                disks = @(
                    [pscustomobject]@{ n = 1; bus = 'Fibre Channel'; gb = 300; ps = 'RAW'; sn = 'SERIAL-INFRA'; uid = 'UID-INFRA'; lun = 0; paths = 4; st = 'Online' }
                    [pscustomobject]@{ n = 2; bus = 'Fibre Channel'; gb = 50; ps = 'RAW'; sn = 'SERIAL-PERF'; uid = 'UID-PERF'; lun = 1; paths = 4; st = 'Online' })
            }
            err = [pscustomobject]@{}
        }
    }

    # A transport that serves canned states and records what it was asked to run.
    function New-FakeTransport([object[]]$States, [scriptblock]$OnApply, [scriptblock]$OnGuard) {
        $log = [System.Collections.Generic.List[object]]::new()
        $queue = [System.Collections.Generic.Queue[object]]::new()
        foreach ($s in $States) { $queue.Enqueue($s) }
        $last = [ref]$States[-1]
        $encode = ${function:ConvertTo-ResultLine}
        if (-not $OnGuard) { $OnGuard = { param($Kind, $P) if ($Kind -eq 'Stage') { @{ v = 1; staged = $true; changeId = $P.changeId; cookie = 'cookie1'; machineSid = 'S-1-5-21-1' } } else { @{ v = 1; found = $true; identityOk = $true; nowUtc = '2026-11-07T10:00:00Z'; state = @{ state = 'Committed'; reason = 'All checks passed.'; repairs = @() } } } } }
        $transport = [pscustomobject]@{ Kind = 'WinRM'; Invoke = $null; Stage = $null; Log = $log; GetAddress = { '192.0.2.11' }; GetPort = { 5985 }; SetAddress = {}; CloseSession = {} }
        $transport.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            if ($Script -match 'AZL-GUARD-STAGE') { $kind = 'GuardStage' } elseif ($Script -match 'AZL-GUARD-STATUS') { $kind = 'GuardStatus' } elseif ($Script -match 'function Invoke-Action') { $kind = 'Apply' } elseif ($Script -match 'shutdown\.exe') { $kind = 'Restart' } elseif ($Script -match 'last-apply') { $kind = 'Collect' } else { $kind = 'Read' }
            $log.Add([pscustomobject]@{ Kind = $kind; Parameters = $Parameters; Secrets = $Secrets })
            switch ($kind) {
                'Read' { if ($queue.Count -gt 0) { $last.Value = $queue.Dequeue() }; [pscustomobject]@{ Output = (& $encode $last.Value); Failed = $false; Error = ''; State = 'Succeeded' } }
                'Apply' { $r = & $OnApply $Parameters; [pscustomobject]@{ Output = (& $encode $r); Failed = $false; Error = ''; State = 'Succeeded' } }
                'Restart' { [pscustomobject]@{ Output = (& $encode ([pscustomobject]@{ restartScheduled = $true })); Failed = $false; Error = ''; State = 'Succeeded' } }
                'GuardStage' { $r = & $OnGuard 'Stage' $Parameters; [pscustomobject]@{ Output = (& $encode $r); Failed = $false; Error = ''; State = 'Succeeded' } }
                'GuardStatus' { $r = & $OnGuard 'Status' $Parameters; [pscustomobject]@{ Output = (& $encode $r); Failed = $false; Error = ''; State = 'Succeeded' } }
            }
        }.GetNewClosure()
        $transport.Stage = { param($Self, $Node, $LocalPath, $RemotePath, $Sha256) [pscustomobject]@{ Name = (Split-Path $LocalPath -Leaf); Url = $null } }
        return $transport
    }
    $script:Resolver = { param($Ref) 'P@ssw0rd-from-vault' }
    # A clock that never waits, and a port probe that always answers.
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc)
    $script:FakeClock = [pscustomobject]@{ Now = { $script:Now }; Sleep = { param($Seconds) $script:Now = $script:Now.AddSeconds($Seconds) } }
    $script:PortUp = { param($Address, $Port) $true }
    # Safety net: no test may reach Azure.
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
}

Describe 'Node spec' {
    It 'finds the management port by MAC, not by name' {
        $infra = Get-Infra
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        $spec.Management.Mac | Should -Be '00005e005310'
        $spec.Management.Ip | Should -Be '192.0.2.11'
        $spec.Management.Prefix | Should -Be 24
        $spec.Management.Gateway | Should -Be '192.0.2.1'
        @($spec.Ports | Where-Object IsManagement).Count | Should -Be 1
    }
    It 'reads the Arc resource ID and the verification from the ZTP handoff' {
        $infra = Get-Infra
        $handoff = Read-AzlHandoff -Path $script:HandoffFile
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[1] -Handoff $handoff
        $spec.ArcResourceId | Should -Match 'machines/iic-n02$'
        $spec.Handoff.ManagementAddressVerified | Should -BeFalse
        $spec.Handoff.InstalledBuild | Should -Be '12.2610.1004.50'
    }
    It 'knows the MSDSM entry for a Dell PowerStore and the expected WWPNs' {
        $infra = Get-Infra
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        $spec.San.Msdsm.Hardware[0].vendorId | Should -Be 'DellEMC'
        $spec.San.ExpectedWwpn | Should -Be @('1000000000000011', '1000000000000012')
        $spec.San.CheckLuns | Should -BeTrue
    }
    It 'rejects the handoff of schema 1' {
        $f = Join-Path $TestDrive 'old.json'
        '{"schemaVersion":1,"nodes":[]}' | Set-Content $f
        { Read-AzlHandoff -Path $f } | Should -Throw '*schema 2*'
    }
}

Describe 'Comparison: a configured node changes nothing' {
    It 'has no Change and nothing Blocked' {
        $infra = Get-Infra
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        $plan = Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec)
        @($plan | Where-Object Action -eq 'Change') | Should -BeNullOrEmpty
        @($plan | Where-Object Action -eq 'Blocked') | Should -BeNullOrEmpty
        @($plan | Where-Object Action -eq 'Ok').Count | Should -BeGreaterThan 10
    }
    It 'matches ports by MAC even when the OS names them differently' {
        $infra = Get-Infra
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        $state = New-ConfiguredState $spec
        # the OS calls the management port "Slot 9 Port 9"; only the MAC identifies it
        $state.nics | Where-Object mac -eq $spec.Management.Mac | ForEach-Object { $_.n = 'Slot 9 Port 9' }
        @(Compare-AzlNodeState -Spec $spec -State $state | Where-Object Action -eq 'Change') | Should -BeNullOrEmpty
    }
}

Describe 'Comparison: only the differences are changes' {
    BeforeEach {
        $infra = Get-Infra
        $script:Spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        $script:State = New-ConfiguredState $script:Spec
    }
    It 'turns DHCP off on a port whose ip_assignment is none, and only that port' {
        $nic = $script:State.nics | Where-Object { $_.mac -eq '00005e005312' }
        $nic.dhcp = 'Enabled'; $nic.ips = @('203.0.113.9/24/Dhcp'); $nic.gw = @('203.0.113.1')
        $changes = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change')
        $changes.Count | Should -Be 1
        $changes[0].Apply.kind | Should -Be 'nic-clean'
        $changes[0].Apply.mac | Should -Be '00005e005312'
    }
    It 'sets the management address only when it is wrong' {
        ($script:State.nics | Where-Object { $_.mac -eq $script:Spec.Management.Mac }).ips = @('192.0.2.99/24/Dhcp')
        ($script:State.nics | Where-Object { $_.mac -eq $script:Spec.Management.Mac }).dhcp = 'Enabled'
        $changes = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change')
        $changes.Count | Should -Be 1
        $changes[0].Apply.kind | Should -Be 'nic-static'
        $changes[0].Apply.ip | Should -Be '192.0.2.11'
        $changes[0].Apply.gateway | Should -Be '192.0.2.1'
    }
    It 'sets DNS in order, only when it differs' {
        ($script:State.nics | Where-Object { $_.mac -eq $script:Spec.Management.Mac }).dns = @('192.0.2.5', '192.0.2.4')
        $c = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change')
        $c.Count | Should -Be 1
        $c[0].Apply.kind | Should -Be 'nic-dns'
    }
    It 'sets NTP only when the peers differ, ignoring the flags' {
        $script:State.time.peers = '192.0.2.5,0x9 192.0.2.4,0x8'
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change') | Should -BeNullOrEmpty
        $script:State.time.peers = 'time.windows.com,0x8'
        (Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change').Apply.kind | Should -Be 'ntp'
    }
    It 'renames the host and says a restart is needed' {
        $script:State.host = 'WIN-ABC123'
        $c = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change')
        $c.Count | Should -Be 1
        $c[0].Apply.kind | Should -Be 'hostname'
        $c[0].Apply.name | Should -Be 'iic-n01'
    }
    It 'does not rename when only the case differs' {
        $script:State.host = 'IIC-N01'
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change') | Should -BeNullOrEmpty
    }
    It 'disables a port the file marks unused, and only when it is not already disabled' {
        ($script:State.nics | Where-Object { $_.mac -eq '00005e005314' }).st = 'Up'
        (Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change').Apply.kind | Should -Be 'nic-disable'
    }
    It 'creates the local administrator when it is missing, and sets the password' {
        $script:State.admin = [pscustomobject]@{ ex = $false; en = $false; adm = $false; pw = $null }
        $c = Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change'
        $c.Apply.kind | Should -Be 'admin'
        $c.Apply.setPassword | Should -BeTrue
    }
    It 'leaves a valid password alone' {
        $script:State.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $true }
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Step -eq 'LocalAdmin' -and $_.Action -eq 'Change' }) | Should -BeNullOrEmpty
    }
    It 'refuses the built-in Administrator as the deployment account' {
        $script:Spec.LocalAdmin.Username = 'Administrator'
        $b = Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Step -eq 'LocalAdmin' }
        $b.Action | Should -Be 'Blocked'
    }
    It 'blocks on a second default gateway held by a port the file does not list' {
        $script:State.nics += [pscustomobject]@{ n = 'Port9'; mac = '00005e0053ff'; st = 'Up'; pci = ''; drv = ''; desc = ''; dhcp = 'Enabled'; ips = @('203.0.113.9/24/Dhcp'); gw = @('203.0.113.1'); dns = @(); vlan = $null }
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Blocked').Count | Should -Be 1
    }
    It 'blocks when no port has the management MAC' {
        ($script:State.nics | Where-Object { $_.mac -eq $script:Spec.Management.Mac }).mac = '00005e00ffff'
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Action -eq 'Blocked' -and $_.Item -like 'management MAC*' }).Count | Should -Be 1
    }
    It 'respects -Step' {
        $script:State.host = 'WIN-ABC123'
        $script:State.time.peers = 'x'
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State -Step Time | Where-Object Action -eq 'Change').Count | Should -Be 1
    }
}


Describe 'Comparison: the management address, per mode' {
    BeforeEach {
        $script:Infra = Get-Infra
        # Changes the management port of node 0 (found by role and MAC, never by slot or name) and returns spec and state.
        $script:For = {
            param([string]$Mode, [AllowNull()][string]$Ip = '192.0.2.11')
            $p = $script:Infra.nodes[0].network_adapters | Where-Object { 'management' -in $_.roles -and $_.ip_assignment -ne 'none' } | Select-Object -First 1
            $p.ip_assignment = $Mode
            if ($Ip) { $p.ip_address = $Ip } else { $p.Remove('ip_address') }
            $spec = Get-AzlNodeSpec -Infrastructure $script:Infra -Node $script:Infra.nodes[0]
            $state = New-ConfiguredState $spec
            [pscustomobject]@{ Spec = $spec; State = $state; Nic = ($state.nics | Where-Object { $_.mac -eq $spec.Management.Mac }) }
        }
        $script:MgmtItem = { param($Plan) $Plan | Where-Object { $_.Step -eq 'Network' -and $_.Item -like 'management *' -and $_.Item -notlike 'management VLAN*' } }
    }
    It 'static (Mode B or C): sets the address by MAC after the install reset the port to DHCP, and names the mode' {
        $c = & $script:For 'static'
        $c.Nic.ips = @('192.0.2.116/24/Dhcp'); $c.Nic.dhcp = 'Enabled'; $c.Nic.gw = @('192.0.2.1')
        $item = & $script:MgmtItem (Compare-AzlNodeState -Spec $c.Spec -State $c.State)
        $item.Action | Should -Be 'Change'
        $item.Apply.kind | Should -Be 'nic-static'
        $item.Apply.mac | Should -Be $c.Spec.Management.Mac
        $item.Note | Should -Match '^Mode [BC] \(Static .*\): set by MAC'
    }
    It 'static: says why ZTP did not verify it, from the handoff' {
        $handoff = Read-AzlHandoff -Path $script:HandoffFile
        $spec = Get-AzlNodeSpec -Infrastructure $script:Infra -Node $script:Infra.nodes[1] -Handoff $handoff
        $spec.Handoff.ManagementMode | Should -Be 'B'
        $state = New-ConfiguredState $spec
        ($state.nics | Where-Object { $_.mac -eq $spec.Management.Mac }) | ForEach-Object { $_.ips = @('192.0.2.120/24/Dhcp'); $_.dhcp = 'Enabled' }
        $item = & $script:MgmtItem (Compare-AzlNodeState -Spec $spec -State $state)
        $item.Action | Should -Be 'Change'
        $item.Note | Should -Match "^ZTP didn't verify it: Mode B \(Static with DHCP\): the management port Port0"
    }
    It 'dhcp_reservation (Mode A): leaves DHCP on and verifies the reserved address' {
        $c = & $script:For 'dhcp_reservation'
        $c.Nic.ips = @('192.0.2.11/24/Dhcp'); $c.Nic.dhcp = 'Enabled'
        $plan = Compare-AzlNodeState -Spec $c.Spec -State $c.State
        (& $script:MgmtItem $plan).Action | Should -Be 'Ok'
        @($plan | Where-Object { $_.Action -eq 'Change' -and $_.Step -eq 'Network' }) | Should -BeNullOrEmpty
        $c.Nic.ips = @('192.0.2.99/24/Dhcp')
        $item = & $script:MgmtItem (Compare-AzlNodeState -Spec $c.Spec -State $c.State)
        $item.Action | Should -Be 'Info'
        $item.Apply | Should -BeNullOrEmpty
        $item.Note | Should -Match 'Mode A \(Reserved\): expected the reserved 192\.0\.2\.11 from DHCP; check the reservation for MAC'
    }
    It 'dhcp_reservation (Mode A) without ip_address: verified when the port has any DHCP address' {
        $c = & $script:For 'dhcp_reservation' $null
        $c.Nic.ips = @('192.0.2.140/24/Dhcp'); $c.Nic.dhcp = 'Enabled'
        $item = & $script:MgmtItem (Compare-AzlNodeState -Spec $c.Spec -State $c.State)
        $item.Action | Should -Be 'Ok'
        $item.Note | Should -Match "can't be compared"
        $c.Nic.ips = @()
        (& $script:MgmtItem (Compare-AzlNodeState -Spec $c.Spec -State $c.State)).Action | Should -Be 'Info'
    }
    It '<_>: leaves the management port alone' -ForEach 'dhcp', 'preconfigured' {
        $c = & $script:For $_
        $c.Nic.ips = @('192.0.2.140/24/Dhcp'); $c.Nic.dhcp = 'Enabled'
        $plan = Compare-AzlNodeState -Spec $c.Spec -State $c.State
        $item = & $script:MgmtItem $plan
        $item.Action | Should -Be 'Ok'
        $item.Note | Should -Match '^Left as it is'
        @($plan | Where-Object { $_.Step -in 'Network', 'Dns' -and $_.Action -eq 'Change' }) | Should -BeNullOrEmpty
    }
    It 'turns DHCP and the gateway off on every other port with ip_assignment none, whatever the mode' {
        foreach ($mode in 'static', 'dhcp_reservation', 'dhcp', 'preconfigured') {
            $script:Infra = Get-Infra
            $c = & $script:For $mode
            $c.Nic.ips = @('192.0.2.11/24/Dhcp'); $c.Nic.dhcp = 'Enabled'
            foreach ($other in @($c.State.nics | Where-Object { $_.mac -ne $c.Spec.Management.Mac -and $_.st -ne 'Disabled' })) { $other.dhcp = 'Enabled'; $other.ips = @('198.51.100.40/26/Dhcp'); $other.gw = @('198.51.100.1') }
            $clean = @(Compare-AzlNodeState -Spec $c.Spec -State $c.State | Where-Object { $_.Apply -and $_.Apply.kind -eq 'nic-clean' })
            $clean.Count | Should -Be @($c.Spec.Ports | Where-Object { -not $_.IsManagement -and $_.IpAssignment -eq 'none' -and $_.Roles -notcontains 'unused' }).Count -Because $mode
        }
    }
    It 'applies the management port''s static address before any other port loses DHCP (Mode C reaches Arc through another port)' {
        $c = & $script:For 'static'
        $c.Nic.ips = @(); $c.Nic.dhcp = 'Enabled'; $c.Nic.gw = @()
        $other = $c.State.nics | Where-Object { $_.mac -eq '00005e005312' }
        $other.dhcp = 'Enabled'; $other.ips = @('198.51.100.40/26/Dhcp'); $other.gw = @('198.51.100.1')
        # The OS lists the management port last.
        $c.State.nics = @(@($c.State.nics | Where-Object { $_.mac -ne $c.Spec.Management.Mac }) + @($c.Nic))
        $kinds = @(Compare-AzlNodeState -Spec $c.Spec -State $c.State -Step Network | Where-Object { $_.Action -eq 'Change' } | ForEach-Object { $_.Apply.kind })
        $kinds | Should -Be @('nic-static', 'nic-clean')
    }
}

Describe 'Comparison: SAN' {
    BeforeEach {
        $infra = Get-Infra
        $script:Spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        $script:State = New-ConfiguredState $script:Spec
    }
    It 'enables MPIO when the feature is off and defers the MSDSM check' {
        $script:State.san.feature = 'Disabled'
        $plan = Compare-AzlNodeState -Spec $script:Spec -State $script:State
        ($plan | Where-Object Action -eq 'Change').Apply.kind | Should -Be 'mpio-feature'
        ($plan | Where-Object { $_.Item -eq 'MSDSM' }).Action | Should -Be 'Skipped'
    }
    It 'registers the vendor hardware ID, the policy and the MPIO settings that differ' {
        $script:State.san.hw = @(); $script:State.san.lb = 'None'; $script:State.san.set.RetryCount = '6'
        $kinds = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change' | ForEach-Object { $_.Apply.kind } | Where-Object { $_ })
        $kinds | Should -Contain 'msdsm-hw'
        $kinds | Should -Contain 'msdsm-lb'
        $kinds | Should -Contain 'mpio-setting'
    }
    It 'sets only the MPIO settings that differ' {
        $script:State.san.set.RetryCount = '6'
        $c = Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Apply -and $_.Apply.kind -eq 'mpio-setting' }
        @($c.Apply.settings.Keys) | Should -Be @('RetryCount')
    }
    It 'blocks on a WWPN the node does not report' {
        $script:State.san.fc = @($script:State.san.fc[0])
        $b = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Blocked')
        $b.Count | Should -Be 1
        $b[0].Item | Should -Be 'WWPN 1000000000000012'
    }
    It 'blocks when the infrastructure LUN is not visible' {
        $script:State.san.disks = @($script:State.san.disks[1])
        (Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Action -eq 'Blocked' }).Item | Should -BeLike 'infrastructure volume*'
    }
    It 'blocks when an infrastructure LUN has been initialized' {
        $script:State.san.disks[0].ps = 'GPT'
        $b = Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Action -eq 'Blocked' }
        $b.Note | Should -BeLike '*must stay RAW*'
    }
    It 'never offers to change a SAN LUN' {
        $script:State.san.disks[0].ps = 'GPT'
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Step -eq 'SanVerify' -and $_.Action -eq 'Change' }) | Should -BeNullOrEmpty
    }
    It 'does nothing SAN-related for a Storage Spaces Direct design' {
        $infra = Get-Infra
        $infra.scenario.storage_architecture = 's2d'
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        $spec.San | Should -BeNullOrEmpty
        @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $script:Spec) | Where-Object { $_.Step -in 'Mpio', 'SanVerify' }) | Should -BeNullOrEmpty
    }
    Context 'storage left over: a deployed cluster is never wiped without the one-shot flag' {
        BeforeEach {
            $infra = Get-Infra; $infra.scenario.storage_architecture = 's2d'
            $script:S2dSpec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
            $script:DirtyState = New-ConfiguredState $script:Spec
        }
        It 'a node that belongs to a cluster is Blocked with the reason, although -ClearStorage is on' {
            $script:DirtyState.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3') -Deployed
            $c = Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage
            $c.Action | Should -Be 'Blocked'
            $c.Apply | Should -BeNullOrEmpty
            $c.Note | Should -Match 'HKLM:\\Cluster exists'
            $c.Note | Should -Match 'ConfirmWipeDeployedCluster'
        }
        It '-ConfirmWipeDeployedCluster turns it into a Change that carries the confirmation and the disks to wipe' {
            $script:DirtyState.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3'), (New-WipeDisk 4 'SN-4') -Deployed
            $c = Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage -ConfirmWipeDeployedCluster
            $c.Action | Should -Be 'Change'
            $c.Apply.kind | Should -Be 'storage-clear'
            $c.Apply.confirmDeployedCluster | Should -BeTrue
            @($c.Apply.serials) | Should -Be @('SN-3', 'SN-4')
            $c.Note | Should -Match 'DEPLOYED CLUSTER'
        }
        It 'a node with no cluster evidence is wiped without the flag, and the action does not carry the confirmation' {
            $script:DirtyState.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3')
            $c = Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage
            $c.Action | Should -Be 'Change'
            $c.Apply.confirmDeployedCluster | Should -BeFalse
            @($c.Apply.serials) | Should -Be @('SN-3')
        }
        It 'a node that does not say whether it belongs to a cluster is not wiped' {
            $script:DirtyState.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3') -NoClusterEvidence
            $c = Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage -ConfirmWipeDeployedCluster
            $c.Action | Should -Be 'Blocked'
            $c.Note | Should -Match 'did not report'
        }
        It 'a disk with no serial number and no unique id cannot be named in the wipe list, so it is Blocked' {
            $nameless = New-WipeDisk 3 ''
            $script:DirtyState.stor = New-WipeStor -Disk $nameless
            $c = Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage
            $c.Action | Should -Be 'Blocked'
            $c.Note | Should -Match 'neither a serial number nor a unique id'
        }
        It 'the current value names every disk by serial, size, model, bus and partition style' {
            $script:DirtyState.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3')
            $c = Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage
            $c.Current | Should -Match 'SN-3'
            $c.Current | Should -Match '1000 GB'
            $c.Current | Should -Match 'ACME NVMe 1T'
            $c.Current | Should -Match 'NVMe'
            $c.Current | Should -Match 'GPT'
        }
        It 'a disk that is not on the approved list is Blocked, and only the approved disks are named in the action' {
            $script:DirtyState.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3'), (New-WipeDisk 4 'SN-4')
            $c = Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage -ApprovedWipeId @('SN-3')
            $c.Action | Should -Be 'Blocked'
            $c.Note | Should -Match 'SN-4'
            $c.Note | Should -Match 'approved'
            $ok = Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage -ApprovedWipeId @('SN-3', 'SN-4', 'SN-9')
            $ok.Action | Should -Be 'Change'
            @($ok.Apply.serials) | Should -Be @('SN-3', 'SN-4')
        }
        It 'an empty approved list approves nothing' {
            $script:DirtyState.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3')
            (Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage -ApprovedWipeId @()).Action | Should -Be 'Blocked'
        }
        It 'Get-AzlNodeWipeItem gives the wipe list its serial, size, model, bus and partition style' {
            $script:DirtyState.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3')
            $plan = @(Compare-AzlNodeState -Spec $script:S2dSpec -State $script:DirtyState -Step ClearStorage -ClearStorage)
            $item = @(Get-AzlNodeWipeItem -Plan $plan -State $script:DirtyState)
            $item.Count | Should -Be 1
            $item[0].serial | Should -Be 'SN-3'
            $item[0].id | Should -Be 'SN-3'
            $item[0].sizeGb | Should -Be 1000
            $item[0].model | Should -Be 'ACME NVMe 1T'
            $item[0].bus | Should -Be 'NVMe'
            $item[0].partitionStyle | Should -Be 'GPT'
            $item[0].number | Should -Be 3
            @(Get-AzlNodeWipeItem -Plan @() -State $script:DirtyState) | Should -BeNullOrEmpty
        }
    }
    It 'leaves leftover local storage as Blocked unless -ClearStorage is given, and never lists SAN disks for it' {
        $script:State.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3')
        $infra = Get-Infra; $infra.scenario.storage_architecture = 's2d'
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        (Compare-AzlNodeState -Spec $spec -State $script:State -Step ClearStorage).Action | Should -Be 'Blocked'
        $c = Compare-AzlNodeState -Spec $spec -State $script:State -Step ClearStorage -ClearStorage
        $c.Action | Should -Be 'Change'
        $c.Apply.kind | Should -Be 'storage-clear'
    }
}

Describe 'Comparison: SBE and drivers' {
    BeforeEach {
        $infra = Get-Infra
        $bundle = [pscustomobject]@{ Name = 'SBE_Dell_X_1.0'; ZipName = 'SBE_Dell_X_1.0.zip'; HashSource = 'x'; Deployment = [ordered]@{}
            Files = @([pscustomobject]@{ Name = 'SBE_Dell_X_1.0.zip'; Path = 'D:\sbe\SBE_Dell_X_1.0.zip'; Size = 100; Sha256 = 'AA' }, [pscustomobject]@{ Name = 'SBE_Dell_X_1.0.xml'; Path = 'D:\sbe\SBE_Dell_X_1.0.xml'; Size = 10; Sha256 = 'BB' }) }
        $script:Spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0] -SbeBundle $bundle
        $script:State = New-ConfiguredState $script:Spec
        $script:State.sbe = @([pscustomobject]@{ n = 'SBE_Dell_X_1.0.zip'; len = 100; ok = $true }, [pscustomobject]@{ n = 'SBE_Dell_X_1.0.xml'; len = 10; ok = $true })
    }
    It 'delivers a file that is absent and nothing else (node_pull)' {
        $script:Spec = Get-SbeSpec node_pull 'https://sbe.example.invalid/sbe/dell/'
        $script:State.sbe = @([pscustomobject]@{ n = 'SBE_Dell_X_1.0.zip'; len = 100; ok = $true })
        $c = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object Action -eq 'Change')
        $c.Count | Should -Be 1
        $c[0].Apply.kind | Should -Be 'sbe-file'
        $c[0].Apply.route | Should -Be 'node_pull'
        $c[0].Apply.name | Should -Be 'SBE_Dell_X_1.0.xml'
        $c[0].Apply.url | Should -Be 'https://sbe.example.invalid/sbe/dell/SBE_Dell_X_1.0.xml'
        $c[0].Apply.Contains('localPath') | Should -BeFalse
    }
    It 'winrm_copy names the local file and no address' {
        $script:Spec = Get-SbeSpec winrm_copy
        $script:State.sbe = @()
        $c = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Action -eq 'Change' -and $_.Step -eq 'Sbe' })
        $c.Count | Should -Be 2
        $c[0].Apply.route | Should -Be 'winrm_copy'
        $c[0].Apply.localPath | Should -Be 'D:\sbe\SBE_Dell_X_1.0.zip'
        $c[0].Apply.Contains('url') | Should -BeFalse
    }
    It 'skip (and no key at all) reports the package as not delivered and changes nothing' {
        $script:State.sbe = @()
        foreach ($spec in $script:Spec, (Get-SbeSpec skip)) {
            $plan = @(Compare-AzlNodeState -Spec $spec -State $script:State)
            @($plan | Where-Object Action -eq 'Change') | Should -BeNullOrEmpty
            $sbe = @($plan | Where-Object Step -eq 'Sbe')
            $sbe.Count | Should -Be 2
            $sbe | ForEach-Object { $_.Action | Should -Be 'Info'; $_.Note | Should -BeLike 'NOT DELIVERED*' }
            @($plan | Where-Object { $_.Apply -and $_.Apply.kind -eq 'sbe-file' }) | Should -BeNullOrEmpty
        }
    }
    It 'node_pull with no address is blocked, not guessed' {
        $script:Spec = Get-SbeSpec node_pull ''
        $script:State.sbe = @()
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Blocked' }).Count | Should -Be 2
    }
    It 'lists the Sbe step last' {
        $script:Spec = Get-SbeSpec node_pull 'https://sbe.example.invalid/sbe'
        $script:State.sbe = @()
        $steps = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State -ClearStorage | ForEach-Object Step)
        $lastNonSbe = [array]::LastIndexOf($steps, 'ClearStorage')
        $firstSbe = [array]::IndexOf($steps, 'Sbe')
        $firstSbe | Should -BeGreaterThan $lastNonSbe
    }
    It 'builds the address a node pulls from' {
        Get-AzlSbePullUrl -Base 'https://h/sbe/' -Name 'SBE A.zip' | Should -Be 'https://h/sbe/SBE%20A.zip'
        Get-AzlSbePullUrl -Base '\\files\sbe\dell\' -Name 'a.zip' | Should -Be '\\files\sbe\dell\a.zip'
    }
    It 'waits for the SBE before it decides on drivers' {
        $script:State.sbe = @()
        (Compare-AzlNodeState -Spec $script:Spec -State $script:State -Step Drivers).Action | Should -Be 'Skipped'
    }
    It 'installs a driver only for a port whose version is older than the SBE''s' {
        $script:State.drv = @([pscustomobject]@{ inf = 'mlx5.inf'; ver = '25.1.2.0'; entry = 'DriversGE/Network/Mellanox/mlx5.inf'; ids = @('PCI\VEN_15B3&DEV_101D') })
        $c = @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Step -eq 'Drivers' -and $_.Action -eq 'Change' -and $_.Apply })
        $c.Count | Should -Be 1
        $c[0].Apply.kind | Should -Be 'driver'
        $c[0].Apply.ver | Should -Be '25.1.2.0'
        $script:State.nics | ForEach-Object { $_.drv = '25.1.2.0' }
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Step -eq 'Drivers' -and $_.Action -eq 'Change' }) | Should -BeNullOrEmpty
    }
    It 'never downgrades a newer driver' {
        $script:State.drv = @([pscustomobject]@{ inf = 'mlx5.inf'; ver = '23.0.0.0'; entry = 'DriversGE/Network/x/mlx5.inf'; ids = @('PCI\VEN_15B3&DEV_101D') })
        @(Compare-AzlNodeState -Spec $script:Spec -State $script:State | Where-Object { $_.Step -eq 'Drivers' -and $_.Action -eq 'Change' }) | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-AzlNodeConfiguration' {
    BeforeEach {
        $infra = Get-Infra
        $script:Spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
    }
    It 'reads once and applies nothing on a configured node, with -Execute too' {
        $t = New-FakeTransport @(New-ConfiguredState $script:Spec) { throw 'Apply must not run' }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver
        $r.Converged | Should -BeTrue
        @($t.Log | Where-Object Kind -eq 'Apply') | Should -BeNullOrEmpty
        @($t.Log | Where-Object Kind -eq 'Read').Count | Should -Be 1
        $r.Changes | Should -BeNullOrEmpty
    }
    It 'in plan mode reads and reports changes but never applies' {
        $state = New-ConfiguredState $script:Spec
        $state.host = 'WIN-X'
        $t = New-FakeTransport @($state) { throw 'Apply must not run' }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -SecretResolver $script:Resolver
        @($r.Plan | Where-Object Action -eq 'Change').Count | Should -Be 1
        @($t.Log | Where-Object Kind -eq 'Apply') | Should -BeNullOrEmpty
        $r.Converged | Should -BeFalse
        $r.Executed | Should -BeFalse
    }
    It 'with -Execute applies only the differing items, then reads again and converges' {
        $bad = New-ConfiguredState $script:Spec
        $bad.time.peers = 'time.windows.com,0x8'
        ($bad.nics | Where-Object { $_.mac -eq '00005e005312' }).dhcp = 'Enabled'
        $mid = New-ConfiguredState $script:Spec
        ($mid.nics | Where-Object { $_.mac -eq '00005e005312' }).dhcp = 'Enabled'
        $good = New-ConfiguredState $script:Spec
        $t = New-FakeTransport @($bad, $mid, $good) { throw 'No inline Apply is expected: time and DHCP-off are guarded changes' }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        @($t.Log | Where-Object Kind -eq 'Apply') | Should -BeNullOrEmpty
        $stages = @($t.Log | Where-Object Kind -eq 'GuardStage')
        $stages.Count | Should -Be 2
        @($stages[0].Parameters.config.items | ForEach-Object { $_.kind }) | Should -Be @('ntp')
        @($stages[1].Parameters.config.items | ForEach-Object { $_.kind }) | Should -Be @('nic-clean')
        $stages[0].Parameters.config.group | Should -Be 'Services'
        $stages[1].Parameters.config.group | Should -Be 'Network'
        $r.Converged | Should -BeTrue
        @($r.Guard | Where-Object State -eq 'Committed').Count | Should -Be 2
    }
    It 'passes the administrator password as a secret, never as a parameter' {
        $bad = New-ConfiguredState $script:Spec
        $bad.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }
        $t = New-FakeTransport @($bad, (New-ConfiguredState $script:Spec)) { param($p) [pscustomobject]@{ reboot = $false; results = @() } }
        $null = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver
        $apply = $t.Log | Where-Object Kind -eq 'Apply'
        $apply.Secrets.adminPassword | Should -Be 'P@ssw0rd-from-vault'
        ($apply.Parameters | ConvertTo-Json -Depth 6) | Should -Not -Match 'P@ssw0rd'
    }
    It 'restarts once when an action asks and waits for a new boot time' {
        $bad = New-ConfiguredState $script:Spec; $bad.san.feature = 'Disabled'
        $after = New-ConfiguredState $script:Spec -Boot '2026-11-07T02:00:00Z'
        Mock -ModuleName AzlNodeConfiguration Start-Sleep {}
        $t = New-FakeTransport @($bad, $after, $after) { param($p) [pscustomobject]@{ reboot = $true; results = @([pscustomobject]@{ id = 'Mpio/feature'; status = 'changed'; detail = 'enabled' }) } }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        $r.Restarted | Should -BeTrue
        @($t.Log | Where-Object Kind -eq 'Restart').Count | Should -Be 1
        $r.Converged | Should -BeTrue
    }
    It 'does not restart with -NoRestart' {
        $bad = New-ConfiguredState $script:Spec; $bad.san.feature = 'Disabled'
        $t = New-FakeTransport @($bad, $bad) { param($p) [pscustomobject]@{ reboot = $true; results = @([pscustomobject]@{ id = 'Mpio/feature'; status = 'changed'; detail = 'enabled' }) } }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -NoRestart -MaxPasses 1 -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        @($t.Log | Where-Object Kind -eq 'Restart') | Should -BeNullOrEmpty
        $r.Restarted | Should -BeFalse
    }
    It 'stops and reports a failed action' {
        $bad = New-ConfiguredState $script:Spec; $bad.san.feature = 'Disabled'
        $t = New-FakeTransport @($bad) { param($p) [pscustomobject]@{ reboot = $false; results = @([pscustomobject]@{ id = 'Mpio/feature'; status = 'failed'; detail = 'denied' }) } }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        $r.Converged | Should -BeFalse
        ($r.Changes | Where-Object Status -eq 'failed').Detail | Should -Be 'denied'
        @($t.Log | Where-Object Kind -eq 'Apply').Count | Should -Be 1
    }
    Context 'the storage wipe' {
        BeforeEach {
            $infra = Get-Infra; $infra.scenario.storage_architecture = 's2d'
            $script:S2dSpec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
            $script:WipeOk = { param($p) [pscustomobject]@{ reboot = $false; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = 'cleared' } }) } }
        }
        It 'is tried once per run, even when the node still shows leftover storage on every later read' {
            $dirty = New-ConfiguredState $script:S2dSpec
            $dirty.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3')
            $t = New-FakeTransport @($dirty) $script:WipeOk
            $r = Invoke-AzlNodeConfiguration -Spec $script:S2dSpec -Transport $t -Execute -ClearStorage -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
            $wipes = @($t.Log | Where-Object Kind -eq 'Apply' | ForEach-Object { $_.Parameters.actions } | Where-Object kind -eq 'storage-clear')
            $wipes.Count | Should -Be 1
            @($wipes[0].serials) | Should -Be @('SN-3')
            $r.Converged | Should -BeFalse -Because 'the node still shows leftover storage, and the run says so instead of wiping again'
            @($r.Plan | Where-Object { $_.Step -eq 'ClearStorage' -and $_.Action -eq 'Change' }).Count | Should -Be 1
        }
        It 'a deployed cluster is not wiped without -ConfirmWipeDeployedCluster: no Apply call at all' {
            $dirty = New-ConfiguredState $script:S2dSpec
            $dirty.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3') -Deployed
            $t = New-FakeTransport @($dirty) { throw 'Apply must not run' }
            $r = Invoke-AzlNodeConfiguration -Spec $script:S2dSpec -Transport $t -Execute -ClearStorage -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
            @($t.Log | Where-Object Kind -eq 'Apply') | Should -BeNullOrEmpty
            @($r.Blocked | Where-Object Step -eq 'ClearStorage').Count | Should -Be 1
            $r.Converged | Should -BeFalse
        }
        It 'with -ConfirmWipeDeployedCluster the action carries the confirmation' {
            $dirty = New-ConfiguredState $script:S2dSpec
            $dirty.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3') -Deployed
            $t = New-FakeTransport @($dirty) $script:WipeOk
            $null = Invoke-AzlNodeConfiguration -Spec $script:S2dSpec -Transport $t -Execute -ClearStorage -ConfirmWipeDeployedCluster -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
            $wipe = @($t.Log | Where-Object Kind -eq 'Apply' | ForEach-Object { $_.Parameters.actions } | Where-Object kind -eq 'storage-clear')
            $wipe.Count | Should -Be 1
            $wipe[0].confirmDeployedCluster | Should -BeTrue
        }
        It 'a disk the approval does not name is never sent to the node' {
            $dirty = New-ConfiguredState $script:S2dSpec
            $dirty.stor = New-WipeStor -Disk (New-WipeDisk 3 'SN-3'), (New-WipeDisk 4 'SN-4')
            $t = New-FakeTransport @($dirty) { throw 'Apply must not run' }
            $r = Invoke-AzlNodeConfiguration -Spec $script:S2dSpec -Transport $t -Execute -ClearStorage -ApprovedWipeId @('SN-3') -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
            @($t.Log | Where-Object Kind -eq 'Apply') | Should -BeNullOrEmpty
            @($r.Blocked | Where-Object Step -eq 'ClearStorage').Count | Should -Be 1
        }
    }
    Context 'delivering the SBE package' {
        BeforeEach {
            $script:OkApply ={ param($p) [pscustomobject]@{ reboot = $false; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = 'ok' } }) } }
            $script:BothPresent = @([pscustomobject]@{ n = 'SBE_Dell_X_1.0.zip'; len = 100; ok = $true }, [pscustomobject]@{ n = 'SBE_Dell_X_1.0.xml'; len = 10; ok = $true })
        }
        It 'node_pull sends the node an address to pull from, and no file and no secret address' {
            $spec = Get-SbeSpec node_pull 'https://sbe.example.invalid/sbe'
            $bad = New-ConfiguredState $spec; $bad.sbe = @()
            $good = New-ConfiguredState $spec; $good.sbe = $script:BothPresent
            $t = New-FakeTransport @($bad, $good) $script:OkApply
            $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -SecretResolver $script:Resolver
            $apply = @($t.Log | Where-Object Kind -eq 'Apply')
            $apply.Count | Should -Be 1
            @($apply[0].Secrets.Keys | Where-Object { $_ -like 'sas:*' }) | Should -BeNullOrEmpty
            $actions = @($apply[0].Parameters.actions)
            $actions.Count | Should -Be 2
            $actions[0].url | Should -Be 'https://sbe.example.invalid/sbe/SBE_Dell_X_1.0.zip'
            $actions[0].sha256 | Should -Be 'AA'
            $actions[0].Contains('localPath') | Should -BeFalse
            $r.Converged | Should -BeTrue
        }
        It 'delivers the package after every other step, in a call of its own' {
            $spec = Get-SbeSpec node_pull 'https://sbe.example.invalid/sbe'
            $bad = New-ConfiguredState $spec; $bad.sbe = @(); $bad.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }
            $good = New-ConfiguredState $spec; $good.sbe = $script:BothPresent
            $t = New-FakeTransport @($bad, $good) $script:OkApply
            $null = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -SecretResolver $script:Resolver
            $apply = @($t.Log | Where-Object Kind -eq 'Apply')
            $apply.Count | Should -Be 2
            @($apply[0].Parameters.actions | ForEach-Object kind) | Should -Contain 'admin'
            @($apply[0].Parameters.actions | ForEach-Object kind) | Should -Not -Contain 'sbe-file'
            @($apply[1].Parameters.actions | ForEach-Object kind | Select-Object -Unique) | Should -Be 'sbe-file'
        }
        It 'skip changes nothing about the package, does not fail the node and keeps the other steps' {
            $spec = Get-SbeSpec skip
            $bad = New-ConfiguredState $spec; $bad.sbe = @(); $bad.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }
            $good = New-ConfiguredState $spec; $good.sbe = @()
            $t = New-FakeTransport @($bad, $good) $script:OkApply
            $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -SecretResolver $script:Resolver
            $apply = @($t.Log | Where-Object Kind -eq 'Apply')
            $apply.Count | Should -Be 1
            @($apply[0].Parameters.actions | ForEach-Object kind) | Should -Be 'admin'
            $r.Converged | Should -BeTrue
            @($r.Plan | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Info' }).Count | Should -Be 2
        }
        It 'a failed pull is reported, tried once, and does not undo the other steps' {
            $spec = Get-SbeSpec node_pull 'https://sbe.example.invalid/sbe'
            $bad = New-ConfiguredState $spec; $bad.sbe = @(); $bad.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }
            $still = New-ConfiguredState $spec; $still.sbe = @()
            $t = New-FakeTransport @($bad, $still) { param($p) [pscustomobject]@{ reboot = $false; results = @($p.actions | ForEach-Object { $isSbe = $_.kind -eq 'sbe-file'; [pscustomobject]@{ id = $_.id; status = $(if ($isSbe) { 'failed' } else { 'changed' }); detail = $(if ($isSbe) { 'The remote name could not be resolved' } else { 'ok' }) } }) } }
            $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -SecretResolver $script:Resolver
            @($t.Log | Where-Object Kind -eq 'Apply').Count | Should -Be 2
            ($r.Changes | Where-Object { $_.Id -like 'Sbe/*' }).Status | Select-Object -Unique | Should -Be 'failed'
            ($r.Changes | Where-Object Id -eq 'LocalAdmin/user').Status | Should -Be 'changed'
            $r.Converged | Should -BeFalse
        }
        It 'winrm_copy over Arc without a WinRM path says so and does not stop the other steps' {
            $spec = Get-SbeSpec winrm_copy
            $bad = New-ConfiguredState $spec; $bad.sbe = @(); $bad.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }
            $still = New-ConfiguredState $spec; $still.sbe = @()
            $t = New-FakeTransport @($bad, $still) $script:OkApply
            $t.Kind = 'ArcRunCommand'
            $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -SecretResolver $script:Resolver
            ($r.Changes | Where-Object Id -eq 'LocalAdmin/user').Status | Should -Be 'changed'
            $sbe = @($r.Changes | Where-Object { $_.Id -like 'Sbe/*' })
            $sbe.Count | Should -Be 2
            $sbe[0].Status | Should -Be 'failed'
            $sbe[0].Detail | Should -BeLike '*needs a WinRM path*'
            $r.Converged | Should -BeFalse
        }
        It 'winrm_copy copies each file through the WinRM transport with its SHA-256' {
            $spec = Get-SbeSpec winrm_copy
            $bad = New-ConfiguredState $spec; $bad.sbe = @()
            $good = New-ConfiguredState $spec; $good.sbe = $script:BothPresent
            $arc = New-FakeTransport @($bad, $good) $script:OkApply
            $copies = [System.Collections.Generic.List[object]]::new()
            $winrm = [pscustomobject]@{ Kind = 'WinRM'; Stage = $null }
            $winrm.Stage = { param($Self, $Node, $LocalPath, $RemotePath, $Sha256) $null = $Self; $copies.Add([pscustomobject]@{ Node = $Node; Local = $LocalPath; Remote = $RemotePath; Sha = $Sha256 }); [pscustomobject]@{ Name = (Split-Path $LocalPath -Leaf); Url = $null } }.GetNewClosure()
            $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $arc -SbeTransport $winrm -Execute -SecretResolver $script:Resolver
            $copies.Count | Should -Be 2
            $copies[0].Local | Should -Be 'D:\sbe\SBE_Dell_X_1.0.zip'
            $copies[0].Remote | Should -Be 'C:\SBE\SBE_Dell_X_1.0.zip'
            $copies[0].Sha | Should -Be 'AA'
            @($arc.Log | Where-Object Kind -eq 'Apply') | Should -BeNullOrEmpty
            $r.Converged | Should -BeTrue
        }
        It 'a copy that fails once is not retried for every file' {
            $spec = Get-SbeSpec winrm_copy
            $bad = New-ConfiguredState $spec; $bad.sbe = @()
            $arc = New-FakeTransport @($bad) $script:OkApply
            $attempts = [System.Collections.Generic.List[string]]::new()
            $winrm = [pscustomobject]@{ Kind = 'WinRM'; Stage = $null }
            $winrm.Stage = { param($Self, $Node, $LocalPath, $RemotePath, $Sha256) $null = $Self, $Node, $RemotePath, $Sha256; $attempts.Add($LocalPath); throw 'WinRM cannot connect to 192.0.2.11:5985' }.GetNewClosure()
            $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $arc -SbeTransport $winrm -Execute -SecretResolver $script:Resolver
            $attempts.Count | Should -Be 1
            @($r.Changes | Where-Object Status -eq 'failed').Count | Should -Be 2
        }
    }
    It 'the computer name is a guarded change of its own, with a restart the node finishes; -NoRestart leaves the restart out' {
        $bad = New-ConfiguredState $script:Spec; $bad.host = 'WIN-X'
        $good = New-ConfiguredState $script:Spec
        $t = New-FakeTransport @($bad, $good) { throw 'no inline Apply' }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        $stage = @($t.Log | Where-Object Kind -eq 'GuardStage')[0]
        $stage.Parameters.config.group | Should -Be 'Hostname'
        $stage.Parameters.config.restartAfter | Should -BeTrue
        $r.Restarted | Should -BeTrue
        $t2 = New-FakeTransport @($bad, $good) { throw 'no inline Apply' }
        $r2 = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t2 -Execute -NoRestart -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        @($t2.Log | Where-Object Kind -eq 'GuardStage')[0].Parameters.config.restartAfter | Should -BeFalse
        $r2.Restarted | Should -BeFalse
    }
}

Describe 'The merged flow: guarded changes first, the SBE package last, a plan reads only' {
    BeforeEach {
        $script:OkApply = { param($p) [pscustomobject]@{ reboot = $false; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = 'ok' } }) } }
        $script:BothPresent = @([pscustomobject]@{ n = 'SBE_Dell_X_1.0.zip'; len = 100; ok = $true }, [pscustomobject]@{ n = 'SBE_Dell_X_1.0.xml'; len = 10; ok = $true })
    }
    It 'the computer name (a guarded change) comes before the SBE package, which is delivered in an Apply call of its own' {
        $spec = Get-SbeSpec node_pull 'https://sbe.example.invalid/sbe'
        $bad = New-ConfiguredState $spec; $bad.sbe = @(); $bad.host = 'WIN-X'
        $half = New-ConfiguredState $spec; $half.sbe = @()
        $good = New-ConfiguredState $spec; $good.sbe = $script:BothPresent
        $t = New-FakeTransport @($bad, $half, $good) $script:OkApply
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        $kinds = @($t.Log | Where-Object { $_.Kind -in 'GuardStage', 'Apply' } | ForEach-Object Kind)
        $kinds[0] | Should -Be 'GuardStage'
        $kinds[-1] | Should -Be 'Apply'
        @($t.Log | Where-Object Kind -eq 'Apply').Count | Should -Be 1
        @((@($t.Log | Where-Object Kind -eq 'Apply')[0]).Parameters.actions | ForEach-Object kind | Select-Object -Unique) | Should -Be 'sbe-file'
        $r.Converged | Should -BeTrue
    }
    It 'a plan reads only: no run command is listed or deleted, nothing is applied' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $bad = New-ConfiguredState $script:Spec; $bad.host = 'WIN-X'
        $t = New-FakeTransport @($bad) { throw 'no Apply in a plan' }
        $t.Kind = 'ArcRunCommand'
        $t | Add-Member -NotePropertyName ListRunCommands -NotePropertyValue ({ param($Self, $Node) $calls.Add('list'); @() }.GetNewClosure())
        $t | Add-Member -NotePropertyName DeleteRunCommand -NotePropertyValue ({ param($Self, $Node, $Name) $calls.Add("delete $Name") }.GetNewClosure())
        $null = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -SecretResolver $script:Resolver
        $calls.Count | Should -Be 0
        @($t.Log | Where-Object { $_.Kind -notin 'Read', 'GuardStatus' }).Count | Should -Be 0 -Because 'a plan only reads: the one extra call is the read-only status of the last guarded change'
    }
    It 'Plan and Apply both end by reading the node''s last guarded change, with no change id, no token and no write' {
        foreach ($execute in $false, $true) {
            $good = New-ConfiguredState $script:Spec
            $t = New-FakeTransport @($good) { throw 'nothing to apply' } {
                param($Kind, $P)
                if ($Kind -eq 'Status') { @{ v = 1; found = $true; identityOk = $true; state = @{ changeId = '5c073442ba6d'; group = 'Management'; state = 'RolledBack'; reason = 'no answer on the new address'; checks = @(@{ name = 'gateway-ping'; ok = $false; detail = 'no reply' }); repairs = @() }; log = @('line 1', 'line 2') } }
                else { throw 'no staging in this test' }
            }
            $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute:$execute -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
            $status = @($t.Log | Where-Object Kind -eq 'GuardStatus')
            $status.Count | Should -Be 1
            @($status[0].Parameters.Keys) | Should -Be @('logTail')
            $status[0].Parameters.logTail | Should -Be 20
            $r.LastGuard.State | Should -Be 'RolledBack'
            $r.LastGuard.ChangeId | Should -Be '5c073442ba6d'
            @($r.LastGuard.Log).Count | Should -Be 2
            @($t.Log | Where-Object Kind -in 'GuardStage', 'Apply').Count | Should -Be 0
        }
    }
    It 'a run that throws carries the node''s last guarded change on the exception, so the report can still say what the node did' {
        $bad = New-ConfiguredState $script:Spec; $bad.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }
        $t = New-FakeTransport @($bad) { throw 'the apply call stalled' } { param($Kind, $P) if ($Kind -eq 'Stage') { throw 'unused' } else { @{ v = 1; found = $true; identityOk = $true; state = @{ changeId = 'c1'; group = 'Hostname'; state = 'InProgress'; reason = 'applying' }; log = @() } } }
        $caught = $null
        try { $null = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['AzlLastGuard'].ChangeId | Should -Be 'c1'
    }
    It 'an Apply lists the leftover run commands of earlier runs once, before the node is touched' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $good = New-ConfiguredState $script:Spec
        $t = New-FakeTransport @($good) { throw 'nothing to apply' }
        $t.Kind = 'ArcRunCommand'
        $t | Add-Member -NotePropertyName ListRunCommands -NotePropertyValue ({ param($Self, $Node) $calls.Add('list'); @() }.GetNewClosure())
        $t | Add-Member -NotePropertyName DeleteRunCommand -NotePropertyValue ({ param($Self, $Node, $Name) $calls.Add("delete $Name") }.GetNewClosure())
        $null = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        @($calls) | Should -Be @('list')
    }
}

Describe 'Transport layer' {
    It 'round-trips an AZLRESULT line' {
        $obj = [pscustomobject]@{ host = 'n1'; list = @(1, 2, 3) }
        (ConvertTo-AzlNodeResult -Text ("noise`n" + (ConvertTo-ResultLine $obj) + "`n")).host | Should -Be 'n1'
    }
    It 'returns $null when the output holds no result' {
        ConvertTo-AzlNodeResult -Text 'nothing here' | Should -BeNullOrEmpty
    }
    It 'Arc Run Command creates, polls, reads and deletes the run command, with the secret protected' {
        $calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName AzlNodeTransport Start-Sleep {}
        Mock -ModuleName AzlNodeTransport Invoke-AzlArm {
            $calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            switch ($Method) {
                'GET' { if ($Path -like '*runCommands*') { [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; instanceView = [pscustomobject]@{ executionState = 'Succeeded'; exitCode = 0; output = (ConvertTo-ResultLine ([pscustomobject]@{ ok = 1 })); error = '' } } } } else { [pscustomobject]@{ location = 'eastus' } } }
                default { [pscustomobject]@{} }
            }
        }
        $t = New-AzlArcRunCommandTransport -ArcResourceId @{ n1 = '/subscriptions/s/resourceGroups/r/providers/Microsoft.HybridCompute/machines/n1' } -PollSeconds 1
        $r = Invoke-AzlNodeScript -Transport $t -Node n1 -Script 'x' -Parameters @{ a = 1 } -Secrets @{ adminPassword = 'secret' }
        $r.ok | Should -Be 1
        $put = $calls | Where-Object Method -eq 'PUT'
        $put.Path | Should -BeLike '*/machines/n1/runCommands/azl-osconfig-*'
        $put.Body.properties.protectedParameters[0].name | Should -Be 'SecretsB64'
        ($put.Body.properties.parameters | ConvertTo-Json -Depth 5) | Should -Not -Match 'secret'
        @($calls | Where-Object Method -eq 'DELETE').Count | Should -Be 1
    }
    It 'Arc path can''t carry a file and points at hardware.sbe.delivery' {
        $t = New-AzlArcRunCommandTransport -ArcResourceId @{ n1 = '/x' }
        { Send-AzlNodeFile -Transport $t -Node n1 -LocalPath 'D:\f.zip' -RemotePath 'C:\SBE\f.zip' } | Should -Throw '*hardware.sbe.delivery*'
        (Get-Command New-AzlArcRunCommandTransport).Parameters.Keys | Should -Not -Contain 'StagingStorageAccount'
    }
}

Describe 'SBE bundle' {
    BeforeAll {
        function New-SbeFolder([string]$Hash) {
            $dir = Join-Path $TestDrive ("sbe-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory $dir | Out-Null
            $zip = Join-Path $dir 'SBE_Dell_16G_5.0.1.zip'
            Set-Content -LiteralPath $zip -Value 'package'
            $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            if (-not $Hash) { $Hash = $actual }
            Set-Content -LiteralPath (Join-Path $dir 'SBE_Dell_16G_5.0.1.xml') -Value '<x/>'
            @"
<SBEUpdatesManifest><ManifestInfo CreationDate="2026-09-01"/>
<ApplicableUpdate Version="5.0.1" Family="16G-Intel"><UpdateInfo><UpdateName>SBE_Dell_16G_5.0.1</UpdateName><Publisher>Dell</Publisher><PackageHash>$Hash</PackageHash></UpdateInfo></ApplicableUpdate>
</SBEUpdatesManifest>
"@ | Set-Content -LiteralPath (Join-Path $dir 'SBE_Discovery_Dell.xml')
            return $dir
        }
    }
    It 'checks the hash and returns the ARM SBE values' {
        $dir = New-SbeFolder
        $b = Get-AzlSbeBundle -Path $dir -OfflineManifest
        $b.Files.Count | Should -Be 3
        $b.Deployment.sbeVersion | Should -Be '5.0.1'
        $b.Deployment.sbeFamily | Should -Be '16G-Intel'
        $b.Deployment.sbePublisher | Should -Be 'Dell'
        $b.Deployment.sbeManifestCreationDate | Should -Be '2026-09-01'
    }
    It 'throws when the package does not match the published hash' {
        $dir = New-SbeFolder -Hash ('0' * 64)
        { Get-AzlSbeBundle -Path $dir -OfflineManifest } | Should -Throw '*SHA-256*'
    }
    It 'throws when a file is missing' {
        $dir = New-SbeFolder
        Remove-Item (Join-Path $dir 'SBE_Dell_16G_5.0.1.xml')
        { Get-AzlSbeBundle -Path $dir -OfflineManifest } | Should -Throw '*needs*'
    }
}

Describe 'Node payloads' {
    It '<_> parses as Windows PowerShell 5.1 syntax (no ternary, ??, &&)' -ForEach 'Read', 'Apply', 'Collect', 'Restart' {
        $text = Get-AzlNodePayload -Name $_
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $text | Should -Not -Match '\?\?|\?\s*\w+\s*:|&&|\|\|'
    }
    It 'stays inside Arc Run Command''s output limit with a realistic node' {
        $nodes = 7
        $json = (1..$nodes | ForEach-Object { [pscustomobject]@{ n = "Port$_"; mac = '00005e005310'; st = 'Up'; pci = 'PCI\VEN_15B3&DEV_101D'; drv = '24.4.1.0'; desc = 'Mellanox ConnectX-6 Dx'; dhcp = 'Disabled'; ips = @('192.0.2.11/24/Manual'); gw = @('192.0.2.1'); dns = @('192.0.2.4', '192.0.2.5'); vlan = $null } }) | ConvertTo-Json -Compress
        (ConvertTo-ResultLine ([pscustomobject]@{ nics = $json; more = ('x' * 1500) })).Length | Should -BeLessThan 4000
    }
    It 'the Apply script pulls an SBE file from an address in the action and checks its SHA-256, with no SAS or blob' {
        $text = Get-AzlNodePayload -Name Apply
        $text | Should -Match 'Get-P \$a ''url'''
        $text | Should -Match 'Get-FileHash -LiteralPath \$tmp'
        $text | Should -Not -MatchExactly 'sas:|SAS|[Bb]lob'
    }
    It 'the Apply script never touches a Fibre Channel or iSCSI disk when it clears storage' {
        $text = Get-AzlNodePayload -Name Apply
        $text | Should -Match "'Fibre Channel', 'iSCSI', 'USB'"
    }
}

Describe 'Run commands that end in state Unknown' {
    BeforeEach {
        $infra = Get-Infra
        $script:Spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        Set-AzlNodeRetryPolicy -Tries 3 -DelaySeconds 1 # Start-Sleep is mocked
        $script:Counter = [pscustomobject]@{ N = 0 }
        Mock -ModuleName AzlNodeTransport Start-Sleep { }
    }
    AfterAll { Set-AzlNodeRetryPolicy -Tries 3 -DelaySeconds 15, 45, 120 }

    It 'tries again after Unknown and returns the result of the try that worked' {
        $transport = [pscustomobject]@{ Kind = 'ArcRunCommand'; Invoke = $null }
        $encode = ${function:ConvertTo-ResultLine}
        $counter = $script:Counter; $transport.Invoke = {
            $counter.N++
            if ($counter.N -lt 3) { [pscustomobject]@{ Output = ''; Failed = $true; Error = ''; State = 'Unknown' } }
            else { [pscustomobject]@{ Output = (& $encode ([pscustomobject]@{ ok = $true })); Failed = $false; Error = ''; State = 'Succeeded' } }
        }.GetNewClosure()
        (Invoke-AzlNodeScript -Transport $transport -Node n1 -Script 'x').ok | Should -BeTrue
        $script:Counter.N | Should -Be 3
        Should -Invoke -ModuleName AzlNodeTransport Start-Sleep -Times 2 -Exactly
    }
    It 'gives up after the configured tries with an error that says Unknown' {
        $transport = [pscustomobject]@{ Kind = 'ArcRunCommand'; Invoke = $null }
        $counter = $script:Counter; $transport.Invoke = { $counter.N++; [pscustomobject]@{ Output = ''; Failed = $true; Error = ''; State = 'Unknown' } }.GetNewClosure().GetNewClosure()
        $caught = $null
        try { Invoke-AzlNodeScript -Transport $transport -Node n1 -Script 'x' } catch { $caught = $_ }
        $caught.Exception.Data['AzlState'] | Should -Be 'Unknown'
        $script:Counter.N | Should -Be 3
        $script:Counter.N = 0
        try { Invoke-AzlNodeScript -Transport $transport -Node n1 -Script 'x' -Tries 1 } catch { $null = $_ }
        $script:Counter.N | Should -Be 1
    }
    It 'does not retry a run that Failed for another reason' {
        $transport = [pscustomobject]@{ Kind = 'ArcRunCommand'; Invoke = $null }
        $counter = $script:Counter; $transport.Invoke = { $counter.N++; [pscustomobject]@{ Output = ''; Failed = $true; Error = 'bad'; State = 'Failed' } }.GetNewClosure()
        { Invoke-AzlNodeScript -Transport $transport -Node n1 -Script 'x' } | Should -Throw '*failed on n1*bad*'
        $script:Counter.N | Should -Be 1
    }
    It 'after an Apply that ends in Unknown, reads the node again and decides convergence by re-planning' {
        $bad = New-ConfiguredState $script:Spec
        $bad.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }
        $good = New-ConfiguredState $script:Spec
        $t = New-FakeTransport @($bad, $good) { throw 'not reached' }
        $inner = $t.Invoke
        $counter = $script:Counter; $t.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            if ($Script -match 'function Invoke-Action') { $counter.N++; return [pscustomobject]@{ Output = ''; Failed = $true; Error = ''; State = 'Unknown' } }
            & $inner $Self $Node $Script $Parameters $Secrets $TimeoutSeconds
        }.GetNewClosure()
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver
        $script:Counter.N | Should -Be 3
        $r.Converged | Should -BeTrue -Because 'the second read shows the node matches, whatever the failed command said'
        @($r.Changes | Where-Object Status -eq 'unknown').Count | Should -Be 1
        @($t.Log | Where-Object Kind -eq 'Read').Count | Should -Be 2
    }
    It 'after an Apply that ends in Unknown and a node that still differs, is not converged' {
        $bad = New-ConfiguredState $script:Spec
        $bad.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }
        $t = New-FakeTransport @($bad, $bad, $bad, $bad, $bad) { throw 'not reached' }
        $inner = $t.Invoke
        $counter = $script:Counter; $t.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            if ($Script -match 'function Invoke-Action') { return [pscustomobject]@{ Output = ''; Failed = $true; Error = ''; State = 'Unknown' } }
            & $inner $Self $Node $Script $Parameters $Secrets $TimeoutSeconds
        }.GetNewClosure()
        (Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver -MaxPasses 2).Converged | Should -BeFalse
    }
}

Describe 'SBE delivered last, together with the Unknown handling of the node scripts' {
    BeforeEach {
        $script:Spec = Get-SbeSpec node_pull 'https://sbe.example.invalid/sbe'
        Set-AzlNodeRetryPolicy -Tries 1 -DelaySeconds 1
        Mock -ModuleName AzlNodeTransport Start-Sleep { }
        Mock -ModuleName AzlNodeConfiguration Start-Sleep { }
        $script:Present = @([pscustomobject]@{ n = 'SBE_Dell_X_1.0.zip'; len = 100; ok = $true }, [pscustomobject]@{ n = 'SBE_Dell_X_1.0.xml'; len = 10; ok = $true })
        $script:Ok = { param($p) [pscustomobject]@{ reboot = $false; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = 'ok' } }) } }
    }
    AfterAll { Set-AzlNodeRetryPolicy -Tries 3 -DelaySeconds 15, 45, 120 }

    It 'an Apply of the other steps that ends in Unknown does not block the package: the next pass reads the node and delivers it' {
        $s1 = New-ConfiguredState $script:Spec; $s1.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }; $s1.sbe = @()
        $s2 = New-ConfiguredState $script:Spec; $s2.sbe = @()
        $s3 = New-ConfiguredState $script:Spec; $s3.sbe = $script:Present
        $t = New-FakeTransport @($s1, $s2, $s3) $script:Ok
        $inner = $t.Invoke; $first = [pscustomobject]@{ Done = $false }
        $t.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            if ($Script -match 'function Invoke-Action' -and -not $first.Done) { $first.Done = $true; return [pscustomobject]@{ Output = ''; Failed = $true; Error = ''; State = 'Unknown' } }
            & $inner $Self $Node $Script $Parameters $Secrets $TimeoutSeconds
        }.GetNewClosure()
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver
        @($r.Changes | Where-Object Status -eq 'unknown').Count | Should -Be 1
        @($r.Changes | Where-Object { $_.Id -like 'Sbe/*' -and $_.Status -eq 'changed' }).Count | Should -Be 2
        $r.Converged | Should -BeTrue
    }
    It 'a restart that ends in Unknown is not a failure and the package is delivered after the node is back' {
        $s1 = New-ConfiguredState $script:Spec; $s1.admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $false }; $s1.sbe = @()
        $s2 = New-ConfiguredState $script:Spec -Boot '2026-11-07T02:00:00Z'; $s2.sbe = @()
        $s3 = New-ConfiguredState $script:Spec -Boot '2026-11-07T02:00:00Z'; $s3.sbe = $script:Present
        $t = New-FakeTransport @($s1, $s2, $s3) { param($p) [pscustomobject]@{ reboot = (@($p.actions | ForEach-Object kind) -contains 'admin'); results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = 'ok' } }) } }
        $inner = $t.Invoke
        $t.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            if ($Script -match 'shutdown\.exe') { return [pscustomobject]@{ Output = ''; Failed = $true; Error = ''; State = 'Unknown' } }
            & $inner $Self $Node $Script $Parameters $Secrets $TimeoutSeconds
        }.GetNewClosure()
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -SecretResolver $script:Resolver
        $r.Restarted | Should -BeTrue
        $r.Converged | Should -BeTrue
        $kinds = @($t.Log | Where-Object { $_.Kind -in 'Apply', 'Read' } | ForEach-Object {
                if ($_.Kind -eq 'Apply') { if (@($_.Parameters.actions | ForEach-Object kind) -contains 'sbe-file') { 'ApplySbe' } else { 'ApplyOther' } } else { 'Read' } })
        $kinds.IndexOf('ApplyOther') | Should -BeLessThan $kinds.IndexOf('ApplySbe')
    }
    It 'the Sbe plan items come after every other step in the plan' {
        $s = New-ConfiguredState $script:Spec; $s.host = 'WIN-X'; $s.sbe = @()
        $plan = @(Compare-AzlNodeState -Spec $script:Spec -State $s -Step (InModuleScope AzlNodeConfiguration { $script:AllSteps }))
        $steps = @($plan | ForEach-Object Step)
        $steps | Should -Contain 'Sbe'
        [array]::IndexOf($steps, 'Hostname') | Should -BeLessThan ([array]::IndexOf($steps, 'Sbe'))
        [array]::LastIndexOf($steps, 'Sbe') | Should -Be ($steps.Count - 1)
    }
    It 'winrm_copy builds the remote path as C:\SBE plus the file name, whatever the host OS' {
        $spec = Get-SbeSpec winrm_copy
        $s1 = New-ConfiguredState $spec; $s1.sbe = @()
        $s2 = New-ConfiguredState $spec; $s2.sbe = $script:Present
        $arc = New-FakeTransport @($s1, $s2) $script:Ok
        $copied = [System.Collections.Generic.List[string]]::new()
        $win = [pscustomobject]@{ Kind = 'WinRM'; Stage = $null }
        $win.Stage = { $copied.Add([string]$args[3]); [pscustomobject]@{ Name = 'x'; Url = $null } }.GetNewClosure()
        $null = Invoke-AzlNodeConfiguration -Spec $spec -Transport $arc -SbeTransport $win -Execute -SecretResolver $script:Resolver
        $copied.Count | Should -Be 2
        $copied | ForEach-Object { $_ | Should -Match '^C:\\SBE\\SBE_Dell_X_1\.0\.(zip|xml)$' }
    }
}
