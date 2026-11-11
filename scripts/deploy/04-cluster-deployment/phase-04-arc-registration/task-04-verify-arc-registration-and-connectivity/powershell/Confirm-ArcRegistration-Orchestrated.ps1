#Requires -Version 7.0
# Task 04 - Verify Arc Registration (orchestrated from management server)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ConfigPath = ".\configs\infrastructure.yml"
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

$ServerList     = @(Get-AzlInfrastructureNode -Infrastructure $cfg | ForEach-Object { $_.ManagementIp } | Where-Object { $_ })
$ResourceGroup  = $cfg.azure.resource_group
$SubscriptionId = $cfg.azure.subscription_id

# 1. Check local Arc agent on every node
Write-Host "`n--- Local Agent Status ---" -ForegroundColor Cyan
Invoke-Command -ComputerName $ServerList -ScriptBlock {
    $svc   = Get-Service himds -ErrorAction SilentlyContinue
    $agent = & "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show 2>&1
    $status = ($agent | Select-String 'Agent Status\s*:\s*(.+)').Matches[0].Groups[1].Value.Trim()
    [PSCustomObject]@{ Service = $svc.Status; AgentStatus = $status }
} | Sort-Object PSComputerName | Format-Table PSComputerName, Service, AgentStatus -AutoSize

# 2. Check Azure-side resource status
Write-Host "--- Azure Resource Status ---" -ForegroundColor Cyan
Connect-AzAccount -SubscriptionId $SubscriptionId | Out-Null
Get-AzConnectedMachine -ResourceGroupName $ResourceGroup |
    Select-Object Name, Status, AgentVersion, LastStatusChange |
    Format-Table -AutoSize
