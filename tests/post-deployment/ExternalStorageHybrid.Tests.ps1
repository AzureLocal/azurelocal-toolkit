#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 10: Invoke-ExternalStorageHybrid-Orchestrated.ps1 attaches the external SAN of a hybrid instance by running the step
# scripts of the toolkit in the order of the guide page. The orchestrator is copied into a tree under TestDrive with fake step scripts and the common modules;
# Invoke-Command is mocked. No cluster, no machine and no Azure is used. The password is read from an environment variable made for the test.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/ExternalStorageHybrid.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body and the fake steps run in other scopes; a global is how the test hands them the state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    $script:PasswordVariable = 'AZL_TEST_HYB_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($script:PasswordVariable, [guid]::NewGuid().ToString())

    $root = Join-Path $TestDrive 'tree'
    foreach ($m in 'infrastructure', 'secrets', 'remoting') { Copy-Item -Recurse -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Destination ([IO.Path]::Combine($root, 'scripts', 'common', $m)) }
    $deploy = [IO.Path]::Combine($root, 'scripts', 'deploy')
    $task = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-06-post-deployment', 'task-10-enable-external-storage-hybrid', 'powershell')
    New-Item -ItemType Directory -Path $task -Force | Out-Null
    Copy-Item -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-10-enable-external-storage-hybrid', 'powershell', 'Invoke-ExternalStorageHybrid-Orchestrated.ps1')) -Destination $task
    $fake = @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$InfrastructureFile, [string[]]$Step, [switch]$NoRestart, [switch]$Execute, [pscredential]$Credential, [string]$TargetNode, [string]$LogPath)
