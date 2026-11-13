<#
.SYNOPSIS
    Creates the Azure Arc gateway resource that networking.outbound.arc_gateway of infrastructure.yml names.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 08 (Arc gateway). An Arc gateway reduces the number of endpoints the machines
    reach through the firewall (Microsoft Learn, Simplify network configuration requirements with Azure Arc gateway). The script creates the
    Microsoft.HybridCompute/gateways resource, of the Public type, with networking.outbound.arc_gateway.name in its resource group (default:
    azure.resource_group), in azure.subscription_id and azure.location. It takes about 10 to 30 minutes.

    The script does something only when scenario.outbound_path is arc_gateway or proxy_arc_gateway. For another path it says so and exits 0.
    It does not point the machines at the gateway: the OS configuration and the Arc registration read the same keys and do that.

    Idempotent. A gateway that exists is reported as AlreadyExists with its id and endpoint, and left alone. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzArcGateway, behind -WhatIf. It does not sign in: run Connect-AzAccount to the
    tenant in azure.tenant_id first. You need Contributor on the resource group. The script changes the subscription of the session while it
    works and puts it back. The tags in the file-level tags map are put on the gateway.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.location, azure.resource_group, tags
        scenario.outbound_path
        networking.outbound.arc_gateway.name, .resource_group

    Exit codes: 0 the gateway exists (created now, already there, or planned under -WhatIf), or the file does not use one; 1 an Azure call failed or
    a precondition failed (not signed in, wrong tenant, Az modules missing, the creation failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-ArcGateway.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./New-ArcGateway.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the gateway. Run it again: it is reported as AlreadyExists.
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

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$location = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$arcGateway = Get-AzlArcGateway -Infrastructure $infra
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if (-not $arcGateway.Enabled) {
    Write-Line 'scenario.outbound_path does not use an Arc gateway (arc_gateway or proxy_arc_gateway): nothing to do.'
    exit 0
}
$name = $arcGateway.Name
$group = $arcGateway.ResourceGroup
$subscriptionId = $arcGateway.SubscriptionId
if (-not $name) { Exit-InputProblem 'networking.outbound.arc_gateway.name is missing. It is the name of the Arc gateway resource.' }
if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { Exit-InputProblem "networking.outbound.arc_gateway.name '$name' is not a valid name (letters, digits, . _ -)." }
if (-not $group) { Exit-InputProblem 'No resource group: networking.outbound.arc_gateway.resource_group and azure.resource_group are both empty.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $location) { Exit-InputProblem 'azure.location is missing.' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzArcGateway', 'New-AzArcGateway') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.ArcGateway modules: Install-Module Az.Accounts, Az.ArcGateway -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    Write-Line "Arc gateway '$name' in '$group' ($location)"
    $row = [ordered]@{ ArcGateway = $name; Action = ''; GatewayId = ''; Endpoint = ''; Detail = '' }

    $existing = $null
    try { $existing = Get-AzArcGateway -Name $name -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The Arc gateway '$name' could not be read: $($_.Exception.Message)" } }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        $row.GatewayId = if ($existing.PSObject.Properties['GatewayId']) { [string]$existing.GatewayId } else { '' }
        $row.Endpoint = if ($existing.PSObject.Properties['Endpoint']) { [string]$existing.Endpoint } else { '' }
        Write-Line "[exists]  The Arc gateway '$name' is already there, nothing changed."
    }
    elseif ($PSCmdlet.ShouldProcess("Arc gateway '$name' in '$group'", 'Create (type Public); this takes 10 to 30 minutes')) {
        Write-Line 'Creating the Arc gateway; this takes 10 to 30 minutes.'
        $arguments = @{ Name = $name; ResourceGroupName = $group; Location = $location; SubscriptionId = $subscriptionId; GatewayType = 'Public'; ErrorAction = 'Stop' }
        if ($tags.Count) { $arguments.Tag = $tags }
        $created = New-AzArcGateway @arguments
        $row.Action = 'Created'
        $row.GatewayId = if ($created -and $created.PSObject.Properties['GatewayId']) { [string]$created.GatewayId } else { '' }
        $row.Endpoint = if ($created -and $created.PSObject.Properties['Endpoint']) { [string]$created.Endpoint } else { '' }
        Write-Line "[created] The Arc gateway '$name'."
    }
    else {
        $row.Action = 'WouldCreate'
        Write-Line "[plan]    The Arc gateway '$name' would be created (type Public)."
    }
    if ($row.Endpoint) { Write-Line "Gateway endpoint: $($row.Endpoint)" }
    [pscustomobject]$row
}
catch {
    Exit-Failed "The Arc gateway '$name' was not created: $($_.Exception.Message)"
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}
exit 0
