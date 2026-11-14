#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Stage 03 (on-premises readiness), phase 01 (Active Directory), tasks 01, 02 and 04: Set-ADConfiguration.ps1 prepares the dedicated OU and the LCM user with
# Microsoft's New-HciAdObjectsPreCreation (and, when the file asks, the computer objects), New-ADSecurityGroups.ps1 creates identity.active_directory.security_groups[]
# (the groups Set-ADGroupMemberships.ps1 fills), and New-ADAccounts.ps1 creates the optional domain join account. Every ActiveDirectory cmdlet and the Microsoft
# module are mocked: no domain, no domain controller and no credential is used. Passwords come from environment variables made for the run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/ActiveDirectoryPrep.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the directory and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the ActiveDirectory cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test values are random and made for the run.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Repo = $repo
    $dir = [IO.Path]::Combine($repo, 'scripts', 'deploy', '03-onprem-readiness', 'phase-01-active-directory')
    $script:Prep = [IO.Path]::Combine($dir, 'task-01-ou-creation-pre-creation-artifacts', 'powershell', 'Set-ADConfiguration.ps1')
    $script:Groups = [IO.Path]::Combine($dir, 'task-02-security-groups', 'powershell', 'New-ADSecurityGroups.ps1')
    $script:Accounts = [IO.Path]::Combine($dir, 'task-04-service-admin-accounts', 'powershell', 'New-ADAccounts.ps1')
    $script:Members = [IO.Path]::Combine($dir, 'task-05-group-assignments', 'powershell', 'Set-ADGroupMemberships.ps1')
    Import-Module powershell-yaml

    function Get-ADOrganizationalUnit { [CmdletBinding()] param([string]$Filter, [string]$Server, [pscredential]$Credential) }
    function Get-ADUser { [CmdletBinding()] param([string]$Filter, [string]$Server, [pscredential]$Credential) }
    function Get-ADGroup { [CmdletBinding()] param([string]$Filter, [string]$Server, [pscredential]$Credential) }
    function Get-ADComputer { [CmdletBinding()] param([string]$Filter, [string]$Server, [pscredential]$Credential) }
    function New-ADComputer { [CmdletBinding()] param([string]$Name, [string]$Path, [bool]$Enabled, [string]$Server, [pscredential]$Credential) }
    function New-ADGroup { [CmdletBinding()] param([string]$Name, [string]$GroupScope, [string]$GroupCategory, [string]$Path, [string]$Description, [string]$Server, [pscredential]$Credential) }
    function New-ADUser { [CmdletBinding()] param([string]$Name, [string]$SamAccountName, [string]$UserPrincipalName, [string]$Path, [securestring]$AccountPassword, [bool]$Enabled, [string]$Server, [pscredential]$Credential) }
    function New-HciAdObjectsPreCreation { [CmdletBinding()] param([pscredential]$AzureStackLCMUserCredential, [string]$AsHciOUName) }

    $global:AzlAdOu = 'OU=iic-azl-01,OU=AzureLocal,DC=improbability,DC=cloud'
    $env:AZL_TEST_LCM_PW = [guid]::NewGuid().ToString('N') + 'Aa1!'
    $env:AZL_TEST_JOIN_PW = [guid]::NewGuid().ToString('N') + 'Aa1!'

    function New-InfraFile {
        param([hashtable]$Directory = @{}, [string]$Identity = 'active_directory', [object]$Nodes = $null, [string]$Cluster = 'iic-azl-01')
        $ad = [ordered]@{
            domain_fqdn = 'improbability.cloud'; netbios_name = 'IIC'; ou_path = $global:AzlAdOu
            lcm_user    = [ordered]@{ username = 'lcm-iic-azl-01'; password = 'env://AZL_TEST_LCM_PW' }
            security_groups = @([ordered]@{ name = 'sg-iic-azl-01-admins'; purpose = 'Administrators of the instance' }, [ordered]@{ name = 'sg-iic-azl-01-operators'; purpose = 'Operators of the instance' })
        }
        foreach ($k in $Directory.Keys) { if ($null -eq $Directory[$k]) { $ad.Remove($k) } else { $ad[$k] = $Directory[$k] } }
        $doc = [ordered]@{
            scenario = [ordered]@{ identity = $Identity }
            cluster  = [ordered]@{ name = $Cluster }
            nodes    = $(if ($null -ne $Nodes) { @($Nodes) } else { @([ordered]@{ name = 'iic-n01' }, [ordered]@{ name = 'iic-n02' }) })
            identity = [ordered]@{ active_directory = $ad }
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Directory {
        $global:AzlAdOuExists = $false
        $global:AzlAdUsers = @()          # sAMAccountNames that exist
        $global:AzlAdGroupsExisting = @()
        $global:AzlAdComputersExisting = @()
        $global:AzlAdCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlAdFilters = [System.Collections.Generic.List[string]]::new()
    }
    function Invoke-Tool([string]$Script, [string]$File, [hashtable]$Extra = @{}, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_ -isnot [string] -and $_ -isnot [Management.Automation.InformationRecord] -and $_ -isnot [Management.Automation.WarningRecord] -and $_ -isnot [Management.Automation.ErrorRecord] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'the Active Directory tasks (mocked directory)' {
    AfterAll {
        Remove-Variable -Name AzlAdOu, AzlAdOuExists, AzlAdUsers, AzlAdGroupsExisting, AzlAdComputersExisting, AzlAdCalls, AzlAdFilters -Scope Global -ErrorAction SilentlyContinue
        Remove-Item Env:AZL_TEST_LCM_PW, Env:AZL_TEST_JOIN_PW -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Reset-Directory
        Mock Get-ADOrganizationalUnit { $global:AzlAdFilters.Add($Filter); if ($global:AzlAdOuExists) { [pscustomobject]@{ DistinguishedName = $global:AzlAdOu } } }
        Mock Get-ADUser { $global:AzlAdFilters.Add($Filter); $n = if ($Filter -match "'(?<n>[^']+)'") { $Matches['n'] } else { '' }; if ($global:AzlAdUsers -contains $n) { [pscustomobject]@{ SamAccountName = $n } } }
        Mock Get-ADGroup { $n = if ($Filter -match "'(?<n>[^']+)'") { $Matches['n'] } else { '' }; if ($global:AzlAdGroupsExisting -contains $n) { [pscustomobject]@{ Name = $n } } }
        Mock Get-ADComputer { $n = if ($Filter -match "'(?<n>[^']+)'") { $Matches['n'] } else { '' }; if ($global:AzlAdComputersExisting -contains $n) { [pscustomobject]@{ Name = $n } } }
        Mock New-ADComputer { $global:AzlAdCalls.Add([pscustomobject]@{ Cmd = 'computer'; Name = $Name; Path = $Path; Enabled = $Enabled; Server = $Server }) }
        Mock New-ADGroup { $global:AzlAdCalls.Add([pscustomobject]@{ Cmd = 'group'; Name = $Name; Path = $Path; Scope = $GroupScope; Category = $GroupCategory; Description = $Description; Server = $Server }) }
        Mock New-ADUser { $global:AzlAdCalls.Add([pscustomobject]@{ Cmd = 'user'; Name = $Name; Sam = $SamAccountName; Upn = $UserPrincipalName; Path = $Path; Enabled = $Enabled; HasPassword = ($null -ne $AccountPassword); Server = $Server }) }
        Mock New-HciAdObjectsPreCreation {
            $plain = $AzureStackLCMUserCredential.GetNetworkCredential().Password
            $global:AzlAdCalls.Add([pscustomobject]@{ Cmd = 'prep'; User = $AzureStackLCMUserCredential.UserName; Ou = $AsHciOUName; PasswordIsTheSecret = ($plain -eq $env:AZL_TEST_LCM_PW) })
        }
    }

    Context 'Set-ADConfiguration.ps1' {
        It 'prepares the OU and the LCM user of the file with Microsoft''s cmdlet, with the password read from the reference' {
            $r = Invoke-Tool $script:Prep (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $prep = @($global:AzlAdCalls | Where-Object Cmd -EQ 'prep')
            $prep.Count | Should -Be 1
            $prep[0].User | Should -Be 'lcm-iic-azl-01'
            $prep[0].Ou | Should -Be $global:AzlAdOu
            $prep[0].PasswordIsTheSecret | Should -BeTrue
            @($r.Rows | Where-Object Action -EQ 'Created').Count | Should -Be 2
        }

        It 'does nothing when the OU and the user exist, and says so' {
            $global:AzlAdOuExists = $true; $global:AzlAdUsers = @('lcm-iic-azl-01')
            $r = Invoke-Tool $script:Prep (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlAdCalls.Count | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'AlreadyExists').Count | Should -Be 2
        }

        It 'stops with exit code 1 and sends nothing when only the OU or only the user exists' {
            $global:AzlAdOuExists = $true
            $r = Invoke-Tool $script:Prep (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'creates both'
            $global:AzlAdCalls.Count | Should -Be 0
            Reset-Directory; $global:AzlAdUsers = @('lcm-iic-azl-01')
            (Invoke-Tool $script:Prep (New-InfraFile)).ExitCode | Should -Be 1
            $global:AzlAdCalls.Count | Should -Be 0
        }

        It 'plans and changes nothing under -WhatIf, and does not read the secret' {
            $r = Invoke-Tool $script:Prep (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlAdCalls.Count | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 2
        }

        It 'creates the computer objects of the machines and the cluster only when precreate_computer_objects is true (the cluster object disabled)' {
            $null = Invoke-Tool $script:Prep (New-InfraFile)
            @($global:AzlAdCalls | Where-Object Cmd -EQ 'computer').Count | Should -Be 0
            Reset-Directory
            $r = Invoke-Tool $script:Prep (New-InfraFile -Directory @{ precreate_computer_objects = $true })
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $objects = @($global:AzlAdCalls | Where-Object Cmd -EQ 'computer')
            @($objects.Name | Sort-Object) | Should -Be @('iic-azl-01', 'iic-n01', 'iic-n02')
            ($objects | Where-Object Name -EQ 'iic-azl-01').Enabled | Should -BeFalse
            ($objects | Where-Object Name -EQ 'iic-n01').Enabled | Should -BeTrue
            @($objects.Path | Select-Object -Unique) | Should -Be $global:AzlAdOu
        }

        It 'leaves a computer object that exists alone' {
            $global:AzlAdOuExists = $true; $global:AzlAdUsers = @('lcm-iic-azl-01'); $global:AzlAdComputersExisting = @('iic-n01')
            $r = Invoke-Tool $script:Prep (New-InfraFile -Directory @{ precreate_computer_objects = $true })
            @($global:AzlAdCalls | Where-Object Cmd -EQ 'computer').Name | Should -Not -Contain 'iic-n01'
            @($global:AzlAdCalls | Where-Object Cmd -EQ 'computer').Count | Should -Be 2
        }

        It 'does nothing with local identity' {
            $r = Invoke-Tool $script:Prep (New-InfraFile -Identity 'local_identity')
            $r.ExitCode | Should -Be 0
            Should -Invoke Get-ADOrganizationalUnit -Times 0 -Exactly
        }

        It 'stops with exit code 2 for a value Microsoft does not allow or the file does not give' -ForEach @(
            @{ Why = 'an OU outside the domain'; Directory = @{ ou_path = 'OU=iic-azl-01,DC=example,DC=test' } }
            @{ Why = 'an OU with an apostrophe'; Directory = @{ ou_path = "OU=iic'azl,OU=AzureLocal,DC=improbability,DC=cloud" } }
            @{ Why = 'an OU that is not an OU'; Directory = @{ ou_path = 'CN=Users,DC=improbability,DC=cloud' } }
            @{ Why = 'no OU'; Directory = @{ ou_path = $null } }
            @{ Why = 'no domain'; Directory = @{ domain_fqdn = $null } }
            @{ Why = 'a user that starts with a digit'; Directory = @{ lcm_user = @{ username = '1lcm'; password = 'env://AZL_TEST_LCM_PW' } } }
            @{ Why = 'a user with a domain'; Directory = @{ lcm_user = @{ username = 'IIC\lcm'; password = 'env://AZL_TEST_LCM_PW' } } }
            @{ Why = 'the user admin'; Directory = @{ lcm_user = @{ username = 'admin'; password = 'env://AZL_TEST_LCM_PW' } } }
            @{ Why = 'no password reference'; Directory = @{ lcm_user = @{ username = 'lcm-iic-azl-01' } } }
            @{ Why = 'a flag that is not true or false'; Directory = @{ precreate_computer_objects = 'sometimes' } }
        ) {
            $r = Invoke-Tool $script:Prep (New-InfraFile -Directory $Directory)
            $r.ExitCode | Should -Be 2 -Because $Why
            $global:AzlAdCalls.Count | Should -Be 0
        }

        It 'stops with exit code 2 when the password reference is not a reference, without echoing it' {
            $secret = 'Not-A-Reference-' + [guid]::NewGuid().ToString('N')
            $r = Invoke-Tool $script:Prep (New-InfraFile -Directory @{ lcm_user = @{ username = 'lcm-iic-azl-01'; password = $secret } })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Not -Match ([regex]::Escape($secret))
            $global:AzlAdCalls.Count | Should -Be 0
        }

        It 'stops with exit code 1 when the Microsoft module is missing' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'New-HciAdObjectsPreCreation' }
            $r = Invoke-Tool $script:Prep (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'AsHciADArtifactsPreCreationTool'
        }
    }

    Context 'New-ADSecurityGroups.ps1' {
        It 'creates each group the file lists, with its name and purpose, as a global security group in the OU of the file' {
            $global:AzlAdOuExists = $true
            $r = Invoke-Tool $script:Groups (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $made = @($global:AzlAdCalls | Where-Object Cmd -EQ 'group')
            @($made.Name) | Should -Be @('sg-iic-azl-01-admins', 'sg-iic-azl-01-operators')
            $made[0].Description | Should -Be 'Administrators of the instance'
            @($made.Path | Select-Object -Unique) | Should -Be $global:AzlAdOu
            @($made.Scope | Select-Object -Unique) | Should -Be 'Global'
            @($made.Category | Select-Object -Unique) | Should -Be 'Security'
            @($made.Server | Select-Object -Unique) | Should -Be 'improbability.cloud'
        }

        It 'creates the same groups Set-ADGroupMemberships.ps1 fills: both read identity.active_directory.security_groups[].name and no name is built in the code' {
            foreach ($path in $script:Groups, $script:Members) {
                (Get-Content -LiteralPath $path -Raw) | Should -Match 'security_groups'
                (Get-Content -LiteralPath $path -Raw) | Should -Not -Match 'GRP-'
            }
        }

        It 'leaves a group that exists and creates only the others' {
            $global:AzlAdOuExists = $true; $global:AzlAdGroupsExisting = @('sg-iic-azl-01-admins')
            $r = Invoke-Tool $script:Groups (New-InfraFile)
            @($global:AzlAdCalls.Name) | Should -Be @('sg-iic-azl-01-operators')
            @($r.Rows | Where-Object Action -EQ 'AlreadyExists').Count | Should -Be 1
        }

        It 'plans and creates nothing under -WhatIf, even when the OU is not there yet' {
            $r = Invoke-Tool $script:Groups (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlAdCalls.Count | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 2
        }

        It 'fails and creates nothing when the OU does not exist (task 01 has not run)' {
            $r = Invoke-Tool $script:Groups (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Set-ADConfiguration'
            $global:AzlAdCalls.Count | Should -Be 0
        }

        It 'does nothing when the file lists no group, and with local identity' {
            (Invoke-Tool $script:Groups (New-InfraFile -Directory @{ security_groups = $null })).ExitCode | Should -Be 0
            (Invoke-Tool $script:Groups (New-InfraFile -Identity 'local_identity')).ExitCode | Should -Be 0
            $global:AzlAdCalls.Count | Should -Be 0
        }

        It 'stops with exit code 2 for a group with no name, a name listed twice or an unusable name' {
            (Invoke-Tool $script:Groups (New-InfraFile -Directory @{ security_groups = @([ordered]@{ purpose = 'x' }) })).ExitCode | Should -Be 2
            (Invoke-Tool $script:Groups (New-InfraFile -Directory @{ security_groups = @([ordered]@{ name = 'sg-a' }, [ordered]@{ name = 'SG-A' }) })).ExitCode | Should -Be 2
            (Invoke-Tool $script:Groups (New-InfraFile -Directory @{ security_groups = @([ordered]@{ name = 'a;b|c' }) })).ExitCode | Should -Be 2
            $global:AzlAdCalls.Count | Should -Be 0
        }
    }

    Context 'New-ADAccounts.ps1' {
        BeforeEach { $global:AzlAdOuExists = $true }

        It 'creates the domain join account of the file in the OU, enabled, with the password of its reference and no flag of its own' {
            $directory = @{ domain_join_account = @{ username = 'svc-azl-join'; password = 'env://AZL_TEST_JOIN_PW' } }
            $r = Invoke-Tool $script:Accounts (New-InfraFile -Directory $directory)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $user = @($global:AzlAdCalls | Where-Object Cmd -EQ 'user')
            $user.Count | Should -Be 1
            $user[0].Sam | Should -Be 'svc-azl-join'
            $user[0].Upn | Should -Be 'svc-azl-join@improbability.cloud'
            $user[0].Path | Should -Be $global:AzlAdOu
            $user[0].Enabled | Should -BeTrue
            $user[0].HasPassword | Should -BeTrue
            (Get-Content -LiteralPath $script:Accounts -Raw) | Should -Not -Match 'PasswordNeverExpires|GeneratePassword|svc-\$'
        }

        It 'takes the name part of NETBIOS\name and name@domain, and refuses another domain' {
            foreach ($form in 'IIC\svc-azl-join', 'svc-azl-join@improbability.cloud') {
                Reset-Directory; $global:AzlAdOuExists = $true
                $null = Invoke-Tool $script:Accounts (New-InfraFile -Directory @{ domain_join_account = @{ username = $form; password = 'env://AZL_TEST_JOIN_PW' } })
                @($global:AzlAdCalls | Where-Object Cmd -EQ 'user').Sam | Should -Be 'svc-azl-join'
            }
            (Invoke-Tool $script:Accounts (New-InfraFile -Directory @{ domain_join_account = @{ username = 'OTHER\svc'; password = 'env://AZL_TEST_JOIN_PW' } })).ExitCode | Should -Be 2
            (Invoke-Tool $script:Accounts (New-InfraFile -Directory @{ domain_join_account = @{ username = 'svc@example.test'; password = 'env://AZL_TEST_JOIN_PW' } })).ExitCode | Should -Be 2
        }

        It 'leaves an account that exists, plans under -WhatIf, and does nothing when the file names no join account' {
            $directory = @{ domain_join_account = @{ username = 'svc-azl-join'; password = 'env://AZL_TEST_JOIN_PW' } }
            $global:AzlAdUsers = @('svc-azl-join')
            @((Invoke-Tool $script:Accounts (New-InfraFile -Directory $directory)).Rows | Where-Object Action -EQ 'AlreadyExists').Count | Should -Be 1
            $global:AzlAdCalls.Count | Should -Be 0
            Reset-Directory; $global:AzlAdOuExists = $true
            @((Invoke-Tool $script:Accounts (New-InfraFile -Directory $directory) -DryRun).Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 1
            (Invoke-Tool $script:Accounts (New-InfraFile)).ExitCode | Should -Be 0
            $global:AzlAdCalls.Count | Should -Be 0
        }

        It 'stops with exit code 2 for a missing password reference or one that is not a reference, and with 1 for a missing OU' {
            (Invoke-Tool $script:Accounts (New-InfraFile -Directory @{ domain_join_account = @{ username = 'svc-azl-join' } })).ExitCode | Should -Be 2
            $secret = 'Plain-Value-' + [guid]::NewGuid().ToString('N')
            $r = Invoke-Tool $script:Accounts (New-InfraFile -Directory @{ domain_join_account = @{ username = 'svc-azl-join'; password = $secret } })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Not -Match ([regex]::Escape($secret))
            $global:AzlAdOuExists = $false
            (Invoke-Tool $script:Accounts (New-InfraFile -Directory @{ domain_join_account = @{ username = 'svc-azl-join'; password = 'env://AZL_TEST_JOIN_PW' } })).ExitCode | Should -Be 1
            $global:AzlAdCalls.Count | Should -Be 0
        }
    }

    Context 'the three scripts follow the script standard' {
        It 'has the standard header, asks nothing, signs in nowhere and names no group, OU or account of its own' -ForEach @(
            @{ Name = 'Set-ADConfiguration.ps1'; Path = $null }
            @{ Name = 'New-ADSecurityGroups.ps1'; Path = $null }
            @{ Name = 'New-ADAccounts.ps1'; Path = $null }
        ) {
            $path = switch ($Name) { 'Set-ADConfiguration.ps1' { $script:Prep } 'New-ADSecurityGroups.ps1' { $script:Groups } default { $script:Accounts } }
            $text = Get-Content -LiteralPath $path -Raw
            $text | Should -Match '(?m)^#Requires -Version 7\.0'
            $text | Should -Match 'Set-StrictMode -Version Latest'
            $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $text | Should -Not -Match 'Read-Host|Get-Credential|Connect-|Invoke-Expression|Write-Host'
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$null)
            $code = ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
            $code | Should -Not -Match 'OU=(Computers|ServiceAccounts|Groups|AzureLocal|Servers)'
            $code | Should -Not -Match 'GRP-|svc-|PasswordNeverExpires|GeneratePassword'
        }
    }
}
