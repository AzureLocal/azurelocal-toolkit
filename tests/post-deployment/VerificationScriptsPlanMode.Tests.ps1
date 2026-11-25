#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 09 (post-deployment verification): the three scripts of the task each run ALONE, with only their own parameters, against the
# toolkit example file. They are read only, so "Plan mode" is -WhatIf (the checks are listed and none runs); the checks themselves are run too, against fakes:
#   Invoke-VerifyPostDeployment.ps1                         the node checks (cluster, identity, quorum, groups, SSH, storage) and the Azure counts
#   Invoke-VerifyPostDeployment.azcli.ps1                   the Azure side with the Azure CLI
#   Invoke-PostDeploymentVerification-Orchestrated.ps1      the whole verification: both scripts, the solution health summary and the SAN checks
# Invoke-Command and az are fakes, so no cluster and no Azure is used. The file is config/variables/examples/infrastructure.example.yml, as it is, and with values added.
# Exit codes: 0 every check passed (or the checks were listed), 1 a check failed, 2 a value in the file is missing or there is no login.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/VerificationScriptsPlanMode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake cluster and Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeDiscovery {
    $script:Cases = @(
        @{ Name = 'Invoke-VerifyPostDeployment.ps1'; Own = @('Credential', 'TargetNode') }
        @{ Name = 'Invoke-VerifyPostDeployment.azcli.ps1'; Own = @('TargetNode') }
        @{ Name = 'Invoke-PostDeploymentVerification-Orchestrated.ps1'; Own = @('Credential', 'SkipAzure', 'TargetNode') }
    )
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $task = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-09-post-deployment-verification')
    $script:Paths = @{
        'Invoke-VerifyPostDeployment.ps1'                    = [IO.Path]::Combine($task, 'powershell', 'Invoke-VerifyPostDeployment.ps1')
        'Invoke-VerifyPostDeployment.azcli.ps1'              = [IO.Path]::Combine($task, 'azurecli', 'Invoke-VerifyPostDeployment.azcli.ps1')
        'Invoke-PostDeploymentVerification-Orchestrated.ps1' = [IO.Path]::Combine($task, 'powershell', 'Invoke-PostDeploymentVerification-Orchestrated.ps1')
    }
    Import-Module powershell-yaml

    function az { }
    $global:AzlPlanTenant = [guid]::NewGuid().ToString()
    $global:AzlPlanSub = [guid]::NewGuid().ToString()
    $global:AzlPlanSecret = 'AZL_TEST_PLAN_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($global:AzlPlanSecret, [guid]::NewGuid().ToString())

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
            $doc.azure.tenant_id = $global:AzlPlanTenant; $doc.azure.subscription_id = $global:AzlPlanSub
            $doc.identity.local_admin.password = "env://$($global:AzlPlanSecret)"
            $doc.identity.active_directory.lcm_user.password = "env://$($global:AzlPlanSecret)"
        }
        if ($Edit) { & $Edit $doc }
        $file = Join-Path $TestDrive "plan-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-World {
        $global:AzlPlanRemote = [System.Collections.Generic.List[object]]::new()
        $global:AzlPlanCalls = [System.Collections.Generic.List[object]]::new()
        # What the cluster and Azure answer. One CSV of the example volume; every disk Healthy; the logical network of the example with its VLAN.
        $global:AzlPlanState = @{
            Csv = @(@{ Name = 'Cluster Virtual Disk (vol-workloads-01)'; State = 'Online' }); Disks = @(@{ Name = 'vol-workloads-01'; Health = 'Healthy' }); PoolHealth = 'Healthy'
            Vlan = 2204; Msdsm = @(@{ VendorId = 'DellEMC'; ProductId = 'PowerStore' }); Balance = 'RR'
        }
    }
    function Invoke-Alone([string]$Script, [string]$File, [hashtable]$Extra = @{}, [switch]$Run) {
        $global:LASTEXITCODE = $null
        $log = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
        $all = if ($Run) { & $Script -InfrastructureFile $File @Extra -LogPath $log 6>&1 3>&1 2>&1 } else { & $Script -InfrastructureFile $File @Extra -LogPath $log -WhatIf 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text     = (@($all | ForEach-Object { "$_" }) -join "`n") + "`n" + $(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw })
        }
    }
    $script:Cred = [pscredential]::new('IIC\lcm-test', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force))
}

