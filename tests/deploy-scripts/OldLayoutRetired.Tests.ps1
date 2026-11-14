#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The old layout is retired in the cluster deployment area: no script of scripts/deploy/04-cluster-deployment, scripts/common/node-configuration,
# scripts/common/arm-deployment, scripts/common/idrac-management or scripts/common/redfish takes -ConfigPath, asks for a value (Read-Host, Get-Credential) or reads
# an old-shape file. The scripts that a schema 5 script replaces are removed; each task folder keeps a placeholder (exit code 3) where no real script is left; the
# scripts that stay take -InfrastructureFile (mandatory) and stop with exit code 2 when it cannot be read. Child processes are used for the exit codes; nothing is
# contacted (every file name here does not exist, so each script stops before it reaches a BMC, a node or Azure).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/OldLayoutRetired.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $cluster = [IO.Path]::Combine($repoRoot, 'scripts', 'deploy', '04-cluster-deployment')
    $p3 = 'phase-03-os-configuration'
    $p4 = 'phase-04-arc-registration'
    $p5 = 'phase-05-cluster-deployment'
    $node = "$p3/Set-AzureLocalNodeConfiguration.ps1"
    $arm = "$p5/Invoke-AzureLocalArmDeployment.ps1"
    $pre = "$p5/Invoke-AzureLocalPreClusterVerification.ps1"
    $post = 'phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-VerifyPostDeployment.ps1'
    # Removed script -> the script that does the job now (relative to scripts/deploy/04-cluster-deployment).
    $script:Removed = @(
        @{ Gone = "$p3/task-02-enable-rdp/powershell/Enable-RDP.ps1"; Instead = $node }
        @{ Gone = "$p3/task-04-disable-dhcp-on-management-adapter/powershell/Disable-DHCPOnAllAdapters.ps1"; Instead = $node }
        @{ Gone = "$p3/task-06-verify-dns-client-configuration/powershell/Test-DnsConfiguration.ps1"; Instead = $node }
        @{ Gone = "$p3/task-08-enable-icmp-ping/powershell/Enable-ICMPFirewallRule.ps1"; Instead = $node }
        @{ Gone = "$p3/task-09-disable-unused-network-adapters/powershell/Disable-UnusedAdapters.ps1"; Instead = $node }
        @{ Gone = "$p3/task-11-clear-previous-storage-configuration-conditional/powershell/Clear-StorageConfiguration.ps1"; Instead = $node }
        @{ Gone = "$p3/task-11-clear-previous-storage-configuration-conditional/powershell/Clear-StorageConfiguration-Direct.ps1"; Instead = $node }
        @{ Gone = "$p4/task-01-pre-registration-validation/powershell/Test-ArcPrerequisites.ps1"; Instead = $pre }
        @{ Gone = "$p4/task-01-pre-registration-validation/powershell/Test-ArcPrerequisites-Orchestrated.ps1"; Instead = $pre }
        @{ Gone = "$p4/task-02-register-cluster-nodes-with-azure-arc/powershell/Register-AzureLocalArc-Remote.ps1"; Instead = $node }
        @{ Gone = "$p4/task-02-register-cluster-nodes-with-azure-arc/powershell/Register-NodesWithArc.ps1"; Instead = $node }
        @{ Gone = "$p4/task-04-verify-arc-registration-and-connectivity/powershell/Confirm-ArcRegistration.ps1"; Instead = $pre }
        @{ Gone = "$p4/task-04-verify-arc-registration-and-connectivity/powershell/Confirm-ArcRegistration-Orchestrated.ps1"; Instead = $pre }
        @{ Gone = 'phase-02-os-installation/task-04-verify-os-deployment/powershell/Test-OsDeployment.ps1'; Instead = $pre }
        @{ Gone = "$p5/active-directory/task-01-initiate-deployment-via-arm-template/powershell/Deploy-AzureLocalCluster.ps1"; Instead = $arm }
        @{ Gone = "$p5/active-directory/task-01-initiate-deployment-via-arm-template/powershell/Deploy-AzureLocalCluster-Standalone.ps1"; Instead = $arm }
        @{ Gone = "$p5/active-directory/task-01-initiate-deployment-via-arm-template/powershell/Get-HciResourceProviderObjectId.ps1"; Instead = $arm }
        @{ Gone = "$p5/active-directory/task-01-initiate-deployment-via-arm-template/powershell/Get-HciResourceProviderObjectId-Standalone.ps1"; Instead = $arm }
        @{ Gone = "$p5/local-identity/task-01-initiate-deployment-via-arm-template/powershell/Deploy-AzureLocalCluster.ps1"; Instead = $arm }
        @{ Gone = "$p5/local-identity/task-01-initiate-deployment-via-arm-template/powershell/Deploy-AzureLocalCluster-Standalone.ps1"; Instead = $arm }
        @{ Gone = "$p5/local-identity/task-01-initiate-deployment-via-arm-template/powershell/Get-HciResourceProviderObjectId.ps1"; Instead = $arm }
        @{ Gone = "$p5/local-identity/task-01-initiate-deployment-via-arm-template/powershell/Get-HciResourceProviderObjectId-Standalone.ps1"; Instead = $arm }
        @{ Gone = "$p5/local-identity/task-01-initiate-deployment-via-azure-portal/powershell/Deploy-CreateLocalAdmin.ps1"; Instead = $node }
        @{ Gone = "$p5/active-directory/task-02-verify-deployment-completion/powershell/Invoke-VerifyClusterHealth-Orchestrated.ps1"; Instead = $post }
        @{ Gone = "$p5/active-directory/task-02-verify-deployment-completion/powershell/Test-ClusterHealth.ps1"; Instead = $post }
        @{ Gone = "$p5/active-directory/task-02-verify-deployment-completion/powershell/Test-ADDomainStatus.ps1"; Instead = $post }
        @{ Gone = "$p5/local-identity/task-02-verify-deployment-completion/powershell/Invoke-VerifyClusterHealth-Orchestrated.ps1"; Instead = $post }
        @{ Gone = "$p5/local-identity/task-02-verify-deployment-completion/powershell/Test-ClusterHealth.ps1"; Instead = $post }
        @{ Gone = "$p5/local-identity/task-02-verify-deployment-completion/powershell/Test-LocalIdentityConfig.ps1"; Instead = $post }
        @{ Gone = 'phase-06-post-deployment/task-04-ssh-connectivity-to-nodes/powershell/Enable-SshConfiguration.ps1'; Instead = 'phase-06-post-deployment/task-04-ssh-connectivity-to-nodes/powershell/Invoke-SSHConnectivity-Orchestrated.ps1' }
    )
    $script:RemovedCase = @($script:Removed | ForEach-Object { @{ Name = [IO.Path]::GetFileName($_.Gone); Gone = [IO.Path]::Combine($cluster, $_.Gone.Replace('/', [IO.Path]::DirectorySeparatorChar)); Instead = [IO.Path]::Combine($cluster, $_.Instead.Replace('/', [IO.Path]::DirectorySeparatorChar)) } })

    # The scripts that became the placeholder of a task folder whose work a schema 5 script does (relative to the cluster folder).
    $script:Placeholder = @(
        "$p3/task-02-enable-rdp/powershell/Invoke-EnableRdp-Orchestrated.ps1"
        "$p3/task-03-configure-static-ip-address/powershell/Invoke-ConfigureStaticIP-Orchestrated.ps1"
        "$p3/task-04-disable-dhcp-on-management-adapter/powershell/Invoke-DisableDHCP-Orchestrated.ps1"
        "$p3/task-05-configure-dns-servers/powershell/Invoke-ConfigureDNS-Orchestrated.ps1"
        "$p3/task-06-verify-dns-client-configuration/powershell/Invoke-VerifyDNS-Orchestrated.ps1"
        "$p3/task-07-configure-time-synchronization-ntp/powershell/Invoke-ConfigureNTP-Orchestrated.ps1"
        "$p3/task-08-enable-icmp-ping/powershell/Invoke-EnableICMP-Orchestrated.ps1"
        "$p3/task-09-disable-unused-network-adapters/powershell/Invoke-DisableAdapters-Orchestrated.ps1"
        "$p3/task-10-configure-hostname/powershell/Invoke-ConfigureHostname-Orchestrated.ps1"
        "$p3/task-11-clear-previous-storage-configuration-conditional/powershell/Invoke-ClearStorage-Orchestrated.ps1"
        "$p3/task-13-phase03-verification/powershell/Invoke-Phase03Verification-Orchestrated.ps1"
        "$p4/task-01-pre-registration-validation/powershell/Invoke-ArcPrerequisites-Orchestrated.ps1"
        "$p4/task-02-register-cluster-nodes-with-azure-arc/powershell/Invoke-ArcRegistration-Orchestrated.ps1"
        "$p4/task-02-register-cluster-nodes-with-azure-arc/azurecli/Register-AzureLocalArc.ps1"
        "$p4/task-04-verify-arc-registration-and-connectivity/powershell/Invoke-ArcVerification-Orchestrated.ps1"
        "$p5/active-directory/task-01-initiate-deployment-via-arm-template/powershell/Invoke-VerifyADPrerequisites-Orchestrated.ps1"
        "$p5/active-directory/task-02-verify-deployment-completion/powershell/Invoke-VerifyADDomainStatus-Orchestrated.ps1"
        "$p5/local-identity/task-01-initiate-deployment-via-arm-template/azurecli/az-deploy-cluster.ps1"
        "$p5/local-identity/task-01-initiate-deployment-via-azure-portal/powershell/Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1"
        "$p5/local-identity/task-02-verify-deployment-completion/powershell/Invoke-VerifyLocalIdentityConfig-Orchestrated.ps1"
        'phase-06-post-deployment/task-02-cluster-quorum-configuration/powershell/Invoke-ConfigureClusterQuorum-Orchestrated.ps1'
    ) | ForEach-Object { @{ Name = [IO.Path]::GetFileName($_); Path = [IO.Path]::Combine($cluster, $_.Replace('/', [IO.Path]::DirectorySeparatorChar)) } }

    # The scripts that stay: relative path (to the repository), what they do when the file cannot be read.
    $script:Kept = @(
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Invoke-HardwareDiscovery.ps1'
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Update-InfrastructureYml-FromDiscovery.ps1'
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-04-bios-and-idrac-settings-validation/powershell/Test-BiosIdracSettings.ps1'
        'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-05-bios-and-idrac-settings-remediation/powershell/Set-BiosIdracSettings.ps1'
        'scripts/deploy/04-cluster-deployment/phase-02-os-installation/task-01-delete-and-recreate-virtual-disk-on-dell-boss-card/powershell/Invoke-ResetBossVirtualDisk.ps1'
        'scripts/deploy/04-cluster-deployment/phase-02-os-installation/task-02-mount-and-verify-dell-gold-image-iso/powershell/Invoke-MountGoldImageISO.ps1'
        'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-03-security-groups-applied-to-nodes/powershell/Invoke-ApplySecurityGroups-Orchestrated.ps1'
        'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-04-ssh-connectivity-to-nodes/powershell/Invoke-SSHConnectivity-Orchestrated.ps1'
        'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-VerifyPostDeployment.ps1'
        'scripts/common/idrac-management/Enable-IdracVnc.ps1'
    ) | ForEach-Object { @{ Name = [IO.Path]::GetFileName($_); Relative = $_ } }
    # These stop with exit code 2 when the file cannot be read (the SSH script throws, which a pipeline sees as 1).
    $script:ExitTwo = @($script:Kept | Where-Object { $_.Name -ne 'Invoke-SSHConnectivity-Orchestrated.ps1' })
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Cluster = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment')
    function Get-OwnScript {
        # every .ps1 and .psm1 of the area this change covers (the parked scripts and the placeholders' module are not part of it)
        foreach ($root in 'scripts/deploy/04-cluster-deployment', 'scripts/common/node-configuration', 'scripts/common/arm-deployment', 'scripts/common/idrac-management', 'scripts/common/redfish') {
            Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, $root.Replace('/', [IO.Path]::DirectorySeparatorChar))) -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }
        }
    }
    function Get-Parse([string]$Path) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        [pscustomobject]@{ Ast = $ast; Tokens = $tokens; Errors = $errors }
    }
    function Invoke-Child([string]$Path, [string[]]$Arguments) {
        $out = & pwsh -NoProfile -NonInteractive -File $Path @Arguments 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
    }
}

