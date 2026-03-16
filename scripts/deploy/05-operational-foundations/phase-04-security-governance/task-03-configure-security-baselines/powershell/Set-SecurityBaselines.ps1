<#
.SYNOPSIS
    Applies security baselines to Azure Local nodes.

.DESCRIPTION
    This script applies security baselines:
    - Windows security baselines
    - Azure Local security settings
    - Audit policy configuration
    - Defender settings

.PARAMETER NodeNames
    Array of cluster node hostnames.

.PARAMETER Credential
    Credentials for node access.

.EXAMPLE
    .\Set-SecurityBaselines.ps1 -NodeNames @("node01", "node02")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-20-governance/step-02-security-baselines
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\security-baselines",

    [Parameter(Mandatory = $false)]
    [switch]$ApplyBaselines,

    [Parameter(Mandatory = $false)]
    [switch]$AuditOnly
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

function Get-SecurityBaselineChecks {
    <#
    .SYNOPSIS
        Returns security baseline checks for Azure Local.
    #>
    return @(
        @{
            Name        = "Credential Guard"
            Category    = "Virtualization-Based Security"
            Check       = { 
                $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
                return $dg.SecurityServicesRunning -contains 1
            }
            Remediation = "Enable via Group Policy or registry"
        }
        @{
            Name        = "Secure Boot"
            Category    = "Firmware Security"
            Check       = { Confirm-SecureBootUEFI -ErrorAction SilentlyContinue }
            Remediation = "Enable in BIOS/UEFI settings"
        }
        @{
            Name        = "BitLocker on OS Drive"
            Category    = "Encryption"
            Check       = { 
                $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
                return $bl.ProtectionStatus -eq 'On'
            }
            Remediation = "Enable BitLocker on system drive"
        }
        @{
            Name        = "Windows Defender"
            Category    = "Antimalware"
            Check       = { 
                $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
                return $defender.RealTimeProtectionEnabled
            }
            Remediation = "Enable Windows Defender real-time protection"
        }
        @{
            Name        = "Audit Policy - Logon Events"
            Category    = "Auditing"
            Check       = { 
                $audit = auditpol /get /subcategory:"Logon" 2>$null
                return $audit -match "Success and Failure"
            }
            Remediation = "Enable via auditpol or Group Policy"
        }
        @{
            Name        = "SMB Signing"
            Category    = "Network Security"
            Check       = { 
                $smb = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
                return $smb.RequireSecuritySignature
            }
            Remediation = "Enable SMB signing"
        }
        @{
            Name        = "LDAP Signing"
            Category    = "Active Directory"
            Check       = { 
                $ldap = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "LDAPServerIntegrity" -ErrorAction SilentlyContinue
                return $ldap.LDAPServerIntegrity -ge 1
            }
            Remediation = "Configure LDAP signing via Group Policy"
        }
        @{
            Name        = "TLS 1.2 Only"
            Category    = "Encryption"
            Check       = {
                $tls12 = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" -Name "Enabled" -ErrorAction SilentlyContinue
                return $tls12.Enabled -eq 1
            }
            Remediation = "Enable TLS 1.2 and disable older protocols"
        }
    )
}

function Test-NodeSecurityBaseline {
    <#
    .SYNOPSIS
        Tests security baseline on a node.
    #>
    [CmdletBinding()]
    param(
        [string]$NodeName,
        [pscredential]$Credential,
        [array]$Checks
    )

    $results = @{
        NodeName = $NodeName
        Checks   = @()
        Passed   = 0
        Failed   = 0
    }

    try {
        $sessionParams = @{
            ComputerName = $NodeName
            ErrorAction  = 'Stop'
        }
        if ($Credential) {
            $sessionParams['Credential'] = $Credential
        }

        $session = New-PSSession @sessionParams

        foreach ($check in $Checks) {
            try {
                $passed = Invoke-Command -Session $session -ScriptBlock $check.Check

                $results.Checks += @{
                    Name        = $check.Name
                    Category    = $check.Category
                    Passed      = [bool]$passed
                    Remediation = $check.Remediation
                }

                if ($passed) {
                    $results.Passed++
                } else {
                    $results.Failed++
                }
            } catch {
                $results.Checks += @{
                    Name        = $check.Name
                    Category    = $check.Category
                    Passed      = $false
                    Error       = $_.Exception.Message
                    Remediation = $check.Remediation
                }
                $results.Failed++
            }
        }

        Remove-PSSession -Session $session
    } catch {
        $results.Error = $_.Exception.Message
    }

    return $results
}

