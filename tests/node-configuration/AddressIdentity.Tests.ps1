#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The node address is not only found, it is proven: live evidence ranks above the historic ZTP handoff, and the machine that answers must be the node
# (computer name and adapter MACs against the file) before anything is sent to it. The lab case that started this: node n01 was resolved to
# the handoff's DHCP address, which had become node 3's lease; Arc (Connected) and the file both said the right address. Nothing here touches the
# network or a node: the port probe is faked and the identity read goes through a fake transport.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/AddressIdentity.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transports and readers keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory objects.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $common = Join-Path (Join-Path $repo 'scripts') 'common'
    Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodeAddress.psm1') -Force
    $fixtures = Join-Path (Join-Path $repo 'tests') 'fixtures'
    $script:Infra = Import-AzlInfrastructure -Path (Join-Path $fixtures 'infrastructure.fc-san.yml') -SkipValidation
    $script:N01 = $script:Infra.nodes[0]   # iic-n01, management MAC 00:00:5E:00:53:10, file address 192.0.2.11
    $script:Expected = Get-AzlNodeExpectedIdentity -Infrastructure $script:Infra -Node $script:N01

    # 192.0.2.11 is the node (file, Arc); 192.0.2.117 was its DHCP address in the handoff and is another machine's now.
    $script:Mac01 = '00:00:5E:00:53:10'
    $script:Mac03 = '00:00:5E:00:53:30'

    function Get-FakeProbe([string[]]$Answers) {
        $set = @{}
        foreach ($a in $Answers) { $set[$a] = $true }
        { param($a, $p) $p -eq 5985 -and $set.ContainsKey($a) }.GetNewClosure()
    }
    function Get-Handoff([string]$Ip) {
        [pscustomobject]@{ name = 'iic-n01'; networkAdapters = @([pscustomobject]@{ name = 'Port1'; macAddress = $script:Mac01; ipAddress = $Ip; ipAssignment = 'Dhcp' }) }
    }
    function Get-Arc([string]$Ip, [string]$Status = 'Connected') {
        [pscustomobject]@{ Name = 'iic-n01'; ResourceId = '/x'; Status = $Status; Interfaces = @([pscustomobject]@{ name = 'Port0'; macAddress = $script:Mac01; ipAddresses = @($Ip) }) }
    }
    function Resolve-Node([string[]]$Answer, [object]$Handoff, [object]$Arc, [string]$Override = '', [hashtable]$Node = $script:N01) {
        Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $Node -Override $Override -HandoffEntry $Handoff -ArcMachine $Arc -PortTest (Get-FakeProbe $Answer)
    }

    # What the Identity node script writes: one AZLRESULT line (gzip, base64).
    function ConvertTo-ResultLine([object]$Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 5 -Compress))
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
    }
    # A transport that answers the Identity script the way the machine at one address would. Records the scripts it was asked to run.
    function New-IdentityTransport([string]$MachineName, [string[]]$Mac, [System.Collections.Generic.List[string]]$Log, [string]$Address) {
        $line = ConvertTo-ResultLine ([pscustomobject]@{ v = 1; host = $MachineName; macs = @($Mac) })
        [pscustomobject]@{
            Kind   = 'WinRM'
            Invoke = {
                param($Self, $Node, $Script, $Parameters, $Secrets, $TimeoutSeconds)
                $Log.Add("$Address|$Script")
                [pscustomobject]@{ Output = $line; Failed = $false; Error = ''; State = 'Succeeded' }
            }.GetNewClosure()
        }
    }
    # The identity reader the run would hand over: every address is a machine in $Machines (Name + MACs), or an error when it is not listed.
    function New-Reader([hashtable]$Machines, [System.Collections.Generic.List[string]]$Log) {
        $makeTransport = ${function:New-IdentityTransport}
        { param([string]$Address, [bool]$UseSsl)
            if (-not $Machines.ContainsKey($Address)) { throw "WinRM cannot process the request: $Address refused the credential" }
            $m = $Machines[$Address]
            Read-AzlNodeIdentity -Transport (& $makeTransport -MachineName $m.Name -Mac $m.Mac -Log $Log -Address $Address) -Node 'iic-n01'
        }.GetNewClosure()
    }
}

