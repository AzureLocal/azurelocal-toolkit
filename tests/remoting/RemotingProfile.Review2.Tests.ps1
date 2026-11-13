#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the second review of the remote management profiles, profile side: F3 (only the explicit run switch approves a production or
# dmz bootstrap), F11 (the validator does not fail open), F12 (the width floor holds for subnets, the class table is checked against a
# baseline in code, IPv4-mapped IPv6 CIDRs are refused). Pure: no node, no Azure, no machine setting is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/RemotingProfile.Review2.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module (Join-Path (Join-Path (Join-Path (Join-Path $repo 'scripts') 'common') 'remoting') 'AzlRemotingProfile.psm1') -Force
    Import-Module powershell-yaml
    $script:Example = Join-Path (Join-Path (Join-Path (Join-Path $repo 'config') 'variables') 'examples') 'infrastructure.example.yml'
    $script:Table = Join-Path (Join-Path $repo 'config') 'remoting-profiles.json'
    $script:Choose = { param($d) $d.os_configuration.remoting.bootstrap_transport = 'smb'; $d.os_configuration.remoting.certificate = ('AB' * 20) }

    function Get-Infra([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        if ($Change) { & $Change $doc }
        return $doc
    }
    function Resolve-For([string]$Class, [scriptblock]$Change, [hashtable]$Override = @{}) {
        $doc = Get-Infra { param($d) $d.scenario.environment_class = $Class }
        if ($Change) { & $Change $doc }
        Resolve-AzlRemotingProfile -Infrastructure $doc -Override $Override
    }
    function Get-Table { Get-Content -LiteralPath $script:Table -Raw | ConvertFrom-Json -AsHashtable -Depth 20 }
}

Describe 'F3: only the explicit run switch approves a production or dmz bootstrap' {
    It '<_>: an approval from a settings file is dropped, marked approved=false, and warned about' -ForEach 'production', 'dmz' {
        $p = Resolve-For $_ $script:Choose @{ approved_bootstrap = $true; approved_bootstrap_source = 'settings' }
        $p.Bootstrap.Approved | Should -BeFalse
        $p.Bootstrap.Permitted | Should -BeFalse
        ($p.Warnings -join ' ') | Should -Match 'settings file'
    }
    It '<_>: the parameter counts' -ForEach 'production', 'dmz' {
        $p = Resolve-For $_ $script:Choose @{ approved_bootstrap = $true; approved_bootstrap_source = 'parameter' }
        $p.Bootstrap.Approved | Should -BeTrue
        $p.Bootstrap.Permitted | Should -BeTrue
    }
    It 'an approval with an unknown source does not count either' {
        (Resolve-For 'production' $script:Choose @{ approved_bootstrap = $true; approved_bootstrap_source = 'environment' }).Bootstrap.Approved | Should -BeFalse
    }
    It 'lab needs no approval, so a settings approval changes nothing there' {
        (Resolve-For 'lab' $script:Choose @{ approved_bootstrap = $true; approved_bootstrap_source = 'settings' }).Bootstrap.Permitted | Should -BeTrue
    }
}

Describe 'F11: the validator does not fail open' {
    It 'a profile table that is not valid JSON is an AZL-060 error finding' {
        $bad = Join-Path $TestDrive 'broken-table.json'
        Set-Content -LiteralPath $bad -Value '{ not json'
        $f = @(Get-AzlRemotingFinding -Infrastructure (Get-Infra) -DataPath $bad)
        $f.Count | Should -Be 1
        $f[0].Id | Should -Be 'AZL-060'
        $f[0].Severity | Should -Be 'error'
    }
    It 'a table without a class row is an AZL-060 error finding' {
        $bad = Join-Path $TestDrive 'short-table.json'
        $t = Get-Table
        $t.classes.Remove('dmz')
        Set-Content -LiteralPath $bad -Value ($t | ConvertTo-Json -Depth 20)
        @(Get-AzlRemotingFinding -Infrastructure (Get-Infra) -DataPath $bad | Where-Object { $_.Id -eq 'AZL-060' -and $_.Severity -eq 'error' }).Count | Should -Be 1
    }
    It 'a missing table file stays a toolkit problem, not a finding on the master file' {
        @(Get-AzlRemotingFinding -Infrastructure (Get-Infra) -DataPath (Join-Path $TestDrive 'not-there.json')) | Should -BeNullOrEmpty
    }
}

