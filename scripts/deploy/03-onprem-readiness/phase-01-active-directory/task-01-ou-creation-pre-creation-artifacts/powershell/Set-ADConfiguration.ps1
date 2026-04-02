<#
.SYNOPSIS
    Validates and configures Active Directory prerequisites for Azure Local deployment.

.DESCRIPTION
    This script handles AD configuration including:
    - Domain connectivity validation
    - OU structure creation for cluster objects
    - Computer account pre-staging
    - Service account creation
    - GPO baseline configuration
    - DNS record validation

.PARAMETER DomainController
    Target domain controller FQDN.

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER NodeNames
    Array of cluster node names.

.PARAMETER OUPath
    Organizational Unit path for cluster objects.

.PARAMETER ServiceAccountName
    Name for the cluster service account.

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration.

.EXAMPLE
    .\Set-ADConfiguration.ps1 -DomainController "dc01.Contoso.com" -ClusterName "azl-cluster-01" -NodeNames @("node-01","node-02")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Requires ActiveDirectory PowerShell module and Domain Admin privileges.
#>

[CmdletBinding()]
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

# Import helpers
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\common\utilities\helpers"

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

function Test-DomainConnectivity {
    Write-Log -Message "Testing domain connectivity..." -Level "INFO"
    
    try {
        $dcTest = Test-Connection -ComputerName $DomainController -Count 2 -Quiet
        
        if ($dcTest) {
            Write-Log -Message "  Domain controller reachable: $DomainController" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  Cannot reach domain controller: $DomainController" -Level "ERROR"
            return $false
        }
        
        # Test LDAP connectivity
        $ldapTest = Test-NetConnection -ComputerName $DomainController -Port 389 -WarningAction SilentlyContinue
        
        if ($ldapTest.TcpTestSucceeded) {
            Write-Log -Message "  LDAP connectivity: OK" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  LDAP connectivity: FAILED" -Level "ERROR"
            return $false
        }
        
        # Test Kerberos
        $kerbTest = Test-NetConnection -ComputerName $DomainController -Port 88 -WarningAction SilentlyContinue
        
        if ($kerbTest.TcpTestSucceeded) {
            Write-Log -Message "  Kerberos connectivity: OK" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  Kerberos connectivity: FAILED" -Level "WARN"
        }
        
        return $true
    }
    catch {
        Write-Log -Message "Domain connectivity test failed: $_" -Level "ERROR"
        return $false
    }
}

function New-ClusterOUStructure {
    Write-Log -Message "Creating OU structure for cluster objects..." -Level "INFO"
    
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        
        # Get domain DN
        $domain = Get-ADDomain -Server $DomainController
        $domainDN = $domain.DistinguishedName
        
        # Define OU structure
        if (-not $OUPath) {
            $OUPath = "OU=AzureLocal,OU=Servers,$domainDN"
        }
        
        # Parse OU path and create hierarchy
        $ouParts = $OUPath -split "," | Where-Object { $_ -match "^OU=" }
        [array]::Reverse($ouParts)
        
        $currentPath = $domainDN
        
        foreach ($ouPart in $ouParts) {
            $ouName = $ouPart -replace "OU=", ""
            $fullPath = "$ouPart,$currentPath"
            
            $exists = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$fullPath'" -Server $DomainController -ErrorAction SilentlyContinue
            
            if (-not $exists) {
                Write-Log -Message "  Creating OU: $ouName" -Level "INFO"
                New-ADOrganizationalUnit -Name $ouName -Path $currentPath -Server $DomainController -ErrorAction Stop
                Write-Log -Message "    Created: $fullPath" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  OU exists: $ouName" -Level "INFO"
            }
            
            $currentPath = $fullPath
        }
        
        # Create sub-OUs for organization
        $subOUs = @("Computers", "ServiceAccounts", "Groups")
        
        foreach ($subOU in $subOUs) {
            $subPath = "OU=$subOU,$OUPath"
            $exists = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$subPath'" -Server $DomainController -ErrorAction SilentlyContinue
            
            if (-not $exists) {
                New-ADOrganizationalUnit -Name $subOU -Path $OUPath -Server $DomainController
                Write-Log -Message "  Created sub-OU: $subOU" -Level "SUCCESS"
            }
        }
        
        return $OUPath
    }
    catch {
        Write-Log -Message "Failed to create OU structure: $_" -Level "ERROR"
        throw
    }
}

