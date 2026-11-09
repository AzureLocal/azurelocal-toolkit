#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The variable map (config/variables/docs/VARIABLE-MAP.md and reports/variable-map.csv) is generated from the master registry and a scan
# of the code. These tests fail when a committed file is out of date, when a registry variable is missing from the map or appears twice,
# when an ARM parameter the builder produces is missing from the by-ARM-parameter table, or when the map disagrees with the purpose files.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/VariableMap.Tests.ps1
# The check against the ZTP, Sonar and Trailwright checkouts runs only with AZL_VARMAP_CHECK_EXTERNAL=1 (they change on their own).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $script:Purposes = 'ztp', 'os_configuration', 'deployment', 'cicd_infra', 'monitoring', 'discovery'
    $script:ExternalCheck = ($env:AZL_VARMAP_CHECK_EXTERNAL -eq '1')
}

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Vars = Join-Path $script:Repo 'config\variables'
    $script:MapMd = Join-Path $script:Vars 'docs\VARIABLE-MAP.md'
    $script:MapCsv = Join-Path $script:Vars 'reports\variable-map.csv'
    $script:Snapshot = Join-Path $script:Vars 'reports\variable-map-external-readers.csv'
    $script:Rows = @(Import-Csv -LiteralPath $script:MapCsv)
    $script:Md = [IO.File]::ReadAllText($script:MapMd)
    Import-Module (Join-Path $script:Vars 'scripts\VariableRegistry.psm1') -Force
    Import-Module powershell-yaml
    $script:Registry = @(Get-RegistryVariable -Path (Join-Path $script:Vars 'schema\master-registry.yaml'))

    # The leaves of the registry, worked out here independently of the generator: a path nothing else is written below.
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($r in $script:Registry) { [void]$paths.Add($r.Path) }
    $parents = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($p in $paths) {
        $q = $p
        while ($true) {
            $n = $q -replace '(\.[^.\[\]]+|\[\])$', ''
            if ($n -eq $q) { break }
            $q = $n
            [void]$parents.Add($q)
        }
    }
    $script:Leaves = @($paths | Where-Object { -not $parents.Contains($_) })
}

Describe 'The committed map is current' {
    It 'New-VariableMap.ps1 -Check finds nothing stale (VARIABLE-MAP.md, variable-map.csv, the external snapshot)' {
        $out = & pwsh -NoProfile -File (Join-Path $script:Vars 'scripts\New-VariableMap.ps1') -Check 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'variable map is current'
    }

    It 'the page says it is generated and how to regenerate it' {
        $script:Md | Should -Match 'This page is generated\. Do not edit it\.'
        $script:Md | Should -Match 'New-VariableMap\.ps1 -Check'
    }

    It 'the files use LF line endings and end with a newline (so the check compares the same bytes everywhere)' {
        foreach ($f in $script:MapMd, $script:MapCsv, $script:Snapshot) {
            $bytes = [IO.File]::ReadAllBytes($f)
            [Array]::IndexOf($bytes, [byte]13) | Should -Be -1 -Because "$f has a carriage return"
            $bytes[-1] | Should -Be 10
        }
    }

    It 'the registry the page names is the registry on disk' {
        $reg = Read-RegistryYaml -Path (Join-Path $script:Vars 'schema\master-registry.yaml')
        $script:Md | Should -Match ([regex]::Escape("Registry version $($reg['_metadata']['version'])"))
    }

    It 'the committed ZTP, Sonar and Trailwright snapshot matches their checkouts' -Skip:(-not $script:ExternalCheck) {
        $out = & pwsh -NoProfile -File (Join-Path $script:Vars 'scripts\New-VariableMap.ps1') -Check -RescanExternal 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }
}

