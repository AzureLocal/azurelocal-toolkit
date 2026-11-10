#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# A placeholder script under scripts/deploy does not do its task. Running one must end with a NOT IMPLEMENTED message and
# exit code 3, and must change nothing: no copied variables.yml, no log file, no other file.
# Each run is a child pwsh process in a temporary copy of the minimum a placeholder needs; nothing touches Azure or a node.
# Run: Invoke-Pester ./tests/deploy-scripts

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers.')]
param()

BeforeDiscovery {
    $repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $deploy = [System.IO.Path]::Combine($repo, 'scripts', 'deploy')
    $common = [System.IO.Path]::Combine($deploy, 'common') + [System.IO.Path]::DirectorySeparatorChar
    $all = @(
        Get-ChildItem -LiteralPath $deploy -Recurse -File -Filter '*.ps1' |
            Where-Object { -not $_.FullName.StartsWith($common) } |
            ForEach-Object {
                $text = Get-Content -LiteralPath $_.FullName -Raw
                if ($text -match 'Invoke-Deployment(?<kind>AzCliPowerShell|Orchestrated|Standalone)\b') {
                    @{ Path = $_.FullName; Name = $_.Name; Kind = $Matches['kind'] }
                }
            }
    )
    # One orchestrated, one Azure CLI and every standalone placeholder are run; all of them are checked by reading.
    $script:ToRun = @(
        $all | Where-Object Kind -eq 'Orchestrated' | Select-Object -First 1
        $all | Where-Object Kind -eq 'AzCliPowerShell' | Select-Object -First 1
        $all | Where-Object Kind -eq 'Standalone'
    ) | Where-Object { $null -ne $_ }
}

