#Requires -Version 7.0
<#
.SYNOPSIS
    One discovery run, for a pipeline or an operator: the hardware inventory of the BMCs, the Azure tenant inventory and the Active Directory
    inventory, each into its own folder of one output directory, with one report and one summary.

.DESCRIPTION
    Runs the discovery scripts of the toolkit one after the other and gathers what they write:

      HardwareInventory  scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/
                         powershell/Get-HardwareInventory.ps1 (any maker; reads every BMC over the standard Redfish API, GET only)
      DellDiscovery      .../Invoke-HardwareDiscovery.ps1 (Dell iDRAC only; one file per node, a summary and the proposal for nodes[])
      AzureTenant        scripts/common/discovery/Inventory-AzureTenant.ps1 (read only; needs an Az sign-in)
      ActiveDirectory    scripts/common/discovery/Get-OnPremInventory.ps1 (read only; needs the ActiveDirectory module on this host)

    Every value comes from infrastructure.yml, read by the scripts themselves. The BMC login is the secret reference of the file (hardware.bmc
    or nodes[].bmc), resolved at run time by the toolkit secret resolver from the current Az sign-in: this script takes no password, no token
    and no credential, and writes none.

    -WriteBack (needs DellDiscovery in the scope) shows what the discovery would write into infrastructure.yml (serial numbers and MAC
    addresses). It never touches the file you pass: Update-InfrastructureYml-FromDiscovery.ps1 -Apply runs on a COPY in the output directory
    (write-back/<file name>), together with the list of the changes (write-back/changes.txt). Review the copy and commit it through a pull
    request; this script and the pipelines never commit it.

    Output, in -OutputDirectory (keep it out of git; it holds serial numbers and MAC addresses):
      discovery-report.json   what ran, the exit code of each step, the files each step wrote, the verdict
      summary.md              the same for a person and a pipeline job summary
      hardware-inventory/, hardware-discovery/, azure-tenant/, ad-inventory/, write-back/   what the steps wrote

    Exit codes: 0 every step succeeded; 1 at least one step failed (the other steps still ran, the report lists each); 2 bad input
    (the file cannot be read, an empty scope, -WriteBack without DellDiscovery): nothing was run.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. It is read, never written.

.PARAMETER OutputDirectory
    Where the report, the summary and the step folders go. Required. Created when missing.

.PARAMETER Scope
    The steps to run: HardwareInventory, DellDiscovery, AzureTenant, ActiveDirectory. Default: HardwareInventory, AzureTenant, ActiveDirectory.

.PARAMETER ManagementPort
    DellDiscovery and -WriteBack: the management port of every node, by suggested name or MAC (see Invoke-HardwareDiscovery.ps1).

.PARAMETER WriteBack
    Also prepare the infrastructure.yml values that DellDiscovery found, in a copy of the file. The file you passed is not changed.

.PARAMETER IncludeRBAC
    AzureTenant: also record the role assignments.

.PARAMETER ToolkitRoot
    The toolkit checkout to take the scripts from. Default: the one this script is in.

.EXAMPLE
    ./Invoke-AzlDiscoveryRun.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory ./discovery-run

    Inventories the BMCs, the Azure tenant and the Active Directory OU into ./discovery-run.

