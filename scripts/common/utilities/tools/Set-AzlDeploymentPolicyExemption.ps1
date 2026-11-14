<#
.SYNOPSIS
    Exempts the Azure Local deployment resource groups from inherited Azure Policy assignments while machines are
    provisioned and the cluster is deployed, and removes the exemptions afterwards.

.DESCRIPTION
    Policies assigned at a management group or subscription with the deployIfNotExists or modify effect act on new Arc
    machines in the middle of provisioning or deployment: they install extensions and agents or change settings (for
    example periodic update assessment on Arc-enabled servers, or a policy that deploys an agent). An exemption
    (category Waiver) on each deployment resource group stops them until the cluster is deployed; -Remove takes the
    exemptions off again. Audit, deny and other effects are left in force: they install nothing.

    The script creates one exemption per deploying assignment per resource group, named 'azl-deploy-<hash>', expiring
    after -ExpiresInDays; for an initiative it exempts only the members that deploy or modify. With -Remove it deletes the
    exemptions this script created (and only those: matched by name prefix and the description marker). With -WhatIf it
    lists every assignment that reaches each resource group, its effect (for an initiative, how many members deploy or
    modify) and what it would do, and changes nothing.

    Idempotent. An exemption this script already made is reported with its expiry and left alone; nothing else is changed
    or removed. One result row per assignment and resource group.

    It also reports the subscription's Defender for Servers plan: that plan installs the Defender (MDE.Windows)
    extension on Arc machines by itself, not through Azure Policy, so an exemption doesn't stop it.

    It does not sign in: run Connect-AzAccount to the tenant in azure.tenant_id first. Needs Az.Accounts and Az.Resources,
    and rights to create policy exemptions (Microsoft.Authorization/policyAssignments/exempt/action at the scope of each
    assignment: Resource Policy Contributor or Owner there). The Az context is put back at the end. Nothing prompts.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                                    the tenant the sign-in must belong to
        azure.subscription_id                              the deployment subscription
        azure.resource_group                               the resource group of the Arc machines and the cluster
        provisioning.simplified.subscription_id            with simplified provisioning, the subscription of the site and edge
                                                           machines (optional, when it is another subscription)
        provisioning.simplified.resource_group             with simplified provisioning, where the edge machines are created
                                                           (optional, when it is another group)
        provisioning.simplified.managed_resource_group_name   the managed resource group of the site, when the file names it
                                                           (optional; in the subscription of the site)

    Exit codes: 0 done (exempted, already exempt, removed, nothing to do, or planned under -WhatIf); 1 an Azure call or a
    precondition failed (not signed in, wrong tenant, Az modules missing, an exemption could not be written); 2 a value in
    the file is missing or not usable, nothing was sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read.

.PARAMETER ManagedResourceGroupName
    Optional. More resource groups to exempt that Azure named itself, such as the managed resource group of a site when
    provisioning.simplified.managed_resource_group_name is empty. They must be in azure.subscription_id.

.PARAMETER ExpiresInDays
    Days until the exemptions expire on their own (default 7), so a forgotten exemption doesn't stay.

.PARAMETER ExcludeAssignmentName
    Assignment names (or display names) to leave in force.

.PARAMETER Remove
    Remove this script's exemptions instead of creating them.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Set-AzlDeploymentPolicyExemption.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Lists what reaches the groups and what would be exempted, and changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Set-AzlDeploymentPolicyExemption.ps1 -InfrastructureFile ./infrastructure.yml

    Before provisioning: creates the exemptions. Run it again: they are reported as already exempt.

.EXAMPLE
    ./Set-AzlDeploymentPolicyExemption.ps1 -InfrastructureFile ./infrastructure.yml -Remove

    After the deployment succeeds: removes the exemptions this script made.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$ManagedResourceGroupName = @(),
    [ValidateRange(1, 90)][int]$ExpiresInDays = 7,
    [string[]]$ExcludeAssignmentName = @(),
    [switch]$Remove,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
