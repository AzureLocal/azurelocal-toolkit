#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 03 (security groups applied to nodes): Invoke-ApplySecurityGroups-Orchestrated.ps1 runs ALONE, with only its own
# parameters, and plans against the toolkit example file: it reads the nodes (which groups resolve, who is in each local group) and adds nothing under -WhatIf.
# Invoke-Command is a fake, so no node is used. The file is config/variables/examples/infrastructure.example.yml, as it is, and with a login that does not
# need Key Vault added in memory.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/SecurityGroupsPlanMode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake node and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $script:This = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-03-security-groups-applied-to-nodes', 'powershell', 'Invoke-ApplySecurityGroups-Orchestrated.ps1')
    Import-Module powershell-yaml

    function az { }
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
        if ($Values) { $doc.identity.active_directory.lcm_user.password = "env://$($global:AzlPlanSecret)" }
        if ($Edit) { & $Edit $doc }
        $file = Join-Path $TestDrive "plan-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-World {
        $global:AzlPlanRemote = [System.Collections.Generic.List[object]]::new()
        # Per node address: the local groups and who is in them. The AD group of the example resolves to a SID unless it is listed in Unresolved.
        $global:AzlPlanState = @{ Members = @{ 'Administrators' = @() }; Unresolved = @(); AddFails = $false }
    }
    function Invoke-Alone([hashtable]$Extra, [string]$File, [switch]$Apply) {
        $global:LASTEXITCODE = $null
        $all = if ($Apply) { & $script:This -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 } else { & $script:This -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Write { @($global:AzlPlanRemote | Where-Object Step -EQ 'AddMember') }
}

Describe 'Invoke-ApplySecurityGroups-Orchestrated.ps1 runs alone in Plan mode' {
    AfterAll { Remove-Variable -Name AzlPlanSecret, AzlPlanRemote, AzlPlanState -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-World
        Mock Invoke-Command {
            $step = [string]$ArgumentList[0]
            $global:AzlPlanRemote.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName; Credential = $Credential; Arguments = @($ArgumentList | Select-Object -Skip 1) })
            switch ($step) {
                'ReadState' {
                    $resolved = @{}
                    foreach ($g in @($ArgumentList[1])) { $resolved[$g] = $(if ($g -in $global:AzlPlanState.Unresolved) { '' } else { 'S-1-5-21-1-2-3-1104' }) }
                    $members = @{}
                    foreach ($l in @($ArgumentList[2])) { $members[$l] = @($global:AzlPlanState.Members[$l] | Where-Object { $_ }) }
                    return @{ Computer = 'iic-azl-n01'; Resolved = $resolved; Members = $members }
                }
                'AddMember' {
                    if ($global:AzlPlanState.AddFails) { throw 'Access is denied' }
                    $global:AzlPlanState.Members[[string]$ArgumentList[1]] = @(@($global:AzlPlanState.Members[[string]$ArgumentList[1]]) + @(@{ Name = [string]$ArgumentList[2]; Sid = 'S-1-5-21-1-2-3-1104' }))
                    return 'Added'
                }
            }
        }
    }

    It 'takes -InfrastructureFile as its only mandatory parameter, and -WhatIf and -LogPath' {
        $command = Get-Command -Name $script:This
        @($command.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory } } | ForEach-Object Name) | Should -Be @('InfrastructureFile')
        $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        $command.Parameters.ContainsKey('LogPath') | Should -BeTrue
        @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters -and $_ -notin 'InfrastructureFile', 'LogPath' } | Sort-Object) | Should -Be @('Credential', 'TargetNode')
    }

    It 'plans against the toolkit example as it is: exit 2 (the LCM password is a Key Vault reference nothing can read here), no node is asked' {
        $r = Invoke-Alone @{} (New-PlanFile)
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $r.Text | Should -Match 'password of identity\.active_directory\.lcm_user'
        $global:AzlPlanRemote.Count | Should -Be 0
    }

    It 'plans against the example with a login added, alone: exit 0, every node is read, the group is only planned, the log is written' {
        $log = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
        $r = Invoke-Alone @{ LogPath = $log } (New-PlanFile -Values)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows.Action) | Should -Be @('WouldAdd', 'WouldAdd')
        @($global:AzlPlanRemote | Where-Object Step -EQ 'ReadState').Count | Should -Be 2
        Get-Write | Should -BeNullOrEmpty
        @($global:AzlPlanRemote.Computer | Sort-Object -Unique) | Should -Be @('192.0.2.11', '192.0.2.12')
        @($global:AzlPlanRemote.Credential.UserName | Sort-Object -Unique) | Should -Be @('IIC\lcm-iic-azl-01')
        (Get-Content -LiteralPath $log -Raw) | Should -Match 'Will assign: IIC\\sg-iic-azl-01-admins'
    }

    It 'is idempotent: a group that is a member already is AlreadyMember, nothing is planned or added' {
        $global:AzlPlanState.Members['Administrators'] = @(@{ Name = 'IIC\sg-iic-azl-01-admins'; Sid = 'S-1-5-21-1-2-3-1104' })
        $r = Invoke-Alone @{} (New-PlanFile -Values)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows.Action | Sort-Object -Unique) | Should -Be @('AlreadyMember')
        Get-Write | Should -BeNullOrEmpty
    }

    It 'fails with exit 1 for a group that does not exist in the domain, and adds nothing' {
        $global:AzlPlanState.Unresolved = @('IIC\sg-iic-azl-01-admins')
        $r = Invoke-Alone @{} (New-PlanFile -Values)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'not found in the domain'
        Get-Write | Should -BeNullOrEmpty
    }

    It 'limits the plan to -TargetNode (by node name)' {
        $r = Invoke-Alone @{ TargetNode = 'iic-azl-n02' } (New-PlanFile -Values)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlPlanRemote.Computer | Sort-Object -Unique) | Should -Be @('192.0.2.12')
    }

    It 'has nothing to do, and exits 0, when no group of the file has local_groups' {
        $file = New-PlanFile -Values -Edit { param($doc) $doc.identity.active_directory.security_groups = @([ordered]@{ name = 'sg-iic-azl-01-wac'; purpose = 'wac' }) }
        $r = Invoke-Alone @{} $file
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlPlanRemote.Count | Should -Be 0
    }

    It 'stops with exit code 2, and asks nothing, when the file has no netbios name and no -Credential is passed' {
        $file = New-PlanFile -Values -Edit { param($doc) $doc.identity.active_directory.netbios_name = '' }
        $r = Invoke-Alone @{} $file
        $r.ExitCode | Should -Be 2
        $global:AzlPlanRemote.Count | Should -Be 0
    }

    It 'applies the group, checks it after and reports Verified; a second run only finds AlreadyMember' {
        $file = New-PlanFile -Values
        $r = Invoke-Alone @{} $file -Apply
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Write).Count | Should -Be 1 # the fake keeps one membership list for both nodes, so the second node already has the group
        @($r.Rows | Where-Object Action -EQ 'Verified').Count | Should -Be 2
        $global:AzlPlanRemote.Clear()
        $r = Invoke-Alone @{} $file -Apply
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Get-Write | Should -BeNullOrEmpty
    }

    It 'fails with exit 1 when the add is refused' {
        $global:AzlPlanState.AddFails = $true
        $r = Invoke-Alone @{} (New-PlanFile -Values) -Apply
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Access is denied'
    }
}
