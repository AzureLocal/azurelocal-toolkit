#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 05: New-AzureBastion.ps1 creates the Bastion host of
# landing_zone.connectivity.bastion in the AzureBastionSubnet of the network it names. Every Az cmdlet is mocked: no Azure, no tenant, no
# sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/AzureBastion.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-05-azure-bastion', 'powershell', 'New-AzureBastion.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzVirtualNetwork { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzBastion { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzPublicIpAddress { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzPublicIpAddress { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$Sku, [string]$AllocationMethod, [string[]]$Zone, [hashtable]$Tag) }
    function New-AzBastion { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$VirtualNetworkId, [string]$PublicIpAddressId, [string]$Sku, [hashtable]$Tag) }

    $global:AzlBsTenant = [guid]::NewGuid().ToString()
    $global:AzlBsSub = [guid]::NewGuid().ToString()
    $global:AzlBsHome = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([hashtable]$Bastion = @{}, [hashtable]$Azure = @{}, [object]$Tags = $null, [switch]$NoBastion)
        $az = [ordered]@{ tenant_id = $global:AzlBsTenant; location = 'eastus' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $b = [ordered]@{ name = 'bas-iic-hub-01'; sku = 'Standard'; network = 'vnet-iic-hub-01' }
        foreach ($k in $Bastion.Keys) { if ($null -eq $Bastion[$k]) { $b.Remove($k) } else { $b[$k] = $Bastion[$k] } }
        $doc = [ordered]@{
            azure        = $az
            landing_zone = [ordered]@{
                subscriptions = @([ordered]@{ name = 'sub-iic-connectivity'; id = $global:AzlBsSub; role = 'connectivity' })
                networks      = @([ordered]@{ name = 'vnet-iic-hub-01'; subscription = 'sub-iic-connectivity'; resource_group = 'rg-iic-conn-01'; location = 'westeurope'; address_space = @('10.20.0.0/22') })
            }
        }
        if (-not $NoBastion) { $doc.landing_zone.connectivity = [ordered]@{ bastion = $b } }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Bastion([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Row      = @($all | Where-Object { $_.PSObject.Properties['Bastion'] -and $_.PSObject.Properties['Action'] })[0]
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'New-AzureBastion.ps1' {
    AfterAll { Remove-Variable -Name AzlBsTenant, AzlBsSub, AzlBsHome -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlBsTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlBsHome } } }
        Mock Set-AzContext { }
        Mock Get-AzVirtualNetwork { [pscustomobject]@{ Name = $Name; Id = "/subscriptions/$($global:AzlBsSub)/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualNetworks/$Name"; Subnets = @([pscustomobject]@{ Name = 'AzureBastionSubnet'; AddressPrefix = @('10.20.1.0/26') }) } }
        Mock Get-AzBastion { throw "The Resource 'Microsoft.Network/bastionHosts/$Name' was not found (404 NotFound)." }
        Mock Get-AzPublicIpAddress { throw "The Resource 'Microsoft.Network/publicIPAddresses/$Name' was not found (404 NotFound)." }
        Mock New-AzPublicIpAddress { [pscustomobject]@{ Name = $Name; Id = "/pip/$Name"; IpAddress = '203.0.113.9' } }
        Mock New-AzBastion { [pscustomobject]@{ Name = $Name } }
    }

    Context 'creating the host' {
        It 'creates a Standard static public IP address and the host in the network, group and subscription of the entry' {
            $r = Invoke-Bastion (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Row.Action | Should -Be 'Created'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlBsSub }
            Should -Invoke New-AzPublicIpAddress -Times 1 -Exactly -ParameterFilter { $Name -eq 'bas-iic-hub-01-pip' -and $ResourceGroupName -eq 'rg-iic-conn-01' -and $Location -eq 'westeurope' -and $Sku -eq 'Standard' -and $AllocationMethod -eq 'Static' }
            Should -Invoke New-AzBastion -Times 1 -Exactly -ParameterFilter { $Name -eq 'bas-iic-hub-01' -and $ResourceGroupName -eq 'rg-iic-conn-01' -and $Sku -eq 'Standard' -and $VirtualNetworkId -like '*/virtualNetworks/vnet-iic-hub-01' -and $PublicIpAddressId -eq '/pip/bas-iic-hub-01-pip' }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlBsHome }
        }

        It 'uses the resource group and the SKU of the entry, and puts the file-level tags on what it creates' {
            $null = Invoke-Bastion (New-InfraFile -Bastion @{ resource_group = 'rg-iic-bas-01'; sku = 'Basic' } -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzBastion -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-iic-bas-01' -and $Sku -eq 'Basic' -and $Tag['environment'] -eq 'lab' }
            Should -Invoke New-AzPublicIpAddress -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-iic-bas-01' -and $Tag['environment'] -eq 'lab' }
        }

        It 'reuses a public IP address that is there' {
            Mock Get-AzPublicIpAddress { [pscustomobject]@{ Name = $Name; Id = "/pip/$Name" } }
            $r = Invoke-Bastion (New-InfraFile)
            $r.Row.Action | Should -Be 'Created'
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
        }

        It 'creates only a public IP address and a host and never removes or changes one' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-Az|Set-AzBastion|Update-Az|Set-AzVirtualNetwork'
        }
    }

    Context 'the host exists already (idempotent)' {
        It 'creates nothing and says so, and reports another SKU' {
            Mock Get-AzBastion { [pscustomobject]@{ Name = $Name; Sku = [pscustomobject]@{ Name = 'Basic' } } }
            $r = Invoke-Bastion (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'AlreadyExists'
            $r.Row.Detail | Should -Match 'SKU is Basic'
            Should -Invoke New-AzBastion -Times 0 -Exactly
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans the host and creates nothing' {
            $r = Invoke-Bastion (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzBastion -Times 0 -Exactly
            Should -Invoke New-AzPublicIpAddress -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the file has no Bastion host' {
            $r = Invoke-Bastion (New-InfraFile -NoBastion)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.tenant_id' {
            (Invoke-Bastion (New-InfraFile -Azure @{ tenant_id = $null })).ExitCode | Should -Be 2
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a host with no name'; Bastion = @{ name = $null } }
            @{ Why = 'a name Azure refuses'; Bastion = @{ name = '-bad' } }
            @{ Why = 'no network'; Bastion = @{ network = $null } }
            @{ Why = 'a network that is not in landing_zone.networks'; Bastion = @{ network = 'vnet-other' } }
            @{ Why = 'no SKU'; Bastion = @{ sku = $null } }
            @{ Why = 'a SKU that does not exist'; Bastion = @{ sku = 'Gold' } }
        ) {
            $r = Invoke-Bastion (New-InfraFile -Bastion $Bastion)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzBastion -Times 0 -Exactly
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Bastion (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Bastion (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzBastion -Times 0 -Exactly
        }

        It 'stops when the network does not exist' {
            Mock Get-AzVirtualNetwork { throw "The Resource 'Microsoft.Network/virtualNetworks/x' was not found (404 NotFound)." }
            $r = Invoke-Bastion (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Deploy-VirtualNetworks'
            Should -Invoke New-AzBastion -Times 0 -Exactly
        }

        It 'stops when the network has no AzureBastionSubnet, or one that is too small' {
            Mock Get-AzVirtualNetwork { [pscustomobject]@{ Name = $Name; Id = '/vnet'; Subnets = @([pscustomobject]@{ Name = 'azurebastionsubnet'; AddressPrefix = @('10.20.1.0/26') }) } }
            (Invoke-Bastion (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzVirtualNetwork { [pscustomobject]@{ Name = $Name; Id = '/vnet'; Subnets = @([pscustomobject]@{ Name = 'AzureBastionSubnet'; AddressPrefix = @('10.20.1.0/27') }) } }
            $r = Invoke-Bastion (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match '/26 or larger'
            Should -Invoke New-AzBastion -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzBastion { throw 'The client does not have authorization to perform action.' }
            (Invoke-Bastion (New-InfraFile)).ExitCode | Should -Be 1
            Should -Invoke New-AzBastion -Times 0 -Exactly
        }

        It 'reports a failed creation, puts the subscription back, and exits 1' {
            Mock New-AzBastion { throw 'AuthorizationFailed' }
            $r = Invoke-Bastion (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlBsHome }
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
            $script:Text | Should -Not -Match 'variables\.yml|logging\.ps1'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_AzureBastion_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.location', 'tags', 'landing_zone.connectivity.bastion.name', 'landing_zone.connectivity.bastion.resource_group', 'landing_zone.connectivity.bastion.sku', 'landing_zone.connectivity.bastion.network', 'landing_zone.networks[].name', 'landing_zone.networks[].subscription', 'landing_zone.networks[].resource_group', 'landing_zone.networks[].location', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
