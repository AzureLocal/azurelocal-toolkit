<#
.SYNOPSIS
    Turns on SSH access to the Azure Local machines through Azure Arc: the WindowsOpenSSH Arc extension, the HybridConnectivity endpoint and the SSH service
    configuration, for every machine of nodes[] in infrastructure.yml. Idempotent. Checks the result.

.DESCRIPTION
    Phase 06 (post-deployment), Task 04 (SSH connectivity to nodes). Microsoft Learn (SSH access to Azure Arc-enabled servers; Connect to an Azure Local VM
    using SSH): the Arc agent installs OpenSSH (sshd) through the extension Microsoft.Azure.OpenSSH / WindowsOpenSSH, the machine gets a HybridConnectivity
    endpoint and the endpoint gets a service configuration that allows the SSH port. After this task an operator connects with az ssh arc or Enter-AzVM.
    Nothing reaches the machines from here (no WinRM, no remoting), and no inbound port is opened on the network.

    For each machine (the Arc machine is nodes[].arc_machine_name, the node name when the file gives none, in azure.resource_group):
      1. The resource provider Microsoft.HybridConnectivity is registered, once per run, when it is not (the script waits up to -MaxWaitMinutes).
      2. The WindowsOpenSSH extension is created (New-AzConnectedMachineExtension, in the region of the Arc machine) when the machine has none that Succeeded.
      3. The HybridConnectivity default endpoint is created (PUT, api-version 2023-03-15) when it is not there.
      4. The SSH service configuration (service SSH, port -SshdPort) is set on that endpoint when it is not there with that port.
      5. The check after (the validation of the guide page): the extension reads Succeeded, and the service configuration reads back with the port and
         resourceProvisioningState Succeeded. A machine that fails this check fails the run.
      6. Informational: whether sshd answers on TCP 22 at the management address of the node. It is not a failure when it does not: the Arc route needs no
         inbound path, and a host that is not on the management network cannot reach the node. Phase 06 task 09 checks sshd and port 22 from the management host.

    Idempotent: an extension that Succeeded, an endpoint and a service configuration that are there with the port are reported as AlreadyDone and not written
    again. -WhatIf reads Azure and changes nothing: no provider is registered, no extension created, nothing written.

    Not in this task, as the page says: the roles that let an operator connect (Virtual Machine Local User Login) and the connection test with az ssh arc, which
    needs the credentials of a person. Windows nodes authenticate sshd with Windows accounts.

    The script does not sign in: run Connect-AzAccount -Tenant <azure.tenant_id> first (Az.Accounts, Az.Resources, Az.ConnectedMachine). You need Contributor or
    Owner (or Azure Connected Machine Resource Administrator) on the resource group. The Az context is put back as it was when the script ends. The script never
    prompts.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group
        nodes[].name, nodes[].arc_machine_name, nodes[].management.ip_address

    Exit codes: 0 every machine is done or planned under -WhatIf; 1 a call or a precondition failed (Az missing, not signed in, wrong tenant, provider not
    registered in time, a machine not found or not Connected, a step or the check after failed); 2 a value in the file is missing or not usable (nothing is sent
    to Azure).

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
    ./Invoke-SSHConnectivity-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Reads Azure and shows what would be done on each machine. Changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Invoke-SSHConnectivity-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -TargetNode <node-name>

    Turns SSH on for one machine. Run it again: AlreadyDone.
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

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# Fixed by Microsoft (Learn: SSH access to Azure Arc-enabled servers; the OpenSSH extension for Windows): the provider, the extension and the REST version.
$HybridConnectivityProvider = 'Microsoft.HybridConnectivity'
$OpenSshExtensionName = 'WindowsOpenSSH'
$OpenSshExtensionPublisher = 'Microsoft.Azure.OpenSSH'
$OpenSshExtensionType = 'WindowsOpenSSH'
$HybridConnectivityApiVersion = '2023-03-15'
$ArcMachineProvider = 'Microsoft.HybridCompute'
# The SSH protocol port the node answers on (page task 09, check 5). The informational check only.
$SshPort = 22

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Property($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    $null
}
function Test-NodePort([string]$Address, [int]$Port) {
    if (Get-Command -Name Test-NetConnection -ErrorAction SilentlyContinue) { return [bool](Test-NetConnection -ComputerName $Address -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue) }
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try { $attempt = $tcp.ConnectAsync($Address, $Port); return [bool]($attempt.Wait(5000) -and $tcp.Connected) } catch { return $false } finally { $tcp.Dispose() }
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
    if ($node.ArcMachineName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { Exit-InputProblem "nodes[].arc_machine_name of '$($node.Name)' ('$($node.ArcMachineName)') is not an Arc machine name (letters, digits, dot, underscore, hyphen)." }
}

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResourceProvider', 'Register-AzResourceProvider', 'Get-AzConnectedMachine', 'Get-AzConnectedMachineExtension', 'New-AzConnectedMachineExtension', 'Invoke-AzRestMethod') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts, Az.Resources and Az.ConnectedMachine modules: Install-Module Az.Accounts, Az.Resources, Az.ConnectedMachine -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } { $_ -in 'AlreadyDone', 'Verified' } { '[exists]  ' } { $_ -like 'Would*' } { '[plan]    ' } 'Info' { '[info]    ' } default { '[done]    ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Item, $(if ($Detail) { " ($Detail)" } else { '' }))
}
function Get-ProviderState {
    $state = @(Get-AzResourceProvider -ProviderNamespace $HybridConnectivityProvider -ErrorAction Stop | ForEach-Object { [string](Get-Property $_ 'RegistrationState') } | Where-Object { $_ })
    if ($state.Count -eq 0) { return 'NotRegistered' }
    if (@($state | Where-Object { $_ -ne 'Registered' }).Count -eq 0) { return 'Registered' }
    $state[0]
}
function ConvertFrom-RestResponse($Response) {
    $code = [int](Get-Property $Response 'StatusCode')
    $body = $null
    $content = [string](Get-Property $Response 'Content')
    if ($content -and $content.Trim()) { try { $body = $content | ConvertFrom-Json -Depth 20 } catch { $body = $null } }
    [pscustomobject]@{ Code = $code; Body = $body; Text = $content }
}
function Get-ConnectivityResource([string]$Url) { ConvertFrom-RestResponse (Invoke-AzRestMethod -Method GET -Path $Url -ErrorAction Stop) }
function Set-ConnectivityResource([string]$Url, [string]$Body) {
    $result = ConvertFrom-RestResponse (Invoke-AzRestMethod -Method PUT -Path $Url -Payload $Body -ErrorAction Stop)
    if ($result.Code -lt 200 -or $result.Code -ge 300) { throw "Azure answered HTTP $($result.Code): $($result.Text)" }
}
function Get-NestedValue($Object, [string[]]$Path) {
    $node = $Object
    foreach ($part in $Path) { $node = Get-Property $node $part; if ($null -eq $node) { return $null } }
    $node
}

Write-Line "SSH over Azure Arc for $($nodes.Count) machine(s) in '$group' (subscription $subscriptionId), SSH port $SshdPort"
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop

    # ---- the provider, once per subscription
    $providerReady = $false
    try {
        $state = Get-ProviderState
        if ($state -eq 'Registered') { Add-Row "resource provider $HybridConnectivityProvider" 'AlreadyDone' 'Registered'; $providerReady = $true }
        elseif ($PSCmdlet.ShouldProcess("resource provider '$HybridConnectivityProvider' in subscription $subscriptionId", 'Register')) {
            $null = Register-AzResourceProvider -ProviderNamespace $HybridConnectivityProvider -ErrorAction Stop
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
            $info = $null
            try { $info = Get-AzConnectedMachine -Name $machine -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
            catch {
                if ($_.Exception.Message -match $NotFound) { throw "The Arc machine '$machine' does not exist in '$group'. Register the node with Azure Arc first (phase 04)." }
                throw "The Arc machine could not be read: $($_.Exception.Message)"
            }
            $status = [string](Get-Property $info 'Status')
            if ($status -and $status -ne 'Connected') { throw "The Arc machine is $status, not Connected. The extension cannot be installed on a machine that is not connected." }
            $machineLocation = [string](Get-Property $info 'Location')
            if (-not $machineLocation) { throw 'Azure gave no region for the Arc machine.' }

            # 2. the extension
            $ext = $null
            try { $ext = Get-AzConnectedMachineExtension -MachineName $machine -ResourceGroupName $group -SubscriptionId $subscriptionId -Name $OpenSshExtensionName -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch $NotFound) { throw "The extension could not be read: $($_.Exception.Message)" } }
            $extState = if ($ext) { [string](Get-Property $ext 'ProvisioningState') } else { '' }
            if ($extState -eq 'Succeeded') { Add-Row "$item extension $OpenSshExtensionName" 'AlreadyDone' 'Succeeded' }
            elseif ($extState -in 'Failed', 'Canceled') { throw "The extension $OpenSshExtensionName is in the $extState state. It is left in place: delete it (portal) after you read its error, then run the script again." }
            elseif ($PSCmdlet.ShouldProcess("machine '$machine'", "Create the extension $OpenSshExtensionName")) {
                $null = New-AzConnectedMachineExtension -Name $OpenSshExtensionName -MachineName $machine -ResourceGroupName $group -SubscriptionId $subscriptionId -Location $machineLocation -Publisher $OpenSshExtensionPublisher -ExtensionType $OpenSshExtensionType -ErrorAction Stop
                $after = Get-AzConnectedMachineExtension -MachineName $machine -ResourceGroupName $group -SubscriptionId $subscriptionId -Name $OpenSshExtensionName -ErrorAction Stop
                $afterState = [string](Get-Property $after 'ProvisioningState')
                if ($afterState -ne 'Succeeded') { throw "The extension is $(if ($afterState) { $afterState } else { 'in an unknown state' }), not Succeeded." }
                Add-Row "$item extension $OpenSshExtensionName" 'Created' 'Succeeded'
            }
            else { Add-Row "$item extension $OpenSshExtensionName" 'WouldCreate' $(if ($extState) { $extState } else { 'not installed' }) }

            # 3. the HybridConnectivity default endpoint, 4. the SSH service configuration
            $machineId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/$ArcMachineProvider/machines/$machine"
            $endpointUrl = "$machineId/providers/$HybridConnectivityProvider/endpoints/default?api-version=$HybridConnectivityApiVersion"
            $serviceUrl = "$machineId/providers/$HybridConnectivityProvider/endpoints/default/serviceconfigurations/SSH?api-version=$HybridConnectivityApiVersion"

            $endpoint = Get-ConnectivityResource $endpointUrl
            if ($endpoint.Code -ne 200 -and $endpoint.Code -ne 404) { throw "The default endpoint could not be read: HTTP $($endpoint.Code) $($endpoint.Text)" }
            $endpointType = [string](Get-NestedValue $endpoint.Body @('properties', 'type'))
            if ($endpoint.Code -eq 200 -and $endpointType -eq 'default') { Add-Row "$item HybridConnectivity endpoint" 'AlreadyDone' 'default' }
            elseif ($PSCmdlet.ShouldProcess("machine '$machine'", 'Create the HybridConnectivity default endpoint')) {
                Set-ConnectivityResource $endpointUrl (@{ properties = @{ type = 'default' } } | ConvertTo-Json -Compress)
                Add-Row "$item HybridConnectivity endpoint" 'Created' 'default'
            }
            else { Add-Row "$item HybridConnectivity endpoint" 'WouldCreate' 'default' }

            $service = Get-ConnectivityResource $serviceUrl
            if ($service.Code -ne 200 -and $service.Code -ne 404) { throw "The SSH service configuration could not be read: HTTP $($service.Code) $($service.Text)" }
            $havePort = [string](Get-NestedValue $service.Body @('properties', 'port'))
            if ($service.Code -eq 200 -and $havePort -eq [string]$SshdPort) { Add-Row "$item SSH service configuration" 'AlreadyDone' "port $havePort" }
            elseif ($PSCmdlet.ShouldProcess("machine '$machine'", "Set the SSH service configuration (port $SshdPort)")) {
                Set-ConnectivityResource $serviceUrl (@{ properties = @{ serviceName = 'SSH'; port = $SshdPort } } | ConvertTo-Json -Compress)
                Add-Row "$item SSH service configuration" 'Created' "port $SshdPort"
            }
            else { Add-Row "$item SSH service configuration" 'WouldCreate' "port $SshdPort" }

            # 5. the check after: the service configuration reads back with the port and Succeeded (not under -WhatIf: nothing was written)
            if (-not $WhatIfPreference) {
                $back = Get-ConnectivityResource $serviceUrl
                $backPort = [string](Get-NestedValue $back.Body @('properties', 'port'))
                $backState = [string](Get-NestedValue $back.Body @('properties', 'resourceProvisioningState'))
                if ($back.Code -ne 200 -or $backPort -ne [string]$SshdPort -or ($backState -and $backState -ne 'Succeeded')) {
                    throw "The SSH service configuration reads back as port '$backPort', state '$backState' (HTTP $($back.Code)); the page expects port $SshdPort and Succeeded."
                }
                Add-Row "$item SSH check" 'Verified' "extension Succeeded; SSH service configuration port $backPort, $(if ($backState) { $backState } else { 'no state reported' })"
            }

            # 6. informational: does sshd answer at the management address
            if ($node.ManagementIp) {
                $open = Test-NodePort $node.ManagementIp $SshPort
                Add-Row "$item sshd on $($node.ManagementIp):$SshPort" 'Info' $(if ($open) { 'answers' } else { 'does not answer from this host (no failure: the Arc route needs no inbound path)' })
            }
        }
        catch { Add-Row $item 'Failed' $_.Exception.Message }
    }
}
catch { Add-Row "subscription $subscriptionId" 'Failed' "the subscription could not be selected or read: $($_.Exception.Message)" }
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
