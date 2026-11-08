#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The REAL node operations of the guarded change (New-GuardRealOps) and the Apply payload, run in a child process (PowerShell 7 and, when installed, Windows
# PowerShell 5.1 - the node's shell) against an in-memory fake of the NetTCPIP / NetAdapter / DnsClient cmdlets. Nothing here touches this machine's network
# configuration: every cmdlet the operations call is replaced by a function that works on a hashtable.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/NodeGuardRealOps.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake node operations take the parameters of the real ones.')]
param()

BeforeDiscovery {
    $script:NodeHosts = @(@{ Label = 'PowerShell 7'; Exe = (Get-Process -Id $PID).Path })
    $ps51 = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($ps51) { $script:NodeHosts += @{ Label = 'Windows PowerShell 5.1'; Exe = $ps51.Source } }
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = [IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration')
    Import-Module (Join-Path $dir 'AzlNodeGuard.psm1') -Force
    Import-Module (Join-Path $dir 'AzlNodePayload.psm1') -Force

    # The fake node. Functions with the names of the cmdlets the operations call; they shadow the cmdlets (functions win over cmdlets).
    $script:Stubs = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$global:Fake = @{ Adapters = (New-Object System.Collections.ArrayList); Ips = (New-Object System.Collections.ArrayList); Routes = (New-Object System.Collections.ArrayList); Ifs = @{}; Dns = @{}; DnsAnswer = @{}; Calls = (New-Object System.Collections.ArrayList) }
function Add-FakeAdapter([string]$Name, [int]$Index, [string]$Mac, [string]$Status = 'Up', [bool]$Cabled = $true, [string]$Dhcp = 'Enabled') {
    [void]$global:Fake.Adapters.Add([pscustomobject]@{ Name = $Name; ifIndex = $Index; MacAddress = $Mac; PermanentAddress = $Mac; Status = $Status; InterfaceGuid = [guid]::NewGuid().ToString(); Cabled = $Cabled })
    $global:Fake.Ifs[$Index] = [pscustomobject]@{ Dhcp = $Dhcp; InterfaceMetric = 25 }
    $global:Fake.Dns[$Index] = @()
}
function Add-FakeIp([int]$Index, [string]$Ip, [int]$Prefix = 24, [string]$Origin = 'Manual') { [void]$global:Fake.Ips.Add([pscustomobject]@{ InterfaceIndex = $Index; IPAddress = $Ip; PrefixLength = $Prefix; PrefixOrigin = $Origin; AddressState = 'Preferred' }) }
function Add-FakeRoute([int]$Index, [string]$NextHop, [string[]]$Stores = @('ActiveStore')) { [void]$global:Fake.Routes.Add([pscustomobject]@{ InterfaceIndex = $Index; DestinationPrefix = '0.0.0.0/0'; NextHop = $NextHop; RouteMetric = 0; Stores = $Stores }) }
function Start-Sleep { [CmdletBinding()] param([int]$Seconds = 0, [int]$Milliseconds = 0) }
function Get-NetAdapter { [CmdletBinding()] param([switch]$Physical, [string]$Name) foreach ($a in @($global:Fake.Adapters)) { if (-not $Name -or $a.Name -eq $Name) { $a } } }
function Enable-NetAdapter { [CmdletBinding(SupportsShouldProcess)] param([string]$Name) foreach ($a in @($global:Fake.Adapters)) { if ($a.Name -eq $Name) { $a.Status = $(if ($a.Cabled) { 'Up' } else { 'Disconnected' }) } } }
function Get-NetLbfoTeamMember { [CmdletBinding()] param([string]$Name) }
function Get-VMSwitch { [CmdletBinding()] param() }
function Get-NetAdapterAdvancedProperty { [CmdletBinding()] param([string]$Name, [string]$RegistryKeyword) }
function Get-NetIPInterface { [CmdletBinding()] param([int]$InterfaceIndex, [string]$AddressFamily) $global:Fake.Ifs[$InterfaceIndex] }
function Set-NetIPInterface { [CmdletBinding()] param([int]$InterfaceIndex, [string]$AddressFamily, [string]$Dhcp) $global:Fake.Ifs[$InterfaceIndex].Dhcp = $Dhcp }
function Get-NetIPAddress {
    [CmdletBinding()] param([int]$InterfaceIndex = -1, [string]$AddressFamily, [string]$IPAddress)
    foreach ($x in @($global:Fake.Ips)) { if (($InterfaceIndex -lt 0 -or $x.InterfaceIndex -eq $InterfaceIndex) -and (-not $IPAddress -or $x.IPAddress -eq $IPAddress)) { $x } }
}
function Remove-NetIPAddress { [CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$InputObject) process { $global:Fake.Ips.Remove($InputObject) } }
function New-NetIPAddress {
    [CmdletBinding()] param([int]$InterfaceIndex, [string]$IPAddress, [int]$PrefixLength, [string]$DefaultGateway)
    if ($global:Fake.Ifs[$InterfaceIndex].Dhcp -eq 'Enabled') { throw 'New-NetIPAddress : Inconsistent parameters PolicyStore PersistentStore and Dhcp Enabled' }
    if (@($global:Fake.Ips | Where-Object { $_.IPAddress -eq $IPAddress }).Count) { throw ('New-NetIPAddress : the address ' + $IPAddress + ' already exists (duplicate)') }
    Add-FakeIp $InterfaceIndex $IPAddress $PrefixLength 'Manual'
    if ($DefaultGateway) {
        if (@($global:Fake.Routes | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex -and $_.Stores -contains 'ActiveStore' }).Count) { throw 'New-NetIPAddress : Instance MSFT_NetRoute already exists' }
        Add-FakeRoute $InterfaceIndex $DefaultGateway @('ActiveStore', 'PersistentStore')
    }
}
function Get-NetRoute {
    [CmdletBinding()] param([int]$InterfaceIndex = -1, [string]$AddressFamily, [string]$DestinationPrefix, [string]$PolicyStore = 'ActiveStore')
    foreach ($r in @($global:Fake.Routes)) { if (($InterfaceIndex -lt 0 -or $r.InterfaceIndex -eq $InterfaceIndex) -and (-not $DestinationPrefix -or $r.DestinationPrefix -eq $DestinationPrefix) -and $r.Stores -contains $PolicyStore) { $r } }
}
function Remove-NetRoute { [CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$InputObject) process { $global:Fake.Routes.Remove($InputObject) } }
function New-NetRoute {
    [CmdletBinding()] param([int]$InterfaceIndex, [string]$AddressFamily, [string]$DestinationPrefix, [string]$NextHop, [string]$PolicyStore)
    if (@($global:Fake.Routes | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex -and $_.NextHop -eq $NextHop -and $_.Stores -contains 'ActiveStore' }).Count) { throw 'New-NetRoute : Instance MSFT_NetRoute already exists' }
    Add-FakeRoute $InterfaceIndex $NextHop @('ActiveStore', 'PersistentStore')
}
function Get-DnsClientServerAddress { [CmdletBinding()] param([int]$InterfaceIndex, [string]$AddressFamily) [pscustomobject]@{ ServerAddresses = @($global:Fake.Dns[$InterfaceIndex]) } }
function Set-DnsClientServerAddress { [CmdletBinding()] param([int]$InterfaceIndex, [string[]]$ServerAddresses, [switch]$ResetServerAddresses) $global:Fake.Dns[$InterfaceIndex] = $(if ($ResetServerAddresses) { @() } else { @($ServerAddresses) }) }
function Resolve-DnsName {
    [CmdletBinding()] param([string]$Name, [string]$Server = '*default*', [string]$Type, [switch]$DnsOnly)
    $answer = $(if ($global:Fake.DnsAnswer.ContainsKey($Server)) { $global:Fake.DnsAnswer[$Server] } else { 'ok' })
    if ($answer -eq 'ok') { return [pscustomobject]@{ Name = $Name } }
    if ($answer -eq 'nx') { throw ($Name + ' : DNS name does not exist') }
    if ($answer -eq 'code') { throw ('Resolve-DnsName : ' + $Name + ' : error 9003') }
    throw ($Name + ' : DNS operation timed out')
}
'@

    # Runs a scenario in a child process: stubs, then the engine text (as staged on the node), then the body. The body leaves its answer in $result.
    function Invoke-NodeHarness([string]$Exe, [string]$Body) {
        $work = Join-Path $TestDrive ('h' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $work
        $file = Join-Path $work 'harness.ps1'
        $text = $script:Stubs + "`n" + (Get-AzlGuardEngine) + "`n" + $Body + "`nWrite-Output ('RESULT:' + (ConvertTo-Json -InputObject `$result -Depth 8 -Compress))`n"
        [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($true)))
        $out = @(& $Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 | ForEach-Object { [string]$_ })
        $line = @($out | Where-Object { $_ -like 'RESULT:*' } | Select-Object -Last 1)
        if (-not $line.Count) { throw ('The harness gave no result (exit ' + $LASTEXITCODE + '): ' + ($out -join ' | ')) }
        return ($line[0].Substring(7) | ConvertFrom-Json)
    }

    # The Apply payload as a file, run under the stubs.
    function Invoke-NodePayload([string]$Exe, [string]$Setup, [object[]]$Action) {
        $work = Join-Path $TestDrive ('p' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $work
        [IO.File]::WriteAllText((Join-Path $work 'stubs.ps1'), $script:Stubs, (New-Object Text.UTF8Encoding($true)))
        $payload = (Get-AzlNodePayload -Name Apply).Replace('C:\ProgramData\AzureLocal\osconfig', $work)
        [IO.File]::WriteAllText((Join-Path $work 'apply.ps1'), $payload, (New-Object Text.UTF8Encoding($true)))
        $wrapper = "param([string]`$ParamsB64)`n. '" + (Join-Path $work 'stubs.ps1') + "'`n" + $Setup + "`n& '" + (Join-Path $work 'apply.ps1') + "' -ParamsB64 `$ParamsB64`n"
        [IO.File]::WriteAllText((Join-Path $work 'wrapper.ps1'), $wrapper, (New-Object Text.UTF8Encoding($true)))
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{ actions = @($Action) } -Depth 6)))
        $out = @(& $Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $work 'wrapper.ps1') -ParamsB64 $b64 2>&1 | ForEach-Object { [string]$_ })
        $line = @($out | Where-Object { $_ -like 'AZLRESULT:*' } | Select-Object -Last 1)
        if (-not $line.Count) { throw ('The payload gave no result (exit ' + $LASTEXITCODE + '): ' + ($out -join ' | ')) }
        $ms = New-Object IO.MemoryStream (, [Convert]::FromBase64String($line[0].Substring(10)))
        $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
        $sr = New-Object IO.StreamReader($gz)
        return ($sr.ReadToEnd() | ConvertFrom-Json)
    }

    $script:MgmtItemText = "[pscustomobject]@{ id = 'n'; kind = 'nic-static'; management = `$true; mac = 'aabbccddee01'; ip = '10.0.0.60'; prefix = 24; gateway = '10.0.0.1'; dns = @('10.0.0.2', '10.0.0.3') }"
}

