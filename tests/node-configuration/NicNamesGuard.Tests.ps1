#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The REAL node operations of the NicNames rename inside the guarded change (nic-rename), run in a child process (PowerShell 7 and, when installed, Windows PowerShell
# 5.1, the node's shell) against an in-memory fake of Get-NetAdapter and Rename-NetAdapter. Nothing here touches this machine's network configuration.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/NicNamesGuard.Tests.ps1
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
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration', 'AzlNodeGuard.psm1')) -Force

    $script:Stubs = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$global:Fake = @{ Adapters = (New-Object System.Collections.ArrayList); Renames = (New-Object System.Collections.ArrayList); FailOn = '' }
function Add-FakeAdapter([string]$Name, [string]$Mac) { [void]$global:Fake.Adapters.Add((New-Object psobject -Property @{ Name = $Name; MacAddress = $Mac; PermanentAddress = $Mac; ifIndex = (10 + $global:Fake.Adapters.Count) })) }
function Get-NetAdapter { [CmdletBinding()] param([switch]$Physical, [string]$Name) foreach ($a in @($global:Fake.Adapters)) { if (-not $Name -or $a.Name -eq $Name) { $a } } }
function Rename-NetAdapter {
    [CmdletBinding(SupportsShouldProcess)] param([string]$Name, [string]$NewName)
    if ($global:Fake.FailOn -eq $NewName) { throw 'Rename-NetAdapter : simulated failure' }
    $hit = @($global:Fake.Adapters | Where-Object { $_.Name -eq $Name })
    if ($hit.Count -eq 0) { throw ('No adapter named ' + $Name) }
    if (@($global:Fake.Adapters | Where-Object { $_.Name -ieq $NewName -and $_.MacAddress -ne $hit[0].MacAddress }).Count) { throw ('Rename-NetAdapter : the name ' + $NewName + ' already exists') }
    [void]$global:Fake.Renames.Add($Name + '->' + $NewName)
    $hit[0].Name = $NewName
}
function New-RenameItem([string]$Mac, [string]$Name) { New-Object psobject -Property @{ id = ('NicNames/' + $Mac); kind = 'nic-rename'; mac = $Mac; name = $Name } }
function Get-FakeNames { return @($global:Fake.Adapters | ForEach-Object { $_.Name + '=' + $_.MacAddress.Replace('-', '').ToLower() }) }
'@

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
}

Describe 'The helpers of the rename exist at the top level of the engine' {
    It 'defines Set-GuardAdapterName and Get-GuardNameHolder as top level functions' {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-AzlGuardEngine), [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $all = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        foreach ($name in 'Set-GuardAdapterName', 'Get-GuardNameHolder') { $all.Name | Should -Contain $name }
    }
}

Describe 'nic-rename: the node operations' {
    It 'renames the adapter found by MAC, whatever its name and brand: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'Ethernet 5' 'AA-BB-CC-DD-EE-01'
Add-FakeAdapter 'SLOT 3 Port 1' 'AA-BB-CC-DD-EE-02'
`$ops = New-GuardRealOps
`$item = New-RenameItem 'aabbccddee02' 'Storage1'
`$snap = & `$ops.SnapshotItem `$item
& `$ops.ApplyItem `$item
`$result = @{ names = @(Get-FakeNames); renames = @(`$global:Fake.Renames); snapName = `$snap.name; snapMac = `$snap.mac }
"@
        @($r.names) | Should -Be @('Ethernet 5=aabbccddee01', 'Storage1=aabbccddee02')
        @($r.renames) | Should -Be @('SLOT 3 Port 1->Storage1')
        $r.snapName | Should -Be 'SLOT 3 Port 1'
        $r.snapMac | Should -Be 'aabbccddee02'
    }

    It 'is idempotent: an adapter that already has the name is not renamed again: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'Storage1' 'AA-BB-CC-DD-EE-02'
`$ops = New-GuardRealOps
& `$ops.ApplyItem (New-RenameItem 'aabbccddee02' 'Storage1')
& `$ops.ApplyItem (New-RenameItem 'aabbccddee02' 'storage1')
`$result = @{ names = @(Get-FakeNames); renames = @(`$global:Fake.Renames) }
"@
        @($r.names) | Should -Be @('Storage1=aabbccddee02')
        @($r.renames).Count | Should -Be 0
    }

    It 'swaps two names through a temporary name and ends with the wanted names: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'X' 'AA-BB-CC-DD-EE-01'
Add-FakeAdapter 'Y' 'AA-BB-CC-DD-EE-02'
`$ops = New-GuardRealOps
`$a = New-RenameItem 'aabbccddee01' 'Y'
`$b = New-RenameItem 'aabbccddee02' 'X'
& `$ops.ApplyItem `$a
& `$ops.ApplyItem `$b
`$result = @{ names = @(Get-FakeNames); renames = @(`$global:Fake.Renames) }
"@
        @($r.names) | Should -Be @('Y=aabbccddee01', 'X=aabbccddee02')
        @($r.renames)[0] | Should -Be 'Y->AzlTmp-aabbccddee02'
        @($r.renames).Count | Should -Be 3
    }

    It 'a failed apply is restored from the snapshots: every adapter gets its old name back, also the one moved out of the way: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'X' 'AA-BB-CC-DD-EE-01'
Add-FakeAdapter 'Y' 'AA-BB-CC-DD-EE-02'
`$ops = New-GuardRealOps
`$a = New-RenameItem 'aabbccddee01' 'Y'
`$b = New-RenameItem 'aabbccddee02' 'X'
`$snapA = & `$ops.SnapshotItem `$a
`$snapB = & `$ops.SnapshotItem `$b
& `$ops.ApplyItem `$a
`$global:Fake.FailOn = 'X'
`$failed = `$false
try { & `$ops.ApplyItem `$b } catch { `$failed = `$true }
`$global:Fake.FailOn = ''
& `$ops.RestoreItem `$b `$snapB | Out-Null
& `$ops.RestoreItem `$a `$snapA | Out-Null
`$result = @{ names = @(Get-FakeNames); failed = `$failed }
"@
        $r.failed | Should -BeTrue
        @($r.names) | Should -Be @('X=aabbccddee01', 'Y=aabbccddee02')
    }

    It 'throws, and changes nothing, when a name is held by something that is not a physical adapter it may move: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'Old' 'AA-BB-CC-DD-EE-01'
