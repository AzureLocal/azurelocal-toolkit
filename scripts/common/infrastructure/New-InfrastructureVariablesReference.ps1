#Requires -Version 7.0
<#
.SYNOPSIS
    Renders config/infrastructure/VARIABLES.md, the variables reference of infrastructure.yml, from the JSON schema.

.DESCRIPTION
    One row per key, grouped by section: path, what it is, type, whether it is required in full and in ztp scope, the default,
    an example, where to get the value, and which tools read it. Types, required keys, defaults and descriptions come from
    config/infrastructure/infrastructure.schema.json. Examples come from the templates and example files. Where to get a
    value, and which tools read a key, come from config/infrastructure/variables-reference.metadata.psd1.

    The page is generated: edit the schema or the metadata, then run this script. With -Check nothing is written; the script
    exits 1 when the page on disk differs from what it would write (the Pester tests run this).

.PARAMETER SchemaPath
    The JSON schema. Default: config/infrastructure/infrastructure.schema.json.

.PARAMETER MetadataPath
    Facts the schema doesn't hold. Default: config/infrastructure/variables-reference.metadata.psd1.

.PARAMETER OutputPath
    The page to write. Default: config/infrastructure/VARIABLES.md.

.PARAMETER Check
    Compare instead of write; exit 1 when the page is out of date.

.EXAMPLE
    ./scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1

.EXAMPLE
    ./scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..\..\..\config\infrastructure\infrastructure.schema.json'),
    [string]$MetadataPath = (Join-Path $PSScriptRoot '..\..\..\config\infrastructure\variables-reference.metadata.psd1'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\..\..\config\infrastructure\VARIABLES.md'),
    [switch]$Check
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop
$configDir = Split-Path -Parent (Resolve-Path -LiteralPath $SchemaPath)
$schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json -AsHashtable
$meta = Import-PowerShellDataFile -LiteralPath $MetadataPath
$defs = $schema['$defs']

# ---------------------------------------------------------------------------------------------------------------------
# Schema helpers
# ---------------------------------------------------------------------------------------------------------------------

$refTypes = @{
    ipv4 = 'IPv4 address'; cidr = 'CIDR'; mac = 'MAC address'; guid = 'GUID'; kv_ref = 'keyvault:// reference'; date = 'date (YYYY-MM-DD)'
    netbios_name = 'NetBIOS name'; resource_group = 'resource group name'; key_vault_name = 'Key Vault name'
    storage_account_name = 'storage account name'; azure_region = 'Azure region'; wwpn = 'WWPN'; iscsi_name = 'iSCSI name (IQN)'
    iscsi_portal = 'IPv4 or IPv4:port'
}

function Resolve-Node($Node) {
    $ref = $null
    while ($Node -is [System.Collections.IDictionary] -and $Node.Contains('$ref')) {
        $ref = ([string]$Node['$ref']) -replace '^#/\$defs/', ''
        $merged = [ordered]@{}
        foreach ($k in $defs[$ref].Keys) { $merged[$k] = $defs[$ref][$k] }
        foreach ($k in $Node.Keys) { if ($k -ne '$ref') { $merged[$k] = $Node[$k] } }
        $Node = $merged
    }
    [pscustomobject]@{ Node = $Node; Ref = $ref }
}

function Get-Val($Node, [string]$Key) { if ($Node -is [System.Collections.IDictionary] -and $Node.Contains($Key)) { $Node[$Key] } else { $null } }

function Get-TypeText($Resolved) {
    $n = $Resolved.Node
    if ($Resolved.Ref -and $refTypes.ContainsKey($Resolved.Ref)) { return $refTypes[$Resolved.Ref] }
    if ($n -isnot [System.Collections.IDictionary]) { return 'any' }
    if ($n.Contains('enum')) {
        $values = @($n['enum'] | ForEach-Object { '`' + $_ + '`' })
        return 'one of ' + (($values | Select-Object -First 10) -join ', ')
    }
    if ($n.Contains('const')) { return 'const `' + $n['const'] + '`' }
    $type = $n['type']
    if ($type -eq 'array') {
        $items = Resolve-Node (Get-Val $n 'items')
        $inner = if ($items.Node -is [System.Collections.IDictionary] -and $items.Node['type'] -eq 'object' -and -not $items.Ref) { 'objects' } else { Get-TypeText $items }
        return "list of $inner"
    }
    if ($type -eq 'object' -and $n.Contains('additionalProperties') -and $n['additionalProperties'] -is [System.Collections.IDictionary] -and -not $n.Contains('properties')) { return 'map of strings' }
    if ($type) { return [string]$type }
    return 'any'
}

function Get-FirstSentence([string]$Text, [int]$Max = 150) {
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    $since = ''
    if ($t -match '^Schema (5\.\d+)\.\s+(.*)$') { $since = " (since $($Matches[1]))"; $t = $Matches[2]; $t = $t.Substring(0, 1).ToUpperInvariant() + $t.Substring(1) }
    $m = [regex]::Match($t, '^.+?[.!?](?=\s+[A-Z(`]|$)')
    $s = if ($m.Success) { $m.Value } else { $t }
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max - 1).TrimEnd() + '...' }
    return $s + $since
}

