# Task 02 - Register Node with Azure Arc via Device Code (run on each node, lab/test only)

$TenantId       = "REPLACE_TENANT_ID"
$SubscriptionId = "REPLACE_SUBSCRIPTION_ID"
$ResourceGroup  = "REPLACE_RESOURCE_GROUP"
$Region         = "REPLACE_REGION"
$Cloud          = "AzureCloud"
$ArcGatewayId   = "REPLACE_ARC_GATEWAY_ID"

if ($TenantId -match '^REPLACE_') { throw 'Edit the REPLACE_ variables before running.' }

# Authenticate interactively with device code
Connect-AzAccount -TenantId $TenantId -SubscriptionId $SubscriptionId -DeviceCode

# Get ARM access token
$ArmToken  = (Get-AzAccessToken).Token
$AccountId = (Get-AzContext).Account.Id

# Register this node with Arc
Invoke-AzStackHciArcInitialization `
    -SubscriptionID $SubscriptionId `
    -ResourceGroup  $ResourceGroup `
    -TenantID       $TenantId `
    -Region         $Region `
    -Cloud          $Cloud `
    -ArmAccessToken $ArmToken `
    -AccountID      $AccountId `
    -ArcGatewayID   $ArcGatewayId
