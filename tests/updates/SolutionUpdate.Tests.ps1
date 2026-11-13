#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Day 2: Start-SolutionUpdateAfterDeployment.ps1 starts the Azure Local solution update when operations.updates.install_after_deployment is true, and returns
# without waiting. Invoke-Command is mocked: no cluster, no machine, no credential is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/updates/SolutionUpdate.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the cluster state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A test credential for a mocked remoting call; it is never a secret.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'lifecycle', 'updates', 'powershell', 'Start-SolutionUpdateAfterDeployment.ps1')
    Import-Module powershell-yaml

    function New-InfraFile {
        param([object]$Switch = $true, [string]$Target = '', [string]$Cluster = 'azl-cluster-01', [switch]$NoUpdates)
        $doc = [ordered]@{ cluster = [ordered]@{}; operations = [ordered]@{} }
        if ($Cluster) { $doc.cluster.name = $Cluster }
        if (-not $NoUpdates) {
            $doc.operations.updates = [ordered]@{}
            if ($null -ne $Switch) { $doc.operations.updates.install_after_deployment = $Switch }
            if ($Target) { $doc.operations.updates.target_version = $Target }
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Update([string]$Version, [string]$State = 'Ready', [string]$Type = 'Solution') {
        @{ ResourceId = "iic-system/$Type$Version"; Version = $Version; State = $State; PackageType = $Type; DisplayName = "update $Version" }
    }
    function Reset-Cluster {
        $global:AzlUpdCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlUpdState = @{ CurrentVersion = '12.2607.1002.20'; State = 'UpdateAvailable'; HealthState = 'Success'; Updates = @((New-Update '12.2610.1004.50')) }
        $global:AzlUpdFail = ''
    }
    function Invoke-Update([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Step) { @($global:AzlUpdCalls | Where-Object Step -EQ $Step) }
}

Describe 'Start-SolutionUpdateAfterDeployment.ps1' {
    AfterAll { Remove-Variable -Name AzlUpdCalls, AzlUpdState, AzlUpdFail -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-Cluster
        Mock Start-Sleep { throw 'The script must not wait.' }
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlUpdCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Arguments = @($ArgumentList | Select-Object -Skip 1); Credential = $Credential })
            if ($global:AzlUpdFail -eq $step) { throw "simulated failure of $step" }
            switch ($step) {
                'ReadState' { $global:AzlUpdState }
                'StartUpdate' { 'instance-0001' }
            }
        }
    }

    Context 'the switch' {
        It 'does nothing and exits 0 when install_after_deployment is false, missing, or the whole block is missing' -ForEach @(
            @{ Case = 'false'; Opts = @{ Switch = $false } }, @{ Case = 'missing'; Opts = @{ Switch = $null } }, @{ Case = 'no block'; Opts = @{ NoUpdates = $true } }
        ) {
            $r = Invoke-Update (New-InfraFile @Opts)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlUpdCalls.Count | Should -Be 0
            $r.Text | Should -Match 'install_after_deployment is not true'
        }

        It 'refuses a switch that is not true or false, before it connects' {
            $r = Invoke-Update (New-InfraFile -Switch 'yes')
            $r.ExitCode | Should -Be 2
            $global:AzlUpdCalls.Count | Should -Be 0
        }
    }

    Context 'values that are not usable (exit 2, nothing sent)' {
        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a target that is not a version'; Opts = @{ Target = '12.2610' } }
            @{ Case = 'a target with a letter in it'; Opts = @{ Target = '12.2610.x.50' } }
            @{ Case = 'a missing cluster name'; Opts = @{ Cluster = '' } }
        ) {
            $r = Invoke-Update (New-InfraFile @Opts)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $global:AzlUpdCalls.Count | Should -Be 0
        }

        It 'refuses a file that does not exist' {
            (Invoke-Update (Join-Path $TestDrive 'nowhere.yml')).ExitCode | Should -Be 2
        }
    }

    Context 'choosing and starting the update' {
        It 'starts the highest ready solution update with latest, ignores SBE updates and older ones, and does not wait' {
            $global:AzlUpdState.Updates = @((New-Update '12.2608.1001.10'), (New-Update '12.2610.1004.50' 'ReadyToInstall'), (New-Update '12.2612.1001.90' 'Ready' 'SBE'), (New-Update '12.2609.1003.30' 'Obsolete'))
            $r = Invoke-Update (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows.Count | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Started'
            $r.Rows[0].Item | Should -Be 'solution update 12.2610.1004.50'
            $r.Rows[0].Detail | Should -Match 'instance-0001'
            $r.Rows[0].Detail | Should -Match 'Sonar'
            (Get-Call 'StartUpdate').Count | Should -Be 1
            (Get-Call 'StartUpdate')[0].Arguments[0] | Should -Be 'iic-system/Solution12.2610.1004.50'
            (Get-Call 'ReadState').Count | Should -Be 1
        }

        It 'starts the version that target_version names, not the highest' {
            $global:AzlUpdState.Updates = @((New-Update '12.2609.1003.30'), (New-Update '12.2610.1004.50'))
            $r = Invoke-Update (New-InfraFile -Target '12.2609.1003.30')
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'StartUpdate')[0].Arguments[0] | Should -Be 'iic-system/Solution12.2609.1003.30'
        }

        It 'connects to cluster.name, or to -ComputerName with -Credential when given' {
            $null = Invoke-Update (New-InfraFile)
            (Get-Call 'ReadState')[0].Computer | Should -Be 'azl-cluster-01'
            Reset-Cluster
            $cred = [pscredential]::new('user', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force))
            $null = Invoke-Update (New-InfraFile) -Extra @{ ComputerName = 'node03'; Credential = $cred }
            (Get-Call 'StartUpdate')[0].Computer | Should -Be 'node03'
            (Get-Call 'StartUpdate')[0].Credential.UserName | Should -Be 'user'
        }

        It 'plans under -WhatIf: reads the cluster, starts nothing, exits 0' {
            $r = Invoke-Update (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldStart'
            (Get-Call 'ReadState').Count | Should -Be 1
            (Get-Call 'StartUpdate').Count | Should -Be 0
        }
    }

    Context 'idempotent: reported, nothing started, exit 0' {
        It 'reports an instance that already runs the target version' {
            $global:AzlUpdState.CurrentVersion = '12.2610.1004.50'
            $global:AzlUpdState.Updates = @((New-Update '12.2610.1004.50' 'Installed'))
            $r = Invoke-Update (New-InfraFile -Target '12.2610.1004.50')
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyAtTarget'
            (Get-Call 'StartUpdate').Count | Should -Be 0
        }

        It 'reports that no newer solution update is ready for latest' {
            $global:AzlUpdState.Updates = @((New-Update '12.2607.1002.20' 'Installed'), (New-Update '12.2605.1001.10' 'Obsolete'))
            $r = Invoke-Update (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyAtTarget'
            (Get-Call 'StartUpdate').Count | Should -Be 0
        }

        It 'reports an update that is already running, whichever version the file names' -ForEach @('Downloading', 'Preparing', 'HealthChecking', 'Installing') {
            $global:AzlUpdState.Updates = @((New-Update '12.2610.1004.50' $_), (New-Update '12.2612.1001.90'))
            $r = Invoke-Update (New-InfraFile -Target '12.2612.1001.90')
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyRunning'
            (Get-Call 'StartUpdate').Count | Should -Be 0
        }

        It 'a second run after a start reports the running update' {
            $null = Invoke-Update (New-InfraFile)
            (Get-Call 'StartUpdate').Count | Should -Be 1
            $global:AzlUpdState.Updates = @((New-Update '12.2610.1004.50' 'Installing'))
            $r = Invoke-Update (New-InfraFile)
            $r.Rows[0].Action | Should -Be 'AlreadyRunning'
            (Get-Call 'StartUpdate').Count | Should -Be 1
        }
    }

    Context 'failures (exit 1), nothing started' {
        It 'stops when the cluster cannot be read' {
            $global:AzlUpdFail = 'ReadState'
            $r = Invoke-Update (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
        }

        It 'does not start when the update environment health is <Health>' -ForEach @(@{ Health = 'Failure' }, @{ Health = 'Error' }, @{ Health = 'Warning' }) {
            $global:AzlUpdState.HealthState = $Health
            $r = Invoke-Update (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match $Health
            (Get-Call 'StartUpdate').Count | Should -Be 0
        }

        It 'starts when the health is Success, InProgress or Unknown' -ForEach @('Success', 'InProgress', 'Unknown') {
            $global:AzlUpdState.HealthState = $_
            (Invoke-Update (New-InfraFile)).ExitCode | Should -Be 0
            (Get-Call 'StartUpdate').Count | Should -Be 1
        }

        It 'does not start a named update that is in the state <State>, and says what to do' -ForEach @(
            @{ State = 'AdditionalContentRequired'; Advice = 'hardware vendor' }, @{ State = 'HasPrerequisite'; Advice = 'another update' }
            @{ State = 'HealthCheckFailed'; Advice = 'readiness checks' }, @{ State = 'InstallationFailed'; Advice = 'installation failed' }
        ) {
            $global:AzlUpdState.Updates = @((New-Update '12.2610.1004.50' $State))
            $r = Invoke-Update (New-InfraFile -Target '12.2610.1004.50')
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match $Advice
            (Get-Call 'StartUpdate').Count | Should -Be 0
        }

        It 'does not pick a failed update for latest: it reports it' {
            $global:AzlUpdState.Updates = @((New-Update '12.2610.1004.50' 'AdditionalContentRequired'))
            $r = Invoke-Update (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'No solution update is ready'
        }

        It 'does not start an older ready update for latest while a newer one is in a failed state' {
            $global:AzlUpdState.Updates = @((New-Update '12.2609.1003.30'), (New-Update '12.2610.1004.50' 'InstallationFailed'))
            $r = Invoke-Update (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'newer 12\.2610\.1004\.50 is in the state InstallationFailed'
            (Get-Call 'StartUpdate').Count | Should -Be 0
        }

        It 'refuses a target version older than the installed version' {
            $global:AzlUpdState.Updates = @((New-Update '12.2605.1001.10'))
            $r = Invoke-Update (New-InfraFile -Target '12.2605.1001.10')
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'older than the installed solution version'
            (Get-Call 'StartUpdate').Count | Should -Be 0
        }

        It 'stops when the named version is not listed' {
            $r = Invoke-Update (New-InfraFile -Target '12.2699.1.1')
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'lists no solution update 12.2699.1.1'
        }

        It 'stops when the start call fails' {
            $global:AzlUpdFail = 'StartUpdate'
            $r = Invoke-Update (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header, never prompts, reads no secret, signs in nowhere and names no vault' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|KeyVault|keyvault://|Connect-AzAccount'
        }

        It 'reads its values through the toolkit loader, holds no address and no version number, and never waits' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            $script:Text | Should -Not -Match '(?m)^\s*(Start-Sleep|Wait-)'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Start_SolutionUpdateAfterDeployment_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'Test-ToolParameterRegistration.ps1')) -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach @('cluster.name', 'operations.updates.install_after_deployment', 'operations.updates.target_version') {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }

        It 'registers the two keys with the version that added them and a default' {
            $switch = $script:Registry | Where-Object Path -EQ 'operations.updates.install_after_deployment'
            $switch.Since | Should -Be '5.6.20'
            $switch.Type | Should -Be 'boolean'
            $switch.Default | Should -BeFalse
            $target = $script:Registry | Where-Object Path -EQ 'operations.updates.target_version'
            $target.Since | Should -Be '5.6.20'
            $target.Default | Should -Be 'latest'
        }
    }
}