function Get-DefaultText($Resolved) {
    $n = $Resolved.Node
    if ($n -isnot [System.Collections.IDictionary]) { return '' }
    if ($n.Contains('default')) { return ([string]$n['default']).ToLowerInvariant() }
    $d = [string](Get-Val $n 'description')
    $m = [regex]::Match($d, '(?<![A-Za-z])Default(?<for> for [^:]{1,50})?: (?<d>[^.]*(?:\.[A-Za-z0-9_%\\<>`-][^.]*)*)\.(?:\s|$)')
    if ($m.Success) {
        $text = $m.Groups['d'].Value.Trim()
        if ($text.Length -gt 90) { $text = $text.Substring(0, 89).TrimEnd() + '...' }
        return $text
    }
    return ''
}

function ConvertTo-Cell([string]$Text) { return ($Text -replace '\|', '\|' -replace '\s*[\r\n]+\s*', ' ') }

# ---------------------------------------------------------------------------------------------------------------------
# Examples: the first value found for each path in the templates, then the example files
# ---------------------------------------------------------------------------------------------------------------------

$examples = @{}
$secretRefs = [System.Collections.Generic.List[object]]::new()
function Add-ExampleValue($Obj, [string]$Path, [string]$Source) {
    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($k in $Obj.Keys) { Add-ExampleValue $Obj[$k] $(if ($Path) { "$Path.$k" } else { [string]$k }) $Source }
    }
    elseif ($Obj -is [System.Collections.IList]) {
        $scalars = @($Obj | Where-Object { $_ -isnot [System.Collections.IDictionary] -and $_ -isnot [System.Collections.IList] })
        if ($scalars.Count -gt 0 -and $scalars.Count -eq $Obj.Count) {
            if (-not $examples.ContainsKey($Path)) { $examples[$Path] = '[' + (($scalars | ForEach-Object { Format-Scalar $_ }) -join ', ') + ']' }
        } else {
            foreach ($item in $Obj) { Add-ExampleValue $item "$Path[]" $Source }
        }
    }
    elseif ($null -ne $Obj -and "$Obj" -ne '') {
        if (-not $examples.ContainsKey($Path)) { $examples[$Path] = Format-Scalar $Obj }
        if ($Obj -is [string] -and $Obj -match '^keyvault://([^/]+)/(.+)$') {
            $secretRefs.Add([pscustomobject]@{ Path = ($Path -replace '\[\d+\]', '[]'); Vault = $Matches[1]; Secret = $Matches[2]; Source = $Source })
        }
    }
}
function Format-Scalar($Value) {
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    return [string]$Value
}

