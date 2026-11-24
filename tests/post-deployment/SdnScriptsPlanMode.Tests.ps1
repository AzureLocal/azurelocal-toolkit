#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The SDN scripts of phase 06 (post-deployment) each run ALONE, with only their own parameters, and plan against the toolkit example file:
#   task 01  Enable-ArcSdn.ps1, Test-ArcSdn.ps1
#   task 07  New-NetworkSecurityGroup.ps1 and New-NetworkSecurityGroup.azcli.ps1
#   task 08  New-LogicalNetwork.ps1 and New-LogicalNetwork.azcli.ps1
# Each script checks its own preconditions from the file (and from Azure or the machine), and no script needs another one to have run in the same
# session: there is no hidden state between them. The Azure CLI (az) and Invoke-Command are replaced by fakes, so no Azure and no cluster is used, and a
# test fails when a plan sends anything that changes a resource. The file is config/variables/examples/infrastructure.example.yml, as it is, and with the
# values that the SDN scripts need added in memory (generated ids; the example holds the all-zero placeholder).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/SdnScriptsPlanMode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and cluster and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeDiscovery {
    $deploy = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment'))
    $script:Cases = @(
        @{ Name = 'Enable-ArcSdn.ps1'; Task = 'task-01'; Path = [IO.Path]::Combine($deploy, 'task-01-deploy-sdn', 'powershell', 'Enable-ArcSdn.ps1'); Own = @('ComputerName', 'Credential') }
        @{ Name = 'Test-ArcSdn.ps1'; Task = 'task-01'; Path = [IO.Path]::Combine($deploy, 'task-01-deploy-sdn', 'powershell', 'Test-ArcSdn.ps1'); Own = @('ComputerName', 'Credential') }
        @{ Name = 'New-NetworkSecurityGroup.ps1'; Task = 'task-07'; Path = [IO.Path]::Combine($deploy, 'task-07-configure-nsgs', 'powershell', 'New-NetworkSecurityGroup.ps1'); Own = @() }
        @{ Name = 'New-NetworkSecurityGroup.azcli.ps1'; Task = 'task-07'; Path = [IO.Path]::Combine($deploy, 'task-07-configure-nsgs', 'azurecli', 'New-NetworkSecurityGroup.azcli.ps1'); Own = @() }
        @{ Name = 'New-LogicalNetwork.ps1'; Task = 'task-08'; Path = [IO.Path]::Combine($deploy, 'task-08-logical-network-creation', 'powershell', 'New-LogicalNetwork.ps1'); Own = @('ComputerName', 'Credential') }
        @{ Name = 'New-LogicalNetwork.azcli.ps1'; Task = 'task-08'; Path = [IO.Path]::Combine($deploy, 'task-08-logical-network-creation', 'azurecli', 'New-LogicalNetwork.azcli.ps1'); Own = @() }
    )
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $script:Deploy = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment')
    $script:Paths = @{
        'Enable-ArcSdn.ps1'                   = [IO.Path]::Combine($script:Deploy, 'task-01-deploy-sdn', 'powershell', 'Enable-ArcSdn.ps1')
        'Test-ArcSdn.ps1'                     = [IO.Path]::Combine($script:Deploy, 'task-01-deploy-sdn', 'powershell', 'Test-ArcSdn.ps1')
        'New-NetworkSecurityGroup.ps1'        = [IO.Path]::Combine($script:Deploy, 'task-07-configure-nsgs', 'powershell', 'New-NetworkSecurityGroup.ps1')
        'New-NetworkSecurityGroup.azcli.ps1'  = [IO.Path]::Combine($script:Deploy, 'task-07-configure-nsgs', 'azurecli', 'New-NetworkSecurityGroup.azcli.ps1')
        'New-LogicalNetwork.ps1'              = [IO.Path]::Combine($script:Deploy, 'task-08-logical-network-creation', 'powershell', 'New-LogicalNetwork.ps1')
        'New-LogicalNetwork.azcli.ps1'        = [IO.Path]::Combine($script:Deploy, 'task-08-logical-network-creation', 'azurecli', 'New-LogicalNetwork.azcli.ps1')
    }
    Import-Module powershell-yaml

    function az { }

    $global:AzlPlanTenant = [guid]::NewGuid().ToString()
    $global:AzlPlanSub = [guid]::NewGuid().ToString()
    $global:AzlPlanSecret = 'AZL_TEST_PLAN_' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    [Environment]::SetEnvironmentVariable($global:AzlPlanSecret, [guid]::NewGuid().ToString())

    # The toolkit example, as read; with -Sdn the values the SDN scripts need: Azure ids, a supported intent layout, the sdn block, one network security
    # group with one rule and a logical network that uses it. Secret references are replaced by an environment variable made for the test.
    function New-PlanFile {
        param([switch]$Sdn, [switch]$NoSwitchName, [switch]$NoGroupInFile)
        $text = Get-Content -LiteralPath $script:Example -Raw
        if (-not $Sdn) {
            $file = Join-Path $TestDrive "example-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            Set-Content -LiteralPath $file -Value $text
            return $file
        }
        $doc = ConvertFrom-Yaml -Ordered $text
        $doc.azure.tenant_id = $global:AzlPlanTenant
        $doc.azure.subscription_id = $global:AzlPlanSub
        $doc.networking.intents = @(
            [ordered]@{ name = 'management_compute'; traffic = @('management', 'compute'); adapters = @('Port1', 'Port2') }
            [ordered]@{ name = 'storage'; traffic = @('storage'); adapters = @('Port3', 'Port4') })
        $doc.identity.local_admin.password = "env://$($global:AzlPlanSecret)"
        $doc.identity.active_directory.lcm_user.password = "env://$($global:AzlPlanSecret)"
        $doc.sdn = [ordered]@{ enabled = $true; prefix = 'iic01'; dns_records = 'dynamic'; acknowledge_maintenance_window = $true }
        if (-not $NoGroupInFile) {
            $doc.networking.network_security_groups = @([ordered]@{ name = 'nsg-iic-baseline'; rules = @(
                    [ordered]@{ name = 'Allow-RDP-Management'; priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; source_address_prefixes = @('192.0.2.0/24'); destination_port_ranges = @('3389') }
                    [ordered]@{ name = 'Deny-All-Inbound'; priority = 4000; direction = 'Inbound'; access = 'Deny'; protocol = '*'; destination_port_ranges = @('*') }) })
            $doc.networking.logical_networks[0].nsg_name = 'nsg-iic-baseline'
        }
        if (-not $NoSwitchName) { $doc.networking.logical_networks[0].vm_switch_name = 'ConvergedSwitch(management_compute)' }
        $file = Join-Path $TestDrive "plan-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-World {
        $global:AzlPlanCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlPlanRemote = [System.Collections.Generic.List[object]]::new()
        $global:AzlPlanState = @{ Groups = @{ 'nsg-iic-baseline' = $true }; NoRules = $false }
    }
    function Invoke-Alone([string]$Script, [string]$File, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = & $Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = @($all)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    # Calls that would change something in Azure.
    function Get-Change { @($global:AzlPlanCalls | Where-Object { $_.Command -match '\b(create|update|delete|set)\b' }) }
}

