<#
.SYNOPSIS
    Creates the Key Vaults that infrastructure.yml lists, and checks that the secrets the file refers to are there.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 10 (Key Vault). Creates each vault of the key_vaults list in the
    subscription and resource group the entry names, in the region azure.location: a Standard vault that uses Azure RBAC for its data plane
    (no access policies), with soft delete (90 days, the Azure default) and, depending on scenario.environment_class, purge protection. Then
    it reads every keyvault://<vault>/<secret> reference in the file and reports which of those secrets exist in the vaults it manages.

    The script never writes a secret and never asks for one. A secret VALUE does not belong in the file or in a script: set it with
    Set-AzKeyVaultSecret (or the portal) as someone who holds Key Vault Secrets Officer on the vault, then run this script again to see the
    secret listed as present. A secret named by a reference that is missing is reported, not created. It does not create the vault of the
    cluster deployment (cluster.key_vault: the ARM deployment creates that one), and it does not grant any role: assign Key Vault Secrets
    User or Officer to the people and identities that need them with the role assignment task.

    Purge protection cannot be switched off once it is on, and it keeps a deleted vault's name reserved for the retention period. So it is on
    for every vault the script creates, except when scenario.environment_class is lab, test or dev, where a vault has to be removable.
    A missing scenario.environment_class means production. The vault's network access is left at the Azure default (all networks); restrict
    it with your network design after the vault exists.

    Idempotent. A vault that exists is reported as AlreadyExists and left alone (a setting that differs is reported, not changed), so a second
    run creates nothing. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzKeyVault, behind -WhatIf. It does not sign in: run Connect-AzAccount to the
    tenant in azure.tenant_id first. You need Key Vault Contributor (or Contributor) on the resource group. Listing a vault's secrets needs
    Key Vault Secrets User (or Reader of the data plane) on the vault; without it the secrets of that vault are reported as Unchecked. The tags
    in the file-level tags map are put on the vaults it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags, scenario.environment_class
        key_vaults[].name, .subscription_id, .resource_group, .purpose
        every keyvault://<vault>/<secret> reference anywhere in the file (names only; no value is read)

    Exit codes: 0 every listed vault exists (created now, already there, or planned under -WhatIf), whether or not secrets are still missing;
    1 an Azure call failed or a precondition failed (not signed in, wrong tenant, Az modules missing, a creation failed); 2 the file lists no
    vault or a value is not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-KeyVaults.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which vaults would be created and which secrets are missing, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-KeyVaults.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the vaults and lists the secrets the file refers to that still have to be set.
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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'azure-local', 'AzlAzure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'
$GroupNotFound = 'ResourceGroupNotFound|Resource group ''[^'']*'' could not be found'
$Forbidden = 'Forbidden|403|not authorized|does not have (secrets )?(list|get)|AuthorizationFailed|Unauthorized'
$RemovableClasses = 'lab', 'test', 'dev'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}

function Exit-InputProblem([string]$Message) {
    Write-Error $Message -ErrorAction Continue
    exit 2
}

function Exit-Failed([string]$Message) {
    Write-Error $Message -ErrorAction Continue
    exit 1
}

