<#
.SYNOPSIS
    Variable Registry Helper for Azure Local Toolkit.

.DESCRIPTION
    This module provides functions to search and validate variables in the
    infrastructure.yml configuration file and track missing variables during
    script development. It integrates with the config-loader.ps1 for consistent
    variable access patterns.

    The registry follows a hierarchical structure:
    - infrastructure.yml - Main configuration with all deployment variables
    - Per-section variables organized by Azure service/component

.NOTES
    Requires powershell-yaml module: Install-Module powershell-yaml -Scope CurrentUser
    Works in conjunction with config-loader.ps1

.EXAMPLE
    # Search for existing variable
    $result = Find-RegistryVariable -VariableName "tenant_id"
    
    # Check if a specific path exists
    $exists = Test-RegistryVariablePath -Path "azure_tenants[0].tenant_id"
    
    # Get a variable value by path
    $value = Get-RegistryVariableValue -Path "keyvault.platform_keyvault_name"
#>

# Check for required module
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "powershell-yaml module not found. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}

Import-Module powershell-yaml -ErrorAction Stop

# Get repository root (relative to this script)
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$script:InfrastructureConfigPath = Join-Path $script:RepoRoot "configs\infrastructure.yml"
$script:MissingVariablesLogPath = Join-Path $script:RepoRoot "configs\variables\missing-variables.log"

# Cache for loaded configuration
$script:ConfigCache = $null
$script:ConfigCacheTime = $null
$script:CacheTTLMinutes = 5

<#
.SYNOPSIS
    Loads the infrastructure configuration with caching.

.DESCRIPTION
    Loads infrastructure.yml and caches it for performance. Cache expires
    after 5 minutes or when explicitly refreshed.

.PARAMETER Force
    Force reload of configuration, bypassing cache.

.EXAMPLE
    $config = Get-InfrastructureConfig
    $config = Get-InfrastructureConfig -Force
#>
function Get-InfrastructureConfig {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    # Check cache validity
    $now = Get-Date
    $cacheValid = ($null -ne $script:ConfigCache) -and 
                  ($null -ne $script:ConfigCacheTime) -and
                  (($now - $script:ConfigCacheTime).TotalMinutes -lt $script:CacheTTLMinutes)

    if (-not $Force -and $cacheValid) {
        return $script:ConfigCache
    }

    if (-not (Test-Path $script:InfrastructureConfigPath)) {
        throw "Infrastructure configuration not found: $script:InfrastructureConfigPath"
    }

    $content = Get-Content -Raw $script:InfrastructureConfigPath
    $script:ConfigCache = ConvertFrom-Yaml $content -Ordered
    $script:ConfigCacheTime = $now

    return $script:ConfigCache
}

<#
.SYNOPSIS
    Searches for a variable by name across the entire configuration.

.DESCRIPTION
    Performs a recursive search through the infrastructure.yml to find
    all occurrences of a variable name. Returns the full path(s) where
    the variable is defined.

.PARAMETER VariableName
    The variable name to search for (case-insensitive).

.PARAMETER ExactMatch
    If specified, only matches exact variable names. Otherwise, performs
    a contains search.

.EXAMPLE
    # Find all paths containing "tenant"
    Find-RegistryVariable -VariableName "tenant"
    
    # Find exact match for "tenant_id"
    Find-RegistryVariable -VariableName "tenant_id" -ExactMatch
#>
function Find-RegistryVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VariableName,

        [switch]$ExactMatch
    )

    $config = Get-InfrastructureConfig
    $results = @()

    function Search-Recursive {
        param(
            [Parameter(Mandatory = $true)]
            $Object,
            
            [string]$CurrentPath = ""
        )

        if ($null -eq $Object) {
            return
        }

        # Handle hashtable/ordered dictionary
        if ($Object -is [hashtable] -or $Object -is [System.Collections.Specialized.OrderedDictionary]) {
            foreach ($key in $Object.Keys) {
                $newPath = if ($CurrentPath) { "$CurrentPath.$key" } else { $key }
                
                # Check if key matches
                $keyMatches = if ($ExactMatch) {
                    $key -eq $VariableName
                } else {
                    $key -like "*$VariableName*"
                }

                if ($keyMatches) {
                    $script:results += [PSCustomObject]@{
                        Path  = $newPath
                        Key   = $key
                        Value = $Object[$key]
                        Type  = ($Object[$key]).GetType().Name
                    }
                }

                # Recurse into value
                Search-Recursive -Object $Object[$key] -CurrentPath $newPath
            }
        }
        # Handle arrays
        elseif ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
            $index = 0
            foreach ($item in $Object) {
                $newPath = "$CurrentPath[$index]"
                Search-Recursive -Object $item -CurrentPath $newPath
                $index++
            }
        }
    }

    Search-Recursive -Object $config -CurrentPath ""
    
    return $results
}

