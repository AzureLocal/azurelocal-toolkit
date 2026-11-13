<#
.SYNOPSIS
    Starts the Azure Local solution update after the deployment, when infrastructure.yml asks for it, and returns without waiting for the update to finish.

.DESCRIPTION
    Day 2, after the deployment. When operations.updates.install_after_deployment is true, the script connects to the cluster with PowerShell remoting and,
    the way Microsoft Learn describes it (Update Azure Local by using PowerShell):

      1. reads the update environment (Get-SolutionUpdateEnvironment: the installed solution version and the health state) and the updates the update
         service has discovered (Get-SolutionUpdate);
      2. chooses the update: the solution update whose version is operations.updates.target_version, or, with latest (the default), the highest solution
         update that is ready to install. Standalone Solution Builder Extension updates (package type SBE) are not chosen;
      3. checks that the system is ready: the HealthState of the update environment must not be Failure, Error or Warning (Learn: review the HealthState
         before you proceed). Start-SolutionUpdate itself downloads the update and runs the readiness checks before it installs;
      4. starts the update with Start-SolutionUpdate and prints the run that was started.

    The script does not wait. An update takes hours (Learn: about four hours for one machine, six for four), and the machines restart. It prints how to follow
    the run (Get-SolutionUpdate on a machine, Update Manager in the Azure portal); the separate tool Sonar watches the progress.

    Idempotent. The script reports and exits 0 without starting anything when
      the switch is off (install_after_deployment is false or missing);
      the instance already runs the target version, or no newer solution update is ready;
      an update is already running (Downloading, Preparing, HealthChecking or Installing).
    A chosen update that is in a failed state (HealthCheckFailed, InstallationFailed and the other failures), needs more content (AdditionalContentRequired) or
    needs another update first (HasPrerequisite) is reported as Failed and left alone: the script does not resume or retry it. See Learn: Troubleshoot updates.
    -WhatIf reads the cluster and prints what would be started; it starts nothing.

    The script does not sign in anywhere and reads no secret. It connects as the account that runs it, or as -Credential. Learn: use the deployment user account.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        operations.updates.install_after_deployment   the switch; false when missing
        operations.updates.target_version             latest (default) or a solution version of four numbers, for example 12.2610.1004.50
        cluster.name                                  the cluster to connect to (unless -ComputerName is given)

    Exit codes: 0 the update was started, or there is nothing to start (reported), or planned under -WhatIf; 1 the cluster could not be reached, the
    system is not ready, or the update cannot be started; 2 a value in the file is missing or not usable. Nothing is sent to the cluster on exit code 2.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to connect to instead of cluster.name, for example one node when the cluster name does not resolve from where you run this.

.PARAMETER Credential
    Optional. The account for the remoting session, the deployment user. Without it the account that runs the script is used.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Start-SolutionUpdateAfterDeployment.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Reads the update state of the cluster and shows which update would be started. Starts nothing.

.EXAMPLE
    ./Start-SolutionUpdateAfterDeployment.ps1 -InfrastructureFile ./infrastructure.yml -Credential (Get-Secret lcm-user)

    Starts the update the file asks for and returns. Run it again: it reports that the update is running, or that the instance is at the target.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ComputerName,
    [pscredential]$Credential,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

