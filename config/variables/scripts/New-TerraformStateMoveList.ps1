#Requires -Version 7.0
<#
.SYNOPSIS
    Lists the terraform state mv commands that move an existing landing zone state to the addresses of the current landing zone module.

.DESCRIPTION
    Before registry 5.0.62 (owner directive D121) the landing zone module of src/terraform held one resource per role of the fixed Azure
    landing zone hierarchy: module.landing_zone.azurerm_management_group.root, platform, identity, connectivity, management, security and
    landing_zones, and module.landing_zone.azurerm_management_group_subscription_association.connectivity[0], identity[0], management[0],
    security[0] and azure_local[0]. The module now builds the tree from landing_zone.management_groups[] (name and parent) and keys every
    group by its name, level by level (azurerm_management_group.level0["<name>"] to level5["<name>"]), and keys every subscription
    association by the subscription's name (azurerm_management_group_subscription_association.subscriptions["<name>"]). A state written by
    the old module would make Terraform destroy every group and create it again. Moving the state first keeps the groups.

    This script reads infrastructure.yml and prints, for each old address, the new address and the command, in the order to run them. It
    computes the level of each group the way the module does (a group whose parent is not in the list is level 0, its children level 1, and so
    on). It does not run Terraform and changes nothing in Azure or in a state. It writes a file only with -OutputPath.

    Old address -> new address:
        azurerm_management_group.<role>                          -> azurerm_management_group.level<N>["<name of the group with that role>"]
        azurerm_management_group_subscription_association.<role>[0], role connectivity, identity, management, security
                                                                 -> ...association.subscriptions["<name of the subscription with that role>"]
        azurerm_management_group_subscription_association.azure_local[0] (azure.subscription_id)
                                                                 -> ...association.subscriptions["<name of the subscription with that id>"]
    An old association the old module never made (its subscription had no id) is listed as None, without a command. An old association whose
    subscription the module no longer associates (azure.subscription_id is in no entry, or the entry has no id or no management_group) is
    listed as terraform state rm: the association stays in Azure, Terraform just forgets it. A role that no group of the file has is listed as
    Check: the old module needed every role, so look at terraform state list.

    Run the commands in src/terraform/environments/azure-local after terraform init with the generated backend.hcl, then run terraform plan
    and read it: it must show no management group or association to destroy. The lines quote the new address with single quotes; that works
    in bash and in PowerShell 7.3 or later (which passes the double quotes inside on to terraform). See src/terraform/README.md, "Moving an
    existing landing zone state".

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure, without validation):
        landing_zone.management_groups[]   name, parent, role
        landing_zone.subscriptions[]       name, id, role, management_group
        azure.subscription_id              the subscription of the instance (the old azure_local association)

    Exit codes: 0 the list is printed (and written with -OutputPath, or planned under -WhatIf); 1 the output file could not be written;
    2 the file cannot be read, has no landing_zone.management_groups, or two groups (or two subscriptions) share a role, or a group's
    parent chain is deeper than six levels or loops.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5) of the environment whose state is moved.

.PARAMETER OutputPath
    Optional. Also write the commands, one per line with a comment above each, to this file (for example D:\work\iac\state-moves.txt). Keep it
    out of the repository: it holds the names of the environment.

.EXAMPLE
    ./New-TerraformStateMoveList.ps1 -InfrastructureFile ./infrastructure.yml

    Prints one row per old address: Kind, From, To, Command, Note.

.EXAMPLE
    ./New-TerraformStateMoveList.ps1 -InfrastructureFile ./infrastructure.yml -OutputPath D:\work\iac\state-moves.txt

    Also writes the commands to the file.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

# The addresses of the landing zone module in the azure-local root module (src/terraform/environments/azure-local/main.tf, module "landing_zone").
$Module = 'module.landing_zone'
$GroupType = 'azurerm_management_group'
$AssociationType = 'azurerm_management_group_subscription_association'
# The roles of the old module, in the order it created the groups, and the roles that had a subscription association.
$GroupRoles = @('root', 'platform', 'identity', 'connectivity', 'management', 'security', 'landing_zones')
$AssociationRoles = @('connectivity', 'identity', 'management', 'security')
# A management group tree has at most six levels below the tenant root (the module creates level0 to level5).
$MaxLevels = 6

function Exit-InputProblem([string]$Message) {
    Write-Error $Message -ErrorAction Continue
    exit 2
}
function Get-Text($Map, [string]$Key) {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key]) { return ([string]$Map[$Key]).Trim() }
    ''
}
function Get-List($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IList]) { return @($Value) }
    @($Value)
}

