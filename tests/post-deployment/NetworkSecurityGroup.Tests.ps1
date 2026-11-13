#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 07: New-NetworkSecurityGroup.ps1 creates the network security groups and rules of networking.network_security_groups.
# The Azure CLI (az) is replaced by a fake: no Azure, no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/NetworkSecurityGroup.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-07-configure-nsgs', 'powershell', 'New-NetworkSecurityGroup.ps1')
    Import-Module powershell-yaml

    # A stub with the name of the command, so the mock works whether or not the Azure CLI is installed.
    function az { }

    $global:AzlNsgTenant = [guid]::NewGuid().ToString()
    $global:AzlNsgSub = [guid]::NewGuid().ToString()

    function New-Rule([hashtable]$Override = @{}) {
        $r = [ordered]@{ name = 'allow-https-in'; priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; source_address_prefixes = @('192.0.2.0/24', '198.51.100.7'); destination_port_ranges = @('443', '8000-8100'); description = 'Allow HTTPS from the workload network' }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $r.Remove($k) } else { $r[$k] = $Override[$k] } }
        $r
    }
    function New-Group([hashtable]$Override = @{}) {
        $g = [ordered]@{ name = 'nsg-workloads'; rules = @((New-Rule)) }
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $g.Remove($k) } else { $g[$k] = $Override[$k] } }
        $g
    }
    function New-InfraFile {
        param([object[]]$Groups = @((New-Group)), [object]$Sdn = $true, [hashtable]$Azure = @{}, [object]$Tags = $null)
        $az = [ordered]@{ tenant_id = $global:AzlNsgTenant; subscription_id = $global:AzlNsgSub; resource_group = 'rg-azl-01'; location = 'eastus'; custom_location = 'cl-azl-01' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{ azure = $az; networking = [ordered]@{} }
        if ($Groups) { $doc.networking.network_security_groups = @($Groups) }
        if ($null -ne $Sdn) { $doc.sdn = [ordered]@{ enabled = $Sdn } }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-Azure {
        $global:AzlNsgCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlNsgState = @{ Groups = @{}; Rules = @{}; TenantId = $global:AzlNsgTenant; SignedIn = $true; Extension = $true; Fail = @{} }
    }
    function Add-ExistingRule([string]$Group, [hashtable]$Properties, [string]$Name = 'allow-https-in') {
        if (-not $global:AzlNsgState.Rules.ContainsKey($Group)) { $global:AzlNsgState.Rules[$Group] = @() }
        $global:AzlNsgState.Rules[$Group] += [pscustomobject]@{ name = $Name; properties = [pscustomobject]$Properties }
    }
    function Invoke-Nsg([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Item'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Command) { @($global:AzlNsgCalls | Where-Object Command -EQ $Command) }
    # The values after an option of a recorded call, for example Get-Option $call '--source-port-ranges'.
    function Get-Option($Call, [string]$Name) { $Call.Options[$Name] }
}

Describe 'New-NetworkSecurityGroup.ps1' {
    AfterAll { Remove-Variable -Name AzlNsgTenant, AzlNsgSub, AzlNsgCalls, AzlNsgState -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-Azure
        Mock az {
            $a = @($args | ForEach-Object { [string]$_ })
            $words = @(); foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
            $options = @{}; $current = ''
            foreach ($x in $a[$words.Count..($a.Count - 1)]) {
                if ($x.StartsWith('--')) { $current = $x; $options[$current] = @() } elseif ($current) { $options[$current] += $x }
            }
            $command = $words -join ' '
            $global:AzlNsgCalls.Add([pscustomobject]@{ Command = $command; Arguments = $a; Options = $options })
            $state = $global:AzlNsgState
            $fail = { param($code, $message) $global:LASTEXITCODE = $code; [Management.Automation.ErrorRecord]::new([Exception]::new($message), 'az', 'NotSpecified', $null) }
            $global:LASTEXITCODE = 0
            if ($state.Fail.ContainsKey($command)) { return (& $fail 1 $state.Fail[$command]) }
            switch ($command) {
                'account show' { if (-not $state.SignedIn) { return (& $fail 1 'Please run az login to setup account.') }; return ('{"tenantId":"' + $state.TenantId + '","id":"' + $options['--subscription'][0] + '"}') }
                'extension show' { if (-not $state.Extension) { return (& $fail 1 'The extension stack-hci-vm is not installed.') }; return '{"name":"stack-hci-vm"}' }
                'stack-hci-vm network nsg show' {
                    $name = $options['--name'][0]
                    if (-not $state.Groups.ContainsKey($name)) { return (& $fail 3 "(ResourceNotFound) The Resource 'Microsoft.AzureStackHCI/networkSecurityGroups/$name' under resource group was not found.") }
                    return ('{"name":"' + $name + '"}')
                }
                'stack-hci-vm network nsg create' { $state.Groups[$options['--name'][0]] = $true; return }
                'stack-hci-vm network nsg rule list' {
                    $name = $options['--nsg-name'][0]
                    $list = @(if ($state.Rules.ContainsKey($name)) { $state.Rules[$name] })
                    if ($list.Count -eq 0) { return '[]' }
                    return (ConvertTo-Json -InputObject $list -Depth 6)
                }
                'stack-hci-vm network nsg rule create' {
                    $name = $options['--nsg-name'][0]
                    if (-not $state.Rules.ContainsKey($name)) { $state.Rules[$name] = @() }
                    $state.Rules[$name] += [pscustomobject]@{ name = $options['--name'][0]; properties = [pscustomobject]@{ priority = [int]$options['--priority'][0] } }
                    return
                }
                default { return (& $fail 2 "unexpected az call: $command") }
            }
        }
    }

    Context 'creating a group and its rules' {
        It 'creates the group in the resource group, region and custom location, then the rule with the values of the file' {
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('Created', 'Created')
            $create = (Get-Call 'stack-hci-vm network nsg create')[0]
            $create.Options['--name'] | Should -Be 'nsg-workloads'
            $create.Options['--resource-group'] | Should -Be 'rg-azl-01'
            $create.Options['--subscription'] | Should -Be $global:AzlNsgSub
            $create.Options['--location'] | Should -Be 'eastus'
            $create.Options['--custom-location'] | Should -Be "/subscriptions/$($global:AzlNsgSub)/resourceGroups/rg-azl-01/providers/Microsoft.ExtendedLocation/customLocations/cl-azl-01"

            $rule = (Get-Call 'stack-hci-vm network nsg rule create')[0]
            $rule.Options['--nsg-name'] | Should -Be 'nsg-workloads'
            $rule.Options['--name'] | Should -Be 'allow-https-in'
            $rule.Options['--priority'] | Should -Be '100'
            $rule.Options['--direction'] | Should -Be 'Inbound'
            $rule.Options['--access'] | Should -Be 'Allow'
            $rule.Options['--protocol'] | Should -Be 'Tcp'
            @($rule.Options['--source-address-prefixes']) | Should -Be @('192.0.2.0/24', '198.51.100.7')
            @($rule.Options['--destination-port-ranges']) | Should -Be @('443', '8000-8100')
            $rule.Options['--description'] | Should -Be 'Allow HTTPS from the workload network'
        }

        It 'creates the group before any of its rules' {
            $null = Invoke-Nsg (New-InfraFile)
            $order = @($global:AzlNsgCalls | Where-Object { $_.Command -like 'stack-hci-vm network nsg * create' -or $_.Command -eq 'stack-hci-vm network nsg create' } | ForEach-Object Command)
            $order | Should -Be @('stack-hci-vm network nsg create', 'stack-hci-vm network nsg rule create')
        }

        It 'sends any, any, any and * for what the rule leaves out, and no description' {
            $null = Invoke-Nsg (New-InfraFile -Groups (New-Group @{ rules = @([ordered]@{ name = 'deny-all-out'; priority = 4096; direction = 'outbound'; access = 'deny'; destination_port_ranges = '*' }) }))
            $rule = (Get-Call 'stack-hci-vm network nsg rule create')[0]
            $rule.Options['--protocol'] | Should -Be '*'
            $rule.Options['--direction'] | Should -Be 'Outbound'
            $rule.Options['--access'] | Should -Be 'Deny'
            $rule.Options['--source-address-prefixes'] | Should -Be '*'
            $rule.Options['--destination-address-prefixes'] | Should -Be '*'
            $rule.Options['--source-port-ranges'] | Should -Be '*'
            $rule.Options['--destination-port-ranges'] | Should -Be '*'
            $rule.Options.ContainsKey('--description') | Should -BeFalse
        }

        It 'accepts protocol in any letter case and normalises it' {
            $null = Invoke-Nsg (New-InfraFile -Groups (New-Group @{ rules = @((New-Rule @{ protocol = 'UDP' })) }))
            (Get-Call 'stack-hci-vm network nsg rule create')[0].Options['--protocol'] | Should -Be 'Udp'
        }

        It 'creates every group and every rule of the list' {
            $groups = (New-Group @{ name = 'nsg-a'; rules = @((New-Rule @{ name = 'r1'; priority = 100 }), (New-Rule @{ name = 'r2'; priority = 200 })) }), (New-Group @{ name = 'nsg-b' })
            $r = Invoke-Nsg (New-InfraFile -Groups $groups)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @(Get-Call 'stack-hci-vm network nsg create').Count | Should -Be 2
            @(Get-Call 'stack-hci-vm network nsg rule create').Count | Should -Be 3
        }

        It 'puts the file-level tags on the group, and sends none when the file has none' {
            $null = Invoke-Nsg (New-InfraFile -Tags ([ordered]@{ environment = 'lab'; owner = 'iic' }))
            @((Get-Call 'stack-hci-vm network nsg create')[0].Options['--tags']) | Should -Be @('environment=lab', 'owner=iic')
            Reset-Azure
            $null = Invoke-Nsg (New-InfraFile)
            (Get-Call 'stack-hci-vm network nsg create')[0].Options.ContainsKey('--tags') | Should -BeFalse
        }

        It 'carries the subscription on every call and never changes the Azure CLI defaults, installs an extension, deletes or updates' {
            $null = Invoke-Nsg (New-InfraFile)
            foreach ($call in @($global:AzlNsgCalls | Where-Object { $_.Command -like "stack-hci-vm *" })) { $call.Options["--subscription"] | Should -Be $global:AzlNsgSub -Because $call.Command }
            @($global:AzlNsgCalls.Command) | Should -Not -Contain 'account set'
            @($global:AzlNsgCalls.Command | Where-Object { $_ -match 'extension (add|update)|delete|update|login' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the group exists (idempotent)' {
        It 'creates nothing and says so, when the group and the rule are there' {
            $global:AzlNsgState.Groups['nsg-workloads'] = $true
            Add-ExistingRule 'nsg-workloads' @{ priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; sourceAddressPrefixes = @('198.51.100.7', '192.0.2.0/24'); destinationAddressPrefixes = @('*'); sourcePortRanges = @('*'); destinationPortRanges = @('8000-8100', '443') }
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('AlreadyExists', 'AlreadyExists')
            $r.Rows[1].Detail | Should -BeNullOrEmpty
            @($global:AzlNsgCalls.Command | Where-Object { $_ -match ' create$' }) | Should -BeNullOrEmpty
        }

        It 'creates the missing rules of a group that has none yet, and does not create the group again' {
            $global:AzlNsgState.Groups['nsg-workloads'] = $true
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Detail | Should -Match 'no rules yet'
            @(Get-Call 'stack-hci-vm network nsg create').Count | Should -Be 0
            @(Get-Call 'stack-hci-vm network nsg rule create').Count | Should -Be 1
        }

        It 'reports a rule that differs from the file and changes nothing' {
            $global:AzlNsgState.Groups['nsg-workloads'] = $true
            Add-ExistingRule 'nsg-workloads' @{ priority = 100; direction = 'Inbound'; access = 'Deny'; protocol = 'Tcp'; sourceAddressPrefixes = @('192.0.2.0/24', '198.51.100.7'); destinationAddressPrefixes = @('*'); sourcePortRanges = @('*'); destinationPortRanges = @('443', '8000-8100') }
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[1].Action | Should -Be 'AlreadyExists'
            $r.Rows[1].Detail | Should -Match 'access is Deny'
            @(Get-Call 'stack-hci-vm network nsg rule create').Count | Should -Be 0
        }

        It 'fails a rule whose priority another rule of the group already has' {
            $global:AzlNsgState.Groups['nsg-workloads'] = $true
            Add-ExistingRule 'nsg-workloads' @{ priority = 100 } 'some-other-rule'
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[1].Action | Should -Be 'Failed'
            $r.Rows[1].Detail | Should -Match 'some-other-rule'
        }

        It 'never deletes or updates anything' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match "'(delete|update)'"
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'reads Azure, plans the group and the rules, and creates nothing' {
            $r = Invoke-Nsg (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('WouldCreate', 'WouldCreate')
            @($global:AzlNsgCalls.Command | Where-Object { $_ -match ' create$' }) | Should -BeNullOrEmpty
            @(Get-Call 'stack-hci-vm network nsg show').Count | Should -Be 1
        }

        It 'does nothing and does not call Azure when the file lists no group' {
            $r = Invoke-Nsg (New-InfraFile -Groups @())
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke az -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file that lists a group while SDN is <Why>' -ForEach @(
            @{ Why = 'off'; Sdn = $false }, @{ Why = 'not in the file'; Sdn = $null }
        ) {
            $r = Invoke-Nsg (New-InfraFile -Sdn $Sdn)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'sdn.enabled'
            $r.Text | Should -Match 'does not turn SDN on'
            Should -Invoke az -Times 0 -Exactly
        }

        It 'refuses a group without rules (Microsoft Learn: an empty group blocks all inbound traffic)' -ForEach @(
            @{ Why = 'an empty rule list'; Group = @{ rules = @() } }
            @{ Why = 'no rules key'; Group = @{ rules = $null } }
        ) {
            $r = Invoke-Nsg (New-InfraFile -Groups (New-Group $Group))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'at least one rule'
            Should -Invoke az -Times 0 -Exactly
        }

        It 'refuses a missing azure.<Key>' -ForEach @(@{ Key = 'tenant_id' }, @{ Key = 'subscription_id' }, @{ Key = 'resource_group' }, @{ Key = 'location' }, @{ Key = 'custom_location' }) {
            $r = Invoke-Nsg (New-InfraFile -Azure @{ $Key = $null })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match "azure.$Key"
            Should -Invoke az -Times 0 -Exactly
        }

        It 'refuses the all-zero subscription id' {
            (Invoke-Nsg (New-InfraFile -Azure @{ subscription_id = [guid]::Empty.ToString() })).ExitCode | Should -Be 2
        }

        It 'refuses a rule with <Why>' -ForEach @(
            @{ Why = 'priority 99'; Rule = @{ priority = 99 } }
            @{ Why = 'priority 4097'; Rule = @{ priority = 4097 } }
            @{ Why = 'no priority'; Rule = @{ priority = $null } }
            @{ Why = 'priority text'; Rule = @{ priority = 'high' } }
            @{ Why = 'no direction'; Rule = @{ direction = $null } }
            @{ Why = 'direction Sideways'; Rule = @{ direction = 'Sideways' } }
            @{ Why = 'access Maybe'; Rule = @{ access = 'Maybe' } }
            @{ Why = 'no access'; Rule = @{ access = $null } }
            @{ Why = 'protocol Gre'; Rule = @{ protocol = 'Gre' } }
            @{ Why = 'a source address that is not an address'; Rule = @{ source_address_prefixes = @('VirtualNetwork') } }
            @{ Why = 'a destination address with prefix 33'; Rule = @{ destination_address_prefixes = @('192.0.2.0/33') } }
            @{ Why = 'a destination address of 999'; Rule = @{ destination_address_prefixes = @('999.1.1.1') } }
            @{ Why = 'a port above 65535'; Rule = @{ destination_port_ranges = @('70000') } }
            @{ Why = 'a reversed port range'; Rule = @{ destination_port_ranges = @('9000-8000') } }
            @{ Why = 'a source port that is text'; Rule = @{ source_port_ranges = @('http') } }
            @{ Why = 'no destination ports'; Rule = @{ destination_port_ranges = $null } }
            @{ Why = 'a description of 141 characters'; Rule = @{ description = ('x' * 141) } }
            @{ Why = 'an ampersand in the description'; Rule = @{ description = 'allow a & b' } }
            @{ Why = 'a pipe in the description'; Rule = @{ description = 'a|b' } }
            @{ Why = 'a percent sign in the description'; Rule = @{ description = '100%' } }
            @{ Why = 'a name that starts with a hyphen'; Rule = @{ name = '-bad' } }
            @{ Why = 'a name that ends with a hyphen'; Rule = @{ name = 'bad-' } }
            @{ Why = 'a name of 81 characters'; Rule = @{ name = ('a' * 81) } }
        ) {
            $r = Invoke-Nsg (New-InfraFile -Groups (New-Group @{ rules = @((New-Rule $Rule)) }))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke az -Times 0 -Exactly
        }

        It 'accepts a description of exactly 140 characters, priority 100 and priority 4096' {
            $rules = (New-Rule @{ name = 'first'; priority = 100; description = ('x' * 140) }), (New-Rule @{ name = 'last'; priority = 4096 })
            (Invoke-Nsg (New-InfraFile -Groups (New-Group @{ rules = $rules }))).ExitCode | Should -Be 0
        }

        It 'refuses two rules with the same priority, or the same name, in one group' {
            $samePriority = (New-Rule @{ name = 'one'; priority = 300 }), (New-Rule @{ name = 'two'; priority = 300 })
            (Invoke-Nsg (New-InfraFile -Groups (New-Group @{ rules = $samePriority }))).ExitCode | Should -Be 2
            $sameName = (New-Rule @{ name = 'one'; priority = 300 }), (New-Rule @{ name = 'ONE'; priority = 400 })
            (Invoke-Nsg (New-InfraFile -Groups (New-Group @{ rules = $sameName }))).ExitCode | Should -Be 2
            Should -Invoke az -Times 0 -Exactly
        }

        It 'allows the same priority in two different groups' {
            $groups = (New-Group @{ name = 'nsg-a' }), (New-Group @{ name = 'nsg-b' })
            (Invoke-Nsg (New-InfraFile -Groups $groups)).ExitCode | Should -Be 0
        }

        It 'refuses a group name that is not valid or is listed twice' {
            (Invoke-Nsg (New-InfraFile -Groups (New-Group @{ name = 'nsg workloads' }))).ExitCode | Should -Be 2
            (Invoke-Nsg (New-InfraFile -Groups (New-Group @{ name = 'nsg-' }))).ExitCode | Should -Be 2
            (Invoke-Nsg (New-InfraFile -Groups (New-Group @{ name = 'nsg-a' }), (New-Group @{ name = 'NSG-A' }))).ExitCode | Should -Be 2
            Should -Invoke az -Times 0 -Exactly
        }

        It 'refuses a tag that holds a character the Azure CLI command file would read as a command' {
            (Invoke-Nsg (New-InfraFile -Tags ([ordered]@{ owner = 'a&b' }))).ExitCode | Should -Be 2
            Should -Invoke az -Times 0 -Exactly
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when the Azure CLI is not signed in' {
            $global:AzlNsgState.SignedIn = $false
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'az login'
            @($global:AzlNsgCalls.Command | Where-Object { $_ -match ' create$' }) | Should -BeNullOrEmpty
        }

        It 'stops when the sign-in is to another tenant' {
            $global:AzlNsgState.TenantId = [guid]::NewGuid().ToString()
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            @($global:AzlNsgCalls.Command | Where-Object { $_ -match ' create$' }) | Should -BeNullOrEmpty
        }

        It 'stops with a clear message when the stack-hci-vm extension is missing, and does not install it' {
            $global:AzlNsgState.Extension = $false
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'stack-hci-vm is not installed'
            $r.Text | Should -Match 'does not install it'
            @($global:AzlNsgCalls.Command) | Should -Not -Contain 'extension add'
            @($global:AzlNsgCalls.Command | Where-Object { $_ -match ' create$' }) | Should -BeNullOrEmpty
        }

        It 'does not hide a lookup error that is not a not-found' {
            $global:AzlNsgState.Fail['stack-hci-vm network nsg show'] = 'AuthorizationFailed: the client does not have authorization.'
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'AuthorizationFailed'
            @(Get-Call 'stack-hci-vm network nsg create').Count | Should -Be 0
        }

        It 'reports a failed group, skips its rules, goes on with the next group, and exits 1' {
            $global:AzlNsgState.Fail['stack-hci-vm network nsg create'] = 'QuotaExceeded'
            $r = Invoke-Nsg (New-InfraFile -Groups (New-Group @{ name = 'nsg-a' }), (New-Group @{ name = 'nsg-b' }))
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed', 'Skipped', 'Failed', 'Skipped')
            @(Get-Call 'stack-hci-vm network nsg create').Count | Should -Be 2
            @(Get-Call 'stack-hci-vm network nsg rule create').Count | Should -Be 0
        }

        It 'reports a failed rule, says the group may be missing rules, and exits 1' {
            $global:AzlNsgState.Fail['stack-hci-vm network nsg rule create'] = 'InvalidSecurityRule'
            $r = Invoke-Nsg (New-InfraFile)
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Created', 'Failed')
            $r.Text | Should -Match 'may be missing rules'
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
            $script:Text | Should -Not -Match 'variables\.yml|network\.nsgs'
            $script:Text | Should -Not -Match 'Invoke-Expression|Start-Process|cmd(\.exe)? /c|iex '
            ([regex]::Matches($script:Text, '&\s+az\s+@')).Count | Should -Be 1
            $script:Text | Should -Not -Match '(?m)^\s*az\s+(stack-hci-vm|account|extension)'
        }

        It 'holds no GUID, no address and no Key Vault name' {
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
            $script:Text | Should -Not -Match '(?i)kv-|keyvault://|Get-AzKeyVault'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_NetworkSecurityGroup_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'LogPath'
        }

        It 'reads only registry keys that exist: <_>' -ForEach @(
            'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'azure.location', 'azure.custom_location', 'sdn.enabled'
            'networking.network_security_groups[].name', 'networking.network_security_groups[].rules[].name', 'networking.network_security_groups[].rules[].priority'
            'networking.network_security_groups[].rules[].direction', 'networking.network_security_groups[].rules[].access', 'networking.network_security_groups[].rules[].protocol'
            'networking.network_security_groups[].rules[].source_address_prefixes', 'networking.network_security_groups[].rules[].destination_address_prefixes'
            'networking.network_security_groups[].rules[].source_port_ranges', 'networking.network_security_groups[].rules[].destination_port_ranges'
            'networking.network_security_groups[].rules[].description'
        ) {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
