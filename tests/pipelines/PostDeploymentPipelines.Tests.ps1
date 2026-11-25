#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The post-deployment pipeline (phase 06 of the cluster deployment), once per platform (GitHub Actions, GitLab CI, Azure DevOps): the three files parse, call only
# scripts that exist with parameters those scripts have, take no credential, validate the master file first, plan with -Mode Plan before anything is applied, apply
# with -Mode Apply only for the mode Apply and only behind the approval environment of devops.pipelines.environments.operations (and refuse while it is not set),
# map the selection inputs to -Only, -From and -To, publish the report even when the run failed, fail the run on a failed script, start only by hand, and read every
# value from the variables of task 05. Nothing is run and nothing is sent anywhere (owner directive D124: no pipeline is run on a platform before the manual runs).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines/PostDeploymentPipelines.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $script:Files = @(
        @{ Platform = 'GitHub'; File = 'pipelines/github-actions/post-deployment.yml' }
        @{ Platform = 'GitLab'; File = 'pipelines/gitlab/stages/post-deployment.yml' }
        @{ Platform = 'AzureDevOps'; File = 'pipelines/azure-devops/post-deployment.yml' }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    function Get-Text([string]$File) { [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $File)) }
    function Get-Yaml([string]$File) { ConvertFrom-Yaml (Get-Text $File) -Ordered }
    function Get-CodeText([string]$File) { ((Get-Text $File) -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n" }
    function Get-Param([string]$Relative) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($script:Repo, $Relative), [ref]$tokens, [ref]$errors)
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }
    # The parameters a pipeline passes: the keys of `$p = @{ ... }` and every `$p.Name = ...`.
    function Get-PassedParameter([string]$Text) {
        @([regex]::Matches($Text, '\$p = @\{([^\r\n]*)\}') | ForEach-Object { [regex]::Matches($_.Groups[1].Value, '(?:^|;)\s*([A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value } }) +
        @([regex]::Matches($Text, '\$p\.([A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    }
    function Find-Stage($Node, [string]$Name) {
        if ($Node -is [System.Collections.IDictionary]) { if ($Node.Contains('stage') -and $Node['stage'] -eq $Name) { $Node }; foreach ($k in $Node.Keys) { Find-Stage $Node[$k] $Name } }
        elseif ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { Find-Stage $i $Name } }
    }
    $script:Orchestrator = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/Invoke-AzureLocalPostDeployment.ps1'
    $script:Validator = 'scripts/common/infrastructure/Test-InfrastructureFile.ps1'
}

Describe 'The post-deployment pipeline: every file' {
    It '<Platform> parses, and every script it names exists' -ForEach $script:Files {
        { Get-Yaml $File } | Should -Not -Throw
        (Get-Yaml $File) | Should -Not -BeNullOrEmpty
        $named = @([regex]::Matches((Get-Text $File), 'scripts/[A-Za-z0-9._/-]+\.ps1') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        foreach ($n in $named) { Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, $n)) | Should -BeTrue -Because "$File names $n" }
        $named | Should -Contain $script:Orchestrator
        $named | Should -Contain $script:Validator
        @($named | Where-Object { $_ -notin $script:Orchestrator, $script:Validator }) | Should -BeNullOrEmpty -Because 'the pipeline runs the one orchestrator (and checks the file first), never a task script of its own'
    }
    It '<Platform> passes only parameters of the orchestrator, none of a credential, a machine or a skipped check' -ForEach $script:Files {
        $text = Get-Text $File
        $known = Get-Param $script:Orchestrator
        $passed = @(Get-PassedParameter $text)
        $passed | Should -Contain 'InfrastructureFile'
        $passed | Should -Contain 'Mode'
        $passed | Should -Contain 'LogPath'
        foreach ($p in $passed) { $known | Should -Contain $p -Because "$File passes -$p" }
        @($passed | Where-Object { $_ -in 'Credential', 'ComputerName', 'SkipValidation', 'SkipClusterProbe', 'Route', 'EventLogPath' }) | Should -BeNullOrEmpty -Because 'the file decides, the pipeline overrides nothing'
        $text | Should -Not -Match '(?i)BMC_PASSWORD|IDRAC_PASSWORD|node_admin|(?<!Connect-AzAccount )-Credential\b'
        $text | Should -Match '& \$(?:env:\w+|\{?\w+\}?) @p|& ''\$\(postDeploymentScript\)'' @p'
    }
    It '<Platform> maps the selection to -Only, -From, -To and -ContinueOnWarning, and nothing else about the steps' -ForEach $script:Files {
        $code = Get-CodeText $File
        foreach ($p in 'Only', 'From', 'To', 'ContinueOnWarning') { $code | Should -Match "\`$p\.$p = " -Because "$File sets -$p from its input" }
        $code | Should -Match "split '\\s\*,\\s\*'|split ""\\s\*,\\s\*""" -Because 'the only input is a comma-separated list'
        # no step id or task name is written in the pipeline: the step table is the one list
        $logic = ($code -split "`n" | Where-Object { $_ -notmatch '^\s*-?\s*(displayName|description|name):' }) -join "`n"
        $logic | Should -Not -Match '(?i)storage-paths|task-\d\d|security-groups|vm-images|logical-networks|sbe-import'
    }
    It '<Platform> takes the master file, the runner and every tool version from the variables of task 05' -ForEach $script:Files {
        $code = Get-CodeText $File
        $code | Should -Match 'AZL_INFRASTRUCTURE_FILE'
        $code | Should -Match 'AZL_POWERSHELL_YAML_VERSION'
        $code | Should -Match 'AZL_AZ_POWERSHELL_VERSION'
        $code | Should -Match 'AZL_AZ_KEYVAULT_VERSION'
        $code | Should -Not -Match '[\w./-]*infrastructure\.ya?ml' -Because 'the master file is a variable, never a path in the file'
        $code | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' -Because 'no ID of a deployment'
        (Get-Text $File) | Should -Not -Match '(?im)^\s*(password|secret|client-secret|token)\s*:\s*[^\s$<{]'
        (Get-Text $File) | Should -Not -Match 'ghp_[A-Za-z0-9]{20,}|AccountKey=|-----BEGIN'
    }
    It '<Platform> never commits, pushes or opens a pull request, and calls no platform API' -ForEach $script:Files {
        $code = Get-CodeText $File
        $code | Should -Not -Match '\bgit\s+(commit|push|add|checkout|merge|rebase|tag)\b'
        $code | Should -Not -Match '\bgh\s+(pr|api|issue|release)\b|az\s+(repos|devops|pipelines)|api\.github\.com|/_apis/|Invoke-RestMethod|Invoke-WebRequest|\bcurl\b'
    }
    It '<Platform> does not let a failed step pass, and fails the run on a failed script' -ForEach $script:Files {
        $text = Get-Text $File
        $text | Should -Not -Match '(?i)continue-on-error|continueOnError|ignoreLASTEXITCODE|failOnStderr:\s*false'
        switch ($Platform) {
            'GitHub' { $text | Should -Match 'exit \$LASTEXITCODE' }
            'GitLab' { $text | Should -Match 'exit \$LASTEXITCODE'; $text | Should -Not -Match '(?m)^\s*allow_failure:\s*true' }
            'AzureDevOps' { $text | Should -Match 'if \(\$LASTEXITCODE -ne 0\) \{ throw'; $text | Should -Match 'exit \$LASTEXITCODE' }
        }
    }
    It '<Platform> starts only by hand: no push, pull request or schedule' -ForEach $script:Files {
        $code = Get-CodeText $File
        switch ($Platform) {
            'GitHub' {
                $doc = Get-Yaml $File
                $on = if ($doc.Contains('on')) { $doc['on'] } else { $doc[$true] }
                $on.Keys | Should -Be @('workflow_dispatch')
            }
            'GitLab' { (Get-Yaml $File)['workflow']['rules'][0]['if'] | Should -Be '$CI_PIPELINE_SOURCE =~ /^(web|api)$/' }
            'AzureDevOps' { $code | Should -Match '(?m)^trigger: none\r?$'; $code | Should -Match '(?m)^pr: none\r?$'; $code | Should -Not -Match '(?m)^schedules:' }
        }
    }
}

Describe 'The inputs: the same on every platform' {
    It 'GitHub: mode, only, from, to and continue_on_warning, each with the safe default of one run' {
        $doc = Get-Yaml 'pipelines/github-actions/post-deployment.yml'
        $inputs = $doc['on']['workflow_dispatch']['inputs']
        @($inputs.Keys) | Should -Be @('mode', 'only', 'from', 'to', 'continue_on_warning')
        @($inputs['mode']['options']) | Should -Be @('Plan', 'Apply')
        [string]$inputs['mode']['default'] | Should -Be 'Plan'
        foreach ($n in 'only', 'from', 'to') { [string]$inputs[$n]['default'] | Should -Be '' }
        $inputs['continue_on_warning']['default'] | Should -BeFalse
        @($inputs.Keys | Where-Object { $_ -match '(?i)infrastructure|file|pool|environment' }) | Should -BeNullOrEmpty -Because 'no value of a deployment is a run input'
    }
    It 'GitLab: POST_DEPLOYMENT_MODE, _ONLY, _FROM, _TO and _CONTINUE_ON_WARNING, each with the safe default of one run' {
        $v = (Get-Yaml 'pipelines/gitlab/stages/post-deployment.yml')['variables']
        [string]$v['POST_DEPLOYMENT_MODE']['value'] | Should -Be 'Plan'
        @($v['POST_DEPLOYMENT_MODE']['options']) | Should -Be @('Plan', 'Apply')
        foreach ($n in 'POST_DEPLOYMENT_ONLY', 'POST_DEPLOYMENT_FROM', 'POST_DEPLOYMENT_TO') { [string]$v[$n]['value'] | Should -Be '' }
        [string]$v['POST_DEPLOYMENT_CONTINUE_ON_WARNING']['value'] | Should -Be 'false'
    }
    It 'Azure DevOps: mode, only, from, to and continue_on_warning, each with a default, and none for an environment, a pool or a file' {
        $p = @((Get-Yaml 'pipelines/azure-devops/post-deployment.yml')['parameters'])
        @($p | ForEach-Object { [string]$_['name'] }) | Should -Be @('mode', 'only', 'from', 'to', 'continue_on_warning')
        foreach ($x in $p) { $x.Contains('default') | Should -BeTrue -Because $x['name'] }
        [string]$p[0]['default'] | Should -Be 'Plan'
        @($p[0]['values']) | Should -Be @('Plan', 'Apply')
        foreach ($i in 1..3) { [string]$p[$i]['default'] | Should -Be 'none' }
        $p[4]['default'] | Should -BeFalse
    }
}

Describe 'GitHub: validate, plan, then apply behind the approval environment' {
    BeforeAll {
        $script:Gh = Get-Yaml 'pipelines/github-actions/post-deployment.yml'
        $script:GhJobs = $script:Gh['jobs']
        function Get-RunText($Job) { (@($Job['steps']) | ForEach-Object { $_['run'] }) -join "`n" }
    }
    It 'has the jobs validate, plan, apply and approval-environment-not-set, and no other' {
        @($script:GhJobs.Keys) | Should -Be @('validate', 'plan', 'apply', 'approval-environment-not-set')
    }
    It 'validate checks the master file and plan runs after it, with -Mode Plan and never an Apply' {
        Get-RunText $script:GhJobs['validate'] | Should -Match 'Test-InfrastructureFile\.ps1 -Path \$env:AZL_INFRASTRUCTURE_FILE'
        @($script:GhJobs['plan']['needs']) | Should -Be @('validate')
        $run = Get-RunText $script:GhJobs['plan']
        $run | Should -Match "Mode = 'Plan'"
        $run | Should -Not -Match "Mode = 'Apply'"
        $script:GhJobs['plan'].Contains('environment') | Should -BeFalse -Because 'the plan only reads, so it needs no approval'
        $script:GhJobs['plan'].Contains('concurrency') | Should -BeFalse -Because 'the plan only reads, so it need not wait for a change'
    }
    It 'apply runs after the plan, only for the mode Apply and only when the environment is set, in that environment, holding the lock of every other change to the cluster' {
        $a = $script:GhJobs['apply']
        @($a['needs']) | Should -Be @('plan')
        [string]$a['if'] | Should -Match "inputs\.mode == 'Apply'"
        [string]$a['if'] | Should -Match "vars\.AZL_ENVIRONMENT_OPERATIONS != ''"
        [string]$a['environment'] | Should -Be '${{ vars.AZL_ENVIRONMENT_OPERATIONS }}'
        [string]$a['concurrency']['group'] | Should -Match '^azure-local-day2-changes-\$\{\{ vars\.AZL_INFRASTRUCTURE_FILE \}\}$'
        $a['concurrency']['cancel-in-progress'] | Should -BeFalse
        $run = Get-RunText $a
        $run | Should -Match "Mode = 'Apply'"
        $run | Should -Not -Match "Mode = 'Plan'|WhatIf"
    }
    It 'while the environment is empty, apply does not run, and approval-environment-not-set fails and changes nothing' {
        $r = $script:GhJobs['approval-environment-not-set']
        [string]$r['if'] | Should -Match "inputs\.mode == 'Apply' && vars\.AZL_ENVIRONMENT_OPERATIONS == ''"
        $r.Contains('environment') | Should -BeFalse
        @($r['steps']).Count | Should -Be 1
        [string]@($r['steps'])[0]['run'] | Should -Match "Write-Error 'AZL_ENVIRONMENT_OPERATIONS .*Nothing was changed\.'"
        [string]@($r['steps'])[0]['run'] | Should -Match '(?m)^\s*exit 1\s*$'
        (@($r['steps']) | ConvertTo-Json -Depth 10) | Should -Not -Match 'azure/login|checkout|Install-Module|post-deployment-apply|POST_DEPLOYMENT_SCRIPT'
    }
    It 'no run step takes an input in its text (the inputs reach the script through env, so a value cannot become code)' {
        foreach ($job in $script:GhJobs.Values) { foreach ($step in @($job['steps'])) { if ($step.Contains('run')) { [string]$step['run'] | Should -Not -Match '\$\{\{' } } }
    }
    It 'signs in by AZL_AUTH_METHOD (OIDC or client secret) in plan and apply, never in validate' {
        foreach ($job in 'plan', 'apply') {
            $logins = @(@($script:GhJobs[$job]['steps']) | Where-Object { [string]$_['uses'] -like 'azure/login@*' })
            $logins.Count | Should -Be 2
            [string]$logins[0]['if'] | Should -Be "`${{ vars.AZL_AUTH_METHOD == 'oidc' }}"
            [string]$logins[1]['if'] | Should -Be "`${{ vars.AZL_AUTH_METHOD == 'client_secret' }}"
        }
        @(@($script:GhJobs['validate']['steps']) | Where-Object { [string]$_['uses'] -like 'azure/login@*' }).Count | Should -Be 0
    }
    It 'plan and apply publish the report and the event feed even when the run failed, with a retention that has a comment' {
        foreach ($pair in @(@('plan', 'post-deployment-plan', 30), @('apply', 'post-deployment-report', 90))) {
            $upload = @(@($script:GhJobs[$pair[0]]['steps']) | Where-Object { [string]$_['uses'] -like 'actions/upload-artifact@*' })
            $upload.Count | Should -Be 1
            [string]$upload[0]['if'] | Should -Match 'always\(\)'
            [string]$upload[0]['with']['name'] | Should -Be $pair[1]
            [int]$upload[0]['with']['retention-days'] | Should -Be $pair[2]
            $summary = @(@($script:GhJobs[$pair[0]]['steps']) | Where-Object { [string]$_['run'] -match 'GITHUB_STEP_SUMMARY' })
            $summary.Count | Should -Be 1
            [string]$summary[0]['if'] | Should -Match 'always\(\)'
        }
    }
}

Describe 'GitLab: validate, plan, then a manual apply in the protected environment' {
    BeforeAll {
        $script:Gl = Get-Yaml 'pipelines/gitlab/stages/post-deployment.yml'
        $script:GlText = Get-Text 'pipelines/gitlab/stages/post-deployment.yml'
    }
    It 'has the stages validate, plan and apply, and the four jobs' {
        @($script:Gl['stages']) | Should -Be @('post-deployment-validate', 'post-deployment-plan', 'post-deployment-apply')
        foreach ($j in 'post-deployment-validate', 'post-deployment-plan', 'post-deployment-apply', 'post-deployment-approval-environment-not-set') { $script:Gl.Contains($j) | Should -BeTrue -Because $j }
    }
    It 'every job runs on the tag AZL_RUNNER_LABEL' {
        foreach ($j in 'post-deployment-validate', 'post-deployment-approval-environment-not-set') { @($script:Gl[$j]['tags']) | Should -Be @('$AZL_RUNNER_LABEL') }
        @($script:Gl['.post-deployment']['tags']) | Should -Be @('$AZL_RUNNER_LABEL')
    }
    It 'validate checks the master file; plan runs after it with -Mode Plan and has no environment and no resource group' {
        [string]@($script:Gl['post-deployment-validate']['script'])[0] | Should -Match 'Test-InfrastructureFile\.ps1 -Path \$env:AZL_INFRASTRUCTURE_FILE'
        @($script:Gl['post-deployment-plan']['needs']) | Should -Be @('post-deployment-validate')
        [string]$script:Gl['post-deployment-plan']['variables']['POST_DEPLOYMENT_STEP_MODE'] | Should -Be 'Plan'
        $script:Gl['post-deployment-plan'].Contains('environment') | Should -BeFalse
        $script:Gl['post-deployment-plan'].Contains('resource_group') | Should -BeFalse
    }
    It 'apply is manual, cannot fail quietly, runs after the plan, is in the protected environment and holds the resource group of the other changes' {
        $a = $script:Gl['post-deployment-apply']
        @($a['needs']) | Should -Be @('post-deployment-plan')
        [string]$a['variables']['POST_DEPLOYMENT_STEP_MODE'] | Should -Be 'Apply'
        [string]$a['environment']['name'] | Should -Be '$AZL_ENVIRONMENT_OPERATIONS'
        [string]$a['resource_group'] | Should -Be 'azure-local-day2-changes'
        $rule = @($a['rules'])[0]
        [string]$rule['when'] | Should -Be 'manual'
        $rule['allow_failure'] | Should -BeFalse
        [string]$rule['if'] | Should -Match '\$POST_DEPLOYMENT_MODE == "Apply"'
        [string]$rule['if'] | Should -Match '\$AZL_ENVIRONMENT_OPERATIONS != null && \$AZL_ENVIRONMENT_OPERATIONS != ""'
    }
    It 'while the environment is empty the apply job is not created, and approval-environment-not-set fails and changes nothing' {
        $r = $script:Gl['post-deployment-approval-environment-not-set']
        [string]@($r['rules'])[0]['if'] | Should -Match '\$POST_DEPLOYMENT_MODE == "Apply" && \(\$AZL_ENVIRONMENT_OPERATIONS == null \|\| \$AZL_ENVIRONMENT_OPERATIONS == ""\)'
        $r.Contains('environment') | Should -BeFalse
        $r.Contains('before_script') | Should -BeFalse
        @($r['script']).Count | Should -Be 1
        [string]@($r['script'])[0] | Should -Match 'Write-Error "AZL_ENVIRONMENT_OPERATIONS .*Nothing was changed\."'
        [string]@($r['script'])[0] | Should -Match 'exit 1'
    }
    It 'plan and apply sign in by AZL_AUTH_METHOD, keep the report even when the run failed, and print the summary' {
        $script:GlText | Should -Match 'if \(\$env:AZL_AUTH_METHOD -eq "oidc"\)'
        foreach ($pair in @(@('post-deployment-plan', 'post-deployment-plan', '30 days'), @('post-deployment-apply', 'post-deployment-report', '90 days'))) {
            $j = $script:Gl[$pair[0]]
            [string]$j['artifacts']['when'] | Should -Be 'always'
            [string]$j['artifacts']['name'] | Should -Be $pair[1]
            [string]$j['artifacts']['expire_in'] | Should -Be $pair[2]
            [string]@($j['after_script'])[0] | Should -Match 'summary\.md'
        }
    }
}

Describe 'Azure DevOps: validate, plan, then a deployment job in the compile-time approval environment' {
    BeforeAll {
        $script:Ado = Get-Yaml 'pipelines/azure-devops/post-deployment.yml'
        $script:AdoText = Get-Text 'pipelines/azure-devops/post-deployment.yml'
        function Get-AdoCondition($Node, [string]$Stage, [string[]]$Conditions = @()) {
            if ($Node -is [System.Collections.IDictionary]) {
                if ($Node.Contains('stage') -and $Node['stage'] -eq $Stage) { return , $Conditions }
                foreach ($k in $Node.Keys) {
                    $next = if ([string]$k -like '${{ if*') { @($Conditions) + [string]$k } else { $Conditions }
                    $r = Get-AdoCondition $Node[$k] $Stage $next
                    if ($null -ne $r) { return , $r }
                }
            }
            elseif ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { $r = Get-AdoCondition $i $Stage $Conditions; if ($null -ne $r) { return , $r } } }
        }
    }
    It 'includes the settings file and the approval environments, and sets lockBehavior sequential' {
        $script:AdoText | Should -Match '(?m)^\s+- template: variables/pipeline-settings\.yml\r?$'
        $script:AdoText | Should -Match '(?m)^\s+- template: variables/approval-environments\.yml\r?$'
        [string]$script:Ado['lockBehavior'] | Should -Be 'sequential'
    }
    It 'has the stages Validate, Plan, ApprovalEnvironmentNotSet and Apply' {
        foreach ($s in 'Validate', 'Plan', 'ApprovalEnvironmentNotSet', 'Apply') { @(Find-Stage $script:Ado['stages'] $s).Count | Should -Be 1 -Because $s }
    }
    It 'Validate checks the master file; Plan runs after it with -Mode Plan, in no environment' {
        $script:AdoText | Should -Match 'Test-InfrastructureFile\.ps1 -Path \$env:POST_DEPLOYMENT_INFRASTRUCTURE_FILE'
        $plan = @(Find-Stage $script:Ado['stages'] 'Plan')[0]
        [string]$plan['dependsOn'] | Should -Be 'Validate'
        $json = $plan | ConvertTo-Json -Depth 30
        $json | Should -Match "Mode = 'Plan'"
        $json | Should -Not -Match 'Mode = ''Apply''|"environment"|"deployment"'
    }
    It 'Apply exists only for the mode Apply and a set environment, is a deployment job in that variable, runs after Plan and takes the lock' {
        $conds = (Get-AdoCondition $script:Ado['stages'] 'Apply') -join ' '
        $conds | Should -Match "eq\(parameters\.mode, 'Apply'\)"
        $conds | Should -Match "ne\(variables\.AZL_ENVIRONMENT_OPERATIONS, ''\)"
        $apply = @(Find-Stage $script:Ado['stages'] 'Apply')[0]
        [string]$apply['dependsOn'] | Should -Be 'Plan'
        [string]$apply['lockBehavior'] | Should -Be 'sequential'
        $deployments = @($apply['jobs'] | Where-Object { $_.Contains('deployment') })
        $deployments.Count | Should -Be 1
        [string]$deployments[0]['environment'] | Should -Be '${{ variables.AZL_ENVIRONMENT_OPERATIONS }}'
        ($apply | ConvertTo-Json -Depth 30) | Should -Match "Mode = 'Apply'"
    }
    It 'while the variable is empty a guard stage fails and changes nothing' {
        $conds = (Get-AdoCondition $script:Ado['stages'] 'ApprovalEnvironmentNotSet') -join ' '
        $conds | Should -Match "eq\(parameters\.mode, 'Apply'\)"
        $conds | Should -Match "eq\(variables\.AZL_ENVIRONMENT_OPERATIONS, ''\)"
        $g = @(Find-Stage $script:Ado['stages'] 'ApprovalEnvironmentNotSet')[0]
        @($g['jobs']).Count | Should -Be 1
        $job = $g['jobs'][0]
        $job.Contains('environment') | Should -BeFalse
        $job.Contains('deployment') | Should -BeFalse
        @($job['steps']).Count | Should -Be 1
        [string]@($job['steps'])[0]['pwsh'] | Should -Match "Write-Error '.*AZL_ENVIRONMENT_OPERATIONS .*approval-environments\.yml.*Nothing was changed\.'"
        [string]@($job['steps'])[0]['pwsh'] | Should -Match '(?m)^\s*exit 1\r?$'
        ($g | ConvertTo-Json -Depth 30) | Should -Not -MatchExactly 'AzurePowerShell|checkout|PublishPipelineArtifact|"environment"'
    }
    It 'Plan and Apply sign in through the service connection of the settings file, publish the report even when the run failed, and print the summary' {
        $script:AdoText | Should -Match 'azureSubscription: \$\{\{ variables\.AZL_SERVICE_CONNECTION \}\}'
        @([regex]::Matches($script:AdoText, 'PublishPipelineArtifact@1')).Count | Should -Be 2
        @([regex]::Matches($script:AdoText, '(?m)^\s+condition: always\(\)')).Count | Should -Be 4 -Because 'two summaries and two published artifacts'
        $script:AdoText | Should -Match 'artifact: post-deployment-plan'
        $script:AdoText | Should -Match 'artifact: post-deployment-report'
        @([regex]::Matches($script:AdoText, 'uploadsummary')).Count | Should -Be 2
    }
    It 'the selection values reach the script through env (a value cannot become code), and none means no selection' {
        $script:AdoText | Should -Match 'POST_DEPLOYMENT_ONLY: \$\{\{ parameters\.only \}\}'
        $script:AdoText | Should -Match "\`$env:POST_DEPLOYMENT_ONLY -ne 'none'"
        $script:AdoText | Should -Match "\`$env:POST_DEPLOYMENT_CONTINUE_ON_WARNING -eq 'True'"
        $script:AdoText | Should -Not -Match '(?m)^\s+(Inline|pwsh): .*\$\{\{ parameters\.'
    }
}

Describe 'The orchestrator the pipelines run' {
    It 'has every parameter the pipelines pass, and -Mode takes Plan and Apply only' {
        $params = Get-Param $script:Orchestrator
        foreach ($p in 'InfrastructureFile', 'LogPath', 'Mode', 'Only', 'From', 'To', 'ContinueOnWarning') { $params | Should -Contain $p }
        (Get-Text $script:Orchestrator) | Should -Match "\[ValidateSet\('Plan', 'Apply'\)\]\[string\]\`$Mode = 'Plan'"
    }
    It 'refuses SDN without its acknowledgement keys, in Plan too, so a pipeline run cannot get past it (exit code 2)' {
        (Get-Text 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/Invoke-AzureLocalPostDeployment.ps1') | Should -Match 'in Plan mode too'
        (Get-Text 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/PostDeploymentSteps.psd1') | Should -Match "Key = 'sdn\.acknowledge_maintenance_window'; Is = \`$true"
    }
}
