#Requires -Version 7.0
# Task 01 - Pre-Registration Environment Validation (orchestrated, all nodes)
# infrastructure.yml variables:
#   nodes[].management.ip_address  -> $ServerList

$ConfigPath = ".\configs\infrastructure.yml"
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
$ServerList = @(Get-AzlInfrastructureNode -Infrastructure (Get-Content $ConfigPath -Raw | ConvertFrom-Yaml) | ForEach-Object { $_.ManagementIp })

Invoke-Command ($ServerList) {
    if (-not (Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker)) {
        Install-Module -Name AzStackHci.EnvironmentChecker -Repository PSGallery -Force -AllowClobber
    }
    Import-Module AzStackHci.EnvironmentChecker
    Invoke-AzStackHciConnectivityValidation
} | Sort -Property PsComputerName
