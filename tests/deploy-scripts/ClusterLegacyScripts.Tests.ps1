#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (cluster deployment) scripts that read the schema 5 infrastructure.yml and no old-layout key: the iDRAC virtual media and BOSS scripts
# (phase 02), the BIOS and iDRAC scripts (phase 01), the Phase 03 verification and the SSH orchestrator. The Redfish calls are mocked
# (Invoke-RestMethod); nothing reaches a BMC, a node or Azure. The scripts that were removed because a schema 5 script does the job are listed
# with the one that replaces them. Ids and addresses are examples (192.0.2.x, 00000000-...).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/ClusterLegacyScripts.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock bodies read the parameters of the mocked cmdlet.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $deploy = [IO.Path]::Combine($repoRoot, 'scripts', 'deploy', '04-cluster-deployment')
    # Removed script -> the script that does the job now (both relative to scripts/deploy/04-cluster-deployment).
    $script:Removed = @(
        @{ Gone = 'phase-06-post-deployment/task-02-cluster-quorum-configuration/powershell/Invoke-ConfigureClusterQuorum-Standalone.ps1'; Instead = 'phase-06-post-deployment/task-02-cluster-quorum-configuration/powershell/Invoke-ConfigureClusterQuorum-Orchestrated.ps1' }
        @{ Gone = 'phase-06-post-deployment/task-03-security-groups-applied-to-nodes/powershell/Invoke-ApplySecurityGroups-Standalone.ps1'; Instead = 'phase-06-post-deployment/task-03-security-groups-applied-to-nodes/powershell/Invoke-ApplySecurityGroups-Orchestrated.ps1' }
        @{ Gone = 'phase-06-post-deployment/task-04-ssh-connectivity-to-nodes/powershell/Invoke-SSHConnectivity-Standalone.ps1'; Instead = 'phase-06-post-deployment/task-04-ssh-connectivity-to-nodes/powershell/Invoke-SSHConnectivity-Orchestrated.ps1' }
        @{ Gone = 'phase-06-post-deployment/task-09-post-deployment-verification/powershell/Test-PostDeployment-Standalone.ps1'; Instead = 'phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-VerifyPostDeployment.ps1' }
        @{ Gone = 'phase-04-arc-registration/task-02-register-cluster-nodes-with-azure-arc/powershell/Register-AzureLocalArc-Interactive.ps1'; Instead = 'phase-04-arc-registration/task-02-register-cluster-nodes-with-azure-arc/powershell/Register-AzureLocalArc-Remote.ps1' }
        @{ Gone = 'phase-04-arc-registration/task-02-register-cluster-nodes-with-azure-arc/powershell/Register-AzureLocalArc-ServicePrincipal.ps1'; Instead = 'phase-04-arc-registration/task-02-register-cluster-nodes-with-azure-arc/powershell/Register-AzureLocalArc-Remote.ps1' }
        @{ Gone = 'phase-03-os-configuration/task-06-verify-dns-client-configuration/powershell/Test-DnsClientConfig.ps1'; Instead = 'phase-03-os-configuration/task-06-verify-dns-client-configuration/powershell/Test-DnsConfiguration.ps1' }
    )
    $script:RemovedCase = @($script:Removed | ForEach-Object { @{ Gone = [IO.Path]::Combine($deploy, $_.Gone); Instead = [IO.Path]::Combine($deploy, $_.Instead); Name = [IO.Path]::GetFileName($_.Gone) } })
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Deploy = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment')
    $script:Boss = [IO.Path]::Combine($script:Deploy, 'phase-02-os-installation', 'task-01-delete-and-recreate-virtual-disk-on-dell-boss-card', 'powershell', 'Invoke-ResetBossVirtualDisk.ps1')
    $script:Iso = [IO.Path]::Combine($script:Deploy, 'phase-02-os-installation', 'task-02-mount-and-verify-dell-gold-image-iso', 'powershell', 'Invoke-MountGoldImageISO.ps1')
    $script:BiosTest = [IO.Path]::Combine($script:Deploy, 'phase-01-hardware-provisioning', 'task-04-bios-and-idrac-settings-validation', 'powershell', 'Test-BiosIdracSettings.ps1')
    $script:BiosSet = [IO.Path]::Combine($script:Deploy, 'phase-01-hardware-provisioning', 'task-05-bios-and-idrac-settings-remediation', 'powershell', 'Set-BiosIdracSettings.ps1')
    $script:Phase03 = [IO.Path]::Combine($script:Deploy, 'phase-03-os-configuration', 'task-13-phase03-verification', 'powershell', 'Invoke-Phase03Verification-Orchestrated.ps1')
    $script:Ssh = [IO.Path]::Combine($script:Deploy, 'phase-06-post-deployment', 'task-04-ssh-connectivity-to-nodes', 'powershell', 'Invoke-SSHConnectivity-Orchestrated.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
    $env:AZL_TEST_BMC_PASSWORD = 'Canary-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

    function New-InfraFile {
        param([hashtable]$Extra = @{}, [object[]]$Nodes)
        if (-not $Nodes) {
            $Nodes = @(
                [ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = '192.0.2.21' } }
                [ordered]@{ name = 'iic-azl-n02'; bmc = [ordered]@{ ip_address = '192.0.2.22' } }
            )
        }
        $doc = [ordered]@{
            hardware = [ordered]@{ bmc = [ordered]@{ username = 'iic-bmc'; password = 'env://AZL_TEST_BMC_PASSWORD' } }
            nodes    = @($Nodes)
        }
        foreach ($k in $Extra.Keys) { $doc[$k] = $Extra[$k] }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Get-CodeText([string]$Path) {
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
    }
}

