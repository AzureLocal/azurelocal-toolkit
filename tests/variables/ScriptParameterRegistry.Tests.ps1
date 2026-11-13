#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Every parameter of every script of the toolkit is a registered variable, and the registry is generated so it stays that way.
# config/variables/scripts/New-ScriptParameterRegistry.ps1 reads the param() block of each script with the PowerShell parser and writes
# the entries between two marker comments in tools.arm_deployment.parameters. These tests fail when:
#   * the generated block is stale (the script's -Check),
#   * a parameter of a script (scripts/, ansible/, tools/, pipelines/, the entry scripts of config/variables/scripts) is in no registry group,
#   * a registry group names a script and lists a parameter the script does not have,
#   * a parameter is registered twice for one script.
# The expected parameters are read with the parser here, not with the generator, so the two checks are independent.
# Reads files only; nothing runs against Azure or a node.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/ScriptParameterRegistry.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Scripts = [IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts')
    $script:Generator = [IO.Path]::Combine($script:Scripts, 'New-ScriptParameterRegistry.ps1')
    $script:RegistryPath = [IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')
    Import-Module ([IO.Path]::Combine($script:Scripts, 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path $script:RegistryPath)

    function Get-ExpectedScript {
        # script path (relative, forward slashes) -> @{ Names = parameter names; Error = text or $null }
        param([string]$Root)
        $files = [System.Collections.Generic.List[string]]::new()
        foreach ($sub in 'scripts', 'ansible', 'tools', 'pipelines') {
            $dir = Join-Path $Root $sub
            if (Test-Path -LiteralPath $dir) { foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.ps1') { $files.Add($f.FullName) } }
        }
        foreach ($f in Get-ChildItem -LiteralPath ([IO.Path]::Combine($Root, 'config', 'variables', 'scripts')) -File -Filter '*.ps1') { $files.Add($f.FullName) }
        $result = @{}
        foreach ($full in $files) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
            $relative = [IO.Path]::GetRelativePath($Root, $full).Replace('\', '/')
            $names = @()
            $broken = $null
            if ($ast.ParamBlock) {
                $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                $from = $ast.ParamBlock.Extent.StartOffset; $to = $ast.ParamBlock.Extent.EndOffset
                $inside = @($errors | Where-Object { $_.Extent.StartOffset -ge $from -and $_.Extent.StartOffset -le $to })
                if ($inside.Count) { $broken = $inside[0].Message }
            }
            elseif ($errors -and $errors.Count) { $broken = $errors[0].Message }
            $result[$relative] = @{ Names = $names; Error = $broken }
        }
        $result
    }

    # The registry groups under tools.<tool>.parameters: area (the script, when the area names one), the names they register, whether generated.
    function Get-ParameterGroup {
        param([object[]]$Record)
        $groups = @{}
        foreach ($r in $Record) { if ($r.Path -match '^tools\.(?<tool>[^.]+)\.parameters\.(?<group>[^.]+)$' -and $r.Node.Contains('area')) { $groups[$r.Path] = $r } }
        foreach ($r in $Record) {
            if ($r.Path -match '^(?<group>tools\.[^.]+\.parameters\.[^.]+)\.(?<name>[^.]+)$' -and $groups.ContainsKey($Matches['group']) -and $r.Node.Contains('name')) {
                $g = $groups[$Matches['group']]
                [pscustomobject]@{ Group = $Matches['group']; Area = [string]$g.Node['area']; Name = [string]$r.Node['name']; Key = $Matches['name']; Generated = $Matches['group'].EndsWith('_generated') }
            }
        }
    }

    $script:Expected = Get-ExpectedScript -Root $script:Repo
    $script:Registered = @(Get-ParameterGroup -Record $script:Registry)

    function Resolve-AreaScript([string]$Area) {
        if ($script:Expected.ContainsKey($Area)) { return $Area }
        if ($script:Expected.ContainsKey("scripts/$Area")) { return "scripts/$Area" }
        $null
    }

    # script -> the names the registry holds for it (every group whose area is the script)
    $script:ByScript = @{}
    foreach ($entry in $script:Registered) {
        $file = Resolve-AreaScript $entry.Area
        if ($file) {
            if (-not $script:ByScript.ContainsKey($file)) { $script:ByScript[$file] = [System.Collections.Generic.List[string]]::new() }
            $script:ByScript[$file].Add($entry.Name)
        }
    }

    # A small repository and registry for the behaviour tests.
    function New-MiniRepo {
        param([string]$Path)
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $Path 'scripts/area'), (Join-Path $Path 'schema'), (Join-Path $Path 'config/variables/scripts')
        $registry = @'
_metadata:
  version: "1.0.0"
tools:
  type: object
  properties:
    arm_deployment:
      type: object
      properties:
        config_keys:
          type: object
          properties: {}
        parameters:
          type: object
          properties:
            scripts_area_Hand_ps1:
              type: object
              area: "scripts/area/Hand.ps1"
              properties:
                Known: {"name":"Known","type":"string","declared_type":"string","required":"N","read_at":"scripts/area/Hand.ps1","description":"Hand.ps1. Written by hand."}
        event_fields:
          type: object
          properties: {}
'@
        Set-Content -LiteralPath (Join-Path $Path 'schema/master-registry.yaml') -Value $registry -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $Path 'scripts/area/Hand.ps1') -Encoding utf8NoBOM -Value @'
param([string]$Known, [string]$Extra = '')
'@
        Set-Content -LiteralPath (Join-Path $Path 'scripts/area/New-Thing.ps1') -Encoding utf8NoBOM -Value @'
<#
.PARAMETER InfrastructureFile
    The master file.
    Second line of the help.
.PARAMETER Mode
    What to do.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan',
    [int]$Count = 3,
    [switch]$Force,
    [string[]]$Names,
    $Yes
)
'@
        Set-Content -LiteralPath (Join-Path $Path 'scripts/area/Invoke-Later.ps1') -Encoding utf8NoBOM -Value @'
# PLACEHOLDER: this script does not do the task. It ends with exit code 3 (NOT IMPLEMENTED) and changes nothing.
param([string]$ConfigPath = '')
exit 3
'@
        Set-Content -LiteralPath (Join-Path $Path 'scripts/area/NoParameters.ps1') -Encoding utf8NoBOM -Value 'Write-Output 1'
    }
}

