<#
.SYNOPSIS
    Configures Datadog monitoring for Azure Local.

.DESCRIPTION
    This script configures Datadog monitoring:
    - Installs Datadog agent on cluster nodes
    - Configures Azure integration
    - Sets up custom metrics and checks
    - Configures log collection

.PARAMETER DatadogApiKey
    Datadog API key.

.PARAMETER DatadogSite
    Datadog site (e.g., datadoghq.com, datadoghq.eu).

.PARAMETER NodeNames
    Array of cluster node hostnames.

.EXAMPLE
    .\Set-DatadogConfiguration.ps1 -DatadogApiKey $apiKey -NodeNames @("node01", "node02")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-18-monitoring/step-02-datadog-configuration
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$DatadogApiKey,

    [Parameter(Mandatory = $false)]
    [string]$DatadogAppKey,

    [Parameter(Mandatory = $false)]
    [ValidateSet('datadoghq.com', 'datadoghq.eu', 'us3.datadoghq.com', 'us5.datadoghq.com', 'ddog-gov.com')]
    [string]$DatadogSite = 'datadoghq.com',

    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$InstallAgent,

    [Parameter(Mandatory = $false)]
    [switch]$EnableAzureIntegration
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

function Install-DatadogAgent {
    <#
    .SYNOPSIS
        Installs Datadog agent on a node.
    #>
    [CmdletBinding()]
    param(
        [string]$NodeName,
        [string]$ApiKey,
        [string]$Site,
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
            param($apiKey, $site)

            # Check if already installed
            $ddService = Get-Service -Name "datadogagent" -ErrorAction SilentlyContinue
            if ($ddService) {
                return @{
                    AlreadyInstalled = $true
                    Status           = $ddService.Status
                }
            }

            # Download and install Datadog agent
            $installerUrl = "https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi"
            $installerPath = "$env:TEMP\datadog-agent.msi"

            try {
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

                # Install with API key
                $msiArgs = @(
                    "/i", $installerPath,
                    "/qn",
                    "APIKEY=$apiKey",
                    "SITE=$site",
                    "TAGS=`"env:production,service:azurelocal`""
                )

                Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -NoNewWindow

                # Verify installation
                $ddService = Get-Service -Name "datadogagent" -ErrorAction SilentlyContinue
                
                return @{
                    Installed = $null -ne $ddService
                    Status    = $ddService.Status
                }
            } finally {
                if (Test-Path $installerPath) {
                    Remove-Item $installerPath -Force
                }
            }
        } -ArgumentList $ApiKey, $Site

        Remove-PSSession -Session $session

        return @{
            NodeName = $NodeName
            Success  = $true
            Result   = $result
        }
    } catch {
        return @{
            NodeName = $NodeName
            Success  = $false
            Error    = $_.Exception.Message
        }
    }
}

function Get-DatadogAgentStatus {
    <#
    .SYNOPSIS
        Gets Datadog agent status on a node.
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

        $status = Invoke-Command -Session $session -ScriptBlock {
            $ddService = Get-Service -Name "datadogagent" -ErrorAction SilentlyContinue
            if ($ddService) {
                $configPath = "${env:ProgramData}\Datadog\datadog.yaml"
                $configExists = Test-Path $configPath

                return @{
                    Installed    = $true
                    Status       = $ddService.Status
                    ConfigExists = $configExists
                }
            }
            return @{
                Installed = $false
            }
        }

        Remove-PSSession -Session $session

        return @{
            NodeName = $NodeName
            Success  = $true
            Status   = $status
        }
    } catch {
        return @{
            NodeName = $NodeName
            Success  = $false
            Error    = $_.Exception.Message
        }
    }
}

function New-DatadogAzureLocalConfig {
    <#
    .SYNOPSIS
        Generates Datadog configuration for Azure Local monitoring.
    #>
    [CmdletBinding()]
    param(
        [string]$ApiKey,
        [string]$Site,
        [string]$ClusterName,
        [string[]]$Tags
    )

    $config = @"
# Datadog Agent Configuration for Azure Local
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

api_key: $ApiKey
site: $Site

# Hostname
hostname: $ClusterName

# Tags
tags:
  - env:production
  - platform:azurelocal
  - cluster:$ClusterName
$(($Tags | ForEach-Object { "  - $_" }) -join "`n")

# Logs collection
logs_enabled: true

# Process monitoring
process_config:
  enabled: true

# Network monitoring
network_config:
  enabled: true

# Container monitoring (for AKS on Azure Local)
container_collect_all: true

# Integrations
integrations:

  # Windows Event Log
  - name: win32_event_log
    init_config:
    instances:
      - log_file:
          - Application
          - System
          - Security

  # Windows Performance Counters
  - name: windows_performance_counters
    init_config:
    instances:
      - class: Hyper-V Hypervisor Logical Processor
        metrics:
          - ["% Total Run Time", "hyperv.cpu.total_run_time", gauge]
      - class: Hyper-V Dynamic Memory VM
        metrics:
          - ["Physical Memory", "hyperv.memory.physical", gauge]

  # Cluster health
  - name: windows_service
    init_config:
    instances:
      - services:
          - ClusSvc
          - vmms
          - SDDC Management
"@

    return $config
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Datadog Configuration" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get values from config if not provided
    if (-not $NodeNames -and $config.compute.cluster_nodes) {
        $NodeNames = $config.compute.cluster_nodes | ForEach-Object { $_.name }
    }
    if (-not $DatadogApiKey -and $config.operations.monitoring.extended.datadog) {
        $DatadogApiKey = $config.operations.monitoring.extended.datadog.api_key
    }
    if (-not $DatadogSite -and $config.operations.monitoring.extended.datadog) {
        $DatadogSite = $config.operations.monitoring.extended.datadog.site ?? 'datadoghq.com'
    }

    if (-not $DatadogApiKey) {
        $DatadogApiKey = Read-Host -Prompt "Enter Datadog API key" -AsSecureString | 
            ConvertFrom-SecureString -AsPlainText
    }

    $results = @{
        NodeStatus     = @()
        ConfigGenerated = $false
    }

    # Check agent status on nodes
    if ($NodeNames) {
        if (-not $Credential) {
            $Credential = Get-Credential -Message "Enter credentials for cluster nodes"
        }

        Write-LogMessage "" -Level Info
        Write-LogMessage "Checking Datadog agent status on nodes..." -Level Info

        foreach ($node in $NodeNames) {
            $status = Get-DatadogAgentStatus -NodeName $node -Credential $Credential
            $results.NodeStatus += $status

            if ($status.Success) {
                if ($status.Status.Installed) {
                    Write-LogMessage "  $node : Installed ($($status.Status.Status))" -Level $(if($status.Status.Status -eq 'Running'){'Success'}else{'Warning'})
                } else {
                    Write-LogMessage "  $node : Not installed" -Level Info
                }
            } else {
                Write-LogMessage "  $node : Error - $($status.Error)" -Level Error
            }
        }
    }

    # Install agent if requested
    if ($InstallAgent -and $NodeNames) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Installing Datadog agent on nodes..." -Level Info

        foreach ($node in $NodeNames) {
            if ($PSCmdlet.ShouldProcess($node, "Install Datadog agent")) {
                $installResult = Install-DatadogAgent `
                    -NodeName $node `
                    -ApiKey $DatadogApiKey `
                    -Site $DatadogSite `
                    -Credential $Credential

                if ($installResult.Success) {
                    if ($installResult.Result.AlreadyInstalled) {
                        Write-LogMessage "  $node : Already installed" -Level Info
                    } else {
                        Write-LogMessage "  $node : Installed successfully" -Level Success
                    }
                } else {
                    Write-LogMessage "  $node : Failed - $($installResult.Error)" -Level Error
                }
            }
        }
    }

    # Generate configuration
    Write-LogMessage "" -Level Info
    Write-LogMessage "Generating Datadog configuration..." -Level Info

    $ddConfig = New-DatadogAzureLocalConfig `
        -ApiKey "YOUR_API_KEY_HERE" `
        -Site $DatadogSite `
        -ClusterName $config.compute.azure_local.cluster_name `
        -Tags @("customer:$($config.site.customer_name ?? 'unknown')")

    $configFile = ".\output\datadog\datadog-azurelocal.yaml"
    $configDir = Split-Path $configFile -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }
    Set-Content -Path $configFile -Value $ddConfig
    $results.ConfigGenerated = $true
    Write-LogMessage "  Configuration saved: $configFile" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Datadog Configuration Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $installed = ($results.NodeStatus | Where-Object { $_.Success -and $_.Status.Installed }).Count
    Write-LogMessage "  Nodes with agent: $installed / $($NodeNames.Count)" -Level Info
    Write-LogMessage "  Configuration: $configFile" -Level Info

    Write-LogMessage "" -Level Info
    Write-LogMessage "NEXT STEPS:" -Level Warning
    Write-LogMessage "  1. Copy configuration to nodes: %ProgramData%\Datadog\datadog.yaml" -Level Info
    Write-LogMessage "  2. Replace YOUR_API_KEY_HERE with actual API key" -Level Info
    Write-LogMessage "  3. Restart Datadog agent service" -Level Info
    Write-LogMessage "  4. Verify in Datadog dashboard" -Level Info

    return $results

} catch {
    Write-LogMessage "Datadog configuration failed: $_" -Level Error
    throw
}

#endregion Main