AfterAll { Remove-Item Env:AZL_TEST_BMC_PASSWORD -ErrorAction SilentlyContinue; Remove-Variable -Name AzlTestInserted -Scope Global -ErrorAction SilentlyContinue }

Describe 'Scripts that a schema 5 script replaces' {
    It '<Name> is removed and <Instead> is still there' -ForEach $script:RemovedCase {
        Test-Path -LiteralPath $Gone | Should -BeFalse
        Test-Path -LiteralPath $Instead | Should -BeTrue
    }
}

Describe 'Invoke-ResetBossVirtualDisk.ps1' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Invoke-RestMethod {
            switch -Wildcard ($Uri) {
                '*/Systems/System.Embedded.1/Storage' { return [pscustomobject]@{ Members = @([pscustomobject]@{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1/Storage/AHCI.Slot.1-1' }, [pscustomobject]@{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1/Storage/BOSS-S1.Modular.1' }) } }
                '*/Storage/BOSS-S1.Modular.1' { return [pscustomobject]@{ Id = 'BOSS-S1.Modular.1' } }
                '*/Volumes' { if ($Method -eq 'POST') { return [pscustomobject]@{ '@odata.id' = '/redfish/v1/new' } } return [pscustomobject]@{ Members = @([pscustomobject]@{ '@odata.id' = '/redfish/v1/old-volume' }) } }
                '*/Drives' { return [pscustomobject]@{ Members = @([pscustomobject]@{ '@odata.id' = '/redfish/v1/d1' }, [pscustomobject]@{ '@odata.id' = '/redfish/v1/d2' }) } }
                default { return [pscustomobject]@{} }
            }
        }
    }

    It 'reads nodes[] and nodes[].bmc.ip_address, finds the BOSS controller and recreates the mirror on every node' {
        $null = & $script:Boss -ConfigPath (New-InfraFile) 6>&1
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'DELETE' -and $Uri -like 'https://192.0.2.2*/redfish/v1/old-volume' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like 'https://192.0.2.21/*BOSS-S1.Modular.1/Volumes' -and $Body -match 'Mirrored' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like 'https://192.0.2.22/*BOSS-S1.Modular.1/Volumes' }
    }
    It 'changes nothing under -WhatIf' {
        $null = & $script:Boss -ConfigPath (New-InfraFile) -WhatIf 6>&1
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
    It 'skips a node that has no BMC address and says so' {
        $file = New-InfraFile -Nodes @([ordered]@{ name = 'iic-azl-n01' }, [ordered]@{ name = 'iic-azl-n02'; bmc = [ordered]@{ ip_address = '192.0.2.22' } })
        $out = & $script:Boss -ConfigPath $file 3>&1 6>&1
        ($out | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { "$_" }) -join "`n" | Should -Match 'iic-azl-n01 has no nodes\[\]\.bmc\.ip_address'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like 'https://192.0.2.21/*' }
    }
    It 'reads no old-layout key' {
        (Get-CodeText $script:Boss) | Should -Not -Match 'cluster\s*\.\s*nodes|idrac_ip|variables\.yml'
    }
}

