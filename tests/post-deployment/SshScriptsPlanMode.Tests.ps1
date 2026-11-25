#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 04 (SSH connectivity to nodes): the two scripts of the task each run ALONE, with only their own parameters, and plan
# against the toolkit example file:
#   Invoke-SSHConnectivity-Orchestrated.ps1   Azure PowerShell: the WindowsOpenSSH extension, the HybridConnectivity endpoint and the SSH service configuration
#   Enable-ArcSshConnectivity.azcli.ps1       the same with the Azure CLI
# Each script checks its own preconditions from the file and from Azure, and none needs the other to have run. Every Az cmdlet and az are fakes, so no
# Azure and no node is used, and a test fails when a plan sends anything that changes a resource. The file is
# config/variables/examples/infrastructure.example.yml, as it is, and with the values the task needs added in memory.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/SshScriptsPlanMode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeDiscovery {
    $task = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-04-ssh-connectivity-to-nodes'))
    $script:Cases = @(
        @{ Name = 'Invoke-SSHConnectivity-Orchestrated.ps1'; Reads = $true; Own = @('MaxWaitMinutes', 'PollSeconds', 'SshdPort', 'TargetNode') }
        @{ Name = 'Enable-ArcSshConnectivity.azcli.ps1'; Reads = $false; Own = @('MaxWaitMinutes', 'PollSeconds', 'SshdPort', 'TargetNode') }
    )
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $task = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-04-ssh-connectivity-to-nodes')
    $script:Paths = @{
        'Invoke-SSHConnectivity-Orchestrated.ps1' = [IO.Path]::Combine($task, 'powershell', 'Invoke-SSHConnectivity-Orchestrated.ps1')
        'Enable-ArcSshConnectivity.azcli.ps1'     = [IO.Path]::Combine($task, 'azurecli', 'Enable-ArcSshConnectivity.azcli.ps1')
    }
    Import-Module powershell-yaml

    function az { }
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function Register-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function Get-AzConnectedMachine { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function Get-AzConnectedMachineExtension { [CmdletBinding()] param([string]$MachineName, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Name) }
    function New-AzConnectedMachineExtension { [CmdletBinding()] param([string]$Name, [string]$MachineName, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$Publisher, [string]$ExtensionType) }
    function Invoke-AzRestMethod { [CmdletBinding()] param([string]$Method, [string]$Path, [string]$Payload) }
    function Test-NetConnection { [CmdletBinding()] param([string]$ComputerName, [int]$Port, [string]$InformationLevel) }

    $global:AzlPlanTenant = [guid]::NewGuid().ToString()
    $global:AzlPlanSub = [guid]::NewGuid().ToString()

    function New-PlanFile {
        param([switch]$Values, [scriptblock]$Edit)
        $text = Get-Content -LiteralPath $script:Example -Raw
        if (-not $Values -and -not $Edit) {
            $file = Join-Path $TestDrive "example-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            Set-Content -LiteralPath $file -Value $text
            return $file
        }
        $doc = ConvertFrom-Yaml -Ordered $text
        if ($Values) { $doc.azure.tenant_id = $global:AzlPlanTenant; $doc.azure.subscription_id = $global:AzlPlanSub }
        if ($Edit) { & $Edit $doc }
        $file = Join-Path $TestDrive "plan-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-World {
        $global:AzlPlanCalls = [System.Collections.Generic.List[object]]::new()
        # Fresh: no extension, no endpoint, no service configuration; the provider is registered; the machines are Connected.
        $global:AzlPlanState = @{ Provider = 'Registered'; Extension = ''; Endpoint = $false; Port = $null; Status = 'Connected' }
    }
    function Invoke-Alone([string]$Script, [string]$File, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = & $Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    # Anything that writes: the Az writes, and the az calls that register, create or PUT.
    function Get-Change { @($global:AzlPlanCalls | Where-Object { $_.Command -in 'Register', 'NewExtension', 'RestPUT', 'rest', 'provider register', 'connectedmachine extension create' }) }
}

Describe 'The SSH scripts of phase 06 run alone in Plan mode' {
    AfterAll { Remove-Variable -Name AzlPlanTenant, AzlPlanSub, AzlPlanCalls, AzlPlanState -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-World
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlPlanTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlPlanSub } } }
        Mock Set-AzContext { }
        Mock Get-AzResourceProvider { [pscustomobject]@{ RegistrationState = $global:AzlPlanState.Provider } }
        Mock Register-AzResourceProvider { $global:AzlPlanCalls.Add([pscustomobject]@{ Command = 'Register' }) }
        Mock Get-AzConnectedMachine { [pscustomobject]@{ Name = $Name; Status = $global:AzlPlanState.Status; Location = 'eastus' } }
        Mock Get-AzConnectedMachineExtension {
            if (-not $global:AzlPlanState.Extension) { throw "(ResourceNotFound) The Resource 'extensions/$Name' was not found." }
            [pscustomobject]@{ Name = $Name; ProvisioningState = $global:AzlPlanState.Extension }
        }
        Mock New-AzConnectedMachineExtension { $global:AzlPlanCalls.Add([pscustomobject]@{ Command = 'NewExtension' }) }
        Mock Invoke-AzRestMethod {
            if ($Method -eq 'PUT') { $global:AzlPlanCalls.Add([pscustomobject]@{ Command = 'RestPUT' }); return [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
            if ($Path -match 'serviceconfigurations/SSH') {
                if ($null -eq $global:AzlPlanState.Port) { return [pscustomobject]@{ StatusCode = 404; Content = '{}' } }
                return [pscustomobject]@{ StatusCode = 200; Content = ('{"properties":{"port":' + $global:AzlPlanState.Port + ',"resourceProvisioningState":"Succeeded"}}') }
            }
            if (-not $global:AzlPlanState.Endpoint) { return [pscustomobject]@{ StatusCode = 404; Content = '{}' } }
            [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"type":"default"}}' }
        }
        Mock Test-NetConnection { $true }
        Mock az {
            $a = @($args | ForEach-Object { [string]$_ })
            $words = @(); foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
            $command = $words -join ' '
            $global:AzlPlanCalls.Add([pscustomobject]@{ Command = $command; Arguments = $a })
            $fail = { param($code, $message) $global:LASTEXITCODE = $code; [Management.Automation.ErrorRecord]::new([Exception]::new($message), 'az', 'NotSpecified', $null) }
            $global:LASTEXITCODE = 0
            switch ($command) {
                'account show' { return ('{"tenantId":"' + $global:AzlPlanTenant + '","id":"' + $global:AzlPlanSub + '"}') }
                'extension show' { return '{"name":"connectedmachine"}' }
                'provider show' { return $global:AzlPlanState.Provider }
                'connectedmachine show' { return ('{"status":"' + $global:AzlPlanState.Status + '","location":"eastus"}') }
                'connectedmachine extension show' {
                    if (-not $global:AzlPlanState.Extension) { return (& $fail 3 "(ResourceNotFound) The Resource 'extensions/WindowsOpenSSH' was not found.") }
                    return ('{"properties":{"provisioningState":"' + $global:AzlPlanState.Extension + '"}}')
                }
                default { return (& $fail 2 "unexpected az call: $command") }
            }
        }
    }

    Context '<Name>' -ForEach $script:Cases {
        BeforeAll { $script:This = $script:Paths[$Name] }

        It 'takes -InfrastructureFile as its only mandatory parameter, and -WhatIf and -LogPath' {
            $command = Get-Command -Name $script:This
            @($command.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory } } | ForEach-Object Name) | Should -Be @('InfrastructureFile')
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $command.Parameters.ContainsKey('LogPath') | Should -BeTrue
            @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters -and $_ -notin 'InfrastructureFile', 'LogPath' } | Sort-Object) | Should -Be @($Own | Sort-Object)
        }

        It 'plans against the toolkit example as it is: exit 2 on the placeholder tenant and subscription, and nothing is sent' {
            $r = Invoke-Alone $script:This (New-PlanFile) @{}
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'azure\.(tenant_id|subscription_id)'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'plans against the example with the Azure ids added, alone: exit 0, the provider, the extension, the endpoint and the service are only planned, the log is written' {
            $global:AzlPlanState.Provider = 'NotRegistered'
            $log = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{ LogPath = $log }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -EQ 'WouldRegister').Count | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 6
            Get-Change | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $log -Raw).Trim() | Should -Not -BeNullOrEmpty
        }

        It 'is idempotent: a machine that has the extension is AlreadyDone (and, for the PowerShell script, the endpoint and the SSH service on port 22 too), and a second plan sends nothing' {
            $global:AzlPlanState.Extension = 'Succeeded'; $global:AzlPlanState.Endpoint = $true; $global:AzlPlanState.Port = 22
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object { $_.Item -like '*extension*' -and $_.Action -eq 'AlreadyDone' }).Count | Should -Be 2
            # the Azure CLI script writes the endpoint and the service configuration again (an Azure PUT of the same value); the PowerShell script reads them first
            @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be $(if ($Reads) { 0 } else { 4 })
            Get-Change | Should -BeNullOrEmpty
        }

        It 'limits the plan to -TargetNode, and exits 2 for a node the file does not have' {
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{ TargetNode = 'iic-azl-n01' }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 3
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{ TargetNode = 'no-such-node' }
            $r.ExitCode | Should -Be 2
        }

        It 'fails with exit 1, and sends nothing, when the machine is not Connected' {
            $global:AzlPlanState.Status = 'Expired'
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'not Connected'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'fails (exit 1) for an extension in the Failed state, leaves it in place and writes nothing' {
            $global:AzlPlanState.Extension = 'Failed'
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Failed state'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'stops with exit code 2 when a node has no usable Arc machine name' {
            $file = New-PlanFile -Values -Edit { param($doc) $doc.nodes[0].arc_machine_name = 'bad&name' }
            $r = Invoke-Alone $script:This $file @{}
            $r.ExitCode | Should -Be 2
            Get-Change | Should -BeNullOrEmpty
        }
    }
}