Describe 'The SDN scripts of phase 06 run alone in Plan mode' {
    AfterAll {
        Remove-Variable -Name AzlPlanTenant, AzlPlanSub, AzlPlanSecret, AzlPlanCalls, AzlPlanRemote, AzlPlanState -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Reset-World
        Mock Invoke-Command {
            # a connection probes the machine first with a block that does nothing
            if ($ScriptBlock.ToString().Trim() -eq '$true') { return $true }
            $step = if ($ArgumentList -and $ArgumentList.Count -gt 0) { [string]$ArgumentList[0] } else { '' }
            $global:AzlPlanRemote.Add([pscustomobject]@{ Step = $step; Computer = [string]$ComputerName })
            switch ($step) {
                'Probe' { return 'iic-n01' }
                'ReadState' { return @{ Computer = 'iic-n01'; OsBuild = 26100; HasEce = $true; NcGroups = @(); AllGroups = @(); Groups = @(); DnsAddresses = @() } }
                default { return @('ConvergedSwitch(management_compute)') }
            }
        }
        Mock az {
            $a = @($args | ForEach-Object { [string]$_ })
            $words = @(); foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
            $options = @{}; $current = ''
            foreach ($x in $a[$words.Count..($a.Count - 1)]) {
                if ($x.StartsWith('--')) { $current = $x; $options[$current] = @() } elseif ($current) { $options[$current] += $x }
            }
            $command = $words -join ' '
            $global:AzlPlanCalls.Add([pscustomobject]@{ Command = $command; Arguments = $a; Options = $options })
            $fail = { param($code, $message) $global:LASTEXITCODE = $code; [Management.Automation.ErrorRecord]::new([Exception]::new($message), 'az', 'NotSpecified', $null) }
            $global:LASTEXITCODE = 0
            switch ($command) {
                'account show' { return ('{"tenantId":"' + $global:AzlPlanTenant + '","id":"' + $global:AzlPlanSub + '"}') }
                'extension show' { return '{"name":"stack-hci-vm"}' }
                'stack-hci-vm network nsg show' {
                    $name = $options['--name'][0]
                    if (-not $global:AzlPlanState.Groups.ContainsKey($name)) { return (& $fail 3 "(ResourceNotFound) The Resource 'Microsoft.AzureStackHCI/networkSecurityGroups/$name' was not found.") }
                    return ('{"name":"' + $name + '"}')
                }
                'stack-hci-vm network nsg rule list' { if ($global:AzlPlanState.NoRules) { return '[]' }; return '[{"name":"Allow-RDP-Management","properties":{"priority":100}}]' }
                'stack-hci-vm network lnet show' { return (& $fail 3 "(ResourceNotFound) The Resource 'Microsoft.AzureStackHCI/logicalNetworks/$($options['--name'][0])' was not found.") }
                default { return (& $fail 2 "unexpected az call: $command") }
            }
        }
    }

    Context '<Name> (<Task>)' -ForEach $script:Cases {
        BeforeAll { $script:This = $script:Paths[$Name] }

        It 'takes -InfrastructureFile as its only mandatory parameter, and -WhatIf and -LogPath' {
            $command = Get-Command -Name $script:This
            @($command.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory } } | ForEach-Object Name) | Should -Be @('InfrastructureFile')
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $command.Parameters.ContainsKey('LogPath') | Should -BeTrue
            @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters -and $_ -notin 'InfrastructureFile', 'LogPath' } | Sort-Object) | Should -Be @($Own | Sort-Object)
        }

        It 'plans against the toolkit example file as it is, alone, and exits 0 without a change' {
            $r = Invoke-Alone $script:This (New-PlanFile) @{}
            # The example plans no SDN (sdn.enabled false) and lists no network security group, so a script either reports that it has nothing to do,
            # or stops with its documented exit code 2 on a value the example does not hold (the logical network needs a virtual switch name for the CLI twin).
            $r.ExitCode | Should -BeIn @(0, 2) -Because $r.Text
            Get-Change | Should -BeNullOrEmpty
            @($global:AzlPlanRemote | Where-Object Step -EQ 'Enable') | Should -BeNullOrEmpty
        }

        It 'plans against the example with the SDN values added, alone: exit 0, a plan in the output, nothing created, enabled or changed' {
            $log = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
            $r = Invoke-Alone $script:This (New-PlanFile -Sdn) @{ LogPath = $log }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-Change | Should -BeNullOrEmpty
            @($global:AzlPlanRemote | Where-Object Step -EQ 'Enable') | Should -BeNullOrEmpty
            Test-Path -LiteralPath $log | Should -BeTrue
            (Get-Content -LiteralPath $log -Raw).Trim() | Should -Not -BeNullOrEmpty
        }
    }

    Context 'task 01: Enable-ArcSdn.ps1 plans the enablement and says it cannot be undone' {
        It 'shows the Add-EceFeature plan with the prefix, and warns' {
            $r = Invoke-Alone $script:Paths['Enable-ArcSdn.ps1'] (New-PlanFile -Sdn) @{}
            $r.Text | Should -Match 'Plan: Add-EceFeature -Name NC -SDNPrefix iic01'
            $r.Text | Should -Match 'CANNOT BE UNDONE'
            @($r.Output | Where-Object { $_.PSObject.Properties['Action'] })[0].Action | Should -Be 'WouldEnable'
        }

        It 'checks its own preconditions from the file: the example intent layout (compute and storage together) is refused with exit code 2' {
            $text = (Get-Content -LiteralPath $script:Example -Raw) -replace '(?m)^  enabled: false', '  enabled: true'
            $file = Join-Path $TestDrive 'example-sdn-on.yml'
            Set-Content -LiteralPath $file -Value $text
            $doc = ConvertFrom-Yaml -Ordered $text
            $doc.sdn = [ordered]@{ enabled = $true; prefix = 'iic01'; dns_records = 'dynamic'; acknowledge_maintenance_window = $true }
            Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
            $r = Invoke-Alone $script:Paths['Enable-ArcSdn.ps1'] $file @{}
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'not supported by SDN enabled by Azure Arc'
            $global:AzlPlanRemote.Count | Should -Be 0
        }
    }

    Context 'task 07: the network security group scripts stop when SDN is not enabled' {
        It '<Script> exits 2 with a group in the file and sdn.enabled false, and sends nothing to Azure' -ForEach @(
            @{ Script = 'New-NetworkSecurityGroup.ps1' }, @{ Script = 'New-NetworkSecurityGroup.azcli.ps1' }) {
            $doc = ConvertFrom-Yaml -Ordered (Get-Content -LiteralPath (New-PlanFile -Sdn) -Raw)
            $doc.sdn.enabled = $false
            $file = Join-Path $TestDrive "sdn-off-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
            $r = Invoke-Alone $script:Paths[$Script] $file @{}
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'sdn\.enabled'
            $global:AzlPlanCalls.Count | Should -Be 0
        }

        It '<Script> plans the group and its two rules when SDN is enabled in the file' -ForEach @(
            @{ Script = 'New-NetworkSecurityGroup.ps1' }, @{ Script = 'New-NetworkSecurityGroup.azcli.ps1' }) {
            $global:AzlPlanState.Groups = @{}
            $r = Invoke-Alone $script:Paths[$Script] (New-PlanFile -Sdn) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $rows = @($r.Output | Where-Object { $_.PSObject.Properties['Action'] })
            @($rows.Action) | Should -Be @('WouldCreate', 'WouldCreate', 'WouldCreate')
            Get-Change | Should -BeNullOrEmpty
        }
    }

    Context 'task 08: a logical network with nsg_name checks that the group exists' {
        It '<Script> plans the network when the group exists' -ForEach @(
            @{ Script = 'New-LogicalNetwork.ps1' }, @{ Script = 'New-LogicalNetwork.azcli.ps1' }) {
            $r = Invoke-Alone $script:Paths[$Script] (New-PlanFile -Sdn) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($global:AzlPlanCalls | Where-Object Command -EQ 'stack-hci-vm network nsg show').Count | Should -BeGreaterThan 0
            Get-Change | Should -BeNullOrEmpty
        }

        It '<Script> does not plan the network when the group exists but has no rule' -ForEach @(
            @{ Script = 'New-LogicalNetwork.ps1' }, @{ Script = 'New-LogicalNetwork.azcli.ps1' }) {
            $global:AzlPlanState.NoRules = $true
            $r = Invoke-Alone $script:Paths[$Script] (New-PlanFile -Sdn) @{}
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'has no rule'
            Get-Change | Should -BeNullOrEmpty
        }

        It '<Script> does not plan the network, and says why, when the group of nsg_name is not in Azure or in the file' -ForEach @(
            @{ Script = 'New-LogicalNetwork.ps1' }, @{ Script = 'New-LogicalNetwork.azcli.ps1' }) {
            $global:AzlPlanState.Groups = @{}
            $doc = ConvertFrom-Yaml -Ordered (Get-Content -LiteralPath (New-PlanFile -Sdn -NoGroupInFile) -Raw)
            $doc.networking.logical_networks[0].nsg_name = 'nsg-iic-missing'
            $file = Join-Path $TestDrive "nsg-missing-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
            $r = Invoke-Alone $script:Paths[$Script] $file @{}
            $r.ExitCode | Should -BeIn @(1, 2) -Because $r.Text
            $r.Text | Should -Match 'nsg-iic-missing'
            Get-Change | Should -BeNullOrEmpty
        }
    }
}
