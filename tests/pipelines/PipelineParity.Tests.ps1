#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Owner directive D126: the CI/CD pipelines are one design on GitHub Actions, GitLab CI and Azure DevOps. Every pipeline calls the same PowerShell entry
# scripts with the values of infrastructure.yml, binds the same approval environments and refuses a change while one is not set, starts by hand, and runs on
# the same schedule; no logic of one platform only is left. pipelines/New-PipelineParity.ps1 generates pipelines/PARITY.md from the files; this test fails
# when the table is out of date or a row is not Equal, and checks the parts of the design the table does not show (the Azure DevOps settings file, the
# schedule of the check for updates, and the task 05 code that writes them). Nothing is run on a platform and nothing is sent anywhere.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines/PipelineParity.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks with -ModuleName run in the module scope, so the call recorder is shared through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Module = Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')) -Force -PassThru
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
    $script:Example = [IO.Path]::Combine($script:Repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    function Get-Text([string]$File) { [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $File)) }
    function Get-Yaml([string]$File) { ConvertFrom-Yaml (Get-Text $File) -Ordered }
    function Get-Settings([string]$Platform, [scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        $doc.devops.Remove('api_token')
        if ($Change) { & $Change $doc }
        return ConvertTo-AzlCicdSetting -Infrastructure $doc -Platform $Platform
    }
    # A copy of the pipeline files the generator writes into, so the toolkit's own files are never changed by a test.
    function New-RepositoryCopy {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        foreach ($relative in 'pipelines/azure-devops/variables/pipeline-settings.yml', 'pipelines/azure-devops/variables/approval-environments.yml', 'pipelines/azure-devops/day2-check-updates.yml', 'pipelines/github-actions/day2-check-updates.yml') {
            $target = Join-Path $root $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath ([IO.Path]::Combine($script:Repo, $relative)) -Destination $target
        }
        return $root
    }
    $script:CronDefault = [string]@($script:Registry | Where-Object Path -EQ 'devops.pipelines.schedules.check_for_updates')[0].Node['default']
    $script:BranchDefault = [string]@($script:Registry | Where-Object Path -EQ 'devops.repository.default_branch')[0].Node['default']
}

Describe 'The generated parity table (pipelines/PARITY.md)' {
    It 'is current: New-PipelineParity.ps1 -Check passes' {
        $global:LASTEXITCODE = 0
        & ([IO.Path]::Combine($script:Repo, 'pipelines', 'New-PipelineParity.ps1')) -Check -RepositoryRoot $script:Repo 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because 'run ./pipelines/New-PipelineParity.ps1 after changing a pipeline file'
    }
    It 'every pipeline is Equal on GitHub Actions, GitLab CI and Azure DevOps' {
        $rows = @((Get-Text 'pipelines/PARITY.md') -split "`r?`n" | Where-Object { $_ -match '^\| [a-z0-9-]+ \| `scripts/|^\| [a-z0-9-]+ \| `config/|^\| [a-z0-9-]+ \| none \|' })
        $rows.Count | Should -Be 12
        @($rows | Where-Object { $_ -notmatch '\| Equal \|$' }) | Should -BeNullOrEmpty
    }
    It 'lists every pipeline file: none is left out of the table' {
        (Get-Text 'pipelines/PARITY.md') | Should -Match 'Pipeline files that are not in the table\s+None\.'
    }
}

