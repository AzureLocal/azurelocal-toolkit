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
        'scripts/common/redfish/AzlRedfishCore.psm1'
        'scripts/common/redfish/AzlRedfishDell.psm1'
        'scripts/common/redfish/AzlRedfishInventory.psm1'
        'scripts/common/idrac-management/AzlDellRedfish.psm1'
        'scripts/common/infrastructure/AzlInfrastructureEdit.psm1'
        'scripts/common/idrac-management/Enable-IdracVnc.ps1'
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Invoke-HardwareDiscovery.ps1'
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Update-InfrastructureYml-FromDiscovery.ps1'
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Get-HardwareInventory.ps1'
        'config/oem/dell-endpoints.md'
    ) | ForEach-Object { @{ Relative = $_; Full = (Join-Path $repoRoot $_) } }
}

BeforeAll {
    $repo = (Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    $script:Redfish = [System.IO.Path]::Combine($repo, 'scripts', 'common', 'idrac-management', 'AzlDellRedfish.psm1')
    . (Join-Path $PSScriptRoot 'RedfishFakeBmc.ps1')
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')) -Force
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishDell.psm1')) -Force
    Import-Module $script:Redfish -Force
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructureEdit.psm1')) -Force
    Import-Module powershell-yaml
    $task = [System.IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-01-hardware-provisioning', 'task-02-hardware-discovery-via-dell-redfish-api', 'powershell')
    $script:InvokeScript = Join-Path $task 'Invoke-HardwareDiscovery.ps1'
    $script:UpdateScript = Join-Path $task 'Update-InfrastructureYml-FromDiscovery.ps1'
    $script:VncScript = [System.IO.Path]::Combine($repo, 'scripts', 'common', 'idrac-management', 'Enable-IdracVnc.ps1')
    $script:Cred = [pscredential]::new('admin', (ConvertTo-SecureString 'not-a-real-secret' -AsPlainText -Force))

    # Discovery of the synthetic fixture, as the flat view the infrastructure.yml tools read.
    function Get-FixtureDiscovery {
        $report = Invoke-AzlRedfishDiscovery -BmcAddress 'bmc.invalid' -Credential $script:Cred -Detail Summary -RetryDelaySeconds 0
        $view = ConvertTo-AzlDiscoveryLegacyView -Report $report
        $view['NodeName'] = 'node-1'
        return $view
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

Describe 'MAC notation' {
    It 'normalises <In>' -ForEach @(
        @{ In = '00-00-5e-00-53-0a'; Out = '00:00:5E:00:53:0A' }
        @{ In = '00005E00530A'; Out = '00:00:5E:00:53:0A' }
        @{ In = '0000.5E00.530A'; Out = '00:00:5E:00:53:0A' }
    ) { ConvertTo-AzlMacAddress $In | Should -Be $Out }
    It 'rejects <In>' -ForEach @(@{ In = '' }, @{ In = 'not a mac' }, @{ In = '00:00:5E:00:53' }, @{ In = '00:00:5E:00:53:0G' }) { ConvertTo-AzlMacAddress $In | Should -BeNullOrEmpty }
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
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $d = Get-FixtureDiscovery
        $script:Proposal = ConvertTo-AzlDiscoveryProposal -Item @([pscustomobject]@{ NodeName = 'node-1'; Discovery = $d; ManagementPort = 'Slot 3 Port 1'; ExistingManagementMac = '' })
        $script:ProposalYaml = ConvertFrom-Yaml $script:Proposal -Ordered
    }
    AfterAll { Remove-FakeBmc }
    It 'is valid YAML with the service tag as serial_number' {
        $script:ProposalYaml.nodes[0].name | Should -Be 'node-1'
        $script:ProposalYaml.nodes[0].serial_number | Should -Be 'DOCTAG1'
    }
    It 'lists every port with its MAC, slot and model' {
        $ports = @($script:ProposalYaml.nodes[0].network_adapters)
        $ports.Count | Should -Be 6
        ($ports | ForEach-Object { $_.mac_address }) | Should -Contain '00:00:5E:00:53:22'
        ($ports | Where-Object name -eq 'Slot 3 Port 1').slot | Should -Be 'Slot 3'
        ($ports | Where-Object name -eq 'Slot 3 Port 1').model | Should -Be 'DOC 100GbE 2P ConnectX6 Adpt'
        ($ports | Where-Object name -eq 'Embedded NIC 2').mac_address | Should -Be '00:00:5E:00:53:11'
        ($ports | Where-Object name -eq 'Embedded NIC 2').model | Should -Be 'Broadcom Gigabit Ethernet BCM5720'
    }
    It 'never writes a generic label as a model' {
        $script:Proposal | Should -Not -Match 'Network Adapter View'
    }
    It 'marks only the chosen port management and leaves roles for the others as unused' {
        $ports = @($script:ProposalYaml.nodes[0].network_adapters)
        ($ports | Where-Object { $_.roles -contains 'management' }).name | Should -Be 'Slot 3 Port 1'
        @($ports | Where-Object { $_.roles -contains 'unused' }).Count | Should -Be 5
        $script:Proposal | Should -Match 'BOSS: controller BOSS.SL.12-1, 2 drive\(s\), a virtual disk exists'
    }
    It 'says in a comment that nothing is applied' { $script:Proposal | Should -Match 'Nothing is applied' }
}
Describe 'Resolve-AzlBmcCredential' {
    BeforeAll {
        $script:Infra = [ordered]@{ hardware = [ordered]@{ bmc = [ordered]@{ username = 'keyvault://vault-test/bmc-user'; password = 'keyvault://vault-test/bmc-pass' } } }
    }
    BeforeEach {
        Mock -ModuleName AzlRedfishCore Get-AzlBmcKeyVaultSecret {
            if ($PesterBoundParameters.ContainsKey('AsPlainText')) { return "user-of-$($Reference.Split('/')[-1])" }
            return (ConvertTo-SecureString "pw-of-$($Reference.Split('/')[-1])" -AsPlainText -Force)
        }
        Mock -ModuleName AzlRedfishCore Get-Credential { [pscredential]::new('prompted', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }
    }
    It 'prefers the credential parameter and never calls Key Vault' {
        (Resolve-AzlBmcCredential -Credential $script:Cred -Infrastructure $script:Infra).UserName | Should -Be 'admin'
        Should -Invoke -ModuleName AzlRedfishCore Get-AzlBmcKeyVaultSecret -Times 0
    }
    It 'reads hardware.bmc from Key Vault' {
        $c = Resolve-AzlBmcCredential -Infrastructure $script:Infra
        $c.UserName | Should -Be 'user-of-bmc-user'
        $c.GetNetworkCredential().Password | Should -Be 'pw-of-bmc-pass'
        Should -Invoke -ModuleName AzlRedfishCore Get-Credential -Times 0
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
        Mock -ModuleName AzlRedfishCore Get-AzlBmcKeyVaultSecret { throw 'vault unreachable' }
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
            if ($PesterBoundParameters["Method"] -eq 'Patch') { $global:AzlTestPatch = @{ Path = $Path; Body = $Body }; return [pscustomobject]@{} }
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
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $script:Discovery = Get-FixtureDiscovery
        $script:Infra = ConvertFrom-Yaml $script:NodeYaml -Ordered
    }
    AfterAll { Remove-FakeBmc }
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
        $doc.nodes[0].serial_number | Should -Be 'DOCTAG1'
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
        Use-FakeBmc
        Mock -ModuleName AzlRedfishCore Invoke-WebRequest $script:FakeBmcResponder
        $script:Cfg = Join-Path $TestDrive 'infrastructure.yml'
        Set-Content $script:Cfg $script:NodeYaml
        $script:Out = Join-Path $TestDrive 'discovery'
    }
    AfterAll { Remove-FakeBmc }

    It 'Invoke-HardwareDiscovery writes the node file, the summary and the proposal, and leaves infrastructure.yml alone' {
        $before = Get-Content $script:Cfg -Raw
        & $script:InvokeScript -ConfigPath $script:Cfg -OutputPath $script:Out -Credential $script:Cred -TargetNode 'node-1' -Detail Summary -ManagementPort 'Embedded NIC 1' -ThrottleLimit 1 -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        Test-Path (Join-Path $script:Out 'DOCTAG1.json') | Should -BeTrue
        $summary = Get-Content (Join-Path $script:Out 'discovery-summary.json') -Raw | ConvertFrom-Json
        $summary[0].ServiceTag | Should -Be 'DOCTAG1'
        $summary[0].Vendor | Should -Be 'Dell'
        $summary[0].ManagementMac | Should -Be '00:00:5E:00:53:10'
        $summary[0].Boss.HasVirtualDisk | Should -BeTrue
        $summary[0].Complete | Should -BeTrue
        (Get-Content (Join-Path $script:Out 'infrastructure.discovered.yml') -Raw) | Should -Match 'serial_number: "DOCTAG1"'
        (Get-Content $script:Cfg -Raw) | Should -Be $before
    }
    It 'Invoke-HardwareDiscovery names its summary and proposal file by parameter, and takes the Redfish limits as parameters' {
        $out = Join-Path $TestDrive 'discovery-named'
        & $script:InvokeScript -ConfigPath $script:Cfg -OutputPath $out -Credential $script:Cred -TargetNode 'node-1' -Detail Summary -ManagementPort 'Embedded NIC 1' -ThrottleLimit 1 `
            -SummaryFileName 'summary-run1.json' -ProposalFileName 'proposal-run1.yml' -TimeoutSeconds 30 -ConnectTimeoutSeconds 5 -MaxRetries 0 -RetryDelaySeconds 1 -NodeBudgetSeconds 600 -MaxMembers 500 `
            -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        Test-Path (Join-Path $out 'summary-run1.json') | Should -BeTrue
        Test-Path (Join-Path $out 'proposal-run1.yml') | Should -BeTrue
        Test-Path (Join-Path $out 'discovery-summary.json') | Should -BeFalse
        (Get-Content -LiteralPath $script:InvokeScript -Raw) | Should -Not -Match "Join-Path \`$OutputPath '(discovery-summary\.json|infrastructure\.discovered\.yml)'"
    }
    It 'the node file is a schema 2.0 report with the capability report, and holds no password' {
        $text = Get-Content (Join-Path $script:Out 'DOCTAG1.json') -Raw
        $text | Should -Not -Match 'not-a-real-secret'
        $r = $text | ConvertFrom-Json
        $r.schemaVersion | Should -Be '2.0'
        $r.nodeName | Should -Be 'node-1'
        $r.vendor.name | Should -Be 'Dell'
        $r.capabilities.areas.network.status | Should -Be 'ok'
        $r.PSObject.Properties.Name | Should -Contain 'readErrors'
    }
    It 'Invoke-HardwareDiscovery -Detail Full writes the full detail for every node it reads' {
        $out = Join-Path $TestDrive 'full'
        & $script:InvokeScript -ConfigPath $script:Cfg -OutputPath $out -Credential $script:Cred -TargetNode 'node-1' -Detail Full -ThrottleLimit 1 -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $r = Get-Content (Join-Path $out 'DOCTAG1.json') -Raw | ConvertFrom-Json
        @($r.firmware).Count | Should -BeGreaterThan 5
        @($r.pcie).Count | Should -Be 3
        $r.capabilities.summary.ok | Should -Be 12
    }
    It 'Invoke-HardwareDiscovery names a non-Dell BMC as unsupported in this version and still fails the run' {
        $root = Get-FakeResource '/redfish/v1'
        $root.Oem = @{ Hpe = @{} }; $root.Vendor = 'HPE'
        Set-FakeResource '/redfish/v1' $root
        $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
        $sys.Oem = @{ Hpe = @{} }; $sys.Manufacturer = 'HPE'
        Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
        $mgr = Get-FakeResource '/redfish/v1/Managers/iDRAC.Embedded.1'
        $mgr.Oem = @{ Hpe = @{} }; $mgr.Model = 'iLO 5'
        Set-FakeResource '/redfish/v1/Managers/iDRAC.Embedded.1' $mgr
        $err = $null
        try { & $script:InvokeScript -ConfigPath $script:Cfg -OutputPath (Join-Path $TestDrive 'hpe') -Credential $script:Cred -Detail Summary -ThrottleLimit 1 -InformationAction SilentlyContinue -ErrorVariable ev -ErrorAction SilentlyContinue } catch { $err = $_.Exception.Message }
        $err | Should -Match 'could not be discovered'
        ($ev | ForEach-Object { $_.ToString() }) -join ' ' | Should -Match 'Unsupported vendor in this version'
        Use-FakeBmc
    }
    It '-Vendor Dell forces the Dell adapter' {
        $root = Get-FakeResource '/redfish/v1'
        $root.Remove('Oem'); $root.Remove('Vendor'); $root.Product = 'BMC'
        Set-FakeResource '/redfish/v1' $root
        $sys = Get-FakeResource '/redfish/v1/Systems/System.Embedded.1'
        $sys.Remove('Oem'); $sys.Manufacturer = 'Contoso'
        Set-FakeResource '/redfish/v1/Systems/System.Embedded.1' $sys
        $mgr = Get-FakeResource '/redfish/v1/Managers/iDRAC.Embedded.1'
        $mgr.Remove('Oem'); $mgr.Model = 'BMC'
        Set-FakeResource '/redfish/v1/Managers/iDRAC.Embedded.1' $mgr
        $out = Join-Path $TestDrive 'forced'
        & $script:InvokeScript -ConfigPath $script:Cfg -OutputPath $out -Credential $script:Cred -Detail Summary -Vendor Dell -ThrottleLimit 1 -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        (Get-Content (Join-Path $out 'DOCTAG1.json') -Raw | ConvertFrom-Json).vendor.confidence | Should -Be 'override'
        Use-FakeBmc
    }
    It 'Update-InfrastructureYml-FromDiscovery previews without -Apply' {
        $before = Get-Content $script:Cfg -Raw
        & $script:UpdateScript -ConfigPath $script:Cfg -DiscoveryPath $script:Out -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        (Get-Content $script:Cfg -Raw) | Should -Be $before
    }
    It 'Update-InfrastructureYml-FromDiscovery -Apply -Force writes serial and MACs from a schema 2.0 file' {
        & $script:UpdateScript -ConfigPath $script:Cfg -DiscoveryPath $script:Out -Apply -Force -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $doc = ConvertFrom-Yaml (Get-Content $script:Cfg -Raw) -Ordered
        $doc.nodes[0].serial_number | Should -Be 'DOCTAG1'
        ($doc.nodes[0].network_adapters | Where-Object name -eq 'Slot 3 Port 1').mac_address | Should -Be '00:00:5E:00:53:21'
        @(Get-ChildItem (Split-Path $script:Cfg) -Filter 'infrastructure.yml.bak.*').Count | Should -BeGreaterThan 0
    }
    It 'Invoke-HardwareDiscovery fails (after writing the others) when a node cannot be read' {
        Remove-FakeResource '/redfish/v1/Systems/System.Embedded.1'
        { & $script:InvokeScript -ConfigPath $script:Cfg -OutputPath (Join-Path $TestDrive 'fail') -Credential $script:Cred -Detail Summary -ThrottleLimit 1 -InformationAction SilentlyContinue -ErrorAction SilentlyContinue -WarningAction SilentlyContinue } | Should -Throw '*could not be discovered*'
        Use-FakeBmc
    }
    It 'sends only GET requests during the whole scripted run' {
        @(Get-FakeCall | Where-Object Method -ne 'Get').Count | Should -Be 0
    }
    It 'Enable-IdracVnc -WhatIf touches no iDRAC' {
        Mock -ModuleName AzlDellRedfish Invoke-AzlRedfish { [pscustomobject]@{ Attributes = [pscustomobject]@{ 'VNCServer.1.Enable' = 'Disabled' } } }
        $r = & $script:VncScript -BmcAddress 'bmc.invalid' -Credential $script:Cred -WhatIf -InformationAction SilentlyContinue
        $r.Status | Should -Be 'WhatIf'
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