Describe 'The scripts that a schema 5 script replaces are removed' {
    It '<Name> is gone' -ForEach $script:RemovedCase {
        Test-Path -LiteralPath $Gone | Should -BeFalse
    }
    It 'the script that does the job instead of <Name> is still there' -ForEach $script:RemovedCase {
        Test-Path -LiteralPath $Instead | Should -BeTrue
    }
    It 'no document, script, pipeline or role still tells a reader to run <Name>' -ForEach @($script:RemovedCase | Sort-Object { $_.Name } -Unique) {
        $hits = @(Get-ChildItem -LiteralPath $script:Repo -Recurse -File -Include *.ps1, *.psm1, *.md, *.yml, *.yaml -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|deferred|reports|validation)[\\/]' -and $_.Name -notin 'CHANGELOG.md', 'MIGRATION.md', 'master-registry.yaml', 'variable-map.csv', 'OldLayoutRetired.Tests.ps1', 'PlaceholderScripts.Tests.ps1', 'variables-audit-tasks.md', 'VARIABLE-MAP.md', 'HANDOFF.md' } |
                Select-String -SimpleMatch $Name | Where-Object { $_.Line -notmatch '\(removed\)|removed|Removed|earlier|replaced' } | ForEach-Object { "$($_.Path.Substring($script:Repo.Length)):$($_.LineNumber)" })
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'A task folder whose script a schema 5 script replaces keeps a placeholder' {
    It '<Name> is a placeholder that takes -InfrastructureFile and ends with exit code 3' -ForEach $script:Placeholder {
        Test-Path -LiteralPath $Path | Should -BeTrue
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match '# PLACEHOLDER: this script does not do the task'
        $text | Should -Match "\[string\]\`$InfrastructureFile = ''"
        $text | Should -Not -Match 'ConfigPath'
        $r = Invoke-Child $Path @('-InfrastructureFile', (Join-Path ([IO.Path]::GetTempPath()) 'does-not-exist.yml'))
        $r.Code | Should -Be 3 -Because $r.Output
        $r.Output | Should -Match 'NOT IMPLEMENTED'
    }
}

Describe 'No script of the area takes -ConfigPath or asks for a value' {
    It 'no script of the area has a ConfigPath parameter, variable or argument, and every one parses' {
        $bad = foreach ($f in Get-OwnScript) {
            $p = Get-Parse $f.FullName
            if ($p.Errors.Count -gt 0) { "$($f.FullName.Substring($script:Repo.Length)): parse error" }
            $hit = @($p.Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'ConfigPath') -or ($n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'ConfigPath') }, $true))
            if ($hit.Count -gt 0) { "$($f.FullName.Substring($script:Repo.Length)): ConfigPath at line $($hit[0].Extent.StartLineNumber)" }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It 'no script of the area calls Read-Host or Get-Credential, or reads the host for a value' {
        $bad = foreach ($f in Get-OwnScript) {
            $p = Get-Parse $f.FullName
            $calls = @($p.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
            foreach ($c in $calls) {
                $name = $c.GetCommandName()
                if ($name -in 'Read-Host', 'Get-Credential') { "$($f.FullName.Substring($script:Repo.Length)): $name at line $($c.Extent.StartLineNumber)" }
            }
            # The approval gate of the ARM run (deployment.approval) asks yes or no before a deployment starts, never for a value: tests/variables/enforcement-allowlist.psd1 records it.
            $prompt = @($p.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -match '^(Prompt|ReadLine|PromptForCredential)' -and -not ($f.Name -eq 'AzlArmDeploymentRun.psm1' -and $n.Member.Value -eq 'PromptForChoice') }, $true))
            if ($prompt.Count -gt 0) { "$($f.FullName.Substring($script:Repo.Length)): host prompt at line $($prompt[0].Extent.StartLineNumber)" }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It 'the BMC login reader never asks and has no -NoPrompt switch' {
        $text = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')) -Raw
        $text | Should -Not -Match 'NoPrompt'
    }
    It 'no script of the area reads the old layout file or the old loader' {
        $bad = foreach ($f in Get-OwnScript) {
            $p = Get-Parse $f.FullName
            $code = ($p.Tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
            if ($code -match 'config-loader|Get-SolutionConfig|variables\.yml|configs\\infrastructure|ConvertFrom-Yaml') { $f.FullName.Substring($script:Repo.Length) }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'The scripts that stay take -InfrastructureFile (mandatory) and stop with exit code 2 when it cannot be read' {
    It '<Name> has a mandatory -InfrastructureFile and no default for it' -ForEach $script:Kept {
        $p = Get-Parse ([IO.Path]::Combine($script:Repo, $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        $param = @($p.Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'InfrastructureFile' })
        $param.Count | Should -Be 1
        $param[0].DefaultValue | Should -BeNullOrEmpty
        @($param[0].Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } | ForEach-Object { $_.NamedArguments.ArgumentName }) | Should -Contain 'Mandatory'
    }
    It '<Name> has the standard header' -ForEach $script:Kept {
        $text = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))) -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = ['""]Stop['""]"
    }
    It '<Name> ends with exit code 2 and a message when the file does not exist' -ForEach $script:ExitTwo {
        $path = [IO.Path]::Combine($script:Repo, $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $arguments = @('-InfrastructureFile', (Join-Path $TestDrive 'does-not-exist.yml'))
        if ($Name -in 'Invoke-ApplySecurityGroups-Orchestrated.ps1', 'Invoke-VerifyPostDeployment.ps1') { $arguments += @('-LogPath', (Join-Path $TestDrive "$Name.log")) }
        if ($Name -eq 'Invoke-HardwareDiscovery.ps1') { $arguments += @('-OutputPath', (Join-Path $TestDrive 'discovery')) }
        $r = Invoke-Child $path $arguments
        $r.Code | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'Cannot read the infrastructure file'
    }
}

Describe 'The security group script and the post-deployment verification never ask for a login' {
    BeforeAll {
        $script:NoLogin = Join-Path $TestDrive 'no-login.yml'
        @'
scenario:
  identity: active_directory
cluster:
  name: iic-azl-01
identity:
  active_directory:
    netbios_name: IIC
    domain_fqdn: iic.improbability.cloud
    security_groups:
      - name: sg-admins
        local_groups: [Administrators]
nodes:
  - name: iic-azl-n01
    management:
      ip_address: 192.0.2.11
'@ | Set-Content -LiteralPath $script:NoLogin
    }
    It '<Name> stops with exit code 2 and says what to pass when there is no -Credential and no secret reference' -ForEach @(
        @{ Name = 'Invoke-ApplySecurityGroups-Orchestrated.ps1'; Relative = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-03-security-groups-applied-to-nodes/powershell/Invoke-ApplySecurityGroups-Orchestrated.ps1' }
        @{ Name = 'Invoke-VerifyPostDeployment.ps1'; Relative = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-VerifyPostDeployment.ps1' }
    ) {
        $path = [IO.Path]::Combine($script:Repo, $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $r = Invoke-Child $path @('-InfrastructureFile', $script:NoLogin, '-LogPath', (Join-Path $TestDrive "$Name-login.log"))
        $r.Code | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'pass -Credential'
    }
    It 'the BMC scripts stop with exit code 2 when there is no -Credential and the file has no BMC login' -ForEach @(
        @{ Name = 'Invoke-MountGoldImageISO.ps1'; Relative = 'scripts/deploy/04-cluster-deployment/phase-02-os-installation/task-02-mount-and-verify-dell-gold-image-iso/powershell/Invoke-MountGoldImageISO.ps1' }
        @{ Name = 'Invoke-ResetBossVirtualDisk.ps1'; Relative = 'scripts/deploy/04-cluster-deployment/phase-02-os-installation/task-01-delete-and-recreate-virtual-disk-on-dell-boss-card/powershell/Invoke-ResetBossVirtualDisk.ps1' }
        @{ Name = 'Enable-IdracVnc.ps1'; Relative = 'scripts/common/idrac-management/Enable-IdracVnc.ps1' }
        @{ Name = 'Invoke-HardwareDiscovery.ps1'; Relative = 'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Invoke-HardwareDiscovery.ps1' }
    ) {
        $file = Join-Path $TestDrive "no-bmc-$Name.yml"
        @'
provisioning:
  iso:
    image_uri: http://192.0.2.50/images/iic.iso
nodes:
  - name: iic-azl-n01
    bmc:
      ip_address: 192.0.2.21
'@ | Set-Content -LiteralPath $file
        $path = [IO.Path]::Combine($script:Repo, $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $arguments = @('-InfrastructureFile', $file)
        if ($Name -eq 'Invoke-HardwareDiscovery.ps1') { $arguments += @('-OutputPath', (Join-Path $TestDrive 'discovery-nologin')) }
        $r = Invoke-Child $path $arguments
        $r.Code | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'No BMC credential'
    }
}

Describe 'The run settings file of the OS configuration and the ARM deployment is -SettingsFile' {
    It '<Name> takes -SettingsFile and no -ConfigPath' -ForEach @(
        @{ Name = 'Invoke-AzureLocalOsConfiguration.ps1'; Relative = 'scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1' }
        @{ Name = 'Invoke-AzureLocalArmDeployment.ps1'; Relative = 'scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1' }
        @{ Name = 'Invoke-AzureLocalPreClusterVerification.ps1'; Relative = 'scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalPreClusterVerification.ps1' }
    ) {
        $p = Get-Parse ([IO.Path]::Combine($script:Repo, $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        $names = @($p.Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Contain 'SettingsFile'
        $names | Should -Not -Contain 'ConfigPath'
        $names | Should -Contain 'InfrastructureFile'
    }
    It 'the guarded change on the node is given its change file as -ChangeFile (a file the host wrote next to the script)' {
        $text = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'node-configuration', 'AzlNodeGuard.psm1')) -Raw
        $text | Should -Match 'Invoke-GuardedChange -ChangeFile'
        $text | Should -Not -Match 'ConfigPath'
    }
}
