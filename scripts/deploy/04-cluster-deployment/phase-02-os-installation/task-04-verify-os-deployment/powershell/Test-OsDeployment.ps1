<#
.SYNOPSIS
    Verifies OS deployment on Azure Local nodes.

.DESCRIPTION
    This script verifies the operating system installation:
    - Validates Windows Server version
    - Checks required features installed
    - Verifies network configuration
    - Validates domain join status

.PARAMETER NodeNames
    Array of node hostnames or IP addresses.

.PARAMETER Credential
    Credentials for node access.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Test-OsDeployment.ps1 -NodeNames @("node01", "node02")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 05-cluster-deployment
    Step: stage-12-os-deployment/step-01-verify-os
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\os-verification"
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Functions

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    [CmdletBinding()]
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $null }

    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    $configContent = Get-Content -Path $Path -Raw
    return ConvertFrom-Yaml $configContent
}

function Get-RequiredWindowsFeatures {
    <#
    .SYNOPSIS
        Returns list of required Windows features for Azure Local.
    #>
    return @(
        'Hyper-V'
        'Failover-Clustering'
        'FS-Data-Deduplication'
        'BitLocker'
        'Data-Center-Bridging'
        'RSAT-AD-PowerShell'
        'RSAT-Clustering-PowerShell'
        'NetworkATC'
    )
}

function Test-NodeOsDeployment {
    <#
    .SYNOPSIS
        Tests OS deployment on a single node.
    #>
    [CmdletBinding()]
    param(
        [string]$NodeName,
        [pscredential]$Credential,
        [string[]]$RequiredFeatures
    )

    $result = @{
        NodeName         = $NodeName
        Reachable        = $false
        OsVersion        = $null
        OsBuild          = $null
        DomainJoined     = $false
        DomainName       = $null
        Features         = @()
        MissingFeatures  = @()
        NetworkAdapters  = @()
        StorageReady     = $false
    }

    try {
        # Test connectivity first
        if (-not (Test-Connection -ComputerName $NodeName -Count 2 -Quiet)) {
            Write-LogMessage "  Node $NodeName is not reachable" -Level Error
            return $result
        }
        $result.Reachable = $true

        # Create remote session
        $sessionParams = @{
            ComputerName = $NodeName
            ErrorAction  = 'Stop'
        }
        if ($Credential) {
            $sessionParams['Credential'] = $Credential
        }

        $session = New-PSSession @sessionParams

        try {
            # Get OS information
            $osInfo = Invoke-Command -Session $session -ScriptBlock {
                Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber
            }
            $result.OsVersion = $osInfo.Caption
            $result.OsBuild = $osInfo.BuildNumber
            Write-LogMessage "    OS: $($osInfo.Caption) (Build $($osInfo.BuildNumber))" -Level Info

            # Check domain join
            $domainInfo = Invoke-Command -Session $session -ScriptBlock {
                $cs = Get-CimInstance -ClassName Win32_ComputerSystem
                @{
                    Domain       = $cs.Domain
                    PartOfDomain = $cs.PartOfDomain
                }
            }
            $result.DomainJoined = $domainInfo.PartOfDomain
            $result.DomainName = $domainInfo.Domain
            Write-LogMessage "    Domain: $(if($domainInfo.PartOfDomain){"$($domainInfo.Domain)"}else{'Not joined'})" -Level $(if($domainInfo.PartOfDomain){'Success'}else{'Warning'})

            # Check Windows features
            $installedFeatures = Invoke-Command -Session $session -ScriptBlock {
                Get-WindowsFeature | Where-Object { $_.InstallState -eq 'Installed' } | Select-Object -ExpandProperty Name
            }

            foreach ($feature in $RequiredFeatures) {
                $installed = $feature -in $installedFeatures
                $result.Features += @{
                    Name      = $feature
                    Installed = $installed
                }
                if (-not $installed) {
                    $result.MissingFeatures += $feature
                }
            }

            $installedCount = ($result.Features | Where-Object { $_.Installed }).Count
            Write-LogMessage "    Features: $installedCount / $($RequiredFeatures.Count) installed" -Level $(if($installedCount -eq $RequiredFeatures.Count){'Success'}else{'Warning'})

            # Check network adapters
            $adapters = Invoke-Command -Session $session -ScriptBlock {
                Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object Name, InterfaceDescription, LinkSpeed, MacAddress
            }
            $result.NetworkAdapters = $adapters
            Write-LogMessage "    Network: $($adapters.Count) active adapters" -Level Info

            # Check storage
            $disks = Invoke-Command -Session $session -ScriptBlock {
                Get-PhysicalDisk | Select-Object FriendlyName, MediaType, Size, HealthStatus
            }
            $result.StorageReady = ($disks | Where-Object { $_.HealthStatus -eq 'Healthy' }).Count -gt 0
            Write-LogMessage "    Storage: $($disks.Count) disks, Ready: $($result.StorageReady)" -Level Info

        } finally {
            Remove-PSSession -Session $session
        }

    } catch {
        Write-LogMessage "  Failed to verify node $NodeName : $_" -Level Error
    }

    return $result
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "OS Deployment Verification" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get node names from config if not provided
    if (-not $NodeNames -and $config.compute.cluster_nodes) {
        $NodeNames = $config.compute.cluster_nodes | ForEach-Object { $_.name }
    }

    if (-not $NodeNames) {
        throw "NodeNames are required"
    }

    # Prompt for credentials if not provided
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter credentials for node access"
    }

    # Get required features
    $requiredFeatures = Get-RequiredWindowsFeatures

    Write-LogMessage "Verifying $($NodeNames.Count) nodes..." -Level Info
    Write-LogMessage "Required features: $($requiredFeatures.Count)" -Level Info

    # Verify each node
    $results = @()
    foreach ($node in $NodeNames) {
        Write-LogMessage "Verifying: $node" -Level Info
        $nodeResult = Test-NodeOsDeployment -NodeName $node -Credential $Credential -RequiredFeatures $requiredFeatures
        $results += $nodeResult
    }

    # Generate report
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $reportFile = Join-Path $OutputPath "os-verification-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $results | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile
    Write-LogMessage "Report saved: $reportFile" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "OS Verification Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $reachable = ($results | Where-Object { $_.Reachable }).Count
    $domainJoined = ($results | Where-Object { $_.DomainJoined }).Count
    $featuresComplete = ($results | Where-Object { $_.MissingFeatures.Count -eq 0 }).Count

    Write-LogMessage "  Nodes verified: $($results.Count)" -Level Info
    Write-LogMessage "  Reachable: $reachable / $($results.Count)" -Level $(if($reachable -eq $results.Count){'Success'}else{'Error'})
    Write-LogMessage "  Domain joined: $domainJoined / $($results.Count)" -Level $(if($domainJoined -eq $results.Count){'Success'}else{'Warning'})
    Write-LogMessage "  Features complete: $featuresComplete / $($results.Count)" -Level $(if($featuresComplete -eq $results.Count){'Success'}else{'Warning'})

    if ($results.MissingFeatures | Where-Object { $_ }) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Missing features detected. Run:" -Level Warning
        Write-LogMessage "  Install-WindowsFeature -Name <feature> -IncludeManagementTools" -Level Info
    }

    return @{
        Results    = $results
        ReportPath = $reportFile
        AllReady   = ($reachable -eq $results.Count) -and ($featuresComplete -eq $results.Count)
    }

} catch {
    Write-LogMessage "OS verification failed: $_" -Level Error
    throw
}

#endregion Main
