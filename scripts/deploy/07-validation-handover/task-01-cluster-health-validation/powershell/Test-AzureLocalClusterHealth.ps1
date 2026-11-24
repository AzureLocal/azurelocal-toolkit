<#
.SYNOPSIS
    Validates Azure Local cluster health and configuration. Read only.

.DESCRIPTION
    Stage 07 (validation and handover), task 01. Over PowerShell remoting the script asks a node of the cluster:
    - Cluster service status (and that the node asked is a node of cluster.name)
    - Node health
    - Storage Spaces Direct, storage pool and virtual disk health
    - Cluster network status
    - Quorum
    - Azure Arc agent status of every node that is Up (each node is asked at its own management address)

    Run it from the management host. Every question is asked on a node, so this host needs neither the failover clustering tools nor
    membership of the cluster's domain, and the cluster name need not resolve from it. The script asks nothing and changes nothing.

    Exit codes: 0 no check failed (warnings are listed); 1 a check failed or the cluster could not be reached; 2 cluster.name is
    missing or the file cannot be read.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Reads cluster.name (the cluster to validate), nodes[] (the management addresses to connect to)
    and identity.active_directory (the deployment user and its secret reference); the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to send the cluster questions to. Default: the first node of nodes[] that answers on WinRM at its management
    address; cluster.name when the file has no node address.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Default: the deployment (LCM) user of the file, its secret read through the
    toolkit's secret resolver; the account that runs the script when the file has none or the secret cannot be read.

.PARAMETER OutputFormat
    Output format: Console, JSON, or HTML. Default: Console

.PARAMETER OutputPath
    Folder to save the validation report in (for JSON/HTML output). Created when it does not exist.

.EXAMPLE
    .\Test-AzureLocalClusterHealth.ps1 -InfrastructureFile ./infrastructure.yml

.EXAMPLE
    .\Test-AzureLocalClusterHealth.ps1 -InfrastructureFile ./infrastructure.yml -OutputFormat HTML -OutputPath "C:\Reports"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 2.0.0
    Created: 2026-02-01
#>
#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read by the functions of the script.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names of the check functions inside the script.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Console", "JSON", "HTML")]
    [string]$OutputFormat = "Console",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'remoting', 'AzlClusterConnection.psm1'))) -Force

