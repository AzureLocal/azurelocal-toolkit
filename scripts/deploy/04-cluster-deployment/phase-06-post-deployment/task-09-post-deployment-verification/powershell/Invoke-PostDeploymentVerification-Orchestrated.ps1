<#
.SYNOPSIS
    The whole Phase 06 verification in one run: the node checks (Invoke-VerifyPostDeployment.ps1), the Azure checks
    (Invoke-VerifyPostDeployment.azcli.ps1), and the checklist items of the guide page that neither covers: the solution health summary and, with
    an external SAN, the SAN disks, their MPIO paths and their identity on every node. Read only.

.DESCRIPTION
    Phase 06 (post-deployment), Task 09 (post-deployment verification). The guide page lists the checks; two scripts of this folder already do most
    of them, so this script runs them and adds the rest:

      1. Invoke-VerifyPostDeployment.ps1 (this folder): cluster nodes, identity, quorum, security groups, SSH, storage pool and CSVs, the counts of
         VM images and logical networks.
      2. ../azurecli/Invoke-VerifyPostDeployment.azcli.ps1: the Arc machines and their extensions, the instance, the custom location, the cloud
         witness account, the counts of storage paths, VM images, logical networks and network security groups in Azure. -SkipAzure leaves it out.
      3. Solution health, on one node: Get-SolutionHealthSummary (Azure Local 2610 and later; Status FAILED fails, WARNING warns, SUCCESS passes),
         else Get-SolutionUpdateEnvironment (HealthState Failure or Error fails, Warning warns; a state of a check that has not finished warns). Microsoft Learn: Use the Get-SolutionHealthSummary command.
      4. SAN, only when scenario.storage_architecture is san or hybrid, on every node: every disk on Fibre Channel or iSCSI is Healthy; every
         MPIO disk has at least two paths (MPIO_DISK_INFO, the WMI class behind mpclaim); the UniqueId set of the SAN disks is the same on every
         node. For a SAN storage check that fails, Learn says to collect the SANDiagnostics log role.

    Each step runs even when an earlier one failed, so one run shows every problem. -WhatIf is passed to steps 1 and 2 (they list their checks and
    run none); steps 3 and 4 are listed and not run.

    The login for steps 3 and 4 is -Credential, else the account the file names for the identity: identity.active_directory.lcm_user (as
    <netbios name>\<user>) with active_directory, identity.local_admin (as .\<user>) with local_identity; the password is a secret reference read
    through scripts/common/secrets/AzlSecret.psm1. -Credential is also passed to step 1; without it step 1 resolves the same account itself. The
    script never asks. Each node is asked at its own management address.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure); steps 1 and 2 read their own keys:
        scenario.storage_architecture, scenario.identity, nodes[].name, nodes[].management.ip_address
        identity.active_directory.netbios_name, identity.active_directory.lcm_user (username, password), identity.local_admin (username, password)

    Exit codes: 0 every step passed (warnings allowed) or the checks were listed under -WhatIf; 1 a step or a check failed; 2 a value in the file is
    missing or not usable, or there is no login (also when step 1 or 2 ends with 2).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).

.PARAMETER Credential
    Optional. The account for the remoting to the nodes. Without it the account of the file is used (see above).

.PARAMETER TargetNode
    Optional. Limit the node checks to these nodes (node names or management addresses). Passed to steps 1 and 2.

.PARAMETER SkipAzure
    Optional. Do not run step 2 (for a host without the Azure CLI; step 1 still reads Azure for its counts).

.PARAMETER LogPath
    Optional. Passed to steps 1 and 2, and the progress lines of this script are appended to it. Keep it out of the repository.

.EXAMPLE
    ./Invoke-PostDeploymentVerification-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    az login --tenant <tenant-id>
    ./Invoke-PostDeploymentVerification-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [pscredential]$Credential,
    [string[]]$TargetNode = @(),
    [switch]$SkipAzure,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

$NodeScript = Join-Path $PSScriptRoot 'Invoke-VerifyPostDeployment.ps1'
$AzureScript = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'azurecli', 'Invoke-VerifyPostDeployment.azcli.ps1'))
# What makes the SAN checks pass, from the checklist of the guide page: at least two MPIO paths per LUN (path redundancy), and the disks of these bus types.
$MinimumMpioPaths = 2
# Compared with the spaces taken out: the Storage module shows the Fibre Channel bus type as 'Fibre Channel' or 'FibreChannel'.
$SanBusTypes = @('FibreChannel', 'iSCSI')

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

