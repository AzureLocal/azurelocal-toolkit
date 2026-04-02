<#
.SYNOPSIS
    Creates Azure resource groups defined in solution configuration.

.DESCRIPTION
    Creates all resource groups defined in the azure_infrastructure.resource_groups
    section of the solution configuration. Applies standard tags from the tags
    section of the configuration.

.PARAMETER Solution
    The solution name (e.g., "azure-local").

.PARAMETER ResourceGroupFilter
    Optional. Filter to create only specific resource groups.
    Valid values: "management", "compute", "storage", "network", "arc", "all".
    Defaults to "all".

.PARAMETER SkipExisting
    If specified, skips resource groups that already exist without error.

.EXAMPLE
    # Create all resource groups for a solution
    .\New-ResourceGroups.ps1 -Solution "azure-local"

.EXAMPLE
    # Create only management and compute resource groups
    .\New-ResourceGroups.ps1 -Solution "azure-local" -ResourceGroupFilter "management"

.NOTES
    Requires:
    - Az.Resources module
    - Contributor or higher on target subscription
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [ValidateSet("management", "compute", "storage", "network", "arc", "all")]
    [string]$ResourceGroupFilter = "all",

    [Parameter(Mandatory = $false)]
    [switch]$SkipExisting
)

# Import required modules
. (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "utilities\helpers\config-loader.ps1")

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
Write-Host "`n[1/3] Loading solution configuration..." -ForegroundColor Cyan
$config = Get-SolutionConfig -Solution $Solution

# Validate required configuration paths
$validation = Test-ConfigPaths -Config $config
if (-not $validation.IsValid) {
    throw "Missing required configuration paths: $($validation.MissingPaths -join ', ')"
}

# Extract configuration values
$tenantId = Get-ConfigValue -Config $config -Path 'azure.tenant.id'
$subscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscription.id'
$solutionName = Get-ConfigValue -Config $config -Path 'solution.name'
$location = Get-ConfigValue -Config $config -Path 'azure.location'
$tags = Get-ConfigTags -Config $config

# Get resource group configurations
$resourceGroups = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups'
if (-not $resourceGroups) {
    throw "No resource groups defined in configuration at path: azure_infrastructure.resource_groups"
}

Write-Host "  Solution: $solutionName" -ForegroundColor Gray
Write-Host "  Location: $location" -ForegroundColor Gray
Write-Host "  Filter: $ResourceGroupFilter" -ForegroundColor Gray

# ============================================================================
# AZURE CONNECTION
# ============================================================================
Write-Host "`n[2/3] Connecting to Azure..." -ForegroundColor Cyan

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context -or $context.Subscription.Id -ne $subscriptionId) {
    Connect-AzAccount -TenantId $tenantId -SubscriptionId $subscriptionId
}
$context = Get-AzContext
Write-Host "  Connected as: $($context.Account.Id)" -ForegroundColor Green

# ============================================================================
# CREATE RESOURCE GROUPS
# ============================================================================
Write-Host "`n[3/3] Creating resource groups..." -ForegroundColor Cyan

$createdRgs = @()
$skippedRgs = @()
$failedRgs = @()

# Build list of resource groups to create
$rgTypes = if ($ResourceGroupFilter -eq "all") {
    @("management", "compute", "storage", "network", "arc")
} else {
    @($ResourceGroupFilter)
}

foreach ($rgType in $rgTypes) {
    $rgConfig = Get-ConfigValue -Config $config -Path "azure_infrastructure.resource_groups.$rgType"
    
    if (-not $rgConfig) {
        Write-Host "  No '$rgType' resource group defined in config" -ForegroundColor Gray
        continue
    }
    
    $rgName = $rgConfig.name
    $rgLocation = if ($rgConfig.location) { $rgConfig.location } else { $location }
    
    Write-Host "`n  Processing: $rgName ($rgType)..." -ForegroundColor Yellow
    
    # Check if already exists
    $existingRg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    
    if ($existingRg) {
        if ($SkipExisting) {
            Write-Host "    Already exists (skipped)" -ForegroundColor Yellow
            $skippedRgs += $rgName
        } else {
            Write-Host "    Already exists" -ForegroundColor Yellow
            # Update tags if needed
            if ($PSCmdlet.ShouldProcess($rgName, "Update resource group tags")) {
                $existingRg | Set-AzResourceGroup -Tag $tags | Out-Null
                Write-Host "    Updated tags" -ForegroundColor Green
            }
            $createdRgs += $existingRg
        }
    } else {
        if ($PSCmdlet.ShouldProcess($rgName, "Create resource group")) {
            try {
                $newRg = New-AzResourceGroup -Name $rgName -Location $rgLocation -Tag $tags
                Write-Host "    Created: $rgName" -ForegroundColor Green
                $createdRgs += $newRg
            }
            catch {
                Write-Error "    Failed to create $rgName : $_"
                $failedRgs += $rgName
            }
        }
    }
}

# ============================================================================
# OUTPUT
# ============================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Resource Group Creation Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Created/Updated: $($createdRgs.Count)"
Write-Host "Skipped: $($skippedRgs.Count)"
Write-Host "Failed: $($failedRgs.Count)"
Write-Host ""

if ($createdRgs.Count -gt 0) {
    Write-Host "Resource Groups:" -ForegroundColor Yellow
    foreach ($rg in $createdRgs) {
        Write-Host "  - $($rg.ResourceGroupName) ($($rg.Location))"
    }
}

if ($failedRgs.Count -gt 0) {
    Write-Host "`nFailed Resource Groups:" -ForegroundColor Red
    foreach ($rg in $failedRgs) {
        Write-Host "  - $rg"
    }
}

Write-Host ""

# Return created resource groups
return $createdRgs
