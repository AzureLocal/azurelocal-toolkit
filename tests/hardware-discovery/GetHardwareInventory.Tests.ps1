#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 (hardware provisioning), task 02: Get-HardwareInventory.ps1 reads the BMC of every node over Redfish and writes one inventory file.
# Every HTTP call is mocked (Invoke-WebRequest in the Redfish core; Invoke-RestMethod must never be called): no BMC, node, cluster or Azure
# resource is contacted. The fake BMCs are made-up trees in three shapes (HardwareFixtures.ps1). Secrets are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/hardware-discovery/GetHardwareInventory.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks run in module scope and read the fake BMCs through a global.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test values only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes and files in TestDrive.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    . (Join-Path $PSScriptRoot 'HardwareFixtures.ps1')
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-01-hardware-provisioning', 'task-02-hardware-discovery-via-dell-redfish-api', 'powershell', 'Get-HardwareInventory.ps1')
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishInventory.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'secrets', 'AzlSecret.psm1')) -Force
    Import-Module powershell-yaml

    $script:Password = [guid]::NewGuid().ToString('N')
    $script:NodePassword = [guid]::NewGuid().ToString('N')
    $env:AZL_HW_TEST_BMC_PASSWORD = $script:Password
    $env:AZL_HW_TEST_NODE_PASSWORD = $script:NodePassword

    function New-InfraFile {
        param([hashtable]$Inventory = @{}, [hashtable]$Bmc = @{}, [object[]]$Nodes = $null, [hashtable]$Hardware = @{}, [switch]$NoSharedBmc)
        $dir = Join-Path $TestDrive "out-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $inv = [ordered]@{ output_directory = $dir; file_name_prefix = 'iic-hw'; format = 'json'; timeout_seconds = 30 }
        foreach ($k in $Inventory.Keys) { if ($null -eq $Inventory[$k]) { $inv.Remove($k) } else { $inv[$k] = $Inventory[$k] } }
        $hw = [ordered]@{ inventory = $inv }
        if (-not $NoSharedBmc) {
            $b = [ordered]@{ username = 'admin-test'; password = 'env://AZL_HW_TEST_BMC_PASSWORD'; verify_certificate = $false }
            foreach ($k in $Bmc.Keys) { if ($null -eq $Bmc[$k]) { $b.Remove($k) } else { $b[$k] = $Bmc[$k] } }
            $hw.bmc = $b
        }
        foreach ($k in $Hardware.Keys) { $hw[$k] = $Hardware[$k] }
        if ($null -eq $Nodes) {
            $Nodes = @(
                [ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = '192.0.2.11' } }
                [ordered]@{ name = 'iic-azl-n02'; bmc = [ordered]@{ ip_address = '192.0.2.12' } }
                [ordered]@{ name = 'iic-azl-n03'; bmc = [ordered]@{ ip_address = '192.0.2.13' } }
            )
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml ([ordered]@{ hardware = $hw; nodes = @($Nodes) }))
        [pscustomobject]@{ File = $file; Directory = $dir }
    }
    function Invoke-Inventory([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Node'] -and $_.PSObject.Properties['Result'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Read-InventoryFile([string]$Directory) {
        $files = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue)
        [pscustomobject]@{ Files = $files; Json = $(if ($files.Count -eq 1 -and $files[0].Extension -eq '.json') { Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json -Depth 40 }) }
    }
}

