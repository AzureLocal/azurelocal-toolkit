#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# scripts/deploy/common/TaskCatalogue.psd1 is the one list of task folders and of whether Azure CLI applies to each.
# These tests keep it in step with the folders: no task without an entry, no entry without a folder, and no Azure CLI folder
# for a task that does not act on Azure. Nothing runs against Azure or a node.
# Run: Invoke-Pester ./tests/deploy-scripts

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeAll {
    $script:Repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:DeployRoot = [System.IO.Path]::Combine($script:Repo, 'scripts', 'deploy')
    $script:Catalogue = Import-PowerShellDataFile -LiteralPath ([System.IO.Path]::Combine($script:DeployRoot, 'common', 'TaskCatalogue.psd1'))
    $script:CommonRoot = [System.IO.Path]::Combine($script:DeployRoot, 'common') + [System.IO.Path]::DirectorySeparatorChar
    $script:TaskFolders = @(
        Get-ChildItem -LiteralPath $script:DeployRoot -Recurse -Directory |
            Where-Object { $_.Name -in 'powershell', 'azurecli', 'bash' -and -not $_.FullName.StartsWith($script:CommonRoot) } |
            ForEach-Object { $_.Parent.FullName.Substring($script:DeployRoot.Length).TrimStart('\', '/').Replace('\', '/') } |
            Select-Object -Unique
    )
    $script:Placeholder = 'Invoke-Deployment(AzCliPowerShell|Orchestrated|Standalone)\b'
}

Describe 'TaskCatalogue.psd1' {
    It 'has a schema version and a list of tasks' {
        $script:Catalogue.SchemaVersion | Should -Be 1
        @($script:Catalogue.Tasks).Count | Should -BeGreaterThan 100
    }

    It 'gives every task a path, an AzureCli value of yes, no or unclear, and a reason' {
        $bad = @($script:Catalogue.Tasks | Where-Object { [string]::IsNullOrWhiteSpace($_.Path) -or $_.AzureCli -notin 'yes', 'no', 'unclear' -or [string]::IsNullOrWhiteSpace($_.Reason) })
        $bad | Should -BeNullOrEmpty
    }

    It 'lists no task twice' {
        $dupes = @($script:Catalogue.Tasks | Group-Object Path | Where-Object Count -gt 1 | ForEach-Object Name)
        $dupes | Should -BeNullOrEmpty
    }

    It 'lists the paths in ordinal order, so a diff of the file is short' {
        $paths = [string[]]@($script:Catalogue.Tasks | ForEach-Object Path)
        $sorted = $paths.Clone()
        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        ($paths -join "`n") | Should -BeExactly ($sorted -join "`n")
    }

    It 'has an entry for every task folder under scripts/deploy' {
        $listed = @($script:Catalogue.Tasks | ForEach-Object Path)
        $missing = @($script:TaskFolders | Where-Object { $_ -notin $listed })
        $missing | Should -BeNullOrEmpty -Because 'a new task folder needs an AzureCli value in TaskCatalogue.psd1'
    }

    It 'has no entry for a folder that is gone' {
        $gone = @($script:Catalogue.Tasks | ForEach-Object Path | Where-Object { $_ -notin $script:TaskFolders })
        $gone | Should -BeNullOrEmpty
    }

    It 'has no azurecli folder for a task that does not act on Azure (AzureCli no)' {
        $found = @(
            foreach ($task in ($script:Catalogue.Tasks | Where-Object AzureCli -eq 'no')) {
                $az = [System.IO.Path]::Combine($script:DeployRoot, $task.Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar), 'azurecli')
                if (Test-Path -LiteralPath $az) { "$($task.Path)/azurecli" }
            }
        )
        $found | Should -BeNullOrEmpty -Because 'a real Azure CLI script means the task acts on Azure: set AzureCli to yes'
    }
}
