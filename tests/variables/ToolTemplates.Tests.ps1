#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# One master file and one template per tool. The registry is the only master: the template of a tool is generated from the used_by of
# the keys. These tests fail on drift: a generated file that differs from what the generator writes now, a template that holds a key its
# tool does not read (or misses one it reads), and a used_by value that is not a tool of the registry's list (_tool_catalog).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'config\variables\scripts\InfrastructureArtifacts.psm1') -Force
    $registry = Get-RegistryDocument -Path (Join-Path $repo 'config\variables\schema\master-registry.yaml')
    $script:AllTools = @((Get-ToolCatalog -Registry $registry).Keys)
    $script:ToolsWithKeys = @(Get-ToolWithKey -Registry $registry)
    $script:ToolsWithoutKeys = @($script:AllTools | Where-Object { $_ -notin $script:ToolsWithKeys })
}

BeforeAll {
    $script:Repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:Vars = Join-Path $script:Repo 'config\variables'
    Import-Module (Join-Path $script:Vars 'scripts\InfrastructureArtifacts.psm1') -Force
    Import-Module (Join-Path $script:Vars 'scripts\VariableRegistry.psm1') -Force
    $script:RegistryPath = Join-Path $script:Vars 'schema\master-registry.yaml'
    $script:Registry = Get-RegistryDocument -Path $script:RegistryPath
    $script:Catalog = Get-ToolCatalog -Registry $script:Registry
    # the keys of infrastructure.yml: every registry variable that is not a tool-owned one
    $script:Variables = @(Get-RegistryVariable -Path $script:RegistryPath -Registry $script:Registry | Where-Object { $_.Path -notlike 'tools.*' })

    function Get-DataPath($Obj, [string]$Path) {
        if ($Obj -is [System.Collections.IDictionary]) {
            foreach ($k in $Obj.Keys) {
                $p = if ($Path) { "$Path.$k" } else { [string]$k }
                $p
                Get-DataPath $Obj[$k] $p
            }
        } elseif ($Obj -is [System.Collections.IList]) {
            foreach ($i in $Obj) { Get-DataPath $i "$Path[]" }
        }
    }

    # The keys of a template that are neither a key the tool is given, nor a section above one, nor the file's own _metadata.
    function Get-ExtraKey([string[]]$Template, [string[]]$Tagged) {
        $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($p in $Tagged) {
            [void]$allowed.Add($p)
            $up = $p
            while ($up -match '^(?<parent>.+)(\[\]|\.[^.\[\]]+)$') { $up = $Matches['parent']; [void]$allowed.Add($up); [void]$allowed.Add($up + '[]') }
        }
        $Template | Where-Object { $_ -ne '_metadata' -and $_ -notlike '_metadata.*' -and -not $allowed.Contains($_) }
    }
}

Describe 'Generated files are current' {
    It 'New-InfrastructureArtifacts.ps1 -Check finds no generated file that differs from what the generator writes now' {
        $out = & pwsh -NoProfile -File (Join-Path $script:Vars 'scripts\New-InfrastructureArtifacts.ps1') -Check 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }

    It 'the folders of the tool files are templates/tools and schema/tools, and the old purposes folders are gone' {
        Test-Path (Join-Path $script:Vars 'templates\tools') | Should -BeTrue
        Test-Path (Join-Path $script:Vars 'schema\tools') | Should -BeTrue
        Test-Path (Join-Path $script:Vars 'templates\purposes') | Should -BeFalse
        Test-Path (Join-Path $script:Vars 'schema\purposes') | Should -BeFalse
    }

    It 'every file in templates/tools and schema/tools belongs to a tool that has keys' {
        $expected = @($script:ToolsWithKeys | ForEach-Object { $_ -replace '_', '-' })
        $yml = @(Get-ChildItem (Join-Path $script:Vars 'templates\tools') -File | ForEach-Object { $_.BaseName })
        $json = @(Get-ChildItem (Join-Path $script:Vars 'schema\tools') -File | ForEach-Object { $_.Name -replace '\.schema\.json$', '' })
        @($yml | Sort-Object) | Should -Be @($expected | Sort-Object)
        @($json | Sort-Object) | Should -Be @($expected | Sort-Object)
    }
}

