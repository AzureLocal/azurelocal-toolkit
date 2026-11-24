#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# scripts/common/remoting/AzlClusterConnection.psm1: how a validation or day 2 script reaches the cluster from a management host that is not in the cluster's domain and does
# not use its DNS (found on the first manual run on a deployed instance, 2026-11-23: the scripts asked the cluster by name with the cluster tools of the host, and could not run).
# Also Get-AzlAzureCliLauncher (scripts/common/azure-cli/AzlAzureCliArgument.psm1): a value with a parenthesis must not go through az.cmd.
# No cluster, no node, no Azure and no vault is used: the remote command is a script block of the test, and the secret is an environment variable.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/ClusterConnection.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A made-up password for a credential object of the test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'remoting', 'AzlClusterConnection.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1')) -Force

    function New-Infra {
        param([switch]$NoNodes, [switch]$NoUser, [string]$Reference = 'env://AZL_TEST_CONNECTION_SECRET', [string]$Netbios = 'IIC')
        $doc = [ordered]@{ cluster = [ordered]@{ name = 'iic-azl-01' } }
        if (-not $NoNodes) {
            $doc.nodes = @(
                [ordered]@{ name = 'iic-n01'; management = [ordered]@{ ip_address = '192.0.2.11' } }
                [ordered]@{ name = 'iic-n02'; management = [ordered]@{ ip_address = '192.0.2.12' } }
                [ordered]@{ name = 'iic-n03' }
            )
        }
        $ad = [ordered]@{ domain_fqdn = 'improbability.cloud' }
        if ($Netbios) { $ad.netbios_name = $Netbios }
        if (-not $NoUser) { $ad.lcm_user = [ordered]@{ username = 'lcm-iic-azl-01'; password = $Reference } }
        $doc.identity = [ordered]@{ active_directory = $ad }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        Import-AzlInfrastructure -Path $file -SkipValidation
    }
    # A remote command that records each call and answers from a table: machine -> 'ok', 'down' (a connection error) or 'error' (the block fails on the node).
    function New-Remote([hashtable]$Machine, [System.Collections.Generic.List[object]]$Log) {
        {
            param([hashtable]$Call)
            $Log.Add([pscustomobject]@{ Computer = $Call.ComputerName; Ssl = [bool]$Call['UseSSL']; User = $(if ($Call['Credential']) { $Call.Credential.UserName } else { '' }); Arguments = @($Call['ArgumentList']) })
            $answer = [string]$Machine[[string]$Call.ComputerName]
            if ($Call['UseSSL'] -and $answer -eq 'https-only') { return "from $($Call.ComputerName)" }
            switch ($answer) {
                'ok' { return "from $($Call.ComputerName)" }
                'error' { throw 'The term Get-Thing is not recognized.' }
                default { throw [System.Management.Automation.Remoting.PSRemotingTransportException]::new("Connecting to remote server $($Call.ComputerName) failed.") }
            }
        }.GetNewClosure()
    }
}

