#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Owner decision O10: a placeholder script (exit code 3, NOT IMPLEMENTED) that no published Implementation guide page names is removed, with its registry
# group, its status row and, when no page names the task folder either, the task folder and its catalogue row. The real scripts that do the job are named
# by the guide pages (OS configuration, pre-cluster verification, post-deployment verification, the real script of the task folder).
# These tests read files; nothing is run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/PlaceholdersRemoved.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $deploy = [IO.Path]::Combine([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..')), 'scripts', 'deploy')
    # Task = folder relative to scripts/deploy; Name = the removed file; FolderGone = the task folder went with it (no page names the task).
    $script:Removed = @(
        @{ Task = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-01-configure-core-variables'; Name = 'Invoke-CoreVariables-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-02-configure-management-mode'; Name = 'Invoke-ManagementMode-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-01-commit-and-push'; Name = 'Invoke-CommitAndPush-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '02-azure-foundation/phase-04-azure-management-infrastructure/task-12-configure-adds'; Name = 'Invoke-DomainController-Orchestrated.ps1'; FolderGone = $true }
        @{ Task = '02-azure-foundation/phase-04-azure-management-infrastructure/task-13-configure-utility-server'; Name = 'Invoke-JumpServer-Orchestrated.ps1'; FolderGone = $true }
        @{ Task = '02-azure-foundation/phase-04-azure-management-infrastructure/task-14-configure-ndm-server'; Name = 'Invoke-NdmServer-Orchestrated.ps1'; FolderGone = $true }
        @{ Task = '02-azure-foundation/phase-04-azure-management-infrastructure/task-15-configure-lighthouse'; Name = 'Invoke-Lighthouse-Orchestrated.ps1'; FolderGone = $true }
        @{ Task = '03-onprem-readiness/phase-01-active-directory/task-02-security-groups'; Name = 'Invoke-ADSecurityGroups-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-01-active-directory/task-03-dns-node-a-records'; Name = 'Invoke-DnsForwarding-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-01-active-directory/task-05-group-assignments'; Name = 'Invoke-ADGroupMemberships-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-02-enterprise-readiness/task-01-hardware-inspection'; Name = 'Invoke-HardwareInspection-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-02-enterprise-readiness/task-02-network-service-verification'; Name = 'Invoke-InfrastructurePrep-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-02-enterprise-readiness/task-03-opengear-verification'; Name = 'Invoke-OpengearVerification-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-02-enterprise-readiness/task-04-validation-signoff'; Name = 'Invoke-ValidationSignoff-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-03-network-infrastructure/task-01-opengear-console-server'; Name = 'Invoke-OpengearEndpoint-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-03-network-infrastructure/task-02-dell-powerswitch-configuration'; Name = 'Invoke-PowerSwitchEndpoint-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-03-network-infrastructure/task-03-firewall-endpoint-verification'; Name = 'Invoke-FirewallEndpoint-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '03-onprem-readiness/phase-03-network-infrastructure/task-04-network-validation'; Name = 'Invoke-NetworkReadiness-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api'; Name = 'Invoke-HardwareDiscovery-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-01-hardware-provisioning/task-04-bios-and-idrac-settings-validation'; Name = 'Invoke-BiosIdracValidation-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-01-hardware-provisioning/task-05-bios-and-idrac-settings-remediation'; Name = 'Invoke-BiosIdracRemediation-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-02-os-installation/task-01-delete-and-recreate-virtual-disk-on-dell-boss-card'; Name = 'Invoke-ResetBossVirtualDisk-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-02-os-installation/task-02-mount-and-verify-dell-gold-image-iso'; Name = 'Invoke-MountGoldImageISO-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-02-os-installation/task-04-verify-os-deployment'; Name = 'Invoke-OsDeploymentVerification-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-01-enable-winrm-for-remote-management'; Name = 'Invoke-EnableWinRm-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-02-enable-rdp'; Name = 'Invoke-EnableRdp-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-03-configure-static-ip-address'; Name = 'Invoke-ConfigureStaticIP-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-04-disable-dhcp-on-management-adapter'; Name = 'Invoke-DisableDHCP-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-05-configure-dns-servers'; Name = 'Invoke-ConfigureDNS-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-06-verify-dns-client-configuration'; Name = 'Invoke-VerifyDNS-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-07-configure-time-synchronization-ntp'; Name = 'Invoke-ConfigureNTP-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-08-enable-icmp-ping'; Name = 'Invoke-EnableICMP-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-09-disable-unused-network-adapters'; Name = 'Invoke-DisableAdapters-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-10-configure-hostname'; Name = 'Invoke-ConfigureHostname-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-03-os-configuration/task-11-clear-previous-storage-configuration-conditional'; Name = 'Invoke-ClearStorage-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-02-verify-deployment-completion'; Name = 'Invoke-VerifyADDomainStatus-Orchestrated.ps1'; FolderGone = $false }
        @{ Task = '04-cluster-deployment/phase-05-cluster-deployment/local-identity/task-01-initiate-deployment-via-arm-template'; Name = 'Invoke-DeployCluster-Orchestrated.ps1'; FolderGone = $false }
    ) | ForEach-Object {
        $task = [IO.Path]::Combine($deploy, $_.Task.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $_ + @{ TaskPath = $task; FilePath = [IO.Path]::Combine($task, 'powershell', $_.Name) }
    }
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Registry = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
    $script:Catalogue = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', 'common', 'TaskCatalogue.psd1'))
    $script:StatusPage = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'docs', 'script-status.md')) -Raw
}

