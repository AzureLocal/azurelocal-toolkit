#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 05: New-StoragePath.ps1 creates the Azure Local storage paths of storage.paths. Every Az cmdlet is mocked: no Azure, no
# tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/storage/StoragePath.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-StoragePath.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzStackHCIVMStoragePath { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function New-AzStackHCIVMStoragePath { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$CustomLocationId, [string]$Path, [hashtable]$Tag) }

    $global:AzlSpTestTenant = [guid]::NewGuid().ToString()
    $global:AzlSpTestSub = [guid]::NewGuid().ToString()
    $global:AzlSpTestHome = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object[]]$Paths = @([ordered]@{ name = 'sp-workloads-01'; path = 'C:\ClusterStorage\vol-workloads-01\vms' }), [hashtable]$Azure = @{}, [object]$Tags = $null)
        $az = [ordered]@{ tenant_id = $global:AzlSpTestTenant; subscription_id = $global:AzlSpTestSub; resource_group = 'rg-azl-01'; location = 'eastus'; custom_location = 'cl-azl-01' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{ azure = $az; storage = [ordered]@{} }
        if ($Paths) { $doc.storage.paths = @($Paths) }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Path([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['StoragePath'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'New-StoragePath.ps1' {
    AfterAll { Remove-Variable -Name AzlSpTestTenant, AzlSpTestSub, AzlSpTestHome -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlSpTestTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlSpTestHome } } }
        Mock Set-AzContext { }
        Mock Get-AzStackHCIVMStoragePath { throw 'The Resource ''Microsoft.AzureStackHCI/storageContainers/x'' was not found (404 NotFound).' }
        Mock New-AzStackHCIVMStoragePath { [pscustomobject]@{ Name = $Name } }
    }

    Context 'creating storage paths' {
        It 'creates the storage path in the resource group, region and custom location of the instance' {
            $r = Invoke-Path (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            Should -Invoke New-AzStackHCIVMStoragePath -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'sp-workloads-01' -and $ResourceGroupName -eq 'rg-azl-01' -and $SubscriptionId -eq $global:AzlSpTestSub -and $Location -eq 'eastus' -and
                $Path -eq 'C:\ClusterStorage\vol-workloads-01\vms' -and
                $CustomLocationId -eq "/subscriptions/$($global:AzlSpTestSub)/resourceGroups/rg-azl-01/providers/Microsoft.ExtendedLocation/customLocations/cl-azl-01"
            }
        }

        It 'creates every storage path of the list and puts the original subscription back' {
            $r = Invoke-Path (New-InfraFile -Paths ([ordered]@{ name = 'sp-a'; path = 'C:\ClusterStorage\vol-a' }), ([ordered]@{ name = 'sp-b'; path = 'C:\ClusterStorage\Volume1\images\' }))
            $r.Rows.Count | Should -Be 2
            Should -Invoke New-AzStackHCIVMStoragePath -Times 1 -Exactly -ParameterFilter { $Name -eq 'sp-b' -and $Path -eq 'C:\ClusterStorage\Volume1\images' }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlSpTestHome }
        }

        It 'puts the file-level tags on the storage path, and sends none when the file has none' {
            $null = Invoke-Path (New-InfraFile -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzStackHCIVMStoragePath -Times 1 -Exactly -ParameterFilter { $Tag -and $Tag['environment'] -eq 'lab' }
            $null = Invoke-Path (New-InfraFile)
            Should -Invoke New-AzStackHCIVMStoragePath -Times 1 -Exactly -ParameterFilter { -not $Tag }
        }

        It 'creates only storage paths and never removes one' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'Remove-AzStackHCIVMStoragePath|Update-AzStackHCIVMStoragePath|New-Volume|Invoke-Command'
        }
    }

    Context 'the storage path already exists (idempotent)' {
        It 'creates nothing and says so' {
            Mock Get-AzStackHCIVMStoragePath { [pscustomobject]@{ Name = $Name; Path = 'C:\ClusterStorage\vol-workloads-01\vms' } }
            $r = Invoke-Path (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Detail | Should -BeNullOrEmpty
            Should -Invoke New-AzStackHCIVMStoragePath -Times 0 -Exactly
        }

        It 'reports a storage path that points somewhere else, and changes nothing' {
            Mock Get-AzStackHCIVMStoragePath { [pscustomobject]@{ Name = $Name; Path = 'C:\ClusterStorage\other' } }
            $r = Invoke-Path (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Detail | Should -Match 'cannot be moved'
            Should -Invoke New-AzStackHCIVMStoragePath -Times 0 -Exactly
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans the storage path and creates nothing' {
            $r = Invoke-Path (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzStackHCIVMStoragePath -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the file lists no storage path' {
            $r = Invoke-Path (New-InfraFile -Paths @())
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.<Key>' -ForEach @(@{ Key = 'tenant_id' }, @{ Key = 'subscription_id' }, @{ Key = 'resource_group' }, @{ Key = 'location' }, @{ Key = 'custom_location' }) {
            $r = Invoke-Path (New-InfraFile -Azure @{ $Key = $null })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match "azure.$Key"
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses the all-zero subscription id' {
            (Invoke-Path (New-InfraFile -Azure @{ subscription_id = [guid]::Empty.ToString() })).ExitCode | Should -Be 2
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a name that is too short'; Entry = @{ name = 'sp'; path = 'C:\ClusterStorage\vol-a' } }
            @{ Why = 'a name with an underscore'; Entry = @{ name = 'sp_one'; path = 'C:\ClusterStorage\vol-a' } }
            @{ Why = 'a path outside ClusterStorage'; Entry = @{ name = 'sp-one'; path = 'D:\data' } }
            @{ Why = 'the ClusterStorage root'; Entry = @{ name = 'sp-one'; path = 'C:\ClusterStorage' } }
            @{ Why = 'a path on the infrastructure volume'; Entry = @{ name = 'sp-one'; path = 'C:\ClusterStorage\Infrastructure_1\vms' } }
            @{ Why = 'a missing path'; Entry = @{ name = 'sp-one' } }
        ) {
            $r = Invoke-Path (New-InfraFile -Paths ([ordered]@{} + $Entry))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke New-AzStackHCIVMStoragePath -Times 0 -Exactly
        }

        It 'refuses the same name twice' {
            (Invoke-Path (New-InfraFile -Paths ([ordered]@{ name = 'sp-a'; path = 'C:\ClusterStorage\vol-a' }), ([ordered]@{ name = 'SP-A'; path = 'C:\ClusterStorage\vol-b' }))).ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Path (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Path (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzStackHCIVMStoragePath -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzStackHCIVMStoragePath { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Path (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            Should -Invoke New-AzStackHCIVMStoragePath -Times 0 -Exactly
        }

        It 'reports a failed creation, goes on with the next one, puts the subscription back, and exits 1' {
            Mock New-AzStackHCIVMStoragePath { throw 'AuthorizationFailed' }
            $r = Invoke-Path (New-InfraFile -Paths ([ordered]@{ name = 'sp-a'; path = 'C:\ClusterStorage\vol-a' }), ([ordered]@{ name = 'sp-b'; path = 'C:\ClusterStorage\vol-b' }))
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed', 'Failed')
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlSpTestHome }
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

        It 'reads its values through the toolkit loader, uses no Azure CLI, and holds no GUID or address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml|cluster_shared_volumes|\baz stack-hci-vm\b'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_StoragePath_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'azure.location', 'azure.custom_location', 'storage.paths[].name', 'storage.paths[].path' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