# The states of an update that Learn names (Update Azure Local by using PowerShell; Understand update phases of Azure Local).
$StartableState = 'Ready', 'ReadyToInstall', 'HealthCheckExpired'
$RunningState = 'Downloading', 'Preparing', 'HealthChecking', 'Installing'
$BlockingHealth = 'Failure', 'Error', 'Warning'
$StateAdvice = @{
    AdditionalContentRequired = 'it needs content from the hardware vendor: import it first (Learn: Solution Builder Extension updates, the AdditionalContentRequired state)'
    HasPrerequisite           = 'it needs another update installed first (see its Prerequisites)'
    Invalid                   = 'it does not match the hardware model of the cluster'
    Obsolete                  = 'a higher version of this update is already installed'
    DownloadFailed            = 'the download failed (see Get-SolutionUpdateRun and Troubleshoot updates)'
    PreparationFailed         = 'the preparation failed (see Get-SolutionUpdateRun and Troubleshoot updates)'
    HealthCheckFailed         = 'the readiness checks failed (see Get-SolutionHealthSummary and Troubleshoot readiness checks)'
    InstallationFailed        = 'the installation failed; look at the failure first, then resume it with Start-SolutionUpdate (see Troubleshoot updates)'
}

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# The commands that run on the cluster. Each takes the step name first, so one remoting call shape serves both of them.
$Remote = @{
    ReadState = {
        param($Step)
        $environment = Get-SolutionUpdateEnvironment -ErrorAction Stop
        @{
            CurrentVersion = [string]$environment.CurrentVersion
            State          = [string]$environment.State
            HealthState    = [string]$environment.HealthState
            Updates        = @(Get-SolutionUpdate -ErrorAction Stop | ForEach-Object {
                    @{ ResourceId = [string]$_.ResourceId; Version = [string]$_.Version; State = [string]$_.State; PackageType = [string]$_.PackageType; DisplayName = [string]$_.DisplayName }
                })
        }
    }
    StartUpdate = {
        param($Step, $ResourceId)
        [string](Get-SolutionUpdate -Id $ResourceId -ErrorAction Stop | Start-SolutionUpdate -ErrorAction Stop)
    }
}
function Invoke-Cluster([string]$Step, [object[]]$Arguments = @()) {
    $call = @{ ComputerName = $script:target; ScriptBlock = $Remote[$Step]; ArgumentList = (, $Step + $Arguments); ErrorAction = 'Stop' }
    if ($Credential) { $call.Credential = $Credential }
    Invoke-Command @call
}
function ConvertTo-UpdateVersion([string]$Text) {
    $parsed = $null
    if ([version]::TryParse($Text, [ref]$parsed)) { return $parsed }
    $null
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$switchRaw = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.updates.install_after_deployment'
if ($null -ne $switchRaw -and $switchRaw -isnot [bool]) { Exit-InputProblem "operations.updates.install_after_deployment must be true or false; found '$switchRaw'." }
if (-not $switchRaw) {
    Write-Line 'operations.updates.install_after_deployment is not true: no update is started.'
    exit 0
}

$targetRaw = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.updates.target_version')).Trim()
if (-not $targetRaw) { $targetRaw = 'latest' }
$wantLatest = $targetRaw -ieq 'latest'
$targetVersion = $null
if (-not $wantLatest) {
    if ($targetRaw -notmatch '^\d+\.\d+\.\d+\.\d+$') { Exit-InputProblem "operations.updates.target_version must be latest or a solution version of four numbers, for example 12.2610.1004.50; found '$targetRaw'." }
    $targetVersion = ConvertTo-UpdateVersion $targetRaw
    if (-not $targetVersion) { Exit-InputProblem "operations.updates.target_version '$targetRaw' is not a version number." }
}

$target = if ($ComputerName) { $ComputerName.Trim() } else { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim() }
if (-not $target) { Exit-InputProblem 'cluster.name is missing. It is the cluster the script connects to (or give -ComputerName).' }

# ---- the cluster as it is (read only)
Write-Line "Cluster '$target': reading the update environment and the discovered updates"
try { $state = Invoke-Cluster 'ReadState' }
catch { Exit-Failed "The cluster '$target' could not be read: $($_.Exception.Message)" }
$current = ConvertTo-UpdateVersion ([string]$state.CurrentVersion)
Write-Line "Installed solution version $($state.CurrentVersion), update environment state $($state.State), health $($state.HealthState)"

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed] ' } { $_ -like 'Already*' } { '[exists] ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[done]   ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Item, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}
$follow = 'Follow it with Get-SolutionUpdate -Id <ResourceId> | ft Version,State,UpdateStateProperties,HealthState on a machine, or in Update Manager in the Azure portal; Sonar watches the progress.'

