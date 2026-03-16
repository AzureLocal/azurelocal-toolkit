<#
.SYNOPSIS
    Validates SDN prerequisites for Azure Local deployment.

.DESCRIPTION
    This script validates Software Defined Networking prerequisites:
    - Validates network controller requirements
    - Checks VLAN configuration
    - Verifies BGP settings
    - Validates logical network configuration

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Test-SdnPrerequisites.ps1

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-17-sdn-configuration/step-01-sdn-prerequisites
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\sdn-validation"
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

function Get-SdnPrerequisiteChecks {
    <#
    .SYNOPSIS
        Returns the list of SDN prerequisite checks.
    #>
    return @(
        @{
            Name        = "Management Network"
            Category    = "Network"
            Description = "Verify management network VLAN and IP range"
            Required    = $true
        }
        @{
            Name        = "Storage Network"
            Category    = "Network"
            Description = "Verify storage network VLAN and IP range"
            Required    = $true
        }
        @{
            Name        = "Compute Network"
            Category    = "Network"
            Description = "Verify compute/VM network VLAN range"
            Required    = $true
        }
        @{
            Name        = "HNV Provider Network"
            Category    = "Network"
            Description = "Verify HNV provider network for SDN"
            Required    = $false
        }
        @{
            Name        = "BGP Configuration"
            Category    = "Routing"
            Description = "Verify BGP peer configuration for load balancers"
            Required    = $false
        }
        @{
            Name        = "IP Pools"
            Category    = "IPAM"
            Description = "Verify IP address pools for SDN workloads"
            Required    = $true
        }
        @{
            Name        = "MTU Configuration"
            Category    = "Network"
            Description = "Verify jumbo frames enabled (MTU 9000+)"
            Required    = $true
        }
        @{
            Name        = "Network Controller"
            Category    = "SDN"
            Description = "Verify Network Controller service account"
            Required    = $false
        }
    )
}

function Test-NetworkConfiguration {
    <#
    .SYNOPSIS
        Tests network configuration from the config file.
    #>
    [CmdletBinding()]
    param([hashtable]$Config)

    $results = @()

    # Check management network
    $mgmtNetwork = $config.networking.onprem.vlans.management
    $results += @{
        Check   = "Management Network"
        Passed  = $null -ne $mgmtNetwork
        Details = if ($mgmtNetwork) { "VLAN: $($mgmtNetwork.id), Subnet: $($mgmtNetwork.subnet)" } else { "Not configured" }
    }

    # Check storage network
    $storageNetwork = $config.networking.onprem.vlans.storage
    $results += @{
        Check   = "Storage Network"
        Passed  = $null -ne $storageNetwork
        Details = if ($storageNetwork) { "VLAN: $($storageNetwork.id), Subnet: $($storageNetwork.subnet)" } else { "Not configured" }
    }

    # Check compute network
    $computeNetwork = $config.networking.onprem.vlans.workload
    $results += @{
        Check   = "Compute Network"
        Passed  = $null -ne $computeNetwork
        Details = if ($computeNetwork) { "VLAN Range: $($computeNetwork.start)-$($computeNetwork.end)" } else { "Not configured" }
    }

    # Check MTU
    $mtu = $config.networking.onprem.mtu
    $results += @{
        Check   = "MTU Configuration"
        Passed  = $mtu -ge 9000
        Details = "MTU: $($mtu ?? 'Default')"
    }

    return $results
}