$script:ErrorCount = 0
function Write-Line {
    param([string]$Message, [string]$Level = 'INFO')
    if ($Level -eq 'ERROR') { $script:ErrorCount++ }
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SUCCESS' { 'Green' } default { 'White' } }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Error "Cannot read the infrastructure file: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
$ClusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
if (-not $ClusterName) { Write-Error 'cluster.name is missing in the infrastructure file. It is the name of the cluster to validate.' -ErrorAction Continue; exit 2 }
$connection = Resolve-AzlClusterConnection -Infrastructure $infra -ComputerName $ComputerName -Credential $Credential -RemoteCommand { param([hashtable]$Call) Invoke-Command @Call }
$script:Nodes = @()

# Initialize results collection
$ValidationResults = @{
    Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    ClusterName   = $ClusterName
    OverallStatus = "Unknown"
    Checks        = @()
}

function Add-ValidationResult {
    param(
        [string]$Category,
        [string]$Check,
        [string]$Status,
        [string]$Message,
        [object]$Details = $null
    )

    $script:ValidationResults.Checks += @{
        Category = $Category
        Check    = $Check
        Status   = $Status
        Message  = $Message
        Details  = $Details
    }

    $statusColor = switch ($Status) {
        "PASSED" { "Green" }
        "FAILED" { "Red" }
        "WARNING" { "Yellow" }
        default { "White" }
    }

    if ($OutputFormat -eq "Console") {
        Write-Host "  [$Status] $Category - $Check" -ForegroundColor $statusColor
        if ($Message) {
            Write-Host "         $Message" -ForegroundColor Gray
        }
    }
}

# The blocks that run on a node (Windows PowerShell): read only. They return plain values, so nothing depends on the failover clustering tools of this host.
$ReadCluster = { $c = Get-Cluster -ErrorAction Stop; @{ Name = [string]$c.Name; Domain = [string]$c.Domain } }
$ReadNodes = { @(Get-ClusterNode -ErrorAction Stop | ForEach-Object { @{ Name = [string]$_.Name; State = [string]$_.State } }) }
$ReadStorage = {
    $s2d = Get-ClusterStorageSpacesDirect -ErrorAction Stop
    @{
        S2dState = [string]$s2d.State
        Pools    = @(Get-StoragePool -IsPrimordial $false -ErrorAction Stop | ForEach-Object { @{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus } })
        BadDisks = @(Get-VirtualDisk -ErrorAction Stop | Where-Object { [string]$_.HealthStatus -ne 'Healthy' } | ForEach-Object { @{ FriendlyName = [string]$_.FriendlyName; HealthStatus = [string]$_.HealthStatus } })
    }
}
$ReadNetworks = { @(Get-ClusterNetwork -ErrorAction Stop | ForEach-Object { @{ Name = [string]$_.Name; State = [string]$_.State; Role = [string]$_.Role } }) }
$ReadQuorum = { $q = Get-ClusterQuorum -ErrorAction Stop; @{ Type = [string]$q.QuorumType; Resource = [string]$(if ($q.QuorumResource) { $q.QuorumResource.Name }) } }
$ReadArc = {
    $agentPath = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    if (Test-Path $agentPath) {
        $status = & $agentPath show --json 2>$null | ConvertFrom-Json
        return @{ Installed = $true; Status = [string]$status.status; LastHeartbeat = [string]$status.lastHeartbeat }
    }
    return @{ Installed = $false }
}

function Test-ClusterService {
    Write-Line -Message "Checking cluster service status..." -Level "INFO"

    try {
        $cluster = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadCluster
        if ($null -eq $cluster -or -not $cluster.Name) { throw 'the node returned no cluster' }
        if ([string]$cluster.Name -ne $ClusterName) {
            Add-ValidationResult -Category "Cluster" -Check "Cluster Service" `
                -Status "FAILED" -Message "The machine asked ($($connection.Target)) is a node of cluster '$($cluster.Name)', not of '$ClusterName' (cluster.name of the file)"
            return $false
        }

        Add-ValidationResult -Category "Cluster" -Check "Cluster Service" `
            -Status "PASSED" -Message "Cluster '$($cluster.Name)' is online" `
            -Details @{ Name = $cluster.Name; Domain = $cluster.Domain }
    }
    catch {
        Add-ValidationResult -Category "Cluster" -Check "Cluster Service" `
            -Status "FAILED" -Message "Cannot connect to cluster: $($_.Exception.Message)"
        return $false
    }

    return $true
}

function Test-ClusterNodes {
    Write-Line -Message "Checking cluster node health..." -Level "INFO"

    try {
        $script:Nodes = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadNodes)
        if ($script:Nodes.Count -eq 0) { Add-ValidationResult -Category "Nodes" -Check "Node Health" -Status "FAILED" -Message "The cluster lists no node" }

        foreach ($node in $script:Nodes) {
            $status = if ($node.State -eq "Up") { "PASSED" } else { "FAILED" }
            Add-ValidationResult -Category "Nodes" -Check "Node: $($node.Name)" `
                -Status $status -Message "State: $($node.State)" `
                -Details @{ Name = $node.Name; State = $node.State }
        }
    }
    catch {
        Add-ValidationResult -Category "Nodes" -Check "Node Health" `
            -Status "FAILED" -Message "Cannot retrieve node information: $($_.Exception.Message)"
    }
}

function Test-StorageSpacesDirect {
    Write-Line -Message "Checking Storage Spaces Direct health..." -Level "INFO"

    try {
        $storage = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadStorage

        $status = if ($storage.S2dState -eq "Enabled") { "PASSED" } else { "FAILED" }
        Add-ValidationResult -Category "Storage" -Check "Storage Spaces Direct" `
            -Status $status -Message $(if ($status -eq 'PASSED') { "S2D is enabled and running" } else { "S2D state: $($storage.S2dState)" }) `
            -Details @{ State = $storage.S2dState }

        foreach ($pool in @($storage.Pools)) {
            $status = if ($pool.Health -eq "Healthy") { "PASSED" } else { "FAILED" }
            Add-ValidationResult -Category "Storage" -Check "Pool: $($pool.Name)" `
                -Status $status -Message "Health: $($pool.Health)" `
                -Details @{ Name = $pool.Name; Health = $pool.Health }
        }

        $vDisks = @($storage.BadDisks)
        if ($vDisks.Count -eq 0) {
            Add-ValidationResult -Category "Storage" -Check "Virtual Disks" `
                -Status "PASSED" -Message "All virtual disks are healthy"
        }
        else {
            Add-ValidationResult -Category "Storage" -Check "Virtual Disks" `
                -Status "FAILED" -Message "$($vDisks.Count) unhealthy virtual disk(s): $(@($vDisks | ForEach-Object { "$($_.FriendlyName) $($_.HealthStatus)" }) -join ', ')" `
                -Details $vDisks
        }
    }
    catch {
        Add-ValidationResult -Category "Storage" -Check "Storage Spaces Direct" `
            -Status "FAILED" -Message "Cannot check S2D: $($_.Exception.Message)"
    }
}

function Test-ClusterNetworks {
    Write-Line -Message "Checking cluster network health..." -Level "INFO"

    try {
        foreach ($network in @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadNetworks)) {
            $status = if ($network.State -eq "Up") { "PASSED" } else { "FAILED" }
            Add-ValidationResult -Category "Network" -Check "Network: $($network.Name)" `
                -Status $status -Message "State: $($network.State), Role: $($network.Role)" `
                -Details @{ Name = $network.Name; State = $network.State; Role = $network.Role }
        }
    }
    catch {
        Add-ValidationResult -Category "Network" -Check "Cluster Networks" `
            -Status "FAILED" -Message "Cannot check networks: $($_.Exception.Message)"
    }
}

