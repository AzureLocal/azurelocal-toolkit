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
         provisioned (Arc Run Command, only the steps ZTP left undone) or one installed from an ISO (WinRM with the local
         administrator from the vault, the computer name, the OS check, Arc registration). A cluster can mix both.
      2. Plan for ALL nodes. Read only. Writes plan-report.json and wipe-list.txt.
      3. -Mode Apply: apply node by node. A failed node does not stop the others (-ContinueOnNodeFailure, default true).
      4. Verify: a Plan pass proves each changed node has nothing left to change.
      5. report.json, summary.md and an exit code.

    Leftover local storage is wiped only when the master file says os_configuration.clear_storage: true (or -ClearStorage is given),
    and only in Apply mode. The Plan mode prints which disks on which node would be wiped; in a pipeline that list is what the
    approval gate shows. Boot, system, SAN (Fibre Channel, iSCSI) and USB disks are never touched.

    A node script whose Arc Run Command ends in state Unknown (the node's agent lost its connection, for example while its network
    changed) is tried again with a growing pause (3 tries); then the node is read again and convergence is decided by what is
    found, not by the command's status.

    Exit codes: 0 every node converged (Plan: nothing failed or blocked); 1 a node failed, is blocked or did not converge;
    2 bad input or nothing reachable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5.4.3 for clear_storage).
.PARAMETER HandoffPath
    A handoff file, several files, or a directory. Every *.ztp-handoff.json in a directory is used. Optional: a cluster installed from
    ISO has none.
.PARAMETER Node
    Limit the run to these nodes. Default: every node in the file.
.PARAMETER Mode
    Plan (default; changes nothing) or Apply.
.PARAMETER Step
    Limit the run to these steps. Default: the steps of each node's method.
.PARAMETER ReportDirectory
    Where plan-report.json, report.json, summary.md, wipe-list.txt and node-reports/ go. Default: a folder in the temp directory.
.PARAMETER ConfigPath
    Optional JSON file of run settings: retryTries, retryDelaySeconds, maxPasses, noRestart, failOnPendingChanges, nodeAddress.
.PARAMETER Settings
    The same keys as a hashtable; wins over -ConfigPath.
.PARAMETER ContinueOnNodeFailure
    Keep going with the other nodes when one fails (default $true). Pass -ContinueOnNodeFailure:$false to stop at the first failure.
.PARAMETER Transport
    Auto (default; per node, from its method), ArcRunCommand or WinRM for every node.
.PARAMETER Method
    Auto (default; worked out per node), Ztp or Iso for every node.
.PARAMETER Credential
    The nodes' local administrator for WinRM. Default: identity.local_admin from the master file, its password read from the Key Vault.
.PARAMETER NodeAddress
    Node name -> the address to open the WinRM session to, for an ISO-installed node that still holds the installer's address.
.PARAMETER ClearStorage
    Force the storage wipe on, as os_configuration.clear_storage: true does.
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
    [ValidateSet('RemoteManagement', 'Sbe', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'DomainJoin', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'ArcRegistration')][string[]]$Step,
    [string]$ReportDirectory,
    [string]$ConfigPath,
    [hashtable]$Settings,
    [bool]$ContinueOnNodeFailure = $true,
    [ValidateSet('Auto', 'ArcRunCommand', 'WinRM')][string]$Transport = 'Auto',
    [ValidateSet('Auto', 'Ztp', 'Iso')][string]$Method = 'Auto',
    [pscredential]$Credential,
    [hashtable]$NodeAddress,
    [switch]$ClearStorage,
    [switch]$FailOnPendingChanges,
    [switch]$SkipValidation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common'))
Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlOsConfigurationRun.psm1') -Force

$result = Invoke-AzlOsConfiguration @PSBoundParameters
exit $result.ExitCode
