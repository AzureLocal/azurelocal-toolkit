#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Research row "REPLACE_NODE_IP": a script of the deploy tree carried REPLACE_ (or <PLACEHOLDER>) text that a person had to type into it: the node addresses, the
# adapter name, the DNS servers, the host name. The values are in infrastructure.yml, and a script that reads the file does the same work, so these scripts are removed:
#   phase 05  Test-ADPrerequisites-Standalone.ps1, Test-ADDomainStatus-Standalone.ps1, Test-ClusterHealth-Standalone.ps1 (two identities), Test-LocalIdentityConfig-Standalone.ps1
#   phase 03  Set-StaticIPAddress.ps1, Set-DnsServers.ps1, Set-NTPConfiguration.ps1, Set-NodeHostname.ps1
# These tests check that each one is gone, that the script that replaces it is there, that nothing names it (except the places that record a removal), and that
# no script outside scripts/deferred holds placeholder text of this kind. Nothing here runs a script.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/PlaceholderScripts.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $cluster = [IO.Path]::Combine($repoRoot, 'scripts', 'deploy', '04-cluster-deployment')
    $p05 = [IO.Path]::Combine($cluster, 'phase-05-cluster-deployment')
    $p03 = [IO.Path]::Combine($cluster, 'phase-03-os-configuration')
    $script:Removed = @(
        @{ Name = 'Test-ADPrerequisites-Standalone.ps1'; Folder = [IO.Path]::Combine($p05, 'active-directory', 'task-01-initiate-deployment-via-arm-template', 'powershell'); Instead = [IO.Path]::Combine($repoRoot, 'scripts', 'common', 'arm-deployment', 'AzlPreClusterVerification.psm1') }
        @{ Name = 'Test-ADDomainStatus-Standalone.ps1'; Folder = [IO.Path]::Combine($p05, 'active-directory', 'task-02-verify-deployment-completion', 'powershell'); Instead = [IO.Path]::Combine($cluster, 'phase-06-post-deployment', 'task-09-post-deployment-verification', 'powershell', 'Invoke-VerifyPostDeployment.ps1') }
        @{ Name = 'Test-ClusterHealth-Standalone.ps1'; Folder = [IO.Path]::Combine($p05, 'active-directory', 'task-02-verify-deployment-completion', 'powershell'); Instead = [IO.Path]::Combine($cluster, 'phase-06-post-deployment', 'task-09-post-deployment-verification', 'powershell', 'Invoke-VerifyPostDeployment.ps1') }
        @{ Name = 'Test-ClusterHealth-Standalone.ps1'; Folder = [IO.Path]::Combine($p05, 'local-identity', 'task-02-verify-deployment-completion', 'powershell'); Instead = [IO.Path]::Combine($cluster, 'phase-06-post-deployment', 'task-09-post-deployment-verification', 'powershell', 'Invoke-VerifyPostDeployment.ps1') }
        @{ Name = 'Test-LocalIdentityConfig-Standalone.ps1'; Folder = [IO.Path]::Combine($p05, 'local-identity', 'task-02-verify-deployment-completion', 'powershell'); Instead = [IO.Path]::Combine($cluster, 'phase-06-post-deployment', 'task-09-post-deployment-verification', 'powershell', 'Invoke-VerifyPostDeployment.ps1') }
        @{ Name = 'Set-StaticIPAddress.ps1'; Folder = [IO.Path]::Combine($p03, 'task-03-configure-static-ip-address', 'powershell'); Instead = [IO.Path]::Combine($p03, 'Set-AzureLocalNodeConfiguration.ps1') }
        @{ Name = 'Set-DnsServers.ps1'; Folder = [IO.Path]::Combine($p03, 'task-05-configure-dns-servers', 'powershell'); Instead = [IO.Path]::Combine($p03, 'Set-AzureLocalNodeConfiguration.ps1') }
        @{ Name = 'Set-NTPConfiguration.ps1'; Folder = [IO.Path]::Combine($p03, 'task-07-configure-time-synchronization-ntp', 'powershell'); Instead = [IO.Path]::Combine($p03, 'Set-AzureLocalNodeConfiguration.ps1') }
        @{ Name = 'Set-NodeHostname.ps1'; Folder = [IO.Path]::Combine($p03, 'task-10-configure-hostname', 'powershell'); Instead = [IO.Path]::Combine($p03, 'Set-AzureLocalNodeConfiguration.ps1') }
    )
    # The task folders that stay: the catalogue lists them and an Orchestrated wrapper is still in each.
    $script:KeptTask = @(
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-03-configure-static-ip-address' }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-05-configure-dns-servers' }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-07-configure-time-synchronization-ntp' }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-10-configure-hostname' }
        @{ Task = '04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-01-initiate-deployment-via-arm-template' }
        @{ Task = '04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-02-verify-deployment-completion' }
        @{ Task = '04-cluster-deployment/phase-05-cluster-deployment/local-identity/task-02-verify-deployment-completion' }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Registry = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
    function Get-LiveFile {
        # every text file of the repository that is not git, node_modules, the parked scripts or a generated report
        Get-ChildItem -LiteralPath $script:Repo -Recurse -File -Include *.ps1, *.psm1, *.psd1, *.md, *.yml, *.yaml, *.json -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|deferred)[\\/]' }
    }
}

