#Requires -Version 7.0
<#
.SYNOPSIS
    Lists the SBE package files on the share (hardware.sbe.source_path) that the cluster's update service imports, and the exact commands to import them. Executes nothing.

.DESCRIPTION
    The OEM Solution Builder Extension is a requirement of the file: the package is downloaded and available on a share the automation can read. This is where it is used after
    the deployment. Microsoft Learn (Update Azure Local by using PowerShell, step 3 "Import and rediscover updates"): when an update reports AdditionalContentRequired (the installed
    SBE has no download connector for this cluster, for example Dell without support credentials on the cluster), copy the three SBE files into a folder of the infrastructure volume and
    run Add-SolutionUpdate -SourceFolder on it, then Get-SolutionUpdate until the update is Ready.

    This script reads the share (list, discovery manifest; read only, no hashing, no copy), picks the package the same way the pre-cluster verification does, and PRINTS the files and the
    commands. It does not run them: you run them on a cluster machine, signed in as the deployment user. Nothing is changed on the share, the nodes or in Azure. With
    hardware.sbe.source_username the password is read from Key Vault (hardware.sbe.source_password) into memory for the read; the script does not sign in to Azure.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). hardware.sbe.source_path (else bundle_path) names the share.
.PARAMETER ImportFolder
    The folder on the cluster's infrastructure volume the commands copy the files into. Default: Learn's C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import.
.PARAMETER OutputPath
    Optional. Also write the plan as JSON to this file (files, commands, notes). Keep it out of the repository.
.EXAMPLE
    ./Get-AzureLocalSbeImportPlan.ps1 -InfrastructureFile ./infrastructure.yml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ImportFolder = 'C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import',
    [string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common'))
Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
Import-Module (Join-Path (Join-Path $common 'sbe') 'AzlSbePackage.psm1') -Force

function Write-Line([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }

$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$requirement = Get-AzlSbeRequirement -Infrastructure $infra
if ($requirement.State -eq 'NotApplicable') {
    Write-Line "The file declares the SBE package not applicable: $($requirement.Reason). Nothing to import from a share."
    return
}
$source = Get-AzlSbeSource -Infrastructure $infra
if (-not $source.Path) { throw 'hardware.sbe.source_path is empty: there is no share to import from. Download the vendor package and set hardware.sbe.source_path (the pre-cluster verification SB-001 says the same).' }
$password = ''
if ($source.Username -and $source.PasswordRef) { $password = Get-AzlSecret -Reference $source.PasswordRef }

$scan = Get-AzlSbeSourceScan -Request @{ Path = $source.Path; Username = $source.Username; Password = $password } -Family $source.Family -Version $source.Version -Publisher $source.Publisher -Model @([string](Get-AzlProp $infra 'hardware.model' ''))
if ($scan.Stage -ne 'Listed') { throw "The SBE source $($source.Path) could not be read from this host: $($scan.List.Error)" }
$p = $scan.Selected
if (-not $p) { throw "No single SBE package could be chosen on $($source.Path). $($scan.SelectionNote)$(if ($scan.Ambiguous.Count) { " Packages there: $($scan.Ambiguous -join ', '). Set hardware.sbe.family and hardware.sbe.version." })" }
$missing = @()
if ($scan.Discovery.Count -ne 1) { $missing += 'exactly one SBE_Discovery_<Vendor>.xml' }
if (-not $p.PayloadPresent) { $missing += $p.PayloadName }
if (-not $p.ZipPresent) { $missing += $p.ZipName }
if ($missing.Count) { throw "The package $($p.BaseName) on $($source.Path) is missing: $($missing -join ', '). Download it again from the vendor." }

$plan = Get-AzlSbeImportPlan -SourcePath $source.Path -Package $p -ImportFolder $ImportFolder
Write-Line "SBE package $($p.BaseName) (family $($p.Family), version $($p.Version)) on $($source.Path):"
foreach ($f in $plan.Files) { Write-Line ("  {0,-60} {1}" -f $f.Name, $f.Role) }
Write-Line ''
Write-Line 'Commands (NOT executed; run them on a cluster machine as the deployment user):'
foreach ($c in $plan.Commands) { Write-Line "  $c" }
Write-Line ''
foreach ($n in $plan.Notes) { Write-Line "  Note: $n" }
if ($OutputPath) {
    [ordered]@{ package = $p.BaseName; family = $p.Family; version = $p.Version; source = $source.Path; importFolder = $plan.ImportFolder; files = @($plan.Files); commands = @($plan.Commands); notes = @($plan.Notes) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    Write-Line "Plan written to $OutputPath."
}
$plan
