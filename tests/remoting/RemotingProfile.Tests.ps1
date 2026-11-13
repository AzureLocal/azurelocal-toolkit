#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the remote management security profile: Resolve-AzlRemotingProfile for every class and every override, and the validator
# rules AZL-060 to AZL-068. Pure: no node, no Azure, no machine setting is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/RemotingProfile.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module (Join-Path (Join-Path (Join-Path (Join-Path $repo 'scripts') 'common') 'remoting') 'AzlRemotingProfile.psm1') -Force
    Import-Module (Join-Path (Join-Path (Join-Path (Join-Path $repo 'scripts') 'common') 'infrastructure') 'AzlInfrastructure.psm1') -Force
    Import-Module powershell-yaml
    $script:Example = Join-Path (Join-Path (Join-Path (Join-Path $repo 'config') 'variables') 'examples') 'infrastructure.example.yml'
    $script:Table = Join-Path (Join-Path $repo 'config') 'remoting-profiles.json'

    function Get-Infra([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        if ($Change) { & $Change $doc }
        return $doc
    }
    # The example with a class and a change, resolved.
    function Resolve-For([string]$Class, [scriptblock]$Change, [hashtable]$Override = @{}) {
        $doc = Get-Infra { param($d) if ($Class) { $d.scenario.environment_class = $Class } else { $d.scenario.Remove('environment_class') } }
        if ($Change) { & $Change $doc }
        Resolve-AzlRemotingProfile -Infrastructure $doc -Override $Override
    }
    function Get-FindingFor([scriptblock]$Change) {
        $doc = Get-Infra $Change
        $file = Join-Path $TestDrive ("case-{0}.yml" -f [guid]::NewGuid())
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        @(Test-AzlInfrastructure -Path $file)
    }
}

Describe 'The profile table' {
    It 'has a row for each of the five classes and the baseline denylist' {
        $t = Get-Content -LiteralPath $script:Table -Raw | ConvertFrom-Json -AsHashtable
        @($t.classes.Keys | Sort-Object) | Should -Be @('dev', 'dmz', 'lab', 'production', 'test')
        $t.defaultClass | Should -Be 'production'
        $t.baseline.allowUnencrypted | Should -BeFalse
        $t.baseline.basicAuth | Should -BeFalse
        $t.baseline.credSsp | Should -BeFalse
        $t.baseline.skipCACheck | Should -BeFalse
        $t.baseline.skipCNCheck | Should -BeFalse
        $t.baseline.cbtHardeningLevel | Should -Be 'Strict'
    }
    It 'holds no network, subscription, host or lab name' {
        $text = Get-Content -LiteralPath $script:Table -Raw
        $text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
        $text | Should -Not -Match '(?i)tplabs|tierpoint|hybridsolutions|inthefog|subscriptions/'
    }
}

