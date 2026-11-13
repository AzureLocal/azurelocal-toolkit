#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The SAN in the file: scenario.storage_architecture (hybrid or san) and storage.san.type (fibre_channel or iscsi) make the OS configuration do the host-side MPIO / MSDSM work
# (Microsoft Learn: Connect an external storage array to Azure Local), and every node is looked at, read only, for SAN LUNs the file does not declare.
# Fakes only: no node, no Azure. Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/SanMpio.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transport and mock script blocks keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\azure-local\AzlAzure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodeTransport.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodeConfiguration.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlOsConfigurationEvents.psm1') -Force
    Import-Module powershell-yaml
    $script:Repo = $repo
    $script:Fixture = Join-Path $repo 'tests\fixtures\infrastructure.fc-san.yml'
    $script:Steps = @('Mpio', 'SanVerify')

    function Get-Infra { Import-AzlInfrastructure -Path $script:Fixture -SkipValidation }

    # A hybrid design (S2D plus a SAN). -Incomplete: the array's WWPNs are not known yet (no storage.san.fibre_channel, no HBA ports on the nodes): only type, vendor and model are in the file.
    function Get-HybridInfra([ValidateSet('fibre_channel', 'iscsi')][string]$Type = 'fibre_channel', [string]$Vendor = 'Pure Storage', [string]$Model = 'FlashArray//X', [switch]$Incomplete) {
        $infra = Get-Infra
        $infra.scenario.storage_architecture = 'hybrid'
        $infra.storage.san.type = $Type
        $infra.storage.san.array = [ordered]@{ name = 'arr-01'; vendor = $Vendor; model = $Model }
        if ($Incomplete) {
            foreach ($key in 'fibre_channel', 'iscsi', 'infra_volume_lun_id', 'performance_history_lun_id') { if ($infra.storage.san.Contains($key)) { $infra.storage.san.Remove($key) } }
            foreach ($node in $infra.nodes) { if ($node.Contains('san')) { $node.Remove('san') } }
        }
        $infra
    }
    function Get-SpecOf([System.Collections.IDictionary]$Infra) { Get-AzlNodeSpec -Infrastructure $Infra -Node $Infra.nodes[0] }

    # The disks of one Pure LUN: four Fibre Channel paths that MPIO has not claimed are four separate offline disks with the same serial and UniqueId.
    function Get-LunPath([int]$Lun, [int]$FirstNumber, [int]$Paths = 4, [string]$Bus = 'Fibre Channel') {
        foreach ($k in 0..($Paths - 1)) { [pscustomobject]@{ n = $FirstNumber + $k; bus = $Bus; gb = 1024; ps = 'RAW'; sn = "PURELUN$Lun"; uid = "624A9370PURE$Lun"; lun = $Lun; paths = 0; st = 'Offline' } }
    }
    # The same LUN once, claimed by MPIO.
    function Get-LunClaimed([int]$Lun, [int]$Number) {
        [pscustomobject]@{ n = $Number; bus = 'Fibre Channel'; gb = 1024; ps = 'RAW'; sn = "PURELUN$Lun"; uid = "624A9370PURE$Lun"; lun = $Lun; paths = 4; st = 'Offline' }
    }
    # What the Read script returns for the parts of a node these tests look at.
    function New-SanState {
        param([object[]]$Disk = @(), [string[]]$Hw = @('PURE|FlashArray'), [string]$Lb = 'RR', [string]$Feature = 'Enabled', [string]$Boot = '2026-11-07T01:00:00Z', [switch]$Deployed,
            [string]$IscsiSvc = '', [string]$IscsiClaim = '', [object[]]$Portal = @(), [object[]]$Session = @(), [object[]]$Fc = @(),
            # MPIO's own list (MPIOSupportedDeviceList) and Get-MPIOAvailableHW: by default the array is claimed.
            [string[]]$Mpdev = @('PURE|FlashArray'), [object[]]$Avail = @([pscustomobject]@{ vendor = 'PURE'; product = 'FlashArray'; multipathed = $true }), [bool]$MpioRead = $true)
        [pscustomobject]@{
            v = 1; host = 'iic-n01'; boot = $Boot; os = '10.0.26100.1'; reboot = $false; nics = @()
            stor = [pscustomobject]@{ pools = 0; vdisks = 0; dirty = @(); cluster = [pscustomobject]@{ deployed = [bool]$Deployed; why = @() } }
            san = [pscustomobject]@{
                feature = $Feature; hw = @($Hw); lb = $Lb
                set = [pscustomobject]@{ UseCustomPathRecoveryTime = 'Enabled'; CustomPathRecoveryTime = '20'; PDORemovePeriod = '20'; DiskTimeoutValue = '60'; PathVerificationState = 'Enabled' }
                fc = @($Fc); iqn = @(); disks = @($Disk); iscsiSvc = $IscsiSvc; iscsiClaim = $IscsiClaim; portals = @($Portal); sessions = @($Session); avail = @($Avail); mpdev = @($Mpdev); mpdevRead = $true; mpioRead = $MpioRead
            }
            err = [pscustomobject]@{}
        }
    }
    function Get-Plan($Spec, $State) { @(Compare-AzlNodeState -Spec $Spec -State $State -Step $script:Steps) }

    function ConvertTo-ResultLine([object]$Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
    }
    # A transport that serves canned states, records what it was asked to run and answers every Apply with OnApply.
    function New-FakeTransport([object[]]$States, [scriptblock]$OnApply) {
        $log = [System.Collections.Generic.List[object]]::new()
        $queue = [System.Collections.Generic.Queue[object]]::new()
        foreach ($s in $States) { $queue.Enqueue($s) }
        $last = [ref]$States[-1]
        $encode = ${function:ConvertTo-ResultLine}
        $onGuard = { param($Kind, $P) if ($Kind -eq 'Stage') { @{ v = 1; staged = $true; changeId = $P.changeId; cookie = 'cookie1'; machineSid = 'S-1-5-21-1' } } else { @{ v = 1; found = $true; identityOk = $true; nowUtc = '2026-11-07T10:00:00Z'; state = @{ state = 'Committed'; reason = 'All checks passed.'; repairs = @() } } } }
        $transport = [pscustomobject]@{ Kind = 'WinRM'; Invoke = $null; Stage = $null; Log = $log; GetAddress = { '192.0.2.11' }; GetPort = { 5985 }; SetAddress = {}; CloseSession = {} }
        $transport.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            if ($Script -match 'AZL-GUARD-STAGE') { $kind = 'GuardStage' } elseif ($Script -match 'AZL-GUARD-STATUS') { $kind = 'GuardStatus' } elseif ($Script -match 'function Invoke-Action') { $kind = 'Apply' } elseif ($Script -match 'shutdown\.exe') { $kind = 'Restart' } elseif ($Script -match 'last-apply') { $kind = 'Collect' } else { $kind = 'Read' }
            $log.Add([pscustomobject]@{ Kind = $kind; Parameters = $Parameters; Secrets = $Secrets })
            switch ($kind) {
                'Read' { if ($queue.Count -gt 0) { $last.Value = $queue.Dequeue() }; [pscustomobject]@{ Output = (& $encode $last.Value); Failed = $false; Error = ''; State = 'Succeeded' } }
                'Apply' { $r = & $OnApply $Parameters; [pscustomobject]@{ Output = (& $encode $r); Failed = $false; Error = ''; State = 'Succeeded' } }
                'Restart' { [pscustomobject]@{ Output = (& $encode ([pscustomobject]@{ restartScheduled = $true })); Failed = $false; Error = ''; State = 'Succeeded' } }
                'GuardStage' { $r = & $onGuard 'Stage' $Parameters; [pscustomobject]@{ Output = (& $encode $r); Failed = $false; Error = ''; State = 'Succeeded' } }
                'GuardStatus' { $r = & $onGuard 'Status' $Parameters; [pscustomobject]@{ Output = (& $encode $r); Failed = $false; Error = ''; State = 'Succeeded' } }
                default { [pscustomobject]@{ Output = (& $encode ([pscustomobject]@{})); Failed = $false; Error = ''; State = 'Succeeded' } }
            }
        }.GetNewClosure()
        $transport.Stage = { param($Self, $Node, $LocalPath, $RemotePath, $Sha256) [pscustomobject]@{ Name = (Split-Path $LocalPath -Leaf); Url = $null } }
        return $transport
    }
    $script:Resolver = { param($Ref) 'P@ssw0rd-from-vault' }
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc)
    $script:FakeClock = [pscustomobject]@{ Now = { $script:Now }; Sleep = { param($Seconds) $script:Now = $script:Now.AddSeconds($Seconds) } }
    $script:PortUp = { param($Address, $Port) $true }
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
}

