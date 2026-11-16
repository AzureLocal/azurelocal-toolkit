#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The discovery pipelines and the pre-cluster verification pipelines (GitHub Actions, GitLab CI, Azure DevOps) parse, call the one entry point
# with parameters that exist, take no BMC or node credential (the login is a secret reference of the master file, read at run time), publish
# the report as an artifact even when the run fails, fail the run on a failed step or a failed gate, never commit or push, and keep the gate's
# two changes (the resource provider registration and the Environment Checker on the nodes) behind the approval. Nothing is run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines/DiscoveryAndGatePipelines.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    # The repository root at discovery time: BeforeAll has not run yet, so a -ForEach list must not use $script:Repo.
    $script:RepoAtDiscovery = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:GitHubPipelineFiles = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:RepoAtDiscovery, 'pipelines', 'github-actions')) -Filter '*.yml' | ForEach-Object { @{ File = 'pipelines/github-actions/' + $_.Name } })
    $script:Pipelines = @(
        @{ Name = 'discovery'; Platform = 'GitHub'; File = 'pipelines/github-actions/discovery.yml' }
        @{ Name = 'discovery'; Platform = 'GitLab'; File = 'pipelines/gitlab/stages/discovery.yml' }
        @{ Name = 'discovery'; Platform = 'AzureDevOps'; File = 'pipelines/azure-devops/discovery.yml' }
        @{ Name = 'pre-cluster-verification'; Platform = 'GitHub'; File = 'pipelines/github-actions/pre-cluster-verification.yml' }
        @{ Name = 'pre-cluster-verification'; Platform = 'GitLab'; File = 'pipelines/gitlab/stages/pre-cluster-verification.yml' }
        @{ Name = 'pre-cluster-verification'; Platform = 'AzureDevOps'; File = 'pipelines/azure-devops/pre-cluster-verification.yml' }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    function Get-Text([string]$File) { [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $File)) }
    function Get-Yaml([string]$File) { ConvertFrom-Yaml (Get-Text $File) -Ordered }
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
    # The parameters a pipeline passes: the keys of `$p = @{ ... }` and every `$p.Name = ...`.
    function Get-PassedParameter([string]$Text) {
        @([regex]::Matches($Text, '\$p = @\{([^\r\n]*)\}') | ForEach-Object { [regex]::Matches($_.Groups[1].Value, '(?:^|;)\s*([A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value } }) +
        @([regex]::Matches($Text, '\$p\.([A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    }
    $script:DiscoveryScript = 'scripts/common/discovery/Invoke-AzlDiscoveryRun.ps1'
    $script:GateScript = 'scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalPreClusterVerification.ps1'
    $script:DiscoveryParam = Get-Param $script:DiscoveryScript
    $script:GateParam = Get-Param $script:GateScript
}

Describe 'The discovery and pre-cluster verification pipelines' {
    It '<Platform> <Name> parses and its entry point exists' -ForEach $script:Pipelines {
        { Get-Yaml $File } | Should -Not -Throw
        (Get-Yaml $File) | Should -Not -BeNullOrEmpty
        $entry = if ($Name -eq 'discovery') { $script:DiscoveryScript } else { $script:GateScript }
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, $entry)) | Should -BeTrue
        (Get-Text $File) | Should -Match ([regex]::Escape($entry))
    }
    It '<Platform> <Name> passes only parameters its entry point has, and no credential, password or token' -ForEach $script:Pipelines {
        $text = Get-Text $File
        $known = if ($Name -eq 'discovery') { $script:DiscoveryParam } else { $script:GateParam }
        $passed = @(Get-PassedParameter $text)
        $passed.Count | Should -BeGreaterThan 2
        foreach ($p in $passed) { $known.Keys | Should -Contain $p -Because "$File passes -$p" }
        foreach ($p in $passed) { $p | Should -Not -Match '(?i)credential|password|secret|token' }
        # the sign-in of the pipeline identity (a service principal) is not a BMC or node credential: only the entry points' parameters matter here
        $text | Should -Not -Match '(?i)BMC_PASSWORD|IDRAC_PASSWORD|bmc_user|bmc_pass|node_admin'
        $text | Should -Match '& \$env:(DISCOVERY_SCRIPT|GATE_SCRIPT|PRECLUSTER_SCRIPT) @p'
    }
    It '<Platform> <Name> never commits, pushes or opens a pull request, and calls no platform API' -ForEach $script:Pipelines {
        $code = ((Get-Text $File) -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
        $code | Should -Not -Match '\bgit\s+(commit|push|add|checkout|merge|rebase|tag)\b'
        $code | Should -Not -Match '\bgh\s+(pr|api|issue|release)\b|az\s+(repos|devops|pipelines)|api\.github\.com|/_apis/|Invoke-RestMethod|Invoke-WebRequest|\bcurl\b'
    }
    It '<Platform> <Name> holds no GUID, password, token or key' -ForEach $script:Pipelines {
        $text = Get-Text $File
        $text | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $text | Should -Not -Match '(?im)^\s*(password|secret|client-secret|token)\s*:\s*[^\s$<{]'
        $text | Should -Not -Match 'ghp_[A-Za-z0-9]{20,}|AccountKey=|-----BEGIN'
    }
    It '<Platform> <Name> does not let a failed step pass' -ForEach $script:Pipelines {
        $text = Get-Text $File
        $text | Should -Not -Match '(?i)continue-on-error|continueOnError|ignoreLASTEXITCODE|failOnStderr:\s*false'
        switch ($Platform) {
            'GitHub' { $text | Should -Match 'exit \$LASTEXITCODE|exit \$code' }
            'GitLab' {
                $text | Should -Match 'exit \$(LASTEXITCODE|code)'
                $text | Should -Not -Match '(?m)^\s*allow_failure:\s*true'
            }
            'AzureDevOps' { $text | Should -Match 'if \(\$(LASTEXITCODE|code) -ne 0\) \{ throw' }
        }
    }
    It '<Platform> <Name> publishes the report as an artifact even when the run failed' -ForEach $script:Pipelines {
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
            'AzureDevOps' { $text | Should -Match "(?s)PublishPipelineArtifact@1.*?condition: always\(\)" }
        }
    }
}

Describe 'The discovery pipelines' {
    It '<Platform> maps its scope to the steps of the entry point, and only to steps it has' -ForEach @($script:Pipelines | Where-Object { $_.Name -eq 'discovery' }) {
        $text = Get-Text $File
        $named = @([regex]::Matches($text, "['""](HardwareInventory|DellDiscovery|AzureTenant|ActiveDirectory)['""]") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $named | Should -Be @('ActiveDirectory', 'AzureTenant', 'DellDiscovery', 'HardwareInventory')
        foreach ($n in $named) { $script:DiscoveryParam['Scope'] | Should -Contain $n }
    }
    It '<Platform> asks for no approval: a discovery run is read only, and the write-back is an artifact, never a commit' -ForEach @($script:Pipelines | Where-Object { $_.Name -eq 'discovery' }) {
        $text = Get-Text $File
        $code = ($text -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
        $code | Should -Not -Match '(?m)^\s*environment:'
        $code | Should -Not -Match '(?i)-Apply\b|UpdateInfrastructure|Update-InfrastructureYml'
        $text | Should -Match '(?i)COPY of the master file'
    }
    It 'the entry point writes the write-back into a copy and never takes -UpdateInfrastructure' {
        $script:DiscoveryParam.Keys | Should -Not -Contain 'UpdateInfrastructure'
        $script:DiscoveryParam.Keys | Should -Contain 'WriteBack'
    }
}

Describe 'The pre-cluster verification pipelines' {
    It 'GitHub: the read-only job has no environment and runs neither -Fix nor -InstallEnvironmentChecker; the job that does is approved' {
        $doc = Get-Yaml 'pipelines/github-actions/pre-cluster-verification.yml'
        $read = $doc['jobs']['verify']
        $read.Contains('environment') | Should -BeFalse
        (($read['steps'] | ForEach-Object { $_['run'] }) -join "`n") | Should -Not -Match 'Fix|InstallEnvironmentChecker'
        $changes = $doc['jobs']['verify-with-changes']
        [string]$changes['environment'] | Should -Be '${{ vars.AZL_ENVIRONMENT_ARM_DEPLOYMENT }}'
        (($changes['steps'] | ForEach-Object { $_['run'] }) -join "`n") | Should -Match '\$p\.Fix = \$true'
        (($changes['steps'] | ForEach-Object { $_['run'] }) -join "`n") | Should -Match '\$p\.InstallEnvironmentChecker = \$true'
        # exactly one of the two jobs runs
        [string]$read['if'] | Should -Match '!inputs\.fix && !inputs\.install_environment_checker'
        [string]$changes['if'] | Should -Match 'inputs\.fix \|\| inputs\.install_environment_checker'
    }
    It 'GitLab: the job with changes is manual, in the protected environment, and cannot fail quietly' {
        $doc = Get-Yaml 'pipelines/gitlab/stages/pre-cluster-verification.yml'
        $job = $doc['pre-cluster-verify-changes']
        @($job['rules'])[0]['when'] | Should -Be 'manual'
        @($job['rules'])[0]['allow_failure'] | Should -BeFalse
        [string]$job['environment']['name'] | Should -Be '$AZL_ENVIRONMENT_ARM_DEPLOYMENT'
        $doc['pre-cluster-verify'].Contains('environment') | Should -BeFalse
        # the changes are only passed when the manual job sets PRECLUSTER_CHANGES
        $doc['pre-cluster-verify']['variables']['PRECLUSTER_CHANGES'] | Should -Be 'false'
        $doc['pre-cluster-verify-changes']['variables']['PRECLUSTER_CHANGES'] | Should -Be 'true'
        (Get-Text 'pipelines/gitlab/stages/pre-cluster-verification.yml') | Should -Match '(?s)if \(\$env:PRECLUSTER_CHANGES -eq "true"\) \{\s+if \(\$env:PRECLUSTER_FIX -eq "true"\) \{ \$p\.Fix = \$true \}'
    }
    It 'Azure DevOps: the stage with changes is a deployment job in an environment the queuer cannot choose, and the read-only stage has none' {
        $text = Get-Text 'pipelines/azure-devops/pre-cluster-verification.yml'
        # the environment is a variable of a YAML file (compile time), never a run parameter
        $text | Should -Match '(?m)^\s+environment: \$\{\{ variables\.AZL_ENVIRONMENT_ARM_DEPLOYMENT \}\}\r?$'
        $text | Should -Not -Match 'approval_environment'
        $text | Should -Not -Match '(?m)^\s+environment: \$\{\{ parameters\.'
        $text | Should -Match '(?m)^\s+- template: variables/approval-environments\.yml\r?$'
        @([regex]::Matches($text, '(?m)^\s+environment:')).Count | Should -Be 1
        $names = @((Get-Yaml 'pipelines/azure-devops/pre-cluster-verification.yml')['parameters'] | ForEach-Object { $_['name'] })
        $names | Should -Not -Contain 'approval_environment'
        # Fix and InstallEnvironmentChecker are passed in the second stage only
        $parts = $text -split '- stage: VerifyWithChanges'
        $parts.Count | Should -Be 2
        $parts[0] | Should -Not -Match '\$p\.Fix = \$true|\$p\.InstallEnvironmentChecker = \$true'
        $parts[1] | Should -Match '\$p\.Fix = \$true'
        $parts[1] | Should -Match '\$p\.InstallEnvironmentChecker = \$true'
        $text | Should -Match 'if and\(not\(parameters\.fix\), not\(parameters\.install_environment_checker\)\)'
        $text | Should -Match 'if and\(or\(parameters\.fix, parameters\.install_environment_checker\)'
    }
    It 'Azure DevOps: the variables template defines the environment, empty in the toolkit, and the pipeline refuses the change stage while it is empty' {
        $template = Get-Yaml 'pipelines/azure-devops/variables/approval-environments.yml'
        $defined = @($template['variables'] | Where-Object { $_['name'] -eq 'AZL_ENVIRONMENT_ARM_DEPLOYMENT' })
        $defined.Count | Should -Be 1
        [string]$defined[0]['value'] | Should -Be '' -Because 'no value of a deployment is written in the toolkit'
        $text = Get-Text 'pipelines/azure-devops/pre-cluster-verification.yml'
        # the change stage exists only when the variable is set; when it is not, a stage fails and says which file to edit
        $text | Should -Match "(?m)^\s+- \`$\{\{ if and\(or\(parameters\.fix, parameters\.install_environment_checker\), ne\(variables\.AZL_ENVIRONMENT_ARM_DEPLOYMENT, ''\)\) \}\}:\r?$"
        $text | Should -Match "(?m)^\s+- \`$\{\{ if and\(or\(parameters\.fix, parameters\.install_environment_checker\), eq\(variables\.AZL_ENVIRONMENT_ARM_DEPLOYMENT, ''\)\) \}\}:\r?$"
        $guard = ($text -split '- stage: ApprovalEnvironmentNotSet')[1] -split '- stage: VerifyWithChanges' | Select-Object -First 1
        $guard | Should -Match 'approval-environments\.yml'
        $guard | Should -Match '(?m)^\s+exit 1\r?$'
        $guard | Should -Not -Match '\$p\.Fix|InstallEnvironmentChecker|AzurePowerShell@'
    }
    It 'Azure DevOps: no pipeline run form can name the approval environment of the gate (the only parameters are the ones listed)' {
        $names = @((Get-Yaml 'pipelines/azure-devops/pre-cluster-verification.yml')['parameters'] | ForEach-Object { [string]$_['name'] })
        $names | Should -Be @('infrastructure_file', 'mode', 'os_configuration_pipeline_id', 'os_configuration_run_id', 'os_configuration_report', 'handoff_file', 'accept_skipped', 'allow_revalidate', 'fix', 'install_environment_checker', 'agent_pool', 'service_connection', 'variable_group')
    }
    It 'Azure DevOps: lockBehavior is described as what Learn says it is (it governs Exclusive lock checks), and each stage that must not overlap sets it' -ForEach @(
        @{ File = 'pipelines/azure-devops/pre-cluster-verification.yml'; Stages = @('Verify', 'VerifyWithChanges') }
        @{ File = 'pipelines/azure-devops/discovery.yml'; Stages = @('Discover') }
    ) {
        $text = Get-Text $File
        $text | Should -Not -Match '(?m)^#\s*Runs queue one after the other'
        $text | Should -Match '(?m)^# lockBehavior does not queue runs by itself\.'
        $text | Should -Match '(?m)^lockBehavior: sequential\r?$'
        # the stages sit under ${{ if }} keys: walk the whole document
        function Find-Stage($Node, [string]$Name) {
            if ($Node -is [System.Collections.IDictionary]) { if ($Node.Contains('stage') -and $Node['stage'] -eq $Name) { $Node }; foreach ($k in $Node.Keys) { Find-Stage $Node[$k] $Name } }
            elseif ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { Find-Stage $i $Name } }
        }
        $doc = Get-Yaml $File
        foreach ($stage in $Stages) {
            $s = @(Find-Stage $doc $stage)
            $s.Count | Should -Be 1 -Because $stage
            [string]$s[0]['lockBehavior'] | Should -Be 'sequential' -Because "stage $stage"
        }
    }
    It '<Platform> <Name> signs in with a client secret through toJSON, so a secret with a quote or a backslash cannot break the JSON of creds' -ForEach @($script:Pipelines | Where-Object { $_.Platform -eq 'GitHub' }) {
        $text = Get-Text $File
        $creds = @($text -split "`r?`n" | Where-Object { $_ -match '^\s+creds:' })
        $creds.Count | Should -BeGreaterThan 0
        foreach ($line in $creds) {
            $line | Should -Match 'toJSON\(secrets\.ARM_CLIENT_SECRET\)'
            $line | Should -Not -Match '"\{1\}"' -Because 'a secret placed between quotes by format() is not escaped'
            $line | Should -Not -Match '"\{[0-3]\}"'
        }
    }
    It 'every GitHub pipeline builds creds the safe way, and the JSON it makes is valid for a secret that holds a quote or a backslash' -ForEach $script:GitHubPipelineFiles {
        $lines = @((Get-Text $File) -split "`r?`n" | Where-Object { $_ -match '^\s+creds:' })
        foreach ($line in $lines) { $line | Should -Match 'toJSON\(secrets\.ARM_CLIENT_SECRET\)' -Because $File }
        # what the expression makes: format() puts toJSON(value) (a JSON string, with its quotes and escapes) into the template
        $template = [regex]::Match($lines[0], "format\('(?<t>.*?)',").Groups['t'].Value -replace '\{\{', '{' -replace '\}\}', '}'
        $secret = 'p"a\ss'
        $json = $template.Replace('{0}', ($script:Repo | ConvertTo-Json)).Replace('{1}', ($secret | ConvertTo-Json)).Replace('{2}', '"s"').Replace('{3}', '"t"')
        $parsed = $json | ConvertFrom-Json
        $parsed.clientSecret | Should -Be $secret
    }
    It '<Platform> publishes a copy of the folder the script wrote, where the ARM run reads it, and does not pass -ReportDirectory' -ForEach @($script:Pipelines | Where-Object { $_.Name -eq 'pre-cluster-verification' }) {
        $text = Get-Text $File
        $text | Should -Match 'PassThru'
        $text | Should -Match 'ReportDirectory'
        (Get-PassedParameter $text) | Should -Not -Contain 'ReportDirectory'
        $text | Should -Match 'deployment\.pre_cluster_verification_report_directory'
    }
    It 'the entry point has the parameters the pipelines pass' {
        foreach ($p in 'InfrastructureFile', 'Mode', 'PassThru', 'OsConfigurationReport', 'HandoffFile', 'AcceptSkipped', 'AllowRevalidate', 'Fix', 'InstallEnvironmentChecker') { $script:GateParam.Keys | Should -Contain $p }
        $script:GateParam['Mode'] | Should -Be @('Plan', 'Verify')
    }
}

Describe 'The GitHub folder and the Ansible tree' {
    It 'one GitHub pipeline folder: no archive of workflows, and every deployment pipeline is in pipelines/github-actions' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'archive', 'github-actions')) | Should -BeFalse
        foreach ($f in 'discovery', 'pre-cluster-verification', 'os-configuration', 'arm-deployment', 'cicd-infra', 'azure-local-deploy') {
            Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'github-actions', "$f.yml")) | Should -BeTrue -Because $f
        }
    }
    It 'one Ansible tree: src/ansible holds the role the OS configuration playbook runs, and there is no ansible/ folder' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'ansible')) | Should -BeFalse
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'src', 'ansible', 'roles', 'azurelocal_os_configuration', 'tasks', 'main.yml')) | Should -BeTrue
        (Get-Text 'src/ansible/playbooks/02-os-configuration.yml') | Should -Match '- role: azurelocal_os_configuration'
    }
}
