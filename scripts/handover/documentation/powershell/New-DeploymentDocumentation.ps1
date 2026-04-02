<#
.SYNOPSIS
    Generates comprehensive documentation package for Azure Local deployment handover.

.DESCRIPTION
    This script generates documentation including:
    - Deployment configuration summary
    - Network topology documentation
    - Storage configuration details
    - Azure integration details
    - Operational runbooks
    - Architecture diagrams (Mermaid format)

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER CustomerName
    Customer organization name for documentation.

.PARAMETER OutputPath
    Path to save documentation package.

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration file.

.PARAMETER IncludeCredentialLocations
    Switch to include Key Vault credential locations (not values).

.EXAMPLE
    .\New-DeploymentDocumentation.ps1 -ClusterName "azl-cluster-01" -CustomerName "Contoso" -OutputPath "C:\Handover"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $true)]
    [string]$CustomerName,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeCredentialLocations
)

# Import helpers
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\common\utilities\helpers"

if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    }
}

# Initialize documentation structure
$DocPackage = @{
    GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    CustomerName = $CustomerName
    ClusterName = $ClusterName
    Sections = @{}
}

function Get-ClusterConfiguration {
    Write-Log -Message "Collecting cluster configuration..." -Level "INFO"
    
    try {
        $cluster = Get-Cluster -Name $ClusterName -ErrorAction Stop
        $nodes = Get-ClusterNode -Cluster $ClusterName
        
        $DocPackage.Sections.ClusterConfig = @{
            Name = $cluster.Name
            Domain = $cluster.Domain
            NodeCount = $nodes.Count
            Nodes = $nodes | ForEach-Object {
                @{
                    Name = $_.Name
                    State = $_.State.ToString()
                }
            }
            QuorumType = (Get-ClusterQuorum -Cluster $ClusterName).QuorumType.ToString()
        }
        
        Write-Log -Message "  Cluster: $($cluster.Name) with $($nodes.Count) nodes" -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Failed to get cluster config: $_" -Level "WARN"
    }
}