Describe 'The file declares the SAN' {
    It 'hybrid with a Fibre Channel type is a SAN, and the spec carries the type, the vendor and the model' {
        $spec = Get-SpecOf (Get-HybridInfra)
        $spec.San | Should -Not -BeNullOrEmpty
        $spec.San.Type | Should -Be 'fibre_channel'
        $spec.San.Vendor | Should -Be 'Pure Storage'
        $spec.San.Architecture | Should -Be 'hybrid'
        $spec.San.CheckLuns | Should -BeFalse -Because 'the infrastructure LUN checks are for a disaggregated design; a hybrid design keeps its infrastructure volume on S2D'
        $spec.San.Msdsm.Hardware[0].vendorId | Should -Be 'PURE'
        $spec.San.Msdsm.RemoveGenericEntry | Should -BeTrue
    }
    It 'a hybrid file whose array WWPNs are unknown still gets the host-side work: only type, vendor and model are needed' {
        $spec = Get-SpecOf (Get-HybridInfra -Incomplete)
        $spec.San.ExpectedWwpn | Should -BeNullOrEmpty
        $state = New-SanState -Hw @('Vendor*|Product*') -Lb 'None'
        $kinds = @(Get-Plan $spec $state | Where-Object { $_.Action -eq 'Change' } | ForEach-Object { $_.Apply.kind })
        $kinds | Should -Contain 'msdsm-hw'
        $kinds | Should -Contain 'msdsm-hw-remove'
        $kinds | Should -Contain 'msdsm-lb'
    }
    It 'scenario.storage_architecture s2d with no storage.san block is not a SAN' {
        $infra = Get-Infra; $infra.scenario.storage_architecture = 's2d'; $infra.storage.Remove('san')
        (Get-SpecOf $infra).San | Should -BeNullOrEmpty
        Test-AzlSanDeclared -Infrastructure $infra | Should -BeFalse
    }
    It 'a storage.san block is a SAN even when scenario.storage_architecture says s2d, and the plan says so' {
        $infra = Get-HybridInfra; $infra.scenario.storage_architecture = 's2d'
        $spec = Get-SpecOf $infra
        $spec.San.DeclaredBy | Should -Be 'storage.san'
        Test-AzlSanDeclared -Infrastructure $infra | Should -BeTrue
        $note = Get-Plan $spec (New-SanState -Disk (Get-LunClaimed 1 3)) | Where-Object { $_.Item -eq 'SAN declared by' }
        $note.Action | Should -Be 'Info'
        $note.Note | Should -Match 'storage.san block'
    }
    It 'a SAN with no storage.san.type is Blocked: the type selects the steps' {
        $infra = Get-HybridInfra; $infra.storage.san.Remove('type')
        $spec = Get-SpecOf $infra
        $spec.San.Type | Should -Be ''
        $b = Get-Plan $spec (New-SanState -Disk (Get-LunClaimed 1 3)) | Where-Object { $_.Item -eq 'SAN type' }
        $b.Action | Should -Be 'Blocked'
        $b.Note | Should -Match 'storage\.san\.type'
    }
    It 'a SAN with no array vendor is Blocked: MSDSM cannot be told what to claim' {
        $infra = Get-HybridInfra; $infra.storage.san.Remove('array')
        $b = Get-Plan (Get-SpecOf $infra) (New-SanState) | Where-Object { $_.Item -eq 'MSDSM vendor' }
        $b.Action | Should -Be 'Blocked'
        $b.Note | Should -Match 'storage.san.array.vendor'
    }
    It 'the Read parameters tell the node there is a SAN and its type, and to list the SAN disks whatever the file says' {
        $declared = Get-AzlNodeReadParameter -Spec (Get-SpecOf (Get-HybridInfra -Type iscsi -Vendor Dell -Model 'PowerStore 1200T'))
        $declared.san | Should -BeTrue
        $declared.sanType | Should -Be 'iscsi'
        $infra = Get-Infra; $infra.scenario.storage_architecture = 's2d'; $infra.storage.Remove('san')
        $undeclared = Get-AzlNodeReadParameter -Spec (Get-SpecOf $infra)
        $undeclared.san | Should -BeFalse
        $undeclared.sanDisks | Should -BeTrue
    }
}

