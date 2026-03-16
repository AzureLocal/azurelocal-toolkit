# Task 02 - Register Node with Azure Arc (run on each node)

$TenantId       = "REPLACE_TENANT_ID"
$SubscriptionId = "REPLACE_SUBSCRIPTION_ID"
$ResourceGroup  = "REPLACE_RESOURCE_GROUP"
$Region         = "REPLACE_REGION"
$Cloud          = "AzureCloud"
$ArcGatewayId   = "REPLACE_ARC_GATEWAY_ID"
$SpnId          = "REPLACE_SPN_ID"
$SpnSecret      = "REPLACE_SPN_SECRET"

if ($TenantId -match '^REPLACE_') { throw 'Edit the REPLACE_ variables before running.' }

# Authenticate with service principal
$SecurePassword = ConvertTo-SecureString $SpnSecret -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($SpnId, $SecurePassword)
Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $Credential -SubscriptionId $SubscriptionId

# Get ARM access token
$ArmToken  = (Get-AzAccessToken).Token
$AccountId = $SpnId

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
