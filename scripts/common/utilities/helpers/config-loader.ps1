<#
.SYNOPSIS
    Configuration loader for Microsoft Hybrid Cloud solutions.

.DESCRIPTION
    This module provides functions to load, merge, and export YAML configuration files
    for hybrid cloud deployments. Supports hierarchical configuration with environment
    and solution-specific overrides.

    The configuration system follows a hierarchy:
    1. Master Registry (config/master-registry.yaml) - Organization defaults
    2. Environment Config (config/environments/{env}.yaml) - Environment-specific
    3. Solution Config (solutions/{solution}/config/solution.yaml) - Solution-specific

    Values are merged with later sources overriding earlier ones.

.NOTES
    Requires powershell-yaml module: Install-Module powershell-yaml -Scope CurrentUser

.EXAMPLE
    # Load solution config directly
    $config = Get-SolutionConfig -Solution "azure-local"
    
    # Access values using fixed paths
    $tenantId = $config.azure_platform.tenant.id
    $kvName = $config.security.key_vaults.management.name
#>

# Check for required module
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "powershell-yaml module not found. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}

Import-Module powershell-yaml -ErrorAction Stop

# Get repository root (relative to this script)
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Guaranteed configuration paths (Variable Path Contract)
# These paths are standardized across all solution configurations
$script:ConfigPaths = @{
    # Azure Identity
    TenantId           = 'azure.tenant.id'
    SubscriptionId     = 'azure.subscription.id'
    
    # Key Vault
    PlatformKeyVault   = 'azure_infrastructure.key_vaults.platform.name'
    SecretsKeyVault    = 'azure_infrastructure.key_vaults.secrets.name'
    
    # Resource Groups
    ManagementRG       = 'azure_infrastructure.resource_groups.management.name'
    ComputeRG          = 'azure_infrastructure.resource_groups.compute.name'
    StorageRG          = 'azure_infrastructure.resource_groups.storage.name'
    NetworkRG          = 'azure_infrastructure.resource_groups.network.name'
    
    # Common Tags
    Environment        = 'tags.environment'
    CostCenter         = 'tags.cost_center'
    Owner              = 'tags.owner'
    
    # Solution Identity
    SolutionName       = 'solution.name'
    SolutionType       = 'solution.type'
}

<#
.SYNOPSIS
    Loads a single YAML configuration file.

.PARAMETER Path
    Path to the YAML file.

.EXAMPLE
    $config = Get-Configuration -Path "config/environments/prod.yaml"
#>
function Get-Configuration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    $content = Get-Content -Raw $Path
    $config = ConvertFrom-Yaml $content -Ordered

    return $config
}

<#
.SYNOPSIS
    Merges environment and solution configurations.

.PARAMETER Environment
    Environment name (dev, test, prod).

.PARAMETER Solution
    Optional. Solution name (azure-local, sofs-azure-local, etc.).

.EXAMPLE
    $config = Get-MergedConfiguration -Environment "prod" -Solution "azure-local"
#>
function Get-MergedConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("dev", "test", "prod")]
        [string]$Environment,

        [Parameter(Mandatory = $false)]
        [string]$Solution
    )

    # Load environment config
    $envPath = Join-Path $script:RepoRoot "config\environments\$Environment.yaml"
    $config = Get-Configuration -Path $envPath

    # Merge solution config if specified
    if ($Solution) {
        $solutionPath = Join-Path $script:RepoRoot "solutions\$Solution\config\solution.yaml"
        if (Test-Path $solutionPath) {
            $solutionConfig = Get-Configuration -Path $solutionPath
            $config = Merge-Hashtables -Base $config -Override $solutionConfig
        }
    }

    return $config
}

<#
.SYNOPSIS
    Deep merges two hashtables.

.DESCRIPTION
    Recursively merges Override into Base. Override values take precedence.

.PARAMETER Base
    The base hashtable.

.PARAMETER Override
    The hashtable with overriding values.

.EXAMPLE
    $merged = Merge-Hashtables -Base $base -Override $override
