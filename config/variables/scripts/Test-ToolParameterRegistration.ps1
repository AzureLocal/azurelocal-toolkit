#Requires -Version 7.0
<#
.SYNOPSIS
    Fails when a script has a parameter that the master registry does not know (tools.<tool>.parameters).

.DESCRIPTION
    The registry is master. Every parameter of a script that belongs to a tool is a registry variable under
    tools.<tool>.parameters.<group>.<name>, where the group is the script (its "area" text names the file). This script reads
    the param() block of each script under -Root, finds the registry groups whose area names that file, and lists the
    parameters that are in no such group. A script with no group at all is reported as "not registered".

    Use it for the toolkit's own scripts (tests/variables/ToolRegistry.Tests.ps1 does) and for a tool that lives in another
    repository (azurelocal-ztp, azurelocal-sonar): point -Root at its checkout.

.PARAMETER Tool
    os_configuration, ztp, sonar, arm_deployment, cicd_infra or discovery.

.PARAMETER Root
    The folder to scan for *.ps1 files.

.PARAMETER RegistryPath
    Default: config/variables/schema/master-registry.yaml.

.PARAMETER Registry
    The result of Get-RegistryVariable, to avoid reading the registry again.

.PARAMETER ReportUnregisteredScripts
    Also report a script with parameters that no registry group names. Without it, only the scripts the registry knows are checked.

.OUTPUTS
    One object per problem: Script, Parameter, Problem. Nothing when everything is registered.

.EXAMPLE
    ./config/variables/scripts/Test-ToolParameterRegistration.ps1 -Tool ztp -Root D:\git\azurelocal\azurelocal-ztp\scripts
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('os_configuration', 'ztp', 'sonar', 'arm_deployment', 'cicd_infra', 'discovery')][string]$Tool,
    [Parameter(Mandatory)][string]$Root,
    [string]$RegistryPath = (Join-Path $PSScriptRoot '../schema/master-registry.yaml'),
    [object[]]$Registry,
    [switch]$ReportUnregisteredScripts
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'VariableRegistry.psm1') -Force
if (-not $Registry) { $Registry = @(Get-RegistryVariable -Path $RegistryPath) }

# groups of this tool: container node under tools.<tool>.parameters with an "area"
$groups = @($Registry | Where-Object { $_.Path -match "^tools\.$Tool\.parameters\.[^.]+$" })
$common = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm', 'ProgressAction'

foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.ps1' -File) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errs)
    $params = @()
    if ($ast.ParamBlock) { $params = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
    if (-not $params.Count) { continue }
    $mine = @($groups | Where-Object { $_.Node.Contains('area') -and ([string]$_.Node['area']).IndexOf($file.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if (-not $mine.Count) { if ($ReportUnregisteredScripts) { [pscustomobject]@{ Script = $file.FullName; Parameter = ''; Problem = "not registered: no tools.$Tool.parameters group names $($file.Name)" } }; continue }
    $known = foreach ($g in $mine) {
        foreach ($child in $g.Node['properties'].Values) { if ($child -is [System.Collections.IDictionary] -and $child.Contains('name')) { [string]$child['name'] } }
    }
    foreach ($p in $params) {
        if ($common -contains $p) { continue }
        if ($known -notcontains $p) { [pscustomobject]@{ Script = $file.FullName; Parameter = $p; Problem = "not registered in tools.$Tool.parameters" } }
    }
}
