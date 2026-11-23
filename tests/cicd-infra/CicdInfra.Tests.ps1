#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for tasks 01 to 06 of automation / 01-cicd-infra: scripts/common/cicd-infra/AzlCicdInfra.psm1 and the task scripts.
# Every native command and REST call is replaced: no network, no sign-in, nothing changes anywhere.
# Run: Invoke-Pester ./tests/cicd-infra

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks with -ModuleName run in the module scope, so the call recorder is shared through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Every responder script block receives the same (file, arguments) pair.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers.')]
param()
BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Import-Module (Join-Path $script:Repo 'scripts\common\cicd-infra\AzlCicdInfra.psm1') -Force
    Import-Module powershell-yaml
    $script:Example = Join-Path $script:Repo 'config\variables\examples\infrastructure.example.yml'
    $script:TaskRoot = Join-Path $script:Repo 'scripts\deploy\01-cicd-infra\phase-01-cicd-setup'

    function Get-Settings([string]$Platform = '', [scriptblock]$Change, [switch]$KeepApiToken) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        # The example names a Key Vault token; the tests sign in with the CLI instead, so no Key Vault read happens.
        if (-not $KeepApiToken) { $doc.devops.Remove('api_token') }
        if ($Change) { & $Change $doc }
        return ConvertTo-AzlCicdSetting -Infrastructure $doc -Platform $Platform
    }

    # A recorder for the mocks: every call is kept, a responder answers it.
    function Start-Recording([scriptblock]$Responder) {
        $global:AzlCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlResponder = $Responder
    }
    function Get-Calls([string]$Pattern) { @($global:AzlCalls | Where-Object { $_.Line -match $Pattern }) }
    function New-Out([string]$Output = '', [int]$ExitCode = 0) { [pscustomobject]@{ ExitCode = $ExitCode; Output = $Output } }

    $env:GH_TOKEN = $null; $env:GITLAB_TOKEN = $null; $env:AZURE_DEVOPS_EXT_PAT = $null; $env:GITHUB_TOKEN = $null; $env:GITLAB_PRIVATE_TOKEN = $null
}