#>
function Merge-Hashtables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Base,

        [Parameter(Mandatory = $true)]
        $Override
    )

    # Handle null cases
    if ($null -eq $Base) { return $Override }
    if ($null -eq $Override) { return $Base }

    # Convert to hashtable if ordered dictionary
    if ($Base -is [System.Collections.Specialized.OrderedDictionary]) {
        $baseHash = @{}
        foreach ($key in $Base.Keys) { $baseHash[$key] = $Base[$key] }
        $Base = $baseHash
    }
    if ($Override -is [System.Collections.Specialized.OrderedDictionary]) {
        $overrideHash = @{}
        foreach ($key in $Override.Keys) { $overrideHash[$key] = $Override[$key] }
        $Override = $overrideHash
    }

    $result = $Base.Clone()

    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key)) {
            # Both have the key - check if we need to deep merge
            if ($result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
                $result[$key] = Merge-Hashtables -Base $result[$key] -Override $Override[$key]
            }
            elseif ($result[$key] -is [System.Collections.Specialized.OrderedDictionary] -or 
                    $Override[$key] -is [System.Collections.Specialized.OrderedDictionary]) {
                $result[$key] = Merge-Hashtables -Base $result[$key] -Override $Override[$key]
            }
            else {
                # Override the value
                $result[$key] = $Override[$key]
            }
        }
        else {
            # Key only in override
            $result[$key] = $Override[$key]
        }
    }

    return $result
}

<#
.SYNOPSIS
    Exports configuration to Bicep parameters format.

.PARAMETER Config
    The configuration hashtable.

.PARAMETER OutputPath
    Path to save the Bicep parameters file.
#>
function Export-BicepParams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath
}

<#
.SYNOPSIS
    Exports configuration to Ansible variables format.

.PARAMETER Config
    The configuration hashtable.

.PARAMETER OutputPath
    Path to save the Ansible variables file.
#>
function Export-AnsibleVars {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $Config | ConvertTo-Yaml | Set-Content -Path $OutputPath
}

<#
.SYNOPSIS
    Loads a solution configuration directly.

.DESCRIPTION
    Loads the solution.yaml file for a specific solution. This is the primary
    function for scripts to load configuration. All solution configurations
    follow the Variable Path Contract - same paths, different values.

.PARAMETER Solution
    Name of the solution folder (e.g., "azure-local").

.PARAMETER ConfigFile
    Optional. Name of the config file. Defaults to "solution.yaml".

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    $tenantId = $config.azure_platform.tenant.id
    $kvName = $config.security.key_vaults.management.name

.EXAMPLE
    # Use the guaranteed config paths
    $config = Get-SolutionConfig -Solution "sofs-azure-local"
    $kvName = Get-ConfigValue -Config $config -Path $script:ConfigPaths.PlatformKeyVault
#>
function Get-SolutionConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("azure-local", "azure-arc-servers")]
        [string]$Solution,

        [Parameter(Mandatory = $false)]
        [string]$ConfigFile = "solution.yaml"
    )

    $solutionPath = Join-Path $script:RepoRoot "solutions\$Solution\config\$ConfigFile"
    
    if (-not (Test-Path $solutionPath)) {
        throw "Solution configuration not found: $solutionPath"
    }

    $config = Get-Configuration -Path $solutionPath
    
    # Add metadata about source
    if (-not $config._metadata) {
        $config._metadata = @{}
    }
    $config._metadata.source_file = $solutionPath
    $config._metadata.loaded_at = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    
    return $config
}

<#
.SYNOPSIS
    Gets a value from configuration using dot notation path.

.DESCRIPTION
    Navigates a configuration hashtable using a dot-separated path string.
    Returns $null if the path doesn't exist.

.PARAMETER Config
    The configuration hashtable.

.PARAMETER Path
    Dot-separated path (e.g., "azure.tenant.id").

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    $tenantId = Get-ConfigValue -Config $config -Path "azure.tenant.id"

