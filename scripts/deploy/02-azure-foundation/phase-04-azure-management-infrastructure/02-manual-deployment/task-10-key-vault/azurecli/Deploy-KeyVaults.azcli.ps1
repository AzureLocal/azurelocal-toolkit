<#
.SYNOPSIS
    Creates the Key Vaults that infrastructure.yml lists, and checks that the secrets the file refers to are there, with the Azure CLI.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 10 (Key Vault), Azure CLI variant of Deploy-KeyVaults.ps1. It does the
    same with az commands, for a host that has the Azure CLI and not the Az PowerShell modules. It creates each vault of the key_vaults list
    with "az keyvault create", in the subscription and resource group the entry names, in the region azure.location: a standard vault that uses
    Azure RBAC for its data plane (no access policies), with soft delete for key_vaults[].soft_delete_retention_days days (7 to 90; the registry
    default is 90, the Azure default) and, depending on scenario.environment_class, purge protection. Then it reads every
    keyvault://<vault>/<secret> reference in the file and reports which of those secrets exist in the vaults it manages.

    The script never writes a secret, never reads a secret value and never asks for one: the check lists the secret NAMES of a vault
    ("az keyvault secret list --query [].name"). A secret VALUE does not belong in the file or in a script: set it with
    "az keyvault secret set" (or the portal) as someone who holds Key Vault Secrets Officer on the vault, then run this script again to see the
    secret listed as present. A secret named by a reference that is missing is reported, not created. It does not create the vault of the
    cluster deployment (cluster.key_vault: the ARM deployment creates that one), and it does not grant any role: assign Key Vault Secrets
    User or Officer to the people and identities that need them with the role assignment task.

    Purge protection cannot be switched off once it is on, and it keeps a deleted vault's name reserved for the retention period. So it is on
    for every vault the script creates, except when scenario.environment_class is lab, test or dev, where a vault has to be removable.
    A missing scenario.environment_class means production. The vault's network access is left at the Azure default (all networks); restrict
    it with your network design after the vault exists.

    Idempotent. A vault that exists is reported as AlreadyExists and left alone (a setting that differs is reported, not changed), so a second
    run creates nothing. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with "az keyvault create", behind -WhatIf. It does not sign in: run
    "az login --tenant <azure.tenant_id>" first. You need Key Vault Contributor (or Contributor) on the resource group. Listing a vault's secrets
    needs Key Vault Secrets User (or Reader of the data plane) on the vault; without it the secrets of that vault are reported as Unchecked.
    Every management call names its subscription, so the subscription of the az session is not changed. The tags in the file-level tags map
    are put on the vaults it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags, scenario.environment_class
        key_vaults[].name, .subscription_id, .resource_group, .purpose, .soft_delete_retention_days
        every keyvault://<vault>/<secret> reference anywhere in the file (names only; no value is read)

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every listed vault exists (created now, already there, or planned under -WhatIf), whether or not secrets are still missing;
    1 an az call failed or a precondition failed (az missing, not signed in, wrong tenant, a creation failed); 2 the file lists no vault or a
    value is not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-KeyVaults.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which vaults would be created and which secrets are missing, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Deploy-KeyVaults.azcli.ps1 -InfrastructureFile ./infrastructure.yml

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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'azure-local', 'AzlAzure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'ResourceNotFound|VaultNotFound|NotFound|could not be found|was not found|does not exist|\b404\b'
$GroupNotFound = 'ResourceGroupNotFound|Resource group ''[^'']*'' could not be found'
$Forbidden = 'Forbidden|403|not authorized|does not have (secrets )?(list|get)|AuthorizationFailed|Unauthorized'
# Not choices of a deployment. The environment classes are the values of scenario.environment_class (the registry lists them): a vault of
# these classes has to be removable, so purge protection is left off (Microsoft Learn: Key Vault soft delete and purge protection).
$RemovableClasses = 'lab', 'test', 'dev'
# The vaults hold secrets only, so the standard SKU is enough: the higher tier adds keys protected by a hardware security module
# (Microsoft Learn: Azure Key Vault service tiers). Azure RBAC is the permission model Microsoft recommends and the one Azure Local uses.
$VaultSku = 'standard'
# key_vaults[].soft_delete_retention_days when an entry leaves it out: the registry default (the Azure default), and the range Azure accepts.
$DefaultRetentionDays = 90
$MinRetentionDays = 7
$MaxRetentionDays = 90

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
# One az call with JSON output, parsed; $null when az printed nothing.
function Invoke-AzJson {
    $text = Invoke-Az @args '--output' 'json'
    if ($text) { $text | ConvertFrom-Json }
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
$vaultEntries = @(@($rawVaults) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawVaults)) { Exit-InputProblem 'An entry of key_vaults is not a map (names with their settings).' } })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
# The tags go into az arguments: refuse a key or a value that az.cmd cannot carry before any Azure call (also under -WhatIf).
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = $rawTags })
if ($problem) { Exit-InputProblem $problem }
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
    $retentionText = Get-Entry $entry 'soft_delete_retention_days'
    $retention = $DefaultRetentionDays
    if ($retentionText) {
        $retentionDays = 0
        if ($retentionText -notmatch '^\d+$' -or -not [int]::TryParse($retentionText, [ref]$retentionDays) -or $retentionDays -lt $MinRetentionDays -or $retentionDays -gt $MaxRetentionDays) { Exit-InputProblem "key_vaults '$name': soft_delete_retention_days '$retentionText' is not a whole number from $MinRetentionDays to $MaxRetentionDays." }
        $retention = $retentionDays
    }
    [pscustomobject]@{ Name = $name; SubscriptionId = $subscriptionId; ResourceGroup = $group; Purpose = (Get-Entry $entry 'purpose'); RetentionDays = $retention }
}
$plan = @($plan)
$duplicate = @($plan | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object Count -GT 1)
if ($duplicate.Count) { Exit-InputProblem "The vault '$($duplicate[0].Group[0].Name)' appears more than once in key_vaults." }

