<#
.SYNOPSIS
    Comprehensive Azure tenant inventory.

.DESCRIPTION
    Inventories all Azure resources in the tenant including:
    - Management groups and subscriptions
    - Resource groups and all resources
    - Azure Local (Stack HCI) clusters and resources
    - Networking infrastructure
    - Compute resources
    - Storage accounts
    - Security resources (Key Vaults, Managed Identities)
    - Monitoring resources
    - Policy assignments
    - RBAC role assignments (optional)
    
    Output is saved to discovery/ folder as azure-inventory.json
    for integration with infrastructure.yml updates.

.PARAMETER TenantId
    Azure tenant ID. Defaults to environment variable if not specified.

.PARAMETER OutputPath
    Directory for output files. Defaults to .\discovery

.PARAMETER Format
    Output format: JSON, CSV, or Both. Defaults to Both.

.PARAMETER IncludeEntraId
    Include Entra ID (Azure AD) information in inventory.

.PARAMETER IncludeRBAC
    Include RBAC role assignments in inventory.

.PARAMETER IncludeCosts
    Include cost information in inventory (requires Cost Management access).

.PARAMETER IncludeAzureLocal
    Include Azure Local (Stack HCI) specific resources. Defaults to true.

.PARAMETER SubscriptionFilter
    Array of subscription IDs to filter. If not specified, all subscriptions are inventoried.

.EXAMPLE
    .\Inventory-AzureTenant.ps1 -TenantId "33333333-3333-3333-3333-333333333333"

    Inventory all resources in the tenant.

.EXAMPLE
    .\Inventory-AzureTenant.ps1 -TenantId "33333333-3333-3333-3333-333333333333" -IncludeRBAC -IncludeEntraId

    Full inventory including RBAC and Entra ID information.

.NOTES
    Author: Hybrid Cloud Solutions Team
    Date: 2025
    Version: 2.0.0

    INTEGRATION WITH DATA FRAMEWORK:
    - Outputs to discovery/ folder as azure-inventory.json
    - Compatible with Update-InfrastructureFromDiscovery.ps1
    - Feeds into infrastructure.yml single source of truth
    - See docs/infrastructure-data-framework.md for complete workflow

    REQUIREMENTS:
    - Az PowerShell module
    - Reader role (minimum) on subscriptions
    - Azure login (az login or Connect-AzAccount)

    CHANGES IN v2.0.0:
    - Azure Local (Stack HCI) discovery now ENABLED BY DEFAULT
    - Fixed subscription enumeration using official Microsoft docs
    - Added comprehensive authentication diagnostics
    - Added subscription count validation
    - Improved resource provider detection
    - All commands now follow Microsoft Learn documentation patterns
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false, HelpMessage = "Azure tenant ID")]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\discovery",

    [Parameter(Mandatory = $false)]
    [ValidateSet("JSON", "CSV", "Both")]
    [string]$Format = "Both",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeEntraId,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeRBAC,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeCosts,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeAzureLocal,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20)]
    [int]$MaxParallelJobs = 10,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionFilter
)

#region Script Configuration

$ErrorActionPreference = 'Continue'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Get repository root for proper path resolution
$ScriptRoot = $PSScriptRoot
$RepoRoot = (Get-Item $ScriptRoot).Parent.Parent.FullName

# Smart TenantId detection with multiple fallback sources
$script:TenantDisplayName = $null
$script:TenantDomain = $null

