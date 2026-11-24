#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Operational foundations, phase 05, task 02: Invoke-WindowsServerSubscription-Orchestrated.ps1 runs Enable-WindowsServerSubscription.ps1, then
# syncs one node and checks every node. The orchestrator is copied into a tree under TestDrive with a fake Enable-WindowsServerSubscription.ps1 and the
# common modules; Invoke-Command is mocked. No Azure, no machine is used. The password is read from an environment variable made for the test.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/operational-foundations/WindowsServerSubscriptionOrchestrated.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the machine state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $task = [IO.Path]::Combine('05-operational-foundations', 'phase-05-licensing-telemetry', 'task-02-activate-windows-server-subscription', 'powershell')
    Import-Module powershell-yaml
    $script:PasswordVariable = 'AZL_TEST_WSSO_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($script:PasswordVariable, [guid]::NewGuid().ToString())

    # One tree for the whole file: scripts/common (the three module folders) and the task folder with the orchestrator and a fake step 1.
    $root = Join-Path $TestDrive 'tree'
    foreach ($m in 'infrastructure', 'secrets', 'remoting') { Copy-Item -Recurse -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Destination ([IO.Path]::Combine($root, 'scripts', 'common', $m)) }
    $folder = [IO.Path]::Combine($root, 'scripts', 'deploy', $task)
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Copy-Item -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'deploy', $task, 'Invoke-WindowsServerSubscription-Orchestrated.ps1')) -Destination $folder
    Set-Content -LiteralPath (Join-Path $folder 'Enable-WindowsServerSubscription.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$InfrastructureFile, [string]$LogPath)
$global:AzlWssStep = [pscustomobject]@{ WhatIf = [bool]$WhatIfPreference }
exit [int]$env:AZL_TEST_WSSO_CODE
'@
    $script:Script = Join-Path $folder 'Invoke-WindowsServerSubscription-Orchestrated.ps1'

    function New-InfraFile([object]$Wanted = $true, [switch]$NoLogin) {
        $doc = [ordered]@{
            scenario   = [ordered]@{ identity = 'active_directory' }
            nodes      = @(1, 2 | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.$(10 + $_)" } } })
            operations = [ordered]@{ licensing = [ordered]@{ windows_server_subscription = $Wanted } }
            identity   = [ordered]@{}
        }
        if (-not $NoLogin) { $doc.identity.active_directory = [ordered]@{ netbios_name = 'IIC'; lcm_user = [ordered]@{ username = 'lcm-azl'; password = "env://$($script:PasswordVariable)" } } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Wss([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Rows = @($all | Where-Object { $_.PSObject.Properties['Node'] -and $_.PSObject.Properties['Result'] }); Text = (@($all | ForEach-Object { "$_" }) -join "`n") }
    }
}

Describe 'Invoke-WindowsServerSubscription-Orchestrated.ps1' {
    AfterAll {
        Remove-Variable -Name AzlWssStep, AzlWssCalls, AzlWssStatus -Scope Global -ErrorAction SilentlyContinue
        Remove-Item Env:AZL_TEST_WSSO_CODE -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable($script:PasswordVariable, $null)
    }
    BeforeEach {
        $env:AZL_TEST_WSSO_CODE = '0'
        $global:AzlWssStep = $null
        $global:AzlWssCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlWssStatus = @{ '192.0.2.11' = 'Active'; '192.0.2.12' = 'Active' }
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlWssCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Credential = $Credential })
            if ($step -eq 'Check') { @{ Computer = [string]$ComputerName; Status = $global:AzlWssStatus[[string]$ComputerName]; Avma = 'AVMA' } }
        }
    }

    It 'runs step 1, syncs one node and checks every node' {
        $r = Invoke-Wss (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlWssStep.WhatIf | Should -BeFalse
        @($global:AzlWssCalls | Where-Object Step -EQ 'Sync').Count | Should -Be 1
        @($global:AzlWssCalls | Where-Object Step -EQ 'Check').Computer | Should -Be @('192.0.2.11', '192.0.2.12')
        @($r.Rows.Result) | Should -Be @('Active', 'Active')
        $global:AzlWssCalls[0].Credential.UserName | Should -Be 'IIC\lcm-azl'
    }

    It 'reports a node that is not active yet as Pending, with exit 0' {
        $global:AzlWssStatus['192.0.2.12'] = 'Inactive'
        $r = Invoke-Wss (New-InfraFile)
        $r.ExitCode | Should -Be 0
        ($r.Rows | Where-Object Node -EQ 'iic-n02').Result | Should -Be 'Pending'
    }

    It 'ends with the exit code of step 1 and asks no node when it fails' {
        $env:AZL_TEST_WSSO_CODE = '1'
        (Invoke-Wss (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlWssCalls.Count | Should -Be 0
    }

    It 'passes -WhatIf to step 1 and asks no node' {
        $r = Invoke-Wss (New-InfraFile) -DryRun
        $r.ExitCode | Should -Be 0
        $global:AzlWssStep.WhatIf | Should -BeTrue
        $global:AzlWssCalls.Count | Should -Be 0
    }

    It 'asks no node when the add-on is not wanted' {
        (Invoke-Wss (New-InfraFile -Wanted $false)).ExitCode | Should -Be 0
        $global:AzlWssCalls.Count | Should -Be 0
    }

    It 'leaves out the sync under -SkipSync' {
        $null = Invoke-Wss (New-InfraFile) -Extra @{ SkipSync = $true }
        @($global:AzlWssCalls | Where-Object Step -EQ 'Sync').Count | Should -Be 0
    }

    It 'stops with exit 2 when there is no login for the machines' {
        (Invoke-Wss (New-InfraFile -NoLogin)).ExitCode | Should -Be 2
    }
}
