#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The three pipeline files for the ARM Validate and Deploy parse, run the one entry point, put an approval between Validate and
# Deploy, sign in without a client secret, and hold no real identifier or secret.

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module powershell-yaml
    $script:Files = @{
        github = [IO.Path]::Combine($repo, 'pipelines', 'github-actions', 'arm-deployment.yml')
        gitlab = [IO.Path]::Combine($repo, 'pipelines', 'gitlab', 'stages', 'arm-deployment.yml')
        ado    = [IO.Path]::Combine($repo, 'pipelines', 'azure-devops', 'arm-deployment.yml')
    }
    $script:Text = @{}; $script:Doc = @{}
    foreach ($k in $script:Files.Keys) { $script:Text[$k] = Get-Content -LiteralPath $script:Files[$k] -Raw; $script:Doc[$k] = ConvertFrom-Yaml $script:Text[$k] }
    $script:EntryRelative = 'scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1'
    $script:Repo = $repo
}

Describe 'All three pipelines' {
    It '<Name> parses as YAML' -ForEach @(@{ Name = 'github' }, @{ Name = 'gitlab' }, @{ Name = 'ado' }) {
        $script:Doc[$Name] | Should -Not -BeNullOrEmpty
    }
    It '<Name> runs the one entry point script, which exists' -ForEach @(@{ Name = 'github' }, @{ Name = 'gitlab' }, @{ Name = 'ado' }) {
        $script:Text[$Name] | Should -Match ([regex]::Escape($script:EntryRelative))
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-05-cluster-deployment', 'Invoke-AzureLocalArmDeployment.ps1')) | Should -BeTrue
    }
    It '<Name> holds no client secret, no password and no real identifier' -ForEach @(@{ Name = 'github' }, @{ Name = 'gitlab' }, @{ Name = 'ado' }) {
        $t = $script:Text[$Name]
        # devops.authentication.method client_secret: the secret is only ever the platform's secret ARM_CLIENT_SECRET, chosen by AZL_AUTH_METHOD
        foreach ($m in [regex]::Matches($t, '(?m)^.*(ARM_CLIENT_SECRET|clientSecret).*$')) {
            $line = $m.Value
            if ($line.TrimStart().StartsWith('#')) { continue }
            $line | Should -Match 'secrets\.ARM_CLIENT_SECRET|\$env:ARM_CLIENT_SECRET' -Because 'the secret is read from the platform, never written'
        }
        $t | Should -Not -Match 'AZURE_CLIENT_SECRET'
        $t | Should -Not -Match '(?i)password\s*[:=]\s*[''"][^''"<]'
        $t | Should -Not -Match '(?<![0-9a-fA-F-])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9a-fA-F-])'
        $t | Should -Not -Match 'https://[^\s]*\.(vault\.azure\.net)'
    }
    It '<Name> uses forward slashes in every repository path' -ForEach @(@{ Name = 'github' }, @{ Name = 'gitlab' }, @{ Name = 'ado' }) {
        $script:Text[$Name] | Should -Not -Match 'scripts\\|pipelines\\|config\\'
    }
    It '<Name> runs preconditions (Plan) before Validate and Deploy, and reports with the event feed' -ForEach @(@{ Name = 'github' }, @{ Name = 'gitlab' }, @{ Name = 'ado' }) {
        $script:Text[$Name] | Should -Match '-Mode Plan|Mode = .Plan.|ARM_STEP_MODE: Plan'
        $script:Text[$Name] | Should -Match '-Mode Validate|Mode = .Validate.|ARM_STEP_MODE: Validate'
        $script:Text[$Name] | Should -Match '-Mode Deploy|Mode = .Deploy.|ARM_STEP_MODE: Deploy'
        $script:Text[$Name] | Should -Match 'summary\.md'
    }
    It '<Name> takes the approval environment from devops.pipelines.environments.arm_deployment, and names none itself' -ForEach @(@{ Name = 'github'; Pattern = 'vars\.AZL_ENVIRONMENT_ARM_DEPLOYMENT' }, @{ Name = 'gitlab'; Pattern = '\$AZL_ENVIRONMENT_ARM_DEPLOYMENT' }, @{ Name = 'ado'; Pattern = 'variables\.AZL_ENVIRONMENT_ARM_DEPLOYMENT' }) {
        $script:Text[$Name] | Should -Match $Pattern
        $script:Text[$Name] | Should -Not -Match '(?m)^\s+(environment|name): azure-local-deploy'
    }
}