Describe 'Resolve-AzlClusterConnection' {
    BeforeEach { $env:AZL_TEST_CONNECTION_SECRET = 'made-up-value' }
    AfterAll { Remove-Item Env:AZL_TEST_CONNECTION_SECRET -ErrorAction SilentlyContinue }

    It 'targets the first node of the file with a management address, and keeps the other addresses as candidates' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra)
        $c.ClusterName | Should -Be 'iic-azl-01'
        $c.Target | Should -Be '192.0.2.11'
        $c.TargetSource | Should -Be 'NodeAddress'
        $c.Candidates | Should -Be @('192.0.2.11', '192.0.2.12')
    }

    It 'falls back to the cluster name, and says so, when no node of the file has an address' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra -NoNodes)
        $c.Target | Should -Be 'iic-azl-01'
        $c.TargetSource | Should -Be 'ClusterName'
        ($c.Notes -join ' ') | Should -Match 'must resolve from this host'
    }

    It 'takes -ComputerName, and maps a node name (short or with the domain) to its address' -ForEach @(
        @{ Given = 'iic-n02'; Target = '192.0.2.12' }, @{ Given = 'iic-n02.improbability.cloud'; Target = '192.0.2.12' }, @{ Given = 'jump.improbability.cloud'; Target = 'jump.improbability.cloud' }
    ) {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -ComputerName $Given
        $c.Target | Should -Be $Target
        $c.TargetSource | Should -Be 'Parameter'
        $c.Candidates | Should -Be @($Target)
    }

    It 'builds the credential of the deployment user of the file from its secret reference: <Expected>' -ForEach @(
        @{ Netbios = 'IIC'; Expected = 'IIC\lcm-iic-azl-01' }, @{ Netbios = ''; Expected = 'lcm-iic-azl-01@improbability.cloud' }
    ) {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra -Netbios $Netbios)
        $c.CredentialSource | Should -Be 'DeploymentUser'
        $c.Credential.UserName | Should -Be $Expected
        $c.Credential.GetNetworkCredential().Password | Should -Be 'made-up-value'
    }

    It 'prefers -Credential' {
        $given = [pscredential]::new('IIC\operator', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -Credential $given
        $c.CredentialSource | Should -Be 'Parameter'
        $c.Credential.UserName | Should -Be 'IIC\operator'
    }

    It 'uses the account that runs the script, with a note, when the file has no deployment user or its secret cannot be read' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra -NoUser)
        $c.CredentialSource | Should -Be 'CurrentAccount'
        $c.Credential | Should -BeNullOrEmpty
        ($c.Notes -join ' ') | Should -Match 'no deployment user'

        Remove-Item Env:AZL_TEST_CONNECTION_SECRET
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra)
        $c.CredentialSource | Should -Be 'CurrentAccount'
        ($c.Notes -join ' ') | Should -Match 'could not be read'
    }

    It 'asks by name, not by address, when there is no credential: WinRM takes the account that runs the script only for a name' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra -NoUser)
        $c.Target | Should -Be 'iic-azl-01'
        $c.TargetSource | Should -Be 'ClusterName'
        $c.Candidates | Should -Be @('iic-azl-01')
        Get-AzlClusterNodeAddress -Connection $c -Node 'iic-n02' | Should -Be 'iic-n02'
        ($c.Notes -join ' ') | Should -Match 'asked by name'
        Format-AzlClusterConnection -Connection $c | Should -Be 'Connecting to iic-azl-01 (the cluster name) as the account that runs the script.'
    }

    It 'never puts the secret in the line for the log' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra)
        $line = Format-AzlClusterConnection -Connection $c
        $line | Should -Be 'Connecting to 192.0.2.11 (a node of the file) as IIC\lcm-iic-azl-01 (the deployment user of the file).'
        $line | Should -Not -Match 'made-up-value'
    }
}

