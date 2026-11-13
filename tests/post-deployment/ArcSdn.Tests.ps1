#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 01: Enable-ArcSdn.ps1 turns on SDN enabled by Azure Arc (Add-EceFeature -Name NC) when sdn.enabled is true.
# Invoke-Command is mocked: no cluster, no machine, no credential and no Azure is used. The one secret is read from an environment variable made for the test.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/ArcSdn.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the machine state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
param()

# Test data is built while Pester discovers the tests, before any BeforeAll has run, so this helper is defined here and again in BeforeAll.
function New-Intent([string]$Name, [string[]]$Traffic) { [ordered]@{ name = $Name; traffic = @($Traffic); adapters = @('Port1', 'Port2') } }

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-01-deploy-sdn', 'powershell', 'Enable-ArcSdn.ps1')
    Import-Module powershell-yaml

    $script:PasswordVariable = 'AZL_TEST_SDN_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($script:PasswordVariable, [guid]::NewGuid().ToString())

    function New-Intent([string]$Name, [string[]]$Traffic) { [ordered]@{ name = $Name; traffic = @($Traffic); adapters = @('Port1', 'Port2') } }
    function New-InfraFile {
        param(
            [object]$Enabled = $true, [object]$Prefix = 'iic01', [object]$DnsMode = 'dynamic', [object]$AckWindow = $true, [object]$AckDns = $null,
            [object[]]$Intents = @((New-Intent 'mgmt_compute' @('management', 'compute')), (New-Intent 'storage' @('storage'))),
            [int]$Nodes = 2, [string]$Connectivity = 'switched', [string]$Architecture = 's2d', [string]$Identity = 'active_directory',
            [string]$Domain = 'improbability.cloud', [string]$PoolStart = '192.0.2.20', [string]$PoolEnd = '192.0.2.29',
            [object]$AdminPassword = $null, [switch]$NoSdn
        )
        if ($null -eq $AdminPassword) { $AdminPassword = "env://$($script:PasswordVariable)" }
        $doc = [ordered]@{
            scenario   = [ordered]@{ identity = $Identity; storage_architecture = $Architecture; storage_connectivity = $Connectivity }
            nodes      = @($(if ($Nodes -gt 0) { 1..$Nodes }) | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.$(10 + $_)" } } })
            networking = [ordered]@{ management = [ordered]@{ infrastructure_pool = [ordered]@{ start = $PoolStart; end = $PoolEnd } } }
            identity   = [ordered]@{ local_admin = [ordered]@{ username = 'azl-admin' } }
        }
        if ($Intents) { $doc.networking.intents = @($Intents) }
        if ($AdminPassword) { $doc.identity.local_admin.password = $AdminPassword }
        if ($Domain -and $Identity -eq 'active_directory') { $doc.identity.active_directory = [ordered]@{ domain_fqdn = $Domain } }
        if ($Domain -and $Identity -eq 'local_identity') { $doc.identity.local_identity = [ordered]@{ dns_zone = $Domain } }
        if (-not $NoSdn) {
            $sdn = [ordered]@{ enabled = $Enabled }
            if ($null -ne $Prefix) { $sdn.prefix = $Prefix }
            if ($null -ne $DnsMode) { $sdn.dns_records = $DnsMode }
            if ($null -ne $AckWindow) { $sdn.acknowledge_maintenance_window = $AckWindow }
            if ($null -ne $AckDns) { $sdn.acknowledge_dns_record = $AckDns }
            $doc.sdn = $sdn
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Machine {
        $global:AzlSdnCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlSdnState = @{ Computer = 'iic-n01'; OsBuild = 26100; HasEce = $true; NcGroups = @(); DnsAddresses = @() }
        $global:AzlSdnEnabledGroups = @('Network Controller')
        $global:AzlSdnFail = ''
    }
    # Runs the script and returns its exit code, its rows and every message as text.
    function Invoke-Sdn([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Step) { @($global:AzlSdnCalls | Where-Object Step -EQ $Step) }
}

Describe 'Enable-ArcSdn.ps1' {
    AfterAll {
        Remove-Variable -Name AzlSdnCalls, AzlSdnState, AzlSdnEnabledGroups, AzlSdnFail -Scope Global -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable($script:PasswordVariable, $null)
    }

    BeforeEach {
        Reset-Machine
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlSdnCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Arguments = @($ArgumentList | Select-Object -Skip 1); Credential = $Credential })
            if ($global:AzlSdnFail -eq $step) { throw "simulated failure of $step" }
            switch ($step) {
                'ReadState' {
                    $state = $global:AzlSdnState.Clone()
                    if (@($global:AzlSdnCalls | Where-Object Step -EQ 'Enable').Count -gt 0) { $state.NcGroups = @($global:AzlSdnEnabledGroups) }
                    $state
                }
            }
        }
    }

    Context 'nothing to do' {
        It 'does nothing and exits 0 when sdn.enabled is false' {
            $r = Invoke-Sdn (New-InfraFile -Enabled $false)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'cannot be turned off'
            $global:AzlSdnCalls.Count | Should -Be 0
        }

        It 'does nothing and exits 0 when the file has no sdn section' {
            $r = Invoke-Sdn (New-InfraFile -NoSdn)
            $r.ExitCode | Should -Be 0
            $global:AzlSdnCalls.Count | Should -Be 0
        }
    }

    Context 'enabling SDN' {
        It 'reads the machine, runs Add-EceFeature with the prefix, and reports Enabled' {
            $r = Invoke-Sdn (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows).Count | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Enabled'
            @($global:AzlSdnCalls.Step) | Should -Be @('ReadState', 'Enable', 'ReadState')
            $enable = (Get-Call 'Enable')[0]
            $enable.Arguments[0] | Should -Be 'iic01'
            $enable.Arguments[1] | Should -BeFalse
        }

        It 'connects to the management address of the first machine of nodes[], as the local administrator of the file, with the password from the secret reference' {
            $null = Invoke-Sdn (New-InfraFile)
            $call = (Get-Call 'Enable')[0]
            $call.Computer | Should -Be '192.0.2.11'
            $call.Credential.UserName | Should -Be '.\azl-admin'
            $call.Credential.GetNetworkCredential().Password | Should -Be ([Environment]::GetEnvironmentVariable($script:PasswordVariable))
        }

        It 'uses -ComputerName and -Credential when they are given' {
            $cred = [pscredential]::new('operator', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force))
            $null = Invoke-Sdn (New-InfraFile) -Extra @{ ComputerName = 'iic-n02'; Credential = $cred }
            (Get-Call 'Enable')[0].Computer | Should -Be 'iic-n02'
            (Get-Call 'Enable')[0].Credential.UserName | Should -Be 'operator'
        }

        It 'runs as the account that runs the script when the file has no password for the local administrator' {
            $null = Invoke-Sdn (New-InfraFile -AdminPassword '')
            (Get-Call 'Enable')[0].Credential | Should -BeNullOrEmpty
        }

        It 'passes the DNS acknowledgement only for static DNS, after the record is found on the machine' {
            $global:AzlSdnState.DnsAddresses = @('192.0.2.24')
            $r = Invoke-Sdn (New-InfraFile -DnsMode 'static' -AckDns $true)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'Enable')[0].Arguments[1] | Should -BeTrue
        }

        It 'looks up <prefix>-NC.<domain> and points it at the fifth address of the infrastructure pool' {
            $r = Invoke-Sdn (New-InfraFile)
            (Get-Call 'ReadState')[0].Arguments[0] | Should -Be 'iic01-NC.improbability.cloud'
            $r.Text | Should -Match '192\.0\.2\.24'
        }

        It 'accepts a record that already points at the fifth address with dynamic DNS' {
            $global:AzlSdnState.DnsAddresses = @('192.0.2.24')
            (Invoke-Sdn (New-InfraFile)).ExitCode | Should -Be 0
            (Get-Call 'Enable').Count | Should -Be 1
        }

        It 'uses identity.local_identity.dns_zone as the domain with local identity' {
            $null = Invoke-Sdn (New-InfraFile -Identity 'local_identity' -Domain 'zone.improbability.cloud')
            (Get-Call 'ReadState')[0].Arguments[0] | Should -Be 'iic01-NC.zone.improbability.cloud'
        }

        It 'warns that SDN cannot be undone, that workloads are interrupted, and that it takes up to 20 minutes' {
            $r = Invoke-Sdn (New-InfraFile)
            $r.Text | Should -Match 'CANNOT BE UNDONE'
            $r.Text | Should -Match 'interrupts the network of running workloads'
            $r.Text | Should -Match '20 minutes'
            $r.Text | Should -Match 'on-premises tools'
        }

        It 'still reports Enabled, with a warning, when the cluster group is not found by name after the action plan' {
            $global:AzlSdnEnabledGroups = @()
            $r = Invoke-Sdn (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'Enabled'
            $r.Text | Should -Match 'not found by name'
        }
    }

    Context 'the instance already has SDN (idempotent)' {
        It 'reports AlreadyEnabled, exits 0 and changes nothing' {
            $global:AzlSdnState.NcGroups = @('Network Controller')
            $r = Invoke-Sdn (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyEnabled'
            (Get-Call 'Enable').Count | Should -Be 0
        }

        It 'reports it even when the answers are no longer in the file, and when the DNS record is gone' {
            $global:AzlSdnState.NcGroups = @('Network Controller')
            $global:AzlSdnState.DnsAddresses = @('198.51.100.9')
            $r = Invoke-Sdn (New-InfraFile -AckWindow $false)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyEnabled'
        }

        It 'is the same on a second run: the first enables, the second finds the group' {
            $file = New-InfraFile
            (Invoke-Sdn $file).Rows[0].Action | Should -Be 'Enabled'
            $global:AzlSdnState.NcGroups = @('Network Controller')
            $global:AzlSdnCalls.Clear()
            (Invoke-Sdn $file).Rows[0].Action | Should -Be 'AlreadyEnabled'
            (Get-Call 'Enable').Count | Should -Be 0
        }
    }

    Context '-WhatIf' {
        It 'reads the machine, prints the plan and the warnings, runs nothing, and exits 0' {
            $r = Invoke-Sdn (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldEnable'
            @($global:AzlSdnCalls.Step) | Should -Be @('ReadState')
            $r.Text | Should -Match 'Plan: Add-EceFeature -Name NC -SDNPrefix iic01 -AcknowledgeMaintenanceWindow'
            $r.Text | Should -Match 'CANNOT BE UNDONE'
        }

        It 'shows the DNS acknowledgement in the plan for static DNS' {
            $global:AzlSdnState.DnsAddresses = @('192.0.2.24')
            $r = Invoke-Sdn (New-InfraFile -DnsMode 'static' -AckDns $true) -DryRun
            $r.Text | Should -Match '-AcknowledgeDNSRecordCreation'
        }

        It 'warns, and still exits 0, when an answer is missing that the real run would need' {
            $r = Invoke-Sdn (New-InfraFile -AckWindow $false) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'The real run would stop: sdn.acknowledge_maintenance_window'
            (Get-Call 'Enable').Count | Should -Be 0
        }

        It 'reports AlreadyEnabled under -WhatIf too' {
            $global:AzlSdnState.NcGroups = @('Network Controller')
            (Invoke-Sdn (New-InfraFile) -DryRun).Rows[0].Action | Should -Be 'AlreadyEnabled'
        }
    }

    Context 'a value in the file is missing or the design is not supported (exit 2, nothing changed)' {
        It 'refuses a missing prefix' {
            $r = Invoke-Sdn (New-InfraFile -Prefix $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'sdn.prefix is missing'
            $global:AzlSdnCalls.Count | Should -Be 0
        }

        It 'refuses the prefix <Prefix>' -ForEach @(
            @{ Prefix = 'ninechars' }, @{ Prefix = 'ab--cd' }, @{ Prefix = 'abc-' }, @{ Prefix = '-abc' }, @{ Prefix = 'ab_cd' }, @{ Prefix = 'ab cd' }
        ) {
            $r = Invoke-Sdn (New-InfraFile -Prefix $Prefix)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'sdn.prefix'
            $global:AzlSdnCalls.Count | Should -Be 0
        }

        It 'accepts the prefix <Prefix>' -ForEach @(@{ Prefix = 'a' }, @{ Prefix = 'ab-cd' }, @{ Prefix = 'ABcd1234' }, @{ Prefix = 'a-b-c-d' }) {
            (Invoke-Sdn (New-InfraFile -Prefix $Prefix)).ExitCode | Should -Be 0
        }

        It 'refuses sdn.dns_records that is missing or neither dynamic nor static' {
            (Invoke-Sdn (New-InfraFile -DnsMode $null)).ExitCode | Should -Be 2
            (Invoke-Sdn (New-InfraFile -DnsMode 'manual')).ExitCode | Should -Be 2
        }

        It 'refuses an sdn.enabled or an answer that is not true or false' {
            (Invoke-Sdn (New-InfraFile -Enabled 'yes')).ExitCode | Should -Be 2
            (Invoke-Sdn (New-InfraFile -AckWindow 'yes')).ExitCode | Should -Be 2
        }

        It 'refuses a missing or short infrastructure pool' {
            (Invoke-Sdn (New-InfraFile -PoolStart '')).ExitCode | Should -Be 2
            (Invoke-Sdn (New-InfraFile -PoolStart '192.0.2.20' -PoolEnd '192.0.2.23')).ExitCode | Should -Be 2
            $global:AzlSdnCalls.Count | Should -Be 0
        }

        It 'refuses static DNS without a domain to check the record in' {
            $r = Invoke-Sdn (New-InfraFile -DnsMode 'static' -AckDns $true -Domain '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'domain is missing'
        }

        It 'checks dynamic DNS no further, and says so, when the domain is missing' {
            $r = Invoke-Sdn (New-InfraFile -Domain '')
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'not checked'
            (Get-Call 'ReadState')[0].Arguments[0] | Should -Be ''
        }

        It 'refuses to enable without the maintenance window answer, after it has looked at the machine' {
            $r = Invoke-Sdn (New-InfraFile -AckWindow $false)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'sdn.acknowledge_maintenance_window'
            (Get-Call 'Enable').Count | Should -Be 0
        }

        It 'refuses static DNS without the DNS record answer' {
            $global:AzlSdnState.DnsAddresses = @('192.0.2.24')
            $r = Invoke-Sdn (New-InfraFile -DnsMode 'static' -AckDns $false)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'sdn.acknowledge_dns_record'
            (Get-Call 'Enable').Count | Should -Be 0
        }

        It 'does not need the DNS record answer with dynamic DNS' {
            (Invoke-Sdn (New-InfraFile -AckDns $false)).ExitCode | Should -Be 0
        }

        It 'refuses an intent layout Learn does not support: <Name>' -ForEach @(
            @{ Name = 'four intents'; Nodes = 2; Connectivity = 'switched'; Intents = @((New-Intent 'a' @('management')), (New-Intent 'b' @('compute')), (New-Intent 'c' @('storage')), (New-Intent 'd' @('compute'))); Match = 'at most three' }
            @{ Name = 'compute and storage without management'; Nodes = 2; Connectivity = 'switched'; Intents = @((New-Intent 'm' @('management')), (New-Intent 'cs' @('compute', 'storage'))); Match = 'compute and storage without management' }
            @{ Name = 'a standalone compute intent on one machine'; Nodes = 1; Connectivity = 'switched'; Intents = @((New-Intent 'm' @('management')), (New-Intent 'c' @('compute')), (New-Intent 's' @('storage'))); Match = 'single machine' }
            @{ Name = 'three intents, two machines, switchless'; Nodes = 2; Connectivity = 'switchless'; Intents = @((New-Intent 'm' @('management')), (New-Intent 'c' @('compute')), (New-Intent 's' @('storage'))); Match = 'switchless' }
            @{ Name = 'three intents, three machines, switchless'; Nodes = 3; Connectivity = 'switchless'; Intents = @((New-Intent 'm' @('management')), (New-Intent 'c' @('compute')), (New-Intent 's' @('storage'))); Match = 'switchless' }
            @{ Name = 'group all traffic with switchless storage'; Nodes = 2; Connectivity = 'switchless'; Intents = @((New-Intent 'all' @('management', 'compute', 'storage'))); Match = 'group-all' }
            @{ Name = 'five machines with switchless storage'; Nodes = 5; Connectivity = 'switchless'; Intents = @((New-Intent 'mc' @('management', 'compute')), (New-Intent 's' @('storage'))); Match = 'only with switched storage' }
            @{ Name = 'management and compute with no storage intent on two machines'; Nodes = 2; Connectivity = 'switched'; Intents = @((New-Intent 'mc' @('management', 'compute'))); Match = 'only on a single machine' }
        ) {
            $r = Invoke-Sdn (New-InfraFile -Nodes $Nodes -Connectivity $Connectivity -Intents $Intents)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlSdnCalls.Count | Should -Be 0
        }

        It 'accepts an intent layout Learn supports: <Name>' -ForEach @(
            @{ Name = 'group all traffic, switched'; Nodes = 2; Connectivity = 'switched'; Intents = @((New-Intent 'all' @('management', 'compute', 'storage'))) }
            @{ Name = 'management and compute, separate storage, switchless, four machines'; Nodes = 4; Connectivity = 'switchless'; Intents = @((New-Intent 'mc' @('management', 'compute')), (New-Intent 's' @('storage'))) }
            @{ Name = 'three intents, four machines, switchless'; Nodes = 4; Connectivity = 'switchless'; Intents = @((New-Intent 'm' @('management')), (New-Intent 'c' @('compute')), (New-Intent 's' @('storage'))) }
            @{ Name = 'management and compute alone on a single machine'; Nodes = 1; Connectivity = 'switched'; Intents = @((New-Intent 'mc' @('management', 'compute'))) }
            @{ Name = 'five machines, switched storage'; Nodes = 5; Connectivity = 'switched'; Intents = @((New-Intent 'mc' @('management', 'compute')), (New-Intent 's' @('storage'))) }
        ) {
            $r = Invoke-Sdn (New-InfraFile -Nodes $Nodes -Connectivity $Connectivity -Intents $Intents)
            $r.ExitCode | Should -Be 0 -Because $r.Text
        }

        It 'does not apply the storage intent rules to a SAN instance' {
            $r = Invoke-Sdn (New-InfraFile -Architecture 'san' -Intents @((New-Intent 'mc' @('management', 'compute'))))
            $r.ExitCode | Should -Be 0 -Because $r.Text
        }

        It 'warns, and goes on, when the file has no networking.intents' {
            $r = Invoke-Sdn (New-InfraFile -Intents @())
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'intent layout was not checked'
        }

        It 'refuses a password that is not a secret reference (2), and stops when the reference cannot be read (1)' {
            $r = Invoke-Sdn (New-InfraFile -AdminPassword ([guid]::NewGuid().ToString()))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}'
            (Invoke-Sdn (New-InfraFile -AdminPassword 'env://AZL_TEST_SDN_NOT_SET_ANYWHERE')).ExitCode | Should -Be 1   # the secret module's own code for a variable that is not set
            $global:AzlSdnCalls.Count | Should -Be 0
        }

        It 'refuses a file without nodes and without -ComputerName' {
            $r = Invoke-Sdn (New-InfraFile -Nodes 0)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'nodes\[\] is empty'
        }

        It 'refuses a file that does not exist' {
            (Invoke-Sdn (Join-Path $TestDrive 'nowhere.yml')).ExitCode | Should -Be 2
        }
    }

    Context 'a prerequisite is not met or a step fails (exit 1, nothing enabled)' {
        It 'stops when the machine cannot be read' {
            $global:AzlSdnFail = 'ReadState'
            $r = Invoke-Sdn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
            (Get-Call 'Enable').Count | Should -Be 0
        }

        It 'stops when Add-EceFeature is not on the machine' {
            $global:AzlSdnState.HasEce = $false
            $r = Invoke-Sdn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Add-EceFeature is not available'
            (Get-Call 'Enable').Count | Should -Be 0
        }

        It 'stops when the OS build is older than 26100, under -WhatIf too' {
            $global:AzlSdnState.OsBuild = 25398
            $r = Invoke-Sdn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match '25398'
            (Invoke-Sdn (New-InfraFile) -DryRun).ExitCode | Should -Be 1
            (Get-Call 'Enable').Count | Should -Be 0
        }

        It 'stops when static DNS is chosen and the record does not resolve' {
            $r = Invoke-Sdn (New-InfraFile -DnsMode 'static' -AckDns $true)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'does not resolve'
            (Get-Call 'Enable').Count | Should -Be 0
        }

        It 'stops on a DNS conflict, whichever DNS mode: the record points at another address' {
            $global:AzlSdnState.DnsAddresses = @('198.51.100.9')
            $r = Invoke-Sdn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'DNS conflict'
            $r.Text | Should -Match '198\.51\.100\.9'
            (Invoke-Sdn (New-InfraFile -DnsMode 'static' -AckDns $true)).ExitCode | Should -Be 1
            (Get-Call 'Enable').Count | Should -Be 0
        }

        It 'reports Failed, exits 1 and says to run it again when Add-EceFeature fails' {
            $global:AzlSdnFail = 'Enable'
            $r = Invoke-Sdn (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'run the script again'
        }

        It 'stops when the secret provider fails to give the password' {
            $r = Invoke-Sdn (New-InfraFile -AdminPassword 'keyvault://kv-iic-test-01/local-admin-password')
            $r.ExitCode | Should -BeIn 1, 2
            (Get-Call 'Enable').Count | Should -Be 0
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header, never prompts, and names no vault' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|keyvault://|Get-AzKeyVaultSecret|az keyvault|Connect-AzAccount\s*(-|$)'
        }

        It 'reads its values through the toolkit loader and the secret module, and holds no address, name or secret' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Match 'AzlSecret\.psm1'
            $script:Text | Should -Match 'Get-AzlSecretValue'
            $script:Text | Should -Not -Match 'variables\.yml|networking\.azure\.sdn|sdn_enabled|sdn_prefix'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            $script:Text | Should -Not -Match 'ConvertTo-SecureString|-AsPlainText'
        }

        It 'passes both acknowledgements only from the file and never as a fixed true' {
            $script:Text | Should -Match 'AcknowledgeMaintenanceWindow = \$true'   # inside the remote block, reached only after the file answered
            $script:Text | Should -Match 'sdn\.acknowledge_maintenance_window'
            $script:Text | Should -Match 'sdn\.acknowledge_dns_record'
        }

        It 'warns in its help and its plan that SDN cannot be undone and interrupts workloads' {
            $script:Text | Should -Match 'CANNOT BE UNDONE'
            $script:Text | Should -Match 'interrupts the network of running workloads'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Enable_ArcSdn_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach @(
            'sdn.enabled', 'sdn.prefix', 'sdn.dns_records', 'sdn.acknowledge_maintenance_window', 'sdn.acknowledge_dns_record',
            'networking.management.infrastructure_pool.start', 'networking.management.infrastructure_pool.end', 'networking.intents[].name', 'networking.intents[].traffic',
            'scenario.identity', 'scenario.storage_architecture', 'scenario.storage_connectivity', 'identity.active_directory.domain_fqdn', 'identity.local_identity.dns_zone',
            'identity.local_admin.username', 'identity.local_admin.password', 'nodes[].name', 'nodes[].management.ip_address'
        ) {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }

        It 'has registry rules for the prefix and the DNS mode that match what the script accepts' {
            $prefix = ($script:Registry | Where-Object Path -EQ 'sdn.prefix').Node
            $prefix['maxLength'] | Should -Be 8
            foreach ($good in 'a', 'ab-cd', 'ABcd1234') { $good -match $prefix['pattern'] | Should -BeTrue -Because $good }
            foreach ($bad in 'ab--cd', 'abc-', '-abc', 'ab_cd') { $bad -match $prefix['pattern'] | Should -BeFalse -Because $bad }
            @(($script:Registry | Where-Object Path -EQ 'sdn.dns_records').Node['enum']) | Should -Be @('dynamic', 'static')
        }

        It 'has the two answers off by default, since 5.6.15, and the removed key gone' {
            foreach ($key in 'sdn.acknowledge_maintenance_window', 'sdn.acknowledge_dns_record') {
                $node = ($script:Registry | Where-Object Path -EQ $key).Node
                $node['default'] | Should -BeFalse
                $node['since'] | Should -Be '5.6.15'
            }
            @($script:Registry | Where-Object Path -EQ 'sdn.default_access_policy').Count | Should -Be 0
            @($script:Registry | Where-Object Path -Match '^networking\.azure\.sdn\.sdn_(enabled|prefix|dns_mode|nc_reserved_ip|intent_pattern)$').Count | Should -Be 0
        }
    }
}
