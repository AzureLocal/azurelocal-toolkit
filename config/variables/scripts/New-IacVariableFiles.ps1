#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the variable files of the Terraform and Ansible code from infrastructure.yml.

.DESCRIPTION
    The Terraform code (src/terraform) and the Ansible roles (src/ansible) are an alternative route to tasks the PowerShell scripts
    do. They need many of the same facts: names, addresses, subscriptions. Those facts are keys of infrastructure.yml, so the
    code does not define them a second time. This script reads the file and writes the variable files the code reads:

        <OutputDirectory>/terraform/azure-local/terraform.tfvars.json   and backend.hcl
        <OutputDirectory>/terraform/backend/terraform.tfvars.json
        <OutputDirectory>/terraform/cicd-infra/terraform.tfvars.json    and backend.hcl
        <OutputDirectory>/ansible/inventory/group_vars/all.yml
        <OutputDirectory>/ansible/inventory/host_vars/<node>.yml

    The mapping lives in the registry (config/variables/schema/master-registry.yaml): every Terraform variable
    (tools.terraform.variables, tools.cicd_infra.terraform_variables) and every Ansible variable (tools.ansible.variables) has
    class, source, infrastructure_key, form and target. The script reads those entries; it has no name or value of its own.
    class a: the same fact as the key named in infrastructure_key. b: a real choice with no key yet (proposed_key says which).
    c: a setting of the code itself, with its default in the registry; the script writes it only to group_vars. d: belongs to a
    feature that is out of scope. source secret or runtime: never written, see below. form: how the value is shaped (-ListForm).

    A secret is never resolved and never written. A variable whose source is secret or runtime is left out, and the file says how
    the code gets it: a comment in a YAML file, not-written.txt next to a JSON file (an environment variable at run time). A value
    that looks like a secret reference (keyvault://, env://, file://, command://) stops the run with exit code 2.

    The cicd-infra environment is built by ConvertTo-AzlRunnerTerraformVariable (scripts/common/cicd-infra), the function task 06
    uses, so the two cannot differ. The registry entries of that environment name the keys it reads.

    Idempotent. A file whose content is already right is reported as Unchanged. Nothing is deleted. -WhatIf writes nothing.
    The files hold subscription IDs and names: keep OutputDirectory out of git (a warning says so when it is inside a repository).

    Keys read (the keys the registry entries name; print them with -ListKey): azure.*, tags, site.code, key_vaults[], cluster.key_vault.name,
    landing_zone.* (management_groups[], subscriptions[], resource_groups[], networks[], connectivity, virtual_machines[]),
    operations.monitoring.*, operations.notifications.emails, security.defender_for_cloud.security_contact_email, devops.*,
    identity.active_directory.*, networking.management.*, networking.ntp_servers, networking.outbound.*, scenario.outbound_path,
    cluster.name, nodes[].name, nodes[].management.ip_address, nodes[].management.adapter_name.

    Exit codes: 0 every file is written, unchanged or planned under -WhatIf, or there was nothing to write; 1 a precondition failed
    (the registry or a module cannot be read, a file cannot be written); 2 a value in the file is missing or not usable, or the
    file names a secret where a value is needed. Nothing is written when the exit code is 2.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). It is read without validation: only the keys of the registry entries are used.

.PARAMETER OutputDirectory
    Where the files go. Created when missing.

.PARAMETER Target
    What to write: AzureLocal (the azure-local Terraform environment), Backend (the state bootstrap), CicdInfra (the cicd-infra
    environment) and Ansible. Default: all four. A target whose section is not in the file (landing_zone, devops.state, devops) is
    skipped when you did not name it, and is an error (exit 2) when you did.

.PARAMETER RegistryPath
    The registry. Default: config/variables/schema/master-registry.yaml of this repository.

.PARAMETER Registry
    The result of Get-RegistryVariable, to avoid reading the registry again (tests).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file.

.PARAMETER ListForm
    Print the names of the forms the script can apply, then stop.

.PARAMETER ListKey
    Print every key of infrastructure.yml the registry entries name, then stop.

.EXAMPLE
    ./New-IacVariableFiles.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory D:\work\iac -WhatIf

    Shows which files would be written.

