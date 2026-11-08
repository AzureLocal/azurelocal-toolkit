#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the DomainJoin node scripts (text for Windows PowerShell 5.1). They run in a child Windows PowerShell 5.1 (powershell.exe) when
# there is one, else in pwsh, with every command that would touch the machine, the network or Active Directory REPLACED by a mock
# function (Add-Computer, Get-CimInstance, Resolve-DnsName, the scheduled task commands, shutdown.exe, ADSI, ...). The state folder is a
# test folder. No domain controller and no node is contacted; nothing is joined, restarted or registered.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/DomainJoinNode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $script:HasPs51 = [bool](Get-Command powershell.exe -ErrorAction SilentlyContinue)
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $nc = [IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration')
    Import-Module (Join-Path $nc 'AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $nc 'AzlNodeTransport.psm1') -Force
    $script:Password = 'Zq9!SentinelJoinPw-4711'
    $ps51 = Get-Command powershell.exe -ErrorAction SilentlyContinue
    $script:Shell = if ($ps51) { $ps51.Source } else { (Get-Command pwsh).Source }
    $script:Is51 = [bool]$ps51

    # The mocks. Scenario switches come from $Scenario (a hashtable read from scenario.json). Every call is logged to calls.log WITHOUT the password.
    $script:Mocks = @'
$ErrorActionPreference = 'Stop'
$Scenario = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'scenario.json') -Raw | ConvertFrom-Json
function Add-Call([string]$Text) { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'calls.log') -Value $Text }
function Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName)
    if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ Name = $Scenario.computerName; PartOfDomain = [bool]$Scenario.partOfDomain; Domain = $Scenario.domain } }
    if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ LastBootUpTime = [datetime]::Parse($Scenario.boot).ToUniversalTime() } }
    throw "unexpected CIM class $ClassName"
}
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$Path, [string]$Name)
    Add-Call "Get-ItemProperty $Name"
    if ($Name -eq 'Distinguished-Name' -and $Scenario.dn) { return [pscustomobject]@{ 'Distinguished-Name' = $Scenario.dn } }
    throw 'not found'
}
function Get-Service { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name) if ($Scenario.inCluster) { return [pscustomobject]@{ Status = 'Running' } }; return $null }
function Test-Path {
    param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath)
    if ($Path -like 'HKLM:*') { return [bool]($Scenario.inCluster -and $Path -eq 'HKLM:\Cluster') }
    if ($Path -eq 'function:Test-DjTcp') { return $true }
    if ($LiteralPath) { return Microsoft.PowerShell.management\Test-Path -LiteralPath $LiteralPath }
    return Microsoft.PowerShell.management\Test-Path -Path $Path
}
function Test-DjTcp { [CmdletBinding()] param([string]$Address, [int]$Port, [int]$Milliseconds) Add-Call "tcp $Address $Port"; return [bool]$Scenario.dcReachable }
function Resolve-DnsName {
    [CmdletBinding()]
    param([string]$Name, [string]$Type, [switch]$DnsOnly)
    Add-Call "Resolve-DnsName $Type $Name"
    if ($Type -eq 'A') { if (-not $Scenario.dnsOk) { throw 'DNS name does not exist' }; return @([pscustomobject]@{ IPAddress = '192.0.2.4' }) }
    if ($Type -eq 'SRV') { if (-not $Scenario.srvOk) { throw 'no SRV' }; return @([pscustomobject]@{ NameTarget = 'dc1.improbability.cloud'; Type = 'SRV' }) }
}
function w32tm.exe { Add-Call "w32tm $args"; 'Tracking dc1.improbability.cloud'; 'The current time is 11/7/2026 3:00:00 PM.'; ('15:00:00, ' + $Scenario.skewText) }
function Test-ComputerSecureChannel { [CmdletBinding()] param() Add-Call 'Test-ComputerSecureChannel'; return [bool]$Scenario.secureChannel }
function net.exe { Add-Call "net.exe $args"; 'Alias name     Administrators'; 'Comment        Administrators have complete access'; 'Members'; '-------'; foreach ($m in $Scenario.localAdmins) { $m }; 'The command completed successfully.' }
function Add-LocalGroupMember {
    [CmdletBinding()]
    param([string]$Group, [string]$Member)
    Add-Call "Add-LocalGroupMember $Group $Member"
    if ($Scenario.failMember -and $Member -like $Scenario.failMember) { throw "Principal $Member was not found." }
}
function Add-Computer {
    [CmdletBinding()]
    param([string]$DomainName, [string]$OUPath, [pscredential]$Credential, [switch]$Force, [switch]$Restart)
    $matches = ($Credential.GetNetworkCredential().Password -eq $Scenario.expectedPassword)
    Add-Call "Add-Computer DomainName=$DomainName OUPath=$OUPath User=$($Credential.UserName) PasswordMatches=$matches Restart=$($Restart.IsPresent) Force=$($Force.IsPresent)"
    if ($Scenario.addComputerCode) {
        $inner = New-Object System.ComponentModel.Win32Exception([int]$Scenario.addComputerCode)
        throw (New-Object System.InvalidOperationException($Scenario.addComputerMessage, $inner))
    }
    if ($Scenario.addComputerMessage) { throw (New-Object System.InvalidOperationException($Scenario.addComputerMessage)) }
}
function New-ScheduledTaskAction { [CmdletBinding()] param($Execute, $Argument) Add-Call "New-ScheduledTaskAction $Execute $Argument"; 'action' }
function New-ScheduledTaskTrigger { [CmdletBinding()] param([switch]$AtStartup) Add-Call "New-ScheduledTaskTrigger AtStartup=$($AtStartup.IsPresent)"; 'trigger' }
function New-ScheduledTaskPrincipal { [CmdletBinding()] param($UserId, $LogonType, $RunLevel) Add-Call "New-ScheduledTaskPrincipal $UserId $RunLevel"; 'principal' }
function Register-ScheduledTask { [CmdletBinding()] param($TaskName, $Action, $Trigger, $Principal, [switch]$Force) Add-Call "Register-ScheduledTask $TaskName"; 'task' }
function Unregister-ScheduledTask { [CmdletBinding()] param($TaskName, [switch]$Confirm) Add-Call "Unregister-ScheduledTask $TaskName" }
function shutdown.exe { Add-Call "shutdown.exe $args" }
function Start-Sleep { [CmdletBinding()] param($Seconds) Add-Call "Start-Sleep $Seconds" }
function New-Object {
    param([Parameter(Position = 0)][string]$TypeName, [Parameter(Position = 1)]$ArgumentList)
    if ($TypeName -like '*DirectoryEntry') {
        $path = [string]$ArgumentList[0]
        Add-Call "DirectoryEntry $path user=$($ArgumentList[1])"
        $entry = Microsoft.PowerShell.Utility\New-Object psobject
        Add-Member -InputObject $entry -MemberType NoteProperty -Name Path -Value $path
        $bag = @{ gPOptions = @(); gPLink = @() }
        foreach ($p in $Scenario.ldap.PSObject.Properties) {
            if ($path -like ('*/' + $p.Name)) { foreach ($q in $p.Value.PSObject.Properties) { $bag[$q.Name] = @($q.Value) } }
        }
        Add-Member -InputObject $entry -MemberType NoteProperty -Name Properties -Value $bag
        Add-Member -InputObject $entry -MemberType ScriptMethod -Name MoveTo -Value { param($target) Add-Call ('MoveTo ' + $target.Path); if ($Scenario.moveFails) { throw 'Access is denied.' } }
        Add-Member -InputObject $entry -MemberType ScriptMethod -Name RefreshCache -Value {
            param($names)
            if ($Scenario.authFails) { throw (New-Object System.Runtime.InteropServices.COMException($Scenario.authFailsMessage, [int]$Scenario.authFailsHResult)) }
            if ($Scenario.ouMissing -and $this.Path -like ('*/' + $Scenario.ouPath)) { throw 'There is no such object on the server.' }
        }
        return $entry
    }
    if ($null -ne $ArgumentList) { return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList }
    return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName
}
function Test-DjMockInstalled { $true }
foreach ($required in 'Add-Computer', 'shutdown.exe', 'Register-ScheduledTask', 'Get-CimInstance', 'New-Object') {
    if ((Get-Command $required).CommandType -ne 'Function') { throw "safety stop: $required is not mocked" }
}
'@

    # Runs one node script with the mocks. $Scenario overrides the defaults. Returns the decoded answer, the calls and the state folder.
    function Invoke-DjNode {
        param([string]$Payload, [hashtable]$Params = @{}, [hashtable]$Secrets = @{}, [hashtable]$Scenario = @{}, [string]$StateDir)
        $dir = Join-Path $TestDrive ("run-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $dir
        $state = if ($StateDir) { $StateDir } else { Join-Path $dir 'state' }
        $sc = @{
            computerName = 'iic-n01'; partOfDomain = $false; domain = 'WORKGROUP'; boot = '2026-11-07T10:00:00Z'; dn = ''; inCluster = $false
            dnsOk = $true; srvOk = $true; dcReachable = $true; skewText = '+00.0004120s'; secureChannel = $true; localAdmins = @('azl-admin', 'Administrator')
            expectedPassword = $script:Password; ouPath = 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'; ldap = @{}
            addComputerCode = 0; addComputerMessage = ''; failMember = ''; moveFails = $false; ouMissing = $false
            authFails = $false; authFailsMessage = 'Logon failure: unknown user name or bad password.'; authFailsHResult = -2147023570
            registerFails = $false; setContentFails = $false; shutdownExit = 0; dnAfterGpupdate = ''; icaclsExit = 0; memberExists = ''
        }
        foreach ($k in $Scenario.Keys) { $sc[$k] = $Scenario[$k] }
        ($sc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $dir 'scenario.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'payload.ps1') -Value (Get-AzlNodePayload -Name $Payload) -Encoding UTF8
        $p = @{ stateDir = $state } + $Params
        $pb = ConvertTo-AzlB64Json $p
        $sb = ConvertTo-AzlB64Json $Secrets
        Set-Content -LiteralPath (Join-Path $dir 'wrapper.ps1') -Encoding UTF8 -Value ($script:Mocks + @"

`$text = Get-Content -LiteralPath (Join-Path `$PSScriptRoot 'payload.ps1') -Raw
`$out = & ([scriptblock]::Create(`$text)) -ParamsB64 '$pb' -SecretsB64 '$sb'
(`$out -join [Environment]::NewLine) | Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'out.txt') -Encoding UTF8
"@)
        # A pending shutdown (should the mock ever not apply) is cancelled afterwards; the mocks are also asserted before the payload runs.
        $output = & $script:Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'wrapper.ps1') 2>&1
        $exit = $LASTEXITCODE
        $outFile = Join-Path $dir 'out.txt'
        $calls = if (Test-Path -LiteralPath (Join-Path $dir 'calls.log')) { @(Get-Content -LiteralPath (Join-Path $dir 'calls.log')) } else { @() }
        [pscustomobject]@{
            Dir = $dir; State = $state; Exit = $exit; Console = ($output -join "`n"); Calls = $calls
            Answer = $(if (Test-Path -LiteralPath $outFile) { ConvertTo-AzlNodeResult -Text (Get-Content -LiteralPath $outFile -Raw) } else { $null })
            Marker = $(if (Test-Path -LiteralPath (Join-Path $state 'domainjoin-state.json')) { try { Get-Content -LiteralPath (Join-Path $state 'domainjoin-state.json') -Raw | ConvertFrom-Json } catch { $null } } else { $null })
        }
    }
    function ConvertTo-AzlB64Json([AllowNull()][object]$Value) {
        if ($null -eq $Value) { return '' }
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 20 -Compress)))
    }
    function Get-JoinParam([hashtable]$More = @{}) {
        $base = @{ mode = 'join'; domain = 'improbability.cloud'; netbios = 'IIC'; ou = 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'; changeId = 'chg1'; expectedHost = 'iic-n01'; resumeScript = '# resume' }
        foreach ($k in $More.Keys) { $base[$k] = $More[$k] }
        $base
    }
    $script:Secret = @{ joinUser = 'lcm-iic-clus01'; joinPassword = 'Zq9!SentinelJoinPw-4711' }
}