Describe 'The list of tools' {
    It 'every used_by value of every key of infrastructure.yml is a tool of _tool_catalog' {
        $unknown = foreach ($v in $script:Variables) {
            foreach ($t in @($v.UsedBy -split '\|' | Where-Object { $_ })) { if ($t -notin $script:AllTools) { "$($v.Path): $t" } }
        }
        @($unknown) | Should -BeNullOrEmpty
    }

    It 'a used_by value that is not a tool is found (the check itself works)' {
        $fake = [pscustomobject]@{ Path = 'site.name'; UsedBy = 'ztp|not_a_tool' }
        $unknown = foreach ($t in @($fake.UsedBy -split '\|')) { if ($t -notin $script:AllTools) { $t } }
        @($unknown) | Should -Be @('not_a_tool')
    }

    It '<_> has a title, a kind, a relation and a note or evidence' -ForEach $script:AllTools {
        $e = $script:Catalog[$_]
        $e['title'] | Should -Not -BeNullOrEmpty
        $e['kind'] | Should -BeIn 'toolkit', 'external'
        $e['relation'] | Should -BeIn 'reads', 'writes'
        if ($e['kind'] -eq 'external') {
            $e['repository'] | Should -Not -BeNullOrEmpty
            @($e['evidence']).Count | Should -BeGreaterThan 0
        } else {
            @($e['scripts']).Count | Should -BeGreaterThan 0
        }
    }

    It '<_> reads no key of infrastructure.yml: it has no template and no schema, and its entry says why' -ForEach $script:ToolsWithoutKeys {
        $name = $_ -replace '_', '-'
        Test-Path (Join-Path $script:Vars "templates\tools\$name.yml") | Should -BeFalse
        Test-Path (Join-Path $script:Vars "schema\tools\$name.schema.json") | Should -BeFalse
        [string]$script:Catalog[$_]['note'] | Should -Match 'no key'
    }

    It 'the tools_section of a tool is a section under tools: of the registry' {
        $sections = @($script:Registry['tools']['properties'].Keys)
        foreach ($id in $script:AllTools) {
            $e = $script:Catalog[$id]
            if ($e.Contains('tools_section')) { $e['tools_section'] | Should -BeIn $sections -Because "tool $id" }
        }
    }
}

Describe 'The template of a tool holds exactly the keys the registry gives the tool' {
    It '<_>: every key whose used_by names the tool is in templates/tools, and nothing else is, except the file''s own _metadata and the sections above a key' -ForEach $script:ToolsWithKeys {
        $id = $_
        $file = Join-Path $script:Vars ("templates\tools\{0}.yml" -f ($id -replace '_', '-'))
        $file | Should -Exist
        # a free-key map (tags.*) is written as <path>.example_name in a template
        $template = @(Get-DataPath (ConvertFrom-Yaml (Get-Content -LiteralPath $file -Raw) -Ordered) '' | ForEach-Object { $_ -replace '\.example_name$', '.*' } | Sort-Object -Unique)
        $tagged = @($script:Variables | Where-Object { @($_.UsedBy -split '\|') -contains $id } | ForEach-Object Path | Sort-Object -Unique)
        $tagged.Count | Should -BeGreaterThan 0

        $missing = @($tagged | Where-Object { $template -notcontains $_ })
        $missing | Should -BeNullOrEmpty -Because "used_by names $id but the template lacks: $($missing -join ', ')"

        $extra = @(Get-ExtraKey $template $tagged)
        $extra | Should -BeNullOrEmpty -Because "the template of $id holds keys whose used_by does not name $id: $($extra -join ', ')"
    }

    It 'a template that holds a key of another tool is found (the check itself works)' {
        $tagged = @($script:Variables | Where-Object { @($_.UsedBy -split '\|') -contains 'ranger' } | ForEach-Object Path)
        $other = @($script:Variables | Where-Object { $_.UsedBy -and @($_.UsedBy -split '\|') -notcontains 'ranger' -and $_.Shape -eq 'scalar' -and $_.Path -notlike '_metadata.*' } | Select-Object -First 1 -ExpandProperty Path)
        $other.Count | Should -Be 1
        @(Get-ExtraKey (@($tagged) + $other) $tagged) | Should -Be $other
        @(Get-ExtraKey $tagged $tagged) | Should -BeNullOrEmpty
    }
}
