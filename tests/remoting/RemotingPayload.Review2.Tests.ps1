#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the second review of the remote management profiles, node script side. The node scripts are text; the functions of interest are
# cut out of the script with the parser and run here in pwsh with fake firewall, WSMan and certificate commands, so the logic itself is
# tested (F7 which rules are touched, F4 where the listener and the rules bind, F10 what a revert undoes, F1 the revert timer).
# No node, no firewall rule, no listener, no scheduled task of this machine is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/RemotingPayload.Review2.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A fake command run by a script block reports back through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module (Join-Path (Join-Path (Join-Path (Join-Path $repo 'scripts') 'common') 'remoting') 'AzlRemotingPayload.psm1') -Force
    $script:Change = Get-AzlRemotingPayload -Name Change

    # The text of some functions of the node script.
    function Get-NodeFunctionText([string]$Payload, [string[]]$Name) {
        $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Payload, [ref]$null, [ref]$e)
        $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Name }, $true)
        if (@($found).Count -ne $Name.Count) { throw "Not every function was found: $($Name -join ', ')" }
        (@($found) | ForEach-Object { $_.Extent.Text }) -join "`n"
    }
    # Fake firewall commands over a table in $global:AzlRules / $global:AzlFilters. They take $args, so any parameter set works.
    $script:FirewallFakes = @'
function Get-NetFirewallPortFilter { $global:AzlFilters }
function Get-NetFirewallRule {
    $a = @($args)
    $i = [array]::IndexOf($a, '-Name')
    if ($i -ge 0) { return @($global:AzlRules | Where-Object { $_.Name -eq $a[$i + 1] }) }
    $j = [array]::IndexOf($a, '-AssociatedNetFirewallPortFilter')
    if ($j -ge 0) { $f = $a[$j + 1]; return @($global:AzlRules | Where-Object { $_.Filter -eq $f.Id }) }
    return @($global:AzlRules)
}
function Set-NetFirewallRule { $global:AzlLog.Add(('Set ' + (@($args) -join ' '))) }
function Remove-NetFirewallRule { $global:AzlLog.Add(('Remove ' + (@($args) -join ' '))) }
function New-NetFirewallRule { $global:AzlLog.Add('New') ; $global:AzlNew = $args }
'@
    function New-FakeRule([string]$Name, [int]$Filter, [string]$Direction = 'Inbound', [string]$Action = 'Allow') { [pscustomobject]@{ Name = $Name; Filter = $Filter; Direction = $Direction; Action = $Action } }
    function New-FakeFilter([int]$Id, [string[]]$Port) { [pscustomobject]@{ Id = $Id; LocalPort = $Port } }
    function Initialize-Fakes {
        $global:AzlLog = [System.Collections.Generic.List[string]]::new()
        $global:AzlNew = $null
        $global:AzlFilters = @(
            (New-FakeFilter 1 @('5985')), (New-FakeFilter 2 @('5985', '5986')), (New-FakeFilter 3 @('5986')), (New-FakeFilter 4 @('5985', '3389')),
            (New-FakeFilter 5 @('5985')), (New-FakeFilter 6 @('5985')), (New-FakeFilter 7 @('80')), (New-FakeFilter 8 @('5985-5986'))
        )
        $global:AzlRules = @(
            (New-FakeRule 'WINRM-HTTP-In-TCP' 1), (New-FakeRule 'BOTH-PORTS' 2), (New-FakeRule 'WINRM-HTTPS-In-TCP' 3), (New-FakeRule 'WITH-RDP' 4),
            (New-FakeRule 'OUTBOUND-5985' 5 'Outbound'), (New-FakeRule 'AzlOsConfig-WinRM-HTTP-In' 6), (New-FakeRule 'WEB' 7), (New-FakeRule 'RANGE' 8)
        )
    }
}