AfterAll {
    # Belt and braces: nothing in these tests may leave a shutdown pending on this machine.
    $null = & shutdown.exe /a 2>&1
}

Describe 'The DomainJoin scripts are text for Windows PowerShell 5.1' {
    It '<_> parses and uses no PowerShell 7 syntax (no ternary, ??, ?., &&, ||)' -ForEach @('Read', 'DomainJoinProbe', 'DomainJoinApply', 'DomainJoinOuCheck', 'DomainJoinRestart', 'DomainJoinResume') {
        $text = Get-AzlNodePayload -Name $_
        $errors = $null; $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $bad = @($tokens | Where-Object { $_.Kind -in 'AndAnd', 'OrOr', 'QuestionQuestion', 'QuestionDot', 'QuestionMark', 'QuestionQuestionEquals' })
        $bad | Should -BeNullOrEmpty
        @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true)) | Should -BeNullOrEmpty
        @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Remove-Computer', 'Rename-Computer', 'Restart-Computer', 'Stop-Computer' }, $true)) | Should -BeNullOrEmpty -Because 'the scripts never unjoin, rename or restart the node directly'
    }
    It 'the Read script asks for the membership only when the plan passed domainJoin, and returns it as domainJoin' {
        $text = Get-AzlNodePayload -Name Read
        $text | Should -Match "Get-P \`$P 'domainJoin'"
        $text | Should -Match 'domainJoin = \$Az\.domainJoin'
        $text | Should -Not -Match '#AZL-HOOK'
    }
    It 'the scripts do not contain the words that the fake transport of the other tests uses to recognise Apply, Collect and Restart' {
        foreach ($n in 'DomainJoinProbe', 'DomainJoinApply', 'DomainJoinOuCheck', 'DomainJoinResume') {
            (Get-AzlNodePayload -Name $n) | Should -Not -Match 'function Invoke-Action|last-apply'
        }
    }
}

