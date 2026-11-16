#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 05: New-AzureBastion.azcli.ps1 creates the Azure Bastion host that
# landing_zone.connectivity.bastion describes, with az commands. "az" is mocked: no Azure, no tenant and no sign-in is used. Ids are generated per run;
# the address ranges use the documentation ranges (RFC 5737).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/AzureBastion.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-05-azure-bastion', 'azurecli', 'New-AzureBastion.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlBsSub = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([hashtable]$Bastion = @{}, [hashtable]$Network = @{}, [hashtable]$Azure = @{}, [object]$Tags = $null, [switch]$NoBastion, [object]$Tenant = $global:AzlFakeTenant)
        $az = [ordered]@{ location = 'eastus' }
        if ($null -ne $Tenant) { $az.tenant_id = $Tenant }
        $null = Set-AzOverride $az $Azure
        $b = Set-AzOverride ([ordered]@{ name = 'bas-iic-hub-01'; network = 'vnet-iic-hub-01'; sku = 'Standard' }) $Bastion
        $n = Set-AzOverride ([ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-hub-01'; location = 'westeurope'; address_space = @('198.51.100.0/24') }) $Network
        $doc = [ordered]@{
            azure        = $az
            landing_zone = [ordered]@{ subscriptions = @([ordered]@{ name = 'sub-iic-connectivity'; id = $global:AzlBsSub; role = 'connectivity' }); networks = @($n) }
        }
        if (-not $NoBastion) { $doc.landing_zone.connectivity = [ordered]@{ bastion = $b } }
        if ($Tags) { $doc.tags = $Tags }
        Save-AzInfraFile $doc
    }
    # The virtual network as az returns it, with its subnets.
    function New-FakeVnet([object[]]$Subnets = @([ordered]@{ name = 'AzureBastionSubnet'; addressPrefix = '198.51.100.64/26' })) {
        [ordered]@{ name = 'vnet-iic-hub-01'; id = '/vnets/vnet-iic-hub-01'; subnets = @($Subnets) }
    }
}

