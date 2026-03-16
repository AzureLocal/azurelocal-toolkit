<#
.SYNOPSIS
    Performs hardware inspection and validation for Azure Local nodes.

.DESCRIPTION
    This script performs physical hardware inspection:
    - Verifies server model and configuration
    - Checks physical connections
    - Validates hardware inventory against requirements
    - Documents hardware state

.PARAMETER NodeNames
    Array of node hostnames or IP addresses.

.PARAMETER iDRACCredential
    Credentials for Dell iDRAC access.

.PARAMETER OutputPath
    Path for inspection report output.

.EXAMPLE
    .\Test-HardwareInspection.ps1 -NodeNames @("node01-idrac", "node02-idrac")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 04-onprem-readiness
    Step: stage-09-enterprise-readiness/step-01-hardware-inspection
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [pscredential]$iDRACCredential,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\hardware-inspection",

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml"
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

function Get-iDRACSystemInfo {
    <#
    .SYNOPSIS
        Gets system information from Dell iDRAC via Redfish API.
    #>
    [CmdletBinding()]
    param(
        [string]$iDRACHost,
        [pscredential]$Credential
    )

    try {
        $baseUri = "https://$iDRACHost/redfish/v1"
        
        # Skip certificate validation for iDRAC
        $null = [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

        $systemUri = "$baseUri/Systems/System.Embedded.1"
        
        $params = @{
            Uri                  = $systemUri
            Credential           = $Credential
            Method               = 'GET'
            ContentType          = 'application/json'
            SkipCertificateCheck = $true
        }

        $system = Invoke-RestMethod @params

        return @{
            Manufacturer    = $system.Manufacturer
            Model           = $system.Model
            SerialNumber    = $system.SerialNumber
            ServiceTag      = $system.SKU
            BiosVersion     = $system.BiosVersion
            ProcessorCount  = $system.ProcessorSummary.Count
            ProcessorModel  = $system.ProcessorSummary.Model
            TotalMemoryGiB  = [math]::Round($system.MemorySummary.TotalSystemMemoryGiB, 0)
            PowerState      = $system.PowerState
            Health          = $system.Status.Health
            HostName        = $system.HostName
        }
    } catch {
        Write-LogMessage "  Failed to query iDRAC $iDRACHost : $_" -Level Warning
        return $null
    }
}

function Get-iDRACStorageInfo {
    <#
    .SYNOPSIS
        Gets storage information from Dell iDRAC via Redfish API.
    #>
    [CmdletBinding()]
    param(
        [string]$iDRACHost,
        [pscredential]$Credential
    )

    try {
        $baseUri = "https://$iDRACHost/redfish/v1"
        $storageUri = "$baseUri/Systems/System.Embedded.1/Storage"

        $params = @{
            Uri                  = $storageUri
            Credential           = $Credential
            Method               = 'GET'
            ContentType          = 'application/json'
            SkipCertificateCheck = $true
        }

        $storage = Invoke-RestMethod @params
        
        $controllers = @()
        foreach ($member in $storage.Members) {
            $controllerUri = "https://$iDRACHost$($member.'@odata.id')"
            $controller = Invoke-RestMethod -Uri $controllerUri -Credential $Credential -Method GET -SkipCertificateCheck
            
            $controllers += @{
                Name   = $controller.Name
                Model  = $controller.StorageControllers[0].Model
                Status = $controller.Status.Health
            }
        }

        return $controllers
    } catch {
        Write-LogMessage "  Failed to query storage on $iDRACHost : $_" -Level Warning
        return @()
    }
}

function Get-iDRACNetworkInfo {
    <#
    .SYNOPSIS
        Gets network adapter information from Dell iDRAC via Redfish API.
    #>
    [CmdletBinding()]
    param(
        [string]$iDRACHost,
        [pscredential]$Credential
    )

    try {
        $baseUri = "https://$iDRACHost/redfish/v1"
        $networkUri = "$baseUri/Systems/System.Embedded.1/NetworkAdapters"

        $params = @{
            Uri                  = $networkUri
            Credential           = $Credential
            Method               = 'GET'
            ContentType          = 'application/json'
            SkipCertificateCheck = $true
        }

        $network = Invoke-RestMethod @params

        $adapters = @()
        foreach ($member in $network.Members) {
            $adapterUri = "https://$iDRACHost$($member.'@odata.id')"
            $adapter = Invoke-RestMethod -Uri $adapterUri -Credential $Credential -Method GET -SkipCertificateCheck
            
            $adapters += @{
                Name         = $adapter.Name
                Manufacturer = $adapter.Manufacturer
                Model        = $adapter.Model
                Status       = $adapter.Status.Health
            }
        }

        return $adapters
    } catch {
        Write-LogMessage "  Failed to query network on $iDRACHost : $_" -Level Warning
        return @()
    }
}

function New-InspectionReport {
    <#
    .SYNOPSIS
        Creates the hardware inspection report.
    #>
    [CmdletBinding()]
    param(
        [hashtable[]]$NodeResults,
        [string]$OutputPath
    )

    $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $reportFile = Join-Path $OutputPath "hardware-inspection-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"

    $report = @"
# Hardware Inspection Report

**Generated:** $reportDate

## Executive Summary

| Node | Model | Serial | Memory | CPUs | Health |
|------|-------|--------|--------|------|--------|
"@

    foreach ($node in $NodeResults) {
        if ($node.SystemInfo) {
            $info = $node.SystemInfo
            $report += "`n| $($node.Name) | $($info.Model) | $($info.ServiceTag) | $($info.TotalMemoryGiB) GB | $($info.ProcessorCount) | $($info.Health) |"
        } else {
            $report += "`n| $($node.Name) | N/A | N/A | N/A | N/A | Unreachable |"
        }
    }

    $report += @"

---

## Detailed Node Information

"@

    foreach ($node in $NodeResults) {
        $report += @"

### $($node.Name)

"@
        if ($node.SystemInfo) {
            $info = $node.SystemInfo
            $report += @"
**System Information:**
- **Manufacturer:** $($info.Manufacturer)
- **Model:** $($info.Model)
- **Service Tag:** $($info.ServiceTag)
- **BIOS Version:** $($info.BiosVersion)
- **Power State:** $($info.PowerState)
- **Health Status:** $($info.Health)

**Processor:**
- **Count:** $($info.ProcessorCount)
- **Model:** $($info.ProcessorModel)

**Memory:**
- **Total:** $($info.TotalMemoryGiB) GB

"@
            if ($node.StorageInfo) {
                $report += "**Storage Controllers:**`n"
                foreach ($ctrl in $node.StorageInfo) {
                    $report += "- $($ctrl.Name): $($ctrl.Model) - $($ctrl.Status)`n"
                }
            }

            if ($node.NetworkInfo) {
                $report += "`n**Network Adapters:**`n"
                foreach ($nic in $node.NetworkInfo) {
                    $report += "- $($nic.Name): $($nic.Model) - $($nic.Status)`n"
                }
            }
        } else {
            $report += "⚠️ **Unable to collect information - node unreachable**`n"
        }
    }

    $report += @"

---

## Validation Checklist

- [ ] All nodes physically inspected
- [ ] Cable connections verified
- [ ] Power connections verified
- [ ] Network connections verified
- [ ] iDRAC access confirmed
- [ ] Hardware health green on all nodes
- [ ] Memory configuration matches requirements
- [ ] Storage configuration matches requirements
- [ ] Network adapters match requirements

---

*Report generated by Azure Local Cloud AzureLocalCloud Automation*
"@

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    Set-Content -Path $reportFile -Value $report
    return $reportFile
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Hardware Inspection and Validation" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
    }

    # Get node names from config if not provided
    if (-not $NodeNames -and $config.compute.cluster_nodes) {
        $NodeNames = $config.compute.cluster_nodes | ForEach-Object { "$($_.name)-idrac" }
    }

    if (-not $NodeNames) {
        throw "NodeNames are required. Provide them via parameter or configuration."
    }

    # Prompt for iDRAC credentials if not provided
    if (-not $iDRACCredential) {
        $iDRACCredential = Get-Credential -Message "Enter iDRAC credentials"
    }

    Write-LogMessage "Inspecting $($NodeNames.Count) nodes..." -Level Info

    # Collect information from each node
    $results = @()
    foreach ($node in $NodeNames) {
        Write-LogMessage "Querying: $node" -Level Info

        $nodeResult = @{
            Name        = $node
            SystemInfo  = $null
            StorageInfo = @()
            NetworkInfo = @()
        }

        # Get system info
        $nodeResult.SystemInfo = Get-iDRACSystemInfo -iDRACHost $node -Credential $iDRACCredential
        
        if ($nodeResult.SystemInfo) {
            Write-LogMessage "  Model: $($nodeResult.SystemInfo.Model)" -Level Success
            Write-LogMessage "  Service Tag: $($nodeResult.SystemInfo.ServiceTag)" -Level Info
            Write-LogMessage "  Memory: $($nodeResult.SystemInfo.TotalMemoryGiB) GB" -Level Info
            Write-LogMessage "  Health: $($nodeResult.SystemInfo.Health)" -Level Info

            # Get storage info
            $nodeResult.StorageInfo = Get-iDRACStorageInfo -iDRACHost $node -Credential $iDRACCredential

            # Get network info
            $nodeResult.NetworkInfo = Get-iDRACNetworkInfo -iDRACHost $node -Credential $iDRACCredential
        }

        $results += $nodeResult
    }

    # Generate report
    Write-LogMessage "Generating inspection report..." -Level Info
    $reportPath = New-InspectionReport -NodeResults $results -OutputPath $OutputPath
    Write-LogMessage "  Report saved: $reportPath" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Hardware Inspection Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $reachable = ($results | Where-Object { $_.SystemInfo }).Count
    $unreachable = $results.Count - $reachable

    Write-LogMessage "  Nodes inspected: $($results.Count)" -Level Info
    Write-LogMessage "  Reachable: $reachable" -Level $(if($reachable -eq $results.Count){'Success'}else{'Warning'})
    Write-LogMessage "  Unreachable: $unreachable" -Level $(if($unreachable -eq 0){'Info'}else{'Error'})
    Write-LogMessage "  Report: $reportPath" -Level Info

    return @{
        Results    = $results
        ReportPath = $reportPath
    }

} catch {
    Write-LogMessage "Hardware inspection failed: $_" -Level Error
    throw
}

#endregion Main
