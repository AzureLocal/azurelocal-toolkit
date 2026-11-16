#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The approval environment of an Azure DevOps pipeline that changes something is bound when the pipeline is compiled, never chosen when a
# run is queued. A deployment job in an environment with no Approvals check runs without one, so an environment that is a run parameter would
# let whoever queues the run name one with no approval. A template expression sees only the variables of the YAML files (Learn: Template
# expressions, "Context"), so the name is a variable of pipelines/azure-devops/variables/approval-environments.yml, shipped empty. While it is
# empty, a guard stage fails and changes nothing. This test checks the five pipelines that deploy and the four day 2 and validation pipelines: arm-deployment, os-configuration, cicd-infra,
# azure-local-deploy and (as the first one to do it) pre-cluster-verification. Nothing is run and nothing is sent anywhere.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines/ApprovalEnvironmentPipelines.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $script:Cases = @(
        @{ File = 'pipelines/azure-devops/arm-deployment.yml'; Name = 'arm-deployment'; Variables = @('AZL_ENVIRONMENT_ARM_DEPLOYMENT'); ChangeStages = @('Deploy'); ReadOnlyStages = @('Preconditions', 'Validate'); GitHub = 'pipelines/github-actions/arm-deployment.yml' }
        @{ File = 'pipelines/azure-devops/os-configuration.yml'; Name = 'os-configuration'; Variables = @('AZL_ENVIRONMENT_OS_CONFIGURATION', 'AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE'); ChangeStages = @('ConfirmStorageWipe', 'Apply'); ReadOnlyStages = @('Plan'); GitHub = 'pipelines/github-actions/os-configuration.yml' }
        @{ File = 'pipelines/azure-devops/cicd-infra.yml'; Name = 'cicd-infra'; Variables = @('AZL_ENVIRONMENT_CICD_INFRA'); ChangeStages = @('Apply'); ReadOnlyStages = @('Validate', 'Plan'); GitHub = 'pipelines/github-actions/cicd-infra.yml' }
        @{ File = 'pipelines/azure-devops/azure-local-deploy.yml'; Name = 'azure-local-deploy'; Variables = @('AZL_ENVIRONMENT_TERRAFORM_DEPLOYMENT'); ChangeStages = @('DeployFoundation', 'ConfigureOnPrem', 'ConfigureOperations'); ReadOnlyStages = @('Validate', 'Plan'); GitHub = 'pipelines/github-actions/azure-local-deploy.yml' }
        @{ File = 'pipelines/azure-devops/pre-cluster-verification.yml'; Name = 'pre-cluster-verification'; Variables = @('AZL_ENVIRONMENT_ARM_DEPLOYMENT'); ChangeStages = @('VerifyWithChanges'); ReadOnlyStages = @('Verify'); GitHub = 'pipelines/github-actions/pre-cluster-verification.yml' }
        @{ File = 'pipelines/azure-devops/day2-update.yml'; Name = 'day2-update'; Variables = @('AZL_ENVIRONMENT_OPERATIONS'); ChangeStages = @('Apply'); ReadOnlyStages = @('Plan'); GitHub = 'pipelines/github-actions/day2-update.yml' }
        @{ File = 'pipelines/azure-devops/day2-node-maintenance.yml'; Name = 'day2-node-maintenance'; Variables = @('AZL_ENVIRONMENT_OPERATIONS'); ChangeStages = @('Apply'); ReadOnlyStages = @('Plan'); GitHub = 'pipelines/github-actions/day2-node-maintenance.yml' }
        @{ File = 'pipelines/azure-devops/day2-cluster-operations.yml'; Name = 'day2-cluster-operations'; Variables = @('AZL_ENVIRONMENT_OPERATIONS'); ChangeStages = @('Apply'); ReadOnlyStages = @('ReadOnly', 'Plan'); GitHub = 'pipelines/github-actions/day2-cluster-operations.yml' }
        @{ File = 'pipelines/azure-devops/validation.yml'; Name = 'validation'; Variables = @('AZL_ENVIRONMENT_OPERATIONS'); ChangeStages = @('StoragePerformance'); ReadOnlyStages = @('Validate'); GitHub = 'pipelines/github-actions/validation.yml' }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    function Get-Text([string]$File) { [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $File)) }
    function Get-Yaml([string]$File) { ConvertFrom-Yaml (Get-Text $File) -Ordered }

    # Every stage of a document with the compile-time conditions (${{ if ... }} keys) it sits under.
    function Get-StageWithCondition($Node, [string[]]$Conditions = @()) {
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains('stage')) { [pscustomobject]@{ Name = [string]$Node['stage']; Stage = $Node; Conditions = $Conditions } }
            foreach ($k in $Node.Keys) {
                $next = if ([string]$k -like '${{ if*') { @($Conditions) + [string]$k } else { $Conditions }
                Get-StageWithCondition $Node[$k] $next
            }
        }
        elseif ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { Get-StageWithCondition $i $Conditions } }
    }
    # A stage whose only job is the one that refuses: it fails and changes nothing.
    function Test-Guard($Stage) { @($Stage['jobs'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('job') -and [string]$_['job'] -eq 'Refuse' }).Count -gt 0 }
    $script:TemplateFile = 'pipelines/azure-devops/variables/approval-environments.yml'
}

