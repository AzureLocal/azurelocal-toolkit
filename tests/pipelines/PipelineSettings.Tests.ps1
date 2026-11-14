#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The pipeline files under pipelines/ carry no value a deployment chooses (research rows 1076, 1078, 1079 and 1080):
#   - a runner label, an agent pool name and an approval environment name is an expression or a variable, never a literal
#     (GitHub: the vars context; GitLab: a CI/CD variable in tags and environment:name; Azure DevOps: a runtime parameter, because the
#     pool and the environment of a job are not task inputs);
#   - every such variable or parameter has a pipeline_inputs entry in the registry with a source_key that is a key of infrastructure.yml,
#     and the CI/CD setup (task 05, AzlCicdInfra.psm1) sets the same variable from the same key;
#   - a job timeout and an artifact retention stay in the files, each with a comment that says what it covers.
# Nothing is run and nothing is sent anywhere.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines/PipelineSettings.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $pipelines = [IO.Path]::Combine($repo, 'pipelines')
    $rel = { param($f) ($f.FullName.Substring($pipelines.Length + 1) -replace '\\', '/') }
    $script:GitHubFiles = @(Get-ChildItem -LiteralPath $pipelines -Recurse -Filter '*.yml' -File | Where-Object { (& $rel $_) -like 'github/*' -or (& $rel $_) -like 'github-actions/*' } | ForEach-Object { @{ File = "pipelines/$(& $rel $_)" } })
    $script:AdoFiles = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($pipelines, 'azure-devops')) -Filter '*.yml' -File | ForEach-Object { @{ File = "pipelines/azure-devops/$($_.Name)" } })
    $script:GitLabFiles = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($pipelines, 'gitlab')) -Recurse -File -Force | Where-Object { $_.Name -like '*.yml' } | ForEach-Object { @{ File = "pipelines/$(& $rel $_)" } })
    $script:AllFiles = @($script:GitHubFiles) + @($script:AdoFiles) + @($script:GitLabFiles)
    # the variables the setup (task 05) sets, read from the module: name, key and platforms
    $module = Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')) -Force -PassThru
    $script:SetupData = @(& $module { $script:AzlPipelineVariable } | ForEach-Object { @{ Name = $_.Name; Key = $_.Key; Platforms = @($_.Platforms) } })
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Module = Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')) -Force -PassThru
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))

    function Get-Text([string]$File) { [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $File)) }
    function Get-Yaml([string]$File) { ConvertFrom-Yaml (Get-Text $File) -Ordered }

    # every dictionary in a parsed YAML document, with the key it sits under
    function Get-Node($Node, [string]$Key = '') {
        if ($Node -is [System.Collections.IDictionary]) {
            [pscustomobject]@{ Key = $Key; Node = $Node }
            foreach ($k in $Node.Keys) { Get-Node $Node[$k] ([string]$k) }
        }
        elseif ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { Get-Node $i $Key } }
    }

    # the pipeline_inputs entries of the registry: one object per entry, with the area (file) of its group
    $script:Inputs = @(foreach ($r in $script:Registry) {
            if ($r.Path -match '\.pipeline_inputs\.[^.]+\.[^.]+$' -and $r.Node.Contains('name')) {
                $group = $script:Registry | Where-Object { $_.Path -eq ($r.Path -replace '\.[^.]+$', '') } | Select-Object -First 1
                [pscustomobject]@{ Path = $r.Path; Name = [string]$r.Node['name']; Area = [string]$group.Node['area']; Node = $r.Node }
            }
        })

    # the names the setup (task 05) sets, and the key each one is set from: read from the module, not copied here
    $script:SetupVariables = @(& $script:Module { $script:AzlPipelineVariable })
    $script:RtFiles = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines')) -Recurse -Filter '*.yml' -File -Force | ForEach-Object { 'pipelines/' + ($_.FullName.Substring(([IO.Path]::Combine($script:Repo, 'pipelines')).Length + 1).Replace('\', '/')) })
    $script:RtShared = @($script:RtFiles | Where-Object { $_ -like 'pipelines/github*' -or $_ -like 'pipelines/gitlab/*' })

    function Get-MasterPath($Obj, [string]$Path) {
        if ($Obj -is [System.Collections.IDictionary]) { foreach ($k in $Obj.Keys) { $p = if ($Path) { "$Path.$k" } else { [string]$k }; $p; Get-MasterPath $Obj[$k] $p } }
        elseif ($Obj -is [System.Collections.IList]) { foreach ($i in $Obj) { Get-MasterPath $i "$Path[]" } }
    }
    $master = ConvertFrom-Yaml (Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'templates', 'infrastructure.master.yml')) -Raw) -Ordered
    $script:MasterPaths = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-MasterPath $master ''))

    # a comment on the line, or on the comment line(s) just above it
    function Test-HasComment([string[]]$Lines, [int]$Index) {
        if ($Lines[$Index] -match '\s#\s') { return $true }
        $i = $Index - 1
        return ($i -ge 0 -and $Lines[$i].TrimStart().StartsWith('#'))
    }
}