if (-not $TenantId) {
    Write-Host ""
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "│  Detecting Target Tenant                                     │" -ForegroundColor Cyan
    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
    
    # Source 1: Try infrastructure.yml (preferred - explicit configuration)
    $infraFile = Join-Path $RepoRoot "infrastructure.yml"
    if (Test-Path $infraFile) {
        try {
            $yamlContent = Get-Content $infraFile -Raw
            
            # Try multiple YAML patterns for tenant ID:
            # Pattern 1: azure.tenant.id: "guid" (nested structure - your format)
            # Pattern 2: tenant_id: "guid" (flat structure)
            # Pattern 3: id: "guid" after "tenant:" section
            
            $foundTenant = $false
            
            # Check for nested azure.tenant.id pattern (matches indented id: under tenant:)
            if ($yamlContent -match '(?ms)azure:\s*\n\s+tenant:\s*\n\s+id:\s*["'']?([a-f0-9-]+)["'']?') {
                $TenantId = $matches[1]
                $foundTenant = $true
            }
            # Fallback: flat tenant_id pattern
            elseif ($yamlContent -match 'tenant_id:\s*["'']?([a-f0-9-]+)["'']?') {
                $TenantId = $matches[1]
                $foundTenant = $true
            }
            
            if ($foundTenant) {
                # Also try to get the friendly tenant name and domain
                if ($yamlContent -match '(?ms)tenant:\s*\n\s+id:[^\n]+\n\s+name:\s*["'']?([^"''\n]+)["'']?') {
                    $script:TenantDisplayName = $matches[1].Trim()
                }
                if ($yamlContent -match '(?ms)default_domain:\s*["'']?([^"''\n]+)["'']?') {
                    $script:TenantDomain = $matches[1].Trim()
                }
                
                Write-Host "  ✓ Found tenant in infrastructure.yml" -ForegroundColor Green
                Write-Host ""
                Write-Host "    Tenant ID:     $TenantId" -ForegroundColor White
                if ($script:TenantDisplayName) {
                    Write-Host "    Tenant Name:   $script:TenantDisplayName" -ForegroundColor Cyan
                }
                if ($script:TenantDomain) {
                    Write-Host "    Domain:        $script:TenantDomain" -ForegroundColor Cyan
                }
                Write-Host ""
            }
            else {
                Write-Host "  ⚠ infrastructure.yml exists but no tenant configuration found" -ForegroundColor Yellow
                Write-Host "    Expected format:" -ForegroundColor DarkGray
                Write-Host "      azure:" -ForegroundColor DarkGray
                Write-Host "        tenant:" -ForegroundColor DarkGray
                Write-Host "          id: `"your-tenant-guid`"" -ForegroundColor DarkGray
                Write-Host "          name: `"Your Tenant Name`"" -ForegroundColor DarkGray
                Write-Host "          default_domain: `"yourdomain.com`"" -ForegroundColor DarkGray
                Write-Host ""
            }
        }
        catch {
            Write-Host "  ⚠ Could not parse infrastructure.yml: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  ⚠ infrastructure.yml not found at: $infraFile" -ForegroundColor Yellow
    }
    
    # Source 2: Try current Azure context (if already logged in)
    if (-not $TenantId) {
        try {
            $existingContext = Get-AzContext -ErrorAction SilentlyContinue
            if ($null -ne $existingContext -and $existingContext.Tenant.Id) {
                Write-Host "  ℹ Checking current Azure context..." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "    Tenant ID: $($existingContext.Tenant.Id)" -ForegroundColor White
                Write-Host "    Account:   $($existingContext.Account.Id)" -ForegroundColor White
                Write-Host ""
                
                # Prompt user to confirm using current context
                $useContext = Read-Host "  Use this tenant for inventory? (Y/n)"
                if ($useContext -eq '' -or $useContext -match '^[Yy]') {
                    $TenantId = $existingContext.Tenant.Id
                }
                else {
                    Write-Host ""
                    Write-Host "  Please provide tenant ID:" -ForegroundColor Yellow
                    $TenantId = Read-Host "  Tenant ID"
                }
            }
        }
        catch {
            Write-Verbose "Could not check Azure context: $($_.Exception.Message)"
        }
    }
    
    # Source 3: Environment variable
    if (-not $TenantId -and $env:AZURE_TENANT_ID) {
        $TenantId = $env:AZURE_TENANT_ID
        Write-Host "  ✓ Found in environment variable AZURE_TENANT_ID: $TenantId" -ForegroundColor Green
    }
    
    # Final check - no tenant found anywhere
    if (-not $TenantId) {
        Write-Host ""
        Write-Host "  ❌ Could not determine target tenant" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Options to specify tenant:" -ForegroundColor Cyan
        Write-Host "    1. Add 'tenant_id' to infrastructure.yml" -ForegroundColor White
        Write-Host "    2. Pass -TenantId parameter" -ForegroundColor White
        Write-Host "    3. Set AZURE_TENANT_ID environment variable" -ForegroundColor White
        Write-Host "    4. Login to Azure first: Connect-AzAccount" -ForegroundColor White
        Write-Host ""
        throw "TenantId is required. See options above."
    }
    
    Write-Host ""
}

# Resolve output path relative to repo root if relative
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $RepoRoot $OutputPath
}

# Default Azure Local discovery to TRUE unless explicitly set to false
if (-not $PSBoundParameters.ContainsKey('IncludeAzureLocal')) {
    $IncludeAzureLocal = $true
    Write-Verbose "Defaulting to comprehensive inventory including Azure Local (Stack HCI) resources"
}

$script:StartTime = Get-Date
$script:Timestamp = $script:StartTime.ToString("yyyyMMdd-HHmmss")
$script:ProgressCounter = 0
$script:TotalSteps = 15

# Initialize inventory data structure
$script:Inventory = [ordered]@{
    Metadata         = [ordered]@{
        GeneratedAt   = $script:StartTime.ToString("yyyy-MM-dd HH:mm:ss UTC")
        GeneratedBy   = $null
        ScriptVersion = "2.0.0"
        TenantId      = $TenantId
        TenantName    = $null
        OutputPath    = $OutputPath
        Options       = [ordered]@{
            IncludeEntraId     = $IncludeEntraId.IsPresent
            IncludeRBAC        = $IncludeRBAC.IsPresent
            IncludeCosts       = $IncludeCosts.IsPresent
            IncludeAzureLocal  = $IncludeAzureLocal
            SubscriptionFilter = $SubscriptionFilter
        }
    }
    Tenant           = [ordered]@{
        TenantId      = $TenantId
        DisplayName   = $null
        DefaultDomain = $null
        TenantType    = $null
        CountryCode   = $null
    }
    ManagementGroups = @()
    Subscriptions    = @()
    ResourceGroups   = @()
    Resources        = @()
    AzureLocal       = [ordered]@{
        Clusters                 = @()
        CustomLocations          = @()
        LogicalNetworks          = @()
        VirtualMachineImages     = @()
        NetworkInterfaces        = @()
        VirtualHardDisks         = @()
        MarketplaceGalleryImages = @()
    }
    Networking       = [ordered]@{
        VirtualNetworks       = @()
        Subnets               = @()
        NetworkSecurityGroups = @()
        NetworkInterfaces     = @()
        PublicIPAddresses     = @()
        LoadBalancers         = @()
        PrivateEndpoints      = @()
        VNetPeerings          = @()
        VPNGateways           = @()
        LocalNetworkGateways  = @()
        VPNConnections        = @()
        RouteTables           = @()
        ExpressRouteCircuits  = @()
        Bastions              = @()
        NATGateways           = @()
        PrivateDNSZones       = @()
    }
    Compute          = [ordered]@{
        VirtualMachines       = @()
        VirtualMachineDetails = @()
        Disks                 = @()
        Images                = @()
        AvailabilitySets      = @()
        VMScaleSets           = @()
    }
    Storage          = [ordered]@{
        StorageAccounts = @()
        Containers      = @()
        FileShares      = @()
    }
    Security         = [ordered]@{
        KeyVaults         = @()
        ManagedIdentities = @()
        RoleAssignments   = @()
    }
    Monitoring       = [ordered]@{
        LogAnalyticsWorkspaces = @()
        ApplicationInsights    = @()
        DiagnosticSettings     = @()
    }
    Policy           = [ordered]@{
        PolicyAssignments = @()
        PolicyDefinitions = @()
    }
    Tags             = [ordered]@{
        AllTags    = @{}
        ByResource = @()
    }
    Statistics       = [ordered]@{
        TotalSubscriptions      = 0
        TotalResourceGroups     = 0
        TotalResources          = 0
        ResourcesByType         = @{}
        ResourcesByLocation     = @{}
        ResourcesBySubscription = @{}
    }
    Errors           = @()
}

#endregion

#region Helper Functions

function Write-ProgressStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Activity,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [int]$PercentComplete = -1
    )

    if ($PercentComplete -lt 0) {
        $script:ProgressCounter++
        $PercentComplete = [math]::Min(100, [int](($script:ProgressCounter / $script:TotalSteps) * 100))
    }

    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete

    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Activity" -NoNewline -ForegroundColor Cyan
    Write-Host " - " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Status" -ForegroundColor White
}

function Add-InventoryError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [object]$Exception,

        [Parameter(Mandatory = $false)]
        [string]$ResourceId
    )

    $errorEntry = [ordered]@{
        Timestamp        = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Component        = $Component
        Message          = $Message
        ResourceId       = $ResourceId
        ExceptionMessage = $Exception?.Exception?.Message ?? $Exception?.Message ?? "N/A"
        ExceptionType    = $Exception?.Exception?.GetType()?.Name ?? "N/A"
    }

    $script:Inventory.Errors += $errorEntry
    Write-Warning "[$Component] $Message"
}

function ConvertTo-HashtableDeep {
    param(
        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject
    )

    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [string] -or $InputObject -is [int] -or $InputObject -is [long] -or 
            $InputObject -is [bool] -or $InputObject -is [double] -or $InputObject -is [decimal]) {
            return $InputObject
        }
        if ($InputObject -is [datetime]) { return $InputObject.ToString("yyyy-MM-dd HH:mm:ss") }
        if ($InputObject -is [array] -or $InputObject -is [System.Collections.IList]) {
            return @($InputObject | ForEach-Object { ConvertTo-HashtableDeep $_ })
        }
        if ($InputObject -is [hashtable]) {
            $result = @{}
            foreach ($key in $InputObject.Keys) {
                $result[$key] = ConvertTo-HashtableDeep $InputObject[$key]
            }
            return $result
        }
        if ($InputObject -is [PSCustomObject]) {
            $result = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-HashtableDeep $property.Value
            }
            return $result
        }
        try { return $InputObject.ToString() } catch { return $InputObject.GetType().FullName }
    }
}

function Export-InventoryReport {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Data,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $true)]
        [string]$BaseName
    )

    if (-not (Test-Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $exportedFiles = @()

    if ($Format -in @("JSON", "Both")) {
        try {
            $jsonPath = Join-Path $OutputDirectory "${BaseName}.json"
            $Data | ConvertTo-Json -Depth 100 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
            $exportedFiles += $jsonPath
            Write-Host "✓ Exported JSON: $jsonPath" -ForegroundColor Green
        }
        catch {
            Add-InventoryError -Component "Export" -Message "Failed to export JSON" -Exception $_
        }
    }

    if ($Format -in @("CSV", "Both")) {
        try {
            # Helper function to convert hashtables to PSCustomObjects and flatten nested objects for CSV
            function ConvertTo-CsvFriendly {
                param([array]$Items)
                $Items | ForEach-Object {
                    $item = $_
                    $flat = [ordered]@{}
                    if ($item -is [hashtable] -or $item -is [System.Collections.Specialized.OrderedDictionary]) {
                        foreach ($key in $item.Keys) {
                            $value = $item[$key]
                            if ($value -is [hashtable] -or $value -is [System.Collections.Specialized.OrderedDictionary] -or $value -is [PSCustomObject]) {
                                $flat[$key] = ($value | ConvertTo-Json -Compress -Depth 5)
                            }
                            elseif ($value -is [array]) {
                                $flat[$key] = ($value -join "; ")
                            }
                            else {
                                $flat[$key] = $value
                            }
                        }
                    }
                    else {
                        # PSCustomObject - convert properties
                        foreach ($prop in $item.PSObject.Properties) {
                            $value = $prop.Value
                            if ($value -is [hashtable] -or $value -is [System.Collections.Specialized.OrderedDictionary] -or $value -is [PSCustomObject]) {
                                $flat[$prop.Name] = ($value | ConvertTo-Json -Compress -Depth 5)
                            }
                            elseif ($value -is [array]) {
                                $flat[$prop.Name] = ($value -join "; ")
                            }
                            else {
                                $flat[$prop.Name] = $value
                            }
                        }
                    }
                    [PSCustomObject]$flat
                }
            }

            if ($Data.Subscriptions.Count -gt 0) {
                $csvPath = Join-Path $OutputDirectory "${BaseName}_Subscriptions.csv"
                ConvertTo-CsvFriendly -Items $Data.Subscriptions | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
                $exportedFiles += $csvPath
            }
            if ($Data.Resources.Count -gt 0) {
                $csvPath = Join-Path $OutputDirectory "${BaseName}_Resources.csv"
                ConvertTo-CsvFriendly -Items $Data.Resources | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
                $exportedFiles += $csvPath
            }
            if ($Data.AzureLocal.Clusters.Count -gt 0) {
                $csvPath = Join-Path $OutputDirectory "${BaseName}_AzureLocal_Clusters.csv"
                ConvertTo-CsvFriendly -Items $Data.AzureLocal.Clusters | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
                $exportedFiles += $csvPath
            }
            Write-Host "✓ Exported CSV files" -ForegroundColor Green
        }
        catch {
            Add-InventoryError -Component "Export" -Message "Failed to export CSV" -Exception $_
        }
    }

    return $exportedFiles
}

#endregion

#region Authentication and Connection

function Test-AzurePermissions {
    <#
    .SYNOPSIS
        Tests if the current user has sufficient permissions to run inventory.
    .DESCRIPTION
        Checks for Reader role on at least one subscription and ability to list management groups.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId
    )

    $permissions = [ordered]@{
        CanListSubscriptions    = $false
        CanListManagementGroups = $false
        CanListResources        = $false
        SubscriptionCount       = 0
        Errors                  = @()
    }

    try {
        # Test subscription access
        $subs = @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop)
        $permissions.SubscriptionCount = $subs.Count
        $permissions.CanListSubscriptions = ($subs.Count -gt 0)
    }
    catch {
        $permissions.Errors += "Cannot list subscriptions: $($_.Exception.Message)"
    }

    try {
        # Test management group access
        $mgs = @(Get-AzManagementGroup -ErrorAction Stop)
        $permissions.CanListManagementGroups = ($mgs.Count -gt 0)
    }
    catch {
        $permissions.Errors += "Cannot list management groups: $($_.Exception.Message)"
    }

    if ($permissions.CanListSubscriptions -and $permissions.SubscriptionCount -gt 0) {
        try {
            # Test resource listing on first subscription
            $firstSub = (Get-AzSubscription -TenantId $TenantId | Select-Object -First 1)
            Set-AzContext -SubscriptionId $firstSub.Id -TenantId $TenantId -ErrorAction Stop | Out-Null
            $resources = @(Get-AzResource -ErrorAction Stop | Select-Object -First 1)
            $permissions.CanListResources = $true
        }
        catch {
            $permissions.Errors += "Cannot list resources: $($_.Exception.Message)"
        }
    }

    return $permissions
}

function Initialize-AzureConnection {
    <#
    .SYNOPSIS
        Intelligently initializes Azure connection with smart context detection.
    .DESCRIPTION
        1. Checks for existing Azure context
        2. Validates if context matches target tenant
        3. Tests permissions before proceeding
        4. Uses device code authentication if needed (user-friendly for headless/remote)
        5. Provides clear guidance on permission issues
    #>
    
    Write-ProgressStep -Activity "Authentication" -Status "Checking Azure context..."

    $context = $null
    $needsLogin = $false
    $existingContextValid = $false

    # Step 1: Check for existing Azure context
    try {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        
        if ($null -ne $context) {
            Write-Host ""
            Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
            Write-Host "│  Existing Azure Context Detected                            │" -ForegroundColor Cyan
            Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
            Write-Host "  Account: $($context.Account.Id)" -ForegroundColor White
            Write-Host "  Tenant:  $($context.Tenant.Id)" -ForegroundColor White
            Write-Host ""
            
            # Step 2: Check if context matches target tenant
            if ($context.Tenant.Id -eq $TenantId) {
                Write-Host "✓ Context matches target tenant" -ForegroundColor Green
                
                # Step 3: Validate token is still valid
                try {
                    $testAccess = Get-AzTenant -TenantId $TenantId -ErrorAction Stop
                    Write-Host "✓ Token is valid and not expired" -ForegroundColor Green
                    $existingContextValid = $true
                }
                catch {
                    Write-Host "⚠ Token appears to be expired or invalid" -ForegroundColor Yellow
                    $needsLogin = $true
                }
            }
            else {
                Write-Host "⚠ Context is for different tenant: $($context.Tenant.Id)" -ForegroundColor Yellow
                Write-Host "  Target tenant: $TenantId" -ForegroundColor Yellow
                $needsLogin = $true
            }
        }
        else {
            Write-Host ""
            Write-Host "ℹ No existing Azure context found" -ForegroundColor Yellow
            $needsLogin = $true
        }
    }
    catch {
        Write-Host "⚠ Could not check existing context: $($_.Exception.Message)" -ForegroundColor Yellow
        $needsLogin = $true
    }

    # Step 4: Login if needed using device code flow
    if ($needsLogin) {
        Write-Host ""
        Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
        Write-Host "│  Authentication Required                                     │" -ForegroundColor Yellow
        Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Using device code authentication (works in any terminal/remote session)" -ForegroundColor Cyan
        Write-Host ""
        
        try {
            # Use device code authentication - works everywhere including SSH, containers, etc.
            Connect-AzAccount -TenantId $TenantId -UseDeviceAuthentication -ErrorAction Stop | Out-Null
            $context = Get-AzContext -ErrorAction Stop
            
            if ($context.Tenant.Id -ne $TenantId) {
                throw "Authentication succeeded but connected to wrong tenant. Expected: $TenantId, Got: $($context.Tenant.Id)"
            }
            
            Write-Host ""
            Write-Host "✓ Successfully authenticated" -ForegroundColor Green
            $existingContextValid = $true
        }
        catch {
            Write-Host ""
            Write-Host "❌ Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
            throw "Failed to authenticate to Azure tenant $TenantId"
        }
    }

    # Step 5: Validate permissions
    Write-Host ""
    Write-Host "Validating permissions..." -ForegroundColor Cyan
    
    $permissions = Test-AzurePermissions -TenantId $TenantId
    
    if (-not $permissions.CanListSubscriptions) {
        Write-Host ""
        Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Red
        Write-Host "│  ❌ Insufficient Permissions                                 │" -ForegroundColor Red
        Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor Red
        Write-Host ""
        Write-Host "User: $($context.Account.Id)" -ForegroundColor White
        Write-Host ""
        Write-Host "This account cannot list subscriptions in tenant $TenantId." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Required permissions:" -ForegroundColor Cyan
        Write-Host "  • Reader role on at least one subscription" -ForegroundColor White
        Write-Host "  • Or: Management Group Reader at tenant root" -ForegroundColor White
        Write-Host ""
        Write-Host "Errors:" -ForegroundColor Yellow
        foreach ($err in $permissions.Errors) {
            Write-Host "  - $err" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  1. Request Reader role from your Azure administrator" -ForegroundColor White
        Write-Host "  2. Run this script with a different account that has access" -ForegroundColor White
        Write-Host "     Disconnect-AzAccount" -ForegroundColor DarkGray
        Write-Host "     .\Inventory-AzureTenant.ps1 -TenantId '$TenantId'" -ForegroundColor DarkGray
        Write-Host ""
        
        throw "Insufficient permissions to run inventory. See above for details."
    }

    # Success - show what we can access
    Write-Host ""
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "│  ✓ Authentication & Permissions Validated                   │" -ForegroundColor Green
    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Account:       $($context.Account.Id)" -ForegroundColor White
    Write-Host "  Tenant:        $TenantId" -ForegroundColor White
    Write-Host "  Subscriptions: $($permissions.SubscriptionCount) accessible" -ForegroundColor White
    Write-Host "  Mgmt Groups:   $(if ($permissions.CanListManagementGroups) { 'Yes' } else { 'No' })" -ForegroundColor White
    Write-Host "  Resources:     $(if ($permissions.CanListResources) { 'Yes' } else { 'Limited' })" -ForegroundColor White
    Write-Host ""

    # Update inventory metadata
    $script:Inventory.Metadata.GeneratedBy = $context.Account.Id

    # Get tenant display name
    try {
        $tenantInfo = Get-AzTenant -TenantId $TenantId -ErrorAction Stop
        $script:Inventory.Tenant.DisplayName = $tenantInfo.Name
        $script:Inventory.Tenant.DefaultDomain = $tenantInfo.DefaultDomain
        $script:Inventory.Tenant.TenantType = $tenantInfo.TenantType
        $script:Inventory.Metadata.TenantName = $tenantInfo.Name
        Write-Host "  Tenant Name:   $($tenantInfo.Name)" -ForegroundColor White
        Write-Host ""
    }
    catch {
        Add-InventoryError -Component "TenantInfo" -Message "Failed to get tenant details" -Exception $_
    }

    return $true
}

#endregion

#region Management Groups

function Get-ManagementGroupInventory {
    Write-ProgressStep -Activity "Management Groups" -Status "Scanning management group hierarchy"

    try {
        $mgGroups = Get-AzManagementGroup -ErrorAction Stop

        foreach ($mg in $mgGroups) {
            try {
                $mgDetail = Get-AzManagementGroup -GroupId $mg.Name -Expand -Recurse -ErrorAction Stop

                $mgEntry = [ordered]@{
                    Id            = $mgDetail.Id
                    Name          = $mgDetail.Name
                    DisplayName   = $mgDetail.DisplayName
                    TenantId      = $mgDetail.TenantId
                    ParentId      = $mgDetail.ParentId
                    ParentName    = $mgDetail.ParentName
                    ChildrenCount = $mgDetail.Children.Count
                }

                $script:Inventory.ManagementGroups += $mgEntry
            }
            catch {
                Add-InventoryError -Component "ManagementGroups" -Message "Failed for $($mg.Name)" -Exception $_ -ResourceId $mg.Id
            }
        }

        Write-Host "✓ Found $($script:Inventory.ManagementGroups.Count) management groups" -ForegroundColor Green
    }
    catch {
        Add-InventoryError -Component "ManagementGroups" -Message "Failed to retrieve management groups" -Exception $_
    }
}

#endregion

#region Subscriptions

function Get-SubscriptionInventory {
    Write-ProgressStep -Activity "Subscriptions" -Status "Scanning subscriptions"

    try {
        $allSubscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.TenantId -eq $TenantId })

        if ($allSubscriptions.Count -eq 0) {
            Write-Warning "No subscriptions found in tenant $TenantId"
            return
        }

        if ($SubscriptionFilter -and $SubscriptionFilter.Count -gt 0) {
            $subscriptions = $allSubscriptions | Where-Object { $_.Id -in $SubscriptionFilter }
            Write-Host "Filtering to $($subscriptions.Count) subscriptions" -ForegroundColor Yellow
        }
        else {
            $subscriptions = $allSubscriptions
        }

        foreach ($sub in $subscriptions) {
            try {
                Set-AzContext -SubscriptionId $sub.Id -TenantId $TenantId -ErrorAction Stop | Out-Null
                $subDetail = Get-AzSubscription -SubscriptionId $sub.Id -ErrorAction Stop

                $subEntry = [ordered]@{
                    SubscriptionId = $subDetail.Id
                    Name           = $subDetail.Name
                    State          = $subDetail.State
                    TenantId       = $subDetail.TenantId
                    Tags           = $subDetail.Tags ?? @{}
                }

                try {
                    $providers = @(Get-AzResourceProvider -ErrorAction SilentlyContinue | Where-Object { $_.RegistrationState -eq 'Registered' })
                    $subEntry.RegisteredProviders = @($providers | Select-Object -ExpandProperty ProviderNamespace | Sort-Object)
                    $hciProvider = $providers | Where-Object { $_.ProviderNamespace -eq 'Microsoft.AzureStackHCI' }
                    $subEntry.AzureStackHCIProviderRegistered = ($null -ne $hciProvider)
                }
                catch {
                    $subEntry.RegisteredProviders = @()
                    $subEntry.AzureStackHCIProviderRegistered = $false
                }

                $script:Inventory.Subscriptions += $subEntry
                $script:Inventory.Statistics.TotalSubscriptions++
            }
            catch {
                Add-InventoryError -Component "Subscriptions" -Message "Failed for $($sub.Name)" -Exception $_ -ResourceId $sub.Id
            }
        }

        Write-Host "✓ Found $($script:Inventory.Subscriptions.Count) subscriptions" -ForegroundColor Green
    }
    catch {
        Add-InventoryError -Component "Subscriptions" -Message "Failed to retrieve subscriptions" -Exception $_
    }
}

#endregion

#region Resource Groups

function Get-ResourceGroupInventory {
    Write-ProgressStep -Activity "Resource Groups" -Status "Scanning resource groups"

    foreach ($sub in $script:Inventory.Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
            $resourceGroups = Get-AzResourceGroup -ErrorAction Stop

            foreach ($rg in $resourceGroups) {
                $rgEntry = [ordered]@{
                    ResourceGroupName = $rg.ResourceGroupName
                    Location          = $rg.Location
                    ProvisioningState = $rg.ProvisioningState
                    ResourceId        = $rg.ResourceId
                    SubscriptionId    = $sub.SubscriptionId
                    SubscriptionName  = $sub.Name
                    Tags              = $rg.Tags ?? @{}
                }

                $script:Inventory.ResourceGroups += $rgEntry
                $script:Inventory.Statistics.TotalResourceGroups++
            }
        }
        catch {
            Add-InventoryError -Component "ResourceGroups" -Message "Failed for $($sub.Name)" -Exception $_ -ResourceId $sub.SubscriptionId
        }
    }

    Write-Host "✓ Found $($script:Inventory.ResourceGroups.Count) resource groups" -ForegroundColor Green
}

#endregion

#region Resources

function Get-ResourceInventory {
    Write-ProgressStep -Activity "Resources" -Status "Scanning all Azure resources"

    foreach ($sub in $script:Inventory.Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
            Write-Host "  Scanning: $($sub.Name)..." -ForegroundColor Cyan

            $resources = Get-AzResource -ErrorAction Stop

            foreach ($resource in $resources) {
                $resourceEntry = [ordered]@{
                    ResourceId        = $resource.ResourceId
                    Name              = $resource.Name
                    ResourceType      = $resource.ResourceType
                    ResourceGroupName = $resource.ResourceGroupName
                    Location          = $resource.Location
                    SubscriptionId    = $sub.SubscriptionId
                    SubscriptionName  = $sub.Name
                    Tags              = $resource.Tags ?? @{}
                    Kind              = $resource.Kind
                    Sku               = if ($resource.Sku) {
                        [ordered]@{
                            Name = $resource.Sku.Name
                            Tier = $resource.Sku.Tier
                            Size = $resource.Sku.Size
                        }
                    }
                    else { $null }
                    Properties        = ConvertTo-HashtableDeep $resource.Properties
                }

                $script:Inventory.Resources += $resourceEntry
                $script:Inventory.Statistics.TotalResources++

                if (-not $script:Inventory.Statistics.ResourcesByType.ContainsKey($resource.ResourceType)) {
                    $script:Inventory.Statistics.ResourcesByType[$resource.ResourceType] = 0
                }
                $script:Inventory.Statistics.ResourcesByType[$resource.ResourceType]++

                if (-not $script:Inventory.Statistics.ResourcesByLocation.ContainsKey($resource.Location)) {
                    $script:Inventory.Statistics.ResourcesByLocation[$resource.Location] = 0
                }
                $script:Inventory.Statistics.ResourcesByLocation[$resource.Location]++
            }
        }
        catch {
            Add-InventoryError -Component "Resources" -Message "Failed for $($sub.Name)" -Exception $_ -ResourceId $sub.SubscriptionId
        }
    }

    Write-Host "✓ Found $($script:Inventory.Resources.Count) resources" -ForegroundColor Green
}

#endregion

#region Azure Local Resources

function Get-AzureLocalInventory {
    if (-not $IncludeAzureLocal) { return }

    Write-ProgressStep -Activity "Azure Local Resources" -Status "Scanning Azure Stack HCI resources"

    foreach ($sub in $script:Inventory.Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null

            $clusters = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.AzureStackHCI/clusters' }
            foreach ($cluster in $clusters) {
                $script:Inventory.AzureLocal.Clusters += [ordered]@{
                    ResourceId        = $cluster.ResourceId
                    Name              = $cluster.Name
                    ResourceGroupName = $cluster.ResourceGroupName
                    Location          = $cluster.Location
                    SubscriptionId    = $sub.SubscriptionId
                    Properties        = $cluster.Properties
                    Tags              = $cluster.Tags
                }
            }

            $customLocations = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.ExtendedLocation/customLocations' }
            foreach ($cl in $customLocations) {
                $script:Inventory.AzureLocal.CustomLocations += [ordered]@{
                    ResourceId        = $cl.ResourceId
                    Name              = $cl.Name
                    ResourceGroupName = $cl.ResourceGroupName
                    Location          = $cl.Location
                    Properties        = $cl.Properties
                }
            }

            $logicalNetworks = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.AzureStackHCI/logicalnetworks' }
            foreach ($lnet in $logicalNetworks) {
                $script:Inventory.AzureLocal.LogicalNetworks += [ordered]@{
                    ResourceId        = $lnet.ResourceId
                    Name              = $lnet.Name
                    ResourceGroupName = $lnet.ResourceGroupName
                    Properties        = $lnet.Properties
                }
            }

            $vmImages = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.AzureStackHCI/galleryimages' }
            foreach ($img in $vmImages) {
                $script:Inventory.AzureLocal.VirtualMachineImages += [ordered]@{
                    ResourceId = $img.ResourceId
                    Name       = $img.Name
                    Properties = $img.Properties
                }
            }

            $marketplaceImages = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.AzureStackHCI/marketplacegalleryimages' }
            foreach ($mktImg in $marketplaceImages) {
                $script:Inventory.AzureLocal.MarketplaceGalleryImages += [ordered]@{
                    ResourceId = $mktImg.ResourceId
                    Name       = $mktImg.Name
                    Properties = $mktImg.Properties
                }
            }

            $nics = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.AzureStackHCI/networkinterfaces' }
            foreach ($nic in $nics) {
                $script:Inventory.AzureLocal.NetworkInterfaces += [ordered]@{
                    ResourceId = $nic.ResourceId
                    Name       = $nic.Name
                    Properties = $nic.Properties
                }
            }

            $vhds = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.AzureStackHCI/virtualharddisks' }
            foreach ($vhd in $vhds) {
                $script:Inventory.AzureLocal.VirtualHardDisks += [ordered]@{
                    ResourceId = $vhd.ResourceId
                    Name       = $vhd.Name
                    Properties = $vhd.Properties
                }
            }
        }
        catch {
            Add-InventoryError -Component "AzureLocal" -Message "Failed for $($sub.Name)" -Exception $_ -ResourceId $sub.SubscriptionId
        }
    }

    $totalAzureLocal = $script:Inventory.AzureLocal.Clusters.Count +
    $script:Inventory.AzureLocal.CustomLocations.Count +
    $script:Inventory.AzureLocal.LogicalNetworks.Count +
    $script:Inventory.AzureLocal.VirtualMachineImages.Count +
    $script:Inventory.AzureLocal.MarketplaceGalleryImages.Count +
    $script:Inventory.AzureLocal.NetworkInterfaces.Count +
    $script:Inventory.AzureLocal.VirtualHardDisks.Count

    Write-Host "✓ Found $totalAzureLocal Azure Local resources:" -ForegroundColor Green
    Write-Host "  - Clusters: $($script:Inventory.AzureLocal.Clusters.Count)" -ForegroundColor Gray
    Write-Host "  - Custom Locations: $($script:Inventory.AzureLocal.CustomLocations.Count)" -ForegroundColor Gray
    Write-Host "  - Logical Networks: $($script:Inventory.AzureLocal.LogicalNetworks.Count)" -ForegroundColor Gray
}

#endregion

#region Networking, Compute, Storage, Security, Monitoring

function Get-NetworkingInventory {
    Write-ProgressStep -Activity "Networking Resources" -Status "Scanning networking infrastructure"

    # Basic resources from inventory
    $vnets = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/virtualNetworks' }
    $nsgs = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/networkSecurityGroups' }
    $nics = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/networkInterfaces' }
    $pips = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/publicIPAddresses' }
    $lbs = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/loadBalancers' }
    $pes = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/privateEndpoints' }
    $bastions = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/bastionHosts' }
    $natGateways = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/natGateways' }
    $privateDnsZones = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/privateDnsZones' }

    # Get detailed VNet information including subnets and peerings
    Write-Host "  Getting detailed VNet configurations..." -ForegroundColor Cyan
    $detailedVNets = @()
    foreach ($vnet in $vnets) {
        try {
            # Set context to the VNet's subscription
            $vnetSub = $script:Inventory.Subscriptions | Where-Object { $_.SubscriptionId -eq $vnet.SubscriptionId }
            if ($vnetSub) {
                Set-AzContext -SubscriptionId $vnetSub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
                
                # Get full VNet details
                $vnetDetail = Get-AzVirtualNetwork -ResourceGroupName $vnet.ResourceGroupName -Name $vnet.Name -ErrorAction SilentlyContinue
                if ($vnetDetail) {
                    $vnetEntry = [ordered]@{
                        ResourceId           = $vnetDetail.Id
                        Name                 = $vnetDetail.Name
                        ResourceType         = $vnet.ResourceType
                        ResourceGroupName    = $vnetDetail.ResourceGroupName
                        Location             = $vnetDetail.Location
                        SubscriptionId       = $vnet.SubscriptionId
                        SubscriptionName     = $vnetSub.Name
                        Tags                 = $vnetDetail.Tag ?? @{}
                        AddressSpace         = @($vnetDetail.AddressSpace.AddressPrefixes)
                        DnsServers           = @($vnetDetail.DhcpOptions.DnsServers)
                        Subnets              = @($vnetDetail.Subnets | ForEach-Object {
                                [ordered]@{
                                    Name                 = $_.Name
                                    AddressPrefix        = $_.AddressPrefix
                                    Id                   = $_.Id
                                    RouteTable           = $_.RouteTable.Id
                                    NetworkSecurityGroup = $_.NetworkSecurityGroup.Id
                                    ServiceEndpoints     = @($_.ServiceEndpoints | ForEach-Object { $_.Service })
                                    Delegations          = @($_.Delegations | ForEach-Object { $_.ServiceName })
                                }
                            })
                        VNetPeerings         = @($vnetDetail.VirtualNetworkPeerings | ForEach-Object {
                                [ordered]@{
                                    Name                      = $_.Name
                                    Id                        = $_.Id
                                    PeeringState              = $_.PeeringState
                                    PeeringSyncLevel          = $_.PeeringSyncLevel
                                    RemoteVirtualNetwork      = $_.RemoteVirtualNetwork.Id
                                    AllowVirtualNetworkAccess = $_.AllowVirtualNetworkAccess
                                    AllowForwardedTraffic     = $_.AllowForwardedTraffic
                                    AllowGatewayTransit       = $_.AllowGatewayTransit
                                    UseRemoteGateways         = $_.UseRemoteGateways
                                    RemoteAddressSpace        = @($_.RemoteAddressSpace.AddressPrefixes)
                                }
                            })
                        EnableDdosProtection = $vnetDetail.EnableDdosProtection
                        EnableVmProtection   = $vnetDetail.EnableVmProtection
                        ProvisioningState    = $vnetDetail.ProvisioningState
                    }
                    $detailedVNets += $vnetEntry
                }
                else {
                    # Fallback to basic info if detailed get fails
                    $detailedVNets += $vnet
                }
            }
            else {
                # Fallback if subscription not found
                $detailedVNets += $vnet
            }
        }
        catch {
            Write-Warning "Failed to get details for VNet $($vnet.Name): $_"
            $detailedVNets += $vnet
        }
    }

    $script:Inventory.Networking.VirtualNetworks = @($detailedVNets)
    $script:Inventory.Networking.NetworkSecurityGroups = @($nsgs)
    $script:Inventory.Networking.NetworkInterfaces = @($nics)
    $script:Inventory.Networking.PublicIPAddresses = @($pips)
    $script:Inventory.Networking.LoadBalancers = @($lbs)
    $script:Inventory.Networking.PrivateEndpoints = @($pes)
    $script:Inventory.Networking.Bastions = @($bastions)
    $script:Inventory.Networking.NATGateways = @($natGateways)
    $script:Inventory.Networking.PrivateDNSZones = @($privateDnsZones)

    # Get detailed VPN Gateway information - must iterate by resource group
    Write-Host "  Scanning VPN Gateways..." -ForegroundColor Cyan
    foreach ($sub in $script:Inventory.Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
            
            # Get resource groups for this subscription
            $subResourceGroups = $script:Inventory.ResourceGroups | Where-Object { $_.SubscriptionId -eq $sub.SubscriptionId }
            
            foreach ($rg in $subResourceGroups) {
                # VPN Gateways - requires ResourceGroupName parameter
                $vpnGateways = Get-AzVirtualNetworkGateway -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
                foreach ($gw in $vpnGateways) {
                    $gwEntry = [ordered]@{
                        ResourceId             = $gw.Id
                        Name                   = $gw.Name
                        ResourceGroupName      = $gw.ResourceGroupName
                        Location               = $gw.Location
                        SubscriptionId         = $sub.SubscriptionId
                        SubscriptionName       = $sub.Name
                        GatewayType            = $gw.GatewayType
                        VpnType                = $gw.VpnType
                        Sku                    = $gw.Sku.Name
                        EnableBgp              = $gw.EnableBgp
                        ActiveActive           = $gw.ActiveActive
                        BgpSettings            = if ($gw.BgpSettings) {
                            [ordered]@{
                                Asn                 = $gw.BgpSettings.Asn
                                BgpPeeringAddress   = $gw.BgpSettings.BgpPeeringAddress
                                PeerWeight          = $gw.BgpSettings.PeerWeight
                                BgpPeeringAddresses = @($gw.BgpSettings.BgpPeeringAddresses | ForEach-Object {
                                        [ordered]@{
                                            IpConfigurationId    = $_.IpConfigurationId
                                            DefaultBgpIpAddress  = $_.DefaultBgpIpAddresses
                                            CustomBgpIpAddresses = $_.CustomBgpIpAddresses
                                            TunnelIpAddresses    = $_.TunnelIpAddresses
                                        }
                                    })
                            }
                        }
                        else { $null }
                        IpConfigurations       = @($gw.IpConfigurations | ForEach-Object {
                                [ordered]@{
                                    Name              = $_.Name
                                    PrivateIpAddress  = $_.PrivateIpAddress
                                    PublicIpAddressId = $_.PublicIpAddress.Id
                                    SubnetId          = $_.Subnet.Id
                                }
                            })
                        VpnClientConfiguration = if ($gw.VpnClientConfiguration) {
                            [ordered]@{
                                VpnClientProtocols     = $gw.VpnClientConfiguration.VpnClientProtocols
                                VpnClientAddressPool   = $gw.VpnClientConfiguration.VpnClientAddressPool.AddressPrefixes
                                VpnAuthenticationTypes = $gw.VpnClientConfiguration.VpnAuthenticationTypes
                            }
                        }
                        else { $null }
                        ProvisioningState      = $gw.ProvisioningState
                        Tags                   = $gw.Tags ?? @{}
                    }
                    $script:Inventory.Networking.VPNGateways += $gwEntry
                }

                # Local Network Gateways - also requires ResourceGroupName
                $localGateways = Get-AzLocalNetworkGateway -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
                foreach ($lng in $localGateways) {
                    $lngEntry = [ordered]@{
                        ResourceId               = $lng.Id
                        Name                     = $lng.Name
                        ResourceGroupName        = $lng.ResourceGroupName
                        Location                 = $lng.Location
                        SubscriptionId           = $sub.SubscriptionId
                        SubscriptionName         = $sub.Name
                        GatewayIpAddress         = $lng.GatewayIpAddress
                        Fqdn                     = $lng.Fqdn
                        LocalNetworkAddressSpace = $lng.LocalNetworkAddressSpace.AddressPrefixes
                        BgpSettings              = if ($lng.BgpSettings) {
                            [ordered]@{
                                Asn               = $lng.BgpSettings.Asn
                                BgpPeeringAddress = $lng.BgpSettings.BgpPeeringAddress
                                PeerWeight        = $lng.BgpSettings.PeerWeight
                            }
                        }
                        else { $null }
                        ProvisioningState        = $lng.ProvisioningState
                        Tags                     = $lng.Tags ?? @{}
                    }
                    $script:Inventory.Networking.LocalNetworkGateways += $lngEntry
                }

                # VPN Connections - also requires ResourceGroupName
                $vpnConnections = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
                foreach ($conn in $vpnConnections) {
                    $connEntry = [ordered]@{
                        ResourceId                     = $conn.Id
                        Name                           = $conn.Name
                        ResourceGroupName              = $conn.ResourceGroupName
                        Location                       = $conn.Location
                        SubscriptionId                 = $sub.SubscriptionId
                        SubscriptionName               = $sub.Name
                        ConnectionType                 = $conn.ConnectionType
                        ConnectionProtocol             = $conn.ConnectionProtocol
                        RoutingWeight                  = $conn.RoutingWeight
                        SharedKey                      = "***REDACTED***"
                        EnableBgp                      = $conn.EnableBgp
                        UsePolicyBasedTrafficSelectors = $conn.UsePolicyBasedTrafficSelectors
                        ConnectionStatus               = $conn.ConnectionStatus
                        EgressBytesTransferred         = $conn.EgressBytesTransferred
                        IngressBytesTransferred        = $conn.IngressBytesTransferred
                        VirtualNetworkGateway1         = $conn.VirtualNetworkGateway1.Id
                        VirtualNetworkGateway2         = $conn.VirtualNetworkGateway2.Id
                        LocalNetworkGateway2           = $conn.LocalNetworkGateway2.Id
                        IpsecPolicies                  = @($conn.IpsecPolicies | ForEach-Object {
                                [ordered]@{
                                    SaLifeTimeSeconds   = $_.SaLifeTimeSeconds
                                    SaDataSizeKilobytes = $_.SaDataSizeKilobytes
                                    IpsecEncryption     = $_.IpsecEncryption
                                    IpsecIntegrity      = $_.IpsecIntegrity
                                    IkeEncryption       = $_.IkeEncryption
                                    IkeIntegrity        = $_.IkeIntegrity
                                    DhGroup             = $_.DhGroup
                                    PfsGroup            = $_.PfsGroup
                                }
                            })
                        ProvisioningState              = $conn.ProvisioningState
                        Tags                           = $conn.Tags ?? @{}
                    }
                    $script:Inventory.Networking.VPNConnections += $connEntry
                }
            }  # End of resource group loop

            # Route Tables - this one works without ResourceGroupName
            $routeTables = Get-AzRouteTable -ErrorAction SilentlyContinue
            foreach ($rt in $routeTables) {
                $rtEntry = [ordered]@{
                    ResourceId                 = $rt.Id
                    Name                       = $rt.Name
                    ResourceGroupName          = $rt.ResourceGroupName
                    Location                   = $rt.Location
                    SubscriptionId             = $sub.SubscriptionId
                    SubscriptionName           = $sub.Name
                    DisableBgpRoutePropagation = $rt.DisableBgpRoutePropagation
                    Routes                     = @($rt.Routes | ForEach-Object {
                            [ordered]@{
                                Name              = $_.Name
                                AddressPrefix     = $_.AddressPrefix
                                NextHopType       = $_.NextHopType
                                NextHopIpAddress  = $_.NextHopIpAddress
                                ProvisioningState = $_.ProvisioningState
                            }
                        })
                    Subnets                    = @($rt.Subnets.Id)
                    ProvisioningState          = $rt.ProvisioningState
                    Tags                       = $rt.Tags ?? @{}
                }
                $script:Inventory.Networking.RouteTables += $rtEntry
            }
        }
        catch {
            Add-InventoryError -Component "NetworkingAdvanced" -Message "Failed advanced networking scan for $($sub.Name)" -Exception $_ -ResourceId $sub.SubscriptionId
        }
    }

    # Get detailed public IP info
    Write-Host "  Scanning Public IP Details..." -ForegroundColor Cyan
    $publicIpDetails = @()
    foreach ($sub in $script:Inventory.Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
            $publicIps = Get-AzPublicIpAddress -ErrorAction SilentlyContinue
            foreach ($pip in $publicIps) {
                $pipEntry = [ordered]@{
                    ResourceId               = $pip.Id
                    Name                     = $pip.Name
                    ResourceGroupName        = $pip.ResourceGroupName
                    Location                 = $pip.Location
                    SubscriptionId           = $sub.SubscriptionId
                    SubscriptionName         = $sub.Name
                    IpAddress                = $pip.IpAddress
                    PublicIpAllocationMethod = $pip.PublicIpAllocationMethod
                    Sku                      = $pip.Sku.Name
                    IpConfigurationId        = $pip.IpConfiguration.Id
                    DnsSettings              = if ($pip.DnsSettings) {
                        [ordered]@{
                            DomainNameLabel = $pip.DnsSettings.DomainNameLabel
                            Fqdn            = $pip.DnsSettings.Fqdn
                        }
                    }
                    else { $null }
                    Zones                    = $pip.Zones
                    Tags                     = $pip.Tags ?? @{}
                }
                $publicIpDetails += $pipEntry
            }
        }
        catch {
            Add-InventoryError -Component "PublicIPs" -Message "Failed to get public IP details for $($sub.Name)" -Exception $_ -ResourceId $sub.SubscriptionId
        }
    }
    $script:Inventory.Networking.PublicIPAddresses = $publicIpDetails

    Write-Host "✓ Found networking: VNets=$($vnets.Count), NSGs=$($nsgs.Count), VPNGWs=$($script:Inventory.Networking.VPNGateways.Count), VPNConns=$($script:Inventory.Networking.VPNConnections.Count)" -ForegroundColor Green
}

function Get-ComputeInventory {
    Write-ProgressStep -Activity "Compute Resources" -Status "Scanning compute infrastructure"

    $vms = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Compute/virtualMachines' }
    $disks = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Compute/disks' }
    $images = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Compute/images' }
    $vmss = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Compute/virtualMachineScaleSets' }

    $script:Inventory.Compute.VirtualMachines = @($vms)
    $script:Inventory.Compute.Disks = @($disks)
    $script:Inventory.Compute.Images = @($images)
    $script:Inventory.Compute.VMScaleSets = @($vmss)

    # Get detailed VM information including sizes, disks, and IPs
    Write-Host "  Scanning VM Details (sizes, disks, IPs)..." -ForegroundColor Cyan
    foreach ($sub in $script:Inventory.Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
            
            $vmList = Get-AzVM -Status -ErrorAction SilentlyContinue
            foreach ($vm in $vmList) {
                # Get network interfaces and IPs
                $privateIps = @()
                $publicIps = @()
                $nicDetails = @()
                
                foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
                    try {
                        $nicName = ($nicRef.Id -split '/')[-1]
                        $nicRg = ($nicRef.Id -split '/')[4]
                        $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $nicRg -ErrorAction SilentlyContinue
                        
                        if ($nic) {
                            foreach ($ipConfig in $nic.IpConfigurations) {
                                $privateIps += $ipConfig.PrivateIpAddress
                                
                                if ($ipConfig.PublicIpAddress) {
                                    $pipName = ($ipConfig.PublicIpAddress.Id -split '/')[-1]
                                    $pipRg = ($ipConfig.PublicIpAddress.Id -split '/')[4]
                                    $pip = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $pipRg -ErrorAction SilentlyContinue
                                    if ($pip) {
                                        $publicIps += $pip.IpAddress
                                    }
                                }
                            }
                            
                            $nicDetails += [ordered]@{
                                Name                        = $nic.Name
                                ResourceId                  = $nic.Id
                                PrivateIpAddress            = $nic.IpConfigurations[0].PrivateIpAddress
                                PrivateIpAllocationMethod   = $nic.IpConfigurations[0].PrivateIpAllocationMethod
                                SubnetId                    = $nic.IpConfigurations[0].Subnet.Id
                                Primary                     = $nicRef.Primary
                                EnableAcceleratedNetworking = $nic.EnableAcceleratedNetworking
                                EnableIPForwarding          = $nic.EnableIPForwarding
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Could not get NIC details for $($nicRef.Id)"
                    }
                }

                # Get disk details
                $dataDisks = @()
                foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
                    $diskInfo = $disks | Where-Object { $_.Name -eq $dataDisk.Name } | Select-Object -First 1
                    $dataDisks += [ordered]@{
                        Name               = $dataDisk.Name
                        Lun                = $dataDisk.Lun
                        SizeGB             = $dataDisk.DiskSizeGB
                        Caching            = $dataDisk.Caching
                        CreateOption       = $dataDisk.CreateOption
                        StorageAccountType = $diskInfo.Sku.Name ?? "Unknown"
                        ManagedDiskId      = $dataDisk.ManagedDisk.Id
                    }
                }

                $vmEntry = [ordered]@{
                    ResourceId         = $vm.Id
                    Name               = $vm.Name
                    ResourceGroupName  = $vm.ResourceGroupName
                    Location           = $vm.Location
                    SubscriptionId     = $sub.SubscriptionId
                    SubscriptionName   = $sub.Name
                    VmSize             = $vm.HardwareProfile.VmSize
                    ComputerName       = $vm.OSProfile.ComputerName
                    OsType             = if ($vm.StorageProfile.OsDisk.OsType) { $vm.StorageProfile.OsDisk.OsType.ToString() } else { "Unknown" }
                    PowerState         = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
                    ProvisioningState  = $vm.ProvisioningState
                    PrivateIpAddresses = $privateIps
                    PublicIpAddresses  = $publicIps
                    NetworkInterfaces  = $nicDetails
                    OsDisk             = [ordered]@{
                        Name               = $vm.StorageProfile.OsDisk.Name
                        SizeGB             = $vm.StorageProfile.OsDisk.DiskSizeGB
                        OsType             = if ($vm.StorageProfile.OsDisk.OsType) { $vm.StorageProfile.OsDisk.OsType.ToString() } else { "Unknown" }
                        Caching            = $vm.StorageProfile.OsDisk.Caching
                        CreateOption       = $vm.StorageProfile.OsDisk.CreateOption
                        StorageAccountType = if ($vm.StorageProfile.OsDisk.ManagedDisk) {
                            # Try to get disk SKU from disks inventory
                            $osDiskInfo = $disks | Where-Object { $_.Name -eq $vm.StorageProfile.OsDisk.Name } | Select-Object -First 1
                            $osDiskInfo.Sku.Name ?? "Unknown"
                        }
                        else { "Unknown" }
                        ManagedDiskId      = $vm.StorageProfile.OsDisk.ManagedDisk.Id
                    }
                    DataDisks          = $dataDisks
                    DataDiskCount      = $dataDisks.Count
                    ImageReference     = if ($vm.StorageProfile.ImageReference) {
                        [ordered]@{
                            Publisher = $vm.StorageProfile.ImageReference.Publisher
                            Offer     = $vm.StorageProfile.ImageReference.Offer
                            Sku       = $vm.StorageProfile.ImageReference.Sku
                            Version   = $vm.StorageProfile.ImageReference.Version
                        }
                    }
                    else { $null }
                    AvailabilitySet    = $vm.AvailabilitySetReference.Id
                    Zones              = $vm.Zones
                    Identity           = if ($vm.Identity) {
                        [ordered]@{
                            Type        = $vm.Identity.Type.ToString()
                            PrincipalId = $vm.Identity.PrincipalId
                            TenantId    = $vm.Identity.TenantId
                        }
                    }
                    else { $null }
                    BootDiagnostics    = if ($vm.DiagnosticsProfile.BootDiagnostics) {
                        [ordered]@{
                            Enabled    = $vm.DiagnosticsProfile.BootDiagnostics.Enabled
                            StorageUri = $vm.DiagnosticsProfile.BootDiagnostics.StorageUri
                        }
                    }
                    else { $null }
                    Tags               = $vm.Tags ?? @{}
                }

                $script:Inventory.Compute.VirtualMachineDetails += $vmEntry
            }
        }
        catch {
            Add-InventoryError -Component "ComputeDetails" -Message "Failed to get VM details for $($sub.Name)" -Exception $_ -ResourceId $sub.SubscriptionId
        }
    }

    Write-Host "✓ Found compute: VMs=$($vms.Count), Detailed=$($script:Inventory.Compute.VirtualMachineDetails.Count), Disks=$($disks.Count)" -ForegroundColor Green
}

function Get-StorageInventory {
    Write-ProgressStep -Activity "Storage Resources" -Status "Scanning storage"

    $storageAccounts = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Storage/storageAccounts' }
    $script:Inventory.Storage.StorageAccounts = @($storageAccounts)

    Write-Host "✓ Found storage: $($storageAccounts.Count) accounts" -ForegroundColor Green
}

function Get-SecurityInventory {
    Write-ProgressStep -Activity "Security Resources" -Status "Scanning security"

    $keyVaults = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.KeyVault/vaults' }
    $managedIdentities = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.ManagedIdentity/userAssignedIdentities' }

    $script:Inventory.Security.KeyVaults = @($keyVaults)
    $script:Inventory.Security.ManagedIdentities = @($managedIdentities)

    Write-Host "✓ Found security: KeyVaults=$($keyVaults.Count), ManagedIdentities=$($managedIdentities.Count)" -ForegroundColor Green
}

function Get-MonitoringInventory {
    Write-ProgressStep -Activity "Monitoring Resources" -Status "Scanning monitoring"

    $logAnalytics = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.OperationalInsights/workspaces' }
    $appInsights = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Insights/components' }

    $script:Inventory.Monitoring.LogAnalyticsWorkspaces = @($logAnalytics)
    $script:Inventory.Monitoring.ApplicationInsights = @($appInsights)

    Write-Host "✓ Found monitoring: LogAnalytics=$($logAnalytics.Count), AppInsights=$($appInsights.Count)" -ForegroundColor Green
}

#endregion

#region RBAC and Policy

function Get-RBACInventory {
    if (-not $IncludeRBAC) { return }

    Write-ProgressStep -Activity "RBAC" -Status "Scanning role assignments"

    foreach ($sub in $script:Inventory.Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
            $roleAssignments = Get-AzRoleAssignment -ErrorAction Stop

            foreach ($ra in $roleAssignments) {
                $raEntry = [ordered]@{
                    RoleAssignmentId   = $ra.RoleAssignmentId
                    RoleDefinitionName = $ra.RoleDefinitionName
                    ObjectId           = $ra.ObjectId
                    ObjectType         = $ra.ObjectType
                    DisplayName        = $ra.DisplayName
                    Scope              = $ra.Scope
                    SubscriptionId     = $sub.SubscriptionId
                }
                $script:Inventory.Security.RoleAssignments += $raEntry
            }
        }
        catch {
            Add-InventoryError -Component "RBAC" -Message "Failed for $($sub.Name)" -Exception $_ -ResourceId $sub.SubscriptionId
        }
    }

    Write-Host "✓ Found $($script:Inventory.Security.RoleAssignments.Count) role assignments" -ForegroundColor Green
}

function Get-PolicyInventory {
    Write-ProgressStep -Activity "Azure Policy" -Status "Scanning policy assignments"

    foreach ($sub in $script:Inventory.Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
            $policyAssignments = Get-AzPolicyAssignment -ErrorAction Stop

            foreach ($pa in $policyAssignments) {
                $paEntry = [ordered]@{
                    PolicyAssignmentId = $pa.PolicyAssignmentId
                    Name               = $pa.Name
                    DisplayName        = $pa.Properties.DisplayName
                    Scope              = $pa.Properties.Scope
                    EnforcementMode    = $pa.Properties.EnforcementMode
                    SubscriptionId     = $sub.SubscriptionId
                }
                $script:Inventory.Policy.PolicyAssignments += $paEntry
            }
        }
        catch {
            Add-InventoryError -Component "Policy" -Message "Failed for $($sub.Name)" -Exception $_ -ResourceId $sub.SubscriptionId
        }
    }

    Write-Host "✓ Found $($script:Inventory.Policy.PolicyAssignments.Count) policy assignments" -ForegroundColor Green
}

#endregion

#region Tags

function Get-TagInventory {
    Write-ProgressStep -Activity "Tags" -Status "Aggregating resource tags"

    $allTags = @{}

    foreach ($resource in $script:Inventory.Resources) {
        if ($resource.Tags) {
            foreach ($tagKey in $resource.Tags.Keys) {
                if (-not $allTags.ContainsKey($tagKey)) {
                    $allTags[$tagKey] = @()
                }
                $tagValue = $resource.Tags[$tagKey]
                if ($tagValue -notin $allTags[$tagKey]) {
                    $allTags[$tagKey] += $tagValue
                }
            }
        }
    }

    $script:Inventory.Tags.AllTags = $allTags
    Write-Host "✓ Found $($allTags.Count) unique tags" -ForegroundColor Green
}

#endregion

#region Main Execution

try {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " Azure Tenant Inventory" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Tenant ID: $TenantId" -ForegroundColor White
    Write-Host "Output Path: $OutputPath" -ForegroundColor White
    Write-Host "Format: $Format" -ForegroundColor White
    Write-Host ""

    # Initialize connection
    Initialize-AzureConnection

    # Scan tenant components
    Get-ManagementGroupInventory
    Get-SubscriptionInventory
    Get-ResourceGroupInventory
    Get-ResourceInventory

    # Scan specific resource types
    Get-AzureLocalInventory
    Get-NetworkingInventory
    Get-ComputeInventory
    Get-StorageInventory
    Get-SecurityInventory
    Get-MonitoringInventory

    # Scan policies and RBAC
    Get-PolicyInventory
    Get-RBACInventory

    # Aggregate tags
    Get-TagInventory

    # Finalize metadata
    $script:Inventory.Metadata.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss UTC")
    $script:Inventory.Metadata.DurationSeconds = [int]((Get-Date) - $script:StartTime).TotalSeconds

    # Export reports
    Write-ProgressStep -Activity "Export" -Status "Generating inventory reports"

    $baseName = "azure-inventory"
    $exportedFiles = Export-InventoryReport -Data $script:Inventory -OutputDirectory $OutputPath -BaseName $baseName

    # Display summary
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host " Inventory Complete!" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "Summary Statistics:" -ForegroundColor Cyan
    Write-Host "  Management Groups: $($script:Inventory.ManagementGroups.Count)" -ForegroundColor White
    Write-Host "  Subscriptions: $($script:Inventory.Statistics.TotalSubscriptions)" -ForegroundColor White
    Write-Host "  Resource Groups: $($script:Inventory.Statistics.TotalResourceGroups)" -ForegroundColor White
    Write-Host "  Total Resources: $($script:Inventory.Statistics.TotalResources)" -ForegroundColor White
    Write-Host ""
    Write-Host "Compute Resources:" -ForegroundColor Cyan
    Write-Host "  Virtual Machines: $($script:Inventory.Compute.VirtualMachineDetails.Count) (with full details)" -ForegroundColor White
    Write-Host "  Disks: $($script:Inventory.Compute.Disks.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "Networking Resources:" -ForegroundColor Cyan
    Write-Host "  Virtual Networks: $($script:Inventory.Networking.VirtualNetworks.Count)" -ForegroundColor White
    Write-Host "  VPN Gateways: $($script:Inventory.Networking.VPNGateways.Count)" -ForegroundColor White
    Write-Host "  Local Network Gateways: $($script:Inventory.Networking.LocalNetworkGateways.Count)" -ForegroundColor White
    Write-Host "  VPN Connections: $($script:Inventory.Networking.VPNConnections.Count)" -ForegroundColor White
    Write-Host "  Route Tables: $($script:Inventory.Networking.RouteTables.Count)" -ForegroundColor White
    Write-Host "  Public IPs: $($script:Inventory.Networking.PublicIPAddresses.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "Azure Local Resources:" -ForegroundColor Cyan
    Write-Host "  Clusters: $($script:Inventory.AzureLocal.Clusters.Count)" -ForegroundColor White
    Write-Host "  Custom Locations: $($script:Inventory.AzureLocal.CustomLocations.Count)" -ForegroundColor White
    Write-Host "  Logical Networks: $($script:Inventory.AzureLocal.LogicalNetworks.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "Duration: $($script:Inventory.Metadata.DurationSeconds) seconds" -ForegroundColor White
    Write-Host "Errors: $($script:Inventory.Errors.Count)" -ForegroundColor $(if ($script:Inventory.Errors.Count -gt 0) { "Yellow" } else { "White" })
    Write-Host ""
    Write-Host "Exported Files:" -ForegroundColor Cyan
    foreach ($file in $exportedFiles) {
        Write-Host "  $file" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "  1. Review inventory JSON in: $OutputPath" -ForegroundColor White
    Write-Host "  2. Run: .\Update-InfrastructureFromDiscovery.ps1" -ForegroundColor White
    Write-Host "  3. Validate infrastructure.yml updates" -ForegroundColor White
    Write-Host ""

    if ($script:Inventory.Errors.Count -gt 0) {
        Write-Host "⚠ Inventory completed with $($script:Inventory.Errors.Count) errors. Check the JSON output for details." -ForegroundColor Yellow
    }
}
catch {
    Write-Host ""
    Write-Host "❌ Inventory failed with critical error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
finally {
    Write-Progress -Activity "Complete" -Completed
}

#endregion
