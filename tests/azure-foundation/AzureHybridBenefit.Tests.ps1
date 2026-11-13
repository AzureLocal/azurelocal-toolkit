#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 05 (licensing and telemetry), task 01: Enable-AzureHybridBenefit.ps1 activates Azure Hybrid Benefit on the Azure Local instance when
# operations.licensing.azure_hybrid_benefit is true. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/AzureHybridBenefit.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-05-licensing-telemetry', 'task-01-enable-azure-hybrid-benefit', 'powershell', 'Enable-AzureHybridBenefit.ps1')
    Import-Module powershell-yaml

    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzStackHciCluster { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit { [CmdletBinding()] param([string]$ClusterName, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$SoftwareAssuranceIntent) }

    $global:AzlAhbTenant = [guid]::NewGuid().ToString()
    $global:AzlAhbSub = [guid]::NewGuid().ToString()
    $global:AzlAhbHome = [guid]::NewGuid().ToString()
    $global:AzlAhbStatus = 'NotEnabled'

    function New-InfraFile {
        param([object]$Benefit = $true, [hashtable]$Azure = @{}, [string]$Architecture = 's2d', [string]$Connectivity = 'connected', [hashtable]$Cluster = @{}, [switch]$NoLicensing)
        $az = [ordered]@{ tenant_id = $global:AzlAhbTenant; subscription_id = $global:AzlAhbSub; resource_group = 'rg-iic-azl-01' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $cl = [ordered]@{ name = 'iic-azl-01' }
        foreach ($k in $Cluster.Keys) { if ($null -eq $Cluster[$k]) { $cl.Remove($k) } else { $cl[$k] = $Cluster[$k] } }
        $doc = [ordered]@{ azure = $az; cluster = $cl; scenario = [ordered]@{ storage_architecture = $Architecture; connectivity = $Connectivity } }
        if (-not $NoLicensing) { $doc.operations = [ordered]@{ licensing = [ordered]@{ azure_hybrid_benefit = $Benefit } } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Ahb([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Row      = @($all | Where-Object { $_.PSObject.Properties['Cluster'] -and $_.PSObject.Properties['Action'] })[0]
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Enable-AzureHybridBenefit.ps1' {
    AfterAll { Remove-Variable -Name AzlAhbTenant, AzlAhbSub, AzlAhbHome, AzlAhbStatus -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        $global:AzlAhbStatus = 'NotEnabled'
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlAhbTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlAhbHome } } }
        Mock Set-AzContext { }
        Mock Get-AzStackHciCluster { [pscustomobject]@{ Name = $Name; SoftwareAssurancePropertySoftwareAssuranceStatus = $global:AzlAhbStatus } }
        Mock Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit { $global:AzlAhbStatus = 'Enabled'; [pscustomobject]@{ Name = $ClusterName } }
    }

    Context 'activating the benefit' {
        It 'activates it on the instance named by cluster.name, in azure.resource_group of azure.subscription_id, with the intent Enable' {
            $r = Invoke-Ahb (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Row.Action | Should -Be 'Activated'
            $r.Row.Status | Should -Be 'Enabled'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlAhbSub }
            Should -Invoke Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -Times 1 -Exactly -ParameterFilter { $ClusterName -eq 'iic-azl-01' -and $ResourceGroupName -eq 'rg-iic-azl-01' -and $SubscriptionId -eq $global:AzlAhbSub -and $SoftwareAssuranceIntent -eq 'Enable' }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlAhbHome }
            $r.Text | Should -Match 'cannot be deactivated'
        }

        It 'says so when the call worked but the status does not read Enabled yet' {
            Mock Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit { [pscustomobject]@{ Name = $ClusterName } }
            $r = Invoke-Ahb (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'Activated'
            $r.Row.Detail | Should -Match 'Read it again'
        }

        It 'never turns the benefit off' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            $code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
            $code | Should -Not -Match 'Disable|Remove-Az'
            $code | Should -Not -Match 'Get-AzConnectedMachine|Update-AzConnectedMachine|Windows_Server'
        }
    }

    Context 'the benefit is on already (idempotent)' {
        It 'activates nothing and reports it' {
            $global:AzlAhbStatus = 'Enabled'
            $r = Invoke-Ahb (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'AlreadyEnabled'
            Should -Invoke Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -Times 0 -Exactly
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'reads the instance, plans the activation and changes nothing' {
            $r = Invoke-Ahb (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'WouldActivate'
            Should -Invoke Get-AzStackHciCluster -Times 1 -Exactly
            Should -Invoke Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the value is false, or the file has no licensing section' {
            foreach ($file in (New-InfraFile -Benefit $false), (New-InfraFile -NoLicensing)) {
                $r = Invoke-Ahb $file
                $r.ExitCode | Should -Be 0
                $r.Text | Should -Match 'nothing to do'
            }
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a missing azure.tenant_id'; Settings = @{ Azure = @{ tenant_id = $null } } }
            @{ Why = 'a missing azure.subscription_id'; Settings = @{ Azure = @{ subscription_id = $null } } }
            @{ Why = 'a missing azure.resource_group'; Settings = @{ Azure = @{ resource_group = $null } } }
            @{ Why = 'a missing cluster.name'; Settings = @{ Cluster = @{ name = $null } } }
            @{ Why = 'a SAN instance (external storage)'; Settings = @{ Architecture = 'san' } }
            @{ Why = 'a hybrid instance (external storage)'; Settings = @{ Architecture = 'hybrid' } }
            @{ Why = 'a disconnected instance'; Settings = @{ Connectivity = 'disconnected' } }
            @{ Why = 'a value that is not true or false'; Settings = @{ Benefit = 'maybe' } }
        ) {
            $r = Invoke-Ahb (New-InfraFile @Settings)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -Times 0 -Exactly
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Ahb (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Ahb (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -Times 0 -Exactly
        }

        It 'stops when the instance does not exist' {
            Mock Get-AzStackHciCluster { throw "The Resource 'Microsoft.AzureStackHCI/clusters/$Name' was not found (404 NotFound)." }
            $r = Invoke-Ahb (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'was not found in the resource group'
            Should -Invoke Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzStackHciCluster { throw 'The client does not have authorization to perform action.' }
            (Invoke-Ahb (New-InfraFile)).ExitCode | Should -Be 1
            Should -Invoke Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -Times 0 -Exactly
        }

        It 'reports a failed activation (no Software Assurance contract, for example), puts the subscription back, and exits 1' {
            Mock Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit { throw "Failed to activate Azure Hybrid Benefit. We couldn't find your Software Assurance contract." }
            $r = Invoke-Ahb (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Row.Action | Should -Be 'Failed'
            $r.Row.Detail | Should -Match 'Software Assurance contract'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlAhbHome }
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
            $script:Text | Should -Not -Match 'ConvertFrom-Yaml|\$config\.|ConfigPath'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Enable_AzureHybridBenefit_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'cluster.name', 'scenario.storage_architecture', 'scenario.connectivity', 'operations.licensing.azure_hybrid_benefit' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
