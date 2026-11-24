#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (testing and validation): Test-InfrastructureHealth.ps1, Test-NetworkRdmaValidation.ps1 and Test-HighAvailability.ps1 take -InfrastructureFile,
# read cluster.name from it, never prompt, and end with 0 (nothing failed), 1 (a check failed) or 2 (cluster.name is missing or the file cannot be read).
# Every cluster, remoting and storage cmdlet is a stub; nothing is contacted. The scripts run as copies in TestDrive, because they need the FailoverClusters
# module (#Requires) and find the infrastructure module by a path relative to their own folder.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/ClusterValidation.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cmdlets they replace.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $phase = [IO.Path]::Combine($repoRoot, 'scripts', 'deploy', '06-testing-validation')
    $script:Cases = @(
        @{ Name = 'Test-InfrastructureHealth.ps1'; Path = [IO.Path]::Combine($phase, 'task-01-infrastructure-health-validation', 'powershell', 'Test-InfrastructureHealth.ps1') }
        @{ Name = 'Invoke-VmFleetStorageTest.ps1'; Path = [IO.Path]::Combine($phase, 'task-02-vmfleet-storage-testing', 'powershell', 'Invoke-VmFleetStorageTest.ps1') }
        @{ Name = 'Test-NetworkRdmaValidation.ps1'; Path = [IO.Path]::Combine($phase, 'task-03-network-rdma-validation', 'powershell', 'Test-NetworkRdmaValidation.ps1') }
        @{ Name = 'Test-HighAvailability.ps1'; Path = [IO.Path]::Combine($phase, 'task-04-high-availability-testing', 'powershell', 'Test-HighAvailability.ps1') }
        @{ Name = 'Test-SecurityCompliance.ps1'; Path = [IO.Path]::Combine($phase, 'task-05-security-compliance-validation', 'powershell', 'Test-SecurityCompliance.ps1') }
    )
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $phase = [IO.Path]::Combine($repo, 'scripts', 'deploy', '06-testing-validation')
    $script:Health = [IO.Path]::Combine($phase, 'task-01-infrastructure-health-validation', 'powershell', 'Test-InfrastructureHealth.ps1')
    $script:Rdma = [IO.Path]::Combine($phase, 'task-03-network-rdma-validation', 'powershell', 'Test-NetworkRdmaValidation.ps1')
    $script:Ha = [IO.Path]::Combine($phase, 'task-04-high-availability-testing', 'powershell', 'Test-HighAvailability.ps1')
    Import-Module powershell-yaml

    function New-ScriptCopy([string]$Source) {
        $text = Get-Content -LiteralPath $Source -Raw
        $moduleLine = 'Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ''..'', ''..'', ''..'', ''..'', ''common'', ''infrastructure'', ''AzlInfrastructure.psm1''))) -Force'
        $text | Should -Match ([regex]::Escape($moduleLine))
        $real = "Import-Module '$([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))' -Force"
        # The remote-host scripts also load the remoting module by a path relative to their folder.
        $remotingLine = 'Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ''..'', ''..'', ''..'', ''..'', ''common'', ''remoting'', ''AzlClusterConnection.psm1''))) -Force'
        $text = $text.Replace($remotingLine, "Import-Module '$([IO.Path]::Combine($repo, 'scripts', 'common', 'remoting', 'AzlClusterConnection.psm1'))' -Force")
        $copy = Join-Path $TestDrive ([IO.Path]::GetFileName($Source))
        Set-Content -LiteralPath $copy -Value ((($text.Replace($moduleLine, $real)) -split "`r?`n" | Where-Object { $_ -notmatch '^#Requires -Module' }) -join "`n")
        $copy
    }
    function New-InfraFile {
        param([switch]$NoCluster, [switch]$WithNodes, [switch]$WithIntents)
        $doc = [ordered]@{ azure = [ordered]@{ location = 'westeurope' } }
        if (-not $NoCluster) { $doc.cluster = [ordered]@{ name = 'iic-azl-01' } }
        if ($WithIntents) { $doc.networking = [ordered]@{ intents = @([ordered]@{ name = 'compute'; traffic = @('compute'); adapters = @('Port3') }, [ordered]@{ name = 'storage'; traffic = @('storage'); adapters = @('SMB1') }) } }
        if ($WithNodes) {
            # the management addresses and the deployment user the remote-host scripts connect with
            $doc.nodes = @([ordered]@{ name = 'iic-01-n01'; management = [ordered]@{ ip_address = '192.0.2.11' } })
            $doc.identity = [ordered]@{ active_directory = [ordered]@{ domain_fqdn = 'improbability.cloud'; netbios_name = 'IIC'; lcm_user = [ordered]@{ username = 'lcm-iic-azl-01'; password = 'env://AZL_TEST_CV_SECRET' } } }
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Validation([string]$Copy, [string]$File, [hashtable]$Extra = @{}) {
        $out = Join-Path $TestDrive "out-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $global:LASTEXITCODE = $null
        $text = (& $Copy -InfrastructureFile $File -OutputPath $out @Extra 6>&1 | Out-String)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text; OutputPath = $out }
    }

    # Stubs of the cluster, storage and remoting cmdlets the three scripts call. The state they answer with is in globals.
    function Get-ClusterNode { param($Cluster, $Name) @([pscustomobject]@{ Name = 'iic-01-n01'; State = $global:AzlCvNodeState; DrainStatus = 'NotInitiated' }) }
    function Test-Cluster { param($Cluster, $Include) @([pscustomobject]@{ Name = 'Validate Network'; Status = $global:AzlCvTestClusterStatus; Description = 'd' }) }
    function Get-HealthFault { param($CimSession) $global:AzlCvFaults }
    function Get-StoragePool { param($CimSession, $IsPrimordial) @([pscustomobject]@{ FriendlyName = 'pool'; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; Size = 10TB; AllocatedSize = 1TB }) }
    function Get-VirtualDisk { param($CimSession) @([pscustomobject]@{ FriendlyName = 'vd'; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; ResiliencySettingName = 'Mirror' }) }
    function Get-PhysicalDisk { param($CimSession) @([pscustomobject]@{ FriendlyName = 'pd'; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; Usage = 'Auto-Select' }) }
    function Get-ClusterQuorum { param($Cluster) [pscustomobject]@{ QuorumType = 'Majority'; QuorumResource = [pscustomobject]@{ Name = 'Cloud Witness'; State = $global:AzlCvWitnessState } } }
    function Get-ClusterSharedVolume { param($Cluster) @([pscustomobject]@{ Name = 'Volume1'; State = 'Online'; SharedVolumeInfo = [pscustomobject]@{ FaultState = $global:AzlCvCsvFault }; OwnerNode = [pscustomobject]@{ Name = 'iic-01-n01' } }) }
    function Get-ClusterResource { param($Cluster) @() }
    function Invoke-Command {
        param($ComputerName, $ScriptBlock, $ErrorAction, $Credential, $ArgumentList, [switch]$UseSSL)
        $body = $ScriptBlock.ToString()
        if ($body -match 'Register-ScheduledTask') {
            # Test-Cluster runs as a scheduled task on the node: the stub answers with what the task would read back
            $global:AzlCvTaskUser = $ArgumentList[1].UserName
            $lines = if ($global:AzlCvTestClusterStatus -eq 2) { @('Network - Validate Network Communication: The test failed.', 'Test Result: ClusterNotApproved') } else { @('Test Result: ClusterApproved') }
            $global:AzlCvCalls.Add([pscustomobject]@{ Computer = [string]$ComputerName; User = $(if ($Credential) { $Credential.UserName } else { '' }) })
            return [pscustomobject]@{ Report = 'C:\Windows\Temp\validation.htm'; Warnings = $lines; Error = '' }
        }
        $global:AzlCvCalls.Add([pscustomobject]@{ Computer = [string]$ComputerName; User = $(if ($Credential) { $Credential.UserName } else { '' }) })
        if ($body -match 'Get-NetAdapterRdma') { return @([pscustomobject]@{ Name = 'SMB1'; Enabled = $global:AzlCvRdmaEnabled; OperationalState = 'Connected' }) + @(if ($global:AzlCvComputePort) { [pscustomobject]@{ Name = 'Port3'; Enabled = $false; OperationalState = $false } }) }
        if ($body -match 'Get-NetQosPolicy') { return @{ QosPolicy = @([pscustomobject]@{ Name = 'SMB'; PriorityValue8021Action = 3 }); PFC = @([pscustomobject]@{ Priority = 3; Enabled = $true }) } }
        if ($body -match 'Get-SmbClientConfiguration') { return @{ SmbClientEnabled = $true; SmbServerEnabled = $true; RdmaConnections = 2; SmbDirectConnections = 2 } }
        if ($body -match 'Get-NetIntent') { return @() }
        if ($body -match 'azcmagent') { return @('Agent Status                 : Connected') }
        if ($body -match 'Get-VMHost') { return [pscustomobject]@{ Enabled = $true; AuthenticationType = 'Kerberos'; MaxMigrations = 4; PerformanceOption = 'SMB' } }
        # A block of the remote-host scripts (the connection probe, a cluster question) runs here against the stubs above.
        if ($body -match 'Get-Cluster|Get-Cau|Get-HealthFault|Get-StoragePool|^\s*\$true\s*$') { return (& $ScriptBlock @($ArgumentList)) }
        $null
    }
}