Describe 'Every registry variable is in the map once' {
    It 'has one row per leaf of the registry' {
        $script:Rows.Count | Should -Be $script:Leaves.Count
    }

    It 'has no path twice' {
        @($script:Rows | Group-Object path -CaseSensitive | Where-Object Count -gt 1).Count | Should -Be 0
    }

    It 'has no leaf missing and no row that is not a leaf' {
        $inRows = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($r in $script:Rows) { [void]$inRows.Add($r.path) }
        $missing = @($script:Leaves | Where-Object { -not $inRows.Contains($_) })
        $extra = @($script:Rows | Where-Object { $script:Leaves -cnotcontains $_.path } | ForEach-Object path)
        $missing | Should -BeNullOrEmpty
        $extra | Should -BeNullOrEmpty
    }

    It 'gives every row a kind, a status and a provider' {
        foreach ($r in $script:Rows) {
            $r.kind | Should -BeIn 'infrastructure.yml', 'tool', 'variables-file'
            $r.status | Should -BeIn 'read', 'read-as-part', 'validated-only', 'placeholder', 'deprecated'
            $r.provided_by | Should -Not -BeNullOrEmpty -Because $r.path
        }
    }

    It 'names what replaces every deprecated variable that has a replacement in the registry' {
        $dep = @($script:Registry | Where-Object { $_.Deprecated -and $_.Node.Contains('replaced_by') } | ForEach-Object Path)
        foreach ($p in $dep) {
            $row = $script:Rows | Where-Object path -eq $p
            if ($row) { $row.replaced_by | Should -Not -BeNullOrEmpty -Because $p }
        }
    }

    It 'knows every key of infrastructure.yml: each schema key that is a leaf is a row of kind infrastructure.yml' {
        $schema = Get-InfrastructureSchemaVariable -SchemaPath (Join-Path $script:Vars 'schema\infrastructure.schema.json')
        $infraRows = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($r in ($script:Rows | Where-Object kind -eq 'infrastructure.yml')) { [void]$infraRows.Add($r.path) }
        $leafSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($l in $script:Leaves) { [void]$leafSet.Add($l) }
        $notThere = @($schema | Where-Object { $leafSet.Contains($_.Path) -and -not $infraRows.Contains($_.Path) })
        $notThere | Should -BeNullOrEmpty
    }
}

Describe 'The purposes in the map are the purpose files' {
    It '<_>: the variables the map gives this purpose are the keys of schema/purposes/<_>.schema.json' -ForEach $script:Purposes {
        $name = $_
        $schemaPath = Join-Path $script:Vars ("schema\purposes\{0}.schema.json" -f ($name -replace '_', '-'))
        $inSchema = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($s in (Get-InfrastructureSchemaVariable -SchemaPath $schemaPath)) { [void]$inSchema.Add($s.Path) }
        $mapped = @($script:Rows | Where-Object { $_.kind -eq 'infrastructure.yml' -and $_.path -notlike '_metadata.*' -and (@($_.purposes -split '; ') -contains $name) } | ForEach-Object path)
        $mapped.Count | Should -BeGreaterThan 0
        $notInSchema = @($mapped | Where-Object { -not $inSchema.Contains($_) })
        $notInSchema | Should -BeNullOrEmpty -Because "the map says $name carries these keys but its purpose schema lacks them"
        # a leaf of the purpose schema (other than the file's own _metadata) must be one the map gives to this purpose
        $leafRows = @($script:Rows | Where-Object { $_.kind -eq 'infrastructure.yml' -and $_.path -notlike '_metadata.*' } | ForEach-Object path)
        $schemaLeaves = @($leafRows | Where-Object { $inSchema.Contains($_) })
        $schemaLeaves.Count | Should -Be $mapped.Count
    }
}