Describe 'Azure DevOps reads the deployment values from the generated settings file, never from a run parameter (D126)' {
    BeforeDiscovery {
        $root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'pipelines', 'azure-devops'))
        $script:AdoFiles = @(Get-ChildItem -LiteralPath $root -Filter '*.yml' -File | ForEach-Object { @{ File = "pipelines/azure-devops/$($_.Name)" } })
    }
    It 'the settings file defines the five values, empty in the toolkit, and no variable group' {
        $doc = Get-Yaml 'pipelines/azure-devops/variables/pipeline-settings.yml'
        @($doc['variables'] | ForEach-Object { [string]$_['name'] }) | Should -Be @('AZL_AGENT_POOL', 'AZL_SERVICE_CONNECTION', 'AZL_VARIABLE_GROUP', 'AZL_INFRASTRUCTURE_FILE', 'AZL_HANDOFF_PATH')
        foreach ($v in $doc['variables']) { [string]$v['value'] | Should -Be '' -Because "no value of a deployment is written in the toolkit ($($v['name']))" }
        (Get-Text 'pipelines/azure-devops/variables/pipeline-settings.yml') | Should -Not -Match '(?m)^\s+- group:'
    }
    It '<File> includes the settings file and has no run parameter for a pool, a service connection, a variable group or a file path' -ForEach $script:AdoFiles {
        $text = Get-Text $File
        $text | Should -Match '(?m)^\s+- template: variables/pipeline-settings\.yml\r?$'
        $text | Should -Not -Match 'parameters\.(agent_?[Pp]ool|azureServiceConnection|service_?[Cc]onnection|variable_?[Gg]roup|infrastructure_?[Ff]ile|handoff_path)\b'
        $text | Should -Not -Match '(?m)^\s+- group: '
        $names = @((Get-Yaml $File)['parameters'] | Where-Object { $_ } | ForEach-Object { [string]$_['name'] })
        @($names | Where-Object { $_ -match '(?i)pool|connection|group|infrastructure|handoff_path' }) | Should -BeNullOrEmpty
        foreach ($line in @($text -split "`r?`n" | Where-Object { $_ -match '^\s+name: \$\{\{' })) { $line | Should -Match '^\s+name: \$\{\{ variables\.AZL_AGENT_POOL \}\}\r?$' }
    }
    It 'the scheduled pipeline (day2-check-updates.yml) has a default for every parameter, so a schedule can start it' {
        foreach ($p in @((Get-Yaml 'pipelines/azure-devops/day2-check-updates.yml')['parameters'] | Where-Object { $_ })) { $p.Contains('default') | Should -BeTrue -Because "parameter $($p['name'])" }
    }
    It '<File>: a parameter without a default is a choice of one run (the node of a day 2 operation), never a deployment value' -ForEach $script:AdoFiles {
        foreach ($p in @((Get-Yaml $File)['parameters'] | Where-Object { $_ -and -not $_.Contains('default') })) { [string]$p['name'] | Should -BeIn @('node') -Because "$File parameter $($p['name'])" }
    }
}