Describe 'The helpers of the real operations exist where the operations can call them' {
    It 'defines no function inside another function: every helper is top level in the engine text' {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-AzlGuardEngine), [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $all = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $nested = @($all | Where-Object { $p = $_.Parent; $inner = $false; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inner = $true }; $p = $p.Parent }; $inner })
        ($nested | ForEach-Object { $_.Name }) -join ', ' | Should -Be ''
        foreach ($name in 'Get-GuardMacKey', 'Get-GuardAdapter', 'Invoke-GuardNative', 'Get-GuardNicInfo', 'Clear-GuardNic', 'Restore-GuardNic', 'Test-GuardTcp') { $all.Name | Should -Contain $name }
    }

    It 'every *-Guard* function an operation calls is defined in the engine: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'Port0' 10 'AA-BB-CC-DD-EE-01' 'Up' `$true 'Enabled'
Add-FakeAdapter 'Port1' 11 'AA-BB-CC-DD-EE-02' 'Up' `$true 'Enabled'
Add-FakeIp 10 '10.0.0.50' 24 'Dhcp'; Add-FakeRoute 10 '10.0.0.1'
`$ops = New-GuardRealOps
`$cfg = [pscustomobject]@{ changeId = 'x'; probeHosts = @('corp.example.test'); expect = [pscustomobject]@{ mac = 'aabbccddee01'; ip = '10.0.0.50'; requireGateway = `$true; winrm = `$false }; items = @([pscustomobject]@{ id = 'c'; kind = 'nic-clean'; mac = 'aabbccddee02' }) }
`$nics = @(& `$ops.GetNics)
`$addr = & `$ops.CheckAddress `$cfg
`$ports = & `$ops.CheckPorts `$cfg
`$gate = & `$ops.SnapshotItem `$cfg.items[0]
`$result = @{ nics = `$nics.Count; addr = [bool]`$addr.ok; ports = [bool]`$ports.ok; snap = [string]`$gate.name }
"@
        $r.nics | Should -Be 2
        $r.addr | Should -BeTrue
        $r.ports | Should -BeTrue
        $r.snap | Should -Be 'Port1'
    }

    It 'the monotonic clock operation works on the node (Windows PowerShell 5.1 has no [Environment]::TickCount64): <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
`$ops = New-GuardRealOps
`$t = [double](& `$ops.Tick)
`$result = @{ positive = (`$t -gt 0) }
"@
        $r.positive | Should -BeTrue
    }
    It 'the staged script exits non-zero and does not hang when it cannot read its configuration: <Label>' -ForEach $script:NodeHosts {
        $work = Join-Path $TestDrive ('s' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $work
        $script = Join-Path $work 'net-abc123def456.ps1'
        [IO.File]::WriteAllText($script, (Get-AzlGuardScriptText -ChangeId 'abc123def456'), (New-Object Text.UTF8Encoding($true)))
        $null = & $Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script 2>&1
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'The DNS check: a configured server that answers is enough' {
    BeforeAll {
        function Get-DnsCheck([string]$Exe, [hashtable]$Answer) {
            # A query without -Server goes to the first server of the port (the system resolver order); with -Server to that server.
            $set = ((@($Answer.Keys) + '*default*') | ForEach-Object { $k = $_; $v = $(if ($k -eq '*default*') { $Answer['192.168.1.30'] } else { $Answer[$k] }); "`$global:Fake.DnsAnswer['$k'] = '$v'" }) -join "`n"
            $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'Port0' 10 'AA-BB-CC-DD-EE-01'
`$global:Fake.Dns[10] = @('192.168.1.30', '192.168.1.31')
$set
`$ops = New-GuardRealOps
`$c = & `$ops.CheckDns ([pscustomobject]@{ probeHosts = @('corp.example.test'); expect = [pscustomobject]@{ mac = 'aabbccddee01' } })
`$result = @{ ok = [bool]`$c.ok; detail = [string]`$c.detail }
"@
            return $r
        }
    }
    It 'NXDOMAIN (name does not exist) from the internal server counts as answering: <Label>' -ForEach $script:NodeHosts {
        $r = Get-DnsCheck $Exe @{ '192.168.1.30' = 'nx'; '192.168.1.31' = 'nx' }
        $r.ok | Should -BeTrue
    }
    It 'error 9003 counts as answering: <Label>' -ForEach $script:NodeHosts {
        (Get-DnsCheck $Exe @{ '192.168.1.30' = 'code'; '192.168.1.31' = 'timeout' }).ok | Should -BeTrue
    }
    It 'one server timing out is not enough to fail when another answers: <Label>' -ForEach $script:NodeHosts {
        (Get-DnsCheck $Exe @{ '192.168.1.30' = 'timeout'; '192.168.1.31' = 'ok' }).ok | Should -BeTrue
    }
    It 'fails only when no server answers (every query times out): <Label>' -ForEach $script:NodeHosts {
        $r = Get-DnsCheck $Exe @{ '192.168.1.30' = 'timeout'; '192.168.1.31' = 'timeout' }
        $r.ok | Should -BeFalse
        $r.detail | Should -Match 'no DNS server answers'
    }
}

Describe 'The management default route is persistent' {
    It 'replaces the DHCP route (active store only) with a persistent one; the old address stays until the finalize step: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'Port0' 10 'AA-BB-CC-DD-EE-01' 'Up' `$true 'Enabled'
Add-FakeIp 10 '10.0.0.50' 24 'Dhcp'
Add-FakeRoute 10 '10.0.0.1' @('ActiveStore')
`$ops = New-GuardRealOps
`$item = $script:MgmtItemText
& `$ops.ApplyItem `$item
`$persistent = @(Get-NetRoute -InterfaceIndex 10 -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore PersistentStore | Where-Object { `$_.NextHop -eq '10.0.0.1' })
`$active = @(Get-NetRoute -InterfaceIndex 10 -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Where-Object { `$_.NextHop -eq '10.0.0.1' })
`$oldDuring = @(Get-NetIPAddress -InterfaceIndex 10 -IPAddress '10.0.0.50').Count
`$newDuring = @(Get-NetIPAddress -InterfaceIndex 10 -IPAddress '10.0.0.60').Count
& `$ops.FinalizeItem `$item `$null
`$result = @{ persistent = `$persistent.Count; active = `$active.Count; dhcp = [string]`$global:Fake.Ifs[10].Dhcp; oldDuring = `$oldDuring; newDuring = `$newDuring
    oldAfter = @(Get-NetIPAddress -InterfaceIndex 10 -IPAddress '10.0.0.50').Count; persistentAfter = @(Get-NetRoute -InterfaceIndex 10 -DestinationPrefix '0.0.0.0/0' -PolicyStore PersistentStore).Count; dns = @(`$global:Fake.Dns[10]) }
