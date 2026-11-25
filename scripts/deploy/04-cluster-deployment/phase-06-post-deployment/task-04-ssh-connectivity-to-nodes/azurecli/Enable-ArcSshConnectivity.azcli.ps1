<#
.SYNOPSIS
    Turns on SSH access to the Azure Local machines through Azure Arc, with the Azure CLI: the WindowsOpenSSH extension, the HybridConnectivity endpoint and the SSH service configuration.

.DESCRIPTION
    Phase 06 (post-deployment), Task 04 (SSH connectivity to nodes). The Azure side of SSH for every machine of nodes[] in infrastructure.yml. The
    Arc agent installs OpenSSH on the machine, so nothing reaches the machine from here: no WinRM and no remoting. After this task an operator
    connects with az ssh arc or Enter-AzVM (Microsoft Learn, SSH access to Azure Arc-enabled servers).

    For each machine (the Arc machine is nodes[].arc_machine_name, the node name when the file gives none, in azure.resource_group):
      1. The WindowsOpenSSH Arc extension (publisher Microsoft.Azure.OpenSSH) is created with az connectedmachine extension create, in the region
         of the Arc machine, when the machine has none that Succeeded.
      2. The HybridConnectivity default endpoint is created with az rest (api-version 2023-03-15).
      3. The SSH service configuration (service SSH, port -SshdPort) is set on that endpoint with az rest.
    Once per run, before the machines: the resource provider Microsoft.HybridConnectivity is registered when it is not (and the script waits up to
    -MaxWaitMinutes for it to show Registered).

    Idempotent. An extension that Succeeded is left alone; the endpoint and the service configuration are PUT again, which Azure accepts as an
    update to the same value. -WhatIf reads Azure and changes nothing.

    The script needs the Azure CLI with the connectedmachine extension (az extension add --name connectedmachine); it does not install it and
    does not sign in: run az login --tenant <azure.tenant_id> first. It does not change the Azure CLI default subscription: every call carries
    --subscription. The signed-in account needs a role that can create extensions and write HybridConnectivity on the machines (Contributor or
    Owner, or Azure Connected Machine Resource Administrator).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group
        nodes[].name, nodes[].arc_machine_name

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every machine is done or planned under -WhatIf; 1 a call or a precondition failed (az missing, not signed in, wrong tenant,
    extension missing, provider not registered in time, a machine not found or not Connected, a step failed); 2 a value in the file is missing or
    not usable. On exit code 2 nothing is sent to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. Only the keys above are read.

.PARAMETER TargetNode
    Limit the run to these nodes (nodes[].name). Default: every node of the file.

.PARAMETER SshdPort
    The port written to the SSH service configuration of the endpoint (1 to 65535). Default: 22, the port of the SSH protocol.

.PARAMETER MaxWaitMinutes
    The longest time to wait for the provider Microsoft.HybridConnectivity to show Registered, in minutes (1 to 60). Default: 10.

.PARAMETER PollSeconds
    Seconds between two reads while a wait runs (1 to 300). Default: 15.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Enable-ArcSshConnectivity.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be done on each machine, and does nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Enable-ArcSshConnectivity.azcli.ps1 -InfrastructureFile ./infrastructure.yml -TargetNode <node-name>

    Turns SSH on for one machine.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$TargetNode = @(),
    [ValidateRange(1, 65535)][int]$SshdPort = 22,
    [ValidateRange(1, 60)][int]$MaxWaitMinutes = 10,
    [ValidateRange(1, 300)][int]$PollSeconds = 15,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# Fixed by Microsoft (Learn: SSH access to Azure Arc-enabled servers; the OpenSSH extension for Windows): the provider, the extension and the REST version.
$HybridConnectivityProvider = 'Microsoft.HybridConnectivity'
$OpenSshExtensionName = 'WindowsOpenSSH'
$OpenSshExtensionPublisher = 'Microsoft.Azure.OpenSSH'
$OpenSshExtensionType = 'WindowsOpenSSH'
$HybridConnectivityApiVersion = '2023-03-15'
$ArcMachineProvider = 'Microsoft.HybridCompute'

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

