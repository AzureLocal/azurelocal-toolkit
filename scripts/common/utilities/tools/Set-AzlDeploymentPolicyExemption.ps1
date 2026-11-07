#Requires -Version 7.0
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

    Without -Execute it only lists: every assignment that reaches each resource group, its effect (for an initiative,
    how many members deploy or modify), and what this script would do. With -Execute it creates one exemption per
    deploying assignment per resource group, named 'azl-deploy-<hash>', expiring after -ExpiresInDays; for an
    initiative it exempts only the members that deploy or modify. With -Remove -Execute it deletes the exemptions this
    script created (and only those: matched by name prefix and the description marker).

    It also reports the subscription's Defender for Servers plan: that plan installs the Defender (MDE.Windows)
    extension on Arc machines by itself, not through Azure Policy, so an exemption doesn't stop it.

    Needs Az.Resources and Az.Accounts, signed in with rights to create policy exemptions on the resource groups
    (Resource Policy Contributor or Owner).
.PARAMETER SubscriptionId
    The deployment subscription.
.PARAMETER ResourceGroupName
    The resource groups to exempt: the cluster resource group, and the Azure Local managed resource group
    (AzLocal-ManagedResources-<rg>-<suffix>) when it exists.
.PARAMETER ExpiresInDays
    Days until the exemptions expire on their own (default 7), so a forgotten exemption doesn't stay.
.PARAMETER ExcludeAssignmentName
    Assignment names (or display names) to leave in force.
.PARAMETER Remove
    Remove this script's exemptions instead of creating them.
.PARAMETER Execute
    Make the change. Without it, only lists.
.EXAMPLE
    ./Set-AzlDeploymentPolicyExemption.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example-azl
.EXAMPLE
    ./Set-AzlDeploymentPolicyExemption.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example-azl -Execute
.EXAMPLE
    ./Set-AzlDeploymentPolicyExemption.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example-azl -Remove -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][string[]]$ResourceGroupName,
    [ValidateRange(1, 90)][int]$ExpiresInDays = 7,
    [string[]]$ExcludeAssignmentName = @(),
    [switch]$Remove,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$marker = 'azl-deploy: temporary exemption while Azure Local machines are provisioned and the cluster is deployed'
