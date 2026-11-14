#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# No script parameter carries a default that is a value a deployment chooses. The enforcement test (Enforcement.Tests.ps1, rule C) finds such
# defaults in every script. This file tests the scripts that were changed to remove one:
#   * Enable-WinRmConfiguration.ps1, Start-Phase03OsConfiguration.ps1 and New-DeploymentServicePrincipal.ps1 are removed (the schema 5 scripts
#     replace them); their task folders, catalogue entries and Orchestrated wrappers stay, and nothing registers or names the old scripts.
#   * The four scripts of config/variables/scripts that defaulted to E:\git\... take their paths from $PSScriptRoot.
#   * New-ScriptFromTemplate.ps1 has no placeholder text for -Description: the parameter is mandatory.
#   * Set-InfrastructurePrep.ps1 has no default time source; New-PipelineSP.ps1 has no default environment name.
# Every script that runs here runs in a child process against files in TestDrive. Nothing reaches Azure, a server or a node.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/ParameterDefaults.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $scripts = [IO.Path]::Combine($repoRoot, 'config', 'variables', 'scripts')
    $script:ConfigScript = @(
        @{ Name = 'audit-aliases.ps1'; Path = [IO.Path]::Combine($scripts, 'audit-aliases.ps1') }
        @{ Name = 'build-mapping-report.ps1'; Path = [IO.Path]::Combine($scripts, 'build-mapping-report.ps1') }
        @{ Name = 'classify-mapping-template.ps1'; Path = [IO.Path]::Combine($scripts, 'classify-mapping-template.ps1') }
        @{ Name = 'inventory-repo-variables.ps1'; Path = [IO.Path]::Combine($scripts, 'inventory-repo-variables.ps1') }
    )
    $deploy = [IO.Path]::Combine($repoRoot, 'scripts', 'deploy')
    $script:Removed = @(
        @{ Name = 'Enable-WinRmConfiguration.ps1'; Folder = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-03-os-configuration', 'task-01-enable-winrm-for-remote-management', 'powershell'); Task = '04-cluster-deployment/phase-03-os-configuration/task-01-enable-winrm-for-remote-management' }
        @{ Name = 'Start-Phase03OsConfiguration.ps1'; Folder = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-03-os-configuration', 'task-12-complete-combined-script-all-steps', 'powershell'); Task = '04-cluster-deployment/phase-03-os-configuration/task-12-complete-combined-script-all-steps' }
        @{ Name = 'New-DeploymentServicePrincipal.ps1'; Folder = [IO.Path]::Combine($deploy, '02-azure-foundation', 'phase-03-rbac-permissions', 'task-01-create-azure-local-deployment-spn', 'powershell'); Task = '02-azure-foundation/phase-03-rbac-permissions/task-01-create-azure-local-deployment-spn' }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:VariableScripts = [IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts')
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Get-ParameterAst([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        @($ast.ParamBlock.Parameters)
    }
    function Invoke-Child([string]$Path, [string[]]$Argument) {
        # A child process, so an exit or a throw in the script ends only that process.
        $text = & $script:Pwsh -NoProfile -NonInteractive -File $Path @Argument 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
    }
}

Describe 'The replaced scripts are gone and nothing names them' {
    It '<Name> is removed' -ForEach $script:Removed {
        Test-Path -LiteralPath ([IO.Path]::Combine($Folder, $Name)) | Should -BeFalse
    }
    It 'the task folder of <Name> keeps its Orchestrated wrapper and its catalogue entry, or the whole task is gone' -ForEach $script:Removed {
        $catalogue = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', 'common', 'TaskCatalogue.psd1'))
        if (Test-Path -LiteralPath $Folder) {
            @(Get-ChildItem -LiteralPath $Folder -Filter '*-Orchestrated.ps1').Count | Should -BeGreaterThan 0
            @($catalogue.Tasks | Where-Object { $_.Path -eq $Task }).Count | Should -Be 1
        }
        else {
            # the whole task went (its wrapper was replaced too): then the catalogue must not list it either
            @($catalogue.Tasks | Where-Object { $_.Path -eq $Task }).Count | Should -Be 0
        }
    }
    It 'the registry has no parameter group for <Name>' -ForEach $script:Removed {
        $registry = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
        # The change log of the registry names the removed scripts, so look for a group of the script, not for the name.
        $registry | Should -Not -Match ('area:\s*"[^"]*/' + [regex]::Escape($Name) + '"')
        $registry | Should -Not -Match ('_' + [regex]::Escape($Name.Replace('-', '_').Replace('.', '_')) + '(_generated)?:')
    }
    It 'no script, test or document except this file and the CHANGELOG names <Name>' -ForEach $script:Removed {
        $hit = @(Get-ChildItem -LiteralPath $script:Repo -Recurse -File -Include *.ps1, *.psm1, *.md, *.yml, *.yaml, *.psd1, *.json -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' -and $_.Name -ne 'ParameterDefaults.Tests.ps1' -and $_.Name -notin 'CHANGELOG.md', 'master-registry.yaml', 'MIGRATION.md' -and $_.Name -notlike '*.Tests.ps1' } |
                # MIGRATION.md records removed scripts on purpose, and a test that checks a removal names the script on purpose.
                Select-String -SimpleMatch $Name -List | ForEach-Object { $_.Path })
        # The README of the phase says which scripts were removed and why; that sentence is the only place that names them.
        $hit | Where-Object { $_ -notmatch 'phase-03-os-configuration[\\/]README\.md$' } | Should -BeNullOrEmpty
    }
}

Describe 'config/variables/scripts: <Name> takes its paths from the folder of the script' -ForEach $script:ConfigScript {
    BeforeAll {
        $script:Params = @(Get-ParameterAst $Path)
    }
    It 'has no default that is a path on a drive' {
        foreach ($p in $script:Params) {
            if ($p.DefaultValue) { $p.DefaultValue.Extent.Text | Should -Not -Match '[A-Za-z]:[\\/]' -Because "-$($p.Name.VariablePath.UserPath)" }
        }
    }
    It 'defaults every path to an expression that starts at $PSScriptRoot' {
        $withDefault = @($script:Params | Where-Object { $_.DefaultValue -and $_.StaticType -eq [string] })
        $withDefault.Count | Should -BeGreaterThan 0
        foreach ($p in $withDefault) { $p.DefaultValue.Extent.Text | Should -Match '\$PSScriptRoot' -Because "-$($p.Name.VariablePath.UserPath)" }
    }
    It 'resolves every default to a place inside this repository (or its parent, for the workspace root)' {
        $parent = [IO.Path]::GetFullPath([IO.Path]::Combine($script:Repo, '..'))
        foreach ($p in @($script:Params | Where-Object { $_.DefaultValue -and $_.StaticType -eq [string] })) {
            $expression = $p.DefaultValue.Extent.Text.Replace('$PSScriptRoot', "'" + $script:VariableScripts.Replace("'", "''") + "'")
            $value = [string](& ([scriptblock]::Create($expression)))
            [IO.Path]::IsPathRooted($value) | Should -BeTrue
            $inside = $value.StartsWith($script:Repo, [StringComparison]::OrdinalIgnoreCase) -or $value.TrimEnd('\', '/') -eq $parent.TrimEnd('\', '/')
            $inside | Should -BeTrue -Because "-$($p.Name.VariablePath.UserPath) = $value"
        }
    }
    It 'has the standard header' {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match '(?m)^Set-StrictMode -Version Latest'
        $text | Should -Match '(?m)^\$ErrorActionPreference = "Stop"'
    }
}

Describe 'config/variables/scripts: the registry and the policy are found without a parameter' {
    It 'audit-aliases.ps1 defaults to files that exist' {
        $registry = $null; $policy = $null
        foreach ($p in Get-ParameterAst ([IO.Path]::Combine($script:VariableScripts, 'audit-aliases.ps1'))) {
            if ($p.DefaultValue -and $p.StaticType -eq [string]) {
                $value = [string](& ([scriptblock]::Create($p.DefaultValue.Extent.Text.Replace('$PSScriptRoot', "'" + $script:VariableScripts + "'"))))
                if ($p.Name.VariablePath.UserPath -eq 'RegistryPath') { $registry = $value } else { $policy = $value }
            }
        }
        Test-Path -LiteralPath $registry | Should -BeTrue
        Test-Path -LiteralPath $policy | Should -BeTrue
    }
    It 'audit-aliases.ps1 names the missing file when a path is wrong' {
        $r = Invoke-Child ([IO.Path]::Combine($script:VariableScripts, 'audit-aliases.ps1')) @('-RegistryPath', (Join-Path $TestDrive 'nope.yaml'), '-PolicyPath', (Join-Path $TestDrive 'nope.json'))
        $r.ExitCode | Should -Not -Be 0
        $r.Text | Should -Match 'File not found'
        $r.Text | Should -Match 'nope\.yaml'
    }
}

Describe 'config/variables/scripts: the three report scripts run on files in TestDrive' {
    BeforeAll {
        $script:Work = Join-Path $TestDrive 'reports'
        New-Item -ItemType Directory -Path $script:Work | Out-Null
        $rows = @(
            [pscustomobject]@{ repo = 'repo-a'; file = 'config/a.yml'; key_path = 'azure.location' }
            [pscustomobject]@{ repo = 'repo-b'; file = 'config/b.yml'; key_path = 'azure.location' }
            [pscustomobject]@{ repo = 'repo-a'; file = 'config/a.yml'; key_path = 'identity.accounts' }
        )
        $rows | Export-Csv -LiteralPath (Join-Path $script:Work 'variable-inventory.csv') -NoTypeInformation
        $rows | Export-Csv -LiteralPath (Join-Path $script:Work 'canonical-mapping-template.csv') -NoTypeInformation
        Set-Content -LiteralPath (Join-Path $script:Work 'legacy-roots.json') -Value '{"roots":["azure"]}'
    }

    It 'build-mapping-report.ps1 reads the inventory and writes the report next to it' {
        $out = Join-Path $TestDrive 'out-build'
        $r = Invoke-Child ([IO.Path]::Combine($script:VariableScripts, 'build-mapping-report.ps1')) @('-InventoryCsv', (Join-Path $script:Work 'variable-inventory.csv'), '-OutputRoot', $out)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Test-Path -LiteralPath (Join-Path $out 'shared-key-paths.csv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $out 'canonical-mapping-template.csv') | Should -BeTrue
        @(Import-Csv -LiteralPath (Join-Path $out 'shared-key-paths.csv')).key_path | Should -Contain 'azure.location'
    }
    It 'build-mapping-report.ps1 says which inventory is missing' {
        $r = Invoke-Child ([IO.Path]::Combine($script:VariableScripts, 'build-mapping-report.ps1')) @('-InventoryCsv', (Join-Path $TestDrive 'missing.csv'), '-OutputRoot', (Join-Path $TestDrive 'out-x'))
        $r.ExitCode | Should -Not -Be 0
        $r.Text | Should -Match 'Inventory file not found'
    }
    It 'classify-mapping-template.ps1 classifies the template and writes the summary' {
        $classified = Join-Path $TestDrive 'classified.csv'
        $summary = Join-Path $TestDrive 'summary.txt'
        $r = Invoke-Child ([IO.Path]::Combine($script:VariableScripts, 'classify-mapping-template.ps1')) @('-TemplateCsv', (Join-Path $script:Work 'canonical-mapping-template.csv'), '-LegacyRootsPath', (Join-Path $script:Work 'legacy-roots.json'), '-OutputCsv', $classified, '-SummaryFile', $summary)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Import-Csv -LiteralPath $classified).Count | Should -Be 3
        (Get-Content -LiteralPath $summary -Raw) | Should -Match 'Classification Summary'
    }
    It 'inventory-repo-variables.ps1 reads the repositories under the workspace root and writes the inventory' {
        $workspace = Join-Path $TestDrive 'workspace'
        $repo = Join-Path $workspace 'azurelocal-toolkit' 'config' 'variables'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'variables.example.yml') -Value "azure:`n  location: eastus`n  tenant_id: x"
        $out = Join-Path $TestDrive 'out-inventory'
        $r = Invoke-Child ([IO.Path]::Combine($script:VariableScripts, 'inventory-repo-variables.ps1')) @('-WorkspaceRoot', $workspace, '-OutputRoot', $out)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $paths = @(Import-Csv -LiteralPath (Join-Path $out 'variable-inventory.csv')).key_path
        $paths | Should -Contain 'azure.location'
        $paths | Should -Contain 'azure.tenant_id'
    }
}

Describe 'New-ScriptFromTemplate.ps1 has no placeholder description' {
    BeforeAll {
        $script:Tool = [IO.Path]::Combine($script:Repo, 'scripts', 'tools', 'authoring', 'New-ScriptFromTemplate.ps1')
    }
    It 'makes -Description mandatory and gives it no default' {
        $p = @(Get-ParameterAst $script:Tool) | Where-Object { $_.Name.VariablePath.UserPath -eq 'Description' }
        $p | Should -Not -BeNullOrEmpty
        $p.DefaultValue | Should -BeNullOrEmpty
        $mandatory = @($p.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } | ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -eq 'Mandatory' })
        $mandatory.Extent.Text | Should -Match 'Mandatory\s*=\s*\$true'
    }
    It 'has the standard header' {
        $text = Get-Content -LiteralPath $script:Tool -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match '(?m)^Set-StrictMode -Version Latest'
    }
    It 'does not run without a description' {
        $r = Invoke-Child $script:Tool @('-ScriptType', 'PowerShell', '-Name', 'New-Thing', '-OutputPath', $TestDrive)
        $r.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $TestDrive 'New-Thing.ps1') | Should -BeFalse
    }
    It 'writes the description it is given and no TODO placeholder text' {
        $r = Invoke-Child $script:Tool @('-ScriptType', 'PowerShell', '-Name', 'New-Thing', '-Description', 'Creates a thing', '-OutputPath', $TestDrive)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $text = Get-Content -LiteralPath (Join-Path $TestDrive 'New-Thing.ps1') -Raw
        $text | Should -Match 'Creates a thing'
        $text | Should -Not -Match 'TODO: Add description'
    }
}

Describe 'Set-InfrastructurePrep.ps1 has no default time source' {
    BeforeAll {
        $script:Prep = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '03-onprem-readiness', 'phase-02-enterprise-readiness', 'task-02-network-service-verification', 'powershell', 'Set-InfrastructurePrep.ps1')
    }
    It 'gives -NTPServer no default' {
        $p = @(Get-ParameterAst $script:Prep) | Where-Object { $_.Name.VariablePath.UserPath -eq 'NTPServer' }
        $p | Should -Not -BeNullOrEmpty
        $p.DefaultValue | Should -BeNullOrEmpty
    }
    It 'does not name a time source in its text' {
        (Get-Content -LiteralPath $script:Prep -Raw) | Should -Not -Match 'time\.windows\.com'
    }
    It 'stops at once, before it reaches any node, when -ConfigureNTP has no -NTPServer' {
        # The check is the first statement after the parameters: no node name is resolved and nothing is connected.
        $r = Invoke-Child $script:Prep @('-NodeNames', 'node-that-is-never-contacted', '-ConfigureNTP')
        $r.ExitCode | Should -Not -Be 0
        $r.Text | Should -Match 'ConfigureNTP needs -NTPServer'
        $r.Text | Should -Not -Match 'Infrastructure Preparation'
    }
}

Describe 'New-PipelineSP.ps1' {
    It 'is removed (the CI/CD bootstrap and New-AutomationManagedIdentity.ps1 replace it)' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'service-principals', 'New-PipelineSP.ps1')) | Should -BeFalse
    }
}