Describe 'GitHub Actions' {
    BeforeAll { $script:G = $script:Doc['github'] }
    It 'has the jobs preconditions, validate and deploy, in that dependency order' {
        $script:G.jobs.Keys | Should -Contain 'preconditions'
        $script:G.jobs.Keys | Should -Contain 'validate'
        $script:G.jobs.Keys | Should -Contain 'deploy'
        $script:G.jobs.validate.needs | Should -Be 'preconditions'
        @($script:G.jobs.deploy.needs) | Should -Contain 'validate'
        @($script:G.jobs.deploy.needs) | Should -Contain 'preconditions'
    }
    It 'the Deploy job is in an environment (the approval gate); Plan and Validate are not' {
        $script:G.jobs.deploy.environment | Should -Be '${{ vars.AZL_ENVIRONMENT_ARM_DEPLOYMENT }}'
        $script:G.jobs.preconditions.Contains('environment') | Should -BeFalse
        $script:G.jobs.validate.Contains('environment') | Should -BeFalse
    }
    It 'the Deploy job only runs for the Deploy modes and its timeout is the wait of the file plus the margin (task 05 sets it)' {
        $script:G.jobs.deploy.if | Should -Match 'ValidateAndDeploy'
        $script:G.jobs.deploy.if | Should -Match "'Deploy'"
        $script:G.jobs.deploy.'timeout-minutes' | Should -Be '${{ fromJSON(vars.AZL_DEPLOY_JOB_TIMEOUT_MINUTES) }}'
    }
    It 'signs in by devops.authentication.method (AZL_AUTH_METHOD): OIDC with id-token write, or the client secret of the platform' {
        $script:G.permissions.'id-token' | Should -Be 'write'
        $script:Text['github'] | Should -Match 'azure/login@v2'
        foreach ($job in 'preconditions', 'validate', 'deploy') {
            $logins = @($script:G.jobs[$job].steps | Where-Object { $_.uses -like 'azure/login@*' })
            $logins.Count | Should -Be 2
            $logins[0].if | Should -Be "`${{ vars.AZL_AUTH_METHOD == 'oidc' }}"
            $logins[0].with.Contains('creds') | Should -BeFalse
            $logins[1].if | Should -Be "`${{ vars.AZL_AUTH_METHOD == 'client_secret' }}"
        }
    }
    It 'every action is pinned to a major version' {
        foreach ($job in $script:G.jobs.Values) { foreach ($s in $job.steps) { if ($s.uses) { $s.uses | Should -Match '@v\d+' } } }
    }
    It 'one run at a time, and a manual trigger with the mode choice' {
        $script:G.concurrency.group | Should -Be 'azure-local-arm-deployment'
        $script:G.concurrency.'cancel-in-progress' | Should -BeFalse
        @($script:G.on.workflow_dispatch.inputs.mode.options) | Should -Be @('Plan', 'Validate', 'ValidateAndDeploy', 'Deploy')
        $script:G.on.Keys | Should -Not -Contain 'push'
    }
    It 'publishes the report and the event feed of every job, even when it failed' {
        foreach ($job in 'preconditions', 'validate', 'deploy') {
            $upload = @($script:G.jobs[$job].steps | Where-Object { $_.uses -like 'actions/upload-artifact@*' })
            $upload.Count | Should -Be 1
            $upload[0].if | Should -Match 'always\(\)'
        }
    }
}

Describe 'GitLab CI' {
    BeforeAll { $script:L = $script:Doc['gitlab'] }
    It 'declares its own stages and the three jobs' {
        @($script:L.stages) | Should -Be @('arm-plan', 'arm-validate', 'arm-deploy')
        foreach ($j in 'arm-preconditions', 'arm-validate', 'arm-deploy') { $script:L.Keys | Should -Contain $j }
        $script:L['arm-validate'].stage | Should -Be 'arm-validate'
        $script:L['arm-deploy'].stage | Should -Be 'arm-deploy'
    }
    It 'the Deploy job is manual, in an environment, never allowed to fail silently' {
        $rule = @($script:L['arm-deploy'].rules)[0]
        $rule.when | Should -Be 'manual'
        $rule.allow_failure | Should -BeFalse
        $script:L['arm-deploy'].environment.name | Should -Be '$AZL_ENVIRONMENT_ARM_DEPLOYMENT'
    }
    It 'serialises runs with a resource group and has OIDC id_tokens' {
        foreach ($j in 'arm-preconditions', 'arm-validate', 'arm-deploy') { $script:L[$j].resource_group | Should -Be 'azure-local-arm-deployment' }
        $script:L['.arm-deployment'].id_tokens.ARM_OIDC_TOKEN.aud | Should -Be 'api://AzureADTokenExchange'
    }
    It 'keeps the artifacts of every job even when it failed' {
        foreach ($j in 'arm-preconditions', 'arm-validate', 'arm-deploy') { $script:L[$j].artifacts.when | Should -Be 'always' }
    }
    It 'is not included from the Terraform and Ansible pipeline, whose stage list is its own' {
        $main = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'gitlab', '.gitlab-ci.yml')) -Raw
        $main | Should -Not -Match 'arm-deployment'
    }
    It 'holds no ID, placeholder or path of its own: the sign-in values and the infrastructure file are the project variables task 05 sets' {
        foreach ($k in 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_AUTH', 'INFRASTRUCTURE_FILE') { $script:L.variables.Contains($k) | Should -BeFalse -Because $k }
        $script:Text['gitlab'] | Should -Match 'AZL_AUTH_METHOD -eq "oidc"'
        $script:Text['gitlab'] | Should -Match 'InfrastructureFile = \$env:AZL_INFRASTRUCTURE_FILE'
    }
}

