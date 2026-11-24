<#
.SYNOPSIS
    Turns on the Windows Server subscription add-on of the Azure Local instance (Enable-WindowsServerSubscription.ps1), then syncs the machines and
    checks on every machine that the subscription is active.

.DESCRIPTION
    Operational foundations, phase 05 (licensing and telemetry), Task 02 (activate the Windows Server subscription). The steps Microsoft Learn gives
    (Activate Windows Server VMs on Azure Local):

      1. Azure: turn on the add-on. This script runs Enable-WindowsServerSubscription.ps1 of the same folder, which reads
         operations.licensing.windows_server_subscription and runs Update-AzStackHciCluster -DesiredPropertyWindowsServerSubscription Enabled when the
         add-on is not on yet. That script holds the Azure logic; this one adds nothing to it. Its exit code 1 or 2 ends the run with the same code.
      2. The machines: Sync-AzureStackHCI on one node, so the machines take the subscription now and not at their next daily sync (Learn: "for faster
         resolution, you can sync manually"). -SkipSync leaves that out.
      3. Check, on every node: Get-AzureStackHCISubscriptionStatus, the row of the Windows Server subscription, and Get-VMAutomaticActivation
         (AVMA set up). A node that is not Active yet is reported as Pending: a warning, not a failure, because the setting comes with the next
         sync. A node that cannot be reached is Failed.

    When operations.licensing.windows_server_subscription is not true, step 1 does nothing and steps 2 and 3 are left out. -WhatIf is passed to step 1
    (it reads Azure and changes nothing); steps 2 and 3 are not run under -WhatIf.

    Sign-in: run Connect-AzAccount -Tenant <azure.tenant_id> first (step 1). The machines: -Credential, else the account the file names for the
    identity: identity.active_directory.lcm_user (as <netbios name>\<user>) with active_directory, identity.local_admin (as .\<user>) with
    local_identity; the password is a secret reference read through scripts/common/secrets/AzlSecret.psm1. The script never asks. Each node is asked
    at its own management address (no second hop).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure); step 1 reads its own keys (see Enable-WindowsServerSubscription.ps1):
        operations.licensing.windows_server_subscription, scenario.identity, nodes[].name, nodes[].management.ip_address
        identity.active_directory.netbios_name, identity.active_directory.lcm_user (username, password), identity.local_admin (username, password)

    Exit codes: 0 the add-on is on (or not asked for, or planned under -WhatIf) and every node answered; 1 step 1 failed, or a node could not be
    checked; 2 a value in the file is missing or not usable, or there is no login for the machines.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).

.PARAMETER Credential
    Optional. The account for the remoting sessions to the nodes. Without it the account of the file is used (see above).

.PARAMETER SkipSync
    Optional. Do not run Sync-AzureStackHCI; only check the nodes.

.PARAMETER LogPath
    Optional. Passed to step 1, and the progress lines of this script are appended to it. Keep it out of the repository.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Invoke-WindowsServerSubscription-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./Invoke-WindowsServerSubscription-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [pscredential]$Credential,
    [switch]$SkipSync,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

$EnableScript = Join-Path $PSScriptRoot 'Enable-WindowsServerSubscription.ps1'
# The row of Get-AzureStackHCISubscriptionStatus for the add-on, and its state when it is on (Learn: Activate Windows Server VMs on Azure Local).
$SubscriptionRow = 'Windows Server Subscription'
$ActiveStatus = 'Active'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

$Remote = @{
    Sync  = { param($Step) Sync-AzureStackHCI -ErrorAction Stop }
    Check = {
        param($Step, $RowName)
        $rows = @(Get-AzureStackHCISubscriptionStatus -ErrorAction Stop)
        $row = @($rows | Where-Object { [string]$_.SubscriptionName -eq $RowName }) | Select-Object -First 1
        $avma = $null
        try { $avma = Get-VMAutomaticActivation -ErrorAction Stop } catch { $avma = $null }
        @{ Computer = [string]$env:COMPUTERNAME; Status = $(if ($row) { [string]$row.Status } else { '' }); Avma = $(if ($avma) { ($avma | Out-String).Trim() } else { '' }) }
    }
}
function Invoke-Node([string]$Computer, [string]$Step, [object[]]$Arguments = @()) {
    $call = @{ ComputerName = $Computer; ScriptBlock = $Remote[$Step]; ArgumentList = (, $Step + $Arguments); ErrorAction = 'Stop'; Credential = $script:remoteCredential }
    Invoke-Command @call
}

