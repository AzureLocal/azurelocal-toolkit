<#
.SYNOPSIS
    Configures SSH access for Azure Local nodes.

.DESCRIPTION
    This script configures SSH server on Azure Local nodes:
    - Enables OpenSSH Server feature
    - Configures SSH server settings
    - Sets up key-based authentication
    - Configures firewall rules

.PARAMETER NodeNames
    Array of node hostnames.

.PARAMETER Credential
    Credentials for node access.

.PARAMETER PublicKeyPath
    Path to SSH public key for key-based auth.

.EXAMPLE
    .\Enable-SshConfiguration.ps1 -NodeNames @("node01", "node02")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-16-security-configuration/step-02-ssh-configuration
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$PublicKeyPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$EnableKeyAuth,

    [Parameter(Mandatory = $false)]
    [switch]$DisablePasswordAuth
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Functions

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    [CmdletBinding()]
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $null }

    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    $configContent = Get-Content -Path $Path -Raw
    return ConvertFrom-Yaml $configContent
}

function Enable-NodeSsh {
    <#
    .SYNOPSIS
        Enables and configures SSH on a node.
    #>
    [CmdletBinding()]
    param(
        [string]$NodeName,
        [pscredential]$Credential,
        [string]$PublicKey,
        [switch]$EnableKeyAuth,
        [switch]$DisablePasswordAuth
    )

    $result = @{
        NodeName     = $NodeName
        SshInstalled = $false
        SshRunning   = $false
        KeyAuthEnabled = $false
        FirewallConfigured = $false
    }

    try {
        $sessionParams = @{
            ComputerName = $NodeName
            ErrorAction  = 'Stop'
        }
        if ($Credential) {
            $sessionParams['Credential'] = $Credential
        }

        $session = New-PSSession @sessionParams

        try {
            # Install OpenSSH Server if needed
            $sshStatus = Invoke-Command -Session $session -ScriptBlock {
                $sshServer = Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH.Server*" }
                
                if ($sshServer.State -ne 'Installed') {
                    Add-WindowsCapability -Online -Name $sshServer.Name
                    return @{
                        Installed = $true
                        WasInstalled = $false
                    }
                }
                
                return @{
                    Installed = $true
                    WasInstalled = $true
                }
            }
            $result.SshInstalled = $sshStatus.Installed
            Write-LogMessage "    SSH Server: $(if($sshStatus.WasInstalled){'Already installed'}else{'Installed'})" -Level $(if($sshStatus.WasInstalled){'Info'}else{'Success'})

            # Configure and start SSH service
            $serviceStatus = Invoke-Command -Session $session -ScriptBlock {
                Set-Service -Name sshd -StartupType 'Automatic'
                Start-Service sshd -ErrorAction SilentlyContinue
                
                $svc = Get-Service -Name sshd
                return $svc.Status -eq 'Running'
            }
            $result.SshRunning = $serviceStatus
            Write-LogMessage "    SSH Service: $(if($serviceStatus){'Running'}else{'Not running'})" -Level $(if($serviceStatus){'Success'}else{'Error'})

            # Configure firewall
            $fwStatus = Invoke-Command -Session $session -ScriptBlock {
                $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
                if (-not $rule) {
                    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
                        -DisplayName "OpenSSH Server (sshd)" `
                        -Enabled True `
                        -Direction Inbound `
                        -Protocol TCP `
                        -Action Allow `
                        -LocalPort 22 | Out-Null
                    return $true
                }
                return $true
            }
            $result.FirewallConfigured = $fwStatus
            Write-LogMessage "    Firewall: Configured" -Level Success

            # Configure key-based authentication
            if ($EnableKeyAuth -and $PublicKey) {
                $keyStatus = Invoke-Command -Session $session -ScriptBlock {
                    param($key)
                    
                    $authKeysPath = "$env:ProgramData\ssh\administrators_authorized_keys"
                    
                    # Create file if doesn't exist
                    if (-not (Test-Path $authKeysPath)) {
                        New-Item -Path $authKeysPath -ItemType File -Force | Out-Null
                    }
                    
                    # Add key if not already present
                    $existingKeys = Get-Content $authKeysPath -ErrorAction SilentlyContinue
                    if ($key -notin $existingKeys) {
                        Add-Content -Path $authKeysPath -Value $key
                    }
                    
                    # Set proper permissions
                    $acl = Get-Acl $authKeysPath
                    $acl.SetAccessRuleProtection($true, $false)
                    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "Allow")
                    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "Allow")
                    $acl.SetAccessRule($adminRule)
                    $acl.SetAccessRule($systemRule)
                    Set-Acl -Path $authKeysPath -AclObject $acl
                    
                    return $true
                } -ArgumentList $PublicKey

                $result.KeyAuthEnabled = $keyStatus
                Write-LogMessage "    Key Auth: Configured" -Level Success
            }

            # Disable password auth if requested
            if ($DisablePasswordAuth) {
                Invoke-Command -Session $session -ScriptBlock {
                    $sshdConfig = "$env:ProgramData\ssh\sshd_config"
                    $content = Get-Content $sshdConfig
                    $content = $content -replace "^#?PasswordAuthentication\s+\w+", "PasswordAuthentication no"
                    Set-Content -Path $sshdConfig -Value $content
                    Restart-Service sshd
                }
                Write-LogMessage "    Password Auth: Disabled" -Level Info
            }

        } finally {
            Remove-PSSession -Session $session
        }

    } catch {
        Write-LogMessage "    Failed: $($_.Exception.Message)" -Level Error
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Test-SshConnectivity {
    <#
    .SYNOPSIS
        Tests SSH connectivity to a node.
    #>
    [CmdletBinding()]
    param([string]$NodeName)

    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect($NodeName, 22, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
        $result = $wait -and $tcpClient.Connected
        if ($tcpClient.Connected) { $tcpClient.Close() }
        return $result
    } catch {
        return $false
    }
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "SSH Configuration" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get node names from config if not provided
    if (-not $NodeNames -and $config.compute.cluster_nodes) {
        $NodeNames = @($config.compute.cluster_nodes.GetEnumerator() | ForEach-Object { $_.Value.management_ip })  # compute.cluster_nodes.<key>.management_ip
    }

    if (-not $NodeNames) {
        throw "NodeNames are required"
    }

    # Resolve credentials — Key Vault first, then interactive fallback
    if (-not $Credential) {
        function Resolve-KeyVaultRef {
            param([string]$KvUri)
            if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') { return $null }
            $vaultName = $Matches[1]; $secretName = $Matches[2]
            if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
                try {
                    $s = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
                    if ($s) { return $s }
                } catch {}
            }
            try {
                $azCmd = Get-Command az -ErrorAction SilentlyContinue
                if ($azCmd) {
                    $val = (& az keyvault secret show --vault-name $vaultName --name $secretName --query value --output tsv --only-show-errors 2>$null)
                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($val)) { return $val }
                }
            } catch {}
            return $null
        }
        # Post-deployment: nodes are domain-joined — use LCM domain account
        $lcmUser       = $config.identity.accounts.account_lcm_username         # identity.accounts.account_lcm_username
        $lcmPassUri    = $config.identity.accounts.account_lcm_password          # identity.accounts.account_lcm_password
        $domainNetbios = $config.identity.active_directory.ad_netbios_name       # identity.active_directory.ad_netbios_name
        $lcmFqUser     = if ($domainNetbios) { "$domainNetbios\$lcmUser" } else { $lcmUser }
        Write-LogMessage "Resolving LCM credentials from Key Vault..." -Level Info
        $lcmPass = Resolve-KeyVaultRef -KvUri $lcmPassUri
        if ($lcmPass) {
            $Credential = New-Object PSCredential($lcmFqUser, (ConvertTo-SecureString $lcmPass -AsPlainText -Force))
            Write-LogMessage "Credentials resolved for '$lcmFqUser'." -Level Success
        } else {
            Write-LogMessage "Key Vault unavailable — prompting for credentials." -Level Warning
            $Credential = Get-Credential -Message "Enter LCM account credentials for cluster nodes" -UserName $lcmFqUser
        }
    }

    # Load public key if path provided
    $publicKey = $null
    if ($PublicKeyPath -and (Test-Path $PublicKeyPath)) {
        $publicKey = Get-Content -Path $PublicKeyPath -Raw
        $publicKey = $publicKey.Trim()
    }

    Write-LogMessage "Configuring SSH on $($NodeNames.Count) nodes..." -Level Info

    # Configure SSH on each node
    $results = @()
    foreach ($node in $NodeNames) {
        Write-LogMessage "  Configuring: $node" -Level Info
        
        if ($PSCmdlet.ShouldProcess($node, "Configure SSH")) {
            $result = Enable-NodeSsh `
                -NodeName $node `
                -Credential $Credential `
                -PublicKey $publicKey `
                -EnableKeyAuth:$EnableKeyAuth `
                -DisablePasswordAuth:$DisablePasswordAuth
            
            $results += $result
        }
    }

    # Test connectivity
    Write-LogMessage "" -Level Info
    Write-LogMessage "Testing SSH connectivity..." -Level Info
    foreach ($node in $NodeNames) {
        $accessible = Test-SshConnectivity -NodeName $node
        Write-LogMessage "  $node : $(if($accessible){'✓ Accessible'}else{'✗ Not accessible'})" -Level $(if($accessible){'Success'}else{'Error'})
    }

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "SSH Configuration Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $sshRunning = ($results | Where-Object { $_.SshRunning }).Count
    Write-LogMessage "  SSH running: $sshRunning / $($NodeNames.Count)" -Level $(if($sshRunning -eq $NodeNames.Count){'Success'}else{'Warning'})

    return @{
        Results = $results
    }

} catch {
    Write-LogMessage "SSH configuration failed: $_" -Level Error
    throw
}

#endregion Main
