#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# K2 batch 3: a placeholder (exit code 3, "NOT IMPLEMENTED") goes when a real script of the same task folder does the task. These four were retired;
# the script that does the job instead is there, is not a placeholder, and the task folder keeps its catalogue entry. The network device monitoring
# server task keeps its placeholder on purpose: in the public route that server is the syslog collector, and syslog forwarding is parked.
# These tests read files; nothing is run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/RetiredPlaceholders.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $deploy = [IO.Path]::Combine([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..')), 'scripts', 'deploy')
    $ad = '03-onprem-readiness/phase-01-active-directory'
    $mon = '05-operational-foundations/phase-02-monitoring-observability'
    $script:Retired = @(
        @{ Task = "$ad/task-01-ou-creation-pre-creation-artifacts"; Gone = 'Invoke-ADConfiguration-Orchestrated.ps1'; Instead = 'Set-ADConfiguration.ps1'; Why = 'it prepares the OU (and its missing parents when the file says so) and the LCM user with New-HciAdObjectsPreCreation' }
        @{ Task = "$ad/task-04-service-admin-accounts"; Gone = 'Invoke-ADAccounts-Orchestrated.ps1'; Instead = 'New-ADAccounts.ps1'; Why = 'it creates the domain join account; task 01 creates the LCM user' }
        @{ Task = "$mon/task-02-configure-azure-monitor-agent"; Gone = 'Invoke-AzureMonitorIntegration-Orchestrated.ps1'; Instead = 'Install-AzureMonitorAgent.ps1'; Why = 'it installs the agent; the Insights rule is checked and associated by task 03' }
        @{ Task = "$mon/task-03-enable-hci-insights"; Gone = 'Invoke-HciInsights-Orchestrated.ps1'; Instead = 'Enable-HciInsights.ps1'; Why = 'it checks the Insights rule and associates it with every node; the Insights views are Azure''s own' }
    ) | ForEach-Object {
        $folder = [IO.Path]::Combine($deploy, $_.Task.Replace('/', [IO.Path]::DirectorySeparatorChar), 'powershell')
        $_ + @{ GonePath = [IO.Path]::Combine($folder, $_.Gone); InsteadPath = [IO.Path]::Combine($folder, $_.Instead) }
    }
    $script:Kept = @(
        @{ Task = '02-azure-foundation/phase-04-azure-management-infrastructure/task-14-configure-ndm-server'; Name = 'Invoke-NdmServer-Orchestrated.ps1' }
    ) | ForEach-Object { $_ + @{ Path = [IO.Path]::Combine($deploy, $_.Task.Replace('/', [IO.Path]::DirectorySeparatorChar), 'powershell', $_.Name) } }
}

BeforeAll {
    $script:Catalogue = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'deploy', 'common', 'TaskCatalogue.psd1'))
    $script:PlaceholderPattern = '(?m)^# PLACEHOLDER:|\b(Invoke-Deployment(AzCliPowerShell|Orchestrated|Standalone)|Stop-DeploymentPlaceholder)\b'
}

Describe 'Placeholders retired in K2 batch 3' {
    It '<Gone> is gone from <Task>' -ForEach $script:Retired {
        Test-Path -LiteralPath $GonePath | Should -BeFalse
    }
    It '<Instead> does the job instead, because <Why>' -ForEach $script:Retired {
        Test-Path -LiteralPath $InsteadPath | Should -BeTrue
        (Get-Content -LiteralPath $InsteadPath -Raw) | Should -Not -Match $script:PlaceholderPattern
    }
    It '<Task> keeps its catalogue entry and holds no other placeholder' -ForEach $script:Retired {
        @($script:Catalogue.Tasks | Where-Object Path -EQ $Task).Count | Should -Be 1
        $left = @(Get-ChildItem -LiteralPath (Split-Path -Parent $InsteadPath) -Filter '*.ps1' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $script:PlaceholderPattern })
        $left | Should -BeNullOrEmpty
    }
}

Describe 'Placeholders kept on purpose' {
    It '<Name> stays a placeholder: the task is the syslog collector of network devices, which is parked' -ForEach $script:Kept {
        Test-Path -LiteralPath $Path | Should -BeTrue
        (Get-Content -LiteralPath $Path -Raw) | Should -Match $script:PlaceholderPattern
        ($script:Catalogue.Tasks | Where-Object Path -EQ $Task).Reason | Should -Match 'syslog'
    }
}
