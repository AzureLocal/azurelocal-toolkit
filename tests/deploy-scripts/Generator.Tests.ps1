#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Generate-DeployScriptScaffolds.ps1 writes the placeholders. It must write no Bash, no Azure CLI placeholder for a task that
# does not act on Azure, and no module; it must stop on a task that is not in the task catalogue; and what it writes must be
# what is committed. Every run is against a temporary folder and a made-up coverage document.
# Run: Invoke-Pester ./tests/deploy-scripts

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers.')]
param()

BeforeAll {
    $script:Repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Deploy = [System.IO.Path]::Combine($script:Repo, 'scripts', 'deploy')
    $script:Generator = [System.IO.Path]::Combine($script:Deploy, 'common', 'Generate-DeployScriptScaffolds.ps1')
    $script:RealCatalogue = [System.IO.Path]::Combine($script:Deploy, 'common', 'TaskCatalogue.psd1')

    # A coverage document in the format the generator reads: a task table (14 columns) and the script list.
    function New-CoverageDocument {
        param([string]$Path, [hashtable]$Tasks, [object[]]$Scripts)

        $lines = @('# Coverage', '', '| # | Task | c3 | c4 | c5 | c6 | PS Standalone | PS Orchestrated | AzCLI | c10 | Bash | c12 | c13 | Status |')
        foreach ($n in ($Tasks.Keys | Sort-Object)) {
            $lines += ('| {0} | {1} | c3 | c4 | c5 | c6 |  |  |  |  |  |  | c13 | Needed |' -f $n, $Tasks[$n])
        }
        $lines += ''
        $lines += '## Scripts to Create (Complete List)'
        $lines += ''
        foreach ($s in $Scripts) {
            $lines += ('| {0} | Task | `{1}` | {2} | `{3}/` |' -f $s.Task, $s.Name, $s.Type, $s.Folder)
        }
        $lines += ''
        $lines += '## Standards-Based Script Authoring Plan'
        Set-Content -LiteralPath $Path -Value $lines
    }

    function Invoke-Generator {
        param([string]$Coverage, [string]$Root, [string]$Catalogue)

        $output = & pwsh -NoProfile -NonInteractive -File $script:Generator -CoverageDocumentPath $Coverage -RepositoryRoot $Root -TaskCatalogPath $Catalogue 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
    }

    function New-TempFolder {
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ('gen-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $p | Out-Null
        $p
    }

    function Get-Normalized([string]$Path) { (Get-Content -LiteralPath $Path -Raw).Replace("`r`n", "`n") }
}

Describe 'Generate-DeployScriptScaffolds.ps1' {
    BeforeAll {
        $script:Tmp = New-TempFolder
        $catalogue = Join-Path $script:Tmp 'catalogue.psd1'
        Set-Content -LiteralPath $catalogue -Value @"
@{
    SchemaVersion = 1
    Tasks = @(
        @{ Path = '02-stage/phase-01-a/task-01-azure'; AzureCli = 'yes'; Reason = 'Creates a resource group.' }
        @{ Path = '03-stage/phase-01-b/task-01-onprem'; AzureCli = 'no'; Reason = 'Acts on Active Directory.' }
        @{ Path = '04-stage/phase-01-c/task-01-unclear'; AzureCli = 'unclear'; Reason = 'Not decided.' }
    )
}
"@
        $script:Coverage = Join-Path $script:Tmp 'coverage.md'
        New-CoverageDocument -Path $script:Coverage -Tasks @{
            1 = '02-stage/phase-01-a/task-01-azure'
            2 = '03-stage/phase-01-b/task-01-onprem'
            3 = '04-stage/phase-01-c/task-01-unclear'
        } -Scripts @(
            @{ Task = 1; Name = 'New-A-Standalone.ps1'; Type = 'PS Standalone'; Folder = 'powershell' }
            @{ Task = 1; Name = 'Invoke-A-Orchestrated.ps1'; Type = 'PS Orchestrated'; Folder = 'powershell' }
            @{ Task = 1; Name = 'az-a.ps1'; Type = 'AzCLI'; Folder = 'azurecli' }
            @{ Task = 1; Name = 'az-a.sh'; Type = 'Bash'; Folder = 'bash' }
            @{ Task = 2; Name = 'Set-B-Orchestrated.ps1'; Type = 'PS Orchestrated'; Folder = 'powershell' }
            @{ Task = 2; Name = 'az-b.ps1'; Type = 'AzCLI'; Folder = 'azurecli' }
            @{ Task = 2; Name = 'az-b.sh'; Type = 'Bash'; Folder = 'bash' }
            @{ Task = 3; Name = 'az-c.ps1'; Type = 'AzCLI'; Folder = 'azurecli' }
        )
        $script:Root = Join-Path $script:Tmp 'repo'
        New-Item -ItemType Directory -Path $script:Root | Out-Null
        $script:Run = Invoke-Generator -Coverage $script:Coverage -Root $script:Root -Catalogue $catalogue
        $script:Dep = [System.IO.Path]::Combine($script:Root, 'scripts', 'deploy')
        function script:Task([string]$Path) { [System.IO.Path]::Combine($script:Dep, $Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)) }
    }

    AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'runs' {
        $script:Run.Code | Should -Be 0 -Because $script:Run.Output
    }

    It 'writes the PowerShell placeholders and the Azure CLI placeholder of a task that acts on Azure' {
        Test-Path (Join-Path (Task '02-stage/phase-01-a/task-01-azure') 'powershell/New-A-Standalone.ps1') | Should -BeTrue
        Test-Path (Join-Path (Task '02-stage/phase-01-a/task-01-azure') 'powershell/Invoke-A-Orchestrated.ps1') | Should -BeTrue
        Test-Path (Join-Path (Task '02-stage/phase-01-a/task-01-azure') 'azurecli/az-a.ps1') | Should -BeTrue
    }

    It 'keeps the Azure CLI placeholder of a task whose classification is unclear' {
        Test-Path (Join-Path (Task '04-stage/phase-01-c/task-01-unclear') 'azurecli/az-c.ps1') | Should -BeTrue
    }

    It 'writes no Azure CLI file and no azurecli folder for a task that does not act on Azure' {
        Test-Path (Join-Path (Task '03-stage/phase-01-b/task-01-onprem') 'powershell/Set-B-Orchestrated.ps1') | Should -BeTrue
        Test-Path (Join-Path (Task '03-stage/phase-01-b/task-01-onprem') 'azurecli') | Should -BeFalse
        $script:Run.Output | Should -Match 'Skipped \(Azure CLI does not apply to this task\): 03-stage/phase-01-b/task-01-onprem'
    }

    It 'writes no Bash file and no bash folder' {
        @(Get-ChildItem -LiteralPath $script:Dep -Recurse -Force | Where-Object { $_.Name -eq 'bash' -or $_.Extension -eq '.sh' }) | Should -BeNullOrEmpty
        $script:Run.Output | Should -Match 'Skipped \(the toolkit has no Bash scripts\)'
    }

    It 'writes no module and no helper next to the placeholders' {
        Test-Path (Join-Path $script:Dep 'common') | Should -BeFalse
    }

    It 'says what it created and left out' {
        $script:Run.Output | Should -Match 'Created 5 placeholders; skipped 0 existing; left out 2 Bash and 1 Azure CLI entries\.'
    }

    It 'records only the scripts it wrote in the task table of the coverage document' {
        $doc = Get-Content -LiteralPath $script:Coverage
        $row2 = $doc | Where-Object { $_ -match '^\| 2 \| 03-stage' }
        $row2 | Should -Match 'Set-B-Orchestrated\.ps1'
        $row2 | Should -Not -Match 'az-b'
        ($doc | Where-Object { $_ -match '^\| 1 \| 02-stage' }) | Should -Not -Match 'az-a\.sh'
        ($doc -join "`n") | Should -Match '## Scripts Created \(Complete List\)'
    }

    It 'never overwrites a file that exists' {
        $existing = Join-Path (Task '02-stage/phase-01-a/task-01-azure') 'azurecli/az-a.ps1'
        Set-Content -LiteralPath $existing -Value '# a real script'
        $again = Invoke-Generator -Coverage $script:Coverage -Root $script:Root -Catalogue (Join-Path $script:Tmp 'catalogue.psd1')
        $again.Code | Should -Be 0 -Because $again.Output
        (Get-Content -LiteralPath $existing -Raw).Trim() | Should -Be '# a real script'
    }

    It 'stops on a task that is not in the task catalogue' {
        $bad = Join-Path $script:Tmp 'coverage-unknown.md'
        New-CoverageDocument -Path $bad -Tasks @{ 1 = '09-stage/phase-01-z/task-01-new' } -Scripts @(
            @{ Task = 1; Name = 'New-Z.ps1'; Type = 'PS Orchestrated'; Folder = 'powershell' }
        )
        $root = Join-Path $script:Tmp 'repo-unknown'
        New-Item -ItemType Directory -Path $root | Out-Null
        $r = Invoke-Generator -Coverage $bad -Root $root -Catalogue (Join-Path $script:Tmp 'catalogue.psd1')
        $r.Code | Should -Not -Be 0
        $r.Output | Should -Match "not in the task catalogue"
        Test-Path (Join-Path $root 'scripts') | Should -BeFalse
    }
}

