#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-cluster verification gate, category azure: the Azure side of everything Microsoft Learn (view azloc-2610) and the azurelocal.cloud
    documentation list as a prerequisite of an Azure Local deployment. Read only.

.DESCRIPTION
    This module is a set of check definitions for the gate engine; it runs nothing at import. The engine calls:

      Get-AzlVerificationCheckDefinition   the checks (Id AZ-nnn, Category 'azure', Title, Source, Blocking, Applies, Run)
      Get-AzlVerificationAdapterDefault    the real, read-only implementations of the Azure adapter (Az cmdlets, Invoke-AzRestMethod)

    Contract with the engine
      $Context          hashtable: Infrastructure (the parsed master file), Handoff, OsReport, Settings, Adapters.
      $Context.Adapters.Azure   hashtable of scriptblocks (members below). Tests replace members with fakes; a member that is missing or
                        $null is "not available here" and the check that needs it ends as Skipped, with the reason.
      Applies           scriptblock param($Context) returning [bool].
      Run               scriptblock param($Context) returning one or more results:
                        @{ Status = Passed|Failed|Warning|Skipped|NotApplicable; Node = '*' or a node name; Message; Remedy; Evidence }.
                        Message and Evidence never hold a secret value. A Skipped result says why in Message.

    Reuse, not copies. Eight checks are the ARM run's own preconditions (AzureContext, ResourceGroup, ResourceProviders, Permissions,
    KeyVaultSecrets, NamesAvailable, ArcMachinesConnected, ArcMachineNaming, NoLeftoverFailedDeployment in AzlArmDeploymentRun.psm1),
    called through Invoke-AzlArmPrecondition with only that one precondition enabled. They read through the same adapter members the ARM
    run uses (same names and arguments), so a fix to a precondition is a fix to the gate. The other checks are harvested from the
    azl-toolkit scripts (Test-ResourceProviders, Test-RbacRoleAssignments, Test-UserAccess, Test-ArcPrerequisites), the toolkit's
    Test-ArcConnectivity and the failures this project met (config/known-issues/arm-deployment.json).

    Azure adapter members (arguments in order)
      Reused from the ARM run's adapter (New-AzlArmAzureAdapter), same behaviour:
        Now, Sleep, GetContext, GetResourceGroup(Subscription, ResourceGroup), GetProviderState(Subscription, Namespace),
        GetPermission(Subscription, ResourceGroup), TestNameAvailable(Subscription, ResourceGroup, Type, Name), TestSecret(Vault, Secret),
        GetArcMachine(Node, ResourceId, ArcMachineName, Subscription, ResourceGroup), GetDeploymentState(Subscription, ResourceGroup, Cluster)
      Defined here:
        GetSubscription(Subscription)                  State, TenantId, DisplayName; $null when not visible
        GetCallerRoles(Scope)                          the roles of the signed-in principal at and above Scope (Role, Scope), groups expanded
        GetPrincipalRoles(ObjectId, Scope)             the roles of one principal at and above Scope (Role, Scope)
        ListRoleAssignments(Scope)                     assignments made exactly at Scope (Role, PrincipalId, PrincipalType, DisplayName, Scope)
        GetHciResourceProviderObjectId()               object id of the Azure Local resource provider's service principal; $null when absent
        GetKeyVault(Vault, Subscription, ResourceGroup)  Name, ResourceGroup, VaultUri, EnableRbacAuthorization, PublicNetworkAccess; $null when absent
        GetKeyVaultSecret(Vault, Secret)               the value; $null when the secret does not exist; throws when it cannot be read
        FindArcMachines(Subscription, Name)            Arc machines of the subscription with that name (Name, ResourceId, ResourceGroup, Status)
        ListArcExtensions(ResourceId)                  Name, Type
        GetArcGateway(Subscription, ResourceGroup, Name)  Name, ProvisioningState; $null when absent
        GetNodeCredential(Infrastructure)              the nodes' local administrator as a PSCredential (read from Key Vault); throws with the reason
        TestEndpoint(Address, Target, Credential)      probes TCP from the node at Address: rows of Host, Port, Ok, Error

    The registration of a missing resource provider is deliberately not in the adapter: this module never changes Azure.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
Import-Module ([IO.Path]::Combine($script:Common, 'infrastructure', 'AzlInfrastructure.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'arm-deployment', 'AzlArmDeployment.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'arm-deployment', 'AzlArmDeploymentRun.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AzlVerification.Endpoints.psm1'))

$script:Learn = 'https://learn.microsoft.com/en-us/azure/azure-local'
$script:View = 'view=azloc-2610'
$script:Docs = 'https://azurelocal.cloud/docs/implementation'
$script:Src = @{
    Perm      = "$script:Learn/deploy/deployment-arc-register-server-permissions?$script:View"
    Prereq    = "$script:Learn/deploy/deployment-prerequisites?$script:View"
    Template  = "$script:Learn/deploy/deployment-azure-resource-manager-template?$script:View"
    Install   = "$script:Learn/deploy/deployment-install-os?$script:View"
    Firewall  = "$script:Learn/concepts/firewall-requirements?$script:View"
    Known     = 'config/known-issues/arm-deployment.json'
    Providers = "$script:Docs/02-azure-foundation/phase-02-resource-providers/task-02-verify-provider-registration"
    Rbac      = "$script:Docs/02-azure-foundation/phase-03-rbac-permissions/task-02-assign-rbac-roles"
    ArcPre    = "$script:Docs/04-cluster-deployment/phase-04-arc-registration/task-01-pre-registration-validation"
    ArcVerify = "$script:Docs/04-cluster-deployment/phase-04-arc-registration/task-04-verify-arc-registration-and-connectivity"
    Avm       = 'https://github.com/Azure/bicep-registry-modules/blob/main/avm/res/azure-stack-hci/cluster/README.md'
}

# The roles Learn tells you to assign to the user who deploys the instance (Assign required permissions for Azure Local deployment, step 2 and 4).
$script:DeploymentRoles = @('Azure Stack HCI Administrator', 'Reader', 'Key Vault Data Access Administrator', 'Key Vault Secrets Officer', 'Key Vault Contributor', 'Storage Account Contributor')
# The roles Learn requires on the resource group to register the machines as Arc resources, unless the user owns the resource group.
$script:ArcRegistrationRoles = @('Azure Connected Machine Onboarding', 'Azure Connected Machine Resource Administrator')
# Data plane roles: Owner (a control plane role) does not carry them.
$script:DataPlaneRoles = @('Key Vault Secrets Officer')
# Application (client) id of the Azure Local resource provider's service principal. A Microsoft-published constant, the same in every tenant.
$script:HciResourceProviderAppId = '1412d89f-b8a8-4111-b4fd-e82905cbd85d'
# Role the Microsoft Azure Verified Module README lists for that service principal (not on Learn; reported as a Warning only).
$script:HciResourceProviderRole = 'Azure Connected Machine Resource Manager'
# The role of the portal deployment's leftover assignment (known issue role-assignment-already-exists).
$script:DeviceManagementRole = 'Azure Stack HCI Device Management Role'

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------

# One state per $Context (its caches live exactly as long as the run), without changing the Context the engine owns.
$script:States = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

function Get-AzlVerifyState {
    param([Parameter(Mandatory)]$Context)
    $state = $null
    if (-not $script:States.TryGetValue($Context, [ref]$state)) {
        $state = @{}
        $script:States.Add($Context, $state)
    }
    return $state
}

function New-AzlVerifyResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object; changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('Passed', 'Failed', 'Warning', 'Skipped', 'NotApplicable')][string]$Status,
        [Parameter(Mandatory, Position = 1)][string]$Message,
        [Parameter(Position = 2)][string]$Remedy = '',
        [string]$Evidence = '',
        [string]$Node = '*'
    )
    if ($Evidence.Length -gt 240) { $Evidence = $Evidence.Substring(0, 237) + '...' }
    [pscustomobject]@{ Status = $Status; Node = $Node; Message = $Message; Remedy = $Remedy; Evidence = $Evidence }
}

function Stop-AzlVerifySkip {
    # Ends the check as Skipped, with the reason (a check that could not read what it needs is never read as fine).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Throws a control-flow exception; changes no system state.')]
    param([Parameter(Mandatory)][string]$Reason, [string]$Remedy = '')
    $e = [System.InvalidOperationException]::new($Reason)
    $e.Data['AzlSkip'] = $true
    $e.Data['AzlRemedy'] = $Remedy
    throw $e
}

function Get-AzlVerifyList([AllowNull()][object]$Value) {
    # The elements of a value that may be $null, one item or a list. Call as @(Get-AzlVerifyList $x).
    if ($null -eq $Value) { return }
    if ($Value -is [string] -or $Value -is [System.Collections.IDictionary]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) { foreach ($item in $Value) { $item }; return }
    return $Value
}

