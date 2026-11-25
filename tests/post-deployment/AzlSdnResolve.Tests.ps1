#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# scripts/common/sdn/AzlSdn.psm1: the two rules that take a value from a variable the file already has.
#   Resolve-AzlSdnPrefix         sdn.prefix, or derived from cluster.name when it is not set.
#   Resolve-AzlNsgAddressPrefix  a network security group rule address: a literal as written, a reference as the subnet of the file.
# Pure functions: no machine, no Azure. Example values only (improbability.cloud, RFC 5737 addresses).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/AzlSdnResolve.Tests.ps1
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'sdn', 'AzlSdn.psm1')) -Force
    function New-Doc {
        [ordered]@{
            cluster    = [ordered]@{ name = 'iic-azl-c01' }
            sdn        = [ordered]@{ enabled = $true }
            networking = [ordered]@{
                management      = [ordered]@{ subnet = '192.0.2.0/24' }
                vlans           = @(
                    [ordered]@{ name = 'management'; id = 711; subnet = '192.0.2.0/24'; purpose = 'management' }
                    [ordered]@{ name = 'storage-1'; id = 712; subnet = '198.51.100.0/25'; purpose = 'storage' }
                    [ordered]@{ name = 'storage-2'; id = 713; subnet = '198.51.100.128/25'; purpose = 'Storage' }
                    [ordered]@{ name = 'workloads'; id = 714; subnet = '203.0.113.0/24'; purpose = 'compute' }
                    [ordered]@{ name = 'no-subnet'; id = 715; purpose = 'oob' }
                )
                logical_networks = @([ordered]@{ name = 'lnet-apps'; address_prefix = '203.0.113.128/25' }, [ordered]@{ name = 'lnet-dynamic' })
            }
        }
    }
}

Describe 'Resolve-AzlSdnPrefix' {
    It 'uses sdn.prefix as written and says so' {
        $doc = New-Doc; $doc.sdn.prefix = 'Own-01'
        $r = Resolve-AzlSdnPrefix -Infrastructure $doc
        $r.Prefix | Should -Be 'Own-01'
        $r.Derived | Should -BeFalse
        $r.Label | Should -Be 'prefix (sdn.prefix)'
        $r.Problem | Should -Be ''
    }

    It 'derives the prefix from cluster.name when sdn.prefix is not set: lower case, letters and digits only, eight characters' {
        $r = Resolve-AzlSdnPrefix -Infrastructure (New-Doc)
        $r.Prefix | Should -Be 'iicazlc0'
        $r.Source | Should -Be 'cluster.name'
        $r.Derived | Should -BeTrue
        $r.Truncated | Should -BeTrue
        $r.Label | Should -Be 'prefix (derived from cluster.name)'
    }

    It 'does not call a short name truncated' -ForEach @(
        @{ Name = 'IIC-01'; Want = 'iic01' }, @{ Name = 'a1'; Want = 'a1' }, @{ Name = 'Ab-Cd-Ef-Gh'; Want = 'abcdefgh' }
    ) {
        $doc = New-Doc; $doc.cluster.name = $Name
        $r = Resolve-AzlSdnPrefix -Infrastructure $doc
        $r.Prefix | Should -Be $Want
        $r.Truncated | Should -Be ($Want.Length -lt (($Name.ToLowerInvariant() -replace '[^a-z0-9]', '').Length))
    }

    It 'uses sdn.prefix before cluster.name, and does not read cluster.name then' {
        $doc = New-Doc; $doc.sdn.prefix = 'iic01'; $doc.cluster.name = '!!!'
        (Resolve-AzlSdnPrefix -Infrastructure $doc).Prefix | Should -Be 'iic01'
    }

    It 'reports a problem and no prefix when it cannot be derived: <Why>' -ForEach @(
        @{ Why = 'no cluster.name'; Name = $null; Match = 'cluster.name is missing' }
        @{ Why = 'a name with no letter or digit'; Name = '---'; Match = 'holds no letter or digit' }
    ) {
        $doc = New-Doc
        if ($null -eq $Name) { $doc.Remove('cluster') } else { $doc.cluster.name = $Name }
        $r = Resolve-AzlSdnPrefix -Infrastructure $doc
        $r.Prefix | Should -Be ''
        $r.Problem | Should -Match $Match
    }

    It 'applies the rules of Microsoft Learn to sdn.prefix: <Prefix>' -ForEach @(
        @{ Prefix = 'ninechars'; Ok = $false }, @{ Prefix = 'ab--cd'; Ok = $false }, @{ Prefix = 'abc-'; Ok = $false }, @{ Prefix = '-abc'; Ok = $false }
        @{ Prefix = 'ab_cd'; Ok = $false }, @{ Prefix = 'a'; Ok = $true }, @{ Prefix = 'ab-cd'; Ok = $true }, @{ Prefix = 'ABcd1234'; Ok = $true }
    ) {
        $doc = New-Doc; $doc.sdn.prefix = $Prefix
        $r = Resolve-AzlSdnPrefix -Infrastructure $doc
        if ($Ok) { $r.Problem | Should -Be '' } else { $r.Problem | Should -Match 'not usable'; $r.Prefix | Should -Be '' }
    }
}

