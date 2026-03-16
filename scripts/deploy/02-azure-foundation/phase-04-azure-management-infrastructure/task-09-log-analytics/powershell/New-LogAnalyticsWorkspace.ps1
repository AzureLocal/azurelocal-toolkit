<#
.SYNOPSIS
    Creates a Log Analytics Workspace for Azure Local monitoring.

.DESCRIPTION
    This script creates a Log Analytics Workspace configured for Azure Local
    cluster monitoring, including appropriate data retention settings.

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace.

.PARAMETER ResourceGroupName
    Name of the resource group.

.PARAMETER Location
    Azure region. Default: eastus

.PARAMETER RetentionInDays
    Data retention period in days. Default: 90

.PARAMETER Sku
    Workspace SKU. Default: PerGB2018

.EXAMPLE
    .\New-LogAnalyticsWorkspace.ps1 -WorkspaceName "log-azl-prd-eus" -ResourceGroupName "rg-azlmgmt-prd-eus-01"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [int]$RetentionInDays = 90,

    [Parameter(Mandatory = $false)]
    [string]$Sku = "PerGB2018",

    [Parameter(Mandatory = $false)]
    [hashtable]$Tags = @{}
)

#Requires -Modules Az.OperationalInsights

# Import logging helper
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\common\utilities\helpers"

if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $color = switch ($Level) {
            "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }
        }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
    }
}

try {
    Write-Log -Message "Starting Log Analytics Workspace Creation" -Level "INFO"

    # Check if workspace already exists
    $existingWorkspace = Get-AzOperationalInsightsWorkspace `
        -ResourceGroupName $ResourceGroupName `
        -Name $WorkspaceName `
        -ErrorAction SilentlyContinue

    if ($existingWorkspace) {
        Write-Log -Message "Workspace '$WorkspaceName' already exists" -Level "WARN"
        Write-Log -Message "  Workspace ID: $($existingWorkspace.CustomerId)" -Level "INFO"
        return $existingWorkspace
    }

    # Build tags
    $defaultTags = @{
        "Environment"  = "Production"
        "Application"  = "Azure Local"
        "ManagedBy"    = "Azure Local Cloud"
        "CreatedDate"  = (Get-Date -Format "yyyy-MM-dd")
    }
    $allTags = $defaultTags + $Tags

    # Create workspace
    Write-Log -Message "Creating Log Analytics Workspace..." -Level "INFO"
    Write-Log -Message "  Name: $WorkspaceName" -Level "INFO"
    Write-Log -Message "  Location: $Location" -Level "INFO"
    Write-Log -Message "  SKU: $Sku" -Level "INFO"
    Write-Log -Message "  Retention: $RetentionInDays days" -Level "INFO"

    $workspace = New-AzOperationalInsightsWorkspace `
        -ResourceGroupName $ResourceGroupName `
        -Name $WorkspaceName `
        -Location $Location `
        -Sku $Sku `
        -RetentionInDays $RetentionInDays `
        -Tag $allTags

    Write-Log -Message "Log Analytics Workspace created successfully" -Level "SUCCESS"

    # Get workspace keys for reference
    $keys = Get-AzOperationalInsightsWorkspaceSharedKey `
        -ResourceGroupName $ResourceGroupName `
        -Name $WorkspaceName

    # Output details
    Write-Host ""
    Write-Log -Message "Workspace Details:" -Level "INFO"
    Write-Host "  Name: $($workspace.Name)"
    Write-Host "  Workspace ID: $($workspace.CustomerId)"
    Write-Host "  Location: $($workspace.Location)"
    Write-Host "  SKU: $Sku"
    Write-Host "  Retention: $RetentionInDays days"
    Write-Host ""
    Write-Log -Message "Connection Information (store securely):" -Level "INFO"
    Write-Host "  Workspace ID: $($workspace.CustomerId)"
    Write-Host "  Primary Key: [Available - use Get-AzOperationalInsightsWorkspaceSharedKey]"

    # Return workspace object
    return [PSCustomObject]@{
        Workspace   = $workspace
        WorkspaceId = $workspace.CustomerId
        PrimaryKey  = $keys.PrimarySharedKey
    }
}
catch {
    Write-Log -Message "Failed to create Log Analytics Workspace: $_" -Level "ERROR"
    throw
}
