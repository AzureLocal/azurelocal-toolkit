#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Research row g4 413: New-AzlArmParameterSet (AzlArmDeployment.psm1) falls back to a value when an optional key is not in the infrastructure file.
# ConvertTo-AzlArmIntent does the same for the Network ATC overrides of an intent (pass H): its QoS and RDMA technology fallbacks are read the same way.
# Those values must be the registry default of the key (config/variables/schema/master-registry.yaml), so the two can never differ, and they must be
# what Microsoft's template uses as the parameter default. Four groups of tests:
#   1. The code is read with the PowerShell parser: every literal fallback of `& $g '<key>' <value>` and of `Get-AzlProp $<object> '<key>' <value>`
#      equals the `default` of the registry entry; an empty fallback has no registry default; a required key has no non-empty fallback.
#   2. The two fallbacks that are expressions are named, with the reason.
#   3. A file without the optional keys gives the registry defaults in the parameter set (nothing deployed changes).
#   4. Those defaults equal the defaultValue of Microsoft's template (the copy in tests/fixtures/arm/microsoft-create-cluster/azuredeploy.json).
# No Azure call is made: Invoke-AzRestMethod is mocked and throws.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/arm-deployment/ParameterSetDefaults.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock script blocks keep the signature of the real command.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $module = [IO.Path]::Combine($repoRoot, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-AzlArmParameterSet' }, $true)

    # The object variables of Get-AzlProp calls and the key each one is read from. A base that is not here and not in $skip is a test failure,
    # so a new fallback cannot be added without deciding where its key lives.
    $base = @{
        '$clusterProperties' = 'networking.cluster_network_properties'
        '$iscsi'             = 'storage.san.iscsi'
        '$iscsiNet'          = 'storage.san.iscsi.networks[]'
        '$li'                = 'identity.local_identity'
        '$ad'                = 'identity.active_directory'
        '$local'             = 'identity.local_admin'
        '$n'                 = 'nodes[]'
    }
    # Objects with a variable key, or whose entries come from a list the file names (SBE partner properties and credentials): no key to compare.
    $skip = @('$Infrastructure', '$handoffNode', '$sbeFile', '$property', '$credential')

    # A literal in the source: a constant, $true, $false, $null, an empty array, or an expression.
    function Get-Literal($Node) {
        if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return @{ Kind = 'string'; Value = $Node.Value } }
        if ($Node -is [System.Management.Automation.Language.ConstantExpressionAst]) { return @{ Kind = 'number'; Value = $Node.Value } }
        if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
            switch ($Node.VariablePath.UserPath) {
                'true' { return @{ Kind = 'bool'; Value = $true } }
                'false' { return @{ Kind = 'bool'; Value = $false } }
                'null' { return @{ Kind = 'null'; Value = $null } }
            }
        }
        if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst] -and $Node.SubExpression.Statements.Count -eq 0) { return @{ Kind = 'empty-list'; Value = @() } }
        return @{ Kind = 'expression'; Value = $Node.Extent.Text }
    }

    $cases = [System.Collections.Generic.List[hashtable]]::new()
    $unknownBase = [System.Collections.Generic.List[string]]::new()
    # ConvertTo-AzlArmIntent (one networking.intents[] entry as the template's intentList) is read the same way: its objects are the overrides blocks of the intent.
    $intentFn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-AzlArmIntent' }, $true)
    $intentBase = @{
        '$qos'     = 'networking.intents[].overrides.qos'
        '$adapter' = 'networking.intents[].overrides.adapter'
    }
    $intentSkip = @('$overrides', '$vswitch', '$Intent')
    $readCall = @(
        @{ Fn = $fn; Base = $base; Skip = $skip }
        @{ Fn = $intentFn; Base = $intentBase; Skip = $intentSkip }
    )
    foreach ($r in $readCall) {
        foreach ($c in $r.Fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $e = @($c.CommandElements)
            $first = $e[0].Extent.Text
            if ($first -eq '$g' -and $c.InvocationOperator -eq 'Ampersand' -and $e.Count -eq 3 -and $e[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $lit = Get-Literal $e[2]
                $cases.Add(@{ Key = $e[1].Value; Kind = $lit.Kind; Value = $lit.Value; Line = $c.Extent.StartLineNumber })
            }
            elseif ($first -eq 'Get-AzlProp' -and $e.Count -eq 4 -and $e[2] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $b = $e[1].Extent.Text
                if ($r.Base.ContainsKey($b)) {
                    $lit = Get-Literal $e[3]
                    $cases.Add(@{ Key = $r.Base[$b] + '.' + $e[2].Value; Kind = $lit.Kind; Value = $lit.Value; Line = $c.Extent.StartLineNumber })
                }
                elseif ($b -notin $r.Skip) { $unknownBase.Add("line $($c.Extent.StartLineNumber): $($c.Extent.Text)") }
            }
        }
    }
    $intentCase = @($cases | Where-Object { $_.Key -like 'networking.intents*' })
    # The security switches: foreach ($m in @(@('<parameter>', '<key under security>', <bool>), ...)) { ... & $g "security.$($m[1])" $m[2] }
    foreach ($arr in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true)) {
        $inner = @($arr.SubExpression.Statements | ForEach-Object { $_.PipelineElements } | ForEach-Object { $_.Expression } | Where-Object { $_ })
        $elements = @($inner | ForEach-Object { if ($_ -is [System.Management.Automation.Language.ArrayLiteralAst]) { $_.Elements } else { $_ } })
        if ($elements.Count -eq 3 -and $elements[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $elements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $elements[2] -is [System.Management.Automation.Language.VariableExpressionAst] -and $elements[2].VariablePath.UserPath -in 'true', 'false') {
            $cases.Add(@{ Key = 'security.' + $elements[1].Value; Kind = 'bool'; Value = ($elements[2].VariablePath.UserPath -eq 'true'); Line = $arr.Extent.StartLineNumber })
        }
    }
    $literalCase = @($cases | Where-Object { $_.Kind -in 'string', 'number', 'bool' -and -not ($_.Kind -eq 'string' -and $_.Value -eq '') } | Sort-Object { $_.Key } -Unique)
    $emptyCase = @($cases | Where-Object { $_.Kind -in 'null', 'empty-list' -or ($_.Kind -eq 'string' -and $_.Value -eq '') } | Sort-Object { $_.Key } -Unique)
    $expressionCase = @($cases | Where-Object { $_.Kind -eq 'expression' })
    $countCase = @(@{ Literal = $literalCase.Count; Empty = $emptyCase.Count; UnknownBase = @($unknownBase); Intent = $intentCase.Count })
    $configurationModeCase = @($expressionCase | Where-Object { $_.Key -eq 'storage.configuration_mode' })

    # The parameter the template takes for each key, and how the registry value reads in the template.
    $titleCase = { param($v) (Get-Culture).TextInfo.ToTitleCase([string]$v) }
    $parameterOfKey = [ordered]@{
        'cluster.deployment_mode'                      = @{ Parameter = 'deploymentMode'; Convert = $titleCase }
        'cluster.key_vault.create_new'                 = @{ Parameter = 'createNewKeyVault' }
        'cluster.key_vault.soft_delete_retention_days' = @{ Parameter = 'softDeleteRetentionDays' }
        'cluster.diagnostics.logs_retention_days'      = @{ Parameter = 'logsRetentionInDays' }
        'cluster.diagnostics.storage_account_type'     = @{ Parameter = 'storageAccountType' }
        'cluster.naming_prefix'                        = @{ Parameter = 'namingPrefix' }
        'security.level'                               = @{ Parameter = 'securityLevel'; Convert = $titleCase }
        'security.drift_control'                       = @{ Parameter = 'driftControlEnforced' }
        'security.credential_guard'                    = @{ Parameter = 'credentialGuardEnforced' }
        'security.smb_signing'                         = @{ Parameter = 'smbSigningEnforced' }
        'security.smb_cluster_encryption'              = @{ Parameter = 'smbClusterEncryption' }
        'security.bitlocker_boot_volume'               = @{ Parameter = 'bitlockerBootVolume' }
        'security.bitlocker_data_volumes'              = @{ Parameter = 'bitlockerDataVolumes' }
        'security.wdac'                                = @{ Parameter = 'wdacEnforced' }
        'security.telemetry.streaming_data'            = @{ Parameter = 'streamingDataClient' }
        'security.telemetry.eu_location'               = @{ Parameter = 'euLocation' }
        'security.telemetry.episodic_data_upload'      = @{ Parameter = 'episodicDataUpload' }
        'networking.management.use_dhcp'               = @{ Parameter = 'useDhcp' }
        'networking.storage.auto_ip'                   = @{ Parameter = 'enableStorageAutoIp' }
    }
    $parameterCase = @($parameterOfKey.Keys | ForEach-Object { @{ Key = $_; Parameter = $parameterOfKey[$_].Parameter; Convert = $parameterOfKey[$_].Convert } })
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    Import-Module powershell-yaml
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
    $script:Catalog = Get-AzlArmTemplateCatalog
    $script:Fixture = [IO.Path]::Combine($script:Repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    $script:RegistryByPath = @{}
    foreach ($r in Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml'))) { $script:RegistryByPath[$r.Path] = $r }
    $script:Template = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'tests', 'fixtures', 'arm', 'microsoft-create-cluster', 'azuredeploy.json')) -Raw | ConvertFrom-Json -AsHashtable

    function Get-RegistryDefault([string]$Key) {
        $r = $script:RegistryByPath[$Key]
        if ($null -eq $r) { return @{ Found = $false; Has = $false; Value = $null; Required = '' } }
        @{ Found = $true; Has = $r.HasDefault; Value = $r.Default; Required = [string]$r.Required }
    }
    function Get-Infra { Import-AzlInfrastructure -Path $script:Fixture -SkipValidation }
    function Convert-ToS2d([System.Collections.IDictionary]$Infra) {
        $Infra.scenario.storage_architecture = 's2d'
        $Infra.Remove('storage') | Out-Null
        $Infra['storage'] = [ordered]@{}
        $Infra.networking.Remove('cluster_networks')
        $Infra.networking.intents = @(
            [ordered]@{ name = 'mgmt_compute'; traffic = @('management', 'compute'); adapters = @('Port0', 'Port1') }
            [ordered]@{ name = 'storage'; traffic = @('storage'); adapters = @('Port2', 'Port3') })
        $Infra.networking['storage'] = [ordered]@{ networks = @([ordered]@{ name = 'StorageNetwork1'; adapter = 'Port2'; vlan_id = 711 }, [ordered]@{ name = 'StorageNetwork2'; adapter = 'Port3'; vlan_id = 712 }) }
        $Infra
    }
    # The fixture with every optional key that has a registry default taken out.
    function Remove-OptionalKey([System.Collections.IDictionary]$Infra) {
        $Infra.scenario.Remove('storage_connectivity')
        $Infra.cluster.Remove('naming_prefix'); $Infra.cluster.Remove('deployment_mode')
        $Infra.cluster.key_vault.Remove('create_new'); $Infra.cluster.key_vault.Remove('soft_delete_retention_days')
        $Infra.cluster.diagnostics.Remove('logs_retention_days'); $Infra.cluster.diagnostics.Remove('storage_account_type')
        $Infra.Remove('security') | Out-Null
        if ($Infra.networking.management.Contains('use_dhcp')) { $Infra.networking.management.Remove('use_dhcp') }
        if ($Infra.Contains('storage') -and $Infra.storage.Contains('configuration_mode')) { $Infra.storage.Remove('configuration_mode') }
        $Infra
    }
}

