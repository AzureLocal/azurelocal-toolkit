#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Invoke-DjLdapSearch as the pre-cluster verification uses it: exported, the optional Scope and SecurityMasks members of the request, entries with Properties.
# No domain controller is touched: the only server tried is 127.0.0.1 on a port nothing listens on.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/DomainJoinLdapSearch.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration', 'AzlDomainJoin.psm1')) -Force
    $script:Request = {
        param([hashtable]$Extra = @{})
        $secure = ConvertTo-SecureString -String 'not-a-real-password' -AsPlainText -Force
        $base = @{ Servers = @('127.0.0.1'); Port = 1; TimeoutSeconds = 2; SearchRoot = 'DC=lab,DC=example'; Filter = '(objectClass=*)'; Properties = @('distinguishedname'); Credential = [pscredential]::new('lab\tester', $secure) }
        foreach ($k in $Extra.Keys) { $base[$k] = $Extra[$k] }
        [pscustomobject]$base
    }
}

Describe 'Invoke-DjLdapSearch' {
    It 'is exported, so the verification modules can call it' {
        (Get-Command -Module AzlDomainJoin -Name Invoke-DjLdapSearch -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It 'reports Reachable false, with the reason and without the password, when no domain controller answers' {
        $r = Invoke-DjLdapSearch -Request (& $script:Request)
        $r.Reachable | Should -BeFalse
        $r.Entries.Count | Should -Be 0
        $r.AuthFailed | Should -BeFalse
        $r.Error | Should -Match 'answered on TCP 1|needs System.DirectoryServices'
        $r.Error | Should -Not -Match 'not-a-real-password'
    }
    It 'accepts a request with Scope and SecurityMasks without failing' {
        $r = Invoke-DjLdapSearch -Request (& $script:Request @{ Scope = 'Base'; SecurityMasks = 'Dacl'; Properties = @('ntsecuritydescriptor', 'objectsid') })
        $r.Reachable | Should -BeFalse
        $r.Error | Should -Not -BeNullOrEmpty
    }
}
