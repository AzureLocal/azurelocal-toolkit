#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# scripts/validation/storage-tests/powershell/Test-StoragePerformance.ps1. The file had a syntax error ("$healthStatus:" in a string), so no one
# could run it. These tests check that it parses, that no script of the toolkit has a parse error (the parked and the paid-security scripts
# are named below), that it holds no limit a deployment chooses and never prompts, and that its checks work against fake cluster objects.
# The script runs in a child process with stub cmdlets; nothing reaches a cluster, a node or Azure.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/storage/StoragePerformance.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($script:Repo, 'scripts', 'validation', 'storage-tests', 'powershell', 'Test-StoragePerformance.ps1')
    $script:Pwsh = (Get-Process -Id $PID).Path
    Import-Module powershell-yaml

    function Get-ParseError([string]$Path) {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        @($errors)
    }

    # A wrapper that defines stub cmdlets with fake objects, then runs the script. -Pool and -Csv name what the fakes look like.
    function Invoke-WithFakes {
        param([string]$PoolHealth = 'Healthy', [double]$CsvUsedPercent = 40, [string[]]$Argument = @())
        $size = 10TB
        $free = [int64]($size * (100 - $CsvUsedPercent) / 100)
        $wrapper = Join-Path $TestDrive "wrap-$([guid]::NewGuid().ToString('N').Substring(0, 6)).ps1"
        $text = @"
`$ErrorActionPreference = 'Stop'
function Get-StoragePool { [CmdletBinding()] param([string]`$CimSession) [pscustomobject]@{ IsPrimordial = `$false; FriendlyName = 'iic-pool'; HealthStatus = '$PoolHealth'; OperationalStatus = 'OK'; Size = 20TB; AllocatedSize = 5TB } }
function Get-VirtualDisk { [CmdletBinding()] param([string]`$CimSession) [pscustomobject]@{ FriendlyName = 'iic-vd'; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; ResiliencySettingName = 'Mirror'; FaultDomainAwareness = 'StorageScaleUnit'; Size = 1TB; FootprintOnPool = 2TB } }
function Get-PhysicalDisk { [CmdletBinding()] param([string]`$CimSession) [pscustomobject]@{ FriendlyName = 'iic-pd'; Usage = 'Auto-Select'; CanPool = `$false; MediaType = 'SSD'; HealthStatus = 'Healthy'; OperationalStatus = 'OK' } }
function Get-ClusterNode { [CmdletBinding()] param([string]`$Cluster) [pscustomobject]@{ Name = 'iic-n01'; State = 'Up' }; [pscustomobject]@{ Name = 'iic-n02'; State = 'Up' } }
function Get-ClusterSharedVolume { [CmdletBinding()] param([string]`$Cluster) [pscustomobject]@{ Name = 'iic-csv'; State = 'Online'; OwnerNode = [pscustomobject]@{ Name = 'iic-n01' }; SharedVolumeInfo = @([pscustomobject]@{ FriendlyVolumeName = 'C:\ClusterStorage\iic-csv'; Partition = [pscustomobject]@{ Size = [int64]$size; FreeSpace = [int64]$free } }) } }
& '$($script:Script.Replace("'", "''"))' -ClusterName 'iic-azl-01' $($Argument -join ' ')
exit `$LASTEXITCODE
"@
        Set-Content -LiteralPath $wrapper -Value $text
        $out = & $script:Pwsh -NoProfile -NonInteractive -File $wrapper 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $out }
    }
}

Describe 'Test-StoragePerformance.ps1 parses' {
    It 'has no syntax error (the string with "<name>:" is delimited with braces)' {
        Get-ParseError $script:Script | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $script:Script -Raw) | Should -Match '\$\{healthStatus\}:'
    }

    It 'has no variable followed by a colon in any double-quoted string of the script' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
        $strings = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
        foreach ($s in $strings) {
            # a simple variable (not $( ), not ${ }) directly before a colon reads as a drive or scope name
            $s.Extent.Text | Should -Not -Match '(?<![\$`])\$[A-Za-z_]\w*:(?![\w:\\])' -Because $s.Extent.Text
        }
    }

    It 'every script and module of the toolkit parses, except the parked scripts and the paid-security scripts' {
        # scripts/deferred is parked; scripts/optional/paid-security-services is out of scope (paid Defender plans) and has parse errors of its own.
        $bad = foreach ($f in Get-ChildItem -LiteralPath $script:Repo -Recurse -File -Include '*.ps1', '*.psm1' | Where-Object {
                $_.FullName -notmatch '[\\/](\.git|node_modules|deferred)[\\/]' -and $_.FullName -notmatch '[\\/]optional[\\/]paid-security-services[\\/]' }) {
            $e = Get-ParseError $f.FullName
            if ($e.Count) { "$($f.FullName.Substring($script:Repo.Length + 1)): line $($e[0].Extent.StartLineNumber): $($e[0].Message)" }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'Test-StoragePerformance.ps1 holds no value a deployment chooses and never prompts' {
    BeforeAll {
        $script:Text = Get-Content -LiteralPath $script:Script -Raw
        Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
        $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
    }

    It 'carries the standard header' {
        $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
        $script:Text | Should -Match '(?m)^Set-StrictMode -Version Latest'
        $script:Text | Should -Match "(?m)^\`$ErrorActionPreference = 'Stop'"
    }

    It 'never prompts and signs in nowhere' {
        $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|Connect-AzAccount|Pause'
    }

    It 'has no cluster name, address or ID in the code' {
        $code = ($script:Text -replace '(?s)<#.*?#>', '')
        $code | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
        $code | Should -Not -Match '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
        $code | Should -Not -Match "-ClusterName\s+['""]"
    }

    It 'compares against parameters, not against a number in the code: <_>' -ForEach 'UsagePercent -gt \$CsvUsageWarningPercent', 'AvgWriteLatencyMs -gt \$MaxAvgWriteLatencyMs', 'AvgReadLatencyMs -gt \$MaxAvgReadLatencyMs' {
        $script:Text | Should -Match $_
        $script:Text | Should -Not -Match 'UsagePercent -gt \d|AvgWriteLatencyMs -gt \d|AvgReadLatencyMs -gt \d'
    }

    It 'does not dot-source the logging helper (its Write-Log rejects the levels this script uses)' {
        $script:Text | Should -Not -Match '(?m)^\s*\.\s+\(Join-Path'
        $script:Text | Should -Not -Match 'logging\.ps1'
    }

    It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
        $names = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.scripts_validation_storage_tests_powershell_Test_StoragePerformance_ps1[^.]*\.[^.]+$' } | ForEach-Object { $_.Node['name'] })
        foreach ($p in 'ClusterName', 'VolumeNames', 'RunPerformanceTest', 'DurationSeconds', 'CsvUsageWarningPercent', 'MaxAvgWriteLatencyMs', 'MaxAvgReadLatencyMs', 'OutputPath') {
            $names | Should -Contain $p -Because $p
        }
    }
}

Describe 'Test-StoragePerformance.ps1 against fake cluster objects' {
    It 'exits 0 and logs no error when pool, disks and volume are healthy' {
        $r = Invoke-WithFakes
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Text | Should -Match 'Pool: iic-pool - Healthy'
        $r.Text | Should -Match 'Storage validation complete'
    }

    It 'logs an unhealthy pool with its status and a colon, and exits 1' {
        $r = Invoke-WithFakes -PoolHealth 'Unhealthy'
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match 'Pool: iic-pool - Unhealthy: OK'
    }

    It 'warns about a volume above the limit (default 85 percent) and not below it' {
        (Invoke-WithFakes -CsvUsedPercent 90).Text | Should -Match 'WARNING: 90% used, limit 85%'
        (Invoke-WithFakes -CsvUsedPercent 80).Text | Should -Not -Match 'WARNING: 80% used'
    }

    It 'takes the volume limit from -CsvUsageWarningPercent' {
        (Invoke-WithFakes -CsvUsedPercent 60 -Argument '-CsvUsageWarningPercent', '50').Text | Should -Match 'WARNING: 60% used, limit 50%'
        (Invoke-WithFakes -CsvUsedPercent 90 -Argument '-CsvUsageWarningPercent', '95').Text | Should -Not -Match 'WARNING: 90% used'
    }

    It 'refuses a duration below 2 seconds and a percent above 100' {
        (Invoke-WithFakes -Argument '-DurationSeconds', '1').ExitCode | Should -Not -Be 0
        (Invoke-WithFakes -Argument '-CsvUsageWarningPercent', '101').ExitCode | Should -Not -Be 0
    }

    It 'saves the results to -OutputPath and creates the folder' {
        $out = Join-Path $TestDrive 'results-new'
        $r = Invoke-WithFakes -Argument '-OutputPath', "'$out'"
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-ChildItem -LiteralPath $out -Filter 'storage-test-*.json').Count | Should -Be 1
    }
}
