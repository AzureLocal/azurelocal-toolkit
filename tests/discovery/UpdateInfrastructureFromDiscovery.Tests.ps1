#Requires -Version 7.0
# Update-InfrastructureYml-FromDiscovery.ps1 end to end, offline: a vendor-neutral hardware inventory (Get-HardwareInventory.ps1,
# kind hardware-inventory) is written back into a file with flow-style adapter entries and placeholder MACs.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/discovery/UpdateInfrastructureFromDiscovery.Tests.ps1

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Script = [System.IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-01-hardware-provisioning', 'task-02-hardware-discovery-via-dell-redfish-api', 'powershell', 'Update-InfrastructureYml-FromDiscovery.ps1')
    $script:InfraText = @'
nodes:
  - name: n01
    serial_number: ""
    network_adapters:
      - { name: Port1, mac_address: 00:00:5E:00:53:21, slot: "Slot 3" }
      - { name: Port2, mac_address: 00:00:5E:00:53:22, slot: "Slot 3" }
'@
    function New-Inventory([string]$Mac1, [string]$Mac2) {
        @{
            kind = 'hardware-inventory'; collectedAt = '2026-11-24T00:00:00Z'
            nodes = @(@{
                    name = 'n01'; status = 'read'; identity = @{ serialNumber = 'SN-0001'; model = 'Example Model'; manufacturer = 'Example' }
                    network = @{ ports = @(
                            @{ mac = $Mac1; adapter = 'NIC.Slot.3'; portNumber = 1; name = 'Port1'; slot = 'Slot 3' }
                            @{ mac = $Mac2; adapter = 'NIC.Slot.3'; portNumber = 2; name = 'Port2'; slot = 'Slot 3' }
                        ) }
                })
        } | ConvertTo-Json -Depth 10
    }
    function Invoke-Updater([string[]]$Argument) {
        $out = & pwsh -NoProfile -File $script:Script @Argument 2>&1
        [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($out | Out-String) }
    }
}

Describe 'Update-InfrastructureYml-FromDiscovery.ps1 with a hardware inventory' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'disc') | Out-Null
        $script:File = Join-Path $script:Dir 'infrastructure.yml'
        [System.IO.File]::WriteAllText($script:File, $script:InfraText)
    }

    It 'places the MACs and the serial number of flow-style entries and exits 0' {
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'disc' 'hardware-inventory-1.json'), (New-Inventory 'AA:BB:CC:00:00:01' 'AA:BB:CC:00:00:02'))
        $r = Invoke-Updater @('-InfrastructureFile', $script:File, '-DiscoveryPath', (Join-Path $script:Dir 'disc'), '-Apply', '-Force')
        $r.Exit | Should -Be 0
        $text = Get-Content -LiteralPath $script:File -Raw
        $text | Should -Match 'mac_address: "AA:BB:CC:00:00:01"'
        $text | Should -Match 'mac_address: "AA:BB:CC:00:00:02"'
        $text | Should -Not -Match '00:00:5E:00:53:2'
        $text | Should -Match 'serial_number: "SN-0001"'
        @(Get-ChildItem -LiteralPath $script:Dir -Filter 'infrastructure.yml.bak.*').Count | Should -Be 1
    }

    It 'writes nothing without -Apply' {
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'disc' 'hardware-inventory-1.json'), (New-Inventory 'AA:BB:CC:00:00:01' 'AA:BB:CC:00:00:02'))
        $before = Get-Content -LiteralPath $script:File -Raw
        $r = Invoke-Updater @('-InfrastructureFile', $script:File, '-DiscoveryPath', (Join-Path $script:Dir 'disc'))
        (Get-Content -LiteralPath $script:File -Raw) | Should -Be $before
    }

    It 'exits 2 with a clear message when the folder holds no discovery file' {
        $r = Invoke-Updater @('-InfrastructureFile', $script:File, '-DiscoveryPath', (Join-Path $script:Dir 'disc'))
        $r.Exit | Should -Be 2
        $r.Output | Should -Match 'No usable discovery file'
    }
}

