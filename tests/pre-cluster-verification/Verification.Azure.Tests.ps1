#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Pre-cluster verification, category azure (AZ-001 to AZ-023): every check passes, fails and is skipped with fake adapters.
# No test touches Azure: every read goes through $Context.Adapters.Azure, and the adapter here is a table of fakes.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake adapter members keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A fake credential for a test; nothing real.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    foreach ($m in 'infrastructure\AzlInfrastructure.psm1', 'azure-local\AzlAzure.psm1', 'arm-deployment\AzlArmDeployment.psm1', 'arm-deployment\AzlArmDeploymentRun.psm1', 'arm-deployment\verification\AzlVerification.Azure.psm1') {
        Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Force
    }
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, '..', 'arm-deployment', 'ArmDeploymentRun.Helpers.ps1'))
    $script:Defs = @{}
    foreach ($d in Get-AzlVerificationCheckDefinition) { $script:Defs[$d.Id] = $d }
    $script:Secret = 'Sup3r-S3cret-Value!'
    $script:Mandatory = @(
        'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.AzureStackHCI', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
        'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector', 'Microsoft.HybridContainerService', 'Microsoft.Attestation', 'Microsoft.Storage', 'Microsoft.Insights', 'Microsoft.KeyVault'
    )

    function New-AzAdapter {
        <# A healthy pretend Azure. -Override replaces members (a $null member is "not available here"). #>
        param([hashtable]$Override = @{}, [hashtable]$Log)
        if (-not $Log) { $Log = @{} }
        $log = $Log
        $a = [ordered]@{
            Now               = { [datetime]::Parse('2026-11-08T12:00:00Z', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
            Sleep             = { param($Seconds) }
            GetContext        = { [pscustomobject]@{ SubscriptionId = '00000000-0000-0000-0000-000000000000'; TenantId = '00000000-0000-0000-0000-000000000000'; Account = 'tester@example.invalid' } }
            GetResourceGroup  = { [pscustomobject]@{ name = 'rg-iic-azl-01' } }
            GetProviderState  = { param($Subscription, $Namespace) $log['Providers'] = @(@($log['Providers']) | Where-Object { $_ }) + $Namespace; 'Registered' }.GetNewClosure()
            RegisterProvider  = { param($Subscription, $Namespace) $log['Registered'] = $true }.GetNewClosure()
            GetPermission     = { , @([pscustomobject]@{ Actions = @('*'); NotActions = @() }) }
            TestNameAvailable = { [pscustomobject]@{ Available = $true; ExistsInResourceGroup = $false; Reason = '' } }
            TestSecret        = { $true }
            GetArcMachine     = {
                param($Node, $ResourceId, $ArcMachineName, $Subscription, $ResourceGroup)
                [pscustomobject]@{ Name = $Node; ResourceId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$Node"; Status = 'Connected'; OsVersion = '10.0.26100.32230'; ComputerName = $Node }
            }
            GetDeploymentState = { $null }
            GetSubscription   = { [pscustomobject]@{ State = 'Enabled'; TenantId = '00000000-0000-0000-0000-000000000000'; DisplayName = 'lab' } }
            GetCallerRoles    = { param($Scope) , @([pscustomobject]@{ Role = 'Owner'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000' }, [pscustomobject]@{ Role = 'Key Vault Secrets Officer'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000' }) }
            GetPrincipalRoles = { param($ObjectId, $Scope) , @([pscustomobject]@{ Role = 'Azure Connected Machine Resource Manager'; Scope = $Scope }) }
            ListRoleAssignments = { param($Scope) , @([pscustomobject]@{ Role = 'Owner'; PrincipalId = '11111111-0000-0000-0000-000000000001'; PrincipalType = 'User'; DisplayName = 'Tester'; Scope = $Scope }) }
            GetHciResourceProviderObjectId = { '00000000-0000-0000-0000-000000000001' }
            GetKeyVault       = { param($Vault, $Subscription, $ResourceGroup) [pscustomobject]@{ Name = $Vault; ResourceGroup = 'rg-iic-mgmt-01'; VaultUri = "https://$Vault.vault.azure.net/"; EnableRbacAuthorization = $true; PublicNetworkAccess = 'Enabled' } }
            GetKeyVaultSecret = {
                param($Vault, $Secret)
                $log['Reads'] = @(@($log['Reads']) | Where-Object { $_ }) + "$Vault/$Secret"
                if ($Secret -eq 'local-admin-username') { return 'azl-admin' }
                return 'Sup3r-S3cret-Value!'
            }.GetNewClosure()
            FindArcMachines   = { param($Subscription, $Name) , @([pscustomobject]@{ Name = $Name; ResourceId = "/subscriptions/$Subscription/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/$Name"; ResourceGroup = 'rg-iic-azl-01'; Status = 'Connected' }) }
            ListArcExtensions = { , @([pscustomobject]@{ Name = 'AzureMonitorWindowsAgent'; Type = 'AzureMonitorWindowsAgent' }) }
            GetArcGateway     = { [pscustomobject]@{ Name = 'arcgw'; ProvisioningState = 'Succeeded' } }
            GetNodeCredential = { [pscredential]::new('azl-admin', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }
            TestEndpoint      = { param($Address, $Target, [pscredential]$Credential) $log['Targets'] = @($Target); , @($Target | ForEach-Object { [pscustomobject]@{ Host = $_.Host; Port = $_.Port; Ok = $true; Error = '' } }) }.GetNewClosure()
        }
        foreach ($k in $Override.Keys) { $a[$k] = $Override[$k] }
        $a
    }

    function New-AzContext {
        param([hashtable]$Override = @{}, [System.Collections.IDictionary]$Infra, [hashtable]$Settings = @{}, $Handoff, [hashtable]$Log)
        if (-not $Infra) { $Infra = Get-TestInfra }
        @{ Infrastructure = $Infra; Handoff = $Handoff; OsReport = (Get-TestOsReport -Infra $Infra); Settings = $Settings; Adapters = @{ Azure = (New-AzAdapter -Override $Override -Log $Log) } }
    }

    function Invoke-AzCheck {
        <# Runs one check by id; returns its results as an array. #>
        param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)]$Context)
        @(& $script:Defs[$Id].Run $Context)
    }
}

