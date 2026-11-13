<#
.SYNOPSIS
    Creates the management virtual machines that landing_zone.virtual_machines of infrastructure.yml lists for Azure.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 11 (management VMs). For every entry of landing_zone.virtual_machines whose
    deploy_target is azure (or empty) the script creates a network interface with the static private IP address of the entry, in the subnet of
    the entry, and the virtual machine on it: the size and the operating system image of the entry, the local administrator user name of the entry
    and its password read from the secret reference. Domain controllers, the jump machine and every other role are created the same way. The
    script installs nothing in them: Active Directory, DNS and the rest are set up after the machine runs.

    The machine, its network interface and the virtual network are in the same subscription: the machine's subscription and region come from its
    network's entry in landing_zone.networks. An entry whose deploy_target is azure_local or onprem is skipped (another task builds those).

    The operating system is one of windows_server_2022, windows_server_2025 (Windows Server Datacenter: Azure Edition) or ubuntu_2404 (Ubuntu
    Server 24.04 LTS), each in its latest version. The OS disk and the other settings are the Azure defaults for the size.

    Idempotent, and additive. A machine that exists is reported as AlreadyExists and left alone (a different size is reported, not changed). A
    network interface that exists is reused. -WhatIf changes nothing and does not read the password.

    The script reads Azure (read only) and writes only with New-AzNetworkInterface and New-AzVM, behind -WhatIf. It does not sign in: run
    Connect-AzAccount to the tenant in azure.tenant_id first. You need Virtual Machine Contributor and Network Contributor (or Contributor) on
    the resource group, and permission to join the subnet. The password is a secret reference (keyvault://, env://, file:// or command://) read by
    the toolkit's secret resolver; it is never written, logged or returned. The script changes the subscription of the session while it works
    and puts it back. The tags in the file-level tags map are put on what it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags
        landing_zone.virtual_machines[]: name, hostname, role, deploy_target, subscription, resource_group, network, subnet, private_ip, size, os,
                                         admin_username, admin_password
        landing_zone.networks[].name, .subscription, .resource_group, .location     where the network is
        landing_zone.subscriptions[].name, .id                                      the subscription that holds the network

    Exit codes: 0 every machine exists (created now, already there, skipped because it is not an Azure machine, or planned under -WhatIf), or
    the file lists none; 1 an Azure call failed or a precondition failed (not signed in, wrong tenant, Az modules missing, a secret could not
    be read) or a creation failed; 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-ManagementVMs.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which machines would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-ManagementVMs.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the machines. Run it again: they are reported as AlreadyExists.
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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'
$Ipv4 = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
# The Azure Marketplace image of each operating system: fixed by the publishers (Microsoft Learn, Windows Server on Azure; Canonical, Ubuntu on Azure).
$OsImage = @{
    'windows_server_2022' = @{ Publisher = 'MicrosoftWindowsServer'; Offer = 'WindowsServer'; Sku = '2022-datacenter-azure-edition'; Windows = $true }
    'windows_server_2025' = @{ Publisher = 'MicrosoftWindowsServer'; Offer = 'WindowsServer'; Sku = '2025-datacenter-azure-edition'; Windows = $true }
    'ubuntu_2404'         = @{ Publisher = 'Canonical'; Offer = 'ubuntu-24_04-lts'; Sku = 'server'; Windows = $false }
}

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$defaultLocation = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$rawMachines = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.virtual_machines'
$machines = @(@($rawMachines) | Where-Object { $null -ne $_ })
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networks = @(@($rawNetworks) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptions = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($machines.Count -eq 0) {
    Write-Line 'The file lists no landing_zone.virtual_machines: nothing to do.'
    exit 0
}

$plan = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($machine in $machines) {
    $index++
    $at = "landing_zone.virtual_machines[$index]"
    if ($machine -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a machine (a map with name, network, subnet ...)." }
    $name = Get-Entry $machine 'name'
    if ($name -notmatch '^[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9_])?$') { Exit-InputProblem "$at.name '$name' is missing or is not a valid VM name (1 to 64 letters, digits, . _ -)." }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seen[$name.ToLowerInvariant()] = $true
    $target = if (Get-Entry $machine 'deploy_target') { Get-Entry $machine 'deploy_target' } else { 'azure' }
    if ($target -ne 'azure') { $plan.Add([pscustomobject]@{ Name = $name; Skip = "deploy_target is $target, not azure" }); continue }

    $networkName = Get-Entry $machine 'network'
    $subnetName = Get-Entry $machine 'subnet'
    $ip = Get-Entry $machine 'private_ip'
    $size = Get-Entry $machine 'size'
    $os = Get-Entry $machine 'os'
    $user = Get-Entry $machine 'admin_username'
    $reference = Get-Entry $machine 'admin_password'
    if (-not $networkName) { Exit-InputProblem "$at.network is missing for '$name'." }
    if (-not $subnetName) { Exit-InputProblem "$at.subnet is missing for '$name'." }
    if ($ip -notmatch $Ipv4) { Exit-InputProblem "$at.private_ip '$ip' is missing or is not an IPv4 address." }
    if (-not $size) { Exit-InputProblem "$at.size is missing for '$name'. It is an Azure VM size, for example Standard_D2s_v5." }
    if (-not $OsImage.ContainsKey($os)) { Exit-InputProblem "$at.os '$os' is missing or not usable. Use one of: $(($OsImage.Keys | Sort-Object) -join ', ')." }
    if (-not $user) { Exit-InputProblem "$at.admin_username is missing for '$name'." }
    if (-not $reference) { Exit-InputProblem "$at.admin_password is missing for '$name'. It is a secret reference (for example keyvault://<vault>/<secret>), never the password." }
    if (-not (Get-AzlSecretProvider -Reference $reference)) { Exit-InputProblem "$at.admin_password is not a secret reference (keyvault://, env://, file:// or command://). The password itself is never written to the file." }
    $hostName = if (Get-Entry $machine 'hostname') { Get-Entry $machine 'hostname' } else { $name }
    if ($OsImage[$os].Windows -and $hostName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') { Exit-InputProblem "${at}: the computer name '$hostName' of a Windows machine is 1 to 15 letters, digits and hyphens. Set hostname." }

    $network = @($networks | Where-Object { (Get-Entry $_ 'name') -eq $networkName }) | Select-Object -First 1
    if (-not $network) { Exit-InputProblem "$at.network '$networkName' is not an entry of landing_zone.networks." }
    $subscriptionName = Get-Entry $network 'subscription'
    $subscription = @($subscriptions | Where-Object { (Get-Entry $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
    $subscriptionId = if ($subscription) { Get-Entry $subscription 'id' } else { '' }
    if (-not $subscriptionName) { Exit-InputProblem "The network '$networkName' has no subscription in landing_zone.networks." }
    if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "The subscription '$subscriptionName' of the network '$networkName' has no usable id in landing_zone.subscriptions." }
    if ((Get-Entry $machine 'subscription') -and (Get-Entry $machine 'subscription') -ne $subscriptionName) { Exit-InputProblem "$at.subscription '$(Get-Entry $machine 'subscription')' is not the subscription of its network ('$subscriptionName'): a network interface can use only a subnet of its own subscription." }
    $networkGroup = Get-Entry $network 'resource_group'
    $group = if (Get-Entry $machine 'resource_group') { Get-Entry $machine 'resource_group' } else { $networkGroup }
    if (-not $networkGroup) { Exit-InputProblem "The network '$networkName' has no resource_group in landing_zone.networks." }
    $location = if (Get-Entry $network 'location') { Get-Entry $network 'location' } else { $defaultLocation }
    if (-not $location) { Exit-InputProblem "No region: the network '$networkName' has no location and azure.location is empty." }
    $plan.Add([pscustomobject]@{
            Name = $name; Skip = ''; Role = (Get-Entry $machine 'role'); HostName = $hostName; Network = $networkName; NetworkGroup = $networkGroup; Subnet = $subnetName; PrivateIp = $ip; Size = $size; Os = $os
            User = $user; Reference = $reference; Group = $group; Location = $location; SubscriptionId = $subscriptionId
        })
}
if (@($plan | Where-Object { -not $_.Skip }).Count -eq 0) {
    Write-Line 'No machine of landing_zone.virtual_machines is for Azure: nothing to do.'
    exit 0
}

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzVM', 'New-AzVM', 'New-AzVMConfig', 'Set-AzVMOperatingSystem', 'Set-AzVMSourceImage', 'Set-AzVMOSDisk', 'Add-AzVMNetworkInterface', 'Get-AzVirtualNetwork', 'Get-AzVirtualNetworkSubnetConfig', 'Get-AzNetworkInterface', 'New-AzNetworkInterface') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts, Az.Compute and Az.Network modules: Install-Module Az.Accounts, Az.Compute, Az.Network -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

Write-Line "Management VMs: $(@($plan | Where-Object { -not $_.Skip }).Count) for Azure, $(@($plan | Where-Object Skip).Count) skipped"
$rows = [System.Collections.Generic.List[object]]::new()
$currentSubscription = ''
try {
    foreach ($item in $plan) {
        $row = [ordered]@{ Machine = $item.Name; Role = $(if ($item.PSObject.Properties['Role']) { $item.Role } else { '' }); Action = ''; PrivateIp = ''; Detail = '' }
        if ($item.Skip) {
            $row.Action = 'Skipped'; $row.Detail = $item.Skip
            Write-Line "[skip]    $($item.Name): $($item.Skip)."
            $rows.Add([pscustomobject]$row)
            continue
        }
        $row.PrivateIp = $item.PrivateIp
        try {
            if ($currentSubscription -ne $item.SubscriptionId) {
                $null = Set-AzContext -SubscriptionId $item.SubscriptionId -Tenant $tenantId -ErrorAction Stop
                $currentSubscription = $item.SubscriptionId
            }
            $existing = $null
            try { $existing = Get-AzVM -ResourceGroupName $item.Group -Name $item.Name -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

            if ($existing) {
                $row.Action = 'AlreadyExists'
                Write-Line "[exists]  The machine '$($item.Name)' is already there, nothing changed."
                $existingSize = if ($existing.PSObject.Properties['HardwareProfile'] -and $existing.HardwareProfile) { [string]$existing.HardwareProfile.VmSize } else { '' }
                if ($existingSize -and $existingSize -ne $item.Size) {
                    $row.Detail = "Differs from the file (the size is $existingSize, the file says $($item.Size)); left unchanged."
                    Write-Warning "$($item.Name): $($row.Detail)"
                }
            }
            elseif ($PSCmdlet.ShouldProcess("virtual machine '$($item.Name)' in '$($item.Group)'", "Create ($($item.Size), $($item.Os), $($item.PrivateIp) in $($item.Subnet))")) {
                $vnet = $null
                try { $vnet = Get-AzVirtualNetwork -ResourceGroupName $item.NetworkGroup -Name $item.Network -ErrorAction Stop }
                catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
                if (-not $vnet) { throw "The virtual network '$($item.Network)' does not exist in '$($item.NetworkGroup)'. Create it first (Deploy-VirtualNetworks.ps1)." }
                $subnet = Get-AzVirtualNetworkSubnetConfig -Name $item.Subnet -VirtualNetwork $vnet -ErrorAction SilentlyContinue
                if (-not $subnet) { throw "The virtual network '$($item.Network)' has no subnet named '$($item.Subnet)'." }

                $nicName = "$($item.Name)-nic"
                $nic = $null
                try { $nic = Get-AzNetworkInterface -ResourceGroupName $item.Group -Name $nicName -ErrorAction Stop }
                catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
                if (-not $nic) {
                    $nicArgs = @{ ResourceGroupName = $item.Group; Name = $nicName; Location = $item.Location; SubnetId = $subnet.Id; PrivateIpAddress = $item.PrivateIp; ErrorAction = 'Stop' }
                    if ($tags.Count) { $nicArgs.Tag = $tags }
                    $nic = New-AzNetworkInterface @nicArgs
                    Write-Line "[created] Network interface '$nicName' ($($item.PrivateIp))."
                }
                else { Write-Line "[exists]  Network interface '$nicName' is reused." }

                $password = Get-AzlSecretValue -Reference $item.Reference -Infrastructure $infra
                $credential = [System.Management.Automation.PSCredential]::new($item.User, $password)
                $image = $OsImage[$item.Os]
                $config = New-AzVMConfig -VMName $item.Name -VMSize $item.Size
                if ($image.Windows) { $config = Set-AzVMOperatingSystem -VM $config -Windows -ComputerName $item.HostName -Credential $credential -ProvisionVMAgent -EnableAutoUpdate }
                else { $config = Set-AzVMOperatingSystem -VM $config -Linux -ComputerName $item.HostName -Credential $credential }
                $config = Set-AzVMSourceImage -VM $config -PublisherName $image.Publisher -Offer $image.Offer -Skus $image.Sku -Version 'latest'
                $config = Set-AzVMOSDisk -VM $config -Name "$($item.Name)-osdisk" -CreateOption 'FromImage'
                $config = Add-AzVMNetworkInterface -VM $config -Id $nic.Id
                $vmArgs = @{ ResourceGroupName = $item.Group; Location = $item.Location; VM = $config; ErrorAction = 'Stop' }
                if ($tags.Count) { $vmArgs.Tag = $tags }
                $null = New-AzVM @vmArgs
                $row.Action = 'Created'
                Write-Line "[created] The machine '$($item.Name)' ($($item.Size), $($item.Os))."
            }
            else {
                $row.Action = 'WouldCreate'
                Write-Line "[plan]    The machine '$($item.Name)' would be created ($($item.Size), $($item.Os), $($item.PrivateIp))."
            }
        }
        catch {
            $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
            Write-Warning "$($item.Name): $($row.Detail)"
        }
        $rows.Add([pscustomobject]$row)
    }
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