Describe 'The verification scripts of phase 06 run alone' {
    AfterAll { Remove-Variable -Name AzlPlanTenant, AzlPlanSub, AzlPlanSecret, AzlPlanRemote, AzlPlanCalls, AzlPlanState -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-World
        Mock Invoke-Command {
            $text = $ScriptBlock.ToString()
            $step = if ($ArgumentList -and $ArgumentList.Count -gt 0) { [string]$ArgumentList[0] } else { '' }
            $global:AzlPlanRemote.Add([pscustomobject]@{ Text = $text; Step = $step; Computer = [string]$ComputerName })
            if ($text -match 'Win32_ComputerSystem') { return [pscustomobject]@{ Domain = 'improbability.cloud'; PartOfDomain = $true; SecureChannel = $true } }
            if ($text -match 'Get-ClusterQuorum') { return @{ QuorumType = 'Majority'; WitnessName = 'Cloud Witness'; WitnessType = 'Cloud Witness'; WitnessState = 'Online'; NonVotingNodes = @() } }
            if ($text -match 'Get-ClusterSharedVolume') { return @{ Pools = @($global:AzlPlanState.PoolHealth); Csv = @($global:AzlPlanState.Csv); VirtualDisks = @($global:AzlPlanState.Disks) } }
            if ($text -match 'Get-ClusterNode') { return @(@{ Name = 'iic-azl-n01'; State = 'Up' }, @{ Name = 'iic-azl-n02'; State = 'Up' }) }
            if ($text -match 'Get-LocalGroupMember') { $counts = @{}; foreach ($g in $ArgumentList[0]) { $counts[[string]$g] = 1 }; return $counts }
            if ($text -match 'sshd') { return 'Stopped' }
            if ($step -eq 'Health') { return @{ Source = 'Get-SolutionHealthSummary'; Status = 'SUCCESS'; Issues = @() } }
            if ($step -eq 'San') {
                return @{ Computer = [string]$ComputerName; Disks = @(@{ Name = 'LUN'; Health = 'Healthy' }); UniqueIds = @('ID-1'); Paths = @(@{ Name = 'LUN'; Paths = 2 }); Msdsm = @($global:AzlPlanState.Msdsm); LoadBalance = $global:AzlPlanState.Balance }
            }
            throw "unexpected remote call: $text"
        }
        Mock az {
            $a = @($args | ForEach-Object { [string]$_ })
            $words = @(); foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
            $command = $words -join ' '
            $global:AzlPlanCalls.Add([pscustomobject]@{ Command = $command; Arguments = $a })
            $global:LASTEXITCODE = 0
            switch ($command) {
                'account show' { return ('{"tenantId":"' + $global:AzlPlanTenant + '","id":"' + $global:AzlPlanSub + '"}') }
                'stack-hci-vm network lnet list' { return ('[{"name":"lnet-workloads","properties":{"provisioningState":"Succeeded","subnets":[{"properties":{"vlan":' + $global:AzlPlanState.Vlan + '}}]}}]') }
                'stack-hci-vm image list' { return '[]' }
                default { return '[]' }
            }
        }
    }

    Context '<Name>' -ForEach $script:Cases {
        BeforeAll { $script:This = $script:Paths[$Name] }

        It 'takes -InfrastructureFile as its only mandatory parameter, and -WhatIf and -LogPath' {
            $command = Get-Command -Name $script:This
            @($command.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory } } | ForEach-Object Name) | Should -Be @('InfrastructureFile')
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $command.Parameters.ContainsKey('LogPath') | Should -BeTrue
            @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters -and $_ -notin 'InfrastructureFile', 'LogPath' } | Sort-Object) | Should -Be @($Own | Sort-Object)
        }

        It 'lists its checks against the example as it is, alone: exit 0 (or 2 on the placeholder ids), no node is asked, nothing is read from Azure' {
            $r = Invoke-Alone $script:This (New-PlanFile) @{}
            $r.ExitCode | Should -BeIn @(0, 2) -Because $r.Text
            if ($Name -like '*azcli*') { $r.ExitCode | Should -Be 2 }
            $global:AzlPlanRemote.Count | Should -Be 0
            $global:AzlPlanCalls.Count | Should -Be 0
        }

        It 'lists its checks against the example with the values added, alone: exit 0, no node is asked and no Azure read happens' {
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlPlanRemote.Count | Should -Be 0
            @($global:AzlPlanCalls | Where-Object { $_.Command -notin 'account show' }).Count | Should -Be 0
        }
    }

    Context 'Invoke-VerifyPostDeployment.ps1 checks the storage against the design, and the VLAN IDs against the site plan' {
        It 'passes when the CSV of storage.volumes is Online, every virtual disk is Healthy and the VLAN ID of Azure is the VLAN ID of the file' {
            $r = Invoke-Alone $script:Paths['Invoke-VerifyPostDeployment.ps1'] (New-PlanFile -Values -Edit { param($doc) $doc.networking.logical_networks[0].name = 'lnet-workloads' }) @{ Credential = $script:Cred } -Run
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Volume vol-workloads-01 \(storage\.volumes\) is an Online cluster shared volume'
            $r.Text | Should -Match 'Virtual disk health - 1 disk\(s\) Healthy'
            $r.Text | Should -Match 'Logical network lnet-workloads VLAN ID is 2204 \(the file\)'
        }

        It 'fails (exit 1) when the volume of the file is not a cluster shared volume' {
            $global:AzlPlanState.Csv = @(@{ Name = 'Cluster Virtual Disk (other)'; State = 'Online' })
            $r = Invoke-Alone $script:Paths['Invoke-VerifyPostDeployment.ps1'] (New-PlanFile -Values) @{ Credential = $script:Cred } -Run
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match '\[FAIL\].*Volume vol-workloads-01 \(storage\.volumes\).*not found'
        }

        It 'fails (exit 1) when a virtual disk is not Healthy' {
            $global:AzlPlanState.Disks = @(@{ Name = 'vol-workloads-01'; Health = 'Unhealthy' })
            $r = Invoke-Alone $script:Paths['Invoke-VerifyPostDeployment.ps1'] (New-PlanFile -Values) @{ Credential = $script:Cred } -Run
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match '\[FAIL\].*Virtual disk health.*vol-workloads-01 Unhealthy'
        }

        It 'fails (exit 1) when the VLAN ID in Azure is not the VLAN ID of the site plan' {
            $global:AzlPlanState.Vlan = 999
            $r = Invoke-Alone $script:Paths['Invoke-VerifyPostDeployment.ps1'] (New-PlanFile -Values -Edit { param($doc) $doc.networking.logical_networks[0].name = 'lnet-workloads' }) @{ Credential = $script:Cred } -Run
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match '\[FAIL\].*Logical network lnet-workloads VLAN ID is 2204'
        }

        It 'stops with exit code 2, and asks no node, when there is no login (the example keeps its Key Vault reference)' {
            $r = Invoke-Alone $script:Paths['Invoke-VerifyPostDeployment.ps1'] (New-PlanFile -Edit { param($doc) $doc.azure.subscription_id = $global:AzlPlanSub }) @{} -Run
            $r.ExitCode | Should -Be 2
            $global:AzlPlanRemote.Count | Should -Be 0
        }
    }

    Context 'Invoke-PostDeploymentVerification-Orchestrated.ps1 checks SDN only when the file turns it on' {
        It 'reports the SDN checks as skipped, with the reason, when sdn.enabled is not true' {
            $r = Invoke-Alone $script:Paths['Invoke-PostDeploymentVerification-Orchestrated.ps1'] (New-PlanFile -Values -Edit { param($doc) $doc.sdn.enabled = $false }) @{ Credential = $script:Cred; SkipAzure = $true } -Run
            $r.Text | Should -Match 'skipped.{0,3} SDN checks \(Test-ArcSdn\.ps1\): sdn\.enabled is not true'
        }
    }

    Context 'Invoke-PostDeploymentVerification-Orchestrated.ps1 checks the array of a hybrid instance in MSDSM' {
        BeforeAll {
            $script:AddHybrid = {
                param($doc)
                $doc.scenario.storage_architecture = 'hybrid'
                $doc.storage.san = [ordered]@{ type = 'fibre_channel'; array = [ordered]@{ name = 'array-01'; vendor = 'Dell'; model = 'PowerStore 1200T' } }
            }
        }

        It 'passes the MSDSM check when the vendor and product IDs of the array are registered and the policy is RR' {
            $r = Invoke-Alone $script:Paths['Invoke-PostDeploymentVerification-Orchestrated.ps1'] (New-PlanFile -Values -Edit $script:AddHybrid) @{ Credential = $script:Cred; SkipAzure = $true } -Run
            $r.Text | Should -Match 'MSDSM on iic-azl-n01: the array is registered, load balance policy RR'
        }

        It 'fails the MSDSM check when the array is not registered' {
            $global:AzlPlanState.Msdsm = @()
            $r = Invoke-Alone $script:Paths['Invoke-PostDeploymentVerification-Orchestrated.ps1'] (New-PlanFile -Values -Edit $script:AddHybrid) @{ Credential = $script:Cred; SkipAzure = $true } -Run
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'MSDSM on iic-azl-n01: not registered: DellEMC PowerStore'
        }

        It 'fails the MSDSM check when the load balance policy is not RR' {
            $global:AzlPlanState.Balance = 'FOO'
            $r = Invoke-Alone $script:Paths['Invoke-PostDeploymentVerification-Orchestrated.ps1'] (New-PlanFile -Values -Edit $script:AddHybrid) @{ Credential = $script:Cred; SkipAzure = $true } -Run
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match "load balance policy is 'FOO', not RR"
        }
    }
}
