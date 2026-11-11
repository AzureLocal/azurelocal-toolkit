#Requires -Version 7.0
# Task 02 - Register Nodes with Azure Arc (orchestrated, all nodes)
# infrastructure.yml variables:
#   azure.tenant_id                        -> $TenantId
#   azure.subscription_id                  -> $SubscriptionId
#   azure.resource_group                   -> $ResourceGroup
#   azure.location                         -> $Region
#   scenario.outbound_path and networking.outbound.arc_gateway (name, resource_group) -> $ArcGatewayId
#   azure.automation_identity.client_id    -> $SpnId
#   nodes[].management.ip_address  -> $ServerList

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
$ServerList     = @(Get-AzlInfrastructureNode -Infrastructure $cfg | ForEach-Object { $_.ManagementIp } | Where-Object { $_ })

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
