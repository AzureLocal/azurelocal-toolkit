#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 09: Invoke-PostDeploymentVerification-Orchestrated.ps1 runs the node and Azure verification scripts and adds the
# solution health and SAN checks. The orchestrator is copied into a tree under TestDrive with fake verification scripts and the common modules;
# Invoke-Command is mocked. No cluster, no machine and no Azure is used. The password is read from an environment variable made for the test.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/PostDeploymentVerificationOrchestrated.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the machine state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $task = [IO.Path]::Combine('04-cluster-deployment', 'phase-06-post-deployment', 'task-09-post-deployment-verification')
    Import-Module powershell-yaml
    $script:PasswordVariable = 'AZL_TEST_PDVO_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($script:PasswordVariable, [guid]::NewGuid().ToString())

    $root = Join-Path $TestDrive 'tree'
    foreach ($m in 'infrastructure', 'secrets', 'remoting') { Copy-Item -Recurse -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Destination ([IO.Path]::Combine($root, 'scripts', 'common', $m)) }
    $ps = [IO.Path]::Combine($root, 'scripts', 'deploy', $task, 'powershell')
    $cli = [IO.Path]::Combine($root, 'scripts', 'deploy', $task, 'azurecli')
    New-Item -ItemType Directory -Path $ps, $cli -Force | Out-Null
    Copy-Item -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'deploy', $task, 'powershell', 'Invoke-PostDeploymentVerification-Orchestrated.ps1')) -Destination $ps
    $fake = @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$InfrastructureFile, [pscredential]$Credential, [string[]]$TargetNode, [string]$LogPath)