AfterAll { Remove-Variable -Name AzlCvNodeState, AzlCvTestClusterStatus, AzlCvFaults, AzlCvWitnessState, AzlCvCsvFault, AzlCvRdmaEnabled, AzlCvCalls, AzlCvTaskUser, AzlCvComputePort -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_CV_SECRET -ErrorAction SilentlyContinue }

Describe 'the phase 06 validation scripts take the infrastructure file' {
    It '<Name> takes -InfrastructureFile (mandatory) and no -ConfigPath or -ClusterName' -ForEach $script:Cases {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Contain 'InfrastructureFile'
        $names | Should -Not -Contain 'ConfigPath'
        $names | Should -Not -Contain 'ClusterName'
        $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'InfrastructureFile' }
        $p.Attributes.NamedArguments.ArgumentName | Should -Contain 'Mandatory'
        $p.DefaultValue | Should -BeNullOrEmpty
    }

    It '<Name> has the standard header, never prompts and installs no YAML module' -ForEach $script:Cases {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        $code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
        $code | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|ConvertFrom-Yaml|Install-Module\s+-Name\s+powershell-yaml|ConfigPath'
    }

    It '<Name> reads cluster.name, a registered key' -ForEach $script:Cases {
        (Get-Content -LiteralPath $Path -Raw) | Should -Match "'cluster\.name'"
    }
}

