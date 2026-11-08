#Requires -Version 7.0
<#
.SYNOPSIS
    Task 03. Sets branch protection, approvals, merge rules and security on the project. Azure CLI variant.

.DESCRIPTION
    The implementation drives the Azure CLI (az) and the platform's own CLI or REST API, so this variant runs the same
    code as Invoke-CicdProjectConfiguration-Orchestrated.ps1 and passes its parameters on. Needs az on PATH and az login.

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
$orchestrated = Join-Path (Split-Path -Path $PSScriptRoot -Parent) (Join-Path 'powershell' 'Invoke-CicdProjectConfiguration-Orchestrated.ps1')
& $orchestrated @PSBoundParameters
