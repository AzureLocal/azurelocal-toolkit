#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Stage 03 (on-premises readiness), task 02: New-SwitchConfiguration.ps1 renders config/network-devices/switches/<vendor>/*.template once per
# network_devices[] switch of infrastructure.yml. The tests render the example infrastructure file and variants of it into TestDrive:
#   * every placeholder is filled, nothing is left, -WhatIf writes nothing, the files hold what the output says;
#   * the QoS follows the registry (Network ATC defaults cluster 7, SMB 3, 50 percent) and the overrides of the storage intent;
#   * a missing key stops the run with exit code 2 and the key name; no password is ever read or written;
#   * the template holds no site value: no address, MAC, VLAN number or name, and every placeholder names a key of the schema.
# Nothing connects to a switch, a node or Azure.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/SwitchConfiguration.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '03-onprem-readiness', 'phase-03-network-infrastructure', 'task-02-dell-powerswitch-configuration', 'powershell', 'New-SwitchConfiguration.ps1')
    $script:Template = [IO.Path]::Combine($script:Repo, 'config', 'network-devices', 'switches', 'dell', 'tor.os10.template')
    $script:Example = [IO.Path]::Combine($script:Repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $script:Schema = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Import-Module powershell-yaml

    function Get-ExampleDoc { Get-Content -LiteralPath $script:Example -Raw | ConvertFrom-Yaml -Ordered }
    function New-InfraFile([System.Collections.IDictionary]$Doc) {
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $Doc)
        $file
    }
    function Invoke-Render([string]$File, [switch]$Write, [string]$Out = (Join-Path $TestDrive ("out-" + [guid]::NewGuid().ToString('N').Substring(0, 6)))) {
        $global:LASTEXITCODE = $null
        $all = if ($Write) { & $script:Script -InfrastructureFile $File -OutputDirectory $Out 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File -OutputDirectory $Out -WhatIf 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Out      = $Out
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Hostname'] -and $_.PSObject.Properties['Text'] })
            Messages = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.ErrorRecord] -or $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    # True when the dotted path (selectors as []) is a key of infrastructure.schema.json.
    function Test-SchemaPath([string]$Path) {
        $node = $script:Schema
        foreach ($segment in ($Path -replace '\[[^\]]*\]', '[]') -split '\.') {
            $name = $segment -replace '\[\]$', ''
            if (-not ($node -is [System.Collections.IDictionary] -and $node.Contains('properties') -and $node.properties.Contains($name))) { return $false }
            $node = $node.properties[$name]
            if ($segment.EndsWith('[]')) { $node = $node.items }
        }
        return $true
    }
}

