Set-StrictMode -Version Latest

function Resolve-DeploymentRepositoryRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StartPath
    )

    $item = Get-Item -LiteralPath $StartPath
    if ($item -is [System.IO.FileInfo]) {
        $item = $item.Directory
    }

    while ($null -ne $item) {
        if (Test-Path -LiteralPath (Join-Path $item.FullName 'config\variables\variables.example.yml')) {
            return $item.FullName
        }

        $item = $item.Parent
    }

    throw "Unable to resolve repository root from '$StartPath'."
}

function Initialize-DeploymentConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [string]$ConfigPath = ''
    )

    $resolvedPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        Join-Path $RepositoryRoot 'config\variables\variables.yml'
    }
    else {
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
    }

    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        $templatePath = Join-Path $RepositoryRoot 'config\variables\variables.example.yml'
        if (-not (Test-Path -LiteralPath $templatePath)) {
            throw "Runtime config '$resolvedPath' is missing and no template exists at '$templatePath'."
        }

        $parent = Split-Path -Path $resolvedPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        Copy-Item -LiteralPath $templatePath -Destination $resolvedPath -Force
    }

    return $resolvedPath
}

function New-DeploymentLogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$TaskPath,

        [string]$LogPath = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $parent = Split-Path -Path $LogPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        return $LogPath
    }

    $taskName = Split-Path -Path $TaskPath -Leaf
    $logDirectory = Join-Path $RepositoryRoot (Join-Path 'logs' $taskName)
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

    return Join-Path $logDirectory ((Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')
}

function Write-DeploymentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',

        [string]$LogPath = ''
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR' { Write-Error $Message }
        'WARN' { Write-Warning $Message }
        'DEBUG' { Write-Verbose $Message }
        default { Write-Host $line }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Add-Content -LiteralPath $LogPath -Value $line
    }
}

function Import-DeploymentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $raw = Get-Content -LiteralPath $ConfigPath -Raw
    $convertFromYaml = Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($null -ne $convertFromYaml) {
        return $raw | ConvertFrom-Yaml
    }

    return [ordered]@{
        _config_path = $ConfigPath
        _yaml_parser = 'unavailable'
        _raw = $raw
    }
}

function Get-DeploymentConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [string[]]$PathCandidates
    )

    foreach ($candidate in $PathCandidates) {
        $current = $Configuration
        $matched = $true
        foreach ($segment in ($candidate -split '\.')) {
            if ($current -is [System.Collections.IDictionary] -and $current.Contains($segment)) {
                $current = $current[$segment]
                continue
            }

            $property = $current.PSObject.Properties[$segment]
            if ($null -ne $property) {
                $current = $property.Value
                continue
            }

            $matched = $false
            break
        }

        if ($matched -and $null -ne $current -and -not [string]::IsNullOrWhiteSpace([string]$current)) {
            return $current
        }
    }

    return $null
}

function Resolve-KeyVaultReference {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or -not $Value.StartsWith('keyvault://')) {
        return $Value
    }

    $reference = $Value.Substring('keyvault://'.Length)
    $segments = $reference.Split('/', 2)
    if ($segments.Count -ne 2) {
        throw "Invalid Key Vault reference '$Value'."
    }

    $vaultName = $segments[0]
    $secretName = $segments[1]

    $getAzKeyVaultSecret = Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue
    if ($null -ne $getAzKeyVaultSecret) {
        try {
            return Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
        }
        catch {
        }
    }

    $azCommand = Get-Command -Name az -ErrorAction SilentlyContinue
    if ($null -ne $azCommand) {
        try {
            $resolved = & $azCommand.Source keyvault secret show --vault-name $vaultName --name $secretName --query value -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolved)) {
                return $resolved
            }
        }
        catch {
        }
    }

    throw "Unable to resolve secret '$secretName' from vault '$vaultName'."
}

function Resolve-DeploymentCredential {
    [CmdletBinding()]
    param(
        [System.Management.Automation.PSCredential]$Credential,

        [AllowNull()]
        [object]$Configuration
    )

    if ($null -ne $Credential) {
        return $Credential
    }

    $username = [string](Get-DeploymentConfigValue -Configuration $Configuration -PathCandidates @(
        'identity.accounts.account_local_admin_username',
        'deployment.admin_upn',
        'site.owner',
        'environment.env_owner'
    ))

    $passwordReference = [string](Get-DeploymentConfigValue -Configuration $Configuration -PathCandidates @(
        'identity.accounts.account_local_admin_password',
        'identity.accounts.password',
        'security.admin_password'
    ))

    if (-not [string]::IsNullOrWhiteSpace($username) -and -not [string]::IsNullOrWhiteSpace($passwordReference)) {
        $password = Resolve-KeyVaultReference -Value $passwordReference
        if (-not [string]::IsNullOrWhiteSpace($password)) {
            $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
            return [System.Management.Automation.PSCredential]::new($username, $securePassword)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($username)) {
        Write-Verbose "Falling back to interactive credential prompt for '$username'."
        return Get-Credential -UserName $username -Message 'Enter credentials for deployment operations.'
    }

    Write-Verbose 'Falling back to interactive credential prompt.'
    return Get-Credential -Message 'Enter credentials for deployment operations.'
}

function Format-DeploymentValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string]) {
        return $Value
    }

    return ($Value | ConvertTo-Json -Depth 8 -Compress)
}