Describe 'The check for updates runs on the schedule devops.pipelines.schedules.check_for_updates on every platform (D74, D126)' {
    It 'GitHub and Azure DevOps carry the registry default in the cron line; Azure DevOps runs it on the registry default branch, always' {
        $github = Get-Yaml 'pipelines/github-actions/day2-check-updates.yml'
        $on = if ($github.Contains('on')) { $github['on'] } else { $github[$true] }
        @($on['schedule'])[0]['cron'] | Should -Be $script:CronDefault
        $ado = Get-Yaml 'pipelines/azure-devops/day2-check-updates.yml'
        @($ado['schedules']).Count | Should -Be 1
        @($ado['schedules'])[0]['cron'] | Should -Be $script:CronDefault
        @(@($ado['schedules'])[0]['branches']['include']) | Should -Be @($script:BranchDefault)
        @($ado['schedules'])[0]['always'] | Should -BeTrue
        $ado['trigger'] | Should -Be 'none'
        $ado['pr'] | Should -Be 'none'
    }
    It 'GitLab creates the pipeline from a schedule, and only the check for updates runs on one' {
        (Get-Text 'pipelines/gitlab/stages/day2-check-updates.yml') | Should -Match "(?m)^workflow:\r?\n  rules:\r?\n    - if: '\`$CI_PIPELINE_SOURCE =~ /\^\(schedule\|web\|api\)\`$/'"
        foreach ($f in @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'gitlab')) -Recurse -Filter '*.yml' -File -Force | Where-Object Name -NE 'day2-check-updates.yml')) {
            [IO.File]::ReadAllText($f.FullName) | Should -Not -Match 'schedule\|' -Because "$($f.Name) does not run on a schedule"
        }
    }
    It 'task 05 writes the cron line and the branch into the Azure DevOps files, with the settings and the approval environments' {
        $root = New-RepositoryCopy
        $s = Get-Settings 'azure_devops' {
            param($d)
            $d.devops.runners[0].pool = 'pool-iic-lnx'
            $d.devops.pipelines['schedules'] = [ordered]@{ check_for_updates = '30 2 * * 1-5' }
            $d.devops.repository.default_branch = 'trunk'
        }
        $r = @(Export-AzlCicdPipelineSetting -Settings $s -RepositoryRoot $root -Confirm:$false)
        @($r | Where-Object Status -EQ 'Updated').Count | Should -Be 3
        $settings = ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $root 'pipelines/azure-devops/variables/pipeline-settings.yml'))) -Ordered
        $values = @{}; foreach ($v in $settings['variables']) { if ($v.Contains('name')) { $values[[string]$v['name']] = [string]$v['value'] } }
        $values['AZL_AGENT_POOL'] | Should -Be 'pool-iic-lnx'
        $values['AZL_SERVICE_CONNECTION'] | Should -Be 'iic-azure-local'
        $values['AZL_VARIABLE_GROUP'] | Should -Be 'iic-azure-credentials'
        $values['AZL_INFRASTRUCTURE_FILE'] | Should -Be 'config/infrastructure.yml'
        @($settings['variables'] | Where-Object { $_.Contains('group') }).Count | Should -Be 1
        @($settings['variables'] | Where-Object { $_.Contains('group') })[0]['group'] | Should -Be 'iic-azure-credentials'
        $approvals = ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $root 'pipelines/azure-devops/variables/approval-environments.yml'))) -Ordered
        (@($approvals['variables'] | Where-Object { $_['name'] -eq 'AZL_ENVIRONMENT_ARM_DEPLOYMENT' })[0]['value']) | Should -Be 'azr-prod-us'
        $ado = ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $root 'pipelines/azure-devops/day2-check-updates.yml'))) -Ordered
        @($ado['schedules'])[0]['cron'] | Should -Be '30 2 * * 1-5'
        @(@($ado['schedules'])[0]['branches']['include']) | Should -Be @('trunk')
        # a second run changes nothing
        @(Export-AzlCicdPipelineSetting -Settings $s -RepositoryRoot $root -Confirm:$false | Where-Object Status -EQ 'Updated').Count | Should -Be 0
    }
    It 'task 05 writes the cron line of the GitHub workflow, and -WhatIf writes nothing' {
        $root = New-RepositoryCopy
        $s = Get-Settings 'github' { param($d) $d.devops.pipelines['schedules'] = [ordered]@{ check_for_updates = '5 1 * * *' } }
        $before = [IO.File]::ReadAllText((Join-Path $root 'pipelines/github-actions/day2-check-updates.yml'))
        @(Export-AzlCicdPipelineSetting -Settings $s -RepositoryRoot $root -WhatIf | Where-Object Status -EQ 'Planned').Count | Should -Be 1
        [IO.File]::ReadAllText((Join-Path $root 'pipelines/github-actions/day2-check-updates.yml')) | Should -BeExactly $before
        Export-AzlCicdPipelineSetting -Settings $s -RepositoryRoot $root -Confirm:$false | Out-Null
        $doc = ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $root 'pipelines/github-actions/day2-check-updates.yml'))) -Ordered
        $on = if ($doc.Contains('on')) { $doc['on'] } else { $doc[$true] }
        @($on['schedule'])[0]['cron'] | Should -Be '5 1 * * *'
    }
    It 'a cron expression is five fields, each in its range (minute, hour, day, month, weekday)' {
        foreach ($good in '17 4 * * *', '30 2 * * 1-5', '0 */6 * * MON', '5 0 1,15 JAN-JUN SUN') { (& $script:Module { param($c) Test-AzlCronExpression $c } $good) | Should -BeTrue -Because $good }
        foreach ($bad in '99 99 99 99 99', '17 4 * *', 'every day', '0 24 * * *', '0 0 0 * *', '0 0 * 13 *', '*/0 * * * *', '0 0 * * FUNDAY') { (& $script:Module { param($c) Test-AzlCronExpression $c } $bad) | Should -BeFalse -Because $bad }
    }
    It 'task 05 refuses a schedule that is not a five-field cron expression, and writes nothing' {
        $root = New-RepositoryCopy
        $s = Get-Settings 'github' { param($d) $d.devops.pipelines['schedules'] = [ordered]@{ check_for_updates = 'every day' } }
        { Export-AzlCicdPipelineSetting -Settings $s -RepositoryRoot $root -Confirm:$false } | Should -Throw '*not a five-field cron expression*'
    }
    It 'GitLab: task 05 creates the project schedule once, then updates it, on the default branch in UTC' {
        $global:AzlScheduleCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlScheduleExisting = @()
        Mock -ModuleName AzlCicdInfra Invoke-AzlGitLab {
            $global:AzlScheduleCalls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Method -eq 'GET' -and $Path -like 'projects/*/pipeline_schedules*') { return $global:AzlScheduleExisting }
            if ($Method -eq 'GET') { return [pscustomobject]@{ id = 42 } }
            return [pscustomobject]@{ id = 7 }
        }
        $s = Get-Settings 'gitlab' { param($d) $d.devops.url = 'https://gitlab.example.com'; $d.devops.pipelines['schedules'] = [ordered]@{ check_for_updates = '17 4 * * *' } }
        $r = Set-AzlGitLabPipelineSchedule -Settings $s -Cron '17 4 * * *' -Confirm:$false
        $r.Status | Should -Be 'Created'
        $post = @($global:AzlScheduleCalls | Where-Object Method -EQ 'POST')
        $post.Count | Should -Be 1
        $post[0].Path | Should -Be 'projects/42/pipeline_schedules'
        $post[0].Body.cron | Should -Be '17 4 * * *'
        $post[0].Body.cron_timezone | Should -Be 'UTC'
        $post[0].Body.ref | Should -Be 'main'
        $global:AzlScheduleCalls.Clear()
        $global:AzlScheduleExisting = @([pscustomobject]@{ id = 9; description = (& $script:Module { $script:AzlCheckForUpdatesScheduleDescription }) })
        (Set-AzlGitLabPipelineSchedule -Settings $s -Cron '0 5 * * *' -Confirm:$false).Status | Should -Be 'Updated'
        @($global:AzlScheduleCalls | Where-Object Method -EQ 'PUT')[0].Path | Should -Be 'projects/42/pipeline_schedules/9'
        @($global:AzlScheduleCalls | Where-Object Method -EQ 'POST').Count | Should -Be 0
        $global:AzlScheduleCalls.Clear()
        (Set-AzlGitLabPipelineSchedule -Settings $s -Cron '0 5 * * *' -WhatIf).Status | Should -Be 'Planned'
        @($global:AzlScheduleCalls | Where-Object { $_.Method -in 'POST', 'PUT' }).Count | Should -Be 0
        Remove-Variable -Name AzlScheduleCalls, AzlScheduleExisting -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Every pipeline starts by hand on every platform (D126)' {
    It 'GitHub: workflow_dispatch, and no push or pull_request trigger' {
        foreach ($f in @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'github-actions')) -Filter '*.yml' -File)) {
            $doc = ConvertFrom-Yaml ([IO.File]::ReadAllText($f.FullName)) -Ordered
            $on = if ($doc.Contains('on')) { $doc['on'] } else { $doc[$true] }
            $on.Contains('workflow_dispatch') | Should -BeTrue -Because $f.Name
            $on.Contains('push') | Should -BeFalse -Because $f.Name
            $on.Contains('pull_request') | Should -BeFalse -Because $f.Name
        }
    }
    It 'Azure DevOps: trigger none and pr none' {
        foreach ($f in @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'azure-devops')) -Filter '*.yml' -File)) {
            $doc = ConvertFrom-Yaml ([IO.File]::ReadAllText($f.FullName)) -Ordered
            $doc['trigger'] | Should -Be 'none' -Because $f.Name
            $doc['pr'] | Should -Be 'none' -Because $f.Name
        }
    }
    It 'GitLab: every pipeline file has a workflow rule for the web form and the API (and the schedule for the check for updates only)' {
        foreach ($f in 'pipelines/gitlab/.gitlab-ci.yml', 'pipelines/gitlab/os-configuration.gitlab-ci.yml', 'pipelines/gitlab/stages/discovery.yml', 'pipelines/gitlab/stages/pre-cluster-verification.yml', 'pipelines/gitlab/stages/arm-deployment.yml', 'pipelines/gitlab/stages/post-deployment.yml', 'pipelines/gitlab/stages/validation.yml', 'pipelines/gitlab/stages/day2-update.yml', 'pipelines/gitlab/stages/day2-node-maintenance.yml', 'pipelines/gitlab/stages/day2-cluster-operations.yml') {
            $doc = Get-Yaml $f
            [string]@($doc['workflow']['rules'])[0]['if'] | Should -Be '$CI_PIPELINE_SOURCE =~ /^(web|api)$/' -Because $f
        }
    }
}