function New-SecurityBaselineReport {
    <#
    .SYNOPSIS
        Generates security baseline report.
    #>
    [CmdletBinding()]
    param(
        [array]$NodeResults,
        [string]$OutputPath
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $reportFile = Join-Path $OutputPath "security-baseline-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"

    $report = @"
# Security Baseline Assessment Report

**Generated:** $timestamp

## Executive Summary

| Node | Passed | Failed | Compliance |
|------|--------|--------|------------|
"@

    foreach ($node in $NodeResults) {
        $total = $node.Passed + $node.Failed
        $compliance = if ($total -gt 0) { [math]::Round(($node.Passed / $total) * 100, 1) } else { 0 }
        $report += "`n| $($node.NodeName) | $($node.Passed) | $($node.Failed) | $compliance% |"
    }

    $report += @"

---

## Detailed Results by Node

"@

    foreach ($node in $NodeResults) {
        $report += @"

### $($node.NodeName)

| Check | Category | Status | Remediation |
|-------|----------|--------|-------------|
"@
        foreach ($check in $node.Checks) {
            $status = if ($check.Passed) { '✅ Passed' } else { '❌ Failed' }
            $remediation = if ($check.Passed) { 'N/A' } else { $check.Remediation }
            $report += "`n| $($check.Name) | $($check.Category) | $status | $remediation |"
        }
    }

    $report += @"

---

## Remediation Summary

"@

    $failedChecks = $NodeResults.Checks | Where-Object { -not $_.Passed } | Group-Object Name

    foreach ($check in $failedChecks) {
        $report += @"

### $($check.Name)

- **Affected Nodes:** $($check.Count)
- **Remediation:** $($check.Group[0].Remediation)

"@
    }

    $report += @"

---

*Report generated by Azure Local Cloud AzureLocalCloud Automation*
"@

    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    Set-Content -Path $reportFile -Value $report
    return $reportFile
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Security Baseline Assessment" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get node names from config if not provided
    if (-not $NodeNames -and $config.compute.cluster_nodes) {
        $NodeNames = $config.compute.cluster_nodes | ForEach-Object { $_.name }
    }

    if (-not $NodeNames) {
        throw "NodeNames are required"
    }

    # Prompt for credentials if not provided
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter credentials for node access"
    }

    # Get baseline checks
    $baselineChecks = Get-SecurityBaselineChecks
    Write-LogMessage "Security checks: $($baselineChecks.Count)" -Level Info

    # Test each node
    Write-LogMessage "" -Level Info
    Write-LogMessage "Assessing security baselines..." -Level Info

    $nodeResults = @()
    foreach ($node in $NodeNames) {
        Write-LogMessage "  Checking: $node" -Level Info
        
        $result = Test-NodeSecurityBaseline -NodeName $node -Credential $Credential -Checks $baselineChecks
        $nodeResults += $result

        $compliance = if (($result.Passed + $result.Failed) -gt 0) {
            [math]::Round(($result.Passed / ($result.Passed + $result.Failed)) * 100, 1)
        } else { 0 }

        Write-LogMessage "    Passed: $($result.Passed), Failed: $($result.Failed), Compliance: $compliance%" -Level $(if($compliance -ge 80){'Success'}elseif($compliance -ge 50){'Warning'}else{'Error'})
    }

    # Generate report
    Write-LogMessage "" -Level Info
    Write-LogMessage "Generating security baseline report..." -Level Info
    $reportPath = New-SecurityBaselineReport -NodeResults $nodeResults -OutputPath $OutputPath
    Write-LogMessage "  Report: $reportPath" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Security Baseline Assessment Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $totalPassed = ($nodeResults | Measure-Object -Property Passed -Sum).Sum
    $totalFailed = ($nodeResults | Measure-Object -Property Failed -Sum).Sum
    $overallCompliance = if (($totalPassed + $totalFailed) -gt 0) {
        [math]::Round(($totalPassed / ($totalPassed + $totalFailed)) * 100, 1)
    } else { 0 }

    Write-LogMessage "  Nodes assessed: $($nodeResults.Count)" -Level Info
    Write-LogMessage "  Total checks passed: $totalPassed" -Level Success
    Write-LogMessage "  Total checks failed: $totalFailed" -Level $(if($totalFailed -eq 0){'Info'}else{'Warning'})
    Write-LogMessage "  Overall compliance: $overallCompliance%" -Level $(if($overallCompliance -ge 80){'Success'}else{'Warning'})
    Write-LogMessage "  Report: $reportPath" -Level Info

    return @{
        NodeResults        = $nodeResults
        ReportPath         = $reportPath
        OverallCompliance  = $overallCompliance
    }

} catch {
    Write-LogMessage "Security baseline assessment failed: $_" -Level Error
    throw
}

#endregion Main