Describe 'Resolve-AzlRemotingProfile: the five classes' {
    Context 'lab and test: relaxed with the wildcard' {
        It '<_> opens WinRM, RDP and ICMP to Any, sets TrustedHosts * and allows HTTP 5985' -ForEach 'lab', 'test' {
            $p = Resolve-For $_
            $p.Valid | Should -BeTrue
            $p.Relaxed | Should -BeTrue
            $p.Posture | Should -Be 'relaxed-wildcard'
            $p.Firewall.AnySource | Should -BeTrue
            @($p.Firewall.RemoteAddress) | Should -Be @('Any')
            @($p.Firewall.RdpRemoteAddress) | Should -Be @('Any')
            @($p.Firewall.IcmpRemoteAddress) | Should -Be @('Any')
            $p.Firewall.RdpEnabled | Should -BeTrue
            $p.TrustedHosts.Mode | Should -Be 'wildcard'
            $p.TrustedHosts.Value | Should -Be '*'
            $p.TrustedHosts.RestoreAfterRun | Should -BeTrue
            $p.Transport.HttpEnabled | Should -BeTrue
            $p.Transport.HttpsEnabled | Should -BeFalse
            $p.Transport.Scheme | Should -Be 'http'
            $p.Bootstrap.Approval | Should -Be 'none'
        }
        It '<_> warns that the posture is relaxed, and says what is open' -ForEach 'lab', 'test' {
            $p = Resolve-For $_
            $warning = @($p.Warnings | Where-Object { $_ -match 'Relaxed remote management posture' })
            $warning.Count | Should -Be 1
            $warning[0] | Should -Match 'any source'
            $warning[0] | Should -Match "TrustedHosts is '\*'"
            $warning[0] | Should -Match 'HTTP 5985'
            $warning[0] | Should -Match 'baseline still holds'
        }
        It 'the warning says whether isolation is confirmed' {
            (Resolve-For 'lab' $null @{ isolation_confirmed = $true }).Warnings -join ' ' | Should -Match 'confirmed the nodes'
            (Resolve-For 'lab').Warnings -join ' ' | Should -Match 'Isolation is not confirmed'
        }
    }
    Context 'dev' {
        BeforeAll { $script:Dev = Resolve-For 'dev' }
        It 'takes sources only from the file: the management and out-of-band networks, allowed_source_cidrs and the node addresses' {
            $script:Dev.Valid | Should -BeTrue
            $script:Dev.Firewall.AnySource | Should -BeFalse
            @($script:Dev.Firewall.RemoteAddress) | Should -Contain '192.0.2.0/24'
            @($script:Dev.Firewall.RemoteAddress) | Should -Contain '198.51.100.0/24'
            @($script:Dev.Firewall.RemoteAddress) | Should -Contain '198.51.100.10/32'
            @($script:Dev.Firewall.RemoteAddress) | Should -Contain '192.0.2.11/32'
            @($script:Dev.Firewall.RemoteAddress) | Should -Not -Contain 'Any'
        }
        It 'uses HTTPS, an exact TrustedHosts list and a per-node certificate' {
            $script:Dev.Transport.Scheme | Should -Be 'https'
            $script:Dev.Transport.HttpsEnabled | Should -BeTrue
            $script:Dev.Transport.HttpEnabled | Should -BeFalse
            $script:Dev.Transport.RemoveHttpAfterHttps | Should -BeTrue
            $script:Dev.TrustedHosts.Mode | Should -Be 'exact'
            @($script:Dev.TrustedHosts.Addresses) | Should -Contain '192.0.2.11'
            $script:Dev.Certificate.Mode | Should -Be 'selfSigned'
            $script:Dev.Listener.Bind | Should -Be 'managementIp'
        }
        It 'RDP and ICMP come from the management networks (ICMP also from the nodes)' {
            @($script:Dev.Firewall.RdpRemoteAddress) | Should -Contain '192.0.2.0/24'
            @($script:Dev.Firewall.RdpRemoteAddress) | Should -Not -Contain '198.51.100.10/32'
            @($script:Dev.Firewall.IcmpRemoteAddress) | Should -Contain '192.0.2.12/32'
        }
    }
    Context 'production' {
        BeforeAll { $script:Prod = Resolve-For 'production' }
        It 'is the class when none is set, and says so' {
            $none = Resolve-For $null
            $none.Class | Should -Be 'production'
            $none.ClassSource | Should -Match 'missing'
            $none.Valid | Should -BeTrue
            $script:Prod.ClassSource | Should -Match 'master file'
        }
        It 'needs HTTPS, has no TrustedHosts, removes HTTP after HTTPS is verified' {
            $script:Prod.Transport.Scheme | Should -Be 'https'
            $script:Prod.Transport.HttpEnabled | Should -BeFalse
            $script:Prod.Transport.RemoveHttpAfterHttps | Should -BeTrue
            $script:Prod.TrustedHosts.Mode | Should -Be 'none'
            $script:Prod.Authentication.Mode | Should -Be 'kerberos-after-join'
            $script:Prod.Warnings | Should -BeNullOrEmpty
        }
        It 'the bootstrap needs a chosen route and a pipeline approval' {
            $script:Prod.Bootstrap.Approval | Should -Be 'pipeline'
            $script:Prod.Bootstrap.RequiresExplicitChoice | Should -BeTrue
            $script:Prod.Bootstrap.Permitted | Should -BeFalse
        }
        It 'opens exact TrustedHosts entries only when a bootstrap opens an HTTP window' {
            (Resolve-For 'production' { param($d) $d.os_configuration.remoting.bootstrap_transport = 'smb' }).TrustedHosts.Mode | Should -Be 'exact'
        }
    }
    Context 'dmz' {
        BeforeAll { $script:Dmz = Resolve-For 'dmz' { param($d) $d.os_configuration.remoting.certificate = ('AB' * 20) } }
        It 'takes single controller addresses only, no management network, no TrustedHosts' {
            $script:Dmz.Valid | Should -BeTrue
            @($script:Dmz.Firewall.RemoteAddress) | Should -Contain '198.51.100.10/32'
            @($script:Dmz.Firewall.RemoteAddress) | Should -Not -Contain '192.0.2.0/24'
            @($script:Dmz.Firewall.RemoteAddress | Where-Object { $_ -notmatch '/(32|128)$' }) | Should -BeNullOrEmpty
            $script:Dmz.TrustedHosts.Mode | Should -Be 'none'
        }
        It 'turns RDP off, keeps ICMP between the nodes, and is HTTPS only with an enterprise certificate' {
            $script:Dmz.Firewall.RdpEnabled | Should -BeFalse
            $script:Dmz.Firewall.IcmpEnabled | Should -BeTrue
            @($script:Dmz.Firewall.IcmpRemoteAddress) | Should -Be @('192.0.2.11/32', '192.0.2.12/32')
            $script:Dmz.Transport.HttpsEnabled | Should -BeTrue
            $script:Dmz.Transport.BootstrapWindowHttp | Should -BeFalse
            $script:Dmz.Certificate.Mode | Should -Be 'thumbprint'
            $script:Dmz.Bootstrap.Approval | Should -Be 'perRun'
        }
        It 'refuses a self-signed per-node certificate' {
            (Resolve-For 'dmz').Errors -join ' ' | Should -Match 'enterprise certificate'
        }
    }
    It 'keeps SMB, ICMP and WS-Man between the nodes in every class' -ForEach 'lab', 'test', 'dev', 'production', 'dmz' {
        $p = Resolve-For $_ { param($d) $d.os_configuration.remoting.certificate = ('AB' * 20) }
        @($p.Firewall.NodeAddress) | Should -Be @('192.0.2.11/32', '192.0.2.12/32')
    }
}

