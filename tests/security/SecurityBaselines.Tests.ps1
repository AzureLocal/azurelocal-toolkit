#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Stage 05, phase 04, task 03: Set-SecurityBaselines.ps1 changes the individual security baseline settings of security.baseline_settings with
# Set-AzsSecurity -Cluster (Azure Local 2610 or later). Invoke-Command is mocked: no machine, no cluster, no credential is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/security/SecurityBaselines.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the machine state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
param()

BeforeDiscovery {
    # The -ForEach tables are built while Pester finds the tests, before BeforeAll runs.
    function New-Setting([hashtable]$Override = @{}) {
        $s = [ordered]@{ type = 'SecuritySettings'; name = 'LanmanWorkstationEnableInsecureGuestLogons'; value = '1' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $s.Remove($k) } else { $s[$k] = $Override[$k] } }
        $s
    }
    $script:Blocked = @('WinRMAllowBasicAuthClient', 'FirewallPublicProfileState', 'MinimumSMBServerVersion', 'DisableRealtimeMonitoring', 'CredSspAllowEncryptionOracle', 'DeviceGuardLsaCfgFlags') | ForEach-Object { @{ Name = $_ } }
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-04-security-governance', 'task-03-configure-security-baselines', 'powershell', 'Set-SecurityBaselines.ps1')
    Import-Module powershell-yaml

    function New-Setting([hashtable]$Override = @{}) {
        $s = [ordered]@{ type = 'SecuritySettings'; name = 'LanmanWorkstationEnableInsecureGuestLogons'; value = '1' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $s.Remove($k) } else { $s[$k] = $Override[$k] } }
        $s
    }
    function New-InfraFile {
        param([object[]]$Settings = @((New-Setting)), [int]$Nodes = 2, [switch]$NoSecurity, [hashtable]$Admin = $null)
        $doc = [ordered]@{ nodes = @(for ($i = 1; $i -le $Nodes; $i++) { [ordered]@{ name = "iic-node0$i"; management = [ordered]@{ ip_address = "192.0.2.$(10 + $i)" } } }) }
        if (-not $NoSecurity) { $doc.security = [ordered]@{ baseline_settings = @($Settings) } }
        if ($Admin) { $doc.identity = [ordered]@{ local_admin = $Admin } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Machine {
        $global:AzlSbCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlSbState = @{ HasSet = $true; HasIntent = $true; IntentJson = '' }
        $global:AzlSbFail = ''
    }
    function Invoke-Baseline([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Step) { @($global:AzlSbCalls | Where-Object Step -EQ $Step) }
}

Describe 'Set-SecurityBaselines.ps1' {
    AfterAll { Remove-Variable -Name AzlSbCalls, AzlSbState, AzlSbFail -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_SB_PASSWORD -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-Machine
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlSbCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Arguments = @($ArgumentList | Select-Object -Skip 1); Credential = $Credential })
            if ($global:AzlSbFail -eq $step) { throw "simulated failure of $step" }
            if ($step -eq 'ReadState') { $global:AzlSbState }
        }
    }

    Context 'changing a setting' {
        It 'runs Set-AzsSecurity for the type, the name and the value, on the first machine of nodes[], for the whole instance' {
            $r = Invoke-Baseline (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Set'
            $r.Rows[0].Item | Should -Be 'SecuritySettings/LanmanWorkstationEnableInsecureGuestLogons'
            $call = (Get-Call 'SetSetting')[0]
            $call.Computer | Should -Be '192.0.2.11'
            $call.Arguments[0] | Should -Be 'SecuritySettings'
            $call.Arguments[1] | Should -Be 'LanmanWorkstationEnableInsecureGuestLogons'
            $call.Arguments[2] | Should -Be '1'
            $call.Arguments[3] | Should -BeFalse
        }

        It 'has the remote step ask for -Cluster, -Confirm:$false and -Force only when the entry acknowledges it' {
            $text = Get-Content -LiteralPath $script:Script -Raw
            $text | Should -Match 'Cluster = \$true; Confirm = \$false'
            $text | Should -Match 'if \(\$Force\) \{ \$parameters\.Force = \$true \}'
            $null = Invoke-Baseline (New-InfraFile -Settings @((New-Setting @{ acknowledge_weaker_security = $true })))
            (Get-Call 'SetSetting')[0].Arguments[3] | Should -BeTrue
        }

        It 'sends an integer as a string and a list as a list' {
            $null = Invoke-Baseline (New-InfraFile -Settings @((New-Setting @{ value = 14 }), (New-Setting @{ name = 'SettingWithList'; value = @('a', 'b') })))
            $calls = Get-Call 'SetSetting'
            $calls[0].Arguments[2] | Should -Be '14'
            $calls[0].Arguments[2] | Should -BeOfType [string]
            @($calls[1].Arguments[2]) | Should -Be @('a', 'b')
        }

        It 'uses -ComputerName, and the local administrator of identity.local_admin as the credential (the password is read from its reference)' {
            $env:AZL_TEST_SB_PASSWORD = [guid]::NewGuid().ToString()
            $null = Invoke-Baseline (New-InfraFile -Admin @{ username = 'iic-admin'; password = 'env://AZL_TEST_SB_PASSWORD' }) -Extra @{ ComputerName = 'iic-node09' }
            $call = (Get-Call 'ReadState')[0]
            $call.Computer | Should -Be 'iic-node09'
            $call.Credential.UserName | Should -Be '.\iic-admin'
        }

        It 'does not call anything but Set-AzsSecurity to change a setting, and never changes drift control' {
            $text = Get-Content -LiteralPath $script:Script -Raw
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            $code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
            $code | Should -Not -Match 'Disable-AzsSecurity|Enable-AzsSecurity|auditpol|Set-ItemProperty|secedit|Set-SmbServerConfiguration|DriftControl|-Default\b'
            $text | Should -Match 'Set-AzsSecurity @parameters'
        }
    }

    Context 'a setting is recorded already (idempotent)' {
        It 'leaves it alone when the recorded customization has the same value' {
            $global:AzlSbState.IntentJson = '[{"Type":"SecuritySettings","Settings":{"LanmanWorkstationEnableInsecureGuestLogons":"1"}}]'
            $r = Invoke-Baseline (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadySet'
            Get-Call 'SetSetting' | Should -BeNullOrEmpty
        }

        It 'recognises a record written as a list of name and value objects' {
            $global:AzlSbState.IntentJson = '{"SecuritySettings":[{"Name":"LanmanWorkstationEnableInsecureGuestLogons","Value":"1"}]}'
            (Invoke-Baseline (New-InfraFile)).Rows[0].Action | Should -Be 'AlreadySet'
        }

        It 'sets it when the recorded value differs, and when the setting is not recorded' {
            $global:AzlSbState.IntentJson = '[{"Type":"SecuritySettings","Settings":{"LanmanWorkstationEnableInsecureGuestLogons":"0"}}]'
            (Invoke-Baseline (New-InfraFile)).Rows[0].Action | Should -Be 'Set'
            Reset-Machine
            $global:AzlSbState.IntentJson = '[{"Type":"SecuritySettings","Settings":{"SomethingElse":"1"}}]'
            (Invoke-Baseline (New-InfraFile)).Rows[0].Action | Should -Be 'Set'
        }

        It 'sets it when the same name and value are recorded only under another policy type' {
            $global:AzlSbState.IntentJson = '[{"Type":"DefenderAntivirus","Settings":{"LanmanWorkstationEnableInsecureGuestLogons":"1"}}]'
            (Invoke-Baseline (New-InfraFile)).Rows[0].Action | Should -Be 'Set'
            Reset-Machine
            $global:AzlSbState.IntentJson = '{"SecuredCore":[{"Name":"LanmanWorkstationEnableInsecureGuestLogons","Value":"1"}]}'
            (Invoke-Baseline (New-InfraFile)).Rows[0].Action | Should -Be 'Set'
        }

        It 'sets the setting when the cmdlet that lists the records is missing, with a warning' {
            $global:AzlSbState.HasIntent = $false
            $r = Invoke-Baseline (New-InfraFile)
            $r.Rows[0].Action | Should -Be 'Set'
            $r.Text | Should -Match 'Get-AzsSecurityPolicyIntent was not found'
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'reads the machine, plans the change and changes nothing' {
            $r = Invoke-Baseline (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'WouldSet'
            (Get-Call 'ReadState').Count | Should -Be 1
            Get-Call 'SetSetting' | Should -BeNullOrEmpty
        }

        It 'does nothing and contacts no machine when the file lists no setting' {
            foreach ($file in (New-InfraFile -NoSecurity), (New-InfraFile -Settings @())) {
                $r = Invoke-Baseline $file
                $r.ExitCode | Should -Be 0
                $r.Text | Should -Match 'nothing to do'
            }
            $global:AzlSbCalls.Count | Should -Be 0
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent anywhere)' {
        It 'refuses the blocked setting <Name>' -ForEach $script:Blocked {
            $r = Invoke-Baseline (New-InfraFile -Settings @((New-Setting @{ name = $Name })))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'blocks from customization'
            $global:AzlSbCalls.Count | Should -Be 0
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a type that is not one of the three'; Settings = @((New-Setting @{ type = 'Registry' })) }
            @{ Why = 'a missing type'; Settings = @((New-Setting @{ type = $null })) }
            @{ Why = 'a missing name'; Settings = @((New-Setting @{ name = $null })) }
            @{ Why = 'a name with spaces or quotes'; Settings = @((New-Setting @{ name = "Bad Name'" })) }
            @{ Why = 'a missing value'; Settings = @((New-Setting @{ value = $null })) }
            @{ Why = 'a true or false value (write it as the CSV does, in quotes)'; Settings = @((New-Setting @{ value = $true })) }
            @{ Why = 'a setting listed twice'; Settings = @((New-Setting), (New-Setting)) }
            @{ Why = 'an acknowledge_weaker_security that is not true or false'; Settings = @((New-Setting @{ acknowledge_weaker_security = 'yes' })) }
            @{ Why = 'an entry that is not a map'; Settings = @('LanmanWorkstationEnableInsecureGuestLogons') }
        ) {
            $r = Invoke-Baseline (New-InfraFile -Settings $Settings)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $global:AzlSbCalls.Count | Should -Be 0
        }

        It 'accepts the type in any letter case and the same name under two types' {
            $r = Invoke-Baseline (New-InfraFile -Settings @((New-Setting @{ type = 'securitysettings' }), (New-Setting @{ type = 'SecuredCore' })))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'SetSetting').Count | Should -Be 2
            (Get-Call 'SetSetting')[0].Arguments[0] | Should -Be 'SecuritySettings'
        }

        It 'refuses a file with no machine and no -ComputerName' {
            (Invoke-Baseline (New-InfraFile -Nodes 0)).ExitCode | Should -Be 2
            $global:AzlSbCalls.Count | Should -Be 0
        }
    }

    Context 'the machine and the cmdlets (exit 1)' {
        It 'stops, and says why, when Set-AzsSecurity does not exist on the machine' {
            $global:AzlSbState.HasSet = $false
            $r = Invoke-Baseline (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match '2610'
            Get-Call 'SetSetting' | Should -BeNullOrEmpty
        }

        It 'stops when the machine cannot be reached' {
            $global:AzlSbFail = 'ReadState'
            $r = Invoke-Baseline (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
        }

        It 'reports a setting that could not be changed, goes on with the next one, and exits 1' {
            Mock Invoke-Command {
                $step = [string]$ArgumentList[0]
                $global:AzlSbCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Arguments = @($ArgumentList | Select-Object -Skip 1); Credential = $Credential })
                if ($step -eq 'ReadState') { return $global:AzlSbState }
                if ($ArgumentList[2] -eq 'SettingOne') { throw 'The change weakens your security posture; confirm it first.' }
            }
            $r = Invoke-Baseline (New-InfraFile -Settings @((New-Setting @{ name = 'SettingOne' }), (New-Setting @{ name = 'SettingTwo' })))
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Item -Like '*SettingOne').Action | Should -Be 'Failed'
            ($r.Rows | Where-Object Item -Like '*SettingOne').Detail | Should -Match 'acknowledge_weaker_security'
            ($r.Rows | Where-Object Item -Like '*SettingTwo').Action | Should -Be 'Set'
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader and the secret resolver, never the old layout, and holds no address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Match 'Get-AzlSecretValue'
            $script:Text | Should -Not -Match 'ConvertFrom-Yaml|ConfigPath|\$config\.'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Set_SecurityBaselines_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'security.baseline_settings[].type', 'security.baseline_settings[].name', 'security.baseline_settings[].value', 'security.baseline_settings[].acknowledge_weaker_security', 'nodes[].name', 'nodes[].management.ip_address', 'identity.local_admin.username', 'identity.local_admin.password' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
