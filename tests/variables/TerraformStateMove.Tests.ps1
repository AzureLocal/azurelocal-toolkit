#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# D121 leftover: New-TerraformStateMoveList.ps1 lists the terraform state mv commands that move a landing zone state written by the old
# role-named module to the name-keyed addresses of the current one. No Terraform is run; the subscription ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/TerraformStateMove.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'New-TerraformStateMoveList.ps1')
    Import-Module powershell-yaml
    $script:Ids = @{}
    foreach ($k in 'connectivity', 'identity', 'management', 'security', 'instance') { $script:Ids[$k] = [guid]::NewGuid().ToString() }

    function New-LzFile([scriptblock]$Change) {
        $doc = [ordered]@{
            azure        = [ordered]@{ subscription_id = $script:Ids.instance }
            landing_zone = [ordered]@{
                management_groups = @(
                    [ordered]@{ name = 'mg-iic'; role = 'root' }
                    [ordered]@{ name = 'mg-iic-platform'; parent = 'mg-iic'; role = 'platform' }
                    [ordered]@{ name = 'mg-iic-identity'; parent = 'mg-iic-platform'; role = 'identity' }
                    [ordered]@{ name = 'mg-iic-connectivity'; parent = 'mg-iic-platform'; role = 'connectivity' }
                    [ordered]@{ name = 'mg-iic-management'; parent = 'mg-iic-platform'; role = 'management' }
                    [ordered]@{ name = 'mg-iic-security'; parent = 'mg-iic-platform'; role = 'security' }
                    [ordered]@{ name = 'mg-iic-landingzones'; parent = 'mg-iic'; role = 'landing_zones' }
                )
                subscriptions     = @(
                    [ordered]@{ name = 'sub-iic-connectivity'; id = $script:Ids.connectivity; role = 'connectivity'; management_group = 'mg-iic-connectivity' }
                    [ordered]@{ name = 'sub-iic-identity'; id = $script:Ids.identity; role = 'identity'; management_group = 'mg-iic-identity' }
                    [ordered]@{ name = 'sub-iic-management'; id = $script:Ids.management; role = 'management'; management_group = 'mg-iic-management' }
                    [ordered]@{ name = 'sub-iic-security'; id = $script:Ids.security; role = 'security' }
                    [ordered]@{ name = 'sub-iic-azl'; id = $script:Ids.instance; role = 'workload'; management_group = 'mg-iic-landingzones' }
                )
            }
        }
        if ($Change) { & $Change $doc }
        $file = Join-Path $TestDrive "lz-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-List([string]$File, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = & $script:Script -InfrastructureFile $File @Extra 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Rows = @($all | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Kind'] }); Text = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n") }
    }
}

