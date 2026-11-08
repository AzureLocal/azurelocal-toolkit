#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The Solution Builder Extension (SBE) is OPTIONAL and opt-in. The registry (config/variables/schema/master-registry.yaml) says so
# first; the schema, the reference and the rules follow it. No default re-enables an SBE or its delivery.
# Run: Invoke-Pester ./tests/variables/SbeOptional.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:RegistryPath = Join-Path $repo 'config\variables\schema\master-registry.yaml'
    Import-Module (Join-Path $repo 'config\variables\scripts\VariableRegistry.psm1') -Force
    $script:Raw = Read-RegistryYaml -Path $script:RegistryPath
    $script:Registry = @(Get-RegistryVariable -Path $script:RegistryPath -Registry $script:Raw)
    $script:ByPath = @{}; foreach ($r in $script:Registry) { $script:ByPath[$r.Path] = $r }
    $script:SchemaJson = Get-Content -LiteralPath (Join-Path $repo 'config\variables\schema\infrastructure.schema.json') -Raw
    $script:Reference = Get-Content -LiteralPath (Join-Path $repo 'config\variables\docs\VARIABLES.md') -Raw
}

Describe 'The registry makes the SBE optional' {
    It 'is bumped to 5.0.2 with a change-log entry that says the SBE is optional' {
        $script:Raw._metadata.version | Should -Be '5.0.2'
        $entry = @($script:Raw._metadata.change_log)[0]
        $entry.version | Should -Be '5.0.2'
        $entry.change | Should -Match 'hardware\.sbe'
        $entry.change | Should -Match 'optional'
    }
    It 'documents: no hardware.sbe = deploy without a Solution Builder Extension' {
        $script:ByPath['hardware.sbe'].Required | Should -Not -BeTrue
        $script:ByPath['hardware.sbe'].Node.description | Should -Match 'no hardware\.sbe = deploy without a Solution Builder Extension \(the OS keeps the OEM drivers already installed\)'
    }
    It 'says publisher, family and version are required only when hardware.sbe is present (and bundle_path is not): <_>' -ForEach 'publisher', 'family', 'version' {
        $v = $script:ByPath["hardware.sbe.$_"]
        $v.Required | Should -Not -BeTrue
        $v.Node.description | Should -Match 'hardware\.sbe is present and bundle_path is not'
    }
    It 'says a hardware.sbe that is there is complete with bundle_path, or publisher, family and version' {
        $script:ByPath['hardware.sbe'].Node.description | Should -Match 'bundle_path \(publisher, family and version are then read from the package\), or publisher, family and version'
    }
    It 'keeps delivery opt-in: the default is skip and nothing under hardware.sbe has another default' {
        $script:ByPath['hardware.sbe.delivery'].Default | Should -Be 'skip'
        $script:ByPath['hardware.sbe.delivery'].Node.description | Should -Match 'opt-in'
        $withDefault = @($script:Registry | Where-Object { $_.Path -like 'hardware.sbe.*' -and $_.HasDefault } | ForEach-Object Path)
        $withDefault | Should -Be @('hardware.sbe.delivery')
    }
    It 'asks the schema for the keys only when hardware.sbe is there (the rule is in _schema_rules)' {
        $script:SchemaJson | Should -Match '"anyOf":\s*\[\s*\{\s*"required":\s*\[\s*"bundle_path"\s*\]\s*\},\s*\{\s*"required":\s*\[\s*"publisher",\s*"family",\s*"version"\s*\]'
        $hardware = ($script:SchemaJson | ConvertFrom-Json -Depth 100).properties.hardware
        @($hardware.required) | Should -Not -Contain 'sbe'
    }
    It 'reaches the generated reference' {
        $script:Reference | Should -Match 'no hardware\.sbe = deploy without a Solution Builder Extension'
    }
}
