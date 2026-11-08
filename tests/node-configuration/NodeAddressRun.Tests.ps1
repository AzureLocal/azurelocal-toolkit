#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The OS configuration run with automatic address resolution (HOOK address-resolution): a ZTP node, a manual ISO node (with the planned static
# IP, and on DHCP), an Arc-only node, nothing found, several candidates, an override. Everything the run touches is mocked: no network, no Azure,
# no node. Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/NodeAddressRun.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester runs a module mock in the module scope; a global is how the mock reports back to the test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The fake transport keeps the signature of the real one.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $node = Join-Path (Join-Path (Join-Path $repo 'scripts') 'common') 'node-configuration'
    # AzlNodeAddress first, so the run module reuses this instance and Mock -ModuleName AzlNodeAddress reaches the one it calls.
    Import-Module (Join-Path $node 'AzlNodeAddress.psm1') -Force
    Import-Module (Join-Path $node 'AzlOsConfigurationRun.psm1') -Force
    Import-Module powershell-yaml
    $fixtures = Join-Path (Join-Path $repo 'tests') 'fixtures'
    $script:Fixture = Join-Path $fixtures 'infrastructure.fc-san.yml'
    $script:HandoffFixture = Join-Path $fixtures 'handoff.v2.json'

    function Get-TestInfra([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Fixture -Raw) -Ordered
        if ($Change) { & $Change $doc }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        return $file
    }
    function Get-TestHandoffDirectory([string[]]$Nodes = @('iic-n01', 'iic-n02')) {
        $dir = Join-Path $TestDrive "handoffs-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $null = New-Item -ItemType Directory -Path $dir
        foreach ($n in $Nodes) {
            $copy = Get-Content -LiteralPath $script:HandoffFixture -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
            $copy.nodes = @($copy.nodes | Where-Object { $_.name -eq $n })
            $copy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $dir "$n.ztp-handoff.json")
        }
        return $dir
    }
    function global:Get-FakeSetResult($Parameters) {
        $name = $Parameters.Node[0]
        $global:AzlCalls.Add([pscustomobject]@{ Node = $name; Params = $Parameters })
        $global:AzlTrustedHostsDuring = $global:AzlTrustedHosts
        $entry = [pscustomobject]@{
            name = $name; hostname = $name; osVersion = '10.0.26100.1'; converged = $true; restarted = $false; ports = @(); sanDisks = @([pscustomobject]@{ uid = 'UID1' })
            changes = @(); plan = @([pscustomobject]@{ step = 'Dns'; item = 'DNS servers'; current = 'y'; desired = 'y'; action = 'Ok'; note = '' }); wipe = @()
        }
        [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Report = [pscustomobject]@{ nodes = @($entry) } }
    }
    function Reset-Fake {
        $global:AzlCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlAnswering = @()
        $global:AzlArcNone = @()
        $global:AzlArcInterfaces = @{}
        $global:AzlIdentity = @{}
        $global:AzlIdentityRead = [System.Collections.Generic.List[string]]::new()
        $global:AzlNeighbors = @()
        $global:AzlTrustedHostsInitial = ''
        $global:AzlTrustedHostsDuring = $null
        $global:AzlProbed = [System.Collections.Generic.List[string]]::new()
    }
    function Invoke-Run {
        param([string]$Infra, [string[]]$Handoff, [string]$Mode = 'Plan', [hashtable]$Extra = @{})
        $out = Join-Path $TestDrive "out-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $global:AzlTrustedHosts = $global:AzlTrustedHostsInitial
        $store = [pscustomobject]@{ Supported = $true; Get = { $global:AzlTrustedHosts }; Set = { param($Value) $global:AzlTrustedHosts = $Value } }
        $arguments = @{ InfrastructureFile = $Infra; Mode = $Mode; ReportDirectory = $out; SkipValidation = $true; TrustedHostsStore = $store } + $Extra
        if ($Handoff) { $arguments.HandoffPath = $Handoff }
        $warnings = @()
        $result = Invoke-AzlOsConfiguration @arguments 6>$null 3>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings += $_.Message } else { $_ } } | Select-Object -Last 1
        $result | Add-Member -NotePropertyName Out -NotePropertyValue $out -Force
        $result | Add-Member -NotePropertyName Warnings -NotePropertyValue $warnings -Force
        return $result
    }
    function Read-RunEvent([string]$Path) { @(Get-Content -LiteralPath $Path -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
    function Get-Report([object]$Run) { Get-Content -LiteralPath (Join-Path $Run.Out 'report.json') -Raw | ConvertFrom-Json -Depth 20 }
}

Describe 'OS configuration run: the node address is resolved, not passed by hand' {
    BeforeEach {
        Reset-Fake
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlSetNodeConfiguration { Get-FakeSetResult $Parameters }
        Mock -ModuleName AzlOsConfigurationRun Test-AzlAzureSignedIn { $true }
        Mock -ModuleName AzlOsConfigurationRun Test-AzlWinRmPort { $global:AzlProbed.Add($Address); $global:AzlAnswering -contains $Address }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
            foreach ($c in $Candidate) {
                $hit = @($c.Addresses | Where-Object { $_ -in $global:AzlAnswering })
                [pscustomobject]@{ Node = $c.Name; Reachable = ($hit.Count -gt 0); Address = $(if ($hit.Count) { $hit[0] } else { @($c.Addresses)[0] }); Port = 5985; Result = $(if ($hit.Count) { 'Open' } else { 'TimedOut' }); Credential = 'vault'; Diagnosis = 'no answer'; Tried = @($c.Addresses) }
            }
        }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlSecret { 'P@ssw0rd-from-the-vault-not-printed' }
        # The identity read (the first authenticated connection): the machine at an address is the node itself unless the test says it is another machine.
        Mock -ModuleName AzlOsConfigurationRun Get-AzlRunNodeIdentity {
            $global:AzlIdentityRead.Add($Address)
            if ($global:AzlIdentity.ContainsKey($Address)) { $entry = $global:AzlIdentity[$Address]; if ($entry -is [string]) { throw $entry }; return [pscustomobject]@{ ComputerName = $entry.Name; Mac = @($entry.Mac) } }
            $mac = @{ 'iic-n01' = '00:00:5E:00:53:10'; 'iic-n02' = '00:00:5E:00:53:20' }[$Name]
            [pscustomobject]@{ ComputerName = $Name.ToUpperInvariant(); Mac = @($mac, '00:00:5E:00:53:99') }
        }
        Mock -ModuleName AzlOsConfigurationRun Find-AzlArcMachine {
            if ($HostName -in $global:AzlArcNone) { return $null }
            $nics = if ($global:AzlArcInterfaces.ContainsKey($HostName)) { $global:AzlArcInterfaces[$HostName] } else { @() }
            [pscustomobject]@{ Name = $ArcMachineName; ResourceId = "/subscriptions/x/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ArcMachineName"; Location = 'eastus'; Status = 'Connected'; Interfaces = $nics }
        }
        Mock -ModuleName AzlOsConfigurationRun New-AzlWinRmTransport { [pscustomobject]@{ Kind = 'WinRM' } }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript { [pscustomobject]@{ caption = 'Microsoft Azure Stack HCI'; build = 26100; host = 'WIN-X' } }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlArcRegistration { [pscustomobject]@{ Name = $Record.name; Status = 'Connected'; ResourceId = '/x' } }
        # The orchestrator is on the management subnet; the neighbor table is what the test says; the sweep pings nothing.
        Mock -ModuleName AzlNodeAddress Get-AzlLocalIPv4Network { @([pscustomobject]@{ Address = '192.0.2.50'; PrefixLength = 24; Interface = 'Ethernet' }) }
        Mock -ModuleName AzlNodeAddress Get-AzlNeighborEntry { [pscustomobject]@{ Available = $true; Source = 'Get-NetNeighbor'; Entries = @($global:AzlNeighbors | ForEach-Object { [pscustomobject]@{ IPAddress = $_.Ip; Mac = $_.Mac; State = 'Reachable'; Source = 'Get-NetNeighbor' } }) } }
        Mock -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep { 253 }
    }
    AfterAll { foreach ($v in 'AzlIdentity', 'AzlIdentityRead', 'AzlCalls', 'AzlAnswering', 'AzlArcNone', 'AzlArcInterfaces', 'AzlNeighbors', 'AzlTrustedHosts', 'AzlTrustedHostsInitial', 'AzlTrustedHostsDuring', 'AzlProbed') { Remove-Variable -Name $v -Scope Global -ErrorAction SilentlyContinue } }

    It 'ZTP node: the handoff adapter with the management MAC gives the DHCP address; a ZTP node without adapter detail falls back to the file' {
        $global:AzlAnswering = @('192.0.2.11', '192.0.2.120')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        $r.ExitCode | Should -Be 0
        $n1 = $r.Records | Where-Object name -eq 'iic-n01'
        $n2 = $r.Records | Where-Object name -eq 'iic-n02'
        $n2.method | Should -Be 'Ztp'
        $n2.address | Should -Be '192.0.2.120'
        $n2.addressSource | Should -Be 'ztp-handoff'
        $n1.address | Should -Be '192.0.2.11'
        $n1.addressSource | Should -Be 'infrastructure-file'
        ($global:AzlCalls | Where-Object Node -eq 'iic-n02' | Select-Object -First 1).Params.NodeAddress['iic-n02'] | Should -Be '192.0.2.120'
    }
    It 'manual ISO node installed with the planned static IP: no handoff, no Arc, method Iso over WinRM, found on the file''s IP' {
        $global:AzlArcNone = @('iic-n01', 'iic-n02')
        $global:AzlAnswering = @('192.0.2.11', '192.0.2.12')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra
        $r.ExitCode | Should -Be 0
        foreach ($rec in $r.Records) {
            $rec.method | Should -Be 'Iso'
            $rec.transport | Should -Be 'WinRM'
            $rec.addressSource | Should -Be 'infrastructure-file'
            $rec.evidence.HandoffPresent | Should -BeFalse
        }
        $report = Get-Report $r
        $report.nodes[0].evidence.handoff.present | Should -BeFalse
        $report.nodes[0].address | Should -Be '192.0.2.11'
        $report.nodes[0].addressSource | Should -Be 'infrastructure-file'
        # Arc registration of the unregistered machine is part of the ISO plan, not an error.
        ($r.Records[0].plan | Where-Object Step -eq 'ArcRegistration').Action | Should -Be 'Change'
    }
    It 'manual ISO node on DHCP: the address is found by its MAC in the neighbor table' {
        $global:AzlArcNone = @('iic-n01', 'iic-n02')
        $global:AzlNeighbors = @(@{ Ip = '192.0.2.121'; Mac = '00005e005310' }, @{ Ip = '192.0.2.120'; Mac = '00005e005320' })
        $global:AzlAnswering = @('192.0.2.120', '192.0.2.121')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra
        $r.ExitCode | Should -Be 0
        ($r.Records | Where-Object name -eq 'iic-n01').address | Should -Be '192.0.2.121'
        ($r.Records | Where-Object name -eq 'iic-n02').address | Should -Be '192.0.2.120'
        ($r.Records | ForEach-Object addressSource | Select-Object -Unique) | Should -Be 'mac-lookup'
        $call = $global:AzlCalls | Where-Object Node -eq 'iic-n02' | Select-Object -First 1
        $call.Params.NodeAddress['iic-n02'] | Should -Be '192.0.2.120'
        $call.Params.Credential | Should -BeOfType [pscredential]
    }
    It 'Arc-only node: the address its Arc agent reports for the management MAC' {
        $global:AzlArcInterfaces = @{ 'iic-n02' = @([pscustomobject]@{ name = 'Port0'; macAddress = '00:00:5E:00:53:20'; ipAddresses = @('192.0.2.77') }) }
        $global:AzlAnswering = @('192.0.2.77')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra -Extra @{ Node = @('iic-n02') }
        $r.ExitCode | Should -Be 0
        $r.Records[0].address | Should -Be '192.0.2.77'
        $r.Records[0].addressSource | Should -Be 'arc'
    }
    It 'manual ISO node, Arc chosen as the transport: no handoff and no address are needed, nothing is probed' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra -Extra @{ Transport = 'ArcRunCommand' }
        $r.ExitCode | Should -Be 0
        ($r.Records | ForEach-Object transport | Select-Object -Unique) | Should -Be 'ArcRunCommand'
        ($r.Records | ForEach-Object method | Select-Object -Unique) | Should -Be 'Iso'
        $global:AzlProbed.Count | Should -Be 0
    }
    It 'nothing found: exit 2, the message names everything that was tried and asks for the address, nothing was changed' {
        $global:AzlArcNone = @('iic-n01', 'iic-n02')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra -Extra @{ Node = @('iic-n02') }
        $r.ExitCode | Should -Be 2
        foreach ($text in 'Cannot find the current management address of iic-n02', '1\. override: none given', '2\. ZTP handoff: no handoff for this node', '3\. Arc machine: none found', '4\. infrastructure file: 192\.0\.2\.12', '5\. MAC lookup', "-NodeAddress @\{ 'iic-n02' = '<ip>' \}") {
            $r.Message | Should -Match $text
        }
        $global:AzlCalls.Count | Should -Be 0
        $r.Message | Should -Not -Match 'P@ssw0rd'
    }
    It 'nothing answers although the Arc machine exists: exit 2 with the same account of what was tried' {
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra -Extra @{ Node = @('iic-n02') }
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'Cannot find the current management address of iic-n02'
        $r.Message | Should -Match '5\. MAC lookup'
        $global:AzlCalls.Count | Should -Be 0
    }
    It 'several candidates answer: the most trusted source is used (the file over a handoff-only address) and a warning says which and why' {
        $global:AzlAnswering = @('192.0.2.11', '192.0.2.12', '192.0.2.120')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Node = @('iic-n02') }
        $r.ExitCode | Should -Be 0
        $r.Records[0].address | Should -Be '192.0.2.12'
        $r.Records[0].addressSource | Should -Be 'infrastructure-file'
        ($r.Warnings -join "`n") | Should -Match 'Several addresses answer for iic-n02'
        ($r.Warnings -join "`n") | Should -Match 'order of trust'
    }
    It 'the lab case: the handoff address is stale and answers as another node; Arc (Connected) and the file say .12: the run uses .12, never sends the credential to the stale address, and says who disagreed' {
        $global:AzlArcInterfaces = @{ 'iic-n02' = @([pscustomobject]@{ name = 'Port0'; macAddress = '00:00:5E:00:53:20'; ipAddresses = @('192.0.2.12') }) }
        $global:AzlAnswering = @('192.0.2.12', '192.0.2.120')
        $global:AzlIdentity = @{ '192.0.2.120' = @{ Name = 'IIC-N03'; Mac = @('00:00:5E:00:53:30') } }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Node = @('iic-n02') }
        $r.ExitCode | Should -Be 0
        $r.Records[0].address | Should -Be '192.0.2.12'
        $r.Records[0].addressSource | Should -Be 'arc'
        @($global:AzlIdentityRead | Select-Object -Unique) | Should -Be @('192.0.2.12')
        ($global:AzlCalls | Select-Object -First 1).Params.NodeAddress['iic-n02'] | Should -Be '192.0.2.12'
        ($r.Warnings -join "`n") | Should -Match 'sources disagree'
        $events = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $t = $events | Where-Object { $_.node -eq 'iic-n02' -and $_.state -eq 'TransportResolved' } | Select-Object -Last 1
        $t.evidence | Should -Match 'ZTP handoff says 192\.0\.2\.120; Arc machine says 192\.0\.2\.12 \(Connected\); infrastructure file says 192\.0\.2\.12 \(they disagree\)'
        $t.addressSourcesAgree | Should -BeFalse
        $address = (Get-Report $r).nodes[0].evidence.address
        $address.sourcesAgree | Should -BeFalse
        $address.agreement | Should -Match 'ZTP handoff says 192\.0\.2\.120'
        $address.identityChecked | Should -BeTrue
    }
    It 'the first address that answers is another machine: it is dropped (warning, event, report) and the next candidate that proves to be the node is used' {
        $global:AzlAnswering = @('192.0.2.12', '192.0.2.120')
        $global:AzlIdentity = @{ '192.0.2.12' = @{ Name = 'IIC-N03'; Mac = @('00:00:5E:00:53:30') } }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Node = @('iic-n02') }
        $r.ExitCode | Should -Be 0
        $r.Records[0].address | Should -Be '192.0.2.120'
        $r.Records[0].addressSource | Should -Be 'ztp-handoff'
        ($r.Warnings -join "`n") | Should -Match 'address 192\.0\.2\.12 answered but is IIC-N03/00:00:5E:00:53:30, not iic-n02 \(management MAC 00:00:5E:00:53:20\)'
        $events = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $drop = $events | Where-Object { $_.node -eq 'iic-n02' -and $_.state -eq 'TransportResolved' -and $_.level -eq 'Warning' } | Select-Object -First 1
        $drop.evidence | Should -Match 'answered but is IIC-N03'
        @((Get-Report $r).nodes[0].evidence.address.dropped).Count | Should -Be 1
    }
    It 'only the handoff address answers and it is another machine: exit 2, the message names what answered where, nothing is changed' {
        $global:AzlArcNone = @('iic-n01', 'iic-n02')
        $global:AzlAnswering = @('192.0.2.120')
        $global:AzlIdentity = @{ '192.0.2.120' = @{ Name = 'IIC-N03'; Mac = @('00:00:5E:00:53:30', '00:00:5E:00:53:31') } }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Node = @('iic-n02') }
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'No address proved to be iic-n02'
        $r.Message | Should -Match 'address 192\.0\.2\.120 answered but is IIC-N03/00:00:5E:00:53:30,00:00:5E:00:53:31, not iic-n02'
        $r.Message | Should -Match 'found by ztp-handoff'
        $r.Message | Should -Match '-NodeAddress'
        $global:AzlCalls.Count | Should -Be 0
    }
    It 'an override that points at another machine stops the run (exit 2) with a clear message instead of changing it' {
        $global:AzlAnswering = @('192.0.2.200', '192.0.2.12')
        $global:AzlIdentity = @{ '192.0.2.200' = @{ Name = 'IIC-N01'; Mac = @('00:00:5E:00:53:10') } }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra -Extra @{ Node = @('iic-n02'); NodeAddress = @{ 'iic-n02' = '192.0.2.200' } }
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'The address you gave for iic-n02 does not belong to it'
        $r.Message | Should -Match 'answered but is IIC-N01/00:00:5E:00:53:10, not iic-n02'
        @($global:AzlIdentityRead | Select-Object -Unique) | Should -Be @('192.0.2.200')
        $global:AzlCalls.Count | Should -Be 0
    }
    It 'addressResolution.verifyIdentity false switches the identity read off (and the report says it was not checked)' {
        $global:AzlAnswering = @('192.0.2.12')
        $global:AzlIdentity = @{ '192.0.2.12' = @{ Name = 'IIC-N03'; Mac = @('00:00:5E:00:53:30') } }
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra -Extra @{ Node = @('iic-n02'); Settings = @{ addressResolution = @{ verifyIdentity = $false } } }
        $r.ExitCode | Should -Be 0
        $global:AzlIdentityRead.Count | Should -Be 0
        (Get-Report $r).nodes[0].evidence.address.identityChecked | Should -BeFalse
    }
    It 'override wins: -NodeAddress is used and no other source is probed' {
        $global:AzlAnswering = @('192.0.2.200', '192.0.2.120', '192.0.2.12')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory) -Extra @{ Node = @('iic-n02'); NodeAddress = @{ 'iic-n02' = '192.0.2.200' } }
        $r.ExitCode | Should -Be 0
        $r.Records[0].address | Should -Be '192.0.2.200'
        $r.Records[0].addressSource | Should -Be 'override'
        @($global:AzlProbed | Select-Object -Unique) | Should -Be @('192.0.2.200')
    }
    It 'override wins when it comes from the nodeAddress run setting' {
        $global:AzlAnswering = @('192.0.2.200', '192.0.2.12')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra -Extra @{ Node = @('iic-n02'); Settings = @{ nodeAddress = @{ 'iic-n02' = '192.0.2.200' } } }
        $r.Records[0].addressSource | Should -Be 'override'
        $r.Records[0].address | Should -Be '192.0.2.200'
    }
    It 'the run settings accept addressResolution and pass it on; an unknown key is still refused' {
        $global:AzlAnswering = @('192.0.2.12')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso' }
        $r = Invoke-Run -Infra $infra -Extra @{ Node = @('iic-n02'); Settings = @{ addressResolution = @{ sweep = $false; allowWideSubnet = $false } } }
        $r.ExitCode | Should -Be 0
        (Invoke-Run -Infra $infra -Extra @{ Settings = @{ addressResolutoin = @{} } }).ExitCode | Should -Be 2
    }
    It 'TransportResolved names the address source; the report and the plan line do too' {
        $global:AzlAnswering = @('192.0.2.11', '192.0.2.120')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'simplified' }
        $r = Invoke-Run -Infra $infra -Handoff (Get-TestHandoffDirectory)
        $events = Read-RunEvent (Join-Path $r.Out 'os-configuration-events.jsonl')
        $t = $events | Where-Object { $_.node -eq 'iic-n02' -and $_.state -eq 'TransportResolved' } | Select-Object -First 1
        $t.addressSource | Should -Be 'ztp-handoff'
        $t.address | Should -Be '192.0.2.120'
        $t.evidence | Should -Match 'ztp-handoff'
        @($t.addressTried).Count | Should -BeGreaterThan 2
        (Get-Report $r).nodes[1].addressSource | Should -Be 'ztp-handoff'
    }
    It 'TrustedHosts (exact) covers a discovered DHCP address while the node is handled, and is restored afterwards' {
        $global:AzlTrustedHostsInitial = 'prior.example.invalid'
        $global:AzlArcNone = @('iic-n01', 'iic-n02')
        $global:AzlNeighbors = @(@{ Ip = '192.0.2.121'; Mac = '00005e005310' }, @{ Ip = '192.0.2.120'; Mac = '00005e005320' })
        $global:AzlAnswering = @('192.0.2.120', '192.0.2.121')
        $infra = Get-TestInfra { param($d) $d.scenario.os_install = 'iso'; $d.scenario.environment_class = 'dev' }
        $r = Invoke-Run -Infra $infra
        $r.ExitCode | Should -Be 0
        $global:AzlTrustedHostsDuring | Should -Match '192\.0\.2\.120'
        $global:AzlTrustedHostsDuring | Should -Match '192\.0\.2\.121'
        $global:AzlTrustedHostsDuring | Should -Match 'prior\.example\.invalid'
        $global:AzlTrustedHosts | Should -Be 'prior.example.invalid'
    }
}

