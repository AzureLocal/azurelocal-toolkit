#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Every pipeline file names only things that exist: the scripts, the playbooks and the paths of the toolkit it calls. The README lists every
# pipeline file, and the removed folders (the old GitHub workflow archive, the second Ansible tree) are named nowhere. Nothing is run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines/PipelinePaths.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $root = [IO.Path]::Combine($repo, 'pipelines')
    $script:Files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.Extension -in '.yml', '.ps1' } |
            ForEach-Object { @{ File = 'pipelines/' + $_.FullName.Substring($root.Length + 1).Replace('\', '/') } })
    $script:YamlFiles = @($script:Files | Where-Object { $_.File -like '*.yml' })
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    function Get-Text([string]$File) { [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $File)) }
}

Describe 'Every path a pipeline names exists' {
    It '<File>: each repository path it names exists' -ForEach $script:Files {
        $text = Get-Text $File
        $paths = @([regex]::Matches($text, '(?<![\w/.-])((?:scripts|config|src|pipelines|tools|docs|tests)/[A-Za-z0-9_./-]+)') | ForEach-Object { $_.Groups[1].Value.TrimEnd('.', ',', ')', ':') } | Sort-Object -Unique)
        foreach ($p in $paths) {
            # a path that ends in a folder of the toolkit, a script, a module or a file; a pattern or a placeholder is not a path
            if ($p -match '[*{}$]|<') { continue }
            Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, $p)) | Should -BeTrue -Because "$File names $p"
        }
    }
    It '<File>: each Ansible playbook it runs exists in src/ansible/playbooks' -ForEach $script:YamlFiles {
        $text = Get-Text $File
        foreach ($m in [regex]::Matches($text, '(?<![\w/.-])playbooks/([0-9A-Za-z-]+\.yml)')) {
            Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'src', 'ansible', 'playbooks', $m.Groups[1].Value)) | Should -BeTrue -Because "$File runs playbooks/$($m.Groups[1].Value)"
        }
    }
    It '<File> parses' -ForEach $script:YamlFiles {
        { ConvertFrom-Yaml (Get-Text $File) -Ordered } | Should -Not -Throw
    }
}

Describe 'The GitLab-only validate-deployment stage is gone (D126: no logic of one platform only)' {
    It 'the file, its include and its stage are removed' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'pipelines', 'gitlab', 'stages', 'validate-deployment.yml')) | Should -BeFalse
        (Get-Text 'pipelines/gitlab/.gitlab-ci.yml') | Should -Not -Match 'validate-deployment'
    }
}

Describe 'The README and the removed folders' {
    It 'pipelines/README.md names every pipeline file' -ForEach $script:YamlFiles {
        $readme = Get-Text 'pipelines/README.md'
        $relative = $File -replace '^pipelines/', ''
        $leaf = Split-Path -Leaf $relative
        # the files of the Terraform and Ansible chain are named through the chain's entry file
        if ($relative -match '^gitlab/stages/(validate|deploy-foundation|configure-onprem|configure-operations)\.yml$') { $readme | Should -Match 'gitlab/stages/\*\.yml|stages/\*\.yml'; return }
        $readme | Should -Match ([regex]::Escape($leaf)) -Because "$File is not in pipelines/README.md"
    }
    It 'no file of the toolkit names the removed archive of GitHub workflows or the second Ansible tree as a place' {
        $hits = foreach ($dir in 'docs', 'pipelines', 'scripts', 'src', 'tests', 'config/variables/docs', 'repo-management') {
            Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, $dir)) -Recurse -File -Include '*.md', '*.yml', '*.ps1', '*.psm1' |
                Where-Object { $_.Name -notin 'PipelinePaths.Tests.ps1', 'DiscoveryAndGatePipelines.Tests.ps1' -and $_.FullName -notmatch '[\\/]deferred[\\/]' } |
                Select-String -Pattern 'ansible/os-configuration|ansible\\os-configuration' -List | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        }
        @($hits) | Should -BeNullOrEmpty
    }
}