Describe 'Ranking: live evidence above historic' {
    It 'the lab case: the handoff is stale (.117), Arc is Connected and the file agrees (.11), all three answer: .11 wins and the plan says who disagreed' {
        $r = Resolve-Node -Answer @('192.0.2.117', '192.0.2.11') -Handoff (Get-Handoff '192.0.2.117') -Arc (Get-Arc '192.0.2.11')
        $r.Address | Should -Be '192.0.2.11'
        $r.Source | Should -Be 'arc'
        @($r.Candidates | Where-Object Answers | ForEach-Object Address) | Should -Be @('192.0.2.11', '192.0.2.117')
        ($r.Candidates | Where-Object Address -eq '192.0.2.11').Sources | Should -Be @('arc', 'infrastructure-file')
        ($r.Candidates | Where-Object Address -eq '192.0.2.117').Rank | Should -Be 2
        $r.SourcesAgree | Should -BeFalse
        $r.Agreement | Should -Be 'ZTP handoff says 192.0.2.117; Arc machine says 192.0.2.11 (Connected); infrastructure file says 192.0.2.11'
        ($r.Notes -join ' ') | Should -Match 'sources disagree'
        ($r.Notes -join ' ') | Should -Match 'ZTP handoff is historic data: its address 192\.0\.2\.117 answers, but 192\.0\.2\.11 is backed by the live Arc machine'
        ($r.Notes -join ' ') | Should -Match 'Arc machine reports it and is Connected'
        $r.Message | Should -Match 'sources disagree'
    }
    It 'all sources agree: one candidate with every source, no disagreement note' {
        $r = Resolve-Node -Answer @('192.0.2.11') -Handoff (Get-Handoff '192.0.2.11') -Arc (Get-Arc '192.0.2.11')
        $r.Address | Should -Be '192.0.2.11'
        @($r.Candidates).Count | Should -Be 1
        $r.Candidates[0].Sources | Should -Be @('ztp-handoff', 'arc', 'infrastructure-file')
        $r.Candidates[0].Rank | Should -Be 0
        $r.SourcesAgree | Should -BeTrue
        $r.Agreement | Should -Be 'ZTP handoff says 192.0.2.11; Arc machine says 192.0.2.11 (Connected); infrastructure file says 192.0.2.11'
        ($r.Notes -join ' ') | Should -Not -Match 'disagree'
    }
    It 'only the handoff answers and it is the only evidence that does: it is used (a last resort is still a resort)' {
        $r = Resolve-Node -Answer @('192.0.2.120') -Handoff (Get-Handoff '192.0.2.120') -Arc $null
        $r.Address | Should -Be '192.0.2.120'
        $r.Source | Should -Be 'ztp-handoff'
        $r.Candidates[0].Rank | Should -Be 2
        $r.Candidates[0].RankReason | Should -Match 'historic'
    }
    It 'a handoff address agreed on by the file beats nothing less: two sources make it rank 0' {
        $r = Resolve-Node -Answer @('192.0.2.11', '192.0.2.90') -Handoff (Get-Handoff '192.0.2.11') -Arc (Get-Arc '192.0.2.90' 'Disconnected')
        $r.Address | Should -Be '192.0.2.11'
        $r.Candidates[0].Rank | Should -Be 0
        ($r.Candidates | Where-Object Address -eq '192.0.2.90').Rank | Should -Be 1
    }
    It 'an Arc machine that is not Connected is one source of rank 1, still above a handoff-only address' {
        $r = Resolve-Node -Answer @('192.0.2.77', '192.0.2.117') -Handoff (Get-Handoff '192.0.2.117') -Arc (Get-Arc '192.0.2.77' 'Disconnected')
        $r.Address | Should -Be '192.0.2.77'
        $r.Source | Should -Be 'arc'
        $r.Candidates[0].Rank | Should -Be 1
        $r.Candidates[1].Address | Should -Be '192.0.2.117'
    }
    It 'Arc Connected beats the file when they disagree and both answer' {
        $r = Resolve-Node -Answer @('192.0.2.11', '192.0.2.77') -Handoff $null -Arc (Get-Arc '192.0.2.77')
        $r.Address | Should -Be '192.0.2.77'
        $r.Candidates[0].Rank | Should -Be 0
        ($r.Candidates | Where-Object Address -eq '192.0.2.11').Rank | Should -Be 1
    }
    It 'the handoff-only address that does not answer stays in Candidates behind the ones that do' {
        $r = Resolve-Node -Answer @('192.0.2.11') -Handoff (Get-Handoff '192.0.2.117') -Arc (Get-Arc '192.0.2.11')
        @($r.Candidates | ForEach-Object Address) | Should -Be @('192.0.2.11', '192.0.2.117')
        $r.Candidates[1].Answers | Should -BeFalse
        ($r.Notes -join ' ') | Should -Match 'does not answer'
    }
    It 'an override is final and has no ranking competition' {
        $r = Resolve-Node -Answer @('192.0.2.200', '192.0.2.11') -Handoff (Get-Handoff '192.0.2.117') -Arc (Get-Arc '192.0.2.11') -Override '192.0.2.200'
        $r.Address | Should -Be '192.0.2.200'
        $r.Source | Should -Be 'override'
        @($r.Candidates).Count | Should -Be 1
    }
}

