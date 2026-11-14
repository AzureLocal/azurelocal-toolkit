#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# identity.active_directory.security_groups is the list-of-groups form (name, purpose, members, local_groups). The 4.0 object-by-role
# form is security_groups_by_role (deprecated). The Ansible AD preparation role and the phase-06 task read the canonical form.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeAll {
    $script:Repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:Task = Join-Path $script:Repo 'scripts\deploy\04-cluster-deployment\phase-06-post-deployment\task-03-security-groups-applied-to-nodes\powershell\Invoke-ApplySecurityGroups-Orchestrated.ps1'
}

Describe 'security_groups, the canonical list form' {
    It 'the Ansible group_vars use name, purpose and local_groups, all registry variables' {
        $vars = ConvertFrom-Yaml (Get-Content (Join-Path $script:Repo 'src\ansible\inventory\group_vars\all.yml') -Raw)
        $vars.security_groups.Count | Should -BeGreaterThan 0
        $allowed = 'name', 'purpose', 'members', 'local_groups'
        foreach ($g in $vars.security_groups) {
            $g.name | Should -Not -BeNullOrEmpty
            $g.Keys | Where-Object { $allowed -notcontains $_ } | Should -BeNullOrEmpty -Because 'the 4.0 "scope" key is gone'
        }
        $vars.security_groups[0].local_groups | Should -Contain 'Administrators'
    }

    It 'the AD preparation role reads purpose, not scope' {
        $role = Get-Content (Join-Path $script:Repo 'src\ansible\roles\ad-preparation\tasks\main.yml') -Raw
        $role | Should -Match 'item\.purpose'
        $role | Should -Not -Match 'item\.scope'
    }

    It 'the registry has the canonical list and keeps the 4.0 form as a deprecated alias' {
        Import-Module (Join-Path $script:Repo 'config\variables\scripts\VariableRegistry.psm1') -Force
        $reg = @(Get-RegistryVariable -Path (Join-Path $script:Repo 'config\variables\schema\master-registry.yaml'))
        $paths = $reg.Path
        $paths | Should -Contain 'identity.active_directory.security_groups[].local_groups'
        $paths | Should -Contain 'identity.active_directory.security_groups_by_role'
        ($reg | Where-Object Path -eq 'identity.active_directory.security_groups_by_role').Deprecated | Should -BeTrue
    }

    It 'the phase-06 task builds its assignments from the list (WhatIf, nothing remote)' {
        $cfg = Join-Path $TestDrive 'infra.yml'
        @'
identity:
  active_directory:
    netbios_name: IIC
    security_groups:
      - name: sg-admins
        local_groups: [Administrators]
      - name: sg-wac
        local_groups: []
      - name: sg-none
nodes:
  - name: n1
    management:
      ip_address: 192.0.2.11
'@ | Set-Content $cfg
        $out = & pwsh -NoProfile -File $script:Task -InfrastructureFile $cfg -WhatIf -LogPath (Join-Path $TestDrive 'sg.log') 2>&1 | Out-String
        $out | Should -Match ([regex]::Escape('Will assign: IIC\sg-admins'))
        $out | Should -Match "Skipping 'sg-wac'"
        $out | Should -Match "Skipping 'sg-none'"
        $out | Should -Match 'WhatIf complete'
    }

    It 'stops with exit code 2, before any remote call, when the file has no LCM user name and no -Credential is passed' {
        $cfg = Join-Path $TestDrive 'infra-nouser.yml'
        @'
identity:
  active_directory:
    netbios_name: IIC
    security_groups:
      - name: sg-admins
        local_groups: [Administrators]
nodes:
  - name: n1
    management:
      ip_address: 192.0.2.11
'@ | Set-Content $cfg
        $out = & pwsh -NoProfile -File $script:Task -InfrastructureFile $cfg -LogPath (Join-Path $TestDrive 'sg2.log') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'lcm_user\.username'
        $out | Should -Not -Match 'Credentials resolved'
    }
}
