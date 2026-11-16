#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The day 2 pipelines and the validation pipeline (stage 08 tasks 01 to 04, stage 07 tasks 01 to 04), once per platform (GitHub Actions, GitLab CI, Azure DevOps):
# they parse, call only scripts that exist with parameters those scripts have, take no credential, fail the run when a script fails, publish the report even then,
# keep every job that changes the cluster (or puts load on it) behind the approval environment of devops.pipelines.environments.operations, run a read-only plan
# first, never run two changes together, take exactly one node per run and check it against the master file, and keep the schedule of the check for updates equal
# to the registry default. Nothing is run and nothing is sent anywhere.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines/Day2Pipelines.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $day2 = '08-day2-operations'
    $validation = '07-validation-handover'
    $azureCheck = "scripts/deploy/$day2/task-01-check-for-updates/azurecli/Get-AvailableSolutionUpdate.azcli.ps1"
    $clusterCheck = "scripts/deploy/$day2/task-01-check-for-updates/powershell/Get-AvailableSolutionUpdate.ps1"
    $update = "scripts/deploy/$day2/task-02-start-solution-update/powershell/Start-AzureLocalSolutionUpdate.ps1"
    $maintenance = "scripts/deploy/$day2/task-03-node-maintenance/powershell/Invoke-NodeMaintenanceReboot.ps1"
    $operations = "scripts/deploy/$day2/task-04-cluster-operations/powershell/Invoke-ClusterOperations.ps1"
    $health = "scripts/deploy/$validation/task-01-cluster-health-validation/powershell/Test-AzureLocalClusterHealth.ps1"
    $arc = "scripts/deploy/$validation/task-02-arc-connectivity-validation/powershell/Test-ArcConnectivity.ps1"
    $network = "scripts/deploy/$validation/task-03-network-configuration-validation/powershell/Test-NetworkConfiguration.ps1"
    $storage = "scripts/deploy/$validation/task-04-storage-performance-validation/powershell/Test-StoragePerformance.ps1"
    # Name, the three files, the scripts it runs, and the jobs (GitHub), the jobs (GitLab) and the stages (Azure DevOps) that only read and that change something
    $script:Pipelines = @(
        @{ Name = 'day2-check-updates'; Scripts = @($azureCheck, $clusterCheck); Read = @('check-azure', 'check-cluster'); Change = @(); GitLabRead = @('day2-check-updates-azure', 'day2-check-updates-cluster'); GitLabChange = @(); AdoRead = @('CheckAzure', 'CheckCluster'); AdoChange = @() }
        @{ Name = 'day2-update'; Scripts = @($update); Read = @('plan'); Change = @('apply'); GitLabRead = @('day2-update-plan'); GitLabChange = @('day2-update-apply'); AdoRead = @('Plan'); AdoChange = @('Apply') }
        @{ Name = 'day2-node-maintenance'; Scripts = @($maintenance); Read = @('plan'); Change = @('apply'); GitLabRead = @('day2-node-maintenance-plan'); GitLabChange = @('day2-node-maintenance-apply'); AdoRead = @('Plan'); AdoChange = @('Apply') }
        @{ Name = 'day2-cluster-operations'; Scripts = @($operations); Read = @('read-only', 'plan-changes'); Change = @('apply-changes'); GitLabRead = @('day2-cluster-operations-read', 'day2-cluster-operations-plan'); GitLabChange = @('day2-cluster-operations-apply'); AdoRead = @('ReadOnly', 'Plan'); AdoChange = @('Apply') }
        @{ Name = 'validation'; Scripts = @($health, $arc, $network, $storage); Read = @('validate'); Change = @('storage-performance'); GitLabRead = @('validation-read-only'); GitLabChange = @('validation-storage-performance'); AdoRead = @('Validate'); AdoChange = @('StoragePerformance') }
    )
    $script:Files = @(foreach ($p in $script:Pipelines) {
            $github = "pipelines/github-actions/$($p.Name).yml"
            $gitlab = "pipelines/gitlab/stages/$($p.Name).yml"
            $ado = "pipelines/azure-devops/$($p.Name).yml"
            @{ Name = $p.Name; Platform = 'GitHub'; File = $github; Scripts = $p.Scripts; Read = $p.Read; Change = $p.Change }
            @{ Name = $p.Name; Platform = 'GitLab'; File = $gitlab; Scripts = $p.Scripts; Read = $p.GitLabRead; Change = $p.GitLabChange }
            @{ Name = $p.Name; Platform = 'AzureDevOps'; File = $ado; Scripts = $p.Scripts; Read = $p.AdoRead; Change = $p.AdoChange }
        })
    $script:Changing = @($script:Files | Where-Object { $_.Change.Count -gt 0 })
    $script:ChangingNames = @($script:Pipelines | Where-Object { $_.Change.Count -gt 0 } | ForEach-Object { @{ Name = $_.Name } })
    $script:Root = $root
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Module = Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')) -Force -PassThru

    function Get-Text([string]$File) { [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $File)) }
    function Get-Yaml([string]$File) { ConvertFrom-Yaml (Get-Text $File) -Ordered }
    function Get-CodeText([string]$File) { ((Get-Text $File) -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n" }
    # every scalar of a parsed document, so a test can ask what a job or a stage says anywhere in it
    function Get-ScalarText($Node) {
        if ($Node -is [System.Collections.IDictionary]) { foreach ($k in $Node.Keys) { Get-ScalarText $Node[$k] } }
        elseif ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { Get-ScalarText $i } }
        elseif ($null -ne $Node) { [string]$Node }
    }
    function Find-Stage($Node, [string]$Name) {
        if ($Node -is [System.Collections.IDictionary]) { if ($Node.Contains('stage') -and $Node['stage'] -eq $Name) { $Node }; foreach ($k in $Node.Keys) { Find-Stage $Node[$k] $Name } }
        elseif ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { Find-Stage $i $Name } }
    }
    function Get-Param([string]$Relative) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($script:Repo, $Relative), [ref]$tokens, [ref]$errors)
        $set = @{}
        foreach ($p in $ast.ParamBlock.Parameters) {
            $v = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
            $set[$p.Name.VariablePath.UserPath] = @(if ($v) { $v.PositionalArguments | ForEach-Object { $_.Value } })
        }
        $set
    }
    # The parameters a pipeline passes: the keys of `$p = @{ ... }`, of each `Parameters = @{ ... }` and every `$p.Name = ...`.
    function Get-PassedParameter([string]$Text) {
        $keys = '(?:^|;)\s*([A-Za-z]+)\s*='
        @([regex]::Matches($Text, '\$p = @\{([^\r\n]*)\}') | ForEach-Object { [regex]::Matches($_.Groups[1].Value, $keys) | ForEach-Object { $_.Groups[1].Value } }) +
        @([regex]::Matches($Text, 'Parameters = @\{([^\}\r\n]*)\}') | ForEach-Object { [regex]::Matches($_.Groups[1].Value, $keys) | ForEach-Object { $_.Groups[1].Value } }) +
        @([regex]::Matches($Text, '\$p\.([A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    }
    function Test-Switch([string]$Relative) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($script:Repo, $Relative), [ref]$tokens, [ref]$errors)
        [bool]($ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' -and ($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }) })
    }
    $script:OperationsScript = 'scripts/deploy/08-day2-operations/task-04-cluster-operations/powershell/Invoke-ClusterOperations.ps1'
    $script:MaintenanceScript = 'scripts/deploy/08-day2-operations/task-03-node-maintenance/powershell/Invoke-NodeMaintenanceReboot.ps1'
    $script:UpdateScript = 'scripts/deploy/08-day2-operations/task-02-start-solution-update/powershell/Start-AzureLocalSolutionUpdate.ps1'
    $script:ReadActions = @('HealthCheck', 'Alerts', 'Capacity')
    $script:ChangeActions = @('MaintenanceMode', 'LiveMigrate', 'Rebalance')
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
    $script:GitHubChange = @{ 'day2-update' = 'apply'; 'day2-node-maintenance' = 'apply'; 'day2-cluster-operations' = 'apply-changes'; 'validation' = 'storage-performance' }
    $script:GitHubPlan = @{ 'day2-update' = 'plan'; 'day2-node-maintenance' = 'plan'; 'day2-cluster-operations' = 'plan-changes' }
}

Describe 'The day 2 and validation pipelines: every file' {
    It '<Platform> <Name> parses, and every script it names exists' -ForEach $script:Files {
        { Get-Yaml $File } | Should -Not -Throw
        (Get-Yaml $File) | Should -Not -BeNullOrEmpty
        $named = @([regex]::Matches((Get-Text $File), 'scripts/[A-Za-z0-9._/-]+\.ps1') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $named.Count | Should -BeGreaterThan 0
        foreach ($n in $named) { Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, $n)) | Should -BeTrue -Because "$File names $n" }
        foreach ($s in $Scripts) { $named | Should -Contain $s -Because "$File runs $s" }
    }
    It '<Platform> <Name> passes only parameters the scripts it runs have, and no credential, password or token' -ForEach $script:Files {
        $text = Get-Text $File
        $known = @{}
        $shouldProcess = $false
        foreach ($s in $Scripts) { foreach ($k in (Get-Param $s).Keys) { $known[$k] = $true }; if (Test-Switch $s) { $shouldProcess = $true } }
        if ($shouldProcess) { $known['WhatIf'] = $true; $known['Confirm'] = $true }
        $passed = @(Get-PassedParameter $text)
        $passed.Count | Should -BeGreaterThan 1
        foreach ($p in $passed) { $known.Keys | Should -Contain $p -Because "$File passes -$p" }
        foreach ($p in $passed) { $p | Should -Not -Match '(?i)credential|password|secret|token' }
        $text | Should -Not -Match '(?i)BMC_PASSWORD|IDRAC_PASSWORD|node_admin|(?<!Connect-AzAccount )-Credential\b'
        $text | Should -Match '& \$(?:env:\w+|checks\[\$name\]\.Script) @p'
    }
    It '<Platform> <Name> never commits, pushes or opens a pull request, and calls no platform API' -ForEach $script:Files {
        $code = Get-CodeText $File
        $code | Should -Not -Match '\bgit\s+(commit|push|add|checkout|merge|rebase|tag)\b'
        $code | Should -Not -Match '\bgh\s+(pr|api|issue|release)\b|az\s+(repos|devops|pipelines)|api\.github\.com|/_apis/|Invoke-RestMethod|Invoke-WebRequest|\bcurl\b'
    }
    It '<Platform> <Name> holds no GUID, password, token or key' -ForEach $script:Files {
        $text = Get-Text $File
        $text | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $text | Should -Not -Match '(?im)^\s*(password|secret|client-secret|token)\s*:\s*[^\s$<{]'
        $text | Should -Not -Match 'ghp_[A-Za-z0-9]{20,}|AccountKey=|-----BEGIN'
    }
    It '<Platform> <Name> does not let a failed step pass, and fails the run on a failed script' -ForEach $script:Files {
        $text = Get-Text $File
        $text | Should -Not -Match '(?i)continue-on-error|continueOnError|ignoreLASTEXITCODE|failOnStderr:\s*false'
        switch ($Platform) {
            'GitHub' { $text | Should -Match 'exit \$LASTEXITCODE|exit 1' }
            'GitLab' { $text | Should -Match 'exit \$LASTEXITCODE|exit 1'; $text | Should -Not -Match '(?m)^\s*allow_failure:\s*true' }
            'AzureDevOps' { $text | Should -Match 'if \(\$(LASTEXITCODE|code) -ne 0\)|if \(\$failed\.Count -gt 0\) \{ throw' }
        }
    }
    It '<Platform> <Name> publishes the report or the log even when the run failed' -ForEach $script:Files {
        $text = Get-Text $File
        switch ($Platform) {
            'GitHub' {
                foreach ($job in (Get-Yaml $File)['jobs'].Values) {
                    $upload = @($job['steps'] | Where-Object { [string]$_['uses'] -like 'actions/upload-artifact@*' })
                    $upload.Count | Should -Be 1
                    [string]$upload[0]['if'] | Should -Match 'always\(\)'
                }
            }
            'GitLab' { $text | Should -Match '(?s)artifacts:\s+when: always' }
            'AzureDevOps' { @([regex]::Matches($text, "PublishPipelineArtifact@1")).Count | Should -BeGreaterThan 0; $text | Should -Match "(?s)PublishPipelineArtifact@1.*?condition: always\(\)" }
        }
    }
    It '<Platform> <Name> only runs from a person, the API or a schedule (GitLab), and the values come from the variables of task 05' -ForEach $script:Files {
        $code = Get-CodeText $File
        if ($Platform -eq 'GitLab') { $code | Should -Match '\$CI_PIPELINE_SOURCE =~ /\^\((schedule\|)?web\|api\)\$/' }
        if ($Platform -eq 'AzureDevOps') { $code | Should -Match '(?m)^trigger: none\r?$'; $code | Should -Match '(?m)^pr: none\r?$' }
        if ($Platform -eq 'GitHub') { $code | Should -Match 'workflow_dispatch' }
        # a display text may name the file; a value may not
        @($code -split "`n" | Where-Object { $_ -notmatch '^\s*-?\s*(displayName|name|description):' }) -join "`n" | Should -Not -Match 'infrastructure\.ya?ml' -Because 'the master file is the variable of task 05, never a path in the file'
    }
}

