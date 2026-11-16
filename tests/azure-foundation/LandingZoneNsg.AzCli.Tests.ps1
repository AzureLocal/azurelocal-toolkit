#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 06: New-LandingZoneNsg.azcli.ps1 creates the network security groups of
# landing_zone.network_security_groups with their rules, with az commands. "az" is mocked: no Azure, no tenant and no sign-in is used. Ids are generated per
# run; the address ranges use the documentation ranges (RFC 5737).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/LandingZoneNsg.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-06-network-security-groups', 'azurecli', 'New-LandingZoneNsg.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlNsgSub = [guid]::NewGuid().ToString()

    function New-Rule([hashtable]$Override = @{}) {
        Set-AzOverride ([ordered]@{ name = 'allow-rdp-from-hub'; priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; source_address_prefixes = @('192.0.2.0/24'); destination_port_ranges = @('3389') }) $Override
    }
    function New-InfraFile {
        param([object[]]$Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule), (New-Rule @{ name = 'deny-all-in'; priority = 4000; access = 'Deny'; protocol = '*'; source_address_prefixes = $null; destination_port_ranges = @('*'); description = 'Deny the rest' })) }),
            [object[]]$Networks = @([ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; location = 'westeurope'; address_space = @('198.51.100.0/24')
                    subnets = @([ordered]@{ name = 'snet-mgmt'; prefix = '198.51.100.0/25'; network_security_group = 'nsg-iic-mgmt-01' }, [ordered]@{ name = 'snet-other'; prefix = '198.51.100.128/25'; network_security_group = 'nsg-made-elsewhere' }) }),
            [hashtable]$Azure = @{}, [object]$Tags = $null, [switch]$NoGroups, [object]$Tenant = $global:AzlFakeTenant)
        $az = [ordered]@{ location = 'eastus' }
        if ($null -ne $Tenant) { $az.tenant_id = $Tenant }
        $null = Set-AzOverride $az $Azure
        $lz = [ordered]@{
            subscriptions = @([ordered]@{ name = 'sub-iic-connectivity'; id = $global:AzlNsgSub; role = 'connectivity' })
            networks      = @($Networks)
        }
        if (-not $NoGroups) { $lz.network_security_groups = @($Groups) }
        $doc = [ordered]@{ azure = $az; landing_zone = $lz }
        if ($Tags) { $doc.tags = $Tags }
        Save-AzInfraFile $doc
    }
    # A group as az returns it, with the rules it already has.
    function New-FakeNsg([object[]]$Rules = @()) { [ordered]@{ name = 'nsg-iic-mgmt-01'; securityRules = @($Rules) } }
    function New-FakeRule([string]$Name, [int]$Priority = 100, [string]$Direction = 'Inbound', [string]$Access = 'Allow', [string]$Protocol = 'Tcp') {
        [ordered]@{ name = $Name; priority = $Priority; direction = $Direction; access = $Access; protocol = $Protocol }
    }
}

