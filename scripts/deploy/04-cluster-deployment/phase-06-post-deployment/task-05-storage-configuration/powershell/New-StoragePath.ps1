<#
.SYNOPSIS
    Creates the Azure Local storage paths that storage.paths of infrastructure.yml lists.

.DESCRIPTION
    Phase 06 (post-deployment), Task 05 (storage configuration), part 2. A storage path is the Azure resource that tells Azure Local where on a
    cluster shared volume the virtual machine files, images and disks go (Microsoft Learn, Create storage path for Azure Local). For every entry
    of storage.paths the script creates the storage path in azure.resource_group, on the custom location of the instance (azure.custom_location),
    in azure.location, with the file-level tags.

    The path of an entry is a folder on a cluster shared volume, for example C:\ClusterStorage\vol-workloads-01\vms. Create the volume first
    (New-StorageVolume.ps1 for Storage Spaces Direct; for a SAN, the cluster shared volume of the LUN). A path on the infrastructure volume is
    refused: Microsoft reserves that volume.

    Storage paths the deployment made (Express mode) are not touched.

    Idempotent. A storage path that exists is reported as AlreadyExists and left alone (a different folder is reported; a storage path cannot be
    moved). -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzStackHCIVMStoragePath, behind -WhatIf. It does not sign in: run
    Connect-AzAccount to the tenant in azure.tenant_id first.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location, azure.custom_location, tags
        storage.paths[]: name, path

    Exit codes: 0 every storage path exists (created now, already there, planned under -WhatIf) or the file lists none; 1 an Azure call failed or
    a precondition failed (not signed in, wrong tenant, Az module missing, a creation failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-StoragePath.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which storage paths would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./New-StoragePath.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the storage paths. Run it again: they are reported as AlreadyExists.
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
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$pathList = @(@(if ($storage -is [System.Collections.IDictionary] -and $storage.Contains('paths')) { $storage['paths'] }) | Where-Object { $null -ne $_ })
if ($pathList.Count -eq 0) {
    Write-Line 'The file lists no storage.paths: nothing to do.'
    exit 0
}

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$location = Get-Text 'azure.location'
$customLocation = Get-Text 'azure.custom_location'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The storage paths are created there.' }
if (-not $location) { Exit-InputProblem 'azure.location is missing.' }
if (-not $customLocation) { Exit-InputProblem 'azure.custom_location is missing. It is the custom location of the Azure Local instance.' }
$customLocationId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ExtendedLocation/customLocations/$customLocation"

$plans = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($entry in $pathList) {
    $index++
    $at = "storage.paths[$index]"
    if ($entry -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a storage path (a map with name and path)." }
    $name = if ($entry.Contains('name')) { ([string]$entry['name']).Trim() } else { '' }
    $folder = if ($entry.Contains('path')) { ([string]$entry['path']).Trim().TrimEnd('\') } else { '' }
    # Microsoft Learn: 3 to 64 characters; letters, numbers and hyphens.
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{1,62}[A-Za-z0-9]$') { Exit-InputProblem "$at.name '$name' is not a valid storage path name: 3 to 64 letters, digits or hyphens, starting and ending with a letter or digit." }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seen[$name.ToLowerInvariant()] = $true
    if ($folder -notmatch '^[A-Za-z]:\\ClusterStorage\\[^\\/:*?"<>|]+(\\[^\\/:*?"<>|]+)*$') { Exit-InputProblem "$at.path '$folder' is not a folder on a cluster shared volume. It looks like C:\ClusterStorage\<volume>\<folder>." }
    if ($folder -match '^[A-Za-z]:\\ClusterStorage\\Infrastructure_\d+(\\|$)') { Exit-InputProblem "$at.path is on the infrastructure volume, which Microsoft reserves for Azure Local. Use a workload volume." }
    $plans.Add([pscustomobject]@{ Name = $name; Path = $folder })
}

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzStackHCIVMStoragePath', 'New-AzStackHCIVMStoragePath') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.StackHCIVM modules: Install-Module Az.Accounts, Az.StackHCIVM -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$rows = [System.Collections.Generic.List[object]]::new()
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    Write-Line "Storage paths in '$group' ($location), custom location '$customLocation'"
    foreach ($plan in $plans) {
        $row = [ordered]@{ StoragePath = $plan.Name; Action = ''; Path = $plan.Path; Detail = '' }
        try {
            $existing = $null
            try { $existing = Get-AzStackHCIVMStoragePath -Name $plan.Name -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

            if ($existing) {
                $row.Action = 'AlreadyExists'
                Write-Line "[exists]  '$($plan.Name)' is already there, nothing changed."
                $existingPath = if ($existing.PSObject.Properties['Path'] -and $existing.Path) { ([string]$existing.Path).TrimEnd('\') } else { '' }
                if ($existingPath -and $existingPath -ne $plan.Path) {
                    $row.Detail = "Differs from the file (the storage path points to $existingPath); left unchanged. A storage path cannot be moved: create one with another name."
                    Write-Warning "$($plan.Name): $($row.Detail)"
                }
            }
            elseif ($PSCmdlet.ShouldProcess("storage path '$($plan.Name)' in '$group'", "Create ($($plan.Path))")) {
                $arguments = @{ Name = $plan.Name; ResourceGroupName = $group; SubscriptionId = $subscriptionId; Location = $location; CustomLocationId = $customLocationId; Path = $plan.Path; ErrorAction = 'Stop' }
                if ($tags.Count) { $arguments.Tag = $tags }
                $null = New-AzStackHCIVMStoragePath @arguments
                $row.Action = 'Created'
                Write-Line "[created] '$($plan.Name)' ($($plan.Path))."
            }
            else {
                $row.Action = 'WouldCreate'
                Write-Line "[plan]    '$($plan.Name)' would be created ($($plan.Path))."
            }
        }
        catch {
            $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
            Write-Warning "$($plan.Name): $($row.Detail)"
        }
        $rows.Add([pscustomobject]$row)
    }
}
catch { Exit-Failed "The subscription $subscriptionId could not be selected: $($_.Exception.Message)" }
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