Describe 'Resolve-AzlRemotingProfile: the class value' {
    It 'an unknown class is an error that names the allowed values' {
        $p = Resolve-For 'staging'
        $p.Valid | Should -BeFalse
        $p.Errors -join ' ' | Should -Match 'lab, test, dev, production, dmz'
        { Assert-AzlRemotingProfile -RemotingProfile $p } | Should -Throw '*lab, test, dev, production, dmz*'
    }
    It 'an empty class is not "missing": it is an error' {
        (Resolve-For 'lab' { param($d) $d.scenario.environment_class = '' }).Errors -join ' ' | Should -Match 'isn''t valid'
    }
    It 'Assert marks the exception as bad input (exit code 2)' {
        try { Assert-AzlRemotingProfile -RemotingProfile (Resolve-For 'staging') }
        catch { $_.Exception.Data['AzlInput'] | Should -BeTrue }
    }
    It 'a valid class passes Assert' {
        { Assert-AzlRemotingProfile -RemotingProfile (Resolve-For 'lab') } | Should -Not -Throw
    }
    It 'the class is case-insensitive' {
        (Resolve-For 'LAB').Class | Should -Be 'lab'
    }
}

Describe 'Resolve-AzlRemotingProfile: every override and key' {
    It 'an override of the class wins over the file' {
        $p = Resolve-For 'production' $null @{ environment_class = 'lab' }
        $p.Class | Should -Be 'lab'
        $p.ClassSource | Should -Match 'override'
    }
    It 'allow_any_source false in lab restricts the sources and the TrustedHosts list' {
        $p = Resolve-For 'lab' { param($d) $d.os_configuration.remoting.allow_any_source = $false }
        $p.Firewall.AnySource | Should -BeFalse
        @($p.Firewall.RemoteAddress) | Should -Not -Contain 'Any'
        @($p.Firewall.RemoteAddress) | Should -Contain '192.0.2.0/24'
        $p.TrustedHosts.Mode | Should -Be 'exact'
    }
    It 'allow_any_source true is an error outside lab and test, and is not honoured' -ForEach 'dev', 'production', 'dmz' {
        $p = Resolve-For $_ { param($d) $d.os_configuration.remoting.allow_any_source = $true; $d.os_configuration.remoting.certificate = ('AB' * 20) }
        $p.Valid | Should -BeFalse
        @($p.Issues | Where-Object { $_.Id -eq 'AZL-061' -and $_.Severity -eq 'error' }).Count | Should -BeGreaterThan 0
        $p.Firewall.AnySource | Should -BeFalse
        @($p.Firewall.RemoteAddress) | Should -Not -Contain 'Any'
    }
    It 'trusted_hosts: wildcard is lab and test only' {
        (Resolve-For 'lab' { param($d) $d.os_configuration.remoting.allow_any_source = $false; $d.os_configuration.remoting.trusted_hosts = 'wildcard' }).TrustedHosts.Mode | Should -Be 'wildcard'
        foreach ($c in 'dev', 'production', 'dmz') {
            $p = Resolve-For $c { param($d) $d.os_configuration.remoting.trusted_hosts = 'wildcard' }
            @($p.Issues | Where-Object { $_.Id -eq 'AZL-061' -and $_.Path -match 'trusted_hosts' }).Count | Should -Be 1 -Because $c
            $p.TrustedHosts.Mode | Should -Not -Be 'wildcard' -Because $c
        }
    }
    It 'trusted_hosts: exact works in lab, dev and production, and is refused in dmz' {
        (Resolve-For 'lab' { param($d) $d.os_configuration.remoting.trusted_hosts = 'exact' }).TrustedHosts.Mode | Should -Be 'exact'
        (Resolve-For 'production' { param($d) $d.os_configuration.remoting.trusted_hosts = 'exact' }).TrustedHosts.Mode | Should -Be 'exact'
        (Resolve-For 'dmz' { param($d) $d.os_configuration.remoting.trusted_hosts = 'exact' }).Errors -join ' ' | Should -Match 'not allowed in the class dmz'
    }
    It 'use_https true in lab keeps HTTP and adds HTTPS; transport winrm_https does the same' {
        foreach ($set in { param($d) $d.os_configuration.remoting.use_https = $true }, { param($d) $d.os_configuration.remoting.transport = 'winrm_https' }) {
            $p = Resolve-For 'lab' $set
            $p.Transport.HttpsEnabled | Should -BeTrue
            $p.Transport.HttpEnabled | Should -BeTrue
            $p.Transport.Scheme | Should -Be 'https'
        }
    }
    It 'use_https false is an error in production and dmz (HTTPS stays on), a warning in dev (HTTP only)' {
        foreach ($c in 'production', 'dmz') {
            $p = Resolve-For $c { param($d) $d.os_configuration.remoting.use_https = $false; $d.os_configuration.remoting.certificate = ('AB' * 20) }
            @($p.Issues | Where-Object { $_.Id -eq 'AZL-065' -and $_.Severity -eq 'error' }).Count | Should -Be 1 -Because $c
            $p.Transport.HttpsEnabled | Should -BeTrue -Because $c
        }
        $dev = Resolve-For 'dev' { param($d) $d.os_configuration.remoting.use_https = $false }
        @($dev.Issues | Where-Object { $_.Id -eq 'AZL-065' -and $_.Severity -eq 'warning' }).Count | Should -Be 1
        $dev.Valid | Should -BeTrue
        $dev.Transport.HttpsEnabled | Should -BeFalse
        $dev.Transport.HttpEnabled | Should -BeTrue
    }
    It 'isolation_confirmed true is an error outside lab and test, a statement in them' {
        foreach ($c in 'dev', 'production', 'dmz') {
            @((Resolve-For $c { param($d) $d.os_configuration.remoting.isolation_confirmed = $true }).Issues | Where-Object { $_.Id -eq 'AZL-066' }).Count | Should -Be 1 -Because $c
        }
        (Resolve-For 'lab' { param($d) $d.os_configuration.remoting.isolation_confirmed = $true }).Valid | Should -BeTrue
    }
    It 'allowed_source_cidrs: well-formed, not /0 to /8, not wider than the class takes' {
        foreach ($bad in 'not-an-ip', '10.0.0.0/33', '0.0.0.0/0', '10.0.0.0/8', '192.0.2.0/24/3') {
            $script:b = $bad
            $p = Resolve-For 'production' { param($d) $d.os_configuration.remoting.allowed_source_cidrs = @($script:b) }
            @($p.Issues | Where-Object { $_.Id -eq 'AZL-062' -and $_.Severity -eq 'error' }).Count | Should -Be 1 -Because $bad
        }
        $wide = Resolve-For 'dev' { param($d) $d.os_configuration.remoting.allowed_source_cidrs = @('203.0.113.0/23') }
        @($wide.Issues | Where-Object { $_.Id -eq 'AZL-062' -and $_.Message -match 'wider' }).Count | Should -Be 1
        (Resolve-For 'dev' { param($d) $d.os_configuration.remoting.allowed_source_cidrs = @('203.0.113.0/24', '2001:db8::10/128') }).Valid | Should -BeTrue
        (Resolve-For 'lab' { param($d) $d.os_configuration.remoting.allowed_source_cidrs = @('10.0.0.0/9') ; $d.os_configuration.remoting.allow_any_source = $false }).Valid | Should -BeTrue
    }
    It 'dmz sources must be /32 or /128' {
        $p = Resolve-For 'dmz' { param($d) $d.os_configuration.remoting.allowed_source_cidrs = @('203.0.113.0/24'); $d.os_configuration.remoting.certificate = ('AB' * 20) }
        @($p.Issues | Where-Object { $_.Id -eq 'AZL-064' }).Count | Should -Be 1
        (Resolve-For 'dmz' { param($d) $d.os_configuration.remoting.allowed_source_cidrs = @('203.0.113.9/32', '2001:db8::9/128'); $d.os_configuration.remoting.certificate = ('AB' * 20) }).Valid | Should -BeTrue
    }
    It 'production and dmz need at least one allowed source; dev warns' {
        $strip = { param($d) $d.os_configuration.remoting.Remove('allowed_source_cidrs'); $d.networking.management.subnet = '192.0.0.0/16'; $d.networking.Remove('oob'); $d.os_configuration.remoting.certificate = ('AB' * 20) }
        foreach ($c in 'production', 'dmz') {
            @((Resolve-For $c $strip).Issues | Where-Object { $_.Id -eq 'AZL-063' -and $_.Severity -eq 'error' }).Count | Should -Be 1 -Because $c
        }
        $dev = Resolve-For 'dev' $strip
        @($dev.Issues | Where-Object { $_.Id -eq 'AZL-063' -and $_.Severity -eq 'warning' }).Count | Should -BeGreaterThan 0
        $dev.Valid | Should -BeTrue
        @($dev.Issues | Where-Object { $_.Id -eq 'AZL-062' -and $_.Severity -eq 'warning' }).Count | Should -Be 1
    }
    It 'a network marked management or oob is a source in dev and production, a network marked otherwise is not' {
        $mark = { param($d) $d.networking.logical_networks[0].purpose = 'management' }
        @((Resolve-For 'dev' $mark).Firewall.RemoteAddress) | Should -Contain '203.0.113.0/24'
        @((Resolve-For 'production' { param($d) $d.networking.vlans[2].purpose = 'OOB' }).Firewall.RemoteAddress) | Should -Contain '203.0.113.0/24'
        @((Resolve-For 'production').Firewall.RemoteAddress) | Should -Not -Contain '203.0.113.0/24'
        @((Resolve-For 'production' { param($d) $d.networking.logical_networks[0].purpose = 'automation' }).Firewall.RemoteAddress) | Should -Not -Contain '203.0.113.0/24'
    }
    It 'certificate: a thumbprint, a Key Vault reference, malformed is an error, set with HTTPS off is a warning' {
        (Resolve-For 'production' { param($d) $d.os_configuration.remoting.certificate = 'ab:cd ' + ('ab' * 18) }).Certificate.Mode | Should -Be 'thumbprint'
        $kv = (Resolve-For 'production' { param($d) $d.os_configuration.remoting.certificate = 'keyvault://kv-example/node-cert' }).Certificate
        $kv.Mode | Should -Be 'keyVault'
        $kv.Reference | Should -Be 'keyvault://kv-example/node-cert'
        @((Resolve-For 'production' { param($d) $d.os_configuration.remoting.certificate = 'not a cert' }).Issues | Where-Object { $_.Id -eq 'AZL-067' -and $_.Severity -eq 'error' }).Count | Should -Be 1
        @((Resolve-For 'lab' { param($d) $d.os_configuration.remoting.certificate = ('AB' * 20) }).Issues | Where-Object { $_.Id -eq 'AZL-067' -and $_.Severity -eq 'warning' }).Count | Should -Be 1
    }
    It 'bootstrap routes: smb, arc, auto (smb then arc), none' {
        foreach ($case in @{ t = 'smb'; r = @('smb') }, @{ t = 'arc'; r = @('arc') }, @{ t = 'auto'; r = @('smb', 'arc') }, @{ t = 'none'; r = @() }) {
            $script:bt = $case.t
            $p = Resolve-For 'lab' { param($d) $d.os_configuration.remoting.bootstrap_transport = $script:bt }
            @($p.Bootstrap.Routes) | Should -Be $case.r -Because $case.t
            $p.Bootstrap.Chosen | Should -Be ($case.t -ne 'none')
        }
    }
    It 'bootstrap permission: lab needs no approval, production and dmz need -ApprovedBootstrap' {
        $choose = { param($d) $d.os_configuration.remoting.bootstrap_transport = 'auto'; $d.os_configuration.remoting.certificate = ('AB' * 20) }
        (Resolve-For 'lab' $choose).Bootstrap.Permitted | Should -BeTrue
        (Resolve-For 'dev' $choose).Bootstrap.Permitted | Should -BeTrue
        foreach ($c in 'production', 'dmz') {
            $without = Resolve-For $c $choose
            $without.Bootstrap.Permitted | Should -BeFalse -Because $c
            $without.Bootstrap.Reason | Should -Match 'ApprovedBootstrap'
            (Resolve-For $c $choose @{ approved_bootstrap = $true }).Bootstrap.Permitted | Should -BeTrue -Because $c
        }
        (Resolve-For 'production' $null @{ approved_bootstrap = $true }).Bootstrap.Permitted | Should -BeFalse   # approved but never chosen
    }
    It 'dmz and production: an approval kept in a settings file does not count' {
        $choose = { param($d) $d.os_configuration.remoting.bootstrap_transport = 'smb'; $d.os_configuration.remoting.certificate = ('AB' * 20) }
        (Resolve-For 'dmz' $choose @{ approved_bootstrap = $true; approved_bootstrap_source = 'settings' }).Bootstrap.Permitted | Should -BeFalse
        (Resolve-For 'production' $choose @{ approved_bootstrap = $true; approved_bootstrap_source = 'settings' }).Bootstrap.Permitted | Should -BeFalse
    }
    It 'Test-AzlBootstrapPermitted takes the approval of the run on top' {
        $p = Resolve-For 'production' { param($d) $d.os_configuration.remoting.bootstrap_transport = 'arc' }
        (Test-AzlBootstrapPermitted -Bootstrap $p.Bootstrap -Class production).Permitted | Should -BeFalse
        (Test-AzlBootstrapPermitted -Bootstrap $p.Bootstrap -Class production -ApprovedBootstrap).Permitted | Should -BeTrue
    }
    It 'an unknown override key is an error' {
        (Resolve-For 'lab' $null @{ colour = 'blue' }).Errors -join ' ' | Should -Match 'Unknown override'
    }
}

