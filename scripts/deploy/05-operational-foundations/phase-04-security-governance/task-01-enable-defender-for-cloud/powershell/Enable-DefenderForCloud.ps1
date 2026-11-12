<#
.SYNOPSIS
    Turns on the free level of Microsoft Defender for Cloud that Azure Local needs.

.DESCRIPTION
    Azure Local shows its security settings in the Azure portal only when two free items are in place
    on the subscription of the cluster:
    - Foundational CSPM, the free plan of Microsoft Defender for Cloud. It is on as soon as the
      Microsoft.Security resource provider is registered.
    - The Microsoft cloud security benchmark initiative, assigned to the subscription.

    When security.defender_for_cloud.security_contact_email holds an address and the subscription has no
    security contact yet, the script also sets that address as the security contact (free). It never
    replaces a contact that exists.

    Apart from that, this script does those two things and nothing else. It never turns on a paid plan (Defender for
    Servers, Storage, Key Vault, Resource Manager, DNS, SQL or Defender CSPM), never changes a pricing
    tier and never turns on agent auto-provisioning. Paid plans are the operator's own decision; see
    scripts/optional/paid-security-services.

    Source: https://learn.microsoft.com/azure/azure-local/manage/manage-security-with-defender-for-cloud

.PARAMETER SubscriptionId
    Azure subscription ID of the cluster. Default: azure.subscription_id of the variables file.

.PARAMETER ConfigPath
    Path to infrastructure.yml. The script reads azure.subscription_id,
    security.defender_for_cloud.enabled, security.defender_for_cloud.apply_cloud_security_benchmark and
    security.defender_for_cloud.security_contact_email.

.EXAMPLE
    .\Enable-DefenderForCloud.ps1 -ConfigPath .\configs\infrastructure.yml

.EXAMPLE
    .\Enable-DefenderForCloud.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -WhatIf

.NOTES
    Author: AzureLocal Cloud Team
    Version: 2.1.0
    Stage: 05-operational-foundations
    Phase: phase-04-security-governance
    Task: task-01-enable-defender-for-cloud
#>

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Built-in initiative "Microsoft cloud security benchmark". The ID is the same in every tenant.
$script:BenchmarkDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
# Name Defender for Cloud itself gives the assignment, so the portal toggle shows it as on.
$script:BenchmarkAssignmentName = 'SecurityCenterBuiltIn'
# API version of the security contact resource (Microsoft.Security/securityContacts).
$script:SecurityContactApiVersion = '2023-12-01-preview'

#region Functions

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    [CmdletBinding()]
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        throw "The powershell-yaml module is needed to read '$Path'. Install it, or pass -SubscriptionId."
    }
    Import-Module powershell-yaml
    return ConvertFrom-Yaml (Get-Content -LiteralPath $Path -Raw)
}

function Get-ConfigSetting {
    # Reads one key of a nested hashtable; returns $Default when any part of the path is absent.
    param($Config, [string[]]$Path, $Default)
    $node = $Config
    foreach ($part in $Path) {
        if ($node -isnot [System.Collections.IDictionary] -or -not $node.Contains($part)) { return $Default }
        $node = $node[$part]
    }
    if ($null -eq $node) { return $Default }
    return $node
}

function ConvertTo-Switch {
    # A YAML boolean arrives as [bool]; a quoted "false" arrives as a string, which [bool] would read as true.
    param($Value, [string]$Key)
    if ($Value -is [bool]) { return $Value }
    switch -Regex ([string]$Value) {
        '^\s*(true|yes|1)\s*$' { return $true }
        '^\s*(false|no|0)\s*$' { return $false }
    }
    throw "$Key must be true or false; found '$Value'."
}

function Get-AssignmentDefinitionId {
    # Az.Resources changed the shape of a policy assignment between versions; read either.
    param($Assignment)
    $names = $Assignment.PSObject.Properties.Name
    if ($names -contains 'PolicyDefinitionId') { return [string]$Assignment.PolicyDefinitionId }
    if ($names -contains 'Properties' -and $Assignment.Properties) { return [string]$Assignment.Properties.PolicyDefinitionId }
    return ''
}

#endregion Functions

#region Main

Write-LogMessage "=== Microsoft Defender for Cloud: free level for Azure Local ===" -Level Info

$config = Import-InfrastructureConfig -Path $ConfigPath
if (-not $SubscriptionId) {
    $SubscriptionId = [string](Get-ConfigSetting -Config $config -Path 'azure', 'subscription_id' -Default '')
}
$enabled = ConvertTo-Switch -Key 'security.defender_for_cloud.enabled' -Value (Get-ConfigSetting -Config $config -Path 'security', 'defender_for_cloud', 'enabled' -Default $true)
$contactEmail = ([string](Get-ConfigSetting -Config $config -Path 'security', 'defender_for_cloud', 'security_contact_email' -Default '')).Trim()
$applyBenchmark = ConvertTo-Switch -Key 'security.defender_for_cloud.apply_cloud_security_benchmark' -Value (Get-ConfigSetting -Config $config -Path 'security', 'defender_for_cloud', 'apply_cloud_security_benchmark' -Default $true)