Describe 'Placeholders that no guide page names are removed (O10)' {
    It '<Name> is gone from <Task>' -ForEach $script:Removed {
        Test-Path -LiteralPath $FilePath | Should -BeFalse
    }

    It 'the task folder <Task> is gone with its catalogue row and its status row when no page names the task' -ForEach @($script:Removed | Where-Object { $_.FolderGone }) {
        Test-Path -LiteralPath $TaskPath | Should -BeFalse
        @($script:Catalogue.Tasks | Where-Object Path -EQ $Task).Count | Should -Be 0
        $script:StatusPage | Should -Not -Match ('`' + [regex]::Escape(($Task -replace '^[^/]+/', '')) + '`')
    }

    It 'the task folder <Task> stays (a page names it) with its catalogue row and no placeholder' -ForEach @($script:Removed | Where-Object { -not $_.FolderGone }) {
        Test-Path -LiteralPath $TaskPath | Should -BeTrue
        @($script:Catalogue.Tasks | Where-Object Path -EQ $Task).Count | Should -Be 1
        $left = @(Get-ChildItem -LiteralPath $TaskPath -Recurse -File -Filter '*.ps1' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^# PLACEHOLDER:|\bInvoke-Deployment(AzCliPowerShell|Orchestrated|Standalone)\b' })
        $left | Should -BeNullOrEmpty
    }

    It 'the registry has no parameter group for <Name>' -ForEach @($script:Removed | Sort-Object { $_.Name } -Unique) {
        $script:Registry | Should -Not -Match ('area:\s*"[^"]*/' + [regex]::Escape($Name) + '"')
    }

    It 'no script, document or pipeline names <Name>, except the places that record a removal' -ForEach @($script:Removed | Sort-Object { $_.Name } -Unique) {
        $hit = @(Get-ChildItem -LiteralPath $script:Repo -Recurse -File -Include *.ps1, *.psm1, *.md, *.yml, *.yaml, *.json -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\/](\.git|node_modules|deferred)[\/]' -and $_.Name -notin 'CHANGELOG.md', 'MIGRATION.md', 'master-registry.yaml' -and $_.Name -notlike '*.Tests.ps1' } |
                Select-String -SimpleMatch $Name | Where-Object { $_.Line -notmatch 'removed|Removed|earlier|replaced' } |
                ForEach-Object { "$($_.Path.Substring($script:Repo.Length)):$($_.LineNumber)" })
        $hit | Should -BeNullOrEmpty
    }
}
