#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The values the node configuration used to repeat in its code (work order of the hard-coded rows): the node state folder and C:\SBE are defined once and put into every
# node script, a payload can be given another folder, the hardware vendor has no fallback, the WinRM ports come from named constants, and the constants that Microsoft or a
# protocol fixes are named with their source. No node is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/NodeConstants.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $script:PayloadNames = @('Read', 'Apply', 'Collect', 'Restart', 'Preflight', 'Identity', 'ArcRegistration', 'DomainJoinProbe', 'DomainJoinApply', 'DomainJoinOuCheck', 'DomainJoinRestart', 'DomainJoinResume')
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Dir = [IO.Path]::Combine($script:Repo, 'scripts', 'common', 'node-configuration')
    Import-Module (Join-Path $script:Dir 'AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $script:Dir 'AzlNodeConfiguration.psm1') -Force
    Import-Module (Join-Path $script:Dir 'AzlGuardedChange.psm1') -Force
    Import-Module (Join-Path $script:Dir 'AzlRemoting.psm1') -Force
    function Get-ModuleText([string]$Name) { Get-Content -LiteralPath (Join-Path $script:Dir $Name) -Raw }
}

Describe 'The node folders have one definition' {
    It 'the state folder and the SBE folder are the documented ones' {
        Get-AzlNodeStateDirectory | Should -Be 'C:\ProgramData\AzureLocal\osconfig'
        Get-AzlNodeSbeDirectory | Should -Be 'C:\SBE'
    }
    It '<_> carries no #AZL-CONST token: the folders are in the text' -ForEach $script:PayloadNames {
        $text = Get-AzlNodePayload -Name $_
        $text | Should -Not -Match '#AZL-CONST'
        $text | Should -Match ([regex]::Escape("`$stateDir = [string](Get-P `$P 'stateDir' 'C:\ProgramData\AzureLocal\osconfig')"))
    }
    It 'Read and Apply default their SBE folder to C:\SBE and take another from the parameter sbeDir' -ForEach @('Read', 'Apply') {
        (Get-AzlNodePayload -Name $_) | Should -Match ([regex]::Escape("`$sbeDir = [string](Get-P `$P 'sbeDir' 'C:\SBE')"))
    }
    It 'the shared start of the node scripts has the folder too' {
        (Get-AzlNodePrologue) | Should -Not -Match '#AZL-CONST'
        (Get-AzlNodePrologue) | Should -Match ([regex]::Escape('C:\ProgramData\AzureLocal\osconfig'))
    }
    It 'no other module writes the state folder or C:\SBE as a literal in code' {
        foreach ($name in 'AzlNodeGuard.psm1', 'AzlNodeConfiguration.psm1', 'AzlNodeDomainJoinPayload.psm1') {
            (Get-ModuleText $name) | Should -Not -Match "'C:\\ProgramData\\AzureLocal\\osconfig'" -Because $name
        }
        (Get-ModuleText 'AzlNodeConfiguration.psm1') | Should -Not -Match "'C:\\SBE'"
    }
}

Describe 'The iSCSI settings that Learn fixes are constants with their source' {
    It 'the iscsi-service, iscsi-claim and iscsi-session actions say which Learn step fixes them, and keep the values' {
        $apply = Get-AzlNodePayload -Name Apply
        $apply | Should -Match '(?s)Learn: Connect an external storage array to Azure Local, step 1\.2\)[^\r\n]*\r?\n\s*Set-Service -Name MSiSCSI -StartupType Automatic\r?\n\s*Start-Service -Name MSiSCSI'
        $apply | Should -Match '(?s)step 2\.5\)[^\r\n]*\r?\n\s*Enable-MSDSMAutomaticClaim -BusType iSCSI'
        $apply | Should -Match '(?s)step 5\)[^\r\n]*persistence and multipath[^\r\n]*\r?\n\s*\$args4 = @\{[^\r\n]*IsPersistent = \$true; IsMultipathEnabled = \$true \}'
    }
}

