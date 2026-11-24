<#
.SYNOPSIS
    Tests the Azure Arc side of every Azure Local node from the node: the agent, its extensions and the endpoints it must reach. Read only.

.DESCRIPTION
    Stage 07 (validation and handover), task 02. Over PowerShell remoting the script asks every cluster node that is Up (Microsoft Learn: Azure Connected Machine agent
    CLI reference, azcmagent show, azcmagent extension; Firewall requirements for Azure Local):

      Agent       is the Azure Connected Machine agent installed, and does azcmagent show report the status Connected (Disconnected is a failure, anything else a warning);
      Extension service  the extension manager of the agent (the Windows service ExtensionService) runs; anything else is a failure, because no
                  extension is installed, updated or removed while it does not run;
      Extensions  the extensions of the Arc machine, from the status files the extension manager keeps on the node: a last status other than success is a warning
                  (azcmagent extension list is NOT used: it stops the extension service of the node while it runs);
      Endpoints   can the node open a TCP connection on 443 to every host of the one documented endpoint list of the toolkit (Arc, authentication, management and data plane
                  groups of AzlVerification.Endpoints.psm1, for the region azure.location). A required host that cannot be reached is a failure, an optional one a warning.

    The Azure side of the same question (the Arc machines, their status, the extensions and the identity as Azure Resource Manager shows them) is stage 04, phase 04, task 04
    (Test-ArcRegistration.azcli.ps1). This script does not sign in to Azure and calls no Azure command, so the task has no Azure CLI script of its own.

    The script changes nothing and asks nothing. It runs on the management host, which needs neither the cluster's domain nor its DNS: the cluster questions go to the
    first node of nodes[] that answers on WinRM at its management address (or -ComputerName), every node is asked at its own management address, and the account is the
    deployment (LCM) user of the file, its secret read through the toolkit's secret resolver (or -Credential; the account that runs the script when the file has none).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure): cluster.name (the cluster to ask), azure.location (the region of the endpoint list),
    nodes[] (the management addresses) and identity.active_directory (the deployment user and its secret reference).

    Exit codes: 0 no check failed (warnings are listed); 1 a check failed or the cluster could not be read; 2 cluster.name or azure.location is missing, or the file cannot be read.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Reads cluster.name and azure.location; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to send the cluster questions to. Default: the first node of nodes[] that answers on WinRM; cluster.name when the file has no node address.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Default: the deployment user of the file; the account that runs the script when the file has none.

.PARAMETER OutputPath
    Optional. A folder: the results are also saved there as arc-connectivity-<date>-<time>.json (created when it does not exist). Keep it out of the repository.