Describe 'New-TerraformStateMoveList.ps1' {
    It 'moves every role-named group to the level and name key the module computes' {
        $r = Invoke-List (New-LzFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $m = @{}; foreach ($row in $r.Rows) { $m[$row.From] = $row }
        $m['module.landing_zone.azurerm_management_group.root'].To | Should -Be 'module.landing_zone.azurerm_management_group.level0["mg-iic"]'
        $m['module.landing_zone.azurerm_management_group.platform'].To | Should -Be 'module.landing_zone.azurerm_management_group.level1["mg-iic-platform"]'
        $m['module.landing_zone.azurerm_management_group.landing_zones'].To | Should -Be 'module.landing_zone.azurerm_management_group.level1["mg-iic-landingzones"]'
        foreach ($role in 'identity', 'connectivity', 'management', 'security') { $m["module.landing_zone.azurerm_management_group.$role"].To | Should -Be "module.landing_zone.azurerm_management_group.level2[""mg-iic-$role""]" }
        $m['module.landing_zone.azurerm_management_group.root'].Command | Should -Be "terraform state mv 'module.landing_zone.azurerm_management_group.root' 'module.landing_zone.azurerm_management_group.level0[""mg-iic""]'"
    }
    It 'moves the role associations and the azure_local association to the subscription name keys, and forgets the one the module no longer makes' {
        $r = Invoke-List (New-LzFile)
        $m = @{}; foreach ($row in $r.Rows) { $m[$row.From] = $row }
        $a = 'module.landing_zone.azurerm_management_group_subscription_association'
        $m["$a.connectivity[0]"].To | Should -Be "$a.subscriptions[""sub-iic-connectivity""]"
        $m["$a.identity[0]"].To | Should -Be "$a.subscriptions[""sub-iic-identity""]"
        $m["$a.management[0]"].To | Should -Be "$a.subscriptions[""sub-iic-management""]"
        $m["$a.azure_local[0]"].To | Should -Be "$a.subscriptions[""sub-iic-azl""]"
        $m["$a.security[0]"].Kind | Should -Be 'Forget'
        $m["$a.security[0]"].Command | Should -Be "terraform state rm '$a.security[0]'"
        $m["$a.security[0]"].Note | Should -Match 'keeps the association in Azure'
    }
    It 'lists an association the old module never made (no subscription for the role) as None, without a command' {
        $r = Invoke-List (New-LzFile { param($d) $d.landing_zone.subscriptions = @($d.landing_zone.subscriptions | Where-Object { $_.role -ne 'identity' }) })
        $r.ExitCode | Should -Be 0
        $row = @($r.Rows | Where-Object From -EQ 'module.landing_zone.azurerm_management_group_subscription_association.identity[0]')[0]
        $row.Kind | Should -Be 'None'; $row.Command | Should -BeNullOrEmpty
    }
    It 'compares parent names case-sensitively, as Terraform does' {
        $r = Invoke-List (New-LzFile { param($d) $d.landing_zone.management_groups[1].parent = 'MG-IIC' })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object From -EQ 'module.landing_zone.azurerm_management_group.platform')[0].To | Should -Be 'module.landing_zone.azurerm_management_group.level0["mg-iic-platform"]'
    }
    It 'reports a role no group has as Check, without a command' {
        $r = Invoke-List (New-LzFile { param($d) $d.landing_zone.management_groups = @($d.landing_zone.management_groups | Where-Object { $_.role -ne 'security' }) })
        $r.ExitCode | Should -Be 0
        $row = @($r.Rows | Where-Object From -EQ 'module.landing_zone.azurerm_management_group.security')[0]
        $row.Kind | Should -Be 'Check'; $row.Command | Should -BeNullOrEmpty
    }
    It 'refuses (exit 2) a file without management groups, two groups with one role, and a parent chain that loops' {
        (Invoke-List (New-LzFile { param($d) $d.landing_zone.Remove('management_groups') })).ExitCode | Should -Be 2
        (Invoke-List (New-LzFile { param($d) $d.landing_zone.management_groups[2].role = 'platform' })).ExitCode | Should -Be 2
        $loop = Invoke-List (New-LzFile { param($d) $d.landing_zone.management_groups += [ordered]@{ name = 'mg-a'; parent = 'mg-b' }; $d.landing_zone.management_groups += [ordered]@{ name = 'mg-b'; parent = 'mg-a' } })
        $loop.ExitCode | Should -Be 2; $loop.Text | Should -Match 'loops'
    }
    It 'writes the commands to -OutputPath, and nothing under -WhatIf' {
        $out = Join-Path $TestDrive 'moves.txt'
        $null = Invoke-List (New-LzFile) @{ OutputPath = $out; WhatIf = $true }
        Test-Path -LiteralPath $out | Should -BeFalse
        $r = Invoke-List (New-LzFile) @{ OutputPath = $out }
        $r.ExitCode | Should -Be 0
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match "terraform state mv 'module.landing_zone.azurerm_management_group.root'"
        $text | Should -Match "terraform state rm 'module.landing_zone.azurerm_management_group_subscription_association.security\[0\]'"
    }
    It 'matches the module: the old role resources are gone, the level and subscriptions resources exist' {
        $tf = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'src', 'terraform', 'modules', 'landing-zone', 'main.tf')) -Raw
        foreach ($l in 0..5) { $tf | Should -Match "resource ""azurerm_management_group"" ""level$l""" }
        $tf | Should -Match 'resource "azurerm_management_group_subscription_association" "subscriptions"'
        $tf | Should -Not -Match 'resource "azurerm_management_group" "root"'
        (Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'src', 'terraform', 'environments', 'azure-local', 'main.tf')) -Raw) | Should -Match 'module "landing_zone"'
    }
    It 'carries the standard header and never prompts' {
        $text = Get-Content -LiteralPath $script:Script -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Not -Match 'Read-Host|Get-Credential'
    }
}