BeforeAll {
    $script:Repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Deploy = [System.IO.Path]::Combine($script:Repo, 'scripts', 'deploy')
    $script:Module = [System.IO.Path]::Combine($script:Deploy, 'common', 'DeploymentScaffold.psm1')
    $script:Common = [System.IO.Path]::Combine($script:Deploy, 'common') + [System.IO.Path]::DirectorySeparatorChar

    function Get-PlaceholderFile {
        Get-ChildItem -LiteralPath $script:Deploy -Recurse -File -Filter '*.ps1' |
            Where-Object { -not $_.FullName.StartsWith($script:Common) } |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Invoke-Deployment(AzCliPowerShell|Orchestrated|Standalone)\b' }
    }

    function Get-FileList([string]$Root) {
        @(Get-ChildItem -LiteralPath $Root -Recurse -Force | ForEach-Object { $_.FullName.Substring($Root.Length) } | Sort-Object)
    }

    # Runs a placeholder from a temporary copy of the repository's minimum: the module, the placeholder, and a
    # variables.example.yml for the old behaviour to copy. Returns the exit code, the output and the files before and after.
    function Invoke-PlaceholderCopy {
        param([string]$Source, [string[]]$Arguments = @())

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ph-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            $commonDir = [System.IO.Path]::Combine($root, 'scripts', 'deploy', 'common')
            New-Item -ItemType Directory -Path $commonDir -Force | Out-Null
            Copy-Item -LiteralPath $script:Module -Destination $commonDir
            $variables = [System.IO.Path]::Combine($root, 'config', 'variables')
            New-Item -ItemType Directory -Path $variables -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $variables 'variables.example.yml') -Value 'example: true'
            $relative = $Source.Substring($script:Repo.Length).TrimStart('\', '/')
            $target = Join-Path $root $relative
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $Source -Destination $target
            $before = Get-FileList $root
            $output = & pwsh -NoProfile -NonInteractive -File $target @Arguments 2>&1 | Out-String
            $code = $LASTEXITCODE
            [pscustomobject]@{ Code = $code; Output = $output; Before = $before; After = (Get-FileList $root); Root = $root }
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'DeploymentScaffold.psm1' {
    BeforeAll { Import-Module $script:Module -Force }

    It 'says exit code 3' {
        Get-DeploymentPlaceholderExitCode | Should -Be 3
    }

    It 'documents the exit code in its help' {
        $text = Get-Content -LiteralPath $script:Module -Raw
        $text | Should -Match '3\s+NOT IMPLEMENTED'
        $text | Should -Match 'Why 3'
    }

    It 'writes the PowerShell message' {
        Get-DeploymentPlaceholderMessage -TaskPath '03-onprem-readiness/phase-01-active-directory/task-02-security-groups' -Kind PowerShell -ActionName 'New-Thing' |
            Should -BeExactly "NOT IMPLEMENTED: 03-onprem-readiness/phase-01-active-directory/task-02-security-groups has no PowerShell script yet ('New-Thing' is a placeholder). Nothing was changed. Look in the powershell folder of this task for a script that does the work, or follow the steps on the guide page."
    }

    It 'writes the Azure CLI message' {
        Get-DeploymentPlaceholderMessage -TaskPath '02-azure-foundation/phase-01-landing-zones/full-deployment/task-03-create-resource-groups' -Kind 'Azure CLI' |
            Should -BeExactly 'NOT IMPLEMENTED: 02-azure-foundation/phase-01-landing-zones/full-deployment/task-03-create-resource-groups has no Azure CLI script yet. Nothing was changed. Use the PowerShell script for this task if one exists, or follow the steps on the guide page.'
    }

    It 'no longer has the helpers that copied the variables example or wrote a log' {
        $names = (Get-Command -Module DeploymentScaffold).Name
        $names | Should -Not -Contain 'Initialize-DeploymentConfigPath'
        $names | Should -Not -Contain 'New-DeploymentLogPath'
        $names | Should -Not -Contain 'Write-DeploymentLog'
        $names | Should -Not -Contain 'Resolve-DeploymentCredential'
        (Get-Content -LiteralPath $script:Module -Raw) | Should -Not -Match 'variables\.example\.yml|Copy-Item|Add-Content|Get-Credential'
    }
}

Describe 'Running a placeholder' {
    It '<Name> (<Kind>) ends with NOT IMPLEMENTED, exit code 3, and creates no file' -ForEach $script:ToRun {
        $r = Invoke-PlaceholderCopy -Source $Path
        $r.Code | Should -Be 3 -Because $r.Output
        $r.Output | Should -Match 'NOT IMPLEMENTED: \S+ has no (PowerShell|Azure CLI) script yet'
        $r.Output | Should -Match 'Nothing was changed\.'
        $r.Output | Should -Not -Match 'scaffold'
        $r.After | Should -Be $r.Before -Because 'no variables.yml, no logs folder, no log file'
    }

    It 'says Azure CLI for an Azure CLI placeholder and PowerShell for a PowerShell one' {
        $ps = Get-PlaceholderFile | Where-Object { $_.Directory.Name -eq 'powershell' } | Select-Object -First 1
        $az = Get-PlaceholderFile | Where-Object { $_.Directory.Name -eq 'azurecli' } | Select-Object -First 1
        (Invoke-PlaceholderCopy -Source $ps.FullName).Output | Should -Match 'has no PowerShell script yet'
        (Invoke-PlaceholderCopy -Source $az.FullName).Output | Should -Match 'has no Azure CLI script yet'
    }

    It 'does not create the log file that -LogPath names' {
        $one = Get-PlaceholderFile | Where-Object { $_.Directory.Name -eq 'powershell' -and (Get-Content -LiteralPath $_.FullName -Raw) -match 'Invoke-DeploymentOrchestrated' } | Select-Object -First 1
        $log = Join-Path ([System.IO.Path]::GetTempPath()) ('ph-log-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
        $r = Invoke-PlaceholderCopy -Source $one.FullName -Arguments @('-LogPath', $log)
        $r.Code | Should -Be 3
        Test-Path -LiteralPath $log | Should -BeFalse
    }
}

Describe 'Every placeholder' {
    BeforeAll {
        $script:Placeholders = @(Get-PlaceholderFile)
    }

    It 'exists in a useful number' {
        $script:Placeholders.Count | Should -BeGreaterThan 100
    }

    It 'parses, needs PowerShell 7, is strict and stops on errors, and says it is a placeholder' {
        $bad = @(
            foreach ($f in $script:Placeholders) {
                $errors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
                $text = Get-Content -LiteralPath $f.FullName -Raw
                $problems = @()
                if ($errors.Count -gt 0) { $problems += 'parse error' }
                if ($text -notmatch '(?m)^#Requires -Version 7\.0') { $problems += '#Requires' }
                if ($text -notmatch 'Set-StrictMode -Version Latest') { $problems += 'strict mode' }
                if ($text -notmatch "\`$ErrorActionPreference = 'Stop'") { $problems += 'ErrorActionPreference' }
                if ($text -notmatch '# PLACEHOLDER: this script does not do the task') { $problems += 'placeholder comment' }
                if ($problems.Count -gt 0) { "$($f.FullName.Substring($script:Repo.Length)): $($problems -join ', ')" }
            }
        )
        $bad | Should -BeNullOrEmpty
    }

    It 'names its own task folder and its own file in the call' {
        $bad = @(
            foreach ($f in $script:Placeholders) {
                $text = Get-Content -LiteralPath $f.FullName -Raw
                $task = $f.Directory.Parent.FullName.Substring($script:Deploy.Length).TrimStart('\', '/').Replace('\', '/')
                if ($text -notmatch [regex]::Escape("-TaskPath '$task'")) { "$($f.Name): TaskPath is not '$task'" }
                if ($text -notmatch [regex]::Escape("-ActionName '$($f.BaseName)'")) { "$($f.Name): ActionName is not '$($f.BaseName)'" }
            }
        )
        $bad | Should -BeNullOrEmpty
    }

    It 'is a PowerShell placeholder in powershell/ and an Azure CLI placeholder in azurecli/' {
        $bad = @(
            foreach ($f in $script:Placeholders) {
                $text = Get-Content -LiteralPath $f.FullName -Raw
                $isAz = $text -match 'Invoke-DeploymentAzCliPowerShell\b'
                if ($isAz -and $f.Directory.Name -ne 'azurecli') { "$($f.Name): an Azure CLI call outside azurecli/" }
                if (-not $isAz -and $f.Directory.Name -ne 'powershell') { "$($f.Name): a PowerShell call outside powershell/" }
            }
        )
        $bad | Should -BeNullOrEmpty
    }

    It 'is not named by any pipeline, Ansible role, source file or workflow' {
        $names = @($script:Placeholders | ForEach-Object Name | Select-Object -Unique)
        $roots = 'pipelines', 'ansible', 'src', '.github' | ForEach-Object { Join-Path $script:Repo $_ } | Where-Object { Test-Path -LiteralPath $_ }
        $files = @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File } ) + @(Get-Item -LiteralPath (Join-Path $script:Repo 'azure-pipelines.yml'))
        $hits = @(
            foreach ($file in $files) {
                $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
                if (-not $content) { continue }
                foreach ($name in $names) {
                    if ($content.Contains($name)) { "$($file.FullName.Substring($script:Repo.Length)) names $name" }
                }
            }
        )
        $hits | Should -BeNullOrEmpty -Because 'a placeholder fails; nothing may call one'
    }
}

Describe 'Bash' {
    It 'has no Bash placeholder and no Bash helper under scripts/deploy' {
        @(Get-ChildItem -LiteralPath $script:Deploy -Recurse -File -Filter '*.sh' |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'invoke_bash_deployment' }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath ([System.IO.Path]::Combine($script:Deploy, 'common', 'deployment-scaffold.sh')) | Should -BeFalse
    }

    It 'keeps a bash folder only where it holds a script' {
        $empty = @(Get-ChildItem -LiteralPath $script:Deploy -Recurse -Directory -Filter 'bash' |
                Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.sh').Count -eq 0 } |
                ForEach-Object { $_.FullName.Substring($script:Repo.Length) })
        $empty | Should -BeNullOrEmpty
    }
}
