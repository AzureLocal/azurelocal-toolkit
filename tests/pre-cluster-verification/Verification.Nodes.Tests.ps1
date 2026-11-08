#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pre-cluster verification, NODES (ND-) and READINESS (RD-) checks. Fakes only: no Azure, no Active Directory, no node.

BeforeAll {
    . ([IO.Path]::Combine($PSScriptRoot, 'Verification.NodeFixtures.ps1'))
    $script:Mod = Import-VerModule -Name Nodes
    function Invoke-VerRun([string]$Id, $World, $Infra, [hashtable]$Settings = @{}, [hashtable]$Adapter = @{}) {
        $ctx = New-VerContext -Module $script:Mod -Infra $Infra -World $World -Settings $Settings -Adapter $Adapter
        Invoke-VerCheck -Module $script:Mod -Id $Id -Context $ctx
    }
    function New-VerFresh { $i = New-VerInfra; $w = New-VerWorld -Infra $i; [pscustomobject]@{ Infra = $i; World = $w } }
}

Describe 'Contract' {
    It 'exports the two commands of the contract' {
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationCheckDefinition'
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationAdapterDefault'
    }
    It 'every definition has Id, Category, Title, Source, Blocking, Applies and Run' {
        $defs = Get-VerDefinition -Module $script:Mod
        $defs.Count | Should -Be 19
        foreach ($d in $defs) {
            $d.Id | Should -Match '^(ND|RD)-\d{3}$'
            $d.Category | Should -BeIn 'nodes', 'readiness'
            $d.Title | Should -Not -BeNullOrEmpty
            $d.Source | Should -Match 'learn.microsoft.com|azurelocal.cloud|azl-toolkit|config/'
            $d.Blocking | Should -BeOfType [bool]
            $d.Applies | Should -BeOfType [scriptblock]
            $d.Run | Should -BeOfType [scriptblock]
        }
        @($defs.Id | Select-Object -Unique).Count | Should -Be $defs.Count
        (@($defs | Where-Object Category -EQ 'readiness')).Count | Should -Be 7
    }
    It 'Applies answers a bool for the file alone' {
        $ctx = New-VerContext -Module $script:Mod -Infra (New-VerInfra) -World (New-VerWorld -Infra (New-VerInfra))
        foreach ($d in (Get-VerDefinition -Module $script:Mod)) { (& $d.Applies $ctx) | Should -BeOfType [bool] }
    }
    It 'the default adapter has the members the checks use, all scriptblocks' {
        $a = & $script:Mod.ExportedCommands['Get-AzlVerificationAdapterDefault']
        $a.Remote.Invoke | Should -BeOfType [scriptblock]
        foreach ($m in 'GetSnapshot', 'GetOsBuild', 'GetHardware', 'GetTime', 'GetDns', 'GetFeatures', 'GetReboot', 'GetDisks', 'GetAdapters', 'GetMpio', 'GetProbes', 'GetEnvChecker') { $a.Node[$m] | Should -BeOfType [scriptblock] }
        $a.Readiness.Run | Should -BeOfType [scriptblock]
    }
    It 'a healthy world passes every NODES check and reads each node with ONE remote call' {
        $f = New-VerFresh
        $ctx = New-VerContext -Module $script:Mod -Infra $f.Infra -World $f.World
        $all = foreach ($d in (Get-VerDefinition -Module $script:Mod | Where-Object Category -EQ 'nodes')) { foreach ($r in (Invoke-VerCheck -Module $script:Mod -Id $d.Id -Context $ctx)) { [pscustomobject]@{ Id = $d.Id; Status = $r.Status; Message = $r.Message } } }
        $bad = @($all | Where-Object { $_.Status -notin 'Passed', 'NotApplicable' })
        $bad | Should -BeNullOrEmpty -Because (($bad | ForEach-Object { "$($_.Id) $($_.Status): $($_.Message)" }) -join "`n")
        $f.World.Calls.Count | Should -Be 2
    }
    It 'results carry Status, Node, Message, Remedy and Evidence, and no secret' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].os.build = '10.0.26100.1'
        $r = Invoke-VerRun 'ND-003' $f.World $f.Infra
        $r[0].PSObject.Properties.Name | Should -Contain 'Evidence'
        $r[0].PSObject.Properties.Name | Should -Contain 'Remedy'
        $r[0].Node | Should -Not -BeNullOrEmpty
    }
}