Describe 'Resolve-AzlNsgAddressPrefix' {
    It 'keeps literal values as written' {
        $r = Resolve-AzlNsgAddressPrefix -Infrastructure (New-Doc) -Value @('*', '192.0.2.0/24', '198.51.100.7')
        $r.Problem | Should -Be ''
        @($r.Addresses) | Should -Be @('*', '192.0.2.0/24', '198.51.100.7')
        @($r.Notes).Count | Should -Be 0
    }

    It 'resolves management to networking.management.subnet and names the variable' {
        $r = Resolve-AzlNsgAddressPrefix -Infrastructure (New-Doc) -Value @('management')
        @($r.Addresses) | Should -Be @('192.0.2.0/24')
        $r.Notes[0] | Should -Match 'networking\.management\.subnet'
        $r.Notes[0] | Should -Match '192\.0\.2\.0/24'
    }

    It 'resolves a purpose to every VLAN with that purpose and a subnet, whatever the case' {
        $r = Resolve-AzlNsgAddressPrefix -Infrastructure (New-Doc) -Value @('storage')
        @($r.Addresses) | Should -Be @('198.51.100.0/25', '198.51.100.128/25')
        $r.Notes[0] | Should -Match 'networking\.vlans\[\] with purpose storage: storage-1, storage-2'
        @((Resolve-AzlNsgAddressPrefix -Infrastructure (New-Doc) -Value @('Compute')).Addresses) | Should -Be @('203.0.113.0/24')
    }

    It 'resolves vlan:<name> and logical-network:<name> by name, without regard to case' {
        $r = Resolve-AzlNsgAddressPrefix -Infrastructure (New-Doc) -Value @('vlan:Workloads', 'logical-network:LNET-APPS')
        @($r.Addresses) | Should -Be @('203.0.113.0/24', '203.0.113.128/25')
        $r.Notes[0] | Should -Match 'networking\.vlans\[\]\.subnet'
        $r.Notes[1] | Should -Match 'networking\.logical_networks\[\]\.address_prefix'
    }

    It 'mixes references and literals and drops duplicates' {
        $r = Resolve-AzlNsgAddressPrefix -Infrastructure (New-Doc) -Value @('management', '192.0.2.0/24', 'vlan:management')
        @($r.Addresses) | Should -Be @('192.0.2.0/24')
    }

    It 'gives a problem, never a guess, when the file cannot answer: <Why>' -ForEach @(
        @{ Why = 'a purpose no VLAN has'; Value = 'automation'; Match = 'networking\.vlans\[\] with purpose automation' }
        @{ Why = 'a VLAN with that purpose but no subnet'; Value = 'oob'; Match = 'purpose oob' }
        @{ Why = 'a VLAN that is not there'; Value = 'vlan:nothing'; Match = "names 'nothing'" }
        @{ Why = 'a logical network without an address_prefix'; Value = 'logical-network:lnet-dynamic'; Match = 'has no address_prefix' }
        @{ Why = 'a word that is not a reference'; Value = 'Internet'; Match = 'is not usable' }
        @{ Why = 'an address that is not one'; Value = '192.0.2.300'; Match = 'is not usable' }
    ) {
        $r = Resolve-AzlNsgAddressPrefix -Infrastructure (New-Doc) -Value @($Value)
        $r.Problem | Should -Match $Match
        @($r.Addresses).Count | Should -Be 0
    }

    It 'refuses a name that two entries share (compared without regard to case) and a reference with no name' {
        $doc = New-Doc
        $doc.networking.vlans += [ordered]@{ name = 'WORKLOADS'; id = 720; subnet = '203.0.113.0/25'; purpose = 'compute' }
        (Resolve-AzlNsgAddressPrefix -Infrastructure $doc -Value @('vlan:workloads')).Problem | Should -Match 'is ambiguous: networking\.vlans\[\] has 2 entries'
        (Resolve-AzlNsgAddressPrefix -Infrastructure (New-Doc) -Value @('vlan:')).Problem | Should -Match 'names no entry'
        (Resolve-AzlNsgAddressPrefix -Infrastructure (New-Doc) -Value @('logical-network:  ')).Problem | Should -Match 'names no entry'
    }

    It 'does not take a VLAN whose subnet is blank for a purpose' {
        $doc = New-Doc
        $doc.networking.vlans = @([ordered]@{ name = 'x'; id = 730; subnet = '  '; purpose = 'automation' })
        (Resolve-AzlNsgAddressPrefix -Infrastructure $doc -Value @('automation')).Problem | Should -Match 'the file has none'
    }
    It 'gives a problem for management when the file has no management subnet' {
        $doc = New-Doc; $doc.networking.management.Remove('subnet')
        (Resolve-AzlNsgAddressPrefix -Infrastructure $doc -Value @('management')).Problem | Should -Match 'networking\.management\.subnet, which the file does not set'
    }

    It 'accepts the references the registry pattern accepts, and only those' {
        $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw | ConvertFrom-Json -Depth 100
        $rule = $registry.properties.networking.properties.network_security_groups.items.properties.rules.items.properties
        foreach ($key in 'source_address_prefixes', 'destination_address_prefixes') {
            $pattern = $rule.$key.items.pattern
            foreach ($good in '*', '192.0.2.0/24', '198.51.100.7', 'management', 'oob', 'automation', 'compute', 'storage', 'vlan:storage-1', 'logical-network:lnet-apps') {
                $good -match $pattern | Should -BeTrue -Because "$good must pass $key"
            }
            foreach ($bad in 'Internet', 'vlan:', 'vlan:a b', 'networks', '192.0.2.300') { $bad -match $pattern | Should -BeFalse -Because "$bad must fail $key" }
        }
    }
}
