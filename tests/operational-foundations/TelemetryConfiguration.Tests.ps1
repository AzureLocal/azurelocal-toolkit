#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Operational foundations, phase 05, task 03: Invoke-TelemetryConfiguration-Orchestrated.ps1 sets the desired diagnostic level of the instance from
# security.telemetry.diagnostic_level and syncs a node. Every Az cmdlet and Invoke-Command are mocked: no Azure, no machine is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/operational-foundations/TelemetryConfiguration.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-05-licensing-telemetry', 'task-03-configure-enhanced-telemetry', 'powershell', 'Invoke-TelemetryConfiguration-Orchestrated.ps1')
    Import-Module powershell-yaml
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzStackHciCluster { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function Update-AzStackHciCluster { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$DesiredPropertyDiagnosticLevel) }

    $script:PasswordVariable = 'AZL_TEST_TELE_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($script:PasswordVariable, [guid]::NewGuid().ToString())
    $global:AzlTeTenant = [guid]::NewGuid().ToString()
    $global:AzlTeSub = [guid]::NewGuid().ToString()

    function New-InfraFile([object]$Level = 'Enhanced', [string]$Connectivity = 'connected') {
        $doc = [ordered]@{
            scenario = [ordered]@{ identity = 'active_directory'; connectivity = $Connectivity }
            azure    = [ordered]@{ tenant_id = $global:AzlTeTenant; subscription_id = $global:AzlTeSub; resource_group = 'rg-iic-azl-01' }
            cluster  = [ordered]@{ name = 'iic-azl-01' }
            nodes    = @([ordered]@{ name = 'iic-n01'; management = [ordered]@{ ip_address = '192.0.2.11' } })
            security = [ordered]@{ telemetry = [ordered]@{ streaming_data = $true } }
            identity = [ordered]@{ active_directory = [ordered]@{ netbios_name = 'IIC'; lcm_user = [ordered]@{ username = 'lcm-azl'; password = "env://$($script:PasswordVariable)" } } }
        }
        if ($null -ne $Level) { $doc.security.telemetry.diagnostic_level = $Level }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Tele([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Row = @($all | Where-Object { $_.PSObject.Properties['Cluster'] -and $_.PSObject.Properties['Action'] })[0]; Text = (@($all | ForEach-Object { "$_" }) -join "`n") }
    }
}

Describe 'Invoke-TelemetryConfiguration-Orchestrated.ps1' {
    AfterAll {
        Remove-Variable -Name AzlTeTenant, AzlTeSub, AzlTeLevel, AzlTeSync -Scope Global -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable($script:PasswordVariable, $null)
    }
    BeforeEach {
        $global:AzlTeLevel = 'Basic'
        $global:AzlTeSync = [System.Collections.Generic.List[object]]::new()
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlTeTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlTeSub } } }
        Mock Set-AzContext { }
        Mock Get-AzStackHciCluster { [pscustomobject]@{ Name = $Name; DesiredPropertyDiagnosticLevel = $global:AzlTeLevel; ReportedPropertyDiagnosticLevel = 'Basic' } }
        Mock Update-AzStackHciCluster { $global:AzlTeLevel = $DesiredPropertyDiagnosticLevel }
        Mock Invoke-Command { $global:AzlTeSync.Add([pscustomobject]@{ Computer = [string]$ComputerName; User = $Credential.UserName }) }
    }

    It 'sets the level when it differs and syncs one node' {
        $r = Invoke-Tele (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Row.Action | Should -Be 'Set'
        $r.Row.Desired | Should -Be 'Enhanced'
        Should -Invoke Update-AzStackHciCluster -Times 1 -Exactly -ParameterFilter { $DesiredPropertyDiagnosticLevel -eq 'Enhanced' }
        $global:AzlTeSync.Count | Should -Be 1
        $global:AzlTeSync[0].Computer | Should -Be '192.0.2.11'
        $r.Row.Sync | Should -Be 'Synced'
    }

    It 'changes nothing and syncs nothing when the level is already set' {
        $global:AzlTeLevel = 'Enhanced'
        $r = Invoke-Tele (New-InfraFile)
        $r.Row.Action | Should -Be 'AlreadySet'
        Should -Invoke Update-AzStackHciCluster -Times 0 -Exactly
        $global:AzlTeSync.Count | Should -Be 0
    }

    It 'takes the level case-insensitively and sends the documented spelling' {
        $null = Invoke-Tele (New-InfraFile -Level 'off')
        Should -Invoke Update-AzStackHciCluster -Times 1 -Exactly -ParameterFilter { $DesiredPropertyDiagnosticLevel -ceq 'Off' }
    }

    It 'plans under -WhatIf' {
        $r = Invoke-Tele (New-InfraFile) -DryRun
        $r.Row.Action | Should -Be 'WouldSet'
        Should -Invoke Update-AzStackHciCluster -Times 0 -Exactly
        $global:AzlTeSync.Count | Should -Be 0
    }

    It 'does nothing without security.telemetry.diagnostic_level' {
        (Invoke-Tele (New-InfraFile -Level $null)).ExitCode | Should -Be 0
        Should -Invoke Get-AzContext -Times 0 -Exactly
    }

    It 'refuses Full, which is not a level (exit 2)' {
        $r = Invoke-Tele (New-InfraFile -Level 'Full')
        $r.ExitCode | Should -Be 2
        $r.Text | Should -Match 'no Full level'
    }

    It 'refuses a disconnected instance (exit 2)' {
        (Invoke-Tele (New-InfraFile -Connectivity 'disconnected')).ExitCode | Should -Be 2
    }

    It 'leaves out the sync under -SkipSync' {
        $r = Invoke-Tele (New-InfraFile) -Extra @{ SkipSync = $true }
        $r.Row.Sync | Should -Be 'Skipped'
        $global:AzlTeSync.Count | Should -Be 0
    }

    It 'fails with exit 1 when the instance is not found' {
        Mock Get-AzStackHciCluster { throw 'ResourceNotFound: the resource was not found' }
        (Invoke-Tele (New-InfraFile)).ExitCode | Should -Be 1
    }
}