Describe 'Invoke-AzlClusterCommand' {
    BeforeEach {
        $env:AZL_TEST_CONNECTION_SECRET = 'made-up-value'
        $script:Log = [System.Collections.Generic.List[object]]::new()
    }
    AfterAll { Remove-Item Env:AZL_TEST_CONNECTION_SECRET -ErrorAction SilentlyContinue }

    It 'runs the block on the target with the credential and the arguments of the call' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -RemoteCommand (New-Remote @{ '192.0.2.11' = 'ok' } $script:Log)
        Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'x' } -ArgumentList 'a', 'b' | Should -Be 'from 192.0.2.11'
        # the first call is the probe (a block that does nothing), the second the block of the caller
        $script:Log.Count | Should -Be 2
        $script:Log[1].User | Should -Be 'IIC\lcm-iic-azl-01'
        $script:Log[1].Arguments | Should -Be @('a', 'b')
        $script:Log[1].Ssl | Should -BeFalse
        Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'y' } | Should -Be 'from 192.0.2.11'
        $script:Log.Count | Should -Be 3 -Because 'a machine is probed once'
    }

    It 'goes to the next node of the file when the target cannot be reached, and stays there' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -RemoteCommand (New-Remote @{ '192.0.2.11' = 'down'; '192.0.2.12' = 'ok' } $script:Log)
        Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'x' } 3>$null | Should -Be 'from 192.0.2.12'
        $c.Target | Should -Be '192.0.2.12'
        $script:Log.Clear()
        Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'x' } | Should -Be 'from 192.0.2.12'
        @($script:Log | ForEach-Object { $_.Computer }) | Should -Be @('192.0.2.12')
    }

    It 'runs the block of the caller once: a connection error while it runs is thrown, not answered with HTTPS or another machine' {
        $state = @{ '192.0.2.11' = 'ok'; '192.0.2.12' = 'ok' }
        $calls = [System.Collections.Generic.List[string]]::new()
        $remote = {
            param([hashtable]$Call)
            $calls.Add("$($Call.ComputerName) $($Call.ScriptBlock.ToString().Trim()) ssl=$([bool]$Call['UseSSL'])")
            if ($Call.ScriptBlock.ToString() -match 'change') { throw [System.Management.Automation.Remoting.PSRemotingTransportException]::new('The connection was lost while the block ran.') }
            'ok'
        }.GetNewClosure()
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -RemoteCommand $remote
        { Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'change' } } | Should -Throw '*connection was lost*'
        @($calls | Where-Object { $_ -match 'change' }) | Should -Be @("192.0.2.11 'change' ssl=False")
    }

    It 'does not fail over once the target has answered: a block that lost its connection may have run in part' {
        $state = @{ '192.0.2.11' = 'ok'; '192.0.2.12' = 'ok' }
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -RemoteCommand (New-Remote $state $script:Log)
        $null = Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'read' }
        $state['192.0.2.11'] = 'down'
        $script:Log.Clear()
        { Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'change' } } | Should -Throw '*192.0.2.11 failed*'
        @($script:Log | ForEach-Object { $_.Computer } | Sort-Object -Unique) | Should -Be @('192.0.2.11')
        @($script:Log | ForEach-Object { $_.Ssl } | Sort-Object -Unique) | Should -Be @($false)
    }

    It 'does not try another machine when the block itself fails on the node' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -RemoteCommand (New-Remote @{ '192.0.2.11' = 'error'; '192.0.2.12' = 'ok' } $script:Log)
        { Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'x' } } | Should -Throw '*Get-Thing*'
        @($script:Log | ForEach-Object { $_.Computer } | Sort-Object -Unique) | Should -Be @('192.0.2.11')
    }

    It 'throws the first connection error when no machine answers' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -RemoteCommand (New-Remote @{ } $script:Log)
        { Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'x' } } | Should -Throw '*192.0.2.11 failed*'
    }

    It 'tries WinRM over HTTPS when HTTP does not connect, and remembers it for that machine' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -RemoteCommand (New-Remote @{ '192.0.2.11' = 'https-only' } $script:Log)
        Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'x' } | Should -Be 'from 192.0.2.11'
        @($script:Log | ForEach-Object { $_.Ssl }) | Should -Be @($false, $true, $true) -Because 'the probe tries HTTP, then HTTPS; the block runs once, over HTTPS'
        $script:Log.Clear()
        $null = Invoke-AzlClusterCommand -Connection $c -ScriptBlock { 'x' }
        @($script:Log | ForEach-Object { $_.Ssl }) | Should -Be @($true)
    }

    It 'asks a node at its management address of the file, and a machine the file does not know by the name given' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -RemoteCommand (New-Remote @{ '192.0.2.12' = 'ok'; 'iic-n03' = 'ok' } $script:Log)
        Invoke-AzlClusterCommand -Connection $c -Node 'IIC-N02' -ScriptBlock { 'x' } | Should -Be 'from 192.0.2.12'
        Invoke-AzlClusterCommand -Connection $c -Node 'iic-n02.improbability.cloud' -ScriptBlock { 'x' } | Should -Be 'from 192.0.2.12'
        Invoke-AzlClusterCommand -Connection $c -Node 'iic-n03' -ScriptBlock { 'x' } | Should -Be 'from iic-n03'
    }

    It 'does not fall over to another machine for a question to one node' {
        $c = Resolve-AzlClusterConnection -Infrastructure (New-Infra) -RemoteCommand (New-Remote @{ '192.0.2.11' = 'ok'; '192.0.2.12' = 'down' } $script:Log)
        { Invoke-AzlClusterCommand -Connection $c -Node 'iic-n02' -ScriptBlock { 'x' } } | Should -Throw
        @($script:Log | ForEach-Object { $_.Computer } | Sort-Object -Unique) | Should -Be @('192.0.2.12')
    }
}