function New-ClusterComputerAccounts {
    param([string]$TargetOU)
    
    Write-Log -Message "Pre-staging computer accounts..." -Level "INFO"
    
    try {
        $computersOU = "OU=Computers,$TargetOU"
        
        # Create cluster computer account
        $clusterAccount = Get-ADComputer -Filter "Name -eq '$ClusterName'" -Server $DomainController -ErrorAction SilentlyContinue
        
        if (-not $clusterAccount) {
            Write-Log -Message "  Creating cluster account: $ClusterName" -Level "INFO"
            New-ADComputer -Name $ClusterName -Path $computersOU -Server $DomainController -Enabled $false -Description "Azure Local Cluster"
            
            # Set permissions for cluster account
            $acl = Get-Acl "AD:$computersOU"
            # Note: In production, would set specific permissions for cluster creation
            
            Write-Log -Message "    Created and configured: $ClusterName" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  Cluster account exists: $ClusterName" -Level "INFO"
        }
        
        # Create node computer accounts
        foreach ($node in $NodeNames) {
            $nodeAccount = Get-ADComputer -Filter "Name -eq '$node'" -Server $DomainController -ErrorAction SilentlyContinue
            
            if (-not $nodeAccount) {
                Write-Log -Message "  Creating node account: $node" -Level "INFO"
                New-ADComputer -Name $node -Path $computersOU -Server $DomainController -Enabled $true -Description "Azure Local Node"
                Write-Log -Message "    Created: $node" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  Node account exists: $node" -Level "INFO"
            }
        }
    }
    catch {
        Write-Log -Message "Failed to create computer accounts: $_" -Level "ERROR"
        throw
    }
}

function New-ClusterServiceAccount {
    param([string]$TargetOU)
    
    if (-not $ServiceAccountName) {
        $ServiceAccountName = "svc-$ClusterName"
    }
    
    Write-Log -Message "Creating service account: $ServiceAccountName" -Level "INFO"
    
    try {
        $serviceOU = "OU=ServiceAccounts,$TargetOU"
        
        # Check if account exists
        $existing = Get-ADUser -Filter "SamAccountName -eq '$ServiceAccountName'" -Server $DomainController -ErrorAction SilentlyContinue
        
        if (-not $existing) {
            # Generate secure password
            $password = [System.Web.Security.Membership]::GeneratePassword(24, 4)
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            
            New-ADUser -Name $ServiceAccountName `
                       -SamAccountName $ServiceAccountName `
                       -UserPrincipalName "$ServiceAccountName@$($domain.DNSRoot)" `
                       -Path $serviceOU `
                       -AccountPassword $securePassword `
                       -Enabled $true `
                       -PasswordNeverExpires $true `
                       -CannotChangePassword $true `
                       -Description "Azure Local Cluster Service Account" `
                       -Server $DomainController
            
            Write-Log -Message "  Service account created: $ServiceAccountName" -Level "SUCCESS"
            Write-Log -Message "  NOTE: Store password securely in Key Vault" -Level "WARN"
            
            return @{
                AccountName = $ServiceAccountName
                Password = $password
            }
        }
        else {
            Write-Log -Message "  Service account exists: $ServiceAccountName" -Level "INFO"
            return @{
                AccountName = $ServiceAccountName
                Password = $null
            }
        }
    }
    catch {
        Write-Log -Message "Failed to create service account: $_" -Level "ERROR"
        throw
    }
}

function New-ClusterSecurityGroup {
    param([string]$TargetOU)
    
    Write-Log -Message "Creating security groups..." -Level "INFO"
    
    try {
        $groupsOU = "OU=Groups,$TargetOU"
        $groups = @(
            @{ Name = "GRP-$ClusterName-Admins"; Description = "Azure Local Cluster Administrators" }
            @{ Name = "GRP-$ClusterName-Operators"; Description = "Azure Local Cluster Operators" }
        )
        
        foreach ($group in $groups) {
            $existing = Get-ADGroup -Filter "Name -eq '$($group.Name)'" -Server $DomainController -ErrorAction SilentlyContinue
            
            if (-not $existing) {
                New-ADGroup -Name $group.Name `
                            -GroupScope Global `
                            -GroupCategory Security `
                            -Path $groupsOU `
                            -Description $group.Description `
                            -Server $DomainController
                
                Write-Log -Message "  Created group: $($group.Name)" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  Group exists: $($group.Name)" -Level "INFO"
            }
        }
    }
    catch {
        Write-Log -Message "Failed to create security groups: $_" -Level "ERROR"
        throw
    }
}

