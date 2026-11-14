#Requires -Version 7.0
<#
.SYNOPSIS
    Enables or disables the VNC server of Dell iDRACs through Redfish.

.DESCRIPTION
    Sets VNCServer.1.Enable, Port and Timeout (and optionally the VNC password) on the iDRAC. The addresses come from
    nodes[].bmc.ip_address of the infrastructure file. -TargetNode limits the run to some nodes (one name is one iDRAC).

    The login is -Credential, then the secret references in the file (hardware.bmc, or the node's own bmc block). Nothing is
    asked: with neither, the script stops with exit code 2. The VNC password is a SecureString, or a secret reference with
    -VncSecretReference; it is never written to a log. The VNC settings are parameters: the infrastructure schema has no VNC keys.

    Exit codes: 0 done (or planned under -WhatIf); 1 an iDRAC call failed; 2 the file or the login is missing or not usable
    (nothing was sent to any iDRAC).

    This is the only tool of the discovery set that writes to an iDRAC. Use -WhatIf to see what it would do.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. Only nodes[].name, nodes[].bmc, hardware.bmc and the secret references are read.

.PARAMETER TargetNode
    Node names to limit the run to.

.PARAMETER Credential
    The iDRAC login.

.PARAMETER State
    Enabled (default) or Disabled.

.PARAMETER Port
    The VNC port. Default 5901.

.PARAMETER TimeoutSeconds
    VNC session timeout, 60 to 10800 seconds. Default 1800.

.PARAMETER VncPassword
    The VNC password (4 to 8 characters), for third-party VNC clients.

.PARAMETER VncSecretReference
    A secret reference (keyvault://, env://, file:// or command://) holding the VNC password. Read with the infrastructure file given in -InfrastructureFile.

.PARAMETER VerifyCertificate
    Check the iDRAC TLS certificate. Default: not checked (self-signed).

.EXAMPLE
    .\Enable-IdracVnc.ps1 -InfrastructureFile .\infrastructure.yml -WhatIf

.EXAMPLE
    .\Enable-IdracVnc.ps1 -InfrastructureFile .\infrastructure.yml -TargetNode node-1 -Port 5901 -TimeoutSeconds 3600

.NOTES
    Requires PowerShell 7 and an iDRAC 9 with Redfish.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$TargetNode = @(),
    [System.Management.Automation.PSCredential]$Credential,
    [ValidateSet('Enabled', 'Disabled')][string]$State = 'Enabled',
    [ValidateRange(1, 65535)][int]$Port = 5901,
    [ValidateRange(60, 10800)][int]$TimeoutSeconds = 1800,
    [SecureString]$VncPassword,
    [string]$VncSecretReference,
    [switch]$VerifyCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'redfish', 'AzlRedfishCore.psm1'))
Import-Module ([System.IO.Path]::Combine($PSScriptRoot, 'AzlDellRedfish.psm1'))

Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))
$targets = [System.Collections.Generic.List[object]]::new()
try { $infrastructure = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Error "Cannot read the infrastructure file: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
foreach ($n in @($infrastructure['nodes'])) {
    if ($n -isnot [System.Collections.IDictionary]) { continue }
    $name = [string]$n['name']
    if ($TargetNode.Count -gt 0 -and $name -notin $TargetNode) { continue }
    $bmc = $n['bmc']
    if ($bmc -is [System.Collections.IDictionary] -and $bmc['ip_address']) { $targets.Add([pscustomobject]@{ Name = $name; Address = [string]$bmc['ip_address']; Node = $n }) }
    else { Write-Warning "Node '$name' has no bmc.ip_address: skipped." }
}
if ($targets.Count -eq 0) { Write-Error 'No matching node with a bmc.ip_address. Check nodes[].bmc.ip_address and -TargetNode.' -ErrorAction Continue; exit 2 }

try {
    if (-not $VncPassword -and $VncSecretReference) { $VncPassword = Get-AzlBmcKeyVaultSecret -Reference $VncSecretReference -Infrastructure $infrastructure }
    $cred = Resolve-AzlBmcCredential -Credential $Credential -Infrastructure $infrastructure -Node ($targets[0].Node)
}
catch { Write-Error "$($_.Exception.Message)" -ErrorAction Continue; exit 2 }

$results = foreach ($t in $targets) {
    try {
        $r = Set-AzlDellIdracVnc -BmcAddress $t.Address -Credential $cred -State $State -Port $Port -TimeoutSeconds $TimeoutSeconds -Password $VncPassword -VerifyCertificate:$VerifyCertificate -WhatIf:$WhatIfPreference
        [pscustomobject]@{ Node = $t.Name; Status = $r.Status; Before = $r.Before; After = $r.After; PasswordSet = $r.PasswordSet; Note = $r.Note }
    }
    catch {
        [pscustomobject]@{ Node = $t.Name; Status = 'FAIL'; Before = ''; After = ''; PasswordSet = $false; Note = $_.Exception.Message }
    }
}
$results
$failed = @($results | Where-Object Status -eq 'FAIL')
if ($failed.Count -gt 0) { Write-Error "$($failed.Count) of $(@($results).Count) iDRAC(s) failed: $(($failed | ForEach-Object { $_.Node }) -join ', ')." -ErrorAction Continue; exit 1 }
Write-Information "VNC $State on $(@($results).Count) iDRAC(s)."
