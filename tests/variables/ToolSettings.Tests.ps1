#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The settings of the external tools (a configuration file key, a command parameter, an environment variable, a URL parameter) are
# registered under tools.<tool> in the master registry. These tests compare what is registered with the source of each tool:
#   - a setting in the tool that is not registered fails, and a registered one that the tool no longer has fails;
#   - a source_key must name a key of the master infrastructure file.
# The comparison with a tool needs its repository. When the repository is not on the machine the test is skipped with a message
# (CI has only the toolkit). Folders: D:\git\azurelocal\azurelocal-<tool> (azurelocal-trailwright: D:\git\hybrid-solutions-cloud\azurelocal-trailwright), or the environment variable AZL_<TOOL>_REPO.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeAll {
    $script:Repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:Vars = Join-Path $script:Repo 'config\variables'
    Import-Module (Join-Path $script:Vars 'scripts\VariableRegistry.psm1') -Force
    $script:RegistryPath = Join-Path $script:Vars 'schema\master-registry.yaml'
    $script:All = @(Get-RegistryVariable -Path $script:RegistryPath)

    function Get-ToolRepo([string]$Tool) {
        $envName = 'AZL_{0}_REPO' -f $Tool.ToUpperInvariant()
        $fromEnv = [Environment]::GetEnvironmentVariable($envName)
        # azurelocal-trailwright lives in D:\git\hybrid-solutions-cloud, the other tools in D:\git\azurelocal.
        $path = if ($fromEnv) { $fromEnv } else { @('D:\git\azurelocal', 'D:\git\hybrid-solutions-cloud' | ForEach-Object { Join-Path $_ "azurelocal-$Tool" } | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1) }
        if ($path -and (Test-Path -LiteralPath $path -PathType Container)) { (Resolve-Path -LiteralPath $path).ProviderPath } else { $null }
    }

    # The registered leaves of a tool: one object per leaf with Kind, Area (the group's area), Name and the node.
    function Get-ToolLeaf([string]$Tool) {
        $groups = @{}
        foreach ($r in $script:All) { if ($r.Path -match "^tools\.$Tool\.([^.]+)\.([^.]+)$") { $groups[$r.Path] = $r } }
        foreach ($r in $script:All) {
            if ($r.Path -match "^tools\.$Tool\.([^.]+)\.([^.]+)\.([^.]+)$" -and $r.Node.Contains('name')) {
                $g = $groups["tools.$Tool.$($Matches[1]).$($Matches[2])"]
                [pscustomobject]@{ Kind = $Matches[1]; Area = [string]$g.Node['area']; Name = [string]$r.Node['name']; Node = $r.Node; Path = $r.Path }
            }
        }
    }

    function Skip-NoRepo([string]$Tool, $Root) {
        Set-ItResult -Skipped -Because "the repository azurelocal-$Tool is not on this machine (looked in D:\git\azurelocal\azurelocal-$Tool and `$env:AZL_$($Tool.ToUpperInvariant())_REPO); nothing was compared"
    }

    # script-level or function-level parameter names from the PowerShell syntax tree
    function Get-ParamName([string]$File, [string]$Function) {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errs)
        $common = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm', 'ProgressAction'
        $pb = $null
        if ($Function) {
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Function }, $true) | Select-Object -First 1
            if ($fn -and $fn.Body.ParamBlock) { $pb = $fn.Body.ParamBlock }
        }
        else { $pb = $ast.ParamBlock }
        if (-not $pb) { return @() }
        @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } | Where-Object { $_ -notin $common })
    }

    function Get-FlatPath($Obj, [string]$Path) {
        if ($Obj -is [System.Collections.IDictionary] -and $Obj.Count -gt 0) { foreach ($k in $Obj.Keys) { Get-FlatPath $Obj[$k] $(if ($Path) { "$Path.$k" } else { [string]$k }) } }
        else { $Path }
    }

    # the paths of the master infrastructure file (templates/infrastructure.master.yml), with [] for list items
    function Get-MasterPath($Obj, [string]$Path) {
        if ($Obj -is [System.Collections.IDictionary]) { foreach ($k in $Obj.Keys) { $p = if ($Path) { "$Path.$k" } else { [string]$k }; $p; Get-MasterPath $Obj[$k] $p } }
        elseif ($Obj -is [System.Collections.IList]) { foreach ($i in $Obj) { Get-MasterPath $i "$Path[]" } }
    }

    function Compare-Name([string[]]$Source, [string[]]$Registered) {
        [pscustomobject]@{
            NotRegistered = @($Source | Where-Object { $_ -notin $Registered } | Sort-Object -Unique)
            NotInSource   = @($Registered | Where-Object { $_ -notin $Source } | Sort-Object -Unique)
        }
    }
}

