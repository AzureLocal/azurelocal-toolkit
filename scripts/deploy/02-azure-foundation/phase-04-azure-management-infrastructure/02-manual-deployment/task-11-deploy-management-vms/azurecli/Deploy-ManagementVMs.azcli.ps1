<#
.SYNOPSIS
    Creates the management virtual machines that landing_zone.virtual_machines of infrastructure.yml lists for Azure, with the Azure CLI.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 11 (management VMs), Azure CLI variant of Deploy-ManagementVMs.ps1. It does the
    same with az commands, for a host that has the Azure CLI and not the Az PowerShell modules. For every entry of landing_zone.virtual_machines whose
    deploy_target is azure (or empty) the script creates a network interface with the static private IP address of the entry, in the subnet of
    the entry ("az network nic create"), and the virtual machine on it ("az vm create"): the size and the operating system image of the entry, the
    local administrator user name of the entry and its password read from the secret reference. Domain controllers, the jump machine and every
    other role are created the same way. The script installs nothing in them: Active Directory, DNS and the rest are set up inside the machine
    after it runs (the configuration tasks 12 to 15 of this phase are done in the guest operating system, not with the Azure CLI).

    The machine, its network interface and the virtual network are in the same subscription: the machine's subscription and region come from its
    network's entry in landing_zone.networks. An entry whose deploy_target is azure_local or onprem is skipped (another task builds those).

    The operating system is one of windows_server_2022, windows_server_2025 (Windows Server Datacenter: Azure Edition) or ubuntu_2404 (Ubuntu
    Server 24.04 LTS), each in its latest version. The OS disk and the other settings are the Azure defaults for the size.

    Idempotent, and additive. A machine that exists is reported as AlreadyExists and left alone (a different size is reported, not changed). A
    network interface that exists is reused. -WhatIf changes nothing and does not read the password.

    The administrator password is a secret reference. A keyvault://<vault>/<secret> reference is read at run time with "az keyvault secret show"
    (the vault must be listed under key_vaults; you need Key Vault Secrets User on it); env://, file:// and command:// references go through
    the toolkit's secret resolver. The password is never written, logged, printed or returned, and an az error text that would hold it is cleaned
    before it is shown. "az vm create" takes the password as an argument, so it is on the command line of that one az process for the seconds the
    call lasts.
    On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and a double quote or a line break
    breaks the argument. The script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, the
    size, the user name, a tag key or value ...) that holds one of & | < > ^ % " or a line break. It refuses a password that holds one right after reading
    it, before it creates the network interface (the message names the reference, never the password; create the secret again without these characters).
    Every az call is checked again in the one function that starts az.

    The script reads Azure (read only) and writes only with "az network nic create" and "az vm create", behind -WhatIf. It does not sign in: run
    "az login --tenant <azure.tenant_id>" first. You need Virtual Machine Contributor and Network Contributor (or Contributor) on the resource
    group, and permission to join the subnet. Every az call names its subscription, so the subscription of the az session is not changed. The
    tags in the file-level tags map are put on what it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags, key_vaults[].name (to check the vault of a keyvault:// reference)
        landing_zone.virtual_machines[]: name, hostname, role, deploy_target, subscription, resource_group, network, subnet, private_ip, size, os,
                                         admin_username, admin_password
        landing_zone.networks[].name, .subscription, .resource_group, .location     where the network is
        landing_zone.subscriptions[].name, .id                                      the subscription that holds the network

    Exit codes: 0 every machine exists (created now, already there, skipped because it is not an Azure machine, or planned under -WhatIf), or
    the file lists none; 1 an az call failed or a precondition failed (az missing, not signed in, wrong tenant, a secret could not
    be read) or a creation failed; 2 a value in the file is missing or not usable (a secret reference whose vault is not listed under key_vaults, a value or a
    password with a character that az.cmd cannot carry).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-ManagementVMs.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which machines would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Deploy-ManagementVMs.azcli.ps1 -InfrastructureFile ./infrastructure.yml

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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecretAzureCli.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'ResourceNotFound|NotFound|could not be found|was not found|does not exist|\b404\b'
$Ipv4 = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
# Every machine gets the latest version of its image (the fourth part of the az image URN Publisher:Offer:Sku:Version).
$ImageVersion = 'latest'
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

# One az call. Returns the text of standard output (warnings on standard error are dropped); throws with the error text when az fails.
function Invoke-Az {
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $args
    if ($unsafe) { Exit-InputProblem $unsafe }
    $out = @(& az @args 2>&1)
    if ($LASTEXITCODE -ne 0) { throw (($out | ForEach-Object { "$_" }) -join ' ').Trim() }
    (@($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
}

# The secret a reference points to, as text, for a call that has to carry it. A keyvault:// reference is read with the Azure CLI by the secrets module of the
# toolkit (AzlSecretAzureCli.psm1, next to the resolver); env://, file:// and command:// go through the resolver. The value is never written or logged, and no
# message holds it. The script block starts az for the module.
function Get-SecretText([string]$Reference) {
    Get-AzlSecretPlainTextAzureCli -Reference $Reference -Infrastructure $infra -Az { param([string[]]$AzArguments) & az @AzArguments 2>$null }
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$defaultLocation = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$rawMachines = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.virtual_machines'
$machines = @(@($rawMachines) | Where-Object { $null -ne $_ })
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networks = @(@($rawNetworks) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawNetworks)) { Exit-InputProblem 'An entry of landing_zone.networks is not a map (names with their settings).' } })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptions = @(@($rawSubscriptions) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawSubscriptions)) { Exit-InputProblem 'An entry of landing_zone.subscriptions is not a map (names with their settings).' } })
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
    # The reference is checked now, also under -WhatIf: the form, and that the vault is listed under key_vaults. Nothing is read.
    try { Assert-AzlSecretReferenceAzureCli -Reference $reference -Infrastructure $infra }
    catch { Exit-InputProblem "$at.admin_password is not usable: $($_.Exception.Message)" }
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
    # The values of this entry that go into an az argument, checked before any Azure call (also under -WhatIf). The address, the OS and the names that have their
    # own pattern are checked above.
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "$at.hostname" = $hostName; "$at.network" = $networkName; "$at.subnet" = $subnetName; "$at.size" = $size; "$at.admin_username" = $user; "$at.resource_group" = $group; "the resource group of the network '$networkName'" = $networkGroup; "the location of the network '$networkName'" = $location })
    if ($problem) { Exit-InputProblem $problem }
    $plan.Add([pscustomobject]@{
            Name = $name; Skip = ''; Role = (Get-Entry $machine 'role'); HostName = $hostName; Network = $networkName; NetworkGroup = $networkGroup; Subnet = $subnetName; PrivateIp = $ip; Size = $size; Os = $os
            User = $user; Reference = $reference; Group = $group; Location = $location; SubscriptionId = $subscriptionId
        })
}
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = $tags })
if ($problem) { Exit-InputProblem $problem }
if (@($plan | Where-Object { -not $_.Skip }).Count -eq 0) {
    Write-Line 'No machine of landing_zone.virtual_machines is for Azure: nothing to do.'
    exit 0
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Deploy-ManagementVMs.ps1.' }
try { $account = Invoke-Az account show --query tenantId --output tsv }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($account -ne $tenantId) { Exit-Failed "Signed in to tenant $account, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

# One az call with JSON output, parsed; $null when az printed nothing.
function Invoke-AzJson {
    $text = Invoke-Az @args '--output' 'json'
    if ($text) { $text | ConvertFrom-Json }
}
# The same, for a resource that may not be there: $null when az says it was not found; any other error is thrown.
function Get-AzCliResource {
    try { Invoke-AzJson @args }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
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
# The --tags arguments of az, from the file-level tags map; nothing when there are none.
function Get-TagArgument { if ($tags.Count) { '--tags'; @($tags.Keys | Sort-Object | ForEach-Object { "$_=$($tags[$_])" }) } }

Write-Line "Management VMs: $(@($plan | Where-Object { -not $_.Skip }).Count) for Azure, $(@($plan | Where-Object Skip).Count) skipped"
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($item in $plan) {
    $row = [ordered]@{ Machine = $item.Name; Role = $(if ($item.PSObject.Properties['Role']) { $item.Role } else { '' }); Action = ''; PrivateIp = ''; Detail = '' }
    if ($item.Skip) {
        $row.Action = 'Skipped'; $row.Detail = $item.Skip
        Write-Line "[skip]    $($item.Name): $($item.Skip)."
        $rows.Add([pscustomobject]$row)
        continue
    }
    $row.PrivateIp = $item.PrivateIp
    $password = $null
    try {
        $existing = Get-AzCliResource vm show --name $item.Name --resource-group $item.Group --subscription $item.SubscriptionId

        if ($existing) {
            $row.Action = 'AlreadyExists'
            Write-Line "[exists]  The machine '$($item.Name)' is already there, nothing changed."
            $existingSize = [string](Get-JsonValue $existing 'hardwareProfile.vmSize')
            if ($existingSize -and $existingSize -ne $item.Size) {
                $row.Detail = "Differs from the file (the size is $existingSize, the file says $($item.Size)); left unchanged."
                Write-Warning "$($item.Name): $($row.Detail)"
            }
        }
        elseif ($PSCmdlet.ShouldProcess("virtual machine '$($item.Name)' in '$($item.Group)'", "Create ($($item.Size), $($item.Os), $($item.PrivateIp) in $($item.Subnet))")) {
            # The password is read and checked first, so that a password az.cmd cannot carry (AzlExit 2: exit code 2) leaves no network interface behind.
            try { $password = Get-SecretText $item.Reference }
            catch {
                if ($_.Exception.Data['AzlExit'] -eq 2) { Exit-InputProblem "$($item.Name): $($_.Exception.Message)" }
                throw
            }
            $vnet = Get-AzCliResource network vnet show --name $item.Network --resource-group $item.NetworkGroup --subscription $item.SubscriptionId
            if (-not $vnet) { throw "The virtual network '$($item.Network)' does not exist in '$($item.NetworkGroup)'. Create it first (Deploy-VirtualNetworks.ps1)." }
            $subnet = @(Get-JsonValue $vnet 'subnets') | Where-Object { $_ -and $_.name -eq $item.Subnet } | Select-Object -First 1
            if (-not $subnet) { throw "The virtual network '$($item.Network)' has no subnet named '$($item.Subnet)'." }

            $nicName = "$($item.Name)-nic"
            $nic = Get-AzCliResource network nic show --name $nicName --resource-group $item.Group --subscription $item.SubscriptionId
            if (-not $nic) {
                $nicArgs = @('network', 'nic', 'create', '--name', $nicName, '--resource-group', $item.Group, '--location', $item.Location, '--subscription', $item.SubscriptionId, '--subnet', [string](Get-JsonValue $subnet 'id'), '--private-ip-address', $item.PrivateIp)
                $nicArgs += @(Get-TagArgument)
                $null = Invoke-AzJson @nicArgs
                Write-Line "[created] Network interface '$nicName' ($($item.PrivateIp))."
            }
            else { Write-Line "[exists]  Network interface '$nicName' is reused." }

            $image = $OsImage[$item.Os]
            $vmArgs = @('vm', 'create', '--name', $item.Name, '--resource-group', $item.Group, '--location', $item.Location, '--subscription', $item.SubscriptionId,
                '--nics', $nicName, '--image', ('{0}:{1}:{2}:{3}' -f $image.Publisher, $image.Offer, $image.Sku, $ImageVersion), '--size', $item.Size,
                '--computer-name', $item.HostName, '--os-disk-name', "$($item.Name)-osdisk", '--admin-username', $item.User, '--admin-password', $password)
            # A Linux machine signs in with the password too (the file has no key for an SSH key).
            if (-not $image.Windows) { $vmArgs += '--authentication-type'; $vmArgs += 'password' }
            $vmArgs += @(Get-TagArgument)
            try { $null = Invoke-AzJson @vmArgs }
            catch { throw ([string]$_.Exception.Message).Replace($password, '<password>') }
            finally { $password = $null; $vmArgs = $null }
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

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