Describe 'Fibre Channel: the host-side steps (Learn: Connect an external storage array to Azure Local)' {
    BeforeEach { $script:Spec = Get-SpecOf (Get-HybridInfra -Incomplete) }

    It 'registers the vendor hardware ID, removes the generic wildcard for Pure, sets the policy and the vendor MPIO settings; the paths are claimed at the restart that follows' {
        $state = New-SanState -Hw @('Vendor*|Product*') -Lb 'None' -Disk (@(Get-LunPath 1 3) + @(Get-LunPath 2 7))
        $state.san.set.PDORemovePeriod = '30'
        $plan = Get-Plan $script:Spec $state
        $hw = $plan | Where-Object { $_.Item -eq 'MSDSM PURE|FlashArray' }
        $hw.Action | Should -Be 'Change'
        $hw.Apply.vendor | Should -Be 'PURE'
        $hw.Apply.product | Should -Be 'FlashArray'
        ($plan | Where-Object { $_.Item -eq 'MSDSM generic entry Vendor*|Product*' }).Apply.kind | Should -Be 'msdsm-hw-remove'
        ($plan | Where-Object { $_.Item -eq 'load balance policy' }).Apply.policy | Should -Be 'RR'
        $settings = ($plan | Where-Object { $_.Apply -and $_.Apply.kind -eq 'mpio-setting' }).Apply.settings
        @($settings.Keys) | Should -Be @('PDORemovePeriod')
        ($plan | Where-Object { $_.Item -eq 'MPIO claims the LUN paths' }).Action | Should -Be 'Info' -Because 'the restart that follows the changes lets MPIO claim the paths; no second one is asked for'
        @($plan | Where-Object { $_.Apply -and $_.Apply.kind -eq 'mpio-claim-restart' }) | Should -BeNullOrEmpty
    }
    It 'does not remove the generic entry for an array whose row does not ask for it' {
        $spec = Get-SpecOf (Get-HybridInfra -Vendor 'Dell' -Model 'PowerStore 1200T' -Incomplete)
        $state = New-SanState -Hw @('Vendor*|Product*', 'DellEMC|PowerStore')
        $state.san.set = [pscustomobject]@{ UseCustomPathRecoveryTime = 'Enabled'; CustomPathRecoveryTime = '10'; RetryCount = '3'; DiskTimeoutValue = '30' }
        @(Get-Plan $spec $state | Where-Object { $_.Item -like 'MSDSM generic*' }) | Should -BeNullOrEmpty
    }
    It 'with everything in place and the paths still separate disks, the node restarts once so MPIO claims them' {
        $state = New-SanState -Disk (@(Get-LunPath 1 3) + @(Get-LunPath 2 7))
        $plan = Get-Plan $script:Spec $state
        $claim = $plan | Where-Object { $_.Item -eq 'MPIO claims the LUN paths' }
        $claim.Action | Should -Be 'Change'
        $claim.Apply.kind | Should -Be 'mpio-claim-restart'
        $claim.Current | Should -Match '8 FC/iSCSI disk\(s\) report only 2 LUN\(s\)'
        $claim.Current | Should -Match 'UniqueId 624A9370PURE1 is 4 separate disks \(#3, #4, #5, #6'
    }
    It 'with the paths claimed, every LUN is seen once and nothing changes' {
        $state = New-SanState -Disk @((Get-LunClaimed 1 3), (Get-LunClaimed 2 4))
        $plan = Get-Plan $script:Spec $state
        @($plan | Where-Object { $_.Action -in 'Change', 'Blocked' }) | Should -BeNullOrEmpty
        ($plan | Where-Object { $_.Item -eq 'each LUN seen once (by UniqueId)' }).Action | Should -Be 'Ok'
        ($plan | Where-Object { $_.Item -eq 'MPIO claims the LUN paths' }).Current | Should -Be '2 LUN(s), each seen once'
    }
    It 'SanVerify blocks a LUN seen more than once when nothing is going to claim it, with the evidence' {
        $state = New-SanState -Disk (Get-LunPath 1 3)
        $state.san.hw = @('PURE|FlashArray'); $state.san.feature = 'Enabled'
        $spec = Get-SpecOf (Get-HybridInfra -Incomplete)
        # SanVerify alone: the Mpio step is not part of this plan, so no restart is coming.
        $verify = @(Compare-AzlNodeState -Spec $spec -State $state -Step SanVerify | Where-Object { $_.Item -eq 'each LUN seen once (by UniqueId)' })
        $verify.Action | Should -Be 'Blocked'
        $verify.Current | Should -Match '4 FC/iSCSI disk\(s\) report only 1 LUN\(s\)'
        $verify.Note | Should -Match 'mpclaim -n -i -d'
    }
    It 'reports the initiator WWPNs when the file lists none (the fabric administrator needs them for zoning)' {
        $state = New-SanState -Fc @([pscustomobject]@{ wwpn = '10000090fa000001'; up = 'Online' }, [pscustomobject]@{ wwpn = '10000090fa000002'; up = 'Online' })
        $fc = Get-Plan $script:Spec $state | Where-Object { $_.Item -eq 'FC initiator ports' }
        $fc.Action | Should -Be 'Info'
        $fc.Current | Should -Be '10000090fa000001, 10000090fa000002'
    }
    It 'with the Learn rule for FC hybrid: LUNs visible before the deployment get the warning not to zone the HBA WWNs yet' {
        $state = New-SanState -Disk @((Get-LunClaimed 1 3))
        $f = Get-Plan $script:Spec $state | Where-Object { $_.Item -like 'Important: to avoid deployment confusion for FC LUNs*' }
        $f.Item | Should -Be 'Important: to avoid deployment confusion for FC LUNs, don''t zone in FC HBA WWNs until after the Azure Local deployment'
        $f.Action | Should -Be 'Info'
        $f.Current | Should -Match 'serial PURELUN1 UniqueId 624A9370PURE1'
    }
    It 'no such warning once the node belongs to a deployed cluster, for a disaggregated design, or when no FC LUN is visible' {
        @(Get-Plan $script:Spec (New-SanState -Deployed -Disk @((Get-LunClaimed 1 3))) | Where-Object { $_.Item -like 'Important:*' }) | Should -BeNullOrEmpty
        @(Get-Plan $script:Spec (New-SanState) | Where-Object { $_.Item -like 'Important:*' }) | Should -BeNullOrEmpty
        $san = Get-HybridInfra; $san.scenario.storage_architecture = 'san'
        @(Get-Plan (Get-SpecOf $san) (New-SanState -Disk @((Get-LunClaimed 1 3))) | Where-Object { $_.Item -like 'Important:*' }) | Should -BeNullOrEmpty
    }
    It 'a disaggregated (san) design still checks the infrastructure LUNs, and a hybrid one does not' {
        $san = Get-HybridInfra; $san.scenario.storage_architecture = 'san'
        $state = New-SanState -Disk @((Get-LunClaimed 1 3))
        @(Get-Plan (Get-SpecOf $san) $state | Where-Object { $_.Item -like 'infrastructure volume*' }).Count | Should -Be 1
        @(Get-Plan $script:Spec $state | Where-Object { $_.Item -like 'infrastructure volume*' }) | Should -BeNullOrEmpty
    }
    It 'the lab case: MSDSM already lists PURE FlashArray but MPIO has not claimed it, so the eight disks stay separate: mpclaim -n -i -d claims it and the node restarts' {
        $state = New-SanState -Mpdev @() -Avail @([pscustomobject]@{ vendor = 'PURE'; product = 'FlashArray'; multipathed = $false }) -Disk (@(Get-LunPath 1 3) + @(Get-LunPath 2 7))
        $plan = Get-Plan $script:Spec $state
        ($plan | Where-Object { $_.Item -eq 'MSDSM PURE|FlashArray' }).Action | Should -Be 'Ok' -Because 'Azure Local ships the hardware ID registered; that alone does not claim the paths'
        $claim = $plan | Where-Object { $_.Item -eq 'MPIO claims PURE|FlashArray' }
        $claim.Action | Should -Be 'Change'
        $claim.Apply.kind | Should -Be 'mpio-claim'
        $claim.Apply.vendor | Should -Be 'PURE'
        $claim.Apply.product | Should -Be 'FlashArray'
        $claim.Current | Should -Match 'not in MPIOSupportedDeviceList; Get-MPIOAvailableHW: IsMultipathed False'
        @($plan | Where-Object { $_.Apply -and $_.Apply.kind -eq 'mpio-claim-restart' }) | Should -BeNullOrEmpty -Because 'the claim restarts the node already'
    }
    It 'before any LUN is presented the array is still claimed, so the paths are claimed when the LUNs appear' {
        $claim = Get-Plan $script:Spec (New-SanState -Mpdev @() -Avail @()) | Where-Object { $_.Item -eq 'MPIO claims PURE|FlashArray' }
        $claim.Action | Should -Be 'Change'
        $claim.Current | Should -Match 'not listed by Get-MPIOAvailableHW'
    }
    It 'IsMultipathed True counts as claimed' {
        $state = New-SanState -Mpdev @() -Avail @([pscustomobject]@{ vendor = 'PURE'; product = 'FlashArray'; multipathed = $true })
        (Get-Plan $script:Spec $state | Where-Object { $_.Item -eq 'MPIO claims PURE|FlashArray' }).Action | Should -Be 'Ok'
    }
    It 'a node whose MPIO list could not be read is not told to claim' {
        $state = New-SanState -Mpdev @(); $state.san.mpdevRead = $false
        @(Get-Plan $script:Spec $state | Where-Object { $_.Item -like 'MPIO claims*' }) | Should -BeNullOrEmpty
    }
    It 'mpclaim -s -d must list every LUN seen once: a disk with no MPIO path is Blocked, an MPIO disk is Ok, and an unread MPIO state says nothing' {
        $noPath = [pscustomobject]@{ n = 3; bus = 'Fibre Channel'; gb = 1024; ps = 'RAW'; sn = 'PURELUN1'; uid = 'UID1'; lun = 1; paths = 0; st = 'Offline' }
        $item = Get-Plan $script:Spec (New-SanState -Disk @($noPath)) | Where-Object { $_.Item -eq 'mpclaim -s -d lists every LUN' }
        $item.Action | Should -Be 'Blocked'
        $item.Current | Should -Match '#3'
        $good = New-SanState -Disk @((Get-LunClaimed 1 3), (Get-LunClaimed 2 4))
        (Get-Plan $script:Spec $good | Where-Object { $_.Item -eq 'mpclaim -s -d lists every LUN' }).Action | Should -Be 'Ok'
        @(Get-Plan $script:Spec (New-SanState -MpioRead $false -Disk @($noPath)) | Where-Object { $_.Item -eq 'mpclaim -s -d lists every LUN' }) | Should -BeNullOrEmpty
    }
    It 'does nothing until MPIO is on: the feature is enabled first and the rest waits for the restart' {
        $plan = Get-Plan $script:Spec (New-SanState -Feature Disabled -Hw @())
        ($plan | Where-Object { $_.Action -eq 'Change' }).Apply.kind | Should -Be 'mpio-feature'
        ($plan | Where-Object { $_.Item -eq 'MSDSM' }).Action | Should -Be 'Skipped'
    }
}

