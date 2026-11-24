#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Stage 07 (validation and handover), tasks 01 to 03: Test-AzureLocalClusterHealth.ps1, Test-ArcConnectivity.ps1 and Test-NetworkConfiguration.ps1 read cluster.name (and azure.location
# for the endpoint list) from infrastructure.yml, never ask, and end with exit code 0 (no check failed), 1 (a check failed) or 2 (a value is missing). Every question is asked on a
# node over PowerShell remoting (scripts/common/remoting/AzlClusterConnection.psm1), so Invoke-Command is mocked: no cluster, no node and no Azure is used. (Task 04, the storage
# test, has its own tests in tests/storage.)
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

    function New-InfraFile {
        # -WithNodes: two nodes with a management address, and a deployment user whose secret is an environment variable (the env provider of the secret resolver).
        param([switch]$NoCluster, [switch]$NoLocation, [switch]$WithNodes)
        $doc = [ordered]@{ azure = [ordered]@{ } }
        if (-not $NoLocation) { $doc.azure.location = 'eastus' }
        if (-not $NoCluster) { $doc.cluster = [ordered]@{ name = 'iic-azl-01' } }
        if ($WithNodes) {
            $doc.nodes = @(
                [ordered]@{ name = 'iic-n01'; management = [ordered]@{ ip_address = '192.0.2.11' } }
                [ordered]@{ name = 'iic-n02'; management = [ordered]@{ ip_address = '192.0.2.12' } }
            )
            $doc.identity = [ordered]@{ active_directory = [ordered]@{ domain_fqdn = 'improbability.cloud'; netbios_name = 'IIC'; lcm_user = [ordered]@{ username = 'lcm-iic-azl-01'; password = 'env://AZL_TEST_LCM_SECRET' } } }
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }    function Reset-Cluster {
        $global:AzlValCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlValNodeState = 'Up'
        $global:AzlValClusterName = 'iic-azl-01'
        $global:AzlValPoolHealth = 'Healthy'
        $global:AzlValNetworkState = 'Up'
        $global:AzlValPingOk = $true
        $global:AzlValArc = @{ Installed = $true; Status = 'Connected'; Error = ''; LastHeartbeat = '2026-01-01T00:00:00Z'; ExtensionService = 'Running'; Extensions = @(@{ Name = 'AzureEdgeDeviceManagement'; State = 'success' }) }
        $global:AzlValProbeFailHost = ''
        $global:AzlValReadFails = $false
    }    function Invoke-Script([string]$Script, [hashtable]$Arguments) {
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
    AfterAll { Remove-Variable -Name AzlValCalls, AzlValNodeState, AzlValClusterName, AzlValPoolHealth, AzlValNetworkState, AzlValPingOk, AzlValArc, AzlValProbeFailHost, AzlValReadFails -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_LCM_SECRET -ErrorAction SilentlyContinue }

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

        It 'asks the cluster on a node over remoting: no cluster cmdlet against the cluster name from this host, and no azcmagent extension command' {
            $code = ($script:Text -replace '(?s)<#.*?#>', '') -replace '(?m)^\s*#.*$', ''
            $code | Should -Match 'AzlClusterConnection\.psm1'
            $code | Should -Match 'Resolve-AzlClusterConnection'
            $code | Should -Not -Match '-Cluster \$ClusterName|-CimSession \$ClusterName|Get-Cluster -Name'
            # azcmagent extension list stops the extension service of the node while it runs (seen on agent 1.67): a validation must not call it.
            $code | Should -Not -Match 'extension\s+(list|remove)'
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
            Mock Invoke-Command {
                $text = $ScriptBlock.ToString()
                $global:AzlValCalls.Add([pscustomobject]@{ Text = $text; Computer = $ComputerName; User = $(if ($Credential) { $Credential.UserName } else { '' }) })
                if ($global:AzlValReadFails) { throw 'The cluster was not found.' }
                switch -Regex ($text) {
                    'Get-ClusterStorageSpacesDirect' { return @{ S2dState = 'Enabled'; Pools = @(@{ Name = 'SU1_Pool'; Health = $global:AzlValPoolHealth }); BadDisks = @() } }
                    'Get-ClusterNetwork' { return @(@{ Name = 'Cluster Network 1'; State = 'Up'; Role = 'ClusterAndClient' }) }
                    'Get-ClusterQuorum' { return @{ Type = 'Majority'; Resource = 'Cloud Witness' } }
                    'azcmagent' { return @{ Installed = $true; Status = 'Connected'; LastHeartbeat = '2026-01-01' } }
                    'Get-ClusterNode' { return @(@{ Name = 'iic-n01'; State = $global:AzlValNodeState }, @{ Name = 'iic-n02'; State = 'Up' }) }
                    'Get-Cluster\b' { return @{ Name = $global:AzlValClusterName; Domain = 'improbability.cloud' } }
                }
            }
        }

        It 'exits 0 when every check passes, and asks the cluster named in the file when the file has no node address' {
            $r = Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Overall Status: PASSED'
            @($global:AzlValCalls | Where-Object { $_.Text -match 'Get-Cluster\b' })[0].Computer | Should -Be 'iic-azl-01'
        }

        It 'connects to the management address of a node of the file, as the deployment user of the file, and asks every node for its Arc agent at its own address' {
            $env:AZL_TEST_LCM_SECRET = 'not-a-real-secret'
            $r = Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile -WithNodes) }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Connecting to 192\.0\.2\.11 \(a node of the file\) as IIC\\lcm-iic-azl-01 \(the deployment user of the file\)'
            $r.Text | Should -Not -Match 'not-a-real-secret'
            @($global:AzlValCalls | Where-Object { $_.Text -match 'Get-ClusterNode' })[0].Computer | Should -Be '192.0.2.11'
            @($global:AzlValCalls | ForEach-Object { $_.User } | Sort-Object -Unique) | Should -Be @('IIC\lcm-iic-azl-01')
            @($global:AzlValCalls | Where-Object { $_.Text -match 'azcmagent' } | ForEach-Object { $_.Computer }) | Should -Be @('192.0.2.11', '192.0.2.12')
        }

        It 'uses -Credential and -ComputerName instead of the values of the file' {
            $given = [pscredential]::new('IIC\operator', (ConvertTo-SecureString 'x' -AsPlainText -Force))
            $r = Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile -WithNodes); Credential = $given; ComputerName = 'iic-n02' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($global:AzlValCalls | Where-Object { $_.Text -match 'Get-ClusterNode' })[0].Computer | Should -Be '192.0.2.12'
            @($global:AzlValCalls | ForEach-Object { $_.User } | Sort-Object -Unique) | Should -Be @('IIC\operator')
        }

        It 'exits 1 when the machine asked is a node of another cluster' {
            $global:AzlValClusterName = 'some-other-cluster'
            $r = Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match "is a node of cluster 'some-other-cluster'"
        }

        It 'exits 1 when a node is not Up' {
            $global:AzlValNodeState = 'Down'
            $r = Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'Overall Status: FAILED'
        }

        It 'exits 1 when the cluster cannot be reached' {
            $global:AzlValReadFails = $true
            (Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile) }).ExitCode | Should -Be 1
        }

        It 'exits 1 for an unhealthy storage pool' {
            $global:AzlValPoolHealth = 'Unhealthy'
            (Invoke-Script $script:Health @{ InfrastructureFile = (New-InfraFile) }).ExitCode | Should -Be 1
        }

        It 'writes the report as JSON with -OutputFormat JSON, and creates the folder' {
            $out = Join-Path $TestDrive 'health-reports'
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
            @($r.Rows | Where-Object Status -EQ 'Passed').Count | Should -Be 8
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
            @{ Arc = @{ Installed = $true; Status = 'Expired'; Error = ''; LastHeartbeat = ''; Extensions = @(@{ Name = 'x'; State = 'success' }) }; Code = 0; Status = 'Warning' }
        ) {
            $global:AzlValArc = $Arc
            $r = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be $Code -Because $r.Text
            (@($r.Rows | Where-Object Check -EQ 'Agent'))[0].Status | Should -Be $Status
        }

        It 'reads the extensions from the status files on the node and never runs azcmagent extension list, which stops the extension service' {
            $null = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile) }
            $agentBlock = @($global:AzlValCalls | Where-Object { $_ -match 'azcmagent' })[0]
            $agentBlock | Should -Match 'Packages\\Plugins'
            $agentBlock | Should -Match '\*\.status'
            ($agentBlock -replace '(?m)^\s*#.*$', '') | Should -Not -Match 'extension\s+list'
        }

        It 'fails and exits 1 when the extension service of the agent does not run, whatever the status files say' {
            $global:AzlValArc.ExtensionService = 'Stopped'
            $r = Invoke-Script $script:Arc @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            (@($r.Rows | Where-Object Check -EQ 'Extension service'))[0].Status | Should -Be 'Failed'
            (@($r.Rows | Where-Object Check -EQ 'Extensions'))[0].Status | Should -Be 'Passed'
        }

        It 'warns for an extension whose last status is not success' {
            $global:AzlValArc.Extensions = @(@{ Name = 'AzureEdgeDeviceManagement'; State = 'error' })
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
            Mock Invoke-Command {
                $text = $ScriptBlock.ToString()
                $global:AzlValCalls.Add([pscustomobject]@{ Text = $text; Args = @($ArgumentList); Computer = $ComputerName })
                switch -Regex ($text) {
                    'Get-ClusterNetwork' {
                        return @{
                            Nodes    = @(@{ Name = 'iic-n01'; State = 'Up' }, @{ Name = 'iic-n02'; State = 'Up' })
                            Networks = @(@{ Name = 'Cluster Network 1'; State = $global:AzlValNetworkState; Role = 'ClusterAndClient'; Address = '192.0.2.0'; Metric = 10 })
                        }
                    }
                    'Get-NetAdapter -Physical' {
                        return @{
                            Adapters = @(@{ Name = 'Port1'; InterfaceDescription = 'Adapter'; Status = 'Up'; LinkSpeed = '25 Gbps'; MediaType = '802.3' })
                            Switches = @(@{ Name = 'ConvergedSwitch'; SwitchType = 'External'; EmbeddedTeaming = $true; TeamMembers = @('Adapter') })
                            Rdma     = @(@{ Name = 'SMB1'; Enabled = $true })
                        }
                    }
                    'Get-NetIntentStatus' { return @{ Available = $true; Rows = @(@{ Intent = 'management_compute'; Node = 'iic-n01'; Configuration = 'Success'; Provisioning = 'Completed'; Error = '' }) } }
                    'Test-Connection' { foreach ($target in $ArgumentList[0]) { @{ Target = $target; Ok = $global:AzlValPingOk } }; return }
                    'Resolve-DnsName' { foreach ($name in $ArgumentList[0]) { @{ Name = $name; Success = $true; IP = '192.0.2.50'; Error = '' } }; return }
                    'BeginConnect' { foreach ($probe in $ArgumentList[0]) { @{ Host = $probe.Host; Port = $probe.Port; Ok = ($probe.Host -ne $global:AzlValProbeFailHost) } }; return }
                }
            }
        }

        It 'exits 0 when every check passes' {
            $r = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Network validation complete'
            $r.Text | Should -Match 'Intent: management_compute on iic-n01 - Success, Completed'
        }

        It 'asks every node at its own management address of the file' {
            $env:AZL_TEST_LCM_SECRET = 'not-a-real-secret'
            $r = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile -WithNodes) }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($global:AzlValCalls | Where-Object { $_.Text -match 'Get-NetAdapter -Physical' } | ForEach-Object { $_.Computer }) | Should -Be @('192.0.2.11', '192.0.2.12')
            @($global:AzlValCalls | Where-Object { $_.Text -match 'Test-Connection' } | ForEach-Object { $_.Computer }) | Should -Be @('192.0.2.11', '192.0.2.12')
        }

        It 'exits 1 when a node cannot be pinged by another node' {
            $global:AzlValPingOk = $false
            $r = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile) }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'iic-n01 -> iic-n02 : FAILED'
        }

        It 'exits 1 when a cluster network is down' {
            $global:AzlValNetworkState = 'Down'
            (Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile) }).ExitCode | Should -Be 1
        }

        It 'with -TestExternalConnectivity probes the hosts of the shared endpoint list of the region of the file, plus the custom endpoints, and fails for one that does not answer' {
            $r = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile); TestExternalConnectivity = $true; CustomEndpoints = @('proxy.improbability.cloud:8080') }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $probed = @(@($global:AzlValCalls | Where-Object { $_.Text -match 'BeginConnect' })[0].Args[0])
            @($probed | ForEach-Object { $_.Host }) | Should -Contain 'management.azure.com'
            $probed.Count | Should -BeGreaterThan 4
            @($probed | Where-Object { $_.Host -eq 'proxy.improbability.cloud' })[0].Port | Should -Be 8080

            $global:AzlValProbeFailHost = 'management.azure.com'
            $r = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile); TestExternalConnectivity = $true }
            $r.ExitCode | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'management\.azure\.com:443 - FAILED'
        }

        It 'resolves the cluster name and the endpoint hosts of the shared list, not names written in the script' {
            $null = Invoke-Script $script:Network @{ InfrastructureFile = (New-InfraFile) }
            $names = @(@($global:AzlValCalls | Where-Object { $_.Text -match 'Resolve-DnsName' })[0].Args[0])
            $names | Should -Contain 'iic-azl-01'
            $names.Count | Should -Be 3
            (Get-Content -LiteralPath $script:Network -Raw) | Should -Not -Match 'management\.azure\.com|login\.microsoftonline\.com|arc\.azure\.com'
        }

        It 'does not name a host variable $host, which is an automatic variable of PowerShell' {
            (Get-Content -LiteralPath $script:Network -Raw) | Should -Not -Match '(?i)\$host\b'
        }
    }
}