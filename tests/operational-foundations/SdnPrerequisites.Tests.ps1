#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Operational foundations, phase 01, task 01: Invoke-SdnPrerequisites-Orchestrated.ps1 checks the prerequisites of SDN enabled by Azure Arc. Read only.
# Invoke-Command is mocked: no cluster, no machine, no credential and no Azure is used. The password is read from an environment variable made for the test.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/operational-foundations/SdnPrerequisites.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the machine state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-01-sdn-deployment', 'task-01-validate-sdn-prerequisites', 'powershell', 'Invoke-SdnPrerequisites-Orchestrated.ps1')
    Import-Module powershell-yaml
    $script:PasswordVariable = 'AZL_TEST_SDNPRE_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($script:PasswordVariable, [guid]::NewGuid().ToString())

    function New-Intent([string]$Name, [string[]]$Traffic) { [ordered]@{ name = $Name; traffic = @($Traffic) } }
    function New-NetIntent([string]$Name, [switch]$M, [switch]$C, [switch]$S) { @{ IntentName = $Name; IsManagementIntentSet = [bool]$M; IsComputeIntentSet = [bool]$C; IsStorageIntentSet = [bool]$S } }
    function New-InfraFile {
        param([object[]]$Intents = @((New-Intent 'mgmt_compute' @('management', 'compute')), (New-Intent 'storage' @('storage'))), [string]$Connectivity = 'switched', [int]$Nodes = 2, [switch]$NoLogin)
        $doc = [ordered]@{
            scenario   = [ordered]@{ identity = 'active_directory'; storage_architecture = 's2d'; storage_connectivity = $Connectivity }
            nodes      = @(1..$Nodes | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.$(10 + $_)" } } })
            networking = [ordered]@{ intents = @($Intents) }
            identity   = [ordered]@{}
        }
        if (-not $NoLogin) { $doc.identity.active_directory = [ordered]@{ netbios_name = 'IIC'; lcm_user = [ordered]@{ username = 'lcm-azl'; password = "env://$($script:PasswordVariable)" } } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Machine {
        $global:AzlSpCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlSpState = @{
            Computer = 'IIC-N01'; OsBuild = 26100; SolutionVersion = '12.2510.1002.88'; RegistrationStatus = 'Registered'; ConnectionStatus = 'Connected'
            NetIntents = @((New-NetIntent 'mgmt_compute' -M -C), (New-NetIntent 'storage' -S)); NodeCount = 2; NcGroups = @(); HostAgentStatus = 'Stopped'
        }
    }
    function Invoke-Pre([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        $rows = @($all | Where-Object { $_.PSObject.Properties['Check'] -and $_.PSObject.Properties['Result'] })
        [pscustomobject]@{
            ExitCode = $code
            Rows     = $rows
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Result($Run, [string]$Check) { ($Run.Rows | Where-Object Check -EQ $Check | Select-Object -First 1).Result }
}

Describe 'Invoke-SdnPrerequisites-Orchestrated.ps1' {
    AfterAll {
        Remove-Variable -Name AzlSpCalls, AzlSpState -Scope Global -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable($script:PasswordVariable, $null)
    }
    BeforeEach {
        Reset-Machine
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlSpCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Credential = $Credential })
            switch ($step) { 'Probe' { 'IIC-N01' } 'ReadState' { $global:AzlSpState.Clone() } }
        }
    }

    It 'passes on a supported instance and asks only read steps' {
        $r = Invoke-Pre (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Get-Result $r 'OS build' | Should -Be 'Pass'
        Get-Result $r 'Azure Local version' | Should -Be 'Pass'
        Get-Result $r 'Network intents (machine)' | Should -Be 'Pass'
        Get-Result $r 'AKS workloads' | Should -Be 'Info'
        @($global:AzlSpCalls.Step | Sort-Object -Unique) | Should -Be @('Probe', 'ReadState')
        $global:AzlSpCalls[0].Credential.UserName | Should -Be 'IIC\lcm-azl'
    }

    It 'fails an OS build below 26100' {
        $global:AzlSpState.OsBuild = 25398
        $r = Invoke-Pre (New-InfraFile)
        $r.ExitCode | Should -Be 1
        Get-Result $r 'OS build' | Should -Be 'Fail'
    }

    It 'fails a release before 2506 and accepts 2506' {
        $global:AzlSpState.SolutionVersion = '11.2504.1001.20'
        (Get-Result (Invoke-Pre (New-InfraFile)) 'Azure Local version') | Should -Be 'Fail'
        $global:AzlSpState.SolutionVersion = '10.2506.0.10'
        (Get-Result (Invoke-Pre (New-InfraFile)) 'Azure Local version') | Should -Be 'Pass'
    }

    It 'warns, and does not fail, when the version cannot be read' {
        $global:AzlSpState.SolutionVersion = ''
        $r = Invoke-Pre (New-InfraFile)
        $r.ExitCode | Should -Be 0
        Get-Result $r 'Azure Local version' | Should -Be 'Warn'
    }

    It 'fails when the instance is not connected to Azure' {
        $global:AzlSpState.ConnectionStatus = 'Disconnected'
        (Get-Result (Invoke-Pre (New-InfraFile)) 'Azure Local registration') | Should -Be 'Fail'
    }

    It 'fails a machine intent that carries compute and storage without management' {
        $global:AzlSpState.NetIntents = @((New-NetIntent 'mgmt' -M), (New-NetIntent 'compute_storage' -C -S))
        $r = Invoke-Pre (New-InfraFile)
        $r.ExitCode | Should -Be 1
        Get-Result $r 'Network intents (machine)' | Should -Be 'Fail'
    }

    It 'fails a planned layout of three intents on two switchless machines' {
        $intents = @((New-Intent 'mgmt' @('management')), (New-Intent 'compute' @('compute')), (New-Intent 'storage' @('storage')))
        $r = Invoke-Pre (New-InfraFile -Intents $intents -Connectivity 'switchless')
        Get-Result $r 'Network intents (file)' | Should -Be 'Fail'
    }

    It 'warns when the intent names of the file and of the machine differ' {
        $global:AzlSpState.NetIntents = @((New-NetIntent 'other' -M -C), (New-NetIntent 'storage' -S))
        $r = Invoke-Pre (New-InfraFile)
        Get-Result $r 'Network intents (file and machine)' | Should -Be 'Warn'
    }

    It 'warns, and does not fail, when the host agent runs and SDN by Arc is not on (a sign of SDN managed by on-premises tools)' {
        $global:AzlSpState.HostAgentStatus = 'Running'
        $r = Invoke-Pre (New-InfraFile)
        $r.ExitCode | Should -Be 0
        Get-Result $r 'SDN managed by on-premises tools' | Should -Be 'Warn'
    }

    It 'reports SDN by Arc as already enabled, with the host agent running, as a pass' {
        $global:AzlSpState.HostAgentStatus = 'Running'; $global:AzlSpState.NcGroups = @('Network Controller')
        $r = Invoke-Pre (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        ($r.Rows | Where-Object Check -EQ 'SDN enabled by Arc').Detail | Should -Match 'already enabled'
    }

    It 'lists the checks and asks nothing under -WhatIf' {
        $r = Invoke-Pre (New-InfraFile) -DryRun
        $r.ExitCode | Should -Be 0
        @($r.Rows | Where-Object Result -NE 'Plan').Count | Should -Be 0
        $global:AzlSpCalls.Count | Should -Be 0
    }

    It 'stops with exit 2 without a login' {
        $r = Invoke-Pre (New-InfraFile -NoLogin)
        $r.ExitCode | Should -Be 2
        $global:AzlSpCalls.Count | Should -Be 0
    }
}