"@
        $r.dhcp | Should -Be 'Disabled'
        $r.persistent | Should -Be 1
        $r.active | Should -Be 1
        $r.oldDuring | Should -Be 1
        $r.newDuring | Should -Be 1
        $r.oldAfter | Should -Be 0
        $r.persistentAfter | Should -Be 1
        @($r.dns) | Should -Be @('10.0.0.2', '10.0.0.3')
    }

    It 'keeps an existing persistent route and creates nothing twice: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'Port0' 10 'AA-BB-CC-DD-EE-01' 'Up' `$true 'Disabled'
Add-FakeIp 10 '10.0.0.50' 24 'Manual'
Add-FakeRoute 10 '10.0.0.1' @('ActiveStore', 'PersistentStore')
`$ops = New-GuardRealOps
& `$ops.ApplyItem ($script:MgmtItemText)
`$result = @{ routes = @(Get-NetRoute -InterfaceIndex 10 -DestinationPrefix '0.0.0.0/0' -PolicyStore PersistentStore).Count }
"@
        $r.routes | Should -Be 1
    }
}

Describe 'The destination port of the management address' {
    BeforeAll {
        function Invoke-Apply([string]$Exe, [string]$Setup, [string]$ItemExtra = '') {
            return (Invoke-NodeHarness $Exe @"
$Setup
`$ops = New-GuardRealOps
`$item = $script:MgmtItemText
$ItemExtra
`$msg = ''
try { & `$ops.ApplyItem `$item } catch { `$msg = `$_.Exception.Message }
`$status = ''
`$a = @(`$global:Fake.Adapters | Where-Object { `$_.ifIndex -eq 10 })
if (`$a.Count) { `$status = [string]`$a[0].Status }
`$result = @{ msg = `$msg; status = `$status; ips = @(Get-NetIPAddress -InterfaceIndex 10 -IPAddress '10.0.0.60').Count }
"@)
        }
    }
    It 'enables a Disabled port and waits for the link before the address is set: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-Apply $Exe "Add-FakeAdapter 'Port0' 10 'AA-BB-CC-DD-EE-01' 'Disabled' `$true 'Disabled'"
        $r.msg | Should -Be ''
        $r.status | Should -Be 'Up'
        $r.ips | Should -Be 1
    }
    It 'NoCarrier (not cabled) is a verdict of its own and nothing is configured: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-Apply $Exe "Add-FakeAdapter 'Port0' 10 'AA-BB-CC-DD-EE-01' 'Disabled' `$false 'Disabled'"
        $r.msg | Should -Match '^NoCarrier'
        $r.ips | Should -Be 0
    }
    It 'skipLinkCheck lets a standby port without a link through: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-Apply $Exe "Add-FakeAdapter 'Port0' 10 'AA-BB-CC-DD-EE-01' 'Disabled' `$false 'Disabled'" "`$item | Add-Member -NotePropertyName skipLinkCheck -NotePropertyValue `$true"
        $r.msg | Should -Be ''
        $r.ips | Should -Be 1
    }
    It 'a port that is not there (BIOS-disabled) is AdapterMissing, a different verdict from NoCarrier: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-Apply $Exe "Add-FakeAdapter 'Other' 11 'AA-BB-CC-DD-EE-09' 'Up' `$true 'Disabled'"
        $r.msg | Should -Match '^AdapterMissing'
    }
}