AfterAll {
    Remove-Variable -Name AzlCalls, AzlResponder -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Settings' {
    It 'reads the example: platform, URLs, runners, environments' {
        $s = Get-Settings
        $s.Platform | Should -Be 'github'
        $s.ScmUrl | Should -Be 'https://github.com/improbability-cloud'
        $s.Repository.Name | Should -Be 'iic-azurelocal'
        $s.Runners.Count | Should -Be 2
        @($s.Runners | Where-Object Purpose -eq 'ztp').Count | Should -Be 1
        ($s.Environments.Name) | Should -Contain 'ztp-reinstall'
        $s.Authentication.Method | Should -Be 'oidc'
    }
    It 'builds the Azure DevOps and GitLab URLs' {
        (Get-Settings 'azure_devops').ScmUrl | Should -Be 'https://github.com/improbability-cloud'
        (Get-Settings 'gitlab' { param($d) $d.devops.url = 'https://gitlab.example.com/' }).ScmUrl | Should -Be 'https://gitlab.example.com'
    }
    It 'refuses a file without a devops section' {
        { ConvertTo-AzlCicdSetting -Infrastructure ([ordered]@{ azure = @{} }) } | Should -Throw '*no devops section*'
    }
    It 'needs the infrastructure file: no default path, no environment variable, no CONFIGURATION region' {
        foreach ($name in 'Resolve-AzlCicdInput', 'Get-AzlCicdSetting') {
            $c = Get-Command -Module AzlCicdInfra -Name $name
            $c.Parameters['InfrastructureFile'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -BeTrue
            $c.Parameters.Keys | Should -Not -Contain 'Configuration'
        }
        $text = Get-Content -LiteralPath (Join-Path $script:Repo 'scripts\common\cicd-infra\AzlCicdInfra.psm1') -Raw
        # AZL_INFRASTRUCTURE_FILE is a pipeline variable task 05 sets (devops.pipelines.infrastructure_file); the module never reads it as a fallback.
        $text | Should -Not -Match '\$env:AZL_INFRASTRUCTURE_FILE|GetEnvironmentVariable\(.AZL_INFRASTRUCTURE_FILE|CONFIGURATION region|\./infrastructure\.yml'
    }
    It 'reads the file the caller names' {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        $doc.devops.Remove('api_token')
        $file = Join-Path $TestDrive 'settings-infra.yml'
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        (Resolve-AzlCicdInput -InfrastructureFile $file).Platform | Should -Be 'github'
    }
    It 'stops when the named file is not there' {
        { Resolve-AzlCicdInput -InfrastructureFile (Join-Path $TestDrive 'no-such-file.yml') } | Should -Throw
    }
}

Describe 'Task 06: Terraform variables from infrastructure.yml' {
    BeforeAll {
        $script:Declared = Select-String -Path (Join-Path $script:Repo 'src\terraform\environments\cicd-infra\variables.tf') -Pattern '^variable "(\w+)"' | ForEach-Object { $_.Matches.Groups[1].Value }
    }
    It 'produces only variables the environment declares' {
        $v = ConvertTo-AzlRunnerTerraformVariable -Settings (Get-Settings) -AdminSshPublicKey 'ssh-ed25519 AAAA test'
        @($v.Keys | Where-Object { $_ -notin $script:Declared }) | Should -BeNullOrEmpty
    }
    It 'maps the runners, the hub peering and the least-privilege scopes' {
        $v = ConvertTo-AzlRunnerTerraformVariable -Settings (Get-Settings) -AdminSshPublicKey 'ssh-ed25519 AAAA test'
        $v.linux_runner.enabled | Should -BeTrue
        $v.ztp_runner.enabled | Should -BeTrue
        $v.ztp_runner.data_disk_size_gb | Should -Be 512
        $v.linux_subnet.address_prefix | Should -Be '10.20.10.0/26'
        $v.hub_peering.hub_vnet_id | Should -Match '/virtualNetworks/vnet-iic-hub-01$'
        $v.bmc_cidrs | Should -Contain '198.51.100.0/24'
        $v.registration_secret.secret_name | Should -Be 'github-runner-token'
        $v.registration_secret.key_vault_id | Should -Match '/vaults/kv-iic-mgmt-01$'
        @($v.contributor_scopes).Count | Should -Be 1
        $v.contributor_scopes[0] | Should -Match '/resourceGroups/rg-iic-azl-01$'
    }
    It 'keeps single-item lists as lists in the JSON' {
        $v = ConvertTo-AzlRunnerTerraformVariable -Settings (Get-Settings) -AdminSshPublicKey 'k'
        $json = $v | ConvertTo-Json -Depth 8
        $json | Should -Match '"rbac_administrator_scopes": \['
        $json | Should -Match '"arc_machine_scopes": \['
    }
    It 'holds no token, password or key: only names, IDs and the public key' {
        $json = ConvertTo-AzlRunnerTerraformVariable -Settings (Get-Settings) -AdminSshPublicKey 'ssh-ed25519 AAAA test' | ConvertTo-Json -Depth 8
        $json | Should -Not -Match '(?i)password|ghp_|glrt-|client_secret|"token"'
    }
    It 'refuses two Linux pools' {
        $s = Get-Settings -Change { param($d) $d.devops.runners += [ordered]@{ name = 'second'; os_type = 'linux'; registration_secret = 'keyvault://kv-iic-mgmt-01/x'; subnet = @{ name = 's'; prefix = '10.20.10.128/26' } } }
        { ConvertTo-AzlRunnerTerraformVariable -Settings $s } | Should -Throw '*one Linux general pool*'
    }
    It 'refuses a registration secret in a vault that key_vaults does not list' {
        $s = Get-Settings -Change { param($d) $d.key_vaults = @() }
        { ConvertTo-AzlRunnerTerraformVariable -Settings $s } | Should -Throw "*not listed in key_vaults*"
    }
}

Describe 'Task 01: bootstrap' {
    BeforeAll {
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative {
            $global:AzlCalls.Add([pscustomobject]@{ Line = "$FilePath $($ArgumentList -join ' ')"; File = $FilePath; Args = @($ArgumentList); Input = $InputText })
            & $global:AzlResponder $FilePath @($ArgumentList)
        }
    }
    Context 'nothing exists' {
        BeforeEach {
            Start-Recording {
                param($file, $a)
                $line = $a -join ' '
                switch -Regex ($line) {
                    '^ad app list' { New-Out '[]' }
                    '^ad app create' { New-Out '11111111-1111-1111-1111-111111111111' }
                    '^ad sp show' { New-Out '' 1 }
                    '^ad sp create' { New-Out '22222222-2222-2222-2222-222222222222' }
                    'federated-credential list' { New-Out '[]' }
                    '^role assignment list' { New-Out '[]' }
                    '^feature show' { New-Out 'NotRegistered' }
                    default { New-Out '' }
                }
            }
        }
        It 'creates the app, the principal, the federated credentials, the roles and the registrations' {
            $s = Get-Settings
            $r = Invoke-AzlCicdBootstrap -Settings $s -Confirm:$false
            (Get-Calls '^az ad app create').Count | Should -Be 1
            (Get-Calls '^az ad sp create').Count | Should -Be 1
            (Get-Calls 'federated-credential create').Count | Should -Be (2 + $s.Environments.Count)
            (Get-Calls '^az role assignment create').Count | Should -Be ($s.RoleSubscriptionIds.Count * $s.Authentication.Roles.Count)
            (Get-Calls '^az feature register').Count | Should -Be $s.RoleSubscriptionIds.Count
            ($r | Where-Object Status -eq 'Created').Count | Should -BeGreaterThan 5
        }
        It 'makes no change with -WhatIf' {
            Invoke-AzlCicdBootstrap -Settings (Get-Settings) -WhatIf | Out-Null
            (Get-Calls ' (create|reset|register|set|add|admin-consent)( |$)').Count | Should -Be 0
        }
        It 'binds each federated credential to the repository, its environments and the branch' {
            $plan = Get-AzlFederatedCredentialPlan -Settings (Get-Settings)
            $plan.Subject | Should -Contain 'repo:improbability-cloud/iic-azurelocal:environment:ztp-reinstall'
            $plan.Subject | Should -Contain 'repo:improbability-cloud/iic-azurelocal:ref:refs/heads/main'
            ($plan.Issuer | Select-Object -Unique) | Should -Be 'https://token.actions.githubusercontent.com'
        }
    }
    Context 'everything exists' {
        It 'creates nothing the second time' {
            $s = Get-Settings
            $names = @(Get-AzlFederatedCredentialPlan -Settings $s | ForEach-Object Name | ConvertTo-Json -Compress -AsArray)
            $global:ExistingNames = $names[0]
            Start-Recording {
                param($file, $a)
                $line = $a -join ' '
                switch -Regex ($line) {
                    '^ad app list' { New-Out '["11111111-1111-1111-1111-111111111111"]' }
                    '^ad sp show' { New-Out '22222222-2222-2222-2222-222222222222' }
                    'federated-credential list' { New-Out $global:ExistingNames }
                    '^role assignment list' { New-Out '["Contributor","User Access Administrator"]' }
                    '^feature show' { New-Out 'Registered' }
                    default { New-Out '' }
                }
            }
            $r = Invoke-AzlCicdBootstrap -Settings $s -Confirm:$false
            (Get-Calls ' (create|reset|register|add)( |$)').Count | Should -Be 0
            ($r | Where-Object Status -eq 'Created').Count | Should -Be 0
            ($r | Where-Object Status -eq 'Exists').Count | Should -BeGreaterThan 5
        }
    }
    Context 'client secret method' {
        It 'sends the secret to Key Vault from a file, never on a command line, and does not print it' {
            # The existence check goes through the toolkit's secret resolver: the secret is not there yet.
            Mock -ModuleName AzlCicdInfra Test-AzlSecretReference { $false }
            Start-Recording {
                param($file, $a)
                $line = $a -join ' '
                switch -Regex ($line) {
                    '^ad app list' { New-Out '["11111111-1111-1111-1111-111111111111"]' }
                    '^ad sp show' { New-Out '22222222-2222-2222-2222-222222222222' }
                    'credential reset' { New-Out 'SuperSecretValue-12345' }
                    '^role assignment list' { New-Out '["Contributor","User Access Administrator"]' }
                    '^feature show' { New-Out 'Registered' }
                    default { New-Out '' }
                }
            }
            $s = Get-Settings -Change { param($d) $d.devops.authentication.method = 'client_secret'; $d.devops.authentication.client_secret = 'keyvault://kv-iic-mgmt-01/automation-spn-secret' }
            $r = Invoke-AzlCicdBootstrap -Settings $s -Confirm:$false
            (Get-Calls 'keyvault secret set').Count | Should -Be 1
            ($global:AzlCalls | Where-Object { $_.Line -match 'SuperSecretValue' -and $_.Line -notmatch 'credential reset' }).Count | Should -Be 0
            (Get-Calls 'keyvault secret set').Line | Should -Match '--file'
            ($r | Out-String) | Should -Not -Match 'SuperSecretValue'
        }
    }
}

Describe 'Task 02: project' {
    BeforeAll {
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative {
            $global:AzlCalls.Add([pscustomobject]@{ Line = "$FilePath $($ArgumentList -join ' ')"; Args = @($ArgumentList) })
            & $global:AzlResponder $FilePath @($ArgumentList)
        }
        Mock -ModuleName AzlCicdInfra Invoke-AzlRest {
            $global:AzlCalls.Add([pscustomobject]@{ Line = "REST $Method $Uri"; Body = $Body })
            & $global:AzlResponder 'REST' @($Method, $Uri)
        }
    }
    It 'GitHub: creates the private repository from the template' {
        Start-Recording { param($f, $a) if ($a -join ' ' -match '^repo view') { New-Out '' 1 } else { New-Out '' } }
        $r = New-AzlCicdProject -Settings (Get-Settings) -Confirm:$false
        $create = Get-Calls '^gh repo create'
        $create.Count | Should -Be 1
        $create.Line | Should -Match 'improbability-cloud/iic-azurelocal --private --template AzureLocal/azurelocal-template'
        $r.Status | Should -Be 'Created'
    }
    It 'GitHub: leaves an existing repository alone' {
        Start-Recording { param($f, $a) New-Out '{"name":"x"}' }
        $r = New-AzlCicdProject -Settings (Get-Settings) -Confirm:$false
        (Get-Calls '^gh repo create').Count | Should -Be 0
        $r.Status | Should -Be 'Exists'
    }
    It 'GitHub: -WhatIf creates nothing' {
        Start-Recording { param($f, $a) New-Out '' 1 }
        $r = New-AzlCicdProject -Settings (Get-Settings) -WhatIf
        (Get-Calls '^gh repo create').Count | Should -Be 0
        $r.Status | Should -Be 'Planned'
    }
    It 'GitLab: needs a token, then creates the project in the group from the template project' {
        { New-AzlCicdProject -Settings (Get-Settings 'gitlab') -Confirm:$false } | Should -Throw '*GitLab needs a token*'
        $env:GITLAB_TOKEN = 'glpat-test-value'
        try {
            Start-Recording {
                param($f, $a)
                $u = $a[1]
                if ($a[0] -eq 'GET' -and $u -match 'namespaces') { return @([pscustomobject]@{ id = 7; full_path = 'improbability-cloud' }) }
                if ($a[0] -eq 'GET' -and $u -match 'projects/AzureLocal') { return [pscustomobject]@{ id = 99 } }
                if ($a[0] -eq 'GET') { return $null }
                if ($a[0] -eq 'POST') { return [pscustomobject]@{ id = 123 } }
            }
            $r = New-AzlCicdProject -Settings (Get-Settings 'gitlab') -Confirm:$false
            $post = Get-Calls '^REST POST .*/api/v4/projects$'
            $post.Count | Should -Be 1
            $post[0].Body.template_project_id | Should -Be 99
            $post[0].Body.visibility | Should -Be 'private'
            $r.Status | Should -Be 'Created'
        }
        finally { $env:GITLAB_TOKEN = $null }
    }
    It 'Azure DevOps: creates the project and imports the template' {
        Start-Recording {
            param($f, $a)
            if ($f -eq 'az') { return New-Out 'aad-token' }
            $m = $a[0]; $u = $a[1]
            if ($m -eq 'GET' -and $u -match '/_apis/projects/') { return $null }
            if ($m -eq 'GET' -and $u -match 'processes') { return [pscustomobject]@{ value = @([pscustomobject]@{ name = 'Agile'; id = 'p1' }) } }
            if ($m -eq 'GET' -and $u -match 'git/repositories') { return [pscustomobject]@{ value = @([pscustomobject]@{ name = 'iic-azurelocal'; id = 'r1'; size = 0 }) } }
            return [pscustomobject]@{ id = 'x' }
        }
        $r = New-AzlCicdProject -Settings (Get-Settings 'azure_devops') -Confirm:$false
        (Get-Calls '^REST POST .*/_apis/projects\?').Count | Should -Be 1
        (Get-Calls 'importRequests').Count | Should -Be 1
        $r.Status | Should -Contain 'Created'
    }
}

Describe 'Task 03: project settings' {
    BeforeAll {
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative {
            $global:AzlCalls.Add([pscustomobject]@{ Line = "$FilePath $($ArgumentList -join ' ')"; Input = $InputText })
            & $global:AzlResponder $FilePath @($ArgumentList)
        }
    }
    It 'GitHub: protects the branch with the approvals, resolves conversations, squash only, secret scanning' {
        Start-Recording { param($f, $a) New-Out '' }
        $null = Set-AzlCicdProjectSetting -Settings (Get-Settings) -Confirm:$false
        $protect = Get-Calls 'branches/main/protection'
        $protect.Count | Should -Be 1
        $body = $protect[0].Input | ConvertFrom-Json
        $body.required_pull_request_reviews.required_approving_review_count | Should -Be 2
        $body.required_conversation_resolution | Should -BeTrue
        $body.allow_force_pushes | Should -BeFalse
        $body.allow_deletions | Should -BeFalse
        $repo = (Get-Calls '-X PATCH repos/improbability-cloud/iic-azurelocal')[0].Input | ConvertFrom-Json
        $repo.allow_merge_commit | Should -BeFalse
        $repo.security_and_analysis.secret_scanning_push_protection.status | Should -Be 'enabled'
    }
    It 'GitHub: -WhatIf sends nothing' {
        Start-Recording { param($f, $a) New-Out '' }
        Set-AzlCicdProjectSetting -Settings (Get-Settings) -WhatIf | Out-Null
        (Get-Calls 'PUT|PATCH').Count | Should -Be 0
    }
}

Describe 'Task 04: environments' {
    BeforeAll {
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative {
            $global:AzlCalls.Add([pscustomobject]@{ Line = "$FilePath $($ArgumentList -join ' ')"; Input = $InputText })
            & $global:AzlResponder $FilePath @($ArgumentList)
        }
    }
    It 'GitHub: creates each environment, with reviewers and a main-only branch rule' {
        Start-Recording {
            param($f, $a)
            $line = $a -join ' '
            switch -Regex ($line) {
                '^api users/' { New-Out '{"id":4242}' }
                'deployment-branch-policies$' { New-Out '{"branch_policies":[]}' }
                '--silent' { New-Out '' 1 }
                default { New-Out '' }
            }
        }
        $null = New-AzlCicdEnvironment -Settings (Get-Settings) -Confirm:$false
        (Get-Calls '-X PUT repos/.*/environments/').Count | Should -Be 3
        $prod = (Get-Calls '-X PUT repos/.*/environments/ztp-reinstall')[0].Input | ConvertFrom-Json
        $prod.reviewers[0].id | Should -Be 4242
        $prod.deployment_branch_policy.custom_branch_policies | Should -BeTrue
        (Get-Calls '-X POST repos/.*/deployment-branch-policies').Count | Should -Be 3
    }
}

Describe 'Task 05: variables' {
    BeforeAll {
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative {
            $global:AzlCalls.Add([pscustomobject]@{ Line = "$FilePath $($ArgumentList -join ' ')"; Input = $InputText })
            & $global:AzlResponder $FilePath @($ArgumentList)
        }
    }
    It 'GitHub with OIDC: sets the IDs as variables for the repository and per environment, and no client secret' {
        Start-Recording { param($f, $a) New-Out '' }
        $s = Get-Settings
        Set-AzlCicdVariable -Settings $s -ClientId '33333333-3333-3333-3333-333333333333' -Confirm:$false | Out-Null
        # the repository (jobs without an environment: validate, plan, preconditions) and each environment
        (Get-Calls 'variable set ARM_CLIENT_ID ').Count | Should -Be ($s.Environments.Count + 1)
        @(Get-Calls 'variable set ARM_CLIENT_ID ' | Where-Object { $_.Line -notmatch '--env' }).Count | Should -Be 1
        (Get-Calls 'secret set ARM_(CLIENT_ID|TENANT_ID|SUBSCRIPTION_ID)').Count | Should -Be 0
        (Get-Calls 'ARM_CLIENT_SECRET').Count | Should -Be 0
        (Get-Calls 'variable set ARM_USE_OIDC').Count | Should -Be ($s.Environments.Count + 1)
    }
    It 'GitHub with a client secret: the value goes through stdin and not on a command line' {
        # The client secret is read through the toolkit's secret resolver, not by a command of this module.
        Mock -ModuleName AzlCicdInfra Get-AzlSecretPlainText { 'TopSecretClientSecret' }
        Start-Recording { param($f, $a) New-Out '' }
        $s = Get-Settings -Change { param($d) $d.devops.authentication.method = 'client_secret'; $d.devops.authentication.client_secret = 'keyvault://kv-iic-mgmt-01/automation-spn-secret' }
        Set-AzlCicdVariable -Settings $s -ClientId '33333333-3333-3333-3333-333333333333' -Confirm:$false | Out-Null
        $set = Get-Calls 'secret set ARM_CLIENT_SECRET'
        $set.Count | Should -Be ($s.Environments.Count + 1)
        $set | ForEach-Object { $_.Line | Should -Not -Match 'TopSecretClientSecret'; $_.Input | Should -Be 'TopSecretClientSecret' }
    }
    It '-WhatIf sets nothing' {
        Start-Recording { param($f, $a) New-Out '' }
        Set-AzlCicdVariable -Settings (Get-Settings) -ClientId '33333333-3333-3333-3333-333333333333' -WhatIf | Out-Null
        (Get-Calls 'secret set|variable set').Count | Should -Be 0
    }
}

Describe 'Task 06: runners' {
    BeforeAll {
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative {
            $global:AzlCalls.Add([pscustomobject]@{ Line = "$FilePath $($ArgumentList -join ' ')"; Args = @($ArgumentList) })
            & $global:AzlResponder $FilePath @($ArgumentList)
        }
        $script:Work = Join-Path $TestDrive 'work'
    }
    BeforeEach {
        Start-Recording { param($f, $a) if ($a[0] -eq 'plan') { New-Out "Plan: 17 to add, 0 to change, 0 to destroy.`n" } else { New-Out '' } }
    }
    It 'plans and stops: no apply without -Apply' {
        $r = Invoke-AzlCicdRunnerDeployment -Settings (Get-Settings) -AdminSshPublicKeyPath (Set-Content (Join-Path $TestDrive 'k.pub') 'ssh-ed25519 AAAA t' -PassThru | ForEach-Object { Join-Path $TestDrive 'k.pub' }) -WorkingDirectory $script:Work -Confirm:$false
        $order = @($global:AzlCalls | ForEach-Object { $_.Args[0] })
        $order | Should -Be @('init', 'validate', 'plan')
        (Get-Calls ' apply ').Count | Should -Be 0
        ($r | Where-Object Action -eq 'terraform apply').Status | Should -Be 'Skipped'
        ($r | Where-Object Action -eq 'terraform plan').Detail | Should -Match 'Plan: 17 to add'
    }
    It 'applies the saved plan file with -Apply, after init, validate and plan' {
        Invoke-AzlCicdRunnerDeployment -Settings (Get-Settings) -AdminSshPublicKeyPath (Join-Path $TestDrive 'k.pub') -WorkingDirectory $script:Work -Apply -Confirm:$false | Out-Null
        $order = @($global:AzlCalls | ForEach-Object { $_.Args[0] })
        $order | Should -Be @('init', 'validate', 'plan', 'apply')
        (Get-Calls 'apply .*cicd-infra\.tfplan$').Count | Should -Be 1
        (Get-Calls ' apply .*-var').Count | Should -Be 0
    }
    It 'does not apply with -Apply -WhatIf' {
        Invoke-AzlCicdRunnerDeployment -Settings (Get-Settings) -AdminSshPublicKeyPath (Join-Path $TestDrive 'k.pub') -WorkingDirectory (Join-Path $TestDrive 'work2') -Apply -WhatIf | Out-Null
        (Get-Calls '^terraform apply').Count | Should -Be 0
    }
    It 'writes variables without any secret, and takes the backend from devops.state' {
        Invoke-AzlCicdRunnerDeployment -Settings (Get-Settings) -AdminSshPublicKeyPath (Join-Path $TestDrive 'k.pub') -WorkingDirectory $script:Work -Confirm:$false | Out-Null
        $file = Join-Path $script:Work 'cicd-infra.auto.tfvars.json'
        Test-Path $file | Should -BeTrue
        (Get-Content $file -Raw) | Should -Not -Match '(?i)password|ghp_|client_secret'
        (Get-Calls '^terraform init').Line | Should -Match 'storage_account_name=stiicazl\w*|storage_account_name=stiictfstate01'
        (Get-Calls '^terraform init').Line | Should -Match 'use_azuread_auth=true'
    }
    It 'uses a prepared tfvars file without reading infrastructure.yml' {
        $vars = Join-Path $TestDrive 'prepared.tfvars'
        Set-Content $vars 'location = "eastus"'
        $null = Invoke-AzlCicdRunnerDeployment -VarFile $vars -BackendFalse -WorkingDirectory $script:Work -NoLock -Confirm:$false
        (Get-Calls '^terraform init').Line | Should -Match '-backend=false'
        (Get-Calls '^terraform plan').Line | Should -Match '-lock=false'
        (Get-Calls '^terraform plan').Line | Should -Match 'prepared\.tfvars'
    }
    It 'applies a reviewed plan file as it is, with its provider lock file, and plans nothing new' {
        $reviewed = Join-Path $TestDrive 'reviewed'
        New-Item -ItemType Directory -Path $reviewed -Force | Out-Null
        Set-Content (Join-Path $reviewed 'cicd-infra.tfplan') 'plan'
        Set-Content (Join-Path $reviewed '.terraform.lock.hcl') '# lock'
        $tf = Join-Path $TestDrive 'tf'
        New-Item -ItemType Directory -Path $tf -Force | Out-Null
        $r = Invoke-AzlCicdRunnerDeployment -Settings (Get-Settings) -TerraformDirectory $tf -PlanFile (Join-Path $reviewed 'cicd-infra.tfplan') -Apply -Confirm:$false
        @($global:AzlCalls | ForEach-Object { $_.Args[0] }) | Should -Be @('init', 'apply')
        Test-Path (Join-Path $tf '.terraform.lock.hcl') | Should -BeTrue
        ($r | Where-Object Action -eq 'terraform apply').Status | Should -Be 'Done'
    }
    It 'refuses -PlanFile without -Apply' {
        { Invoke-AzlCicdRunnerDeployment -Settings (Get-Settings) -PlanFile (Join-Path $TestDrive 'reviewed\cicd-infra.tfplan') -Confirm:$false } | Should -Throw '*needs -Apply*'
    }
    It 'needs an SSH public key for a Linux runner' {
        $env:AZL_RUNNER_SSH_PUBLIC_KEY = $null
        { Invoke-AzlCicdRunnerDeployment -Settings (Get-Settings) -WorkingDirectory $script:Work -Confirm:$false } | Should -Throw '*SSH public key*'
    }
}

Describe 'Task scripts' {
    BeforeDiscovery {
        $script:Scripts = Get-ChildItem -Path (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'scripts\deploy\01-cicd-infra') -Recurse -Filter '*.ps1' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    }
    It '<Name> parses, needs PowerShell 7, uses strict mode and stops on errors' -ForEach $script:Scripts {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match '#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Not -Match 'scaffold'
        $ast.ParamBlock.Attributes.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
    }
    It '<Name> takes no secret as a parameter' -ForEach $script:Scripts {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        @($names | Where-Object { $_ -match '(?i)token|secret|password|pat$' }) | Should -BeNullOrEmpty
    }
    It 'has one script for each of the six tasks, and no Orchestrated wrapper, and an Azure CLI script only for task 01' {
        $dirs = Get-ChildItem -Path $script:TaskRoot -Directory
        $dirs.Count | Should -Be 6
        foreach ($d in $dirs) {
            @(Get-ChildItem (Join-Path $d.FullName 'powershell') -Filter '*.ps1').Count | Should -Be 1
            @(Get-ChildItem (Join-Path $d.FullName 'powershell') -Filter '*-Orchestrated.ps1').Count | Should -Be 0
            # Task 01 has one Azure CLI script of its own (New-CicdBootstrap.azcli.ps1: the app registration, the roles and the registrations are Azure work);
            # the other tasks act on the CI/CD platform or run Terraform, and have none.
            $az = Join-Path $d.FullName 'azurecli'
            $expectedAzureCli = if ($d.Name -eq 'task-01-bootstrap') { 1 } else { 0 }
            if (Test-Path -LiteralPath $az) { @(Get-ChildItem $az -Filter '*.ps1').Count | Should -Be $expectedAzureCli }
        }
    }
    It '<Name> takes a mandatory -InfrastructureFile and no ConfigPath, default path, environment variable, CONFIGURATION region or prompt' -ForEach $script:Scripts {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'InfrastructureFile' }
        $param | Should -Not -BeNullOrEmpty
        @($param.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' -and ($_.NamedArguments.ArgumentName -contains 'Mandatory') }).Count | Should -Be 1
        $param.DefaultValue | Should -BeNullOrEmpty
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Not -Contain 'ConfigPath'
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Not -Match 'ConfigPath|AZL_INFRASTRUCTURE_FILE|#region CONFIGURATION|Get-Credential|Read-Host|PromptForCredential'
    }
    It 'Deploy-CicdRunners.ps1 documents -Apply as the only way to change Azure' {
        $text = Get-Content -LiteralPath (Join-Path $script:TaskRoot 'task-06-deploy-runners\powershell\Deploy-CicdRunners.ps1') -Raw
        $text | Should -Match '\[switch\]\$Apply'
        $text | Should -Match 'Without it the script stops after the plan'
    }
}

Describe 'Runner bootstrap templates carry no secret' {
    It '<Name> has no token, password or key material' -ForEach @(
        @{ Name = 'bootstrap-linux.sh.tftpl' }, @{ Name = 'bootstrap-windows.ps1.tftpl' }, @{ Name = 'cloud-init.yaml.tftpl' }
    ) {
        $text = Get-Content -LiteralPath (Join-Path $script:Repo "src\terraform\modules\cicd-runner\templates\$Name") -Raw
        $text | Should -Not -Match 'ghp_[A-Za-z0-9]{10,}|glpat-[A-Za-z0-9]{10,}|glrt-[A-Za-z0-9]{10,}|BEGIN (RSA |OPENSSH )?PRIVATE KEY'
        if ($Name -like 'bootstrap-*') { $text | Should -Match '169\.254\.169\.254' }
    }
}

Describe 'Task 05: the runner label and approval environments of the pipelines (devops.pipelines)' {
    BeforeAll {
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative {
            $global:AzlCalls.Add([pscustomobject]@{ Line = "$FilePath $($ArgumentList -join ' ')"; Input = $InputText })
            & $global:AzlResponder $FilePath @($ArgumentList)
        }
        Mock -ModuleName AzlCicdInfra Invoke-AzlRest {
            $global:AzlCalls.Add([pscustomobject]@{ Line = "REST $Method $Uri"; Body = $Body })
            & $global:AzlResponder 'REST' @($Method, $Uri)
        }
        $script:Client = '33333333-3333-3333-3333-333333333333'
    }
    It 'reads the example: the label and one approval environment per pipeline, each with its key' {
        $v = Get-AzlCicdPipelineInput -Settings (Get-Settings)
        ($v | Where-Object Name -eq 'AZL_RUNNER_LABEL').Value | Should -Be 'azure-local'
        ($v | Where-Object Name -eq 'AZL_RUNNER_LABEL').Key | Should -Be 'devops.pipelines.runner_label'
        ($v | Where-Object Name -eq 'AZL_ENVIRONMENT_ARM_DEPLOYMENT').Value | Should -Be 'azr-prod-us'
        ($v | Where-Object Name -eq 'AZL_ENVIRONMENT_ARM_DEPLOYMENT').Key | Should -Be 'devops.pipelines.environments.arm_deployment'
        # the second approval of a storage wipe is read on every platform (D126)
        ($v | Where-Object Name -eq 'AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE').Key | Should -Be 'devops.pipelines.environments.os_configuration_clear_storage'
    }
    It 'GitHub: sets each one as a repository variable (no --env), from the file' {
        Start-Recording { param($f, $a) New-Out '' }
        $s = Get-Settings
        Set-AzlCicdVariable -Settings $s -ClientId $script:Client -Confirm:$false | Out-Null
        $set = @(Get-Calls 'variable set AZL_')
        $set.Count | Should -Be @(Get-AzlCicdPipelineInput -Settings $s).Count
        $set.Count | Should -BeGreaterThan 15
        $set | ForEach-Object { $_.Line | Should -Not -Match '--env' }
        (Get-Calls 'variable set AZL_RUNNER_OS .*--body linux$').Count | Should -Be 1
        (Get-Calls 'variable set AZL_INFRASTRUCTURE_FILE .*--body config/infrastructure.yml$').Count | Should -Be 1
        (Get-Calls 'variable set AZL_AUTH_METHOD .*--body oidc$').Count | Should -Be 1
        (Get-Calls 'variable set AZL_TERRAFORM_VERSION .*--body 1\.16\.3$').Count | Should -Be 1
        (Get-Calls 'variable set AZL_DEPLOY_JOB_TIMEOUT_MINUTES .*--body \d+$').Count | Should -Be 1
        (Get-Calls 'variable set AZL_RUNNER_LABEL .*--body azure-local$').Count | Should -Be 1
        (Get-Calls 'variable set AZL_ENVIRONMENT_OS_CONFIGURATION .*--body azr-prod-us$').Count | Should -Be 1
        (Get-Calls 'variable set AZL_ENVIRONMENT_TERRAFORM_DEPLOYMENT .*--body azr-prod-us$').Count | Should -Be 1
    }
    It 'GitHub: -WhatIf sets none of them' {
        Start-Recording { param($f, $a) New-Out '' }
        $r = Set-AzlCicdVariable -Settings (Get-Settings) -ClientId $script:Client -WhatIf
        (Get-Calls 'variable set AZL_').Count | Should -Be 0
        @($r | Where-Object { $_.Action -eq 'Pipeline variable' -and $_.Status -eq 'Planned' }).Count | Should -Be @(Get-AzlCicdPipelineInput -Settings (Get-Settings)).Count
    }
    It 'GitLab: creates project variables for all environments (scope *), not per environment' {
        $env:GITLAB_TOKEN = 'glpat-test-value'
        try {
            Start-Recording {
                param($f, $a)
                if ($a[0] -eq 'GET' -and $a[1] -match 'projects/improbability') { return [pscustomobject]@{ id = 55 } }
                if ($a[0] -eq 'GET') { return $null }
                return [pscustomobject]@{ id = 1 }
            }
            $r = Set-AzlCicdVariable -Settings (Get-Settings 'gitlab') -ClientId $script:Client -Confirm:$false
            $posts = @(Get-Calls '^REST POST .*/projects/55/variables$' | Where-Object { $_.Body.key -like 'AZL_*' })
            $expected = @(Get-AzlCicdPipelineInput -Settings (Get-Settings 'gitlab')).Count
            $posts.Count | Should -Be $expected
            $posts | ForEach-Object { $_.Body.environment_scope | Should -Be '*'; $_.Body.masked | Should -BeFalse }
            ($posts | Where-Object { $_.Body.key -eq 'AZL_RUNNER_LABEL' }).Body.value | Should -Be 'azure-local'
            ($posts | Where-Object { $_.Body.key -eq 'AZL_PYTHON_VERSION' }).Body.value | Should -Be '3.12'
            # GitHub only: GitLab chooses the runner by its tag and reads no job timeout from a variable
            @($posts | Where-Object { $_.Body.key -in 'AZL_RUNNER_OS', 'AZL_DEPLOY_JOB_TIMEOUT_MINUTES' }).Count | Should -Be 0
            @($r | Where-Object Action -eq 'Pipeline variable').Count | Should -Be $expected
        }
        finally { $env:GITLAB_TOKEN = $null }
    }
    It 'Azure DevOps: sets no variable; it names the pool and each environment for the settings files Set-CicdVariables.ps1 writes, never a run parameter (D126)' {
        Start-Recording {
            param($f, $a)
            if ($f -eq 'az') { return New-Out 'x' }
            return [pscustomobject]@{ id = 'x'; value = @() }
        }
        $s = Get-Settings 'azure_devops' { param($d) $d.devops.runners[0].pool = 'pool-lnx' }
        $r = Set-AzlCicdVariable -Settings $s -ClientId $script:Client -Confirm:$false
        (Get-Calls 'AZL_').Count | Should -Be 0
        @($r | Where-Object Action -eq 'Pipeline run parameter').Count | Should -Be 0 -Because 'no deployment value is a run parameter'
        $rows = @($r | Where-Object Action -eq 'Pipeline settings file')
        $rows | ForEach-Object { $_.Status | Should -Be 'Skipped' }
        ($rows | Where-Object Target -eq 'devops.runners[].pool').Detail | Should -Match "writes 'pool-lnx' as AZL_AGENT_POOL into pipelines/azure-devops/variables/pipeline-settings\.yml"
        # the approval environments go to the other YAML file of the repository: whoever queues a run cannot choose an environment with no approval
        $templateRows = @($rows | Where-Object Target -like 'devops.pipelines.environments.*')
        @($templateRows | ForEach-Object Target | Sort-Object) | Should -Be @('devops.pipelines.environments.arm_deployment', 'devops.pipelines.environments.cicd_infra', 'devops.pipelines.environments.os_configuration', 'devops.pipelines.environments.os_configuration_clear_storage', 'devops.pipelines.environments.terraform_deployment')
        ($templateRows | Where-Object Target -eq 'devops.pipelines.environments.os_configuration_clear_storage').Detail | Should -Match "writes 'azr-prod-us' as AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE into pipelines/azure-devops/variables/approval-environments\.yml"
        foreach ($t in $rows) { $t.Detail | Should -Match 'never a run parameter' }
    }
    It 'Azure DevOps: there is no default pool, so a general runner without one is refused' {
        { Get-AzlCicdPipelineInput -Settings (Get-Settings 'azure_devops') } | Should -Throw '*devops.runners[[]].pool is not set*'
        { ConvertTo-AzlRunnerTerraformVariable -Settings (Get-Settings 'azure_devops') } | Should -Throw '*Azure DevOps needs the agent pool*'
    }
    It 'Azure DevOps: the service connection and the variable groups are named by devops.pipelines (5.6.27), and the settings file rows name them (D126)' {
        Start-Recording {
            param($f, $a)
            if ($f -eq 'az') { return New-Out 'x' }
            return [pscustomobject]@{ id = 'x'; value = @() }
        }
        $s = Get-Settings 'azure_devops' { param($d) $d.devops.runners[0].pool = 'pool-lnx' }
        $r = Set-AzlCicdVariable -Settings $s -ClientId $script:Client -Confirm:$false
        $groups = @($r | Where-Object Action -eq 'Variable group' | ForEach-Object Target)
        $groups.Count | Should -BeGreaterThan 0
        $groups | ForEach-Object { $_ | Should -BeLike 'iic-azure-credentials*' }
        @($r | Where-Object Action -eq 'Service connection').Target | Should -Be 'iic-azure-local'
        $groups | Should -Contain 'iic-azure-credentials' -Because 'the repository group, which every pipeline reads (D126)'
        $rows = @($r | Where-Object Action -eq 'Pipeline settings file')
        ($rows | Where-Object Target -eq 'devops.pipelines.service_connection').Detail | Should -Match "writes 'iic-azure-local' as AZL_SERVICE_CONNECTION into pipelines/azure-devops/variables/pipeline-settings\.yml"
        ($rows | Where-Object Target -eq 'devops.pipelines.variable_group').Detail | Should -Match "writes 'iic-azure-credentials' as AZL_VARIABLE_GROUP"
        (Get-Calls 'AzureLocal-ServiceConnection|(?<!iic-)azure-credentials').Count | Should -Be 0
    }
    It 'Azure DevOps: there is no default service connection or variable group name, so a file without them is refused' {
        $none = Get-Settings 'azure_devops' { param($d) $d.devops.runners[0].pool = 'pool-lnx'; $d.devops.pipelines.Remove('service_connection') }
        { Get-AzlCicdPipelineInput -Settings $none } | Should -Throw '*devops.pipelines.service_connection is not set*'
        $none = Get-Settings 'azure_devops' { param($d) $d.devops.runners[0].pool = 'pool-lnx'; $d.devops.pipelines.Remove('variable_group') }
        { Get-AzlCicdPipelineInput -Settings $none } | Should -Throw '*devops.pipelines.variable_group is not set*'
    }
    It 'Azure DevOps: task 06 passes the pool of each runner on, and the ztp runner needs its own' {
        $s = Get-Settings 'azure_devops' { param($d) $d.devops.runners[0].pool = 'pool-lnx' }
        $v = ConvertTo-AzlRunnerTerraformVariable -Settings $s -AdminSshPublicKey 'k'
        $v.azure_devops_pool | Should -Be 'pool-lnx'
        $v.azure_devops_ztp_pool | Should -Be 'azurelocal-ztp'
        $none = Get-Settings 'azure_devops' { param($d) $d.devops.runners[0].pool = 'pool-lnx'; $d.devops.runners[1].Remove('pool') }
        { ConvertTo-AzlRunnerTerraformVariable -Settings $none } | Should -Throw '*ztp runner*pool*'
    }
    It 'refuses a runner label that the general runner does not have' {
        $s = Get-Settings -Change { param($d) $d.devops.pipelines.runner_label = 'not-a-label' }
        { Get-AzlCicdPipelineInput -Settings $s } | Should -Throw '*not an entry of devops.runners[[]].labels*'
    }
    It 'refuses an environment that devops.environments does not list, or one without an approval' {
        $s = Get-Settings -Change { param($d) $d.devops.pipelines.environments.arm_deployment = 'no-such-environment' }
        { Get-AzlCicdPipelineInput -Settings $s } | Should -Throw "*'no-such-environment' is not the name of an entry*"
        $t = Get-Settings -Change { param($d) $d.devops.pipelines.environments.arm_deployment = 'azr-dev-us' }
        { Get-AzlCicdPipelineInput -Settings $t } | Should -Throw '*without approval_required*'
    }
    It 'a file without devops.pipelines sets no runner label or environment, and the registry defaults of the rest' {
        Start-Recording { param($f, $a) New-Out '' }
        $s = Get-Settings -Change { param($d) $d.devops.Remove('pipelines') }
        Set-AzlCicdVariable -Settings $s -ClientId $script:Client -Confirm:$false | Out-Null
        (Get-Calls 'variable set AZL_(RUNNER_LABEL|ENVIRONMENT_)').Count | Should -Be 0
        (Get-Calls 'variable set AZL_INFRASTRUCTURE_FILE .*--body config/infrastructure.yml$').Count | Should -Be 1
        (Get-Calls 'variable set AZL_HANDOFF_PATH .*--body ztp-state$').Count | Should -Be 1
        (Get-Calls 'variable set AZL_TERRAFORM_VERSION .*--body 1\.16\.3$').Count | Should -Be 1
    }
    It 'sets every value from its key: the paths, the tool versions, the sign-in method and the job timeouts (5.6.28)' {
        Start-Recording { param($f, $a) New-Out '' }
        $s = Get-Settings -Change {
            param($d)
            $d.devops.pipelines.infrastructure_file = 'environments/iic/infrastructure.yml'
            $d.devops.pipelines.handoff_path = 'environments/iic/ztp-state'
            $d.devops.pipelines.tool_versions = [ordered]@{ terraform = '1.17.0'; python = '3.13'; ansible_core = '2.22.0'; ansible_lint = '26.11.0'; az_powershell = '16.4.0'; powershell_yaml = '0.4.13'; az_keyvault = '6.7.0' }
            $d.devops.authentication.method = 'client_secret'
            $d.devops.authentication.client_secret = 'keyvault://kv-iic-mgmt-01/automation-spn-secret'
            $d['deployment'] = [ordered]@{ validate_timeout_minutes = 120; deploy_timeout_minutes = 480 }
        }
        Mock -ModuleName AzlCicdInfra Get-AzlSecretPlainText { 'TopSecretClientSecret' }
        Set-AzlCicdVariable -Settings $s -ClientId $script:Client -Confirm:$false | Out-Null
        $expect = [ordered]@{
            AZL_INFRASTRUCTURE_FILE = 'environments/iic/infrastructure.yml'; AZL_HANDOFF_PATH = 'environments/iic/ztp-state'
            AZL_TERRAFORM_VERSION = '1.17.0'; AZL_PYTHON_VERSION = '3.13'; AZL_ANSIBLE_CORE_VERSION = '2.22.0'; AZL_ANSIBLE_LINT_VERSION = '26.11.0'
            AZL_AZ_POWERSHELL_VERSION = '16.4.0'; AZL_POWERSHELL_YAML_VERSION = '0.4.13'; AZL_AZ_KEYVAULT_VERSION = '6.7.0'
            AZL_AUTH_METHOD = 'client_secret'; AZL_VALIDATE_JOB_TIMEOUT_MINUTES = '180'; AZL_DEPLOY_JOB_TIMEOUT_MINUTES = '540'
        }
        foreach ($k in $expect.Keys) { (Get-Calls "variable set $k .*--body $([regex]::Escape($expect[$k]))$").Count | Should -Be 1 -Because $k }
    }
    It 'sets the runner public key from devops.runners[].admin_ssh_public_key, and reads a reference through the secret resolver' {
        Start-Recording { param($f, $a) New-Out '' }
        $s = Get-Settings -Change { param($d) $d.devops.runners[0]['admin_ssh_public_key'] = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnly iic-runner-admin' }
        Set-AzlCicdVariable -Settings $s -ClientId $script:Client -Confirm:$false | Out-Null
        (Get-Calls 'variable set AZL_RUNNER_SSH_PUBLIC_KEY .*--body ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnly iic-runner-admin$').Count | Should -Be 1
        Mock -ModuleName AzlCicdInfra Get-AzlSecretPlainText { "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFromTheFile iic-runner-admin`n" }
        Start-Recording { param($f, $a) New-Out '' }
        $s = Get-Settings -Change { param($d) $d.devops.runners[0]['admin_ssh_public_key'] = 'file://runner-admin.pub' }
        $r = Set-AzlCicdVariable -Settings $s -ClientId $script:Client -WhatIf
        (Get-Calls 'variable set AZL_RUNNER_SSH_PUBLIC_KEY').Count | Should -Be 0
        ($r | Where-Object Target -eq 'AZL_RUNNER_SSH_PUBLIC_KEY (repository)').Detail | Should -Match 'reference'
        Set-AzlCicdVariable -Settings $s -ClientId $script:Client -Confirm:$false | Out-Null
        (Get-Calls 'variable set AZL_RUNNER_SSH_PUBLIC_KEY .*--body ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFromTheFile iic-runner-admin$').Count | Should -Be 1
        Should -Invoke -ModuleName AzlCicdInfra Get-AzlSecretPlainText -ParameterFilter { $Reference -eq 'file://runner-admin.pub' }
    }
    It 'a value other than the public key may not be a secret reference' {
        $s = Get-Settings -Change { param($d) $d.devops.pipelines.tool_versions = @{ terraform = 'env://TF_VERSION' } }
        { Get-AzlCicdPipelineInput -Settings $s } | Should -Throw '*is a secret reference*'
    }
    It 'Azure DevOps: writes the tool versions, the sign-in method, the default branch and the public key to the variable group' {
        Start-Recording {
            param($f, $a)
            if ($f -eq 'az') { return New-Out 'x' }
            return [pscustomobject]@{ id = 'x'; value = @() }
        }
        $s = Get-Settings 'azure_devops' { param($d) $d.devops.runners[0].pool = 'pool-lnx'; $d.devops.runners[0]['admin_ssh_public_key'] = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnly iic-runner-admin' }
        $r = Set-AzlCicdVariable -Settings $s -ClientId $script:Client -Confirm:$false
        $groups = @(Get-Calls '^REST POST .*/distributedtask/variablegroups')
        $groups.Count | Should -Be ($s.Environments.Count + 1) -Because 'the repository group, which the pipelines read (D126), and one per environment'
        foreach ($g in $groups) {
            $vars = $g.Body.variables
            $vars['AZL_TERRAFORM_VERSION'].value | Should -Be '1.16.3'
            $vars['AZL_AZ_POWERSHELL_VERSION'].value | Should -Be '16.3.0'
            $vars['AZL_AUTH_METHOD'].value | Should -Be 'oidc'
            $vars['AZL_DEFAULT_BRANCH'].value | Should -Be 'main'
            $vars['AZL_RUNNER_SSH_PUBLIC_KEY'].value | Should -Match '^ssh-ed25519 '
            $vars['TF_BACKEND_KEY'].value | Should -Be 'azure-local.tfstate'
            $vars.Contains('AZL_INFRASTRUCTURE_FILE') | Should -BeFalse -Because 'the path is a variable of pipeline-settings.yml, read when the pipeline is compiled'
        }
        $rows = @($r | Where-Object Action -eq 'Pipeline settings file')
        ($rows | Where-Object Target -eq 'devops.pipelines.infrastructure_file').Detail | Should -Match "writes 'config/infrastructure.yml' as AZL_INFRASTRUCTURE_FILE"
        ($rows | Where-Object Target -eq 'devops.pipelines.handoff_path').Detail | Should -Match "writes 'ztp-state' as AZL_HANDOFF_PATH"
        @($rows | Where-Object Target -like 'devops.pipelines.tool_versions.*').Count | Should -Be 0
    }
    It 'TF_BACKEND_KEY is devops.state.azure_local_key' {
        $s = Get-Settings -Change { param($d) $d.devops.state['azure_local_key'] = 'iic/azure-local.tfstate' }
        $plan = & (Get-Module AzlCicdInfra) { param($x) Get-AzlCicdVariablePlan -Settings $x -ClientId 'x' } $s
        ($plan | Where-Object Name -EQ 'TF_BACKEND_KEY').Value | Should -Be 'iic/azure-local.tfstate'
    }
}
