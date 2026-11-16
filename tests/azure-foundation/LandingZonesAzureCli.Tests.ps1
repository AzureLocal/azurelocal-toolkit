#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 (landing zones), full deployment, tasks 01 to 03, Azure CLI variants: Deploy-ManagementGroups.azcli.ps1, Set-ManagementGroupDisplayNames.azcli.ps1,
# Deploy-Subscriptions.azcli.ps1, Invoke-SubscriptionMove-Orchestrated.azcli.ps1 and Deploy-ResourceGroups.azcli.ps1. Each takes its values from
# infrastructure.yml and calls az. The az command is replaced by a function that records the call: no Azure, no tenant and no sign-in is used.
# Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/LandingZonesAzureCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the az command.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-01-landing-zones', 'full-deployment')
    $script:MgCreate = [IO.Path]::Combine($dir, 'task-01-configure-management-groups', 'azurecli', 'Deploy-ManagementGroups.azcli.ps1')
    $script:MgRename = [IO.Path]::Combine($dir, 'task-01-configure-management-groups', 'azurecli', 'Set-ManagementGroupDisplayNames.azcli.ps1')
    $script:SubCreate = [IO.Path]::Combine($dir, 'task-02-create-subscriptions', 'azurecli', 'Deploy-Subscriptions.azcli.ps1')
    $script:SubMove = [IO.Path]::Combine($dir, 'task-02-create-subscriptions', 'azurecli', 'Invoke-SubscriptionMove-Orchestrated.azcli.ps1')
    $script:RgCreate = [IO.Path]::Combine($dir, 'task-03-create-resource-groups', 'azurecli', 'Deploy-ResourceGroups.azcli.ps1')
    Import-Module powershell-yaml

    function az { }

    $global:AzlK6Tenant = [guid]::NewGuid().ToString()
    $global:AzlK6Home = [guid]::NewGuid().ToString()
    $global:AzlK6SubA = [guid]::NewGuid().ToString()
    $global:AzlK6SubB = [guid]::NewGuid().ToString()
    $global:AzlK6Scope = '/providers/Microsoft.Billing/billingAccounts/00000000-0000-0000-0000-000000000000:11111111-1111-1111-1111-111111111111_2019-05-31/enrollmentAccounts/1234567'

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
        param([object]$Tenant = $global:AzlK6Tenant, [hashtable]$Azure = @{}, [object]$LandingZone, [object]$Tags)
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $Tenant) { $doc.azure.tenant_id = $Tenant }
        foreach ($k in $Azure.Keys) { $doc.azure[$k] = $Azure[$k] }
        if ($null -ne $LandingZone) { $doc.landing_zone = $LandingZone }
        if ($null -ne $Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Tool([string]$Script, [string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_ -isnot [string] -and $_ -isnot [Management.Automation.InformationRecord] -and $_ -isnot [Management.Automation.WarningRecord] -and $_ -isnot [Management.Automation.ErrorRecord] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Pattern) { @($global:AzlK6Calls | Where-Object { $_ -match $Pattern }) }
    function New-Group([string]$Name, [string]$Display, [string]$Parent) {
        $g = [ordered]@{ name = $Name }
        if ($Display) { $g.display_name = $Display }
        if ($Parent) { $g.parent = $Parent }
        $g
    }
}

AfterAll { Remove-Variable -Name AzlK6Tenant, AzlK6Home, AzlK6SubA, AzlK6SubB, AzlK6Scope, AzlK6Calls, AzlK6Responder -Scope Global -ErrorAction SilentlyContinue }

Describe 'the Azure CLI landing zone scripts, all of them' {
    It '<_> carries the standard header, reads only infrastructure.yml and never prompts' -ForEach @('MgCreate', 'MgRename', 'SubCreate', 'SubMove', 'RgCreate') {
        $path = (Get-Variable -Name $_ -Scope Script).Value
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Match 'SupportsShouldProcess'
        $text | Should -Match 'Import-AzlInfrastructure'
        $text | Should -Not -Match 'Read-Host|Get-Credential|Connect-AzAccount|az login(?! --tenant)'
        $text | Should -Not -Match 'NOT IMPLEMENTED'
    }
}

Describe 'Deploy-ManagementGroups.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'account management-group show*') { return @{ Fail = "(NotFound) Management group '$($Line.Split(' ')[3])' could not be found." } }
        }
        $script:Tree = @((New-Group -Name 'mg-iic-platform' -Display 'Platform' -Parent 'mg-iic'), (New-Group -Name 'mg-iic' -Display 'IIC'), (New-Group -Name 'mg-iic-identity' -Display 'Identity' -Parent 'mg-iic-platform'))
    }

    It 'creates the groups with parents first, and the group without a parent under the tenant root (no --parent)' {
        $r = Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = $script:Tree })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows.ManagementGroup) | Should -Be @('mg-iic', 'mg-iic-platform', 'mg-iic-identity')
        @(Get-Call '^account management-group create') | Should -Be @(
            'account management-group create --name mg-iic --display-name IIC --output none'
            'account management-group create --name mg-iic-platform --display-name Platform --parent mg-iic --output none'
            'account management-group create --name mg-iic-identity --display-name Identity --parent mg-iic-platform --output none')
    }

    It 'creates nothing under -WhatIf and plans every group' {
        $r = Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = $script:Tree }) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'management-group create').Count | Should -Be 0
        @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 3
    }

    It 'leaves a group that exists alone and reports a different display name' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'account management-group show*') { return (@{ displayName = 'Old name'; parent = "/providers/Microsoft.Management/managementGroups/$($global:AzlK6Tenant)" } | ConvertTo-Json -Compress) }
        }
        $r = Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = @((New-Group -Name 'mg-iic' -Display 'IIC')) })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'management-group create').Count | Should -Be 0
        $r.Rows[0].Action | Should -Be 'AlreadyExists'
        $r.Rows[0].Detail | Should -Match "display name is 'Old name'"
    }

    It 'goes on with the other groups when one cannot be created, and ends with exit code 1; a child of a failed parent is not attempted' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'account management-group show*') { return @{ Fail = 'NotFound' } }
            if ($Line -like 'account management-group create --name mg-iic *') { return @{ Fail = 'AuthorizationFailed' } }
        }
        $r = Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = @($script:Tree + (New-Group -Name 'mg-other' -Display 'Other')) })
        $r.ExitCode | Should -Be 1
        @($r.Rows | Where-Object Action -EQ 'Failed').Count | Should -Be 3
        @(Get-Call 'management-group create --name mg-other').Count | Should -Be 1
        (Get-Call 'create --name mg-iic-platform').Count | Should -Be 0
    }

    It 'stops with exit code 1 before any change when az is not signed in, is signed in to another tenant, or is not installed' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return @{ Fail = 'Please run az login to setup account.' } } }
        $r = Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = $script:Tree })
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'az login'
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = $script:Tree })).ExitCode | Should -Be 1
        (Get-Call 'management-group create').Count | Should -Be 0
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        $r = Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = $script:Tree })
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Azure CLI'
    }

    It 'stops with exit code 2 before any az call for a file without a tenant, without groups, with a bad name, an unknown parent or a loop' {
        (Invoke-Tool $script:MgCreate (New-InfraFile -Tenant $null -LandingZone @{ management_groups = $script:Tree })).ExitCode | Should -Be 2
        (Invoke-Tool $script:MgCreate (New-InfraFile)).ExitCode | Should -Be 2
        (Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = @((New-Group -Name 'bad name!' -Display 'X')) })).ExitCode | Should -Be 2
        (Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = @((New-Group -Name 'mg-a' -Display 'A' -Parent 'mg-missing')) })).ExitCode | Should -Be 2
        (Invoke-Tool $script:MgCreate (New-InfraFile -LandingZone @{ management_groups = @((New-Group -Name 'mg-a' -Display 'A' -Parent 'mg-b'), (New-Group -Name 'mg-b' -Display 'B' -Parent 'mg-a')) })).ExitCode | Should -Be 2
        $global:AzlK6Calls.Count | Should -Be 0
    }
}

