#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 04: Invoke-SSHConnectivity-Orchestrated.ps1 reads the machines from nodes[] and their Arc machine names from
# nodes[].arc_machine_name (the node name when the file gives none), in azure.resource_group of azure.subscription_id. It is run with -WhatIf and
# the Azure CLI (az) is a stub: no Azure, no node, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/SshConnectivity.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Azure CLI.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-04-ssh-connectivity-to-nodes', 'powershell', 'Invoke-SSHConnectivity-Orchestrated.ps1')
    Import-Module powershell-yaml
    $script:Sub = [guid]::NewGuid().ToString()

    # The Azure CLI is a stub that answers like a signed-in session; -WhatIf makes no other call.
    function az { $global:LASTEXITCODE = 0; 'stub-answer' }

    function New-InfraFile {
        param([object[]]$Nodes = @([ordered]@{ name = 'iic-node-a' }, [ordered]@{ name = 'iic-node-b'; arc_machine_name = 'iic-arc-b' }), [hashtable]$Azure = @{})
        $az = [ordered]@{ subscription_id = $script:Sub; resource_group = 'rg-iic-azl-01'; location = 'westeurope' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{ azure = $az; nodes = @($Nodes) }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Ssh([string]$File, [string[]]$TargetNode = @()) {
        $log = Join-Path $TestDrive 'logs' ("ssh-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log")
        $arguments = @{ ConfigPath = $File; LogPath = $log; WhatIf = $true }
        if ($TargetNode.Count) { $arguments.TargetNode = $TargetNode }
        $failure = $null
        $all = try { & $script:Script @arguments 6>&1 3>&1 2>&1 } catch { $failure = $_.Exception.Message; @() }
        [pscustomobject]@{ Failure = $failure; Text = (@($all | ForEach-Object { "$_" }) -join "`n"); Log = $(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }) }
    }
}

Describe 'Invoke-SSHConnectivity-Orchestrated.ps1' {
    Context 'the nodes and their Arc machines' {
        It 'plans the extension, the endpoint and the SSH service for every machine of nodes[], in azure.resource_group of azure.subscription_id' {
            $r = Invoke-Ssh (New-InfraFile)
            $r.Failure | Should -BeNullOrEmpty -Because $r.Text
            $r.Log | Should -Match 'Node: iic-node-a \| Arc machine: iic-node-a \| RG: rg-iic-azl-01'
            $r.Log | Should -Match "subscriptions/$($script:Sub)/resourceGroups/rg-iic-azl-01/providers/Microsoft\.HybridCompute/machines/iic-node-a/providers/Microsoft\.HybridConnectivity/endpoints/default\?"
            $r.Log | Should -Match 'serviceconfigurations/SSH'
            ([regex]::Matches($r.Log, 'Would deploy WindowsOpenSSH')).Count | Should -Be 2
        }

        It 'names the Arc machine by nodes[].arc_machine_name and falls back to the node name' {
            $r = Invoke-Ssh (New-InfraFile)
            $r.Log | Should -Match 'Node: iic-node-b \| Arc machine: iic-arc-b'
            $r.Log | Should -Match 'machines/iic-arc-b/providers'
            $r.Log | Should -Not -Match 'machines/iic-node-b/providers'
        }

        It 'limits the run to the nodes named by -TargetNode (by node name)' {
            $r = Invoke-Ssh (New-InfraFile) -TargetNode 'iic-node-b'
            $r.Log | Should -Match 'Node: iic-node-b'
            $r.Log | Should -Not -Match 'Node: iic-node-a'
        }

        It 'exits quietly when no node matches' {
            $r = Invoke-Ssh (New-InfraFile) -TargetNode 'iic-node-z'
            $r.Failure | Should -BeNullOrEmpty
            $r.Log | Should -Match 'No matching nodes'
        }

        It 'stops when azure.resource_group or azure.subscription_id is missing' {
            (Invoke-Ssh (New-InfraFile -Azure @{ resource_group = $null })).Failure | Should -Match 'azure\.subscription_id or azure\.resource_group is missing'
            (Invoke-Ssh (New-InfraFile -Azure @{ subscription_id = $null })).Failure | Should -Match 'azure\.subscription_id or azure\.resource_group is missing'
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

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.subscription_id', 'azure.resource_group', 'azure.location', 'nodes[].name', 'nodes[].arc_machine_name' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Invoke_SSHConnectivity_Orchestrated_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'ConfigPath'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }
    }
}
