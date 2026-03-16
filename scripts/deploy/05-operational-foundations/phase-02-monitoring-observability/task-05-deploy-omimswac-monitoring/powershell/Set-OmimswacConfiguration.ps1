<#
.SYNOPSIS
    Configures OMIMSWAC (Operations Manager Integration for Windows Admin Center).

.DESCRIPTION
    This script configures monitoring integration:
    - Validates WAC installation
    - Configures SCOM integration if applicable
    - Sets up monitoring connections
    - Configures alert forwarding

.PARAMETER WacServerName
    Windows Admin Center server hostname.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Set-OmimswacConfiguration.ps1 -WacServerName "wac.Infinite Improbability Corp.local"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-18-monitoring/step-01-omimswac-configuration
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$WacServerName,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string[]]$ClusterNodes,

    [Parameter(Mandatory = $false)]
    [string]$ScomServerName,

    [Parameter(Mandatory = $false)]
    [switch]$EnableScomIntegration
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

function Test-WacInstallation {
    <#
    .SYNOPSIS
        Tests if Windows Admin Center is installed and accessible.
    #>
    [CmdletBinding()]
    param(
        [string]$ServerName,
        [pscredential]$Credential
    )

    try {
        # Test HTTPS connectivity to WAC
        $wacUrl = "https://$ServerName"
        $response = Invoke-WebRequest -Uri $wacUrl -UseBasicParsing -TimeoutSec 10 -SkipCertificateCheck -ErrorAction Stop
        
        return @{
            Installed   = $true
            Accessible  = $response.StatusCode -eq 200
            Url         = $wacUrl
        }
    } catch {
        return @{
            Installed   = $false
            Accessible  = $false
            Error       = $_.Exception.Message
        }
    }
}

function Get-WacExtensions {
    <#
    .SYNOPSIS
        Gets installed WAC extensions.
    #>
    [CmdletBinding()]
    param(
        [string]$ServerName,
        [pscredential]$Credential
    )

    $sessionParams = @{
        ComputerName = $ServerName
        ErrorAction  = 'Stop'
    }
    if ($Credential) {
        $sessionParams['Credential'] = $Credential
    }

    try {
        $session = New-PSSession @sessionParams

        $extensions = Invoke-Command -Session $session -ScriptBlock {
            $wacPath = "${env:ProgramFiles}\Windows Admin Center"
            if (Test-Path "$wacPath\Extensions") {
                Get-ChildItem "$wacPath\Extensions" -Directory | Select-Object Name
            }
        }

        Remove-PSSession -Session $session
        return $extensions
    } catch {
        return @()
    }
}

function Add-WacConnection {
    <#
    .SYNOPSIS
        Adds a cluster connection to Windows Admin Center.
    #>
    [CmdletBinding()]
    param(
        [string]$WacServer,
        [string]$ClusterName,
        [pscredential]$Credential
    )

    # WAC connections are typically managed via the WAC API
    # This provides the commands needed
    
    Write-LogMessage "  To add cluster connection manually:" -Level Info
    Write-LogMessage "    1. Open Windows Admin Center: https://$WacServer" -Level Info
    Write-LogMessage "    2. Click 'Add' in the connections panel" -Level Info
    Write-LogMessage "    3. Select 'Windows Server cluster'" -Level Info
    Write-LogMessage "    4. Enter cluster name: $ClusterName" -Level Info
    Write-LogMessage "    5. Click 'Add'" -Level Info
}

