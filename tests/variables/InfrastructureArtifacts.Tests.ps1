#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The infrastructure.yml schema, the master template, the purpose templates and schemas, the stubs and the variables reference are
# generated from config/variables/schema/master-registry.yaml. These tests regenerate them and fail when one is stale, and prove
# that a purpose template is a strict subset of the master file and that a real file can be cut down to each purpose.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $script:Purposes = 'ztp', 'os_configuration', 'deployment', 'cicd_infra', 'monitoring', 'discovery'
}

BeforeAll {
    $script:Repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:Vars = Join-Path $script:Repo 'config\variables'
    Import-Module (Join-Path $script:Vars 'scripts\InfrastructureArtifacts.psm1') -Force
    $script:AzlModule = Import-Module (Join-Path $script:Repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force -PassThru
    $script:Registry = Get-RegistryDocument -Path (Join-Path $script:Vars 'schema\master-registry.yaml')

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
    function Get-SchemaError([string]$Json, [string]$SchemaFile) {
        @(& $script:AzlModule { param($j, $s) Get-SchemaFinding -Json $j -SchemaText $s } $Json (Get-Content -LiteralPath $SchemaFile -Raw))
    }
}

Describe 'Generated files are current' {
    It 'New-InfrastructureArtifacts.ps1 -Check finds nothing stale (schema, purpose schemas, templates, stubs, VARIABLES.md)' {
        $out = & pwsh -NoProfile -File (Join-Path $script:Vars 'scripts\New-InfrastructureArtifacts.ps1') -Check 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'generated files are current'
    }

    It '<_> carries the generated-from header' -ForEach 'schema\infrastructure.schema.json', 'templates\infrastructure.master.yml', 'templates\purposes\ztp.yml', 'schema\purposes\ztp.schema.json' {
        (Get-Content -LiteralPath (Join-Path $script:Vars $_) -TotalCount 5 | Out-String) | Should -Match 'GENERATED from config/variables/schema/master-registry.yaml'
    }

    It 'the stubs at config/infrastructure say they are stubs and point to the source' {
        $stub = Join-Path $script:Repo 'config\infrastructure'
        (Get-Content (Join-Path $stub 'infrastructure.schema.json') -Raw) | Should -Match 'STUB'
        (Get-Content (Join-Path $stub 'infrastructure.example.yml') -Raw) | Should -Match '# STUB: a copy of config/variables/examples/infrastructure.example.yml'
        (Get-Content (Join-Path $stub 'infrastructure.ztp.example.yml') -Raw) | Should -Match '# STUB: a copy of config/variables/examples/infrastructure.ztp.example.yml'
        ((Get-Content (Join-Path $stub 'infrastructure.schema.json') -Raw | ConvertFrom-Json).'$id') | Should -Be ((Get-Content (Join-Path $script:Vars 'schema\infrastructure.schema.json') -Raw | ConvertFrom-Json).'$id')
    }

    It 'the validator reads the generated schema' {
        $path = & $script:AzlModule { $script:DefaultSchemaPath }
        (Resolve-Path $path).Path | Should -Be (Resolve-Path (Join-Path $script:Vars 'schema\infrastructure.schema.json')).Path
    }
}

Describe 'The schema built from the registry' {
    It 'keeps the sections of infrastructure.yml in the registry order, and the scope and scenario rules' {
        $schema = Get-Content (Join-Path $script:Vars 'schema\infrastructure.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        @($schema.properties.Keys)[0] | Should -Be '_metadata'
        $schema.properties.Keys | Should -Contain 'os_configuration'
        $schema.allOf.Count | Should -BeGreaterOrEqual 2
        $schema.'$defs'.Keys | Should -Contain 'kv_ref'
    }

    It 'accepts every curated example (<_>)' -ForEach @(Get-ChildItem (Join-Path $PSScriptRoot '..\..\config\variables\examples') -Recurse -Filter '*.yml' | ForEach-Object FullName) {
        $json = ConvertFrom-Yaml (Get-Content -LiteralPath $_ -Raw) -Ordered | ConvertTo-Json -Depth 50
        @(Get-SchemaError $json (Join-Path $script:Vars 'schema\infrastructure.schema.json')) | Should -BeNullOrEmpty
    }
}

Describe 'Purpose templates and schemas' {
    It 'the <_> template is a strict subset of the master file' -ForEach $script:Purposes {
        $file = $_ -replace '_', '-'
        $master = @(Get-DataPath (ConvertFrom-Yaml (Get-Content (Join-Path $script:Vars 'templates\infrastructure.master.yml') -Raw) -Ordered) '' | Sort-Object -Unique)
        $part = @(Get-DataPath (ConvertFrom-Yaml (Get-Content (Join-Path $script:Vars "templates\purposes\$file.yml") -Raw) -Ordered) '' | Sort-Object -Unique)
        $part.Count | Should -BeGreaterThan 3
        @($part | Where-Object { $master -notcontains $_ -and $_ -notmatch '\.example_name$' }) | Should -BeNullOrEmpty
        $part.Count | Should -BeLessThan $master.Count
    }

    It 'the <_> schema is a subset of the full schema (same keys, nothing added)' -ForEach $script:Purposes {
        $full = Get-Content (Join-Path $script:Vars 'schema\infrastructure.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $part = Get-Content (Join-Path $script:Vars "schema\purposes\$($_ -replace '_', '-').schema.json") -Raw | ConvertFrom-Json -AsHashtable
        function Test-Subset($p, $f, [string]$at) {
            if ($f -is [System.Collections.IDictionary] -and $f.Contains('$ref')) {
                $merged = [ordered]@{}
                foreach ($k in $full.'$defs'[($f['$ref'] -replace '^#/\$defs/', '')].Keys) { $merged[$k] = $full.'$defs'[($f['$ref'] -replace '^#/\$defs/', '')][$k] }
                foreach ($k in $f.Keys) { if ($k -ne '$ref') { $merged[$k] = $f[$k] } }
                $f = $merged
            }
            if ($p -is [System.Collections.IDictionary] -and $f -is [System.Collections.IDictionary]) {
                foreach ($k in $p.Keys) {
                    if ($k -in 'title', 'description', '$id', '$comment', '$ref') { continue }
                    if (-not $f.Contains($k)) { "$at.$k"; continue }
                    Test-Subset $p[$k] $f[$k] "$at.$k"
                }
            }
        }
        @(Test-Subset $part.properties $full.properties 'properties') | Should -BeNullOrEmpty
    }

    It 'a real file cut down to <_> validates against the purpose schema, for every example, and keeps only values it had' -ForEach $script:Purposes {
        $purpose = $_
        $schemaFile = Join-Path $script:Vars "schema\purposes\$($purpose -replace '_', '-').schema.json"
        foreach ($example in (Get-ChildItem (Join-Path $script:Vars 'examples') -Recurse -Filter '*.yml')) {
            $doc = ConvertFrom-Yaml (Get-Content $example.FullName -Raw) -Ordered
            $cut = Select-InfrastructurePurpose -Registry $script:Registry -Document $doc -Purpose $purpose
            @(Get-SchemaError ($cut | ConvertTo-Json -Depth 50) $schemaFile) | Should -BeNullOrEmpty -Because "$($example.Name) cut to $purpose"
            $original = @(Get-DataPath $doc '')
            @(Get-DataPath $cut '' | Where-Object { $original -notcontains $_ }) | Should -BeNullOrEmpty
        }
    }

    It 'the ztp cut keeps what ZTP reads and drops the rest' {
        $doc = ConvertFrom-Yaml (Get-Content (Join-Path $script:Vars 'examples\infrastructure.example.yml') -Raw) -Ordered
        $cut = Select-InfrastructurePurpose -Registry $script:Registry -Document $doc -Purpose ztp
        $paths = @(Get-DataPath $cut '')
        $paths | Should -Contain 'nodes[].bmc.ip_address'
        $paths | Should -Contain 'networking.management.subnet'
        $paths | Should -Not -Contain 'devops'
        $paths | Should -Not -Contain 'storage'
    }

    It 'the master file cut to a purpose and the rest together make the master file again' {
        $doc = ConvertFrom-Yaml (Get-Content (Join-Path $script:Vars 'examples\infrastructure.example.yml') -Raw) -Ordered
        $all = @(Get-DataPath $doc '' | Sort-Object -Unique)
        $union = @()
        foreach ($p in $script:Purposes) { $union += @(Get-DataPath (Select-InfrastructurePurpose -Registry $script:Registry -Document $doc -Purpose $p) '') }
        @($union | Sort-Object -Unique | Where-Object { $all -notcontains $_ }) | Should -BeNullOrEmpty
    }
}

Describe 'The cut command' {
    It 'writes a purpose file that validates against the purpose schema' {
        $out = Join-Path $TestDrive 'infra.ztp.yml'
        & (Join-Path $script:Vars 'scripts\New-InfrastructureArtifacts.ps1') -Cut ztp -From (Join-Path $script:Vars 'examples\infrastructure.example.yml') -Out $out 6>$null
        $out | Should -Exist
        $json = ConvertFrom-Yaml (Get-Content $out -Raw) -Ordered | ConvertTo-Json -Depth 50
        @(Get-SchemaError $json (Join-Path $script:Vars 'schema\purposes\ztp.schema.json')) | Should -BeNullOrEmpty
    }
}