Describe 'Detection: SAN LUNs are visible but the file declares no SAN' {
    BeforeEach {
        $infra = Get-Infra; $infra.scenario.storage_architecture = 's2d'; $infra.storage.Remove('san')
        $script:S2dSpec = Get-SpecOf $infra
        $script:Finding = 'SAN LUNs are visible but the file declares no SAN (storage.san / scenario.storage_architecture)'
    }
    It 'reports the finding with the exact evidence when a LUN repeats (multipath not claimed): two Pure LUNs seen as eight disks' {
        $state = New-SanState -Disk (@(Get-LunPath 1 3) + @(Get-LunPath 2 7))
        $f = Get-Plan $script:S2dSpec $state | Where-Object { $_.Item -eq $script:Finding }
        $f.Step | Should -Be 'SanVerify'
        $f.Action | Should -Be 'Blocked'
        $f.Current | Should -Match '8 FC/iSCSI disk\(s\) report only 2 LUN\(s\) that repeat'
        $f.Current | Should -Match 'UniqueId 624A9370PURE1 is 4 separate disks \(#3, #4, #5, #6, BusType Fibre Channel\)'
        $f.Current | Should -Match 'UniqueId 624A9370PURE2 is 4 separate disks \(#7, #8, #9, #10'
        $f.Current | Should -Match 'MPIO has not claimed the paths'
        $f.Current | Should -Match '#3 Fibre Channel serial PURELUN1 UniqueId 624A9370PURE1 1024 GB Offline'
        $f.Note | Should -Match 'scenario.storage_architecture hybrid'
        $f.Note | Should -Match 'storage.san.type fibre_channel or iscsi'
    }
    It 'with the node not in a SAN design the Mpio step still plans nothing (the file decides), only SanVerify reports' {
        $state = New-SanState -Disk (Get-LunPath 1 3)
        @(Get-Plan $script:S2dSpec $state | Where-Object { $_.Step -eq 'Mpio' }) | Should -BeNullOrEmpty
    }
    It 'LUNs seen once each are still reported, as Info' {
        $f = Get-Plan $script:S2dSpec (New-SanState -Disk @((Get-LunClaimed 1 3))) | Where-Object { $_.Item -eq $script:Finding }
        $f.Action | Should -Be 'Info'
        $f.Current | Should -Match '1 FC/iSCSI disk\(s\)'
    }
    It 'an iSCSI repeat is found the same way' {
        $f = Get-Plan $script:S2dSpec (New-SanState -Disk (Get-LunPath 1 3 -Paths 2 -Bus iSCSI)) | Where-Object { $_.Item -eq $script:Finding }
        $f.Action | Should -Be 'Blocked'
        $f.Current | Should -Match 'BusType iSCSI'
    }
    It 'a node that sees no SAN disk gets no finding' {
        @(Get-Plan $script:S2dSpec (New-SanState)) | Should -BeNullOrEmpty
    }
    It 'a repeat is found by SerialNumber when the UniqueIds differ' {
        $d = @(Get-LunPath 1 3 -Paths 2)
        $d[1].uid = 'OTHER'
        $dup = @(Get-AzlSanDuplicate -Disk $d)
        $dup.Count | Should -Be 1
        $dup[0].KeyKind | Should -Be 'SerialNumber'
        $dup[0].Numbers | Should -Be @(3, 4)
    }
    It 'the event of the step is a Warning for the finding' {
        $feed = Join-Path $TestDrive 'events.jsonl'
        $run = Import-Module (Join-Path $script:Repo 'scripts\common\node-configuration\AzlOsConfigurationRun.psm1') -Force -PassThru
        $record = [ordered]@{ name = 'iic-n01'; method = 'Iso'; transport = 'WinRM'; steps = @('SanVerify'); plan = @(Get-Plan $script:S2dSpec (New-SanState -Disk (Get-LunPath 1 3))) }
        $context = [pscustomobject]@{ EventLogPath = $feed; Infra = @{}; SchemaVersion = '5.6.1' }
        & $run { param($c, $r) Send-AzlStepPlanEvent -Context $c -Record $r } $context $record
        $line = Get-Content -LiteralPath $feed | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.state -eq 'StepPlanned' -and $_.step -eq 'SanVerify' }
        $line.level | Should -Be 'Warning'
        $line.evidence | Should -Match 'SAN LUNs are visible but the file declares no SAN'
    }
}

