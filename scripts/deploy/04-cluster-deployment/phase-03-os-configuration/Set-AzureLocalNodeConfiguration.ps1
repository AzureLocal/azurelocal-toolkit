#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 03, OS configuration, for schema 5: reads each node, changes only what differs from infrastructure.yml, and reports.

.DESCRIPTION
    Runs after azurelocal-ztp has handed off provisioned machines (or after an ISO install). For every node it reads the
    current state first and compares it with what infrastructure.yml says:

      RemoteManagement  WinRM, RDP, ICMP echo
      Drivers           the OEM's network drivers from that package, for the ports that need them
      Network           DHCP off on every port whose ip_assignment is none (so only the management port has a default
                        gateway); the management port's static address, found by MAC and set only if wrong
      Dns, Time         DNS servers on the management port; NTP peers
      Hostname          the computer name (needs a restart)
      UnusedAdapters    ports marked unused are disabled
      DomainJoin        Active Directory designs only: joins the node to identity.active_directory.domain_fqdn, in ou_path, with
                        domain_join_account (after Network, Dns, Time and Hostname; a guarded restart and a check follow). A node
                        of a local identity design gets an explicit 'not applicable: local identity' item.
      LocalAdmin        identity.local_admin as a local administrator (never the built-in Administrator)
      Mpio              SAN only: MultipathIO, the array's MSDSM hardware ID, load balance policy, MPIO settings
      SanVerify         SAN only, read only: FC ports and WWPNs, the infrastructure and performance history LUNs
                        (visible, RAW, big enough, two or more paths)
      ClearStorage      leftover local storage; wiped only with -ClearStorage -Execute
      Sbe               LAST. The OEM's SBE package (hardware.sbe.bundle_path) in C:\SBE, SHA-256 checked. How it reaches a node is
                        hardware.sbe.delivery: winrm_copy, node_pull or skip (default; reports 'not delivered', changes nothing, and
                        never stops the other steps). The drivers install from it, in the pass after it has landed.

    Without -Execute it is a plan: one read-only script per node, then a table of what it would change. With -Execute it
    changes only the items marked Change, reads again, and repeats until the node matches (at most -MaxPasses). Re-running
    it on a configured node changes nothing and runs no change script on the node.

    Transport. PowerShell remoting (WinRM) is the default and the only automatic choice: run it from a jump server on the management network, or from
    a CI runner that has a route to it. Every node is probed first (all nodes at the same time) and one table says which is unreachable and why. There is no
    silent fallback to Arc. -Transport ArcRunCommand (Microsoft.HybridCompute/machines/{name}/runCommands) stays available when asked for, as the exception for
    sites with no route; it is not recommended for network changes. With -Settings @{ remoting = @{ bootstrapTransport = 'arc' } } Arc is used ONCE per node, only
    to open the node firewall for WinRM (and RDP, ICMP) for the source CIDRs; everything else then goes over WinRM.

    A change that can cut the node off (management address, gateway, DNS, VLAN, remote-management firewall rules, time, DHCP-off on other ports, disabled adapters, the
    computer name) is a GUARDED change: staged on the node, applied there, checked there, committed only after this host confirms it through a new session, and
    rolled back by the node when it is not. See docs/os-configuration-and-arm-deployment.md, 'Changing the management address safely'.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).
.PARAMETER HandoffFile
    azurelocal-ztp's ztp-handoff.json (schema 2). Optional: it supplies the Arc machine resource IDs, the installed build
    and each node's managementAddressVerified. Without it the Arc machines are found by name in azure.resource_group.
.PARAMETER Node
    Node names to configure. Default: every node in the file.
.PARAMETER Transport
    Auto (default: WinRM, or what -Settings remoting.transport / os_configuration.remoting.transport say), WinRM, or ArcRunCommand (only when you pass it).
.PARAMETER Credential
    The nodes' local administrator: for -Transport WinRM, and for copying the SBE package over WinRM (hardware.sbe.delivery winrm_copy) when the other steps go over Arc.
    Without it identity.local_admin from the master file is used, with its password read from the Key Vault (never printed). Run from a host that reaches the nodes'
    management subnet on TCP 5985 (5986 with -UseSsl).
