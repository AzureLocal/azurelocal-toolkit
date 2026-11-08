#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Category azure: the tenant and subscription, the 13 resource providers (and -Fix), the roles and permissions, Key Vault, names, Arc machines,
# the leftovers of earlier deployments. Every failure Azure returned in this project is a check. Fakes only.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake adapter members and mock script blocks keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    foreach ($m in 'infrastructure\AzlInfrastructure.psm1', 'azure-local\AzlAzure.psm1', 'arm-deployment\AzlArmDeployment.psm1', 'arm-deployment\AzlArmDeploymentRun.psm1', 'arm-deployment\AzlPreClusterGate.psm1', 'arm-deployment\AzlPreClusterVerification.psm1') {
        Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Force
    }
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'PreClusterVerification.Helpers.ps1'))
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
    $script:Mandatory = @(
        'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.AzureStackHCI', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
        'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector', 'Microsoft.HybridContainerService', 'Microsoft.Attestation', 'Microsoft.Storage', 'Microsoft.Insights', 'Microsoft.KeyVault'
    )
}

Describe 'AZR-001 the Azure context (wrong tenant)' {
    It 'passes for the tenant and subscription of the file' {
        (Get-PclCheck (Invoke-PclRun) 'AZR-001').Status | Should -Be 'Passed'
    }
    It 'fails for another tenant, and names both' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Context = 'wrongTenant'
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-001'
        $c.Status | Should -Be 'Failed'
        $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'tenant 22222222'
        $c.Message | Should -Match 'the file says 00000000'
        $c.Remedy | Should -Match 'Connect-AzAccount -Tenant'
    }
    It 'fails for another subscription' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Context = 'wrongSubscription'
        (Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-001').Message | Should -Match 'subscription 11111111'
    }
    It 'fails when nobody is signed in, and every Azure check is then Skipped and blocks' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Context = 'none'
        $r = Invoke-PclRun -World $w -Infra $infra
        (Get-PclCheck $r 'AZR-001').Status | Should -Be 'Failed'
        foreach ($id in 'AZR-002', 'AZR-003', 'AZR-004', 'AZR-008', 'AZR-010') {
            $c = Get-PclCheck $r $id
            $c.Status | Should -Be 'Skipped' -Because $id
            $c.Blocking | Should -BeTrue
        }
        $r.Verdict | Should -Be 'Fail'
    }
}