Describe 'New-SwitchConfiguration.ps1 with the example infrastructure file' {
    BeforeAll { $script:Example1 = Invoke-Render $script:Example }

    It 'renders both switches with exit code 0 and writes nothing with -WhatIf' {
        $script:Example1.ExitCode | Should -Be 0 -Because $script:Example1.Messages
        @($script:Example1.Rows | ForEach-Object { $_.Hostname }) | Should -Be @('sw01-iic', 'sw02-iic')
        @($script:Example1.Rows | ForEach-Object { $_.Action } | Sort-Object -Unique) | Should -Be @('Rendered')
        Test-Path -LiteralPath $script:Example1.Out | Should -BeFalse
    }
    It 'leaves no placeholder and no template note' {
        foreach ($r in $script:Example1.Rows) {
            $r.Text | Should -Not -Match '\{\{|\}\}'
            $r.Text | Should -Not -Match '(?m)^!!'
        }
    }
    It 'fills the values of each switch from the file' {
        $one = $script:Example1.Rows[0].Text; $two = $script:Example1.Rows[1].Text
        $one | Should -Match '(?m)^hostname sw01-iic$'
        $one | Should -Match '(?m)^\s+ip address 198\.51\.100\.6/24$'
        $one | Should -Match '(?m)^management route 0\.0\.0\.0/0 198\.51\.100\.1$'
        $one | Should -Match '(?m)^\s+backup destination 198\.51\.100\.7$'
        $two | Should -Match '(?m)^\s+backup destination 198\.51\.100\.6$'
        $one | Should -Match '(?m)^\s+primary-priority 100$'
        $two | Should -Match '(?m)^\s+primary-priority 200$'
        $one | Should -Match '(?m)^\s+vlt-mac 00:00:5e:00:53:01$'
        $one | Should -Match '(?m)^clock timezone CST -6 0$'
        $one | Should -Match '(?m)^ntp server 192\.0\.2\.4$'
        $one | Should -Match '(?m)^ip name-server 192\.0\.2\.5$'
        $one | Should -Match '(?m)^\s+seq 10 permit ip 198\.51\.100\.0/24 any log$'
        $one | Should -Match '(?m)^interface ethernet1/1/3$'
        $one | Should -Match '(?m)^\s+mtu 9216$'
    }
    It 'puts the untagged management traffic in the native VLAN and keeps it out of the tagged list' {
        $one = $script:Example1.Rows[0].Text
        $one | Should -Match '(?m)^\s+switchport access vlan 2201$'
        $one | Should -Match '(?m)^\s+switchport trunk allowed vlan 2204$'
        $one | Should -Match '(?m)^\s+switchport trunk allowed vlan 711,712$'
    }
    It 'follows Network ATC through the registry defaults: cluster 7 with 1 percent at 25 Gbps, SMB 3 with 50 percent, PFC on 3' {
        $one = $script:Example1.Rows[0].Text
        $one | Should -Match '(?m)^\s+qos-group 7 dot1p 7$'
        $one | Should -Match '(?m)^\s+qos-group 3 dot1p 3$'
        $one | Should -Match '(?m)^\s+qos-group 0 dot1p 0-2,4-6$'
        $one | Should -Match '(?m)^\s+pfc-cos 3$'
        $one | Should -Match '(?ms)class QSmb\s+bandwidth percent 50'
        $one | Should -Match '(?ms)class QCluster\s+bandwidth percent 1\b'
        $one | Should -Match '(?ms)class QDefault\s+bandwidth percent 49'
        $one | Should -Not -Match 'dot1p 5\b'
    }
    It 'names the password reference and never a password' {
        $script:Example1.Rows[0].Text | Should -Match 'keyvault://kv-iic-mgmt-01/switch-admin-password'
        $script:Example1.Rows[0].Text | Should -Not -Match '(?m)^\s*username \S+ password'
    }
    It 'leaves syslog and SNMP out (parked)' {
        $script:Example1.Rows[0].Text | Should -Not -Match '(?m)^\s*(logging server|snmp-server)'
    }
}

