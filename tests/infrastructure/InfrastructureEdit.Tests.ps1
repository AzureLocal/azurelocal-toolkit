#Requires -Version 7.0
# Line-level YAML edit used by hardware discovery write-back (Update-InfrastructureYml-FromDiscovery.ps1):
# flow-style list entries, quoted values, trailing commas, block-style entries.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/infrastructure/InfrastructureEdit.Tests.ps1

BeforeAll {
    Set-StrictMode -Version Latest
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module ([System.IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructureEdit.psm1')) -Force
    function New-Lines([string]$Text) { return , [System.Collections.Generic.List[string]]::new([string[]]($Text -split "\r?\n")) }
}

Describe 'Edit-AzlYamlValue on flow-style list entries' {
    It 'replaces a value inside the braces and leaves the other lines alone' {
        $lines = New-Lines @'
nodes:
  - name: n01
    network_adapters:
      - { name: Port1, mac_address: 00:00:5E:00:53:21, slot: "Slot 3" } # first
      - { name: Port2, mac_address: 00:00:5E:00:53:22 }
'@
        $r = Edit-AzlYamlValue -Lines $lines -Path @('nodes', '[name=n01]', 'network_adapters', '[name=Port1]', 'mac_address') -Value 'AA:BB:CC:DD:EE:01'
        $r.Result | Should -Be 'Changed'
        $r.Old | Should -Be '00:00:5E:00:53:21'
        $lines[3] | Should -Be '      - { name: Port1, mac_address: "AA:BB:CC:DD:EE:01", slot: "Slot 3" } # first'
        $lines[4] | Should -Be '      - { name: Port2, mac_address: 00:00:5E:00:53:22 }'
    }

    It 'reports Unchanged when the value is already there' {
        $lines = New-Lines "a:`n  - { name: P, mac_address: `"AA:BB:CC:DD:EE:01`" }"
        (Edit-AzlYamlValue -Lines $lines -Path @('a', '[name=P]', 'mac_address') -Value 'AA:BB:CC:DD:EE:01').Result | Should -Be 'Unchanged'
    }

    It 'inserts a missing key only with -InsertIfMissing' {
        $lines = New-Lines "a:`n  - { name: P, slot: S }"
        (Edit-AzlYamlValue -Lines $lines -Path @('a', '[name=P]', 'port_index') -Value 2).Result | Should -Be 'NotFound'
        (Edit-AzlYamlValue -Lines $lines -Path @('a', '[name=P]', 'port_index') -Value 2 -InsertIfMissing).Result | Should -Be 'Inserted'
        $lines[1] | Should -Be '  - { name: P, slot: S, port_index: 2 }'
    }

    It 'does not double a trailing comma when it inserts' {
        $lines = New-Lines "a:`n  - { name: P, slot: S, }"
        (Edit-AzlYamlValue -Lines $lines -Path @('a', '[name=P]', 'port_index') -Value 2 -InsertIfMissing).Result | Should -Be 'Inserted'
        $lines[1] | Should -Not -Match ',,'
        $lines[1] | Should -Match 'port_index: 2'
    }

    It 'finds an entry whose value holds a comma or an apostrophe' {
        $lines = New-Lines "a:`n  - { name: `"P, one`", note: O'Brien, mac_address: AA }"
        $r = Edit-AzlYamlValue -Lines $lines -Path @('a', '[name=P, one]', 'mac_address') -Value 'BB'
        $r.Result | Should -Be 'Changed'
        $lines[1] | Should -Be "  - { name: `"P, one`", note: O'Brien, mac_address: `"BB`" }"
    }

    It 'matches key names case-sensitively' {
        $lines = New-Lines "a:`n  - { name: P, Mac_Address: AA }"
        (Edit-AzlYamlValue -Lines $lines -Path @('a', '[name=P]', 'mac_address') -Value 'BB').Result | Should -Be 'NotFound'
    }

    It 'returns NotFound for an entry that is not in the list' {
        $lines = New-Lines "a:`n  - { name: P, mac_address: AA }"
        (Edit-AzlYamlValue -Lines $lines -Path @('a', '[name=Q]', 'mac_address') -Value 'BB').Result | Should -Be 'NotFound'
    }
}

Describe 'Edit-AzlYamlValue on block-style list entries' {
    It 'still edits a block entry and keeps the comment' {
        $lines = New-Lines @'
a:
  - name: P
    mac_address: 00:00:5E:00:53:21   # placeholder
  - name: Q
    mac_address: 00:00:5E:00:53:22
'@
        $r = Edit-AzlYamlValue -Lines $lines -Path @('a', '[name=P]', 'mac_address') -Value 'AA:BB:CC:DD:EE:01'
        $r.Result | Should -Be 'Changed'
        $lines[2] | Should -Be '    mac_address: "AA:BB:CC:DD:EE:01"   # placeholder'
        $lines[4] | Should -Be '    mac_address: 00:00:5E:00:53:22'
    }
}