# the secrets the file refers to, by vault
$references = @(Get-KeyVaultReference $infra | Select-Object -Unique | ForEach-Object { ConvertFrom-AzlKeyVaultRef -Reference $_ } | Where-Object { $_ })

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A name that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.location' = $location; 'key_vaults resource_group' = @($plan | ForEach-Object { $_.ResourceGroup }); 'key_vaults purpose' = @($plan | ForEach-Object { $_.Purpose }) })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Deploy-KeyVaults.ps1.' }
try { $account = Invoke-Az account show --query tenantId --output tsv }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($account -ne $tenantId) { Exit-Failed "Signed in to tenant $account, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Key Vaults: $($plan.Count) listed, region $location, purge protection on new vaults: $(if ($purgeProtection) { 'on' } else { "off (scenario.environment_class is $($environmentClass.Trim().ToLowerInvariant()))" })"

# ---- one vault at a time
$vaultRows = foreach ($item in $plan) {
    $row = [ordered]@{ Vault = $item.Name; Action = ''; Detail = '' }
    try {
        $existing = $null
        try { $existing = Invoke-AzJson keyvault show --name $item.Name --resource-group $item.ResourceGroup --subscription $item.SubscriptionId }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

        if ($existing) {
            $row.Action = 'AlreadyExists'
            Write-Line "[exists]  $($item.Name): already there, nothing changed."
            $differs = @()
            $rbac = Get-JsonValue $existing 'properties.enableRbacAuthorization'
            if ($null -ne $rbac -and -not [bool]$rbac) { $differs += 'it uses access policies, not Azure RBAC' }
            $soft = Get-JsonValue $existing 'properties.enableSoftDelete'
            if ($null -ne $soft -and -not [bool]$soft) { $differs += 'soft delete is off' }
            $days = Get-JsonValue $existing 'properties.softDeleteRetentionInDays'
            if ($null -ne $days -and [int]$days -ne $item.RetentionDays) { $differs += "soft delete keeps $days days, the file says $($item.RetentionDays) (Azure does not change it after creation)" }
            # A vault this script would create with purge protection: say so when the existing one has none. It is never turned on here.
            $purge = Get-JsonValue $existing 'properties.enablePurgeProtection'
            if ($purgeProtection -and -not [bool]$purge) { $differs += 'purge protection is off' }
            if ($differs.Count) {
                $row.Detail = "Differs from what this script creates ($($differs -join '; ')); left unchanged."
                Write-Warning "$($item.Name): $($row.Detail)"
            }
        }
        elseif ($PSCmdlet.ShouldProcess("Key Vault '$($item.Name)' in '$($item.ResourceGroup)'", "Create (standard, Azure RBAC, soft delete $($item.RetentionDays) days, purge protection $(if ($purgeProtection) { 'on' } else { 'off' }))")) {
            $createArgs = @('keyvault', 'create', '--name', $item.Name, '--resource-group', $item.ResourceGroup, '--location', $location, '--subscription', $item.SubscriptionId, '--sku', $VaultSku, '--enable-rbac-authorization', 'true', '--retention-days', [string]$item.RetentionDays)
            if ($purgeProtection) { $createArgs += '--enable-purge-protection'; $createArgs += 'true' }
            $createArgs += @(Get-TagArgument)
            $null = Invoke-AzJson @createArgs
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
        $present = @(Invoke-AzJson keyvault secret list --vault-name $vaultName --query '[].name' | ForEach-Object { [string]$_ })
    }
    catch {
        $status = if ($_.Exception.Message -match $Forbidden) { 'no permission to list the secrets of this vault' } else { $_.Exception.Message }
        Write-Warning "${vaultName}: the secrets could not be listed ($status)."
    }
    foreach ($secret in $secrets) {
        $state = if ($null -eq $present) { 'Unchecked' } elseif ($present -icontains $secret) { 'Present' } else { 'Missing' }
        $secretRows.Add([pscustomobject]@{ Vault = $vaultName; Secret = $secret; Status = $state })
        if ($state -eq 'Missing') { Write-Warning "${vaultName}: the secret '$secret' is referenced by the file and does not exist. Set it with az keyvault secret set; this script never writes a secret." }
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
