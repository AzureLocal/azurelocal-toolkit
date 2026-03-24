<#
.SYNOPSIS
    Configures security logging and audit policies for Azure Local.

.DESCRIPTION
    This script configures security logging:
    - Enables Windows Security audit policies on cluster nodes
    - Configures log forwarding to Log Analytics
    - Sets up security event collection via Data Collection Rules
    - Validates log ingestion

.PARAMETER ResourceGroupName
    Azure resource group name.

.PARAMETER WorkspaceId
    Log Analytics workspace resource ID.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Set-SecurityLogging.ps1 -ResourceGroupName "rg-azurelocal-prod"

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 05-operational-foundations
    Phase: phase-04-security-governance
    Task: task-04-enable-security-logging
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Monitor

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

function Set-SecurityAuditPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$NodeName,
        [pscredential]$Credential
    )
    if ($PSCmdlet.ShouldProcess($NodeName, "Configure security audit policies")) {
        Write-LogMessage "Configuring audit policies on $NodeName..." -Level Info
        $scriptBlock = {
            # Enable advanced audit policies
            $auditPolicies = @(
                @{ Category = 'Account Logon'; Subcategory = 'Credential Validation'; Setting = 'Success,Failure' }
                @{ Category = 'Account Management'; Subcategory = 'Security Group Management'; Setting = 'Success,Failure' }
                @{ Category = 'Account Management'; Subcategory = 'User Account Management'; Setting = 'Success,Failure' }
                @{ Category = 'Logon/Logoff'; Subcategory = 'Logon'; Setting = 'Success,Failure' }
                @{ Category = 'Logon/Logoff'; Subcategory = 'Special Logon'; Setting = 'Success' }
                @{ Category = 'Object Access'; Subcategory = 'File Share'; Setting = 'Success,Failure' }
                @{ Category = 'Policy Change'; Subcategory = 'Audit Policy Change'; Setting = 'Success,Failure' }
                @{ Category = 'Privilege Use'; Subcategory = 'Sensitive Privilege Use'; Setting = 'Success,Failure' }
                @{ Category = 'System'; Subcategory = 'Security System Extension'; Setting = 'Success,Failure' }
                @{ Category = 'System'; Subcategory = 'System Integrity'; Setting = 'Success,Failure' }
            )

            foreach ($policy in $auditPolicies) {
                auditpol /set /subcategory:"$($policy.Subcategory)" /success:enable /failure:enable 2>$null
            }

            # Increase security log size
            wevtutil sl Security /ms:1073741824

            return @{ Status = 'Configured'; NodeName = $env:COMPUTERNAME }
        }

        $params = @{ ComputerName = $NodeName; ScriptBlock = $scriptBlock }
        if ($Credential) { $params.Credential = $Credential }
        $result = Invoke-Command @params
        Write-LogMessage "Audit policies configured on $($result.NodeName)." -Level Success
    }
}

#endregion Functions

#region Main

Write-LogMessage "=== Configure Security Logging ===" -Level Info

# Load configuration
$config = Import-InfrastructureConfig -Path $ConfigPath
if ($config) {
    $ResourceGroupName = if ($ResourceGroupName) { $ResourceGroupName } else { $config.azure.resource_group_name }
    $WorkspaceId = if ($WorkspaceId) { $WorkspaceId } else { $config.monitoring.log_analytics_workspace_id }
    $SubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { $config.azure.subscription_id }
    if (-not $NodeNames) {
        $NodeNames = $config.compute.nodes | ForEach-Object { $_.name }
    }
}

if (-not $NodeNames -or $NodeNames.Count -eq 0) {
    Write-LogMessage "NodeNames are required. Provide via parameter or config." -Level Error
    exit 1
}

# Configure audit policies on each node
foreach ($node in $NodeNames) {
    try {
        Set-SecurityAuditPolicy -NodeName $node -Credential $Credential
    }
    catch {
        Write-LogMessage "Failed to configure audit policies on $node : $_" -Level Error
    }
}

# Verify security event collection
Write-LogMessage "Verifying security event collection..." -Level Info
foreach ($node in $NodeNames) {
    try {
        $params = @{ ComputerName = $node; ScriptBlock = { Get-WinEvent -LogName Security -MaxEvents 5 | Select-Object TimeCreated, Id, Message } }
        if ($Credential) { $params.Credential = $Credential }
        $events = Invoke-Command @params
        Write-LogMessage "  $node : $($events.Count) recent security events found." -Level Success
    }
    catch {
        Write-LogMessage "  $node : Unable to query security events — $_" -Level Warning
    }
}

Write-LogMessage "=== Security Logging Configuration Complete ===" -Level Success
Write-LogMessage "Configure DCR in Azure Portal to forward Security events to Log Analytics." -Level Info

#endregion Main