Describe 'AZR-004 the 13 mandatory resource providers' {
    It 'evaluates all 13 and lists them in the details' {
        $c = Get-PclCheck (Invoke-PclRun) 'AZR-004'
        $c.Status | Should -Be 'Passed'
        $c.Details.Count | Should -Be 13
        foreach ($ns in $script:Mandatory) { ($c.Details -join ' ') | Should -Match ([regex]::Escape($ns)) }
    }
    It 'fails for each missing provider with the exact Register-AzResourceProvider command (HybridContainerService and KeyVault among them)' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Providers['Microsoft.HybridContainerService'] = 'NotRegistered'; $w.Providers['Microsoft.KeyVault'] = 'Registering'
        $r = Invoke-PclRun -World $w -Infra $infra
        $c = Get-PclCheck $r 'AZR-004'
        $c.Status | Should -Be 'Failed'
        $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'Microsoft\.HybridContainerService \(NotRegistered\)'
        $c.Message | Should -Match 'Microsoft\.KeyVault \(Registering\)'
        $c.Message | Should -Match 'ValidateArcIntegration'
        $c.Remedy | Should -Match 'Register-AzResourceProvider -ProviderNamespace Microsoft\.HybridContainerService; Register-AzResourceProvider -ProviderNamespace Microsoft\.KeyVault'
        $w.Registered.Count | Should -Be 0
    }
    It 'fails for every one of the 13 on its own' -ForEach (@(
            'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.AzureStackHCI', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
            'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector', 'Microsoft.HybridContainerService', 'Microsoft.Attestation', 'Microsoft.Storage', 'Microsoft.Insights', 'Microsoft.KeyVault') | ForEach-Object { @{ Ns = $_ } }) {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Providers[$Ns] = 'NotRegistered'
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra -Category azure) 'AZR-004'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match ([regex]::Escape($Ns))
    }
    It 'registers nothing without -Fix, and not in Mode Plan even with -Fix' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Providers['Microsoft.KeyVault'] = 'NotRegistered'
        $null = Invoke-PclRun -World $w -Infra $infra
        $null = Invoke-PclRun -World $w -Infra $infra -Mode Plan -Fix
        $w.Registered.Count | Should -Be 0
        $w.Calls | Should -Not -Contain 'RegisterProvider:Microsoft.KeyVault'
    }
    It 'with -Fix registers only the missing providers, waits until they are Registered and reports Fixed' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Providers['Microsoft.KeyVault'] = 'NotRegistered'; $w.Providers['Microsoft.Insights'] = 'NotRegistered'
        $r = Invoke-PclRun -World $w -Infra $infra -Fix
        @($w.Registered | Sort-Object) | Should -Be @('Microsoft.Insights', 'Microsoft.KeyVault')
        $c = Get-PclCheck $r 'AZR-004'
        $c.Status | Should -Be 'Fixed'
        $c.Blocking | Should -BeFalse
        $c.Message | Should -Match 'Registered by -Fix'
        $r.Verdict | Should -Be 'Pass'
        (Get-Content $r.ReportPath -Raw | ConvertFrom-Json).fixesApplied | Should -BeTrue
    }
    It 'with -Fix leaves an Registering provider alone and waits for it' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Providers['Microsoft.KeyVault'] = 'Registering'
        $script:Reads = 0
        $r = Invoke-PclRun -World $w -Infra $infra -Fix -Override @{ GetProviderState = { param($Subscription, $Namespace) if ($Namespace -eq 'Microsoft.KeyVault') { $script:Reads++; if ($script:Reads -ge 4) { 'Registered' } else { 'Registering' } } else { 'Registered' } } }
        $w.Registered.Count | Should -Be 0
        (Get-PclCheck $r 'AZR-004').Status | Should -Be 'Fixed'
        $w.Clock.Sleeps.Count | Should -BeGreaterThan 0
    }
    It 'with -Fix fails, with the message, when registering is refused' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Providers['Microsoft.KeyVault'] = 'NotRegistered'; $w.RegisterFails = @('Microsoft.KeyVault')
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra -Fix) 'AZR-004'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'AuthorizationFailed'
    }
    It 'with -Fix fails when the provider does not exist in the cloud' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Providers['Microsoft.Attestation'] = 'NotFound'
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra -Fix) 'AZR-004'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'cannot be registered'
    }
}

Describe 'AZR-005 to AZR-007 permissions and roles' {
    It 'passes with Owner and the Key Vault Secrets Officer role' {
        $r = Invoke-PclRun
        (Get-PclCheck $r 'AZR-005').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'AZR-006').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'AZR-007').Status | Should -Be 'Passed'
    }
    It 'fails on the subscription without User Access Administrator, with the role assignment command' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Roles = @('Contributor')
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-005'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'User Access Administrator'
        $c.Remedy | Should -Match "New-AzRoleAssignment .*'User Access Administrator'"
    }
    It 'fails when the effective permissions lack Microsoft.Authorization/roleAssignments/write' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Permissions = @('Microsoft.Resources/*', 'Microsoft.AzureStackHCI/*', 'Microsoft.KeyVault/*', 'Microsoft.Storage/*', 'Microsoft.HybridCompute/*', 'Microsoft.Authorization/roleAssignments/read')
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-006'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'Microsoft\.Authorization/roleAssignments/write'
    }
    It 'lists the roles of Learn that are missing on the resource group' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.Roles = @('Contributor', 'User Access Administrator', 'Reader')
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-007'
        $c.Status | Should -Be 'Failed'
        foreach ($role in 'Azure Stack HCI Administrator', 'Key Vault Data Access Administrator', 'Key Vault Secrets Officer', 'Key Vault Contributor', 'Storage Account Contributor', 'Azure Connected Machine Onboarding', 'Azure Connected Machine Resource Administrator') { $c.Message | Should -Match $role }
        $c.Remedy | Should -Match "New-AzRoleAssignment .*-ResourceGroupName 'rg-iic-azl-01'"
    }
    It 'is Skipped, not passed, when the roles cannot be read' {
        $c = Get-PclCheck (Invoke-PclRun -Override @{ GetCallerRoles = { throw 'AuthorizationFailed' } }) 'AZR-005'
        $c.Status | Should -Be 'Skipped'
        $c.Blocking | Should -BeTrue
    }
}