function Test-ClusterQuorum {
    Write-Line -Message "Checking cluster quorum..." -Level "INFO"

    try {
        $quorum = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadQuorum

        Add-ValidationResult -Category "Quorum" -Check "Quorum Configuration" `
            -Status "PASSED" -Message "Type: $($quorum.Type)$(if ($quorum.Resource) { ", witness: $($quorum.Resource)" })" `
            -Details @{ Type = $quorum.Type; Resource = $quorum.Resource }
    }
    catch {
        Add-ValidationResult -Category "Quorum" -Check "Quorum Configuration" `
            -Status "FAILED" -Message "Cannot check quorum: $($_.Exception.Message)"
    }
}

function Test-ArcConnection {
    Write-Line -Message "Checking Azure Arc connection status..." -Level "INFO"

    # Every node is asked from this host, at its management address of the file: a second hop from one node to another does not work.
    foreach ($node in @($script:Nodes | Where-Object { $_.State -eq 'Up' })) {
        $arcStatus = $null; $readError = ''
        try { $arcStatus = Invoke-AzlClusterCommand -Connection $connection -Node $node.Name -ScriptBlock $ReadArc }
        catch { $readError = $_.Exception.Message }

        if ($null -eq $arcStatus) {
            Add-ValidationResult -Category "Azure Arc" -Check "Node: $($node.Name)" -Status "FAILED" -Message "The Arc agent status could not be read from the node$(if ($readError) { ": $readError" })"
        }
        elseif ($arcStatus.Installed -and $arcStatus.Status -eq "Connected") {
            Add-ValidationResult -Category "Azure Arc" -Check "Node: $($node.Name)" `
                -Status "PASSED" -Message "Arc agent connected" `
                -Details $arcStatus
        }
        elseif ($arcStatus.Installed) {
            Add-ValidationResult -Category "Azure Arc" -Check "Node: $($node.Name)" `
                -Status "WARNING" -Message "Arc agent status: $($arcStatus.Status)" `
                -Details $arcStatus
        }
        else {
            Add-ValidationResult -Category "Azure Arc" -Check "Node: $($node.Name)" `
                -Status "FAILED" -Message "Arc agent not installed"
        }
    }
}

