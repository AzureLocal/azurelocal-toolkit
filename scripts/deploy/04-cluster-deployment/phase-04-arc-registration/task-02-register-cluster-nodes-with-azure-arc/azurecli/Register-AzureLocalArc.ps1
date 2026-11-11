#Requires -Version 7.0
# Task 02 - Register Nodes with Azure Arc via Azure CLI (orchestrated)
# infrastructure.yml variables:
#   azure.tenant_id                        -> $TenantId
#   azure.subscription_id                  -> $SubscriptionId
#   azure.resource_group                   -> $ResourceGroup
#   azure.location                         -> $Region
#   scenario.outbound_path and networking.outbound.arc_gateway (name, resource_group) -> $ArcGatewayId
#   azure.automation_identity.client_id    -> $SpnId
#   nodes[].name            -> $NodeNames

$ConfigPath = ".\configs\infrastructure.yml"
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
$cfg        = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$gateway    = Get-AzlArcGateway -Infrastructure $cfg

$TenantId       = $cfg.azure.tenant_id
$SubscriptionId = $cfg.azure.subscription_id
$ResourceGroup  = $cfg.azure.resource_group
$Region         = $cfg.azure.location
$ArcGatewayId   = $gateway.Id
$SpnId          = $cfg['azure']?['automation_identity']?['client_id']
$NodeNames      = @(Get-AzlInfrastructureNode -Infrastructure $cfg | ForEach-Object { $_.Name })

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