# Azure resource group names: 1 to 90 letters, digits, underscores, hyphens, periods and parentheses, not ending in a period (Learn: naming rules).
$GroupName = '^[-\w\._\(\)]{0,89}[-\w_\(\)]$'
$Marker = 'azl-deploy: temporary exemption while Azure Local machines are provisioned and the cluster is deployed'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

function Get-ShortHash([string]$Text) {
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant()))
    -join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') })
}

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]; if ($p) { $p.Value } else { $null }
}

function Resolve-Effect([string]$Effect, $ValueSources) {
    # An effect written as [parameters('x')] takes the first value found in the sources (the member's parameters in an
    # initiative, the assignment's, the initiative's defaults, the definition's defaults), resolving chains of
    # parameter references between them.
    $guard = 0
    while ($Effect -match "^\[parameters\('([^']+)'\)\]$" -and $guard++ -lt 5) {
        $name = $Matches[1]; $found = $null
        foreach ($src in $ValueSources) {
            $entry = Get-Prop $src $name
            if ($null -eq $entry) { continue }
            $v = Get-Prop $entry 'value'; if ($null -eq $v) { $v = Get-Prop $entry 'defaultValue' }
            if ($null -ne $v -and "$v" -ne '') { $found = [string]$v; break }
        }
        if ($null -eq $found) { return 'unknown' }
        $Effect = $found
    }
    $Effect
}

function Get-DeployingMember($Assignment) {
    # The parts of an assignment that change resources: deployIfNotExists or modify. For a single policy, @('') when it
    # deploys; for an initiative, the policyDefinitionReferenceIds of the members that deploy. Empty when nothing does.
    if ([string]$Assignment.PolicyDefinitionId -notmatch '/policySetDefinitions/') {
        try {
            $def = Get-AzPolicyDefinition -Id $Assignment.PolicyDefinitionId -WarningAction SilentlyContinue
            $eff = Resolve-Effect ([string](Get-Prop (Get-Prop $def 'PolicyRule') 'then' | ForEach-Object { Get-Prop $_ 'effect' })) @((Get-Prop $Assignment 'Parameter'), (Get-Prop $def 'Parameter'))
            return [pscustomobject]@{ Effect = $eff; Members = @(if ($eff -match '(?i)^(deployIfNotExists|modify)$') { '' }) }
        }
        catch { return [pscustomobject]@{ Effect = 'unknown'; Members = @() } }
    }
    $set = Get-AzPolicySetDefinition -Id $Assignment.PolicyDefinitionId -WarningAction SilentlyContinue
    $members = foreach ($m in @(Get-Prop $set 'PolicyDefinition')) {
        if ($null -eq $m) { continue }
        try { $def = Get-AzPolicyDefinition -Id (Get-Prop $m 'policyDefinitionId') -WarningAction SilentlyContinue } catch { continue }
        $eff = Resolve-Effect ([string](Get-Prop (Get-Prop $def 'PolicyRule') 'then' | ForEach-Object { Get-Prop $_ 'effect' })) @((Get-Prop $m 'parameters'), (Get-Prop $Assignment 'Parameter'), (Get-Prop $set 'Parameter'), (Get-Prop $def 'Parameter'))
        if ($eff -match '(?i)^(deployIfNotExists|modify)$') { [string](Get-Prop $m 'policyDefinitionReferenceId') }
    }
    [pscustomobject]@{ Effect = "initiative, $(@($members).Count) of $(@(Get-Prop $set 'PolicyDefinition').Count) deploy or modify"; Members = @($members) }
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }

$siteSubscriptionId = Get-Text 'provisioning.simplified.subscription_id'
if (-not $siteSubscriptionId) { $siteSubscriptionId = $subscriptionId }
elseif ($siteSubscriptionId -notmatch $Guid -or $siteSubscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'provisioning.simplified.subscription_id is not a GUID or is the all-zero placeholder.' }