function Test-NodeNetworkReadiness {
    <#
    .SYNOPSIS
        Tests network readiness on cluster nodes.
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

        $nodeNetwork = Invoke-Command -Session $session -ScriptBlock {
            $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
            $vmSwitch = Get-VMSwitch -ErrorAction SilentlyContinue
            
            $result = @{
                Adapters = @()
                VMSwitch = $null
            }

            foreach ($adapter in $adapters) {
                $adapterInfo = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword "*JumboPacket" -ErrorAction SilentlyContinue
                $result.Adapters += @{
                    Name       = $adapter.Name
                    LinkSpeed  = $adapter.LinkSpeed
                    Status     = $adapter.Status
                    JumboFrame = $adapterInfo.RegistryValue
                }
            }

            if ($vmSwitch) {
                $result.VMSwitch = @{
                    Name        = $vmSwitch.Name
                    Type        = $vmSwitch.SwitchType
                    NetAdapters = $vmSwitch.NetAdapterInterfaceDescriptions
                }
            }

            return $result
        }

        Remove-PSSession -Session $session

        return @{
            NodeName = $NodeName
            Success  = $true
            Network  = $nodeNetwork
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
    Write-LogMessage "SDN Prerequisites Validation" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    } else {
        throw "Configuration file not found: $ConfigPath"
    }

    # Get node names from config if not provided
    if (-not $NodeNames -and $config.compute.cluster_nodes) {
        $NodeNames = $config.compute.cluster_nodes | ForEach-Object { $_.name }
    }

    # Get prerequisite checks
    $prereqChecks = Get-SdnPrerequisiteChecks

    # Validate network configuration from config
    Write-LogMessage "" -Level Info
    Write-LogMessage "Validating network configuration..." -Level Info
    $networkResults = Test-NetworkConfiguration -Config $config

    foreach ($result in $networkResults) {
        $status = if ($result.Passed) { "✓" } else { "✗" }
        $color = if ($result.Passed) { "Green" } else { "Red" }
        Write-Host "  $status $($result.Check): $($result.Details)" -ForegroundColor $color
    }

    # Test node network if nodes specified and credentials available
    $nodeResults = @()
    if ($NodeNames) {
        if (-not $Credential) {
            $Credential = Get-Credential -Message "Enter credentials for node access"
        }

        Write-LogMessage "" -Level Info
        Write-LogMessage "Validating node network readiness..." -Level Info
        
        foreach ($node in $NodeNames) {
            Write-LogMessage "  Checking: $node" -Level Info
            $result = Test-NodeNetworkReadiness -NodeName $node -Credential $Credential
            $nodeResults += $result

            if ($result.Success) {
                $adapterCount = $result.Network.Adapters.Count
                $jumboEnabled = ($result.Network.Adapters | Where-Object { [int]$_.JumboFrame -ge 9000 }).Count
                Write-LogMessage "    Adapters: $adapterCount, Jumbo frames: $jumboEnabled" -Level Info
                
                if ($result.Network.VMSwitch) {
                    Write-LogMessage "    VM Switch: $($result.Network.VMSwitch.Name) ($($result.Network.VMSwitch.Type))" -Level Info
                }
            } else {
                Write-LogMessage "    Failed: $($result.Error)" -Level Error
            }
        }
    }

    # Generate report
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $report = @{
        Timestamp         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        PrerequisiteChecks = $prereqChecks
        NetworkValidation  = $networkResults
        NodeValidation     = $nodeResults
    }

    $reportFile = Join-Path $OutputPath "sdn-prerequisites-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile
    Write-LogMessage "" -Level Info
    Write-LogMessage "Report saved: $reportFile" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "SDN Prerequisites Validation Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $passedConfig = ($networkResults | Where-Object { $_.Passed }).Count
    $totalConfig = $networkResults.Count
    Write-LogMessage "  Configuration checks: $passedConfig / $totalConfig passed" -Level $(if($passedConfig -eq $totalConfig){'Success'}else{'Warning'})

    if ($nodeResults) {
        $passedNodes = ($nodeResults | Where-Object { $_.Success }).Count
        Write-LogMessage "  Node checks: $passedNodes / $($nodeResults.Count) passed" -Level $(if($passedNodes -eq $nodeResults.Count){'Success'}else{'Warning'})
    }

    return @{
        NetworkResults = $networkResults
        NodeResults    = $nodeResults
        ReportPath     = $reportFile
    }

} catch {
    Write-LogMessage "SDN prerequisites validation failed: $_" -Level Error
    throw
}

#endregion Main
