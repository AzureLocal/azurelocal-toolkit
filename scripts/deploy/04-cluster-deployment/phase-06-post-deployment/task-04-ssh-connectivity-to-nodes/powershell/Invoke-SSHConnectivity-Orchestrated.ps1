#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the WindowsOpenSSH Arc extension and configures HybridConnectivity
    SSH access on all Azure Local cluster nodes.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 04 — SSH Connectivity to Nodes

    For each machine in nodes[] of infrastructure.yml:
      1. Deploys the WindowsOpenSSH Arc VM extension via az connectedmachine extension create
      2. Registers Microsoft.HybridConnectivity RP (once per subscription)
      3. Creates the HybridConnectivity default endpoint
      4. Configures the SSH service on the endpoint

    After this task, operators connect with:
        az ssh arc  |  Enter-AzVM (Az.Ssh module)

    No WinRM/PSRemoting required — the Arc agent handles the OpenSSH install.

    The Arc machine of a node is in the resource group azure.resource_group of the subscription azure.subscription_id and is named by
    nodes[].arc_machine_name (the node name when the file gives none). Steps: Microsoft Learn, SSH access to Azure Arc-enabled servers, and
    Connect to an Azure Local VM using SSH (the WindowsOpenSSH extension).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.subscription_id, azure.resource_group, azure.location
        nodes[].name, nodes[].arc_machine_name

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. Only the keys named above are read.

.PARAMETER TargetNode
    Limit to specific node names (nodes[].name). Empty = all nodes in the file.

.PARAMETER WhatIf
    Log planned actions without making changes.

.PARAMETER LogPath
    Override log directory. Defaults to logs\task-04-ssh-connectivity-to-nodes\ in CWD.

.PARAMETER SshdPort
    Port to configure on the HybridConnectivity SSH endpoint. Default: 22.

.NOTES
    Run from the repo root.
    Requires: az CLI logged in with Contributor/Owner on the subscription.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]    $TargetNode  = @(),
    [switch]      $WhatIf,
    [string]      $LogPath     = "",
    [int]         $SshdPort    = 22
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

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
if (-not (Test-Path -LiteralPath $InfrastructureFile)) {
    Write-Log "Infrastructure file not found: $InfrastructureFile" "FAIL"; throw "Infrastructure file not found: $InfrastructureFile"
}
Write-Log "Loading the infrastructure file: $InfrastructureFile"

$cfg = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
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
# nodes[]: the host name and the Arc machine name of each machine.
$allNodes = @(Get-AzlInfrastructureNode -Infrastructure $cfg)

if ($TargetNode.Count -gt 0) {
    $allNodes = @($allNodes | Where-Object { $_.Name -in $TargetNode })
    Write-Log "Filtered to $($allNodes.Count) node(s): $($TargetNode -join ', ')"
} else {
    Write-Log "Processing all $($allNodes.Count) node(s) from config"
}
if ($allNodes.Count -eq 0) { Write-Log "No matching nodes — exiting" -Level "WARN"; exit 0 }
#endregion

#region HYBRIDCONNECTIVITY RP (once per subscription) ---------------------------
# The Arc machines are in azure.resource_group of azure.subscription_id.
$subId   = ([string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'azure.subscription_id')).Trim()
$nodeRg0 = ([string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'azure.resource_group')).Trim()
if (-not $subId -or -not $nodeRg0) {
    Write-Log "azure.subscription_id and azure.resource_group are needed: the Arc machines of the nodes are there." "FAIL"
    throw "azure.subscription_id or azure.resource_group is missing in $InfrastructureFile"
}

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

#region GET LOCATION FROM THE RESOURCE GROUP -----------------------------------
# az connectedmachine extension create requires --location (must match the Arc machine's region)
$location = az group show --name $nodeRg0 --query location -o tsv 2>$null
if (-not $location) { $location = $cfg.azure.location }   # azure.location fallback
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
    $nodeSub   = $using:subId
    $nodeRg    = $using:nodeRg0

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

    $hostname    = $nodeEntry.Name             # nodes[].name
    $machineName = $nodeEntry.ArcMachineName   # nodes[].arc_machine_name, else the node name

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

# Exit codes: 0 every machine is done (or planned under -WhatIf); 1 a machine failed. A missing file or a missing value stops the script before this.
if ($failed.Count -gt 0) { exit 1 }
exit 0
