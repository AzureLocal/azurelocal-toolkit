#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 07: New-NatGateway.azcli.ps1 creates the NAT gateway that
# landing_zone.connectivity.nat_gateway describes and puts the listed subnets behind it, with az commands. "az" is mocked: no Azure, no tenant and no
# sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/NatGateway.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-07-nat-gateway', 'azurecli', 'New-NatGateway.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlNgSub = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([hashtable]$Nat = @{}, [hashtable]$Azure = @{}, [object]$Tags = $null, [switch]$NoNat, [object]$Tenant = $global:AzlFakeTenant)
        $az = [ordered]@{ location = 'eastus' }
        if ($null -ne $Tenant) { $az.tenant_id = $Tenant }
        $null = Set-AzOverride $az $Azure
        $n = Set-AzOverride ([ordered]@{ name = 'ng-iic-mgmt-01'; network = 'vnet-iic-mgmt-01'; subnets = @('snet-iic-mgmt-01', 'snet-iic-mgmt-02') }) $Nat
        $doc = [ordered]@{
            azure        = $az
            landing_zone = [ordered]@{
                subscriptions = @([ordered]@{ name = 'sub-iic-management'; id = $global:AzlNgSub; role = 'management' })
                networks      = @([ordered]@{ name = 'vnet-iic-mgmt-01'; subscription = 'sub-iic-management'; resource_group = 'rg-iic-mgmt-01'; location = 'westeurope'; address_space = @('198.51.100.0/24') })
            }
        }
        if (-not $NoNat) { $doc.landing_zone.connectivity = [ordered]@{ nat_gateway = $n } }
        if ($Tags) { $doc.tags = $Tags }
        Save-AzInfraFile $doc
    }
    # The virtual network as az returns it: each subnet may name a NAT gateway.
    function New-FakeVnet([hashtable]$Attached = @{}) {
        $subnets = foreach ($name in 'snet-iic-mgmt-01', 'snet-iic-mgmt-02') {
            $s = [ordered]@{ name = $name; addressPrefix = '198.51.100.0/25' }
            if ($Attached.ContainsKey($name)) { $s.natGateway = [ordered]@{ id = $Attached[$name] } }
            $s
        }
        [ordered]@{ name = 'vnet-iic-mgmt-01'; id = '/vnets/vnet-iic-mgmt-01'; subnets = @($subnets) }
    }
}