Describe 'AZR-008 and AZR-009 Key Vault secrets and names' {
    It 'fails for a secret that is not in the vault, naming the reference' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.MissingSecrets = @('lcm-password')
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-008'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'secret lcm-password is not in vault kv-iic-mgmt-01'
    }
    It 'fails for a vault that is not listed under key_vaults' {
        $infra = Get-PclInfra
        $infra.identity.local_admin.password = 'keyvault://kv-unlisted/pw'
        $c = Get-PclCheck (Invoke-PclRun -Infra $infra) 'AZR-008'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'kv-unlisted is not listed'
    }
    It 'fails for a storage account name that is taken, with the reason Azure gives' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra; $w.NameTaken = @('stiicazl01diag')
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-009'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'stiicazl01diag'
        $c.Message | Should -Match 'already in use'
    }
    It 'fails for a storage account name that cannot be one' {
        $infra = Get-PclInfra
        $infra.cluster.witness.storage_account = 'St-Invalid_Name'
        (Get-PclCheck (Invoke-PclRun -Infra $infra) 'AZR-009').Message | Should -Match 'not a valid storage account name'
    }
}

Describe 'AZR-010 to AZR-012 and AZR-016 Arc machines' {
    It 'fails for a machine that is not Connected, and for a missing one' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.ArcMachines['iic-n01'] = [pscustomobject]@{ Name = 'iic-n01'; ResourceId = "/subscriptions/$($infra.azure.subscription_id)/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/iic-n01"; Status = 'Disconnected'; OsVersion = ''; ComputerName = 'iic-n01' }
        $r = Invoke-PclRun -World $w -Infra $infra -Override @{ GetArcMachine = { param($Node, $ResourceId, $ArcMachineName, $Subscription, $ResourceGroup) if ($Node -eq 'iic-n02') { return $null }; $w.ArcMachines[$Node] }.GetNewClosure() }
        (Get-PclCheck $r 'AZR-010' 'iic-n01').Status | Should -Be 'Failed'
        (Get-PclCheck $r 'AZR-010' 'iic-n01').Message | Should -Match "status is 'Disconnected'"
        (Get-PclCheck $r 'AZR-010' 'iic-n02').Message | Should -Match 'No Arc machine found'
    }
    It 'fails for a machine in another resource group' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.ArcMachines['iic-n01'] = [pscustomobject]@{ Name = 'iic-n01'; ResourceId = "/subscriptions/$($infra.azure.subscription_id)/resourceGroups/rg-other/providers/Microsoft.HybridCompute/machines/iic-n01"; Status = 'Connected'; OsVersion = ''; ComputerName = 'iic-n01' }
        (Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-010' 'iic-n01').Message | Should -Match 'resource group rg-other, not rg-iic-azl-01'
    }
    It 'fails for a node that is also an Arc machine in another resource group (Arc integration validator)' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.ArcElsewhere['iic-n02'] = @([pscustomobject]@{ Name = 'iic-n02'; ResourceId = '/subscriptions/x/resourceGroups/rg-old/providers/Microsoft.HybridCompute/machines/iic-n02'; ResourceGroup = 'rg-old'; Status = 'Disconnected' })
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-012' 'iic-n02'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'rg-old/iic-n02'
    }
    It 'fails on the known issue arc-device-id-name, and warns when the operator acknowledges it' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.ArcMachines['iic-n01'] = [pscustomobject]@{ Name = '8a1b2c3d4e5f60718293a4b5c6d7e8f9-1'; ResourceId = "/subscriptions/$($infra.azure.subscription_id)/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/8a1b2c3d4e5f60718293a4b5c6d7e8f9-1"; Status = 'Connected'; OsVersion = ''; ComputerName = 'iic-n01' }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-011' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'arc-device-id-name'
        $w2 = Initialize-PclWorld -Infra $infra; $w2.ArcMachines = $w.ArcMachines
        $c2 = Get-PclCheck (Invoke-PclRun -World $w2 -Infra $infra -AcknowledgeKnownIssues 'arc-device-id-name') 'AZR-011' 'iic-n01'
        $c2.Status | Should -Be 'Warning'
        $c2.Message | Should -Match 'Acknowledged'
    }
    It 'fails when the Windows update extension is on an Arc machine' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $id = "/subscriptions/$($infra.azure.subscription_id)/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/iic-n01"
        $w.ArcExtensions[$id] = @([pscustomobject]@{ Name = 'WindowsOsUpdateExtension'; Type = 'WindowsOsUpdateExtension' })
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-016' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'causes a deployment failure'
    }
}