Describe 'Set-ManagementGroupDisplayNames.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'account management-group show --name mg-iic *') { return 'Old IIC' }
            if ($Line -like 'account management-group show --name mg-ok *') { return 'Fine' }
            if ($Line -like 'account management-group show*') { return @{ Fail = 'NotFound' } }
        }
        $script:Groups = @((New-Group -Name 'mg-iic' -Display 'IIC'), (New-Group -Name 'mg-ok' -Display 'Fine'), (New-Group -Name 'mg-plain'))
    }

    It 'renames only the group whose display name differs, and skips an entry with no display name' {
        $r = Invoke-Tool $script:MgRename (New-InfraFile -LandingZone @{ management_groups = $script:Groups })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-Call 'management-group update') | Should -Be @('account management-group update --name mg-iic --display-name IIC --output none')
        $r.Rows[0].Renamed | Should -Be 1
        $r.Rows[0].AlreadyCorrect | Should -Be 1
        $r.Rows[0].Skipped | Should -Be 1
    }

    It 'changes nothing under -WhatIf' {
        $r = Invoke-Tool $script:MgRename (New-InfraFile -LandingZone @{ management_groups = $script:Groups }) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'management-group update').Count | Should -Be 0
        $r.Rows[0].Planned | Should -Be 1
    }

    It 'fails for a group that does not exist, and stops with exit code 2 for a file without display names or a tenant' {
        $r = Invoke-Tool $script:MgRename (New-InfraFile -LandingZone @{ management_groups = @((New-Group -Name 'mg-missing' -Display 'Missing')) })
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'does not exist'
        (Invoke-Tool $script:MgRename (New-InfraFile -LandingZone @{ management_groups = @((New-Group -Name 'mg-plain')) })).ExitCode | Should -Be 2
        (Invoke-Tool $script:MgRename (New-InfraFile -Tenant 'not-a-guid' -LandingZone @{ management_groups = $script:Groups })).ExitCode | Should -Be 2
    }

    It 'stops with exit code 1 when az is signed in to another tenant' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $script:MgRename (New-InfraFile -LandingZone @{ management_groups = $script:Groups })).ExitCode | Should -Be 1
        (Get-Call 'management-group').Count | Should -Be 0
    }
}

