#Requires -Version 7.0
<#
.SYNOPSIS
    Small Azure helpers the node configuration and the ARM deployment share: ARM REST calls, Key Vault references, the
    azurelocal-ztp handoff file and Arc machine lookups.

.DESCRIPTION
    Every call that touches Azure goes through one of these functions, so a test replaces them and no test needs a
    subscription.

    Invoke-AzlArm            One ARM REST call through Invoke-AzRestMethod. Returns the parsed body ($null for a 404 when
                             -AllowNotFound). Throws on any other failure, with the error message ARM gave.
    Get-AzlProp              Reads a dotted path from a parsed object or hashtable. $null when any part is missing, so it is
                             safe under strict mode.
    ConvertFrom-AzlKeyVaultRef  keyvault://<vault>/<secret> into its parts.
    Get-AzlSecret            The value of a keyvault:// reference (Az.KeyVault).
    Read-AzlHandoff          azurelocal-ztp's handoff file (schema 2): Arc machine resource IDs, the installed build and
                             managementAddressVerified for each node.
    Find-AzlArcMachine       A node's Arc machine: from the handoff, else looked up by name in the instance's resource group.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Microsoft.HybridCompute machines GET. The run command resource has its own version, in AzlNodeTransport.
$script:ArcMachineApiVersion = '2024-07-10'

function Get-AzlProp {
    <#
    .SYNOPSIS
        Reads a dotted path ('properties.reportedProperties.validationStatus') from a parsed object or a hashtable.
    .EXAMPLE
        Get-AzlProp $response 'properties.provisioningState'
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Path, [object]$Default = $null)
    $current = $InputObject
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($part)) { return $Default }
            $current = $current[$part]
        }
        else {
            $property = $current.PSObject.Properties[$part]
            if (-not $property) { return $Default }
            $current = $property.Value
        }
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Invoke-AzlArm {
    <#
    .SYNOPSIS
        One Azure Resource Manager REST call.
    .DESCRIPTION
        -Path is the resource ID (with or without a leading slash). The api-version is added. A 404 returns $null when
        -AllowNotFound; every other status outside 200-299 throws with ARM's error code and message.
    .EXAMPLE
        Invoke-AzlArm -Method GET -Path "/subscriptions/$sub/resourceGroups/$rg" -ApiVersion 2024-03-01
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ApiVersion,
        [object]$Body,
        [switch]$AllowNotFound
    )
    $resource = '/' + $Path.TrimStart('/')
    $separator = if ($resource.Contains('?')) { '&' } else { '?' }
    $request = @{ Method = $Method; Path = "$resource${separator}api-version=$ApiVersion" }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $request.Payload = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 50 -Compress }
    }
    $response = Invoke-AzRestMethod @request
    $status = [int]$response.StatusCode
    if ($status -eq 404 -and $AllowNotFound) { return $null }
    if ($status -lt 200 -or $status -ge 300) {
        $detail = $response.Content
        try {
            $parsed = $response.Content | ConvertFrom-Json
            $code = Get-AzlProp $parsed 'error.code'
            $message = Get-AzlProp $parsed 'error.message'
            if ($code -or $message) { $detail = "$code $message".Trim() }
        }
        catch { Write-Verbose "The error body wasn't JSON: $($_.Exception.Message)" }
        throw "ARM $Method $resource failed with HTTP ${status}: $detail"
    }
    if ([string]::IsNullOrWhiteSpace($response.Content)) { return [pscustomobject]@{} }
    return ($response.Content | ConvertFrom-Json -Depth 50)
}

function ConvertFrom-AzlKeyVaultRef {
    <#
    .SYNOPSIS
        keyvault://<vault>/<secret>[/<version>] into Vault, Secret and Version. $null when the value isn't a reference.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Reference)
    if ($Reference -notmatch '^keyvault://(?<vault>[^/]+)/(?<secret>[^/]+)(/(?<version>[^/]+))?$') { return $null }
    [pscustomobject]@{ Vault = $Matches['vault']; Secret = $Matches['secret']; Version = $(if ($Matches['version']) { $Matches['version'] } else { $null }) }
}

