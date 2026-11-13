#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 08: New-ArcGateway.ps1 creates the Arc gateway resource that
# networking.outbound.arc_gateway names, when scenario.outbound_path uses one. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used.
# Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ArcGateway.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-08-arc-gateway', 'powershell', 'New-ArcGateway.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzArcGateway { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function New-AzArcGateway { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$Location, [string]$SubscriptionId, [string]$GatewayType, [hashtable]$Tag) }

    $global:AzlAgTenant = [guid]::NewGuid().ToString()
    $global:AzlAgSub = [guid]::NewGuid().ToString()
    $global:AzlAgHome = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([hashtable]$Azure = @{}, [hashtable]$Gateway = @{}, [string]$Path = 'arc_gateway', [object]$Tags = $null)
        $az = [ordered]@{ tenant_id = $global:AzlAgTenant; subscription_id = $global:AzlAgSub; location = 'eastus'; resource_group = 'rg-iic-azl-01' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $gw = [ordered]@{ name = 'arcgw-iic-01' }
        foreach ($k in $Gateway.Keys) { if ($null -eq $Gateway[$k]) { $gw.Remove($k) } else { $gw[$k] = $Gateway[$k] } }
        $doc = [ordered]@{ azure = $az; scenario = [ordered]@{ outbound_path = $Path }; networking = [ordered]@{ outbound = [ordered]@{ arc_gateway = $gw } } }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Gateway([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Row      = @($all | Where-Object { $_.PSObject.Properties['ArcGateway'] -and $_.PSObject.Properties['Action'] })[0]
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'New-ArcGateway.ps1' {
    AfterAll { Remove-Variable -Name AzlAgTenant, AzlAgSub, AzlAgHome -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlAgTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlAgHome } } }
        Mock Set-AzContext { }
        Mock Get-AzArcGateway { throw "The Resource 'Microsoft.HybridCompute/gateways/$Name' was not found (404 NotFound)." }
        Mock New-AzArcGateway { [pscustomobject]@{ Name = $Name; GatewayId = '11111111-1111-1111-1111-111111111111'; Endpoint = 'gateway.example.test' } }
    }

    Context 'creating the gateway' {
        It 'creates a Public gateway in the subscription, resource group and region of the file' {
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Row.Action | Should -Be 'Created'
            $r.Row.Endpoint | Should -Be 'gateway.example.test'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlAgSub }
            Should -Invoke New-AzArcGateway -Times 1 -Exactly -ParameterFilter { $Name -eq 'arcgw-iic-01' -and $ResourceGroupName -eq 'rg-iic-azl-01' -and $Location -eq 'eastus' -and $SubscriptionId -eq $global:AzlAgSub -and $GatewayType -eq 'Public' }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlAgHome }
        }

        It 'uses the resource group of the gateway entry and creates for proxy_arc_gateway too, with the file-level tags' {
            $null = Invoke-Gateway (New-InfraFile -Gateway @{ resource_group = 'rg-iic-arcgw-01' } -Path 'proxy_arc_gateway' -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzArcGateway -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-iic-arcgw-01' -and $Tag['environment'] -eq 'lab' }
        }

        It 'creates only a gateway and never removes or changes one' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-Az|Update-Az|Invoke-AzRestMethod'
        }
    }

    Context 'the gateway exists already (idempotent), -WhatIf, and a path without a gateway' {
        It 'creates nothing and reports its id and endpoint' {
            Mock Get-AzArcGateway { [pscustomobject]@{ Name = $Name; GatewayId = '22222222-2222-2222-2222-222222222222'; Endpoint = 'existing.example.test' } }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'AlreadyExists'
            $r.Row.Endpoint | Should -Be 'existing.example.test'
            Should -Invoke New-AzArcGateway -Times 0 -Exactly
        }

        It 'plans the gateway and creates nothing under -WhatIf' {
            $r = Invoke-Gateway (New-InfraFile) -DryRun
            $r.Row.Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzArcGateway -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when scenario.outbound_path uses no gateway' {
            $r = Invoke-Gateway (New-InfraFile -Path 'direct')
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.<Key>' -ForEach @(@{ Key = 'tenant_id' }, @{ Key = 'subscription_id' }, @{ Key = 'location' }) {
            $r = Invoke-Gateway (New-InfraFile -Azure @{ $Key = $null })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match "azure\.$Key"
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses the all-zero subscription id, a gateway with no name, and a name with a space' {
            (Invoke-Gateway (New-InfraFile -Azure @{ subscription_id = [guid]::Empty.ToString() })).ExitCode | Should -Be 2
            (Invoke-Gateway (New-InfraFile -Gateway @{ name = $null })).ExitCode | Should -Be 2
            (Invoke-Gateway (New-InfraFile -Gateway @{ name = 'arc gw' })).ExitCode | Should -Be 2
            Should -Invoke New-AzArcGateway -Times 0 -Exactly
        }

        It 'refuses a file with no resource group at all' {
            (Invoke-Gateway (New-InfraFile -Azure @{ resource_group = $null })).ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Gateway (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzArcGateway -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzArcGateway { throw 'The client does not have authorization to perform action.' }
            (Invoke-Gateway (New-InfraFile)).ExitCode | Should -Be 1
            Should -Invoke New-AzArcGateway -Times 0 -Exactly
        }

        It 'reports a failed creation, puts the subscription back, and exits 1' {
            Mock New-AzArcGateway { throw 'AuthorizationFailed' }
            $r = Invoke-Gateway (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlAgHome }
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
            $script:Text | Should -Not -Match 'variables\.yml|logging\.ps1|2024-06-01-preview'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_ArcGateway_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.subscription_id', 'azure.location', 'azure.resource_group', 'tags', 'scenario.outbound_path', 'networking.outbound.arc_gateway.name', 'networking.outbound.arc_gateway.resource_group' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