Describe 'Registered settings of the external tools' {
    BeforeAll {
        $master = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $script:Vars 'templates\infrastructure.master.yml') -Raw) -Ordered
        $script:MasterPaths = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-MasterPath $master ''))
        $script:ExternalTools = 'ranger', 'loadtools', 'draftsman', 'sonar'
    }

    It 'has settings for <_>' -ForEach 'ranger', 'loadtools', 'draftsman', 'sonar' {
        @(Get-ToolLeaf $_).Count | Should -BeGreaterThan 5
    }

    It 'gives every setting of <_> a type, a place where it is read and a one-line description' -ForEach 'ranger', 'loadtools', 'draftsman', 'sonar', 'trailwright' {
        $bad = foreach ($l in (Get-ToolLeaf $_)) {
            foreach ($f in 'type', 'read_at', 'description') { if (-not $l.Node.Contains($f) -or [string]::IsNullOrWhiteSpace([string]$l.Node[$f])) { "$($l.Path): no $f" } }
            if ($l.Node.Contains('description') -and ([string]$l.Node['description']).Length -gt 900) { "$($l.Path): description is longer than 900 characters" }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'gives every group of <_> an area that names a file of the tool' -ForEach 'ranger', 'loadtools', 'draftsman', 'sonar', 'trailwright' {
        $tool = $_
        $bad = foreach ($r in $script:All) { if ($r.Path -match "^tools\.$tool\.[^.]+\.[^.]+$" -and (-not $r.Node.Contains('area') -or [string]::IsNullOrWhiteSpace([string]$r.Node['area']))) { $r.Path } }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'names, in source_key of <_>, only keys that exist in the master infrastructure file' -ForEach 'ranger', 'loadtools', 'draftsman', 'sonar', 'trailwright' {
        $bad = foreach ($l in (Get-ToolLeaf $_)) {
            if ($l.Node.Contains('source_key') -and -not $script:MasterPaths.Contains([string]$l.Node['source_key'])) { "$($l.Path): source_key $($l.Node['source_key']) is not a key of the master file" }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'lists the surveyor as a tool without settings of its own: it has no tools section' {
        @($script:All | Where-Object { $_.Path -like 'tools.surveyor*' }).Count | Should -Be 0
    }

    It 'a source_key that is not in the master file is found (the check itself works)' {
        $script:MasterPaths.Contains('azure.subscription_id') | Should -BeTrue
        $script:MasterPaths.Contains('nodes[].name') | Should -BeTrue
        $script:MasterPaths.Contains('not.a.key') | Should -BeFalse
    }
}

Describe 'azurelocal-ranger: the registered settings match its source' {
    BeforeAll {
        $script:RgRoot = Get-ToolRepo 'ranger'
        $script:RgLeaf = @(Get-ToolLeaf 'ranger')
    }

    It 'every key of Get-RangerDefaultConfig and of samples/configs/ranger.yml is registered, and every registered key is used by the code' {
        if (-not $script:RgRoot) { return (Skip-NoRepo 'ranger' $null) }
        $configLeaf = @($script:RgLeaf | Where-Object { $_.Kind -eq 'config_keys' -and $_.Area -eq 'Modules/Private/20-Config.ps1' })
        $configLeaf.Count | Should -BeGreaterThan 40
        # the defaults come from the function itself (the file holds functions only)
        $defaults = & { . (Join-Path $script:RgRoot 'Modules\Private\20-Config.ps1'); Get-RangerDefaultConfig }
        $fromCode = @(Get-FlatPath $defaults '')
        $sample = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $script:RgRoot 'samples\configs\ranger.yml') -Raw) -Ordered
        $fromSample = @(Get-FlatPath $sample '')
        $registered = @($configLeaf | ForEach-Object { $_.Name })
        $missing = @(($fromCode + $fromSample) | Where-Object { $_ -notin $registered } | Sort-Object -Unique)
        $missing | Should -BeNullOrEmpty -Because "register them under tools.ranger.config_keys: $($missing -join ', ')"
        # a registered key whose last name no longer appears in the code
        $text = (Get-ChildItem -LiteralPath (Join-Path $script:RgRoot 'Modules') -Recurse -Filter '*.ps1' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $gone = foreach ($n in $registered) {
            $last = ($n -replace '\[\]', '' -split '\.')[-1]
            if ($text -notmatch ('(?<![A-Za-z0-9_])' + [regex]::Escape($last) + '(?![A-Za-z0-9_])')) { $n }
        }
        @($gone) | Should -BeNullOrEmpty -Because 'these registered keys are not in the code any more'
    }

    It 'the tunables of config/waf-rules.json are registered, and the code still reads them' {
        if (-not $script:RgRoot) { return (Skip-NoRepo 'ranger' $null) }
        $waf = @($script:RgLeaf | Where-Object { $_.Area -eq 'config/waf-rules.json' } | ForEach-Object { $_.Name })
        $waf.Count | Should -BeGreaterThan 10
        $rules = Get-Content -LiteralPath (Join-Path $script:RgRoot 'config\waf-rules.json') -Raw | ConvertFrom-Json -AsHashtable
        $inFile = foreach ($section in 'scoreThresholds', 'prioritization') { Get-FlatPath $rules[$section] $section }
        $missing = @($inFile | Where-Object { $_ -notin $waf -and $_ -notlike '*.description' })
        $missing | Should -BeNullOrEmpty -Because "register them under tools.ranger.config_keys (config/waf-rules.json): $($missing -join ', ')"
        $collector = Get-Content -LiteralPath (Join-Path $script:RgRoot 'Modules\Collectors\70-WafAssessmentCollector.ps1') -Raw
        $gone = foreach ($n in $waf) { $last = ($n -split '\.')[-1]; if ($collector -notmatch [regex]::Escape($last)) { $n } }
        @($gone) | Should -BeNullOrEmpty
    }

    It 'every parameter of every exported command is registered, and every registered parameter exists' {
        if (-not $script:RgRoot) { return (Skip-NoRepo 'ranger' $null) }
        $psd1 = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RgRoot 'AzureLocalRanger.psd1')
        $files = @('Modules\Public\10-Commands.ps1', 'Modules\Public\20-EstateCommands.ps1', 'Modules\Core\50-DesignCompare.ps1') | ForEach-Object { Join-Path $script:RgRoot $_ }
        $problems = foreach ($fn in $psd1.FunctionsToExport) {
            $file = $files | Where-Object { (Get-Content -LiteralPath $_ -Raw) -match "(?m)^function $([regex]::Escape($fn))\b" } | Select-Object -First 1
            if (-not $file) { "${fn}: the function is not in Modules/Public or Modules/Core/50-DesignCompare.ps1"; continue }
            $inCode = @(Get-ParamName $file $fn)
            $registered = @($script:RgLeaf | Where-Object { $_.Kind -eq 'parameters' -and $_.Area -like "*($fn)" } | ForEach-Object { $_.Name })
            if (-not $registered.Count -and $inCode.Count) { "${fn}: no tools.ranger.parameters group has the area '... ($fn)'"; continue }
            $c = Compare-Name $inCode $registered
            foreach ($n in $c.NotRegistered) { "${fn}: -$n is not registered" }
            foreach ($n in $c.NotInSource) { "${fn}: -$n is registered but the command has no such parameter" }
        }
        @($problems) | Should -BeNullOrEmpty
    }

    It 'every parameter of samples/configs/ranger.from-environment.ps1 is registered' {
        if (-not $script:RgRoot) { return (Skip-NoRepo 'ranger' $null) }
        $inCode = @(Get-ParamName (Join-Path $script:RgRoot 'samples\configs\ranger.from-environment.ps1') $null)
        $registered = @($script:RgLeaf | Where-Object { $_.Kind -eq 'parameters' -and $_.Area -eq 'samples/configs/ranger.from-environment.ps1' } | ForEach-Object { $_.Name })
        $c = Compare-Name $inCode $registered
        $c.NotRegistered | Should -BeNullOrEmpty
        $c.NotInSource | Should -BeNullOrEmpty
    }
}

Describe 'azurelocal-loadtools: the registered settings match its source' {
    BeforeAll {
        $script:LtRoot = Get-ToolRepo 'loadtools'
        $script:LtLeaf = @(Get-ToolLeaf 'loadtools')
        function Get-LtName([string]$Area) { @($script:LtLeaf | Where-Object { $_.Area -eq $Area } | ForEach-Object { $_.Name }) }
    }

    It 'the variables of config/variables/variables.yml are the registered variables' {
        if (-not $script:LtRoot) { return (Skip-NoRepo 'loadtools' $null) }
        $y = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $script:LtRoot 'config\variables\variables.yml') -Raw)
        $c = Compare-Name @($y.variables | ForEach-Object { [string]$_.name }) (Get-LtName 'config/variables/variables.yml')
        $c.NotRegistered | Should -BeNullOrEmpty -Because 'register them under tools.loadtools.config_keys'
        $c.NotInSource | Should -BeNullOrEmpty -Because 'the variable is not in variables.yml any more'
    }

    It 'every solution JSON key that a script reads is registered' {
        if (-not $script:LtRoot) { return (Skip-NoRepo 'loadtools' $null) }
        $registered = @((Get-LtName 'config/variables/variables.yml') + (Get-LtName 'tools/vmfleet/config/vmfleet.json'))
        $read = foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $script:LtRoot 'tools') -Recurse -Filter '*.ps1' | Where-Object { $_.Name -notmatch 'Tests\.ps1$' })) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw), '\$(?:solutionConfig|config)\.([A-Za-z_][A-Za-z_0-9]*)')) { $m.Groups[1].Value }
        }
        $methods = 'ContainsKey', 'Keys', 'Count', 'azure', 'azure_local', 'nodes', 'variables', 'metadata'
        $missing = @($read | Where-Object { $_ -notin $registered -and $_ -notin $methods } | Sort-Object -Unique)
        $missing | Should -BeNullOrEmpty -Because "register them under tools.loadtools.config_keys: $($missing -join ', ')"
        $gone = @((Get-LtName 'tools/vmfleet/config/vmfleet.json') | Where-Object { $_ -notin $read })
        $gone | Should -BeNullOrEmpty -Because 'no script reads these any more'
    }

    It 'the keys of the profiles of each tool are the registered keys' {
        if (-not $script:LtRoot) { return (Skip-NoRepo 'loadtools' $null) }
        $problems = foreach ($tool in 'fio', 'iperf', 'hammerdb', 'stress-ng', 'vmfleet') {
            $paths = foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $script:LtRoot "tools\$tool\config\profiles") -Filter '*.yml')) {
                Get-FlatPath (ConvertFrom-Yaml (Get-Content -LiteralPath $f.FullName -Raw) -Ordered) ''
            }
            $c = Compare-Name @($paths | Sort-Object -Unique) (Get-LtName "tools/$tool/config/profiles/*.yml")
            foreach ($n in $c.NotRegistered) { "${tool}: profile key $n is not registered" }
            foreach ($n in $c.NotInSource) { "${tool}: registered profile key $n is in no profile" }
        }
        @($problems) | Should -BeNullOrEmpty
    }

    It 'the rules of each alert rule file are the registered test thresholds' {
        if (-not $script:LtRoot) { return (Skip-NoRepo 'loadtools' $null) }
        $problems = foreach ($tool in 'fio', 'iperf', 'hammerdb', 'stress-ng', 'vmfleet') {
            $y = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $script:LtRoot "tools\$tool\monitoring\alerts\alert-rules.yml") -Raw)
            $area = "tools/$tool/monitoring/alerts/alert-rules.yml"
            $inFile = @($y.alert_rules | ForEach-Object { 'rule: {0} threshold' -f $_.name })
            $registered = @(Get-LtName $area | Where-Object { $_.StartsWith('rule: ') })
            $c = Compare-Name $inFile $registered
            foreach ($n in $c.NotRegistered) { "${tool}: $n is not registered" }
            foreach ($n in $c.NotInSource) { "${tool}: $n is registered but the rule file has no such rule" }
            # the keys of one rule are the registered rule fields
            $fields = @($y.alert_rules | ForEach-Object { $_.Keys } | Sort-Object -Unique)
            $regFields = @(Get-LtName $area | Where-Object { $_.StartsWith('alert_rules[].') } | ForEach-Object { $_ -replace '^alert_rules\[\]\.', '' })
            $cf = Compare-Name $fields $regFields
            foreach ($n in $cf.NotRegistered) { "${tool}: rule field $n is not registered" }
            foreach ($n in $cf.NotInSource) { "${tool}: registered rule field $n is in no rule" }
        }
        @($problems) | Should -BeNullOrEmpty
    }

    It 'every parameter of every script under tools/ and of Initialize-Environment.ps1 is registered, and every registered parameter exists' {
        if (-not $script:LtRoot) { return (Skip-NoRepo 'loadtools' $null) }
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:LtRoot 'tools') -Recurse -Filter '*.ps1' | Where-Object { $_.Name -notmatch 'Tests\.ps1$' } | ForEach-Object { $_.FullName })
        $files += Join-Path $script:LtRoot 'common\helpers\Initialize-Environment.ps1'
        $seenAreas = @()
        $problems = foreach ($file in $files) {
            $rel = $file.Substring($script:LtRoot.Length + 1).Replace('\', '/')
            $inCode = @(Get-ParamName $file $null)
            if (-not $inCode.Count) { continue }
            $seenAreas += $rel
            $registered = @(Get-LtName $rel)
            if (-not $registered.Count) { "${rel}: no tools.loadtools.parameters group has this area"; continue }
            $c = Compare-Name $inCode $registered
            foreach ($n in $c.NotRegistered) { "${rel}: -$n is not registered" }
            foreach ($n in $c.NotInSource) { "${rel}: -$n is registered but the script has no such parameter" }
        }
        $stale = foreach ($l in ($script:LtLeaf | Where-Object { $_.Kind -eq 'parameters' -and $_.Area -like 'tools/*.ps1' -or $_.Area -like 'common/helpers/*.ps1' } | Select-Object -ExpandProperty Area -Unique)) { if ($l -notin $seenAreas) { "${l}: registered, but the script has no parameters or does not exist" } }
        @($problems + $stale) | Should -BeNullOrEmpty
    }

    It 'every key of the per-cluster file that a script reads is registered' {
        if (-not $script:LtRoot) { return (Skip-NoRepo 'loadtools' $null) }
        $registered = @(Get-LtName 'config/clusters/cluster.yml')
        $read = foreach ($f in (Get-ChildItem -LiteralPath $script:LtRoot -Recurse -Include '*.ps1', '*.psm1' | Where-Object { $_.FullName -notmatch '\\(tests|archive)\\|Tests\.ps1$' })) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw), '\$(?:clusterConfig|cc)\.((?:cluster|storage)\.[a-z_]+|nodes)\b')) { $m.Groups[1].Value }
        }
        $names = @($registered | ForEach-Object { $_ -replace '\[\]\.name$', '' -replace '\[\]$', '' })
        $missing = @($read | Where-Object { $_ -notin $names -and $_ -ne 'cluster.nodes' } | Sort-Object -Unique)
        $missing | Should -BeNullOrEmpty -Because "register them under tools.loadtools.config_keys (config/clusters/cluster.yml): $($missing -join ', ')"
    }

    It 'the keys of config/variables/variables.example.yml are registered' {
        if (-not $script:LtRoot) { return (Skip-NoRepo 'loadtools' $null) }
        $y = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $script:LtRoot 'config\variables\variables.example.yml') -Raw) -Ordered
        # the nodes are a list of maps: azure_local.nodes[].name and so on
        $flat = [System.Collections.Generic.List[string]]::new()
        foreach ($p in (Get-FlatPath $y '')) { if ($p -ne 'azure_local.nodes') { $flat.Add($p) } }
        foreach ($k in $y.azure_local.nodes[0].Keys) { $flat.Add("azure_local.nodes[].$k") }        $registered = @(Get-LtName 'config/variables/variables.example.yml')
        $c = Compare-Name @($flat | Sort-Object -Unique) $registered
        $c.NotRegistered | Should -BeNullOrEmpty
        $c.NotInSource | Should -BeNullOrEmpty
    }
}

