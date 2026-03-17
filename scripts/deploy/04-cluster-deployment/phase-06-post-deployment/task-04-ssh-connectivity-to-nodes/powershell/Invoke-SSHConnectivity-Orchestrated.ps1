#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the WindowsOpenSSH Arc extension and configures HybridConnectivity
    SSH access on all Azure Local cluster nodes.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 04 — SSH Connectivity to Nodes

    For each node in infrastructure.yml:
      1. Deploys the WindowsOpenSSH Arc VM extension via az connectedmachine extension create
      2. Registers Microsoft.HybridConnectivity RP (once per subscription)
      3. Creates the HybridConnectivity default endpoint
      4. Configures the SSH service on the endpoint

    After this task, operators connect with:
        az ssh arc  |  Enter-AzVM (Az.Ssh module)

    No WinRM/PSRemoting required — the Arc agent handles the OpenSSH install.

.PARAMETER ConfigPath
    Path to infrastructure YAML config. Defaults to config/infrastructure.yml
    relative to CWD (repo root).

.PARAMETER TargetNode
    Limit to specific node key names. Empty = all nodes in config.

.PARAMETER WhatIf
    Log planned actions without making changes.

.PARAMETER LogPath
    Override log directory. Defaults to logs\task-04-ssh-connectivity-to-nodes\ in CWD.

.PARAMETER SshdPort
    Port to configure on the HybridConnectivity SSH endpoint. Default: 22.

.NOTES
    Run from the repo root.
    Requires: az CLI logged in with Contributor/Owner on the subscription.
    Requires: powershell-yaml module  (Install-Module powershell-yaml)
#>

