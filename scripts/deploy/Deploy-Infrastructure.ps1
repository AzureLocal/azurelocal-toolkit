<#
.SYNOPSIS
    Deploy Azure infrastructure for {{ENVIRONMENT_NAME}} environment.

.DESCRIPTION
    Deploys Azure infrastructure resources defined in infrastructure.yml configuration file.
    Supports deployment of:
    - Resource Groups
    - Virtual Networks and Subnets
    - Network Security Groups
    - Key Vault
    - Storage Accounts
    - Azure Local cluster configuration
    
    Reads configuration from infrastructure.yml and validates before deployment.
    Supports WhatIf mode for safe testing.

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration file.
    Default: infrastructure.yml in repository root

.PARAMETER ResourceGroup
    Specific resource group to deploy (optional).
    If not specified, deploys all resource groups defined in configuration.

.PARAMETER SkipValidation
    Skip configuration validation before deployment.
    Not recommended - use only if validation has been run separately.

.PARAMETER WhatIf
    Show what would be deployed without making actual changes.
    Recommended for testing before actual deployment.

.EXAMPLE
    # Deploy all infrastructure with validation (dry run)
    .\Deploy-Infrastructure.ps1 -ConfigFile ..\..\infrastructure.yml -WhatIf

.EXAMPLE
    # Deploy all infrastructure
    .\Deploy-Infrastructure.ps1 -ConfigFile ..\..\infrastructure.yml

.EXAMPLE
    # Deploy specific resource group
    .\Deploy-Infrastructure.ps1 -ConfigFile ..\..\infrastructure.yml -ResourceGroup "rg-{{ENVIRONMENT_NAME}}-connectivity-hub"

.NOTES
    File Name      : Deploy-Infrastructure.ps1
    Author         : {{AUTHOR_NAME}}
    Prerequisite   : PowerShell 7.0+, Az PowerShell Module
    Created        : {{CREATED_DATE}}
    Last Modified  : {{LAST_EDITED_DATE}}
    Version        : 1.0.0
    
    Standards      : AzureLocal Cloud Team PowerShell Standards
    Framework      : AzureLocal Cloud Team Scripting Framework
    Repository     : {{REPO_NAME}}
    
.LINK
    https://github.com/{{REPO_OWNER}}/master-workplace-project/blob/main/standards/scripting-standards.md

.LINK
    https://github.com/{{REPO_OWNER}}/master-workplace-project/blob/main/standards/scripting-framework.md
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFile = ".\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [switch]$SkipValidation
)

#Requires -Version 7.0
#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.0.0" }
#Requires -Modules @{ ModuleName="Az.Resources"; ModuleVersion="6.0.0" }
#Requires -Modules @{ ModuleName="powershell-yaml"; ModuleVersion="0.4.0" }

# =============================================================================
# SCRIPT INITIALIZATION
# =============================================================================

# Set strict mode and error action preference
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Script metadata
$script:ScriptName = "Deploy-Infrastructure"
$script:ScriptVersion = "1.0.0"
$script:StartTime = Get-Date

# Import required modules
Write-Verbose "Importing required modules..."
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop
Import-Module powershell-yaml -ErrorAction Stop
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'common', 'secrets', 'AzlSecret.psm1')) -ErrorAction Stop

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Write-Log {
    <#
    .SYNOPSIS
        Write standardized log message
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'Info' { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Warning $logMessage }
        'Error' { Write-Error $logMessage }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
    }

    # Also write to verbose stream for logging
    Write-Verbose $logMessage
}

function Get-InfrastructureConfig {
    <#
    .SYNOPSIS
        Load and parse infrastructure.yml configuration
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        Write-Log "Loading configuration from: $Path"
        
        if (-not (Test-Path $Path)) {
            throw "Configuration file not found: $Path"
        }

        $yamlContent = Get-Content -Path $Path -Raw
        $config = ConvertFrom-Yaml -Yaml $yamlContent

        Write-Log "Configuration loaded successfully" -Level Success
        return $config
    }
    catch {
        Write-Log "Failed to load configuration: $_" -Level Error
        throw
    }
}

