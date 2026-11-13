#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01, tasks 04 and 05: Test-BiosIdracSettings.ps1 and Set-BiosIdracSettings.ps1 take the BMC login from infrastructure.yml
# (hardware.bmc, a node's own nodes[].bmc wins) through the shared reader, never prompt, and check the BMC certificate only when
# hardware.bmc.verify_certificate says so. Every Redfish call is mocked (Invoke-RestMethod): no BMC, node, cluster or Azure
# resource is contacted. Secrets are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/hardware-discovery/BiosIdracSettings.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks run in their own scope and read the fake state through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes and files in TestDrive.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test values only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock parameters mirror Invoke-RestMethod.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $phase = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-01-hardware-provisioning')
    $script:TestScript = [IO.Path]::Combine($phase, 'task-04-bios-and-idrac-settings-validation', 'powershell', 'Test-BiosIdracSettings.ps1')
    $script:SetScript = [IO.Path]::Combine($phase, 'task-05-bios-and-idrac-settings-remediation', 'powershell', 'Set-BiosIdracSettings.ps1')
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'secrets', 'AzlSecret.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')) -Force
    Import-Module powershell-yaml

    $script:SharedPassword = [guid]::NewGuid().ToString('N')
    $script:NodePassword = [guid]::NewGuid().ToString('N')
    $script:ExplicitPassword = [guid]::NewGuid().ToString('N')
    $env:AZL_BIOS_TEST_SHARED = $script:SharedPassword
    $env:AZL_BIOS_TEST_NODE = $script:NodePassword
    # The mocks of Invoke-RestMethod run in their own scope and read the expected passwords and record the calls through this global.
    $global:BiosTest = @{ Calls = [System.Collections.Generic.List[object]]::new(); Shared = $script:SharedPassword; Node = $script:NodePassword; Explicit = $script:ExplicitPassword }

    function New-InfraFile {
        param([bool]$VerifyCertificate = $false, [switch]$NoSharedBmc, [switch]$NodeOverride, [switch]$NoVerifyKey)
        $hardware = [ordered]@{}
        if (-not $NoSharedBmc) {
            $bmc = [ordered]@{ username = 'shared-admin'; password = 'env://AZL_BIOS_TEST_SHARED' }
            if (-not $NoVerifyKey) { $bmc.verify_certificate = $VerifyCertificate }
            $hardware.bmc = $bmc
        }
        $one = [ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = '192.0.2.11' } }
        $two = [ordered]@{ name = 'iic-azl-n02'; bmc = [ordered]@{ ip_address = '192.0.2.12' } }
        if ($NodeOverride) { $two.bmc.username = 'node-admin'; $two.bmc.password = 'env://AZL_BIOS_TEST_NODE' }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        $doc = [ordered]@{ nodes = @($one, $two) }
        if ($hardware.Count) { $doc.hardware = $hardware }
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }

    # The text of a script without its comments, from the parser.
    function Get-CodeText([string]$Path) {
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
    }
}

AfterAll {
    Remove-Item Env:AZL_BIOS_TEST_SHARED, Env:AZL_BIOS_TEST_NODE -ErrorAction SilentlyContinue
    Remove-Variable -Name BiosTest -Scope Global -ErrorAction SilentlyContinue
}