Describe 'Deploy-Subscriptions.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $script:NewId = [guid]::NewGuid().ToString()
        $global:AzlK6NewId = $script:NewId
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'extension list*') { return 'account' }
            if ($Line -like 'account alias show*') { return @{ Fail = '(ResourceNotFound) The alias was not found.' } }
            if ($Line -like 'account alias create*') { return $global:AzlK6NewId }
        }
        $script:Subs = @(
            [ordered]@{ name = 'sub-iic-mgmt'; billing_scope = $global:AzlK6Scope; workload = 'Production'; management_group = 'mg-iic-platform' },
            [ordered]@{ name = 'sub-iic-lab'; billing_scope = $global:AzlK6Scope; workload = 'DevTest' },
            [ordered]@{ name = 'sub-iic-old'; id = $global:AzlK6SubA; management_group = 'mg-iic' })
    }
    AfterAll { Remove-Variable -Name AzlK6NewId -Scope Global -ErrorAction SilentlyContinue }

    It 'creates each subscription without an id with its alias, moves it under its group and tags it, and skips the one that has an id' {
        $r = Invoke-Tool $script:SubCreate (New-InfraFile -Tags ([ordered]@{ Project = 'azl'; Owner = 'ops team' }) -LandingZone @{ subscriptions = $script:Subs })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object Action -EQ 'Created').Count | Should -Be 2
        @($r.Rows | Where-Object Action -EQ 'Skipped').Count | Should -Be 1
        (Get-Call "^account alias create --name sub-iic-mgmt --display-name sub-iic-mgmt --billing-scope $([regex]::Escape($global:AzlK6Scope)) --workload Production").Count | Should -Be 1
        (Get-Call '^account alias create --name sub-iic-lab .* --workload DevTest').Count | Should -Be 1
        @(Get-Call '^account management-group subscription add') | Should -Be @("account management-group subscription add --name mg-iic-platform --subscription $($script:NewId) --output none")
        (Get-Call "^tag update --resource-id /subscriptions/$($script:NewId) --operation Merge --tags Project=azl Owner=ops team").Count | Should -Be 2
        $r.Rows[0].SubscriptionId | Should -Be $script:NewId
    }

    It 'creates nothing under -WhatIf' {
        $r = Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = $script:Subs }) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'alias create|subscription add|tag update').Count | Should -Be 0
        @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 2
    }

    It 'reports an alias that exists and creates nothing for it' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'extension list*') { return 'account' }
            if ($Line -like 'account alias show*') { return $global:AzlK6SubB }
        }
        $r = Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = @($script:Subs[1]) })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Rows[0].Action | Should -Be 'AlreadyExists'
        $r.Rows[0].SubscriptionId | Should -Be $global:AzlK6SubB
        (Get-Call 'alias create').Count | Should -Be 0
    }

    It 'ends with exit code 1 and names the new id when the move under the management group fails' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'extension list*') { return 'account' }
            if ($Line -like 'account alias show*') { return @{ Fail = 'NotFound' } }
            if ($Line -like 'account alias create*') { return $global:AzlK6NewId }
            if ($Line -like 'account management-group subscription add*') { return @{ Fail = 'AuthorizationFailed' } }
        }
        $r = Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = @($script:Subs[0]) })
        $r.ExitCode | Should -Be 1
        $r.Rows[0].Detail | Should -Match $script:NewId
    }

    It 'refuses an id that is not a GUID, and an entry that is not a map, with exit code 2 and no az call' {
        $r = Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = @($script:Subs[0], [ordered]@{ name = 'sub-iic-bad'; id = 'not-a-guid'; management_group = 'mg-iic' }) })
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $r.Text | Should -Match "id 'not-a-guid' is not a GUID"
        $r = Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = @($script:Subs[0], 'sub-iic-oops') })
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $r.Text | Should -Match 'entry of landing_zone.subscriptions is not a map'
        $global:AzlK6Calls.Count | Should -Be 0
    }

    It 'fails the row, and applies no management group or tag, when az returns no subscription id for the new alias' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'extension list*') { return 'account' }
            if ($Line -like 'account alias show*') { return @{ Fail = '(ResourceNotFound) The alias was not found.' } }
            if ($Line -like 'account alias create*') { return 'Accepted' }
        }
        $r = Invoke-Tool $script:SubCreate (New-InfraFile -Tags ([ordered]@{ Project = 'azl' }) -LandingZone @{ subscriptions = @($script:Subs[0]) })
        $r.ExitCode | Should -Be 1
        $r.Rows[0].Action | Should -Be 'Failed'
        $r.Rows[0].Detail | Should -Match 'returned no subscription id'
        (Get-Call 'subscription add|tag update').Count | Should -Be 0
    }

    It 'fails the row for an alias that exists but reports no subscription id yet' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'extension list*') { return 'account' }
            if ($Line -like 'account alias show*') { return '' }
        }
        $r = Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = @($script:Subs[1]) })
        $r.ExitCode | Should -Be 1
        $r.Rows[0].Action | Should -Be 'Failed'
        $r.Rows[0].Detail | Should -Match 'reports no subscription id yet'
    }

    It 'stops with exit code 1 when the account extension is missing, az is signed in to another tenant, and with exit code 2 for bad values' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return $global:AzlK6Tenant } }
        $r = Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = $script:Subs })
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'az extension add --name account'
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = $script:Subs })).ExitCode | Should -Be 1
        (Get-Call 'alias create').Count | Should -Be 0
        $global:AzlK6Calls.Clear()
        (Invoke-Tool $script:SubCreate (New-InfraFile -Tenant $null -LandingZone @{ subscriptions = $script:Subs })).ExitCode | Should -Be 2
        (Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = @([ordered]@{ name = 'sub-x' }) })).ExitCode | Should -Be 2
        (Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = @([ordered]@{ name = 'sub-x'; billing_scope = $global:AzlK6Scope; workload = 'Other' }) })).ExitCode | Should -Be 2
        (Invoke-Tool $script:SubCreate (New-InfraFile -LandingZone @{ subscriptions = @($script:Subs[2]) })).ExitCode | Should -Be 2
        $global:AzlK6Calls.Count | Should -Be 0
    }
}

