<#
.SYNOPSIS
    Invoke-ConfigureClusterQuorum-Standalone.ps1
    Validates or creates the cloud witness storage account, then configures
    cluster quorum — fully self-contained, no infrastructure.yml required.

.DESCRIPTION
    Edit the #region CONFIGURATION block below with your environment values
    and run from any management server or jump box with Az.Accounts + Az.Storage
    installed and an active Connect-AzAccount session.

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        06-post-deployment
    Task:         task-02-cluster-quorum-configuration
    Execution:    Run from management server or jump box
    Prerequisites: Az.Accounts, Az.Storage, FailoverClusters; Azure authenticated

.EXAMPLE
    .\Invoke-ConfigureClusterQuorum-Standalone.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region CONFIGURATION
# ── Edit these values to match your environment ───────────────────────────────

# Cluster
$ClusterName   = "iic-01-clus01"         # Cluster name or IP

# Witness type: cloud_witness | file_share_witness
$WitnessType   = "cloud_witness"

# Cloud Witness settings (used when $WitnessType = "cloud_witness")
$WitnessAccountName    = "stiiccluster01witness"                   # 3-24 chars, lowercase alphanumeric
$WitnessResourceGroup  = "rg-iic-cluster-eus-01"
$WitnessSubscription   = ""                                        # Name or ID; leave empty to use current Az context
$WitnessRegion         = "eastus"
$WitnessSku            = "Standard_LRS"                           # Standard_LRS | Standard_ZRS | Standard_GRS

# File Share Witness settings (used when $WitnessType = "file_share_witness")
$FileSharePath = "\\fileserver.contoso.cloud\ClusterWitness\iic-01-clus01"

# Target node for PSRemoting — only one node required to set cluster quorum
$TargetNode    = "iic-01-n01"

# Credentials — set to $null to use the current session's identity
$Credential    = $null

#endregion CONFIGURATION

#region SCRIPT

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Task 02 — Cluster Quorum Configuration (Standalone)"          -ForegroundColor Cyan
Write-Host "  Cluster     : $ClusterName"
Write-Host "  Witness Type: $WitnessType"
Write-Host "  Target Node : $TargetNode"
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ── Cloud Witness: validate or create storage account ─────────────────────────
$witnessKey = $null

if ($WitnessType -eq 'cloud_witness') {
    Write-Host "-- Step 1: Validate cloud witness storage account" -ForegroundColor Cyan

    if (-not (Get-Module -Name Az.Storage -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Host "  Installing Az.Storage..." -ForegroundColor Yellow
        Install-Module -Name Az.Storage -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Az.Accounts, Az.Storage -ErrorAction Stop

    $ctx = Get-AzContext
    if (-not $ctx) {
        Write-Host "  ERROR: Not authenticated to Azure. Run Connect-AzAccount first." -ForegroundColor Red
        exit 1
    }
    Write-Host "  Azure context: $($ctx.Account.Id) / $($ctx.Subscription.Name)"

    if ($WitnessSubscription) {
        Write-Host "  Setting subscription: $WitnessSubscription"
        Set-AzContext -Subscription $WitnessSubscription | Out-Null
    }

    Write-Host "  Checking: $WitnessAccountName (RG: $WitnessResourceGroup)"
    $sa = Get-AzStorageAccount -ResourceGroupName $WitnessResourceGroup -Name $WitnessAccountName -ErrorAction SilentlyContinue

    if (-not $sa) {
        Write-Host "  Storage account NOT FOUND — creating..." -ForegroundColor Yellow
        Write-Host "    Name  : $WitnessAccountName"
        Write-Host "    RG    : $WitnessResourceGroup"
        Write-Host "    Region: $WitnessRegion"
        Write-Host "    SKU   : $WitnessSku"

        $sa = New-AzStorageAccount `
            -ResourceGroupName      $WitnessResourceGroup `
            -Name                   $WitnessAccountName `
            -Location               $WitnessRegion `
            -SkuName                $WitnessSku `
            -Kind                   'StorageV2' `
            -AccessTier             'Hot' `
            -EnableHttpsTrafficOnly $true `
            -MinimumTlsVersion      'TLS1_2' `
            -AllowBlobPublicAccess  $false

        Write-Host "  Storage account created: $($sa.Id)" -ForegroundColor Green
    } else {
        Write-Host "  Storage account OK: $($sa.Id)" -ForegroundColor Green
    }

    Write-Host "  Retrieving storage account key..."
    $keys = Get-AzStorageAccountKey -ResourceGroupName $WitnessResourceGroup -Name $WitnessAccountName
    $witnessKey = $keys[0].Value
    Write-Host "  Key retrieved" -ForegroundColor Green
}

# ── Configure quorum via PSRemoting ──────────────────────────────────────────
Write-Host ""
Write-Host "-- Step 2: Configure cluster quorum" -ForegroundColor Cyan
Write-Host "  Node: $TargetNode"

$credParam = @{}
if ($Credential) { $credParam['Credential'] = $Credential }

$result = Invoke-Command -ComputerName $TargetNode @credParam -ScriptBlock {
    param($Cluster, $WType, $AccountName, $AccountKey, $SharePath)

    try {
        Import-Module FailoverClusters -ErrorAction Stop

        switch ($WType) {
            'cloud_witness' {
                if (-not $AccountName -or -not $AccountKey) {
                    throw "cloud_witness requires AccountName and AccountKey"
                }
                Set-ClusterQuorum -Cluster $Cluster -CloudWitness -AccountName $AccountName -AccessKey $AccountKey -Endpoint "core.windows.net" -ErrorAction Stop
            }
            'file_share_witness' {
                if (-not $SharePath) {
                    throw "file_share_witness requires FileSharePath"
                }
                Set-ClusterQuorum -Cluster $Cluster -FileShareWitness $SharePath -ErrorAction Stop
            }
            'disk_witness' {
                throw "disk_witness requires a pre-existing shared disk cluster resource — use Set-ClusterQuorum -DiskWitness manually"
            }
            default {
                throw "Unknown WitnessType '$WType' — expected cloud_witness, file_share_witness, or disk_witness"
            }
        }

        $quorum = Get-ClusterQuorum -Cluster $Cluster
        return [PSCustomObject]@{
            Success        = $true
            QuorumType     = [string]$quorum.QuorumType
            QuorumResource = if ($quorum.QuorumResource) { [string]$quorum.QuorumResource.Name } else { "(none)" }
            QuorumState    = [string](Get-Cluster -Name $Cluster).QuorumState
        }
    } catch {
        return [PSCustomObject]@{
            Success        = $false
            Error          = $_.Exception.Message
            QuorumType     = $null
            QuorumResource = $null
            QuorumState    = $null
        }
    }

} -ArgumentList $ClusterName, $WitnessType, $WitnessAccountName, $witnessKey, $FileSharePath

# ── Results ───────────────────────────────────────────────────────────────────
Write-Host ""
if ($result.Success) {
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  Quorum Configuration Complete"                                  -ForegroundColor Green
    Write-Host "  Quorum Type    : $($result.QuorumType)"
    Write-Host "  Quorum Resource: $($result.QuorumResource)"
    Write-Host "  Quorum State   : $($result.QuorumState)"
    Write-Host "================================================================" -ForegroundColor Green

    if ($result.QuorumState -ne 'Normal') {
        Write-Host "  WARNING: Quorum state is '$($result.QuorumState)' — expected 'Normal'" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ERROR: Quorum configuration failed: $($result.Error)" -ForegroundColor Red
    exit 1
}

#endregion SCRIPT
