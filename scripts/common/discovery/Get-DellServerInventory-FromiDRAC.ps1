<#
.SYNOPSIS
    Collects comprehensive server inventory from Dell iDRAC via Redfish API.

.DESCRIPTION
    Gathers complete hardware inventory from Dell PowerEdge/AX servers via iDRAC
    Redfish API. Collects system info, chassis, power, thermal, PCI devices,
    sensors, CPU, memory, storage, network adapters, BIOS configuration, iDRAC
    configuration, and firmware inventory.

    Output is saved to a consolidated idrac-inventory.json file that gets updated
    with each run. Nodes are keyed by service tag and updated in place.
    
    Optionally, timestamped individual files can also be saved for historical tracking.

.PARAMETER iDRACIP
    IP address of the iDRAC interface to connect to

.PARAMETER Credential
    PSCredential object for iDRAC authentication. If not provided, prompts for credentials.

.PARAMETER OutputPath
    Directory for output files. Defaults to .\discovery

.PARAMETER KeepTimestampedFiles
    If specified, also saves individual timestamped files in addition to the consolidated file

.PARAMETER RunPostDiscovery
    If specified, runs the Update-InfrastructureFromDiscovery.ps1 script after collection

.EXAMPLE
    .\Get-DellServerInventory-FromiDRAC.ps1 -iDRACIP "192.168.200.11"

    Collects inventory from single iDRAC, updates idrac-inventory.json.

.EXAMPLE
    $cred = Get-Credential
    .\Get-DellServerInventory-FromiDRAC.ps1 -iDRACIP "192.168.200.11","192.168.200.12" -Credential $cred

    Collects inventory from multiple iDRACs with same credentials.

.EXAMPLE
    .\Get-DellServerInventory-FromiDRAC.ps1 -iDRACIP "192.168.200.11" -KeepTimestampedFiles

    Collects inventory and saves both consolidated and timestamped files.

.EXAMPLE
    .\Get-DellServerInventory-FromiDRAC.ps1 -iDRACIP "192.168.200.11" -RunPostDiscovery

    Collects inventory and then runs infrastructure.yml update.

.NOTES
    Author: Hybrid Cloud Solutions Team
    Date: 2025
    Version: 3.0.0
    
    INTEGRATION WITH DATA FRAMEWORK:
    - Outputs to discovery/idrac-inventory.json (consolidated, updated in place)
    - Optional timestamped files with -KeepTimestampedFiles
    - Compatible with Update-InfrastructureFromDiscovery.ps1
    - Feeds into infrastructure.yml single source of truth
    - See docs/infrastructure-data-framework.md for complete workflow
    
    REQUIREMENTS:
    - iDRAC 9 with Redfish API enabled
    - Network access to iDRAC management interface
    - iDRAC admin credentials
    - PowerShell 5.1 or later
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false, HelpMessage = "iDRAC IP address(es) to connect to")]
    [ValidateNotNullOrEmpty()]
    [string[]]$iDRACIP,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\discovery",

    [Parameter(Mandatory = $false)]
    [switch]$KeepTimestampedFiles,

    [Parameter(Mandatory = $false)]
    [switch]$RunPostDiscovery
)

