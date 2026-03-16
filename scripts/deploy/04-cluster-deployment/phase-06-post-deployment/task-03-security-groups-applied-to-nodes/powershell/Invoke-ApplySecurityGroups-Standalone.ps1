# ==============================================================================
# Script : Invoke-ApplySecurityGroups-Standalone.ps1
# Purpose: Add AD security groups to local groups on each cluster node for all
#          5 node-applied roles — fully self-contained, no infrastructure.yml
# Run    : From any management server with PSRemoting access to cluster nodes
# Prereqs: PSRemoting enabled on all target nodes
# ==============================================================================

#region CONFIGURATION
# ── Edit these values to match your environment ──────────────────────────────

# Domain NetBIOS name
$DomainNetbios = "IMPROBABLE"

# Group name prefix — SG-{OrgPrefix}-{ClusterId}-AZL-{role}
$OrgPrefix     = "IIC"
$ClusterId     = "improbability-clus01"

# Cluster nodes to configure
$ClusterNodes  = @(
    "iic-01-n01",
    "iic-01-n02",
    "iic-01-n03",
    "iic-01-n04"
)

# Credentials for PSRemoting (leave $null to use current session)
$Credential    = $null

#endregion CONFIGURATION

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Group name builder
function sg { param([string]$Role) return "$DomainNetbios\SG-$OrgPrefix-$ClusterId-AZL-$Role" }

# Map: AD group → local groups to join (wac_admins / wac_users omitted — WAC server only)
$assignments = @(
    [PSCustomObject]@{ Key='azure_local_admins'; AdGroup=(sg 'Administrators');         LocalGroups=@('Administrators') },
    [PSCustomObject]@{ Key='operations';         AdGroup=(sg 'Operations');             LocalGroups=@('Remote Management Users','Remote Desktop Users') },
    [PSCustomObject]@{ Key='read_only';          AdGroup=(sg 'ReadOnly');               LocalGroups=@('Remote Desktop Users','Performance Monitor Users','Event Log Readers') },
    [PSCustomObject]@{ Key='hyperv_admins';      AdGroup=(sg 'HyperV-Administrators');  LocalGroups=@('Hyper-V Administrators','Remote Management Users') },
    [PSCustomObject]@{ Key='storage_admins';     AdGroup=(sg 'Storage-Administrators'); LocalGroups=@('Administrators') }
)

Write-Host "================================================================"
Write-Host " Apply Security Groups to Cluster Nodes — Standalone"
Write-Host " Domain  : $DomainNetbios"
Write-Host " Prefix  : $OrgPrefix  ClusterId: $ClusterId"
Write-Host " Nodes   : $($ClusterNodes -join ', ')"
Write-Host "================================================================"
foreach ($a in $assignments) { Write-Host "  $($a.Key): $($a.AdGroup) → [$($a.LocalGroups -join ', ')]" }
Write-Host ""

$credParam = @{}
if ($Credential) { $credParam['Credential'] = $Credential }

$results = @()

foreach ($node in $ClusterNodes) {
    Write-Host ""
    Write-Host "-- Node: $node"

    $nodeResult = Invoke-Command -ComputerName $node @credParam -ScriptBlock {
        param($Assignments)

        function Add-GroupMemberSafe {
            param([string]$LocalGroup, [string]$Member)
            try {
                Add-LocalGroupMember -Group $LocalGroup -Member $Member -ErrorAction Stop
                return "Added '$Member' to '$LocalGroup'"
            } catch {
                if ($_.Exception.Message -match 'already a member') {
                    return "'$Member' already in '$LocalGroup' — no change"
                }
                throw
            }
        }

        $log = @(); $errors = @()
        foreach ($a in $Assignments) {
            foreach ($lg in $a.LocalGroups) {
                try   { $log    += Add-GroupMemberSafe -LocalGroup $lg -Member $a.AdGroup }
                catch { $errors += "[$($a.Key)] $lg : $($_.Exception.Message)" }
            }
        }

        # Verify
        $verified = @{}
        foreach ($a in $Assignments) {
            foreach ($lg in $a.LocalGroups) {
                $members = Get-LocalGroupMember -Group $lg -ErrorAction SilentlyContinue |
                           Where-Object ObjectClass -eq 'Group' | Select-Object -ExpandProperty Name
                $verified["$($a.Key)|$lg"] = $members -contains $a.AdGroup
            }
        }

        return [PSCustomObject]@{
            Node     = $env:COMPUTERNAME
            Success  = ($errors.Count -eq 0)
            Log      = $log
            Errors   = $errors
            Verified = $verified
        }
    } -ArgumentList (, $assignments)

    foreach ($line in $nodeResult.Log)    { Write-Host "  $line" }
    foreach ($err  in $nodeResult.Errors) { Write-Host "  ERROR: $err" -ForegroundColor Red }
    foreach ($k in $nodeResult.Verified.Keys) {
        $ok = if ($nodeResult.Verified[$k]) { 'OK' } else { 'NOT CONFIRMED' }
        Write-Host "  [$k] : $ok"
    }

    $results += [PSCustomObject]@{
        Node    = $node
        Status  = if ($nodeResult.Success) { 'Success' } else { 'Failed' }
        Errors  = $nodeResult.Errors -join '; '
    }
}

Write-Host ""
Write-Host "================================================================"
Write-Host " Summary"
$results | Format-Table Node, Status, Errors -AutoSize
Write-Host "================================================================"
