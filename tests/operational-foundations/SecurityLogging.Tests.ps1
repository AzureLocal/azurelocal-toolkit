#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Operational foundations, phase 04, task 04: Invoke-SecurityLogging-Orchestrated.ps1 creates the data collection rule of operations.security_logging
# and associates it with every node. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/operational-foundations/SecurityLogging.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-04-security-governance', 'task-04-enable-security-logging', 'powershell', 'Invoke-SecurityLogging-Orchestrated.ps1')
    Import-Module powershell-yaml
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzOperationalInsightsWorkspace { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzStackHciExtension { [CmdletBinding()] param([string]$ClusterName, [string]$ResourceGroupName, [string]$ArcSettingName, [string]$Name, [string]$SubscriptionId) }
    function Get-AzDataCollectionRule { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function New-AzDataCollectionRule { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$JsonString) }
    function Get-AzDataCollectionRuleAssociation { [CmdletBinding()] param([string]$TargetResourceId) }
    function New-AzDataCollectionRuleAssociation { [CmdletBinding()] param([string]$TargetResourceId, [string]$DataCollectionRuleId, [string]$AssociationName) }

    $global:AzlSlTenant = [guid]::NewGuid().ToString()
    $global:AzlSlSub = [guid]::NewGuid().ToString()
    $global:AzlSlWorkspaceId = "/subscriptions/$($global:AzlSlSub)/resourceGroups/rg-iic-mgmt-01/providers/Microsoft.OperationalInsights/workspaces/log-iic-azl-01"

    function New-InfraFile([object]$Enabled = $true, [object]$Audit = $null, [object[]]$Levels = $null, [object]$Monitoring = $true, [string]$Rule = 'dcr-iic-azl-01-security') {
        $sl = [ordered]@{ enabled = $Enabled; data_collection_rule = $Rule }
        if ($null -ne $Audit) { $sl.security_audit = $Audit }
        if ($null -ne $Levels) { $sl.event_levels = @($Levels) }
        $doc = [ordered]@{
            azure      = [ordered]@{ tenant_id = $global:AzlSlTenant; subscription_id = $global:AzlSlSub; resource_group = 'rg-iic-azl-01' }
            cluster    = [ordered]@{ name = 'iic-azl-01' }
            nodes      = @(1, 2 | ForEach-Object { [ordered]@{ name = "iic-n0$_" } })
            tags       = [ordered]@{ Environment = 'test' }
            operations = [ordered]@{ monitoring = [ordered]@{ enabled = $Monitoring; log_analytics_workspace = 'log-iic-azl-01'; workspace_resource_group = 'rg-iic-mgmt-01' }; security_logging = $sl }
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Sl([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Rows = @($all | Where-Object { $_.PSObject.Properties['Kind'] -and $_.PSObject.Properties['Action'] }); Text = (@($all | ForEach-Object { "$_" }) -join "`n") }
    }
}

Describe 'Invoke-SecurityLogging-Orchestrated.ps1' {
    AfterAll { Remove-Variable -Name AzlSlTenant, AzlSlSub, AzlSlWorkspaceId, AzlSlRule, AzlSlBody, AzlSlAssoc -Scope Global -ErrorAction SilentlyContinue }
    BeforeEach {
        $global:AzlSlRule = $null; $global:AzlSlBody = $null
        $global:AzlSlAssoc = @{}
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlSlTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlSlSub } } }
        Mock Set-AzContext { }
        Mock Get-AzOperationalInsightsWorkspace { [pscustomobject]@{ Name = $Name; Location = 'westeurope'; ResourceId = $global:AzlSlWorkspaceId } }
        Mock Get-AzStackHciExtension { [pscustomobject]@{ Name = $Name } }
        Mock Get-AzDataCollectionRule { if ($global:AzlSlRule) { $global:AzlSlRule } else { throw "ResourceNotFound: $Name was not found" } }
        Mock New-AzDataCollectionRule { $global:AzlSlBody = $JsonString | ConvertFrom-Json; [pscustomobject]@{ Id = "/subscriptions/x/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$Name" } }
        Mock Get-AzDataCollectionRuleAssociation { @($global:AzlSlAssoc[$TargetResourceId]) | Where-Object { $_ } }
        Mock New-AzDataCollectionRuleAssociation { $global:AzlSlAssoc[$TargetResourceId] = [pscustomobject]@{ Name = $AssociationName; DataCollectionRuleId = $DataCollectionRuleId } }
    }

    It 'creates the rule with the default queries and associates every node' {
        $r = Invoke-Sl (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        ($r.Rows | Where-Object Kind -EQ 'Rule').Action | Should -Be 'Created'
        @($r.Rows | Where-Object Kind -EQ 'Association' | ForEach-Object Action) | Should -Be @('Created', 'Created')
        $global:AzlSlBody.location | Should -Be 'westeurope'
        $global:AzlSlBody.kind | Should -Be 'Windows'
        $q = @($global:AzlSlBody.properties.dataSources.windowsEventLogs[0].xPathQueries)
        $q | Should -Contain 'Security!*[System[(band(Keywords,13510798882111488))]]'
        $q | Should -Contain 'System!*[System[(Level=1 or Level=2 or Level=3)]]'
        $q | Should -Contain 'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
        $global:AzlSlBody.properties.destinations.logAnalytics[0].workspaceResourceId | Should -Be $global:AzlSlWorkspaceId
        @($global:AzlSlBody.properties.dataFlows[0].streams) | Should -Be @('Microsoft-Event')
        Should -Invoke New-AzDataCollectionRuleAssociation -Times 1 -Exactly -ParameterFilter { $AssociationName -eq 'iic-n01-dcr-iic-azl-01-security' -and $TargetResourceId -match 'Microsoft.HybridCompute/machines/iic-n01$' }
    }

    It 'collects audit failures only and the levels of the file' {
        $null = Invoke-Sl (New-InfraFile -Audit 'failure' -Levels @('critical', 'information'))
        $q = @($global:AzlSlBody.properties.dataSources.windowsEventLogs[0].xPathQueries)
        $q | Should -Contain 'Security!*[System[(band(Keywords,4503599627370496))]]'
        $q | Should -Contain 'System!*[System[(Level=1 or Level=4 or Level=0)]]'
    }

    It 'is idempotent: a rule as the file says and existing associations are left alone' {
        $null = Invoke-Sl (New-InfraFile)
        $global:AzlSlRule = [pscustomobject]@{
            Id                        = "/subscriptions/x/resourceGroups/rg-iic-mgmt-01/providers/Microsoft.Insights/dataCollectionRules/dcr-iic-azl-01-security"
            DataSourceWindowsEventLog = @([pscustomobject]@{ XPathQuery = @($global:AzlSlBody.properties.dataSources.windowsEventLogs[0].xPathQueries) })
            DestinationLogAnalytic    = @([pscustomobject]@{ WorkspaceResourceId = $global:AzlSlWorkspaceId })
        }
        $r = Invoke-Sl (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows.Action | Sort-Object -Unique) | Should -Be @('AlreadyExists')
        Should -Invoke New-AzDataCollectionRule -Times 1 -Exactly
        Should -Invoke New-AzDataCollectionRuleAssociation -Times 2 -Exactly
    }

    It 'fails, and associates no node, when an existing rule collects other queries' {
        $global:AzlSlRule = [pscustomobject]@{ Id = 'r'; DataSourceWindowsEventLog = @([pscustomobject]@{ XPathQuery = @('Security!*') }); DestinationLogAnalytic = @([pscustomobject]@{ WorkspaceResourceId = $global:AzlSlWorkspaceId }) }
        $r = Invoke-Sl (New-InfraFile)
        $r.ExitCode | Should -Be 1
        Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
    }

    It 'reports a conflicting association of the same name' {
        $id = "/subscriptions/$($global:AzlSlSub)/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/iic-n01"
        $global:AzlSlAssoc[$id] = [pscustomobject]@{ Name = 'iic-n01-dcr-iic-azl-01-security'; DataCollectionRuleId = 'other' }
        $r = Invoke-Sl (New-InfraFile)
        $r.ExitCode | Should -Be 1
        ($r.Rows | Where-Object Name -EQ 'iic-n01').Action | Should -Be 'Conflict'
    }

    It 'plans under -WhatIf' {
        $r = Invoke-Sl (New-InfraFile) -DryRun
        $r.ExitCode | Should -Be 0
        @($r.Rows.Action | Sort-Object -Unique) | Should -Be @('WouldCreate')
        Should -Invoke New-AzDataCollectionRule -Times 0 -Exactly
        Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
    }

    It 'does nothing when not enabled' {
        (Invoke-Sl (New-InfraFile -Enabled $false)).ExitCode | Should -Be 0
        Should -Invoke Get-AzContext -Times 0 -Exactly
    }

    It 'refuses when Azure Monitor is off, or a level is unknown (exit 2, nothing sent)' {
        (Invoke-Sl (New-InfraFile -Monitoring $false)).ExitCode | Should -Be 2
        (Invoke-Sl (New-InfraFile -Levels @('loud'))).ExitCode | Should -Be 2
        Should -Invoke Get-AzContext -Times 0 -Exactly
    }

    It 'fails when the agent is not on the instance' {
        Mock Get-AzStackHciExtension { throw 'ResourceNotFound: not found' }
        $r = Invoke-Sl (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Install-AzureMonitorAgent'
    }
}
