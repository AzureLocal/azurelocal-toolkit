<#
.SYNOPSIS
    Turns on the free level of Microsoft Defender for Cloud that Azure Local needs, from infrastructure.yml.

.DESCRIPTION
    Phase 04 (security and governance), Task 01. Azure Local shows its security settings in the Azure portal only when two free items are in place
    on the subscription of the cluster (Microsoft Learn, Manage security with Defender for Cloud):
      1. Foundational CSPM, the free plan of Microsoft Defender for Cloud. It is on as soon as the Microsoft.Security resource provider is
         registered. The script registers the provider when it is not.
      2. The Microsoft cloud security benchmark initiative, assigned to the subscription. The script assigns it when no assignment of it applies
         to the subscription or above it. It never replaces an assignment it did not create: an assignment with the name Defender for Cloud
         gives it that points at another definition stops the run with exit code 2.
    When security.defender_for_cloud.security_contact_email holds an address and the subscription has no security contact yet, the script also
    sets that address as the security contact (free). It never replaces a contact that exists.

    Apart from that, the script does those three things and nothing else. It never turns on a paid plan (Defender for Servers, Storage,
    Key Vault, Resource Manager, DNS, SQL or Defender CSPM), never changes a pricing tier and never turns on agent auto-provisioning. Paid plans
    are the operator's own decision; see scripts/optional/paid-security-services.

    Idempotent. An item that is already in place is reported and left alone. -WhatIf reads Azure and changes nothing.

    The script does not sign in anywhere and asks nothing: run Connect-AzAccount to the tenant of azure.tenant_id first. It changes the
    subscription of the session while it works and puts it back.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id
        security.defender_for_cloud.enabled                           default true (the registry default)
        security.defender_for_cloud.apply_cloud_security_benchmark    default true (the registry default)
        security.defender_for_cloud.security_contact_email            empty or absent: no contact is set

    Exit codes: 0 every item is in place (done now, already there, planned under -WhatIf) or the file turns Defender for Cloud off;
    1 an Azure call failed or a precondition failed (not signed in, wrong tenant, an Az module missing); 2 a value in the file is missing or
    not usable, or an assignment would be overwritten. Nothing is sent to Azure on exit code 2.

    Source: https://learn.microsoft.com/azure/azure-local/manage/manage-security-with-defender-for-cloud

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Enable-DefenderForCloud.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be registered, assigned or set. Changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Enable-DefenderForCloud.ps1 -InfrastructureFile ./infrastructure.yml

    Puts the free level in place. Run it again: every item is reported as already there.
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

# Built-in initiative "Microsoft cloud security benchmark". Fixed by Microsoft: the ID is the same in every tenant (Microsoft Learn, Azure Policy built-in initiatives).
$BenchmarkDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
# Name Defender for Cloud itself gives the assignment, so the portal toggle shows it as on. Fixed by Defender for Cloud, not a choice.
$BenchmarkAssignmentName = 'SecurityCenterBuiltIn'
# The resource provider that carries Foundational CSPM. Fixed by Azure.
$SecurityProvider = 'Microsoft.Security'
# API version of the security contact resource (Microsoft.Security/securityContacts).
$SecurityContactApiVersion = '2023-12-01-preview'
# The alert severity Defender for Cloud itself uses for a new contact. Fixed by Defender for Cloud.
$ContactMinimalSeverity = 'High'
$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'

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
function Get-AssignmentDefinitionId([object]$Assignment) {
    # Az.Resources changed the shape of a policy assignment between versions; read either.
    $names = $Assignment.PSObject.Properties.Name
    if ($names -contains 'PolicyDefinitionId') { return [string]$Assignment.PolicyDefinitionId }
    if ($names -contains 'Properties' -and $Assignment.Properties) { return [string]$Assignment.Properties.PolicyDefinitionId }
    ''
}
function New-Row([string]$Item) { [ordered]@{ Item = $Item; Action = ''; Detail = '' } }

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
    $invalid = @($addresses | Where-Object { $_ -notmatch '^[^@\s;]+@[^@\s;]+\.[^@\s;]+$' })
    if (-not $addresses.Count -or $invalid.Count) { Exit-InputProblem "security.defender_for_cloud.security_contact_email must hold one email address or several separated by semicolons; found '$contactEmail'." }
}

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResourceProvider', 'Register-AzResourceProvider', 'Get-AzPolicyAssignment', 'Get-AzPolicySetDefinition', 'New-AzPolicyAssignment', 'Invoke-AzRestMethod') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Resources modules: Install-Module Az.Accounts, Az.Resources -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context
$scope = "/subscriptions/$subscriptionId"

