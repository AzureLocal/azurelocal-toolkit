#Requires -Version 7.0
<#
.SYNOPSIS
    OS configuration for a whole Azure Local instance in ONE run: every handoff, every node, plan, apply, verify, one report.

.DESCRIPTION
    The one entry point of the OS configuration phase. The same command runs on an operator's workstation and, unchanged, in a
    CI/CD pipeline (GitHub Actions, GitLab CI) under pwsh on Windows or Linux. It calls Set-AzureLocalNodeConfiguration.ps1 for each
    node and adds the cluster-wide parts around it:

      1. Validate the inputs. Every *.ztp-handoff.json found under -HandoffPath is merged into one node -> handoff map (a node in two
         files is an error). The method per node is worked out from the master file and from what is there: a machine that ZTP
         provisioned (only the steps ZTP left undone) or one installed from an ISO (the computer name, the OS check, Arc registration too).
         Both are reached over PowerShell remoting (WinRM) with the local administrator from the vault; Arc Run Command only when -Transport
         ArcRunCommand is passed. A cluster can mix both methods.
      2. Plan for ALL nodes. Read only. Writes plan-report.json and wipe-list.txt.
      3. -Mode Apply: apply node by node. A failed node does not stop the others (-ContinueOnNodeFailure, default true).
      4. Verify: a Plan pass proves each changed node has nothing left to change.
      5. report.json, summary.md and an exit code.

    Leftover local storage is wiped only when the master file says os_configuration.clear_storage: true (or -ClearStorage is given),
    and only in Apply mode. The Plan mode prints which disks on which node would be wiped; in a pipeline that list is what the
    approval gate shows. Boot, system, SAN (Fibre Channel, iSCSI) and USB disks are never touched.

    A change that can cut a node off (its management address, VLAN, remote-management firewall rules, time, the computer name, DHCP off on other
    ports) is a guarded change: applied on the node, checked there, committed only after this host confirms it through a new session, and rolled
    back by the node otherwise. With -Transport ArcRunCommand, a node script whose Arc Run Command ends in state Unknown (the node's agent lost its
    connection, for example while its network changed) is tried again with a growing pause (3 tries); then the node is read again and convergence is decided by what is
    found, not by the command's status.

    Exit codes: 0 every node converged (Plan: nothing failed or blocked); 1 a node failed, is blocked or did not converge;
    2 bad input or nothing reachable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).
.PARAMETER HandoffPath
    A handoff file, several files, or a directory. Every *.ztp-handoff.json in a directory is used. Optional: a cluster installed from
    ISO has none.
.PARAMETER Node
    Limit the run to these nodes. Default: every node in the file.
.PARAMETER Mode
    Plan (default; changes nothing) or Apply.
.PARAMETER Step
    Limit the run to these steps. Default: the steps of each node's method.
.PARAMETER EventLogPath
    The event feed: one JSON object per line (JSON Lines, UTF-8, UTC timestamps) that says what the run is doing, for a viewer such as
    azurelocal-sonar to follow. Default: os-configuration-events.jsonl in the report directory. Lines are appended, so a path shared with an
    earlier run keeps its history. Run events (node '*'): RunStarted, PlanCompleted, WipeListPublished, RunCompleted. Node events:
    NodeStarted, MethodResolved, TransportResolved, NodeRetry, NodeRestarting, NodeConverged, NodeFailed, NodeBlocked, NodeReconnecting, NodeReconnected. Step events: StepPlanned, StepApplying,
    StepApplied, StepFailed, StepSkipped, StepVerified. Each line has timestamp, node, stage ('OsConfiguration'), step, state, evidence, level
    (Info|Warning|Error), nextAction, method (Ztp|Iso), transport (ArcRunCommand|WinRM), payloadVersion and schemaVersion. The guarded network change adds
    the NetworkChange* states (the guarded change of the management address and the other changes that can cut a node off). Contract: pmo/azure-local/os-configuration-design.md section 6. Writing it never fails the run.
.PARAMETER ReportDirectory
    Where plan-report.json, report.json, summary.md, wipe-list.txt and node-reports/ go. Default: a folder in the temp directory.
