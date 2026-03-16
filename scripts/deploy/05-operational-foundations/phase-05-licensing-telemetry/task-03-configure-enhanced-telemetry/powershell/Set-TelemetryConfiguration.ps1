<#
.SYNOPSIS
    Configures telemetry settings for Azure Local.

.DESCRIPTION
    This script configures telemetry and diagnostics:
    - Sets telemetry level
    - Configures diagnostic data collection
    - Enables/disables specific telemetry features
    - Reviews current settings

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER TelemetryLevel
    Desired telemetry level (Basic, Enhanced, Full).

.EXAMPLE
    .\Set-TelemetryConfiguration.ps1 -ClusterName "azl-cluster01" -TelemetryLevel "Enhanced"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-21-licensing/step-02-telemetry-configuration
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Basic', 'Enhanced', 'Full')]
    [string]$TelemetryLevel = 'Enhanced',

    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$ApplySettings
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

function Get-TelemetryLevelValue {
    <#
    .SYNOPSIS
        Converts telemetry level name to registry value.
    #>
    [CmdletBinding()]
    param([string]$Level)

    switch ($Level) {
        'Basic'    { return 1 }
        'Enhanced' { return 2 }
        'Full'     { return 3 }
        default    { return 2 }
    }
}

function Get-NodeTelemetrySettings {
    <#
    .SYNOPSIS
        Gets current telemetry settings from a node.
    #>
    [CmdletBinding()]
    param(
        [string]$NodeName,
        [pscredential]$Credential
    )

    try {
        $sessionParams = @{
            ComputerName = $NodeName
            ErrorAction  = 'Stop'
        }
        if ($Credential) {
            $sessionParams['Credential'] = $Credential
        }

        $session = New-PSSession @sessionParams

        $settings = Invoke-Command -Session $session -ScriptBlock {
            $telemetry = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -ErrorAction SilentlyContinue
            $diagTrack = Get-Service -Name "DiagTrack" -ErrorAction SilentlyContinue

            $levelName = switch ($telemetry.AllowTelemetry) {
                0 { "Security (Off)" }
                1 { "Basic" }
                2 { "Enhanced" }
                3 { "Full" }
                default { "Unknown ($($telemetry.AllowTelemetry))" }
            }

            return @{
                TelemetryLevel      = $telemetry.AllowTelemetry
                TelemetryLevelName  = $levelName
                DiagTrackStatus     = $diagTrack.Status
                DiagTrackStartType  = $diagTrack.StartType
            }
        }

        Remove-PSSession -Session $session

        return @{
            NodeName = $NodeName
            Success  = $true
            Settings = $settings
        }
    } catch {
        return @{
            NodeName = $NodeName
            Success  = $false
            Error    = $_.Exception.Message
        }
    }
}