Describe 'the contract' {
    It 'defines AZ-001 to AZ-023 once each, in category azure, with title, source, blocking, applies and run' {
        $ids = @($script:Defs.Keys | Sort-Object)
        $ids.Count | Should -Be 23
        $ids[0] | Should -Be 'AZ-001'
        $ids[-1] | Should -Be 'AZ-023'
        foreach ($d in Get-AzlVerificationCheckDefinition) {
            $d.Id | Should -Match '^AZ-\d{3}$'
            $d.Category | Should -Be 'azure'
            $d.Title | Should -Not -BeNullOrEmpty
            $d.Source | Should -Match '^https://|config/known-issues'
            $d.Blocking | Should -BeOfType [bool]
            $d.Applies | Should -BeOfType [scriptblock]
            $d.Run | Should -BeOfType [scriptblock]
        }
    }
    It 'Applies returns a bool' {
        $ctx = New-AzContext
        foreach ($d in $script:Defs.Values) { (& $d.Applies $ctx) | Should -BeOfType [bool] -Because $d.Id }
    }
    It 'every check passes (or is not applicable) in a healthy world, and no result holds a secret value' {
        $ctx = New-AzContext
        $all = foreach ($d in $script:Defs.Values) { if (-not (& $d.Applies $ctx)) { continue }; foreach ($r in (& $d.Run $ctx)) { [pscustomobject]@{ Id = $d.Id; R = $r } } }
        foreach ($x in $all) {
            $x.R.Status | Should -BeIn @('Passed', 'NotApplicable') -Because "$($x.Id): $($x.R.Message)"
            $x.R.PSObject.Properties.Name | Should -Contain 'Node'
            $x.R.PSObject.Properties.Name | Should -Contain 'Remedy'
            $x.R.PSObject.Properties.Name | Should -Contain 'Evidence'
        }
        ($all | ForEach-Object { $_.R } | ConvertTo-Json -Depth 5) | Should -Not -Match 'Sup3r'
    }
    It 'with nobody signed in, every check that reads Azure is Skipped and says why' {
        $ctx = New-AzContext -Override @{ GetContext = { $null } }
        foreach ($id in ($script:Defs.Keys | Where-Object { $_ -notin 'AZ-001', 'AZ-022', 'AZ-023' })) {
            $r = Invoke-AzCheck $id $ctx
            $r[0].Status | Should -Be 'Skipped' -Because $id
            $r[0].Message | Should -Match 'signed in' -Because $id
        }
        (Invoke-AzCheck 'AZ-001' $ctx)[0].Status | Should -Be 'Failed'
    }
    It 'with no Azure adapter at all, every check is Skipped, never Passed' {
        $ctx = New-AzContext
        $ctx.Adapters = @{}
        foreach ($id in ($script:Defs.Keys | Where-Object { $_ -ne 'AZ-022' })) {
            foreach ($r in (Invoke-AzCheck $id $ctx)) { $r.Status | Should -Not -Be 'Passed' -Because $id }
        }
    }
    It 'the default adapter is read only: the usual members, no RegisterProvider, Submit or Prompt' {
        $a = (Get-AzlVerificationAdapterDefault).Azure
        foreach ($k in 'GetContext', 'GetResourceGroup', 'GetProviderState', 'GetPermission', 'TestNameAvailable', 'TestSecret', 'GetArcMachine', 'GetDeploymentState', 'GetSubscription', 'GetCallerRoles', 'GetPrincipalRoles', 'ListRoleAssignments', 'GetHciResourceProviderObjectId', 'GetKeyVault', 'GetKeyVaultSecret', 'FindArcMachines', 'ListArcExtensions', 'GetArcGateway', 'GetNodeCredential', 'TestEndpoint') {
            $a.Contains($k) | Should -BeTrue -Because $k
            $a[$k] | Should -BeOfType [scriptblock] -Because $k
        }
        foreach ($k in 'RegisterProvider', 'Submit', 'Prompt') { $a.Contains($k) | Should -BeFalse -Because $k }
    }
}