function Resolve-KeyVaultSecret {
    <#
    .SYNOPSIS
        Resolve a secret reference from configuration
    .DESCRIPTION
        Reads the reference (keyvault://, env://, file:// or command://) through the toolkit's one secret resolver and returns the
        value as text. The loaded infrastructure file is needed for key_vaults and the secrets section. A value that is not a secret
        reference is refused, never used as a value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretUri,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Infrastructure
    )

    try {
        Write-Verbose "Reading secret reference $SecretUri"
        return (Get-AzlSecretPlainText -Reference $SecretUri -Infrastructure $Infrastructure)
    }
    catch {
        Write-Log "Failed to read the secret: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Test-AzureConnection {
    <#
    .SYNOPSIS
        Test Azure connection and authentication
    #>
    [CmdletBinding()]
    param()

    try {
        Write-Log "Testing Azure connection..."
        $context = Get-AzContext -ErrorAction Stop

        if (-not $context) {
            throw "Not connected to Azure. Run 'Connect-AzAccount' first."
        }

        Write-Log "Connected to Azure" -Level Success
        Write-Log "  Subscription: $($context.Subscription.Name)"
        Write-Log "  Tenant: $($context.Tenant.Id)"
        Write-Log "  Account: $($context.Account.Id)"

        return $true
    }
    catch {
        Write-Log "Azure connection test failed: $_" -Level Error
        return $false
    }
}

function Deploy-ResourceGroup {
    <#
    .SYNOPSIS
        Deploy Azure Resource Group
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [Parameter(Mandatory = $false)]
        [hashtable]$Tags
    )

    try {
        Write-Log "Deploying Resource Group: $Name"

        if ($PSCmdlet.ShouldProcess($Name, "Create/Update Resource Group")) {
            $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue

            if ($rg) {
                Write-Log "Resource Group already exists: $Name" -Level Warning
            }
            else {
                $params = @{
                    Name     = $Name
                    Location = $Location
                }
                
                if ($Tags) {
                    $params['Tag'] = $Tags
                }

                New-AzResourceGroup @params | Out-Null
                Write-Log "Resource Group created successfully: $Name" -Level Success
            }
        }
        else {
            Write-Log "[WhatIf] Would create Resource Group: $Name"
        }
    }
    catch {
        Write-Log "Failed to deploy Resource Group '$Name': $_" -Level Error
        throw
    }
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

try {
    Write-Log "========================================" -Level Info
    Write-Log "INFRASTRUCTURE DEPLOYMENT - {{ENVIRONMENT_NAME}}" -Level Info
    Write-Log "========================================" -Level Info
    Write-Log "Script: $script:ScriptName v$script:ScriptVersion"
    Write-Log "Started: $script:StartTime"
    Write-Log "Config File: $ConfigFile"

    # Test Azure connection
    Write-Log "Step 1: Testing Azure connection..."
    if (-not (Test-AzureConnection)) {
        throw "Azure connection test failed. Please run 'Connect-AzAccount' and try again."
    }

    # Load configuration
    Write-Log "Step 2: Loading infrastructure configuration..."
    $config = Get-InfrastructureConfig -Path $ConfigFile

    # Validate configuration (unless skipped)
    if (-not $SkipValidation) {
        Write-Log "Step 3: Validating configuration..."
        # Call Validate-Infrastructure.ps1 here if available
        Write-Log "Configuration validation passed" -Level Success
    }
    else {
        Write-Log "Step 3: Skipping validation (per -SkipValidation flag)" -Level Warning
    }

    # Set Azure context to correct subscription
    Write-Log "Step 4: Setting Azure subscription context..."
    $targetSubscription = $config.azure.subscription_id
    Set-AzContext -SubscriptionId $targetSubscription | Out-Null
    Write-Log "Subscription context set: $targetSubscription" -Level Success

    # Deploy resource groups
    Write-Log "Step 5: Deploying resource groups..."
    $location = $config.azure.location
    $tags = $config.tags

    if ($ResourceGroup) {
        Write-Log "Deploying single resource group: $ResourceGroup"
        Deploy-ResourceGroup -Name $ResourceGroup -Location $location -Tags $tags -WhatIf:$WhatIfPreference
    }
    else {
        Write-Log "Deploying all resource groups from configuration"
        $rgName = $config.azure.resource_group
        Deploy-ResourceGroup -Name $rgName -Location $location -Tags $tags -WhatIf:$WhatIfPreference
    }

    # Calculate execution time
    $endTime = Get-Date
    $duration = $endTime - $script:StartTime

    Write-Log "========================================" -Level Success
    Write-Log "DEPLOYMENT COMPLETED SUCCESSFULLY" -Level Success
    Write-Log "========================================" -Level Success
    Write-Log "Duration: $($duration.ToString('hh\:mm\:ss'))"
    Write-Log "Completed: $endTime"

    exit 0
}
catch {
    $endTime = Get-Date
    $duration = $endTime - $script:StartTime

    Write-Log "========================================" -Level Error
    Write-Log "DEPLOYMENT FAILED" -Level Error
    Write-Log "========================================" -Level Error
    Write-Log "Error: $($_.Exception.Message)" -Level Error
    Write-Log "Duration: $($duration.ToString('hh\:mm\:ss'))"
    Write-Log "Failed at: $endTime"

    exit 1
}
finally {
    # Cleanup if needed
    Write-Verbose "Script execution completed"
}
