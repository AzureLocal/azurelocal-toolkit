# A fake Azure CLI for the tests of the *.azcli.ps1 scripts. Dot-source it inside BeforeAll, after "function az { }" has been defined (a stub with the name of
# the command, so the mock works whether or not the Azure CLI is installed), then call Mock az { & $global:AzlFakeDispatch $args } in BeforeEach.
# Nothing here reaches Azure: the dispatcher records each call (the words before the first option, and every option with its values) and answers from the handler
# registered for those words. An unregistered command is an error with exit code 2, so a script that calls an az command a test did not expect fails the test.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Globals are read by the dispatcher.')]
param()

$global:AzlFake = @{ Calls = [System.Collections.Generic.List[object]]::new(); Handlers = [ordered]@{} }

$global:AzlFakeDispatch = {
    param([object[]]$CallArgs)
    $a = @($CallArgs | ForEach-Object { [string]$_ })
    $words = @()
    foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
    $options = @{}
    $current = ''
    if ($words.Count -lt $a.Count) {
        foreach ($x in $a[$words.Count..($a.Count - 1)]) {
            if ($x.StartsWith('--')) { $current = $x; $options[$current] = @() }
            elseif ($current) { $options[$current] += $x }
        }
    }
    $command = $words -join ' '
    $global:AzlFake.Calls.Add([pscustomobject]@{ Command = $command; Arguments = $a; Options = $options })
    $global:LASTEXITCODE = 0
    $handler = $global:AzlFake.Handlers[$command]
    if (-not $handler) {
        $global:LASTEXITCODE = 2
        return [Management.Automation.ErrorRecord]::new([Exception]::new("unexpected az call: $command"), 'az', 'NotSpecified', $null)
    }
    & $handler $options $a
}

function Reset-AzFake {
    $global:AzlFake.Calls.Clear()
    $global:AzlFake.Handlers.Clear()
}

# Registers the answer for one command (the words before the first option). The handler gets the options table and the argument list and returns the output.
function Set-AzHandler([string]$Command, [scriptblock]$Handler) { $global:AzlFake.Handlers[$Command] = $Handler }

# What an az command that fails returns: an error record, and the exit code.
function New-AzFailure([int]$Code, [string]$Message) {
    $global:LASTEXITCODE = $Code
    [Management.Automation.ErrorRecord]::new([Exception]::new($Message), 'az', 'NotSpecified', $null)
}

function Get-AzCall([string]$Command) { @($global:AzlFake.Calls | Where-Object Command -EQ $Command) }

# The calls that change something: every command that is not a read (show, list, check-name, ls, get) and not the sign-in check.
function Get-AzWriteCall {
    @($global:AzlFake.Calls | Where-Object {
            $_.Command -notmatch '(^| )(show|list|check-name|validate)$' -and
            -not ($_.Command -eq 'rest' -and $_.Options['--method'][0] -eq 'get')
        })
}

# The sign-in the scripts check first: tenant, subscription, state and the account.
function Set-AzSignIn([string]$Tenant, [string]$Subscription, [string]$UserType = 'user', [string]$UserName = 'someone@example.test') {
    $global:AzlFakeSignIn = @{ Tenant = $Tenant; Subscription = $Subscription; UserType = $UserType; UserName = $UserName }
    Set-AzHandler 'account show' {
        param($o, $a)
        $null = $a
        ('{{"tenantId":"{0}","id":"{1}","state":"Enabled","user":{{"name":"{2}","type":"{3}"}}}}' -f $global:AzlFakeSignIn.Tenant, $(if ($o.ContainsKey('--subscription')) { $o['--subscription'][0] } else { $global:AzlFakeSignIn.Subscription }), $global:AzlFakeSignIn.UserName, $global:AzlFakeSignIn.UserType)
    }
}

# ---- a small infrastructure file for the tests, and a runner for the scripts under test. The tenant and the subscription are generated per run.
$global:AzlTestTenant = [guid]::NewGuid().ToString()
$global:AzlTestSubscription = [guid]::NewGuid().ToString()

function New-AzTestDoc {
    [ordered]@{
        azure      = [ordered]@{ tenant_id = $global:AzlTestTenant; subscription_id = $global:AzlTestSubscription; resource_group = 'rg-azl-01'; location = 'eastus'; custom_location = 'cl-azl-01' }
        tags       = [ordered]@{ environment = 'lab' }
        scenario   = [ordered]@{ identity = 'active_directory' }
        cluster    = [ordered]@{ name = 'azl-cl-01'; witness = [ordered]@{ type = 'cloud'; storage_account = 'stazlwitness01' } }
        nodes      = @([ordered]@{ name = 'azl-n01' }, [ordered]@{ name = 'azl-n02'; arc_machine_name = 'arc-azl-n02' })
        sdn        = [ordered]@{ enabled = $true }
        storage    = [ordered]@{
            paths     = @([ordered]@{ name = 'sp-workloads-01'; path = 'C:\ClusterStorage\vol-workloads-01\vms' })
            vm_images = @([ordered]@{ name = 'img-ws2025'; os_type = 'Windows'; publisher = 'microsoftwindowsserver'; offer = 'windowsserver'; sku = '2025-datacenter-azure-edition'; storage_path = 'sp-workloads-01' })
        }
        networking = [ordered]@{
            network_security_groups = @([ordered]@{ name = 'nsg-workloads'; rules = @([ordered]@{ name = 'allow-https-in'; priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; destination_port_ranges = @('443') }) })
            logical_networks        = @([ordered]@{ name = 'lnet-workloads'; vlan_id = 100; address_prefix = '192.0.2.0/24'; gateway = '192.0.2.1'; dns_servers = @('192.0.2.10'); ip_pool = [ordered]@{ start = '192.0.2.50'; end = '192.0.2.99' }; vm_switch_name = 'ConvergedSwitch'; nsg_name = 'nsg-workloads' })
        }
    }
}

# Writes the base document, after $Edit has changed it (the script block gets the document), as a YAML file in $TestDrive. Needs the module powershell-yaml.
function New-AzTestInfraFile([scriptblock]$Edit) {
    $doc = New-AzTestDoc
    if ($Edit) { & $Edit $doc }
    $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
    Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
    $file
}

# Runs a script and returns its exit code, the rows it wrote to the pipeline and the text of its information, warning and error streams.
function Invoke-AzTool([string]$Script, [string]$File, [hashtable]$Params = @{}, [switch]$DryRun) {
    $global:LASTEXITCODE = $null
    $all = if ($DryRun) { & $Script -InfrastructureFile $File @Params -WhatIf 6>&1 3>&1 2>&1 } else { & $Script -InfrastructureFile $File @Params 6>&1 3>&1 2>&1 }
    [pscustomobject]@{
        ExitCode = $global:LASTEXITCODE
        Rows     = @($all | Where-Object { $_.GetType().Name -eq 'PSCustomObject' })
        Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
    }
}
