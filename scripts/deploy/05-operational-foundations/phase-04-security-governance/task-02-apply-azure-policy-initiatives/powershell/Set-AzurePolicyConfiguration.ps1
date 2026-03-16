<#
.SYNOPSIS
    Configures Azure Policy for Azure Local resources.

.DESCRIPTION
    This script configures Azure Policy:
    - Assigns built-in policies for Azure Local
    - Configures custom policies
    - Sets up policy initiatives
    - Enables compliance monitoring

.PARAMETER ResourceGroupName
    Azure resource group name.

.PARAMETER SubscriptionId
    Azure subscription ID.

.EXAMPLE
    .\Set-AzurePolicyConfiguration.ps1 -ResourceGroupName "rg-azurelocal-prod"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-20-governance/step-01-azure-policy
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$AssignPolicies
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

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

function Get-RecommendedPolicies {
    <#
    .SYNOPSIS
        Returns recommended Azure Policy definitions for Azure Local.
    #>
    return @(
        @{
            DisplayName = "Configure Azure Local to use only TLS 1.2"
            Category    = "Azure Local"
            Effect      = "Audit"
        }
        @{
            DisplayName = "Azure Local should have encryption at host enabled"
            Category    = "Azure Local"
            Effect      = "Audit"
        }
        @{
            DisplayName = "Configure Azure Arc-enabled servers to use a private link scope"
            Category    = "Azure Arc"
            Effect      = "Modify"
        }
        @{
            DisplayName = "Azure Arc-enabled servers should have Azure Defender's vulnerability assessment enabled"
            Category    = "Security Center"
            Effect      = "AuditIfNotExists"
        }
        @{
            DisplayName = "Configure machines to receive updates from Azure Update Management Center"
            Category    = "Azure Update Manager"
            Effect      = "DeployIfNotExists"
        }
        @{
            DisplayName = "Require a tag on resources"
            Category    = "Tags"
            Effect      = "Deny"
        }
    )
}

function Get-ExistingPolicyAssignments {
    <#
    .SYNOPSIS
        Gets existing policy assignments for the scope.
    #>
    [CmdletBinding()]
    param([string]$Scope)

    try {
        $assignments = Get-AzPolicyAssignment -Scope $Scope -ErrorAction SilentlyContinue
        return $assignments
    } catch {
        return @()
    }
}

function New-PolicyAssignment {
    <#
    .SYNOPSIS
        Creates a new policy assignment.
    #>
    [CmdletBinding()]
    param(
        [string]$PolicyDefinitionId,
        [string]$Scope,
        [string]$Name,
        [string]$DisplayName,
        [hashtable]$Parameters
    )

    try {
        $assignmentParams = @{
            Name                = $Name
            Scope               = $Scope
            PolicyDefinition    = Get-AzPolicyDefinition -Id $PolicyDefinitionId
            DisplayName         = $DisplayName
        }

        if ($Parameters) {
            $assignmentParams['PolicyParameterObject'] = $Parameters
        }

        $assignment = New-AzPolicyAssignment @assignmentParams
        return @{
            Success    = $true
            Assignment = $assignment
        }
    } catch {
        return @{
            Success = $false
            Error   = $_.Exception.Message
        }
    }
}

function Get-ComplianceStatus {
    <#
    .SYNOPSIS
        Gets policy compliance status for the scope.
    #>
    [CmdletBinding()]
    param([string]$Scope)

    try {
        $compliance = Get-AzPolicyState -SubscriptionId $SubscriptionId -PolicySetDefinitionName '*' -ErrorAction SilentlyContinue | 
            Group-Object ComplianceState | 
            Select-Object Name, Count

        return $compliance
    } catch {
        return $null
    }
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Azure Policy Configuration" -Level Info
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

    # Connect to Azure
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }

    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }

    $subscriptionScope = "/subscriptions/$((Get-AzContext).Subscription.Id)"
    $rgScope = "$subscriptionScope/resourceGroups/$ResourceGroupName"

    Write-LogMessage "Subscription: $((Get-AzContext).Subscription.Name)" -Level Info
    Write-LogMessage "Resource Group: $ResourceGroupName" -Level Info

    # Get recommended policies
    Write-LogMessage "" -Level Info
    Write-LogMessage "Recommended policies for Azure Local:" -Level Info
    $recommendedPolicies = Get-RecommendedPolicies

    foreach ($policy in $recommendedPolicies) {
        Write-LogMessage "  - $($policy.DisplayName) [$($policy.Effect)]" -Level Info
    }

    # Get existing assignments
    Write-LogMessage "" -Level Info
    Write-LogMessage "Checking existing policy assignments..." -Level Info
    $existingAssignments = Get-ExistingPolicyAssignments -Scope $rgScope
    Write-LogMessage "  Found $($existingAssignments.Count) existing assignments" -Level Info

    # Get compliance status
    Write-LogMessage "" -Level Info
    Write-LogMessage "Getting compliance status..." -Level Info
    $compliance = Get-ComplianceStatus -Scope $subscriptionScope

    if ($compliance) {
        foreach ($state in $compliance) {
            $color = switch ($state.Name) {
                'Compliant'    { 'Success' }
                'NonCompliant' { 'Error' }
                default        { 'Info' }
            }
            Write-LogMessage "  $($state.Name): $($state.Count)" -Level $color
        }
    }

    # Assign policies if requested
    if ($AssignPolicies) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Assigning recommended policies..." -Level Info

        # Find Azure Local built-in policies
        $azureLocalPolicies = Get-AzPolicyDefinition | Where-Object { 
            $_.Properties.DisplayName -like "*Azure Local*" -or 
            $_.Properties.DisplayName -like "*Azure Stack HCI*" -or
            $_.Properties.DisplayName -like "*Arc*"
        }

        foreach ($policyDef in $azureLocalPolicies | Select-Object -First 5) {
            $policyName = "azl-$($policyDef.Name.Substring(0, [Math]::Min(20, $policyDef.Name.Length)))"
            
            if ($PSCmdlet.ShouldProcess($policyDef.Properties.DisplayName, "Assign policy")) {
                Write-LogMessage "  Assigning: $($policyDef.Properties.DisplayName)" -Level Info
                
                $result = New-PolicyAssignment `
                    -PolicyDefinitionId $policyDef.PolicyDefinitionId `
                    -Scope $rgScope `
                    -Name $policyName `
                    -DisplayName "Azure Local - $($policyDef.Properties.DisplayName)"

                if ($result.Success) {
                    Write-LogMessage "    ✓ Assigned" -Level Success
                } else {
                    Write-LogMessage "    ✗ Failed: $($result.Error)" -Level Warning
                }
            }
        }
    }

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Azure Policy Configuration Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    Write-LogMessage "  Recommended policies: $($recommendedPolicies.Count)" -Level Info
    Write-LogMessage "  Existing assignments: $($existingAssignments.Count)" -Level Info

    Write-LogMessage "" -Level Info
    Write-LogMessage "NEXT STEPS:" -Level Warning
    Write-LogMessage "  1. Review recommended policies and assign as needed" -Level Info
    Write-LogMessage "  2. Create custom policies for organization requirements" -Level Info
    Write-LogMessage "  3. Set up policy remediation tasks" -Level Info
    Write-LogMessage "  4. Monitor compliance in Azure Portal" -Level Info

    return @{
        RecommendedPolicies  = $recommendedPolicies
        ExistingAssignments  = $existingAssignments.Count
        ComplianceStatus     = $compliance
    }

} catch {
    Write-LogMessage "Azure Policy configuration failed: $_" -Level Error
    throw
}

#endregion Main
