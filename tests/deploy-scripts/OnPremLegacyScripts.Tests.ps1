#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 of the on-premises readiness (Active Directory), task 01: the three validation scripts find the domain controller VM in
# landing_zone.virtual_machines[] (the entry with role domain_controller) instead of the old key compute.azure_vms.dc01, and take the region
# from the file instead of a default. The function that finds the VM is taken out of each script by the parser and run against a file in
# TestDrive; nothing reaches Azure or Active Directory.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/OnPremLegacyScripts.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = [IO.Path]::Combine($repoRoot, 'scripts', 'deploy', '03-onprem-readiness', 'phase-01-active-directory', 'task-01-ou-creation-pre-creation-artifacts', 'powershell')
    $script:Cases = @(
        @{ Name = 'Invoke-ADValidation-Arc.ps1'; Path = [IO.Path]::Combine($dir, 'Invoke-ADValidation-Arc.ps1') }
        @{ Name = 'Invoke-ADValidation-AzVM.ps1'; Path = [IO.Path]::Combine($dir, 'Invoke-ADValidation-AzVM.ps1') }
        @{ Name = 'Test-ADConfiguration.ps1'; Path = [IO.Path]::Combine($dir, 'Test-ADConfiguration.ps1') }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))

    function Get-FunctionText([string]$Path, [string]$Name) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1).Extent.Text
    }
    function Get-CodeText([string]$Path) {
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
    }
    function Get-Config {
        param([object[]]$Machines, [object[]]$Groups = @([ordered]@{ name = 'rg-iic-mgmt-01'; location = 'westeurope' }), [string]$Location = 'eastus')
        $doc = [ordered]@{
            azure        = [ordered]@{ location = $Location }
            landing_zone = [ordered]@{ resource_groups = @($Groups); virtual_machines = @($Machines) }
        }
        ConvertFrom-Yaml (ConvertTo-Yaml $doc) -Ordered
    }
    $script:Dc = [ordered]@{ name = 'vm-iic-dc-01'; hostname = 'iic-dc01'; role = 'domain_controller'; resource_group = 'rg-iic-mgmt-01' }
    $script:Jump = [ordered]@{ name = 'vm-iic-jump-01'; hostname = 'iic-jump01'; role = 'jumpbox'; resource_group = 'rg-iic-mgmt-01' }
}

Describe '<Name> finds the domain controller VM in landing_zone.virtual_machines[]' -ForEach $script:Cases {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionText $Path 'Get-DomainControllerVm')))
        $script:Code = Get-CodeText $Path
    }

    It 'takes name, hostname and resource group from the first entry with role domain_controller' {
        $vm = Get-DomainControllerVm -Config (Get-Config -Machines $script:Jump, $script:Dc)
        $vm.Name | Should -Be 'vm-iic-dc-01'
        $vm.HostName | Should -Be 'iic-dc01'
        $vm.ResourceGroup | Should -Be 'rg-iic-mgmt-01'
    }
    It 'takes the region of the resource group from landing_zone.resource_groups[]' {
        (Get-DomainControllerVm -Config (Get-Config -Machines $script:Dc)).Location | Should -Be 'westeurope'
    }
    It 'falls back to azure.location when the resource group has no region, and to nothing when the file has none' {
        (Get-DomainControllerVm -Config (Get-Config -Machines $script:Dc -Groups @([ordered]@{ name = 'rg-iic-mgmt-01' }))).Location | Should -Be 'eastus'
        (Get-DomainControllerVm -Config (Get-Config -Machines $script:Dc -Groups @([ordered]@{ name = 'rg-iic-mgmt-01' }) -Location '')).Location | Should -BeNullOrEmpty
    }
    It 'uses the VM name when the entry has no hostname' {
        $noHost = [ordered]@{ name = 'vm-iic-dc-01'; role = 'domain_controller'; resource_group = 'rg-iic-mgmt-01' }
        (Get-DomainControllerVm -Config (Get-Config -Machines $noHost)).HostName | Should -Be 'vm-iic-dc-01'
    }
    It 'returns nothing when the file has no domain controller, or no landing zone' {
        Get-DomainControllerVm -Config (Get-Config -Machines $script:Jump) | Should -BeNullOrEmpty
        Get-DomainControllerVm -Config ([ordered]@{ azure = [ordered]@{ location = 'eastus' } }) | Should -BeNullOrEmpty
    }
    It 'reads no old-layout key and has no region in its code' {
        $script:Code | Should -Not -Match 'azure_vms'
        $script:Code | Should -Not -Match '"eastus"|''eastus'''
    }
}

Describe 'The keys the three scripts read are in the registry' {
    It '<_>' -ForEach 'landing_zone.virtual_machines', 'landing_zone.virtual_machines[].role', 'landing_zone.virtual_machines[].name', 'landing_zone.virtual_machines[].hostname', 'landing_zone.virtual_machines[].resource_group', 'landing_zone.resource_groups[].name', 'landing_zone.resource_groups[].location', 'azure.location', 'identity.active_directory.domain_fqdn' {
        @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
    }
}
