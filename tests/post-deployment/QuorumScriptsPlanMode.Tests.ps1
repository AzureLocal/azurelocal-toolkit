#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 02 (cluster quorum): the two scripts of the task each run ALONE, with only their own parameters, and plan against the
# toolkit example file:
#   Invoke-ConfigureClusterQuorum-Orchestrated.ps1   checks or creates the cloud witness account, sets the witness on a node, checks the witness after
#   New-CloudWitnessStorageAccount.azcli.ps1         the Azure CLI twin of the Azure side
# Each script reads its own preconditions from the file and from Azure or the cluster, and none needs the other to have run. Invoke-Command, every Az cmdlet
# and az are replaced by fakes, so no cluster and no Azure is used, and a test fails when a plan sends anything that changes a resource or the cluster.
# The file is config/variables/examples/infrastructure.example.yml, as it is, and with the values the task needs added in memory.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/QuorumScriptsPlanMode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and cluster and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeDiscovery {
    $task = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-02-cluster-quorum-configuration'))
    $script:Cases = @(
        @{ Name = 'Invoke-ConfigureClusterQuorum-Orchestrated.ps1'; Path = [IO.Path]::Combine($task, 'powershell', 'Invoke-ConfigureClusterQuorum-Orchestrated.ps1'); Own = @('AccessKeyName', 'ComputerName', 'Credential', 'UpdateAccessKey') }
        @{ Name = 'New-CloudWitnessStorageAccount.azcli.ps1'; Path = [IO.Path]::Combine($task, 'azurecli', 'New-CloudWitnessStorageAccount.azcli.ps1'); Own = @() }
    )
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $task = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-02-cluster-quorum-configuration')
    $script:Quorum = [IO.Path]::Combine($task, 'powershell', 'Invoke-ConfigureClusterQuorum-Orchestrated.ps1')
    $script:Twin = [IO.Path]::Combine($task, 'azurecli', 'New-CloudWitnessStorageAccount.azcli.ps1')
    Import-Module powershell-yaml

    function az { }
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzStorageAccount { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzStorageAccount { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$SkuName, [string]$Kind, [hashtable]$Tag) }
    function Get-AzStorageAccountKey { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzStorageAccountNameAvailability { [CmdletBinding()] param([string]$Name) }

    $global:AzlPlanTenant = [guid]::NewGuid().ToString()
    $global:AzlPlanSub = [guid]::NewGuid().ToString()
    $global:AzlPlanSecret = 'AZL_TEST_PLAN_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($global:AzlPlanSecret, [guid]::NewGuid().ToString())

    # The toolkit example, as read; with -Values the Azure ids and a login that does not need Key Vault (the secret references are replaced by an
    # environment variable made for the test). -Edit changes the document in memory before it is written.
    function New-PlanFile {
        param([switch]$Values, [scriptblock]$Edit)
        $text = Get-Content -LiteralPath $script:Example -Raw
        if (-not $Values -and -not $Edit) {
            $file = Join-Path $TestDrive "example-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            Set-Content -LiteralPath $file -Value $text
            return $file
        }
        $doc = ConvertFrom-Yaml -Ordered $text
        if ($Values) {
            $doc.azure.tenant_id = $global:AzlPlanTenant
            $doc.azure.subscription_id = $global:AzlPlanSub
            $doc.identity.local_admin.password = "env://$($global:AzlPlanSecret)"
            $doc.identity.active_directory.lcm_user.password = "env://$($global:AzlPlanSecret)"
        }
        if ($Edit) { & $Edit $doc }
        $file = Join-Path $TestDrive "plan-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-World {
        $global:AzlPlanCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlPlanRemote = [System.Collections.Generic.List[object]]::new()
        $global:AzlPlanState = @{
            Account = $null
            Quorum  = @{ Computer = 'iic-azl-n01'; Nodes = 2; QuorumType = 'NodeMajority'; ResourceName = ''; ResourceType = ''; ResourceState = ''; AccountName = ''; SharePath = ''; EndpointInfo = '' }
        }
    }
    function Invoke-Alone([string]$Script, [string]$File, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = & $Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = @($all)
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    # What would change something: an az write, a storage account creation, a key read, or a command that sets the quorum on the node.
    function Get-Change {
        @($global:AzlPlanCalls | Where-Object { $_.Command -match '\b(create|update|delete|set)\b' }) +
        @($global:AzlPlanRemote | Where-Object { $_.Step -like 'Set*' }) +
        @($global:AzlPlanCalls | Where-Object { $_.Command -in 'New-AzStorageAccount', 'Get-AzStorageAccountKey' })
    }
}

Describe 'The quorum scripts of phase 06 run alone in Plan mode' {
    AfterAll {
        Remove-Variable -Name AzlPlanTenant, AzlPlanSub, AzlPlanSecret, AzlPlanCalls, AzlPlanRemote, AzlPlanState -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Reset-World
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlPlanTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlPlanSub } } }
        Mock Set-AzContext { }
        Mock Get-AzStorageAccount {
            $global:AzlPlanCalls.Add([pscustomobject]@{ Command = 'Get-AzStorageAccount' })
            if ($global:AzlPlanState.Account) { $global:AzlPlanState.Account } else { throw "The Resource 'Microsoft.Storage/storageAccounts/$Name' under resource group was not found." }
        }
        Mock Get-AzStorageAccountNameAvailability { [pscustomobject]@{ NameAvailable = $true } }
        Mock New-AzStorageAccount { $global:AzlPlanCalls.Add([pscustomobject]@{ Command = 'New-AzStorageAccount' }) }
        Mock Get-AzStorageAccountKey { $global:AzlPlanCalls.Add([pscustomobject]@{ Command = 'Get-AzStorageAccountKey' }); @() }
        Mock Invoke-Command {
            $step = if ($ArgumentList -and $ArgumentList.Count -gt 0) { [string]$ArgumentList[0] } else { '' }
            $global:AzlPlanRemote.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName })
            switch ($step) {
                'Probe' { return 'iic-azl-n01' }
                'ReadQuorum' { return $global:AzlPlanState.Quorum.Clone() }
                default { return $null }
            }
        }
        Mock az {
            $a = @($args | ForEach-Object { [string]$_ })
            $words = @(); foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
            $command = $words -join ' '
            $global:AzlPlanCalls.Add([pscustomobject]@{ Command = $command; Arguments = $a })
            $fail = { param($code, $message) $global:LASTEXITCODE = $code; [Management.Automation.ErrorRecord]::new([Exception]::new($message), 'az', 'NotSpecified', $null) }
            $global:LASTEXITCODE = 0
            switch ($command) {
                'account show' { return ('{"tenantId":"' + $global:AzlPlanTenant + '","id":"' + $global:AzlPlanSub + '"}') }
                'storage account show' {
                    if ($global:AzlPlanState.Account) { return ('{"kind":"' + $global:AzlPlanState.Account.Kind + '","sku":{"name":"' + $global:AzlPlanState.Account.Sku.Name + '"}}') }
                    return (& $fail 3 "(ResourceNotFound) The Resource 'Microsoft.Storage/storageAccounts/x' was not found.")
                }
                'storage account check-name' { return 'true' }
                default { return (& $fail 2 "unexpected az call: $command") }
            }
        }
    }

    Context '<Name>' -ForEach $script:Cases {
        BeforeAll { $script:This = $Path }

        It 'takes -InfrastructureFile as its only mandatory parameter, and -WhatIf and -LogPath' {
            $command = Get-Command -Name $script:This
            @($command.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory } } | ForEach-Object Name) | Should -Be @('InfrastructureFile')
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $command.Parameters.ContainsKey('LogPath') | Should -BeTrue
            @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters -and $_ -notin 'InfrastructureFile', 'LogPath' } | Sort-Object) | Should -Be @($Own | Sort-Object)
        }

        It 'plans against the toolkit example as it is: exit 2 on the placeholder subscription, and nothing is created, read as a key, or set' {
            $r = Invoke-Alone $script:This (New-PlanFile) @{}
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'azure\.(tenant_id|subscription_id)'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'plans against the example with the Azure ids added, alone: exit 0, the missing account is only planned, the log is written' {
            $log = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{ LogPath = $log }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Item -Like 'cloud witness storage account*').Action | Should -Be 'WouldCreate'
            Get-Change | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $log -Raw).Trim() | Should -Not -BeNullOrEmpty
        }

        It 'plans an account that exists as AlreadyExists, and a wrong kind as a failure that changes nothing' {
            $global:AzlPlanState.Account = [pscustomobject]@{ StorageAccountName = 'stiicazl01wit'; Kind = 'StorageV2'; Sku = [pscustomobject]@{ Name = 'Standard_LRS' }; PrimaryEndpoints = [pscustomobject]@{ Blob = 'https://stiicazl01wit.blob.core.windows.net/' } }
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            @($r.Rows | Where-Object Item -Like 'cloud witness storage account*').Action | Should -Be 'AlreadyExists'
            Get-Change | Should -BeNullOrEmpty

            Reset-World
            $global:AzlPlanState.Account = [pscustomobject]@{ StorageAccountName = 'stiicazl01wit'; Kind = 'BlobStorage'; Sku = [pscustomobject]@{ Name = 'Standard_GRS' }; PrimaryEndpoints = [pscustomobject]@{ Blob = 'https://stiicazl01wit.blob.core.windows.net/' } }
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Item -Like 'cloud witness storage account*').Action | Should -Be 'Failed'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'stops with exit code 2 when the witness account name in the file is not a storage account name' {
            $file = New-PlanFile -Values -Edit { param($doc) $doc.cluster.witness.storage_account = 'Not_A_Valid_Name' }
            $r = Invoke-Alone $script:This $file @{}
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'storage_account'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'has nothing to do for a witness that is not in Azure (file_share), and plans no Azure call that changes anything' {
            $file = New-PlanFile -Values -Edit { param($doc) $doc.cluster.witness = [ordered]@{ type = 'file_share'; path = '\\fs01.improbability.cloud\witness' } }
            $r = Invoke-Alone $script:This $file @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($global:AzlPlanCalls | Where-Object Command -EQ 'New-AzStorageAccount') | Should -BeNullOrEmpty
            Get-Change | Should -BeNullOrEmpty
        }
    }

    Context 'Invoke-ConfigureClusterQuorum-Orchestrated.ps1 reads the cluster in Plan mode and checks the witness after' {
        It 'plans the cloud witness when the cluster has none: WouldConfigure, no Set-ClusterQuorum sent, no key read' {
            $global:AzlPlanState.Account = [pscustomobject]@{ StorageAccountName = 'stiicazl01wit'; Kind = 'StorageV2'; Sku = [pscustomobject]@{ Name = 'Standard_LRS' }; PrimaryEndpoints = [pscustomobject]@{ Blob = 'https://stiicazl01wit.blob.core.windows.net/' } }
            $r = Invoke-Alone $script:Quorum (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Item -EQ 'cluster quorum witness').Action | Should -Be 'WouldConfigure'
            @($global:AzlPlanRemote | Where-Object Step -EQ 'ReadQuorum').Count | Should -BeGreaterThan 0
            Get-Change | Should -BeNullOrEmpty
        }

        It 'is idempotent: a cloud witness on the account that is Online is AlreadyConfigured and verified, and nothing is sent' {
            $global:AzlPlanState.Account = [pscustomobject]@{ StorageAccountName = 'stiicazl01wit'; Kind = 'StorageV2'; Sku = [pscustomobject]@{ Name = 'Standard_LRS' }; PrimaryEndpoints = [pscustomobject]@{ Blob = 'https://stiicazl01wit.blob.core.windows.net/' } }
            $global:AzlPlanState.Quorum.ResourceType = 'Cloud Witness'; $global:AzlPlanState.Quorum.ResourceName = 'Cloud Witness'; $global:AzlPlanState.Quorum.ResourceState = 'Online'; $global:AzlPlanState.Quorum.AccountName = 'stiicazl01wit'
            $r = Invoke-Alone $script:Quorum (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Item -EQ 'cluster quorum witness').Action | Should -Be 'AlreadyConfigured'
            @($r.Rows | Where-Object Item -EQ 'cluster quorum witness resource').Action | Should -Be 'Verified'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'fails (exit 1) when the witness the file asks for is there but its resource is not Online' {
            $global:AzlPlanState.Account = [pscustomobject]@{ StorageAccountName = 'stiicazl01wit'; Kind = 'StorageV2'; Sku = [pscustomobject]@{ Name = 'Standard_LRS' }; PrimaryEndpoints = [pscustomobject]@{ Blob = 'https://stiicazl01wit.blob.core.windows.net/' } }
            $global:AzlPlanState.Quorum.ResourceType = 'Cloud Witness'; $global:AzlPlanState.Quorum.ResourceName = 'Cloud Witness'; $global:AzlPlanState.Quorum.ResourceState = 'Failed'; $global:AzlPlanState.Quorum.AccountName = 'stiicazl01wit'
            $r = Invoke-Alone $script:Quorum (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 1
            (@($r.Rows | Where-Object Item -EQ 'cluster quorum witness resource').Detail) | Should -Match 'not Online'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'plans a file share witness from cluster.witness.path, and a file share without a path is exit 2' {
            $file = New-PlanFile -Values -Edit { param($doc) $doc.cluster.witness = [ordered]@{ type = 'file_share'; path = '\\fs01.improbability.cloud\witness' } }
            $r = Invoke-Alone $script:Quorum $file @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Item -EQ 'cluster quorum witness').Action | Should -Be 'WouldConfigure'
            Get-Change | Should -BeNullOrEmpty

            Reset-World
            $file = New-PlanFile -Values -Edit { param($doc) $doc.cluster.witness = [ordered]@{ type = 'file_share' } }
            $r = Invoke-Alone $script:Quorum $file @{}
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'cluster\.witness\.path'
            $global:AzlPlanRemote.Count | Should -Be 0
        }

        It 'refuses no witness on a two-machine instance with exit 2, before any node is asked' {
            $file = New-PlanFile -Values -Edit { param($doc) $doc.cluster.witness = [ordered]@{ type = 'none' } }
            $r = Invoke-Alone $script:Quorum $file @{}
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'two machines need a witness'
            $global:AzlPlanRemote.Count | Should -Be 0
        }

        It 'plans removing a witness that exists when the file says none (three machines), and sends no Set-ClusterQuorum' {
            $global:AzlPlanState.Quorum.ResourceType = 'Cloud Witness'; $global:AzlPlanState.Quorum.ResourceName = 'Cloud Witness'; $global:AzlPlanState.Quorum.ResourceState = 'Online'; $global:AzlPlanState.Quorum.AccountName = 'x'; $global:AzlPlanState.Quorum.Nodes = 3
            $file = New-PlanFile -Values -Edit {
                param($doc)
                $doc.cluster.witness = [ordered]@{ type = 'none' }
                $doc.nodes = @($doc.nodes) + @([ordered]@{ name = 'iic-azl-n03'; management = [ordered]@{ ip_address = '192.0.2.13' } })
            }
            $r = Invoke-Alone $script:Quorum $file @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Item -EQ 'cluster quorum witness').Action | Should -Be 'WouldConfigure'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'stops with exit code 2 and asks nothing when there is no login (the example keeps its Key Vault reference)' {
            $file = New-PlanFile -Values -Edit {
                param($doc)
                $doc.identity.active_directory.lcm_user.password = 'keyvault://kv-iic-mgmt-01/lcm-password'
            }
            $r = Invoke-Alone $script:Quorum $file @{}
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'password'
            Get-Change | Should -BeNullOrEmpty
        }
    }
}
