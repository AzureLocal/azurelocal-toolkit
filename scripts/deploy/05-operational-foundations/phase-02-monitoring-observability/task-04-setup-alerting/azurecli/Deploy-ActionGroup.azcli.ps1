<#
.SYNOPSIS
    Creates the Azure Monitor action group that tells the operations team about alerts, with the Azure CLI, from infrastructure.yml.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 04 (set up alerting), Azure CLI variant of Deploy-ActionGroup.ps1. Creates the action group
    operations.monitoring.action_group in the resource group of the monitoring resources (operations.monitoring.workspace_resource_group), with one email
    receiver for each address of operations.notifications.emails and operations.monitoring.alert_email (duplicates are joined). The alert rules point at
    this group.

    It creates only the action group. It does not create alert rules or the data collection endpoint. When operations.monitoring.enabled is false the
    design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent, and additive. A group that exists is not recreated and no receiver is removed: an address the file lists and the group lacks is added to
    the group (az monitor action-group update --add-action email; the receivers it already has, of any kind, are kept); a second run with the same file
    changes nothing. -WhatIf changes nothing.

    The short name of an action group (at most 12 characters, shown in SMS and email subjects) is made from the group name: its letters and digits, cut
    to 12. An email receiver is named 'email-' and its address with each character that is not a letter or a digit made a hyphen; when that name is
    already taken (by another receiver of the group, or by another address that gives the same name), the first 8 hex digits of the SHA-256 of the
    address are added, because Azure requires every receiver name of a group to be unique. An action group is global: az monitor action-group create uses the location Global by default, and the script passes none.

    The script does not sign in: run az login to the tenant in azure.tenant_id first. It does not change the Azure CLI default subscription: every call
    carries --subscription. You need Monitoring Contributor (or Contributor) on the resource group. The file-level tags map is put on a group it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, tags
        operations.monitoring.enabled                    false means: do nothing
        operations.monitoring.workspace_resource_group   the resource group of the action group
        operations.monitoring.action_group               the name of the action group
        operations.monitoring.alert_email                an address that receives alerts
        operations.notifications.emails                  the addresses that receive notifications

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 the action group exists with every listed address (created now, already there, receivers added, or planned under -WhatIf) or monitoring
    is switched off in the file; 1 an Azure call failed or a precondition failed (az missing, not signed in, wrong tenant, the creation or the update
    failed); 2 a value in the file is missing or not usable, or no email address is listed.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-ActionGroup.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the group would be created or which receivers would be added, and changes nothing.
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

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
$Email = '^[^@\s,;<>()\[\]\\"]+@[^@\s,;<>()\[\]\\"]+\.[^@\s,;<>()\[\]\\"]+$'

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

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$subscriptionId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')
$monitoring = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring'
$rawEmails = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.notifications.emails'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tagArguments = @()
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tagArguments += "$k=$($rawTags[$k])" } } }

function Get-Field([string]$Key) {
    if ($monitoring -is [System.Collections.IDictionary] -and $monitoring.Contains($Key) -and $null -ne $monitoring[$Key]) { return ([string]$monitoring[$Key]).Trim() }
    ''
}

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($monitoring -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'operations.monitoring is missing. Describe the monitoring resources and the action group.' }
if ((Get-Field 'enabled').ToLowerInvariant() -eq 'false') {
    Write-Line 'operations.monitoring.enabled is false: Azure Monitor is not part of the design, so no action group is created.'
    exit 0
}
$groupName = Get-Field 'action_group'
$resourceGroup = Get-Field 'workspace_resource_group'
if (-not $groupName) { Exit-InputProblem 'operations.monitoring.action_group is missing. Name the action group to create.' }
if ($groupName -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,258}[A-Za-z0-9_()-]$|^[A-Za-z0-9]$') { Exit-InputProblem "operations.monitoring.action_group '$groupName' is not a valid action group name (1 to 260 characters; letters, digits, space, . _ - ( ); starts with a letter or digit)." }
if (-not $resourceGroup) { Exit-InputProblem 'operations.monitoring.workspace_resource_group is missing. It is the resource group of the action group.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
$shortName = ($groupName -replace '[^A-Za-z0-9]', '')
if ($shortName.Length -gt 12) { $shortName = $shortName.Substring(0, 12) }
if (-not $shortName) { Exit-InputProblem "operations.monitoring.action_group '$groupName' has no letter or digit to make the 12-character short name from." }
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = $tagArguments }); if ($problem) { Exit-InputProblem $problem }