begin {
    # Get repository root for proper path resolution
    $ScriptRoot = $PSScriptRoot
    $RepoRoot = (Get-Item $ScriptRoot).Parent.Parent.FullName

    # Resolve output path relative to repo root if relative
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path $RepoRoot $OutputPath
    }

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Host "Created output directory: $OutputPath" -ForegroundColor Cyan
    }

    # Consolidated inventory file path
    $script:ConsolidatedFile = Join-Path $OutputPath "idrac-inventory.json"

    # Load existing consolidated inventory or create new structure
    if (Test-Path $script:ConsolidatedFile) {
        try {
            $script:ConsolidatedInventory = Get-Content -Path $script:ConsolidatedFile -Raw | ConvertFrom-Json
            # Ensure Nodes property exists as hashtable-like structure
            if (-not $script:ConsolidatedInventory.Nodes) {
                $script:ConsolidatedInventory | Add-Member -NotePropertyName "Nodes" -NotePropertyValue @{} -Force
            }
            Write-Host "Loaded existing inventory with $($script:ConsolidatedInventory.Nodes.PSObject.Properties.Count) node(s)" -ForegroundColor Cyan
        }
        catch {
            Write-Host "Warning: Could not parse existing inventory, starting fresh" -ForegroundColor Yellow
            $script:ConsolidatedInventory = $null
        }
    }

    if (-not $script:ConsolidatedInventory) {
        $script:ConsolidatedInventory = [ordered]@{
            Metadata = [ordered]@{
                ScriptVersion = "3.0.0"
                Created       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                LastUpdated   = $null
            }
            Nodes    = [ordered]@{}
        }
    }

    # ==========================================================================
    # CREDENTIAL RESOLUTION: Key Vault → infrastructure.yml → Prompt
    # ==========================================================================
    if (-not $Credential) {
        Write-Host "Resolving iDRAC credentials..." -ForegroundColor Cyan
        
        $credentialSource = "none"
        $username = $null
        $password = $null
        
        # --------------------------------------------------------------------------
        # Step 1: Try Azure Key Vault
        # --------------------------------------------------------------------------
        Write-Host "  [1/3] Checking Azure Key Vault..." -ForegroundColor Gray
        try {
            # Load infrastructure.yml to get Key Vault name
            $infrastructurePath = Join-Path $RepoRoot "infrastructure.yml"
            $keyVaultName = $null
            
            Write-Verbose "    Looking for infrastructure.yml at: $infrastructurePath"
            
            if (Test-Path $infrastructurePath) {
                Write-Verbose "    Found infrastructure.yml"
                # Check if powershell-yaml is available
                if (Get-Module -ListAvailable -Name powershell-yaml) {
                    Import-Module powershell-yaml -ErrorAction Stop
                    $infraYaml = Get-Content -Path $infrastructurePath -Raw | ConvertFrom-Yaml
                    
                    Write-Verbose "    Loaded YAML, checking for key vault paths..."
                    Write-Verbose "    azure_infrastructure exists: $($null -ne $infraYaml.azure_infrastructure)"
                    Write-Verbose "    key_vaults exists: $($null -ne $infraYaml.azure_infrastructure.key_vaults)"
                    Write-Verbose "    platform exists: $($null -ne $infraYaml.azure_infrastructure.key_vaults.platform)"
                    Write-Verbose "    platform.name: $($infraYaml.azure_infrastructure.key_vaults.platform.name)"
                    
                    # Try multiple possible locations for key vault name
                    # 1. azure_infrastructure.key_vaults.platform.name (current structure)
                    # 2. azure_infrastructure.key_vault.name (legacy structure)
                    # 3. credentials.key_vault (credentials section)
                    if ($infraYaml.azure_infrastructure.key_vaults.platform.name) {
                        $keyVaultName = $infraYaml.azure_infrastructure.key_vaults.platform.name
                        Write-Verbose "    Found key vault name via path 1: $keyVaultName"
                    }
                    elseif ($infraYaml.azure_infrastructure.key_vault.name) {
                        $keyVaultName = $infraYaml.azure_infrastructure.key_vault.name
                        Write-Verbose "    Found key vault name via path 2: $keyVaultName"
                    }
                    elseif ($infraYaml.credentials.key_vault) {
                        $keyVaultName = $infraYaml.credentials.key_vault
                        Write-Verbose "    Found key vault name via path 3: $keyVaultName"
                    }
                    else {
                        Write-Verbose "    No key vault name found in any path"
                    }
                }
                else {
                    Write-Host "    ⚠ powershell-yaml module not installed" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "    ⚠ infrastructure.yml not found at: $infrastructurePath" -ForegroundColor Yellow
            }
            
            if ($keyVaultName) {
                Write-Host "    Using Key Vault: $keyVaultName" -ForegroundColor Gray
                
                # Check if Az.KeyVault module is available and we're logged in
                if (Get-Module -ListAvailable -Name Az.KeyVault) {
                    Import-Module Az.KeyVault -ErrorAction Stop
                    
                    # Try to get the secrets
                    $usernameSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "idrac-username" -ErrorAction Stop
                    $passwordSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "idrac-password" -ErrorAction Stop
                    
                    if ($usernameSecret -and $passwordSecret) {
                        $username = $usernameSecret.SecretValue | ConvertFrom-SecureString -AsPlainText
                        $password = $passwordSecret.SecretValue
                        $credentialSource = "keyvault"
                        Write-Host "    ✓ Found credentials in Key Vault: $keyVaultName" -ForegroundColor Green
                    }
                }
                else {
                    Write-Host "    ⚠ Az.KeyVault module not installed" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "    ⚠ Key Vault name not found in infrastructure.yml" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "    ⚠ Key Vault lookup failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        
        # --------------------------------------------------------------------------
        # Step 2: Try infrastructure.yml credentials section
        # --------------------------------------------------------------------------
        if ($credentialSource -eq "none") {
            Write-Host "  [2/3] Checking infrastructure.yml..." -ForegroundColor Gray
            try {
                $infrastructurePath = Join-Path $RepoRoot "infrastructure.yml"
                if (Test-Path $infrastructurePath) {
                    if (-not (Get-Module -Name powershell-yaml)) {
                        if (Get-Module -ListAvailable -Name powershell-yaml) {
                            Import-Module powershell-yaml -ErrorAction Stop
                        }
                    }
                    
                    if (Get-Module -Name powershell-yaml) {
                        $infraYaml = Get-Content -Path $infrastructurePath -Raw | ConvertFrom-Yaml
                        
                        # Look for idrac credentials in infrastructure.yml
                        if ($infraYaml.credentials.idrac) {
                            $username = $infraYaml.credentials.idrac.username
                            $plaintextPassword = $infraYaml.credentials.idrac.password
                            if ($username -and $plaintextPassword) {
                                $password = ConvertTo-SecureString $plaintextPassword -AsPlainText -Force
                                $credentialSource = "infrastructure.yml"
                                Write-Host "    ✓ Found credentials in infrastructure.yml" -ForegroundColor Green
                            }
                        }
                    }
                }
            }
            catch {
                Write-Host "    ⚠ infrastructure.yml lookup failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        # --------------------------------------------------------------------------
        # Step 3: Prompt user for credentials
        # --------------------------------------------------------------------------
        if ($credentialSource -eq "none") {
            Write-Host "  [3/3] Prompting for credentials..." -ForegroundColor Gray
            Write-Host "    ⚠ Credentials not found in Key Vault or infrastructure.yml" -ForegroundColor Yellow
            $Credential = Get-Credential -Message "iDRAC Administrator Credentials"
            $credentialSource = "prompt"
            Write-Host "    ✓ Using prompted credentials" -ForegroundColor Green
        }
        else {
            # Build credential object from Key Vault or infrastructure.yml
            $Credential = New-Object System.Management.Automation.PSCredential($username, $password)
        }
        
        Write-Host "  Credential source: $credentialSource" -ForegroundColor Cyan
    }
    else {
        Write-Host "Using provided credentials" -ForegroundColor Cyan
    }

    # Create basic auth header
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(
            ("{0}:{1}" -f $Credential.UserName, $Credential.GetNetworkCredential().Password)
        ))
    $script:headers = @{
        "Authorization" = "Basic $base64Auth"
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
    }

    # Track collected service tags for summary
    $script:CollectedNodes = @()
    $script:UpdatedNodes = @()
    $script:NewNodes = @()
    $script:TimestampedFiles = @()

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " Dell iDRAC Server Inventory Collection" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " Targets: $($iDRACIP -join ', ')" -ForegroundColor White
    Write-Host " Output: $OutputPath" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

process {
    foreach ($ip in $iDRACIP) {
        Write-Host "Connecting to iDRAC: $ip" -ForegroundColor Yellow

        # Ignore SSL certificate errors for self-signed iDRAC certs
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
        }
        else {
            # PowerShell 5.1 workaround
            if (-not ("TrustAllCertsPolicy" -as [type])) {
                Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint svc, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
            }
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        }

        # Initialize inventory structure
        $inventory = [ordered]@{
            CollectedAt        = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            iDRACIP            = $ip
            ScriptVersion      = "2.0.0"
            System             = @{}
            Chassis            = @{}
            Power              = @{}
            Thermal            = @{}
            PCIDevices         = @()
            Sensors            = @()
            CPUs               = @()
            Memory             = @()
            Storage            = @{}
            NetworkAdapters    = @()
            BIOSConfiguration  = @{}
            iDRACConfiguration = @{}
            Firmware           = @()
            Errors             = @()
        }

        $baseUrl = "https://$ip"

        try {
            # ============================================================
            # SYSTEM INFORMATION
            # ============================================================
            Write-Host "  Collecting system information..." -ForegroundColor Cyan
            try {
                $system = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Systems/System.Embedded.1" -Headers $script:headers -Method GET -ErrorAction Stop

                $inventory.System = [ordered]@{
                    ServiceTag       = $system.SKU
                    Model            = $system.Model
                    Manufacturer     = $system.Manufacturer
                    SerialNumber     = $system.SerialNumber
                    HostName         = $system.HostName
                    PowerState       = $system.PowerState
                    IndicatorLED     = $system.IndicatorLED
                    BiosVersion      = $system.BiosVersion
                    MemorySummary    = @{
                        TotalGB = [math]::Round($system.MemorySummary.TotalSystemMemoryGiB, 0)
                        Status  = $system.MemorySummary.Status.Health
                    }
                    ProcessorSummary = @{
                        Count  = $system.ProcessorSummary.Count
                        Model  = $system.ProcessorSummary.Model
                        Status = $system.ProcessorSummary.Status.Health
                    }
                }
                Write-Host "    ✓ System: $($system.Model) - $($system.SKU)" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "System"; Error = $_.Exception.Message }
                Write-Host "    ✗ System information failed: $($_.Exception.Message)" -ForegroundColor Red
            }

            # ============================================================
            # CHASSIS INFORMATION
            # ============================================================
            Write-Host "  Collecting chassis information..." -ForegroundColor Cyan
            try {
                $chassis = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Chassis/System.Embedded.1" -Headers $script:headers -Method GET -ErrorAction Stop

                $inventory.Chassis = [ordered]@{
                    ChassisType  = $chassis.ChassisType
                    Manufacturer = $chassis.Manufacturer
                    Model        = $chassis.Model
                    SKU          = $chassis.SKU
                    SerialNumber = $chassis.SerialNumber
                    PartNumber   = $chassis.PartNumber
                    AssetTag     = $chassis.AssetTag
                    Status       = @{
                        Health       = $chassis.Status.Health
                        HealthRollup = $chassis.Status.HealthRollup
                        State        = $chassis.Status.State
                    }
                }
                Write-Host "    ✓ Chassis: $($chassis.ChassisType)" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "Chassis"; Error = $_.Exception.Message }
                Write-Host "    ✗ Chassis information failed" -ForegroundColor Red
            }

            # ============================================================
            # POWER INFORMATION
            # ============================================================
            Write-Host "  Collecting power information..." -ForegroundColor Cyan
            try {
                $power = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Chassis/System.Embedded.1/Power" -Headers $script:headers -Method GET -ErrorAction Stop

                $inventory.Power = [ordered]@{
                    PowerControl  = @($power.PowerControl | ForEach-Object {
                            [ordered]@{
                                Name               = $_.Name
                                PowerConsumedWatts = $_.PowerConsumedWatts
                                PowerCapacityWatts = $_.PowerCapacityWatts
                                PowerMetrics       = @{
                                    MinConsumedWatts     = $_.PowerMetrics.MinConsumedWatts
                                    MaxConsumedWatts     = $_.PowerMetrics.MaxConsumedWatts
                                    AverageConsumedWatts = $_.PowerMetrics.AverageConsumedWatts
                                }
                            }
                        })
                    PowerSupplies = @($power.PowerSupplies | ForEach-Object {
                            [ordered]@{
                                Name                 = $_.Name
                                Model                = $_.Model
                                Manufacturer         = $_.Manufacturer
                                SerialNumber         = $_.SerialNumber
                                PartNumber           = $_.PartNumber
                                SparePartNumber      = $_.SparePartNumber
                                PowerCapacityWatts   = $_.PowerCapacityWatts
                                PowerInputWatts      = $_.PowerInputWatts
                                PowerOutputWatts     = $_.PowerOutputWatts
                                EfficiencyPercent    = $_.EfficiencyPercent
                                LineInputVoltage     = $_.LineInputVoltage
                                LineInputVoltageType = $_.LineInputVoltageType
                                Status               = @{
                                    Health = $_.Status.Health
                                    State  = $_.Status.State
                                }
                            }
                        })
                }
                Write-Host "    ✓ Power: $($power.PowerSupplies.Count) PSUs" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "Power"; Error = $_.Exception.Message }
                Write-Host "    ✗ Power information failed" -ForegroundColor Red
            }

            # ============================================================
            # THERMAL INFORMATION
            # ============================================================
            Write-Host "  Collecting thermal information..." -ForegroundColor Cyan
            try {
                $thermal = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Chassis/System.Embedded.1/Thermal" -Headers $script:headers -Method GET -ErrorAction Stop

                $inventory.Thermal = [ordered]@{
                    Temperatures = @($thermal.Temperatures | ForEach-Object {
                            [ordered]@{
                                Name                      = $_.Name
                                SensorNumber              = $_.SensorNumber
                                ReadingCelsius            = $_.ReadingCelsius
                                UpperThresholdNonCritical = $_.UpperThresholdNonCritical
                                UpperThresholdCritical    = $_.UpperThresholdCritical
                                UpperThresholdFatal       = $_.UpperThresholdFatal
                                Status                    = @{
                                    Health = $_.Status.Health
                                    State  = $_.Status.State
                                }
                            }
                        })
                    Fans         = @($thermal.Fans | ForEach-Object {
                            [ordered]@{
                                Name         = $_.Name
                                Reading      = $_.Reading
                                ReadingUnits = $_.ReadingUnits
                                Status       = @{
                                    Health = $_.Status.Health
                                    State  = $_.Status.State
                                }
                            }
                        })
                }
                Write-Host "    ✓ Thermal: $($thermal.Temperatures.Count) sensors, $($thermal.Fans.Count) fans" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "Thermal"; Error = $_.Exception.Message }
                Write-Host "    ✗ Thermal information failed" -ForegroundColor Red
            }

            # ============================================================
            # PCI DEVICES
            # ============================================================
            Write-Host "  Collecting PCI device information..." -ForegroundColor Cyan
            try {
                $pciCollection = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Systems/System.Embedded.1/PCIeDevices" -Headers $script:headers -Method GET -ErrorAction Stop

                foreach ($pciLink in $pciCollection.Members.'@odata.id') {
                    try {
                        $pci = Invoke-RestMethod -Uri "$baseUrl$pciLink" -Headers $script:headers -Method GET -ErrorAction Stop
                        $inventory.PCIDevices += [ordered]@{
                            Name         = $pci.Name
                            Manufacturer = $pci.Manufacturer
                            Model        = $pci.Model
                            DeviceType   = $pci.DeviceType
                            Description  = $pci.Description
                        }
                    }
                    catch {
                        # Silent skip for individual device failures
                    }
                }
                Write-Host "    ✓ PCI Devices: $($inventory.PCIDevices.Count) devices" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "PCIDevices"; Error = $_.Exception.Message }
                Write-Host "    ✗ PCI device information failed" -ForegroundColor Red
            }

            # ============================================================
            # CPU INFORMATION
            # ============================================================
            Write-Host "  Collecting CPU information..." -ForegroundColor Cyan
            try {
                $cpuCollection = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Systems/System.Embedded.1/Processors" -Headers $script:headers -Method GET -ErrorAction Stop

                foreach ($cpuLink in $cpuCollection.Members.'@odata.id') {
                    try {
                        $cpu = Invoke-RestMethod -Uri "$baseUrl$cpuLink" -Headers $script:headers -Method GET -ErrorAction Stop
                        $inventory.CPUs += [ordered]@{
                            Socket        = $cpu.Id
                            Manufacturer  = $cpu.Manufacturer
                            Model         = $cpu.Model
                            ProcessorType = $cpu.ProcessorType
                            TotalCores    = $cpu.TotalCores
                            TotalThreads  = $cpu.TotalThreads
                            MaxSpeedMHz   = $cpu.MaxSpeedMHz
                            Status        = @{
                                Health = $cpu.Status.Health
                                State  = $cpu.Status.State
                            }
                        }
                    }
                    catch {
                        # Silent skip for individual CPU failures
                    }
                }
                Write-Host "    ✓ CPUs: $($inventory.CPUs.Count) processors" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "CPUs"; Error = $_.Exception.Message }
                Write-Host "    ✗ CPU information failed" -ForegroundColor Red
            }

            # ============================================================
            # MEMORY INFORMATION
            # ============================================================
            Write-Host "  Collecting memory information..." -ForegroundColor Cyan
            try {
                $memCollection = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Systems/System.Embedded.1/Memory" -Headers $script:headers -Method GET -ErrorAction Stop

                foreach ($memLink in $memCollection.Members.'@odata.id') {
                    try {
                        $mem = Invoke-RestMethod -Uri "$baseUrl$memLink" -Headers $script:headers -Method GET -ErrorAction Stop
                        if ($mem.Status.State -eq "Enabled") {
                            $inventory.Memory += [ordered]@{
                                Slot          = $mem.Id
                                Manufacturer  = $mem.Manufacturer
                                PartNumber    = $mem.PartNumber
                                SerialNumber  = $mem.SerialNumber
                                CapacityGB    = [math]::Round($mem.CapacityMiB / 1024, 0)
                                SpeedMHz      = $mem.OperatingSpeedMhz
                                MemoryType    = $mem.MemoryDeviceType
                                DataWidthBits = $mem.DataWidthBits
                                RankCount     = $mem.RankCount
                                Status        = @{
                                    Health = $mem.Status.Health
                                    State  = $mem.Status.State
                                }
                            }
                        }
                    }
                    catch {
                        # Silent skip for individual DIMM failures
                    }
                }
                $totalMemoryGB = ($inventory.Memory | Measure-Object -Property CapacityGB -Sum).Sum
                Write-Host "    ✓ Memory: $($inventory.Memory.Count) DIMMs, $totalMemoryGB GB total" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "Memory"; Error = $_.Exception.Message }
                Write-Host "    ✗ Memory information failed" -ForegroundColor Red
            }

            # ============================================================
            # STORAGE INFORMATION
            # ============================================================
            Write-Host "  Collecting storage information..." -ForegroundColor Cyan
            try {
                $storageCollection = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Systems/System.Embedded.1/Storage" -Headers $script:headers -Method GET -ErrorAction Stop

                $inventory.Storage = [ordered]@{
                    Controllers = @()
                    Drives      = @()
                    Volumes     = @()
                }

                foreach ($storLink in $storageCollection.Members.'@odata.id') {
                    try {
                        $stor = Invoke-RestMethod -Uri "$baseUrl$storLink" -Headers $script:headers -Method GET -ErrorAction Stop

                        # Controller info
                        $inventory.Storage.Controllers += [ordered]@{
                            Id                 = $stor.Id
                            Name               = $stor.Name
                            StorageControllers = @($stor.StorageControllers | ForEach-Object {
                                    [ordered]@{
                                        MemberId                 = $_.MemberId
                                        Manufacturer             = $_.Manufacturer
                                        Model                    = $_.Model
                                        FirmwareVersion          = $_.FirmwareVersion
                                        SupportedDeviceProtocols = $_.SupportedDeviceProtocols
                                        Status                   = @{
                                            Health = $_.Status.Health
                                            State  = $_.Status.State
                                        }
                                    }
                                })
                        }

                        # Drives
                        foreach ($driveLink in $stor.Drives.'@odata.id') {
                            try {
                                $drive = Invoke-RestMethod -Uri "$baseUrl$driveLink" -Headers $script:headers -Method GET -ErrorAction Stop
                                $inventory.Storage.Drives += [ordered]@{
                                    Id               = $drive.Id
                                    Name             = $drive.Name
                                    Manufacturer     = $drive.Manufacturer
                                    Model            = $drive.Model
                                    MediaType        = $drive.MediaType
                                    Protocol         = $drive.Protocol
                                    CapacityBytes    = $drive.CapacityBytes
                                    CapacityGB       = [math]::Round($drive.CapacityBytes / 1GB, 0)
                                    SerialNumber     = $drive.SerialNumber
                                    PartNumber       = $drive.PartNumber
                                    Revision         = $drive.Revision
                                    RotationSpeedRPM = $drive.RotationSpeedRPM
                                    Status           = @{
                                        Health = $drive.Status.Health
                                        State  = $drive.Status.State
                                    }
                                }
                            }
                            catch {
                                # Silent skip for individual drive failures
                            }
                        }
                    }
                    catch {
                        # Silent skip for individual controller failures
                    }
                }
                Write-Host "    ✓ Storage: $($inventory.Storage.Controllers.Count) controllers, $($inventory.Storage.Drives.Count) drives" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "Storage"; Error = $_.Exception.Message }
                Write-Host "    ✗ Storage information failed" -ForegroundColor Red
            }

            # ============================================================
            # NETWORK ADAPTERS
            # ============================================================
            Write-Host "  Collecting network adapter information..." -ForegroundColor Cyan
            try {
                $netCollection = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Systems/System.Embedded.1/NetworkAdapters" -Headers $script:headers -Method GET -ErrorAction Stop

                foreach ($netLink in $netCollection.Members.'@odata.id') {
                    try {
                        $net = Invoke-RestMethod -Uri "$baseUrl$netLink" -Headers $script:headers -Method GET -ErrorAction Stop

                        $adapter = [ordered]@{
                            Id           = $net.Id
                            Name         = $net.Name
                            Manufacturer = $net.Manufacturer
                            Model        = $net.Model
                            PartNumber   = $net.PartNumber
                            SerialNumber = $net.SerialNumber
                            Status       = @{
                                Health = $net.Status.Health
                                State  = $net.Status.State
                            }
                            Ports        = @()
                        }

                        # Get port information
                        if ($net.NetworkPorts) {
                            try {
                                $portsUri = $net.NetworkPorts.'@odata.id'
                                $ports = Invoke-RestMethod -Uri "$baseUrl$portsUri" -Headers $script:headers -Method GET -ErrorAction Stop
                                foreach ($portLink in $ports.Members.'@odata.id') {
                                    try {
                                        $port = Invoke-RestMethod -Uri "$baseUrl$portLink" -Headers $script:headers -Method GET -ErrorAction Stop
                                        $adapter.Ports += [ordered]@{
                                            Id                         = $port.Id
                                            PhysicalPortNumber         = $port.PhysicalPortNumber
                                            LinkStatus                 = $port.LinkStatus
                                            CurrentLinkSpeedMbps       = $port.CurrentLinkSpeedMbps
                                            AssociatedNetworkAddresses = $port.AssociatedNetworkAddresses
                                        }
                                    }
                                    catch {
                                        # Silent skip for individual port failures
                                    }
                                }
                            }
                            catch {
                                # Silent skip for ports collection failure
                            }
                        }

                        $inventory.NetworkAdapters += $adapter
                    }
                    catch {
                        # Silent skip for individual adapter failures
                    }
                }
                Write-Host "    ✓ Network: $($inventory.NetworkAdapters.Count) adapters" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "NetworkAdapters"; Error = $_.Exception.Message }
                Write-Host "    ✗ Network adapter information failed" -ForegroundColor Red
            }

            # ============================================================
            # BIOS CONFIGURATION
            # ============================================================
            Write-Host "  Collecting BIOS configuration..." -ForegroundColor Cyan
            try {
                $bios = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Systems/System.Embedded.1/Bios" -Headers $script:headers -Method GET -ErrorAction Stop

                $inventory.BIOSConfiguration = [ordered]@{
                    BiosVersion = $bios.Attributes.SystemBiosVersion
                    Attributes  = $bios.Attributes
                }
                Write-Host "    ✓ BIOS: Version $($bios.Attributes.SystemBiosVersion)" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "BIOSConfiguration"; Error = $_.Exception.Message }
                Write-Host "    ✗ BIOS configuration failed" -ForegroundColor Red
            }

            # ============================================================
            # iDRAC CONFIGURATION
            # ============================================================
            Write-Host "  Collecting iDRAC configuration..." -ForegroundColor Cyan
            try {
                $idrac = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/Managers/iDRAC.Embedded.1/Attributes" -Headers $script:headers -Method GET -ErrorAction Stop

                $inventory.iDRACConfiguration = [ordered]@{
                    Attributes = $idrac.Attributes
                }
                Write-Host "    ✓ iDRAC: Configuration collected" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "iDRACConfiguration"; Error = $_.Exception.Message }
                Write-Host "    ✗ iDRAC configuration failed" -ForegroundColor Red
            }

            # ============================================================
            # FIRMWARE INVENTORY
            # ============================================================
            Write-Host "  Collecting firmware inventory..." -ForegroundColor Cyan
            try {
                $fwCollection = Invoke-RestMethod -Uri "$baseUrl/redfish/v1/UpdateService/FirmwareInventory" -Headers $script:headers -Method GET -ErrorAction Stop

                foreach ($fwLink in $fwCollection.Members.'@odata.id') {
                    try {
                        $fw = Invoke-RestMethod -Uri "$baseUrl$fwLink" -Headers $script:headers -Method GET -ErrorAction Stop
                        $inventory.Firmware += [ordered]@{
                            Id         = $fw.Id
                            Name       = $fw.Name
                            Version    = $fw.Version
                            Updateable = $fw.Updateable
                            Status     = @{
                                Health = $fw.Status.Health
                                State  = $fw.Status.State
                            }
                        }
                    }
                    catch {
                        # Silent skip for individual firmware entries
                    }
                }
                Write-Host "    ✓ Firmware: $($inventory.Firmware.Count) components" -ForegroundColor Green
            }
            catch {
                $inventory.Errors += @{ Component = "Firmware"; Error = $_.Exception.Message }
                Write-Host "    ✗ Firmware inventory failed" -ForegroundColor Red
            }

            # ============================================================
            # SAVE TO CONSOLIDATED INVENTORY
            # ============================================================
            $serviceTag = $inventory.System.ServiceTag
            if (-not $serviceTag) { $serviceTag = "UNKNOWN" }

            # Check if this is a new or updated node
            $isNewNode = -not ($script:ConsolidatedInventory.Nodes.PSObject.Properties.Name -contains $serviceTag)
            
            # Extract network port MACs
            $networkPorts = [ordered]@{}
            if ($inventory.Network.PhysicalAdapters) {
                $adapter = $inventory.Network.PhysicalAdapters | Select-Object -First 1
                if ($adapter.NetworkPorts) {
                    $ports = $adapter.NetworkPorts | Sort-Object { [int]$_.PhysicalPortNumber }
                    for ($i = 0; $i -lt [Math]::Min(4, $ports.Count); $i++) {
                        $mac = $ports[$i].AssociatedNetworkAddresses | Select-Object -First 1
                        $networkPorts["Port$($i+1)"] = $mac
                    }
                }
            }

            # Create consolidated node entry (simplified structure for Update-InfrastructureFromDiscovery.ps1)
            $nodeEntry = [ordered]@{
                ServiceTag     = $serviceTag
                SerialNumber   = $inventory.System.SerialNumber
                Model          = $inventory.System.Model
                Manufacturer   = $inventory.System.Manufacturer
                HostName       = $inventory.System.HostName
                PowerState     = $inventory.System.PowerState
                BiosVersion    = $inventory.System.BiosVersion
                iDRACIP        = $ip
                iDRACMAC       = $inventory.Network.iDRAC.MACAddress
                CPU            = [ordered]@{
                    Model   = $inventory.System.ProcessorSummary.Model
                    Count   = $inventory.System.ProcessorSummary.Count
                    Cores   = if ($inventory.CPUs.Count -gt 0) { ($inventory.CPUs | Measure-Object -Property TotalCores -Sum).Sum } else { $null }
                    Threads = if ($inventory.CPUs.Count -gt 0) { ($inventory.CPUs | Measure-Object -Property TotalThreads -Sum).Sum } else { $null }
                }
                MemoryGB       = $inventory.System.MemorySummary.TotalGB
                NetworkPorts   = $networkPorts
                LastDiscovered = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                FullInventory  = $inventory  # Keep full details for reference
            }

            # Update consolidated inventory
            if ($script:ConsolidatedInventory.Nodes -is [PSCustomObject]) {
                # PSCustomObject from loaded JSON - need to add/update property
                if ($isNewNode) {
                    $script:ConsolidatedInventory.Nodes | Add-Member -NotePropertyName $serviceTag -NotePropertyValue $nodeEntry -Force
                }
                else {
                    $script:ConsolidatedInventory.Nodes.$serviceTag = $nodeEntry
                }
            }
            else {
                # Hashtable (newly created)
                $script:ConsolidatedInventory.Nodes[$serviceTag] = $nodeEntry
            }

            $script:CollectedNodes += $serviceTag
            if ($isNewNode) {
                $script:NewNodes += $serviceTag
            }
            else {
                $script:UpdatedNodes += $serviceTag
            }

            Write-Host ""
            if ($isNewNode) {
                Write-Host "  ✓ Added new node: $serviceTag" -ForegroundColor Green
            }
            else {
                Write-Host "  ✓ Updated node: $serviceTag" -ForegroundColor Green
            }

            # Optionally save timestamped individual file
            if ($KeepTimestampedFiles) {
                $timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
                $timestampedFile = Join-Path $OutputPath "idrac-inventory-$serviceTag-$timestamp.json"
                $inventory | ConvertTo-Json -Depth 20 | Out-File -FilePath $timestampedFile -Encoding UTF8 -Force
                $script:TimestampedFiles += $timestampedFile
                Write-Host "  ✓ Timestamped file: $($timestampedFile | Split-Path -Leaf)" -ForegroundColor Gray
            }
            Write-Host ""

        }
        catch {
            Write-Host "  ✗ Failed to connect to iDRAC $ip : $($_.Exception.Message)" -ForegroundColor Red
            $inventory.Errors += @{ Component = "Connection"; Error = $_.Exception.Message }
        }
    }
}

