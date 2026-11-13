#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 02 (monitoring and observability), task 02: Install-AzureMonitorAgent.ps1 installs the Azure Monitor Agent extension on the Azure Local instance of the file.
# Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/AzureMonitorAgent.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-02-monitoring-observability', 'task-02-configure-azure-monitor-agent', 'powershell', 'Install-AzureMonitorAgent.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzStackHciCluster { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function Get-AzStackHciExtension { [CmdletBinding()] param([string]$ClusterName, [string]$ResourceGroupName, [string]$ArcSettingName, [string]$Name, [string]$SubscriptionId) }
    function New-AzStackHciExtension { [CmdletBinding()] param([string]$ClusterName, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$ArcSettingName, [string]$Name, [string]$ExtensionParameterPublisher, [string]$ExtensionParameterType, [switch]$ExtensionParameterEnableAutomaticUpgrade, [switch]$NoWait) }

    $global:AzlAmaTestTenant = [guid]::NewGuid().ToString()
    $global:AzlAmaTestSub = [guid]::NewGuid().ToString()
    $global:AzlAmaTestHome = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object]$Monitoring = (New-Monitoring), [object]$TenantId = $global:AzlAmaTestTenant, [object]$SubscriptionId = $global:AzlAmaTestSub, [string]$Group = 'rg-azl-01', [string]$Cluster = 'iic-azl-01')
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $SubscriptionId) { $doc.azure.subscription_id = $SubscriptionId }
        if ($Group) { $doc.azure.resource_group = $Group }
        if ($Cluster) { $doc.cluster = [ordered]@{ name = $Cluster } }
        if ($null -ne $Monitoring) { $doc.operations = [ordered]@{ monitoring = $Monitoring } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Monitoring([hashtable]$Override = @{}) {
        $m = [ordered]@{ enabled = $true; log_analytics_workspace = 'log-azl-01'; workspace_resource_group = 'rg-mgmt-01' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $m.Remove($k) } else { $m[$k] = $Override[$k] } }
        $m
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Agent([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['Extension'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Install-AzureMonitorAgent.ps1' {
    AfterAll {
        Remove-Variable -Name AzlAmaTestTenant, AzlAmaTestSub, AzlAmaTestHome -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlAmaTestTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlAmaTestHome } } }
        Mock Set-AzContext { }
        Mock Get-AzStackHciCluster { [pscustomobject]@{ Name = $Name; Id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/clusters/$Name" } }
        Mock Get-AzStackHciExtension { throw 'The Resource ''Microsoft.AzureStackHCI/clusters/x/arcSettings/default/extensions/AzureMonitorWindowsAgent'' was not found (404 NotFound).' }
        Mock New-AzStackHciExtension { [pscustomobject]@{ Name = $Name } }
    }

    Context 'installing the extension (happy path)' {
        It 'installs the Azure Monitor Agent on the instance, through its Arc setting, with the publisher and type Learn names' {
            $r = Invoke-Agent (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Result.Action | Should -Be 'Created'
            Should -Invoke New-AzStackHciExtension -Times 1 -Exactly -ParameterFilter {
                $ClusterName -eq 'iic-azl-01' -and $ResourceGroupName -eq 'rg-azl-01' -and $SubscriptionId -eq $global:AzlAmaTestSub -and $ArcSettingName -eq 'default' -and $Name -eq 'AzureMonitorWindowsAgent' -and
                $ExtensionParameterPublisher -eq 'Microsoft.Azure.Monitor' -and $ExtensionParameterType -eq 'AzureMonitorWindowsAgent'
            }
        }

        It 'sets no automatic upgrade (Learn: the upgrade happens with the solution update)' {
            $null = Invoke-Agent (New-InfraFile)
            Should -Invoke New-AzStackHciExtension -Times 1 -Exactly -ParameterFilter { -not $ExtensionParameterEnableAutomaticUpgrade }
        }

        It 'works in the subscription of the file and puts the original subscription back' {
            $null = Invoke-Agent (New-InfraFile)
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlAmaTestSub }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlAmaTestHome }
        }

        It 'installs nothing per machine and creates no rule, association or workspace' {
            $text = Get-Content -LiteralPath $script:Script -Raw
            $text | Should -Not -Match 'New-AzConnectedMachineExtension|Get-AzConnectedMachine|MicrosoftMonitoringAgent|OmsAgent|New-AzDataCollectionRule|New-AzOperationalInsights'
        }
    }

    Context 'the extension already exists (idempotent)' {
        It 'installs nothing and says so' {
            Mock Get-AzStackHciExtension { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Succeeded' } }
            $r = Invoke-Agent (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'AlreadyExists'
            $r.Result.Detail | Should -BeNullOrEmpty
            Should -Invoke New-AzStackHciExtension -Times 0 -Exactly
            $r.Text | Should -Match 'nothing changed'
        }

        It 'reports an extension that is not Succeeded, and changes nothing' {
            Mock Get-AzStackHciExtension { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Failed' } }
            $r = Invoke-Agent (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Detail | Should -Match 'provisioning state is Failed'
            Should -Invoke New-AzStackHciExtension -Times 0 -Exactly
        }
    }

    Context 'monitoring is switched off in the file' {
        It 'does nothing and exits 0, without touching Azure' {
            $r = Invoke-Agent (New-InfraFile -Monitoring (New-Monitoring @{ enabled = $false }))
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'enabled is false'
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzStackHciExtension -Times 0 -Exactly
        }
    }

    Context '-WhatIf' {
        It 'plans the installation and installs nothing' {
            $r = Invoke-Agent (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzStackHciExtension -Times 0 -Exactly
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'ama.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>&1
            (Get-Content -LiteralPath $log -Raw) | Should -Match 'would be installed'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without operations.monitoring' {
            $r = Invoke-Agent (New-InfraFile -Monitoring $null)
            $r.ExitCode | Should -Be 2
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Agent (New-InfraFile -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses a missing azure.resource_group' {
            $r = Invoke-Agent (New-InfraFile -Group '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.resource_group'
        }

        It 'refuses a missing cluster.name' {
            $r = Invoke-Agent (New-InfraFile -Cluster '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'cluster.name'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a missing or placeholder subscription id' {
            (Invoke-Agent (New-InfraFile -SubscriptionId $null)).ExitCode | Should -Be 2
            (Invoke-Agent (New-InfraFile -SubscriptionId ([guid]::Empty.ToString()))).ExitCode | Should -Be 2
            Should -Invoke New-AzStackHciExtension -Times 0 -Exactly
        }

        It 'refuses a file that does not exist' {
            $global:LASTEXITCODE = $null
            $null = & $script:Script -InfrastructureFile (Join-Path $TestDrive 'nope.yml') 6>&1 3>&1 2>&1
            $LASTEXITCODE | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Agent (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzStackHciExtension -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Agent (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Sign in to the right tenant'
            Should -Invoke Set-AzContext -Times 0 -Exactly
        }

        It 'stops when the instance does not exist, and installs nothing' {
            Mock Get-AzStackHciCluster { throw 'The Resource ''Microsoft.AzureStackHCI/clusters/x'' under resource group was not found.' }
            $r = Invoke-Agent (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'does not exist'
            Should -Invoke New-AzStackHciExtension -Times 0 -Exactly
        }

        It 'does not hide an extension lookup error that is not a not-found' {
            Mock Get-AzStackHciExtension { throw 'AuthorizationFailed: the client has no permission' }
            $r = Invoke-Agent (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Detail | Should -Match 'AuthorizationFailed'
            Should -Invoke New-AzStackHciExtension -Times 0 -Exactly
        }

        It 'reports a failed installation, puts the subscription back, and exits 1' {
            Mock New-AzStackHciExtension { throw 'Conflict: the extension could not be installed' }
            $r = Invoke-Agent (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Detail | Should -Match 'Conflict'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlAmaTestHome }
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, never variables.yml, and holds no GUID or address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Install_AzureMonitorAgent_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'cluster.name', 'operations.monitoring.enabled') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
        }
    }
}
