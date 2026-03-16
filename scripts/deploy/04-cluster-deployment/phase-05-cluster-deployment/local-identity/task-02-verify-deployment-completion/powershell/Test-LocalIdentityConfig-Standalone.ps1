<#
.SYNOPSIS
    Test-LocalIdentityConfig-Standalone.ps1
    Verifies Local Identity (AD-less) configuration via PSRemoting from any machine.

.DESCRIPTION
    Self-contained script. Run from any machine (workstation, jump box, etc.)
    with network access to the cluster nodes. No infrastructure.yml or toolkit
    dependencies required. Define all variables in #region CONFIGURATION.

    Connects to each cluster node via PSRemoting and verifies:
      1. The node is NOT domain-joined (Domain = WORKGROUP)
      2. The cluster ADAware parameter = 2 (AD-less mode)

    Source: https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-03-verify-deployment-completion
    Execution:    Run from any machine with network access to the cluster nodes
    Run after:    Portal deployment completes

.EXAMPLE
    .\Test-LocalIdentityConfig-Standalone.ps1
#>

#region CONFIGURATION
$NodeIPs = @(
    "REPLACE_NODE_01_IP"   # compute.cluster_nodes[0].management_ip
    # "REPLACE_NODE_02_IP" # compute.cluster_nodes[1].management_ip — add additional nodes as needed
)
#endregion CONFIGURATION

$invalid = @($NodeIPs | Where-Object { $_ -match '^REPLACE_' })
if ($invalid.Count -gt 0) {
    throw "Edit the REPLACE_ variables in #region CONFIGURATION before running."
}

$cred = Get-Credential -Message "Enter local admin credentials for the cluster nodes"

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($nodeIP in $NodeIPs) {
    Write-Host "`n=== Local Identity Verification — $nodeIP ===" -ForegroundColor Cyan

    try {
        $result = Invoke-Command -ComputerName $nodeIP -Credential $cred -ScriptBlock {
            $output = [PSCustomObject]@{
                Node       = $env:COMPUTERNAME
                IP         = $using:nodeIP
                Domain     = (Get-WmiObject Win32_ComputerSystem).Domain
                ADAware    = $null
                Errors     = @()
            }

            try {
                $adAware = Get-ClusterResource "Cluster Name" | Get-ClusterParameter ADAware
                $output.ADAware = $adAware.Value
            } catch {
                $output.Errors += "ADAware check failed: $_"
            }
            $output
        }

        # Check 1: WORKGROUP membership
        if ($result.Domain -eq 'WORKGROUP') {
            Write-Host "  [PASS] Domain: $($result.Domain)" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Domain: $($result.Domain) (expected WORKGROUP)" -ForegroundColor Red
        }

        # Check 2: ADAware = 2
        if ($result.ADAware -eq 2) {
            Write-Host "  [PASS] ADAware: $($result.ADAware)" -ForegroundColor Green
        } elseif ($null -eq $result.ADAware) {
            Write-Host "  [FAIL] ADAware: could not read" -ForegroundColor Red
        } else {
            Write-Host "  [FAIL] ADAware: $($result.ADAware) (expected 2)" -ForegroundColor Red
        }

        foreach ($err in $result.Errors) {
            Write-Host "  [ERROR] $err" -ForegroundColor Red
        }

        $results.Add($result)

    } catch {
        Write-Host "  [ERROR] Failed to connect to $nodeIP : $_" -ForegroundColor Red
    }
}

# ── Summary table ─────────────────────────────────────────────────────────────
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
$results | Format-Table Node, IP, Domain, ADAware -AutoSize

Write-Host "`n[DONE] Local Identity configuration check complete" -ForegroundColor Cyan