Describe 'The denylist cannot be overridden' {
    It 'an override of <_> is an error' -ForEach 'allow_unencrypted', 'basic', 'credssp', 'skip_ca_check', 'skip_cn_check', 'cbt_hardening_level', 'AllowUnencrypted' {
        $key = $_
        $p = Resolve-For 'lab' $null @{ $key = $true }
        $p.Valid | Should -BeFalse
        $p.Errors -join ' ' | Should -Match 'baseline'
    }
    It 'a profile table that weakens the baseline is refused' -ForEach 'allowUnencrypted', 'basicAuth', 'credSsp', 'skipCACheck', 'skipCNCheck' {
        $table = Get-Content -LiteralPath $script:Table -Raw | ConvertFrom-Json -AsHashtable
        $table.baseline[$_] = $true
        $p = Resolve-AzlRemotingProfile -Infrastructure (Get-Infra) -Data $table
        $p.Valid | Should -BeFalse
        $p.Errors -join ' ' | Should -Match 'weakens the baseline'
    }
    It 'a table that drops a firewall profile is refused' {
        $table = Get-Content -LiteralPath $script:Table -Raw | ConvertFrom-Json -AsHashtable
        $table.baseline.firewallProfiles = @('Domain', 'Private')
        (Resolve-AzlRemotingProfile -Infrastructure (Get-Infra) -Data $table).Valid | Should -BeFalse
    }
    It 'the baseline is the same in every class' -ForEach 'lab', 'test', 'dev', 'production', 'dmz' {
        $p = Resolve-For $_
        $p.Baseline.allowUnencrypted | Should -BeFalse
        $p.Baseline.basicAuth | Should -BeFalse
        $p.Baseline.credSsp | Should -BeFalse
        $p.Baseline.skipCACheck | Should -BeFalse
        $p.Baseline.skipCNCheck | Should -BeFalse
        @($p.Firewall.Profiles) | Should -Be @('Domain', 'Private', 'Public')
    }
}