Describe 'The variables template of the approval environments' {
    It 'defines one empty variable for each approval environment, named like the GitHub and GitLab variables of the same purpose' {
        $defined = @((Get-Yaml $script:TemplateFile)['variables'])
        $names = @($defined | ForEach-Object { [string]$_['name'] })
        $names | Should -Be @('AZL_ENVIRONMENT_OS_CONFIGURATION', 'AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE', 'AZL_ENVIRONMENT_ARM_DEPLOYMENT', 'AZL_ENVIRONMENT_CICD_INFRA', 'AZL_ENVIRONMENT_TERRAFORM_DEPLOYMENT', 'AZL_ENVIRONMENT_OPERATIONS')
        foreach ($d in $defined) { [string]$d['value'] | Should -Be '' -Because "no value of a deployment is written in the toolkit ($($d['name']))" }
        $names | ForEach-Object { $_ | Should -Match '^AZL_ENVIRONMENT_[A-Z_]+$' }
    }
    It 'every name is one task 05 sets on GitHub and GitLab from devops.pipelines.environments (the same names on the three platforms)' {
        $module = Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')) -Force -PassThru
        $table = @(& $module { $script:AzlPipelineVariable } | Where-Object { $_.Name -like 'AZL_ENVIRONMENT_*' })
        $names = @((Get-Yaml $script:TemplateFile)['variables'] | ForEach-Object { [string]$_['name'] })
        @($table | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @($names | Sort-Object)
        foreach ($v in $table) {
            $v.AzureDevOps | Should -Be 'Template' -Because "$($v.Name) is not a run parameter"
            $v.Platforms | Should -Contain 'azure_devops'
            $v.Key | Should -Match '^devops\.pipelines\.environments\.[a-z_]+$'
        }
    }
}

Describe 'Azure DevOps: <Name> binds its approval environment at compile time' -ForEach $script:Cases {
    BeforeAll {
        $script:Text = Get-Text $File
        $script:Doc = Get-Yaml $File
        $script:Stages = @(Get-StageWithCondition $script:Doc['stages'])
    }
    It 'has no run parameter for an environment' {
        $names = @($script:Doc['parameters'] | ForEach-Object { [string]$_['name'] })
        @($names | Where-Object { $_ -match '(?i)environment' -and $_ -ne 'install_environment_checker' }) | Should -BeNullOrEmpty
        $names | Should -Not -Contain 'approvalEnvironment'
        $names | Should -Not -Contain 'approval_environment'
        $names | Should -Not -Contain 'clear_storage_approval_environment'
        $script:Text | Should -Not -Match 'parameters\.\w*[Ee]nvironment\b'
        $script:Text | Should -Not -Match '(?m)^\s+environment: \$\{\{ parameters\.'
    }
    It 'includes the variables template, and every environment of a job is a variable of it' {
        $script:Text | Should -Match '(?m)^\s+- template: variables/approval-environments\.yml\r?$'
        $lines = @($script:Text -split "`r?`n" | Where-Object { $_ -match '^\s+environment:' })
        $lines.Count | Should -BeGreaterThan 0
        foreach ($l in $lines) { $l | Should -Match '^\s+environment: \$\{\{ variables\.AZL_ENVIRONMENT_[A-Z_]+ \}\}$' }
        foreach ($l in $lines) { ([regex]::Match($l, 'variables\.(AZL_ENVIRONMENT_[A-Z_]+)').Groups[1].Value) | Should -BeIn $Variables }
        foreach ($v in $Variables) { $script:Text | Should -Match "(?m)^\s+environment: \`$\{\{ variables\.$v \}\}\r?`$" }
    }
    It 'the stages that change something exist only when their variable is set, and each is a deployment job in that environment' {
        foreach ($name in $ChangeStages) {
            $found = @($script:Stages | Where-Object { $_.Name -eq $name -and -not (Test-Guard $_.Stage) })
            $found.Count | Should -Be 1 -Because $name
            $stage = $found[0]
            $conds = $stage.Conditions -join ' '
            $deployments = @($stage.Stage['jobs'] | Where-Object { $_.Contains('deployment') })
            $deployments.Count | Should -Be 1 -Because $name
            $env = [string]$deployments[0]['environment']
            $env | Should -Match '^\$\{\{ variables\.AZL_ENVIRONMENT_[A-Z_]+ \}\}$'
            $variable = [regex]::Match($env, 'variables\.(AZL_ENVIRONMENT_[A-Z_]+)').Groups[1].Value
            $variable | Should -BeIn $Variables
            $conds | Should -Match "ne\(variables\.$variable, ''\)" -Because "$name is compiled only when $variable is set"
            $conds | Should -Not -Match "eq\(variables\.$variable, ''\)"
        }
    }
    It 'while a variable is empty and the run would change something, a guard stage fails and changes nothing' {
        $guards = @($script:Stages | Where-Object { Test-Guard $_.Stage })
        $guards.Count | Should -BeGreaterThan 0
        foreach ($g in $guards) {
            $json = $g.Stage | ConvertTo-Json -Depth 30
            $conds = $g.Conditions -join ' '
            $conds | Should -Match "eq\(variables\.AZL_ENVIRONMENT_[A-Z_]+, ''\)" -Because "$($g.Name) exists only when a variable is empty"
            $variable = [regex]::Match($conds, "eq\(variables\.(AZL_ENVIRONMENT_[A-Z_]+), ''\)").Groups[1].Value
            $variable | Should -BeIn $Variables
            # it refuses: one pwsh step that writes the error and exits 1; it names the variable and the file to edit; it has no environment and changes nothing
            @($g.Stage['jobs']).Count | Should -Be 1
            $job = $g.Stage['jobs'][0]
            $job.Contains('environment') | Should -BeFalse
            $job.Contains('deployment') | Should -BeFalse
            @($job['steps']).Count | Should -Be 1
            $step = @($job['steps'])[0]
            [string]$step['pwsh'] | Should -Match "(?m)^\s*Write-Error '.*$variable .*approval-environments\.yml.*Nothing was changed\.'\r?`$"
            [string]$step['pwsh'] | Should -Match '(?m)^\s*exit 1\r?$'
            $json | Should -Not -MatchExactly 'AzurePowerShell|AzureCLI|TerraformTask|TerraformInstaller|ansible-playbook|checkout|download|PublishPipelineArtifact|"environment"'
        }
    }
    It 'the stages that only read have no environment and no deployment job' {
        foreach ($name in $ReadOnlyStages) {
            $found = @($script:Stages | Where-Object { $_.Name -eq $name })
            $found.Count | Should -BeGreaterThan 0 -Because $name
            foreach ($s in $found) {
                $s.Conditions -join ' ' | Should -Not -Match 'AZL_ENVIRONMENT_' -Because "$name is not behind an approval environment"
                $json = $s.Stage | ConvertTo-Json -Depth 30
                $json | Should -Not -Match '"environment"'
                $json | Should -Not -Match '"deployment"'
            }
        }
    }
    It 'GitHub reads the same name from the repository variable, for the pipelines that exist there' {
        foreach ($v in $Variables) {
            if ($v -eq 'AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE') { continue }   # the storage wipe approval is Azure DevOps only
            (Get-Text $GitHub) | Should -Match "vars\.$v\b"
        }
    }
}

Describe 'Azure DevOps os-configuration.yml: the two approvals' {
    BeforeAll {
        $script:Stages = @(Get-StageWithCondition (Get-Yaml 'pipelines/azure-devops/os-configuration.yml')['stages'])
    }
    It 'ConfirmStorageWipe has a deployment variant (both variables set) and a refusing variant (only the wipe variable empty), and Apply needs the first variable' {
        $confirm = @($script:Stages | Where-Object { $_.Name -eq 'ConfirmStorageWipe' })
        $confirm.Count | Should -Be 2
        $deploy = @($confirm | Where-Object { -not (Test-Guard $_.Stage) })
        $refuse = @($confirm | Where-Object { Test-Guard $_.Stage })
        $deploy.Count | Should -Be 1
        $refuse.Count | Should -Be 1
        $deploy[0].Stage['jobs'][0]['environment'] | Should -Be '${{ variables.AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE }}'
        ($deploy[0].Conditions -join ' ') | Should -Match "ne\(variables\.AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE, ''\)"
        ($refuse[0].Conditions -join ' ') | Should -Match "eq\(variables\.AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE, ''\)"
        # the refusing variant runs where the deployment variant would: the plan would wipe, so Apply (which needs Succeeded or Skipped) does not run
        $refuse[0].Stage['condition'] | Should -Be $deploy[0].Stage['condition']
        $apply = @($script:Stages | Where-Object { $_.Name -eq 'Apply' })
        $apply.Count | Should -Be 1
        $apply[0].Stage['jobs'][0]['environment'] | Should -Be '${{ variables.AZL_ENVIRONMENT_OS_CONFIGURATION }}'
        ($apply[0].Conditions -join ' ') | Should -Match "ne\(variables\.AZL_ENVIRONMENT_OS_CONFIGURATION, ''\)"
        @($apply[0].Stage['dependsOn']) | Should -Contain 'ConfirmStorageWipe'
        $apply[0].Stage['condition'] | Should -Match "dependencies\.ConfirmStorageWipe\.result, 'Succeeded', 'Skipped'"
    }
    It 'the first guard needs mode Apply and an empty AZL_ENVIRONMENT_OS_CONFIGURATION' {
        $guard = @($script:Stages | Where-Object { $_.Name -eq 'ApprovalEnvironmentNotSet' })
        $guard.Count | Should -Be 1
        ($guard[0].Conditions -join ' ') | Should -Match "eq\(parameters\.mode, 'Apply'\)"
        ($guard[0].Conditions -join ' ') | Should -Match "eq\(variables\.AZL_ENVIRONMENT_OS_CONFIGURATION, ''\)"
    }
}

Describe 'Azure DevOps azure-local-deploy.yml: the deployment stages' {
    It 'all three deployment stages sit under one condition, and the guard under the opposite one' {
        $stages = @(Get-StageWithCondition (Get-Yaml 'pipelines/azure-devops/azure-local-deploy.yml')['stages'])
        foreach ($n in 'DeployFoundation', 'ConfigureOnPrem', 'ConfigureOperations') {
            $s = @($stages | Where-Object { $_.Name -eq $n })
            $s.Count | Should -Be 1
            ($s[0].Conditions -join ' ') | Should -Be "`${{ if ne(variables.AZL_ENVIRONMENT_TERRAFORM_DEPLOYMENT, '') }}"
        }
        $g = @($stages | Where-Object { $_.Name -eq 'ApprovalEnvironmentNotSet' })
        $g.Count | Should -Be 1
        ($g[0].Conditions -join ' ') | Should -Be "`${{ if eq(variables.AZL_ENVIRONMENT_TERRAFORM_DEPLOYMENT, '') }}"
        @($g[0].Stage['dependsOn']) | Should -Contain 'Plan'
    }
}

BeforeDiscovery {
    # computed from this file's folder, never from a variable set at run time: the list must be right whatever the working folder is
    $root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $github = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($root, 'pipelines', 'github-actions')) -Filter '*.yml' -File | ForEach-Object { @{ File = 'pipelines/github-actions/' + $_.Name } })
    $gitlabRoot = [IO.Path]::Combine($root, 'pipelines', 'gitlab')
    $gitlab = @(Get-ChildItem -LiteralPath $gitlabRoot -Recurse -Filter '*.yml' -File -Force | ForEach-Object { @{ File = 'pipelines/gitlab/' + $_.FullName.Substring($gitlabRoot.Length + 1).Replace('\', '/') } })
    # the files that have a job bound to an AZL_ENVIRONMENT_* variable (found in the text, so a new pipeline cannot be left out)
    $script:GitHubBound = @($github | Where-Object { [IO.File]::ReadAllText([IO.Path]::Combine($root, $_.File)) -match '(?m)^\s+environment: \$\{\{ vars\.AZL_ENVIRONMENT_' })
    $script:GitLabBound = @($gitlab | Where-Object { [IO.File]::ReadAllText([IO.Path]::Combine($root, $_.File)) -match '(?m)^\s+name: \$\{?AZL_ENVIRONMENT_' })
}

Describe 'GitHub and GitLab: a job bound to an AZL_ENVIRONMENT_* variable does not run, and a refusal job fails, while the variable is empty' {
    BeforeAll {
        $script:RepoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
        Import-Module powershell-yaml
        function Read-Yaml([string]$File) { ConvertFrom-Yaml ([IO.File]::ReadAllText([IO.Path]::Combine($script:RepoRoot, $File))) -Ordered }
    }
    It 'the workflows and stage files that bind such a variable are found (so the tests below are not empty)' {
        $github = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:RepoRoot, 'pipelines', 'github-actions')) -Filter '*.yml' -File | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '(?m)^\s+environment: \$\{\{ vars\.AZL_ENVIRONMENT_' })
        $gitlab = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:RepoRoot, 'pipelines', 'gitlab')) -Recurse -Filter '*.yml' -File -Force | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '(?m)^\s+name: \$\{?AZL_ENVIRONMENT_' })
        $github.Count | Should -BeGreaterThan 8
        $gitlab.Count | Should -BeGreaterThan 8
    }
    It 'GitHub <File>: every job bound to an environment variable has the non-empty condition in its if, and the job approval-environment-not-set refuses with the opposite condition' -ForEach $script:GitHubBound {
        $jobs = (Read-Yaml $File)['jobs']
        $bound = @($jobs.Keys | Where-Object { $jobs[$_].Contains('environment') })
        $bound.Count | Should -BeGreaterThan 0
        $refuse = $jobs['approval-environment-not-set']
        $refuse | Should -Not -BeNullOrEmpty -Because "$File needs a refusal job"
        $variables = @()
        foreach ($name in $bound) {
            $j = $jobs[$name]
            $variable = [regex]::Match([string]$j['environment'], '^\$\{\{ vars\.(AZL_ENVIRONMENT_[A-Z_]+) \}\}').Groups[1].Value
            $variable | Should -Not -BeNullOrEmpty -Because "$File $name"
            $variables += $variable
            $j.Contains('if') | Should -BeTrue -Because "$File $name has a job-level if"
            $andForm = '&& vars\.' + $variable + " != ''"
            $onlyForm = '^\$\{\{ vars\.' + $variable + " != '' \}\}`$"
            [string]$j['if'] | Should -Match "$andForm|$onlyForm" -Because "$name does not run without $variable"
        }
        # one variable per pipeline; the refusal job has the opposite condition, the runner of the guarded job, and one pwsh step that names the variable and its key and exits 1
        $variable = $variables[0]
        @($variables | Sort-Object -Unique) | Should -Be @($variable)
        [string]$refuse['if'] | Should -Match ('vars\.' + $variable + " == ''")
        [string]$refuse['if'] | Should -Not -Match "!= ''"
        $refuseNeeds = @($refuse['needs'] | Where-Object { $_ }) -join ','
        $guardedNeeds = @($bound | ForEach-Object { (@($jobs[$_]['needs'] | Where-Object { $_ })) -join ',' })
        $guardedNeeds | Should -Contain $refuseNeeds -Because 'the refusal job waits for the same jobs as a guarded job'
        (ConvertTo-Json $refuse['runs-on'] -Compress) | Should -Be (ConvertTo-Json $jobs[$bound[0]]['runs-on'] -Compress)
        $refuse.Contains('environment') | Should -BeFalse
        $steps = @($refuse['steps'])
        $steps.Count | Should -Be 1
        $steps[0]['shell'] | Should -Be 'pwsh'
        $steps[0].Contains('uses') | Should -BeFalse
        [string]$steps[0]['run'] | Should -Not -Match '\$\{\{'
        [string]$steps[0]['run'] | Should -Match ("Write-Error '" + $variable + ' \(devops\.pipelines\.environments\.[a-z0-9_]+\)')
        [string]$steps[0]['run'] | Should -Match 'Nothing was changed\.'
        [string]$steps[0]['run'] | Should -Match '(?m)^\s*exit 1\r?$'
        [string]$steps[0]['run'] | Should -Not -Match '(?i)\baz\s|terraform\s+(init|apply|plan)|ansible-playbook|Invoke-Command|checkout'
        $refuse.Contains('timeout-minutes') | Should -BeTrue
    }
    It 'GitLab <File>: every job bound to an environment variable has the non-empty condition in every rule, and a job named approval-environment-not-set has the opposite rule' -ForEach $script:GitLabBound {
        $doc = Read-Yaml $File
        $jobs = @($doc.Keys | Where-Object { $doc[$_] -is [System.Collections.IDictionary] -and $doc[$_].Contains('environment') -and $doc[$_]['environment'] -is [System.Collections.IDictionary] -and [string]$doc[$_]['environment']['name'] -match '^\$\{?AZL_ENVIRONMENT_' })
        $jobs.Count | Should -BeGreaterThan 0
        $refusals = @($doc.Keys | Where-Object { [string]$_ -like '*approval-environment-not-set' })
        $refusals.Count | Should -Be 1 -Because "$File needs one refusal job"
        $refuse = $doc[$refusals[0]]
        $variable = ''
        foreach ($name in $jobs) {
            $j = $doc[$name]
            $variable = [regex]::Match([string]$j['environment']['name'], 'AZL_ENVIRONMENT_[A-Z_]+').Value
            @($j['rules']).Count | Should -BeGreaterThan 0 -Because "$name has rules, so it is not created without $variable"
            foreach ($r in @($j['rules'])) { [string]$r['if'] | Should -Match ('\$' + $variable + ' != null && \$' + $variable + ' != ""') -Because "$name needs $variable" }
        }
        $refuse.Contains('environment') | Should -BeFalse
        $refuse.Contains('resource_group') | Should -BeFalse
        @($refuse['rules']).Count | Should -Be 1
        [string]@($refuse['rules'])[0]['if'] | Should -Match ('\(\$' + $variable + ' == null \|\| \$' + $variable + ' == ""\)')
        @($refuse['rules'])[0].Contains('when') | Should -BeFalse -Because 'the refusal runs by itself and fails the pipeline'
        # the stage of the guarded job, which may come from the template it extends
        $guardedJob = $doc[$jobs[0]]
        $stage = if ($guardedJob.Contains('stage')) { $guardedJob['stage'] } else { $doc[[string]@($guardedJob['extends'])[0]]['stage'] }
        $refuse['stage'] | Should -Be $stage
        [string]@($refuse['tags'])[0] | Should -Be '$AZL_RUNNER_LABEL'
        $script = (@($refuse['script']) -join "`n")
        $script | Should -Match ('Write-Error "' + $variable + ' \(devops\.pipelines\.environments\.[a-z0-9_]+\)')
        $script | Should -Match 'Nothing was changed\.'
        $script | Should -Match 'exit 1'
        $script | Should -Not -Match '(?i)\baz\s|terraform\s+(init|apply|plan)|ansible-playbook|Invoke-Command'
        $refuse.Contains('timeout') | Should -BeTrue
    }
    It 'GitLab <File>: a job that needs a guarded job exists only when it does (its rule has the variable condition, or the need is optional)' -ForEach $script:GitLabBound {
        $doc = Read-Yaml $File
        $guarded = @($doc.Keys | Where-Object { $doc[$_] -is [System.Collections.IDictionary] -and $doc[$_].Contains('environment') -and $doc[$_]['environment'] -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_ })
        foreach ($name in $doc.Keys) {
            $j = $doc[$name]
            if ($j -isnot [System.Collections.IDictionary] -or -not $j.Contains('needs') -or [string]$name -like '*approval-environment-not-set') { continue }
            foreach ($n in @($j['needs'])) {
                $target = if ($n -is [System.Collections.IDictionary]) { [string]$n['job'] } else { [string]$n }
                if ($target -notin $guarded) { continue }
                $optional = ($n -is [System.Collections.IDictionary] -and $n['optional'] -eq $true)
                $same = @($j['rules']).Count -gt 0 -and ([string]@($j['rules'])[0]['if'] -match 'AZL_ENVIRONMENT_')
                ($optional -or $same) | Should -BeTrue -Because "$name needs $target, which is not created while the variable is empty"
            }
        }
    }
}