Describe 'Test-AzlNodeIdentity' {
    It 'the management MAC and the name match' {
        $v = Test-AzlNodeIdentity -Expected $script:Expected -Found ([pscustomobject]@{ ComputerName = 'IIC-N01'; Mac = @('00005e005310', '00005e005311') })
        $v.Match | Should -BeTrue
        $v.Reason | Should -BeNullOrEmpty
    }
    It 'another machine: wrong name and no adapter with the management MAC' {
        $v = Test-AzlNodeIdentity -Expected $script:Expected -Found ([pscustomobject]@{ ComputerName = 'IIC-N03'; Mac = @('00005e005330') })
        $v.Match | Should -BeFalse
        $v.Reason | Should -Match 'no adapter has the management MAC 00:00:5E:00:53:10'
        $v.Found | Should -Be 'IIC-N03/00:00:5E:00:53:30'
        $v.Expected | Should -Be 'iic-n01 (management MAC 00:00:5E:00:53:10)'
    }
    It 'the right name but not the MAC is not the node either (a clone, a swapped board)' {
        (Test-AzlNodeIdentity -Expected $script:Expected -Found ([pscustomobject]@{ ComputerName = 'iic-n01'; Mac = @('00005e005330') })).Match | Should -BeFalse
    }
    It 'the MAC is there but the name is the installer''s: accepted with a note (the Hostname step renames it)' {
        $v = Test-AzlNodeIdentity -Expected $script:Expected -Found ([pscustomobject]@{ ComputerName = 'WIN-ABC123'; Mac = @('00005e005310') })
        $v.Match | Should -BeTrue
        $v.Reason | Should -Match 'not yet iic-n01'
    }
    It 'the MAC is there but the name is another node of the file: refused' {
        $v = Test-AzlNodeIdentity -Expected $script:Expected -Found ([pscustomobject]@{ ComputerName = 'iic-n02'; Mac = @('00005e005310') })
        $v.Match | Should -BeFalse
        $v.Reason | Should -Match 'name of another node'
    }
    It 'a file without a management MAC: the name decides' {
        $noMac = [pscustomobject]@{ Name = 'iic-n01'; ManagementMac = ''; OtherName = @('iic-n02') }
        (Test-AzlNodeIdentity -Expected $noMac -Found ([pscustomobject]@{ ComputerName = 'IIC-N01'; Mac = @() })).Match | Should -BeTrue
        (Test-AzlNodeIdentity -Expected $noMac -Found ([pscustomobject]@{ ComputerName = 'iic-n03'; Mac = @('00005e005330') })).Match | Should -BeFalse
    }
    It 'a machine that reports nothing is not the node' {
        $v = Test-AzlNodeIdentity -Expected $script:Expected -Found ([pscustomobject]@{ ComputerName = ''; Mac = @() })
        $v.Match | Should -BeFalse
        $v.Found | Should -Be 'unknown name/no MAC reported'
    }
    It 'Get-AzlNodeExpectedIdentity takes the host name and the management MAC from the file, and the other nodes'' names' {
        $script:Expected.Name | Should -Be 'iic-n01'
        $script:Expected.ManagementMac | Should -Be '00005e005310'
        $script:Expected.OtherName | Should -Be @('iic-n02')
    }
}

