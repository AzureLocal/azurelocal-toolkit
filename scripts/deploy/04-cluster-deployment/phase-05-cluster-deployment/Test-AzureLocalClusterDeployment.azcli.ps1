<#
.SYNOPSIS
    Verifies in Azure that the deployment of an Azure Local instance completed, with the Azure CLI. Read only.

.DESCRIPTION
    Phase 05 (cluster deployment), task 02 (verify deployment completion), the Azure side. It asks Azure what the deployment reported; it does not reach
    the nodes or Active Directory. The checks of the nodes, the domain or workgroup, the quorum and the security groups run on premises: they are
    Invoke-VerifyPostDeployment.ps1 (phase 06, task 09), which is also the verification of the deployment itself. The two task scripts of phase 05
    (active-directory and local-identity, task 02) call this script with the identity of their folder.

    Checks, in this order. Nothing is created, changed or deleted.
      1. Instance: the Azure Local instance cluster.name exists in azure.resource_group and its provisioning state is Succeeded.
      2. Deployment: deploymentSettings/default of the instance has the provisioning state Succeeded and the deployment status Success. A failed or
         unfinished deployment lists the steps that failed.
      3. Machines: every machine of nodes[] has an Arc machine in azure.resource_group with the status Connected.

    -WhatIf lists the checks and runs none. The script does not sign in: run az login --tenant <azure.tenant_id> first. It needs the Azure CLI extensions
    stack-hci and connectedmachine and does not install them. It does not change the Azure CLI default subscription: every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure): azure.tenant_id, azure.subscription_id, azure.resource_group,
    cluster.name, scenario.identity, nodes[].name, nodes[].arc_machine_name.

    Exit codes: 0 every check passed (or planned under -WhatIf); 1 a check failed or a precondition failed (az missing, not signed in, wrong tenant);
    2 a value in the file is missing or unusable, or scenario.identity is not the identity this task is for (nothing was checked).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. Only the keys above are read.

.PARAMETER ExpectedIdentity
    active_directory or local_identity. The two task scripts pass the identity of their folder; the script stops with exit code 2 when scenario.identity
    of the file is the other one. Empty: no check.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-AzureLocalClusterDeployment.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    az login --tenant <tenant-id>
    ./Test-AzureLocalClusterDeployment.azcli.ps1 -InfrastructureFile ./infrastructure.yml
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [ValidateSet('', 'active_directory', 'local_identity')][string]$ExpectedIdentity = '',
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# The Azure CLI is started through a command file on Windows. These characters would be read as commands there, so no value that holds one is sent.
$UnsafeArgument = '[&|<>^%"`\r\n]'
# The api-version of the Microsoft.AzureStackHCI deploymentSettings resource this script reads. Fixed by the Azure API (Microsoft Learn, Microsoft.AzureStackHCI
# clusters/deploymentSettings, 2026-10-01 is in the 2610 view); the same version AzlArmDeployment.psm1 reads with.
$HciApiVersion = '2026-10-01'

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
function Get-Reported($Object, [string]$Name) {
    $value = Get-Prop $Object @($Name)
    if ($null -eq $value -or "$value" -eq '') { $value = Get-Prop $Object @('properties', $Name) }
    [string]$value
}

# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the exit code, stdout and stderr.
function Invoke-AzCli([string[]]$Arguments) {
    foreach ($argument in $Arguments) {
        if ($argument -match $UnsafeArgument) { throw "An argument holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote): $argument" }
    }
    $all = @(& az @Arguments 2>&1)
    $code = [int](Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err; Detail = $(if ($err) { $err.Trim() } else { $out.Trim() }) }
}
function ConvertFrom-AzJson([string]$Text) { if ($Text -and $Text.Trim()) { $Text | ConvertFrom-Json -Depth 50 } }
function Get-FailedStep($Steps) {
    foreach ($s in @($Steps)) {
        if ($null -eq $s) { continue }
        if ([string](Get-Prop $s @('status')) -in 'Error', 'Failed') { "$(Get-Prop $s @('name')): $(@(Get-Prop $s @('exception')) -join ' ')" }
        Get-FailedStep (Get-Prop $s @('steps'))
    }
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$clusterName = Get-Text 'cluster.name'
$identity = Get-Text 'scenario.identity'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The instance is deployed there.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing in the infrastructure file.' }
foreach ($value in @($group, $clusterName)) { if ($value -match $UnsafeArgument) { Exit-InputProblem "A value of the file holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote): $value" } }
if ($ExpectedIdentity -and $identity -ne $ExpectedIdentity) { Exit-InputProblem "This task is for scenario.identity $ExpectedIdentity, but the file says '$identity'. Use the task of the other identity, or correct the file." }
$nodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
if ($nodes.Count -eq 0) { Exit-InputProblem 'nodes[] is empty in the infrastructure file.' }
foreach ($node in $nodes) {
    if (-not $node.ArcMachineName -or $node.ArcMachineName -match $UnsafeArgument) { Exit-InputProblem "Node '$($node.Name)' has no usable Arc machine name (nodes[].arc_machine_name)." }
}

Write-Line "Deployment completion (Azure): instance '$clusterName', $($nodes.Count) machine(s), resource group '$group'"
if (-not $PSCmdlet.ShouldProcess("the deployment of '$clusterName'", 'Check')) {
    foreach ($line in @('Instance is Succeeded', 'deploymentSettings: provisioning Succeeded, deployment status Success', 'Every Arc machine is Connected')) { Write-Line "[plan]    $line" }
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

# 1. The instance
$list = Invoke-AzCli (@('stack-hci', 'cluster', 'list') + $scope + @('--output', 'json', '--only-show-errors'))
if ($list.ExitCode -ne 0) { Add-Check "instance $clusterName" 'Failed' $list.Detail }
else {
    $cluster = @(@(ConvertFrom-AzJson $list.Output) | Where-Object { $_ -and [string](Get-Prop $_ @('name')) -eq $clusterName }) | Select-Object -First 1
    if (-not $cluster) { Add-Check "instance $clusterName" 'Failed' "not found in '$group'" }
    else {
        $state = Get-Reported $cluster 'provisioningState'
        Add-Check "instance $clusterName is Succeeded" $(if ($state -eq 'Succeeded') { 'Passed' } else { 'Failed' }) "$state, status $(Get-Reported $cluster 'status')"
    }
}

# 2. The deployment
$url = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.AzureStackHCI/clusters/$clusterName/deploymentSettings/default?api-version=$HciApiVersion"
$settings = Invoke-AzCli @('rest', '--method', 'get', '--url', $url, '--output', 'json', '--only-show-errors')
if ($settings.ExitCode -ne 0) { Add-Check 'deployment settings of the instance' 'Failed' $(if ($settings.Detail -match $NotFound) { 'not found: the deployment has not run' } else { $settings.Detail }) }
else {
    $j = ConvertFrom-AzJson $settings.Output
    $provisioning = [string](Get-Prop $j @('properties', 'provisioningState'))
    $deployment = Get-Prop $j @('properties', 'reportedProperties', 'deploymentStatus')
    $status = [string](Get-Prop $deployment @('status'))
    $done = ($provisioning -eq 'Succeeded') -and (($status -replace '[\s_\-]', '') -in 'Success', 'Succeeded', 'DeploymentSuccess')
    Add-Check 'deployment completed' $(if ($done) { 'Passed' } else { 'Failed' }) "provisioning $provisioning, deployment status $status"
    if (-not $done) {
        foreach ($step in @(Get-FailedStep (Get-Prop $deployment @('steps')))) { if ($step) { Write-Line "         failed step: $step" } }
    }
}

# 3. The Arc machines
foreach ($node in $nodes) {
    $show = Invoke-AzCli (@('connectedmachine', 'show') + $scope + @('--name', $node.ArcMachineName, '--output', 'json', '--only-show-errors'))
    if ($show.ExitCode -ne 0) { Add-Check "Arc machine $($node.ArcMachineName) (node $($node.Name))" 'Failed' $(if ($show.Detail -match $NotFound) { 'not found' } else { $show.Detail }); continue }
    $status = Get-Reported (ConvertFrom-AzJson $show.Output) 'status'
    Add-Check "Arc machine $($node.ArcMachineName) (node $($node.Name)) is Connected" $(if ($status -eq 'Connected') { 'Passed' } else { 'Failed' }) $status
}

$failed = @($rows | Where-Object Result -EQ 'Failed').Count
$passed = @($rows | Where-Object Result -EQ 'Passed').Count
Write-Line "Summary: $passed passed, $failed failed"
$rows
if ($failed -gt 0) { exit 1 }
exit 0