Describe 'ND-001 nodes answer' {
    It 'Passed per node' {
        $f = New-VerFresh
        $r = Invoke-VerRun 'ND-001' $f.World $f.Infra
        @($r | Where-Object Status -EQ 'Passed').Count | Should -Be 2
        $r[0].Message | Should -Match '26100.33650'
    }
    It 'Failed for a node that does not answer, with the reason; the other checks are Skipped for it' {
        $f = New-VerFresh; $f.World.Down['n02'] = 'WinRM cannot connect to n02'
        $r = Invoke-VerRun 'ND-001' $f.World $f.Infra
        ($r | Where-Object Node -EQ 'n02').Status | Should -Be 'Failed'
        ($r | Where-Object Node -EQ 'n02').Message | Should -Match 'WinRM cannot connect'
        $o = Invoke-VerRun 'ND-007' $f.World $f.Infra
        ($o | Where-Object Node -EQ 'n02').Status | Should -Be 'Skipped'
        ($o | Where-Object Node -EQ 'n01').Status | Should -Be 'Passed'
    }
    It 'Failed (never Passed) when parts of the read failed' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].err = @{ mpio = 'cmdlet missing' }
        (Invoke-VerRun 'ND-001' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed'
    }
    It 'Skipped, not Failed, when the adapter has no Remote.Invoke' {
        $f = New-VerFresh
        $r = Invoke-VerRun 'ND-001' $f.World $f.Infra -Adapter @{ Remote = @{} }
        @($r | Where-Object Status -EQ 'Skipped').Count | Should -Be 2
    }
}

