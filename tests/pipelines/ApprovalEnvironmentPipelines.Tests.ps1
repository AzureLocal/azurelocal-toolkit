#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The approval environment of an Azure DevOps pipeline that changes something is bound when the pipeline is compiled, never chosen when a
# run is queued. A deployment job in an environment with no Approvals check runs without one, so an environment that is a run parameter would
# let whoever queues the run name one with no approval. A template expression sees only the variables of the YAML files (Learn: Template
# expressions, "Context"), so the name is a variable of pipelines/azure-devops/variables/approval-environments.yml, shipped empty. While it is
# empty, a guard stage fails and changes nothing. This test checks the five pipelines that deploy: arm-deployment, os-configuration, cicd-infra,
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
        $names | Should -Be @('AZL_ENVIRONMENT_OS_CONFIGURATION', 'AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE', 'AZL_ENVIRONMENT_ARM_DEPLOYMENT', 'AZL_ENVIRONMENT_CICD_INFRA', 'AZL_ENVIRONMENT_TERRAFORM_DEPLOYMENT')
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
