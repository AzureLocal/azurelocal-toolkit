<#
.SYNOPSIS
    Retrieves Azure tenant information.

.DESCRIPTION
    Discovers Azure tenant details including subscriptions, resource groups,
    and key resources. Useful for pre-deployment discovery and validation.

.PARAMETER TenantId
    The Azure AD/Entra ID Tenant ID.

.PARAMETER OutputPath
    Optional. Path to save output as JSON.

.EXAMPLE
    .\Get-TenantInfo.ps1 -TenantId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\Get-TenantInfo.ps1 -TenantId "00000000-0000-0000-0000-000000000000" -OutputPath "tenant-info.json"

.NOTES
    Requires Az PowerShell module and authenticated session.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# Import shared utilities
$scriptRoot = Split-Path -Parent $PSScriptRoot
. "$scriptRoot\utilities\helpers\logging.ps1"

Write-Log -Level Info -Message "Starting tenant discovery for: $TenantId"

try {
    # Check Az module
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Log -Level Error -Message "Az.Accounts module not found. Install with: Install-Module Az -Scope CurrentUser"
        exit 1
    }

    # Connect if not already connected
    $context = Get-AzContext
    if (-not $context -or $context.Tenant.Id -ne $TenantId) {
        Write-Log -Level Info -Message "Connecting to Azure..."
        Connect-AzAccount -TenantId $TenantId
    }

    # Gather tenant info
    $tenantInfo = @{
        TenantId = $TenantId
        DiscoveryDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Subscriptions = @()
    }

    # Get subscriptions
    $subscriptions = Get-AzSubscription -TenantId $TenantId
    Write-Log -Level Info -Message "Found $($subscriptions.Count) subscription(s)"

    foreach ($sub in $subscriptions) {
        Set-AzContext -SubscriptionId $sub.Id | Out-Null
        
        $subInfo = @{
            Id = $sub.Id
            Name = $sub.Name
            State = $sub.State
            ResourceGroups = @()
        }

        # Get resource groups
        $resourceGroups = Get-AzResourceGroup
        foreach ($rg in $resourceGroups) {
            $subInfo.ResourceGroups += @{
                Name = $rg.ResourceGroupName
                Location = $rg.Location
                Tags = $rg.Tags
            }
        }

        $tenantInfo.Subscriptions += $subInfo
    }

    # Output results
    $output = $tenantInfo | ConvertTo-Json -Depth 10

    if ($OutputPath) {
        $output | Set-Content -Path $OutputPath
        Write-Log -Level Info -Message "Output saved to: $OutputPath"
    } else {
        Write-Output $output
    }

    Write-Log -Level Info -Message "Tenant discovery complete"
}
catch {
    Write-Log -Level Error -Message "Discovery failed: $_"
    throw
}