Describe 'The BIOS and iDRAC scripts read the BMC login from the infrastructure file' -ForEach @(
    @{ Name = 'Test-BiosIdracSettings.ps1'; Kind = 'test' }
    @{ Name = 'Set-BiosIdracSettings.ps1'; Kind = 'set' }
) {
    BeforeAll {
        $script:Path = if ($Kind -eq 'test') { $script:TestScript } else { $script:SetScript }
        $script:Kind = $Kind
        function Invoke-Bios {
            param([string]$File, [hashtable]$Extra = @{})
            $global:BiosTest.Calls = [System.Collections.Generic.List[object]]::new()
            $output = Join-Path $TestDrive "report-$([guid]::NewGuid().ToString('N').Substring(0, 6)).json"
            $arguments = @{ ConfigPath = $File } + $Extra
            if ($script:Kind -eq 'test') { $arguments.OutputPath = $output }
            $streams = & $script:Path @arguments 6>&1 3>&1 2>&1
            [pscustomobject]@{
                Text   = (@($streams | ForEach-Object { "$_" }) -join "`n")
                Report = $(if ((Test-Path -LiteralPath $output)) { Get-Content -LiteralPath $output -Raw } else { '' })
                Calls  = $global:BiosTest.Calls
            }
        }
    }

    BeforeEach {
        # A BMC in the state the baseline wants, except one BIOS value, so the validation has one FAIL and the remediation has one change.
        Mock Invoke-RestMethod {
            $expected = switch -Wildcard ($Credential.UserName) { 'shared-admin' { $global:BiosTest.Shared } 'node-admin' { $global:BiosTest.Node } 'explicit-admin' { $global:BiosTest.Explicit } default { '' } }
            $global:BiosTest.Calls.Add([pscustomobject]@{ Method = [string]$Method; Uri = [string]$Uri; User = $Credential.UserName; PasswordMatches = ($Credential.GetNetworkCredential().Password -eq $expected); SkipCertificateCheck = [bool]$SkipCertificateCheck })
            if ($Method -ne 'Get') { return [pscustomobject]@{ Done = $true } }
            if ($Uri -like '*/Bios') {
                return [pscustomobject]@{ Attributes = [pscustomobject]@{ SysProfile = 'Custom'; LogicalProc = 'Enabled'; VirtualizationTechnology = 'Enabled'; SriovGlobalEnable = 'Enabled'; BootMode = 'Uefi'; SecureBoot = 'Enabled'; TpmSecurity = 'OnPbm' } }
            }
            return [pscustomobject]@{ Attributes = [pscustomobject]@{ 'IPMILan.1#Enable' = 'Enabled' } }
        }
        Mock Get-Credential { throw 'A prompt must never be shown.' }
        Mock Read-Host { throw 'A prompt must never be shown.' }
    }

    It '<Name> uses hardware.bmc for every node, reads the password from its reference, and prints no secret' {
        $r = Invoke-Bios (New-InfraFile)
        $r.Calls.Count | Should -BeGreaterThan 3 -Because $r.Text
        @($r.Calls.User | Select-Object -Unique) | Should -Be @('shared-admin')
        @($r.Calls | Where-Object { -not $_.PasswordMatches }).Count | Should -Be 0
        foreach ($secret in $script:SharedPassword, $script:NodePassword) {
            $r.Text | Should -Not -Match $secret
            $r.Report | Should -Not -Match $secret
        }
        Should -Invoke Get-Credential -Times 0 -Exactly
    }

    It '<Name> lets a node''s own nodes[].bmc win for that node' {
        $r = Invoke-Bios (New-InfraFile -NodeOverride)
        @($r.Calls | Where-Object { $_.Uri -like 'https://192.0.2.11/*' }).User | Select-Object -Unique | Should -Be 'shared-admin'
        @($r.Calls | Where-Object { $_.Uri -like 'https://192.0.2.12/*' }).User | Select-Object -Unique | Should -Be 'node-admin'
        @($r.Calls | Where-Object { -not $_.PasswordMatches }).Count | Should -Be 0
    }

    It '<Name> uses an explicit -Credential for every node and does not read the file''s references' {
        Remove-Item Env:AZL_BIOS_TEST_SHARED -ErrorAction SilentlyContinue
        try {
            $credential = [pscredential]::new('explicit-admin', (ConvertTo-SecureString $script:ExplicitPassword -AsPlainText -Force))
            $r = Invoke-Bios (New-InfraFile -NodeOverride) @{ Credential = $credential }
            @($r.Calls.User | Select-Object -Unique) | Should -Be @('explicit-admin')
            @($r.Calls | Where-Object { -not $_.PasswordMatches }).Count | Should -Be 0
            $r.Text | Should -Not -Match $script:ExplicitPassword
        }
        finally { $env:AZL_BIOS_TEST_SHARED = $script:SharedPassword }
    }

    It '<Name> does not prompt and calls no BMC when the file has no BMC login' {
        $r = Invoke-Bios (New-InfraFile -NoSharedBmc)
        $r.Calls.Count | Should -Be 0
        $r.Text | Should -Match 'No BMC credential'
        Should -Invoke Get-Credential -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It '<Name> does not prompt and says why when the reference cannot be read' {
        Remove-Item Env:AZL_BIOS_TEST_SHARED -ErrorAction SilentlyContinue
        try {
            $r = Invoke-Bios (New-InfraFile)
            $r.Calls.Count | Should -Be 0
            $r.Text | Should -Match 'AZL_BIOS_TEST_SHARED'
            $r.Text | Should -Match 'No BMC credential'
        }
        finally { $env:AZL_BIOS_TEST_SHARED = $script:SharedPassword }
    }

    It '<Name> accepts the BMC certificate by default and when verify_certificate is false' {
        foreach ($file in (New-InfraFile), (New-InfraFile -NoVerifyKey)) {
            $r = Invoke-Bios $file
            $r.Calls.Count | Should -BeGreaterThan 0
            @($r.Calls | Where-Object { -not $_.SkipCertificateCheck }).Count | Should -Be 0
        }
    }

    It '<Name> checks the BMC certificate when hardware.bmc.verify_certificate is true' {
        $r = Invoke-Bios (New-InfraFile -VerifyCertificate $true)
        $r.Calls.Count | Should -BeGreaterThan 0
        @($r.Calls | Where-Object { $_.SkipCertificateCheck }).Count | Should -Be 0
    }

    It '<Name> has no prompt, no old credential function and no old credential parameters' {
        $code = Get-CodeText $script:Path
        $code | Should -Not -Match '(?i)\bGet-Credential\b|\bRead-Host\b|Get-RedfishCredential|iDRACPassword|iDRACUsername'
        $code | Should -Match 'Resolve-AzlBmcCredential'
        $code | Should -Not -Match '(?i)-SkipCertificateCheck'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$null, [ref]$null)
        $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'Credential'
    }
}

