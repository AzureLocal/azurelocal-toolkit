#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The day-2 and helper scripts that read the infrastructure file and never ask:
#   scripts/lifecycle/operations/powershell/Invoke-ClusterOperations.ps1   cluster.name from the file; changes are behind -WhatIf; exit 0, 1, 2
#   scripts/common/utilities/helpers/Connect-AzureSession.ps1 and Connect-AzureCliSession.ps1   the tenant and subscription come from the file; they ask nothing
#   scripts/tools/authoring/New-ScriptFromTemplate.ps1                     writes a schema 5 script (-InfrastructureFile, registered keys, no prompt)
# Every cluster, Az and az call is a stub or a mock; nothing is contacted. Scripts run as copies in TestDrive where they need the Az modules (#Requires)
# or find the infrastructure module by a path relative to their own folder.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/utilities/LifecycleAndHelpers.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cmdlets they replace.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Operations = [IO.Path]::Combine($repo, 'scripts', 'lifecycle', 'operations', 'powershell', 'Invoke-ClusterOperations.ps1')
    $script:AzSession = [IO.Path]::Combine($repo, 'scripts', 'common', 'utilities', 'helpers', 'Connect-AzureSession.ps1')
    $script:CliSession = [IO.Path]::Combine($repo, 'scripts', 'common', 'utilities', 'helpers', 'Connect-AzureCliSession.ps1')
    $script:Template = [IO.Path]::Combine($repo, 'scripts', 'tools', 'authoring', 'New-ScriptFromTemplate.ps1')
    $script:Module = [IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')
    Import-Module powershell-yaml

    function New-ScriptCopy([string]$Source, [string]$RelativeLine) {
        # The copy lives in TestDrive: the relative path of the infrastructure module is replaced by the real one, and #Requires -Module lines are dropped.
        $text = Get-Content -LiteralPath $Source -Raw
        $match = [regex]::Match($text, 'Import-Module \(\[IO\.Path\]::GetFullPath\(\[IO\.Path\]::Combine\(\$PSScriptRoot[^\r\n]*AzlInfrastructure\.psm1''\)\)\) -Force')
        $match.Success | Should -BeTrue
        $copy = Join-Path $TestDrive ([IO.Path]::GetFileName($Source))
        Set-Content -LiteralPath $copy -Value ((($text.Replace($match.Value, "Import-Module '$script:Module' -Force")) -split "`r?`n" | Where-Object { $_ -notmatch '^#Requires -Module' }) -join "`n")
        $copy
    }
    function New-InfraFile {
        param([switch]$NoCluster, [switch]$NoTenant, [string]$Subscription = '11111111-1111-1111-1111-111111111111')
        $az = [ordered]@{ subscription_id = $Subscription }
        if (-not $NoTenant) { $az.tenant_id = '22222222-2222-2222-2222-222222222222' }
        $doc = [ordered]@{ azure = $az }
        if (-not $NoCluster) { $doc.cluster = [ordered]@{ name = 'iic-azl-01' } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }

    # Stubs of the cluster cmdlets of Invoke-ClusterOperations.ps1
    function Get-ClusterNode { param($Cluster, $Name) @([pscustomobject]@{ Name = 'iic-01-n01'; State = 'Up' }, [pscustomobject]@{ Name = 'iic-01-n02'; State = 'Up' }) }
    function Suspend-ClusterNode { param($Name, $Cluster, [switch]$Drain, [switch]$Wait) $null }
    function Resume-ClusterNode { param($Name, $Cluster, $Failback) $null }
    function Invoke-Command { param($ComputerName, $ScriptBlock, $ErrorAction) $null }
    function Get-VM { param($ComputerName) @([pscustomobject]@{ Name = 'vm-iic-01' }) }
    function Move-VM { param($Name, $ComputerName, $DestinationHost) $null }
    function Get-ClusterSharedVolume { param($Cluster) @() }
    function Move-ClusterSharedVolume { param($Name, $Node) $null }
    function Invoke-Operations([string]$File, [hashtable]$Extra = @{}) {
        $copy = New-ScriptCopy $script:Operations
        $global:LASTEXITCODE = $null
        $text = (& $copy -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 | Out-String)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
    }
}

Describe 'Invoke-ClusterOperations.ps1' {
    BeforeEach {
        Mock Suspend-ClusterNode { }
        Mock Resume-ClusterNode { }
        Mock Move-VM { }
        Mock Move-ClusterSharedVolume { }
    }

    It 'ends with exit code 2 when cluster.name is missing, and does nothing' {
        $r = Invoke-Operations (New-InfraFile -NoCluster) @{ Action = 'HealthCheck' }
        $r.ExitCode | Should -Be 2
        $r.Text | Should -Match 'cluster.name is missing'
    }

    It 'ends with exit code 2 when MaintenanceMode or LiveMigrate has no -NodeName' {
        foreach ($action in 'MaintenanceMode', 'LiveMigrate') {
            $r = Invoke-Operations (New-InfraFile) @{ Action = $action }
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'needs -NodeName'
        }
        Should -Invoke Suspend-ClusterNode -Times 0 -Exactly
    }

    It 'drains the node of the cluster named by the file when entering maintenance mode' {
        $r = Invoke-Operations (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-01-n01'; Enable = $true }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Should -Invoke Suspend-ClusterNode -Times 1 -Exactly -ParameterFilter { $Name -eq 'iic-01-n01' -and $Cluster -eq 'iic-azl-01' }
    }

    It 'changes nothing under -WhatIf: no drain, no resume, no VM move, no CSV move' {
        $file = New-InfraFile
        $null = Invoke-Operations $file @{ Action = 'MaintenanceMode'; NodeName = 'iic-01-n01'; Enable = $true; WhatIf = $true }
        $null = Invoke-Operations $file @{ Action = 'MaintenanceMode'; NodeName = 'iic-01-n01'; WhatIf = $true }
        $null = Invoke-Operations $file @{ Action = 'LiveMigrate'; NodeName = 'iic-01-n01'; WhatIf = $true }
        Should -Invoke Suspend-ClusterNode -Times 0 -Exactly
        Should -Invoke Resume-ClusterNode -Times 0 -Exactly
        Should -Invoke Move-VM -Times 0 -Exactly
        Should -Invoke Move-ClusterSharedVolume -Times 0 -Exactly
    }

    It 'ends with exit code 1 when the drain fails' {
        Mock Suspend-ClusterNode { throw 'The node cannot be drained.' }
        $r = Invoke-Operations (New-InfraFile) @{ Action = 'MaintenanceMode'; NodeName = 'iic-01-n01'; Enable = $true }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'cannot be drained'
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Operations -Raw
            $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Operations, [ref]$null, [ref]$null)
        }
        It 'takes -InfrastructureFile (mandatory) and no -ClusterName' {
            $names = @($script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $names | Should -Contain 'InfrastructureFile'
            $names | Should -Not -Contain 'ClusterName'
        }
        It 'has the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential'
        }
    }
}

