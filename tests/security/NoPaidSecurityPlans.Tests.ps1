#Requires -Version 7.0
Set-StrictMode -Version Latest

# Owner rule: the automation turns on only the free level of Microsoft Defender for Cloud that
# Azure Local needs. Nothing paid, no Microsoft Sentinel onboarding. Paid items live only under
# scripts/optional/paid-security-services, which nothing runs.

BeforeDiscovery {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:AutomationFiles = @(
        Get-ChildItem -Path (Join-Path $script:Root 'scripts'), (Join-Path $script:Root 'pipelines'), (Join-Path $script:Root 'src') -Recurse -File -Include *.ps1, *.psm1, *.yml, *.yaml, *.tf |
            Where-Object { $_.FullName -notmatch '[\\/]scripts[\\/]optional[\\/]paid-security-services[\\/]' } |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($script:Root.Length + 1) } }
    )
}

Describe 'No paid security plan is turned on by the automation' {
    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        # Calls that set a Defender pricing tier, turn on agent auto-provisioning or onboard Sentinel.
        $script:Forbidden = @(
            'Set-AzSecurityPricing'
            'Set-AzSecurityAutoProvisioningSetting'
            'az\s+security\s+pricing\s+create'
            'az\s+security\s+auto-provisioning-setting\s+update'
            'Microsoft\.Security/pricings/[^"''\s]+["'']?\s*$'
            'New-AzSentinelOnboardingState'
            'Microsoft\.SecurityInsights/onboardingStates'
            'azurerm_sentinel_log_analytics_workspace_onboarding'
        )
    }

    It '<Name> has no call that turns on a paid plan' -ForEach $script:AutomationFiles {
        $text = Get-Content -LiteralPath $Path -Raw
        if (-not $text) { return }
        foreach ($pattern in $script:Forbidden) {
            $text | Should -Not -Match "(?m)$pattern" -Because "'$pattern' turns on a paid plan; paid items belong in scripts/optional/paid-security-services"
        }
    }

    It 'the Terraform defender_plans variable is empty by default in <_>' -ForEach @(
        'src/terraform/modules/security/variables.tf'
        'src/terraform/environments/azure-local/variables.tf'
    ) {
        $text = Get-Content -LiteralPath (Join-Path $script:Root $_) -Raw
        $block = [regex]::Match($text, '(?s)variable\s+"defender_plans"\s*\{.*?\n\}').Value
        $block | Should -Not -BeNullOrEmpty
        $block | Should -Match '(?m)^\s*default\s*=\s*\{\}\s*$'
    }

    It 'Enable-DefenderForCloud.ps1 reads the two registered keys' {
        $path = Join-Path $script:Root 'scripts/deploy/05-operational-foundations/phase-04-security-governance/task-01-enable-defender-for-cloud/powershell/Enable-DefenderForCloud.ps1'
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match "'security', 'defender_for_cloud', 'enabled'"
        $text | Should -Match "'security', 'defender_for_cloud', 'apply_cloud_security_benchmark'"
    }

    It 'the paid script is run by nothing outside its own folder' {
        $hits = Get-ChildItem -Path (Join-Path $script:Root 'scripts'), (Join-Path $script:Root 'pipelines') -Recurse -File -Include *.ps1, *.psm1, *.yml, *.yaml |
            Where-Object { $_.FullName -notmatch '[\\/]scripts[\\/]optional[\\/]paid-security-services[\\/]' } |
            Select-String -Pattern 'Deploy-DefenderPaidPlans|paid-security-services[\\/]' -List
        # The free script names the folder in its help text only; a reference to the script file itself is not allowed.
        @($hits | Where-Object { $_.Line -match 'Deploy-DefenderPaidPlans' }).Count | Should -Be 0
    }
}
