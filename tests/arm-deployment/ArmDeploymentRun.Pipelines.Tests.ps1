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
        $t | Should -Not -Match 'ARM_CLIENT_SECRET|client_secret|clientSecret|AZURE_CLIENT_SECRET'
        $t | Should -Not -Match '(?i)password\s*[:=]\s*[''"][^''"<]'
        $t | Should -Not -Match '(?<![0-9a-fA-F-])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9a-fA-F-])'
        $t | Should -Not -Match 'https://[^\s]*\.(vault\.azure\.net)'
    }
    It '<Name> uses forward slashes in every repository path' -ForEach @(@{ Name = 'github' }, @{ Name = 'gitlab' }, @{ Name = 'ado' }) {
        $script:Text[$Name] | Should -Not -Match 'scripts\\|pipelines\\|config\\'
    }
    It '<Name> runs preconditions (Plan) before Validate and Deploy, and reports with the event feed' -ForEach @(@{ Name = 'github' }, @{ Name = 'gitlab' }, @{ Name = 'ado' }) {
        $script:Text[$Name] | Should -Match '-Mode Plan|Mode = .Plan.'
        $script:Text[$Name] | Should -Match '-Mode Validate|Mode = .Validate.'
        $script:Text[$Name] | Should -Match '-Mode Deploy|Mode = .Deploy.'
        $script:Text[$Name] | Should -Match 'summary\.md'
    }
    It '<Name> takes the approval environment from devops.pipelines.environments.arm_deployment, and names none itself' -ForEach @(@{ Name = 'github'; Pattern = 'vars\.AZL_ENVIRONMENT_ARM_DEPLOYMENT' }, @{ Name = 'gitlab'; Pattern = '\$AZL_ENVIRONMENT_ARM_DEPLOYMENT' }, @{ Name = 'ado'; Pattern = 'parameters\.approvalEnvironment' }) {
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
    It 'the Deploy job only runs for the Deploy modes and has a timeout that fits 3 hours of deployment' {
        $script:G.jobs.deploy.if | Should -Match 'ValidateAndDeploy'
        $script:G.jobs.deploy.if | Should -Match "'Deploy'"
        [int]$script:G.jobs.deploy.'timeout-minutes' | Should -BeGreaterThan 360
    }
    It 'signs in with OIDC (id-token write, azure/login, no secret input)' {
        $script:G.permissions.'id-token' | Should -Be 'write'
        $script:Text['github'] | Should -Match 'azure/login@v2'
        $script:Text['github'] | Should -Not -Match 'creds:'
        foreach ($job in 'preconditions', 'validate', 'deploy') {
            @($script:G.jobs[$job].steps | Where-Object { $_.uses -like 'azure/login@*' }).Count | Should -Be 1
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
        $script:L['.arm-deployment'].id_tokens.AZURE_ID_TOKEN.aud | Should -Be 'api://AzureADTokenExchange'
    }
    It 'keeps the artifacts of every job even when it failed' {
        foreach ($j in 'arm-preconditions', 'arm-validate', 'arm-deploy') { $script:L[$j].artifacts.when | Should -Be 'always' }
    }
    It 'is not included from the Terraform and Ansible pipeline, whose stage list is its own' {
        $main = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'gitlab', '.gitlab-ci.yml')) -Raw
        $main | Should -Not -Match 'arm-deployment'
    }
    It 'the placeholders are placeholders' {
        $script:L.variables.AZURE_CLIENT_ID | Should -Match '^<.*>$'
        $script:L.variables.AZURE_TENANT_ID | Should -Match '^<.*>$'
        $script:L.variables.AZURE_SUBSCRIPTION_ID | Should -Match '^<.*>$'
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
        $script:Text['ado'] | Should -Match "if or\(eq\(parameters.mode, 'ValidateAndDeploy'\), eq\(parameters.mode, 'Deploy'\)\)"
    }
    It 'Deploy is a deployment job in the approval environment' {
        $script:Text['ado'] | Should -Match '(?m)^\s+- deployment: Deploy'
        $script:Text['ado'] | Should -Match '(?m)^\s+environment: \$\{\{ parameters\.approvalEnvironment \}\}'
    }
    It 'signs in through a workload identity service connection and the AzurePowerShell task, not with a secret' {
        $script:Text['ado'] | Should -Match 'AzurePowerShell@5'
        $script:Text['ado'] | Should -Match 'azureSubscription: \$\{\{ parameters.azureServiceConnection \}\}'
        $script:Text['ado'] | Should -Match 'workload identity federation'
        $script:A.parameters | Where-Object name -eq 'azureServiceConnection' | ForEach-Object { $_.default } | Should -Match '^<.*>$'
    }
    It 'the stage with the long deploy has a timeout over 3 hours' {
        $script:Text['ado'] | Should -Match 'timeoutInMinutes: 480'
    }
}
