<#
.SYNOPSIS
    Downloads the Azure Marketplace images that storage.vm_images of infrastructure.yml lists to Azure Local, as Azure Local VM images, with the Azure CLI.

.DESCRIPTION
    Phase 06 (post-deployment), Task 06 (image downloads). Azure CLI variant of New-VmImage.ps1: the same keys, the same checks and the same exit
    codes, with az stack-hci-vm image instead of the Az.StackHCIVM module. An Azure Local VM image is the Azure resource that holds an operating
    system image the instance creates virtual machines from (Microsoft Learn, Create Azure Local VM image using Azure Marketplace images). For every
    entry of storage.vm_images the script creates the image in azure.resource_group, on the custom location of the instance (azure.custom_location),
    in azure.location, with the file-level tags, with az stack-hci-vm image create (offer, publisher, sku, version). When the entry names a
    storage_path, the image is kept on that storage path (one of storage.paths, created by New-StoragePath.azcli.ps1 or New-StoragePath.ps1, task 05);
    otherwise Azure Local chooses a storage path.

    The images are created one after the other. The command waits until the image is downloaded, which can take a long time for a large image.
    Nothing runs in parallel, because Microsoft Learn documents no setting for it.

    Version. latest (the default) lets Azure take the newest version of the Marketplace image when the image is created. The script reports the
    version it got in the Detail column. It never writes that version, or anything else, to the infrastructure file: pin the version in
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

    The script needs the Azure CLI with the stack-hci-vm extension (az extension add --name stack-hci-vm); it does not install it and does not sign
    in: run az login --tenant <azure.tenant_id> first. It does not change the Azure CLI default subscription: every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location, azure.custom_location, tags
        storage.paths[]: name
        storage.vm_images[]: name, os_type, publisher, offer, sku, version, storage_path

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every image exists (created now, already there, still downloading, planned under -WhatIf) or the file lists none; 1 a call or a
    precondition failed (az missing, not signed in, wrong tenant, extension missing, provider not registered, a creation failed, an image is in the
    Failed state); 2 a value in the file is missing or not usable. On exit code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-VmImage.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which images would be downloaded, and downloads nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-VmImage.azcli.ps1 -InfrastructureFile ./infrastructure.yml

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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

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
function Get-Prop($Object, [string[]]$Path) {
    $node = $Object
    foreach ($part in $Path) {
        if ($null -eq $node) { return $null }
        if ($node -is [System.Collections.IDictionary]) { if ($node.Contains($part)) { $node = $node[$part] } else { return $null } }
        elseif ($node.PSObject.Properties[$part]) { $node = $node.PSObject.Properties[$part].Value }
        else { return $null }
    }
    $node
}

# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the exit code, stdout and stderr.
function Invoke-AzCli([string[]]$Arguments) {
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $Arguments
    if ($unsafe) { Exit-InputProblem $unsafe }
    $all = @(& az @Arguments 2>&1)
    $code = [int](Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err; Detail = $(if ($err) { $err.Trim() } else { $out.Trim() }) }
}
function ConvertFrom-AzJson([string]$Text) { if ($Text -and $Text.Trim()) { $Text | ConvertFrom-Json -Depth 20 } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$imageList = @(@(Get-Field $storage 'vm_images' @()) | Where-Object { $null -ne $_ })
if ($imageList.Count -eq 0) {
    Write-Line 'The file lists no storage.vm_images: nothing to do.'
    exit 0
}
$pathNames = @(@(Get-Field $storage 'paths' @()) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne (Get-Field $storage 'paths' @())) { Exit-InputProblem 'An entry of storage.paths is not a map (names with their settings).' } } | ForEach-Object { ([string](Get-Field $_ 'name' '')).Trim().ToLowerInvariant() })

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$location = Get-Text 'azure.location'
$customLocation = Get-Text 'azure.custom_location'
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tagArguments = @()
if ($rawTags -is [System.Collections.IDictionary]) {
    foreach ($k in $rawTags.Keys) {
        if ($null -eq $rawTags[$k]) { continue }
        $pair = "$k=$($rawTags[$k])"
        $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "tags.$k" = $pair }); if ($problem) { Exit-InputProblem $problem }
        $tagArguments += $pair
    }
}

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
    if ($storagePath -and $pathNames -notcontains $storagePath.ToLowerInvariant()) { Exit-InputProblem "$at.storage_path '$storagePath' is not in storage.paths[]. List the storage path there and create it first with New-StoragePath.azcli.ps1 (task 05)." }

    $plans.Add([pscustomobject]@{ Name = $name; OsType = $osName; Publisher = $values.publisher; Offer = $values.offer; Sku = $values.sku; Version = $version; StoragePath = $storagePath })
}

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A value that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group; 'azure.location' = $location; 'azure.custom_location' = $customLocation; 'storage.vm_images storage_path' = @($plans | ForEach-Object { $_.StoragePath }) })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>. Or use New-VmImage.ps1.' }
$account = Invoke-AzCli @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors')
if ($account.ExitCode -ne 0) { Exit-Failed "Not signed in to the Azure CLI for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($account.Detail)" }
$accountInfo = ConvertFrom-AzJson $account.Output
if ([string](Get-Prop $accountInfo @('tenantId')) -ne $tenantId) { Exit-Failed "The Azure CLI is signed in to tenant $(Get-Prop $accountInfo @('tenantId')), but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }
$extension = Invoke-AzCli @('extension', 'show', '--name', 'stack-hci-vm', '--output', 'json', '--only-show-errors')
if ($extension.ExitCode -ne 0) { Exit-Failed 'The Azure CLI extension stack-hci-vm is not installed. This script does not install it. Run: az extension add --name stack-hci-vm' }
$providerState = Invoke-AzCli @('provider', 'show', '--namespace', $Provider, '--subscription', $subscriptionId, '--query', 'registrationState', '--output', 'tsv', '--only-show-errors')
if ($providerState.ExitCode -ne 0) { Exit-Failed "The state of the resource provider $Provider could not be read: $($providerState.Detail)" }
if ($providerState.Output.Trim() -ne 'Registered') {
    Exit-Failed "The resource provider $Provider is not registered in subscription $subscriptionId. Register it (az provider register --namespace $Provider), wait until it shows Registered, then run the script again. Microsoft Learn lists this as a prerequisite for Marketplace images."
}

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Image, [string]$Action, [string]$Version = '', [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Image = $Image; Action = $Action; Version = $Version; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]   ' } 'AlreadyExists' { '[exists]   ' } 'InProgress' { '[running]  ' } { $_ -like 'Would*' } { '[plan]     ' } default { '[created]  ' } }
    Write-Line ("{0}'{1}'{2}{3}" -f $tag, $Image, $(if ($Version) { " version $Version" } else { '' }), $(if ($Detail) { " ($Detail)" } else { '' }))
}
# The state Azure reports for an image: Succeeded, Failed, or something that means it is still going.
function Get-ImageState($Image) {
    foreach ($path in @('properties', 'status', 'provisioningStatus', 'status'), @('properties', 'provisioningState')) {
        $value = [string](Get-Prop $Image $path)
        if ($value) { return $value }
    }
    ''
}
function Get-ImageError($Image) {
    $parts = @('errorCode', 'errorMessage') | ForEach-Object { [string](Get-Prop $Image @('properties', 'status', $_)) } | Where-Object { $_ }
    if ($parts) { $parts -join ': ' } else { 'Azure gave no error text.' }
}
function Read-Image([string]$Name) {
    $show = Invoke-AzCli (@('stack-hci-vm', 'image', 'show', '--subscription', $subscriptionId, '--resource-group', $group, '--name', $Name, '--output', 'json', '--only-show-errors'))
    if ($show.ExitCode -eq 0) { return (ConvertFrom-AzJson $show.Output) }
    if ($show.Detail -match $NotFound) { return $null }
    throw "The lookup failed: $($show.Detail)"
}

