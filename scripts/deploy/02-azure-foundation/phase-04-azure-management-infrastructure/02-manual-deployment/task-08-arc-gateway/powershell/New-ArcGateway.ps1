<#
.SYNOPSIS
    Creates an Azure Arc Gateway for Azure Local hybrid connectivity.

.DESCRIPTION
    This script creates an Azure Arc Gateway resource that enables hybrid 
    connectivity for Azure Local clusters. The Arc Gateway provides secure 
    outbound connectivity for Arc-enabled resources.

.PARAMETER ArcGatewayName
    Name of the Arc Gateway.

.PARAMETER ResourceGroupName
    Name of the resource group.

.PARAMETER Location
    Azure region. Default: eastus

.PARAMETER SubscriptionId
    Azure subscription ID. Uses current context if not specified.

.EXAMPLE
    .\New-ArcGateway.ps1 -ArcGatewayName "arcgw-azl-prd-eus" -ResourceGroupName "rg-azlmgmt-prd-eus-01"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Arc Gateway is currently in preview. Check Microsoft documentation for 
    latest availability and limitations.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArcGatewayName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [hashtable]$Tags = @{}
)

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
    Write-Log -Message "Starting Azure Arc Gateway Creation" -Level "INFO"
    Write-Log -Message "Arc Gateway Name: $ArcGatewayName" -Level "INFO"

    # Set subscription context if provided
    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }
    $context = Get-AzContext

    # Build tags
    $defaultTags = @{
        "Environment"  = "Production"
        "Application"  = "Azure Local"
        "ManagedBy"    = "Azure Local Cloud"
        "CreatedDate"  = (Get-Date -Format "yyyy-MM-dd")
    }
    $allTags = $defaultTags + $Tags

    # Convert tags to format for REST API
    $tagObject = @{}
    foreach ($key in $allTags.Keys) {
        $tagObject[$key] = $allTags[$key]
    }

    # Arc Gateway uses REST API as it may not have full PowerShell module support
    $apiVersion = "2024-06-01-preview"
    $resourceId = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/gateways/$ArcGatewayName"
    
    # Check if Arc Gateway already exists
    Write-Log -Message "Checking for existing Arc Gateway..." -Level "INFO"
    
    try {
        $existingGateway = Invoke-AzRestMethod -Path "$resourceId`?api-version=$apiVersion" -Method GET
        if ($existingGateway.StatusCode -eq 200) {
            $gatewayData = $existingGateway.Content | ConvertFrom-Json
            Write-Log -Message "Arc Gateway '$ArcGatewayName' already exists" -Level "WARN"
            Write-Log -Message "  Resource ID: $($gatewayData.id)" -Level "INFO"
            Write-Log -Message "  Gateway ID: $($gatewayData.properties.gatewayId)" -Level "INFO"
            return $gatewayData
        }
    }
    catch {
        # Gateway doesn't exist, continue with creation
    }

    # Create Arc Gateway
    Write-Log -Message "Creating Arc Gateway..." -Level "INFO"
    Write-Log -Message "  Location: $Location" -Level "INFO"
    Write-Log -Message "  Resource Group: $ResourceGroupName" -Level "INFO"

    $body = @{
        location   = $Location
        properties = @{
            gatewayType = "Public"
        }
        tags       = $tagObject
    } | ConvertTo-Json -Depth 10

    $response = Invoke-AzRestMethod `
        -Path "$resourceId`?api-version=$apiVersion" `
        -Method PUT `
        -Payload $body

    if ($response.StatusCode -notin @(200, 201, 202)) {
        $errorContent = $response.Content | ConvertFrom-Json
        throw "Failed to create Arc Gateway: $($errorContent.error.message)"
    }

    $gateway = $response.Content | ConvertFrom-Json

    Write-Log -Message "Arc Gateway creation initiated" -Level "SUCCESS"

    # Wait for provisioning if needed
    if ($gateway.properties.provisioningState -eq "Creating") {
        Write-Log -Message "Waiting for Arc Gateway provisioning to complete..." -Level "INFO"
        
        $maxWaitMinutes = 10
        $startTime = Get-Date
        $timeout = $startTime.AddMinutes($maxWaitMinutes)

        while ((Get-Date) -lt $timeout) {
            Start-Sleep -Seconds 30
            
            $checkResponse = Invoke-AzRestMethod -Path "$resourceId`?api-version=$apiVersion" -Method GET
            $checkGateway = $checkResponse.Content | ConvertFrom-Json
            
            if ($checkGateway.properties.provisioningState -eq "Succeeded") {
                $gateway = $checkGateway
                break
            }
            elseif ($checkGateway.properties.provisioningState -eq "Failed") {
                throw "Arc Gateway provisioning failed"
            }
            
            Write-Log -Message "Provisioning state: $($checkGateway.properties.provisioningState)" -Level "INFO"
        }
    }

    # Output details
    Write-Host ""
    Write-Log -Message "Arc Gateway Details:" -Level "INFO"
    Write-Host "  Name: $ArcGatewayName"
    Write-Host "  Resource ID: $($gateway.id)"
    Write-Host "  Gateway ID: $($gateway.properties.gatewayId)"
    Write-Host "  Gateway Type: $($gateway.properties.gatewayType)"
    Write-Host "  Provisioning State: $($gateway.properties.provisioningState)"
    Write-Host ""
    Write-Log -Message "Use this Gateway ID when configuring Azure Arc agents:" -Level "INFO"
    Write-Host "  $($gateway.properties.gatewayId)"

    return $gateway
}
catch {
    Write-Log -Message "Failed to create Arc Gateway: $_" -Level "ERROR"
    throw
}
