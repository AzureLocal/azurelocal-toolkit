# Helpers for the ARM deployment run tests. Dot-sourced inside BeforeAll. No test here touches Azure: every Azure call goes through
# the adapter, and the adapter is a fake with a fake clock.

function Get-TestInfra {
    <# The Fibre Channel fixture, reshaped: identity, storage, switchless or not, and any number of nodes. #>
    param(
        [ValidateSet('active_directory', 'local_identity')][string]$Identity = 'active_directory',
        [ValidateSet('s2d', 'san')][string]$Storage = 's2d',
        [switch]$Switchless,
        [int]$Nodes = 2
    )
    $infra = Import-AzlInfrastructure -Path $script:Fixture -SkipValidation
    $first = $infra.nodes[0]
    $list = for ($i = 1; $i -le $Nodes; $i++) {
        $n = ConvertFrom-Json ($first | ConvertTo-Json -Depth 20) -AsHashtable
        $n.name = 'iic-n{0:00}' -f $i
        $port = 0
        foreach ($p in $n.network_adapters) {
            $p.mac_address = '00:00:5E:00:{0:X2}:{1:X2}' -f $i, (0x10 + $port)
            if ($p.ip_address) { $p.ip_address = '192.0.2.{0}' -f (10 + $i) }
            $port++
        }
        $n
    }
    $infra.nodes = @($list)
    if ($Storage -eq 's2d') {
        $infra.scenario.storage_architecture = 's2d'
        $infra.Remove('storage'); $infra['storage'] = [ordered]@{ configuration_mode = 'express' }
        $infra.networking.Remove('cluster_networks')
        $infra.networking.intents = @(
            [ordered]@{ name = 'mgmt_compute'; traffic = @('management', 'compute'); adapters = @('Port0', 'Port1') }
            [ordered]@{ name = 'storage'; traffic = @('storage'); adapters = @('Port2', 'Port3') })
        $infra.networking['storage'] = [ordered]@{ auto_ip = $true; networks = @([ordered]@{ name = 'StorageNetwork1'; adapter = 'Port2'; vlan_id = 711 }, [ordered]@{ name = 'StorageNetwork2'; adapter = 'Port3'; vlan_id = 712 }) }
        foreach ($n in $infra.nodes) { $n.Remove('san') }
        if ($Switchless) { $infra.scenario.storage_connectivity = 'switchless' }
    }
    if ($Identity -eq 'local_identity') {
        $infra.scenario.identity = 'local_identity'
        $infra.identity.Remove('active_directory')
        $infra.identity.local_identity = [ordered]@{ dns_server_config = 'use_forwarder'; dns_zone = 'improbability.cloud'; dns_forwarders = @('192.0.2.4') }
    }
    $infra
}

function Get-TestOsReport {
    <# An OS configuration report (cluster report.json shape with the node report fields), every node converged. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infra, [string[]]$NotConverged = @(), [string]$Cluster)
    $nodes = foreach ($n in $Infra.nodes) {
        $ports = foreach ($p in $n.network_adapters) { [pscustomobject]@{ osName = $p.name; mac = ($p.mac_address -replace '[:-]', '').ToLowerInvariant(); status = 'Up' } }
        [pscustomobject]@{
            name = $n.name; converged = ($n.name -notin $NotConverged); status = 'ok'; osVersion = '10.0.26100.32230'
            planned = [pscustomobject]@{ changes = $(if ($n.name -in $NotConverged) { 2 } else { 0 }); blocked = 0 }
            errors = @(); plan = @(); ports = @($ports)
            sanDisks = @([pscustomobject]@{ lun = 0; uid = 'UID-INFRA'; sn = 'SN-INFRA'; gb = 300 }, [pscustomobject]@{ lun = 1; uid = 'UID-PERF'; sn = 'SN-PERF'; gb = 50 })
        }
    }
    [pscustomobject]@{ schemaVersion = 1; generatedUtc = '2026-11-07T11:00:00.0000000Z'; mode = 'Apply'; cluster = $(if ($Cluster) { $Cluster } else { $Infra.cluster.name }); exitCode = 0; nodes = @($nodes) }
}

