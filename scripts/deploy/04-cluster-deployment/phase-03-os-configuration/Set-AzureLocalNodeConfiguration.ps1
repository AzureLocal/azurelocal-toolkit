#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 03, OS configuration, for schema 5: reads each node, changes only what differs from infrastructure.yml, and reports.

.DESCRIPTION
    Runs after azurelocal-ztp has handed off provisioned machines (or after an ISO install). For every node it reads the
    current state first and compares it with what infrastructure.yml says:

      RemoteManagement  WinRM, RDP, ICMP echo
      Sbe               the OEM's SBE package (hardware.sbe.bundle_path) in C:\SBE, SHA-256 checked
      Drivers           the OEM's network drivers from that package, for the ports that need them
      Network           DHCP off on every port whose ip_assignment is none (so only the management port has a default
                        gateway); the management port's static address, found by MAC and set only if wrong
      Dns, Time         DNS servers on the management port; NTP peers
      Hostname          the computer name (needs a restart)
      UnusedAdapters    ports marked unused are disabled
      LocalAdmin        identity.local_admin as a local administrator (never the built-in Administrator)
      Mpio              SAN only: MultipathIO, the array's MSDSM hardware ID, load balance policy, MPIO settings
      SanVerify         SAN only, read only: FC ports and WWPNs, the infrastructure and performance history LUNs
                        (visible, RAW, big enough, two or more paths)
      ClearStorage      leftover local storage; wiped only with -ClearStorage -Execute

    Without -Execute it is a plan: one read-only script per node, then a table of what it would change. With -Execute it
    changes only the items marked Change, reads again, and repeats until the node matches (at most -MaxPasses). Re-running
    it on a configured node changes nothing and runs no change script on the node.

    Transport. The operator host usually has no path to the nodes' management subnet, so the default is Azure Arc Run
    Command (Microsoft.HybridCompute/machines/{name}/runCommands): the script goes through ARM to the Connected Machine
    agent. Plan mode creates and deletes a transient run command resource per read. -Transport WinRM runs the same scripts over
    a PSSession from a host that can reach the nodes.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).
.PARAMETER HandoffFile
    azurelocal-ztp's ztp-handoff.json (schema 2). Optional: it supplies the Arc machine resource IDs, the installed build
    and each node's managementAddressVerified. Without it the Arc machines are found by name in azure.resource_group.
.PARAMETER Node
    Node names to configure. Default: every node in the file.
.PARAMETER Transport
    Auto (default; Arc Run Command, WinRM when -Credential is given and no Arc machine is found), ArcRunCommand or WinRM.
.PARAMETER Credential
    The nodes' local administrator, for -Transport WinRM.
.PARAMETER StagingStorageAccount
    Storage account (name) for staging the SBE package to nodes over the Arc path; the node downloads it with a read-only
    SAS. Needed only when a node doesn't hold the package yet. You need Storage Blob Data Contributor on it.
.PARAMETER Step
    Limit the run to these steps. Default: all.
.PARAMETER NodeAddress
    -Transport WinRM only: node name -> the address to open the session to (default: the management address in the file). A node installed
    from an ISO may still hold the address the installer gave it.
.PARAMETER RetryTries
    How many times a node script is tried when its Arc run command ends in state Unknown (default 3, with a growing pause).
.PARAMETER ClearStorage
    Treat leftover local storage as a change (destroys data on local disks; never SAN LUNs). With -Execute.
.PARAMETER NoRestart
    Don't restart a node that needs it (hostname, MPIO, a driver); the report says which need one.
.PARAMETER SpecOnly
    Print what each node should look like and stop. Reads only the files (and the SBE folder); touches no node, no Azure resource and no Key Vault.
.PARAMETER ReportPath
    Where to write the JSON report (plan, changes, ports by MAC with their OS names, SAN disks). The ARM parameter
    generator reads it. Default: the temp folder.
.PARAMETER Execute
    Make the changes. Without it nothing on the node changes.
.EXAMPLE
    ./Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json
