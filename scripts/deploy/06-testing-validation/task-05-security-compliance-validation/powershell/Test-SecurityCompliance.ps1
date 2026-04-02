<#
.SYNOPSIS
    Validates security configuration and compliance posture.

.DESCRIPTION
    Comprehensive security and compliance validation including:
    - Microsoft Defender for Cloud enrollment and plan status
    - RBAC role assignments on cluster Arc resource
    - BitLocker / encryption at rest status
    - Windows Defender Antivirus and exclusions
    - Security baseline and audit policy settings
    - Azure Policy compliance state
    - Generates validation report for customer handover

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER SubscriptionId
    Azure subscription ID containing the cluster resource.

.PARAMETER ResourceGroupName
    Resource group containing the Arc-enabled cluster.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.PARAMETER OutputPath
    Path to save validation report. Default: .\logs\validation-reports\

.EXAMPLE
    .\Test-SecurityCompliance.ps1 -ClusterName "azl-cluster-01" -SubscriptionId "00000000-0000-0000-0000-000000000000" -ResourceGroupName "rg-azurelocal-01"

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-05-security-compliance-validation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports"
)

#Requires -Version 7.0
#Requires -Module Az.Accounts
#Requires -Module Az.Resources
#Requires -Module Az.Security

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml
    return Get-Content -Path $Path -Raw | ConvertFrom-Yaml
}

#region Validation Functions

function Test-DefenderForCloudStatus {
    param([string]$SubId, [string]$RgName)

    Write-Log "Validating Microsoft Defender for Cloud..." -Level "HEADER"
    $results = @()

    try {
        Set-AzContext -SubscriptionId $SubId -ErrorAction Stop | Out-Null

        $pricings = Get-AzSecurityPricing -ErrorAction SilentlyContinue
        $plans = @("VirtualMachines", "Servers", "StorageAccounts", "KeyVaults")

        foreach ($plan in $plans) {
            $pricing = $pricings | Where-Object { $_.Name -eq $plan }
            $tier = if ($pricing) { $pricing.PricingTier } else { "NotFound" }
            $ok = $tier -eq "Standard"
            Write-Log "  $plan`: $tier" -Level $(if ($ok) { "SUCCESS" } else { "WARN" })
            $results += [PSCustomObject]@{ Plan = $plan; Tier = $tier; Status = if ($ok) { "PASS" } else { "WARN" } }
        }
    }
    catch {
        Write-Log "  Defender check failed — $_" -Level "ERROR"
    }

    return $results
}

function Test-RbacAssignments {
    param([string]$SubId, [string]$RgName)

    Write-Log "Validating RBAC role assignments..." -Level "HEADER"

    try {
        $scope = "/subscriptions/$SubId/resourceGroups/$RgName"
        $assignments = Get-AzRoleAssignment -Scope $scope -ErrorAction SilentlyContinue

        if ($assignments -and $assignments.Count -gt 0) {
            $grouped = $assignments | Group-Object -Property RoleDefinitionName
            foreach ($group in $grouped) {
                Write-Log "  $($group.Name): $($group.Count) assignment(s)" -Level "INFO"
            }

            $ownerCount = ($assignments | Where-Object { $_.RoleDefinitionName -eq "Owner" }).Count
            if ($ownerCount -gt 3) {
                Write-Log "  WARNING: $ownerCount Owner assignments (recommend <= 3)" -Level "WARN"
            }
        }
        else {
            Write-Log "  No RBAC assignments found on resource group scope" -Level "WARN"
        }

        return [PSCustomObject]@{
            TotalAssignments = $assignments.Count
            OwnerCount       = ($assignments | Where-Object { $_.RoleDefinitionName -eq "Owner" }).Count
        }
    }
    catch {
        Write-Log "  RBAC check failed — $_" -Level "ERROR"
        return $null
    }
}

function Test-EncryptionStatus {
    param([string[]]$NodeNames)

    Write-Log "Validating encryption at rest (BitLocker)..." -Level "HEADER"
    $results = @()

    foreach ($node in $NodeNames) {
        try {
            $volumes = Invoke-Command -ComputerName $node -ScriptBlock {
                Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage
            }

            foreach ($vol in $volumes) {
                $ok = $vol.ProtectionStatus -eq 'On'
                Write-Log "  $node $($vol.MountPoint): Protection=$($vol.ProtectionStatus), Encrypted=$($vol.EncryptionPercentage)%" -Level $(if ($ok) { "SUCCESS" } else { "WARN" })
                $results += [PSCustomObject]@{
                    Node       = $node
                    Volume     = $vol.MountPoint
                    Protection = $vol.ProtectionStatus.ToString()
                    Percent    = $vol.EncryptionPercentage
                    Status     = if ($ok) { "PASS" } else { "WARN" }
                }
            }
        }
        catch {
            Write-Log "  $node: BitLocker check failed — $_" -Level "ERROR"
        }
    }
    return $results
}

