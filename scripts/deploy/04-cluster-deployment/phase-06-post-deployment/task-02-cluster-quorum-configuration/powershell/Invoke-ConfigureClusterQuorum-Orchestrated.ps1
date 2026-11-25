<#
.SYNOPSIS
    Configures the quorum witness of the Azure Local cluster from cluster.witness of infrastructure.yml: checks or creates the storage account of a
    cloud witness, then sets the witness on the cluster (cloud witness, file share witness, or no witness). Idempotent.

.DESCRIPTION
    Phase 06 (post-deployment), Task 02 (cluster quorum configuration). The deployment creates the witness from cluster.witness; this script checks
    it, or sets it when it was added or changed after the deployment. It runs from a management host: every cluster command runs on a node over
    PowerShell remoting, so the host needs neither the failover clustering tools nor membership of the domain.

    Microsoft Learn (Deploy a quorum witness; Set-ClusterQuorum; Understanding cluster and pool quorum):
      * Cloud witness: Set-ClusterQuorum -CloudWitness -AccountName <name> -AccessKey <key> [-Endpoint <suffix>]. Only an Azure Standard general
        purpose v2 storage account with locally redundant storage is supported. The cluster does not keep the key: it makes a SAS token from it.
        The nodes reach the account on TCP 443.
      * File share witness: Set-ClusterQuorum -FileShareWitness \\server\share. The share is on a file server that is not a node, and the computer
        account of the cluster has Full Control on it.
      * Disk witness: not supported with Storage Spaces Direct, so not on Azure Local. cluster.witness.type has no disk value and the script has no
        disk witness step.
      * Two machines need a witness. The script refuses cluster.witness.type none on a two-machine instance.

    What it does, by cluster.witness.type:
      cloud       1. Azure: the account cluster.witness.storage_account in its resource group (the landing_zone.storage_accounts[] entry of that
                     name, else azure.resource_group). An account that exists is checked, never changed: another kind or SKU than StorageV2 and
                     Standard_LRS is Failed. A missing account is created (StorageV2, Standard_LRS, azure.location, the file-level tags) after the
                     name is checked free in Azure.
                  2. The cluster: when its witness is already a cloud witness on that account, nothing is changed (AlreadyConfigured), unless
                     -UpdateAccessKey asks to set it again with the current key (after a key rotation). Otherwise the access key is read
                     (Get-AzStorageAccountKey, -AccessKeyName key1 by default) and Set-ClusterQuorum -CloudWitness runs on the node. The endpoint is
                     the suffix of the blob endpoint of the account (core.windows.net in the public cloud), so a sovereign cloud works too.
      file_share  Set-ClusterQuorum -FileShareWitness cluster.witness.path, unless the witness already is that share. The share and its
                  permissions are not created here (they live on a file server outside the toolkit).
      none        Set-ClusterQuorum -NoWitness when the cluster has a witness; nothing when it has none. Refused on two machines.

    The access key is never printed, logged or returned. It goes to the node as a SecureString over the remoting session.

    The check after (the validation of the guide page): once the witness is set, or found as the file says, the quorum is read again and the witness
    resource must be Online (a row 'cluster quorum witness resource': Verified, or Failed with exit code 1). After -NoWitness the cluster must report no
    witness. Under -WhatIf the cluster is read (and the state of an existing witness is checked) and nothing is set.

    -WhatIf reads Azure and the cluster and changes nothing: no account is created, no key is read, no quorum command runs.

    Sign-in and login. Azure: the script does not sign in; run Connect-AzAccount -Tenant <azure.tenant_id> first (only for a cloud witness). It
    needs Storage Account Contributor on the resource group (create, read the key). The nodes: -Credential, else the account the file names for the
    identity: the deployment (LCM) user identity.active_directory.lcm_user (as <netbios name>\<user>) with active_directory, the local administrator
    identity.local_admin (as .\<user>) with local_identity. The password is a secret reference read through scripts/common/secrets/AzlSecret.psm1.
    The script never asks. With neither it stops with exit code 2.

    Where it connects: -ComputerName, else the management address of the first node of nodes[]; when that node does not answer, the next node.
    WinRM to an address from a host outside the domain needs the address in the WinRM TrustedHosts list of the host, or WinRM over HTTPS, as for the
    other remoting scripts of the toolkit.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.witness.type, cluster.witness.storage_account, cluster.witness.path, landing_zone.storage_accounts[] (name, resource_group)
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location, tags
        nodes[].name, nodes[].management.ip_address, scenario.identity
        identity.active_directory.netbios_name, identity.active_directory.lcm_user (username, password), identity.local_admin (username, password)

    Exit codes: 0 the witness is as the file says (set now, already so, or planned under -WhatIf); 1 a call or a precondition failed (Az missing, not
    signed in, wrong tenant, the name is taken, the account has the wrong kind or SKU, no node answers, Set-ClusterQuorum failed); 2 a value in the
    file is missing or not usable, or there is no login. On exit code 2 nothing is changed.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to run the cluster commands on (a node name of the file or an address), instead of the first node of nodes[].