function Get-NetworkConfiguration {
    Write-Log -Message "Collecting network configuration..." -Level "INFO"
    
    try {
        $networks = Get-ClusterNetwork -Cluster $ClusterName
        
        $DocPackage.Sections.NetworkConfig = @{
            ClusterNetworks = $networks | ForEach-Object {
                @{
                    Name = $_.Name
                    Address = $_.Address
                    Role = $_.Role.ToString()
                    State = $_.State.ToString()
                }
            }
        }
        
        # Get virtual switch info from first node
        $node = (Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" } | Select-Object -First 1).Name
        
        $switches = Invoke-Command -ComputerName $node -ScriptBlock {
            Get-VMSwitch | Select-Object Name, SwitchType, EmbeddedTeamingEnabled
        }
        
        $DocPackage.Sections.NetworkConfig.VirtualSwitches = $switches | ForEach-Object {
            @{
                Name = $_.Name
                Type = $_.SwitchType.ToString()
                SetEnabled = $_.EmbeddedTeamingEnabled
            }
        }
        
        Write-Log -Message "  Networks: $($networks.Count), Switches: $($switches.Count)" -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Failed to get network config: $_" -Level "WARN"
    }
}

function Get-StorageConfiguration {
    Write-Log -Message "Collecting storage configuration..." -Level "INFO"
    
    try {
        $pools = Get-StoragePool -CimSession $ClusterName | Where-Object { $_.IsPrimordial -eq $false }
        $vDisks = Get-VirtualDisk -CimSession $ClusterName
        $csvs = Get-ClusterSharedVolume -Cluster $ClusterName
        
        $DocPackage.Sections.StorageConfig = @{
            StoragePools = $pools | ForEach-Object {
                @{
                    Name = $_.FriendlyName
                    SizeGB = [math]::Round($_.Size / 1GB, 0)
                    HealthStatus = $_.HealthStatus.ToString()
                }
            }
            VirtualDisks = $vDisks | ForEach-Object {
                @{
                    Name = $_.FriendlyName
                    SizeTB = [math]::Round($_.Size / 1TB, 2)
                    ResiliencySetting = $_.ResiliencySettingName
                    HealthStatus = $_.HealthStatus.ToString()
                }
            }
            CSVs = $csvs | ForEach-Object {
                @{
                    Name = $_.Name
                    Path = $_.SharedVolumeInfo[0].FriendlyVolumeName
                    State = $_.State.ToString()
                }
            }
        }
        
        Write-Log -Message "  Pools: $($pools.Count), VDisks: $($vDisks.Count), CSVs: $($csvs.Count)" -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Failed to get storage config: $_" -Level "WARN"
    }
}

function Get-AzureIntegrationDetails {
    Write-Log -Message "Collecting Azure integration details..." -Level "INFO"
    
    try {
        $node = (Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" } | Select-Object -First 1).Name
        
        $arcInfo = Invoke-Command -ComputerName $node -ScriptBlock {
            $agentPath = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
            if (Test-Path $agentPath) {
                $status = & $agentPath show --json 2>&1 | ConvertFrom-Json
                return @{
                    Status = $status.status
                    SubscriptionId = $status.subscriptionId
                    ResourceGroup = $status.resourceGroup
                    TenantId = $status.tenantId
                    Location = $status.location
                }
            }
            return $null
        }
        
        if ($arcInfo) {
            $DocPackage.Sections.AzureIntegration = @{
                ArcStatus = $arcInfo.Status
                SubscriptionId = $arcInfo.SubscriptionId
                ResourceGroup = $arcInfo.ResourceGroup
                TenantId = $arcInfo.TenantId
                Location = $arcInfo.Location
            }
            
            Write-Log -Message "  Azure Arc: $($arcInfo.Status) in $($arcInfo.ResourceGroup)" -Level "SUCCESS"
        }
    }
    catch {
        Write-Log -Message "Failed to get Azure integration: $_" -Level "WARN"
    }
}

function New-MarkdownDocumentation {
    Write-Log -Message "Generating Markdown documentation..." -Level "INFO"
    
    $mdContent = @"
# Azure Local Deployment Documentation

**Customer:** $CustomerName  
**Cluster:** $ClusterName  
**Generated:** $($DocPackage.GeneratedAt)

---

## Table of Contents

1. [Cluster Overview](#cluster-overview)
2. [Network Configuration](#network-configuration)
3. [Storage Configuration](#storage-configuration)
4. [Azure Integration](#azure-integration)
5. [Architecture Diagram](#architecture-diagram)
6. [Operational Procedures](#operational-procedures)
7. [Support Contacts](#support-contacts)

---

## Cluster Overview

| Property | Value |
|----------|-------|
| Cluster Name | $ClusterName |
| Domain | $($DocPackage.Sections.ClusterConfig.Domain) |
| Node Count | $($DocPackage.Sections.ClusterConfig.NodeCount) |
| Quorum Type | $($DocPackage.Sections.ClusterConfig.QuorumType) |

### Cluster Nodes

| Node Name | State |
|-----------|-------|
$(($DocPackage.Sections.ClusterConfig.Nodes | ForEach-Object { "| $($_.Name) | $($_.State) |" }) -join "`n")

---

## Network Configuration

### Cluster Networks

| Name | Address | Role | State |
|------|---------|------|-------|
$(($DocPackage.Sections.NetworkConfig.ClusterNetworks | ForEach-Object { "| $($_.Name) | $($_.Address) | $($_.Role) | $($_.State) |" }) -join "`n")

### Virtual Switches

| Name | Type | SET Enabled |
|------|------|-------------|
$(($DocPackage.Sections.NetworkConfig.VirtualSwitches | ForEach-Object { "| $($_.Name) | $($_.Type) | $($_.SetEnabled) |" }) -join "`n")

---

## Storage Configuration

### Storage Pools

| Name | Size (GB) | Health Status |
|------|-----------|---------------|
$(($DocPackage.Sections.StorageConfig.StoragePools | ForEach-Object { "| $($_.Name) | $($_.SizeGB) | $($_.HealthStatus) |" }) -join "`n")

### Virtual Disks

| Name | Size (TB) | Resiliency | Health |
|------|-----------|------------|--------|
$(($DocPackage.Sections.StorageConfig.VirtualDisks | ForEach-Object { "| $($_.Name) | $($_.SizeTB) | $($_.ResiliencySetting) | $($_.HealthStatus) |" }) -join "`n")

### Cluster Shared Volumes

| Name | Path | State |
|------|------|-------|
$(($DocPackage.Sections.StorageConfig.CSVs | ForEach-Object { "| $($_.Name) | $($_.Path) | $($_.State) |" }) -join "`n")

---

## Azure Integration

| Property | Value |
|----------|-------|
| Arc Status | $($DocPackage.Sections.AzureIntegration.ArcStatus) |
| Subscription ID | $($DocPackage.Sections.AzureIntegration.SubscriptionId) |
| Resource Group | $($DocPackage.Sections.AzureIntegration.ResourceGroup) |
| Tenant ID | $($DocPackage.Sections.AzureIntegration.TenantId) |
| Location | $($DocPackage.Sections.AzureIntegration.Location) |

---

## Architecture Diagram

``````mermaid
graph TB
    subgraph Azure["Azure Cloud"]
        ARM[Azure Resource Manager]
        ARC[Azure Arc]
        MON[Azure Monitor]
    end
    
    subgraph OnPrem["On-Premises"]
        subgraph Cluster["$ClusterName"]
$(($DocPackage.Sections.ClusterConfig.Nodes | ForEach-Object { "            NODE$($_.Name -replace '-','')[$($_.Name)]" }) -join "`n")
        end
        subgraph Storage["Storage Spaces Direct"]
            POOL[Storage Pool]
            CSV[Cluster Shared Volumes]
        end
    end
    
    ARC --> Cluster
    MON --> Cluster
    Cluster --> Storage
    Cluster --> ARM
``````

---

## Operational Procedures

### Daily Operations
- Monitor cluster health via Windows Admin Center or Azure Portal
- Review Azure Monitor alerts
- Check storage capacity utilization

### Weekly Operations  
- Review security logs and alerts
- Verify backup completion status
- Check for pending Windows Updates

### Monthly Operations
- Apply approved Windows Updates during maintenance window
- Review and rotate service account credentials
- Capacity planning review

### Troubleshooting
- Cluster health: `Get-ClusterNode`, `Get-ClusterResource`
- Storage health: `Get-StoragePool`, `Get-VirtualDisk`
- Arc status: `azcmagent show`

---

## Support Contacts

| Role | Contact |
|------|---------|
| Azure Local Cloud Support | support@Azure Local Cloud.com |
| Microsoft Support | Azure Portal Support Request |

---

*This document was automatically generated by the Azure Local Cloud AZL Toolkit.*
"@
    
    $mdPath = Join-Path $OutputPath "$CustomerName-$ClusterName-Documentation.md"
    $mdContent | Set-Content -Path $mdPath -Encoding UTF8
    
    Write-Log -Message "  Markdown: $mdPath" -Level "SUCCESS"
}

function New-JsonExport {
    Write-Log -Message "Exporting JSON data..." -Level "INFO"
    
    $jsonPath = Join-Path $OutputPath "$CustomerName-$ClusterName-Config.json"
    $DocPackage | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
    
    Write-Log -Message "  JSON: $jsonPath" -Level "SUCCESS"
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Generating Deployment Documentation" -Level "INFO"
    Write-Log -Message "Customer: $CustomerName" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    # Create output directory
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }
    
    # Collect information
    Get-ClusterConfiguration
    Get-NetworkConfiguration
    Get-StorageConfiguration
    Get-AzureIntegrationDetails
    
    Write-Host ""
    
    # Generate documentation
    New-MarkdownDocumentation
    New-JsonExport
    
    Write-Host ""
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Documentation package generated: $OutputPath" -Level "SUCCESS"
}
catch {
    Write-Log -Message "Documentation generation failed: $_" -Level "ERROR"
    exit 1
}