Describe 'The harness' {
    It 'runs the node scripts in Windows PowerShell 5.1 when this machine has it' -Skip:(-not $script:HasPs51) {
        $dir = Join-Path $TestDrive 'ver'
        $null = New-Item -ItemType Directory -Path $dir
        Set-Content -LiteralPath (Join-Path $dir 'v.ps1') -Value '$PSVersionTable.PSVersion.Major'
        (& $script:Shell -NoProfile -File (Join-Path $dir 'v.ps1')) | Should -Be 5
    }
}

Describe 'Probe: the membership, read only' {
    It 'a workgroup node: not a member, DNS, SRV, a controller, the skew, no secure channel, the name' {
        $r = Invoke-DjNode -Payload DomainJoinProbe -Params @{ domain = 'improbability.cloud'; dcs = @('192.0.2.4') }
        $r.Exit | Should -Be 0 -Because $r.Console
        $d = $r.Answer.domainJoin
        $d.partOfDomain | Should -BeFalse
        $d.domain | Should -Be 'WORKGROUP'
        $d.host | Should -Be 'iic-n01'
        $d.dnsOk | Should -BeTrue
        $d.srvOk | Should -BeTrue
        $d.dcReachable | Should -BeTrue
        $d.dcUsed | Should -Be '192.0.2.4'
        $d.skewSeconds | Should -BeGreaterThan 0.0003
        $d.skewSeconds | Should -BeLessThan 0.001
        $d.secureChannel | Should -BeNullOrEmpty
        $d.inCluster | Should -BeFalse
        $d.localAdmins | Should -Contain 'azl-admin'
        $d.localAdmins | Should -Not -Contain 'Members'
        $r.Calls | Should -Not -Contain 'Test-ComputerSecureChannel'
        @($r.Calls | Where-Object { $_ -like 'Add-Computer*' -or $_ -like 'shutdown*' -or $_ -like 'Register*' }) | Should -BeNullOrEmpty
    }
    It 'a member: the distinguished name from Group Policy state, the secure channel, the cluster flag' {
        $dn = 'CN=iic-n01,OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $r = Invoke-DjNode -Payload DomainJoinProbe -Params @{ domain = 'improbability.cloud'; dcs = @('192.0.2.4') } -Scenario @{ partOfDomain = $true; domain = 'improbability.cloud'; dn = $dn; inCluster = $true }
        $d = $r.Answer.domainJoin
        $d.partOfDomain | Should -BeTrue
        $d.dn | Should -Be $dn
        $d.secureChannel | Should -BeTrue
        $d.inCluster | Should -BeTrue
    }
    It 'DNS failure and no controller: reported, not thrown' {
        $r = Invoke-DjNode -Payload DomainJoinProbe -Params @{ domain = 'improbability.cloud'; dcs = @('192.0.2.4') } -Scenario @{ dnsOk = $false; srvOk = $false; dcReachable = $false }
        $d = $r.Answer.domainJoin
        $d.dnsOk | Should -BeFalse
        $d.dnsError | Should -Match 'does not exist'
        $d.srvOk | Should -BeFalse
        $d.dcReachable | Should -BeFalse
        $d.dcUsed | Should -BeNullOrEmpty
        $d.skewSeconds | Should -BeNullOrEmpty
    }
    It 'reads the skew as an absolute number of seconds' {
        $d = (Invoke-DjNode -Payload DomainJoinProbe -Params @{ domain = 'improbability.cloud'; dcs = @('192.0.2.4') } -Scenario @{ skewText = '-312.5000000s' }).Answer.domainJoin
        $d.skewSeconds | Should -Be 312.5
    }
    It 'reads the restart marker' {
        $dir = Join-Path $TestDrive 'marker-state'
        $null = New-Item -ItemType Directory -Path $dir
        '{"state":"RebootExpected","changeId":"c9","bootBefore":"2026-11-07T10:00:00Z","domain":"improbability.cloud","error":""}' | Set-Content -LiteralPath (Join-Path $dir 'domainjoin-state.json')
        $d = (Invoke-DjNode -Payload DomainJoinProbe -Params @{ domain = 'improbability.cloud' } -StateDir $dir).Answer.domainJoin
        $d.marker.state | Should -Be 'RebootExpected'
        $d.marker.changeId | Should -Be 'c9'
    }
    It 'falls back to the marker copy when the marker is unreadable' {
        $dir = Join-Path $TestDrive 'marker-state2'
        $null = New-Item -ItemType Directory -Path $dir
        'not json {' | Set-Content -LiteralPath (Join-Path $dir 'domainjoin-state.json')
        '{"state":"Restarting","changeId":"c1","bootBefore":"b","domain":"d","error":""}' | Set-Content -LiteralPath (Join-Path $dir 'domainjoin-state.json.bak')
        (Invoke-DjNode -Payload DomainJoinProbe -Params @{ domain = 'd' } -StateDir $dir).Answer.domainJoin.marker.state | Should -Be 'Restarting'
    }
    It 'the Read script embeds the same section (runs the Read script with its other sections mocked away is not needed: the function is the same text)' {
        (Get-AzlNodePayload -Name Read) | Should -Match 'function Get-DjRead'
        (Get-AzlNodePayload -Name DomainJoinProbe) | Should -Match 'function Get-DjRead'
    }
}

