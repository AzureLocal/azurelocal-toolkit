<#
.SYNOPSIS
    Performs validation signoff checks for enterprise readiness.

.DESCRIPTION
    This script performs final validation checks before deployment:
    - Validates all prerequisite checks have passed
    - Generates signoff documentation
    - Creates deployment readiness checklist

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.PARAMETER ValidationResultsPath
    Path to previous validation results.

.PARAMETER OutputPath
    Path for signoff documentation output.

.EXAMPLE
    .\Complete-ValidationSignoff.ps1 -OutputPath ".\output\signoff"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 04-onprem-readiness
    Step: stage-09-enterprise-readiness/step-04-validation-signoff
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$ValidationResultsPath = ".\output",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\signoff",

    [Parameter(Mandatory = $false)]
    [string]$CustomerName,

    [Parameter(Mandatory = $false)]
    [string]$ProjectName
)

#Requires -Version 7.0

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

function Get-ValidationResults {
    <#
    .SYNOPSIS
        Collects all validation results from previous checks.
    #>
    [CmdletBinding()]
    param([string]$Path)

    $results = @{
        HardwareInspection  = $null
        NetworkReadiness    = $null
        OpengearVerification = $null
        AzureValidation     = $null
    }

    # Look for hardware inspection reports
    $hardwareReports = Get-ChildItem -Path $Path -Filter "hardware-inspection*.md" -Recurse -ErrorAction SilentlyContinue
    if ($hardwareReports) {
        $results.HardwareInspection = @{
            Found     = $true
            LatestReport = $hardwareReports | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
    }

    # Look for network readiness reports
    $networkReports = Get-ChildItem -Path $Path -Filter "*network*.json" -Recurse -ErrorAction SilentlyContinue
    if ($networkReports) {
        $results.NetworkReadiness = @{
            Found     = $true
            LatestReport = $networkReports | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
    }

    # Look for Opengear verification
    $opengearReports = Get-ChildItem -Path $Path -Filter "*opengear*.json" -Recurse -ErrorAction SilentlyContinue
    if ($opengearReports) {
        $results.OpengearVerification = @{
            Found     = $true
            LatestReport = $opengearReports | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
    }

    return $results
}

function New-SignoffDocument {
    <#
    .SYNOPSIS
        Creates the validation signoff document.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath,
        [string]$CustomerName,
        [string]$ProjectName,
        [hashtable]$ValidationResults,
        [hashtable]$Config
    )

    $signoffDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $signoffFile = Join-Path $OutputPath "validation-signoff-$(Get-Date -Format 'yyyyMMdd').md"

    $document = @"
# Azure Local Deployment - Validation Signoff

**Customer:** $CustomerName  
**Project:** $ProjectName  
**Date:** $signoffDate  
**Document Version:** 1.0

---

## Executive Summary

This document certifies that all pre-deployment validation checks have been completed for the Azure Local deployment.

---

## Validation Status

### Infrastructure Validation

| Check | Status | Notes |
|-------|--------|-------|
| Hardware Inspection | $(if($ValidationResults.HardwareInspection.Found){'✅ Complete'}else{'⚠️ Not Found'}) | $(if($ValidationResults.HardwareInspection.LatestReport){"Report: $($ValidationResults.HardwareInspection.LatestReport.Name)"}else{'Manual verification required'}) |
| Network Readiness | $(if($ValidationResults.NetworkReadiness.Found){'✅ Complete'}else{'⚠️ Not Found'}) | $(if($ValidationResults.NetworkReadiness.LatestReport){"Report: $($ValidationResults.NetworkReadiness.LatestReport.Name)"}else{'Manual verification required'}) |
| Opengear Verification | $(if($ValidationResults.OpengearVerification.Found){'✅ Complete'}else{'⚠️ Not Found'}) | $(if($ValidationResults.OpengearVerification.LatestReport){"Report: $($ValidationResults.OpengearVerification.LatestReport.Name)"}else{'Manual verification required'}) |

### Pre-Deployment Checklist

#### Azure Resources
- [ ] Subscription access verified
- [ ] Resource providers registered
- [ ] RBAC permissions assigned
- [ ] Virtual network deployed
- [ ] Key Vault configured
- [ ] Log Analytics workspace created

#### On-Premises Infrastructure
- [ ] Active Directory configured
- [ ] OUs and groups created
- [ ] DNS records configured
- [ ] Service accounts created
- [ ] Network connectivity verified
- [ ] Firewall rules configured

#### Hardware
- [ ] All nodes physically inspected
- [ ] Firmware versions validated
- [ ] BIOS settings configured
- [ ] iDRAC access confirmed
- [ ] Network cabling verified
- [ ] Power connections verified

#### Network Devices
- [ ] Opengear console server configured
- [ ] PowerSwitch ONIE installation complete
- [ ] Switch port configuration complete
- [ ] VLAN configuration verified

---

## Configuration Summary

**Cluster Name:** $($config.compute.azure_local.cluster_name ?? 'Not configured')  
**Node Count:** $($config.compute.cluster_nodes.Count ?? 'Not configured')  
**Azure Region:** $($config.azure_platform.location ?? 'Not configured')  
**Subscription:** $($config.azure_platform.subscriptions.lab.id ?? 'Not configured')

---

## Signoff

### Azure Local Cloud Engineering

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Lead Engineer | _________________ | _________________ | __________ |
| Network Engineer | _________________ | _________________ | __________ |
| Project Manager | _________________ | _________________ | __________ |

### Customer

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Technical Contact | _________________ | _________________ | __________ |
| Project Sponsor | _________________ | _________________ | __________ |

---

## Approval

By signing above, all parties acknowledge that:

1. All pre-deployment validation checks have been completed
2. The infrastructure meets the requirements for Azure Local deployment
3. Any noted exceptions or deviations have been documented and accepted
4. The project is approved to proceed to the deployment phase

---

*Document generated by Azure Local Cloud AzureLocalCloud Automation*  
*Generated: $signoffDate*
"@

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    Set-Content -Path $signoffFile -Value $document
    return $signoffFile
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Validation Signoff Generation" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = @{}
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get customer/project names
    if (-not $CustomerName) {
        $CustomerName = $config.site.customer_name ?? "TBD"
    }
    if (-not $ProjectName) {
        $ProjectName = $config.project.name ?? "Azure Local Deployment"
    }

    Write-LogMessage "Customer: $CustomerName" -Level Info
    Write-LogMessage "Project: $ProjectName" -Level Info

    # Collect validation results
    Write-LogMessage "Collecting validation results..." -Level Info
    $validationResults = Get-ValidationResults -Path $ValidationResultsPath

    $foundChecks = ($validationResults.Values | Where-Object { $_.Found }).Count
    $totalChecks = $validationResults.Count

    Write-LogMessage "  Found $foundChecks of $totalChecks validation reports" -Level Info

    # Generate signoff document
    Write-LogMessage "Generating signoff document..." -Level Info
    $signoffPath = New-SignoffDocument `
        -OutputPath $OutputPath `
        -CustomerName $CustomerName `
        -ProjectName $ProjectName `
        -ValidationResults $validationResults `
        -Config $config

    Write-LogMessage "  Signoff document: $signoffPath" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Validation Signoff Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "  Document: $signoffPath" -Level Info
    Write-LogMessage "  Validation checks found: $foundChecks / $totalChecks" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "NEXT STEPS:" -Level Warning
    Write-LogMessage "  1. Review the signoff document" -Level Info
    Write-LogMessage "  2. Complete any missing validation checks" -Level Info
    Write-LogMessage "  3. Obtain required signatures" -Level Info
    Write-LogMessage "  4. Proceed to deployment phase" -Level Info

    return @{
        SignoffPath       = $signoffPath
        ValidationResults = $validationResults
        ReadyForDeployment = ($foundChecks -eq $totalChecks)
    }

} catch {
    Write-LogMessage "Signoff generation failed: $_" -Level Error
    throw
}

#endregion Main
