<#
.SYNOPSIS
    Creates the Azure Monitor action group that tells the operations team about alerts, from infrastructure.yml.

.DESCRIPTION
    Phase 02 (monitoring and observability), Task 04 (set up alerting). Creates the action group operations.monitoring.action_group in the
    resource group of the monitoring resources (operations.monitoring.workspace_resource_group), with one email receiver for each address of
    operations.notifications.emails and operations.monitoring.alert_email (duplicates are joined). The alert rules point at this group.

    It creates only the action group. It does not create alert rules, and it does not create the data collection endpoint
    (Deploy-DataCollectionEndpoint.ps1, the first half of the original monitoring deployment, does that). When operations.monitoring.enabled is
    false the design has no Azure Monitor and the script does nothing and exits 0.

    Idempotent, and additive. A group that exists is not recreated and no receiver is removed: an address the file lists and the group lacks is
    added to the group (the receivers it already has, of any kind, are kept); a second run with the same file changes nothing. -WhatIf changes
    nothing.

    The short name of an action group (at most 12 characters, shown in SMS and email subjects) is made from the group name: its letters and
    digits, cut to 12.

    The script reads Azure (read only) and writes only with New-AzActionGroup and Update-AzActionGroup, behind -WhatIf. It does not sign in: run
    Connect-AzAccount to the tenant in azure.tenant_id first. You need Monitoring Contributor (or Contributor) on the resource group. The tags
    in the file-level tags map are put on a group it creates. The group is global and is created in azure.subscription_id.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, tags
        operations.monitoring.enabled                    false means: do nothing
        operations.monitoring.workspace_resource_group   the resource group of the action group
        operations.monitoring.action_group               the name of the action group
        operations.monitoring.alert_email                an address that receives alerts
        operations.notifications.emails                  the addresses that receive notifications

    Exit codes: 0 the action group exists with every listed address (created now, already there, receivers added, or planned under -WhatIf) or
    monitoring is switched off in the file; 1 an Azure call failed or a precondition failed (not signed in, wrong tenant, Az modules missing,
    the creation or the update failed); 2 a value in the file is missing or not usable, or no email address is listed.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-ActionGroup.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the group would be created or which receivers would be added, and changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-ActionGroup.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the group with its email receivers. Run it again: it is reported as AlreadyExists.
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

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'
$Email = '^[^@\s,;<>()\[\]\\"]+@[^@\s,;<>()\[\]\\"]+\.[^@\s,;<>()\[\]\\"]+$'

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

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$subscriptionId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')
$monitoring = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring'
$rawEmails = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.notifications.emails'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

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

$addresses = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in @(@($rawEmails) + @(Get-Field 'alert_email'))) {
    if ($null -eq $candidate -or [string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    $address = ([string]$candidate).Trim()
    if ($address -notmatch $Email) { Exit-InputProblem "The address '$address' (operations.notifications.emails or operations.monitoring.alert_email) is not an email address." }
    if (-not @($addresses | Where-Object { $_ -ieq $address })) { $addresses.Add($address) }
}
if ($addresses.Count -eq 0) { Exit-InputProblem 'No email address: list at least one in operations.notifications.emails or operations.monitoring.alert_email, or the action group would tell nobody.' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Get-AzActionGroup', 'New-AzActionGroup', 'Update-AzActionGroup', 'New-AzActionGroupEmailReceiverObject') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Monitor modules: Install-Module Az.Accounts, Az.Monitor -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }

function Get-EmailReceiverObject([string]$Address) {
    New-AzActionGroupEmailReceiverObject -Name ('email-' + ($Address -replace '[^A-Za-z0-9]', '-')) -EmailAddress $Address
}

Write-Line "Action group '$groupName' in '$resourceGroup', $($addresses.Count) email address(es)"

$row = [ordered]@{ ActionGroup = $groupName; Action = ''; Receivers = @($addresses); Added = @(); Detail = '' }
try {
    $existing = $null
    try { $existing = Get-AzActionGroup -Name $groupName -ResourceGroupName $resourceGroup -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

    if (-not $existing) {
        if ($PSCmdlet.ShouldProcess("action group '$groupName' in '$resourceGroup'", "Create with $($addresses.Count) email receiver(s)")) {
            $arguments = @{
                Name = $groupName; ResourceGroupName = $resourceGroup; SubscriptionId = $subscriptionId; Location = 'Global'; GroupShortName = $shortName
                EmailReceiver = @($addresses | ForEach-Object { Get-EmailReceiverObject $_ }); Enabled = $true; ErrorAction = 'Stop'
            }
            if ($tags.Count) { $arguments.Tag = $tags }
            $null = New-AzActionGroup @arguments
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
        if ($existing.PSObject.Properties['EmailReceiver'] -and $existing.EmailReceiver) { $haveReceivers = @($existing.EmailReceiver) }
        $haveAddresses = @($haveReceivers | ForEach-Object { [string]$_.EmailAddress })
        $missing = @($addresses | Where-Object { $a = $_; -not @($haveAddresses | Where-Object { $_ -ieq $a }) })
        if ($missing.Count -eq 0) {
            $row.Action = 'AlreadyExists'
            Write-Line "[exists]  '$groupName' is already there with every listed address, nothing changed."
        }
        elseif ($PSCmdlet.ShouldProcess("action group '$groupName'", "Add the email receiver(s) $($missing -join ', ') (the receivers it has are kept)")) {
            $all = @($haveReceivers) + @($missing | ForEach-Object { Get-EmailReceiverObject $_ })
            $null = Update-AzActionGroup -Name $groupName -ResourceGroupName $resourceGroup -SubscriptionId $subscriptionId -EmailReceiver $all -ErrorAction Stop
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
