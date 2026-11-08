#Requires -Version 7.0
<#
.SYNOPSIS
    Enables or disables the VNC server of Dell iDRACs through Redfish.

.DESCRIPTION
    Sets VNCServer.1.Enable, Port and Timeout (and optionally the VNC password) on the iDRAC. Two ways to pick the iDRACs:

    Config-driven (-ConfigPath): the addresses come from nodes[].bmc.ip_address of infrastructure.yml, the login from
    the Key Vault references in hardware.bmc (or the node's own bmc block). -TargetNode limits it to some nodes.

    Single address (-BmcAddress): one iDRAC, login from -Credential or a prompt.

    The login is -Credential, then Key Vault (keyvault://vault/secret references), then a prompt. The VNC password is a
    SecureString, or a Key Vault reference with -VncSecretReference; it is never written to a log. The VNC settings are
    parameters: the infrastructure schema has no VNC keys.

    This is the only tool of the discovery set that writes to an iDRAC. Use -WhatIf to see what it would do.

.PARAMETER ConfigPath
    infrastructure.yml.

.PARAMETER BmcAddress
    One iDRAC address (single-address mode).

.PARAMETER TargetNode
    Node names to limit the run to, in config-driven mode.

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
    A keyvault://vault/secret reference holding the VNC password.

.PARAMETER VerifyCertificate
    Check the iDRAC TLS certificate. Default: not checked (self-signed).

.EXAMPLE
    .\Enable-IdracVnc.ps1 -ConfigPath .\infrastructure.yml -WhatIf

.EXAMPLE
    .\Enable-IdracVnc.ps1 -BmcAddress '<idrac-address>' -Port 5901 -TimeoutSeconds 3600

.NOTES
    Requires PowerShell 7 and an iDRAC 9 with Redfish.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$ConfigPath,
    [string]$BmcAddress,
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

$infrastructure = $null
$targets = [System.Collections.Generic.List[object]]::new()
if ($ConfigPath) {
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))
    $infrastructure = Import-AzlInfrastructure -Path $ConfigPath -SkipValidation
    foreach ($n in @($infrastructure['nodes'])) {
        if ($n -isnot [System.Collections.IDictionary]) { continue }
        $name = [string]$n['name']
        if ($TargetNode.Count -gt 0 -and $name -notin $TargetNode) { continue }
        $bmc = $n['bmc']
        if ($bmc -is [System.Collections.IDictionary] -and $bmc['ip_address']) { $targets.Add([pscustomobject]@{ Name = $name; Address = [string]$bmc['ip_address']; Node = $n }) }
        else { Write-Warning "Node '$name' has no bmc.ip_address: skipped." }
    }
}
elseif ($BmcAddress) { $targets.Add([pscustomobject]@{ Name = $BmcAddress; Address = $BmcAddress; Node = $null }) }
else { throw 'Give -ConfigPath (config-driven) or -BmcAddress (one iDRAC).' }
if ($targets.Count -eq 0) { throw 'No matching node with a bmc.ip_address. Check -TargetNode.' }

if (-not $VncPassword -and $VncSecretReference) { $VncPassword = Get-AzlBmcKeyVaultSecret -Reference $VncSecretReference }
$cred = Resolve-AzlBmcCredential -Credential $Credential -Infrastructure $infrastructure -Node ($targets[0].Node)

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
if ($failed.Count -gt 0) { throw "$($failed.Count) of $(@($results).Count) iDRAC(s) failed: $(($failed | ForEach-Object { $_.Node }) -join ', ')." }
Write-Information "VNC $State on $(@($results).Count) iDRAC(s)."