if (-not (Test-Path -LiteralPath $EnableScript)) { Write-Error "The step script is missing: $EnableScript" -ErrorAction Continue; exit 1 }
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

# ---- 1. Azure, through the script of the task
Write-Line '---- Step 1: Enable-WindowsServerSubscription.ps1'
$arguments = @{ InfrastructureFile = $InfrastructureFile; WhatIf = [bool]$WhatIfPreference }
if ($LogPath) { $arguments.LogPath = $LogPath }
$global:LASTEXITCODE = 0
& $EnableScript @arguments
$stepCode = [int]$LASTEXITCODE
if ($stepCode -ne 0) { Write-Line "Step 1 ended with exit code $stepCode; the machines are not checked."; exit $stepCode }
if ((Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.licensing.windows_server_subscription') -ne $true) { exit 0 }
if ($WhatIfPreference) { Write-Line '[plan]    After the add-on is on, Sync-AzureStackHCI would run on one node and every node would be checked.'; exit 0 }

# ---- the login for the machines
$remoteCredential = $Credential
if (-not $remoteCredential) {
    if ((Get-Text 'scenario.identity').ToLowerInvariant() -eq 'local_identity') { $user = Get-Text 'identity.local_admin.username'; $reference = Get-Text 'identity.local_admin.password'; $account = ".\$user"; $what = 'identity.local_admin' }
    else {
        $netbios = Get-Text 'identity.active_directory.netbios_name'
        $user = Get-Text 'identity.active_directory.lcm_user.username'; $reference = Get-Text 'identity.active_directory.lcm_user.password'
        $account = if ($user -match '\\|@') { $user } elseif ($netbios) { "$netbios\$user" } else { $user }
        $what = 'identity.active_directory.lcm_user'
    }
    if (-not $user -or -not $reference) { Exit-InputProblem "The add-on is on, but there is no login to check the machines: pass -Credential, or set $what username and password (a secret reference)." }
    try { $remoteCredential = [pscredential]::new($account, (Get-AzlSecretValue -Reference $reference -Infrastructure $infra)) }
    catch { Exit-InputProblem "The password of $what could not be read: $($_.Exception.Message)" }
}
$nodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
if ($nodes.Count -eq 0) { Exit-InputProblem 'nodes[] is empty: there is no machine to check.' }

# ---- 2. sync, on the first node that answers
$rows = [System.Collections.Generic.List[object]]::new()
if (-not $SkipSync) {
    $synced = $false
    foreach ($n in $nodes) {
        $address = if ($n.ManagementIp) { $n.ManagementIp } else { $n.Name }
        try { Invoke-Node $address 'Sync' | Out-Null; Write-Line "[done]    Sync-AzureStackHCI ran on $($n.Name)."; $synced = $true; break }
        catch { Write-Warning "Sync-AzureStackHCI on $($n.Name) failed: $($_.Exception.Message)" }
    }
    if (-not $synced) { Write-Warning 'No node could be synced. The machines take the add-on at their next daily sync.' }
}

# ---- 3. check every node
foreach ($n in $nodes) {
    $address = if ($n.ManagementIp) { $n.ManagementIp } else { $n.Name }
    try {
        $state = Invoke-Node $address 'Check' @($SubscriptionRow)
        $result = if ([string]$state.Status -eq $ActiveStatus) { 'Active' } else { 'Pending' }
        $detail = if ($result -eq 'Active') { 'AVMA ' + $(if ($state.Avma) { 'set up' } else { 'not reported' }) } else { "status '$($state.Status)'; the machine takes the add-on at its next sync. Run this script again later." }
        $rows.Add([pscustomobject][ordered]@{ Node = $n.Name; Result = $result; Detail = $detail })
        if ($result -eq 'Pending') { Write-Warning "$($n.Name): $detail" } else { Write-Line "[ok]      $($n.Name): $SubscriptionRow $ActiveStatus." }
    }
    catch { $rows.Add([pscustomobject][ordered]@{ Node = $n.Name; Result = 'Failed'; Detail = $_.Exception.Message }) }
}

$rows
if (@($rows | Where-Object Result -EQ 'Failed')) { exit 1 }
exit 0
