<#
.SYNOPSIS
    Creates the Azure Arc gateway resource that networking.outbound.arc_gateway of infrastructure.yml names, with the Azure CLI.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 08 (Arc gateway), Azure CLI variant of New-ArcGateway.ps1. It does the same
    with az commands, for a host that has the Azure CLI and not the Az PowerShell modules. An Arc gateway reduces the number of endpoints the
    machines reach through the firewall (Microsoft Learn, About Azure Arc gateway for Azure Local). The script creates the
    Microsoft.HybridCompute/gateways resource, of the Public type, with "az arcgateway create" (Azure CLI extension arcgateway), with
    networking.outbound.arc_gateway.name in its resource group (default: azure.resource_group), in azure.subscription_id and azure.location.
    It takes about 10 to 30 minutes.

    The script does something only when scenario.outbound_path is arc_gateway or proxy_arc_gateway. For another path it says so and exits 0.
    It does not point the machines at the gateway: the OS configuration and the Arc registration read the same keys and do that.

    Idempotent. A gateway that exists is reported as AlreadyExists with its id and endpoint, and left alone. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with "az arcgateway create", behind -WhatIf. It does not sign in: run
    "az login --tenant <azure.tenant_id>" first. It needs the Azure CLI extension arcgateway ("az extension add --name arcgateway"). You need
    Contributor on the resource group. Every az call names its subscription, so the subscription of the az session is not changed. The tags in
    the file-level tags map are put on the gateway.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.location, azure.resource_group, tags
        scenario.outbound_path
        networking.outbound.arc_gateway.name, .resource_group

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 the gateway exists (created now, already there, or planned under -WhatIf), or the file does not use one; 1 an az call failed or
    a precondition failed (az missing, not signed in, wrong tenant, the extension missing, the creation failed); 2 a value in the file is missing
    or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-ArcGateway.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-ArcGateway.azcli.ps1 -InfrastructureFile ./infrastructure.yml

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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'ResourceNotFound|NotFound|could not be found|was not found|does not exist|\b404\b'
# The one type of Arc gateway Microsoft offers (az arcgateway create --gateway-type accepts Public only).
$GatewayType = 'Public'
# The Azure CLI extension that holds the arcgateway commands (Microsoft Learn: About Azure Arc gateway for Azure Local).
$ExtensionName = 'arcgateway'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# One az call. Returns the text of standard output (warnings on standard error are dropped); throws with the error text when az fails.
function Invoke-Az {
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $args
    if ($unsafe) { Exit-InputProblem $unsafe }
    $out = @(& az @args 2>&1)
    if ($LASTEXITCODE -ne 0) { throw (($out | ForEach-Object { "$_" }) -join ' ').Trim() }
    (@($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
}
# One az call with JSON output, parsed; $null when az printed nothing.
function Invoke-AzJson {
    $text = Invoke-Az @args '--output' 'json'
    if ($text) { $text | ConvertFrom-Json }
}
# The value at a dotted path of a parsed JSON object; $null when a part is missing.
function Get-JsonValue([object]$Object, [string]$Path) {
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current -or $current -is [string] -or -not $current.PSObject.Properties[$part]) { return $null }
        $current = $current.$part
    }
    $current
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$location = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$arcGateway = Get-AzlArcGateway -Infrastructure $infra
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
# The tags go into az arguments: refuse a key or a value that az.cmd cannot carry before any Azure call (also under -WhatIf).
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = $rawTags })
if ($problem) { Exit-InputProblem $problem }
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

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A name that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'networking.outbound.arc_gateway.resource_group (or azure.resource_group)' = $group; 'azure.location' = $location })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use New-ArcGateway.ps1.' }
try { $account = Invoke-Az account show --query tenantId --output tsv }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($account -ne $tenantId) { Exit-Failed "Signed in to tenant $account, but azure.tenant_id is $tenantId. Sign in to the right tenant." }
try { $null = Invoke-Az extension show --name $ExtensionName --query version --output tsv }
catch { Exit-Failed "The Azure CLI extension $ExtensionName is not installed. Run az extension add --name $ExtensionName." }

try {
    Write-Line "Arc gateway '$name' in '$group' ($location)"
    $row = [ordered]@{ ArcGateway = $name; Action = ''; GatewayId = ''; Endpoint = ''; Detail = '' }

    $existing = $null
    try { $existing = Invoke-AzJson arcgateway show --name $name --resource-group $group --subscription $subscriptionId }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The Arc gateway '$name' could not be read: $($_.Exception.Message)" } }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        $row.GatewayId = [string](Get-JsonValue $existing 'properties.gatewayId')
        $row.Endpoint = [string](Get-JsonValue $existing 'properties.gatewayEndpoint')
        Write-Line "[exists]  The Arc gateway '$name' is already there, nothing changed."
    }
    elseif ($PSCmdlet.ShouldProcess("Arc gateway '$name' in '$group'", "Create (type $GatewayType); this takes 10 to 30 minutes")) {
        Write-Line 'Creating the Arc gateway; this takes 10 to 30 minutes.'
        $createArgs = @('arcgateway', 'create', '--name', $name, '--resource-group', $group, '--location', $location, '--subscription', $subscriptionId, '--gateway-type', $GatewayType)
        if ($tags.Count) { $createArgs += '--tags'; $createArgs += @($tags.Keys | Sort-Object | ForEach-Object { "$_=$($tags[$_])" }) }
        $created = Invoke-AzJson @createArgs
        $row.Action = 'Created'
        $row.GatewayId = [string](Get-JsonValue $created 'properties.gatewayId')
        $row.Endpoint = [string](Get-JsonValue $created 'properties.gatewayEndpoint')
        Write-Line "[created] The Arc gateway '$name'."
    }
    else {
        $row.Action = 'WouldCreate'
        Write-Line "[plan]    The Arc gateway '$name' would be created (type $GatewayType)."
    }
    if ($row.Endpoint) { Write-Line "Gateway endpoint: $($row.Endpoint)" }
    [pscustomobject]$row
}
catch {
    Exit-Failed "The Arc gateway '$name' was not created: $($_.Exception.Message)"
}
exit 0