Describe 'Apply: join' {
    It 'joins with Add-Computer -DomainName -OUPath -Credential, -Restart:false, from a secure string, and leaves a durable restart marker' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets $script:Secret
        $r.Exit | Should -Be 0 -Because $r.Console
        $r.Answer.status | Should -Be 'joined'
        $r.Answer.reboot | Should -BeTrue
        $join = @($r.Calls | Where-Object { $_ -like 'Add-Computer*' })
        $join.Count | Should -Be 1
        $join[0] | Should -Match 'DomainName=improbability.cloud'
        $join[0] | Should -Match 'OUPath=OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $join[0] | Should -Match 'User=IIC\\lcm-iic-clus01'
        $join[0] | Should -Match 'PasswordMatches=True'
        $join[0] | Should -Match 'Restart=False'
        $r.Marker.state | Should -Be 'RebootExpected'
        $r.Marker.changeId | Should -Be 'chg1'
        ([datetime]$r.Marker.bootBefore).ToUniversalTime().ToString('s') | Should -Be '2026-11-07T10:00:00'
        $r.Marker.domain | Should -Be 'improbability.cloud'
        Test-Path (Join-Path $r.State 'domainjoin-state.json.tmp') | Should -BeFalse
        @($r.Calls | Where-Object { $_ -like 'shutdown*' }) | Should -BeNullOrEmpty -Because 'Apply never restarts; the guarded restart is its own script'
    }
    It 'registers a one-time startup task for the resume script, as SYSTEM, and writes the script (without any secret)' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam @{ resumeScript = '# the resume script text' }) -Secrets $script:Secret
        $r.Calls | Should -Contain 'Register-ScheduledTask AzureLocal-OSConfig-DomainJoinResume'
        $r.Calls | Should -Contain 'New-ScheduledTaskTrigger AtStartup=True'
        ($r.Calls -join "`n") | Should -Match 'New-ScheduledTaskPrincipal SYSTEM Highest'
        (Get-Content -LiteralPath (Join-Path $r.State 'domainjoin-resume.ps1') -Raw) | Should -Match 'the resume script text'
    }
    It 'qualifies a plain user name with the NetBIOS name, and with the domain when there is none; keeps NETBIOS\name and name@domain as they are' {
        (Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets $script:Secret).Calls -join "`n" | Should -Match 'User=IIC\\lcm-iic-clus01'
        (Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam @{ netbios = '' }) -Secrets $script:Secret).Calls -join "`n" | Should -Match 'User=lcm-iic-clus01@improbability.cloud'
        (Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets @{ joinUser = 'CORP\svc'; joinPassword = $script:Password }).Calls -join "`n" | Should -Match 'User=CORP\\svc'
        (Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets @{ joinUser = 'svc@improbability.cloud'; joinPassword = $script:Password }).Calls -join "`n" | Should -Match 'User=svc@improbability.cloud'
    }
    It 'already a member of the domain: unchanged, no Add-Computer, no restart' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets $script:Secret -Scenario @{ partOfDomain = $true; domain = 'improbability.cloud' }
        $r.Answer.status | Should -Be 'unchanged'
        $r.Answer.reboot | Should -BeFalse
        @($r.Calls | Where-Object { $_ -like 'Add-Computer*' }) | Should -BeNullOrEmpty
    }
    It 'a member of a different domain: failed, never unjoined, no Add-Computer' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets $script:Secret -Scenario @{ partOfDomain = $true; domain = 'contoso.com' }
        $r.Answer.status | Should -Be 'failed'
        $r.Answer.errorText | Should -Match 'contoso.com'
        $r.Answer.nextAction | Should -Match 'Remove-Computer'
        @($r.Calls | Where-Object { $_ -like 'Add-Computer*' }) | Should -BeNullOrEmpty
    }
    It 'the computer name differs from the file: failed before anything is changed, a rename is never done' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets $script:Secret -Scenario @{ computerName = 'WIN-ABC123' }
        $r.Answer.status | Should -Be 'failed'
        $r.Answer.errorText | Should -Match 'WIN-ABC123'
        $r.Answer.nextAction | Should -Match 'Hostname step'
        @($r.Calls | Where-Object { $_ -like 'Add-Computer*' }) | Should -BeNullOrEmpty
        $r.Marker | Should -BeNullOrEmpty
        $r.Console | Should -Not -Match 'Rename-Computer'
    }
    It 'no credential was passed: failed with a clear message' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets @{}
        $r.Answer.status | Should -Be 'failed'
        $r.Answer.errorText | Should -Match 'No join account'
    }

    Context 'on a failure the node stays as it is and the exact AD error comes back, mapped, with a next action' {
        It 'maps <Name> (text only)' -ForEach @(
            @{ Name = '1326'; Message = "Computer 'iic-n01' failed to join domain 'improbability.cloud' from its current workgroup 'WORKGROUP' with following error message: The user name or password is incorrect."; Code = '1326'; Label = 'bad credential'; Next = 'domain_join_account|lcm' }
            @{ Name = '1355'; Message = 'Computer failed to join domain with following error message: The specified domain either does not exist or could not be contacted.'; Code = '1355'; Label = 'domain not found'; Next = 'DNS servers' }
            @{ Name = '2224'; Message = 'Computer failed to join domain with following error message: The account already exists.'; Code = '2224'; Label = 'account exists'; Next = 'computer object' }
            @{ Name = '5'; Message = 'Computer failed to join domain with following error message: Access is denied.'; Code = '5'; Label = 'access denied'; Next = 'Delegate' }
            @{ Name = '53'; Message = 'Computer failed to join domain with following error message: The network path was not found.'; Code = '53'; Label = 'network path not found'; Next = 'firewalls' }
            @{ Name = '1722'; Message = 'Computer failed to join domain with following error message: The RPC server is unavailable.'; Code = '1722'; Label = 'RPC server unavailable'; Next = 'RPC' }
            @{ Name = 'clock skew'; Message = 'The time difference between the client and server is too great (Kerberos clock skew).'; Code = '37'; Label = 'clock skew'; Next = 'time' }
            @{ Name = 'locked out'; Message = 'The referenced account is currently locked out and may not be logged on to.'; Code = '1909'; Label = 'account locked out'; Next = 'Unlock' }
            @{ Name = 'OU not found'; Message = 'Computer failed to join domain with following error message: There is no such object on the server.'; Code = '8240'; Label = 'OU not found'; Next = 'OU' }
        ) {
            $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets $script:Secret -Scenario @{ addComputerMessage = $Message }
            $r.Answer.status | Should -Be 'failed'
            $r.Answer.code | Should -Be $Code
            $r.Answer.label | Should -Be $Label
            $r.Answer.errorText | Should -Be $Message
            $r.Answer.nextAction | Should -Match $Next
            $r.Answer.stillWorkgroup | Should -BeTrue
            $r.Answer.reboot | Should -BeFalse
            $r.Marker.state | Should -Be 'JoinFailed'
            @($r.Calls | Where-Object { $_ -like 'Register-ScheduledTask*' -or $_ -like 'shutdown*' }) | Should -BeNullOrEmpty
        }
        It 'maps <Code> from the Win32 error code alone, whatever the language of the message' -ForEach @(
            @{ Code = 1326; Label = 'bad credential' }, @{ Code = 1355; Label = 'domain not found' }, @{ Code = 2224; Label = 'account exists' }, @{ Code = 5; Label = 'access denied' }, @{ Code = 53; Label = 'network path not found' }, @{ Code = 1722; Label = 'RPC server unavailable' }
        ) {
            $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets $script:Secret -Scenario @{ addComputerCode = $Code; addComputerMessage = 'Der Computer konnte der Domane nicht beitreten.' }
            $r.Answer.code | Should -Be ([string]$Code)
            $r.Answer.label | Should -Be $Label
        }
        It 'an unmapped error is passed on as it is, with a generic next action' {
            $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets $script:Secret -Scenario @{ addComputerMessage = 'Something entirely new happened.' }
            $r.Answer.status | Should -Be 'failed'
            $r.Answer.code | Should -Be ''
            $r.Answer.label | Should -Be 'not mapped'
            $r.Answer.errorText | Should -Be 'Something entirely new happened.'
            $r.Answer.nextAction | Should -Match 'node stays as it is'
        }
    }
}

