#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The code scanner of the variable map (config/variables/scripts/VariableMapScanner.psm1) follows a helper function that reads one key of a
# map: Get-Field $item 'name' on an item of a list the script got from the file with Get-AzlInfrastructureValue. The helper is proven from its
# own body, so a function that only has the same name is not a reader. Small made-up scripts are scanned; nothing is run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/VariableMapScanner.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers write files in TestDrive.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableMapScanner.psm1')) -Force

    # A small registry: the paths the scripts below read, and which of them are lists.
    $records = @(
        foreach ($p in 'storage', 'storage.pool', 'storage.pool.name', 'storage.volumes', 'storage.volumes[].name', 'storage.volumes[].size_gib', 'storage.volumes[].deduplication',
            'storage.volumes[].deduplication.type', 'storage.paths', 'storage.paths[].name', 'storage.paths[].path', 'storage.vm_images', 'storage.vm_images[].publisher',
            'storage.vm_images[].offer', 'storage.vm_images[].sku', 'operations', 'operations.monitoring', 'operations.monitoring.action_group', 'operations.monitoring.alert_email',
            'cluster', 'cluster.name') {
            [pscustomobject]@{ Path = $p; Shape = $(if ($p -in 'storage.volumes', 'storage.paths', 'storage.vm_images') { 'array' } else { 'scalar' }) }
        }
    )
    $script:Index = Get-MapIndex -Record $records

    function Get-ScanResult {
        param([Parameter(Mandatory)][string]$Code, [switch]$ReportUnknown)
        $file = Join-Path $TestDrive "scan-$([guid]::NewGuid().ToString('N').Substring(0, 8)).ps1"
        Set-Content -LiteralPath $file -Value $Code
        $found = @(Find-MapReader -Root $TestDrive -File $file -Index $script:Index -ReportUnknown:$ReportUnknown)
        [pscustomobject]@{ Records = $found; Paths = @($found | Where-Object { $_.Mode -ne 'unknown' } | ForEach-Object { $_.Path } | Sort-Object -Unique); Unknown = @($found | Where-Object { $_.Mode -eq 'unknown' }) }
    }
}

Describe 'A helper that reads one key of a map' {
    It 'resolves the keys of a list item read with Get-Field: the list, its fields and a nested section' {
        $r = Get-ScanResult @'
function Get-Field($Map, [string]$Key, $Default = $null) {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key]) { return $Map[$Key] }
    $Default
}
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$pool = Get-Field $storage 'pool'
$poolName = ([string](Get-Field $pool 'name' '')).Trim()
$volumeList = @(@(Get-Field $storage 'volumes' @()) | Where-Object { $null -ne $_ })
foreach ($volume in $volumeList) {
    $name = ([string](Get-Field $volume 'name' '')).Trim()
    $size = Get-Field $volume 'size_gib' ''
    $dedup = Get-Field $volume 'deduplication'
    $type = ([string](Get-Field $dedup 'type' 'none')).ToLowerInvariant()
}
'@
        $r.Paths | Should -Contain 'storage.pool.name'
        $r.Paths | Should -Contain 'storage.volumes'
        $r.Paths | Should -Contain 'storage.volumes[].name'
        $r.Paths | Should -Contain 'storage.volumes[].size_gib'
        $r.Paths | Should -Contain 'storage.volumes[].deduplication.type'
    }

    It 'reads a nested call: Get-Field (Get-Field $storage ''pool'') ''name''' {
        $r = Get-ScanResult @'
function Get-Field($Map, [string]$Key, $Default = $null) { if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key)) { return $Map[$Key] }; $Default }
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$x = Get-Field (Get-Field $storage 'pool') 'name'
'@
        $r.Paths | Should -Contain 'storage.pool.name'
    }

    It 'resolves keys given by the loop variable of a foreach over literals' {
        $r = Get-ScanResult @'
function Get-Field($Map, [string]$Key, $Default = $null) { if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key)) { return $Map[$Key] }; $Default }
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$imageList = @(Get-Field $storage 'vm_images' @())
foreach ($entry in $imageList) {
    foreach ($key in 'publisher', 'offer', 'sku') { $value = ([string](Get-Field $entry $key '')).Trim() }
}
'@
        $r.Paths | Should -Contain 'storage.vm_images[].publisher'
        $r.Paths | Should -Contain 'storage.vm_images[].offer'
        $r.Paths | Should -Contain 'storage.vm_images[].sku'
        @($r.Records | Where-Object { $_.Path -eq 'storage.vm_images[].sku' }).Mode | Should -Be 'inferred'
    }

    It 'resolves the keys of a helper that reads a script variable: Get-Field ''action_group''' {
        $r = Get-ScanResult @'
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$monitoring = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.monitoring'
function Get-Field([string]$Key) {
    if ($monitoring -is [System.Collections.IDictionary] -and $monitoring.Contains($Key) -and $null -ne $monitoring[$Key]) { return ([string]$monitoring[$Key]).Trim() }
    ''
}
$groupName = Get-Field 'action_group'
$mail = Get-Field 'alert_email'
'@
        $r.Paths | Should -Contain 'operations.monitoring.action_group'
        $r.Paths | Should -Contain 'operations.monitoring.alert_email'
    }

    It 'follows a list read with one conditional: @(if ($storage.Contains(''paths'')) { $storage[''paths''] })' {
        $r = Get-ScanResult @'
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$pathList = @(@(if ($storage -is [System.Collections.IDictionary] -and $storage.Contains('paths')) { $storage['paths'] }) | Where-Object { $null -ne $_ })
foreach ($entry in $pathList) {
    $name = if ($entry.Contains('name')) { ([string]$entry['name']).Trim() } else { '' }
    $folder = if ($entry.Contains('path')) { ([string]$entry['path']).Trim() } else { '' }
}
'@
        $r.Paths | Should -Contain 'storage.paths[].name'
        $r.Paths | Should -Contain 'storage.paths[].path'
    }
}

