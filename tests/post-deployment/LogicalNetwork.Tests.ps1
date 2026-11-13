#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 08: New-LogicalNetwork.ps1 creates the Arc VM logical networks of networking.logical_networks. The Azure CLI (az) and
# Invoke-Command are replaced by fakes: no Azure, no cluster, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/LogicalNetwork.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and cluster and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-08-logical-network-creation', 'powershell', 'New-LogicalNetwork.ps1')
    Import-Module powershell-yaml

    function az { }

    $global:AzlLnTenant = [guid]::NewGuid().ToString()
    $global:AzlLnSub = [guid]::NewGuid().ToString()

    function New-Lnet([hashtable]$Override = @{}) {
        $n = [ordered]@{ name = 'lnet-workloads'; vlan_id = 2204; address_prefix = '203.0.113.0/24'; gateway = '203.0.113.1'; dns_servers = @('192.0.2.4', '192.0.2.5'); ip_pool = [ordered]@{ start = '203.0.113.100'; end = '203.0.113.200' } }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $n.Remove($k) } else { $n[$k] = $Override[$k] } }
        $n
    }
    function New-InfraFile {
        param([object[]]$Networks = @((New-Lnet)), [object[]]$Groups = @(), [object]$Sdn = $null, [hashtable]$Azure = @{}, [object]$Tags = $null, [string]$Cluster = 'azl-cluster-01')
        $az = [ordered]@{ tenant_id = $global:AzlLnTenant; subscription_id = $global:AzlLnSub; resource_group = 'rg-azl-01'; location = 'eastus'; custom_location = 'cl-azl-01' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{ azure = $az; cluster = [ordered]@{}; networking = [ordered]@{} }
        if ($Cluster) { $doc.cluster.name = $Cluster }
        if ($Networks) { $doc.networking.logical_networks = @($Networks) }
        if ($Groups) { $doc.networking.network_security_groups = @($Groups) }
        if ($null -ne $Sdn) { $doc.sdn = [ordered]@{ enabled = $Sdn } }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Group([string]$Name = 'nsg-workloads') { [ordered]@{ name = $Name; rules = @([ordered]@{ name = 'allow-https-in'; priority = 100; direction = 'Inbound'; access = 'Allow'; destination_port_ranges = @('443') }) } }
    function Reset-World {
        $global:AzlLnCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlLnRemote = [System.Collections.Generic.List[object]]::new()
        $global:AzlLnState = @{
            Lnets = @{}; Groups = @{}; Rules = @{}; TenantId = $global:AzlLnTenant; SignedIn = $true; Extension = $true; Fail = @{}
            Switches = @('ConvergedSwitch(management_compute_storage)'); ClusterError = ''
        }
    }
    function Invoke-Lnet([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Command) { @($global:AzlLnCalls | Where-Object Command -EQ $Command) }
}

Describe 'New-LogicalNetwork.ps1' {
    AfterAll { Remove-Variable -Name AzlLnTenant, AzlLnSub, AzlLnCalls, AzlLnRemote, AzlLnState -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-World
        Mock Invoke-Command {
            $global:AzlLnRemote.Add([pscustomobject]@{ Computer = [string]$ComputerName; Credential = $Credential; Script = $ScriptBlock.ToString() })
            if ($global:AzlLnState.ClusterError) { throw $global:AzlLnState.ClusterError }
            $global:AzlLnState.Switches
        }
        Mock az {
            $a = @($args | ForEach-Object { [string]$_ })
            $words = @(); foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
            $options = @{}; $current = ''
            foreach ($x in $a[$words.Count..($a.Count - 1)]) {
                if ($x.StartsWith('--')) { $current = $x; $options[$current] = @() } elseif ($current) { $options[$current] += $x }
            }
            $command = $words -join ' '
            $global:AzlLnCalls.Add([pscustomobject]@{ Command = $command; Arguments = $a; Options = $options })
            $state = $global:AzlLnState
            $fail = { param($code, $message) $global:LASTEXITCODE = $code; [Management.Automation.ErrorRecord]::new([Exception]::new($message), 'az', 'NotSpecified', $null) }
            $global:LASTEXITCODE = 0
            if ($state.Fail.ContainsKey($command)) { return (& $fail 1 $state.Fail[$command]) }
            switch ($command) {
                'account show' { if (-not $state.SignedIn) { return (& $fail 1 'Please run az login to setup account.') }; return ('{"tenantId":"' + $state.TenantId + '"}') }
                'extension show' { if (-not $state.Extension) { return (& $fail 1 'The extension stack-hci-vm is not installed.') }; return '{"name":"stack-hci-vm"}' }
                'stack-hci-vm network lnet show' {
                    $name = $options['--name'][0]
                    if (-not $state.Lnets.ContainsKey($name)) { return (& $fail 3 "(ResourceNotFound) The Resource 'Microsoft.AzureStackHCI/logicalNetworks/$name' was not found.") }
                    return (ConvertTo-Json -InputObject $state.Lnets[$name] -Depth 8)
                }
                'stack-hci-vm network lnet create' {
                    $state.Lnets[$options['--name'][0]] = [pscustomobject]@{ name = $options['--name'][0]; properties = [pscustomobject]@{ vmSwitchName = $options['--vm-switch-name'][0]; subnets = @([pscustomobject]@{ properties = [pscustomobject]@{ ipAllocationMethod = $options['--ip-allocation-method'][0] } }) } }
                    return
                }
                'stack-hci-vm network nsg show' {
                    $name = $options['--name'][0]
                    if (-not $state.Groups.ContainsKey($name)) { return (& $fail 3 "(ResourceNotFound) The Resource 'Microsoft.AzureStackHCI/networkSecurityGroups/$name' was not found.") }
                    return ('{"name":"' + $name + '"}')
                }
                'stack-hci-vm network nsg rule list' {
                    $name = $options['--nsg-name'][0]
                    $list = @(if ($state.Rules.ContainsKey($name)) { $state.Rules[$name] })
                    if ($list.Count -eq 0) { return '[]' }
                    return (ConvertTo-Json -InputObject $list -Depth 6)
                }
                default { return (& $fail 2 "unexpected az call: $command") }
            }
        }
    }

    Context 'creating a static logical network' {
        It 'creates it with the values of the file, on the switch the cluster reports' {
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            $c = (Get-Call 'stack-hci-vm network lnet create')[0]
            $c.Options['--name'] | Should -Be 'lnet-workloads'
            $c.Options['--resource-group'] | Should -Be 'rg-azl-01'
            $c.Options['--subscription'] | Should -Be $global:AzlLnSub
            $c.Options['--location'] | Should -Be 'eastus'
            $c.Options['--custom-location'] | Should -Be "/subscriptions/$($global:AzlLnSub)/resourceGroups/rg-azl-01/providers/Microsoft.ExtendedLocation/customLocations/cl-azl-01"
            $c.Options['--vm-switch-name'] | Should -Be 'ConvergedSwitch(management_compute_storage)'
            $c.Options['--ip-allocation-method'] | Should -Be 'Static'
            $c.Options['--vlan'] | Should -Be '2204'
            $c.Options['--address-prefixes'] | Should -Be '203.0.113.0/24'
            $c.Options['--gateway'] | Should -Be '203.0.113.1'
            @($c.Options['--dns-servers']) | Should -Be @('192.0.2.4', '192.0.2.5')
            $c.Options['--ip-pool-start'] | Should -Be '203.0.113.100'
            $c.Options['--ip-pool-end'] | Should -Be '203.0.113.200'
            $c.Options.ContainsKey('--network-security-group') | Should -BeFalse
            $c.Options.ContainsKey('--ip-pool-type') | Should -BeFalse
            $c.Options.ContainsKey('--no-gateway') | Should -BeFalse
        }

        It 'reads the gateway key called gateway (not default_gateway) and the pool key called ip_pool' {
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ gateway = $null; default_gateway = '203.0.113.1' }))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'gateway'
            Should -Invoke az -Times 0 -Exactly
        }

        It 'puts the file-level tags on the logical network, and sends none when the file has none' {
            $null = Invoke-Lnet (New-InfraFile -Tags ([ordered]@{ environment = 'lab' }))
            @((Get-Call 'stack-hci-vm network lnet create')[0].Options['--tags']) | Should -Be @('environment=lab')
            Reset-World
            $null = Invoke-Lnet (New-InfraFile)
            (Get-Call 'stack-hci-vm network lnet create')[0].Options.ContainsKey('--tags') | Should -BeFalse
        }

        It 'passes the VLAN 0 for an untagged network' {
            $null = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ vlan_id = 0 }))
            (Get-Call 'stack-hci-vm network lnet create')[0].Options['--vlan'] | Should -Be '0'
        }

        It 'creates every network of the list, reading the cluster once' {
            $networks = (New-Lnet @{ name = 'lnet-a' }), (New-Lnet @{ name = 'lnet-b'; vlan_id = 2205; address_prefix = '198.51.100.0/24'; gateway = '198.51.100.1'; ip_pool = [ordered]@{ start = '198.51.100.10'; end = '198.51.100.20' } })
            $r = Invoke-Lnet (New-InfraFile -Networks $networks)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('Created', 'Created')
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 2
            $global:AzlLnRemote.Count | Should -Be 1
        }

        It 'carries the subscription on every call and never installs, updates, deletes or changes defaults' {
            $null = Invoke-Lnet (New-InfraFile)
            foreach ($call in @($global:AzlLnCalls | Where-Object { $_.Command -like 'stack-hci-vm *' })) { $call.Options['--subscription'] | Should -Be $global:AzlLnSub -Because $call.Command }
            @($global:AzlLnCalls.Command | Where-Object { $_ -match 'extension (add|update)|delete|update|login|account set' }) | Should -BeNullOrEmpty
        }
    }

    Context 'a dynamic logical network and a disabled one' {
        It 'creates a Dynamic network with no address, gateway, DNS or pool arguments, and warns about the unused keys' {
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ name = 'lnet-dhcp'; ip_allocation_method = 'Dynamic'; vlan_id = $null; address_prefix = $null; dns_servers = $null; ip_pool = $null }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $c = (Get-Call 'stack-hci-vm network lnet create')[0]
            $c.Options['--ip-allocation-method'] | Should -Be 'Dynamic'
            foreach ($option in '--address-prefixes', '--gateway', '--dns-servers', '--ip-pool-start', '--ip-pool-end', '--vlan') { $c.Options.ContainsKey($option) | Should -BeFalse -Because $option }
            $r.Text | Should -Match 'gateway is not used'
        }

        It 'sends the VLAN of a Dynamic network when the file gives one' {
            $null = Invoke-Lnet (New-InfraFile -Networks ([ordered]@{ name = 'lnet-dhcp'; ip_allocation_method = 'dynamic'; vlan_id = 300 }))
            (Get-Call 'stack-hci-vm network lnet create')[0].Options['--vlan'] | Should -Be '300'
        }

        It 'skips a network with enabled false and does not validate it or look it up' {
            $r = Invoke-Lnet (New-InfraFile -Networks ([ordered]@{ name = 'lnet-off'; enabled = $false; address_prefix = 'not a prefix' }), (New-Lnet))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('Skipped', 'Created')
            @((Get-Call 'stack-hci-vm network lnet show') | ForEach-Object { $_.Options['--name'][0] }) | Should -Be @('lnet-workloads')
        }

        It 'does not read the cluster when every network is disabled or already exists' {
            $global:AzlLnState.Lnets['lnet-workloads'] = [pscustomobject]@{ name = 'lnet-workloads'; properties = [pscustomobject]@{ vmSwitchName = 'x'; subnets = @([pscustomobject]@{ properties = [pscustomobject]@{ addressPrefix = '203.0.113.0/24'; ipAllocationMethod = 'Static' } }) } }
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $global:AzlLnRemote.Count | Should -Be 0
        }
    }

    Context 'the virtual switch' {
        It 'asks the cluster for its external virtual switches with Get-VMSwitch -SwitchType External, on cluster.name' {
            $null = Invoke-Lnet (New-InfraFile)
            $global:AzlLnRemote[0].Computer | Should -Be 'azl-cluster-01'
            $global:AzlLnRemote[0].Script | Should -Match 'Get-VMSwitch -SwitchType External'
        }

        It 'asks -ComputerName instead, with -Credential when given' {
            $cred = [pscredential]::new('user', (ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force))
            $null = Invoke-Lnet (New-InfraFile) -Extra @{ ComputerName = 'node03'; Credential = $cred }
            $global:AzlLnRemote[0].Computer | Should -Be 'node03'
            $global:AzlLnRemote[0].Credential.UserName | Should -Be 'user'
        }

        It 'uses the name the cluster reports, exactly, with parentheses' {
            $global:AzlLnState.Switches = @('ConvergedSwitch(mgmt_compute)')
            $null = Invoke-Lnet (New-InfraFile)
            (Get-Call 'stack-hci-vm network lnet create')[0].Options['--vm-switch-name'] | Should -Be 'ConvergedSwitch(mgmt_compute)'
        }

        It 'does not guess when the cluster has several external switches: it fails the network and creates nothing' {
            $global:AzlLnState.Switches = @('ConvergedSwitch(a)', 'ConvergedSwitch(b)')
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'vm_switch_name'
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'uses the switch the file names when the cluster has several' {
            $global:AzlLnState.Switches = @('ConvergedSwitch(a)', 'ConvergedSwitch(b)')
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ vm_switch_name = 'ConvergedSwitch(b)' }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'stack-hci-vm network lnet create')[0].Options['--vm-switch-name'] | Should -Be 'ConvergedSwitch(b)'
        }

        It 'fails a network whose vm_switch_name the cluster does not report' {
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ vm_switch_name = 'ConvergedSwitch(other)' }))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'is not an external virtual switch'
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'fails when the cluster reports no external switch, or cannot be read' {
            $global:AzlLnState.Switches = @()
            (Invoke-Lnet (New-InfraFile)).ExitCode | Should -Be 1
            Reset-World
            $global:AzlLnState.ClusterError = 'WinRM cannot process the request.'
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'could not be read'
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'builds no switch name from an intent' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'ConvergedSwitch|intents'
        }
    }

    Context 'the network security group' {
        It 'ties the group to the network at creation when nsg_name is set, SDN is on and the group has a rule' {
            $global:AzlLnState.Groups['nsg-workloads'] = $true
            $global:AzlLnState.Rules['nsg-workloads'] = @([pscustomobject]@{ name = 'allow-https-in'; properties = [pscustomobject]@{ priority = 100 } })
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ nsg_name = 'nsg-workloads' }) -Groups (New-Group) -Sdn $true)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            (Get-Call 'stack-hci-vm network lnet create')[0].Options['--network-security-group'] | Should -Be 'nsg-workloads'
        }

        It 'refuses (exit 2) a nsg_name that is not in networking.network_security_groups, and says the group comes first' {
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ nsg_name = 'nsg-workloads' }) -Sdn $true)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'networking.network_security_groups'
            $r.Text | Should -Match 'New-NetworkSecurityGroup'
            Should -Invoke az -Times 0 -Exactly
        }

        It 'refuses (exit 2) a nsg_name while SDN is <Why>' -ForEach @(@{ Why = 'off'; Sdn = $false }, @{ Why = 'not in the file'; Sdn = $null }) {
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ nsg_name = 'nsg-workloads' }) -Groups (New-Group) -Sdn $Sdn)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'sdn.enabled'
            Should -Invoke az -Times 0 -Exactly
        }

        It 'does not check a group of a disabled network' {
            $r = Invoke-Lnet (New-InfraFile -Networks ([ordered]@{ name = 'lnet-off'; enabled = $false; nsg_name = 'nsg-missing' }), (New-Lnet))
            $r.ExitCode | Should -Be 0 -Because $r.Text
        }

        It 'fails the network when the group does not exist in Azure yet' {
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ nsg_name = 'nsg-workloads' }) -Groups (New-Group) -Sdn $true)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'does not exist'
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'fails the network when the group has no rule (an empty group blocks all inbound traffic)' {
            $global:AzlLnState.Groups['nsg-workloads'] = $true
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ nsg_name = 'nsg-workloads' }) -Groups (New-Group) -Sdn $true)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'has no rule'
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'does not tie a group to a network that exists' {
            $global:AzlLnState.Lnets['lnet-workloads'] = [pscustomobject]@{ name = 'lnet-workloads'; properties = [pscustomobject]@{ vmSwitchName = 'x'; subnets = @([pscustomobject]@{ properties = [pscustomobject]@{ addressPrefix = '203.0.113.0/24'; ipAllocationMethod = 'Static' } }) } }
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ nsg_name = 'nsg-workloads' }) -Groups (New-Group) -Sdn $true)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            @($global:AzlLnCalls.Command | Where-Object { $_ -match 'update|create' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the logical network already exists (idempotent)' {
        It 'creates nothing and says so' {
            $global:AzlLnState.Lnets['lnet-workloads'] = [pscustomobject]@{ name = 'lnet-workloads'; properties = [pscustomobject]@{ vmSwitchName = 'ConvergedSwitch(x)'; subnets = @([pscustomobject]@{ properties = [pscustomobject]@{ addressPrefix = '203.0.113.0/24'; ipAllocationMethod = 'Static' } }) } }
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Detail | Should -BeNullOrEmpty
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'reports a network that differs from the file, and changes nothing' {
            $global:AzlLnState.Lnets['lnet-workloads'] = [pscustomobject]@{ name = 'lnet-workloads'; properties = [pscustomobject]@{ vmSwitchName = 'ConvergedSwitch(x)'; subnets = @([pscustomobject]@{ properties = [pscustomobject]@{ addressPrefix = '198.51.100.0/24'; ipAllocationMethod = 'Static' } }) } }
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Detail | Should -Match 'address prefix is 198.51.100.0/24'
            $r.Rows[0].Detail | Should -Match 'cannot be changed'
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'never deletes or updates a logical network' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match "'(delete|update)'"
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'reads Azure and the cluster, plans the network with its switch, and creates nothing' {
            $r = Invoke-Lnet (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            $r.Rows[0].Detail | Should -Match 'ConvergedSwitch\(management_compute_storage\)'
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'does nothing and does not call Azure when the file lists no logical network' {
            $r = Invoke-Lnet (New-InfraFile -Networks @())
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke az -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure or the cluster)' {
        It 'refuses a missing azure.<Key>' -ForEach @(@{ Key = 'tenant_id' }, @{ Key = 'subscription_id' }, @{ Key = 'resource_group' }, @{ Key = 'location' }, @{ Key = 'custom_location' }) {
            $r = Invoke-Lnet (New-InfraFile -Azure @{ $Key = $null })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match "azure.$Key"
            Should -Invoke az -Times 0 -Exactly
        }

        It 'refuses a missing cluster.name when a network is listed, unless -ComputerName is given' {
            (Invoke-Lnet (New-InfraFile -Cluster '')).ExitCode | Should -Be 2
            Should -Invoke az -Times 0 -Exactly
            (Invoke-Lnet (New-InfraFile -Cluster '') -Extra @{ ComputerName = 'node01' }).ExitCode | Should -Be 0
        }

        It 'refuses a static network with <Why>' -ForEach @(
            @{ Why = 'no address_prefix'; Net = @{ address_prefix = $null } }
            @{ Why = 'an address_prefix that is not CIDR'; Net = @{ address_prefix = '203.0.113.0' } }
            @{ Why = 'no gateway'; Net = @{ gateway = $null } }
            @{ Why = 'a gateway outside the prefix'; Net = @{ gateway = '198.51.100.1' } }
            @{ Why = 'no dns_servers'; Net = @{ dns_servers = $null } }
            @{ Why = 'a DNS server that is not an address'; Net = @{ dns_servers = @('dns01') } }
            @{ Why = 'no vlan_id'; Net = @{ vlan_id = $null } }
            @{ Why = 'vlan_id 4095'; Net = @{ vlan_id = 4095 } }
            @{ Why = 'a negative vlan_id'; Net = @{ vlan_id = -1 } }
            @{ Why = 'no ip_pool'; Net = @{ ip_pool = $null } }
            @{ Why = 'a pool start outside the prefix'; Net = @{ ip_pool = [ordered]@{ start = '198.51.100.10'; end = '203.0.113.200' } } }
            @{ Why = 'a pool end outside the prefix'; Net = @{ ip_pool = [ordered]@{ start = '203.0.113.10'; end = '203.0.114.1' } } }
            @{ Why = 'a pool that ends before it starts'; Net = @{ ip_pool = [ordered]@{ start = '203.0.113.200'; end = '203.0.113.100' } } }
            @{ Why = 'a pool without an end'; Net = @{ ip_pool = [ordered]@{ start = '203.0.113.200' } } }
            @{ Why = 'an ip_allocation_method of Manual'; Net = @{ ip_allocation_method = 'Manual' } }
            @{ Why = 'a name that starts with a hyphen'; Net = @{ name = '-bad' } }
            @{ Why = 'a name with a space'; Net = @{ name = 'lnet one' } }
            @{ Why = 'enabled as text'; Net = @{ enabled = 'sometimes' } }
            @{ Why = 'a vm_switch_name with an ampersand'; Net = @{ vm_switch_name = 'a&b' } }
        ) {
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet $Net))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke az -Times 0 -Exactly
            $global:AzlLnRemote.Count | Should -Be 0
        }

        It 'refuses two networks with the same name' {
            (Invoke-Lnet (New-InfraFile -Networks (New-Lnet), (New-Lnet @{ name = 'LNET-WORKLOADS' }))).ExitCode | Should -Be 2
        }

        It 'refuses overlapping IP pools on the same VLAN, and accepts them on different VLANs' {
            $other = New-Lnet @{ name = 'lnet-b'; ip_pool = [ordered]@{ start = '203.0.113.150'; end = '203.0.113.220' } }
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet), $other)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'overlap'
            Should -Invoke az -Times 0 -Exactly
            $elsewhere = New-Lnet @{ name = 'lnet-b'; vlan_id = 2300; ip_pool = [ordered]@{ start = '203.0.113.150'; end = '203.0.113.220' } }
            (Invoke-Lnet (New-InfraFile -Networks (New-Lnet), $elsewhere)).ExitCode | Should -Be 0
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when the Azure CLI is not signed in' {
            $global:AzlLnState.SignedIn = $false
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'az login'
            $global:AzlLnRemote.Count | Should -Be 0
        }

        It 'stops when the sign-in is to another tenant' {
            $global:AzlLnState.TenantId = [guid]::NewGuid().ToString()
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'stops with a clear message when the stack-hci-vm extension is missing, and does not install it' {
            $global:AzlLnState.Extension = $false
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'stack-hci-vm is not installed'
            $r.Text | Should -Match 'does not install it'
            @($global:AzlLnCalls.Command) | Should -Not -Contain 'extension add'
            @(Get-Call 'stack-hci-vm network lnet show').Count | Should -Be 0
        }

        It 'does not update the extension on a normal run' {
            $null = Invoke-Lnet (New-InfraFile)
            @($global:AzlLnCalls.Command | Where-Object { $_ -like 'extension*' }) | Should -Be @('extension show')
        }

        It 'does not hide a lookup error that is not a not-found' {
            $global:AzlLnState.Fail['stack-hci-vm network lnet show'] = 'AuthorizationFailed: the client does not have authorization.'
            $r = Invoke-Lnet (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 0
        }

        It 'reports a failed creation, goes on with the next network, and exits 1' {
            $global:AzlLnState.Fail['stack-hci-vm network lnet create'] = 'InvalidAddressPrefix'
            $r = Invoke-Lnet (New-InfraFile -Networks (New-Lnet @{ name = 'lnet-a' }), (New-Lnet @{ name = 'lnet-b'; vlan_id = 2205 }))
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed', 'Failed')
            @(Get-Call 'stack-hci-vm network lnet create').Count | Should -Be 2
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

        It 'reads its values through the toolkit loader and calls the Azure CLI only through one function, with an argument array' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml|default_gateway|ip_pools|-AssociateNsg|compute\.azure_local'
            $script:Text | Should -Not -Match 'Invoke-Expression|Start-Process|cmd(\.exe)? /c|iex '
            ([regex]::Matches($script:Text, '&\s+az\s+@')).Count | Should -Be 1
            $script:Text | Should -Not -Match '(?m)^\s*az\s+(stack-hci-vm|account|extension)'
        }

        It 'holds no GUID, no address and no Key Vault name, and fixes no allocation method or pool type outside the registry default' {
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
            $script:Text | Should -Not -Match '(?i)kv-|keyvault://|Get-AzKeyVault|ip-pool-type|--no-gateway'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_LogicalNetwork_ps1' })
            $names = @($own | ForEach-Object { $_.Node['name'] })
            foreach ($parameter in 'InfrastructureFile', 'ComputerName', 'Credential', 'LogPath') { $names | Should -Contain $parameter }
        }

        It 'reads only registry keys that exist: <_>' -ForEach @(
            'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'azure.location', 'azure.custom_location', 'cluster.name', 'sdn.enabled'
            'networking.network_security_groups[].name'
            'networking.logical_networks[].name', 'networking.logical_networks[].enabled', 'networking.logical_networks[].ip_allocation_method', 'networking.logical_networks[].vlan_id'
            'networking.logical_networks[].address_prefix', 'networking.logical_networks[].gateway', 'networking.logical_networks[].dns_servers'
            'networking.logical_networks[].ip_pool.start', 'networking.logical_networks[].ip_pool.end', 'networking.logical_networks[].nsg_name', 'networking.logical_networks[].vm_switch_name'
        ) {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
