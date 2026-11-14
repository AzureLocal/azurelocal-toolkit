#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The old variables layout is retired in scripts/deploy/01-cicd-infra and scripts/deploy/02-azure-foundation: no -ConfigPath, no CONFIGURATION region, no default
# path, no prompt, no placeholder next to a script that does the job, and every script that takes the file takes it as a mandatory -InfrastructureFile.
# Nothing here runs a script against Azure; a placeholder is run in a child process and only ends with exit code 3.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/OldLayoutRetired.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $deploy = [IO.Path]::Combine($repo, 'scripts', 'deploy')
    $script:Files = @(
        foreach ($stage in '01-cicd-infra', '02-azure-foundation') {
            Get-ChildItem -LiteralPath ([IO.Path]::Combine($deploy, $stage)) -Recurse -File -Filter '*.ps1' | ForEach-Object {
                @{ Name = $_.Name; Path = $_.FullName; Relative = $_.FullName.Substring($repo.Length + 1).Replace('\', '/') }
            }
        }
    )
    $script:Placeholders = @($script:Files | Where-Object { (Get-Content -LiteralPath $_.Path -Raw) -match 'PLACEHOLDER: this script does not do the task' })
    $script:Gone = @(
        @{ Item = 'scripts/deploy/02-azure-foundation/phase-01-landing-zones/simplified-deployment' }
        @{ Item = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-09-log-analytics' }
        @{ Item = 'scripts/deploy/01-cicd-infra/phase-01-cicd-setup/task-01-bootstrap/powershell/Invoke-CicdBootstrap-Orchestrated.ps1' }
        @{ Item = 'scripts/deploy/01-cicd-infra/phase-01-cicd-setup/task-06-deploy-runners/powershell/Invoke-CicdRunners-Orchestrated.ps1' }
        @{ Item = 'scripts/deploy/01-cicd-infra/phase-01-cicd-setup/task-06-deploy-runners/azurecli/az-deploy-runners.ps1' }
        @{ Item = 'scripts/deploy/02-azure-foundation/phase-01-landing-zones/full-deployment/task-01-configure-management-groups/powershell/Invoke-ManagementGroups-Orchestrated.ps1' }
        @{ Item = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-11-deploy-management-vms/powershell/Invoke-ManagementVMs-Orchestrated.ps1' }
        @{ Item = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-01-configure-core-variables/powershell/Set-CoreVariables.ps1' }
        @{ Item = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-01-verify-resources/powershell/Test-Resources.ps1' }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Deploy = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy')
    $script:PlaceholderPattern = 'PLACEHOLDER: this script does not do the task'
    $script:AllFiles = @(foreach ($stage in '01-cicd-infra', '02-azure-foundation') { Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Deploy, $stage)) -Recurse -File -Filter '*.ps1' })
    function Get-ParamName([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        if ($ast.ParamBlock) { @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) } else { @() }
    }
}

Describe 'Scripts under 01-cicd-infra and 02-azure-foundation' {
    It 'is a useful number of files' {
        @($script:AllFiles).Count | Should -BeGreaterThan 30
    }

    It '<Relative> has no -ConfigPath, no prompt, no variables.yml and no config loader' -ForEach $script:Files {
        $text = Get-Content -LiteralPath $Path -Raw
        (Get-ParamName $Path) | Should -Not -Contain 'ConfigPath'
        $text | Should -Not -Match 'ConfigPath|Get-Credential|Read-Host|PromptForCredential|variables\.yml|config-loader|Get-SolutionConfig|#region CONFIGURATION|AZL_INFRASTRUCTURE_FILE'
    }

    It '<Relative> takes -InfrastructureFile as a mandatory parameter with no default path' -ForEach $script:Files {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $param = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'InfrastructureFile' })
        $param.Count | Should -Be 1 -Because 'every script of the two folders reads the one infrastructure file'
        $param[0].DefaultValue | Should -BeNullOrEmpty
        @($param[0].Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' -and $_.NamedArguments.ArgumentName -contains 'Mandatory' }).Count | Should -Be 1
    }

    It '<Relative> parses, needs PowerShell 7, is strict and stops on errors' -ForEach $script:Files {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
    }
}

Describe 'What the schema 5 scripts replaced is gone' {
    It '<Item> is gone' -ForEach $script:Gone {
        Test-Path -LiteralPath (Join-Path $script:Repo $Item) | Should -BeFalse
    }

    It 'no task folder holds a placeholder next to a script that does the job' {
        $bad = @(
            foreach ($stage in '01-cicd-infra', '02-azure-foundation') {
                $tasks = Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Deploy, $stage)) -Recurse -Directory | Where-Object { $_.Name -in 'powershell', 'azurecli' } | ForEach-Object { $_.Parent.FullName } | Select-Object -Unique
                foreach ($task in $tasks) {
                    $files = @(Get-ChildItem -LiteralPath $task -Recurse -File -Filter '*.ps1')
                    $isPlaceholder = @($files | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $script:PlaceholderPattern })
                    $real = @($files | Where-Object { $_ -notin $isPlaceholder })
                    if ($real.Count -gt 0 -and $isPlaceholder.Count -gt 0) { "$($task.Substring($script:Deploy.Length + 1)): $($isPlaceholder.Name -join ', ')" }
                }
            }
        )
        $bad | Should -BeNullOrEmpty
    }

    It 'no -Standalone placeholder with a CONFIGURATION region is left in the two folders' {
        $bad = @($script:AllFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Invoke-DeploymentStandalone' } | ForEach-Object { $_.FullName })
        $bad | Should -BeNullOrEmpty
    }

    It 'the catalogue has no entry for a folder that is gone and one for every task folder that is left' {
        $catalogue = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:Deploy, 'common', 'TaskCatalogue.psd1'))
        $listed = @($catalogue.Tasks | ForEach-Object Path | Where-Object { $_ -like '01-cicd-infra/*' -or $_ -like '02-azure-foundation/*' })
        $folders = @(
            foreach ($stage in '01-cicd-infra', '02-azure-foundation') {
                Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Deploy, $stage)) -Recurse -Directory | Where-Object { $_.Name -in 'powershell', 'azurecli' } |
                    ForEach-Object { $_.Parent.FullName.Substring($script:Deploy.Length + 1).Replace('\', '/') }
            }
        ) | Select-Object -Unique
        @($listed | Where-Object { $_ -notin $folders }) | Should -BeNullOrEmpty
        @($folders | Where-Object { $_ -notin $listed }) | Should -BeNullOrEmpty
    }
}

Describe 'The placeholders that stay' {
    It 'are a few, and none takes a credential or a target node' {
        @($script:Placeholders).Count | Should -BeGreaterThan 0
        foreach ($p in $script:Placeholders) {
            $names = Get-ParamName $p.Path
            $names | Should -Contain 'InfrastructureFile'
            $names | Should -Not -Contain 'Credential'
            $names | Should -Not -Contain 'TargetNode'
        }
    }

    if (@($script:Placeholders).Count -gt 0) {
        It '<Relative> ends with NOT IMPLEMENTED and exit code 3, and changes nothing' -ForEach $script:Placeholders {
            $own = Split-Path -Path $Path -Parent
            $logs = Join-Path $script:Repo 'logs'
            $before = @((Get-ChildItem -LiteralPath $own -Force).Name) -join ','
            $logsBefore = Test-Path -LiteralPath $logs
            $output = & pwsh -NoProfile -NonInteractive -File $Path -InfrastructureFile 'infrastructure.yml' 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 3 -Because $output
            $output | Should -Match 'NOT IMPLEMENTED'
            (@((Get-ChildItem -LiteralPath $own -Force).Name) -join ',') | Should -Be $before
            Test-Path -LiteralPath $logs | Should -Be $logsBefore
        }
    }
}