Describe 'The literal fallbacks of New-AzlArmParameterSet read from the code' {
    It 'finds the fallbacks (the parser sees the call sites, so an empty result would hide a drift)' -ForEach $countCase {
        $Literal | Should -BeGreaterThan 25
        $Empty | Should -BeGreaterThan 20
    }
    It 'knows where every Get-AzlProp object reads from (a new one needs an entry in this test)' -ForEach $countCase {
        $UnknownBase | Should -BeNullOrEmpty
    }
    It 'finds the fallbacks of ConvertTo-AzlArmIntent too (the QoS overrides, the adapter properties)' -ForEach $countCase {
        $Intent | Should -BeGreaterThan 4
    }
}

Describe 'The intent fallbacks are Network ATC''s defaults, from the registry' {
    BeforeAll {
        $script:Intent = InModuleScope AzlArmDeployment {
            ConvertTo-AzlArmIntent -Intent ([ordered]@{ name = 'storage'; traffic = @('storage'); adapters = @('Port2', 'Port3') }) -Resolve { param($a) $a }
        }
    }
    It 'an intent without overrides sends the registry default of each QoS key and of the RDMA technology' {
        $script:Intent.qosPolicyOverrides.priorityValue8021Action_Cluster | Should -Be ([string](Get-RegistryDefault 'networking.intents[].overrides.qos.cluster_priority').Value)
        $script:Intent.qosPolicyOverrides.priorityValue8021Action_SMB | Should -Be ([string](Get-RegistryDefault 'networking.intents[].overrides.qos.smb_priority').Value)
        $script:Intent.qosPolicyOverrides.bandwidthPercentage_SMB | Should -Be ([string](Get-RegistryDefault 'networking.intents[].overrides.qos.smb_bandwidth_percent').Value)
        (Get-RegistryDefault 'networking.intents[].overrides.adapter.network_direct_technology').Value | Should -Be 'roce_v2'
        $script:Intent.adapterPropertyOverrides.networkDirectTechnology | Should -Be 'RoCEv2'
    }
    It 'the registry defaults are the values Learn gives (Deploy host networking with Network ATC: cluster 7, SMB Direct 3 with 50 percent)' {
        (Get-RegistryDefault 'networking.intents[].overrides.qos.cluster_priority').Value | Should -Be 7
        (Get-RegistryDefault 'networking.intents[].overrides.qos.smb_priority').Value | Should -Be 3
        (Get-RegistryDefault 'networking.intents[].overrides.qos.smb_bandwidth_percent').Value | Should -Be 50
    }
    It 'the registry defaults are the values of Microsoft''s quickstart parameters file' {
        $p = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'tests', 'fixtures', 'arm', 'microsoft-create-cluster', 'azuredeploy.parameters.json')) -Raw | ConvertFrom-Json -AsHashtable
        $storage = @($p.parameters.intentList.value | Where-Object { $_.trafficType -contains 'Storage' })[0]
        $storage.qosPolicyOverrides.priorityValue8021Action_Cluster | Should -Be ([string](Get-RegistryDefault 'networking.intents[].overrides.qos.cluster_priority').Value)
        $storage.qosPolicyOverrides.priorityValue8021Action_SMB | Should -Be ([string](Get-RegistryDefault 'networking.intents[].overrides.qos.smb_priority').Value)
        $storage.qosPolicyOverrides.bandwidthPercentage_SMB | Should -Be ([string](Get-RegistryDefault 'networking.intents[].overrides.qos.smb_bandwidth_percent').Value)
        $storage.adapterPropertyOverrides.networkDirectTechnology | Should -Be 'RoCEv2'
    }
}

