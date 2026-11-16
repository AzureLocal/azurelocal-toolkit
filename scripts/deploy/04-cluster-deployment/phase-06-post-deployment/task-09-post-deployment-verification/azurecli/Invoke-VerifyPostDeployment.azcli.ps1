<#
.SYNOPSIS
    Verifies the Azure side of a deployed Azure Local instance against the infrastructure file, with the Azure CLI. Read only.

.DESCRIPTION
    Phase 06 (post-deployment), Task 09. Azure CLI variant of Invoke-VerifyPostDeployment.ps1 for the checks that read Azure. The PowerShell script
    also reaches the nodes (cluster state, domain membership, quorum, local groups, sshd, storage pool, CSV volumes); this script does not, so those
    checks are not here: run the PowerShell script for them. Nothing is created, changed or deleted.

    Checks, in this order:
      1. Arc machines: every machine of nodes[] exists in azure.resource_group and its status is Connected.
      2. Arc extensions: on every machine the extensions the Azure Local registration installs (AzureEdgeTelemetryAndDiagnostics,
         AzureEdgeDeviceManagement, AzureEdgeLifecycleManager, AzureEdgeRemoteSupport) and the OpenSSH extension of task 04 (WindowsOpenSSH) are
         Succeeded.
      3. Cluster: the Azure Local instance cluster.name exists in azure.resource_group and its provisioning state is Succeeded.
      4. Custom location: azure.custom_location exists and its provisioning state is Succeeded.
      5. Cloud witness: with cluster.witness.type cloud, the storage account cluster.witness.storage_account exists in azure.resource_group and
         is Succeeded.
      6. Storage paths: the number of storage paths in Azure is not below the number in storage.paths[].
      7. VM images: the number of images that Succeeded is not below the number in storage.vm_images[].
      8. Logical networks: the number that Succeeded is not below the number of enabled entries of networking.logical_networks[].
      9. Network security groups: the number of groups in Azure is not below the number in networking.network_security_groups[].

    -WhatIf lists the checks and runs none. The script does not sign in: run az login --tenant <azure.tenant_id> first. It needs the Azure CLI
    extensions connectedmachine, stack-hci, stack-hci-vm and customlocation, and does not install them. It does not change the Azure CLI default
    subscription: every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.custom_location, cluster.name, cluster.witness.type,
        cluster.witness.storage_account, nodes[].name, nodes[].arc_machine_name, storage.paths[], storage.vm_images[],
        networking.logical_networks[].enabled, networking.network_security_groups[]

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every check passed (or planned under -WhatIf); 1 a check failed or a precondition failed (az missing, not signed in, wrong tenant);
    2 a value in the file is missing or unusable (nothing was checked).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. Only the keys above are read.

.PARAMETER TargetNode
    Limit the machine checks (1 and 2) to these nodes (nodes[].name). Default: every node of the file.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Invoke-VerifyPostDeployment.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    az login --tenant <tenant-id>
    ./Invoke-VerifyPostDeployment.azcli.ps1 -InfrastructureFile ./infrastructure.yml -TargetNode <node-name>
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$TargetNode = @(),
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# The Arc extensions that the Azure Local registration installs (Microsoft Learn, Known issues in Azure Local 24xx releases: the mandatory extensions for
# device deployment) and the OpenSSH extension of task 04 (Microsoft Learn, SSH access to Azure Arc-enabled servers).
$RegistrationExtension = @('AzureEdgeTelemetryAndDiagnostics', 'AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport')
$SshExtension = 'WindowsOpenSSH'

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
# A value that the Azure CLI shows at the top of the resource or, with older output, under properties.
function Get-Reported($Object, [string]$Name) {
    $value = Get-Prop $Object @($Name)
    if ($null -eq $value -or "$value" -eq '') { $value = Get-Prop $Object @('properties', $Name) }
    [string]$value
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

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$customLocation = Get-Text 'azure.custom_location'
$clusterName = Get-Text 'cluster.name'
$witness = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.witness'
$witnessType = ([string](Get-Field $witness 'type' '')).Trim().ToLowerInvariant()
$witnessAccount = ([string](Get-Field $witness 'storage_account' '')).Trim()
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$networking = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking'
$expectedPaths = @(@(Get-Field $storage 'paths' @()) | Where-Object { $null -ne $_ }).Count
$expectedImages = @(@(Get-Field $storage 'vm_images' @()) | Where-Object { $null -ne $_ }).Count
$expectedNetworks = @(@(Get-Field $networking 'logical_networks' @()) | Where-Object { $_ -is [System.Collections.IDictionary] -and (Get-Field $_ 'enabled' $true) -ne $false }).Count
$expectedGroups = @(@(Get-Field $networking 'network_security_groups' @()) | Where-Object { $null -ne $_ }).Count

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The instance and its Arc machines are there.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing in the infrastructure file.' }
if (-not $customLocation) { Exit-InputProblem 'azure.custom_location is missing. It is the custom location of the Azure Local instance.' }
if ($witnessType -eq 'cloud' -and -not $witnessAccount) { Exit-InputProblem 'cluster.witness.type is cloud, but cluster.witness.storage_account is missing.' }
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group; 'cluster.name' = $clusterName; 'azure.custom_location' = $customLocation; 'cluster.witness.storage_account' = $witnessAccount }); if ($problem) { Exit-InputProblem $problem }

$fileNodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
$nodes = @(if ($TargetNode.Count -gt 0) { $fileNodes | Where-Object { $_.Name -in $TargetNode } } else { $fileNodes })
if ($fileNodes.Count -eq 0) { Exit-InputProblem 'nodes[] is empty in the infrastructure file.' }
if ($nodes.Count -eq 0) { Exit-InputProblem "-TargetNode matches no node of the file ($($TargetNode -join ', '))." }
foreach ($node in $nodes) {
    if (-not $node.ArcMachineName) { Exit-InputProblem "Node '$($node.Name)' has no usable Arc machine name (nodes[].arc_machine_name)." }
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "nodes[].arc_machine_name of '$($node.Name)'" = $node.ArcMachineName }); if ($problem) { Exit-InputProblem $problem }
}

Write-Line "Post-deployment verification (Azure): cluster '$clusterName', $($nodes.Count) machine(s), resource group '$group'"
if (-not $PSCmdlet.ShouldProcess("the Azure checks of cluster '$clusterName'", 'Run')) {
    foreach ($line in @('Arc machines: every node is Connected', 'Arc extensions: the Azure Local and OpenSSH extensions are Succeeded', 'Cluster resource is Succeeded', 'Custom location is Succeeded',
            'Cloud witness storage account exists', 'Storage paths, VM images, logical networks and network security groups are at least as many as the file lists')) { Write-Line "[plan]    $line" }
    Write-Line 'Planned only: run again without -WhatIf to run the checks.'
    exit 0
}

