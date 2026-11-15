#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), the Azure CLI scripts: the storage paths, the VM images, the network security groups, the logical networks, SSH over Azure Arc, the
# Azure side of the post-deployment verification and the cloud witness storage account. Every az command is replaced by a fake (tests/fixtures/AzCliFake.ps1): no
# Azure, no tenant and no sign-in is used. The ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/AzureCliScripts.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks and stub parameters.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $phase = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment')
    $script:StoragePath = [IO.Path]::Combine($phase, 'task-05-storage-configuration', 'azurecli', 'New-StoragePath.azcli.ps1')
    $script:VmImage = [IO.Path]::Combine($phase, 'task-06-image-downloads', 'azurecli', 'New-VmImage.azcli.ps1')
    $script:Nsg = [IO.Path]::Combine($phase, 'task-07-configure-nsgs', 'azurecli', 'New-NetworkSecurityGroup.azcli.ps1')
    $script:Lnet = [IO.Path]::Combine($phase, 'task-08-logical-network-creation', 'azurecli', 'New-LogicalNetwork.azcli.ps1')
    $script:Ssh = [IO.Path]::Combine($phase, 'task-04-ssh-connectivity-to-nodes', 'azurecli', 'Enable-ArcSshConnectivity.azcli.ps1')
    $script:Verify = [IO.Path]::Combine($phase, 'task-09-post-deployment-verification', 'azurecli', 'Invoke-VerifyPostDeployment.azcli.ps1')
    $script:Witness = [IO.Path]::Combine($phase, 'task-02-cluster-quorum-configuration', 'azurecli', 'New-CloudWitnessStorageAccount.azcli.ps1')
    $script:Tool = @{ StoragePath = $script:StoragePath; VmImage = $script:VmImage; Nsg = $script:Nsg; Lnet = $script:Lnet; Ssh = $script:Ssh; Verify = $script:Verify; Witness = $script:Witness }
    Import-Module powershell-yaml
    function az { }
    . ([IO.Path]::Combine($repo, 'tests', 'fixtures', 'AzCliFake.ps1'))
    $script:Notfound = '(ResourceNotFound) The Resource was not found.'
    $script:CustomLocationId = "/subscriptions/$($global:AzlTestSubscription)/resourceGroups/rg-azl-01/providers/Microsoft.ExtendedLocation/customLocations/cl-azl-01"
    $script:Sub = $global:AzlTestSubscription
}

