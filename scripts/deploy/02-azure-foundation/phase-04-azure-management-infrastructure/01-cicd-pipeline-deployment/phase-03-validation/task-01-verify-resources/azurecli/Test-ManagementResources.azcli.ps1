<#
.SYNOPSIS
    Checks with the Azure CLI that the management infrastructure of infrastructure.yml exists in Azure and is in the state the file describes. Changes nothing.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), CI/CD pipeline deployment, Phase 03 (validation), Task 01 (verify Azure resources). After the
    Terraform apply (or the manual deployment) this script reads each resource the file describes with an "az ... show" command and compares what
    Azure reports with the file. One result row per check: Check, Target, Status (Pass or Fail) and Detail.

    What is checked, and only when the file describes it:
        resource group      landing_zone.resource_groups[] (else azure.resource_group) exists
        virtual network     provisioning state Succeeded, the address space and each subnet (name and prefix) of landing_zone.networks[], and
                            the network security group the file names for a subnet is attached
        VPN gateway         landing_zone.connectivity.vpn_gateway: Succeeded, gateway type Vpn, the SKU, BGP on and the BGP ASN of the file
        Azure Bastion       landing_zone.connectivity.bastion: Succeeded and the SKU of the file
        NAT gateway         landing_zone.connectivity.nat_gateway: Succeeded
        Key Vault           key_vaults[]: Succeeded, soft delete on (and the retention days of the file), purge protection on unless
                            scenario.environment_class is lab, test or dev (the rule of Deploy-KeyVaults.ps1)
        Log Analytics       operations.monitoring.log_analytics_workspace: Succeeded and the retention days of the file
        virtual machine     landing_zone.virtual_machines[]: Succeeded and running

    The VPN connection status and the BGP peers are checked by the connectivity task (Test-ManagementConnectivity.azcli.ps1); the Key Vault access,
    diagnostic settings and tags by the configuration task (Test-ManagementConfiguration.azcli.ps1).

    The script only reads. It does not sign in: run "az login --tenant <azure.tenant_id>" first. Reader on the subscriptions is enough. Each az call
    names its subscription with --subscription, so the subscription that az has selected is not changed.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, scenario.environment_class
        landing_zone.subscriptions[].name, .id                      the subscription of each network and virtual machine
        landing_zone.resource_groups[].name, .subscription
        landing_zone.networks[].name, .subscription, .resource_group, .address_space, .subnets[].name, .prefix, .network_security_group
        landing_zone.connectivity.vpn_gateway.name, .resource_group, .network, .sku, .bgp_asn
        landing_zone.connectivity.bastion.name, .resource_group, .network, .sku
        landing_zone.connectivity.nat_gateway.name, .resource_group, .network
        landing_zone.virtual_machines[].name, .subscription, .resource_group
        key_vaults[].name, .subscription_id, .resource_group, .soft_delete_retention_days
        operations.monitoring.enabled, .log_analytics_workspace, .workspace_resource_group, .retention_days

    Exit codes: 0 every check passed; 1 a check failed, an az call failed or a precondition failed (az missing, not signed in, wrong tenant); 2 the
    file describes nothing to check, or a value is not usable (a network the file does not list, a subscription without an id).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-ManagementResources.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Prints one row for each check and ends with exit code 0 when all of them pass.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = '(?i)NotFound|not found|could not be found|does not exist|\b404\b'
