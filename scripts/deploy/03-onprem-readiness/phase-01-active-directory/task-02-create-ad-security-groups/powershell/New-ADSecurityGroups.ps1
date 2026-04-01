<#
.SYNOPSIS
    Creates Active Directory security groups for Azure Local cluster management.

.DESCRIPTION
    This script creates the required AD security groups:
    - Cluster Administrators group
    - Cluster Operators group
    - Azure Arc management group
    - Storage Administrators group
    - Validates group creation and sets descriptions

.PARAMETER DomainController
    Target domain controller FQDN.

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER OUPath
    Organizational Unit path for group objects.

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration.

.EXAMPLE
    .\New-ADSecurityGroups.ps1 -DomainController "dc01.contoso.com" -ClusterName "azl-cluster-01"

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 03-onprem-readiness
    Phase: phase-01-active-directory
    Task: task-02-create-ad-security-groups
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainController,

    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

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

# Load config if provided
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    if (Test-Path (Join-Path $HelpersPath "config-loader.ps1")) {
        . (Join-Path $HelpersPath "config-loader.ps1")
        $Config = Get-Config -ConfigPath $ConfigFile
    }
}

#region Functions

function Get-GroupsOUPath {
    param([string]$BaseOU)
    if ($BaseOU) {
        return "OU=Groups,$BaseOU"
    }
    $domain = Get-ADDomain -Server $DomainController
    return "OU=Groups,OU=AzureLocal,OU=Servers,$($domain.DistinguishedName)"
}

function New-ClusterSecurityGroups {
    param([string]$GroupsOU)

    $groups = @(
        @{ Name = "GRP-$ClusterName-Admins";          Scope = 'Global'; Description = "Azure Local Cluster Administrators — full cluster management" }
        @{ Name = "GRP-$ClusterName-Operators";        Scope = 'Global'; Description = "Azure Local Cluster Operators — day-to-day operations" }
        @{ Name = "GRP-$ClusterName-ArcManagement";    Scope = 'Global'; Description = "Azure Arc management for $ClusterName" }
        @{ Name = "GRP-$ClusterName-StorageAdmins";    Scope = 'Global'; Description = "Storage Spaces Direct administrators for $ClusterName" }
        @{ Name = "GRP-$ClusterName-ReadOnly";         Scope = 'Global'; Description = "Read-only access to $ClusterName" }
    )

    $created = 0
    $existing = 0

    foreach ($group in $groups) {
        $found = Get-ADGroup -Filter "Name -eq '$($group.Name)'" -Server $DomainController -ErrorAction SilentlyContinue

        if ($found) {
            Write-Log -Message "  Group exists: $($group.Name)" -Level "INFO"
            $existing++
        }
        else {
            if ($PSCmdlet.ShouldProcess($group.Name, "Create AD Security Group")) {
                New-ADGroup -Name $group.Name `
                    -GroupScope $group.Scope `
                    -GroupCategory Security `
                    -Path $GroupsOU `
                    -Description $group.Description `
                    -Server $DomainController
                Write-Log -Message "  Created group: $($group.Name)" -Level "SUCCESS"
                $created++
            }
        }
    }

    return @{ Created = $created; Existing = $existing; Total = $groups.Count }
}

#endregion Functions

#region Main

try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Create AD Security Groups" -Level "INFO"
    Write-Log -Message "Domain Controller: $DomainController" -Level "INFO"
    Write-Log -Message "Cluster Name: $ClusterName" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""

    Import-Module ActiveDirectory -ErrorAction Stop

    $groupsOU = Get-GroupsOUPath -BaseOU $OUPath

    # Verify OU exists
    $ouExists = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$groupsOU'" -Server $DomainController -ErrorAction SilentlyContinue
    if (-not $ouExists) {
        Write-Log -Message "Groups OU does not exist: $groupsOU" -Level "ERROR"
        Write-Log -Message "Run task-01 (Set-ADConfiguration.ps1) first to create OU structure." -Level "ERROR"
        exit 1
    }

    $result = New-ClusterSecurityGroups -GroupsOU $groupsOU
    Write-Host ""

    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Security Groups Summary" -Level "SUCCESS"
    Write-Log -Message "  Total defined: $($result.Total)" -Level "INFO"
    Write-Log -Message "  Created: $($result.Created)" -Level "INFO"
    Write-Log -Message "  Already existed: $($result.Existing)" -Level "INFO"
}
catch {
    Write-Log -Message "Failed to create security groups: $_" -Level "ERROR"
    exit 1
}

#endregion Main