AfterAll {
    foreach ($v in 'AzlLog', 'AzlNew', 'AzlFilters', 'AzlRules') { Remove-Variable -Name $v -Scope Global -ErrorAction SilentlyContinue }
}

Describe 'F7: only the rules that are exactly WinRM are touched' {
    BeforeAll { $script:RuleFn = Get-NodeFunctionText $script:Change @('Get-WinRmRuleName', 'Disable-DiscoveredWinRm') }
    BeforeEach { Initialize-Fakes }

    It 'finds the rules whose LocalPort set is exactly {5985} or {5986}, inbound allow, not ours' {
        $names = & ([scriptblock]::Create($script:FirewallFakes + "`n" + $script:RuleFn + "`nGet-WinRmRuleName"))
        @($names | Sort-Object) | Should -Be @('WINRM-HTTP-In-TCP', 'WINRM-HTTPS-In-TCP')
    }
    It "'http' finds only the {5985} rules, 'https' only the {5986} rules" {
        @(& ([scriptblock]::Create($script:FirewallFakes + "`n" + $script:RuleFn + "`nGet-WinRmRuleName 'http'"))) | Should -Be @('WINRM-HTTP-In-TCP')
        @(& ([scriptblock]::Create($script:FirewallFakes + "`n" + $script:RuleFn + "`nGet-WinRmRuleName 'https'"))) | Should -Be @('WINRM-HTTPS-In-TCP')
    }
    It 'disabling the HTTP side never disables a rule that allows 5986, or one that allows other ports too' {
        $null = & ([scriptblock]::Create($script:FirewallFakes + "`n" + $script:RuleFn + "`nDisable-DiscoveredWinRm"))
        @($global:AzlLog) | Should -Be @('Set -Name WINRM-HTTP-In-TCP -Enabled False')
    }
}

Describe 'F4: until the node holds the management IP, the listener is on * and the rules take any local address' {
    BeforeAll {
        $script:BindFn = Get-NodeFunctionText $script:Change @('Get-P', 'Test-OwnAddress', 'Get-OwnManagementAddress', 'Get-BindAddress', 'Get-ListenerAddress', 'Get-RuleState', 'Set-ManagedRule')
        $script:Spec = '[pscustomobject]@{ name = "AzlOsConfig-WinRM-HTTPS-In"; display = "d"; protocol = "TCP"; port = "5986"; remote = @("192.0.2.0/24") }'
        function Invoke-Bind([string]$Bind, [string]$Mgmt, [string]$Current, [string[]]$Own) {
            $head = "`$bind = '$Bind'; `$mgmtIp = '$Mgmt'; `$currentIp = '$Current'; `$global:AzlOwn = @('$($Own -join "','")')`n" +
            'function Get-NetIPAddress { $a = @($args); $i = [array]::IndexOf($a, ''-IPAddress''); if ($i -ge 0 -and $global:AzlOwn -contains $a[$i + 1]) { [pscustomobject]@{ IPAddress = $a[$i + 1] } } }' + "`n"
            $body = "`n`$r = [ordered]@{ listener = (Get-ListenerAddress) }; `$null = Set-ManagedRule ($($script:Spec)) `$false; `$r.local = @(`$global:AzlNew | ForEach-Object { `$_ }) ; `$r"
            & ([scriptblock]::Create($head + $script:FirewallFakes + "`n" + $script:BindFn + $body))
        }
        function Get-LocalAddressArg { $a = @($global:AzlNew); $i = [array]::IndexOf($a, '-LocalAddress:'); $a[$i + 1] }
    }
    BeforeEach { Initialize-Fakes; $global:AzlRules = @(); $global:AzlFilters = @() }

    It 'the node does not hold the management IP yet: listener *, LocalAddress Any (it does not bind to the address in use)' {
        $r = Invoke-Bind 'managementIp' '192.0.2.11' '192.0.2.50' @('192.0.2.50')
        $r.listener | Should -Be '*'
        @(Get-LocalAddressArg) | Should -Be @('Any')
    }
    It 'the node holds the management IP and the session came in on it: listener IP:management-ip, LocalAddress that ip' {
        $r = Invoke-Bind 'managementIp' '192.0.2.11' '192.0.2.11' @('192.0.2.11')
        $r.listener | Should -Be 'IP:192.0.2.11'
        @(Get-LocalAddressArg) | Should -Be @('192.0.2.11')
    }
    It 'the node holds the management IP but the session came in on another address of it: the listener stays on *' {
        $r = Invoke-Bind 'managementIp' '192.0.2.11' '192.0.2.50' @('192.0.2.11', '192.0.2.50')
        $r.listener | Should -Be '*'
        @(Get-LocalAddressArg) | Should -Be @('Any')
    }
    It 'bind any (lab and test): always *, Any' {
        $r = Invoke-Bind 'any' '192.0.2.11' '192.0.2.11' @('192.0.2.11')
        $r.listener | Should -Be '*'
    }
    It 'no session address (Arc) and the management IP held: bound to it' {
        $r = Invoke-Bind 'managementIp' '192.0.2.11' '' @('192.0.2.11')
        $r.listener | Should -Be 'IP:192.0.2.11'
    }
    It 'no longer throws when neither address is on the node' {
        { Invoke-Bind 'managementIp' '192.0.2.11' '192.0.2.50' @() } | Should -Not -Throw
    }
}