function Get-AzlVerifyAzureAdapter {
    # The Azure adapter table of the Context, or $null.
    param([Parameter(Mandatory)]$Context)
    $adapters = Get-AzlProp $Context 'Adapters'
    $azure = Get-AzlProp $adapters 'Azure'
    if ($azure -is [System.Collections.IDictionary]) { return $azure }
    return $null
}

function Test-AzlVerifyAdapterHas {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $azure = Get-AzlVerifyAzureAdapter $Context
    return ($null -ne $azure -and $azure.Contains($Name) -and $null -ne $azure[$Name])
}

function Invoke-AzlVerifyAdapter {
    # Calls an adapter member; a member that is missing or $null ends the check as Skipped.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [object[]]$Argument = @())
    if (-not (Test-AzlVerifyAdapterHas $Context $Name)) { Stop-AzlVerifySkip "The Azure adapter has no '$Name' here, so this check could not read what it needs." }
    $azure = Get-AzlVerifyAzureAdapter $Context
    return (& $azure[$Name] @Argument)
}

function Get-AzlVerifyInfrastructure {
    param([Parameter(Mandatory)]$Context)
    $infra = Get-AzlProp $Context 'Infrastructure'
    if ($infra -isnot [System.Collections.IDictionary]) { Stop-AzlVerifySkip 'The context holds no parsed infrastructure file.' }
    return $infra
}

function Get-AzlVerifyTarget {
    # What the file says about the target: subscription, resource group, tenant, location, cluster, nodes.
    param([Parameter(Mandatory)]$Context)
    $infra = Get-AzlVerifyInfrastructure $Context
    [pscustomobject]@{
        Subscription = [string](Get-AzlProp $infra 'azure.subscription_id' ''); ResourceGroup = [string](Get-AzlProp $infra 'azure.resource_group' '')
        Tenant = [string](Get-AzlProp $infra 'azure.tenant_id' ''); Location = [string](Get-AzlProp $infra 'azure.location' '')
        Cluster = [string](Get-AzlProp $infra 'cluster.name' ''); Identity = [string](Get-AzlProp $infra 'scenario.identity' 'active_directory')
        Nodes = @(Get-AzlVerifyList $infra['nodes'])
    }
}

function Format-AzlVerifyId([AllowNull()][string]$Id) {
    # A subscription or tenant id in a message: the first 8 characters only.
    if (-not $Id) { return '(empty)' }
    if ($Id.Length -le 8) { return $Id }
    return $Id.Substring(0, 8) + '...'
}

function Join-AzlVerifyList([AllowNull()][object[]]$Item) { return (@($Item) -join ', ') }

function Get-AzlVerifyAzureContext {
    # The signed-in context (GetContext), once per run; the check is Skipped when nobody is signed in (AZ-001 says so).
    param([Parameter(Mandatory)]$Context)
    $state = Get-AzlVerifyState $Context
    if (-not $state.ContainsKey('Azure')) {
        $state['Azure'] = $(if (Test-AzlVerifyAdapterHas $Context 'GetContext') { & (Get-AzlVerifyAzureAdapter $Context).GetContext } else { $null })
    }
    if (-not $state['Azure']) {
        Stop-AzlVerifySkip 'Nobody is signed in to Azure, so nothing in Azure could be read (see AZ-001).' 'Connect-AzAccount -Tenant <tenant id> -Subscription <subscription id>   (this tool never signs in by itself)'
    }
    return $state['Azure']
}

function Test-AzlVerifyScopeCover {
    # $true when the role assignment scope is the target scope or a parent of it.
    param([string]$AssignmentScope, [string]$Target)
    if (-not $AssignmentScope) { return $false }
    $a = $AssignmentScope.TrimEnd('/')
    return ($Target -ieq $a -or $Target.StartsWith($a + '/', [StringComparison]::OrdinalIgnoreCase) -or $a -ieq '/')
}

function Get-AzlVerifyCallerRole {
    # The role names the signed-in identity holds at the scope or above. The adapter read failing is a Skip, not a "no roles".
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Scope)
    try { $rows = @(Invoke-AzlVerifyAdapter $Context GetCallerRoles @($Scope)) }
    catch {
        if ($_.Exception.Data['AzlSkip']) { throw }
        Stop-AzlVerifySkip "The roles of the signed-in identity could not be read ($($_.Exception.Message))." 'Read access to role assignments is part of Reader; ask for it, or check Access control (IAM) in the portal.'
    }
    return @($rows | Where-Object { Test-AzlVerifyScopeCover ([string]$_.Scope) $Scope } | ForEach-Object { [string]$_.Role } | Select-Object -Unique)
}

function Test-AzlVerifyRoleHeld {
    # $true when the role is held by name, or the caller is Owner and the role is a control plane role.
    param([string[]]$Held, [string]$Role)
    if ($Role -in $Held) { return $true }
    return ('Owner' -in $Held -and $Role -notin $script:DataPlaneRoles)
}

function ConvertTo-AzlVerifyRoleCommand {
    param([string[]]$Role, [string]$Scope)
    return ((@($Role) | ForEach-Object { "New-AzRoleAssignment -SignInName '<signed-in user>' -RoleDefinitionName '$_' -Scope '$Scope'" }) -join '; ')
}

# ---------------------------------------------------------------------------------------------------------------------
# The ARM run's own preconditions, called (not copied)
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlVerifyParameterSet {
    # The ARM parameters the Validate would submit (New-AzlArmParameterSet, the same code), once per run. Skipped when they can't be built.
    param([Parameter(Mandatory)]$Context)
    $state = Get-AzlVerifyState $Context
    if (-not $state.ContainsKey('ParamSet')) {
        $result = [pscustomobject]@{ Set = $null; Error = '' }
        try {
            $infra = Get-AzlVerifyInfrastructure $Context
            $arguments = @{ Infrastructure = $infra; Handoff = (Get-AzlProp $Context 'Handoff'); Mode = 'Validate'; AllowUnresolvedSanLun = $true }
            $osReport = Get-AzlProp $Context 'OsReport'
            if ($osReport) { $arguments.AdapterMap = Get-AzlAdapterMapFromReport -Report $osReport; $arguments.NodeReport = @($osReport.nodes) }
            if (-not (Get-AzlProp $infra 'azure.hci_resource_provider_object_id') -and (Test-AzlVerifyAdapterHas $Context 'GetHciResourceProviderObjectId')) {
                try {
                    $id = & (Get-AzlVerifyAzureAdapter $Context).GetHciResourceProviderObjectId
                    if ($id) { $arguments.HciResourceProviderObjectId = [string]$id }
                }
                catch { Write-Verbose "The Azure Local resource provider object id could not be read: $($_.Exception.Message)" }
            }
            $result.Set = New-AzlArmParameterSet @arguments
        }
        catch { $result.Error = $_.Exception.Message }
        $state['ParamSet'] = $result
    }
    $r = $state['ParamSet']
    if (-not $r.Set) { Stop-AzlVerifySkip "The ARM parameters could not be generated from the file ($($r.Error)), and this check reads names and Key Vault references from them." 'Fix the file first (Test-InfrastructureFile.ps1 names the key), then run the verification again.' }
    return $r.Set
}

function Get-AzlVerifyArmBridge {
    # What Invoke-AzlArmPrecondition needs, built once per run: a Run over the Azure adapter, and the precondition Context.
    param([Parameter(Mandatory)]$Context)
    $state = Get-AzlVerifyState $Context
    if ($state.ContainsKey('Bridge')) { return $state['Bridge'] }
    $infra = Get-AzlVerifyInfrastructure $Context
    $target = Get-AzlVerifyTarget $Context
    $adapter = [ordered]@{ Now = { [datetime]::UtcNow }; Sleep = { param([double]$Seconds) Start-Sleep -Seconds $Seconds } }
    $azure = Get-AzlVerifyAzureAdapter $Context
    if ($azure) { foreach ($k in $azure.Keys) { if ($null -ne $azure[$k]) { $adapter[$k] = $azure[$k] } } }
    $acknowledged = @(Get-AzlVerifyList (Get-AzlProp (Get-AzlProp $Context 'Settings') 'acknowledgeKnownIssues' @()))
    $settings = Get-AzlArmRunSetting -Infrastructure $infra -Settings @{ acknowledgeKnownIssues = @($acknowledged | ForEach-Object { [string]$_ }) }
    # The gate reads: it never registers a provider. A failed deployment may be validated again only when the operator said so (-AllowRevalidate): then AZ-018 is a Warning that records it.
    $settings.registerResourceProviders = $false
    $settings.allowRevalidate = [bool](Get-AzlProp (Get-AzlProp $Context 'Settings') 'allowRevalidate' $false)
    $run = [ordered]@{ RunId = 'pre-cluster-verification'; Mode = 'Verify'; Cluster = $target.Cluster; SchemaVersion = ''; EventPath = ''; Adapter = $adapter; Settings = $settings; WhatIf = $true }
    $deviceIdIssue = Get-AzlArmKnownIssue | Where-Object { $_['id'] -eq 'arc-device-id-name' } | Select-Object -First 1
    $handoff = Get-AzlProp $Context 'Handoff'
    $ctx = [pscustomobject]@{
        Run = $run; Infra = $infra; Handoff = $handoff; OsReport = (Get-AzlProp $Context 'OsReport'); Set = $null; Settings = $settings
        Subscription = $target.Subscription; ResourceGroup = $target.ResourceGroup; Cluster = $target.Cluster; Nodes = @($target.Nodes)
        Build = $(if ($handoff) { [string](Get-AzlProp $handoff 'VsrVersion' '') } else { '' }); Phase = 'Validate'; ArcMachines = @{}; State = $null; AzureContext = $null
        Offline = $false; ValidateName = ''; DeviceIdIssue = $(if ($deviceIdIssue) { [pscustomobject]$deviceIdIssue } else { [pscustomobject]@{ affectedBuilds = @() } })
    }
    $state['Bridge'] = [pscustomobject]@{ Run = $run; Ctx = $ctx }
    return $state['Bridge']
}

