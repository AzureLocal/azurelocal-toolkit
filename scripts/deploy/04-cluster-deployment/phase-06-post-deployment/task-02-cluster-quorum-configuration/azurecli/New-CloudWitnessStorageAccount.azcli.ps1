<#
.SYNOPSIS
    Creates, or checks, the Azure storage account of the cloud witness that cluster.witness of infrastructure.yml names, with the Azure CLI.

.DESCRIPTION
    Phase 06 (post-deployment), Task 02 (cluster quorum configuration). The Azure side of a cloud witness. When cluster.witness.type is cloud, the
    quorum witness of the instance is a blob in an Azure storage account (Microsoft Learn, Deploy a quorum witness (cloud-witness), and Understanding
    cluster and pool quorum). The Azure Local deployment creates that account from the ARM parameter clusterWitnessStorageAccountName; this script is
    for a witness that is added or replaced after the deployment, or whose account was removed.

    What it does, for the account cluster.witness.storage_account in azure.resource_group:
      * The account exists: it is checked, never changed. Learn: a cloud witness supports only an Azure Standard general-purpose v2 account with
        locally redundant storage, so an account of another kind or SKU is reported as Failed (nothing is changed).
      * The account does not exist: the script checks that the name is free in Azure, then creates it in azure.location with az storage account
        create, kind StorageV2, SKU Standard_LRS and the file-level tags, behind -WhatIf.
    The script never reads, prints or stores an access key. Pointing the cluster at the account (Set-ClusterQuorum -CloudWitness -AccountName <name>
    -AccessKey <key>) runs on a node and is not an Azure CLI task; the nodes must reach the account on TCP 443.

    cluster.witness.type none or file_share is not an Azure task: the script says so and ends with exit code 0.

    The script does not sign in: run az login --tenant <azure.tenant_id> first. It does not change the Azure CLI default subscription: every call
    carries --subscription. The signed-in account needs Storage Account Contributor (or Contributor) on the resource group.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location, tags
        cluster.witness.type, cluster.witness.storage_account

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 the account exists, was created, is planned under -WhatIf, or the witness is not a cloud witness; 1 a call or a precondition failed
    (az missing, not signed in, wrong tenant, the name is taken, the account has the wrong kind or SKU, the creation failed); 2 a value in the file is
    missing or not usable. On exit code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-CloudWitnessStorageAccount.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the storage account would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-CloudWitnessStorageAccount.azcli.ps1 -InfrastructureFile ./infrastructure.yml
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
# Microsoft Learn, Deploy a quorum witness (cloud-witness): only an Azure Standard general-purpose v2 storage account is supported, with locally redundant
# storage when the cluster is on premises. Azure storage account names: 3 to 24 characters, lowercase letters and digits.
$WitnessKind = 'StorageV2'
$WitnessSku = 'Standard_LRS'
$StorageAccountNamePattern = '^[a-z0-9]{3,24}$'

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

$witnessType = (Get-Text 'cluster.witness.type').ToLowerInvariant()
if ($witnessType -notin 'cloud', 'file_share', 'none') { Exit-InputProblem "cluster.witness.type must be cloud, file_share or none; found '$witnessType'." }
if ($witnessType -ne 'cloud') {
    Write-Line "cluster.witness.type is '$witnessType': there is no Azure storage account to create. Nothing to do."
    exit 0
}

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$location = Get-Text 'azure.location'
$accountName = Get-Text 'cluster.witness.storage_account'
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
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The storage account is created there.' }
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group }); if ($problem) { Exit-InputProblem $problem }
if (-not $location) { Exit-InputProblem 'azure.location is missing.' }
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.location' = $location }); if ($problem) { Exit-InputProblem $problem }
if ($accountName -notmatch $StorageAccountNamePattern) { Exit-InputProblem "cluster.witness.storage_account '$accountName' is missing or is not a valid storage account name (3 to 24 lowercase letters and digits)." }

# ---- preconditions (read only)
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>.' }
$account = Invoke-AzCli @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors')
if ($account.ExitCode -ne 0) { Exit-Failed "Not signed in to the Azure CLI for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($account.Detail)" }
$accountInfo = ConvertFrom-AzJson $account.Output
if ([string](Get-Prop $accountInfo @('tenantId')) -ne $tenantId) { Exit-Failed "The Azure CLI is signed in to tenant $(Get-Prop $accountInfo @('tenantId')), but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } 'AlreadyExists' { '[exists]  ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[created] ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Item, $(if ($Detail) { " ($Detail)" } else { '' }))
}
$item = "cloud witness storage account $accountName"
$common = @('--subscription', $subscriptionId, '--resource-group', $group)

try {
    $show = Invoke-AzCli (@('storage', 'account', 'show') + $common + @('--name', $accountName, '--output', 'json', '--only-show-errors'))
    if ($show.ExitCode -eq 0) {
        $have = ConvertFrom-AzJson $show.Output
        $haveKind = [string](Get-Prop $have @('kind'))
        $haveSku = [string](Get-Prop $have @('sku', 'name'))
        if (($haveKind -and $haveKind -ne $WitnessKind) -or ($haveSku -and $haveSku -ne $WitnessSku)) {
            Add-Row $item 'Failed' "the account is kind '$haveKind' with SKU '$haveSku'. A cloud witness supports only $WitnessKind (Standard general purpose v2) with $WitnessSku (Microsoft Learn). Nothing was changed: use another account name in cluster.witness.storage_account."
        }
        else { Add-Row $item 'AlreadyExists' "$haveKind, $haveSku; nothing changed" }
    }
    elseif ($show.Detail -notmatch $NotFound) { throw "The lookup failed: $($show.Detail)" }
    else {
        # Not in the resource group: is the name free in Azure at all? (A name is unique across Azure.)
        $name = Invoke-AzCli @('storage', 'account', 'check-name', '--subscription', $subscriptionId, '--name', $accountName, '--query', 'nameAvailable', '--output', 'tsv', '--only-show-errors')
        if ($name.ExitCode -ne 0) { throw "The name check failed: $($name.Detail)" }
        if ($name.Output.Trim() -ne 'true') { throw "The storage account name '$accountName' is taken in Azure (in another resource group or subscription). Use another name in cluster.witness.storage_account." }
        if ($PSCmdlet.ShouldProcess("storage account '$accountName' in '$group'", "Create ($WitnessKind, $WitnessSku, $location)")) {
            $arguments = @('storage', 'account', 'create') + $common + @('--name', $accountName, '--location', $location, '--kind', $WitnessKind, '--sku', $WitnessSku)
            if ($tagArguments.Count) { $arguments += @('--tags') + $tagArguments }
            $result = Invoke-AzCli ($arguments + @('--output', 'none', '--only-show-errors'))
            if ($result.ExitCode -ne 0) { throw "The creation failed: $($result.Detail)" }
            Add-Row $item 'Created' "$WitnessKind, $WitnessSku, $location"
        }
        else { Add-Row $item 'WouldCreate' "$WitnessKind, $WitnessSku, $location" }
    }
}
catch { Add-Row $item 'Failed' $_.Exception.Message }

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