Describe 'Every ARM parameter the builder produces is in the by-ARM-parameter table' {
    BeforeAll {
        Import-Module (Join-Path $script:Repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
        Import-Module (Join-Path $script:Repo 'scripts\common\azure-local\AzlAzure.psm1') -Force
        Import-Module (Join-Path $script:Repo 'scripts\common\arm-deployment\AzlArmDeployment.psm1') -Force
        Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
        $script:Fixture = Join-Path $script:Repo 'tests\fixtures\infrastructure.fc-san.yml'
        $script:Catalog = Get-AzlArmTemplateCatalog

        # the by-ARM-parameter table of the page: the first column
        $start = $script:Md.IndexOf('## By ARM parameter')
        $end = $script:Md.IndexOf('## Where do I set X')
        $section = $script:Md.Substring($start, $end - $start)
        $script:TableParameters = @([regex]::Matches($section, '(?m)^\| `([A-Za-z0-9_]+)` \|') | ForEach-Object { $_.Groups[1].Value })

        function Get-Infra { Import-AzlInfrastructure -Path $script:Fixture -SkipValidation }
        function ConvertTo-S2d([System.Collections.IDictionary]$Infra) {
            $Infra.scenario.storage_architecture = 's2d'
            $Infra.Remove('storage') | Out-Null
            $Infra['storage'] = [ordered]@{ configuration_mode = 'express' }
            $Infra.networking.Remove('cluster_networks')
            $Infra.networking.intents = @(
                [ordered]@{ name = 'mgmt_compute'; traffic = @('management', 'compute'); adapters = @('Port0', 'Port1') }
                [ordered]@{ name = 'storage'; traffic = @('storage'); adapters = @('Port2', 'Port3') })
            $Infra.networking['storage'] = [ordered]@{ auto_ip = $true; networks = @([ordered]@{ name = 'StorageNetwork1'; adapter = 'Port2'; vlan_id = 711 }, [ordered]@{ name = 'StorageNetwork2'; adapter = 'Port3'; vlan_id = 712 }) }
            $Infra
        }
        function Get-ParameterName([System.Collections.IDictionary]$Infra) {
            $set = New-AzlArmParameterSet -Infrastructure $Infra -Mode Validate -Catalog $script:Catalog -AllowUnresolvedSanLun 3>$null
            @($set.Parameters.Keys)
        }
        $script:Produced = [ordered]@{
            'Fibre Channel SAN, Active Directory' = { Get-ParameterName (Get-Infra) }
            'Storage Spaces Direct, Active Directory' = { Get-ParameterName (ConvertTo-S2d (Get-Infra)) }
            'Storage Spaces Direct, local identity' = { $i = ConvertTo-S2d (Get-Infra); $i.scenario.identity = 'local_identity'; $i.identity['local_identity'] = [ordered]@{ dns_zone = 'lab.example'; dns_server_config = 'use_dns_server'; dns_forwarders = @('192.0.2.1') }; Get-ParameterName $i }
            'Storage Spaces Direct, rack aware'  = { $i = ConvertTo-S2d (Get-Infra); $i.scenario.topology = 'rack_aware'; for ($n = 0; $n -lt @($i.nodes).Count; $n++) { @($i.nodes)[$n]['zone'] = "zone$($n % 2)" }; Get-ParameterName $i }
            'Storage Spaces Direct with an SBE'  = { $i = ConvertTo-S2d (Get-Infra); $i.hardware['sbe'] = [ordered]@{ version = '1.0.0'; family = 'Example'; publisher = 'Example'; manifest_source = 'https://example.invalid/manifest'; manifest_creation_date = '2026-01-01' }; Get-ParameterName $i }
        }
    }

    It 'the table has the parameters of the catalog and of the builder' {
        $script:TableParameters.Count | Should -BeGreaterThan 50
        $script:TableParameters | Should -Contain 'clusterName'
        $script:TableParameters | Should -Contain 'intentList'
    }

    It 'every parameter produced for: <_>' -ForEach @('Fibre Channel SAN, Active Directory', 'Storage Spaces Direct, Active Directory', 'Storage Spaces Direct, local identity', 'Storage Spaces Direct, rack aware', 'Storage Spaces Direct with an SBE') {
        $names = & $script:Produced[$_]
        $names.Count | Should -BeGreaterThan 30
        $missing = @($names | Where-Object { $script:TableParameters -cnotcontains $_ })
        $missing | Should -BeNullOrEmpty -Because 'the by-ARM-parameter table must list every parameter the builder sets'
    }

    It 'every parameter of every quickstart template in the catalog is in the table' {
        $all = foreach ($t in $script:Catalog.templates.Keys) { $script:Catalog.templates[$t].parameters.Keys }
        $missing = @($all | Select-Object -Unique | Where-Object { $script:TableParameters -cnotcontains $_ })
        $missing | Should -BeNullOrEmpty
    }

    It 'gives the file key each well-known parameter comes from' {
        $cases = @{ clusterName = 'cluster.name'; location = 'azure.location'; tenantId = 'azure.tenant_id'; securityLevel = 'security.level'; defaultGateway = 'networking.management.gateway'; subnetMask = 'networking.management.subnet'; localAdminUserName = 'identity.local_admin.username'; diagnosticStorageAccountName = 'cluster.diagnostics.storage_account'; startingIPAddress = 'networking.management.infrastructure_pool.start' }
        foreach ($name in $cases.Keys) {
            $row = [regex]::Match($script:Md, "(?m)^\| ``$name`` \|[^\r\n]*$").Value
            $row | Should -Not -BeNullOrEmpty -Because $name
            $row | Should -Match ([regex]::Escape('`' + $cases[$name] + '`')) -Because "$name comes from $($cases[$name])"
        }
    }

    It 'the row of a key says which ARM parameter it becomes' {
        ($script:Rows | Where-Object path -eq 'cluster.name').arm_parameters | Should -Match 'clusterName'
        ($script:Rows | Where-Object path -eq 'networking.management.gateway').arm_parameters | Should -Be 'defaultGateway'
    }
}

Describe 'The map says who provides, who reads and what a key becomes' {
    It 'cluster.name is read by the ARM run, the OS configuration, ZTP and Sonar' {
        $row = $script:Rows | Where-Object path -eq 'cluster.name'
        $row.status | Should -Be 'read'
        foreach ($tool in 'arm-deployment', 'os-configuration', 'ztp', 'sonar') { @($row.read_by_tools -split '; ') | Should -Contain $tool }
        $row.sonar_config_key | Should -Be 'clusterName'
    }

    It 'a key the Redfish discovery proposes says so, and one a person must fill does not' {
        ($script:Rows | Where-Object path -eq 'nodes[].serial_number').provided_by | Should -Match 'Redfish discovery'
        ($script:Rows | Where-Object path -eq 'nodes[].network_adapters[].mac_address').provided_by | Should -Match 'Redfish discovery'
        ($script:Rows | Where-Object path -eq 'networking.management.gateway').provided_by | Should -Not -Match 'Redfish discovery'
    }

    It 'a Key Vault reference says so, and Trailwright''s questions are listed' {
        ($script:Rows | Where-Object path -eq 'identity.local_admin.password').provided_by | Should -Match 'Key Vault reference'
        ($script:Rows | Where-Object path -eq 'cluster.name').trailwright | Should -Not -BeNullOrEmpty
    }

    It 'the OS configuration step that applies a key is named' {
        ($script:Rows | Where-Object path -eq 'networking.ntp_servers').os_steps | Should -Match 'Time'
        ($script:Rows | Where-Object path -eq 'identity.local_admin.username').os_steps | Should -Match 'LocalAdmin'
        ($script:Rows | Where-Object path -eq 'os_configuration.clear_storage').os_steps | Should -Match 'ClearStorage'
    }

    It 'a placeholder is a registry variable no tool reads, and the page lists it' {
        $placeholders = @($script:Rows | Where-Object { $_.kind -eq 'infrastructure.yml' -and $_.status -eq 'placeholder' })
        $placeholders.Count | Should -BeGreaterThan 0
        foreach ($p in ($placeholders | Select-Object -First 5)) {
            $p.read_by_tools | Should -BeNullOrEmpty
            $script:Md | Should -Match ([regex]::Escape('`' + $p.path + '`'))
        }
    }

    It 'the page has the five views and the tool tables' {
        foreach ($h in '## By phase', '## By tool', '## By ARM parameter', '## Where do I set X', '## Unread and placeholder variables', '## The map: every key of infrastructure.yml') {
            $script:Md | Should -Match ([regex]::Escape($h))
        }
        $script:Md | Should -Match 'Discovery'
        $script:Md | Should -Match 'Pre-cluster verification'
    }

    It '"Where do I set X" lists 40 variables' {
        $start = $script:Md.IndexOf('## Where do I set X')
        $end = $script:Md.IndexOf('## Unread and placeholder variables')
        @([regex]::Matches($script:Md.Substring($start, $end - $start), '(?m)^\| `[^`]+` \|')).Count | Should -Be 40
    }
}

Describe 'The map is linked and has a diagram' {
    It 'config/variables/README.md and docs/os-configuration-and-arm-deployment.md link the map' {
        (Get-Content (Join-Path $script:Vars 'README.md') -Raw) | Should -Match 'VARIABLE-MAP\.md'
        (Get-Content (Join-Path $script:Repo 'docs\os-configuration-and-arm-deployment.md') -Raw) | Should -Match 'VARIABLE-MAP\.md'
    }

    It 'every relative link of the page points at a file that exists' {
        $dir = Split-Path -Parent $script:MapMd
        foreach ($m in [regex]::Matches($script:Md, '\]\((?<t>[^)#]+)(#[^)]*)?\)')) {
            $t = $m.Groups['t'].Value
            if ($t -match '^(https?:|mailto:)') { continue }
            Test-Path -LiteralPath (Join-Path $dir $t) | Should -BeTrue -Because "the link $t"
        }
    }

    It 'the draw.io diagram is XML that shows the sources, the master file, the purpose files, the tools and Azure' {
        $file = Join-Path $script:Repo 'docs\diagrams\variable-flow.drawio'
        Test-Path -LiteralPath $file | Should -BeTrue
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $xml.mxfile | Should -Not -BeNullOrEmpty
        $text = (Get-Content -LiteralPath $file -Raw)
        foreach ($word in 'Trailwright', 'Redfish', 'infrastructure.yml', 'ztp', 'os_configuration', 'deployment', 'monitoring', 'discovery', 'cicd_infra', 'azurelocal-ztp', 'Sonar', 'Azure', 'Key Vault') {
            $text | Should -Match ([regex]::Escape($word))
        }
    }

    It 'the committed map holds no secret and no identifier' {
        $guid = [regex]'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'
        $allowed = '1412d89f-b8a8-4111-b4fd-e82905cbd85d'   # Microsoft's Azure Local resource provider application (public)
        foreach ($f in $script:MapMd, $script:MapCsv, $script:Snapshot) {
            $found = @($guid.Matches([IO.File]::ReadAllText($f)) | ForEach-Object Value | Where-Object { $_ -ne $allowed -and $_ -ne '00000000-0000-0000-0000-000000000000' } | Select-Object -Unique)
            $found | Should -BeNullOrEmpty -Because "$f"
        }
    }
}