function Invoke-AzlVerifyArmPrecondition {
    <#
    .SYNOPSIS
        Runs ONE of the ARM run's preconditions (Invoke-AzlArmPrecondition, only that name enabled) and maps its results to the gate's.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [ValidateSet('Validate', 'Deploy')][string]$Phase = 'Validate',
        [switch]$NeedParameterSet, [switch]$NeedDeploymentState
    )
    $bridge = Get-AzlVerifyArmBridge $Context
    $ctx = $bridge.Ctx
    if ($Name -eq 'AzureContext') {
        # The check that reports a missing sign-in itself: it gets $null, not a Skip.
        $signedIn = $(if (Test-AzlVerifyAdapterHas $Context 'GetContext') { & (Get-AzlVerifyAzureAdapter $Context).GetContext } else { $null })
        (Get-AzlVerifyState $Context)['Azure'] = $signedIn
    }
    else { $signedIn = Get-AzlVerifyAzureContext $Context }
    $ctx.AzureContext = $signedIn
    if ($NeedParameterSet) { $ctx.Set = Get-AzlVerifyParameterSet $Context }
    if ($NeedDeploymentState) {
        $ctx.State = Invoke-AzlVerifyAdapter $Context GetDeploymentState @($ctx.Subscription, $ctx.ResourceGroup, $ctx.Cluster)
    }
    # Every other precondition is skipped on purpose, so exactly one runs.
    $others = @(Get-AzlArmPreconditionName | Where-Object { $_ -ne $Name })
    $bridge.Run.Settings.skipPreconditions = $others
    $rows = @(Invoke-AzlArmPrecondition -Run $bridge.Run -Context $ctx -Phase $Phase | Where-Object { $_.Name -eq $Name })
    if (-not $rows) { Stop-AzlVerifySkip "The ARM precondition $Name did not run for the $Phase phase." }
    foreach ($r in $rows) {
        New-AzlVerifyResult ([string]$r.Result) ([string]$r.Evidence) ([string]$r.NextAction) -Evidence "ARM precondition $Name (AzlArmDeploymentRun)" -Node ([string]$r.Node)
    }
}

