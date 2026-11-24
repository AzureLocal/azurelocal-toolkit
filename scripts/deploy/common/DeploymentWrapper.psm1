#Requires -Version 7.0
<#
.SYNOPSIS
    Shared by the thin wrapper scripts of scripts/deploy: runs the real script of a guide step and hands back its exit code.

.DESCRIPTION
    A wrapper keeps the file name that a task folder (and a guide page) names, and does its job by running the schema 5 script that
    does the work (the OS configuration, the pre-cluster verification, the post-deployment verification). The wrapper adds no logic of
    its own: it checks that the infrastructure file is there, builds the argument list and runs the script.

    Invoke-DeploymentWrapperStep runs one script in the same process (so -WhatIf and the common parameters behave) and returns its exit
    code. Under -WhatIf it only prints the command line and returns 0.

    Exit codes of the wrappers follow the scripts they run: 0 passed or planned, 1 a check failed, 2 bad input (also a missing file).
    A PARTIAL run of the pre-cluster verification (a -Category run) ends with 3 when nothing blocks; a wrapper reports that as 0, because
    3 is the exit code of a placeholder (NOT IMPLEMENTED) in this tree and a wrapper is not one.

.NOTES
    Reads nothing from infrastructure.yml itself. Never contacts Azure, a node or a BMC by itself.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DeploymentWrapperTarget {
    <#
    .SYNOPSIS
        The full path of a script of scripts/deploy, from the repository root found above the wrapper.
    .PARAMETER From
        The folder of the wrapper ($PSScriptRoot).
    .PARAMETER Relative
        The path of the script, relative to scripts/deploy, with forward slashes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$Relative
    )
    $current = Get-Item -LiteralPath $From
    while ($null -ne $current) {
        $candidate = [System.IO.Path]::Combine($current.FullName, 'scripts', 'deploy', $Relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $current = $current.Parent
    }
    throw "Unable to find scripts/deploy/$Relative from '$From'."
}

function Invoke-DeploymentWrapperStep {
    <#
    .SYNOPSIS
        Runs a script with a set of named arguments and returns its exit code (0 for -WhatIf).
    .PARAMETER ScriptPath
        The script to run.
    .PARAMETER Argument
        The named arguments (a hashtable). A switch is passed as $true.
    .PARAMETER Label
        A short name of the step for the progress line.
    .PARAMETER PartialIsPass
        Report exit code 3 (a partial pre-cluster verification with no blocking result) as 0.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$Argument = @{},
        [Parameter(Mandatory)][string]$Label,
        [switch]$PartialIsPass
    )
    $shown = ($Argument.GetEnumerator() | Sort-Object Name | ForEach-Object { if ($_.Value -is [bool] -or $_.Value -is [switch]) { "-$($_.Name)" } elseif ($_.Value -is [array]) { "-$($_.Name) $($_.Value -join ',')" } else { "-$($_.Name) $($_.Value)" } }) -join ' '
    $line = "{0} {1}" -f (Split-Path -Leaf $ScriptPath), $shown
    if (-not $PSCmdlet.ShouldProcess($line, "Run $Label")) {
        Write-Information -InformationAction Continue -MessageData "WhatIf: would run $line"
        return 0
    }
    Write-Information -InformationAction Continue -MessageData "${Label}: $line"
    # The script runs with the error preference of its own file, not the Stop of this module; its output goes to the host, so only the exit code is returned.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    & $ScriptPath @Argument | Out-Host
    $code = [int]$global:LASTEXITCODE
    if ($PartialIsPass -and $code -eq 3) {
        Write-Information -InformationAction Continue -MessageData "${Label}: partial run, nothing blocks (the script ended with 3); reported as 0."
        return 0
    }
    return $code
}

Export-ModuleMember -Function Get-DeploymentWrapperTarget, Invoke-DeploymentWrapperStep
