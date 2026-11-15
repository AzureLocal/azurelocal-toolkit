#Requires -Version 7.0
<#
.SYNOPSIS
    Installs the operator tools of a Windows management machine: desktop tools with winget, the Az PowerShell module, and the
    Remote Server Administration Tools features.

.DESCRIPTION
    Installs, in this order:
      winget (machine scope)   Visual Studio Code, PowerShell, Git, Azure CLI, GitHub Desktop, PuTTY, kubectl, WinSCP, Helm
      PowerShell Gallery       the Az module (current user)
      Windows features         GPMC, RSAT-Clustering, RSAT-Hyper-V-Tools, RSAT-ADDS, RSAT-ADCS, RSAT-DHCP, RSAT-DNS-Server
    Takes no value a deployment chooses and asks nothing. A winget package that does not install (for example because it is
    already installed) is reported as a warning and the run goes on; a Windows feature that fails to install stops the run.
    Install-WindowsFeature exists on Windows Server only.

.NOTES
    Author:  Kristopher J Turner
    Updated: 2025-4-1 (2026-11: brought to the scripting standard; the list of tools is unchanged)

.EXAMPLE
    ./tools/install-tools.ps1
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$wingetPackages = @(
    'Microsoft.VisualStudioCode'
    'Microsoft.PowerShell'
    'Git.Git'
    'Microsoft.AzureCLI'
    'GitHub.GitHubDesktop'
    'PuTTY.PuTTY'
    'Kubernetes.kubectl'
    'WinSCP.WinSCP'
    'Helm.Helm'
)
foreach ($id in $wingetPackages) {
    & winget install -e --id $id --scope machine
    if ($LASTEXITCODE -ne 0) { Write-Warning "winget install $id ended with exit code $LASTEXITCODE (for example: already installed)." }
}

Install-Module -Name Az -Scope CurrentUser -AllowClobber -Force
Import-Module Az

# The Remote Server Administration Tools features to install.
$features = @(
    'GPMC'               # Group Policy Management Console
    'RSAT-Clustering'    # Failover Cluster Tools
    'RSAT-Hyper-V-Tools' # Hyper-V Management Tools
    'RSAT-ADDS'          # Active Directory Domain Services and Lightweight Directory Tools
    'RSAT-ADCS'          # Active Directory Certificate Services Tools
    'RSAT-DHCP'          # DHCP Server Tools
    'RSAT-DNS-Server'    # DNS Server Tools
)
foreach ($feature in $features) {
    Write-Information -InformationAction Continue -MessageData "Installing feature: $feature..."
    $null = Install-WindowsFeature -Name $feature -IncludeManagementTools
    Write-Information -InformationAction Continue -MessageData "$feature installed."
}
Write-Information -InformationAction Continue -MessageData 'All features installation completed.'