Describe 'The approval binding of the jobs that change the cluster' {
    It 'GitHub <Name>: the changing job is in the environment of AZL_ENVIRONMENT_OPERATIONS, runs after the plan, and holds the lock of the other changes; the read-only jobs have no environment' -ForEach @($script:Files | Where-Object { $_.Platform -eq 'GitHub' -and $_.Change.Count -gt 0 }) {
        $doc = Get-Yaml $File
        foreach ($job in $Change) {
            $j = $doc['jobs'][$job]
            [string]$j['environment'] | Should -Be '${{ vars.AZL_ENVIRONMENT_OPERATIONS }}'
            [string]$j['concurrency']['group'] | Should -Match '^azure-local-day2-changes-\$\{\{ vars\.AZL_INFRASTRUCTURE_FILE \}\}$'
            $j['concurrency']['cancel-in-progress'] | Should -BeFalse
            if ($script:GitHubPlan.ContainsKey($Name)) { @($j['needs']) | Should -Contain $script:GitHubPlan[$Name] }
            else { @($j['needs']) | Should -Contain 'validate' }
        }
        foreach ($job in $Read) {
            $doc['jobs'][$job].Contains('environment') | Should -BeFalse -Because "$job only reads"
            $doc['jobs'][$job].Contains('concurrency') | Should -BeFalse -Because "$job only reads, so it need not wait for a change"
        }
        @($doc['jobs'].Keys).Count | Should -Be ($Read.Count + $Change.Count)
    }
    It 'GitHub <Name>: no read-only job passes a change, and the plan job passes -WhatIf' -ForEach @($script:Files | Where-Object { $_.Platform -eq 'GitHub' }) {
        $doc = Get-Yaml $File
        foreach ($job in $Read) {
            $run = (@($doc['jobs'][$job]['steps']) | ForEach-Object { $_['run'] }) -join "`n"
            $run | Should -Not -Match 'RunPerformanceTest|\$p\.Fix|Reboot'
            if ($script:GitHubPlan.ContainsKey($Name) -and $script:GitHubPlan[$Name] -eq $job) { $run | Should -Match 'WhatIf = \$true' }
        }
        foreach ($job in $Change) {
            $run = (@($doc['jobs'][$job]['steps']) | ForEach-Object { $_['run'] }) -join "`n"
            $run | Should -Not -Match 'WhatIf'
        }
    }
    It 'GitHub <Name>: no run step takes an input in its text (the inputs reach the script through env, so a value cannot become code)' -ForEach @($script:Files | Where-Object { $_.Platform -eq 'GitHub' }) {
        foreach ($job in (Get-Yaml $File)['jobs'].Values) {
            foreach ($step in @($job['steps'])) { if ($step.Contains('run')) { [string]$step['run'] | Should -Not -Match '\$\{\{' } }
        }
    }
    It 'GitLab <Name>: the changing job is manual, cannot fail quietly, is in the protected environment, runs after the plan and holds the resource group of the other changes; the read-only jobs have none of that' -ForEach @($script:Files | Where-Object { $_.Platform -eq 'GitLab' -and $_.Change.Count -gt 0 }) {
        $doc = Get-Yaml $File
        foreach ($job in $Change) {
            $j = $doc[$job]
            @($j['rules'])[0]['when'] | Should -Be 'manual'
            @($j['rules'])[0]['allow_failure'] | Should -BeFalse
            [string]$j['environment']['name'] | Should -Be '$AZL_ENVIRONMENT_OPERATIONS'
            [string]$j['resource_group'] | Should -Be 'azure-local-day2-changes'
            @($j['needs']).Count | Should -Be 1
            $Read | Should -Contain @($j['needs'])[0] -Because 'the change needs a read-only job first'
        }
        foreach ($job in $Read) {
            $doc[$job].Contains('environment') | Should -BeFalse
            $doc[$job].Contains('resource_group') | Should -BeFalse
            $doc[$job]['rules'] | ForEach-Object { $_.Contains('when') | Should -BeFalse }
        }
    }
    It 'GitLab <Name>: the plan job passes -WhatIf and the changing job does not' -ForEach @($script:Files | Where-Object { $_.Platform -eq 'GitLab' -and $_.Name -in 'day2-update', 'day2-node-maintenance', 'day2-cluster-operations' }) {
        $doc = Get-Yaml $File
        $plan = if ($Name -eq 'day2-cluster-operations') { 'day2-cluster-operations-plan' } else { "$Name-plan" }
        $apply = "$Name-apply"
        (Get-ScalarText $doc[$plan] | Out-String) | Should -Match 'WhatIf = \$true'
        (Get-ScalarText $doc[$apply] | Out-String) | Should -Not -Match 'WhatIf'
    }
    It 'Azure DevOps <Name>: the changing stage is a deployment job in an environment the queuer cannot choose, with the lock, after the read-only stage; the read-only stages have no environment' -ForEach @($script:Files | Where-Object { $_.Platform -eq 'AzureDevOps' -and $_.Change.Count -gt 0 }) {
        $text = Get-Text $File
        $doc = Get-Yaml $File
        # the environment is a variable of a YAML file (compile time), never a run parameter
        $text | Should -Match '(?m)^\s+environment: \$\{\{ variables\.AZL_ENVIRONMENT_OPERATIONS \}\}\r?$'
        $text | Should -Not -Match '(?m)^\s+environment: \$\{\{ parameters\.'
        $text | Should -Not -MatchExactly 'approval_environment|\bapprovalEnvironment\b'
        $text | Should -Match '(?m)^\s+- template: variables/approval-environments\.yml\r?$'
        @([regex]::Matches($text, '(?m)^\s+environment:')).Count | Should -Be 1
        $text | Should -Match '(?m)^lockBehavior: sequential\r?$'
        $text | Should -Match '(?m)^# lockBehavior does not queue runs by itself\.'
        foreach ($stage in $Change) {
            $s = @(Find-Stage $doc $stage)
            $s.Count | Should -Be 1 -Because $stage
            [string]$s[0]['lockBehavior'] | Should -Be 'sequential'
            $s[0]['jobs'][0].Contains('deployment') | Should -BeTrue
            [string]$s[0]['jobs'][0]['environment'] | Should -Be '${{ variables.AZL_ENVIRONMENT_OPERATIONS }}'
            [string]$s[0]['dependsOn'] | Should -BeIn @('Plan', 'Validate')
        }
        foreach ($stage in $Read) {
            $s = @(Find-Stage $doc $stage)
            $s.Count | Should -Be 1 -Because $stage
            $s[0]['jobs'][0].Contains('job') | Should -BeTrue
            $s[0]['jobs'][0].Contains('environment') | Should -BeFalse
        }
        $names = @($doc['parameters'] | ForEach-Object { [string]$_['name'] })
        $names | Should -Not -Contain 'approval_environment'
        $names | Should -Not -Contain 'environment'
    }
    It 'Azure DevOps <Name>: while the environment is empty the stage ApprovalEnvironmentNotSet fails and the change stage does not exist' -ForEach @($script:Files | Where-Object { $_.Platform -eq 'AzureDevOps' -and $_.Change.Count -gt 0 }) {
        $text = Get-Text $File
        $text | Should -Match "(?m)^\s+- \`$\{\{ if and\(.*, ne\(variables\.AZL_ENVIRONMENT_OPERATIONS, ''\)\) \}\}:\r?$"
        $text | Should -Match "(?m)^\s+- \`$\{\{ if and\(.*, eq\(variables\.AZL_ENVIRONMENT_OPERATIONS, ''\)\) \}\}:\r?$"
        $guard = ($text -split '- stage: ApprovalEnvironmentNotSet')[1] -split '(?m)^\s+# -{20,}' | Select-Object -First 1
        $guard | Should -Match 'approval-environments\.yml'
        $guard | Should -Match '(?m)^\s+exit 1\r?$'
        $guard | Should -Not -Match '\$p\.|RunPerformanceTest|AzurePowerShell@|AzureCLI@|checkout'
        $guard | Should -Match '(?m)^\s+dependsOn: (Plan|Validate)\r?$'
    }
    It 'Azure DevOps: the variables template defines the environment, empty in the toolkit' {
        $template = Get-Yaml 'pipelines/azure-devops/variables/approval-environments.yml'
        $defined = @($template['variables'] | Where-Object { $_['name'] -eq 'AZL_ENVIRONMENT_OPERATIONS' })
        $defined.Count | Should -Be 1
        [string]$defined[0]['value'] | Should -Be '' -Because 'no value of a deployment is written in the toolkit'
    }
    It 'Azure DevOps: the run forms are exactly the parameters listed, and none of them names the approval environment' {
        $expected = @{
            'day2-check-updates'      = @('infrastructure_file', 'source', 'agent_pool', 'service_connection', 'variable_group')
            'day2-update'             = @('infrastructure_file', 'action', 'update_mode', 'agent_pool', 'variable_group')
            'day2-node-maintenance'   = @('infrastructure_file', 'node', 'action', 'agent_pool', 'service_connection', 'variable_group')
            'day2-cluster-operations' = @('infrastructure_file', 'action', 'node', 'enable', 'agent_pool', 'variable_group')
            'validation'              = @('infrastructure_file', 'run_performance_test', 'agent_pool', 'variable_group')
        }
        foreach ($name in $expected.Keys) {
            $names = @((Get-Yaml "pipelines/azure-devops/$name.yml")['parameters'] | ForEach-Object { [string]$_['name'] })
            $names | Should -Be $expected[$name] -Because $name
        }
    }
    It 'the day 2 environment is a key of the master file, set by task 05 for GitHub, GitLab and Azure DevOps, and written in a YAML file on Azure DevOps (compile time)' {
        $entry = @($script:Registry | Where-Object Path -EQ 'devops.pipelines.environments.operations')
        $entry.Count | Should -Be 1
        $entry[0].Node['pattern'] | Should -Be '^[A-Za-z0-9][A-Za-z0-9._-]*$'
        $variable = @(& $script:Module { $script:AzlPipelineVariable } | Where-Object Name -EQ 'AZL_ENVIRONMENT_OPERATIONS')
        $variable.Count | Should -Be 1
        $variable[0].Key | Should -Be 'devops.pipelines.environments.operations'
        @($variable[0].Platforms) | Should -Be @('github', 'gitlab', 'azure_devops')
        $variable[0].AzureDevOps | Should -Be 'CompileTime'
        (Get-Text 'scripts/common/cicd-infra/AzlCicdInfra.psm1') | Should -Match "(?m)^\s+operations\s+= \[string\]\(Get-AzlValue \`$pipelineEnvironments 'operations'\)"
    }
    It 'task 05 sets the environment from the key, and refuses one that has no approval' {
        $infra = { param($approval) [ordered]@{
                devops = [ordered]@{
                    platform     = 'github'
                    environments = @([ordered]@{ name = 'iic-day2'; approval_required = $approval })
                    pipelines    = [ordered]@{ environments = [ordered]@{ operations = 'iic-day2' } }
                }
            } }
        $settings = ConvertTo-AzlCicdSetting -Infrastructure (& $infra $true)
        $set = @(Get-AzlCicdPipelineInput -Settings $settings | Where-Object Name -EQ 'AZL_ENVIRONMENT_OPERATIONS')
        $set.Count | Should -Be 1
        $set[0].Value | Should -Be 'iic-day2'
        $set[0].Key | Should -Be 'devops.pipelines.environments.operations'
        $without = ConvertTo-AzlCicdSetting -Infrastructure (& $infra $false)
        { Get-AzlCicdPipelineInput -Settings $without } | Should -Throw '*approval_required*'
    }
}