Describe 'New-LandingZoneNsg.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlNsgSub, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
    }

    Context 'creating the groups (happy path)' {
        It 'creates the group in the subscription, group and region of the network that uses it, then each rule with the values of the file' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -EQ 'Created').Count | Should -Be 1
            Get-AzCall "network nsg create --name nsg-iic-mgmt-01 --resource-group rg-iic-conn-01 --location westeurope --subscription $($global:AzlNsgSub)" | Should -HaveCount 1
            Get-AzCall "network nsg rule create --nsg-name nsg-iic-mgmt-01 --resource-group rg-iic-conn-01 --subscription $($global:AzlNsgSub) --name allow-rdp-from-hub --priority 100 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes 192.0.2.0/24 --source-port-ranges * --destination-address-prefixes * --destination-port-ranges 3389" | Should -HaveCount 1
            Get-AzCall "network nsg rule create --nsg-name nsg-iic-mgmt-01 *--name deny-all-in --priority 4000 --direction Inbound --access Deny --protocol * --source-address-prefixes * --source-port-ranges * --destination-address-prefixes * --destination-port-ranges * --description Deny the rest" | Should -HaveCount 1
        }

        It 'puts the file-level tags on the group' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Tags ([ordered]@{ environment = 'lab' }))
            Get-AzCall 'network nsg create*--tags environment=lab' | Should -HaveCount 1
        }

        It 'creates a group in each network that uses it, once per subscription and resource group' {
            $net2 = [ordered]@{ name = 'vnet-iic-spoke-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-spoke-01'; location = 'northeurope'; address_space = @('203.0.113.0/24'); subnets = @([ordered]@{ name = 'snet-a'; prefix = '203.0.113.0/25'; network_security_group = 'nsg-iic-mgmt-01' }) }
            $net1 = [ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; location = 'westeurope'; address_space = @('198.51.100.0/24'); subnets = @([ordered]@{ name = 'snet-mgmt'; prefix = '198.51.100.0/25'; network_security_group = 'nsg-iic-mgmt-01' }, [ordered]@{ name = 'snet-b'; prefix = '198.51.100.128/25'; network_security_group = 'nsg-iic-mgmt-01' }) }
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Networks @($net1, $net2))
            Get-AzCall 'network nsg create*' | Should -HaveCount 2
            Get-AzCall 'network nsg create --name nsg-iic-mgmt-01 --resource-group rg-iic-spoke-01 --location northeurope*' | Should -HaveCount 1
        }

        It 'uses azure.location when the network has none, and takes * as the default protocol and address' {
            $net = [ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; address_space = @('198.51.100.0/24'); subnets = @([ordered]@{ name = 'snet-mgmt'; prefix = '198.51.100.0/25'; network_security_group = 'nsg-iic-mgmt-01' }) }
            $grp = [ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @([ordered]@{ name = 'any-in'; priority = 200; direction = 'inbound'; access = 'allow'; destination_port_ranges = @('443', '8000-8100') }) }
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Networks @($net) -Groups @($grp))
            Get-AzCall 'network nsg create*--location eastus*' | Should -HaveCount 1
            Get-AzCall 'network nsg rule create*--name any-in --priority 200 --direction Inbound --access Allow --protocol * --source-address-prefixes * --source-port-ranges * --destination-address-prefixes * --destination-port-ranges 443 8000-8100' | Should -HaveCount 1
        }

        It 'never changes the subscription of the az session' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall 'account set*' | Should -BeNullOrEmpty
        }
    }

    Context 'the group already exists (idempotent, additive)' {
        It 'creates and changes nothing when every rule is there' {
            Add-AzRoute 'network nsg show*' (New-FakeNsg @((New-FakeRule 'allow-rdp-from-hub'), (New-FakeRule 'deny-all-in' 4000 'Inbound' 'Deny' '*')))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -EQ 'AlreadyExists').Count | Should -Be 1
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'adds the rule that is missing, by name, and nothing else' {
            Add-AzRoute 'network nsg show*' (New-FakeNsg @(, (New-FakeRule 'allow-rdp-from-hub')))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            @($r.Rows | Where-Object Action -EQ 'RulesAdded').Count | Should -Be 1
            Get-AzCall 'network nsg create*' | Should -BeNullOrEmpty
            Get-AzCall 'network nsg rule create*' | Should -HaveCount 1
            Get-AzCall 'network nsg rule create*--name deny-all-in*' | Should -HaveCount 1
        }

        It 'reports a rule that differs and does not change it' {
            Add-AzRoute 'network nsg show*' (New-FakeNsg @((New-FakeRule 'allow-rdp-from-hub' 150 'Inbound' 'Allow' 'Udp'), (New-FakeRule 'deny-all-in' 4000 'Inbound' 'Deny' '*')))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $detail = @($r.Rows | Where-Object Action -EQ 'AlreadyExists')[0].Detail
            $detail | Should -Match 'Priority is 150, the file says 100'
            $detail | Should -Match 'Protocol is Udp, the file says Tcp'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'never removes a rule or a group' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match "'delete'|'update'|'remove'"
        }
    }

    Context 'groups that no subnet names' {
        It 'reports a group no subnet uses as NotUsed and does not create it' {
            $groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @(, (New-Rule)) }, [ordered]@{ name = 'nsg-iic-unused-01'; rules = @(, (New-Rule)) })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Groups $groups)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -EQ 'NotUsed').NetworkSecurityGroup | Should -Be 'nsg-iic-unused-01'
            Get-AzCall 'network nsg create --name nsg-iic-unused-01*' | Should -BeNullOrEmpty
        }

        It 'does nothing and exits 0 when the file lists no group' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoGroups)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf' {
        It 'plans the group and its rules and writes nothing to Azure' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 1
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would be created'
        }

        It 'plans the missing rules of an existing group and writes nothing' {
            Add-AzRoute 'network nsg show*' (New-FakeNsg @(, (New-FakeRule 'allow-rdp-from-hub')))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            @($r.Rows | Where-Object Action -EQ 'WouldAddRules').Count | Should -Be 1
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'nsg.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'refuses a missing tenant' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Tenant $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a group with no name'; Group = @{ name = 'bad name!' }; Rule = @{}; Match = 'not a valid network security group name' }
            @{ Case = 'a rule with a bad name'; Group = @{}; Rule = @{ name = 'bad name!' }; Match = 'not a valid rule name' }
            @{ Case = 'a priority below 100'; Group = @{}; Rule = @{ priority = 99 }; Match = 'priority must be a whole number from 100 to 4096' }
            @{ Case = 'a priority above 4096'; Group = @{}; Rule = @{ priority = 4097 }; Match = 'priority must be a whole number from 100 to 4096' }
            @{ Case = 'a direction that is neither Inbound nor Outbound'; Group = @{}; Rule = @{ direction = 'Sideways' }; Match = 'must be Inbound or Outbound' }
            @{ Case = 'an access that is neither Allow nor Deny'; Group = @{}; Rule = @{ access = 'Maybe' }; Match = 'must be Allow or Deny' }
            @{ Case = 'a protocol Azure does not know'; Group = @{}; Rule = @{ protocol = 'gre' }; Match = 'is not one of' }
            @{ Case = 'no destination ports'; Group = @{}; Rule = @{ destination_port_ranges = $null }; Match = 'destination_port_ranges is missing' }
            @{ Case = 'a port above 65535'; Group = @{}; Rule = @{ destination_port_ranges = @('70000') }; Match = 'a port is 0 to 65535' }
            @{ Case = 'a source that is neither an address nor a service tag'; Group = @{}; Rule = @{ source_address_prefixes = @('not an address') }; Match = 'not \*, an IPv4 address' }
            @{ Case = 'a service tag mixed with addresses'; Group = @{}; Rule = @{ source_address_prefixes = @('VirtualNetwork', '192.0.2.0/24') }; Match = 'mixes a service tag' }
            @{ Case = '* mixed with an address'; Group = @{}; Rule = @{ source_address_prefixes = @('*', '192.0.2.0/24') }; Match = 'mixes \* with other values' }
            @{ Case = 'a description over 140 characters'; Group = @{}; Rule = @{ description = ('x' * 141) }; Match = 'longer than 140' }
        ) {
            $rule = New-Rule $Rule
            $group = Set-AzOverride ([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @($rule) }) $Group
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Groups @($group))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses two rules with the same priority and direction, and the same rule name twice' {
            $same = [ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule), (New-Rule @{ name = 'another' })) }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Groups @($same))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'used twice'
            $twice = [ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule), (New-Rule @{ priority = 200 })) }
            (Invoke-AzCliScript $script:Script (New-InfraFile -Groups @($twice))).Text | Should -Match 'listed twice'
        }

        It 'refuses the same group twice' {
            $g = [ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @(, (New-Rule)) }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Groups @($g, $g))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'listed twice'
        }

        It 'refuses a network whose subscription has no id in the file' {
            $net = [ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-unknown'; resource_group = 'rg-iic-conn-01'; address_space = @('198.51.100.0/24'); subnets = @([ordered]@{ name = 'snet-mgmt'; prefix = '198.51.100.0/25'; network_security_group = 'nsg-iic-mgmt-01' }) }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Networks @($net))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no usable id'
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-AzCliScript $script:Script (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when az is not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Azure CLI \(az\) was not found'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'stops when nobody is signed in' {
            Add-AzRoute 'account show*' 'ERROR: Please run ''az login'' to setup account.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the sign-in is to another tenant' {
            Add-AzRoute 'account show*' ([guid]::NewGuid().ToString())
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports a group that cannot be created and exits 1' {
            Add-AzRoute 'network nsg create*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed')[0].Detail | Should -Match 'AuthorizationFailed'
            Get-AzCall 'network nsg rule create*' | Should -BeNullOrEmpty
        }

        It 'stops at the rule that fails, reports it and exits 1' {
            Add-AzRoute 'network nsg rule create*--name deny-all-in*' 'ERROR: (SecurityRuleParameterContainsConflictingValues) Conflicting values.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed')[0].Detail | Should -Match 'Conflicting'
        }

        It 'does not hide a read error that is not a not-found' {
            Add-AzRoute 'network nsg show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Get-AzWriteCall | Should -BeNullOrEmpty
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader and holds no GUID' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter registered' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($p in 'InfrastructureFile', 'LogPath') {
                ($registry -match ('New_LandingZoneNsg_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