.EXAMPLE
    ./Test-ArcConnectivity.ps1 -InfrastructureFile ./infrastructure.yml

    Checks the Arc agent, the extensions and the endpoints from every node and prints a row per check.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ComputerName,
    [pscredential]$Credential,
    [string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common'))
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'arm-deployment', 'verification', 'AzlVerification.Endpoints.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'remoting', 'AzlClusterConnection.psm1')) -Force

function Write-Line([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }

# $Node empty: the cluster target of the connection. Otherwise that node, at its management address of the file.
function Invoke-Remote([string]$Node, [scriptblock]$Block, [object[]]$Arguments = @()) { Invoke-AzlClusterCommand -Connection $connection -Node $Node -ScriptBlock $Block -ArgumentList $Arguments }

# The blocks that run on the nodes (Windows PowerShell): read only.
$ReadNodes = { @(Get-ClusterNode | Where-Object { [string]$_.State -eq 'Up' } | ForEach-Object { [string]$_.Name }) }
$ReadAgent = {
    $agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
    if (-not (Test-Path -LiteralPath $agent)) { return @{ Installed = $false } }
    $show = (& $agent show --json 2>&1 | Out-String) | ConvertFrom-Json
    # The extensions are read from the status files the extension manager keeps (the newest status file of the newest version of each extension), NOT with
    # 'azcmagent extension list': that command stops the extension service of the node while it runs (seen on agent 1.67; Learn, azcmagent extension: the extension
    # manager must be stopped, which interrupts an extension operation in progress), and a validation must not do that.
    $extensions = @()
    $plugins = Join-Path $env:SystemDrive 'Packages\Plugins'
    if (Test-Path -LiteralPath $plugins) {
        $extensions = @(Get-ChildItem -LiteralPath $plugins -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $version = Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } | Select-Object -Last 1
                $state = 'no status file'
                if ($version) {
                    $file = Get-ChildItem -LiteralPath (Join-Path $version.FullName 'status') -Filter '*.status' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
                    if ($file) { try { $state = [string]@(Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)[0].status.status } catch { $state = 'status file not readable' } }
                }
                @{ Name = [string]$_.Name; Version = [string]$(if ($version) { $version.Name }); State = $state }
            })
    }
    # The status files say what an extension last reported, not that the extension manager runs now: its service is read as well.
    $service = Get-Service -Name 'ExtensionService' -ErrorAction SilentlyContinue
    @{ Installed = $true; Status = [string]$show.status; Error = [string]$show.agentErrorMessage; LastHeartbeat = [string]$show.lastHeartbeat; Extensions = $extensions; ExtensionService = [string]$(if ($service) { $service.Status } else { 'not installed' }) }
}
$ProbeEndpoint = {
    param($Targets)
    foreach ($target in $Targets) {
        $ok = $false; $err = ''
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $tcp.BeginConnect([string]$target.Host, [int]$target.Port, $null, $null)
            if ($connect.AsyncWaitHandle.WaitOne(5000, $false)) { $tcp.EndConnect($connect); $ok = $true } else { $err = 'timeout after 5 seconds' }
        }
        catch { $err = $_.Exception.Message }
        finally { $tcp.Close() }
        @{ Host = [string]$target.Host; Port = [int]$target.Port; Ok = $ok; Error = $err }
    }
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }
$clusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
$location = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')).Trim()
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing in the infrastructure file. It is the cluster to ask.' }
if (-not $location) { Exit-InputProblem 'azure.location is missing in the infrastructure file. It is the region of the endpoint list.' }
$targets = @(Get-AzlEndpointSet -Location $location -Group Arc, Auth, Management, DataPlane -Port 443 | ForEach-Object { @{ Host = $_.Host; Port = $_.Port; Tier = $_.Tier; Name = $_.Note } })
if ($targets.Count -eq 0) { Exit-InputProblem "azure.location '$location' is not a region of the endpoint list, so no endpoint can be tested." }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Node, [string]$Check, [string]$Status, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Node = $Node; Check = $Check; Status = $Status; Detail = $Detail })
    $tag = switch ($Status) { 'Passed' { '[ok]      ' } 'Warning' { '[warning] ' } default { '[failed]  ' } }
    Write-Line ('{0}{1} {2}: {3}{4}' -f $tag, $Node, $Check, $Status, $(if ($Detail) { " ($Detail)" } else { '' }))
}