Describe 'Invoke-SubscriptionMove-Orchestrated.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'account management-group show*') { return 'mg' }
            if ($Line -like "account management-group subscription show --name mg-iic --subscription $($global:AzlK6SubB)*") { return '{}' }
            if ($Line -like 'account management-group subscription show*') { return @{ Fail = '(NotFound) The subscription is not under the group.' } }
        }
        $script:Subs = @(
            [ordered]@{ name = 'sub-iic-a'; id = $global:AzlK6SubA; management_group = 'mg-iic-platform' },
            [ordered]@{ name = 'sub-iic-b'; id = $global:AzlK6SubB; management_group = 'mg-iic' },
            [ordered]@{ name = 'sub-iic-c'; id = '00000000-0000-0000-0000-000000000000'; management_group = 'mg-iic' },
            [ordered]@{ name = 'sub-iic-d'; id = [guid]::NewGuid().ToString() })
    }

    It 'moves the subscription that is not under its group, leaves the one that is, and skips the other two' {
        $r = Invoke-Tool $script:SubMove (New-InfraFile -LandingZone @{ subscriptions = $script:Subs })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-Call 'subscription add') | Should -Be @("account management-group subscription add --name mg-iic-platform --subscription $($global:AzlK6SubA) --output none")
        $r.Rows[0].Moved | Should -Be 1
        $r.Rows[0].AlreadyInPlace | Should -Be 1
        $r.Rows[0].Skipped | Should -Be 2
    }

    It 'moves nothing under -WhatIf' {
        $r = Invoke-Tool $script:SubMove (New-InfraFile -LandingZone @{ subscriptions = $script:Subs }) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'subscription add').Count | Should -Be 0
        $r.Rows[0].Planned | Should -Be 1
    }

    It 'fails for a target group that does not exist and stops with exit code 2 when there is nothing to move' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'account management-group show*') { return @{ Fail = 'NotFound' } }
        }
        $r = Invoke-Tool $script:SubMove (New-InfraFile -LandingZone @{ subscriptions = @($script:Subs[0]) })
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'does not exist'
        (Invoke-Tool $script:SubMove (New-InfraFile -LandingZone @{ subscriptions = @($script:Subs[2], $script:Subs[3]) })).ExitCode | Should -Be 2
        (Invoke-Tool $script:SubMove (New-InfraFile -Tenant $null -LandingZone @{ subscriptions = $script:Subs })).ExitCode | Should -Be 2
    }

    It 'stops with exit code 1 when az is not signed in or is signed in to another tenant' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return @{ Fail = 'Please run az login' } } }
        (Invoke-Tool $script:SubMove (New-InfraFile -LandingZone @{ subscriptions = $script:Subs })).ExitCode | Should -Be 1
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $script:SubMove (New-InfraFile -LandingZone @{ subscriptions = $script:Subs })).ExitCode | Should -Be 1
        (Get-Call 'subscription add').Count | Should -Be 0
    }
}