Describe 'The generated script parameter registry' {
    It 'is current: New-ScriptParameterRegistry.ps1 -Check passes' {
        $global:LASTEXITCODE = 0
        & $script:Generator -Check *>$null
        $LASTEXITCODE | Should -Be 0 -Because 'run ./config/variables/scripts/New-ScriptParameterRegistry.ps1 and commit the registry'
    }

    It 'has the markers once, in tools.arm_deployment.parameters' {
        $text = Get-Content -LiteralPath $script:RegistryPath -Raw
        ([regex]::Matches($text, '(?m)^\s+# BEGIN script-parameters ')).Count | Should -Be 1
        ([regex]::Matches($text, '(?m)^\s+# END script-parameters\r?$')).Count | Should -Be 1
        @($script:Registered | Where-Object { $_.Generated -and $_.Group -notmatch '^tools\.arm_deployment\.parameters\.' }) | Should -BeNullOrEmpty
    }
}

Describe 'Every script parameter is registered, and every registration is a real parameter' {
    It 'scans the scripts of the repository' {
        $script:Expected.Count | Should -BeGreaterThan 300
        @($script:Expected.Keys | Where-Object { $_ -like 'scripts/*' }).Count | Should -BeGreaterThan 300
    }

    It 'has no script whose param() block does not parse' {
        $broken = @($script:Expected.Keys | Where-Object { $script:Expected[$_].Error } | Sort-Object | ForEach-Object { "$_ ($($script:Expected[$_].Error))" })
        $broken | Should -BeNullOrEmpty
    }

    It 'registers every parameter of every script' {
        $missing = foreach ($file in ($script:Expected.Keys | Sort-Object)) {
            $names = if ($script:ByScript.ContainsKey($file)) { @($script:ByScript[$file]) } else { @() }
            foreach ($p in $script:Expected[$file].Names) { if ($names -cnotcontains $p) { "$file -$p" } }
        }
        @($missing) | Should -BeNullOrEmpty -Because 'run ./config/variables/scripts/New-ScriptParameterRegistry.ps1'
    }

    It 'registers no parameter a script does not have' {
        $extra = foreach ($entry in $script:Registered) {
            $file = Resolve-AreaScript $entry.Area
            if ($file -and $script:Expected[$file].Names -cnotcontains $entry.Name) { "$($entry.Group): $($entry.Name) is not a parameter of $file" }
        }
        @($extra) | Should -BeNullOrEmpty
    }

    It 'registers no parameter twice for one script' {
        $twice = foreach ($file in ($script:Expected.Keys | Sort-Object)) {
            $names = if ($script:ByScript.ContainsKey($file)) { @($script:ByScript[$file]) } else { @() }
            foreach ($g in ($names | Group-Object -CaseSensitive | Where-Object Count -GT 1)) { "$file -$($g.Name) ($($g.Count) times)" }
        }
        @($twice) | Should -BeNullOrEmpty
    }

    It 'has a generated group only for a script that exists' {
        $orphan = foreach ($g in ($script:Registered | Where-Object Generated | Select-Object Group, Area -Unique)) { if (-not $script:Expected.ContainsKey($g.Area)) { "$($g.Group): $($g.Area) is not a script" } }
        @($orphan) | Should -BeNullOrEmpty
    }

    It 'gives every generated entry the fields of a registered parameter' {
        $bad = foreach ($r in $script:Registry) {
            if ($r.Path -match '^tools\.arm_deployment\.parameters\.[^.]+_generated\.[^.]+$') {
                foreach ($field in 'name', 'type', 'declared_type', 'required', 'read_at', 'description') { if (-not $r.Node.Contains($field)) { "$($r.Path) lacks $field" } }
                if ($r.Node['required'] -cnotin 'Y', 'N') { "$($r.Path): required is $($r.Node['required'])" }
                if (-not $r.Node['description']) { "$($r.Path): empty description" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'The generator' {
    BeforeAll {
        $script:Mini = Join-Path $TestDrive 'mini'
        New-MiniRepo -Path $script:Mini
        $script:MiniRegistry = Join-Path $script:Mini 'schema/master-registry.yaml'
        $script:Result = @(& $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini -PassThru 6>$null)
        $script:MiniText = Get-Content -LiteralPath $script:MiniRegistry -Raw
        $script:MiniRecord = @(Get-RegistryVariable -Path $script:MiniRegistry)
    }

    It 'writes the registration between the markers, and the registry still reads' {
        $script:MiniText | Should -Match '(?m)^            # BEGIN script-parameters '
        $script:MiniText | Should -Match '(?m)^            # END script-parameters\r?$'
        @($script:MiniRecord | Where-Object { $_.Path -like 'tools.arm_deployment.parameters.scripts_area_New_Thing_ps1_generated.*' -and $_.Node.Contains('name') }).Count | Should -Be 6
    }

    It 'leaves the hand-written group alone and adds only the parameter it lacks' {
        @($script:Result | Where-Object { $_.Script -eq 'scripts/area/Hand.ps1' } | ForEach-Object { "$($_.Parameter)=$($_.Registration)" }) | Should -Be @('Known=hand-written', 'Extra=generated')
        $script:MiniText | Should -Match 'Known: \{"name":"Known","type":"string","declared_type":"string","required":"N","read_at":"scripts/area/Hand.ps1","description":"Hand.ps1. Written by hand."\}'
        ([regex]::Matches($script:MiniText, '"name":"Known"')).Count | Should -Be 1
        ([regex]::Matches($script:MiniText, '"name":"Extra"')).Count | Should -Be 1
    }

    It 'reads type, default, ValidateSet, Mandatory and the help text of the parameters' {
        $entry = { param($name) ($script:MiniRecord | Where-Object { $_.Path -eq "tools.arm_deployment.parameters.scripts_area_New_Thing_ps1_generated.$name" }).Node }
        $file = & $entry 'InfrastructureFile'
        $file['required'] | Should -Be 'Y'
        $file['description'] | Should -Be 'New-Thing.ps1. The master file. Second line of the help.'
        $mode = & $entry 'Mode'
        $mode['enum'] | Should -Be @('Plan', 'Apply')
        $mode['default'] | Should -Be 'Plan'
        $mode['required'] | Should -Be 'N'
        $count = & $entry 'Count'
        $count['type'] | Should -Be 'integer'
        $count['default'] | Should -Be '3'
        (& $entry 'Force')['type'] | Should -Be 'boolean'
        (& $entry 'Force')['declared_type'] | Should -Be 'switch'
        (& $entry 'Names')['type'] | Should -Be 'array'
        (& $entry 'Yes')['type'] | Should -Be 'object'
        (& $entry 'Yes')['declared_type'] | Should -Be ''
    }

    It 'builds a neutral description from the name when the script has no help for the parameter' {
        $node = ($script:MiniRecord | Where-Object { $_.Path -eq 'tools.arm_deployment.parameters.scripts_area_New_Thing_ps1_generated.Count' }).Node
        $node['description'] | Should -Be 'New-Thing.ps1. Count (no help text for this parameter).'
    }

    It 'does not register the common parameters that CmdletBinding adds' {
        @($script:MiniRecord | Where-Object { $_.Path -match '\.(WhatIf|Confirm|Verbose)$' }) | Should -BeNullOrEmpty
    }

    It 'registers a placeholder script and marks it' {
        $node = ($script:MiniRecord | Where-Object { $_.Path -eq 'tools.arm_deployment.parameters.scripts_area_Invoke_Later_ps1_generated.ConfigPath' }).Node
        $node['description'] | Should -Match 'Placeholder script: it ends with exit code 3 \(NOT IMPLEMENTED\)'
        $script:MiniText | Should -Match 'description: "Placeholder script: it ends with exit code 3 \(NOT IMPLEMENTED\)'
    }

    It 'writes nothing for a script without parameters' {
        $script:MiniText | Should -Not -Match 'NoParameters'
    }

    It 'is idempotent, and -Check passes after a write' {
        $before = Get-Content -LiteralPath $script:MiniRegistry -Raw
        $null = & $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini 6>$null
        (Get-Content -LiteralPath $script:MiniRegistry -Raw) | Should -BeExactly $before
        $global:LASTEXITCODE = 0
        & $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini -Check *>$null
        $LASTEXITCODE | Should -Be 0
    }

    It '-Check fails and writes nothing when a script gained a parameter' {
        Set-Content -LiteralPath (Join-Path $script:Mini 'scripts/area/Invoke-Later.ps1') -Encoding utf8NoBOM -Value "# PLACEHOLDER: this script does not do the task.`nparam([string]`$ConfigPath = '', [switch]`$Another)`nexit 3"
        $before = Get-Content -LiteralPath $script:MiniRegistry -Raw
        $global:LASTEXITCODE = 0
        & $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini -Check *>$null 2>$null
        $LASTEXITCODE | Should -Be 1
        (Get-Content -LiteralPath $script:MiniRegistry -Raw) | Should -BeExactly $before
    }

    It 'drops the generated entry when a hand-written group registers the parameter, and removes a parameter the script lost' {
        $null = & $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini 6>$null
        $text = (Get-Content -LiteralPath $script:MiniRegistry -Raw)
        $text | Should -Match '"name":"Another"'
        Set-Content -LiteralPath (Join-Path $script:Mini 'scripts/area/Invoke-Later.ps1') -Encoding utf8NoBOM -Value "# PLACEHOLDER: this script does not do the task.`nparam([string]`$ConfigPath = '')`nexit 3"
        $null = & $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini 6>$null
        (Get-Content -LiteralPath $script:MiniRegistry -Raw) | Should -Not -Match '"name":"Another"'
    }

    It 'refuses to write when a param() block does not parse' {
        Set-Content -LiteralPath (Join-Path $script:Mini 'scripts/area/Broken.ps1') -Encoding utf8NoBOM -Value 'param([string]$A, [string]$)'
        $before = Get-Content -LiteralPath $script:MiniRegistry -Raw
        $global:LASTEXITCODE = 0
        & $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini *>$null 2>$null
        $LASTEXITCODE | Should -Be 1
        (Get-Content -LiteralPath $script:MiniRegistry -Raw) | Should -BeExactly $before
        Remove-Item -LiteralPath (Join-Path $script:Mini 'scripts/area/Broken.ps1')
    }

    It 'warns about a default that looks like an environment value' {
        Set-Content -LiteralPath (Join-Path $script:Mini 'scripts/area/Env.ps1') -Encoding utf8NoBOM -Value "param([string]`$Address = '10.20.30.40', [string]`$Documentation = '192.0.2.10')"
        $warnings = @(& $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini -Check 3>&1 2>$null 6>$null | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        @($warnings | Where-Object { $_ -match '-Address defaults to' }).Count | Should -Be 1
        @($warnings | Where-Object { $_ -match '-Documentation' }).Count | Should -Be 0
    }

    It 'does not copy an environment default or an address in help text into the registry' {
        Set-Content -LiteralPath (Join-Path $script:Mini 'scripts/area/Env.ps1') -Encoding utf8NoBOM -Value @'
<#
.PARAMETER Address
    The address. Default 10.20.30.40, documentation 192.0.2.10.
#>
[CmdletBinding()]
param([string]$Address = '10.20.30.40')
'@
        $null = & $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini 3>$null 6>$null
        $node = (Get-RegistryVariable -Path $script:MiniRegistry | Where-Object { $_.Path -eq 'tools.arm_deployment.parameters.scripts_area_Env_ps1_generated.Address' }).Node
        $node.Contains('default') | Should -BeFalse
        $node['description'] | Should -Not -Match '10\.20\.30\.40'
        $node['description'] | Should -Match '192\.0\.2\.10'
        $node['description'] | Should -Match 'looks like an environment value \(IPv4 address\)'
    }

    It 'writes a default that spans lines on one line' {
        Set-Content -LiteralPath (Join-Path $script:Mini 'scripts/area/Multi.ps1') -Encoding utf8NoBOM -Value "param([string[]]`$List = @(`r`n    'a',`r`n    'b'`r`n))"
        $null = & $script:Generator -RegistryPath $script:MiniRegistry -Root $script:Mini 3>$null 6>$null
        $node = (Get-RegistryVariable -Path $script:MiniRegistry | Where-Object { $_.Path -eq 'tools.arm_deployment.parameters.scripts_area_Multi_ps1_generated.List' }).Node
        $node['default'] | Should -Be "@( 'a', 'b' )"
    }
}