$name = Split-Path -Leaf $PSCommandPath
$global:AzlPdvSteps.Add([pscustomobject]@{ Name = $name; WhatIf = [bool]$WhatIfPreference; Credential = $Credential; TargetNode = $TargetNode })
exit [int]$global:AzlPdvCodes[$name]
'@
    Set-Content -LiteralPath (Join-Path $ps 'Invoke-VerifyPostDeployment.ps1') -Value ($fake -replace '\[pscredential\]\$Credential, ', '[pscredential]$Credential, ')
    Set-Content -LiteralPath (Join-Path $cli 'Invoke-VerifyPostDeployment.azcli.ps1') -Value ($fake -replace '\[pscredential\]\$Credential, ', '')
    $sdnDir = [IO.Path]::Combine($root, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-01-deploy-sdn', 'powershell')
    New-Item -ItemType Directory -Path $sdnDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sdnDir 'Test-ArcSdn.ps1') -Value $fake
    $script:Script = Join-Path $ps 'Invoke-PostDeploymentVerification-Orchestrated.ps1'

    function New-InfraFile([string]$Architecture = 's2d', [switch]$NoLogin, [switch]$Sdn) {
        $doc = [ordered]@{
            scenario = [ordered]@{ identity = 'active_directory'; storage_architecture = $Architecture }
            nodes    = @(1, 2 | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.$(10 + $_)" } } })
            identity = [ordered]@{}
        }
        if ($Sdn) { $doc.sdn = [ordered]@{ enabled = $true } }
        if (-not $NoLogin) { $doc.identity.active_directory = [ordered]@{ netbios_name = 'IIC'; lcm_user = [ordered]@{ username = 'lcm-azl'; password = "env://$($script:PasswordVariable)" } } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Pdv([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Rows = @($all | Where-Object { $_.PSObject.Properties['Step'] -and $_.PSObject.Properties['Result'] }); Text = (@($all | ForEach-Object { "$_" }) -join "`n") }
    }
    function Get-Result($Run, [string]$Like) { ($Run.Rows | Where-Object Step -Like $Like | Select-Object -First 1).Result }
}

Describe 'Invoke-PostDeploymentVerification-Orchestrated.ps1' {
    AfterAll {
        Remove-Variable -Name AzlPdvSteps, AzlPdvCodes, AzlPdvHealth, AzlPdvSan, AzlPdvCalls -Scope Global -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable($script:PasswordVariable, $null)
    }
    BeforeEach {
        $global:AzlPdvSteps = [System.Collections.Generic.List[object]]::new()
        $global:AzlPdvCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlPdvCodes = @{ 'Invoke-VerifyPostDeployment.ps1' = 0; 'Invoke-VerifyPostDeployment.azcli.ps1' = 0; 'Test-ArcSdn.ps1' = 0 }
        $global:AzlPdvHealth = @{ Source = 'Get-SolutionHealthSummary'; Status = 'SUCCESS'; Issues = @() }
        $global:AzlPdvSan = @{
            '192.0.2.11' = @{ Disks = @(@{ Name = 'LUN1'; Health = 'Healthy' }); UniqueIds = @('id-1'); Paths = @(@{ Name = 'MPIO Disk0'; Paths = 2 }) }
            '192.0.2.12' = @{ Disks = @(@{ Name = 'LUN1'; Health = 'Healthy' }); UniqueIds = @('id-1'); Paths = @(@{ Name = 'MPIO Disk0'; Paths = 4 }) }
        }
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlPdvCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; User = $Credential.UserName })
            switch ($step) { 'Health' { $global:AzlPdvHealth.Clone() } 'San' { $global:AzlPdvSan[[string]$ComputerName].Clone() } }
        }
    }

    It 'runs both verification scripts and the health check; no SAN check without a SAN' {
        $r = Invoke-Pdv (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlPdvSteps.Name) | Should -Be @('Invoke-VerifyPostDeployment.ps1', 'Invoke-VerifyPostDeployment.azcli.ps1')
        Get-Result $r 'Solution health*' | Should -Be 'Passed'
        @($global:AzlPdvCalls | Where-Object Step -EQ 'San').Count | Should -Be 0
        $global:AzlPdvCalls[0].User | Should -Be 'IIC\lcm-azl'
    }

    It 'runs every step even when the node checks fail, and exits 1' {
        $global:AzlPdvCodes['Invoke-VerifyPostDeployment.ps1'] = 1
        $r = Invoke-Pdv (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $global:AzlPdvSteps.Count | Should -Be 2
        Get-Result $r 'Solution health*' | Should -Be 'Passed'
    }

    It 'fails on a FAILED health summary and warns on WARNING' {
        $global:AzlPdvHealth.Status = 'FAILED'; $global:AzlPdvHealth.Issues = @('Critical: Test Network intent')
        (Invoke-Pdv (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlPdvHealth.Status = 'WARNING'
        $r = Invoke-Pdv (New-InfraFile)
        $r.ExitCode | Should -Be 0
        Get-Result $r 'Solution health*' | Should -Be 'Warn'
    }

    It 'fails on HealthState Error of Get-SolutionUpdateEnvironment (before 2610)' {
        $global:AzlPdvHealth = @{ Source = 'Get-SolutionUpdateEnvironment'; Status = 'Error'; Issues = @() }
        $r = Invoke-Pdv (New-InfraFile)
        $r.ExitCode | Should -Be 1
        Get-Result $r 'Solution health*' | Should -Be 'Failed'
    }

    It 'checks the SAN of every node: healthy disks, two paths, the same LUNs' {
        $r = Invoke-Pdv (New-InfraFile -Architecture 'san')
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Get-Result $r 'SAN disk identity*' | Should -Be 'Passed'
        @($global:AzlPdvCalls | Where-Object Step -EQ 'San').Computer | Should -Be @('192.0.2.11', '192.0.2.12')
    }

    It 'fails a LUN with one path, an unhealthy disk, and different LUN sets' {
        $global:AzlPdvSan['192.0.2.12'].Paths = @(@{ Name = 'MPIO Disk0'; Paths = 1 })
        $global:AzlPdvSan['192.0.2.12'].Disks = @(@{ Name = 'LUN1'; Health = 'Warning' })
        $global:AzlPdvSan['192.0.2.12'].UniqueIds = @('id-2')
        $r = Invoke-Pdv (New-InfraFile -Architecture 'hybrid')
        $r.ExitCode | Should -Be 1
        Get-Result $r 'MPIO paths on iic-n02' | Should -Be 'Failed'
        Get-Result $r 'SAN disks on iic-n02' | Should -Be 'Failed'
        Get-Result $r 'SAN disk identity*' | Should -Be 'Failed'
    }

    It 'passes -WhatIf to both scripts and asks no node' {
        $r = Invoke-Pdv (New-InfraFile -Architecture 'san') -DryRun
        $r.ExitCode | Should -Be 0
        @($global:AzlPdvSteps.WhatIf) | Should -Be @($true, $true)
        $global:AzlPdvCalls.Count | Should -Be 0
    }

    It 'leaves out the Azure script under -SkipAzure and passes -TargetNode' {
        $r = Invoke-Pdv (New-InfraFile) -Extra @{ SkipAzure = $true; TargetNode = @('iic-n01') }
        @($global:AzlPdvSteps.Name) | Should -Be @('Invoke-VerifyPostDeployment.ps1')
        @($global:AzlPdvSteps[0].TargetNode) | Should -Be @('iic-n01')
        Get-Result $r 'Azure checks*' | Should -Be 'Skipped'
    }

    It 'skips the SDN checks with the reason when sdn.enabled is not true, and runs Test-ArcSdn.ps1 when it is' {
        $r = Invoke-Pdv (New-InfraFile)
        Get-Result $r 'SDN checks*' | Should -Be 'Skipped'
        ($r.Rows | Where-Object Step -Like 'SDN checks*').Detail | Should -Match 'sdn.enabled is not true'
        @($global:AzlPdvSteps.Name) | Should -Not -Contain 'Test-ArcSdn.ps1'
        $global:AzlPdvSteps.Clear()
        $r = Invoke-Pdv (New-InfraFile -Sdn)
        Get-Result $r 'SDN checks*' | Should -Be 'Passed'
        @($global:AzlPdvSteps.Name) | Should -Be @('Invoke-VerifyPostDeployment.ps1', 'Invoke-VerifyPostDeployment.azcli.ps1', 'Test-ArcSdn.ps1')
        $global:AzlPdvCodes['Test-ArcSdn.ps1'] = 1
        $r = Invoke-Pdv (New-InfraFile -Sdn)
        $r.ExitCode | Should -Be 1
        Get-Result $r 'SDN checks*' | Should -Be 'Failed'
    }

    It 'ends with exit 2 when there is no login for its own checks' {
        (Invoke-Pdv (New-InfraFile -NoLogin)).ExitCode | Should -Be 2
    }
}