Describe 'The identity read of the run (the first authenticated connection to an address)' {
    AfterAll { foreach ($v in 'AzlOrder', 'AzlFakeTransport', 'AzlRunContext') { Remove-Variable -Name $v -Scope Global -ErrorAction SilentlyContinue } }
    It 'puts a found address into TrustedHosts first, reads the computer name and MACs through the transport, and closes the session' {
        $global:AzlOrder = [System.Collections.Generic.List[string]]::new()
        $bytes = [Text.Encoding]::UTF8.GetBytes((([pscustomobject]@{ v = 1; host = 'IIC-N02'; macs = @('00:00:5E:00:53:20') }) | ConvertTo-Json -Compress))
        $ms = [IO.MemoryStream]::new(); $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress); $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        $line = 'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
        $global:AzlFakeTransport = [pscustomobject]@{
            Kind         = 'WinRM'
            Invoke       = { param($Self, $Node, $Script, $Parameters, $Secrets, $TimeoutSeconds) $global:AzlOrder.Add('session'); [pscustomobject]@{ Output = $line; Failed = $false; Error = ''; State = 'Succeeded' } }.GetNewClosure()
            CloseSession = { param($Self, $Node) $global:AzlOrder.Add("closed:$Node") }
        }
        Mock -ModuleName AzlOsConfigurationRun New-AzlWinRmTransport { $global:AzlOrder.Add("transport:$($Address['iic-n02'])"); $global:AzlFakeTransport }
        Mock -ModuleName AzlOsConfigurationRun Set-AzlTrustedHostsPolicy { $global:AzlOrder.Add("trusted:$(@($Address) -join ',')"); [pscustomobject]@{ Changed = $true; Previous = 'changed' } }
        $secure = [System.Security.SecureString]::new(); $secure.AppendChar([char]'x')
        $global:AzlRunContext = [pscustomobject]@{
            CredentialInfo = [pscustomobject]@{ Credential = [pscredential]::new('azl-admin', $secure) }
            TrustedHosts = [pscustomobject]@{ Previous = 'prior.example.invalid'; Changed = $true }
            TrustedHostsState = @{ Profile = [pscustomobject]@{}; Store = [pscustomobject]@{}; Addresses = @('192.0.2.11') }
        }
        $id = InModuleScope AzlOsConfigurationRun { Get-AzlRunNodeIdentity -Context $global:AzlRunContext -Name 'iic-n02' -Address '192.0.2.120' -UseSsl $false }
        $id.ComputerName | Should -Be 'IIC-N02'
        $id.Mac | Should -Be @('00005e005320')
        @($global:AzlOrder) | Should -Be @('trusted:192.0.2.11,192.0.2.120', 'transport:192.0.2.120', 'session', 'closed:iic-n02')
        $global:AzlRunContext.TrustedHosts.Previous | Should -Be 'prior.example.invalid'
        $global:AzlRunContext.TrustedHostsState.Addresses | Should -Contain '192.0.2.120'
    }
}

Describe 'Set-AzureLocalNodeConfiguration.ps1 (standalone) uses the same resolution' {
    It 'imports AzlNodeAddress, resolves with the handoff entry and the Arc machine, and needs no handoff file' {
        $script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Set-AzureLocalNodeConfiguration.ps1')
        $text = Get-Content -LiteralPath $script -Raw
        $text | Should -Match "AzlNodeAddress\.psm1"
        $text | Should -Match 'Resolve-AzlNodeAddress -Infrastructure \$infra -Node \$nodeObject -Override \$override -HandoffEntry \(Get-AzlHandoffNode -Handoff \$handoff'
        # The handoff stays optional: read only when a file is given, and every user of it is null-safe.
        $text | Should -Match 'if \(\$HandoffFile\) \{ Read-AzlHandoff'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $handoffParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'HandoffFile' }
        @($handoffParameter.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' -and ($_.NamedArguments | Where-Object ArgumentName -eq 'Mandatory') }).Count | Should -Be 0
    }
}
