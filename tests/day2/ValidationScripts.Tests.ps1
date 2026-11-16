#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Stage 07 (validation and handover), tasks 01 to 03: Test-AzureLocalClusterHealth.ps1, Test-ArcConnectivity.ps1 and Test-NetworkConfiguration.ps1 read cluster.name (and azure.location
# for the endpoint list) from infrastructure.yml, never ask, and end with exit code 0 (no check failed), 1 (a check failed) or 2 (a value is missing). The cluster cmdlets are
# stubs and Invoke-Command is mocked: no cluster, no node and no Azure is used. (Task 04, the storage test, has its own tests in tests/storage.)
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/day2/ValidationScripts.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the cluster state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cmdlets they replace.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $deploy = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '07-validation-handover')
    $script:Health = [IO.Path]::Combine($deploy, 'task-01-cluster-health-validation', 'powershell', 'Test-AzureLocalClusterHealth.ps1')
    $script:Arc = [IO.Path]::Combine($deploy, 'task-02-arc-connectivity-validation', 'powershell', 'Test-ArcConnectivity.ps1')
    $script:Network = [IO.Path]::Combine($deploy, 'task-03-network-configuration-validation', 'powershell', 'Test-NetworkConfiguration.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))

    # Stubs of the cluster cmdlets the scripts call (the real ones need the failover clustering tools).
    function Get-Cluster { param($Name) [pscustomobject]@{ Name = 'iic-azl-01'; Domain = 'improbability.cloud' } }
    function Get-ClusterNode { param($Cluster) @() }
    function Get-ClusterStorageSpacesDirect { param($CimSession) [pscustomobject]@{ State = 'Enabled' } }
    function Get-StoragePool { param($CimSession) @() }
    function Get-VirtualDisk { param($CimSession) @() }
    function Get-ClusterNetwork { param($Cluster) @() }
    function Get-ClusterQuorum { param($Cluster) [pscustomobject]@{ QuorumType = 'NodeAndCloudMajority'; QuorumResource = [pscustomobject]@{ Name = 'Cloud Witness' } } }

    function New-InfraFile {
        param([switch]$NoCluster, [switch]$NoLocation)
        $doc = [ordered]@{ azure = [ordered]@{ } }
        if (-not $NoLocation) { $doc.azure.location = 'eastus' }
        if (-not $NoCluster) { $doc.cluster = [ordered]@{ name = 'iic-azl-01' } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Cluster {
        $global:AzlValCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlValNodeState = 'Up'
        $global:AzlValArc = @{ Installed = $true; Status = 'Connected'; Error = ''; LastHeartbeat = '2026-01-01T00:00:00Z'; Extensions = @(@{ Name = 'AzureEdgeDeviceManagement'; State = 'Succeeded' }) }
        $global:AzlValProbeFailHost = ''
        $global:AzlValReadFails = $false
    }
    function Invoke-Script([string]$Script, [hashtable]$Arguments) {
        $global:LASTEXITCODE = $null
        $all = & $Script @Arguments 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Node'] -and $_.PSObject.Properties['Check'] })
            Text     = (@($all | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'the three validation scripts of stage 07' {
    AfterAll { Remove-Variable -Name AzlValCalls, AzlValNodeState, AzlValArc, AzlValProbeFailHost, AzlValReadFails -Scope Global -ErrorAction SilentlyContinue }

    Context 'the script text: <Name>' -ForEach @(
        @{ Name = 'Test-AzureLocalClusterHealth.ps1'; Key = 'Health' }
        @{ Name = 'Test-ArcConnectivity.ps1'; Key = 'Arc' }
        @{ Name = 'Test-NetworkConfiguration.ps1'; Key = 'Network' }
    ) {
        BeforeAll {
            $script:Path = Get-Variable -Name $Key -Scope Script -ValueOnly
            $script:Text = Get-Content -LiteralPath $script:Path -Raw
            $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$null, [ref]$null)
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match '(?m)^Set-StrictMode -Version Latest'
            $script:Text | Should -Match "(?m)^\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|Connect-AzAccount'
        }

        It 'takes -InfrastructureFile and no -ClusterName, -SubscriptionId or -ResourceGroup' {
            $names = @($script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $names | Should -Contain 'InfrastructureFile'
            foreach ($old in 'ClusterName', 'SubscriptionId', 'ResourceGroup') { $names | Should -Not -Contain $old }
        }

        It 'does not read the helpers folder that moved, and names no host of a deployment' {
            $script:Text | Should -Not -Match 'logging\.ps1|utilities\\helpers'
            ($script:Text -replace '(?s)<#.*?#>', '') | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $group = ($script:Path.Substring($script:Repo.Length + 1) -replace '[^A-Za-z0-9]', '_')
            $names = @($script:Registry | Where-Object { $_.Path -match ('^tools\.arm_deployment\.parameters\.' + [regex]::Escape($group) + '[^.]*\.[^.]+$') } | ForEach-Object { $_.Node['name'] })
            foreach ($p in @($script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })) { $names | Should -Contain $p -Because $p }
        }
    }

    Context 'values that are not usable (exit 2, nothing sent)' {
        BeforeEach {
            Reset-Cluster
            Mock Invoke-Command { $global:AzlValCalls.Add($ScriptBlock.ToString()); return $null }
        }

        It '<Name> ends with exit code 2 without a cluster name' -ForEach @(
            @{ Name = 'Test-AzureLocalClusterHealth.ps1'; Key = 'Health' }, @{ Name = 'Test-ArcConnectivity.ps1'; Key = 'Arc' }, @{ Name = 'Test-NetworkConfiguration.ps1'; Key = 'Network' }
        ) {
            $r = Invoke-Script (Get-Variable -Name $Key -Scope Script -ValueOnly) @{ InfrastructureFile = (New-InfraFile -NoCluster) }
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'cluster.name is missing'
            $global:AzlValCalls.Count | Should -Be 0
        }

        It '<Name> ends with exit code 2 for a file that does not exist' -ForEach @(
            @{ Name = 'Test-AzureLocalClusterHealth.ps1'; Key = 'Health' }, @{ Name = 'Test-ArcConnectivity.ps1'; Key = 'Arc' }, @{ Name = 'Test-NetworkConfiguration.ps1'; Key = 'Network' }
        ) {
            (Invoke-Script (Get-Variable -Name $Key -Scope Script -ValueOnly) @{ InfrastructureFile = (Join-Path $TestDrive 'nowhere.yml') }).ExitCode | Should -Be 2
        }

        It 'Test-ArcConnectivity.ps1 ends with exit code 2 without azure.location (the region of the endpoint list)' {
            $r = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile -NoLocation) }
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'azure.location is missing'
        }
    }

    Context 'Test-AzureLocalClusterHealth.ps1' {
        BeforeEach {
            Reset-Cluster
            Mock Get-Cluster { [pscustomobject]@{ Name = $Name; Domain = 'improbability.cloud' } }
            Mock Get-ClusterNode { @([pscustomobject]@{ Name = 'iic-n01'; State = $global:AzlValNodeState }, [pscustomobject]@{ Name = 'iic-n02'; State = 'Up' }) }
            Mock Get-StoragePool { [pscustomobject]@{ FriendlyName = 'SU1_Pool'; IsPrimordial = $false; HealthStatus = 'Healthy' } }
            Mock Get-VirtualDisk { @() }
            Mock Get-ClusterNetwork { [pscustomobject]@{ Name = 'Cluster Network 1'; State = 'Up'; Role = 'ClusterAndClient' } }
            Mock Invoke-Command { @{ Installed = $true; Status = 'Connected'; LastHeartbeat = '2026-01-01' } }
        }

        It 'exits 0 when every check passes, and asks the cluster named in the file' {
            $r = Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Overall Status: PASSED'
            Should -Invoke Get-Cluster -ParameterFilter { $Name -eq 'iic-azl-01' }
        }

        It 'exits 1 when a node is not Up' {
            $global:AzlValNodeState = 'Down'
            $r = Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'Overall Status: FAILED'
        }

        It 'exits 1 when the cluster cannot be reached' {
            Mock Get-Cluster { throw 'The cluster was not found.' }
            (Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile) }).ExitCode | Should -Be 1
        }

        It 'exits 1 for an unhealthy storage pool' {
            Mock Get-StoragePool { [pscustomobject]@{ FriendlyName = 'SU1_Pool'; IsPrimordial = $false; HealthStatus = 'Unhealthy' } }
            (Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile) }).ExitCode | Should -Be 1
        }

        It 'writes the report as JSON with -OutputFormat JSON' {
            $out = Join-Path $TestDrive 'health-reports'
            $null = New-Item -ItemType Directory -Path $out
            $r = Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile); OutputFormat = 'JSON'; OutputPath = $out }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $file = @(Get-ChildItem -LiteralPath $out -Filter 'cluster-health-*.json')
            $file.Count | Should -Be 1
            (Get-Content -LiteralPath $file[0].FullName -Raw | ConvertFrom-Json).ClusterName | Should -Be 'iic-azl-01'
        }
    }

    Context 'Test-ArcConnectivity.ps1' {
        BeforeEach {
            Reset-Cluster
            Mock Invoke-Command {
                $text = $ScriptBlock.ToString()
                $global:AzlValCalls.Add($text)
                if ($global:AzlValReadFails -and $text -match 'Get-ClusterNode') { throw 'The cluster could not be reached.' }
                switch -Regex ($text) {
                    'Get-ClusterNode' { return @('iic-n01', 'iic-n02') }
                    'azcmagent' { return $global:AzlValArc }
                    'BeginConnect' {
                        foreach ($t in $ArgumentList[0]) { @{ Host = $t.Host; Port = $t.Port; Ok = ($t.Host -ne $global:AzlValProbeFailHost); Error = $(if ($t.Host -eq $global:AzlValProbeFailHost) { 'timeout after 5 seconds' } else { '' }) } }
                        return
                    }
                }
            }
        }

        It 'passes agent, extensions and endpoints on both nodes and exits 0' {
            $r = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Status -EQ 'Passed').Count | Should -Be 6
            @($r.Rows | Where-Object Check -EQ 'Endpoints')[0].Detail | Should -Match 'reachable on 443'
        }

        It 'takes the endpoints from the shared documented list for the region of the file, not from the script' {
            $null = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile) }
            @($global:AzlValCalls | Where-Object { $_ -match 'BeginConnect' }).Count | Should -Be 2
            (Get-Content -LiteralPath $script:Arc -Raw) | Should -Not -Match 'management\.azure\.com|login\.microsoftonline\.com|arc\.azure\.com'
        }

        It 'fails an agent that is Disconnected or not installed, and warns for another status' -ForEach @(
            @{ Arc = @{ Installed = $true; Status = 'Disconnected'; Error = 'no route'; LastHeartbeat = ''; Extensions = @() }; Code = 1; Status = 'Failed' }
            @{ Arc = @{ Installed = $false }; Code = 1; Status = 'Failed' }
            @{ Arc = @{ Installed = $true; Status = 'Expired'; Error = ''; LastHeartbeat = ''; Extensions = @(@{ Name = 'x'; State = 'Succeeded' }) }; Code = 0; Status = 'Warning' }
        ) {
            $global:AzlValArc = $Arc
            $r = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be $Code -Because $r.Text
            (@($r.Rows | Where-Object Check -EQ 'Agent'))[0].Status | Should -Be $Status
        }

        It 'warns for an extension that is not Succeeded' {
            $global:AzlValArc.Extensions = @(@{ Name = 'AzureEdgeDeviceManagement'; State = 'Failed' })
            $r = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 0
            (@($r.Rows | Where-Object Check -EQ 'Extensions'))[0].Status | Should -Be 'Warning'
        }

        It 'fails and exits 1 when a required endpoint cannot be reached from a node' {
            $global:AzlValProbeFailHost = 'management.azure.com'
            $r = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            (@($r.Rows | Where-Object Check -EQ 'Endpoints'))[0].Detail | Should -Match 'management\.azure\.com'
        }

        It 'exits 1 when the cluster cannot be read' {
            $global:AzlValReadFails = $true
            (Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile) }).ExitCode | Should -Be 1
        }

        It 'saves the results as JSON in -OutputPath' {
            $out = Join-Path $TestDrive 'arc-reports'
            $r = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile); OutputPath = $out }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $file = @(Get-ChildItem -LiteralPath $out -Filter 'arc-connectivity-*.json')
            $file.Count | Should -Be 1
            (Get-Content -LiteralPath $file[0].FullName -Raw | ConvertFrom-Json).Failed | Should -Be 0
        }

        It 'calls no Azure command and does not sign in' {
            (Get-Content -LiteralPath $script:Arc -Raw) | Should -Not -Match '(?m)^\s*(\$null = )?(az |Get-Az|Connect-Az)'
        }
    }

    Context 'Test-NetworkConfiguration.ps1' {
        BeforeEach {
            Reset-Cluster
            Mock Get-ClusterNode { @([pscustomobject]@{ Name = 'iic-n01'; State = 'Up' }, [pscustomobject]@{ Name = 'iic-n02'; State = 'Up' }) }
            Mock Get-ClusterNetwork { [pscustomobject]@{ Name = 'Cluster Network 1'; State = 'Up'; Role = 'ClusterAndClient'; Address = '192.0.2.0'; Metric = 10 } }
            Mock Invoke-Command {
                $text = $ScriptBlock.ToString()
                $global:AzlValCalls.Add([pscustomobject]@{ Text = $text; Args = @($ArgumentList) })
                switch -Regex ($text) {
                    "Status -ne" { return @() }
                    'Get-NetAdapter\b(?!Rdma)' { return [pscustomobject]@{ Name = 'Port1'; InterfaceDescription = 'Adapter'; Status = 'Up'; LinkSpeed = '25 Gbps'; MediaType = '802.3' } }
                    'Get-VMSwitchTeam' { return @('Port1') }
                    'Get-VMSwitch' { return [pscustomobject]@{ Name = 'ConvergedSwitch'; SwitchType = 'External'; EmbeddedTeamingEnabled = $true } }
                    'Get-NetAdapterRdma' { return [pscustomobject]@{ Name = 'SMB1'; Enabled = $true } }
                    'Test-Connection' { return $true }
                    'Resolve-DnsName' { return @{ Success = $true; IP = '192.0.2.50' } }
                    'BeginConnect' { return $global:AzlValProbeFailHost -ne $ArgumentList[0] }
                    'Test-NetConnection' { return $true }
                }
            }
        }

        It 'exits 0 when every check passes' {
            $r = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Network validation complete'
        }

        It 'exits 1 when a node cannot be pinged by another node' {
            Mock Invoke-Command { if ($ScriptBlock.ToString() -match 'Test-Connection') { return $false } return $null }
            $r = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'FAILED'
        }

        It 'exits 1 when a cluster network is down' {
            Mock Get-ClusterNetwork { [pscustomobject]@{ Name = 'Cluster Network 1'; State = 'Down'; Role = 'ClusterAndClient'; Address = '192.0.2.0'; Metric = 10 } }
            (Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile) }).ExitCode | Should -Be 1
        }

        It 'with -TestExternalConnectivity probes the hosts of the shared endpoint list of the region of the file, plus the custom endpoints' {
            $r = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile); TestExternalConnectivity = $true; CustomEndpoints = @('proxy.improbability.cloud:8080') }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $probed = @($global:AzlValCalls | Where-Object { $_.Text -match 'BeginConnect' } | ForEach-Object { $_.Args[0] })
            $probed | Should -Contain 'management.azure.com'
            $probed.Count | Should -BeGreaterThan 3
            @($global:AzlValCalls | Where-Object { $_.Text -match 'Test-NetConnection' } | ForEach-Object { $_.Args[0] }) | Should -Contain 'proxy.improbability.cloud'
        }

        It 'resolves the cluster name and the endpoint hosts of the shared list, not names written in the script' {
            $null = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile) }
            $names = @($global:AzlValCalls | Where-Object { $_.Text -match 'Resolve-DnsName' } | ForEach-Object { $_.Args[0] })
            $names | Should -Contain 'iic-azl-01'
            $names.Count | Should -Be 3
            (Get-Content -LiteralPath $script:Network -Raw) | Should -Not -Match 'management\.azure\.com|login\.microsoftonline\.com|arc\.azure\.com'
        }

        It 'does not name a host variable $host, which is an automatic variable of PowerShell' {
            (Get-Content -LiteralPath $script:Network -Raw) | Should -Not -Match '(?i)\$host\b'
        }
    }
}