Describe 'F10: a revert undoes what stage did' {
    BeforeAll {
        $script:RestoreFn = Get-NodeFunctionText $script:Change @('Get-P', 'Get-WinRmRuleName', 'Remove-ManagedRule', 'Restore-Snapshot')
        $script:RestoreFakes = @'
function Set-WsmanValue { }
function Get-ListenerState { @($global:AzlListeners) }
function Remove-Listener { $global:AzlLog.Add(('RemoveListener ' + (@($args) -join ' '))) }
function New-WSManInstance { }
function Remove-AddedCertificate { $global:AzlLog.Add(('RemoveCert ' + (@($args) -join ' '))) }
'@
        function Invoke-Restore([object]$Snapshot, [string]$Marker) {
            $dir = Join-Path $TestDrive 'osconfig'
            $changes = Join-Path $dir 'changes'
            New-Item -ItemType Directory -Force -Path $changes | Out-Null
            Set-Content -LiteralPath (Join-Path $changes 'chg1.json') -Value ($Snapshot | ConvertTo-Json -Depth 8)
            $markerFile = Join-Path $changes 'chg1.addedcert'
            Remove-Item -LiteralPath $markerFile -ErrorAction SilentlyContinue
            if ($Marker) { Set-Content -LiteralPath $markerFile -Value $Marker }
            $text = "`$stateRoot = '$dir'`n" + $script:FirewallFakes + "`n" + $script:RestoreFakes + "`n" + $script:RestoreFn + "`nRestore-Snapshot 'chg1'"
            $problems = & ([scriptblock]::Create($text))
            [pscustomobject]@{ Problems = @($problems); MarkerLeft = (Test-Path -LiteralPath $markerFile) }
        }
    }
    BeforeEach {
        Initialize-Fakes
        $global:AzlListeners = @()
        # now: the built-in rule Enable-PSRemoting created after the snapshot, and one that was already there
        $global:AzlFilters = @((New-FakeFilter 1 @('5985')), (New-FakeFilter 3 @('5986')))
        $global:AzlRules = @((New-FakeRule 'WINRM-HTTP-In-TCP' 1), (New-FakeRule 'WINRM-HTTPS-In-TCP' 3))
    }
    AfterAll { Remove-Variable -Name AzlListeners -Scope Global -ErrorAction SilentlyContinue }

    It 'a WinRM rule that was not there when the snapshot was taken is removed; one that was there is put back, not removed' {
        $snap = [pscustomobject]@{
            changeId = 'chg1'; service = [pscustomobject]@{}; listeners = @(); ruleNames = @('WINRM-HTTPS-In-TCP')
            rules = @([pscustomobject]@{ name = 'WINRM-HTTPS-In-TCP'; enabled = $true; profile = 'Public'; remote = @('LocalSubnet'); local = @('Any') }); rdp = $null
        }
        $r = Invoke-Restore $snap ''
        $r.Problems | Should -BeNullOrEmpty
        @($global:AzlLog | Where-Object { $_ -like 'Remove -Name*' }) | Should -Be @('Remove -Name WINRM-HTTP-In-TCP')
        @($global:AzlLog | Where-Object { $_ -like 'Set -Name WINRM-HTTPS-In-TCP*' }).Count | Should -Be 1
    }
    It 'the certificate stage put in LocalMachine\My is removed on revert, and the marker with it' {
        $snap = [pscustomobject]@{ changeId = 'chg1'; service = [pscustomobject]@{}; listeners = @(); ruleNames = @('WINRM-HTTP-In-TCP', 'WINRM-HTTPS-In-TCP'); rules = @(); rdp = $null }
        $r = Invoke-Restore $snap ('AB' * 20)
        @($global:AzlLog | Where-Object { $_ -like 'RemoveCert*' }) | Should -Be @("RemoveCert $('AB' * 20)")
        $r.MarkerLeft | Should -BeFalse
    }
    It 'with no marker no certificate is removed (a certificate that was on the node before is never touched)' {
        $snap = [pscustomobject]@{ changeId = 'chg1'; service = [pscustomobject]@{}; listeners = @(); ruleNames = @('WINRM-HTTP-In-TCP', 'WINRM-HTTPS-In-TCP'); rules = @(); rdp = $null }
        $null = Invoke-Restore $snap ''
        @($global:AzlLog | Where-Object { $_ -like 'RemoveCert*' }) | Should -BeNullOrEmpty
    }
}