Describe 'Apply: move, administrators, finalize' {
    It 'moves the computer object with ADSI and the credential, before the deployment' {
        $dn = 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud'
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam @{ mode = 'move'; dn = $dn; dc = '192.0.2.4' }) -Secrets $script:Secret -Scenario @{ partOfDomain = $true; domain = 'improbability.cloud' }
        $r.Answer.status | Should -Be 'moved'
        ($r.Calls -join "`n") | Should -Match 'DirectoryEntry LDAP://192.0.2.4/CN=iic-n01,OU=Elsewhere'
        ($r.Calls -join "`n") | Should -Match 'MoveTo LDAP://192.0.2.4/OU=iic-clus01'
        @($r.Calls | Where-Object { $_ -like 'Add-Computer*' }) | Should -BeNullOrEmpty
    }
    It 'a move that is refused is reported with the mapped error' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam @{ mode = 'move'; dn = 'CN=iic-n01,OU=Elsewhere,DC=improbability,DC=cloud'; dc = '192.0.2.4' }) -Secrets $script:Secret -Scenario @{ moveFails = $true }
        $r.Answer.status | Should -Be 'failed'
        $r.Answer.label | Should -Be 'access denied'
    }
    It 'adds the missing principals to the local Administrators group, and only those (idempotent)' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params @{ mode = 'admins'; members = @('IIC\sg-a', 'IIC\lcm-iic-clus01') } -Scenario @{ localAdmins = @('azl-admin', 'IIC\lcm-iic-clus01') }
        $r.Answer.status | Should -Be 'configured'
        @($r.Answer.added) | Should -Be @('IIC\sg-a')
        @($r.Calls | Where-Object { $_ -like 'Add-LocalGroupMember*' }) | Should -Be @('Add-LocalGroupMember Administrators IIC\sg-a')
        $again = Invoke-DjNode -Payload DomainJoinApply -Params @{ mode = 'admins'; members = @('IIC\sg-a') } -Scenario @{ localAdmins = @('azl-admin', 'IIC\sg-a') }
        $again.Answer.status | Should -Be 'configured'
        $again.Answer.detail | Should -Be 'already members'
        @($again.Calls | Where-Object { $_ -like 'Add-LocalGroupMember*' }) | Should -BeNullOrEmpty
    }
    It 'a principal that does not exist is reported with the exact error, the others are still added' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params @{ mode = 'admins'; members = @('IIC\ghost', 'IIC\sg-a') } -Scenario @{ failMember = '*ghost' }
        $r.Answer.status | Should -Be 'failed'
        $r.Answer.errorText | Should -Match 'ghost: Principal IIC\\ghost was not found'
        $r.Calls | Should -Contain 'Add-LocalGroupMember Administrators IIC\sg-a'
    }
    It 'finalize completes the marker and removes the resume task' {
        $dir = Join-Path $TestDrive 'fin-state'
        $null = New-Item -ItemType Directory -Path $dir
        '{"state":"RebootExpected","changeId":"c1","bootBefore":"2026-11-07T10:00:00Z","domain":"improbability.cloud","error":""}' | Set-Content -LiteralPath (Join-Path $dir 'domainjoin-state.json')
        $r = Invoke-DjNode -Payload DomainJoinApply -Params @{ mode = 'finalize'; domain = 'improbability.cloud'; ou = 'OU=x'; changeId = 'c1' } -StateDir $dir
        $r.Answer.status | Should -Be 'finalized'
        $r.Marker.state | Should -Be 'Completed'
        $r.Calls | Should -Contain 'Unregister-ScheduledTask AzureLocal-OSConfig-DomainJoinResume'
    }
}

