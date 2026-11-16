#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), CI/CD pipeline deployment, phase 03 (validation), Azure CLI scripts: Test-ManagementResources.azcli.ps1 (task 01),
# Test-ManagementConnectivity.azcli.ps1 (task 02) and Test-ManagementConfiguration.azcli.ps1 (task 03). Each reads what infrastructure.yml describes with
# az and changes nothing. The az command is replaced by a function that records the call: no Azure, no tenant and no sign-in is used. Ids are generated
# per run; addresses are from the documentation ranges.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ManagementValidationAzureCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the az command.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '01-cicd-pipeline-deployment', 'phase-03-validation')
    $script:Resources = [IO.Path]::Combine($dir, 'task-01-verify-resources', 'azurecli', 'Test-ManagementResources.azcli.ps1')
    $script:Connectivity = [IO.Path]::Combine($dir, 'task-02-test-connectivity', 'azurecli', 'Test-ManagementConnectivity.azcli.ps1')
    $script:Configuration = [IO.Path]::Combine($dir, 'task-03-validate-configuration', 'azurecli', 'Test-ManagementConfiguration.azcli.ps1')
    Import-Module powershell-yaml

    function az { }

    $global:AzlK6Tenant = [guid]::NewGuid().ToString()
    $global:AzlK6Sub = [guid]::NewGuid().ToString()
    $global:AzlK6Home = [guid]::NewGuid().ToString()
    $global:AzlK6Workspace = "/subscriptions/$($global:AzlK6Home)/resourceGroups/rg-iic-mgmt-01/providers/Microsoft.OperationalInsights/workspaces/law-iic-mgmt-01"

    function Reset-State {
        $global:AzlK6Calls = [System.Collections.Generic.List[string]]::new()
        $global:AzlK6Responder = { param($Line) }
    }
    # The responder gets the az command line (without "az") and returns the text az would print, or @{ Fail = 'text' } for an az error.
    function Use-AzMock {
        Mock az {
            $line = $args -join ' '
            $global:AzlK6Calls.Add($line)
            $answer = & $global:AzlK6Responder $line
            if ($answer -is [hashtable] -and $answer.ContainsKey('Fail')) { $global:LASTEXITCODE = 1; return $answer.Fail }
            $global:LASTEXITCODE = 0
            $answer
        }
    }
    function New-InfraFile {
        param([scriptblock]$Change, [object]$Tenant = $global:AzlK6Tenant)
        $doc = [ordered]@{
            azure       = [ordered]@{ subscription_id = $global:AzlK6Home; resource_group = 'rg-iic-azl-01'; location = 'eastus' }
            scenario    = [ordered]@{ environment_class = 'production' }
            tags        = [ordered]@{ Project = 'azl'; Owner = 'ops' }
            landing_zone = [ordered]@{
                subscriptions   = @([ordered]@{ name = 'sub-iic-mgmt'; id = $global:AzlK6Sub })
                resource_groups = @([ordered]@{ name = 'rg-iic-mgmt-01'; subscription = 'sub-iic-mgmt' })
                networks        = @([ordered]@{
                        name = 'vnet-iic-hub-01'; subscription = 'sub-iic-mgmt'; resource_group = 'rg-iic-mgmt-01'; address_space = @('198.51.100.0/24')
                        subnets = @([ordered]@{ name = 'GatewaySubnet'; prefix = '198.51.100.0/27' }, [ordered]@{ name = 'snet-iic-mgmt'; prefix = '198.51.100.64/27'; network_security_group = 'nsg-iic-mgmt-01' })
                    })
                connectivity    = [ordered]@{
                    vpn_gateway = [ordered]@{ name = 'vpngw-iic-01'; network = 'vnet-iic-hub-01'; sku = 'VpnGw2AZ'; bgp_asn = 65515
                        site_to_site = @([ordered]@{ connection_name = 'conn-iic-onprem-01'; peer_bgp_address = '169.254.21.1' }, [ordered]@{ connection_name = 'conn-iic-onprem-02' }) }
                    bastion     = [ordered]@{ name = 'bas-iic-01'; network = 'vnet-iic-hub-01'; sku = 'Standard' }
                    nat_gateway = [ordered]@{ name = 'natgw-iic-01'; network = 'vnet-iic-hub-01' }
                }
                virtual_machines = @([ordered]@{ name = 'vm-iic-util-01'; subscription = 'sub-iic-mgmt'; resource_group = 'rg-iic-mgmt-01' })
            }
            key_vaults  = @([ordered]@{ name = 'kv-iic-mgmt-01'; subscription_id = $global:AzlK6Sub; resource_group = 'rg-iic-mgmt-01'; soft_delete_retention_days = 30 })
            operations  = [ordered]@{ monitoring = [ordered]@{ enabled = $true; log_analytics_workspace = 'law-iic-mgmt-01'; workspace_resource_group = 'rg-iic-mgmt-01'; retention_days = 30 } }
        }
        if ($null -eq $Tenant) { $doc.azure.Remove('tenant_id') } else { $doc.azure.tenant_id = $Tenant }
        if ($Change) { & $Change $doc }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Tool([string]$Script, [string]$File) {
        $global:LASTEXITCODE = $null
        $all = & $Script -InfrastructureFile $File 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Check'] -and $_ -isnot [string] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Pattern) { @($global:AzlK6Calls | Where-Object { $_ -match $Pattern }) }
    # A healthy deployment: what az prints for each read. A test changes one answer and runs again.
    $global:AzlK6Healthy = {
        param($Line)
        if ($Line -like 'account show*') { return $global:AzlK6Tenant }
        if ($Line -like 'group show*') { return '{"state":"Succeeded"}' }
        if ($Line -like 'network vnet show*') { return '{"state":"Succeeded","prefixes":["198.51.100.0/24"],"subnets":[{"name":"GatewaySubnet","prefix":"198.51.100.0/27","prefixes":null,"nsg":null},{"name":"snet-iic-mgmt","prefix":"198.51.100.64/27","prefixes":null,"nsg":"/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg-iic-mgmt-01"}]}' }
        if ($Line -like 'network vnet-gateway show*--query id*') { return '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/virtualNetworkGateways/vpngw-iic-01' }
        if ($Line -like 'network vnet-gateway show*') { return '{"state":"Succeeded","type":"Vpn","sku":"VpnGw2AZ","asn":65515,"bgp":true}' }
        if ($Line -like 'network vnet-gateway list-bgp-peer-status*') { return '{"value":[{"neighbor":"169.254.21.1","asn":65001,"state":"Connected","routesReceived":3}]}' }
        if ($Line -like 'network vpn-connection show*') { return '{"status":"Connected","state":"Succeeded"}' }
        if ($Line -like 'network bastion show*--query id*') { return '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/bastionHosts/bas-iic-01' }
        if ($Line -like 'network bastion show*') { return '{"state":"Succeeded","sku":"Standard"}' }
        if ($Line -like 'network nat gateway show*') { return '{"state":"Succeeded"}' }
        if ($Line -like 'keyvault show*--query id*') { return '/subscriptions/x/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv-iic-mgmt-01' }
        if ($Line -like 'keyvault show*') { return '{"state":"Succeeded","softDelete":true,"retention":30,"purge":true,"network":"Enabled"}' }
        if ($Line -like 'keyvault secret list*') { return '[]' }
        if ($Line -like 'monitor log-analytics workspace show*') { return (@{ id = $global:AzlK6Workspace; state = 'Succeeded'; retention = 30 } | ConvertTo-Json -Compress) }
        if ($Line -like 'monitor diagnostic-settings list*') { return (@{ value = @(@{ name = 'send-to-law'; workspaceId = $global:AzlK6Workspace; logs = @(@{ category = 'AuditEvent'; enabled = $true }) }) } | ConvertTo-Json -Depth 6 -Compress) }
        if ($Line -like 'resource list*') { return '[{"name":"vpngw-iic-01","tags":{"Project":"azl","Owner":"ops"}},{"name":"kv-iic-mgmt-01","tags":{"Project":"azl","Owner":"ops","Extra":"x"}}]' }
        if ($Line -like 'vm show*') { return '{"state":"Succeeded","power":"VM running"}' }
    }
}

AfterAll { Remove-Variable -Name AzlK6Tenant, AzlK6Sub, AzlK6Home, AzlK6Workspace, AzlK6Healthy, AzlK6Calls, AzlK6Responder -Scope Global -ErrorAction SilentlyContinue }

Describe 'the Azure CLI validation scripts, all of them' {
    BeforeEach { Reset-State; Use-AzMock; $global:AzlK6Responder = $global:AzlK6Healthy }

    It '<Name> carries the standard header, reads only infrastructure.yml, never prompts and only reads' -ForEach @(
        @{ Name = 'Resources' }, @{ Name = 'Connectivity' }, @{ Name = 'Configuration' }) {
        $path = (Get-Variable -Name $Name -Scope Script).Value
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Match 'Import-AzlInfrastructure'
        $text | Should -Not -Match 'Read-Host|Get-Credential|Connect-AzAccount|az login(?! --tenant)'
        $text | Should -Not -Match 'NOT IMPLEMENTED|SupportsShouldProcess'
        $text | Should -Not -MatchExactly "'(create|delete|update|set|add|register|remove|start|stop|restart|deallocate)'"
        (Get-Command $path).Parameters.Keys | Should -Not -Contain 'WhatIf'
    }

    It '<Name> stops with exit code 1 when az is not signed in, is signed in to another tenant or is not installed, and with exit code 2 for a file without a tenant' -ForEach @(
        @{ Name = 'Resources' }, @{ Name = 'Connectivity' }, @{ Name = 'Configuration' }) {
        $path = (Get-Variable -Name $Name -Scope Script).Value
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return @{ Fail = 'Please run az login' } } }
        $r = Invoke-Tool $path (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'az login'
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $path (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlK6Calls.Count | Should -Be 2
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        (Invoke-Tool $path (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlK6Calls.Clear()
        (Invoke-Tool $path (New-InfraFile -Tenant $null)).ExitCode | Should -Be 2
        $global:AzlK6Calls.Count | Should -Be 0
    }

    It '<Name> calls only read commands of az, in the subscriptions of the file' -ForEach @(
        @{ Name = 'Resources' }, @{ Name = 'Connectivity' }, @{ Name = 'Configuration' }) {
        $path = (Get-Variable -Name $Name -Scope Script).Value
        $r = Invoke-Tool $path (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlK6Calls | Where-Object { $_ -match ' (create|delete|update|set|add|register|remove|start|stop|restart|deallocate)( |$)' }).Count | Should -Be 0
        (Get-Call 'account set').Count | Should -Be 0
        @($global:AzlK6Calls | Where-Object { $_ -match '--subscription (\S+)' -and $Matches[1] -notin $global:AzlK6Sub, $global:AzlK6Home }).Count | Should -Be 0
    }
}

Describe 'Test-ManagementResources.azcli.ps1' {
    BeforeEach { Reset-State; Use-AzMock; $global:AzlK6Responder = $global:AzlK6Healthy }

    It 'passes one check for each resource the file describes when the deployment is healthy' {
        $r = Invoke-Tool $script:Resources (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object Status -EQ 'Pass').Count | Should -Be 8
        @($r.Rows.Check | Select-Object -Unique) | Should -Contain 'VpnGateway'
        (Get-Call "^network vnet-gateway show --resource-group rg-iic-mgmt-01 --name vpngw-iic-01 --subscription $($global:AzlK6Sub) ").Count | Should -Be 1
        (Get-Call "^keyvault show --name kv-iic-mgmt-01 --subscription $($global:AzlK6Sub) --resource-group rg-iic-mgmt-01 ").Count | Should -Be 1
        (Get-Call "^monitor log-analytics workspace show --resource-group rg-iic-mgmt-01 --workspace-name law-iic-mgmt-01 --subscription $($global:AzlK6Home) ").Count | Should -Be 1
    }

    It 'fails for a resource that is missing, and goes on with the rest' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'network bastion show*') { return @{ Fail = "(ResourceNotFound) The Resource 'Microsoft.Network/bastionHosts/bas-iic-01' was not found." } }
            & $global:AzlK6Healthy $Line
        }
        $r = Invoke-Tool $script:Resources (New-InfraFile)
        $r.ExitCode | Should -Be 1
        @($r.Rows | Where-Object Status -EQ 'Fail').Check | Should -Be 'Bastion'
        @($r.Rows | Where-Object Status -EQ 'Fail').Detail | Should -Be 'not found'
        @($r.Rows | Where-Object Status -EQ 'Pass').Count | Should -Be 7
    }

    It 'fails for a SKU, ASN, subnet, address space, network security group, power state and retention that differ from the file' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'network vnet-gateway show*') { return '{"state":"Updating","type":"Vpn","sku":"VpnGw1AZ","asn":65000,"bgp":true}' }
            if ($Line -like 'network vnet show*') { return '{"state":"Succeeded","prefixes":["203.0.113.0/24"],"subnets":[{"name":"GatewaySubnet","prefix":"198.51.100.0/27"},{"name":"snet-iic-mgmt","prefix":"198.51.100.64/27","nsg":null}]}' }
            if ($Line -like 'vm show*') { return '{"state":"Succeeded","power":"VM deallocated"}' }
            if ($Line -like 'monitor log-analytics*') { return '{"state":"Succeeded","retention":90}' }
            & $global:AzlK6Healthy $Line
        }
        $r = Invoke-Tool $script:Resources (New-InfraFile)
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Check -EQ 'VpnGateway').Detail) | Should -Match 'Updating.*VpnGw1AZ.*65000'
        (@($r.Rows | Where-Object Check -EQ 'VirtualNetwork').Detail) | Should -Match 'address space 198\.51\.100\.0/24 is missing.*network security group nsg-iic-mgmt-01'
        (@($r.Rows | Where-Object Check -EQ 'VirtualMachine').Detail) | Should -Match 'VM deallocated'
        (@($r.Rows | Where-Object Check -EQ 'LogAnalytics').Detail) | Should -Match '90 days, the file says 30'
    }

    It 'requires purge protection unless scenario.environment_class is lab, test or dev' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'keyvault show*') { return '{"state":"Succeeded","softDelete":true,"retention":30,"purge":false}' }
            & $global:AzlK6Healthy $Line
        }
        $r = Invoke-Tool $script:Resources (New-InfraFile)
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Check -EQ 'KeyVault').Detail) | Should -Match 'purge protection is off'
        (Invoke-Tool $script:Resources (New-InfraFile { param($d) $d.scenario.environment_class = 'lab' })).ExitCode | Should -Be 0
    }

    It 'ends with exit code 1 and names the error when an az read fails' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'network nat gateway show*') { return @{ Fail = 'AuthorizationFailed: no read access' } }; & $global:AzlK6Healthy $Line }
        $r = Invoke-Tool $script:Resources (New-InfraFile)
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Status -EQ 'Fail').Detail) | Should -Match 'AuthorizationFailed'
    }

    It 'checks only what the file describes and stops with exit code 2 when it describes nothing or a network it does not list' {
        $r = Invoke-Tool $script:Resources (New-InfraFile { param($d) $d.Remove('key_vaults'); $d.Remove('operations'); $d.landing_zone.Remove('virtual_machines'); $d.landing_zone.connectivity.Remove('nat_gateway') })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows).Count | Should -Be 4
        (Invoke-Tool $script:Resources (New-InfraFile { param($d) $d.landing_zone.connectivity.bastion.network = 'vnet-unknown' })).ExitCode | Should -Be 2
        (Invoke-Tool $script:Resources (New-InfraFile { param($d) $d.landing_zone.subscriptions[0].id = '00000000-0000-0000-0000-000000000000' })).ExitCode | Should -Be 2
        (Invoke-Tool $script:Resources (New-InfraFile { param($d) $d.Remove('landing_zone'); $d.azure.Remove('resource_group'); $d.Remove('key_vaults'); $d.Remove('operations') })).ExitCode | Should -Be 2
    }
}