Describe 'Plan first, one change at a time, one node at a time' {
    It 'GitLab <Name>: the changing jobs of the day 2 pipelines share one resource group, and so do GitHub (one concurrency group) and Azure DevOps (one environment)' -ForEach $script:ChangingNames {
        (Get-Text "pipelines/gitlab/stages/$Name.yml") | Should -Match '(?m)^\s+resource_group: azure-local-day2-changes\r?$'
        (Get-Text "pipelines/github-actions/$Name.yml") | Should -Match 'group: azure-local-day2-changes-\$\{\{ vars\.AZL_INFRASTRUCTURE_FILE \}\}'
        (Get-Text "pipelines/azure-devops/$Name.yml") | Should -Match 'variables\.AZL_ENVIRONMENT_OPERATIONS'
    }
    It 'the node maintenance takes exactly one node, checks it against the master file in the plan and in the apply, and never loops over nodes' -ForEach @($script:Files | Where-Object { $_.Name -eq 'day2-node-maintenance' }) {
        $text = Get-Text $File
        $code = Get-CodeText $File
        @([regex]::Matches($code, 'RequireNodeInFile = \$true')).Count | Should -Be 2
        $code | Should -Match 'TargetNode = \$env:MAINTENANCE_NODE'
        $code | Should -Not -Match '(?i)matrix:|foreach \(\$node|ForEach-Object -Parallel|-Parallel|Start-ThreadJob|Start-Job|strategy:\s*\r?\n\s+matrix|\bnodes\b\s*:\s*\['
        $text | Should -Match '(?i)exactly one node'
        switch ($Platform) {
            'GitHub' { ((Get-Yaml $File)['on'] ?? (Get-Yaml $File)[$true])['workflow_dispatch']['inputs']['node']['required'] | Should -BeTrue }
            'AzureDevOps' { $p = @((Get-Yaml $File)['parameters'] | Where-Object { $_['name'] -eq 'node' }); $p.Count | Should -Be 1; $p[0].Contains('default') | Should -BeFalse; $p[0]['type'] | Should -Be 'string' }
            'GitLab' { $code | Should -Match 'MAINTENANCE_NODE is empty' }
        }
    }
    It 'the cluster operations pass -RequireNodeInFile with a node, in the plan and in the apply, and read-only actions pass no node' -ForEach @($script:Files | Where-Object { $_.Name -eq 'day2-cluster-operations' }) {
        $code = Get-CodeText $File
        @([regex]::Matches($code, '\$p\.RequireNodeInFile = \$true')).Count | Should -Be 2
        @([regex]::Matches($code, '\$p\.NodeName = \$env:OPERATIONS_NODE')).Count | Should -Be 2
    }
    It 'the actions of the cluster operations are the ValidateSet of the script, split into the actions that only read and the ones that change the cluster' -ForEach @($script:Files | Where-Object { $_.Name -eq 'day2-cluster-operations' }) {
        $set = (Get-Param $script:OperationsScript)['Action']
        @($script:ReadActions + $script:ChangeActions | Sort-Object) | Should -Be @($set | Sort-Object)
        $text = Get-Text $File
        foreach ($a in $set) { $text | Should -Match "\b$a\b" }
        switch ($Platform) {
            'GitHub' {
                $doc = Get-Yaml $File
                $on = $doc['on'] ?? $doc[$true]
                @($on['workflow_dispatch']['inputs']['action']['options']) | Should -Be @($script:ReadActions + $script:ChangeActions)
                [string]$doc['jobs']['read-only']['if'] | Should -Match ([regex]::Escape('["HealthCheck","Alerts","Capacity"]'))
                [string]$doc['jobs']['plan-changes']['if'] | Should -Match ([regex]::Escape('["MaintenanceMode","LiveMigrate","Rebalance"]'))
                [string]$doc['jobs']['apply-changes']['if'] | Should -Match ([regex]::Escape('["MaintenanceMode","LiveMigrate","Rebalance"]'))
            }
            'GitLab' {
                $doc = Get-Yaml $File
                @($doc['variables']['OPERATIONS_ACTION']['options']) | Should -Be @($script:ReadActions + $script:ChangeActions)
                @($doc['day2-cluster-operations-read']['rules'])[0]['if'] | Should -Match ([regex]::Escape('(HealthCheck|Alerts|Capacity)'))
                @($doc['day2-cluster-operations-plan']['rules'])[0]['if'] | Should -Match ([regex]::Escape('(MaintenanceMode|LiveMigrate|Rebalance)'))
                @($doc['day2-cluster-operations-apply']['rules'])[0]['if'] | Should -Match ([regex]::Escape('(MaintenanceMode|LiveMigrate|Rebalance)'))
            }
            'AzureDevOps' {
                $text | Should -Match "(?m)^\s+- \`$\{\{ if in\(parameters\.action, 'HealthCheck', 'Alerts', 'Capacity'\) \}\}:\r?$"
                $text | Should -Match "(?m)^\s+- \`$\{\{ if in\(parameters\.action, 'MaintenanceMode', 'LiveMigrate', 'Rebalance'\) \}\}:\r?$"
                @((Get-Yaml $File)['parameters'] | Where-Object { $_['name'] -eq 'action' })[0]['values'] | Should -Be @($script:ReadActions + $script:ChangeActions)
            }
        }
    }
    It 'the update takes the two modes and -PrepareOnly of the script, and PrepareOnly or Install need the approval while Plan stops after the read-only job' -ForEach @($script:Files | Where-Object { $_.Name -eq 'day2-update' }) {
        $params = Get-Param $script:UpdateScript
        $params.Keys | Should -Contain 'PrepareOnly'
        @($params['Mode']) | Should -Be @('AfterDeployment', 'OnDemand')
        $text = Get-Text $File
        $text | Should -Match '\$p\.PrepareOnly = \$true'
        $text | Should -Match 'PrepareOnly'
        switch ($Platform) {
            'GitHub' { [string](Get-Yaml $File)['jobs']['apply']['if'] | Should -Match "inputs\.action == 'PrepareOnly' \|\| inputs\.action == 'Install'" }
            'GitLab' { @((Get-Yaml $File)['day2-update-apply']['rules'])[0]['if'] | Should -Match '\$DAY2UPDATE_ACTION == "PrepareOnly" \|\| \$DAY2UPDATE_ACTION == "Install"' }
            'AzureDevOps' { $text | Should -Match "(?m)^\s+- \`$\{\{ if and\(ne\(parameters\.action, 'Plan'\), ne\(variables\.AZL_ENVIRONMENT_OPERATIONS, ''\)\) \}\}:\r?$" }
        }
    }
    It 'the scripts have the switch the pipelines pass to check a node against the file' {
        (Get-Param $script:MaintenanceScript).Keys | Should -Contain 'RequireNodeInFile'
        (Get-Param $script:OperationsScript).Keys | Should -Contain 'RequireNodeInFile'
        (Get-Param $script:MaintenanceScript).Keys | Should -Contain 'ResumeOnly'
    }
}