.EXAMPLE
    ./Invoke-AzlDiscoveryRun.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory ./discovery-run -Scope DellDiscovery -WriteBack

    Reads the Dell BMCs and prepares a copy of infrastructure.yml with the serial numbers and MAC addresses found.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('HardwareInventory', 'DellDiscovery', 'AzureTenant', 'ActiveDirectory')][string[]]$Scope = @('HardwareInventory', 'AzureTenant', 'ActiveDirectory'),
    [string]$ManagementPort,
    [switch]$WriteBack,
    [switch]$IncludeRBAC,
    [string]$ToolkitRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ToolkitRoot) { $ToolkitRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..')) }
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

if (-not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { Exit-InputProblem "The infrastructure file '$InfrastructureFile' does not exist." }
$InfrastructureFile = (Resolve-Path -LiteralPath $InfrastructureFile).Path
# The file must parse as a YAML mapping (the same read every discovery script makes); a file that cannot be read ends the run here, with nothing run and nothing created.
# It is not validated against the schema: a file that is still being filled in is exactly what discovery is for.
try { $null = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "The infrastructure file '$InfrastructureFile' cannot be read: $($_.Exception.Message)" }
if (@($Scope).Count -eq 0) { Exit-InputProblem 'The scope is empty: name at least one step.' }
if ($WriteBack -and 'DellDiscovery' -notin $Scope) { Exit-InputProblem '-WriteBack needs DellDiscovery in -Scope: there is nothing to write back without it.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$hardwareFolder = 'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell'
$scripts = [ordered]@{
    HardwareInventory = "$hardwareFolder/Get-HardwareInventory.ps1"
    DellDiscovery     = "$hardwareFolder/Invoke-HardwareDiscovery.ps1"
    AzureTenant       = 'scripts/common/discovery/Inventory-AzureTenant.ps1'
    ActiveDirectory   = 'scripts/common/discovery/Get-OnPremInventory.ps1'
}
$updater = "$hardwareFolder/Update-InfrastructureYml-FromDiscovery.ps1"
$folders = @{ HardwareInventory = 'hardware-inventory'; DellDiscovery = 'hardware-discovery'; AzureTenant = 'azure-tenant'; ActiveDirectory = 'ad-inventory' }

function Get-ToolkitScript([string]$Relative) { Join-Path $ToolkitRoot ($Relative.Replace("/", [IO.Path]::DirectorySeparatorChar)) }

# The files under a folder, relative to the output directory, with forward slashes.
function Get-OutputFile([string]$Folder, [datetime]$Since) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $Folder -Recurse -File | Where-Object { $_.LastWriteTimeUtc -ge $Since } |
            ForEach-Object { [IO.Path]::GetRelativePath($OutputDirectory, $_.FullName).Replace('\', '/') } | Sort-Object)
}

# Run one script, return its exit code and message. A script that throws is a failed step (exit code 1); its own exit code otherwise.
function Invoke-Step([string]$Path, [hashtable]$Arguments, [string]$WorkingDirectory) {
    $message = ''
    $code = 0
    Push-Location -LiteralPath $WorkingDirectory
    try {
        $global:LASTEXITCODE = 0
        & $Path @Arguments | Out-Null
        $code = [int]$global:LASTEXITCODE
    }
    catch { $message = $_.Exception.Message; $code = 1 }
    finally { Pop-Location }
    [pscustomobject]@{ ExitCode = $code; Message = $message }
}

$started = [datetime]::UtcNow
$steps = [System.Collections.Generic.List[object]]::new()
foreach ($name in $scripts.Keys) {
    if ($name -notin $Scope) { continue }
    $relative = $scripts[$name]
    $script = Get-ToolkitScript $relative
    $folder = Join-Path $OutputDirectory $folders[$name]
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $since = [datetime]::UtcNow.AddSeconds(-1)
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        $steps.Add([ordered]@{ name = $name; script = $relative; status = 'Failed'; exitCode = 1; message = "The script $relative does not exist in this toolkit."; folder = $folders[$name]; files = @() })
        continue
    }
    Write-Information -InformationAction Continue -MessageData "Discovery step $name ($relative)."
    $arguments = @{ InfrastructureFile = $InfrastructureFile }
    switch ($name) {
        'HardwareInventory' { }   # writes into hardware.inventory.output_directory, relative to the folder it runs in
        'DellDiscovery' { $arguments.OutputPath = $folder; if ($ManagementPort) { $arguments.ManagementPort = $ManagementPort } }
        'AzureTenant' { $arguments.OutputPath = $folder; if ($IncludeRBAC) { $arguments.IncludeRBAC = $true } }
        'ActiveDirectory' { $arguments.OutputPath = Join-Path $folder 'ad-inventory.json' }
    }
    $r = Invoke-Step -Path $script -Arguments $arguments -WorkingDirectory $folder
    # an inventory the file sends to an absolute folder is copied next to the others
    $files = @(Get-OutputFile $folder $since)
    if ($name -eq 'HardwareInventory') {
        $module = Get-ToolkitScript 'scripts/common/infrastructure/AzlInfrastructure.psm1'
        if (Test-Path -LiteralPath $module -PathType Leaf) {
            try {
                Import-Module $module -Force
                $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
                $configured = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'hardware.inventory.output_directory')).Trim()
                if ($configured -and [IO.Path]::IsPathRooted($configured) -and (Test-Path -LiteralPath $configured -PathType Container)) {
                    foreach ($f in Get-ChildItem -LiteralPath $configured -File | Where-Object { $_.LastWriteTimeUtc -ge $since }) { Copy-Item -LiteralPath $f.FullName -Destination $folder -Force }
                    $files = @(Get-OutputFile $folder $since)
                }
            }
            catch { Write-Warning "The hardware inventory folder of the file could not be read: $($_.Exception.Message)" }
        }
    }
    $steps.Add([ordered]@{ name = $name; script = $relative; status = $(if ($r.ExitCode -eq 0) { 'Succeeded' } else { 'Failed' }); exitCode = $r.ExitCode; message = $r.Message; folder = $folders[$name]; files = $files })
}

# The write-back: the discovery values in a copy of the file. The file itself is never changed.
$writeBackReport = [ordered]@{ requested = $WriteBack.IsPresent; applied = $false; file = $null; changes = $null; message = '' }
if ($WriteBack) {
    $dell = @($steps | Where-Object { $_.name -eq 'DellDiscovery' })[0]
    if ($dell.status -ne 'Succeeded') { $writeBackReport.message = 'Skipped: the DellDiscovery step did not succeed.' }
    else {
        $folder = Join-Path $OutputDirectory 'write-back'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $copy = Join-Path $folder (Split-Path -Leaf $InfrastructureFile)
        Copy-Item -LiteralPath $InfrastructureFile -Destination $copy -Force
        $updaterPath = Get-ToolkitScript $updater
        $arguments = @{ InfrastructureFile = $copy; DiscoveryPath = (Join-Path $OutputDirectory $folders.DellDiscovery); Apply = $true; Force = $true }
        if ($ManagementPort) { $arguments.ManagementPort = $ManagementPort }
        $changes = Join-Path $folder 'changes.txt'
        $code = 0
        $message = ''
        Push-Location -LiteralPath $folder
        try {
            $global:LASTEXITCODE = 0
            & $updaterPath @arguments *>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath $changes -Encoding utf8
            $code = [int]$global:LASTEXITCODE
        }
        catch { $message = $_.Exception.Message; $code = 1 }
        finally { Pop-Location }
        # the updater saves a backup of the copy it edits; the original is the file in the repository
        Get-ChildItem -LiteralPath $folder -File -Filter '*.bak.*' -ErrorAction SilentlyContinue | Remove-Item -Force
        if ($code -eq 0) {
            $writeBackReport.applied = $true
            $writeBackReport.file = [IO.Path]::GetRelativePath($OutputDirectory, $copy).Replace('\', '/')
            $writeBackReport.changes = [IO.Path]::GetRelativePath($OutputDirectory, $changes).Replace('\', '/')
            $writeBackReport.message = 'The copy holds the discovered values; the file you passed is unchanged. Review it and commit it through a pull request.'
        }
        else { $writeBackReport.message = "The write-back failed (exit code $code). $message".Trim() }
    }
}

$failed = @($steps | Where-Object { $_.status -ne 'Succeeded' })
$writeBackFailed = $WriteBack -and -not $writeBackReport.applied
$verdict = if ($failed.Count -eq 0 -and -not $writeBackFailed) { 'Pass' } else { 'Fail' }
$report = [ordered]@{
    schema = 1; startedUtc = $started.ToString('o'); completedUtc = [datetime]::UtcNow.ToString('o')
    infrastructureFile = (Split-Path -Leaf $InfrastructureFile); scope = @($Scope); verdict = $verdict
    steps = @($steps); writeBack = $writeBackReport
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'discovery-report.json') -Encoding utf8

$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# Discovery run')
$md.Add('')
$md.Add("Verdict: **$verdict**. Infrastructure file: ``$(Split-Path -Leaf $InfrastructureFile)``.")
$md.Add('')
$md.Add('| Step | Result | Exit code | Files |')
$md.Add('| --- | --- | --- | --- |')
foreach ($s in $steps) { $md.Add("| $($s.name) | $($s.status) | $($s.exitCode) | $(@($s.files).Count) |") }
foreach ($s in @($steps | Where-Object { $_.message })) { $md.Add(''); $md.Add("$($s.name): $($s.message)") }
if ($WriteBack) { $md.Add(''); $md.Add("Write-back: $($writeBackReport.message)") }
Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Value $md -Encoding utf8

Write-Information -InformationAction Continue -MessageData "Discovery run: verdict $verdict. Report: $(Join-Path $OutputDirectory 'discovery-report.json')"
exit $(if ($verdict -eq 'Pass') { 0 } else { 1 })
