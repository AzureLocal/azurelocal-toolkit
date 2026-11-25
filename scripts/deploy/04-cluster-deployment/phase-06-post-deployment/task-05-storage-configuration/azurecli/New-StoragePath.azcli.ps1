<#
.SYNOPSIS
    Creates the Azure Local storage paths that storage.paths of infrastructure.yml lists, with the Azure CLI.

.DESCRIPTION
    Phase 06 (post-deployment), Task 05 (storage configuration), part 2. Azure CLI variant of New-StoragePath.ps1: the same keys, the same checks and
    the same exit codes, with az stack-hci-vm storagepath instead of the Az.StackHCIVM module. A storage path is the Azure resource that tells Azure
    Local where on a cluster shared volume the virtual machine files, images and disks go (Microsoft Learn, Create storage path for Azure Local). For
    every entry of storage.paths the script creates the storage path in azure.resource_group, on the custom location of the instance
    (azure.custom_location), in azure.location, with the file-level tags.

    The path of an entry is a folder on a cluster shared volume, for example C:\ClusterStorage\vol-workloads-01\vms. The script does not touch the
    cluster: create the volume first (New-StorageVolume.ps1 for Storage Spaces Direct; for a SAN, the cluster shared volume of the LUN). A path on
    the infrastructure volume is refused: Microsoft reserves that volume. Storage paths the deployment made (Express mode) are not touched.

    Idempotent. A storage path that exists is reported as AlreadyExists and left alone (a different folder is reported; a storage path cannot be
    moved). -WhatIf reads Azure and changes nothing.

    The script needs the Azure CLI with the stack-hci-vm extension (az extension add --name stack-hci-vm); it does not install it and does not sign
    in: run az login --tenant <azure.tenant_id> first. It does not change the Azure CLI default subscription: every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location, azure.custom_location, tags
        storage.paths[]: name, path

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every storage path exists (created now, already there, planned under -WhatIf) or the file lists none; 1 a call or a precondition
    failed (az missing, not signed in, wrong tenant, extension missing, a creation failed); 2 a value in the file is missing or not usable. On exit
    code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-StoragePath.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which storage paths would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-StoragePath.azcli.ps1 -InfrastructureFile ./infrastructure.yml

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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
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

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A value that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group; 'azure.location' = $location; 'azure.custom_location' = $customLocation; 'storage.paths path' = @($plans | ForEach-Object { $_.Path }) })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>. Or use New-StoragePath.ps1.' }
$account = Invoke-AzCli @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors')
if ($account.ExitCode -ne 0) { Exit-Failed "Not signed in to the Azure CLI for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($account.Detail)" }
$accountInfo = ConvertFrom-AzJson $account.Output
if ([string](Get-Prop $accountInfo @('tenantId')) -ne $tenantId) { Exit-Failed "The Azure CLI is signed in to tenant $(Get-Prop $accountInfo @('tenantId')), but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }
$extension = Invoke-AzCli @('extension', 'show', '--name', 'stack-hci-vm', '--output', 'json', '--only-show-errors')
if ($extension.ExitCode -ne 0) { Exit-Failed 'The Azure CLI extension stack-hci-vm is not installed. This script does not install it. Run: az extension add --name stack-hci-vm' }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } 'AlreadyExists' { '[exists]  ' } 'Info' { '[info]    ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[created] ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Item, $(if ($Detail) { " ($Detail)" } else { '' }))
}
$common = @('--subscription', $subscriptionId, '--resource-group', $group)

Write-Line "Storage paths in '$group' ($location), custom location '$customLocation'"
foreach ($plan in $plans) {
    $item = "storage path $($plan.Name)"
    try {
        $show = Invoke-AzCli (@('stack-hci-vm', 'storagepath', 'show') + $common + @('--name', $plan.Name, '--output', 'json', '--only-show-errors'))
        if ($show.ExitCode -eq 0) {
            $existingPath = ([string](Get-Prop (ConvertFrom-AzJson $show.Output) @('properties', 'path'))).TrimEnd('\')
            # Azure Local keeps the files of a storage path in a folder it makes inside the folder asked for (<path>\<generated id>, seen on 2610), and reports that folder.
            $existingParent = if ($existingPath -match '\\') { $existingPath.Substring(0, $existingPath.LastIndexOf('\')) } else { '' }
            if ($existingPath -and $existingPath -ine $plan.Path -and $existingParent -ine $plan.Path) {
                Add-Row $item 'AlreadyExists' "differs from the file (the storage path points to $existingPath); left unchanged. A storage path cannot be moved: create one with another name."
            }
            else { Add-Row $item 'AlreadyExists' 'nothing changed' }
            # The validation of the guide page: provisioningState Succeeded. Failed or Canceled is a failure; a state still moving is reported.
            $existingState = [string](Get-Prop (ConvertFrom-AzJson $show.Output) @('properties', 'provisioningState'))
            if ($existingState -in 'Failed', 'Canceled') { Add-Row "$item state" 'Failed' "the storage path is in the $existingState state. Delete it (az stack-hci-vm storagepath delete) and run the script again." }
            elseif ($existingState -and $existingState -ne 'Succeeded') { Add-Row "$item state" 'Info' "$existingState, not Succeeded yet; run the script again later" }
        }
        elseif ($show.Detail -notmatch $NotFound) { throw "The lookup failed: $($show.Detail)" }
        elseif ($PSCmdlet.ShouldProcess("storage path '$($plan.Name)' in '$group'", "Create ($($plan.Path))")) {
            $arguments = @('stack-hci-vm', 'storagepath', 'create') + $common + @('--name', $plan.Name, '--custom-location', $customLocationId, '--location', $location, '--path', $plan.Path)
            if ($tagArguments.Count) { $arguments += @('--tags') + $tagArguments }
            $result = Invoke-AzCli ($arguments + @('--output', 'none', '--only-show-errors'))
            if ($result.ExitCode -ne 0) { throw "The creation failed: $($result.Detail)" }
            Add-Row $item 'Created' $plan.Path
            # The check after: read it back; it must read Succeeded (a read that fails, or a state not reported, is not judged).
            $back = Invoke-AzCli (@('stack-hci-vm', 'storagepath', 'show') + $common + @('--name', $plan.Name, '--output', 'json', '--only-show-errors'))
            $backState = if ($back.ExitCode -eq 0) { [string](Get-Prop (ConvertFrom-AzJson $back.Output) @('properties', 'provisioningState')) } else { '' }
            if ($backState -and $backState -ne 'Succeeded') { Add-Row "$item state" 'Failed' "the storage path was created but reads $backState, not Succeeded" }
        }
        else { Add-Row $item 'WouldCreate' $plan.Path }
    }
    catch { Add-Row $item 'Failed' $_.Exception.Message }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
