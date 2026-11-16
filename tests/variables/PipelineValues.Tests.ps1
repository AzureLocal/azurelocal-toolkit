#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Owner directive D121: no value of a deployment is written in a pipeline file. Every script and automation takes its values from a variable
# file generated from the master registry; for the pipelines under pipelines/ that is the variables task 05 of the CI/CD setup sets from
# infrastructure.yml (scripts/common/cicd-infra/AzlCicdInfra.psm1, $script:AzlPipelineVariable). This test fails when a pipeline file has:
#   - a tool version literal (Terraform, Python, ansible-core, ansible-lint, Az PowerShell, powershell-yaml, Az.KeyVault), or a tool it installs
#     without the version of devops.pipelines.tool_versions;
#   - an infrastructure file path literal or a handoff path literal;
#   - a runner OS label literal, or a hosted image on a job that does more than validate or plan;
#   - ARM_USE_OIDC or ARM_CLIENT_SECRET chosen without the sign-in method variable AZL_AUTH_METHOD, or a managed identity sign-in;
#   - a deploy branch literal;
#   - a parameter, input or variable default that is a choice of a deployment.
# The reviewed allow-list below holds the values the platform fixes: action and task versions, built-in variables, the toolkit's own repository
# paths and artifact names, the hosted image of the jobs that only validate or plan, and the safe default of a per-run choice.
# Nothing is run and nothing is sent anywhere.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/PipelineValues.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'pipelines'))
    $script:Files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.yml' -File -Force | ForEach-Object { @{ File = 'pipelines/' + $_.FullName.Substring($root.Length + 1).Replace('\', '/') } })
    $script:GitHubFiles = @($script:Files | Where-Object { $_.File -like 'pipelines/github-actions/*' })
    $script:AdoFiles = @($script:Files | Where-Object { $_.File -like 'pipelines/azure-devops/*' })
    $script:GitLabFiles = @($script:Files | Where-Object { $_.File -like 'pipelines/gitlab/*' })
    $script:HostedFiles = @($script:Files | Where-Object { [IO.File]::ReadAllText([IO.Path]::Combine($root, '..', $_.File)).Contains('ubuntu-latest') })
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Module = Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')) -Force -PassThru
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))

    function Get-Text([string]$File) { [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $File)) }
    function Get-Yaml([string]$File) { ConvertFrom-Yaml (Get-Text $File) -Ordered }
    # The code lines of a file: no comment line, and no trailing ' # comment'.
    function Get-CodeLine([string]$File) {
        $n = 0
        foreach ($line in ((Get-Text $File) -split "`r?`n")) {
            $n++
            if ($line.TrimStart().StartsWith('#')) { continue }
            [pscustomobject]@{ Number = $n; Text = ($line -replace '\s+#\s.*$', '') }
        }
    }
    function Get-Node($Node, [string]$Key = '') {
        if ($Node -is [System.Collections.IDictionary]) {
            [pscustomobject]@{ Key = $Key; Node = $Node }
            foreach ($k in $Node.Keys) { Get-Node $Node[$k] ([string]$k) }
        }
        elseif ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { Get-Node $i $Key } }
    }

    # ---------------------------------------------------------------------------------------------------------------------------------
    # The reviewed allow-list
    # ---------------------------------------------------------------------------------------------------------------------------------
    # Version-like text the platform fixes: the major version of an action (@v4) or a task (AzurePowerShell@5), and the build number format.
    $script:PlatformVersionToken = '@v\d+\b', '\b[A-Za-z]+@\d+\b', '\$\(Date:yyyyMMdd\)\$\(Rev:\.r\)'
    # Jobs that only validate or plan may run on the vendor's hosted image (a platform choice). cicd-infra plans and applies on it only for
    # the first run, before the self-hosted runners exist (its runner input or agentPool parameter chooses).
    $script:HostedJob = @{
        'pipelines/github-actions/azure-local-deploy.yml' = @('terraform-validate', 'ansible-lint', 'terraform-plan')
        'pipelines/github-actions/cicd-infra.yml'         = @('validate', 'plan', 'apply')
        'pipelines/azure-devops/azure-local-deploy.yml'   = @('TerraformValidate', 'AnsibleLint', 'TerraformPlan')
        'pipelines/azure-devops/cicd-infra.yml'           = @('Validate', 'Plan', 'Apply')
    }
    $script:HostedImage = 'ubuntu-latest'
    # The defaults a per-run choice may have: the safe choice, never a value of a deployment.
    $script:SafeDefault = @('', 'none', 'all', 'Plan', 'hosted', 'github-hosted', 'false', 'False')
    # GitLab and Azure DevOps variables a file may define: the toolkit's own paths, built-in variables, artifact names and per-job constants.
    $script:FileVariable = @{
        OSCONFIG_SCRIPT = '^scripts/'; ARM_SCRIPT = '^scripts/'; armScript = '^scripts/'; TASK06 = '^scripts/'; CICD_TASK06 = '^scripts/'
        DISCOVERY_SCRIPT = '^scripts/'; PRECLUSTER_SCRIPT = '^scripts/'; preClusterScript = '^scripts/'
        TF_ROOT = '^(\$\{CI_PROJECT_DIR\}/)?src/'; ANSIBLE_ROOT = '^(\$\{CI_PROJECT_DIR\}/)?src/'; CICD_TF_ROOT = '^\$\{CI_PROJECT_DIR\}/src/'
        CICD_WORK = '^\$\{CI_PROJECT_DIR\}/\.cicd-infra$'; WORK = '^\$\(Pipeline\.Workspace\)/'; IAC_DIRECTORY = '^\$\{CI_BUILDS_DIR\}/azl-iac-\$\{CI_JOB_ID\}$'
        REPORT_DIRECTORY = '^(os-configuration-report|arm-deployment-report|discovery-report|pre-cluster-report)$'; OS_CONFIGURATION_REPORT = '^os-configuration-report$'
        ANSIBLE_HOST_KEY_CHECKING = '^False$'; TF_IN_AUTOMATION = '^true$'; APPROVED_BOOTSTRAP = '^false$'; ARM_RESUME = '^false$'; ARM_ACKNOWLEDGE = '^$'
        DISCOVERY_SCOPE = '^all$'; DISCOVERY_MANAGEMENT_PORT = '^$'; DISCOVERY_WRITE_BACK = '^false$'; DISCOVERY_INCLUDE_RBAC = '^false$'
        PRECLUSTER_MODE = '^Plan$'; PRECLUSTER_ACCEPT_SKIPPED = '^$'; PRECLUSTER_ALLOW_REVALIDATE = '^false$'; PRECLUSTER_FIX = '^false$'
        PRECLUSTER_INSTALL_ENVIRONMENT_CHECKER = '^false$'; PRECLUSTER_CHANGES = '^(true|false)$'
        HANDOFF_FILE = '^$'; ARM_MODE = '^Plan$'; ARM_STEP_MODE = '^(Plan|Validate|Deploy)$'; ARM_STEP_DIRECTORY = '^(plan|validate|deploy)$'
        # the approval environment an Azure DevOps pipeline binds at compile time (a template expression sees only the variables of YAML files): the toolkit ships it empty
        AZL_ENVIRONMENT_ARM_DEPLOYMENT = '^$'
    }
}

