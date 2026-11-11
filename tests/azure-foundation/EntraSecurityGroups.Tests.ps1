#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 03 (RBAC and permissions), task 02: New-EntraSecurityGroups.ps1 creates the Microsoft Entra security groups that identity.entra.groups lists.
# Every Microsoft Graph cmdlet is mocked: no tenant, no sign-in is used. The tenant id is generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/EntraSecurityGroups.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant id.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Graph cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-03-rbac-permissions', 'task-02-assign-rbac-roles', 'powershell', 'New-EntraSecurityGroups.ps1')
    Import-Module powershell-yaml

    # Stubs with the Microsoft Graph signatures the script uses, so the mocks work whether or not the Graph modules are installed.
    function Get-MgContext { [CmdletBinding()] param() }
    function Get-MgGroup { [CmdletBinding()] param([string]$Filter) }
    function New-MgGroup {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$DisplayName, [string]$Description, [string]$MailNickname, [switch]$SecurityEnabled, [switch]$MailEnabled)
    }

    $global:AzlGroupTestTenant = [guid]::NewGuid().ToString()

    function New-InfraFile([object[]]$Groups, [object]$TenantId = $global:AzlGroupTestTenant) {
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $Groups) { $doc.identity = [ordered]@{ entra = [ordered]@{ groups = @($Groups) } } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Group([string]$Name, [string]$Purpose) {
        $g = [ordered]@{ name = $Name; roles = @('Reader') }
        if ($Purpose) { $g.purpose = $Purpose }
        $g
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-GroupRun([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['Groups'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'New-EntraSecurityGroups.ps1' {
    AfterAll {
        Remove-Variable -Name AzlGroupTestTenant -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-MgContext { [pscustomobject]@{ TenantId = $global:AzlGroupTestTenant; Scopes = @('Group.ReadWrite.All') } }
        Mock Get-MgGroup { @() }
        Mock New-MgGroup { [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); DisplayName = $DisplayName } }
    }

    Context 'creating groups (happy path)' {
        It 'creates each group the file lists, as a security group that is not mail enabled' {
            $file = New-InfraFile @((New-Group 'grp-azl-operators' 'Operate the instance'), (New-Group 'grp-azl-readers' 'Read the instance'))
            $r = Invoke-GroupRun $file
            $r.ExitCode | Should -Be 0
            $r.Result.Created | Should -Be 2
            $r.Result.Failed | Should -Be 0
            Should -Invoke New-MgGroup -Times 2 -Exactly
            Should -Invoke New-MgGroup -Times 1 -Exactly -ParameterFilter { $DisplayName -eq 'grp-azl-operators' -and $SecurityEnabled -and -not $MailEnabled -and $Description -eq 'Operate the instance' }
            Should -Invoke New-MgGroup -Times 1 -Exactly -ParameterFilter { $DisplayName -eq 'grp-azl-readers' -and $SecurityEnabled -and -not $MailEnabled }
            $r.Text | Should -Match 'created'
        }

        It 'returns the object id of each created group' {
            $r = Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')))
            $r.Result.Groups[0].Id | Should -Match '^[0-9a-f]{8}-'
        }

        It 'gives a group with no purpose a plain description' {
            $null = Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')))
            Should -Invoke New-MgGroup -Times 1 -Exactly -ParameterFilter { $Description -eq 'Azure Local security group' }
        }

        It 'builds a mail nickname Graph accepts from a name with spaces and symbols' {
            $null = Invoke-GroupRun (New-InfraFile @(, (New-Group 'Azure Local (Ops) @ site' '')))
            Should -Invoke New-MgGroup -Times 1 -Exactly -ParameterFilter { $MailNickname -eq 'AzureLocalOpssite' }
        }

        It 'builds a mail nickname for a name made only of symbols, and keeps one under 64 characters for a long name' {
            $null = Invoke-GroupRun (New-InfraFile @((New-Group '###' ''), (New-Group ('a' * 100) '')))
            Should -Invoke New-MgGroup -Times 1 -Exactly -ParameterFilter { $MailNickname -match '^group[0-9A-F]{8}$' }
            Should -Invoke New-MgGroup -Times 1 -Exactly -ParameterFilter { $MailNickname.Length -eq 64 }
        }

        It 'doubles a single quote in the name when it looks the group up' {
            $null = Invoke-GroupRun (New-InfraFile @(, (New-Group "o'brien-ops" '')))
            Should -Invoke Get-MgGroup -Times 1 -Exactly -ParameterFilter { $Filter -eq "displayName eq 'o''brien-ops'" }
        }

        It 'accepts a sign-in with a Directory scope or the Group.Create scope' {
            Mock Get-MgContext { [pscustomobject]@{ TenantId = $global:AzlGroupTestTenant; Scopes = @('Group.Create', 'User.Read') } }
            (Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')))).ExitCode | Should -Be 0
        }

        It 'accepts an app-only sign-in, which has no delegated scopes' {
            Mock Get-MgContext { [pscustomobject]@{ TenantId = $global:AzlGroupTestTenant; Scopes = @() } }
            (Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')))).ExitCode | Should -Be 0
        }
    }

    Context 'the group already exists (idempotent)' {
        It 'creates nothing and says so' {
            Mock Get-MgGroup { [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111'; DisplayName = 'x' } }
            $r = Invoke-GroupRun (New-InfraFile @((New-Group 'grp-azl-operators' ''), (New-Group 'grp-azl-readers' '')))
            $r.ExitCode | Should -Be 0
            $r.Result.Created | Should -Be 0
            $r.Result.AlreadyExists | Should -Be 2
            Should -Invoke New-MgGroup -Times 0 -Exactly
            $r.Text | Should -Match 'Nothing to do'
            $r.Result.Groups[0].Id | Should -Be '11111111-1111-1111-1111-111111111111'
        }

        It 'a mixed file creates only the group that is missing' {
            Mock Get-MgGroup { if ($Filter -match 'grp-azl-operators') { [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222' } } }
            $r = Invoke-GroupRun (New-InfraFile @((New-Group 'grp-azl-operators' ''), (New-Group 'grp-azl-readers' '')))
            $r.ExitCode | Should -Be 0
            $r.Result.Created | Should -Be 1
            $r.Result.AlreadyExists | Should -Be 1
            Should -Invoke New-MgGroup -Times 1 -Exactly -ParameterFilter { $DisplayName -eq 'grp-azl-readers' }
        }

        It 'leaves a name that two groups already have, reports a conflict and exits 1' {
            Mock Get-MgGroup { @([pscustomobject]@{ Id = [guid]::NewGuid().ToString() }, [pscustomobject]@{ Id = [guid]::NewGuid().ToString() }) }
            $r = Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')))
            $r.ExitCode | Should -Be 1
            $r.Result.Conflict | Should -Be 1
            $r.Text | Should -Match 'already have this display name'
            Should -Invoke New-MgGroup -Times 0 -Exactly
        }
    }

    Context '-WhatIf' {
        It 'plans the groups and creates none' {
            $r = Invoke-GroupRun (New-InfraFile @((New-Group 'grp-azl-operators' ''), (New-Group 'grp-azl-readers' ''))) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Planned | Should -Be 2
            $r.Result.Created | Should -Be 0
            Should -Invoke New-MgGroup -Times 0 -Exactly
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'groups.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile @(, (New-Group 'grp-azl-operators' ''))) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
            Should -Invoke New-MgGroup -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Graph)' {
        It 'refuses a file without identity.entra.groups' {
            $r = Invoke-GroupRun (New-InfraFile $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'identity.entra.groups is empty'
            Should -Invoke New-MgGroup -Times 0 -Exactly
            Should -Invoke Get-MgContext -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')) -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses a group with no name' {
            $r = Invoke-GroupRun (New-InfraFile @(, ([ordered]@{ purpose = 'no name' })))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'has no name'
        }

        It 'refuses a name longer than 256 characters' {
            $r = Invoke-GroupRun (New-InfraFile @(, (New-Group ('g' * 257) '')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match '256 characters'
        }

        It 'refuses a purpose longer than 1024 characters' {
            $r = Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' ('p' * 1025))))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match '1024 characters'
        }

        It 'refuses the same name twice, whatever the case' {
            $r = Invoke-GroupRun (New-InfraFile @((New-Group 'grp-azl-operators' ''), (New-Group 'GRP-AZL-Operators' '')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'more than once'
            Should -Invoke New-MgGroup -Times 0 -Exactly
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-GroupRun (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-MgContext { $null }
            $r = Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-MgGroup -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-MgContext { [pscustomobject]@{ TenantId = [guid]::NewGuid().ToString(); Scopes = @('Group.ReadWrite.All') } }
            $r = Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-MgGroup -Times 0 -Exactly
        }

        It 'stops when the sign-in has no scope that lets it create groups' {
            Mock Get-MgContext { [pscustomobject]@{ TenantId = $global:AzlGroupTestTenant; Scopes = @('User.Read', 'Group.Read.All') } }
            $r = Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'none of which lets it create groups'
            Should -Invoke New-MgGroup -Times 0 -Exactly
        }

        It 'reports a failed creation, still creates the others, and exits 1' {
            Mock New-MgGroup { if ($DisplayName -eq 'grp-azl-operators') { throw 'Insufficient privileges to complete the operation.' } else { [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-GroupRun (New-InfraFile @((New-Group 'grp-azl-operators' ''), (New-Group 'grp-azl-readers' '')))
            $r.ExitCode | Should -Be 1
            $r.Result.Created | Should -Be 1
            $r.Result.Failed | Should -Be 1
            ($r.Result.Groups | Where-Object Action -EQ 'Failed').Detail | Should -Match 'Insufficient privileges'
        }

        It 'reports a lookup error and creates nothing for that group' {
            Mock Get-MgGroup { throw 'Authorization_RequestDenied' }
            $r = Invoke-GroupRun (New-InfraFile @(, (New-Group 'grp-azl-operators' '')))
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 1
            Should -Invoke New-MgGroup -Times 0 -Exactly
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, never variables.yml, and holds no GUID or address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_EntraSecurityGroups_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: azure.tenant_id and identity.entra.groups[] name, purpose' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'identity.entra.groups[].name', 'identity.entra.groups[].purpose') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
        }
    }
}