function Get-AzlSecret {
    <#
    .SYNOPSIS
        The plain-text value of a keyvault:// reference. Reads the vault; changes nothing.
    .DESCRIPTION
        The value stays in memory: callers pass it to a protected run-command parameter or a secure ARM parameter and never
        write it to a file or a log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Reference)
    $parts = ConvertFrom-AzlKeyVaultRef -Reference $Reference
    if (-not $parts) { throw "'$Reference' isn't a keyvault://<vault>/<secret> reference." }
    $arguments = @{ VaultName = $parts.Vault; Name = $parts.Secret; AsPlainText = $true }
    if ($parts.Version) { $arguments.Version = $parts.Version }
    $value = Get-AzKeyVaultSecret @arguments
    if ([string]::IsNullOrEmpty($value)) { throw "Secret $($parts.Secret) in vault $($parts.Vault) is empty or unreadable." }
    return [string]$value
}

function Read-AzlHandoff {
    <#
    .SYNOPSIS
        Reads azurelocal-ztp's handoff file (schema 2) and returns it with a Node lookup by name.
    .DESCRIPTION
        Schema 2 holds only what Azure generated during ZTP: nodes[] (name, serial, arcMachineName, arcMachineResourceId,
        arcMachineResourceGroup, ready, managementAddressVerified, managementAddressReason), solution.vsrVersion (the build
        installed), subscriptionId, resourceGroup and site. Addresses and MACs come from infrastructure.yml, not from here.
    .OUTPUTS
        SchemaVersion, SubscriptionId, ResourceGroup, VsrVersion, Nodes (name -> node object), Raw.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Handoff file not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20
    $version = [int](Get-AzlProp $raw 'schemaVersion' 0)
    if ($version -lt 2) { throw "$Path is handoff schema $version. This reads schema 2 (azurelocal-ztp, node entries with arcMachineResourceId and managementAddressVerified)." }
    $nodes = @{}
    foreach ($n in @(Get-AzlProp $raw 'nodes' @())) {
        $name = [string](Get-AzlProp $n 'name' '')
        if ($name) { $nodes[$name.ToLowerInvariant()] = $n }
    }
    [pscustomobject]@{
        SchemaVersion  = $version
        SubscriptionId = [string](Get-AzlProp $raw 'subscriptionId' '')
        ResourceGroup  = [string](Get-AzlProp $raw 'resourceGroup' '')
        VsrVersion     = [string](Get-AzlProp $raw 'solution.vsrVersion' '')
        Nodes          = $nodes
        Raw            = $raw
    }
}

function Get-AzlHandoffNode {
    <#
    .SYNOPSIS
        One node's entry from a handoff read by Read-AzlHandoff, matched by node name or Arc machine name. $null when absent.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Handoff, [Parameter(Mandatory)][string]$Name, [string]$ArcMachineName)
    if (-not $Handoff) { return $null }
    foreach ($candidate in @($Name, $ArcMachineName) | Where-Object { $_ }) {
        if ($Handoff.Nodes.ContainsKey($candidate.ToLowerInvariant())) { return $Handoff.Nodes[$candidate.ToLowerInvariant()] }
    }
    foreach ($entry in $Handoff.Nodes.Values) {
        if ($ArcMachineName -and [string](Get-AzlProp $entry 'arcMachineName' '') -ieq $ArcMachineName) { return $entry }
    }
    return $null
}

function Find-AzlArcMachine {
    <#
    .SYNOPSIS
        A node's Arc machine resource ID and, from Azure, its status and network interfaces.
    .DESCRIPTION
        The handoff's arcMachineResourceId wins. Without one the machine is looked up by its Arc machine name in the
        instance's resource group. Reads only.
    .OUTPUTS
        Name, ResourceId, Location, Status, Interfaces (the Arc agent's per-NIC report: name, macAddress, ipAddresses), or
        $null when no such machine exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArcMachineName,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [string]$ResourceId
    )
    $path = if ($ResourceId) { $ResourceId } else { "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ArcMachineName" }
    $machine = Invoke-AzlArm -Method GET -Path $path -ApiVersion $script:ArcMachineApiVersion -AllowNotFound
    if (-not $machine) { return $null }
    [pscustomobject]@{
        Name       = [string](Get-AzlProp $machine 'name' $ArcMachineName)
        ResourceId = [string](Get-AzlProp $machine 'id' $path)
        Location   = [string](Get-AzlProp $machine 'location' '')
        Status     = [string](Get-AzlProp $machine 'properties.status' '')
        Interfaces = @(Get-AzlProp $machine 'properties.networkProfile.networkInterfaces' @())
    }
}

Export-ModuleMember -Function Get-AzlProp, Invoke-AzlArm, ConvertFrom-AzlKeyVaultRef, Get-AzlSecret, Read-AzlHandoff, Get-AzlHandoffNode, Find-AzlArcMachine
