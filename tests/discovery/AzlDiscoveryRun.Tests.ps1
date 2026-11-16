#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Invoke-AzlDiscoveryRun.ps1 (the one discovery run of the discovery pipelines): the steps it runs, the folders and the report it writes,
# the exit codes, and that the write-back never changes the file it is given. The four discovery scripts and the updater are stubs in a
# fake toolkit folder: no BMC, no Azure, no Active Directory is contacted. Nothing is run against a real file.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/discovery/AzlDiscoveryRun.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Run = [IO.Path]::Combine($script:Repo, 'scripts', 'common', 'discovery', 'Invoke-AzlDiscoveryRun.ps1')
    $script:Hardware = 'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell'

    # A fake toolkit: each stub records its parameters (names and values) as one JSON line in STUB_LOG and exits with STUB_EXIT_<name>.
    $script:Toolkit = Join-Path $TestDrive 'toolkit'
    $stub = @'
[CmdletBinding()]
param([string]$InfrastructureFile, [string]$OutputPath, [string]$DiscoveryPath, [string]$ManagementPort, [switch]$IncludeRBAC, [switch]$Apply, [switch]$Force)
$name = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
$bound = [ordered]@{}
foreach ($k in $PSBoundParameters.Keys) { $v = $PSBoundParameters[$k]; $bound[$k] = if ($v -is [switch]) { $v.IsPresent } else { $v } }
([ordered]@{ script = $name; cwd = (Get-Location).Path; parameters = $bound } | ConvertTo-Json -Compress -Depth 4) | Add-Content -LiteralPath $env:STUB_LOG
$exit = [Environment]::GetEnvironmentVariable("STUB_EXIT_$name")
if ($exit -eq 'throw') { throw "$name failed on purpose." }
switch ($name) {
    'Get-HardwareInventory' { New-Item -ItemType Directory -Path 'hardware-inventory' -Force | Out-Null; Set-Content -LiteralPath 'hardware-inventory/hardware-inventory-1.json' -Value '{}' }
    'Invoke-HardwareDiscovery' { Set-Content -LiteralPath (Join-Path $OutputPath 'TAG1.json') -Value '{}' }
    'Inventory-AzureTenant' { Set-Content -LiteralPath (Join-Path $OutputPath 'azure-inventory.json') -Value '{}' }
    'Get-OnPremInventory' { New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null; Set-Content -LiteralPath $OutputPath -Value '[]' }
    'Update-InfrastructureYml-FromDiscovery' {
        Add-Content -LiteralPath $InfrastructureFile -Value '# discovered'
        Copy-Item -LiteralPath $InfrastructureFile -Destination "$InfrastructureFile.bak.20260101"
        Write-Information "Changes to $InfrastructureFile :" -InformationAction Continue
        Write-Information '  nodes[0].serial_number: (not set) -> TAG1' -InformationAction Continue
    }
}
if ($exit) { exit [int]$exit }
exit 0
'@
    foreach ($relative in "$script:Hardware/Get-HardwareInventory.ps1", "$script:Hardware/Invoke-HardwareDiscovery.ps1", "$script:Hardware/Update-InfrastructureYml-FromDiscovery.ps1",
        'scripts/common/discovery/Inventory-AzureTenant.ps1', 'scripts/common/discovery/Get-OnPremInventory.ps1') {
        $path = Join-Path $script:Toolkit $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value $stub -Encoding utf8NoBOM
    }
    $script:InfraFile = Join-Path $TestDrive 'infrastructure.yml'

    function Invoke-Discovery {
        param([string]$Arguments = '', [hashtable]$Environment = @{})
        $out = Join-Path $TestDrive ('out-' + [guid]::NewGuid().ToString('N'))
        $log = Join-Path $TestDrive ('log-' + [guid]::NewGuid().ToString('N') + '.jsonl')
        Set-Content -LiteralPath $script:InfraFile -Value "schema_version: '5.0'`nnodes: []`n" -Encoding utf8NoBOM
        $saved = @{}
        $names = @('STUB_LOG') + @($Environment.Keys)
        foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
        try {
            $env:STUB_LOG = $log
            foreach ($k in $Environment.Keys) { [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
            $command = "& '$script:Run' -InfrastructureFile '$script:InfraFile' -OutputDirectory '$out' -ToolkitRoot '$script:Toolkit' $Arguments; exit `$LASTEXITCODE"
            $console = & pwsh -NoProfile -NonInteractive -Command $command 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally { foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
        [pscustomobject]@{
            ExitCode = $code; Console = $console; Out = $out
            Calls    = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { $_ | ConvertFrom-Json } })
            Report   = $(if (Test-Path -LiteralPath (Join-Path $out 'discovery-report.json')) { Get-Content -LiteralPath (Join-Path $out 'discovery-report.json') -Raw | ConvertFrom-Json })
        }
    }
}

Describe 'Invoke-AzlDiscoveryRun.ps1' {
    It 'has the usual script header and a parameter for each thing a pipeline sets' {
        $text = Get-Content -LiteralPath $script:Run -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match '(?m)^Set-StrictMode -Version Latest'
        $text | Should -Match "(?m)^\`$ErrorActionPreference = 'Stop'"
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Run, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Be @('InfrastructureFile', 'OutputDirectory', 'Scope', 'ManagementPort', 'WriteBack', 'IncludeRBAC', 'ToolkitRoot')
        # nothing here takes a password, a token or a credential: the BMC login is the secret reference of the file
        ($names -join ' ') | Should -Not -Match '(?i)password|token|credential|secret'
    }
    It 'calls only scripts that exist in this toolkit' {
        $text = Get-Content -LiteralPath $script:Run -Raw
        foreach ($m in [regex]::Matches($text, "'(scripts/common/discovery/[A-Za-z-]+\.ps1)'")) { Test-Path -LiteralPath (Join-Path $script:Repo $m.Groups[1].Value) | Should -BeTrue -Because $m.Groups[1].Value }
        foreach ($n in 'Get-HardwareInventory.ps1', 'Invoke-HardwareDiscovery.ps1', 'Update-InfrastructureYml-FromDiscovery.ps1') {
            Test-Path -LiteralPath (Join-Path $script:Repo "$script:Hardware/$n") | Should -BeTrue -Because $n
            $text | Should -Match ([regex]::Escape($n))
        }
    }

    It 'exits 2 and runs nothing when the file does not exist' {
        $out = Join-Path $TestDrive 'none'
        $env:STUB_LOG = Join-Path $TestDrive 'none.jsonl'
        & pwsh -NoProfile -NonInteractive -File $script:Run -InfrastructureFile (Join-Path $TestDrive 'missing.yml') -OutputDirectory $out -ToolkitRoot $script:Toolkit 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 2
        Test-Path -LiteralPath $env:STUB_LOG | Should -BeFalse
        $env:STUB_LOG = $null
    }
    It 'exits 2, runs nothing and creates no output when the file cannot be parsed (<Case>)' -ForEach @(
        @{ Case = 'broken YAML'; Content = "nodes: [`n  - name: a`n  bad: {`n    unclosed" }
        @{ Case = 'a tab and a stray colon'; Content = "nodes:`n`t- name: a`n: :`n" }
        @{ Case = 'not a mapping'; Content = "- one`n- two`n" }
        @{ Case = 'a plain scalar'; Content = "just some text`n" }
    ) {
        $file = Join-Path $TestDrive ('broken-' + [guid]::NewGuid().ToString('N') + '.yml')
        Set-Content -LiteralPath $file -Value $Content -Encoding utf8NoBOM
        $out = Join-Path $TestDrive ('broken-out-' + [guid]::NewGuid().ToString('N'))
        $env:STUB_LOG = Join-Path $TestDrive ('broken-' + [guid]::NewGuid().ToString('N') + '.jsonl')
        $text = & pwsh -NoProfile -NonInteractive -File $script:Run -InfrastructureFile $file -OutputDirectory $out -ToolkitRoot $script:Toolkit 2>&1 | Out-String
        $code = $LASTEXITCODE
        $log = $env:STUB_LOG
        $env:STUB_LOG = $null
        $code | Should -Be 2 -Because $text
        $text | Should -Match 'cannot be read'
        Test-Path -LiteralPath $log | Should -BeFalse -Because 'no discovery script was started'
        Test-Path -LiteralPath $out | Should -BeFalse -Because 'nothing was created'
    }
    It 'accepts a file that parses but is not complete (discovery is what fills it in)' {
        $r = Invoke-Discovery -Arguments '-Scope HardwareInventory'
        $r.ExitCode | Should -Be 0 -Because $r.Console
    }
    It 'exits 2 and runs nothing for -WriteBack without DellDiscovery' {
        $r = Invoke-Discovery -Arguments '-WriteBack'
        $r.ExitCode | Should -Be 2
        $r.Calls.Count | Should -Be 0
    }

    It 'runs the hardware inventory, the Azure tenant and the Active Directory by default, each into its own folder, and passes the file' {
        $r = Invoke-Discovery
        $r.ExitCode | Should -Be 0 -Because $r.Console
        @($r.Calls | ForEach-Object { $_.script }) | Should -Be @('Get-HardwareInventory', 'Inventory-AzureTenant', 'Get-OnPremInventory')
        foreach ($c in $r.Calls) { $c.parameters.InfrastructureFile | Should -Be $script:InfraFile }
        ($r.Calls | Where-Object script -EQ 'Inventory-AzureTenant').parameters.OutputPath | Should -Be (Join-Path $r.Out 'azure-tenant')
        ($r.Calls | Where-Object script -EQ 'Get-OnPremInventory').parameters.OutputPath | Should -Be (Join-Path $r.Out (Join-Path 'ad-inventory' 'ad-inventory.json'))
        # the hardware inventory writes where the file says, relative to the folder it runs in: that folder is this run's
        ($r.Calls | Where-Object script -EQ 'Get-HardwareInventory').cwd | Should -Be (Join-Path $r.Out 'hardware-inventory')
        $r.Report.verdict | Should -Be 'Pass'
        @($r.Report.steps | ForEach-Object { $_.name }) | Should -Be @('HardwareInventory', 'AzureTenant', 'ActiveDirectory')
        @(($r.Report.steps | Where-Object name -EQ 'HardwareInventory').files) | Should -Be @('hardware-inventory/hardware-inventory/hardware-inventory-1.json')
        @(($r.Report.steps | Where-Object name -EQ 'AzureTenant').files) | Should -Be @('azure-tenant/azure-inventory.json')
        Test-Path -LiteralPath (Join-Path $r.Out 'summary.md') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $r.Out 'summary.md') -Raw) | Should -Match 'Verdict: \*\*Pass\*\*'
    }
    It 'passes no credential, password or token to any step, and the report names the file, not its path' {
        $r = Invoke-Discovery -Arguments '-Scope HardwareInventory,DellDiscovery,AzureTenant,ActiveDirectory -IncludeRBAC'
        $r.ExitCode | Should -Be 0 -Because $r.Console
        foreach ($c in $r.Calls) { @($c.parameters.PSObject.Properties.Name) | Should -Not -Contain 'Credential' }
        (Get-Content -LiteralPath (Join-Path $r.Out 'discovery-report.json') -Raw) | Should -Not -Match ([regex]::Escape($TestDrive))
        $r.Report.infrastructureFile | Should -Be 'infrastructure.yml'
        ($r.Calls | Where-Object script -EQ 'Inventory-AzureTenant').parameters.IncludeRBAC | Should -BeTrue
    }
    It 'passes the management port to the Dell discovery only' {
        $r = Invoke-Discovery -Arguments "-Scope DellDiscovery,AzureTenant -ManagementPort 'Slot 3 Port 1'"
        ($r.Calls | Where-Object script -EQ 'Invoke-HardwareDiscovery').parameters.ManagementPort | Should -Be 'Slot 3 Port 1'
        ($r.Calls | Where-Object script -EQ 'Inventory-AzureTenant').parameters.PSObject.Properties.Name | Should -Not -Contain 'ManagementPort'
    }

    It 'runs every step, reports each failure and exits 1 when a step fails' {
        $r = Invoke-Discovery -Environment @{ 'STUB_EXIT_Inventory-AzureTenant' = '3' }
        $r.ExitCode | Should -Be 1
        $r.Calls.Count | Should -Be 3
        $r.Report.verdict | Should -Be 'Fail'
        $tenant = $r.Report.steps | Where-Object name -EQ 'AzureTenant'
        $tenant.status | Should -Be 'Failed'
        $tenant.exitCode | Should -Be 3
        ($r.Report.steps | Where-Object name -EQ 'ActiveDirectory').status | Should -Be 'Succeeded'
    }
    It 'treats a script that throws as a failed step' {
        $r = Invoke-Discovery -Arguments '-Scope DellDiscovery' -Environment @{ 'STUB_EXIT_Invoke-HardwareDiscovery' = 'throw' }
        $r.ExitCode | Should -Be 1
        $step = $r.Report.steps[0]
        $step.status | Should -Be 'Failed'
        $step.message | Should -Match 'failed on purpose'
    }

    It '-WriteBack changes a copy of the file in the output directory and never the file itself' {
        $r = Invoke-Discovery -Arguments '-Scope DellDiscovery -WriteBack'
        $r.ExitCode | Should -Be 0 -Because $r.Console
        (Get-Content -LiteralPath $script:InfraFile -Raw) | Should -Not -Match 'discovered'
        $copy = Join-Path $r.Out (Join-Path 'write-back' 'infrastructure.yml')
        (Get-Content -LiteralPath $copy -Raw) | Should -Match '# discovered'
        (Get-Content -LiteralPath (Join-Path $r.Out (Join-Path 'write-back' 'changes.txt')) -Raw) | Should -Match 'serial_number'
        @(Get-ChildItem -LiteralPath (Join-Path $r.Out 'write-back') -Filter '*.bak.*').Count | Should -Be 0
        $update = $r.Calls | Where-Object script -EQ 'Update-InfrastructureYml-FromDiscovery'
        $update.parameters.InfrastructureFile | Should -Be $copy
        $update.parameters.DiscoveryPath | Should -Be (Join-Path $r.Out 'hardware-discovery')
        $r.Report.writeBack.applied | Should -BeTrue
        $r.Report.writeBack.file | Should -Be 'write-back/infrastructure.yml'
    }
    It '-WriteBack is skipped, and the run fails, when the Dell discovery failed' {
        $r = Invoke-Discovery -Arguments '-Scope DellDiscovery -WriteBack' -Environment @{ 'STUB_EXIT_Invoke-HardwareDiscovery' = '1' }
        $r.ExitCode | Should -Be 1
        @($r.Calls | Where-Object script -EQ 'Update-InfrastructureYml-FromDiscovery').Count | Should -Be 0
        $r.Report.writeBack.applied | Should -BeFalse
        $r.Report.verdict | Should -Be 'Fail'
    }
}