# The environment classes of scenario.environment_class in which a vault has to be removable, so purge protection is off (Deploy-KeyVaults.ps1).
$RemovableClass = @('lab', 'test', 'dev')

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# One az call. Returns the text of standard output; throws, with the error text, when az ends with an error (warnings on standard error are dropped).
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgument)
    $all = @(& az @AzArgument 2>&1)
    $code = $LASTEXITCODE
    $errorText = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ').Trim()
    $text = (@($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0) { throw $(if ($errorText -or $text) { (@($errorText, $text) | Where-Object { $_ }) -join ' ' } else { "az ended with exit code $code." }) }
    $text
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

function Get-List([string]$Path) {
    $raw = Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path
    @(@($raw) | Where-Object { $_ -is [System.Collections.IDictionary] })
}

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$homeSubscription = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
$instanceGroup = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.resource_group')).Trim()
$environmentClass = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.environment_class')).Trim().ToLowerInvariant()
$subscriptionEntries = @(Get-List 'landing_zone.subscriptions')
$networkEntries = @(Get-List 'landing_zone.networks')
$groupEntries = @(Get-List 'landing_zone.resource_groups')
$machineEntries = @(Get-List 'landing_zone.virtual_machines')
$vaultEntries = @(Get-List 'key_vaults')
$vpn = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.vpn_gateway'
$bastion = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.bastion'
$nat = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.nat_gateway'
$monitoringEnabled = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring.enabled'
$workspaceName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring.log_analytics_workspace')).Trim()
$workspaceGroup = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring.workspace_resource_group')).Trim()
$workspaceRetention = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring.retention_days')).Trim()

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }

function Test-UsableId([string]$Id) { $Id -match $Guid -and $Id -ne [guid]::Empty.ToString() }
function Get-SubscriptionIdByName([string]$Name, [string]$At) {
    if (-not $Name) {
        if (-not (Test-UsableId $homeSubscription)) { Exit-InputProblem "$At names no subscription, and azure.subscription_id is missing, not a GUID or the all-zero placeholder." }
        return $homeSubscription
    }
    $entry = @($subscriptionEntries | Where-Object { (Get-Entry $_ 'name') -eq $Name }) | Select-Object -First 1
    if (-not $entry) { Exit-InputProblem "$At.subscription '$Name' is not a name in landing_zone.subscriptions." }
    $id = Get-Entry $entry 'id'
    if (-not (Test-UsableId $id)) { Exit-InputProblem "$At.subscription '$Name' has no usable id in landing_zone.subscriptions." }
    $id
}
function Get-NetworkPlace([string]$NetworkName, [string]$At) {
    if (-not $NetworkName) { Exit-InputProblem "$At.network is missing. Name the virtual network (an entry of landing_zone.networks)." }
    $network = @($networkEntries | Where-Object { (Get-Entry $_ 'name') -eq $NetworkName }) | Select-Object -First 1
    if (-not $network) { Exit-InputProblem "$At.network '$NetworkName' is not an entry of landing_zone.networks." }
    $group = Get-Entry $network 'resource_group'
    if (-not $group) { Exit-InputProblem "The network '$NetworkName' has no resource_group in landing_zone.networks." }
    if (-not (Get-Entry $network 'subscription')) { Exit-InputProblem "The network '$NetworkName' has no subscription in landing_zone.networks." }
    [pscustomobject]@{ SubscriptionId = (Get-SubscriptionIdByName (Get-Entry $network 'subscription') "landing_zone.networks '$NetworkName'"); ResourceGroup = $group }
}

# Each target: Kind, Name, ResourceGroup, SubscriptionId and the expectations of the file.
$targets = [System.Collections.Generic.List[object]]::new()
function Add-Target([string]$Kind, [string]$Name, [string]$Group, [string]$SubscriptionId, [hashtable]$Expect = @{}) {
    $targets.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; ResourceGroup = $Group; SubscriptionId = $SubscriptionId; Expect = $Expect })
}

if ($groupEntries.Count -gt 0) {
    $index = -1
    foreach ($entry in $groupEntries) {
        $index++
        $name = Get-Entry $entry 'name'
        if (-not $name) { Exit-InputProblem "landing_zone.resource_groups[$index] has no name." }
        Add-Target -Kind 'ResourceGroup' -Name $name -Group $name -SubscriptionId (Get-SubscriptionIdByName (Get-Entry $entry 'subscription') "landing_zone.resource_groups[$index]")
    }
}
elseif ($instanceGroup) {
    Add-Target -Kind 'ResourceGroup' -Name $instanceGroup -Group $instanceGroup -SubscriptionId (Get-SubscriptionIdByName '' 'azure.resource_group')
}