Describe 'Reporting the profile' {
    It 'Format-AzlRemotingProfile prints the class, the source of each setting and the warnings' {
        $text = (Format-AzlRemotingProfile -RemotingProfile (Resolve-For 'lab')) -join "`n"
        $text | Should -Match 'class lab'
        $text | Should -Match 'firewall.remoteAddress\s+Any'
        $text | Should -Match 'WARNING: Relaxed remote management posture'
        $text | Should -Match '\[class table'
    }
    It 'ConvertTo-AzlRemotingReport holds the posture and no secret' {
        $report = ConvertTo-AzlRemotingReport -RemotingProfile (Resolve-For 'production' { param($d) $d.os_configuration.remoting.certificate = 'keyvault://kv-example/node-cert' })
        $report.class | Should -Be 'production'
        $report.posture | Should -Be 'restricted'
        $json = $report | ConvertTo-Json -Depth 8
        $json | Should -Match 'keyvault://kv-example/node-cert'
        $json | Should -Not -Match '(?i)password|secret"'
    }
}

Describe 'ConvertTo-AzlCidr' {
    It '<Text> normalises to <Normalized>' -ForEach @(
        @{ Text = '192.0.2.77/24'; Normalized = '192.0.2.0/24' }
        @{ Text = '198.51.100.10'; Normalized = '198.51.100.10/32' }
        @{ Text = '2001:db8::5/64'; Normalized = '2001:db8::/64' }
        @{ Text = '2001:db8::5'; Normalized = '2001:db8::5/128' }
    ) {
        $c = ConvertTo-AzlCidr -Text $Text
        $c.Valid | Should -BeTrue
        $c.Normalized | Should -Be $Normalized
    }
    It '<_> is not an address or CIDR' -ForEach '', 'host.example', '1.2.3', '10.0.0.0/40', '10.0.0.0/x', 'fe80::1%eth0', '1.2.3.4/5/6' {
        (ConvertTo-AzlCidr -Text $_).Valid | Should -BeFalse
    }
}