Describe 'Get-AzlOemConfig has no vendor fallback' {
    It 'an empty or blank hardware.vendor is an error that names the key' {
        { Get-AzlOemConfig -Vendor '' } | Should -Throw '*hardware.vendor is empty*'
        { Get-AzlOemConfig -Vendor '   ' } | Should -Throw '*hardware.vendor is empty*'
    }
    It 'a named vendor loads its definition, whatever the case and spaces' {
        (Get-AzlOemConfig -Vendor ' Dell ').sbe.discoveryManifestUrl | Should -Not -BeNullOrEmpty
    }
    It 'no script of the deployment says Dell when it reads hardware.vendor' {
        foreach ($file in @(
                [IO.Path]::Combine($script:Dir, 'AzlNodeConfiguration.psm1')
                [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Set-AzureLocalNodeConfiguration.ps1')
                [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-05-cluster-deployment', 'Invoke-AzureLocalClusterDeployment.ps1')
                [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-05-cluster-deployment', 'New-AzureLocalArmParameters.ps1'))) {
            (Get-Content -LiteralPath $file -Raw) | Should -Not -Match "hardware\.vendor'\s+'Dell'" -Because $file
        }
    }
}

Describe 'Constants are named with what fixes them' {
    It 'AzlRemoting names the WinRM ports and uses them' {
        $text = Get-ModuleText 'AzlRemoting.psm1'
        $text | Should -Match '\$script:WinRmHttpPort = 5985'
        $text | Should -Match '\$script:WinRmHttpsPort = 5986'
        $text | Should -Match 'Port = \$\(if \(\$ssl\) \{ \$script:WinRmHttpsPort \} else \{ \$script:WinRmHttpPort \}\)'
        (Get-AzlRemotingSetting).Port | Should -Be 5985
        (Get-AzlRemotingSetting -UseSsl).Port | Should -Be 5986
    }
    It 'the Apply payload sets the NTP peers with the client flag, manual sources and not-reliable, and says why' {
        $apply = Get-AzlNodePayload -Name Apply
        $apply | Should -Match ([regex]::Escape("`$_ + ',0x8'"))
        $apply | Should -Match '/syncfromflags:manual /reliable:no /update'
        $apply | Should -Match 'Fixed by Microsoft'
    }
    It 'the Apply payload enables the two built-in echo request rules, and the guard engine the same two' {
        (Get-AzlNodePayload -Name Apply) | Should -Match "'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In'"
        (Get-ModuleText 'AzlNodeGuard.psm1') | Should -Match "'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In'"
    }
    It 'the Kerberos skew limit and the minimum OS build say what fixes them' {
        (Get-ModuleText 'AzlDomainJoin.psm1') | Should -Match 'Fixed by Microsoft: the default of the Kerberos policy'
        (Get-ModuleText 'AzlOsConfigurationRun.psm1') | Should -Match 'Fixed by Microsoft: Learn, Azure Local release information'
    }
    It 'the guarded change keeps its settings in one table that the run settings override, and names the probe host fallback' {
        $text = Get-ModuleText 'AzlGuardedChange.psm1'
        $text | Should -Match '\$script:GuardDefaults = \[ordered\]@\{ networkRollbackMinutes = 10; networkStableSeconds = 60; reconnectWaitMinutes = 15; staleRunCommandMinutes = 15; addressProbe = \$true \}'
        $text | Should -Match "\`$script:DefaultProbeHost = 'management.azure.com'"
        $text | Should -Match 'else \{ \$script:DefaultProbeHost \}'
        (Get-AzlGuardSetting -Setting @{ reconnectWaitMinutes = 20 }).reconnectWaitMinutes | Should -Be 20
        (Get-AzlGuardSetting -Setting @{ staleRunCommandMinutes = 30 }).staleRunCommandMinutes | Should -Be 30
        (Get-AzlGuardSetting).networkRollbackMinutes | Should -Be 10
    }
}