Describe 'iSCSI: the host-side steps' {
    BeforeEach {
        $infra = Get-HybridInfra -Type iscsi -Vendor 'Dell' -Model 'PowerStore 1200T' -Incomplete
        $infra.storage.san.iscsi = [ordered]@{ targets = @(
                [ordered]@{ iqn = 'iqn.2010-06.com.example:array-a'; portals = @('198.51.100.10'); fabric = 'A' }
                [ordered]@{ iqn = 'iqn.2010-06.com.example:array-b'; portals = @('198.51.100.74:3261'); fabric = 'B' }) }
        $adapters = $infra.nodes[0].network_adapters
        $adapters[2].roles = @('iscsi:a'); $adapters[2].ip_assignment = 'static'; $adapters[2].ip_address = '198.51.100.21'; $adapters[2].prefix_length = 26
        $adapters[3].roles = @('iscsi:b'); $adapters[3].ip_assignment = 'static'; $adapters[3].ip_address = '198.51.100.85'; $adapters[3].prefix_length = 26
        $script:Infra = $infra
        $script:Spec = Get-SpecOf $infra
        $script:DellHw = @('DellEMC|PowerStore')
        $script:DellSet = [pscustomobject]@{ UseCustomPathRecoveryTime = 'Enabled'; CustomPathRecoveryTime = '10'; RetryCount = '3'; DiskTimeoutValue = '30' }
    }
    It 'starts the MSiSCSI service, enables MSDSM auto-claim for iSCSI, and makes a portal and a session per initiator port and target of its fabric' {
        $state = New-SanState -Hw $script:DellHw -Mpdev @('DellEMC|PowerStore') -IscsiSvc 'Stopped/Manual' -IscsiClaim 'False'
        $state.san.set = $script:DellSet
        $plan = Get-Plan $script:Spec $state
        ($plan | Where-Object { $_.Item -eq 'MSiSCSI service' }).Apply.kind | Should -Be 'iscsi-service'
        ($plan | Where-Object { $_.Item -eq 'iSCSI auto-claim' }).Apply.kind | Should -Be 'iscsi-claim'
        $portals = @($plan | Where-Object { $_.Apply -and $_.Apply.kind -eq 'iscsi-portal' })
        $portals.Count | Should -Be 2 -Because 'fabric A is reached from iscsi:a only and fabric B from iscsi:b only'
        ($portals | Where-Object { $_.Apply.portal -eq '198.51.100.10' }).Apply.initiator | Should -Be '198.51.100.21'
        $b = $portals | Where-Object { $_.Apply.portal -eq '198.51.100.74' }
        $b.Apply.initiator | Should -Be '198.51.100.85'
        $b.Apply.port | Should -Be 3261
        $sessions = @($plan | Where-Object { $_.Apply -and $_.Apply.kind -eq 'iscsi-session' })
        $sessions.Count | Should -Be 2
        $sessions[0].Apply.iqn | Should -Match '^iqn\.2010-06\.com\.example:array-'
    }
    It 'makes nothing that is already there, and leaves a live session that is not persistent alone with a note' {
        $state = New-SanState -Hw $script:DellHw -Mpdev @('DellEMC|PowerStore') -IscsiSvc 'Running/Automatic' -IscsiClaim 'True' `
            -Portal @([pscustomobject]@{ addr = '198.51.100.10'; port = 3260; init = '198.51.100.21' }, [pscustomobject]@{ addr = '198.51.100.74'; port = 3261; init = '198.51.100.85' }) `
            -Session @([pscustomobject]@{ iqn = 'iqn.2010-06.com.example:array-a'; portal = '198.51.100.10'; init = '198.51.100.21'; persistent = $true; mpio = $true }, [pscustomobject]@{ iqn = 'iqn.2010-06.com.example:array-b'; portal = '198.51.100.74'; init = '198.51.100.85'; persistent = $false; mpio = $true })
        $state.san.set = $script:DellSet
        $plan = Get-Plan $script:Spec $state
        @($plan | Where-Object { $_.Action -eq 'Change' }) | Should -BeNullOrEmpty
        ($plan | Where-Object { $_.Item -like 'iSCSI session*array-b*' }).Action | Should -Be 'Info'
    }
    It 'asks for a restart with the auto-claim when LUNs are already visible (Learn step 2.5), and not otherwise' {
        $state = New-SanState -Hw $script:DellHw -Mpdev @('DellEMC|PowerStore') -IscsiSvc 'Running/Automatic' -IscsiClaim 'False' -Disk (Get-LunPath 1 3 -Paths 2 -Bus iSCSI)
        $state.san.set = $script:DellSet
        (Get-Plan $script:Spec $state | Where-Object { $_.Item -eq 'iSCSI auto-claim' }).Apply.restart | Should -BeTrue
        $state.san.disks = @()
        (Get-Plan $script:Spec $state | Where-Object { $_.Item -eq 'iSCSI auto-claim' }).Apply.restart | Should -BeFalse
    }
    It 'makes no session when CHAP is on, and says so' {
        $infra = $script:Infra; $infra.storage.san.iscsi.chap = [ordered]@{ enabled = $true; username = 'u'; secret = 'keyvault://kv/chap' }
        $state = New-SanState -Hw $script:DellHw -Mpdev @('DellEMC|PowerStore') -IscsiSvc 'Running/Automatic' -IscsiClaim 'True'
        $state.san.set = $script:DellSet
        $plan = Get-Plan (Get-SpecOf $infra) $state
        @($plan | Where-Object { $_.Apply -and $_.Apply.kind -eq 'iscsi-session' }) | Should -BeNullOrEmpty
        ($plan | Where-Object { $_.Item -eq 'iSCSI sessions' }).Action | Should -Be 'Info'
    }
    It 'with no targets in the file it makes no portals and says what is missing' {
        $infra = $script:Infra; $infra.storage.san.Remove('iscsi')
        $state = New-SanState -Hw $script:DellHw -Mpdev @('DellEMC|PowerStore') -IscsiSvc 'Running/Automatic' -IscsiClaim 'True'
        $state.san.set = $script:DellSet
        $plan = Get-Plan (Get-SpecOf $infra) $state
        ($plan | Where-Object { $_.Item -eq 'iSCSI targets' }).Action | Should -Be 'Info'
        @($plan | Where-Object { $_.Action -eq 'Change' }) | Should -BeNullOrEmpty
    }
    It 'reports the initiator IQN (SanVerify) instead of WWPNs' {
        $state = New-SanState -Hw $script:DellHw
        $state.san.iqn = @('iqn.1991-05.com.microsoft:iic-n01')
        $item = Get-Plan $script:Spec $state | Where-Object { $_.Item -eq 'iSCSI initiator IQN' }
        $item.Action | Should -Be 'Info'
        $item.Current | Should -Be 'iqn.1991-05.com.microsoft:iic-n01'
        @(Get-Plan $script:Spec $state | Where-Object { $_.Item -like 'WWPN*' -or $_.Item -eq 'FC initiator ports' }) | Should -BeNullOrEmpty
    }
}

