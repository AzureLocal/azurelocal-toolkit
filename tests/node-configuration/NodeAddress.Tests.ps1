#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the automatic resolution of a node's CURRENT management address (AzlNodeAddress.psm1). Nothing here touches the network:
# the port probe, the neighbor table, the local interfaces and the ping sweep are all faked.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/NodeAddress.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $common = Join-Path (Join-Path $repo 'scripts') 'common'
    Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodeAddress.psm1') -Force
    $fixtures = Join-Path (Join-Path $repo 'tests') 'fixtures'
    $script:Infra = Import-AzlInfrastructure -Path (Join-Path $fixtures 'infrastructure.fc-san.yml') -SkipValidation
    $script:N01 = $script:Infra.nodes[0]   # management MAC 00:00:5E:00:53:10, planned 192.0.2.11
    $script:N02 = $script:Infra.nodes[1]   # management MAC 00:00:5E:00:53:20, planned 192.0.2.12
    $handoff = Read-AzlHandoff -Path (Join-Path $fixtures 'handoff.v2.json')
    $script:Handoff02 = Get-AzlHandoffNode -Handoff $handoff -Name 'iic-n02'   # adapter Port0, same MAC, DHCP 192.0.2.120
    $script:Handoff01 = Get-AzlHandoffNode -Handoff $handoff -Name 'iic-n01'   # no networkAdapters
    $script:ArpDirectory = Join-Path $fixtures 'address'

    # The addresses that answer on a port: 'ip' answers on 5985; 'ip:5986' on 5986 only. Records every probe.
    function Get-FakeProbe([string[]]$Answers) {
        $set = @{}
        foreach ($a in $Answers) { $set[$a] = $true }
        $log = [System.Collections.Generic.List[string]]::new()
        $block = {
            param($a, $p)
            $log.Add("${a}:$p")
            $set.ContainsKey("${a}:$p") -or ($p -eq 5985 -and $set.ContainsKey($a))
        }.GetNewClosure()
        [pscustomobject]@{ Block = $block; Log = $log }
    }
    function Get-FakeArc([string]$Mac, [string[]]$Ip, [string]$Status = 'Connected') {
        [pscustomobject]@{ Name = 'iic-n02'; ResourceId = '/x'; Status = $Status; Interfaces = @([pscustomobject]@{ name = 'Port0'; macAddress = $Mac; ipAddresses = $Ip }, [pscustomobject]@{ name = 'Port2'; macAddress = '00:00:5E:00:53:22'; ipAddresses = @('198.51.100.40') }) }
    }
    function Get-FakeNeighbor([hashtable[]]$Row) {
        [pscustomobject]@{ Available = $true; Source = 'Get-NetNeighbor'; Entries = @($Row | ForEach-Object { [pscustomobject]@{ IPAddress = $_.Ip; Mac = $_.Mac; State = 'Reachable'; Source = 'Get-NetNeighbor' } }) }
    }
}