$templates = [ordered]@{
    full = Join-Path $configDir 'infrastructure.example.yml'
    ztp  = Join-Path $configDir 'infrastructure.ztp.example.yml'
}
foreach ($name in $templates.Keys) {
    if (Test-Path -LiteralPath $templates[$name]) {
        Add-ExampleValue (ConvertFrom-Yaml (Get-Content -LiteralPath $templates[$name] -Raw) -Ordered) '' $name
    }
}
foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $configDir 'examples') -Filter '*.yml' | Sort-Object Name)) {
    $before = $secretRefs.Count
    Add-ExampleValue (ConvertFrom-Yaml (Get-Content -LiteralPath $file.FullName -Raw) -Ordered) '' $file.Name
    while ($secretRefs.Count -gt $before) { $secretRefs.RemoveAt($secretRefs.Count - 1) }   # the secret list is from the two templates only
}

function Get-ExampleText([string]$Path, [bool]$IsMap) {
    $key = $Path
    if ($IsMap) {
        $prefix = $Path.Replace('.<attribute>', '') + '.'
        $first = $examples.Keys | Where-Object { $_.StartsWith($prefix) -and $_.Substring($prefix.Length) -notmatch '[.\[]' } | Sort-Object | Select-Object -First 1
        if (-not $first) { return '' }
        return ('`{0}: {1}`' -f $first.Substring($prefix.Length), $examples[$first])
    }
    if (-not $examples.ContainsKey($key)) { return '' }
    $v = $examples[$key]
    if ($v.Length -gt 56) { $v = $v.Substring(0, 55) + '...' }
    return '`' + ($v -replace '`', "'") + '`'
}

# ---------------------------------------------------------------------------------------------------------------------
# Conditions: what the scenario switches make required, read from the schema
# ---------------------------------------------------------------------------------------------------------------------

$autoConditions = @{}
function Get-ConditionText($If) {
    $parts = @()
    $scenario = Get-Val (Get-Val $If 'properties') 'scenario'
    $props = Get-Val $scenario 'properties'
    if ($props -is [System.Collections.IDictionary]) {
        foreach ($k in $props.Keys) {
            $values = if ($props[$k].Contains('const')) { @($props[$k]['const']) } else { @($props[$k]['enum']) }
            $parts += "scenario.$k is $($values -join ' or ')"
        }
    }
    return ($parts -join ' and ')
}
function Add-ConditionPaths($Then, [string]$Prefix, [string]$Text, [bool]$InZtp) {
    if ($Then -isnot [System.Collections.IDictionary]) { return }
    foreach ($r in @(Get-Val $Then 'required')) {
        $p = "$Prefix$r"
        if (-not $autoConditions.ContainsKey($p)) { $autoConditions[$p] = [pscustomobject]@{ Text = $Text; Ztp = $InZtp } }
    }
    $props = Get-Val $Then 'properties'
    if ($props -is [System.Collections.IDictionary]) {
        foreach ($k in $props.Keys) {
            $child = $props[$k]
            if ($child -isnot [System.Collections.IDictionary]) { continue }
            if ($child['type'] -eq 'array' -and $child.Contains('items')) { Add-ConditionPaths $child['items'] "$Prefix$k[]." $Text $InZtp }
            else { Add-ConditionPaths $child "$Prefix$k." $Text $InZtp }
        }
    }
}
$scopeBranch = $schema['allOf'][0]
foreach ($item in @($scopeBranch['else']['allOf'])) { Add-ConditionPaths $item['then'] '' (Get-ConditionText $item['if']) $false }
foreach ($item in @($schema['allOf'] | Select-Object -Skip 1)) { Add-ConditionPaths $item['then'] '' (Get-ConditionText $item['if']) $true }