.EXAMPLE
    # Using the predefined paths
    $kvName = Get-ConfigValue -Config $config -Path $script:ConfigPaths.PlatformKeyVault
#>
function Get-ConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = $Config
    $parts = $Path -split '\.'

    foreach ($part in $parts) {
        if ($null -eq $current) {
            return $null
        }

        # Handle hashtable/ordered dictionary
        if ($current -is [hashtable] -or $current -is [System.Collections.Specialized.OrderedDictionary]) {
            if ($current.ContainsKey($part)) {
                $current = $current[$part]
            }
            else {
                return $null
            }
        }
        # Handle PSCustomObject
        elseif ($current -is [PSCustomObject]) {
            $prop = $current.PSObject.Properties[$part]
            if ($prop) {
                $current = $prop.Value
            }
            else {
                return $null
            }
        }
        else {
            return $null
        }
    }

    return $current
}

<#
.SYNOPSIS
    Validates that a configuration has all required paths.

.DESCRIPTION
    Checks that the configuration contains values for the standard Variable Path Contract.
    Returns a validation result with any missing paths.

.PARAMETER Config
    The configuration hashtable to validate.

.PARAMETER RequiredPaths
    Optional. Array of dot-notation paths to require. Defaults to core paths.

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    $validation = Test-ConfigPaths -Config $config
    if (-not $validation.IsValid) {
        Write-Warning "Missing paths: $($validation.MissingPaths -join ', ')"
    }
#>
function Test-ConfigPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $false)]
        [string[]]$RequiredPaths = @(
            'azure.tenant.id',
            'azure.subscription.id',
            'azure_infrastructure.key_vaults.platform.name',
            'azure_infrastructure.resource_groups.management.name',
            'solution.name',
            'solution.type'
        )
    )

    $missingPaths = @()
    
    foreach ($path in $RequiredPaths) {
        $value = Get-ConfigValue -Config $Config -Path $path
        if ($null -eq $value -or $value -eq '') {
            $missingPaths += $path
        }
    }

    return @{
        IsValid = ($missingPaths.Count -eq 0)
        MissingPaths = $missingPaths
        CheckedPaths = $RequiredPaths
    }
}

<#
.SYNOPSIS
    Gets the platform Key Vault name from configuration.

.DESCRIPTION
    Helper function that extracts the platform Key Vault name from a solution config.
    This is a common operation so it's provided as a convenience function.

.PARAMETER Config
    The configuration hashtable (from Get-SolutionConfig).

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    $kvName = Get-PlatformKeyVault -Config $config
#>
function Get-PlatformKeyVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $kvName = Get-ConfigValue -Config $Config -Path 'azure_infrastructure.key_vaults.platform.name'
    
    if ([string]::IsNullOrEmpty($kvName)) {
        throw "Platform Key Vault not defined in configuration at path: azure_infrastructure.key_vaults.platform.name"
    }

    return $kvName
}

<#
.SYNOPSIS
    Gets tags from configuration as a hashtable.

.DESCRIPTION
    Extracts the tags section from configuration and returns as a hashtable
    suitable for Azure resource tagging.

.PARAMETER Config
    The configuration hashtable (from Get-SolutionConfig).

.EXAMPLE
    $config = Get-SolutionConfig -Solution "azure-local"
    $tags = Get-ConfigTags -Config $config
    # Use with Azure commands: New-AzResourceGroup -Tag $tags
#>
function Get-ConfigTags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $tagsSection = Get-ConfigValue -Config $Config -Path 'tags'
    
    if ($null -eq $tagsSection) {
        return @{}
    }

    # Convert to hashtable if needed
    $tags = @{}
    
    if ($tagsSection -is [hashtable]) {
        $tags = $tagsSection.Clone()
    }
    elseif ($tagsSection -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($key in $tagsSection.Keys) {
            $tags[$key] = $tagsSection[$key]
        }
    }
    elseif ($tagsSection -is [PSCustomObject]) {
        foreach ($prop in $tagsSection.PSObject.Properties) {
            $tags[$prop.Name] = $prop.Value
        }
    }

    return $tags
}