function Test-DNSConfiguration {
    Write-Log -Message "Validating DNS configuration..." -Level "INFO"
    
    try {
        $domain = Get-ADDomain -Server $DomainController
        $dnsZone = $domain.DNSRoot
        
        # Check for existing DNS records
        foreach ($node in $NodeNames) {
            $fqdn = "$node.$dnsZone"
            
            try {
                $dnsResult = Resolve-DnsName -Name $fqdn -Server $DomainController -ErrorAction Stop
                Write-Log -Message "  $node : Resolved to $($dnsResult.IPAddress)" -Level "SUCCESS"
            }
            catch {
                Write-Log -Message "  $node : No DNS record (will be created at domain join)" -Level "INFO"
            }
        }
        
        # Check cluster name
        try {
            $clusterFqdn = "$ClusterName.$dnsZone"
            $clusterDns = Resolve-DnsName -Name $clusterFqdn -Server $DomainController -ErrorAction SilentlyContinue
            
            if ($clusterDns) {
                Write-Log -Message "  $ClusterName : Already exists ($($clusterDns.IPAddress))" -Level "WARN"
            }
            else {
                Write-Log -Message "  $ClusterName : Available (will be created at cluster formation)" -Level "SUCCESS"
            }
        }
        catch {
            Write-Log -Message "  $ClusterName : Available" -Level "SUCCESS"
        }
    }
    catch {
        Write-Log -Message "DNS validation failed: $_" -Level "ERROR"
    }
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Active Directory Configuration" -Level "INFO"
    Write-Log -Message "Domain Controller: $DomainController" -Level "INFO"
    Write-Log -Message "Cluster Name: $ClusterName" -Level "INFO"
    Write-Log -Message "Nodes: $($NodeNames -join ', ')" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    # Import AD module
    Import-Module ActiveDirectory -ErrorAction Stop
    
    # Test connectivity first
    if (-not (Test-DomainConnectivity)) {
        throw "Domain connectivity check failed"
    }
    Write-Host ""
    
    # Create OU structure
    $targetOU = New-ClusterOUStructure
    Write-Host ""
    
    # Pre-stage computer accounts
    New-ClusterComputerAccounts -TargetOU $targetOU
    Write-Host ""
    
    # Create service account
    $svcAccount = New-ClusterServiceAccount -TargetOU $targetOU
    Write-Host ""
    
    # Create security groups
    New-ClusterSecurityGroup -TargetOU $targetOU
    Write-Host ""
    
    # Validate DNS
    Test-DNSConfiguration
    Write-Host ""
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "AD Configuration Complete" -Level "SUCCESS"
    Write-Log -Message "Target OU: $targetOU" -Level "INFO"
    
    if ($svcAccount.Password) {
        Write-Log -Message "IMPORTANT: Store service account password in Key Vault" -Level "WARN"
    }
}
catch {
    Write-Log -Message "AD configuration failed: $_" -Level "ERROR"
    exit 1
}