<#
.SYNOPSIS
    Tests if a variable path exists in the configuration.

.PARAMETER Path
    Dot-notation path to test (e.g., "keyvault.platform_keyvault_name").

.EXAMPLE
    if (Test-RegistryVariablePath -Path "azure_tenants[0].tenant_id") {
        Write-Host "Path exists"
    }
#>
function Test-RegistryVariablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $value = Get-RegistryVariableValue -Path $Path
    return ($null -ne $value)
}

<#
.SYNOPSIS
    Gets a variable value by its dot-notation path.

.DESCRIPTION
    Navigates the configuration using a dot-separated path string.
    Supports array indexing with [n] notation.

.PARAMETER Path
    Dot-notation path (e.g., "keyvault.platform_keyvault_name" or 
    "azure_tenants[0].tenant_id").

.EXAMPLE
    $kvName = Get-RegistryVariableValue -Path "keyvault.platform_keyvault_name"
    $tenantId = Get-RegistryVariableValue -Path "azure_tenants[0].tenant_id"
#>
function Get-RegistryVariableValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $config = Get-InfrastructureConfig
    $current = $config

    # Parse path including array notation
    $segments = @()
    $remaining = $Path
    
    while ($remaining) {
        # Check for array notation
        if ($remaining -match '^([^\.\[]+)(?:\[(\d+)\])?(?:\.(.*))?$') {
            $segments += @{
                Key   = $Matches[1]
                Index = if ($Matches[2]) { [int]$Matches[2] } else { $null }
            }
            $remaining = $Matches[3]
        }
        else {
            break
        }
    }

    foreach ($segment in $segments) {
        if ($null -eq $current) {
            return $null
        }

        # Navigate to key
        if ($current -is [hashtable] -or $current -is [System.Collections.Specialized.OrderedDictionary]) {
            if ($current.Contains($segment.Key)) {
                $current = $current[$segment.Key]
            }
            else {
                return $null
            }
        }
        else {
            return $null
        }

        # Handle array index
        if ($null -ne $segment.Index) {
            if ($current -is [System.Collections.IEnumerable] -and $current -isnot [string]) {
                $arr = @($current)
                if ($segment.Index -lt $arr.Count) {
                    $current = $arr[$segment.Index]
                }
                else {
                    return $null
                }
            }
            else {
                return $null
            }
        }
    }

    return $current
}

<#
.SYNOPSIS
    Lists all top-level sections in the infrastructure configuration.

.EXAMPLE
    Get-RegistrySections
#>
function Get-RegistrySections {
    [CmdletBinding()]
    param()

    $config = Get-InfrastructureConfig
    
    $sections = @()
    foreach ($key in $config.Keys) {
        $value = $config[$key]
        $sections += [PSCustomObject]@{
            Section = $key
            Type    = if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and $value -isnot [hashtable]) {
                "Array[$($value.Count)]"
            } elseif ($value -is [hashtable] -or $value -is [System.Collections.Specialized.OrderedDictionary]) {
                "Object"
            } else {
                $value.GetType().Name
            }
        }
    }
    
    return $sections
}

<#
.SYNOPSIS
    Logs a missing variable to the tracking file.

.DESCRIPTION
    When a script requires a variable that doesn't exist in the registry,
    this function logs it for later addition to the configuration.

.PARAMETER VariableName
    The name of the missing variable.

.PARAMETER ExpectedPath
    The expected path where the variable should be defined.

.PARAMETER RequiredBy
    The script or component that requires this variable.