Describe 'Invoke-MountGoldImageISO.ps1' {
    BeforeEach {
        Mock Start-Sleep { }
        $global:AzlTestInserted = $false
        Mock Invoke-RestMethod {
            if ($Uri -like '*InsertMedia') { $global:AzlTestInserted = $true; return [pscustomobject]@{} }
            if ($Uri -like '*EjectMedia') { return [pscustomobject]@{} }
            [pscustomobject]@{ Inserted = $global:AzlTestInserted; Image = 'x' }
        }
    }

    It 'mounts provisioning.iso.image_uri on the iDRAC of every node' {
        $file = New-InfraFile -Extra @{ provisioning = [ordered]@{ iso = [ordered]@{ image_uri = 'http://192.0.2.50/images/azure-local.iso' } } }
        $null = & $script:Iso -ConfigPath $file 6>&1
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*InsertMedia' -and $Body -match 'http://192\.0\.2\.50/images/azure-local\.iso' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like 'https://192.0.2.21/*InsertMedia' }
    }
    It 'stops when the file has no provisioning.iso.image_uri' {
        { & $script:Iso -ConfigPath (New-InfraFile) 6>&1 } | Should -Throw '*provisioning.iso.image_uri is missing*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
    It 'changes nothing under -WhatIf' {
        $file = New-InfraFile -Extra @{ provisioning = [ordered]@{ iso = [ordered]@{ image_uri = 'http://192.0.2.50/images/azure-local.iso' } } }
        $null = & $script:Iso -ConfigPath $file -WhatIf 6>&1
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*InsertMedia' }
    }
    It 'reads no old-layout key, and the key it reads is in the registry' {
        (Get-CodeText $script:Iso) | Should -Not -Match 'cluster\s*\.\s*nodes|gold_image_iso_path|idrac_ip|variables\.yml'
        @($script:Registry | Where-Object Path -EQ 'provisioning.iso.image_uri').Count | Should -Be 1
    }
}

Describe 'The BIOS and iDRAC scripts read hardware.bios and nodes[].bios' {
    BeforeEach {
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get' -and $Uri -like '*/Bios') {
                return [pscustomobject]@{ Attributes = [pscustomobject]@{ SysProfile = 'PerfOptimized'; LogicalProc = 'Enabled'; VirtualizationTechnology = 'Enabled'; SriovGlobalEnable = 'Enabled'; BootMode = 'Uefi'; SecureBoot = 'Enabled'; TpmSecurity = 'OnPbm' } }
            }
            if ($Method -eq 'Get') { return [pscustomobject]@{ Attributes = [pscustomobject]@{ 'IPMILan.1#Enable' = 'Enabled' } } }
            [pscustomobject]@{}
        }
        $script:File = New-InfraFile -Extra @{ hardware = [ordered]@{ bmc = [ordered]@{ username = 'iic-bmc'; password = 'env://AZL_TEST_BMC_PASSWORD' }; bios = [ordered]@{ SriovGlobalEnable = 'Disabled' } } } -Nodes @(
            [ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = '192.0.2.21' }; bios = [ordered]@{ SriovGlobalEnable = 'Enabled'; SysProfile = 'Custom' } }
            [ordered]@{ name = 'iic-azl-n02'; bmc = [ordered]@{ ip_address = '192.0.2.22' } })
    }

    It 'the validation applies hardware.bios to every machine and nodes[].bios over it' {
        $report = Join-Path $TestDrive 'bios-report.json'
        $null = & $script:BiosTest -ConfigPath $script:File -OutputPath $report 6>&1
        $rows = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        $n1 = @($rows | Where-Object Node -EQ 'iic-azl-n01').Results
        $n2 = @($rows | Where-Object Node -EQ 'iic-azl-n02').Results
        ($n1 | Where-Object Setting -EQ 'SriovGlobalEnable').Status | Should -Be 'PASS'
        ($n1 | Where-Object Setting -EQ 'SysProfile').Status | Should -Be 'FAIL'
        ($n2 | Where-Object Setting -EQ 'SriovGlobalEnable').Status | Should -Be 'FAIL'
        ($n2 | Where-Object Setting -EQ 'SriovGlobalEnable').Desired | Should -Be 'Disabled'
    }
    It 'the remediation sends the attributes of each machine: hardware.bios for one, nodes[].bios over it for the other' {
        $null = & $script:BiosSet -ConfigPath $script:File 6>&1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Patch' -and $Uri -like 'https://192.0.2.21/*Bios/Settings' -and $Body -match 'SysProfile' -and $Body -notmatch 'SriovGlobalEnable' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Patch' -and $Uri -like 'https://192.0.2.22/*Bios/Settings' -and $Body -match 'SriovGlobalEnable' -and $Body -notmatch 'SysProfile' }
    }
    It 'the remediation changes nothing under -WhatIf' {
        $null = & $script:BiosSet -ConfigPath $script:File -WhatIf 6>&1
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'Get' }
    }
    It 'neither script reads hardware.bios_settings or hardware.idrac_settings, and every key they read is in the registry: <_>' -ForEach 'hardware.bios', 'nodes[].bios', 'nodes[].bmc.ip_address', 'hardware.bmc.verify_certificate' {
        foreach ($p in $script:BiosTest, $script:BiosSet) { (Get-CodeText $p) | Should -Not -Match 'bios_settings|idrac_settings' }
        @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
    }
}

Describe 'The Phase 03 verification and the SSH orchestrator' {
    It 'the DNS check resolves an Azure endpoint, not a public search site' {
        $code = Get-CodeText $script:Phase03
        $code | Should -Match 'management\.azure\.com'
        $code | Should -Not -Match 'google\.com'
    }
    It 'the SSH orchestrator falls back to azure.location, not azure_platform.region' {
        $code = Get-CodeText $script:Ssh
        $code | Should -Match '\$cfg\s*\.\s*azure\s*\.\s*location'
        $code | Should -Not -Match 'azure_platform'
        @($script:Registry | Where-Object Path -EQ 'azure.location').Count | Should -Be 1
    }
}