Describe 'Test-BiosIdracSettings.ps1 still tests what it tested' {
    It 'reports the BIOS value that differs from the baseline and the ones that match' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*/Bios') { return [pscustomobject]@{ Attributes = [pscustomobject]@{ SysProfile = 'Custom'; LogicalProc = 'Enabled'; VirtualizationTechnology = 'Enabled'; SriovGlobalEnable = 'Enabled'; BootMode = 'Uefi'; SecureBoot = 'Enabled'; TpmSecurity = 'OnPbm' } } }
            [pscustomobject]@{ Attributes = [pscustomobject]@{ 'IPMILan.1#Enable' = 'Enabled' } }
        }
        $output = Join-Path $TestDrive 'validation.json'
        $null = & $script:TestScript -ConfigPath (New-InfraFile) -OutputPath $output 6>&1 3>&1
        $report = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        @($report).Count | Should -Be 2
        foreach ($node in $report) {
            $node.Fail | Should -Be 1
            $node.Pass | Should -Be 7
            @($node.Results | Where-Object Status -EQ 'FAIL').Setting | Should -Be 'SysProfile'
        }
    }
}

Describe 'Set-BiosIdracSettings.ps1 still changes what it changed' {
    BeforeEach {
        $global:BiosTest.Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod {
            $global:BiosTest.Calls.Add([pscustomobject]@{ Method = [string]$Method; Uri = [string]$Uri; Body = [string]$Body })
            if ($Method -ne 'Get') { return [pscustomobject]@{ Done = $true } }
            if ($Uri -like '*/Bios') { return [pscustomobject]@{ Attributes = [pscustomobject]@{ SysProfile = 'Custom'; LogicalProc = 'Enabled'; VirtualizationTechnology = 'Enabled'; SriovGlobalEnable = 'Enabled'; BootMode = 'Uefi'; SecureBoot = 'Enabled'; TpmSecurity = 'OnPbm' } } }
            [pscustomobject]@{ Attributes = [pscustomobject]@{ 'IPMILan.1#Enable' = 'Enabled' } }
        }
    }
    It 'sends the one BIOS change and the configuration job to every node, and nothing else' {
        $null = & $script:SetScript -ConfigPath (New-InfraFile) 6>&1 3>&1
        $writes = @($global:BiosTest.Calls | Where-Object { $_.Method -ne 'Get' })
        @($writes | Where-Object { $_.Method -eq 'Patch' }).Count | Should -Be 2
        @($writes | Where-Object { $_.Method -eq 'Patch' -and $_.Uri -like '*/Bios/Settings' -and $_.Body -match '"SysProfile":\s*"PerfOptimized"' }).Count | Should -Be 2
        @($writes | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*/Jobs' }).Count | Should -Be 2
        $writes.Count | Should -Be 4
    }
    It 'sends nothing under -WhatIf' {
        $null = & $script:SetScript -ConfigPath (New-InfraFile) -WhatIf 6>&1 3>&1
        @($global:BiosTest.Calls | Where-Object { $_.Method -ne 'Get' }).Count | Should -Be 0
    }
}