# One PUT with az rest. The body goes through a file in the temporary folder, so no quote crosses the command line.
function Invoke-AzPut([string]$Url, [string]$Body) {
    $file = Join-Path ([IO.Path]::GetTempPath()) ("azl-ssh-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $file -Value $Body -Encoding utf8NoBOM -NoNewline -WhatIf:$false
        Invoke-AzCli @('rest', '--method', 'put', '--url', $Url, '--headers', 'Content-Type=application/json', '--body', "@$file", '--output', 'none', '--only-show-errors')
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue -WhatIf:$false }
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The Arc machines of the nodes are there.' }

$fileNodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
$nodes = @(if ($TargetNode.Count -gt 0) { $fileNodes | Where-Object { $_.Name -in $TargetNode } } else { $fileNodes })
if ($fileNodes.Count -eq 0) { Exit-InputProblem 'nodes[] is empty in the infrastructure file.' }
if ($nodes.Count -eq 0) { Exit-InputProblem "-TargetNode matches no node of the file ($($TargetNode -join ', '))." }
foreach ($node in $nodes) {
    if (-not $node.ArcMachineName) { Exit-InputProblem "Node '$($node.Name)' has no Arc machine name (nodes[].arc_machine_name)." }
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "nodes[].arc_machine_name of '$($node.Name)'" = $node.ArcMachineName }); if ($problem) { Exit-InputProblem $problem }
}

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A value that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>.' }
$account = Invoke-AzCli @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors')
if ($account.ExitCode -ne 0) { Exit-Failed "Not signed in to the Azure CLI for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($account.Detail)" }
$accountInfo = ConvertFrom-AzJson $account.Output
if ([string](Get-Prop $accountInfo @('tenantId')) -ne $tenantId) { Exit-Failed "The Azure CLI is signed in to tenant $(Get-Prop $accountInfo @('tenantId')), but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }
$extension = Invoke-AzCli @('extension', 'show', '--name', 'connectedmachine', '--output', 'json', '--only-show-errors')
if ($extension.ExitCode -ne 0) { Exit-Failed 'The Azure CLI extension connectedmachine is not installed. This script does not install it. Run: az extension add --name connectedmachine' }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } 'AlreadyDone' { '[exists]  ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[done]    ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Item, $(if ($Detail) { " ($Detail)" } else { '' }))
}
function Get-ProviderState {
    $r = Invoke-AzCli @('provider', 'show', '--namespace', $HybridConnectivityProvider, '--subscription', $subscriptionId, '--query', 'registrationState', '--output', 'tsv', '--only-show-errors')
    if ($r.ExitCode -ne 0) { throw "The state of $HybridConnectivityProvider could not be read: $($r.Detail)" }
    $r.Output.Trim()
}

Write-Line "SSH over Azure Arc for $($nodes.Count) machine(s) in '$group' (subscription $subscriptionId), SSH port $SshdPort"

# ---- the provider, once per subscription
$providerReady = $false
try {
    $state = Get-ProviderState
    if ($state -eq 'Registered') { Add-Row "resource provider $HybridConnectivityProvider" 'AlreadyDone' 'Registered'; $providerReady = $true }
    elseif ($PSCmdlet.ShouldProcess("resource provider '$HybridConnectivityProvider' in subscription $subscriptionId", 'Register')) {
        $r = Invoke-AzCli @('provider', 'register', '--namespace', $HybridConnectivityProvider, '--subscription', $subscriptionId, '--output', 'none', '--only-show-errors')
        if ($r.ExitCode -ne 0) { throw "The registration failed: $($r.Detail)" }
        $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
        do {
            Start-Sleep -Seconds $PollSeconds
            $state = Get-ProviderState
        } while ($state -ne 'Registered' -and (Get-Date) -lt $deadline)
        if ($state -ne 'Registered') { throw "The provider is still $state after $MaxWaitMinutes minute(s)." }
        Add-Row "resource provider $HybridConnectivityProvider" 'Registered' 'registration finished'
        $providerReady = $true
    }
    else { Add-Row "resource provider $HybridConnectivityProvider" 'WouldRegister' $state; $providerReady = $true }
}
catch { Add-Row "resource provider $HybridConnectivityProvider" 'Failed' $_.Exception.Message }