Describe 'iSCSI before the deployment (Microsoft Learn, Install the Azure Local operating system for disaggregated deployments: from 2610 the deployment configures iSCSI)' {
    BeforeEach {
        $infra = Get-HybridInfra -Type iscsi -Vendor 'Dell' -Model 'PowerStore 1200T' -Incomplete
        $infra.storage.san.iscsi = [ordered]@{ targets = @([ordered]@{ iqn = 'iqn.2010-06.com.example:array-a'; portals = @('198.51.100.10'); fabric = 'A' }) }
        $adapters = $infra.nodes[0].network_adapters
        $adapters[2].roles = @('iscsi:a'); $adapters[2].ip_assignment = 'static'; $adapters[2].ip_address = '198.51.100.21'; $adapters[2].prefix_length = 26
        $script:Infra = $infra
        $script:DellSet = [pscustomobject]@{ UseCustomPathRecoveryTime = 'Enabled'; CustomPathRecoveryTime = '10'; RetryCount = '3'; DiskTimeoutValue = '30' }
        function Get-IscsiPlan([string]$Architecture, [string]$Version) {
            $i = $script:Infra
            $i.scenario.storage_architecture = $Architecture
            if ($Version) { $i.deployment = [ordered]@{ solution_version = $Version } } else { $i.provisioning.os_version = 'latest' }   # the fixture names a 2610 solution in provisioning.os_version
            $state = New-SanState -Hw @('DellEMC|PowerStore') -Mpdev @('DellEMC|PowerStore') -IscsiSvc 'Stopped/Manual' -IscsiClaim 'False'
            $state.san.set = $script:DellSet
            Get-Plan (Get-SpecOf $i) $state
        }
    }
    It 'a SAN-only design on 2610 or later makes no service, auto-claim, portal or session, and says why (Skipped)' {
        $plan = Get-IscsiPlan 'san' '12.2610.1004.50'
        $item = $plan | Where-Object { $_.Item -eq 'iSCSI before the deployment' }
        $item.Action | Should -Be 'Skipped'
        $item.Note | Should -Match "don't|not to enable iSCSI"
        @($plan | Where-Object { $_.Item -in 'MSiSCSI service', 'iSCSI auto-claim' }) | Should -BeNullOrEmpty
        @($plan | Where-Object { $_.Apply -and $_.Apply.kind -in 'iscsi-service', 'iscsi-claim', 'iscsi-portal', 'iscsi-session' }) | Should -BeNullOrEmpty
    }
    It 'a SAN-only design on a later release than 2610 is treated the same' {
        ((Get-IscsiPlan 'san' '12.2701.1.1') | Where-Object { $_.Item -eq 'iSCSI before the deployment' }).Action | Should -Be 'Skipped'
    }
    It 'a SAN-only design on a release before 2610 still does the manual steps (Learn: for earlier versions, follow the steps)' {
        $plan = Get-IscsiPlan 'san' '12.2606.1004.50'
        @($plan | Where-Object { $_.Item -eq 'iSCSI before the deployment' }) | Should -BeNullOrEmpty
        ($plan | Where-Object { $_.Item -eq 'MSiSCSI service' }).Apply.kind | Should -Be 'iscsi-service'
        @($plan | Where-Object { $_.Apply -and $_.Apply.kind -eq 'iscsi-portal' }).Count | Should -Be 1
    }
    It 'a SAN-only design whose release is not known is Blocked and nothing about iSCSI is changed' {
        $plan = Get-IscsiPlan 'san' ''
        ($plan | Where-Object { $_.Item -eq 'iSCSI before the deployment' }).Action | Should -Be 'Blocked'
        @($plan | Where-Object { $_.Apply -and $_.Apply.kind -in 'iscsi-service', 'iscsi-claim', 'iscsi-portal', 'iscsi-session' }) | Should -BeNullOrEmpty
    }
    It 'takes the release from the ZTP handoff when the file gives none' {
        $infra = $script:Infra; $infra.scenario.storage_architecture = 'san'; $infra.provisioning.os_version = 'latest'
        (Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]).San.ReleaseTrain | Should -Be 0
        $spec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0] -Handoff ([pscustomobject]@{ VsrVersion = '12.2610.1004.50'; Nodes = @{} })
        $spec.San.ReleaseTrain | Should -Be 2610
        $spec.San.SolutionVersion | Should -Be '12.2610.1004.50'
    }
    It 'a hybrid design is unchanged on 2610 (Learn attaches the SAN after the deployment and says nothing against it before)' {
        $plan = Get-IscsiPlan 'hybrid' '12.2610.1004.50'
        @($plan | Where-Object { $_.Item -eq 'iSCSI before the deployment' }) | Should -BeNullOrEmpty
        ($plan | Where-Object { $_.Item -eq 'MSiSCSI service' }).Apply.kind | Should -Be 'iscsi-service'
    }
    It 'Fibre Channel is unchanged: the MPIO steps still run for a SAN-only design on 2610' {
        $infra = Get-HybridInfra -Type fibre_channel; $infra.scenario.storage_architecture = 'san'; $infra.deployment = [ordered]@{ solution_version = '12.2610.1004.50' }
        $plan = Get-Plan (Get-SpecOf $infra) (New-SanState -Hw @())
        @($plan | Where-Object { $_.Item -eq 'iSCSI before the deployment' }) | Should -BeNullOrEmpty
        @($plan | Where-Object { $_.Item -like 'MSDSM*' -and $_.Action -eq 'Change' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'The apply: plan, approval, apply, verify' {
    BeforeEach {
        $script:Spec = Get-SpecOf (Get-HybridInfra -Incomplete)
        Mock -ModuleName AzlNodeConfiguration Start-Sleep {}
    }
    It 'the lab case end to end: claim with mpclaim, one restart, each LUN once and listed by MPIO: converged' {
        $before = New-SanState -Mpdev @() -Avail @([pscustomobject]@{ vendor = 'PURE'; product = 'FlashArray'; multipathed = $false }) -Disk (@(Get-LunPath 1 3) + @(Get-LunPath 2 7))
        $after = New-SanState -Boot '2026-11-07T02:00:00Z' -Disk @((Get-LunClaimed 1 3), (Get-LunClaimed 2 4))
        $t = New-FakeTransport @($before, $after, $after) { param($p) [pscustomobject]@{ reboot = $true; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = $_.kind } }) } }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step $script:Steps -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        $applied = @($t.Log | Where-Object Kind -eq 'Apply')
        $applied.Count | Should -Be 1
        $claim = @($applied[0].Parameters.actions | Where-Object { $_.kind -eq 'mpio-claim' })
        $claim.Count | Should -Be 1
        $claim[0].vendor | Should -Be 'PURE'
        @($t.Log | Where-Object Kind -eq 'Restart').Count | Should -Be 1
        $r.Converged | Should -BeTrue
        ($r.Plan | Where-Object { $_.Item -eq 'mpclaim -s -d lists every LUN' }).Action | Should -Be 'Ok'
    }
    It 'registers MSDSM, restarts once, and the node comes back with every LUN claimed: converged' {
        $before = New-SanState -Hw @('Vendor*|Product*') -Lb 'None' -Disk (@(Get-LunPath 1 3) + @(Get-LunPath 2 7))
        $after = New-SanState -Boot '2026-11-07T02:00:00Z' -Disk @((Get-LunClaimed 1 3), (Get-LunClaimed 2 4))
        $t = New-FakeTransport @($before, $after, $after) { param($p) [pscustomobject]@{ reboot = $true; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = $_.kind } }) } }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step $script:Steps -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        $applied = @($t.Log | Where-Object Kind -eq 'Apply')
        $applied.Count | Should -Be 1
        @($applied[0].Parameters.actions | ForEach-Object { $_.kind }) | Should -Contain 'msdsm-hw'
        @($applied[0].Parameters.actions | ForEach-Object { $_.kind }) | Should -Contain 'msdsm-hw-remove'
        @($t.Log | Where-Object Kind -eq 'Restart').Count | Should -Be 1
        $r.Restarted | Should -BeTrue
        $r.Converged | Should -BeTrue
    }
    It 'when the hardware ID is already registered but the paths are still separate, one restart is asked for, and a second is not tried if they still are' {
        $stuck = New-SanState -Disk (Get-LunPath 1 3)
        $afterRestart = New-SanState -Boot '2026-11-07T02:00:00Z' -Disk (Get-LunPath 1 3)
        $t = New-FakeTransport @($stuck, $afterRestart, $afterRestart) { param($p) [pscustomobject]@{ reboot = $true; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = $_.kind } }) } }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Execute -Step $script:Steps -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        @($t.Log | Where-Object Kind -eq 'Apply').Count | Should -Be 1
        @($t.Log | Where-Object Kind -eq 'Restart').Count | Should -Be 1
        $r.Converged | Should -BeFalse
        $blocked = @($r.Plan | Where-Object { $_.Action -eq 'Blocked' -and $_.Item -eq 'MPIO claims the LUN paths' })
        $blocked.Count | Should -Be 1
        $blocked[0].Note | Should -Match 'a second restart is not tried'
    }
    It 'a plan only (no -Execute) changes nothing and sends no apply' {
        $before = New-SanState -Hw @() -Disk (Get-LunPath 1 3)
        $t = New-FakeTransport @($before) { param($p) throw 'Apply must not run in a plan' }
        $r = Invoke-AzlNodeConfiguration -Spec $script:Spec -Transport $t -Step $script:Steps -SecretResolver $script:Resolver -Clock $script:FakeClock -PortProbe $script:PortUp
        @($t.Log | Where-Object Kind -in 'Apply', 'Restart') | Should -BeNullOrEmpty
        @($r.Plan | Where-Object Action -eq 'Change').Count | Should -BeGreaterThan 0
    }
    It 'never offers to change or wipe a SAN LUN' {
        $plan = Get-Plan $script:Spec (New-SanState -Hw @() -Disk (Get-LunPath 1 3))
        @($plan | Where-Object { $_.Apply -and $_.Apply.kind -in 'storage-clear' }) | Should -BeNullOrEmpty
    }
}

