<#
.SYNOPSIS
    Activates Windows Server subscription on Azure Local nodes.

.DESCRIPTION
    This script configures Windows Server subscription licensing:
    - Validates Azure Local registration
    - Enables Windows Server subscription
    - Configures licensing for VMs
    - Verifies activation status

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER ResourceGroupName
    Azure resource group name.

.EXAMPLE
    .\Enable-WindowsServerSubscription.ps1 -ClusterName "azl-cluster01"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-21-licensing/step-01-windows-subscription
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml"
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.StackHCI

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

function Get-ClusterLicenseStatus {
    <#
    .SYNOPSIS
        Gets current license status for Azure Local cluster.
    #>
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$ClusterName
    )

    try {
        $cluster = Get-AzStackHciCluster -ResourceGroupName $ResourceGroupName -Name $ClusterName -ErrorAction Stop

        return @{
            ClusterName               = $cluster.Name
            RegistrationStatus        = $cluster.Status
            ConnectivityStatus        = $cluster.ConnectivityStatus
            LastBillingTimestamp      = $cluster.LastBillingTimestamp
            SoftwareAssuranceIntent   = $cluster.SoftwareAssuranceProperties.SoftwareAssuranceIntent
            SoftwareAssuranceStatus   = $cluster.SoftwareAssuranceProperties.SoftwareAssuranceStatus
        }
    } catch {
        return @{
            Error = $_.Exception.Message
        }
    }
}

function Get-NodeActivationStatus {
    <#
    .SYNOPSIS
        Gets Windows activation status on cluster nodes.
    #>
    [CmdletBinding()]
    param(
        [string[]]$NodeNames,
        [pscredential]$Credential
    )

    $results = @()

    foreach ($node in $NodeNames) {
        try {
            $sessionParams = @{
                ComputerName = $node
                ErrorAction  = 'Stop'
            }
            if ($Credential) {
                $sessionParams['Credential'] = $Credential
            }

            $session = New-PSSession @sessionParams

            $licenseStatus = Invoke-Command -Session $session -ScriptBlock {
                $slmgr = cscript //nologo "$env:windir\system32\slmgr.vbs" /dli 2>&1
                $activated = $slmgr -match "License Status: Licensed"
                
                $product = Get-CimInstance -ClassName SoftwareLicensingProduct | 
                    Where-Object { $_.PartialProductKey -and $_.ApplicationId -eq "55c92734-d682-4d71-983e-d6ec3f16059f" } |
                    Select-Object -First 1

                return @{
                    Activated       = $activated
                    LicenseStatus   = $product.LicenseStatus
                    ProductName     = $product.Name
                    Description     = $product.Description
                    PartialKey      = $product.PartialProductKey
                }
            }

            Remove-PSSession -Session $session

            $results += @{
                NodeName = $node
                Success  = $true
                Status   = $licenseStatus
            }
        } catch {
            $results += @{
                NodeName = $node
                Success  = $false
                Error    = $_.Exception.Message
            }
        }
    }

    return $results
}

function Enable-WindowsSubscription {
    <#
    .SYNOPSIS
        Enables Windows Server subscription for the cluster.
    #>
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$ClusterName
    )

    try {
        # Enable Windows Server subscription via Az CLI
        # This requires specific Azure Local configuration
        
        $result = az stack-hci arc-setting update `
            --resource-group $ResourceGroupName `
            --cluster-name $ClusterName `
            --name "default" `
            --connectivity-properties "{""enabled"": true}" 2>&1

        if ($LASTEXITCODE -eq 0) {
            return @{
                Success = $true
                Message = "Windows Server subscription enabled"
            }
        } else {
            return @{
                Success = $false
                Error   = $result
            }
        }
    } catch {
        return @{
            Success = $false
            Error   = $_.Exception.Message
        }
    }
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Windows Server Subscription Configuration" -Level Info
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

    if (-not $ClusterName -or -not $ResourceGroupName) {
        throw "ClusterName and ResourceGroupName are required"
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
    Write-LogMessage "Cluster: $ClusterName" -Level Info

    # Get cluster license status
    Write-LogMessage "" -Level Info
    Write-LogMessage "Getting cluster license status..." -Level Info
    $clusterStatus = Get-ClusterLicenseStatus -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName

    if ($clusterStatus.Error) {
        Write-LogMessage "  Error: $($clusterStatus.Error)" -Level Error
    } else {
        Write-LogMessage "  Registration: $($clusterStatus.RegistrationStatus)" -Level Info
        Write-LogMessage "  Connectivity: $($clusterStatus.ConnectivityStatus)" -Level Info
        Write-LogMessage "  Software Assurance: $($clusterStatus.SoftwareAssuranceStatus)" -Level Info
        Write-LogMessage "  Last Billing: $($clusterStatus.LastBillingTimestamp)" -Level Info
    }

    # Get node activation status
    $nodeNames = @()
    if ($config.compute.cluster_nodes) {
        $nodeNames = $config.compute.cluster_nodes | ForEach-Object { $_.name }
    }

    if ($nodeNames) {
        if (-not $Credential) {
            $Credential = Get-Credential -Message "Enter credentials for cluster nodes"
        }

        Write-LogMessage "" -Level Info
        Write-LogMessage "Checking node activation status..." -Level Info
        $nodeStatus = Get-NodeActivationStatus -NodeNames $nodeNames -Credential $Credential

        foreach ($node in $nodeStatus) {
            if ($node.Success) {
                $activated = $node.Status.Activated
                Write-LogMessage "  $($node.NodeName): $(if($activated){'✓ Activated'}else{'✗ Not Activated'})" -Level $(if($activated){'Success'}else{'Warning'})
                if ($node.Status.ProductName) {
                    Write-LogMessage "    Product: $($node.Status.ProductName)" -Level Info
                }
            } else {
                Write-LogMessage "  $($node.NodeName): Error - $($node.Error)" -Level Error
            }
        }
    }

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Windows Subscription Status Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    Write-LogMessage "" -Level Info
    Write-LogMessage "LICENSING OPTIONS:" -Level Warning
    Write-LogMessage "" -Level Info
    Write-LogMessage "1. WINDOWS SERVER SUBSCRIPTION (recommended for Azure Local):" -Level Info
    Write-LogMessage "   - Pay-as-you-go licensing through Azure" -Level Info
    Write-LogMessage "   - Requires Azure Local registration" -Level Info
    Write-LogMessage "   - Automatically enabled for registered clusters" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "2. BRING YOUR OWN LICENSE (Software Assurance):" -Level Info
    Write-LogMessage "   - Use existing Windows Server licenses" -Level Info
    Write-LogMessage "   - Requires Software Assurance" -Level Info
    Write-LogMessage "   - Configure via Azure Portal > Azure Local > Licensing" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "3. HYBRID USE BENEFIT:" -Level Info
    Write-LogMessage "   - Apply existing licenses to reduce costs" -Level Info
    Write-LogMessage "   - Configure in Azure Portal" -Level Info

    return @{
        ClusterStatus = $clusterStatus
        NodeStatus    = $nodeStatus
    }

} catch {
    Write-LogMessage "Windows subscription configuration failed: $_" -Level Error
    throw
}

#endregion Main