Describe 'Get-AzlAzureCliLauncher' {
    It 'starts the Python of the Azure CLI, not az.cmd, when az is the batch file of the Windows installer' {
        $root = Join-Path $TestDrive 'CLI2'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'wbin') -Force
        Set-Content -LiteralPath (Join-Path $root 'python.exe') -Value ''
        Set-Content -LiteralPath (Join-Path $root 'wbin\az.cmd') -Value ''
        $launcher = Get-AzlAzureCliLauncher -Command ([pscustomobject]@{ CommandType = 'Application'; Source = (Join-Path $root 'wbin\az.cmd') })
        $launcher.Direct | Should -BeTrue
        $launcher.Command | Should -Be (Join-Path $root 'python.exe')
        $launcher.Prefix | Should -Be @('-IBm', 'azure.cli')
    }

    It 'refuses a parenthesis when az can only be started as a batch file, and never shows the value' {
        $batch = Get-AzlAzureCliLauncher -Command ([pscustomobject]@{ CommandType = 'Application'; Source = 'C:\nowhere\wbin\az.cmd' })
        $batch.BatchFile | Should -BeTrue
        $problem = Get-AzlAzureCliParenthesisProblem -Launcher $batch -Argument @('stack-hci-vm', 'network', 'lnet', 'create', '--vm-switch-name', 'ComputeSwitch(compute)')
        $problem | Should -Match 'Argument 6 of an az call holds a parenthesis'
        $problem | Should -Not -Match 'ComputeSwitch'
        Get-AzlAzureCliParenthesisProblem -Launcher $batch -Argument @('account', 'show') | Should -BeNullOrEmpty
        $direct = [pscustomobject]@{ Command = 'python.exe'; Prefix = @('-IBm', 'azure.cli'); Direct = $true; BatchFile = $false }
        Get-AzlAzureCliParenthesisProblem -Launcher $direct -Argument @('--vm-switch-name', 'ComputeSwitch(compute)') | Should -BeNullOrEmpty
    }

    It 'starts az as it is otherwise: <Name>' -ForEach @(
        @{ Name = 'a function named az (the tests)'; Command = [pscustomobject]@{ CommandType = 'Function'; Source = '' } }
        @{ Name = 'az on Linux'; Command = [pscustomobject]@{ CommandType = 'Application'; Source = '/usr/bin/az' } }

        @{ Name = 'no az at all'; Command = $null }
    ) {
        $launcher = Get-AzlAzureCliLauncher -Command $Command
        $launcher.Direct | Should -BeFalse
        $launcher.Command | Should -Be 'az'
        @($launcher.Prefix).Count | Should -Be 0
    }

    It 'is what the two logical network scripts start az with: a switch named by Network ATC has parentheses, and cmd.exe ends az.cmd at the closing one' -ForEach @(
        @{ File = 'powershell/New-LogicalNetwork.ps1' }, @{ File = 'azurecli/New-LogicalNetwork.azcli.ps1' }
    ) {
        $text = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-08-logical-network-creation', $File)) -Raw
        $text | Should -Match 'Get-AzlAzureCliLauncher'
        $text | Should -Match '& \$launcher\.Command @\(\$launcher\.Prefix \+ \$Arguments\)'
        $text | Should -Match 'Get-AzlAzureCliParenthesisProblem -Launcher \$launcher -Argument \$Arguments'
        $text | Should -Not -Match '& az @Arguments'
    }
}

Describe 'the scripts that ask the cluster' {
    It '<_> connects through the shared connection and runs the remote command in its own scope (so that its tests can replace Invoke-Command)' -ForEach @(
        'scripts/deploy/07-validation-handover/task-01-cluster-health-validation/powershell/Test-AzureLocalClusterHealth.ps1'
        'scripts/deploy/07-validation-handover/task-02-arc-connectivity-validation/powershell/Test-ArcConnectivity.ps1'
        'scripts/deploy/07-validation-handover/task-03-network-configuration-validation/powershell/Test-NetworkConfiguration.ps1'
        'scripts/deploy/07-validation-handover/task-04-storage-performance-validation/powershell/Test-StoragePerformance.ps1'
        'scripts/deploy/07-validation-handover/task-05-deployment-documentation/powershell/New-DeploymentDocumentation.ps1'
        'scripts/deploy/08-day2-operations/task-01-check-for-updates/powershell/Get-AvailableSolutionUpdate.ps1'
        'scripts/deploy/08-day2-operations/task-02-start-solution-update/powershell/Start-AzureLocalSolutionUpdate.ps1'
        'scripts/deploy/08-day2-operations/task-04-cluster-operations/powershell/Invoke-ClusterOperations.ps1'
        'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-05-storage-configuration/powershell/New-StorageVolume.ps1'
        'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-05-storage-configuration/powershell/New-SanVolume.ps1'
        'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-08-logical-network-creation/powershell/New-LogicalNetwork.ps1'
    ) {
        $text = Get-Content -LiteralPath (Join-Path $script:Repo $_) -Raw
        $text | Should -Match 'Resolve-AzlClusterConnection -Infrastructure \$infra -ComputerName \$ComputerName -Credential \$Credential -RemoteCommand \{ param\(\[hashtable\]\$Call\) Invoke-Command @Call \}'
        $text | Should -Match 'Invoke-AzlClusterCommand -Connection'
        $text | Should -Not -Match '-CimSession \$ClusterName|-Cluster \$ClusterName|-Cluster \$clusterName'
    }
}
