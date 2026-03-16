# Task 04 - Verify Arc Registration (orchestrated from management server)

$ConfigPath = ".\configs\infrastructure.yml"
$cfg = Get-Content $ConfigPath

$ServerList     = ($cfg | Select-String 'management_ip:\s+"?([^"\s]+)' -AllMatches).Matches |
    ForEach-Object { $_.Groups[1].Value }
$ResourceGroup  = ($cfg | Select-String 'resource_group:\s+"?([^"\s]+)').Matches[0].Groups[1].Value
$SubscriptionId = ($cfg | Select-String 'subscription_id:\s+"?([^"\s]+)').Matches[0].Groups[1].Value

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
