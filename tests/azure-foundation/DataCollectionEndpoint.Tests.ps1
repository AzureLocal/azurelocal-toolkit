#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 02 (monitoring and observability), task 01: Deploy-DataCollectionEndpoint.ps1 creates the data collection endpoint that operations.monitoring names, in the region of
# the Log Analytics workspace. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/DataCollectionEndpoint.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-02-monitoring-observability', 'task-01-configure-log-analytics-workspace', 'powershell', 'Deploy-DataCollectionEndpoint.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzOperationalInsightsWorkspace { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzDataCollectionEndpoint { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function New-AzDataCollectionEndpoint { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$NetworkAclsPublicNetworkAccess, [hashtable]$Tag) }

    $global:AzlDceTestTenant = [guid]::NewGuid().ToString()
    $global:AzlDceTestSub = [guid]::NewGuid().ToString()
    $global:AzlDceTestHome = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object]$Monitoring = (New-Monitoring), [object]$TenantId = $global:AzlDceTestTenant, [object]$SubscriptionId = $global:AzlDceTestSub, [string]$Location = 'eastus', [object]$Tags = $null)
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $SubscriptionId) { $doc.azure.subscription_id = $SubscriptionId }
        if ($Location) { $doc.azure.location = $Location }
        if ($Tags) { $doc.tags = $Tags }
        if ($null -ne $Monitoring) { $doc.operations = [ordered]@{ monitoring = $Monitoring } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Monitoring([hashtable]$Override = @{}) {
        $m = [ordered]@{ enabled = $true; log_analytics_workspace = 'log-azl-01'; workspace_resource_group = 'rg-mgmt-01'; data_collection_endpoint = 'dce-azl-01' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $m.Remove($k) } else { $m[$k] = $Override[$k] } }
        $m
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Endpoint([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['Endpoint'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Deploy-DataCollectionEndpoint.ps1' {
    AfterAll {
        Remove-Variable -Name AzlDceTestTenant, AzlDceTestSub, AzlDceTestHome -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlDceTestTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlDceTestHome } } }
        Mock Set-AzContext { }
        Mock Get-AzOperationalInsightsWorkspace { [pscustomobject]@{ Name = $Name; Location = 'westus2' } }
        Mock Get-AzDataCollectionEndpoint { throw 'The Resource ''Microsoft.Insights/dataCollectionEndpoints/x'' was not found (404 NotFound).' }
        Mock New-AzDataCollectionEndpoint { [pscustomobject]@{ Name = $Name } }
    }

    Context 'creating the endpoint (happy path)' {
        It 'creates the endpoint in the resource group and in the region of the workspace, and leaves the network access at the Azure default' {
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Result.Action | Should -Be 'Created'
            $r.Result.Location | Should -Be 'westus2'
            Should -Invoke New-AzDataCollectionEndpoint -Times 1 -Exactly -ParameterFilter { $Name -eq 'dce-azl-01' -and $ResourceGroupName -eq 'rg-mgmt-01' -and $SubscriptionId -eq $global:AzlDceTestSub -and $Location -eq 'westus2' -and -not $NetworkAclsPublicNetworkAccess }
        }

        It 'looks the workspace up in the resource group and the subscription of the file, and puts the original subscription back' {
            $null = Invoke-Endpoint (New-InfraFile)
            Should -Invoke Get-AzOperationalInsightsWorkspace -Times 1 -Exactly -ParameterFilter { $Name -eq 'log-azl-01' -and $ResourceGroupName -eq 'rg-mgmt-01' }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlDceTestSub }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlDceTestHome }
        }

        It 'uses azure.location when the workspace reports no region' {
            Mock Get-AzOperationalInsightsWorkspace { [pscustomobject]@{ Name = $Name } }
            $null = Invoke-Endpoint (New-InfraFile -Location 'centralus')
            Should -Invoke New-AzDataCollectionEndpoint -Times 1 -Exactly -ParameterFilter { $Location -eq 'centralus' }
        }

        It 'puts the file-level tags on the endpoint' {
            $null = Invoke-Endpoint (New-InfraFile -Tags ([ordered]@{ environment = 'lab'; owner = 'team' }))
            Should -Invoke New-AzDataCollectionEndpoint -Times 1 -Exactly -ParameterFilter { $Tag -and $Tag['environment'] -eq 'lab' }
        }

        It 'sends no tags when the file has none' {
            $null = Invoke-Endpoint (New-InfraFile)
            Should -Invoke New-AzDataCollectionEndpoint -Times 1 -Exactly -ParameterFilter { -not $Tag }
        }

        It 'creates only the endpoint: no workspace, no rule, no association, no action group' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'New-AzOperationalInsightsWorkspace|New-AzDataCollectionRule|New-AzDataCollectionRuleAssociation|New-AzActionGroup|Set-AzActionGroup'
        }
    }

    Context 'the endpoint already exists (idempotent)' {
        It 'creates nothing and says so' {
            Mock Get-AzDataCollectionEndpoint { [pscustomobject]@{ Name = $Name; Location = 'westus2' } }
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'AlreadyExists'
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
            $r.Text | Should -Match 'nothing changed'
        }

        It 'reports an endpoint in another region than the workspace, and changes nothing' {
            Mock Get-AzDataCollectionEndpoint { [pscustomobject]@{ Name = $Name; Location = 'eastus' } }
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Detail | Should -Match 'the endpoint is in eastus, the workspace in westus2'
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
        }

        It 'compares regions without regard to case or spaces' {
            Mock Get-AzDataCollectionEndpoint { [pscustomobject]@{ Name = $Name; Location = 'West US 2' } }
            (Invoke-Endpoint (New-InfraFile)).Result.Detail | Should -BeNullOrEmpty
        }
    }

    Context 'monitoring is switched off in the file' {
        It 'does nothing and exits 0, without touching Azure' {
            $r = Invoke-Endpoint (New-InfraFile -Monitoring (New-Monitoring @{ enabled = $false }))
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'Azure Monitor is not part of the design'
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
        }
    }

    Context '-WhatIf' {
        It 'plans the endpoint and creates nothing' {
            $r = Invoke-Endpoint (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'dce.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null 3>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without operations.monitoring' {
            $r = Invoke-Endpoint (New-InfraFile -Monitoring $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'operations.monitoring is missing'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Endpoint (New-InfraFile -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses a missing <Key>' -ForEach @(
            @{ Key = 'log_analytics_workspace' }, @{ Key = 'workspace_resource_group' }, @{ Key = 'data_collection_endpoint' }
        ) {
            $r = Invoke-Endpoint (New-InfraFile -Monitoring (New-Monitoring @{ $Key = $null }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match "operations.monitoring.$Key is missing"
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
        }

        It 'refuses an endpoint name Azure does not accept: <_>' -ForEach 'bad name!', '-leading', ('d' * 65) {
            $r = Invoke-Endpoint (New-InfraFile -Monitoring (New-Monitoring @{ data_collection_endpoint = $_ }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'not a valid name'
        }

        It 'refuses a missing or placeholder subscription id' {
            foreach ($sub in $null, [guid]::Empty.ToString()) {
                $r = Invoke-Endpoint (New-InfraFile -SubscriptionId $sub)
                $r.ExitCode | Should -Be 2
                $r.Text | Should -Match 'azure.subscription_id'
            }
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Endpoint (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke Set-AzContext -Times 0 -Exactly
        }

        It 'stops when the workspace does not exist, and creates nothing' {
            Mock Get-AzOperationalInsightsWorkspace { throw 'The Resource ''Microsoft.OperationalInsights/workspaces/log-azl-01'' was not found (ResourceNotFound).' }
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'does not exist'
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
        }

        It 'stops when the workspace lookup returns nothing' {
            Mock Get-AzOperationalInsightsWorkspace { $null }
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
        }

        It 'does not hide a workspace lookup error that is not a not-found' {
            Mock Get-AzOperationalInsightsWorkspace { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
        }

        It 'does not hide an endpoint lookup error that is not a not-found' {
            Mock Get-AzDataCollectionEndpoint { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Action | Should -Be 'Failed'
            Should -Invoke New-AzDataCollectionEndpoint -Times 0 -Exactly
        }

        It 'reports a failed creation, puts the subscription back, and exits 1' {
            Mock New-AzDataCollectionEndpoint { throw 'AuthorizationFailed' }
            $r = Invoke-Endpoint (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Detail | Should -Match 'AuthorizationFailed'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlDceTestHome }
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
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Deploy_DataCollectionEndpoint_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'azure.subscription_id', 'azure.location', 'operations.monitoring.enabled', 'operations.monitoring.log_analytics_workspace',
                'operations.monitoring.workspace_resource_group', 'operations.monitoring.data_collection_endpoint') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
            @($registry | Where-Object Path -EQ 'tags').Count | Should -BeGreaterOrEqual 1
        }
    }
}