Describe 'Tool versions: every pipeline installs the versions of devops.pipelines.tool_versions, and names none itself' {
    It '<File> has no version literal' -ForEach $script:Files {
        $bad = foreach ($l in (Get-CodeLine $File)) {
            $text = $l.Text
            foreach ($token in $script:PlatformVersionToken) { $text = $text -replace $token, '' }
            if ($text -match '(?<![\w$.{-])\d+\.\d+(\.\d+)*(?![\w])') { "line $($l.Number): $($l.Text.Trim())" }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It '<File>: every version input is an AZL_*_VERSION variable, and Az PowerShell is not LatestVersion' -ForEach $script:Files {
        foreach ($l in (Get-CodeLine $File)) {
            if ($l.Text -match '^\s*(terraform_version|terraformVersion|versionSpec|python-version|preferredAzurePowerShellVersion):\s*(.+)$') {
                $Matches[2] | Should -Match 'AZL_[A-Z_]+_VERSION' -Because "$File line $($l.Number)"
            }
            if ($l.Text -match '^\s*azurePowerShellVersion:\s*(\S+)') { $Matches[1] | Should -Be 'OtherVersion' -Because "$File line $($l.Number) takes the version of AZL_AZ_POWERSHELL_VERSION" }
        }
    }
    It '<File>: every module install has a required version, and every pip install pins each package' -ForEach $script:Files {
        foreach ($l in (Get-CodeLine $File)) {
            if ($l.Text -match 'Install-Module|Install-PSResource') { $l.Text | Should -Match '-RequiredVersion \$(env:|m\.Value|\{\{)' -Because "$File line $($l.Number)" }
            # pip install -r <requirements of azure.azcollection>: the versions the collection pins
            if ($l.Text -match 'pip install\s+(.+)$' -and $l.Text -notmatch 'pip install (--quiet )?-r ') {
                foreach ($package in ($Matches[1] -split '\s+' | Where-Object { $_ -and $_ -notlike '-*' })) { $package | Should -Match '==\$(env:)?AZL_[A-Z_]+_VERSION' -Because "$File line $($l.Number)" }
            }
            $l.Text | Should -Not -Match 'releases\.hashicorp\.com/terraform/\d' -Because "$File line $($l.Number)"
        }
    }
    It '<File>: setup-terraform and setup-python name their version' -ForEach $script:GitHubFiles {
        $doc = Get-Yaml $File
        foreach ($job in $doc['jobs'].Keys) {
            foreach ($step in @($doc['jobs'][$job]['steps'])) {
                if ([string]$step['uses'] -like 'hashicorp/setup-terraform@*') { [string]$step['with']['terraform_version'] | Should -Be '${{ vars.AZL_TERRAFORM_VERSION }}' -Because "$File $job" }
                if ([string]$step['uses'] -like 'actions/setup-python@*') { [string]$step['with']['python-version'] | Should -Be '${{ vars.AZL_PYTHON_VERSION }}' -Because "$File $job" }
            }
        }
    }
    It '<File>: every TerraformInstaller and UsePythonVersion task names its version' -ForEach $script:AdoFiles {
        foreach ($n in (Get-Node (Get-Yaml $File))) {
            if ([string]$n.Node['task'] -like 'TerraformInstaller@*') { [string]$n.Node['inputs']['terraformVersion'] | Should -Be '$(AZL_TERRAFORM_VERSION)' }
            if ([string]$n.Node['task'] -like 'UsePythonVersion@*') { [string]$n.Node['inputs']['versionSpec'] | Should -Be '$(AZL_PYTHON_VERSION)' }
        }
    }
    It 'the GitLab jobs install their tools through Use-AzlGitLabTool.ps1, which holds no version of its own' {
        $tool = Get-Text 'pipelines/gitlab/Use-AzlGitLabTool.ps1'
        $code = ($tool -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') -and $_ -notmatch '^\s*\.' }) -join "`n"
        $code | Should -Not -Match '(?<![\w$.{-])\d+\.\d+(\.\d+)*(?![\w])'
        $gitlab = [IO.Path]::Combine($script:Repo, 'pipelines', 'gitlab')
        foreach ($f in @(Get-ChildItem -LiteralPath $gitlab -Recurse -Filter '*.yml' -File -Force | ForEach-Object { 'pipelines/gitlab/' + $_.FullName.Substring($gitlab.Length + 1).Replace('\', '/') })) {
            foreach ($l in (Get-CodeLine $f)) { if ($l.Text -match '\b(terraform|ansible-playbook|ansible-lint)\s+(init|plan|apply|validate|fmt|test|-i|--syntax|playbooks)') { (Get-Text $f) | Should -Match 'Use-AzlGitLabTool\.ps1 -Tool' -Because "$f runs a tool" } }
        }
    }
}

Describe 'Paths: the infrastructure file and the handoff path come from the variable task 05 sets' {
    It '<File> holds no infrastructure file or handoff path literal' -ForEach $script:Files {
        foreach ($l in (Get-CodeLine $File)) {
            # a display text may name the file; a value may not
            if ($l.Text -match '^\s*-?\s*(displayName|name|description):') { continue }
            $l.Text | Should -Not -Match '[\w./-]*infrastructure\.ya?ml' -Because "$File line $($l.Number)"
            $l.Text | Should -Not -Match 'ztp-state' -Because "$File line $($l.Number)"
        }
    }
}

Describe 'Runners: the OS label and the runner label come from the variables, and a hosted image only validates or plans' {
    It '<File>: runs-on names no OS label, and a hosted image only on a reviewed validate or plan job' -ForEach $script:GitHubFiles {
        $doc = Get-Yaml $File
        foreach ($job in $doc['jobs'].Keys) {
            $on = $doc['jobs'][$job]['runs-on']
            foreach ($item in @($on)) { [string]$item | Should -Not -Match '(?i)(^|[^\w.])(linux|windows|macos)([^\w]|$)' -Because "$File $job" }
            if (([string](@($on) -join ' ')).Contains($script:HostedImage)) { @($script:HostedJob[$File]) | Should -Contain $job -Because "$File $job runs on the hosted image" }
            if ($on -is [System.Collections.IList]) { (@($on) -join ' ') | Should -Match 'vars\.AZL_RUNNER_OS' -Because "$File $job" }
        }
    }
    It '<File>: a hosted image only on a reviewed validate or plan job' -ForEach $script:AdoFiles {
        $lines = (Get-Text $File) -split "`r?`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch '^\s*vmImage:\s*(\S+)') { continue }
            $Matches[1].Trim("'", '"') | Should -Be $script:HostedImage -Because "$File line $($i + 1)"
            $name = ''
            for ($j = $i - 1; $j -ge 0; $j--) { if ($lines[$j] -match '^\s*-\s*(stage|job|deployment):\s*(\S+)') { $name = $Matches[2]; break } }
            @($script:HostedJob[$File]) | Should -Contain $name -Because "$File line $($i + 1) runs $name on the hosted image"
        }
    }
    It 'every file states why a hosted image is a platform choice' -ForEach $script:HostedFiles {
        (Get-Text $File) | Should -Match '(?i)hosted image[^\r\n]*(platform choice|validate|plan)'
    }
}

Describe 'Sign-in: every pipeline follows devops.authentication.method (AZL_AUTH_METHOD)' {
    It '<File>: ARM_USE_OIDC and ARM_CLIENT_SECRET are set only by AZL_AUTH_METHOD' -ForEach $script:Files {
        foreach ($l in (Get-CodeLine $File)) {
            if ($l.Text -match '(?<![\w.])(\$env:)?ARM_(USE_OIDC|CLIENT_SECRET)\s*(:|=(?!=))') { $l.Text | Should -Match 'AZL_AUTH_METHOD' -Because "$File line $($l.Number): $($l.Text.Trim())" }
        }
    }
    It '<File>: a file that signs in follows AZL_AUTH_METHOD, and uses no managed identity of the runner' -ForEach $script:Files {
        $code = (@(Get-CodeLine $File) | ForEach-Object Text) -join "`n"
        if ($code -match 'azure/login@|Connect-AzAccount|az login|ARM_CLIENT_ID|ARM_USE_OIDC') { $code | Should -Match 'AZL_AUTH_METHOD' }
        $code | Should -Not -Match '(?i)Connect-AzAccount -Identity|az login --identity|ARM_USE_MSI|managed-identity'
        $code | Should -Not -Match 'AZURE_CLIENT_ID|AZURE_TENANT_ID|AZURE_SUBSCRIPTION_ID' -Because 'the sign-in values are ARM_*, the names task 05 sets'
    }
    It 'GitHub: each azure/login step runs for one method only' -ForEach $script:GitHubFiles {
        $doc = Get-Yaml $File
        foreach ($job in $doc['jobs'].Keys) {
            $logins = @(@($doc['jobs'][$job]['steps']) | Where-Object { [string]$_['uses'] -like 'azure/login@*' })
            if ($logins.Count -eq 0) { continue }
            $logins.Count | Should -Be 2 -Because "$File $job signs in by OIDC or by the client secret"
            [string]$logins[0]['if'] | Should -Be "`${{ vars.AZL_AUTH_METHOD == 'oidc' }}"
            [string]$logins[1]['if'] | Should -Be "`${{ vars.AZL_AUTH_METHOD == 'client_secret' }}"
            $logins[0]['with'].Contains('creds') | Should -BeFalse
            [string]$logins[1]['with']['creds'] | Should -Match 'secrets\.ARM_CLIENT_SECRET'
        }
    }
}

Describe 'Branches: the deploy branch is the default branch of the repository' {
    It '<File> holds no branch name' -ForEach $script:Files {
        foreach ($l in (Get-CodeLine $File)) {
            if ($l.Text -match '^\s*-?\s*(displayName|description):') { continue }
            $l.Text | Should -Not -Match '(?<![\w./-])(main|master)(?![\w.-])' -Because "$File line $($l.Number)"
            $l.Text | Should -Not -Match 'refs/heads/(?!\{0\})' -Because "$File line $($l.Number)"
        }
    }
    It 'each platform gates the deploy on its default branch' {
        (Get-Text 'pipelines/github-actions/azure-local-deploy.yml') | Should -Match "format\('refs/heads/\{0\}', github\.event\.repository\.default_branch\)"
        (Get-Text 'pipelines/azure-devops/azure-local-deploy.yml') | Should -Match "format\('refs/heads/\{0\}', variables\['AZL_DEFAULT_BRANCH'\]\)"
        (Get-Text 'pipelines/gitlab/stages/deploy-foundation.yml') | Should -Match '\$CI_COMMIT_BRANCH == \$CI_DEFAULT_BRANCH'
    }
}

Describe 'Defaults: no parameter, input or variable default is a choice of a deployment' {
    It '<File>: every parameter with a default defaults to the safe choice of one run' -ForEach $script:AdoFiles {
        foreach ($p in @((Get-Yaml $File)['parameters'])) {
            if ($null -eq $p -or -not $p.Contains('default')) { continue }   # a variables template has no parameters
            [string]$p['default'] | Should -BeIn $script:SafeDefault -Because "$File parameter $($p['name'])"
        }
    }
    It '<File>: every workflow input with a default defaults to the safe choice of one run' -ForEach $script:GitHubFiles {
        $doc = Get-Yaml $File
        $on = if ($doc.Contains('on')) { $doc['on'] } else { $doc[$true] }
        if ($on -isnot [System.Collections.IDictionary] -or $on['workflow_dispatch'] -isnot [System.Collections.IDictionary]) { return }
        foreach ($name in $on['workflow_dispatch']['inputs'].Keys) {
            $i = $on['workflow_dispatch']['inputs'][$name]
            if ($i.Contains('default')) { [string]$i['default'] | Should -BeIn $script:SafeDefault -Because "$File input $name" }
        }
    }
    It '<File>: every env value is an expression or the toolkit''s own path' -ForEach $script:GitHubFiles {
        foreach ($n in (Get-Node (Get-Yaml $File))) {
            if (-not $n.Node.Contains('env') -or $n.Node['env'] -isnot [System.Collections.IDictionary]) { continue }
            foreach ($k in $n.Node['env'].Keys) {
                # ANSIBLE_AZURE_AUTH_SOURCE cli: azure.azcollection uses the Azure CLI sign-in of the job (a toolkit constant)
                if ($k -eq 'ANSIBLE_AZURE_AUTH_SOURCE') { [string]$n.Node['env'][$k] | Should -Be 'cli'; continue }
                [string]$n.Node['env'][$k] | Should -Match '^(\$\{\{.+\}\}|scripts/|src/)' -Because "$File env $k"
            }
        }
    }
    It '<File>: every variable the file defines is a reviewed toolkit constant' -ForEach (@($script:GitLabFiles) + @($script:AdoFiles)) {
        foreach ($n in (Get-Node (Get-Yaml $File))) {
            if (-not $n.Node.Contains('variables')) { continue }
            $vars = $n.Node['variables']
            $pairs = [System.Collections.Generic.List[object]]::new()
            if ($vars -is [System.Collections.IDictionary]) { foreach ($k in $vars.Keys) { $pairs.Add([pscustomobject]@{ Name = [string]$k; Value = $vars[$k] }) } }
            else { foreach ($v in @($vars)) { if ($v -is [System.Collections.IDictionary] -and $v.Contains('name')) { $pairs.Add([pscustomobject]@{ Name = [string]$v['name']; Value = $v['value'] }) } } }
            foreach ($pair in $pairs) {
                $name = $pair.Name; $value = $pair.Value
                if ($value -is [System.Collections.IDictionary]) { $value = $value['value'] }
                $script:FileVariable.ContainsKey($name) | Should -BeTrue -Because "$File defines ${name}: add it to the reviewed list only if it is a toolkit constant"
                [string]$value | Should -Match $script:FileVariable[$name] -Because "$File $name"
            }
        }
    }
}

Describe 'Task 05 sets every value a pipeline reads, from its key, with the registry default' {
    It 'every AZL_ name a pipeline reads is in the task 05 table for that platform' -ForEach $script:Files {
        $table = @(& $script:Module { $script:AzlPipelineVariable })
        $platform = if ($File -like 'pipelines/azure-devops/*') { 'azure_devops' } elseif ($File -like 'pipelines/gitlab/*') { 'gitlab' } else { 'github' }
        $names = @([regex]::Matches(((@(Get-CodeLine $File) | ForEach-Object Text) -join "`n"), '(?<![A-Za-z0-9_])(AZL_[A-Z_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($n in $names) {
            $v = @($table | Where-Object Name -EQ $n)
            $v.Count | Should -Be 1 -Because "$File reads $n"
            $v[0].Platforms | Should -Contain $platform -Because "$File reads $n"
        }
    }
    It 'the module defaults are the registry defaults' {
        $defaults = & $script:Module { $script:AzlPipelineDefault }
        foreach ($key in $defaults.Keys) {
            $entry = @($script:Registry | Where-Object Path -EQ $key)
            $entry.Count | Should -Be 1 -Because $key
            [string]$entry[0].Node['default'] | Should -Be ([string]$defaults[$key]) -Because $key
        }
        $state = @($script:Registry | Where-Object Path -EQ 'devops.state.azure_local_key')[0].Node['default']
        $state | Should -Be (& $script:Module { $script:AzlAzureLocalStateKey })
    }
    It 'the Terraform default is the version the toolkit''s runners carry' {
        $runner = ([string]@($script:Registry | Where-Object { $_.Path -like 'tools.*.tool_versions_terraform' })[0].Node['default']).Trim('"')  # the Terraform entries hold the HCL default, quotes included
        $pipelines = @($script:Registry | Where-Object Path -EQ 'devops.pipelines.tool_versions.terraform')[0].Node['default']
        $pipelines | Should -Be $runner
        (Get-Text 'src/ansible/roles/cicd_runner/defaults/main.yml') | Should -Match "cicd_runner_terraform_version: `"$([regex]::Escape($pipelines))`""
    }
    It 'every key of the task 05 table is a key of infrastructure.yml with since 5.6.25 or later, or an older key' {
        foreach ($v in @(& $script:Module { $script:AzlPipelineVariable })) {
            @($script:Registry | Where-Object Path -EQ $v.Key).Count | Should -Be 1 -Because $v.Key
        }
    }
    It 'the legacy keys devops.terraform.tf_backend_* are deprecated, and nothing reads them' {
        foreach ($k in 'devops.terraform.tf_backend_storage_account', 'devops.terraform.tf_backend_container') {
            @($script:Registry | Where-Object Path -EQ $k)[0].Node['deprecated'] | Should -BeTrue
        }
        foreach ($dir in 'scripts', 'pipelines', 'src', 'config/variables/scripts') {
            $hits = Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, $dir)) -Recurse -File | Select-String -Pattern 'tf_backend_storage_account|tf_backend_container' -CaseSensitive -List
            @($hits) | Should -BeNullOrEmpty -Because $dir
        }
    }
}

Describe 'Removed and moved pipeline files' {
    It 'GitHub pipelines live in pipelines/github-actions only' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'github')) | Should -BeFalse
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'github-actions', 'os-configuration.yml')) | Should -BeTrue
    }
    It 'the dead GitLab files are gone, and every included file exists' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'gitlab', 'templates')) | Should -BeFalse
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'gitlab', 'stages', 'deploy-cluster.yml')) | Should -BeFalse
        $main = Get-Yaml 'pipelines/gitlab/.gitlab-ci.yml'
        foreach ($i in @($main['include'])) { Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, $i['local'])) | Should -BeTrue -Because $i['local'] }
        # every stage a job uses is declared
        $stages = @($main['stages'])
        foreach ($i in @($main['include'])) {
            $doc = Get-Yaml $i['local']
            foreach ($job in $doc.Keys) { if ($doc[$job] -is [System.Collections.IDictionary] -and $doc[$job].Contains('stage')) { $stages | Should -Contain $doc[$job]['stage'] -Because "$($i['local']) $job" } }
        }
    }
    It 'no file of the repository names a removed or moved pipeline path' {
        $hits = foreach ($dir in 'docs', 'pipelines', 'scripts', 'tests', 'config/variables/docs', 'repo-management') {
            Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, $dir)) -Recurse -File -Include '*.md', '*.yml', '*.ps1', '*.psm1' |
                Where-Object { $_.Name -ne 'PipelineValues.Tests.ps1' } |
                Select-String -Pattern 'pipelines/github/|gitlab/templates/|stages/deploy-cluster\.yml' -List | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        }
        @($hits) | Should -BeNullOrEmpty
    }
    It 'the archived GitHub workflows are described as archived' {
        (Get-Text '.azurelocal-platform.yml') | Should -Match 'reusableWorkflows: \[\]'
        (Get-Text 'repo-management/automation.md') | Should -Match '\*\*Archived\.\*\*'
    }
}

Describe 'One version per tool (D121): the pipelines, the Terraform runner module and the Ansible runner role install the same release' {
    BeforeAll {
        $schema = [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) | ConvertFrom-Json -AsHashtable
        $script:PipelineVersion = $schema.properties.devops.properties.pipelines.properties.tool_versions.properties
        $tf = [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, 'src', 'terraform', 'modules', 'cicd-runner', 'variables.tf'))
        $script:TerraformVersion = @{}
        foreach ($m in [regex]::Matches($tf, '(?m)^\s+(?<k>[a-z_]+)\s*=\s*optional\(string,\s*"(?<v>[^"]*)"\)')) { $script:TerraformVersion[$m.Groups['k'].Value] = $m.Groups['v'].Value }
        $role = ConvertFrom-Yaml ([IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, 'src', 'ansible', 'roles', 'cicd_runner', 'defaults', 'main.yml')))
        $script:RoleVersion = $role
    }
    It '<Tool>: pipelines <Pipeline>, Terraform <Terraform>, Ansible <Role>' -ForEach @(
        @{ Tool = 'terraform'; Pipeline = 'terraform'; Terraform = 'terraform'; Role = 'cicd_runner_terraform_version' }
        @{ Tool = 'ansible-core'; Pipeline = 'ansible_core'; Terraform = 'ansible_core'; Role = 'cicd_runner_ansible_core_version' }
        @{ Tool = 'ansible-lint'; Pipeline = 'ansible_lint'; Terraform = $null; Role = 'cicd_runner_ansible_lint_version' }
        @{ Tool = 'Az PowerShell'; Pipeline = 'az_powershell'; Terraform = 'az_powershell'; Role = 'cicd_runner_az_module_version' }
        @{ Tool = 'powershell-yaml'; Pipeline = 'powershell_yaml'; Terraform = $null; Role = 'cicd_runner_powershell_yaml_version' }
    ) {
        $want = [string]$script:PipelineVersion[$Pipeline].default
        $want | Should -Not -BeNullOrEmpty -Because "devops.pipelines.tool_versions.$Pipeline needs a pinned default"
        [string]$script:RoleVersion[$Role] | Should -Be $want -Because "src/ansible/roles/cicd_runner/defaults/main.yml $Role must install the release the pipelines install"
        if ($Terraform) { $script:TerraformVersion[$Terraform] | Should -Be $want -Because "src/terraform/modules/cicd-runner/variables.tf tool_versions.$Terraform must install the release the pipelines install" }
    }
}