$name = Split-Path -Leaf $PSCommandPath
$global:AzlHybSteps.Add([pscustomobject]@{ Name = $name; Step = ($Step -join ','); Execute = [bool]$Execute; WhatIf = [bool]$WhatIfPreference; TargetNode = $TargetNode; User = $(if ($Credential) { $Credential.UserName } else { '' }) })
$key = if ($Step) { "$name|$($Step -join ',')" } else { $name }
$codes = @($global:AzlHybCodes[$key])
$n = @($global:AzlHybSteps | Where-Object { $_.Name -eq $name -and $_.Step -eq ($Step -join ',') }).Count
exit $(if ($codes.Count -ge $n) { [int]$codes[$n - 1] } elseif ($codes.Count) { [int]$codes[-1] } else { 0 })
'@
    $paths = @{
        NodeConfig = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-03-os-configuration', 'Set-AzureLocalNodeConfiguration.ps1')
        SanVolume  = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-SanVolume.ps1')
        Path       = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-StoragePath.ps1')
        Reboot     = [IO.Path]::Combine($deploy, '08-day2-operations', 'task-03-node-maintenance', 'powershell', 'Invoke-NodeMaintenanceReboot.ps1')
    }
    foreach ($p in $paths.Values) { New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null; Set-Content -LiteralPath $p -Value $fake }
    $script:Script = Join-Path $task 'Invoke-ExternalStorageHybrid-Orchestrated.ps1'
    $script:RealSteps = @(
        [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Set-AzureLocalNodeConfiguration.ps1')
        [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-SanVolume.ps1')
        [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-StoragePath.ps1')
        [IO.Path]::Combine($repo, 'scripts', 'deploy', '08-day2-operations', 'task-03-node-maintenance', 'powershell', 'Invoke-NodeMaintenanceReboot.ps1')
    )

    function New-InfraFile([string]$Architecture = 'hybrid', [string]$Topology = 'standard', [object]$SanType = 'iscsi') {
        $doc = [ordered]@{
            scenario = [ordered]@{ identity = 'active_directory'; storage_architecture = $Architecture; topology = $Topology }
            nodes    = @(1, 2 | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.$(10 + $_)" } } })
            storage  = [ordered]@{ san = [ordered]@{} }
            identity = [ordered]@{ active_directory = [ordered]@{ netbios_name = 'IIC'; lcm_user = [ordered]@{ username = 'lcm-azl'; password = "env://$($script:PasswordVariable)" } } }
        }
        if ($null -ne $SanType) { $doc.storage.san.type = $SanType }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Hyb([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Rows = @($all | Where-Object { $_.PSObject.Properties['Step'] -and $_.PSObject.Properties['Result'] }); Text = (@($all | ForEach-Object { "$_" }) -join "`n") }
    }
    function Get-Names { @($global:AzlHybSteps | ForEach-Object { if ($_.Step) { "$($_.Name)|$($_.Step)" } else { $_.Name } }) }
}

Describe 'Invoke-ExternalStorageHybrid-Orchestrated.ps1' {
    AfterAll {
        Remove-Variable -Name AzlHybSteps, AzlHybCodes, AzlHybState, AzlHybRemote -Scope Global -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable($script:PasswordVariable, $null)
    }
    BeforeEach {
        $global:AzlHybSteps = [System.Collections.Generic.List[object]]::new()
        $global:AzlHybRemote = [System.Collections.Generic.List[string]]::new()
        $global:AzlHybCodes = @{}
        $global:AzlHybState = @{ Computer = 'IIC-N01'; SolutionVersion = '12.2610.1002.88'; RunningUpdates = @(); Cluster = 'iic-clus-01' }
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlHybRemote.Add($step)
            switch ($step) { 'ReadState' { $global:AzlHybState.Clone() } 'ValidateStore' { @{ Report = 'C:\Windows\Cluster\Reports\Validation.htm' } } }
        }
    }

    It 'runs the steps of the page in order and exits 0' {
        $r = Invoke-Hyb (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Get-Names | Should -Be @('Set-AzureLocalNodeConfiguration.ps1|Mpio', 'Set-AzureLocalNodeConfiguration.ps1|SanVerify', 'New-SanVolume.ps1', 'New-StoragePath.ps1')
        ($global:AzlHybSteps | Where-Object Step -EQ 'Mpio').Execute | Should -BeTrue
        ($global:AzlHybSteps | Where-Object Step -EQ 'SanVerify').Execute | Should -BeFalse
        $global:AzlHybSteps[0].User | Should -Be 'IIC\lcm-azl'
        $r.Text | Should -Match '30-day trial'
    }

    It 'stops and asks for a rolling restart when the MPIO step is not finished' {
        $global:AzlHybCodes['Set-AzureLocalNodeConfiguration.ps1|Mpio'] = @(1)
        $r = Invoke-Hyb (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'RollingRestart'
        Get-Names | Should -Be @('Set-AzureLocalNodeConfiguration.ps1|Mpio')
    }

    It 'restarts the nodes one at a time with -RollingRestart, then runs the MPIO step again' {
        $global:AzlHybCodes['Set-AzureLocalNodeConfiguration.ps1|Mpio'] = @(1, 0)
        $r = Invoke-Hyb (New-InfraFile) -Extra @{ RollingRestart = $true }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Get-Names | Should -Be @('Set-AzureLocalNodeConfiguration.ps1|Mpio', 'Invoke-NodeMaintenanceReboot.ps1', 'Invoke-NodeMaintenanceReboot.ps1', 'Set-AzureLocalNodeConfiguration.ps1|Mpio', 'Set-AzureLocalNodeConfiguration.ps1|SanVerify', 'New-SanVolume.ps1', 'New-StoragePath.ps1')
        @($global:AzlHybSteps | Where-Object Name -EQ 'Invoke-NodeMaintenanceReboot.ps1' | ForEach-Object TargetNode) | Should -Be @('iic-n01', 'iic-n02')
    }

    It 'stops at the first restart that fails' {
        $global:AzlHybCodes['Set-AzureLocalNodeConfiguration.ps1|Mpio'] = @(1, 0)
        $global:AzlHybCodes['Invoke-NodeMaintenanceReboot.ps1'] = @(1)
        $r = Invoke-Hyb (New-InfraFile) -Extra @{ RollingRestart = $true }
        $r.ExitCode | Should -Be 1
        @($global:AzlHybSteps | Where-Object Name -EQ 'Invoke-NodeMaintenanceReboot.ps1').Count | Should -Be 1
    }

    It 'plans under -WhatIf: no -Execute, -WhatIf to the volume and path steps, no restart, no Test-Cluster' {
        $r = Invoke-Hyb (New-InfraFile) -DryRun -Extra @{ RollingRestart = $true; ValidateStorage = $true }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        ($global:AzlHybSteps | Where-Object Step -EQ 'Mpio').Execute | Should -BeFalse
        ($global:AzlHybSteps | Where-Object Name -EQ 'New-SanVolume.ps1').WhatIf | Should -BeTrue
        ($global:AzlHybSteps | Where-Object Name -EQ 'New-StoragePath.ps1').WhatIf | Should -BeTrue
        @($global:AzlHybSteps | Where-Object Name -EQ 'Invoke-NodeMaintenanceReboot.ps1').Count | Should -Be 0
        $global:AzlHybRemote | Should -Not -Contain 'ValidateStore'
    }

    It 'runs Test-Cluster -Include Storage with -ValidateStorage' {
        $r = Invoke-Hyb (New-InfraFile) -Extra @{ ValidateStorage = $true }
        $r.ExitCode | Should -Be 0
        $global:AzlHybRemote | Should -Contain 'ValidateStore'
    }

    It 'does not run Test-Cluster -Include Storage unless -ValidateStorage is given (it is opt-in: it can touch disks of a live cluster)' {
        $r = Invoke-Hyb (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlHybRemote | Should -Not -Contain 'ValidateStore'
        $r.Text | Should -Match 'not selected'
        $global:AzlHybRemote.Clear()
        (Invoke-Hyb (New-InfraFile) -Extra @{ ValidateStorage = $true }).ExitCode | Should -Be 0
        $global:AzlHybRemote | Should -Contain 'ValidateStore'
    }
    It 'restarts the nodes one at a time when the file approves it (operations.post_cluster.allow_node_restarts), without -RollingRestart' {
        $global:AzlHybCodes['Set-AzureLocalNodeConfiguration.ps1|Mpio'] = @(1, 0)
        $doc = ConvertFrom-Yaml -Ordered (Get-Content -LiteralPath (New-InfraFile) -Raw)
        $doc.operations = [ordered]@{ post_cluster = [ordered]@{ allow_node_restarts = $true } }
        $file = Join-Path $TestDrive "approved-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $r = Invoke-Hyb $file
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlHybSteps | Where-Object Name -EQ 'Invoke-NodeMaintenanceReboot.ps1').Count | Should -Be 2
    }

    It 'refuses to start while a solution update is running, before any step' {
        $global:AzlHybState.RunningUpdates = @('12.2611.1001.10 Installing')
        $r = Invoke-Hyb (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $global:AzlHybSteps.Count | Should -Be 0
    }

    It 'refuses a release before 2604, and a machine that is not in a cluster' {
        $global:AzlHybState.SolutionVersion = '11.2601.1001.5'
        (Invoke-Hyb (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlHybState.SolutionVersion = '12.2610.1002.88'; $global:AzlHybState.Cluster = ''
        (Invoke-Hyb (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlHybSteps.Count | Should -Be 0
    }

    It 'does nothing for s2d, and refuses san, rack aware or a missing SAN type (exit 2, nothing called)' {
        (Invoke-Hyb (New-InfraFile -Architecture 's2d')).ExitCode | Should -Be 0
        (Invoke-Hyb (New-InfraFile -Architecture 'san')).ExitCode | Should -Be 2
        (Invoke-Hyb (New-InfraFile -Topology 'rack_aware')).ExitCode | Should -Be 2
        (Invoke-Hyb (New-InfraFile -SanType $null)).ExitCode | Should -Be 2
        $global:AzlHybSteps.Count | Should -Be 0
        $global:AzlHybRemote.Count | Should -Be 0
    }

    It 'names the real step scripts, and they exist in the toolkit' {
        foreach ($p in $script:RealSteps) { Test-Path -LiteralPath $p | Should -BeTrue -Because $p }
    }
}