try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$groups = @(Get-List (Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.management_groups') | Where-Object { $_ -is [System.Collections.IDictionary] -and (Get-Text $_ 'name') })
$subscriptions = @(Get-List (Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions') | Where-Object { $_ -is [System.Collections.IDictionary] -and (Get-Text $_ 'name') })
$instanceSubscription = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
if (-not $groups.Count) { Exit-InputProblem 'landing_zone.management_groups is missing or empty: there is no landing zone state to move.' }

# The level of each group, as the module computes it.
$names = @($groups | ForEach-Object { Get-Text $_ 'name' })
$parentOf = [hashtable]::new([StringComparer]::Ordinal) # Terraform compares names case-sensitively
foreach ($g in $groups) { $parentOf[(Get-Text $g 'name')] = Get-Text $g 'parent' }
$level = [hashtable]::new([StringComparer]::Ordinal)
foreach ($n in $names) { if ($parentOf[$n] -cnotin $names) { $level[$n] = 0 } }
for ($l = 1; $l -lt $MaxLevels; $l++) {
    foreach ($n in $names) { if (-not $level.ContainsKey($n) -and $level.ContainsKey($parentOf[$n]) -and $level[$parentOf[$n]] -eq ($l - 1)) { $level[$n] = $l } }
}
$unplaced = @($names | Where-Object { -not $level.ContainsKey($_) })
if ($unplaced.Count) { Exit-InputProblem "landing_zone.management_groups[] is deeper than six levels, or a parent chain loops ($($unplaced -join ', ')); the module refuses it too." }

function Get-ByRole([object[]]$Item, [string]$Role, [string]$What) {
    $found = @($Item | Where-Object { (Get-Text $_ 'role') -eq $Role })
    if ($found.Count -gt 1) { Exit-InputProblem "$What has more than one entry with role $Role ($(@($found | ForEach-Object { Get-Text $_ 'name' }) -join ', ')); the old module had one, so the move is ambiguous." }
    if ($found.Count) { return $found[0] }
    $null
}
function New-Row([string]$Kind, [string]$From, [string]$To, [string]$Note) {
    $command = if ($Kind -eq 'Move') { "terraform state mv '$From' '$To'" } elseif ($Kind -eq 'Forget') { "terraform state rm '$From'" } else { '' }
    [pscustomobject]@{ Kind = $Kind; From = $From; To = $To; Command = $command; Note = $Note }
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($role in $GroupRoles) {
    $from = "$Module.$GroupType.$role"
    $g = Get-ByRole $groups $role 'landing_zone.management_groups[]'
    if (-not $g) { $rows.Add((New-Row 'Check' $from '' "No group of landing_zone.management_groups[] has role $role. If terraform state list shows $from, give that group role $role (or move it by hand to the address level<N>[""<name>""] of its name).")); continue }
    $name = Get-Text $g 'name'
    $rows.Add((New-Row 'Move' $from "$Module.$GroupType.level$($level[$name])[""$name""]" "management group $name (role $role, level $($level[$name]))"))
}

function Add-AssociationRow([string]$From, $Subscription, [string]$What, [string]$OldId) {
    # The old module made the association only when its subscription id was set (count = id != "" ? 1 : 0): without one there is nothing to move.
    if (-not $OldId) { $rows.Add((New-Row 'None' $From '' "The old module made no association here ($What had no id), so there is nothing to move.")); return }
    if (-not $Subscription) { $rows.Add((New-Row 'Forget' $From '' "No entry of landing_zone.subscriptions[] is $What, so the module no longer manages this association. terraform state rm keeps it in Azure; skip the line if terraform state list does not show the address."))
        return }
    $name = Get-Text $Subscription 'name'
    $group = Get-Text $Subscription 'management_group'
    if (-not (Get-Text $Subscription 'id') -or -not $group) { $rows.Add((New-Row 'Forget' $From '' "landing_zone.subscriptions[] entry $name has no id or no management_group, so the module does not associate it. terraform state rm keeps the association in Azure.")); return }
    $rows.Add((New-Row 'Move' $From "$Module.$AssociationType.subscriptions[""$name""]" "subscription $name under management group $group; the plan shows a change if the old module had put it under another group"))
}
foreach ($role in $AssociationRoles) {
    $sub = Get-ByRole $subscriptions $role 'landing_zone.subscriptions[]'
    Add-AssociationRow "$Module.$AssociationType.${role}[0]" $sub "the subscription with role $role" $(if ($sub) { Get-Text $sub 'id' } else { '' })
}
$instance = $null
if ($instanceSubscription) { $instance = @($subscriptions | Where-Object { (Get-Text $_ 'id') -ieq $instanceSubscription }) | Select-Object -First 1 }
Add-AssociationRow "$Module.$AssociationType.azure_local[0]" $instance 'the subscription of azure.subscription_id' $instanceSubscription

# Two old addresses must never move to one new address.
$dup = @($rows | Where-Object { $_.Kind -eq 'Move' } | Group-Object To | Where-Object Count -GT 1 | ForEach-Object Name)
if ($dup.Count) { Exit-InputProblem "Two old addresses would move to the same new address ($($dup -join ', ')): one subscription has two roles, or azure.subscription_id is also a role's subscription. Run the lines by hand and drop the duplicate with terraform state rm." }

if ($OutputPath) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by config/variables/scripts/New-TerraformStateMoveList.ps1. Run in src/terraform/environments/azure-local after terraform init, then terraform plan.')
    foreach ($r in $rows) {
        $lines.Add("# $($r.Kind): $($r.Note)")
        if ($r.Command) { $lines.Add($r.Command) } else { $lines.Add("# (no command) $($r.From)") }
    }
    if ($PSCmdlet.ShouldProcess($OutputPath, "Write $(@($rows | Where-Object Command).Count) terraform state command(s)")) {
        try { Set-Content -LiteralPath $OutputPath -Value $lines -Encoding utf8 }
        catch { Write-Error "Cannot write ${OutputPath}: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
    }
}

$rows
exit 0