# What every script does first: stop with exit code 2 before any az call when a value is missing, and with exit code 1 when az is missing, not signed in, in another
# tenant or without the extension. $Edit is an edit that spoils the file.
Describe 'The common behaviour of the scripts' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        Set-AzHandler 'extension show' { '{"name":"x"}' }
        Set-AzHandler 'stack-hci-vm storagepath show' { New-AzFailure 3 $script:Notfound }
        Set-AzHandler 'stack-hci-vm storagepath create' { }
        Set-AzHandler 'provider show' { 'Registered' }
        Set-AzHandler 'stack-hci-vm image show' { New-AzFailure 3 $script:Notfound }
        Set-AzHandler 'stack-hci-vm network nsg show' { New-AzFailure 3 $script:Notfound }
        Set-AzHandler 'stack-hci-vm network lnet show' { New-AzFailure 3 $script:Notfound }
        Set-AzHandler 'storage account show' { New-AzFailure 3 $script:Notfound }
        Set-AzHandler 'connectedmachine show' { New-AzFailure 3 $script:Notfound }
    }

    It '<Name> stops with exit code 2 and calls no az command when the tenant is missing' -ForEach @(
        @{ Name = 'New-StoragePath'; Path = 'StoragePath' }, @{ Name = 'New-VmImage'; Path = 'VmImage' }, @{ Name = 'New-NetworkSecurityGroup'; Path = 'Nsg' }
        @{ Name = 'New-LogicalNetwork'; Path = 'Lnet' }, @{ Name = 'Enable-ArcSshConnectivity'; Path = 'Ssh' }, @{ Name = 'Invoke-VerifyPostDeployment'; Path = 'Verify' }
        @{ Name = 'New-CloudWitnessStorageAccount'; Path = 'Witness' }
    ) {
        $r = Invoke-AzTool ($script:Tool[$Path]) (New-AzTestInfraFile { param($d) $d.azure.Remove('tenant_id') })
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It '<Name> stops with exit code 1 when the Azure CLI is signed in to another tenant' -ForEach @(
        @{ Name = 'New-StoragePath'; Path = 'StoragePath' }, @{ Name = 'New-VmImage'; Path = 'VmImage' }, @{ Name = 'New-NetworkSecurityGroup'; Path = 'Nsg' }
        @{ Name = 'New-LogicalNetwork'; Path = 'Lnet' }, @{ Name = 'Enable-ArcSshConnectivity'; Path = 'Ssh' }, @{ Name = 'Invoke-VerifyPostDeployment'; Path = 'Verify' }
        @{ Name = 'New-CloudWitnessStorageAccount'; Path = 'Witness' }
    ) {
        Set-AzSignIn ([guid]::NewGuid().ToString()) $global:AzlTestSubscription
        $r = Invoke-AzTool ($script:Tool[$Path]) (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'tenant'
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It '<Name> stops with exit code 1 when nobody is signed in' -ForEach @(
        @{ Name = 'New-StoragePath'; Path = 'StoragePath' }, @{ Name = 'New-VmImage'; Path = 'VmImage' }, @{ Name = 'New-NetworkSecurityGroup'; Path = 'Nsg' }
        @{ Name = 'New-LogicalNetwork'; Path = 'Lnet' }, @{ Name = 'Enable-ArcSshConnectivity'; Path = 'Ssh' }, @{ Name = 'Invoke-VerifyPostDeployment'; Path = 'Verify' }
        @{ Name = 'New-CloudWitnessStorageAccount'; Path = 'Witness' }
    ) {
        Set-AzHandler 'account show' { New-AzFailure 1 'Please run az login to setup account.' }
        $r = Invoke-AzTool ($script:Tool[$Path]) (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'Not signed in'
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It '<Name> stops with exit code 1 when the Azure CLI is not installed' -ForEach @(
        @{ Name = 'New-StoragePath'; Path = 'StoragePath' }, @{ Name = 'New-VmImage'; Path = 'VmImage' }, @{ Name = 'New-NetworkSecurityGroup'; Path = 'Nsg' }
        @{ Name = 'New-LogicalNetwork'; Path = 'Lnet' }, @{ Name = 'Enable-ArcSshConnectivity'; Path = 'Ssh' }, @{ Name = 'Invoke-VerifyPostDeployment'; Path = 'Verify' }
        @{ Name = 'New-CloudWitnessStorageAccount'; Path = 'Witness' }
    ) {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        $r = Invoke-AzTool ($script:Tool[$Path]) (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'Azure CLI \(az\) was not found'
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It '<Name> stops with exit code 1 when its az extension is not installed' -ForEach @(
        @{ Name = 'New-StoragePath'; Path = 'StoragePath' }, @{ Name = 'New-VmImage'; Path = 'VmImage' }, @{ Name = 'New-NetworkSecurityGroup'; Path = 'Nsg' }
        @{ Name = 'New-LogicalNetwork'; Path = 'Lnet' }, @{ Name = 'Enable-ArcSshConnectivity'; Path = 'Ssh' }
    ) {
        Set-AzHandler 'extension show' { New-AzFailure 1 'The extension is not installed.' }
        $r = Invoke-AzTool ($script:Tool[$Path]) (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'extension'
        @(Get-AzWriteCall).Count | Should -Be 0
    }
}

Describe 'New-StoragePath.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        Set-AzHandler 'extension show' { '{"name":"stack-hci-vm"}' }
        Set-AzHandler 'stack-hci-vm storagepath show' { New-AzFailure 3 $script:Notfound }
        Set-AzHandler 'stack-hci-vm storagepath create' { }
    }

    It 'creates the storage path with the values of the file' {
        $r = Invoke-AzTool $script:StoragePath (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $create = (Get-AzCall 'stack-hci-vm storagepath create')[0]
        $create.Options['--name'] | Should -Be 'sp-workloads-01'
        $create.Options['--path'] | Should -Be 'C:\ClusterStorage\vol-workloads-01\vms'
        $create.Options['--resource-group'] | Should -Be 'rg-azl-01'
        $create.Options['--subscription'] | Should -Be $script:Sub
        $create.Options['--location'] | Should -Be 'eastus'
        $create.Options['--custom-location'] | Should -Be $script:CustomLocationId
        $create.Options['--tags'] | Should -Be 'environment=lab'
        @($r.Rows.Action) | Should -Be @('Created')
    }

    It 'changes nothing under -WhatIf, and says what it would create' {
        $r = Invoke-AzTool $script:StoragePath (New-AzTestInfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'stack-hci-vm storagepath create').Count | Should -Be 0
        @($r.Rows.Action) | Should -Be @('WouldCreate')
    }

    It 'leaves a storage path that exists alone, and reports a different folder' {
        Set-AzHandler 'stack-hci-vm storagepath show' { '{"name":"sp-workloads-01","properties":{"path":"C:\\ClusterStorage\\other\\vms"}}' }
        $r = Invoke-AzTool $script:StoragePath (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'stack-hci-vm storagepath create').Count | Should -Be 0
        @($r.Rows.Action) | Should -Be @('AlreadyExists')
        $r.Rows[0].Detail | Should -Match 'differs from the file'
    }

    It 'refuses a path on the infrastructure volume with exit code 2 and calls nothing' {
        $r = Invoke-AzTool $script:StoragePath (New-AzTestInfraFile { param($d) $d.storage.paths[0].path = 'C:\ClusterStorage\Infrastructure_1\vms' })
        $r.ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'does nothing and ends with exit code 0 when the file lists no storage path' {
        $r = Invoke-AzTool $script:StoragePath (New-AzTestInfraFile { param($d) $d.storage.Remove('paths') })
        $r.ExitCode | Should -Be 0
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'ends with exit code 1 when the creation fails' {
        Set-AzHandler 'stack-hci-vm storagepath create' { New-AzFailure 1 'The custom location is not ready.' }
        $r = Invoke-AzTool $script:StoragePath (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        @($r.Rows.Action) | Should -Be @('Failed')
    }
}

Describe 'New-VmImage.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        Set-AzHandler 'extension show' { '{"name":"stack-hci-vm"}' }
        Set-AzHandler 'provider show' { 'Registered' }
        $global:AzlImageState = @{ Created = $false }
        Set-AzHandler 'stack-hci-vm image show' {
            if (-not $global:AzlImageState.Created) { return (New-AzFailure 3 $script:Notfound) }
            '{"name":"img-ws2025","properties":{"version":{"name":"26100.1.1"},"status":{"provisioningStatus":{"status":"Succeeded"}}}}'
        }
        Set-AzHandler 'stack-hci-vm storagepath show' { '{"name":"sp-workloads-01","id":"/subscriptions/x/resourceGroups/rg-azl-01/providers/Microsoft.AzureStackHCI/storageContainers/sp-workloads-01"}' }
        Set-AzHandler 'stack-hci-vm image create' { $global:AzlImageState.Created = $true }
    }
    AfterAll { Remove-Variable -Name AzlImageState -Scope Global -ErrorAction SilentlyContinue }

    It 'creates the image from the Marketplace values of the file, on the storage path, and reads the version back' {
        $r = Invoke-AzTool $script:VmImage (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $create = (Get-AzCall 'stack-hci-vm image create')[0]
        $create.Options['--name'] | Should -Be 'img-ws2025'
        $create.Options['--publisher'] | Should -Be 'microsoftwindowsserver'
        $create.Options['--offer'] | Should -Be 'windowsserver'
        $create.Options['--sku'] | Should -Be '2025-datacenter-azure-edition'
        $create.Options['--version'] | Should -Be 'latest'
        $create.Options['--os-type'] | Should -Be 'Windows'
        $create.Options['--custom-location'] | Should -Be $script:CustomLocationId
        $create.Options['--storage-path-id'] | Should -Match 'storageContainers/sp-workloads-01$'
        @($r.Rows.Action) | Should -Be @('Created')
        $r.Rows[0].Version | Should -Be '26100.1.1'
    }

    It 'changes nothing under -WhatIf' {
        $r = Invoke-AzTool $script:VmImage (New-AzTestInfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'stack-hci-vm image create').Count | Should -Be 0
        @($r.Rows.Action) | Should -Be @('WouldCreate')
    }

    It 'ends with exit code 1 and creates nothing when Microsoft.EdgeMarketplace is not registered' {
        Set-AzHandler 'provider show' { 'NotRegistered' }
        $r = Invoke-AzTool $script:VmImage (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Microsoft.EdgeMarketplace'
        (Get-AzCall 'stack-hci-vm image create').Count | Should -Be 0
    }

    It 'leaves an image that exists alone, and keeps a failed one in place with exit code 1' {
        $global:AzlImageState.Created = $true
        $r = Invoke-AzTool $script:VmImage (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows.Action) | Should -Be @('AlreadyExists')
        Set-AzHandler 'stack-hci-vm image show' { '{"name":"img-ws2025","properties":{"status":{"provisioningStatus":{"status":"Failed"},"errorCode":"E1","errorMessage":"download failed"}}}' }
        $r = Invoke-AzTool $script:VmImage (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        $r.Rows[0].Detail | Should -Match 'download failed'
        (Get-AzCall 'stack-hci-vm image create').Count | Should -Be 0
    }

    It 'stops with exit code 2 for a storage path that storage.paths does not list, and for another operating system' {
        (Invoke-AzTool $script:VmImage (New-AzTestInfraFile { param($d) $d.storage.vm_images[0].storage_path = 'unlisted' })).ExitCode | Should -Be 2
        (Invoke-AzTool $script:VmImage (New-AzTestInfraFile { param($d) $d.storage.vm_images[0].os_type = 'Plan9' })).ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
    }
}

Describe 'New-NetworkSecurityGroup.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        Set-AzHandler 'extension show' { '{"name":"stack-hci-vm"}' }
        Set-AzHandler 'stack-hci-vm network nsg show' { New-AzFailure 3 $script:Notfound }
        Set-AzHandler 'stack-hci-vm network nsg create' { }
        Set-AzHandler 'stack-hci-vm network nsg rule list' { '[]' }
        Set-AzHandler 'stack-hci-vm network nsg rule create' { }
    }

    It 'creates the group, then its rule, with the values of the file' {
        $r = Invoke-AzTool $script:Nsg (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $group = (Get-AzCall 'stack-hci-vm network nsg create')[0]
        $group.Options['--name'] | Should -Be 'nsg-workloads'
        $group.Options['--custom-location'] | Should -Be $script:CustomLocationId
        $group.Options['--location'] | Should -Be 'eastus'
        $rule = (Get-AzCall 'stack-hci-vm network nsg rule create')[0]
        $rule.Options['--nsg-name'] | Should -Be 'nsg-workloads'
        $rule.Options['--name'] | Should -Be 'allow-https-in'
        $rule.Options['--priority'] | Should -Be '100'
        $rule.Options['--direction'] | Should -Be 'Inbound'
        $rule.Options['--protocol'] | Should -Be 'Tcp'
        @($rule.Options['--destination-port-ranges']) | Should -Be @('443')
        $order = @($global:AzlFake.Calls | Where-Object { $_.Command -like 'stack-hci-vm network nsg*create' } | ForEach-Object Command)
        $order | Should -Be @('stack-hci-vm network nsg create', 'stack-hci-vm network nsg rule create')
    }

    It 'changes nothing under -WhatIf' {
        $r = Invoke-AzTool $script:Nsg (New-AzTestInfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It 'stops with exit code 2 and calls nothing when SDN is off, or the group has no rule' {
        (Invoke-AzTool $script:Nsg (New-AzTestInfraFile { param($d) $d.sdn.enabled = $false })).ExitCode | Should -Be 2
        (Invoke-AzTool $script:Nsg (New-AzTestInfraFile { param($d) $d.networking.network_security_groups[0].rules = @() })).ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'leaves a group and a rule that exist alone' {
        Set-AzHandler 'stack-hci-vm network nsg show' { '{"name":"nsg-workloads"}' }
        Set-AzHandler 'stack-hci-vm network nsg rule list' { '[{"name":"allow-https-in","properties":{"priority":100,"direction":"Inbound","access":"Allow","protocol":"Tcp","sourceAddressPrefixes":["*"],"destinationAddressPrefixes":["*"],"sourcePortRanges":["*"],"destinationPortRanges":["443"]}}]' }
        $r = Invoke-AzTool $script:Nsg (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-AzWriteCall).Count | Should -Be 0
    }
}

Describe 'New-LogicalNetwork.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        Set-AzHandler 'extension show' { '{"name":"stack-hci-vm"}' }
        Set-AzHandler 'stack-hci-vm network lnet show' { New-AzFailure 3 $script:Notfound }
        Set-AzHandler 'stack-hci-vm network lnet create' { }
        Set-AzHandler 'stack-hci-vm network nsg show' { '{"name":"nsg-workloads"}' }
        Set-AzHandler 'stack-hci-vm network nsg rule list' { '[{"name":"allow-https-in"}]' }
    }

    It 'creates the static logical network on the switch and with the addresses of the file, tied to its group' {
        $r = Invoke-AzTool $script:Lnet (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $create = (Get-AzCall 'stack-hci-vm network lnet create')[0]
        $create.Options['--name'] | Should -Be 'lnet-workloads'
        $create.Options['--vm-switch-name'] | Should -Be 'ConvergedSwitch'
        $create.Options['--ip-allocation-method'] | Should -Be 'Static'
        $create.Options['--vlan'] | Should -Be '100'
        $create.Options['--address-prefixes'] | Should -Be '192.0.2.0/24'
        $create.Options['--gateway'] | Should -Be '192.0.2.1'
        $create.Options['--dns-servers'] | Should -Be '192.0.2.10'
        $create.Options['--ip-pool-start'] | Should -Be '192.0.2.50'
        $create.Options['--ip-pool-end'] | Should -Be '192.0.2.99'
        $create.Options['--network-security-group'] | Should -Be 'nsg-workloads'
        $create.Options['--custom-location'] | Should -Be $script:CustomLocationId
    }

    It 'changes nothing under -WhatIf' {
        $r = Invoke-AzTool $script:Lnet (New-AzTestInfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-AzWriteCall).Count | Should -Be 0
        @($r.Rows.Action) | Should -Be @('WouldCreate')
    }

    It 'stops with exit code 2 and calls nothing for a network without vm_switch_name, because it cannot read the cluster' {
        $r = Invoke-AzTool $script:Lnet (New-AzTestInfraFile { param($d) $d.networking.logical_networks[0].Remove('vm_switch_name') })
        $r.ExitCode | Should -Be 2
        $r.Text | Should -Match 'vm_switch_name'
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'stops with exit code 2 for a gateway outside the address range' {
        $r = Invoke-AzTool $script:Lnet (New-AzTestInfraFile { param($d) $d.networking.logical_networks[0].gateway = '198.51.100.1' })
        $r.ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'ends with exit code 1 and creates nothing when the network security group has no rule' {
        Set-AzHandler 'stack-hci-vm network nsg rule list' { '[]' }
        $r = Invoke-AzTool $script:Lnet (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        (Get-AzCall 'stack-hci-vm network lnet create').Count | Should -Be 0
    }

    It 'leaves a logical network that exists alone' {
        Set-AzHandler 'stack-hci-vm network lnet show' { '{"name":"lnet-workloads","properties":{"vmSwitchName":"ConvergedSwitch","subnets":[{"properties":{"addressPrefix":"192.0.2.0/24","ipAllocationMethod":"Static"}}]}}' }
        $r = Invoke-AzTool $script:Lnet (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows.Action) | Should -Be @('AlreadyExists')
        (Get-AzCall 'stack-hci-vm network lnet create').Count | Should -Be 0
    }
}

Describe 'Enable-ArcSshConnectivity.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Mock Start-Sleep { }
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        $global:AzlSshState = @{ Provider = 'Registered'; Extension = @{}; Bodies = [System.Collections.Generic.List[string]]::new() }
        Set-AzHandler 'extension show' { '{"name":"connectedmachine"}' }
        Set-AzHandler 'provider show' { $global:AzlSshState.Provider }
        Set-AzHandler 'provider register' { $global:AzlSshState.Provider = 'Registered' }
        Set-AzHandler 'connectedmachine show' { '{"name":"x","location":"eastus","status":"Connected"}' }
        Set-AzHandler 'connectedmachine extension show' {
            param($o, $a)
            $null = $a
            if (-not $global:AzlSshState.Extension[$o['--machine-name'][0]]) { return (New-AzFailure 3 $script:Notfound) }
            '{"name":"WindowsOpenSSH","properties":{"provisioningState":"Succeeded"}}'
        }
        Set-AzHandler 'connectedmachine extension create' { param($o, $a); $null = $a; $global:AzlSshState.Extension[$o['--machine-name'][0]] = $true }
        Set-AzHandler 'rest' {
            param($o, $a)
            $null = $a
            $global:AzlSshState.Bodies.Add((Get-Content -LiteralPath ($o['--body'][0].Substring(1)) -Raw))
        }
    }
    AfterAll { Remove-Variable -Name AzlSshState -Scope Global -ErrorAction SilentlyContinue }

    It 'creates the extension, the endpoint and the SSH configuration of every node, with the Arc machine names of the file' {
        $r = Invoke-AzTool $script:Ssh (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $create = Get-AzCall 'connectedmachine extension create'
        @($create | ForEach-Object { $_.Options['--machine-name'][0] }) | Should -Be @('azl-n01', 'arc-azl-n02')
        $create[0].Options['--publisher'] | Should -Be 'Microsoft.Azure.OpenSSH'
        $create[0].Options['--type'] | Should -Be 'WindowsOpenSSH'
        $create[0].Options['--location'] | Should -Be 'eastus'
        $puts = Get-AzCall 'rest'
        $puts.Count | Should -Be 4
        $puts[0].Options['--url'] | Should -Match "^/subscriptions/$($script:Sub)/resourceGroups/rg-azl-01/providers/Microsoft.HybridCompute/machines/azl-n01/providers/Microsoft.HybridConnectivity/endpoints/default\?api-version="
        $puts[1].Options['--url'] | Should -Match 'serviceconfigurations/SSH'
        ($global:AzlSshState.Bodies[1] | ConvertFrom-Json).properties.port | Should -Be 22
    }

    It 'changes nothing under -WhatIf' {
        $global:AzlSshState.Provider = 'NotRegistered'
        $r = Invoke-AzTool $script:Ssh (New-AzTestInfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It 'registers Microsoft.HybridConnectivity first when it is not registered' {
        $global:AzlSshState.Provider = 'NotRegistered'
        $r = Invoke-AzTool $script:Ssh (New-AzTestInfraFile) @{ TargetNode = 'azl-n01' }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'provider register')[0].Options['--namespace'] | Should -Be 'Microsoft.HybridConnectivity'
        @(Get-AzCall 'connectedmachine extension create').Count | Should -Be 1
    }

    It 'uses the SSH port the caller names' {
        $null = Invoke-AzTool $script:Ssh (New-AzTestInfraFile) @{ TargetNode = 'azl-n01'; SshdPort = 2222 }
        ($global:AzlSshState.Bodies[1] | ConvertFrom-Json).properties.port | Should -Be 2222
    }

    It 'ends with exit code 1 for a machine that is not Connected, and with exit code 2 for an unknown node' {
        Set-AzHandler 'connectedmachine show' { '{"name":"x","location":"eastus","status":"Disconnected"}' }
        $r = Invoke-AzTool $script:Ssh (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        (Get-AzCall 'connectedmachine extension create').Count | Should -Be 0
        (Invoke-AzTool $script:Ssh (New-AzTestInfraFile) @{ TargetNode = 'no-such-node' }).ExitCode | Should -Be 2
    }
}

Describe 'Invoke-VerifyPostDeployment.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        $global:AzlVerifyState = @{ ExtensionState = 'Succeeded'; Images = 1 }
        Set-AzHandler 'connectedmachine show' { '{"name":"x","status":"Connected"}' }
        Set-AzHandler 'connectedmachine extension list' {
            $s = $global:AzlVerifyState.ExtensionState
            '[{"name":"AzureEdgeTelemetryAndDiagnostics","properties":{"provisioningState":"' + $s + '"}},{"name":"AzureEdgeDeviceManagement","properties":{"provisioningState":"Succeeded"}},{"name":"AzureEdgeLifecycleManager","properties":{"provisioningState":"Succeeded"}},{"name":"AzureEdgeRemoteSupport","properties":{"provisioningState":"Succeeded"}},{"name":"WindowsOpenSSH","properties":{"provisioningState":"Succeeded"}}]'
        }
        Set-AzHandler 'stack-hci cluster list' { '[{"name":"azl-cl-01","provisioningState":"Succeeded","status":"ConnectedRecently"}]' }
        Set-AzHandler 'customlocation show' { '{"name":"cl-azl-01","provisioningState":"Succeeded"}' }
        Set-AzHandler 'storage account show' { '{"name":"stazlwitness01","provisioningState":"Succeeded"}' }
        Set-AzHandler 'stack-hci-vm storagepath list' { '[{"name":"sp-workloads-01"}]' }
        Set-AzHandler 'stack-hci-vm image list' { if ($global:AzlVerifyState.Images -gt 0) { '[{"name":"img-ws2025","properties":{"provisioningState":"Succeeded"}}]' } else { '[]' } }
        Set-AzHandler 'stack-hci-vm network lnet list' { '[{"name":"lnet-workloads","properties":{"provisioningState":"Succeeded"}}]' }
        Set-AzHandler 'stack-hci-vm network nsg list' { '[{"name":"nsg-workloads"}]' }
    }
    AfterAll { Remove-Variable -Name AzlVerifyState -Scope Global -ErrorAction SilentlyContinue }

    It 'passes when Azure shows every machine, extension, resource and count of the file, and changes nothing' {
        $r = Invoke-AzTool $script:Verify (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object Result -EQ 'Failed').Count | Should -Be 0
        @(Get-AzCall 'connectedmachine show' | ForEach-Object { $_.Options['--name'][0] }) | Should -Be @('azl-n01', 'arc-azl-n02')
        (Get-AzCall 'stack-hci cluster list')[0].Options['--resource-group'] | Should -Be 'rg-azl-01'
        (Get-AzCall 'customlocation show')[0].Options['--name'] | Should -Be 'cl-azl-01'
        (Get-AzCall 'storage account show')[0].Options['--name'] | Should -Be 'stazlwitness01'
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It 'ends with exit code 1 and names the extension that is not Succeeded' {
        $global:AzlVerifyState.ExtensionState = 'Failed'
        $r = Invoke-AzTool $script:Verify (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'AzureEdgeTelemetryAndDiagnostics'
    }

    It 'ends with exit code 1 when fewer images Succeeded than the file lists' {
        $global:AzlVerifyState.Images = 0
        (Invoke-AzTool $script:Verify (New-AzTestInfraFile)).ExitCode | Should -Be 1
    }

    It 'runs no check under -WhatIf' {
        $r = Invoke-AzTool $script:Verify (New-AzTestInfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'stops with exit code 2 for a cloud witness without a storage account' {
        $r = Invoke-AzTool $script:Verify (New-AzTestInfraFile { param($d) $d.cluster.witness.Remove('storage_account') })
        $r.ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
    }
}

Describe 'New-CloudWitnessStorageAccount.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        Set-AzHandler 'storage account show' { New-AzFailure 3 $script:Notfound }
        Set-AzHandler 'storage account check-name' { 'true' }
        Set-AzHandler 'storage account create' { }
    }

    It 'creates a Standard LRS general-purpose v2 account with the name, group, region and tags of the file, and reads no key' {
        $r = Invoke-AzTool $script:Witness (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $create = (Get-AzCall 'storage account create')[0]
        $create.Options['--name'] | Should -Be 'stazlwitness01'
        $create.Options['--resource-group'] | Should -Be 'rg-azl-01'
        $create.Options['--location'] | Should -Be 'eastus'
        $create.Options['--kind'] | Should -Be 'StorageV2'
        $create.Options['--sku'] | Should -Be 'Standard_LRS'
        $create.Options['--tags'] | Should -Be 'environment=lab'
        @($global:AzlFake.Calls | Where-Object Command -Like '*keys*').Count | Should -Be 0
    }

    It 'changes nothing under -WhatIf' {
        $r = Invoke-AzTool $script:Witness (New-AzTestInfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-AzWriteCall).Count | Should -Be 0
        @($r.Rows.Action) | Should -Be @('WouldCreate')
    }

    It 'leaves an account of the right kind alone, and ends with exit code 1 for an account of the wrong SKU' {
        Set-AzHandler 'storage account show' { '{"name":"stazlwitness01","kind":"StorageV2","sku":{"name":"Standard_LRS"}}' }
        (Invoke-AzTool $script:Witness (New-AzTestInfraFile)).ExitCode | Should -Be 0
        (Get-AzCall 'storage account create').Count | Should -Be 0
        Set-AzHandler 'storage account show' { '{"name":"stazlwitness01","kind":"StorageV2","sku":{"name":"Premium_LRS"}}' }
        $r = Invoke-AzTool $script:Witness (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Standard_LRS'
    }

    It 'ends with exit code 1 when the name is taken in Azure' {
        Set-AzHandler 'storage account check-name' { 'false' }
        $r = Invoke-AzTool $script:Witness (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        (Get-AzCall 'storage account create').Count | Should -Be 0
    }

    It 'ends with exit code 0 and calls nothing for a witness that is not in the cloud' {
        $r = Invoke-AzTool $script:Witness (New-AzTestInfraFile { param($d) $d.cluster.witness = [ordered]@{ type = 'none' } })
        $r.ExitCode | Should -Be 0
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'stops with exit code 2 for a storage account name that Azure does not allow' {
        $r = Invoke-AzTool $script:Witness (New-AzTestInfraFile { param($d) $d.cluster.witness.storage_account = 'Not_Valid' })
        $r.ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
    }
}