Describe 'Validator rules AZL-060 to AZL-068 on infrastructure.yml' {
    It 'the main template is clean' {
        @(Get-FindingFor { }) | Should -BeNullOrEmpty
    }
    It 'AZL-060 rejects a class that is not one of the five (the message names them)' {
        $f = @(Get-FindingFor { param($d) $d.scenario.environment_class = 'staging' } | Where-Object Id -eq 'AZL-060')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'error'
        $f[0].Message | Should -Match 'lab, test, dev, production, dmz'
    }
    It 'a missing class is accepted (it means production)' {
        @(Get-FindingFor { param($d) $d.scenario.Remove('environment_class') }) | Should -BeNullOrEmpty
    }
    It 'AZL-061 allows Any and the wildcard in lab and test only' {
        @(Get-FindingFor { param($d) $d.os_configuration.remoting.allow_any_source = $true } | Where-Object { $_.Id -eq 'AZL-061' -and $_.Severity -eq 'error' }).Count | Should -Be 1
        @(Get-FindingFor { param($d) $d.os_configuration.remoting.trusted_hosts = 'wildcard' } | Where-Object { $_.Id -eq 'AZL-061' -and $_.Severity -eq 'error' }).Count | Should -Be 1
        @(Get-FindingFor { param($d) $d.scenario.environment_class = 'lab'; $d.os_configuration.remoting.allow_any_source = $true; $d.os_configuration.remoting.trusted_hosts = 'wildcard' } | Where-Object { $_.Severity -eq 'error' }) | Should -BeNullOrEmpty
    }
    It 'AZL-062 checks the allowed source addresses' {
        $f = @(Get-FindingFor { param($d) $d.os_configuration.remoting.allowed_source_cidrs = @('10.0.0.0/8', 'nonsense', '203.0.113.0/23') } | Where-Object Id -eq 'AZL-062')
        $f.Count | Should -Be 3
    }
    It 'AZL-063 needs a source in production and dmz' {
        $f = @(Get-FindingFor { param($d) $d.scenario.environment_class = 'production'; $d.os_configuration.remoting.Remove('allowed_source_cidrs'); $d.networking.management.subnet = '192.0.0.0/16'; $d.networking.Remove('oob') } | Where-Object { $_.Id -eq 'AZL-063' -and $_.Severity -eq 'error' })
        $f.Count | Should -Be 1
    }
    It 'AZL-064 wants single addresses in dmz' {
        @(Get-FindingFor { param($d) $d.scenario.environment_class = 'dmz'; $d.os_configuration.remoting.certificate = ('AB' * 20) } | Where-Object Id -eq 'AZL-064') | Should -BeNullOrEmpty
        @(Get-FindingFor { param($d) $d.scenario.environment_class = 'dmz'; $d.os_configuration.remoting.certificate = ('AB' * 20); $d.os_configuration.remoting.allowed_source_cidrs = @('203.0.113.0/24') } | Where-Object Id -eq 'AZL-064').Count | Should -Be 1
    }
    It 'AZL-065 refuses HTTP in production and warns in dev' {
        @(Get-FindingFor { param($d) $d.os_configuration.remoting.use_https = $false } | Where-Object { $_.Id -eq 'AZL-065' -and $_.Severity -eq 'error' }).Count | Should -Be 1
        @(Get-FindingFor { param($d) $d.scenario.environment_class = 'dev'; $d.os_configuration.remoting.use_https = $false } | Where-Object { $_.Id -eq 'AZL-065' -and $_.Severity -eq 'warning' }).Count | Should -Be 1
    }
    It 'AZL-066 does not allow the isolation statement outside lab and test' {
        @(Get-FindingFor { param($d) $d.os_configuration.remoting.isolation_confirmed = $true } | Where-Object Id -eq 'AZL-066').Count | Should -Be 1
        @(Get-FindingFor { param($d) $d.scenario.environment_class = 'test'; $d.os_configuration.remoting.isolation_confirmed = $true } | Where-Object Id -eq 'AZL-066') | Should -BeNullOrEmpty
    }
    It 'AZL-067 checks the certificate' {
        @(Get-FindingFor { param($d) $d.os_configuration.remoting.certificate = 'zzz' } | Where-Object { $_.Id -eq 'AZL-067' -and $_.Severity -eq 'error' }).Count | Should -Be 1
        @(Get-FindingFor { param($d) $d.scenario.environment_class = 'dmz' } | Where-Object { $_.Id -eq 'AZL-067' -and $_.Severity -eq 'error' }).Count | Should -Be 1
    }
    It 'AZL-068 warns about the relaxed classes and says what is open' {
        $f = @(Get-FindingFor { param($d) $d.scenario.environment_class = 'lab' } | Where-Object Id -eq 'AZL-068')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'warning'
        $f[0].Message | Should -Match 'any source'
    }
    It 'the schema rejects an unknown key in os_configuration.remoting, and a bad purpose' {
        @(Get-FindingFor { param($d) $d.os_configuration.remoting['typo'] = 1 } | Where-Object { $_.Id -eq 'SCHEMA' }).Count | Should -BeGreaterThan 0
        @(Get-FindingFor { param($d) $d.networking.logical_networks[0].purpose = 'dmz-net' } | Where-Object { $_.Id -eq 'SCHEMA' }).Count | Should -BeGreaterThan 0
        @(Get-FindingFor { param($d) $d.os_configuration.remoting.bootstrap_transport = 'ssh' } | Where-Object { $_.Id -eq 'SCHEMA' }).Count | Should -BeGreaterThan 0
    }
    It 'bootstrap_transport accepts none, arc, smb and auto' -ForEach 'none', 'arc', 'smb', 'auto' {
        $v = $_
        @(Get-FindingFor { param($d) $d.os_configuration.remoting.bootstrap_transport = $v } | Where-Object { $_.Severity -eq 'error' }) | Should -BeNullOrEmpty
    }
}
