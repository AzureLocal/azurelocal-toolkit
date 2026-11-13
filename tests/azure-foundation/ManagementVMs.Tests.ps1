#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 11: Deploy-ManagementVMs.ps1 creates the Azure machines of
# landing_zone.virtual_machines (a network interface with a static address, then the machine). Every Az cmdlet is mocked: no Azure, no tenant,
# no sign-in is used. The administrator password is read from an environment variable the test sets; its value is a per-run canary that must not
# appear in any output.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ManagementVMs.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-11-deploy-management-vms', 'powershell', 'Deploy-ManagementVMs.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzVM { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzVM { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Location, [object]$VM, [hashtable]$Tag) }
    function New-AzVMConfig { [CmdletBinding()] param([string]$VMName, [string]$VMSize) }
    function Set-AzVMOperatingSystem { [CmdletBinding()] param([object]$VM, [switch]$Windows, [switch]$Linux, [string]$ComputerName, [pscredential]$Credential, [switch]$ProvisionVMAgent, [switch]$EnableAutoUpdate) }
    function Set-AzVMSourceImage { [CmdletBinding()] param([object]$VM, [string]$PublisherName, [string]$Offer, [string]$Skus, [string]$Version) }
    function Set-AzVMOSDisk { [CmdletBinding()] param([object]$VM, [string]$Name, [string]$CreateOption) }
    function Add-AzVMNetworkInterface { [CmdletBinding()] param([object]$VM, [string]$Id) }
    function Get-AzVirtualNetwork { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzVirtualNetworkSubnetConfig { [CmdletBinding()] param([string]$Name, [object]$VirtualNetwork) }
    function Get-AzNetworkInterface { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function New-AzNetworkInterface { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name, [string]$Location, [string]$SubnetId, [string]$PrivateIpAddress, [hashtable]$Tag) }

    $global:AzlVmTenant = [guid]::NewGuid().ToString()
    $global:AzlVmSub = [guid]::NewGuid().ToString()
    $global:AzlVmHome = [guid]::NewGuid().ToString()
    $global:AzlVmCanary = 'Canary-' + [guid]::NewGuid().ToString('N')
    $env:AZL_TEST_VM_PASSWORD = $global:AzlVmCanary
    $global:AzlVmCalls = [System.Collections.Generic.List[string]]::new()

    function New-Machine([string]$Name = 'vm-iic-dc-01', [hashtable]$Override = @{}) {
        $m = [ordered]@{ name = $Name; hostname = 'iic-dc01'; role = 'domain_controller'; network = 'vnet-iic-mgmt-01'; subnet = 'snet-iic-mgmt-01'; private_ip = '192.0.2.10'; size = 'Standard_D2s_v5'; os = 'windows_server_2025'; admin_username = 'iic-vmadmin'; admin_password = 'env://AZL_TEST_VM_PASSWORD' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $m.Remove($k) } else { $m[$k] = $Override[$k] } }
        $m
    }
    function New-InfraFile {
        param([object[]]$Machines = @((New-Machine)), [hashtable]$Azure = @{}, [object]$Tags = $null)
        $az = [ordered]@{ tenant_id = $global:AzlVmTenant; location = 'eastus' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{
            azure        = $az
            landing_zone = [ordered]@{
                subscriptions    = @([ordered]@{ name = 'sub-iic-management'; id = $global:AzlVmSub; role = 'management' })
                networks         = @([ordered]@{ name = 'vnet-iic-mgmt-01'; subscription = 'sub-iic-management'; resource_group = 'rg-iic-mgmt-01'; location = 'westeurope'; address_space = @('192.0.2.0/24') })
                virtual_machines = @($Machines)
            }
        }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Vms([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode   = $code
            Rows       = @($all | Where-Object { $_.PSObject.Properties['Machine'] -and $_.PSObject.Properties['Action'] })
            Text       = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
            Everything = (@($all | ForEach-Object { "$_" | Out-String }) -join "`n")
        }
    }
}

Describe 'Deploy-ManagementVMs.ps1' {
    AfterAll { Remove-Variable -Name AzlVmTenant, AzlVmSub, AzlVmHome, AzlVmCanary, AzlVmCalls -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_VM_PASSWORD -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlVmTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlVmHome } } }
        Mock Set-AzContext { }
        Mock Get-AzVM { throw "The Resource 'Microsoft.Compute/virtualMachines/$Name' was not found (404 NotFound)." }
        Mock Get-AzVirtualNetwork { [pscustomobject]@{ Name = $Name; Id = "/vnet/$Name" } }
        Mock Get-AzVirtualNetworkSubnetConfig { [pscustomobject]@{ Name = $Name; Id = "/subnet/$Name" } }
        Mock Get-AzNetworkInterface { throw "The Resource 'Microsoft.Network/networkInterfaces/$Name' was not found (404 NotFound)." }
        Mock New-AzNetworkInterface { [pscustomobject]@{ Name = $Name; Id = "/nic/$Name" } }
        Mock New-AzVMConfig { [pscustomobject]@{ Name = $VMName; Size = $VMSize } }
        Mock Set-AzVMOperatingSystem { $VM }
        Mock Set-AzVMSourceImage { $VM }
        Mock Set-AzVMOSDisk { $VM }
        Mock Add-AzVMNetworkInterface { $VM }
        Mock New-AzVM { [pscustomobject]@{ Name = $VM.Name } }
    }

    Context 'creating machines' {
        It 'creates the network interface with the static address and a Windows machine from the image of its os, in the network''s subscription and region' {
            $r = Invoke-Vms (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            $r.Rows[0].Role | Should -Be 'domain_controller'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVmSub }
            Should -Invoke New-AzNetworkInterface -Times 1 -Exactly -ParameterFilter { $Name -eq 'vm-iic-dc-01-nic' -and $ResourceGroupName -eq 'rg-iic-mgmt-01' -and $Location -eq 'westeurope' -and $SubnetId -eq '/subnet/snet-iic-mgmt-01' -and $PrivateIpAddress -eq '192.0.2.10' }
            Should -Invoke New-AzVMConfig -Times 1 -Exactly -ParameterFilter { $VMName -eq 'vm-iic-dc-01' -and $VMSize -eq 'Standard_D2s_v5' }
            Should -Invoke Set-AzVMOperatingSystem -Times 1 -Exactly -ParameterFilter { $Windows -and $ComputerName -eq 'iic-dc01' -and $Credential.UserName -eq 'iic-vmadmin' -and $Credential.GetNetworkCredential().Password -eq $global:AzlVmCanary }
            Should -Invoke Set-AzVMSourceImage -Times 1 -Exactly -ParameterFilter { $PublisherName -eq 'MicrosoftWindowsServer' -and $Offer -eq 'WindowsServer' -and $Skus -eq '2025-datacenter-azure-edition' -and $Version -eq 'latest' }
            Should -Invoke Add-AzVMNetworkInterface -Times 1 -Exactly -ParameterFilter { $Id -eq '/nic/vm-iic-dc-01-nic' }
            Should -Invoke New-AzVM -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-iic-mgmt-01' -and $Location -eq 'westeurope' }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVmHome }
        }

        It 'sets up a Linux machine for ubuntu_2404 and uses the VM name as the computer name when there is no hostname' {
            $m = New-Machine 'vm-iic-syslog-01' @{ role = 'syslog'; os = 'ubuntu_2404'; hostname = $null; private_ip = '192.0.2.20' }
            $null = Invoke-Vms (New-InfraFile @($m))
            Should -Invoke Set-AzVMOperatingSystem -Times 1 -Exactly -ParameterFilter { $Linux -and -not $Windows -and $ComputerName -eq 'vm-iic-syslog-01' }
            Should -Invoke Set-AzVMSourceImage -Times 1 -Exactly -ParameterFilter { $PublisherName -eq 'Canonical' -and $Offer -eq 'ubuntu-24_04-lts' -and $Skus -eq 'server' }
        }

        It 'uses the resource group of the entry, puts the file-level tags on the interface and the machine, and reuses an interface that is there' {
            Mock Get-AzNetworkInterface { [pscustomobject]@{ Name = $Name; Id = "/nic/$Name" } }
            $null = Invoke-Vms (New-InfraFile @((New-Machine 'vm-iic-dc-01' @{ resource_group = 'rg-iic-vm-01' })) -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzNetworkInterface -Times 0 -Exactly
            Should -Invoke New-AzVM -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-iic-vm-01' -and $Tag['environment'] -eq 'lab' }
        }

        It 'creates every machine of the list, skips one that is not for Azure, and never prints or returns the password' {
            $local = New-Machine 'vm-iic-local-01' @{ deploy_target = 'azure_local'; private_ip = '192.0.2.30' }
            $r = Invoke-Vms (New-InfraFile @((New-Machine), (New-Machine 'vm-iic-dc-02' @{ hostname = 'iic-dc02'; private_ip = '192.0.2.11' }), $local))
            @($r.Rows.Action) | Should -Be @('Created', 'Created', 'Skipped') -Because $r.Text
            Should -Invoke New-AzVM -Times 2 -Exactly
            $r.Everything | Should -Not -Match ([regex]::Escape($global:AzlVmCanary))
        }

        It 'creates only network interfaces and machines and never removes or changes one' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-Az|Update-Az|Stop-AzVM|Restart-AzVM|Set-AzVM(?!OperatingSystem|SourceImage|OSDisk)'
        }
    }

    Context 'a machine exists already (idempotent)' {
        It 'creates nothing and says so, and reports another size' {
            Mock Get-AzVM { [pscustomobject]@{ Name = $Name; HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D4s_v5' } } }
            $r = Invoke-Vms (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Detail | Should -Match 'size is Standard_D4s_v5'
            Should -Invoke New-AzVM -Times 0 -Exactly
            Should -Invoke New-AzNetworkInterface -Times 0 -Exactly
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans the machine, creates nothing and does not read the password' {
            $env:AZL_TEST_VM_PASSWORD = $null
            try { $r = Invoke-Vms (New-InfraFile) -DryRun }
            finally { $env:AZL_TEST_VM_PASSWORD = $global:AzlVmCanary }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzVM -Times 0 -Exactly
            Should -Invoke New-AzNetworkInterface -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the file lists no machine, or none for Azure' {
            (Invoke-Vms (New-InfraFile @())).Text | Should -Match 'nothing to do'
            $r = Invoke-Vms (New-InfraFile @((New-Machine 'vm-iic-local-01' @{ deploy_target = 'onprem' })))
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.tenant_id' {
            (Invoke-Vms (New-InfraFile -Azure @{ tenant_id = $null })).ExitCode | Should -Be 2
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a machine with no name'; Override = @{ name = $null } }
            @{ Why = 'no network'; Override = @{ network = $null } }
            @{ Why = 'a network that is not in landing_zone.networks'; Override = @{ network = 'vnet-other' } }
            @{ Why = 'no subnet'; Override = @{ subnet = $null } }
            @{ Why = 'no static address'; Override = @{ private_ip = $null } }
            @{ Why = 'an address that is not IPv4'; Override = @{ private_ip = 'dc01' } }
            @{ Why = 'no size'; Override = @{ size = $null } }
            @{ Why = 'an operating system that is not one of the three'; Override = @{ os = 'windows_xp' } }
            @{ Why = 'no administrator name'; Override = @{ admin_username = $null } }
            @{ Why = 'no password'; Override = @{ admin_password = $null } }
            @{ Why = 'a password that is not a secret reference'; Override = @{ admin_password = 'P@ssw0rd-in-the-file' } }
            @{ Why = 'a Windows computer name of more than 15 characters'; Override = @{ hostname = 'iic-dc01-too-long-name' } }
            @{ Why = 'a subscription other than the one of the network'; Override = @{ subscription = 'sub-other' } }
        ) {
            $r = Invoke-Vms (New-InfraFile @((New-Machine 'vm-iic-dc-01' $Override)))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzVM -Times 0 -Exactly
        }

        It 'refuses the same machine twice' {
            (Invoke-Vms (New-InfraFile @((New-Machine), (New-Machine 'VM-IIC-DC-01')))).ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Vms (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Vms (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzVM -Times 0 -Exactly
        }

        It 'reports a missing network or subnet and creates nothing for that machine' {
            Mock Get-AzVirtualNetwork { throw "The Resource 'Microsoft.Network/virtualNetworks/x' was not found (404 NotFound)." }
            $r = Invoke-Vms (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'Deploy-VirtualNetworks'
            Mock Get-AzVirtualNetwork { [pscustomobject]@{ Name = $Name; Id = "/vnet/$Name" } }
            Mock Get-AzVirtualNetworkSubnetConfig { $null }
            $r = Invoke-Vms (New-InfraFile)
            $r.Rows[0].Detail | Should -Match 'no subnet named'
            Should -Invoke New-AzVM -Times 0 -Exactly
            Should -Invoke New-AzNetworkInterface -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzVM { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Vms (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            Should -Invoke New-AzVM -Times 0 -Exactly
        }

        It 'reports a password that cannot be read, creates no machine for it, and goes on with the next one' {
            $bad = New-Machine 'vm-iic-dc-02' @{ hostname = 'iic-dc02'; private_ip = '192.0.2.11'; admin_password = 'env://AZL_TEST_VM_PASSWORD_MISSING' }
            $r = Invoke-Vms (New-InfraFile @($bad, (New-Machine)))
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed', 'Created')
            Should -Invoke New-AzVM -Times 1 -Exactly
        }

        It 'reports a failed creation, goes on, puts the subscription back, and exits 1' {
            Mock New-AzVM { throw 'AuthorizationFailed' }
            $r = Invoke-Vms (New-InfraFile @((New-Machine), (New-Machine 'vm-iic-dc-02' @{ hostname = 'iic-dc02'; private_ip = '192.0.2.11' })))
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed', 'Failed')
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlVmHome }
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

        It 'reads its values through the toolkit loader, never the old layout, and holds no GUID or address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml|management_vms|vnet_name|management_subnet_name|\$azure\.prefix'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Deploy_ManagementVMs_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.location', 'tags', 'landing_zone.virtual_machines[].name', 'landing_zone.virtual_machines[].hostname', 'landing_zone.virtual_machines[].deploy_target', 'landing_zone.virtual_machines[].subscription', 'landing_zone.virtual_machines[].resource_group', 'landing_zone.virtual_machines[].network', 'landing_zone.virtual_machines[].subnet', 'landing_zone.virtual_machines[].private_ip', 'landing_zone.virtual_machines[].size', 'landing_zone.virtual_machines[].os', 'landing_zone.virtual_machines[].admin_username', 'landing_zone.virtual_machines[].admin_password', 'landing_zone.networks[].name', 'landing_zone.networks[].subscription', 'landing_zone.networks[].resource_group', 'landing_zone.networks[].location', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