Describe 'What the generator writes is what is committed' {
    It 'writes the same text as the committed <Kind> placeholder' -ForEach @(
        @{ Kind = 'Orchestrated'; Type = 'PS Orchestrated'; Folder = 'powershell'; Pattern = 'Invoke-DeploymentOrchestrated\b' }
        @{ Kind = 'Standalone'; Type = 'PS Standalone'; Folder = 'powershell'; Pattern = 'Invoke-DeploymentStandalone\b' }
        @{ Kind = 'Azure CLI'; Type = 'AzCLI'; Folder = 'azurecli'; Pattern = 'Invoke-DeploymentAzCliPowerShell\b' }
    ) {
        $common = [System.IO.Path]::Combine($script:Deploy, 'common') + [System.IO.Path]::DirectorySeparatorChar
        $committed = Get-ChildItem -LiteralPath $script:Deploy -Recurse -File -Filter '*.ps1' |
            Where-Object { -not $_.FullName.StartsWith($common) -and $_.Directory.Name -eq $Folder } |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $Pattern } |
            # A placeholder that still passes the retired -ConfigPath is not the form the generator writes; those are regenerated with their task folder.
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -notmatch '-ConfigPath' } |
            Select-Object -First 1
        $committed | Should -Not -BeNullOrEmpty
        $task = $committed.Directory.Parent.FullName.Substring($script:Deploy.Length).TrimStart('\', '/').Replace('\', '/')

        $tmp = New-TempFolder
        try {
            $coverage = Join-Path $tmp 'coverage.md'
            New-CoverageDocument -Path $coverage -Tasks @{ 1 = $task } -Scripts @(@{ Task = 1; Name = $committed.Name; Type = $Type; Folder = $Folder })
            $root = Join-Path $tmp 'repo'
            New-Item -ItemType Directory -Path $root | Out-Null
            $r = Invoke-Generator -Coverage $coverage -Root $root -Catalogue $script:RealCatalogue
            $r.Code | Should -Be 0 -Because $r.Output
            $generated = [System.IO.Path]::Combine($root, 'scripts', 'deploy', $task.Replace('/', [System.IO.Path]::DirectorySeparatorChar), $Folder, $committed.Name)
            Get-Normalized $generated | Should -BeExactly (Get-Normalized $committed.FullName)
        }
        finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