foreach ($network in $networkEntries) {
    $name = Get-Entry $network 'name'
    if (-not $name) { Exit-InputProblem 'An entry of landing_zone.networks has no name.' }
    $place = Get-NetworkPlace -NetworkName $name -At 'landing_zone.networks'
    $subnets = @(@($network['subnets']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object {
            [pscustomobject]@{ Name = (Get-Entry $_ 'name'); Prefix = (Get-Entry $_ 'prefix'); Nsg = (Get-Entry $_ 'network_security_group') } })
    $space = @(@($(if ($network.Contains('address_space')) { $network['address_space'] })) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
    Add-Target -Kind 'VirtualNetwork' -Name $name -Group $place.ResourceGroup -SubscriptionId $place.SubscriptionId -Expect @{ AddressSpace = $space; Subnets = $subnets }
}
if ($vpn -is [System.Collections.IDictionary] -and (Get-Entry $vpn 'name')) {
    $place = Get-NetworkPlace -NetworkName (Get-Entry $vpn 'network') -At 'landing_zone.connectivity.vpn_gateway'
    $group = if (Get-Entry $vpn 'resource_group') { Get-Entry $vpn 'resource_group' } else { $place.ResourceGroup }
    Add-Target -Kind 'VpnGateway' -Name (Get-Entry $vpn 'name') -Group $group -SubscriptionId $place.SubscriptionId -Expect @{ Sku = (Get-Entry $vpn 'sku'); Asn = (Get-Entry $vpn 'bgp_asn') }
}
if ($bastion -is [System.Collections.IDictionary] -and (Get-Entry $bastion 'name')) {
    $place = Get-NetworkPlace -NetworkName (Get-Entry $bastion 'network') -At 'landing_zone.connectivity.bastion'
    $group = if (Get-Entry $bastion 'resource_group') { Get-Entry $bastion 'resource_group' } else { $place.ResourceGroup }
    Add-Target -Kind 'Bastion' -Name (Get-Entry $bastion 'name') -Group $group -SubscriptionId $place.SubscriptionId -Expect @{ Sku = (Get-Entry $bastion 'sku') }
}
if ($nat -is [System.Collections.IDictionary] -and (Get-Entry $nat 'name')) {
    $place = Get-NetworkPlace -NetworkName (Get-Entry $nat 'network') -At 'landing_zone.connectivity.nat_gateway'
    $group = if (Get-Entry $nat 'resource_group') { Get-Entry $nat 'resource_group' } else { $place.ResourceGroup }
    Add-Target -Kind 'NatGateway' -Name (Get-Entry $nat 'name') -Group $group -SubscriptionId $place.SubscriptionId
}
foreach ($vault in $vaultEntries) {
    $name = Get-Entry $vault 'name'
    if (-not $name) { Exit-InputProblem 'An entry of key_vaults has no name.' }
    $id = if (Get-Entry $vault 'subscription_id') { Get-Entry $vault 'subscription_id' } else { $homeSubscription }
    if (-not (Test-UsableId $id)) { Exit-InputProblem "key_vaults '$name' has no usable subscription_id, and azure.subscription_id is missing, not a GUID or the all-zero placeholder." }
    Add-Target -Kind 'KeyVault' -Name $name -Group (Get-Entry $vault 'resource_group') -SubscriptionId $id -Expect @{ Retention = (Get-Entry $vault 'soft_delete_retention_days') }
}
if ($monitoringEnabled -ne $false -and $workspaceName) {
    if (-not $workspaceGroup) { Exit-InputProblem 'operations.monitoring.log_analytics_workspace is set, but operations.monitoring.workspace_resource_group is missing.' }
    Add-Target -Kind 'LogAnalytics' -Name $workspaceName -Group $workspaceGroup -SubscriptionId (Get-SubscriptionIdByName '' 'operations.monitoring') -Expect @{ Retention = $workspaceRetention }
}
foreach ($machine in $machineEntries) {
    $name = Get-Entry $machine 'name'
    if (-not $name) { Exit-InputProblem 'An entry of landing_zone.virtual_machines has no name.' }
    if (-not (Get-Entry $machine 'resource_group')) { Exit-InputProblem "landing_zone.virtual_machines '$name' has no resource_group." }
    Add-Target -Kind 'VirtualMachine' -Name $name -Group (Get-Entry $machine 'resource_group') -SubscriptionId (Get-SubscriptionIdByName (Get-Entry $machine 'subscription') "landing_zone.virtual_machines '$name'")
}
if ($targets.Count -eq 0) { Exit-InputProblem 'The file describes no resource to check: list landing_zone.resource_groups, networks, connectivity, key_vaults or virtual_machines.' }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Invoke-VerifyResources-Orchestrated.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param([string]$Check, [string]$Target, [bool]$Pass, [string]$Detail = '')
    $rows.Add([pscustomobject][ordered]@{ Check = $Check; Target = $Target; Status = $(if ($Pass) { 'Pass' } else { 'Fail' }); Detail = $Detail })
    Write-Line ('[{0}] {1}: {2}{3}' -f $(if ($Pass) { 'pass' } else { 'FAIL' }), $Check, $Target, $(if ($Detail) { " ($Detail)" } else { '' }))
}
# Reads one resource as JSON; $null when it does not exist.
function Get-Resource([string[]]$AzArgument) {
    try { return (Invoke-Az -AzArgument $AzArgument | ConvertFrom-Json) }
    catch { if ($_.Exception.Message -match $NotFound) { return $null }; throw }
}
function Get-Problem([object]$Resource, [string]$What) {
    if ($Resource.PSObject.Properties['state'] -and [string]$Resource.state -ne 'Succeeded') { return "$What is $($Resource.state), not Succeeded" }
    $null
}

Write-Line "Verifying $($targets.Count) resource(s)"
foreach ($t in $targets) {
    $check = $t.Kind
    $subscription = @('--subscription', $t.SubscriptionId)
    try {
        $resource = $null
        $problems = [System.Collections.Generic.List[string]]::new()
        switch ($t.Kind) {
            'ResourceGroup' {
                $resource = Get-Resource (@('group', 'show', '--name', $t.Name) + $subscription + @('--query', '{state:properties.provisioningState}', '--output', 'json'))
            }
            'VirtualNetwork' {
                $resource = Get-Resource (@('network', 'vnet', 'show', '--resource-group', $t.ResourceGroup, '--name', $t.Name) + $subscription + @('--query', '{state:provisioningState,prefixes:addressSpace.addressPrefixes,subnets:subnets[].{name:name,prefix:addressPrefix,prefixes:addressPrefixes,nsg:networkSecurityGroup.id}}', '--output', 'json'))
                if ($resource) {
                    $actual = @($resource.prefixes | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() })
                    foreach ($prefix in $t.Expect.AddressSpace) { if ($prefix.ToLowerInvariant() -notin $actual) { $problems.Add("address space $prefix is missing") } }
                    foreach ($subnet in $t.Expect.Subnets) {
                        $found = @($resource.subnets | Where-Object { [string]$_.name -ieq $subnet.Name }) | Select-Object -First 1
                        if (-not $found) { $problems.Add("subnet $($subnet.Name) is missing"); continue }
                        $foundPrefixes = @(@($found.PSObject.Properties | Where-Object { $_.Name -in 'prefix', 'prefixes' } | ForEach-Object { $_.Value }) | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() })
                        if ($subnet.Prefix -and $subnet.Prefix.ToLowerInvariant() -notin $foundPrefixes) { $problems.Add("subnet $($subnet.Name) has the prefix $($foundPrefixes -join ', '), the file says $($subnet.Prefix)") }
                        $foundNsg = if ($found.PSObject.Properties['nsg']) { [string]$found.nsg } else { '' }
                        if ($subnet.Nsg -and $foundNsg -notmatch ('(?i)/networkSecurityGroups/' + [regex]::Escape($subnet.Nsg) + '$')) { $problems.Add("subnet $($subnet.Name) has not the network security group $($subnet.Nsg)") }
                    }
                }
            }
            'VpnGateway' {
                $resource = Get-Resource (@('network', 'vnet-gateway', 'show', '--resource-group', $t.ResourceGroup, '--name', $t.Name) + $subscription + @('--query', '{state:provisioningState,type:gatewayType,sku:sku.name,asn:bgpSettings.asn,bgp:enableBgp}', '--output', 'json'))
                if ($resource) {
                    if ([string]$resource.type -ne 'Vpn') { $problems.Add("the gateway type is $($resource.type), not Vpn") }
                    if ($t.Expect.Sku -and [string]$resource.sku -ne $t.Expect.Sku) { $problems.Add("the SKU is $($resource.sku), the file says $($t.Expect.Sku)") }
                    if ($t.Expect.Asn) {
                        if (-not $resource.bgp) { $problems.Add('BGP is not enabled') }
                        if ([string]$resource.asn -ne $t.Expect.Asn) { $problems.Add("the BGP ASN is $($resource.asn), the file says $($t.Expect.Asn)") }
                    }
                }
            }
            'Bastion' {
                $resource = Get-Resource (@('network', 'bastion', 'show', '--resource-group', $t.ResourceGroup, '--name', $t.Name) + $subscription + @('--query', '{state:provisioningState,sku:sku.name}', '--output', 'json'))
                if ($resource -and $t.Expect.Sku -and [string]$resource.sku -ne $t.Expect.Sku) { $problems.Add("the SKU is $($resource.sku), the file says $($t.Expect.Sku)") }
            }
            'NatGateway' {
                $resource = Get-Resource (@('network', 'nat', 'gateway', 'show', '--resource-group', $t.ResourceGroup, '--name', $t.Name) + $subscription + @('--query', '{state:provisioningState}', '--output', 'json'))
            }
            'KeyVault' {
                $show = @('keyvault', 'show', '--name', $t.Name) + $subscription
                if ($t.ResourceGroup) { $show += @('--resource-group', $t.ResourceGroup) }
                $resource = Get-Resource ($show + @('--query', '{state:properties.provisioningState,softDelete:properties.enableSoftDelete,retention:properties.softDeleteRetentionInDays,purge:properties.enablePurgeProtection}', '--output', 'json'))
                if ($resource) {
                    if ($null -ne $resource.softDelete -and -not $resource.softDelete) { $problems.Add('soft delete is off') }
                    if ($t.Expect.Retention -and [string]$resource.retention -ne $t.Expect.Retention) { $problems.Add("the soft delete retention is $($resource.retention) days, the file says $($t.Expect.Retention)") }
                    if ($RemovableClass -notcontains $environmentClass -and -not $resource.purge) { $problems.Add('purge protection is off') }
                }
            }
            'LogAnalytics' {
                $resource = Get-Resource (@('monitor', 'log-analytics', 'workspace', 'show', '--resource-group', $t.ResourceGroup, '--workspace-name', $t.Name) + $subscription + @('--query', '{state:provisioningState,retention:retentionInDays}', '--output', 'json'))
                if ($resource -and $t.Expect.Retention -and [string]$resource.retention -ne $t.Expect.Retention) { $problems.Add("the retention is $($resource.retention) days, the file says $($t.Expect.Retention)") }
            }
            'VirtualMachine' {
                $resource = Get-Resource (@('vm', 'show', '--resource-group', $t.ResourceGroup, '--name', $t.Name) + $subscription + @('--show-details', '--query', '{state:provisioningState,power:powerState}', '--output', 'json'))
                if ($resource -and [string]$resource.power -notmatch '(?i)running') { $problems.Add("the power state is $($resource.power), not running") }
            }
        }
        if (-not $resource) { Add-Check -Check $check -Target $t.Name -Pass $false -Detail 'not found'; continue }
        $state = Get-Problem -Resource $resource -What $check
        if ($state) { $problems.Insert(0, $state) }
        Add-Check -Check $check -Target $t.Name -Pass ($problems.Count -eq 0) -Detail ($problems -join '; ')
    }
    catch { Add-Check -Check $check -Target $t.Name -Pass $false -Detail $_.Exception.Message }
}

$failed = @($rows | Where-Object Status -EQ 'Fail')
Write-Line "Summary: $($rows.Count - $failed.Count) of $($rows.Count) checks passed, $($failed.Count) failed."
$rows
if ($failed.Count -gt 0) { exit 1 }
exit 0
