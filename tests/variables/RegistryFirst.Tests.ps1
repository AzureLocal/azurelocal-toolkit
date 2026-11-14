#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The master registry (config/variables/schema/master-registry.yaml) is the master of every variable. These tests fail when a
# key was added to infrastructure.schema.json (or a name was changed there) without the registry being changed first.
# Run: Invoke-Pester ./tests/variables

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:Scripts = Join-Path $repo 'config\variables\scripts'
    $script:RegistryPath = Join-Path $repo 'config\variables\schema\master-registry.yaml'
    $script:SchemaPath = Join-Path $repo 'config\variables\schema\infrastructure.schema.json'
    Import-Module (Join-Path $script:Scripts 'VariableRegistry.psm1') -Force
    $script:Registry = @(Get-RegistryVariable -Path $script:RegistryPath)
    $script:Schema = @(Get-InfrastructureSchemaVariable -SchemaPath $script:SchemaPath)
    $script:Comparison = Compare-RegistryToSchema -Registry $script:Registry -Schema $script:Schema
}

Describe 'Registry first: infrastructure.schema.json against master-registry.yaml' {
    It 'reads a plausible number of keys from both' {
        $script:Schema.Count | Should -BeGreaterThan 600
        $script:Registry.Count | Should -BeGreaterThan $script:Schema.Count
    }

    It 'has no schema key the registry lacks (register it in the registry first)' {
        $names = @($script:Comparison.Missing | ForEach-Object Path)
        $names | Should -BeNullOrEmpty -Because "these keys are in infrastructure.schema.json but not in master-registry.yaml: $($names -join ', ')"
    }

    It 'has no schema key that disagrees with the registry on shape, type, enum, default or constraints' {
        $lines = @($script:Comparison.Conflict | ForEach-Object { "$($_.Path) ($($_.Problems))" })
        $lines | Should -BeNullOrEmpty -Because "the registry wins: $($lines -join '; ')"
    }

    It 'registers every key the schema names as read by a tool (used_by) with that attribute' {
        $byPath = @{}; foreach ($r in $script:Registry) { $byPath[$r.Path] = $r }
        foreach ($p in 'nodes[].bmc.ip_address', 'os_configuration.clear_storage', 'devops.platform', 'deployment.approval') {
            $byPath[$p].UsedBy | Should -Not -BeNullOrEmpty -Because "$p is read by a tool"
        }
    }

    It 'knows the keys added in schema 5.6: <_>' -ForEach @(
        'scenario.environment_class', 'os_configuration.remoting.transport', 'os_configuration.remoting.bootstrap_transport',
        'os_configuration.remoting.allowed_source_cidrs', 'os_configuration.clear_storage',
        'identity.active_directory.domain_join_account.username', 'identity.active_directory.join_options.allow_ou_move',
        'networking.logical_networks[].purpose', 'networking.cluster_networks[].purpose',
        'deployment.validate_timeout_minutes', 'devops.runners[].labels', 'networking.management.static_method'
    ) {
        ($script:Registry | ForEach-Object Path) | Should -Contain $_
    }

    It 'detects a key that is missing from the registry' {
        $fake = $script:Schema + [pscustomobject]@{
            Path = 'scenario.invented_key'; Type = 'string'; Format = ''; Enum = ''; ItemEnum = ''; Constraints = ''; Shape = 'scalar'
            Default = $null; HasDefault = $false; Required = $false; Since = ''; Deprecated = $false; Description = ''; Node = @{}
        }
        $cmp = Compare-RegistryToSchema -Registry $script:Registry -Schema $fake
        @($cmp.Missing | ForEach-Object Path) | Should -Be @('scenario.invented_key')
    }
}

Describe 'Registry validators' {
    It 'validate-registry.ps1 passes' {
        $out = & (Join-Path $script:Scripts 'validate-registry.ps1') -WarningAction SilentlyContinue
        ($out -join "`n") | Should -Match 'PASS: Registry structure validation passed'
    }

    It 'has no file of the old variables.yml layout: the infrastructure example is the only example' {
        foreach ($old in 'config\variables\variables.example.yml', 'config\variables\schema\variables.schema.json', 'config\variables\scripts\validate-variables.ps1', 'config\variables\scripts\Test-VariablesFile.ps1', 'config\variables\scripts\Test-VariableConfig.ps1') {
            Test-Path -LiteralPath (Join-Path $repo $old) | Should -BeFalse -Because "$old belongs to the old layout and is retired"
        }
        Test-Path -LiteralPath (Join-Path $repo 'config\variables\examples\infrastructure.example.yml') | Should -BeTrue
    }

    It 'the infrastructure example is valid against the schema and the rules' {
        $out = & pwsh -NoProfile -File (Join-Path $repo 'scripts\common\infrastructure\Test-InfrastructureFile.ps1') -Path (Join-Path $repo 'config\variables\examples\infrastructure.example.yml') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }

    It 'every alias added since registry 4.1.0 has an expiry inside the policy limit and a registry entry' {
        $policy = Get-Content (Join-Path $repo 'config\variables\schema\alias-policy.json') -Raw | ConvertFrom-Json
        $byPath = @{}; foreach ($r in $script:Registry) { $byPath[$r.Path] = $r }
        $new = @($policy.active_aliases | Where-Object { $_.PSObject.Properties.Name -contains 'expires_on' })
        # The 4.0 form security_groups_by_role was the one alias with an expiry; it is removed (registry 5.0.58), so the list can be empty.
        foreach ($a in $new) {
            $span = ([datetime]$a.expires_on - [datetime]$a.created).Days
            $span | Should -BeLessOrEqual $policy.rules.max_alias_age_days -Because "$($a.alias_path) lives longer than the policy allows"
            $byPath.ContainsKey($a.alias_path) | Should -BeTrue -Because "$($a.alias_path) must be in the registry (deprecated, with alias_for)"
            $byPath[$a.alias_path].AliasFor | Should -Be $a.canonical_target
        }
    }
}