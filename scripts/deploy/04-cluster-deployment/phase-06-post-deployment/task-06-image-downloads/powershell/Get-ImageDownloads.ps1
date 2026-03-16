<#
.SYNOPSIS
    Downloads required images for Azure Local deployment.

.DESCRIPTION
    This script downloads VM images for Azure Local:
    - Windows Server images
    - Azure Stack HCI marketplace images
    - Custom VM templates
    - Container images

.PARAMETER ImageType
    Type of image to download (WindowsServer, AzureStackHCI, Custom).

.PARAMETER DestinationPath
    Local path to store downloaded images.

.PARAMETER SubscriptionId
    Azure subscription ID.

.EXAMPLE
    .\Get-ImageDownloads.ps1 -ImageType WindowsServer -DestinationPath "D:\Images"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-16-security-configuration/step-03-image-downloads
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('WindowsServer', 'AzureStackHCI', 'Custom', 'All')]
    [string]$ImageType = 'All',

    [Parameter(Mandatory = $false)]
    [string]$DestinationPath = ".\images",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$ListOnly
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts

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

function Get-AvailableMarketplaceImages {
    <#
    .SYNOPSIS
        Gets available marketplace images for Azure Local.
    #>
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$ClusterName
    )

    # Standard Azure Local compatible images
    $images = @(
        @{
            Publisher   = "microsoftwindowsserver"
            Offer       = "windowsserver"
            Sku         = "2022-datacenter-azure-edition-core"
            Version     = "latest"
            DisplayName = "Windows Server 2022 Datacenter: Azure Edition Core"
            Category    = "WindowsServer"
            SizeGB      = 30
        }
        @{
            Publisher   = "microsoftwindowsserver"
            Offer       = "windowsserver"
            Sku         = "2022-datacenter-azure-edition"
            Version     = "latest"
            DisplayName = "Windows Server 2022 Datacenter: Azure Edition"
            Category    = "WindowsServer"
            SizeGB      = 32
        }
        @{
            Publisher   = "microsoftwindowsserver"
            Offer       = "windowsserver"
            Sku         = "2019-datacenter"
            Version     = "latest"
            DisplayName = "Windows Server 2019 Datacenter"
            Category    = "WindowsServer"
            SizeGB      = 30
        }
        @{
            Publisher   = "canonical"
            Offer       = "0001-com-ubuntu-server-jammy"
            Sku         = "22_04-lts"
            Version     = "latest"
            DisplayName = "Ubuntu Server 22.04 LTS"
            Category    = "Linux"
            SizeGB      = 30
        }
    )

    return $images
}

function Start-ImageDownload {
    <#
    .SYNOPSIS
        Initiates image download for Azure Local gallery.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Image,
        [string]$ResourceGroupName,
        [string]$ClusterName,
        [string]$DestinationPath
    )

    Write-LogMessage "  Initiating download: $($Image.DisplayName)" -Level Info

    # For Azure Local, images are downloaded via the Azure portal or CLI
    # This script prepares the commands needed

    $imageName = "$($Image.Offer)-$($Image.Sku)" -replace '[^a-zA-Z0-9-]', '-'
    
    # Generate Az CLI command for image download
    $azCommand = @"
az stack-hci-vm image create `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --custom-location /subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ExtendedLocation/customLocations/$ClusterName-cl `
    --name $imageName `
    --os-type $(if($Image.Category -eq 'Linux'){'Linux'}else{'Windows'}) `
    --image-path "$DestinationPath\$imageName.vhdx"
"@

    return @{
        ImageName   = $imageName
        DisplayName = $Image.DisplayName
        Command     = $azCommand
        Status      = 'CommandGenerated'
    }
}

function Get-ExistingGalleryImages {
    <#
    .SYNOPSIS
        Gets images already in the Azure Local gallery.
    #>
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName
    )

    try {
        # Use Az CLI to list existing images
        $imagesJson = az stack-hci-vm image list --resource-group $ResourceGroupName 2>$null
        if ($imagesJson) {
            return $imagesJson | ConvertFrom-Json
        }
    } catch {
        Write-LogMessage "  Could not retrieve existing images: $_" -Level Warning
    }

    return @()
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Image Download Management" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get values from config if not provided
    if (-not $SubscriptionId -and $config.azure) {
        $SubscriptionId = $config.azure_platform.subscriptions.lab.id
    }
    if (-not $ResourceGroupName -and $config.azure) {
        $ResourceGroupName = $config.azure_platform.resource_group
    }
    if (-not $ClusterName -and $config.cluster) {
        $ClusterName = $config.compute.azure_local.cluster_name
    }

    # Connect to Azure
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }

    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }

    Write-LogMessage "Subscription: $((Get-AzContext).Subscription.Name)" -Level Info

    # Get available images
    Write-LogMessage "Getting available marketplace images..." -Level Info
    $availableImages = Get-AvailableMarketplaceImages -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName

    # Filter by type if specified
    if ($ImageType -ne 'All') {
        $availableImages = $availableImages | Where-Object { $_.Category -eq $ImageType }
    }

    Write-LogMessage "  Found $($availableImages.Count) images" -Level Info

    # List images
    Write-LogMessage "" -Level Info
    Write-LogMessage "Available Images:" -Level Info
    foreach ($image in $availableImages) {
        Write-LogMessage "  - $($image.DisplayName) (~$($image.SizeGB) GB)" -Level Info
    }

    if ($ListOnly) {
        return @{
            AvailableImages = $availableImages
        }
    }

    # Ensure destination path exists
    if (-not (Test-Path $DestinationPath)) {
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
    }

    # Generate download commands
    Write-LogMessage "" -Level Info
    Write-LogMessage "Generating download commands..." -Level Info
    $downloadResults = @()
    
    foreach ($image in $availableImages) {
        $result = Start-ImageDownload `
            -Image $image `
            -ResourceGroupName $ResourceGroupName `
            -ClusterName $ClusterName `
            -DestinationPath $DestinationPath
        
        $downloadResults += $result
    }

    # Save commands to file
    $commandsFile = Join-Path $DestinationPath "download-commands.ps1"
    $commandsContent = @"
# Azure Local Image Download Commands
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# 
# Run these commands to download images to your Azure Local cluster
# Ensure you're logged in with: az login
# And have selected the correct subscription: az account set --subscription "$SubscriptionId"

"@

    foreach ($result in $downloadResults) {
        $commandsContent += @"

# $($result.DisplayName)
$($result.Command)

"@
    }

    Set-Content -Path $commandsFile -Value $commandsContent
    Write-LogMessage "  Commands saved: $commandsFile" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Image Download Setup Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "  Available images: $($availableImages.Count)" -Level Info
    Write-LogMessage "  Commands file: $commandsFile" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "NEXT STEPS:" -Level Warning
    Write-LogMessage "  1. Review the download commands in: $commandsFile" -Level Info
    Write-LogMessage "  2. Ensure Azure CLI is installed and logged in" -Level Info
    Write-LogMessage "  3. Run the commands to download images" -Level Info
    Write-LogMessage "  4. Verify images in Azure Portal > Azure Local > VM Images" -Level Info

    return @{
        AvailableImages = $availableImages
        DownloadResults = $downloadResults
        CommandsFile    = $commandsFile
    }

} catch {
    Write-LogMessage "Image download setup failed: $_" -Level Error
    throw
}

#endregion Main