if (-not $enabled) {
    Write-LogMessage "security.defender_for_cloud.enabled is false. Nothing to do." -Level Warning
    return
}
if (-not $SubscriptionId) {
    throw "SubscriptionId is required: pass -SubscriptionId or set azure.subscription_id in '$ConfigPath'."
}

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-LogMessage "Subscription: $SubscriptionId" -Level Info

# 1. Foundational CSPM (free): on once Microsoft.Security is registered.
$provider = Get-AzResourceProvider -ProviderNamespace 'Microsoft.Security'
$states = @($provider | ForEach-Object { $_.RegistrationState } | Select-Object -Unique)
if ($states.Count -eq 1 -and $states[0] -eq 'Registered') {
    Write-LogMessage "Microsoft.Security is registered. Foundational CSPM (free) is on." -Level Info
}
elseif ($PSCmdlet.ShouldProcess($SubscriptionId, "Register resource provider Microsoft.Security")) {
    Register-AzResourceProvider -ProviderNamespace 'Microsoft.Security' | Out-Null
    Write-LogMessage "Microsoft.Security registration requested. Foundational CSPM (free) is on when it completes." -Level Success
}

# 2. Microsoft cloud security benchmark, assigned to the subscription.
if ($applyBenchmark) {
    $scope = "/subscriptions/$SubscriptionId"
    $existing = @(Get-AzPolicyAssignment -Scope $scope | Where-Object {
            (Get-AssignmentDefinitionId -Assignment $_) -eq $script:BenchmarkDefinitionId
        })
    if ($existing.Count -gt 0) {
        Write-LogMessage "Microsoft cloud security benchmark is already assigned on this subscription or above it." -Level Info
    }
    elseif (@(Get-AzPolicyAssignment -Scope $scope | Where-Object { $_.Name -eq $script:BenchmarkAssignmentName }).Count -gt 0) {
        # New-AzPolicyAssignment would overwrite it. Never replace an assignment this script did not create.
        throw "A policy assignment named '$($script:BenchmarkAssignmentName)' applies to $scope but points at another definition. Remove or rename it, or set security.defender_for_cloud.apply_cloud_security_benchmark to false."
    }
    elseif ($PSCmdlet.ShouldProcess($scope, "Assign the Microsoft cloud security benchmark initiative")) {
        $definition = Get-AzPolicySetDefinition -Id $script:BenchmarkDefinitionId
        New-AzPolicyAssignment -Name $script:BenchmarkAssignmentName `
            -DisplayName 'Microsoft cloud security benchmark' `
            -Scope $scope `
            -PolicySetDefinition $definition | Out-Null
        Write-LogMessage "Microsoft cloud security benchmark assigned. Allow at least one hour for the first evaluation." -Level Success
    }
}
else {
    Write-LogMessage "security.defender_for_cloud.apply_cloud_security_benchmark is false. The initiative is not assigned; the Azure Local security settings will not show in the portal." -Level Warning
}

# 3. Security contact (free): set only when the file names one and the subscription has none.
if ($contactEmail) {
    $addresses = @($contactEmail -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $invalid = @($addresses | Where-Object { $_ -notmatch '^[^@\s;]+@[^@\s;]+\.[^@\s;]+$' })
    if (-not $addresses.Count -or $invalid.Count) { throw "security.defender_for_cloud.security_contact_email must hold one email address or several separated by semicolons; found '$contactEmail'." }
    $contactEmail = $addresses -join ';'
    $contactPath = "/subscriptions/$SubscriptionId/providers/Microsoft.Security/securityContacts/default?api-version=$($script:SecurityContactApiVersion)"
    $current = Invoke-AzRestMethod -Method GET -Path $contactPath
    if ($current.StatusCode -notin 200, 404) {
        throw "The security contact of the subscription could not be read (HTTP $($current.StatusCode))."
    }
    if ($current.StatusCode -eq 200) {
        # Any contact that exists is left alone, whatever it holds.
        Write-LogMessage "The subscription already has a security contact. It is left as it is." -Level Info
    }
    elseif ($PSCmdlet.ShouldProcess("/subscriptions/$SubscriptionId", "Set the Defender for Cloud security contact")) {
        # Alerts of high severity is the level Defender for Cloud itself uses for a new contact.
        $payload = @{ properties = @{ emails = $contactEmail; isEnabled = $true; notificationsSources = @(@{ sourceType = 'Alert'; minimalSeverity = 'High' }) } } | ConvertTo-Json -Depth 5
        $result = Invoke-AzRestMethod -Method PUT -Path $contactPath -Payload $payload
        if ($result.StatusCode -notin 200, 201) { throw "The security contact could not be set (HTTP $($result.StatusCode)): $($result.Content)" }
        Write-LogMessage "Security contact set." -Level Success
    }
}

Write-LogMessage "No paid Defender plan was turned on or changed by this script." -Level Info
Write-LogMessage "=== Done ===" -Level Success

#endregion Main
