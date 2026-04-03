<#
.SYNOPSIS
    Post-Terraform configuration orchestrator for Azure Local deployments.

.DESCRIPTION
    Runs all PowerShell configuration steps that must execute AFTER Terraform
    has provisioned the Azure foundation resources. This is the "Path 1"
    automation path (Terraform + PowerShell).

    Steps executed in order:
      1. Active Directory preparation (OUs, security groups, DNS, service accounts)
      2. Domain Controller promotion (on Terraform-provisioned VMs)
      3. Cluster node OS configuration (hostname, NIC, NTP, domain join)
      4. Azure Arc registration (agent install, Azure registration)
      5. Monitoring agent deployment (AMA, HCI Insights)
      6. WAC server configuration
      7. Syslog/SNMP receiver configuration

.PARAMETER ConfigPath
    Path to the variables.yml configuration file. Defaults to the repo's
    config/variables/variables.yml.

.PARAMETER Credential
    PSCredential for remote execution on target nodes (domain admin).

.PARAMETER TargetNodes
    Array of cluster node hostnames or IPs. Auto-detected from config if omitted.

.PARAMETER LogPath
    Output directory for execution logs. Defaults to logs/.

.PARAMETER SkipSteps
    Array of step names to skip. Valid values:
    ad-preparation, dc-promotion, os-configuration, arc-registration,
    monitoring-agents, wac-server, syslog-receiver

.PARAMETER DryRun
    Previews the execution plan without running any steps.

.EXAMPLE
    .\Invoke-PostTerraformConfiguration.ps1 -ConfigPath ".\config\variables\variables.yml"

.EXAMPLE
    .\Invoke-PostTerraformConfiguration.ps1 -SkipSteps @("dc-promotion") -DryRun
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = '',
    [System.Management.Automation.PSCredential]$Credential = $null,
    [string[]]$TargetNodes = @(),
    [string]$LogPath = '',
    [ValidateSet('ad-preparation', 'dc-promotion', 'os-configuration',
                 'arc-registration', 'monitoring-agents', 'wac-server', 'syslog-receiver')]
    [string[]]$SkipSteps = @(),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$repoRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.FullName
$helpersPath = Join-Path $repoRoot 'scripts\common\utilities\helpers'

# Import helpers
. (Join-Path $helpersPath 'config-loader.ps1')
. (Join-Path $helpersPath 'logging.ps1')
. (Join-Path $helpersPath 'error-handling.ps1')

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $repoRoot 'config\variables\variables.yml'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    exit 1
}

$config = Get-Config -ConfigPath $ConfigPath