function Test-WindowsDefenderStatus {
    param([string[]]$NodeNames)

    Write-Log "Validating Windows Defender Antivirus..." -Level "HEADER"

    foreach ($node in $NodeNames) {
        try {
            $defender = Invoke-Command -ComputerName $node -ScriptBlock {
                $status = Get-MpComputerStatus
                [PSCustomObject]@{
                    RealTimeProtection   = $status.RealTimeProtectionEnabled
                    AntivirusEnabled     = $status.AntivirusEnabled
                    SignatureAge         = $status.AntivirusSignatureAge
                    LastScan             = $status.LastQuickScanEndTime
                }
            }
            $rtOk = $defender.RealTimeProtection
            $sigOk = $defender.SignatureAge -le 7
            Write-Log "  $node - RealTime=$($defender.RealTimeProtection), AV=$($defender.AntivirusEnabled), SigAge=$($defender.SignatureAge)d" -Level $(if ($rtOk -and $sigOk) { "SUCCESS" } else { "WARN" })
        }
        catch {
            Write-Log "  $node: Defender AV check failed — $_" -Level "ERROR"
        }
    }
}

function Test-AuditPolicies {
    param([string[]]$NodeNames)

    Write-Log "Validating security audit policies..." -Level "HEADER"

    foreach ($node in $NodeNames) {
        try {
            $auditInfo = Invoke-Command -ComputerName $node -ScriptBlock {
                $output = auditpol /get /category:* 2>&1
                $enabledPolicies = ($output | Select-String "Success|Failure" | Where-Object { $_ -notmatch "No Auditing" }).Count
                return @{ EnabledPolicies = $enabledPolicies }
            }
            Write-Log "  $node: $($auditInfo.EnabledPolicies) audit policy categories enabled" -Level $(if ($auditInfo.EnabledPolicies -gt 0) { "SUCCESS" } else { "WARN" })
        }
        catch {
            Write-Log "  $node: Audit policy check failed — $_" -Level "ERROR"
        }
    }
}

function Test-AzurePolicyCompliance {
    param([string]$SubId, [string]$RgName)

    Write-Log "Validating Azure Policy compliance..." -Level "HEADER"

    try {
        $scope = "/subscriptions/$SubId/resourceGroups/$RgName"
        $states = Get-AzPolicyState -ResourceGroupName $RgName -ErrorAction SilentlyContinue

        if ($states) {
            $grouped = $states | Group-Object -Property ComplianceState
            foreach ($group in $grouped) {
                $level = switch ($group.Name) { "Compliant" { "SUCCESS" }; "NonCompliant" { "WARN" }; default { "INFO" } }
                Write-Log "  $($group.Name): $($group.Count) resources" -Level $level
            }
        }
        else {
            Write-Log "  No policy state data available" -Level "INFO"
        }
    }
    catch {
        Write-Log "  Policy compliance check failed — $_" -Level "WARN"
    }
}

#endregion Validation Functions

#region Main

Write-Log "========================================" -Level "HEADER"
Write-Log "Security & Compliance Validation" -Level "HEADER"
Write-Log "========================================" -Level "HEADER"

if ($ConfigPath) {
    $config = Import-InfrastructureConfig -Path $ConfigPath
    if (-not $ClusterName -and $config) { $ClusterName = $config.platform.cluster_name }
    if (-not $SubscriptionId -and $config) { $SubscriptionId = $config.azure.subscription_id }
    if (-not $ResourceGroupName -and $config) { $ResourceGroupName = $config.azure.resource_group }
}
if (-not $ClusterName -or -not $SubscriptionId -or -not $ResourceGroupName) {
    Write-Log "ClusterName, SubscriptionId, and ResourceGroupName are required." -Level "ERROR"
    exit 1
}

$nodes = (Get-ClusterNode -Cluster $ClusterName).Name
Write-Log "Cluster: $ClusterName ($($nodes.Count) nodes)" -Level "INFO"
Write-Log "Subscription: $SubscriptionId" -Level "INFO"
Write-Host ""

$report = @{ Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; ClusterName = $ClusterName; Sections = @{} }

# 1. Defender for Cloud
$defenderResults = Test-DefenderForCloudStatus -SubId $SubscriptionId -RgName $ResourceGroupName
$report.Sections["DefenderForCloud"] = $defenderResults
Write-Host ""

# 2. RBAC
$rbacResult = Test-RbacAssignments -SubId $SubscriptionId -RgName $ResourceGroupName
$report.Sections["RBAC"] = $rbacResult
Write-Host ""

# 3. Encryption
$encryptionResults = Test-EncryptionStatus -NodeNames $nodes
$report.Sections["Encryption"] = $encryptionResults
Write-Host ""

# 4. Windows Defender AV
Test-WindowsDefenderStatus -NodeNames $nodes
Write-Host ""

# 5. Audit Policies
Test-AuditPolicies -NodeNames $nodes
Write-Host ""

# 6. Azure Policy
Test-AzurePolicyCompliance -SubId $SubscriptionId -RgName $ResourceGroupName
Write-Host ""

# Save report
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $OutputPath "05-security-compliance-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8
Write-Log "Report saved: $reportFile" -Level "INFO"

$defenderPass = ($defenderResults | Where-Object { $_.Status -eq "PASS" }).Count
$encPass = ($encryptionResults | Where-Object { $_.Status -eq "PASS" }).Count

Write-Host ""
Write-Log "========================================" -Level "HEADER"
Write-Log "Security & Compliance Summary" -Level "SUCCESS"
Write-Log "  Defender plans enabled: $defenderPass / $($defenderResults.Count)" -Level "INFO"
Write-Log "  Encrypted volumes: $encPass / $($encryptionResults.Count)" -Level "INFO"

#endregion Main
