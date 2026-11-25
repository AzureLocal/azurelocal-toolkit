#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 01: Test-ArcSdn.ps1 checks that SDN enabled by Azure Arc is on: the Network Controller cluster group and its resources
# are Online and the REST name resolves to the reserved address. Read only. Invoke-Command is mocked: no cluster, no machine, no credential and no Azure.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/TestArcSdn.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the machine state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-01-deploy-sdn', 'powershell', 'Test-ArcSdn.ps1')
    $script:Text = Get-Content -LiteralPath $script:Script -Raw
    Import-Module powershell-yaml

    $script:PasswordVariable = 'AZL_TEST_TSDN_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($script:PasswordVariable, [guid]::NewGuid().ToString())

    function New-InfraFile {
        param(
            [object]$Enabled = $true, [object]$Prefix = 'iic01', [string]$Identity = 'active_directory', [string]$Domain = 'improbability.cloud',
            [string]$PoolStart = '192.0.2.20', [string]$PoolEnd = '192.0.2.29', [switch]$LcmUser, [switch]$NoSdn, [int]$Nodes = 2, [string]$ClusterName = ''
        )
        $doc = [ordered]@{
            scenario   = [ordered]@{ identity = $Identity }
            nodes      = @($(if ($Nodes -gt 0) { 1..$Nodes }) | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.$(10 + $_)" } } })
            networking = [ordered]@{ management = [ordered]@{ infrastructure_pool = [ordered]@{ start = $PoolStart; end = $PoolEnd } } }
            identity   = [ordered]@{ local_admin = [ordered]@{ username = 'azl-admin'; password = "env://$($script:PasswordVariable)" } }
        }
        if ($ClusterName) { $doc.cluster = [ordered]@{ name = $ClusterName } }
        if ($Domain -and $Identity -eq 'active_directory') { $doc.identity.active_directory = [ordered]@{ domain_fqdn = $Domain; netbios_name = 'IMPROB' } }
        if ($Domain -and $Identity -eq 'local_identity') { $doc.identity.local_identity = [ordered]@{ dns_zone = $Domain } }
        if ($LcmUser) { $doc.identity.active_directory.lcm_user = [ordered]@{ username = 'lcm-iic01'; password = "env://$($script:PasswordVariable)" } }
        if (-not $NoSdn) {
            $sdn = [ordered]@{ enabled = $Enabled }
            if ($null -ne $Prefix) { $sdn.prefix = $Prefix }
            $doc.sdn = $sdn
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Group([string]$State = 'Online', [string[]]$ResourceStates = @('Online', 'Online')) {
        @{ Name = 'Network Controller'; State = $State; Owner = 'iic-n01'; Resources = @($ResourceStates | ForEach-Object -Begin { $i = 0 } -Process { $i++; @{ Name = "NC resource $i"; Type = 'Generic Service'; State = $_ } }) }
    }
    function Reset-Machine {
        $global:AzlTsdnCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlTsdnProbeFails = @()
        $global:AzlTsdnState = @{ Computer = 'iic-n01'; OsBuild = 26100; Groups = @((New-Group)); AllGroups = @('Cluster Group', 'Network Controller'); DnsAddresses = @('192.0.2.24') }
    }
    function Invoke-Check([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Check'] -and $_.PSObject.Properties['Result'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Result($Run, [string]$Pattern) { @($Run.Rows | Where-Object { $_.Check -match $Pattern }) }
}

Describe 'Test-ArcSdn.ps1' {
    AfterAll {
        Remove-Variable -Name AzlTsdnCalls, AzlTsdnState, AzlTsdnProbeFails -Scope Global -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable($script:PasswordVariable, $null)
    }

    BeforeEach {
        Reset-Machine
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlTsdnCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Arguments = @($ArgumentList | Select-Object -Skip 1); Credential = $Credential })
            if ($step -eq 'Probe' -and @($global:AzlTsdnProbeFails) -contains [string]$ComputerName) { throw "simulated: $ComputerName does not answer" }
            if ($step -eq 'Probe') { return 'iic-n01' }
            $global:AzlTsdnState
        }
    }

    Context 'nothing to check' {
        It 'exits 0 and asks no machine when sdn.enabled is false or the file has no sdn section' {
            (Invoke-Check (New-InfraFile -Enabled $false)).ExitCode | Should -Be 0
            $r = Invoke-Check (New-InfraFile -NoSdn)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'not planned'
            $global:AzlTsdnCalls.Count | Should -Be 0
        }
    }

    Context 'a healthy Network Controller' {
        It 'passes the build, the group, its resources and the DNS name, and exits 0' {
            $r = Invoke-Check (New-InfraFile -LcmUser)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Result -NE 'Pass').Count | Should -Be 0
            (Get-Result $r 'OS build')[0].Detail | Should -Be '26100'
            (Get-Result $r "cluster group 'Network Controller'")[0].Detail | Should -Match 'Online, owner iic-n01'
            (Get-Result $r 'cluster resources')[0].Detail | Should -Match '2 resource\(s\), all Online'
            (Get-Result $r 'DNS')[0].Detail | Should -Be 'iic01-NC.improbability.cloud points at 192.0.2.24'
        }

        It 'asks the machine as the deployment user of the file, at the management address of the first node' {
            $null = Invoke-Check (New-InfraFile -LcmUser)
            $call = @($global:AzlTsdnCalls | Where-Object Step -EQ 'ReadState')[0]
            $call.Computer | Should -Be '192.0.2.11'
            $call.Credential.UserName | Should -Be 'IMPROB\lcm-iic01'
            $call.Arguments[0] | Should -Be 'iic01-NC.improbability.cloud'
        }

        It 'uses the local administrator with local identity, and the zone of local identity for the name' {
            $r = Invoke-Check (New-InfraFile -Identity local_identity -Domain 'iic.local')
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($global:AzlTsdnCalls | Where-Object Step -EQ 'ReadState')[0].Credential.UserName | Should -Be '.\azl-admin'
            @($global:AzlTsdnCalls | Where-Object Step -EQ 'ReadState')[0].Arguments[0] | Should -Be 'iic01-NC.iic.local'
        }

        It 'uses -ComputerName and -Credential when they are given' {
            $cred = [pscredential]::new('operator', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force))
            $null = Invoke-Check (New-InfraFile) -Extra @{ ComputerName = 'iic-n02'; Credential = $cred }
            $call = @($global:AzlTsdnCalls | Where-Object Step -EQ 'ReadState')[0]
            $call.Computer | Should -Be '192.0.2.12'
            $call.Credential.UserName | Should -Be 'operator'
        }

        It 'moves on to the next node when the first does not answer' {
            $global:AzlTsdnProbeFails = @('192.0.2.11')
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($global:AzlTsdnCalls | Where-Object Step -EQ 'ReadState')[0].Computer | Should -Be '192.0.2.12'
        }
    }

    Context 'an unhealthy or missing Network Controller' {
        It 'fails (1) when no cluster group is named like Network Controller, and lists the groups it saw' {
            $global:AzlTsdnState.Groups = @()
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1
            (Get-Result $r 'cluster group')[0].Detail | Should -Match 'Cluster Group, Network Controller'
            (Get-Result $r 'cluster resources')[0].Result | Should -Be 'Fail'
        }

        It 'fails (1) when the group is not Online' {
            $global:AzlTsdnState.Groups = @((New-Group -State 'Offline'))
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1
            (Get-Result $r "cluster group 'Network Controller'")[0].Detail | Should -Match 'state Offline'
        }

        It 'fails (1) and names a cluster resource that is not Online' {
            $global:AzlTsdnState.Groups = @((New-Group -ResourceStates @('Online', 'Failed')))
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1
            (Get-Result $r 'cluster resources')[0].Detail | Should -Match 'NC resource 2 \(Failed\)'
        }

        It 'warns, and does not fail, when the group has no resource that could be read' {
            $global:AzlTsdnState.Groups = @((New-Group -ResourceStates @()))
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 0
            (Get-Result $r 'cluster resources')[0].Result | Should -Be 'Warn'
        }

        It 'fails (1) when the OS build is older than 26100' {
            $global:AzlTsdnState.OsBuild = 25398
            (Invoke-Check (New-InfraFile)).ExitCode | Should -Be 1
        }

        It 'fails (1) when the name does not resolve, or resolves to another address' {
            $global:AzlTsdnState.DnsAddresses = @()
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1
            (Get-Result $r 'DNS')[0].Detail | Should -Match 'does not resolve'
            $global:AzlTsdnState.DnsAddresses = @('192.0.2.99')
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1
            (Get-Result $r 'DNS')[0].Detail | Should -Match 'must point at 192\.0\.2\.24'
        }

        It 'fails (1) when no node answers' {
            $global:AzlTsdnProbeFails = @('192.0.2.11', '192.0.2.12')
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Check | Should -Be 'Connection'
        }
    }

    Context 'the prefix' {
        It 'checks the name <prefix>-NC with the prefix derived from cluster.name when sdn.prefix is not set, and says where it comes from' {
            $r = Invoke-Check (New-InfraFile -Prefix $null -ClusterName 'iic-azl-c01')
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'prefix \(derived from cluster\.name\): iicazlc0'
            (Get-Result $r 'DNS')[0].Detail | Should -Match '^iicazlc0-NC\.improbability\.cloud'
        }

        It 'uses sdn.prefix when both are set' {
            $r = Invoke-Check (New-InfraFile -Prefix 'own01' -ClusterName 'iic-azl-c01')
            $r.Text | Should -Match 'prefix \(sdn\.prefix\): own01'
            (Get-Result $r 'DNS')[0].Detail | Should -Match '^own01-NC\.'
        }
    }

    Context 'values of the file' {
        It 'exits 2 and asks no machine when the prefix or the pool is missing or too small, or sdn.enabled is not a boolean' {
            (Invoke-Check (New-InfraFile -Prefix $null)).ExitCode | Should -Be 2
            (Invoke-Check (New-InfraFile -PoolStart '192.0.2.20' -PoolEnd '192.0.2.23')).ExitCode | Should -Be 2
            (Invoke-Check (New-InfraFile -PoolStart 'x' -PoolEnd 'y')).ExitCode | Should -Be 2
            (Invoke-Check (New-InfraFile -Enabled 'yes')).ExitCode | Should -Be 2
            (Invoke-Check (New-InfraFile -Nodes 0)).ExitCode | Should -Be 2
            $global:AzlTsdnCalls.Count | Should -Be 0
        }

        It 'does not check the name, with a warning, when the file has no domain' {
            $r = Invoke-Check (New-InfraFile -Domain '')
            $r.ExitCode | Should -Be 0
            (Get-Result $r 'DNS')[0].Result | Should -Be 'Warn'
        }
    }

    Context '-WhatIf and the file itself' {
        It 'lists the four checks and asks no machine under -WhatIf' {
            $r = Invoke-Check (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            @($r.Rows).Count | Should -Be 4
            $global:AzlTsdnCalls.Count | Should -Be 0
        }

        It 'carries the standard header, never prompts, holds no address or vault, and only reads' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'Resolve-AzlSdnLogin'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|keyvault://|Get-AzKeyVaultSecret|az keyvault|Connect-AzAccount\s*(-|$)'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            $script:Text | Should -Not -Match 'Add-EceFeature\s+@|Start-ClusterGroup\s+-|Set-Cluster|Remove-|Stop-|Restart-'
        }

        It 'reads only keys that the registry knows' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($key in 'sdn.enabled', 'sdn.prefix', 'networking.management.infrastructure_pool.start', 'networking.management.infrastructure_pool.end', 'scenario.identity', 'identity.active_directory.domain_fqdn', 'identity.local_identity.dns_zone') {
                $script:Text | Should -Match ([regex]::Escape($key)) -Because "the script reads $key"
                $registry | Should -Match "(?m)^\s*$([regex]::Escape($key.Split('.')[-1])):" -Because "$key is a registry key"
            }
        }
    }
}