$Remote = @{
    Health = {
        param($Step)
        if (Get-Command -Name Get-SolutionHealthSummary -ErrorAction SilentlyContinue) {
            $summary = Get-SolutionHealthSummary -ErrorAction Stop
            $titles = @(@($summary.Results) | Where-Object { $_ } | ForEach-Object { "$($_.Severity): $($_.Title)" })
            return @{ Source = 'Get-SolutionHealthSummary'; Status = [string]$summary.Status; Issues = $titles }
        }
        $environment = @(Get-SolutionUpdateEnvironment -ErrorAction Stop)[0]
        @{ Source = 'Get-SolutionUpdateEnvironment'; Status = [string]$environment.HealthState; Issues = @() }
    }
    San    = {
        param($Step, [string[]]$BusTypes)
        $disks = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { ([string]$_.BusType -replace '\s', '') -in $BusTypes } | ForEach-Object { @{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus } })
        $ids = @(Get-Disk -ErrorAction Stop | Where-Object { ([string]$_.BusType -replace '\s', '') -in $BusTypes } | ForEach-Object { [string]$_.UniqueId } | Sort-Object)
        $paths = @()
        try { $paths = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MPIO_DISK_INFO' -ErrorAction Stop | ForEach-Object { @($_.DriveInfo) } | Where-Object { $_ } | ForEach-Object { @{ Name = [string]$_.Name; Paths = [int]$_.NumberPaths } }) } catch { $paths = $null }
        @{ Computer = [string]$env:COMPUTERNAME; Disks = $disks; UniqueIds = $ids; Paths = $paths }
    }
}
function Invoke-Node([string]$Computer, [string]$Step, [object[]]$Arguments = @()) {
    $call = @{ ComputerName = $Computer; ScriptBlock = $Remote[$Step]; ArgumentList = (, $Step + $Arguments); ErrorAction = 'Stop'; Credential = $script:remoteCredential }
    Invoke-Command @call
}

foreach ($p in $NodeScript, $AzureScript) { if (-not (Test-Path -LiteralPath $p)) { Write-Error "The step script is missing: $p" -ErrorAction Continue; exit 1 } }
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }
$architecture = (Get-Text 'scenario.storage_architecture').ToLowerInvariant()
$hasSan = $architecture -in 'san', 'hybrid'
$nodes = @(Get-AzlInfrastructureNode -Infrastructure $infra | Where-Object { $TargetNode.Count -eq 0 -or $_.Name -in $TargetNode -or $_.ManagementIp -in $TargetNode })
if ($nodes.Count -eq 0) { Exit-InputProblem 'No node to check: nodes[] is empty or -TargetNode matches none.' }

$summary = [System.Collections.Generic.List[object]]::new()
function Add-Step([string]$Step, [string]$Result, [string]$Detail = '') {
    $summary.Add([pscustomobject][ordered]@{ Step = $Step; Result = $Result; Detail = $Detail })
    Write-Line ("[{0,-7}] {1}{2}" -f $Result.ToLowerInvariant(), $Step, $(if ($Detail) { ": $Detail" } else { '' }))
}
function Invoke-Step([string]$Name, [string]$Path, [hashtable]$Arguments) {
    Write-Line "---- $Name"
    $global:LASTEXITCODE = 0
    & $Path @Arguments
    $code = [int]$LASTEXITCODE
    Add-Step $Name $(switch ($code) { 0 { 'Passed' } 2 { 'InputProblem' } default { 'Failed' } }) "exit code $code"
}

# ---- 1 and 2: the two scripts of the task
$common = @{ InfrastructureFile = $InfrastructureFile; WhatIf = [bool]$WhatIfPreference }
if ($TargetNode.Count) { $common.TargetNode = $TargetNode }
if ($LogPath) { $common.LogPath = $LogPath }
$nodeArguments = $common.Clone(); if ($Credential) { $nodeArguments.Credential = $Credential }
Invoke-Step 'Node checks (Invoke-VerifyPostDeployment.ps1)' $NodeScript $nodeArguments
if ($SkipAzure) { Add-Step 'Azure checks (Invoke-VerifyPostDeployment.azcli.ps1)' 'Skipped' '-SkipAzure' }
else { Invoke-Step 'Azure checks (Invoke-VerifyPostDeployment.azcli.ps1)' $AzureScript $common.Clone() }

if ($WhatIfPreference) {
    Add-Step 'Solution health summary' 'Plan' 'would read Get-SolutionHealthSummary (or Get-SolutionUpdateEnvironment) on one node'
    if ($hasSan) { Add-Step 'SAN disks, MPIO paths, LUN identity' 'Plan' "would read the SAN disks of $($nodes.Count) node(s)" }
    $summary
    exit $(if (@($summary | Where-Object Result -EQ 'InputProblem')) { 2 } elseif (@($summary | Where-Object Result -EQ 'Failed')) { 1 } else { 0 })
}