# The resource groups to exempt, each with its subscription.
$targets = [System.Collections.Generic.List[object]]::new()
function Add-Target([string]$Subscription, [string]$Group, [string]$From) {
    if ($Group -notmatch $GroupName) { Exit-InputProblem "$From '$Group' is not a valid resource group name." }
    if (-not ($targets | Where-Object { $_.Subscription -eq $Subscription -and $_.Group -ieq $Group })) { $targets.Add([pscustomobject]@{ Subscription = $Subscription; Group = $Group }) }
}
$clusterGroup = Get-Text 'azure.resource_group'
if (-not $clusterGroup) { Exit-InputProblem 'azure.resource_group is missing. It is the resource group of the Arc machines and the cluster.' }
Add-Target $subscriptionId $clusterGroup 'azure.resource_group'
foreach ($path in 'provisioning.simplified.resource_group', 'provisioning.simplified.managed_resource_group_name') {
    $value = Get-Text $path
    if ($value) { Add-Target $siteSubscriptionId $value $path }
}
foreach ($value in @($ManagedResourceGroupName | Where-Object { $_ })) { Add-Target $subscriptionId $value '-ManagedResourceGroupName' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResourceGroup', 'Get-AzPolicyAssignment', 'Get-AzPolicyDefinition', 'Get-AzPolicySetDefinition', 'Get-AzPolicyExemption', 'New-AzPolicyExemption', 'Remove-AzPolicyExemption') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Resources modules: Install-Module Az.Accounts, Az.Resources -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$rows = [System.Collections.Generic.List[object]]::new()
try {
    $current = ''
    foreach ($target in $targets) {
        $rg = $target.Group
        if ($target.Subscription -ne $current) { $null = Set-AzContext -SubscriptionId $target.Subscription -Tenant $tenantId -ErrorAction Stop; $current = $target.Subscription }
        $scope = "/subscriptions/$($target.Subscription)/resourceGroups/$rg"
        if (-not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)) {
            $rows.Add([pscustomobject]@{ ResourceGroup = $rg; Assignment = ''; Effect = ''; Action = 'NotFound'; Detail = 'The resource group does not exist (yet); nothing to exempt.' })
            Write-Line "[skip]    '$rg' does not exist."
            continue
        }
        $existing = @(Get-AzPolicyExemption -Scope $scope -WarningAction SilentlyContinue | Where-Object { [string]$_.Name -like 'azl-deploy-*' -and [string](Get-Prop $_ 'Description') -like "$Marker*" })

        if ($Remove) {
            foreach ($e in $existing) {
                $row = [ordered]@{ ResourceGroup = $rg; Assignment = [string](Get-Prop $e 'DisplayName'); Effect = ''; Action = ''; Detail = '' }
                try {
                    if ($PSCmdlet.ShouldProcess("exemption '$($e.Name)' on '$rg'", 'Remove')) {
                        Remove-AzPolicyExemption -Id $e.Id -Force -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                        $row.Action = 'Removed'; Write-Line "[removed] '$($e.Name)' on '$rg'."
                    }
                    else { $row.Action = 'WouldRemove'; Write-Line "[plan]    '$($e.Name)' on '$rg' would be removed." }
                }
                catch { $row.Action = 'Failed'; $row.Detail = $_.Exception.Message; Write-Warning "$($e.Name): $($row.Detail)" }
                $rows.Add([pscustomobject]$row)
            }
            if (-not $existing) { $rows.Add([pscustomobject]@{ ResourceGroup = $rg; Assignment = ''; Effect = ''; Action = 'NothingToRemove'; Detail = 'No exemption of this script.' }) }
            continue
        }

        # Get-AzPolicyAssignment -Scope returns the assignments that apply there, inherited from management groups and
        # the subscription included; keep only the inherited ones (one assigned on the group itself is the owner's choice).
        $assignments = @(Get-AzPolicyAssignment -Scope $scope -WarningAction SilentlyContinue | Where-Object { [string]$_.Scope -ne $scope })
        foreach ($a in $assignments) {
            $label = if (Get-Prop $a 'DisplayName') { [string]$a.DisplayName } else { [string]$a.Name }
            $row = [ordered]@{ ResourceGroup = $rg; Assignment = "$label ($([string]$a.Scope -replace '^/providers/Microsoft.Management/managementGroups/', 'mg:' -replace "^/subscriptions/$($target.Subscription)$", 'subscription'))"; Effect = ''; Action = ''; Detail = '' }
            try {
                $deploying = Get-DeployingMember $a
                $row.Effect = $deploying.Effect
                $name = "azl-deploy-$(Get-ShortHash "$scope|$($a.Id)")"
                $already = @($existing | Where-Object Name -EQ $name)
                if ($ExcludeAssignmentName -contains $a.Name -or ((Get-Prop $a 'DisplayName') -and $ExcludeAssignmentName -contains $a.DisplayName)) { $row.Action = 'Excluded' }
                elseif (-not @($deploying.Members).Count) { $row.Action = 'LeftInForce'; $row.Detail = 'It does not deploy or modify.' }
                elseif ($already) { $row.Action = 'AlreadyExempt'; $row.Detail = "Until $(Get-Prop $already[0] 'ExpiresOn')." }
                elseif ($PSCmdlet.ShouldProcess("assignment '$label' on '$rg'", "Exempt for $ExpiresInDays days")) {
                    $params = @{
                        Name              = $name
                        Scope             = $scope
                        PolicyAssignment  = $a
                        ExemptionCategory = 'Waiver'
                        DisplayName       = "azl-deploy: $label"
                        Description       = "$Marker. Created $((Get-Date).ToUniversalTime().ToString('u')); remove with Set-AzlDeploymentPolicyExemption.ps1 -Remove."
                        ExpiresOn         = (Get-Date).ToUniversalTime().AddDays($ExpiresInDays)
                    }
                    # In an initiative, only the members that deploy or modify are exempted; its audits stay in force.
                    $refs = @($deploying.Members | Where-Object { $_ })
                    if ($refs.Count) { $params.PolicyDefinitionReferenceId = $refs }
                    # Azure answers a burst of exemption writes with a transient error ("try again after 60 seconds").
                    for ($try = 1; ; $try++) {
                        try { New-AzPolicyExemption @params -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null; break }
                        catch {
                            if ($try -ge 4 -or $_.Exception.Message -notmatch '(?i)transient|try again') { throw }
                            Write-Warning "$($label): transient error, retrying in 60 s (attempt $try of 3)."; Start-Sleep -Seconds 60
                        }
                    }
                    $row.Action = 'Exempted'
                }
                else { $row.Action = 'WouldExempt' }
                Write-Line "[$($row.Action)] $label on '$rg' ($($row.Effect))."
            }
            catch { $row.Action = 'Failed'; $row.Detail = $_.Exception.Message; Write-Warning "$($label): $($row.Detail)" }
            $rows.Add([pscustomobject]$row)
        }
    }

    # Defender for Servers installs MDE.Windows on Arc machines itself; policy exemptions don't stop it.
    if ($current -ne $subscriptionId) { $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop }
    if (Get-Command -Name Get-AzSecurityPricing -ErrorAction SilentlyContinue) {
        try {
            $plan = Get-AzSecurityPricing -Name 'VirtualMachines' -WarningAction SilentlyContinue -ErrorAction Stop
            Write-Line "Defender for Servers on this subscription: $($plan.PricingTier)$(if (Get-Prop $plan 'SubPlan') { " ($($plan.SubPlan))" }). An exemption doesn't stop it installing the Defender (MDE.Windows) extension on new Arc machines; turn it off per machine (Defender for Cloud resource-level pricing) if it interferes with provisioning."
        }
        catch { Write-Line "Defender for Servers plan: couldn't read it ($($_.Exception.Message)). An exemption doesn't stop Defender installing MDE.Windows on Arc machines." }
    }
}
catch { Exit-Failed "An Azure call failed in subscription ${subscriptionId}: $($_.Exception.Message)" }
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