.PARAMETER SettingsFile
    Optional JSON file of run settings: retryTries, retryDelaySeconds, maxPasses (default 6), noRestart, failOnPendingChanges, nodeAddress,
    networkRollbackMinutes, networkStableSeconds, reconnectWaitMinutes, staleRunCommandMinutes, addressProbe, remoting.
.PARAMETER Settings
    The same keys as a hashtable; wins over -SettingsFile.
.PARAMETER ContinueOnNodeFailure
    Keep going with the other nodes when one fails (default $true). Pass -ContinueOnNodeFailure:$false to stop at the first failure.
.PARAMETER Transport
    Auto (default) is PowerShell remoting (WinRM) for every node, or what remoting.transport says. ArcRunCommand only when you pass it: the exception for sites with no route to the nodes, not recommended for network changes. Arc is never a silent fallback.
.PARAMETER Method
    Auto (default; worked out per node), Ztp or Iso for every node.
.PARAMETER Credential
    The nodes' local administrator for WinRM. Default: identity.local_admin from the master file, its password read from the Key Vault.
.PARAMETER NodeAddress
    Node name -> the address to open the WinRM session to first, for a node that still holds the installer's address.
.PARAMETER ClearStorage
    Force the storage wipe on, as os_configuration.clear_storage: true does.
.PARAMETER ConfirmWipeDeployedCluster
    One-shot, per run, never read from a file or from os_configuration.clear_storage: lets the storage wipe touch a node that belongs to a deployed cluster
    (a running Cluster service, HKLM:\Cluster that names a cluster, a clustered or S2D pool, or cluster shared volumes; a Cluster service that is only installed does not count). Without it such a node is Blocked in the plan
    with the reason, and the node-side clear refuses it too. Only meaningful together with the storage wipe.
.PARAMETER ApprovedWipeList
    The approval of the storage wipe, bound to what the reviewer saw. A Plan run writes wipe-list.json (node, disk serials and a SHA-256 of them) next to plan-report.json;
    an Apply run whose own wipe list is not empty needs that file (or the plan-report.json) here, and stops with exit code 2, before anything is changed, when it holds
    a disk that is not in it. A pipeline passes the Plan stage's artifact. Each node call is then told which disks it may wipe, and wipes nothing else.
.PARAMETER ApprovedBootstrap
    The pipeline approval of the one-time bootstrap (os_configuration.remoting.bootstrap_transport arc, smb or auto). Classes lab, test and dev need
    none; production and dmz do not bootstrap without it (dmz: on every run).
.PARAMETER FailOnPendingChanges
    Plan mode only: exit 1 when any change is still pending (drift detection). Without it a plan with changes exits 0.
.EXAMPLE
    ./Invoke-AzureLocalOsConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffPath ./ztp-state -Mode Plan -ReportDirectory ./out
.EXAMPLE
    ./Invoke-AzureLocalOsConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffPath ./ztp-state -Mode Apply -ReportDirectory ./out
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$HandoffPath,
    [string[]]$Node,
    [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan',
    [ValidateSet('RemoteManagement', 'Sbe', 'Drivers', 'NicNames', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'DomainJoin', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'ArcRegistration')][string[]]$Step,
    [string]$ReportDirectory,
    [string]$SettingsFile,
    [hashtable]$Settings,
    [bool]$ContinueOnNodeFailure = $true,
    [ValidateSet('Auto', 'ArcRunCommand', 'WinRM')][string]$Transport = 'Auto',
    [ValidateSet('Auto', 'Ztp', 'Iso')][string]$Method = 'Auto',
    [pscredential]$Credential,
    [hashtable]$NodeAddress,
    [switch]$ClearStorage,
    [switch]$ConfirmWipeDeployedCluster,
    [string]$ApprovedWipeList,
    [switch]$FailOnPendingChanges,
    [switch]$SkipValidation,
    [string]$EventLogPath,
    [switch]$ApprovedBootstrap
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common'))
Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlOsConfigurationRun.psm1') -Force

$result = Invoke-AzlOsConfiguration @PSBoundParameters
exit $result.ExitCode