Describe 'F10: stage records the certificate it adds, and commit keeps it' {
    It 'Resolve-ServerCertificate writes the marker only for a certificate it added (Key Vault PFX, new self-signed)' {
        $fn = Get-NodeFunctionText $script:Change @('Resolve-ServerCertificate')
        $fn | Should -Match 'Set-AddedCertificateMarker'
        ([regex]::Matches($fn, 'Set-AddedCertificateMarker')).Count | Should -Be 2
        $fn | Should -Match 'Test-Path'
    }
    It 'the commit removes the marker: the certificate is wanted from then on' {
        $script:Change | Should -Match "Remove-Item -LiteralPath \(Join-Path \(Join-Path \`$stateRoot 'changes'\) \(\`$changeId \+ '\.addedcert'\)\)"
    }
}

Describe 'F1: the node can put the snapshot back by itself' {
    It 'arms a scheduled task as SYSTEM from a copy of the script file, only on commit and only when asked for minutes' {
        $script:Change | Should -Match 'Register-ScheduledTask'
        $script:Change | Should -Match "AzlOsConfig-Revert-"
        $script:Change | Should -Match '\$PSCommandPath'
        $script:Change | Should -Match "revertMinutes"
        $script:Change | Should -Match "mode -eq 'disarm'"
    }
    It 'the timer is armed BEFORE the commit narrows anything' {
        $arm = $script:Change.IndexOf('Register-RevertTimer $changeId')
        $narrow = $script:Change.IndexOf('Set-ManagedRule $r $false')
        $arm | Should -BeGreaterThan 0
        $arm | Should -BeLessThan $narrow
    }
    It 'a revert run by the timer removes the task and the copy; disarm does the same without reverting' {
        $fn = Get-NodeFunctionText $script:Change @('Unregister-RevertTimer')
        $fn | Should -Match 'Unregister-ScheduledTask'
        $fn | Should -Match 'Remove-Item'
    }
}
