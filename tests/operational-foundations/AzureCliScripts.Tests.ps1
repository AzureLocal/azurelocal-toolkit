#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Azure CLI scripts of the operational foundations (stage 05, phases 01, 02, 04 and 05) and of the security validation (stage 06, task 05) (K6 batch 4).
# Each script takes its values from infrastructure.yml and calls only az. The az command is replaced by a fake: no Azure, no tenant, no sign-in and no
# subscription is used. Ids are generated per run. No script is run against a real Azure.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/operational-foundations/AzureCliScripts.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters and Pester blocks.')]
param()

BeforeDiscovery {
    $deploy = [IO.Path]::Combine([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..')), 'scripts', 'deploy')
    function Get-CliPath([string]$Task, [string]$Name) { [IO.Path]::Combine($deploy, $Task.Replace('/', [IO.Path]::DirectorySeparatorChar), 'azurecli', $Name) }
    $of = '05-operational-foundations'
    $script:Cases = @(
        @{ Name = 'Set-NetworkSecurityGroupRule'; Path = (Get-CliPath "$of/phase-01-sdn-deployment/task-02-configure-network-security-groups" 'Set-NetworkSecurityGroupRule.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Test-NetworkSecurityGroupRule'; Path = (Get-CliPath "$of/phase-01-sdn-deployment/task-03-configure-network-security-groups" 'Test-NetworkSecurityGroupRule.azcli.ps1'); Changes = $false; Subscription = $true }
        @{ Name = 'Deploy-LogAnalyticsWorkspace'; Path = (Get-CliPath "$of/phase-02-monitoring-observability/task-01-configure-log-analytics-workspace" 'Deploy-LogAnalyticsWorkspace.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Deploy-DataCollectionEndpoint'; Path = (Get-CliPath "$of/phase-02-monitoring-observability/task-01-configure-log-analytics-workspace" 'Deploy-DataCollectionEndpoint.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Install-AzureMonitorAgent'; Path = (Get-CliPath "$of/phase-02-monitoring-observability/task-02-configure-azure-monitor-agent" 'Install-AzureMonitorAgent.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Enable-HciInsights'; Path = (Get-CliPath "$of/phase-02-monitoring-observability/task-03-enable-hci-insights" 'Enable-HciInsights.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Deploy-ActionGroup'; Path = (Get-CliPath "$of/phase-02-monitoring-observability/task-04-setup-alerting" 'Deploy-ActionGroup.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Enable-DefenderForCloud'; Path = (Get-CliPath "$of/phase-04-security-governance/task-01-enable-defender-for-cloud" 'Enable-DefenderForCloud.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Invoke-AzurePolicyTier1-Orchestrated'; Path = (Get-CliPath "$of/phase-04-security-governance/task-02-apply-azure-policy-initiatives" 'Invoke-AzurePolicyTier1-Orchestrated.azcli.ps1'); Changes = $true; Subscription = $false }
        @{ Name = 'Enable-AzureHybridBenefit'; Path = (Get-CliPath "$of/phase-05-licensing-telemetry/task-01-enable-azure-hybrid-benefit" 'Enable-AzureHybridBenefit.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Enable-WindowsServerSubscription'; Path = (Get-CliPath "$of/phase-05-licensing-telemetry/task-02-activate-windows-server-subscription" 'Enable-WindowsServerSubscription.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Invoke-TelemetryConfiguration-Orchestrated'; Path = (Get-CliPath "$of/phase-05-licensing-telemetry/task-03-configure-enhanced-telemetry" 'Invoke-TelemetryConfiguration-Orchestrated.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Invoke-SecurityLogging-Orchestrated'; Path = (Get-CliPath "$of/phase-04-security-governance/task-04-enable-security-logging" 'Invoke-SecurityLogging-Orchestrated.azcli.ps1'); Changes = $true; Subscription = $true }
        @{ Name = 'Test-SecurityCompliance'; Path = (Get-CliPath '06-testing-validation/task-05-security-compliance-validation' 'Test-SecurityCompliance.azcli.ps1'); Changes = $false; Subscription = $true }
    )
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Repo = $repo
    # az rest counts as a change unless it is a GET: the Tier 1 policy assignment is a PUT, the reads of the inherited policy assignments
    # (Enable-DefenderForCloud, Test-SecurityCompliance) are GETs.
    $script:ChangeCommand = '(create|update|delete|register|extend-software-assurance-benefit)$|^rest$'
    $script:IsChange = { param($Call) if ($Call.Command -eq 'rest') { return ([string]@($Call.Options['--method'])[0]) -ine 'get' }; $Call.Command -match $script:ChangeCommand }
    Import-Module powershell-yaml
    # A stub with the name of the command, so the mock works whether or not the Azure CLI is installed.
    function az { }

    $global:K6Tenant = [guid]::NewGuid().ToString()
    $global:K6Sub = [guid]::NewGuid().ToString()

    function New-K6Error([string]$Message, [int]$Code = 1) {
        $global:LASTEXITCODE = $Code
        [Management.Automation.ErrorRecord]::new([Exception]::new($Message), 'az', 'NotSpecified', $null)
    }
    function New-K6NotFound { New-K6Error "(ResourceNotFound) The Resource was not found." 3 }

    # The fake az: records the command words and the options of the call, then lets the handler of the state answer. A repeated option adds its values.
    $global:K6AzBody = {
        $a = @($args | ForEach-Object { $_ } | ForEach-Object { [string]$_ })
        $words = @(); foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
        $options = @{}; $current = ''
        foreach ($x in @($a | Select-Object -Skip $words.Count)) {
            if ($x.StartsWith('--')) { $current = $x; if (-not $options.ContainsKey($current)) { $options[$current] = @() } } elseif ($current) { $options[$current] += $x }
        }
        $command = $words -join ' '
        $global:K6Calls.Add([pscustomobject]@{ Command = $command; Arguments = $a; Options = $options })
        $global:LASTEXITCODE = 0
        if ($global:K6Handlers.ContainsKey($command)) { return (& $global:K6Handlers[$command] $options $a) }
        New-K6Error "unexpected az call: $command" 2
    }

    function Set-K6Path($Map, [string]$Path, $Value) {
        $parts = $Path.Split('.')
        $node = $Map
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if (-not $node.Contains($parts[$i]) -or $node[$parts[$i]] -isnot [System.Collections.IDictionary]) { $node[$parts[$i]] = [ordered]@{} }
            $node = $node[$parts[$i]]
        }
        if ($null -eq $Value) { $node.Remove($parts[-1]) } else { $node[$parts[-1]] = $Value }
    }
    function New-K6Infra([hashtable]$Set = @{}) {
        $doc = [ordered]@{
            azure      = [ordered]@{ tenant_id = $global:K6Tenant; subscription_id = $global:K6Sub; resource_group = 'rg-example-01'; location = 'eastus'; custom_location = 'cl-example-01' }
            cluster    = [ordered]@{ name = 'azl-example-01' }
            nodes      = @([ordered]@{ name = 'node-a' }, [ordered]@{ name = 'node-b'; arc_machine_name = 'arc-node-b' })
            tags       = [ordered]@{ owner = 'example' }
            scenario   = [ordered]@{ storage_architecture = 's2d'; connectivity = 'connected' }
            sdn        = [ordered]@{ enabled = $true }
            networking = [ordered]@{ network_security_groups = @([ordered]@{ name = 'nsg-workloads'; rules = @(
                            [ordered]@{ name = 'allow-https-in'; priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; source_address_prefixes = @('192.0.2.0/24'); destination_port_ranges = @('443'); description = 'Allow HTTPS from the workload network' }
                            [ordered]@{ name = 'deny-all-in'; priority = 4000; direction = 'Inbound'; access = 'Deny'; destination_port_ranges = @('*') })
                    }) }
            operations = [ordered]@{
                monitoring    = [ordered]@{ enabled = $true; log_analytics_workspace = 'law-example-01'; workspace_resource_group = 'rg-example-mon'; retention_days = 90; data_collection_endpoint = 'dce-example-01'; data_collection_rule = 'dcr-example-insights'; action_group = 'ag-example-01'; alert_email = 'alerts@improbability.cloud' }
                notifications = [ordered]@{ emails = @('team@improbability.cloud') }
                licensing     = [ordered]@{ azure_hybrid_benefit = $true; windows_server_subscription = $true }
                security_logging = [ordered]@{ enabled = $true; data_collection_rule = 'dcr-example-security' }
            }
            security   = [ordered]@{ defender_for_cloud = [ordered]@{ enabled = $true; apply_cloud_security_benchmark = $true; security_contact_email = 'security@improbability.cloud' }; telemetry = [ordered]@{ diagnostic_level = 'Enhanced' } }
            landing_zone = [ordered]@{ policy = [ordered]@{ required_tags = @('costcenter', 'owner'); management_group = 'mg-example' } }
        }
        foreach ($key in $Set.Keys) { Set-K6Path $doc $key $Set[$key] }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 8)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-K6([string]$ScriptPath, [string]$File, [hashtable]$Extra = @{}, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $ScriptPath -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $ScriptPath -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Objects  = @($all | Where-Object { $_ -is [pscustomobject] })
            Rows     = @($all | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-K6Call([string]$Command) { @($global:K6Calls | Where-Object Command -EQ $Command) }
    function Get-K6Change { @($global:K6Calls | Where-Object { & $script:IsChange $_ }) }
    function Get-K6Option($Call, [string]$Name) { $Call.Options[$Name] }

    # The state of the fake Azure: signed in to the tenant of the file, the stack-hci and stack-hci-vm extensions installed, nothing else exists.
    function Reset-K6 {
        $global:K6Calls = [System.Collections.Generic.List[object]]::new()
        $global:K6State = @{ Signed = $true; Tenant = $global:K6Tenant; Extension = $true }
        $global:K6Handlers = @{
            'account show'   = { param($o, $a) if (-not $global:K6State.Signed) { return (New-K6Error 'Please run az login to setup account.') }; $global:K6State.Tenant }
            'extension show' = { param($o, $a) if (-not $global:K6State.Extension) { return (New-K6Error 'The extension is not installed.') }; '{"name":"x"}' }
        }
    }
    # The policy assignments as the ARM list of a subscription returns them (az rest), from the flat list the tests write: name, scope, policyDefinitionId.
    function New-K6PolicyList([string]$Flat) {
        $items = @(@($Flat | ConvertFrom-Json) | Where-Object { $null -ne $_ } | ForEach-Object { [ordered]@{ name = $_.name; properties = [ordered]@{ scope = $_.scope; policyDefinitionId = $_.policyDefinitionId } } })
        ConvertTo-Json -InputObject ([ordered]@{ value = $items }) -Depth 6 -Compress
    }
    # The Insights rule as az monitor data-collection rule show returns it: what Learn lists for Insights unless the test takes something out.
    function New-K6InsightsRule([string[]]$Counters = @('\Memory(*)\Available Bytes', '\Network Interface(*)\Bytes Total/sec', '\Processor(_Total)\% Processor Time', '\RDMA Activity(*)\RDMA Inbound Bytes/sec', '\RDMA Activity(*)\RDMA Outbound Bytes/sec'),
        [string[]]$Queries = @('Microsoft-Windows-SDDC-Management/Operational!*[System[(EventID=3000)]]', 'Microsoft-Windows-Health/Operational!*'),
        [string[]]$Workspaces = @("/subscriptions/$($global:K6Sub)/resourceGroups/rg-example-mon/providers/Microsoft.OperationalInsights/workspaces/law-example-01")) {
        [ordered]@{
            name         = 'dcr-example-insights'
            id           = "/subscriptions/$($global:K6Sub)/resourceGroups/rg-example-mon/providers/Microsoft.Insights/dataCollectionRules/dcr-example-insights"
            dataSources  = [ordered]@{ performanceCounters = @([ordered]@{ name = 'perf'; counterSpecifiers = $Counters }); windowsEventLogs = @([ordered]@{ name = 'events'; xPathQueries = $Queries }) }
            destinations = [ordered]@{ logAnalytics = @($Workspaces | ForEach-Object { [ordered]@{ name = 'la'; workspaceResourceId = $_ } }) }
        } | ConvertTo-Json -Depth 6
    }
    # Fake Azure where nothing the script creates exists yet and every creation works.
    function Set-K6Empty([string]$Name) {
        $h = $global:K6Handlers
        $none = { param($o, $a) New-K6NotFound }
        $quiet = { param($o, $a) $null }
        switch ($Name) {
            'Set-NetworkSecurityGroupRule' {
                $h['stack-hci-vm network nsg show'] = { param($o, $a) '{"name":"nsg-workloads"}' }
                $h['stack-hci-vm network nsg rule list'] = { param($o, $a) '[]' }
                foreach ($c in 'create', 'update', 'delete') { $h["stack-hci-vm network nsg rule $c"] = $quiet }
            }
            'Deploy-LogAnalyticsWorkspace' {
                $h['group show'] = { param($o, $a) '{"name":"rg-example-mon"}' }
                $h['monitor log-analytics workspace show'] = $none
                $h['monitor log-analytics workspace create'] = $quiet
            }
            'Deploy-DataCollectionEndpoint' {
                $h['monitor log-analytics workspace show'] = { param($o, $a) '{"name":"law-example-01","location":"westus2"}' }
                $h['monitor data-collection endpoint show'] = $none
                $h['monitor data-collection endpoint create'] = $quiet
            }
            'Install-AzureMonitorAgent' {
                $h['stack-hci cluster show'] = { param($o, $a) '{"name":"azl-example-01"}' }
                $h['stack-hci extension show'] = $none
                $h['stack-hci extension create'] = $quiet
            }
            'Enable-HciInsights' {
                $h['stack-hci extension show'] = { param($o, $a) '{"name":"AzureMonitorWindowsAgent","provisioningState":"Succeeded"}' }
                $h['monitor data-collection rule show'] = { param($o, $a) New-K6InsightsRule }
                $h['monitor data-collection rule association list-by-resource'] = { param($o, $a) '[]' }
                $h['monitor data-collection rule association create'] = $quiet
            }
            'Deploy-ActionGroup' {
                $h['monitor action-group show'] = $none
                $h['monitor action-group create'] = $quiet
                $h['monitor action-group update'] = $quiet
            }
            'Enable-DefenderForCloud' {
                $h['provider show'] = { param($o, $a) 'NotRegistered' }
                $h['provider register'] = $quiet
                $h['rest'] = { param($o, $a) New-K6PolicyList ('[]') }
                $h['policy set-definition show'] = { param($o, $a) '{"name":"x"}' }
                $h['policy assignment create'] = $quiet
                $h['security contact show'] = $none
                $h['security contact create'] = $quiet
            }
            'Invoke-AzurePolicyTier1-Orchestrated' {
                $h['policy definition show'] = { param($o, $a) '{"displayName":"Require a tag on resources"}' }
                $h['policy assignment show'] = $none
                $h['rest'] = { param($o, $a) $path = ([string]$o['--body'][0]).TrimStart('@'); $global:K6Params += , (Get-Content -LiteralPath $path -Raw); $null }
                $global:K6Params = @()
            }
            'Enable-AzureHybridBenefit' {
                $h['stack-hci cluster show'] = { param($o, $a) $global:K6Shows++; if ($global:K6Shows -gt 1) { '{"name":"azl-example-01","softwareAssuranceProperties":{"softwareAssuranceStatus":"Enabled"}}' } else { '{"name":"azl-example-01","softwareAssuranceProperties":{"softwareAssuranceStatus":"Disabled"}}' } }
                $h['stack-hci cluster extend-software-assurance-benefit'] = $quiet
                $global:K6Shows = 0
            }
            'Enable-WindowsServerSubscription' {
                $h['stack-hci cluster show'] = { param($o, $a) $global:K6Shows++; if ($global:K6Shows -gt 1) { '{"name":"azl-example-01","desiredProperties":{"windowsServerSubscription":"Enabled"}}' } else { '{"name":"azl-example-01","desiredProperties":{"windowsServerSubscription":"Disabled"}}' } }
                $h['stack-hci cluster update'] = $quiet
                $global:K6Shows = 0
            }            'Invoke-TelemetryConfiguration-Orchestrated' {
                $h['stack-hci cluster show'] = { param($o, $a) $global:K6Shows++; if ($global:K6Shows -gt 1) { '{"name":"azl-example-01","desiredProperties":{"diagnosticLevel":"Enhanced"}}' } else { '{"name":"azl-example-01","desiredProperties":{"diagnosticLevel":"Basic"}}' } }
                $h['stack-hci cluster update'] = $quiet
                $global:K6Shows = 0
            }
            'Invoke-SecurityLogging-Orchestrated' {
                $h['monitor log-analytics workspace show'] = { param($o, $a) "{`"id`":`"/subscriptions/$($global:K6Sub)/resourceGroups/rg-example-mon/providers/Microsoft.OperationalInsights/workspaces/law-example-01`",`"location`":`"westus2`"}" }
                $h['stack-hci extension show'] = { param($o, $a) '{"name":"AzureMonitorWindowsAgent","provisioningState":"Succeeded"}' }
                $h['monitor data-collection rule show'] = $none
                $h['monitor data-collection rule create'] = { param($o, $a) $global:K6Rules = Get-Content -LiteralPath ([string]$o['--rule-file'][0]) -Raw | ConvertFrom-Json; '{"id":"/subscriptions/x/resourceGroups/rg-example-mon/providers/Microsoft.Insights/dataCollectionRules/dcr-example-security"}' }
                $h['monitor data-collection rule association list-by-resource'] = { param($o, $a) '[]' }
                $h['monitor data-collection rule association create'] = $quiet
            }
        }
    }
}

AfterAll { Remove-Variable -Name K6Rule, K6Benchmark, K6AzBody, K6Rules, K6Tenant, K6Sub, K6Calls, K6State, K6Handlers, K6Params, K6Shows -Scope Global -ErrorAction SilentlyContinue }

Describe 'every Azure CLI script of the batch: <Name>' -ForEach $script:Cases {
    BeforeEach {
        Reset-K6
        Mock az { & $global:K6AzBody @($args) }
    }

    It 'carries the standard header, takes every value from the file and has no prompt' {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Match 'Import-AzlInfrastructure'
        $text | Should -Match '(?s)^<#\s+\.SYNOPSIS.*\.DESCRIPTION.*\.PARAMETER InfrastructureFile.*\.EXAMPLE.*#>'
        $text | Should -Not -Match 'Read-Host|Get-Credential|\bbash\b'
        if ($Changes) { $text | Should -Match 'SupportsShouldProcess' }
        # one call site of az, never a command string
        ([regex]::Matches($text, '&\s+az\s+@')).Count | Should -Be 1
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?<!1f3afdf9-d0c9-4c3d-847f-89da613e70a8)(?<!871b6d14-10aa-478d-b590-94f262ecfa99)'
    }

    It 'has every parameter registered' {
        $registry = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
        $key = ([IO.Path]::GetFileName($Path) -replace '[.-]', '_') + '_generated:'
        $registry | Should -Match ([regex]::Escape($key))
        foreach ($p in 'InfrastructureFile') { $registry | Should -Match ([regex]::Escape($key) + '[\s\S]{0,6000}?\b' + $p + ':') }
    }

    It 'ends with exit code 1 and sends nothing when az is not installed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        $r = Invoke-K6 $Path (New-K6Infra)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'Azure CLI \(az\)'
        $global:K6Calls.Count | Should -Be 0
    }

    It 'ends with exit code 1 when az is not signed in, and changes nothing' {
        $global:K6State.Signed = $false
        $r = Invoke-K6 $Path (New-K6Infra)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'az login'
        Get-K6Change | Should -BeNullOrEmpty
    }

    It 'ends with exit code 1 when az is signed in to another tenant, and changes nothing' {
        $global:K6State.Tenant = [guid]::NewGuid().ToString()
        $r = Invoke-K6 $Path (New-K6Infra)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'tenant'
        Get-K6Change | Should -BeNullOrEmpty
    }

    It 'ends with exit code 2 before any az call for a missing, bad or placeholder tenant or subscription' {
        $sets = @(@{ 'azure.tenant_id' = $null }, @{ 'azure.tenant_id' = 'not-a-guid' })
        if ($Subscription) { $sets += @(@{ 'azure.subscription_id' = $null }, @{ 'azure.subscription_id' = '00000000-0000-0000-0000-000000000000' }) }
        foreach ($set in $sets) {
            $r = Invoke-K6 $Path (New-K6Infra $set)
            $r.ExitCode | Should -Be 2 -Because ($set.Keys -join ',')
        }
        $r = Invoke-K6 $Path (Join-Path $TestDrive 'missing.yml')
        $r.ExitCode | Should -Be 2
        $global:K6Calls.Count | Should -Be 0
    }

    It 'under -WhatIf reads Azure and changes nothing, and without it makes the change' -Skip:(-not $Changes) {
        Set-K6Empty $Name
        $dry = Invoke-K6 $Path (New-K6Infra) -DryRun
        $dry.ExitCode | Should -Be 0 -Because $dry.Text
        Get-K6Change | Should -BeNullOrEmpty
        Reset-K6; Set-K6Empty $Name
        $real = Invoke-K6 $Path (New-K6Infra)
        $real.ExitCode | Should -Be 0 -Because $real.Text
        (Get-K6Change).Count | Should -BeGreaterThan 0
    }

    It 'passes the subscription of the file to every az call that reads or changes a resource' {
        Set-K6Empty $Name
        $null = Invoke-K6 $Path (New-K6Infra)
        $calls = @($global:K6Calls | Where-Object { $_.Command -notin 'extension show' -and $_.Command -ne 'account show' -and $_.Command -notlike 'monitor data-collection rule association*' -and $_.Command -ne 'policy definition show' -and $_.Command -ne 'policy assignment show' -and $_.Command -ne 'policy assignment create' -and $_.Command -ne 'rest' })
        foreach ($call in $calls) { $call.Options['--subscription'] | Should -Be $global:K6Sub -Because $call.Command }
    }
}

Describe 'Set-NetworkSecurityGroupRule.azcli.ps1' {
    BeforeAll {
        $script:S = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-01-sdn-deployment', 'task-02-configure-network-security-groups', 'azurecli', 'Set-NetworkSecurityGroupRule.azcli.ps1')
        function Add-AzRule([string]$Name, [int]$Priority, [string]$Access = 'Allow', [string[]]$Ports = @('443'), [string[]]$Sources = @('192.0.2.0/24'), [string]$Protocol = 'Tcp') {
        $global:K6Rules += [pscustomobject]@{ name = $Name; properties = [pscustomobject]@{ priority = $Priority; direction = 'Inbound'; access = $Access; protocol = $Protocol; sourceAddressPrefixes = $Sources; destinationAddressPrefixes = @('*'); sourcePortRanges = @('*'); destinationPortRanges = $Ports } }
        }
    }
    BeforeEach {
        Reset-K6
        Mock az { & $global:K6AzBody @($args) }
        Set-K6Empty 'Set-NetworkSecurityGroupRule'
        $global:K6Rules = @()
        $global:K6Handlers['stack-hci-vm network nsg rule list'] = { param($o, $a) if (@($global:K6Rules).Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject @($global:K6Rules) -Depth 6 } }
    }
    AfterAll { Remove-Variable -Name K6Rules -Scope Global -ErrorAction SilentlyContinue }

    It 'creates the rules the group lacks, with the values of the file and the custom location' {
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $creates = Get-K6Call 'stack-hci-vm network nsg rule create'
        @($creates | ForEach-Object { $_.Options['--name'][0] }) | Should -Be @('allow-https-in', 'deny-all-in')
        $first = $creates[0]
        $first.Options['--nsg-name'] | Should -Be 'nsg-workloads'
        $first.Options['--resource-group'] | Should -Be 'rg-example-01'
        $first.Options['--subscription'] | Should -Be $global:K6Sub
        $first.Options['--priority'] | Should -Be '100'
        $first.Options['--direction'] | Should -Be 'Inbound'
        $first.Options['--access'] | Should -Be 'Allow'
        $first.Options['--protocol'] | Should -Be 'Tcp'
        @($first.Options['--source-address-prefixes']) | Should -Be @('192.0.2.0/24')
        @($first.Options['--destination-port-ranges']) | Should -Be @('443')
        $first.Options['--description'] | Should -Be 'Allow HTTPS from the workload network'
        $first.Options['--custom-location'] | Should -Be "/subscriptions/$($global:K6Sub)/resourceGroups/rg-example-01/providers/Microsoft.ExtendedLocation/customLocations/cl-example-01"
        Get-K6Call 'stack-hci-vm network nsg create' | Should -BeNullOrEmpty
    }

    It 'changes nothing when the rules are already as the file says' {
        Add-AzRule 'allow-https-in' 100
        Add-AzRule 'deny-all-in' 4000 -Access 'Deny' -Ports @('*') -Sources @('*') -Protocol '*'
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows.Action) | Should -Be @('AlreadyInSync', 'AlreadyInSync')
        Get-K6Change | Should -BeNullOrEmpty
    }

    It 'updates a rule that differs from the file' {
        Add-AzRule 'allow-https-in' 100 -Ports @('8443')
        Add-AzRule 'deny-all-in' 4000 -Access 'Deny' -Ports @('*') -Sources @('*') -Protocol '*'
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $update = (Get-K6Call 'stack-hci-vm network nsg rule update')
        $update.Count | Should -Be 1
        $update[0].Options['--name'] | Should -Be 'allow-https-in'
        @($update[0].Options['--destination-port-ranges']) | Should -Be @('443')
        Get-K6Call 'stack-hci-vm network nsg rule create' | Should -BeNullOrEmpty
    }

    It 'reports a rule the file does not list and removes it only with -RemoveUnlistedRules, after the rules of the file are in place' {
        Add-AzRule 'allow-https-in' 100
        Add-AzRule 'deny-all-in' 4000 -Access 'Deny' -Ports @('*') -Sources @('*') -Protocol '*'
        Add-AzRule 'old-rule' 200
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object Action -EQ 'Unlisted').Count | Should -Be 1
        Get-K6Call 'stack-hci-vm network nsg rule delete' | Should -BeNullOrEmpty
        $r2 = Invoke-K6 $script:S (New-K6Infra) @{ RemoveUnlistedRules = $true }
        $r2.ExitCode | Should -Be 0 -Because $r2.Text
        $delete = Get-K6Call 'stack-hci-vm network nsg rule delete'
        $delete.Count | Should -Be 1
        $delete[0].Options['--name'] | Should -Be 'old-rule'
        $delete[0].Arguments | Should -Contain '--yes'
        Invoke-K6 $script:S (New-K6Infra) @{ RemoveUnlistedRules = $true } -DryRun | Out-Null
        (Get-K6Call 'stack-hci-vm network nsg rule delete').Count | Should -Be 1
    }

    It 'deletes nothing from a group when a rule of the file failed, and ends with exit code 1' {
        Add-AzRule 'old-rule' 100
        $r = Invoke-K6 $script:S (New-K6Infra) @{ RemoveUnlistedRules = $true }
        $r.ExitCode | Should -Be 1 -Because 'the priority of allow-https-in is held by old-rule'
        Get-K6Call 'stack-hci-vm network nsg rule delete' | Should -BeNullOrEmpty
    }

    It 'fails with exit code 1 for a group that does not exist and never creates one' {
        $global:K6Handlers['stack-hci-vm network nsg show'] = { param($o, $a) New-K6NotFound }
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'New-NetworkSecurityGroup\.ps1'
        Get-K6Change | Should -BeNullOrEmpty
    }

    It 'ends with exit code 1 when the stack-hci-vm extension is missing' {
        $global:K6State.Extension = $false
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'az extension add --name stack-hci-vm'
    }

    It 'ends with exit code 2 and sends nothing for SDN off, a group without rules, a bad priority or port, a missing port list' {
        $bad = @(
            @{ 'sdn.enabled' = $false }
            @{ 'networking.network_security_groups' = @([ordered]@{ name = 'nsg-empty'; rules = @() }) }
            @{ 'networking.network_security_groups' = @([ordered]@{ name = 'nsg-a'; rules = @([ordered]@{ name = 'r1'; priority = 99; direction = 'Inbound'; access = 'Allow'; destination_port_ranges = @('443') }) }) }
            @{ 'networking.network_security_groups' = @([ordered]@{ name = 'nsg-a'; rules = @([ordered]@{ name = 'r1'; priority = 100; direction = 'Inbound'; access = 'Allow'; destination_port_ranges = @('70000') }) }) }
            @{ 'networking.network_security_groups' = @([ordered]@{ name = 'nsg-a'; rules = @([ordered]@{ name = 'r1'; priority = 100; direction = 'Inbound'; access = 'Allow' }) }) }
            @{ 'azure.custom_location' = $null }
        )
        foreach ($set in $bad) { (Invoke-K6 $script:S (New-K6Infra $set)).ExitCode | Should -Be 2 -Because ($set.Keys -join ',') }
        $global:K6Calls.Count | Should -Be 0
    }

    It 'does nothing and exits 0 when the file lists no group' {
        $r = Invoke-K6 $script:S (New-K6Infra @{ 'networking.network_security_groups' = $null })
        $r.ExitCode | Should -Be 0
        $global:K6Calls.Count | Should -Be 0
    }
}

Describe 'Test-NetworkSecurityGroupRule.azcli.ps1' {
    BeforeAll { $script:S = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-01-sdn-deployment', 'task-03-configure-network-security-groups', 'azurecli', 'Test-NetworkSecurityGroupRule.azcli.ps1') }
    BeforeEach {
        Reset-K6
        Mock az { & $global:K6AzBody @($args) }
        $global:K6Rules = @(
            [pscustomobject]@{ name = 'allow-https-in'; properties = [pscustomobject]@{ priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; sourceAddressPrefixes = @('192.0.2.0/24'); destinationAddressPrefixes = @('*'); sourcePortRanges = @('*'); destinationPortRanges = @('443') } }
            [pscustomobject]@{ name = 'deny-all-in'; properties = [pscustomobject]@{ priority = 4000; direction = 'Inbound'; access = 'Deny'; protocol = '*'; sourceAddressPrefixes = @('*'); destinationAddressPrefixes = @('*'); sourcePortRanges = @('*'); destinationPortRanges = @('*') } }
        )
        $global:K6Handlers['stack-hci-vm network nsg show'] = { param($o, $a) '{"name":"nsg-workloads"}' }
        $global:K6Handlers['stack-hci-vm network nsg rule list'] = { param($o, $a) ConvertTo-Json -InputObject @($global:K6Rules) -Depth 6 }
    }
    AfterAll { Remove-Variable -Name K6Rules -Scope Global -ErrorAction SilentlyContinue }

    It 'ends with exit code 0 when the group and every rule are as the file says, and only reads' {
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Get-K6Change | Should -BeNullOrEmpty
        @($global:K6Calls.Command | Sort-Object -Unique) | Should -Be @('account show', 'extension show', 'stack-hci-vm network nsg rule list', 'stack-hci-vm network nsg show')
    }

    It 'ends with exit code 1 and names a rule that is missing' {
        $global:K6Rules = @($global:K6Rules[0])
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Action -EQ 'Missing') | ForEach-Object { $_.Item }) | Should -Be 'rule nsg-workloads/deny-all-in'
    }

    It 'ends with exit code 1 and says what differs' {
        $global:K6Rules[0].properties.priority = 150
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Action -EQ 'Differs').Detail) | Should -Match 'priority is 150'
    }

    It 'ends with exit code 1 for a group that does not exist' {
        $global:K6Handlers['stack-hci-vm network nsg show'] = { param($o, $a) New-K6NotFound }
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 1
        @($r.Rows | Where-Object Action -EQ 'GroupMissing').Count | Should -Be 1
    }

    It 'reports a rule the file does not list as Extra and does not fail for it' {
        $global:K6Rules += [pscustomobject]@{ name = 'by-hand'; properties = [pscustomobject]@{ priority = 300; direction = 'Inbound'; access = 'Allow'; protocol = '*'; sourceAddressPrefixes = @('*'); destinationAddressPrefixes = @('*'); sourcePortRanges = @('*'); destinationPortRanges = @('22') } }
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object Action -EQ 'Extra').Count | Should -Be 1
    }

    It 'ends with exit code 2 for SDN off or a group without rules' {
        (Invoke-K6 $script:S (New-K6Infra @{ 'sdn.enabled' = $false })).ExitCode | Should -Be 2
        (Invoke-K6 $script:S (New-K6Infra @{ 'networking.network_security_groups' = @([ordered]@{ name = 'nsg-empty'; rules = @() }) })).ExitCode | Should -Be 2
    }
}

Describe 'the monitoring scripts' {
    BeforeAll {
        $m = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-02-monitoring-observability')
        $script:Workspace = [IO.Path]::Combine($m, 'task-01-configure-log-analytics-workspace', 'azurecli', 'Deploy-LogAnalyticsWorkspace.azcli.ps1')
        $script:Endpoint = [IO.Path]::Combine($m, 'task-01-configure-log-analytics-workspace', 'azurecli', 'Deploy-DataCollectionEndpoint.azcli.ps1')
        $script:Agent = [IO.Path]::Combine($m, 'task-02-configure-azure-monitor-agent', 'azurecli', 'Install-AzureMonitorAgent.azcli.ps1')
        $script:Insights = [IO.Path]::Combine($m, 'task-03-enable-hci-insights', 'azurecli', 'Enable-HciInsights.azcli.ps1')
        $script:Alerting = [IO.Path]::Combine($m, 'task-04-setup-alerting', 'azurecli', 'Deploy-ActionGroup.azcli.ps1')
    }
    BeforeEach {
        Reset-K6
        Mock az { & $global:K6AzBody @($args) }
    }

    Context 'Deploy-LogAnalyticsWorkspace.azcli.ps1' {
        BeforeEach { Set-K6Empty 'Deploy-LogAnalyticsWorkspace' }
        It 'creates the workspace in the resource group, region, retention and tags of the file' {
            $r = Invoke-K6 $script:Workspace (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $c = (Get-K6Call 'monitor log-analytics workspace create')[0]
            $c.Options['--workspace-name'] | Should -Be 'law-example-01'
            $c.Options['--resource-group'] | Should -Be 'rg-example-mon'
            $c.Options['--location'] | Should -Be 'eastus'
            $c.Options['--retention-time'] | Should -Be '90'
            @($c.Options['--tags']) | Should -Be @('owner=example')
            $c.Options.ContainsKey('--sku') | Should -BeFalse
        }
        It 'leaves a workspace that exists alone and reports a different region or retention' {
            $global:K6Handlers['monitor log-analytics workspace show'] = { param($o, $a) '{"name":"law-example-01","location":"westeurope","retentionInDays":30}' }
            $r = Invoke-K6 $script:Workspace (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Detail | Should -Match 'westeurope'
            $r.Rows[0].Detail | Should -Match '30 days'
            Get-K6Change | Should -BeNullOrEmpty
        }
        It 'fails with exit code 1 when the resource group does not exist, and does nothing when monitoring is off' {
            $global:K6Handlers['group show'] = { param($o, $a) New-K6NotFound }
            (Invoke-K6 $script:Workspace (New-K6Infra)).ExitCode | Should -Be 1
            Get-K6Change | Should -BeNullOrEmpty
            Reset-K6
            (Invoke-K6 $script:Workspace (New-K6Infra @{ 'operations.monitoring.enabled' = $false })).ExitCode | Should -Be 0
            $global:K6Calls.Count | Should -Be 0
        }
        It 'ends with exit code 2 for a missing workspace name, a bad name or a retention out of range' {
            foreach ($set in @{ 'operations.monitoring.log_analytics_workspace' = $null }, @{ 'operations.monitoring.log_analytics_workspace' = 'x' }, @{ 'operations.monitoring.retention_days' = 10 }, @{ 'operations.monitoring.workspace_resource_group' = $null }) {
                (Invoke-K6 $script:Workspace (New-K6Infra $set)).ExitCode | Should -Be 2 -Because ($set.Keys -join ',')
            }
            $global:K6Calls.Count | Should -Be 0
        }
    }

    Context 'Deploy-DataCollectionEndpoint.azcli.ps1' {
        BeforeEach { Set-K6Empty 'Deploy-DataCollectionEndpoint' }
        It 'creates the endpoint in the region of the workspace, with public network access stated' {
            $r = Invoke-K6 $script:Endpoint (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $c = (Get-K6Call 'monitor data-collection endpoint create')[0]
            $c.Options['--name'] | Should -Be 'dce-example-01'
            $c.Options['--resource-group'] | Should -Be 'rg-example-mon'
            $c.Options['--location'] | Should -Be 'westus2'
            $c.Options['--public-network-access'] | Should -Be 'Enabled'
        }
        It 'fails with exit code 1 when the workspace does not exist, and reports an endpoint in another region' {
            $global:K6Handlers['monitor log-analytics workspace show'] = { param($o, $a) New-K6NotFound }
            (Invoke-K6 $script:Endpoint (New-K6Infra)).ExitCode | Should -Be 1
            Reset-K6; Set-K6Empty 'Deploy-DataCollectionEndpoint'
            $global:K6Handlers['monitor data-collection endpoint show'] = { param($o, $a) '{"name":"dce-example-01","location":"eastus"}' }
            $r = Invoke-K6 $script:Endpoint (New-K6Infra)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Detail | Should -Match 'eastus'
            Get-K6Change | Should -BeNullOrEmpty
        }
        It 'ends with exit code 2 for a missing endpoint name' {
            (Invoke-K6 $script:Endpoint (New-K6Infra @{ 'operations.monitoring.data_collection_endpoint' = $null })).ExitCode | Should -Be 2
        }
        It 'stops with exit code 1, before any data-collection call, when the extension monitor-control-service is missing (lab run 2026-11-23: az asked to install it)' {
            $global:K6Handlers['extension show'] = { param($o, $a) if ("$($o['--name'])" -eq 'monitor-control-service') { return (New-K6Error 'The extension monitor-control-service is not installed.') }; '{"name":"x"}' }
            $r = Invoke-K6 $script:Endpoint (New-K6Infra)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'az extension add --name monitor-control-service'
            @($global:K6Calls | Where-Object { $_.Command -like 'monitor data-collection*' }) | Should -BeNullOrEmpty
        }
    }

    Context 'Install-AzureMonitorAgent.azcli.ps1' {
        BeforeEach { Set-K6Empty 'Install-AzureMonitorAgent' }
        It 'installs the extension on the Arc setting default of the instance' {
            $r = Invoke-K6 $script:Agent (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $c = (Get-K6Call 'stack-hci extension create')[0]
            $c.Options['--cluster-name'] | Should -Be 'azl-example-01'
            $c.Options['--resource-group'] | Should -Be 'rg-example-01'
            $c.Options['--arc-setting-name'] | Should -Be 'default'
            $c.Options['--name'] | Should -Be 'AzureMonitorWindowsAgent'
            $c.Options['--publisher'] | Should -Be 'Microsoft.Azure.Monitor'
            $c.Options['--type'] | Should -Be 'AzureMonitorWindowsAgent'
        }
        It 'leaves an installed extension alone and warns about a provisioning state that is not Succeeded' {
            $global:K6Handlers['stack-hci extension show'] = { param($o, $a) '{"name":"AzureMonitorWindowsAgent","provisioningState":"Failed"}' }
            $r = Invoke-K6 $script:Agent (New-K6Infra)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Detail | Should -Match 'Failed'
            Get-K6Change | Should -BeNullOrEmpty
        }
        It 'fails with exit code 1 when the instance or the stack-hci extension is missing, and does nothing when monitoring is off' {
            $global:K6Handlers['stack-hci cluster show'] = { param($o, $a) New-K6NotFound }
            (Invoke-K6 $script:Agent (New-K6Infra)).ExitCode | Should -Be 1
            Reset-K6; $global:K6State.Extension = $false
            (Invoke-K6 $script:Agent (New-K6Infra)).ExitCode | Should -Be 1
            Reset-K6
            (Invoke-K6 $script:Agent (New-K6Infra @{ 'operations.monitoring.enabled' = $false })).ExitCode | Should -Be 0
            $global:K6Calls.Count | Should -Be 0
        }
        It 'ends with exit code 2 for a missing cluster name or resource group' {
            (Invoke-K6 $script:Agent (New-K6Infra @{ 'cluster.name' = $null })).ExitCode | Should -Be 2
            (Invoke-K6 $script:Agent (New-K6Infra @{ 'azure.resource_group' = $null })).ExitCode | Should -Be 2
        }
    }

    Context 'Enable-HciInsights.azcli.ps1' {
        BeforeEach { Set-K6Empty 'Enable-HciInsights' }
        It 'associates the rule with the Arc machine of every node, using arc_machine_name where the node has one' {
            $r = Invoke-K6 $script:Insights (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $creates = Get-K6Call 'monitor data-collection rule association create'
            @($creates | ForEach-Object { $_.Options['--name'][0] }) | Should -Be @('node-a-dataCollectionRuleAssociations', 'arc-node-b-dataCollectionRuleAssociations')
            $creates[0].Options['--resource'] | Should -Be "/subscriptions/$($global:K6Sub)/resourceGroups/rg-example-01/providers/Microsoft.HybridCompute/machines/node-a"
            $creates[0].Options['--rule-id'] | Should -Be "/subscriptions/$($global:K6Sub)/resourceGroups/rg-example-mon/providers/Microsoft.Insights/dataCollectionRules/dcr-example-insights"
            (Get-K6Call 'monitor data-collection rule show')[0].Options['--name'] | Should -Be 'dcr-example-insights'
        }
        It 'never creates or changes the rule: it stops with exit code 1 when the rule does not exist' {
            $global:K6Handlers['monitor data-collection rule show'] = { param($o, $a) New-K6NotFound }
            $r = Invoke-K6 $script:Insights (New-K6Infra)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'portal'
            Get-K6Change | Should -BeNullOrEmpty
            $global:K6Calls.Command | Should -Not -Contain 'monitor data-collection rule create'
        }
        It 'reads the rule and stops with exit code 1, associating nothing, when it lacks what Insights needs: <Why>' -ForEach @(
            @{ Why = 'an RDMA counter'; Rule = { New-K6InsightsRule -Counters @('\Memory(*)\Available Bytes', '\Network Interface(*)\Bytes Total/sec', '\Processor(_Total)\% Processor Time', '\RDMA Activity(*)\RDMA Inbound Bytes/sec') }; Expect = 'RDMA Outbound' }
            @{ Why = 'the health channel'; Rule = { New-K6InsightsRule -Queries @('Microsoft-Windows-SDDC-Management/Operational!*') }; Expect = 'Microsoft-Windows-Health/Operational' }
            @{ Why = 'a destination'; Rule = { New-K6InsightsRule -Workspaces @() }; Expect = 'no Log Analytics workspace' }
            @{ Why = 'the workspace of the file'; Rule = { New-K6InsightsRule -Workspaces @("/subscriptions/$($global:K6Sub)/resourceGroups/rg-example-mon/providers/Microsoft.OperationalInsights/workspaces/law-other") }; Expect = "law-other, not to the workspace 'law-example-01'" }
            @{ Why = 'any data source at all'; Rule = { '{"name":"dcr-example-insights","id":"/x/dcr-example-insights"}' }; Expect = 'not ready for Insights' }
        ) {
            $global:K6Rule = $Rule
            $global:K6Handlers['monitor data-collection rule show'] = { param($o, $a) & $global:K6Rule }
            $r = Invoke-K6 $script:Insights (New-K6Infra)
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match $Expect
            $r.Text | Should -Match 'Update'
            Get-K6Change | Should -BeNullOrEmpty
            Get-K6Call 'monitor data-collection rule association list-by-resource' | Should -BeNullOrEmpty
        }
        It 'stops with exit code 1 when the Azure Monitor Agent is not on the instance' {
            $global:K6Handlers['stack-hci extension show'] = { param($o, $a) New-K6NotFound }
            (Invoke-K6 $script:Insights (New-K6Infra)).ExitCode | Should -Be 1
            Get-K6Change | Should -BeNullOrEmpty
        }
        It 'leaves an existing association alone and fails on one that points to another rule' {
            $global:K6Handlers['monitor data-collection rule association list-by-resource'] = { param($o, $a)
                ('[{"name":"' + (($o['--resource'][0]).Split('/')[-1]) + '-dataCollectionRuleAssociations","dataCollectionRuleId":"/subscriptions/' + $global:K6Sub + '/resourceGroups/rg-example-mon/providers/Microsoft.Insights/dataCollectionRules/dcr-example-insights"}]') }
            $r = Invoke-K6 $script:Insights (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action | Select-Object -Unique) | Should -Be 'AlreadyExists'
            Get-K6Change | Should -BeNullOrEmpty
            $global:K6Handlers['monitor data-collection rule association list-by-resource'] = { param($o, $a)
                ('[{"name":"' + (($o['--resource'][0]).Split('/')[-1]) + '-dataCollectionRuleAssociations","dataCollectionRuleId":"/subscriptions/' + $global:K6Sub + '/resourceGroups/rg-other/providers/Microsoft.Insights/dataCollectionRules/another"}]') }
            $r2 = Invoke-K6 $script:Insights (New-K6Infra)
            $r2.ExitCode | Should -Be 1
            @($r2.Rows.Action | Select-Object -Unique) | Should -Be 'Conflict'
        }
        It 'ends with exit code 2 for a missing rule name or no node' {
            (Invoke-K6 $script:Insights (New-K6Infra @{ 'operations.monitoring.data_collection_rule' = $null })).ExitCode | Should -Be 2
            (Invoke-K6 $script:Insights (New-K6Infra @{ nodes = $null })).ExitCode | Should -Be 2
        }
        It 'stops with exit code 1, before any data-collection call, when the extension monitor-control-service is missing' {
            $global:K6Handlers['extension show'] = { param($o, $a) if ("$($o['--name'])" -eq 'monitor-control-service') { return (New-K6Error 'The extension monitor-control-service is not installed.') }; '{"name":"x"}' }
            $r = Invoke-K6 $script:Insights (New-K6Infra)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'az extension add --name monitor-control-service'
            @($global:K6Calls | Where-Object { $_.Command -like 'monitor data-collection*' }) | Should -BeNullOrEmpty
        }
    }

    Context 'Deploy-ActionGroup.azcli.ps1' {
        BeforeEach { Set-K6Empty 'Deploy-ActionGroup' }
        It 'creates the group with one email receiver per address of the file, a short name of at most 12 characters and the tags' {
            $r = Invoke-K6 $script:Alerting (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $c = (Get-K6Call 'monitor action-group create')[0]
            $c.Options['--name'] | Should -Be 'ag-example-01'
            $c.Options['--resource-group'] | Should -Be 'rg-example-mon'
            $c.Options['--short-name'] | Should -Be 'agexample01'
            @($c.Options['--action']) | Should -Be @('email', 'email-team-improbability-cloud', 'team@improbability.cloud', 'email', 'email-alerts-improbability-cloud', 'alerts@improbability.cloud')
            @($c.Options['--tags']) | Should -Be @('owner=example')
        }
        It 'adds only the missing addresses to a group that exists and keeps its receivers' {
            $global:K6Handlers['monitor action-group show'] = { param($o, $a) '{"name":"ag-example-01","emailReceivers":[{"name":"old","emailAddress":"TEAM@improbability.cloud"}]}' }
            $r = Invoke-K6 $script:Alerting (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $u = (Get-K6Call 'monitor action-group update')
            $u.Count | Should -Be 1
            @($u[0].Options['--add-action']) | Should -Be @('email', 'email-alerts-improbability-cloud', 'alerts@improbability.cloud')
            Get-K6Call 'monitor action-group create' | Should -BeNullOrEmpty
        }
        It 'gives two addresses that make the same receiver name two different names' {
            $r = Invoke-K6 $script:Alerting (New-K6Infra @{ 'operations.notifications.emails' = @('a.b@improbability.cloud', 'a-b@improbability.cloud'); 'operations.monitoring.alert_email' = $null })
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('a-b@improbability.cloud'))).Substring(0, 8).ToLowerInvariant()
            @((Get-K6Call 'monitor action-group create')[0].Options['--action']) | Should -Be @('email', 'email-a-b-improbability-cloud', 'a.b@improbability.cloud', 'email', "email-a-b-improbability-cloud-$hash", 'a-b@improbability.cloud')
        }
        It 'does not give an added receiver a name that a receiver of another kind already has' {
            $global:K6Handlers['monitor action-group show'] = { param($o, $a) '{"name":"ag-example-01","emailReceivers":[{"name":"team","emailAddress":"team@improbability.cloud"}],"smsReceivers":[{"name":"email-alerts-improbability-cloud","phoneNumber":"5550100"}]}' }
            $r = Invoke-K6 $script:Alerting (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('alerts@improbability.cloud'))).Substring(0, 8).ToLowerInvariant()
            @((Get-K6Call 'monitor action-group update')[0].Options['--add-action']) | Should -Be @('email', "email-alerts-improbability-cloud-$hash", 'alerts@improbability.cloud')
        }
        It 'changes nothing when the group has every address' {
            $global:K6Handlers['monitor action-group show'] = { param($o, $a) '{"name":"ag-example-01","emailReceivers":[{"emailAddress":"team@improbability.cloud"},{"emailAddress":"alerts@improbability.cloud"}]}' }
            $r = Invoke-K6 $script:Alerting (New-K6Infra)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            Get-K6Change | Should -BeNullOrEmpty
        }
        It 'reports a disabled group as Disabled with a warning, and changes nothing by default' {
            $global:K6Handlers['monitor action-group show'] = { param($o, $a) '{"name":"ag-example-01","enabled":false,"emailReceivers":[{"emailAddress":"team@improbability.cloud"},{"emailAddress":"alerts@improbability.cloud"}]}' }
            $r = Invoke-K6 $script:Alerting (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Disabled'
            $r.Rows[0].Enabled | Should -BeFalse
            $r.Text | Should -Match 'DISABLED: none of its receivers gets an alert'
            Get-K6Change | Should -BeNullOrEmpty
        }
        It 'enables a disabled group with --enabled true when operations.monitoring.action_group_enable_if_disabled is true' {
            $global:K6Handlers['monitor action-group show'] = { param($o, $a) '{"name":"ag-example-01","enabled":false,"emailReceivers":[{"emailAddress":"team@improbability.cloud"},{"emailAddress":"alerts@improbability.cloud"}]}' }
            $r = Invoke-K6 $script:Alerting (New-K6Infra @{ 'operations.monitoring.action_group_enable_if_disabled' = $true })
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Enabled'
            $u = @(Get-K6Call 'monitor action-group update')
            $u.Count | Should -Be 1
            @($u[0].Options['--enabled']) | Should -Be @('true')
            $u[0].Options.ContainsKey('--add-action') | Should -BeFalse
        }
        It 'adds a missing receiver to a disabled group without enabling it, and warns' {
            $global:K6Handlers['monitor action-group show'] = { param($o, $a) '{"name":"ag-example-01","enabled":false,"emailReceivers":[{"emailAddress":"team@improbability.cloud"}]}' }
            $r = Invoke-K6 $script:Alerting (New-K6Infra)
            $r.Rows[0].Action | Should -Be 'Updated'
            $r.Rows[0].Enabled | Should -BeFalse
            $r.Text | Should -Match 'DISABLED'
            (Get-K6Call 'monitor action-group update')[0].Options.ContainsKey('--enabled') | Should -BeFalse
        }
        It 'ends with exit code 2 for no address, a bad address or a missing group name' {
            foreach ($set in @{ 'operations.notifications.emails' = $null; 'operations.monitoring.alert_email' = $null }, @{ 'operations.monitoring.alert_email' = 'not-an-address' }, @{ 'operations.monitoring.action_group' = $null }) {
                (Invoke-K6 $script:Alerting (New-K6Infra $set)).ExitCode | Should -Be 2 -Because ($set.Keys -join ',')
            }
            $global:K6Calls.Count | Should -Be 0
        }
    }
}

Describe 'the security and licensing scripts' {
    BeforeAll {
        $o = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '05-operational-foundations')
        $script:Defender = [IO.Path]::Combine($o, 'phase-04-security-governance', 'task-01-enable-defender-for-cloud', 'azurecli', 'Enable-DefenderForCloud.azcli.ps1')
        $script:Policy = [IO.Path]::Combine($o, 'phase-04-security-governance', 'task-02-apply-azure-policy-initiatives', 'azurecli', 'Invoke-AzurePolicyTier1-Orchestrated.azcli.ps1')
        $script:Benefit = [IO.Path]::Combine($o, 'phase-05-licensing-telemetry', 'task-01-enable-azure-hybrid-benefit', 'azurecli', 'Enable-AzureHybridBenefit.azcli.ps1')
        $script:Subscription = [IO.Path]::Combine($o, 'phase-05-licensing-telemetry', 'task-02-activate-windows-server-subscription', 'azurecli', 'Enable-WindowsServerSubscription.azcli.ps1')
        $global:K6Benchmark = '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
    }
    BeforeEach {
        Reset-K6
        Mock az { & $global:K6AzBody @($args) }
    }

    Context 'Enable-DefenderForCloud.azcli.ps1' {
        BeforeEach { Set-K6Empty 'Enable-DefenderForCloud' }
        It 'registers Microsoft.Security, assigns the benchmark to the subscription and sets the security contact, and nothing paid' {
            $r = Invoke-K6 $script:Defender (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-K6Call 'provider register')[0].Options['--namespace'] | Should -Be 'Microsoft.Security'
            $a = (Get-K6Call 'policy assignment create')[0]
            $a.Options['--name'] | Should -Be 'SecurityCenterBuiltIn'
            $a.Options['--scope'] | Should -Be "/subscriptions/$($global:K6Sub)"
            $a.Options['--policy-set-definition'] | Should -Be $global:K6Benchmark
            $c = (Get-K6Call 'security contact create')[0]
            $c.Options['--name'] | Should -Be 'default'
            $c.Options['--emails'] | Should -Be 'security@improbability.cloud'
            @($global:K6Calls.Command | Where-Object { $_ -like 'security pricing*' -or $_ -like '*auto-provisioning*' }) | Should -BeNullOrEmpty
            @($global:K6Calls | Where-Object { & $script:IsChange $_ } | ForEach-Object Command | Sort-Object -Unique) | Should -Be @('policy assignment create', 'provider register', 'security contact create')
        }
        It 'changes nothing when every item is in place, and never replaces a contact that exists' {
            $global:K6Handlers['provider show'] = { param($o, $a) 'Registered' }
            $global:K6Handlers['rest'] = { param($o, $a) New-K6PolicyList (('[{"name":"other","scope":"/providers/Microsoft.Management/managementGroups/mg-example","policyDefinitionId":"' + $global:K6Benchmark + '"}]')) }
            $global:K6Handlers['security contact show'] = { param($o, $a) '{"name":"default"}' }
            $r = Invoke-K6 $script:Defender (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('Exists', 'Exists', 'Exists')
            Get-K6Change | Should -BeNullOrEmpty
            # Lab run 2026-11-23: az policy assignment list missed the benchmark assigned at a management group; the ARM list of the subscription has it.
            $list = @(Get-K6Call 'rest')
            $list.Count | Should -Be 1
            "$($list[0].Options['--method'])" | Should -Be 'get'
            "$($list[0].Options['--url'])" | Should -Be "/subscriptions/$($global:K6Sub)/providers/Microsoft.Authorization/policyAssignments?api-version=2023-04-01"
            $global:K6Calls.Command | Should -Not -Contain 'policy assignment list'
        }
        It 'stops the benchmark item, assigning nothing, when the list of assignments has a second page' {
            $global:K6Handlers['provider show'] = { param($o, $a) 'Registered' }
            $global:K6Handlers['rest'] = { param($o, $a) '{"value":[],"nextLink":"https://example.invalid/next"}' }
            $global:K6Handlers['security contact show'] = { param($o, $a) '{"name":"default"}' }
            $r = Invoke-K6 $script:Defender (New-K6Infra)
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Item -EQ 'Cloud security benchmark').Action | Should -Be 'Failed'
            (Get-K6Call 'policy assignment create').Count | Should -Be 0
        }
        It 'does not count the assignment of a resource group of the subscription' {
            $global:K6Handlers['provider show'] = { param($o, $a) 'Registered' }
            $global:K6Handlers['rest'] = { param($o, $a) New-K6PolicyList (('[{"name":"rgonly","scope":"/subscriptions/' + $global:K6Sub + '/resourceGroups/rg-example-01","policyDefinitionId":"' + $global:K6Benchmark + '"}]')) }
            $r = Invoke-K6 $script:Defender (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-K6Call 'policy assignment create').Count | Should -Be 1
        }
        It 'ends with exit code 2 and never overwrites an assignment with the name of Defender for Cloud that points elsewhere' {
            $global:K6Handlers['provider show'] = { param($o, $a) 'Registered' }
            $global:K6Handlers['rest'] = { param($o, $a) New-K6PolicyList (('[{"name":"SecurityCenterBuiltIn","scope":"/subscriptions/' + $global:K6Sub + '","policyDefinitionId":"/providers/Microsoft.Authorization/policySetDefinitions/other"}]')) }
            (Invoke-K6 $script:Defender (New-K6Infra)).ExitCode | Should -Be 2
            Get-K6Change | Should -BeNullOrEmpty
        }
        It 'stops with exit code 2 on a name conflict before it registers the provider or changes anything, when the provider is not registered' {
            $global:K6Handlers['provider show'] = { param($o, $a) 'NotRegistered' }
            $global:K6Handlers['rest'] = { param($o, $a) New-K6PolicyList (('[{"name":"SecurityCenterBuiltIn","scope":"/subscriptions/' + $global:K6Sub + '","policyDefinitionId":"/providers/Microsoft.Authorization/policySetDefinitions/other"}]')) }
            (Invoke-K6 $script:Defender (New-K6Infra)).ExitCode | Should -Be 2
            Get-K6Change | Should -BeNullOrEmpty
            (Get-K6Call 'provider register').Count | Should -Be 0
            (Get-K6Call 'provider show').Count | Should -Be 0
        }
        It 'does not count an assignment of the same name at a management group above as a conflict: it is another scope' {
            $global:K6Handlers['provider show'] = { param($o, $a) 'Registered' }
            $global:K6Handlers['rest'] = { param($o, $a) New-K6PolicyList ('[{"name":"SecurityCenterBuiltIn","scope":"/providers/Microsoft.Management/managementGroups/mg-example","policyDefinitionId":"/providers/Microsoft.Authorization/policySetDefinitions/other"}]') }
            $r = Invoke-K6 $script:Defender (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-K6Call 'policy assignment create').Count | Should -Be 1
        }
        It 'does nothing when the file turns it off, skips the benchmark and the contact when the file says so, and rejects a bad address' {
            (Invoke-K6 $script:Defender (New-K6Infra @{ 'security.defender_for_cloud.enabled' = $false })).ExitCode | Should -Be 0
            $global:K6Calls.Count | Should -Be 0
            $r = Invoke-K6 $script:Defender (New-K6Infra @{ 'security.defender_for_cloud.apply_cloud_security_benchmark' = $false; 'security.defender_for_cloud.security_contact_email' = $null })
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('Registered', 'Skipped', 'Skipped')
            (Invoke-K6 $script:Defender (New-K6Infra @{ 'security.defender_for_cloud.security_contact_email' = 'nope' })).ExitCode | Should -Be 2
        }
    }

    Context 'Invoke-AzurePolicyTier1-Orchestrated.azcli.ps1' {
        BeforeEach { Set-K6Empty 'Invoke-AzurePolicyTier1-Orchestrated' }
        It 'assigns the built-in tag policy once per tag at the management group, in audit mode, with a body file that is deleted again' {
            $r = Invoke-K6 $script:Policy (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $creates = Get-K6Call 'rest'
            $creates.Count | Should -Be 2
            $mg = '/providers/Microsoft.Management/managementGroups/mg-example/providers/Microsoft.Authorization/policyAssignments'
            @($creates | ForEach-Object { $_.Options['--url'][0] }) | Should -Be @("$mg/req-tag-costcenter?api-version=2023-04-01", "$mg/req-tag-owner?api-version=2023-04-01")
            @($creates | ForEach-Object { $_.Options['--method'][0] } | Select-Object -Unique) | Should -Be 'put'
            $first = ($global:K6Params[0] | ConvertFrom-Json).properties
            $first.policyDefinitionId | Should -Be '/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99'
            $first.enforcementMode | Should -Be 'DoNotEnforce'
            $first.parameters.tagName.value | Should -Be 'costcenter'
            $first.displayName | Should -Match 'costcenter'
            ($global:K6Params[1] | ConvertFrom-Json).properties.parameters.tagName.value | Should -Be 'owner'
            Test-Path -LiteralPath (([string]$creates[0].Options['--body'][0]).TrimStart('@')) | Should -BeFalse
        }
        It 'never uses az policy assignment create, which fails for a built-in definition at a management group scope (Azure CLI 2.90, lab run 2026-11-23)' {
            $global:K6Handlers['policy assignment create'] = { param($o, $a) New-K6Error "(PolicyDefinitionNotFound) The policy definition '871b6d14-10aa-478d-b590-94f262ecfa99' could not be found." 1 }
            $r = Invoke-K6 $script:Policy (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-K6Call 'policy assignment create' | Should -BeNullOrEmpty
            (Get-K6Call 'rest').Count | Should -Be 2
        }
        It 'uses the tenant root management group when the file names none' {
            $null = Invoke-K6 $script:Policy (New-K6Infra @{ 'landing_zone.policy.management_group' = $null })
            (Get-K6Call 'rest')[0].Options['--url'][0] | Should -BeLike "/providers/Microsoft.Management/managementGroups/$($global:K6Tenant)/providers/Microsoft.Authorization/policyAssignments/*"
        }
        It 'leaves an assignment that exists alone, and reports a name taken by another assignment as a conflict with exit code 1' {
            $global:K6Handlers['policy assignment show'] = { param($o, $a) '{"name":"x","policyDefinitionId":"/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99","enforcementMode":"DoNotEnforce","parameters":{"tagName":{"value":"' + $(if ($o['--name'][0] -eq 'req-tag-owner') { 'owner' } else { 'costcenter' }) + '"}}}' }
            $r = Invoke-K6 $script:Policy (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-K6Change | Should -BeNullOrEmpty
            $global:K6Handlers['policy assignment show'] = { param($o, $a) '{"name":"x","policyDefinitionId":"/providers/Microsoft.Authorization/policyDefinitions/other","enforcementMode":"Default"}' }
            $r2 = Invoke-K6 $script:Policy (New-K6Infra)
            $r2.ExitCode | Should -Be 1
            @(($r2.Objects | Where-Object { $_.PSObject.Properties['Assignments'] }).Assignments.Action | Select-Object -Unique) | Should -Be 'Conflict'
        }
        It 'ends with exit code 2 for no tag, a bad management group, or two tags with one assignment name' {
            foreach ($set in @{ 'landing_zone.policy.required_tags' = $null }, @{ 'landing_zone.policy.management_group' = '-bad' }, @{ 'landing_zone.policy.required_tags' = @('Cost Center', 'cost-center') }) {
                (Invoke-K6 $script:Policy (New-K6Infra $set)).ExitCode | Should -Be 2 -Because ($set.Keys -join ',')
            }
            $global:K6Calls.Count | Should -Be 0
        }
    }

    Context 'Enable-AzureHybridBenefit.azcli.ps1' {
        BeforeEach { Set-K6Empty 'Enable-AzureHybridBenefit' }
        It 'activates the benefit with the Enable intent and reads the status again' {
            $r = Invoke-K6 $script:Benefit (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $c = (Get-K6Call 'stack-hci cluster extend-software-assurance-benefit')
            $c.Count | Should -Be 1
            $c[0].Options['--cluster-name'] | Should -Be 'azl-example-01'
            $c[0].Options['--resource-group'] | Should -Be 'rg-example-01'
            $c[0].Options['--software-assurance-intent'] | Should -Be 'Enable'
            $r.Rows[0].Status | Should -Be 'Enabled'
        }
        It 'does nothing when the benefit is already Enabled or the file does not ask for it' {
            $global:K6Handlers['stack-hci cluster show'] = { param($o, $a) '{"name":"azl-example-01","softwareAssuranceProperties":{"softwareAssuranceStatus":"Enabled"}}' }
            $r = Invoke-K6 $script:Benefit (New-K6Infra)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyEnabled'
            Get-K6Change | Should -BeNullOrEmpty
            Reset-K6
            (Invoke-K6 $script:Benefit (New-K6Infra @{ 'operations.licensing.azure_hybrid_benefit' = $false })).ExitCode | Should -Be 0
            $global:K6Calls.Count | Should -Be 0
        }
        It 'ends with exit code 2 and sends nothing for a SAN or hybrid instance or a disconnected one, and 1 when the instance does not exist' {
            foreach ($set in @{ 'scenario.storage_architecture' = 'san' }, @{ 'scenario.storage_architecture' = 'hybrid' }, @{ 'scenario.connectivity' = 'disconnected' }, @{ 'operations.licensing.azure_hybrid_benefit' = 'yes please' }) {
                (Invoke-K6 $script:Benefit (New-K6Infra $set)).ExitCode | Should -Be 2 -Because ($set.Keys -join ',')
            }
            $global:K6Calls.Count | Should -Be 0
            $global:K6Handlers['stack-hci cluster show'] = { param($o, $a) New-K6NotFound }
            (Invoke-K6 $script:Benefit (New-K6Infra)).ExitCode | Should -Be 1
        }
    }

    Context 'Enable-WindowsServerSubscription.azcli.ps1' {
        BeforeEach { Set-K6Empty 'Enable-WindowsServerSubscription' }
        It 'turns the add-on on with the desired property of Learn and reads the instance again' {
            $r = Invoke-K6 $script:Subscription (New-K6Infra)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $c = Get-K6Call 'stack-hci cluster update'
            $c.Count | Should -Be 1
            $c[0].Options['--name'] | Should -Be 'azl-example-01'
            $c[0].Options['--desired-properties'] | Should -Be 'windows-server-subscription=Enabled'
            $r.Rows[0].State | Should -Be 'Enabled'
        }
        It 'does nothing when the add-on is Enabled or the file does not ask for it, and refuses a disconnected instance with exit code 2' {
            $global:K6Handlers['stack-hci cluster show'] = { param($o, $a) '{"name":"azl-example-01","desiredProperties":{"windowsServerSubscription":"Enabled"}}' }
            $r = Invoke-K6 $script:Subscription (New-K6Infra)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyEnabled'
            Get-K6Change | Should -BeNullOrEmpty
            Reset-K6
            (Invoke-K6 $script:Subscription (New-K6Infra @{ 'operations.licensing.windows_server_subscription' = $null })).ExitCode | Should -Be 0
            (Invoke-K6 $script:Subscription (New-K6Infra @{ 'scenario.connectivity' = 'disconnected' })).ExitCode | Should -Be 2
            $global:K6Calls.Count | Should -Be 0
        }
    }
}

Describe 'Test-SecurityCompliance.azcli.ps1' {
    BeforeAll { $script:S = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '06-testing-validation', 'task-05-security-compliance-validation', 'azurecli', 'Test-SecurityCompliance.azcli.ps1') }
    BeforeEach {
        Reset-K6
        Mock az { & $global:K6AzBody @($args) }
        $global:K6Handlers['provider show'] = { param($o, $a) 'Registered' }
        $global:K6Handlers['rest'] = { param($o, $a) New-K6PolicyList ('[{"name":"SecurityCenterBuiltIn","scope":"/subscriptions/x","policyDefinitionId":"/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8"}]') }
        $global:K6Handlers['role assignment list'] = { param($o, $a) '[{"roleDefinitionName":"Owner"},{"roleDefinitionName":"Contributor"},{"roleDefinitionName":"Contributor"}]' }
        $global:K6Handlers['policy state list'] = { param($o, $a) "Compliant`nCompliant`nNonCompliant" }
    }

    It 'passes with exit code 0, only reads, and asks for the resource group of the file' {
        $r = Invoke-K6 $script:S (New-K6Infra)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Get-K6Change | Should -BeNullOrEmpty
        (Get-K6Call 'role assignment list')[0].Options['--scope'] | Should -Be "/subscriptions/$($global:K6Sub)/resourceGroups/rg-example-01"
        (Get-K6Call 'policy state list')[0].Options['--resource-group'] | Should -Be 'rg-example-01'
        $r.Text | Should -Match 'NonCompliant: 1'
        $global:K6Calls.Command | Should -Not -Contain 'security pricing list'
    }

    It 'ends with exit code 1 when the free Defender for Cloud level is not in place' {
        $global:K6Handlers['provider show'] = { param($o, $a) 'NotRegistered' }
        (Invoke-K6 $script:S (New-K6Infra)).ExitCode | Should -Be 1
        $global:K6Handlers['provider show'] = { param($o, $a) 'Registered' }
        $global:K6Handlers['rest'] = { param($o, $a) New-K6PolicyList ('[]') }
        (Invoke-K6 $script:S (New-K6Infra)).ExitCode | Should -Be 1
    }

    It 'does not run the Defender checks the file turns off' {
        $global:K6Handlers['provider show'] = { param($o, $a) 'NotRegistered' }
        (Invoke-K6 $script:S (New-K6Infra @{ 'security.defender_for_cloud.enabled' = $false })).ExitCode | Should -Be 0
        $global:K6Calls.Command | Should -Not -Contain 'provider show'
        $global:K6Handlers['rest'] = { param($o, $a) New-K6PolicyList ('[]') }
        $global:K6Handlers['provider show'] = { param($o, $a) 'Registered' }
        (Invoke-K6 $script:S (New-K6Infra @{ 'security.defender_for_cloud.apply_cloud_security_benchmark' = $false })).ExitCode | Should -Be 0
    }

    It 'warns about more Owner assignments than the maximum and writes the report only when asked' {
        $global:K6Handlers['role assignment list'] = { param($o, $a) '[{"roleDefinitionName":"Owner"},{"roleDefinitionName":"Owner"},{"roleDefinitionName":"Owner"},{"roleDefinitionName":"Owner"}]' }
        $r = Invoke-K6 $script:S (New-K6Infra) @{ OutputPath = (Join-Path $TestDrive 'reports') }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Text | Should -Match '4 Owner assignments'
        @(Get-ChildItem -LiteralPath (Join-Path $TestDrive 'reports') -Filter '*.json').Count | Should -Be 1
        $r2 = Invoke-K6 $script:S (New-K6Infra) @{ MaximumOwnerAssignments = 4 }
        $r2.Text | Should -Not -Match 'Owner assignments \(recommended'
    }

    It 'ends with exit code 1 when an Azure read fails' {
        $global:K6Handlers['role assignment list'] = { param($o, $a) New-K6Error 'AuthorizationFailed' }
        (Invoke-K6 $script:S (New-K6Infra)).ExitCode | Should -Be 1
    }

    It 'ends with exit code 2 for a missing resource group' {
        (Invoke-K6 $script:S (New-K6Infra @{ 'azure.resource_group' = $null })).ExitCode | Should -Be 2
    }
}

Describe 'Invoke-TelemetryConfiguration-Orchestrated.azcli.ps1' {
    BeforeAll { $script:TelePath = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-05-licensing-telemetry', 'task-03-configure-enhanced-telemetry', 'azurecli', 'Invoke-TelemetryConfiguration-Orchestrated.azcli.ps1') }
    BeforeEach { Reset-K6; Mock az { & $global:K6AzBody @($args) }; Set-K6Empty 'Invoke-TelemetryConfiguration-Orchestrated' }

    It 'sends the level of the file as diagnostic-level of the desired properties' {
        $r = Invoke-K6 $script:TelePath (New-K6Infra)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-K6Option (Get-K6Call 'stack-hci cluster update')[0] '--desired-properties') | Should -Be @('diagnostic-level=Enhanced')
    }
    It 'changes nothing when the level is already the one of the file' {
        $global:K6Handlers['stack-hci cluster show'] = { param($o, $a) '{"name":"azl-example-01","desiredProperties":{"diagnosticLevel":"Enhanced"}}' }
        $r = Invoke-K6 $script:TelePath (New-K6Infra)
        $r.Rows[0].Action | Should -Be 'AlreadySet'
        Get-K6Change | Should -BeNullOrEmpty
    }
    It 'ends with exit code 2 for Full, and does nothing without the key' {
        (Invoke-K6 $script:TelePath (New-K6Infra @{ 'security.telemetry.diagnostic_level' = 'Full' })).ExitCode | Should -Be 2
        (Invoke-K6 $script:TelePath (New-K6Infra @{ 'security.telemetry.diagnostic_level' = $null })).ExitCode | Should -Be 0
        $global:K6Calls.Count | Should -Be 0
    }
}

Describe 'Invoke-SecurityLogging-Orchestrated.azcli.ps1' {
    BeforeAll { $script:SlPath = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-04-security-governance', 'task-04-enable-security-logging', 'azurecli', 'Invoke-SecurityLogging-Orchestrated.azcli.ps1') }
    BeforeEach { Reset-K6; Mock az { & $global:K6AzBody @($args) }; Set-K6Empty 'Invoke-SecurityLogging-Orchestrated'; $global:K6Rules = $null }

    It 'creates the rule from a file with the queries of the file, and associates every node' {
        $r = Invoke-K6 $script:SlPath (New-K6Infra)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $q = @($global:K6Rules.properties.dataSources.windowsEventLogs[0].xPathQueries)
        $q | Should -Contain 'Security!*[System[(band(Keywords,13510798882111488))]]'
        $q | Should -Contain 'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
        $global:K6Rules.location | Should -Be 'westus2'
        $created = @(Get-K6Call 'monitor data-collection rule association create' | ForEach-Object { [string]@($_.Options['--resource'])[0] })
        $created.Count | Should -Be 2 -Because ($global:K6Calls.Command -join ', ')
        @($created | ForEach-Object { ($_ -split '/')[-1] }) | Should -Be @('node-a', 'arc-node-b') -Because ($created -join ' | ')
    }
    It 'fails, and associates no node, when the existing rule collects other queries' {
        $global:K6Handlers['monitor data-collection rule show'] = { param($o, $a) "{`"id`":`"r`",`"dataSources`":{`"windowsEventLogs`":[{`"xPathQueries`":[`"Security!*`"]}]},`"destinations`":{`"logAnalytics`":[{`"workspaceResourceId`":`"/subscriptions/$($global:K6Sub)/resourceGroups/rg-example-mon/providers/Microsoft.OperationalInsights/workspaces/law-example-01`"}]}}" }
        $r = Invoke-K6 $script:SlPath (New-K6Infra)
        $r.ExitCode | Should -Be 1
        Get-K6Change | Should -BeNullOrEmpty
    }
    It 'does nothing when security logging is off, and ends with exit code 2 when monitoring is off' {
        (Invoke-K6 $script:SlPath (New-K6Infra @{ 'operations.security_logging.enabled' = $false })).ExitCode | Should -Be 0
        (Invoke-K6 $script:SlPath (New-K6Infra @{ 'operations.monitoring.enabled' = $false })).ExitCode | Should -Be 2
        $global:K6Calls.Count | Should -Be 0
    }
}