Describe 'Restart: guarded by the marker' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive "rs-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $null = New-Item -ItemType Directory -Path $script:Dir
    }
    It 'refuses without a marker, and does not restart' {
        $r = Invoke-DjNode -Payload DomainJoinRestart -Params @{ changeId = 'c1' } -StateDir $script:Dir
        $r.Answer.restartScheduled | Should -BeFalse
        $r.Answer.reason | Should -Match 'No durable restart marker'
        @($r.Calls | Where-Object { $_ -like 'shutdown*' }) | Should -BeNullOrEmpty
    }
    It 'refuses a marker of another change, or a marker that is not RebootExpected' {
        '{"state":"RebootExpected","changeId":"other","bootBefore":"b","domain":"d","error":""}' | Set-Content -LiteralPath (Join-Path $script:Dir 'domainjoin-state.json')
        (Invoke-DjNode -Payload DomainJoinRestart -Params @{ changeId = 'c1' } -StateDir $script:Dir).Answer.restartScheduled | Should -BeFalse
        '{"state":"JoinFailed","changeId":"c1","bootBefore":"b","domain":"d","error":"x"}' | Set-Content -LiteralPath (Join-Path $script:Dir 'domainjoin-state.json')
        (Invoke-DjNode -Payload DomainJoinRestart -Params @{ changeId = 'c1' } -StateDir $script:Dir).Answer.restartScheduled | Should -BeFalse
    }
    It 'with the marker: writes Restarting (flushed) first, then schedules the restart in 20 seconds' {
        '{"state":"RebootExpected","changeId":"c1","bootBefore":"2026-11-07T10:00:00Z","domain":"improbability.cloud","ou":"OU=x","host":"iic-n01","error":""}' | Set-Content -LiteralPath (Join-Path $script:Dir 'domainjoin-state.json')
        $r = Invoke-DjNode -Payload DomainJoinRestart -Params @{ changeId = 'c1' } -StateDir $script:Dir
        $r.Answer.restartScheduled | Should -BeTrue
        $r.Marker.state | Should -Be 'Restarting'
        ([datetime]$r.Marker.bootBefore).ToUniversalTime().ToString('s') | Should -Be '2026-11-07T10:00:00'
        $shut = @($r.Calls | Where-Object { $_ -like 'shutdown.exe*' })
        $shut.Count | Should -Be 1
        $shut[0] | Should -Match '/r /t 20'
    }
}