Describe 'Deploy-ResourceGroups.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'group show --name rg-iic-existing *') { return 'westeurope' }
            if ($Line -like 'group show*') { return @{ Fail = "(ResourceGroupNotFound) Resource group 'x' could not be found." } }
        }
        $script:Lz = @{
            subscriptions   = @([ordered]@{ name = 'sub-iic-mgmt'; id = $global:AzlK6SubA })
            resource_groups = @(
                [ordered]@{ name = 'rg-iic-mgmt-01'; subscription = 'sub-iic-mgmt'; purpose = 'Management' },
                [ordered]@{ name = 'rg-iic-existing'; subscription = 'sub-iic-mgmt'; location = 'eastus' },
                [ordered]@{ name = 'rg-iic-home'; location = 'westus3' })
        }
    }

    It 'creates the groups that are missing in the subscription of each entry, with the location, and the file tags' {
        $r = Invoke-Tool $script:RgCreate (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Home } -Tags ([ordered]@{ Project = 'azl' }) -LandingZone $script:Lz)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-Call '^group create') | Should -Be @(
            "group create --name rg-iic-mgmt-01 --location eastus --subscription $($global:AzlK6SubA) --tags Project=azl --output none"
            "group create --name rg-iic-home --location westus3 --subscription $($global:AzlK6Home) --tags Project=azl --output none")
        @($r.Rows | Where-Object Action -EQ 'AlreadyExists').Count | Should -Be 1
        $r.Rows[1].Detail | Should -Match 'cannot change location'
    }

    It 'creates nothing under -WhatIf' {
        $r = Invoke-Tool $script:RgCreate (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Home } -LandingZone $script:Lz) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call '^group create').Count | Should -Be 0
        @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 2
    }

    It 'creates the one resource group of the instance when the file has no landing zone groups' {
        $r = Invoke-Tool $script:RgCreate (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Home; resource_group = 'rg-iic-azl-01' })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-Call '^group create') | Should -Be @("group create --name rg-iic-azl-01 --location eastus --subscription $($global:AzlK6Home) --output none")
        $global:AzlK6Calls.Clear()
        $r = Invoke-Tool $script:RgCreate (New-InfraFile)
        $r.ExitCode | Should -Be 0
        $global:AzlK6Calls.Count | Should -Be 0
    }

    It 'ends with exit code 1 when one group cannot be created, and goes on with the others' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'group show*') { return @{ Fail = 'ResourceGroupNotFound' } }
            if ($Line -like 'group create --name rg-iic-mgmt-01*') { return @{ Fail = 'AuthorizationFailed' } }
        }
        $r = Invoke-Tool $script:RgCreate (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Home } -LandingZone $script:Lz)
        $r.ExitCode | Should -Be 1
        (Get-Call '^group create').Count | Should -Be 3
    }

    It 'stops with exit code 1 when az is not signed in or is signed in to another tenant, and with exit code 2 for bad values' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return @{ Fail = 'Please run az login' } } }
        (Invoke-Tool $script:RgCreate (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Home } -LandingZone $script:Lz)).ExitCode | Should -Be 1
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $script:RgCreate (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Home } -LandingZone $script:Lz)).ExitCode | Should -Be 1
        (Get-Call '^group create').Count | Should -Be 0
        $global:AzlK6Calls.Clear()
        (Invoke-Tool $script:RgCreate (New-InfraFile -Tenant $null -Azure @{ subscription_id = $global:AzlK6Home } -LandingZone $script:Lz)).ExitCode | Should -Be 2
        (Invoke-Tool $script:RgCreate (New-InfraFile -LandingZone $script:Lz)).ExitCode | Should -Be 2
        (Invoke-Tool $script:RgCreate (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Home } -LandingZone @{ resource_groups = @([ordered]@{ name = 'rg-x'; subscription = 'sub-unknown' }) })).ExitCode | Should -Be 2
        (Invoke-Tool $script:RgCreate (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Home } -LandingZone @{ resource_groups = @([ordered]@{ name = 'bad name'; location = 'eastus' }) })).ExitCode | Should -Be 2
        $global:AzlK6Calls.Count | Should -Be 0
    }
}
