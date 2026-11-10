<#
.SYNOPSIS
    Assigns the Tier 1 tag policy at one management group, in audit mode, from infrastructure.yml.

.DESCRIPTION
    Phase 04 (security and governance), Task 02 (Azure Policy). Tier 1 is the lightest governance layer: for each tag name in
    landing_zone.policy.required_tags this script assigns Microsoft's built-in policy "Require a tag on resources" at the management group
    landing_zone.policy.management_group (empty: the tenant root management group, whose id is azure.tenant_id), so the assignment
    cascades to every management group, subscription and resource group under it.

    Audit mode. The built-in definition has the fixed effect deny. Each assignment therefore sets the enforcement mode DoNotEnforce:
    Azure evaluates the resources and reports the ones without the tag as non-compliant, and denies nothing. Turning a tag into a hard
    requirement is a separate, deliberate change of the assignment; this script never does it and never changes an existing assignment.

    One assignment per tag, named req-tag-<tag> (lower case, at most 24 characters, because a policy assignment name is limited to 24
    characters at management group scope). Two tags that give the same name are refused before anything is created.

    Idempotent. An assignment that already exists (same id) is left alone and reported as AlreadyAssigned, with a warning when it
    enforces the tag instead of only reporting it. When the name is used by an assignment of another definition or of another tag, the
    tag is not covered: it is reported as Conflict, nothing is changed and the script exits 1. A second run with the same file creates
    nothing.

    The script reads Azure to find out what exists (read only) and writes only with New-AzPolicyAssignment, behind -WhatIf. It does not
    sign in: run Connect-AzAccount to the tenant in azure.tenant_id first. Assigning at the tenant root management group needs a role that
    can write policy assignments there (for example Resource Policy Contributor or Owner at that scope; a Global Administrator first has to
    elevate access to manage all Azure subscriptions and management groups).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                          the tenant; also the id of the tenant root management group
        landing_zone.policy.required_tags        the tag names to require (no default: the names follow your tagging standard)
        landing_zone.policy.management_group     optional; the management group to assign at

    Exit codes: 0 all assignments exist (created now or already there, or planned under -WhatIf); 1 an Azure call failed, a precondition
    failed (not signed in, wrong tenant, Az.Resources missing), an assignment could not be created or a name is in conflict; 2 the file is missing a value this
    script needs, or a value is not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the three keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository. No secret is ever written: there is none to write.

.EXAMPLE
    ./Invoke-AzurePolicyTier1-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which assignments would be created at the management group, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Invoke-AzurePolicyTier1-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the missing assignments. Run it again: it reports every assignment as AlreadyAssigned and changes nothing.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common'))
Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force

# Microsoft's built-in policy "Require a tag on resources" (Microsoft Learn: Azure Policy built-in definitions, Tags). Parameter tagName; effect deny; mode Indexed.
$RequireTagDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99'
$AssignmentPrefix = 'req-tag-'
$MaxAssignmentNameLength = 24   # Microsoft.Authorization/policyAssignments at management group scope
$MaxTagLength = 80              # the display name of the assignment holds the tag and is limited to 128 characters

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}

function Exit-InputProblem([string]$Message) {
    Write-Error $Message -ErrorAction Continue
    exit 2
}

function Exit-Failed([string]$Message) {
    Write-Error $Message -ErrorAction Continue
    exit 1
}