$connection = Resolve-AzlClusterConnection -Infrastructure $infra -ComputerName $ComputerName -Credential $Credential -RemoteCommand { param([hashtable]$Call) Invoke-Command @Call }
Write-Line "Azure Arc validation from the nodes of cluster '$clusterName' (region $location, $($targets.Count) endpoints)"
Write-Line (Format-AzlClusterConnection -Connection $connection)
foreach ($note in $connection.Notes) { Write-Warning $note }
try { $nodes = @(Invoke-Remote '' $ReadNodes) }
catch { Write-Error "The cluster '$clusterName' could not be read: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
if ($nodes.Count -eq 0) { Add-Row $clusterName 'Nodes' 'Failed' 'no node is Up' }

foreach ($node in $nodes) {
    try {
        $agent = Invoke-Remote $node $ReadAgent
        if (-not $agent.Installed) { Add-Row $node 'Agent' 'Failed' 'the Azure Connected Machine agent is not installed' }
        elseif ($agent.Status -eq 'Connected') { Add-Row $node 'Agent' 'Passed' "Connected, last heartbeat $($agent.LastHeartbeat)" }
        elseif ($agent.Status -eq 'Disconnected') { Add-Row $node 'Agent' 'Failed' "Disconnected$(if ($agent.Error) { ': ' + $agent.Error })" }
        else { Add-Row $node 'Agent' 'Warning' "status $($agent.Status)" }
        if ($agent.Installed) {
            $extensionService = [string]$(if ($agent.ContainsKey('ExtensionService')) { $agent.ExtensionService } else { '' })
            if ($extensionService -eq 'Running') { Add-Row $node 'Extension service' 'Passed' 'Running' }
            elseif ($extensionService) { Add-Row $node 'Extension service' 'Failed' "the extension service (ExtensionService) of the Azure Connected Machine agent is $extensionService`: extensions are not installed, updated or removed while it does not run" }
            $badExtensions = @(@($agent.Extensions) | Where-Object { $_.State -notin 'success', 'Succeeded' })
            if (@($agent.Extensions).Count -eq 0) { Add-Row $node 'Extensions' 'Warning' 'the node has no extension' }
            elseif ($badExtensions.Count -gt 0) { Add-Row $node 'Extensions' 'Warning' (@($badExtensions | ForEach-Object { "$($_.Name) $($_.State)" }) -join ', ') }
            else { Add-Row $node 'Extensions' 'Passed' "$(@($agent.Extensions).Count) extension(s) report success" }
        }
    }
    catch { Add-Row $node 'Agent' 'Failed' "could not be read: $($_.Exception.Message)" }
    try {
        $probe = @(Invoke-Remote $node $ProbeEndpoint @(, @($targets | ForEach-Object { @{ Host = $_.Host; Port = $_.Port } })))
        $tier = @{}; foreach ($t in $targets) { $tier[[string]$t.Host] = [string]$t.Tier }
        $bad = @($probe | Where-Object { -not $_.Ok })
        $badRequired = @($bad | Where-Object { $tier[[string]$_.Host] -ne 'Optional' })
        if ($badRequired.Count -gt 0) { Add-Row $node 'Endpoints' 'Failed' "$($badRequired.Count) of $($probe.Count) required endpoints cannot be reached on 443: $(@($badRequired | ForEach-Object { "$($_.Host) ($($_.Error))" }) -join '; ')" }
        elseif ($bad.Count -gt 0) { Add-Row $node 'Endpoints' 'Warning' "optional endpoint(s) cannot be reached: $(@($bad | ForEach-Object { $_.Host }) -join ', ')" }
        else { Add-Row $node 'Endpoints' 'Passed' "all $($probe.Count) endpoints reachable on 443" }
    }
    catch { Add-Row $node 'Endpoints' 'Failed' "could not be probed: $($_.Exception.Message)" }
}

$failed = @($rows | Where-Object Status -EQ 'Failed').Count
$warnings = @($rows | Where-Object Status -EQ 'Warning').Count
Write-Line "Summary: $(@($rows | Where-Object Status -EQ 'Passed').Count) passed, $warnings warning(s), $failed failed."
if ($OutputPath) {
    try {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
        $file = Join-Path $OutputPath ('arc-connectivity-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
        Set-Content -LiteralPath $file -Value ([ordered]@{ Cluster = $clusterName; Location = $location; AtUtc = (Get-Date).ToUniversalTime().ToString('o'); Failed = $failed; Warnings = $warnings; Rows = @($rows) } | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM
        Write-Line "Results saved to $file"
    }
    catch { Write-Error "The results could not be saved to ${OutputPath}: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
}
$rows
if ($failed -gt 0) { exit 1 }
exit 0