.PARAMETER Credential
    Optional. The account for the remoting session to the node. Without it the account of the file is used (see above).

.PARAMETER AccessKeyName
    Optional. Which access key of the storage account the cloud witness gets: key1 (default) or key2. Learn: before you regenerate key1, set the
    witness to key2 on every cluster that uses the account.

.PARAMETER UpdateAccessKey
    Optional. Set the cloud witness again with the current access key even when the cluster already uses the account (after a key rotation).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Invoke-ConfigureClusterQuorum-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Reads Azure and the cluster and shows what would change. Changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Invoke-ConfigureClusterQuorum-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the witness storage account if it is missing and sets the cloud witness. Run it again: AlreadyConfigured.

.EXAMPLE
    ./Invoke-ConfigureClusterQuorum-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -AccessKeyName key2 -UpdateAccessKey

    Moves the cloud witness to the second key, so that the first key can be regenerated.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ComputerName,
    [pscredential]$Credential,
    [ValidateSet('key1', 'key2')][string]$AccessKeyName = 'key1',
    [switch]$UpdateAccessKey,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# Microsoft Learn, Deploy a quorum witness (cloud witness): only an Azure Standard general-purpose v2 account with locally redundant storage.
$WitnessKind = 'StorageV2'
$WitnessSku = 'Standard_LRS'
# Azure storage account names: 3 to 24 characters, lowercase letters and digits.
$StorageAccountNamePattern = '^[a-z0-9]{3,24}$'
# A file share witness is a UNC path: \\server\share[\folder...].
$UncPattern = '^\\\\[^\\/:*?"<>|\s]+\\[^\\/:*?"<>|]+(\\[^\\/:*?"<>|]+)*\\?$'
# Learn (Understanding cluster and pool quorum): two machines need a witness.
$MachinesThatNeedWitness = 2
# The cluster resource types of the witness kinds (Failover Clustering).
$CloudWitnessType = 'Cloud Witness'
$FileShareWitnessType = 'File Share Witness'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