function Get-TestStep {
    <# A flattened step as Get-AzlDeploymentState returns it. #>
    param([string]$Index, [string]$Name, [string]$Status = 'Success', [int]$Depth = 0, [string[]]$Errors = @(), [string]$End = '2026-11-07T12:30:00Z')
    [pscustomobject]@{ Depth = $Depth; Name = $Name; Status = $Status; Description = ''; FullStepIndex = $Index; StartTime = ''; EndTime = $End; Errors = @($Errors) }
}

function Get-TestState {
    <# A cluster resource's deploymentSettings as Get-AzlDeploymentState returns it. #>
    param([string]$Prov = 'Succeeded', [string]$Validation = '', [string]$Deployment = '', [object[]]$ValidationSteps = @(), [object[]]$DeploymentSteps = @())
    [pscustomobject]@{ ProvisioningState = $Prov; ValidationStatus = $Validation; ValidationSteps = @($ValidationSteps); DeploymentStatus = $Deployment; DeploymentSteps = @($DeploymentSteps) }
}

function Get-FakeWorld {
    <# The state of a pretend Azure: what the reads return before the submit and, poll by poll, after it. #>
    [pscustomobject]@{
        Clock = [pscustomobject]@{ Time = [datetime]::Parse('2026-11-07T12:00:00Z', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal); Sleeps = [System.Collections.Generic.List[double]]::new() }
        Before = $null; BeforeArm = @{}; After = @{}; ArmAfter = @{}; LastMode = '';  Polls = 0; Submitted = $false; SubmitCalls = [System.Collections.Generic.List[object]]::new()
        PreReads = 0; Nodes = @{}; SecretReads = [System.Collections.Generic.List[string]]::new(); Overrides = @{}; PollFailures = 0
        RegisteredProviders = [System.Collections.Generic.List[string]]::new()
    }
}