$rows = [System.Collections.Generic.List[object]]::new()
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    Write-Line "Subscription: $subscriptionId"

    # 1. Foundational CSPM (free): on once Microsoft.Security is registered.
    $row = New-Row 'Foundational CSPM'
    try {
        $provider = Get-AzResourceProvider -ProviderNamespace $SecurityProvider -ErrorAction Stop
        $states = @($provider | ForEach-Object { $_.RegistrationState } | Select-Object -Unique)
        if ($states.Count -eq 1 -and $states[0] -eq 'Registered') {
            $row.Action = 'Exists'
            Write-Line "[exists]  $SecurityProvider is registered. Foundational CSPM (free) is on."
        }
        elseif ($PSCmdlet.ShouldProcess($scope, "Register resource provider $SecurityProvider")) {
            $null = Register-AzResourceProvider -ProviderNamespace $SecurityProvider -ErrorAction Stop
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
    $row = New-Row 'Cloud security benchmark'
    if (-not $applyBenchmark) {
        $row.Action = 'Skipped'
        $row.Detail = 'security.defender_for_cloud.apply_cloud_security_benchmark is false. The initiative is not assigned; the Azure Local security settings will not show in the portal.'
        Write-Line "[skip]    $($row.Detail)"
    }
    else {
        try {
            $assignments = @(Get-AzPolicyAssignment -Scope $scope -ErrorAction Stop)
            if (@($assignments | Where-Object { (Get-AssignmentDefinitionId $_) -eq $BenchmarkDefinitionId }).Count -gt 0) {
                $row.Action = 'Exists'
                Write-Line '[exists]  The Microsoft cloud security benchmark is already assigned on this subscription or above it.'
            }
            elseif (@($assignments | Where-Object { $_.Name -eq $BenchmarkAssignmentName }).Count -gt 0) {
                # New-AzPolicyAssignment would overwrite it. Never replace an assignment this script did not create.
                Exit-InputProblem "A policy assignment named '$BenchmarkAssignmentName' applies to $scope but points at another definition. Remove or rename it, or set security.defender_for_cloud.apply_cloud_security_benchmark to false."
            }
            elseif ($PSCmdlet.ShouldProcess($scope, 'Assign the Microsoft cloud security benchmark initiative')) {
                $definition = Get-AzPolicySetDefinition -Id $BenchmarkDefinitionId -ErrorAction Stop
                $null = New-AzPolicyAssignment -Name $BenchmarkAssignmentName -DisplayName 'Microsoft cloud security benchmark' -Scope $scope -PolicySetDefinition $definition -ErrorAction Stop
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
    $row = New-Row 'Security contact'
    if (-not $addresses.Count) {
        $row.Action = 'Skipped'
        $row.Detail = 'security.defender_for_cloud.security_contact_email is empty: no contact is set.'
        Write-Line "[skip]    $($row.Detail)"
    }
    else {
        try {
            $contactPath = "$scope/providers/Microsoft.Security/securityContacts/default?api-version=$SecurityContactApiVersion"
            $current = Invoke-AzRestMethod -Method GET -Path $contactPath
            if ($current.StatusCode -notin 200, 404) { throw "The security contact of the subscription could not be read (HTTP $($current.StatusCode))." }
            if ($current.StatusCode -eq 200) {
                # Any contact that exists is left alone, whatever it holds.
                $row.Action = 'Exists'
                Write-Line '[exists]  The subscription already has a security contact. It is left as it is.'
            }
            elseif ($PSCmdlet.ShouldProcess($scope, 'Set the Defender for Cloud security contact')) {
                $payload = @{ properties = @{ emails = ($addresses -join ';'); isEnabled = $true; notificationsSources = @(@{ sourceType = 'Alert'; minimalSeverity = $ContactMinimalSeverity }) } } | ConvertTo-Json -Depth 5
                $result = Invoke-AzRestMethod -Method PUT -Path $contactPath -Payload $payload
                if ($result.StatusCode -notin 200, 201) { throw "The security contact could not be set (HTTP $($result.StatusCode)): $($result.Content)" }
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
}
catch {
    Exit-Failed "Defender for Cloud: $($_.Exception.Message)"
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$rows
Write-Line 'No paid Defender plan was turned on or changed by this script.'
$failed = @($rows | Where-Object Action -EQ 'Failed').Count
if ($failed -gt 0) { exit 1 }
exit 0