Describe 'GitHub Actions: runner labels and environment names come from the vars context' {
    It '<File>: runs-on is the hosted image or names the runner label variable, and the environment is an expression' -ForEach $script:GitHubFiles {
        $doc = Get-Yaml $File
        foreach ($job in $doc['jobs'].Keys) {
            $j = $doc['jobs'][$job]
            $on = $j['runs-on']
            if ($on -is [System.Collections.IList]) {
                $on[0] | Should -Be 'self-hosted' -Because "$job lists self-hosted first"
                $dynamic = @($on | Where-Object { $_ -like '${{*' })
                $dynamic.Count | Should -BeGreaterThan 0 -Because "$job selects the runner by a variable"
                $dynamic | ForEach-Object { $_ | Should -Match 'vars\.AZL_RUNNER_LABEL' }
                @($on | Where-Object { $_ -notlike '${{*' -and $_ -notin 'self-hosted', 'linux' }) | Should -BeNullOrEmpty -Because "$job names no label of its own (self-hosted and linux are GitHub's own labels)"
            }
            else {
                # ubuntu-latest is the vendor's label of its hosted image, not a setting of a deployment
                ([string]$on -eq 'ubuntu-latest' -or [string]$on -match 'vars\.AZL_RUNNER_LABEL') | Should -BeTrue -Because "$job runs-on is $on"
            }
            if ($j.Contains('environment')) {
                $env = $j['environment']
                if ($env -is [System.Collections.IDictionary]) { $env = $env['name'] }
                [string]$env | Should -Match '^\$\{\{ vars\.AZL_ENVIRONMENT_[A-Z_]+ \}\}$' -Because "$job"
            }
        }
    }
}

Describe 'Azure DevOps: the pool and the environment of a job are runtime parameters' {
    It '<File>: every pool name and environment is ${{ parameters.x }}, and x is declared in the file' -ForEach $script:AdoFiles {
        $doc = Get-Yaml $File
        $declared = @{}
        foreach ($p in $doc['parameters']) { $declared[[string]$p['name']] = $p }
        $used = [System.Collections.Generic.List[string]]::new()
        foreach ($n in (Get-Node $doc)) {
            if ($n.Node.Contains('pool') -and $n.Node['pool'] -is [System.Collections.IDictionary]) {
                $pool = $n.Node['pool']
                if ($pool.Contains('name')) { [string]$pool['name'] | Should -Match '^\$\{\{ parameters\.\w+ \}\}$'; $used.Add(([regex]::Match([string]$pool['name'], 'parameters\.(\w+)').Groups[1].Value)) }
                if ($pool.Contains('vmImage')) { [string]$pool['vmImage'] | Should -Be 'ubuntu-latest' -Because 'the hosted image is the vendor label, not a setting of a deployment' }
            }
            if ($n.Node.Contains('environment') -and $n.Node.Contains('strategy')) {
                [string]$n.Node['environment'] | Should -Match '^\$\{\{ parameters\.\w+ \}\}$'
                $used.Add(([regex]::Match([string]$n.Node['environment'], 'parameters\.(\w+)').Groups[1].Value))
            }
        }
        $used.Count | Should -BeGreaterThan 0
        foreach ($u in ($used | Sort-Object -Unique)) { $declared.Keys | Should -Contain $u }
    }
    It '<File>: a pool or environment parameter has no default that names something (empty, hosted or a placeholder at most)' -ForEach $script:AdoFiles {
        $doc = Get-Yaml $File
        $text = Get-Text $File
        $names = [regex]::Matches($text, '(?m)^\s+(?:name|environment): \$\{\{ parameters\.(\w+) \}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        foreach ($n in $names) {
            $p = $doc['parameters'] | Where-Object { $_['name'] -eq $n }
            if ($p.Contains('default')) { ([string]$p['default']) | Should -BeIn @('', 'hosted') -Because "the default of $n" }
            $p.Contains('values') | Should -BeFalse -Because "$n is not a list of names"
        }
    }
    It 'every file that gates an Apply or Deploy names its environment by a parameter: no literal environment is left' {
        foreach ($f in @($script:RtFiles | Where-Object { $_ -like 'pipelines/azure-devops/*' })) {
            (Get-Text $f) | Should -Not -Match "(?m)^\s+environment:\s+(?!\$\{\{ parameters\.)\S" -Because $f
        }
    }
}