Describe 'A literal fallback is the registry default of its key' {
    It '<Key> (line <Line>): the registry has the key and its default equals the fallback' -ForEach $literalCase {
        $d = Get-RegistryDefault $Key
        $d.Found | Should -BeTrue -Because "$Key is not in the registry"
        $d.Has | Should -BeTrue -Because "$Key has no default in the registry, but the code falls back to $Value"
        switch ($Kind) {
            'bool' { [bool]$d.Value | Should -Be $Value }
            'number' { [int]$d.Value | Should -Be ([int]$Value) }
            default { [string]$d.Value | Should -BeExactly ([string]$Value) }
        }
    }
    # storage.san.iscsi.chap.enabled is required only inside the chap object; with no chap object CHAP is off, which is its default.
    It '<Key> (line <Line>): a key the file must have has no non-empty fallback' -ForEach @($literalCase | Where-Object { $_.Key -ne 'storage.san.iscsi.chap.enabled' }) {
        (Get-RegistryDefault $Key).Required | Should -Not -Be 'True' -Because "$Key is required: the file always has it, so a fallback of $Value is never used and a default would not mean anything"
    }
}

Describe 'An empty fallback means the key has no default' {
    It '<Key> (line <Line>): the key is in the registry and has no default' -ForEach $emptyCase {
        $d = Get-RegistryDefault $Key
        if ($d.Found) {
            if ($d.Has) { "$($d.Value)" | Should -BeNullOrEmpty -Because "$Key has a default in the registry, the code falls back to nothing" }
        }
        else {
            # A list or object entry is listed under its parent: the key must be the start of a registry path.
            @($script:RegistryByPath.Keys | Where-Object { $_.StartsWith("$Key.") -or $_.StartsWith("$Key[]") }).Count | Should -BeGreaterThan 0 -Because "$Key is not in the registry"
        }
    }
}