Describe 'Update-InfrastructureYml-FromDiscovery.ps1 exit codes and matching' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'disc') | Out-Null
        $script:File = Join-Path $script:Dir 'infrastructure.yml'
    }

    It 'restores a blanked MAC on an adapter named Port1 by slot and port_index and exits 0' {
        $text = @'
nodes:
  - name: n01
    serial_number: SN-0001
    network_adapters:
      - { name: Port1, slot: "Slot 3", port_index: 1, mac_address: "" }
      - { name: Port2, slot: "Slot 3", port_index: 2, mac_address: "AA:BB:CC:00:00:02" }
'@
        [System.IO.File]::WriteAllText($script:File, $text)
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'disc' 'hardware-inventory-1.json'), (New-Inventory 'AA:BB:CC:00:00:01' 'AA:BB:CC:00:00:02'))
        $r = Invoke-Updater @('-InfrastructureFile', $script:File, '-DiscoveryPath', (Join-Path $script:Dir 'disc'), '-Apply', '-Force')
        $r.Exit | Should -Be 0
        (Get-Content -LiteralPath $script:File -Raw) | Should -Match 'name: Port1.*mac_address: "AA:BB:CC:00:00:01"'
    }

    It 'exits 1 and lists the value when a MAC cannot be placed (the node has no adapter list)' {
        [System.IO.File]::WriteAllText($script:File, "nodes:`n  - name: n01`n    serial_number: `"`"`n    management:`n      mac_address: `"00:00:5E:00:53:11`"`n")
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'disc' 'hardware-inventory-1.json'), (New-Inventory 'AA:BB:CC:00:00:01' 'AA:BB:CC:00:00:02'))
        $r = Invoke-Updater @('-InfrastructureFile', $script:File, '-DiscoveryPath', (Join-Path $script:Dir 'disc'))
        $r.Exit | Should -Be 1
        $r.Output | Should -Match 'Not settled'
        $r.Output | Should -Match '-ManagementPort'
    }

    It 'replaces a management placeholder MAC with -ManagementPort and exits 0' {
        [System.IO.File]::WriteAllText($script:File, "nodes:`n  - name: n01`n    serial_number: `"`"`n    management:`n      mac_address: `"00:00:5E:00:53:11`"`n")
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'disc' 'hardware-inventory-1.json'), (New-Inventory 'AA:BB:CC:00:00:01' 'AA:BB:CC:00:00:02'))
        $r = Invoke-Updater @('-InfrastructureFile', $script:File, '-DiscoveryPath', (Join-Path $script:Dir 'disc'), '-ManagementPort', 'Port1', '-Apply', '-Force')
        $r.Exit | Should -Be 0
        $out = Get-Content -LiteralPath $script:File -Raw
        $out | Should -Match 'mac_address: "AA:BB:CC:00:00:01"'
        $out | Should -Not -Match '00:00:5E:00:53:11'
    }
}

Describe 'The keys that discovery writes pass the schema' {
    It 'accepts nodes[].bmc.mac_address, hardware.drives.*.model and hardware.boot_drives in a valid file' {
        $example = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($script:Repo, 'config', 'variables', 'examples', 'infrastructure.ztp.example.yml'))
        $example = $example -replace 'bmc: \{ ip_address: "198.51.100.11", type: idrac \}', 'bmc: { ip_address: "198.51.100.11", type: idrac, mac_address: "00:00:5E:00:53:F1" }'
        $example | Should -Match 'mac_address: "00:00:5E:00:53:F1"'
        $example = $example -replace '(?m)^hardware:\r?\n', "hardware:`n  boot_drives: { type: boss, count: 2, size_gb: 960, model: `"Example M.2 960GB`" }`n  drives:`n    capacity: { media: nvme, count: 4, size_tb: 3.84, model: `"Example NVMe 3.84TB`" }`n"
        $file = Join-Path $TestDrive 'schema-check.yml'
        [System.IO.File]::WriteAllText($file, $example)
        $validator = [System.IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'Test-InfrastructureFile.ps1')
        $out = & pwsh -NoProfile -File $validator -Path $file 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }
}

Describe 'Resolve-AzlDiscoveryDirectory (the default of Invoke-HardwareDiscovery.ps1 -OutputPath and of the updater -DiscoveryPath)' {
    BeforeAll {
        Import-Module ([System.IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    }

    It 'uses hardware.discovery.output_directory, a relative one against the folder of the file' {
        $infra = @{ hardware = @{ discovery = @{ output_directory = 'found' } }; provisioning = @{ simplified = @{ evidence_path = 'ev' } } }
        $dir = Join-Path $TestDrive 'site'
        $r = Resolve-AzlDiscoveryDirectory -Infrastructure $infra -InfrastructureFile (Join-Path $dir 'infrastructure.yml')
        $r | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $dir 'found')))
    }

    It 'falls back to <evidence_path>\discovery, the folder Sonar derives' {
        $infra = @{ provisioning = @{ simplified = @{ evidence_path = (Join-Path $TestDrive 'evidence') } } }
        $r = Resolve-AzlDiscoveryDirectory -Infrastructure $infra -InfrastructureFile (Join-Path $TestDrive 'infrastructure.yml')
        $r | Should -Be ([System.IO.Path]::GetFullPath((Join-Path (Join-Path $TestDrive 'evidence') 'discovery')))
    }

    It 'ends in discovery in the current folder when nothing is configured' {
        $r = Resolve-AzlDiscoveryDirectory -Infrastructure @{ cluster = @{ name = 'x' } }
        $r | Should -Be (Join-Path (Get-Location).ProviderPath 'discovery')
    }
}