# The commands that run on the node. Each takes the step name first, so one remoting call shape serves all of them (and a test can tell them apart).
$Remote = @{
    Probe        = { param($Step) [string]$env:COMPUTERNAME }
    ReadQuorum   = {
        param($Step)
        $quorum = Get-ClusterQuorum -ErrorAction Stop
        $resource = $quorum.QuorumResource
        $type = ''; $state = ''; $name = ''; $account = ''; $share = ''; $endpointInfo = ''
        if ($resource) {
            $name = [string]$resource.Name
            $type = [string]$(if ($resource.ResourceType -and $resource.ResourceType.PSObject.Properties['Name']) { $resource.ResourceType.Name } else { $resource.ResourceType })
            $state = [string]$resource.State
            foreach ($p in @($resource | Get-ClusterParameter -ErrorAction SilentlyContinue)) {
                if ([string]$p.Name -eq 'AccountName') { $account = [string]$p.Value }
                if ([string]$p.Name -eq 'SharePath') { $share = [string]$p.Value }
                if ([string]$p.Name -eq 'EndpointInfo') { $endpointInfo = [string]$p.Value }
            }
        }
        @{ Computer = [string]$env:COMPUTERNAME; Nodes = @(Get-ClusterNode -ErrorAction Stop).Count; QuorumType = [string]$quorum.QuorumType; ResourceName = $name; ResourceType = $type; ResourceState = $state; AccountName = $account; SharePath = $share; EndpointInfo = $endpointInfo }
    }
    SetCloud     = {
        param($Step, $Account, [securestring]$Key, $Endpoint)
        $plain = [Net.NetworkCredential]::new('', $Key).Password
        try { $null = Set-ClusterQuorum -CloudWitness -AccountName $Account -AccessKey $plain -Endpoint $Endpoint -ErrorAction Stop }
        finally { $plain = $null }
    }
    SetFileShare = { param($Step, $Path) $null = Set-ClusterQuorum -FileShareWitness $Path -ErrorAction Stop }
    SetNone      = { param($Step) $null = Set-ClusterQuorum -NoWitness -ErrorAction Stop }
}
function Invoke-Node([string]$Computer, [string]$Step, [object[]]$Arguments = @()) {
    $call = @{ ComputerName = $Computer; ScriptBlock = $Remote[$Step]; ArgumentList = (, $Step + $Arguments); ErrorAction = 'Stop' }
    if ($script:remoteCredential) { $call.Credential = $script:remoteCredential }
    Invoke-Command @call
}