Describe 'Test-ManagementConnectivity.azcli.ps1' {
    BeforeEach { Reset-State; Use-AzMock; $global:AzlK6Responder = $global:AzlK6Healthy }

    It 'passes the connections, the BGP peer and the Bastion host of a healthy deployment' {
        $r = Invoke-Tool $script:Connectivity (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object Status -EQ 'Pass').Count | Should -Be 4
        (Get-Call "^network vpn-connection show --resource-group rg-iic-mgmt-01 --name conn-iic-onprem-02 --subscription $($global:AzlK6Sub) ").Count | Should -Be 1
        (Get-Call '^network vnet-gateway list-bgp-peer-status --resource-group rg-iic-mgmt-01 --name vpngw-iic-01 ').Count | Should -Be 1
        @($r.Rows | Where-Object Check -EQ 'BGP peer').Target | Should -Be '169.254.21.1'
        @($r.Rows | Where-Object Check -EQ 'BGP peer').Detail | Should -Match 'routes received: 3'
    }

    It 'fails while a connection is still connecting, and for a peer that is not connected or not listed' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'network vpn-connection show*') { return '{"status":"Connecting","state":"Succeeded"}' }
            if ($Line -like 'network vnet-gateway list-bgp-peer-status*') { return '{"value":[{"neighbor":"169.254.21.1","state":"Connecting"}]}' }
            & $global:AzlK6Healthy $Line
        }
        $r = Invoke-Tool $script:Connectivity (New-InfraFile)
        $r.ExitCode | Should -Be 1
        @($r.Rows | Where-Object { $_.Check -eq 'VPN connection' -and $_.Status -eq 'Fail' }).Count | Should -Be 2
        @($r.Rows | Where-Object { $_.Check -eq 'VPN connection' }).Detail | Select-Object -First 1 | Should -Match 'Connecting'
        @($r.Rows | Where-Object Check -EQ 'BGP peer').Status | Should -Be 'Fail'
        $global:AzlK6Responder = { param($Line) if ($Line -like 'network vnet-gateway list-bgp-peer-status*') { return '{"value":[]}' }; & $global:AzlK6Healthy $Line }
        $r = Invoke-Tool $script:Connectivity (New-InfraFile)
        $r.ExitCode | Should -Be 1
        @($r.Rows | Where-Object Check -EQ 'BGP peer').Detail | Should -Match 'lists no peer'
    }

    It 'fails for a connection that does not exist and for a peer status that cannot be read' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'network vpn-connection show*conn-iic-onprem-02*') { return @{ Fail = '(ResourceNotFound) The connection was not found.' } }
            if ($Line -like 'network vnet-gateway list-bgp-peer-status*') { return @{ Fail = 'BadRequest: BGP is not enabled' } }
            & $global:AzlK6Healthy $Line
        }
        $r = Invoke-Tool $script:Connectivity (New-InfraFile)
        $r.ExitCode | Should -Be 1
        @($r.Rows | Where-Object { $_.Status -eq 'Fail' }).Count | Should -Be 2
    }

    It 'tests only the Bastion host when the file has no connection, and stops with exit code 2 when it has neither' {
        $r = Invoke-Tool $script:Connectivity (New-InfraFile { param($d) $d.landing_zone.connectivity.vpn_gateway.Remove('site_to_site') })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows).Count | Should -Be 1
        (Invoke-Tool $script:Connectivity (New-InfraFile { param($d) $d.landing_zone.connectivity.vpn_gateway.Remove('site_to_site'); $d.landing_zone.connectivity.Remove('bastion') })).ExitCode | Should -Be 2
        (Invoke-Tool $script:Connectivity (New-InfraFile { param($d) $d.landing_zone.connectivity.vpn_gateway.network = 'vnet-unknown' })).ExitCode | Should -Be 2
    }
}