Describe 'Consistency across nodes' {
    BeforeAll { $run = Import-Module (Join-Path $script:Repo 'scripts\common\node-configuration\AzlOsConfigurationRun.psm1') -Force -PassThru; $script:Run = $run }
    It 'nodes that see different SAN disks are reported when a SAN is declared, and not when it is not' {
        $records = @(
            [pscustomobject]@{ name = 'n1'; status = 'planned'; sanDisks = @([pscustomobject]@{ uid = 'A' }) }
            [pscustomobject]@{ name = 'n2'; status = 'planned'; sanDisks = @([pscustomobject]@{ uid = 'A' }, [pscustomobject]@{ uid = 'B' }) })
        $declared = & $script:Run { param($r) Test-AzlSanConsistency -Record $r -Declared $true } $records
        @($declared).Count | Should -Be 1
        $undeclared = & $script:Run { param($r) Test-AzlSanConsistency -Record $r -Declared $false } $records
        @($undeclared) | Should -BeNullOrEmpty
    }
}

Describe 'The node scripts' {
    It 'the Read script always lists the Fibre Channel and iSCSI disks, and reads MPIO, MSDSM and iSCSI only for a declared SAN' {
        $text = Get-AzlNodePayload -Name Read
        $text | Should -Match "Invoke-Section 'san'"
        $text | Should -Not -Match 'if \(Get-P \$P ''san'' \$false\) \{\s*Invoke-Section'
        $text | Should -Match "@\('Fibre Channel', 'iSCSI'\) -contains"
        $text | Should -Match 'Get-IscsiTargetPortal'
        $text | Should -Match 'Get-MPIOAvailableHW'
        $text | Should -Match 'MPIOSupportedDeviceList'
        $text | Should -Match 'Get-IscsiSession'
    }
    It 'the Apply script knows the new actions' {
        $text = Get-AzlNodePayload -Name Apply
        foreach ($kind in 'msdsm-hw-remove', 'mpio-claim', 'mpio-claim-restart', 'iscsi-portal', 'iscsi-session') { $text | Should -Match "'$kind'" }
        $text | Should -Match 'Remove-MSDSMSupportedHW'
        $text | Should -Match 'mpclaim\.exe -n -i -d \$device'
        $text | Should -Match '\{0,-8\}\{1,-16\}' -Because 'the vendor is padded to 8 characters and the product to 16'
        $text | Should -Match 'MPIOSupportedDeviceList'
        $text | Should -Match 'New-IscsiTargetPortal'
        $text | Should -Match 'Connect-IscsiTarget'
        $text | Should -Match 'IsMultipathEnabled = \$true'
    }
    It 'both scripts parse in Windows PowerShell 5.1 syntax: no ternary, no null-coalescing, no pipeline chain' {
        foreach ($name in 'Read', 'Apply') {
            $text = Get-AzlNodePayload -Name $name
            $errors = $null; $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            @($errors) | Should -BeNullOrEmpty
            $text | Should -Not -Match '\?\?'
            $text | Should -Not -Match '\s\?\s.*\s:\s'
        }
    }
}