.EXAMPLE
    ./New-IacVariableFiles.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory D:\work\iac -Target Ansible

    Writes group_vars/all.yml and host_vars/<node>.yml only.
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Every form is a scriptblock called with the same three arguments (entry, file, context); most forms use some of them.')]
param(
    [string]$InfrastructureFile,
    [string]$OutputDirectory,
    [ValidateSet('AzureLocal', 'Backend', 'CicdInfra', 'Ansible')][string[]]$Target,
    [string]$RegistryPath,
    [object[]]$Registry,
    [string]$LogPath,
    [switch]$ListForm,
    [switch]$ListKey
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

$repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
if (-not $RegistryPath) { $RegistryPath = Join-Path $PSScriptRoot '..\schema\master-registry.yaml' }

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string[]]$Message) { foreach ($m in $Message) { Write-Error $m -ErrorAction Continue }; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# ---------------------------------------------------------------------------------------------------------------------
# Reading a key. A key is a dotted path. A segment may carry a selector: name[] (every item), name[role=hub] (the items whose
# role is hub), name[0] (the first item). The result is every node the path reaches.
# ---------------------------------------------------------------------------------------------------------------------
function Resolve-IacKey {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][string]$Key)
    $nodes = @(, $Infrastructure)
    foreach ($segment in ($Key -split '\.')) {
        if ($segment -notmatch '^([A-Za-z0-9_]+)(\[(.*)\])?$') { throw "The key '$Key' has a segment that is not usable: '$segment'." }
        $name = $Matches[1]; $hasSelector = [bool]$Matches[2]; $selector = $Matches[3]
        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($node in $nodes) {
            if ($node -isnot [System.Collections.IDictionary] -or -not $node.Contains($name) -or $null -eq $node[$name]) { continue }
            $value = $node[$name]
            if (-not $hasSelector) { $next.Add($value); continue }
            if ($value -isnot [System.Collections.IList]) { continue }
            if ($selector -eq '') { foreach ($item in $value) { $next.Add($item) } }
            elseif ($selector -match '^\d+$') { if ([int]$selector -lt $value.Count) { $next.Add($value[[int]$selector]) } }
            elseif ($selector -match '^([A-Za-z0-9_]+)=(.*)$') {
                $field = $Matches[1]; $wanted = $Matches[2]
                foreach ($item in $value) { if ($item -is [System.Collections.IDictionary] -and $item.Contains($field) -and [string]$item[$field] -eq $wanted) { $next.Add($item) } }
            }
            else { throw "The key '$Key' has a selector that is not usable: '[$selector]'." }
        }
        $nodes = $next.ToArray()
        if ($nodes.Count -eq 0) { return [pscustomobject]@{ Found = $false; Values = @() } }
    }
    [pscustomobject]@{ Found = $true; Values = $nodes }
}

function Get-IacText($Value) { if ($null -eq $Value) { '' } else { ([string]$Value).Trim() } }
function Test-Empty($Value) { $null -eq $Value -or ($Value -is [string] -and $Value.Trim() -eq '') -or ($Value -is [System.Collections.IList] -and $Value.Count -eq 0) }

# One value of a key: the node when the key reaches one, the list of nodes when it reaches several.
function Get-KeyValue {
    param($Infrastructure, [string]$Key)
    $r = Resolve-IacKey -Infrastructure $Infrastructure -Key $Key
    if (-not $r.Found) { return [pscustomobject]@{ Found = $false; Value = $null } }
    if ($r.Values.Count -eq 1) { return [pscustomobject]@{ Found = $true; Value = $r.Values[0] } }
    [pscustomobject]@{ Found = $true; Value = @($r.Values) }
}