function Set-NodeTelemetryLevel {
    <#
    .SYNOPSIS
        Sets telemetry level on a node.
    #>
    [CmdletBinding()]
    param(
        [string]$NodeName,
        [int]$Level,
        [pscredential]$Credential
    )

    try {
        $sessionParams = @{
            ComputerName = $NodeName
            ErrorAction  = 'Stop'
        }
        if ($Credential) {
            $sessionParams['Credential'] = $Credential
        }

        $session = New-PSSession @sessionParams

        $result = Invoke-Command -Session $session -ScriptBlock {
            param($level)

            $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
            
            if (-not (Test-Path $regPath)) {
                New-Item -Path $regPath -Force | Out-Null
            }

            Set-ItemProperty -Path $regPath -Name "AllowTelemetry" -Value $level -Type DWord
            
            # Ensure DiagTrack service is running
            $diagTrack = Get-Service -Name "DiagTrack"
            if ($diagTrack.Status -ne 'Running') {
                Set-Service -Name "DiagTrack" -StartupType Automatic
                Start-Service -Name "DiagTrack"
            }

            # Verify the setting
            $verify = Get-ItemProperty -Path $regPath -Name "AllowTelemetry" -ErrorAction SilentlyContinue
            
            return @{
                Success = $verify.AllowTelemetry -eq $level
                NewLevel = $verify.AllowTelemetry
            }
        } -ArgumentList $Level

        Remove-PSSession -Session $session

        return @{
            NodeName = $NodeName
            Success  = $result.Success
            NewLevel = $result.NewLevel
        }
    } catch {
        return @{
            NodeName = $NodeName
            Success  = $false
            Error    = $_.Exception.Message
        }
    }
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Telemetry Configuration" -Level Info
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
    if (-not $ClusterName -and $config.cluster) {
        $ClusterName = $config.compute.azure_local.cluster_name
    }

    if (-not $NodeNames) {
        throw "NodeNames are required"
    }

    # Prompt for credentials if not provided
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter credentials for cluster nodes"
    }

    $telemetryValue = Get-TelemetryLevelValue -Level $TelemetryLevel

    Write-LogMessage "Cluster: $ClusterName" -Level Info
    Write-LogMessage "Target telemetry level: $TelemetryLevel ($telemetryValue)" -Level Info

    # Get current settings
    Write-LogMessage "" -Level Info
    Write-LogMessage "Getting current telemetry settings..." -Level Info

    $currentSettings = @()
    foreach ($node in $NodeNames) {
        $settings = Get-NodeTelemetrySettings -NodeName $node -Credential $Credential
        $currentSettings += $settings

        if ($settings.Success) {
            Write-LogMessage "  $node : $($settings.Settings.TelemetryLevelName) (DiagTrack: $($settings.Settings.DiagTrackStatus))" -Level Info
        } else {
            Write-LogMessage "  $node : Error - $($settings.Error)" -Level Error
        }
    }

    # Apply settings if requested
    if ($ApplySettings) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Applying telemetry settings..." -Level Info

        $applyResults = @()
        foreach ($node in $NodeNames) {
            if ($PSCmdlet.ShouldProcess($node, "Set telemetry level to $TelemetryLevel")) {
                $result = Set-NodeTelemetryLevel -NodeName $node -Level $telemetryValue -Credential $Credential
                $applyResults += $result

                if ($result.Success) {
                    Write-LogMessage "  $node : ✓ Applied (Level: $($result.NewLevel))" -Level Success
                } else {
                    Write-LogMessage "  $node : ✗ Failed - $($result.Error)" -Level Error
                }
            }
        }
    }

    # Telemetry explanation
    Write-LogMessage "" -Level Info
    Write-LogMessage "TELEMETRY LEVELS:" -Level Warning
    Write-LogMessage "" -Level Info
    Write-LogMessage "1. BASIC (Level 1):" -Level Info
    Write-LogMessage "   - Minimal data required for Windows Update" -Level Info
    Write-LogMessage "   - Basic device info, compatibility data" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "2. ENHANCED (Level 2) - Recommended:" -Level Info
    Write-LogMessage "   - Includes Basic data" -Level Info
    Write-LogMessage "   - Reliability and performance data" -Level Info
    Write-LogMessage "   - Helps Microsoft improve Windows" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "3. FULL (Level 3):" -Level Info
    Write-LogMessage "   - Includes Enhanced data" -Level Info
    Write-LogMessage "   - Additional diagnostics" -Level Info
    Write-LogMessage "   - Most comprehensive but highest data volume" -Level Info

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Telemetry Configuration Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    if ($ApplySettings -and $applyResults) {
        $applied = ($applyResults | Where-Object { $_.Success }).Count
        Write-LogMessage "  Nodes configured: $applied / $($NodeNames.Count)" -Level $(if($applied -eq $NodeNames.Count){'Success'}else{'Warning'})
    }

    return @{
        CurrentSettings = $currentSettings
        ApplyResults    = $applyResults
        TargetLevel     = $TelemetryLevel
    }

} catch {
    Write-LogMessage "Telemetry configuration failed: $_" -Level Error
    throw
}

#endregion Main