Describe 'azurelocal-sonar: the registered settings match its source' {
    BeforeAll {
        $script:SnRoot = Get-ToolRepo 'sonar'
        $script:SnLeaf = @(Get-ToolLeaf 'sonar')
    }

    It 'every configuration key that Config.ps1 reads is registered' {
        if (-not $script:SnRoot) { return (Skip-NoRepo 'sonar' $null) }
        $src = Get-Content -LiteralPath (Join-Path $script:SnRoot 'src\AzlSonar\Private\Config.ps1') -Raw
        $read = @([regex]::Matches($src, "Get-AzlSonarMember\s+\`$\w+\s+'([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $read.Count | Should -BeGreaterThan 20
        # a registered name is the full path (credential.vault, logs.paths); its last segment is the key the code reads
        $last = @($script:SnLeaf | Where-Object { $_.Kind -eq 'config_keys' } | ForEach-Object { ($_.Name -replace '\[\]', '' -split '[.\s]')[-1] })
        $parents = @($script:SnLeaf | Where-Object { $_.Kind -eq 'config_keys' } | ForEach-Object { ($_.Name -replace '\[\]', '' -split '\.')[0] })
        $missing = @($read | Where-Object { $_ -notin $last -and $_ -notin $parents })
        $missing | Should -BeNullOrEmpty -Because "register them under tools.sonar.config_keys: $($missing -join ', ')"
    }

    It 'every parameter of every script of the repository that has parameters is registered' {
        if (-not $script:SnRoot) { return (Skip-NoRepo 'sonar' $null) }
        $problems = @(& (Join-Path $script:Vars 'scripts\Test-ToolParameterRegistration.ps1') -Tool sonar -Root $script:SnRoot -Registry $script:All)
        @($problems | ForEach-Object { "$(Split-Path -Leaf $_.Script) -$($_.Parameter)" }) | Should -BeNullOrEmpty
    }
}

Describe 'azurelocal-trailwright: the registered settings match its source' {
    # Trailwright is a web app. Its only PowerShell is the example script docs/examples/ConvertTo-AsBuiltSnapshot.ps1 (Ranger manifest to as-built snapshot).
    # Its parameters are registered under tools.trailwright.parameters, like the parameters of the scripts of the other external tools.
    BeforeAll {
        $script:TwRoot = Get-ToolRepo 'trailwright'
        $script:TwLeaf = @(Get-ToolLeaf 'trailwright')
    }

    It 'registers the parameters of the example script, with the file as its area' {
        $params = @($script:TwLeaf | Where-Object { $_.Kind -eq 'parameters' -and $_.Area -eq 'docs/examples/ConvertTo-AsBuiltSnapshot.ps1' })
        @($params | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('ManifestPath', 'OutPath', 'Release')
        @($script:TwLeaf | Where-Object { $_.Kind -ne 'parameters' }).Count | Should -Be 0 -Because 'Trailwright has no other registered kind of setting; add a test for it when one is registered'
    }

    It 'marks the mandatory parameters and ties Release to deployment.solution_version' {
        $byName = @{}; foreach ($l in $script:TwLeaf) { $byName[$l.Name] = $l }
        $byName['ManifestPath'].Node['required'] | Should -Be 'Y'
        $byName['OutPath'].Node['required'] | Should -Be 'Y'
        $byName['Release'].Node['required'] | Should -Be 'N'
        $byName['Release'].Node['source_key'] | Should -Be 'deployment.solution_version'
    }

    It 'the tool catalog names the tools section and the script' {
        $catalog = (Read-RegistryYaml -Path $script:RegistryPath)['_tool_catalog']['tools']['trailwright']
        $catalog['tools_section'] | Should -Be 'trailwright'
        @($catalog['evidence']) | Should -Contain 'docs/examples/ConvertTo-AsBuiltSnapshot.ps1'
    }

    It 'every parameter of every PowerShell script of the repository is registered, and every registered parameter exists' {
        if (-not $script:TwRoot) { return (Skip-NoRepo 'trailwright' $null) }
        $files = @(Get-ChildItem -LiteralPath $script:TwRoot -Recurse -Include '*.ps1', '*.psm1' -File | Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' })
        $files.Count | Should -BeGreaterThan 0
        $seen = @()
        $problems = foreach ($file in $files) {
            $rel = $file.FullName.Substring($script:TwRoot.Length + 1).Replace('\', '/')
            $inCode = @(Get-ParamName $file.FullName $null)
            if (-not $inCode.Count) { continue }
            $seen += $rel
            $registered = @($script:TwLeaf | Where-Object { $_.Kind -eq 'parameters' -and $_.Area -eq $rel } | ForEach-Object { $_.Name })
            if (-not $registered.Count) { "${rel}: no tools.trailwright.parameters group has this area"; continue }
            $c = Compare-Name $inCode $registered
            foreach ($n in $c.NotRegistered) { "${rel}: -$n is not registered" }
            foreach ($n in $c.NotInSource) { "${rel}: -$n is registered but the script has no such parameter" }
        }
        $stale = foreach ($a in @($script:TwLeaf | Where-Object { $_.Kind -eq 'parameters' } | Select-Object -ExpandProperty Area -Unique)) { if ($a -notin $seen) { "${a}: registered, but the repository has no such script with parameters" } }
        @($problems + $stale) | Should -BeNullOrEmpty
    }

    It 'Test-ToolParameterRegistration.ps1 finds no unregistered parameter in the checkout' {
        if (-not $script:TwRoot) { return (Skip-NoRepo 'trailwright' $null) }
        $found = @(& (Join-Path $script:Vars 'scripts\Test-ToolParameterRegistration.ps1') -Tool trailwright -Root $script:TwRoot -Registry $script:All -ReportUnregisteredScripts)
        @($found | ForEach-Object { "$(Split-Path -Leaf $_.Script) -$($_.Parameter)" }) | Should -BeNullOrEmpty
    }
}

Describe 'azurelocal-draftsman and azurelocal-surveyor: the settings outside the page' {
    It 'every URL parameter of draftsman is registered, and VITE_BASE is still read' {
        $root = Get-ToolRepo 'draftsman'
        if (-not $root) { return (Skip-NoRepo 'draftsman' $null) }
        $leaf = @(Get-ToolLeaf 'draftsman')
        $inCode = @(Select-String -Path (Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -Include '*.ts', '*.tsx' | ForEach-Object { $_.FullName }) -Pattern "(?:params|searchParams|URLSearchParams\([^)]*\))\.get\('([A-Za-z]+)'\)" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $inCode.Count | Should -BeGreaterThan 3
        $c = Compare-Name $inCode @($leaf | Where-Object { $_.Kind -eq 'url_parameters' } | ForEach-Object { $_.Name })
        $c.NotRegistered | Should -BeNullOrEmpty
        $c.NotInSource | Should -BeNullOrEmpty
        $env = @(Select-String -Path (Join-Path $root 'vite.config.ts') -Pattern 'process\.env\.([A-Z_]+)' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $c2 = Compare-Name $env @($leaf | Where-Object { $_.Kind -eq 'env_vars' } | ForEach-Object { $_.Name })
        $c2.NotRegistered | Should -BeNullOrEmpty
        $c2.NotInSource | Should -BeNullOrEmpty
    }

    It 'surveyor still has no setting outside its page (no URL parameter, no environment variable except the browser test one)' {
        $root = Get-ToolRepo 'surveyor'
        if (-not $root) { return (Skip-NoRepo 'surveyor' $null) }
        $sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -Include '*.ts', '*.tsx' | ForEach-Object { $_.FullName })
        $urlParams = @(Select-String -Path $sources -Pattern 'URLSearchParams|useSearchParams|location\.search' | ForEach-Object { "$($_.Path):$($_.LineNumber)" })
        $urlParams | Should -BeNullOrEmpty -Because 'a new URL parameter of surveyor must be registered under tools.surveyor'
        $envs = @(Select-String -Path $sources -Pattern 'import\.meta\.env\.([A-Z_]+)|process\.env\.([A-Z_]+)' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Where-Object { $_ -ne 'import.meta.env.BASE_URL' } | Sort-Object -Unique)
        $envs | Should -BeNullOrEmpty -Because 'a new environment variable of surveyor must be registered under tools.surveyor'
        $cfg = @(Select-String -Path (Join-Path $root 'vite.config.ts'), (Join-Path $root 'playwright.config.ts') -Pattern 'process\.env\.([A-Z_]+)' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $cfg | Should -Be @('PLAYWRIGHT_BASE_URL')
    }
}