Describe 'Test-ManagementConfiguration.azcli.ps1' {
    BeforeEach { Reset-State; Use-AzMock; $global:AzlK6Responder = $global:AzlK6Healthy }

    It 'passes the Key Vault, the workspace, the diagnostic settings and the tags of a healthy deployment, and writes no secret' {
        $r = Invoke-Tool $script:Configuration (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object Status -EQ 'Pass').Count | Should -Be 6
        (Get-Call '^keyvault secret list --vault-name kv-iic-mgmt-01 ').Count | Should -Be 1
        (Get-Call 'keyvault secret set').Count | Should -Be 0
        (Get-Call '^monitor diagnostic-settings list --resource /subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/virtualNetworkGateways/vpngw-iic-01 ').Count | Should -Be 1
        (Get-Call "^resource list --resource-group rg-iic-mgmt-01 --subscription $($global:AzlK6Sub) ").Count | Should -Be 1
    }

    It 'fails when the secret list cannot be read, with the reason' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'keyvault secret list*') { return @{ Fail = 'Forbidden: the caller is not authorized to perform the action' } }; & $global:AzlK6Healthy $Line }
        $r = Invoke-Tool $script:Configuration (New-InfraFile)
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Check -EQ 'Key Vault').Detail) | Should -Match 'secret list cannot be read.*Forbidden'
    }

    It 'fails for a missing diagnostic setting, a setting that sends nothing to the workspace of the file, and a resource without the tags' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'monitor diagnostic-settings list*virtualNetworkGateways*') { return '{"value":[]}' }
            if ($Line -like 'monitor diagnostic-settings list*bastionHosts*') { return '[{"name":"other","workspaceId":"/subscriptions/x/workspaces/another","logs":[{"enabled":true}]}]' }
            if ($Line -like 'resource list*') { return '[{"name":"vpngw-iic-01","tags":{"Project":"azl"}},{"name":"nic-01","tags":null},{"name":"kv-iic-mgmt-01","tags":{"Project":"azl","Owner":"ops"}}]' }
            & $global:AzlK6Healthy $Line
        }
        $r = Invoke-Tool $script:Configuration (New-InfraFile)
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Check -EQ 'VPN gateway diagnostic settings').Detail) | Should -Match 'no diagnostic setting'
        (@($r.Rows | Where-Object Check -EQ 'Azure Bastion diagnostic settings').Detail) | Should -Match 'workspace of the file'
        (@($r.Rows | Where-Object Check -EQ 'Key Vault diagnostic settings').Status) | Should -Be 'Pass'
        (@($r.Rows | Where-Object Check -EQ 'Tags').Detail) | Should -Match '2 of 3 resource.*vpngw-iic-01 \(Owner\).*nic-01 \(Project, Owner\)'
    }

    It 'reports a resource group that has no resources as passed and one that does not exist as failed' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'resource list*') { return '[]' }; & $global:AzlK6Healthy $Line }
        (@((Invoke-Tool $script:Configuration (New-InfraFile)).Rows | Where-Object Check -EQ 'Tags').Status) | Should -Be 'Pass'
        $global:AzlK6Responder = { param($Line) if ($Line -like 'resource list*') { return @{ Fail = '(ResourceGroupNotFound) Resource group could not be found.' } }; & $global:AzlK6Healthy $Line }
        $r = Invoke-Tool $script:Configuration (New-InfraFile)
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Check -EQ 'Tags').Detail) | Should -Match 'was not found'
    }

    It 'checks only what the file describes and stops with exit code 2 when it describes nothing' {
        $r = Invoke-Tool $script:Configuration (New-InfraFile { param($d) $d.Remove('tags'); $d.Remove('operations'); $d.landing_zone.Remove('connectivity') })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object Check -EQ 'Key Vault').Count | Should -Be 1
        @($r.Rows | Where-Object Check -EQ 'Tags').Count | Should -Be 0
        (Invoke-Tool $script:Configuration (New-InfraFile { param($d) $d.Remove('tags'); $d.Remove('operations'); $d.Remove('key_vaults'); $d.landing_zone.Remove('connectivity') })).ExitCode | Should -Be 2
        (Invoke-Tool $script:Configuration (New-InfraFile { param($d) $d.operations.monitoring.Remove('workspace_resource_group') })).ExitCode | Should -Be 2
    }
}
