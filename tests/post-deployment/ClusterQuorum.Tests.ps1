#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 02: Invoke-ConfigureClusterQuorum-Orchestrated.ps1 checks or creates the cloud witness storage account and sets
# the quorum witness of the cluster from cluster.witness. Invoke-Command and every Az cmdlet are mocked: no cluster, no machine and no Azure is used.
# The password of the login is read from an environment variable made for the test; the access key is a generated value that must never be printed.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/ClusterQuorum.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the state and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-02-cluster-quorum-configuration', 'powershell', 'Invoke-ConfigureClusterQuorum-Orchestrated.ps1')
    Import-Module powershell-yaml

    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzStorageAccount { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzStorageAccount { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$SkuName, [string]$Kind, [hashtable]$Tag) }
    function Get-AzStorageAccountKey { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzStorageAccountNameAvailability { [CmdletBinding()] param([string]$Name) }

    $script:PasswordVariable = 'AZL_TEST_QUORUM_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($script:PasswordVariable, [guid]::NewGuid().ToString())
    $global:AzlQTenant = [guid]::NewGuid().ToString()
    $global:AzlQSub = [guid]::NewGuid().ToString()
    $global:AzlQKey = 'K' + [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')

    function New-InfraFile {
        param([string]$Type = 'cloud', [object]$Account = 'stiicazl01wit', [object]$Path = $null, [int]$Nodes = 2, [string]$Identity = 'active_directory', [switch]$NoLogin)
        $witness = [ordered]@{ type = $Type }
        if ($null -ne $Account) { $witness.storage_account = $Account }
        if ($null -ne $Path) { $witness.path = $Path }
        $doc = [ordered]@{
            scenario = [ordered]@{ identity = $Identity }
            azure    = [ordered]@{ tenant_id = $global:AzlQTenant; subscription_id = $global:AzlQSub; resource_group = 'rg-iic-azl-01'; location = 'westeurope' }
            tags     = [ordered]@{ Environment = 'test' }
            cluster  = [ordered]@{ name = 'iic-azl-01'; witness = $witness }
            nodes    = @(1..$Nodes | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.$(10 + $_)" } } })
            identity = [ordered]@{ local_admin = [ordered]@{ username = 'azl-admin'; password = "env://$($script:PasswordVariable)" } }
        }
        if (-not $NoLogin) { $doc.identity.active_directory = [ordered]@{ netbios_name = 'IIC'; lcm_user = [ordered]@{ username = 'lcm-azl'; password = "env://$($script:PasswordVariable)" } } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-State {
        $global:AzlQCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlQAccount = $null
        $global:AzlQNameFree = $true
        $global:AzlQDown = @()
        $global:AzlQQuorum = @{ Computer = 'IIC-N01'; Nodes = 2; QuorumType = 'NodeMajority'; ResourceName = ''; ResourceType = ''; ResourceState = ''; AccountName = ''; SharePath = ''; EndpointInfo = '' }
    }
    function New-Account([string]$Name, [string]$Kind = 'StorageV2', [string]$Sku = 'Standard_LRS') {
        [pscustomobject]@{ StorageAccountName = $Name; Kind = $Kind; Sku = [pscustomobject]@{ Name = $Sku }; PrimaryEndpoints = [pscustomobject]@{ Blob = "https://$Name.blob.core.windows.net/" } }
    }
    function Invoke-Quorum([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            All      = (@($all | ForEach-Object { "$_" }) -join "`n")
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Step) { @($global:AzlQCalls | Where-Object Step -EQ $Step) }
}

Describe 'Invoke-ConfigureClusterQuorum-Orchestrated.ps1' {
    AfterAll {
        Remove-Variable -Name AzlQCalls, AzlQAccount, AzlQNameFree, AzlQDown, AzlQQuorum, AzlQTenant, AzlQSub, AzlQKey -Scope Global -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable($script:PasswordVariable, $null)
    }

    BeforeEach {
        Reset-State
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlQTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlQSub } } }
        Mock Set-AzContext { }
        Mock Get-AzStorageAccount { if ($global:AzlQAccount) { $global:AzlQAccount } else { throw "The Resource 'Microsoft.Storage/storageAccounts/$Name' under resource group was not found." } }
        Mock Get-AzStorageAccountNameAvailability { [pscustomobject]@{ NameAvailable = $global:AzlQNameFree } }
        Mock New-AzStorageAccount { $global:AzlQCalls.Add([pscustomobject]@{ Step = 'NewAccount'; Arguments = @($Name, $SkuName, $Kind, $Location) }); $global:AzlQAccount = New-Account $Name; $global:AzlQAccount }
        Mock Get-AzStorageAccountKey { @([pscustomobject]@{ KeyName = 'key1'; Value = $global:AzlQKey }, [pscustomobject]@{ KeyName = 'key2'; Value = 'second' + $global:AzlQKey }) }
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlQCalls.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Arguments = @($ArgumentList | Select-Object -Skip 1); Credential = $Credential })
            if ([string]$ComputerName -in $global:AzlQDown) { throw [System.Management.Automation.Remoting.PSRemotingTransportException]::new("Connecting to remote server $ComputerName failed") }
            switch ($step) {
                'Probe' { 'IIC-N01' }
                'ReadQuorum' { $global:AzlQQuorum.Clone() }
                'SetCloud' {
                    $global:AzlQQuorum.ResourceType = 'Cloud Witness'; $global:AzlQQuorum.ResourceName = 'Cloud Witness'; $global:AzlQQuorum.ResourceState = 'Online'
                    $global:AzlQQuorum.AccountName = [string]$ArgumentList[1]
                }
                'SetFileShare' { $global:AzlQQuorum.ResourceType = 'File Share Witness'; $global:AzlQQuorum.SharePath = [string]$ArgumentList[1] }
                'SetNone' { $global:AzlQQuorum.ResourceType = ''; $global:AzlQQuorum.AccountName = '' }
            }
        }
    }

    Context 'cloud witness' {
        It 'creates the missing account, reads key1 and sets the cloud witness on the first node' {
            $r = Invoke-Quorum (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            ($r.Rows | Where-Object Item -Like 'cloud witness storage account*').Action | Should -Be 'Created'
            ($r.Rows | Where-Object Item -EQ 'cluster quorum witness').Action | Should -Be 'Configured'
            (Get-Call 'NewAccount')[0].Arguments | Should -Be @('stiicazl01wit', 'Standard_LRS', 'StorageV2', 'westeurope')
            $set = (Get-Call 'SetCloud')[0]
            $set.Computer | Should -Be '192.0.2.11'
            $set.Arguments[0] | Should -Be 'stiicazl01wit'
            $set.Arguments[1] | Should -BeOfType [securestring]
            [Net.NetworkCredential]::new('', $set.Arguments[1]).Password | Should -Be $global:AzlQKey
            $set.Arguments[2] | Should -Be 'core.windows.net'
            $set.Credential.UserName | Should -Be 'IIC\lcm-azl'
        }

        It 'never prints the access key' {
            $r = Invoke-Quorum (New-InfraFile)
            $r.All | Should -Not -Match ([regex]::Escape($global:AzlQKey))
        }

        It 'changes nothing when the cluster already uses the account, and reads no key' {
            $global:AzlQAccount = New-Account 'stiicazl01wit'
            $global:AzlQQuorum.ResourceType = 'Cloud Witness'; $global:AzlQQuorum.AccountName = 'stiicazl01wit'
            $r = Invoke-Quorum (New-InfraFile)
            $r.ExitCode | Should -Be 0
            ($r.Rows | Where-Object Item -EQ 'cluster quorum witness').Action | Should -Be 'AlreadyConfigured'
            (Get-Call 'SetCloud').Count | Should -Be 0
            Should -Invoke Get-AzStorageAccountKey -Times 0 -Exactly
            Should -Invoke New-AzStorageAccount -Times 0 -Exactly
        }

        It 'sets the witness again when the cluster uses the account with another endpoint' {
            $global:AzlQAccount = New-Account 'stiicazl01wit'
            $global:AzlQQuorum.ResourceType = 'Cloud Witness'; $global:AzlQQuorum.AccountName = 'stiicazl01wit'; $global:AzlQQuorum.EndpointInfo = 'core.usgovcloudapi.net'
            $r = Invoke-Quorum (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'SetCloud').Count | Should -Be 1
        }

        It 'sets the witness again with key2 under -UpdateAccessKey' {
            $global:AzlQAccount = New-Account 'stiicazl01wit'
            $global:AzlQQuorum.ResourceType = 'Cloud Witness'; $global:AzlQQuorum.AccountName = 'stiicazl01wit'
            $r = Invoke-Quorum (New-InfraFile) -Extra @{ UpdateAccessKey = $true; AccessKeyName = 'key2' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            [Net.NetworkCredential]::new('', (Get-Call 'SetCloud')[0].Arguments[1]).Password | Should -Be ('second' + $global:AzlQKey)
        }

        It 'fails and changes nothing when the existing account has the wrong SKU' {
            $global:AzlQAccount = New-Account 'stiicazl01wit' -Sku 'Standard_GRS'
            $r = Invoke-Quorum (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Standard_GRS'
            (Get-Call 'SetCloud').Count | Should -Be 0
            (Get-Call 'ReadQuorum').Count | Should -Be 0
        }

        It 'fails when the name is taken elsewhere in Azure' {
            $global:AzlQNameFree = $false
            $r = Invoke-Quorum (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'taken'
            Should -Invoke New-AzStorageAccount -Times 0 -Exactly
        }

        It 'plans under -WhatIf: creates no account, reads no key, runs no quorum command' {
            $r = Invoke-Quorum (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('WouldCreate', 'WouldConfigure')
            Should -Invoke New-AzStorageAccount -Times 0 -Exactly
            Should -Invoke Get-AzStorageAccountKey -Times 0 -Exactly
            @((Get-Call 'SetCloud'), (Get-Call 'SetFileShare'), (Get-Call 'SetNone') | Where-Object { $_ }).Count | Should -Be 0
        }

        It 'stops with exit 1 when signed in to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            (Invoke-Quorum (New-InfraFile)).ExitCode | Should -Be 1
        }

        It 'tries the next node when the first does not answer' {
            $global:AzlQDown = @('192.0.2.11')
            $r = Invoke-Quorum (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'SetCloud')[0].Computer | Should -Be '192.0.2.12'
        }

        It 'fails when no node answers' {
            $global:AzlQDown = @('192.0.2.11', '192.0.2.12')
            $r = Invoke-Quorum (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'no node answered'
        }
    }

    Context 'file share witness and no witness' {
        It 'sets the file share witness from cluster.witness.path, and needs no Azure' {
            $r = Invoke-Quorum (New-InfraFile -Type 'file_share' -Account $null -Path '\\fs01.example.com\witness$')
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'SetFileShare')[0].Arguments[0] | Should -Be '\\fs01.example.com\witness$'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'leaves a file share witness that already is the path' {
            $global:AzlQQuorum.ResourceType = 'File Share Witness'; $global:AzlQQuorum.SharePath = '\\fs01.example.com\witness$'
            $r = Invoke-Quorum (New-InfraFile -Type 'file_share' -Account $null -Path '\\fs01.example.com\witness$')
            ($r.Rows | Where-Object Item -EQ 'cluster quorum witness').Action | Should -Be 'AlreadyConfigured'
            (Get-Call 'SetFileShare').Count | Should -Be 0
        }

        It 'refuses a path that is not a UNC path (exit 2, nothing called)' {
            $r = Invoke-Quorum (New-InfraFile -Type 'file_share' -Account $null -Path 'C:\witness')
            $r.ExitCode | Should -Be 2
            $global:AzlQCalls.Count | Should -Be 0
        }

        It 'refuses none on two machines (exit 2)' {
            $r = Invoke-Quorum (New-InfraFile -Type 'none' -Account $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'two machines need a witness'
        }

        It 'removes the witness for none on three machines' {
            $global:AzlQQuorum.Nodes = 3; $global:AzlQQuorum.ResourceType = 'Cloud Witness'; $global:AzlQQuorum.AccountName = 'old'
            $r = Invoke-Quorum (New-InfraFile -Type 'none' -Account $null -Nodes 3)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'SetNone').Count | Should -Be 1
        }
    }

    Context 'input problems (exit 2, nothing called)' {
        It 'refuses a disk witness type' {
            $r = Invoke-Quorum (New-InfraFile -Type 'disk')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Storage Spaces Direct'
        }

        It 'refuses a storage account name that is not valid' {
            (Invoke-Quorum (New-InfraFile -Account 'Bad_Name')).ExitCode | Should -Be 2
            $global:AzlQCalls.Count | Should -Be 0
        }

        It 'stops when there is no login and no -Credential' {
            $r = Invoke-Quorum (New-InfraFile -NoLogin)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'No login'
        }

        It 'uses the local administrator with local identity' {
            $r = Invoke-Quorum (New-InfraFile -Identity 'local_identity' -NoLogin)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'Probe')[0].Credential.UserName | Should -Be '.\azl-admin'
        }
    }
}
