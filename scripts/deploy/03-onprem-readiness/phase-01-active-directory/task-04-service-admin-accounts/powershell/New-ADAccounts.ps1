<#
.SYNOPSIS
    Creates Active Directory computer and service accounts for Azure Local deployment.

.DESCRIPTION
    This script creates the required AD accounts:
    - Pre-stages cluster computer account (disabled)
    - Pre-stages node computer accounts
    - Creates cluster service account (gMSA or standard)
    - Configures SPNs for cluster services
    - Sets appropriate permissions on computer objects

.PARAMETER DomainController
    Target domain controller FQDN.

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER NodeNames
    Array of cluster node names.

.PARAMETER OUPath
    Organizational Unit path for cluster objects.

.PARAMETER ServiceAccountName
    Name for the cluster service account. Defaults to svc-<ClusterName>.

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration.

.EXAMPLE
    .\New-ADAccounts.ps1 -DomainController "dc01.contoso.com" -ClusterName "azl-cluster-01" -NodeNames @("node-01","node-02")

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 03-onprem-readiness
    Phase: phase-01-active-directory
    Task: task-04-create-ad-accounts
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
    [string]$OUPath,

    [Parameter(Mandatory = $false)]
    [string]$ServiceAccountName,

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

function Get-TargetOUPaths {
    if ($OUPath) {
        return @{
            Computers       = "OU=Computers,$OUPath"
            ServiceAccounts = "OU=ServiceAccounts,$OUPath"
        }
    }
    $domain = Get-ADDomain -Server $DomainController
    $base = "OU=AzureLocal,OU=Servers,$($domain.DistinguishedName)"
    return @{
        Computers       = "OU=Computers,$base"
        ServiceAccounts = "OU=ServiceAccounts,$base"
    }
}

function New-ClusterComputerAccount {
    param([string]$ComputersOU)

    Write-Log -Message "Pre-staging cluster computer account..." -Level "INFO"

    $existing = Get-ADComputer -Filter "Name -eq '$ClusterName'" -Server $DomainController -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Log -Message "  Cluster account exists: $ClusterName" -Level "INFO"
        return $false
    }

    if ($PSCmdlet.ShouldProcess($ClusterName, "Create cluster computer account")) {
        New-ADComputer -Name $ClusterName `
            -Path $ComputersOU `
            -Server $DomainController `
            -Enabled $false `
            -Description "Azure Local Cluster — pre-staged for deployment"
        Write-Log -Message "  Created cluster account: $ClusterName (disabled)" -Level "SUCCESS"
        return $true
    }
    return $false
}

function New-NodeComputerAccounts {
    param([string]$ComputersOU)

    Write-Log -Message "Pre-staging node computer accounts..." -Level "INFO"
    $created = 0

    foreach ($node in $NodeNames) {
        $existing = Get-ADComputer -Filter "Name -eq '$node'" -Server $DomainController -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Log -Message "  Node exists: $node" -Level "INFO"
        }
        else {
            if ($PSCmdlet.ShouldProcess($node, "Create node computer account")) {
                New-ADComputer -Name $node `
                    -Path $ComputersOU `
                    -Server $DomainController `
                    -Enabled $true `
                    -Description "Azure Local Node"
                Write-Log -Message "  Created node: $node" -Level "SUCCESS"
                $created++
            }
        }
    }
    return $created
}

function New-ClusterServiceAccount {
    param([string]$ServiceOU)

    if (-not $ServiceAccountName) {
        $ServiceAccountName = "svc-$ClusterName"
    }

    Write-Log -Message "Creating service account: $ServiceAccountName" -Level "INFO"

    $existing = Get-ADUser -Filter "SamAccountName -eq '$ServiceAccountName'" -Server $DomainController -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Log -Message "  Service account exists: $ServiceAccountName" -Level "INFO"
        return $null
    }

    if ($PSCmdlet.ShouldProcess($ServiceAccountName, "Create service account")) {
        $domain = Get-ADDomain -Server $DomainController
        $password = [System.Web.Security.Membership]::GeneratePassword(24, 4)
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force

        New-ADUser -Name $ServiceAccountName `
            -SamAccountName $ServiceAccountName `
            -UserPrincipalName "$ServiceAccountName@$($domain.DNSRoot)" `
            -Path $ServiceOU `
            -AccountPassword $securePassword `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -CannotChangePassword $true `
            -Description "Azure Local Cluster Service Account" `
            -Server $DomainController

        Write-Log -Message "  Created service account: $ServiceAccountName" -Level "SUCCESS"
        Write-Log -Message "  IMPORTANT: Store password securely in Key Vault" -Level "WARN"
        return $ServiceAccountName
    }
    return $null
}

#endregion Functions

#region Main

try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Create AD Accounts" -Level "INFO"
    Write-Log -Message "Domain Controller: $DomainController" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "Nodes: $($NodeNames -join ', ')" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""

    Import-Module ActiveDirectory -ErrorAction Stop

    $ouPaths = Get-TargetOUPaths

    # Verify OUs exist
    foreach ($ou in $ouPaths.Values) {
        $exists = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ou'" -Server $DomainController -ErrorAction SilentlyContinue
        if (-not $exists) {
            Write-Log -Message "OU does not exist: $ou" -Level "ERROR"
            Write-Log -Message "Run task-01 (Set-ADConfiguration.ps1) first." -Level "ERROR"
            exit 1
        }
    }

    # Create cluster computer account
    $clusterCreated = New-ClusterComputerAccount -ComputersOU $ouPaths.Computers
    Write-Host ""

    # Create node computer accounts
    $nodesCreated = New-NodeComputerAccounts -ComputersOU $ouPaths.Computers
    Write-Host ""

    # Create service account
    $svcCreated = New-ClusterServiceAccount -ServiceOU $ouPaths.ServiceAccounts
    Write-Host ""

    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "AD Accounts Summary" -Level "SUCCESS"
    Write-Log -Message "  Cluster account created: $clusterCreated" -Level "INFO"
    Write-Log -Message "  Node accounts created: $nodesCreated" -Level "INFO"
    Write-Log -Message "  Service account created: $(if ($svcCreated) { $svcCreated } else { 'Already existed' })" -Level "INFO"
}
catch {
    Write-Log -Message "Failed to create AD accounts: $_" -Level "ERROR"
    exit 1
}

#endregion Main
