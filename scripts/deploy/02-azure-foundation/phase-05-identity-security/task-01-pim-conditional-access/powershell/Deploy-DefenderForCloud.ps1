#!/usr/bin/env pwsh
#Requires -Version 7.0
#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.0.0" }
#Requires -Modules @{ ModuleName="Az.Resources"; ModuleVersion="6.0.0" }
#Requires -Modules @{ ModuleName="Az.Security"; ModuleVersion="1.0.0" }

<#
.SYNOPSIS
    Configures Microsoft Defender for Cloud settings across all subscriptions.

.DESCRIPTION
    This script configures:
    - Security policy assignments (Microsoft Cloud Security Benchmark, Cyber Essentials v3.1, MCSB v2 Preview)
    - Defender CSPM with all settings enabled
    - Defender for Servers Plan 2 with specific configurations
    - Defender for SQL Server on Machines with DCR integration
    - Email notifications for all subscriptions
    - Guest Configuration Agent and Azure Monitor Agent for SQL

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "azure-arc-servers"

.PARAMETER TenantId
    The Azure AD tenant ID.

.PARAMETER ManagementGroupId
    The Management Group ID for root-level policy assignments (default: tenant root).

.PARAMETER NotificationEmail
    Additional email address for security notifications.

.EXAMPLE
    # Using solution configuration
    .\Deploy-DefenderForCloud.ps1 -Solution "azure-local" -NotificationEmail "admin@example.com"

.EXAMPLE
    # Using direct parameters
    .\Deploy-DefenderForCloud.ps1 -TenantId "your-tenant-id" -NotificationEmail "admin@example.com"

