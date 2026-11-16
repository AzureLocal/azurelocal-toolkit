<#
.SYNOPSIS
    Tests the Azure Arc side of every Azure Local node from the node: the agent, its extensions and the endpoints it must reach. Read only.

.DESCRIPTION
    Stage 07 (validation and handover), task 02. Over PowerShell remoting the script asks every cluster node that is Up (Microsoft Learn: Azure Connected Machine agent
    CLI reference, azcmagent show, azcmagent extension list; Firewall requirements for Azure Local):

      Agent       is the Azure Connected Machine agent installed, and does azcmagent show report the status Connected (Disconnected is a failure, anything else a warning);
      Extensions  the extensions of the Arc machine as the agent lists them: a provisioning state other than Succeeded is a warning;
      Endpoints   can the node open a TCP connection on 443 to every host of the one documented endpoint list of the toolkit (Arc, authentication, management and data plane
                  groups of AzlVerification.Endpoints.psm1, for the region azure.location). A required host that cannot be reached is a failure, an optional one a warning.

    The Azure side of the same question (the Arc machines, their status, the extensions and the identity as Azure Resource Manager shows them) is stage 04, phase 04, task 04
    (Test-ArcRegistration.azcli.ps1). This script does not sign in to Azure and calls no Azure command, so the task has no Azure CLI script of its own.

    The script changes nothing. It connects as the account that runs it, or as -Credential. It asks nothing.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure): cluster.name (the cluster to ask), azure.location (the region of the endpoint list).

    Exit codes: 0 no check failed (warnings are listed); 1 a check failed or the cluster could not be read; 2 cluster.name or azure.location is missing, or the file cannot be read.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Reads cluster.name and azure.location; the whole file is not validated here.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Without it the account that runs the script is used.

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
    [pscredential]$Credential,
    [string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$remoteCredential = $Credential

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common'))
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'arm-deployment', 'verification', 'AzlVerification.Endpoints.psm1')) -Force

function Write-Line([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }

function Invoke-Remote([string]$Computer, [scriptblock]$Block, [object[]]$Arguments = @()) {
    $call = @{ ComputerName = $Computer; ScriptBlock = $Block; ErrorAction = 'Stop' }
    if ($Arguments.Count -gt 0) { $call.ArgumentList = $Arguments }
    if ($remoteCredential) { $call.Credential = $remoteCredential }
    Invoke-Command @call
}

# The blocks that run on the nodes (Windows PowerShell): read only.
$ReadNodes = { @(Get-ClusterNode | Where-Object { [string]$_.State -eq 'Up' } | ForEach-Object { [string]$_.Name }) }
$ReadAgent = {
    $agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
    if (-not (Test-Path -LiteralPath $agent)) { return @{ Installed = $false } }
    $show = (& $agent show --json 2>&1 | Out-String) | ConvertFrom-Json
    $extensions = @()
    $listing = (& $agent extension list --json 2>&1 | Out-String).Trim()
    if ($listing.StartsWith('[')) { $extensions = @($listing | ConvertFrom-Json | ForEach-Object { @{ Name = [string]$_.name; State = [string]$_.provisioningState } }) }
    @{ Installed = $true; Status = [string]$show.status; Error = [string]$show.agentErrorMessage; LastHeartbeat = [string]$show.lastHeartbeat; Extensions = $extensions }
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

Write-Line "Azure Arc validation from the nodes of cluster '$clusterName' (region $location, $($targets.Count) endpoints)"
try { $nodes = @(Invoke-Remote $clusterName $ReadNodes) }
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
            $badExtensions = @(@($agent.Extensions) | Where-Object { $_.State -ne 'Succeeded' })
            if (@($agent.Extensions).Count -eq 0) { Add-Row $node 'Extensions' 'Warning' 'the agent lists no extension' }
            elseif ($badExtensions.Count -gt 0) { Add-Row $node 'Extensions' 'Warning' (@($badExtensions | ForEach-Object { "$($_.Name) $($_.State)" }) -join ', ') }
            else { Add-Row $node 'Extensions' 'Passed' "$(@($agent.Extensions).Count) extension(s) Succeeded" }
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