# Required keys the scope adds to a section: from the schema's scope branches.
$fullExtra = @{}; $ztpExtra = @{}
foreach ($pair in @(@($scopeBranch['else'], $fullExtra), @($scopeBranch['then'], $ztpExtra))) {
    $props = Get-Val $pair[0] 'properties'
    if ($props -is [System.Collections.IDictionary]) {
        foreach ($sec in $props.Keys) { if ($props[$sec] -is [System.Collections.IDictionary] -and $props[$sec].Contains('required')) { $pair[1][$sec] = @($props[$sec]['required']) } }
    }
}
$fullTop = @($scopeBranch['else']['required']) + @($schema['required'])
$ztpTop = @($scopeBranch['then']['required']) + @($schema['required'])

# ---------------------------------------------------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------------------------------------------------

$rows = [System.Collections.Generic.List[object]]::new()

function Get-RequiredCell([bool]$Required, [bool]$Ancestors, [string]$Path, [string]$Scope) {
    if ($Required) { return $(if ($Ancestors) { 'yes' } else { 'if section is set' }) }
    $manual = if ($meta.Conditions.ContainsKey($Path)) { [string]$meta.Conditions[$Path] } else { $null }
    $auto = if ($autoConditions.ContainsKey($Path)) { $autoConditions[$Path] } else { $null }
    if ($Scope -eq 'ztp') {
        if ($manual -and $Path -match '^nodes\[\]\.(management|network_adapters)') { return "when $manual" }
        if ($auto -and $auto.Ztp -and -not $manual) { return 'yes' }
        if ($auto -and $auto.Ztp -and $manual) { return "when $manual" }
        return 'no'
    }
    if ($manual) { return "when $manual" }
    if ($auto) { return "when $($auto.Text)" }
    return 'no'
}

function Add-Row($Path, $Resolved, [bool]$ReqFull, [bool]$ReqZtp, [bool]$AncFull, [bool]$AncZtp, [bool]$IsMap) {
    $n = $Resolved.Node
    $desc = [string](Get-Val $n 'description')
    $ztp = [bool](@($meta.Ztp | Where-Object { $Path -match $_ }).Count)
    $os = [bool](@($meta.OsConfiguration | Where-Object { $Path -match $_ }).Count)
    $cicd = [bool](@($meta.CicdInfra | Where-Object { $Path -match $_ }).Count)
    $arm = ($desc -cmatch '\bARM\b') -or [bool](@($meta.ArmDeployment | Where-Object { $Path -match $_ }).Count)
    $tw = -not [bool](@($meta.TrailwrightNot | Where-Object { $Path -match $_ }).Count)
    $source = ($meta.Sources | Where-Object { $Path -match $_.Pattern } | Select-Object -First 1)
    $meaning = Get-FirstSentence $desc
    if ($desc -like 'A Key Vault secret reference*') {
        $parts = $Path -split '\.'
        $meaning = "Key Vault reference for the $($parts[-1] -replace '\[\]$', '') of $(if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join '.') } else { 'the file' })."
    }
    $rows.Add([pscustomobject]@{
            Path     = $Path
            Section  = ($Path -split '[.\[]')[0]
            Meaning  = $meaning
            Type     = Get-TypeText $Resolved
            Full     = Get-RequiredCell $ReqFull $AncFull $Path 'full'
            Ztp      = Get-RequiredCell $ReqZtp $AncZtp $Path 'ztp'
            Default  = Get-DefaultText $Resolved
            Example  = Get-ExampleText $Path $IsMap
            Source   = $(if ($source) { $source.Text } else { '' })
            Zt       = $ztp; Os = $os; Arm = $arm; Tw = $tw; Ci = $cicd
            IsSecret = ($Resolved.Ref -eq 'kv_ref')
            Deprecated = ($n -is [System.Collections.IDictionary] -and $n.Contains('deprecated') -and $n['deprecated'] -eq $true)
        })
}

