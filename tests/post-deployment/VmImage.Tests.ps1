#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 06: New-VmImage.ps1 downloads the Azure Marketplace images of storage.vm_images as Azure Local VM images. Every Az cmdlet
# is mocked: no Azure, no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/VmImage.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-06-image-downloads', 'powershell', 'New-VmImage.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function Get-AzStackHCIVMImage { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function New-AzStackHCIVMImage { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$CustomLocationId, [string]$OSType, [string]$Publisher, [string]$Offer, [string]$Sku, [string]$Version, [string]$StoragePathName, [hashtable]$Tag) }
    function Get-AzStackHCIVMStoragePath { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function Remove-AzStackHCIVMImage { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName) }

    $global:AzlImgTenant = [guid]::NewGuid().ToString()
    $global:AzlImgSub = [guid]::NewGuid().ToString()
    $global:AzlImgHome = [guid]::NewGuid().ToString()

    function New-Image([hashtable]$Override = @{}) {
        $i = [ordered]@{ name = 'img-ws2025-azure-edition'; os_type = 'Windows'; publisher = 'microsoftwindowsserver'; offer = 'windowsserver'; sku = '2025-datacenter-azure-edition' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $i.Remove($k) } else { $i[$k] = $Override[$k] } }
        $i
    }
    function New-InfraFile {
        param([object[]]$Images = @((New-Image)), [object[]]$Paths = @([ordered]@{ name = 'sp-workloads-01'; path = 'C:\ClusterStorage\vol-workloads-01\vms' }), [hashtable]$Azure = @{}, [object]$Tags = $null)
        $az = [ordered]@{ tenant_id = $global:AzlImgTenant; subscription_id = $global:AzlImgSub; resource_group = 'rg-azl-01'; location = 'eastus'; custom_location = 'cl-azl-01' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{ azure = $az; storage = [ordered]@{} }
        if ($Images) { $doc.storage.vm_images = @($Images) }
        if ($Paths) { $doc.storage.paths = @($Paths) }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Image([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Image'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function New-ImageObject([string]$State = 'Succeeded', [string]$Version = '26100.4652.250808') {
        [pscustomobject]@{
            Name = 'img'; ProvisioningStatus = $State; ProvisioningState = $State; VersionName = $Version; IdentifierPublisher = 'microsoftwindowsserver'; IdentifierOffer = 'windowsserver'
            IdentifierSku = '2025-datacenter-azure-edition'; OSType = 'Windows'; StatusErrorCode = ''; StatusErrorMessage = ''; StatusProgressPercentage = 100
        }
    }
}

Describe 'New-VmImage.ps1' {
    AfterAll { Remove-Variable -Name AzlImgTenant, AzlImgSub, AzlImgHome, AzlImgExisting, AzlImgCreated, AzlImgNames -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        $global:AzlImgExisting = $null
        $global:AzlImgNames = @()
        $global:AzlImgCreated = New-ImageObject
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlImgTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlImgHome } } }
        Mock Set-AzContext { }
        Mock Get-AzResourceProvider { [pscustomobject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = 'Registered' } }
        Mock Get-AzStackHCIVMImage {
            if ($null -ne $global:AzlImgExisting) { return $global:AzlImgExisting }
            if ($global:AzlImgNames -contains $Name) { return $global:AzlImgCreated }
            throw 'The Resource ''Microsoft.AzureStackHCI/marketplaceGalleryImages/x'' under resource group ''rg-azl-01'' was not found (404 NotFound).'
        }
        Mock New-AzStackHCIVMImage { $global:AzlImgNames += $Name; [pscustomobject]@{ Name = $Name } }
        Mock Get-AzStackHCIVMStoragePath { [pscustomobject]@{ Name = $Name } }
        Mock Remove-AzStackHCIVMImage { }
    }

    Context 'downloading images' {
        It 'creates the image from the Marketplace identifiers, in the resource group, region and custom location of the instance' {
            $r = Invoke-Image (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            Should -Invoke New-AzStackHCIVMImage -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'img-ws2025-azure-edition' -and $ResourceGroupName -eq 'rg-azl-01' -and $SubscriptionId -eq $global:AzlImgSub -and $Location -eq 'eastus' -and
                $OSType -eq 'Windows' -and $Publisher -eq 'microsoftwindowsserver' -and $Offer -eq 'windowsserver' -and $Sku -eq '2025-datacenter-azure-edition' -and
                $CustomLocationId -eq "/subscriptions/$($global:AzlImgSub)/resourceGroups/rg-azl-01/providers/Microsoft.ExtendedLocation/customLocations/cl-azl-01"
            }
        }

        It 'sends version latest when the file gives none, and reports the version Azure resolved' {
            $r = Invoke-Image (New-InfraFile)
            Should -Invoke New-AzStackHCIVMImage -Times 1 -Exactly -ParameterFilter { $Version -eq 'latest' -and -not $StoragePathName }
            $r.Rows[0].Version | Should -Be '26100.4652.250808'
        }

        It 'sends the pinned version, and the storage path when the entry names one' {
            $null = Invoke-Image (New-InfraFile -Images (New-Image @{ version = '26100.4652.250808'; storage_path = 'sp-workloads-01' }))
            Should -Invoke New-AzStackHCIVMImage -Times 1 -Exactly -ParameterFilter { $Version -eq '26100.4652.250808' -and $StoragePathName -eq 'sp-workloads-01' }
        }

        It 'normalises os_type, and puts the file-level tags on the image' {
            $null = Invoke-Image (New-InfraFile -Images (New-Image @{ os_type = 'linux' }) -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzStackHCIVMImage -Times 1 -Exactly -ParameterFilter { $OSType -eq 'Linux' -and $Tag -and $Tag['environment'] -eq 'lab' }
        }

        It 'creates the images one after the other, in the order of the file, and puts the original subscription back' {
            $images = (New-Image @{ name = 'img-a' }), (New-Image @{ name = 'img-b'; sku = '2022-datacenter-azure-edition-hotpatch' })
            $r = Invoke-Image (New-InfraFile -Images $images)
            @($r.Rows.Image) | Should -Be @('img-a', 'img-b')
            Should -Invoke New-AzStackHCIVMImage -Times 2 -Exactly
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlImgHome }
        }

        It 'never writes to the infrastructure file' {
            $file = New-InfraFile
            $before = (Get-FileHash -LiteralPath $file).Hash
            $null = Invoke-Image $file
            (Get-FileHash -LiteralPath $file).Hash | Should -Be $before
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'Set-Content|Out-File|Add-Content -LiteralPath \$Infra|ConvertTo-Yaml|\.Save\('
        }

        It 'has no parallelism: no job, no thread, no runspace' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'Start-Job|Start-ThreadJob|ForEach-Object -Parallel|-AsJob|-NoWait|Runspace|ThrottleLimit'
        }
    }

    Context 'the image already exists (idempotent)' {
        It 'creates nothing, deletes nothing, and says so' {
            $global:AzlImgExisting = New-ImageObject
            $r = Invoke-Image (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Version | Should -Be '26100.4652.250808'
            $r.Rows[0].Detail | Should -BeNullOrEmpty
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
            Should -Invoke Remove-AzStackHCIVMImage -Times 0 -Exactly
        }

        It 'reports a different SKU or a different pinned version, and changes nothing' {
            $global:AzlImgExisting = New-ImageObject -Version '26100.1.1'
            $r = Invoke-Image (New-InfraFile -Images (New-Image @{ sku = '2025-datacenter-azure-edition-core'; version = '26100.4652.250808' }))
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Detail | Should -Match 'sku is 2025-datacenter-azure-edition'
            $r.Rows[0].Detail | Should -Match 'version is 26100.1.1'
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
        }

        It 'does not call a version difference when the file says latest' {
            $global:AzlImgExisting = New-ImageObject -Version '26100.1.1'
            (Invoke-Image (New-InfraFile)).Rows[0].Detail | Should -BeNullOrEmpty
        }

        It 'reports an image that is still downloading as InProgress, exit 0, and leaves it' {
            $global:AzlImgExisting = New-ImageObject -State 'InProgress'
            $global:AzlImgExisting.StatusProgressPercentage = 40
            $r = Invoke-Image (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'InProgress'
            $r.Rows[0].Detail | Should -Match '40 percent'
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
        }

        It 'reports a failed image with the error from Azure, exits 1, and neither deletes nor recreates it' {
            $global:AzlImgExisting = New-ImageObject -State 'Failed'
            $global:AzlImgExisting.StatusErrorCode = 'DownloadFailed'
            $global:AzlImgExisting.StatusErrorMessage = 'The image could not be downloaded.'
            $r = Invoke-Image (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'DownloadFailed: The image could not be downloaded'
            $r.Rows[0].Detail | Should -Match 'left in place'
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
            Should -Invoke Remove-AzStackHCIVMImage -Times 0 -Exactly
        }

        It 'never removes an image' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'Remove-AzStackHCIVMImage|Update-AzStackHCIVMImage|&\s+az\s'
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans the image and downloads nothing' {
            $r = Invoke-Image (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the file lists no image' {
            $r = Invoke-Image (New-InfraFile -Images @())
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.<Key>' -ForEach @(@{ Key = 'tenant_id' }, @{ Key = 'subscription_id' }, @{ Key = 'resource_group' }, @{ Key = 'location' }, @{ Key = 'custom_location' }) {
            $r = Invoke-Image (New-InfraFile -Azure @{ $Key = $null })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match "azure.$Key"
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses the all-zero subscription id' {
            (Invoke-Image (New-InfraFile -Azure @{ subscription_id = [guid]::Empty.ToString() })).ExitCode | Should -Be 2
        }

        It 'refuses an image with <Why>' -ForEach @(
            @{ Why = 'no name'; Image = @{ name = $null } }
            @{ Why = 'a name with a space'; Image = @{ name = 'img one' } }
            @{ Why = 'a name that ends with a hyphen'; Image = @{ name = 'img-' } }
            @{ Why = 'a name of 81 characters'; Image = @{ name = ('a' * 81) } }
            @{ Why = 'no os_type'; Image = @{ os_type = $null } }
            @{ Why = 'os_type Solaris'; Image = @{ os_type = 'Solaris' } }
            @{ Why = 'no publisher'; Image = @{ publisher = $null } }
            @{ Why = 'no offer'; Image = @{ offer = $null } }
            @{ Why = 'no sku'; Image = @{ sku = $null } }
            @{ Why = 'a publisher with a colon'; Image = @{ publisher = 'a:b' } }
            @{ Why = 'a version that is not a version'; Image = @{ version = 'newest' } }
            @{ Why = 'a storage path that is not in storage.paths'; Image = @{ storage_path = 'sp-unknown' } }
        ) {
            $r = Invoke-Image (New-InfraFile -Images (New-Image $Image))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
        }

        It 'refuses the same image name twice' {
            (Invoke-Image (New-InfraFile -Images (New-Image), (New-Image @{ name = 'IMG-WS2025-AZURE-EDITION' }))).ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Image (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Image (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
        }

        It 'stops when the Microsoft.EdgeMarketplace resource provider is not registered, and puts the subscription back' {
            Mock Get-AzResourceProvider { [pscustomobject]@{ ProviderNamespace = 'Microsoft.EdgeMarketplace'; RegistrationState = 'NotRegistered' } }
            $r = Invoke-Image (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Microsoft.EdgeMarketplace is not registered'
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlImgHome }
        }

        It 'fails an image whose storage path does not exist in Azure yet' {
            Mock Get-AzStackHCIVMStoragePath { throw 'The Resource was not found (404 NotFound).' }
            $r = Invoke-Image (New-InfraFile -Images (New-Image @{ storage_path = 'sp-workloads-01' }))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'New-StoragePath'
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzStackHCIVMImage { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Image (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            Should -Invoke New-AzStackHCIVMImage -Times 0 -Exactly
        }

        It 'reports a failed download, goes on with the next image, puts the subscription back, and exits 1' {
            Mock New-AzStackHCIVMImage { throw 'DownloadFailed' }
            $r = Invoke-Image (New-InfraFile -Images (New-Image @{ name = 'img-a' }), (New-Image @{ name = 'img-b' }))
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed', 'Failed')
            Should -Invoke New-AzStackHCIVMImage -Times 2 -Exactly
            Should -Invoke Remove-AzStackHCIVMImage -Times 0 -Exactly
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlImgHome }
        }

        It 'reports an image that is created but ends in the Failed state as Failed' {
            $global:AzlImgCreated = New-ImageObject -State 'Failed'
            $global:AzlImgCreated.StatusErrorMessage = 'No space on the storage path.'
            $r = Invoke-Image (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'No space on the storage path'
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, carries no image catalogue and uses no Azure CLI' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml|marketplace_images|&\s+az\s|Get-Command -Name az\b|microsoftwindowsserver|windowsserver|2025-datacenter'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_VmImage_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'LogPath'
        }

        It 'reads only registry keys that exist: <_>' -ForEach @(
            'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'azure.location', 'azure.custom_location', 'storage.paths[].name'
            'storage.vm_images[].name', 'storage.vm_images[].os_type', 'storage.vm_images[].publisher', 'storage.vm_images[].offer', 'storage.vm_images[].sku'
            'storage.vm_images[].version', 'storage.vm_images[].storage_path'
        ) {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
