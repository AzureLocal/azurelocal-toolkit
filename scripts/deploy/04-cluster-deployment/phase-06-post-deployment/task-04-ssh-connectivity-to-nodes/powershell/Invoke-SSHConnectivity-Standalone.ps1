#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone: deploys the WindowsOpenSSH Arc extension and configures
    Azure Arc SSH (HybridConnectivity) on Azure Local cluster nodes
    without requiring the toolkit YAML config.
#>

[CmdletBinding(SupportsShouldProcess)]
param([switch]$WhatIf)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region CONFIGURATION -----------------------------------------------------------
# Replace all values for your environment.
# Example values use the fictional "Infinite Improbability Corp" (prefix: iic).

# Azure subscription ID containing the Arc-enrolled nodes
[string]$SubscriptionId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

# Resource group containing the Arc machine resources
[string]$ArcResourceGroup = 'rg-iic01-azl-eus-01'

# Azure region of the Arc resource group (must match Arc machine region)
[string]$Location = 'eastus'

# SSH port (almost always 22)
[int]$SshdPort = 22

# Arc machine names (must match the HybridCompute machine resource names in Azure)
[string[]]$ArcMachineNames = @(
    'iic-01-n01',
    'iic-01-n02'
)
#endregion

#region LOGGING -----------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[{0}] [{1,-5}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    $color = switch ($Level) {
        "ERROR" { "Red" }; "WARN" { "Yellow" }; "OK" { "Green" }; default { "Cyan" }
    }
    Write-Host $entry -ForegroundColor $color
}
#endregion

Write-Log "SSH Connectivity — Standalone"
Write-Log "Subscription : $SubscriptionId"
Write-Log "Arc RG       : $ArcResourceGroup"
Write-Log "Nodes        : $($ArcMachineNames -join ', ')"
if ($WhatIf) { Write-Log "[WHATIF MODE — no changes will be made]" -Level "WARN" }

#region AZ CLI CHECK ------------------------------------------------------------
$azSub = az account show --query id -o tsv 2>$null
if (-not $azSub) {
    Write-Log "Azure CLI not authenticated. Run: az login --use-device-code" -Level "ERROR"
    throw "az not authenticated"
}
if (-not $WhatIf) { az account set --subscription $SubscriptionId | Out-Null }
Write-Log "Azure CLI context: $SubscriptionId" -Level "OK"
#endregion

#region HYBRIDCONNECTIVITY RP ---------------------------------------------------
Write-Log "Checking HybridConnectivity RP registration"
if (-not $WhatIf) {
    $rpState = az provider show -n Microsoft.HybridConnectivity --query registrationState -o tsv 2>$null
    if ($rpState -ne 'Registered') {
        Write-Log "Registering Microsoft.HybridConnectivity — waiting up to 5 minutes"
        az provider register -n Microsoft.HybridConnectivity | Out-Null
        $retries = 0
        do {
            Start-Sleep 15
            $rpState = az provider show -n Microsoft.HybridConnectivity --query registrationState -o tsv 2>$null
            Write-Log "  RP state: $rpState (attempt $($retries+1)/20)"
            $retries++
        } until ($rpState -eq 'Registered' -or $retries -ge 20)
        if ($rpState -ne 'Registered') { throw "HybridConnectivity RP registration timed out" }
    }
    Write-Log "HybridConnectivity RP: Registered" -Level "OK"
} else {
    Write-Log "[WHATIF] Would register HybridConnectivity RP if not already registered"
}
#endregion

#region PROCESS NODES -----------------------------------------------------------
foreach ($machineName in $ArcMachineNames) {
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Log "Node: $machineName"

    # Step 1 — Deploy WindowsOpenSSH extension
    Write-Log "[$machineName] Step 1/3 — Deploy WindowsOpenSSH Arc extension"
    if (-not $WhatIf) {
        try {
            $extState = az connectedmachine extension show `
                --resource-group $ArcResourceGroup --machine-name $machineName `
                --name "WindowsOpenSSH" --query "properties.provisioningState" -o tsv 2>$null

            if ($extState -eq 'Succeeded') {
                Write-Log "[$machineName]   Already installed" "PASS"
            } else {
                Write-Log "[$machineName]   Installing (2-3 minutes)..."
                az connectedmachine extension create `
                    --resource-group $ArcResourceGroup `
                    --machine-name   $machineName `
                    --name           "WindowsOpenSSH" `
                    --publisher      "Microsoft.Azure.OpenSSH" `
                    --type           "WindowsOpenSSH" `
                    --location       $Location | Out-Null

                $retries = 0
                do {
                    Start-Sleep 20
                    $extState = az connectedmachine extension show `
                        --resource-group $ArcResourceGroup --machine-name $machineName `
                        --name "WindowsOpenSSH" --query "properties.provisioningState" -o tsv 2>$null
                    Write-Log "[$machineName]   State: $extState (attempt $($retries+1)/15)"
                    $retries++
                } until ($extState -in @('Succeeded','Failed') -or $retries -ge 15)

                Write-Log "[$machineName]   Extension: $extState" -Level $(if ($extState -eq 'Succeeded') {"OK"} else {"ERROR"})
            }
        } catch {
            Write-Log "[$machineName] Extension install failed: $($_.Exception.Message)" -Level "ERROR"
        }
    } else {
        Write-Log "[$machineName] [WHATIF] Would deploy WindowsOpenSSH extension"
    }

    # Step 2 — HybridConnectivity endpoint
    Write-Log "[$machineName] Step 2/3 — Create HybridConnectivity default endpoint"
    $epUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroup/providers/Microsoft.HybridCompute/machines/$machineName/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15"
    if (-not $WhatIf) {
        try {
            $epTmp = [IO.Path]::GetTempFileName()
            '{"properties":{"type":"default"}}' | Set-Content $epTmp -Encoding utf8 -NoNewline
            $epOut = az rest --method put --uri $epUri `
                --headers "Content-Type=application/json" `
                --body "@$epTmp" 2>&1
            Remove-Item $epTmp -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) { throw ($epOut | Out-String).Trim() }
            Write-Log "[$machineName]   Endpoint created/verified" "PASS"
        } catch {
            Write-Log "[$machineName] Endpoint PUT failed: $($_.Exception.Message)" "FAIL"
        }
    } else { Write-Log "[$machineName] [WHATIF] Would PUT: $epUri" }

    # Step 3 — SSH service config
    Write-Log "[$machineName] Step 3/3 — Configure SSH service on endpoint (port $SshdPort)"
    $svcUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroup/providers/Microsoft.HybridCompute/machines/$machineName/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15"
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
            Write-Log "[$machineName]   SSH service enabled on port $SshdPort" "PASS"
        } catch {
            Write-Log "[$machineName] SSH service config failed: $($_.Exception.Message)" "FAIL"
        }
    } else { Write-Log "[$machineName] [WHATIF] Would PUT SSH service config (port $SshdPort)" }
}
#endregion

Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Log "Done. Connect with: az ssh arc --resource-group $ArcResourceGroup --name <node> --local-user <user>" -Level "OK"
