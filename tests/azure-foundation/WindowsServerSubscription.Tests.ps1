#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 05 (licensing and telemetry), task 02: Enable-WindowsServerSubscription.ps1 turns on the Windows Server subscription add-on of the Azure Local instance
# when operations.licensing.windows_server_subscription is true. Every Az cmdlet is a stub or a mock: no Azure, no tenant and no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/WindowsServerSubscription.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-05-licensing-telemetry', 'task-02-activate-windows-server-subscription', 'powershell', 'Enable-WindowsServerSubscription.ps1')
    Import-Module powershell-yaml

    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzStackHciCluster { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function Update-AzStackHciCluster { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$DesiredPropertyWindowsServerSubscription) }

    $global:AzlWssTenant = [guid]::NewGuid().ToString()
    $global:AzlWssSub = [guid]::NewGuid().ToString()
    $global:AzlWssHome = [guid]::NewGuid().ToString()
    $global:AzlWssState = 'Disabled'

    function New-InfraFile {
        param([object]$Subscription = $true, [hashtable]$Azure = @{}, [string]$Connectivity = 'connected', [hashtable]$Cluster = @{}, [switch]$NoLicensing)
        $az = [ordered]@{ tenant_id = $global:AzlWssTenant; subscription_id = $global:AzlWssSub; resource_group = 'rg-iic-azl-01' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $cl = [ordered]@{ name = 'iic-azl-01' }
        foreach ($k in $Cluster.Keys) { if ($null -eq $Cluster[$k]) { $cl.Remove($k) } else { $cl[$k] = $Cluster[$k] } }
        $doc = [ordered]@{ azure = $az; cluster = $cl; scenario = [ordered]@{ connectivity = $Connectivity } }
        if (-not $NoLicensing) { $doc.operations = [ordered]@{ licensing = [ordered]@{ windows_server_subscription = $Subscription } } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Wss([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Row      = @($all | Where-Object { $_.PSObject.Properties['Cluster'] -and $_.PSObject.Properties['Action'] })[0]
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

AfterAll { Remove-Variable -Name AzlWssTenant, AzlWssSub, AzlWssHome, AzlWssState -Scope Global -ErrorAction SilentlyContinue }

Describe 'Enable-WindowsServerSubscription.ps1' {
    BeforeEach {
        $global:AzlWssState = 'Disabled'
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlWssTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlWssHome } } }
        Mock Set-AzContext { }
        Mock Get-AzStackHciCluster { [pscustomobject]@{ Name = $Name; DesiredPropertyWindowsServerSubscription = $global:AzlWssState } }
        Mock Update-AzStackHciCluster { $global:AzlWssState = $DesiredPropertyWindowsServerSubscription; [pscustomobject]@{ Name = $Name } }
    }

    Context 'turning the add-on on' {
        It 'sets the desired state Enabled on the instance of cluster.name, in azure.resource_group of azure.subscription_id' {
            $r = Invoke-Wss (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Row.Action | Should -Be 'Enabled'
            $r.Row.State | Should -Be 'Enabled'
            Should -Invoke Update-AzStackHciCluster -Times 1 -Exactly -ParameterFilter { $Name -eq 'iic-azl-01' -and $ResourceGroupName -eq 'rg-iic-azl-01' -and $SubscriptionId -eq $global:AzlWssSub -and $DesiredPropertyWindowsServerSubscription -eq 'Enabled' }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlWssSub }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlWssHome }
            $r.Text | Should -Match 'Get-AzureStackHCISubscriptionStatus'
        }

        It 'says so when the call worked but the state does not read Enabled yet' {
            Mock Update-AzStackHciCluster { [pscustomobject]@{ Name = $Name } }
            $r = Invoke-Wss (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'Enabled'
            $r.Row.Detail | Should -Match 'Read it again'
        }

        It 'never turns the add-on off' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            $code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
            $code | Should -Not -Match "'Disabled'|Remove-Az|Disable"
        }
    }

    Context 'the add-on is on already (idempotent)' {
        It 'changes nothing and reports it' {
            $global:AzlWssState = 'Enabled'
            $r = Invoke-Wss (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'AlreadyEnabled'
            Should -Invoke Update-AzStackHciCluster -Times 0 -Exactly
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'reads the instance, plans the change and changes nothing' {
            $r = Invoke-Wss (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Row.Action | Should -Be 'WouldEnable'
            Should -Invoke Get-AzStackHciCluster -Times 1 -Exactly
            Should -Invoke Update-AzStackHciCluster -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the value is false, or the file has no licensing section' {
            foreach ($file in (New-InfraFile -Subscription $false), (New-InfraFile -NoLicensing)) {
                $r = Invoke-Wss $file
                $r.ExitCode | Should -Be 0
                $r.Text | Should -Match 'nothing to do'
            }
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a missing azure.tenant_id'; Settings = @{ Azure = @{ tenant_id = $null } } }
            @{ Why = 'a missing azure.subscription_id'; Settings = @{ Azure = @{ subscription_id = $null } } }
            @{ Why = 'a missing azure.resource_group'; Settings = @{ Azure = @{ resource_group = $null } } }
            @{ Why = 'a missing cluster.name'; Settings = @{ Cluster = @{ name = $null } } }
            @{ Why = 'a disconnected instance'; Settings = @{ Connectivity = 'disconnected' } }
            @{ Why = 'a value that is not true or false'; Settings = @{ Subscription = 'maybe' } }
        ) {
            $r = Invoke-Wss (New-InfraFile @Settings)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke Update-AzStackHciCluster -Times 0 -Exactly
        }

        It 'refuses a file that cannot be read' {
            (Invoke-Wss (Join-Path $TestDrive 'missing.yml')).ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Wss (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Wss (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke Update-AzStackHciCluster -Times 0 -Exactly
        }

        It 'stops when the instance does not exist' {
            Mock Get-AzStackHciCluster { throw "The Resource 'Microsoft.AzureStackHCI/clusters/$Name' was not found (404 NotFound)." }
            $r = Invoke-Wss (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'was not found in the resource group'
            Should -Invoke Update-AzStackHciCluster -Times 0 -Exactly
        }

        It 'reports a failed update, puts the subscription back, and exits 1' {
            Mock Update-AzStackHciCluster { throw 'The machines of the system are not all registered.' }
            $r = Invoke-Wss (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Row.Action | Should -Be 'Failed'
            $r.Row.Detail | Should -Match 'not all registered'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlWssHome }
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            $script:Code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header and never prompts, signs in or opens a session of its own' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Code | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|ConfigPath|ConvertFrom-Yaml|New-PSSession|Invoke-Command|az\s+stack-hci'
        }

        It 'takes -InfrastructureFile, mandatory, and no cluster, resource group or credential parameter' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
            $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $names | Should -Be @('InfrastructureFile', 'LogPath')
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'cluster.name', 'scenario.connectivity', 'operations.licensing.windows_server_subscription' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
            $script:Text | Should -Match ([regex]::Escape($_))
        }

        It 'says in the registry that a script reads the key (it is no longer a placeholder)' {
            $key = @($script:Registry | Where-Object Path -EQ 'operations.licensing.windows_server_subscription')[0]
            $key.Node['description'] | Should -Match 'Enable-WindowsServerSubscription\.ps1'
            $key.Node['description'] | Should -Not -Match 'Not read by the tools yet'
        }
    }
}
