#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 03 (RBAC and permissions), task 01: New-AutomationManagedIdentity.ps1 creates the user-assigned managed identity that azure.automation_identity names.
# Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Tenant, subscription and identity ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/AutomationManagedIdentity.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-03-rbac-permissions', 'task-01-create-azure-local-deployment-spn', 'powershell', 'New-AutomationManagedIdentity.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzUserAssignedIdentity { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$SubscriptionId) }
    function New-AzUserAssignedIdentity { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$SubscriptionId, [hashtable]$Tag) }

    $global:AzlMiTestTenant = [guid]::NewGuid().ToString()
    $global:AzlMiTestSub = [guid]::NewGuid().ToString()
    $global:AzlMiTestIdentitySub = [guid]::NewGuid().ToString()
    $global:AzlMiTestClient = [guid]::NewGuid().ToString()
    $global:AzlMiTestPrincipal = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object]$Identity = (New-Identity), [object]$TenantId = $global:AzlMiTestTenant, [string]$Location = 'eastus', [object]$SubscriptionId = $global:AzlMiTestSub,
            [string]$ResourceGroup = 'rg-azl-01', [object]$Tags = $null)
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($Location) { $doc.azure.location = $Location }
        if ($null -ne $SubscriptionId) { $doc.azure.subscription_id = $SubscriptionId }
        if ($ResourceGroup) { $doc.azure.resource_group = $ResourceGroup }
        if ($null -ne $Identity) { $doc.azure.automation_identity = $Identity }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Identity([hashtable]$Override = @{}) {
        $i = [ordered]@{ type = 'managed_identity'; name = 'id-azl-automation-01' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $i.Remove($k) } else { $i[$k] = $Override[$k] } }
        $i
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Identity([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['PrincipalId'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'New-AutomationManagedIdentity.ps1' {
    AfterAll {
        Remove-Variable -Name AzlMiTestTenant, AzlMiTestSub, AzlMiTestIdentitySub, AzlMiTestClient, AzlMiTestPrincipal -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlMiTestTenant } } }
        Mock Get-AzUserAssignedIdentity { throw 'The Resource ''Microsoft.ManagedIdentity/userAssignedIdentities/x'' under resource group ''rg'' was not found. (ResourceNotFound)' }
        Mock New-AzUserAssignedIdentity { [pscustomobject]@{ Name = $Name; ClientId = $global:AzlMiTestClient; PrincipalId = $global:AzlMiTestPrincipal; Location = $Location } }
    }

    Context 'creating the identity (happy path)' {
        It 'creates the identity in the resource group and region of the file and reports its ids' {
            $r = Invoke-Identity (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Result.Action | Should -Be 'Created'
            $r.Result.ClientId | Should -Be $global:AzlMiTestClient
            $r.Result.PrincipalId | Should -Be $global:AzlMiTestPrincipal
            Should -Invoke New-AzUserAssignedIdentity -Times 1 -Exactly -ParameterFilter { $Name -eq 'id-azl-automation-01' -and $ResourceGroupName -eq 'rg-azl-01' -and $Location -eq 'eastus' -and $SubscriptionId -eq $global:AzlMiTestSub }
            $r.Text | Should -Match 'azure\.automation_identity\.client_id'
        }

        It 'uses the subscription and resource group of the entry when it has them' {
            $null = Invoke-Identity (New-InfraFile -Identity (New-Identity @{ subscription_id = $global:AzlMiTestIdentitySub; resource_group = 'rg-devops-01' }))
            Should -Invoke Get-AzUserAssignedIdentity -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-devops-01' -and $SubscriptionId -eq $global:AzlMiTestIdentitySub }
            Should -Invoke New-AzUserAssignedIdentity -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-devops-01' -and $SubscriptionId -eq $global:AzlMiTestIdentitySub }
        }

        It 'puts the file-level tags on the identity' {
            $null = Invoke-Identity (New-InfraFile -Tags ([ordered]@{ environment = 'lab'; owner = 'team' }))
            Should -Invoke New-AzUserAssignedIdentity -Times 1 -Exactly -ParameterFilter { $Tag -and $Tag['environment'] -eq 'lab' -and $Tag['owner'] -eq 'team' }
        }

        It 'sends no tags when the file has none' {
            $null = Invoke-Identity (New-InfraFile)
            Should -Invoke New-AzUserAssignedIdentity -Times 1 -Exactly -ParameterFilter { -not $Tag }
        }

        It 'treats a not-found error from the lookup as "no identity yet"' {
            Mock Get-AzUserAssignedIdentity { throw 'Response status code does not indicate success: 404 (Not Found).' }
            (Invoke-Identity (New-InfraFile)).Result.Action | Should -Be 'Created'
        }

        It 'treats a lookup that returns nothing as "no identity yet"' {
            Mock Get-AzUserAssignedIdentity { $null }
            (Invoke-Identity (New-InfraFile)).Result.Action | Should -Be 'Created'
        }

        It 'creates nothing else: no role is assigned and no resource group is created' {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            $script:Text | Should -Not -Match 'New-AzRoleAssignment|New-AzResourceGroup'
        }
    }

    Context 'the identity already exists (idempotent)' {
        It 'creates nothing and reports the ids' {
            Mock Get-AzUserAssignedIdentity { [pscustomobject]@{ Name = $Name; ClientId = $global:AzlMiTestClient; PrincipalId = $global:AzlMiTestPrincipal; Location = 'eastus' } }
            $r = Invoke-Identity (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'AlreadyExists'
            $r.Result.ClientId | Should -Be $global:AzlMiTestClient
            Should -Invoke New-AzUserAssignedIdentity -Times 0 -Exactly
            $r.Text | Should -Match 'nothing changed'
        }

        It 'reports a region that differs from azure.location, and changes nothing' {
            Mock Get-AzUserAssignedIdentity { [pscustomobject]@{ Name = $Name; ClientId = $global:AzlMiTestClient; PrincipalId = $global:AzlMiTestPrincipal; Location = 'westus2' } }
            $r = Invoke-Identity (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Detail | Should -Match 'region is westus2'
            Should -Invoke New-AzUserAssignedIdentity -Times 0 -Exactly
        }

        It 'compares regions without regard to case or spaces' {
            Mock Get-AzUserAssignedIdentity { [pscustomobject]@{ Name = $Name; ClientId = $global:AzlMiTestClient; PrincipalId = $global:AzlMiTestPrincipal; Location = 'East US' } }
            (Invoke-Identity (New-InfraFile)).Result.Detail | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf' {
        It 'plans the identity and creates nothing' {
            $r = Invoke-Identity (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzUserAssignedIdentity -Times 0 -Exactly
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'mi.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
            Should -Invoke New-AzUserAssignedIdentity -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without azure.automation_identity' {
            $r = Invoke-Identity (New-InfraFile -Identity $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'automation_identity is missing'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a service principal: the CI/CD bootstrap creates that one' {
            $r = Invoke-Identity (New-InfraFile -Identity (New-Identity @{ type = 'service_principal' }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'service_principal'
            Should -Invoke New-AzUserAssignedIdentity -Times 0 -Exactly
        }

        It 'refuses a missing or unknown type: <_>' -ForEach $null, 'user' {
            $r = Invoke-Identity (New-InfraFile -Identity (New-Identity @{ type = $_ }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'is missing or is not managed_identity'
        }

        It 'refuses a missing name' {
            $r = Invoke-Identity (New-InfraFile -Identity (New-Identity @{ name = $null }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'automation_identity.name is missing'
        }

        It 'refuses a name Azure does not accept: <_>' -ForEach 'ab', '-leading', 'has space', 'bad!name' {
            $r = Invoke-Identity (New-InfraFile -Identity (New-Identity @{ name = $_ }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'not a valid managed identity name'
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Identity (New-InfraFile -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses a file with no usable subscription anywhere' {
            $r = Invoke-Identity (New-InfraFile -SubscriptionId ([guid]::Empty.ToString()))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'No usable subscription'
        }

        It 'refuses a file with no resource group anywhere' {
            $r = Invoke-Identity (New-InfraFile -ResourceGroup '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'No resource group'
        }

        It 'refuses a file with no region' {
            $r = Invoke-Identity (New-InfraFile -Location '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.location is missing'
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Identity (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Identity (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzUserAssignedIdentity -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Identity (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzUserAssignedIdentity -Times 0 -Exactly
        }

        It 'stops when the resource group does not exist, and says which task creates it' {
            Mock Get-AzUserAssignedIdentity { throw "Resource group 'rg-azl-01' could not be found." }
            $r = Invoke-Identity (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'resource group .* does not exist'
            Should -Invoke New-AzUserAssignedIdentity -Times 0 -Exactly
        }

        It 'reports a resource group that is missing when the creation says so' {
            Mock New-AzUserAssignedIdentity { throw 'ResourceGroupNotFound: Resource group ''rg-azl-01'' could not be found.' }
            $r = Invoke-Identity (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Action | Should -Be 'Failed'
            $r.Result.Detail | Should -Match 'Create it first'
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzUserAssignedIdentity { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Identity (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Action | Should -Be 'Failed'
            $r.Result.Detail | Should -Match 'authorization'
            Should -Invoke New-AzUserAssignedIdentity -Times 0 -Exactly
        }

        It 'reports a failed creation and exits 1' {
            Mock New-AzUserAssignedIdentity { throw 'AuthorizationFailed' }
            $r = Invoke-Identity (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Detail | Should -Match 'AuthorizationFailed'
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
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_AutomationManagedIdentity_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'azure.location', 'azure.subscription_id', 'azure.resource_group', 'azure.automation_identity.type', 'azure.automation_identity.name',
                'azure.automation_identity.subscription_id', 'azure.automation_identity.resource_group') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
            @($registry | Where-Object Path -EQ 'tags').Count | Should -BeGreaterOrEqual 1
        }
    }
}
