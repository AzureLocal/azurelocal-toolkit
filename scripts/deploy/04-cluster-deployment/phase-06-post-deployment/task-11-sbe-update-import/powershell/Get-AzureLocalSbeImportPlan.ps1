#Requires -Version 7.0
<#
.SYNOPSIS
    Lists the SBE package files on the share (hardware.sbe.source_path) that the cluster's update service imports, and the exact commands to import them. With
    -Execute it also runs them on a cluster machine: copy, check the hash, Add-SolutionUpdate, then wait until the update is Ready.

.DESCRIPTION
    The OEM Solution Builder Extension is a requirement of the file: the package is downloaded and available on a share the automation can read. This is where it is used after
    the deployment. Microsoft Learn (Update Azure Local by using PowerShell, step 3 "Import and rediscover updates"): when an update reports AdditionalContentRequired (the installed
    SBE has no download connector for this cluster, for example Dell without support credentials on the cluster), copy the three SBE files into a folder of the infrastructure volume and
    run Add-SolutionUpdate -SourceFolder on it, then Get-SolutionUpdate until the update is Ready.

    Without -Execute, or with -WhatIf (the default is the plan), the script reads the share (list, discovery manifest; read only, no hashing, no copy), picks the package the same way the pre-cluster verification
    does, and PRINTS the files and the commands. It does not run them. Nothing is changed on the share, the nodes or in Azure. With hardware.sbe.source_username the password is read
    from the secret reference hardware.sbe.source_password into memory for the read; the script does not sign in to Azure.

    With -Execute the script runs the import steps of the guide page, over PowerShell remoting on one machine of the cluster, as the deployment user (never prompts):
      1. reads Get-SolutionUpdate on the machine. The import is only for an update that reports AdditionalContentRequired: when none does, the result is NotNeeded (an update that is
         Ready already means the vendor connector works) and nothing is copied or imported;
      2. creates the import folder and copies the three files into it from the share (a file that is there with the same size is not copied again). The share must be readable from the
         machine: with hardware.sbe.source_username the machine mounts the share with that account (an explicit account avoids the second hop of a remoting session); without it the machine
         reads the share as the deployment user, which needs a share that allows it;
      3. checks the SHA256 of the zip against the PackageHash of the discovery manifest, and stops (nothing is imported) when they differ;
      4. runs Add-SolutionUpdate -SourceFolder on the import folder;
      5. reads Get-SolutionUpdate every -PollSeconds, up to -MaxWaitMinutes, until no update reports AdditionalContentRequired and one is Ready (discovery is asynchronous). An update that
         reports Invalid (it does not match the hardware model or family) fails the run.
    Without -Execute, or with -WhatIf, nothing is run and no machine is asked (that is the plan, and the default). The import does not install the update: starting it is task 02 of the day 2 operations.

    Login for -Execute: -Credential, else the account of the file: identity.active_directory.lcm_user (as <netbios name>\<user>; the deployment user) with active_directory,
    identity.local_admin (as .\<user>) with local_identity; the password is a secret reference read through scripts/common/secrets/AzlSecret.psm1. With neither: exit code 2.
    The machine is -ComputerName, else the management address of the first node of nodes[], then the next one.

    Exit codes: 0 the plan was printed, or the import is done (or not needed); 1 the share could not be read, a step failed, the hash differs, the update
    is Invalid, or the wait ran out; 2 a value of the file is missing or not usable (no source path, no single package, a file missing from the package, no login).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). hardware.sbe.source_path (else bundle_path) names the share.
.PARAMETER ImportFolder
    The folder on the cluster's infrastructure volume the commands copy the files into. Default: Learn's C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import.
.PARAMETER OutputPath
    Optional. Also write the plan as JSON to this file (files, commands, notes). Keep it out of the repository.
.PARAMETER Execute
    Run the import steps on a cluster machine (see above). Without it nothing is run.
.PARAMETER ComputerName
    Optional, with -Execute. The cluster machine to run the steps on, instead of the first node of nodes[].
.PARAMETER Credential
    Optional, with -Execute. The account for the remoting session (the deployment user). Without it the account of the file is used.
.PARAMETER MaxWaitMinutes
    With -Execute. The longest time to wait for the update to be Ready after the import, in minutes (0 to 240; 0 does not wait). Default: 30.
.PARAMETER PollSeconds
    With -Execute. Seconds between two reads of Get-SolutionUpdate while waiting (1 to 600). Default: 30.
