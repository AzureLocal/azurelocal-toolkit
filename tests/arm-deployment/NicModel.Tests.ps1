#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The adapter names of the ARM parameters. Nothing is assumed about names: each port of the file (nodes[].network_adapters[].name, the key that intents refer to) is found on its node by
# MAC, and the deployment sends what the node calls the adapter, or the user's explicit os_name_override. Three machines of different NIC brands, nodes that name the same adapters
# differently (tests/fixtures/nic-model). No Azure call is made.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/arm-deployment/NicModel.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks and mock script blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    . ([IO.Path]::Combine($PSScriptRoot, '..', 'fixtures', 'nic-model', 'NicFixtures.ps1'))
    $script:Brands = @(Get-NicBrandFixture | ForEach-Object { @{ Fixture = $_; Id = $_.Id } })
}

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\azure-local\AzlAzure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodeConfiguration.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\arm-deployment\AzlArmDeployment.psm1') -Force
    Import-Module powershell-yaml
    . (Join-Path $repo 'tests\fixtures\nic-model\NicFixtures.ps1')
    $script:Base = Join-Path $repo 'tests\fixtures\infrastructure.fc-san.yml'
    $script:Catalog = Get-AzlArmTemplateCatalog
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    function Get-NicInfra([hashtable]$Fixture, [switch]$WithOverride) {
        $infra = Import-AzlInfrastructure -Path $script:Base -SkipValidation
        Set-NicFixtureOnInfra -Infra $infra -Fixture $Fixture -WithOverride:$WithOverride
    }
    # node -> (MAC -> OS name), the shape of the OS configuration report's map, from the nodes' states.
    function ConvertTo-NicMap([hashtable]$States) {
        $map = @{}
        foreach ($node in $States.Keys) { $by = @{}; foreach ($n in $States[$node]) { $by[$n.mac] = [string]$n.n }; $map[$node] = $by }
        $map
    }
    function Get-NicStateSet([hashtable]$Fixture, [scriptblock]$Names) {
        @{
            'iic-n01' = @(Get-NicNodeState $Fixture 1 -OsName (& $Names 1))
            'iic-n02' = @(Get-NicNodeState $Fixture 2 -OsName (& $Names 2))
        }
    }
    function New-NicParameterSet($Infra, $Map) { New-AzlArmParameterSet -Infrastructure $Infra -Mode Validate -Catalog $script:Catalog -AdapterMap $Map -AllowUnresolvedSanLun }
    # What the NicNames step does to the nodes: the states after the renames (only ports with os_name_override change, found by MAC).
    function Invoke-NicNamesOnState($Infra, [hashtable]$States) {
        $after = @{}
        $i = 0
        foreach ($node in @($Infra.nodes)) {
            $spec = Get-AzlNodeSpec -Infrastructure $Infra -Node $node
            $state = $States[[string]$node.name]
            $plan = @(Compare-AzlNodeState -Spec $spec -State ([pscustomobject]@{ nics = $state }) -Step @('NicNames'))
            $rename = @{}
            foreach ($c in @($plan | Where-Object Action -eq 'Change')) { $rename[$c.Apply.mac] = $c.Apply.name }
            $after[[string]$node.name] = @($state | ForEach-Object { $copy = $_.PSObject.Copy(); if ($rename.ContainsKey($copy.mac)) { $copy.n = $rename[$copy.mac] }; $copy })
            $i++
        }
        $after
    }
}

Describe 'No override: the deployment sends what each node calls the adapter, found by MAC: <Id>' -ForEach $script:Brands {
    BeforeAll {
        # A consistent install: both nodes name the same physical adapter alike (node 1's names), in an order that is not the BMC's.
        $script:Same = Get-NicStateSet $Fixture { param($n) $Fixture.OsNames['iic-n01'] }
        $script:Set = New-NicParameterSet (Get-NicInfra $Fixture) (ConvertTo-NicMap $script:Same)
        $script:Names = @{}
        for ($i = 0; $i -lt $Fixture.Ports.Count; $i++) { $script:Names[$Fixture.Ports[$i].Key] = $Fixture.OsNames['iic-n01'][$i] }
    }
    It 'carries the OS names, not the keys of the file, in every intent' {
        $intentList = @($script:Set.Parameters.intentList)
        $intentList.Count | Should -Be $Fixture.Intents.Count
        for ($i = 0; $i -lt $Fixture.Intents.Count; $i++) {
            $expected = @($Fixture.Intents[$i].Ports | ForEach-Object { $script:Names[$_] })
            @($intentList[$i].adapter) | Should -Be $expected
        }
    }
    It 'carries the OS names in the storage networks' {
        $nets = @($script:Set.Parameters.storageNetworkList)
        $nets.Count | Should -Be $Fixture.Storage.Count
        for ($i = 0; $i -lt $Fixture.Storage.Count; $i++) { $nets[$i].networkAdapterName | Should -Be $script:Names[$Fixture.Storage[$i].Port] }
    }
    It 'sends no key of the file as an adapter name when the node calls the adapter something else' {
        $sent = @(@($script:Set.Parameters.intentList | ForEach-Object { $_.adapter }) + @($script:Set.Parameters.storageNetworkList | ForEach-Object { $_.networkAdapterName }))
        foreach ($p in $Fixture.Ports) { if ($p.Key -notin $Fixture.OsNames['iic-n01']) { $sent | Should -Not -Contain $p.Key } }
    }
    It 'does not depend on the order the nodes list the adapters: the same file and the same names give the same parameters' {
        $shuffled = Get-NicStateSet $Fixture { param($n) $Fixture.OsNames['iic-n01'] }
        foreach ($k in @($shuffled.Keys)) { [array]::Reverse($shuffled[$k]) }
        $again = New-NicParameterSet (Get-NicInfra $Fixture) (ConvertTo-NicMap $shuffled)
        ($again.Parameters | ConvertTo-Json -Depth 20) | Should -Be ($script:Set.Parameters | ConvertTo-Json -Depth 20)
    }
}