function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# Every string of the file that is a keyvault:// reference.
function Get-KeyVaultReference([object]$Node) {
    if ($Node -is [string]) { if ($Node -like 'keyvault://*') { $Node.Trim() }; return }
    if ($Node -is [System.Collections.IDictionary]) { foreach ($key in $Node.Keys) { Get-KeyVaultReference $Node[$key] }; return }
    if ($Node -is [System.Collections.IEnumerable]) { foreach ($item in $Node) { Get-KeyVaultReference $item } }
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$location = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$environmentClass = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.environment_class')
$rawVaults = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'key_vaults'
$vaultEntries = @(@($rawVaults) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($vaultEntries.Count -eq 0) { Exit-InputProblem 'key_vaults is empty. List the vaults with their name, subscription_id and resource_group.' }
if (-not $location) { Exit-InputProblem 'azure.location is missing. It is the region of the vaults.' }
$purgeProtection = $RemovableClasses -notcontains $environmentClass.Trim().ToLowerInvariant()

$plan = foreach ($entry in $vaultEntries) {
    $name = Get-Entry $entry 'name'
    if (-not $name) { Exit-InputProblem 'An entry of key_vaults has no name.' }
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$' -or $name -match '--') { Exit-InputProblem "key_vaults: '$name' is not a valid Key Vault name (3 to 24 letters, digits and hyphens; starts with a letter, ends with a letter or digit, no two hyphens in a row)." }
    $subscriptionId = Get-Entry $entry 'subscription_id'
    if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "key_vaults '$name': subscription_id is missing, not a GUID or the all-zero placeholder." }
    $group = Get-Entry $entry 'resource_group'
    if (-not $group) { Exit-InputProblem "key_vaults '$name': resource_group is missing." }
    [pscustomobject]@{ Name = $name; SubscriptionId = $subscriptionId; ResourceGroup = $group; Purpose = (Get-Entry $entry 'purpose') }
}
$plan = @($plan)
$duplicate = @($plan | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object Count -GT 1)
if ($duplicate.Count) { Exit-InputProblem "The vault '$($duplicate[0].Group[0].Name)' appears more than once in key_vaults." }

# the secrets the file refers to, by vault
$references = @(Get-KeyVaultReference $infra | Select-Object -Unique | ForEach-Object { ConvertFrom-AzlKeyVaultRef -Reference $_ } | Where-Object { $_ })

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Get-AzKeyVault', 'New-AzKeyVault', 'Get-AzKeyVaultSecret') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.KeyVault modules: Install-Module Az.Accounts, Az.KeyVault -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Key Vaults: $($plan.Count) listed, region $location, purge protection on new vaults: $(if ($purgeProtection) { 'on' } else { "off (scenario.environment_class is $($environmentClass.Trim().ToLowerInvariant()))" })"

# ---- one vault at a time
$vaultRows = foreach ($item in $plan) {
    $row = [ordered]@{ Vault = $item.Name; Action = ''; Detail = '' }
    try {
        $existing = $null
        try { $existing = Get-AzKeyVault -VaultName $item.Name -ResourceGroupName $item.ResourceGroup -SubscriptionId $item.SubscriptionId -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

        if ($existing) {
            $row.Action = 'AlreadyExists'
            Write-Line "[exists]  $($item.Name): already there, nothing changed."
            $differs = @()
            $rbac = $existing.PSObject.Properties['EnableRbacAuthorization']
            if ($rbac -and $null -ne $rbac.Value -and -not [bool]$rbac.Value) { $differs += 'it uses access policies, not Azure RBAC' }
            $soft = $existing.PSObject.Properties['EnableSoftDelete']
            if ($soft -and $null -ne $soft.Value -and -not [bool]$soft.Value) { $differs += 'soft delete is off' }
            # A vault this script would create with purge protection: say so when the existing one has none. It is never turned on here.
            $purge = $existing.PSObject.Properties['EnablePurgeProtection']
            if ($purgeProtection -and $purge -and -not [bool]$purge.Value) { $differs += 'purge protection is off' }
            if ($differs.Count) {
                $row.Detail = "Differs from what this script creates ($($differs -join '; ')); left unchanged."
                Write-Warning "$($item.Name): $($row.Detail)"
            }
        }
        elseif ($PSCmdlet.ShouldProcess("Key Vault '$($item.Name)' in '$($item.ResourceGroup)'", "Create (Standard, Azure RBAC, soft delete, purge protection $(if ($purgeProtection) { 'on' } else { 'off' }))")) {
            $arguments = @{ Name = $item.Name; ResourceGroupName = $item.ResourceGroup; Location = $location; SubscriptionId = $item.SubscriptionId; Sku = 'Standard'; ErrorAction = 'Stop' }
            if ($purgeProtection) { $arguments.EnablePurgeProtection = $true }
            if ($tags.Count) { $arguments.Tag = $tags }
            $null = New-AzKeyVault @arguments
            $row.Action = 'Created'
            Write-Line "[created] $($item.Name)."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    $($item.Name): would be created."
        }
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match $GroupNotFound) { $detail = "The resource group '$($item.ResourceGroup)' does not exist in the subscription. Create it first (the landing zone resource group task). $detail" }
        $row.Action = 'Failed'; $row.Detail = $detail
        Write-Warning "$($item.Name): $detail"
    }
    [pscustomobject]$row
}
$vaultRows = @($vaultRows)

# ---- the secrets the file refers to: names only, nothing is read or written
$secretRows = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($references | Group-Object { $_.Vault.ToLowerInvariant() })) {
    $vaultName = $group.Group[0].Vault
    $managed = @($plan | Where-Object { $_.Name -ieq $vaultName }) | Select-Object -First 1
    $vaultRow = @($vaultRows | Where-Object { $_.Vault -ieq $vaultName }) | Select-Object -First 1
    $secrets = @($group.Group | ForEach-Object { $_.Secret } | Select-Object -Unique)
    if (-not $managed) {
        foreach ($secret in $secrets) { $secretRows.Add([pscustomobject]@{ Vault = $vaultName; Secret = $secret; Status = 'NotManaged' }) }
        Write-Line "[note]    $($secrets.Count) secret(s) refer to the vault '$vaultName', which is not in key_vaults, so they are not checked."
        continue
    }
    if ($vaultRow.Action -notin 'AlreadyExists', 'Created') {
        foreach ($secret in $secrets) { $secretRows.Add([pscustomobject]@{ Vault = $vaultName; Secret = $secret; Status = 'Unchecked' }) }
        continue
    }
    $present = $null
    try {
        $present = @(Get-AzKeyVaultSecret -VaultName $vaultName -ErrorAction Stop | ForEach-Object { [string]$_.Name })
    }
    catch {
        $status = if ($_.Exception.Message -match $Forbidden) { 'no permission to list the secrets of this vault' } else { $_.Exception.Message }
        Write-Warning "${vaultName}: the secrets could not be listed ($status)."
    }
    foreach ($secret in $secrets) {
        $state = if ($null -eq $present) { 'Unchecked' } elseif ($present -icontains $secret) { 'Present' } else { 'Missing' }
        $secretRows.Add([pscustomobject]@{ Vault = $vaultName; Secret = $secret; Status = $state })
        if ($state -eq 'Missing') { Write-Warning "${vaultName}: the secret '$secret' is referenced by the file and does not exist. Set it with Set-AzKeyVaultSecret; this script never writes a secret." }
    }
}

$created = @($vaultRows | Where-Object Action -EQ 'Created').Count
$existingCount = @($vaultRows | Where-Object Action -EQ 'AlreadyExists').Count
$planned = @($vaultRows | Where-Object Action -EQ 'WouldCreate').Count
$failed = @($vaultRows | Where-Object Action -EQ 'Failed').Count
$missing = @($secretRows | Where-Object Status -EQ 'Missing').Count
$presentCount = @($secretRows | Where-Object Status -EQ 'Present').Count
Write-Line "Summary: $created created, $existingCount already existed, $planned planned, $failed failed; secrets: $presentCount present, $missing missing."
if ($created -eq 0 -and $planned -eq 0 -and $failed -eq 0) { Write-Line 'Nothing to do: every listed vault already exists.' }

[pscustomobject]@{ Created = $created; AlreadyExists = $existingCount; Planned = $planned; Failed = $failed; SecretsPresent = $presentCount; SecretsMissing = $missing; Vaults = $vaultRows; Secrets = @($secretRows) }
if ($failed -gt 0) { exit 1 }
exit 0