foreach ($node in $nodes) {
    $machine = $node.ArcMachineName
    $item = "machine $machine (node $($node.Name))"
    if (-not $providerReady) { Add-Row $item 'Failed' 'skipped: the provider is not registered'; continue }
    try {
        $show = Invoke-AzCli @('connectedmachine', 'show', '--subscription', $subscriptionId, '--resource-group', $group, '--name', $machine, '--output', 'json', '--only-show-errors')
        if ($show.ExitCode -ne 0) {
            if ($show.Detail -match $NotFound) { throw "The Arc machine '$machine' does not exist in '$group'. Register the node with Azure Arc first (phase 04)." }
            throw "The Arc machine could not be read: $($show.Detail)"
        }
        $info = ConvertFrom-AzJson $show.Output
        $status = [string](Get-Prop $info @('status'))
        if (-not $status) { $status = [string](Get-Prop $info @('properties', 'status')) }
        if ($status -and $status -ne 'Connected') { throw "The Arc machine is $status, not Connected. The extension cannot be installed on a machine that is not connected." }
        $machineLocation = [string](Get-Prop $info @('location'))
        if (-not $machineLocation) { throw 'Azure gave no region for the Arc machine.' }

        # 1. the extension
        $ext = Invoke-AzCli @('connectedmachine', 'extension', 'show', '--subscription', $subscriptionId, '--resource-group', $group, '--machine-name', $machine, '--name', $OpenSshExtensionName, '--output', 'json', '--only-show-errors')
        if ($ext.ExitCode -ne 0 -and $ext.Detail -notmatch $NotFound) { throw "The extension could not be read: $($ext.Detail)" }
        $extState = if ($ext.ExitCode -eq 0) { [string](Get-Prop (ConvertFrom-AzJson $ext.Output) @('properties', 'provisioningState')) } else { '' }
        if ($extState -eq 'Succeeded') { Add-Row "$item extension $OpenSshExtensionName" 'AlreadyDone' 'Succeeded' }
        elseif ($extState -in 'Failed', 'Canceled') { throw "The extension $OpenSshExtensionName is in the $extState state. It is left in place: delete it (az connectedmachine extension delete) after you read its error, then run the script again." }
        elseif ($PSCmdlet.ShouldProcess("machine '$machine'", "Create the extension $OpenSshExtensionName")) {
            $create = Invoke-AzCli @('connectedmachine', 'extension', 'create', '--subscription', $subscriptionId, '--resource-group', $group, '--machine-name', $machine, '--name', $OpenSshExtensionName,
                '--publisher', $OpenSshExtensionPublisher, '--type', $OpenSshExtensionType, '--location', $machineLocation, '--output', 'none', '--only-show-errors')
            if ($create.ExitCode -ne 0) { throw "The extension creation failed: $($create.Detail)" }
            $after = Invoke-AzCli @('connectedmachine', 'extension', 'show', '--subscription', $subscriptionId, '--resource-group', $group, '--machine-name', $machine, '--name', $OpenSshExtensionName, '--output', 'json', '--only-show-errors')
            $afterState = if ($after.ExitCode -eq 0) { [string](Get-Prop (ConvertFrom-AzJson $after.Output) @('properties', 'provisioningState')) } else { '' }
            if ($afterState -ne 'Succeeded') { throw "The extension is $(if ($afterState) { $afterState } else { 'in an unknown state' }), not Succeeded." }
            Add-Row "$item extension $OpenSshExtensionName" 'Created' 'Succeeded'
        }
        else { Add-Row "$item extension $OpenSshExtensionName" 'WouldCreate' $extState }

        # 2. the HybridConnectivity default endpoint, 3. the SSH service configuration
        $machineId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/$ArcMachineProvider/machines/$machine"
        $endpointUrl = "$machineId/providers/$HybridConnectivityProvider/endpoints/default?api-version=$HybridConnectivityApiVersion"
        $serviceUrl = "$machineId/providers/$HybridConnectivityProvider/endpoints/default/serviceconfigurations/SSH?api-version=$HybridConnectivityApiVersion"
        if ($PSCmdlet.ShouldProcess("machine '$machine'", 'Create the HybridConnectivity default endpoint')) {
            $put = Invoke-AzPut $endpointUrl (@{ properties = @{ type = 'default' } } | ConvertTo-Json -Compress)
            if ($put.ExitCode -ne 0) { throw "The default endpoint could not be created: $($put.Detail)" }
            Add-Row "$item HybridConnectivity endpoint" 'Created' 'default'
        }
        else { Add-Row "$item HybridConnectivity endpoint" 'WouldCreate' 'default' }
        if ($PSCmdlet.ShouldProcess("machine '$machine'", "Set the SSH service configuration (port $SshdPort)")) {
            $put = Invoke-AzPut $serviceUrl (@{ properties = @{ serviceName = 'SSH'; port = $SshdPort } } | ConvertTo-Json -Compress)
            if ($put.ExitCode -ne 0) { throw "The SSH service configuration could not be set: $($put.Detail)" }
            Add-Row "$item SSH service configuration" 'Created' "port $SshdPort"
        }
        else { Add-Row "$item SSH service configuration" 'WouldCreate' "port $SshdPort" }
    }
    catch { Add-Row $item 'Failed' $_.Exception.Message }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
