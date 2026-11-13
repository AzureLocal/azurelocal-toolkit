#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Arc registration): the two orchestrated scripts read the secret reference of the automation identity from the registered key
# devops.authentication.client_secret, not from the old-layout key identity.service_principal.secret. The config reader and the secret
# helper of each script are taken out of the script by the parser and run against a file in TestDrive; nothing reaches Azure.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/ArcSecretKey.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the helpers under test.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $phase = [IO.Path]::Combine($repoRoot, 'scripts', 'deploy', '04-cluster-deployment', 'phase-04-arc-registration')
    $script:Cases = @(
        @{ Name = 'Invoke-ArcRegistration-Orchestrated.ps1'; Path = [IO.Path]::Combine($phase, 'task-02-register-cluster-nodes-with-azure-arc', 'powershell', 'Invoke-ArcRegistration-Orchestrated.ps1') }
        @{ Name = 'Invoke-ArcPrerequisites-Orchestrated.ps1'; Path = [IO.Path]::Combine($phase, 'task-01-pre-registration-validation', 'powershell', 'Invoke-ArcPrerequisites-Orchestrated.ps1') }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'secrets', 'AzlSecret.psm1')) -Force
    Import-Module powershell-yaml
    $script:Canary = 'Canary-Arc-S3cret-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $env:AZL_TEST_ARC_SECRET = $script:Canary

    function Get-InfraFile {
        param([hashtable]$Extra = @{})
        $doc = [ordered]@{
            azure     = [ordered]@{ tenant_id = '00000000-0000-0000-0000-000000000000'; subscription_id = '00000000-0000-0000-0000-000000000000'; location = 'eastus'; resource_group = 'rg-iic-azl-01'; automation_identity = [ordered]@{ type = 'service_principal'; name = 'iic-automation'; client_id = '00000000-0000-0000-0000-000000000001' } }
            identity  = [ordered]@{ local_admin = [ordered]@{ username = 'azl-admin'; password = 'env://AZL_TEST_ARC_SECRET' } }
            nodes     = @([ordered]@{ name = 'iic-azl-n01'; management = [ordered]@{ ip_address = '192.0.2.11' } })
            key_vaults = @()
        }
        foreach ($k in $Extra.Keys) { $doc[$k] = $Extra[$k] }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Get-FunctionText([string]$Path, [string]$Name) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1).Extent.Text
    }
    function Get-CodeText([string]$Path) {
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
    }
}

AfterAll { Remove-Item Env:AZL_TEST_ARC_SECRET -ErrorAction SilentlyContinue }

Describe '<Name> reads the automation identity secret from the registered key' -ForEach $script:Cases {
    BeforeAll {
        $script:Code = Get-CodeText $Path
        function Write-Log { param($Message, $Level) }
        . ([scriptblock]::Create((Get-FunctionText $Path 'Get-Config')))
        . ([scriptblock]::Create((Get-FunctionText $Path 'Resolve-KeyVaultRef')))
    }

    It 'no longer reads identity.service_principal' {
        $script:Code | Should -Not -Match 'service_principal'
    }
    It 'reads devops.authentication.client_secret, and the key is in the registry (the generated schema has it)' {
        $script:Code | Should -Match "'devops'.{1,8}'authentication'.{1,8}'client_secret'"
        $schema = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $schema.properties.devops.properties.authentication.properties.Keys | Should -Contain 'client_secret'
    }
    It 'takes the secret reference from the file and the SPN application id from azure.automation_identity' {
        $file = Get-InfraFile @{ devops = [ordered]@{ authentication = [ordered]@{ method = 'client_secret'; client_secret = 'env://AZL_TEST_ARC_SECRET' } } }
        $cfg = Get-Config -Path $file
        $cfg.SpnSecretUri | Should -Be 'env://AZL_TEST_ARC_SECRET'
        $cfg.SpnAppId | Should -Be '00000000-0000-0000-0000-000000000001'
    }
    It 'reads the secret with the resolver, whatever the provider, and the config does not carry the value' {
        $file = Get-InfraFile @{ devops = [ordered]@{ authentication = [ordered]@{ method = 'client_secret'; client_secret = 'env://AZL_TEST_ARC_SECRET' } } }
        $cfg = Get-Config -Path $file
        (Resolve-KeyVaultRef -KvUri $cfg.SpnSecretUri) | Should -BeExactly $script:Canary
        ($cfg | ConvertTo-Json -Depth 5) | Should -Not -Match $script:Canary
    }
    It 'has no secret reference when the file has none (OIDC or a managed identity), and the old key is ignored' {
        $file = Get-InfraFile @{ identity = [ordered]@{ local_admin = [ordered]@{ username = 'azl-admin'; password = 'env://AZL_TEST_ARC_SECRET' }; service_principal = [ordered]@{ secret = 'env://AZL_TEST_ARC_SECRET' } } }
        $cfg = Get-Config -Path $file
        $cfg.SpnSecretUri | Should -BeNullOrEmpty
        (Resolve-KeyVaultRef -KvUri $cfg.SpnSecretUri) | Should -BeNullOrEmpty
    }
}
