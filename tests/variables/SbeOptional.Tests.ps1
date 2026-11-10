#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The Solution Builder Extension (SBE) PACKAGE is a requirement (registry 5.0.15: it is downloaded and available on a share the automation can read) and the BUILD-TIME SIDE-LOAD
# stays opt-in. The registry (config/variables/schema/master-registry.yaml) says so first; the schema, the reference and the rules follow it. No default re-enables an SBE
# delivery.
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

Describe 'The registry: the SBE package is a requirement, the build-time side-load is the opt-in' {
    It 'was bumped to 5.0.2 with a change-log entry that says the SBE is optional' {
        # Later versions may follow; the 5.0.2 entry stays in the change log.
        [version]$script:Raw._metadata.version | Should -BeGreaterOrEqual ([version]'5.0.2')
        $entry = @(@($script:Raw._metadata.change_log) | Where-Object { $_.version -eq '5.0.2' })[0]
        $entry | Should -Not -BeNullOrEmpty
        $entry.change | Should -Match 'hardware\.sbe'
        $entry.change | Should -Match 'optional'
    }
    It 'documents: the package is a requirement on a share, and only the build-time side-load is opt-in' {
        $script:ByPath['hardware.sbe'].Required | Should -Not -BeTrue
        $d = $script:ByPath['hardware.sbe'].Node.description
        $d | Should -Match 'is a REQUIREMENT'
        $d | Should -Match 'available on a share the automation can read'
        $d | Should -Match 'What stays opt-in is only the build-time side-load'
        $d | Should -Match 'default skip'
    }
    It 'registers the requirement keys (schema 5.6.4) and none of them has a default' {
        foreach ($k in 'requirement', 'not_applicable_reason', 'source_path', 'source_username', 'source_password', 'package_sha256', 'package_size_bytes') {
            $v = $script:ByPath["hardware.sbe.$k"]
            $v | Should -Not -BeNullOrEmpty -Because $k
            $v.Required | Should -Not -BeTrue -Because $k
            $v.HasDefault | Should -BeFalse -Because "$k must not default into an SBE"
            $v.Node.since | Should -Be '5.6.4' -Because $k
        }
        @($script:ByPath['hardware.sbe.requirement'].Node.enum) | Should -Be @('required', 'not_applicable')
        $script:ByPath['hardware.sbe.source_password'].Node.format | Should -Be 'kv_ref'
        $script:ByPath['hardware.sbe.source_password'].Node.sensitive | Should -BeTrue
        # 5.6.4 added the SBE keys; later minor versions only add optional keys, so the test must not pin the current version.
        $script:Raw._metadata.infrastructure_schema_version | Should -Match '^5\.6\.([4-9]|[1-9][0-9])$'
        @($script:Raw._metadata.change_log | Where-Object { $_.version -eq '5.0.15' }).Count | Should -Be 1
    }
    It 'says publisher, family and version are required only when hardware.sbe is present (and bundle_path is not): <_>' -ForEach 'publisher', 'family', 'version' {
        $v = $script:ByPath["hardware.sbe.$_"]
        $v.Required | Should -Not -BeTrue
        $v.Node.description | Should -Match 'hardware\.sbe is present and bundle_path is not'
    }
    It 'says what a package is: source_path of the three files, or the older bundle_path' {
        $d = $script:ByPath['hardware.sbe.source_path'].Node.description
        $d | Should -Match 'SBE_Discovery_<Vendor>\.xml'
        $d | Should -Match 'SBE_<Vendor>_<Family>_<Version>\.zip'
        $d | Should -Match 'bundle_path is used'
        $script:ByPath['hardware.sbe.bundle_path'].Node.description | Should -Match 'when source_path is set it is the one read'
    }
    It 'keeps delivery opt-in: the default is skip and nothing under hardware.sbe has another default' {
        $script:ByPath['hardware.sbe.delivery'].Default | Should -Be 'skip'
        $script:ByPath['hardware.sbe.delivery'].Node.description | Should -Match 'opt-in'
        $withDefault = @($script:Registry | Where-Object { $_.Path -like 'hardware.sbe.*' -and $_.HasDefault } | ForEach-Object Path)
        $withDefault | Should -Be @('hardware.sbe.delivery')
    }
    It 'asks the schema for the keys only when hardware.sbe is there (the rule is in _schema_rules)' {
        $script:SchemaJson | Should -Match '"anyOf":\s*\[\s*\{\s*"required":\s*\[\s*"bundle_path"\s*\]\s*\},\s*\{\s*"required":\s*\[\s*"source_path"\s*\]\s*\},\s*\{\s*"required":\s*\[\s*"requirement"\s*\]\s*\},\s*\{\s*"required":\s*\[\s*"publisher",\s*"family",\s*"version"\s*\]'
        $hardware = ($script:SchemaJson | ConvertFrom-Json -Depth 100).properties.hardware
        @($hardware.required) | Should -Not -Contain 'sbe'
    }
    It 'reaches the generated reference' {
        $script:Reference | Should -Match 'is a REQUIREMENT'
        $script:Reference | Should -Match 'hardware\.sbe\.source_path'
    }
}