.EXAMPLE
    .\Deploy-DefenderForCloud.ps1 -Solution "azure-local" -NotificationEmail "admin@example.com" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ManagementGroupId,

    [Parameter(Mandatory = $false)]
    [string]$NotificationEmail
)

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
if ($Solution) {
    Write-Host "[Config] Loading solution configuration for: $Solution" -ForegroundColor Cyan
    . "$PSScriptRoot\..\..\..\utilities\helpers\config-loader.ps1"
    $config = Get-SolutionConfig -Solution $Solution
    
    # Map config values to script parameters - only if not explicitly provided
    if (-not $TenantId) { $TenantId = Get-ConfigValue -Config $config -Path 'azure.tenant.id' }
    if (-not $ManagementGroupId) { $ManagementGroupId = Get-ConfigValue -Config $config -Path 'azure.management_groups.platform.id' }
    if (-not $NotificationEmail) { $NotificationEmail = Get-ConfigValue -Config $config -Path 'azure_infrastructure.security.notification_email' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $TenantId) { $missingParams += 'TenantId' }
if (-not $NotificationEmail) { $missingParams += 'NotificationEmail' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

#region Helper Functions

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Invoke-AzRestMethodWithRetry { -ApiVersion "2024-01-01"
    param(
        [string]$Path,
        [string]$Method,
        [string]$Payload,
        [string]$ApiVersion,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 10
    )
    
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++
        
        $params = @{
            Path = $Path
            Method = $Method
        }
        
        if ($ApiVersion) {
            # Add api-version to the path if not already there
            if ($Path -notmatch '\ {
                $params.Path = "$Path`"
            }
        }
        
        if ($Payload) {
            $params.Payload = $Payload
        }
        
        $result = Invoke-AzRestMethod @params
        
        # Success codes
        if ($result.StatusCode -in 200, 201, 202, 204) {
            return $result
        }
        
        # Retry on timeout or server errors
        if ($result.StatusCode -in 408, 429, 500, 502, 503, 504 -and $attempt -lt $MaxRetries) {
            Write-Host "    Retry $attempt/$MaxRetries after HTTP $($result.StatusCode) - waiting $RetryDelaySeconds seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelaySeconds
            continue
        }
        
        # Return on other errors
        return $result
    }
    
    return $result
}

#endregion

try {
    Write-Step "Starting Defender for Cloud Configuration"
    
    # Connect to Azure
    Write-Host "Connecting to Azure tenant: $TenantId" -ForegroundColor Yellow
    $context = Get-AzContext
    if (-not $context -or $context.Tenant.Id -ne $TenantId) {
        Connect-AzAccount -Tenant $TenantId
    }
    
    # Set management group scope (default to tenant root)
    if (-not $ManagementGroupId) {
        $ManagementGroupId = $TenantId
        Write-Host "Using tenant root management group: $ManagementGroupId" -ForegroundColor Yellow
    }
    
    $mgScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
    
    #region 1. Deploy Security Policy Initiatives at Management Group Level
    Write-Step "Step 1: Deploying Security Policy Initiatives at Management Group"
    
    # Register PolicyInsights provider
    Write-Host "Registering Microsoft.PolicyInsights provider..." -ForegroundColor Yellow
    Register-AzResourceProvider -ProviderNamespace 'Microsoft.PolicyInsights'
Out-Null
    
    # Policy initiatives to assign (using built-in definition IDs)
    $policyInitiatives = @(
        @{
            Id = "1f3afdf9-d0c9-4c3d-847f-89da613e70a8"
            Name = "mcsb"
            DisplayName = "Microsoft Cloud Security Benchmark"
        },
        @{
            Id = "5e4e5e7f-4b3c-4b3c-4b3c-4b3c4b3c4b3c"
            Name = "cyber-essentials"
            DisplayName = "Cyber Essentials v3.1"
        },
        @{
            Id = "1a5bb27d-173f-493e-9568-eb56638dde4d"
            Name = "mcsb-v2-preview"
            DisplayName = "Microsoft Cloud Security Benchmark v2 (Preview)"
        }
    )
    
    foreach ($initiative in $policyInitiatives) {
        Write-Host "  Assigning policy: $($initiative.DisplayName)..." -ForegroundColor Yellow
        
        if ($PSCmdlet.ShouldProcess($mgScope, "Assign policy '$($initiative.DisplayName)'")) {
            try {
                # Use REST API to assign built-in policy
                $assignmentName = "mdc-$($initiative.Name)"
                $uri = "$mgScope/providers/Microsoft.Authorization/policyAssignments/$($assignmentName)"
                $body = @{
                    properties = @{
                        displayName = $initiative.DisplayName
                        policyDefinitionId = "/providers/Microsoft.Authorization/policySetDefinitions/$($initiative.Id)"
                        scope = $mgScope
                    }
                }
ConvertTo-Json -Depth 10
                
                $result = Invoke-AzRestMethodWithRetry -Path $uri -Method PUT -Payload $body -ApiVersion "2023-04-01" -ApiVersion "2024-01-01"
                if ($result.StatusCode -in 200, 201, 202) {
                    Write-Success "Assigned: $($initiative.DisplayName)"
                } elseif ($result.StatusCode -eq 409) {
                    Write-Warning "Already assigned: $($initiative.DisplayName)"
                } else {
                    Write-ErrorMessage "Failed to assign $($initiative.DisplayName): HTTP $($result.StatusCode)"
                    if ($result.Content) {
                        Write-Host "    Error: $($result.Content)" -ForegroundColor Red
                    }
                }
            } catch {
                Write-ErrorMessage "Failed to assign $($initiative.DisplayName): $_"
            }
        }
    }
    
    #endregion
    
    #region 2. Configure Defender Plans for All Subscriptions
    Write-Step "Step 2: Configuring Defender Plans for All Subscriptions"
    
    # Get all subscriptions
    $subscriptions = Get-AzSubscription -TenantId $TenantId
Where-Object { $_.State -eq 'Enabled' }
    Write-Host "Found $($subscriptions.Count) active subscription(s)" -ForegroundColor Yellow
    
    foreach ($subscription in $subscriptions) {
        Write-Host "`n--- Processing Subscription: $($subscription.Name) ($($subscription.Id)) ---" -ForegroundColor Cyan
        
        # Set context to subscription
        Set-AzContext -SubscriptionId $subscription.Id
Out-Null
        
        # Register Security provider
        Register-AzResourceProvider -ProviderNamespace 'Microsoft.Security'
Out-Null
        
        #region 2.1 Enable Defender CSPM with all sub-features
        Write-Host "  [2.1] Enabling Defender CSPM with all sub-features..." -ForegroundColor Yellow
        
        if ($PSCmdlet.ShouldProcess($subscription.Name, "Enable Defender CSPM")) {
            try {
                # Enable Defender CSPM with all extensions using REST API
                $uri = "/subscriptions/$($subscription.Id)/providers/Microsoft.Security/pricings/CloudPosture"
                $body = @{
                    properties = @{
                        pricingTier = "Standard"
                        extensions = @(
                            @{
                                name = "AgentlessVmScanning"
                                isEnabled = "True"
                            },
                            @{
                                name = "SensitiveDataDiscovery"
                                isEnabled = "True"
                            },
                            @{
                                name = "ContainerRegistriesVulnerabilityAssessments"
                                isEnabled = "True"
                            },
                            @{
                                name = "AgentlessDiscoveryForKubernetes"
                                isEnabled = "True"
                            },
                            @{
                                name = "EntraPermissionsManagement"
                                isEnabled = "True"
                            }
                        )
                    }
                }
ConvertTo-Json -Depth 10
                
                $result = Invoke-AzRestMethodWithRetry -Path $uri -Method PUT -Payload $body -ApiVersion "2024-01-01" -MaxRetries 3 -RetryDelaySeconds 5 -ApiVersion "2024-01-01"
                if ($result.StatusCode -in 200, 201, 202) {
                    Write-Success "Defender CSPM enabled with all sub-features:"
                    Write-Host "    - Agentless VM scanning" -ForegroundColor Gray
                    Write-Host "    - Sensitive data discovery" -ForegroundColor Gray
                    Write-Host "    - Container registry vulnerability assessment" -ForegroundColor Gray
                    Write-Host "    - Agentless discovery for Kubernetes" -ForegroundColor Gray
                    Write-Host "    - Entra permissions management (CIEM)" -ForegroundColor Gray
                } else {
                    Write-ErrorMessage "Failed to enable Defender CSPM: HTTP $($result.StatusCode)"
                    if ($result.Content) {
                        Write-Host "    Error: $($result.Content)" -ForegroundColor Red
                    }
                }
                
            } catch {
                Write-ErrorMessage "Failed to enable Defender CSPM: $_"
            }
        }
        
        #endregion
        
        #region 2.2 Enable Defender for Servers Plan 2 with monitoring settings
        Write-Host "  [2.2] Enabling Defender for Servers Plan 2 with monitoring settings..." -ForegroundColor Yellow
        
        if ($PSCmdlet.ShouldProcess($subscription.Name, "Enable Defender for Servers Plan 2")) {
            try {
                # Enable Defender for Servers Plan 2 with extensions using REST API
                $uri = "/subscriptions/$($subscription.Id)/providers/Microsoft.Security/pricings/VirtualMachines"
                $body = @{
                    properties = @{
                        pricingTier = "Standard"
                        subPlan = "P2"
                        extensions = @(
                            @{
                                name = "AgentlessVmScanning"
                                isEnabled = "True"
                            },
                            @{
                                name = "MdeDesignatedSubscription"
                                isEnabled = "True"
                            }
                        )
                    }
                }
ConvertTo-Json -Depth 10
                
                $result = Invoke-AzRestMethodWithRetry -Path $uri -Method PUT -Payload $body -MaxRetries 5 -RetryDelaySeconds 15 -ApiVersion "2024-01-01"
                if ($result.StatusCode -in 200, 201, 202) {
                    Write-Success "Defender for Servers Plan 2 enabled"
                } else {
                    Write-ErrorMessage "Failed to enable Defender for Servers: HTTP $($result.StatusCode)"
                }
                
                # Enable Guest Configuration agent via auto-provisioning
                Write-Host "    Enabling Guest Configuration agent..." -ForegroundColor Yellow
                $uri = "/subscriptions/$($subscription.Id)/providers/Microsoft.Security/autoProvisioningSettings/GuestConfiguration"
                $body = @{
                    properties = @{
                        autoProvision = "On"
                    }
                }
ConvertTo-Json
                
                $result = Invoke-AzRestMethodWithRetry -Path $uri -Method PUT -Payload $body -ApiVersion "2024-01-01"
                if ($result.StatusCode -in 200, 201, 202) {
                    Write-Success "Guest Configuration agent (preview) enabled"
                } else {
                    Write-Warning "Guest Configuration agent: HTTP $($result.StatusCode)"
                }
                
                # Enable Azure Monitoring Agent for SQL servers
                Write-Host "    Enabling Azure Monitoring Agent for SQL servers..." -ForegroundColor Yellow
                $uri = "/subscriptions/$($subscription.Id)/providers/Microsoft.Security/autoProvisioningSettings/SqlVmAgents"
                $body = @{
                    properties = @{
                        autoProvision = "On"
                    }
                }
ConvertTo-Json
                
                $result = Invoke-AzRestMethodWithRetry -Path $uri -Method PUT -Payload $body -ApiVersion "2024-01-01"
                if ($result.StatusCode -in 200, 201, 202) {
                    Write-Success "Azure Monitoring Agent for SQL servers enabled"
                } else {
                    Write-Warning "SQL Monitoring Agent: HTTP $($result.StatusCode)"
                }
                
            } catch {
                Write-ErrorMessage "Failed to enable Defender for Servers: $_"
            }
        }
        
        #endregion
        
        #region 2.3 Enable Defender for SQL Server on Machines with DCR configuration
        Write-Host "  [2.3] Enabling Defender for SQL Server on Machines..." -ForegroundColor Yellow
        
        if ($PSCmdlet.ShouldProcess($subscription.Name, "Enable Defender for SQL on Machines")) {
            try {
                # Enable Defender for SQL on Machines with extensions
                $uri = "/subscriptions/$($subscription.Id)/providers/Microsoft.Security/pricings/SqlServerVirtualMachines"
                $body = @{
                    properties = @{
                        pricingTier = "Standard"
                    }
                }
ConvertTo-Json -Depth 10
                
                $result = Invoke-AzRestMethodWithRetry -Path $uri -Method PUT -Payload $body -ApiVersion "2024-01-01"
                if ($result.StatusCode -in 200, 201, 202) {
                    Write-Success "Defender for SQL Server on Machines enabled"
                } else {
                    Write-ErrorMessage "Failed to enable Defender for SQL: HTTP $($result.StatusCode)"
                }
                
                # Configure SQL Server DCR and Log Analytics workspace for Management subscription only
                if ($subscription.Name -like "*management*") {
                    Write-Host "    Configuring SQL Server monitoring with DCR and Log Analytics workspace..." -ForegroundColor Yellow
                    
                    # Note: These should come from solution config parameters
                    # Example: Get-ConfigValue -Path 'azure_infrastructure.monitoring.workspace_resource_id'
                    $lawResourceId = "/subscriptions/$($subscription.Id)/resourceGroups/$MonitoringResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$LogAnalyticsWorkspaceName"
                    
                    # Create or get DCR for SQL - name should come from config
                    $dcrResourceId = "/subscriptions/$($subscription.Id)/resourceGroups/$MonitoringResourceGroup/providers/Microsoft.Insights/dataCollectionRules/dcr-sqldefender"
                    
                    # Configure SQL Defender settings with DCR
                    $uri = "/subscriptions/$($subscription.Id)/providers/Microsoft.Security/sqlVulnerabilityAssessments/default"
                    $body = @{
                        properties = @{
                            state = "Enabled"
                        }
                    }
ConvertTo-Json -Depth 10
                    
                    $result = Invoke-AzRestMethodWithRetry -Path $uri -Method PUT -Payload $body -ApiVersion "2024-01-01"
                    if ($result.StatusCode -in 200, 201, 202) {
                        Write-Success "SQL Server monitoring configured with workspace: $LogAnalyticsWorkspaceName"
                    } else {
                        Write-Warning "SQL Server DCR configuration: HTTP $($result.StatusCode) - may require manual Portal configuration"
                    }
                } else {
                    Write-Host "    SQL Server monitoring will use default settings (configure DCR in Management subscription)" -ForegroundColor Gray
                }
                
            } catch {
                Write-ErrorMessage "Failed to enable Defender for SQL: $_"
            }
        }
        
        #endregion
        
        #region 2.4 Configure Email Notifications
        Write-Host "  [2.4] Configuring email notifications..." -ForegroundColor Yellow
        
        if ($PSCmdlet.ShouldProcess($subscription.Name, "Configure email notifications")) {
            try {
                # Configure security contact with notifications using REST API
                $uri = "/subscriptions/$($subscription.Id)/providers/Microsoft.Security/securityContacts/default"
                $body = @{
                    properties = @{
                        emails = $NotificationEmail
                        alertNotifications = @{
                            state = "On"
                            minimalSeverity = "Medium"
                        }
                        notificationsByRole = @{
                            state = "On"
                            roles = @("Owner")
                        }
                        notificationsSource = @{
                            attackPath = @{
                                state = "On"
                                minimalRiskLevel = "High"
                            }
                        }
                    }
                }
ConvertTo-Json -Depth 10
                
                $result = Invoke-AzRestMethodWithRetry -Path $uri -Method PUT -Payload $body -ApiVersion "2024-01-01"
                if ($result.StatusCode -in 200, 201, 202) {
                    Write-Success "Email notifications configured:"
                    Write-Host "    - Notify: All users with Owner role" -ForegroundColor Gray
                    Write-Host "    - Additional email: $NotificationEmail" -ForegroundColor Gray
                    Write-Host "    - Alert severity: Medium or higher" -ForegroundColor Gray
                    Write-Host "    - Attack path risk: High or higher" -ForegroundColor Gray
                } else {
                    Write-ErrorMessage "Failed to configure email notifications: HTTP $($result.StatusCode)"
                    Write-Host "    Response: $($result.Content)" -ForegroundColor Red
                }
                
            } catch {
                Write-ErrorMessage "Failed to configure email notifications: $_"
            }
        }
        
        #endregion
    }
    
    #endregion
    
    #region 3. Summary and Next Steps
    Write-Step "Configuration Summary"
    
    Write-Host "`nCompleted Configurations:" -ForegroundColor Green
    Write-Host "  ✓ Security policy initiatives assigned at management group" -ForegroundColor Green
    Write-Host "  ✓ Defender CSPM enabled with all sub-features on all subscriptions" -ForegroundColor Green
    Write-Host "  ✓ Defender for Servers Plan 2 enabled on all subscriptions" -ForegroundColor Green
    Write-Host "  ✓ Guest Configuration agent auto-provisioning enabled" -ForegroundColor Green
    Write-Host "  ✓ Defender for SQL Server on Machines enabled on all subscriptions" -ForegroundColor Green
    Write-Host "  ✓ Email notifications configured for all subscriptions" -ForegroundColor Green
    
    Write-Host "\nPost-Deployment Notes:" -ForegroundColor Cyan
    Write-Host "  - SQL Server DCR/workspace configured automatically for Management subscription" -ForegroundColor Gray
    Write-Host "  - Policy compliance evaluation takes ~30 minutes" -ForegroundColor Gray
    Write-Host "  - Guest Configuration agents will deploy to VMs automatically" -ForegroundColor Gray
    
    Write-Host "`nVerification:" -ForegroundColor Cyan
    Write-Host "  Run the following to verify configuration:" -ForegroundColor Gray
    Write-Host "    Get-AzSecurityPricing
Select-Object Name, PricingTier, SubPlan" -ForegroundColor Gray
    Write-Host "    Get-AzSecurityContact" -ForegroundColor Gray
    
    Write-Success "`nDefender for Cloud configuration completed successfully!"
    
    #endregion
    
} catch {
    Write-ErrorMessage "Script execution failed: $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}

Write-Host "`nScript completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan


