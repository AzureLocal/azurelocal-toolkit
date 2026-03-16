<#
.SYNOPSIS
    Assigns required RBAC roles to a principal (SPN or user) for Azure Local automation deployment.
.DESCRIPTION
    Assigns subscription-level and resource group-level RBAC roles needed for Azure Local deployment. Reads all values from infrastructure.yml or parameters. No hardcoded values.
.PARAMETER PrincipalId
    The objectId of the principal (SPN or user) to assign roles to.
.PARAMETER SubscriptionId
    The Azure subscription ID.
.PARAMETER ResourceGroupName
    The resource group name for resource group-level roles.
.PARAMETER SubscriptionRoles
    Array of role names to assign at the subscription scope.
.PARAMETER ResourceGroupRoles
    Array of role names to assign at the resource group scope.
.EXAMPLE
    .\Assign-AzureLocalRBAC.ps1 -PrincipalId <objectId> -SubscriptionId <subId> -ResourceGroupName <rg> -SubscriptionRoles @('Contributor') -ResourceGroupRoles @('Key Vault Contributor')
.NOTES
    No hardcoded variables. All values are parameters or config-driven.
#>
param(
    [Parameter(Mandatory)]
    [string]$PrincipalId,
    [Parameter(Mandatory)]
    [string]$SubscriptionId,
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory)]
    [string[]]$SubscriptionRoles,
    [Parameter(Mandatory)]
    [string[]]$ResourceGroupRoles
)

Write-Host "Assigning RBAC roles to $PrincipalId..." -ForegroundColor Cyan

$subScope = "/subscriptions/$SubscriptionId"
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

foreach ($role in $SubscriptionRoles) {
    Write-Host "  Assigning $role at subscription..." -ForegroundColor Yellow
    $exists = Get-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $role -Scope $subScope -ErrorAction SilentlyContinue
    if (-not $exists) {
        New-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $role -Scope $subScope | Out-Null
        Write-Host "  ✅ Assigned $role (subscription)" -ForegroundColor Green
    } else {
        Write-Host "  Already assigned: $role (subscription)" -ForegroundColor Gray
    }
}

foreach ($role in $ResourceGroupRoles) {
    Write-Host "  Assigning $role at resource group..." -ForegroundColor Yellow
    $exists = Get-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $role -Scope $rgScope -ErrorAction SilentlyContinue
    if (-not $exists) {
        New-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $role -Scope $rgScope | Out-Null
        Write-Host "  ✅ Assigned $role (resource group)" -ForegroundColor Green
    } else {
        Write-Host "  Already assigned: $role (resource group)" -ForegroundColor Gray
    }
}

Write-Host "RBAC roles assigned successfully." -ForegroundColor Green
