#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# An old search-and-replace had damaged the name of an outbound NSG rule (Allow-Outbound-HTTP-Updates became Allow-Outbound-HTazl-Updates).
# The two Lighthouse scripts that carried the rule are removed (the management VMs come from landing_zone.virtual_machines[]); the guard
# stays: no script may carry the damaged name. Reads files only.
# Run: Invoke-Pester ./tests/deploy-scripts/NsgRuleNames.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

Describe 'NSG rule names' {
    It 'no script keeps the damaged name' {
        $scripts = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts')
        $hit = @(Get-ChildItem -LiteralPath $scripts -Recurse -File -Filter '*.ps1' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'HTazl' } | ForEach-Object Name)
        $hit | Should -BeNullOrEmpty
    }
}
