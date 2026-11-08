#Requires -Version 7.0
<#
.SYNOPSIS
    Starts Invoke-AzureLocalOsConfiguration.ps1 for the Ansible role, with the node credential taken from the environment.

.DESCRIPTION
    A thin launcher and nothing else: it does not decide anything the wrapper decides (ZTP versus ISO, transport, steps, exit codes).
    It exists because a PSCredential cannot be given on a command line, and the role must not put the node password on one.

      1. Reads the wrapper's parameters from a JSON file (no secrets in it; the role writes it) and checks every name against the
         wrapper's own parameter list. An unknown name, or a Credential entry, is bad input (exit 2).
      2. Builds the -Credential from the environment variables AZL_NODE_ADMIN_USER and AZL_NODE_ADMIN_PASSWORD when the password is
         set, and removes the password from the process environment straight away. Neither set: no -Credential, the wrapper reads
         identity.local_admin from the Key Vault as always.
      3. Optionally signs in to Azure with the managed identity (-AzureAuth ManagedIdentity).
      4. Runs the wrapper with those parameters and exits with the wrapper's exit code, unchanged:
         0 every node converged (Plan: nothing failed or blocked), 1 a node failed, is blocked or did not converge,
         2 bad input or nothing reachable.

    Its own messages never contain the password. They are written to <ArgumentsFile>.error.txt so the Ansible task, which runs
    with no_log, can still tell the operator why a run did not start.
.PARAMETER ArgumentsFile
    JSON object: wrapper parameter name -> value (arrays, booleans, strings, objects for -Settings and -NodeAddress).
.PARAMETER WrapperPath
    Path to Invoke-AzureLocalOsConfiguration.ps1.
.PARAMETER AzureAuth
    None (default; the runner is already signed in) or ManagedIdentity.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArgumentsFile,
    [Parameter(Mandatory)][string]$WrapperPath,
    [ValidateSet('None', 'ManagedIdentity')][string]$AzureAuth = 'None'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errorFile = "$ArgumentsFile.error.txt"
Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue

function Write-RunFailure {
    param([Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)][int]$ExitCode)
    $text = if ($ExitCode -eq 2) { "BAD INPUT: $Message" } else { "FAILED: $Message" }
    Set-Content -LiteralPath $errorFile -Value $text -Encoding utf8NoBOM
    [Console]::Error.WriteLine($text)
    exit $ExitCode
}

# The password leaves the environment before anything else runs, so no child process inherits it.
$nodeUser = [Environment]::GetEnvironmentVariable('AZL_NODE_ADMIN_USER')
$nodePassword = [Environment]::GetEnvironmentVariable('AZL_NODE_ADMIN_PASSWORD')
[Environment]::SetEnvironmentVariable('AZL_NODE_ADMIN_PASSWORD', $null)

if (-not (Test-Path -LiteralPath $WrapperPath -PathType Leaf)) { Write-RunFailure "The wrapper script was not found: $WrapperPath" 2 }
if (-not (Test-Path -LiteralPath $ArgumentsFile -PathType Leaf)) { Write-RunFailure "The arguments file was not found: $ArgumentsFile" 2 }

try { $arguments = Get-Content -LiteralPath $ArgumentsFile -Raw | ConvertFrom-Json -AsHashtable }
catch { Write-RunFailure "The arguments file is not valid JSON: $($_.Exception.Message)" 2 }
if ($arguments -isnot [hashtable]) { Write-RunFailure 'The arguments file must hold one JSON object.' 2 }

$known = @((Get-Command -Name $WrapperPath).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.Cmdlet]::CommonParameters })
foreach ($key in $arguments.Keys) {
    if ($key -eq 'Credential') { Write-RunFailure 'Credential must not be in the arguments file; it comes from the environment.' 2 }
    if ($key -notin $known) { Write-RunFailure "The wrapper has no parameter '$key'. Parameters: $($known -join ', ')." 2 }
}

if ($nodePassword) {
    if (-not $nodeUser) { Write-RunFailure 'AZL_NODE_ADMIN_PASSWORD is set but AZL_NODE_ADMIN_USER is not.' 2 }
    $secure = [System.Security.SecureString]::new()
    foreach ($char in $nodePassword.ToCharArray()) { $secure.AppendChar($char) }
    $secure.MakeReadOnly()
    $arguments['Credential'] = [pscredential]::new($nodeUser, $secure)
}
$nodePassword = $null

if ($AzureAuth -eq 'ManagedIdentity') {
    try {
        Import-Module Az.Accounts -ErrorAction Stop
        $null = Connect-AzAccount -Identity -ErrorAction Stop
    }
    catch { Write-RunFailure "Azure sign-in with the managed identity failed: $($_.Exception.Message)" 2 }
}

$LASTEXITCODE = 0
try { & $WrapperPath @arguments }
catch { Write-RunFailure "The wrapper stopped with an error: $($_.Exception.Message)" 1 }
exit $LASTEXITCODE
