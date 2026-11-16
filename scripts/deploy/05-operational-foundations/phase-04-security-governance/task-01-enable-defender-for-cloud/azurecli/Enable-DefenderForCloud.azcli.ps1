<#
.SYNOPSIS
    Turns on the free level of Microsoft Defender for Cloud that Azure Local needs, with the Azure CLI, from infrastructure.yml.

.DESCRIPTION
    Phase 04 (security and governance), Task 01, Azure CLI variant of Enable-DefenderForCloud.ps1. Azure Local shows its security settings in the Azure
    portal only when two free items are in place on the subscription of the cluster (Microsoft Learn, Manage security with Defender for Cloud):
      1. Foundational CSPM, the free plan of Microsoft Defender for Cloud. It is on as soon as the Microsoft.Security resource provider is registered.
         The script registers the provider (az provider register) when it is not.
      2. The Microsoft cloud security benchmark initiative, assigned to the subscription (az policy assignment create). The script assigns it when no
         assignment of it applies to the subscription or above it. It never replaces an assignment it did not create: an assignment with the name
         Defender for Cloud gives it that points at another definition stops the run with exit code 2.
    When security.defender_for_cloud.security_contact_email holds an address and the subscription has no security contact yet, the script also sets that
    address as the security contact (az security contact create, free). It never replaces a contact that exists. The Azure CLI command is a preview
    command of Microsoft.

    Apart from that, the script does those three things and nothing else. FREE TIER ONLY: it never turns on a paid plan (Defender for Servers, Storage,
    Key Vault, Resource Manager, DNS, SQL or Defender CSPM), never changes a pricing tier (no az security pricing call) and never turns on agent
    auto-provisioning. Paid plans are the operator's own decision.

    Idempotent. An item that is already in place is reported and left alone. -WhatIf reads Azure and changes nothing.

    The script does not sign in and asks nothing: run az login to the tenant of azure.tenant_id first. It does not change the Azure CLI default
    subscription: every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id
        security.defender_for_cloud.enabled                           default true (the registry default)
        security.defender_for_cloud.apply_cloud_security_benchmark    default true (the registry default)
        security.defender_for_cloud.security_contact_email            empty or absent: no contact is set

    Exit codes: 0 every item is in place (done now, already there, planned under -WhatIf) or the file turns Defender for Cloud off; 1 an Azure call
    failed or a precondition failed (az missing, not signed in, wrong tenant); 2 a value in the file is missing or not usable, or an assignment would be
    overwritten. Nothing is sent to Azure on exit code 2.

    Source: https://learn.microsoft.com/azure/azure-local/manage/manage-security-with-defender-for-cloud

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Enable-DefenderForCloud.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be registered, assigned or set. Changes nothing.
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

