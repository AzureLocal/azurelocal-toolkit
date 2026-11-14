#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The six task scripts of automation / 01-cicd-infra take -InfrastructureFile (mandatory) and nothing else for the file. These tests run each script
# in this process with the module's native and REST calls replaced: no network, no sign-in, nothing changes anywhere.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/cicd-infra/CicdScripts.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks with -ModuleName run in the module scope, so the call recorder is shared through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers.')]
param()

BeforeDiscovery {
    $root = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'scripts\deploy\01-cicd-infra\phase-01-cicd-setup'
    $script:Cases = @(
        @{ Task = 'task-01-bootstrap'; File = 'New-CicdBootstrap.ps1' }
        @{ Task = 'task-02-create-project'; File = 'New-CicdProject.ps1' }
        @{ Task = 'task-03-configure-project'; File = 'Set-CicdProjectConfiguration.ps1' }
        @{ Task = 'task-04-create-environments'; File = 'New-CicdEnvironments.ps1' }
        @{ Task = 'task-05-configure-variables'; File = 'Set-CicdVariables.ps1' }
        @{ Task = 'task-06-deploy-runners'; File = 'Deploy-CicdRunners.ps1' }
    ) | ForEach-Object { $_.Path = Join-Path $root (Join-Path $_.Task (Join-Path 'powershell' $_.File)); $_ }
}

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Import-Module (Join-Path $script:Repo 'scripts\common\cicd-infra\AzlCicdInfra.psm1') -Force
    Import-Module powershell-yaml
    $script:Example = Join-Path $script:Repo 'config\variables\examples\infrastructure.example.yml'
    $script:Setup = Join-Path $script:Repo 'scripts\deploy\01-cicd-infra\phase-01-cicd-setup'

    # The example without the Key Vault token: the scripts then sign in with the CLI and no vault is read.
    function New-InfraFile([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        $doc.devops.Remove('api_token')
        if ($Change) { & $Change $doc }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-TaskScript([string]$Path, [hashtable]$Arguments) {
        $global:LASTEXITCODE = $null
        $log = Join-Path $TestDrive "log-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
        $all = & $Path @Arguments -LogPath $log 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    $env:GH_TOKEN = $null; $env:GITLAB_TOKEN = $null; $env:AZURE_DEVOPS_EXT_PAT = $null; $env:GITHUB_TOKEN = $null; $env:GITLAB_PRIVATE_TOKEN = $null
}

AfterAll {
    Remove-Variable -Name AzlScriptCalls -Scope Global -ErrorAction SilentlyContinue
}

Describe 'The task scripts end with exit code 2 when the file cannot be used' {
    It '<File> ends with 2 and calls nothing when the named file is not there' -ForEach $script:Cases {
        $global:AzlScriptCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative { $global:AzlScriptCalls.Add("$FilePath $($ArgumentList -join ' ')"); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName AzlCicdInfra Invoke-AzlRest { $global:AzlScriptCalls.Add("$Method $Uri"); $null }
        $r = Invoke-TaskScript $Path @{ InfrastructureFile = (Join-Path $TestDrive 'no-such-file.yml') }
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $r.Text | Should -Match 'infrastructure file cannot be used'
        $global:AzlScriptCalls.Count | Should -Be 0
    }

    It '<File> ends with 2 when the file has no devops section' -ForEach $script:Cases {
        $global:AzlScriptCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative { $global:AzlScriptCalls.Add("$FilePath $($ArgumentList -join ' ')"); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        $file = New-InfraFile { param($d) $d.Remove('devops') }
        $r = Invoke-TaskScript $Path @{ InfrastructureFile = $file }
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $global:AzlScriptCalls.Count | Should -Be 0
    }
}

Describe 'The task scripts plan with -WhatIf and change nothing' {
    BeforeAll {
        $global:AzlScriptCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative {
            $global:AzlScriptCalls.Add("$FilePath $($ArgumentList -join ' ')")
            $line = $ArgumentList -join ' '
            $out = switch -Regex ($line) {
                '^ad app list' { '[]' }
                '^feature show' { 'NotRegistered' }
                '^role assignment list' { '[]' }
                'federated-credential list' { '[]' }
                '^plan' { 'Plan: 3 to add, 0 to change, 0 to destroy.' }
                default { '' }
            }
            [pscustomobject]@{ ExitCode = $(if ($line -match '^ad sp show') { 1 } else { 0 }); Output = $out }
        }
        Mock -ModuleName AzlCicdInfra Invoke-AzlRest { $global:AzlScriptCalls.Add("$Method $Uri"); $null }
        $script:Key = Join-Path $TestDrive 'k.pub'
        Set-Content -LiteralPath $script:Key -Value 'ssh-ed25519 AAAA test'
    }

    It 'task 01 plans the bootstrap and creates nothing' {
        $global:AzlScriptCalls.Clear()
        $path = Join-Path $script:Setup 'task-01-bootstrap\powershell\New-CicdBootstrap.ps1'
        $r = Invoke-TaskScript $path @{ InfrastructureFile = (New-InfraFile); WhatIf = $true }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlScriptCalls | Where-Object { $_ -match ' (create|reset|register|set|add|admin-consent)( |$)' }).Count | Should -Be 0
    }

    It 'task 06 plans the runners without an apply' {
        $global:AzlScriptCalls.Clear()
        $path = Join-Path $script:Setup 'task-06-deploy-runners\powershell\Deploy-CicdRunners.ps1'
        $r = Invoke-TaskScript $path @{ InfrastructureFile = (New-InfraFile); AdminSshPublicKeyPath = $script:Key; WorkingDirectory = (Join-Path $TestDrive 'work'); WhatIf = $true; Apply = $true }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlScriptCalls | Where-Object { $_ -match '^terraform apply' }).Count | Should -Be 0
    }
}