Describe 'Get-HardwareInventory.ps1' {
    AfterAll {
        Remove-FakeBmcSet
        Remove-Item Env:\AZL_HW_TEST_BMC_PASSWORD, Env:\AZL_HW_TEST_NODE_PASSWORD -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Use-FakeBmcSet @{ '192.0.2.11' = (Get-DellShapeTree); '192.0.2.12' = (Get-HpeShapeTree); '192.0.2.13' = (Get-AmiShapeTree) }
        Mock Invoke-WebRequest -ModuleName AzlRedfishCore -MockWith $script:HwResponder
        Mock Invoke-RestMethod -ModuleName AzlRedfishCore { throw 'Invoke-RestMethod must not be called.' }
        Mock Invoke-RestMethod -ModuleName AzlRedfishInventory { throw 'Invoke-RestMethod must not be called.' }
    }

    Context 'reading three BMCs of different makers' {
        It 'reads all three, writes one file, and exits 0' {
            $i = New-InfraFile
            $r = Invoke-Inventory $i.File
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Result) | Should -Be @('Read', 'Read', 'Read')
            $out = Read-InventoryFile $i.Directory
            $out.Files.Count | Should -Be 1
            $out.Files[0].Name | Should -Match '^iic-hw-\d{8}T\d{6}Z\.json$'
            $out.Json.kind | Should -Be 'hardware-inventory'
            @($out.Json.nodes).Count | Should -Be 3
            @($out.Json.nodes.name) | Should -Be @('iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03')
            @($out.Json.nodes.status) | Should -Be @('read', 'read', 'read')
            $out.Json.source.readOnly | Should -BeTrue
        }

        It 'holds per node the model, serial, CPU, memory, drives with role, ports with MAC, GPU, TPM, BIOS and BMC version' {
            $i = New-InfraFile
            $null = Invoke-Inventory $i.File
            $nodes = (Read-InventoryFile $i.Directory).Json.nodes
            $dell = $nodes[0]
            $dell.identity.model | Should -Be 'Test Model D1'
            $dell.identity.serialNumber | Should -Be 'TESTSN-D-0001'
            $dell.cpu.cores | Should -Be 64
            $dell.memory.totalGiB | Should -Be 256
            @($dell.drives | Where-Object role -EQ 'cache').Count | Should -Be 4
            @($dell.drives | Where-Object role -EQ 'capacity').Count | Should -Be 6
            @($dell.network.ports).Count | Should -Be 4
            $dell.network.ports[0].mac | Should -Be '00:00:5E:00:53:10'
            $dell.tpm.present | Should -BeTrue
            $dell.bios.version | Should -Be '9.9.9'
            $dell.bmc.firmwareVersion | Should -Be '7.10.50.00'
            $nodes[1].gpu.count | Should -Be 1
            $nodes[1].gpu.devices[0].memoryGiB | Should -Be 24
            $nodes[2].tpm.present | Should -Be 'not reported'
            $nodes[2].notReported | Should -Contain 'tpm.present'
        }

        It 'writes the drive role rule and the OEM rule into the file' {
            $i = New-InfraFile
            $null = Invoke-Inventory $i.File
            $rules = (Read-InventoryFile $i.Directory).Json.rules
            $rules.driveRole | Should -Match 'fastest type'
            $rules.source | Should -Match 'No vendor \(OEM\) path'
        }

        It 'writes the symmetry checks across the three nodes' {
            $i = New-InfraFile
            $null = Invoke-Inventory $i.File
            $sym = @((Read-InventoryFile $i.Directory).Json.symmetry)
            $sym.Count | Should -BeGreaterThan 8
            ($sym | Where-Object check -EQ 'model').result | Should -Be 'differs'
        }

        It 'compares the plan with what was found for the hardware keys that have a value' {
            $i = New-InfraFile -Hardware @{ vendor = 'Dell'; model = 'Test Model D1'; cpu_cores = 64; memory_gib = 256 } -Nodes @(
                [ordered]@{ name = 'iic-azl-n01'; serial_number = 'TESTSKU1'; bmc = [ordered]@{ ip_address = '192.0.2.11'; type = 'idrac' } })
            $null = Invoke-Inventory $i.File
            $rows = @((Read-InventoryFile $i.Directory).Json.planComparison)
            ($rows | Where-Object key -EQ 'hardware.vendor').result | Should -Be 'match'
            ($rows | Where-Object key -EQ 'hardware.memory_gib').result | Should -Be 'match'
            ($rows | Where-Object key -EQ 'nodes[].bmc.type').result | Should -Be 'match'
            ($rows | Where-Object key -EQ 'nodes[].serial_number').result | Should -Be 'match'
        }
    }

    Context 'read only, and the login' {
        It 'sends GET only, with Basic authentication for the login in hardware.bmc, and checks no certificate by default' {
            $i = New-InfraFile
            $null = Invoke-Inventory $i.File
            $calls = @($global:AzlHwBmc.Calls)
            $calls.Count | Should -BeGreaterThan 30
            @($calls | Where-Object Method -NE 'Get').Count | Should -Be 0
            @($calls | Where-Object { -not $_.Basic }).Count | Should -Be 0
            @($calls.User | Select-Object -Unique) | Should -Be @('admin-test')
            @($calls | Where-Object { -not $_.SkipCertificateCheck }).Count | Should -Be 0
            @($calls.Host | Select-Object -Unique).Count | Should -Be 3
            Should -Invoke Invoke-RestMethod -ModuleName AzlRedfishCore -Times 0 -Exactly
        }

        It 'checks the certificate when hardware.bmc.verify_certificate is true, and passes the timeout of the file' {
            $i = New-InfraFile -Bmc @{ verify_certificate = $true } -Inventory @{ timeout_seconds = 45 }
            $null = Invoke-Inventory $i.File
            @($global:AzlHwBmc.Calls | Where-Object SkipCertificateCheck).Count | Should -Be 0
            @($global:AzlHwBmc.Calls.OperationTimeoutSeconds | Select-Object -Unique) | Should -Be @(45)
        }

        It 'uses the login of a node that has its own, and the shared one for the others' {
            $own = [ordered]@{ ip_address = '192.0.2.12'; username = 'node-admin'; password = 'env://AZL_HW_TEST_NODE_PASSWORD' }
            $i = New-InfraFile -Nodes @(
                [ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = '192.0.2.11' } }
                [ordered]@{ name = 'iic-azl-n02'; bmc = $own })
            $null = Invoke-Inventory $i.File
            @($global:AzlHwBmc.Calls | Where-Object Host -EQ '192.0.2.11' | ForEach-Object User | Select-Object -Unique) | Should -Be @('admin-test')
            @($global:AzlHwBmc.Calls | Where-Object Host -EQ '192.0.2.12' | ForEach-Object User | Select-Object -Unique) | Should -Be @('node-admin')
        }

        It 'never writes the password into the file, the output or the log' {
            $log = Join-Path $TestDrive 'run.log'
            $i = New-InfraFile
            $global:LASTEXITCODE = $null
            $all = & $script:Script -InfrastructureFile $i.File -LogPath $log 6>&1 3>&1 2>&1
            $content = (Get-Content -LiteralPath (Get-ChildItem -LiteralPath $i.Directory).FullName -Raw) + (Get-Content -LiteralPath $log -Raw) + (($all | Out-String))
            $content | Should -Not -Match $script:Password
            $content | Should -Not -Match '(?i)authorization'
        }

        It 'reads the secret through the toolkit resolver: a failing reference stops the run before any BMC is contacted' {
            $env:AZL_HW_TEST_MISSING = $null
            $i = New-InfraFile -Bmc @{ password = 'env://AZL_HW_TEST_MISSING' }
            $r = Invoke-Inventory $i.File
            $r.ExitCode | Should -BeIn 1, 2
            $r.Text | Should -Match 'AZL_HW_TEST_MISSING'
            @($global:AzlHwBmc.Calls).Count | Should -Be 0
            Test-Path $i.Directory | Should -BeFalse
        }
    }

    Context 'output location and format come from the file' {
        It 'writes YAML when hardware.inventory.format is yaml' {
            $i = New-InfraFile -Inventory @{ format = 'yaml' }
            $r = Invoke-Inventory $i.File
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $f = @(Get-ChildItem -LiteralPath $i.Directory -File)
            $f.Count | Should -Be 1
            $f[0].Name | Should -Match '^iic-hw-\d{8}T\d{6}Z\.yml$'
            $y = Get-Content -LiteralPath $f[0].FullName -Raw | ConvertFrom-Yaml
            $y.kind | Should -Be 'hardware-inventory'
            @($y.nodes).Count | Should -Be 3
        }

        It 'uses the file name prefix and the directory of the file' {
            $i = New-InfraFile -Inventory @{ file_name_prefix = 'iic-inventory' }
            $null = Invoke-Inventory $i.File
            (Get-ChildItem -LiteralPath $i.Directory -File)[0].Name | Should -Match '^iic-inventory-'
        }

        It 'writes one new file on every run and keeps the old one' {
            $i = New-InfraFile
            $null = Invoke-Inventory $i.File
            $null = Invoke-Inventory $i.File
            @(Get-ChildItem -LiteralPath $i.Directory -File).Count | Should -Be 2
        }
    }

    Context '-WhatIf' {
        It 'plans the run, contacts no BMC and writes no file' {
            $i = New-InfraFile
            $r = Invoke-Inventory $i.File -DryRun
            $r.ExitCode | Should -Be 0
            @($r.Rows.Result) | Should -Be @('WouldRead', 'WouldRead', 'WouldRead')
            $r.Text | Should -Match 'would be written'
            @($global:AzlHwBmc.Calls).Count | Should -Be 0
            Test-Path $i.Directory | Should -BeFalse
        }
    }

    Context 'a BMC that cannot be read' {
        It 'records it as failed, still reads the others, writes the file, and exits 1' {
            $global:AzlHwBmc.Tree.Remove('192.0.2.12')
            $i = New-InfraFile
            $r = Invoke-Inventory $i.File
            $r.ExitCode | Should -Be 1
            @($r.Rows.Result) | Should -Be @('Read', 'Failed', 'Read')
            $nodes = (Read-InventoryFile $i.Directory).Json.nodes
            $nodes[1].status | Should -Be 'failed'
            $nodes[1].error | Should -Not -BeNullOrEmpty
            $nodes[0].status | Should -Be 'read'
        }

        It 'stops at rejected credentials after a few tries instead of locking the account' {
            $global:AzlHwBmc.Status['192.0.2.11/redfish/v1'] = 401
            $i = New-InfraFile -Nodes @([ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = '192.0.2.11' } })
            $r = Invoke-Inventory $i.File
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Result | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'credentials'
            @($global:AzlHwBmc.Calls).Count | Should -BeLessOrEqual 3
        }

        It 'reads a node whose areas are only partly available and lists what is missing' {
            $global:AzlHwBmc.Tree['192.0.2.13'].Remove('/redfish/v1/Systems/Self/Memory')
            $i = New-InfraFile
            $r = Invoke-Inventory $i.File
            $r.ExitCode | Should -Be 0
            ((Read-InventoryFile $i.Directory).Json.nodes[2]).memory.modules | Should -BeNullOrEmpty
        }
    }

    Context 'a node without a BMC address' {
        It 'skips it and reads the rest' {
            $i = New-InfraFile -Nodes @(
                [ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = '192.0.2.11' } }
                [ordered]@{ name = 'iic-azl-n02' })
            $r = Invoke-Inventory $i.File
            $r.ExitCode | Should -Be 0
            @($r.Rows.Result) | Should -Be @('Read', 'Skipped')
            @((Read-InventoryFile $i.Directory).Json.nodes).Count | Should -Be 1
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, no BMC contacted)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a password that is not a secret reference'; Make = { New-InfraFile -Bmc @{ password = 'plain-text-password-value' } } }
            @{ Why = 'a missing BMC login'; Make = { New-InfraFile -NoSharedBmc } }
            @{ Why = 'a bad format'; Make = { New-InfraFile -Inventory @{ format = 'xml' } } }
            @{ Why = 'a timeout that is not a number'; Make = { New-InfraFile -Inventory @{ timeout_seconds = 'soon' } } }
            @{ Why = 'a timeout below the limit'; Make = { New-InfraFile -Inventory @{ timeout_seconds = 1 } } }
            @{ Why = 'a file name prefix with a path in it'; Make = { New-InfraFile -Inventory @{ file_name_prefix = '..\x' } } }
            @{ Why = 'a BMC address that is not IPv4'; Make = { New-InfraFile -Nodes @([ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = 'bmc.example.invalid' } }) } }
            @{ Why = 'a node listed twice'; Make = { New-InfraFile -Nodes @([ordered]@{ name = 'iic-azl-n01'; bmc = [ordered]@{ ip_address = '192.0.2.11' } }, [ordered]@{ name = 'IIC-AZL-N01'; bmc = [ordered]@{ ip_address = '192.0.2.12' } }) } }
            @{ Why = 'no node with a BMC address'; Make = { New-InfraFile -Nodes @([ordered]@{ name = 'iic-azl-n01' }) } }
        ) {
            $i = & $Make
            $r = Invoke-Inventory $i.File
            $r.ExitCode | Should -Be 2 -Because $r.Text
            @($global:AzlHwBmc.Calls).Count | Should -Be 0
            $r.Text | Should -Not -Match 'plain-text-password-value'
        }

        It 'exits 2 for a file that cannot be read' {
            (Invoke-Inventory (Join-Path $TestDrive 'does-not-exist.yml')).ExitCode | Should -Be 2
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            $script:Module = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'common', 'redfish', 'AzlRedfishInventory.psm1')) -Raw
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|-AsPlainText'
        }

        It 'reads its values through the toolkit loader and the secret resolver, and names no vault' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Match 'Get-AzlSecretValue'
            $script:Text | Should -Match 'AzlSecret\.psm1'
            $script:Text | Should -Not -Match '(?i)Get-AzKeyVaultSecret|keyvault://[A-Za-z]|\bkv-[a-z0-9]'
        }

        It 'holds no address, GUID, subscription, tenant or vendor path' {
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
            $script:Text | Should -Not -MatchExactly 'Oem\.|/Oem|iDRAC\.Embedded|System\.Embedded|AzlRedfishDell'
            $script:Module | Should -Not -MatchExactly '\bOem\b|/Oem|iDRAC\.Embedded|System\.Embedded|AzlRedfishDell'
        }

        It 'sends no write request: no HTTP cmdlet of its own and no method other than GET' {
            $script:Text | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod|-Method\s+(Post|Put|Patch|Delete)'
            $script:Module | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod|-Method\s+(Post|Put|Patch|Delete)'
            $script:Text | Should -Match '-Vendor None -Detail Inventory'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Get_HardwareInventory_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'LogPath'
        }

        It 'reads only registry keys that exist: <_>' -ForEach @(
            'nodes[].name', 'nodes[].bmc.ip_address', 'nodes[].bmc.type', 'nodes[].bmc.username', 'nodes[].bmc.password', 'nodes[].serial_number'
            'hardware.bmc.username', 'hardware.bmc.password', 'hardware.bmc.verify_certificate'
            'hardware.inventory.output_directory', 'hardware.inventory.file_name_prefix', 'hardware.inventory.format', 'hardware.inventory.timeout_seconds'
            'hardware.vendor', 'hardware.model', 'hardware.cpu_cores', 'hardware.memory_gib', 'hardware.gpu.enabled', 'hardware.gpu.model', 'hardware.gpu.count_per_node'
            'hardware.drives.capacity.media', 'hardware.drives.capacity.count', 'hardware.drives.capacity.size_tb'
            'hardware.drives.cache.media', 'hardware.drives.cache.count', 'hardware.drives.cache.size_tb'
        ) {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }

        It 'names every key it reads in its help text' {
            foreach ($k in 'hardware.inventory', 'output_directory', 'file_name_prefix', 'timeout_seconds', 'verify_certificate') { $script:Text | Should -Match ([regex]::Escape($k)) -Because $k }
        }
    }
}
