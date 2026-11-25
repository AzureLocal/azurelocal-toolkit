#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 11 (SBE update import): Get-AzureLocalSbeImportPlan.ps1 runs ALONE, with only its own parameters, against the toolkit example
# file. By default it only reads the share and prints the plan. With -Execute it runs the import steps of the guide page on a cluster machine (copy, check the hash,
# Add-SolutionUpdate, wait for Ready); not giving -Execute, or giving -WhatIf, is the plan. The "share" is a folder in TestDrive; Invoke-Command is a fake,
# so no cluster, no node and no network is used. The file is config/variables/examples/infrastructure.example.yml, as it is, and with the SBE source added in memory.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/SbeImportPlanMode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake cluster and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $script:This = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-11-sbe-update-import', 'powershell', 'Get-AzureLocalSbeImportPlan.ps1')
    Import-Module powershell-yaml
    function az { $global:LASTEXITCODE = 1 }
    $global:AzlPlanSecret = 'AZL_TEST_PLAN_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($global:AzlPlanSecret, [guid]::NewGuid().ToString())
    $script:Hash = [guid]::NewGuid().ToString('N').ToUpperInvariant()

    # A share with one package of the vendor of the example (Dell is the example's vendor; the package names follow SBE_<Vendor>_<Family>_<Version>).
    function New-Share {
        $dir = Join-Path $TestDrive ('share-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = New-Item -ItemType Directory $dir
        $name = 'SBE_Example_GenA-Std_4.1.2610.5'
        Set-Content -LiteralPath (Join-Path $dir "$name.xml") -Value '<x/>'
        Set-Content -LiteralPath (Join-Path $dir "$name.zip") -Value 'payload'
        "<SBEUpdatesManifest><ManifestInfo CreationDate=`"2026-09-01`"/><ApplicableUpdate Version=`"4.1.2610.5`" Family=`"GenA-Std`"><UpdateInfo><UpdateName>$name</UpdateName><Publisher>Example</Publisher><PackageHash>$($script:Hash)</PackageHash><SupportedModels><SupportedModel>ExampleA1</SupportedModel></SupportedModels></UpdateInfo></ApplicableUpdate></SBEUpdatesManifest>" | Set-Content -LiteralPath (Join-Path $dir 'SBE_Discovery_Example.xml')
        $dir
    }
    function New-PlanFile {
        param([string]$Share = '', [scriptblock]$Edit, [switch]$Login)
        $doc = ConvertFrom-Yaml -Ordered (Get-Content -LiteralPath $script:Example -Raw)
        $doc.hardware.model = 'ExampleA1'
        $doc.hardware.sbe = [ordered]@{}
        if ($Share) { $doc.hardware.sbe.source_path = $Share }
        if ($Login) { $doc.identity.active_directory.lcm_user.password = "env://$($global:AzlPlanSecret)" }
        if ($Edit) { & $Edit $doc }
        $file = Join-Path $TestDrive "plan-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-World {
        $global:AzlPlanRemote = [System.Collections.Generic.List[object]]::new()
        $global:AzlPlanState = @{ Updates = @(@{ DisplayName = 'Solution update'; PackageType = 'Solution'; Version = '12.2611.1004.9'; SbeVersion = ''; State = 'AdditionalContentRequired' }); HashOnNode = $script:Hash; AfterImport = 'Ready'; CopyFails = $false; Reads = 0 }
    }
    function Invoke-Alone([hashtable]$Extra, [string]$File) {
        $global:LASTEXITCODE = $null
        $all = & $script:This -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = @($all)
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Step([string]$Step) { @($global:AzlPlanRemote | Where-Object Step -EQ $Step) }
}

Describe 'Get-AzureLocalSbeImportPlan.ps1 runs alone' {
    AfterAll { Remove-Variable -Name AzlPlanSecret, AzlPlanRemote, AzlPlanState -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-World
        Mock Start-Sleep { }
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlPlanRemote.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Credential = $Credential; Arguments = @($ArgumentList | Select-Object -Skip 1) })
            switch ($step) {
                'Probe' { return 'iic-azl-n01' }
                'ReadUpdates' {
                    $global:AzlPlanState.Reads++
                    $imported = @($global:AzlPlanRemote | Where-Object Step -EQ 'Import').Count -gt 0
                    if ($imported) { return @(@{ DisplayName = 'Solution update'; PackageType = 'Solution'; Version = '12.2611.1004.9'; SbeVersion = '4.1.2610.5'; State = $global:AzlPlanState.AfterImport }) }
                    return $global:AzlPlanState.Updates
                }
                'CopyFiles' { if ($global:AzlPlanState.CopyFails) { throw 'Access is denied' }; return @{ Copied = @($ArgumentList[2]); Kept = @() } }
                'HashFile' { return @{ Hash = $global:AzlPlanState.HashOnNode } }
                'Import' { return $null }
            }
        }
    }

    It 'takes -InfrastructureFile as its only mandatory parameter, -WhatIf and -LogPath (the plan is not giving -Execute, or giving -WhatIf)' {
        $command = Get-Command -Name $script:This
        @($command.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory } } | ForEach-Object Name) | Should -Be @('InfrastructureFile')
        $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        $command.Parameters.ContainsKey('LogPath') | Should -BeTrue
        @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters -and $_ -notin 'InfrastructureFile', 'LogPath' } | Sort-Object) |
            Should -Be @('ComputerName', 'Credential', 'Execute', 'ImportFolder', 'MaxWaitMinutes', 'OutputPath', 'PollSeconds')
    }

    Context 'without -Execute it only prints the plan' {
        It 'plans against the toolkit example as it is: the share of the example is not on this host, exit 1 with the reason, no node asked' {
            $r = Invoke-Alone @{} (New-PlanFile -Edit { param($doc) $doc.hardware.sbe = [ordered]@{ source_path = (Join-Path $TestDrive 'nowhere') } })
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read from this host'
            $global:AzlPlanRemote.Count | Should -Be 0
        }

        It 'says there is nothing to import, exit 0, when the file declares the package not applicable' {
            $r = Invoke-Alone @{} (New-PlanFile -Edit { param($doc) $doc.hardware.sbe = [ordered]@{ requirement = 'not_applicable'; not_applicable_reason = 'No SBE exists for this model' } })
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'not applicable'
            $global:AzlPlanRemote.Count | Should -Be 0
        }

        It 'prints the three files and the commands, writes the log, runs nothing and asks no node' {
            $log = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
            $r = Invoke-Alone @{ LogPath = $log } (New-PlanFile -Share (New-Share))
            $r.ExitCode | Should -BeIn @($null, 0) -Because $r.Text
            $r.Text | Should -Match 'Add-SolutionUpdate -SourceFolder'
            $r.Text | Should -Match 'NOT executed'
            $global:AzlPlanRemote.Count | Should -Be 0
            (Get-Content -LiteralPath $log -Raw) | Should -Match 'SBE_Example_GenA-Std_4.1.2610.5.zip'
        }

        It 'stops with exit code 2 when the file names no share' {
            $r = Invoke-Alone @{} (New-PlanFile)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'source_path is empty'
        }

        It '-Execute with -WhatIf is still the plan: the commands are printed, no node is asked, nothing is imported' {
            $r = Invoke-Alone @{ Execute = $true; WhatIf = $true } (New-PlanFile -Share (New-Share) -Login)
            $r.ExitCode | Should -BeIn @($null, 0) -Because $r.Text
            $r.Text | Should -Match 'NOT executed'
            $global:AzlPlanRemote.Count | Should -Be 0
        }
    }

    Context 'with -Execute' {
        It 'stops with exit code 2, asks no node, when there is no login (the example keeps its Key Vault reference)' {
            $r = Invoke-Alone @{ Execute = $true } (New-PlanFile -Share (New-Share))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'No login|password of identity'
            $global:AzlPlanRemote.Count | Should -Be 0
        }

        It 'runs the steps in the order of the page: read, copy, hash, import, read until Ready; as the deployment user, on the first node' {
            $r = Invoke-Alone @{ Execute = $true; PollSeconds = 1 } (New-PlanFile -Share (New-Share) -Login)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($global:AzlPlanRemote.Step) | Should -Be @('Probe', 'ReadUpdates', 'CopyFiles', 'HashFile', 'Import', 'ReadUpdates')
            (Get-Step 'Import')[0].Computer | Should -Be '192.0.2.11'
            (Get-Step 'Import')[0].Credential.UserName | Should -Be 'IIC\lcm-iic-azl-01'
            (Get-Step 'Import')[0].Arguments[0] | Should -Be 'C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import'
            (Get-Step 'CopyFiles')[0].Arguments[1] | Should -Be @('SBE_Discovery_Example.xml', 'SBE_Example_GenA-Std_4.1.2610.5.xml', 'SBE_Example_GenA-Std_4.1.2610.5.zip')
            @($r.Rows | Where-Object Item -EQ 'update state after the import').Action | Should -Be 'Verified'
        }

        It 'imports nothing when no update reports AdditionalContentRequired (the vendor connector works): NotNeeded, exit 0' {
            $global:AzlPlanState.Updates = @(@{ DisplayName = 'Solution update'; PackageType = 'Solution'; Version = '12.2611.1004.9'; SbeVersion = ''; State = 'Ready' })
            $r = Invoke-Alone @{ Execute = $true } (New-PlanFile -Share (New-Share) -Login)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('NotNeeded')
            (Get-Step 'CopyFiles').Count | Should -Be 0
            (Get-Step 'Import').Count | Should -Be 0
        }

        It 'stops before the import, exit 1, when the SHA256 of the zip on the machine is not the PackageHash of the manifest' {
            $global:AzlPlanState.HashOnNode = 'ABCDEF'
            $r = Invoke-Alone @{ Execute = $true } (New-PlanFile -Share (New-Share) -Login)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Nothing was imported'
            (Get-Step 'Import').Count | Should -Be 0
        }

        It 'stops before the hash, exit 1, and says to set the share account, when the machine cannot read the share' {
            $global:AzlPlanState.CopyFails = $true
            $r = Invoke-Alone @{ Execute = $true } (New-PlanFile -Share (New-Share) -Login)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'source_username'
            (Get-Step 'HashFile').Count | Should -Be 0
            (Get-Step 'Import').Count | Should -Be 0
        }

        It 'fails (exit 1) when the imported update is Invalid, and when it is not Ready after the wait' {
            $global:AzlPlanState.AfterImport = 'Invalid'
            $r = Invoke-Alone @{ Execute = $true } (New-PlanFile -Share (New-Share) -Login)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Invalid'
            Reset-World; $global:AzlPlanState.AfterImport = 'AdditionalContentRequired'
            $r = Invoke-Alone @{ Execute = $true; MaxWaitMinutes = 0 } (New-PlanFile -Share (New-Share) -Login)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'not Ready'
        }

        It 'connects to -ComputerName when given, and uses -Credential when given, without reading the password of the file' {
            $cred = [pscredential]::new('IIC\deploy', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force))
            $r = Invoke-Alone @{ Execute = $true; ComputerName = 'iic-azl-n02'; Credential = $cred } (New-PlanFile -Share (New-Share))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Step 'Probe')[0].Computer | Should -Be 'iic-azl-n02'
            (Get-Step 'Probe')[0].Credential.UserName | Should -Be 'IIC\deploy'
        }
    }
}