.PARAMETER UseSsl
    WinRM over HTTPS (TCP 5986) with a full certificate check; a node needs a listener with a certificate. The remote management profile (scenario.environment_class) decides which endpoint the OS configuration run uses and passes this switch.
.PARAMETER Authentication
    Default, Negotiate (default), Kerberos, Basic or CredSSP. From a Linux runner Negotiate and Kerberos need PSWSMan. A workgroup node needs TrustedHosts or HTTPS.
.PARAMETER Settings
    networkRollbackMinutes (10), networkStableSeconds (60), reconnectWaitMinutes (15), staleRunCommandMinutes (15), addressProbe (true), remoting = @{ transport; bootstrapTransport; allowedSourceCidrs; useSsl; authentication }.
.PARAMETER EventLogPath
    Append the OS configuration events (the guarded-change and transport events, and the events of the one-run command) here (JSON Lines).
.PARAMETER Step
    Limit the run to these steps. Default: all.
.PARAMETER NodeAddress
    Node name -> the address to open the session to first (default: the management address in the file, then the maintenance address, then the address the Arc agent reports).
    A node installed from an ISO may still hold the address the installer gave it. The winrm_copy of the SBE package uses it too.
.PARAMETER RetryTries
    How many times a node script is tried when its Arc run command ends in state Unknown (default 3, with a growing pause).
.PARAMETER ClearStorage
    Treat leftover local storage as a change (destroys data on local disks; never SAN LUNs). With -Execute. A node that belongs to a deployed cluster
    (HKLM:\Cluster, the Cluster service, a clustered pool or CSV) is Blocked, and the node-side clear refuses it too, unless -ConfirmWipeDeployedCluster is given.
.PARAMETER ApprovedBootstrap
    The pipeline approval of the one-time Arc bootstrap (remoting.bootstrapTransport arc). The environment class decides whether it is needed: lab, test and dev need none,
    production needs it, dmz on every run. Without a needed approval nothing is opened on a node.
.PARAMETER ReconcileChangeId
    Guarded changes whose outcome an earlier call could not read (state Unknown). Each is read once, read only (no confirmation is sent), and the report lists its state
    under pendingGuard. A node is converged only when every one of them is Committed.
.PARAMETER RunId
    The id of the run this call belongs to; written on every event line (runId) next to a sequence number (seq). Default: a new id.
.PARAMETER ConfirmWipeDeployedCluster
    One-shot, per run, never read from a file: lets -ClearStorage wipe a node that belongs to a deployed cluster.
.PARAMETER ApprovedWipeId
    Hashtable: node name -> the disks (serial, else unique id) approved for that node. A leftover disk that is not in the node's list blocks the wipe, and only the listed
    disks are named in the clear. Without it the plan of this call is the list.
.PARAMETER NoRestart
    Don't restart a node that needs it (hostname, MPIO, a driver); the report says which need one.
.PARAMETER EventMethod
    Ztp or Iso: the method of the node, written on every event of the feed this run appends (-EventLogPath). Optional.
.PARAMETER EventPhase
    Plan, Apply or Verify: the pass of the one-run command this call belongs to. Optional.
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
    ./Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password was just read from the Key Vault and only lives in memory; WinRM needs a PSCredential.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$HandoffFile,
    [string[]]$Node,
    [ValidateSet('Auto', 'ArcRunCommand', 'WinRM')][string]$Transport = 'Auto',
    [pscredential]$Credential,
    [switch]$UseSsl,
    [ValidateSet('Default', 'Negotiate', 'Kerberos', 'Basic', 'CredSSP')][string]$Authentication,
    [hashtable]$Settings,
    [string]$EventLogPath,
    [ValidateSet('RemoteManagement', 'Sbe', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'DomainJoin', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage')][string[]]$Step,
    [switch]$ClearStorage,
    [switch]$ConfirmWipeDeployedCluster,
    [hashtable]$ApprovedWipeId,
    [switch]$ApprovedBootstrap,
    [string[]]$ReconcileChangeId,
    [string]$RunId,
    [hashtable]$NodeAddress,
    [ValidateSet('', 'Ztp', 'Iso')][string]$EventMethod = '',
    [ValidateSet('', 'Plan', 'Apply', 'Verify')][string]$EventPhase = '',
    [ValidateRange(1, 10)][int]$RetryTries = 3,
    [int[]]$RetryDelaySeconds = @(15, 45, 120),
    [switch]$NoRestart,
    [switch]$SkipValidation,
    [switch]$OfflineManifest,
    [switch]$SpecOnly,
    [int]$MaxPasses = 6,
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
Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlGuardedChange.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlRemoting.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'remoting') 'AzlRemotingProfile.psm1') -Force