Describe 'Moving the management address from port A to port B' {
    It 'takes the address, its route and its name servers off A, puts them on B, and the snapshot gives them back to A: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'PortA' 10 'AA-BB-CC-DD-EE-01' 'Up' `$true 'Disabled'
Add-FakeAdapter 'PortB' 11 'AA-BB-CC-DD-EE-02' 'Up' `$true 'Enabled'
Add-FakeIp 10 '10.0.0.50' 24 'Manual'
Add-FakeRoute 10 '10.0.0.1' @('ActiveStore', 'PersistentStore')
`$global:Fake.Dns[10] = @('10.0.0.2')
`$ops = New-GuardRealOps
`$item = [pscustomobject]@{ id = 'n'; kind = 'nic-static'; management = `$true; move = `$true; mac = 'aabbccddee02'; ip = '10.0.0.50'; prefix = 24; gateway = '10.0.0.1'; dns = @('10.0.0.2', '10.0.0.3') }
`$cfgMove = [pscustomobject]@{ expect = [pscustomobject]@{ mac = 'aabbccddee02'; currentIp = '10.0.0.50' }; items = @(`$item) }
`$cfgPlain = [pscustomobject]@{ expect = [pscustomobject]@{ mac = 'aabbccddee02'; currentIp = '10.0.0.50' }; items = @([pscustomobject]@{ id = 'n'; kind = 'nic-static'; management = `$true; mac = 'aabbccddee02'; ip = '10.0.0.50'; prefix = 24 }) }
`$topoMove = [string](& `$ops.CheckTopology `$cfgMove)
`$topoPlain = [string](& `$ops.CheckTopology `$cfgPlain)
`$snap = & `$ops.SnapshotItem `$item
& `$ops.ApplyItem `$item
`$after = @{ aIps = @(Get-NetIPAddress -InterfaceIndex 10).Count; aRoutes = @(Get-NetRoute -InterfaceIndex 10).Count; aDns = @(`$global:Fake.Dns[10]).Count
    bIps = @(Get-NetIPAddress -InterfaceIndex 11 -IPAddress '10.0.0.50').Count; bPersistent = @(Get-NetRoute -InterfaceIndex 11 -PolicyStore PersistentStore).Count; bDns = @(`$global:Fake.Dns[11]) }