Describe 'The fallbacks that are expressions are named here, with the reason' {
    It 'every expression fallback is one of the three known (found: <Key>)' -ForEach @($expressionCase) {
        $Key | Should -BeIn 'storage.configuration_mode', 'azure.custom_location', 'networking.intents[].overrides.adapter.jumbo_packet'
    }
    It 'networking.intents[].overrides.adapter.jumbo_packet: the fallback depends on the traffic of the intent (9014 with storage, 1514 without), so the key has no default' {
        (Get-RegistryDefault 'networking.intents[].overrides.adapter.jumbo_packet').Has | Should -BeFalse
        $both = InModuleScope AzlArmDeployment {
            foreach ($t in @(@('storage'), @('management', 'compute'))) { (ConvertTo-AzlArmIntent -Intent ([ordered]@{ name = 'x'; traffic = $t; adapters = @('A') }) -Resolve { param($a) $a }).adapterPropertyOverrides.jumboPacket }
        }
        $both | Should -Be @('9014', '1514')
    }
    It 'storage.configuration_mode: the Storage Spaces Direct value is the registry default and the SAN value is one of its allowed values' -ForEach $configurationModeCase {
        # $(if ($storage -eq 'san') { 'infra_only' } else { 'express' }): the quoted words are 'san', the SAN value, the Storage Spaces Direct value
        $words = @([regex]::Matches($Value, "'([a-z_]+)'") | ForEach-Object { $_.Groups[1].Value })
        $words[0] | Should -Be 'san'
        $words[1] | Should -BeIn @($script:RegistryByPath['storage.configuration_mode'].Enum -split '\|')
        $words[2] | Should -Be ([string]$script:RegistryByPath['storage.configuration_mode'].Default)
    }
    It 'azure.custom_location: the fallback is built from the cluster name, so the key has no default' {
        (Get-RegistryDefault 'azure.custom_location').Has | Should -BeFalse
    }
}

