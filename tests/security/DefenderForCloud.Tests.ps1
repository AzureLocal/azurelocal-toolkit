#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (security and governance), task 01: Enable-DefenderForCloud.ps1 puts the free level of Microsoft Defender for Cloud in place from the keys
# security.defender_for_cloud.* of infrastructure.yml. Every Az cmdlet is a stub or a mock: no Azure, no tenant and no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/security/DefenderForCloud.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-04-security-governance', 'task-01-enable-defender-for-cloud', 'powershell', 'Enable-DefenderForCloud.ps1')
    Import-Module powershell-yaml

    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function Register-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function Get-AzPolicyAssignment { [CmdletBinding()] param([string]$Scope) }
    function Get-AzPolicySetDefinition { [CmdletBinding()] param([string]$Id) }
    function New-AzPolicyAssignment { [CmdletBinding()] param([string]$Name, [string]$DisplayName, [string]$Scope, [object]$PolicySetDefinition) }
    function Invoke-AzRestMethod { [CmdletBinding()] param([string]$Method, [string]$Path, [string]$Payload) }

    $global:AzlDfcTenant = [guid]::NewGuid().ToString()
    $global:AzlDfcSub = [guid]::NewGuid().ToString()
    $global:AzlDfcHome = [guid]::NewGuid().ToString()
    $global:AzlDfcProviderState = 'NotRegistered'
    $global:AzlDfcAssignments = @()
    $global:AzlDfcContactStatus = 404

    function New-InfraFile {
        param([hashtable]$Defender, [hashtable]$Azure = @{})
        $az = [ordered]@{ tenant_id = $global:AzlDfcTenant; subscription_id = $global:AzlDfcSub }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{ azure = $az }
        if ($Defender) { $doc.security = [ordered]@{ defender_for_cloud = $Defender } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Defender([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Row($Result, [string]$Item) { @($Result.Rows | Where-Object Item -EQ $Item)[0] }
}

AfterAll { Remove-Variable -Name AzlDfcTenant, AzlDfcSub, AzlDfcHome, AzlDfcProviderState, AzlDfcAssignments, AzlDfcContactStatus -Scope Global -ErrorAction SilentlyContinue }

Describe 'Enable-DefenderForCloud.ps1' {
    BeforeEach {
        $global:AzlDfcProviderState = 'NotRegistered'
        $global:AzlDfcAssignments = @()
        $global:AzlDfcContactStatus = 404
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlDfcTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlDfcHome } } }
        Mock Set-AzContext { }
        Mock Get-AzResourceProvider { [pscustomobject]@{ RegistrationState = $global:AzlDfcProviderState } }
        Mock Register-AzResourceProvider { $global:AzlDfcProviderState = 'Registered'; [pscustomobject]@{ RegistrationState = 'Registering' } }
        Mock Get-AzPolicyAssignment { $global:AzlDfcAssignments }
        Mock Get-AzPolicySetDefinition { [pscustomobject]@{ Id = $Id } }
        Mock New-AzPolicyAssignment { [pscustomobject]@{ Name = $Name } }
        Mock Invoke-AzRestMethod {
            if ($Method -eq 'GET') { return [pscustomobject]@{ StatusCode = $global:AzlDfcContactStatus; Content = '' } }
            [pscustomobject]@{ StatusCode = 200; Content = '' }
        }
    }

    Context 'putting the free level in place' {
        It 'registers Microsoft.Security, assigns the benchmark and reads the contact; the subscription of the session is set and put back' {
            $r = Invoke-Defender (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Row $r 'Foundational CSPM').Action | Should -Be 'Registered'
            (Get-Row $r 'Cloud security benchmark').Action | Should -Be 'Assigned'
            (Get-Row $r 'Security contact').Action | Should -Be 'Skipped'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlDfcSub }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlDfcHome }
            Should -Invoke Register-AzResourceProvider -Times 1 -Exactly -ParameterFilter { $ProviderNamespace -eq 'Microsoft.Security' }
            Should -Invoke New-AzPolicyAssignment -Times 1 -Exactly -ParameterFilter { $Name -eq 'SecurityCenterBuiltIn' -and $Scope -eq "/subscriptions/$($global:AzlDfcSub)" }
            $r.Text | Should -Match 'No paid Defender plan'
        }

        It 'sets the security contact when the file names one and the subscription has none' {
            $r = Invoke-Defender (New-InfraFile @{ security_contact_email = 'security@improbability.cloud; noc@improbability.cloud' })
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Row $r 'Security contact').Action | Should -Be 'Set'
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Payload -match 'security@improbability.cloud;noc@improbability.cloud' }
        }

        It 'never replaces a contact that exists' {
            $global:AzlDfcContactStatus = 200
            $r = Invoke-Defender (New-InfraFile @{ security_contact_email = 'security@improbability.cloud' })
            (Get-Row $r 'Security contact').Action | Should -Be 'Exists'
            Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        }
    }

    Context 'everything is in place (idempotent)' {
        It 'changes nothing' {
            $global:AzlDfcProviderState = 'Registered'
            $global:AzlDfcAssignments = @([pscustomobject]@{ Name = 'any'; PolicyDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8' })
            $r = Invoke-Defender (New-InfraFile)
            $r.ExitCode | Should -Be 0
            (Get-Row $r 'Foundational CSPM').Action | Should -Be 'Exists'
            (Get-Row $r 'Cloud security benchmark').Action | Should -Be 'Exists'
            Should -Invoke Register-AzResourceProvider -Times 0 -Exactly
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }

        It 'stops with exit code 2 and replaces nothing when the assignment name is taken by another definition' {
            $global:AzlDfcProviderState = 'Registered'
            $global:AzlDfcAssignments = @([pscustomobject]@{ Name = 'SecurityCenterBuiltIn'; PolicyDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/other' })
            $r = Invoke-Defender (New-InfraFile)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'points at another definition'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }
    }

    Context '-WhatIf and the switches' {
        It 'plans the three changes and changes nothing under -WhatIf' {
            $r = Invoke-Defender (New-InfraFile @{ security_contact_email = 'security@improbability.cloud' }) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Row $r 'Foundational CSPM').Action | Should -Be 'WouldRegister'
            (Get-Row $r 'Cloud security benchmark').Action | Should -Be 'WouldAssign'
            (Get-Row $r 'Security contact').Action | Should -Be 'WouldSet'
            Should -Invoke Register-AzResourceProvider -Times 0 -Exactly
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
            Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        }

        It 'does nothing and does not touch Azure when enabled is false' {
            $r = Invoke-Defender (New-InfraFile @{ enabled = $false })
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'is false: nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'does not assign the benchmark when apply_cloud_security_benchmark is false' {
            $global:AzlDfcProviderState = 'Registered'
            $r = Invoke-Defender (New-InfraFile @{ apply_cloud_security_benchmark = $false })
            $r.ExitCode | Should -Be 0
            (Get-Row $r 'Cloud security benchmark').Action | Should -Be 'Skipped'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a missing azure.tenant_id'; Settings = @{ Azure = @{ tenant_id = $null } } }
            @{ Why = 'a missing azure.subscription_id'; Settings = @{ Azure = @{ subscription_id = $null } } }
            @{ Why = 'the all-zero subscription'; Settings = @{ Azure = @{ subscription_id = '00000000-0000-0000-0000-000000000000' } } }
            @{ Why = 'an enabled value that is not true or false'; Settings = @{ Defender = @{ enabled = 'maybe' } } }
            @{ Why = 'a contact that is not an address'; Settings = @{ Defender = @{ security_contact_email = 'not-an-address' } } }
        ) {
            $r = Invoke-Defender (New-InfraFile @Settings)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke Register-AzResourceProvider -Times 0 -Exactly
        }

        It 'refuses a file that cannot be read' {
            $r = Invoke-Defender (Join-Path $TestDrive 'missing.yml')
            $r.ExitCode | Should -Be 2
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Defender (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Defender (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke Register-AzResourceProvider -Times 0 -Exactly
        }

        It 'reports a failed registration, still reads the rest, puts the subscription back and exits 1' {
            Mock Register-AzResourceProvider { throw 'Authorization failed.' }
            $r = Invoke-Defender (New-InfraFile)
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'Foundational CSPM').Action | Should -Be 'Failed'
            (Get-Row $r 'Cloud security benchmark').Action | Should -Be 'Assigned'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlDfcHome }
        }

        It 'reports a security contact that cannot be read' {
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 403; Content = '' } }
            $r = Invoke-Defender (New-InfraFile @{ security_contact_email = 'security@improbability.cloud' })
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'Security contact').Action | Should -Be 'Failed'
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            $script:Code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Code | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|ConfigPath|ConvertFrom-Yaml'
        }

        It 'takes -InfrastructureFile, mandatory, and nothing that names a subscription' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
            $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $names | Should -Contain 'InfrastructureFile'
            $names | Should -Not -Contain 'SubscriptionId'
            $names | Should -Not -Contain 'ConfigPath'
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.subscription_id', 'security.defender_for_cloud.enabled', 'security.defender_for_cloud.apply_cloud_security_benchmark', 'security.defender_for_cloud.security_contact_email' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
            $script:Text | Should -Match ([regex]::Escape($_))
        }

        It 'turns on no paid plan and holds no GUID but the ID of the benchmark initiative, which Microsoft fixes' {
            $script:Code | Should -Not -Match 'Set-AzSecurityPricing|pricings|auto-provisioning|AutoProvisioning'
            $guids = @([regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}') | ForEach-Object Value)
            $guids | Should -Be @('1f3afdf9-d0c9-4c3d-847f-89da613e70a8')
        }
    }
}
