#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The adapter model of infrastructure.yml: a port is identified by its MAC and hardware facts (slot, port_index, pci_location, vendor, model, speed_gbps, rdma); roles and intents
# refer to a port by its name (the key of the file); os_name_override is the opt-in name the OS configuration gives the adapter. Existing files stay valid.
# Run: Invoke-Pester ./tests/infrastructure/NicModel.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module powershell-yaml
    $script:Lom = Join-Path $repo 'config\variables\examples\scenarios\lom-management-ztp.yml'
    function Get-FindingFor([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Lom -Raw) -Ordered
        & $Change $doc
        $file = Join-Path $TestDrive ("case-{0}.yml" -f [guid]::NewGuid())
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        @(Test-AzlInfrastructure -Path $file)
    }
    function Get-Port($Doc, [int]$Node, [string]$Name) { $Doc.nodes[$Node].network_adapters | Where-Object { $_.name -eq $Name } | Select-Object -First 1 }
    function Get-Error($Finding) { @($Finding | Where-Object Severity -eq 'error') }
}

Describe 'The base example is clean and keeps working with only name and mac_address' {
    It 'has no errors' { Get-Error (Get-FindingFor { param($d) }) | Should -BeNullOrEmpty }
}

Describe 'Hardware facts of a port' {
    It 'accepts port_index, pci_location, vendor, slot, model, speed_gbps and rdma together' {
        $f = Get-FindingFor { param($d)
            $p = Get-Port $d 0 'Embedded NIC 1'
            $p.port_index = 1; $p.vendor = 'Any Vendor'; $p.pci_location = [ordered]@{ bus = 59; device = 0; function = 1 }; $p.rdma = 'none'
        }
        Get-Error $f | Should -BeNullOrEmpty
    }
    It 'rejects a port_index of 0 and an unknown key inside pci_location' {
        $f = Get-FindingFor { param($d) $p = Get-Port $d 0 'Embedded NIC 1'; $p.port_index = 0; $p.pci_location = [ordered]@{ bus = 1; device = 0; function = 0; domain = 2 } }
        $paths = @($f | Where-Object { $_.Id -eq 'SCHEMA' } | ForEach-Object { $_.Path })
        $paths | Should -Contain 'nodes[0].network_adapters[0].port_index'
        $paths | Should -Contain 'nodes[0].network_adapters[0].pci_location.domain'
    }
    It 'rejects a PCI function above 7' {
        $f = Get-FindingFor { param($d) (Get-Port $d 0 'Embedded NIC 1').pci_location = [ordered]@{ bus = 1; device = 0; function = 8 } }
        ($f | Where-Object { $_.Id -eq 'SCHEMA' } | ForEach-Object { $_.Path }) -join ' ' | Should -Match 'function'
    }
    It 'needs the MAC of every port: it is the identity' {
        $f = Get-FindingFor { param($d) (Get-Port $d 0 'Embedded NIC 2').Remove('mac_address') }
        $f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'nodes[0].network_adapters[1]' -and $_.Message -match 'mac_address' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses one MAC on two ports, whatever the notation' {
        $f = Get-FindingFor { param($d) $a = Get-Port $d 0 'Embedded NIC 1'; (Get-Port $d 0 'Embedded NIC 2').mac_address = (($a.mac_address -replace ':', '-').ToLowerInvariant()) }
        $f | Where-Object { $_.Id -eq 'AZL-019' -and $_.Severity -eq 'error' -and $_.Message -match 'Each MAC names one port' } | Should -Not -BeNullOrEmpty
    }
}

Describe 'os_name_override (opt-in)' {
    It 'is optional: the example without it has no finding about names' {
        @(Get-FindingFor { param($d) } | Where-Object { $_.Message -match 'os_name_override' }) | Should -BeNullOrEmpty
    }
    It 'is accepted when it is the same on every node' {
        $f = Get-FindingFor { param($d) foreach ($n in 0, 1) { (Get-Port $d $n 'Embedded NIC 1').os_name_override = 'Mgmt1'; (Get-Port $d $n 'Embedded NIC 2').os_name_override = 'Mgmt 2' } }
        Get-Error $f | Should -BeNullOrEmpty
    }
    It 'is an error when two nodes give the same port different names (Network ATC needs one name)' {
        $f = Get-FindingFor { param($d) (Get-Port $d 0 'Embedded NIC 1').os_name_override = 'Mgmt1'; (Get-Port $d 1 'Embedded NIC 1').os_name_override = 'Mgmt9' }
        $f | Where-Object { $_.Id -eq 'AZL-021' -and $_.Severity -eq 'error' -and $_.Message -match 'different on different nodes' -and $_.Message -match 'Mgmt1, Mgmt9' } | Should -Not -BeNullOrEmpty
    }
    It 'is an error when only some nodes set it' {
        $f = Get-FindingFor { param($d) (Get-Port $d 0 'Embedded NIC 1').os_name_override = 'Mgmt1' }
        $f | Where-Object { $_.Id -eq 'AZL-021' -and $_.Severity -eq 'error' -and $_.Message -match 'set on 1 of 2 nodes' } | Should -Not -BeNullOrEmpty
    }
    It 'is an error when two ports of one node ask for one name' {
        $f = Get-FindingFor { param($d) foreach ($n in 0, 1) { (Get-Port $d $n 'Embedded NIC 1').os_name_override = 'Same'; (Get-Port $d $n 'Embedded NIC 2').os_name_override = 'SAME' } }
        $f | Where-Object { $_.Id -eq 'AZL-019' -and $_.Severity -eq 'error' -and $_.Message -match 'An adapter name is unique on a machine' } | Should -Not -BeNullOrEmpty
    }
    It 'refuses a name Windows would not take: <_>' -ForEach @('a/b', 'bad:name', ' lead', 'trail ', 'x*y', '-hyphen') {
        $name = $_
        $f = Get-FindingFor { param($d) foreach ($n in 0, 1) { (Get-Port $d $n 'Embedded NIC 1').os_name_override = $name } }
        Get-Error $f | Should -Not -BeNullOrEmpty
    }
}

Describe 'Intents and storage networks refer to the key of the port, never to an OS name' {
    It 'an intent that names a port the node does not list is an error, whatever its spelling' {
        $f = Get-FindingFor { param($d) $d.networking.intents[0].adapters = @('Embedded NIC 1', 'Ethernet 7') }
        $f | Where-Object { $_.Id -eq 'AZL-021' -and $_.Severity -eq 'error' -and $_.Message -match "uses adapter 'Ethernet 7'" } | Should -Not -BeNullOrEmpty
    }
}
