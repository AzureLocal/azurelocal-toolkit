#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The Lighthouse NSG scripts add an outbound rule for Ubuntu package updates over HTTP (port 80). An old search-and-replace had
# damaged its name (Allow-Outbound-HTTP-Updates became Allow-Outbound-HTazl-Updates). Reads files only.
# Run: Invoke-Pester ./tests/deploy-scripts/NsgRuleNames.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $azure = [System.IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure')
    $script:LighthouseScript = @(
        @{ Path = [System.IO.Path]::Combine($azure, '02-manual-deployment', 'task-06-network-security-groups', 'powershell', 'Deploy-LighthouseNsg.ps1'); Name = 'Deploy-LighthouseNsg.ps1' }
        @{ Path = [System.IO.Path]::Combine($azure, 'task-15-configure-lighthouse', 'powershell', 'Deploy-Lighthouse.ps1'); Name = 'Deploy-Lighthouse.ps1' }
    )
}

Describe 'Lighthouse NSG outbound updates rule' {
    It '<Name> names the rule Allow-Outbound-HTTP-Updates and opens port 80' -ForEach $script:LighthouseScript {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match 'Add-AzNetworkSecurityRuleConfig -Name "Allow-Outbound-HTTP-Updates"'
        $rule = [regex]::Match($text, '(?s)-Name "Allow-Outbound-HTTP-Updates".*?-DestinationPortRange (?<port>\S+)')
        $rule.Groups['port'].Value | Should -Be '80'
    }

    It 'no script keeps the damaged name' {
        $scripts = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts')
        $hit = @(Get-ChildItem -LiteralPath $scripts -Recurse -File -Filter '*.ps1' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'HTazl' } | ForEach-Object Name)
        $hit | Should -BeNullOrEmpty
    }
}
