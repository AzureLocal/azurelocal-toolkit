#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Arc registration of an ISO-installed node: the failures seen on real nodes and what the run does about each. No node, no Azure: Invoke-AzlNodeScript,
# Find-AzlArcMachine, Get-AzlArmToken, the ARM delete and the sleeps are replaced.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/ArcRegistrationRetry.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $dir = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'common', 'node-configuration')
    Import-Module (Join-Path $dir 'AzlOsConfigurationRun.psm1') -Force
    $script:Issues = Get-Content -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'config', 'known-issues', 'arm-deployment.json')) -Raw | ConvertFrom-Json -Depth 20
}

Describe 'Resolve-AzlArcRegistrationFailure' {
    It '<Kind> for "<Text>": retry <Retry>, wait <Wait>' -ForEach @(
        @{ Text = 'AZCM0044: the resource already exists'; Kind = 'ResourceExists'; Retry = $true; Wait = $false }
        @{ Text = 'The Arc machine resource already exists in the resource group'; Kind = 'ResourceExists'; Retry = $true; Wait = $false }
        @{ Text = 'AZCM0042: could not authenticate'; Kind = 'AuthFailed'; Retry = $true; Wait = $false }
        @{ Text = 'The remote server returned an error: (401) Unauthorized'; Kind = 'AuthFailed'; Retry = $true; Wait = $false }
        @{ Text = 'Exception 0x8009030e: No credentials are available in the security package'; Kind = 'LogonSession'; Retry = $true; Wait = $false }
        @{ Text = 'A specified logon session does not exist. It may already have been terminated.'; Kind = 'LogonSession'; Retry = $true; Wait = $false }
        @{ Text = 'The I/O operation has been aborted because of either a thread exit or an application request.'; Kind = 'IoAborted'; Retry = $false; Wait = $true }
        @{ Text = 'something else went wrong'; Kind = 'Unknown'; Retry = $false; Wait = $false }
    ) {
        $r = Resolve-AzlArcRegistrationFailure -Message $Text
        $r.Kind | Should -Be $Kind
        $r.Retry | Should -Be $Retry
        $r.Wait | Should -Be $Wait
        if ($Kind -ne 'Unknown') { $r.Advice | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Invoke-AzlArcRegistration' {
    BeforeEach {
        $global:ArcRegCalls = [System.Collections.Generic.List[string]]::new()
        $global:ArcRegScript = { $global:ArcRegCalls.Add('register') }
        $global:ArcRegDeleted = [System.Collections.Generic.List[string]]::new()
        $global:ArcRegArc = @('none')
        $global:ArcRegTokens = 0
        $global:ArcRegPort = $true
        Mock -ModuleName AzlOsConfigurationRun Start-Sleep { }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlArmToken { $global:ArcRegTokens++; [pscustomobject]@{ Token = "token-$($global:ArcRegTokens)"; AccountId = 'operator@example.invalid' } }
        Mock -ModuleName AzlOsConfigurationRun New-AzlWinRmTransport { $global:ArcRegCalls.Add('transport'); [pscustomobject]@{ Kind = 'WinRM' } }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlNodePayload { 'arc-registration-script' }
        Mock -ModuleName AzlOsConfigurationRun Test-AzlWinRmPort { $global:ArcRegCalls.Add('port'); $global:ArcRegPort }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript { & $global:ArcRegScript }
        Mock -ModuleName AzlOsConfigurationRun Find-AzlArcMachine {
            $global:ArcRegCalls.Add('find')
            # The queue of answers: the first is used once while more follow, the last stays. 'none' stands for no Arc machine found.
            $queue = @($global:ArcRegArc)
            $next = $queue[0]
            if ($queue.Count -gt 1) { $global:ArcRegArc = @($queue | Select-Object -Skip 1) }
            if ($next -is [string]) { return $null }
            $next
        }
        Mock -ModuleName AzlOsConfigurationRun Remove-AzlStaleArcMachine { $global:ArcRegDeleted.Add($ResourceId); $true }
        Mock -ModuleName AzlOsConfigurationRun Send-AzlRunEvent { }
        Mock -ModuleName AzlOsConfigurationRun Write-Warning { }
        $script:Context = [pscustomobject]@{
            Infra = [ordered]@{ azure = [ordered]@{ subscription_id = '00000000-0000-0000-0000-000000000000'; resource_group = 'rg-iic-azl-01'; tenant_id = '00000000-0000-0000-0000-000000000001'; location = 'eastus' }; scenario = [ordered]@{ outbound_path = 'direct' } }
            CredentialInfo = [pscustomobject]@{ Credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }
            EventLogPath = ''
        }
        $script:Record = [ordered]@{ name = 'iic-n02'; address = '192.0.2.12' }
        $script:Node = [ordered]@{ name = 'iic-n02' }
        $script:Connected = [pscustomobject]@{ Name = 'iic-n02'; ResourceId = '/subscriptions/x/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/iic-n02'; Status = 'Connected' }
        $script:Stale = [pscustomobject]@{ Name = 'iic-n02'; ResourceId = '/subscriptions/x/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/iic-n02'; Status = 'Disconnected' }
    }
    AfterAll { Remove-Variable ArcRegCalls, ArcRegScript, ArcRegDeleted, ArcRegArc, ArcRegTokens, ArcRegPort -Scope Global -ErrorAction SilentlyContinue }

    It 'registers once when nothing goes wrong, and returns the Connected Arc machine' {
        $global:ArcRegArc = @($script:Connected)
        $arc = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $script:Context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N }
        $arc.Status | Should -Be 'Connected'
        @($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count | Should -Be 1
        $global:ArcRegDeleted.Count | Should -Be 0
    }
    It 'AZCM0044: deletes the stale (not Connected) Arc resource, registers again, and ends Connected' {
        $global:ArcRegScript = { $global:ArcRegCalls.Add('register'); if (@($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count -eq 1) { throw 'AZCM0044: the resource already exists' } }
        $global:ArcRegArc = @($script:Stale, $script:Connected)
        $arc = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $script:Context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N }
        @($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count | Should -Be 2
        $global:ArcRegDeleted.Count | Should -Be 1
        $global:ArcRegDeleted[0] | Should -Match 'machines/iic-n02$'
        $arc.Status | Should -Be 'Connected'
    }
    It 'AZCM0044 on an Arc machine that is already Connected: nothing is deleted and nothing is registered again' {
        $global:ArcRegScript = { $global:ArcRegCalls.Add('register'); throw 'AZCM0044: the resource already exists' }
        $global:ArcRegArc = @($script:Connected)
        $arc = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $script:Context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N }
        $arc.Status | Should -Be 'Connected'
        $global:ArcRegDeleted.Count | Should -Be 0
        @($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count | Should -Be 1
    }
    It 'AZCM0042 or 401: takes a new token and registers again with it' {
        $global:ArcRegScript = { $global:ArcRegCalls.Add('register'); if (@($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count -eq 1) { throw 'AZCM0042: (401) Unauthorized' } }
        $global:ArcRegArc = @($script:Connected)
        $null = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $script:Context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N }
        $global:ArcRegTokens | Should -Be 2
        @($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count | Should -Be 2
    }
    It '0x8009030e: opens a new WinRM session and registers again' {
        $global:ArcRegScript = { $global:ArcRegCalls.Add('register'); if (@($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count -eq 1) { throw 'Exception 0x8009030e' } }
        $global:ArcRegArc = @($script:Connected)
        $null = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $script:Context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N }
        @($global:ArcRegCalls | Where-Object { $_ -eq 'transport' }).Count | Should -Be 2
        @($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count | Should -Be 2
    }
    It 'I/O operation aborted (the node restarts mid-bootstrap): never registers again; waits for the node, then for the Arc machine' {
        $global:ArcRegScript = { $global:ArcRegCalls.Add('register'); throw 'The I/O operation has been aborted because of either a thread exit or an application request.' }
        $global:ArcRegArc = @('none', $script:Connected)
        $arc = InModuleScope AzlOsConfigurationRun -Parameters @{ C = $script:Context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N }
        @($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count | Should -Be 1
        @($global:ArcRegCalls | Where-Object { $_ -eq 'port' }).Count | Should -BeGreaterThan 0
        $arc.Status | Should -Be 'Connected'
    }
    It 'an unknown failure is not retried and is thrown as it was' {
        $global:ArcRegScript = { $global:ArcRegCalls.Add('register'); throw 'something else went wrong' }
        { InModuleScope AzlOsConfigurationRun -Parameters @{ C = $script:Context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N } } | Should -Throw '*something else went wrong*'
        @($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count | Should -Be 1
    }
    It 'gives up after three tries with the last error' {
        $global:ArcRegScript = { $global:ArcRegCalls.Add('register'); throw 'Exception 0x8009030e' }
        { InModuleScope AzlOsConfigurationRun -Parameters @{ C = $script:Context; R = $script:Record; N = $script:Node } { Invoke-AzlArcRegistration -Context $C -Record $R -Node $N } } | Should -Throw '*0x8009030e*'
        @($global:ArcRegCalls | Where-Object { $_ -eq 'register' }).Count | Should -Be 3
    }
}

Describe 'Remove-AzlStaleArcMachine' {
    It 'refuses a Connected machine and deletes any other through ARM' {
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlArm { $global:ArcRegDeleted2 = "$Method $Path" }
        InModuleScope AzlOsConfigurationRun { Remove-AzlStaleArcMachine -ResourceId '/x/y' -Status Connected -Confirm:$false } | Should -BeFalse
        $global:ArcRegDeleted2 | Should -BeNullOrEmpty
        InModuleScope AzlOsConfigurationRun { Remove-AzlStaleArcMachine -ResourceId '/x/y' -Status Disconnected -Confirm:$false } | Should -BeTrue
        $global:ArcRegDeleted2 | Should -Be 'DELETE /x/y'
        Remove-Variable ArcRegDeleted2 -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'The Arc registration known issues (config/known-issues/arm-deployment.json)' {
    It '<Id> is a known issue with a match, a remediation and a retry rule' -ForEach @(@{ Id = 'arc-registration-resource-exists' }, @{ Id = 'arc-registration-unauthorized' }, @{ Id = 'arc-registration-logon-session' }, @{ Id = 'arc-registration-io-aborted' }) {
        $issue = $script:Issues.issues | Where-Object id -eq $Id
        $issue | Should -Not -BeNullOrEmpty
        $issue.match.error | Should -Not -BeNullOrEmpty
        @($issue.remediation).Count | Should -BeGreaterThan 1
        $issue.retry | Should -BeIn 'none', 'after-fix', 'resubmit-once', 'no-validate'
    }
    It 'the error patterns match the texts of the real failures' {
        $byId = @{}; foreach ($i in $script:Issues.issues) { $byId[$i.id] = $i }
        'AZCM0044 the resource already exists' | Should -Match $byId['arc-registration-resource-exists'].match.error
        'AZCM0042 (401) Unauthorized' | Should -Match $byId['arc-registration-unauthorized'].match.error
        'Exception 0x8009030e' | Should -Match $byId['arc-registration-logon-session'].match.error
        'The I/O operation has been aborted' | Should -Match $byId['arc-registration-io-aborted'].match.error
    }
}
