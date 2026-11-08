#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Schema 5.6: the optional deployment block, its validator rule AZL-040, and the generated variables reference.

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $script:Schema = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $script:Repo = $repo
    function Get-Finding([scriptblock]$Change) {
        $infra = Import-AzlInfrastructure -Path $script:Example
        $infra._metadata.schema_version = '5.6.0'
        & $Change $infra
        $file = Join-Path $TestDrive ('f-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.yml')
        ConvertTo-Yaml $infra | Set-Content -LiteralPath $file
        @(Test-AzlInfrastructure -Path $file)
    }
}

Describe 'The deployment block (schema 5.6)' {
    It 'the example file is clean, and so is a file with every key set to a good value' {
        @(Get-Finding { }) | Should -BeNullOrEmpty
        $f = Get-Finding { param($i) $i.deployment = [ordered]@{
                validate_timeout_minutes = 120; deploy_timeout_minutes = 480; poll_seconds = 10; poll_max_seconds = 60; approval = 'prompt'; resume = $true
                require_os_configuration_report = $true; skip_preconditions = @('NamesAvailable'); acknowledge_known_issues = @('arc-device-id-name'); deployment_settings_api_version = '2026-10-01'
                solution_version = '12.2610.1004.50'; sbe_catalog_path = 'D:/sbe/dell/SBE_Discovery_Dell.xml' } }
        $f | Should -BeNullOrEmpty
    }
    It 'rejects an unknown key, a bad approval, a timeout out of range and an unknown precondition name' {
        (Get-Finding { param($i) $i.deployment = [ordered]@{ nonsense = 1 } }).Id | Should -Contain 'SCHEMA'
        (Get-Finding { param($i) $i.deployment = [ordered]@{ approval = 'maybe' } }) | Should -Not -BeNullOrEmpty
        (Get-Finding { param($i) $i.deployment = [ordered]@{ validate_timeout_minutes = 1 } }) | Should -Not -BeNullOrEmpty
        (Get-Finding { param($i) $i.deployment = [ordered]@{ skip_preconditions = @('Everything') } }) | Should -Not -BeNullOrEmpty
    }
    It 'the schema lists exactly the preconditions the run has' {
        $enum = @($script:Schema.properties.deployment.properties.skip_preconditions.items.enum)
        $enum | Should -Be @(Get-AzlArmPreconditionName)
    }
    It 'the schema defaults are the run''s defaults' {
        $p = $script:Schema.properties.deployment.properties
        $s = Get-AzlArmRunSetting
        $p.validate_timeout_minutes.default | Should -Be $s.validateTimeoutMinutes
        $p.deploy_timeout_minutes.default | Should -Be $s.deployTimeoutMinutes
        $p.poll_seconds.default | Should -Be $s.pollSeconds
        $p.poll_max_seconds.default | Should -Be $s.pollMaxSeconds
        $p.approval.default | Should -Be $s.approvalMode
        $p.resume.default | Should -Be $s.resume
        $p.require_os_configuration_report.default | Should -Be $s.requireOsConfigurationReport
    }
    It 'every key of the block is a setting of the run' {
        foreach ($k in $script:Schema.properties.deployment.properties.Keys) {
            $def = $script:Schema.properties.deployment.properties[$k]
            $value = if ($def.Contains('default')) { $def.default } elseif ($def.type -eq 'array') { @() } elseif ($def.Contains('pattern')) { '12.2610.1004.50' } else { 'x' }
            { Get-AzlArmRunSetting -Infrastructure @{ deployment = @{ $k = $value } } } | Should -Not -Throw
        }
    }}

Describe 'AZL-040: the deployment options' {
    It 'poll_max_seconds below poll_seconds is an error' {
        $f = Get-Finding { param($i) $i.deployment = [ordered]@{ poll_seconds = 60; poll_max_seconds = 30 } }
        $f.Id | Should -Contain 'AZL-040'
        ($f | Where-Object Id -eq 'AZL-040').Severity | Should -Be 'error'
    }
    It 'short time limits and approval none are warnings' {
        $f = Get-Finding { param($i) $i.deployment = [ordered]@{ validate_timeout_minutes = 20; deploy_timeout_minutes = 120; approval = 'none' } }
        @($f | Where-Object Id -eq 'AZL-040').Count | Should -Be 3
        @($f | Where-Object Id -eq 'AZL-040' | Where-Object Severity -ne 'warning') | Should -BeNullOrEmpty
    }
    It 'an acknowledged id that does not exist is a warning that lists the ids; a real one is quiet' {
        $f = Get-Finding { param($i) $i.deployment = [ordered]@{ acknowledge_known_issues = @('no-such-issue') } }
        ($f | Where-Object Id -eq 'AZL-040').Message | Should -Match 'arc-device-id-name'
        @(Get-Finding { param($i) $i.deployment = [ordered]@{ acknowledge_known_issues = @('arc-device-id-name') } }) | Should -BeNullOrEmpty
    }
    It 'the run takes the block from the master file' {
        $s = Get-AzlArmRunSetting -Infrastructure @{ deployment = @{ approval = 'none'; deploy_timeout_minutes = 400 } }
        $s.approvalMode | Should -Be 'none'
        $s.deployTimeoutMinutes | Should -Be 400
    }
}

Describe 'The variables reference' {
    It 'is current (New-InfrastructureVariablesReference.ps1 -Check)' {
        $out = & pwsh -NoProfile -NonInteractive -File ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'New-InfrastructureVariablesReference.ps1')) -Check 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }
    It 'documents every key of the deployment block' {
        $text = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'docs', 'VARIABLES.md')) -Raw
        foreach ($k in $script:Schema.properties.deployment.properties.Keys) { $text | Should -Match ([regex]::Escape("``deployment.$k``")) }
    }
}