Describe 'Resume after the restart' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive "rz-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $null = New-Item -ItemType Directory -Path $script:Dir
    }
    It 'after a new boot, verifies the join, records VerifiedAfterRestart and removes its task' {
        '{"state":"Restarting","changeId":"c1","bootBefore":"2026-11-07T10:00:00Z","domain":"improbability.cloud","ou":"OU=x","host":"iic-n01","error":""}' | Set-Content -LiteralPath (Join-Path $script:Dir 'domainjoin-state.json')
        $r = Invoke-DjNode -Payload DomainJoinResume -StateDir $script:Dir -Scenario @{ boot = '2026-11-07T10:09:00Z'; partOfDomain = $true; domain = 'improbability.cloud'; secureChannel = $true }
        $r.Marker.state | Should -Be 'VerifiedAfterRestart'
        $r.Calls | Should -Contain 'Unregister-ScheduledTask AzureLocal-OSConfig-DomainJoinResume'
    }
    It 'records VerifyFailedAfterRestart with the facts when the node is not in the domain' {
        '{"state":"RebootExpected","changeId":"c1","bootBefore":"2026-11-07T10:00:00Z","domain":"improbability.cloud","ou":"OU=x","host":"iic-n01","error":""}' | Set-Content -LiteralPath (Join-Path $script:Dir 'domainjoin-state.json')
        $r = Invoke-DjNode -Payload DomainJoinResume -StateDir $script:Dir -Scenario @{ boot = '2026-11-07T10:09:00Z'; partOfDomain = $false; domain = 'WORKGROUP'; secureChannel = $false }
        $r.Marker.state | Should -Be 'VerifyFailedAfterRestart'
        $r.Marker.error | Should -Match 'PartOfDomain=False'
        @($r.Calls | Where-Object { $_ -like 'Start-Sleep*' }).Count | Should -BeGreaterThan 0
    }
    It 'does nothing before the restart happened (the same boot), or with no marker' {
        '{"state":"RebootExpected","changeId":"c1","bootBefore":"2026-11-07T10:00:00Z","domain":"improbability.cloud","error":""}' | Set-Content -LiteralPath (Join-Path $script:Dir 'domainjoin-state.json')
        $r = Invoke-DjNode -Payload DomainJoinResume -StateDir $script:Dir -Scenario @{ boot = '2026-11-07T10:00:00Z' }
        $r.Marker.state | Should -Be 'RebootExpected'
        $empty = Invoke-DjNode -Payload DomainJoinResume -StateDir (Join-Path $TestDrive 'nothing-here')
        $empty.Exit | Should -Be 0
    }
}