$rows = [System.Collections.Generic.List[object]]::new()
$originalContext = $null
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch -Wildcard ($Action) { 'Failed' { '[failed]  ' } 'Already*' { '[exists]  ' } 'Would*' { '[plan]    ' } default { '[done]    ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Item, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}
# The check after the witness is set (or found as the file says): the page validates that the witness resource is Online. A state the cluster does
# not report is not judged; a state other than Online is a failure.
function Add-WitnessStateRow($Quorum) {
    $resourceState = [string]$Quorum.ResourceState
    if (-not $resourceState) { return }
    if ($resourceState -eq 'Online') { Add-Row 'cluster quorum witness resource' 'Verified' "Online ($($Quorum.ResourceName))" }
    else { Add-Row 'cluster quorum witness resource' 'Failed' "the witness resource '$($Quorum.ResourceName)' is $resourceState, not Online. Check that the nodes reach the witness (TCP 443 to the storage account, or the share) and the storage account firewall." }
}
# Puts the Azure context back as it was, writes the rows and ends the run: exit 1 when a row failed.
function Complete-Run {
    if ($script:originalContext -and $script:originalContext.PSObject.Properties['Subscription'] -and $script:originalContext.Subscription -and $script:originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $script:originalContext.Subscription.Id -Tenant $script:tenantId -ErrorAction Stop } catch { Write-Warning "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
    $script:rows
    if (@($script:rows | Where-Object Action -EQ 'Failed')) { exit 1 }
    exit 0
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$witness = Get-AzlClusterWitness -Infrastructure $infra
$witnessType = $witness.Type.Trim().ToLowerInvariant()
if ($witnessType -notin 'cloud', 'file_share', 'none') { Exit-InputProblem "cluster.witness.type must be cloud, file_share or none; found '$($witness.Type)'. (A disk witness is not supported with Storage Spaces Direct, so not on Azure Local.)" }

$nodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
if ($nodes.Count -eq 0 -and -not $ComputerName) { Exit-InputProblem 'nodes[] is empty. The script runs the cluster commands on a node (or give -ComputerName).' }
if ($witnessType -eq 'none' -and $nodes.Count -eq $MachinesThatNeedWitness) { Exit-InputProblem "cluster.witness.type is none, but the instance has $MachinesThatNeedWitness machines. Microsoft Learn: two machines need a witness. Set cloud or file_share." }

$accountName = $witness.StorageAccount.Trim()
$sharePath = $witness.Path.Trim()
$accountGroup = $witness.ResourceGroup.Trim()
$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = $witness.SubscriptionId.Trim()
$location = Get-Text 'azure.location'
if ($witnessType -eq 'cloud') {
    if ($accountName -notmatch $StorageAccountNamePattern) { Exit-InputProblem "cluster.witness.storage_account '$accountName' is missing or is not a valid storage account name (3 to 24 lowercase letters and digits)." }
    if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
    if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
    if (-not $accountGroup) { Exit-InputProblem 'The resource group of the witness account is missing: azure.resource_group (or resource_group of the landing_zone.storage_accounts[] entry of that name).' }
    if (-not $location) { Exit-InputProblem 'azure.location is missing. A missing witness account is created there.' }
}
if ($witnessType -eq 'file_share' -and $sharePath -notmatch $UncPattern) { Exit-InputProblem "cluster.witness.path '$sharePath' is missing or is not a UNC path (\\server\share)." }
$tags = @{}
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

# ---- the login for the nodes: -Credential, else the account of the file. Nothing is asked.
$remoteCredential = $Credential
if (-not $remoteCredential) {
    $identityMode = (Get-Text 'scenario.identity').ToLowerInvariant()
    if ($identityMode -eq 'local_identity') {
        $user = Get-Text 'identity.local_admin.username'; $reference = Get-Text 'identity.local_admin.password'; $account = ".\$user"; $what = 'identity.local_admin'
    }
    else {
        $netbios = Get-Text 'identity.active_directory.netbios_name'
        $user = Get-Text 'identity.active_directory.lcm_user.username'; $reference = Get-Text 'identity.active_directory.lcm_user.password'
        $account = if ($user -match '\\|@') { $user } elseif ($netbios) { "$netbios\$user" } else { $user }
        $what = 'identity.active_directory.lcm_user'
    }
    if (-not $user -or -not $reference) { Exit-InputProblem "No login for the nodes: pass -Credential, or set $what username and password (a secret reference) in the infrastructure file." }
    try { $secret = Get-AzlSecretValue -Reference $reference -Infrastructure $infra }
    catch { Exit-InputProblem "The password of $what could not be read: $($_.Exception.Message)" }
    $remoteCredential = [pscredential]::new($account, $secret)
}

# ---- 1. Azure: the storage account of a cloud witness
$endpoint = ''
$storage = $null
if ($witnessType -eq 'cloud') {
    foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzStorageAccount', 'New-AzStorageAccount', 'Get-AzStorageAccountKey', 'Get-AzStorageAccountNameAvailability') {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Storage modules: Install-Module Az.Accounts, Az.Storage -Scope CurrentUser." }
    }
    $context = Get-AzContext
    if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
    if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
    $originalContext = $context
    $item = "cloud witness storage account $accountName"
    try {
        $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
        try { $storage = Get-AzStorageAccount -ResourceGroupName $accountGroup -Name $accountName -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
        if ($storage) {
            $haveKind = [string]$storage.Kind
            $haveSku = if ($storage.Sku) { [string]$storage.Sku.Name } else { '' }
            if (($haveKind -and $haveKind -ne $WitnessKind) -or ($haveSku -and $haveSku -ne $WitnessSku)) {
                Add-Row $item 'Failed' "the account is kind '$haveKind' with SKU '$haveSku'. A cloud witness supports only $WitnessKind with $WitnessSku (Microsoft Learn). Nothing was changed: use another name in cluster.witness.storage_account."
                Complete-Run
            }
            Add-Row $item 'AlreadyExists' "$haveKind, $haveSku"
        }
        else {
            $free = Get-AzStorageAccountNameAvailability -Name $accountName -ErrorAction Stop
            if (-not $free.NameAvailable) { throw "The storage account name '$accountName' is taken in Azure (in another resource group or subscription). Use another name in cluster.witness.storage_account." }
            if ($PSCmdlet.ShouldProcess("storage account '$accountName' in '$accountGroup'", "Create ($WitnessKind, $WitnessSku, $location)")) {
                $create = @{ ResourceGroupName = $accountGroup; Name = $accountName; Location = $location; SkuName = $WitnessSku; Kind = $WitnessKind; ErrorAction = 'Stop' }
                if ($tags.Count) { $create.Tag = $tags }
                $storage = New-AzStorageAccount @create
                Add-Row $item 'Created' "$WitnessKind, $WitnessSku, $location"
            }
            else { Add-Row $item 'WouldCreate' "$WitnessKind, $WitnessSku, $location" }
        }
        if ($storage -and $storage.PrimaryEndpoints -and $storage.PrimaryEndpoints.Blob) {
            $blobHost = ([Uri][string]$storage.PrimaryEndpoints.Blob).Host
            $endpoint = $blobHost -replace "^$([regex]::Escape($accountName))\.blob\.", ''
        }
    }
    catch { Add-Row $item 'Failed' $_.Exception.Message; Complete-Run }
}

# ---- 2. The cluster: find a node that answers, read the quorum
$candidates = if ($ComputerName) {
    $match = @($nodes | Where-Object { $_.Name -ieq $ComputerName.Trim() } | Select-Object -First 1)
    @($(if ($match -and $match[0].ManagementIp) { $match[0].ManagementIp } else { $ComputerName.Trim() }))
}
else { @($nodes | ForEach-Object { if ($_.ManagementIp) { $_.ManagementIp } else { $_.Name } }) }
$target = ''
$firstError = ''
foreach ($candidate in $candidates) {
    try { $null = Invoke-Node $candidate 'Probe'; $target = $candidate; break }
    catch { if (-not $firstError) { $firstError = "${candidate}: $($_.Exception.Message)" } }
}
$quorumItem = 'cluster quorum witness'
if (-not $target) { Add-Row $quorumItem 'Failed' "no node answered over PowerShell remoting ($firstError)"; Complete-Run }
Write-Line "Connected to '$target' as $($remoteCredential.UserName)."

try { $state = Invoke-Node $target 'ReadQuorum' }
catch { Add-Row $quorumItem 'Failed' "the quorum could not be read on '$target': $($_.Exception.Message)"; Complete-Run }
$haveType = [string]$state.ResourceType
$haveEndpoint = if ($state -is [System.Collections.IDictionary] -and $state.Contains('EndpointInfo')) { [string]$state['EndpointInfo'] } else { '' }
$current = if ($haveType -eq $CloudWitnessType) { "cloud witness on '$($state.AccountName)'" } elseif ($haveType -eq $FileShareWitnessType) { "file share witness '$($state.SharePath)'" } elseif ($haveType) { "$haveType '$($state.ResourceName)'" } else { 'no witness' }
Write-Line "Quorum now: $current (quorum type $($state.QuorumType))."
if ($witnessType -eq 'none' -and [int]$state.Nodes -eq $MachinesThatNeedWitness) { Add-Row $quorumItem 'Failed' "the cluster has $MachinesThatNeedWitness nodes; Microsoft Learn: two machines need a witness. Nothing was changed."; Complete-Run }

# ---- 3. Set the witness when it differs (or when the key must be set again)
try {
    switch ($witnessType) {
        'cloud' {
            # The same account and, when the cluster reports it and the account is known, the same endpoint (a sovereign cloud has another suffix).
            $same = $haveType -eq $CloudWitnessType -and $state.AccountName -ieq $accountName -and (-not $endpoint -or -not $haveEndpoint -or $haveEndpoint -ieq $endpoint)
            if ($same -and -not $UpdateAccessKey) { Add-Row $quorumItem 'AlreadyConfigured' "cloud witness on '$accountName'"; Add-WitnessStateRow $state; break }
            $why = if ($same) { "set the cloud witness on '$accountName' again with $AccessKeyName" } else { "replace $current with a cloud witness on '$accountName' ($AccessKeyName)" }
            if (-not $storage) { Add-Row $quorumItem 'WouldConfigure' "$why, after the account is created"; break }
            if (-not $endpoint) { throw "The blob endpoint of '$accountName' could not be read, so the endpoint of the witness is not known." }
            if ($PSCmdlet.ShouldProcess("cluster of '$target'", "Set-ClusterQuorum -CloudWitness: $why")) {
                $key = @(Get-AzStorageAccountKey -ResourceGroupName $accountGroup -Name $accountName -ErrorAction Stop | Where-Object { [string]$_.KeyName -eq $AccessKeyName } | Select-Object -First 1)
                if (-not $key -or -not $key[0].Value) { throw "The access key $AccessKeyName of '$accountName' could not be read." }
                $secureKey = ConvertTo-SecureString -String ([string]$key[0].Value) -AsPlainText -Force
                $key = $null
                Invoke-Node $target 'SetCloud' @($accountName, $secureKey, $endpoint) | Out-Null
                $secureKey = $null
                $after = Invoke-Node $target 'ReadQuorum'
                if ([string]$after.ResourceType -ne $CloudWitnessType -or $after.AccountName -ine $accountName) { throw "Set-ClusterQuorum finished, but the witness reads '$($after.ResourceType)' on '$($after.AccountName)'." }
                Add-Row $quorumItem 'Configured' "cloud witness on '$accountName' ($AccessKeyName, endpoint $endpoint), resource state $($after.ResourceState)"
                Add-WitnessStateRow $after
            }
            else { Add-Row $quorumItem 'WouldConfigure' $why }
        }
        'file_share' {
            if ($haveType -eq $FileShareWitnessType -and $state.SharePath.TrimEnd('\') -ieq $sharePath.TrimEnd('\')) { Add-Row $quorumItem 'AlreadyConfigured' "file share witness '$sharePath'"; Add-WitnessStateRow $state; break }
            $why = "replace $current with the file share witness '$sharePath'"
            if ($PSCmdlet.ShouldProcess("cluster of '$target'", "Set-ClusterQuorum -FileShareWitness: $why")) {
                Invoke-Node $target 'SetFileShare' @($sharePath) | Out-Null
                $after = Invoke-Node $target 'ReadQuorum'
                if ([string]$after.ResourceType -ne $FileShareWitnessType) { throw "Set-ClusterQuorum finished, but the witness reads '$($after.ResourceType)'." }
                Add-Row $quorumItem 'Configured' "file share witness '$sharePath', resource state $($after.ResourceState)"
                Add-WitnessStateRow $after
            }
            else { Add-Row $quorumItem 'WouldConfigure' $why }
        }
        'none' {
            if (-not $haveType) { Add-Row $quorumItem 'AlreadyConfigured' 'no witness'; break }
            Write-Warning "cluster.witness.type is none: the witness ($current) is removed. Microsoft Learn strongly recommends a witness for three or four machines."
            if ($PSCmdlet.ShouldProcess("cluster of '$target'", "Set-ClusterQuorum -NoWitness (remove $current)")) {
                Invoke-Node $target 'SetNone' | Out-Null
                $after = Invoke-Node $target 'ReadQuorum'
                if ([string]$after.ResourceType) { throw "Set-ClusterQuorum -NoWitness finished, but the cluster still has the witness '$($after.ResourceType)'." }
                Add-Row $quorumItem 'Configured' "no witness (was $current)"
            }
            else { Add-Row $quorumItem 'WouldConfigure' "remove $current" }
        }
    }
}
catch { Add-Row $quorumItem 'Failed' $_.Exception.Message }

Complete-Run