Describe 'New-NatGateway.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlNgSub, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
        Add-AzRoute 'network vnet show*' (New-FakeVnet)
        Add-AzRoute 'network nat gateway create*' ([ordered]@{ name = 'ng-iic-mgmt-01'; id = '/natGateways/ng-iic-mgmt-01' })
    }

    Context 'creating the gateway (happy path)' {
        It 'creates a Standard static public IP address and the gateway behind it, in the group and region of the network, with the file values' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Nat @{ idle_timeout_minutes = 10 })
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-AzCall "network public-ip create --name ng-iic-mgmt-01-pip --resource-group rg-iic-mgmt-01 --location westeurope --subscription $($global:AzlNgSub) --sku Standard --allocation-method Static" | Should -HaveCount 1
            Get-AzCall "network nat gateway create --name ng-iic-mgmt-01 --resource-group rg-iic-mgmt-01 --location westeurope --subscription $($global:AzlNgSub) --public-ip-addresses ng-iic-mgmt-01-pip --idle-timeout 10" | Should -HaveCount 1
            @($r.Rows | Where-Object Kind -EQ 'NatGateway').Action | Should -Be 'Created'
        }

        It 'attaches each listed subnet to the gateway by its resource id' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall "network vnet subnet update --name snet-iic-mgmt-01 --vnet-name vnet-iic-mgmt-01 --resource-group rg-iic-mgmt-01 --subscription $($global:AzlNgSub) --nat-gateway /natGateways/ng-iic-mgmt-01" | Should -HaveCount 1
            Get-AzCall 'network vnet subnet update --name snet-iic-mgmt-02*' | Should -HaveCount 1
            @($r.Rows | Where-Object Kind -EQ 'Subnet').Action | Should -Be @('Attached', 'Attached')
        }

        It 'leaves the idle timeout to Azure when the file gives none' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall 'network nat gateway create*--idle-timeout*' | Should -BeNullOrEmpty
        }

        It 'puts the file-level tags on the public IP address and the gateway' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Tags ([ordered]@{ environment = 'lab' }))
            Get-AzCall 'network public-ip create*--tags environment=lab' | Should -HaveCount 1
            Get-AzCall 'network nat gateway create*--tags environment=lab' | Should -HaveCount 1
        }

        It 'uses the resource group of the gateway entry, and azure.location when the network has no location' {
            $file = New-InfraFile -Nat @{ resource_group = 'rg-iic-nat-01' }
            $null = Invoke-AzCliScript $script:Script $file
            Get-AzCall 'network nat gateway create --name ng-iic-mgmt-01 --resource-group rg-iic-nat-01*' | Should -HaveCount 1
            Get-AzCall 'network public-ip show --name ng-iic-mgmt-01-pip --resource-group rg-iic-nat-01*' | Should -HaveCount 1
        }

        It 'reuses a public IP address that is already there' {
            Add-AzRoute 'network public-ip show*' ([ordered]@{ name = 'ng-iic-mgmt-01-pip'; id = '/pips/ng-iic-mgmt-01-pip' })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            Get-AzCall 'network public-ip create*' | Should -BeNullOrEmpty
            Get-AzCall 'network nat gateway create*' | Should -HaveCount 1
        }
    }

    Context 'the gateway and the subnets already exist (idempotent)' {
        BeforeEach {
            Add-AzRoute 'network nat gateway show*' ([ordered]@{ name = 'ng-iic-mgmt-01'; id = '/natGateways/ng-iic-mgmt-01'; idleTimeoutInMinutes = 4 })
            Add-AzRoute 'network vnet show*' (New-FakeVnet @{ 'snet-iic-mgmt-01' = '/natGateways/ng-iic-mgmt-01'; 'snet-iic-mgmt-02' = '/natGateways/ng-iic-mgmt-01' })
        }

        It 'creates and changes nothing' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Kind -EQ 'NatGateway').Action | Should -Be 'AlreadyExists'
            @($r.Rows | Where-Object Kind -EQ 'Subnet').Action | Should -Be @('AlreadyAttached', 'AlreadyAttached')
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports another idle timeout and leaves the gateway alone' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Nat @{ idle_timeout_minutes = 15 })
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Kind -EQ 'NatGateway').Detail | Should -Match 'idle timeout is 4 minutes'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports a subnet that uses another NAT gateway and does not move it' {
            Add-AzRoute 'network vnet show*' (New-FakeVnet @{ 'snet-iic-mgmt-01' = '/natGateways/ng-other-01' })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            @($r.Rows | Where-Object Resource -EQ 'snet-iic-mgmt-01').Detail | Should -Match 'another NAT gateway'
            Get-AzCall 'network vnet subnet update --name snet-iic-mgmt-01*' | Should -BeNullOrEmpty
            Get-AzCall 'network vnet subnet update --name snet-iic-mgmt-02*' | Should -HaveCount 1
        }
    }

    Context '-WhatIf' {
        It 'plans everything and writes nothing to Azure' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-AzWriteCall | Should -BeNullOrEmpty
            @($r.Rows | Where-Object Kind -EQ 'NatGateway').Action | Should -Be 'WouldCreate'
            @($r.Rows | Where-Object Kind -EQ 'Subnet').Action | Should -Be @('WouldAttach', 'WouldAttach')
            $r.Text | Should -Match 'would be created'
        }

        It 'plans the attachment to an existing gateway and writes nothing' {
            Add-AzRoute 'network nat gateway show*' ([ordered]@{ name = 'ng-iic-mgmt-01'; id = '/natGateways/ng-iic-mgmt-01' })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            @($r.Rows | Where-Object Kind -EQ 'Subnet').Action | Should -Be @('WouldAttach', 'WouldAttach')
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'nat.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'does nothing and exits 0 when the file has no NAT gateway' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoNat)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a missing tenant'; Tenant = $null; Nat = @{}; Match = 'azure.tenant_id' }
            @{ Case = 'a gateway without a name'; Tenant = 'default'; Nat = @{ name = $null }; Match = 'nat_gateway.name is missing' }
            @{ Case = 'a name Azure does not accept'; Tenant = 'default'; Nat = @{ name = 'bad name!' }; Match = 'not a valid name' }
            @{ Case = 'no network'; Tenant = 'default'; Nat = @{ network = $null }; Match = 'nat_gateway.network is missing' }
            @{ Case = 'a network that is not in the file'; Tenant = 'default'; Nat = @{ network = 'vnet-nowhere' }; Match = 'not an entry of landing_zone.networks' }
            @{ Case = 'no subnets'; Tenant = 'default'; Nat = @{ subnets = @() }; Match = 'subnets is empty' }
            @{ Case = 'an idle timeout out of range'; Tenant = 'default'; Nat = @{ idle_timeout_minutes = 3 }; Match = 'not a number from 4 to 120' }
            @{ Case = 'an idle timeout that is not a number'; Tenant = 'default'; Nat = @{ idle_timeout_minutes = 'long' }; Match = 'not a number from 4 to 120' }
        ) {
            $tenant = if ($Tenant -eq 'default') { $global:AzlFakeTenant } else { $Tenant }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Nat $Nat -Tenant $tenant)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses a subscription whose id is the all-zero placeholder' {
            $file = New-InfraFile
            $text = (Get-Content -LiteralPath $file -Raw).Replace($global:AzlNgSub, '00000000-0000-0000-0000-000000000000')
            Set-Content -LiteralPath $file -Value $text
            $r = Invoke-AzCliScript $script:Script $file
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

        It 'stops when the virtual network does not exist' {
            Add-AzNotFound 'network vnet show*'
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Create it first'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the virtual network lacks a listed subnet' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Nat @{ subnets = @('snet-iic-mgmt-01', 'snet-missing') })
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match "no subnet named 'snet-missing'"
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports a creation that fails' {
            Add-AzRoute 'network nat gateway create*' 'ERROR: (QuotaExceeded) Quota exceeded.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'QuotaExceeded'
            Get-AzCall 'network vnet subnet update*' | Should -BeNullOrEmpty
        }

        It 'does not hide a read error that is not a not-found' {
            Add-AzRoute 'network nat gateway show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
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

        It 'reads its values through the toolkit loader, holds no GUID and never deletes' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
            $script:Text | Should -Not -Match '\bdelete\b'
        }

        It 'has every parameter registered' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($p in 'InfrastructureFile', 'LogPath') {
                ($registry -match ('New_NatGateway_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