Write-Line "VM images in '$group' ($location), custom location '$customLocation'"
foreach ($plan in $plans) {
    try {
        $existing = Read-Image $plan.Name
        if ($existing) {
            $state = Get-ImageState $existing
            $haveVersion = [string](Get-Prop $existing @('properties', 'version', 'name'))
            if ($state -in 'Failed', 'Canceled') {
                Add-Row $plan.Name 'Failed' $haveVersion "The image is in the $state state: $(Get-ImageError $existing) It is left in place. Delete it (portal or az stack-hci-vm image delete) after you read the error, then run the script again."
                continue
            }
            if ($state -and $state -ne 'Succeeded') {
                $percent = [string](Get-Prop $existing @('properties', 'status', 'progressPercentage'))
                Add-Row $plan.Name 'InProgress' $haveVersion "state $state$(if ($percent) { ", $percent percent" }); run the script again later to see the result"
                continue
            }
            $differences = [System.Collections.Generic.List[string]]::new()
            foreach ($pair in @(@{ Path = @('properties', 'identifier', 'publisher'); Want = $plan.Publisher; Label = 'publisher' }, @{ Path = @('properties', 'identifier', 'offer'); Want = $plan.Offer; Label = 'offer' }, @{ Path = @('properties', 'identifier', 'sku'); Want = $plan.Sku; Label = 'sku' }, @{ Path = @('properties', 'osType'); Want = $plan.OsType; Label = 'os_type' })) {
                $got = [string](Get-Prop $existing $pair.Path)
                if ($got -and $got -ne $pair.Want) { $differences.Add("$($pair.Label) is $got") }
            }
            if ($plan.Version -ne 'latest' -and $haveVersion -and $haveVersion -ne $plan.Version) { $differences.Add("version is $haveVersion") }
            $note = if ($differences.Count) { "differs from the file ($($differences -join '; ')); left unchanged. A newer Marketplace image is a new image: use another name." } else { '' }
            Add-Row $plan.Name 'AlreadyExists' $haveVersion $note
            continue
        }

        $storagePathId = ''
        if ($plan.StoragePath) {
            $path = Invoke-AzCli @('stack-hci-vm', 'storagepath', 'show', '--subscription', $subscriptionId, '--resource-group', $group, '--name', $plan.StoragePath, '--output', 'json', '--only-show-errors')
            if ($path.ExitCode -ne 0) {
                if ($path.Detail -match $NotFound) { throw "The storage path '$($plan.StoragePath)' does not exist in '$group'. Run New-StoragePath.azcli.ps1 (task 05) first." }
                throw "The storage path '$($plan.StoragePath)' could not be read: $($path.Detail)"
            }
            $storagePathId = [string](Get-Prop (ConvertFrom-AzJson $path.Output) @('id'))
            if (-not $storagePathId) { throw "Azure gave no resource ID for the storage path '$($plan.StoragePath)'." }
        }

        $summary = "$($plan.OsType) $($plan.Publisher):$($plan.Offer):$($plan.Sku), version $($plan.Version)$(if ($plan.StoragePath) { ", storage path $($plan.StoragePath)" })"
        if ($PSCmdlet.ShouldProcess("VM image '$($plan.Name)' in '$group'", "Download ($summary)")) {
            $arguments = @('stack-hci-vm', 'image', 'create', '--subscription', $subscriptionId, '--resource-group', $group, '--name', $plan.Name, '--custom-location', $customLocationId, '--location', $location,
                '--os-type', $plan.OsType, '--publisher', $plan.Publisher, '--offer', $plan.Offer, '--sku', $plan.Sku, '--version', $plan.Version)
            if ($storagePathId) { $arguments += @('--storage-path-id', $storagePathId) }
            # No --tags on the create: the extension stack-hci-vm 1.15.1 hands the tag list unconverted to the marketplace image model and the
            # command ends with "SerializationError: Unable to build a model ... Data: ['k=v', ...]" before any request is sent (seen on a live
            # instance). The tags of the file are merged onto the image with az tag update once it exists.
            $result = Invoke-AzCli ($arguments + @('--output', 'none', '--only-show-errors'))
            if ($result.ExitCode -ne 0) { throw "The creation failed: $($result.Detail)" }
            if ($tagArguments.Count) {
                $imageId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.AzureStackHCI/marketplaceGalleryImages/$($plan.Name)"
                $tagged = Invoke-AzCli (@('tag', 'update', '--resource-id', $imageId, '--operation', 'Merge', '--tags') + $tagArguments + @('--output', 'none', '--only-show-errors'))
                if ($tagged.ExitCode -ne 0) { Write-Warning "The image '$($plan.Name)' was created, but its tags could not be set: $($tagged.Detail)" }
            }

            # Read it back: the version Azure chose for 'latest', and the state.
            $created = $null
            try { $created = Read-Image $plan.Name } catch { Write-Verbose "The image could not be read back: $($_.Exception.Message)" }
            $createdState = if ($created) { Get-ImageState $created } else { '' }
            $createdVersion = if ($created) { [string](Get-Prop $created @('properties', 'version', 'name')) } else { '' }
            if ($createdState -in 'Failed', 'Canceled') { Add-Row $plan.Name 'Failed' $createdVersion "The image is in the $createdState state: $(Get-ImageError $created) It is left in place. Delete it after you read the error, then run the script again." }
            elseif ($createdState -and $createdState -ne 'Succeeded') { Add-Row $plan.Name 'InProgress' $createdVersion "state $createdState; run the script again later to see the result" }
            else { Add-Row $plan.Name 'Created' $createdVersion $summary }
        }
        else { Add-Row $plan.Name 'WouldCreate' $plan.Version $summary }
    }
    catch { Add-Row $plan.Name 'Failed' '' $_.Exception.Message }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
