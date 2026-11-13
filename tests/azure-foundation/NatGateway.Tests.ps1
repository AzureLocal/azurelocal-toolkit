#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 07: New-NatGateway.ps1 creates the NAT gateway of
# landing_zone.connectivity.nat_gateway and attaches the listed subnets. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used.
# Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/NatGateway.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-07-nat-gateway', 'powershell', 'New-NatGateway.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzNatGateway { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzNatGateway { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$Sku, [int]$IdleTimeoutInMinutes, [object]$PublicIpAddress, [hashtable]$Tag) }
    function Get-AzPublicIpAddress { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzPublicIpAddress { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$Sku, [string]$AllocationMethod, [hashtable]$Tag) }
    function Get-AzVirtualNetwork { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Set-AzVirtualNetworkSubnetConfig { [CmdletBinding()] param([object]$VirtualNetwork, [string]$Name, [string[]]$AddressPrefix, [object]$NatGateway) }
    function Set-AzVirtualNetwork { [CmdletBinding()] param([object]$VirtualNetwork) }

    $global:AzlNgTenant = [guid]::NewGuid().ToString()
    $global:AzlNgSub = [guid]::NewGuid().ToString()
    $global:AzlNgHome = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([hashtable]$Nat = @{}, [hashtable]$Azure = @{}, [object]$Tags = $null, [switch]$NoNat)
        $az = [ordered]@{ tenant_id = $global:AzlNgTenant; location = 'eastus' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $n = [ordered]@{ name = 'ng-iic-mgmt-01'; network = 'vnet-iic-mgmt-01'; subnets = @('snet-iic-mgmt-01', 'snet-iic-mgmt-02') }
        foreach ($k in $Nat.Keys) { if ($null -eq $Nat[$k]) { $n.Remove($k) } else { $n[$k] = $Nat[$k] } }
        $doc = [ordered]@{
            azure        = $az
            landing_zone = [ordered]@{
                subscriptions = @([ordered]@{ name = 'sub-iic-management'; id = $global:AzlNgSub; role = 'management' })
                networks      = @([ordered]@{ name = 'vnet-iic-mgmt-01'; subscription = 'sub-iic-management'; resource_group = 'rg-iic-mgmt-01'; location = 'westeurope'; address_space = @('10.20.4.0/24') })
            }
        }
        if (-not $NoNat) { $doc.landing_zone.connectivity = [ordered]@{ nat_gateway = $n } }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-FakeVnet([object[]]$Subnets) {
        [pscustomobject]@{ Name = 'vnet-iic-mgmt-01'; Subnets = @($Subnets | ForEach-Object { [pscustomobject]@{ Name = $_.Name; AddressPrefix = @('10.20.4.0/25'); NatGateway = $_.NatGateway } }) }
    }
    function Invoke-Nat([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Kind'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'New-NatGateway.ps1' {
    AfterAll { Remove-Variable -Name AzlNgTenant, AzlNgSub, AzlNgHome -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlNgTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlNgHome } } }
        Mock Set-AzContext { }
        Mock Get-AzVirtualNetwork { New-FakeVnet @([pscustomobject]@{ Name = 'snet-iic-mgmt-01'; NatGateway = $null }, [pscustomobject]@{ Name = 'snet-iic-mgmt-02'; NatGateway = $null }) }
        Mock Get-AzNatGateway { throw "The Resource 'Microsoft.Network/natGateways/$Name' was not found (404 NotFound)." }
        Mock Get-AzPublicIpAddress { throw "The Resource 'Microsoft.Network/publicIPAddresses/$Name' was not found (404 NotFound)." }
        Mock New-AzPublicIpAddress { [pscustomobject]@{ Name = $Name; Id = "/pip/$Name" } }
        Mock New-AzNatGateway { [pscustomobject]@{ Name = $Name; Id = "/subscriptions/x/providers/Microsoft.Network/natGateways/$Name" } }
        Mock Set-AzVirtualNetworkSubnetConfig { $VirtualNetwork }
        Mock Set-AzVirtualNetwork { $VirtualNetwork }
    }

    Context 'creating the gateway' {
        It 'creates the public IP address and the gateway in the group, region and subscription of the network, and attaches both subnets with one write' {
            $r = Invoke-Nat (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('Created', 'Attached', 'Attached')
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlNgSub }
            Should -Invoke New-AzPublicIpAddress -Times 1 -Exactly -ParameterFilter { $Name -eq 'ng-iic-mgmt-01-pip' -and $ResourceGroupName -eq 'rg-iic-mgmt-01' -and $Location -eq 'westeurope' -and $Sku -eq 'Standard' -and $AllocationMethod -eq 'Static' }
            Should -Invoke New-AzNatGateway -Times 1 -Exactly -ParameterFilter { $Name -eq 'ng-iic-mgmt-01' -and $ResourceGroupName -eq 'rg-iic-mgmt-01' -and $Sku -eq 'Standard' -and $PublicIpAddress.Name -eq 'ng-iic-mgmt-01-pip' -and -not $IdleTimeoutInMinutes }
            Should -Invoke Set-AzVirtualNetworkSubnetConfig -Times 2 -Exactly -ParameterFilter { $NatGateway.Name -eq 'ng-iic-mgmt-01' -and @($AddressPrefix) -contains '10.20.4.0/25' }
            Should -Invoke Set-AzVirtualNetwork -Times 1 -Exactly
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlNgHome }
        }

        It 'sets the idle timeout of the file, uses the resource group of the entry, and puts the file-level tags on what it creates' {
            $null = Invoke-Nat (New-InfraFile -Nat @{ idle_timeout_minutes = 10; resource_group = 'rg-iic-nat-01' } -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzNatGateway -Times 1 -Exactly -ParameterFilter { $IdleTimeoutInMinutes -eq 10 -and $ResourceGroupName -eq 'rg-iic-nat-01' -and $Tag['environment'] -eq 'lab' }
            Should -Invoke New-AzPublicIpAddress -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-iic-nat-01' -and $Tag['environment'] -eq 'lab' }
        }

        It 'reuses a public IP address that is there' {
            Mock Get-AzPublicIpAddress { [pscustomobject]@{ Name = $Name; Id = "/pip/$Name" } }
            $null = Invoke-Nat (New-InfraFile)
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
            Should -Invoke New-AzNatGateway -Times 1 -Exactly
        }

        It 'creates only what it needs and never removes a gateway or detaches a subnet' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-Az|Update-Az|Remove-AzVirtualNetworkSubnetConfig'
        }
    }

    Context 'things that exist already (idempotent)' {
        It 'creates nothing for a gateway that is there, attaches only the subnet that lacks it, and reports another idle timeout' {
            $global:AzlNgFake = [pscustomobject]@{ Name = 'ng-iic-mgmt-01'; Id = '/subscriptions/x/providers/Microsoft.Network/natGateways/ng-iic-mgmt-01'; IdleTimeoutInMinutes = 4 }
            try {
                Mock Get-AzNatGateway { $global:AzlNgFake }
                Mock Get-AzVirtualNetwork { New-FakeVnet @([pscustomobject]@{ Name = 'snet-iic-mgmt-01'; NatGateway = [pscustomobject]@{ Id = $global:AzlNgFake.Id } }, [pscustomobject]@{ Name = 'snet-iic-mgmt-02'; NatGateway = $null }) }
                $r = Invoke-Nat (New-InfraFile -Nat @{ idle_timeout_minutes = 10 })
                $r.ExitCode | Should -Be 0 -Because $r.Text
                @($r.Rows.Action) | Should -Be @('AlreadyExists', 'AlreadyAttached', 'Attached')
                $r.Rows[0].Detail | Should -Match 'idle timeout is 4 minutes'
                Should -Invoke New-AzNatGateway -Times 0 -Exactly
                Should -Invoke Set-AzVirtualNetworkSubnetConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'snet-iic-mgmt-02' }
            }
            finally { Remove-Variable -Name AzlNgFake -Scope Global -ErrorAction SilentlyContinue }
        }

        It 'leaves a subnet that uses another NAT gateway alone and says so, and writes nothing when nothing changed' {
            Mock Get-AzNatGateway { [pscustomobject]@{ Name = $Name; Id = "/x/natGateways/$Name" } }
            Mock Get-AzVirtualNetwork { New-FakeVnet @([pscustomobject]@{ Name = 'snet-iic-mgmt-01'; NatGateway = [pscustomobject]@{ Id = '/x/natGateways/ng-other' } }, [pscustomobject]@{ Name = 'snet-iic-mgmt-02'; NatGateway = [pscustomobject]@{ Id = '/x/natGateways/ng-iic-mgmt-01' } }) }
            $r = Invoke-Nat (New-InfraFile)
            $r.Rows[1].Detail | Should -Match 'another NAT gateway'
            $r.Rows[2].Detail | Should -BeNullOrEmpty
            Should -Invoke Set-AzVirtualNetworkSubnetConfig -Times 0 -Exactly
            Should -Invoke Set-AzVirtualNetwork -Times 0 -Exactly
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans everything and changes nothing' {
            $r = Invoke-Nat (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            @($r.Rows.Action) | Should -Be @('WouldCreate', 'WouldAttach', 'WouldAttach')
            Should -Invoke New-AzNatGateway -Times 0 -Exactly
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
            Should -Invoke Set-AzVirtualNetwork -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the file has no NAT gateway' {
            $r = Invoke-Nat (New-InfraFile -NoNat)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.tenant_id' {
            (Invoke-Nat (New-InfraFile -Azure @{ tenant_id = $null })).ExitCode | Should -Be 2
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a gateway with no name'; Nat = @{ name = $null } }
            @{ Why = 'a name Azure refuses'; Nat = @{ name = '-bad' } }
            @{ Why = 'no network'; Nat = @{ network = $null } }
            @{ Why = 'a network that is not in landing_zone.networks'; Nat = @{ network = 'vnet-other' } }
            @{ Why = 'no subnet'; Nat = @{ subnets = @() } }
            @{ Why = 'an idle timeout below 4'; Nat = @{ idle_timeout_minutes = 3 } }
            @{ Why = 'an idle timeout above 120'; Nat = @{ idle_timeout_minutes = 121 } }
            @{ Why = 'an idle timeout that is not a number'; Nat = @{ idle_timeout_minutes = 'long' } }
        ) {
            $r = Invoke-Nat (New-InfraFile -Nat $Nat)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzNatGateway -Times 0 -Exactly
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Nat (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Nat (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzNatGateway -Times 0 -Exactly
        }

        It 'stops when the network or a listed subnet does not exist, before it creates anything' {
            Mock Get-AzVirtualNetwork { throw "The Resource 'Microsoft.Network/virtualNetworks/x' was not found (404 NotFound)." }
            $r = Invoke-Nat (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Deploy-VirtualNetworks'
            Mock Get-AzVirtualNetwork { New-FakeVnet @([pscustomobject]@{ Name = 'snet-iic-mgmt-01'; NatGateway = $null }) }
            $r = Invoke-Nat (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match "no subnet named 'snet-iic-mgmt-02'"
            Should -Invoke New-AzNatGateway -Times 0 -Exactly
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzNatGateway { throw 'The client does not have authorization to perform action.' }
            (Invoke-Nat (New-InfraFile)).ExitCode | Should -Be 1
            Should -Invoke New-AzNatGateway -Times 0 -Exactly
        }

        It 'reports a failed creation, puts the subscription back, and exits 1' {
            Mock New-AzNatGateway { throw 'AuthorizationFailed' }
            $r = Invoke-Nat (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Should -Invoke Set-AzVirtualNetwork -Times 0 -Exactly
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlNgHome }
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
            $script:Text | Should -Not -Match 'variables\.yml|azure_platform|vnet-management|natgw-outbound'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_NatGateway_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.location', 'tags', 'landing_zone.connectivity.nat_gateway.name', 'landing_zone.connectivity.nat_gateway.resource_group', 'landing_zone.connectivity.nat_gateway.network', 'landing_zone.connectivity.nat_gateway.subnets', 'landing_zone.connectivity.nat_gateway.idle_timeout_minutes', 'landing_zone.networks[].name', 'landing_zone.networks[].subscription', 'landing_zone.networks[].resource_group', 'landing_zone.networks[].location', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