Describe 'F12: the hard floor, the checked table, IPv4-mapped IPv6' {
    It 'a management subnet wider than the floor is never a source, whatever the table says' {
        $t = Get-Table
        $t.classes.lab.sources.widestPrefixV4 = 0
        $doc = Get-Infra { param($d) $d.scenario.environment_class = 'lab'; $d.networking.management.subnet = '10.0.0.0/8' }
        $p = Resolve-AzlRemotingProfile -Infrastructure $doc -Override @{ allow_any_source = $false } -Data $t
        @($p.Firewall.RemoteAddress) | Should -Not -Contain '10.0.0.0/8'
        $p.Valid | Should -BeFalse
    }
    It 'a /8 management subnet is left out with a warning in the table as shipped' {
        $doc = Get-Infra { param($d) $d.scenario.environment_class = 'dev'; $d.networking.management.subnet = '10.0.0.0/8' }
        $p = Resolve-AzlRemotingProfile -Infrastructure $doc
        @($p.Firewall.RemoteAddress) | Should -Not -Contain '10.0.0.0/8'
        ($p.Warnings -join ' ') | Should -Match '10\.0\.0\.0/8'
    }
    It '<Path> in the table is checked: a weaker value is refused' -ForEach @(
        @{ Path = 'production.sources.widestPrefixV4'; Value = 8 }
        @{ Path = 'production.sources.widestPrefixV6'; Value = 8 }
        @{ Path = 'dev.sources.widestPrefixV4'; Value = 16 }
        @{ Path = 'dmz.sources.widestPrefixV4'; Value = 24 }
        @{ Path = 'production.transport.httpsPolicy'; Value = 'preferred' }
        @{ Path = 'production.transport.httpsPolicy'; Value = 'warn' }
        @{ Path = 'dmz.transport.httpsPolicy'; Value = 'preferred' }
        @{ Path = 'dev.transport.httpsPolicy'; Value = 'preferred' }
        @{ Path = 'production.bootstrap.approval'; Value = 'none' }
        @{ Path = 'dmz.bootstrap.approval'; Value = 'pipeline' }
        @{ Path = 'dmz.bootstrap.approval'; Value = 'none' }
        @{ Path = 'production.sources.any'; Value = $true }
    ) {
        $t = Get-Table
        $parts = $Path.Split('.')
        $t.classes[$parts[0]][$parts[1]][$parts[2]] = $Value
        $p = Resolve-AzlRemotingProfile -Infrastructure (Get-Infra) -Data $t
        $p.Valid | Should -BeFalse -Because $Path
        ($p.Errors -join ' ') | Should -Match 'weakens the baseline'
    }
    It 'the table as shipped passes its own class baseline in <_>' -ForEach 'lab', 'test', 'dev', 'production', 'dmz' {
        $p = Resolve-For $_ { param($d) $d.os_configuration.remoting.certificate = ('AB' * 20) }
        ($p.Errors -join ' ') | Should -Not -Match 'weakens'
    }
    It 'a stricter value than the baseline is fine' {
        $t = Get-Table
        $t.classes.production.sources.widestPrefixV4 = 28
        $t.classes.dev.bootstrap.approval = 'pipeline'
        $p = Resolve-AzlRemotingProfile -Infrastructure (Get-Infra) -Data $t
        ($p.Errors -join ' ') | Should -Not -Match 'weakens'
    }
    It '<Text> is an IPv4-mapped IPv6 address: refused, so the width check cannot be bypassed' -ForEach @(
        @{ Text = '::ffff:0:0/96' }
        @{ Text = '::ffff:10.0.0.0/104' }
        @{ Text = '::ffff:192.0.2.1' }
        @{ Text = '::FFFF:0:0/96' }
    ) {
        $c = ConvertTo-AzlCidr -Text $Text
        $c.Valid | Should -BeFalse
        $c.Reason | Should -Match 'IPv4-mapped'
    }
    It 'allowed_source_cidrs with ::ffff:0:0/96 is an AZL-062 error and not a source' {
        $p = Resolve-For 'production' { param($d) $d.os_configuration.remoting.allowed_source_cidrs = @('::ffff:0:0/96') }
        @($p.Issues | Where-Object { $_.Id -eq 'AZL-062' -and $_.Severity -eq 'error' }).Count | Should -Be 1
        @($p.Firewall.RemoteAddress) | Should -Not -Contain '::ffff:0:0/96'
    }
    It 'a plain IPv6 address and the IPv4 ones still parse' {
        (ConvertTo-AzlCidr -Text '2001:db8::5').Valid | Should -BeTrue
        (ConvertTo-AzlCidr -Text '192.0.2.0/24').Valid | Should -BeTrue
    }
}
