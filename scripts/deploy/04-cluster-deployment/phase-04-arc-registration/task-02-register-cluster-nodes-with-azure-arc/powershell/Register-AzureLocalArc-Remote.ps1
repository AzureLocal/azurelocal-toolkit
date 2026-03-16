# Task 02 - Register Nodes with Azure Arc (orchestrated, all nodes)
# infrastructure.yml variables:
#   azure.tenant_id         -> $TenantId
#   azure.subscription_id   -> $SubscriptionId
#   azure.resource_group    -> $ResourceGroup
#   azure.region            -> $Region
#   azure.arc_gateway_id    -> $ArcGatewayId
#   azure.spn_id            -> $SpnId
#   cluster_nodes[].management_ip  -> $ServerList

$ConfigPath = ".\configs\infrastructure.yml"
$cfg        = Get-Content $ConfigPath

$TenantId       = ($cfg | Select-String 'tenant_id:\s+"?([^"'' ]+)'     | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$SubscriptionId = ($cfg | Select-String 'subscription_id:\s+"?([^"'' ]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$ResourceGroup  = ($cfg | Select-String 'resource_group:\s+"?([^"'' ]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$Region         = ($cfg | Select-String 'region:\s+"?([^"'' ]+)'         | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$ArcGatewayId   = ($cfg | Select-String 'arc_gateway_id:\s+"?([^"'' ]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$SpnId          = ($cfg | Select-String 'spn_id:\s+"?([^"'' ]+)'         | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$ServerList     = ($cfg | Select-String 'management_ip:\s+"?([^"'' ]+)'  | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })

$Cloud = "AzureCloud"

# SPN secret — prompt securely (not stored in YAML)
$SpnSecret = Read-Host "Enter SPN secret" -AsPlainText

# Authenticate with service principal
$SecurePassword = ConvertTo-SecureString $SpnSecret -AsPlainText -Force
$SpnCredential  = New-Object System.Management.Automation.PSCredential($SpnId, $SecurePassword)
Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $SpnCredential -SubscriptionId $SubscriptionId

$ArmToken  = (Get-AzAccessToken).Token
$AccountId = $SpnId

# Register each node
Invoke-Command ($ServerList) {
    param($Sub, $RG, $Tenant, $Reg, $Cld, $Token, $Acct, $GwId)
    Invoke-AzStackHciArcInitialization `
        -SubscriptionID $Sub `
        -ResourceGroup  $RG `
        -TenantID       $Tenant `
        -Region         $Reg `
        -Cloud          $Cld `
        -ArmAccessToken $Token `
        -AccountID      $Acct `
        -ArcGatewayID   $GwId
} -ArgumentList $SubscriptionId, $ResourceGroup, $TenantId, $Region, $Cloud, $ArmToken, $AccountId, $ArcGatewayId |
    Sort -Property PsComputerName
