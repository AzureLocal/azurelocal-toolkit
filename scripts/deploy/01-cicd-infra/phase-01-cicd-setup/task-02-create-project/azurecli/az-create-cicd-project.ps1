#Requires -Version 7.0
<#
.SYNOPSIS
    Task 02. Creates the deployment repository or project from the Azure Local template. Azure CLI variant.

.DESCRIPTION
    The implementation drives the Azure CLI (az) and the platform's own CLI or REST API, so this variant runs the same
    code as Invoke-CicdProject-Orchestrated.ps1 and passes its parameters on. Needs az on PATH and az login.

.PARAMETER ConfigPath
    The infrastructure file (infrastructure.yml, schema 5.5).

.PARAMETER LogPath
    The log file.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = '',
    [string]$LogPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { throw "Azure CLI 'az' was not found in PATH." }
$orchestrated = Join-Path (Split-Path -Path $PSScriptRoot -Parent) (Join-Path 'powershell' 'Invoke-CicdProject-Orchestrated.ps1')
& $orchestrated @PSBoundParameters
