#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06, task 10: Get-AzureLocalSbeImportPlan.ps1 lists the SBE files on the share and the exact Add-SolutionUpdate commands (Microsoft Learn, Import and rediscover updates), and
# executes none of them. The "share" is a folder in TestDrive with made-up file names that follow SBE_<Vendor>_<Family>_<Version>; no Azure, no node, no network.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/SbeImportPlan.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:Script = Join-Path $repo 'scripts\deploy\04-cluster-deployment\phase-06-post-deployment\task-10-sbe-update-import\powershell\Get-AzureLocalSbeImportPlan.ps1'
    function New-Share([switch]$SkipZip) {
        $dir = Join-Path $TestDrive ('share-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = New-Item -ItemType Directory $dir
        $name = 'SBE_Example_GenA-Std_4.1.2610.5'
        Set-Content -LiteralPath (Join-Path $dir "$name.xml") -Value '<x/>'
        if (-not $SkipZip) { Set-Content -LiteralPath (Join-Path $dir "$name.zip") -Value 'payload' }
        "<SBEUpdatesManifest><ManifestInfo CreationDate=`"2026-09-01`"/><ApplicableUpdate Version=`"4.1.2610.5`" Family=`"GenA-Std`"><UpdateInfo><UpdateName>$name</UpdateName><Publisher>Example</Publisher><PackageHash>00</PackageHash><SupportedModels><SupportedModel>ExampleA1</SupportedModel></SupportedModels></UpdateInfo></ApplicableUpdate></SBEUpdatesManifest>" | Set-Content -LiteralPath (Join-Path $dir 'SBE_Discovery_Example.xml')
        $dir
    }
    function New-InfraFile([string]$Sbe) {
        $file = Join-Path $TestDrive ('infra-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.yml')
        "hardware:`n  vendor: Example`n  model: ExampleA1`n  sbe:`n$Sbe" | Set-Content -LiteralPath $file
        $file
    }
}

Describe 'Get-AzureLocalSbeImportPlan.ps1' {
    It 'prints the three files and the exact commands, and returns them without running any' {
        $share = New-Share
        $file = New-InfraFile "    source_path: '$share'"
        $plan = & $script:Script -InfrastructureFile $file 6>$null 3>$null
        @($plan.Files.Name) | Should -Be @('SBE_Discovery_Example.xml', 'SBE_Example_GenA-Std_4.1.2610.5.xml', 'SBE_Example_GenA-Std_4.1.2610.5.zip')
        $text = $plan.Commands -join "`n"
        $text | Should -Match ([regex]::Escape('Add-SolutionUpdate -SourceFolder ''C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import'''))
        $text | Should -Match 'Get-SolutionUpdate'
        $text | Should -Match ([regex]::Escape("Copy-Item -LiteralPath '$share\SBE_Example_GenA-Std_4.1.2610.5.zip'"))
        @($plan.Notes).Count | Should -BeGreaterThan 1
    }
    It 'a custom import folder is used in every command' {
        $file = New-InfraFile "    source_path: '$(New-Share)'"
        $plan = & $script:Script -InfrastructureFile $file -ImportFolder 'C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\other' 6>$null
        ($plan.Commands | Where-Object { $_ -match 'Add-SolutionUpdate' }) | Should -Match 'other'
    }
    It 'writes the plan as JSON when asked' {
        $file = New-InfraFile "    source_path: '$(New-Share)'"
        $out = Join-Path $TestDrive 'plan.json'
        $null = & $script:Script -InfrastructureFile $file -OutputPath $out 6>$null
        $j = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        $j.package | Should -Be 'SBE_Example_GenA-Std_4.1.2610.5'
        @($j.files).Count | Should -Be 3
    }
    It 'refuses a share that lacks the payload, and says which file' {
        $file = New-InfraFile "    source_path: '$(New-Share -SkipZip)'"
        { & $script:Script -InfrastructureFile $file 6>$null } | Should -Throw '*SBE_Example_GenA-Std_4.1.2610.5.zip*'
    }
    It 'refuses when no source is configured' {
        $file = New-InfraFile "    delivery: skip"
        { & $script:Script -InfrastructureFile $file 6>$null } | Should -Throw '*source_path is empty*'
    }
    It 'says nothing is to import when the file declares the package not applicable' {
        $file = New-InfraFile "    requirement: not_applicable`n    not_applicable_reason: No SBE exists for this model"
        $plan = & $script:Script -InfrastructureFile $file 6>&1
        ($plan | Out-String) | Should -Match 'not applicable'
    }
    It 'an unreadable share is an error with the reason' {
        $file = New-InfraFile "    source_path: '$(Join-Path $TestDrive 'nowhere')'"
        { & $script:Script -InfrastructureFile $file 6>$null } | Should -Throw '*could not be read from this host*'
    }
}
