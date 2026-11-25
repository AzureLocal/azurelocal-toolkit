<#
.SYNOPSIS
    Deploys the Windows Admin Center (WAC) gateway on its own management server: checks the server, installs the gateway in Administration Mode when
    it is not there, starts the service and checks that the gateway answers on its HTTPS port. Idempotent.

.DESCRIPTION
    Operational foundations, phase 02 (monitoring and observability), Task 05 (deploy Windows Admin Center). Microsoft Learn (Install Windows Admin
    Center in Administration Mode or Virtualization Mode): the installer is downloaded from https://aka.ms/WACdownload and run on the server with
    "WindowsAdminCenter.exe /VERYSILENT /Mode=Administration", and the options /HTTPSPortNumber and /CertificateThumbprint set the port and the
    TLS certificate; without a thumbprint the installer generates a self-signed certificate that expires after 60 days. The service is called
    WindowsAdminCenter (ServerManagementGateway before the 2025 installer).

    The WAC server is the landing_zone.virtual_machines[] entry of the file with role windows_admin_center (a dedicated management server, not
    the jumpbox). The script reaches it over PowerShell remoting through scripts/common/remoting/AzlClusterConnection.psm1, as -Credential or as the
    local administrator of that entry (admin_username, and the secret of admin_password read through the toolkit's secret resolver). It never asks
    for a password.

    Steps:
      1. Checks the server (read only): Windows Server 2019 or later (build 17763), and warns below 4 processor cores or 8 GB of memory (the guide
         page: 4+ vCPU, 8 GB+ recommended). A thumbprint of operations.windows_admin_center.certificate_thumbprint must be in LocalMachine\My.
      2. Installs the gateway (Administration Mode) when no WAC service exists: from operations.windows_admin_center.installer_path on the server,
         or downloaded there from the Microsoft address. Then starts the service and waits for the HTTPS port. A gateway that is already installed
         is never reinstalled, upgraded or moved to another port: the script reports it (and fails when the port is not listening).
      3. Checks that the port answers on the server.

    Not automated, and reported as such (rows of Kind Manual): the cluster connection (Import-WACConnection needs the access key from the Advanced tab of
    the gateway settings and a signed-in user), the extensions of the guide page (Cluster Manager, Azure Hybrid Center, Azure Monitor, Virtual Machines,
    Storage, Networking) and the registration with Azure and Azure Monitor (an interactive Microsoft Entra sign-in with consent).
    Administration Mode manages about 10 nodes and one concurrent connection per gateway (Learn).

    With operations.windows_admin_center.enabled false or absent the script does nothing and exits 0. -WhatIf reads the server and changes nothing.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        operations.windows_admin_center.enabled, port, certificate_thumbprint, installer_path
        landing_zone.virtual_machines[] (role windows_admin_center: name, hostname, private_ip, admin_username, admin_password)
        identity.active_directory.domain_fqdn, cluster.name

    Exit codes: 0 the gateway is in place and answers (installed now, already there, planned under -WhatIf, or not asked for); 1 a remote call or
    a check failed (server unreachable, too old, certificate missing, install failed, port not answering); 2 a value of the file is missing or not
    usable. On exit code 2 nothing is sent to the server.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.PARAMETER Credential
    Optional. The account for the remoting session to the WAC server. Default: the local administrator of the landing_zone.virtual_machines[] entry.

.EXAMPLE
    ./Deploy-WindowsAdminCenter.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./Deploy-WindowsAdminCenter.ps1 -InfrastructureFile ./infrastructure.yml
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath,
    [pscredential]$Credential
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'remoting', 'AzlClusterConnection.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

# Fixed by Microsoft (Learn, Install Windows Admin Center): the download address, the service names and the installer options.
$DownloadAddress = 'https://aka.ms/WACdownload'
$ServiceNames = @('WindowsAdminCenter', 'ServerManagementGateway')
# Windows Server 2019 is build 17763 (the guide page: Windows Server 2019 or later).
$MinimumBuild = 17763
$MinimumCores = 4
$MinimumMemoryGiB = 8
$ListenWaitSeconds = 120

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Get-Text([string]$Path) { $v = Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$enabled = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.windows_admin_center.enabled'
if ($null -ne $enabled -and $enabled -isnot [bool]) { Exit-InputProblem "operations.windows_admin_center.enabled must be true or false; found '$enabled'." }
if ($enabled -ne $true) { Write-Line 'operations.windows_admin_center.enabled is not true: nothing to do.'; exit 0 }

$portValue = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.windows_admin_center.port'
$port = 443
if ($null -ne $portValue) {
    $parsedPort = 0
    if (-not [int]::TryParse([string]$portValue, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) { Exit-InputProblem "operations.windows_admin_center.port must be a number from 1 to 65535; found '$portValue'." }
    $port = $parsedPort
}
$thumbprint = Get-Text 'operations.windows_admin_center.certificate_thumbprint'
if ($thumbprint -and $thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { Exit-InputProblem 'operations.windows_admin_center.certificate_thumbprint must be 40 hexadecimal characters.' }
$installerPath = Get-Text 'operations.windows_admin_center.installer_path'
if ($installerPath -and $installerPath -match '["`$;&|<>]') { Exit-InputProblem 'operations.windows_admin_center.installer_path holds a character that is not allowed in a path.' }

$servers = @(@(Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.virtual_machines') | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['role'] -eq 'windows_admin_center' })
if ($servers.Count -eq 0) { Exit-InputProblem 'landing_zone.virtual_machines[] has no entry with role windows_admin_center: the gateway has no server to go on.' }
if ($servers.Count -gt 1) { Exit-InputProblem 'landing_zone.virtual_machines[] has more than one entry with role windows_admin_center. The gateway goes on one server.' }
$server = $servers[0]
$hostName = if ($server['hostname']) { ([string]$server['hostname']).Trim() } else { ([string]$server['name']).Trim() }
if (-not $hostName) { Exit-InputProblem 'The windows_admin_center entry of landing_zone.virtual_machines[] has no hostname and no name.' }
$domain = Get-Text 'identity.active_directory.domain_fqdn'
$fqdn = if ($domain) { "$hostName.$domain" } else { $hostName }
$privateIp = if ($server['private_ip']) { ([string]$server['private_ip']).Trim() } else { '' }

# The account: -Credential, else the local administrator of the entry (the secret is read through the resolver, never logged).
$account = $Credential
$accountSource = if ($Credential) { 'Parameter' } else { 'CurrentAccount' }
if (-not $account -and $server['admin_username'] -and $server['admin_password']) {
    try {
        $secret = Get-AzlSecretValue -Reference ([string]$server['admin_password']) -Infrastructure $infra
        $account = [pscredential]::new(([string]$server['admin_username']).Trim(), $secret)
        $accountSource = 'AdminUser'
    }
    catch { Exit-InputProblem "The secret of admin_password of the windows_admin_center entry could not be read: $($_.Exception.Message)" }
}
# An address needs an explicit account (WinRM takes the current account only for a name), so without one the server is reached by its name.
$address = if ($account -and $privateIp) { $privateIp } else { $fqdn }

# ---- the remote blocks. They run in Windows PowerShell 5.1 on the server: no PowerShell 7 syntax here.
$InspectBlock = {
    # azl:inspect
    param([string[]]$ServiceNames, [int]$Port, [string]$Thumbprint)
    $svc = $null
    foreach ($n in $ServiceNames) { $svc = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($svc) { break } }
    $version = ''
    if ($svc) {
        $wmi = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $svc.Name) -ErrorAction SilentlyContinue
        if ($wmi -and $wmi.PathName) {
            $exe = ([string]$wmi.PathName).Trim().Trim('"')
            if ($exe -match '^"?([^"]+?\.exe)') { $exe = $Matches[1] }
            if (Test-Path -LiteralPath $exe) { $version = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
        }
    }
    $listening = $false
    try { $listening = [bool](@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).Count) } catch { $listening = $false }
    $cert = $false
    if ($Thumbprint) { $cert = [bool](Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -ieq $Thumbprint }) }
    [pscustomobject]@{
        ServiceName = $(if ($svc) { [string]$svc.Name } else { '' })
        Status      = $(if ($svc) { [string]$svc.Status } else { '' })
        Version     = $version
        Listening   = $listening
        Build       = [int][Environment]::OSVersion.Version.Build
        Cores       = [int]((Get-CimInstance -ClassName Win32_ComputerSystem).NumberOfLogicalProcessors)
        MemoryGiB   = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        CertPresent = $cert
        InstallerOk = $false
    }
}
$InstallBlock = {
    # azl:install
    param([string[]]$ServiceNames, [int]$Port, [string]$Thumbprint, [string]$InstallerPath, [string]$DownloadAddress, [int]$WaitSeconds)
    $downloaded = $null
    try {
        $installer = $InstallerPath
        if ($installer) {
            if (-not (Test-Path -LiteralPath $installer)) { throw "The installer $installer is not on the server." }
        }
        else {
            $downloaded = Join-Path ([IO.Path]::GetTempPath()) ('WindowsAdminCenter-{0}.exe' -f [guid]::NewGuid().ToString('N'))
            Start-BitsTransfer -Source $DownloadAddress -Destination $downloaded -ErrorAction Stop
            $installer = $downloaded
        }
        $arguments = @('/VERYSILENT', '/Mode=Administration', "/HTTPSPortNumber=$Port")
        if ($Thumbprint) { $arguments += "/CertificateThumbprint=$Thumbprint" }
        $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "The installer ended with exit code $($process.ExitCode)." }
        $svc = $null
        foreach ($n in $ServiceNames) { $svc = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($svc) { break } }
        if (-not $svc) { throw 'The installer ended without error, but the Windows Admin Center service does not exist.' }
        if ($svc.Status -ne 'Running') { Start-Service -Name $svc.Name }
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        $up = $false
        while (-not $up -and (Get-Date) -lt $deadline) {
            $up = [bool](@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).Count)
            if (-not $up) { Start-Sleep -Seconds 5 }
        }
        [pscustomobject]@{ ServiceName = [string]$svc.Name; Listening = $up }
    }
    finally { if ($downloaded -and (Test-Path -LiteralPath $downloaded)) { Remove-Item -LiteralPath $downloaded -Force -ErrorAction SilentlyContinue } }
}

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Kind, [string]$Name, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Kind = $Kind; Name = $Name; Action = $Action; Detail = $Detail })
    $tag = switch -Wildcard ($Action) { 'Failed' { '[failed]  ' } 'Already*' { '[exists]  ' } 'Would*' { '[plan]    ' } 'NotAutomated' { '[manual]  ' } 'Warning' { '[warning] ' } default { '[created] ' } }
    Write-Line ("{0}{1} {2}{3}" -f $tag, $Kind, $Name, $(if ($Detail) { " ($Detail)" } else { '' }))
}

