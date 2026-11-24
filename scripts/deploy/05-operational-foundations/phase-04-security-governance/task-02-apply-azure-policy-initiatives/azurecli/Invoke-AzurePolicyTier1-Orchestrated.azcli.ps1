<#
.SYNOPSIS
    Assigns the Tier 1 tag policy at one management group, in audit mode, with the Azure CLI, from infrastructure.yml.

.DESCRIPTION
    Phase 04 (security and governance), Task 02 (Azure Policy), Azure CLI variant of Invoke-AzurePolicyTier1-Orchestrated.ps1. Tier 1 is the lightest
    governance layer: for each tag name in landing_zone.policy.required_tags this script assigns Microsoft's built-in policy "Require a tag on resources"
    at the management group landing_zone.policy.management_group (empty: the tenant root management group, whose id is azure.tenant_id), so the
    assignment cascades to every management group, subscription and resource group under it. It reads with az policy assignment show and creates each
    assignment with az rest (a PUT of the assignment resource): az policy assignment create (Azure CLI 2.90) looks a built-in definition up in the
    management group of the scope, gets PolicyDefinitionNotFound and fails.

    Audit mode. The built-in definition has the fixed effect deny. Each assignment therefore sets the enforcement mode DoNotEnforce: Azure evaluates the
    resources and reports the ones without the tag as non-compliant, and denies nothing. Turning a tag into a hard requirement is a separate, deliberate
    change of the assignment; this script never does it and never changes an existing assignment. The assignment has no managed identity and no role:
    the policy has no deployIfNotExists or modify effect.

    One assignment per tag, named req-tag-<tag> (lower case, at most 24 characters, because a policy assignment name is limited to 24 characters at
    management group scope). Two tags that give the same name are refused before anything is created.

    Idempotent. An assignment that already exists (same name at that scope) is left alone and reported as AlreadyAssigned, with a warning when it enforces
    the tag instead of only reporting it. When the name is used by an assignment of another definition or of another tag, the tag is not covered: it is
    reported as Conflict, nothing is changed and the script exits 1. A second run with the same file creates nothing. -WhatIf changes nothing.

    The assignment (its display name, description, definition, the tag name and the enforcement mode) goes to Azure in a body file that the script
    writes to a temporary file and deletes again: the Azure CLI is started through a command file on Windows, which would misread the quotes of a JSON
    text on the command line. The file holds nothing secret.

    The script does not sign in: run az login to the tenant in azure.tenant_id first. Assigning at the tenant root management group needs a role that can
    write policy assignments there (for example Resource Policy Contributor or Owner at that scope; a Global Administrator first has to elevate access to
    manage all Azure subscriptions and management groups).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                          the tenant; also the id of the tenant root management group
        landing_zone.policy.required_tags        the tag names to require (no default: the names follow your tagging standard)
        landing_zone.policy.management_group     optional; the management group to assign at

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 all assignments exist (created now or already there, or planned under -WhatIf); 1 an Azure call failed, a precondition failed (az
    missing, not signed in, wrong tenant), an assignment could not be created or a name is in conflict; 2 the file is missing a value this script needs,
    or a value is not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the three keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Invoke-AzurePolicyTier1-Orchestrated.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which assignments would be created at the management group, and creates nothing.
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
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'azure-cli', 'AzlAzureCliArgument.psm1')) -Force