function Write-Line([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }

# One run id on every event line: the wrapper's, else a new one for this call.
if ($RunId) { $env:AZL_OSCONFIG_RUN_ID = $RunId } elseif (-not $env:AZL_OSCONFIG_RUN_ID) { $env:AZL_OSCONFIG_RUN_ID = '{0:yyyyMMddTHHmmssZ}-{1}' -f [datetime]::UtcNow, [guid]::NewGuid().ToString('N').Substring(0, 6) }

Set-AzlNodeRetryPolicy -Tries $RetryTries -DelaySeconds $RetryDelaySeconds
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation:$SkipValidation
if (-not $ReportPath) { $ReportPath = Join-Path ([IO.Path]::GetTempPath()) ("azl-osconfig-{0}-{1:yyyyMMddHHmmss}.json" -f (Get-AzlProp $infra 'cluster.name' 'cluster'), (Get-Date)) }
$handoff = if ($HandoffFile) { Read-AzlHandoff -Path $HandoffFile } else { $null }
# The remote management profile of the class (missing class = production). Printed first; TrustedHosts on this machine is managed by Invoke-AzureLocalOsConfiguration.ps1, not here.
$remotingProfile = Resolve-AzlRemotingProfile -Infrastructure $infra -Override (ConvertTo-AzlRemotingProfileOverride -Setting $Settings)
foreach ($line in @(Format-AzlRemotingProfile -RemotingProfile $remotingProfile)) { Write-Line $line }
Assert-AzlRemotingProfile -RemotingProfile $remotingProfile
$allSteps = @('RemoteManagement', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'DomainJoin', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe')
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

$specs = foreach ($n in $nodes) { Get-AzlNodeSpec -Infrastructure $infra -Node $n -Handoff $handoff -SbeBundle $bundle -RemotingProfile $remotingProfile }

if ($SpecOnly) {
    foreach ($s in $specs) {
        Write-Line "== $($s.Name) (Arc machine $($s.ArcMachineName); handoff $(if ($s.Handoff.Present) { "verified=$($s.Handoff.ManagementAddressVerified)" } else { 'none' }))"
        Write-Line "   management: MAC $($s.Management.Mac)  $($s.Management.Mode)  $($s.Management.Ip)/$($s.Management.Prefix) gw $($s.Management.Gateway) dns $($s.Management.Dns -join ',') vlan $($s.Management.Vlan)"
        foreach ($p in $s.Ports) { Write-Line "   port $($p.Name)  $($p.Mac)  $($p.IpAssignment)  roles $($p.Roles -join ',')" }
        Write-Line "   ntp $($s.Ntp -join ',')  local admin $($s.LocalAdmin.Username)  SAN $(if ($s.San) { "$($s.San.Type) $($s.San.Vendor) $($s.San.Model)" } else { 'no' })"
    }
    return
}

# ---- the transport: PowerShell remoting (WinRM) unless Arc Run Command was asked for. There is no silent fallback to Arc.
$remoting = Get-AzlRemotingSetting -Infrastructure $infra -Setting $Settings -Transport $Transport -UseSsl:$UseSsl -Authentication $Authentication
# The environment class decides HTTP or HTTPS (production, dev and dmz use HTTPS). An explicit -UseSsl does too.
if ($remotingProfile.Transport.Scheme -eq 'https' -and -not $remoting.UseSsl) { $remoting.UseSsl = $true; $remoting.Port = 5986 }
$eventContext = New-AzlGuardEventContext -Path $EventLogPath -SchemaVersion ([string](Get-AzlProp $infra '_metadata.schema_version' '')) -Method $EventMethod -Phase $EventPhase
$subscription = [string](Get-AzlProp $infra 'azure.subscription_id')
$resourceGroup = [string](Get-AzlProp $infra 'azure.resource_group')
$azureSignedIn = [bool]((Get-Command Get-AzContext -ErrorAction SilentlyContinue) -and (Get-AzContext -ErrorAction SilentlyContinue))
$needArc = $remoting.Kind -eq 'ArcRunCommand' -or $remoting.BootstrapTransport -eq 'arc'
$arcIds = @{}
$arcMachines = @{}
if ($needArc -and -not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) { throw 'Az.Accounts is needed for Azure Arc Run Command (the explicit -Transport ArcRunCommand, or remoting.bootstrapTransport arc). Install-Module Az.Accounts, then Connect-AzAccount.' }
if ($needArc -and -not $azureSignedIn) { throw 'Not signed in to Azure. Run Connect-AzAccount (the account needs Azure Connected Machine Resource Administrator on the Arc machines).' }
if ($azureSignedIn) {
    foreach ($s in $specs) {
        try { $found = Find-AzlArcMachine -ArcMachineName $s.ArcMachineName -HostName $s.Name -SubscriptionId $subscription -ResourceGroup $resourceGroup -ResourceId $s.ArcResourceId }
        catch { $found = $null; if ($needArc) { throw } }
        if ($found) { $arcIds[$s.Name] = $found.ResourceId; $arcMachines[$s.Name] = $found; if ($needArc) { Write-Line "$($s.Name): Arc machine $($found.Name) ($($found.Status))." } }
        elseif ($needArc) { Write-Warning "$($s.Name): no Arc machine named $($s.ArcMachineName), or reporting host name $($s.Name), in $resourceGroup." }
    }
}

$nodeTransports = @{}
$bootstrapRecords = @{}
if ($remoting.Kind -eq 'ArcRunCommand') {
    if ($arcIds.Count -ne $specs.Count) { throw 'Not every node has an Arc machine, so the Arc Run Command transport can''t reach all of them.' }
    $arcTransport = New-AzlArcRunCommandTransport -ArcResourceId $arcIds
    foreach ($s in $specs) {
        $nodeTransports[$s.Name] = $arcTransport
        Send-AzlGuardEvent -Context $eventContext -Node $s.Name -State 'TransportResolved' -Step '' -Transport 'ArcRunCommand' -Evidence "Arc Run Command was asked for explicitly (-Transport ArcRunCommand). It is the exception for sites with no route to the nodes and is not recommended for network changes." -Level Warning
    }
}
else {
    $credentialSource = 'parameter'
    if (-not $Credential) {
        $admin = Get-AzlProp $infra 'identity.local_admin'
        $user = [string](Get-AzlProp $admin 'username' ''); $reference = [string](Get-AzlProp $admin 'password' '')
        if ($user -and $reference) {
            try { $secure = ConvertTo-SecureString -String (Get-AzlSecret -Reference $reference) -AsPlainText -Force; $Credential = [pscredential]::new($user, $secure); $credentialSource = "vault ($reference)" }
            catch { Write-Warning "Can't read the local administrator's password ($reference): $($_.Exception.Message)" }
        }
    }
    $addressByNode = @{}
    $candidates = foreach ($s in $specs) {
        $nodeObject = @($infra.nodes | Where-Object { $_.name -eq $s.Name })[0]
        $override = if ($NodeAddress -and $NodeAddress.ContainsKey($s.Name)) { [string]$NodeAddress[$s.Name] } else { '' }
        $list = @(Get-AzlNodeRemotingAddress -Node $nodeObject -Override $override -ManagementMac $s.Management.Mac -ArcMachine $arcMachines[$s.Name])
        [pscustomobject]@{ Name = $s.Name; Addresses = $list }
    }
    $arcAvailable = @($arcMachines.Keys | Where-Object { $arcMachines[$_].Status -eq 'Connected' })
    $findings = @(Get-AzlRemotingPreCheckFinding -Node $candidates -Port $remoting.Port -HasCredential ([bool]$Credential) -Origin $credentialSource -ArcAvailable $arcAvailable)
    # The bootstrap: Arc once per node, only to open remote management for the source CIDRs; then the node is probed again and everything else goes over WinRM.
    $closed = @($findings | Where-Object { -not $_.Reachable -and $_.Result -ne 'NoCredential' -and $_.Result -ne 'NoAddress' })
    # The same rule as the one-run wrapper: the class allows a bootstrap, the operator chose a route, and where the class needs it the pipeline approved it (-ApprovedBootstrap).
    $bootstrapVerdict = Test-AzlBootstrapPermitted -Bootstrap $remotingProfile.Bootstrap -Class $remotingProfile.Class -ApprovedBootstrap:$ApprovedBootstrap
    if ($closed.Count -and $remoting.BootstrapTransport -eq 'arc' -and -not $bootstrapVerdict.Permitted) {
        Write-Warning "The one-time bootstrap is not permitted, so nothing is opened on $(($closed | ForEach-Object { $_.Node }) -join ', '): $($bootstrapVerdict.Reason)"
    }
    if ($closed.Count -and $remoting.BootstrapTransport -eq 'arc' -and $bootstrapVerdict.Permitted) {
        $cidrs = @(Get-AzlRemotingAllowedCidr -Infrastructure $infra -RunnerCidr $remoting.AllowedSourceCidrs)
        if (-not $cidrs.Count) { throw 'remoting.bootstrapTransport is arc but no source CIDR is known: the file has no networking.management.subnet and remoting.allowedSourceCidrs is empty.' }
        $arcBootstrap = New-AzlArcRunCommandTransport -ArcResourceId $arcIds
        foreach ($f in $closed) {
            if (-not $arcIds.ContainsKey($f.Node)) { Write-Warning "$($f.Node): bootstrap needs its Arc machine and none was found; skipped."; continue }
            if ($arcMachines[$f.Node].Status -ne 'Connected') { Write-Warning "$($f.Node): its Arc machine is $($arcMachines[$f.Node].Status), not Connected; the bootstrap can't run."; continue }
            if (-not $Execute) { Write-Line "$($f.Node): not reachable over remoting; the bootstrap would open WinRM for $($cidrs -join ', ') through Arc once (plan only: not done)."; continue }
            Write-Line "$($f.Node): not reachable over remoting ($($f.Result)); using Arc Run Command ONCE to open remote management for $($cidrs -join ', ')."
            $steps = @($steps)
            $bootstrapRecords[$f.Node] = Invoke-AzlRemotingBootstrap -ArcTransport $arcBootstrap -Node $f.Node -Cidr $cidrs -Rdp:('RemoteManagement' -in $steps) -Icmp:('RemoteManagement' -in $steps) -Https:$remoting.UseSsl
            Send-AzlGuardEvent -Context $eventContext -Node $f.Node -State 'TransportResolved' -Step 'RemoteManagement' -Transport 'ArcRunCommand' -Evidence "Bootstrap through Arc Run Command, once: opened $($bootstrapRecords[$f.Node].Opened -join ', ') for $($cidrs -join ', '). Everything after this goes over WinRM." -Level Warning -Data @{ bootstrap = $true; cidrs = $cidrs }
        }
        if ($Execute -and $bootstrapRecords.Count) {
            Start-Sleep -Seconds 5
            $findings = @(Get-AzlRemotingPreCheckFinding -Node $candidates -Port $remoting.Port -HasCredential ([bool]$Credential) -Origin $credentialSource -ArcAvailable $arcAvailable)
        }
    }
    Write-Line (Format-AzlRemotingPreCheckFinding -Finding $findings)
    if (@($findings | Where-Object { -not $_.Reachable }).Count -and -not ($remoting.BootstrapTransport -eq 'arc' -and -not $Execute -and @($findings | Where-Object { -not $_.Reachable -and $_.Node -in $arcAvailable }).Count -eq @($findings | Where-Object { -not $_.Reachable }).Count)) {
        $notReady = "NOT READY: $(@($findings | Where-Object { -not $_.Reachable }).Count) node(s) can't be reached over PowerShell remoting. Nothing was changed."
        Write-Line $notReady
        # The caller reads the report, so a call that stops here leaves one that says so (never none, and never an older one).
        [ordered]@{ schemaVersion = 1; generatedUtc = [datetime]::UtcNow.ToString('o'); executed = [bool]$Execute; error = $notReady; nodes = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
        exit 1
    }
    foreach ($f in $findings) { $addressByNode[$f.Node] = $(if ($f.Reachable) { $f.Address } else { @($candidates | Where-Object Name -eq $f.Node)[0].Addresses[0] }) }
    foreach ($s in $specs) {
        $nodeTransports[$s.Name] = New-AzlWinRmTransport -Address @{ $s.Name = $addressByNode[$s.Name] } -Credential $Credential -UseSsl:$remoting.UseSsl -Authentication $remoting.Authentication
        $why = "PowerShell remoting is the default transport; $($addressByNode[$s.Name]):$($remoting.Port) answers$(if ($bootstrapRecords.ContainsKey($s.Name)) { ' after the one-time Arc bootstrap' }), credential from $credentialSource."
        Send-AzlGuardEvent -Context $eventContext -Node $s.Name -State 'TransportResolved' -Step '' -Transport 'WinRM' -Evidence $why -Data @{ address = $addressByNode[$s.Name]; port = $remoting.Port; authentication = $remoting.Authentication; ssl = $remoting.UseSsl }
    }
}
# The SBE package can't ride Arc Run Command. With hardware.sbe.delivery winrm_copy and the nodes reached over Arc (only when -Transport ArcRunCommand was asked for),
# the copy gets its own WinRM transport (sessions open only when a file has to be copied). Without -Credential the Sbe step reports why.
$sbeDelivery = [string](Get-AzlProp $infra 'hardware.sbe.delivery' 'skip')
$sbeTransport = $null
if ($bundle -and $sbeDelivery -eq 'winrm_copy' -and $remoting.Kind -ne 'WinRM' -and $Credential) {
    $sbeAddresses = @{}
    foreach ($s in $specs) { $sbeAddresses[$s.Name] = if ($NodeAddress -and $NodeAddress.ContainsKey($s.Name)) { [string]$NodeAddress[$s.Name] } else { $s.Management.Ip } }
    $sbeTransport = New-AzlWinRmTransport -Address $sbeAddresses -Credential $Credential -UseSsl:$remoting.UseSsl -Authentication $remoting.Authentication
}
Write-Line "Transport: $($remoting.Kind)$(if ($remoting.Kind -eq 'WinRM') { " (authentication $($remoting.Authentication), $(if ($remoting.UseSsl) { 'HTTPS 5986' } else { 'HTTP 5985' }))" }). $(if ($Execute) { 'EXECUTE: changes will be made.' } else { 'Plan only: nothing on the nodes changes. Add -Execute.' })"

# ---- the nodes
$guardSetting = @{}
if ($Settings) { foreach ($k in 'networkRollbackMinutes', 'networkStableSeconds', 'reconnectWaitMinutes', 'staleRunCommandMinutes', 'addressProbe') { if ($Settings.ContainsKey($k)) { $guardSetting[$k] = $Settings[$k] } } }
$null = Get-AzlGuardSetting -Setting $guardSetting
$results = [System.Collections.Generic.List[object]]::new()

# ---- what the report and the closing lines say about the run, from the results so far (a run that is cut short still has a true report)
function Get-SbeMissing { @(if ($bundle) { $results | Where-Object { @($_.Plan | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -ne 'Ok' }).Count } }) }
function Get-SanProblem {
    $found = @()
    if ((Get-AzlProp $infra 'scenario.storage_architecture' 's2d') -eq 'san') {
        $sets = @{}
        foreach ($r in $results) { if (-not (Get-AzlProp $r 'Error' '')) { $sets[$r.Node] = @(Get-AzlProp $r.State 'san.disks' @() | ForEach-Object { $_.uid } | Sort-Object) -join ',' } }
        if (@($sets.Values | Select-Object -Unique).Count -gt 1) { $found += "The nodes don't see the same SAN disks (UniqueIds differ): $(($sets.GetEnumerator() | ForEach-Object { "$($_.Key)=[$($_.Value)]" }) -join '; ')" }
    }
    return $found
}
function Write-NodeReport {
    # The report the ARM parameter generator and the one-run wrapper read. Written in finally, so a run that was cut short leaves the changes made so far, and says which call
    # failed and whether its outcome is indeterminate.
    $sbeMissing = @(Get-SbeMissing)
    $report = [ordered]@{
        schemaVersion = 1
        generatedUtc  = [datetime]::UtcNow.ToString('o')
        executed      = [bool]$Execute
        complete      = ($results.Count -eq @($specs).Count)
        transport     = $remoting.Kind
        sbeDelivery   = $sbeDelivery
        sbeNotDelivered = @($sbeMissing | ForEach-Object { $_.Node })
        remoting      = [ordered]@{ transport = $remoting.Transport; authentication = $remoting.Authentication; ssl = $remoting.UseSsl; port = $remoting.Port; bootstrapTransport = $remoting.BootstrapTransport }
        sanProblems   = @(Get-SanProblem)
        nodes         = @($results | ForEach-Object {
                $pendingGuard = @(Get-AzlProp $_ 'PendingGuard' @())
                [ordered]@{
                    name      = $_.Node
                    hostname  = [string](Get-AzlProp $_.State 'host' '')
                    osVersion = [string](Get-AzlProp $_.State 'os' '')
                    converged = ([bool]$_.Converged -and -not (Get-AzlProp $_ 'Error' '') -and @($pendingGuard | Where-Object { $_.State -ne 'Committed' }).Count -eq 0)
                    error     = [string](Get-AzlProp $_ 'Error' '')
                    indeterminate = [bool](Get-AzlProp $_ 'Indeterminate' $false)
                    transport = $nodeTransports[$_.Node].Kind
                    address   = $_.Address
                    stepTransports = [ordered]@{ all = $nodeTransports[$_.Node].Kind; bootstrap = $(if ($bootstrapRecords.ContainsKey($_.Node)) { 'ArcRunCommand' } else { '' }) }
                    bootstrap = $(if ($bootstrapRecords.ContainsKey($_.Node)) { [ordered]@{ used = $true; transport = 'ArcRunCommand'; opened = @($bootstrapRecords[$_.Node].Opened); scope = @($bootstrapRecords[$_.Node].Scope) } } else { [ordered]@{ used = $false } })
                    guard     = @($_.Guard | ForEach-Object { [ordered]@{ group = $_.Group; state = $_.State; changeId = $_.ChangeId; reason = $_.Reason; nextAction = $_.NextAction; oldAddress = $_.OldAddress; newAddress = $_.NewAddress; verdict = $_.Verdict; repairs = @($_.Repairs | ForEach-Object { $_.rung }) } })
                    pendingGuard = @($pendingGuard | ForEach-Object { [ordered]@{ changeId = $_.ChangeId; group = (Get-AzlProp $_ 'Group' ''); state = $_.State; reason = $_.Reason } })
                    events    = @($_.Events)
                    restarted = $_.Restarted
                    domainJoin = $_.DomainJoin # DOMAINJOIN HOOK
                    ports     = @(Get-AzlProp $_.State 'nics' @() | ForEach-Object { [ordered]@{ osName = $_.n; mac = $_.mac; status = $_.st } })
                    sanDisks  = @(Get-AzlProp $_.State 'san.disks' @())
                    fcPorts   = @(Get-AzlProp $_.State 'san.fc' @())
                    changes   = @($_.Changes)
                    wipe      = @(Get-AzlNodeWipeItem -Plan $_.Plan -State $_.State)
                    plan      = @($_.Plan | ForEach-Object { [ordered]@{ step = $_.Step; item = $_.Item; current = $_.Current; desired = $_.Desired; action = $_.Action; note = $_.Note } })
                }
            })
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
    Write-Line "Report: $ReportPath"
}

try {
    foreach ($s in $specs) {
        Write-Line "== $($s.Name)"
        $wipeArgs = @{}
        if ($ApprovedWipeId) { $wipeArgs.ApprovedWipeId = $(if ($ApprovedWipeId.ContainsKey($s.Name)) { @($ApprovedWipeId[$s.Name]) } else { @() }) }
        $nodeResult = $null
        try {
            $nodeResult = Invoke-AzlNodeConfiguration -Spec $s -Transport $nodeTransports[$s.Name] -Execute:$Execute -Step $steps -ClearStorage:$ClearStorage -ConfirmWipeDeployedCluster:$ConfirmWipeDeployedCluster @wipeArgs -NoRestart:$NoRestart -MaxPasses $MaxPasses -GuardSetting $guardSetting -EventContext $eventContext -SbeTransport $sbeTransport
        }
        catch {
            # A call that failed or timed out ends this node, not the report: what was done so far is kept, the error is on the node, and the exit code is 1.
            $indeterminate = ($_.Exception.Data['AzlState'] -eq 'Indeterminate')
            $nodeResult = $_.Exception.Data['AzlPartial']
            if (-not $nodeResult) {
                $nodeResult = [pscustomobject]@{ Node = $s.Name; Transport = $nodeTransports[$s.Name].Kind; Plan = @(); Changes = @(); Blocked = @(); Restarted = $false; Converged = $false; State = $null; Passes = @(); Executed = [bool]$Execute; Guard = @(); Events = @(); Address = ''; DomainJoin = $null; Error = $_.Exception.Message; Indeterminate = $indeterminate }
            }
            Write-Warning "$($s.Name): $($_.Exception.Message)$(if ($indeterminate) { ' (indeterminate: read the node again before anything else)' })"
        }
        # A guarded change an earlier call could not read (state Unknown) is looked at, read only, before the node is called converged.
        if ($ReconcileChangeId) {
            $pendingGuard = @(Get-AzlPendingGuardState -Transport $nodeTransports[$s.Name] -Node $s.Name -ChangeId $ReconcileChangeId -Spec $s)
            Add-Member -InputObject $nodeResult -NotePropertyName PendingGuard -NotePropertyValue $pendingGuard -Force
            foreach ($g in $pendingGuard) { Write-Line "   [guard] change $($g.ChangeId): $($g.State). $($g.Reason)" }
        }
        $results.Add($nodeResult)
    }
    foreach ($r in $results) {
        Write-Line (Format-AzlPlan -Plan @($r.Plan | Where-Object { $_.Action -ne 'Ok' -or -not $Execute }))
        foreach ($c in $r.Changes) { Write-Line "   [$($c.Status)] $($c.Id): $($c.Detail)" }
    }

    # ---- the SBE package: said plainly, because nothing else fails when it is missing
    $sbeMissing = @(Get-SbeMissing)
    if ($bundle -and $sbeMissing.Count) {
        Write-Line "SBE package NOT delivered to: $(($sbeMissing | ForEach-Object { $_.Node }) -join ', ') (hardware.sbe.delivery = $sbeDelivery). The other steps are not affected; the OEM drivers wait for the package."
    }

    # ---- every node must see the same SAN disks
    $sanProblems = @(Get-SanProblem)
    foreach ($p in $sanProblems) { Write-Warning $p }
}
finally {
    # The report is written whatever happened above: with the changes so far, and the error and the indeterminate mark of a call that was cut off.
    Write-NodeReport
}

$blocked = @($results | ForEach-Object { $_.Blocked })
$errored = @($results | Where-Object { Get-AzlProp $_ 'Error' '' })
$unreconciled = @($results | ForEach-Object { Get-AzlProp $_ 'PendingGuard' @() } | Where-Object { $_.State -ne 'Committed' })
$notConverged = @($results | Where-Object { $Execute -and -not $_.Converged })
$pending = @($results | ForEach-Object { $_.Plan } | Where-Object { $_.Action -eq 'Change' })
if ($blocked.Count -or $notConverged.Count -or $sanProblems.Count -or $errored.Count -or $unreconciled.Count) {
    Write-Line "NOT READY: $($blocked.Count) blocked item(s), $($notConverged.Count) node(s) not converged, $($errored.Count) node(s) with a failed or timed-out call$(if (@($errored | Where-Object { $_.Indeterminate }).Count) { ' (indeterminate)' }), $($unreconciled.Count) guarded change(s) not yet confirmed."
    exit 1
}
if (-not $Execute) { Write-Line "Plan: $($pending.Count) change(s) needed across $($results.Count) node(s)." }
else { Write-Line "All $($results.Count) node(s) match infrastructure.yml. $(if (@($results | Where-Object Restarted).Count) { 'Some restarted.' })" }
$results