Describe 'Address helpers' {
    It 'normalizes a MAC in every notation, including macOS unpadded octets' {
        ConvertTo-AzlAddressMacKey '00:00:5E:00:53:20' | Should -Be '00005e005320'
        ConvertTo-AzlAddressMacKey '00-00-5e-00-53-20' | Should -Be '00005e005320'
        ConvertTo-AzlAddressMacKey '0:0:5e:0:53:20' | Should -Be '00005e005320'
        ConvertTo-AzlAddressMacKey '0000.5e00.5320' | Should -Be '00005e005320'
        ConvertTo-AzlAddressMacKey 'nonsense' | Should -BeNullOrEmpty
        ConvertTo-AzlAddressMacKey '' | Should -BeNullOrEmpty
    }
    It 'parses a CIDR into its host range' {
        $s = ConvertFrom-AzlCidr '192.0.2.0/24'
        $s.Count | Should -Be 254
        $s.Prefix | Should -Be 24
        (ConvertFrom-AzlCidr '192.0.2.77/22').Text | Should -Be '192.0.0.0/22'
        (ConvertFrom-AzlCidr '192.0.2.0/22').Count | Should -Be 1022
        (ConvertFrom-AzlCidr '192.0.2.5/32').Count | Should -Be 1
        ConvertFrom-AzlCidr '192.0.2.0/33' | Should -BeNullOrEmpty
        ConvertFrom-AzlCidr 'not a cidr' | Should -BeNullOrEmpty
        ConvertFrom-AzlCidr '300.0.2.0/24' | Should -BeNullOrEmpty
    }
    It 'knows which address is in a subnet' {
        $s = ConvertFrom-AzlCidr '192.0.2.0/24'
        Test-AzlAddressInCidr -Address '192.0.2.200' -Subnet $s | Should -BeTrue
        Test-AzlAddressInCidr -Address '192.0.3.1' -Subnet $s | Should -BeFalse
        Test-AzlAddressInCidr -Address 'host' -Subnet $s | Should -BeFalse
    }
    It 'parses arp -a from Windows' {
        $rows = @(ConvertFrom-AzlArpOutput -Line (Get-Content -LiteralPath (Join-Path $script:ArpDirectory 'arp-a.windows.txt')))
        ($rows | Where-Object IPAddress -eq '192.0.2.120').Mac | Should -Be '00005e005320'
        $rows.Count | Should -Be 5
    }
    It 'parses arp -a from Linux and leaves incomplete entries out' {
        $rows = @(ConvertFrom-AzlArpOutput -Line (Get-Content -LiteralPath (Join-Path $script:ArpDirectory 'arp-a.linux.txt')))
        $rows.Count | Should -Be 2
        ($rows | Where-Object IPAddress -eq '192.0.2.120').Mac | Should -Be '00005e005320'
    }
    It 'parses arp -a from macOS with unpadded octets' {
        $rows = @(ConvertFrom-AzlArpOutput -Line (Get-Content -LiteralPath (Join-Path $script:ArpDirectory 'arp-a.macos.txt')))
        ($rows | Where-Object IPAddress -eq '192.0.2.120').Mac | Should -Be '00005e005320'
        ($rows | Where-Object IPAddress -eq '192.0.2.1').Mac | Should -Be '00005e005301'
    }
    It 'the sweep seam stays inside the subnet it is given and counts what it pinged' {
        Invoke-AzlSubnetSweep -Subnet (ConvertFrom-AzlCidr '127.0.0.1/32') -TimeoutMilliseconds 200 | Should -Be 1
        Invoke-AzlSubnetSweep -Subnet (ConvertFrom-AzlCidr '127.0.0.0/30') -Exclude @('127.0.0.1') -TimeoutMilliseconds 200 | Should -Be 1
    }
}