# Built-in initiative "Microsoft cloud security benchmark". Fixed by Microsoft: the ID is the same in every tenant (Microsoft Learn, Azure Policy built-in initiatives).
$BenchmarkDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
# Name Defender for Cloud itself gives the assignment, so the portal toggle shows it as on. Fixed by Defender for Cloud, not a choice.
$BenchmarkAssignmentName = 'SecurityCenterBuiltIn'
$BenchmarkDisplayName = 'Microsoft cloud security benchmark'
# The resource provider that carries Foundational CSPM. Fixed by Azure.
$SecurityProvider = 'Microsoft.Security'
# The one security contact of a subscription is called default. Fixed by Azure (Microsoft.Security/securityContacts).
$SecurityContactName = 'default'
# What Defender for Cloud itself uses for a new contact: alert emails on, from severity High. Fixed by Defender for Cloud.
$ContactAlertState = 'On'
$ContactMinimalSeverity = 'High'
$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# The Azure CLI is started through a command file on Windows. These characters would be read as commands there, so no value that holds one is sent.
$UnsafeArgument = '[&|<>^%"`\r\n]'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Switch([string]$Path, [bool]$Default) {
    # A YAML boolean arrives as [bool]; a quoted "false" arrives as a string, which [bool] would read as true.
    $value = Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path
    if ($null -eq $value) { return $Default }
    if ($value -is [bool]) { return $value }
    switch -Regex ([string]$value) {
        '^\s*(true|yes|1)\s*$' { return $true }
        '^\s*(false|no|0)\s*$' { return $false }
    }
    Exit-InputProblem "$Path must be true or false; found '$value'."
}
function Get-RowTemplate([string]$Item) { [ordered]@{ Item = $Item; Action = ''; Detail = '' } }
# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the text of standard output; throws when az ends with an error.
function Invoke-Az {
    $arguments = @($args | ForEach-Object { $_ } | ForEach-Object { [string]$_ })
    foreach ($argument in $arguments) {
        if ($argument -match $UnsafeArgument) { throw "An argument holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote): $argument" }
    }
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

$enabled = Get-Switch 'security.defender_for_cloud.enabled' $true
$applyBenchmark = Get-Switch 'security.defender_for_cloud.apply_cloud_security_benchmark' $true
$contactEmail = Get-Text 'security.defender_for_cloud.security_contact_email'
if (-not $enabled) {
    Write-Line 'security.defender_for_cloud.enabled is false: nothing to do. Defender for Cloud is left alone.'
    exit 0
}
$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
$addresses = @()
if ($contactEmail) {
    $addresses = @($contactEmail -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $invalid = @($addresses | Where-Object { $_ -notmatch '^[^@\s;]+@[^@\s;]+\.[^@\s;]+$' -or $_ -match $UnsafeArgument })
    if (-not $addresses.Count -or $invalid.Count) { Exit-InputProblem "security.defender_for_cloud.security_contact_email must hold one email address or several separated by semicolons; found '$contactEmail'." }
}
$scope = "/subscriptions/$subscriptionId"

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Enable-DefenderForCloud.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

$rows = [System.Collections.Generic.List[object]]::new()
Write-Line "Subscription: $subscriptionId"

# 1. Foundational CSPM (free): on once Microsoft.Security is registered.
$row = Get-RowTemplate 'Foundational CSPM'
try {
    $state = Invoke-Az provider show --subscription $subscriptionId --namespace $SecurityProvider --query registrationState --output tsv
    if ($state -eq 'Registered') {
        $row.Action = 'Exists'
        Write-Line "[exists]  $SecurityProvider is registered. Foundational CSPM (free) is on."
    }
    elseif ($PSCmdlet.ShouldProcess($scope, "Register resource provider $SecurityProvider")) {
        $null = Invoke-Az provider register --subscription $subscriptionId --namespace $SecurityProvider
        $row.Action = 'Registered'
        Write-Line "[done]    $SecurityProvider registration requested. Foundational CSPM (free) is on when it completes."
    }
    else {
        $row.Action = 'WouldRegister'
        Write-Line "[plan]    $SecurityProvider would be registered."
    }
}
catch { $row.Action = 'Failed'; $row.Detail = $_.Exception.Message; Write-Warning "Foundational CSPM: $($row.Detail)" }
$rows.Add([pscustomobject]$row)

# 2. Microsoft cloud security benchmark, assigned to the subscription.
$row = Get-RowTemplate 'Cloud security benchmark'
if (-not $applyBenchmark) {
    $row.Action = 'Skipped'
    $row.Detail = 'security.defender_for_cloud.apply_cloud_security_benchmark is false. The initiative is not assigned; the Azure Local security settings will not show in the portal.'
    Write-Line "[skip]    $($row.Detail)"
}
else {
    try {
        # The assignments that apply to the subscription: its own and those of the management groups above it, not those of its resource groups.
        $assignments = @(@(Invoke-Az policy assignment list --subscription $subscriptionId --scope $scope --disable-scope-strict-match --output json | ConvertFrom-Json) |
                Where-Object { $null -ne $_ -and -not ([string]$_.scope).StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase) })
        if (@($assignments | Where-Object { [string]$_.policyDefinitionId -eq $BenchmarkDefinitionId }).Count -gt 0) {
            $row.Action = 'Exists'
            Write-Line '[exists]  The Microsoft cloud security benchmark is already assigned on this subscription or above it.'
        }
        elseif (@($assignments | Where-Object { [string]$_.name -eq $BenchmarkAssignmentName }).Count -gt 0) {
            # az policy assignment create would overwrite it. Never replace an assignment this script did not create.
            Exit-InputProblem "A policy assignment named '$BenchmarkAssignmentName' applies to $scope but points at another definition. Remove or rename it, or set security.defender_for_cloud.apply_cloud_security_benchmark to false."
        }
        elseif ($PSCmdlet.ShouldProcess($scope, 'Assign the Microsoft cloud security benchmark initiative')) {
            $null = Invoke-Az policy set-definition show --subscription $subscriptionId --name $BenchmarkDefinitionId.Split('/')[-1] --output none
            $null = Invoke-Az policy assignment create --subscription $subscriptionId --name $BenchmarkAssignmentName --display-name $BenchmarkDisplayName --scope $scope --policy-set-definition $BenchmarkDefinitionId --output none
            $row.Action = 'Assigned'
            Write-Line '[done]    The Microsoft cloud security benchmark is assigned. Allow at least one hour for the first evaluation.'
        }
        else {
            $row.Action = 'WouldAssign'
            Write-Line '[plan]    The Microsoft cloud security benchmark would be assigned.'
        }
    }
    catch { $row.Action = 'Failed'; $row.Detail = $_.Exception.Message; Write-Warning "Cloud security benchmark: $($row.Detail)" }
}
$rows.Add([pscustomobject]$row)

# 3. Security contact (free): set only when the file names one and the subscription has none.
$row = Get-RowTemplate 'Security contact'
if (-not $addresses.Count) {
    $row.Action = 'Skipped'
    $row.Detail = 'security.defender_for_cloud.security_contact_email is empty: no contact is set.'
    Write-Line "[skip]    $($row.Detail)"
}
else {
    try {
        $current = $null
        try { $current = Invoke-Az security contact show --subscription $subscriptionId --name $SecurityContactName --output json }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
        if ($current) {
            # Any contact that exists is left alone, whatever it holds.
            $row.Action = 'Exists'
            Write-Line '[exists]  The subscription already has a security contact. It is left as it is.'
        }
        elseif ($PSCmdlet.ShouldProcess($scope, 'Set the Defender for Cloud security contact')) {
            $null = Invoke-Az security contact create --subscription $subscriptionId --name $SecurityContactName --emails ($addresses -join ';') --alert-notifications "state=$ContactAlertState" "minimal-severity=$ContactMinimalSeverity" --output none
            $row.Action = 'Set'
            Write-Line '[done]    The security contact is set.'
        }
        else {
            $row.Action = 'WouldSet'
            Write-Line '[plan]    The security contact would be set.'
        }
    }
    catch { $row.Action = 'Failed'; $row.Detail = $_.Exception.Message; Write-Warning "Security contact: $($row.Detail)" }
}
$rows.Add([pscustomobject]$row)

$rows
Write-Line 'No paid Defender plan was turned on or changed by this script.'
$failed = @($rows | Where-Object Action -EQ 'Failed').Count
if ($failed -gt 0) { exit 1 }
exit 0