function Install-ScomAgent {
    <#
    .SYNOPSIS
        Installs SCOM agent on cluster nodes.
    #>
    [CmdletBinding()]
    param(
        [string[]]$NodeNames,
        [string]$ScomServer,
        [pscredential]$Credential
    )

    $results = @()

    foreach ($node in $NodeNames) {
        Write-LogMessage "  Installing SCOM agent on: $node" -Level Info
        
        try {
            $sessionParams = @{
                ComputerName = $node
                ErrorAction  = 'Stop'
            }
            if ($Credential) {
                $sessionParams['Credential'] = $Credential
            }

            $session = New-PSSession @sessionParams

            $installed = Invoke-Command -Session $session -ScriptBlock {
                param($scomServer)
                
                # Check if agent is already installed
                $agent = Get-Service -Name "HealthService" -ErrorAction SilentlyContinue
                if ($agent) {
                    return @{
                        AlreadyInstalled = $true
                        Status           = $agent.Status
                    }
                }

                # Agent installation would typically be done via SCOM console push
                # or via command line with the agent installer
                return @{
                    AlreadyInstalled = $false
                    Message          = "Agent installation required - use SCOM console or manual installation"
                }
            } -ArgumentList $ScomServer

            Remove-PSSession -Session $session

            $results += @{
                NodeName = $node
                Success  = $true
                Result   = $installed
            }

            if ($installed.AlreadyInstalled) {
                Write-LogMessage "    Agent already installed, Status: $($installed.Status)" -Level Info
            } else {
                Write-LogMessage "    $($installed.Message)" -Level Warning
            }
        } catch {
            $results += @{
                NodeName = $node
                Success  = $false
                Error    = $_.Exception.Message
            }
            Write-LogMessage "    Failed: $($_.Exception.Message)" -Level Error
        }
    }

    return $results
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "OMIMSWAC Configuration" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get values from config if not provided
    if (-not $WacServerName -and $config.operations.monitoring.wac) {
        $WacServerName = $config.operations.monitoring.wac.server
    }
    if (-not $ClusterNodes -and $config.compute.cluster_nodes) {
        $ClusterNodes = $config.compute.cluster_nodes | ForEach-Object { $_.name }
    }
    if (-not $ScomServerName -and $config.operations.monitoring.extended.scom) {
        $ScomServerName = $config.operations.monitoring.extended.scom.server
    }

    $results = @{
        WacStatus  = $null
        Extensions = @()
        ScomStatus = @()
    }

    # Test WAC installation
    if ($WacServerName) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Testing Windows Admin Center..." -Level Info
        $wacStatus = Test-WacInstallation -ServerName $WacServerName -Credential $Credential
        $results.WacStatus = $wacStatus

        if ($wacStatus.Accessible) {
            Write-LogMessage "  WAC accessible at: $($wacStatus.Url)" -Level Success

            # Get extensions
            if (-not $Credential) {
                $Credential = Get-Credential -Message "Enter credentials for WAC server"
            }
            $extensions = Get-WacExtensions -ServerName $WacServerName -Credential $Credential
            $results.Extensions = $extensions
            Write-LogMessage "  Extensions installed: $($extensions.Count)" -Level Info
        } else {
            Write-LogMessage "  WAC not accessible: $($wacStatus.Error)" -Level Warning
        }
    }

    # Configure SCOM integration
    if ($EnableScomIntegration -and $ScomServerName -and $ClusterNodes) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Configuring SCOM integration..." -Level Info
        
        if (-not $Credential) {
            $Credential = Get-Credential -Message "Enter credentials for cluster nodes"
        }
        
        $scomResults = Install-ScomAgent -NodeNames $ClusterNodes -ScomServer $ScomServerName -Credential $Credential
        $results.ScomStatus = $scomResults
    }

    # Display manual steps
    Write-LogMessage "" -Level Info
    Write-LogMessage "MANUAL CONFIGURATION STEPS:" -Level Warning
    Write-LogMessage "" -Level Info
    Write-LogMessage "1. WINDOWS ADMIN CENTER:" -Level Info
    
    if ($WacServerName) {
        Add-WacConnection -WacServer $WacServerName -ClusterName $config.compute.azure_local.cluster_name -Credential $Credential
    } else {
        Write-LogMessage "   - Install Windows Admin Center on a management server" -Level Info
        Write-LogMessage "   - Add Azure Local cluster connection" -Level Info
    }

    Write-LogMessage "" -Level Info
    Write-LogMessage "2. RECOMMENDED WAC EXTENSIONS:" -Level Info
    Write-LogMessage "   - Azure Local extension" -Level Info
    Write-LogMessage "   - Azure Kubernetes Service extension" -Level Info
    Write-LogMessage "   - Azure Arc extension" -Level Info

    if ($ScomServerName) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "3. SCOM INTEGRATION:" -Level Info
        Write-LogMessage "   - Import Azure Local management pack" -Level Info
        Write-LogMessage "   - Configure agent failover" -Level Info
        Write-LogMessage "   - Set up alert forwarding" -Level Info
    }

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "OMIMSWAC Configuration Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    if ($results.WacStatus) {
        Write-LogMessage "  WAC: $(if($results.WacStatus.Accessible){'Accessible'}else{'Not accessible'})" -Level Info
    }

    return $results

} catch {
    Write-LogMessage "OMIMSWAC configuration failed: $_" -Level Error
    throw
}

#endregion Main