Describe 'A file without the optional keys gives the registry defaults' {
    Context 'Storage Spaces Direct, Active Directory' {
        BeforeAll {
            $infra = Remove-OptionalKey (Convert-ToS2d (Get-Infra))
            $script:S2d = (New-AzlArmParameterSet -Infrastructure $infra -Catalog $script:Catalog).Parameters
        }
        It '<Key> -> <Parameter>' -ForEach $parameterCase {
            $expected = (Get-RegistryDefault $Key).Value
            if ($Convert) { $expected = & $Convert $expected }
            $script:S2d[$Parameter] | Should -Be $expected -Because "$Key is $expected in the registry"
        }
        It 'configurationMode is the registry default of storage.configuration_mode and the storage is switched' {
            $mode = [string](Get-RegistryDefault 'storage.configuration_mode').Value
            $script:S2d.configurationMode | Should -Be ($mode.Substring(0, 1).ToUpperInvariant() + $mode.Substring(1))
            $script:S2d.storageConnectivitySwitchless | Should -Be ((Get-RegistryDefault 'scenario.storage_connectivity').Value -eq 'switchless')
        }
    }
    Context 'SAN: the configuration mode falls back to InfraOnly' {
        It 'gives InfraOnly, which is an allowed value of storage.configuration_mode' {
            $infra = Remove-OptionalKey (Get-Infra)
            $p = (New-AzlArmParameterSet -Infrastructure $infra -Catalog $script:Catalog -AllowUnresolvedSanLun).Parameters
            $p.configurationMode | Should -Be 'InfraOnly'
            'infra_only' | Should -BeIn @($script:RegistryByPath['storage.configuration_mode'].Enum -split '\|')
        }
    }
}

Describe 'The registry defaults are the defaults of Microsoft''s template' {
    It '<Key> -> <Parameter>: the defaultValue of the template equals the registry default' -ForEach $parameterCase {
        $parameter = $script:Template.parameters[$Parameter]
        $parameter | Should -Not -BeNullOrEmpty -Because "the template has a parameter $Parameter"
        # The template spells the property defaultValue; for the auto IP parameter it is defaultvalue.
        $name = @($parameter.Keys | Where-Object { $_ -ieq 'defaultValue' })
        $name.Count | Should -Be 1 -Because "the template gives $Parameter a default"
        $expected = (Get-RegistryDefault $Key).Value
        if ($Convert) { $expected = & $Convert $expected }
        $parameter[$name[0]] | Should -Be $expected
    }
}
