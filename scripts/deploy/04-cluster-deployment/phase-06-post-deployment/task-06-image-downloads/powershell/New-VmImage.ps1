<#
.SYNOPSIS
    Downloads the Azure Marketplace images that storage.vm_images of infrastructure.yml lists to Azure Local, as Azure Local VM images.

.DESCRIPTION
    Phase 06 (post-deployment), Task 06 (image downloads). An Azure Local VM image is the Azure resource that holds an operating system image the
    instance creates virtual machines from (Microsoft Learn, Create Azure Local VM image using Azure Marketplace images). For every entry of
    storage.vm_images the script creates the image in azure.resource_group, on the custom location of the instance (azure.custom_location), in
    azure.location, with the file-level tags, with New-AzStackHCIVMImage (the Marketplace parameter set: OSType, Publisher, Offer, Sku, Version).
    When the entry names a storage_path, the image is kept on that storage path (one of storage.paths, created by New-StoragePath.ps1, task 05);
    otherwise Azure Local chooses a storage path.

    The images are created one after the other. The cmdlet waits until the image is downloaded, which can take a long time for a large image.
    Nothing runs in parallel, because Microsoft Learn documents no setting for it.

    Version. latest (the default) lets Azure take the newest version of the Marketplace image when the image is created. The script reports the
    version it got in the Version column. It never writes that version, or anything else, to the infrastructure file: pin the version in
    storage.vm_images[].version yourself when you need to.

    Idempotent. An image that exists is reported as AlreadyExists and left alone, also when the file now asks for another version or SKU (the
    difference is reported; a newer Marketplace image is a new image with a new name). An image that is still downloading is reported as
    InProgress. An image that failed is reported as Failed with the error Azure gives, and is NOT deleted or recreated: read the error, delete the
    image yourself (portal or az stack-hci-vm image delete), then run the script again. -WhatIf reads Azure and changes nothing.

    Sources. Only Azure Marketplace images are supported. Images from a local path, a storage account, an existing virtual machine or an Azure
    compute gallery are not: each needs a prepared image and further choices (Hyper-V generation, cloud-init data source) that the file does not
    describe.

    Prerequisites, from Microsoft Learn: the Microsoft.EdgeMarketplace resource provider is registered in the subscription (the script checks this,
    read only), and the Azure Connected Machine Resource Manager role is assigned to the Microsoft.AzureStackHCI resource provider app on the
    resource group (the script does not check this).

    The script reads Azure (read only) and writes only with New-AzStackHCIVMImage, behind -WhatIf. It does not sign in: run Connect-AzAccount to
    the tenant in azure.tenant_id first. The Az context is put back when the script ends.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location, azure.custom_location, tags
        storage.paths[]: name
        storage.vm_images[]: name, os_type, publisher, offer, sku, version, storage_path

    Exit codes: 0 every image exists (created now, already there, still downloading, planned under -WhatIf) or the file lists none; 1 an Azure call
    failed or a precondition failed (not signed in, wrong tenant, Az module missing, provider not registered, a creation failed, an image is in
    the Failed state); 2 a value in the file is missing or not usable. On exit code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-VmImage.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which images would be downloaded, and downloads nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./New-VmImage.ps1 -InfrastructureFile ./infrastructure.yml

    Downloads the images that are missing. Run it again: they are reported as AlreadyExists.
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
# Az.StackHCIVM, New-AzStackHCIVMImage -Name: 1 to 80 characters; starts and ends with a letter or digit; letters, digits, hyphen, period and underscore.
$ImageName = '^[A-Za-z0-9]([A-Za-z0-9._-]{0,78}[A-Za-z0-9])?$'
$MarketplaceIdentifier = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
$VersionPattern = '^(latest|[0-9]+(\.[0-9]+){1,3})$'
# Microsoft Learn, Create Azure Local VM image using Azure Marketplace images: if the version is left empty, it is the latest.
$DefaultVersion = 'latest'
$Provider = 'Microsoft.EdgeMarketplace'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Field($Map, [string]$Key, $Default = $null) {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key] -and "$($Map[$Key])" -ne '') { return $Map[$Key] }
    $Default
}
function Get-Property($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    $null
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$imageList = @(@(Get-Field $storage 'vm_images' @()) | Where-Object { $null -ne $_ })
if ($imageList.Count -eq 0) {
    Write-Line 'The file lists no storage.vm_images: nothing to do.'
    exit 0
}
$pathNames = @(@(Get-Field $storage 'paths' @()) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { ([string](Get-Field $_ 'name' '')).Trim().ToLowerInvariant() })

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
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The images are created there.' }
if (-not $location) { Exit-InputProblem 'azure.location is missing.' }
if (-not $customLocation) { Exit-InputProblem 'azure.custom_location is missing. It is the custom location of the Azure Local instance.' }
$customLocationId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ExtendedLocation/customLocations/$customLocation"

$plans = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($entry in $imageList) {
    $index++
    $at = "storage.vm_images[$index]"
    if ($entry -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not an image (a map with name, os_type, publisher, offer and sku)." }
    $name = ([string](Get-Field $entry 'name' '')).Trim()
    if ($name -notmatch $ImageName) { Exit-InputProblem "$at.name '$name' is not a valid image name: 1 to 80 letters, digits, hyphen, period or underscore, starting and ending with a letter or digit." }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seen[$name.ToLowerInvariant()] = $true

    $osType = ([string](Get-Field $entry 'os_type' '')).Trim()
    $osName = switch ($osType.ToLowerInvariant()) { 'windows' { 'Windows' } 'linux' { 'Linux' } default { '' } }
    if (-not $osName) { Exit-InputProblem "$at.os_type must be Windows or Linux; found '$osType'." }
    $values = @{}
    foreach ($key in 'publisher', 'offer', 'sku') {
        $value = ([string](Get-Field $entry $key '')).Trim()
        if ($value -notmatch $MarketplaceIdentifier) { Exit-InputProblem "$at.$key '$value' is missing or has characters a Marketplace identifier does not have (letters, digits, hyphen, period, underscore)." }
        $values[$key] = $value
    }
    $version = ([string](Get-Field $entry 'version' $DefaultVersion)).Trim()
    if ($version -notmatch $VersionPattern) { Exit-InputProblem "$at.version '$version' must be latest or a version such as 26100.4652.250808." }
    $storagePath = ([string](Get-Field $entry 'storage_path' '')).Trim()
    if ($storagePath -and $pathNames -notcontains $storagePath.ToLowerInvariant()) { Exit-InputProblem "$at.storage_path '$storagePath' is not in storage.paths[]. List the storage path there and create it first with New-StoragePath.ps1 (task 05)." }

    $plans.Add([pscustomobject]@{ Name = $name; OsType = $osName; Publisher = $values.publisher; Offer = $values.offer; Sku = $values.sku; Version = $version; StoragePath = $storagePath })
}

# ---- preconditions (read only)
$needed = 'Get-AzContext', 'Set-AzContext', 'Get-AzStackHCIVMImage', 'New-AzStackHCIVMImage', 'Get-AzResourceProvider'
if (@($plans | Where-Object StoragePath).Count -gt 0) { $needed += 'Get-AzStackHCIVMStoragePath' }
foreach ($cmd in $needed) {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts, Az.Resources and Az.StackHCIVM modules: Install-Module Az.Accounts, Az.Resources, Az.StackHCIVM -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Image, [string]$Action, [string]$Version = '', [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Image = $Image; Action = $Action; Version = $Version; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]   ' } 'AlreadyExists' { '[exists]   ' } 'InProgress' { '[running]  ' } { $_ -like 'Would*' } { '[plan]     ' } default { '[created]  ' } }
    Write-Line ("{0}'{1}'{2}{3}" -f $tag, $Image, $(if ($Version) { " version $Version" } else { '' }), $(if ($Detail) { " ($Detail)" } else { '' }))
}
# The state Azure reports for an image: Succeeded, Failed, or something that means it is still going.
function Get-ImageState($Image) {
    foreach ($property in 'ProvisioningStatus', 'ProvisioningState') {
        $value = [string](Get-Property $Image $property)
        if ($value) { return $value }
    }
    ''
}
function Get-ImageError($Image) {
    $parts = @('StatusErrorCode', 'StatusErrorMessage') | ForEach-Object { [string](Get-Property $Image $_) } | Where-Object { $_ }
    if ($parts) { $parts -join ': ' } else { 'Azure gave no error text.' }
}

$fatal = ''
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    $registered = @(Get-AzResourceProvider -ProviderNamespace $Provider -ErrorAction Stop | Where-Object { [string](Get-Property $_ 'RegistrationState') -eq 'Registered' })
    if (-not $registered) {
        $fatal = "The resource provider $Provider is not registered in subscription $subscriptionId. Register it (Register-AzResourceProvider -ProviderNamespace $Provider), wait until it shows Registered, then run the script again. Microsoft Learn lists this as a prerequisite for Marketplace images."
    }
    else {
        Write-Line "VM images in '$group' ($location), custom location '$customLocation'"
        foreach ($plan in $plans) {
            try {
                $existing = $null
                try { $existing = Get-AzStackHCIVMImage -Name $plan.Name -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
                catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

                if ($existing) {
                    $state = Get-ImageState $existing
                    $haveVersion = [string](Get-Property $existing 'VersionName')
                    if ($state -in 'Failed', 'Canceled') {
                        Add-Row $plan.Name 'Failed' $haveVersion "The image is in the $state state: $(Get-ImageError $existing) It is left in place. Delete it (portal or az stack-hci-vm image delete) after you read the error, then run the script again."
                        continue
                    }
                    if ($state -and $state -ne 'Succeeded') {
                        $percent = [string](Get-Property $existing 'StatusProgressPercentage')
                        Add-Row $plan.Name 'InProgress' $haveVersion "state $state$(if ($percent) { ", $percent percent" }); run the script again later to see the result"
                        continue
                    }
                    $differences = [System.Collections.Generic.List[string]]::new()
                    foreach ($pair in @(@{ Property = 'IdentifierPublisher'; Want = $plan.Publisher; Label = 'publisher' }, @{ Property = 'IdentifierOffer'; Want = $plan.Offer; Label = 'offer' }, @{ Property = 'IdentifierSku'; Want = $plan.Sku; Label = 'sku' }, @{ Property = 'OSType'; Want = $plan.OsType; Label = 'os_type' })) {
                        $got = [string](Get-Property $existing $pair.Property)
                        if ($got -and $got -ne $pair.Want) { $differences.Add("$($pair.Label) is $got") }
                    }
                    if ($plan.Version -ne 'latest' -and $haveVersion -and $haveVersion -ne $plan.Version) { $differences.Add("version is $haveVersion") }
                    $note = if ($differences.Count) { "differs from the file ($($differences -join '; ')); left unchanged. A newer Marketplace image is a new image: use another name." } else { '' }
                    Add-Row $plan.Name 'AlreadyExists' $haveVersion $note
                    continue
                }

                if ($plan.StoragePath) {
                    $path = $null
                    try { $path = Get-AzStackHCIVMStoragePath -Name $plan.StoragePath -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
                    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
                    if (-not $path) { throw "The storage path '$($plan.StoragePath)' does not exist in '$group'. Run New-StoragePath.ps1 (task 05) first." }
                }

                $summary = "$($plan.OsType) $($plan.Publisher):$($plan.Offer):$($plan.Sku), version $($plan.Version)$(if ($plan.StoragePath) { ", storage path $($plan.StoragePath)" })"
                if ($PSCmdlet.ShouldProcess("VM image '$($plan.Name)' in '$group'", "Download ($summary)")) {
                    $arguments = @{
                        Name = $plan.Name; ResourceGroupName = $group; SubscriptionId = $subscriptionId; Location = $location; CustomLocationId = $customLocationId
                        OSType = $plan.OsType; Publisher = $plan.Publisher; Offer = $plan.Offer; Sku = $plan.Sku; Version = $plan.Version; ErrorAction = 'Stop'
                    }
                    if ($plan.StoragePath) { $arguments.StoragePathName = $plan.StoragePath }
                    if ($tags.Count) { $arguments.Tag = $tags }
                    $null = New-AzStackHCIVMImage @arguments

                    # Read it back: the version Azure chose for 'latest', and the state.
                    $created = $null
                    try { $created = Get-AzStackHCIVMImage -Name $plan.Name -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop } catch { Write-Verbose "The image could not be read back: $($_.Exception.Message)" }
                    $createdState = if ($created) { Get-ImageState $created } else { '' }
                    if ($createdState -in 'Failed', 'Canceled') { Add-Row $plan.Name 'Failed' ([string](Get-Property $created 'VersionName')) "The image is in the $createdState state: $(Get-ImageError $created) It is left in place. Delete it after you read the error, then run the script again." }
                    elseif ($createdState -and $createdState -ne 'Succeeded') { Add-Row $plan.Name 'InProgress' ([string](Get-Property $created 'VersionName')) "state $createdState; run the script again later to see the result" }
                    else { Add-Row $plan.Name 'Created' $(if ($created) { [string](Get-Property $created 'VersionName') } else { '' }) $summary }
                }
                else { Add-Row $plan.Name 'WouldCreate' $plan.Version $summary }
            }
            catch { Add-Row $plan.Name 'Failed' '' $_.Exception.Message }
        }
    }
}
catch { $fatal = "The subscription $subscriptionId could not be selected or read: $($_.Exception.Message)" }
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}
if ($fatal) { Exit-Failed $fatal }

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