Describe 'Resolving a node''s current management address' {
    BeforeEach {
        # By default this machine is on the management subnet, the neighbor table is empty and the sweep does nothing.
        Mock -ModuleName AzlNodeAddress Get-AzlLocalIPv4Network { @([pscustomobject]@{ Address = '192.0.2.50'; PrefixLength = 24; Interface = 'Ethernet' }) }
        Mock -ModuleName AzlNodeAddress Get-AzlNeighborEntry { Get-FakeNeighbor @() }
        Mock -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep { 253 }
        Mock -ModuleName AzlNodeAddress Test-AzlAddressPort { $false }
    }

    It 'ZTP node: the handoff adapter with the management MAC gives the DHCP address it holds' {
        $probe = Get-FakeProbe @('192.0.2.120')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -HandoffEntry $script:Handoff02 -PortTest $probe.Block
        $r.Address | Should -Be '192.0.2.120'
        $r.Source | Should -Be 'ztp-handoff'
        $r.Answered | Should -BeTrue
        $r.Port | Should -Be 5985
        $r.Message | Should -Match 'ztp-handoff'
        Should -Invoke -ModuleName AzlNodeAddress Get-AzlNeighborEntry -Times 0 -Exactly
        Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 0 -Exactly
    }
    It 'ZTP node whose handoff has no adapter detail falls through to the file address' {
        $probe = Get-FakeProbe @('192.0.2.11')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N01 -HandoffEntry $script:Handoff01 -PortTest $probe.Block
        $r.Source | Should -Be 'infrastructure-file'
        ($r.Tried -join "`n") | Should -Match 'no adapter with MAC'
    }
    It 'manual ISO node installed with the planned static IP answers on the file''s IP: no handoff, no Arc, no lookup' {
        $probe = Get-FakeProbe @('192.0.2.11')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N01 -PortTest $probe.Block
        $r.Address | Should -Be '192.0.2.11'
        $r.Source | Should -Be 'infrastructure-file'
        ($r.Tried -join "`n") | Should -Match '2\. ZTP handoff: no handoff for this node'
        ($r.Tried -join "`n") | Should -Match '5\. MAC lookup: not needed'
        Should -Invoke -ModuleName AzlNodeAddress Get-AzlNeighborEntry -Times 0 -Exactly
        Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 0 -Exactly
    }
    It 'manual ISO node on DHCP: found by its MAC in the neighbor table the orchestrator already has' {
        Mock -ModuleName AzlNodeAddress Get-AzlNeighborEntry { Get-FakeNeighbor @(@{ Ip = '192.0.2.1'; Mac = '00005e005301' }, @{ Ip = '192.0.2.120'; Mac = '00005e005320' }, @{ Ip = '203.0.113.9'; Mac = '00005e005320' }) }
        $probe = Get-FakeProbe @('192.0.2.120')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -PortTest $probe.Block
        $r.Address | Should -Be '192.0.2.120'
        $r.Source | Should -Be 'mac-lookup'
        $r.Layer2 | Should -BeTrue
        @($r.Candidates | Where-Object Source -eq 'mac-lookup').Count | Should -Be 1 # 203.0.113.9 is outside the management subnet: not used
        Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 0 -Exactly
    }
    It 'manual ISO node on DHCP: an empty neighbor table is filled by a bounded ping sweep of the file''s subnet, then matched' {
        $script:Calls = 0
        Mock -ModuleName AzlNodeAddress Get-AzlNeighborEntry { $script:Calls++; if ($script:Calls -ge 2) { Get-FakeNeighbor @(@{ Ip = '192.0.2.120'; Mac = '00005e005320' }) } else { Get-FakeNeighbor @() } }
        $probe = Get-FakeProbe @('192.0.2.120')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -PortTest $probe.Block
        $r.Source | Should -Be 'mac-lookup'
        $r.Address | Should -Be '192.0.2.120'
        ($r.Tried -join "`n") | Should -Match 'ping sweep of 192\.0\.2\.0/24'
        Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 1 -Exactly -ParameterFilter { $Subnet.Text -eq '192.0.2.0/24' -and '192.0.2.50' -in $Exclude }
    }
    It 'sends nothing to the node but TCP connects: the probes are the only calls' {
        $probe = Get-FakeProbe @()
        $null = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -HandoffEntry $script:Handoff02 -PortTest $probe.Block
        @($probe.Log | ForEach-Object { ($_ -split ':')[1] } | Select-Object -Unique | Sort-Object) | Should -Be @('5985', '5986')
    }
    It 'Arc-only node: the address its Arc agent reports for the management MAC' {
        $probe = Get-FakeProbe @('192.0.2.77')
        $arc = Get-FakeArc -Mac '00:00:5E:00:53:20' -Ip @('192.0.2.77', '169.254.10.10', 'fe80::1')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -ArcMachine $arc -PortTest $probe.Block
        $r.Address | Should -Be '192.0.2.77'
        $r.Source | Should -Be 'arc'
        @($r.Candidates.Address) | Should -Not -Contain '169.254.10.10'
        @($r.Candidates.Address) | Should -Not -Contain '198.51.100.40' # the storage NIC is not the management port
    }
    It 'an Arc NIC that reports another MAC is not used' {
        $probe = Get-FakeProbe @('192.0.2.77')
        $arc = Get-FakeArc -Mac '00:00:5E:00:53:99' -Ip @('192.0.2.77')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -ArcMachine $arc -PortTest $probe.Block
        $r.Source | Should -Be 'none'
    }
    It 'nothing found: Address is empty, the message names every source tried and asks for the address' {
        $probe = Get-FakeProbe @()
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -PortTest $probe.Block
        $r.Address | Should -BeNullOrEmpty
        $r.Source | Should -Be 'none'
        $r.Answered | Should -BeFalse
        foreach ($text in '1\. override: none given', '2\. ZTP handoff', '3\. Arc machine', '4\. infrastructure file: 192\.0\.2\.12', '5\. MAC lookup', 'Cannot find the current management address of iic-n02', "-NodeAddress @\{ 'iic-n02' = '<ip>' \}", 'Nothing was changed') {
            $r.Message | Should -Match $text
        }
    }
    It 'nothing found on a machine that is not on the management subnet: says it does not share the layer-2 segment, and does not sweep' {
        Mock -ModuleName AzlNodeAddress Get-AzlLocalIPv4Network { @([pscustomobject]@{ Address = '198.18.0.5'; PrefixLength = 24; Interface = 'Ethernet' }) }
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -PortTest (Get-FakeProbe @()).Block
        $r.Layer2 | Should -BeFalse
        $r.Message | Should -Match 'does not share the layer-2 segment'
        $r.Message | Should -Match '198\.18\.0\.5'
        Should -Invoke -ModuleName AzlNodeAddress Get-AzlNeighborEntry -Times 0 -Exactly
        Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 0 -Exactly
    }
    It 'a platform with neither Get-NetNeighbor nor arp skips the lookup gracefully' {
        Mock -ModuleName AzlNodeAddress Get-AzlNeighborEntry { [pscustomobject]@{ Available = $false; Source = ''; Entries = @() } }
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -PortTest (Get-FakeProbe @()).Block
        $r.Source | Should -Be 'none'
        $r.Message | Should -Match 'neither Get-NetNeighbor nor arp is available'
        Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 0 -Exactly
    }
    It 'several candidates answer: the most trusted source wins (the file over a handoff-only address) and the message says which and why' {
        $probe = Get-FakeProbe @('192.0.2.120', '192.0.2.12')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -HandoffEntry $script:Handoff02 -PortTest $probe.Block
        $r.Address | Should -Be '192.0.2.12'
        $r.Source | Should -Be 'infrastructure-file'
        @($r.Candidates | Where-Object Answers).Count | Should -Be 2
        $r.Notes[0] | Should -Match 'Several addresses answer'
        $r.Notes[0] | Should -Match '192\.0\.2\.120 \(ztp-handoff\)'
        $r.Notes[0] | Should -Match 'order of trust'
        ($r.Notes -join ' ') | Should -Match 'sources disagree'
        ($r.Notes -join ' ') | Should -Match 'ZTP handoff is historic data'
    }
    It 'a candidate that answers is preferred over an earlier source that does not' {
        $probe = Get-FakeProbe @('192.0.2.12')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -HandoffEntry $script:Handoff02 -PortTest $probe.Block
        $r.Address | Should -Be '192.0.2.12'
        $r.Source | Should -Be 'infrastructure-file'
        $r.Candidates[0].Address | Should -Be '192.0.2.12'
    }
    It 'HTTPS-only: a node that answers on 5986 only is found, with the port' {
        $probe = Get-FakeProbe @('192.0.2.11:5986')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N01 -PortTest $probe.Block
        $r.Address | Should -Be '192.0.2.11'
        $r.Port | Should -Be 5986
    }
    It 'override wins and is the only address tried' {
        $probe = Get-FakeProbe @('192.0.2.200', '192.0.2.120', '192.0.2.12')
        $arc = Get-FakeArc -Mac '00:00:5E:00:53:20' -Ip @('192.0.2.77')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -Override '192.0.2.200' -HandoffEntry $script:Handoff02 -ArcMachine $arc -PortTest $probe.Block
        $r.Address | Should -Be '192.0.2.200'
        $r.Source | Should -Be 'override'
        @($probe.Log | ForEach-Object { ($_ -split ':')[0] } | Select-Object -Unique) | Should -Be @('192.0.2.200')
        @($r.Candidates).Count | Should -Be 1
    }
    It 'an override that does not answer is still the address: credentials never go to an address the operator did not give' {
        $probe = Get-FakeProbe @('192.0.2.120')
        $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -Override '192.0.2.200' -HandoffEntry $script:Handoff02 -PortTest $probe.Block
        $r.Address | Should -Be '192.0.2.200'
        $r.Source | Should -Be 'override'
        $r.Answered | Should -BeFalse
        $r.Message | Should -Match 'No other source was tried'
        $probe.Log | Should -Not -Contain '192.0.2.120:5985'
    }
    It 'an override may be a host name' {
        $probe = Get-FakeProbe @('azl-n02.example.test')
        (Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -Override 'azl-n02.example.test' -PortTest $probe.Block).Answered | Should -BeTrue
    }

    Context 'the sweep is bounded' {
        BeforeEach {
            $script:Wide = [ordered]@{} + $script:Infra
            $script:Wide['networking'] = [ordered]@{ management = [ordered]@{ subnet = '192.0.0.0/16' } }
            Mock -ModuleName AzlNodeAddress Get-AzlLocalIPv4Network { @([pscustomobject]@{ Address = '192.0.2.50'; PrefixLength = 16; Interface = 'Ethernet' }) }
        }
        It 'refuses a subnet wider than /22 and names the setting that allows it' {
            $r = Resolve-AzlNodeAddress -Infrastructure $script:Wide -Node $script:N02 -PortTest (Get-FakeProbe @()).Block
            Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 0 -Exactly
            $r.Message | Should -Match 'wider than /22'
            $r.Message | Should -Match 'addressResolution\.allowWideSubnet'
        }
        It 'sweeps it when the override is given' {
            $null = Resolve-AzlNodeAddress -Infrastructure $script:Wide -Node $script:N02 -PortTest (Get-FakeProbe @()).Block -Setting @{ allowWideSubnet = $true }
            Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 1 -Exactly -ParameterFilter { $Subnet.Prefix -eq 16 }
        }
        It 'a /22 is allowed without the override' {
            $wide = [ordered]@{} + $script:Infra
            $wide['networking'] = [ordered]@{ management = [ordered]@{ subnet = '192.0.0.0/22' } }
            $null = Resolve-AzlNodeAddress -Infrastructure $wide -Node $script:N02 -PortTest (Get-FakeProbe @()).Block
            Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 1 -Exactly
        }
        It 'addressResolution.sweep false reads the table but never pings' {
            $r = Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N02 -PortTest (Get-FakeProbe @()).Block -Setting @{ sweep = $false }
            Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 0 -Exactly
            Should -Invoke -ModuleName AzlNodeAddress Get-AzlNeighborEntry -Times 1 -Exactly
            $r.Message | Should -Match 'sweep switched off'
        }
        It 'no subnet in the file: the lookup is skipped and says so' {
            $none = [ordered]@{} + $script:Infra
            $none['networking'] = [ordered]@{ management = [ordered]@{} }
            $r = Resolve-AzlNodeAddress -Infrastructure $none -Node $script:N02 -PortTest (Get-FakeProbe @()).Block
            $r.Message | Should -Match 'networking\.management\.subnet in the file is not set'
            Should -Invoke -ModuleName AzlNodeAddress Invoke-AzlSubnetSweep -Times 0 -Exactly
        }
    }
}