& `$ops.RestoreItem `$item `$snap
`$result = @{ topoMove = `$topoMove; topoPlain = `$topoPlain; from = @(`$snap.from).Count; after = `$after
    restored = @{ aIps = @(Get-NetIPAddress -InterfaceIndex 10 -IPAddress '10.0.0.50').Count; aRoutes = @(Get-NetRoute -InterfaceIndex 10).Count; aDns = @(`$global:Fake.Dns[10]); bIps = @(Get-NetIPAddress -InterfaceIndex 11 -IPAddress '10.0.0.50').Count } }
"@
        $r.topoMove | Should -Be ''
        $r.topoPlain | Should -Match 'another interface'
        $r.from | Should -Be 1
        $r.after.aIps | Should -Be 0
        $r.after.aRoutes | Should -Be 0
        $r.after.aDns | Should -Be 0
        $r.after.bIps | Should -Be 1
        $r.after.bPersistent | Should -Be 1
        @($r.after.bDns) | Should -Be @('10.0.0.2', '10.0.0.3')
        $r.restored.aIps | Should -Be 1
        $r.restored.aRoutes | Should -Be 1
        @($r.restored.aDns) | Should -Be @('10.0.0.2')
        $r.restored.bIps | Should -Be 0
    }
}

Describe 'The Apply payload counts a port as configured only when everything matches' {
    BeforeAll {
        $script:StaticAction = @{ id = 'n'; kind = 'nic-static'; management = $true; mac = 'aabbccddee01'; ip = '10.0.0.60'; prefix = 24; gateway = '10.0.0.1'; dns = @('10.0.0.2', '10.0.0.3') }
        function New-Setup([string]$Dhcp = 'Disabled', [string[]]$Stores = @('ActiveStore', 'PersistentStore'), [string]$Dns = "@('10.0.0.2', '10.0.0.3')", [string]$Status = 'Up', [string]$Cabled = '$true') {
            $storeText = ($Stores | ForEach-Object { "'$_'" }) -join ', '
            return "Add-FakeAdapter 'Port0' 10 'AA-BB-CC-DD-EE-01' '$Status' $Cabled '$Dhcp'`nAdd-FakeIp 10 '10.0.0.60' 24 'Manual'`nAdd-FakeRoute 10 '10.0.0.1' @($storeText)`n`$global:Fake.Dns[10] = $Dns"
        }
    }
    It 'everything matches (address, prefix, Manual, DHCP off, persistent route, both DNS servers): already configured, <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodePayload $Exe (New-Setup) @($script:StaticAction)
        $r.results[0].status | Should -Be 'changed'
        $r.results[0].detail | Should -Match 'already 10.0.0.60'
    }
    It 'DHCP still enabled on the port: not configured, it is configured again: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodePayload $Exe (New-Setup -Dhcp 'Enabled') @($script:StaticAction)
        $r.results[0].detail | Should -Not -Match 'already'
        $r.results[0].detail | Should -Match 'static 10.0.0.60'
    }
    It 'a DNS server missing: only the name servers are set, <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodePayload $Exe (New-Setup -Dns "@('10.0.0.2')") @($script:StaticAction)
        $r.results[0].detail | Should -Match 'DNS 10.0.0.2,10.0.0.3 set'
    }
    It 'a default route that is not persistent: not configured, <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodePayload $Exe (New-Setup -Stores @('ActiveStore')) @($script:StaticAction)
        $r.results[0].detail | Should -Match 'static 10.0.0.60'
    }
    It 'a Disabled management port without a link reports NoCarrier, <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodePayload $Exe (New-Setup -Status 'Disabled' -Cabled '$false') @($script:StaticAction)
        $r.results[0].status | Should -Be 'failed'
        $r.results[0].detail | Should -Match '^NoCarrier'
    }
    It 'a port that is not there reports AdapterMissing, <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodePayload $Exe "Add-FakeAdapter 'Other' 11 'AA-BB-CC-DD-EE-09'" @($script:StaticAction)
        $r.results[0].detail | Should -Match '^AdapterMissing'
    }
}
