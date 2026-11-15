#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the example ARM parameter files of config/azure/arm-templates/examples from the example infrastructure files, with the toolkit's
    own parameter builder. -Check fails when a committed example is not what the builder writes.

.DESCRIPTION
    The examples show what the deployment sends to Microsoft's quickstart template for a few designs. They are not written by hand: each is
    built from an example infrastructure file of config/variables/examples (example values only: the IIC example company, documentation
    address ranges, zero GUIDs) by the same code the deployment uses (New-AzlArmParameterSet and ConvertTo-AzlArmParameterFile of
    scripts/common/arm-deployment/AzlArmDeployment.psm1, as New-AzureLocalArmParameters.ps1 calls them), and checked with
    Test-AzlArmParameterSet against the parameters of the template the design selects (config/azure/arm-templates/template-parameters.json).

    Inputs the builder takes from outside the file are fixed so the output is the same on every machine:
      no ZTP handoff           the Arc machine IDs are built from azure.subscription_id, azure.resource_group and the machine names
      no OS configuration report  the adapter names are the file's names (the builder warns; the run does not)
      no SBE folder            hardware.sbe.bundle_path is not read: the SBE values are those of the file, or none
      the HCI resource provider object ID  the file's azure.hci_resource_provider_object_id, else the zero GUID (the deployment looks it up)
      secrets                  Key Vault references (-SecretMode KeyVaultReference), never values
    Reads files only; nothing runs against Azure.

    Exit codes: 0 written, or -Check found every example up to date; 1 -Check found an example missing, different or not in the list;
    2 an example infrastructure file does not build (the message says why).

.PARAMETER Check
    Compare the committed examples with what the builder writes; change nothing.

.PARAMETER Root
    The toolkit root. Default: the root of this repository.

.EXAMPLE
    pwsh -File config/variables/scripts/New-ArmParameterExample.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$Root
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..')) }
$common = [IO.Path]::Combine($Root, 'scripts', 'common')
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'azure-local', 'AzlAzure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'node-configuration', 'AzlNodeConfiguration.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'arm-deployment', 'AzlArmDeployment.psm1')) -Force

$examples = [IO.Path]::Combine($Root, 'config', 'variables', 'examples')
$outDir = [IO.Path]::Combine($Root, 'config', 'azure', 'arm-templates', 'examples')
# The zero GUID stands for the HCI resource provider's object ID when the example file has none (the deployment looks it up in the directory).
$ExampleObjectId = '00000000-0000-0000-0000-000000000000'

# Example parameter file -> the example infrastructure file it is built from.
$list = [ordered]@{
    'active-directory-s2d-switched.parameters.json' = 'infrastructure.example.yml'
    'local-identity-s2d-switchless.parameters.json' = 'scenarios/local-identity-switchless-iso.yml'
    'rack-aware-s2d.parameters.json'                = 'scenarios/rack-aware-ztp.yml'
    'fibre-channel-san.parameters.json'             = 'scenarios/disaggregated-fibre-channel-proxy.yml'
}

function ConvertTo-ExampleText([string]$Source) {
    $infra = Import-AzlInfrastructure -Path $Source -SkipValidation
    $arguments = @{ Infrastructure = $infra; AllowUnresolvedSanLun = $true }
    if (-not [string](Get-AzlProp $infra 'azure.hci_resource_provider_object_id' '')) { $arguments.HciResourceProviderObjectId = $ExampleObjectId }
    $set = New-AzlArmParameterSet @arguments
    $definitions = (Get-AzlArmTemplateCatalog).templates[$set.Template.Name].parameters
    $problems = @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $definitions)
    if ($problems.Count) { throw "$([IO.Path]::GetFileName($Source)): $($problems -join ' ')" }
    $text = (ConvertTo-AzlArmParameterFile -ParameterSet $set -Infrastructure $infra -SecretMode KeyVaultReference) -replace "`r`n", "`n"
    return $text.TrimEnd("`n") + "`n"
}

$wanted = [ordered]@{}
foreach ($name in $list.Keys) {
    $source = [IO.Path]::Combine($examples, $list[$name])
    try { $wanted[$name] = ConvertTo-ExampleText $source }
    catch { Write-Error "Example $name does not build from $($list[$name]): $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
}

$present = @(Get-ChildItem -LiteralPath $outDir -File -Filter '*.parameters.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
if ($Check) {
    $bad = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $wanted.Keys) {
        $path = [IO.Path]::Combine($outDir, $name)
        if (-not (Test-Path -LiteralPath $path)) { $bad.Add("$name is missing"); continue }
        $committed = ([IO.File]::ReadAllText($path)) -replace "`r`n", "`n"
        if ($committed -cne $wanted[$name]) { $bad.Add("$name differs from what $($list[$name]) builds") }
    }
    foreach ($name in $present) { if (-not $wanted.Contains($name)) { $bad.Add("$name is not built from an example file (remove it or add it to the list)") } }
    if ($bad.Count) {
        foreach ($b in $bad) { Write-Warning $b }
        Write-Error "The ARM parameter examples are not up to date. Run: pwsh -File config/variables/scripts/New-ArmParameterExample.ps1" -ErrorAction Continue
        exit 1
    }
    Write-Information -InformationAction Continue -MessageData "The $($wanted.Count) ARM parameter examples are up to date."
    exit 0
}

if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
foreach ($name in $present) { if (-not $wanted.Contains($name)) { Remove-Item -LiteralPath ([IO.Path]::Combine($outDir, $name)) } }
foreach ($name in $wanted.Keys) {
    [IO.File]::WriteAllText([IO.Path]::Combine($outDir, $name), $wanted[$name], [Text.UTF8Encoding]::new($false))
}
Write-Information -InformationAction Continue -MessageData "Wrote $($wanted.Count) ARM parameter examples to config/azure/arm-templates/examples."
exit 0
