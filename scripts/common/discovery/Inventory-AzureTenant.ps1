<#
.SYNOPSIS
    Read-only inventory of the Azure tenant in azure.tenant_id of infrastructure.yml.

.DESCRIPTION
    Records what the tenant holds, for planning and as a record before a deployment:
    - management groups and subscriptions (with the registered resource providers)
    - resource groups and every resource
    - Azure Local resources (clusters, custom locations, logical networks, images, network interfaces, disks)
    - networking (virtual networks with subnets and peerings, VPN and local network gateways, connections, route tables,
      public addresses), compute (virtual machines with sizes, disks and addresses), storage, Key Vaults, managed identities,
      Log Analytics workspaces, policy assignments, tags, and with -IncludeRBAC the role assignments

    The output is a JSON file and CSV files in -OutputPath. Nothing writes it into infrastructure.yml: enter the values you need
    there by hand, then check the file with Test-InfrastructureFile.ps1.

    Read only: the script changes nothing in Azure. It does not sign in: run Connect-AzAccount -Tenant <azure.tenant_id> first
    (Reader on the subscriptions is enough; Management Group Reader at the root to see the management groups). It checks that
    the signed-in tenant is the one in the file, and it puts the Az context back as it was when it ends.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id

    Exit codes: 0 the inventory is written and every read succeeded; 1 a precondition failed (Az module missing, not signed in,
    wrong tenant, no subscription can be listed) or at least one read failed (the files are still written and list the errors);
    2 azure.tenant_id is missing or not usable, or the file cannot be read (nothing is sent to Azure).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only azure.tenant_id is read; the whole file is not validated here.

.PARAMETER OutputPath
    Folder for the output files. Default: .\discovery under the current folder. Keep it out of the repository.

.PARAMETER BaseName
    File name, without extension, of the inventory files in -OutputPath. Default: azure-inventory.

.PARAMETER Format
    JSON, CSV or Both. Default: Both.

.PARAMETER IncludeRBAC
    Also record the role assignments of every subscription.

.PARAMETER IncludeAzureLocal
    Record the Azure Local resources. On unless -IncludeAzureLocal:$false is given.

.PARAMETER SubscriptionFilter
    Subscription IDs to limit the inventory to. Default: every subscription of the tenant the sign-in can read.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Inventory-AzureTenant.ps1 -InfrastructureFile ./infrastructure.yml

    Inventories every subscription of the tenant into .\discovery.

.EXAMPLE
    ./Inventory-AzureTenant.ps1 -InfrastructureFile ./infrastructure.yml -IncludeRBAC -Format JSON -OutputPath ./out/tenant

    Adds the role assignments and writes the JSON file only.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,

    [string]$OutputPath = ".\discovery",

    [string]$BaseName = "azure-inventory",

    [ValidateSet("JSON", "CSV", "Both")]
    [string]$Format = "Both",

    [switch]$IncludeRBAC,

    [switch]$IncludeAzureLocal,

    [string[]]$SubscriptionFilter,

    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'   # the Az modules print notices on every call; the errors are recorded in the inventory
$ProgressPreference = 'SilentlyContinue'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$TenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
if ($TenantId -notmatch $Guid -or $TenantId -eq [guid]::Empty.ToString()) {
    Exit-InputProblem 'azure.tenant_id is missing, not a GUID or the all-zero placeholder. Set it to the tenant to inventory (Get-AzContext shows it after Connect-AzAccount).'
}

# The output folder is relative to the current folder when it is not a full path.
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

# Azure Local resources are recorded unless -IncludeAzureLocal:$false is given.
if (-not $PSBoundParameters.ContainsKey('IncludeAzureLocal')) { $IncludeAzureLocal = [switch]$true }

$script:StartTime = Get-Date
$script:ProgressCounter = 0
$script:TotalSteps = 15