# Microsoft's built-in policy "Require a tag on resources" (Microsoft Learn: Azure Policy built-in definitions, Tags). Parameter tagName; effect deny; mode Indexed.
$RequireTagDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99'
$AssignmentPrefix = 'req-tag-'
$MaxAssignmentNameLength = 24   # Microsoft.Authorization/policyAssignments at management group scope
$MaxTagLength = 80              # the display name of the assignment holds the tag and is limited to 128 characters
$AssignmentApiVersion = '2023-04-01'   # Microsoft.Authorization/policyAssignments, the version the assignment is written with
$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the text of standard output; throws when az ends with an error.
function Invoke-Az {
    $arguments = @($args | ForEach-Object { $_ } | ForEach-Object { [string]$_ })
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $arguments
    if ($unsafe) { Exit-InputProblem $unsafe }
    $all = @(& az @arguments '--only-show-errors' 2>&1)
    $code = $LASTEXITCODE
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw $(if ($err) { $err.Trim() } else { $out.Trim() }) }
    $out.Trim()
}
function Get-AssignmentName([string]$Tag) {
    $clean = ($Tag.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($clean.Length -gt ($MaxAssignmentNameLength - $AssignmentPrefix.Length)) { $clean = $clean.Substring(0, $MaxAssignmentNameLength - $AssignmentPrefix.Length).TrimEnd('-') }
    if (-not $clean) { return $null }
    return "$AssignmentPrefix$clean"
}
# The tag an existing assignment reports (its tagName parameter), or $null when it cannot be read.
function Get-AssignedTagName($Assignment) {
    $parameters = $null
    if ($Assignment.PSObject.Properties['parameters']) { $parameters = $Assignment.parameters }
    elseif ($Assignment.PSObject.Properties['properties'] -and $Assignment.properties -and $Assignment.properties.PSObject.Properties['parameters']) { $parameters = $Assignment.properties.parameters }
    if ($null -eq $parameters -or -not $parameters.PSObject.Properties['tagName']) { return $null }
    $entry = $parameters.tagName
    if ($entry -is [string]) { return $entry }
    if ($null -ne $entry -and $entry.PSObject.Properties['value'] -and $null -ne $entry.value) { return [string]$entry.value }
    $null
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$groupName = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.policy.management_group')
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.policy.required_tags'
$tags = @(@($rawTags) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant to sign in to and the id of the tenant root management group.' }
if ($tags.Count -eq 0) { Exit-InputProblem 'landing_zone.policy.required_tags is empty. List the tag names your tagging standard requires; this script assumes none.' }
if ($groupName -and $groupName -notmatch '^[A-Za-z0-9]([A-Za-z0-9._()-]{0,88}[A-Za-z0-9_()-])?$') { Exit-InputProblem "landing_zone.policy.management_group '$groupName' is not a valid management group id (1 to 90 letters, digits, . _ - ( ); starts with a letter or digit, does not end with a period)." }

$names = @{}
foreach ($tag in $tags) {
    if ($tag.Length -gt $MaxTagLength) { Exit-InputProblem "The tag name '$tag' is longer than $MaxTagLength characters." }
    if ($tag -match '[<>%&\\?/]') { Exit-InputProblem "The tag name '$tag' contains a character Azure does not allow in a tag name (< > % & \ ? /)." }
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "the tag name $tag" = $tag }); if ($problem) { Exit-InputProblem $problem }
    $name = Get-AssignmentName $tag
    if (-not $name) { Exit-InputProblem "The tag name '$tag' has no letter or digit to build an assignment name from." }
    if ($names.ContainsKey($name)) { Exit-InputProblem "The tag names '$($names[$name])' and '$tag' give the same assignment name '$name'. Remove one, or rename a tag." }
    $names[$name] = $tag
}

$managementGroupId = if ($groupName) { $groupName } else { $tenantId }
$scope = "/providers/Microsoft.Management/managementGroups/$managementGroupId"
$definitionName = $RequireTagDefinitionId.Split('/')[-1]

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A value that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'landing_zone.policy.management_group' = $groupName })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Invoke-AzurePolicyTier1-Orchestrated.ps1.' }
try { $signedInTenant = Invoke-Az account show --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }
try { $definition = Invoke-Az policy definition show --name $definitionName --output json | ConvertFrom-Json }
catch { Exit-Failed "The built-in policy definition $RequireTagDefinitionId could not be read: $($_.Exception.Message)" }
if (-not $definition) { Exit-Failed "The built-in policy definition $RequireTagDefinitionId was not found." }
$definitionDisplayName = if ($definition.PSObject.Properties['displayName'] -and $definition.displayName) { [string]$definition.displayName } else { 'Require a tag on resources' }

Write-Line "Tier 1 tag policy at $scope"
Write-Line "Mode: audit (enforcement mode DoNotEnforce); $($tags.Count) tag(s): $($tags -join ', ')"

# ---- one assignment per tag
$results = foreach ($tag in $tags) {
    $name = Get-AssignmentName $tag
    $id = "$scope/providers/Microsoft.Authorization/policyAssignments/$name"
    $row = [ordered]@{ Tag = $tag; Name = $name; Action = ''; Detail = '' }
    $parameterFile = $null
    try {
        $existing = $null
        try { $existing = Invoke-Az policy assignment show --name $name --scope $scope --output json | ConvertFrom-Json }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

        if ($existing) {
            $mode = if ($existing.PSObject.Properties['enforcementMode']) { [string]$existing.enforcementMode } else { '' }
            $defId = if ($existing.PSObject.Properties['policyDefinitionId']) { [string]$existing.policyDefinitionId } else { '' }
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
        elseif ($PSCmdlet.ShouldProcess($id, "Assign '$definitionDisplayName' for tag '$tag' in audit mode")) {
            # A PUT of the assignment through az rest, not az policy assignment create: at a management group scope, Azure CLI 2.90 looks the
            # built-in definition up in that management group, gets PolicyDefinitionNotFound and fails (tplabs, 2026-11-23). az rest puts the ARM
            # endpoint of the current cloud in front of the resource id. The body (tag, display name, description) goes in a temporary file.
            # A PUT replaces: an assignment of this name made between the show above and this call would be overwritten. Microsoft.Authorization
            # ignores If-None-Match on policy assignments (tried 2026-11-23), so the show is the guard, as with New-AzPolicyAssignment in the twin.
            $parameterFile = [IO.Path]::GetTempFileName()
            $body = [ordered]@{
                properties = [ordered]@{
                    displayName        = "Require tag '$tag' on resources (audit)"
                    description        = "Tier 1: report resources without the tag '$tag'. Enforcement mode DoNotEnforce: non-compliance is reported and nothing is denied."
                    policyDefinitionId = $RequireTagDefinitionId
                    parameters         = [ordered]@{ tagName = [ordered]@{ value = $tag } }
                    enforcementMode    = 'DoNotEnforce'
                }
            }
            Set-Content -LiteralPath $parameterFile -Value ($body | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8NoBOM
            $null = Invoke-Az rest --method put --url "$id`?api-version=$AssignmentApiVersion" --body "@$parameterFile" --output none
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
    finally {
        if ($parameterFile -and (Test-Path -LiteralPath $parameterFile)) { Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue }
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