[CmdletBinding()]
param(
    [string]      $ConfigPath  = "",
    [PSCredential]$Credential  = $null,
    [string[]]    $TargetNode  = @(),
    [switch]      $WhatIf,
    [string]      $LogPath     = "",
    [int]         $SshdPort    = 22
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region LOGGING -----------------------------------------------------------------
$scriptShortName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -replace '^Invoke-|-Orchestrated$', ''
$taskFolderName  = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf
$logDir  = if ($LogPath -ne "") { Split-Path $LogPath -Parent } else { Join-Path (Get-Location).Path "logs\$taskFolderName" }
$logFile = if ($LogPath -ne "") { $LogPath } else { Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd_HHmmss')_${scriptShortName}.log" }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    $line | Out-File -FilePath $script:logFile -Append -Encoding utf8
    switch ($Level) {
        "PASS"    { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "FAIL"    { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
        "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
        "VERBOSE" { Write-Verbose "[$ts] $Message" }
        "DEBUG"   { Write-Debug  "[$ts] $Message" }
        default   { Write-Host "[$ts] [INFO] $Message" }
    }
}
#endregion

#region CONFIG LOADING ----------------------------------------------------------
if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path (Get-Location).Path "configs\infrastructure.yml"
}
if (-not (Test-Path $ConfigPath)) {
    Write-Log "Config not found: $ConfigPath" "FAIL"; throw "Config not found: $ConfigPath"
}
Write-Log "Loading config: $ConfigPath"

Import-Module powershell-yaml -ErrorAction Stop
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
#endregion

#region AZ CLI CHECK ------------------------------------------------------------
Write-Log "Verifying Azure CLI authentication"
$azSub = az account show --query id -o tsv 2>$null
if (-not $azSub) {
    Write-Log "Not logged in to Azure CLI. Run: az login --use-device-code" "FAIL"
    throw "az CLI not authenticated"
}
Write-Log "Authenticated — subscription context: $azSub" "PASS"
#endregion

#region NODE LIST ---------------------------------------------------------------
$allNodes = @($cfg.compute.cluster_nodes.GetEnumerator())   # compute.cluster_nodes


if ($TargetNode.Count -gt 0) {
    $allNodes = $allNodes | Where-Object { $_.Key -in $TargetNode }
    Write-Log "Filtered to $($allNodes.Count) node(s): $($TargetNode -join ', ')"
} else {
    Write-Log "Processing all $($allNodes.Count) node(s) from config"
}
if ($allNodes.Count -eq 0) { Write-Log "No matching nodes — exiting" -Level "WARN"; exit 0 }
#endregion

#region HYBRIDCONNECTIVITY RP (once per subscription) ---------------------------
# Parse subscription from first node's arc_resource_id
$firstArcId = $allNodes[0].Value.arc_resource_id   # compute.cluster_nodes.<key>.arc_resource_id
$subId      = ($firstArcId -split '/')[2]

Write-Log "Checking HybridConnectivity RP on subscription: $subId"
if (-not $WhatIf) {
    az account set --subscription $subId | Out-Null
    $rpState = az provider show -n Microsoft.HybridConnectivity --query registrationState -o tsv 2>$null
    if ($rpState -ne 'Registered') {
        Write-Log "Registering Microsoft.HybridConnectivity RP — may take 2-5 minutes"
        az provider register -n Microsoft.HybridConnectivity | Out-Null
        $retries = 0
        do {
            Start-Sleep -Seconds 15
            $rpState = az provider show -n Microsoft.HybridConnectivity --query registrationState -o tsv 2>$null
            Write-Log "  RP state: $rpState (attempt $($retries+1)/20)"
            $retries++
        } until ($rpState -eq 'Registered' -or $retries -ge 20)
        if ($rpState -ne 'Registered') { throw "HybridConnectivity RP registration timed out" }
    }
    Write-Log "HybridConnectivity RP: Registered" "PASS"
} else {
    Write-Log "[WHATIF] Would register Microsoft.HybridConnectivity RP on subscription $subId if needed"
}
#endregion

#region GET LOCATION FROM FIRST NODE RESOURCE GROUP ----------------------------
# az connectedmachine extension create requires --location (must match the Arc machine's region)
$firstRg = ($firstArcId -split '/')[4]
$location = az group show --name $firstRg --query location -o tsv 2>$null
if (-not $location) { $location = $cfg.azure_platform.region }   # azure_platform.region fallback
Write-Log "Arc resource region: $location"
#endregion

#region PROCESS NODES (parallel) ------------------------------------------------
$logMutex = [System.Threading.Mutex]::new($false, "SSHConnectivityLog_$(Get-Random)")

$results = $allNodes | ForEach-Object -Parallel {
    $nodeEntry = $_
    $logFile   = $using:logFile
    $logMutex  = $using:logMutex
    $WhatIf    = $using:WhatIf
    $location  = $using:location
    $SshdPort  = $using:SshdPort

    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "[$ts] [$Level] $Message"
        $null = $logMutex.WaitOne(5000)
        try   { $line | Out-File -FilePath $logFile -Append -Encoding utf8 }
        finally { $logMutex.ReleaseMutex() }
        switch ($Level) {
            "PASS"    { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
            "FAIL"    { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
            "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
            "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
            "VERBOSE" { Write-Verbose "[$ts] $Message" }
            "DEBUG"   { Write-Debug  "[$ts] $Message" }
            default   { Write-Host "[$ts] [INFO] $Message" }
        }
    }

    $arcResourceId = $nodeEntry.Value.arc_resource_id   # compute.cluster_nodes.<key>.arc_resource_id
    $hostname      = $nodeEntry.Value.hostname           # compute.cluster_nodes.<key>.hostname
    $arcParts      = $arcResourceId -split '/'
    $nodeSub       = $arcParts[2]
    $nodeRg        = $arcParts[4]
    $machineName   = $arcParts[-1]

    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Log "Node: $hostname | Arc machine: $machineName | RG: $nodeRg"

    $result = [PSCustomObject]@{
        Node         = $hostname
        ExtensionOK  = $false
        EndpointOK   = $false
        SshServiceOK = $false
        Errors       = [System.Collections.Generic.List[string]]::new()
    }

    #-- Step 1: Deploy WindowsOpenSSH Arc extension --------------------------------
    Write-Log "[$hostname] Step 1/3 — Deploy WindowsOpenSSH Arc extension"

    if (-not $WhatIf) {
        try {
            $extState = az connectedmachine extension show `
                --resource-group $nodeRg `
                --machine-name   $machineName `
                --name           "WindowsOpenSSH" `
                --query          "properties.provisioningState" `
                -o               tsv 2>$null

            if ($extState -eq 'Succeeded') {
                Write-Log "[$hostname]   WindowsOpenSSH extension already installed" "PASS"
                $result.ExtensionOK = $true
            } else {
                Write-Log "[$hostname]   Installing WindowsOpenSSH extension (this may take 2-3 minutes)"
                az connectedmachine extension create `
                    --resource-group $nodeRg `
                    --machine-name   $machineName `
                    --name           "WindowsOpenSSH" `
                    --publisher      "Microsoft.Azure.OpenSSH" `
                    --type           "WindowsOpenSSH" `
                    --location       $location | Out-Null

                $retries = 0
                do {
                    Start-Sleep -Seconds 20
                    $extState = az connectedmachine extension show `
                        --resource-group $nodeRg --machine-name $machineName `
                        --name "WindowsOpenSSH" --query "properties.provisioningState" -o tsv 2>$null
                    Write-Log "[$hostname]   Extension state: $extState (attempt $($retries+1)/15)"
                    $retries++
                } until ($extState -in @('Succeeded','Failed') -or $retries -ge 15)

                if ($extState -eq 'Succeeded') {
                    $result.ExtensionOK = $true
                    Write-Log "[$hostname]   WindowsOpenSSH extension installed" "PASS"
                } else {
                    $result.Errors.Add("Extension provisioning state: $extState")
                    Write-Log "[$hostname]   Extension install did not succeed: $extState" "FAIL"
                }
            }
        } catch {
            $result.Errors.Add("Extension: $($_.Exception.Message)")
            Write-Log "[$hostname] Extension install failed: $($_.Exception.Message)" "FAIL"
        }
    } else {
        Write-Log "[$hostname] [WHATIF] Would deploy WindowsOpenSSH extension via az connectedmachine extension create"
        $result.ExtensionOK = $true
    }

    #-- Step 2: HybridConnectivity default endpoint --------------------------------
    Write-Log "[$hostname] Step 2/3 — Create HybridConnectivity default endpoint"

    $epUri = "https://management.azure.com/subscriptions/$nodeSub/resourceGroups/$nodeRg/providers/Microsoft.HybridCompute/machines/$machineName/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15"

    if (-not $WhatIf) {
        try {
            $epTmp = [IO.Path]::GetTempFileName()
            '{"properties":{"type":"default"}}' | Set-Content $epTmp -Encoding utf8 -NoNewline
            $epOut = az rest --method put --uri $epUri `
                --headers "Content-Type=application/json" `
                --body "@$epTmp" 2>&1
            Remove-Item $epTmp -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) { throw ($epOut | Out-String).Trim() }
            $result.EndpointOK = $true
            Write-Log "[$hostname]   HybridConnectivity default endpoint created/verified" "PASS"
        } catch {
            $result.Errors.Add("Endpoint: $($_.Exception.Message)")
            Write-Log "[$hostname] Endpoint creation failed: $($_.Exception.Message)" "FAIL"
        }
    } else {
        Write-Log "[$hostname] [WHATIF] Would PUT default endpoint: $epUri"
        $result.EndpointOK = $true
    }

    #-- Step 3: SSH service configuration ------------------------------------------
    Write-Log "[$hostname] Step 3/3 — Configure SSH service on endpoint (port $SshdPort)"

    $svcUri = "https://management.azure.com/subscriptions/$nodeSub/resourceGroups/$nodeRg/providers/Microsoft.HybridCompute/machines/$machineName/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15"

    if (-not $WhatIf) {
        try {
            $svcBody = '{"properties":{"serviceName":"SSH","port":' + $SshdPort + '}}'
            $svcTmp  = [IO.Path]::GetTempFileName()
            $svcBody | Set-Content $svcTmp -Encoding utf8 -NoNewline
            $svcOut  = az rest --method put --uri $svcUri `
                --headers "Content-Type=application/json" `
                --body "@$svcTmp" 2>&1
            Remove-Item $svcTmp -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) { throw ($svcOut | Out-String).Trim() }
            $result.SshServiceOK = $true
            Write-Log "[$hostname]   SSH service configured on port $SshdPort" "PASS"
        } catch {
            $result.Errors.Add("SshService: $($_.Exception.Message)")
            Write-Log "[$hostname] SSH service config failed: $($_.Exception.Message)" "FAIL"
        }
    } else {
        Write-Log "[$hostname] [WHATIF] Would PUT SSH service config (port $SshdPort): $svcUri"
        $result.SshServiceOK = $true
    }

    $result

} -ThrottleLimit 8

$logMutex.Dispose()
$results = @($results)
#endregion

#region SUMMARY -----------------------------------------------------------------
Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Log "SUMMARY"
$ok     = @($results | Where-Object { $_.Errors.Count -eq 0 })
$failed = @($results | Where-Object { $_.Errors.Count -gt 0 })
Write-Log "Succeeded: $($ok.Count) / $($results.Count)" "PASS"
$failed | ForEach-Object {
    Write-Log "FAILED: $($_.Node)" "FAIL"
    $_.Errors | ForEach-Object { Write-Log "  $_" "FAIL" }
}
Write-Log "Log: $logFile"
#endregion
