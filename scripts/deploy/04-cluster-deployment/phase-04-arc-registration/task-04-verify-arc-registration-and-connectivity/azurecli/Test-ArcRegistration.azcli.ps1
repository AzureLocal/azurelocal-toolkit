<#
.SYNOPSIS
    Verifies in Azure that the Azure Local machines are registered with Azure Arc and connected, with the Azure CLI. Read only.

.DESCRIPTION
    Phase 04 (Arc registration), Task 04 (verify Arc registration and connectivity), the Azure side: what Azure Arc reports about each machine of
    nodes[] in infrastructure.yml. The reachability of the Arc endpoints from the machines themselves runs on the machines and is not an Azure CLI
    task. Nothing is created, changed or deleted.

    Checks:
      1. Machines: the number of Arc machines found for nodes[] equals the number of nodes[] in scope, and each one exists in azure.resource_group
         (the Arc machine is nodes[].arc_machine_name, the node name when the file gives none).
      2. Connected: the status of each Arc machine is Connected.
      3. Extensions: on each machine the extensions that the Azure Local registration installs (AzureEdgeTelemetryAndDiagnostics,
         AzureEdgeDeviceManagement, AzureEdgeLifecycleManager, AzureEdgeRemoteSupport; Microsoft Learn, Known issues in Azure Local 24xx releases, and
         Azure Arc extension management on Azure Local) are Succeeded. They install some time after the registration, so run this check again when one
         is still Creating.

    -WhatIf lists the checks and runs none. The script does not sign in: run az login --tenant <azure.tenant_id> first. It needs the Azure CLI
    extension connectedmachine (az extension add --name connectedmachine) and does not install it. It does not change the Azure CLI default
    subscription: every call carries --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, nodes[].name, nodes[].arc_machine_name

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every check passed (or planned under -WhatIf); 1 a check failed or a precondition failed (az missing, not signed in, wrong tenant,
    extension missing); 2 a value in the file is missing or unusable (nothing was checked).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. Only the keys above are read.

.PARAMETER TargetNode
    Limit the checks to these nodes (nodes[].name). Default: every node of the file.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-ArcRegistration.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    az login --tenant <tenant-id>
    ./Test-ArcRegistration.azcli.ps1 -InfrastructureFile ./infrastructure.yml
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
# The Arc extensions that the Azure Local registration installs (Microsoft Learn, Known issues in Azure Local 24xx releases: the mandatory extensions for device deployment).
$RegistrationExtension = @('AzureEdgeTelemetryAndDiagnostics', 'AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport')

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
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The Arc machines are registered into it.' }
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group }); if ($problem) { Exit-InputProblem $problem }

$fileNodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
$nodes = @(if ($TargetNode.Count -gt 0) { $fileNodes | Where-Object { $_.Name -in $TargetNode } } else { $fileNodes })
if ($fileNodes.Count -eq 0) { Exit-InputProblem 'nodes[] is empty in the infrastructure file.' }
if ($nodes.Count -eq 0) { Exit-InputProblem "-TargetNode matches no node of the file ($($TargetNode -join ', '))." }
foreach ($node in $nodes) {
    if (-not $node.ArcMachineName) { Exit-InputProblem "Node '$($node.Name)' has no usable Arc machine name (nodes[].arc_machine_name)." }
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "nodes[].arc_machine_name of '$($node.Name)'" = $node.ArcMachineName }); if ($problem) { Exit-InputProblem $problem }
}

Write-Line "Arc registration (Azure): $($nodes.Count) machine(s) in resource group '$group', subscription $subscriptionId"
if (-not $PSCmdlet.ShouldProcess("the Arc machines of $($nodes.Count) node(s) in '$group'", 'Check')) {
    foreach ($line in @('Every node has an Arc machine in the resource group', 'Every Arc machine is Connected', "The $($RegistrationExtension.Count) Azure Local extensions are Succeeded on every machine")) { Write-Line "[plan]    $line" }
    Write-Line 'Planned only: run again without -WhatIf to run the checks.'
    exit 0
}

# ---- preconditions (read only)
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>.' }
$account = Invoke-AzCli @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors')
if ($account.ExitCode -ne 0) { Exit-Failed "Not signed in to the Azure CLI for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($account.Detail)" }
$accountInfo = ConvertFrom-AzJson $account.Output
if ([string](Get-Prop $accountInfo @('tenantId')) -ne $tenantId) { Exit-Failed "The Azure CLI is signed in to tenant $(Get-Prop $accountInfo @('tenantId')), but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }
$extension = Invoke-AzCli @('extension', 'show', '--name', 'connectedmachine', '--output', 'json', '--only-show-errors')
if ($extension.ExitCode -ne 0) { Exit-Failed 'The Azure CLI extension connectedmachine is not installed. This script does not install it. Run: az extension add --name connectedmachine' }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Check, [string]$Result, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Check = $Check; Result = $Result; Detail = $Detail })
    $tag = switch ($Result) { 'Failed' { '[FAIL] ' } 'Skipped' { '[SKIP] ' } default { '[PASS] ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Check, $(if ($Detail) { " - $Detail" } else { '' }))
}
$scope = @('--subscription', $subscriptionId, '--resource-group', $group)

$found = 0
foreach ($node in $nodes) {
    $machine = $node.ArcMachineName
    $label = "Arc machine $machine (node $($node.Name))"
    $show = Invoke-AzCli (@('connectedmachine', 'show') + $scope + @('--name', $machine, '--output', 'json', '--only-show-errors'))
    if ($show.ExitCode -ne 0) {
        Add-Check "$label exists" 'Failed' $(if ($show.Detail -match $NotFound) { "not found in '$group'. Register the node with Azure Arc (task 02)." } else { $show.Detail })
        continue
    }
    $found++
    $info = ConvertFrom-AzJson $show.Output
    Add-Check "$label exists" 'Passed' "agent $(Get-Reported $info 'agentVersion')"
    $status = Get-Reported $info 'status'
    Add-Check "$label is Connected" $(if ($status -eq 'Connected') { 'Passed' } else { 'Failed' }) $status

    $list = Invoke-AzCli (@('connectedmachine', 'extension', 'list') + $scope + @('--machine-name', $machine, '--output', 'json', '--only-show-errors'))
    if ($list.ExitCode -ne 0) { Add-Check "extensions of $machine" 'Failed' $list.Detail; continue }
    $have = @(@(ConvertFrom-AzJson $list.Output) | Where-Object { $null -ne $_ })
    foreach ($name in $RegistrationExtension) {
        $one = @($have | Where-Object { ([string](Get-Prop $_ @('name'))).Split('/')[-1] -eq $name }) | Select-Object -First 1
        $state = if ($one) { Get-Reported $one 'provisioningState' } else { 'not installed (yet)' }
        Add-Check "extension $name on $machine" $(if ($state -eq 'Succeeded') { 'Passed' } else { 'Failed' }) $state
    }
}
Add-Check "Arc machines found: $($nodes.Count) expected" $(if ($found -eq $nodes.Count) { 'Passed' } else { 'Failed' }) "$found found"

$failed = @($rows | Where-Object Result -EQ 'Failed').Count
$passed = @($rows | Where-Object Result -EQ 'Passed').Count
Write-Line "Summary: $passed passed, $failed failed"
$rows
if ($failed -gt 0) { exit 1 }
exit 0