Describe 'New-SwitchConfiguration.ps1 writes and follows the file' {
    It 'writes <hostname>.cfg with the rendered text' {
        $r = Invoke-Render $script:Example -Write
        $r.ExitCode | Should -Be 0 -Because $r.Messages
        foreach ($row in $r.Rows) {
            $row.Action | Should -Be 'Written'
            [IO.File]::ReadAllText((Join-Path $r.Out "$($row.Hostname).cfg")) | Should -BeExactly $row.Text
        }
    }
    It 'takes the QoS overrides of the storage intent and 2 percent for the cluster at 10 Gbps' {
        $doc = Get-ExampleDoc
        $doc.networking.intents[1]['overrides'] = [ordered]@{ qos = [ordered]@{ cluster_priority = 5; smb_priority = 4; smb_bandwidth_percent = 40 } }
        foreach ($card in $doc.hardware.network_cards) { foreach ($p in $card.ports) { $p.speed_gbps = 10 } }
        $r = Invoke-Render (New-InfraFile $doc)
        $r.ExitCode | Should -Be 0 -Because $r.Messages
        $t = $r.Rows[0].Text
        $t | Should -Match '(?m)^\s+qos-group 5 dot1p 5$'
        $t | Should -Match '(?m)^\s+pfc-cos 4$'
        $t | Should -Match '(?m)^\s+qos-group 0 dot1p 0-3,6-7$'
        $t | Should -Match '(?ms)class QSmb\s+bandwidth percent 40'
        $t | Should -Match '(?ms)class QCluster\s+bandwidth percent 2\b'
        $t | Should -Match '(?ms)class QDefault\s+bandwidth percent 58'
    }
    It 'switchless storage: no storage VLAN and no PFC on the switch' {
        $doc = Get-ExampleDoc
        $doc.scenario.storage_connectivity = 'switchless'
        $r = Invoke-Render (New-InfraFile $doc)
        $r.ExitCode | Should -Be 0 -Because $r.Messages
        $r.Rows[0].Text | Should -Not -Match 'pfc-cos|priority-flow-control|StorageNetwork1'
        $r.Rows[0].Text | Should -Not -Match 'allowed vlan 711'
    }
    It 'a tagged management VLAN needs no native VLAN and is carried tagged' {
        $doc = Get-ExampleDoc
        $doc.networking.management.vlan_id = 2210
        foreach ($d in $doc.network_devices) { $d.ports.Remove('native_vlan_id') }
        $r = Invoke-Render (New-InfraFile $doc)
        $r.ExitCode | Should -Be 0 -Because $r.Messages
        $r.Rows[0].Text | Should -Not -Match 'switchport access vlan'
        $r.Rows[0].Text | Should -Match '(?m)^\s+switchport trunk allowed vlan 2204,2210$'
    }
    It 'a switch without a template for its vendor is skipped, not failed' {
        $doc = Get-ExampleDoc
        $doc.network_devices[1].vendor = 'ExampleVendor'
        $r = Invoke-Render (New-InfraFile $doc)
        $r.ExitCode | Should -Be 0 -Because $r.Messages
        @($r.Rows | Where-Object { $_.Action -eq 'Skipped' }).Hostname | Should -Be 'sw02-iic'
    }
    It 'a file without switches does nothing, exit code 0' {
        $doc = Get-ExampleDoc
        $doc.Remove('network_devices')
        (Invoke-Render (New-InfraFile $doc)).ExitCode | Should -Be 0
    }
}

Describe 'New-SwitchConfiguration.ps1 stops on a missing or wrong value (exit code 2, the key named)' {
    It '<Name>' -ForEach @(
        @{ Name = 'no mtu'; Key = 'network_devices\[\]\.mtu'; Change = { param($d) $d.network_devices[0].Remove('mtu') } }
        @{ Name = 'untagged management without a native VLAN'; Key = 'native_vlan_id'; Change = { param($d) $d.network_devices[0].ports.Remove('native_vlan_id') } }
        @{ Name = 'a pair without its peer address'; Key = 'ha\.peer_address'; Change = { param($d) $d.network_devices[0].ha.Remove('peer_address') } }
        @{ Name = 'no time zone'; Key = 'site\.time_zone'; Change = { param($d) $d.site.Remove('time_zone') } }
        @{ Name = 'no out-of-band gateway'; Key = 'networking\.oob\.gateway'; Change = { param($d) $d.networking.oob.Remove('gateway') } }
        @{ Name = 'no adapter speed for the cluster reservation'; Key = 'speed_gbps'; Change = { param($d) foreach ($c in $d.hardware.network_cards) { foreach ($p in $c.ports) { $p.Remove('speed_gbps') } } } }
        @{ Name = 'a password value instead of a reference'; Key = 'credentials\.password'; Change = { param($d) $d.network_devices[0].credentials.password = 'not-a-reference' } }
    ) {
        $doc = Get-ExampleDoc
        & $Change $doc
        $r = Invoke-Render (New-InfraFile $doc) -Write
        $r.ExitCode | Should -Be 2 -Because $r.Messages
        $r.Messages | Should -Match $Key
        Test-Path -LiteralPath $r.Out | Should -BeFalse -Because 'nothing is written when a value is missing'
    }
    It 'never reads the password: the value behind the reference is not in any output' {
        $doc = Get-ExampleDoc
        foreach ($d in $doc.network_devices) { $d.credentials.password = 'env://AZL_TEST_SWITCH_PASSWORD' }
        $secret = [guid]::NewGuid().ToString()
        $env:AZL_TEST_SWITCH_PASSWORD = $secret
        try {
            $r = Invoke-Render (New-InfraFile $doc) -Write
            $r.ExitCode | Should -Be 0 -Because $r.Messages
            foreach ($row in $r.Rows) { $row.Text | Should -Not -Match $secret }
            $r.Messages | Should -Not -Match $secret
        }
        finally { Remove-Item Env:AZL_TEST_SWITCH_PASSWORD -ErrorAction SilentlyContinue }
    }
}

