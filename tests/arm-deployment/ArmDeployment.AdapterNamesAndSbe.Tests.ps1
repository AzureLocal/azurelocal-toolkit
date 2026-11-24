#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# K1 (the OS adapter names come from the ZTP handoff by MAC, and a port the intents use without a network_adapters entry is a warning in Validate and a problem in Deploy)
# and K2 (an SBE version without family or publisher). Reads files only; no Azure call.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/arm-deployment/ArmDeployment.AdapterNamesAndSbe.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\azure-local\AzlAzure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\arm-deployment\AzlArmDeployment.psm1') -Force
    Import-Module powershell-yaml
    $script:Fixture = Join-Path $repo 'tests\fixtures\infrastructure.fc-san.yml'
    $script:Catalog = Get-AzlArmTemplateCatalog

    function Get-Infra { Import-AzlInfrastructure -Path $script:Fixture -SkipValidation }
    # The file calls its ports 'Slot PortN'; the nodes call them PortN. The ZTP handoff reports the OS names by MAC.
    function Get-SlotInfra {
        $infra = Get-Infra
        foreach ($n in $infra.nodes) { foreach ($a in $n.network_adapters) { $a.name = "Slot $($a.name)" } }
        $infra.networking.intents[0].adapters = @('Slot Port0', 'Slot Port1')
        $infra.networking.cluster_networks[0].adapter = 'Slot Port2'; $infra.networking.cluster_networks[1].adapter = 'Slot Port3'
        $infra
    }
    function Get-PortHandoff([System.Collections.IDictionary]$Infra) {
        $nodes = @{}
        foreach ($n in $Infra.nodes) {
            $adapters = @($n.network_adapters | ForEach-Object { [pscustomobject]@{ name = ([string]$_.name -replace '^Slot ', ''); macAddress = ([string]$_.mac_address); fileName = [string]$_.name } })
            $nodes[([string]$n.name).ToLowerInvariant()] = [pscustomobject]@{ name = [string]$n.name; arcMachineResourceId = ''; networkAdapters = $adapters }
        }
        [pscustomobject]@{ SchemaVersion = 2; Nodes = $nodes; Raw = $null }
    }
}

Describe 'K1: adapter names from the ZTP handoff networkAdapters, by MAC' {
    It 'sends the OS names the handoff reports when there is no OS configuration report' {
        $infra = Get-SlotInfra
        $set = New-AzlArmParameterSet -Infrastructure $infra -Handoff (Get-PortHandoff $infra) -AllowUnresolvedSanLun -Catalog $script:Catalog
        @($set.Parameters.intentList[0].adapter) | Should -Be @('Port0', 'Port1')
        $set.Parameters.sanNetworkList.clusterNetworkConfig.adapterIPConfig[0].networkAdapterName | Should -Be 'Port2'
        ($set.Warnings -join "`n") | Should -Not -Match 'was not read from the node'
    }
    It 'prefers the OS configuration report over the handoff for a node the report lists' {
        $infra = Get-SlotInfra
        $handoff = Get-PortHandoff $infra
        foreach ($a in $handoff.Nodes['iic-n01'].networkAdapters) { $a.name = "Wrong$($a.name)" }
        $map = @{ 'iic-n01' = @{ '00005e005310' = 'Port0'; '00005e005311' = 'Port1'; '00005e005312' = 'Port2'; '00005e005313' = 'Port3' }; 'iic-n02' = @{ '00005e005320' = 'Port0'; '00005e005321' = 'Port1'; '00005e005322' = 'Port2'; '00005e005323' = 'Port3' } }
        $set = New-AzlArmParameterSet -Infrastructure $infra -Handoff $handoff -AdapterMap $map -AllowUnresolvedSanLun -Catalog $script:Catalog
        @($set.Parameters.intentList[0].adapter) | Should -Be @('Port0', 'Port1')
    }
    It 'warns that nothing was read when there is neither a report nor handoff adapters, and says so in the words of what is missing' {
        $infra = Get-SlotInfra
        $set = New-AzlArmParameterSet -Infrastructure $infra -AllowUnresolvedSanLun -Catalog $script:Catalog
        ($set.Warnings -join "`n") | Should -Match 'no OS configuration report and no ZTP handoff networkAdapters for the node'
        @($set.Parameters.intentList[0].adapter) | Should -Be @('Slot Port0', 'Slot Port1')
    }
    It 'names the report it read when the report has no ports for a node' {
        $infra = Get-Infra
        $map = @{ 'iic-n01' = @{ '00005e005310' = 'Port0'; '00005e005311' = 'Port1'; '00005e005312' = 'Port2'; '00005e005313' = 'Port3' } }
        $set = New-AzlArmParameterSet -Infrastructure $infra -AdapterMap $map -AdapterMapSource 'D:\run\osconfig-out\report.json' -AllowUnresolvedSanLun -Catalog $script:Catalog
        $text = $set.Warnings -join "`n"
        $text | Should -Match "Node iic-n02: OS configuration report 'D:\\run\\osconfig-out\\report.json' lists no ports for the node"
        $text | Should -Not -Match 'Node iic-n01: .*not read'
    }
    It 'a port the handoff does not list keeps the file name with a warning that names the handoff; a report that lacks the MAC still throws' {
        $infra = Get-Infra
        $handoff = Get-PortHandoff $infra
        $handoff.Nodes['iic-n02'].networkAdapters = @($handoff.Nodes['iic-n02'].networkAdapters | Where-Object { $_.name -ne 'Port1' })
        $set = New-AzlArmParameterSet -Infrastructure $infra -Handoff $handoff -AllowUnresolvedSanLun -Catalog $script:Catalog
        ($set.Warnings -join "`n") | Should -Match "Port Port1 on iic-n02: the ZTP handoff networkAdapters of the node has no port with MAC 00005e005321"
        @($set.Parameters.intentList[0].adapter) | Should -Be @('Port0', 'Port1')
        $map = @{ 'iic-n01' = @{ '00005e005310' = 'Port0'; '00005e005311' = 'Port1'; '00005e005312' = 'Port2'; '00005e005313' = 'Port3' }; 'iic-n02' = @{ '00005e005320' = 'Port0' } }
        { New-AzlArmParameterSet -Infrastructure $infra -AdapterMap $map -AllowUnresolvedSanLun -Catalog $script:Catalog } | Should -Throw '*has no port with that MAC*'
    }
}

