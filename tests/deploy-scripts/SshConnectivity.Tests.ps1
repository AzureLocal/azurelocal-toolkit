#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 04: Invoke-SSHConnectivity-Orchestrated.ps1 reads the machines from nodes[] and their Arc machine names from
# nodes[].arc_machine_name (the node name when the file gives none), in azure.resource_group of azure.subscription_id, and turns SSH on through Azure Arc:
# the WindowsOpenSSH extension, the HybridConnectivity default endpoint and the SSH service configuration, then checks the result. Every Az cmdlet is a
# fake: no Azure, no node, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/SshConnectivity.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-04-ssh-connectivity-to-nodes', 'powershell', 'Invoke-SSHConnectivity-Orchestrated.ps1')
    Import-Module powershell-yaml
    $global:AzlSshTenant = [guid]::NewGuid().ToString()
    $global:AzlSshSub = [guid]::NewGuid().ToString()

    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function Register-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function Get-AzConnectedMachine { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function Get-AzConnectedMachineExtension { [CmdletBinding()] param([string]$MachineName, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Name) }
    function New-AzConnectedMachineExtension { [CmdletBinding()] param([string]$Name, [string]$MachineName, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$Publisher, [string]$ExtensionType) }
    function Invoke-AzRestMethod { [CmdletBinding()] param([string]$Method, [string]$Path, [string]$Payload) }
    function Test-NetConnection { [CmdletBinding()] param([string]$ComputerName, [int]$Port, [string]$InformationLevel) }

    function New-InfraFile {
        param([object[]]$Nodes = @([ordered]@{ name = 'iic-node-a' }, [ordered]@{ name = 'iic-node-b'; arc_machine_name = 'iic-arc-b' }), [hashtable]$Azure = @{})
        $az = [ordered]@{ tenant_id = $global:AzlSshTenant; subscription_id = $global:AzlSshSub; resource_group = 'rg-iic-azl-01'; location = 'westeurope' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{ azure = $az; nodes = @($Nodes) }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-World {
        $global:AzlSshCalls = [System.Collections.Generic.List[object]]::new()
        # per Arc machine: the extension state ('' = none); one endpoint and one service configuration port ($null = none) for all machines
        $global:AzlSshWorld = @{ Provider = 'Registered'; Machines = @{}; Status = 'Connected'; Endpoint = $false; Port = $null }
    }
    function Invoke-Ssh([string]$File, [hashtable]$Extra = @{}, [switch]$Plan) {
        $global:LASTEXITCODE = $null
        $all = if ($Plan) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Name) { @($global:AzlSshCalls | Where-Object Name -EQ $Name) }
}

Describe 'Invoke-SSHConnectivity-Orchestrated.ps1' {
    AfterAll { Remove-Variable -Name AzlSshTenant, AzlSshSub, AzlSshCalls, AzlSshWorld -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-World
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlSshTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlSshSub } } }
        Mock Set-AzContext { }
        Mock Get-AzResourceProvider { [pscustomobject]@{ RegistrationState = $global:AzlSshWorld.Provider } }
        Mock Register-AzResourceProvider { $global:AzlSshCalls.Add([pscustomobject]@{ Name = 'Register'; Arguments = @() }); $global:AzlSshWorld.Provider = 'Registered' }
        Mock Get-AzConnectedMachine {
            $global:AzlSshCalls.Add([pscustomobject]@{ Name = 'GetMachine'; Arguments = @($Name, $ResourceGroupName, $SubscriptionId) })
            [pscustomobject]@{ Name = $Name; Status = $global:AzlSshWorld.Status; Location = 'westeurope' }
        }
        Mock Get-AzConnectedMachineExtension {
            $state = [string]$global:AzlSshWorld.Machines[$MachineName]
            if (-not $state) { throw "(ResourceNotFound) The Resource 'Microsoft.HybridCompute/machines/$MachineName/extensions/$Name' was not found." }
            [pscustomobject]@{ Name = $Name; ProvisioningState = $state }
        }
        Mock New-AzConnectedMachineExtension {
            $global:AzlSshCalls.Add([pscustomobject]@{ Name = 'NewExtension'; Arguments = @($Name, $MachineName, $ResourceGroupName, $SubscriptionId, $Location, $Publisher, $ExtensionType) })
            $global:AzlSshWorld.Machines[$MachineName] = 'Succeeded'
        }
        Mock Invoke-AzRestMethod {
            $global:AzlSshCalls.Add([pscustomobject]@{ Name = "Rest$Method"; Arguments = @($Path, $Payload) })
            if ($Method -eq 'PUT') {
                if ($Path -match 'serviceconfigurations/SSH') { $global:AzlSshWorld.Port = [int](($Payload | ConvertFrom-Json).properties.port) } else { $global:AzlSshWorld.Endpoint = $true }
                return [pscustomobject]@{ StatusCode = 200; Content = $Payload }
            }
            if ($Path -match 'serviceconfigurations/SSH') {
                if ($null -eq $global:AzlSshWorld.Port) { return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NotFound"}}' } }
                return [pscustomobject]@{ StatusCode = 200; Content = ('{"properties":{"serviceName":"SSH","port":' + $global:AzlSshWorld.Port + ',"resourceProvisioningState":"Succeeded"}}') }
            }
            if (-not $global:AzlSshWorld.Endpoint) { return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NotFound"}}' } }
            [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"type":"default","provisioningState":"Succeeded"}}' }
        }
        Mock Test-NetConnection { $true }
    }

    Context 'the nodes and their Arc machines' {
        It 'creates the extension, the endpoint and the SSH service for every machine of nodes[], in azure.resource_group of azure.subscription_id, then checks them' {
            $r = Invoke-Ssh (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'NewExtension').Count | Should -Be 2
            $first = (Get-Call 'NewExtension')[0].Arguments
            $first[0] | Should -Be 'WindowsOpenSSH'
            $first[2] | Should -Be 'rg-iic-azl-01'
            $first[3] | Should -Be $global:AzlSshSub
            $first[4] | Should -Be 'westeurope'
            $first[5] | Should -Be 'Microsoft.Azure.OpenSSH'
            $first[6] | Should -Be 'WindowsOpenSSH'
            # the endpoint and the service configuration are shared in this fake, so the second machine finds them: 2 writes for the first machine
            $put = @(Get-Call 'RestPUT')
            $put.Count | Should -BeGreaterOrEqual 2
            $put[0].Arguments[0] | Should -Match "subscriptions/$($global:AzlSshSub)/resourceGroups/rg-iic-azl-01/providers/Microsoft\.HybridCompute/machines/iic-node-a/providers/Microsoft\.HybridConnectivity/endpoints/default\?api-version=2023-03-15"
            $put[1].Arguments[0] | Should -Match 'serviceconfigurations/SSH\?api-version=2023-03-15'
            ($put[1].Arguments[1] | ConvertFrom-Json).properties.port | Should -Be 22
            @($r.Rows | Where-Object Action -EQ 'Verified').Count | Should -Be 2
        }

        It 'names the Arc machine by nodes[].arc_machine_name and falls back to the node name' {
            $null = Invoke-Ssh (New-InfraFile)
            $names = @((Get-Call 'GetMachine') | ForEach-Object { $_.Arguments[0] })
            $names | Should -Contain 'iic-arc-b'
            $names | Should -Contain 'iic-node-a'
            $names | Should -Not -Contain 'iic-node-b'
        }

        It 'limits the run to the nodes named by -TargetNode (by node name)' {
            $null = Invoke-Ssh (New-InfraFile) @{ TargetNode = 'iic-node-b' }
            (Get-Call 'GetMachine').Count | Should -Be 1
            (Get-Call 'GetMachine')[0].Arguments[0] | Should -Be 'iic-arc-b'
        }

        It 'stops with exit code 2 when -TargetNode matches no node, and sends nothing to Azure' {
            $r = Invoke-Ssh (New-InfraFile) @{ TargetNode = 'iic-node-z' }
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'matches no node'
            $global:AzlSshCalls.Count | Should -Be 0
        }

        It 'stops with exit code 2 when azure.resource_group, azure.subscription_id or azure.tenant_id is missing' {
            (Invoke-Ssh (New-InfraFile -Azure @{ resource_group = $null })).ExitCode | Should -Be 2
            (Invoke-Ssh (New-InfraFile -Azure @{ subscription_id = $null })).ExitCode | Should -Be 2
            (Invoke-Ssh (New-InfraFile -Azure @{ tenant_id = $null })).ExitCode | Should -Be 2
            $global:AzlSshCalls.Count | Should -Be 0
        }
    }

    Context 'idempotence, and the check after' {
        It 'writes nothing the second time: the extension, the endpoint and the service configuration are AlreadyDone' {
            $file = New-InfraFile
            Reset-World; $global:AzlSshWorld.Machines = @{ 'iic-node-a' = 'Succeeded'; 'iic-arc-b' = 'Succeeded' }; $global:AzlSshWorld.Endpoint = $true; $global:AzlSshWorld.Port = 22
            $r = Invoke-Ssh $file
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'NewExtension').Count | Should -Be 0
            (Get-Call 'RestPUT').Count | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'AlreadyDone').Count | Should -BeGreaterThan 5
        }

        It 'writes the service configuration again when the port differs, and the check reads it back' {
            $global:AzlSshWorld.Machines = @{ 'iic-node-a' = 'Succeeded' }; $global:AzlSshWorld.Endpoint = $true; $global:AzlSshWorld.Port = 2222
            $r = Invoke-Ssh (New-InfraFile -Nodes @([ordered]@{ name = 'iic-node-a' }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'RestPUT').Count | Should -Be 1
            $global:AzlSshWorld.Port | Should -Be 22
        }

        It 'fails (exit 1) when the Arc machine is not Connected' {
            $global:AzlSshWorld.Status = 'Disconnected'
            $r = Invoke-Ssh (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'not Connected'
            (Get-Call 'NewExtension').Count | Should -Be 0
        }

        It 'fails (exit 1) when the Arc machine is not in the resource group' {
            Mock Get-AzConnectedMachine { throw "(ResourceNotFound) The Resource 'Microsoft.HybridCompute/machines/x' was not found." }
            $r = Invoke-Ssh (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'does not exist'
        }

        It 'registers the provider when it is not, and waits for Registered' {
            $global:AzlSshWorld.Provider = 'NotRegistered'
            $r = Invoke-Ssh (New-InfraFile) @{ PollSeconds = 1 }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'Register').Count | Should -Be 1
        }

        It 'does not register the provider under -WhatIf' {
            $global:AzlSshWorld.Provider = 'NotRegistered'
            $r = Invoke-Ssh (New-InfraFile) -Plan
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'Register').Count | Should -Be 0
            (Get-Call 'NewExtension').Count | Should -Be 0
            (Get-Call 'RestPUT').Count | Should -Be 0
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'reads no key of the old layout and no Arc resource id' {
            $script:Text | Should -Not -Match 'cluster_nodes|arc_resource_id|ConvertFrom-Yaml|compute\.'
            $script:Text | Should -Match 'Get-AzlInfrastructureNode'
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'nodes[].name', 'nodes[].arc_machine_name', 'nodes[].management.ip_address' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Invoke_SSHConnectivity_Orchestrated_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }
    }
}