Describe 'OuCheck: the dedicated OU over LDAP with the credential' {
    BeforeAll {
        $script:OuPath = 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'
        $script:OuParams = @{ domain = 'improbability.cloud'; netbios = 'IIC'; ou = $script:OuPath; dcs = @('192.0.2.4') }
    }
    It 'blocked inheritance (gPOptions 1): reported, and the credential is the join credential' {
        $ldap = @{ $script:OuPath = @{ gPOptions = 1 } }
        $r = Invoke-DjNode -Payload DomainJoinOuCheck -Params $script:OuParams -Secrets $script:Secret -Scenario @{ ldap = $ldap }
        $r.Exit | Should -Be 0 -Because $r.Console
        $r.Answer.ou.checked | Should -BeTrue
        $r.Answer.ou.exists | Should -BeTrue
        $r.Answer.ou.gpOptions | Should -Be 1
        $r.Answer.ou.blockInheritance | Should -BeTrue
        ($r.Calls -join "`n") | Should -Match 'DirectoryEntry LDAP://192.0.2.4/OU=iic-clus01.* user=IIC\\lcm-iic-clus01'
    }
    It 'gPOptions 0 or absent: inheritance is not blocked' {
        (Invoke-DjNode -Payload DomainJoinOuCheck -Params $script:OuParams -Secrets $script:Secret -Scenario @{ ldap = @{ $script:OuPath = @{ gPOptions = 0 } } }).Answer.ou.blockInheritance | Should -BeFalse
        (Invoke-DjNode -Payload DomainJoinOuCheck -Params $script:OuParams -Secrets $script:Secret).Answer.ou.blockInheritance | Should -BeFalse
    }
    It 'lists the Enforced GPO links above the OU (flag 2), not the disabled or plain ones' {
        $gp = '[LDAP://cn={AAAA},cn=policies,cn=system,DC=improbability,DC=cloud;2][LDAP://cn={BBBB},cn=policies,cn=system,DC=improbability,DC=cloud;0][LDAP://cn={CCCC},cn=policies,cn=system,DC=improbability,DC=cloud;3]'
        $ldap = @{ $script:OuPath = @{ gPOptions = 1 }; 'OU=AzureLocal,DC=improbability,DC=cloud' = @{ gPLink = $gp } }
        $r = Invoke-DjNode -Payload DomainJoinOuCheck -Params $script:OuParams -Secrets $script:Secret -Scenario @{ ldap = $ldap }
        @($r.Answer.ou.enforcedLinks).Count | Should -Be 1
        $r.Answer.ou.enforcedLinks[0] | Should -Match '\{AAAA\}'
        $r.Answer.ou.enforcedLinks[0] | Should -Match 'linked at OU=AzureLocal'
    }
    It 'the OU does not exist: exists false, not checked, with the LDAP error' {
        $r = Invoke-DjNode -Payload DomainJoinOuCheck -Params $script:OuParams -Secrets $script:Secret -Scenario @{ ouMissing = $true }
        $r.Answer.ou.exists | Should -BeFalse
        $r.Answer.ou.checked | Should -BeFalse
        $r.Answer.ou.error | Should -Match 'no such object'
    }
    It 'a rejected credential (<Name>) is authFailed, not "the OU is missing", and nothing else is bound after it' -ForEach @(
        @{ Name = 'HRESULT 0x8007052E'; HResult = -2147023570; Message = 'Logon failure: unknown user name or bad password.' }
        @{ Name = 'account disabled 0x80070533'; HResult = -2147023565; Message = 'Logon failure: account currently disabled.' }
        @{ Name = 'locked out 0x80070775'; HResult = -2147022987; Message = 'The referenced account is currently locked out and may not be logged on to.' }
        @{ Name = 'text only'; HResult = -2147467259; Message = 'The user name or password is incorrect.' }
    ) {
        $ldap = @{ $script:OuPath = @{ gPOptions = 1 }; 'OU=AzureLocal,DC=improbability,DC=cloud' = @{ gPLink = '[LDAP://cn={AAAA},cn=policies,cn=system,DC=improbability,DC=cloud;2]' } }
        $r = Invoke-DjNode -Payload DomainJoinOuCheck -Params $script:OuParams -Secrets $script:Secret -Scenario @{ ldap = $ldap; authFails = $true; authFailsHResult = $HResult; authFailsMessage = $Message }
        $r.Exit | Should -Be 0 -Because $r.Console
        $r.Answer.ou.authFailed | Should -BeTrue
        $r.Answer.ou.checked | Should -BeFalse
        $r.Answer.ou.error | Should -Not -BeNullOrEmpty
        @($r.Calls | Where-Object { $_ -like 'DirectoryEntry*' }).Count | Should -Be 1 -Because 'one bind with a wrong password is all the account may take'
    }
    It 'a missing OU and a good bind are not authFailed' {
        (Invoke-DjNode -Payload DomainJoinOuCheck -Params $script:OuParams -Secrets $script:Secret -Scenario @{ ouMissing = $true }).Answer.ou.authFailed | Should -BeFalse
        (Invoke-DjNode -Payload DomainJoinOuCheck -Params $script:OuParams -Secrets $script:Secret -Scenario @{ ldap = @{ $script:OuPath = @{ gPOptions = 1 } } }).Answer.ou.authFailed | Should -BeFalse
    }
    It 'it only reads: no Add-Computer, no MoveTo, no restart' {
        $r = Invoke-DjNode -Payload DomainJoinOuCheck -Params $script:OuParams -Secrets $script:Secret -Scenario @{ ldap = @{ $script:OuPath = @{ gPOptions = 1 } } }
        @($r.Calls | Where-Object { $_ -like 'Add-Computer*' -or $_ -like 'MoveTo*' -or $_ -like 'shutdown*' -or $_ -like 'Register*' }) | Should -BeNullOrEmpty
    }
}

Describe 'The password is never written down by the node scripts' {
    It 'is not in the marker, the result, the resume script, the calls, the console or any file the run left behind' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam @{ resumeScript = (Get-AzlNodePayload -Name DomainJoinResume) }) -Secrets $script:Secret
        $r.Answer.status | Should -Be 'joined'
        $leftovers = @(Get-ChildItem -LiteralPath $r.State -Recurse -File)
        $leftovers.Count | Should -BeGreaterThan 1
        foreach ($f in $leftovers) { (Get-Content -LiteralPath $f.FullName -Raw) | Should -Not -Match ([regex]::Escape($script:Password)) -Because $f.Name }
        ($r.Calls -join "`n") | Should -Not -Match ([regex]::Escape($script:Password))
        $r.Console | Should -Not -Match ([regex]::Escape($script:Password))
        (Get-Content -LiteralPath (Join-Path $r.Dir 'out.txt') -Raw) | Should -Not -Match ([regex]::Escape($script:Password))
        ($r.Answer | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:Password))
    }
    It 'a failed join leaves no password anywhere either, and the error text is the node''s own' {
        $r = Invoke-DjNode -Payload DomainJoinApply -Params (Get-JoinParam) -Secrets $script:Secret -Scenario @{ addComputerMessage = 'The user name or password is incorrect.' }
        foreach ($f in @(Get-ChildItem -LiteralPath $r.State -Recurse -File)) { (Get-Content -LiteralPath $f.FullName -Raw) | Should -Not -Match ([regex]::Escape($script:Password)) }
        ($r.Answer | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:Password))
    }
}