Describe 'The validation pipelines: the storage performance test puts load on the cluster' {
    It '<Platform> keeps -RunPerformanceTest out of the read-only job and says why it is approved' -ForEach @($script:Files | Where-Object { $_.Name -eq 'validation' }) {
        $text = Get-Text $File
        $text | Should -Match 'generate I/O on the cluster'
        $text | Should -Match 'RunPerformanceTest'
        @([regex]::Matches((Get-CodeText $File), 'RunPerformanceTest = \$true')).Count | Should -Be 1
        (Get-Param 'scripts/deploy/07-validation-handover/task-04-storage-performance-validation/powershell/Test-StoragePerformance.ps1').Keys | Should -Contain 'RunPerformanceTest'
        switch ($Platform) {
            'GitHub' {
                $doc = Get-Yaml $File
                (@($doc['jobs']['validate']['steps']) | ForEach-Object { $_['run'] }) -join "`n" | Should -Not -Match 'RunPerformanceTest'
                (@($doc['jobs']['storage-performance']['steps']) | ForEach-Object { $_['run'] }) -join "`n" | Should -Match 'RunPerformanceTest'
                [string]$doc['jobs']['storage-performance']['if'] | Should -Match 'inputs\.run_performance_test'
            }
            'GitLab' {
                $doc = Get-Yaml $File
                (Get-ScalarText $doc['validation-read-only'] | Out-String) | Should -Not -Match 'RunPerformanceTest'
                (Get-ScalarText $doc['validation-storage-performance'] | Out-String) | Should -Match 'RunPerformanceTest'
                @($doc['validation-storage-performance']['rules'])[0]['if'] | Should -Match '\$VALIDATION_RUN_PERFORMANCE_TEST == "true"'
            }
            'AzureDevOps' {
                $doc = Get-Yaml $File
                (Get-ScalarText (@(Find-Stage $doc 'Validate'))[0] | Out-String) | Should -Not -Match 'RunPerformanceTest'
                (Get-ScalarText (@(Find-Stage $doc 'StoragePerformance'))[0] | Out-String) | Should -Match 'RunPerformanceTest'
                $text | Should -Match "(?m)^\s+- \`$\{\{ if and\(parameters\.run_performance_test, ne\(variables\.AZL_ENVIRONMENT_OPERATIONS, ''\)\) \}\}:\r?$"
            }
        }
    }
    It '<Platform> runs the four scripts one after the other, runs the later ones when an earlier one fails, and fails the run at the end' -ForEach @($script:Files | Where-Object { $_.Name -eq 'validation' }) {
        $code = Get-CodeText $File
        foreach ($k in 'ClusterHealth', 'ArcConnectivity', 'Network', 'Storage') { $code | Should -Match "(?m)^\s+$k = @\{ Script = \`$env:\w+; Parameters = @\{ InfrastructureFile = \`$env:\w+; " }
        $code | Should -Match 'if \(\$LASTEXITCODE -ne 0\) \{ \$failed \+= '
        $code | Should -Match '\$failed\.Count -gt 0'
        # the read-only check of the storage script never passes the load test
        $code | Should -Not -Match '(?m)^\s+Storage = .*RunPerformanceTest'
        # each script gets its own report folder
        foreach ($folder in 'cluster-health', 'arc-connectivity', 'network', 'storage') { $code | Should -Match "OutputPath = `"\`$dir/$folder`"" }
        $code | Should -Match "OutputFormat = ['""]JSON['""]"
    }
    It 'the parameters of each validation script entry exist in that script' -ForEach @($script:Files | Where-Object { $_.Name -eq 'validation' }) {
        $map = @{
            ClusterHealth   = 'scripts/deploy/07-validation-handover/task-01-cluster-health-validation/powershell/Test-AzureLocalClusterHealth.ps1'
            ArcConnectivity = 'scripts/deploy/07-validation-handover/task-02-arc-connectivity-validation/powershell/Test-ArcConnectivity.ps1'
            Network         = 'scripts/deploy/07-validation-handover/task-03-network-configuration-validation/powershell/Test-NetworkConfiguration.ps1'
            Storage         = 'scripts/deploy/07-validation-handover/task-04-storage-performance-validation/powershell/Test-StoragePerformance.ps1'
        }
        foreach ($m in [regex]::Matches((Get-Text $File), '(?m)^\s+(ClusterHealth|ArcConnectivity|Network|Storage) = @\{ Script = \$env:\w+; Parameters = @\{([^\}]*)\}')) {
            $known = (Get-Param $map[$m.Groups[1].Value]).Keys
            foreach ($k in [regex]::Matches($m.Groups[2].Value, '(?:^|;)\s*([A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value }) { $known | Should -Contain $k -Because "$($m.Groups[1].Value) is given -$k" }
        }
    }
}

Describe 'Check for updates: read only, on a schedule, and the run fails when the cluster needs attention' {
    It '<Platform> has no approval, no change and no -WhatIf, and runs the Azure view and the cluster view as two separate paths' -ForEach @($script:Files | Where-Object { $_.Name -eq 'day2-check-updates' }) {
        $text = Get-Text $File
        $code = Get-CodeText $File
        $code | Should -Not -Match '(?m)^\s+environment:'
        $code | Should -Not -Match 'Start-AzureLocalSolutionUpdate|WhatIf|\$p\.Prepare'
        $text | Should -Match 'azurecli/Get-AvailableSolutionUpdate\.azcli\.ps1'
        $text | Should -Match 'powershell/Get-AvailableSolutionUpdate\.ps1'
        $text | Should -Match 'devops\.pipelines\.schedules\.check_for_updates'
        $text | Should -Match '(?i)exit code 1'
    }
    It 'GitHub: the schedule is the registry default of devops.pipelines.schedules.check_for_updates, and a scheduled run takes the Azure view' {
        $default = [string]@($script:Registry | Where-Object Path -EQ 'devops.pipelines.schedules.check_for_updates')[0].Node['default']
        $default | Should -Be '17 4 * * *'
        $doc = Get-Yaml 'pipelines/github-actions/day2-check-updates.yml'
        $on = $doc['on'] ?? $doc[$true]
        @($on['schedule']).Count | Should -Be 1
        [string]@($on['schedule'])[0]['cron'] | Should -Be $default
        $on['workflow_dispatch']['inputs']['source'].Contains('default') | Should -BeFalse
        @($on['workflow_dispatch']['inputs']['source']['options'])[0] | Should -Be 'azure'
        [string]$doc['jobs']['check-azure']['if'] | Should -Be "`${{ inputs.source != 'cluster' }}"
        [string]$doc['jobs']['check-cluster']['if'] | Should -Be "`${{ inputs.source == 'cluster' }}"
        # only the Azure job signs in, with the method of devops.authentication.method
        $logins = @(@($doc['jobs']['check-azure']['steps']) | Where-Object { [string]$_['uses'] -like 'azure/login@*' })
        $logins.Count | Should -Be 2
        @(@($doc['jobs']['check-cluster']['steps']) | Where-Object { [string]$_['uses'] -like 'azure/login@*' }).Count | Should -Be 0
    }
    It 'GitLab: the schedule is a project setting, so the file has no cron and the schedule source takes the Azure view' {
        $text = Get-Text 'pipelines/gitlab/stages/day2-check-updates.yml'
        (Get-CodeText 'pipelines/gitlab/stages/day2-check-updates.yml') | Should -Not -Match '(?m)^\s*(cron|schedules?):|\d+ \d+ \* \* \*'
        $text | Should -Match 'CI/CD > Schedules'
        $doc = Get-Yaml 'pipelines/gitlab/stages/day2-check-updates.yml'
        $doc['variables']['UPDATECHECK_SOURCE']['value'] | Should -Be 'azure'
        @($doc['day2-check-updates-azure']['rules'])[0]['if'] | Should -Match '\^\(schedule\|web\|api\)\$'
        $doc['day2-check-updates-azure']['id_tokens'].Contains('ARM_OIDC_TOKEN') | Should -BeTrue
        $doc['day2-check-updates-cluster'].Contains('id_tokens') | Should -BeFalse
    }
    It 'Azure DevOps: a scheduled run cannot supply the run parameters, so the sample carries the block as a comment with the registry default, and no active schedule' {
        $default = [string]@($script:Registry | Where-Object Path -EQ 'devops.pipelines.schedules.check_for_updates')[0].Node['default']
        $file = 'pipelines/azure-devops/day2-check-updates.yml'
        (Get-CodeText $file) | Should -Not -Match '(?m)^schedules:'
        (Get-Text $file) | Should -Match "(?m)^#\s+- cron: '$([regex]::Escape($default))'\r?$"
        (Get-Text $file) | Should -Match '(?m)^#\s+always: true\r?$'
        $doc = Get-Yaml $file
        $doc.Contains('schedules') | Should -BeFalse
        @($doc['parameters'] | Where-Object { $_['name'] -eq 'source' })[0]['default'] | Should -Be 'azure'
        $doc['trigger'] | Should -Be 'none'
    }
    It 'task 05 knows the schedule: the module default is the registry default, the key is a leaf of the master file, and an empty value means no schedule' {
        $entry = @($script:Registry | Where-Object Path -EQ 'devops.pipelines.schedules.check_for_updates')
        $entry.Count | Should -Be 1
        $pattern = [string]$entry[0].Node['pattern']
        '17 4 * * *' | Should -Match $pattern
        '' | Should -Match $pattern
        '17 4 * *' | Should -Not -Match $pattern
        (& $script:Module { $script:AzlPipelineDefault['devops.pipelines.schedules.check_for_updates'] }) | Should -Be ([string]$entry[0].Node['default'])
        $settings = ConvertTo-AzlCicdSetting -Infrastructure ([ordered]@{ devops = [ordered]@{ platform = 'github' } })
        $settings.Pipelines.Schedules['check_for_updates'] | Should -Be '17 4 * * *'
        $own = ConvertTo-AzlCicdSetting -Infrastructure ([ordered]@{ devops = [ordered]@{ platform = 'github'; pipelines = [ordered]@{ schedules = [ordered]@{ check_for_updates = '5 3 * * 1' } } } })
        $own.Pipelines.Schedules['check_for_updates'] | Should -Be '5 3 * * 1'
        (Get-Text 'scripts/common/cicd-infra/AzlCicdInfra.psm1') | Should -Match "'Pipeline schedule' 'devops\.pipelines\.schedules\.check_for_updates'"
    }
}

Describe 'The pipeline guide lists every day 2 pipeline, once per platform' {
    It 'pipelines/README.md names <File>' -ForEach $script:Files {
        $readme = Get-Text 'pipelines/README.md'
        $leaf = ($File -split '/')[-1]
        $readme | Should -Match ([regex]::Escape($leaf))
    }
}