function Get-AssignmentName([string]$Tag) {
    $clean = ($Tag.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($clean.Length -gt ($MaxAssignmentNameLength - $AssignmentPrefix.Length)) { $clean = $clean.Substring(0, $MaxAssignmentNameLength - $AssignmentPrefix.Length).TrimEnd('-') }
    if (-not $clean) { return $null }
    return "$AssignmentPrefix$clean"
}

# The tag an existing assignment reports (its tagName parameter), or $null when it cannot be read. Az.Resources 7 and later return the
# parameters as a model object (ToJsonString) or a custom object; older versions keep them under Properties.Parameters.
function Get-AssignedTagName($Assignment) {
    $parameters = $null
    foreach ($property in 'Parameter', 'Parameters') {
        if ($Assignment.PSObject.Properties[$property] -and $null -ne $Assignment.$property) { $parameters = $Assignment.$property; break }
    }
    if ($null -eq $parameters -and $Assignment.PSObject.Properties['Properties'] -and $null -ne $Assignment.Properties -and $Assignment.Properties.PSObject.Properties['Parameters']) {
        $parameters = $Assignment.Properties.Parameters
    }
    if ($null -eq $parameters) { return $null }
    try {
        $json = if ($parameters -is [string]) { $parameters } elseif ($parameters.PSObject.Methods['ToJsonString']) { $parameters.ToJsonString() } else { $parameters | ConvertTo-Json -Depth 6 -Compress }
        $map = $json | ConvertFrom-Json -AsHashtable
        if ($map -isnot [System.Collections.IDictionary]) { return $null }
        foreach ($key in @($map.Keys)) {
            if ($key -ne 'tagName') { continue }
            $entry = $map[$key]
            if ($entry -is [string]) { return $entry }
            if ($entry -is [System.Collections.IDictionary]) { foreach ($inner in @($entry.Keys)) { if ($inner -eq 'value' -and $null -ne $entry[$inner]) { return [string]$entry[$inner] } } }
        }
    }
    catch { return $null }
    return $null
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$groupName = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.policy.management_group')
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.policy.required_tags'
$tags = @(@($rawTags) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })

if ($tenantId -notmatch '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$') { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant to sign in to and the id of the tenant root management group.' }
if ($tags.Count -eq 0) { Exit-InputProblem 'landing_zone.policy.required_tags is empty. List the tag names your tagging standard requires; this script assumes none.' }
if ($groupName -and $groupName -notmatch '^[A-Za-z0-9]([A-Za-z0-9._()-]{0,88}[A-Za-z0-9_()-])?$') { Exit-InputProblem "landing_zone.policy.management_group '$groupName' is not a valid management group id (1 to 90 letters, digits, . _ - ( ); starts with a letter or digit, does not end with a period)." }

$names = @{}
foreach ($tag in $tags) {
    if ($tag.Length -gt $MaxTagLength) { Exit-InputProblem "The tag name '$tag' is longer than $MaxTagLength characters." }
    if ($tag -match '[<>%&\\?/]') { Exit-InputProblem "The tag name '$tag' contains a character Azure does not allow in a tag name (< > % & \ ? /)." }
    $name = Get-AssignmentName $tag
    if (-not $name) { Exit-InputProblem "The tag name '$tag' has no letter or digit to build an assignment name from." }
    if ($names.ContainsKey($name)) { Exit-InputProblem "The tag names '$($names[$name])' and '$tag' give the same assignment name '$name'. Remove one, or rename a tag." }
    $names[$name] = $tag
}

$managementGroupId = if ($groupName) { $groupName } else { $tenantId }
$scope = "/providers/Microsoft.Management/managementGroups/$managementGroupId"

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Get-AzPolicyDefinition', 'Get-AzPolicyAssignment', 'New-AzPolicyAssignment') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Resources modules: Install-Module Az.Accounts, Az.Resources -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }

try { $definition = Get-AzPolicyDefinition -Id $RequireTagDefinitionId }
catch { Exit-Failed "The built-in policy definition $RequireTagDefinitionId could not be read: $($_.Exception.Message)" }
if (-not $definition) { Exit-Failed "The built-in policy definition $RequireTagDefinitionId was not found." }
# Az.Resources 7 and later return DisplayName on the object; older versions keep it under Properties.
$definitionName = if ($definition.PSObject.Properties['DisplayName'] -and $definition.DisplayName) { [string]$definition.DisplayName } else { 'Require a tag on resources' }

Write-Line "Tier 1 tag policy at $scope"
Write-Line "Mode: audit (enforcement mode DoNotEnforce); $($tags.Count) tag(s): $($tags -join ', ')"

# ---- one assignment per tag
$results = foreach ($tag in $tags) {
    $name = Get-AssignmentName $tag
    $id = "$scope/providers/Microsoft.Authorization/policyAssignments/$name"
    $row = [ordered]@{ Tag = $tag; Name = $name; Action = ''; Detail = '' }
    try {
        $existing = $null
        try { $existing = Get-AzPolicyAssignment -Id $id -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch 'NotFound|could not be found|does not exist|\b404\b') { throw } }

        if ($existing) {
            $mode = if ($existing.PSObject.Properties['EnforcementMode']) { [string]$existing.EnforcementMode } else { '' }
            $defId = if ($existing.PSObject.Properties['PolicyDefinitionId']) { [string]$existing.PolicyDefinitionId } else { '' }
            $assignedTag = Get-AssignedTagName $existing
            if (($defId -and $defId -ne $RequireTagDefinitionId) -or ($assignedTag -and $assignedTag -ne $tag)) {
                # The name is taken by an assignment that does not report this tag, so the tag is not covered. Nothing is changed.
                $row.Action = 'Conflict'
                $row.Detail = "The name is used by another assignment (definition '$defId', tag '$assignedTag'); left unchanged. Remove or rename it, then run again."
                Write-Warning "${name}: $($row.Detail)"
            }
            else {
                $row.Action = 'AlreadyAssigned'
                if ($mode -and $mode -ne 'DoNotEnforce') {
                    $row.Detail = "Differs from Tier 1 (enforcement mode '$mode': the tag is enforced, not only reported); left unchanged."
                    Write-Warning "${name}: $($row.Detail)"
                }
                Write-Line "[exists]  $name ($tag): already assigned, nothing changed."
            }
        }
        elseif ($PSCmdlet.ShouldProcess($id, "Assign '$definitionName' for tag '$tag' in audit mode")) {
            $assignment = @{
                Name                 = $name
                Scope                = $scope
                DisplayName          = "Require tag '$tag' on resources (audit)"
                Description          = "Tier 1: report resources without the tag '$tag'. Enforcement mode DoNotEnforce: non-compliance is reported and nothing is denied."
                PolicyDefinition     = $definition
                PolicyParameterObject = @{ tagName = $tag }
                EnforcementMode      = 'DoNotEnforce'
                ErrorAction          = 'Stop'
            }
            $null = New-AzPolicyAssignment @assignment
            $row.Action = 'Created'
            Write-Line "[created] $name ($tag): assigned in audit mode."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    $name ($tag): would be assigned in audit mode."
        }
    }
    catch {
        $row.Action = 'Failed'
        $row.Detail = $_.Exception.Message
        Write-Warning "${name}: $($row.Detail)"
    }
    [pscustomobject]$row
}

$results = @($results)
$created = @($results | Where-Object Action -EQ 'Created').Count
$already = @($results | Where-Object Action -EQ 'AlreadyAssigned').Count
$planned = @($results | Where-Object Action -EQ 'WouldCreate').Count
$conflicts = @($results | Where-Object Action -EQ 'Conflict').Count
$failed = @($results | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $created created, $already already assigned, $planned planned, $conflicts in conflict, $failed failed."
if ($created -eq 0 -and $planned -eq 0 -and $conflicts -eq 0 -and $failed -eq 0) { Write-Line 'Nothing to do: every assignment exists.' }

[pscustomobject]@{ Scope = $scope; Created = $created; AlreadyAssigned = $already; Planned = $planned; Conflict = $conflicts; Failed = $failed; Assignments = $results }
if ($failed -gt 0 -or $conflicts -gt 0) { exit 1 }
exit 0