function Invoke-NodeWalk($Resolved, [string]$Path, [bool]$AncFull, [bool]$AncZtp) {
    $n = $Resolved.Node
    if ($n -isnot [System.Collections.IDictionary]) { return }
    $own = @(Get-Val $n 'required')
    $fullReq = if ($Path -eq '') { $fullTop } else { $own + @(if ($fullExtra.ContainsKey($Path)) { $fullExtra[$Path] }) }
    $ztpReq = if ($Path -eq '') { $ztpTop } else { $own + @(if ($ztpExtra.ContainsKey($Path)) { $ztpExtra[$Path] }) }
    $props = Get-Val $n 'properties'
    if ($props -is [System.Collections.IDictionary]) {
        foreach ($k in $props.Keys) {
            $childPath = if ($Path) { "$Path.$k" } else { [string]$k }
            $child = Resolve-Node $props[$k]
            $rf = $fullReq -contains $k
            $rz = $ztpReq -contains $k
            Add-Row $childPath $child $rf $rz $AncFull $AncZtp $false
            Descend $child $childPath ($rf -and $AncFull) ($rz -and $AncZtp)
        }
    }
}

function Descend($Resolved, [string]$Path, [bool]$AncFull, [bool]$AncZtp) {
    $n = $Resolved.Node
    if ($n -isnot [System.Collections.IDictionary]) { return }
    if ($n.Contains('properties')) { Invoke-NodeWalk $Resolved $Path $AncFull $AncZtp; return }
    if ($n['type'] -eq 'array' -and $n.Contains('items')) {
        $items = Resolve-Node $n['items']
        if ($items.Node -is [System.Collections.IDictionary] -and $items.Node.Contains('properties')) { Invoke-NodeWalk $items "$Path[]" $AncFull $AncZtp }
        return
    }
    if ($n['type'] -eq 'object' -and $n.Contains('additionalProperties') -and $n['additionalProperties'] -is [System.Collections.IDictionary]) {
        Add-Row "$Path.<attribute>" (Resolve-Node $n['additionalProperties']) $false $false $AncFull $AncZtp $true
    }
}

Invoke-NodeWalk ([pscustomobject]@{ Node = $schema; Ref = $null }) '' $true $true

