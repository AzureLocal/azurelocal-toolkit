#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 11: Deploy-ManagementVMs.azcli.ps1 creates the management virtual machines of
# landing_zone.virtual_machines with az commands. The administrator password is a keyvault:// reference that the script reads with "az keyvault secret show"
# only when a machine is created; the tests give it a value made up at run time (a canary) and check that it reaches the one az call that needs it and
# nowhere else. "az" is mocked: no Azure, no tenant and no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ManagementVMs.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-11-deploy-management-vms', 'azurecli', 'Deploy-ManagementVMs.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlVmSub = [guid]::NewGuid().ToString()
    $global:AzlVmCanary = 'Canary-' + [guid]::NewGuid().ToString('N')
    $env:AZL_TEST_VM_PASSWORD = $global:AzlVmCanary

    function New-Machine([string]$Name = 'vm-iic-dc-01', [hashtable]$Override = @{}) {
        Set-AzOverride ([ordered]@{ name = $Name; hostname = 'iic-dc01'; role = 'domain_controller'; network = 'vnet-iic-mgmt-01'; subnet = 'snet-iic-mgmt-01'; private_ip = '192.0.2.10'; size = 'Standard_D2s_v5'; os = 'windows_server_2025'; admin_username = 'iic-vmadmin'; admin_password = 'keyvault://kv-iic-mgmt-01/vm-admin-password' }) $Override
    }
    function New-InfraFile {
        param([object[]]$Machines = @((New-Machine)), [hashtable]$Azure = @{}, [object]$Tags = $null, [object]$Tenant = $global:AzlFakeTenant, [object]$NetworkLocation = 'westeurope')
        $az = [ordered]@{ location = 'eastus' }
        if ($null -ne $Tenant) { $az.tenant_id = $Tenant }
        $null = Set-AzOverride $az $Azure
        $net = [ordered]@{ name = 'vnet-iic-mgmt-01'; subscription = 'sub-iic-management'; resource_group = 'rg-iic-mgmt-01'; address_space = @('192.0.2.0/24') }
        if ($NetworkLocation) { $net.location = $NetworkLocation }
        $doc = [ordered]@{
            azure        = $az
            key_vaults   = @([ordered]@{ name = 'kv-iic-mgmt-01'; subscription_id = $global:AzlVmSub; resource_group = 'rg-iic-mgmt-01' })
            landing_zone = [ordered]@{
                subscriptions    = @([ordered]@{ name = 'sub-iic-management'; id = $global:AzlVmSub; role = 'management' })
                networks         = @($net)
                virtual_machines = @($Machines)
            }
        }
        if ($Tags) { $doc.tags = $Tags }
        Save-AzInfraFile $doc
    }
    function Invoke-Vm([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 4>&1 5>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 4>&1 5>&1 }
        $code = $global:LASTEXITCODE
        [pscustomobject]@{
            ExitCode   = $code
            Rows       = @($all | Where-Object { $_ -isnot [string] -and $_.PSObject.Properties['Machine'] -and $_.PSObject.Properties['Action'] })
            Text       = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
            Everything = (@($all | ForEach-Object { "$_" | Out-String }) -join "`n")
        }
    }
    function New-FakeVnet { [ordered]@{ name = 'vnet-iic-mgmt-01'; id = '/vnets/vnet-iic-mgmt-01'; subnets = @([ordered]@{ name = 'snet-iic-mgmt-01'; id = '/subnets/snet-iic-mgmt-01' }) } }
}