Describe 'AZR-013 to AZR-015 what earlier deployments left behind' {
    It 'fails on a failed deployment state (another Validate would reset the license sync)' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.DeploymentState = Get-TestState -Prov 'Failed' -Validation 'Succeeded' -Deployment 'Failed'
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-013'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'license sync'
        $c.Remedy | Should -Match '-Mode Deploy -Resume'
    }
    It 'fails on zombie role assignments (identity not found) and names them' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.RoleAssignments = @([pscustomobject]@{ Role = 'Azure Stack HCI Device Management Role'; PrincipalId = 'aaaaaaaa-0000-0000-0000-000000000001'; PrincipalType = 'Unknown'; DisplayName = ''; Scope = 'x' })
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-014'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'Identity not found'
        $c.Message | Should -Match 'aaaaaaaa-0000'
        $c.Remedy | Should -Match 'Remove-AzRoleAssignment'
    }
    It 'fails on a Device Management Role assignment left by an earlier portal deployment when the cluster does not exist yet (role-assignment-already-exists)' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.RoleAssignments = @([pscustomobject]@{ Role = 'Azure Stack HCI Device Management Role'; PrincipalId = 'bbbbbbbb-0000-0000-0000-000000000002'; PrincipalType = 'ServicePrincipal'; DisplayName = 'old-cluster'; Scope = 'x' })
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'AZR-015'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'RoleAssignmentExists'
    }
    It 'passes both when the resource group is clean' {
        $r = Invoke-PclRun
        (Get-PclCheck $r 'AZR-014').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'AZR-015').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'AZR-013').Status | Should -Be 'Passed'
    }
}

Describe 'AZR-017 the ARM parameters' {
    It 'fails, naming the key, when the file cannot produce the parameters' {
        $infra = Get-PclInfra
        $infra.identity.local_admin.username = ''
        $c = Get-PclCheck (Invoke-PclRun -Infra $infra) 'AZR-017'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'identity.local_admin.username is empty'
    }
    It 'fails for the built-in Administrator as the local administrator' {
        $infra = Get-PclInfra
        $infra.identity.local_admin.username = 'Administrator'
        (Get-PclCheck (Invoke-PclRun -Infra $infra) 'AZR-017').Message | Should -Match 'built-in'
    }
}
