#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The OS configuration pipeline definitions (GitHub Actions, GitLab CI) parse, call the one entry point with parameters that exist,
# keep the approval gate, and carry no value of any ID or secret. Nothing is run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:GitHubFile = [IO.Path]::Combine($repo, 'pipelines', 'github', 'os-configuration.yml')
    $script:GitLabFile = [IO.Path]::Combine($repo, 'pipelines', 'gitlab', 'os-configuration.gitlab-ci.yml')
    $script:EntryScript = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Invoke-AzureLocalOsConfiguration.ps1')
    Import-Module powershell-yaml
    $script:GitHub = ConvertFrom-Yaml (Get-Content -LiteralPath $script:GitHubFile -Raw)
    $script:GitLab = ConvertFrom-Yaml (Get-Content -LiteralPath $script:GitLabFile -Raw)

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:EntryScript, [ref]$tokens, [ref]$errors)
    $script:EntryParameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

    # Every text value in a parsed YAML document.
    function Get-YamlText($Node) {
        if ($Node -is [System.Collections.IDictionary]) { foreach ($k in $Node.Keys) { Get-YamlText $Node[$k] } }
        elseif ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { Get-YamlText $i } }
        elseif ($Node -is [string]) { $Node }
    }
    $script:AllText = @{
        GitHub = (Get-Content -LiteralPath $script:GitHubFile -Raw)
        GitLab = (Get-Content -LiteralPath $script:GitLabFile -Raw)
    }
}