try {
    $connection = Resolve-AzlClusterConnection -Infrastructure $infra -ComputerName $address -Credential $account -RemoteCommand { param([hashtable]$Call) Invoke-Command @Call }
    Write-Line (Format-AzlClusterConnection -Connection $connection)

    $state = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $InspectBlock -ArgumentList @(, $ServiceNames), $port, $thumbprint
    if ($state.Build -lt $MinimumBuild) { throw "The server is Windows build $($state.Build); Windows Admin Center needs Windows Server 2019 (build $MinimumBuild) or later." }
    if ($state.Cores -lt $MinimumCores -or $state.MemoryGiB -lt $MinimumMemoryGiB) { Add-Row 'Server' $fqdn 'Warning' "$($state.Cores) cores and $($state.MemoryGiB) GB of memory; the guide page recommends $MinimumCores or more cores and $MinimumMemoryGiB GB or more" }
    if ($thumbprint -and -not $state.CertPresent) { throw "The certificate $thumbprint (operations.windows_admin_center.certificate_thumbprint) is not in LocalMachine\My on $fqdn." }

    if ($state.ServiceName) {
        if ($state.Status -ne 'Running') { throw "The Windows Admin Center service $($state.ServiceName) is installed but is $($state.Status). The script does not change an installed gateway: start it, or remove it and run the script again." }
        if (-not $state.Listening) { throw "The Windows Admin Center service $($state.ServiceName) is running, but nothing listens on port $port. The gateway uses another port: reinstall it, or set operations.windows_admin_center.port to the port it uses. The script does not change an installed gateway." }
        Add-Row 'Gateway' $fqdn 'AlreadyInstalled' "service $($state.ServiceName) running, version $($state.Version), port $port"
    }
    elseif ($PSCmdlet.ShouldProcess($fqdn, "Install Windows Admin Center (Administration Mode, port $port, $(if ($thumbprint) { 'certificate ' + $thumbprint } else { 'self-signed certificate' }))")) {
        $result = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $InstallBlock -ArgumentList @(, $ServiceNames), $port, $thumbprint, $installerPath, $DownloadAddress, $ListenWaitSeconds
        if (-not $result.Listening) { throw "The gateway was installed (service $($result.ServiceName)), but nothing listens on port $port after $ListenWaitSeconds seconds." }
        Add-Row 'Gateway' $fqdn 'Installed' "service $($result.ServiceName), port $port, $(if ($thumbprint) { 'certificate ' + $thumbprint } else { 'self-signed certificate (60 days, test use only)' })"
    }
    else { Add-Row 'Gateway' $fqdn 'WouldInstall' "Administration Mode, port $port, $(if ($installerPath) { "installer $installerPath" } else { 'downloaded on the server' })" }

    Add-Row 'Manual' 'Cluster connection' 'NotAutomated' "add the cluster by FQDN in Windows Admin Center (Add, Server clusters); the connection list can be imported with Import-WACConnection only with the access key of the gateway"
    Add-Row 'Manual' 'Extensions' 'NotAutomated' 'install or update Cluster Manager, Azure Hybrid Center, Azure Monitor, Virtual Machines, Storage and Networking in Settings, Extensions'
    Add-Row 'Manual' 'Azure registration' 'NotAutomated' 'Settings, Azure, Register: an interactive Microsoft Entra sign-in with consent; then enable Azure Monitor on the cluster'
}
catch { Add-Row 'Gateway' $fqdn 'Failed' $_.Exception.Message }

$rows
if (@($rows | Where-Object { $_.Action -eq 'Failed' })) { exit 1 }
exit 0