`$ops = New-GuardRealOps
`$global:Fake.FailOn = 'New'
`$threw = `$false
try { & `$ops.ApplyItem (New-RenameItem 'aabbccddee01' 'New') } catch { `$threw = `$true }
`$result = @{ names = @(Get-FakeNames); threw = `$threw }
"@
        $r.threw | Should -BeTrue
        @($r.names) | Should -Be @('Old=aabbccddee01')
    }

    It 'throws for a MAC that no adapter has: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'Old' 'AA-BB-CC-DD-EE-01'
`$ops = New-GuardRealOps
`$msg = ''
try { & `$ops.ApplyItem (New-RenameItem 'aabbccddee99' 'New') } catch { `$msg = `$_.Exception.Message }
`$result = @{ msg = `$msg; names = @(Get-FakeNames) }
"@
        $r.msg | Should -Match 'No port with MAC'
        @($r.names) | Should -Be @('Old=aabbccddee01')
    }

    It 'the ports check passes when the adapter has the new name and fails when it does not: <Label>' -ForEach $script:NodeHosts {
        $r = Invoke-NodeHarness $Exe @"
Add-FakeAdapter 'Storage1' 'AA-BB-CC-DD-EE-01'
Add-FakeAdapter 'Port2' 'AA-BB-CC-DD-EE-02'
`$ops = New-GuardRealOps
`$good = & `$ops.CheckPorts @{ items = @((New-RenameItem 'aabbccddee01' 'Storage1')) }
`$bad = & `$ops.CheckPorts @{ items = @((New-RenameItem 'aabbccddee02' 'Storage2')) }
`$none = & `$ops.CheckPorts @{ items = @() }
`$result = @{ good = `$good.ok; bad = `$bad.ok; badDetail = `$bad.detail; noneSkipped = [bool]`$none.skipped }
"@
        $r.good | Should -BeTrue
        $r.bad | Should -BeFalse
        $r.badDetail | Should -Match 'aabbccddee02 is not named Storage2'
        $r.noneSkipped | Should -BeTrue
    }
}

Describe 'nic-rename: the node refuses what it should' {
    BeforeAll {
        # The engine in this process, with fake operations (as NodeGuard.Tests.ps1 does).
        $script:EngineFile = Join-Path $TestDrive 'engine.ps1'
        Set-Content -LiteralPath $script:EngineFile -Value (Get-AzlGuardEngine)
        . $script:EngineFile
        Set-GuardOps @{ CheckTopology = { '' } }
        function New-Cfg([object[]]$Items) {
            [pscustomobject]@{ expect = [pscustomobject]@{ mac = 'aabbccddee01'; ip = '10.0.0.60'; requireGateway = $true; winrm = $true }; items = @($Items) }
        }
        $script:Nics = @(
            [pscustomobject]@{ mac = 'aabbccddee01'; name = 'Port0'; gw = @('10.0.0.1'); metric = 25; ips = @() }
            [pscustomobject]@{ mac = 'aabbccddee02'; name = 'Port1'; gw = @(); metric = 9999; ips = @() })
    }
    It 'accepts a usable name' {
        $item = [pscustomobject]@{ id = 'NicNames/aabbccddee02'; kind = 'nic-rename'; mac = 'aabbccddee02'; name = 'Storage 1' }
        (Get-GuardRefusal (New-Cfg @($item)) $script:Nics) | Should -Be ''
    }
    It 'refuses an unusable name: <_>' -ForEach @('', 'a/b', 'a:b', '-lead', 'x*y', ('n' * 70)) {
        $item = [pscustomobject]@{ id = 'NicNames/aabbccddee02'; kind = 'nic-rename'; mac = 'aabbccddee02'; name = $_ }
        (Get-GuardRefusal (New-Cfg @($item)) $script:Nics) | Should -Match 'not a usable adapter name'
    }
    It 'refuses while no port has the management MAC' {
        $item = [pscustomobject]@{ id = 'NicNames/aabbccddee02'; kind = 'nic-rename'; mac = 'aabbccddee02'; name = 'Storage1' }
        (Get-GuardRefusal (New-Cfg @($item)) @($script:Nics | Where-Object mac -ne 'aabbccddee01')) | Should -Match 'No port has the management MAC'
    }
    It 'lets the management adapter itself be renamed (its address stays with the interface)' {
        $item = [pscustomobject]@{ id = 'NicNames/aabbccddee01'; kind = 'nic-rename'; mac = 'aabbccddee01'; name = 'Mgmt1' }
        (Get-GuardRefusal (New-Cfg @($item)) $script:Nics) | Should -Be ''
    }
}