function Invoke-AzlVerifyGuarded {
    <#
    .SYNOPSIS
        Runs one check function. A check that can't read what it needs ends as Skipped with the reason; an unexpected error is a Skip too
        (never read as fine, never claimed as a finding about the environment).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Function)
    try { return @(& $Function $Context) }
    catch [System.NotSupportedException] { return @(New-AzlVerifyResult Skipped ($_.Exception.Message + ' This check was not run.')) }
    catch {
        $e = $_.Exception
        if ($e.Data['AzlSkip']) { return @(New-AzlVerifyResult Skipped $e.Message ([string]$e.Data['AzlRemedy'])) }
        return @(New-AzlVerifyResult Skipped "The check could not run: $($e.Message)" 'Fix the cause named above (a sign-in, a permission or a network path), then run the verification again.')
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------------------------------------------------

function Test-AzlVerifyAzureContext {
    # AZ-001. Reuses the ARM precondition AzureContext; adds the empty tenant of the file.
    param($Context)
    $target = Get-AzlVerifyTarget $Context
    $rows = @(Invoke-AzlVerifyArmPrecondition -Context $Context -Name AzureContext)
    foreach ($r in $rows) {
        if ($r.Status -eq 'Passed' -and -not $target.Tenant) {
            New-AzlVerifyResult Skipped ($r.Message + ' azure.tenant_id is empty in the file, so the tenant of the context could not be compared.') 'Set azure.tenant_id in the master file.' -Evidence $r.Evidence
        }
        elseif ($r.Status -eq 'Failed') {
            New-AzlVerifyResult Failed ($r.Message + ' Registering the machines or deploying in another tenant fails later and cannot be moved.') "Connect-AzAccount -Tenant '$($target.Tenant)' -Subscription '$($target.Subscription)'; Set-AzContext -Subscription '$($target.Subscription)'   (or fix azure.tenant_id and azure.subscription_id in the file)" -Evidence $r.Evidence
        }
        else { $r }
    }
}

function Test-AzlVerifySubscription {
    # AZ-002.
    param($Context)
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    $sub = Invoke-AzlVerifyAdapter $Context GetSubscription @($t.Subscription)
    if (-not $sub) { return New-AzlVerifyResult Failed "Subscription $(Format-AzlVerifyId $t.Subscription) is not visible to the signed-in identity." "Select the subscription of the file: Set-AzContext -Subscription '$($t.Subscription)'" }
    if ($sub.State -and [string]$sub.State -ne 'Enabled') {
        return New-AzlVerifyResult Failed "Subscription $(Format-AzlVerifyId $t.Subscription) is $($sub.State), not Enabled. A disabled or warned subscription cannot create the resources of the deployment." 'Use an enabled subscription (Azure portal, Subscriptions), or fix azure.subscription_id.' -Evidence "state $($sub.State)"
    }
    if ($t.Tenant -and $sub.TenantId -and [string]$sub.TenantId -ne $t.Tenant) {
        return New-AzlVerifyResult Failed "Subscription $(Format-AzlVerifyId $t.Subscription) belongs to tenant $(Format-AzlVerifyId $sub.TenantId), the file says $(Format-AzlVerifyId $t.Tenant)." 'Fix azure.tenant_id or azure.subscription_id in the file.' -Evidence 'tenant differs'
    }
    New-AzlVerifyResult Passed "Subscription '$($sub.DisplayName)' ($(Format-AzlVerifyId $t.Subscription)) is Enabled." -Evidence "state $($sub.State)"
}

function Test-AzlVerifySubscriptionRole {
    # AZ-005. Harvested from azl-toolkit Test-RbacRoleAssignments (subscription roles) and Learn.
    param($Context)
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    $scope = "/subscriptions/$($t.Subscription)"
    $held = @(Get-AzlVerifyCallerRole $Context $scope)
    $ok = ('Owner' -in $held) -or ('Contributor' -in $held -and 'User Access Administrator' -in $held)
    if ($ok) { return New-AzlVerifyResult Passed "The identity holds $(Join-AzlVerifyList $held) on the subscription." -Evidence "roles: $(Join-AzlVerifyList $held)" }
    $missing = @('Contributor', 'User Access Administrator' | Where-Object { $_ -notin $held })
    New-AzlVerifyResult Failed "Learn: be a contributor and a user access administrator on the subscription (the deployment Arc-enables the machines and assigns roles). The identity holds: $(if ($held) { Join-AzlVerifyList $held } else { 'no role at this scope' }). Missing: $(Join-AzlVerifyList $missing)." (ConvertTo-AzlVerifyRoleCommand $missing $scope) -Evidence "roles: $(Join-AzlVerifyList $held)"
}

function Test-AzlVerifyDeployerRole {
    # AZ-007. The roles Learn lists for the user who deploys the instance.
    param($Context)
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    $scope = "/subscriptions/$($t.Subscription)/resourceGroups/$($t.ResourceGroup)"
    $held = @(Get-AzlVerifyCallerRole $Context $scope)
    $missing = @($script:DeploymentRoles | Where-Object { -not (Test-AzlVerifyRoleHeld -Held $held -Role $_) })
    if (-not $missing) { return New-AzlVerifyResult Passed "The identity holds all $($script:DeploymentRoles.Count) roles Learn lists for the deploying user (directly or through Owner): $(Join-AzlVerifyList $script:DeploymentRoles)." -Evidence "roles: $(Join-AzlVerifyList $held)" }
    New-AzlVerifyResult Failed "Missing on resource group $($t.ResourceGroup) (or above): $(Join-AzlVerifyList $missing). Learn: assign these to the user who deploys the instance (Azure Stack HCI Administrator and Reader; Key Vault Data Access Administrator, Key Vault Secrets Officer and Key Vault Contributor; Storage Account Contributor). The identity holds: $(if ($held) { Join-AzlVerifyList $held } else { 'nothing here' })." ((@($missing) | ForEach-Object { "New-AzRoleAssignment -SignInName '<signed-in user>' -RoleDefinitionName '$_' -ResourceGroupName '$($t.ResourceGroup)'" }) -join '; ') -Evidence "missing: $(Join-AzlVerifyList $missing)"
}

function Test-AzlVerifyArcRegistrationRole {
    # AZ-008. The roles Learn lists for the user who registers the machines with Azure Arc.
    param($Context)
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    $scope = "/subscriptions/$($t.Subscription)/resourceGroups/$($t.ResourceGroup)"
    $held = @(Get-AzlVerifyCallerRole $Context $scope)
    $missing = @($script:ArcRegistrationRoles | Where-Object { -not (Test-AzlVerifyRoleHeld -Held $held -Role $_) })
    if (-not $missing) { return New-AzlVerifyResult Passed "The identity may register the machines: $(if ('Owner' -in $held) { 'Owner of the scope' } else { Join-AzlVerifyList $script:ArcRegistrationRoles })." -Evidence "roles: $(Join-AzlVerifyList $held)" }
    New-AzlVerifyResult Failed "Learn: to register machines as Arc resources be the resource group owner or hold $(Join-AzlVerifyList $script:ArcRegistrationRoles) on the resource group. Missing: $(Join-AzlVerifyList $missing)." ((@($missing) | ForEach-Object { "New-AzRoleAssignment -SignInName '<signed-in user>' -RoleDefinitionName '$_' -ResourceGroupName '$($t.ResourceGroup)'" }) -join '; ') -Evidence "missing: $(Join-AzlVerifyList $missing)"
}

function Test-AzlVerifyHciResourceProvider {
    # AZ-009. The Azure Local resource provider's service principal (application 1412d89f-...): exists in the tenant, equals the file, holds its role.
    param($Context)
    $t = Get-AzlVerifyTarget $Context
    $infra = Get-AzlVerifyInfrastructure $Context
    $null = Get-AzlVerifyAzureContext $Context
    $objectId = Invoke-AzlVerifyAdapter $Context GetHciResourceProviderObjectId
    if (-not $objectId) {
        return New-AzlVerifyResult Failed "The Azure Local resource provider's service principal (application $script:HciResourceProviderAppId) is not in this tenant. Without it the template parameter hciResourceProviderObjectID cannot be filled." ("Register-AzResourceProvider -ProviderNamespace Microsoft.AzureStackHCI   (it creates the service principal), then Get-AzADServicePrincipal -ApplicationId $script:HciResourceProviderAppId")
    }
    $inFile = [string](Get-AzlProp $infra 'azure.hci_resource_provider_object_id' '')
    if ($inFile -and $inFile -ine [string]$objectId) {
        return New-AzlVerifyResult Failed "azure.hci_resource_provider_object_id in the file ($(Format-AzlVerifyId $inFile)) is not the object id of the Azure Local resource provider in this tenant ($(Format-AzlVerifyId ([string]$objectId))). The object id is unique per tenant; one copied from another tenant makes the deployment fail." "Set it to: (Get-AzADServicePrincipal -ApplicationId '$script:HciResourceProviderAppId').Id   (or leave the key empty; the toolkit looks it up)" -Evidence 'object id differs'
    }
    $scope = "/subscriptions/$($t.Subscription)"
    $roles = @()
    if (Test-AzlVerifyAdapterHas $Context 'GetPrincipalRoles') {
        try { $roles = @(Invoke-AzlVerifyAdapter $Context GetPrincipalRoles @([string]$objectId, $scope) | ForEach-Object { [string]$_.Role }) }
        catch { return New-AzlVerifyResult Skipped "The service principal exists ($(Format-AzlVerifyId ([string]$objectId))); its roles could not be read ($($_.Exception.Message))." 'Check Access control (IAM) of the subscription.' -Evidence 'roles not read' }
    }
    else { return New-AzlVerifyResult Skipped "The service principal exists ($(Format-AzlVerifyId ([string]$objectId)))$(if ($inFile) { ' and matches the file' }); its roles were not read (no GetPrincipalRoles in the adapter)." '' -Evidence 'roles not read' }
    if ($script:HciResourceProviderRole -notin $roles) {
        return New-AzlVerifyResult Warning "The Azure Local resource provider's service principal ($(Format-AzlVerifyId ([string]$objectId))) does not hold '$script:HciResourceProviderRole' on the subscription. Learn does not list this role; the Microsoft Azure Verified Module for Azure Local clusters lists it as a prerequisite (extension reconciliation and hybrid compute operations). Treat as a warning unless Validate reports it." "New-AzRoleAssignment -ObjectId '$objectId' -RoleDefinitionName '$script:HciResourceProviderRole' -Scope '$scope'" -Evidence "roles: $(Join-AzlVerifyList $roles)"
    }
    New-AzlVerifyResult Passed "The Azure Local resource provider's service principal ($(Format-AzlVerifyId ([string]$objectId))) exists$(if ($inFile) { ', equals azure.hci_resource_provider_object_id' }) and holds '$script:HciResourceProviderRole' on the subscription." -Evidence "roles: $(Join-AzlVerifyList $roles)"
}

function Get-AzlVerifySecretReference {
    # The Key Vault references of the identities the deployment uses (the local administrator, the LCM user when Active Directory).
    param([Parameter(Mandatory)]$Context)
    $infra = Get-AzlVerifyInfrastructure $Context
    $t = Get-AzlVerifyTarget $Context
    $list = [System.Collections.Generic.List[object]]::new()
    $keys = @(@{ Label = 'local administrator password'; Path = 'identity.local_admin.password'; Kind = 'LocalAdmin' })
    if ($t.Identity -eq 'active_directory') { $keys += @{ Label = 'LCM user password'; Path = 'identity.active_directory.lcm_user.password'; Kind = 'Lcm' } }
    foreach ($k in $keys) {
        $ref = [string](Get-AzlProp $infra $k.Path '')
        $parts = ConvertFrom-AzlKeyVaultRef -Reference $ref
        $list.Add([pscustomobject]@{ Label = $k.Label; Path = $k.Path; Kind = $k.Kind; Reference = $ref; Vault = $(if ($parts) { $parts.Vault } else { '' }); Secret = $(if ($parts) { $parts.Secret } else { '' }); Valid = [bool]$parts })
    }
    return $list.ToArray()
}

function Test-AzlVerifyKeyVault {
    # AZ-010. The vaults of the local administrator and the LCM user exist, and are the ones listed under key_vaults.
    param($Context)
    $infra = Get-AzlVerifyInfrastructure $Context
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    $refs = @(Get-AzlVerifySecretReference $Context)
    $listed = @(Get-AzlVerifyList $infra['key_vaults'])
    $problems = @(); $seen = @{}
    foreach ($r in $refs) {
        if (-not $r.Valid) { $problems += "$($r.Path): '$($r.Reference)' is not a keyvault://<vault>/<secret> reference"; continue }
        if ($seen.ContainsKey($r.Vault)) { continue }
        $entry = @($listed | Where-Object { [string](Get-AzlProp $_ 'name' '') -ieq $r.Vault }) | Select-Object -First 1
        if (-not $entry) { $problems += "vault $($r.Vault) ($($r.Label)) is not listed under key_vaults in the file"; continue }
        $subscription = [string](Get-AzlProp $entry 'subscription_id' $t.Subscription)
        $resourceGroup = [string](Get-AzlProp $entry 'resource_group' '')
        $vault = Invoke-AzlVerifyAdapter $Context GetKeyVault @($r.Vault, $subscription, $resourceGroup)
        $seen[$r.Vault] = $vault
        if (-not $vault) { $problems += "vault $($r.Vault) ($($r.Label)) does not exist$(if ($resourceGroup) { " in resource group $resourceGroup" }) of subscription $(Format-AzlVerifyId $subscription)" }
    }
    if ($problems) {
        return New-AzlVerifyResult Failed "Key Vault: $($problems -join '; ')." "Create the vault, or fix key_vaults and the keyvault:// references in the file. The vault holds the local administrator and LCM passwords (Add-KeyVaultCredentials.ps1)." -Evidence "$($problems.Count) problem(s)"
    }
    if (-not $refs.Count) { return New-AzlVerifyResult Skipped 'The file names no Key Vault reference for the local administrator.' }
    New-AzlVerifyResult Passed "Key Vault $(Join-AzlVerifyList @($seen.Keys)) exist." -Evidence "$($seen.Count) vault(s)"
}

function Test-AzlVerifySecretReadable {
    # AZ-012. The password secrets can be READ (not only listed) by this identity and are not empty. The values are never shown.
    param($Context)
    $null = Get-AzlVerifyAzureContext $Context
    $refs = @(Get-AzlVerifySecretReference $Context)
    $bad = @()
    foreach ($r in $refs) {
        if (-not $r.Valid) { $bad += "$($r.Label): '$($r.Reference)' is not a keyvault://<vault>/<secret> reference"; continue }
        try { $value = Invoke-AzlVerifyAdapter $Context GetKeyVaultSecret @($r.Vault, $r.Secret) }
        catch {
            if ($_.Exception.Data['AzlSkip']) { throw }
            $bad += "$($r.Label): secret $($r.Secret) in $($r.Vault) could not be read ($($_.Exception.Message))"; continue
        }
        if ($null -eq $value) { $bad += "$($r.Label): secret $($r.Secret) is not in vault $($r.Vault)"; continue }
        if ([string]::IsNullOrWhiteSpace([string]$value)) { $bad += "$($r.Label): secret $($r.Secret) in $($r.Vault) is empty" }
        $value = $null
    }
    if (-not $refs.Count) { return New-AzlVerifyResult Failed 'The file has no keyvault:// reference for identity.local_admin.password.' 'Store the password in Key Vault and reference it as keyvault://<vault>/local-admin-password.' }
    if ($bad) { return New-AzlVerifyResult Failed ($bad -join '; ') 'Create the secret (Add-KeyVaultCredentials.ps1), grant this identity Get on secrets (Key Vault Secrets Officer on the vault), or fix the keyvault:// reference.' -Evidence "$($bad.Count) unreadable" }
    New-AzlVerifyResult Passed "$($refs.Count) password secret(s) are readable by the signed-in identity and not empty (values not shown)." -Evidence "$($refs.Count) read"
}

function Test-AzlVerifyLocalAdminUsername {
    # AZ-013. The vault's local-admin username secret must equal identity.local_admin.username (a real mismatch: the vault said Administrator, the nodes use another name).
    param($Context)
    $infra = Get-AzlVerifyInfrastructure $Context
    $null = Get-AzlVerifyAzureContext $Context
    $fileUser = [string](Get-AzlProp $infra 'identity.local_admin.username' '')
    $ref = @(Get-AzlVerifySecretReference $Context | Where-Object { $_.Kind -eq 'LocalAdmin' })[0]
    if (-not $fileUser) { return New-AzlVerifyResult Failed 'identity.local_admin.username is empty in the file.' 'Set identity.local_admin.username (not the built-in Administrator).' }
    if (-not $ref -or -not $ref.Valid) { Stop-AzlVerifySkip 'identity.local_admin.password is not a keyvault:// reference, so the vault holding the username secret is unknown (see AZ-012).' }
    if ($ref.Secret -notmatch '(?i)password$') { Stop-AzlVerifySkip "The secret $($ref.Secret) does not end in 'password', so the name of the matching username secret cannot be derived." "Name the secrets <prefix>-password and <prefix>-username (Add-KeyVaultCredentials.ps1: local-admin-username, local-admin-password)." }
    $userSecret = $ref.Secret -creplace '(?i)password$', $(if ($ref.Secret -cmatch 'PASSWORD$') { 'USERNAME' } elseif ($ref.Secret -cmatch 'Password$') { 'Username' } else { 'username' })
    $value = Invoke-AzlVerifyAdapter $Context GetKeyVaultSecret @($ref.Vault, $userSecret)
    if ($null -eq $value) {
        return New-AzlVerifyResult Warning "Vault $($ref.Vault) has no secret $userSecret; nothing to compare with identity.local_admin.username ('$fileUser'). Tools that read the username from the vault would not find it." "Set-AzKeyVaultSecret -VaultName '$($ref.Vault)' -Name '$userSecret' -SecretValue (ConvertTo-SecureString '$fileUser' -AsPlainText -Force)" -Evidence 'secret absent'
    }
    $vaultUser = ([string]$value).Trim()
    if ($vaultUser -ine $fileUser) {
        return New-AzlVerifyResult Failed "The vault says the local administrator is '$vaultUser' (secret $userSecret in $($ref.Vault)); the file says '$fileUser' (identity.local_admin.username), and the nodes are configured with the file's. A mismatch makes the deployment, or any tool that reads the vault, log on with a name that does not exist." "Make them agree: Set-AzKeyVaultSecret -VaultName '$($ref.Vault)' -Name '$userSecret' -SecretValue (ConvertTo-SecureString '$fileUser' -AsPlainText -Force)   (or correct identity.local_admin.username and the nodes)" -Evidence "vault '$vaultUser' vs file '$fileUser'"
    }
    New-AzlVerifyResult Passed "Secret $userSecret in $($ref.Vault) equals identity.local_admin.username ('$fileUser')." -Evidence 'usernames equal'
}

function Test-AzlVerifyArcDuplicate {
    # AZ-017. Harvested from the Arc integration validator (use-environment-checker): a node Arc-enabled twice or elsewhere.
    param($Context)
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    foreach ($n in $t.Nodes) {
        $name = [string]$n['name']
        $found = @(Invoke-AzlVerifyAdapter $Context FindArcMachines @($t.Subscription, $name))
        $elsewhere = @($found | Where-Object { $_.ResourceGroup -ine $t.ResourceGroup })
        $same = @($found | Where-Object { $_.ResourceGroup -ieq $t.ResourceGroup })
        if ($elsewhere.Count) {
            New-AzlVerifyResult Failed "$name is also an Arc machine in another resource group: $((@($elsewhere | ForEach-Object { "$($_.ResourceGroup)/$($_.Name) ($($_.Status))" })) -join '; '). The Arc integration validator fails when a node is already Arc-enabled in a different resource group." 'Delete the stale Arc machine (az connectedmachine delete --resource-group <rg> --name <name>) or deploy into the resource group it is in.' -Evidence "$($elsewhere.Count) elsewhere" -Node $name
        }
        elseif ($same.Count -gt 1) {
            New-AzlVerifyResult Failed "$($same.Count) Arc machines in $($t.ResourceGroup) carry the name or host name $name ($((@($same | ForEach-Object { "$($_.Name) ($($_.Status))" })) -join '; ')). Machines left over from earlier installs make the lookup ambiguous." 'Delete the stale ones that are not Connected (az connectedmachine delete).' -Evidence "$($same.Count) in the group" -Node $name
        }
        else { New-AzlVerifyResult Passed "$name has $($same.Count) Arc machine in the subscription, in $($t.ResourceGroup)." -Evidence "$($found.Count) found" -Node $name }
    }
}

function Test-AzlVerifyLeftoverFailedDeployment {
    # AZ-018. Reuses the ARM precondition NoLeftoverFailedDeployment.
    param($Context)
    Invoke-AzlVerifyArmPrecondition -Context $Context -Name NoLeftoverFailedDeployment -NeedDeploymentState
}

function Test-AzlVerifyZombieRoleAssignment {
    # AZ-019. Known issue role-assignment-zombie: assignments of a deleted principal ('Identity not found' in the portal).
    param($Context)
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    $scope = "/subscriptions/$($t.Subscription)/resourceGroups/$($t.ResourceGroup)"
    $all = @(Invoke-AzlVerifyAdapter $Context ListRoleAssignments @($scope))
    $zombies = @($all | Where-Object { [string]$_.PrincipalType -eq 'Unknown' -or (-not $_.DisplayName -and -not $_.PrincipalType) })
    if (-not $zombies) { return New-AzlVerifyResult Passed "$($all.Count) role assignment(s) at the resource group; none belongs to a deleted principal." -Evidence "$($all.Count) checked" }
    $list = @($zombies | ForEach-Object { "$($_.Role) -> $($_.PrincipalId)" })
    New-AzlVerifyResult Failed "$($zombies.Count) role assignment(s) at $($t.ResourceGroup) belong to a principal that no longer exists (the portal shows 'Identity not found'): $($list -join '; '). A former deployment's role assignments stayed behind; Azure then fails with 'Tenant ID, application ID, principal ID, and scope aren't allowed to be updated'." "Get-AzRoleAssignment -Scope '$scope' | Where-Object { `$_.ObjectType -eq 'Unknown' } | Remove-AzRoleAssignment" -Evidence "$($zombies.Count) zombie(s)"
}

function Test-AzlVerifyLeftoverRoleAssignment {
    # AZ-020. Known issue role-assignment-already-exists: a portal deployment's assignment the template would create again.
    param($Context)
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    $s = Invoke-AzlVerifyAdapter $Context GetDeploymentState @($t.Subscription, $t.ResourceGroup, $t.Cluster)
    if ($s) { return New-AzlVerifyResult NotApplicable 'The cluster resource exists, so its role assignments are its own (the template updates them).' }
    $scope = "/subscriptions/$($t.Subscription)/resourceGroups/$($t.ResourceGroup)"
    $mine = @(Invoke-AzlVerifyAdapter $Context ListRoleAssignments @($scope) | Where-Object { [string]$_.Role -eq $script:DeviceManagementRole -and [string]$_.PrincipalType -ne 'Unknown' })
    if (-not $mine) { return New-AzlVerifyResult Passed "No '$script:DeviceManagementRole' assignment exists in the resource group; the template can create its own." }
    $list = @($mine | ForEach-Object { "$($_.Role) -> $($_.DisplayName) ($($_.PrincipalId))" })
    New-AzlVerifyResult Failed "The resource group already holds $($mine.Count) assignment(s) of '$script:DeviceManagementRole' although the cluster resource does not exist: $($list -join '; '). The deployment was tried from the portal first (or by another run), so another identity holds the equivalent assignment and the template fails with RoleAssignmentExists (AzureStackHCIDeviceManagementRole-RoleAssignment)." "Access control (IAM), Role assignments: delete these assignments, or: Remove-AzRoleAssignment -ObjectId <principal id> -RoleDefinitionName '$script:DeviceManagementRole' -Scope '$scope'" -Evidence "$($mine.Count) assignment(s)"
}

function Test-AzlVerifyUpdateExtension {
    # AZ-021. Learn: do not install Windows Updates before the deployment; the update extension on an Arc machine is the sign.
    param($Context)
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    $bridge = Get-AzlVerifyArmBridge $Context
    foreach ($n in $t.Nodes) {
        $name = [string]$n['name']
        $handoffNode = Get-AzlHandoffNode -Handoff (Get-AzlProp $Context 'Handoff') -Name $name -ArcMachineName (Get-AzlArcMachineName -Node $n)
        $id = if ($handoffNode -and (Get-AzlProp $handoffNode 'arcMachineResourceId')) { [string](Get-AzlProp $handoffNode 'arcMachineResourceId') } else { '' }
        if (-not $bridge.Ctx.ArcMachines.ContainsKey($name)) {
            $bridge.Ctx.ArcMachines[$name] = Invoke-AzlVerifyAdapter $Context GetArcMachine @($name, $id, (Get-AzlArcMachineName -Node $n), $t.Subscription, $t.ResourceGroup)
        }
        $m = $bridge.Ctx.ArcMachines[$name]
        if (-not $m) { New-AzlVerifyResult Skipped "No Arc machine for $name, so its extensions could not be listed (see AZ-015)." -Node $name; continue }
        $ext = @(Invoke-AzlVerifyAdapter $Context ListArcExtensions @($m.ResourceId) | Where-Object { [string]$_.Type -match 'WindowsOsUpdateExtension' -or [string]$_.Name -match 'WindowsOsUpdateExtension' })
        if ($ext.Count) {
            New-AzlVerifyResult Failed "$name carries the extension $($ext[0].Name) (Microsoft.SoftwareUpdateManagement.WindowsOsUpdateExtension). Learn: do not install Windows Updates with SConfig or Azure Update Manager before the deployment; updates are installed during the deployment, and installing them before causes a deployment failure." "Remove-AzConnectedMachineExtension -MachineName '$($m.Name)' -ResourceGroupName '$($t.ResourceGroup)' -Name '$($ext[0].Name)'" -Evidence 'update extension present' -Node $name
        }
        else { New-AzlVerifyResult Passed "$name has no Windows update extension." -Node $name }
    }
}

function Test-AzlVerifyArcGateway {
    # AZ-022. Applies only when the outbound path uses an Arc gateway.
    param($Context)
    $infra = Get-AzlVerifyInfrastructure $Context
    $t = Get-AzlVerifyTarget $Context
    $null = Get-AzlVerifyAzureContext $Context
    $name = [string](Get-AzlProp $infra 'networking.outbound.arc_gateway.name' '')
    $rg = [string](Get-AzlProp $infra 'networking.outbound.arc_gateway.resource_group' $t.ResourceGroup)
    if (-not $name) { return New-AzlVerifyResult Failed 'scenario.outbound_path uses an Arc gateway but networking.outbound.arc_gateway.name is empty.' "Set networking.outbound.arc_gateway.name (and resource_group when it is not the instance's)." }
    $g = Invoke-AzlVerifyAdapter $Context GetArcGateway @($t.Subscription, $rg, $name)
    if (-not $g) { return New-AzlVerifyResult Failed "The Arc gateway $name does not exist in resource group $rg of the subscription." "az connectedmachine gateway create --name $name --resource-group $rg   (or fix networking.outbound.arc_gateway)" }
    if ($g.ProvisioningState -and [string]$g.ProvisioningState -ne 'Succeeded') { return New-AzlVerifyResult Failed "The Arc gateway $name is in state $($g.ProvisioningState), not Succeeded." 'Wait for it, or recreate it.' -Evidence "state $($g.ProvisioningState)" }
    New-AzlVerifyResult Passed "The Arc gateway $name exists in $rg." -Evidence 'Succeeded'
}

function Get-AzlVerifyArcEndpoint {
    # The concrete Azure Arc, authentication, management and data plane hosts a node must reach on 443: the one documented list (AzlVerification.Endpoints.psm1,
    # from Learn's firewall requirements and the Arc agent network requirements), with the region of the file.
    param([string]$Location)
    @(Get-AzlEndpointSet -Location $Location -Group Arc, Auth, Management, DataPlane -Port 443 |
            ForEach-Object { [pscustomobject]@{ Name = $_.Note; Host = $_.Host; Port = $_.Port; Tier = $_.Tier; Group = $_.Group } })
}

function Get-AzlVerifyCallerObjectId {
    <#
    .SYNOPSIS
        The Microsoft Entra object id of the signed-in Az context: the user (by user principal name, else the signed-in user from Graph) or the service principal
        (by application id). Never mixes parameter sets: one lookup, one id.
    #>
    [CmdletBinding()]
    param()
    $c = Get-AzContext
    if (-not $c -or -not $c.Account) { throw 'There is no Az context (Connect-AzAccount).' }
    $id = [string]$c.Account.Id
    if ([string]$c.Account.Type -eq 'User') {
        $user = $null
        try { $user = Get-AzADUser -UserPrincipalName $id -ErrorAction Stop } catch { $user = $null }
        if ($user -and $user.Id) { return [string]$user.Id }
        $me = Invoke-AzRestMethod -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id'
        if ($me.StatusCode -lt 400) { $o = [string](($me.Content | ConvertFrom-Json).id); if ($o) { return $o } }
        throw "The object id of the signed-in user $id could not be read (Get-AzADUser and Graph /me both failed)."
    }
    $sp = Get-AzADServicePrincipal -ApplicationId $id -ErrorAction Stop
    if (-not $sp -or -not $sp.Id) { throw "The service principal with application id $id was not found." }
    return [string]$sp.Id
}

function Get-AzlVerifyRoleByPrincipal {
    <#
    .SYNOPSIS
        The role assignments of one user or service principal that apply at -Scope: Azure Resource Manager lists them with $filter=assignedTo('{objectId}') on the scope,
        which is transitive over groups and includes what is inherited from the subscription and management groups. Rows of Role (the role name) and Scope.
        REST on purpose: Get-AzRoleAssignment cannot combine -Scope with -ExpandPrincipalGroups ("Parameter set cannot be resolved").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ObjectId, [Parameter(Mandatory)][string]$Scope)
    $names = @{}
    $rows = [System.Collections.Generic.List[object]]::new()
    $path = "$($Scope.TrimEnd('/'))/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$ObjectId')"
    $uri = ''
    for ($page = 0; $page -lt 50; $page++) {
        $r = if ($uri) { Invoke-AzRestMethod -Method GET -Uri $uri } else { Invoke-AzRestMethod -Method GET -Path $path }
        if ($r.StatusCode -ge 400) { throw "Listing role assignments at $Scope failed with HTTP $($r.StatusCode): $([string]$r.Content)" }
        $j = $r.Content | ConvertFrom-Json
        foreach ($a in @($j.value)) { $rows.Add($a) }
        $next = if ($j.PSObject.Properties['nextLink']) { [string]$j.nextLink } else { '' }
        if (-not $next) { break }
        $uri = $next
    }
    foreach ($a in $rows) {
        $defId = [string]$a.properties.roleDefinitionId
        if (-not $names.ContainsKey($defId)) {
            $d = Invoke-AzRestMethod -Method GET -Path "$defId`?api-version=2022-04-01"
            $names[$defId] = if ($d.StatusCode -lt 400) { [string](($d.Content | ConvertFrom-Json).properties.roleName) } else { '' }
        }
        if ($names[$defId]) { [pscustomobject]@{ Role = $names[$defId]; Scope = [string]$a.properties.scope } }
    }
}