# A container is read by whoever reads a key inside it.
foreach ($r in $rows) {
    $inside = @($rows | Where-Object { $_.Path.StartsWith($r.Path + '.') -or $_.Path.StartsWith($r.Path + '[]') })
    if ($inside.Count -gt 0) {
        if ($inside | Where-Object Zt) { $r.Zt = $true }
        if ($inside | Where-Object Os) { $r.Os = $true }
        if ($inside | Where-Object Arm) { $r.Arm = $true }
        if ($inside | Where-Object Ci) { $r.Ci = $true }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The page
# ---------------------------------------------------------------------------------------------------------------------

$sb = [System.Text.StringBuilder]::new()
function Out-Line([string]$Text = '') { [void]$sb.Append($Text).Append("`n") }

$latest = if ($schema['properties']['_metadata']['properties']['schema_version']['description'] -match '(?s).*\b(5\.\d+) adds') { $Matches[1] } else { '5.x' }

Out-Line '# infrastructure.yml variables reference'
Out-Line
Out-Line ('Every key of [`infrastructure.yml`](README.md), schema {0}, one row each, grouped by section. **This page is generated** from [`infrastructure.schema.json`](infrastructure.schema.json), the templates and [`variables-reference.metadata.psd1`](variables-reference.metadata.psd1). Don''t edit it: change those and run:' -f $latest)
Out-Line
Out-Line '```powershell'
Out-Line './scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1'
Out-Line '```'
Out-Line
Out-Line 'A test fails when this page is out of date (`./scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1 -Check`).'
Out-Line
Out-Line '## How to read the tables'
Out-Line
Out-Line '| Column | Meaning |'
Out-Line '| --- | --- |'
Out-Line '| Path | The key. `[]` is an item of a list (`nodes[].name`). |'
Out-Line '| Required: full / ztp | Whether the key must be set in a file with `_metadata.scope: full` (the default) and in one with `scope: ztp`. `yes`: always. `if section is set`: required once its parent exists. `when ...`: required when the condition holds. `no`: optional. |'
Out-Line '| Default | What a tool does when the key is left out (from the schema). |'
Out-Line '| Example | The value in the templates and examples. Placeholders only. |'
Out-Line '| Where to get the value | Where the real value comes from. |'
Out-Line '| Read by | **ZTP**: azurelocal-ztp (the list is what its `ConvertFrom-ZtpInfrastructureV5` reads, plus the 5.3 and 5.4 keys). **OS configuration**: the toolkit''s OS configuration phase (by design, by section). **CI/CD infrastructure**: tasks 01 to 06 of automation / 01-cicd-infra (the `devops` section, plus the Azure identifiers they sign in with). **ARM deployment**: the key becomes a parameter of Microsoft''s ARM deployment template (the schema description names the parameter), or is part of the SAN (`storage.san`, `nodes[].san`) that the ARM and SAN deployment reads. **Trailwright**: it can write the key from its design (host-local paths and files are set by the operator). |'
Out-Line
Out-Line 'Two templates start a file: [`infrastructure.example.yml`](infrastructure.example.yml) (full scope: ZTP, OS configuration and the ARM deployment) and [`infrastructure.ztp.example.yml`](infrastructure.ztp.example.yml) (ztp scope: only what azurelocal-ztp reads). See [Which template](README.md#which-template).'
Out-Line

# Secrets
Out-Line '## Secrets: keyvault:// references'
Out-Line
Out-Line '**No secret value is ever written in the file.** A secret key holds only `keyvault://<vault>/<secret>`: the vault name and the secret name. Create each secret in Key Vault before the run, and list every vault you reference under `key_vaults` (with its subscription and resource group). The validator refuses a plain value (the key must match the reference form) and a reference to an unlisted vault (rule AZL-001). Keep files with real vault names in a private environment repository.'
Out-Line
Out-Line 'The templates expect these secrets. The names are the templates'' placeholders (vault `kv-iic-mgmt-01`); use your own, and match the vault name to a `key_vaults` entry.'
Out-Line
Out-Line '| Path | Vault | Secret | What it holds | In template |'
Out-Line '| --- | --- | --- | --- | --- |'
$seenSecret = [ordered]@{}
$secretPaths = @($rows | Where-Object IsSecret | ForEach-Object Path)
foreach ($ref in ($secretRefs | Sort-Object { [array]::IndexOf($secretPaths, $_.Path) }, Path)) {
    $key = "$($ref.Path)|$($ref.Vault)|$($ref.Secret)"
    if ($seenSecret.Contains($key)) { $seenSecret[$key].In += $ref.Source; continue }
    $row = $rows | Where-Object { $_.Path -eq $ref.Path } | Select-Object -First 1
    $seenSecret[$key] = [pscustomobject]@{ Ref = $ref; Meaning = $(if ($row) { $row.Meaning } else { '' }); In = @($ref.Source) }
}
foreach ($entry in $seenSecret.Values) {
    $r = $entry.Ref
    Out-Line ('| `{0}` | `{1}` | `{2}` | {3} | {4} |' -f $r.Path, $r.Vault, $r.Secret, (ConvertTo-Cell $entry.Meaning), (($entry.In | Select-Object -Unique) -join ', '))
}
Out-Line
Out-Line 'ZTP reads all its secrets from vaults in one subscription (the provisioning admin''s vault decides which). `hardware.bmc.username` may be a reference or the user name itself.'
Out-Line

# Folders
Out-Line '## Folders on the management host'
Out-Line
Out-Line 'Three keys name folders on the machine that runs azurelocal-ztp. **Keep every one outside every git working tree**: they hold ISOs, per-machine images, ownership vouchers, run state and logs, none of which belongs in a repository. azurelocal-ztp refuses `media_path` and `evidence_path` inside a git working tree, and creates them when they are missing. The disk figures are planning estimates; check them against your OEM''s bundle.'
Out-Line
Out-Line '| Path | What it holds | Disk space | Default |'
Out-Line '| --- | --- | --- | --- |'
Out-Line '| `provisioning.simplified.media_path` | The maintenance ISO cache, the copy of the SBE and its unpacked drivers, the per-machine USB images, the ownership vouchers and the run state. | About 4 GB per machine for the images, plus the maintenance ISO and the SBE copy (twice the bundle''s size, as downloaded and unpacked). Plan 30 GB free for a small cluster, on a fast local disk. | `%ProgramData%\AzureLocalZtp\<site_name>\media` |'
Out-Line '| `provisioning.simplified.evidence_path` | The event log the monitors follow (`ztp-events.jsonl`), the BIOS and other Redfish change logs, and run logs. | Small: 1 GB is ample for many runs. Put it where it survives the run, for audit. | `%ProgramData%\AzureLocalZtp\<site_name>\evidence` |'
Out-Line '| `hardware.sbe.bundle_path` | The OEM''s Solution Builder Extension files, as downloaded. Required with simplified provisioning: ZTP prepares each machine with the SBE before validation. | The size of the OEM bundle (a few GB, varies by OEM). ZTP copies it under `media_path`. | none |'
Out-Line

# Sections
Out-Line '## Reference by section'
Out-Line
$topProps = @($schema['properties'].Keys)
foreach ($section in $topProps) {
    $secRows = @($rows | Where-Object Section -eq $section)
    if ($secRows.Count -eq 0) { continue }
    $top = $secRows[0]
    Out-Line "### $section"
    Out-Line
    Out-Line (ConvertTo-Cell $top.Meaning)
    Out-Line
    Out-Line '| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |'
    Out-Line '| --- | --- | --- | --- | --- | --- | --- | --- |'
    foreach ($r in $secRows) {
        $readers = @()
        if ($r.Zt) { $readers += 'ZTP' }
        if ($r.Os) { $readers += 'OS configuration' }
        if ($r.Ci) { $readers += 'CI/CD infrastructure' }
        if ($r.Arm) { $readers += 'ARM deployment' }
        if ($r.Tw) { $readers += 'Trailwright' }
        $meaning = $r.Meaning
        if ($r.Deprecated) { $meaning = "Deprecated. $meaning" }
        $path = '`' + $r.Path + '`'
        if ($r.IsSecret) { $path += ' (secret)' }
        Out-Line ('| {0} | {1} | {2} | {3} / {4} | {5} | {6} | {7} | {8} |' -f $path, (ConvertTo-Cell $meaning), (ConvertTo-Cell $r.Type), (ConvertTo-Cell $r.Full), (ConvertTo-Cell $r.Ztp), (ConvertTo-Cell $(if ($r.Default) { '`' + ($r.Default -replace '`', '') + '`' } else { '' })), (ConvertTo-Cell $r.Example), (ConvertTo-Cell $r.Source), ($readers -join ', '))
    }
    Out-Line
}

$page = $sb.ToString().TrimEnd("`n") + "`n"

if ($Check) {
    if (-not (Test-Path -LiteralPath $OutputPath)) { Write-Error "$OutputPath doesn't exist; run this script without -Check."; exit 1 }
    $current = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $OutputPath)).Replace("`r`n", "`n")
    if ($current -ne $page) {
        Write-Error "$OutputPath is out of date. Run ./scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1 and commit the result."
        exit 1
    }
    Write-Host "$OutputPath is current ($($rows.Count) keys)."
    return
}
[IO.File]::WriteAllText($OutputPath, $page.Replace("`n", "`r`n"))
Write-Host "Wrote $OutputPath ($($rows.Count) keys)."