function Get-FakeAdapter {
    <# An adapter whose every member answers from the world. -Override replaces members. #>
    param([Parameter(Mandatory)]$World, [hashtable]$Override = @{})
    $w = $World
    $a = [ordered]@{
        Now = { $w.Clock.Time }.GetNewClosure()
        Sleep = { param($Seconds) $w.Clock.Sleeps.Add([double]$Seconds); $w.Clock.Time = $w.Clock.Time.AddSeconds([double]$Seconds) }.GetNewClosure()
        GetContext = { [pscustomobject]@{ SubscriptionId = '00000000-0000-0000-0000-000000000000'; TenantId = '00000000-0000-0000-0000-000000000000'; Account = 'tester@example.invalid' } }
        GetResourceGroup = { [pscustomobject]@{ name = 'rg-iic-azl-01' } }
        GetProviderState = { 'Registered' }
        RegisterProvider = { param($Subscription, $Namespace) $null = $Subscription; $w.RegisteredProviders.Add($Namespace) }.GetNewClosure()
        GetPermission = { , @([pscustomobject]@{ Actions = @('*'); NotActions = @() }) }
        TestNameAvailable = { [pscustomobject]@{ Available = $true; ExistsInResourceGroup = $false; Reason = '' } }
        TestSecret = { $true }
        GetSecret = { param($Reference) $w.SecretReads.Add($Reference); 'Sup3r-S3cret-Value!' }.GetNewClosure()
        GetHciResourceProviderObjectId = { '00000000-0000-0000-0000-000000000009' }
        GetArcMachine = {
            param($Node, $ResourceId, $ArcMachineName, $Subscription, $ResourceGroup)
            $null = $ResourceId, $ArcMachineName
            if ($w.Nodes.ContainsKey($Node)) { return $w.Nodes[$Node] }
            [pscustomobject]@{ Name = $Node; ResourceId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$Node"; Status = 'Connected'; OsVersion = '10.0.26100.32230'; ComputerName = $Node }
        }.GetNewClosure()
        GetDeploymentState = {
            if ($w.PreReads -gt 0) { $w.PreReads--; return $w.Before }
            if (-not $w.Submitted) { return $w.Before }
            if ($w.PollFailures -gt 0) { $w.PollFailures--; throw 'HTTP 503 from ARM' }
            $list = $w.After[$w.LastMode]
            if (-not $list) { return $w.Before }
            $i = [math]::Min($w.Polls, @($list).Count - 1)
            $w.Polls++
            @($list)[$i]
        }.GetNewClosure()
        GetArmDeployment = {
            param($Subscription, $ResourceGroup, $Name)
            $null = $Subscription, $ResourceGroup
            $kind = if ($Name -like 'azl-validate*') { 'validate' } else { 'deploy' }
            if (-not $w.Submitted -or ($kind -eq 'deploy' -and $w.LastMode -ne 'deploy')) { return $w.BeforeArm[$Name] }
            $list = $w.ArmAfter[$kind]
            if (-not $list) { return $w.BeforeArm[$Name] }
            $i = if ($kind -eq $w.LastMode) { [math]::Min($w.Polls, @($list).Count - 1) } else { @($list).Count - 1 }
            @($list)[$i]
        }.GetNewClosure()
        GetTemplate = { @{ '$schema' = 'x'; parameters = @{}; resources = @() } }
        Submit = {
            param($Arguments)
            $resolved = @{}
            foreach ($k in $Arguments.ParameterSet.Parameters.Keys) {
                $v = $Arguments.ParameterSet.Parameters[$k]
                if ($v -is [System.Collections.IDictionary] -and $v.Contains('KeyVault')) { $resolved[$k] = & $Arguments.SecretResolver $v.KeyVault }
            }
            $w.SubmitCalls.Add([pscustomobject]@{ Mode = $Arguments.Mode; DeploymentName = $Arguments.DeploymentName; SkipValidationCheck = [bool]$Arguments.SkipValidationCheck; SecretKeys = @($resolved.Keys); Time = $w.Clock.Time })
            $w.Submitted = $true; $w.Polls = 0; $w.LastMode = $Arguments.Mode.ToLowerInvariant()
        }.GetNewClosure()
        ResolveDns = { $true }
        TestActiveDirectory = { [pscustomobject]@{ OuExists = $true; LcmUserExists = $true } }
        ProbeOsConfiguration = $null
        Prompt = { $true }
    }
    foreach ($k in $Override.Keys) { $a[$k] = $Override[$k] }
    $a
}

function Invoke-TestRun {
    <# Runs the module's run with a fake adapter. Returns the result. #>
    param(
        [Parameter(Mandatory)]$World, [System.Collections.IDictionary]$Infra, [string]$Mode = 'Plan', [object]$OsReport, [hashtable]$Settings = @{}, [string]$Dir,
        [switch]$Resume, [switch]$AutoApprove, [switch]$DryRun, [hashtable]$Override = @{}, [string]$Handoff
    )
    if (-not $Infra) { $Infra = Get-TestInfra }
    if (-not $Dir) { $Dir = Join-Path $TestDrive ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
    if (-not $PSBoundParameters.ContainsKey('OsReport')) { $OsReport = Get-TestOsReport -Infra $Infra }
    $arguments = @{ Infrastructure = $Infra; Mode = $Mode; ReportDirectory = $Dir; Settings = $Settings; Adapter = (Get-FakeAdapter -World $World -Override $Override); TemplateFile = $script:TemplateFile }
    if ($OsReport) { $arguments.OsConfigurationReport = $OsReport }
    if ($Handoff) { $arguments.HandoffFile = $Handoff }
    if ($Resume) { $arguments.Resume = $true }
    if ($AutoApprove) { $arguments.AutoApprove = $true }
    if ($DryRun) { $arguments.WhatIf = $true }
    Invoke-AzlArmDeploymentRun @arguments
}

function Read-TestEvent([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