end {
    # Update metadata
    $script:ConsolidatedInventory.Metadata.LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $script:ConsolidatedInventory.Metadata.NodeCount = $script:ConsolidatedInventory.Nodes.PSObject.Properties.Count

    # Save consolidated inventory
    $script:ConsolidatedInventory | ConvertTo-Json -Depth 25 | Out-File -FilePath $script:ConsolidatedFile -Encoding UTF8 -Force

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " Collection Complete" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " Consolidated inventory: $($script:ConsolidatedFile | Split-Path -Leaf)" -ForegroundColor White
    Write-Host " Total nodes in inventory: $($script:ConsolidatedInventory.Nodes.PSObject.Properties.Count)" -ForegroundColor White
    Write-Host ""
    
    if ($script:NewNodes.Count -gt 0) {
        Write-Host " New nodes added:" -ForegroundColor Green
        foreach ($tag in $script:NewNodes) {
            Write-Host "   + $tag" -ForegroundColor Green
        }
    }
    
    if ($script:UpdatedNodes.Count -gt 0) {
        Write-Host " Nodes updated:" -ForegroundColor Yellow
        foreach ($tag in $script:UpdatedNodes) {
            Write-Host "   ~ $tag" -ForegroundColor Yellow
        }
    }

    if ($KeepTimestampedFiles -and $script:TimestampedFiles.Count -gt 0) {
        Write-Host ""
        Write-Host " Timestamped files:" -ForegroundColor Gray
        foreach ($file in $script:TimestampedFiles) {
            Write-Host "   - $($file | Split-Path -Leaf)" -ForegroundColor Gray
        }
    }

    # Run post-discovery automation if requested
    if ($RunPostDiscovery -and $script:CollectedNodes.Count -gt 0) {
        Write-Host ""
        Write-Host "Running post-discovery automation..." -ForegroundColor Yellow

        $updateScript = Join-Path $ScriptRoot "Update-InfrastructureFromDiscovery.ps1"
        if (Test-Path $updateScript) {
            Write-Host "Executing: Update-InfrastructureFromDiscovery.ps1 -iDRAC" -ForegroundColor Cyan
            & $updateScript -DiscoveryPath $OutputPath -iDRAC
        }
        else {
            Write-Host "  ⚠ Update script not found: $updateScript" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "  1. Review: $($script:ConsolidatedFile | Split-Path -Leaf)" -ForegroundColor White
    Write-Host "  2. Run: .\Update-InfrastructureFromDiscovery.ps1 -iDRAC" -ForegroundColor White
    Write-Host "  3. Validate infrastructure.yml updates" -ForegroundColor White
    Write-Host ""
}
