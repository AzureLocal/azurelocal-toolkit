#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Stage 07 task 06, Azure CLI variant: Set-CustomerTransfer.azcli.ps1 gives the customer administrator Contributor on the resource group and Reader on the subscription
# of infrastructure.yml with az, and writes the transfer record. az is mocked: no Azure, no tenant and no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/handover/CustomerTransferAzureCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '07-validation-handover', 'task-06-customer-transfer', 'azurecli', 'Set-CustomerTransfer.azcli.ps1')
    Import-Module powershell-yaml
    function az { }
    $global:AzlCtTenant = [guid]::NewGuid().ToString()
    $global:AzlCtSubscription = [guid]::NewGuid().ToString()
    $global:AzlCtHome = [guid]::NewGuid().ToString()
    $global:AzlCtCustomerTenant = [guid]::NewGuid().ToString()
    $global:AzlCtUser = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object]$Tenant = $global:AzlCtTenant, [string]$Cluster = 'iic-azl-01', [string]$ResourceGroup = 'rg-iic-azl-01')
        $doc = [ordered]@{ azure = [ordered]@{ subscription_id = $global:AzlCtSubscription }; site = [ordered]@{ customer = 'Improbability Cloud' } }
        if ($null -ne $Tenant) { $doc.azure.tenant_id = $Tenant }
        if ($ResourceGroup) { $doc.azure.resource_group = $ResourceGroup }
        if ($Cluster) { $doc.cluster = [ordered]@{ name = $Cluster } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Transfer([string]$File, [hashtable]$Extra = @{}, [switch]$DryRun) {
        $arguments = @{ InfrastructureFile = $File; CustomerTenantId = $global:AzlCtCustomerTenant; CustomerAdminUPN = 'admin@improbability.cloud' }
        foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script @arguments -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script @arguments 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Step'] -and $_.PSObject.Properties['Status'] -and $_ -isnot [string] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Set-CustomerTransfer.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlCtFilter, AzlCtShowId, AzlCtTenant, AzlCtSubscription, AzlCtHome, AzlCtCustomerTenant, AzlCtUser, AzlCtState, AzlCtCalls -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        $global:AzlCtCalls = [System.Collections.Generic.List[string]]::new()
        $global:AzlCtState = @{ SignedIn = $true; Tenant = $global:AzlCtTenant; UserByName = $true; ByMail = $false; Existing = @{}; CreateFails = $false; RestoreFails = $false }
        $global:AzlCtFilter = ''
        $global:AzlCtShowId = ''
        Mock az {
            $global:LASTEXITCODE = 0
            $line = $args -join ' '
            $global:AzlCtCalls.Add($line)
            $s = $global:AzlCtState
            if ($line -like 'account show*') { if (-not $s.SignedIn) { $global:LASTEXITCODE = 1; return 'run az login' }; return @($s.Tenant, $global:AzlCtHome) }
            if ($line -like 'account set*') {
                if ($s.RestoreFails -and $args[-1] -eq $global:AzlCtHome) { $global:LASTEXITCODE = 1; return 'ERROR: the subscription was removed' }
                return
            }
            if ($line -like 'ad user show*') { $global:AzlCtShowId = [string]$args[$args.IndexOf('--id') + 1]; if ($s.UserByName) { return $global:AzlCtUser }; $global:LASTEXITCODE = 1; return 'ResourceNotFound' }
            if ($line -like 'ad user list*') { $global:AzlCtFilter = [string]$args[$args.IndexOf('--filter') + 1]; if ($s.ByMail) { return $global:AzlCtUser }; return '' }
            if ($line -like 'role assignment list*--scope*') {
                $role = $args[$args.IndexOf('--role') + 1]; $scope = $args[$args.IndexOf('--scope') + 1]
                if ($s.Existing.ContainsKey("$role|$scope")) { return '/subscriptions/x/providers/Microsoft.Authorization/roleAssignments/1' }
                return ''
            }
            if ($line -like 'role assignment list*--all*') { return @('a', 'b', 'c') }
            if ($line -like 'role assignment create*') { if ($s.CreateFails) { $global:LASTEXITCODE = 1; return 'AuthorizationFailed' }; return }
            $global:LASTEXITCODE = 1
            "unexpected az call: $line"
        }
    }

    It 'assigns Contributor on the resource group and Reader on the subscription of the file, as a User by object id, and puts the earlier subscription back' {
        $r = Invoke-Transfer (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $creates = @($global:AzlCtCalls | Where-Object { $_ -like 'role assignment create*' })
        $creates.Count | Should -Be 2
        $creates | Should -Contain "role assignment create --assignee-object-id $($global:AzlCtUser) --assignee-principal-type User --role Contributor --scope /subscriptions/$($global:AzlCtSubscription)/resourceGroups/rg-iic-azl-01 --output none"
        $creates | Should -Contain "role assignment create --assignee-object-id $($global:AzlCtUser) --assignee-principal-type User --role Reader --scope /subscriptions/$($global:AzlCtSubscription) --output none"
        $global:AzlCtCalls | Should -Contain "account set --subscription $($global:AzlCtSubscription)"
        $global:AzlCtCalls[-1] | Should -Be "account set --subscription $($global:AzlCtHome)"
        @($r.Rows | Where-Object Status -EQ 'Assigned').Count | Should -Be 2
    }

    It 'assigns nothing that the administrator already has, and says so' {
        $global:AzlCtState.Existing = @{ "Contributor|/subscriptions/$($global:AzlCtSubscription)/resourceGroups/rg-iic-azl-01" = $true; "Reader|/subscriptions/$($global:AzlCtSubscription)" = $true }
        $r = Invoke-Transfer (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlCtCalls | Where-Object { $_ -like 'role assignment create*' }).Count | Should -Be 0
        @($r.Rows | Where-Object Status -EQ 'AlreadyAssigned').Count | Should -Be 2
    }

    It 'plans under -WhatIf: it reads, assigns nothing and writes no file' {
        $out = Join-Path $TestDrive 'plan'
        $r = Invoke-Transfer (New-InfraFile) @{ OutputPath = $out } -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlCtCalls | Where-Object { $_ -like 'role assignment create*' }).Count | Should -Be 0
        @($r.Rows | Where-Object Status -EQ 'WouldAssign').Count | Should -Be 2
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'finds a guest by mail when the user principal name is not a user' {
        $global:AzlCtState.UserByName = $false; $global:AzlCtState.ByMail = $true
        (Invoke-Transfer (New-InfraFile)).ExitCode | Should -Be 0
        @($global:AzlCtCalls | Where-Object { $_ -like 'role assignment create*' }).Count | Should -Be 2
    }

    It 'doubles an apostrophe of the address in the OData filter, and the whole address reaches az (the apostrophe is not a character the guard refuses)' {
        $global:AzlCtState.UserByName = $false; $global:AzlCtState.ByMail = $true
        $r = Invoke-Transfer (New-InfraFile) @{ CustomerAdminUPN = "o'brien@improbability.cloud" }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlCtFilter | Should -Be "mail eq 'o''brien@improbability.cloud'"
        $global:AzlCtShowId | Should -Be "o'brien@improbability.cloud"
        @($global:AzlCtCalls | Where-Object { $_ -like 'role assignment create*' }).Count | Should -Be 2
    }

    It 'leaves an address without an apostrophe as it is in the filter' {
        $global:AzlCtState.UserByName = $false; $global:AzlCtState.ByMail = $true
        $null = Invoke-Transfer (New-InfraFile)
        $global:AzlCtFilter | Should -Be "mail eq 'admin@improbability.cloud'"
    }

    It 'refuses an address that holds <Bad> (exit 2, no az call, also under -WhatIf)' -ForEach @(@{ Bad = 'a&b@improbability.cloud' }, @{ Bad = 'a|b@improbability.cloud' }, @{ Bad = 'a^b@improbability.cloud' }, @{ Bad = 'a%b@improbability.cloud' }, @{ Bad = 'a"b@improbability.cloud' }) {
        foreach ($dry in $false, $true) {
            $global:AzlCtCalls.Clear()
            $r = if ($dry) { Invoke-Transfer (New-InfraFile) @{ CustomerAdminUPN = $Bad } -DryRun } else { Invoke-Transfer (New-InfraFile) @{ CustomerAdminUPN = $Bad } }
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'CustomerAdminUPN'
            $global:AzlCtCalls.Count | Should -Be 0
        }
    }

    It 'warns, records a Failed step and exits 1 when the earlier subscription cannot be put back, although every role was assigned' {
        $global:AzlCtState.RestoreFails = $true
        $r = Invoke-Transfer (New-InfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'could not be put back'
        @($r.Rows | Where-Object { $_.Step -eq 'Original subscription' -and $_.Status -eq 'Failed' }).Count | Should -Be 1
        @($r.Rows | Where-Object Status -EQ 'Assigned').Count | Should -Be 2
    }

    It 'exits 1 when the administrator is not found in Microsoft Entra ID' {
        $global:AzlCtState.UserByName = $false
        $r = Invoke-Transfer (New-InfraFile)
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'was not found in Microsoft Entra ID'
        @($global:AzlCtCalls | Where-Object { $_ -like 'role assignment create*' }).Count | Should -Be 0
    }

    It 'exits 1 when an assignment fails, and 1 when az is not signed in or is signed in to another tenant' {
        $global:AzlCtState.CreateFails = $true
        (Invoke-Transfer (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlCtState.CreateFails = $false; $global:AzlCtState.SignedIn = $false
        (Invoke-Transfer (New-InfraFile)).ExitCode | Should -Be 1
        $global:AzlCtState.SignedIn = $true; $global:AzlCtState.Tenant = [guid]::NewGuid().ToString()
        (Invoke-Transfer (New-InfraFile)).ExitCode | Should -Be 1
    }

    It 'writes the Markdown record and the JSON file in -OutputPath' {
        $out = Join-Path $TestDrive 'record'
        $r = Invoke-Transfer (New-InfraFile) @{ OutputPath = $out }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $md = @(Get-ChildItem -LiteralPath $out -Filter 'Customer-Transfer-iic-azl-01-*.md')
        $md.Count | Should -Be 1
        (Get-Content -LiteralPath $md[0].FullName -Raw) | Should -Match 'Improbability Cloud'
        (Get-Content -LiteralPath $md[0].FullName -Raw) | Should -Match ([regex]::Escape("https://portal.azure.com/#@$($global:AzlCtCustomerTenant)/resource/subscriptions/$($global:AzlCtSubscription)/resourceGroups/rg-iic-azl-01"))
        @(Get-ChildItem -LiteralPath $out -Filter '*.json').Count | Should -Be 1
    }

    It 'exits 2 for a value that is missing or not usable, before it calls az: <Case>' -ForEach @(
        @{ Case = 'no tenant'; Opts = @{ Tenant = $null }; Extra = @{} }
        @{ Case = 'no cluster name'; Opts = @{ Cluster = '' }; Extra = @{} }
        @{ Case = 'no resource group'; Opts = @{ ResourceGroup = '' }; Extra = @{} }
        @{ Case = 'an unsafe resource group'; Opts = @{ ResourceGroup = 'rg&calc' }; Extra = @{} }
        @{ Case = 'a customer tenant that is not a GUID'; Opts = @{}; Extra = @{ CustomerTenantId = 'not-a-guid' } }
        @{ Case = 'an administrator that is not a user principal name'; Opts = @{}; Extra = @{ CustomerAdminUPN = 'admin' } }
    ) {
        $r = Invoke-Transfer (New-InfraFile @Opts) $Extra
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $global:AzlCtCalls.Count | Should -Be 0
    }

    It 'has one guarded call site of az and never signs in' {
        $text = Get-Content -LiteralPath $script:Script -Raw
        ([regex]::Matches($text, '&\s+az\s')).Count | Should -Be 1
        $text | Should -Match 'AzlAzureCliArgument\.psm1'
        $text | Should -Match 'Get-AzlAzureCliArgumentProblem'
        $text | Should -Match 'Get-AzlAzureCliValueProblem'
        $text | Should -Not -Match 'UnsafeArgument'
        $text | Should -Not -Match '(?m)^\s*(\$null = )?(az login|Invoke-AzCli @\(.login)'
    }
}