Describe 'New-AzureBastion.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlBsSub, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
        Add-AzRoute 'network vnet show*' (New-FakeVnet)
    }

    Context 'creating the host (happy path)' {
        It 'creates a Standard static public IP address without zones and the host, in the subscription, group and region of the file' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            Get-AzCall "network public-ip create --name bas-iic-hub-01-pip --resource-group rg-iic-hub-01 --location westeurope --subscription $($global:AzlBsSub) --sku Standard --allocation-method Static" | Should -HaveCount 1
            Get-AzCall 'network public-ip create *--zone*' | Should -HaveCount 0
            Get-AzCall "network bastion create --name bas-iic-hub-01 --resource-group rg-iic-hub-01 --location westeurope --subscription $($global:AzlBsSub) --vnet-name /vnets/vnet-iic-hub-01 --public-ip-address bas-iic-hub-01-pip --sku Standard" | Should -HaveCount 1
        }

        It 'passes the SKU of the file and the file-level tags, and never changes the subscription of the az session' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Bastion @{ sku = 'Premium' } -Tags ([ordered]@{ environment = 'lab' }))
            Get-AzCall 'network bastion create*--sku Premium --tags environment=lab' | Should -HaveCount 1
            Get-AzCall 'network public-ip create*--tags environment=lab' | Should -HaveCount 1
            Get-AzCall 'account set*' | Should -BeNullOrEmpty
        }

        It 'uses the resource group of the bastion entry for the host and its address, and the network group for the virtual network' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Bastion @{ resource_group = 'rg-iic-bas-01' })
            Get-AzCall 'network bastion create --name bas-iic-hub-01 --resource-group rg-iic-bas-01*' | Should -HaveCount 1
            Get-AzCall 'network public-ip show --name bas-iic-hub-01-pip --resource-group rg-iic-bas-01*' | Should -HaveCount 1
            Get-AzCall 'network vnet show --name vnet-iic-hub-01 --resource-group rg-iic-hub-01*' | Should -HaveCount 1
        }

        It 'uses azure.location when the network has none' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Network @{ location = $null })
            Get-AzCall 'network bastion create*--location eastus*' | Should -HaveCount 1
        }

        It 'reuses a public IP address that is already there' {
            Add-AzRoute 'network public-ip show*' ([ordered]@{ name = 'bas-iic-hub-01-pip'; id = '/pips/bas-iic-hub-01-pip' })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            Get-AzCall 'network public-ip create*' | Should -BeNullOrEmpty
            Get-AzCall 'network bastion create*' | Should -HaveCount 1
        }
    }

    Context 'the host already exists (idempotent)' {
        It 'creates nothing and says so' {
            Add-AzRoute 'network bastion show*' ([ordered]@{ name = 'bas-iic-hub-01'; sku = [ordered]@{ name = 'Standard' } })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports another SKU and leaves the host alone' {
            Add-AzRoute 'network bastion show*' ([ordered]@{ name = 'bas-iic-hub-01'; sku = [ordered]@{ name = 'Basic' } })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Detail | Should -Match 'SKU is Basic, the file says Standard'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf' {
        It 'plans the address and the host and writes nothing to Azure' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'bastion.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'does nothing and exits 0 when the file has no Bastion host' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoBastion)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a missing tenant'; Tenant = $null; Bastion = @{}; Network = @{}; Match = 'azure.tenant_id' }
            @{ Case = 'a host without a name'; Tenant = 'default'; Bastion = @{ name = $null }; Network = @{}; Match = 'bastion.name is missing' }
            @{ Case = 'a name Azure does not accept'; Tenant = 'default'; Bastion = @{ name = 'bad name!' }; Network = @{}; Match = 'not a valid name' }
            @{ Case = 'no network'; Tenant = 'default'; Bastion = @{ network = $null }; Network = @{}; Match = 'bastion.network is missing' }
            @{ Case = 'a network that is not in the file'; Tenant = 'default'; Bastion = @{ network = 'vnet-nowhere' }; Network = @{}; Match = 'not an entry of landing_zone.networks' }
            @{ Case = 'an unknown SKU'; Tenant = 'default'; Bastion = @{ sku = 'Gigantic' }; Network = @{}; Match = 'missing or not allowed' }
            @{ Case = 'no SKU'; Tenant = 'default'; Bastion = @{ sku = $null }; Network = @{}; Match = 'missing or not allowed' }
            @{ Case = 'a network without a subscription'; Tenant = 'default'; Bastion = @{}; Network = @{ subscription = $null }; Match = 'has no subscription' }
            @{ Case = 'a network with a subscription that has no id'; Tenant = 'default'; Bastion = @{}; Network = @{ subscription = 'sub-unknown' }; Match = 'no usable id' }
            @{ Case = 'a network without a resource group'; Tenant = 'default'; Bastion = @{}; Network = @{ resource_group = $null }; Match = 'no resource_group' }
        ) {
            $tenant = if ($Tenant -eq 'default') { $global:AzlFakeTenant } else { $Tenant }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Bastion $Bastion -Network $Network -Tenant $tenant)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses a network with no location anywhere' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Network @{ location = $null } -Azure @{ location = $null })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'No region'
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

        It 'stops when the network has no AzureBastionSubnet, or one that is spelled differently' {
            Add-AzRoute 'network vnet show*' (New-FakeVnet @([ordered]@{ name = 'azurebastionsubnet'; addressPrefix = '198.51.100.64/26' }))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'no subnet named AzureBastionSubnet'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the AzureBastionSubnet is smaller than /26' {
            Add-AzRoute 'network vnet show*' (New-FakeVnet @([ordered]@{ name = 'AzureBastionSubnet'; addressPrefix = '198.51.100.64/27' }))
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'needs /26 or larger'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reads the prefix of a subnet that az reports as a list' {
            Add-AzRoute 'network vnet show*' (New-FakeVnet @([ordered]@{ name = 'AzureBastionSubnet'; addressPrefixes = @('198.51.100.64/26') }))
            (Invoke-AzCliScript $script:Script (New-InfraFile)).ExitCode | Should -Be 0
        }

        It 'reports a creation that fails' {
            Add-AzRoute 'network bastion create*' 'ERROR: (QuotaExceeded) Quota exceeded.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'QuotaExceeded'
        }

        It 'does not hide a read error that is not a not-found' {
            Add-AzRoute 'network bastion show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
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

        It 'reads its values through the toolkit loader and holds no GUID' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter registered' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($p in 'InfrastructureFile', 'LogPath') {
                ($registry -match ('New_AzureBastion_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
