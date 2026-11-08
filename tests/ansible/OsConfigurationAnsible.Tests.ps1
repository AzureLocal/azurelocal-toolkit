#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The Ansible front end of the OS configuration (ansible/os-configuration): every YAML file parses, the tasks that carry the node
# credential have no_log, the credential is never a command line argument, no file holds a secret, an ID or a real address, and the
# parameters the role passes are the parameters of Invoke-AzureLocalOsConfiguration.ps1. The launcher runs against a stub wrapper in
# the test drive. Nothing here runs Ansible, contacts Azure or touches a node.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/ansible
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $root = Join-Path (Join-Path $repo 'ansible') 'os-configuration'
    $script:DiscoveredFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -match '\.(yml|example)$|^\.(yamllint|ansible-lint)$' -or $_.Extension -in '.ps1', '.cfg', '.md' } |
            ForEach-Object { @{ Relative = $_.FullName.Substring($root.Length + 1).Replace('\', '/'); Path = $_.FullName } })
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Root = Join-Path (Join-Path $repo 'ansible') 'os-configuration'
    $script:RoleRoot = Join-Path (Join-Path $script:Root 'roles') 'azurelocal_os_configuration'
    $script:Wrapper = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $repo 'scripts') 'deploy') '04-cluster-deployment') 'phase-03-os-configuration') 'Invoke-AzureLocalOsConfiguration.ps1'
    $script:Launcher = Join-Path (Join-Path $script:RoleRoot 'files') 'Invoke-OsConfigurationFromAnsible.ps1'
    Import-Module powershell-yaml

    function Read-Yaml([string]$Path) { ConvertFrom-Yaml (Get-Content -LiteralPath $Path -Raw) -Ordered }
    function Get-RoleYaml([string]$Relative) { Read-Yaml (Join-Path $script:RoleRoot $Relative) }

    # Every task in a task list, including the ones inside block / rescue / always.
    function Get-Task($List) {
        foreach ($item in @($List)) {
            if ($item -isnot [System.Collections.IDictionary]) { continue }
            $item
            foreach ($key in 'block', 'rescue', 'always') { if ($item.Contains($key)) { Get-Task $item[$key] } }
        }
    }

    $script:Main = Get-RoleYaml 'tasks/main.yml'
    $script:Phase = Get-RoleYaml 'tasks/phase.yml'
    $script:Defaults = Get-RoleYaml 'defaults/main.yml'
    $script:Specs = Get-RoleYaml 'meta/argument_specs.yml'
    $script:Playbook = Read-Yaml (Join-Path $script:Root 'os-configuration.yml')
    $script:AllTasks = @(Get-Task $script:Main) + @(Get-Task $script:Phase)

    # The wrapper's parameters, their ValidateSet values and its documented exit codes, from its source.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Wrapper, [ref]$tokens, [ref]$errors)
    $script:WrapperParameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $script:WrapperSets = @{}
    foreach ($p in $ast.ParamBlock.Parameters) {
        $set = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        if ($set) { $script:WrapperSets[$p.Name.VariablePath.UserPath] = @($set.PositionalArguments | ForEach-Object { $_.Value }) }
    }
    $script:WrapperText = Get-Content -LiteralPath $script:Wrapper -Raw

    # The run task: the one that starts pwsh.
    $script:RunTask = $script:AllTasks | Where-Object { $_['name'] -eq 'Run Invoke-AzureLocalOsConfiguration.ps1' }
    $vars = (@($script:AllTasks | Where-Object { $_.Contains('vars') -and $_['vars'].Contains('azurelocal_os_configuration__args_always') }))[0]['vars']
    $script:ArgsAlways = @($vars['azurelocal_os_configuration__args_always'].Keys)
    $script:ArgsOptional = @($vars['azurelocal_os_configuration__args_optional'].Keys)
    $script:ArgsSwitches = @($vars['azurelocal_os_configuration__args_switches'].Keys)
    $script:ArgsVars = $vars
}