Describe 'The same logical adapter has different names on different nodes: <Id>' -ForEach $script:Brands {
    It 'fails and names both ways out: install consistently, or set the override so the OS configuration renames (opt-in)' {
        $states = Get-NicStateSet $Fixture { param($n) $Fixture.OsNames["iic-n0$n"] }
        { New-NicParameterSet (Get-NicInfra $Fixture) (ConvertTo-NicMap $states) } | Should -Throw '*same adapter name on every node*'
        { New-NicParameterSet (Get-NicInfra $Fixture) (ConvertTo-NicMap $states) } | Should -Throw '*install the nodes consistently*'
        { New-NicParameterSet (Get-NicInfra $Fixture) (ConvertTo-NicMap $states) } | Should -Throw '*os_name_override*'
        { New-NicParameterSet (Get-NicInfra $Fixture) (ConvertTo-NicMap $states) } | Should -Throw '*NicNames*'
    }
    It 'names the file port and what each node calls it' {
        $states = Get-NicStateSet $Fixture { param($n) $Fixture.OsNames["iic-n0$n"] }
        $message = ''
        try { $null = New-NicParameterSet (Get-NicInfra $Fixture) (ConvertTo-NicMap $states) } catch { $message = $_.Exception.Message }
        $message | Should -Match 'on iic-n01'
        $message | Should -Match 'on iic-n02'
    }
}

Describe 'With os_name_override the parameters are the same whatever the OS names were: <Id>' -ForEach $script:Brands {
    It 'is identical for two installs with different names, once the NicNames step has renamed the adapters' {
        $infra = Get-NicInfra $Fixture -WithOverride
        $installA = Get-NicStateSet $Fixture { param($n) $Fixture.OsNames["iic-n0$n"] }
        $installB = Get-NicStateSet $Fixture { param($n) @($Fixture.OsNames["iic-n0$n"]) | ForEach-Object { "Renamed-$_" } }
        $afterA = Invoke-NicNamesOnState $infra $installA
        $afterB = Invoke-NicNamesOnState $infra $installB
        $setA = New-NicParameterSet $infra (ConvertTo-NicMap $afterA)
        $setB = New-NicParameterSet $infra (ConvertTo-NicMap $afterB)
        ($setA.Parameters | ConvertTo-Json -Depth 20) | Should -Be ($setB.Parameters | ConvertTo-Json -Depth 20)
    }
    It 'sends the override for the ports that have one and the node''s own name for the others' {
        $infra = Get-NicInfra $Fixture -WithOverride
        $states = Get-NicStateSet $Fixture { param($n) $Fixture.OsNames['iic-n01'] }
        $after = Invoke-NicNamesOnState $infra $states
        $set = New-NicParameterSet $infra (ConvertTo-NicMap $after)
        $sent = @($set.Parameters.intentList | ForEach-Object { $_.adapter } | ForEach-Object { $_ })
        foreach ($intent in $Fixture.Intents) {
            foreach ($key in $intent.Ports) {
                $i = [array]::IndexOf(@($Fixture.Ports | ForEach-Object { $_.Key }), $key)
                $want = if ($Fixture.Override.ContainsKey($key)) { $Fixture.Override[$key] } else { $Fixture.OsNames['iic-n01'][$i] }
                $sent | Should -Contain $want
            }
        }
    }
    It 'refuses a node that has not been renamed yet, and says to run the NicNames step' {
        $infra = Get-NicInfra $Fixture -WithOverride
        $states = Get-NicStateSet $Fixture { param($n) $Fixture.OsNames['iic-n01'] }
        { New-NicParameterSet $infra (ConvertTo-NicMap $states) } | Should -Throw '*NicNames*'
    }
    It 'uses the override when there is no report at all' {
        $infra = Get-NicInfra $Fixture -WithOverride
        $set = New-AzlArmParameterSet -Infrastructure $infra -Mode Validate -Catalog $script:Catalog -AllowUnresolvedSanLun
        $sent = @($set.Parameters.intentList | ForEach-Object { $_.adapter } | ForEach-Object { $_ })
        foreach ($key in $Fixture.Override.Keys) { if ($key -in ($Fixture.Intents | ForEach-Object { $_.Ports } | ForEach-Object { $_ })) { $sent | Should -Contain $Fixture.Override[$key] } }
    }
}

Describe 'Without a report nothing is assumed silently' {
    It 'sends the file''s names as they are and warns that the OS names were not read' {
        $f = (Get-NicBrandFixture)[0]
        $set = New-AzlArmParameterSet -Infrastructure (Get-NicInfra $f) -Mode Validate -Catalog $script:Catalog -AllowUnresolvedSanLun
        @($set.Warnings | Where-Object { $_ -match 'no OS configuration report' }).Count | Should -BeGreaterThan 0
        @($set.Parameters.intentList[0].adapter) | Should -Be @('Slot 3 Port 1', 'Slot 3 Port 2')
    }
    It 'throws when the report has no port with the MAC of a port of the file' {
        $f = (Get-NicBrandFixture)[1]
        $states = Get-NicStateSet $f { param($n) $f.OsNames['iic-n01'] }
        $states['iic-n02'] = @($states['iic-n02'] | Select-Object -Skip 1)
        { New-NicParameterSet (Get-NicInfra $f) (ConvertTo-NicMap $states) } | Should -Throw '*no port with that MAC*'
    }
}