Describe 'Validation: a hybrid file whose SAN block is incomplete is allowed (AZL-028)' {
    BeforeAll {
        function Get-Findings([System.Collections.IDictionary]$Infra) {
            $path = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            $Infra | ConvertTo-Yaml | Set-Content -LiteralPath $path -Encoding utf8
            @(Test-AzlInfrastructure -Path $path)
        }
    }
    It 'hybrid: missing target WWPNs and HBA WWPNs are warnings; the schema no longer requires storage.san.fibre_channel' {
        $f = Get-Findings (Get-HybridInfra -Incomplete)
        @($f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' }) | Should -BeNullOrEmpty
        @($f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'warning' -and $_.Path -eq 'storage.san.fibre_channel.target_wwpns' }).Count | Should -Be 1
        @($f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'warning' -and $_.Path -like 'nodes[[]*].san' }).Count | Should -Be 2
        @($f | Where-Object { $_.Path -match 'fibre_channel$' }) | Should -BeNullOrEmpty
    }
    It 'san (disaggregated): the target WWPNs and HBA WWPNs are still errors' {
        $infra = Get-HybridInfra -Incomplete; $infra.scenario.storage_architecture = 'san'
        $f = Get-Findings $infra
        @($f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' -and $_.Path -eq 'storage.san.fibre_channel.target_wwpns' }).Count | Should -Be 1
        @($f | Where-Object { $_.Id -eq 'AZL-028' -and $_.Severity -eq 'error' -and $_.Path -like 'nodes[[]*].san' }).Count | Should -Be 2
    }
    It 'a hybrid file without any storage.san block is still rejected: the type is what selects the host-side steps' {
        $infra = Get-HybridInfra -Incomplete; $infra.storage.Remove('san')
        $f = Get-Findings $infra
        @($f | Where-Object { $_.Severity -eq 'error' -and "$($_.Path)$($_.Message)" -match 'san' }).Count | Should -BeGreaterThan 0
    }
}
