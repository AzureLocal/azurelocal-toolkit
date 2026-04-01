<#
    Author:  Kristopher J Turner
    Updated:  2025-4-1

    .DESCRIPTION
    .

    .NOTES
    .
#>

winget install -e --id Microsoft.VisualStudioCode --scope machine
winget install -e --id Microsoft.PowerShell --scope machine
winget install -e --id Git.Git --scope machine
winget install -e --id Microsoft.AzureCLI --scope machine
winget install -e --id GitHub.GitHubDesktop --scope machine
winget install -e --id PuTTY.PuTTY --scope machine
winget install -e --id Kubernetes.kubectl --scope machine
winget install -e --id WinSCP.WinSCP --scope machine
winget install -e --id Helm.Helm --scope machine

Install-Module -Name Az -Scope CurrentUser -AllowClobber -Force
Import-Module Az

<#
    Author:  Kristopher J Turner
    Updated:  2025-4-1

    .DESCRIPTION
    .

    .NOTES
    .
#>

# Define the features to install
$features = @(
    "GPMC",                                   # Group Policy Management Console
    "RSAT-Clustering",                        # Failover Cluster Tools
    "RSAT-Hyper-V-Tools",                     # Hyper-V Management Tools
    "RSAT-ADDS",                              # Active Directory Domain Services and Lightweight Directory Tools
    "RSAT-ADCS",                              # Active Directory Certificate Services Tools
    "RSAT-DHCP",                              # DHCP Server Tools
    "RSAT-DNS-Server"                         # DNS Server Tools
)

# Iterate over the features and install them
foreach ($feature in $features) {
    Write-Host "Installing feature: $feature..." -ForegroundColor Green
    Install-WindowsFeature -Name $feature -IncludeManagementTools -ErrorAction Stop
    if ($?) {
        Write-Host "$feature installed successfully." -ForegroundColor Cyan
    } else {
        Write-Host "Failed to install $feature." -ForegroundColor Red
    }
}

Write-Host "All features installation completed." -ForegroundColor Green