#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 02 (monitoring and observability), task 03: Enable-HciInsights.ps1 associates the existing Insights data collection rule with the Arc machine of every node.
# It never creates or changes a rule (Learn documents no template for it). Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/HciInsights.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-02-monitoring-observability', 'task-03-enable-hci-insights', 'powershell', 'Enable-HciInsights.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzStackHciExtension { [CmdletBinding()] param([string]$ClusterName, [string]$ResourceGroupName, [string]$ArcSettingName, [string]$Name, [string]$SubscriptionId) }
    function Get-AzDataCollectionRule { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function Get-AzDataCollectionRuleAssociation { [CmdletBinding()] param([string]$TargetResourceId) }
    function New-AzDataCollectionRuleAssociation { [CmdletBinding()] param([string]$TargetResourceId, [string]$DataCollectionRuleId, [string]$AssociationName) }

    $global:AzlInsTestTenant = [guid]::NewGuid().ToString()
    $global:AzlInsTestSub = [guid]::NewGuid().ToString()
    $global:AzlInsTestHome = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object]$Monitoring = (New-Monitoring), [object]$Nodes = @(@{ name = 'iic-azl-n01' }, @{ name = 'iic-azl-n02'; arc_machine_name = 'iic-arc-n02' }), [object]$TenantId = $global:AzlInsTestTenant, [object]$SubscriptionId = $global:AzlInsTestSub,
            [string]$Group = 'rg-azl-01', [string]$Cluster = 'iic-azl-01')
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $SubscriptionId) { $doc.azure.subscription_id = $SubscriptionId }
        if ($Group) { $doc.azure.resource_group = $Group }
        if ($Cluster) { $doc.cluster = [ordered]@{ name = $Cluster } }
        if ($Nodes) { $doc.nodes = @($Nodes) }
        if ($null -ne $Monitoring) { $doc.operations = [ordered]@{ monitoring = $Monitoring } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Monitoring([hashtable]$Override = @{}) {
        $m = [ordered]@{ enabled = $true; log_analytics_workspace = 'log-azl-01'; workspace_resource_group = 'rg-mgmt-01'; data_collection_rule = 'AzureStackHCI-azl-01' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $m.Remove($k) } else { $m[$k] = $Override[$k] } }
        $m
    }

    # Runs the script and returns its exit code, its result rows and every message (information, warning, error) as text.
    function Invoke-Insights([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        $rows = @($all | Where-Object { $_.PSObject.Properties['Kind'] -and $_.PSObject.Properties['Action'] })
        [pscustomobject]@{
            ExitCode = $code
            Rows     = $rows
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Enable-HciInsights.ps1' {
    AfterAll {
        Remove-Variable -Name AzlInsTestTenant, AzlInsTestSub, AzlInsTestHome -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlInsTestTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlInsTestHome } } }
        Mock Set-AzContext { }
        Mock Get-AzStackHciExtension { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Succeeded' } }
        Mock Get-AzDataCollectionRule { [pscustomobject]@{ Name = $Name; Location = 'westus2'; Id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$Name" } }
        Mock Get-AzDataCollectionRuleAssociation { @() }
        Mock New-AzDataCollectionRuleAssociation { [pscustomobject]@{ Name = $AssociationName } }
    }

    Context 'associating the existing rule (happy path)' {
        It 'looks the rule up in the monitoring resource group and the subscription of the file' {
            $r = Invoke-Insights (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke Get-AzDataCollectionRule -Times 1 -Exactly -ParameterFilter { $Name -eq 'AzureStackHCI-azl-01' -and $ResourceGroupName -eq 'rg-mgmt-01' -and $SubscriptionId -eq $global:AzlInsTestSub }
        }

        It 'associates the rule with the Arc machine of every node, using arc_machine_name where the node has one' {
            $r = Invoke-Insights (New-InfraFile)
            $r.Rows.Count | Should -Be 2
            $r.Rows.Action | Should -Not -Contain 'Failed'
            $rule = "/subscriptions/$($global:AzlInsTestSub)/resourceGroups/rg-mgmt-01/providers/Microsoft.Insights/dataCollectionRules/AzureStackHCI-azl-01"
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 1 -Exactly -ParameterFilter {
                $TargetResourceId -eq "/subscriptions/$($global:AzlInsTestSub)/resourceGroups/rg-azl-01/providers/Microsoft.HybridCompute/machines/iic-azl-n01" -and $DataCollectionRuleId -eq $rule -and $AssociationName -eq 'iic-azl-n01-dataCollectionRuleAssociations'
            }
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 1 -Exactly -ParameterFilter {
                $TargetResourceId -like '*/machines/iic-arc-n02' -and $AssociationName -eq 'iic-arc-n02-dataCollectionRuleAssociations'
            }
        }

        It 'works in the subscription of the file and puts the original subscription back' {
            $null = Invoke-Insights (New-InfraFile)
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlInsTestSub }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlInsTestHome }
        }
    }

    Context 'the rule does not exist (one portal step remains)' {
        It 'stops with exit 1, names the portal step and the Learn page, and creates nothing' {
            Mock Get-AzDataCollectionRule { throw 'The Resource ''Microsoft.Insights/dataCollectionRules/x'' was not found (404 NotFound).' }
            $r = Invoke-Insights (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'enable Insights once'
            $r.Text | Should -Match 'Azure portal'
            $r.Text | Should -Match 'Monitor a single Azure Local system with Insights'
            $r.Text | Should -Match 'AzureStackHCI-azl-01'
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
            Should -Invoke Get-AzDataCollectionRuleAssociation -Times 0 -Exactly
        }

        It 'stops with exit 1 when the lookup returns nothing' {
            Mock Get-AzDataCollectionRule { $null }
            (Invoke-Insights (New-InfraFile)).ExitCode | Should -Be 1
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
        }
    }

    Context 'the associations already exist (idempotent)' {
        It 'creates nothing and says so' {
            Mock Get-AzDataCollectionRuleAssociation { [pscustomobject]@{ Name = 'x'; DataCollectionRuleId = "/subscriptions/$($global:AzlInsTestSub)/resourcegroups/rg-mgmt-01/providers/microsoft.insights/datacollectionrules/azurestackhci-azl-01" } }
            $r = Invoke-Insights (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action | Select-Object -Unique) | Should -Be 'AlreadyExists'
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
        }

        It 'never re-points an association with the right name that belongs to another rule' {
            Mock Get-AzDataCollectionRuleAssociation { [pscustomobject]@{ Name = 'iic-azl-n01-dataCollectionRuleAssociations'; DataCollectionRuleId = "/subscriptions/$($global:AzlInsTestSub)/resourceGroups/rg-other/providers/Microsoft.Insights/dataCollectionRules/another" } } -ParameterFilter { $TargetResourceId -like '*iic-azl-n01' }
            $r = Invoke-Insights (New-InfraFile)
            $r.ExitCode | Should -Be 0
            ($r.Rows | Where-Object Name -EQ 'iic-azl-n01').Detail | Should -Match 'points to another rule'
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly -ParameterFilter { $TargetResourceId -like '*iic-azl-n01' }
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 1 -Exactly -ParameterFilter { $TargetResourceId -like '*iic-arc-n02' }
        }
    }

    Context 'monitoring is switched off in the file' {
        It 'does nothing and exits 0, without touching Azure' {
            $r = Invoke-Insights (New-InfraFile -Monitoring (New-Monitoring @{ enabled = $false }))
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'enabled is false'
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
        }
    }

    Context '-WhatIf' {
        It 'plans the associations and creates nothing' {
            $r = Invoke-Insights (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            @($r.Rows.Action | Select-Object -Unique) | Should -Be 'WouldCreate'
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'insights.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>&1
            (Get-Content -LiteralPath $log -Raw) | Should -Match 'would be associated'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without operations.monitoring' {
            $r = Invoke-Insights (New-InfraFile -Monitoring $null)
            $r.ExitCode | Should -Be 2
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a missing <Key>' -ForEach @(
            @{ Key = 'workspace_resource_group' }, @{ Key = 'data_collection_rule' }
        ) {
            $r = Invoke-Insights (New-InfraFile -Monitoring (New-Monitoring @{ $Key = $null }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match $Key
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a rule name Azure does not accept: <_>' -ForEach 'bad name!', '-leading', ('d' * 65) {
            (Invoke-Insights (New-InfraFile -Monitoring (New-Monitoring @{ data_collection_rule = $_ }))).ExitCode | Should -Be 2
        }

        It 'refuses a file with no node' {
            $r = Invoke-Insights (New-InfraFile -Nodes $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'nodes\[\]'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id, azure.resource_group, cluster.name or subscription id' {
            (Invoke-Insights (New-InfraFile -TenantId $null)).ExitCode | Should -Be 2
            (Invoke-Insights (New-InfraFile -Group '')).ExitCode | Should -Be 2
            (Invoke-Insights (New-InfraFile -Cluster '')).ExitCode | Should -Be 2
            (Invoke-Insights (New-InfraFile -SubscriptionId ([guid]::Empty.ToString()))).ExitCode | Should -Be 2
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
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
            $r = Invoke-Insights (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Insights (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Should -Invoke Set-AzContext -Times 0 -Exactly
        }

        It 'stops when the Azure Monitor Agent is not on the instance, and associates nothing' {
            Mock Get-AzStackHciExtension { throw 'The Resource ''Microsoft.AzureStackHCI/clusters/x/arcSettings/default/extensions/AzureMonitorWindowsAgent'' was not found (404 NotFound).' }
            $r = Invoke-Insights (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Install-AzureMonitorAgent.ps1'
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
        }

        It 'does not hide a rule lookup error that is not a not-found' {
            Mock Get-AzDataCollectionRule { throw 'AuthorizationFailed: no permission' }
            $r = Invoke-Insights (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'AuthorizationFailed'
            Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
        }

        It 'reports a failed association, goes on with the other node, puts the subscription back, and exits 1' {
            Mock New-AzDataCollectionRuleAssociation { throw 'NotFound: the machine does not exist' } -ParameterFilter { $TargetResourceId -like '*iic-azl-n01' }
            $r = Invoke-Insights (New-InfraFile)
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Name -EQ 'iic-azl-n01').Action | Should -Be 'Failed'
            ($r.Rows | Where-Object Name -EQ 'iic-arc-n02').Action | Should -Be 'Created'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlInsTestHome }
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

        It 'never creates or changes a rule and carries no stream, counter or event list' {
            $script:Text | Should -Not -Match 'New-AzDataCollectionRule\b|Set-AzDataCollectionRule|Update-AzDataCollectionRule|Remove-AzDataCollectionRule|New-AzDataFlowObject|New-AzPerfCounter|New-AzWindowsEventLog|Microsoft-Perf|Microsoft-Event|RDMA|SamplingFrequency'
        }

        It 'does nothing outside Learn: no workbook, no solution, no legacy agent, no syslog, no Sentinel, no Linux, no cluster remoting, no Key Vault' {
            $script:Text | Should -Not -Match '(?i)workbook|IntelligencePack|MicrosoftMonitoringAgent|OmsAgent|Syslog|Sentinel|Invoke-Command|Get-ClusterNode|KeyVault|New-AzConnectedMachineExtension|New-AzScheduledQueryRule'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Enable_HciInsights_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist, and the removed keys are gone' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'cluster.name', 'operations.monitoring.enabled',
                'operations.monitoring.workspace_resource_group', 'operations.monitoring.data_collection_rule') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
            @($registry | Where-Object Path -EQ 'nodes[].arc_machine_name').Count | Should -Be 1
            foreach ($key in 'operations.monitoring.performance_counter_sampling_seconds', 'operations.monitoring.health_alerts', 'operations.monitoring.health_alert_processing_rule', 'operations.notifications.teams_webhook') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 0 -Because "$key was removed"
            }
        }
    }
}