# ---- the login for steps 3 and 4
$remoteCredential = $Credential
if (-not $remoteCredential) {
    if ((Get-Text 'scenario.identity').ToLowerInvariant() -eq 'local_identity') { $user = Get-Text 'identity.local_admin.username'; $reference = Get-Text 'identity.local_admin.password'; $account = ".\$user"; $what = 'identity.local_admin' }
    else {
        $netbios = Get-Text 'identity.active_directory.netbios_name'
        $user = Get-Text 'identity.active_directory.lcm_user.username'; $reference = Get-Text 'identity.active_directory.lcm_user.password'
        $account = if ($user -match '\\|@') { $user } elseif ($netbios) { "$netbios\$user" } else { $user }
        $what = 'identity.active_directory.lcm_user'
    }
    $secret = $null
    if ($user -and $reference) { try { $secret = Get-AzlSecretValue -Reference $reference -Infrastructure $infra } catch { $secret = $null } }
    if (-not $secret) { Add-Step 'Solution health and SAN checks' 'InputProblem' "no login: pass -Credential, or set $what username and password (a secret reference)"; $summary; exit 2 }
    $remoteCredential = [pscredential]::new($account, $secret)
}

# ---- 3. solution health, on the first node that answers
$health = $null; $healthNode = ''
foreach ($n in $nodes) {
    $address = if ($n.ManagementIp) { $n.ManagementIp } else { $n.Name }
    try { $health = Invoke-Node $address 'Health'; $healthNode = $n.Name; break } catch { Write-Line "  $($n.Name): $($_.Exception.Message)" }
}
if (-not $health) { Add-Step 'Solution health summary' 'Failed' 'no node answered' }
else {
    $status = ([string]$health.Status).ToUpperInvariant()
    $issues = @($health.Issues) -join '; '
    # Get-SolutionHealthSummary: FAILED, WARNING, SUCCESS. Get-SolutionUpdateEnvironment (HealthState, before 2610): Success, Warning, Failure, Error,
    # and states of a check that has not finished (InProgress, Unknown), which are a warning: the check may not have run yet.
    $result = if ($status -in 'FAILED', 'FAILURE', 'ERROR', 'CRITICAL') { 'Failed' } elseif ($status -eq 'WARNING') { 'Warn' } elseif ($status -in 'SUCCESS', 'SUCCEEDED', 'HEALTHY') { 'Passed' } else { 'Warn' }
    Add-Step 'Solution health summary' $result "$($health.Source) on ${healthNode}: $($health.Status)$(if ($issues) { " ($issues)" })"
}

# ---- 4. SAN, on every node
if ($hasSan) {
    $idSets = @{}
    foreach ($n in $nodes) {
        $address = if ($n.ManagementIp) { $n.ManagementIp } else { $n.Name }
        try { $san = Invoke-Node $address 'San' @(, $SanBusTypes) }
        catch { Add-Step "SAN on $($n.Name)" 'Failed' $_.Exception.Message; continue }
        $disks = @($san.Disks)
        if ($disks.Count -eq 0) { Add-Step "SAN disks on $($n.Name)" 'Failed' 'no Fibre Channel or iSCSI disk is seen'; continue }
        $sick = @($disks | Where-Object { [string]$_.Health -ne 'Healthy' })
        Add-Step "SAN disks on $($n.Name)" $(if ($sick) { 'Failed' } else { 'Passed' }) $(if ($sick) { "not Healthy: $(($sick | ForEach-Object { "$($_.Name) $($_.Health)" }) -join ', '); collect the SANDiagnostics log role" } else { "$($disks.Count) disk(s) Healthy" })
        if ($null -eq $san.Paths) { Add-Step "MPIO paths on $($n.Name)" 'Failed' 'MPIO_DISK_INFO could not be read: is MPIO installed and are the LUNs claimed?' }
        else {
            $few = @(@($san.Paths) | Where-Object { [int]$_.Paths -lt $MinimumMpioPaths })
            Add-Step "MPIO paths on $($n.Name)" $(if ($few -or @($san.Paths).Count -eq 0) { 'Failed' } else { 'Passed' }) $(if ($few) { "fewer than $MinimumMpioPaths paths: $(($few | ForEach-Object { "$($_.Name) $($_.Paths)" }) -join ', ')" } elseif (@($san.Paths).Count -eq 0) { 'no MPIO disk' } else { "$(@($san.Paths).Count) MPIO disk(s), each with $MinimumMpioPaths or more paths" })
        }
        $idSets[$n.Name] = (@($san.UniqueIds) | Sort-Object) -join ','
    }
    if ($idSets.Count -gt 1) {
        $distinct = @($idSets.Values | Sort-Object -Unique)
        Add-Step 'SAN disk identity across nodes' $(if ($distinct.Count -eq 1) { 'Passed' } else { 'Failed' }) $(if ($distinct.Count -eq 1) { 'every node sees the same SAN disks (UniqueId)' } else { 'the nodes see different SAN disks (UniqueId); check the zoning or the iSCSI targets' })
    }
}

$summary
if (@($summary | Where-Object Result -EQ 'InputProblem')) { exit 2 }
if (@($summary | Where-Object Result -EQ 'Failed')) { exit 1 }
exit 0