if (-not $LogPath) {
    $LogPath = Join-Path $repoRoot 'logs'
}
if (-not (Test-Path -LiteralPath $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogPath "post-terraform-$timestamp.log"

# ---------------------------------------------------------------------------
# Step definitions (in execution order)
# ---------------------------------------------------------------------------
$steps = [ordered]@{
    'ad-preparation'    = @{
        Description = 'Active Directory Preparation (OUs, Security Groups, DNS, Service Accounts)'
        TaskPath    = '03-onprem-readiness\phase-01-active-directory'
        Tasks       = @(
            'task-01-ou-creation-pre-creation-artifacts'
            'task-02-security-groups'
            'task-03-dns-node-a-records'
            'task-04-service-admin-accounts'
            'task-05-group-assignments'
        )
    }
    'dc-promotion'      = @{
        Description = 'Domain Controller Promotion'
        TaskPath    = '02-azure-foundation\phase-04-azure-management-infrastructure'
        Tasks       = @('task-12-configure-adds')
    }
    'os-configuration'  = @{
        Description = 'Cluster Node OS Configuration (Hostname, NIC, NTP, Domain Join)'
        TaskPath    = '04-cluster-deployment\phase-03-os-configuration'
        Tasks       = @(
            'task-01-enable-winrm'
            'task-03-configure-static-ip-address'
            'task-05-configure-dns-clients'
            'task-07-configure-time-synchronization-ntp'
            'task-10-configure-hostname'
        )
    }
    'arc-registration'  = @{
        Description = 'Azure Arc Registration'
        TaskPath    = '04-cluster-deployment\phase-04-arc-registration'
        Tasks       = @('task-02-register-cluster-nodes-with-azure-arc')
    }
    'monitoring-agents' = @{
        Description = 'Monitoring Agent Deployment (AMA, HCI Insights)'
        TaskPath    = '05-operational-foundations\phase-02-monitoring-observability'
        Tasks       = @(
            'task-02-configure-azure-monitor-agent'
            'task-03-enable-hci-insights'
        )
    }
    'wac-server'        = @{
        Description = 'Windows Admin Center Configuration'
        TaskPath    = '05-operational-foundations\phase-02-monitoring-observability'
        Tasks       = @('task-05-deploy-wac')
    }
    'syslog-receiver'   = @{
        Description = 'Syslog/SNMP Receiver Configuration'
        TaskPath    = '05-operational-foundations\phase-02-monitoring-observability'
        Tasks       = @('task-06-configure-network-device-logging')
    }
}

# ---------------------------------------------------------------------------
# Execution plan
# ---------------------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Post-Terraform Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Config  : $ConfigPath"
Write-Host "Log     : $logFile"
Write-Host "SkipSteps: $($SkipSteps -join ', ')"
Write-Host ""

$executionPlan = @()
foreach ($stepName in $steps.Keys) {
    $step = $steps[$stepName]
    $skipped = $stepName -in $SkipSteps
    $status = if ($skipped) { 'SKIP' } else { 'RUN' }
    $executionPlan += [PSCustomObject]@{
        Step        = $stepName
        Status      = $status
        Description = $step.Description
        Tasks       = $step.Tasks.Count
    }
    Write-Host "  [$status] $stepName — $($step.Description) ($($step.Tasks.Count) tasks)" -ForegroundColor $(if ($skipped) { 'DarkGray' } else { 'White' })
}
Write-Host ""

if ($DryRun) {
    Write-Host "DRY RUN — no changes will be made." -ForegroundColor Yellow
    $executionPlan | Format-Table -AutoSize
    exit 0
}

# ---------------------------------------------------------------------------
# Execute steps
# ---------------------------------------------------------------------------
$deployBase = Join-Path $repoRoot 'scripts\deploy'
$results = @()

foreach ($stepName in $steps.Keys) {
    if ($stepName -in $SkipSteps) {
        Write-Host "[SKIP] $stepName" -ForegroundColor DarkGray
        continue
    }

    $step = $steps[$stepName]
    $stepStart = Get-Date
    Write-Host "`n[START] $stepName — $($step.Description)" -ForegroundColor Green

    foreach ($taskDir in $step.Tasks) {
        $taskFullPath = Join-Path $deployBase "$($step.TaskPath)\$taskDir"
        $orchestratedScript = Get-ChildItem -Path (Join-Path $taskFullPath 'powershell') -Filter 'Invoke-*-Orchestrated.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($orchestratedScript) {
            Write-Host "  Running: $($orchestratedScript.Name)" -ForegroundColor White

            if ($PSCmdlet.ShouldProcess($orchestratedScript.Name, "Execute")) {
                try {
                    $taskParams = @{
                        ConfigPath = $ConfigPath
                        LogPath    = $LogPath
                    }
                    if ($Credential) { $taskParams['Credential'] = $Credential }
                    if ($TargetNodes.Count -gt 0) { $taskParams['TargetNode'] = $TargetNodes }

                    & $orchestratedScript.FullName @taskParams
                    Write-Host "  [OK] $($orchestratedScript.Name)" -ForegroundColor Green
                }
                catch {
                    Write-Host "  [FAIL] $($orchestratedScript.Name): $_" -ForegroundColor Red
                    $results += [PSCustomObject]@{
                        Step    = $stepName
                        Task    = $taskDir
                        Status  = 'FAILED'
                        Error   = $_.Exception.Message
                        Duration = (Get-Date) - $stepStart
                    }
                    Write-Error "Step '$stepName' failed at task '$taskDir': $_"
                }
            }
        }
        else {
            Write-Host "  [WARN] No orchestrated script found in: $taskFullPath" -ForegroundColor Yellow
        }
    }

    $results += [PSCustomObject]@{
        Step     = $stepName
        Task     = 'all'
        Status   = 'OK'
        Error    = $null
        Duration = (Get-Date) - $stepStart
    }
    Write-Host "[DONE] $stepName ($([math]::Round(((Get-Date) - $stepStart).TotalSeconds))s)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Execution Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$results | Format-Table Step, Status, Duration -AutoSize

$failures = $results | Where-Object { $_.Status -eq 'FAILED' }
if ($failures.Count -gt 0) {
    Write-Host "FAILURES: $($failures.Count) step(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "All steps completed successfully." -ForegroundColor Green
exit 0
