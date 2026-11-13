#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 06: New-LandingZoneNsg.ps1 creates the network security groups of
# landing_zone.network_security_groups in the resource group and region of the networks whose subnets name them. Every Az cmdlet is mocked: no Azure,
# no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/LandingZoneNsg.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeDiscovery {
    # The -ForEach tables below are built while Pester finds the tests, before BeforeAll runs.
    function New-Rule([hashtable]$Override = @{}) {
        $r = [ordered]@{ name = 'allow-rdp-from-hub'; priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; source_address_prefixes = @('192.0.2.0/24'); destination_port_ranges = @('3389') }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $r.Remove($k) } else { $r[$k] = $Override[$k] } }
        $r
    }
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-06-network-security-groups', 'powershell', 'New-LandingZoneNsg.ps1')
    Import-Module powershell-yaml

    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzNetworkSecurityGroup { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzNetworkSecurityRuleConfig {
        [CmdletBinding()] param([string]$Name, [string]$Description, [string]$Access, [string]$Protocol, [string]$Direction, [int]$Priority, [string[]]$SourceAddressPrefix, [string[]]$SourcePortRange, [string[]]$DestinationAddressPrefix, [string[]]$DestinationPortRange)
    }
    function Add-AzNetworkSecurityRuleConfig {
        [CmdletBinding()] param([object]$NetworkSecurityGroup, [string]$Name, [string]$Description, [string]$Access, [string]$Protocol, [string]$Direction, [int]$Priority, [string[]]$SourceAddressPrefix, [string[]]$SourcePortRange, [string[]]$DestinationAddressPrefix, [string[]]$DestinationPortRange)
    }
    function New-AzNetworkSecurityGroup { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [object[]]$SecurityRules, [hashtable]$Tag, [switch]$Force) }
    function Set-AzNetworkSecurityGroup { [CmdletBinding()] param([object]$NetworkSecurityGroup) }

    $global:AzlNsgTenant = [guid]::NewGuid().ToString()
    $global:AzlNsgSub = [guid]::NewGuid().ToString()
    $global:AzlNsgHome = [guid]::NewGuid().ToString()

    function New-Rule([hashtable]$Override = @{}) {
        $r = [ordered]@{ name = 'allow-rdp-from-hub'; priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; source_address_prefixes = @('192.0.2.0/24'); destination_port_ranges = @('3389') }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $r.Remove($k) } else { $r[$k] = $Override[$k] } }
        $r
    }
    function New-InfraFile {
        param([object[]]$Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule), (New-Rule @{ name = 'deny-all-in'; priority = 4000; access = 'Deny'; protocol = '*'; source_address_prefixes = $null; destination_port_ranges = @('*') })) }),
            [object[]]$Networks = @([ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; location = 'westeurope'; address_space = @('10.20.0.0/22')
                    subnets = @([ordered]@{ name = 'snet-mgmt'; prefix = '10.20.1.0/24'; network_security_group = 'nsg-iic-mgmt-01' }, [ordered]@{ name = 'snet-other'; prefix = '10.20.2.0/24'; network_security_group = 'nsg-made-elsewhere' }) }),
            [hashtable]$Azure = @{}, [object]$Tags = $null, [switch]$NoGroups)
        $az = [ordered]@{ tenant_id = $global:AzlNsgTenant; location = 'eastus' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $lz = [ordered]@{
            subscriptions = @([ordered]@{ name = 'sub-iic-connectivity'; id = $global:AzlNsgSub; role = 'connectivity' })
            networks      = @($Networks)
        }
        if (-not $NoGroups) { $lz.network_security_groups = @($Groups) }
        $doc = [ordered]@{ azure = $az; landing_zone = $lz }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Nsg([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['NetworkSecurityGroup'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'New-LandingZoneNsg.ps1' {
    AfterAll { Remove-Variable -Name AzlNsgTenant, AzlNsgSub, AzlNsgHome -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlNsgTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlNsgHome } } }
        Mock Set-AzContext { }
        Mock Get-AzNetworkSecurityGroup { throw "The Resource 'Microsoft.Network/networkSecurityGroups/$Name' was not found (404 NotFound)." }
        Mock New-AzNetworkSecurityRuleConfig { [pscustomobject]@{ Name = $Name; Priority = $Priority } }
        Mock Add-AzNetworkSecurityRuleConfig { $NetworkSecurityGroup }
        Mock New-AzNetworkSecurityGroup { [pscustomobject]@{ Name = $Name } }
        Mock Set-AzNetworkSecurityGroup { $NetworkSecurityGroup }
    }

    Context 'creating a group' {
        It 'creates the group in the subscription, resource group and region of the network whose subnet names it, with its rules' {
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            $r.Rows[0].RulesAdded | Should -Be 2
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlNsgSub }
            Should -Invoke New-AzNetworkSecurityRuleConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'allow-rdp-from-hub' -and $Priority -eq 100 -and $Direction -eq 'Inbound' -and $Access -eq 'Allow' -and $Protocol -eq 'Tcp' -and $SourceAddressPrefix -contains '192.0.2.0/24' -and $SourcePortRange -contains '*' -and $DestinationAddressPrefix -contains '*' -and $DestinationPortRange -contains '3389' }
            Should -Invoke New-AzNetworkSecurityRuleConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'deny-all-in' -and $Access -eq 'Deny' -and $Protocol -eq '*' -and $SourceAddressPrefix -contains '*' -and $DestinationPortRange -contains '*' }
            Should -Invoke New-AzNetworkSecurityGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'nsg-iic-mgmt-01' -and $ResourceGroupName -eq 'rg-iic-conn-01' -and $Location -eq 'westeurope' -and @($SecurityRules).Count -eq 2 }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlNsgHome }
        }

        It 'falls back to azure.location, puts the file-level tags on the group and passes the description of a rule' {
            $network = [ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; address_space = @('10.20.0.0/22'); subnets = @([ordered]@{ name = 'snet-mgmt'; prefix = '10.20.1.0/24'; network_security_group = 'nsg-iic-mgmt-01' }) }
            $group = [ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ description = 'Allow RDP from the hub' })) }
            $null = Invoke-Nsg (New-InfraFile -Groups @($group) -Networks @($network) -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzNetworkSecurityGroup -Times 1 -Exactly -ParameterFilter { $Location -eq 'eastus' -and $Tag['environment'] -eq 'lab' }
            Should -Invoke New-AzNetworkSecurityRuleConfig -Times 1 -Exactly -ParameterFilter { $Description -eq 'Allow RDP from the hub' }
        }

        It 'creates a group that has no rules' {
            $r = Invoke-Nsg (New-InfraFile -Groups @([ordered]@{ name = 'nsg-iic-mgmt-01' }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke New-AzNetworkSecurityGroup -Times 1 -Exactly
            Should -Invoke New-AzNetworkSecurityRuleConfig -Times 0 -Exactly
        }

        It 'creates the group once in each resource group of two networks that name it, and not for a name the file does not list' {
            $a = [ordered]@{ name = 'vnet-a'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-a'; location = 'westeurope'; address_space = @('10.20.0.0/22'); subnets = @([ordered]@{ name = 's1'; prefix = '10.20.1.0/24'; network_security_group = 'nsg-iic-mgmt-01' }, [ordered]@{ name = 's2'; prefix = '10.20.2.0/24'; network_security_group = 'nsg-iic-mgmt-01' }) }
            $b = [ordered]@{ name = 'vnet-b'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-b'; location = 'northeurope'; address_space = @('10.30.0.0/22'); subnets = @([ordered]@{ name = 's1'; prefix = '10.30.1.0/24'; network_security_group = 'nsg-iic-mgmt-01' }) }
            $r = Invoke-Nsg (New-InfraFile -Networks @($a, $b))
            @($r.Rows | Where-Object Action -EQ 'Created').Count | Should -Be 2
            Should -Invoke New-AzNetworkSecurityGroup -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-a' -and $Location -eq 'westeurope' }
            Should -Invoke New-AzNetworkSecurityGroup -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-b' -and $Location -eq 'northeurope' }
            Should -Invoke New-AzNetworkSecurityGroup -Times 0 -Exactly -ParameterFilter { $Name -eq 'nsg-made-elsewhere' }
        }

        It 'reports a group that no subnet names as NotUsed and creates nothing for it' {
            $r = Invoke-Nsg (New-InfraFile -Groups @([ordered]@{ name = 'nsg-iic-unused-01' }))
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'NotUsed'
            Should -Invoke New-AzNetworkSecurityGroup -Times 0 -Exactly
            Should -Invoke Get-AzContext -Times 1 -Exactly
        }

        It 'never removes a group or a rule and never attaches a group to a subnet' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-Az|Set-AzVirtualNetwork|Update-Az'
        }
    }

    Context 'the group exists already (idempotent and additive)' {
        It 'adds only the rules that are missing and leaves the others alone' {
            Mock Get-AzNetworkSecurityGroup { [pscustomobject]@{ Name = $Name; SecurityRules = @([pscustomobject]@{ Name = 'allow-rdp-from-hub'; Priority = 100; Direction = 'Inbound'; Access = 'Allow'; Protocol = 'Tcp' }) } }
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'RulesAdded'
            $r.Rows[0].RulesAdded | Should -Be 1
            Should -Invoke Add-AzNetworkSecurityRuleConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'deny-all-in' -and $Priority -eq 4000 }
            Should -Invoke Set-AzNetworkSecurityGroup -Times 1 -Exactly
            Should -Invoke New-AzNetworkSecurityGroup -Times 0 -Exactly
        }

        It 'creates nothing when every rule is there, and reports a rule that differs without changing it' {
            Mock Get-AzNetworkSecurityGroup {
                [pscustomobject]@{ Name = $Name; SecurityRules = @(
                        [pscustomobject]@{ Name = 'allow-rdp-from-hub'; Priority = 200; Direction = 'Inbound'; Access = 'Allow'; Protocol = 'Tcp' }
                        [pscustomobject]@{ Name = 'deny-all-in'; Priority = 4000; Direction = 'Inbound'; Access = 'Deny'; Protocol = '*' }) }
            }
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Detail | Should -Match "allow-rdp-from-hub.*Priority is 200, the file says 100"
            Should -Invoke Set-AzNetworkSecurityGroup -Times 0 -Exactly
            Should -Invoke Add-AzNetworkSecurityRuleConfig -Times 0 -Exactly
            Should -Invoke New-AzNetworkSecurityGroup -Times 0 -Exactly
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans the group and creates nothing' {
            $r = Invoke-Nsg (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzNetworkSecurityGroup -Times 0 -Exactly
            Should -Invoke New-AzNetworkSecurityRuleConfig -Times 0 -Exactly
        }

        It 'plans the missing rules of a group that exists and changes nothing' {
            Mock Get-AzNetworkSecurityGroup { [pscustomobject]@{ Name = $Name; SecurityRules = @() } }
            $r = Invoke-Nsg (New-InfraFile) -DryRun
            $r.Rows[0].Action | Should -Be 'WouldAddRules'
            Should -Invoke Set-AzNetworkSecurityGroup -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the file lists no group' {
            $r = Invoke-Nsg (New-InfraFile -NoGroups)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.tenant_id' {
            (Invoke-Nsg (New-InfraFile -Azure @{ tenant_id = $null })).ExitCode | Should -Be 2
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a group with no name'; Groups = @([ordered]@{ rules = @((New-Rule)) }) }
            @{ Why = 'a group name Azure refuses'; Groups = @([ordered]@{ name = '-bad'; rules = @((New-Rule)) }) }
            @{ Why = 'a group listed twice'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01' }, [ordered]@{ name = 'NSG-IIC-MGMT-01' }) }
            @{ Why = 'a rule with no name'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ name = $null })) }) }
            @{ Why = 'a priority below 100'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ priority = 99 })) }) }
            @{ Why = 'a priority above 4096'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ priority = 4097 })) }) }
            @{ Why = 'a direction that is not Inbound or Outbound'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ direction = 'Sideways' })) }) }
            @{ Why = 'an access that is not Allow or Deny'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ access = 'Maybe' })) }) }
            @{ Why = 'a protocol Azure does not have'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ protocol = 'Gre' })) }) }
            @{ Why = 'two rules with the same priority and direction'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule), (New-Rule @{ name = 'second' })) }) }
            @{ Why = 'no destination ports'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ destination_port_ranges = $null })) }) }
            @{ Why = 'a port above 65535'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ destination_port_ranges = @('70000') })) }) }
            @{ Why = 'a port that is not a number'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ destination_port_ranges = @('https') })) }) }
            @{ Why = 'a service tag mixed with an address'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ source_address_prefixes = @('VirtualNetwork', '192.0.2.0/24') })) }) }
            @{ Why = 'two service tags'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ source_address_prefixes = @('VirtualNetwork', 'Internet') })) }) }
            @{ Why = '* mixed with an address'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ destination_address_prefixes = @('*', '192.0.2.0/24') })) }) }
            @{ Why = 'an address that is not IPv4 or CIDR'; Groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @((New-Rule @{ source_address_prefixes = @('192.0.2.0/33') })) }) }
        ) {
            $r = Invoke-Nsg (New-InfraFile -Groups $Groups)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzNetworkSecurityGroup -Times 0 -Exactly
        }

        It 'accepts one service tag alone, in either direction' {
            $rule = New-Rule @{ source_address_prefixes = @('VirtualNetwork'); destination_address_prefixes = @('Internet'); direction = 'outbound'; access = 'allow' }
            $r = Invoke-Nsg (New-InfraFile -Groups @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @($rule) }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke New-AzNetworkSecurityRuleConfig -Times 1 -Exactly -ParameterFilter { $Direction -eq 'Outbound' -and $Access -eq 'Allow' -and $SourceAddressPrefix -contains 'VirtualNetwork' -and $DestinationAddressPrefix -contains 'Internet' }
        }

        It 'refuses a network whose subscription has no usable id' {
            $network = [ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-unknown'; resource_group = 'rg-iic-conn-01'; address_space = @('10.20.0.0/22'); subnets = @([ordered]@{ name = 'snet-mgmt'; prefix = '10.20.1.0/24'; network_security_group = 'nsg-iic-mgmt-01' }) }
            $r = Invoke-Nsg (New-InfraFile -Networks @($network))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no usable id'
            Should -Invoke New-AzNetworkSecurityGroup -Times 0 -Exactly
        }

        It 'refuses a network with no resource group, or no region anywhere' {
            $network = [ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; address_space = @('10.20.0.0/22'); subnets = @([ordered]@{ name = 'snet-mgmt'; prefix = '10.20.1.0/24'; network_security_group = 'nsg-iic-mgmt-01' }) }
            (Invoke-Nsg (New-InfraFile -Networks @($network))).ExitCode | Should -Be 2
            $network.resource_group = 'rg-iic-conn-01'
            (Invoke-Nsg (New-InfraFile -Networks @($network) -Azure @{ location = $null })).ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Nsg (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzNetworkSecurityGroup -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzNetworkSecurityGroup { throw 'The client does not have authorization to perform action.' }
            (Invoke-Nsg (New-InfraFile)).ExitCode | Should -Be 1
            Should -Invoke New-AzNetworkSecurityGroup -Times 0 -Exactly
        }

        It 'reports a failed creation, puts the subscription back, and exits 1' {
            Mock New-AzNetworkSecurityGroup { throw 'AuthorizationFailed' }
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlNsgHome }
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, never the old layout, and holds no GUID or address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml|logging\.ps1|Lighthouse'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_LandingZoneNsg_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.location', 'tags', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id', 'landing_zone.networks[].name', 'landing_zone.networks[].subscription', 'landing_zone.networks[].resource_group', 'landing_zone.networks[].location', 'landing_zone.networks[].subnets[].name', 'landing_zone.networks[].subnets[].network_security_group', 'landing_zone.network_security_groups[].name', 'landing_zone.network_security_groups[].rules[].name', 'landing_zone.network_security_groups[].rules[].priority', 'landing_zone.network_security_groups[].rules[].direction', 'landing_zone.network_security_groups[].rules[].access', 'landing_zone.network_security_groups[].rules[].protocol', 'landing_zone.network_security_groups[].rules[].source_address_prefixes', 'landing_zone.network_security_groups[].rules[].source_port_ranges', 'landing_zone.network_security_groups[].rules[].destination_address_prefixes', 'landing_zone.network_security_groups[].rules[].destination_port_ranges', 'landing_zone.network_security_groups[].rules[].description' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
