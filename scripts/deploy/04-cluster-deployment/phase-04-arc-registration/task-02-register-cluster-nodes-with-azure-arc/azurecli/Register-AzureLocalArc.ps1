# Task 02 - Register Nodes with Azure Arc via Azure CLI (orchestrated)
# infrastructure.yml variables:
#   azure.tenant_id         -> $TenantId
#   azure.subscription_id   -> $SubscriptionId
#   azure.resource_group    -> $ResourceGroup
#   azure.region            -> $Region
#   azure.arc_gateway_id    -> $ArcGatewayId
#   azure.spn_id            -> $SpnId
#   cluster_nodes[].hostname -> $NodeNames

$ConfigPath = ".\configs\infrastructure.yml"
$cfg        = Get-Content $ConfigPath

$TenantId       = ($cfg | Select-String 'tenant_id:\s+"?([^"'' ]+)'     | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$SubscriptionId = ($cfg | Select-String 'subscription_id:\s+"?([^"'' ]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$ResourceGroup  = ($cfg | Select-String 'resource_group:\s+"?([^"'' ]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$Region         = ($cfg | Select-String 'region:\s+"?([^"'' ]+)'         | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$ArcGatewayId   = ($cfg | Select-String 'arc_gateway_id:\s+"?([^"'' ]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$SpnId          = ($cfg | Select-String 'spn_id:\s+"?([^"'' ]+)'         | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }) | Select-Object -First 1
$NodeNames      = ($cfg | Select-String 'hostname:\s+"?([^"'' ]+)'       | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })

$SpnSecret = Read-Host "Enter SPN secret" -AsPlainText

az login --service-principal --username $SpnId --password $SpnSecret --tenant $TenantId
az account set --subscription $SubscriptionId

foreach ($Node in $NodeNames) {
    az connectedmachine connect `
        --name $Node `
        --resource-group $ResourceGroup `
        --location $Region `
        --subscription $SubscriptionId `
        --cloud "AzureCloud" `
        --correlation-id ([guid]::NewGuid().ToString()) `
        --gateway-id $ArcGatewayId
}

az connectedmachine list --resource-group $ResourceGroup --output table