Describe 'The entry point the pipelines call' {
    It 'exists with the parameters the pipelines pass' {
        Test-Path -LiteralPath $script:EntryScript | Should -BeTrue
        foreach ($p in 'InfrastructureFile', 'HandoffPath', 'Mode', 'ReportDirectory', 'Node', 'Step', 'ContinueOnNodeFailure', 'Transport', 'ClearStorage', 'SettingsFile', 'Settings') {
            $script:EntryParameters | Should -Contain $p
        }
    }
    It '<Name> passes only parameters that exist' -ForEach @(@{ Name = 'GitHub' }, @{ Name = 'GitLab' }) {
        $calls = [regex]::Matches($script:AllText[$Name], '(?m)Invoke-AzureLocalOsConfiguration\.ps1|"\$OSCONFIG_SCRIPT"[^\r\n]*')
        $calls.Count | Should -BeGreaterThan 0
        $used = [regex]::Matches($script:AllText[$Name], '(?m)"\$OSCONFIG_SCRIPT"([^\r\n]*)') | ForEach-Object { [regex]::Matches($_.Groups[1].Value, '\s-([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } }
        $used.Count | Should -BeGreaterThan 0
        foreach ($u in $used) { $script:EntryParameters | Should -Contain $u }
    }
}

Describe 'The apply is bound to the wipe list the Plan stage published' {
    It 'the entry point takes -ApprovedWipeList' { $script:EntryParameters | Should -Contain 'ApprovedWipeList' }
    It 'GitHub: the apply job downloads the plan artifact and passes its wipe-list.json' {
        $steps = $script:GitHub['jobs']['apply']['steps']
        $download = @($steps | Where-Object { $_['uses'] -like 'actions/download-artifact*' -and $_['with']['name'] -eq 'os-configuration-plan' })
        $download.Count | Should -Be 1
        $run = ($steps | ForEach-Object { $_['run'] }) -join "`n"
        $run | Should -Match '-Mode Apply[^\r\n]*-ApprovedWipeList "\$RUNNER_TEMP/osconfig-plan/wipe-list\.json"'
        $download[0]['with']['path'] | Should -Be '${{ runner.temp }}/osconfig-plan'
    }
    It 'GitLab: the apply job passes the wipe-list.json of the plan job (the artifact comes with needs)' {
        $apply = $script:GitLab['os-configuration-apply']
        @($apply['script']) -join "`n" | Should -Match '-Mode Apply[^\r\n]*-ApprovedWipeList "\$REPORT_DIRECTORY/plan/wipe-list\.json"'
        @($apply['needs']) | Should -Contain 'os-configuration-plan'
    }
}

Describe 'GitHub Actions workflow' {
    It 'parses and is a dispatch workflow with the infrastructure file and the mode as inputs' {
        $script:GitHub | Should -Not -BeNullOrEmpty
        $on = if ($script:GitHub.Contains('on')) { $script:GitHub['on'] } else { $script:GitHub[$true] }
        $inputs = $on['workflow_dispatch']['inputs']
        $inputs.Keys | Should -Contain 'infrastructure_file'
        $inputs.Keys | Should -Contain 'mode'
        $inputs['mode']['options'] | Should -Be @('Plan', 'Apply')
        $inputs['infrastructure_file']['required'] | Should -BeTrue
    }
    It 'has a plan job and an apply job that needs it' {
        $script:GitHub['jobs'].Keys | Should -Contain 'plan'
        $script:GitHub['jobs'].Keys | Should -Contain 'apply'
        @($script:GitHub['jobs']['apply']['needs']) | Should -Contain 'plan'
    }
    It 'gates the apply job with the environment of the variable AZL_ENVIRONMENT_OS_CONFIGURATION, and not the plan job' {
        $script:GitHub['jobs']['apply']['environment'] | Should -Be '${{ vars.AZL_ENVIRONMENT_OS_CONFIGURATION }}'
        $script:GitHub['jobs']['plan'].Contains('environment') | Should -BeFalse
    }
    It 'plan runs -Mode Plan, apply runs -Mode Apply, both through the one script' {
        $plan = ($script:GitHub['jobs']['plan']['steps'] | ForEach-Object { $_['run'] }) -join "`n"
        $apply = ($script:GitHub['jobs']['apply']['steps'] | ForEach-Object { $_['run'] }) -join "`n"
        $plan | Should -Match '-Mode Plan'
        $plan | Should -Not -Match '-Mode Apply'
        $apply | Should -Match '-Mode Apply'
        $script:GitHub['env']['OSCONFIG_SCRIPT'] | Should -Be 'scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1'
        Test-Path -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Invoke-AzureLocalOsConfiguration.ps1')) | Should -BeTrue
        $plan | Should -Match 'pwsh -NoProfile -File'
        $plan | Should -Match '-InfrastructureFile'
        $plan | Should -Match '-HandoffPath'
    }
    It 'plan publishes the report and the wipe list as an artifact and in the job summary; apply publishes the report' {
        $planSteps = $script:GitHub['jobs']['plan']['steps']
        @($planSteps | Where-Object { $_['uses'] -like 'actions/upload-artifact@*' }).Count | Should -Be 1
        (($planSteps | ForEach-Object { $_['run'] }) -join "`n") | Should -Match 'GITHUB_STEP_SUMMARY'
        @($script:GitHub['jobs']['apply']['steps'] | Where-Object { $_['uses'] -like 'actions/upload-artifact@*' }).Count | Should -Be 1
    }
    It 'logs in to Azure by OIDC with variable names only' {
        $script:GitHub['permissions']['id-token'] | Should -Be 'write'
        foreach ($job in 'plan', 'apply') {
            $login = $script:GitHub['jobs'][$job]['steps'] | Where-Object { $_['uses'] -like 'azure/login@*' }
            $login | Should -Not -BeNullOrEmpty
            $login['with']['client-id'] | Should -Be '${{ vars.AZURE_CLIENT_ID }}'
            $login['with']['tenant-id'] | Should -Be '${{ vars.AZURE_TENANT_ID }}'
            $login['with']['subscription-id'] | Should -Be '${{ vars.AZURE_SUBSCRIPTION_ID }}'
        }
    }
    It 'allows one run at a time' {
        $script:GitHub['concurrency']['group'] | Should -Be 'azure-local-os-configuration'
        $script:GitHub['concurrency']['cancel-in-progress'] | Should -BeFalse
    }
}

Describe 'GitLab CI pipeline' {
    It 'parses and has the stages plan then apply' {
        @($script:GitLab['stages']) | Should -Be @('plan', 'apply')
    }
    It 'has a plan job and a manual apply job that cannot run at the same time as another run' {
        $plan = $script:GitLab['os-configuration-plan']
        $apply = $script:GitLab['os-configuration-apply']
        $plan['stage'] | Should -Be 'plan'
        $apply['stage'] | Should -Be 'apply'
        $apply['when'] | Should -Be 'manual'
        $apply['allow_failure'] | Should -BeFalse
        $plan['resource_group'] | Should -Be 'azure-local-os-configuration'
        $apply['resource_group'] | Should -Be 'azure-local-os-configuration'
        @($apply['needs']) | Should -Contain 'os-configuration-plan'
    }
    It 'runs the one script with -Mode Plan and -Mode Apply' {
        ($script:GitLab['os-configuration-plan']['script'] -join "`n") | Should -Match 'pwsh -NoProfile -File "\$OSCONFIG_SCRIPT" .*-Mode Plan'
        ($script:GitLab['os-configuration-apply']['script'] -join "`n") | Should -Match 'pwsh -NoProfile -File "\$OSCONFIG_SCRIPT" .*-Mode Apply'
        $script:GitLab['variables']['OSCONFIG_SCRIPT'] | Should -Be 'scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1'
    }
    It 'keeps the reports as artifacts, even when the job failed' {
        foreach ($job in 'os-configuration-plan', 'os-configuration-apply') {
            $script:GitLab[$job]['artifacts']['when'] | Should -Be 'always'
            @($script:GitLab[$job]['artifacts']['paths']).Count | Should -BeGreaterThan 0
        }
    }
    It 'authenticates with the runner''s managed identity or an OIDC id_token, and the IDs are placeholders' {
        $script:GitLab['.os-configuration']['id_tokens']['AZURE_ID_TOKEN']['aud'] | Should -Be 'api://AzureADTokenExchange'
        $v = $script:GitLab['variables']
        $v['AZURE_AUTH'] | Should -Match 'managed-identity'
        foreach ($k in 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID') { $v[$k] | Should -BeLike '<*>' }
        $script:GitLab['.os-configuration']['before_script'] -join "`n" | Should -Match 'Connect-AzAccount -Identity'
        $script:GitLab['.os-configuration']['before_script'] -join "`n" | Should -Match '-FederatedToken'
    }
    It 'extends the shared job in both jobs' {
        $script:GitLab['os-configuration-plan']['extends'] | Should -Be '.os-configuration'
        $script:GitLab['os-configuration-apply']['extends'] | Should -Be '.os-configuration'
    }
}

Describe 'No value of any ID or secret' -ForEach @(@{ Name = 'GitHub' }, @{ Name = 'GitLab' }) {
    It '<Name> holds no GUID, password, token or key' {
        $text = $script:AllText[$Name]
        $text | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $text | Should -Not -Match '(?im)^\s*(password|secret|client-secret|token)\s*:\s*[^\s$<{]'
        $text | Should -Not -Match 'ghp_[A-Za-z0-9]{20,}|AccountKey=|-----BEGIN'
    }
}