try {
    $solution = @(@($state.Updates) | Where-Object { $_.PackageType -eq 'Solution' })

    # an update that is already running
    $running = @($solution | Where-Object { $RunningState -contains $_.State })
    if ($running) {
        $first = $running[0]
        Add-Row "solution update $($first.Version)" 'AlreadyRunning' "state $($first.State); nothing is started. $follow"
    }
    elseif ($targetVersion -and $current -and $current -eq $targetVersion) {
        Add-Row "solution update $targetRaw" 'AlreadyAtTarget' "the instance runs $($state.CurrentVersion)"
    }
    else {
        # the update to start
        $chosen = $null
        if ($targetVersion) {
            if ($current -and $targetVersion -lt $current) { throw "operations.updates.target_version $targetRaw is older than the installed solution version $($state.CurrentVersion). A solution update never goes back to an older version." }
            $chosen = @($solution | Where-Object { (ConvertTo-UpdateVersion $_.Version) -eq $targetVersion }) | Select-Object -First 1
            if (-not $chosen) { throw "The update service lists no solution update $targetRaw (it lists: $(@($solution | ForEach-Object { "$($_.Version) $($_.State)" }) -join ', ')). It can take a week after the release date before an update is visible; Add-SolutionUpdate imports one by hand." }
            if ($chosen.State -eq 'Installed') { Add-Row "solution update $targetRaw" 'AlreadyAtTarget' 'the update is installed'; $chosen = $null }
            elseif ($StartableState -notcontains $chosen.State) { throw "Solution update $targetRaw is in the state $($chosen.State): $(if ($StateAdvice.ContainsKey($chosen.State)) { $StateAdvice[$chosen.State] } else { 'it cannot be started now' })." }
        }
        else {
            $ready = @($solution | Where-Object { $StartableState -contains $_.State } | Sort-Object { ConvertTo-UpdateVersion $_.Version } -Descending)
            if ($ready) {
                $chosen = $ready[0]
                # a newer update that failed is looked at first: an older one is never started past it
                $newerStuck = @($solution | Where-Object { $StateAdvice.ContainsKey($_.State) -and $_.State -ne 'Obsolete' -and $_.State -ne 'Invalid' -and (ConvertTo-UpdateVersion $_.Version) -gt (ConvertTo-UpdateVersion $chosen.Version) })
                if ($newerStuck) { throw "Solution update $($chosen.Version) is ready, but the newer $($newerStuck[0].Version) is in the state $($newerStuck[0].State): $($StateAdvice[$newerStuck[0].State]). Nothing is started; fix the newer update, or name the version to install in operations.updates.target_version." }
            }
            else {
                $stuck = @($solution | Where-Object { $StateAdvice.ContainsKey($_.State) -and $_.State -ne 'Obsolete' -and $_.State -ne 'Invalid' })
                if ($stuck) { throw "No solution update is ready to install. $($stuck[0].Version) is in the state $($stuck[0].State): $($StateAdvice[$stuck[0].State])." }
                Add-Row 'solution update latest' 'AlreadyAtTarget' "no newer solution update is ready; the instance runs $($state.CurrentVersion)"
            }
            if ($chosen -and $current -and (ConvertTo-UpdateVersion $chosen.Version) -le $current) { Add-Row "solution update $($chosen.Version)" 'AlreadyAtTarget' "the instance runs $($state.CurrentVersion)"; $chosen = $null }
        }

        if ($chosen) {
            $item = "solution update $($chosen.Version)"
            if ($BlockingHealth -contains $state.HealthState) { throw "The update environment health is $($state.HealthState), so $item is not started. Fix it first (Learn: Troubleshoot readiness checks; Get-SolutionHealthSummary shows the details)." }
            if ($PSCmdlet.ShouldProcess("$item on '$target'", 'Start-SolutionUpdate (download, readiness checks, install)')) {
                $run = Invoke-Cluster 'StartUpdate' @($chosen.ResourceId)
                Add-Row $item 'Started' "run $run, ResourceId $($chosen.ResourceId). The script does not wait. $follow"
            }
            else { Add-Row $item 'WouldStart' "$($chosen.DisplayName), state $($chosen.State)" }
        }
    }
}
catch { Add-Row 'solution update' 'Failed' $_.Exception.Message }

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
