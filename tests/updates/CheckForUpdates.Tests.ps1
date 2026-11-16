#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Day 2, stage 08 task 01 (owner directive D74, check for updates after a deployment and periodically): Get-AvailableSolutionUpdate.ps1 reads the update
# environment and the discovered updates of the cluster, Get-AvailableSolutionUpdate.azcli.ps1 reads the update summary and the updates of the cluster
# resource in Azure. Both are read only. Invoke-Command and az are mocked: no cluster, no machine, no Azure, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/updates/CheckForUpdates.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the cluster state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A test credential for a mocked remoting call; it is never a secret.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $task = [IO.Path]::Combine($repo, 'scripts', 'deploy', '08-day2-operations', 'task-01-check-for-updates')
    $script:Script = [IO.Path]::Combine($task, 'powershell', 'Get-AvailableSolutionUpdate.ps1')
    $script:ScriptCli = [IO.Path]::Combine($task, 'azurecli', 'Get-AvailableSolutionUpdate.azcli.ps1')
    Import-Module powershell-yaml
    function az { }

    $global:AzlChkTenant = [guid]::NewGuid().ToString()
    $global:AzlChkSubscription = [guid]::NewGuid().ToString()
    $global:AzlChkHome = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([string]$Cluster = 'azl-cluster-01', [string]$Target = '', [object]$Tenant = $global:AzlChkTenant, [object]$Subscription = $global:AzlChkSubscription, [string]$ResourceGroup = 'rg-azl-01')
        $doc = [ordered]@{ cluster = [ordered]@{}; azure = [ordered]@{}; operations = [ordered]@{} }
        if ($Cluster) { $doc.cluster.name = $Cluster }
        if ($null -ne $Tenant) { $doc.azure.tenant_id = $Tenant }
        if ($null -ne $Subscription) { $doc.azure.subscription_id = $Subscription }
        if ($ResourceGroup) { $doc.azure.resource_group = $ResourceGroup }
        if ($Target) { $doc.operations.updates = [ordered]@{ target_version = $Target } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Update([string]$Version, [string]$State = 'Ready', [string]$Type = 'Solution') {
        @{ ResourceId = "azl/$Type$Version"; Version = $Version; SbeVersion = '4.1.2410.5'; State = $State; PackageType = $Type; DisplayName = "update $Version"; UpdateStateProperties = '' }
    }
    function Reset-Cluster {
        $global:AzlChkCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlChkReads = 0
        $global:AzlChkNow = [datetime]'2026-01-01T00:00:00Z'
        $global:AzlChkFail = $false
        $global:AzlChkAppearsOnRead = 1
        $global:AzlChkState = @{
            CurrentVersion = '12.2607.1002.20'; CurrentSbeVersion = '4.1.2410.5'; State = 'UpdateAvailable'; HealthState = 'Success'
            LastChecked = '2026-01-01T00:00:00.0000000Z'; HardwareModel = 'Model-1'
            Updates = @((New-Update '12.2607.1002.20' 'Installed'), (New-Update '12.2610.1004.50'))
        }
    }
    function Invoke-Check([string]$File, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Update'] -and $_.PSObject.Properties['Next'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Invoke-CheckCli([string]$File, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = & $script:ScriptCli -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Update'] -and $_.PSObject.Properties['Next'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

AfterAll { Remove-Variable -Name AzlChkTenant, AzlChkSubscription, AzlChkHome, AzlChkCalls, AzlChkReads, AzlChkNow, AzlChkFail, AzlChkAppearsOnRead, AzlChkState, AzlChkAz, AzlChkAzCalls -Scope Global -ErrorAction SilentlyContinue }

Describe 'Get-AvailableSolutionUpdate.ps1 (the cluster)' {
    BeforeEach {
        Reset-Cluster
        Mock Get-Date { $global:AzlChkNow }
        Mock Start-Sleep { $global:AzlChkNow = $global:AzlChkNow.AddSeconds($Seconds) }
        Mock Invoke-Command {
            $global:AzlChkCalls.Add([pscustomobject]@{ Computer = [string]$ComputerName; Credential = $Credential; Block = $ScriptBlock.ToString() })
            if ($global:AzlChkFail) { throw 'simulated remoting failure' }
            $global:AzlChkReads++
            if ($global:AzlChkReads -lt $global:AzlChkAppearsOnRead) {
                $state = $global:AzlChkState.Clone(); $state.Updates = @((New-Update '12.2607.1002.20' 'Installed')); return $state
            }
            $global:AzlChkState
        }
    }

    Context 'what it reports' {
        It 'offers a ready solution update, says how to start it, and exits 0' {
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows.Count | Should -Be 1
            $r.Rows[0].Update | Should -Be '12.2610.1004.50'
            $r.Rows[0].Next | Should -Be 'Start'
            $r.Rows[0].Detail | Should -Match 'Start-AzureLocalSolutionUpdate'
            $r.Text | Should -Match 'Verdict: UpdateAvailable'
        }

        It 'says UpToDate when only installed or obsolete updates exist' {
            $global:AzlChkState.Updates = @((New-Update '12.2607.1002.20' 'Installed'), (New-Update '12.2605.1001.10' 'Obsolete'))
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows.Count | Should -Be 0
            $r.Text | Should -Match 'Verdict: UpToDate'
        }

        It 'points an AdditionalContentRequired update at the SBE import and does not call it startable' {
            $global:AzlChkState.Updates = @((New-Update '12.2610.1004.50' 'AdditionalContentRequired'))
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Next | Should -Be 'ImportSbe'
            $r.Rows[0].Detail | Should -Match 'task 11'
            $r.Text | Should -Match 'Verdict: AdditionalContentRequired'
        }

        It 'says UpdateRunning for an update that is installing' {
            $global:AzlChkState.Updates = @((New-Update '12.2610.1004.50' 'Installing'))
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Next | Should -Be 'Follow'
            $r.Text | Should -Match 'Verdict: UpdateRunning'
        }

        It 'marks a standalone SBE update as startable by hand, not by the solution update script' {
            $global:AzlChkState.Updates = @((New-Update '4.1.2412.5' 'Ready' 'SBE'))
            $r = Invoke-Check (New-InfraFile)
            $r.Rows[0].Type | Should -Be 'SBE'
            $r.Rows[0].Detail | Should -Match 'combined solution update'
        }

        It 'says whether operations.updates.target_version is offered' {
            (Invoke-Check (New-InfraFile -Target '12.2610.1004.50')).Text | Should -Match 'target_version 12.2610.1004.50 is offered'
            (Invoke-Check (New-InfraFile -Target '12.2699.1001.10')).Text | Should -Match 'is not offered yet'
            (Invoke-Check (New-InfraFile -Target '12.2607.1002.20')).Text | Should -Match 'installed or older'
        }
    }

    Context 'what needs attention (exit 1)' {
        It 'exits 1 for <Case>' -ForEach @(
            @{ Case = 'an update whose readiness checks failed'; Update = 'HealthCheckFailed'; Health = 'Success'; Env = 'UpdateAvailable' }
            @{ Case = 'an update whose installation failed'; Update = 'InstallationFailed'; Health = 'Success'; Env = 'UpdateAvailable' }
            @{ Case = 'an update that has a prerequisite'; Update = 'HasPrerequisite'; Health = 'Success'; Env = 'UpdateAvailable' }
            @{ Case = 'a health state of Failure'; Update = 'Ready'; Health = 'Failure'; Env = 'UpdateAvailable' }
            @{ Case = 'a health state of Warning'; Update = 'Ready'; Health = 'Warning'; Env = 'UpdateAvailable' }
            @{ Case = 'an update environment in UpdateFailed'; Update = 'Ready'; Health = 'Success'; Env = 'UpdateFailed' }
        ) {
            $global:AzlChkState.Updates = @((New-Update '12.2610.1004.50' $Update))
            $global:AzlChkState.HealthState = $Health
            $global:AzlChkState.State = $Env
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'Verdict: AttentionNeeded'
            $r.Text | Should -Match '\[attention\]'
        }

        It 'exits 1 when the cluster cannot be read' {
            $global:AzlChkFail = $true
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
        }
    }

    Context 'it only reads' {
        It 'runs one remote read of the update environment and the updates, with nothing that changes the cluster' {
            $null = Invoke-Check (New-InfraFile)
            $global:AzlChkCalls.Count | Should -Be 1
            $block = $global:AzlChkCalls[0].Block
            $block | Should -Match 'Get-SolutionUpdateEnvironment'
            $block | Should -Match 'Get-SolutionUpdate\b'
            $block | Should -Not -Match 'Start-SolutionUpdate|Add-SolutionUpdate|Set-|Remove-|Install-|Restart-|New-|Invoke-'
            $global:AzlChkCalls[0].Computer | Should -Be 'azl-cluster-01'
        }

        It 'connects to -ComputerName instead of cluster.name and passes -Credential on' {
            $secure = ConvertTo-SecureString ([guid]::NewGuid().ToString()) -AsPlainText -Force
            $cred = [pscredential]::new('contoso\lcm', $secure)
            $null = Invoke-Check (New-InfraFile) @{ ComputerName = 'node-01'; Credential = $cred }
            $global:AzlChkCalls[0].Computer | Should -Be 'node-01'
            $global:AzlChkCalls[0].Credential.UserName | Should -Be 'contoso\lcm'
        }
    }

    Context 'waiting for the first update after a deployment' {
        It 'reads again until an update is offered (-WaitMinutes)' {
            $global:AzlChkAppearsOnRead = 3
            $r = Invoke-Check (New-InfraFile) @{ WaitMinutes = 30; PollSeconds = 60 }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlChkReads | Should -Be 3
            Should -Invoke Start-Sleep -Times 2 -ParameterFilter { $Seconds -eq 60 }
            $r.Rows[0].Next | Should -Be 'Start'
        }

        It 'stops waiting when the time is over, reports UpToDate and exits 0' {
            $global:AzlChkAppearsOnRead = 999
            $r = Invoke-Check (New-InfraFile) @{ WaitMinutes = 5; PollSeconds = 60 }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlChkReads | Should -BeLessOrEqual 7
            $r.Text | Should -Match 'Verdict: UpToDate'
        }

        It 'stops waiting at once with AttentionNeeded and exit 1 for <Case>: it does not sleep and reads once' -ForEach @(
            @{ Case = 'an update in InstallationFailed'; Set = { $global:AzlChkState.Updates = @((New-Update '12.2607.1002.20' 'Installed'), (New-Update '12.2610.1004.50' 'InstallationFailed')) } }
            @{ Case = 'an update in HealthCheckFailed'; Set = { $global:AzlChkState.Updates = @((New-Update '12.2607.1002.20' 'Installed'), (New-Update '12.2610.1004.50' 'HealthCheckFailed')) } }
            @{ Case = 'an update in ScanFailed'; Set = { $global:AzlChkState.Updates = @((New-Update '12.2607.1002.20' 'Installed'), (New-Update '12.2610.1004.50' 'ScanFailed')) } }
            @{ Case = 'a health state of Failure'; Set = { $global:AzlChkState.HealthState = 'Failure'; $global:AzlChkState.Updates = @((New-Update '12.2607.1002.20' 'Installed')) } }
            @{ Case = 'a health state of Warning'; Set = { $global:AzlChkState.HealthState = 'Warning'; $global:AzlChkState.Updates = @((New-Update '12.2607.1002.20' 'Installed')) } }
            @{ Case = 'an update environment in UpdateFailed'; Set = { $global:AzlChkState.State = 'UpdateFailed'; $global:AzlChkState.Updates = @((New-Update '12.2607.1002.20' 'Installed')) } }
            @{ Case = 'an update environment in PreparationFailed'; Set = { $global:AzlChkState.State = 'PreparationFailed'; $global:AzlChkState.Updates = @((New-Update '12.2607.1002.20' 'Installed')) } }
        ) {
            & $Set
            $r = Invoke-Check (New-InfraFile) @{ WaitMinutes = 120; PollSeconds = 60 }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'Verdict: AttentionNeeded'
            $global:AzlChkReads | Should -Be 1
            Should -Invoke Start-Sleep -Times 0
        }

        It 'reads once and does not sleep without -WaitMinutes' {
            $global:AzlChkAppearsOnRead = 999
            $null = Invoke-Check (New-InfraFile)
            $global:AzlChkReads | Should -Be 1
            Should -Invoke Start-Sleep -Times 0
        }
    }

    Context 'the JSON report (-OutputPath)' {
        It 'writes the whole report as JSON, creating the folder' {
            $out = Join-Path $TestDrive 'reports/check.json'
            $r = Invoke-Check (New-InfraFile) @{ OutputPath = $out }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $json = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $json.Verdict | Should -Be 'UpdateAvailable'
            $json.CurrentVersion | Should -Be '12.2607.1002.20'
            $json.Cluster | Should -Be 'azl-cluster-01'
            @($json.Updates).Count | Should -Be 2
            (@($json.Updates | Where-Object Next -EQ 'Start')).Version | Should -Be '12.2610.1004.50'
        }
    }

    Context 'values that are not usable (exit 2, nothing sent)' {
        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a missing cluster name'; Opts = @{ Cluster = '' } }
            @{ Case = 'a target that is not a version'; Opts = @{ Target = '12.2610' } }
        ) {
            $r = Invoke-Check (New-InfraFile @Opts)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $global:AzlChkCalls.Count | Should -Be 0
        }

        It 'refuses a file that does not exist' {
            (Invoke-Check (Join-Path $TestDrive 'nowhere.yml')).ExitCode | Should -Be 2
        }
    }
}

Describe 'Get-AvailableSolutionUpdate.azcli.ps1 (Azure)' {
    BeforeEach {
        Reset-Cluster
        $global:AzlChkAzCalls = [System.Collections.Generic.List[string]]::new()
        $global:AzlChkAz = @{
            SignedIn = $true; Tenant = $global:AzlChkTenant; Rest = @{}
            State = 'UpdateAvailable'; LastChecked = [datetime]::UtcNow.AddHours(-3).ToString('o'); HealthChecks = @()
            Updates = @(
                @{ name = 'Solution12.2607.1002.20'; properties = @{ version = '12.2607.1002.20'; state = 'Installed'; packageType = 'Solution'; displayName = 'old' } }
                @{ name = 'Solution12.2610.1004.50'; properties = @{ version = '12.2610.1004.50'; state = 'Ready'; packageType = 'Solution'; displayName = 'new'; updateStateProperties = @{ notifyMessage = '' } } }
            )
            NotFound = $false; FailList = $false; Health = 'Success'; NextLink = ''; PageTwo = @(); NextAlways = $false; RestoreFails = $false
        }
        Mock az {
            $global:LASTEXITCODE = 0
            $line = $args -join ' '
            $global:AzlChkAzCalls.Add($line)
            $s = $global:AzlChkAz
            if ($line -like 'account show*') {
                if (-not $s.SignedIn) { $global:LASTEXITCODE = 1; return 'Please run az login' }
                return @($s.Tenant, $global:AzlChkHome)
            }
            if ($line -like 'account set*') {
                if ($s.RestoreFails -and $args[-1] -eq $global:AzlChkHome) { $global:LASTEXITCODE = 1; return 'ERROR: the subscription was removed' }
                return
            }
            if ($line -like 'rest*updateSummaries/default*') {
                if ($s.NotFound) { $global:LASTEXITCODE = 1; return 'ERROR: (ResourceNotFound) The Resource was not found 404' }
                return (@{ name = 'default'; properties = @{ currentVersion = '12.2607.1002.20'; currentSbeVersion = '4.1.2410.5'; hardwareModel = 'Model-1'; state = $s.State; healthState = $s.Health; lastChecked = $s.LastChecked; healthCheckResult = $s.HealthChecks } } | ConvertTo-Json -Depth 8)
            }
            if ($line -like 'rest*/updates --url-parameters*') {
                if ($s.NextAlways) { return (@{ value = @(); nextLink = $s.NextLink } | ConvertTo-Json -Depth 8) }
                return (@{ value = $s.PageTwo } | ConvertTo-Json -Depth 8)
            }
            if ($line -like 'rest*/updates?api-version*') {
                if ($s.FailList) { $global:LASTEXITCODE = 1; return 'ERROR: Forbidden' }
                $page = @{ value = $s.Updates }
                if ($s.NextLink) { $page.nextLink = $s.NextLink }
                return ($page | ConvertTo-Json -Depth 8)
            }
            $global:LASTEXITCODE = 1
            "unexpected az call: $line"
        }
    }


    It 'reads the update summary and the updates of the cluster resource from the file values, with GET only, in the subscription of the file' {
        $r = Invoke-CheckCli (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $rest = @($global:AzlChkAzCalls | Where-Object { $_ -like 'rest*' })
        $rest.Count | Should -Be 2
        $base = "/subscriptions/$($global:AzlChkSubscription)/resourceGroups/rg-azl-01/providers/Microsoft.AzureStackHCI/clusters/azl-cluster-01"
        # no host: az rest prefixes the ARM endpoint of the cloud it is set to (Learn: az rest, --url)
        $rest[0] | Should -BeLike "rest --method get --url $base/updateSummaries/default?api-version=2024-04-01*"
        $rest[1] | Should -BeLike "rest --method get --url $base/updates?api-version=2024-04-01*"
        @($global:AzlChkAzCalls | Where-Object { $_ -match 'https?://|management\.azure\.com' }).Count | Should -Be 0
        @($global:AzlChkAzCalls | Where-Object { $_ -match '--method (post|put|patch|delete)' }).Count | Should -Be 0
        $global:AzlChkAzCalls | Should -Contain "account set --subscription $($global:AzlChkSubscription)"
        $global:AzlChkAzCalls[-1] | Should -Be "account set --subscription $($global:AzlChkHome)"
    }

    It 'lists the offered update and the verdict UpdateAvailable' {
        $r = Invoke-CheckCli (New-InfraFile)
        $r.Rows.Count | Should -Be 1
        $r.Rows[0].Update | Should -Be '12.2610.1004.50'
        $r.Rows[0].Next | Should -Be 'Start'
        $r.Text | Should -Match 'Verdict: UpdateAvailable'
    }

    It 'says AdditionalContentRequired and UpdateRunning for those states' {
        $global:AzlChkAz.Updates = @(@{ name = 'a'; properties = @{ version = '12.2610.1004.50'; state = 'AdditionalContentRequired'; packageType = 'Solution' } })
        (Invoke-CheckCli (New-InfraFile)).Text | Should -Match 'Verdict: AdditionalContentRequired'
        $global:AzlChkAz.Updates = @(@{ name = 'a'; properties = @{ version = '12.2610.1004.50'; state = 'Installing'; packageType = 'Solution' } })
        (Invoke-CheckCli (New-InfraFile)).Text | Should -Match 'Verdict: UpdateRunning'
    }

    It 'exits 1 with AttentionNeeded for <Case>' -ForEach @(
        @{ Case = 'a failed update'; Set = { $global:AzlChkAz.Updates = @(@{ name = 'a'; properties = @{ version = '12.2610.1004.50'; state = 'InstallationFailed'; packageType = 'Solution' } }) } }
        @{ Case = 'a cluster in UpdateFailed'; Set = { $global:AzlChkAz.State = 'UpdateFailed' } }
        @{ Case = 'a failed critical readiness check'; Set = { $global:AzlChkAz.HealthChecks = @(@{ title = 'Storage not healthy'; status = 'Failed'; severity = 'Critical' }) } }
        @{ Case = 'an update service that has not checked for days'; Set = { $global:AzlChkAz.LastChecked = [datetime]::UtcNow.AddHours(-100).ToString('o') } }
    ) {
        & $Set
        $r = Invoke-CheckCli (New-InfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'Verdict: AttentionNeeded'
    }

    It 'follows the next link of the list of updates (keeping the query as --url-parameters, with no host and no & in an argument) and reads the updates of every page' {
        $global:AzlChkAz.NextLink = "https://management.azure.com/subscriptions/$($global:AzlChkSubscription)/resourceGroups/rg-azl-01/providers/Microsoft.AzureStackHCI/clusters/azl-cluster-01/updates?api-version=2024-04-01&`$skiptoken=abc%3D%3D"
        $global:AzlChkAz.PageTwo = @(@{ name = 'Solution12.2612.1001.90'; properties = @{ version = '12.2612.1001.90'; state = 'InstallationFailed'; packageType = 'Solution'; displayName = 'page two' } })
        $r = Invoke-CheckCli (New-InfraFile)
        $r.ExitCode | Should -Be 1 -Because 'the update on the second page is in a failed state'
        $r.Text | Should -Match 'Verdict: AttentionNeeded'
        @($r.Rows | Where-Object Update -EQ '12.2612.1001.90').Count | Should -Be 1
        $second = @($global:AzlChkAzCalls | Where-Object { $_ -like 'rest*--url-parameters*' })
        $second.Count | Should -Be 1
        $second[0] | Should -BeLike 'rest --method get --url /subscriptions/*/updates --url-parameters api-version=2024-04-01 $skiptoken=abc== --output json*'
        $second[0] | Should -Not -Match '&|https?:|%'
    }

    It 'stops after 50 pages with exit 1 instead of looping for ever' {
        $global:AzlChkAz.NextAlways = $true
        $global:AzlChkAz.NextLink = "https://management.azure.com/subscriptions/$($global:AzlChkSubscription)/resourceGroups/rg-azl-01/providers/Microsoft.AzureStackHCI/clusters/azl-cluster-01/updates?api-version=2024-04-01&`$skiptoken=again"
        $r = Invoke-CheckCli (New-InfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'more than 50 pages'
        @($global:AzlChkAzCalls | Where-Object { $_ -like '*/updates?api-version*' -or $_ -like '*/updates --url-parameters*' }).Count | Should -Be 50
    }

    It 'refuses a next link whose query holds a character that cannot be sent safely (exit 1, never an az call with it)' {
        $global:AzlChkAz.NextLink = "https://management.azure.com/subscriptions/$($global:AzlChkSubscription)/resourceGroups/rg-azl-01/providers/Microsoft.AzureStackHCI/clusters/azl-cluster-01/updates?api-version=2024-04-01&`$skiptoken=a%26b"
        $r = Invoke-CheckCli (New-InfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'cannot be sent to the Azure CLI safely'
        @($global:AzlChkAzCalls | Where-Object { $_ -like 'rest*--url-parameters*' }).Count | Should -Be 0
    }

    It 'raises AttentionNeeded for a health state of <Health> (as the PowerShell variant does), and not for Success' -ForEach @(@{ Health = 'Failure' }, @{ Health = 'Error' }, @{ Health = 'Warning' }) {
        $global:AzlChkAz.Health = $Health
        $r = Invoke-CheckCli (New-InfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'Verdict: AttentionNeeded'
        $r.Text | Should -Match "health of the update environment is $Health"
        $global:AzlChkAz.Health = 'Success'
        (Invoke-CheckCli (New-InfraFile)).ExitCode | Should -Be 0
    }

    It 'warns and exits 1 when the earlier subscription cannot be put back, also when everything else was fine' {
        $global:AzlChkAz.RestoreFails = $true
        $r = Invoke-CheckCli (New-InfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'could not be put back'
        $r.Text | Should -Match 'az account set --subscription'
    }

    It 'takes -MaxCheckAgeHours into account' {
        $global:AzlChkAz.LastChecked = [datetime]::UtcNow.AddHours(-60).ToString('o')
        (Invoke-CheckCli (New-InfraFile) @{ MaxCheckAgeHours = 72 }).ExitCode | Should -Be 0
        (Invoke-CheckCli (New-InfraFile) @{ MaxCheckAgeHours = 48 }).ExitCode | Should -Be 1
    }

    It 'writes the JSON report with -OutputPath' {
        $out = Join-Path $TestDrive 'azure/check.json'
        $r = Invoke-CheckCli (New-InfraFile) @{ OutputPath = $out }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $json = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        $json.Verdict | Should -Be 'UpdateAvailable'
        $json.CurrentVersion | Should -Be '12.2607.1002.20'
        @($json.Updates).Count | Should -Be 2
    }

    It 'exits 1 when az is not signed in, signed in to another tenant, or the cluster resource is not found' {
        $global:AzlChkAz.SignedIn = $false
        (Invoke-CheckCli (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlChkAz.SignedIn = $true; $global:AzlChkAz.Tenant = [guid]::NewGuid().ToString()
        (Invoke-CheckCli (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlChkAz.Tenant = $global:AzlChkTenant; $global:AzlChkAz.NotFound = $true
        $r = Invoke-CheckCli (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'was not found'
    }

    It 'exits 1 when the updates cannot be read, and still puts the earlier subscription back' {
        $global:AzlChkAz.FailList = $true
        (Invoke-CheckCli (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlChkAzCalls[-1] | Should -Be "account set --subscription $($global:AzlChkHome)"
    }

    It 'exits 2 for a missing key, before it calls az: <Case>' -ForEach @(
        @{ Case = 'no tenant'; Opts = @{ Tenant = $null } }
        @{ Case = 'no subscription'; Opts = @{ Subscription = $null } }
        @{ Case = 'no resource group'; Opts = @{ ResourceGroup = '' } }
        @{ Case = 'no cluster name'; Opts = @{ Cluster = '' } }
        @{ Case = 'an unsafe resource group'; Opts = @{ ResourceGroup = 'rg&calc' } }
    ) {
        $r = Invoke-CheckCli (New-InfraFile @Opts)
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $global:AzlChkAzCalls.Count | Should -Be 0
    }

    It 'never runs az with a character the Windows command file would read as a command' {
        $text = Get-Content -LiteralPath $script:ScriptCli -Raw
        $text | Should -Match 'AzlAzureCliArgument\.psm1'
        $text | Should -Match 'Get-AzlAzureCliArgumentProblem'
        $text | Should -Match 'Get-AzlAzureCliValueProblem'
        $text | Should -Not -Match 'UnsafeArgument'
        ([regex]::Matches($text, '&\s+az\s')).Count | Should -Be 1 -Because 'one call site, guarded'
    }
}