Describe 'Read-AzlNodeIdentity (fake transport)' {
    It 'runs the read-only Identity script and returns the name and the MACs in one notation' {
        $log = [System.Collections.Generic.List[string]]::new()
        $t = New-IdentityTransport -MachineName 'IIC-N01' -Mac @('00-00-5E-00-53-10', '00:00:5e:00:53:11') -Log $log -Address '192.0.2.11'
        $id = Read-AzlNodeIdentity -Transport $t -Node 'iic-n01'
        $id.ComputerName | Should -Be 'IIC-N01'
        $id.Mac | Should -Be @('00005e005310', '00005e005311')
        $log.Count | Should -Be 1
        $log[0] | Should -Match 'Get-NetAdapter'
        $log[0] | Should -Not -Match 'Set-Net|Set-Item|Set-Dns|Remove-|Restart-|New-NetIPAddress|Rename-|Disable-|Enable-'
    }
}

Describe 'Select-AzlVerifiedNodeAddress' {
    It 'the lab case: the stale handoff address would have answered as node 3, but .11 is tried first, proves to be n01 and .117 is never sent a credential' {
        $r = Resolve-Node -Answer @('192.0.2.117', '192.0.2.11') -Handoff (Get-Handoff '192.0.2.117') -Arc (Get-Arc '192.0.2.11')
        $log = [System.Collections.Generic.List[string]]::new()
        $reader = New-Reader @{ '192.0.2.11' = @{ Name = 'IIC-N01'; Mac = @($script:Mac01) }; '192.0.2.117' = @{ Name = 'IIC-N03'; Mac = @($script:Mac03) } } $log
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader
        $v.Verified | Should -BeTrue
        $v.Address | Should -Be '192.0.2.11'
        $v.Source | Should -Be 'arc'
        @($log | ForEach-Object { ($_ -split '\|')[0] } | Select-Object -Unique) | Should -Be @('192.0.2.11')
        $v.Dropped.Count | Should -Be 0
    }
    It 'the first candidate is another machine: it is dropped with the exact words and the next candidate is used' {
        # No Arc machine and no corroboration: the file's .11 is now another machine, the handoff's .120 is the node.
        $r = Resolve-Node -Answer @('192.0.2.11', '192.0.2.120') -Handoff (Get-Handoff '192.0.2.120') -Arc $null
        $log = [System.Collections.Generic.List[string]]::new()
        $reader = New-Reader @{ '192.0.2.11' = @{ Name = 'IIC-N03'; Mac = @($script:Mac03) }; '192.0.2.120' = @{ Name = 'IIC-N01'; Mac = @($script:Mac01) } } $log
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader
        $v.Verified | Should -BeTrue
        $v.Address | Should -Be '192.0.2.120'
        $v.Dropped.Count | Should -Be 1
        $v.Dropped[0].Address | Should -Be '192.0.2.11'
        $v.Dropped[0].Text | Should -Be 'address 192.0.2.11 answered but is IIC-N03/00:00:5E:00:53:30, not iic-n01 (management MAC 00:00:5E:00:53:10)'
        ($v.Log -join ' ') | Should -Match 'address 192\.0\.2\.11 answered but is IIC-N03'
    }
    It 'only the handoff exists and it is right: verified' {
        $r = Resolve-Node -Answer @('192.0.2.120') -Handoff (Get-Handoff '192.0.2.120') -Arc $null
        $reader = New-Reader @{ '192.0.2.120' = @{ Name = 'IIC-N01'; Mac = @($script:Mac01) } } ([System.Collections.Generic.List[string]]::new())
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader
        $v.Verified | Should -BeTrue
        $v.Address | Should -Be '192.0.2.120'
        $v.Source | Should -Be 'ztp-handoff'
    }
    It 'only the handoff exists and it is wrong: nothing proves the identity, the message names what answered where, nothing is accepted' {
        $r = Resolve-Node -Answer @('192.0.2.117') -Handoff (Get-Handoff '192.0.2.117') -Arc $null
        $reader = New-Reader @{ '192.0.2.117' = @{ Name = 'TPLABS-AZL-N03'; Mac = @('C4:CB:E1:B3:6F:D0', 'C4:CB:E1:B3:6F:D1') } } ([System.Collections.Generic.List[string]]::new())
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader
        $v.Verified | Should -BeFalse
        $v.Address | Should -BeNullOrEmpty
        $v.Message | Should -Match 'No address proved to be iic-n01'
        $v.Message | Should -Match 'address 192\.0\.2\.117 answered but is TPLABS-AZL-N03/C4:CB:E1:B3:6F:D0,C4:CB:E1:B3:6F:D1, not iic-n01'
        $v.Message | Should -Match 'found by ztp-handoff'
        $v.Message | Should -Match 'Nothing was changed|nothing was changed'
        $v.Message | Should -Match '-NodeAddress'
    }
    It 'an override that points at the wrong machine stops the run with a clear message (no other source is tried)' {
        $r = Resolve-Node -Answer @('192.0.2.117', '192.0.2.11') -Handoff (Get-Handoff '192.0.2.11') -Arc (Get-Arc '192.0.2.11') -Override '192.0.2.117'
        $log = [System.Collections.Generic.List[string]]::new()
        $reader = New-Reader @{ '192.0.2.117' = @{ Name = 'IIC-N03'; Mac = @($script:Mac03) }; '192.0.2.11' = @{ Name = 'IIC-N01'; Mac = @($script:Mac01) } } $log
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader
        $v.Verified | Should -BeFalse
        $v.Message | Should -Match 'The address you gave for iic-n01 does not belong to it'
        $v.Message | Should -Match 'address 192\.0\.2\.117 answered but is IIC-N03/00:00:5E:00:53:30, not iic-n01'
        @($log | ForEach-Object { ($_ -split '\|')[0] } | Select-Object -Unique) | Should -Be @('192.0.2.117')
    }
    It 'an override that points at the node is accepted' {
        $r = Resolve-Node -Answer @('192.0.2.200') -Handoff $null -Arc $null -Override '192.0.2.200'
        $reader = New-Reader @{ '192.0.2.200' = @{ Name = 'IIC-N01'; Mac = @($script:Mac01) } } ([System.Collections.Generic.List[string]]::new())
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader
        $v.Verified | Should -BeTrue
        $v.Source | Should -Be 'override'
    }
    It 'a candidate whose identity cannot be read proves nothing: it is reported with the reason, not accepted' {
        $r = Resolve-Node -Answer @('192.0.2.11') -Handoff $null -Arc $null
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader (New-Reader @{} ([System.Collections.Generic.List[string]]::new()))
        $v.Verified | Should -BeFalse
        $v.Message | Should -Match 'the local administrator was refused at 192\.0\.2\.11'
        $v.Message | Should -Match 'refused the credential'
        (Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader { throw 'The node script returned something this host cannot read.' }).Message | Should -Match 'could not read the identity at 192\.0\.2\.11'
    }
    It 'without a reader (no credential) nothing is checked and the best answering candidate is returned, marked unchecked' {
        $r = Resolve-Node -Answer @('192.0.2.11') -Handoff $null -Arc $null
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $null
        $v.Verified | Should -BeTrue
        $v.Checked | Should -BeFalse
        $v.Address | Should -Be '192.0.2.11'
    }
    It 'nothing answers: nothing to verify, no message (the resolution already says what it tried)' {
        $r = Resolve-Node -Answer @() -Handoff $null -Arc $null
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader (New-Reader @{} ([System.Collections.Generic.List[string]]::new()))
        $v.Verified | Should -BeFalse
        $v.Message | Should -BeNullOrEmpty
    }
    It 'the endpoint resolver decides the scheme the identity is read over' {
        $r = Resolve-Node -Answer @('192.0.2.11') -Handoff $null -Arc $null
        $seen = [System.Collections.Generic.List[string]]::new()
        $reader = { param([string]$Address, [bool]$UseSsl) $seen.Add("$Address|$UseSsl"); [pscustomobject]@{ ComputerName = 'iic-n01'; Mac = @('00005e005310') } }.GetNewClosure()
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader -EndpointResolver { param($a) [pscustomobject]@{ Answers = $true; UseSsl = $true; Port = 5986 } }
        $v.UseSsl | Should -BeTrue
        $seen[0] | Should -Be '192.0.2.11|True'
    }
}

