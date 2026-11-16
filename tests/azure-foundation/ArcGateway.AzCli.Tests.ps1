#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 08: New-ArcGateway.azcli.ps1 creates the Arc gateway resource that
# networking.outbound.arc_gateway names, with az commands, when scenario.outbound_path uses one. "az" is mocked: no Azure, no tenant and no sign-in is
# used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ArcGateway.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-08-arc-gateway', 'azurecli', 'New-ArcGateway.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlAgSub = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([hashtable]$Azure = @{}, [hashtable]$Gateway = @{}, [string]$Path = 'arc_gateway', [object]$Tags = $null, [object]$Tenant = $global:AzlFakeTenant)
        $az = [ordered]@{ subscription_id = $global:AzlAgSub; location = 'eastus'; resource_group = 'rg-iic-azl-01' }
        if ($null -ne $Tenant) { $az.tenant_id = $Tenant }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $gw = [ordered]@{ name = 'arcgw-iic-01' }
        foreach ($k in $Gateway.Keys) { if ($null -eq $Gateway[$k]) { $gw.Remove($k) } else { $gw[$k] = $Gateway[$k] } }
        $doc = [ordered]@{ azure = $az; scenario = [ordered]@{ outbound_path = $Path }; networking = [ordered]@{ outbound = [ordered]@{ arc_gateway = $gw } } }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
}

Describe 'New-ArcGateway.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlAgSub, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
        Add-AzNotFound 'arcgateway show*'
        Add-AzRoute 'arcgateway create*' ([ordered]@{ name = 'arcgw-iic-01'; properties = [ordered]@{ gatewayId = '11111111-1111-1111-1111-111111111111'; gatewayEndpoint = 'gateway.example.test' } })
    }

    Context 'creating the gateway' {
        It 'creates a Public gateway in the subscription, resource group and region of the file' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            $r.Rows[0].Endpoint | Should -Be 'gateway.example.test'
            $r.Rows[0].GatewayId | Should -Be '11111111-1111-1111-1111-111111111111'
            Get-AzCall "arcgateway create --name arcgw-iic-01 --resource-group rg-iic-azl-01 --location eastus --subscription $($global:AzlAgSub) --gateway-type Public*" | Should -HaveCount 1
        }

        It 'reads the gateway first, in the same subscription, and never changes the subscription of the az session' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall "arcgateway show --name arcgw-iic-01 --resource-group rg-iic-azl-01 --subscription $($global:AzlAgSub)*" | Should -HaveCount 1
            Get-AzCall 'account set*' | Should -BeNullOrEmpty
        }

        It 'uses the resource group of the gateway entry, and creates for proxy_arc_gateway too, with the file-level tags' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Gateway @{ resource_group = 'rg-iic-arcgw-01' } -Path 'proxy_arc_gateway' -Tags ([ordered]@{ environment = 'lab' }))
            Get-AzCall 'arcgateway create * --resource-group rg-iic-arcgw-01 *--tags environment=lab*' | Should -HaveCount 1
        }
    }

    Context 'the gateway already exists' {
        It 'creates nothing and reports its id and endpoint' {
            Add-AzRoute 'arcgateway show*' ([ordered]@{ name = 'arcgw-iic-01'; properties = [ordered]@{ gatewayId = '22222222-2222-2222-2222-222222222222'; gatewayEndpoint = 'existing.example.test' } })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Endpoint | Should -Be 'existing.example.test'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf' {
        It 'plans the gateway and writes nothing to Azure' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'arcgw.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
        }
    }

    Context 'nothing to do' {
        It 'says so and calls nothing when scenario.outbound_path uses no Arc gateway' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Path 'default')
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a missing tenant'; Tenant = $null; Azure = @{}; Gateway = @{}; Match = 'azure.tenant_id' }
            @{ Case = 'a tenant that is not a GUID'; Tenant = 'not-a-guid'; Azure = @{}; Gateway = @{}; Match = 'azure.tenant_id' }
            @{ Case = 'a gateway without a name'; Tenant = 'default'; Azure = @{}; Gateway = @{ name = $null }; Match = 'arc_gateway.name is missing' }
            @{ Case = 'a name Azure does not accept'; Tenant = 'default'; Azure = @{}; Gateway = @{ name = 'bad name!' }; Match = 'not a valid name' }
            @{ Case = 'no resource group anywhere'; Tenant = 'default'; Azure = @{ resource_group = $null }; Gateway = @{}; Match = 'No resource group' }
            @{ Case = 'a missing subscription'; Tenant = 'default'; Azure = @{ subscription_id = $null }; Gateway = @{}; Match = 'azure.subscription_id' }
            @{ Case = 'the all-zero subscription'; Tenant = 'default'; Azure = @{ subscription_id = '00000000-0000-0000-0000-000000000000' }; Gateway = @{}; Match = 'azure.subscription_id' }
            @{ Case = 'a missing location'; Tenant = 'default'; Azure = @{ location = $null }; Gateway = @{}; Match = 'azure.location' }
        ) {
            $tenant = if ($Tenant -eq 'default') { $global:AzlFakeTenant } else { $Tenant }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Azure $Azure -Gateway $Gateway -Tenant $tenant)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
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

        It 'stops when the arcgateway extension is not installed' {
            Add-AzRoute 'extension show*' 'The extension arcgateway is not installed.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'az extension add --name arcgateway'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports a creation that fails' {
            Add-AzRoute 'arcgateway create*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'AuthorizationFailed'
        }

        It 'does not hide a read error that is not a not-found' {
            Add-AzRoute 'arcgateway show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
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
                ($registry -match ('New_ArcGateway_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
