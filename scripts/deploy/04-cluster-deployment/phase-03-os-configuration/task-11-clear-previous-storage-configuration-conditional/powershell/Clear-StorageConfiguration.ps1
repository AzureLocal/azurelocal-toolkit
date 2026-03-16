<#
.SYNOPSIS
    Clears and prepares storage for Azure Local deployment.

.DESCRIPTION
    This script prepares storage on Azure Local nodes:
    - Clears existing partitions from data disks
    - Resets storage pools
    - Validates disk health
    - Prepares disks for Storage Spaces Direct

.PARAMETER NodeNames
    Array of node hostnames.

.PARAMETER Credential
    Credentials for node access.

.PARAMETER Force
    Force clear without confirmation.

.EXAMPLE
    .\Clear-StorageConfiguration.ps1 -NodeNames @("node01", "node02") -Force

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 05-cluster-deployment
    Step: stage-13-node-configuration/step-03-clear-storage

    WARNING: This script will DESTROY all data on non-boot disks!
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$Force
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

function Get-NodeStorageInfo {
    <#
    .SYNOPSIS
        Gets current storage configuration from a node.
    #>
    [CmdletBinding()]
    param(
        [string]$NodeName,
        [pscredential]$Credential
    )

    $sessionParams = @{
        ComputerName = $NodeName
        ErrorAction  = 'Stop'
    }
    if ($Credential) {
        $sessionParams['Credential'] = $Credential
    }

    $session = New-PSSession @sessionParams

    try {
        $storageInfo = Invoke-Command -Session $session -ScriptBlock {
            $disks = Get-PhysicalDisk | Select-Object `
                FriendlyName, `
                DeviceId, `
                MediaType, `
                @{N='SizeGB';E={[math]::Round($_.Size/1GB,2)}}, `
                HealthStatus, `
                OperationalStatus, `
                BusType, `
                CanPool

            $pools = Get-StoragePool | Where-Object { $_.IsPrimordial -eq $false } | Select-Object `
                FriendlyName, `
                HealthStatus, `
                OperationalStatus, `
                @{N='SizeGB';E={[math]::Round($_.Size/1GB,2)}}

            $volumes = Get-Volume | Where-Object { $_.DriveLetter } | Select-Object `
                DriveLetter, `
                FileSystemLabel, `
                FileSystem, `
                @{N='SizeGB';E={[math]::Round($_.Size/1GB,2)}}, `
                HealthStatus

            @{
                Disks   = $disks
                Pools   = $pools
                Volumes = $volumes
            }
        }

        return @{
            NodeName    = $NodeName
            Success     = $true
            StorageInfo = $storageInfo
        }
    } catch {
        return @{
            NodeName = $NodeName
            Success  = $false
            Error    = $_.Exception.Message
        }
    } finally {
        Remove-PSSession -Session $session
    }
}

function Clear-NodeStorage {
    <#
    .SYNOPSIS
        Clears storage configuration on a node.
    #>
    [CmdletBinding()]
    param(
        [string]$NodeName,
        [pscredential]$Credential
    )

    $sessionParams = @{
        ComputerName = $NodeName
        ErrorAction  = 'Stop'
    }
    if ($Credential) {
        $sessionParams['Credential'] = $Credential
    }

    $session = New-PSSession @sessionParams

    try {
        $result = Invoke-Command -Session $session -ScriptBlock {
            $report = @{
                PoolsRemoved    = 0
                VirtualDisksRemoved = 0
                DisksCleared    = 0
                Errors          = @()
            }

            # Remove virtual disks
            try {
                $virtualDisks = Get-VirtualDisk -ErrorAction SilentlyContinue
                foreach ($vd in $virtualDisks) {
                    try {
                        Remove-VirtualDisk -FriendlyName $vd.FriendlyName -Confirm:$false -ErrorAction Stop
                        $report.VirtualDisksRemoved++
                    } catch {
                        $report.Errors += "Failed to remove virtual disk $($vd.FriendlyName): $_"
                    }
                }
            } catch { }

            # Remove storage pools (non-primordial)
            try {
                $pools = Get-StoragePool | Where-Object { $_.IsPrimordial -eq $false }
                foreach ($pool in $pools) {
                    try {
                        Remove-StoragePool -FriendlyName $pool.FriendlyName -Confirm:$false -ErrorAction Stop
                        $report.PoolsRemoved++
                    } catch {
                        $report.Errors += "Failed to remove pool $($pool.FriendlyName): $_"
                    }
                }
            } catch { }

            # Reset physical disks that can be pooled (non-boot disks)
            try {
                $disks = Get-PhysicalDisk | Where-Object { 
                    $_.CanPool -eq $true -or 
                    ($_.OperationalStatus -eq 'OK' -and $_.MediaType -ne 'Unspecified')
                }

                # Get boot disk to exclude
                $bootDisk = Get-Disk | Where-Object { $_.IsBoot -eq $true }
                
                foreach ($disk in $disks) {
                    # Skip if this is the boot disk
                    $diskObj = Get-Disk | Where-Object { $_.Number -eq $disk.DeviceId }
                    if ($diskObj.IsBoot -or $diskObj.IsSystem) {
                        continue
                    }

                    try {
                        # Clear the disk
                        Reset-PhysicalDisk -FriendlyName $disk.FriendlyName -Confirm:$false -ErrorAction SilentlyContinue
                        
                        # Clear partitions
                        $diskObj | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
                        
                        $report.DisksCleared++
                    } catch {
                        $report.Errors += "Failed to clear disk $($disk.FriendlyName): $_"
                    }
                }
            } catch { }

            return $report
        }

        return @{
            NodeName = $NodeName
            Success  = $true
            Report   = $result
        }
    } catch {
        return @{
            NodeName = $NodeName
            Success  = $false
            Error    = $_.Exception.Message
        }
    } finally {
        Remove-PSSession -Session $session
    }
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Storage Configuration Cleanup" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    Write-LogMessage "" -Level Info
    Write-LogMessage "⚠️  WARNING: This script will DESTROY all data on non-boot disks!" -Level Warning
    Write-LogMessage "" -Level Info

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

    # Confirm action
    if (-not $Force -and -not $PSCmdlet.ShouldProcess("All non-boot disks on $($NodeNames -join ', ')", "Clear storage")) {
        Write-LogMessage "Operation cancelled" -Level Warning
        return
    }

    # Get current storage state
    Write-LogMessage "Getting current storage configuration..." -Level Info
    $preState = @()
    foreach ($node in $NodeNames) {
        Write-LogMessage "  $node" -Level Info
        $info = Get-NodeStorageInfo -NodeName $node -Credential $Credential
        $preState += $info
        
        if ($info.Success) {
            $diskCount = $info.StorageInfo.Disks.Count
            $poolCount = $info.StorageInfo.Pools.Count
            Write-LogMessage "    Disks: $diskCount, Pools: $poolCount" -Level Info
        }
    }

    # Clear storage on each node
    Write-LogMessage "" -Level Info
    Write-LogMessage "Clearing storage..." -Level Info
    $results = @()
    foreach ($node in $NodeNames) {
        Write-LogMessage "  Clearing: $node" -Level Info
        $result = Clear-NodeStorage -NodeName $node -Credential $Credential
        $results += $result
        
        if ($result.Success) {
            Write-LogMessage "    Pools removed: $($result.Report.PoolsRemoved)" -Level Info
            Write-LogMessage "    Disks cleared: $($result.Report.DisksCleared)" -Level Info
            if ($result.Report.Errors) {
                foreach ($err in $result.Report.Errors) {
                    Write-LogMessage "    Error: $err" -Level Warning
                }
            }
        } else {
            Write-LogMessage "    Failed: $($result.Error)" -Level Error
        }
    }

    # Get post-clear state
    Write-LogMessage "" -Level Info
    Write-LogMessage "Verifying storage state..." -Level Info
    $postState = @()
    foreach ($node in $NodeNames) {
        $info = Get-NodeStorageInfo -NodeName $node -Credential $Credential
        $postState += $info
        
        if ($info.Success) {
            $canPool = ($info.StorageInfo.Disks | Where-Object { $_.CanPool }).Count
            Write-LogMessage "  $node : $canPool disks ready for pooling" -Level Success
        }
    }

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Storage Cleanup Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $successCount = ($results | Where-Object { $_.Success }).Count
    Write-LogMessage "  Nodes processed: $successCount / $($NodeNames.Count)" -Level Info

    $totalDisksCleared = ($results | Where-Object { $_.Success } | ForEach-Object { $_.Report.DisksCleared } | Measure-Object -Sum).Sum
    $totalPoolsRemoved = ($results | Where-Object { $_.Success } | ForEach-Object { $_.Report.PoolsRemoved } | Measure-Object -Sum).Sum

    Write-LogMessage "  Total disks cleared: $totalDisksCleared" -Level Info
    Write-LogMessage "  Total pools removed: $totalPoolsRemoved" -Level Info

    return @{
        Results   = $results
        PreState  = $preState
        PostState = $postState
    }

} catch {
    Write-LogMessage "Storage cleanup failed: $_" -Level Error
    throw
}

#endregion Main
