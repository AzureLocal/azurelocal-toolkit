#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (testing and validation), task 05: Test-SecurityCompliance.ps1. It reads security.defender_for_cloud.enabled and
# apply_cloud_security_benchmark from the infrastructure file, and the owner limit and the signature age are parameters.
# Every cluster, Azure and remoting call is a stub; nothing is contacted.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/security/SecurityCompliance.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cmdlets they replace.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Source = [IO.Path]::Combine($repo, 'scripts', 'deploy', '06-testing-validation', 'task-05-security-compliance-validation', 'powershell', 'Test-SecurityCompliance.ps1')
    $script:Text = Get-Content -LiteralPath $script:Source -Raw
    Import-Module powershell-yaml
    # The script asks for the Az modules with #Requires; the test runs a copy without those two lines, because every Az call is a stub.
    $script:Copy = Join-Path $TestDrive 'Test-SecurityCompliance.ps1'
    Set-Content -LiteralPath $script:Copy -Value (($script:Text -split "`r?`n" | Where-Object { $_ -notmatch '^#Requires -Module' }) -join "`n")

    function Set-AzContext { param($SubscriptionId, $ErrorAction) $null }
    function Get-AzResourceProvider { param($ProviderNamespace, $ErrorAction) [pscustomobject]@{ RegistrationState = 'Registered' } }
    function Get-AzPolicyAssignment { param($Scope, $ErrorAction) @() }
    function Get-AzRoleAssignment { param($Scope, $ErrorAction) $global:AzlScOwners }
    function Get-AzPolicyState { param($ResourceGroupName, $ErrorAction) @() }
    function Get-ClusterNode { param($Cluster) @([pscustomobject]@{ Name = 'iic-01-n01' }) }
    function Invoke-Command {
        param($ComputerName, $ScriptBlock)
        $body = $ScriptBlock.ToString()
        if ($body -match 'Get-BitLockerVolume') { return @([pscustomobject]@{ MountPoint = 'C:'; VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On'; EncryptionPercentage = 100 }) }
        if ($body -match 'Get-MpComputerStatus') { return [pscustomobject]@{ RealTimeProtection = $true; AntivirusEnabled = $true; SignatureAge = $global:AzlScSignatureAge; LastScan = [datetime]::Now } }
        @{ EnabledPolicies = 5 }
    }
    function New-Infra {
        param([hashtable]$Defender)
        $doc = [ordered]@{ cluster = [ordered]@{ name = 'iic-azl-01' }; azure = [ordered]@{ subscription_id = '00000000-0000-0000-0000-000000000000'; resource_group = 'rg-iic-azl-01' } }
        if ($Defender) { $doc.security = [ordered]@{ defender_for_cloud = $Defender } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Compliance {
        param([string]$File, [hashtable]$Extra = @{})
        $out = Join-Path $TestDrive "out-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $text = (& $script:Copy -ConfigPath $File -OutputPath $out @Extra 6>&1 | Out-String)
        $report = Get-ChildItem -LiteralPath $out -Filter '*.json' | Select-Object -First 1
        [pscustomobject]@{ Text = $text; Report = (Get-Content -LiteralPath $report.FullName -Raw | ConvertFrom-Json) }
    }
}

AfterAll { Remove-Variable -Name AzlScOwners, AzlScSignatureAge -Scope Global -ErrorAction SilentlyContinue }

Describe 'Test-SecurityCompliance.ps1' {
    BeforeEach {
        $global:AzlScOwners = @()
        $global:AzlScSignatureAge = 1
    }

    It 'checks the free Defender for Cloud level and the benchmark when the file says nothing' {
        $r = Invoke-Compliance (New-Infra)
        $r.Text | Should -Match 'Foundational CSPM'
        $r.Text | Should -Match 'Microsoft cloud security benchmark: NotAssigned'
    }

    It 'does not check Defender for Cloud when security.defender_for_cloud.enabled is false' {
        $r = Invoke-Compliance (New-Infra @{ enabled = $false })
        $r.Text | Should -Match 'security.defender_for_cloud.enabled is false'
        $r.Text | Should -Not -Match 'Foundational CSPM'
    }

    It 'does not check the benchmark when apply_cloud_security_benchmark is false' {
        $r = Invoke-Compliance (New-Infra @{ apply_cloud_security_benchmark = $false })
        $r.Text | Should -Match 'Foundational CSPM'
        $r.Text | Should -Match 'apply_cloud_security_benchmark is false'
        $r.Text | Should -Not -Match 'benchmark: NotAssigned'
    }

    It 'warns about owners above the limit of the parameter MaximumOwnerAssignments' {
        $global:AzlScOwners = 1..2 | ForEach-Object { [pscustomobject]@{ RoleDefinitionName = 'Owner' } }
        (Invoke-Compliance (New-Infra) @{ MaximumOwnerAssignments = 1 }).Text | Should -Match 'WARNING: 2 Owner assignments \(recommend <= 1\)'
        (Invoke-Compliance (New-Infra)).Text | Should -Not -Match 'Owner assignments \(recommend'
    }

    It 'judges the signature age by the parameter MaximumSignatureAgeDays' {
        $global:AzlScSignatureAge = 10
        (Invoke-Compliance (New-Infra)).Text | Should -Match '\[WARN\].*SigAge=10d'
        (Invoke-Compliance (New-Infra) @{ MaximumSignatureAgeDays = 14 }).Text | Should -Match '\[SUCCESS\].*SigAge=10d'
    }

    Context 'the script text' {
        It 'names the benchmark initiative once, as a constant' {
            ([regex]::Matches($script:Text, '1f3afdf9-d0c9-4c3d-847f-89da613e70a8')).Count | Should -Be 1
            $script:Text | Should -Match '\$BenchmarkDefinitionId = '
        }
        It 'has no owner limit or signature age typed into a comparison' {
            $script:Text | Should -Not -Match '-gt 3\b'
            $script:Text | Should -Not -Match 'SignatureAge -le 7'
        }
        It 'registers the two new parameters' {
            $script:Text | Should -Match '\[int\]\$MaximumOwnerAssignments = 3'
            $script:Text | Should -Match '\[int\]\$MaximumSignatureAgeDays = 7'
        }
    }
}