# ---- preconditions (read only)
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>.' }
$account = Invoke-AzCli @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors')
if ($account.ExitCode -ne 0) { Exit-Failed "Not signed in to the Azure CLI for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($account.Detail)" }
$accountInfo = ConvertFrom-AzJson $account.Output
if ([string](Get-Prop $accountInfo @('tenantId')) -ne $tenantId) { Exit-Failed "The Azure CLI is signed in to tenant $(Get-Prop $accountInfo @('tenantId')), but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Check, [string]$Result, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Check = $Check; Result = $Result; Detail = $Detail })
    $tag = switch ($Result) { 'Failed' { '[FAIL] ' } 'Skipped' { '[SKIP] ' } default { '[PASS] ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Check, $(if ($Detail) { " - $Detail" } else { '' }))
}
$scope = @('--subscription', $subscriptionId, '--resource-group', $group)
# Reads one list or one resource; $null with the reason in $script:ReadError when it is not there or cannot be read.
function Read-Az([string[]]$Arguments) {
    $r = Invoke-AzCli ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ($r.ExitCode -ne 0) { $script:ReadError = $(if ($r.Detail -match $NotFound) { 'not found' } else { $r.Detail }); return $null }
    $script:ReadError = ''
    [pscustomobject]@{ Data = (ConvertFrom-AzJson $r.Output) }
}
$script:ReadError = ''

# 1 and 2. Arc machines and their extensions
foreach ($node in $nodes) {
    $machine = $node.ArcMachineName
    $info = Read-Az (@('connectedmachine', 'show') + $scope + @('--name', $machine))
    if ($null -eq $info) { Add-Check "Arc machine $machine (node $($node.Name))" 'Failed' $script:ReadError; continue }
    $status = Get-Reported $info.Data 'status'
    Add-Check "Arc machine $machine (node $($node.Name)) is Connected" $(if ($status -eq 'Connected') { 'Passed' } else { 'Failed' }) $status

    $list = Read-Az (@('connectedmachine', 'extension', 'list') + $scope + @('--machine-name', $machine))
    if ($null -eq $list) { Add-Check "extensions of $machine" 'Failed' $script:ReadError; continue }
    $have = @($list.Data)
    foreach ($name in @($RegistrationExtension) + @($SshExtension)) {
        $one = @($have | Where-Object { $_ -and ([string](Get-Prop $_ @('name'))).Split('/')[-1] -eq $name }) | Select-Object -First 1
        $state = if ($one) { Get-Reported $one 'provisioningState' } else { 'not installed' }
        Add-Check "extension $name on $machine" $(if ($state -eq 'Succeeded') { 'Passed' } else { 'Failed' }) $state
    }
}

# 3. The cluster resource
$clusters = Read-Az (@('stack-hci', 'cluster', 'list') + $scope)
if ($null -eq $clusters) { Add-Check "Azure Local instance $clusterName" 'Failed' $script:ReadError }
else {
    $cluster = @($clusters.Data | Where-Object { $_ -and [string](Get-Prop $_ @('name')) -eq $clusterName }) | Select-Object -First 1
    if (-not $cluster) { Add-Check "Azure Local instance $clusterName" 'Failed' "not found in '$group'" }
    else {
        $state = Get-Reported $cluster 'provisioningState'
        Add-Check "Azure Local instance $clusterName is Succeeded" $(if ($state -eq 'Succeeded') { 'Passed' } else { 'Failed' }) "$state, status $(Get-Reported $cluster 'status')"
    }
}

# 4. The custom location
$location = Read-Az (@('customlocation', 'show') + $scope + @('--name', $customLocation))
if ($null -eq $location) { Add-Check "custom location $customLocation" 'Failed' $script:ReadError }
else {
    $state = Get-Reported $location.Data 'provisioningState'
    Add-Check "custom location $customLocation is Succeeded" $(if ($state -eq 'Succeeded') { 'Passed' } else { 'Failed' }) $state
}

# 5. The cloud witness
if ($witnessType -eq 'cloud') {
    $account = Read-Az (@('storage', 'account', 'show') + $scope + @('--name', $witnessAccount))
    if ($null -eq $account) { Add-Check "cloud witness storage account $witnessAccount" 'Failed' $script:ReadError }
    else {
        $state = Get-Reported $account.Data 'provisioningState'
        Add-Check "cloud witness storage account $witnessAccount is Succeeded" $(if ($state -eq 'Succeeded') { 'Passed' } else { 'Failed' }) $state
    }
}
else { Add-Check 'cloud witness storage account' 'Skipped' "cluster.witness.type is '$witnessType'" }

# 6 to 9. What the tasks of this phase create
$counts = @(
    @{ Label = 'storage paths'; Command = @('stack-hci-vm', 'storagepath', 'list'); Expected = $expectedPaths; Succeeded = $false }
    @{ Label = 'VM images'; Command = @('stack-hci-vm', 'image', 'list'); Expected = $expectedImages; Succeeded = $true }
    @{ Label = 'logical networks'; Command = @('stack-hci-vm', 'network', 'lnet', 'list'); Expected = $expectedNetworks; Succeeded = $true }
    @{ Label = 'network security groups'; Command = @('stack-hci-vm', 'network', 'nsg', 'list'); Expected = $expectedGroups; Succeeded = $false }
)
foreach ($count in $counts) {
    if ($count.Expected -eq 0) { Add-Check $count.Label 'Skipped' 'the file lists none'; continue }
    $list = Read-Az (@($count.Command) + $scope)
    if ($null -eq $list) { Add-Check $count.Label 'Failed' $script:ReadError; continue }
    $items = @($list.Data | Where-Object { $null -ne $_ })
    $have = if ($count.Succeeded) { @($items | Where-Object { (Get-Reported $_ 'provisioningState') -eq 'Succeeded' }).Count } else { $items.Count }
    Add-Check "$($count.Label): $($count.Expected) expected" $(if ($have -ge $count.Expected) { 'Passed' } else { 'Failed' }) "$have$(if ($count.Succeeded) { ' Succeeded' } else { ' found' }) in '$group'"
}

$failed = @($rows | Where-Object Result -EQ 'Failed').Count
$passed = @($rows | Where-Object Result -EQ 'Passed').Count
$skipped = @($rows | Where-Object Result -EQ 'Skipped').Count
Write-Line "Summary: $passed passed, $failed failed, $skipped skipped"
$rows
if ($failed -gt 0) { exit 1 }
exit 0
