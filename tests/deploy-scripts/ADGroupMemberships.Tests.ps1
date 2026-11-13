#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Stage 03 (on-premises readiness), phase 01, task 05: Set-ADGroupMemberships.ps1 adds the members of identity.active_directory.security_groups[].members
# to their groups. Every ActiveDirectory cmdlet is mocked: no domain, no domain controller, no credential is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/ADGroupMemberships.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the directory and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the ActiveDirectory cmdlets.')]
param()

BeforeDiscovery {
    $script:BadNames = @('bad name;drop', 'a\b', 'x*', 'a"b') | ForEach-Object { @{ Name = $_ } }
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '03-onprem-readiness', 'phase-01-active-directory', 'task-05-group-assignments', 'powershell', 'Set-ADGroupMemberships.ps1')
    Import-Module powershell-yaml

    function Get-ADGroup { [CmdletBinding()] param([string]$Identity, [string]$Server, [pscredential]$Credential) }
    function Get-ADGroupMember { [CmdletBinding()] param([object]$Identity, [string]$Server, [pscredential]$Credential) }
    function Get-ADObject { [CmdletBinding()] param([string]$LDAPFilter, [string]$Server, [pscredential]$Credential) }
    function Add-ADGroupMember { [CmdletBinding()] param([object]$Identity, [object]$Members, [string]$Server, [pscredential]$Credential) }

    function New-InfraFile {
        param([object[]]$Groups = @([ordered]@{ name = 'sg-iic-azl-01-admins'; members = @('iic-admin-01', 'iic-admin-02@improbability.cloud') }), [string]$Identity = 'active_directory', [hashtable]$Directory = @{})
        $ad = [ordered]@{ domain_fqdn = 'improbability.cloud'; security_groups = @($Groups) }
        foreach ($k in $Directory.Keys) { if ($null -eq $Directory[$k]) { $ad.Remove($k) } else { $ad[$k] = $Directory[$k] } }
        $doc = [ordered]@{ scenario = [ordered]@{ identity = $Identity }; identity = [ordered]@{ active_directory = $ad } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Directory {
        $global:AzlAdAdds = [System.Collections.Generic.List[object]]::new()
        $global:AzlAdFilters = [System.Collections.Generic.List[string]]::new()
        $global:AzlAdCurrent = @()          # distinguished names that are in the group already
        $global:AzlAdMissingGroup = $false
        $global:AzlAdMissingAccount = @()   # account names the directory does not know
        $global:AzlAdAmbiguous = @()
    }
    function Invoke-Memberships([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Member'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Set-ADGroupMemberships.ps1' {
    AfterAll { Remove-Variable -Name AzlAdAdds, AzlAdFilters, AzlAdCurrent, AzlAdMissingGroup, AzlAdMissingAccount, AzlAdAmbiguous -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-Directory
        Mock Get-ADGroup {
            if ($global:AzlAdMissingGroup) { throw 'Cannot find an object with identity: ''x'' under: ''DC=improbability,DC=cloud''.' }
            [pscustomobject]@{ Name = $Identity; DistinguishedName = "CN=$Identity,OU=Groups,DC=improbability,DC=cloud" }
        }
        Mock Get-ADGroupMember { @($global:AzlAdCurrent | ForEach-Object { [pscustomobject]@{ DistinguishedName = $_ } }) }
        Mock Get-ADObject {
            $global:AzlAdFilters.Add($LDAPFilter)
            $account = if ($LDAPFilter -match '=(?<v>[^)]+)\)') { $Matches['v'] } else { '' }
            if ($global:AzlAdMissingAccount -contains $account) { return @() }
            if ($global:AzlAdAmbiguous -contains $account) { return @([pscustomobject]@{ DistinguishedName = "CN=$account,OU=A,DC=x" }, [pscustomobject]@{ DistinguishedName = "CN=$account,OU=B,DC=x" }) }
            [pscustomobject]@{ DistinguishedName = "CN=$account,OU=Users,DC=improbability,DC=cloud" }
        }
        Mock Add-ADGroupMember { $global:AzlAdAdds.Add([pscustomobject]@{ Group = $Identity.Name; Members = $Members; Server = $Server; Credential = $Credential }) }
    }

    Context 'adding members' {
        It 'adds each member that is not in the group yet, in the domain of domain_fqdn' {
            $r = Invoke-Memberships (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -EQ 'Added').Count | Should -Be 2
            $global:AzlAdAdds.Count | Should -Be 2
            $global:AzlAdAdds[0].Group | Should -Be 'sg-iic-azl-01-admins'
            $global:AzlAdAdds[0].Members | Should -Be 'CN=iic-admin-01,OU=Users,DC=improbability,DC=cloud'
            $global:AzlAdAdds[0].Server | Should -Be 'improbability.cloud'
            Should -Invoke Get-ADGroup -Times 1 -Exactly -ParameterFilter { $Server -eq 'improbability.cloud' }
        }

        It 'looks a name up by sAMAccountName and a name@domain by user principal name' {
            $null = Invoke-Memberships (New-InfraFile)
            $global:AzlAdFilters | Should -Contain '(sAMAccountName=iic-admin-01)'
            $global:AzlAdFilters | Should -Contain '(userPrincipalName=iic-admin-02@improbability.cloud)'
        }

        It 'escapes the characters of an LDAP filter and looks up a computer account' {
            $null = Invoke-Memberships (New-InfraFile -Groups @([ordered]@{ name = 'sg-iic-azl-01-admins'; members = @('iic-node01$') }))
            $global:AzlAdFilters | Should -Contain '(sAMAccountName=iic-node01$)'
            $global:AzlAdAdds[0].Members | Should -Be 'CN=iic-node01$,OU=Users,DC=improbability,DC=cloud'
        }

        It 'passes -Credential to every call when it is given' {
            $cred = [pscredential]::new('user', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force))
            $null = Invoke-Memberships (New-InfraFile) -Extra @{ Credential = $cred }
            $global:AzlAdAdds[0].Credential.UserName | Should -Be 'user'
            Should -Invoke Get-ADGroup -Times 1 -Exactly -ParameterFilter { $Credential.UserName -eq 'user' }
        }

        It 'does not add the same member twice when the file lists it twice, and skips a group with no members' {
            $groups = @([ordered]@{ name = 'sg-iic-azl-01-admins'; members = @('iic-admin-01', 'IIC-ADMIN-01') }, [ordered]@{ name = 'sg-iic-azl-01-readers' })
            $r = Invoke-Memberships (New-InfraFile -Groups $groups)
            $global:AzlAdAdds.Count | Should -Be 1
            Should -Invoke Get-ADGroup -Times 1 -Exactly
        }

        It 'never removes a member, creates or deletes a group or an account' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-AD|New-AD|Set-AD|Disable-AD|Move-AD'
        }
    }

    Context 'a member is in the group already (idempotent)' {
        It 'adds nothing and reports it' {
            $global:AzlAdCurrent = @('CN=iic-admin-01,OU=Users,DC=improbability,DC=cloud', 'CN=iic-admin-02@improbability.cloud,OU=Users,DC=improbability,DC=cloud')
            $r = Invoke-Memberships (New-InfraFile)
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'AlreadyMember').Count | Should -Be 2
            $global:AzlAdAdds.Count | Should -Be 0
        }

        It 'adds only the member that is missing' {
            $global:AzlAdCurrent = @('CN=iic-admin-01,OU=Users,DC=improbability,DC=cloud')
            $null = Invoke-Memberships (New-InfraFile)
            $global:AzlAdAdds.Count | Should -Be 1
            $global:AzlAdAdds[0].Members | Should -Match 'iic-admin-02'
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans the additions and changes nothing' {
            $r = Invoke-Memberships (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'WouldAdd').Count | Should -Be 2
            $global:AzlAdAdds.Count | Should -Be 0
        }

        It 'does nothing and contacts no domain when no group lists a member' {
            $r = Invoke-Memberships (New-InfraFile -Groups @([ordered]@{ name = 'sg-iic-azl-01-admins' }))
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-ADGroup -Times 0 -Exactly
        }

        It 'does nothing for a local identity instance, which has no Active Directory' {
            $r = Invoke-Memberships (New-InfraFile -Identity 'local_identity')
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'no Active Directory'
            Should -Invoke Get-ADGroup -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent anywhere)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a missing domain_fqdn'; Args2 = @{ Directory = @{ domain_fqdn = $null } } }
            @{ Why = 'a group with no name'; Args2 = @{ Groups = @([ordered]@{ members = @('iic-admin-01') }) } }
            @{ Why = 'a group listed twice'; Args2 = @{ Groups = @([ordered]@{ name = 'sg-a'; members = @('iic-admin-01') }, [ordered]@{ name = 'SG-A'; members = @('iic-admin-02') }) } }
            @{ Why = 'a member that is not a name'; Args2 = @{ Groups = @([ordered]@{ name = 'sg-a'; members = @(@{ x = 1 }) }) } }
        ) {
            $r = Invoke-Memberships (New-InfraFile @Args2)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-ADGroup -Times 0 -Exactly
        }

        It 'refuses the member name <Name>' -ForEach $script:BadNames {
            $r = Invoke-Memberships (New-InfraFile -Groups @([ordered]@{ name = 'sg-a'; members = @($Name) }))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'is not an account name'
            Should -Invoke Add-ADGroupMember -Times 0 -Exactly
        }
    }

    Context 'the directory (exit 1)' {
        It 'reports a group that does not exist, and adds nothing to it' {
            $global:AzlAdMissingGroup = $true
            $r = Invoke-Memberships (New-InfraFile)
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed').Count | Should -Be 2
            $r.Rows[0].Detail | Should -Match 'does not exist'
            $global:AzlAdAdds.Count | Should -Be 0
        }

        It 'reports a member that is not found and still adds the others' {
            $global:AzlAdMissingAccount = @('iic-admin-01')
            $r = Invoke-Memberships (New-InfraFile)
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Member -EQ 'iic-admin-01').Action | Should -Be 'Failed'
            ($r.Rows | Where-Object Member -EQ 'iic-admin-01').Detail | Should -Match 'No account'
            $global:AzlAdAdds.Count | Should -Be 1
        }

        It 'refuses to guess when two objects match one name' {
            $global:AzlAdAmbiguous = @('iic-admin-01')
            $r = Invoke-Memberships (New-InfraFile)
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Member -EQ 'iic-admin-01').Detail | Should -Match 'More than one object'
        }

        It 'reports a failed addition and goes on' {
            Mock Add-ADGroupMember { if ($Members -match 'iic-admin-01') { throw 'Insufficient access rights.' } else { $global:AzlAdAdds.Add([pscustomobject]@{ Group = 'x'; Members = $Members; Server = $Server; Credential = $Credential }) } }
            $r = Invoke-Memberships (New-InfraFile)
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Member -EQ 'iic-admin-01').Action | Should -Be 'Failed'
            ($r.Rows | Where-Object Member -Like 'iic-admin-02*').Action | Should -Be 'Added'
        }

        It 'stops when the ActiveDirectory cmdlets are not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Add-ADGroupMember' }
            $r = Invoke-Memberships (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'ActiveDirectory module'
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, never the old layout, and holds no group name of its own' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'GRP-|ConfigFile|logging\.ps1|config-loader|DomainController'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Set_ADGroupMemberships_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'scenario.identity', 'identity.active_directory.domain_fqdn', 'identity.active_directory.security_groups[].name', 'identity.active_directory.security_groups[].members' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