# ---------------------------------------------------------------------------------------------------------------------
# Forms: how a value is shaped when it is not a plain copy. Each returns Found and Value. The names are in the registry.
# ---------------------------------------------------------------------------------------------------------------------
$script:Forms = [ordered]@{
    # The file names the operating system of a machine as a choice (windows_server_2022, windows_server_2025, ubuntu_2404).
    # Terraform takes the Windows Server image SKU that Microsoft publishes for that choice; a machine that is not Windows gives no value.
    windows_image_sku   = { param($Entry, $Infra, $Ctx) $v = Get-KeyValue $Infra $Entry.Keys[0]; $sku = @{ windows_server_2022 = '2022-datacenter-azure-edition'; windows_server_2025 = '2025-datacenter-azure-edition' }; $name = if ($v.Found) { ([string]$v.Value).Trim().ToLowerInvariant() } else { '' }; if ($sku.ContainsKey($name)) { [pscustomobject]@{ Found = $true; Value = $sku[$name] } } else { [pscustomobject]@{ Found = $false; Value = $null } } }
    lowercase           = { param($Entry, $Infra, $Ctx) $v = Get-KeyValue $Infra $Entry.Keys[0]; if (-not $v.Found -or (Test-Empty $v.Value)) { return [pscustomobject]@{ Found = $false; Value = $null } }; [pscustomobject]@{ Found = $true; Value = ([string]$v.Value).ToLowerInvariant() } }
    present             = { param($Entry, $Infra, $Ctx) $v = Get-KeyValue $Infra $Entry.Keys[0]; [pscustomobject]@{ Found = $true; Value = [bool]($v.Found -and -not (Test-Empty $v.Value)) } }
    first_present       = { param($Entry, $Infra, $Ctx) foreach ($k in $Entry.Keys) { $v = Get-KeyValue $Infra $k; if ($v.Found -and -not (Test-Empty $v.Value)) { return [pscustomobject]@{ Found = $true; Value = $v.Value } } }; [pscustomobject]@{ Found = $false; Value = $null } }
    union_unique        = {
        param($Entry, $Infra, $Ctx)
        $all = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $Entry.Keys) { $v = Get-KeyValue $Infra $k; if ($v.Found) { foreach ($x in @($v.Value)) { $t = Get-IacText $x; if ($t -and -not $all.Contains($t)) { $all.Add($t) } } } }
        [pscustomobject]@{ Found = ($all.Count -gt 0); Value = $all.ToArray() }
    }
    names_map           = {
        param($Entry, $Infra, $Ctx)
        $v = Get-KeyValue $Infra $Entry.Keys[0]
        if (-not $v.Found) { return [pscustomobject]@{ Found = $false; Value = $null } }
        $map = [ordered]@{}
        foreach ($n in @($v.Value)) { $t = Get-IacText $n; if ($t) { $map[$t] = $t } }
        [pscustomobject]@{ Found = ($map.Count -gt 0); Value = $map }
    }
    subnets_map         = {
        param($Entry, $Infra, $Ctx)
        $v = Get-KeyValue $Infra $Entry.Keys[0]
        if (-not $v.Found) { return [pscustomobject]@{ Found = $false; Value = $null } }
        $map = [ordered]@{}
        foreach ($s in @($v.Value)) {
            if ($s -isnot [System.Collections.IDictionary]) { continue }
            $name = Get-IacText $s['name']; $prefix = Get-IacText $s['prefix']
            if (-not $name -or -not $prefix) { $Ctx.Errors.Add("$($Entry.Name): a subnet of $($Entry.Keys[0]) has no name or no prefix."); continue }
            # Azure fixes these two names: the Terraform networking module looks the subnets up by the keys gateway and bastion.
            $key = switch ($name) { 'GatewaySubnet' { 'gateway' } 'AzureBastionSubnet' { 'bastion' } default { $name } }
            $map[$key] = [ordered]@{ name = $name; address_prefix = $prefix }
        }
        [pscustomobject]@{ Found = ($map.Count -gt 0); Value = $map }
    }
    nsg_subnet_map      = {
        param($Entry, $Infra, $Ctx)
        $v = Get-KeyValue $Infra 'landing_zone.networks[role=hub].subnets[]'
        $map = [ordered]@{}
        if ($v.Found) {
            foreach ($s in @($v.Value)) {
                if ($s -isnot [System.Collections.IDictionary]) { continue }
                $nsg = Get-IacText $(if ($s.Contains('network_security_group')) { $s['network_security_group'] }); if (-not $nsg) { continue }
                $name = Get-IacText $s['name']
                $key = switch ($name) { 'GatewaySubnet' { 'gateway' } 'AzureBastionSubnet' { 'bastion' } default { $name } }
                $map[$key] = $nsg
            }
        }
        [pscustomobject]@{ Found = ($map.Count -gt 0); Value = $map }
    }
    managed_identities_map = {
        param($Entry, $Infra, $Ctx)
        $v = Get-KeyValue $Infra 'azure.automation_identity'
        if (-not $v.Found -or $v.Value -isnot [System.Collections.IDictionary]) { return [pscustomobject]@{ Found = $false; Value = $null } }
        $id = $v.Value
        if ((Get-IacText $id['type']) -ne 'managed_identity') { return [pscustomobject]@{ Found = $false; Value = $null } }
        $name = Get-IacText $id['name']; $group = Get-IacText $(if ($id.Contains('resource_group')) { $id['resource_group'] })
        if (-not $name -or -not $group) { return [pscustomobject]@{ Found = $false; Value = $null } }
        [pscustomobject]@{ Found = $true; Value = [ordered]@{ $name = [ordered]@{ name = $name; resource_group = $group } } }
    }
    management_vms_map  = {
        param($Entry, $Infra, $Ctx)
        $v = Get-KeyValue $Infra $Entry.Keys[0]
        if (-not $v.Found) { return [pscustomobject]@{ Found = $false; Value = $null } }
        $map = [ordered]@{}
        $index = -1
        foreach ($vm in @($v.Value)) {
            $index++
            if ($vm -isnot [System.Collections.IDictionary]) { continue }
            if ((Get-IacText $(if ($vm.Contains('deploy_target')) { $vm['deploy_target'] })) -ne 'azure') { continue }
            $item = [ordered]@{}
            foreach ($a in $Ctx.Attributes[$Entry.Name]) {
                if (-not $a.Keys.Count) { continue }
                $field = ($a.Keys[0] -split '\.')[-1] -replace '\[\]', ''
                $value = if ($vm.Contains($field)) { $vm[$field] } else { $null }
                if (Test-Empty $value) {
                    if ($a.Required -eq 'Y') { $Ctx.Errors.Add("landing_zone.virtual_machines[$index].$field is missing ($($a.Name) of $($Entry.Name)).") }
                    continue
                }
                $item[($a.Name -split '\.')[-1]] = $value
            }
            $map[(Get-IacText $vm['name'])] = $item
        }
        [pscustomobject]@{ Found = ($map.Count -gt 0); Value = $map }
    }
    domain_join_username = {
        param($Entry, $Infra, $Ctx)
        $account = Get-KeyValue $Infra $Entry.Keys[0]; $lcm = Get-KeyValue $Infra $Entry.Keys[1]; $netbios = Get-KeyValue $Infra $Entry.Keys[2]
        $user = if ($account.Found -and -not (Test-Empty $account.Value)) { Get-IacText $account.Value } elseif ($lcm.Found) { Get-IacText $lcm.Value } else { '' }
        if (-not $user) { return [pscustomobject]@{ Found = $false; Value = $null } }
        $domain = if ($netbios.Found) { Get-IacText $netbios.Value } else { '' }
        [pscustomobject]@{ Found = $true; Value = $(if ($domain -and $user -notmatch '[\\@]') { "$domain\$user" } else { $user }) }
    }
    proxy_url           = {
        param($Entry, $Infra, $Ctx)
        $path = Get-KeyValue $Infra 'scenario.outbound_path'
        $url = Get-KeyValue $Infra 'networking.outbound.proxy.url'
        $use = $path.Found -and ((Get-IacText $path.Value) -in 'proxy', 'proxy_arc_gateway') -and $url.Found
        [pscustomobject]@{ Found = $true; Value = $(if ($use) { Get-IacText $url.Value } else { '' }) }
    }
    arc_gateway_id      = { param($Entry, $Infra, $Ctx) [pscustomobject]@{ Found = $true; Value = [string](Get-AzlArcGateway -Infrastructure $Infra).Id } }
    scm_url             = { param($Entry, $Infra, $Ctx) try { [pscustomobject]@{ Found = $true; Value = [string](ConvertTo-AzlCicdSetting -Infrastructure $Infra).ScmUrl } } catch { [pscustomobject]@{ Found = $false; Value = $null } } }
    keyvault_vault      = { param($Entry, $Infra, $Ctx) $v = Get-KeyValue $Infra $Entry.Keys[0]; if ($v.Found -and (Get-IacText $v.Value) -match '^keyvault://([^/]+)/') { [pscustomobject]@{ Found = $true; Value = $Matches[1] } } else { [pscustomobject]@{ Found = $false; Value = $null } } }
    keyvault_secret     = { param($Entry, $Infra, $Ctx) $v = Get-KeyValue $Infra $Entry.Keys[0]; if ($v.Found -and (Get-IacText $v.Value) -match '^keyvault://[^/]+/(.+)$') { [pscustomobject]@{ Found = $true; Value = $Matches[1] } } else { [pscustomobject]@{ Found = $false; Value = $null } } }
    cicd_runners        = { param($Entry, $Infra, $Ctx) [pscustomobject]@{ Found = $false; Value = $null } }   # built as a whole by ConvertTo-AzlRunnerTerraformVariable
}