.PARAMETER Description
    Optional description of what the variable is used for.

.EXAMPLE
    Register-MissingVariable -VariableName "arc_gateway_resource_id" `
        -ExpectedPath "arc_configuration.gateway.resource_id" `
        -RequiredBy "New-ArcGateway.ps1" `
        -Description "Azure Arc Gateway Resource ID for cluster onboarding"
#>
function Register-MissingVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VariableName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedPath,

        [Parameter(Mandatory = $true)]
        [string]$RequiredBy,

        [Parameter(Mandatory = $false)]
        [string]$Description = ""
    )

    # Ensure directory exists
    $logDir = Split-Path $script:MissingVariablesLogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Create log entry
    $entry = [PSCustomObject]@{
        Timestamp     = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        VariableName  = $VariableName
        ExpectedPath  = $ExpectedPath
        RequiredBy    = $RequiredBy
        Description   = $Description
    }

    # Append to log file
    $logLine = "$($entry.Timestamp) | $($entry.VariableName) | $($entry.ExpectedPath) | $($entry.RequiredBy) | $($entry.Description)"
    Add-Content -Path $script:MissingVariablesLogPath -Value $logLine

    Write-Warning "Missing variable logged: $VariableName (expected at: $ExpectedPath)"
}

<#
.SYNOPSIS
    Gets all logged missing variables.

.EXAMPLE
    Get-MissingVariables
#>
function Get-MissingVariables {
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:MissingVariablesLogPath)) {
        return @()
    }

    $entries = Get-Content $script:MissingVariablesLogPath | Where-Object { $_ -match '\S' } | ForEach-Object {
        $parts = $_ -split '\s*\|\s*'
        if ($parts.Count -ge 4) {
            [PSCustomObject]@{
                Timestamp    = $parts[0]
                VariableName = $parts[1]
                ExpectedPath = $parts[2]
                RequiredBy   = $parts[3]
                Description  = if ($parts.Count -ge 5) { $parts[4] } else { "" }
            }
        }
    }

    return $entries
}

<#
.SYNOPSIS
    Validates that all required variables exist for a script.

.DESCRIPTION
    Takes a list of required variable paths and checks that each exists
    in the infrastructure configuration. Returns validation results.

.PARAMETER RequiredPaths
    Array of dot-notation paths that must exist.

.PARAMETER ScriptName
    Name of the script being validated (for logging purposes).

.PARAMETER LogMissing
    If specified, automatically logs any missing variables.

.EXAMPLE
    $required = @(
        "keyvault.platform_keyvault_name",
        "azure_tenants[0].tenant_id",
        "subscriptions[0].id"
    )
    
    $validation = Test-RequiredVariables -RequiredPaths $required `
        -ScriptName "New-ManagementGroups.ps1" -LogMissing
    
    if (-not $validation.AllValid) {
        Write-Error "Missing required variables"
        exit 4
    }
#>
function Test-RequiredVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredPaths,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [switch]$LogMissing
    )

    $results = @()
    $allValid = $true

    foreach ($path in $RequiredPaths) {
        $exists = Test-RegistryVariablePath -Path $path
        $value = if ($exists) { Get-RegistryVariableValue -Path $path } else { $null }
        
        $results += [PSCustomObject]@{
            Path   = $path
            Exists = $exists
            Value  = if ($exists -and $value -notmatch 'secret|password|key') { $value } else { "[REDACTED]" }
        }

        if (-not $exists) {
            $allValid = $false
            if ($LogMissing) {
                $varName = ($path -split '\.' | Select-Object -Last 1) -replace '\[\d+\]', ''
                Register-MissingVariable -VariableName $varName `
                    -ExpectedPath $path `
                    -RequiredBy $ScriptName
            }
        }
    }

    return [PSCustomObject]@{
        AllValid = $allValid
        Results  = $results
        Missing  = $results | Where-Object { -not $_.Exists }
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Get-InfrastructureConfig',
    'Find-RegistryVariable',
    'Test-RegistryVariablePath',
    'Get-RegistryVariableValue',
    'Get-RegistrySections',
    'Register-MissingVariable',
    'Get-MissingVariables',
    'Test-RequiredVariables'
)