Describe 'Identity read failures: refused versus unreachable (a node that restarts is not a node that refuses the credential)' {
    BeforeAll {
        # The text of the failures the lab saw and the ones WinRM gives while a node goes down or comes up.
        $script:Denied = 'Opening a session to iic-n01 at 192.0.2.11:5985 failed after 0.1 s (open timeout 30 s): Connecting to remote server 192.0.2.11 failed with the following error message : Access is denied. For more information, see the about_Remote_Troubleshooting Help topic.'
        $script:Timeout = 'Opening a session to iic-n01 at 192.0.2.11:5985 failed after 30.1 s (open timeout 30 s): Connecting to remote server 192.0.2.11 failed with the following error message : The WinRM client cannot process the request because the server name cannot be resolved. The operation has timed out.'
        $script:Closed = 'Opening a session to iic-n01 at 192.0.2.11:5985 failed after 2.0 s (open timeout 30 s): Connecting to remote server 192.0.2.11 failed with the following error message : The connection was closed by the remote host (an existing connection was forcibly closed by the remote host).'
        $script:Sleeps = [System.Collections.Generic.List[int]]::new()
        $script:Sleeper = { param([int]$Seconds) $script:Sleeps.Add($Seconds) }
        $script:Answering = { Resolve-AzlNodeAddress -Infrastructure $script:Infra -Node $script:N01 -Override '192.0.2.11' -HandoffEntry $null -ArcMachine $null -PortTest { param($a, $p) $p -eq 5985 -and $a -eq '192.0.2.11' } }
    }
    BeforeEach { $script:Sleeps.Clear() }

    It '<Kind>: <Text>' -ForEach @(
        @{ Kind = 'Refused'; Text = 'Connecting to remote server 192.0.2.11 failed with the following error message : Access is denied.' }
        @{ Kind = 'Refused'; Text = 'The WinRM client cannot process the request. 0x80070005 occurred' }
        @{ Kind = 'Refused'; Text = 'The user name or password is incorrect.' }
        @{ Kind = 'Refused'; Text = 'The server returned HTTP status 401 (Unauthorized)' }
        @{ Kind = 'Refused'; Text = 'WinRM cannot process the request: 192.0.2.11 refused the credential' }
        @{ Kind = 'Unreachable'; Text = 'The operation has timed out.' }
        @{ Kind = 'Unreachable'; Text = 'The connection was closed by the remote host' }
        @{ Kind = 'Unreachable'; Text = 'An existing connection was forcibly closed by the remote host' }
        @{ Kind = 'Unreachable'; Text = 'Connection reset by peer' }
        @{ Kind = 'Unreachable'; Text = 'No connection could be made because the target machine actively refused it' }
        @{ Kind = 'Unreachable'; Text = 'WinRM cannot complete the operation. Verify that the specified computer name is valid, that the computer is accessible over the network (0x80338126)' }
        @{ Kind = 'Unreachable'; Text = 'The call to iic-n01 did not finish within 105 seconds and was abandoned.' }
        @{ Kind = 'Other'; Text = 'The node script returned something this host cannot read.' }
    ) {
        Get-AzlSessionFailureKind -Message $Text | Should -Be $Kind
    }

    It 'the lab case: the session open is denied after 0.1 s while the node restarts, and only a refusal says refused' {
        Get-AzlSessionFailureKind -Message $script:Denied | Should -Be 'Refused'
        Get-AzlSessionFailureKind -Message $script:Timeout | Should -Be 'Unreachable'
        Get-AzlSessionFailureKind -Message $script:Closed | Should -Be 'Unreachable'
    }

    It 'a session that cannot be opened because the node is restarting is unreachable, said as "did not answer (restarting?)", never as a refused credential' {
        $r = & $script:Answering; $closed = $script:Closed; $timeout = $script:Timeout; $denied = $script:Denied
        $calls = [System.Collections.Generic.List[int]]::new()
        $reader = { param([string]$Address, [bool]$UseSsl) $calls.Add(1); throw $closed }.GetNewClosure()
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader -Sleeper $script:Sleeper
        $v.Verified | Should -BeFalse
        $v.Unreachable | Should -BeTrue
        $v.Message | Should -Match 'did not answer \(restarting\?\)'
        $v.Message | Should -Not -Match 'refused'
        $calls.Count | Should -Be 3
        $script:Sleeps.Count | Should -Be 2
    }

    It 'an unreachable read is retried and the node that answers on the second try is verified' {
        $r = & $script:Answering; $closed = $script:Closed; $timeout = $script:Timeout; $denied = $script:Denied
        $n = [ref]0
        $reader = { param([string]$Address, [bool]$UseSsl) $n.Value++; if ($n.Value -lt 3) { throw $timeout }; [pscustomobject]@{ ComputerName = 'IIC-N01'; Mac = @('00005e005310') } }.GetNewClosure()
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader -Sleeper $script:Sleeper
        $v.Verified | Should -BeTrue
        $v.Message | Should -BeNullOrEmpty
        $n.Value | Should -Be 3
        ($v.Log -join ' ') | Should -Match 'did not answer \(restarting\?\).*trying again'
    }

    It 'a real refusal is refused, once: it is not retried' {
        $r = & $script:Answering; $closed = $script:Closed; $timeout = $script:Timeout; $denied = $script:Denied
        $n = [ref]0
        $reader = { param([string]$Address, [bool]$UseSsl) $n.Value++; throw $denied }.GetNewClosure()
        $v = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader -Sleeper $script:Sleeper
        $v.Verified | Should -BeFalse
        $v.Unreachable | Should -BeFalse
        $v.Message | Should -Match 'the local administrator was refused at 192\.0\.2\.11'
        $n.Value | Should -Be 1
        $script:Sleeps.Count | Should -Be 0
    }

    It 'the number of tries and the pause are the caller''s' {
        $r = & $script:Answering; $closed = $script:Closed; $timeout = $script:Timeout; $denied = $script:Denied
        $n = [ref]0
        $reader = { param([string]$Address, [bool]$UseSsl) $n.Value++; throw $timeout }.GetNewClosure()
        $null = Select-AzlVerifiedNodeAddress -Resolution $r -Expected $script:Expected -IdentityReader $reader -UnreachableTries 5 -UnreachableDelaySeconds 7 -Sleeper $script:Sleeper
        $n.Value | Should -Be 5
        @($script:Sleeps | Select-Object -Unique) | Should -Be @(7)
    }
}
