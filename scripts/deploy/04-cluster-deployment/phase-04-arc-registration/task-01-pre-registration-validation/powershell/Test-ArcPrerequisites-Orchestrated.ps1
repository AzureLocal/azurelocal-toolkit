# Task 01 - Pre-Registration Environment Validation (orchestrated, all nodes)
# infrastructure.yml variables:
#   cluster_nodes[].management_ip  -> $ServerList

$ConfigPath = ".\configs\infrastructure.yml"
$ServerList = (Get-Content $ConfigPath | Select-String 'management_ip:\s+"?([^"'' ]+)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })

Invoke-Command ($ServerList) {
    if (-not (Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker)) {
        Install-Module -Name AzStackHci.EnvironmentChecker -Repository PSGallery -Force -AllowClobber
    }
    Import-Module AzStackHci.EnvironmentChecker
    Invoke-AzStackHciConnectivityValidation
} | Sort -Property PsComputerName