Describe 'Test-InfrastructureHealth.ps1, Test-NetworkRdmaValidation.ps1 and Test-HighAvailability.ps1' {
    BeforeEach {
        $global:AzlCvNodeState = 'Up'
        $global:AzlCvTestClusterStatus = 0
        $global:AzlCvFaults = @()
        $global:AzlCvWitnessState = 'Online'
        $global:AzlCvCsvFault = 'NoFaults'
        $global:AzlCvRdmaEnabled = $true
        $global:AzlCvComputePort = $false
        $global:AzlCvCalls = [System.Collections.Generic.List[object]]::new()
        $env:AZL_TEST_CV_SECRET = 'not-a-real-password'
    }

    It '<Name> asks a node at its management address as the deployment user of the file, not the cluster by name' -ForEach @(
        @{ Name = 'health'; Source = 'Health' }
        @{ Name = 'rdma'; Source = 'Rdma' }
        @{ Name = 'ha'; Source = 'Ha' }
    ) {
        $r = Invoke-Validation (New-ScriptCopy (Get-Variable -Name $Source -Scope Script -ValueOnly)) (New-InfraFile -WithNodes) @{ }
        $r.ExitCode | Should -BeIn @(0, 1) -Because $r.Text
        $global:AzlCvCalls.Count | Should -BeGreaterThan 0
        @($global:AzlCvCalls | Where-Object { $_.Computer -ne '192.0.2.11' }) | Should -BeNullOrEmpty
        @($global:AzlCvCalls | Where-Object { $_.User -ne 'IIC\lcm-iic-azl-01' }) | Should -BeNullOrEmpty
    }

    It '<Name> ends with exit code 2 and tests nothing when cluster.name is missing' -ForEach @(
        @{ Name = 'health'; Source = 'Health' }
        @{ Name = 'rdma'; Source = 'Rdma' }
        @{ Name = 'ha'; Source = 'Ha' }
    ) {
        $r = Invoke-Validation (New-ScriptCopy (Get-Variable -Name $Source -Scope Script -ValueOnly)) (New-InfraFile -NoCluster)
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $r.Text | Should -Match 'cluster.name is missing'
        Test-Path -LiteralPath $r.OutputPath | Should -BeFalse
    }

    It '<Name> ends with exit code 2 when the file cannot be read' -ForEach @(
        @{ Name = 'health'; Source = 'Health' }
        @{ Name = 'rdma'; Source = 'Rdma' }
        @{ Name = 'ha'; Source = 'Ha' }
    ) {
        $r = Invoke-Validation (New-ScriptCopy (Get-Variable -Name $Source -Scope Script -ValueOnly)) (Join-Path $TestDrive 'missing.yml')
        $r.ExitCode | Should -Be 2
        $r.Text | Should -Match 'Cannot read the infrastructure file'
    }

    Context 'Test-InfrastructureHealth.ps1' {
        It 'tests the cluster of cluster.name, writes the report and ends with 0 when everything is healthy' {
            $r = Invoke-Validation (New-ScriptCopy $script:Health) (New-InfraFile -WithNodes)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Cluster: iic-azl-01'
            $report = Get-ChildItem -LiteralPath $r.OutputPath -Filter '01-infrastructure-health-*.json'
            $report | Should -Not -BeNullOrEmpty
            (Get-Content -LiteralPath $report.FullName -Raw | ConvertFrom-Json).ClusterName | Should -Be 'iic-azl-01'
        }
        It 'runs Test-Cluster as the deployment user of the file in a scheduled task on the node (no second hop)' {
            $r = Invoke-Validation (New-ScriptCopy $script:Health) (New-InfraFile -WithNodes)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlCvTaskUser | Should -Be 'IIC\lcm-iic-azl-01'
            $r.Text | Should -Match 'Test-Cluster result: ClusterApproved'
        }
        It 'counts Test-Cluster as failed without an account to run it as' {
            $r = Invoke-Validation (New-ScriptCopy $script:Health) (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Test-Cluster needs the account'
        }
        It 'ends with 1 when a node is down' {
            $global:AzlCvNodeState = 'Down'
            (Invoke-Validation (New-ScriptCopy $script:Health) (New-InfraFile -WithNodes)).ExitCode | Should -Be 1
        }
        It 'ends with 1 when Test-Cluster fails a test' {
            $global:AzlCvTestClusterStatus = 2
            (Invoke-Validation (New-ScriptCopy $script:Health) (New-InfraFile -WithNodes)).ExitCode | Should -Be 1
        }
        It 'ends with 1 when the Health Service reports a fault' {
            $global:AzlCvFaults = @([pscustomobject]@{ FaultType = 'Disk'; Description = 'd'; Severity = 'Minor' })
            (Invoke-Validation (New-ScriptCopy $script:Health) (New-InfraFile -WithNodes)).ExitCode | Should -Be 1
        }
    }

    Context 'Test-NetworkRdmaValidation.ps1' {
        It 'ends with 0 when the RDMA adapters are enabled and writes the report' {
            $r = Invoke-Validation (New-ScriptCopy $script:Rdma) (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @(Get-ChildItem -LiteralPath $r.OutputPath -Filter '03-network-rdma-*.json').Count | Should -Be 1
        }
        It 'does not fail an adapter with RDMA off that is not in a storage intent of the file (Network ATC turns RDMA on for storage only)' {
            $global:AzlCvComputePort = $true
            $r = Invoke-Validation (New-ScriptCopy $script:Rdma) (New-InfraFile -WithIntents)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Port3.*not a storage intent adapter'
        }
        It 'fails a storage intent adapter with RDMA off' {
            $global:AzlCvRdmaEnabled = $false; $global:AzlCvComputePort = $true
            (Invoke-Validation (New-ScriptCopy $script:Rdma) (New-InfraFile -WithIntents)).ExitCode | Should -Be 1
        }
        It 'ends with 1 when an RDMA adapter is not enabled' {
            $global:AzlCvRdmaEnabled = $false
            (Invoke-Validation (New-ScriptCopy $script:Rdma) (New-InfraFile)).ExitCode | Should -Be 1
        }
    }

    Context 'Test-HighAvailability.ps1' {
        It 'ends with 0 when the quorum witness is online and the CSVs are healthy, and moves nothing' {
            $r = Invoke-Validation (New-ScriptCopy $script:Ha) (New-InfraFile) @{ SkipMigrationTest = $true }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @(Get-ChildItem -LiteralPath $r.OutputPath -Filter '04-high-availability-*.json').Count | Should -Be 1
        }
        It 'ends with 1 when a CSV has a fault' {
            $global:AzlCvCsvFault = 'IOError'
            (Invoke-Validation (New-ScriptCopy $script:Ha) (New-InfraFile) @{ SkipMigrationTest = $true }).ExitCode | Should -Be 1
        }
        It 'does not move a VM or drain a node' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Ha, [ref]$tokens, [ref]$null)
            $code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
            $code | Should -Not -Match 'Move-VM|Move-ClusterVirtualMachineRole|Suspend-ClusterNode|Resume-ClusterNode|Restart-Computer'
        }
    }
}
