#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 02 (monitoring and observability), task 04: Deploy-ActionGroup.ps1 creates the action group that operations.monitoring.action_group names, with an email receiver
# for each address of operations.notifications.emails and operations.monitoring.alert_email. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. The
# addresses use the reserved example.test domain.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ActionGroup.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-02-monitoring-observability', 'task-04-setup-alerting', 'powershell', 'Deploy-ActionGroup.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzActionGroup { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function New-AzActionGroup { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$GroupShortName, [object[]]$EmailReceiver, [bool]$Enabled, [hashtable]$Tag) }
    function Update-AzActionGroup { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [object[]]$EmailReceiver) }
    function New-AzActionGroupEmailReceiverObject { [CmdletBinding()] param([string]$EmailAddress, [string]$Name) }

    $global:AzlAgTestTenant = [guid]::NewGuid().ToString()
    $global:AzlAgTestSub = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object]$Monitoring = (New-Monitoring), [object]$Emails = @('noc@example.test', 'ops@example.test'), [object]$TenantId = $global:AzlAgTestTenant, [object]$SubscriptionId = $global:AzlAgTestSub, [object]$Tags = $null)
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $SubscriptionId) { $doc.azure.subscription_id = $SubscriptionId }
        if ($Tags) { $doc.tags = $Tags }
        $ops = [ordered]@{}
        if ($null -ne $Monitoring) { $ops.monitoring = $Monitoring }
        if ($null -ne $Emails) { $ops.notifications = [ordered]@{ emails = @($Emails) } }
        $doc.operations = $ops
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Monitoring([hashtable]$Override = @{}) {
        $m = [ordered]@{ enabled = $true; log_analytics_workspace = 'log-azl-01'; workspace_resource_group = 'rg-mgmt-01'; action_group = 'ag-azl-01' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $m.Remove($k) } else { $m[$k] = $Override[$k] } }
        $m
    }
    function New-Receiver([string]$Address) { [pscustomobject]@{ EmailAddress = $Address; Name = "r-$Address" } }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Group([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['ActionGroup'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Deploy-ActionGroup.ps1' {
    AfterAll {
        Remove-Variable -Name AzlAgTestTenant, AzlAgTestSub -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlAgTestTenant } } }
        Mock Get-AzActionGroup { throw 'The Resource ''microsoft.insights/actionGroups/ag-azl-01'' was not found (404 NotFound).' }
        Mock New-AzActionGroup { [pscustomobject]@{ Name = $Name } }
        Mock Update-AzActionGroup { [pscustomobject]@{ Name = $Name } }
        Mock New-AzActionGroupEmailReceiverObject { [pscustomobject]@{ EmailAddress = $EmailAddress; Name = $Name } }
    }

    Context 'creating the group (happy path)' {
        It 'creates the global group in the resource group, with one email receiver for each address' {
            $r = Invoke-Group (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Result.Action | Should -Be 'Created'
            Should -Invoke New-AzActionGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'ag-azl-01' -and $ResourceGroupName -eq 'rg-mgmt-01' -and $SubscriptionId -eq $global:AzlAgTestSub -and $Location -eq 'Global' -and $GroupShortName -eq 'agazl01' -and $Enabled -and @($EmailReceiver).Count -eq 2 }
            Should -Invoke New-AzActionGroupEmailReceiverObject -Times 2 -Exactly
            Should -Invoke New-AzActionGroupEmailReceiverObject -Times 1 -Exactly -ParameterFilter { $EmailAddress -eq 'noc@example.test' -and $Name -eq 'email-noc-example-test' }
        }

        It 'adds operations.monitoring.alert_email next to operations.notifications.emails, and joins duplicates whatever the case' {
            $file = New-InfraFile -Monitoring (New-Monitoring @{ alert_email = 'alerts@example.test' }) -Emails @('noc@example.test', 'NOC@example.test')
            $null = Invoke-Group $file
            Should -Invoke New-AzActionGroup -Times 1 -Exactly -ParameterFilter { @($EmailReceiver).Count -eq 2 }
            Should -Invoke New-AzActionGroupEmailReceiverObject -Times 1 -Exactly -ParameterFilter { $EmailAddress -eq 'alerts@example.test' }
        }

        It 'works with alert_email alone' {
            $r = Invoke-Group (New-InfraFile -Monitoring (New-Monitoring @{ alert_email = 'alerts@example.test' }) -Emails $null)
            $r.ExitCode | Should -Be 0
            Should -Invoke New-AzActionGroup -Times 1 -Exactly -ParameterFilter { @($EmailReceiver).Count -eq 1 }
        }

        It 'cuts the short name to 12 letters and digits' {
            $null = Invoke-Group (New-InfraFile -Monitoring (New-Monitoring @{ action_group = 'ag-azure-local-production-01' }))
            Should -Invoke New-AzActionGroup -Times 1 -Exactly -ParameterFilter { $GroupShortName -eq 'agazurelocal' }
        }

        It 'puts the file-level tags on the group it creates' {
            $null = Invoke-Group (New-InfraFile -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzActionGroup -Times 1 -Exactly -ParameterFilter { $Tag -and $Tag['environment'] -eq 'lab' }
        }

        It 'sends no tags when the file has none' {
            $null = Invoke-Group (New-InfraFile)
            Should -Invoke New-AzActionGroup -Times 1 -Exactly -ParameterFilter { -not $Tag }
        }

        It 'does not switch the session subscription' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'Set-AzContext'
        }

        It 'creates no alert rule and no endpoint' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'New-AzMetricAlertRuleV2|New-AzScheduledQueryRule|New-AzActivityLogAlert|New-AzDataCollectionEndpoint'
        }
    }

    Context 'the group already exists (idempotent, additive)' {
        It 'changes nothing when it has every listed address' {
            Mock Get-AzActionGroup { [pscustomobject]@{ Name = $Name; EmailReceiver = @((New-Receiver 'noc@example.test'), (New-Receiver 'OPS@example.test')) } }
            $r = Invoke-Group (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'AlreadyExists'
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
            Should -Invoke Update-AzActionGroup -Times 0 -Exactly
            $r.Text | Should -Match 'nothing changed'
        }

        It 'adds the address the group lacks and keeps the receivers it has' {
            $keep = New-Receiver 'noc@example.test'
            Mock Get-AzActionGroup { [pscustomobject]@{ Name = $Name; EmailReceiver = @($keep) } }
            $r = Invoke-Group (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'Updated'
            $r.Result.Added | Should -Be @('ops@example.test')
            Should -Invoke Update-AzActionGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'ag-azl-01' -and $ResourceGroupName -eq 'rg-mgmt-01' -and @($EmailReceiver).Count -eq 2 -and $EmailReceiver[0].EmailAddress -eq 'noc@example.test' -and $EmailReceiver[1].EmailAddress -eq 'ops@example.test' }
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
        }

        It 'removes no receiver the file does not list' {
            Mock Get-AzActionGroup { [pscustomobject]@{ Name = $Name; EmailReceiver = @((New-Receiver 'old@example.test')) } }
            $null = Invoke-Group (New-InfraFile)
            Should -Invoke Update-AzActionGroup -Times 1 -Exactly -ParameterFilter { @($EmailReceiver | Where-Object EmailAddress -EQ 'old@example.test').Count -eq 1 -and @($EmailReceiver).Count -eq 3 }
        }

        It 'handles a group with no email receiver at all' {
            Mock Get-AzActionGroup { [pscustomobject]@{ Name = $Name; EmailReceiver = $null } }
            $r = Invoke-Group (New-InfraFile)
            $r.Result.Action | Should -Be 'Updated'
            Should -Invoke Update-AzActionGroup -Times 1 -Exactly -ParameterFilter { @($EmailReceiver).Count -eq 2 }
        }

        It 'plans the addition under -WhatIf and changes nothing' {
            Mock Get-AzActionGroup { [pscustomobject]@{ Name = $Name; EmailReceiver = @((New-Receiver 'noc@example.test')) } }
            $r = Invoke-Group (New-InfraFile) -DryRun
            $r.Result.Action | Should -Be 'WouldUpdate'
            Should -Invoke Update-AzActionGroup -Times 0 -Exactly
            $r.Text | Should -Match 'would add ops@example.test'
        }
    }

    Context 'monitoring is switched off in the file' {
        It 'does nothing and exits 0, without touching Azure' {
            $r = Invoke-Group (New-InfraFile -Monitoring (New-Monitoring @{ enabled = $false }))
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'Azure Monitor is not part of the design'
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
        }
    }

    Context '-WhatIf' {
        It 'plans the group and creates nothing' {
            $r = Invoke-Group (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'ag.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null 3>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without operations.monitoring' {
            $r = Invoke-Group (New-InfraFile -Monitoring $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'operations.monitoring is missing'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Group (New-InfraFile -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses a missing <Key>' -ForEach @(@{ Key = 'action_group' }, @{ Key = 'workspace_resource_group' }) {
            $r = Invoke-Group (New-InfraFile -Monitoring (New-Monitoring @{ $Key = $null }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match "operations.monitoring.$Key is missing"
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
        }

        It 'refuses an action group name Azure does not accept: <_>' -ForEach '-leading', 'bad/name', '!!!' {
            $r = Invoke-Group (New-InfraFile -Monitoring (New-Monitoring @{ action_group = $_ }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'not a valid action group name'
        }

        It 'refuses a missing or placeholder subscription id' {
            foreach ($sub in $null, [guid]::Empty.ToString()) {
                $r = Invoke-Group (New-InfraFile -SubscriptionId $sub)
                $r.ExitCode | Should -Be 2
                $r.Text | Should -Match 'azure.subscription_id'
            }
        }

        It 'refuses a file with no email address anywhere' {
            $r = Invoke-Group (New-InfraFile -Emails $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'No email address'
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
        }

        It 'refuses an address that is not an email address: <_>' -ForEach 'not-an-address', 'a@b', 'two@@example.test', 'a b@example.test', 'a@example.test,b@example.test' {
            $r = Invoke-Group (New-InfraFile -Emails @('noc@example.test', $_))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'is not an email address'
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Group (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Group (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Group (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzActionGroup { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Group (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Action | Should -Be 'Failed'
            Should -Invoke New-AzActionGroup -Times 0 -Exactly
        }

        It 'reports a failed creation and exits 1' {
            Mock New-AzActionGroup { throw 'AuthorizationFailed' }
            $r = Invoke-Group (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Detail | Should -Match 'AuthorizationFailed'
        }

        It 'reports a failed update and exits 1' {
            Mock Get-AzActionGroup { [pscustomobject]@{ Name = $Name; EmailReceiver = @((New-Receiver 'noc@example.test')) } }
            Mock Update-AzActionGroup { throw 'AuthorizationFailed' }
            $r = Invoke-Group (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Detail | Should -Match 'AuthorizationFailed'
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
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Deploy_ActionGroup_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist, and operations.monitoring.action_group is the one this change registered (schema 5.6.6)' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'azure.subscription_id', 'operations.monitoring.enabled', 'operations.monitoring.workspace_resource_group', 'operations.monitoring.action_group',
                'operations.monitoring.alert_email', 'operations.notifications.emails') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
            @($registry | Where-Object Path -EQ 'tags').Count | Should -BeGreaterOrEqual 1
            ($registry | Where-Object Path -EQ 'operations.monitoring.action_group').Since | Should -Be '5.6.6'
        }
    }
}