.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.
.EXAMPLE
    ./Get-AzureLocalSbeImportPlan.ps1 -InfrastructureFile ./infrastructure.yml

    Prints the files and the commands. Runs nothing.
.EXAMPLE
    ./Get-AzureLocalSbeImportPlan.ps1 -InfrastructureFile ./infrastructure.yml -Execute

    Copies the files, checks the hash, imports the package and waits until the update is Ready.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ImportFolder = 'C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import',
    [string]$OutputPath,
    [switch]$Execute,
    [string]$ComputerName,
    [pscredential]$Credential,
    [ValidateRange(0, 240)][int]$MaxWaitMinutes = 30,
    [ValidateRange(1, 600)][int]$PollSeconds = 30,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath
# -WhatIf default: nothing is run unless -Execute is given and -WhatIf is not.
$runImport = ($Execute.IsPresent -and -not $WhatIfPreference)

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common'))
Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'sbe') 'AzlSbePackage.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'secrets') 'AzlSecret.psm1') -Force

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

# The commands that run on the cluster machine (-Execute). Each takes the step name first, so one remoting call shape serves all of them.
$Remote = @{
    Probe       = { param($Step) [string]$env:COMPUTERNAME }
    ReadUpdates = {
        param($Step)
        @(Get-SolutionUpdate -ErrorAction Stop | ForEach-Object { @{ DisplayName = [string]$_.DisplayName; PackageType = [string]$_.PackageType; Version = [string]$_.Version; SbeVersion = [string]$_.SbeVersion; State = [string]$_.State } })
    }
    CopyFiles   = {
        param($Step, $Source, $Names, $Folder, [pscredential]$ShareCredential)
        $null = New-Item -ItemType Directory -Force -Path $Folder -ErrorAction Stop
        $drive = $null
        $copied = @(); $kept = @()
        try {
            $root = $Source
            if ($ShareCredential) {
                $drive = New-PSDrive -Name ('Sbe' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -PSProvider FileSystem -Root $Source -Credential $ShareCredential -ErrorAction Stop
                $root = "$($drive.Name):\"
            }
            foreach ($name in $Names) {
                $from = Join-Path $root $name
                $to = Join-Path $Folder $name
                $fromItem = Get-Item -LiteralPath $from -ErrorAction Stop
                if ((Test-Path -LiteralPath $to) -and (Get-Item -LiteralPath $to).Length -eq $fromItem.Length) { $kept += $name; continue }
                Copy-Item -LiteralPath $from -Destination $Folder -Force -ErrorAction Stop
                $copied += $name
            }
        }
        finally { if ($drive) { Remove-PSDrive -Name $drive.Name -Force -ErrorAction SilentlyContinue } }
        @{ Copied = $copied; Kept = $kept }
    }
    HashFile    = { param($Step, $Path) @{ Hash = [string](Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash } }
    Import      = { param($Step, $Folder) $null = Add-SolutionUpdate -SourceFolder $Folder -ErrorAction Stop }
}
function Invoke-Node([string]$Computer, [string]$Step, [object[]]$Arguments = @()) {
    Invoke-Command -ComputerName $Computer -Credential $script:remoteCredential -ScriptBlock $Remote[$Step] -ArgumentList (, $Step + $Arguments) -ErrorAction Stop
}

try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }
$requirement = Get-AzlSbeRequirement -Infrastructure $infra
if ($requirement.State -eq 'NotApplicable') {
    Write-Line "The file declares the SBE package not applicable: $($requirement.Reason). Nothing to import from a share."
    exit 0
}
$source = Get-AzlSbeSource -Infrastructure $infra
if (-not $source.Path) { Exit-InputProblem 'hardware.sbe.source_path is empty: there is no share to import from. Download the vendor package and set hardware.sbe.source_path (the pre-cluster verification SB-001 says the same).' }
$password = ''
if ($source.Username -and $source.PasswordRef) { $password = Get-AzlSecret -Reference $source.PasswordRef -Infrastructure $infra }

$scan = Get-AzlSbeSourceScan -Request @{ Path = $source.Path; Username = $source.Username; Password = $password } -Family $source.Family -Version $source.Version -Publisher $source.Publisher -Model @([string](Get-AzlProp $infra 'hardware.model' ''))
if ($scan.Stage -ne 'Listed') { Exit-Failed "The SBE source $($source.Path) could not be read from this host: $($scan.List.Error)" }
$p = $scan.Selected
if (-not $p) { Exit-InputProblem "No single SBE package could be chosen on $($source.Path). $($scan.SelectionNote)$(if ($scan.Ambiguous.Count) { " Packages there: $($scan.Ambiguous -join ', '). Set hardware.sbe.family and hardware.sbe.version." })" }
$missing = @()
if ($scan.Discovery.Count -ne 1) { $missing += 'exactly one SBE_Discovery_<Vendor>.xml' }
if (-not $p.PayloadPresent) { $missing += $p.PayloadName }
if (-not $p.ZipPresent) { $missing += $p.ZipName }
if ($missing.Count) { Exit-InputProblem "The package $($p.BaseName) on $($source.Path) is missing: $($missing -join ', '). Download it again from the vendor." }

$plan = Get-AzlSbeImportPlan -SourcePath $source.Path -Package $p -ImportFolder $ImportFolder
Write-Line "SBE package $($p.BaseName) (family $($p.Family), version $($p.Version)) on $($source.Path):"
foreach ($f in $plan.Files) { Write-Line ("  {0,-60} {1}" -f $f.Name, $f.Role) }
Write-Line ''
Write-Line "Commands ($(if ($runImport) { 'run by -Execute below' } else { 'NOT executed; run them on a cluster machine as the deployment user' })):"
foreach ($c in $plan.Commands) { Write-Line "  $c" }
Write-Line ''
foreach ($n in $plan.Notes) { Write-Line "  Note: $n" }
if ($OutputPath) {
    [ordered]@{ package = $p.BaseName; family = $p.Family; version = $p.Version; source = $source.Path; importFolder = $plan.ImportFolder; files = @($plan.Files); commands = @($plan.Commands); notes = @($plan.Notes) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM -WhatIf:$false
    Write-Line "Plan written to $OutputPath."
}
if (-not $runImport) { $plan; return }

# ---------------------------------------------------------------- -Execute: the import steps of the guide page, on a cluster machine
$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch -Wildcard ($Action) { 'Failed' { '[failed]  ' } { $_ -in 'AlreadyDone', 'NotNeeded', 'Verified' } { '[exists]  ' } default { '[done]    ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Item, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}
function Complete-Run { $script:rows; if (@($script:rows | Where-Object Action -EQ 'Failed')) { exit 1 }; exit 0 }
function Format-Updates($Updates) { (@($Updates) | ForEach-Object { "$($_['DisplayName']) $($_['Version']) [$($_['State'])]" }) -join '; ' }

# the login: -Credential, else the account of the file. Nothing is asked.
$remoteCredential = $Credential
if (-not $remoteCredential) {
    if ((Get-Text 'scenario.identity').ToLowerInvariant() -eq 'local_identity') { $user = Get-Text 'identity.local_admin.username'; $reference = Get-Text 'identity.local_admin.password'; $account = ".\$user"; $what = 'identity.local_admin' }
    else {
        $netbios = Get-Text 'identity.active_directory.netbios_name'
        $user = Get-Text 'identity.active_directory.lcm_user.username'; $reference = Get-Text 'identity.active_directory.lcm_user.password'
        $account = if ($user -match '\\|@') { $user } elseif ($netbios) { "$netbios\$user" } else { $user }
        $what = 'identity.active_directory.lcm_user'
    }
    if (-not $user -or -not $reference) { Exit-InputProblem "No login for the cluster machine: pass -Credential, or set $what username and password (a secret reference) in the file. The import runs as the deployment user." }
    try { $remoteCredential = [pscredential]::new($account, (Get-AzlSecretValue -Reference $reference -Infrastructure $infra)) }
    catch { Exit-InputProblem "The password of $what could not be read: $($_.Exception.Message)" }
}

# the machine: -ComputerName, else the first node that answers
$candidates = @(if ($ComputerName) { $ComputerName.Trim() } else { @(Get-AzlInfrastructureNode -Infrastructure $infra | ForEach-Object { if ($_.ManagementIp) { $_.ManagementIp } else { $_.Name } }) })
if ($candidates.Count -eq 0) { Exit-InputProblem 'nodes[] is empty in the infrastructure file, and no -ComputerName was given.' }
$target = ''; $firstError = ''
foreach ($candidate in $candidates) {
    try { $null = Invoke-Node $candidate 'Probe'; $target = $candidate; break }
    catch { if (-not $firstError) { $firstError = "${candidate}: $($_.Exception.Message)" } }
}
if (-not $target) { Add-Row 'cluster machine' 'Failed' "no machine answered over PowerShell remoting ($firstError)"; Complete-Run }
Write-Line "Connected to '$target' as $($remoteCredential.UserName)."

try {
    # 1. is there anything to import?
    $updates = @(Invoke-Node $target 'ReadUpdates')
    $needs = @($updates | Where-Object { [string]$_['State'] -eq 'AdditionalContentRequired' })
    if ($needs.Count -eq 0) {
        Add-Row 'SBE import' 'NotNeeded' $(if ($updates.Count) { "no update reports AdditionalContentRequired: $(Format-Updates $updates)" } else { 'Get-SolutionUpdate lists no update; check for updates first (day 2, task 01)' })
        Complete-Run
    }
    $needVersions = @($needs | ForEach-Object { [string]$_['Version'] })
    Add-Row 'update state' 'Verified' "AdditionalContentRequired: $(Format-Updates $needs)"

    # 2. copy, 3. hash, 4. import, 5. wait
    $names = @($plan.Files | ForEach-Object { $_.Name })
    $shareCredential = $null
    if ($source.Username -and $password) { $shareCredential = [pscredential]::new($source.Username, (ConvertTo-SecureString -String $password -AsPlainText -Force)) }
    try {
        $copy = Invoke-Node $target 'CopyFiles' @($plan.SourceFolder, $names, $ImportFolder, $shareCredential)
        Add-Row 'copy the SBE files' $(if (@($copy['Copied']).Count) { 'Copied' } else { 'AlreadyDone' }) "copied: $(@($copy['Copied']) -join ', '); already there: $(@($copy['Kept']) -join ', ')"
    }
    catch {
        Add-Row 'copy the SBE files' 'Failed' "$($_.Exception.Message) The share must be readable from the cluster machine: set hardware.sbe.source_username and hardware.sbe.source_password, or share the folder with the deployment user."
        Complete-Run
    }
    $wanted = ([string]$scan.Entry.PackageHash).Trim().ToUpperInvariant()
    $got = ([string](Invoke-Node $target 'HashFile' @("$ImportFolder\$($p.ZipName)"))['Hash']).Trim().ToUpperInvariant()
    if (-not $wanted) { Add-Row 'hash of the zip' 'Failed' "the discovery manifest has no PackageHash for $($p.BaseName), so the zip cannot be checked. Nothing was imported."; Complete-Run }
    if ($got -ne $wanted) { Add-Row 'hash of the zip' 'Failed' "the SHA256 of $($p.ZipName) on the machine is $got, the discovery manifest says $wanted. Nothing was imported; download the package again."; Complete-Run }
    Add-Row 'hash of the zip' 'Verified' "SHA256 $got"
    $null = Invoke-Node $target 'Import' @($ImportFolder)
    Add-Row 'Add-SolutionUpdate' 'Imported' $ImportFolder

    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    do {
        $after = @(Invoke-Node $target 'ReadUpdates')
        $invalid = @($after | Where-Object { [string]$_['State'] -eq 'Invalid' })
        $pending = @($after | Where-Object { [string]$_['State'] -eq 'AdditionalContentRequired' })
        $ready = @($after | Where-Object { [string]$_['State'] -eq 'Ready' -and [string]$_['Version'] -in $needVersions })
        if ($invalid.Count -gt 0 -or ($pending.Count -eq 0 -and $ready.Count -gt 0) -or $MaxWaitMinutes -eq 0 -or (Get-Date) -ge $deadline) { break }
        Write-Line "[waiting] $(Format-Updates $after)"
        Start-Sleep -Seconds $PollSeconds
    } while ($true)
    if ($invalid.Count -gt 0) { Add-Row 'update state after the import' 'Failed' "an update is Invalid: it does not match the hardware model or the family. Import only the SBE family that matches the nodes. $(Format-Updates $after)" }
    elseif ($pending.Count -eq 0 -and $ready.Count -gt 0) { Add-Row 'update state after the import' 'Verified' "Ready: $(Format-Updates $ready)" }
    else { Add-Row 'update state after the import' 'Failed' "not Ready after $MaxWaitMinutes minute(s) (discovery is asynchronous): $(Format-Updates $after). Run Get-SolutionUpdate again later." }
}
catch { Add-Row 'SBE import' 'Failed' $_.Exception.Message }
Complete-Run