<#
.SYNOPSIS
    Lists all available solutions in the repository.

.DESCRIPTION
    Scans the solutions directory and returns information about each solution.

.EXAMPLE
    $solutions = Get-AvailableSolutions
    $solutions | Format-Table Name, HasConfig, ConfigPath
#>
function Get-AvailableSolutions {
    [CmdletBinding()]
    param()

    $solutionsPath = Join-Path $script:RepoRoot "solutions"
    $solutions = @()

    Get-ChildItem -Path $solutionsPath -Directory | ForEach-Object {
        $configPath = Join-Path $_.FullName "config\solution.yaml"
        $hasConfig = Test-Path $configPath
        
        $solutions += [PSCustomObject]@{
            Name = $_.Name
            Path = $_.FullName
            HasConfig = $hasConfig
            ConfigPath = if ($hasConfig) { $configPath } else { $null }
        }
    }

    return $solutions
}

<#
.SYNOPSIS
    Loads infrastructure configuration from infrastructure.yml.

.DESCRIPTION
    Primary function for deployment scripts to load configuration.
    Loads config/infrastructure.yml from the repository root.
    
    This is the simplified loader for scripts that need direct access
    to infrastructure configuration without solution-based merging.

.PARAMETER ConfigPath
    Optional. Path to infrastructure.yml. Defaults to config/infrastructure.yml
    in the repository root.

.EXAMPLE
    $config = Get-InfrastructureConfig
    $b2b = $config.b2b_configuration
    $tenantId = $b2b.Azure Local Cloud_mgmt.tenant_id

.EXAMPLE
    # With custom path
    $config = Get-InfrastructureConfig -ConfigPath "C:\path\to\infrastructure.yml"
#>
function Get-InfrastructureConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )

    # Default to config/infrastructure.yml in repo root
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $script:RepoRoot "configs\infrastructure.yml"
    }

    if (-not (Test-Path $ConfigPath)) {
        throw "Infrastructure configuration not found: $ConfigPath"
    }

    Write-Verbose "Loading infrastructure config from: $ConfigPath"
    $config = Get-Configuration -Path $ConfigPath
    
    # Add metadata
    if (-not $config._metadata) {
        $config._metadata = @{}
    }
    $config._metadata.source_file = $ConfigPath
    $config._metadata.loaded_at = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    
    return $config
}

<#
.SYNOPSIS
    Gets B2B/Cross-Tenant configuration from infrastructure config.

.DESCRIPTION
    Helper function to extract the b2b_configuration section from
    infrastructure.yml. Used by Stage 00 B2B scripts.

.PARAMETER Config
    Optional. Pre-loaded infrastructure config. If not provided,
    loads from default infrastructure.yml location.

.EXAMPLE
    $b2b = Get-B2BConfig
    $Azure Local CloudTenantId = $b2b.Azure Local Cloud_mgmt.tenant_id
    $serviceTier = $b2b.service_tier

.EXAMPLE
    # With pre-loaded config
    $config = Get-InfrastructureConfig
    $b2b = Get-B2BConfig -Config $config
#>
function Get-B2BConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Config
    )

    if (-not $Config) {
        $Config = Get-InfrastructureConfig
    }

    $b2b = Get-ConfigValue -Config $Config -Path 'b2b_configuration'
    
    if ($null -eq $b2b) {
        throw "B2B configuration not found in infrastructure.yml. Ensure b2b_configuration section exists."
    }

    return $b2b
}

# Export functions
Export-ModuleMember -Function @(
    'Get-Configuration',
    'Get-MergedConfiguration', 
    'Get-SolutionConfig',
    'Get-InfrastructureConfig',
    'Get-B2BConfig',
    'Get-ConfigValue',
    'Get-PlatformKeyVault',
    'Get-ConfigTags',
    'Get-AvailableSolutions',
    'Test-ConfigPaths',
    'Merge-Hashtables',
    'Export-BicepParams',
    'Export-AnsibleVars'
) -Variable 'ConfigPaths'