Describe 'The files' {
    It 'has the role, the playbook, the inventory examples, the lint configuration and the README' {
        foreach ($rel in 'os-configuration.yml', 'README.md', 'ansible.cfg', '.yamllint', '.ansible-lint', '.gitignore', 'inventory/hosts.yml.example', 'inventory/vault.yml.example',
            'roles/azurelocal_os_configuration/tasks/main.yml', 'roles/azurelocal_os_configuration/tasks/phase.yml', 'roles/azurelocal_os_configuration/defaults/main.yml',
            'roles/azurelocal_os_configuration/meta/main.yml', 'roles/azurelocal_os_configuration/meta/argument_specs.yml',
            'roles/azurelocal_os_configuration/files/Invoke-OsConfigurationFromAnsible.ps1') {
            Test-Path -LiteralPath (Join-Path $script:Root $rel) | Should -BeTrue -Because $rel
        }
    }
    It '<Relative> parses' -ForEach $script:DiscoveredFiles {
        if ($Relative -match '\.(yml|example)$' -or $Relative -in '.yamllint', '.ansible-lint') {
            { ConvertFrom-Yaml (Get-Content -LiteralPath $Path -Raw) } | Should -Not -Throw
        }
        elseif ($Path -like '*.ps1') {
            $tokens = $null; $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }
    It 'the playbook runs the role on the os_config_runner group' {
        $script:Playbook[0]['hosts'] | Should -Be 'os_config_runner'
        @($script:Playbook[0]['roles'] | ForEach-Object { $_['role'] }) | Should -Contain 'azurelocal_os_configuration'
    }
    It 'every task has a name' {
        foreach ($t in $script:AllTasks) { $t['name'] | Should -Not -BeNullOrEmpty }
    }
}

Describe 'The node credential' {
    It 'every task that names the credential has no_log: true' {
        $secretTasks = @($script:AllTasks | Where-Object { ($_ | ConvertTo-Json -Depth 20) -match 'node_admin_password|AZL_NODE_ADMIN_PASSWORD' })
        $secretTasks.Count | Should -BeGreaterThan 0
        foreach ($t in $secretTasks) { $t['no_log'] | Should -BeTrue -Because $t['name'] }
    }
    It 'the credential reaches pwsh only through the task environment' {
        $script:RunTask | Should -Not -BeNullOrEmpty
        $script:RunTask['environment'].Keys | Should -Contain 'AZL_NODE_ADMIN_PASSWORD'
        $script:RunTask['environment'].Keys | Should -Contain 'AZL_NODE_ADMIN_USER'
    }
    It 'the run task is a command with an argv list, with no password or credential in the arguments' {
        $script:RunTask.Contains('ansible.builtin.command') | Should -BeTrue
        $argv = @($script:RunTask['ansible.builtin.command']['argv'])
        $argv.Count | Should -BeGreaterThan 5
        ($argv -join ' ') | Should -Not -Match '(?i)password|credential|secret'
        foreach ($t in $script:AllTasks) {
            foreach ($bad in 'ansible.builtin.shell', 'ansible.builtin.raw', 'ansible.builtin.script') { $t.Contains($bad) | Should -BeFalse -Because "$($t['name']) uses $bad" }
        }
    }
    It 'the password is a no_log argument of the role and is never a default value' {
        $specs = $script:Specs['argument_specs']['main']['options']
        $specs['azurelocal_os_configuration_node_admin_password']['no_log'] | Should -BeTrue
        $script:Defaults['azurelocal_os_configuration_node_admin_password'] | Should -Match "lookup\('ansible.builtin.env', 'AZL_NODE_ADMIN_PASSWORD'\)"
    }
    It 'the arguments file the role writes has no credential key' {
        ($script:ArgsAlways + $script:ArgsOptional + $script:ArgsSwitches) | Should -Not -Contain 'Credential'
    }
}

Describe 'Plan, approval, Apply and check mode' {
    It 'check mode and the plan phase resolve to the Plan phase only' {
        $expr = ($script:Main | Where-Object { $_['name'] -eq 'Resolve the phases of this run' })['ansible.builtin.set_fact']['azurelocal_os_configuration__phases']
        $expr | Should -Match 'ansible_check_mode'
        $expr | Should -Match "\['Plan'\] if"
        $expr | Should -Match "\['Plan', 'Apply'\]"
    }
    It 'the run task also runs in check mode (the Plan is read only)' {
        $script:RunTask['check_mode'] | Should -BeFalse
    }
    It 'the approval is a pause that must be answered yes, skipped only by azurelocal_os_configuration_approved' {
        $block = $script:Phase | Where-Object { $_['name'] -eq 'Ask for approval before Apply' }
        $block | Should -Not -BeNullOrEmpty
        (@($block['when']) -join ' ') | Should -Match "== 'Apply'"
        (@($block['when']) -join ' ') | Should -Match 'azurelocal_os_configuration_approved'
        @($block['block'] | ForEach-Object { $_.Keys } | Where-Object { $_ -like 'ansible.builtin.*' }) | Should -Contain 'ansible.builtin.pause'
        ($block['block'] | ConvertTo-Json -Depth 10) | Should -Match "== 'yes'"
    }
    It 'the apply phase alone needs an explicit approval' {
        $assert = $script:Main | Where-Object { $_['name'] -eq 'Check the run control values' }
        (@($assert['ansible.builtin.assert']['that']) -join ' ') | Should -Match "phase != 'apply' or .*approved"
    }
    It 'Mode and ReportDirectory are set per phase' {
        $script:ArgsAlways | Should -Contain 'Mode'
        $script:ArgsAlways | Should -Contain 'ReportDirectory'
        $script:ArgsVars['azurelocal_os_configuration__args_always']['Mode'] | Should -Match 'azurelocal_os_configuration__phase'
    }
    It 'the report is surfaced as facts and set_stats' {
        $fact = ($script:Phase | Where-Object { $_['name'] -eq 'Surface the report and the exit code as facts' })['ansible.builtin.set_fact']
        foreach ($k in 'azurelocal_os_configuration_exit_code', 'azurelocal_os_configuration_report', 'azurelocal_os_configuration_reports', 'azurelocal_os_configuration_summary', 'azurelocal_os_configuration_wipe_list') {
            $fact.Keys | Should -Contain $k
        }
        ($script:Phase | Where-Object { $_.Contains('ansible.builtin.set_stats') }) | Should -Not -BeNullOrEmpty
        ($fact['azurelocal_os_configuration_report']) | Should -Match 'from_json'
    }
    It 'fails on a non-zero exit code, after the facts are set' {
        $names = @($script:Phase | ForEach-Object { $_['name'] })
        $failIndex = $names.IndexOf("Fail with the wrapper's exit code")
        $failIndex | Should -BeGreaterThan $names.IndexOf('Surface the report and the exit code as facts')
        $failIndex | Should -Be ($names.Count - 1)
        ($script:Phase[$failIndex]['when']) | Should -Match 'exit_code \| int != 0'
        $script:RunTask['failed_when'] | Should -BeFalse
    }
}

Describe 'The parameters match Invoke-AzureLocalOsConfiguration.ps1' {
    It 'the wrapper has the parameters the role is built on' {
        foreach ($p in 'InfrastructureFile', 'HandoffPath', 'Node', 'Step', 'Mode', 'ReportDirectory', 'Transport', 'Method', 'Credential', 'ClearStorage', 'ContinueOnNodeFailure', 'FailOnPendingChanges', 'ConfigPath', 'Settings', 'NodeAddress', 'SkipValidation') {
            $script:WrapperParameters | Should -Contain $p
        }
    }
    It 'every parameter the role passes exists in the wrapper' {
        foreach ($p in ($script:ArgsAlways + $script:ArgsOptional + $script:ArgsSwitches)) { $script:WrapperParameters | Should -Contain $p }
    }
    It 'every wrapper parameter is passed by the role, or is Credential (environment) ' {
        $covered = $script:ArgsAlways + $script:ArgsOptional + $script:ArgsSwitches + 'Credential'
        foreach ($p in $script:WrapperParameters) { $covered | Should -Contain $p }
    }
    It 'each parameter takes its value from the matching role variable' {
        $dicts = @($script:ArgsVars['azurelocal_os_configuration__args_always'], $script:ArgsVars['azurelocal_os_configuration__args_optional'], $script:ArgsVars['azurelocal_os_configuration__args_switches'])
        $special = @{ Node = 'nodes'; Step = 'steps' }
        foreach ($d in $dicts) {
            foreach ($key in $d.Keys) {
                if ($key -in 'Mode', 'ReportDirectory') { continue }
                $snake = if ($special.ContainsKey($key)) { $special[$key] } else { ([regex]::Replace($key, '(?<!^)([A-Z])', '_$1')).ToLowerInvariant() }
                $d[$key] | Should -Match "azurelocal_os_configuration_$snake\b" -Because $key
                $script:Defaults.Keys | Should -Contain "azurelocal_os_configuration_$snake"
            }
        }
    }
    It 'the allowed values equal the wrapper''s ValidateSet' {
        $options = $script:Specs['argument_specs']['main']['options']
        @($options['azurelocal_os_configuration_transport']['choices']) | Should -Be $script:WrapperSets['Transport']
        @($options['azurelocal_os_configuration_method']['choices']) | Should -Be $script:WrapperSets['Method']
        @($options['azurelocal_os_configuration_steps']['choices']) | Should -Be $script:WrapperSets['Step']
        $script:WrapperSets['Mode'] | Should -Be @('Plan', 'Apply')
        $script:Defaults['azurelocal_os_configuration_transport'] | Should -Be 'Auto'
        $script:Defaults['azurelocal_os_configuration_method'] | Should -Be 'Auto'
    }
    It 'the exit codes mean what the wrapper says' {
        @($script:Defaults['azurelocal_os_configuration_exit_meanings'].Keys) | Should -Be @('0', '1', '2')
        $script:WrapperText | Should -Match 'Exit codes: 0 every node converged'
        $script:WrapperText | Should -Match '1 a node failed, is blocked or did not converge'
        $script:WrapperText | Should -Match '2 bad input or nothing reachable'
        $script:Defaults['azurelocal_os_configuration_exit_meanings']['1'] | Should -Match 'failed, is blocked or did not converge'
        $script:Defaults['azurelocal_os_configuration_exit_meanings']['2'] | Should -Match 'Bad input or nothing reachable'
    }
    It 'does not reimplement the ZTP versus ISO decision' {
        $text = (Get-Content -LiteralPath (Join-Path $script:RoleRoot 'tasks/phase.yml') -Raw) + (Get-Content -LiteralPath (Join-Path $script:RoleRoot 'tasks/main.yml') -Raw)
        $text | Should -Not -Match '(?i)os_install|ztp-handoff|Resolve-AzlNodeMethod|arcMachine'
        $script:ArgsVars['azurelocal_os_configuration__args_always']['Method'] | Should -Match 'azurelocal_os_configuration_method'
        $script:ArgsVars['azurelocal_os_configuration__args_always']['Transport'] | Should -Match 'azurelocal_os_configuration_transport'
    }
    It 'the README names every wrapper parameter' {
        $readme = Get-Content -LiteralPath (Join-Path $script:Root 'README.md') -Raw
        foreach ($p in $script:WrapperParameters) { $readme | Should -Match "-$p\b" -Because $p }
    }
}

Describe 'No secret, ID or real address in any file' {
    It '<Relative> holds none' -ForEach $script:DiscoveredFiles {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $text | Should -Not -Match 'ghp_[A-Za-z0-9]{20,}|AccountKey=|-----BEGIN|\$ANSIBLE_VAULT;'
        # A key named like a secret may only hold a template, a placeholder or an empty value.
        $text | Should -Not -Match '(?im)^[ \t]*[\w-]*(password|secret|token)[\w-]*[ \t]*:[ \t]*(?!["'']?(\{\{|<|["'']?[ \t]*$|lookup|true|false))\S'
        # Only the documentation address ranges (RFC 5737) may appear.
        foreach ($m in [regex]::Matches($text, '(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])')) {
            $m.Value | Should -Match '^(192\.0\.2|198\.51\.100|203\.0\.113)\.' -Because "$Relative holds the address $($m.Value)"
        }
    }
}

Describe 'The launcher' {
    BeforeAll {
        $script:Stub = Join-Path $TestDrive 'Stub-Wrapper.ps1'
        Set-Content -LiteralPath $script:Stub -Encoding utf8NoBOM -Value @'
[CmdletBinding()]
param([string]$InfrastructureFile, [string]$Mode, [string[]]$Node, [bool]$ContinueOnNodeFailure = $true, [pscredential]$Credential, [switch]$ClearStorage)
$seen = [ordered]@{
    mode = $Mode; nodes = @($Node); continueOnNodeFailure = $ContinueOnNodeFailure; clearStorage = $ClearStorage.IsPresent
    hasCredential = [bool]$Credential
    user = $(if ($Credential) { $Credential.UserName } else { '' })
    passwordLength = $(if ($Credential) { $Credential.GetNetworkCredential().Password.Length } else { 0 })
    passwordInEnvironment = [bool][Environment]::GetEnvironmentVariable('AZL_NODE_ADMIN_PASSWORD')
}
$seen | ConvertTo-Json | Set-Content -LiteralPath $env:STUB_OUT -Encoding utf8NoBOM
exit ([int]$env:STUB_EXIT)
'@
        function Invoke-Launcher {
            param([hashtable]$Arguments, [int]$StubExit = 0, [string]$EnvUser = '', [string]$EnvValue = '')
            $argFile = Join-Path $TestDrive ('args-{0}.json' -f [guid]::NewGuid().ToString('N'))
            $out = Join-Path $TestDrive ('out-{0}.json' -f [guid]::NewGuid().ToString('N'))
            $Arguments | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $argFile -Encoding utf8NoBOM
            $saved = @{}
            foreach ($n in 'STUB_OUT', 'STUB_EXIT', 'AZL_NODE_ADMIN_USER', 'AZL_NODE_ADMIN_PASSWORD') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
            try {
                $env:STUB_OUT = $out; $env:STUB_EXIT = "$StubExit"
                $env:AZL_NODE_ADMIN_USER = $EnvUser; $env:AZL_NODE_ADMIN_PASSWORD = $EnvValue
                $console = & pwsh -NoProfile -NonInteractive -File $script:Launcher -ArgumentsFile $argFile -WrapperPath $script:Stub 2>&1 | Out-String
                $code = $LASTEXITCODE
            }
            finally { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
            [pscustomobject]@{
                ExitCode = $code; Console = $console
                Seen = $(if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw | ConvertFrom-Json } else { $null })
                ErrorText = $(if (Test-Path -LiteralPath "$argFile.error.txt") { Get-Content -LiteralPath "$argFile.error.txt" -Raw } else { '' })
            }
        }
    }
    It 'has the usual script header' {
        $text = Get-Content -LiteralPath $script:Launcher -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match '(?m)^Set-StrictMode -Version Latest'
        $text | Should -Match "(?m)^\`$ErrorActionPreference = 'Stop'"
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Launcher, [ref]$tokens, [ref]$errors)
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Be @('ArgumentsFile', 'WrapperPath', 'AzureAuth')
    }
    It 'passes the wrapper parameters through and builds no credential when the environment has none' {
        $r = Invoke-Launcher -Arguments @{ Mode = 'Plan'; Node = @('n1', 'n2'); ContinueOnNodeFailure = $false; ClearStorage = $true }
        $r.ExitCode | Should -Be 0
        $r.Seen.mode | Should -Be 'Plan'
        @($r.Seen.nodes) | Should -Be @('n1', 'n2')
        $r.Seen.continueOnNodeFailure | Should -BeFalse
        $r.Seen.clearStorage | Should -BeTrue
        $r.Seen.hasCredential | Should -BeFalse
    }
    It 'builds the credential from the environment, hides the password from the wrapper''s environment and prints nothing of it' {
        $secret = [guid]::NewGuid().ToString('N') + 'Aa1!'
        $r = Invoke-Launcher -Arguments @{ Mode = 'Apply' } -EnvUser 'azl-admin' -EnvValue $secret
        $r.ExitCode | Should -Be 0
        $r.Seen.hasCredential | Should -BeTrue
        $r.Seen.user | Should -Be 'azl-admin'
        $r.Seen.passwordLength | Should -Be $secret.Length
        $r.Seen.passwordInEnvironment | Should -BeFalse
        $r.Console | Should -Not -Match ([regex]::Escape($secret))
    }
    It 'returns the wrapper''s exit code unchanged: <Code>' -ForEach @(@{ Code = 0 }, @{ Code = 1 }, @{ Code = 2 }) {
        (Invoke-Launcher -Arguments @{ Mode = 'Plan' } -StubExit $Code).ExitCode | Should -Be $Code
    }
    It 'refuses a parameter the wrapper does not have (exit 2, with the reason in the error file)' {
        $r = Invoke-Launcher -Arguments @{ Mode = 'Plan'; NoSuchParameter = 1 }
        $r.ExitCode | Should -Be 2
        $r.Seen | Should -BeNullOrEmpty
        $r.ErrorText | Should -Match "no parameter 'NoSuchParameter'"
    }
    It 'refuses a Credential in the arguments file' {
        $r = Invoke-Launcher -Arguments @{ Mode = 'Plan'; Credential = 'x' }
        $r.ExitCode | Should -Be 2
        $r.Seen | Should -BeNullOrEmpty
    }
    It 'refuses a password without a user name, without printing the password' {
        $secret = [guid]::NewGuid().ToString('N') + 'Aa1!'
        $r = Invoke-Launcher -Arguments @{ Mode = 'Plan' } -EnvValue $secret
        $r.ExitCode | Should -Be 2
        $r.Seen | Should -BeNullOrEmpty
        ($r.Console + $r.ErrorText) | Should -Not -Match ([regex]::Escape($secret))
    }
}