$addresses = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in @(@($rawEmails) + @(Get-Field 'alert_email'))) {
    if ($null -eq $candidate -or [string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    $address = ([string]$candidate).Trim()
    if ($address -notmatch $Email) { Exit-InputProblem "The address '$address' (operations.notifications.emails or operations.monitoring.alert_email) is not an email address." }
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "the address $address" = $address }); if ($problem) { Exit-InputProblem $problem }
    if (-not @($addresses | Where-Object { $_ -ieq $address })) { $addresses.Add($address) }
}
if ($addresses.Count -eq 0) { Exit-InputProblem 'No email address: list at least one in operations.notifications.emails or operations.monitoring.alert_email, or the action group would tell nobody.' }

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A value that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'operations.monitoring.action_group' = $groupName; 'operations.monitoring.workspace_resource_group' = $resourceGroup })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Deploy-ActionGroup.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

# The receiver names already in use: Azure requires a name to be unique across every receiver of an action group, of any kind.
$takenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

# The name of the email receiver of an address: 'email-' and the address with each character that is not a letter or a digit made a hyphen.
# Two addresses can give the same name (a.b@x.test and a-b@x.test), and a receiver of the group may already have it: such a name takes the
# first 8 hex digits of the SHA-256 of the address as a suffix, so every receiver keeps a unique, repeatable name.
function Get-ReceiverName([string]$Address) {
    $name = 'email-' + ($Address -replace '[^A-Za-z0-9]', '-')
    if ($takenNames.Contains($name)) { $name += '-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Address.ToLowerInvariant()))).Substring(0, 8).ToLowerInvariant() }
    $null = $takenNames.Add($name)
    $name
}

# One email receiver as the --action / --add-action arguments of az monitor action-group: email NAME ADDRESS.
function Get-ReceiverArgument([string]$Option, [string]$Address) { @($Option, 'email', (Get-ReceiverName $Address), $Address) }

Write-Line "Action group '$groupName' in '$resourceGroup', $($addresses.Count) email address(es)"

$row = [ordered]@{ ActionGroup = $groupName; Action = ''; Receivers = @($addresses); Added = @(); Detail = '' }
try {
    $existing = $null
    try { $existing = Invoke-Az monitor action-group show --subscription $subscriptionId --resource-group $resourceGroup --name $groupName --output json | ConvertFrom-Json }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

    if (-not $existing) {
        if ($PSCmdlet.ShouldProcess("action group '$groupName' in '$resourceGroup'", "Create with $($addresses.Count) email receiver(s)")) {
            $arguments = @('monitor', 'action-group', 'create', '--subscription', $subscriptionId, '--resource-group', $resourceGroup, '--name', $groupName, '--short-name', $shortName)
            foreach ($address in $addresses) { $arguments += Get-ReceiverArgument '--action' $address }
            if ($tagArguments.Count) { $arguments += @('--tags') + $tagArguments }
            $null = Invoke-Az ($arguments + @('--output', 'none'))
            $row.Action = 'Created'
            Write-Line "[created] '$groupName' with $($addresses -join ', ')."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    '$groupName' would be created with $($addresses -join ', ')."
        }
    }
    else {
        $haveReceivers = @()
        if ($existing.PSObject.Properties['emailReceivers'] -and $existing.emailReceivers) { $haveReceivers = @($existing.emailReceivers) }
        $haveAddresses = @($haveReceivers | ForEach-Object { [string]$_.emailAddress })
        $missing = @($addresses | Where-Object { $a = $_; -not @($haveAddresses | Where-Object { $_ -ieq $a }) })
        if ($missing.Count -eq 0) {
            $row.Action = 'AlreadyExists'
            Write-Line "[exists]  '$groupName' is already there with every listed address, nothing changed."
        }
        elseif ($PSCmdlet.ShouldProcess("action group '$groupName'", "Add the email receiver(s) $($missing -join ', ') (the receivers it has are kept)")) {
            foreach ($property in @($existing.PSObject.Properties | Where-Object Name -Like '*Receivers')) {
                foreach ($receiver in @($property.Value)) { if ($receiver -and $receiver.PSObject.Properties['name'] -and $receiver.name) { $null = $takenNames.Add([string]$receiver.name) } }
            }
            $arguments = @('monitor', 'action-group', 'update', '--subscription', $subscriptionId, '--resource-group', $resourceGroup, '--name', $groupName)
            foreach ($address in $missing) { $arguments += Get-ReceiverArgument '--add-action' $address }
            $null = Invoke-Az ($arguments + @('--output', 'none'))
            $row.Action = 'Updated'; $row.Added = @($missing)
            Write-Line "[updated] '$groupName': added $($missing -join ', ')."
        }
        else {
            $row.Action = 'WouldUpdate'; $row.Added = @($missing)
            Write-Line "[plan]    '$groupName': would add $($missing -join ', ')."
        }
    }
}
catch {
    $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
    Write-Warning "${groupName}: $($row.Detail)"
}

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