if (-not (Get-AzContext)) { throw 'Not signed in to Azure. Run Connect-AzAccount.' }
$null = Set-AzContext -Subscription $SubscriptionId -WarningAction SilentlyContinue

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
    if ($Assignment.PolicyDefinitionId -notmatch '/policySetDefinitions/') {
        try {
            $def = Get-AzPolicyDefinition -Id $Assignment.PolicyDefinitionId -WarningAction SilentlyContinue
            $eff = Resolve-Effect ([string](Get-Prop (Get-Prop $def 'PolicyRule') 'then' | ForEach-Object { Get-Prop $_ 'effect' })) @((Get-Prop $Assignment 'Parameter'), (Get-Prop $def 'Parameter'))
            return [pscustomobject]@{ Effect = $eff; Members = @(if ($eff -match '(?i)^(deployIfNotExists|modify)$') { '' }) }
        }
        catch { return [pscustomobject]@{ Effect = 'unknown'; Members = @() } }
    }
    $set = Get-AzPolicySetDefinition -Id $Assignment.PolicyDefinitionId -WarningAction SilentlyContinue
    $members = foreach ($m in @($set.PolicyDefinition)) {
        try { $def = Get-AzPolicyDefinition -Id (Get-Prop $m 'policyDefinitionId') -WarningAction SilentlyContinue } catch { continue }
        $eff = Resolve-Effect ([string](Get-Prop (Get-Prop $def 'PolicyRule') 'then' | ForEach-Object { Get-Prop $_ 'effect' })) @((Get-Prop $m 'parameters'), (Get-Prop $Assignment 'Parameter'), (Get-Prop $set 'Parameter'), (Get-Prop $def 'Parameter'))
        if ($eff -match '(?i)^(deployIfNotExists|modify)$') { [string](Get-Prop $m 'policyDefinitionReferenceId') }
    }
    [pscustomobject]@{ Effect = "initiative, $(@($members).Count) of $(@($set.PolicyDefinition).Count) deploy or modify"; Members = @($members) }
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($rg in $ResourceGroupName) {
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"
    if (-not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)) { Write-Warning "$($rg): resource group not found; skipped."; continue }
    $existing = @(Get-AzPolicyExemption -Scope $scope -WarningAction SilentlyContinue | Where-Object { $_.Name -like 'azl-deploy-*' -and [string]$_.Description -like "$marker*" })

    if ($Remove) {
        foreach ($e in $existing) {
            $rows.Add([pscustomobject]@{ ResourceGroup = $rg; Assignment = $e.DisplayName; Effect = ''; Action = $(if ($Execute) { 'removed' } else { 'would remove' }) })
            if ($Execute) { Remove-AzPolicyExemption -Id $e.Id -Force -WarningAction SilentlyContinue | Out-Null }
        }
        if (-not $existing) { $rows.Add([pscustomobject]@{ ResourceGroup = $rg; Assignment = '(none from this script)'; Effect = ''; Action = 'nothing to remove' }) }
        continue
    }

    # Get-AzPolicyAssignment -Scope returns the assignments that apply there, inherited from management groups and
    # the subscription included; keep only the inherited ones (one assigned on the group itself is the owner's choice).
    $assignments = @(Get-AzPolicyAssignment -Scope $scope -WarningAction SilentlyContinue | Where-Object { $_.Scope -ne $scope })
    foreach ($a in $assignments) {
        $label = if ($a.DisplayName) { $a.DisplayName } else { $a.Name }
        $deploying = Get-DeployingMember $a
        $effect = $deploying.Effect
        $name = "azl-deploy-$(Get-ShortHash "$scope|$($a.Id)")"
        $already = @($existing | Where-Object Name -eq $name)
        $action =
            if ($ExcludeAssignmentName -contains $a.Name -or ($a.DisplayName -and $ExcludeAssignmentName -contains $a.DisplayName)) { 'excluded' }
            elseif (-not @($deploying.Members).Count) { 'left in force (doesn''t deploy or modify)' }
            elseif ($already) { "exempt until $($already[0].ExpiresOn)" }
            elseif ($Execute) { 'exempted' }
            else { 'would exempt' }
        if ($action -eq 'exempted') {
            $params = @{
                Name              = $name
                Scope             = $scope
                PolicyAssignment  = $a
                ExemptionCategory = 'Waiver'
                DisplayName       = "azl-deploy: $label"
                Description       = "$marker. Created $((Get-Date).ToUniversalTime().ToString('u')); remove with Set-AzlDeploymentPolicyExemption.ps1 -Remove -Execute."
                ExpiresOn         = (Get-Date).ToUniversalTime().AddDays($ExpiresInDays)
            }
            # In an initiative, only the members that deploy or modify are exempted; its audits stay in force.
            $refs = @($deploying.Members | Where-Object { $_ })
            if ($refs.Count) { $params.PolicyDefinitionReferenceId = $refs }
            # Azure answers a burst of exemption writes with a transient error ("try again after 60 seconds").
            for ($try = 1; ; $try++) {
                try { New-AzPolicyExemption @params -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null; break }
                catch {
                    if ($try -ge 4 -or $_.Exception.Message -notmatch "(?i)transient|try again") { throw }
                    Write-Warning "$($label): transient error, retrying in 60 s (attempt $try of 3)."; Start-Sleep -Seconds 60
                }
            }
        }
        $rows.Add([pscustomobject]@{ ResourceGroup = $rg; Assignment = "$label ($($a.Scope -replace '^/providers/Microsoft.Management/managementGroups/', 'mg:' -replace "^/subscriptions/$SubscriptionId$", 'subscription'))"; Effect = $effect; Action = $action })
    }
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Output

# Defender for Servers installs MDE.Windows on Arc machines itself; policy exemptions don't stop it.
try {
    $plan = Get-AzSecurityPricing -Name 'VirtualMachines' -WarningAction SilentlyContinue
    Write-Output "Defender for Servers on this subscription: $($plan.PricingTier)$(if ($plan.SubPlan) { " ($($plan.SubPlan))" }). An exemption doesn't stop it installing the Defender (MDE.Windows) extension on new Arc machines; turn it off per machine (Defender for Cloud resource-level pricing) if it interferes with provisioning."
}
catch { Write-Output "Defender for Servers plan: couldn't read it ($($_.Exception.Message)). An exemption doesn't stop Defender installing MDE.Windows on Arc machines." }
if (-not $Execute) { Write-Output 'List only. Add -Execute to make the change.' }
