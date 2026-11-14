#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Scripts that used to carry a value in their code (work order of the hard-coded rows): the BOSS volume label is a parameter, the Redfish paths of the Dell scripts are named
# once, the key vault script suggests no site account, the combined phase 03 scripts are gone, and
# the values that Microsoft fixes are named with their source. The Redfish calls are mocked (Invoke-RestMethod); nothing reaches a BMC, a node or Azure.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/HardCodedScripts.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock bodies read the parameters of the mocked cmdlet.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Deploy = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment')
    $script:Boss = [IO.Path]::Combine($script:Deploy, 'phase-02-os-installation', 'task-01-delete-and-recreate-virtual-disk-on-dell-boss-card', 'powershell', 'Invoke-ResetBossVirtualDisk.ps1')
    $script:Iso = [IO.Path]::Combine($script:Deploy, 'phase-02-os-installation', 'task-02-mount-and-verify-dell-gold-image-iso', 'powershell', 'Invoke-MountGoldImageISO.ps1')
    $script:BiosTest = [IO.Path]::Combine($script:Deploy, 'phase-01-hardware-provisioning', 'task-04-bios-and-idrac-settings-validation', 'powershell', 'Test-BiosIdracSettings.ps1')
    $script:BiosSet = [IO.Path]::Combine($script:Deploy, 'phase-01-hardware-provisioning', 'task-05-bios-and-idrac-settings-remediation', 'powershell', 'Set-BiosIdracSettings.ps1')

    $env:AZL_TEST_BMC_PASSWORD = 'Canary-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

    function New-InfraFile {
        $doc = [ordered]@{
            hardware = [ordered]@{ bmc = [ordered]@{ username = 'iic-bmc'; password = 'env://AZL_TEST_BMC_PASSWORD' } }
            nodes    = @([ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = '192.0.2.21' } }, [ordered]@{ name = 'iic-azl-n02'; bmc = [ordered]@{ ip_address = '192.0.2.22' } })
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Get-CodeText([string]$Path) {
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
    }
    function Get-ParamBlock([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $ast.ParamBlock.Parameters
    }
}

AfterAll { Remove-Item Env:AZL_TEST_BMC_PASSWORD -ErrorAction SilentlyContinue }

Describe 'Invoke-ResetBossVirtualDisk.ps1 -VolumeName' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Invoke-RestMethod {
            switch -Wildcard ($Uri) {
                '*/Systems/System.Embedded.1/Storage' { return [pscustomobject]@{ Members = @([pscustomobject]@{ '@odata.id' = '/redfish/v1/Systems/System.Embedded.1/Storage/BOSS-S1.Modular.1' }) } }
                '*/Storage/BOSS-S1.Modular.1' { return [pscustomobject]@{ Id = 'BOSS-S1.Modular.1' } }
                '*/Volumes' { if ($Method -eq 'POST') { return [pscustomobject]@{ '@odata.id' = '/redfish/v1/new' } } return [pscustomobject]@{ Members = @() } }
                '*/Drives' { return [pscustomobject]@{ Members = @([pscustomobject]@{ '@odata.id' = '/redfish/v1/d1' }, [pscustomobject]@{ '@odata.id' = '/redfish/v1/d2' }) } }
                default { return [pscustomobject]@{} }
            }
        }
    }
    It 'labels the new virtual disk BOSS-RAID1 when no name is given' {
        $null = & $script:Boss -InfrastructureFile (New-InfraFile) 6>&1
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Body -match '"Name":\s*"BOSS-RAID1"' }
    }
    It 'labels it with -VolumeName when one is given' {
        $null = & $script:Boss -InfrastructureFile (New-InfraFile) -VolumeName 'iic-boot-mirror' 6>&1
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Body -match '"Name":\s*"iic-boot-mirror"' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Body -match 'BOSS-RAID1' }
    }
    It 'refuses an empty -VolumeName' {
        { & $script:Boss -InfrastructureFile (New-InfraFile) -VolumeName '' 6>&1 } | Should -Throw
    }
    It 'has the label only as the default of the parameter' {
        (Get-CodeText $script:Boss) | Should -Not -Match '(?<![A-Za-z])Name\s*=\s*"BOSS-RAID1"'
        @(Get-ParamBlock $script:Boss | Where-Object { $_.Name.VariablePath.UserPath -eq 'VolumeName' }).Count | Should -Be 1
    }
}