Describe 'The Dell template holds no site value' {
    BeforeAll {
        $script:Lines = @(Get-Content -LiteralPath $script:Template | Where-Object { -not $_.StartsWith('!!') })
        $script:Body = $script:Lines -join "`n"
        # The text with every placeholder taken out: what is left is fixed text.
        $script:Fixed = [regex]::Replace($script:Body, '\{\{[^}]*\}\}', '')
    }
    It 'has no IPv4 address but the default route 0.0.0.0/0' {
        @([regex]::Matches($script:Fixed, '\b\d{1,3}(\.\d{1,3}){3}\b') | ForEach-Object { $_.Value } | Where-Object { $_ -ne '0.0.0.0' }) | Should -BeNullOrEmpty
    }
    It 'has no MAC address' {
        $script:Fixed | Should -Not -Match '\b[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}\b'
    }
    It 'names no VLAN, host, server, user, domain or time zone' {
        $script:Fixed | Should -Not -Match '(?m)^[ \t]*interface vlan[ \t]*\d'
        $script:Fixed | Should -Not -Match 'allowed vlan[ \t]*\d'
        $script:Fixed | Should -Not -Match '(?m)^hostname[ \t]+\S'
        $script:Fixed | Should -Not -Match '(?m)^[ \t]*(ntp server|ip name-server|backup destination|vlt-domain|vlt-mac)[ \t]+\S'
        $script:Fixed | Should -Not -Match '(?m)^clock timezone[ \t]+\S'
        $script:Fixed | Should -Not -Match '(?m)^[ \t]*mtu[ \t]+\d'
        $script:Fixed | Should -Not -Match '(?i)contoso|improbability|\biic\b'
    }
    It 'has no syslog or SNMP line (parked) and no password' {
        $script:Body | Should -Not -Match '(?m)^\s*(logging server|snmp-server)'
        $script:Body | Should -Not -Match '(?m)^\s*username \S+ password'
    }
    It 'every placeholder names a key of infrastructure.yml (or a documented Network ATC value): <_>' -ForEach @(
        [regex]::Matches((@(Get-Content -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'config', 'network-devices', 'switches', 'dell', 'tor.os10.template')) | Where-Object { -not $_.StartsWith('!!') }) -join "`n"), '\{\{[#/]?(?:each |if )?(?<e>[^}]*)\}\}') |
            ForEach-Object { ($_.Groups['e'].Value -split '\|')[0] -split '\+' } | ForEach-Object { ($_.Trim() -split '=(?![^\[]*\])')[0] } |
            Where-Object { $_ -and $_ -notin 'each', 'if' -and -not $_.StartsWith('.') -and -not $_.StartsWith('atc.') } | Sort-Object -Unique
    ) {
        Test-SchemaPath $_ | Should -BeTrue -Because "$_ must be a key of the master registry"
    }
    It 'uses only the Network ATC values it documents' {
        @([regex]::Matches($script:Body, '\{\{(atc\.[a-z_]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) |
            Should -Be @('atc.cluster_bandwidth_percent', 'atc.default_bandwidth_percent', 'atc.default_priorities')
    }
}
