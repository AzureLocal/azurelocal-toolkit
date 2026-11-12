#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the infrastructure.yml schema, the master template, the purpose templates and schemas, from the master registry.

.DESCRIPTION
    config/variables/schema/master-registry.yaml is the master of every variable. Nothing below is edited by hand:

    * schema/infrastructure.schema.json         the full schema of infrastructure.yml (the validator reads this one)
    * schema/purposes/<purpose>.schema.json     the part of the schema one purpose reads (ztp, os_configuration, deployment, cicd_infra, monitoring, discovery)
    * templates/infrastructure.master.yml       every variable, with comments and allowed values
    * templates/scenarios/master.<key>-<value>.yml   the master for one scenario choice (scenario.identity: local_identity, ...)
    * templates/purposes/<purpose>.yml          only the variables one purpose reads: a strict subset of the master
    * docs/VARIABLES.md                         the variables reference (New-InfrastructureVariablesReference.ps1, run at the end)

    The curated worked examples (config/variables/examples/*.yml) are written by hand and tested against the schema and the rules.

    -Check regenerates everything in memory and exits 1 when a file on disk differs (the Pester tests run this).
    -Cut <purpose> -From <infrastructure.yml> -Out <file> cuts a real file down to what one purpose reads, for example the file
    azurelocal-ztp or Sonar validates against its purpose schema.

.PARAMETER RegistryPath
    Default: config/variables/schema/master-registry.yaml.

.PARAMETER Check
    Compare, do not write.

.PARAMETER Cut
    A purpose: ztp, os_configuration, deployment, cicd_infra, monitoring or discovery.

.PARAMETER From
    With -Cut: the infrastructure.yml to cut.

.PARAMETER Out
    With -Cut: where to write the cut file. Default: next to -From, named <name>.<purpose>.yml.

.EXAMPLE
    ./config/variables/scripts/New-InfrastructureArtifacts.ps1

.EXAMPLE
    ./config/variables/scripts/New-InfrastructureArtifacts.ps1 -Cut ztp -From ./infrastructure.yml -Out ./infrastructure.ztp.yml
#>
[CmdletBinding(DefaultParameterSetName = 'Generate')]
param(
    [string]$RegistryPath = (Join-Path $PSScriptRoot '../schema/master-registry.yaml'),
    [Parameter(ParameterSetName = 'Generate')][switch]$Check,
    [Parameter(ParameterSetName = 'Cut', Mandatory)][ValidateSet('ztp', 'os_configuration', 'deployment', 'cicd_infra', 'monitoring', 'discovery')][string]$Cut,
    [Parameter(ParameterSetName = 'Cut', Mandatory)][string]$From,
    [Parameter(ParameterSetName = 'Cut')][string]$Out
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'InfrastructureArtifacts.psm1') -Force

$variablesRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../../..')
$registry = Get-RegistryDocument -Path $RegistryPath
$purposes = 'ztp', 'os_configuration', 'deployment', 'cicd_infra', 'monitoring', 'discovery'

if ($PSCmdlet.ParameterSetName -eq 'Cut') {
    $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $From -Raw) -Ordered
    $result = Select-InfrastructurePurpose -Registry $registry -Document $doc -Purpose $Cut
    if (-not $Out) { $Out = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $From)) ("{0}.{1}.yml" -f [IO.Path]::GetFileNameWithoutExtension($From), ($Cut -replace '_', '-')) }
    $header = "# Cut from $(Split-Path -Leaf $From) for the purpose '$Cut' by New-InfrastructureArtifacts.ps1 -Cut. Validate against schema/purposes/$Cut.schema.json.`n"
    [IO.File]::WriteAllText($Out, $header + (ConvertTo-Yaml $result), [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $Out"
    return
}

function ConvertTo-JsonText($Object, [string]$Comment) {
    if ($Comment) { $Object = [ordered]@{ '$comment' = $Comment } + $Object }
    return ((ConvertTo-Json -InputObject $Object -Depth 100) -replace "`r`n", "`n") + "`n"
}

$generatedNote = 'GENERATED from config/variables/schema/master-registry.yaml by config/variables/scripts/New-InfrastructureArtifacts.ps1. Do not edit: change the registry and run the generator.'
$files = [ordered]@{}   # absolute path -> text

# schemas
$fullSchema = Get-InfrastructureSchemaFromRegistry -Registry $registry
$files[(Join-Path $variablesRoot 'schema/infrastructure.schema.json')] = ConvertTo-JsonText $fullSchema $generatedNote
foreach ($p in $purposes) {
    $files[(Join-Path $variablesRoot "schema/purposes/$($p -replace '_', '-').schema.json")] = ConvertTo-JsonText (Get-InfrastructureSchemaFromRegistry -Registry $registry -Purpose $p) $generatedNote
}

# templates
$masterText = Get-InfrastructureTemplateText -Registry $registry
$files[(Join-Path $variablesRoot 'templates/infrastructure.master.yml')] = $masterText
foreach ($p in $purposes) {
    $files[(Join-Path $variablesRoot "templates/purposes/$($p -replace '_', '-').yml")] = Get-InfrastructureTemplateText -Registry $registry -Purpose $p
}
$scenario = $registry['scenario']['properties']
foreach ($key in $scenario.Keys) {
    $entry = $scenario[$key]
    if (-not $entry.Contains('enum')) { continue }
    foreach ($value in $entry['enum']) {
        $text = Get-InfrastructureTemplateText -Registry $registry -Scenario @{ $key = [string]$value } -Title "infrastructure.yml for scenario.$key = $value"
        # a choice that changes nothing in the file (cloud, deploy_method, environment_class) has no scenario file
        $sameAsMaster = ((@($text -split "`n") | Select-Object -Skip 4) -join "`n") -ceq ((@($masterText -split "`n") | Select-Object -Skip 4) -join "`n")
        if ($sameAsMaster) { continue }
        $files[(Join-Path $variablesRoot "templates/scenarios/master.$($key -replace '_', '-')-$($value -replace '_', '-').yml")] = $text
    }
}

$stale = @()
foreach ($path in $files.Keys) {
    $text = $files[$path]
    $current = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path).Replace("`r`n", "`n") } else { $null }
    if ($Check) {
        if ($current -ne $text) { $stale += $path }
        continue
    }
    if ($current -eq $text) { continue }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $path"
}

$reference = Join-Path $repoRoot 'scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1'
if ($Check) {
    $global:LASTEXITCODE = 0
    & $reference -Check *>$null
    if ($LASTEXITCODE -ne 0) { $stale += (Join-Path $variablesRoot 'docs/VARIABLES.md') }
    if ($stale.Count) {
        $stale | ForEach-Object { Write-Error "Out of date: $_" -ErrorAction Continue }
        Write-Error 'Run ./config/variables/scripts/New-InfrastructureArtifacts.ps1 and commit the result.'
        exit 1
    }
    Write-Host "All $($files.Count) generated files are current."
}
else {
    & $reference
}