Describe 'Connect-AzureSession.ps1 and Connect-AzureCliSession.ps1' {
    BeforeAll {
        function Connect-AzAccount { param($TenantId, $SubscriptionId, $Scope, [switch]$UseDeviceAuthentication) $null }
        function Get-AzContext { [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'a@improbability.cloud' }; Subscription = [pscustomobject]@{ Name = 's'; Id = '11111111-1111-1111-1111-111111111111' }; Tenant = [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222' }; Environment = [pscustomobject]@{ Name = 'AzureCloud' } } }
        function az {
            $global:AzlHelperAzCalls += , ($args -join ' ')
            $global:LASTEXITCODE = 0
            if ($args -contains 'version') { return '{"azure-cli":"2.99.0"}' }
            if ($args -contains 'show') { return '{"user":{"name":"a@improbability.cloud"},"name":"s","id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","environmentName":"AzureCloud","state":"Enabled"}' }
        }
    }
    BeforeEach {
        $global:AzlHelperAzCalls = @()
        Mock Connect-AzAccount { }
    }
    AfterAll { Remove-Variable -Name AzlHelperAzCalls -Scope Global -ErrorAction SilentlyContinue }

    It 'Connect-AzureSession.ps1 signs in with the tenant and the subscription of the file, and asks nothing' {
        $copy = New-ScriptCopy $script:AzSession
        $null = & $copy -InfrastructureFile (New-InfraFile) 6>&1
        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $TenantId -eq '22222222-2222-2222-2222-222222222222' -and $SubscriptionId -eq '11111111-1111-1111-1111-111111111111' -and $Scope -eq 'Process' }
    }

    It 'Connect-AzureSession.ps1 ends with exit code 2 and signs in to nothing when the tenant is missing or the subscription is the all-zero placeholder' {
        $copy = New-ScriptCopy $script:AzSession
        $null = & $copy -InfrastructureFile (New-InfraFile -NoTenant) 6>&1 2>&1
        $LASTEXITCODE | Should -Be 2
        $null = & $copy -InfrastructureFile (New-InfraFile -Subscription '00000000-0000-0000-0000-000000000000') 6>&1 2>&1
        $LASTEXITCODE | Should -Be 2
        Should -Invoke Connect-AzAccount -Times 0 -Exactly
    }

    It 'Connect-AzureCliSession.ps1 runs az login for the tenant and az account set for the subscription of the file' {
        $copy = New-ScriptCopy $script:CliSession
        $null = & $copy -InfrastructureFile (New-InfraFile) 6>&1
        $global:AzlHelperAzCalls | Should -Contain 'login --tenant 22222222-2222-2222-2222-222222222222'
        $global:AzlHelperAzCalls | Should -Contain 'account set --subscription 11111111-1111-1111-1111-111111111111'
    }

    It 'Connect-AzureCliSession.ps1 ends with exit code 2 and calls az login for nothing when the tenant is missing' {
        $copy = New-ScriptCopy $script:CliSession
        $null = & $copy -InfrastructureFile (New-InfraFile -NoTenant) 6>&1 2>&1
        $LASTEXITCODE | Should -Be 2
        @($global:AzlHelperAzCalls | Where-Object { $_ -like 'login*' }) | Should -BeNullOrEmpty
    }

    It '<Name> takes -InfrastructureFile, mandatory, and has no -TenantId, -SubscriptionId or -ConfigPath, and no prompt' -ForEach @(
        @{ Name = 'Connect-AzureSession.ps1'; Key = 'AzSession' }
        @{ Name = 'Connect-AzureCliSession.ps1'; Key = 'CliSession' }
    ) {
        $path = Get-Variable -Name $Key -Scope Script -ValueOnly
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Contain 'InfrastructureFile'
        foreach ($old in 'TenantId', 'SubscriptionId', 'ConfigPath') { $names | Should -Not -Contain $old }
        $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$null)
        ((($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')) | Should -Not -Match 'Read-Host|Get-Credential|ConvertFrom-Yaml|ConfigPath'
    }
}

Describe 'New-ScriptFromTemplate.ps1' {
    BeforeAll {
        function Invoke-Template([string]$Type, [string]$Name) {
            $out = Join-Path $TestDrive "tpl-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
            New-Item -ItemType Directory -Path $out | Out-Null
            $null = & $script:Template -ScriptType $Type -Name $Name -Description 'Does the thing' -OutputPath $out 6>&1
            @(Get-ChildItem -LiteralPath $out -File)[0].FullName
        }
    }

    It 'writes a script that parses, takes a mandatory -InfrastructureFile and never prompts: <Type>' -ForEach @(
        @{ Type = 'PowerShell'; Name = 'Set-Thing' }
        @{ Type = 'AzurePowerShell'; Name = 'Set-AzThing' }
        @{ Type = 'AzureCliPowerShell'; Name = 'Thing' }
        @{ Type = 'InvokeScript'; Name = 'Thing' }
    ) {
        $path = Invoke-Template $Type $Name
        $errors = $null; $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'InfrastructureFile' }
        $parameter | Should -Not -BeNullOrEmpty
        $parameter.Attributes.NamedArguments.ArgumentName | Should -Contain 'Mandatory'
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match 'Does the thing'
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Match 'Import-AzlInfrastructure'
        ((($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')) | Should -Not -Match 'Read-Host|Get-Credential|ConfigPath|ConvertFrom-Yaml'
    }

    It 'checks the tenant of azure.tenant_id and does not sign in, for the Azure types' {
        foreach ($case in @(@('AzurePowerShell', 'Set-AzThing', 'Get-AzContext'), @('AzureCliPowerShell', 'Thing', 'az account show'))) {
            $text = Get-Content -LiteralPath (Invoke-Template $case[0] $case[1]) -Raw
            $text | Should -Match 'azure\.tenant_id'
            $text | Should -Match ([regex]::Escape($case[2]))
            $text | Should -Not -Match '(?m)^\s*(\$null = )?(Connect-AzAccount|az login)\b'
        }
    }

    It 'has no Bash type any more' {
        { & $script:Template -ScriptType AzureCliBash -Name Thing -Description 'x' -OutputPath $TestDrive } | Should -Throw
        (Get-Content -LiteralPath $script:Template -Raw) | Should -Not -Match '#!/bin/bash|-Standalone'
    }
}