Describe 'The scripts with typed-in placeholder text are removed' {
    It '<Name> is gone from <Folder>' -ForEach $script:Removed {
        Test-Path -LiteralPath ([IO.Path]::Combine($Folder, $Name)) | Should -BeFalse
    }

    It 'the script that does the job instead of <Name> is still there' -ForEach $script:Removed {
        Test-Path -LiteralPath $Instead | Should -BeTrue
    }

    It 'the script that does the job instead of <Name> reads the node addresses from the infrastructure file' -ForEach $script:Removed {
        $text = Get-Content -LiteralPath $Instead -Raw
        $text | Should -Match 'Get-AzlInfrastructureNode|Import-AzlInfrastructure|ConvertFrom-Yaml'
        $text | Should -Not -Match 'REPLACE_'
    }

    It 'the task folder <Task> keeps its Orchestrated wrapper and its catalogue entry' -ForEach $script:KeptTask {
        $catalogue = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', 'common', 'TaskCatalogue.psd1'))
        @($catalogue.Tasks | Where-Object { $_.Path -eq $Task }).Count | Should -Be 1
        $folder = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', $Task.Replace('/', [IO.Path]::DirectorySeparatorChar), 'powershell')
        @(Get-ChildItem -LiteralPath $folder -Filter '*-Orchestrated.ps1').Count | Should -BeGreaterThan 0
    }

    It 'the registry has no parameter group for <Name>' -ForEach @($script:Removed | Sort-Object { $_.Name } -Unique) {
        $script:Registry | Should -Not -Match ('area:\s*"[^"]*/' + [regex]::Escape($Name) + '"')
        $script:Registry | Should -Not -Match ('_' + [regex]::Escape($Name.Replace('-', '_').Replace('.', '_')) + '(_generated)?:')
    }

    It 'no script, document or test names <Name>, except the places that record a removal' -ForEach @($script:Removed | Sort-Object { $_.Name } -Unique) {
        $hit = @(Get-LiveFile | Where-Object {
                $_.Name -notin 'CHANGELOG.md', 'MIGRATION.md', 'master-registry.yaml', 'PlaceholderScripts.Tests.ps1' -and $_.Name -notlike '*.Tests.ps1'
            } | Select-String -SimpleMatch $Name -List | ForEach-Object { $_.Path })
        # The READMEs of phase 03 say which scripts were removed and why; that sentence is the only place that names them.
        @($hit | Where-Object { $_ -notmatch 'phase-03-os-configuration[\\/](task-03-configure-static-ip-address[\\/])?README\.md$' }) | Should -BeNullOrEmpty
    }
}

Describe 'No script outside scripts/deferred carries placeholder text for a person to fill in' {
    It 'no script has REPLACE_ text or an angle-bracket placeholder such as <NODE_IP_1>' {
        $pattern = 'REPLACE_|<NODE_IP|<DOMAIN_FQDN>|<DOMAIN_OU_PATH>|<LCM_USERNAME>|<CLUSTER_NAME>'
        $offenders = foreach ($f in Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts')) -Recurse -File -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '[\\/]deferred[\\/]' }) {
            $m = Select-String -LiteralPath $f.FullName -Pattern $pattern -List
            if ($m) { "$($f.FullName.Substring($script:Repo.Length + 1)): line $($m.LineNumber)" }
        }
        @($offenders) | Should -BeNullOrEmpty
    }

    It 'the check finds placeholder text (it is not empty by accident)' {
        'param([string]$NodeIP = "REPLACE_NODE_01_IP")' | Should -Match 'REPLACE_'
        '$nodeIPs = @("<NODE_IP_1>", "<NODE_IP_2>")' | Should -Match '<NODE_IP'
    }
}