# Initialize inventory data structure
$script:Inventory = [ordered]@{
    Metadata         = [ordered]@{
        GeneratedAt   = $script:StartTime.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss UTC")
        GeneratedBy   = $null
        ScriptVersion = "3.0.0"
        TenantId      = $TenantId
        TenantName    = $null
        OutputPath    = $OutputPath
        Options       = [ordered]@{
            IncludeRBAC        = $IncludeRBAC.IsPresent
            IncludeAzureLocal  = [bool]$IncludeAzureLocal
            SubscriptionFilter = @($SubscriptionFilter | Where-Object { $_ })
        }
    }
    Tenant           = [ordered]@{
        TenantId      = $TenantId
        DisplayName   = $null
        DefaultDomain = $null
        TenantType    = $null
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

    Write-Line "$Activity - $Status"
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

    $inner = if ($Exception -is [System.Management.Automation.ErrorRecord]) { $Exception.Exception } elseif ($Exception -is [System.Exception]) { $Exception } else { $null }
    $exceptionMessage = if ($inner) { $inner.Message } elseif ($null -ne $Exception) { [string]$Exception } else { 'N/A' }
    $exceptionType = if ($inner) { $inner.GetType().Name } else { 'N/A' }
    $errorEntry = [ordered]@{
        Timestamp        = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Component        = $Component
        Message          = $Message
        ResourceId       = $ResourceId
        ExceptionMessage = $exceptionMessage
        ExceptionType    = $exceptionType
    }

    $script:Inventory.Errors += $errorEntry
    Write-Line "[error] [$Component] $Message$(if ($exceptionMessage -ne 'N/A') { ": $exceptionMessage" })"
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
        [System.Collections.IDictionary]$Data,

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
            Write-Line "Exported JSON: $jsonPath"
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
            Write-Line "Exported CSV files"
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

function Get-TenantDetail {
    # The display name, default domain and type of the tenant, for the record.
    try {
        $tenantInfo = Get-AzTenant -TenantId $TenantId -ErrorAction Stop
        $script:Inventory.Tenant.DisplayName = $tenantInfo.Name
        $script:Inventory.Tenant.DefaultDomain = $tenantInfo.DefaultDomain
        $script:Inventory.Tenant.TenantType = $tenantInfo.TenantType
        $script:Inventory.Metadata.TenantName = $tenantInfo.Name
        Write-Line "  Tenant name:   $($tenantInfo.Name)"
    }
    catch {
        Add-InventoryError -Component "TenantInfo" -Message "Failed to get tenant details" -Exception $_
    }
}

function Invoke-InventoryStep {
    # Runs one reader. Az objects differ by resource type and module version: a property can be absent or null. The readers record
    # what Azure returns, so inside them a missing property reads as null (strict mode version 1: variables must still be set)
    # instead of stopping the step. The rest of the script runs with Set-StrictMode -Version Latest.
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Arguments = @{})
    Set-StrictMode -Version 1
    & $Name @Arguments
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

        Write-Line "Found $($script:Inventory.ManagementGroups.Count) management groups"
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
            Write-Line "Filtering to $($subscriptions.Count) subscriptions"
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

        Write-Line "Found $($script:Inventory.Subscriptions.Count) subscriptions"
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

    Write-Line "Found $($script:Inventory.ResourceGroups.Count) resource groups"
}

#endregion

#region Resources

function Get-ResourceInventory {
    Write-ProgressStep -Activity "Resources" -Status "Scanning all Azure resources"

    foreach ($sub in $script:Inventory.Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
            Write-Line "  Scanning: $($sub.Name)..."

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

    Write-Line "Found $($script:Inventory.Resources.Count) resources"
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

    Write-Line "Found $totalAzureLocal Azure Local resources:"
    Write-Line "  - Clusters: $($script:Inventory.AzureLocal.Clusters.Count)"
    Write-Line "  - Custom Locations: $($script:Inventory.AzureLocal.CustomLocations.Count)"
    Write-Line "  - Logical Networks: $($script:Inventory.AzureLocal.LogicalNetworks.Count)"
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
    Write-Line "  Getting detailed VNet configurations..."
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
    Write-Line "  Scanning VPN Gateways..."
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
    Write-Line "  Scanning Public IP Details..."
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

    Write-Line "Found networking: VNets=$($vnets.Count), NSGs=$($nsgs.Count), VPNGWs=$($script:Inventory.Networking.VPNGateways.Count), VPNConns=$($script:Inventory.Networking.VPNConnections.Count)"
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
    Write-Line "  Scanning VM Details (sizes, disks, IPs)..."
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

    Write-Line "Found compute: VMs=$($vms.Count), Detailed=$($script:Inventory.Compute.VirtualMachineDetails.Count), Disks=$($disks.Count)"
}

function Get-StorageInventory {
    Write-ProgressStep -Activity "Storage Resources" -Status "Scanning storage"

    $storageAccounts = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Storage/storageAccounts' }
    $script:Inventory.Storage.StorageAccounts = @($storageAccounts)

    Write-Line "Found storage: $($storageAccounts.Count) accounts"
}

function Get-SecurityInventory {
    Write-ProgressStep -Activity "Security Resources" -Status "Scanning security"

    $keyVaults = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.KeyVault/vaults' }
    $managedIdentities = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.ManagedIdentity/userAssignedIdentities' }

    $script:Inventory.Security.KeyVaults = @($keyVaults)
    $script:Inventory.Security.ManagedIdentities = @($managedIdentities)

    Write-Line "Found security: KeyVaults=$($keyVaults.Count), ManagedIdentities=$($managedIdentities.Count)"
}

function Get-MonitoringInventory {
    Write-ProgressStep -Activity "Monitoring Resources" -Status "Scanning monitoring"

    $logAnalytics = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.OperationalInsights/workspaces' }
    $appInsights = $script:Inventory.Resources | Where-Object { $_.ResourceType -eq 'Microsoft.Insights/components' }

    $script:Inventory.Monitoring.LogAnalyticsWorkspaces = @($logAnalytics)
    $script:Inventory.Monitoring.ApplicationInsights = @($appInsights)

    Write-Line "Found monitoring: LogAnalytics=$($logAnalytics.Count), AppInsights=$($appInsights.Count)"
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

    Write-Line "Found $($script:Inventory.Security.RoleAssignments.Count) role assignments"
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

    Write-Line "Found $($script:Inventory.Policy.PolicyAssignments.Count) policy assignments"
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
    Write-Line "Found $($allTags.Count) unique tags"
}

#endregion

#region Main Execution

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzTenant', 'Get-AzSubscription', 'Get-AzManagementGroup', 'Get-AzResourceGroup', 'Get-AzResource', 'Get-AzResourceProvider') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az modules: Install-Module Az -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed "Not signed in to Azure. Run Connect-AzAccount -Tenant $TenantId first. This script does not sign in." }
if ([string]$context.Tenant.Id -ne $TenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $TenantId. Run Connect-AzAccount -Tenant $TenantId." }
$originalContext = $context
$script:Inventory.Metadata.GeneratedBy = [string]$context.Account.Id

$exitCode = 0
$exportedFiles = @()
try {
    Write-Line "Azure tenant inventory of $TenantId into $OutputPath (format $Format)"

    $permissions = Invoke-InventoryStep -Name 'Test-AzurePermissions' -Arguments @{ TenantId = $TenantId }
    if (-not $permissions.CanListSubscriptions) {
        $reasons = @($permissions.Errors) -join '; '
        Write-Error "The account $($context.Account.Id) cannot list the subscriptions of tenant $TenantId. It needs Reader on at least one subscription (or Management Group Reader at the root). $reasons" -ErrorAction Continue
        $exitCode = 1
    }
    else {
        Write-Line "  Subscriptions: $($permissions.SubscriptionCount) the account can read; management groups: $(if ($permissions.CanListManagementGroups) { 'yes' } else { 'no' })"
        foreach ($step in 'Get-TenantDetail', 'Get-ManagementGroupInventory', 'Get-SubscriptionInventory', 'Get-ResourceGroupInventory', 'Get-ResourceInventory',
            'Get-AzureLocalInventory', 'Get-NetworkingInventory', 'Get-ComputeInventory', 'Get-StorageInventory', 'Get-SecurityInventory',
            'Get-MonitoringInventory', 'Get-PolicyInventory', 'Get-RBACInventory', 'Get-TagInventory') {
            $null = Invoke-InventoryStep -Name $step
        }

        $script:Inventory.Metadata.CompletedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss UTC")
        $script:Inventory.Metadata.DurationSeconds = [int]((Get-Date) - $script:StartTime).TotalSeconds

        Write-ProgressStep -Activity "Export" -Status "Writing the inventory files"
        $exportedFiles = @(Invoke-InventoryStep -Name 'Export-InventoryReport' -Arguments @{ Data = $script:Inventory; OutputDirectory = $OutputPath; BaseName = $BaseName })

        Write-Line "Inventory complete: $($script:Inventory.Statistics.TotalSubscriptions) subscriptions, $($script:Inventory.Statistics.TotalResourceGroups) resource groups, $($script:Inventory.Statistics.TotalResources) resources, $($script:Inventory.AzureLocal.Clusters.Count) Azure Local clusters, $($script:Inventory.Errors.Count) errors."
        foreach ($file in $exportedFiles) { Write-Line "  $file" }
        Write-Line "Enter the values you need in infrastructure.yml by hand, then check it with Test-InfrastructureFile.ps1."
        if ($script:Inventory.Errors.Count -gt 0) {
            Write-Warning "The inventory has $($script:Inventory.Errors.Count) read errors; they are listed in the JSON file." -WarningAction Continue
            $exitCode = 1
        }
    }
}
catch {
    Write-Error "The inventory stopped: $($_.Exception.Message)" -ErrorAction Continue
    $exitCode = 1
}
finally {
    Write-Progress -Activity "Complete" -Completed
    # The readers switch subscriptions; the context the operator had is put back.
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $TenantId -ErrorAction Stop }
        catch { Write-Warning "Could not put the original subscription context back: $($_.Exception.Message)" -WarningAction Continue }
    }
}

[pscustomobject]@{
    TenantId       = $TenantId
    Subscriptions  = $script:Inventory.Statistics.TotalSubscriptions
    ResourceGroups = $script:Inventory.Statistics.TotalResourceGroups
    Resources      = $script:Inventory.Statistics.TotalResources
    Errors         = $script:Inventory.Errors.Count
    Files          = @($exportedFiles)
}
exit $exitCode

#endregion
