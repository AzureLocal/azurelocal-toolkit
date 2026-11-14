#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 02 of the on-premises readiness, task 04: Complete-ValidationSignoff.ps1 writes the sign-off page from infrastructure.yml and the report of the
# pre-cluster verification. It reads files and writes one file; it signs in to nothing and asks nothing. Everything runs against files in TestDrive.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/ValidationSignoff.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '03-onprem-readiness', 'phase-02-enterprise-readiness', 'task-04-validation-signoff', 'powershell', 'Complete-ValidationSignoff.ps1')
    Import-Module powershell-yaml

    function New-InfraFile {
        param([switch]$NoCustomer)
        $doc = [ordered]@{
            site    = [ordered]@{ code = 'IIC' }
            cluster = [ordered]@{ name = 'iic-azl-01' }
            azure   = [ordered]@{ location = 'westeurope'; subscription_id = '00000000-0000-0000-0000-000000000000' }
            nodes   = @([ordered]@{ name = 'iic-01-n01' }, [ordered]@{ name = 'iic-01-n02' })
        }
        if (-not $NoCustomer) { $doc.site.customer = 'Improbability Cloud' }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Report {
        param([string]$File, [string]$Verdict = 'Pass', [switch]$OtherHash)
        $hash = if ($OtherHash) { 'ABCDEF' } else { (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash }
        $dir = Join-Path $TestDrive "report-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $json = [ordered]@{ schema = 1; verdict = $Verdict; counts = [ordered]@{ Passed = 40; Failed = 0; Warning = 2 }; fileHash = $hash; expiresUtc = '2026-11-20T10:00:00.0000000Z' } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $dir 'report.json') -Value $json
        $dir
    }
    function Invoke-Signoff([hashtable]$Arguments) {
        $global:LASTEXITCODE = $null
        $all = & $script:Script @Arguments 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Result   = @($all | Where-Object { $_.PSObject.Properties['SignoffPath'] })[0]
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Complete-ValidationSignoff.ps1' {
    It 'writes the page with the customer, the cluster, the region and the number of machines from the file' {
        $file = New-InfraFile
        $out = Join-Path $TestDrive 'o1'
        $r = Invoke-Signoff @{ InfrastructureFile = $file; OutputPath = $out; ProjectName = 'Iic Rollout' }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $text = Get-Content -LiteralPath $r.Result.SignoffPath -Raw
        $text | Should -Match 'Improbability Cloud'
        $text | Should -Match 'Iic Rollout'
        $text | Should -Match 'iic-azl-01'
        $text | Should -Match 'westeurope'
        $text | Should -Match 'Machines in the file:\*\* 2'
    }

    It 'says that no report was given, and that the deployment must not start' {
        $r = Invoke-Signoff @{ InfrastructureFile = (New-InfraFile); OutputPath = (Join-Path $TestDrive 'o2') }
        $r.Result.ReadyForDeployment | Should -BeFalse
        $text = Get-Content -LiteralPath $r.Result.SignoffPath -Raw
        $text | Should -Match 'No report given'
        $text | Should -Match 'must not start'
        $text | Should -Not -Match '\*\*Project:\*\*'
    }

    It 'reads the verdict, the counts and the expiry from the report, and says the report is for this file' {
        $file = New-InfraFile
        $r = Invoke-Signoff @{ InfrastructureFile = $file; OutputPath = (Join-Path $TestDrive 'o3'); VerificationReport = (New-Report -File $file) }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Result.ReadyForDeployment | Should -BeTrue
        $r.Result.Verdict | Should -Be 'Pass'
        $text = Get-Content -LiteralPath $r.Result.SignoffPath -Raw
        $text | Should -Match '\| Pre-cluster verification \| Pass \|'
        $text | Should -Match 'Passed 40'
        $text | Should -Match 'Report for this file: yes'
        $text | Should -Match '2026-11-20'
    }

    It 'accepts the report.json itself as well as its folder' {
        $file = New-InfraFile
        $dir = New-Report -File $file
        $r = Invoke-Signoff @{ InfrastructureFile = $file; OutputPath = (Join-Path $TestDrive 'o3b'); VerificationReport = (Join-Path $dir 'report.json') }
        $r.Result.ReadyForDeployment | Should -BeTrue
    }

    It 'does not call the file ready when the verdict is Fail' {
        $file = New-InfraFile
        $r = Invoke-Signoff @{ InfrastructureFile = $file; OutputPath = (Join-Path $TestDrive 'o4'); VerificationReport = (New-Report -File $file -Verdict 'Fail') }
        $r.ExitCode | Should -Be 0
        $r.Result.ReadyForDeployment | Should -BeFalse
        (Get-Content -LiteralPath $r.Result.SignoffPath -Raw) | Should -Match 'must not start'
    }

    It 'does not call the file ready when the report was made for another file' {
        $file = New-InfraFile
        $r = Invoke-Signoff @{ InfrastructureFile = $file; OutputPath = (Join-Path $TestDrive 'o5'); VerificationReport = (New-Report -File $file -OtherHash) }
        $r.Result.ReadyForDeployment | Should -BeFalse
        (Get-Content -LiteralPath $r.Result.SignoffPath -Raw) | Should -Match 'infrastructure file changed after the report was made'
    }

    It 'writes no file under -WhatIf' {
        $out = Join-Path $TestDrive 'o6'
        $all = & $script:Script -InfrastructureFile (New-InfraFile) -OutputPath $out -WhatIf 6>&1
        Test-Path -LiteralPath $out | Should -BeFalse
        @($all | Where-Object { $_.PSObject.Properties['Action'] })[0].Action | Should -Be 'WouldWrite'
    }

    It 'ends with exit code 2 when site.customer is missing, and writes nothing' {
        $out = Join-Path $TestDrive 'o7'
        $r = Invoke-Signoff @{ InfrastructureFile = (New-InfraFile -NoCustomer); OutputPath = $out }
        $r.ExitCode | Should -Be 2
        $r.Text | Should -Match 'site.customer is missing'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'ends with exit code 2 when the file cannot be read, and 1 when the report cannot be found' {
        (Invoke-Signoff @{ InfrastructureFile = (Join-Path $TestDrive 'missing.yml'); OutputPath = (Join-Path $TestDrive 'o8') }).ExitCode | Should -Be 2
        $r = Invoke-Signoff @{ InfrastructureFile = (New-InfraFile); OutputPath = (Join-Path $TestDrive 'o9'); VerificationReport = (Join-Path $TestDrive 'no-report') }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'verification report was not found'
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            $script:Code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
            $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
        }
        It 'takes -InfrastructureFile (mandatory, no default) and no -ConfigPath, -CustomerName or -ValidationResultsPath' {
            $names = @($script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $names | Should -Contain 'InfrastructureFile'
            foreach ($old in 'ConfigPath', 'CustomerName', 'ValidationResultsPath') { $names | Should -Not -Contain $old }
            $p = $script:Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'InfrastructureFile' }
            $p.Attributes.NamedArguments.ArgumentName | Should -Contain 'Mandatory'
            $p.DefaultValue | Should -BeNullOrEmpty
        }
        It 'has the standard header, never prompts and installs nothing' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Code | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|ConvertFrom-Yaml|Install-Module|ConfigPath'
        }
        It 'reads only registry keys that exist: <_>' -ForEach 'site.customer', 'cluster.name', 'azure.location', 'azure.subscription_id', 'nodes' {
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            @($registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
        It 'names no customer, project or site in the script' {
            $script:Code | Should -Not -Match 'TBD|Azure Local Deployment"|Contoso'
        }
    }
}