function Test-AzlVerifyArcEndpoint {
    # AZ-023. Harvested from the toolkit's Test-ArcConnectivity: the Arc endpoints, probed FROM each node.
    param($Context)
    $infra = Get-AzlVerifyInfrastructure $Context
    $t = Get-AzlVerifyTarget $Context
    $path = [string](Get-AzlProp $infra 'scenario.outbound_path' 'direct')
    $cloud = [string](Get-AzlProp $infra 'scenario.cloud' 'public')
    if ($path -ne 'direct') { return New-AzlVerifyResult NotApplicable "scenario.outbound_path is '$path': a direct TCP probe does not describe the path through the proxy or the Arc gateway (the network checks cover it)." }
    if ($cloud -ne 'public') { return New-AzlVerifyResult NotApplicable "scenario.cloud is '$cloud': the endpoint list is for Azure public." }
    $targets = @(Get-AzlVerifyArcEndpoint -Location $t.Location)
    $credential = $null
    try { $credential = Invoke-AzlVerifyAdapter $Context GetNodeCredential @($infra) }
    catch {
        if ($_.Exception.Data['AzlSkip']) { throw }
        Stop-AzlVerifySkip "No credential for the nodes ($($_.Exception.Message)), so the endpoints could not be probed from them." 'Make identity.local_admin.password readable from Key Vault, or run the probes from the nodes (scripts/validation/arc-tests/powershell/Test-ArcConnectivity.ps1).'
    }
    foreach ($n in $t.Nodes) {
        $name = [string]$n['name']
        $mgmt = Get-AzlManagementAdapter -Infrastructure $infra -Node $n
        $address = if ($mgmt) { [string]$mgmt.IpAddress } else { '' }
        if (-not $address) { New-AzlVerifyResult Skipped "$name has no management address in the file, so it could not be probed." -Node $name; continue }
        try { $rows = @(Invoke-AzlVerifyAdapter $Context TestEndpoint @($address, $targets, $credential)) }
        catch {
            if ($_.Exception.Data['AzlSkip']) { throw }
            New-AzlVerifyResult Skipped "$name could not run the probe ($($_.Exception.Message)); the endpoints were not tested from the node." 'Open WinRM to the node from this host, or run Test-ArcConnectivity.ps1 on the node.' -Node $name; continue
        }
        $tier = @{}; foreach ($x in $targets) { $tier[[string]$x.Host] = [string]$x.Tier }
        $bad = @($rows | Where-Object { -not $_.Ok })
        $badRequired = @($bad | Where-Object { $tier[[string]$_.Host] -ne 'Optional' })
        $skipped = Format-AzlEndpointNotTested -Location $t.Location
        $fix = 'On the node: Test-NetConnection <host> -Port 443. Open the endpoints on the firewall or proxy (Learn: Firewall requirements for Azure Local, the consolidated endpoint list of the region).'
        if ($badRequired) {
            New-AzlVerifyResult Failed "$name cannot reach $($badRequired.Count) of $($rows.Count) documented Azure Arc endpoints on 443: $((@($badRequired | ForEach-Object { "$($_.Host) ($($_.Error))" })) -join '; '). Arc and the deployment need them. $skipped" $fix -Evidence "$($badRequired.Count) of $($rows.Count) failed" -Node $name
        }
        elseif ($bad) { New-AzlVerifyResult Warning "$name cannot reach the optional documented endpoint(s) $((@($bad | ForEach-Object { "$($_.Host) ($($_.Error))" })) -join '; '). $skipped" $fix -Node $name }
        else { New-AzlVerifyResult Passed "$name reaches all $($rows.Count) documented Azure Arc endpoints on 443 (region $((Get-AzlEndpointRegion -Location $t.Location).Name)). $skipped" -Evidence "$($rows.Count) reachable" -Node $name }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The definitions
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlVerificationCheckDefinition {
    <#
    .SYNOPSIS
        The Azure checks of the pre-cluster verification gate: Id (AZ-nnn), Category ('azure'), Title, Source, Blocking, Applies, Run.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $always = { param($Context) $null = $Context; $true }
    $def = {
        param($Id, $Title, $Source, $Applies, $Run, $Blocking = $true)
        [pscustomobject]@{ Id = $Id; Category = 'azure'; Title = $Title; Source = $Source; Blocking = [bool]$Blocking; Applies = $Applies; Run = $Run }
    }
    $d = [System.Collections.Generic.List[object]]::new()
    $d.Add((& $def 'AZ-001' 'Signed in to the tenant and subscription the file names' $script:Src.Perm $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyAzureContext }))
    $d.Add((& $def 'AZ-002' 'Subscription is enabled and in the tenant of the file' $script:Src.Prereq $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifySubscription }))
    $d.Add((& $def 'AZ-003' 'Resource group of the instance exists' $script:Src.Perm $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyResourceGroup }))
    $d.Add((& $def 'AZ-004' 'All 13 mandatory resource providers are registered' "$($script:Src.Perm); $($script:Src.Providers)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyResourceProvider }))
    $d.Add((& $def 'AZ-005' 'Subscription roles: Contributor and User Access Administrator (or Owner)' "$($script:Src.Prereq); $($script:Src.Rbac)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifySubscriptionRole }))
    $d.Add((& $def 'AZ-006' 'Effective permissions on the resource group include role assignment, deployment, cluster, Key Vault and storage writes' $script:Src.Perm $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyPermission }))
    $d.Add((& $def 'AZ-007' 'The roles Learn lists for the deploying user on the resource group' "$($script:Src.Perm) (Assign Azure permissions for deployment)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyDeployerRole }))
    $d.Add((& $def 'AZ-008' 'The roles Learn lists for registering the machines with Azure Arc (Azure Connected Machine Onboarding and Resource Administrator)' "$($script:Src.Perm) (Verify permissions)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyArcRegistrationRole }))
    $d.Add((& $def 'AZ-009' 'The Azure Local resource provider service principal exists, matches the file and holds its role' "$($script:Learn)/deploy/deployment-azure-resource-manager-template?$($script:View) (Get the object ID for Azure Local Resource Provider); $($script:Src.Avm)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyHciResourceProvider } $false))
    $d.Add((& $def 'AZ-010' 'The Key Vault of the local administrator and LCM secrets exists and is listed in the file' $script:Src.Prereq $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyKeyVault }))
    $d.Add((& $def 'AZ-011' 'Every Key Vault secret the deployment parameters reference exists' $script:Src.Prereq $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyKeyVaultSecret }))
    $d.Add((& $def 'AZ-012' 'The local administrator and LCM password secrets can be read and are not empty' $script:Src.Prereq $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifySecretReadable }))
    $d.Add((& $def 'AZ-013' 'The vault''s local-admin username secret equals identity.local_admin.username' "$($script:Src.Prereq); $($script:Src.Known) (built-in Administrator is refused)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyLocalAdminUsername }))
    $d.Add((& $def 'AZ-014' 'Names of the cloud witness storage account, diagnostics storage account and new Key Vault are free' $script:Src.Prereq $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyNameAvailable }))
    $d.Add((& $def 'AZ-015' 'Arc machines exist, are Connected and are in the resource group of the file' "$($script:Src.Perm); $($script:Src.ArcVerify); $($script:Src.ArcPre)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyArcConnected }))
    $d.Add((& $def 'AZ-016' 'Arc machines are named after the host (known issue arc-device-id-name)' "$($script:Src.Known) (arc-device-id-name)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyArcNaming }))
    $d.Add((& $def 'AZ-017' 'No node is Arc-enabled twice or in another resource group' "$($script:Learn)/manage/use-environment-checker?$($script:View) (Arc integration validator)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyArcDuplicate }))
    $d.Add((& $def 'AZ-018' 'No leftover failed or running deployment on the instance' "$($script:Src.Known) (license-sync-after-failed-validate)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyLeftoverFailedDeployment }))
    $d.Add((& $def 'AZ-019' 'No zombie role assignments (Identity not found) in the resource group' "$($script:Src.Known) (role-assignment-zombie)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyZombieRoleAssignment }))
    $d.Add((& $def 'AZ-020' 'No role assignment left by an earlier (portal) deployment that the template would create again' "$($script:Src.Known) (role-assignment-already-exists); $($script:Src.Template) (known issues)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyLeftoverRoleAssignment }))
    $d.Add((& $def 'AZ-021' 'No Windows update extension on the Arc machines (updates install during the deployment)' $script:Src.Install $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyUpdateExtension }))
    $d.Add((& $def 'AZ-022' 'The Arc gateway resource exists (outbound path with an Arc gateway)' "$($script:Learn)/deploy/deployment-without-azure-arc-gateway?$($script:View)" {
                param($Context)
                $path = [string](Get-AzlProp (Get-AzlProp $Context 'Infrastructure') 'scenario.outbound_path' '')
                return ($path -in 'arc_gateway', 'proxy_arc_gateway', 'private_path')
            } { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyArcGateway }))
    $d.Add((& $def 'AZ-023' 'Nodes reach the Azure Arc endpoints on 443 (probed from each node)' "$($script:Src.Firewall); $($script:Src.ArcPre) (Test-ArcConnectivity.ps1)" $always { param($Context) Invoke-AzlVerifyGuarded -Context $Context -Function Test-AzlVerifyArcEndpoint }))
    return $d.ToArray()
}

# Thin wrappers over the ARM run's preconditions (one function per check so Invoke-AzlVerifyGuarded can name them).
function Test-AzlVerifyResourceGroup { param($Context) Invoke-AzlVerifyArmPrecondition -Context $Context -Name ResourceGroup }
function Test-AzlVerifyResourceProvider { param($Context) Invoke-AzlVerifyArmPrecondition -Context $Context -Name ResourceProviders }
function Test-AzlVerifyPermission { param($Context) Invoke-AzlVerifyArmPrecondition -Context $Context -Name Permissions }
function Test-AzlVerifyKeyVaultSecret { param($Context) Invoke-AzlVerifyArmPrecondition -Context $Context -Name KeyVaultSecrets -NeedParameterSet }
function Test-AzlVerifyNameAvailable { param($Context) Invoke-AzlVerifyArmPrecondition -Context $Context -Name NamesAvailable -NeedParameterSet }
function Test-AzlVerifyArcConnected { param($Context) Invoke-AzlVerifyArmPrecondition -Context $Context -Name ArcMachinesConnected }
# Phase Deploy: the precondition then Fails (not only Warns) on a build where the device-ID name is known to break the Deploy, unless acknowledged.
function Test-AzlVerifyArcNaming {
    # AZ-016. A device-ID Arc machine name is a Warning in every phase: a failure at Deploy step 0.41 was reported against a prerelease build in another environment and has not
    # been reproduced here. The remedies (Learn: the Arc resource name is fixed at onboarding) are in the remedy text; nothing depends on this naming being a defect.
    param($Context)
    Invoke-AzlVerifyArmPrecondition -Context $Context -Name ArcMachineNaming -Phase Validate
}

# ---------------------------------------------------------------------------------------------------------------------
# The default adapter (real, read only)
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlVerificationAdapterDefault {
    <#
    .SYNOPSIS
        The real implementations of the Azure adapter, as @{ Azure = @{ ... } }. The engine merges this into $Context.Adapters.
    .DESCRIPTION
        Everything is a read. The ARM run's adapter members are reused as they are (New-AzlArmAzureAdapter); RegisterProvider, Submit and
        Prompt are NOT carried over, so the gate cannot change Azure.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table; changes no system state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'GetNodeCredential: the password was just read from the Key Vault and only ever lives in memory; WinRM needs a PSCredential.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $arm = New-AzlArmAzureAdapter
    $azure = [ordered]@{}
    foreach ($k in 'Now', 'Sleep', 'GetContext', 'GetResourceGroup', 'GetProviderState', 'GetPermission', 'TestNameAvailable', 'TestSecret', 'GetArcMachine', 'GetDeploymentState') { $azure[$k] = $arm[$k] }
    $azure['GetSubscription'] = {
        param($Subscription)
        $r = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription" -ApiVersion '2022-12-01' -AllowNotFound
        if ($r) { [pscustomobject]@{ State = [string](Get-AzlProp $r 'state' ''); TenantId = [string](Get-AzlProp $r 'tenantId' ''); DisplayName = [string](Get-AzlProp $r 'displayName' '') } }
    }
    $azure['GetCallerRoles'] = {
        param($Scope)
        # The roles the signed-in principal holds at the scope and above, including those it holds through a group and those inherited from a management group.
        Get-AzlVerifyRoleByPrincipal -ObjectId (Get-AzlVerifyCallerObjectId) -Scope $Scope
    }
    $azure['GetPrincipalRoles'] = {
        param($ObjectId, $Scope)
        Get-AzlVerifyRoleByPrincipal -ObjectId $ObjectId -Scope $Scope
    }
    $azure['ListRoleAssignments'] = {
        param($Scope)
        # ObjectType Unknown is the portal's "Identity not found": a role assignment whose principal was deleted.
        @(Get-AzRoleAssignment -Scope $Scope | Where-Object { [string]$_.Scope -eq $Scope } | ForEach-Object {
                [pscustomobject]@{ Role = [string]$_.RoleDefinitionName; PrincipalId = [string]$_.ObjectId; PrincipalType = [string]$_.ObjectType; DisplayName = [string]$_.DisplayName; Scope = [string]$_.Scope }
            })
    }
    $azure['GetHciResourceProviderObjectId'] = {
        $sp = Get-AzADServicePrincipal -ApplicationId '1412d89f-b8a8-4111-b4fd-e82905cbd85d'
        if ($sp) { [string]$sp.Id }
    }
    $azure['GetKeyVault'] = {
        param($Vault, $Subscription, $ResourceGroup)
        if ($ResourceGroup) {
            $r = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$Vault" -ApiVersion '2023-07-01' -AllowNotFound
        }
        else {
            $list = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/providers/Microsoft.KeyVault/vaults" -ApiVersion '2023-07-01'
            $r = @(Get-AzlProp $list 'value' @() | Where-Object { [string]$_.name -ieq $Vault }) | Select-Object -First 1
        }
        if ($r) {
            $id = [string](Get-AzlProp $r 'id' '')
            [pscustomobject]@{
                Name = [string](Get-AzlProp $r 'name' $Vault); ResourceGroup = $(if ($id -match '/resourceGroups/(?<g>[^/]+)/') { $Matches.g } else { $ResourceGroup })
                VaultUri = [string](Get-AzlProp $r 'properties.vaultUri' ''); EnableRbacAuthorization = [bool](Get-AzlProp $r 'properties.enableRbacAuthorization' $false)
                PublicNetworkAccess = [string](Get-AzlProp $r 'properties.publicNetworkAccess' '')
            }
        }
    }
    $azure['GetKeyVaultSecret'] = {
        param($Vault, $Secret)
        # The value; $null when the secret does not exist; anything else (no permission, network) throws.
        try { $v = Get-AzKeyVaultSecret -VaultName $Vault -Name $Secret -AsPlainText -ErrorAction Stop }
        catch {
            if ($_.Exception.Message -match 'SecretNotFound|was not found|not found') { return $null }
            throw
        }
        if ($null -eq $v) { return $null }
        return [string]$v
    }
    $azure['FindArcMachines'] = {
        param($Subscription, $Name)
        # Arc machines of the subscription with this name, in any resource group (the resources API filters by name).
        $filter = [uri]::EscapeDataString("resourceType eq 'Microsoft.HybridCompute/machines' and name eq '$Name'")
        $r = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/resources?`$filter=$filter" -ApiVersion '2021-04-01'
        @(Get-AzlProp $r 'value' @() | ForEach-Object {
                $id = [string]$_.id
                [pscustomobject]@{ Name = [string]$_.name; ResourceId = $id; ResourceGroup = $(if ($id -match '/resourceGroups/(?<g>[^/]+)/') { $Matches.g } else { '' }); Status = 'unknown' }
            })
    }
    $azure['ListArcExtensions'] = {
        param($ResourceId)
        $r = Invoke-AzlArm -Method GET -Path "$ResourceId/extensions" -ApiVersion '2024-07-10' -AllowNotFound
        @(Get-AzlProp $r 'value' @() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Type = [string](Get-AzlProp $_ 'properties.type' '') } })
    }
    $azure['GetArcGateway'] = {
        param($Subscription, $ResourceGroup, $Name)
        $r = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/gateways/$Name" -ApiVersion '2024-07-31-preview' -AllowNotFound
        if ($r) { [pscustomobject]@{ Name = [string](Get-AzlProp $r 'name' $Name); ProvisioningState = [string](Get-AzlProp $r 'properties.provisioningState' '') } }
    }
    $azure['GetNodeCredential'] = {
        param($Infrastructure)
        $user = [string](Get-AzlProp $Infrastructure 'identity.local_admin.username' '')
        $reference = [string](Get-AzlProp $Infrastructure 'identity.local_admin.password' '')
        if (-not $user -or -not $reference) { throw 'identity.local_admin has no username or password reference in the file.' }
        [pscredential]::new($user, (ConvertTo-SecureString -String (Get-AzlSecret -Reference $reference) -AsPlainText -Force))
    }
    $azure['TestEndpoint'] = {
        param($Address, $Target, [pscredential]$Credential)
        # Runs on the node (WinRM): a TCP connect to each endpoint, five seconds at most. Nothing is changed on the node.
        $probe = {
            param($List)
            foreach ($t in $List) {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                try {
                    $task = $tcp.ConnectAsync([string]$t.Host, [int]$t.Port)
                    $ok = $task.Wait(5000) -and $tcp.Connected
                    [pscustomobject]@{ Host = [string]$t.Host; Port = [int]$t.Port; Ok = [bool]$ok; Error = $(if ($ok) { '' } else { 'no answer in 5 seconds' }) }
                }
                catch { [pscustomobject]@{ Host = [string]$t.Host; Port = [int]$t.Port; Ok = $false; Error = $_.Exception.GetBaseException().Message } }
                finally { $tcp.Dispose() }
            }
        }
        $arguments = @{ ComputerName = $Address; ScriptBlock = $probe; ArgumentList = (, @($Target)); ErrorAction = 'Stop'; Authentication = 'Negotiate' }
        if ($Credential) { $arguments.Credential = $Credential }
        @(Invoke-Command @arguments | ForEach-Object { [pscustomobject]@{ Host = $_.Host; Port = $_.Port; Ok = $_.Ok; Error = $_.Error } })
    }
    return @{ Azure = $azure }
}

Export-ModuleMember -Function Get-AzlVerificationCheckDefinition, Get-AzlVerificationAdapterDefault