function Export-Results {
    # Calculate overall status
    $failedCount = @($ValidationResults.Checks | Where-Object { $_.Status -eq "FAILED" }).Count
    $warningCount = @($ValidationResults.Checks | Where-Object { $_.Status -eq "WARNING" }).Count

    if ($failedCount -gt 0) {
        $ValidationResults.OverallStatus = "FAILED"
    }
    elseif ($warningCount -gt 0) {
        $ValidationResults.OverallStatus = "WARNING"
    }
    else {
        $ValidationResults.OverallStatus = "PASSED"
    }

    if ($OutputFormat -eq 'Console') { return }
    if ($OutputPath -and -not (Test-Path -LiteralPath $OutputPath)) { $null = New-Item -ItemType Directory -Path $OutputPath -Force }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    switch ($OutputFormat) {
        "JSON" {
            $jsonPath = if ($OutputPath) { Join-Path $OutputPath "cluster-health-$stamp.json" } else { "cluster-health-$stamp.json" }
            $ValidationResults | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath
            Write-Line -Message "Report saved to: $jsonPath" -Level "INFO"
        }
        "HTML" {
            $htmlPath = if ($OutputPath) { Join-Path $OutputPath "cluster-health-$stamp.html" } else { "cluster-health-$stamp.html" }
            $encode = { param($Text) [System.Net.WebUtility]::HtmlEncode([string]$Text) }
            $html = "<html><head><title>Cluster Health Report</title></head><body>"
            $html += "<h1>Cluster Health Report: $(& $encode $ClusterName)</h1>"
            $html += "<p>Generated: $($ValidationResults.Timestamp)</p>"
            $html += "<p>Overall Status: <strong>$($ValidationResults.OverallStatus)</strong></p>"
            $html += "<table border='1'><tr><th>Category</th><th>Check</th><th>Status</th><th>Message</th></tr>"
            foreach ($check in $ValidationResults.Checks) {
                $color = switch ($check.Status) { "PASSED" { "green" }; "FAILED" { "red" }; default { "orange" } }
                $html += "<tr><td>$(& $encode $check.Category)</td><td>$(& $encode $check.Check)</td><td style='color:$color'>$($check.Status)</td><td>$(& $encode $check.Message)</td></tr>"
            }
            $html += "</table></body></html>"
            $html | Set-Content -Path $htmlPath
            Write-Line -Message "Report saved to: $htmlPath" -Level "INFO"
        }
    }
}

# Main execution
try {
    Write-Line -Message "Starting Cluster Health Validation" -Level "INFO"
    Write-Line -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Line -Message (Format-AzlClusterConnection -Connection $connection) -Level "INFO"
    foreach ($note in $connection.Notes) { Write-Line -Message $note -Level "WARN" }
    Write-Line -Message "========================================" -Level "INFO"

    # Run all validation checks
    $clusterOk = Test-ClusterService

    if ($clusterOk) {
        Test-ClusterNodes
        Test-StorageSpacesDirect
        Test-ClusterNetworks
        Test-ClusterQuorum
        Test-ArcConnection
    }

    # Export results
    Export-Results

    # Summary
    Write-Host ""
    Write-Line -Message "========================================" -Level "INFO"

    $passed = @($ValidationResults.Checks | Where-Object { $_.Status -eq "PASSED" }).Count
    $failed = @($ValidationResults.Checks | Where-Object { $_.Status -eq "FAILED" }).Count
    $warnings = @($ValidationResults.Checks | Where-Object { $_.Status -eq "WARNING" }).Count

    Write-Line -Message "Validation Complete" -Level "INFO"
    Write-Host "  Passed:   $passed" -ForegroundColor Green
    Write-Host "  Warnings: $warnings" -ForegroundColor Yellow
    Write-Host "  Failed:   $failed" -ForegroundColor Red

    if ($failed -gt 0) {
        Write-Line -Message "Overall Status: FAILED" -Level "ERROR"
        exit 1
    }
    elseif ($warnings -gt 0) {
        Write-Line -Message "Overall Status: WARNING" -Level "WARN"
        exit 0
    }
    else {
        Write-Line -Message "Overall Status: PASSED" -Level "SUCCESS"
        exit 0
    }
}
catch {
    Write-Line -Message "Validation failed: $_" -Level "ERROR"
    exit 1
}