Describe 'Deploy-ManagementVMs.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlVmSub, AzlVmCanary, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_VM_PASSWORD -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
        Add-AzRoute 'network vnet show*' (New-FakeVnet)
        Add-AzRoute 'keyvault secret show*' $global:AzlVmCanary
    }

    Context 'creating the machines (happy path)' {
        It 'creates the network interface with the static address and the machine on it, in the subscription, group and region of the network' {
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            Get-AzCall "network nic create --name vm-iic-dc-01-nic --resource-group rg-iic-mgmt-01 --location westeurope --subscription $($global:AzlVmSub) --subnet /subnets/snet-iic-mgmt-01 --private-ip-address 192.0.2.10" | Should -HaveCount 1
            Get-AzCall "vm create --name vm-iic-dc-01 --resource-group rg-iic-mgmt-01 --location westeurope --subscription $($global:AzlVmSub) --nics vm-iic-dc-01-nic --image MicrosoftWindowsServer:WindowsServer:2025-datacenter-azure-edition:latest --size Standard_D2s_v5 --computer-name iic-dc01 --os-disk-name vm-iic-dc-01-osdisk --admin-username iic-vmadmin --admin-password *" | Should -HaveCount 1
            Get-AzCall 'account set*' | Should -BeNullOrEmpty
        }

        It 'reads the password from the vault of the reference with az, and passes it to the one az call that creates the machine' {
            $null = Invoke-Vm (New-InfraFile)
            Get-AzCall 'keyvault secret show --vault-name kv-iic-mgmt-01 --name vm-admin-password --query value --output tsv' | Should -HaveCount 1
            @($global:AzlFakeCalls | Where-Object { $_.Contains($global:AzlVmCanary) }).Count | Should -Be 1
            @(Get-AzCall "*$($global:AzlVmCanary)*")[0] | Should -BeLike 'vm create*'
        }

        It 'prints, logs and returns the password nowhere' {
            $log = Join-Path $TestDrive 'vms.log'
            $global:LASTEXITCODE = $null
            $all = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -Verbose 6>&1 3>&1 2>&1 4>&1 5>&1
            (@($all | ForEach-Object { "$_" | Out-String }) -join "`n") | Should -Not -Match ([regex]::Escape($global:AzlVmCanary))
            (Get-Content -LiteralPath $log -Raw) | Should -Not -Match ([regex]::Escape($global:AzlVmCanary))
        }

        It 'cleans the password out of an az error text before it is shown' {
            Add-AzRoute 'vm create*' { "ERROR: (InvalidParameter) The password $($global:AzlVmCanary) does not meet the complexity requirements." } 1
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Everything | Should -Not -Match ([regex]::Escape($global:AzlVmCanary))
            $r.Text | Should -Match 'InvalidParameter'
        }

        It 'reads an env:// reference through the toolkit resolver, without az' {
            $r = Invoke-Vm (New-InfraFile -Machines @(New-Machine 'vm-iic-dc-01' @{ admin_password = 'env://AZL_TEST_VM_PASSWORD' }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
            @($global:AzlFakeCalls | Where-Object { $_.Contains($global:AzlVmCanary) }).Count | Should -Be 1
        }

        It 'creates an Ubuntu machine with password sign-in, and the 2022 Windows image on request' {
            $null = Invoke-Vm (New-InfraFile -Machines @((New-Machine 'vm-iic-jump-01' @{ os = 'ubuntu_2404'; hostname = $null; private_ip = '192.0.2.20' }), (New-Machine 'vm-iic-dc-02' @{ os = 'windows_server_2022'; hostname = 'iic-dc02'; private_ip = '192.0.2.11' })))
            Get-AzCall 'vm create --name vm-iic-jump-01*--image Canonical:ubuntu-24_04-lts:server:latest*--computer-name vm-iic-jump-01*--authentication-type password*' | Should -HaveCount 1
            Get-AzCall 'vm create --name vm-iic-dc-02*--image MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest*' | Should -HaveCount 1
            Get-AzCall 'vm create --name vm-iic-dc-02*--authentication-type*' | Should -BeNullOrEmpty
        }

        It 'puts the file-level tags on the network interface and the machine' {
            $null = Invoke-Vm (New-InfraFile -Tags ([ordered]@{ environment = 'lab' }))
            Get-AzCall 'network nic create*--tags environment=lab' | Should -HaveCount 1
            Get-AzCall 'vm create*--tags environment=lab' | Should -HaveCount 1
        }

        It 'uses the resource group of the machine entry, and azure.location when the network has no location' {
            $file = New-InfraFile -Machines @(New-Machine 'vm-iic-dc-01' @{ resource_group = 'rg-iic-vm-01' }) -NetworkLocation $null
            $null = Invoke-Vm $file
            Get-AzCall 'vm create --name vm-iic-dc-01 --resource-group rg-iic-vm-01 --location eastus*' | Should -HaveCount 1
            Get-AzCall 'network vnet show --name vnet-iic-mgmt-01 --resource-group rg-iic-mgmt-01*' | Should -HaveCount 1
        }

        It 'reuses a network interface that is already there' {
            Add-AzRoute 'network nic show*' ([ordered]@{ name = 'vm-iic-dc-01-nic'; id = '/nics/vm-iic-dc-01-nic' })
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 0
            Get-AzCall 'network nic create*' | Should -BeNullOrEmpty
            Get-AzCall 'vm create*' | Should -HaveCount 1
        }

        It 'skips a machine whose deploy_target is not azure, and does nothing at all when none is for Azure' {
            $r = Invoke-Vm (New-InfraFile -Machines @((New-Machine 'vm-iic-hci-01' @{ deploy_target = 'azure_local' }), (New-Machine 'vm-iic-dc-01')))
            @($r.Rows | Where-Object Action -EQ 'Skipped').Count | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Created').Count | Should -Be 1
            Initialize-AzFake
            $r = Invoke-Vm (New-InfraFile -Machines @(New-Machine 'vm-iic-hci-01' @{ deploy_target = 'onprem' }))
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'does nothing and exits 0 when the file lists no machine' {
            $r = Invoke-Vm (New-InfraFile -Machines @())
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }
    }

    Context 'the machine already exists (idempotent)' {
        It 'creates nothing, reads no secret, and reports another size without changing it' {
            Add-AzRoute 'vm show*' ([ordered]@{ name = 'vm-iic-dc-01'; hardwareProfile = [ordered]@{ vmSize = 'Standard_D4s_v5' } })
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Detail | Should -Match 'size is Standard_D4s_v5, the file says Standard_D2s_v5'
            Get-AzWriteCall | Should -BeNullOrEmpty
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf' {
        It 'plans the machine, reads no secret and writes nothing to Azure' {
            $r = Invoke-Vm (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Get-AzWriteCall | Should -BeNullOrEmpty
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'vms2.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'refuses a missing tenant' {
            $r = Invoke-Vm (New-InfraFile -Tenant $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a machine with no name'; Override = @{ name = $null }; Match = 'name' }
            @{ Case = 'a machine name Azure does not accept'; Override = @{ name = 'bad name!' }; Match = 'not a valid VM name' }
            @{ Case = 'no network'; Override = @{ network = $null }; Match = 'network is missing' }
            @{ Case = 'a network that is not in the file'; Override = @{ network = 'vnet-nowhere' }; Match = 'not an entry of landing_zone.networks' }
            @{ Case = 'no subnet'; Override = @{ subnet = $null }; Match = 'subnet is missing' }
            @{ Case = 'an address that is not IPv4'; Override = @{ private_ip = 'nowhere' }; Match = 'private_ip' }
            @{ Case = 'an address with an octet above 255'; Override = @{ private_ip = '192.0.2.256' }; Match = 'private_ip' }
            @{ Case = 'no size'; Override = @{ size = $null }; Match = 'size is missing' }
            @{ Case = 'an operating system the script does not know'; Override = @{ os = 'amiga' }; Match = 'missing or not usable' }
            @{ Case = 'no user name'; Override = @{ admin_username = $null }; Match = 'admin_username is missing' }
            @{ Case = 'no password reference'; Override = @{ admin_password = $null }; Match = 'admin_password is missing' }
            @{ Case = 'a password that is a value, not a reference'; Override = @{ admin_password = 'not-a-reference-value' }; Match = 'not a secret reference' }
            @{ Case = 'a Windows computer name over 15 characters'; Override = @{ hostname = 'a-very-long-computer-name' }; Match = '1 to 15 letters' }
            @{ Case = 'a machine in another subscription than its network'; Override = @{ subscription = 'sub-other' }; Match = 'not the subscription of its network' }
        ) {
            $r = Invoke-Vm (New-InfraFile -Machines @(New-Machine 'vm-iic-dc-01' $Override))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses the same machine twice' {
            $r = Invoke-Vm (New-InfraFile -Machines @((New-Machine 'vm-iic-dc-01'), (New-Machine 'VM-IIC-DC-01')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'listed twice'
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Vm (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when az is not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Azure CLI \(az\) was not found'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'stops when nobody is signed in' {
            Add-AzRoute 'account show*' 'ERROR: Please run ''az login'' to setup account.' 1
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the sign-in is to another tenant' {
            Add-AzRoute 'account show*' ([guid]::NewGuid().ToString())
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'fails the machine and creates nothing when the virtual network or its subnet is missing' {
            Add-AzNotFound 'network vnet show*'
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'Create it first'
            Get-AzWriteCall | Should -BeNullOrEmpty
            Add-AzRoute 'network vnet show*' ([ordered]@{ id = '/vnets/v'; subnets = @([ordered]@{ name = 'snet-other'; id = '/subnets/o' }) })
            $r = Invoke-Vm (New-InfraFile)
            $r.Rows[0].Detail | Should -Match "no subnet named 'snet-iic-mgmt-01'"
        }

        It 'fails the machine, and creates none, when the password cannot be read' {
            Add-AzRoute 'keyvault secret show*' 'ERROR: (Forbidden) The user does not have secrets get permission.' 1
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'could not be read with az'
            Get-AzCall 'vm create*' | Should -BeNullOrEmpty
        }

        It 'fails the machine when the vault of the reference is not listed under key_vaults' {
            $r = Invoke-Vm (New-InfraFile -Machines @(New-Machine 'vm-iic-dc-01' @{ admin_password = 'keyvault://kv-iic-other-01/vm-admin-password' }))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'not listed under key_vaults'
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
        }

        It 'reports a machine that cannot be created, goes on with the next one, and exits 1' {
            Add-AzRoute 'vm create --name vm-iic-dc-01*' 'ERROR: (QuotaExceeded) Operation could not be completed as it results in exceeding approved quota.' 1
            $r = Invoke-Vm (New-InfraFile -Machines @((New-Machine 'vm-iic-dc-01'), (New-Machine 'vm-iic-dc-02' @{ private_ip = '192.0.2.11'; hostname = 'iic-dc02' })))
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed').Count | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Created').Count | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed')[0].Detail | Should -Match 'QuotaExceeded'
        }

        It 'does not hide a read error that is not a not-found' {
            Add-AzRoute 'vm show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-Vm (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Get-AzWriteCall | Should -BeNullOrEmpty
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, holds no GUID, and never uses the Az keyvault cmdlets' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
            $script:Text | Should -Not -Match 'Get-AzKeyVaultSecret|ConvertTo-SecureString|Write-Host'
        }

        It 'has every parameter registered' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($p in 'InfrastructureFile', 'LogPath') {
                ($registry -match ('Deploy_ManagementVMs_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