Describe 'GitLab CI: tags and environment names are CI/CD variables' {
    It '<File>: every tag is a variable and every environment name is a variable' -ForEach $script:GitLabFiles {
        $doc = Get-Yaml $File
        $tagged = 0
        foreach ($n in (Get-Node $doc)) {
            if ($n.Node.Contains('tags')) {
                foreach ($t in @($n.Node['tags'])) { [string]$t | Should -Match '^\$(\{AZL_RUNNER_LABEL\}|AZL_RUNNER_LABEL)$' }
                $tagged++
            }
            if ($n.Key -eq 'environment' -or ($n.Node.Contains('environment') -and $n.Node['environment'] -is [System.Collections.IDictionary])) {
                $env = if ($n.Key -eq 'environment') { $n.Node } else { $n.Node['environment'] }
                if ($env.Contains('name')) { [string]$env['name'] | Should -Match '^\$(\{AZL_ENVIRONMENT_[A-Z_]+\}|AZL_ENVIRONMENT_[A-Z_]+)$' }
            }
        }
        # a file with a runner section selects it by tag: nothing else may be a tag
        (Get-Text $File) | Should -Not -Match '(?m)^\s*tags:\s*\[(?!\$AZL_RUNNER_LABEL\])'
    }
}

Describe 'Every variable or parameter of a runner label, pool or environment is registered with its source key' {
    It '<File>: each AZL_ variable it reads has a pipeline_inputs entry for this file' -ForEach (@($script:GitHubFiles) + @($script:GitLabFiles)) {
        $text = Get-Text $File
        $names = @([regex]::Matches($text, '(?<![A-Za-z0-9_])(?:vars\.|\$\{?)(AZL_[A-Z_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($n in $names) {
            $e = @($script:Inputs | Where-Object { $_.Area -eq $File -and $_.Name -eq $n })
            $e.Count | Should -Be 1 -Because "$File reads $n"
            $e[0].Node['source_key'] | Should -Not -BeNullOrEmpty
        }
    }
    It '<File>: each pool and environment parameter it uses has a pipeline_inputs entry for this file' -ForEach $script:AdoFiles {
        $text = Get-Text $File
        $names = @([regex]::Matches($text, '(?m)^\s+(?:name|environment): \$\{\{ parameters\.(\w+) \}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $names.Count | Should -BeGreaterThan 0
        foreach ($n in $names) {
            $e = @($script:Inputs | Where-Object { $_.Area -eq $File -and $_.Name -eq $n })
            $e.Count | Should -Be 1 -Because "$File uses the parameter $n"
            $e[0].Node['source_key'] | Should -Not -BeNullOrEmpty
        }
    }
    It 'every entry that has a source_key names a key of infrastructure.yml' {
        $bad = foreach ($e in @($script:Inputs | Where-Object { $_.Node.Contains('source_key') })) {
            if (-not $script:MasterPaths.Contains([string]$e.Node['source_key'])) { "$($e.Area) $($e.Name): $($e.Node['source_key'])" }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It 'the line an entry says it is read at holds its name' {
        $bad = foreach ($e in @($script:Inputs | Where-Object { $_.Node.Contains('source_key') })) {
            if ([string]$e.Node['read_at'] -match '^(.+):(\d+)$') {
                $lines = (Get-Text $Matches[1]) -split "`r?`n"
                if ($lines[[int]$Matches[2] - 1] -notmatch [regex]::Escape($e.Name)) { "$($e.Area) $($e.Name): read_at $($e.Node['read_at']) is '$($lines[[int]$Matches[2] - 1].Trim())'" }
            }
            else { "$($e.Area) $($e.Name): no read_at" }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It 'no old entry that registers a literal environment name is left' {
        $left = @($script:Registry | Where-Object { $_.Node -is [System.Collections.IDictionary] -and $_.Node.Contains('type') -and [string]$_.Node['type'] -eq 'environment name' })
        $left.Count | Should -Be 0
    }
}

Describe 'The setup and the pipelines read the same key' {
    It 'the setup (task 05) has a variable for each AZL_ name that a pipeline reads, and no more' {
        $read = @(foreach ($f in $script:RtShared) {
                [regex]::Matches((Get-Text $f), '(?<![A-Za-z0-9_])(?:vars\.|\$\{?)(AZL_[A-Z_]+)') | ForEach-Object { $_.Groups[1].Value }
            }) | Sort-Object -Unique
        $set = @($script:SetupVariables | Where-Object { $_.Platforms -contains 'github' -or $_.Platforms -contains 'gitlab' } | ForEach-Object { $_.Name }) | Sort-Object -Unique
        $read | Should -Be $set
    }
    It '<Name> is set from <Key>, and the registry entries of every pipeline file that reads it carry the same source_key' -ForEach $script:SetupData {
        $script:MasterPaths.Contains($Key) | Should -BeTrue
        $entries = @($script:Inputs | Where-Object { $_.Name -eq $Name })
        if ($Platforms -contains 'github' -or $Platforms -contains 'gitlab') { $entries.Count | Should -BeGreaterThan 0 }
        foreach ($e in $entries) { $e.Node['source_key'] | Should -Be $Key -Because "$($e.Area) reads $Name" }
    }
    It 'the Azure DevOps parameters take the same keys as the setup lists for Azure DevOps' {
        $byKey = @{}
        foreach ($v in $script:SetupVariables) { if ($v.Platforms -contains 'azure_devops') { $byKey[$v.Key] = $v } }
        $byKey['devops.runners[].pool'] = $true
        $keys = @($script:Inputs | Where-Object { $_.Area -like 'pipelines/azure-devops/*' -and $_.Node.Contains('source_key') } | ForEach-Object { [string]$_.Node['source_key'] } | Sort-Object -Unique)
        foreach ($k in $keys) { $byKey.Keys | Should -Contain $k }
        # and the five environment keys and the pool are all used by some Azure DevOps file
        foreach ($k in $byKey.Keys) { $keys | Should -Contain $k }
    }
    It 'the module reads each key it sets a variable from: devops.pipelines.runner_label and devops.pipelines.environments.*' {
        $text = Get-Text 'scripts/common/cicd-infra/AzlCicdInfra.psm1'
        $text | Should -Match "Get-AzlValue \`$devops 'pipelines\.runner_label'"
        $text | Should -Match "Get-AzlValue \`$devops 'pipelines\.environments'"
        foreach ($v in @($script:SetupVariables | Where-Object { $_.Key -like 'devops.pipelines.environments.*' })) {
            $leaf = $v.Key -replace '^devops\.pipelines\.environments\.', ''
            $text | Should -Match "(?m)^\s+$([regex]::Escape($leaf))\s+= \[string\]\(Get-AzlValue" -Because $v.Key
        }
    }
    It 'the Azure DevOps pool is the pool of the general runner: devops.runners[].pool, the key task 06 gives the agents' {
        $text = Get-Text 'scripts/common/cicd-infra/AzlCicdInfra.psm1'
        $text | Should -Match "Pool\s+= \[string\]\(Get-AzlValue \`$_ 'pool'\)"
        $text | Should -Match '\$variables\.azure_devops_pool = \$linux\[0\]\.Pool'
        $text | Should -Match "Key = 'devops\.runners\[\]\.pool'"
    }
    It 'the runners and the setup have no default pool: no pool name is written in Terraform, Ansible, the module or a pipeline' {
        foreach ($f in 'src/terraform/environments/cicd-infra/variables.tf', 'src/terraform/modules/cicd-runner/variables.tf', 'src/ansible/roles/cicd_runner/defaults/main.yml', 'scripts/common/cicd-infra/AzlCicdInfra.psm1') {
            (Get-Text $f) | Should -Not -Match 'AzureRunners|AzureLocalZtp|AzureLocal-SelfHosted' -Because $f
        }
        foreach ($f in $script:RtFiles) { (Get-Text $f) | Should -Not -Match 'AzureRunners|AzureLocalZtp|AzureLocal-SelfHosted' -Because $f }
        (Get-Text 'src/terraform/modules/cicd-runner/main.tf') | Should -Match 'azure_devops_pool != ""'
        (Get-Text 'src/ansible/roles/cicd_runner/tasks/main.yml') | Should -Match "cicd_runner_azure_devops_pool \| length > 0"
    }
    It 'no pipeline file carries an environment or runner name that an older version had' {
        $old = 'azure-local-os-configuration-clear-storage', 'azure-local-deploy', 'cicd-infra-apply', 'azurelocal', 'AzureLocal-SelfHosted'
        foreach ($f in $script:RtFiles) {
            $code = (Get-Text $f) -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') }
            foreach ($o in $old) { ($code -join "`n") | Should -Not -Match "(?m)^\s*(environment|name|tags|runs-on):.*\b$([regex]::Escape($o))\b" -Because "$f $o" }
        }
    }
}

Describe 'Job timeouts and artifact retention stay in the files, each with a comment' {
    It '<File>: every timeout and every retention has a comment on its line or just above it' -ForEach $script:AllFiles {
        $lines = (Get-Text $File) -split "`r?`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*(timeout-minutes|timeoutInMinutes|timeout|retention-days|expire_in):\s*\S') {
                (Test-HasComment $lines $i) | Should -BeTrue -Because "$File line $($i + 1): $($lines[$i].Trim())"
            }
        }
    }
    It 'a deployment job timeout cites the Microsoft Learn page on how long a deployment takes, and the wait setting it must exceed' -ForEach @(
        @{ File = 'pipelines/github-actions/arm-deployment.yml'; Pattern = 'timeout-minutes: 420' }
        @{ File = 'pipelines/azure-devops/arm-deployment.yml'; Pattern = 'timeoutInMinutes: 480' }
        @{ File = 'pipelines/gitlab/stages/arm-deployment.yml'; Pattern = 'timeout: 7 hours' }
    ) {
        $lines = (Get-Text $File) -split "`r?`n"
        $at = 0..($lines.Count - 1) | Where-Object { $lines[$_] -match [regex]::Escape($Pattern) } | Select-Object -First 1
        $at | Should -Not -BeNullOrEmpty
        $above = ($lines[([Math]::Max(0, $at - 4))..($at - 1)]) -join "`n"
        $above | Should -Match 'learn\.microsoft\.com/azure/azure-local/deploy/deployment-azure-resource-manager-template'
        $above | Should -Match 'deployment\.deploy_timeout_minutes'
    }
    It 'the timeout of the longest job is longer than the wait of the script it runs (deployment.deploy_timeout_minutes, default 360)' {
        $entry = @($script:Registry | Where-Object { $_.Path -like '*deploy_timeout_minutes' -and $_.Node.Contains('default') })
        $entry.Count | Should -BeGreaterThan 0
        $default = [int]$entry[0].Node['default']
        $default | Should -Be 360
        [int][regex]::Match((Get-Text 'pipelines/github-actions/arm-deployment.yml'), 'timeout-minutes: (4\d\d)').Groups[1].Value | Should -BeGreaterThan $default
        [int][regex]::Match((Get-Text 'pipelines/azure-devops/arm-deployment.yml'), 'timeoutInMinutes: (4\d\d)').Groups[1].Value | Should -BeGreaterThan $default
    }
}