Describe 'AZ-001 the tenant and subscription of the file' {
    It 'passes' { (Invoke-AzCheck 'AZ-001' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails for another tenant and names both' {
        $r = (Invoke-AzCheck 'AZ-001' (New-AzContext -Override @{ GetContext = { [pscustomobject]@{ SubscriptionId = '00000000-0000-0000-0000-000000000000'; TenantId = '22222222-0000-0000-0000-000000000000'; Account = 'a' } } }))[0]
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'tenant 22222222'
        $r.Message | Should -Match 'the file says 00000000'
        $r.Remedy | Should -Match 'Connect-AzAccount -Tenant'
    }
    It 'fails for another subscription' {
        $r = (Invoke-AzCheck 'AZ-001' (New-AzContext -Override @{ GetContext = { [pscustomobject]@{ SubscriptionId = '11111111-0000-0000-0000-000000000000'; TenantId = '00000000-0000-0000-0000-000000000000'; Account = 'a' } } }))[0]
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'subscription 11111111'
    }
    It 'fails when nobody is signed in' {
        $r = (Invoke-AzCheck 'AZ-001' (New-AzContext -Override @{ GetContext = { $null } }))[0]
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'Nobody is signed in'
    }
    It 'warns when azure.tenant_id is empty in the file' {
        $infra = Get-TestInfra; $infra.azure.tenant_id = ''
        $r = (Invoke-AzCheck 'AZ-001' (New-AzContext -Infra $infra))[0]
        $r.Status | Should -Be 'Warning'
        $r.Message | Should -Match 'azure.tenant_id is empty'
    }
}

Describe 'AZ-002 the subscription' {
    It 'passes when Enabled' { (Invoke-AzCheck 'AZ-002' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails when the subscription is not Enabled' {
        $r = (Invoke-AzCheck 'AZ-002' (New-AzContext -Override @{ GetSubscription = { [pscustomobject]@{ State = 'Disabled'; TenantId = '00000000-0000-0000-0000-000000000000'; DisplayName = 'lab' } } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'Disabled'
    }
    It 'fails when the subscription is not visible' {
        (Invoke-AzCheck 'AZ-002' (New-AzContext -Override @{ GetSubscription = { $null } }))[0].Status | Should -Be 'Failed'
    }
    It 'fails when the subscription is in another tenant than the file' {
        $r = (Invoke-AzCheck 'AZ-002' (New-AzContext -Override @{ GetSubscription = { [pscustomobject]@{ State = 'Enabled'; TenantId = '33333333-0000-0000-0000-000000000000'; DisplayName = 'x' } } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match '33333333'
    }
    It 'is Skipped without the adapter member' {
        $r = (Invoke-AzCheck 'AZ-002' (New-AzContext -Override @{ GetSubscription = $null }))[0]
        $r.Status | Should -Be 'Skipped'; $r.Message | Should -Match 'GetSubscription'
    }
}

Describe 'AZ-003 the resource group (ARM precondition ResourceGroup)' {
    It 'passes' { (Invoke-AzCheck 'AZ-003' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails when it does not exist' {
        $r = (Invoke-AzCheck 'AZ-003' (New-AzContext -Override @{ GetResourceGroup = { $null } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'rg-iic-azl-01'
    }
    It 'is Skipped without the adapter member' {
        (Invoke-AzCheck 'AZ-003' (New-AzContext -Override @{ GetResourceGroup = $null }))[0].Status | Should -Be 'Skipped'
    }
}

Describe 'AZ-004 the 13 mandatory resource providers (ARM precondition ResourceProviders)' {
    It 'evaluates all 13 and passes' {
        $log = @{}
        $r = (Invoke-AzCheck 'AZ-004' (New-AzContext -Log $log))[0]
        $r.Status | Should -Be 'Passed'
        @($log['Providers'] | Select-Object -Unique).Count | Should -Be 13
        foreach ($p in $script:Mandatory) { $log['Providers'] | Should -Contain $p }
    }
    It 'fails for one that is not registered, names it, gives the command, and never registers it' {
        $log = @{}
        $ctx = New-AzContext -Log $log -Override @{ GetProviderState = { param($Subscription, $Namespace) if ($Namespace -eq 'Microsoft.KeyVault') { 'NotRegistered' } else { 'Registered' } } }
        $r = (Invoke-AzCheck 'AZ-004' $ctx)[0]
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'Microsoft.KeyVault'
        $r.Remedy | Should -Match 'Register-AzResourceProvider -ProviderNamespace Microsoft.KeyVault'
        $log.ContainsKey('Registered') | Should -BeFalse
    }
    It 'does not register even when the run setting asks for it' {
        $log = @{}
        $ctx = New-AzContext -Log $log -Settings @{ registerResourceProviders = $true } -Override @{ GetProviderState = { 'NotRegistered' } }
        (Invoke-AzCheck 'AZ-004' $ctx)[0].Status | Should -Be 'Failed'
        $log.ContainsKey('Registered') | Should -BeFalse
    }
}

Describe 'AZ-005 the subscription roles' {
    It 'passes for Owner' { (Invoke-AzCheck 'AZ-005' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'passes for Contributor and User Access Administrator' {
        $ctx = New-AzContext -Override @{ GetCallerRoles = { , @([pscustomobject]@{ Role = 'Contributor'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000' }, [pscustomobject]@{ Role = 'User Access Administrator'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000' }) } }
        (Invoke-AzCheck 'AZ-005' $ctx)[0].Status | Should -Be 'Passed'
    }
    It 'fails for Contributor alone and names the missing role' {
        $ctx = New-AzContext -Override @{ GetCallerRoles = { , @([pscustomobject]@{ Role = 'Contributor'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000' }) } }
        $r = (Invoke-AzCheck 'AZ-005' $ctx)[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'User Access Administrator'
        $r.Remedy | Should -Match "New-AzRoleAssignment .* 'User Access Administrator'"
    }
    It 'does not count a role held on a different subscription' {
        $ctx = New-AzContext -Override @{ GetCallerRoles = { , @([pscustomobject]@{ Role = 'Owner'; Scope = '/subscriptions/99999999-0000-0000-0000-000000000000' }) } }
        (Invoke-AzCheck 'AZ-005' $ctx)[0].Status | Should -Be 'Failed'
    }
    It 'is Skipped, with the reason, when the roles cannot be read' {
        $r = (Invoke-AzCheck 'AZ-005' (New-AzContext -Override @{ GetCallerRoles = { throw 'AuthorizationFailed' } }))[0]
        $r.Status | Should -Be 'Skipped'; $r.Message | Should -Match 'AuthorizationFailed'
    }
}

Describe 'AZ-006 the effective permissions (ARM precondition Permissions)' {
    It 'passes with *' { (Invoke-AzCheck 'AZ-006' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails without Microsoft.Authorization/roleAssignments/write and names it' {
        $ctx = New-AzContext -Override @{ GetPermission = { , @([pscustomobject]@{ Actions = @('*'); NotActions = @('Microsoft.Authorization/roleAssignments/write') }) } }
        $r = (Invoke-AzCheck 'AZ-006' $ctx)[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'Microsoft.Authorization/roleAssignments/write'
    }
    It 'fails for a Contributor-like permission set' {
        $ctx = New-AzContext -Override @{ GetPermission = { , @([pscustomobject]@{ Actions = @('*'); NotActions = @('Microsoft.Authorization/*/Write', 'Microsoft.Authorization/*/Delete') }) } }
        (Invoke-AzCheck 'AZ-006' $ctx)[0].Status | Should -Be 'Failed'
    }
    It 'warns when the permissions cannot be read (empty answer)' {
        (Invoke-AzCheck 'AZ-006' (New-AzContext -Override @{ GetPermission = { , @() } }))[0].Status | Should -Be 'Warning'
    }
    It 'is Skipped without the adapter member' { (Invoke-AzCheck 'AZ-006' (New-AzContext -Override @{ GetPermission = $null }))[0].Status | Should -Be 'Skipped' }
}

Describe 'AZ-007 the roles Learn lists for the deploying user' {
    It 'passes for Owner plus Key Vault Secrets Officer (a data plane role Owner does not carry)' { (Invoke-AzCheck 'AZ-007' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails for Owner alone, naming only Key Vault Secrets Officer' {
        $ctx = New-AzContext -Override @{ GetCallerRoles = { , @([pscustomobject]@{ Role = 'Owner'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000' }) } }
        $r = (Invoke-AzCheck 'AZ-007' $ctx)[0]
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'Missing on resource group rg-iic-azl-01 \(or above\): Key Vault Secrets Officer\.'
    }
    It 'passes when every role is held by name at the resource group' {
        $roles = 'Azure Stack HCI Administrator', 'Reader', 'Key Vault Data Access Administrator', 'Key Vault Secrets Officer', 'Key Vault Contributor', 'Storage Account Contributor'
        $ctx = New-AzContext -Override @{ GetCallerRoles = { , @($roles | ForEach-Object { [pscustomobject]@{ Role = $_; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01' } }) }.GetNewClosure() }
        (Invoke-AzCheck 'AZ-007' $ctx)[0].Status | Should -Be 'Passed'
    }
    It 'fails for Contributor and lists the roles it lacks' {
        $ctx = New-AzContext -Override @{ GetCallerRoles = { , @([pscustomobject]@{ Role = 'Contributor'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000' }) } }
        $r = (Invoke-AzCheck 'AZ-007' $ctx)[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'Azure Stack HCI Administrator'
    }
    It 'is Skipped without the adapter member' { (Invoke-AzCheck 'AZ-007' (New-AzContext -Override @{ GetCallerRoles = $null }))[0].Status | Should -Be 'Skipped' }
}

Describe 'AZ-008 the roles Learn lists for registering the machines with Azure Arc' {
    It 'passes for Owner' { (Invoke-AzCheck 'AZ-008' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'passes for the two Arc roles' {
        $ctx = New-AzContext -Override @{ GetCallerRoles = { , @([pscustomobject]@{ Role = 'Azure Connected Machine Onboarding'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01' }, [pscustomobject]@{ Role = 'Azure Connected Machine Resource Administrator'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01' }) } }
        (Invoke-AzCheck 'AZ-008' $ctx)[0].Status | Should -Be 'Passed'
    }
    It 'fails for Contributor and names both roles' {
        $ctx = New-AzContext -Override @{ GetCallerRoles = { , @([pscustomobject]@{ Role = 'Contributor'; Scope = '/subscriptions/00000000-0000-0000-0000-000000000000' }) } }
        $r = (Invoke-AzCheck 'AZ-008' $ctx)[0]
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'Azure Connected Machine Onboarding'
        $r.Message | Should -Match 'Azure Connected Machine Resource Administrator'
    }
}

Describe 'AZ-009 the Azure Local resource provider service principal' {
    It 'passes, and is not blocking' {
        (Invoke-AzCheck 'AZ-009' (New-AzContext))[0].Status | Should -Be 'Passed'
        $script:Defs['AZ-009'].Blocking | Should -BeFalse
    }
    It 'fails when the service principal is not in the tenant' {
        $r = (Invoke-AzCheck 'AZ-009' (New-AzContext -Override @{ GetHciResourceProviderObjectId = { $null } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Remedy | Should -Match 'Register-AzResourceProvider -ProviderNamespace Microsoft.AzureStackHCI'
    }
    It 'fails when the object id of the file is not the tenant''s' {
        $r = (Invoke-AzCheck 'AZ-009' (New-AzContext -Override @{ GetHciResourceProviderObjectId = { '99999999-0000-0000-0000-000000000009' } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'azure.hci_resource_provider_object_id'
    }
    It 'warns when the service principal lacks the role the Azure Verified Module lists' {
        $r = (Invoke-AzCheck 'AZ-009' (New-AzContext -Override @{ GetPrincipalRoles = { , @() } }))[0]
        $r.Status | Should -Be 'Warning'; $r.Message | Should -Match 'Azure Connected Machine Resource Manager'
    }
    It 'passes when the file leaves the object id empty' {
        $infra = Get-TestInfra; $infra.azure.hci_resource_provider_object_id = ''
        (Invoke-AzCheck 'AZ-009' (New-AzContext -Infra $infra))[0].Status | Should -Be 'Passed'
    }
    It 'is Skipped when the directory cannot be read' {
        $r = (Invoke-AzCheck 'AZ-009' (New-AzContext -Override @{ GetHciResourceProviderObjectId = { throw 'Conditional Access blocked Graph' } }))[0]
        $r.Status | Should -Be 'Skipped'; $r.Message | Should -Match 'Conditional Access'
    }
}

Describe 'AZ-010 the Key Vault exists' {
    It 'passes' { (Invoke-AzCheck 'AZ-010' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails when the vault does not exist' {
        $r = (Invoke-AzCheck 'AZ-010' (New-AzContext -Override @{ GetKeyVault = { $null } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'kv-iic-mgmt-01'
    }
    It 'fails when the vault is not listed under key_vaults' {
        $infra = Get-TestInfra; $infra.key_vaults = @()
        $r = (Invoke-AzCheck 'AZ-010' (New-AzContext -Infra $infra))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'not listed under key_vaults'
    }
    It 'fails when the password is not a keyvault:// reference' {
        $infra = Get-TestInfra; $infra.identity.local_admin.password = 'plain'
        (Invoke-AzCheck 'AZ-010' (New-AzContext -Infra $infra))[0].Status | Should -Be 'Failed'
    }
    It 'is Skipped without the adapter member' { (Invoke-AzCheck 'AZ-010' (New-AzContext -Override @{ GetKeyVault = $null }))[0].Status | Should -Be 'Skipped' }
}

Describe 'AZ-011 the secrets the deployment parameters reference (ARM precondition KeyVaultSecrets)' {
    It 'passes' { (Invoke-AzCheck 'AZ-011' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails for a secret that is not in the vault' {
        $r = (Invoke-AzCheck 'AZ-011' (New-AzContext -Override @{ TestSecret = { param($Vault, $Secret) $Secret -ne 'lcm-password' } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'lcm-password'
    }
    It 'is Skipped, with the reason, when the ARM parameters cannot be generated' {
        $infra = Get-TestInfra; $infra.cluster.name = ''
        $r = (Invoke-AzCheck 'AZ-011' (New-AzContext -Infra $infra))[0]
        $r.Status | Should -Be 'Skipped'; $r.Message | Should -Match 'ARM parameters could not be generated'
    }
}

Describe 'AZ-012 the password secrets can be read' {
    It 'reads the local administrator and the LCM password, passes, and shows no value' {
        $log = @{}
        $r = (Invoke-AzCheck 'AZ-012' (New-AzContext -Log $log))[0]
        $r.Status | Should -Be 'Passed'
        $log['Reads'] | Should -Contain 'kv-iic-mgmt-01/local-admin-password'
        $log['Reads'] | Should -Contain 'kv-iic-mgmt-01/lcm-password'
        ($r | ConvertTo-Json) | Should -Not -Match 'Sup3r'
    }
    It 'reads only the local administrator with local identity' {
        $log = @{}
        $infra = Get-TestInfra -Identity local_identity
        (Invoke-AzCheck 'AZ-012' (New-AzContext -Infra $infra -Log $log))[0].Status | Should -Be 'Passed'
        @($log['Reads']).Count | Should -Be 1
    }
    It 'fails for a secret that does not exist' {
        $r = (Invoke-AzCheck 'AZ-012' (New-AzContext -Override @{ GetKeyVaultSecret = { param($Vault, $Secret) if ($Secret -eq 'lcm-password') { $null } else { 'x' } } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'lcm-password is not in vault'
    }
    It 'fails for a secret that cannot be read (no permission), without a value' {
        $r = (Invoke-AzCheck 'AZ-012' (New-AzContext -Override @{ GetKeyVaultSecret = { throw 'Forbidden: caller lacks secrets/get' } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'Forbidden'
    }
    It 'fails for an empty secret' {
        (Invoke-AzCheck 'AZ-012' (New-AzContext -Override @{ GetKeyVaultSecret = { ' ' } }))[0].Status | Should -Be 'Failed'
    }
    It 'is Skipped without the adapter member' { (Invoke-AzCheck 'AZ-012' (New-AzContext -Override @{ GetKeyVaultSecret = $null }))[0].Status | Should -Be 'Skipped' }
}

Describe 'AZ-013 the vault''s local-admin username equals the file''s' {
    It 'passes when they are equal (case does not matter)' {
        (Invoke-AzCheck 'AZ-013' (New-AzContext))[0].Status | Should -Be 'Passed'
        (Invoke-AzCheck 'AZ-013' (New-AzContext -Override @{ GetKeyVaultSecret = { param($Vault, $Secret) 'AZL-Admin' } }))[0].Status | Should -Be 'Passed'
    }
    It 'fails when the vault says Administrator and the file says azl-admin, naming both' {
        $r = (Invoke-AzCheck 'AZ-013' (New-AzContext -Override @{ GetKeyVaultSecret = { param($Vault, $Secret) 'Administrator' } }))[0]
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match "vault says the local administrator is 'Administrator'"
        $r.Message | Should -Match "the file says 'azl-admin'"
        $r.Remedy | Should -Match 'Set-AzKeyVaultSecret'
    }
    It 'reads the secret local-admin-username of the vault of the password' {
        $log = @{}
        $null = Invoke-AzCheck 'AZ-013' (New-AzContext -Log $log)
        $log['Reads'] | Should -Contain 'kv-iic-mgmt-01/local-admin-username'
    }
    It 'warns when the vault has no username secret' {
        $r = (Invoke-AzCheck 'AZ-013' (New-AzContext -Override @{ GetKeyVaultSecret = { $null } }))[0]
        $r.Status | Should -Be 'Warning'; $r.Message | Should -Match 'no secret local-admin-username'
    }
    It 'is Skipped, with the reason, when the secret name does not end in password' {
        $infra = Get-TestInfra; $infra.identity.local_admin.password = 'keyvault://kv-iic-mgmt-01/node-admin-credential'
        $r = (Invoke-AzCheck 'AZ-013' (New-AzContext -Infra $infra))[0]
        $r.Status | Should -Be 'Skipped'; $r.Message | Should -Match "does not end in 'password'"
    }
    It 'fails when the file holds the built-in name only as empty' {
        $infra = Get-TestInfra; $infra.identity.local_admin.username = ''
        (Invoke-AzCheck 'AZ-013' (New-AzContext -Infra $infra))[0].Status | Should -Be 'Failed'
    }
}

Describe 'AZ-014 the names are free (ARM precondition NamesAvailable)' {
    It 'passes' { (Invoke-AzCheck 'AZ-014' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails for a taken storage account name' {
        $ctx = New-AzContext -Override @{ TestNameAvailable = { param($Subscription, $ResourceGroup, $Type, $Name) [pscustomobject]@{ Available = ($Name -ne 'stiicazl01wit'); ExistsInResourceGroup = $false; Reason = 'AlreadyExists' } } }
        $r = (Invoke-AzCheck 'AZ-014' $ctx)[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'stiicazl01wit'
    }
    It 'passes when the name exists in the resource group (a re-run)' {
        $ctx = New-AzContext -Override @{ TestNameAvailable = { [pscustomobject]@{ Available = $false; ExistsInResourceGroup = $true; Reason = '' } } }
        (Invoke-AzCheck 'AZ-014' $ctx)[0].Status | Should -Be 'Passed'
    }
    It 'is Skipped when the ARM parameters cannot be generated' {
        $infra = Get-TestInfra; $infra.cluster.name = ''
        (Invoke-AzCheck 'AZ-014' (New-AzContext -Infra $infra))[0].Status | Should -Be 'Skipped'
    }
}

Describe 'AZ-015 the Arc machines are connected (ARM precondition ArcMachinesConnected)' {
    It 'passes for every node, one result per node' {
        $r = Invoke-AzCheck 'AZ-015' (New-AzContext)
        $r.Count | Should -Be 2
        ($r | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be 'Passed'
        ($r | ForEach-Object { $_.Node }) | Should -Contain 'iic-n01'
    }
    It 'fails for the node that is Disconnected' {
        $ctx = New-AzContext -Override @{ GetArcMachine = { param($Node, $ResourceId, $ArcMachineName, $Subscription, $ResourceGroup) [pscustomobject]@{ Name = $Node; ResourceId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$Node"; Status = $(if ($Node -eq 'iic-n02') { 'Disconnected' } else { 'Connected' }); OsVersion = ''; ComputerName = $Node } } }
        $r = Invoke-AzCheck 'AZ-015' $ctx
        ($r | Where-Object Node -eq 'iic-n02').Status | Should -Be 'Failed'
        ($r | Where-Object Node -eq 'iic-n01').Status | Should -Be 'Passed'
    }
    It 'fails when there is no Arc machine' {
        $r = Invoke-AzCheck 'AZ-015' (New-AzContext -Override @{ GetArcMachine = { $null } })
        ($r | ForEach-Object Status | Select-Object -Unique) | Should -Be 'Failed'
    }
    It 'fails for a machine in another resource group' {
        $ctx = New-AzContext -Override @{ GetArcMachine = { param($Node) [pscustomobject]@{ Name = $Node; ResourceId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-other/providers/Microsoft.HybridCompute/machines/$Node"; Status = 'Connected'; OsVersion = ''; ComputerName = $Node } } }
        (Invoke-AzCheck 'AZ-015' $ctx)[0].Message | Should -Match 'rg-other'
    }
    It 'is Skipped without the adapter member' { (Invoke-AzCheck 'AZ-015' (New-AzContext -Override @{ GetArcMachine = $null }))[0].Status | Should -Be 'Skipped' }
}

Describe 'AZ-016 the Arc machines are named after the host (ARM precondition ArcMachineNaming)' {
    BeforeAll {
        $script:DeviceId = { param($Node, $ResourceId, $ArcMachineName, $Subscription, $ResourceGroup) [pscustomobject]@{ Name = 'a1b2c3d4e5f60718293a4b5c6d7e8f90-1'; ResourceId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/a1b2c3d4e5f60718293a4b5c6d7e8f90-1"; Status = 'Connected'; OsVersion = ''; ComputerName = $Node } }
        $script:Handoff2690 = [pscustomobject]@{ VsrVersion = '12.2690.1003.15'; Nodes = @{} }
    }
    It 'passes when named after the host' { (Invoke-AzCheck 'AZ-016' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails on the build the known issue was seen on, when the name is the device id' {
        $r = (Invoke-AzCheck 'AZ-016' (New-AzContext -Override @{ GetArcMachine = $script:DeviceId } -Handoff $script:Handoff2690))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'arc-device-id-name'
    }
    It 'warns when the operator acknowledged the known issue' {
        $r = (Invoke-AzCheck 'AZ-016' (New-AzContext -Override @{ GetArcMachine = $script:DeviceId } -Handoff $script:Handoff2690 -Settings @{ acknowledgeKnownIssues = @('arc-device-id-name') }))[0]
        $r.Status | Should -Be 'Warning'
    }
    It 'warns for a name that is neither the host nor a device id' {
        $ctx = New-AzContext -Override @{ GetArcMachine = { param($Node, $ResourceId, $ArcMachineName, $Subscription, $ResourceGroup) [pscustomobject]@{ Name = 'custom-name'; ResourceId = 'x'; Status = 'Connected'; OsVersion = ''; ComputerName = $Node } } }
        (Invoke-AzCheck 'AZ-016' $ctx)[0].Status | Should -Be 'Warning'
    }
}

Describe 'AZ-017 no node is Arc-enabled twice or elsewhere' {
    It 'passes' { (Invoke-AzCheck 'AZ-017' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails for a machine of the same name in another resource group' {
        $ctx = New-AzContext -Override @{ FindArcMachines = { param($Subscription, $Name) , @([pscustomobject]@{ Name = $Name; ResourceId = 'x'; ResourceGroup = 'rg-old'; Status = 'Expired' }) } }
        $r = (Invoke-AzCheck 'AZ-017' $ctx)[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'rg-old'
    }
    It 'fails for two machines of the name in the resource group' {
        $ctx = New-AzContext -Override @{ FindArcMachines = { param($Subscription, $Name) , @([pscustomobject]@{ Name = $Name; ResourceId = 'x'; ResourceGroup = 'rg-iic-azl-01'; Status = 'Connected' }, [pscustomobject]@{ Name = $Name; ResourceId = 'y'; ResourceGroup = 'rg-iic-azl-01'; Status = 'Expired' }) } }
        (Invoke-AzCheck 'AZ-017' $ctx)[0].Message | Should -Match '2 Arc machines'
    }
    It 'is Skipped without the adapter member' { (Invoke-AzCheck 'AZ-017' (New-AzContext -Override @{ FindArcMachines = $null }))[0].Status | Should -Be 'Skipped' }
}

Describe 'AZ-018 no leftover failed deployment (ARM precondition NoLeftoverFailedDeployment)' {
    It 'passes when there is no cluster resource yet' { (Invoke-AzCheck 'AZ-018' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'passes for a cluster with no deployment' {
        (Invoke-AzCheck 'AZ-018' (New-AzContext -Override @{ GetDeploymentState = { Get-TestState -Prov 'Succeeded' -Validation 'Succeeded' } }))[0].Status | Should -Be 'Passed'
    }
    It 'fails for a failed deployment and says why' {
        $r = (Invoke-AzCheck 'AZ-018' (New-AzContext -Override @{ GetDeploymentState = { Get-TestState -Prov 'Failed' -Deployment 'Failed' } }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'failed deployment state'
    }
    It 'fails for a running deployment' {
        (Invoke-AzCheck 'AZ-018' (New-AzContext -Override @{ GetDeploymentState = { Get-TestState -Prov 'Succeeded' -Deployment 'InProgress' } }))[0].Status | Should -Be 'Failed'
    }
    It 'fails for an instance that is already deployed' {
        (Invoke-AzCheck 'AZ-018' (New-AzContext -Override @{ GetDeploymentState = { Get-TestState -Prov 'Succeeded' -Deployment 'Succeeded' } }))[0].Status | Should -Be 'Failed'
    }
    It 'is Skipped, never Passed, when the state cannot be read' {
        $r = (Invoke-AzCheck 'AZ-018' (New-AzContext -Override @{ GetDeploymentState = { throw 'HTTP 503' } }))[0]
        $r.Status | Should -Be 'Skipped'; $r.Message | Should -Match '503'
        (Invoke-AzCheck 'AZ-018' (New-AzContext -Override @{ GetDeploymentState = $null }))[0].Status | Should -Be 'Skipped'
    }
}

Describe 'AZ-019 no zombie role assignments' {
    It 'passes' { (Invoke-AzCheck 'AZ-019' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails for an assignment of a deleted principal and gives the cleanup command' {
        $ctx = New-AzContext -Override @{ ListRoleAssignments = { param($Scope) , @([pscustomobject]@{ Role = 'Azure Stack HCI Device Management Role'; PrincipalId = '55555555-0000-0000-0000-000000000005'; PrincipalType = 'Unknown'; DisplayName = ''; Scope = $Scope }) } }
        $r = (Invoke-AzCheck 'AZ-019' $ctx)[0]
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'Identity not found'
        $r.Message | Should -Match '55555555'
        $r.Remedy | Should -Match 'Remove-AzRoleAssignment'
    }
    It 'is Skipped without the adapter member' { (Invoke-AzCheck 'AZ-019' (New-AzContext -Override @{ ListRoleAssignments = $null }))[0].Status | Should -Be 'Skipped' }
}

Describe 'AZ-020 no leftover Device Management Role assignment' {
    BeforeAll {
        $script:DmrList = { param($Scope) , @([pscustomobject]@{ Role = 'Azure Stack HCI Device Management Role'; PrincipalId = '66666666-0000-0000-0000-000000000006'; PrincipalType = 'ServicePrincipal'; DisplayName = 'portal'; Scope = $Scope }) }
    }
    It 'passes when no such assignment exists' { (Invoke-AzCheck 'AZ-020' (New-AzContext))[0].Status | Should -Be 'Passed' }
    It 'fails when the portal left one and the cluster resource does not exist' {
        $r = (Invoke-AzCheck 'AZ-020' (New-AzContext -Override @{ ListRoleAssignments = $script:DmrList }))[0]
        $r.Status | Should -Be 'Failed'; $r.Message | Should -Match 'RoleAssignmentExists'
    }
    It 'is not applicable when the cluster resource exists' {
        $ctx = New-AzContext -Override @{ ListRoleAssignments = $script:DmrList; GetDeploymentState = { Get-TestState } }
        (Invoke-AzCheck 'AZ-020' $ctx)[0].Status | Should -Be 'NotApplicable'
    }
}

Describe 'AZ-021 no Windows update extension' {
    It 'passes, one result per node' {
        $r = Invoke-AzCheck 'AZ-021' (New-AzContext)
        $r.Count | Should -Be 2
        ($r | ForEach-Object Status | Select-Object -Unique) | Should -Be 'Passed'
    }
    It 'fails for the node that has the extension' {
        $ctx = New-AzContext -Override @{ ListArcExtensions = { param($ResourceId) if ($ResourceId -like '*iic-n01') { , @([pscustomobject]@{ Name = 'WindowsOsUpdateExtension'; Type = 'WindowsOsUpdateExtension' }) } else { , @() } } }
        $r = Invoke-AzCheck 'AZ-021' $ctx
        ($r | Where-Object Node -eq 'iic-n01').Status | Should -Be 'Failed'
        ($r | Where-Object Node -eq 'iic-n02').Status | Should -Be 'Passed'
    }
    It 'is Skipped per node when there is no Arc machine' {
        $r = Invoke-AzCheck 'AZ-021' (New-AzContext -Override @{ GetArcMachine = { $null } })
        ($r | ForEach-Object Status | Select-Object -Unique) | Should -Be 'Skipped'
    }
}

Describe 'AZ-022 the Arc gateway' {
    BeforeAll {
        $script:GatewayInfra = { $i = Get-TestInfra; $i.scenario.outbound_path = 'arc_gateway'; $i.networking['outbound'] = [ordered]@{ arc_gateway = [ordered]@{ name = 'arcgw-iic'; resource_group = 'rg-iic-azl-01' } }; $i }
    }
    It 'applies only when the outbound path uses an Arc gateway' {
        (& $script:Defs['AZ-022'].Applies (New-AzContext)) | Should -BeFalse
        (& $script:Defs['AZ-022'].Applies (New-AzContext -Infra (& $script:GatewayInfra))) | Should -BeTrue
    }
    It 'passes when the gateway exists' { (Invoke-AzCheck 'AZ-022' (New-AzContext -Infra (& $script:GatewayInfra)))[0].Status | Should -Be 'Passed' }
    It 'fails when the gateway does not exist' {
        (Invoke-AzCheck 'AZ-022' (New-AzContext -Infra (& $script:GatewayInfra) -Override @{ GetArcGateway = { $null } }))[0].Status | Should -Be 'Failed'
    }
    It 'fails when the gateway is not Succeeded' {
        (Invoke-AzCheck 'AZ-022' (New-AzContext -Infra (& $script:GatewayInfra) -Override @{ GetArcGateway = { [pscustomobject]@{ Name = 'x'; ProvisioningState = 'Creating' } } }))[0].Status | Should -Be 'Failed'
    }
    It 'fails when the file names no gateway' {
        $i = & $script:GatewayInfra; $i.networking.outbound.arc_gateway.name = ''
        (Invoke-AzCheck 'AZ-022' (New-AzContext -Infra $i))[0].Status | Should -Be 'Failed'
    }
    It 'is Skipped without the adapter member' {
        (Invoke-AzCheck 'AZ-022' (New-AzContext -Infra (& $script:GatewayInfra) -Override @{ GetArcGateway = $null }))[0].Status | Should -Be 'Skipped'
    }
}

Describe 'AZ-023 the Arc endpoints, probed from each node' {
    It 'passes for both nodes and probes the region endpoint of the file' {
        $log = @{}
        $r = Invoke-AzCheck 'AZ-023' (New-AzContext -Log $log)
        $r.Count | Should -Be 2
        ($r | ForEach-Object Status | Select-Object -Unique) | Should -Be 'Passed'
        @($log['Targets'] | ForEach-Object Host) | Should -Contain 'eastus.his.arc.azure.com'
        @($log['Targets'] | ForEach-Object Host) | Should -Contain 'management.azure.com'
        @($log['Targets'] | ForEach-Object Port | Select-Object -Unique) | Should -Be 443
    }
    It 'fails for the node that cannot reach an endpoint and names it' {
        $ctx = New-AzContext -Override @{ TestEndpoint = { param($Address, $Target, [pscredential]$Credential) , @($Target | ForEach-Object { [pscustomobject]@{ Host = $_.Host; Port = $_.Port; Ok = ($_.Host -ne 'gbl.his.arc.azure.com' -or $Address -ne '192.0.2.12'); Error = 'no answer in 5 seconds' } }) } }
        $r = Invoke-AzCheck 'AZ-023' $ctx
        $bad = @($r | Where-Object Status -eq 'Failed')
        $bad.Count | Should -Be 1
        $bad[0].Message | Should -Match 'gbl.his.arc.azure.com'
        $bad[0].Node | Should -Be 'iic-n02'
    }
    It 'is Skipped per node, with the reason, when the probe cannot run on the node' {
        $r = Invoke-AzCheck 'AZ-023' (New-AzContext -Override @{ TestEndpoint = { throw 'WinRM cannot connect' } })
        $r.Count | Should -Be 2
        foreach ($x in $r) { $x.Status | Should -Be 'Skipped'; $x.Message | Should -Match 'WinRM cannot connect' }
    }
    It 'is Skipped when there is no credential for the nodes' {
        $r = Invoke-AzCheck 'AZ-023' (New-AzContext -Override @{ GetNodeCredential = { throw 'vault unreachable' } })
        $r[0].Status | Should -Be 'Skipped'; $r[0].Message | Should -Match 'vault unreachable'
    }
    It 'is not applicable behind a proxy or an Arc gateway (the path is not direct)' {
        $i = Get-TestInfra; $i.scenario.outbound_path = 'proxy'
        (Invoke-AzCheck 'AZ-023' (New-AzContext -Infra $i))[0].Status | Should -Be 'NotApplicable'
    }
}