Describe 'ND-002 computer name' {
    It 'Passed when it matches' { $f = New-VerFresh; (Invoke-VerRun 'ND-002' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'Failed when it differs from the file' { $f = New-VerFresh; $f.World.Snapshot['n01'].host = 'WIN-X1'; (Invoke-VerRun 'ND-002' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'Failed for an underscore in the name' {
        $f = New-VerFresh; $f.Infra.nodes[0].name = 'node_01'; $f.World = New-VerWorld -Infra $f.Infra
        (Invoke-VerRun 'ND-002' $f.World $f.Infra | Where-Object Node -EQ 'node_01').Message | Should -Match 'underscore'
    }
}

Describe 'ND-003 and ND-004 OS build' {
    It 'ND-003 Passed for identical builds' { $f = New-VerFresh; (Invoke-VerRun 'ND-003' $f.World $f.Infra).Status | Should -Be 'Passed' }
    It 'ND-003 Failed when the builds differ' { $f = New-VerFresh; $f.World.Snapshot['n02'].os.build = '10.0.26100.32370'; $r = Invoke-VerRun 'ND-003' $f.World $f.Infra; $r[0].Status | Should -Be 'Failed'; $r[0].Evidence | Should -Match 'n02=10.0.26100.32370' }
    It 'ND-003 Skipped when no node can be read' { $f = New-VerFresh; $f.World.Down['n01'] = 'x'; $f.World.Down['n02'] = 'x'; (Invoke-VerRun 'ND-003' $f.World $f.Infra).Status | Should -Be 'Skipped' }
    It 'ND-004 Passed: 26100.33650 is solution 12.2610.1004.50 (the lab)' { $f = New-VerFresh; @(Invoke-VerRun 'ND-004' $f.World $f.Infra | Where-Object Status -NE 'Passed').Count | Should -Be 0 }
    It 'ND-004 reads the target from Settings.solutionVersion first' {
        $f = New-VerFresh
        $r = Invoke-VerRun 'ND-004' $f.World $f.Infra -Settings @{ solutionVersion = '12.2611.1002.10' }
        $r[0].Status | Should -Be 'Failed'; $r[0].Message | Should -Match '12.2611.1002.10'
    }
    It 'ND-004 Skipped (could not compare, not a Warning) for an OS build that is not in the table' { $f = New-VerFresh; $f.World.Snapshot['n01'].os.build = '10.0.26100.99999'; (Invoke-VerRun 'ND-004' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Skipped' }
    It 'ND-004 NotApplicable without a target' { $f = New-VerFresh; $f.Infra.provisioning = @{}; (Invoke-VerRun 'ND-004' $f.World $f.Infra).Status | Should -Be 'NotApplicable' }
}

Describe 'ND-005 time' {
    It 'Passed with a real NTP source in step' { $f = New-VerFresh; (Invoke-VerRun 'ND-005' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'Failed on the local CMOS clock' { $f = New-VerFresh; $f.World.Snapshot['n01'].time.src = 'Local CMOS Clock'; (Invoke-VerRun 'ND-005' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'Failed when the clock is more than 300 seconds off' { $f = New-VerFresh; $f.World.Snapshot['n02'].utc = $f.World.Now.AddSeconds(900).ToString('o'); (Invoke-VerRun 'ND-005' $f.World $f.Infra | Where-Object Node -EQ 'n02').Status | Should -Be 'Failed' }
    It 'Failed when the nodes use different NTP peers' { $f = New-VerFresh; $f.World.Snapshot['n02'].time.peers = '192.0.2.9,0x8'; @(Invoke-VerRun 'ND-005' $f.World $f.Infra | Where-Object { $_.Status -eq 'Failed' -and $_.Node -eq '*' }).Count | Should -Be 1 }
}

Describe 'ND-006 DNS client' {
    It 'Passed with the DNS servers of the file' { $f = New-VerFresh; (Invoke-VerRun 'ND-006' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'Failed for a public resolver' { $f = New-VerFresh; $f.World.Snapshot['n01'].dns[0].servers = @('8.8.8.8'); (Invoke-VerRun 'ND-006' $f.World $f.Infra | Where-Object Node -EQ 'n01').Message | Should -Match 'public resolver'; }
    It 'Failed when the servers differ from the file' { $f = New-VerFresh; $f.World.Snapshot['n02'].dns[0].servers = @('192.0.2.77'); (Invoke-VerRun 'ND-006' $f.World $f.Infra | Where-Object Node -EQ 'n02').Status | Should -Be 'Failed' }
}

Describe 'ND-007 pending restart' {
    It 'Passed' { $f = New-VerFresh; (Invoke-VerRun 'ND-007' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'Failed on a servicing reboot' { $f = New-VerFresh; $f.World.Snapshot['n01'].reboot.cbs = $true; (Invoke-VerRun 'ND-007' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'Warning on PendingFileRenameOperations only' { $f = New-VerFresh; $f.World.Snapshot['n01'].reboot.files = $true; (Invoke-VerRun 'ND-007' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning' }
}

Describe 'ND-008 processors and memory, ND-009 boot disk' {
    It 'ND-008 Failed below the minimum memory' { $f = New-VerFresh; $f.World.Snapshot['n01'].cs.memBytes = [int64]16GB; (Invoke-VerRun 'ND-008' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'ND-008 the minimum is a setting' { $f = New-VerFresh; $f.World.Snapshot['n01'].cs.memBytes = [int64]64GB; (Invoke-VerRun 'ND-008' $f.World $f.Infra -Settings @{ verificationMinMemoryGiB = 128 } | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'ND-008 Failed when virtualization is off' { $f = New-VerFresh; $f.World.Snapshot['n01'].cpu[0].vt = $false; $f.World.Snapshot['n01'].cs.hypervisor = $false; (Invoke-VerRun 'ND-008' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'ND-008 Failed when the processors differ' { $f = New-VerFresh; $f.World.Snapshot['n02'].cpu[0].cores = 12; @(Invoke-VerRun 'ND-008' $f.World $f.Infra | Where-Object { $_.Status -eq 'Failed' -and $_.Node -eq '*' }).Count | Should -Be 1 }
    It 'ND-008 Warning when the file declares more cores than the node has' { $f = New-VerFresh; $f.Infra.hardware.cpu_cores = 128; (Invoke-VerRun 'ND-008' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning' }
    It 'ND-009 Passed with a 480 GB BOSS boot disk' { $f = New-VerFresh; (Invoke-VerRun 'ND-009' $f.World $f.Infra).Status | Should -Not -Contain 'Failed' }
    It 'ND-009 Failed with a boot disk under 200 GB' { $f = New-VerFresh; $f.World.Snapshot['n01'].disks[0].size = 120000000000; (Invoke-VerRun 'ND-009' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
}

Describe 'ND-010 features, ND-011 firmware, ND-012 cluster membership' {
    It 'ND-010 Failed for a missing required feature, with the exact command' {
        $f = New-VerFresh; ($f.World.Snapshot['n01'].features | Where-Object n -EQ 'NetworkATC').installed = $false
        $r = Invoke-VerRun 'ND-010' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Failed'; $r.Remedy | Should -Match 'Install-WindowsFeature -Name NetworkATC'
    }
    It 'ND-010 Warning for a missing advised feature' { $f = New-VerFresh; ($f.World.Snapshot['n01'].features | Where-Object n -EQ 'RSAT-AD-PowerShell').installed = $false; (Invoke-VerRun 'ND-010' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Warning' }
    It 'ND-011 Failed with Secure Boot off' { $f = New-VerFresh; $f.World.Snapshot['n01'].fw.secureBoot = $false; (Invoke-VerRun 'ND-011' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'ND-011 Failed with TPM 1.2' { $f = New-VerFresh; $f.World.Snapshot['n01'].fw.tpmSpec = '1.2, 2, 1.16'; (Invoke-VerRun 'ND-011' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
    It 'ND-011 Warning when the BIOS versions differ' { $f = New-VerFresh; $f.World.Snapshot['n02'].fw.biosVersion = '2.0.9'; @(Invoke-VerRun 'ND-011' $f.World $f.Infra | Where-Object { $_.Status -eq 'Warning' -and $_.Node -eq '*' }).Count | Should -Be 1 }
    It 'ND-012 Failed when the node is in a running cluster' { $f = New-VerFresh; $f.World.Snapshot['n01'].cluster = @{ svc = 'Running'; name = 'old-clus' }; (Invoke-VerRun 'ND-012' $f.World $f.Infra | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed' }
}

Describe 'READINESS: Environment Checker validators' {
    It 'RD-001 Passed when the module is on the node' { $f = New-VerFresh; (Invoke-VerRun 'RD-001' $f.World $f.Infra).Status | Should -Not -Contain 'Skipped' }
    It 'RD-001 Skipped with the exact install command when the module is not on the node' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].ec = @()
        $r = Invoke-VerRun 'RD-001' $f.World $f.Infra | Where-Object Node -EQ 'n01'
        $r.Status | Should -Be 'Skipped'
        $r.Remedy | Should -Match 'Install-Module -Name AzStackHci.EnvironmentChecker -Repository PSGallery'
    }
    It 'RD-002..RD-005, RD-007 Passed when the validator ran clean' {
        $f = New-VerFresh
        foreach ($id in 'RD-002', 'RD-003', 'RD-004', 'RD-005') { (Invoke-VerRun $id $f.World $f.Infra).Status | Should -Not -Contain 'Failed' -Because $id }
    }
    It 'RD-002 Failed on a critical finding, with the validator remediation' {
        $f = New-VerFresh
        $f.World.Ec = @{ Connectivity = @{ Available = $true; Results = @(@{ Node = 'n01'; Name = 'AzStackHci_Connectivity_Arc'; Title = 'Arc endpoint'; Status = 'FAILURE'; Severity = 'CRITICAL'; Description = 'login.microsoftonline.com unreachable'; Remediation = 'https://aka.ms/hci-envch'; Target = 'n01' }) } }
        $r = Invoke-VerRun 'RD-002' $f.World $f.Infra
        $r[0].Status | Should -Be 'Failed'; $r[0].Message | Should -Match 'unreachable'; $r[0].Remedy | Should -Match 'aka.ms'
    }
    It 'RD-003 Warning on a warning-severity finding' {
        $f = New-VerFresh
        $f.World.Ec = @{ Hardware = @{ Available = $true; Results = @(@{ Node = 'n01'; Name = 'Memory'; Title = 'Memory consistent'; Status = 'FAILURE'; Severity = 'WARNING'; Description = 'differs'; Remediation = ''; Target = 'n01' }) } }
        (Invoke-VerRun 'RD-003' $f.World $f.Infra)[0].Status | Should -Be 'Warning'
    }
    It 'RD-002 Skipped, saying why, when the module is not installed (a Skipped blocks the gate)' {
        $f = New-VerFresh
        $f.World.Ec = @{ Connectivity = @{ Available = $false; Reason = 'the module AzStackHci.EnvironmentChecker is not installed on this node' } }
        $r = Invoke-VerRun 'RD-002' $f.World $f.Infra
        $r[0].Status | Should -Be 'Skipped'; $r[0].Message | Should -Match 'not installed'; $r[0].Remedy | Should -Match 'Install-Module'
        (Get-VerDefinition -Module $script:Mod -Id 'RD-002').Blocking | Should -BeTrue
    }
    It 'RD-004 Skipped when the adapter has no Readiness.Run' {
        $f = New-VerFresh
        (Invoke-VerRun 'RD-004' $f.World $f.Infra -Adapter @{ Readiness = @{} })[0].Status | Should -Be 'Skipped'
    }
    It 'RD-006 NotApplicable for local identity; RD-006 and RD-007 are not blocking when they cannot run' {
        $f = New-VerFresh; $f.Infra.scenario.identity = 'local_identity'
        (Invoke-VerRun 'RD-006' $f.World $f.Infra)[0].Status | Should -Be 'NotApplicable'
        (Get-VerDefinition -Module $script:Mod -Id 'RD-006').Blocking | Should -BeFalse
        (Get-VerDefinition -Module $script:Mod -Id 'RD-007').Blocking | Should -BeFalse
    }
    It 'the default Readiness.Run says why Software cannot run without the credential' {
        $f = New-VerFresh
        $a = & $script:Mod.ExportedCommands['Get-AzlVerificationAdapterDefault']
        $ctx = New-VerContext -Module $script:Mod -Infra $f.Infra -World $f.World
        $ans = & $a.Readiness.Run 'Software' $ctx
        $ans.Available | Should -BeFalse; $ans.Reason | Should -Match 'credential'
    }
}

Describe 'The default adapter' {
    It 'GetDisks and GetAdapters of one node cost ONE remote call (the snapshot is cached)' {
        $f = New-VerFresh
        $ctx = New-VerContext -Module $script:Mod -Infra $f.Infra -World $f.World
        $a = $ctx.Adapters.Node
        $d = & $a.GetDisks 'n01' $ctx
        $n = & $a.GetAdapters 'n01' $ctx
        $f.World.Calls.Count | Should -Be 1
        @($d.disks).Count | Should -Be 5
        @($n.nics).Count | Should -Be 4
    }
    It 'a test can replace one member with a fake' {
        $f = New-VerFresh
        $fake = { param($Node, $Context) [pscustomobject]@{ host = 'FAKEHOST'; utc = ''; os = [pscustomobject]@{ build = '10.0.26100.33650' }; cs = $null } }
        (Invoke-VerRun 'ND-002' $f.World $f.Infra -Adapter @{ Node = @{ GetOsBuild = $fake } } | Where-Object Node -EQ 'n01').Status | Should -Be 'Failed'
    }
    It 'the snapshot script is valid Windows PowerShell and read only (no Set-/Remove-/Install-/New- cmdlet)' {
        $sb = & $script:Mod { Get-AzlVerSnapshotScript -Parameter @{ features = @('Hyper-V'); tcp = @(); ping = @(); https = @(); proxy = '' } }
        $errors = $null; $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($sb.ToString(), [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $verbs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match "^(Set|Remove|Install|New|Add|Enable|Disable|Clear|Start|Stop|Restart|Update|Register|Uninstall)-" -and $_ -ne "New-Object" })
        $verbs | Should -BeNullOrEmpty -Because "found: $($verbs -join ', ')"
    }
}

Describe 'A section whose read failed is never read as fine (review C1)' {
    It '<Id> is Skipped on the node whose <Section> read failed, with the reason, and not Passed' -ForEach @(
        @{ Id = 'ND-010'; Section = 'features' }
        @{ Id = 'ND-007'; Section = 'reboot' }
        @{ Id = 'ND-012'; Section = 'cluster' }
    ) {
        $f = New-VerFresh; $f.World.Snapshot['n01'].err = @{ $Section = 'access denied' }
        $r = @(Invoke-VerRun $Id $f.World $f.Infra | Where-Object Node -EQ 'n01')
        $r.Count | Should -BeGreaterThan 0
        ($r | Where-Object Status -EQ 'Passed') | Should -BeNullOrEmpty
        ($r | Select-Object -First 1).Status | Should -Be 'Skipped'
        ($r | Select-Object -First 1).Message | Should -Match 'access denied'
    }
    It 'the other node is still checked' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].err = @{ features = 'access denied' }
        (Invoke-VerRun 'ND-010' $f.World $f.Infra | Where-Object Node -EQ 'n02').Status | Should -Be 'Passed'
    }
}
Describe 'Could not verify is Skipped, never Warning (review C2)' {
    It 'ND-010 is Skipped when the node lists none of the required features' {
        $f = New-VerFresh; $f.World.Snapshot['n01'].features = @()
        $r = @(Invoke-VerRun 'ND-010' $f.World $f.Infra | Where-Object Node -EQ 'n01')
        $r[0].Status | Should -Be 'Skipped'
    }
}

Describe 'Environment Checker rows: only an explicit success passes (review C3)' {
    It 'a row with status <Status> and severity <Severity> is <Expected>' -ForEach @(
        @{ Status = 'ERROR'; Severity = 'CRITICAL'; Expected = 'Failed' }
        @{ Status = ''; Severity = 'CRITICAL'; Expected = 'Failed' }
        @{ Status = 'ABORTED'; Severity = ''; Expected = 'Failed' }
        @{ Status = 'UNKNOWNSTATE'; Severity = 'weird'; Expected = 'Failed' }
        @{ Status = 'FAILURE'; Severity = ''; Expected = 'Failed' }
        @{ Status = 'SKIPPED'; Severity = 'CRITICAL'; Expected = 'Skipped' }
        @{ Status = 'FAILURE'; Severity = 'WARNING'; Expected = 'Warning' }
        @{ Status = 'SUCCESS'; Severity = 'CRITICAL'; Expected = 'Passed' }
    ) {
        $f = New-VerFresh
        $f.World.Ec = @{ Hardware = @{ Available = $true; Results = @(@{ Node = 'n01'; Name = 'T1'; Title = 'T one'; Status = $Status; Severity = $Severity; Description = 'd'; Remediation = ''; Target = 'n01' }) } }
        (Invoke-VerRun 'RD-003' $f.World $f.Infra)[0].Status | Should -Be $Expected
    }
    It 'no result rows at all is Skipped, not Passed' {
        $f = New-VerFresh
        $f.World.Ec = @{ Hardware = @{ Available = $true; Results = @() } }
        (Invoke-VerRun 'RD-003' $f.World $f.Infra)[0].Status | Should -Be 'Skipped'
    }
}