function Invoke-DeploymentStandalone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$TaskPath,

        [Parameter(Mandatory)]
        [string]$ActionName,

        [hashtable]$Configuration = @{},

        [hashtable]$Parameters = @{},

        [string]$LogPath = ''
    )

    $repositoryRoot = Resolve-DeploymentRepositoryRoot -StartPath $ScriptPath
    $resolvedLogPath = New-DeploymentLogPath -RepositoryRoot $repositoryRoot -TaskPath $TaskPath -LogPath $LogPath

    Write-DeploymentLog -Message "Starting standalone script '$ActionName' for task '$TaskPath'." -LogPath $resolvedLogPath
    foreach ($key in ($Configuration.Keys | Sort-Object)) {
        Write-DeploymentLog -Message ("Configuration [{0}] = {1}" -f $key, (Format-DeploymentValue -Value $Configuration[$key])) -Level DEBUG -LogPath $resolvedLogPath
    }

    Write-DeploymentLog -Message 'This script is a standards-compliant scaffold. Add task-specific operations before production use.' -Level WARN -LogPath $resolvedLogPath

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        TaskPath = $TaskPath
        LogPath = $resolvedLogPath
        Parameters = $Parameters
    }
}

function Invoke-DeploymentOrchestrated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$TaskPath,

        [Parameter(Mandatory)]
        [string]$ActionName,

        [string]$ConfigPath = '',

        [System.Management.Automation.PSCredential]$Credential,

        [string[]]$TargetNode = @(),

        [hashtable]$Parameters = @{},

        [string]$LogPath = ''
    )

    $repositoryRoot = Resolve-DeploymentRepositoryRoot -StartPath $ScriptPath
    $resolvedConfigPath = Initialize-DeploymentConfigPath -RepositoryRoot $repositoryRoot -ConfigPath $ConfigPath
    $configuration = Import-DeploymentConfiguration -ConfigPath $resolvedConfigPath
    $resolvedCredential = Resolve-DeploymentCredential -Credential $Credential -Configuration $configuration
    $resolvedLogPath = New-DeploymentLogPath -RepositoryRoot $repositoryRoot -TaskPath $TaskPath -LogPath $LogPath
    $targets = if ($TargetNode.Count -gt 0) { $TargetNode } else { @('all') }

    Write-DeploymentLog -Message "Starting orchestrated script '$ActionName' for task '$TaskPath'." -LogPath $resolvedLogPath
    Write-DeploymentLog -Message ("Using config path '{0}'." -f $resolvedConfigPath) -LogPath $resolvedLogPath
    Write-DeploymentLog -Message ("Resolved credential for '{0}'." -f $resolvedCredential.UserName) -Level DEBUG -LogPath $resolvedLogPath
    foreach ($target in $targets) {
        Write-DeploymentLog -Message ("Prepared target node '{0}'." -f $target) -Level DEBUG -LogPath $resolvedLogPath
    }

    Write-DeploymentLog -Message 'This script is a standards-compliant scaffold. Add task-specific orchestration before production use.' -Level WARN -LogPath $resolvedLogPath

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        ConfigPath = $resolvedConfigPath
        TaskPath = $TaskPath
        TargetNode = $targets
        LogPath = $resolvedLogPath
        Parameters = $Parameters
    }
}

function Invoke-DeploymentAzCliPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$TaskPath,

        [Parameter(Mandatory)]
        [string]$ActionName,

        [string]$ConfigPath = '',

        [hashtable]$Parameters = @{},

        [string]$LogPath = ''
    )

    $repositoryRoot = Resolve-DeploymentRepositoryRoot -StartPath $ScriptPath
    $resolvedConfigPath = Initialize-DeploymentConfigPath -RepositoryRoot $repositoryRoot -ConfigPath $ConfigPath
    $null = Import-DeploymentConfiguration -ConfigPath $resolvedConfigPath
    $resolvedLogPath = New-DeploymentLogPath -RepositoryRoot $repositoryRoot -TaskPath $TaskPath -LogPath $LogPath

    if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI 'az' was not found in PATH."
    }

    Write-DeploymentLog -Message "Starting Azure CLI PowerShell wrapper '$ActionName' for task '$TaskPath'." -LogPath $resolvedLogPath
    Write-DeploymentLog -Message ("Using config path '{0}'." -f $resolvedConfigPath) -LogPath $resolvedLogPath
    Write-DeploymentLog -Message 'This script is a standards-compliant scaffold. Add task-specific az commands before production use.' -Level WARN -LogPath $resolvedLogPath

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        ConfigPath = $resolvedConfigPath
        TaskPath = $TaskPath
        LogPath = $resolvedLogPath
        Parameters = $Parameters
    }
}

Export-ModuleMember -Function *
