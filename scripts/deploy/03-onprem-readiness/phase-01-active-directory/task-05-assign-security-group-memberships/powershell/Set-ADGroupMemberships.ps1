<#
.SYNOPSIS
    Assigns security group memberships for Azure Local cluster accounts.

.DESCRIPTION
    This script assigns AD security group memberships:
    - Adds node computer accounts to cluster security groups
    - Adds service account to required groups
    - Assigns deployment user to admin groups
    - Validates all membership assignments

.PARAMETER DomainController
    Target domain controller FQDN.

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER NodeNames
    Array of cluster node names.

.PARAMETER DeploymentUser
    SAM account name of the deployment administrator.

.PARAMETER OUPath
    Organizational Unit path for group objects.

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration.

.EXAMPLE
    .\Set-ADGroupMemberships.ps1 -DomainController "dc01.contoso.com" -ClusterName "azl-cluster-01" -NodeNames @("node-01","node-02") -DeploymentUser "admin-deploy"

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 03-onprem-readiness
    Phase: phase-01-active-directory
    Task: task-05-assign-security-group-memberships
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainController,

    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $true)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [string]$DeploymentUser,

    [Parameter(Mandatory = $false)]
    [string]$OUPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile
)

#Requires -Version 7.0
#Requires -Modules ActiveDirectory

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import helpers
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\..\common\utilities\helpers"

if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $color = switch ($Level) {
            "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }
        }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
    }
}

#region Functions

function Add-MemberToGroup {
    param(
        [string]$GroupName,
        [string]$MemberName,
        [ValidateSet('Computer', 'User')]
        [string]$MemberType
    )

    $group = Get-ADGroup -Filter "Name -eq '$GroupName'" -Server $DomainController -ErrorAction SilentlyContinue
    if (-not $group) {
        Write-Log -Message "  Group not found: $GroupName — run task-02 first" -Level "ERROR"
        return $false
    }

    if ($MemberType -eq 'Computer') {
        $member = Get-ADComputer -Filter "Name -eq '$MemberName'" -Server $DomainController -ErrorAction SilentlyContinue
    }
    else {
        $member = Get-ADUser -Filter "SamAccountName -eq '$MemberName'" -Server $DomainController -ErrorAction SilentlyContinue
    }

    if (-not $member) {
        Write-Log -Message "  Member not found: $MemberName ($MemberType)" -Level "WARN"
        return $false
    }

    $isMember = Get-ADGroupMember -Identity $group -Server $DomainController |
        Where-Object { $_.SamAccountName -eq $member.SamAccountName }

    if ($isMember) {
        Write-Log -Message "  $MemberName already in $GroupName" -Level "INFO"
        return $true
    }

    if ($PSCmdlet.ShouldProcess("$MemberName -> $GroupName", "Add group membership")) {
        Add-ADGroupMember -Identity $group -Members $member -Server $DomainController
        Write-Log -Message "  Added $MemberName to $GroupName" -Level "SUCCESS"
        return $true
    }
    return $false
}

function Set-NodeGroupMemberships {
    Write-Log -Message "Assigning node computer accounts to groups..." -Level "INFO"

    $operatorsGroup = "GRP-$ClusterName-Operators"

    foreach ($node in $NodeNames) {
        Add-MemberToGroup -GroupName $operatorsGroup -MemberName $node -MemberType 'Computer'
    }
}

function Set-ServiceAccountMemberships {
    $serviceAccountName = "svc-$ClusterName"
    Write-Log -Message "Assigning service account memberships..." -Level "INFO"

    $groups = @("GRP-$ClusterName-Admins")
    foreach ($group in $groups) {
        Add-MemberToGroup -GroupName $group -MemberName $serviceAccountName -MemberType 'User'
    }
}

function Set-DeploymentUserMemberships {
    if (-not $DeploymentUser) {
        Write-Log -Message "No deployment user specified — skipping." -Level "INFO"
        return
    }

    Write-Log -Message "Assigning deployment user memberships..." -Level "INFO"

    $groups = @("GRP-$ClusterName-Admins", "GRP-$ClusterName-ArcManagement")
    foreach ($group in $groups) {
        Add-MemberToGroup -GroupName $group -MemberName $DeploymentUser -MemberType 'User'
    }
}

function Show-GroupMemberships {
    Write-Log -Message "Current group memberships:" -Level "INFO"

    $groupNames = @(
        "GRP-$ClusterName-Admins",
        "GRP-$ClusterName-Operators",
        "GRP-$ClusterName-ArcManagement",
        "GRP-$ClusterName-StorageAdmins",
        "GRP-$ClusterName-ReadOnly"
    )

    foreach ($groupName in $groupNames) {
        $group = Get-ADGroup -Filter "Name -eq '$groupName'" -Server $DomainController -ErrorAction SilentlyContinue
        if ($group) {
            $members = Get-ADGroupMember -Identity $group -Server $DomainController -ErrorAction SilentlyContinue
            $memberList = if ($members) { ($members.SamAccountName -join ', ') } else { '(empty)' }
            Write-Log -Message "  $groupName : $memberList" -Level "INFO"
        }
    }
}

#endregion Functions

#region Main

try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Assign Security Group Memberships" -Level "INFO"
    Write-Log -Message "Domain Controller: $DomainController" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "Nodes: $($NodeNames -join ', ')" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""

    Import-Module ActiveDirectory -ErrorAction Stop

    Set-NodeGroupMemberships
    Write-Host ""

    Set-ServiceAccountMemberships
    Write-Host ""

    Set-DeploymentUserMemberships
    Write-Host ""

    Show-GroupMemberships
    Write-Host ""

    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Group Membership Assignment Complete" -Level "SUCCESS"
}
catch {
    Write-Log -Message "Failed to assign group memberships: $_" -Level "ERROR"
    exit 1
}

#endregion Main
