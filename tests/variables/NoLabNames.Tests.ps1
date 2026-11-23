#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# D129: the current tree holds no company, lab, hardware or personal account name of the owner's environments. The names are kept only as
# hashes (tests/fixtures/ForbiddenTokens.ps1), so this test names none of them. Git history is out of scope (owner decision D129).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/NoLabNames.Tests.ps1
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    . ([IO.Path]::Combine($PSScriptRoot, '..', 'fixtures', 'ForbiddenTokens.ps1'))
}

Describe 'No lab, company or personal name in the tree (D129)' {
    It 'finds a listed name (the guard works)' {
        # d129-guard-probe is on the list as a test probe; it is no name of anything.
        @(Find-AzlForbiddenToken 'x d129-guard-probe y' -WholeOnly) | Should -Match 'test probe'
    }
    It 'no text file of the tree holds one' {
        $skip = '[\/](\.git|node_modules|\.terraform)[\/]'
        $text = '\.(ps1|psm1|psd1|md|mdx|yml|yaml|json|tf|tfvars|hcl|txt|csv|xml|j2|cfg|conf|ini|drawio|sh|py)$'
        $found = foreach ($f in Get-ChildItem -LiteralPath $script:Repo -Recurse -File | Where-Object { $_.FullName -notmatch $skip -and $_.Name -match $text }) {
            $hits = @(Find-AzlForbiddenToken (Get-Content -LiteralPath $f.FullName -Raw) -WholeOnly | Where-Object { $_ -notmatch '^test probe' })
            if ($hits.Count) { "$([IO.Path]::GetRelativePath($script:Repo, $f.FullName)): $($hits -join ', ')" }
        }
        @($found) | Should -BeNullOrEmpty
    }
}