Describe 'A helper is a reader only when its body proves it, and only on a map from the file' {
    It 'a function called Get-Field that does not index by its key parameter reads nothing' {
        $r = Get-ScanResult @'
function Get-Field($Map, [string]$Key, $Default = $null) { return "$Key" }
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$pool = Get-Field $storage 'pool'
$volumes = Get-Field $storage 'volumes'
'@
        $r.Paths | Should -Not -Contain 'storage.pool'
        $r.Paths | Should -Not -Contain 'storage.volumes'
    }

    It 'a call to a Get-Field that the script does not define reads nothing' {
        $r = Get-ScanResult @'
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$pool = Get-Field $storage 'pool'
'@
        $r.Paths | Should -Not -Contain 'storage.pool'
    }

    It 'a map that does not come from the file gives no path' {
        $r = Get-ScanResult @'
function Get-Field($Map, [string]$Key, $Default = $null) { if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key)) { return $Map[$Key] }; $Default }
$other = @{ pool = @{ name = 'x' } }
$pool = Get-Field $other 'pool'
$name = Get-Field $pool 'name'
'@
        $r.Paths | Should -BeNullOrEmpty
    }

    It 'a key the registry does not have gives no path and is not reported as unknown' {
        $r = Get-ScanResult -ReportUnknown @'
function Get-Field($Map, [string]$Key, $Default = $null) { if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key)) { return $Map[$Key] }; $Default }
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$x = Get-Field $storage 'nonsense'
'@
        $r.Paths | Should -Not -Contain 'storage.nonsense'
        @($r.Unknown | Where-Object { $_.Path -match 'nonsense' }).Count | Should -Be 0
    }

    It 'a key that is a variable outside any literal loop gives no path' {
        $r = Get-ScanResult @'
function Get-Field($Map, [string]$Key, $Default = $null) { if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key)) { return $Map[$Key] }; $Default }
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$storage = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage'
$x = Get-Field $storage $SomeParameter
'@
        $r.Paths | Should -Be @('storage') -Because 'only the read of the section itself'
    }

    It 'a pipeline with a call operator after the first element does not stop the scan' {
        $r = Get-ScanResult @'
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation
$names = $infra.cluster.name | & { process { $_ } }
'@
        $r.Paths | Should -Contain 'cluster.name'
    }
}

Describe 'The committed map shows the keys the field-reader scripts read as read' {
    BeforeAll { $script:Rows = @(Import-Csv -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'reports', 'variable-map.csv'))) }
    It '<_> has a reader' -ForEach @(
        'storage.volumes[].size_gib', 'storage.volumes[].file_system', 'storage.volumes[].deduplication.type', 'storage.pool.name',
        'storage.vm_images[].sku', 'storage.vm_images[].publisher', 'storage.san.luns[].unique_id', 'storage.san.luns[].name',
        'networking.network_security_groups[].name', 'networking.network_security_groups[].rules[].priority',
        'networking.logical_networks[].gateway', 'networking.logical_networks[].ip_pool.start', 'networking.logical_networks[].nsg_name',
        'operations.monitoring.action_group'
    ) {
        $row = $script:Rows | Where-Object path -EQ $_
        $row | Should -Not -BeNullOrEmpty
        $row.status | Should -Be 'read'
        $row.readers | Should -Not -BeNullOrEmpty
    }
}