Describe 'K1: a port the intents use without a network_adapters entry' {
    It 'is a warning in the parameter set and a problem only for a Deploy' {
        $infra = Get-Infra
        $infra.nodes[1].network_adapters = @($infra.nodes[1].network_adapters | Where-Object { $_.name -ne 'Port1' })
        $set = New-AzlArmParameterSet -Infrastructure $infra -AllowUnresolvedSanLun -Catalog $script:Catalog
        ($set.Warnings -join "`n") | Should -Match "Node iic-n02: port 'Port1' is used by a network intent or storage network, but nodes\[\]\.network_adapters has no entry"
        $definitions = $script:Catalog.templates[$set.Template.Name].parameters
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $definitions) | Should -Not -Match 'network_adapters has no entry'
        $deploy = @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $definitions -Deploy)
        $deploy.Count | Should -BeGreaterThan 0
        ($deploy -join "`n") | Should -Match 'iic-n02: port ''Port1'''
    }
    It 'is clean when every port is listed' {
        $set = New-AzlArmParameterSet -Infrastructure (Get-Infra) -AllowUnresolvedSanLun -Catalog $script:Catalog
        @($set.Gaps).Count | Should -Be 0
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $script:Catalog.templates[$set.Template.Name].parameters -Deploy) | Should -Not -Match 'network_adapters'
    }
}

Describe 'K2: an SBE version without family or publisher' {
    It 'is a warning for a Validate and a problem for a Deploy' {
        $infra = Get-Infra
        $infra.hardware.sbe = [ordered]@{ version = '4.1.2606.1' }
        $set = New-AzlArmParameterSet -Infrastructure $infra -AllowUnresolvedSanLun -Catalog $script:Catalog
        $set.Parameters.sbeVersion | Should -Be '4.1.2606.1'
        ($set.Warnings -join "`n") | Should -Match 'hardware\.sbe\.version is ''4\.1\.2606\.1'' but hardware\.sbe\.family and hardware\.sbe\.publisher are empty'
        $definitions = $script:Catalog.templates[$set.Template.Name].parameters
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $definitions) | Should -Not -Match 'hardware\.sbe\.version'
        (@(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $definitions -Deploy) -join "`n") | Should -Match 'hardware\.sbe\.family and hardware\.sbe\.publisher are empty'
    }
    It 'names only the missing one' {
        $infra = Get-Infra
        $infra.hardware.sbe = [ordered]@{ version = '4.1.2606.1'; family = 'Example-Family' }
        $set = New-AzlArmParameterSet -Infrastructure $infra -AllowUnresolvedSanLun -Catalog $script:Catalog
        ($set.Warnings -join "`n") | Should -Match 'but hardware\.sbe\.publisher is empty'
    }
    It 'is clean when a readable bundle supplies family and publisher' {
        $infra = Get-Infra
        $infra.hardware.sbe = [ordered]@{ version = '4.1.2606.1' }
        $bundle = [ordered]@{ sbeVersion = '4.1.2606.1'; sbeFamily = 'Example-Family'; sbePublisher = 'Example'; sbeManifestSource = 'https://example.invalid/m'; sbeManifestCreationDate = '2026-10-21' }
        $set = New-AzlArmParameterSet -Infrastructure $infra -AllowUnresolvedSanLun -Catalog $script:Catalog -SbeDeployment $bundle
        @($set.Gaps).Count | Should -Be 0
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $script:Catalog.templates[$set.Template.Name].parameters -Deploy) | Should -Not -Match 'hardware\.sbe'
    }
}