.EXAMPLE
    ./Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -StagingStorageAccount stazlstaging -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$HandoffFile,
    [string[]]$Node,
    [ValidateSet('Auto', 'ArcRunCommand', 'WinRM')][string]$Transport = 'Auto',
    [pscredential]$Credential,
    [string]$StagingStorageAccount,
    [string]$StagingContainer = 'azl-staging',
    [ValidateSet('RemoteManagement', 'Sbe', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage')][string[]]$Step,
    [switch]$ClearStorage,
    [hashtable]$NodeAddress,
    [ValidateRange(1, 10)][int]$RetryTries = 3,
    [int[]]$RetryDelaySeconds = @(15, 45, 120),
    [switch]$NoRestart,
    [switch]$SkipValidation,
    [switch]$OfflineManifest,
    [switch]$SpecOnly,
    [int]$MaxPasses = 3,
    [string]$ReportPath,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common'))
Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodeConfiguration.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodeTransport.psm1') -Force

function Write-Line([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }

Set-AzlNodeRetryPolicy -Tries $RetryTries -DelaySeconds $RetryDelaySeconds
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation:$SkipValidation
$handoff = if ($HandoffFile) { Read-AzlHandoff -Path $HandoffFile } else { $null }
$allSteps = @('RemoteManagement', 'Sbe', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage')
$steps = if ($Step) { $Step } else { $allSteps }

$nodes = @($infra.nodes | Where-Object { -not $Node -or $_.name -in $Node })
if ($Node) { foreach ($n in $Node) { if ($n -notin @($infra.nodes | ForEach-Object { $_.name })) { throw "Node $n isn't in $InfrastructureFile. Nodes there: $(@($infra.nodes | ForEach-Object { $_.name }) -join ', ')." } } }

# ---- the SBE package, checked before any node is touched
$bundle = $null
$bundlePath = Get-AzlProp $infra 'hardware.sbe.bundle_path'
if ($bundlePath -and -not $SpecOnly -and ('Sbe' -in $steps -or 'Drivers' -in $steps)) {
    $oem = Get-AzlOemConfig -Vendor ([string](Get-AzlProp $infra 'hardware.vendor' 'Dell'))
    $bundle = Get-AzlSbeBundle -Path $bundlePath -ManifestUrl ([string]$oem.sbe.discoveryManifestUrl) -OfflineManifest:$OfflineManifest
    Write-Line "SBE $($bundle.Name): SHA-256 matches $($bundle.HashSource)."
}
elseif (-not $bundlePath) { Write-Line 'hardware.sbe.bundle_path is not set: the SBE and the OEM drivers are skipped.' }

$specs = foreach ($n in $nodes) { Get-AzlNodeSpec -Infrastructure $infra -Node $n -Handoff $handoff -SbeBundle $bundle }

if ($SpecOnly) {
    foreach ($s in $specs) {
        Write-Line "== $($s.Name) (Arc machine $($s.ArcMachineName); handoff $(if ($s.Handoff.Present) { "verified=$($s.Handoff.ManagementAddressVerified)" } else { 'none' }))"
        Write-Line "   management: MAC $($s.Management.Mac)  $($s.Management.Mode)  $($s.Management.Ip)/$($s.Management.Prefix) gw $($s.Management.Gateway) dns $($s.Management.Dns -join ',') vlan $($s.Management.Vlan)"
        foreach ($p in $s.Ports) { Write-Line "   port $($p.Name)  $($p.Mac)  $($p.IpAssignment)  roles $($p.Roles -join ',')" }
        Write-Line "   ntp $($s.Ntp -join ',')  local admin $($s.LocalAdmin.Username)  SAN $(if ($s.San) { "$($s.San.Type) $($s.San.Vendor) $($s.San.Model)" } else { 'no' })"
    }
    return
}

# ---- the transport
if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue) -and $Transport -ne 'WinRM') { throw 'Az.Accounts is needed for Azure Arc Run Command. Install-Module Az.Accounts, then Connect-AzAccount.' }
$subscription = [string](Get-AzlProp $infra 'azure.subscription_id')
$resourceGroup = [string](Get-AzlProp $infra 'azure.resource_group')
$arcIds = @{}
if ($Transport -ne 'WinRM') {
    if (-not (Get-AzContext)) { throw 'Not signed in to Azure. Run Connect-AzAccount (the account needs Azure Connected Machine Resource Administrator on the Arc machines).' }
    foreach ($s in $specs) {
        $found = Find-AzlArcMachine -ArcMachineName $s.ArcMachineName -HostName $s.Name -SubscriptionId $subscription -ResourceGroup $resourceGroup -ResourceId $s.ArcResourceId
        if ($found) { $arcIds[$s.Name] = $found.ResourceId; Write-Line "$($s.Name): Arc machine $($found.Name) ($($found.Status))."; if ($found.Status -and $found.Status -ne 'Connected') { Write-Warning "$($s.Name): its Arc machine reports '$($found.Status)'." } }
        else { Write-Warning "$($s.Name): no Arc machine named $($s.ArcMachineName), or reporting host name $($s.Name), in $resourceGroup." }
    }
}
$useArc = $Transport -eq 'ArcRunCommand' -or ($Transport -eq 'Auto' -and $arcIds.Count -eq $specs.Count)
if ($useArc) {
    if ($arcIds.Count -ne $specs.Count) { throw 'Not every node has an Arc machine, so the Arc Run Command transport can''t reach all of them.' }
    $nodeTransport = New-AzlArcRunCommandTransport -ArcResourceId $arcIds -StagingStorageAccount $StagingStorageAccount -StagingContainer $StagingContainer
}
else {
    if (-not $Credential) { throw 'The WinRM transport needs -Credential (the nodes'' local administrator).' }
    $addresses = @{}
    foreach ($s in $specs) { $addresses[$s.Name] = if ($NodeAddress -and $NodeAddress.ContainsKey($s.Name)) { [string]$NodeAddress[$s.Name] } else { $s.Management.Ip } }
    $nodeTransport = New-AzlWinRmTransport -Address $addresses -Credential $Credential
}
Write-Line "Transport: $($nodeTransport.Kind). $(if ($Execute) { 'EXECUTE: changes will be made.' } else { 'Plan only: nothing on the nodes changes. Add -Execute.' })"

# ---- the nodes
$results = foreach ($s in $specs) {
    Write-Line "== $($s.Name)"
    Invoke-AzlNodeConfiguration -Spec $s -Transport $nodeTransport -Execute:$Execute -Step $steps -ClearStorage:$ClearStorage -NoRestart:$NoRestart -MaxPasses $MaxPasses
}
foreach ($r in $results) {
    Write-Line (Format-AzlPlan -Plan @($r.Plan | Where-Object { $_.Action -ne 'Ok' -or -not $Execute }))
    foreach ($c in $r.Changes) { Write-Line "   [$($c.Status)] $($c.Id): $($c.Detail)" }
}

# ---- every node must see the same SAN disks
$sanProblems = @()
if ((Get-AzlProp $infra 'scenario.storage_architecture' 's2d') -eq 'san') {
    $sets = @{}
    foreach ($r in $results) { $sets[$r.Node] = @(Get-AzlProp $r.State 'san.disks' @() | ForEach-Object { $_.uid } | Sort-Object) -join ',' }
    if (@($sets.Values | Select-Object -Unique).Count -gt 1) { $sanProblems += "The nodes don't see the same SAN disks (UniqueIds differ): $(($sets.GetEnumerator() | ForEach-Object { "$($_.Key)=[$($_.Value)]" }) -join '; ')" }
}
foreach ($p in $sanProblems) { Write-Warning $p }

# ---- the report the ARM parameter generator reads
if (-not $ReportPath) { $ReportPath = Join-Path ([IO.Path]::GetTempPath()) ("azl-osconfig-{0}-{1:yyyyMMddHHmmss}.json" -f (Get-AzlProp $infra 'cluster.name' 'cluster'), (Get-Date)) }
$report = [ordered]@{
    schemaVersion = 1
    generatedUtc  = [datetime]::UtcNow.ToString('o')
    executed      = [bool]$Execute
    transport     = $nodeTransport.Kind
    sanProblems   = $sanProblems
    nodes         = @($results | ForEach-Object {
            [ordered]@{
                name      = $_.Node
                hostname  = [string](Get-AzlProp $_.State 'host' '')
                osVersion = [string](Get-AzlProp $_.State 'os' '')
                converged = $_.Converged
                restarted = $_.Restarted
                ports     = @(Get-AzlProp $_.State 'nics' @() | ForEach-Object { [ordered]@{ osName = $_.n; mac = $_.mac; status = $_.st } })
                sanDisks  = @(Get-AzlProp $_.State 'san.disks' @())
                fcPorts   = @(Get-AzlProp $_.State 'san.fc' @())
                changes   = @($_.Changes)
                plan      = @($_.Plan | ForEach-Object { [ordered]@{ step = $_.Step; item = $_.Item; current = $_.Current; desired = $_.Desired; action = $_.Action; note = $_.Note } })
            }
        })
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
Write-Line "Report: $ReportPath"

$blocked = @($results | ForEach-Object { $_.Blocked })
$notConverged = @($results | Where-Object { $Execute -and -not $_.Converged })
$pending = @($results | ForEach-Object { $_.Plan } | Where-Object { $_.Action -eq 'Change' })
if ($blocked.Count -or $notConverged.Count -or $sanProblems.Count) {
    Write-Line "NOT READY: $($blocked.Count) blocked item(s), $($notConverged.Count) node(s) not converged."
    exit 1
}
if (-not $Execute) { Write-Line "Plan: $($pending.Count) change(s) needed across $($results.Count) node(s)." }
else { Write-Line "All $($results.Count) node(s) match infrastructure.yml. $(if (@($results | Where-Object Restarted).Count) { 'Some restarted.' })" }
$results