Describe 'The Redfish paths of the Dell scripts are named once' {
    It '<Name> writes the manager and system resource ids only in its constants' -ForEach @(
        @{ Name = 'Set-BiosIdracSettings.ps1'; File = 'BiosSet'; Count = 2 }
        @{ Name = 'Test-BiosIdracSettings.ps1'; File = 'BiosTest'; Count = 2 }
        @{ Name = 'Invoke-MountGoldImageISO.ps1'; File = 'Iso'; Count = 1 }
        @{ Name = 'Invoke-ResetBossVirtualDisk.ps1'; File = 'Boss'; Count = 1 }
    ) {
        $text = Get-CodeText (Get-Variable -Name $File -Scope Script -ValueOnly)
        ([regex]::Matches($text, 'Embedded\.1')).Count | Should -Be $Count
    }
    It 'the constants say which API fixes them' {
        foreach ($file in $script:BiosSet, $script:BiosTest, $script:Iso, $script:Boss) {
            (Get-Content -LiteralPath $file -Raw) | Should -Match "Fixed by (the DMTF Redfish schema and by )?Dell's iDRAC Redfish API"
        }
    }
    It 'the iDRAC baseline is one attribute and says why it is not a key' {
        foreach ($file in $script:BiosSet, $script:BiosTest) {
            (Get-Content -LiteralPath $file -Raw) | Should -Match 'MIGRATION\.md, To 5\.6\.21, Not keys'
            ([regex]::Matches((Get-CodeText $file), 'IPMILan\.1#Enable')).Count | Should -Be 1
        }
    }
}

Describe 'The error texts name no script that stores a secret' {
    It '<_> tells the operator to put the secret in the store the reference names' -ForEach @(
        'scripts/common/arm-deployment/AzlArmDeploymentRun.psm1'
        'scripts/common/arm-deployment/verification/AzlVerification.Azure.psm1') {
        $text = Get-Content -LiteralPath (Join-Path $script:Repo $_) -Raw
        $text | Should -Not -Match 'Add-KeyVaultCredentials'
        $text | Should -Match 'Put the secret in the store the reference names'
    }
}

Describe 'The combined phase 03 scripts are removed' {
    It 'the folder of task 12 and its catalogue entry are gone' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Deploy, 'phase-03-os-configuration', 'task-12-complete-combined-script-all-steps')) | Should -BeFalse
        (Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', 'common', 'TaskCatalogue.psd1')) -Raw) | Should -Not -Match 'task-12-complete-combined-script-all-steps'
    }
    It 'the script that replaces them is there and reads the NTP servers from the file' {
        $wrapper = [IO.Path]::Combine($script:Deploy, 'phase-03-os-configuration', 'Invoke-AzureLocalOsConfiguration.ps1')
        Test-Path -LiteralPath $wrapper | Should -BeTrue
        (Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'node-configuration', 'AzlNodeConfiguration.psm1')) -Raw) | Should -Match 'networking\.ntp_servers'
    }
}

Describe 'Values that Microsoft fixes are named with their source' {
    It 'the firewall endpoint list says that Learn fixes it (the two older scripts with their own lists are removed)' {
        $net = [IO.Path]::Combine($script:Deploy, '..', '03-onprem-readiness', 'phase-03-network-infrastructure')
        Test-Path -LiteralPath ([IO.Path]::Combine($net, 'task-03-firewall-endpoint-verification', 'powershell', 'Set-FirewallEndpoint.ps1')) | Should -BeFalse
        Test-Path -LiteralPath ([IO.Path]::Combine($net, 'task-04-network-validation', 'powershell', 'Test-NetworkReadiness.ps1')) | Should -BeFalse
        (Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'verification', 'AzlVerification.Endpoints.psm1')) -Raw) | Should -Match 'The list is fixed by Microsoft, not a choice of the deployment'
    }
}