if ($ListForm) { $script:Forms.Keys; exit 0 }

# ---------------------------------------------------------------------------------------------------------------------
# The registry entries
# ---------------------------------------------------------------------------------------------------------------------
Import-Module powershell-yaml -ErrorAction Stop
Import-Module ([IO.Path]::Combine($repoRoot, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
try {
    if (-not $Registry) { $Registry = @(Get-RegistryVariable -Path $RegistryPath) }
}
catch { Exit-Failed "Cannot read the registry $RegistryPath : $($_.Exception.Message)" }

$byPath = @{}
foreach ($r in $Registry) { $byPath[$r.Path] = $r }
$entries = [System.Collections.Generic.List[object]]::new()
foreach ($r in $Registry) {
    if ($r.Path -notmatch '^tools\.(terraform\.variables|ansible\.variables|cicd_infra\.terraform_variables|cicd_infra\.ansible_variables)\.[^.]+\.[^.]+$') { continue }
    $n = $r.Node
    if ($n -isnot [System.Collections.IDictionary] -or -not $n.Contains('name') -or -not $n.Contains('class')) { continue }
    $group = $byPath[$r.Path.Substring(0, $r.Path.LastIndexOf('.'))]
    $area = if ($group -and $group.Node.Contains('area')) { [string]$group.Node['area'] } else { '' }
    $keys = @(if ($n.Contains('infrastructure_key')) { @($n['infrastructure_key']) | ForEach-Object { [string]$_ } })
    $entries.Add([pscustomobject]@{
            Path = $r.Path; Area = $area; Name = [string]$n['name']; Class = [string]$n['class']; Source = [string]$n['source']
            Keys = $keys; Form = $(if ($n.Contains('form')) { [string]$n['form'] } else { '' })
            Target = $(if ($n.Contains('target')) { [string]$n['target'] } else { '' })
            Required = $(if ($n.Contains('required')) { [string]$n['required'] } else { 'N' })
            HasDefault = $n.Contains('default'); Default = $(if ($n.Contains('default')) { $n['default'] } else { $null }); Type = [string]$n['type']
            Note = $(if ($n.Contains('note')) { [string]$n['note'] } else { '' })
        })
}

if ($ListKey) {
    $entries | ForEach-Object { $_.Keys } | ForEach-Object { ($_ -replace '\[[^\]]*\]', '[]') -replace '\[\]$', '' } | Sort-Object -Unique
    exit 0
}

if (-not $InfrastructureFile) { Exit-InputProblem 'InfrastructureFile is required.' }
if (-not $OutputDirectory) { Exit-InputProblem 'OutputDirectory is required.' }

$modules = [IO.Path]::Combine($repoRoot, 'scripts', 'common')
try {
    Import-Module ([IO.Path]::Combine($modules, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($modules, 'cicd-infra', 'AzlCicdInfra.psm1')) -Force
}
catch { Exit-Failed "Cannot load a toolkit module: $($_.Exception.Message)" }

try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$explicit = [bool]$Target
if (-not $Target) { $Target = 'AzureLocal', 'Backend', 'CicdInfra', 'Ansible' }

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$probe = $outputRoot
while ($probe) {
    if (Test-Path -LiteralPath (Join-Path $probe '.git')) { Write-Warning "OutputDirectory is inside the repository $probe. The files hold subscription IDs and names: keep them out of git."; break }
    $parent = Split-Path -Path $probe -Parent
    if ($parent -eq $probe) { break }
    $probe = $parent
}

# ---------------------------------------------------------------------------------------------------------------------
# Building values
# ---------------------------------------------------------------------------------------------------------------------
$ctx = [pscustomobject]@{ Errors = [System.Collections.Generic.List[string]]::new(); Attributes = @{} }

function Get-EntryValue {
    # The value of one entry: Found, Value. A class a or b entry with no key and no form has no value of its own.
    param($Entry)
    if ($Entry.Form -and $Entry.Form -ne 'cicd_runners') {
        if (-not $script:Forms.Contains($Entry.Form)) { $ctx.Errors.Add("$($Entry.Name): the form '$($Entry.Form)' is not known to this script."); return [pscustomobject]@{ Found = $false; Value = $null } }
        return & $script:Forms[$Entry.Form] $Entry $infra $ctx
    }
    if ($Entry.Keys.Count -ge 1) { return Get-KeyValue $infra $Entry.Keys[0] }
    [pscustomobject]@{ Found = $false; Value = $null }
}

function ConvertTo-PlainData($Value) {
    # JSON and YAML writers get plain dictionaries, lists and scalars.
    if ($Value -is [System.Collections.IDictionary]) { $o = [ordered]@{}; foreach ($k in $Value.Keys) { $o[[string]$k] = ConvertTo-PlainData $Value[$k] }; return $o }
    if ($Value -is [System.Collections.IList]) { return , @($Value | ForEach-Object { ConvertTo-PlainData $_ }) }
    $Value
}

function Get-AttributePath([string]$Name) { $s = @($Name -split '\.'); if ($s.Count -gt 1) { @($s[1..($s.Count - 1)]) } else { @() } }

function Build-Variable {
    # The variables of one group of entries (one variables.tf, or group_vars): an ordered map name -> value.
    param([object[]]$GroupEntries, [string]$Kind)
    $result = [ordered]@{}
    $roots = @($GroupEntries | Where-Object { $_.Name -notmatch '\.' -and $_.Target -eq $Kind })
    foreach ($e in $roots) {
        if ($e.Source -in 'secret', 'runtime') { continue }
        $attrs = @($GroupEntries | Where-Object { $_.Name.StartsWith("$($e.Name).") -and $_.Target -eq $Kind -and $_.Source -notin 'secret', 'runtime' })
        $ctx.Attributes[$e.Name] = @($GroupEntries | Where-Object { $_.Name.StartsWith("$($e.Name).") })
        $found = $false; $value = $null
        if ($e.Form) { $r = Get-EntryValue $e; $found = $r.Found; $value = $r.Value }
        elseif ($attrs.Count -gt 0) {
            $obj = [ordered]@{}
            $pending = [System.Collections.Generic.List[string]]::new()
            foreach ($a in $attrs) {
                if ($a.Source -eq 'tool') { if ($Kind -eq 'group_vars' -and $a.HasDefault) { $parts = @(Get-AttributePath $a.Name); $cursor = $obj; for ($i = 0; $i -lt $parts.Count - 1; $i++) { if (-not $cursor.Contains($parts[$i])) { $cursor[$parts[$i]] = [ordered]@{} }; $cursor = $cursor[$parts[$i]] }; $cursor[$parts[-1]] = $a.Default; $found = $true }; continue }
                $r = Get-EntryValue $a
                if (-not $r.Found -or ((Test-Empty $r.Value) -and $r.Value -isnot [bool])) {
                    if ($a.Required -eq 'Y') { $pending.Add("$($a.Name): $(($a.Keys -join ', ')) is missing or empty in the file.") }
                    continue
                }
                $parts = @(Get-AttributePath $a.Name)
                $cursor = $obj
                for ($i = 0; $i -lt $parts.Count - 1; $i++) { if (-not $cursor.Contains($parts[$i])) { $cursor[$parts[$i]] = [ordered]@{} }; $cursor = $cursor[$parts[$i]] }
                $cursor[$parts[-1]] = $r.Value
                $found = $true
            }
            if ($found) { $value = $obj }
            # An optional object (VPN, Bastion) that has no value at all is left out; a required one (or one with some values) reports what is missing.
            if ($found -or $e.Required -eq 'Y') { foreach ($m in $pending) { $ctx.Errors.Add($m) } }
        }
        elseif ($e.Source -eq 'infrastructure') { $r = Get-EntryValue $e; $found = $r.Found; $value = $r.Value }
        elseif ($e.Source -eq 'tool' -and $Kind -eq 'group_vars' -and $e.HasDefault) { $found = $true; $value = $e.Default }
        $empty = (-not $found) -or ((Test-Empty $value) -and $value -isnot [bool] -and -not ($e.Form -in 'proxy_url', 'arc_gateway_id') )
        if ($empty) {
            if ($e.Required -eq 'Y' -and $e.Source -eq 'infrastructure') { $ctx.Errors.Add("$($e.Name): $(if ($e.Keys.Count) { $e.Keys -join ', ' } else { 'its form' }) is missing or empty in the file.") }
            continue
        }
        $result[$e.Name] = ConvertTo-PlainData $value
    }
    $result
}

function Get-NotWritten {
    param([object[]]$GroupEntries, [string]$Kind)
    foreach ($e in @($GroupEntries | Where-Object { $_.Name -notmatch '\.' -and $_.Target -eq $Kind -and $_.Source -in 'secret', 'runtime' })) {
        $how = if ($e.Note) { $e.Note } else { 'Pass it at run time.' }
        $from = if ($e.Keys.Count) { " The file holds the reference at $($e.Keys -join ' or ')." } else { '' }
        "$($e.Name): not written.$from $how"
    }
}

function Test-SecretReference($Value, [string]$Where) {
    if ($Value -is [System.Collections.IDictionary]) { foreach ($k in $Value.Keys) { Test-SecretReference $Value[$k] "$Where.$k" }; return }
    if ($Value -is [System.Collections.IList]) { $i = 0; foreach ($x in $Value) { Test-SecretReference $x "$Where[$i]"; $i++ }; return }
    if ($Value -is [string] -and $Value -match '^(keyvault|env|file|command)://') { $ctx.Errors.Add("${Where}: the file holds a secret reference where a value is needed ('$($Value.Substring(0, $Value.IndexOf('://') + 3))...'). A secret is never written to a variable file.") }
}

# ---- the plan: files and their text
$files = [System.Collections.Generic.List[object]]::new()   # Target, Path, Text
function Add-File([string]$TargetName, [string]$RelativePath, [string]$Text) { $files.Add([pscustomobject]@{ Target = $TargetName; Path = (Join-Path $outputRoot $RelativePath); Text = $Text }) }

function ConvertTo-JsonText($Data) { (($Data | ConvertTo-Json -Depth 20) -replace "`r`n", "`n").TrimEnd() + "`n" }

function ConvertTo-HclValue($Value) {
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    '"' + (([string]$Value) -replace '\\', '\\' -replace '"', '\"') + '"'
}

$skipped = [System.Collections.Generic.List[string]]::new()

function Test-Section([string]$Key) { $v = Get-KeyValue $infra $Key; $v.Found -and -not (Test-Empty $v.Value) }

function Add-BackendHcl([string]$TargetName, [string]$AreaSuffix, [string]$Folder) {
    $group = @($entries | Where-Object { $_.Area -like "*$AreaSuffix" -and $_.Target -eq 'backend_hcl' })
    if ($group.Count -eq 0) { return }
    if (-not (Test-Section 'devops.state.storage_account')) { $skipped.Add("${Folder}/backend.hcl: devops.state.storage_account is not in the file."); return }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Written by config/variables/scripts/New-IacVariableFiles.ps1 from devops.state of infrastructure.yml. Do not edit.")
    $lines.Add('# terraform init -backend-config=backend.hcl')
    foreach ($e in $group) {
        $name = $e.Name -replace '^backend\.', ''
        $value = $null; $have = $false
        if ($e.Source -eq 'infrastructure') { $r = Get-EntryValue $e; if ($r.Found -and -not (Test-Empty $r.Value)) { $value = $r.Value; $have = $true } }
        if (-not $have -and $e.HasDefault) { $value = if ($e.Type -eq 'boolean') { $e.Default -eq 'true' } else { $e.Default }; $have = $true }
        if (-not $have) { $ctx.Errors.Add("$($e.Name): $($e.Keys -join ', ') is missing or empty in the file."); continue }
        if ($e.Type -eq 'boolean' -and $value -isnot [bool]) { $value = ([string]$value) -eq 'true' }
        Test-SecretReference $value $e.Name
        $lines.Add("$name = $(ConvertTo-HclValue $value)")
    }
    Add-File $TargetName "terraform/$Folder/backend.hcl" ((($lines -join "`n") + "`n"))
}

function Add-TerraformEnvironment([string]$TargetName, [string]$AreaSuffix, [string]$Folder) {
    $group = @($entries | Where-Object { $_.Area -like "*$AreaSuffix" })
    $vars = Build-Variable -GroupEntries $group -Kind 'tfvars'
    Test-SecretReference $vars 'tfvars'
    Add-File $TargetName "terraform/$Folder/terraform.tfvars.json" (ConvertTo-JsonText $vars)
    $nw = @(Get-NotWritten -GroupEntries $group -Kind 'tfvars')
    if ($nw.Count) { Add-File $TargetName "terraform/$Folder/not-written.txt" ((($nw -join "`n") + "`n")) }
}

foreach ($t in $Target) {
    switch ($t) {
        'AzureLocal' {
            if (-not (Test-Section 'landing_zone')) { if ($explicit) { $ctx.Errors.Add('AzureLocal: the file has no landing_zone section.') } else { $skipped.Add('AzureLocal: the file has no landing_zone section.') }; continue }
            Add-TerraformEnvironment 'AzureLocal' 'environments/azure-local/variables.tf' 'azure-local'
            Add-BackendHcl 'AzureLocal' 'environments/azure-local/backend.hcl' 'azure-local'
        }
        'Backend' {
            if (-not (Test-Section 'devops.state')) { if ($explicit) { $ctx.Errors.Add('Backend: the file has no devops.state section.') } else { $skipped.Add('Backend: the file has no devops.state section.') }; continue }
            Add-TerraformEnvironment 'Backend' 'backend/variables.tf' 'backend'
        }
        'CicdInfra' {
            if (-not (Test-Section 'devops')) { if ($explicit) { $ctx.Errors.Add('CicdInfra: the file has no devops section.') } else { $skipped.Add('CicdInfra: the file has no devops section.') }; continue }
            try {
                $settings = ConvertTo-AzlCicdSetting -Infrastructure $infra
                $vars = ConvertTo-AzlRunnerTerraformVariable -Settings $settings -AdminSshPublicKey ''
            }
            catch { $ctx.Errors.Add("CicdInfra: $($_.Exception.Message)"); continue }
            $group = @($entries | Where-Object { $_.Area -like '*environments/cicd-infra/variables.tf' })
            $declared = @($group | Where-Object { $_.Name -notmatch '\.' } | ForEach-Object { $_.Name })
            $out = [ordered]@{}
            foreach ($k in $vars.Keys) {
                if ($k -eq 'admin_ssh_public_key') { continue }
                if ($k -notin $declared) { $ctx.Errors.Add("CicdInfra: ConvertTo-AzlRunnerTerraformVariable gives '$k', which the registry does not list for environments/cicd-infra."); continue }
                $out[$k] = ConvertTo-PlainData $vars[$k]
            }
            Test-SecretReference $out 'tfvars'
            Add-File 'CicdInfra' 'terraform/cicd-infra/terraform.tfvars.json' (ConvertTo-JsonText $out)
            $nw = @(Get-NotWritten -GroupEntries $group -Kind 'tfvars')
            if ($nw.Count) { Add-File 'CicdInfra' 'terraform/cicd-infra/not-written.txt' ((($nw -join "`n") + "`n")) }
            Add-BackendHcl 'CicdInfra' 'environments/cicd-infra/backend.hcl.example' 'cicd-infra'
        }
        'Ansible' {
            $group = @($entries | Where-Object { $_.Area -like 'src/ansible/*' })
            $vars = Build-Variable -GroupEntries $group -Kind 'group_vars'
            Test-SecretReference $vars 'group_vars'
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.Append("# =============================================================================`n# Ansible group variables, written by config/variables/scripts/New-IacVariableFiles.ps1 from`n# infrastructure.yml. Do not edit: change the file and write this one again.`n# No secret is in this file. The variables named at the end are passed at run time.`n# =============================================================================`n`n")
            foreach ($k in $vars.Keys) {
                $one = [ordered]@{ $k = $vars[$k] }
                [void]$sb.Append((ConvertTo-Yaml $one).TrimEnd() + "`n")
            }
            $nw = @(Get-NotWritten -GroupEntries $group -Kind 'group_vars')
            if ($nw.Count) { [void]$sb.Append("`n"); foreach ($l in $nw) { [void]$sb.Append("# $l`n") } }
            Add-File 'Ansible' 'ansible/inventory/group_vars/all.yml' $sb.ToString()
            # host_vars: one file for each node
            $hostEntries = @($group | Where-Object { $_.Target -eq 'host_vars' })
            $nodes = Get-KeyValue $infra 'nodes'
            if ($hostEntries.Count -and $nodes.Found) {
                $seen = @{}
                $index = -1
                foreach ($node in @($nodes.Value)) {
                    $index++
                    if ($node -isnot [System.Collections.IDictionary]) { continue }
                    $nodeName = Get-IacText $node['name']
                    if ($nodeName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $ctx.Errors.Add("nodes[$index].name '$nodeName' is missing or is not usable as a host name."); continue }
                    if ($seen.ContainsKey($nodeName.ToLowerInvariant())) { $ctx.Errors.Add("nodes[$index].name '$nodeName' is listed twice."); continue }
                    $seen[$nodeName.ToLowerInvariant()] = $true
                    $hv = [ordered]@{}
                    foreach ($h in $hostEntries) {
                        $field = ($h.Keys[0] -split '\.')[-1]
                        $inner = $node
                        foreach ($seg in @(($h.Keys[0] -replace '^nodes\[\]\.', '') -split '\.')) { if ($inner -is [System.Collections.IDictionary] -and $inner.Contains($seg)) { $inner = $inner[$seg] } else { $inner = $null; break } }
                        if (Test-Empty $inner) { if ($h.Required -eq 'Y') { $ctx.Errors.Add("nodes[$index].$($h.Keys[0] -replace '^nodes\[\]\.', '') is missing."); }; continue }
                        $hv[$h.Name] = $inner
                    }
                    $text = "# Written by config/variables/scripts/New-IacVariableFiles.ps1 from nodes[] of infrastructure.yml. Do not edit.`n"
                    if ($hv.Count) { $text += (ConvertTo-Yaml $hv).TrimEnd() + "`n" } else { $text += "{}`n" }
                    Add-File 'Ansible' "ansible/inventory/host_vars/$nodeName.yml" $text
                }
            }
        }
    }
}

if ($ctx.Errors.Count -gt 0) { Exit-InputProblem @($ctx.Errors | Select-Object -Unique) }

# ---- write
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($s in $skipped) { Write-Line "Skipped: $s" }
try {
    foreach ($f in $files) {
        $text = $f.Text.Replace("`r`n", "`n")
        $existing = if (Test-Path -LiteralPath $f.Path -PathType Leaf) { [IO.File]::ReadAllText($f.Path).Replace("`r`n", "`n") } else { $null }
        if ($null -ne $existing -and $existing -ceq $text) { $action = 'Unchanged' }
        elseif ($PSCmdlet.ShouldProcess($f.Path, 'Write')) {
            New-Item -ItemType Directory -Path (Split-Path -Path $f.Path -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($f.Path, $text, [Text.UTF8Encoding]::new($false))
            $action = if ($null -eq $existing) { 'Written' } else { 'Updated' }
        }
        else { $action = 'Planned' }
        $rows.Add([pscustomobject]@{ Target = $f.Target; File = $f.Path; Action = $action })
        Write-Line "[$($action.ToLowerInvariant())] $($f.Path)"
    }
}
catch { Exit-Failed "Cannot write a file: $($_.Exception.Message)" }

if ($rows.Count -eq 0) { Write-Line 'Nothing to write.' }
$rows
exit 0