Describe 'Azure DevOps' {
    BeforeAll { $script:A = $script:Doc['ado'] }
    It 'has no CI trigger and takes the mode as a parameter' {
        $script:A.trigger | Should -Be 'none'
        $script:A.pr | Should -Be 'none'
        @($script:A.parameters | Where-Object name -eq 'mode').values | Should -Be @('Plan', 'Validate', 'ValidateAndDeploy', 'Deploy')
    }
    It 'has the stages Preconditions, Validate and Deploy; Validate and Deploy are chosen by the mode at compile time' {
        $script:Text['ado'] | Should -Match 'stage: Preconditions'
        $script:Text['ado'] | Should -Match 'stage: Validate'
        $script:Text['ado'] | Should -Match 'stage: Deploy'
        $script:Text['ado'] | Should -Match "if or\(eq\(parameters.mode, 'Validate'\), eq\(parameters.mode, 'ValidateAndDeploy'\)\)"
        $script:Text['ado'] | Should -Match "if and\(or\(eq\(parameters.mode, 'ValidateAndDeploy'\), eq\(parameters.mode, 'Deploy'\)\), ne\(variables.AZL_ENVIRONMENT_ARM_DEPLOYMENT, ''\)\)"
        $script:Text['ado'] | Should -Match "if and\(or\(eq\(parameters.mode, 'ValidateAndDeploy'\), eq\(parameters.mode, 'Deploy'\)\), eq\(variables.AZL_ENVIRONMENT_ARM_DEPLOYMENT, ''\)\)"
        $script:Text['ado'] | Should -Match 'stage: ApprovalEnvironmentNotSet'
    }
    It 'Deploy is a deployment job in the approval environment' {
        $script:Text['ado'] | Should -Match '(?m)^\s+- deployment: Deploy'
        # the environment is a variable of a YAML file of the repository (bound at compile time), never a run parameter the queuer could point at an environment with no approval
        $script:Text['ado'] | Should -Match '(?m)^\s+environment: \$\{\{ variables\.AZL_ENVIRONMENT_ARM_DEPLOYMENT \}\}\r?$'
        $script:Text['ado'] | Should -Not -MatchExactly 'approvalEnvironment'
        @($script:A.parameters | Where-Object name -eq 'approvalEnvironment').Count | Should -Be 0
        $script:Text['ado'] | Should -Match '(?m)^\s+- template: variables/approval-environments\.yml\r?$'
    }
    It 'signs in through a workload identity service connection and the AzurePowerShell task, not with a secret' {
        $script:Text['ado'] | Should -Match 'AzurePowerShell@5'
        $script:Text['ado'] | Should -Match 'azureSubscription: \$\{\{ parameters.azureServiceConnection \}\}'
        $script:Text['ado'] | Should -Match 'workload identity federation'
        # Pass H: the name is devops.pipelines.service_connection, entered at run time; the parameter has no default (not even a placeholder).
        $p = @($script:A.parameters | Where-Object name -eq 'azureServiceConnection')
        $p.Count | Should -Be 1
        $p[0].Contains('default') | Should -BeFalse
        $script:Text['ado'] | Should -Match 'devops\.pipelines\.service_connection'
    }
    It 'the stage with the long deploy has the fixed upper bound above the largest wait the file allows, and runs queue one after the other' {
        $script:Text['ado'] | Should -Match 'timeoutInMinutes: 1500'
        $script:A.lockBehavior | Should -Be 'sequential'
        @($script:A.parameters | Where-Object name -eq 'infrastructureFile')[0].Contains('default') | Should -BeFalse
        $script:Text['ado'] | Should -Match 'preferredAzurePowerShellVersion: \$\(AZL_AZ_POWERSHELL_VERSION\)'
    }
}
