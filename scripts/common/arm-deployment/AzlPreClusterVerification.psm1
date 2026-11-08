#Requires -Version 7.0
<#
.SYNOPSIS
    The pre-cluster verification gate: everything Microsoft Learn (view azloc-2610) and the azurelocal.cloud documentation list as a
    prerequisite of an Azure Local deployment, checked read only before the ARM Validate, so that an ARM Validate never fails for
    something the toolkit could have caught.

.DESCRIPTION
    A stage of its own between the OS configuration and the cluster ARM Validate. The catalog has six categories (azure, identity,
    nodes, network, storage, readiness); docs/pre-cluster-verification.md lists every check with the Learn page it comes from.

    Modes
      Plan    Offline. Lists what would be checked and what each check reads. Writes plan.json and plan.md. Never a result the ARM run accepts.
      Verify  Runs the checks read only against Azure (ARM REST), Active Directory (LDAP, with the LCM credential from Key Vault)
              and the nodes (WinRM, the same transport and payloads as the OS configuration). Writes report.json, summary.md and
              precluster-verification-events.jsonl. Default: nothing is changed anywhere. -Fix (opt in) applies the safe fixes, which
              are Azure side only: registering the mandatory resource providers that are not registered.

    A check ends as Passed, Failed, Warning, Skipped, NotApplicable or Fixed. Skipped is its own state and BLOCKS the verdict unless
    the operator accepts that check id with -AcceptSkipped; a check that could not run is never read as fine.

    Everything that touches Azure, Active Directory, DNS or a node goes through the ADAPTER (New-AzlPclAdapter): a table of
    scriptblocks, built on the ARM run's adapter (New-AzlArmAzureAdapter). Tests pass a fake adapter, so no test needs Azure, a
    domain controller or a node. Nothing runs at import.

    The contract with the ARM run (where the result is, when it counts) is in AzlPreClusterGate.psm1.

    Exit codes: 0 Plan done, or Verify with the verdict Pass; 1 Verify with the verdict Fail; 2 bad input.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Here = $PSScriptRoot
$script:Common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
Import-Module ([IO.Path]::Combine($script:Common, 'infrastructure', 'AzlInfrastructure.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($script:Here, 'AzlArmDeployment.psm1'))
Import-Module ([IO.Path]::Combine($script:Here, 'AzlArmDeploymentRun.psm1'))
Import-Module ([IO.Path]::Combine($script:Here, 'AzlPreClusterGate.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'node-configuration', 'AzlNodeConfiguration.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'node-configuration', 'AzlNodePayload.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'node-configuration', 'AzlNodeTransport.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'node-configuration', 'AzlRemoting.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'node-configuration', 'AzlDomainJoin.psm1'))

$script:Learn = 'https://learn.microsoft.com/en-us/azure/azure-local'
$script:View = 'view=azloc-2610'
$script:Docs = 'https://azurelocal.cloud/docs/implementation'
$script:Secrets = [System.Collections.Generic.List[string]]::new()
$script:Catalog = [System.Collections.Generic.List[object]]::new()
$script:Statuses = @('Passed', 'Failed', 'Warning', 'Skipped', 'NotApplicable', 'Fixed')

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlPclList([AllowNull()][object]$Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) { return @($Value) }
    return @($Value)
}

function Test-AzlPclFilled([AllowNull()][object]$Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return -not [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Count -gt 0 }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value).Count -gt 0 }
    return $true
}

function Register-AzlPclSecret([AllowNull()][string]$Value) {
    if ($Value -and $Value.Length -ge 3 -and -not $script:Secrets.Contains($Value)) { $script:Secrets.Add($Value) }
}

function Hide-AzlPclSecret {
    <#
    .SYNOPSIS
        The text with every secret value this run read replaced by ***.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $out = $Text
    foreach ($s in $script:Secrets) { $out = $out.Replace($s, '***') }
    return $out
}

function Format-AzlPclShort([string]$Id) {
    if ($Id -match '^[0-9a-fA-F]{8}-') { return $Id.Substring(0, 8) + '...' }
    return $Id
}

function Join-AzlPclList([AllowNull()][object[]]$Item) {
    $list = @($Item | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [string]$_ })
    if ($list.Count -le 1) { return ($list -join '') }
    return (($list | Select-Object -SkipLast 1) -join ', ') + ' and ' + $list[-1]
}

function New-AzlPclResult {
    <#
    .SYNOPSIS
        One result of a check: Status, Message, Remedy (with the exact command), Node ('*' when it is not about one node) and Details.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object; changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('Passed', 'Failed', 'Warning', 'Skipped', 'NotApplicable', 'Fixed')][string]$Status,
        [Parameter(Mandatory, Position = 1)][string]$Message,
        [Parameter(Position = 2)][string]$Remedy = '',
        [string]$Node = '*',
        [object[]]$Details = @()
    )
    [pscustomobject]@{ Status = $Status; Message = $Message; Remedy = $Remedy; Node = $Node; Details = @($Details) }
}

function Stop-AzlPclSkip {
    <#
    .SYNOPSIS
        Ends the check as Skipped, with the reason. A Skipped check blocks the verdict unless the operator accepts it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Throws a control-flow exception; changes no system state.')]
    param([Parameter(Mandatory)][string]$Reason, [string]$Remedy = '')
    $e = [System.InvalidOperationException]::new($Reason)
    $e.Data['AzlSkip'] = $true
    $e.Data['AzlRemedy'] = $Remedy
    throw $e
}

function Stop-AzlPclInput {
    <#
    .SYNOPSIS
        Bad input: the run ends with exit code 2.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Throws a control-flow exception; changes no system state.')]
    param([Parameter(Mandatory)][string]$Message)
    $e = [System.ArgumentException]::new($Message)
    $e.Data['AzlExit'] = 2
    throw $e
}
function Register-AzlPclCheck {
    <#
    .SYNOPSIS
        Adds a check to the catalog. Applies returns $true, or a string: why the check does not apply (NotApplicable).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Adds to the in-memory catalog; changes no system state.')]
    param(
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][ValidateSet('azure', 'identity', 'nodes', 'network', 'storage', 'readiness')][string]$Category,
        [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Reads,
        [Parameter(Mandatory)][scriptblock]$Run, [scriptblock]$Applies = { $true }, [bool]$Blocking = $true, [switch]$Fixable
    )
    if (@($script:Catalog | Where-Object { $_.Id -eq $Id }).Count) { throw "Check $Id is registered twice." }
    $script:Catalog.Add([pscustomobject]@{ Id = $Id; Category = $Category; Title = $Title; Source = $Source; Reads = $Reads; Blocking = $Blocking; Fixable = [bool]$Fixable; Applies = $Applies; Run = $Run })
}

function Get-AzlPclCatalog {
    <#
    .SYNOPSIS
        The check catalog: Id, Category, Title, Source (Learn or azurelocal.cloud page), Reads (what the check talks to), Blocking
        (whether a Failed or an unaccepted Skipped result blocks the verdict) and Fixable (-Fix can repair it).
    #>
    [CmdletBinding()]
    param([string[]]$Category, [string]$ExtensionFolder)
    $definitions = if ($PSBoundParameters.ContainsKey('ExtensionFolder')) { Get-AzlPclDefinitionSet (Import-AzlPclExtension -Folder $ExtensionFolder) } else { @($script:Catalog) }
    @($definitions | Where-Object { -not $Category -or $_.Category -in $Category } | ForEach-Object {
            [pscustomobject]@{ Id = $_.Id; Category = $_.Category; Title = $_.Title; Source = $_.Source; Reads = $_.Reads; Blocking = $_.Blocking; Fixable = $_.Fixable }
        })
}

# ---------------------------------------------------------------------------------------------------------------------
# The adapter
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlPclAdapter {
    <#
    .SYNOPSIS
        The table of scriptblocks that touch Azure, Active Directory, DNS, a node or the clock. Tests replace members with fakes.
    .DESCRIPTION
        Starts from the ARM run's adapter (New-AzlArmAzureAdapter: Now, Sleep, GetContext, GetResourceGroup, GetProviderState,
        RegisterProvider, GetPermission, TestNameAvailable, TestSecret, GetSecret, GetHciResourceProviderObjectId, GetArcMachine,
        GetDeploymentState) and adds: GetSubscription, GetCallerRoles, ListRoleAssignments, ListArcExtensions, FindArcMachines,
        GetArcGateway, LdapSearch, ResolveDns, ReadNode, EnvChecker. Everything is a read, except RegisterProvider, which only
        -Fix reaches. A member that is $null is "not available here": the check that needs it is Skipped with that reason.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table; changes no system state.')]
    [CmdletBinding()]
    param()
    $a = New-AzlArmAzureAdapter
    $a['GetSubscription'] = {
        param($Subscription)
        $r = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription" -ApiVersion '2022-12-01' -AllowNotFound
        if ($r) { [pscustomobject]@{ State = [string](Get-AzlProp $r 'state' ''); TenantId = [string](Get-AzlProp $r 'tenantId' ''); DisplayName = [string](Get-AzlProp $r 'displayName' '') } }
    }
    $a['GetCallerRoles'] = {
        param($Scope)
        # The roles the signed-in principal holds at the scope and above, including those it holds through a group.
        $c = Get-AzContext
        if ([string]$c.Account.Type -eq 'User') { $found = Get-AzRoleAssignment -Scope $Scope -SignInName ([string]$c.Account.Id) -ExpandPrincipalGroups }
        else { $sp = Get-AzADServicePrincipal -ApplicationId ([string]$c.Account.Id); $found = Get-AzRoleAssignment -Scope $Scope -ObjectId $sp.Id -ExpandPrincipalGroups }
        @($found | ForEach-Object { [pscustomobject]@{ Role = [string]$_.RoleDefinitionName; Scope = [string]$_.Scope } })
    }
    $a['ListRoleAssignments'] = {
        param($Scope)
        # ObjectType Unknown is the portal's "Identity not found": a role assignment whose principal was deleted.
        @(Get-AzRoleAssignment -Scope $Scope | Where-Object { [string]$_.Scope -eq $Scope } | ForEach-Object {
                [pscustomobject]@{ Role = [string]$_.RoleDefinitionName; PrincipalId = [string]$_.ObjectId; PrincipalType = [string]$_.ObjectType; DisplayName = [string]$_.DisplayName; Scope = [string]$_.Scope }
            })
    }
    $a['ListArcExtensions'] = {
        param($ResourceId)
        $r = Invoke-AzlArm -Method GET -Path "$ResourceId/extensions" -ApiVersion '2024-07-10' -AllowNotFound
        @(Get-AzlProp $r 'value' @() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Type = [string](Get-AzlProp $_ 'properties.type' '') } })
    }
    $a['FindArcMachines'] = {
        param($Subscription, $Name)
        # Arc machines of the subscription with this name or host name, in any resource group.
        $r = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/providers/Microsoft.HybridCompute/machines" -ApiVersion '2024-07-10'
        @(Get-AzlProp $r 'value' @() | Where-Object { ([string]$_.name -ieq $Name) -or ([string](Get-AzlProp $_ 'properties.osProfile.computerName' '') -ieq $Name) } | ForEach-Object {
                $id = [string]$_.id
                [pscustomobject]@{ Name = [string]$_.name; ResourceId = $id; ResourceGroup = $(if ($id -match '/resourceGroups/(?<g>[^/]+)/') { $Matches.g } else { '' }); Status = [string](Get-AzlProp $_ 'properties.status' '') }
            })
    }
    $a['GetArcGateway'] = {
        param($Subscription, $ResourceGroup, $Name)
        $r = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/gateways/$Name" -ApiVersion '2024-07-31-preview' -AllowNotFound
        if ($r) { [pscustomobject]@{ Name = [string](Get-AzlProp $r 'name' $Name); ProvisioningState = [string](Get-AzlProp $r 'properties.provisioningState' '') } }
    }
    $a['LdapSearch'] = { param($Request) Invoke-DjLdapSearch -Request $Request }
    $a['ResolveDns'] = {
        param($Name, $Server)
        # Address records of a name asked of one DNS server. Ok is false when the server did not answer; Addresses is empty when it has no record.
        if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { return $null }
        try { [pscustomobject]@{ Ok = $true; Addresses = @(Resolve-DnsName -Name $Name -Server $Server -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress }); Error = '' } }
        catch {
            $text = $_.Exception.Message
            $missing = $text -match 'DNS name does not exist|DNS_ERROR_RCODE_NAME_ERROR|No such host|does not exist'
            [pscustomobject]@{ Ok = [bool]$missing; Addresses = @(); Error = $text }
        }
    }
    $a['ReadNode'] = { param($Request) Invoke-AzlPclReadNode -Request $Request }
    $a['EnvChecker'] = { param($Request) Invoke-AzlPclEnvironmentChecker -Request $Request }
    return $a
}

# ---------------------------------------------------------------------------------------------------------------------
# Verification modules: scripts/common/arm-deployment/verification/AzlVerification.*.psm1
# ---------------------------------------------------------------------------------------------------------------------

$script:CategoryNames = @('azure', 'identity', 'nodes', 'network', 'storage', 'readiness')

function Get-AzlPclExtensionFolder {
    <#
    .SYNOPSIS
        The folder whose AzlVerification.*.psm1 modules add checks to the gate: scripts/common/arm-deployment/verification.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [IO.Path]::Combine($script:Here, 'verification')
}

function Get-AzlPclContextTable {
    # The $Context a verification module's Applies and Run receive: a hashtable (so both $Context.X and $Context['X'] work).
    param([Parameter(Mandatory)]$Ctx)
    if (-not $Ctx.Cache.ContainsKey('ExtContext')) {
        $Ctx.Cache['ExtContext'] = @{
            Infrastructure = $Ctx.Infra; Handoff = $Ctx.Handoff; OsReport = $Ctx.OsReport; Settings = $Ctx.Settings; Adapters = $Ctx.Adapter
            Cluster = $Ctx.Cluster; Nodes = $Ctx.Nodes; Subscription = $Ctx.Subscription; ResourceGroup = $Ctx.ResourceGroup; Identity = $Ctx.Identity; Architecture = $Ctx.Architecture
            Fix = [bool]$Ctx.Fix; Mode = $Ctx.Mode; Cache = $Ctx.Cache
        }
    }
    return $Ctx.Cache['ExtContext']
}

function ConvertTo-AzlPclDefinition {
    <#
    .SYNOPSIS
        A check definition of a verification module ({Id, Category, Title, Source, Blocking, Applies, Run}, as a hashtable or an object) as a
        catalog entry. A definition that is not usable becomes a check that fails with the reason, so a broken module is never silent.
    #>
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$Module)
    $get = {
        param($Name, $Default)
        if ($Definition -is [System.Collections.IDictionary]) { if ($Definition.Contains($Name)) { return $Definition[$Name] } return $Default }
        $p = $Definition.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $Default
    }
    $id = [string](& $get 'Id' ''); $category = ([string](& $get 'Category' '')).ToLowerInvariant(); $run = & $get 'Run' $null; $applies = & $get 'Applies' $null
    $problem = ''
    if (-not $id) { $problem = 'a check definition has no Id' }
    elseif ($category -notin $script:CategoryNames) { $problem = "category '$category' is not one of $($script:CategoryNames -join ', ')" }
    elseif ($run -isnot [scriptblock]) { $problem = 'Run is not a scriptblock' }
    $title = [string](& $get 'Title' $id)
    if ($problem) {
        $why = "The verification module $Module has an unusable check definition ($(if ($id) { $id } else { 'no Id' })): $problem."
        return [pscustomobject]@{ Id = $(if ($id) { $id } else { "EXT-$Module" }); Category = 'readiness'; Title = $title; Source = "scripts/common/arm-deployment/verification/$Module.psm1"; Reads = "verification module $Module"; Blocking = $true; Fixable = $false; Module = $Module
            Applies = { $true }; Run = { param($Ctx, $Def) throw $Def.Why }; Why = $why }
    }
    # The module's own scriptblocks are kept on the definition and called by wrappers that need no closure (the engine passes the definition as the second argument).
    $appliesWrapped = { $true }
    if ($applies -is [scriptblock]) {
        $appliesWrapped = {
            param($Ctx, $Def)
            $r = & $Def.ExtApplies (Get-AzlPclContextTable $Ctx)
            if ($r -is [string]) { return $r }
            if ($r -is [bool] -and -not $r) { return 'This check does not apply to this design.' }
            return $true
        }
    }
    $runWrapped = { param($Ctx, $Def) & $Def.ExtRun (Get-AzlPclContextTable $Ctx) }
    $blocking = & $get 'Blocking' $true
    [pscustomobject]@{
        Id = $id; Category = $category; Title = $title; Source = [string](& $get 'Source' ''); Reads = "verification module $Module"; Blocking = [bool]$blocking; Fixable = $false; Module = $Module
        Applies = $appliesWrapped; Run = $runWrapped; ExtApplies = $applies; ExtRun = $run
    }
}

function Import-AzlPclExtension {
    <#
    .SYNOPSIS
        Loads every AzlVerification.*.psm1 of the folder. Each module exports Get-AzlVerificationCheckDefinition (an array of {Id, Category, Title,
        Source, Blocking, Applies = { param($Context) }, Run = { param($Context) -> results }}) and may export Get-AzlVerificationAdapterDefault (a table of
        read only scriptblocks the module's checks use). A module that does not load becomes a failing check, never a silent gap.
    .OUTPUTS
        Definitions, AdapterDefaults, Modules (Name, Checks, Error).
    #>
    [CmdletBinding()]
    param([string]$Folder = (Get-AzlPclExtensionFolder))
    $defs = [System.Collections.Generic.List[object]]::new(); $adapters = [ordered]@{}; $modules = [System.Collections.Generic.List[object]]::new()
    if ($Folder -and (Test-Path -LiteralPath $Folder -PathType Container)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $Folder -Filter 'AzlVerification.*.psm1' -File | Sort-Object Name)) {
            $name = $file.BaseName
            try {
                $module = Import-Module -Name $file.FullName -Force -PassThru -ErrorAction Stop
                $getDefinitions = $module.ExportedCommands['Get-AzlVerificationCheckDefinition']
                if (-not $getDefinitions) { throw 'it does not export Get-AzlVerificationCheckDefinition' }
                $count = 0
                foreach ($d in @(& $getDefinitions)) { if ($null -ne $d) { $defs.Add((ConvertTo-AzlPclDefinition -Definition $d -Module $name)); $count++ } }
                $getAdapters = $module.ExportedCommands['Get-AzlVerificationAdapterDefault']
                if ($getAdapters) { $table = & $getAdapters; foreach ($k in @($table.Keys)) { if (-not $adapters.Contains($k)) { $adapters[$k] = $table[$k] } } }
                $modules.Add([pscustomobject]@{ Name = $name; Checks = $count; Error = '' })
            }
            catch {
                $why = "The verification module $name could not be loaded: $($_.Exception.Message)"
                $modules.Add([pscustomobject]@{ Name = $name; Checks = 0; Error = $_.Exception.Message })
                $defs.Add([pscustomobject]@{ Id = "EXT-$($name -replace '^AzlVerification\.', '')"; Category = 'readiness'; Title = "The verification module $name loads"; Source = "scripts/common/arm-deployment/verification/$name.psm1"; Reads = "verification module $name"
                        Blocking = $true; Fixable = $false; Module = $name; Applies = { $true }; Run = { param($Ctx, $Def) throw $Def.Why }; Why = $why })
            }
        }
    }
    [pscustomobject]@{ Definitions = $defs.ToArray(); AdapterDefaults = $adapters; Modules = $modules.ToArray() }
}

function Get-AzlPclDefinitionSet {
    # The built-in catalog with the modules' definitions; a module definition with the Id of a built-in check replaces it.
    param($Extension)
    $byId = [ordered]@{}
    foreach ($d in $script:Catalog) { $byId[$d.Id] = $d }
    if ($Extension) { foreach ($d in $Extension.Definitions) { $byId[$d.Id] = $d } }
    return @($byId.Values)
}

function ConvertTo-AzlPclResultObject {
    # A result of a check as the engine reads it: an object or a table with Status, Node, Message, Remedy, Evidence (or Details).
    param($Result)
    $get = {
        param($Name)
        if ($Result -is [System.Collections.IDictionary]) { if ($Result.Contains($Name)) { return $Result[$Name] } return $null }
        $p = $Result.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $null
    }
    $status = [string](& $get 'Status')
    if (-not $status) { return $null }
    $message = [string](& $get 'Message')
    $evidence = & $get 'Evidence'
    $details = @(ConvertTo-AzlPclList (& $get 'Details'))
    if ($null -ne $evidence -and "$evidence" -ne '') {
        $evidenceText = (@(ConvertTo-AzlPclList $evidence) | ForEach-Object { [string]$_ }) -join '; '
        if ($message -notlike "*$evidenceText*") { $message = "$message Evidence: $evidenceText".Trim() }
        $details += @(ConvertTo-AzlPclList $evidence | ForEach-Object { [string]$_ })
    }
    $node = [string](& $get 'Node'); if (-not $node) { $node = '*' }
    $canon = $script:Statuses | Where-Object { $_ -ieq $status } | Select-Object -First 1
    if (-not $canon) { return [pscustomobject]@{ Status = 'Failed'; Message = "The check returned the status '$status', which is not one of $($script:Statuses -join ', '). $message"; Remedy = [string](& $get 'Remedy'); Node = $node; Details = $details } }
    [pscustomobject]@{ Status = $canon; Message = $message; Remedy = [string](& $get 'Remedy'); Node = $node; Details = $details }
}

function Invoke-AzlPclAdapter {
    # Calls an adapter member; a member that is missing or $null is "not available here" and ends the check as Skipped.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name, [object[]]$Argument = @())
    $adapter = $Ctx.Adapter
    if (-not $adapter.Contains($Name) -or $null -eq $adapter[$Name]) { Stop-AzlPclSkip "The adapter has no '$Name' here, so this check could not read what it needs." }
    return (& $adapter[$Name] @Argument)
}

function Test-AzlPclAdapterHas($Ctx, [string]$Name) { return ($Ctx.Adapter.Contains($Name) -and $null -ne $Ctx.Adapter[$Name]) }

# ---------------------------------------------------------------------------------------------------------------------
# The feed, the report and the summary
# ---------------------------------------------------------------------------------------------------------------------

function Write-AzlPclEvent {
    <#
    .SYNOPSIS
        Appends one line to precluster-verification-events.jsonl (UTF-8 without BOM, one JSON object per line). Never throws.
    .DESCRIPTION
        Fields on every line: schema, runId, seq, ts, type, checkId, category, title, status, node, message, remedy, source, blocking.
        RunCompleted adds verdict, counts, fileHash and expiresUtc. Text is never truncated; secrets are scrubbed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][ValidateSet('RunStarted', 'Check', 'RunCompleted')][string]$Type, $Check, $Result, [System.Collections.IDictionary]$Extra)
    if (-not $Run.EventPath) { return $false }
    try {
        $Run.Seq++
        $entry = [ordered]@{
            schema = 1; runId = $Run.RunId; seq = $Run.Seq; ts = (& $Run.Adapter.Now).ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture); type = $Type
            checkId = $(if ($Check) { $Check.Id } else { '' }); category = $(if ($Check) { $Check.Category } else { '' }); title = $(if ($Check) { $Check.Title } else { '' })
            status = $(if ($Result) { $Result.Status } else { '' }); node = $(if ($Result) { $Result.Node } else { '*' })
            message = $(if ($Result) { Hide-AzlPclSecret $Result.Message } elseif ($Extra -and $Extra.Contains('message')) { Hide-AzlPclSecret ([string]$Extra['message']) } else { '' })
            remedy = $(if ($Result) { Hide-AzlPclSecret $Result.Remedy } else { '' }); source = $(if ($Check) { $Check.Source } else { '' })
            blocking = $(if ($Result) { [bool]$Result.Blocking } else { $false })
        }
        if ($Type -eq 'RunCompleted') { foreach ($k in 'verdict', 'counts', 'fileHash', 'expiresUtc') { $entry[$k] = $Extra[$k] } }
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $entry -Compress -Depth 5) + "`n")
        $stream = [IO.File]::Open($Run.EventPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
        return $true
    }
    catch { Write-Verbose "The event could not be written: $($_.Exception.Message)"; return $false }
}

function Get-AzlPclCount([object[]]$Results) {
    $counts = [ordered]@{}
    foreach ($s in $script:Statuses) { $counts[$s] = @($Results | Where-Object { $_.Status -eq $s }).Count }
    return $counts
}

function Format-AzlPclSummary {
    # summary.md: for a person and for a pipeline's job summary.
    param([Parameter(Mandatory)]$Report)
    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add("## Pre-cluster verification: $($Report.cluster)"); $l.Add('')
    $l.Add("- **Verdict:** $($Report.verdict)")
    $l.Add("- **Run:** $($Report.runId), $($Report.startedUtc) to $($Report.completedUtc)")
    $l.Add("- **Valid until:** $($Report.expiresUtc) ($($Report.maxAgeHours) hours), for the infrastructure file with SHA-256 $($Report.fileHash)")
    $l.Add("- **Counts:** " + (($Report.counts.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '))
    if (@($Report.acceptedSkipped).Count) { $l.Add("- **Accepted as Skipped by the operator:** $(@($Report.acceptedSkipped) -join ', ')") }
    if ($Report.partial) { $l.Add('- **Partial run:** only some categories ran, so the ARM run does not accept this result.') }
    if ($Report.fixesApplied) { $l.Add('- **-Fix was given:** the safe fixes were allowed (Azure side only).') }
    $l.Add('')
    if ($Report.categories -and $Report.categories.Keys.Count) {
        $l.Add('### By category'); $l.Add(''); $l.Add('| Category | Results | Passed | Failed | Warning | Skipped | NotApplicable | Fixed | Blocking |'); $l.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
        foreach ($cat in $Report.categories.Keys) { $c = $Report.categories[$cat]; $l.Add("| $cat | $($c.results) | $($c.Passed) | $($c.Failed) | $($c.Warning) | $($c.Skipped) | $($c.NotApplicable) | $($c.Fixed) | $($c.blocking) |") }
        $l.Add('')
    }
    $blocking = @($Report.checks | Where-Object { $_.blocking })
    if ($blocking.Count) {
        $l.Add('### Blocking'); $l.Add('')
        foreach ($c in $blocking) {
            $l.Add("- **$($c.checkId)** ($($c.category), $($c.status)) $($c.title)$(if ($c.node -ne '*') { " on $($c.node)" })")
            $l.Add("  - $($c.message)")
            if ($c.remedy) { $l.Add("  - Fix: $($c.remedy)") }
            $l.Add("  - Source: $($c.source)")
        }
        $l.Add('')
    }
    $l.Add('### All checks'); $l.Add(''); $l.Add('| Check | Category | Node | Status | Blocking | Title |'); $l.Add('| --- | --- | --- | --- | --- | --- |')
    foreach ($c in $Report.checks) { $l.Add("| $($c.checkId) | $($c.category) | $($c.node) | $($c.status) | $($c.blocking) | $(($c.title -replace '\|', '/')) |") }
    $l.Add('')
    $others = @($Report.checks | Where-Object { -not $_.blocking -and $_.status -in 'Warning', 'Skipped', 'Fixed' })
    if ($others.Count) {
        $l.Add('### Warnings, accepted skips and fixes'); $l.Add('')
        foreach ($c in $others) { $l.Add("- **$($c.checkId)** ($($c.status)) $($c.title)$(if ($c.node -ne '*') { " on $($c.node)" }): $($c.message)$(if ($c.remedy) { " Fix: $($c.remedy)" })") }
        $l.Add('')
    }
    return ($l -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------------------------------------------------
# IPv4 helpers
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlPclUInt32([string]$Address) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip) -or $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $bytes = $ip.GetAddressBytes()
    return ([uint32]$bytes[0] * 16777216) + ([uint32]$bytes[1] * 65536) + ([uint32]$bytes[2] * 256) + [uint32]$bytes[3]
}

function Test-AzlPclInCidr([string]$Address, [string]$Cidr) {
    if ($Cidr -notmatch '^(?<net>[0-9.]+)/(?<len>\d{1,2})$') { return $false }
    $a = ConvertTo-AzlPclUInt32 $Address
    $n = ConvertTo-AzlPclUInt32 $Matches.net
    if ($null -eq $a -or $null -eq $n) { return $false }
    $len = [int]$Matches.len
    if ($len -eq 0) { return $true }
    $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $len))
    return (($a -band $mask) -eq ($n -band $mask))
}

function Get-AzlPclRange([string]$Start, [string]$End) {
    $s = ConvertTo-AzlPclUInt32 $Start
    $e = ConvertTo-AzlPclUInt32 $End
    if ($null -eq $s -or $null -eq $e -or $e -lt $s -or ($e - $s) -gt 4096) { return @() }
    return @(for ($i = $s; $i -le $e; $i++) { '{0}.{1}.{2}.{3}' -f [math]::Floor($i / 16777216), ([math]::Floor($i / 65536) % 256), ([math]::Floor($i / 256) % 256), ($i % 256) })
}

function Test-AzlPclCidrOverlap([string]$A, [string]$B) {
    if ($A -notmatch '^(?<n>[0-9.]+)/(?<l>\d{1,2})$') { return $false }
    $na = $Matches.n; $la = [int]$Matches.l
    if ($B -notmatch '^(?<n>[0-9.]+)/(?<l>\d{1,2})$') { return $false }
    $nb = $Matches.n; $lb = [int]$Matches.l
    return ((Test-AzlPclInCidr $na $B) -or (Test-AzlPclInCidr $nb $A)) -and ($la -ge 0) -and ($lb -ge 0)
}

# ---------------------------------------------------------------------------------------------------------------------
# The context of one run, and what it reads once
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlPclContext {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object; changes no system state.')]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [string]$InfrastructureFile, $Handoff, $OsReport, [Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)]$Settings, $Remoting, [bool]$Fix = $false, [string]$Mode = 'Verify')
    $infra = $Infrastructure
    $identity = [string](Get-AzlProp $infra 'scenario.identity' 'active_directory')
    $architecture = [string](Get-AzlProp $infra 'scenario.storage_architecture' 's2d')
    [pscustomobject]@{
        Infra = $infra; InfraFile = $InfrastructureFile; Handoff = $Handoff; OsReport = $OsReport; Adapter = $Adapter; Settings = $Settings; Remoting = $Remoting; Fix = $Fix; Mode = $Mode
        Cluster = [string](Get-AzlProp $infra 'cluster.name' ''); Subscription = [string](Get-AzlProp $infra 'azure.subscription_id' ''); ResourceGroup = [string](Get-AzlProp $infra 'azure.resource_group' '')
        Tenant = [string](Get-AzlProp $infra 'azure.tenant_id' ''); Location = [string](Get-AzlProp $infra 'azure.location' ''); Cloud = [string](Get-AzlProp $infra 'scenario.cloud' 'public')
        Identity = $identity; Architecture = $architecture; SanType = [string](Get-AzlProp $infra 'storage.san.type' '')
        Nodes = @(ConvertTo-AzlPclList $infra['nodes']); Cache = @{}; LdapLatch = @{}
        Infrastructure = $infra; Adapters = $Adapter
    }
}

function Get-AzlPclAzure {
    # The signed-in Azure context, or the check is Skipped (AZR-001 says why nobody is signed in).
    param([Parameter(Mandatory)]$Ctx)
    if (-not $Ctx.Cache.ContainsKey('Azure')) { $Ctx.Cache['Azure'] = $(if (Test-AzlPclAdapterHas $Ctx 'GetContext') { & $Ctx.Adapter.GetContext } else { $null }) }
    if (-not $Ctx.Cache['Azure']) { Stop-AzlPclSkip 'Nobody is signed in to Azure, so nothing in Azure could be read (see AZR-001).' 'Connect-AzAccount -Tenant <tenant id> -Subscription <subscription id>' }
    return $Ctx.Cache['Azure']
}

function Get-AzlPclParameterSet {
    <#
    .SYNOPSIS
        The ARM parameters the Validate would submit (New-AzlArmParameterSet, the same code), once per run: Set, Problems, Error.
    #>
    param([Parameter(Mandatory)]$Ctx)
    if ($Ctx.Cache.ContainsKey('ParamSet')) { return $Ctx.Cache['ParamSet'] }
    $r = [pscustomobject]@{ Set = $null; Problems = @(); Error = '' }
    try {
        $arguments = @{ Infrastructure = $Ctx.Infra; Handoff = $Ctx.Handoff; Mode = 'Validate'; AllowUnresolvedSanLun = $true }
        if ($Ctx.OsReport) { $arguments.AdapterMap = Get-AzlAdapterMapFromReport -Report $Ctx.OsReport; $arguments.NodeReport = @($Ctx.OsReport.nodes) }
        if (-not (Get-AzlProp $Ctx.Infra 'azure.hci_resource_provider_object_id') -and $Ctx.Cache.ContainsKey('Azure') -and $Ctx.Cache['Azure'] -and (Test-AzlPclAdapterHas $Ctx 'GetHciResourceProviderObjectId')) {
            try { $arguments.HciResourceProviderObjectId = [string](& $Ctx.Adapter.GetHciResourceProviderObjectId) } catch { Write-Verbose "The Azure Local resource provider object id could not be read: $($_.Exception.Message)" }
        }
        $set = New-AzlArmParameterSet @arguments
        $catalog = Get-AzlArmTemplateCatalog
        $problems = @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $catalog.templates[$set.Template.Name].parameters)
        # What only Azure or the nodes can supply is not a defect of the file.
        $problems = @($problems | Where-Object { $_ -notmatch '^(infraVolLunId|infraPerfLunId|hciResourceProviderObjectID) ' })
        $problems += @(Test-AzlArmRequiredKey -Infrastructure $Ctx.Infra -TemplateName $set.Template.Name -Catalog $catalog)
        $r.Set = $set; $r.Problems = $problems
    }
    catch { $r.Error = $_.Exception.Message }
    $Ctx.Cache['ParamSet'] = $r
    return $r
}

function Get-AzlPclArcMachine {
    # One Arc machine lookup per node per run (the ARM run's adapter member GetArcMachine).
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Node)
    $name = [string]$Node['name']
    if ($Ctx.Cache.ContainsKey("Arc:$name")) { return $Ctx.Cache["Arc:$name"] }
    $handoffNode = Get-AzlHandoffNode -Handoff $Ctx.Handoff -Name $name -ArcMachineName (Get-AzlArcMachineName -Node $Node)
    $id = if ($handoffNode -and (Get-AzlProp $handoffNode 'arcMachineResourceId')) { [string](Get-AzlProp $handoffNode 'arcMachineResourceId') } else { '' }
    $machine = Invoke-AzlPclAdapter $Ctx GetArcMachine @($name, $id, (Get-AzlArcMachineName -Node $Node), $Ctx.Subscription, $Ctx.ResourceGroup)
    $Ctx.Cache["Arc:$name"] = $machine
    return $machine
}

function Get-AzlPclLcm {
    # The LCM user's name and its Key Vault reference (the credential the LDAP checks use).
    param([Parameter(Mandatory)]$Ctx)
    [pscustomobject]@{
        Domain = [string](Get-AzlProp $Ctx.Infra 'identity.active_directory.domain_fqdn' ''); Netbios = [string](Get-AzlProp $Ctx.Infra 'identity.active_directory.netbios_name' '')
        OuPath = [string](Get-AzlProp $Ctx.Infra 'identity.active_directory.ou_path' ''); User = [string](Get-AzlProp $Ctx.Infra 'identity.active_directory.lcm_user.username' '')
        PasswordRef = [string](Get-AzlProp $Ctx.Infra 'identity.active_directory.lcm_user.password' '')
        DomainControllers = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'identity.active_directory.domain_controllers' @()) | ForEach-Object { [string]$_ })
    }
}

function Get-AzlPclLcmSecure {
    # The LCM password from Key Vault, read once per run and kept in memory (registered for scrubbing; never written).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret was just read from Key Vault; it is made a SecureString at once and only ever lives in memory.')]
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Lcm)
    if (-not $Ctx.Cache.ContainsKey('LcmSecure')) {
        $plain = [string](Invoke-AzlPclAdapter $Ctx GetSecret @($Lcm.PasswordRef))
        Register-AzlPclSecret $plain
        $Ctx.Cache['LcmPlain'] = $plain
        $Ctx.Cache['LcmSecure'] = ConvertTo-SecureString -String $plain -AsPlainText -Force
        $plain = $null
    }
    return $Ctx.Cache['LcmSecure']
}

function Invoke-AzlPclLdap {
    <#
    .SYNOPSIS
        One read only LDAP search with the LCM credential from Key Vault (Invoke-DjLdapSearch through the adapter). Throws a Skipped
        when it can't be asked; a rejected credential trips the run's latch so it is not sent again (repeated bad passwords lock the account).
    .OUTPUTS
        The adapter's answer: Reachable, Server, Entries (distinguishedName, dnsHostName, Properties), AuthFailed, Error.
    #>
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Filter, [string[]]$Property = @('distinguishedname'), [string]$SearchRoot, [string]$Scope = 'Subtree', [string]$SecurityMasks = '')
    $lcm = Get-AzlPclLcm $Ctx
    if ($Ctx.LdapLatch.ContainsKey('Tripped') -and $Ctx.LdapLatch['Tripped']) { Stop-AzlPclSkip "The LCM credential was rejected earlier in this run ($($Ctx.LdapLatch['Reason'])), so it is not sent again." }
    if (-not $lcm.DomainControllers.Count -and -not $lcm.Domain) { Stop-AzlPclSkip 'identity.active_directory.domain_controllers and domain_fqdn are empty: there is no domain controller to ask.' }
    if (-not $lcm.User -or -not $lcm.PasswordRef) { Stop-AzlPclSkip 'identity.active_directory.lcm_user has no username or password reference: there is no credential for the LDAP checks.' }
    $null = Get-AzlPclLcmSecure -Ctx $Ctx -Lcm $lcm
    $prefix = if ($lcm.Netbios) { $lcm.Netbios } elseif ($lcm.Domain) { $lcm.Domain.Split('.')[0].ToUpperInvariant() } else { '' }
    $user = if ($lcm.User -match '[\\@]') { $lcm.User } elseif ($prefix) { "$prefix\$($lcm.User)" } else { "$($lcm.User)@$($lcm.Domain)" }
    $servers = if ($lcm.DomainControllers.Count) { $lcm.DomainControllers } else { @($lcm.Domain) }
    $root = if ($SearchRoot) { $SearchRoot } else { (($lcm.Domain.Split('.') | Where-Object { $_ } | ForEach-Object { "DC=$_" }) -join ',') }
    $request = [pscustomobject]@{
        Servers = $servers; Port = 389; Credential = [pscredential]::new($user, $Ctx.Cache['LcmSecure']); SearchRoot = $root; Filter = $Filter; Properties = @($Property); TimeoutSeconds = 20; Scope = $Scope; SecurityMasks = $SecurityMasks
    }
    $answer = Invoke-AzlPclAdapter $Ctx LdapSearch @($request)
    if ([bool](Get-AzlProp $answer 'AuthFailed' $false)) {
        $Ctx.LdapLatch['Tripped'] = $true
        $Ctx.LdapLatch['Reason'] = "${user}: $([string](Get-AzlProp $answer 'Error' ''))"
    }
    return $answer
}

function ConvertTo-AzlPclLdapFilter([string]$Value) {
    return $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
}

function Get-AzlPclLdapProperty {
    # The first value of a property of an LDAP entry (Properties is a name -> values table), or $null.
    param($Entry, [string]$Name)
    $props = Get-AzlProp $Entry 'Properties'
    if (-not $props) { return $null }
    $v = if ($props -is [System.Collections.IDictionary]) { $(if ($props.Contains($Name)) { $props[$Name] } else { $null }) } else { Get-AzlProp $props $Name }
    if ($null -eq $v) { return $null }
    return @(ConvertTo-AzlPclList $v)[0]
}

# ---------------------------------------------------------------------------------------------------------------------
# The nodes: what a node says, read once per run
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlPclEndpointList {
    # The floor of outbound endpoints a node must reach on 443 (the Environment Checker connectivity validator, RDY-001, covers them all).
    param([Parameter(Mandatory)]$Ctx)
    $region = $Ctx.Location
    if ($Ctx.Cloud -eq 'government') { return @('https://login.microsoftonline.us', 'https://management.usgovcloudapi.net', 'https://gbl.his.arc.azure.us', 'https://mcr.microsoft.com') }
    $list = @('https://login.microsoftonline.com', 'https://management.azure.com', 'https://gbl.his.arc.azure.com', 'https://mcr.microsoft.com')
    if ($region) { $list += "https://$region.his.arc.azure.com" }
    return $list
}

function Get-AzlPclNodeRequest {
    # What the node reads need to know: never a secret.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Node)
    $name = [string]$Node['name']
    $dns = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ })
    $tcp = [System.Collections.Generic.List[object]]::new()
    $dnsq = [System.Collections.Generic.List[object]]::new()
    if ($Ctx.Identity -eq 'active_directory') {
        $domain = [string](Get-AzlProp $Ctx.Infra 'identity.active_directory.domain_fqdn' '')
        foreach ($dc in @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'identity.active_directory.domain_controllers' @()))) { foreach ($port in 9389, 389, 88) { $tcp.Add(@{ h = [string]$dc; p = $port }) } }
        if ($domain) { foreach ($s in $dns) { $dnsq.Add(@{ name = $domain; server = $s }) } }
    }
    else {
        $zone = [string](Get-AzlProp $Ctx.Infra 'identity.local_identity.dns_zone' '')
        if ($zone -and [string](Get-AzlProp $Ctx.Infra 'identity.local_identity.dns_server_config' '') -eq 'use_dns_server') { foreach ($s in $dns) { $dnsq.Add(@{ name = "$name.$zone"; server = $s }) } }
    }
    foreach ($s in $dns) { $tcp.Add(@{ h = $s; p = 53 }) }
    $pool = Get-AzlProp $Ctx.Infra 'networking.management.infrastructure_pool'
    $ping = @()
    $gateway = [string](Get-AzlProp $Ctx.Infra 'networking.management.gateway' '')
    if ($gateway) { $ping += $gateway }
    if ($pool) { $ping += @(Get-AzlPclRange ([string](Get-AzlProp $pool 'start' '')) ([string](Get-AzlProp $pool 'end' ''))) | Select-Object -First 64 }
    $proxy = if ([string](Get-AzlProp $Ctx.Infra 'scenario.outbound_path' '') -in 'proxy', 'proxy_arc_gateway') { [string](Get-AzlProp $Ctx.Infra 'networking.outbound.proxy.url' '') } else { '' }
    @{
        features = @($script:RequiredFeatures | ForEach-Object { $_.Name }); tcp = @($tcp); dnsq = @($dnsq); https = @(Get-AzlPclEndpointList $Ctx); proxy = $proxy; ping = @($ping | Select-Object -Unique)
        san = $true; adminUser = [string](Get-AzlProp $Ctx.Infra 'identity.local_admin.username' '')
    }
}

function Get-AzlPclNodeData {
    <#
    .SYNOPSIS
        What one node says, read once per run through the adapter's ReadNode: Ok, Error, Name, Read (the OS configuration's Read payload:
        adapters, time, admin, storage, SAN) and Pcl (the gate's own payload: hardware, disks, adapters, features, DNS, probes).
    #>
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Node)
    $name = [string]$Node['name']
    if ($Ctx.Cache.ContainsKey("Node:$name")) { return $Ctx.Cache["Node:$name"] }
    $r = [pscustomobject]@{ Name = $name; Ok = $false; Error = ''; Address = ''; Read = $null; Pcl = $null; Spec = $null }
    try {
        if (-not (Test-AzlPclAdapterHas $Ctx 'ReadNode')) { throw 'The adapter has no ReadNode here (nodes are not reachable from this host).' }
        $local = Get-AzlProp $Ctx.Infra 'identity.local_admin'
        $user = [string](Get-AzlProp $local 'username' '')
        $ref = [string](Get-AzlProp $local 'password' '')
        if (-not $user -or -not $ref) { throw 'identity.local_admin.username or password is not set: there is no credential for the node.' }
        if (-not $Ctx.Cache.ContainsKey('AdminSecure')) {
            $plain = [string](Invoke-AzlPclAdapter $Ctx GetSecret @($ref))
            Register-AzlPclSecret $plain
            $Ctx.Cache['AdminPlain'] = $plain
            $Ctx.Cache['AdminSecure'] = ConvertTo-SecureString -String $plain -AsPlainText -Force
            $plain = $null
        }
        $spec = Get-AzlNodeSpec -Infrastructure $Ctx.Infra -Node $Node -Handoff $Ctx.Handoff
        $r.Spec = $spec
        $mgmtMac = [string]$spec.Management.Mac
        $addresses = @(@([string]$spec.Management.Ip) + @(Get-AzlNodeRemotingAddress -Node $Node -ManagementMac $mgmtMac) | Where-Object { $_ } | Select-Object -Unique)
        if (-not $addresses.Count) { throw "Node $name has no management address (nodes[].management.ip_address or the management port's ip_address)." }
        $readParameters = Get-AzlNodeReadParameter -Spec $spec
        # The gate always asks about the SAN (what is visible but not declared is a finding) and the disks.
        $readParameters.san = $true; $readParameters.sanDisks = $true
        if (-not $readParameters.sanType) { $readParameters.sanType = $Ctx.SanType }
        $remoting = $Ctx.Remoting
        $request = [pscustomobject]@{
            Node = $name; Addresses = $addresses; Credential = [pscredential]::new("$name\$user", $Ctx.Cache['AdminSecure']); AdminPassword = $Ctx.Cache['AdminPlain']
            UseSsl = [bool]$remoting.UseSsl; Authentication = [string]$remoting.Authentication; ReadParameters = $readParameters; PclParameters = (Get-AzlPclNodeRequest -Ctx $Ctx -Node $Node)
        }
        $answer = & $Ctx.Adapter.ReadNode $request
        $r.Read = Get-AzlProp $answer 'Read'; $r.Pcl = Get-AzlProp $answer 'Pcl'; $r.Address = [string](Get-AzlProp $answer 'Address' ($addresses | Select-Object -First 1))
        if (-not $r.Pcl) { throw 'The node answered without the verification payload.' }
        $r.Ok = $true
    }
    catch { $r.Error = Hide-AzlPclSecret $_.Exception.Message }
    $Ctx.Cache["Node:$name"] = $r
    return $r
}

function Invoke-AzlPclPerNode {
    <#
    .SYNOPSIS
        Runs -Body for every node that could be read, as { param($Name, $Data, $Node) }; a node that could not be read gets a Skipped
        result that says so (NOD-001 holds the reason). The body returns results.
    #>
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][scriptblock]$Body)
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $d = Get-AzlPclNodeData -Ctx $Ctx -Node $n
        if (-not $d.Ok) { New-AzlPclResult Skipped "$name could not be read, so this was not checked on it: $($d.Error)" 'Make the node reachable first (NOD-001), then run the verification again.' -Node $name; continue }
        try { & $Body $name $d $n }
        catch {
            if ($_.Exception.Data['AzlSkip']) { New-AzlPclResult Skipped $_.Exception.Message ([string]$_.Exception.Data['AzlRemedy']) -Node $name }
            else { New-AzlPclResult Failed "${name}: the check could not run: $($_.Exception.Message)" 'Read the message, fix the cause and run the verification again.' -Node $name }
        }
    }
}

function Get-AzlPclPcl {
    # A field of the gate's own payload (Pcl) or the OS configuration Read (Read) with a default, safe under strict mode.
    param($Data, [string]$Path, $Default = $null)
    return (Get-AzlProp $Data $Path $Default)
}

# =====================================================================================================================
# THE CATALOG
#   Source of every check: the Microsoft Learn page (view azloc-2610) or the azurelocal.cloud page its rule comes from.
#   Learn's rules are encoded as Learn states them; where the azurelocal.cloud docs differ (docs-2610-audit.md) Learn wins.
# =====================================================================================================================

$script:Src = @{
    Prereq     = "$script:Learn/deploy/deployment-prerequisites?$script:View"
    Perm       = "$script:Learn/deploy/deployment-arc-register-server-permissions?$script:View"
    PrepAd     = "$script:Learn/deploy/deployment-prep-active-directory?$script:View"
    CustomAd   = "$script:Learn/plan/configure-custom-settings-active-directory?$script:View"
    Install    = "$script:Learn/deploy/deployment-install-os?$script:View"
    InstallDa  = "$script:Learn/deploy/deployment-install-os-disaggregated?$script:View"
    ExtStorage = "$script:Learn/deploy/enable-external-storage?$script:View"
    NetPlan    = "$script:Learn/plan/cloud-deployment-network-considerations?$script:View"
    HostNet    = "$script:Learn/concepts/host-network-requirements?$script:View"
    SysReq     = "$script:Learn/concepts/system-requirements-23h2?$script:View"
    EnvChecker = "$script:Learn/manage/use-environment-checker?$script:View"
    Local      = "$script:Learn/deploy/deployment-local-identity-with-key-vault?$script:View"
    LocalTpl   = "$script:Learn/deploy/deployment-local-identity-with-key-vault-template?$script:View"
    Template   = "$script:Learn/deploy/deployment-azure-resource-manager-template?$script:View"
    Firewall   = "$script:Learn/concepts/firewall-requirements?$script:View"
    Known      = 'config/known-issues/arm-deployment.json'
    DocsPrereq = "$script:Docs/04-prerequisites-and-assumptions"
}

# The Azure Local regions of Learn, system requirements (Azure public, Azure Government).
$script:SupportedRegions = @{
    public     = @('eastus', 'westeurope', 'australiaeast', 'southeastasia', 'centralindia', 'canadacentral', 'japaneast', 'southcentralus')
    government = @('usgovvirginia', 'usgovarizona')
}

# The roles Learn tells you to assign to the user who deploys (Assign required permissions for Azure Local deployment). Owner holds
# every control-plane one; Key Vault Secrets Officer is a data plane role that Owner does not carry.
$script:DeploymentRoles = @('Azure Stack HCI Administrator', 'Reader', 'Key Vault Data Access Administrator', 'Key Vault Secrets Officer', 'Key Vault Contributor', 'Storage Account Contributor', 'Azure Connected Machine Onboarding', 'Azure Connected Machine Resource Administrator')
$script:DataPlaneRoles = @('Key Vault Secrets Officer')

function Test-AzlPclRoleHeld {
    # $true when the role is held by name, or the caller is Owner and the role is a control-plane role.
    param([string[]]$Held, [string]$Role)
    if ($Role -in $Held) { return $true }
    return ('Owner' -in $Held -and $Role -notin $script:DataPlaneRoles)
}

# ---------------------------------------------------------------------------------------------------------------------
# AZURE
# ---------------------------------------------------------------------------------------------------------------------

Register-AzlPclCheck -Id 'AZR-001' -Category azure -Title 'Signed in to the tenant and subscription the file names' -Source $script:Src.Perm -Reads 'the Az context' -Run {
    param($Ctx)
    $c = if (Test-AzlPclAdapterHas $Ctx 'GetContext') { & $Ctx.Adapter.GetContext } else { $null }
    $Ctx.Cache['Azure'] = $c
    if (-not $c) { return New-AzlPclResult Failed 'Nobody is signed in to Azure. Every check that reads Azure is Skipped until someone is.' "Connect-AzAccount -Tenant '$($Ctx.Tenant)' -Subscription '$($Ctx.Subscription)'   (this tool never signs in by itself)" }
    $problems = @()
    if ($c.SubscriptionId -ne $Ctx.Subscription) { $problems += "the context is subscription $(Format-AzlPclShort $c.SubscriptionId), the file says $(Format-AzlPclShort $Ctx.Subscription)" }
    if ($Ctx.Tenant -and $c.TenantId -and $c.TenantId -ne $Ctx.Tenant) { $problems += "the context is tenant $(Format-AzlPclShort $c.TenantId), the file says $(Format-AzlPclShort $Ctx.Tenant)" }
    if (-not $Ctx.Tenant) { $problems += 'azure.tenant_id is empty in the file, so the tenant of the context cannot be compared' }
    if ($problems) { return New-AzlPclResult Failed ("Wrong Azure context: " + ($problems -join '; ') + '. Registering the machines or deploying in another tenant fails later and cannot be moved.') "Connect-AzAccount -Tenant '$($Ctx.Tenant)' -Subscription '$($Ctx.Subscription)'; Set-AzContext -Subscription '$($Ctx.Subscription)'  (or fix azure.tenant_id and azure.subscription_id in the file)" }
    New-AzlPclResult Passed "Signed in as $($c.Account) to subscription $(Format-AzlPclShort $c.SubscriptionId) in tenant $(Format-AzlPclShort $c.TenantId)."
}

Register-AzlPclCheck -Id 'AZR-002' -Category azure -Title 'Subscription is enabled and the region is one Azure Local supports' -Source $script:Src.SysReq -Reads 'ARM: the subscription' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $sub = Invoke-AzlPclAdapter $Ctx GetSubscription @($Ctx.Subscription)
    if (-not $sub) { return New-AzlPclResult Failed "Subscription $(Format-AzlPclShort $Ctx.Subscription) is not visible to the signed-in identity." "Select the subscription of the file: Set-AzContext -Subscription '$($Ctx.Subscription)'" }
    $problems = @()
    if ($sub.State -and $sub.State -ne 'Enabled') { $problems += "the subscription state is $($sub.State), not Enabled" }
    $region = ($Ctx.Location -replace '[\s_-]', '').ToLowerInvariant()
    $listed = @($script:SupportedRegions[$(if ($Ctx.Cloud -eq 'government') { 'government' } else { 'public' })])
    if ($problems) { return New-AzlPclResult Failed ("Subscription $(Format-AzlPclShort $Ctx.Subscription): " + ($problems -join '; ') + '.') 'Use an enabled subscription (Azure portal, Subscriptions).' }
    if ($region -and $region -notin $listed) {
        return New-AzlPclResult Warning "azure.location '$($Ctx.Location)' is not in the regions Learn lists for Azure Local ($($listed -join ', ')); the Arc integration validator rejects a region that is not valid for the service." "Check the region against Learn 'System requirements' or use one of: $($listed -join ', ')."
    }
    New-AzlPclResult Passed "Subscription '$($sub.DisplayName)' is Enabled; region $($Ctx.Location) is supported."
}

Register-AzlPclCheck -Id 'AZR-003' -Category azure -Title 'Resource group of the instance exists' -Source $script:Src.Perm -Reads 'ARM: the resource group' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $rg = Invoke-AzlPclAdapter $Ctx GetResourceGroup @($Ctx.Subscription, $Ctx.ResourceGroup)
    if (-not $rg) { return New-AzlPclResult Failed "Resource group $($Ctx.ResourceGroup) does not exist in subscription $(Format-AzlPclShort $Ctx.Subscription)." "New-AzResourceGroup -Name '$($Ctx.ResourceGroup)' -Location '$($Ctx.Location)'   (or fix azure.resource_group)" }
    New-AzlPclResult Passed "Resource group $($Ctx.ResourceGroup) exists."
}

Register-AzlPclCheck -Id 'AZR-004' -Category azure -Title 'All 13 mandatory resource providers are registered' -Source $script:Src.Perm -Reads 'ARM: the resource providers (-Fix registers)' -Fixable -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $providers = @(Get-AzlArmMandatoryProvider)
    $state = [ordered]@{}
    foreach ($ns in $providers) { $state[$ns] = [string](Invoke-AzlPclAdapter $Ctx GetProviderState @($Ctx.Subscription, $ns)) }
    $details = @($providers | ForEach-Object { "${_}: $($state[$_])" })
    $missing = @($providers | Where-Object { $state[$_] -ne 'Registered' })
    if (-not $missing) { return New-AzlPclResult Passed "All $($providers.Count) mandatory resource providers are registered ($($providers -join ', '))." -Details $details }
    $commands = (($missing | ForEach-Object { "Register-AzResourceProvider -ProviderNamespace $_" }) -join '; ')
    $listed = ($missing | ForEach-Object { "$_ ($(if ($state[$_]) { $state[$_] } else { 'unknown' }))" }) -join ', '
    $why = "Learn lists $($providers.Count) providers as required; Azure's validation step ValidateArcIntegration (AzStackHci_ArcIntegration_MandatoryRPRegistration_Check) fails on any that is not registered. Microsoft.KeyVault and Microsoft.HybridContainerService are among them; Microsoft.Insights is needed for monitoring and Key Vault audit logging."
    $notFound = @($missing | Where-Object { $state[$_] -eq 'NotFound' })
    if (-not ($Ctx.Fix -and $Ctx.Mode -eq 'Verify')) {
        return New-AzlPclResult Failed "Mandatory resource providers not registered: $listed. $why" "$commands   (Owner or Contributor on the subscription; or run this gate with -Fix)" -Details $details
    }
    if ($notFound) { return New-AzlPclResult Failed "These providers do not exist in the subscription, so they cannot be registered: $($notFound -join ', '). $why" 'A sovereign cloud may not offer a provider; check the Azure cloud of the file.' -Details $details }
    $requested = [System.Collections.Generic.List[string]]::new()
    foreach ($ns in $missing) {
        if ($state[$ns] -eq 'Registering') { continue }
        try { $null = Invoke-AzlPclAdapter $Ctx RegisterProvider @($Ctx.Subscription, $ns) }
        catch { return New-AzlPclResult Failed "Registering $ns failed: $($_.Exception.Message)" "Owner or Contributor on the subscription is needed. Register it yourself: Register-AzResourceProvider -ProviderNamespace $ns" -Details $details }
        $requested.Add($ns)
    }
    $deadline = (& $Ctx.Adapter.Now).AddMinutes(15)
    $pending = @($missing)
    while ($true) {
        $pending = @($pending | Where-Object { (Invoke-AzlPclAdapter $Ctx GetProviderState @($Ctx.Subscription, $_)) -ne 'Registered' })
        if (-not $pending) { break }
        if ((& $Ctx.Adapter.Now) -ge $deadline) { return New-AzlPclResult Failed "Registration was requested ($($requested -join ', ')) but these are not Registered after 15 minutes: $($pending -join ', ')." 'Wait for them (Get-AzResourceProvider -ProviderNamespace <name> shows RegistrationState), then run the verification again.' -Details $details }
        $null = Invoke-AzlPclAdapter $Ctx Sleep @(10)
    }
    New-AzlPclResult Fixed "Registered by -Fix: $($missing -join ', '). The other $($providers.Count - $missing.Count) mandatory providers already were Registered." -Details $details
}

Register-AzlPclCheck -Id 'AZR-005' -Category azure -Title 'Subscription roles: Contributor and User Access Administrator (or Owner)' -Source $script:Src.Prereq -Reads 'ARM: role assignments of the signed-in identity' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $scope = "/subscriptions/$($Ctx.Subscription)"
    try { $held = @(Invoke-AzlPclAdapter $Ctx GetCallerRoles @($scope) | Where-Object { $scope -like "$($_.Scope)*" -or $_.Scope -eq $scope } | ForEach-Object { [string]$_.Role } | Select-Object -Unique) }
    catch [System.NotSupportedException] { throw }
    catch { if ($_.Exception.Data['AzlSkip']) { throw }; Stop-AzlPclSkip "The roles of the signed-in identity could not be read ($($_.Exception.Message)); AZR-006 checks the effective permissions instead." }
    $ok = ('Owner' -in $held) -or ('Contributor' -in $held -and 'User Access Administrator' -in $held)
    if ($ok) { return New-AzlPclResult Passed "The identity holds $(Join-AzlPclList $held) on the subscription." -Details $held }
    $missing = @('Contributor', 'User Access Administrator') | Where-Object { $_ -notin $held }
    New-AzlPclResult Failed "Learn: make sure you are a user access administrator and a contributor on the subscription (it Arc-enables each machine and assigns roles). The identity holds: $(if ($held) { Join-AzlPclList $held } else { 'no role at this scope' }). Missing: $(Join-AzlPclList $missing)." ((@($missing) | ForEach-Object { "New-AzRoleAssignment -SignInName '<signed-in user>' -RoleDefinitionName '$_' -Scope '$scope'" }) -join '; ') -Details $held
}

Register-AzlPclCheck -Id 'AZR-006' -Category azure -Title 'Effective permissions on the resource group include role assignment, deployment, cluster, Key Vault and storage writes' -Source $script:Src.Perm -Reads 'ARM: effective permissions of the resource group' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $perm = @(Invoke-AzlPclAdapter $Ctx GetPermission @($Ctx.Subscription, $Ctx.ResourceGroup))
    if ($perm.Count -eq 0) { return New-AzlPclResult Warning 'The effective permissions of the resource group could not be read.' 'Make sure the identity is Owner, or Contributor plus User Access Administrator, on the resource group.' }
    $required = @(Get-AzlArmRequiredAction) + @('Microsoft.HybridCompute/machines/read', 'Microsoft.Authorization/roleAssignments/read') | Select-Object -Unique
    $missing = foreach ($action in $required) {
        $allowed = $false
        foreach ($p in $perm) {
            $yes = @($p.Actions | Where-Object { $action -like $_ }).Count -gt 0
            $no = @($p.NotActions | Where-Object { $action -like $_ }).Count -gt 0
            if ($yes -and -not $no) { $allowed = $true }
        }
        if (-not $allowed) { $action }
    }
    if ($missing) { return New-AzlPclResult Failed "The signed-in identity may not do these on resource group $($Ctx.ResourceGroup): $((@($missing)) -join ', '). Microsoft.Authorization/roleAssignments/write is what the deployment needs to give the cluster its roles." "Give the identity Owner, or Contributor plus User Access Administrator, on the resource group: New-AzRoleAssignment -SignInName '<signed-in user>' -RoleDefinitionName 'Owner' -ResourceGroupName '$($Ctx.ResourceGroup)'" -Details @($missing) }
    New-AzlPclResult Passed "The identity may $((@($required | Select-Object -First 3)) -join ', ') and $($required.Count - 3) more on the resource group, including Microsoft.Authorization/roleAssignments/write."
}

Register-AzlPclCheck -Id 'AZR-007' -Category azure -Title 'The roles Learn lists for the deployment user on the resource group' -Source $script:Src.Perm -Reads 'ARM: role assignments of the signed-in identity' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $scope = "/subscriptions/$($Ctx.Subscription)/resourceGroups/$($Ctx.ResourceGroup)"
    try { $held = @(Invoke-AzlPclAdapter $Ctx GetCallerRoles @($scope) | Where-Object { $scope -like "$($_.Scope)*" -or $_.Scope -eq $scope } | ForEach-Object { [string]$_.Role } | Select-Object -Unique) }
    catch { if ($_.Exception.Data['AzlSkip']) { throw }; Stop-AzlPclSkip "The roles of the signed-in identity could not be read ($($_.Exception.Message))." }
    $missing = @($script:DeploymentRoles | Where-Object { -not (Test-AzlPclRoleHeld -Held $held -Role $_) })
    if (-not $missing) { return New-AzlPclResult Passed "The identity holds all $($script:DeploymentRoles.Count) roles Learn lists (directly or through Owner): $(Join-AzlPclList $script:DeploymentRoles)." -Details $held }
    New-AzlPclResult Failed "Missing on resource group $($Ctx.ResourceGroup) (or above): $(Join-AzlPclList $missing). Learn: assign these to the user who deploys the instance (Azure Stack HCI Administrator and Reader; the four Key Vault and storage roles; Azure Connected Machine Onboarding and Resource Administrator unless that user owns the resource group). The identity holds: $(if ($held) { Join-AzlPclList $held } else { 'nothing here' })." ((@($missing) | ForEach-Object { "New-AzRoleAssignment -SignInName '<signed-in user>' -RoleDefinitionName '$_' -ResourceGroupName '$($Ctx.ResourceGroup)'" }) -join '; ') -Details $held
}

Register-AzlPclCheck -Id 'AZR-008' -Category azure -Title 'Every Key Vault secret the deployment reads exists and can be read' -Source $script:Src.Prereq -Reads 'Key Vault: secret metadata' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $refs = [System.Collections.Generic.List[object]]::new()
    $set = Get-AzlPclParameterSet $Ctx
    if ($set.Set) { foreach ($k in $set.Set.Parameters.Keys) { $v = $set.Set.Parameters[$k]; if ($v -is [System.Collections.IDictionary] -and $v.Contains('KeyVault')) { $refs.Add([pscustomobject]@{ Name = $k; Reference = [string]$v.KeyVault }) } } }
    foreach ($p in 'identity.local_admin.password', 'identity.local_admin.username_secret', 'identity.active_directory.lcm_user.password', 'identity.active_directory.domain_join_account.password') {
        $v = [string](Get-AzlProp $Ctx.Infra $p '')
        if ($v -and $v -like 'keyvault://*' -and -not @($refs | Where-Object { $_.Reference -eq $v }).Count) { $refs.Add([pscustomobject]@{ Name = $p; Reference = $v }) }
    }
    $listed = @(ConvertTo-AzlPclList $Ctx.Infra['key_vaults'] | ForEach-Object { [string]$_['name'] })
    $bad = @()
    foreach ($r in $refs) {
        $parts = ConvertFrom-AzlKeyVaultRef -Reference $r.Reference
        if (-not $parts) { $bad += "$($r.Name): '$($r.Reference)' is not a keyvault://<vault>/<secret> reference"; continue }
        if ($parts.Vault -notin $listed) { $bad += "$($r.Name): vault $($parts.Vault) is not listed under key_vaults in the file"; continue }
        $exists = $false
        try { $exists = [bool](Invoke-AzlPclAdapter $Ctx TestSecret @($parts.Vault, $parts.Secret)) }
        catch { if ($_.Exception.Data['AzlSkip']) { throw }; $bad += "$($r.Name): secret $($parts.Secret) in $($parts.Vault) could not be read ($($_.Exception.Message))"; continue }
        if (-not $exists) { $bad += "$($r.Name): secret $($parts.Secret) is not in vault $($parts.Vault)" }
    }
    if (-not $refs.Count) { return New-AzlPclResult Warning 'The file references no Key Vault secret (identity.local_admin.password and the LCM user password should be keyvault:// references).' 'Store the secrets in Key Vault and reference them as keyvault://<vault>/<secret>.' }
    if ($bad) { return New-AzlPclResult Failed ($bad -join '; ') 'Create the secret (Add-KeyVaultCredentials.ps1), grant this identity Get on secrets (Key Vault Secrets Officer), or fix the keyvault:// reference.' -Details $bad }
    New-AzlPclResult Passed "$($refs.Count) secret reference(s) resolve to existing secrets the signed-in identity can read (values not shown)."
}

Register-AzlPclCheck -Id 'AZR-009' -Category azure -Title 'Names of the cloud witness storage account, diagnostics storage account and Key Vault are free' -Source $script:Src.Prereq -Reads 'ARM: name availability' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $names = @()
    $diag = [string](Get-AzlProp $Ctx.Infra 'cluster.diagnostics.storage_account' '')
    if ($diag) { $names += , @('storage', $diag, 'diagnostics storage account') }
    if ([string](Get-AzlProp $Ctx.Infra 'cluster.witness.type' '') -eq 'cloud') { $w = [string](Get-AzlProp $Ctx.Infra 'cluster.witness.storage_account' ''); if ($w) { $names += , @('storage', $w, 'cloud witness storage account') } }
    if ([bool](Get-AzlProp $Ctx.Infra 'cluster.key_vault.create_new' $false)) { $k = [string](Get-AzlProp $Ctx.Infra 'cluster.key_vault.name' ''); if ($k) { $names += , @('keyvault', $k, 'Key Vault') } }
    $bad = @()
    foreach ($n in $names) {
        if ($n[0] -eq 'storage' -and $n[1] -notmatch '^[a-z0-9]{3,24}$') { $bad += "$($n[1]) ($($n[2])) is not a valid storage account name (3 to 24 lower case letters and digits)"; continue }
        if ($n[0] -eq 'keyvault' -and $n[1] -notmatch '^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$') { $bad += "$($n[1]) ($($n[2])) is not a valid Key Vault name (3 to 24 letters, digits and hyphens, starting with a letter)"; continue }
        $r = Invoke-AzlPclAdapter $Ctx TestNameAvailable @($Ctx.Subscription, $Ctx.ResourceGroup, $n[0], $n[1])
        if (-not $r.Available -and -not $r.ExistsInResourceGroup) { $bad += "$($n[1]) ($($n[2]))$(if ($r.Reason) { ': ' + $r.Reason })" }
    }
    if ($bad) { return New-AzlPclResult Failed "Name taken or unusable: $($bad -join '; ')." 'Choose another name in the file (cluster.witness.storage_account, cluster.diagnostics.storage_account, cluster.key_vault.name). A soft-deleted Key Vault keeps its name until it is purged: Remove-AzKeyVault -VaultName <name> -Location <region> -InRemovedState.' -Details $bad }
    New-AzlPclResult Passed "$($names.Count) resource name(s) are free or already in the resource group."
}

Register-AzlPclCheck -Id 'AZR-010' -Category azure -Title 'Arc machines exist, are Connected and are in the resource group of the file' -Source $script:Src.Perm -Reads 'ARM: the Arc machines' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $m = Get-AzlPclArcMachine $Ctx $n
        if (-not $m) { New-AzlPclResult Failed "No Arc machine found for $name in $($Ctx.ResourceGroup)." 'Finish ZTP or the Arc registration of the node (Phase 04), or fix nodes[].arc_machine_name.' -Node $name; continue }
        $problems = @()
        if ($m.Status -ne 'Connected') { $problems += "status is '$($m.Status)', not Connected" }
        if ($m.ResourceId -match '^/subscriptions/(?<s>[^/]+)/resourceGroups/(?<g>[^/]+)/') { if ($Matches.s -ne $Ctx.Subscription -or $Matches.g -ne $Ctx.ResourceGroup) { $problems += "the machine is in resource group $($Matches.g), not $($Ctx.ResourceGroup)" } }
        if ($problems) { New-AzlPclResult Failed "Arc machine $($m.Name): $($problems -join '; ')." 'Wait for the agent to connect, restart it (Restart-Service himds on the node), or register the node in the resource group of the instance. A stale machine that is not Connected: delete it (az connectedmachine delete) and register again (AZCM0044 otherwise).' -Node $name }
        else { New-AzlPclResult Passed "Arc machine $($m.Name) is Connected in $($Ctx.ResourceGroup)." -Node $name }
    }
}

Register-AzlPclCheck -Id 'AZR-011' -Category azure -Title 'Arc machines are named after the host (known issue arc-device-id-name)' -Source $script:Src.Known -Reads 'ARM: the Arc machines' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $issue = Get-AzlArmKnownIssue | Where-Object { $_['id'] -eq 'arc-device-id-name' } | Select-Object -First 1
    $affected = @(ConvertTo-AzlPclList $(if ($issue) { $issue['affectedBuilds'] } else { @() }))
    $build = if ($Ctx.Handoff) { [string]$Ctx.Handoff.VsrVersion } else { '' }
    $guid = '^[0-9a-f]{8}(-?[0-9a-f]{4}){3}-?[0-9a-f]{12}(-\d+)?$|^[0-9a-f]{16,}(-\d+)?$'
    $acknowledged = ('arc-device-id-name' -in $Ctx.Settings.acknowledgeKnownIssues) -or ('*' -in $Ctx.Settings.acknowledgeKnownIssues)
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $m = Get-AzlPclArcMachine $Ctx $n
        if (-not $m) { New-AzlPclResult Skipped "No Arc machine for $name (see AZR-010)." -Node $name; continue }
        $hostName = if ($m.ComputerName) { $m.ComputerName } else { $name }
        if ($m.Name -ieq $hostName -or $m.Name -ieq $name) { New-AzlPclResult Passed "Arc machine $($m.Name) is named after the host." -Node $name; continue }
        if ($m.Name -notmatch $guid) { New-AzlPclResult Warning "Arc machine $($m.Name) is not named after the host ($hostName). Check that nodes[].arc_machine_name is intended." -Node $name; continue }
        $knownBad = (-not $build) -or (@($affected | Where-Object { $build.StartsWith([string]$_) }).Count -gt 0)
        $text = "Arc machine $($m.Name) is named by device ID, not after the host ($hostName). On build $($affected -join ', ') the Deploy step 0.41 (Arc infrastructure) looks the machine up by host name and fails with ParentResourceNotFound (known issue arc-device-id-name); Validate does not reach that step, so it passes and the Deploy fails hours later."
        $fix = 'Install the node from the Microsoft image and register it with Azure Arc under the host name (the OS configuration run does this for ISO-installed nodes), or wait for a fixed build. To go ahead anyway: -AcknowledgeKnownIssues arc-device-id-name.'
        if ($acknowledged -or -not $knownBad) { New-AzlPclResult Warning ($text + $(if ($acknowledged) { ' Acknowledged by the operator.' } else { " Build $build is not one it was seen on." })) $fix -Node $name }
        else { New-AzlPclResult Failed $text $fix -Node $name }
    }
}

Register-AzlPclCheck -Id 'AZR-012' -Category azure -Title 'No node is Arc-enabled twice or in another resource group' -Source "$script:Learn/manage/use-environment-checker?$script:View (Arc integration validator)" -Reads 'ARM: Arc machines of the subscription' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $found = @(Invoke-AzlPclAdapter $Ctx FindArcMachines @($Ctx.Subscription, $name))
        $elsewhere = @($found | Where-Object { $_.ResourceGroup -ine $Ctx.ResourceGroup })
        $same = @($found | Where-Object { $_.ResourceGroup -ieq $Ctx.ResourceGroup })
        if ($elsewhere.Count) { New-AzlPclResult Failed "$name is also an Arc machine in another resource group: $((@($elsewhere | ForEach-Object { "$($_.ResourceGroup)/$($_.Name) ($($_.Status))" })) -join '; '). The Arc integration validator fails when a node is already Arc-enabled in a different resource group." "Delete the stale Arc machine (az connectedmachine delete --resource-group <rg> --name <name>) or choose the resource group it is in." -Node $name }
        elseif ($same.Count -gt 1) { New-AzlPclResult Failed "$($same.Count) Arc machines in $($Ctx.ResourceGroup) carry the name or host name $name ($((@($same | ForEach-Object { "$($_.Name) ($($_.Status))" })) -join '; ')). Machines left over from earlier installs make the lookup ambiguous." 'Delete the stale ones that are not Connected (az connectedmachine delete).' -Node $name }
        else { New-AzlPclResult Passed "$name has $($same.Count) Arc machine in the subscription, in $($Ctx.ResourceGroup)." -Node $name }
    }
}

Register-AzlPclCheck -Id 'AZR-013' -Category azure -Title 'No leftover failed or running deployment on the instance' -Source "$($script:Src.Known) (license-sync-after-failed-validate)" -Reads 'ARM: the cluster resource and its deployment settings' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $s = Invoke-AzlPclAdapter $Ctx GetDeploymentState @($Ctx.Subscription, $Ctx.ResourceGroup, $Ctx.Cluster)
    if (-not $s) { return New-AzlPclResult Passed "No cluster resource $($Ctx.Cluster) yet: a fresh deployment." }
    $dep = ConvertTo-AzlArmStepStatus $s.DeploymentStatus
    $failed = ([string]$s.ProvisioningState -eq 'Failed') -or $dep -eq 'error'
    if ($dep -eq 'success') { return New-AzlPclResult Failed "The instance $($Ctx.Cluster) is already deployed (deployment status $($s.DeploymentStatus))." 'Nothing to validate. If this is a redeployment, delete the cluster resource first.' }
    if ($dep -eq 'running') { return New-AzlPclResult Failed 'A deployment is running on this instance.' 'Wait for it, or run the ARM deployment in Mode Deploy to attach to it.' }
    if ($failed) { return New-AzlPclResult Failed "The instance is in a failed deployment state (provisioning $($s.ProvisioningState), deployment $($s.DeploymentStatus)). Microsoft: another Validate resets the system properties and can break license sync." 'Fix the cause and resume with Invoke-AzureLocalArmDeployment.ps1 -Mode Deploy -Resume. -AllowRevalidate is for support-guided recovery only.' }
    New-AzlPclResult Passed 'The instance is not in a failed or running deployment.'
}

Register-AzlPclCheck -Id 'AZR-014' -Category azure -Title 'No zombie role assignments (identity not found) in the resource group' -Source "$($script:Src.Known) (role-assignment-zombie)" -Reads 'ARM: role assignments of the resource group' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $scope = "/subscriptions/$($Ctx.Subscription)/resourceGroups/$($Ctx.ResourceGroup)"
    $all = @(Invoke-AzlPclAdapter $Ctx ListRoleAssignments @($scope))
    $zombies = @($all | Where-Object { $_.PrincipalType -eq 'Unknown' -or (-not $_.DisplayName -and -not $_.PrincipalType) })
    if (-not $zombies) { return New-AzlPclResult Passed "$($all.Count) role assignment(s) at the resource group; none has a deleted principal." }
    $list = @($zombies | ForEach-Object { "$($_.Role) -> $($_.PrincipalId)" })
    New-AzlPclResult Failed "$($zombies.Count) role assignment(s) at $($Ctx.ResourceGroup) belong to a principal that no longer exists (the portal shows 'Identity not found'): $($list -join '; '). A former deployment's role assignments stayed behind; Azure then fails with 'Tenant ID, application ID, principal ID, and scope aren't allowed to be updated'." "Get-AzRoleAssignment -Scope '$scope' | Where-Object { `$_.ObjectType -eq 'Unknown' } | Remove-AzRoleAssignment" -Details $list
}

Register-AzlPclCheck -Id 'AZR-015' -Category azure -Title 'No role assignment left by an earlier (portal) deployment that the template would create again' -Source "$($script:Src.Known) (role-assignment-already-exists)" -Reads 'ARM: the cluster resource and the role assignments of the resource group' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $s = Invoke-AzlPclAdapter $Ctx GetDeploymentState @($Ctx.Subscription, $Ctx.ResourceGroup, $Ctx.Cluster)
    if ($s) { return New-AzlPclResult NotApplicable 'The cluster resource exists, so its role assignments are its own (the template updates them).' }
    $scope = "/subscriptions/$($Ctx.Subscription)/resourceGroups/$($Ctx.ResourceGroup)"
    $mine = @(Invoke-AzlPclAdapter $Ctx ListRoleAssignments @($scope) | Where-Object { $_.Role -eq 'Azure Stack HCI Device Management Role' -and $_.PrincipalType -ne 'Unknown' })
    if (-not $mine) { return New-AzlPclResult Passed 'No Azure Stack HCI Device Management Role assignment exists in the resource group; the template can create its own.' }
    $list = @($mine | ForEach-Object { "$($_.Role) -> $($_.DisplayName) ($($_.PrincipalId))" })
    New-AzlPclResult Failed "The resource group already holds $($mine.Count) assignment(s) of the Azure Stack HCI Device Management Role although the cluster resource does not exist: $($list -join '; '). The deployment was tried from the portal first (or by another run), so another identity holds the equivalent assignment and the template fails with RoleAssignmentExists (AzureStackHCIDeviceManagementRole-RoleAssignment)." "Access control (IAM), Role assignments: delete these assignments, or: Remove-AzRoleAssignment -ObjectId <principal id> -RoleDefinitionName 'Azure Stack HCI Device Management Role' -Scope '$scope'" -Details $list
}

Register-AzlPclCheck -Id 'AZR-016' -Category azure -Title 'No Windows update extension on the Arc machines (updates install during the deployment)' -Source $script:Src.Install -Reads 'ARM: extensions of the Arc machines' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $m = Get-AzlPclArcMachine $Ctx $n
        if (-not $m) { New-AzlPclResult Skipped "No Arc machine for $name (see AZR-010)." -Node $name; continue }
        $ext = @(Invoke-AzlPclAdapter $Ctx ListArcExtensions @($m.ResourceId) | Where-Object { $_.Type -match 'WindowsOsUpdateExtension' -or $_.Name -match 'WindowsOsUpdateExtension' })
        if ($ext.Count) { New-AzlPclResult Failed "$name carries the extension $($ext[0].Name) (Microsoft.SoftwareUpdateManagement.WindowsOsUpdateExtension). Learn: do not install Windows Updates with SConfig or Azure Update Manager; updates are installed during the deployment, and installing them before causes a deployment failure." "Remove-AzConnectedMachineExtension -MachineName '$($m.Name)' -ResourceGroupName '$($Ctx.ResourceGroup)' -Name '$($ext[0].Name)'" -Node $name }
        else { New-AzlPclResult Passed "$name has no Windows update extension." -Node $name }
    }
}

Register-AzlPclCheck -Id 'AZR-017' -Category azure -Title 'The ARM parameters can be generated from the file and match the template' -Source $script:Src.Template -Reads 'the file (and the OS configuration report for adapter names)' -Run {
    param($Ctx)
    $r = Get-AzlPclParameterSet $Ctx
    if ($r.Error) { return New-AzlPclResult Failed "The ARM parameters cannot be generated from the file: $($r.Error)" 'Fix the file (Test-InfrastructureFile.ps1 names the key), then run the verification again.' }
    if ($r.Problems.Count) { return New-AzlPclResult Failed "$($r.Problems.Count) problem(s) in the ARM parameter set for template $($r.Set.Template.Name): $($r.Problems -join ' | ')" 'Fill the keys named above in infrastructure.yml (parameter-sources.md of an ARM Plan run maps each ARM parameter to its key).' -Details @($r.Problems) }
    New-AzlPclResult Passed "Template $($r.Set.Template.Name): $($r.Set.Parameters.Count) parameters generated and checked against the template."
}

Register-AzlPclCheck -Id 'AZR-018' -Category azure -Title 'The Arc gateway resource exists (outbound path with an Arc gateway)' -Source "$script:Learn/deploy/deployment-without-azure-arc-gateway?$script:View" -Reads 'ARM: the Arc gateway' `
    -Applies { param($Ctx) if ([string](Get-AzlProp $Ctx.Infra 'scenario.outbound_path' '') -in 'arc_gateway', 'proxy_arc_gateway', 'private_path') { $true } else { 'scenario.outbound_path does not use an Arc gateway.' } } -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $name = [string](Get-AzlProp $Ctx.Infra 'networking.outbound.arc_gateway.name' '')
    $rg = [string](Get-AzlProp $Ctx.Infra 'networking.outbound.arc_gateway.resource_group' '')
    if (-not $rg) { $rg = $Ctx.ResourceGroup }
    if (-not $name) { return New-AzlPclResult Failed 'scenario.outbound_path uses an Arc gateway but networking.outbound.arc_gateway.name is empty.' 'Set networking.outbound.arc_gateway.name (and resource_group when it is not the instance''s).' }
    $g = Invoke-AzlPclAdapter $Ctx GetArcGateway @($Ctx.Subscription, $rg, $name)
    if (-not $g) { return New-AzlPclResult Failed "The Arc gateway $name does not exist in resource group $rg of the subscription." "New-AzArcGateway / az connectedmachine gateway create --name $name --resource-group $rg   (or fix networking.outbound.arc_gateway)" }
    if ($g.ProvisioningState -and $g.ProvisioningState -ne 'Succeeded') { return New-AzlPclResult Failed "The Arc gateway $name is in state $($g.ProvisioningState), not Succeeded." 'Wait for it, or recreate it.' }
    New-AzlPclResult Passed "The Arc gateway $name exists in $rg."
}

# ---------------------------------------------------------------------------------------------------------------------
# IDENTITY
# ---------------------------------------------------------------------------------------------------------------------

$script:IsAd = { param($Ctx) if ($Ctx.Identity -eq 'active_directory') { $true } else { 'scenario.identity is local_identity: no Active Directory.' } }
$script:IsLocal = { param($Ctx) if ($Ctx.Identity -eq 'local_identity') { $true } else { 'scenario.identity is active_directory: no local identity deployment.' } }

function Get-AzlPclLdapChecked {
    # One LDAP search for a check: a credential that was rejected or a domain controller that does not answer ends the check as Skipped.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Filter, [string[]]$Property = @('distinguishedname'), [string]$SearchRoot, [string]$Scope = 'Subtree', [string]$SecurityMasks = '')
    $answer = Invoke-AzlPclLdap -Ctx $Ctx -Filter $Filter -Property $Property -SearchRoot $SearchRoot -Scope $Scope -SecurityMasks $SecurityMasks
    if ([bool](Get-AzlProp $answer 'AuthFailed' $false)) { Stop-AzlPclSkip "The domain controller rejected the LCM credential, so Active Directory could not be read (IDN-002): $([string](Get-AzlProp $answer 'Error' ''))" }
    if (-not [bool](Get-AzlProp $answer 'Reachable' $false)) {
        $why = [string](Get-AzlProp $answer 'Error' '')
        Stop-AzlPclSkip $(if ($why) { $why } else { 'no domain controller of the file answered on TCP 389 from this host' }) 'Run the verification from a host that reaches the domain controllers on TCP 389 (for example a domain-joined jump server), or accept the skipped checks with -AcceptSkipped.'
    }
    if ([string](Get-AzlProp $answer 'Error' '')) { Stop-AzlPclSkip ([string]$answer.Error) 'Run the verification from a host that can read Active Directory.' }
    return $answer
}

function Test-AzlPclPassword {
    # Azure's rule: at least 14 characters with a lower case letter, an upper case letter, a digit and a special character. Returns what is missing.
    param([string]$Password)
    $missing = @()
    if ($Password.Length -lt 14) { $missing += 'at least 14 characters' }
    if ($Password -cnotmatch '[a-z]') { $missing += 'a lower case letter' }
    if ($Password -cnotmatch '[A-Z]') { $missing += 'an upper case letter' }
    if ($Password -notmatch '\d') { $missing += 'a digit' }
    if ($Password -notmatch '[^A-Za-z0-9]') { $missing += 'a special character' }
    return $missing
}

function Get-AzlPclDnsMode {
    # How likely it is that the DNS servers of the file support secure dynamic updates: they are domain controllers (Microsoft DNS integrated with AD).
    param([Parameter(Mandatory)]$Ctx)
    $dns = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ })
    $dcs = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'identity.active_directory.domain_controllers' @()) | ForEach-Object { [string]$_ })
    $secure = ($dns.Count -gt 0) -and (@($dns | Where-Object { $_ -notin $dcs }).Count -eq 0)
    [pscustomobject]@{ Servers = $dns; AdIntegrated = $secure }
}

function Resolve-AzlPclRecord {
    # A name against every configured DNS server: Answers (server -> addresses), Silent (servers that did not answer).
    param([Parameter(Mandatory)]$Ctx, [string]$Name, [string[]]$Server)
    $answers = [ordered]@{}; $silent = @()
    foreach ($s in $Server) {
        $r = Invoke-AzlPclAdapter $Ctx ResolveDns @($Name, $s)
        if ($null -eq $r) { Stop-AzlPclSkip 'This host has no DNS client (Resolve-DnsName), so DNS records could not be asked for.' }
        if (-not $r.Ok) { $silent += $s; continue }
        $answers[$s] = @($r.Addresses)
    }
    [pscustomobject]@{ Answers = $answers; Silent = $silent }
}

Register-AzlPclCheck -Id 'IDN-001' -Category identity -Title 'Active Directory settings in the file follow Learn (OU path, LCM user name, domain)' -Source $script:Src.PrepAd -Reads 'the file' -Applies $script:IsAd -Run {
    param($Ctx)
    $lcm = Get-AzlPclLcm $Ctx
    $problems = @()
    if (-not $lcm.Domain) { $problems += 'identity.active_directory.domain_fqdn is empty' }
    if (-not $lcm.OuPath) { $problems += 'identity.active_directory.ou_path is empty' }
    else {
        if ($lcm.OuPath -notmatch '^\s*OU=') { $problems += "ou_path '$($lcm.OuPath)' does not start with OU=: the OU can't be the top of the domain" }
        if ($lcm.OuPath -notmatch '(^|,)\s*DC=') { $problems += "ou_path '$($lcm.OuPath)' has no DC= parts: Learn asks for the distinguished name including the domain components" }
        if ($lcm.OuPath -match '[&"''<>]') { $problems += "ou_path '$($lcm.OuPath)' contains one of & `" ' < >, which the OU path does not support" }
    }
    if (-not $lcm.User) { $problems += 'identity.active_directory.lcm_user.username is empty' }
    else {
        if ($lcm.User -match '[\\@]') { $problems += "the LCM user name '$($lcm.User)' includes a domain; give only the user name" }
        if ($lcm.User.Length -gt 20) { $problems += "the LCM user name is $($lcm.User.Length) characters; the limit is 20" }
        if ($lcm.User -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$' -and $lcm.User -notmatch '[\\@]') { $problems += "the LCM user name '$($lcm.User)' may contain only letters, numbers, hyphens and underscores, and must not start with a hyphen or a number" }
        if ($lcm.User -ieq 'admin') { $problems += "'admin' can't be the LCM user name" }
        if ($lcm.User -ieq [string](Get-AzlProp $Ctx.Infra 'identity.local_admin.username' '')) { $problems += 'the LCM user name must differ from the local administrator name' }
    }
    if (-not $lcm.PasswordRef) { $problems += 'identity.active_directory.lcm_user.password is empty' }
    if ($lcm.Netbios -and $lcm.Netbios.Length -gt 15) { $problems += "netbios_name '$($lcm.Netbios)' is longer than 15 characters" }
    if ($problems) { return New-AzlPclResult Failed ("identity.active_directory: " + ($problems -join '; ') + '.') 'Fix identity.active_directory in infrastructure.yml. Learn: the LCM user name is 1 to 20 characters (letters, numbers, hyphens, underscores), not starting with a hyphen or number, not admin, unique per instance, with no domain part; the OU path is a distinguished name below the domain.' -Details $problems }
    $warn = if (-not $lcm.DomainControllers.Count) { ' identity.active_directory.domain_controllers is empty, so the domain name is used to find a domain controller.' } else { '' }
    New-AzlPclResult $(if ($warn) { 'Warning' } else { 'Passed' }) "OU $($lcm.OuPath) and LCM user $($lcm.User) follow Learn's naming rules in $($lcm.Domain).$warn"
}

Register-AzlPclCheck -Id 'IDN-002' -Category identity -Title 'A domain controller answers and accepts the LCM credential' -Source $script:Src.PrepAd -Reads 'Active Directory (LDAP 389) with the LCM credential from Key Vault' -Applies $script:IsAd -Run {
    param($Ctx)
    $lcm = Get-AzlPclLcm $Ctx
    $root = ($lcm.Domain.Split('.') | Where-Object { $_ } | ForEach-Object { "DC=$_" }) -join ','
    $a = Invoke-AzlPclLdap -Ctx $Ctx -Filter '(objectClass=domainDNS)' -Property @('distinguishedname') -SearchRoot $root -Scope Base
    if ([bool](Get-AzlProp $a 'AuthFailed' $false)) { return New-AzlPclResult Failed "The domain controller rejected the LCM credential ($($lcm.User)): $([string](Get-AzlProp $a 'Error' '')). The credential is not sent again in this run (repeated bad passwords lock the account)." "Check the password in Key Vault ($($lcm.PasswordRef)) and that the account is enabled and not locked: Get-ADUser $($lcm.User) -Properties Enabled,LockedOut" }
    if (-not [bool](Get-AzlProp $a 'Reachable' $false)) {
        $why = [string](Get-AzlProp $a 'Error' '')
        Stop-AzlPclSkip $(if ($why) { $why } else { "no domain controller of the file answered on TCP 389 from this host (tried $($lcm.DomainControllers -join ', '))" }) 'Run the verification from a host that reaches the domain controllers on TCP 389 (for example a domain-joined jump server), or accept the skipped identity checks with -AcceptSkipped.'
    }
    if ([string](Get-AzlProp $a 'Error' '')) { return New-AzlPclResult Failed "The LDAP search on $([string](Get-AzlProp $a 'Server' '')) failed: $($a.Error)" 'Check LDAP signing and the account, or run from a domain-joined host.' }
    New-AzlPclResult Passed "Domain controller $([string](Get-AzlProp $a 'Server' '')) answered and accepted $($lcm.User)."
}

Register-AzlPclCheck -Id 'IDN-003' -Category identity -Title 'The dedicated OU exists' -Source $script:Src.PrepAd -Reads 'Active Directory (LDAP)' -Applies $script:IsAd -Run {
    param($Ctx)
    $lcm = Get-AzlPclLcm $Ctx
    $a = Get-AzlPclLdapChecked -Ctx $Ctx -Filter "(&(objectClass=organizationalUnit)(distinguishedName=$(ConvertTo-AzlPclLdapFilter $lcm.OuPath)))" -Property @('distinguishedname', 'gpoptions', 'gplink')
    $entries = @($a.Entries)
    $Ctx.Cache['Ou'] = $(if ($entries.Count) { $entries[0] } else { $null })
    if (-not $entries.Count) { return New-AzlPclResult Failed "The OU $($lcm.OuPath) does not exist in $($lcm.Domain). Learn: the Active Directory preparation tool was not run (a skipped preparation is what Azure's Active Directory validator then fails on)." "New-HciAdObjectsPreCreation -AzureStackLCMUserCredential (Get-Credential) -AsHciOUName '$($lcm.OuPath)'   (module AsHciADArtifactsPreCreationTool; Install-Module AsHciADArtifactsPreCreationTool -Repository PSGallery -Force)" }
    New-AzlPclResult Passed "The OU $($lcm.OuPath) exists (found on $([string](Get-AzlProp $a 'Server' '')))."
}

Register-AzlPclCheck -Id 'IDN-004' -Category identity -Title 'The LCM user exists, is enabled, not locked, not expired and may log on interactively' -Source $script:Src.PrepAd -Reads 'Active Directory (LDAP)' -Applies $script:IsAd -Run {
    param($Ctx)
    $lcm = Get-AzlPclLcm $Ctx
    $a = Get-AzlPclLdapChecked -Ctx $Ctx -Filter "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-AzlPclLdapFilter $lcm.User)))" -Property @('distinguishedname', 'useraccountcontrol', 'accountexpires', 'msds-user-account-control-computed', 'userworkstations', 'objectsid')
    $entries = @($a.Entries)
    $Ctx.Cache['LcmUser'] = $(if ($entries.Count -eq 1) { $entries[0] } else { $null })
    if (-not $entries.Count) { return New-AzlPclResult Failed "The LCM user $($lcm.User) does not exist in $($lcm.Domain). The preparation tool creates it in the OU." "New-HciAdObjectsPreCreation -AzureStackLCMUserCredential (Get-Credential) -AsHciOUName '$($lcm.OuPath)'" }
    if ($entries.Count -gt 1) { return New-AzlPclResult Failed "$($entries.Count) accounts match the LCM user name $($lcm.User): $((@($entries | ForEach-Object { [string]$_.distinguishedName })) -join '; '). The name must be unique." 'Remove or rename the duplicates.' }
    $e = $entries[0]
    $uac = [int](Get-AzlPclLdapProperty $e 'useraccountcontrol')
    $computed = [int](Get-AzlPclLdapProperty $e 'msds-user-account-control-computed')
    $expires = [int64](Get-AzlPclLdapProperty $e 'accountexpires')
    $problems = @(); $warnings = @()
    if ($uac -band 0x2) { $problems += 'the account is disabled' }
    if ($computed -band 0x10) { $problems += 'the account is locked out' }
    if ($uac -band 0x40000) { $problems += 'the account requires a smart card (no interactive logon with a password)' }
    if ($expires -gt 0 -and $expires -lt [int64]::MaxValue -and [datetime]::FromFileTimeUtc($expires) -lt (& $Ctx.Adapter.Now)) { $problems += "the account expired on $([datetime]::FromFileTimeUtc($expires).ToString('yyyy-MM-dd'))" }
    if (Get-AzlPclLdapProperty $e 'userworkstations') { $warnings += "the account may log on only to: $(Get-AzlPclLdapProperty $e 'userworkstations'); the deployment signs it in on every node" }
    $dn = [string]$e.distinguishedName
    if ($problems) { return New-AzlPclResult Failed "The LCM user $dn cannot be used: $($problems -join '; ')." "Set-ADUser $($lcm.User) -Enabled `$true; Unlock-ADAccount $($lcm.User); Set-ADUser $($lcm.User) -SmartcardLogonRequired `$false -AccountExpirationDate `$null" -Details $problems }
    if ($warnings) { return New-AzlPclResult Warning "The LCM user $dn exists and is enabled, but $($warnings -join '; ')." 'Clear the logon workstation restriction. Learn also needs the Log on as a batch job right: make sure the default domain policy does not deny it (not readable over LDAP).' }
    $inOu = $dn.EndsWith($lcm.OuPath, [StringComparison]::OrdinalIgnoreCase)
    New-AzlPclResult Passed "The LCM user $dn exists, is enabled, not locked, not expired and not restricted$(if (-not $inOu) { " (it is outside the OU, which Learn allows: the user can reside anywhere)" }). Learn also needs the Log on as a batch job right; a deny in the default domain policy is not readable over LDAP."
}

Register-AzlPclCheck -Id 'IDN-005' -Category identity -Title 'The LCM user can create and delete computer objects in the OU' -Source $script:Src.CustomAd -Reads 'Active Directory (LDAP): the OU security descriptor' -Applies $script:IsAd -Run {
    param($Ctx)
    $lcm = Get-AzlPclLcm $Ctx
    $user = $Ctx.Cache['LcmUser']
    if (-not $user) { Stop-AzlPclSkip 'The LCM user was not found (IDN-004), so its rights on the OU cannot be compared.' }
    $a = Get-AzlPclLdapChecked -Ctx $Ctx -Filter "(&(objectClass=organizationalUnit)(distinguishedName=$(ConvertTo-AzlPclLdapFilter $lcm.OuPath)))" -Property @('distinguishedname', 'ntsecuritydescriptor') -SecurityMasks Dacl
    $ou = @($a.Entries) | Select-Object -First 1
    if (-not $ou) { Stop-AzlPclSkip 'The OU was not found (IDN-003).' }
    $sd = Get-AzlPclLdapProperty $ou 'ntsecuritydescriptor'
    $sid = Get-AzlPclLdapProperty $user 'objectsid'
    if (-not $sd -or -not $sid) { Stop-AzlPclSkip 'The security descriptor of the OU or the SID of the LCM user was not returned over LDAP, so the delegated rights could not be compared.' "Check by hand: Learn needs the LCM user to list contents, read all properties, read permissions, and create and delete computer objects in the OU (New-HciAdObjectsPreCreation sets this)." }
    $rights = Get-AzlPclOuRight -DescriptorBase64 $sd -SidBase64 $sid
    if ($rights.CanCreateDeleteComputer) { return New-AzlPclResult Passed "The LCM user has $(Join-AzlPclList $rights.Matched) on the OU." }
    New-AzlPclResult Warning "No access control entry on the OU grants the LCM user $($lcm.User) full control or the rights to create and delete computer objects directly (found: $(if ($rights.Matched) { Join-AzlPclList $rights.Matched } else { 'none' })). The rights may come through a group; if they do not, the deployment fails to create the node and cluster objects." "Run New-HciAdObjectsPreCreation again for this OU and user, or delegate: create and delete Computer objects, read all properties, list contents and read permissions for $($lcm.User) on $($lcm.OuPath). Learn: Custom Active Directory configuration for your Azure Local instance."
}

function Get-AzlPclOuRight {
    <#
    .SYNOPSIS
        From the DACL of an OU (base64 of the binary descriptor) and the SID of a user (base64): whether an allow entry for that SID grants
        GenericAll, or both CreateChild and DeleteChild for computer objects (or all objects). Needs System.DirectoryServices (Windows).
    #>
    param([Parameter(Mandatory)][string]$DescriptorBase64, [Parameter(Mandatory)][string]$SidBase64)
    $result = [pscustomobject]@{ CanCreateDeleteComputer = $false; Matched = @() }
    $sid = [System.Security.Principal.SecurityIdentifier]::new([Convert]::FromBase64String($SidBase64), 0)
    $security = [System.DirectoryServices.ActiveDirectorySecurity]::new()
    $security.SetSecurityDescriptorBinaryForm([Convert]::FromBase64String($DescriptorBase64))
    $computer = [guid]'bf967a86-0de6-11d0-a285-00aa00302ce8'
    $matched = [System.Collections.Generic.List[string]]::new()
    $create = $false; $delete = $false; $all = $false
    foreach ($rule in $security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or $rule.IdentityReference.Value -ne $sid.Value) { continue }
        $r = [string]$rule.ActiveDirectoryRights
        $scopeOk = ($rule.ObjectType -eq [guid]::Empty -or $rule.ObjectType -eq $computer)
        if ($r -match 'GenericAll') { $all = $true; $matched.Add('GenericAll') }
        if ($scopeOk -and $r -match 'CreateChild') { $create = $true }
        if ($scopeOk -and $r -match 'DeleteChild') { $delete = $true }
    }
    if ($create) { $matched.Add('CreateChild') }
    if ($delete) { $matched.Add('DeleteChild') }
    $result.Matched = @($matched | Select-Object -Unique)
    $result.CanCreateDeleteComputer = ($all -or ($create -and $delete))
    return $result
}

Register-AzlPclCheck -Id 'IDN-006' -Category identity -Title 'Group policy inheritance is blocked on the OU; enforced GPOs above it are handled' -Source $script:Src.PrepAd -Reads 'Active Directory (LDAP): gPOptions and gPLink of the OU and its parents' -Applies $script:IsAd -Run {
    param($Ctx)
    $lcm = Get-AzlPclLcm $Ctx
    $ou = $Ctx.Cache['Ou']
    if (-not $ou) { Stop-AzlPclSkip 'The OU was not found (IDN-003), so Block Inheritance could not be read.' }
    $options = [int](Get-AzlPclLdapProperty $ou 'gpoptions')
    if (-not ($options -band 1)) { return New-AzlPclResult Failed "Group policy inheritance is not blocked on $($lcm.OuPath) (gPOptions $options). Learn: Block Inheritance is required, so that no GPO conflicts with the settings Azure Local manages (security defaults and drift control)." "Set-GPInheritance -Target '$($lcm.OuPath)' -IsBlocked Yes" }
    # The ancestors, nearest first: a GPO link with the enforced flag (option 2) is not blocked by Block Inheritance.
    $parts = @($lcm.OuPath -split '(?<!\\),' | ForEach-Object { $_.Trim() })
    $ancestors = @()
    for ($i = 1; $i -lt $parts.Count; $i++) { $candidate = ($parts[$i..($parts.Count - 1)]) -join ','; if ($candidate -match '(^|,)DC=') { $ancestors += $candidate } }
    $enforced = @()
    if ($ancestors.Count) {
        $filter = '(|' + (($ancestors | ForEach-Object { "(distinguishedName=$(ConvertTo-AzlPclLdapFilter $_))" }) -join '') + ')'
        $a = Get-AzlPclLdapChecked -Ctx $Ctx -Filter $filter -Property @('distinguishedname', 'gplink')
        foreach ($e in @($a.Entries)) {
            $link = [string](Get-AzlPclLdapProperty $e 'gplink')
            foreach ($m in [regex]::Matches($link, '\[(?<dn>[^;\]]+);(?<opt>\d+)\]')) { if (([int]$m.Groups['opt'].Value -band 2) -and -not ([int]$m.Groups['opt'].Value -band 1)) { $enforced += "$($m.Groups['dn'].Value) (linked at $($e.distinguishedName))" } }
        }
    }
    if ($enforced.Count) { return New-AzlPclResult Warning "Block Inheritance is on, but $($enforced.Count) enforced GPO link(s) above the OU still apply: $($enforced -join '; '). Learn: enforced GPOs are not blocked." "Exclude the Azure Local machine accounts from these GPOs with a WMI filter (Learn: Prepare Active Directory, note on enforced GPOs)." -Details $enforced }
    New-AzlPclResult Passed "Block Inheritance is set on $($lcm.OuPath) and no enforced GPO link above it applies."
}

Register-AzlPclCheck -Id 'IDN-007' -Category identity -Title 'KDS root key (not required by Learn 2610 for Azure Local)' -Source $script:Src.PrepAd -Reads 'nothing' -Blocking $false -Applies $script:IsAd -Run {
    param($Ctx)
    New-AzlPclResult NotApplicable "Learn 2610 does not list a KDS root key (or a gMSA) among the Active Directory requirements for Azure Local: the preparation article names a dedicated OU, blocked GPO inheritance and a user with rights on the OU. Add-KdsRootKey belongs to the optional gMSA tasks of azurelocal.cloud, not to the deployment, so it is not checked."
}

Register-AzlPclCheck -Id 'IDN-008' -Category identity -Title 'DNS host (A) records of the nodes resolve to their management addresses' -Source $script:Src.CustomAd -Reads 'DNS servers of the file' -Applies {
    param($Ctx)
    if ($Ctx.Identity -eq 'active_directory') { return $true }
    if ([string](Get-AzlProp $Ctx.Infra 'identity.local_identity.dns_server_config' '') -eq 'use_dns_server') { return $true }
    'identity.local_identity.dns_server_config is use_forwarder: the internal DNS service of Azure Local creates the records.'
} -Run {
    param($Ctx)
    $zone = if ($Ctx.Identity -eq 'active_directory') { [string](Get-AzlProp $Ctx.Infra 'identity.active_directory.domain_fqdn' '') } else { [string](Get-AzlProp $Ctx.Infra 'identity.local_identity.dns_zone' '') }
    if (-not $zone) { return New-AzlPclResult Failed 'There is no DNS domain (identity.active_directory.domain_fqdn or identity.local_identity.dns_zone) to look the nodes up in.' 'Set it in infrastructure.yml.' }
    $mode = Get-AzlPclDnsMode $Ctx
    if (-not $mode.Servers.Count) { return New-AzlPclResult Failed 'networking.management.dns_servers is empty.' 'Set the DNS servers of the management network.' }
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $mgmt = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $n
        $expected = if ($mgmt) { [string]$mgmt.IpAddress } else { '' }
        $fqdn = "$name.$zone"
        $r = Resolve-AzlPclRecord -Ctx $Ctx -Name $fqdn -Server $mode.Servers
        $wrong = @($r.Answers.Keys | Where-Object { $r.Answers[$_].Count -and $expected -and $expected -notin $r.Answers[$_] })
        $none = @($r.Answers.Keys | Where-Object { -not $r.Answers[$_].Count })
        $required = ($Ctx.Identity -eq 'local_identity') -or -not $mode.AdIntegrated
        $fix = "Add-DnsServerResourceRecordA -ZoneName '$zone' -Name '$name' -IPv4Address '$expected'   (on the DNS server; Learn: create a Host (A) record for every machine)"
        if ($r.Silent.Count -eq $mode.Servers.Count) { New-AzlPclResult Failed "None of the DNS servers ($($mode.Servers -join ', ')) answered the query for $fqdn from this host." 'Make the DNS servers reachable from this host (UDP/TCP 53), or run from a host that reaches them.' -Node $name }
        elseif ($wrong) { New-AzlPclResult Failed "$fqdn resolves to $(($r.Answers[$wrong[0]]) -join ', ') on $($wrong[0]), not to the management address $expected." $fix -Node $name }
        elseif ($none.Count) {
            $level = if ($required) { 'Failed' } else { 'Warning' }
            $why = if ($required) { 'Learn requires a Host (A) record for every machine' + $(if ($Ctx.Identity -eq 'active_directory') { ' when the DNS server does not support secure dynamic updates (these DNS servers are not domain controllers)' } else { ' for a local identity deployment' }) } else { 'The DNS servers are domain controllers (Microsoft DNS integrated with Active Directory), so secure dynamic updates create the record when the node joins; Learn requires the record up front only when the DNS server does not support them' }
            New-AzlPclResult $level "$fqdn has no A record on $(Join-AzlPclList $none). $why." $fix -Node $name
        }
        else { New-AzlPclResult Passed "$fqdn resolves to $expected on every DNS server ($($mode.Servers -join ', '))." -Node $name }
    }
}

Register-AzlPclCheck -Id 'IDN-009' -Category identity -Title 'Cluster (CNO) and client access point (VCO) DNS records exist when DNS has no secure dynamic update' -Source $script:Src.CustomAd -Reads 'DNS servers of the file' -Applies $script:IsAd -Run {
    param($Ctx)
    $zone = [string](Get-AzlProp $Ctx.Infra 'identity.active_directory.domain_fqdn' '')
    $mode = Get-AzlPclDnsMode $Ctx
    if (-not $mode.Servers.Count) { return New-AzlPclResult Failed 'networking.management.dns_servers is empty.' 'Set the DNS servers of the management network.' }
    $fqdn = "$($Ctx.Cluster).$zone"
    $r = Resolve-AzlPclRecord -Ctx $Ctx -Name $fqdn -Server $mode.Servers
    if ($r.Silent.Count -eq $mode.Servers.Count) { return New-AzlPclResult Failed "None of the DNS servers answered the query for $fqdn from this host." 'Make the DNS servers reachable from this host.' }
    $none = @($r.Answers.Keys | Where-Object { -not $r.Answers[$_].Count })
    if (-not $none.Count) { return New-AzlPclResult Passed "The cluster name $fqdn resolves on every DNS server ($(($r.Answers.Values | ForEach-Object { $_ -join ', ' } | Select-Object -Unique) -join '; '))." }
    $fix = "Add-DnsServerResourceRecordA -ZoneName '$zone' -Name '$($Ctx.Cluster)' -IPv4Address '<the cluster IP>'  (the first address of the infrastructure pool); also a Host (A) record for the Cluster Aware Updating client access point (VCO). Learn: Custom Active Directory configuration, Required DNS records."
    if ($mode.AdIntegrated) { return New-AzlPclResult Warning "The cluster name $fqdn has no A record yet. The DNS servers are domain controllers (secure dynamic updates), so the deployment creates the CNO and VCO records; Learn requires them up front only when the DNS server does not support secure dynamic updates. Learn gives no fixed name for the VCO, so it is not looked up." $fix }
    New-AzlPclResult Failed "The cluster name $fqdn has no A record on $(Join-AzlPclList $none), and the DNS servers are not domain controllers, so secure dynamic updates cannot be assumed. Learn: if your DNS server doesn't support secure dynamic updates, create a Host (A) record for each machine, the cluster CNO and the cluster VCO before you deploy." $fix
}

Register-AzlPclCheck -Id 'IDN-010' -Category identity -Title 'AD computer objects of the nodes and the cluster, if they exist, are in the OU' -Source $script:Src.PrepAd -Reads 'Active Directory (LDAP)' -Applies $script:IsAd -Run {
    param($Ctx)
    $lcm = Get-AzlPclLcm $Ctx
    foreach ($label in @($Ctx.Nodes | ForEach-Object { [pscustomobject]@{ Name = [string]$_['name']; Kind = 'node' } }) + @([pscustomobject]@{ Name = $Ctx.Cluster; Kind = 'cluster (CNO)' })) {
        $a = Get-AzlPclLdapChecked -Ctx $Ctx -Filter "(&(objectCategory=computer)(cn=$(ConvertTo-AzlPclLdapFilter $label.Name)))" -Property @('distinguishedname', 'dnshostname')
        $entries = @($a.Entries)
        $node = if ($label.Kind -eq 'node') { $label.Name } else { '*' }
        if (-not $entries.Count) { New-AzlPclResult Passed "No computer object named $($label.Name) ($($label.Kind)) exists; the deployment creates it in the OU." -Node $node; continue }
        $outside = @($entries | Where-Object { -not ([string]$_.distinguishedName).EndsWith($lcm.OuPath, [StringComparison]::OrdinalIgnoreCase) })
        if ($outside) { New-AzlPclResult Failed "The computer object $($outside[0].distinguishedName) ($($label.Kind)) is outside the OU $($lcm.OuPath). Learn: the dedicated OU holds the computer objects and the CNO, and moving them to another OU after the deployment is not supported." "Move it into the OU before the deployment: Move-ADObject -Identity '$($outside[0].distinguishedName)' -TargetPath '$($lcm.OuPath)'   (or delete a stale object)" -Node $node }
        else { New-AzlPclResult Passed "The computer object $($entries[0].distinguishedName) ($($label.Kind)) is already in the OU (pre-staged)." -Node $node }
    }
}

Register-AzlPclCheck -Id 'IDN-011' -Category identity -Title 'Nodes resolve the domain with their DNS servers and reach the domain controllers (ADWS 9389, LDAP 389, Kerberos 88)' -Source $script:Src.Firewall -Reads 'the nodes (WinRM)' -Applies $script:IsAd -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $domain = [string](Get-AzlProp $Ctx.Infra 'identity.active_directory.domain_fqdn' '')
        $dnsq = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'dnsq' @()))
        $tcp = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'tcp' @()) | Where-Object { $_.p -in 9389, 389, 88 })
        $badDns = @($dnsq | Where-Object { -not $_.ok -or -not @($_.addrs).Count })
        $adws = @($tcp | Where-Object { $_.p -eq 9389 })
        $adwsDown = $adws.Count -gt 0 -and @($adws | Where-Object { $_.ok }).Count -eq 0
        $others = @($tcp | Where-Object { $_.p -ne 9389 -and -not $_.ok })
        if ($badDns.Count) { New-AzlPclResult Failed "$Name cannot resolve $domain with DNS server $(Join-AzlPclList @($badDns | ForEach-Object { $_.server })): $(@($badDns | ForEach-Object { $_.err } | Where-Object { $_ } | Select-Object -First 1)). Azure fails with 'No such host is known' or 'Unable to find a default server with Active Directory Web Services'." "On the node: Resolve-DnsName $domain -Server <dns server>. Fix networking.management.dns_servers and the zone, then run the OS configuration (Dns step)." -Node $Name }
        elseif ($adwsDown) { New-AzlPclResult Failed "$Name cannot reach Active Directory Web Services (TCP 9389) on any domain controller ($(Join-AzlPclList @($adws | ForEach-Object { $_.h })))." "On the node: Test-NetConnection <domain controller> -Port 9389. Open ADWS and the Active Directory Gateway Management Service on the firewall (Learn: Firewall requirements)." -Node $Name }
        elseif ($others.Count) { New-AzlPclResult Warning "$Name cannot reach $(Join-AzlPclList @($others | ForEach-Object { "$($_.h):$($_.p)" })); domain join and the deployment use them." 'Open the ports between the node and the domain controllers.' -Node $Name }
        else { New-AzlPclResult Passed "$Name resolves $domain on every DNS server and reaches ADWS (9389), LDAP (389) and Kerberos (88) on the domain controllers." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'IDN-012' -Category identity -Title 'Nodes are in a workgroup, or joined to the file''s domain in the OU with the LCM user in local Administrators (Learn: 2604 and later)' -Source $script:Src.Install -Reads 'the nodes (WinRM) and Active Directory (LDAP)' -Applies $script:IsAd -Run {
    param($Ctx)
    $lcm = Get-AzlPclLcm $Ctx
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $cs = Get-AzlProp $D.Pcl 'cs'
        $joined = [bool](Get-AzlProp $cs 'partOfDomain' $false)
        $domain = [string](Get-AzlProp $cs 'domain' '')
        if (-not $joined) { New-AzlPclResult Passed "$Name is in the workgroup '$domain'. Learn: if you don't domain join beforehand, the machines are joined to the domain during the deployment." -Node $Name; return }
        if ($domain -ine $lcm.Domain) { New-AzlPclResult Failed "$Name is joined to the domain $domain, not to $($lcm.Domain) of the file." "Remove-Computer -WorkgroupName WORKGROUP -Restart on the node, or fix identity.active_directory.domain_fqdn." -Node $Name; return }
        $problems = @(); $remedy = @()
        $admins = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'admins' @()) | ForEach-Object { [string]$_ })
        $prefix = if ($lcm.Netbios) { $lcm.Netbios } else { $lcm.Domain.Split('.')[0] }
        if (-not (@($admins | Where-Object { $_ -ieq "$prefix\$($lcm.User)" -or $_ -ieq "$($lcm.User)@$($lcm.Domain)" -or $_ -ieq $lcm.User }).Count)) {
            $problems += "the deployment user $prefix\$($lcm.User) is not in the local Administrators group (members: $(Join-AzlPclList $admins))"
            $remedy += "Add-LocalGroupMember -Group 'Administrators' -Member '$prefix\$($lcm.User)'   (on the node)"
        }
        $dj = Get-AzlDomainJoinSpec -Infrastructure $Ctx.Infra
        $dj.Username = $lcm.User; $dj.PasswordRef = $lcm.PasswordRef; $dj.HasAccount = [bool]($lcm.User -and $lcm.PasswordRef)
        if (-not @($dj.DomainControllers).Count) { $dj.DomainControllers = @($lcm.Domain) }
        $query = { param($Request) & $Ctx.Adapter.LdapSearch $Request }
        $ldap = Get-AzlDomainJoinLdapComputer -Spec ([pscustomobject]@{ Name = $Name; DomainJoin = $dj }) -SecretResolver { param($Ref) & $Ctx.Adapter.GetSecret $Ref } -Latch $Ctx.LdapLatch -LdapQuery $query
        if ($ldap.found) {
            if (-not ([string]$ldap.dn).EndsWith($lcm.OuPath, [StringComparison]::OrdinalIgnoreCase)) { $problems += "its computer object $($ldap.dn) is not in the OU $($lcm.OuPath)"; $remedy += "Move-ADObject -Identity '$($ldap.dn)' -TargetPath '$($lcm.OuPath)'" }
        }
        elseif (-not $ldap.checked) { Stop-AzlPclSkip "$Name is joined to $domain but its computer object could not be looked up: $($ldap.error)" 'Run the verification from a host that reaches the domain controllers.' }
        else { $problems += "it is joined to $domain but no computer object named $Name was found ($($ldap.error))" }
        if ($problems) { New-AzlPclResult Failed "$Name is domain-joined (supported before the deployment from version 2604), but $($problems -join '; ')." ($remedy -join '; ') -Node $Name }
        else { New-AzlPclResult Passed "$Name is joined to $domain (supported before the deployment from 2604), its computer object $($ldap.dn) is in the OU and $prefix\$($lcm.User) is a local administrator." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'IDN-013' -Category identity -Title 'Disjoint namespace: a joined node''s DNS suffix matches the domain' -Source $script:Src.CustomAd -Reads 'the nodes (WinRM)' -Applies $script:IsAd -Run {
    param($Ctx)
    $lcm = Get-AzlPclLcm $Ctx
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $cs = Get-AzlProp $D.Pcl 'cs'
        if (-not [bool](Get-AzlProp $cs 'partOfDomain' $false)) { New-AzlPclResult NotApplicable "$Name is in a workgroup: the DNS suffix is set when it joins." -Node $Name; return }
        $primary = [string](Get-AzlProp $D.Pcl 'primarySuffix' '')
        $conn = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'dns' @()) | ForEach-Object { [string](Get-AzlProp $_ 'suffix' '') } | Where-Object { $_ })
        if ($primary -ieq $lcm.Domain -or ($lcm.Domain -in $conn)) { New-AzlPclResult Passed "$Name's primary DNS suffix is $primary; no disjoint namespace." -Node $Name }
        else { New-AzlPclResult Failed "$Name's primary DNS suffix is '$primary' but the Active Directory domain is $($lcm.Domain): a disjoint namespace. Learn: append the DNS suffix to the management adapter of every node (Group Policy can't be used for it)." "Set-DnsClient -InterfaceIndex <management adapter index> -ConnectionSpecificSuffix '$($lcm.Domain)'  then verify: nslookup $Name.$($lcm.Domain)" -Node $Name }
    }
}

Register-AzlPclCheck -Id 'IDN-014' -Category identity -Title 'LCM and local administrator passwords meet Azure''s length and complexity rule' -Source $script:Src.Prereq -Reads 'Key Vault: the passwords (never shown)' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $items = @(@{ Name = 'the local administrator'; Path = 'identity.local_admin.password' })
    if ($Ctx.Identity -eq 'active_directory') { $items += @{ Name = 'the LCM user'; Path = 'identity.active_directory.lcm_user.password' } }
    $bad = @()
    foreach ($i in $items) {
        $ref = [string](Get-AzlProp $Ctx.Infra $i.Path '')
        if (-not $ref) { $bad += "$($i.Name): $($i.Path) is empty"; continue }
        $plain = [string](Invoke-AzlPclAdapter $Ctx GetSecret @($ref))
        Register-AzlPclSecret $plain
        $missing = @(Test-AzlPclPassword -Password $plain)
        $plain = $null
        if ($missing) { $bad += "$($i.Name) ($ref) lacks $(Join-AzlPclList $missing)" }
    }
    if ($bad) { return New-AzlPclResult Failed "Azure's rule (at least 14 characters with a lower case letter, an upper case letter, a digit and a special character) is not met: $($bad -join '; ')." 'Set a new secret in Key Vault (the value is never shown here) and, for the local administrator, on every node.' -Details $bad }
    New-AzlPclResult Passed "$(($items | ForEach-Object { $_.Name }) -join ' and ') meet the length and complexity rule (values not shown)."
}

Register-AzlPclCheck -Id 'IDN-015' -Category identity -Title 'The dedicated local administrator of the file exists on every node, is enabled, is in Administrators and is not the built-in Administrator' -Source "$($script:Src.Local); $($script:Src.Template) (localAdminUserName)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $user = [string](Get-AzlProp $Ctx.Infra 'identity.local_admin.username' '')
    if (-not $user) { return New-AzlPclResult Failed 'identity.local_admin.username is empty.' 'Set identity.local_admin.username to the dedicated local administrator account (for example azl-admin).' }
    if ($user -in 'Administrator', 'Guest') { return New-AzlPclResult Failed "identity.local_admin.username is the built-in $user. The deployment renames the built-in Administrator account, so the account it uses must be a dedicated one." "Create a dedicated local administrator on every node (SConfig option 3, or New-LocalUser and Add-LocalGroupMember -Group Administrators) and set identity.local_admin.username to it." }
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $adm = Get-AzlProp $D.Read 'admin'
        $acct = Get-AzlProp $D.Pcl 'adminAccount'
        $problems = @()
        if (-not $adm -or -not [bool](Get-AzlProp $adm 'ex' $false)) { $problems += "the local user '$user' does not exist" }
        else {
            if (-not [bool](Get-AzlProp $adm 'en' $false)) { $problems += "the local user '$user' is disabled" }
            if (-not [bool](Get-AzlProp $adm 'adm' $false)) { $problems += "'$user' is not in the local Administrators group" }
        }
        if ($acct -and [bool](Get-AzlProp $acct 'builtin' $false)) { $problems += "'$user' is the built-in Administrator account (SID ends in -500), which the deployment renames" }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." "On the node: New-LocalUser -Name $user -Password (Read-Host -AsSecureString); Add-LocalGroupMember -Group Administrators -Member $user   (same name and password on every node; SConfig option 3 does it)" -Node $Name }
        else { New-AzlPclResult Passed "$Name has the dedicated local administrator '$user': enabled, a member of Administrators, not the built-in account." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'IDN-016' -Category identity -Title 'The Key Vault secret that holds the local administrator user name is readable and equals identity.local_admin.username' -Source "$($script:Src.Local); $($script:Src.Prereq) (Local administrator credentials)" -Reads 'Key Vault: the user name secret' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $user = [string](Get-AzlProp $Ctx.Infra 'identity.local_admin.username' '')
    $explicit = [string](Get-AzlProp $Ctx.Infra 'identity.local_admin.username_secret' '')
    $password = ConvertFrom-AzlKeyVaultRef -Reference ([string](Get-AzlProp $Ctx.Infra 'identity.local_admin.password' ''))
    $ref = $explicit
    if (-not $ref -and $password) { $ref = "keyvault://$($password.Vault)/local-admin-username" }
    if (-not $ref) { return New-AzlPclResult NotApplicable 'identity.local_admin.password is not a Key Vault reference, so there is no vault to look for the user name secret in.' }
    $parts = ConvertFrom-AzlKeyVaultRef -Reference $ref
    if (-not $parts) { return New-AzlPclResult Failed "identity.local_admin.username_secret '$ref' is not a keyvault://<vault>/<secret> reference." 'Fix identity.local_admin.username_secret.' }
    $value = $null; $readError = ''
    try { $value = [string](Invoke-AzlPclAdapter $Ctx GetSecret @($ref)) }
    catch { if ($_.Exception.Data['AzlSkip']) { throw }; $readError = $_.Exception.Message }
    $setCommand = "Set-AzKeyVaultSecret -VaultName '$($parts.Vault)' -Name '$($parts.Secret)' -SecretValue (ConvertTo-SecureString '$user' -AsPlainText -Force)"
    if ($readError -or [string]::IsNullOrWhiteSpace($value)) {
        $text = "The secret $($parts.Secret) in vault $($parts.Vault) ($(if ($explicit) { 'named by identity.local_admin.username_secret' } else { 'the default name for the user name next to the password' })) cannot be read$(if ($readError) { ": $readError" } else { ' (it is empty)' })."
        if ($explicit) { return New-AzlPclResult Failed $text "Create the secret with the file's user name: $setCommand   (and grant this identity Key Vault Secrets Officer or Get on secrets)" }
        return New-AzlPclResult Warning "$text Tools that read the user name from the vault (azurelocal-ztp's Add-KeyVaultCredentials.ps1 stores it as local-admin-username) have nothing to read; the file's username is '$user'." "Create it with the file's user name, or name another secret in identity.local_admin.username_secret: $setCommand"
    }
    if ($value.Trim() -cne $user) {
        return New-AzlPclResult Failed "The Key Vault secret $($parts.Vault)/$($parts.Secret) holds the user name '$($value.Trim())', but identity.local_admin.username is '$user'. A tool that takes the user name from the vault signs in as one account while the file (and the nodes) have the other." "Update the secret to the file's user name: $setCommand   -- or, if the vault is right, set identity.local_admin.username to '$($value.Trim())' (and create that account on the nodes)."
    }
    New-AzlPclResult Passed "The Key Vault secret $($parts.Vault)/$($parts.Secret) holds '$user', the same user name as identity.local_admin.username."
}

Register-AzlPclCheck -Id 'IDN-017' -Category identity -Title 'The local administrator password secret opens a session as that account on every node' -Source "$($script:Src.Prereq) (Local administrator credentials identical on all machines)" -Reads 'the nodes (WinRM) and Key Vault' -Run {
    param($Ctx)
    $user = [string](Get-AzlProp $Ctx.Infra 'identity.local_admin.username' '')
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $pw = Get-AzlProp (Get-AzlProp $D.Read 'admin') 'pw' $null
        if ($pw -eq $false) { New-AzlPclResult Failed "The password in Key Vault ($((Get-AzlProp $Ctx.Infra 'identity.local_admin.password' ''))) is not the password of '$user' on $Name, although a session was opened. Learn: the local administrator credentials must be identical on all machines." "Set the same password on every node (net user $user <password> / SConfig option 3) or update the secret." -Node $Name }
        elseif ($pw -eq $true) { New-AzlPclResult Passed "The Key Vault password opened a WinRM session on $Name as $Name\$user and validated against the local account." -Node $Name }
        else { New-AzlPclResult Passed "The Key Vault password opened a WinRM session on $Name as $Name\$user (the local account check did not return)." -Node $Name }
    }
}

# ---- local identity (AD-less)

Register-AzlPclCheck -Id 'IDN-020' -Category identity -Title 'Local identity settings: DNS zone, DNS server configuration, local administrator is not the built-in account' -Source $script:Src.Local -Reads 'the file' -Applies $script:IsLocal -Run {
    param($Ctx)
    $li = Get-AzlProp $Ctx.Infra 'identity.local_identity'
    $zone = [string](Get-AzlProp $li 'dns_zone' ''); $cfg = [string](Get-AzlProp $li 'dns_server_config' '')
    $forwarders = @(ConvertTo-AzlPclList (Get-AzlProp $li 'dns_forwarders' @()))
    $admin = [string](Get-AzlProp $Ctx.Infra 'identity.local_admin.username' '')
    $problems = @()
    if (-not $zone) { $problems += 'identity.local_identity.dns_zone is empty (the zone name establishes the private, authoritative DNS namespace of the cluster)' }
    elseif ($zone -notmatch '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$') { $problems += "dns_zone '$zone' is not a fully qualified domain name" }
    if ($cfg -notin 'use_dns_server', 'use_forwarder') { $problems += "dns_server_config is '$cfg'; it must be use_dns_server (an existing DNS service) or use_forwarder (the internal DNS service with a forwarder)" }
    if ($cfg -eq 'use_forwarder' -and -not $forwarders.Count) { $problems += 'dns_server_config is use_forwarder but dns_forwarders is empty (a forwarder, gateway or DNS server that resolves external names)' }
    if ($cfg -eq 'use_dns_server' -and -not @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.management.dns_servers' @())).Count) { $problems += 'dns_server_config is use_dns_server but networking.management.dns_servers is empty' }
    if ($admin -in 'Administrator', 'Guest' -or -not $admin) { $problems += "identity.local_admin.username is '$admin': Learn says to create a local administrator and not to use the built-in Administrator account" }
    if ($problems) { return New-AzlPclResult Failed ("Local identity: " + ($problems -join '; ') + '.') 'Fix identity.local_identity and identity.local_admin in infrastructure.yml (template create-adless-cluster-external-dns-public-preview: identityProvider LocalIdentity, dnsServerConfig, dnsZones).' -Details $problems }
    New-AzlPclResult Passed "Local identity: zone $zone, $cfg, local administrator '$admin' (not the built-in account)."
}

Register-AzlPclCheck -Id 'IDN-021' -Category identity -Title 'Local identity: static IP addresses only (no DHCP)' -Source $script:Src.Local -Reads 'the file and the nodes (WinRM)' -Applies $script:IsLocal -Run {
    param($Ctx)
    if ([bool](Get-AzlProp $Ctx.Infra 'networking.management.use_dhcp' $false)) { return New-AzlPclResult Failed 'networking.management.use_dhcp is true. Learn: the nodes require static IP addresses and don''t support DHCP with local identity.' 'Set use_dhcp to false and give every node a static management address.' }
    $dhcp = @()
    foreach ($n in $Ctx.Nodes) { $m = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $n; if ($m -and [string]$m.IpAssignment -like 'dhcp*') { $dhcp += [string]$n['name'] } }
    if ($dhcp) { return New-AzlPclResult Failed "These nodes take their management address from DHCP in the file: $($dhcp -join ', '). Learn: local identity doesn't support DHCP." 'Set nodes[].network_adapters[].ip_assignment to static for the management port.' }
    New-AzlPclResult Passed 'The file uses static management addresses only.'
}

Register-AzlPclCheck -Id 'IDN-022' -Category identity -Title 'Local identity: A records for every node and for the system (first infrastructure address) in the zone' -Source $script:Src.Local -Reads 'DNS servers of the file' -Applies {
    param($Ctx)
    if ($Ctx.Identity -ne 'local_identity') { return 'scenario.identity is active_directory.' }
    if ([string](Get-AzlProp $Ctx.Infra 'identity.local_identity.dns_server_config' '') -ne 'use_dns_server') { return 'dns_server_config is use_forwarder: the internal DNS service creates the records.' }
    $true
} -Run {
    param($Ctx)
    $zone = [string](Get-AzlProp $Ctx.Infra 'identity.local_identity.dns_zone' '')
    $servers = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ })
    $pool = Get-AzlProp $Ctx.Infra 'networking.management.infrastructure_pool'
    $first = [string](Get-AzlProp $pool 'start' '')
    if (-not $zone -or -not $servers.Count) { return New-AzlPclResult Failed 'The DNS zone or the DNS servers are not set (IDN-020).' 'Set identity.local_identity.dns_zone and networking.management.dns_servers.' }
    $bad = @()
    $records = @($Ctx.Nodes | ForEach-Object { $mg = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $_; [pscustomobject]@{ Name = "$([string]$_['name']).$zone"; Expected = $(if ($mg) { [string]$mg.IpAddress } else { '' }) } })
    $records += [pscustomobject]@{ Name = "$($Ctx.Cluster).$zone"; Expected = $first }
    foreach ($rec in $records) {
        $r = Resolve-AzlPclRecord -Ctx $Ctx -Name $rec.Name -Server $servers
        foreach ($s in $servers) {
            if ($r.Silent -contains $s) { $bad += "$($rec.Name): DNS server $s did not answer"; continue }
            $a = @($r.Answers[$s])
            if (-not $a.Count) { $bad += "$($rec.Name): no A record on $s (expected $($rec.Expected))" }
            elseif ($rec.Expected -and $rec.Expected -notin $a) { $bad += "$($rec.Name): $($a -join ', ') on $s, expected $($rec.Expected)" }
        }
    }
    if ($bad) { return New-AzlPclResult Failed "DNS records for the local identity deployment are missing or wrong: $($bad -join '; '). Learn: create a Host (A) record for each node and one for the system itself using the first IP address of the range allocated to it." "Add-DnsServerResourceRecordA -ZoneName '$zone' -Name '<name>' -IPv4Address '<address>'  for each record above; verify with Resolve-DnsName <name>.$zone" -Details $bad }
    New-AzlPclResult Passed "$($records.Count) A records ($($Ctx.Nodes.Count) nodes and the system $($Ctx.Cluster).$zone) resolve correctly on every DNS server."
}

Register-AzlPclCheck -Id 'IDN-023' -Category identity -Title 'Local identity: SSH (sshd) is enabled on every node' -Source $script:Src.Local -Reads 'the nodes (WinRM)' -Applies $script:IsLocal -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $ssh = Get-AzlProp $D.Pcl 'sshd'
        if (-not $ssh) { New-AzlPclResult Failed "$Name has no sshd service. Learn: enable SSH on each node for remote access from the Azure portal." "On the node: Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Set-Service sshd -StartupType Automatic; Start-Service sshd" -Node $Name }
        elseif ([string]$ssh.status -ne 'Running') { New-AzlPclResult Failed "On $Name sshd is $($ssh.status) (start type $($ssh.start))." 'Set-Service sshd -StartupType Automatic; Start-Service sshd' -Node $Name }
        else { New-AzlPclResult Passed "sshd is Running on $Name (start type $($ssh.start))." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'IDN-024' -Category identity -Title 'Local identity: the nodes are in a workgroup (the local administrator is IDN-015 to IDN-017)' -Source $script:Src.Local -Reads 'the nodes (WinRM)' -Applies $script:IsLocal -Run {
    param($Ctx)
    $user = [string](Get-AzlProp $Ctx.Infra 'identity.local_admin.username' '')
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $problems = @()
        if ([bool](Get-AzlProp (Get-AzlProp $D.Pcl 'cs') 'partOfDomain' $false)) { $problems += "it is joined to the domain $(Get-AzlProp (Get-AzlProp $D.Pcl 'cs') 'domain' ''); a local identity deployment needs a workgroup machine" }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." 'Remove-Computer -WorkgroupName WORKGROUP -Restart on the node (a local identity deployment needs workgroup machines).' -Node $Name }
        else { New-AzlPclResult Passed "$Name is in a workgroup." -Node $Name }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# NODES
# ---------------------------------------------------------------------------------------------------------------------

# Windows features the Azure Local OS carries and the deployment uses (Hyper-V, clustering, Network ATC with Data Center Bridging, BitLocker).
# A feature the node does not list by this name is a Warning; one that is listed and not installed is Failed.
$script:RequiredFeatures = @(
    [pscustomobject]@{ Name = 'Hyper-V'; Why = 'virtualization (Hyper-V role)' }
    [pscustomobject]@{ Name = 'Failover-Clustering'; Why = 'the cluster' }
    [pscustomobject]@{ Name = 'Data-Center-Bridging'; Why = 'RDMA QoS (DCB) of the storage intent' }
    [pscustomobject]@{ Name = 'NetworkATC'; Why = 'Network ATC, which applies the intents' }
    [pscustomobject]@{ Name = 'BitLocker'; Why = 'BitLocker for the volumes' }
)
$script:PublicDns = @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220')

function Get-AzlPclTargetSolution {
    # The solution version the deployment installs: the run setting, the ZTP handoff, else provisioning.os_version of the file. '' when none is declared.
    param([Parameter(Mandatory)]$Ctx)
    if ($Ctx.Settings.solutionVersion) { return [string]$Ctx.Settings.solutionVersion }
    if ($Ctx.Handoff -and [string]$Ctx.Handoff.VsrVersion -match '^\d+\.\d+\.\d+\.\d+$') { return [string]$Ctx.Handoff.VsrVersion }
    $v = [string](Get-AzlProp $Ctx.Infra 'provisioning.os_version' '')
    if ($v -match '^\d+\.\d+\.\d+\.\d+$') { return $v }
    return ''
}

Register-AzlPclCheck -Id 'NOD-001' -Category nodes -Title 'Every node answers over WinRM to the local administrator from the Key Vault secret' -Source $script:Src.Install -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $d = Get-AzlPclNodeData -Ctx $Ctx -Node $n
        if ($d.Ok) { New-AzlPclResult Passed "$name answered at $($d.Address) with the local administrator (OS $(Get-AzlProp $d.Pcl 'os.build' 'unknown'))." -Node $name }
        else { New-AzlPclResult Failed "$name could not be read: $($d.Error). Learn: the local administrator credentials must be identical on all machines. Every node check below is Skipped for this node." "Check WinRM on the node (Test-WSMan $name), the management address in the file, the firewall, and that the password in Key Vault ($((Get-AzlProp $Ctx.Infra 'identity.local_admin.password' ''))) is the node's local administrator password." -Node $name }
    }
}

Register-AzlPclCheck -Id 'NOD-002' -Category nodes -Title 'Computer name equals the node name in the file and is a valid name (no underscore, 15 characters at most)' -Source $script:Src.Install -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $host_ = [string](Get-AzlProp $D.Pcl 'host' '')
        $problems = @()
        if ($host_ -ine $Name) { $problems += "its computer name is '$host_', the file says '$Name'" }
        if ($Name -match '_') { $problems += "the name contains an underscore (Learn: not supported, it impacts storage path creation)" }
        if ($Name.Length -gt 15) { $problems += "the name is longer than 15 characters (NetBIOS)" }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." "On the node: Rename-Computer -NewName $Name -Restart   (or the OS configuration Hostname step); no underscore, 15 characters at most." -Node $Name }
        else { New-AzlPclResult Passed "The computer name of $Name matches the file and is valid." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NOD-003' -Category nodes -Title 'All nodes run exactly the same OS build' -Source "$script:Learn/deploy/deployment-azure-resource-manager-template?$script:View; $($script:Src.Known) (unsupported-os-version)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $builds = [ordered]@{}
    foreach ($n in $Ctx.Nodes) { $d = Get-AzlPclNodeData -Ctx $Ctx -Node $n; if ($d.Ok) { $builds[[string]$n['name']] = [string](Get-AzlProp $d.Pcl 'os.build' '') } }
    if (-not $builds.Count) { Stop-AzlPclSkip 'No node could be read (NOD-001).' }
    $distinct = @($builds.Values | Where-Object { $_ } | Select-Object -Unique)
    $unread = @($Ctx.Nodes | Where-Object { -not $builds.Contains([string]$_['name']) } | ForEach-Object { [string]$_['name'] })
    if ($distinct.Count -gt 1) { return New-AzlPclResult Failed ("The nodes run different OS builds: " + (($builds.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') + '. Microsoft requires the same exact version on every node; the portal reports Unsupported OS version for some mismatches.') 'Install the same build on every node.' }
    if ($unread) { return New-AzlPclResult Skipped "Every node that could be read runs $($distinct[0]), but $(Join-AzlPclList $unread) could not be read (NOD-001)." }
    New-AzlPclResult Passed "Every node runs OS build $($distinct[0])."
}

Register-AzlPclCheck -Id 'NOD-004' -Category nodes -Title 'The OS build is the one the target solution version ships with' -Source "$script:Learn/whats-new?$script:View; $($script:Src.Known) (unsupported-os-version)" -Reads 'the nodes (WinRM) and the file' -Run {
    param($Ctx)
    $target = Get-AzlPclTargetSolution $Ctx
    if (-not $target) { return New-AzlPclResult NotApplicable 'No target solution version is declared (provisioning.os_version, the run setting solutionVersion or the ZTP handoff), so the OS build is not compared with one.' }
    $line = (($target.Split('.') | Select-Object -First 3) -join '.')
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $build = [string](Get-AzlProp $D.Pcl 'os.build' '')
        $map = ConvertFrom-AzlArmOsBuild -OsBuild $build
        if (-not $map) { New-AzlPclResult Warning "$Name runs OS build $build, which is not in the table of builds seen with a solution version, so it cannot be compared with the target $target. Azure refuses a build it does not accept for new deployments (Unsupported OS version)." "Install the build that ships with solution $target (Learn: solution 12.2610.1004.50 is OS build 26100.33650)." -Node $Name }
        elseif ($map.Version -eq $line) { New-AzlPclResult Passed "$Name's OS build $build ships with solution $($map.Version), the line of the target $target." -Node $Name }
        else { New-AzlPclResult Failed "$Name's OS build $build ships with solution $($map.Version), but the deployment targets $target." "Install the OS build of solution $target on $Name, or change provisioning.os_version." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NOD-005' -Category nodes -Title 'Time: a real NTP source (not the CMOS clock), the same on every node, in step with this host' -Source $script:Src.Install -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $expected = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.ntp_servers' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $now = (& $Ctx.Adapter.Now).ToUniversalTime()
    $peerSets = [ordered]@{}
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $src = [string](Get-AzlProp $D.Pcl 'time.src' (Get-AzlProp $D.Read 'time.src' ''))
        $peers = @(([string](Get-AzlProp $D.Read 'time.peers' (Get-AzlProp $D.Pcl 'time.peers' ''))) -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -replace ',0x[0-9a-fA-F]+$', '').ToLowerInvariant() } | Sort-Object -Unique)
        $peerSets[$Name] = ($peers -join ' ')
        $problems = @(); $warnings = @()
        if ($src -match '(?i)Local CMOS Clock|Free-running System Clock') { $problems += "the time source is '$src' (Learn: validate the machine is not using the local CMOS clock)" }
        $utc = [datetime]::MinValue
        if ([datetime]::TryParse([string](Get-AzlProp $D.Pcl 'utc' ''), [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$utc)) {
            $skew = [math]::Abs(($utc - $now).TotalSeconds)
            if ($skew -gt 300) { $problems += "its clock differs from this host by $([math]::Round($skew)) seconds (Kerberos allows 300)" } elseif ($skew -gt 60) { $warnings += "its clock differs from this host by $([math]::Round($skew)) seconds" }
        }
        if ($expected.Count -and $peers.Count -and @($expected | Where-Object { $_ -notin $peers }).Count) { $warnings += "its NTP peers ($($peers -join ', ')) do not include all of networking.ntp_servers ($($expected -join ', ')); a domain-joined node syncs from the PDC emulator instead" }
        if ($peers.Count -and ([string](Get-AzlProp $D.Read 'time.peers' '')) -notmatch '0x8' -and $src -notmatch 'Local CMOS') { $warnings += 'the NTP peers carry no ,0x8 flag (Learn: w32tm /config /manualpeerlist:"server,0x8" /syncfromflags:manual /update)' }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." 'w32tm /config /manualpeerlist:"<ntp server>,0x8" /syncfromflags:manual /update; w32tm /resync   (or the OS configuration Time step)' -Node $Name }
        elseif ($warnings) { New-AzlPclResult Warning "$Name`: $($warnings -join '; ')." 'w32tm /config /manualpeerlist:"<ntp server>,0x8" /syncfromflags:manual /update' -Node $Name }
        else { New-AzlPclResult Passed "$Name syncs from '$src' with peers $($peers -join ', ') and its clock is in step." -Node $Name }
    }
    if (@($peerSets.Values | Select-Object -Unique).Count -gt 1) { New-AzlPclResult Failed ("The nodes use different NTP configurations: " + (($peerSets.GetEnumerator() | ForEach-Object { "$($_.Key) = [$($_.Value)]" }) -join '; ') + '. Learn: all nodes must be configured with the same, valid NTP server.') 'Configure the same time source on every node.' }
}

Register-AzlPclCheck -Id 'NOD-006' -Category nodes -Title 'DNS servers on the nodes equal the file''s, are the same on every node and are not public resolvers' -Source "$($script:Src.NetPlan) (DNS server considerations)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $expected = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ } | Sort-Object)
    $sets = [ordered]@{}
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $nics = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'nics' @()))
        $withGw = @($nics | Where-Object { @(ConvertTo-AzlPclList (Get-AzlProp $_ 'gw' @())).Count })
        $dnsRows = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'dns' @()))
        $take = if ($withGw.Count) { $withGw | ForEach-Object { $i = $_.idx; $dnsRows | Where-Object { $_.idx -eq $i } } } else { $dnsRows }
        $servers = @($take | ForEach-Object { ConvertTo-AzlPclList $_.servers } | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -notlike '127.*' -and $_ -notlike '169.254.*' } | Select-Object -Unique | Sort-Object)
        $sets[$Name] = ($servers -join ',')
        $public = @($servers | Where-Object { $_ -in $script:PublicDns })
        if ($public) { New-AzlPclResult Failed "$Name uses the public resolver $(Join-AzlPclList $public). Learn: all DNS servers must resolve the on-premises domain; public DNS such as 8.8.8.8 is not supported, and DNS can't be changed after the deployment." 'Set the DNS servers of the domain (networking.management.dns_servers) with the OS configuration Dns step.' -Node $Name }
        elseif ($expected.Count -and (($servers -join ',') -ne ($expected -join ','))) { New-AzlPclResult Failed "$Name uses DNS servers [$($servers -join ', ')], the file says [$($expected -join ', ')]. Learn: the DNS servers of the nodes and of the infrastructure range must be the same, and they can't be changed after the deployment." 'Run the OS configuration (Dns step) so the node uses networking.management.dns_servers.' -Node $Name }
        else { New-AzlPclResult Passed "$Name uses DNS servers $($servers -join ', ') (the file's)." -Node $Name }
    }
    if (@($sets.Values | Select-Object -Unique).Count -gt 1) { New-AzlPclResult Failed ("The nodes use different DNS servers: " + (($sets.GetEnumerator() | ForEach-Object { "$($_.Key) = [$($_.Value)]" }) -join '; ') + '. Learn: DNS servers across all the nodes must be the same.') 'Run the OS configuration (Dns step).' }
}

Register-AzlPclCheck -Id 'NOD-007' -Category nodes -Title 'Required Windows features are installed (Hyper-V, Failover Clustering, Data Center Bridging, Network ATC, BitLocker)' -Source $script:Src.SysReq -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $rows = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'features' @()))
        $off = @($rows | Where-Object { $_.found -and $_.installed -eq $false } | ForEach-Object { $_.n })
        $unknown = @($rows | Where-Object { -not $_.found } | ForEach-Object { $_.n })
        if ($off) { New-AzlPclResult Failed "On $Name these Windows features are not installed: $(Join-AzlPclList $off)." ("Install-WindowsFeature -Name " + ($off -join ',') + " -IncludeManagementTools   (on the node; restart if asked)") -Node $Name }
        elseif ($unknown.Count -eq $rows.Count -and $rows.Count) { New-AzlPclResult Warning "$Name does not list any of the features by name (Get-WindowsFeature is not available), so they were not verified." 'Verify by hand: Get-WindowsFeature Hyper-V, Failover-Clustering, Data-Center-Bridging, NetworkATC, BitLocker.' -Node $Name }
        elseif ($unknown) { New-AzlPclResult Warning "$Name installs $(@($rows | Where-Object { $_.installed }).Count) of the features; it does not list $(Join-AzlPclList $unknown) by that name." 'Verify the feature by hand.' -Node $Name }
        else { New-AzlPclResult Passed "$Name has Hyper-V, Failover Clustering, Data Center Bridging, Network ATC and BitLocker installed." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NOD-008' -Category nodes -Title 'No pending restart' -Source $script:Src.Install -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $r = Get-AzlProp $D.Pcl 'reboot'
        $why = @()
        if ([bool](Get-AzlProp $r 'cbs' $false)) { $why += 'component servicing (RebootPending)' }
        if ([bool](Get-AzlProp $r 'wu' $false)) { $why += 'Windows Update (RebootRequired)' }
        if ([bool](Get-AzlProp $r 'rename' $false)) { $why += 'a computer rename' }
        if (-not $why -and [bool](Get-AzlProp $D.Read 'reboot' $false)) { $why += 'the OS configuration read reports a pending restart' }
        if ($why) { New-AzlPclResult Failed "$Name is waiting for a restart: $(Join-AzlPclList $why). A restart that lands during the deployment fails it." "Restart-Computer -ComputerName $Name -Force   (then run the verification again)" -Node $Name }
        elseif ([bool](Get-AzlProp $r 'files' $false)) { New-AzlPclResult Warning "$Name has PendingFileRenameOperations; this is usually harmless but a restart clears it." "Restart-Computer -ComputerName $Name" -Node $Name }
        else { New-AzlPclResult Passed "$Name has no pending restart." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NOD-009' -Category nodes -Title 'Processors and memory: identical processors on all nodes, at least 32 GB memory, virtualization enabled, at least what the file declares' -Source $script:Src.SysReq -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $sigs = [ordered]@{}; $mems = [ordered]@{}
    $wantCores = [int](Get-AzlProp $Ctx.Infra 'hardware.cpu_cores' 0); $wantGib = [int](Get-AzlProp $Ctx.Infra 'hardware.memory_gib' 0)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $cpu = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'cpu' @()))
        $memBytes = [int64](Get-AzlProp $D.Pcl 'cs.memBytes' 0)
        $sigs[$Name] = (@($cpu | ForEach-Object { "$($_.caption)|$($_.family)|$($_.manufacturer)|$($_.maxClock)|$($_.cores)|$($_.logical)|$($_.threads)" }) -join ';')
        $mems[$Name] = (@(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'mem' @())) | Measure-Object -Sum).Sum
        $problems = @(); $warnings = @()
        $gib = [math]::Round($memBytes / 1GB, 1)
        if ($memBytes -lt (30 * 1GB)) { $problems += "it has $gib GiB memory (Learn: at least 32 GB per machine, with ECC)" }
        if ($cpu.Count -eq 0) { $problems += 'no processor was reported' }
        elseif (@($cpu | Where-Object { -not $_.vt }).Count -and -not [bool](Get-AzlProp $D.Pcl 'cs.hypervisor' $false)) { $problems += 'hardware virtualization (Intel VT or AMD-V) is not enabled in the BIOS' }
        elseif (@($cpu | Where-Object { -not $_.slat }).Count -and $false) { $warnings += 'second-level address translation is not reported' }
        $logical = (@($cpu | ForEach-Object { [int]$_.logical }) | Measure-Object -Sum).Sum
        if ($wantCores -gt 0 -and $logical -gt 0 -and $logical -lt $wantCores) { $warnings += "it has $logical logical processors, the file declares hardware.cpu_cores $wantCores" }
        if ($wantGib -gt 0 -and $gib -lt ($wantGib * 0.9)) { $warnings += "it has $gib GiB memory, the file declares hardware.memory_gib $wantGib" }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." 'Fix the hardware or the BIOS setting (Learn: System requirements, Machine and storage requirements).' -Node $Name }
        elseif ($warnings) { New-AzlPclResult Warning "$Name`: $($warnings -join '; ')." 'Check hardware.cpu_cores and hardware.memory_gib in the file against the node.' -Node $Name }
        else { New-AzlPclResult Passed "$Name has $gib GiB memory, $logical logical processors and virtualization enabled." -Node $Name }
    }
    if (@($sigs.Values | Select-Object -Unique).Count -gt 1) { New-AzlPclResult Failed ("The processors differ between the nodes (Learn: Caption, Family, Manufacturer, MaxClockSpeed, NumberOfEnabledCore, NumberOfLogicalProcessors and ThreadCount must be identical): " + (($sigs.GetEnumerator() | ForEach-Object { "$($_.Key) = [$($_.Value)]" }) -join '; ')) 'Use machines with the same processor model and the same core settings in the BIOS.' }
    if (@($mems.Values | Select-Object -Unique).Count -gt 1) { New-AzlPclResult Warning ("The installed memory differs between the nodes: " + (($mems.GetEnumerator() | ForEach-Object { "$($_.Key) = $([math]::Round($_.Value / 1GB, 1)) GiB" }) -join ', ') + '. The hardware validator warns about inconsistent memory.') 'Use the same memory on every node.' }
}

Register-AzlPclCheck -Id 'NOD-010' -Category nodes -Title 'Secure Boot on, TPM 2.0 present and ready, the same BIOS version on all nodes' -Source "$($script:Src.SysReq); $($script:Src.EnvChecker) (hardware validator)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $bios = [ordered]@{}
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $fw = Get-AzlProp $D.Pcl 'fw'
        $bios[$Name] = [string](Get-AzlProp $fw 'biosVersion' '')
        $problems = @(); $warnings = @()
        $sb = Get-AzlProp $fw 'secureBoot' $null
        if ($sb -eq $false) { $problems += 'Secure Boot is off (Learn: must be present and turned on)' } elseif ($null -eq $sb) { $warnings += 'Secure Boot could not be read (not a UEFI boot?)' }
        $present = Get-AzlProp $fw 'tpmPresent' $null; $ready = Get-AzlProp $fw 'tpmReady' $null; $spec = [string](Get-AzlProp $fw 'tpmSpec' '')
        if ($present -eq $false) { $problems += 'no TPM is present (Learn: TPM 2.0 must be present and turned on)' }
        elseif ($ready -eq $false) { $problems += 'the TPM is present but not ready' }
        elseif ($spec -and $spec -notmatch '^2\.0') { $problems += "the TPM is version $spec, not 2.0" }
        elseif ($null -eq $present) { $warnings += 'the TPM could not be read' }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." 'Enable Secure Boot and TPM 2.0 in the BIOS (Dell: Redfish / iDRAC BIOS settings; hardware.bios_during_provisioning in the file).' -Node $Name }
        elseif ($warnings) { New-AzlPclResult Warning "$Name`: $($warnings -join '; ')." 'Verify Secure Boot and the TPM by hand (Confirm-SecureBootUEFI; Get-Tpm).' -Node $Name }
        else { New-AzlPclResult Passed "$Name has Secure Boot on and a ready TPM $spec (BIOS $($bios[$Name]))." -Node $Name }
    }
    if (@($bios.Values | Where-Object { $_ } | Select-Object -Unique).Count -gt 1) { New-AzlPclResult Warning ("The BIOS version differs between the nodes: " + (($bios.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join ', ') + '. Learn: all hardware components should use the same firmware versions (the hardware validator warns).') 'Update the BIOS (and firmware) of the nodes to the OEM baseline of the Solution Builder Extension.' }
}

Register-AzlPclCheck -Id 'NOD-011' -Category nodes -Title 'Boot disk is at least 200 GB' -Source $script:Src.SysReq -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $boot = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'phys' @()) | Where-Object { $_.boot })
        if (-not $boot.Count) { New-AzlPclResult Warning "$Name reported no boot disk." 'Verify by hand: Get-Disk | Where-Object IsBoot.' -Node $Name; return }
        $size = [int64]$boot[0].size
        if ($size -lt 200e9) { New-AzlPclResult Failed "The boot disk of $Name is $([math]::Round($size / 1e9)) GB. Learn: a minimum of 200 GB (400 GB or more recommended for large memory instances)." 'Use a boot drive of at least 200 GB.' -Node $Name }
        else { New-AzlPclResult Passed "The boot disk of $Name is $([math]::Round($size / 1e9)) GB." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NOD-012' -Category nodes -Title 'The node is not already a member of a cluster' -Source "$($script:Src.Install) (clean the machines before deployment)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $c = Get-AzlProp $D.Pcl 'cluster'
        $evidence = @(ConvertTo-AzlPclList (Get-AzlProp $D.Read 'stor.cluster.why' @()))
        if ([string](Get-AzlProp $c 'svc' '') -eq 'Running' -and [string](Get-AzlProp $c 'name' '')) { New-AzlPclResult Failed "$Name is already a member of the cluster '$(Get-AzlProp $c 'name' '')' (the cluster service is running). A deployment needs clean machines." 'Clear-ClusterNode -Force on the node, then clean the drives (the OS configuration ClearStorage step); or reinstall the OS.' -Node $Name }
        elseif ([bool](Get-AzlProp $D.Read 'stor.cluster.deployed' $false)) { New-AzlPclResult Failed "$Name shows evidence of an earlier deployment: $($evidence -join '; ')." 'Reinstall the OS, or clear the cluster configuration and the drives (the OS configuration ClearStorage step) before deploying again.' -Node $Name }
        else { New-AzlPclResult Passed "$Name is not part of a cluster and shows no sign of an earlier deployment." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NOD-013' -Category nodes -Title 'The Environment Checker module is not installed on the nodes' -Source "$($script:Src.EnvChecker) (Uninstall environment checker)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $ec = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'ec' @()))
        if ($ec.Count) { New-AzlPclResult Failed "$Name has the module AzStackHci.EnvironmentChecker installed ($((@($ec | ForEach-Object { $_.version })) -join ', ')). Learn: uninstall it from all Azure Local machines before you begin the deployment, to avoid conflicts. (This gate runs the validators from this host, not on the nodes.)" "On the node: Remove-Module AzStackHci.EnvironmentChecker -Force; Get-Module AzStackHci.EnvironmentChecker -ListAvailable | Where-Object {`$_.Path -like `"*`$(`$_.Version)*`"} | Uninstall-Module -Force" -Node $Name }
        else { New-AzlPclResult Passed "$Name has no Environment Checker module installed." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NOD-014' -Category nodes -Title 'C:\SBE matches the file: nothing there when no SBE is configured, the package when one is' -Source "$($script:Src.Install); $($script:Src.Known) (sbe-referenced-but-not-configured)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $sbeVersion = [string](Get-AzlProp $Ctx.Infra 'hardware.sbe.version' '')
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $held = @(ConvertTo-AzlPclList (Get-AzlProp $D.Read 'sbeHeld' @()) | ForEach-Object { [string]$_ })
        if (-not $sbeVersion) {
            if ($held.Count) { New-AzlPclResult Failed "No SBE is configured (hardware.sbe has no version) but C:\SBE on $Name holds: $($held -join ', '). Azure finds the package, validates it against the solution version and can fail at step 0.60 (InvokeEnvironmentChecker) with ErrorUnvalidatedSolutionAndSbeCombination. The toolkit never deletes C:\SBE." "On the node: Remove-Item C:\SBE\* -Recurse -Force   (only if you mean to deploy without an SBE; or configure hardware.sbe.version and family for the package)" -Node $Name }
            else { New-AzlPclResult Passed "$Name has no SBE package in C:\SBE and none is configured: the deployment goes without a Solution Builder Extension." -Node $Name }
        }
        else {
            if ($held.Count) { New-AzlPclResult Passed "$Name holds $($held.Count) file(s) in C:\SBE for the configured SBE $sbeVersion ($($held -join ', '))." -Node $Name }
            else { New-AzlPclResult Warning "SBE $sbeVersion is configured but C:\SBE on $Name is empty. Learn: place the SBE content at C:\SBE so that it is detected and used during the deployment." 'Run the OS configuration with hardware.sbe.delivery winrm_copy or node_pull, or copy the package to C:\SBE yourself.' -Node $Name }
        }
    }
}

Register-AzlPclCheck -Id 'NOD-015' -Category nodes -Title 'The configured SBE is validated by the OEM with the target solution version (Azure step 0.60)' -Source "$($script:Src.Known) (unvalidated-solution-sbe-combination)" -Reads 'the SBE discovery catalog (file) and the nodes (WinRM)' -Applies {
    param($Ctx)
    if ([string](Get-AzlProp $Ctx.Infra 'hardware.sbe.version' '')) { $true } else { 'No SBE is configured (hardware.sbe has no version): the SBE is opt-in.' }
} -Run {
    param($Ctx)
    $version = [string](Get-AzlProp $Ctx.Infra 'hardware.sbe.version' ''); $family = [string](Get-AzlProp $Ctx.Infra 'hardware.sbe.family' '')
    $source = Resolve-AzlArmSbeCatalogFile ([pscustomobject]@{ Settings = $Ctx.Settings; Infra = $Ctx.Infra })
    if (-not $source.File) { Stop-AzlPclSkip $source.Reason 'Set hardware.sbe.bundle_path or the setting sbeCatalogPath to the folder with SBE_Discovery_*.xml.' }
    try { $catalog = @(Read-AzlArmSbeCatalog -Path $source.File) }
    catch { return New-AzlPclResult Warning "The SBE discovery catalog $($source.File) could not be read ($($_.Exception.Message)), so SBE $version was not compared with the solution version." 'Copy SBE_Discovery_*.xml again from the OEM download.' }
    $solution = Get-AzlPclTargetSolution $Ctx
    $derived = $false
    if (-not $solution) {
        $builds = @($Ctx.Nodes | ForEach-Object { $d = Get-AzlPclNodeData -Ctx $Ctx -Node $_; if ($d.Ok) { [string](Get-AzlProp $d.Pcl 'os.build' '') } } | Where-Object { $_ } | Select-Object -Unique)
        $maps = @($builds | ForEach-Object { ConvertFrom-AzlArmOsBuild -OsBuild $_ } | Where-Object { $_ })
        if ($maps.Count -eq 1 -and $builds.Count -eq 1) { $solution = $maps[0].Version; $derived = $true }
    }
    if (-not $solution) { return New-AzlPclResult Warning "The solution version could not be determined, so SBE $version was not compared with the catalog." 'Set deployment.solution_version (for example 12.2610.1004.50) or provisioning.os_version.' }
    $r = Test-AzlArmSbeSolution -Catalog $catalog -Family $family -Version $version -Solution $solution
    $shown = if ($derived) { "$solution.x" } else { $solution }
    if ($r.Status -eq 'NotListed') { return New-AzlPclResult Warning "SBE $version (family $family) is not listed in $(Split-Path -Leaf $source.File), so it was not compared with solution $shown." 'Use the SBE_Discovery_*.xml that came with the package, and check hardware.sbe.family and hardware.sbe.version.' }
    if ($r.Status -eq 'Validated') { return New-AzlPclResult Passed "SBE $version ($family) is validated with solution $($r.MatchedPattern); this deployment uses $shown." }
    $patterns = Join-AzlPclList @($r.Entry.SolutionPatterns | ForEach-Object { $_.Pattern })
    $fix = if (@($r.ValidatedVersions).Count) { "Use SBE $(@($r.ValidatedVersions)[0]) (validated for family $family and solution $shown) and set hardware.sbe.version and bundle_path." } else { "No SBE of family $family in the catalog is validated with solution $shown; use a newer catalog or a solution version SBE $version is validated for ($patterns)." }
    New-AzlPclResult Failed "SBE $version is validated for solution $patterns, this deployment uses $shown (catalog $(Split-Path -Leaf $source.File)). Azure would stop the Validate at step 0.60 (InvokeEnvironmentChecker) with ErrorUnvalidatedSolutionAndSbeCombination, after about 13 minutes." $fix
}

# ---------------------------------------------------------------------------------------------------------------------
# NETWORK
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlPclIntent {
    <#
    .SYNOPSIS
        The intents as the ARM Validate will send them (intentList of the parameter set: OS adapter names, networkDirect, jumboPacket),
        else, when the parameters cannot be generated, as the file states them. Each: Name, Traffic, Adapters, NetworkDirect, Jumbo.
    #>
    param([Parameter(Mandatory)]$Ctx)
    $set = Get-AzlPclParameterSet $Ctx
    if ($set.Set -and $set.Set.Parameters.Contains('intentList')) {
        return @(foreach ($i in @($set.Set.Parameters['intentList'])) {
                [pscustomobject]@{ Name = [string]$i['name']; Traffic = @($i['trafficType'] | ForEach-Object { ([string]$_).ToLowerInvariant() }); Adapters = @($i['adapter'] | ForEach-Object { [string]$_ })
                    NetworkDirect = [string]$i['adapterPropertyOverrides']['networkDirect']; Jumbo = [string]$i['adapterPropertyOverrides']['jumboPacket']; FromArm = $true }
            })
    }
    return @(foreach ($i in @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.intents' @()))) {
            $traffic = @(ConvertTo-AzlPclList $i['traffic'] | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $direct = Get-AzlProp $i 'overrides.adapter.network_direct' $null
            [pscustomobject]@{ Name = [string]$i['name']; Traffic = $traffic; Adapters = @(ConvertTo-AzlPclList $i['adapters'] | ForEach-Object { [string]$_ })
                NetworkDirect = $(if ($null -ne $direct) { $(if ([bool]$direct) { 'Enabled' } else { 'Disabled' }) } elseif ($traffic -contains 'storage') { 'Enabled' } else { 'Disabled' })
                Jumbo = [string](Get-AzlProp $i 'overrides.adapter.jumbo_packet' $(if ($traffic -contains 'storage') { 9014 } else { 1514 })); FromArm = $false }
        })
}

function Get-AzlPclNic {
    param($Data, [string]$Name)
    @(ConvertTo-AzlPclList (Get-AzlProp $Data.Pcl 'nics' @()) | Where-Object { [string]$_.n -ieq $Name }) | Select-Object -First 1
}

Register-AzlPclCheck -Id 'NET-001' -Category network -Title 'Every adapter of every intent exists on every node under the same name, with link up' -Source "$($script:Src.HostNet); $($script:Src.NetPlan) (Decision 6, 7)" -Reads 'the nodes (WinRM) and the file' -Run {
    param($Ctx)
    $intents = @(Get-AzlPclIntent $Ctx)
    if (-not $intents.Count) { return New-AzlPclResult Failed 'networking.intents is empty: the deployment needs at least one network intent.' 'Define the intents in infrastructure.yml (networking.intents).' }
    $allNames = @($intents | ForEach-Object { $_.Adapters } | ForEach-Object { $_ })
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $problems = @()
        foreach ($i in $intents) {
            foreach ($a in $i.Adapters) {
                $nic = Get-AzlPclNic $D $a
                if (-not $nic) { $problems += "adapter '$a' of intent $($i.Name) does not exist (the node has: $(Join-AzlPclList @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'nics' @()) | ForEach-Object { $_.n })))" }
                elseif ([string]$nic.st -ne 'Up') { $problems += "adapter '$a' of intent $($i.Name) is $($nic.st), not Up" }
            }
        }
        $dup = @($allNames | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($dup) { $problems += "adapter(s) $(Join-AzlPclList $dup) are in more than one intent" }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; '). Network ATC takes the adapter names from the deployment, so they must exist and be identical on every node." 'Rename the adapters on the nodes (the OS configuration run maps them by MAC) or fix networking.intents[].adapters; connect the cables of the adapters that are not Up.' -Node $Name }
        else { New-AzlPclResult Passed "$Name has all $($allNames.Count) intent adapters, each Up." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NET-002' -Category network -Title 'Link speed: at least 10 Gbps for storage, adapters of an intent and of the same name on all nodes are symmetric' -Source "$($script:Src.HostNet); $($script:Src.NetPlan) (Decision 6)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $intents = @(Get-AzlPclIntent $Ctx)
    $seen = @{}
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $problems = @(); $warnings = @()
        foreach ($i in $intents) {
            $speeds = @()
            foreach ($a in $i.Adapters) {
                $nic = Get-AzlPclNic $D $a
                if (-not $nic) { continue }
                $gbps = [math]::Round([double]$nic.speed / 1e9, 1)
                $speeds += $gbps
                $key = "$a"
                if (-not $seen.ContainsKey($key)) { $seen[$key] = @{} }
                $seen[$key][$Name] = "$gbps Gbps, $($nic.desc)"
                if ($i.Traffic -contains 'storage' -and $gbps -lt 10) { $problems += "storage adapter '$a' runs at $gbps Gbps (Learn: at least 10 Gbps for RDMA or iSCSI storage traffic)" }
                elseif ($gbps -lt 1) { $problems += "adapter '$a' runs at $gbps Gbps" }
                elseif ($gbps -lt 10) { $warnings += "adapter '$a' of $($i.Name) runs at $gbps Gbps (10 Gbps recommended; 1 Gbps is accepted for management and compute with RDMA disabled)" }
            }
            if (@($speeds | Select-Object -Unique).Count -gt 1) { $problems += "the adapters of intent $($i.Name) have different speeds ($($speeds -join ', ') Gbps); Switch Embedded Teaming needs symmetric adapters (same make, model, speed and configuration)" }
        }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." 'Use adapters of the same speed in an intent and 10 Gbps or more for storage (25 GbE recommended).' -Node $Name }
        elseif ($warnings) { New-AzlPclResult Warning "$Name`: $($warnings -join '; ')." 'Use 10 Gbps or faster adapters where the hardware allows.' -Node $Name }
        else { New-AzlPclResult Passed "$Name's intent adapters have symmetric link speeds ($(Join-AzlPclList @($intents | ForEach-Object { $i = $_; $i.Adapters | ForEach-Object { $n = Get-AzlPclNic $D $_; if ($n) { "$($_)=$([math]::Round([double]$n.speed / 1e9, 1))G" } } })))." -Node $Name }
    }
    $mismatch = @($seen.Keys | Where-Object { @($seen[$_].Values | Select-Object -Unique).Count -gt 1 })
    foreach ($k in $mismatch) { New-AzlPclResult Failed "Adapter '$k' differs between the nodes: $(($seen[$k].GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join '; '). Learn (hardware validator): all network adapters must have consistent properties on every node." 'Use the same adapter model and speed in the same slot on every node.' }
}

Register-AzlPclCheck -Id 'NET-003' -Category network -Title 'RDMA matches the intent: off for management and compute, on and capable for storage' -Source "$($script:Src.NetPlan) (Decision 6: Network Direct); $($script:Src.HostNet)" -Reads 'the nodes (WinRM) and the ARM intent list' -Run {
    param($Ctx)
    $intents = @(Get-AzlPclIntent $Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $problems = @(); $warnings = @(); $notes = @()
        foreach ($i in $intents) {
            $storage = $i.Traffic -contains 'storage'
            foreach ($a in $i.Adapters) {
                $nic = Get-AzlPclNic $D $a
                if (-not $nic) { continue }
                $capable = [bool]$nic.rdmaCapable; $op = $nic.rdmaOp
                if ($i.NetworkDirect -eq 'Enabled') {
                    if (-not $capable) { $problems += "intent $($i.Name) asks for RDMA (networkDirect Enabled) but adapter '$a' is not RDMA capable" }
                    elseif (-not $storage -and $op -ne $true) { $problems += "intent $($i.Name) carries no storage traffic but asks for RDMA, and RDMA is not operational on adapter '$a'; Azure's network validation fails on exactly this" }
                    elseif ($storage -and $op -eq $false) { $warnings += "RDMA is not operational on storage adapter '$a' yet (Network ATC enables it with the intent)" }
                }
                else { $notes += "$($i.Name)/$a RDMA off" }
            }
        }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." 'Learn: RDMA belongs to the storage traffic. Set networking.intents[].overrides.adapter.network_direct to false for management and compute intents (the intent builder sends it off by default), or use RDMA-capable adapters for the storage intent.' -Node $Name }
        elseif ($warnings) { New-AzlPclResult Warning "$Name`: $($warnings -join '; ')." 'Verify after the deployment: Get-NetAdapterRdma.' -Node $Name }
        else { New-AzlPclResult Passed "$Name`: RDMA is off where the intent says so ($($notes.Count) adapters) and the storage intent adapters are RDMA capable." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NET-004' -Category network -Title 'Jumbo frames only for storage; values valid; the same MTU on all nodes' -Source "$($script:Src.NetPlan) (Decision 6: Jumbo Packets)" -Reads 'the ARM intent list and the nodes (WinRM)' -Run {
    param($Ctx)
    $intents = @(Get-AzlPclIntent $Ctx)
    $valid = '1514', '4088', '9014'
    $problems = @(); $warnings = @()
    foreach ($i in $intents) {
        if ($i.Jumbo -notin $valid) { $problems += "intent $($i.Name) has jumboPacket $($i.Jumbo); the options are $($valid -join ', ')" }
        elseif ($i.Traffic -notcontains 'storage' -and $i.Jumbo -ne '1514') { $warnings += "intent $($i.Name) (no storage traffic) has jumboPacket $($i.Jumbo); Learn keeps jumbo frames for the storage traffic and the default 1514 elsewhere unless your OEM says otherwise" }
        elseif ($i.Traffic -contains 'storage' -and [int]$i.Jumbo -lt 9014) { $warnings += "storage intent $($i.Name) has jumboPacket $($i.Jumbo); Learn recommends an MTU of 9216 on the switch and 9014 on the host for RDMA storage traffic" }
    }
    $mtus = @{}
    foreach ($n in $Ctx.Nodes) {
        $d = Get-AzlPclNodeData -Ctx $Ctx -Node $n
        if (-not $d.Ok) { continue }
        foreach ($i in $intents) { foreach ($a in $i.Adapters) { $nic = Get-AzlPclNic $d $a; if ($nic) { if (-not $mtus.ContainsKey($a)) { $mtus[$a] = @{} }; $mtus[$a][[string]$n['name']] = [string]$nic.jumbo } } }
    }
    foreach ($a in $mtus.Keys) { if (@($mtus[$a].Values | Select-Object -Unique).Count -gt 1) { $warnings += "adapter '$a' has different jumbo packet values on the nodes ($(($mtus[$a].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))" } }
    if ($problems) { return New-AzlPclResult Failed ($problems -join '; ') 'Use 1514, 4088 or 9014 (networking.intents[].overrides.adapter.jumbo_packet).' -Details $problems }
    if ($warnings) { return New-AzlPclResult Warning ($warnings -join '; ') 'Set the same MTU on the physical switch ports end to end (9216 on the switch is the usual pairing with 9014 on the host).' -Details $warnings }
    New-AzlPclResult Passed "Jumbo frames follow Learn for $($intents.Count) intent(s): $(Join-AzlPclList @($intents | ForEach-Object { "$($_.Name)=$($_.Jumbo)" }))."
}

Register-AzlPclCheck -Id 'NET-005' -Category network -Title 'Management network: one management IP and one default gateway per node, matching the file' -Source "$($script:Src.NetPlan) (Node and cluster IP assignment)" -Reads 'the nodes (WinRM) and the file' -Run {
    param($Ctx)
    $subnet = [string](Get-AzlProp $Ctx.Infra 'networking.management.subnet' ''); $gateway = [string](Get-AzlProp $Ctx.Infra 'networking.management.gateway' '')
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $nics = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'nics' @()))
        $withGw = @($nics | Where-Object { @(ConvertTo-AzlPclList $_.gw).Count })
        $mgmt = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $Node
        $expected = if ($mgmt) { [string]$mgmt.IpAddress } else { '' }
        $problems = @(); $warnings = @()
        $gws = @($withGw | ForEach-Object { ConvertTo-AzlPclList $_.gw } | Select-Object -Unique)
        if ($withGw.Count -gt 1) { $problems += "$($withGw.Count) physical adapters have a default gateway ($(Join-AzlPclList @($withGw | ForEach-Object { $_.n }))); the network validation fails when more than one does" }
        elseif ($withGw.Count -eq 0) { $warnings += 'no physical adapter has a default gateway (the management intent may already hold it on a virtual adapter)' }
        if ($gateway -and $gws.Count -and $gateway -notin $gws) { $problems += "the default gateway is $($gws -join ', '), the file says $gateway" }
        $ips = @($nics | ForEach-Object { ConvertTo-AzlPclList $_.ips } | ForEach-Object { [string]$_ })
        if ($expected -and $ips.Count -and $expected -notin $ips) { $warnings += "the node does not hold its management address $expected (it has $($ips -join ', ')); expected when the address is still to be assigned" }
        $multi = @($nics | Where-Object { @(ConvertTo-AzlPclList $_.ips).Count -gt 1 })
        if ($multi) { $problems += "adapter(s) $(Join-AzlPclList @($multi | ForEach-Object { $_.n })) have more than one IPv4 address (the network validator expects one)" }
        if ($expected -and $subnet -and -not (Test-AzlPclInCidr $expected $subnet)) { $problems += "the file puts the management address $expected outside the management subnet $subnet" }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." 'Configure one management IP and one default gateway per node (SConfig, or the OS configuration Network step); remove the gateway from adapters that are not the management one.' -Node $Name }
        elseif ($warnings) { New-AzlPclResult Warning "$Name`: $($warnings -join '; ')." 'Check the management address and gateway.' -Node $Name }
        else { New-AzlPclResult Passed "$Name has one default gateway ($($gws -join ', ')) and its management address $expected." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NET-006' -Category network -Title 'Infrastructure IP pool: at least 6 contiguous addresses in the management subnet, free of nodes, gateway and active hosts' -Source "$($script:Src.NetPlan) (Management IP pool); $($script:Src.EnvChecker) (network validator)" -Reads 'the file and the nodes (ICMP from the nodes)' -Run {
    param($Ctx)
    $subnet = [string](Get-AzlProp $Ctx.Infra 'networking.management.subnet' ''); $gateway = [string](Get-AzlProp $Ctx.Infra 'networking.management.gateway' '')
    $pool = Get-AzlProp $Ctx.Infra 'networking.management.infrastructure_pool'
    $start = [string](Get-AzlProp $pool 'start' ''); $end = [string](Get-AzlProp $pool 'end' '')
    if ([bool](Get-AzlProp $Ctx.Infra 'networking.management.use_dhcp' $false) -and -not $start) { }
    $range = @(Get-AzlPclRange $start $end)
    $problems = @()
    if (-not $range.Count) { return New-AzlPclResult Failed "networking.management.infrastructure_pool ($start - $end) is not a valid IPv4 range. Learn: a range of at least six consecutive, available addresses on the management subnet." 'Set infrastructure_pool.start and end.' }
    if ($range.Count -lt 6) { $problems += "the pool has $($range.Count) addresses; Learn needs at least six consecutive ones (the cluster IP, the Arc Resource Bridge VM and its components)" }
    if ($subnet) { $outside = @($range | Where-Object { -not (Test-AzlPclInCidr $_ $subnet) }); if ($outside.Count) { $problems += "$($outside.Count) pool address(es) are outside the management subnet $subnet (the pool must be on the same subnet as the nodes)" } }
    $nodeIps = @($Ctx.Nodes | ForEach-Object { $m = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $_; if ($m) { [string]$m.IpAddress } } | Where-Object { $_ })
    $clash = @($range | Where-Object { $_ -in $nodeIps -or $_ -eq $gateway })
    if ($clash) { $problems += "the pool contains $(Join-AzlPclList $clash), which a node or the gateway uses (the pool must not include the node IPs)" }
    $active = @()
    foreach ($n in $Ctx.Nodes) {
        $d = Get-AzlPclNodeData -Ctx $Ctx -Node $n
        if (-not $d.Ok) { continue }
        foreach ($p in @(ConvertTo-AzlPclList (Get-AzlProp $d.Pcl 'ping' @()))) { if ($p.ok -and $p.a -in $range) { $active += "$($p.a) (answers ping from $([string]$n['name']))" } }
    }
    $active = @($active | Select-Object -Unique)
    if ($active) { $problems += "address(es) of the pool are in use by active hosts: $($active -join '; ') (the network validator fails when a host answers on the reserved range)" }
    if ($problems) { return New-AzlPclResult Failed "Infrastructure pool $start - $end`: $($problems -join '; ')." 'Choose a free contiguous range on the management subnet; reserve it in DHCP and IPAM; exclude it from the DHCP scope.' -Details $problems }
    $unread = @($Ctx.Nodes | Where-Object { -not (Get-AzlPclNodeData -Ctx $Ctx -Node $_).Ok })
    if ($unread.Count) { return New-AzlPclResult Skipped "The pool $start - $end ($($range.Count) addresses) is well formed, but no node could be read to test that nothing answers on it ($(Join-AzlPclList @($unread | ForEach-Object { $_['name'] }))): NOD-001." }
    New-AzlPclResult Passed "The pool $start - $end has $($range.Count) contiguous addresses on $subnet; none is a node, the gateway or an active host."
}

Register-AzlPclCheck -Id 'NET-007' -Category network -Title 'DNS servers: at least one, not public, not inside the instance, not in the reserved Kubernetes ranges' -Source "$($script:Src.NetPlan) (DNS server considerations)" -Reads 'the file' -Run {
    param($Ctx)
    $dns = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ })
    if ([bool](Get-AzlProp $Ctx.Infra 'networking.management.use_dhcp' $false)) { return New-AzlPclResult NotApplicable 'networking.management.use_dhcp is true: DHCP supplies the DNS servers.' }
    if ($Ctx.Identity -eq 'local_identity' -and [string](Get-AzlProp $Ctx.Infra 'identity.local_identity.dns_server_config' '') -eq 'use_forwarder' -and -not $dns.Count) { return New-AzlPclResult NotApplicable 'The internal DNS service of Azure Local is used (use_forwarder).' }
    $problems = @()
    if (-not $dns.Count) { $problems += 'networking.management.dns_servers is empty' }
    $nodeIps = @($Ctx.Nodes | ForEach-Object { $m = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $_; if ($m) { [string]$m.IpAddress } })
    $pool = Get-AzlProp $Ctx.Infra 'networking.management.infrastructure_pool'
    $range = @(Get-AzlPclRange ([string](Get-AzlProp $pool 'start' '')) ([string](Get-AzlProp $pool 'end' '')))
    foreach ($s in $dns) {
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($s, [ref]$ip)) { $problems += "DNS server '$s' is not an IP address"; continue }
        if ($s -in $script:PublicDns) { $problems += "$s is a public resolver (Learn: public DNS such as 8.8.8.8 isn't supported; the servers must resolve the on-premises domain)" }
        if ($s -in $nodeIps -or $s -in $range) { $problems += "$s is inside the Azure Local instance (a node or the infrastructure pool): at least one DNS server must run outside the cluster" }
        if ((Test-AzlPclInCidr $s '10.96.0.0/24') -or (Test-AzlPclInCidr $s '10.244.0.0/16')) { $problems += "$s is inside the Arc resource bridge service or pod range (10.96.0.0/24, 10.244.0.0/16)" }
    }
    if ($problems) { return New-AzlPclResult Failed ("DNS servers: " + ($problems -join '; ') + '. Learn: the DNS servers can''t be changed after the deployment.') 'Fix networking.management.dns_servers before the first deployment.' -Details $problems }
    New-AzlPclResult Passed "DNS servers $($dns -join ', ') are IP addresses outside the instance and outside the reserved ranges (that they run outside the cluster is the operator's to confirm if they are VMs on it)."
}

Register-AzlPclCheck -Id 'NET-008' -Category network -Title 'No node, pool, gateway, DNS, proxy or logical network address in the reserved Kubernetes ranges (10.96.0.0/24 and 12, 10.244.0.0/16)' -Source "$($script:Src.NetPlan) (Reserved IP ranges to avoid)" -Reads 'the file' -Run {
    param($Ctx)
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $Ctx.Nodes) { $m = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $n; if ($m -and $m.IpAddress) { $items.Add(@('node IP', [string]$m.IpAddress)) } }
    $pool = Get-AzlProp $Ctx.Infra 'networking.management.infrastructure_pool'
    foreach ($k in 'start', 'end') { $v = [string](Get-AzlProp $pool $k ''); if ($v) { $items.Add(@("pool $k", $v)) } }
    $gw = [string](Get-AzlProp $Ctx.Infra 'networking.management.gateway' ''); if ($gw) { $items.Add(@('default gateway', $gw)) }
    foreach ($d in @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.management.dns_servers' @()))) { $items.Add(@('DNS server', [string]$d)) }
    $proxy = [string](Get-AzlProp $Ctx.Infra 'networking.outbound.proxy.url' '')
    if ($proxy -match '//(?<h>\d+\.\d+\.\d+\.\d+)') { $items.Add(@('proxy server', $Matches.h)) }
    $fail = @(); $warn = @()
    foreach ($i in $items) {
        if (Test-AzlPclInCidr $i[1] '10.96.0.0/24') { $fail += "$($i[0]) $($i[1]) is in 10.96.0.0/24 (the Arc resource bridge service range, new deployments from 2610)" }
        elseif (Test-AzlPclInCidr $i[1] '10.96.0.0/12') { $warn += "$($i[0]) $($i[1]) is in 10.96.0.0/12 (the service range of deployments created before 2610 and of AKS)" }
        if (Test-AzlPclInCidr $i[1] '10.244.0.0/16') { $fail += "$($i[0]) $($i[1]) is in 10.244.0.0/16 (the pod range, all deployments)" }
    }
    foreach ($l in @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.logical_networks' @()))) {
        $p = [string](Get-AzlProp $l 'address_prefix' '')
        if ($p -and ((Test-AzlPclCidrOverlap $p '10.244.0.0/16') -or (Test-AzlPclCidrOverlap $p '10.96.0.0/12'))) { $warn += "logical network $(Get-AzlProp $l 'name' '') ($p) overlaps 10.244.0.0/16 or 10.96.0.0/12" }
    }
    if ($fail) { return New-AzlPclResult Failed ("Addresses in the ranges Arc resource bridge reserves: " + ($fail -join '; ') + '. Traffic to them never reaches the real destination; deployment fails or has connectivity problems that are hard to trace.') 'Move the addresses out of 10.96.0.0/24 and 10.244.0.0/16 (safe: 192.168.x.x, 172.16-31.x.x, 10.0-95.x.x).' -Details $fail }
    if ($warn) { return New-AzlPclResult Warning ($warn -join '; ') 'Outside 10.96.0.0/24 this is accepted for a new 2610 deployment, but AKS on Azure Local still reserves 10.96.0.0/12.' -Details $warn }
    New-AzlPclResult Passed "$($items.Count) addresses checked; none is in the Arc resource bridge or AKS ranges."
}

Register-AzlPclCheck -Id 'NET-009' -Category network -Title 'Storage network plan: valid unique VLANs, distinct subnets, at least two storage adapters, switchless limits' -Source "$($script:Src.NetPlan) (Decision 5)" -Reads 'the file' -Run {
    param($Ctx)
    $arch = $Ctx.Architecture
    $problems = @(); $warnings = @()
    $nets = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.storage.networks' @()))
    $vlans = @($nets | ForEach-Object { [string](Get-AzlProp $_ 'vlan_id' '') } | Where-Object { $_ })
    foreach ($v in $vlans) { if ([int]$v -lt 1 -or [int]$v -gt 4094) { $problems += "storage VLAN $v is not between 1 and 4094" } }
    if (@($vlans | Select-Object -Unique).Count -ne $vlans.Count) { $problems += "storage VLAN IDs are not unique ($($vlans -join ', ')); Learn: use two unique VLAN IDs for the storage networks (Network ATC defaults 711 and 712)" }
    $subnets = @($nets | ForEach-Object { [string](Get-AzlProp $_ 'subnet' '') } | Where-Object { $_ })
    $mgmt = [string](Get-AzlProp $Ctx.Infra 'networking.management.subnet' '')
    for ($i = 0; $i -lt $subnets.Count; $i++) {
        if ($mgmt -and (Test-AzlPclCidrOverlap $subnets[$i] $mgmt)) { $problems += "storage subnet $($subnets[$i]) overlaps the management subnet $mgmt" }
        for ($j = $i + 1; $j -lt $subnets.Count; $j++) { if (Test-AzlPclCidrOverlap $subnets[$i] $subnets[$j]) { $problems += "storage subnets $($subnets[$i]) and $($subnets[$j]) overlap" } }
    }
    $intents = @(Get-AzlPclIntent $Ctx)
    $storageAdapters = @($intents | Where-Object { $_.Traffic -contains 'storage' } | ForEach-Object { $_.Adapters } | ForEach-Object { $_ })
    if ($arch -in 's2d', 'hybrid') {
        if ($Ctx.Nodes.Count -gt 1 -and $storageAdapters.Count -eq 0) { $problems += 'no intent carries storage traffic (Storage Spaces Direct needs a storage intent)' }
        elseif ($Ctx.Nodes.Count -gt 1 -and $storageAdapters.Count -eq 1) { $warnings += 'the storage intent has one adapter: no fault tolerance (Learn recommends at least two ports per intent)' }
    }
    if ([string](Get-AzlProp $Ctx.Infra 'scenario.storage_connectivity' 'switched') -eq 'switchless') {
        if ($Ctx.Nodes.Count -gt 4) { $problems += "switchless storage supports 1 to 4 nodes, the file has $($Ctx.Nodes.Count)" }
        if ($Ctx.Nodes.Count -ge 3 -and [bool](Get-AzlProp $Ctx.Infra 'networking.storage.auto_ip' $true)) { $problems += "with $($Ctx.Nodes.Count) switchless nodes Storage Auto IP must be disabled and every storage IP defined in the template (the number of storage subnets is N x (N - 1) = $($Ctx.Nodes.Count * ($Ctx.Nodes.Count - 1)))" }
    }
    if ($arch -in 'san', 'hybrid' -and -not @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.cluster_networks' @())).Count -and $arch -eq 'san') { $warnings += 'a disaggregated (SAN) design has no networking.cluster_networks (the cluster networks run on standalone ports, VLANs 1711 and 1712 by default)' }
    if ($problems) { return New-AzlPclResult Failed ($problems -join '; ') 'Fix networking.storage and networking.intents (Learn: Network considerations for cloud deployments, Decision 5).' -Details $problems }
    if ($warnings) { return New-AzlPclResult Warning ($warnings -join '; ') 'Review the storage network design.' -Details $warnings }
    New-AzlPclResult Passed "Storage plan: $($storageAdapters.Count) storage adapter(s), VLANs $(if ($vlans) { $vlans -join ', ' } else { 'Network ATC defaults (711, 712)' }), $(if ($subnets) { $subnets -join ', ' } else { 'Storage Auto IP' })."
}

Register-AzlPclCheck -Id 'NET-010' -Category network -Title 'Nodes reach the required Azure endpoints on 443 (directly or through the proxy) without TLS inspection' -Source "$($script:Src.Firewall); $($script:Src.EnvChecker) (connectivity validator, RDY-001, covers all endpoints)" -Reads 'the nodes (HTTPS probes)' -Applies {
    param($Ctx)
    if ([string](Get-AzlProp $Ctx.Infra 'scenario.connectivity' 'connected') -eq 'disconnected') { 'scenario.connectivity is disconnected: there is no outbound path to Azure.' } else { $true }
} -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $rows = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'https' @()))
        if (-not $rows.Count) { New-AzlPclResult Skipped "$Name returned no endpoint probe." -Node $Name; return }
        $bad = @($rows | Where-Object { -not $_.ok })
        if ($bad.Count) {
            $tls = @($bad | Where-Object { [string]$_.err -match 'trust|certificate|SSL|TLS' })
            $text = ($bad | ForEach-Object { "$($_.u): $($_.err)" }) -join '; '
            New-AzlPclResult Failed "$Name cannot reach $($bad.Count) of $($rows.Count) required endpoints on 443: $text.$(if ($tls.Count) { ' A certificate or TLS error points at SSL inspection, which Azure Local does not support on its endpoints.' })" "On the node: Test-NetConnection <host> -Port 443. Open the endpoints on the firewall or the proxy (Learn: Firewall requirements for Azure Local), turn SSL inspection off for them, and run the Environment Checker connectivity validator (RDY-001)." -Node $Name
        }
        else { New-AzlPclResult Passed "$Name reaches all $($rows.Count) endpoints on 443$(if ([string](Get-AzlProp $Ctx.Infra 'networking.outbound.proxy.url' '')) { ' through the proxy' }) with a trusted certificate." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NET-011' -Category network -Title 'Proxy settings follow Learn: no PAC, no .local, no credentials, no CIDR in the bypass list; node, cluster and pool covered' -Source "$($script:Src.NetPlan) (Proxy requirements)" -Reads 'the file' -Applies {
    param($Ctx)
    if ([string](Get-AzlProp $Ctx.Infra 'scenario.outbound_path' 'direct') -in 'proxy', 'proxy_arc_gateway') { $true } else { 'scenario.outbound_path does not use an enterprise proxy.' }
} -Run {
    param($Ctx)
    $url = [string](Get-AzlProp $Ctx.Infra 'networking.outbound.proxy.url' '')
    $bypass = @(ConvertTo-AzlPclList (Get-AzlProp $Ctx.Infra 'networking.outbound.proxy.bypass' @()) | ForEach-Object { [string]$_ })
    $problems = @(); $warnings = @()
    if (-not $url) { return New-AzlPclResult Failed 'scenario.outbound_path uses a proxy but networking.outbound.proxy.url is empty.' 'Set networking.outbound.proxy.url (http://host:port).' }
    if ($url -notmatch '^https?://[^/@\s]+(:\d+)?/?$') { $problems += "the proxy URL '$url' must be http(s)://host[:port] without credentials or a path (Learn: only non-authenticated proxies are supported)" }
    if ($url -match '\.pac(\?|$)|wpad') { $problems += 'a Proxy Auto-Configuration (PAC) file is not supported' }
    if ($url -match '\.local(:\d+)?/?$') { $problems += 'a proxy endpoint with a .local domain is not supported' }
    foreach ($b in $bypass) { if ($b -match '/\d{1,2}$') { $problems += "the bypass entry '$b' uses CIDR notation, which is not supported for registration (use 192.168.1.* wildcard notation)" } }
    $nodeIps = @($Ctx.Nodes | ForEach-Object { $m = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $_; if ($m) { [string]$m.IpAddress } })
    $subnetWild = [string](Get-AzlProp $Ctx.Infra 'networking.management.subnet' '') -replace '\.\d+/\d+$', '.*'
    $covered = { param($ip) ($ip -in $bypass) -or ($subnetWild -in $bypass) -or (@($bypass | Where-Object { $_ -like '*.*' -and $_.EndsWith('*') -and $ip -like $_ }).Count -gt 0) }
    $missing = @($nodeIps | Where-Object { -not (& $covered $_) })
    if ($missing) { $warnings += "the bypass list does not cover the node address(es) $(Join-AzlPclList $missing) (Learn: include each machine's IP, the cluster IP and the infrastructure network, or bypass the whole subnet such as $subnetWild)" }
    if ($Ctx.Nodes.Count -and -not @($bypass | Where-Object { $_ -ieq $Ctx.Cluster -or $_ -like "*$($Ctx.Cluster)*" }).Count) { $warnings += "the bypass list does not name the cluster $($Ctx.Cluster) (Learn: include the NetBIOS name of each machine and of the cluster)" }
    if ($problems) { return New-AzlPclResult Failed ("Proxy: " + ($problems -join '; ') + '.') 'Fix networking.outbound.proxy in infrastructure.yml (Learn: Proxy requirements).' -Details $problems }
    if ($warnings) { return New-AzlPclResult Warning ($warnings -join '; ') 'Complete the bypass list.' -Details $warnings }
    New-AzlPclResult Passed "The proxy $url is a plain http(s) endpoint and its bypass list covers the nodes and the cluster."
}

Register-AzlPclCheck -Id 'NET-012' -Category network -Title 'Nodes reach every DNS server (TCP 53) and the default gateway (ICMP)' -Source "$($script:Src.NetPlan) (DNS server and Management IP pool considerations)" -Reads 'the nodes (probes)' -Run {
    param($Ctx)
    $gateway = [string](Get-AzlProp $Ctx.Infra 'networking.management.gateway' '')
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $dns = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'tcp' @()) | Where-Object { $_.p -eq 53 })
        $down = @($dns | Where-Object { -not $_.ok })
        $gw = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'ping' @()) | Where-Object { $_.a -eq $gateway })
        $problems = @(); $warnings = @()
        if ($dns.Count -and $down.Count -eq $dns.Count) { $problems += "no DNS server answers on TCP 53 ($(Join-AzlPclList @($down | ForEach-Object { $_.h })))" }
        elseif ($down.Count) { $warnings += "DNS server(s) $(Join-AzlPclList @($down | ForEach-Object { $_.h })) do not answer on TCP 53" }
        if ($gw.Count -and -not $gw[0].ok) { $warnings += "the default gateway $gateway does not answer ping; Learn: the environment checker tests ICMP from the management IP pool to the gateway, so the gateway must allow ICMP from the management subnet" }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." 'Open DNS (53) from the management subnet to the DNS servers.' -Node $Name }
        elseif ($warnings) { New-AzlPclResult Warning "$Name`: $($warnings -join '; ')." 'Allow ICMP echo on the gateway for the management subnet.' -Node $Name }
        else { New-AzlPclResult Passed "$Name reaches the DNS servers on TCP 53 and the gateway $gateway." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NET-013' -Category network -Title 'Intent adapters use the OEM driver, not the inbox Microsoft driver' -Source "$($script:Src.NetPlan) (Decision 6); $($script:Src.Install)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $intents = @(Get-AzlPclIntent $Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $inbox = @()
        foreach ($i in $intents) { foreach ($a in $i.Adapters) { $nic = Get-AzlPclNic $D $a; if ($nic -and [string]$nic.drvProv -match '^Microsoft') { $inbox += "$a ($($nic.desc), driver $($nic.drvVer))" } } }
        if ($inbox) { New-AzlPclResult Failed "$Name uses the inbox Microsoft driver on: $($inbox -join '; '). Learn: install the latest driver from your OEM or network interface vendor before configuring networking; important capabilities may not surface with the default Microsoft drivers (and inbox drivers are not used for iSCSI)." 'Install the OEM driver (pnputil /add-driver <inf> /install, or the OS configuration Drivers step from an SBE), then restart.' -Node $Name }
        else { New-AzlPclResult Passed "$Name's intent adapters use vendor drivers." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'NET-014' -Category network -Title 'No Network ATC intent and no stray virtual switch left from an earlier attempt' -Source "$($script:Src.Known) (vmswitch-not-bound)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $intents = @(Get-AzlPclIntent $Ctx)
    $mine = @($intents | ForEach-Object { $_.Adapters } | ForEach-Object { $_ })
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $vms = Get-AzlProp $D.Pcl 'vms'
        $atc = @(ConvertTo-AzlPclList (Get-AzlProp $vms 'intents' @()))
        $switches = @(ConvertTo-AzlPclList (Get-AzlProp $vms 'switches' @()))
        if ($atc.Count) { New-AzlPclResult Failed "$Name already has Network ATC intent(s): $($atc -join ', '). The deployment creates the intents; existing ones conflict (an earlier deployment, or manual intents)." "On the node: Get-NetIntent | Remove-NetIntent  (only on a machine that is being redeployed)" -Node $Name; return }
        if ($switches.Count) {
            $nics = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'nics' @()))
            $uses = @($switches | Where-Object { $sw = $_; @($nics | Where-Object { $mine -contains $_.n -and (@($sw.uplinks) -contains $_.desc) }).Count })
            if ($uses.Count) { New-AzlPclResult Warning "$Name has virtual switch(es) $(Join-AzlPclList @($uses | ForEach-Object { $_.n })) on intent adapters. A switch left by a failed validation makes the next one fail ('not bound to the management virtual switch'); a switch pre-created for a DHCP management setup (Learn) is fine." 'If it is a leftover: Remove-VMSwitch -Name <name> -Force; Restart-Service DeviceManagementService (Learn known issue steps).' -Node $Name; return }
        }
        New-AzlPclResult Passed "$Name has no Network ATC intent and no virtual switch on the intent adapters." -Node $Name
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# STORAGE
# ---------------------------------------------------------------------------------------------------------------------

$script:IsS2d = { param($Ctx) if ($Ctx.Architecture -in 's2d', 'hybrid') { $true } else { 'scenario.storage_architecture is san: the nodes use SAN LUNs only (disaggregated).' } }
$script:IsSanDeclared = { param($Ctx) if ($Ctx.Architecture -in 'san', 'hybrid') { $true } else { 'scenario.storage_architecture is s2d: no SAN is declared.' } }

function Get-AzlPclSanDisk {
    # The FC and iSCSI disks a node sees (the OS configuration Read, section san.disks).
    param($Data)
    @(ConvertTo-AzlPclList (Get-AzlProp $Data.Read 'san.disks' @()) | Where-Object { $_ })
}

function Get-AzlPclSanView {
    # Per node: Disks, Groups (the same UniqueId more than once), plus Declared and Visible for the run.
    param([Parameter(Mandatory)]$Ctx)
    if ($Ctx.Cache.ContainsKey('SanView')) { return $Ctx.Cache['SanView'] }
    $nodes = [ordered]@{}; $unread = @()
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $d = Get-AzlPclNodeData -Ctx $Ctx -Node $n
        if (-not $d.Ok) { $unread += $name; continue }
        $disks = @(Get-AzlPclSanDisk $d)
        $dups = @($disks | Group-Object { [string]$_.uid } | Where-Object { $_.Count -gt 1 })
        $nodes[$name] = [pscustomobject]@{ Name = $name; Data = $d; Disks = $disks; Duplicates = $dups }
    }
    $view = [pscustomobject]@{ Nodes = $nodes; Unread = $unread; Declared = ($Ctx.Architecture -in 'san', 'hybrid'); Visible = (@($nodes.Values | Where-Object { $_.Disks.Count }).Count -gt 0) }
    $Ctx.Cache['SanView'] = $view
    return $view
}

function Format-AzlPclDuplicateEvidence {
    # The text Azure's Test-Cluster prints for it, built from what the node showed.
    param($NodeView)
    @(foreach ($g in $NodeView.Duplicates) {
            $numbers = @($g.Group | ForEach-Object { $_.n }) -join ', '
            "Disks $numbers on $($NodeView.Name) present the same LUN (UniqueId $($g.Name), $($g.Count) paths seen as $($g.Count) disks): 'Two disks have been found on node $($NodeView.Name) that cannot be distinguished from one another' (Azure's Test-Cluster, List Disks)"
        })
}

Register-AzlPclCheck -Id 'STO-001' -Category storage -Title 'Storage Spaces Direct: at least two data disks of at least 500 GB per node, the same number and size on every node' -Source $script:Src.SysReq -Reads 'the nodes (WinRM)' -Applies $script:IsS2d -Run {
    param($Ctx)
    $declared = Get-AzlProp $Ctx.Infra 'hardware.drives.capacity'
    $summary = [ordered]@{}
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $phys = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'phys' @()))
        $data = @($phys | Where-Object { -not $_.boot -and -not $_.system -and [string]$_.bus -notin 'USB', 'SD', 'MMC', 'Fibre Channel', 'iSCSI', 'FibreChannel', 'Virtual', 'File Backed Virtual' })
        $big = @($data | Where-Object { [int64]$_.size -ge 475e9 })
        $summary[$Name] = "$($data.Count) disks: " + ((@($data | ForEach-Object { "$([math]::Round([int64]$_.size / 1e9))GB $($_.media)/$($_.bus)" } | Sort-Object)) -join ', ')
        $want = [int](Get-AzlProp $declared 'count' 0)
        if ($big.Count -lt 2) { New-AzlPclResult Failed "$Name has $($big.Count) data disk(s) of at least 500 GB ($($data.Count) non-boot local disks). Learn: at least two disks per machine with a minimum capacity of 500 GB." 'Install the missing drives, or check that RAID-mode controllers are in HBA/pass-through mode (RAID controllers are not supported).' -Node $Name }
        elseif ($want -gt 0 -and $data.Count -ne $want) { New-AzlPclResult Warning "$Name has $($data.Count) local data disks, the file declares hardware.drives.capacity.count $want." 'Check the drive count in the file against the node.' -Node $Name }
        else { New-AzlPclResult Passed "$Name has $($data.Count) local data disks ($($big.Count) of them 500 GB or more)." -Node $Name }
    }
    $distinct = @($summary.Values | Select-Object -Unique)
    if ($distinct.Count -gt 1) { New-AzlPclResult Failed ("The nodes do not have the same drives (Learn: same number and type of drives, with the same capacity and firmware, on every server): " + (($summary.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join ' | ')) 'Use the same drive configuration on every node.' }
}

Register-AzlPclCheck -Id 'STO-002' -Category storage -Title 'Local data disks are clean: poolable, no partitions, nothing but the boot disk in use' -Source "$($script:Src.Install) (Clean all the non-OS drives); $($script:Src.EnvChecker) (hardware validator)" -Reads 'the nodes (WinRM)' -Applies $script:IsS2d -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $phys = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'phys' @()))
        $data = @($phys | Where-Object { -not $_.boot -and -not $_.system -and [string]$_.bus -notin 'USB', 'SD', 'MMC', 'Fibre Channel', 'iSCSI', 'FibreChannel', 'Virtual', 'File Backed Virtual' })
        $dirty = @($data | Where-Object { -not $_.canPool -or $_.parts -gt 0 -or ([string]$_.style -notin 'RAW', '') })
        if ($dirty) {
            $list = @($dirty | ForEach-Object { "disk $($_.num) $($_.name) ($([math]::Round([int64]$_.size / 1e9)) GB, $(if ($_.parts -gt 0) { "$($_.parts) partition(s), $($_.style)" } else { $_.style }), canPool=$($_.canPool)$(if ($_.reason) { ", $($_.reason)" }))" })
            New-AzlPclResult Failed "$Name has $($dirty.Count) local disk(s) that Storage Spaces Direct cannot take as they are: $($list -join '; '). Learn: clean all the non-OS drives of each machine before the deployment." "The OS configuration ClearStorage step cleans them (os_configuration.clear_storage; it never touches SAN LUNs), or on the node, destroying the data on them: Get-PhysicalDisk | Where-Object CanPool -eq `$false | ... Clear-Disk -Number <n> -RemoveData -RemoveOEM -Confirm:`$false" -Node $Name -Details $list
        }
        else { New-AzlPclResult Passed "All $($data.Count) local data disks of $Name are clean and poolable." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'STO-003' -Category storage -Title 'No storage pool or virtual disk left on the nodes' -Source "$($script:Src.EnvChecker) (hardware validator: No storage pools exist, Critical)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $pools = @(ConvertTo-AzlPclList (Get-AzlProp $D.Pcl 'pools' @()))
        $vd = [int](Get-AzlProp $D.Pcl 'vdisks' 0)
        if ($pools.Count -or $vd) { New-AzlPclResult Failed "$Name has $($pools.Count) storage pool(s) ($(Join-AzlPclList $pools)) and $vd virtual disk(s). The hardware validator fails when a storage pool exists: the deployment creates the pool." "The OS configuration ClearStorage step, or on the node (destroys the data): Get-StoragePool -IsPrimordial `$false | Set-StoragePool -IsReadOnly `$false; Get-VirtualDisk | Remove-VirtualDisk -Confirm:`$false; Get-StoragePool -IsPrimordial `$false | Remove-StoragePool -Confirm:`$false" -Node $Name }
        else { New-AzlPclResult Passed "$Name has no storage pool or virtual disk." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'STO-004' -Category storage -Title 'The SAN the file declares is the SAN the nodes see (no undeclared SAN LUNs)' -Source "$($script:Src.ExtStorage); $($script:Src.InstallDa)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $view = Get-AzlPclSanView $Ctx
    if ($view.Unread.Count -and -not $view.Nodes.Count) { Stop-AzlPclSkip 'No node could be read (NOD-001).' }
    $type = $Ctx.SanType
    $bus = @{ fibre_channel = 'Fibre Channel'; iscsi = 'iSCSI' }
    if (-not $view.Declared) {
        if (-not $view.Visible) { return New-AzlPclResult Passed 'The file declares no SAN (scenario.storage_architecture s2d) and no node sees a Fibre Channel or iSCSI LUN.' }
        $lines = @(foreach ($nv in $view.Nodes.Values) { if ($nv.Disks.Count) { "$($nv.Name) sees $($nv.Disks.Count) SAN disk(s) ($((@($nv.Disks | ForEach-Object { $_.bus } | Select-Object -Unique)) -join ', '), UniqueIds $((@($nv.Disks | ForEach-Object { $_.uid } | Select-Object -First 4)) -join ', '))" } })
        $evidence = @(foreach ($nv in $view.Nodes.Values) { Format-AzlPclDuplicateEvidence $nv })
        $text = "SAN LUNs are visible but the file declares no SAN (scenario.storage_architecture is $($Ctx.Architecture), no storage.san): $($lines -join '; ')."
        if ($evidence.Count) { $text += " With the paths not claimed by MPIO: $($evidence -join ' | '). This is the failure Azure's Test-Cluster returned on the lab." }
        return New-AzlPclResult Failed $text "Declare the SAN in the file (scenario.storage_architecture hybrid or san and storage.san.type fibre_channel or iscsi) and run the OS configuration (Mpio and SanVerify steps); or, for a design without a SAN, unmask/unzone the LUNs from the nodes (Learn hybrid: don't zone FC HBA WWNs until after the deployment) or disable the HBA for the deployment window." -Details $lines
    }
    if (-not $type) { return New-AzlPclResult Failed 'The file declares a SAN architecture but storage.san.type is empty.' 'Set storage.san.type to fibre_channel or iscsi.' }
    $wrong = @(foreach ($nv in $view.Nodes.Values) { $other = @($nv.Disks | Where-Object { [string]$_.bus -ne $bus[$type] }); if ($other.Count) { "$($nv.Name) sees $($other.Count) $($other[0].bus) disk(s) although the file says $type" } })
    if ($wrong) { return New-AzlPclResult Failed ($wrong -join '; ') 'Fix storage.san.type or the cabling/zoning.' -Details $wrong }
    if ($Ctx.Architecture -eq 'san' -and -not $view.Visible) { return New-AzlPclResult Failed 'The file declares a disaggregated (SAN) design but no node sees a SAN LUN. Learn: the LUNs must be visible, unmasked to the HBAs and left RAW, before the Arc registration.' "Collect the WWPNs (Get-InitiatorPort), have the SAN administrator zone and unmask the infrastructure (250 GB) and performance history (20 GB) LUNs to every node, configure MPIO, rescan (Update-HostStorageCache) and run the verification again. Do not initialize the disks." }
    if ($Ctx.Architecture -eq 'hybrid' -and -not $view.Visible) { return New-AzlPclResult Passed "Hybrid design: no SAN LUN is visible before the deployment, which is what Learn asks for (attach the external storage after the deployment; for FC, don't zone the HBA WWNs until then)." }
    New-AzlPclResult Passed "The $type SAN the file declares is visible on $(@($view.Nodes.Values | Where-Object { $_.Disks.Count }).Count) of $($view.Nodes.Count) node(s)."
}

Register-AzlPclCheck -Id 'STO-005' -Category storage -Title 'Multipath I/O is enabled on the nodes' -Source "$($script:Src.ExtStorage) (Step 1.1: Verify Multipath I/O)" -Reads 'the nodes (WinRM)' -Applies {
    param($Ctx)
    if ($Ctx.Architecture -in 'san', 'hybrid') { return $true }
    $true
} -Run {
    param($Ctx)
    $view = Get-AzlPclSanView $Ctx
    if ($view.Unread.Count -and -not $view.Nodes.Count) { Stop-AzlPclSkip 'No node could be read (NOD-001).' }
    if (-not $view.Declared -and -not $view.Visible) { return New-AzlPclResult NotApplicable 'No SAN is declared and none is visible: MPIO is not needed.' }
    foreach ($nv in $view.Nodes.Values) {
        $state = [string](Get-AzlProp $nv.Data.Read 'san.feature' '')
        if ($state -eq 'Enabled') { New-AzlPclResult Passed "MPIO (MultipathIO) is Enabled on $($nv.Name)." -Node $nv.Name }
        else { New-AzlPclResult Failed "MPIO is '$state' on $($nv.Name). Learn: Azure Local 2604 and later enables Multipath I/O by default; verify it is enabled on all nodes. Without MPIO each path to a LUN is a separate disk." "Enable-WindowsOptionalFeature -Online -FeatureName MultipathIO -NoRestart   then restart the node (rolling), or the OS configuration Mpio step" -Node $nv.Name }
    }
}

Register-AzlPclCheck -Id 'STO-006' -Category storage -Title 'The array''s vendor and product are claimed by MPIO (MSDSM hardware ID registered)' -Source "$($script:Src.ExtStorage) (Step 2.2: Register vendor device with MSDSM); config/san/msdsm-vendors.json" -Reads 'the nodes (WinRM) and config/san/msdsm-vendors.json' -Applies $script:IsSanDeclared -Run {
    param($Ctx)
    $array = Get-AzlProp $Ctx.Infra 'storage.san.array'
    $vendor = [string](Get-AzlProp $array 'vendor' ''); $model = [string](Get-AzlProp $array 'model' '')
    if (-not $vendor) { return New-AzlPclResult Failed 'storage.san.array.vendor is empty, so the MPIO hardware ID of the array cannot be derived.' 'Set storage.san.array.vendor and model.' }
    $row = Get-AzlSanVendor -Vendor $vendor -Model $model
    if (-not $row) { Stop-AzlPclSkip "The array '$vendor $model' is not in config/san/msdsm-vendors.json, so its MSDSM hardware ID is not known to this tool." "Add the vendor and product ID to config/san/msdsm-vendors.json (Learn: Connect an external storage array to Azure Local, Step 2.2) or accept this check with -AcceptSkipped STO-006 after verifying Get-MSDSMSupportedHw on every node." }
    $view = Get-AzlPclSanView $Ctx
    if ($view.Unread.Count -and -not $view.Nodes.Count) { Stop-AzlPclSkip 'No node could be read (NOD-001).' }
    foreach ($nv in $view.Nodes.Values) {
        $have = @(ConvertTo-AzlPclList (Get-AzlProp $nv.Data.Read 'san.hw' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $missing = @($row.Hardware | Where-Object { "$($_.vendorId)|$($_.productId)".ToLowerInvariant() -notin $have })
        if (-not $missing) { New-AzlPclResult Passed "$($nv.Name): MSDSM claims $(Join-AzlPclList @($row.Hardware | ForEach-Object { "$($_.vendorId) $($_.productId)" }))." -Node $nv.Name; continue }
        $cmds = @($missing | ForEach-Object { "mpclaim -n -i -d `"$(([string]$_.vendorId).PadRight(8))$(([string]$_.productId).PadRight(16))`"   (or New-MSDSMSupportedHW -VendorId '$($_.vendorId)' -ProductId '$($_.productId)')" })
        New-AzlPclResult Failed "On $($nv.Name) MPIO does not claim $(Join-AzlPclList @($missing | ForEach-Object { "$($_.vendorId) $($_.productId)" })) (MSDSM supports: $(if ($have.Count) { $have -join ', ' } else { 'nothing registered' })). Unclaimed, every path to a LUN is a separate disk and Azure's Test-Cluster fails with 'Two disks ... cannot be distinguished'." ($cmds -join '; ') -Node $nv.Name
    }
}

Register-AzlPclCheck -Id 'STO-007' -Category storage -Title 'Each SAN LUN is visible exactly once by UniqueId on every node (no duplicate paths)' -Source "$($script:Src.ExtStorage) (Step 7: Verify SAN Disks); Azure Test-Cluster 'List Disks'" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $view = Get-AzlPclSanView $Ctx
    if ($view.Unread.Count -and -not $view.Nodes.Count) { Stop-AzlPclSkip 'No node could be read (NOD-001).' }
    if (-not $view.Visible) { return New-AzlPclResult NotApplicable 'No node sees a Fibre Channel or iSCSI LUN.' }
    foreach ($nv in $view.Nodes.Values) {
        if (-not $nv.Disks.Count) { New-AzlPclResult Passed "$($nv.Name) sees no SAN disk." -Node $nv.Name; continue }
        if ($nv.Duplicates.Count) {
            $e = @(Format-AzlPclDuplicateEvidence $nv)
            New-AzlPclResult Failed "$($nv.Name): $($nv.Duplicates.Count) LUN(s) are seen more than once: $($e -join ' | ')." "Have MPIO claim the array (STO-006: mpclaim -n -i -d `"<vendor padded to 8><product padded to 16>`"), restart the node, and run Update-HostStorageCache; or mask (unpresent) the extra paths, or, for a hybrid design, unzone the HBA until after the deployment (STO-011)." -Node $nv.Name -Details $e
        }
        else { New-AzlPclResult Passed "$($nv.Name) sees $($nv.Disks.Count) SAN LUN(s), each once by UniqueId." -Node $nv.Name }
    }
}

Register-AzlPclCheck -Id 'STO-008' -Category storage -Title 'Every node sees the same LUNs, with the same LUN IDs' -Source "$($script:Src.ExtStorage) (Step 4: consistent LUN IDs; Step 7)" -Reads 'the nodes (WinRM)' -Run {
    param($Ctx)
    $view = Get-AzlPclSanView $Ctx
    if ($view.Unread.Count -and -not $view.Nodes.Count) { Stop-AzlPclSkip 'No node could be read (NOD-001).' }
    if (-not $view.Visible) { return New-AzlPclResult NotApplicable 'No node sees a Fibre Channel or iSCSI LUN.' }
    $sets = [ordered]@{}; $luns = @{}
    foreach ($nv in $view.Nodes.Values) {
        $sets[$nv.Name] = @($nv.Disks | ForEach-Object { [string]$_.uid } | Sort-Object -Unique)
        foreach ($disk in $nv.Disks) { if (-not $luns.ContainsKey([string]$disk.uid)) { $luns[[string]$disk.uid] = @{} }; $luns[[string]$disk.uid][$nv.Name] = [string]$disk.lun }
    }
    $problems = @()
    $all = @($sets.Values | ForEach-Object { $_ } | Select-Object -Unique)
    foreach ($nv in $sets.Keys) { $absent = @($all | Where-Object { $_ -notin $sets[$nv] }); if ($absent) { $problems += "$nv does not see LUN(s) $((@($absent | Select-Object -First 3)) -join ', ')$(if ($absent.Count -gt 3) { " and $($absent.Count - 3) more" })" } }
    foreach ($uid in $luns.Keys) { if (@($luns[$uid].Values | Select-Object -Unique).Count -gt 1) { $problems += "UniqueId $uid has different LUN IDs: $(($luns[$uid].GetEnumerator() | ForEach-Object { "$($_.Key)=LUN $($_.Value)" }) -join ', ')" } }
    if ($view.Unread.Count) { $problems += "$(Join-AzlPclList $view.Unread) could not be read" }
    if ($problems) { return New-AzlPclResult Failed ("The nodes do not agree on the LUNs: " + ($problems -join '; ') + '. Learn: all nodes must see the same set of LUNs (compare UniqueId; disk numbers may differ) and the array must present consistent LUN IDs to all of them.') 'On the array, map every LUN to all cluster node initiators with the same LUN ID; rescan with Update-HostStorageCache.' -Details $problems }
    New-AzlPclResult Passed "All $($view.Nodes.Count) node(s) see the same $($all.Count) LUN(s) with the same LUN IDs."
}

Register-AzlPclCheck -Id 'STO-009' -Category storage -Title 'The infrastructure LUN (250 GB) and performance history LUN (20 GB) are visible on every node and still RAW' -Source "$($script:Src.InstallDa) (Prerequisites; Connect to SAN); $($script:Src.SysReq) (SAN)" -Reads 'the nodes (WinRM) and the file' -Applies {
    param($Ctx) if ($Ctx.Architecture -eq 'san') { $true } else { 'scenario.storage_architecture is not san: the two system LUNs are a disaggregated requirement.' }
} -Run {
    param($Ctx)
    $view = Get-AzlPclSanView $Ctx
    if ($view.Unread.Count -and -not $view.Nodes.Count) { Stop-AzlPclSkip 'No node could be read (NOD-001).' }
    $wants = @(@{ Key = 'infra_volume_lun_id'; Label = 'infrastructure'; MinGb = 250 }, @{ Key = 'performance_history_lun_id'; Label = 'performance history'; MinGb = 20 })
    foreach ($nv in $view.Nodes.Values) {
        $problems = @()
        foreach ($w in $wants) {
            $id = [string](Get-AzlProp $Ctx.Infra "storage.san.$($w.Key)" '')
            if (-not $id) { $problems += "storage.san.$($w.Key) is empty"; continue }
            $disk = @($nv.Disks | Where-Object { if ($id -match '^\d{1,4}$') { [string]$_.lun -eq $id } else { [string]$_.uid -ieq $id -or [string]$_.sn -ieq $id } }) | Select-Object -First 1
            if (-not $disk) { $problems += "the $($w.Label) LUN $id is not visible"; continue }
            if ([double]$disk.gb * 1.073741824 -lt $w.MinGb) { $problems += "the $($w.Label) LUN $id is $($disk.gb) GiB, smaller than the $($w.MinGb) GB Learn asks for" }
            if ([string]$disk.ps -ne 'RAW') { $problems += "the $($w.Label) LUN $id has partition style $($disk.ps): it was initialized. Learn: don't initialize the drives, the deployment expects the drive type to be RAW" }
        }
        if ($problems) { New-AzlPclResult Failed "$($nv.Name): $($problems -join '; ')." 'Present the two LUNs to every node (infrastructure 250 GB, performance history 20 GB), leave them RAW (a wrongly initialized LUN: Clear-Disk -Number <n> -RemoveData on ONE node, after checking it is not in use), rescan with Update-HostStorageCache.' -Node $nv.Name }
        else { New-AzlPclResult Passed "$($nv.Name) sees both system LUNs, large enough and RAW." -Node $nv.Name }
    }
}

Register-AzlPclCheck -Id 'STO-010' -Category storage -Title 'Fibre Channel: the HBA ports of the file are present on the nodes' -Source "$($script:Src.InstallDa) (Connect to SAN, FC)" -Reads 'the nodes (WinRM) and the file' -Applies {
    param($Ctx) if ($Ctx.Architecture -in 'san', 'hybrid' -and $Ctx.SanType -eq 'fibre_channel') { $true } else { 'No Fibre Channel SAN is declared.' }
} -Run {
    param($Ctx)
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $expected = @(foreach ($hba in ConvertTo-AzlPclList (Get-AzlProp $Node 'san.hbas')) { foreach ($port in ConvertTo-AzlPclList (Get-AzlProp $hba 'ports')) { (([string](Get-AzlProp $port 'wwpn' '')) -replace '[:\-\s]', '').ToLowerInvariant() } }) | Where-Object { $_ }
        $seen = @(ConvertTo-AzlPclList (Get-AzlProp $D.Read 'san.fc' @()))
        $seenKeys = @($seen | ForEach-Object { [string]$_.wwpn })
        if (-not $expected.Count) { New-AzlPclResult Warning "The file lists no HBA WWPN for $Name (nodes[].san.hbas), so the HBA ports cannot be compared; $($seen.Count) FC port(s) are present." 'Add the WWPNs (Get-InitiatorPort) to the file; the SAN administrator needs them anyway.' -Node $Name; return }
        $missing = @($expected | Where-Object { $_ -notin $seenKeys })
        if ($missing) { New-AzlPclResult Failed "$Name does not show the HBA port(s) the file lists: $(Join-AzlPclList $missing) (it shows $(if ($seenKeys) { $seenKeys -join ', ' } else { 'no Fibre Channel port' })). The HBA driver may be missing, or the file is wrong." 'Install the HBA driver (Learn: pnputil /add-driver <inf> /install) and read the WWPNs with Get-InitiatorPort; correct nodes[].san.hbas.' -Node $Name }
        else { New-AzlPclResult Passed "$Name shows all $($expected.Count) HBA port(s) of the file." -Node $Name }
    }
}

Register-AzlPclCheck -Id 'STO-011' -Category storage -Title 'Hybrid Fibre Channel: do not zone the HBA WWNs until after the deployment' -Source "$($script:Src.ExtStorage) (Fibre Channel prerequisites: Important)" -Reads 'the nodes (WinRM)' -Applies {
    param($Ctx) if ($Ctx.Architecture -eq 'hybrid' -and $Ctx.SanType -eq 'fibre_channel') { $true } else { 'The rule is for hybrid (Storage Spaces Direct plus Fibre Channel SAN) designs.' }
} -Run {
    param($Ctx)
    $view = Get-AzlPclSanView $Ctx
    if ($view.Unread.Count -and -not $view.Nodes.Count) { Stop-AzlPclSkip 'No node could be read (NOD-001).' }
    $visible = @($view.Nodes.Values | Where-Object { $_.Disks.Count })
    if (-not $visible.Count) { return New-AzlPclResult Passed 'No FC LUN is visible before the deployment: the HBA WWNs are not zoned yet, as Learn asks.' }
    $dups = @($visible | Where-Object { $_.Duplicates.Count })
    $options = "Workarounds: (1) leave the HBA WWNs unzoned (or unmask the LUNs) until the deployment is done; (2) have MPIO claim the array first, so each LUN is one disk (mpclaim -n -i -d `"<vendor padded to 8><product padded to 16>`" from config/san/msdsm-vendors.json, STO-006), then restart; (3) disable the FC HBA for the deployment window: Get-PnpDevice -Class SCSIAdapter | Where-Object FriendlyName -match 'Fibre|HBA|FC' | Disable-PnpDevice -Confirm:`$false, and enable it again after the deployment."
    $text = "FC LUNs are visible on $(Join-AzlPclList @($visible | ForEach-Object { $_.Name })) ($((@($visible | ForEach-Object { $_.Disks.Count }) | Measure-Object -Sum).Sum) disks) before the deployment. Learn (hybrid): to avoid deployment confusion for FC LUNs, don't zone in FC HBA World Wide Names until after the Azure Local deployment."
    if ($dups.Count) { return New-AzlPclResult Failed "$text The paths are not claimed by MPIO, so the same LUN shows up as several disks: $((@($dups | ForEach-Object { Format-AzlPclDuplicateEvidence $_ }) | Select-Object -First 2) -join ' | '). $options" "See the workarounds; the quickest is to unzone the HBA until after the deployment." }
    New-AzlPclResult Warning "$text MPIO presents each LUN once, so Test-Cluster should not trip over it, but the zoning is still earlier than Learn asks. $options" 'Prefer to unzone until after the deployment.'
}

Register-AzlPclCheck -Id 'STO-012' -Category storage -Title 'iSCSI: dedicated adapters with OEM drivers; the iSCSI service state matches the solution version (2610: the wizard enables it)' -Source "$($script:Src.InstallDa) (Connect to SAN, iSCSI); $($script:Src.ExtStorage) (iSCSI prerequisites)" -Reads 'the nodes (WinRM) and the file' -Applies {
    param($Ctx) if ($Ctx.Architecture -in 'san', 'hybrid' -and $Ctx.SanType -eq 'iscsi') { $true } else { 'No iSCSI SAN is declared.' }
} -Run {
    param($Ctx)
    $target = Get-AzlPclTargetSolution $Ctx
    $minor = if ($target -match '^\d+\.(?<m>\d{4})\.') { [int]$Matches.m } else { 0 }
    Invoke-AzlPclPerNode -Ctx $Ctx -Body {
        param($Name, $D, $Node)
        $problems = @(); $warnings = @()
        $iscsiPorts = @(ConvertTo-AzlPclList (Get-AzlProp $Node 'network_adapters' @()) | Where-Object { @(ConvertTo-AzlPclList $_['roles']) -match '^iscsi' })
        foreach ($p in $iscsiPorts) { $nic = Get-AzlPclNic $D ([string]$p['name']); if ($nic -and [string]$nic.drvProv -match '^Microsoft') { $problems += "iSCSI adapter '$($p['name'])' uses the inbox Microsoft driver (Learn: don't use the inbox drivers for iSCSI adapters)" } elseif (-not $nic) { $warnings += "iSCSI adapter '$($p['name'])' of the file is not found on the node under that name" } }
        if (-not $iscsiPorts.Count) { $warnings += 'no port of the file has the role iscsi:a or iscsi:b (Learn: Azure Local only supports dedicated adapters for iSCSI)' }
        $svc = [string](Get-AzlProp $D.Read 'san.iscsiSvc' ''); $claim = [string](Get-AzlProp $D.Read 'san.iscsiClaim' '')
        if ($minor -ge 2610) { if ($svc -like 'Running*') { $warnings += "the iSCSI service is ${svc}: Learn 2610 says not to enable iSCSI manually before the deployment; the deployment wizard configures it" } }
        elseif ($minor -gt 0) { if ($svc -notlike 'Running/Automatic*') { $problems += "the iSCSI service is '$svc' (before 2610 Learn has you enable it by hand: Set-Service MSiSCSI -StartupType Automatic; Start-Service MSiSCSI)" }; if ($claim -and $claim -notmatch 'True') { $problems += 'iSCSI auto-claim is off (Enable-MSDSMAutomaticClaim -BusType iSCSI)' } }
        else { $warnings += 'the solution version is not declared (provisioning.os_version), so it is not known whether Learn 2610 (the wizard enables iSCSI; do not enable it by hand) or 2604-2609 (enable it by hand) applies' }
        if ($problems) { New-AzlPclResult Failed "$Name`: $($problems -join '; ')." 'Fix the iSCSI adapters and service as Learn describes for this solution version.' -Node $Name }
        elseif ($warnings) { New-AzlPclResult Warning "$Name`: $($warnings -join '; ')." 'Review the iSCSI preparation for this solution version.' -Node $Name }
        else { New-AzlPclResult Passed "$Name's iSCSI adapters use vendor drivers and the iSCSI service state ($svc) fits solution $target." -Node $Name }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# READINESS: Microsoft's own validators, run from this host against the nodes
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlPclEnvironmentChecker {
    # One run of the Environment Checker per verification (the adapter's EnvChecker), cached: the answer per validator.
    param([Parameter(Mandatory)]$Ctx)
    if ($Ctx.Cache.ContainsKey('Ec')) { return $Ctx.Cache['Ec'] }
    if (-not (Test-AzlPclAdapterHas $Ctx 'EnvChecker')) { Stop-AzlPclSkip 'The adapter has no EnvChecker here.' }
    $lcm = Get-AzlPclLcm $Ctx
    if ($Ctx.Identity -eq 'active_directory' -and $lcm.PasswordRef) { try { $null = Get-AzlPclLcmSecure -Ctx $Ctx -Lcm $lcm } catch { Write-Verbose "The LCM password could not be read for the Active Directory validator: $($_.Exception.Message)" } }
    $addresses = [ordered]@{}
    foreach ($n in $Ctx.Nodes) { $d = Get-AzlPclNodeData -Ctx $Ctx -Node $n; if ($d.Ok -and $d.Address) { $addresses[[string]$n['name']] = $d.Address } }
    $set = Get-AzlPclParameterSet $Ctx
    $pool = Get-AzlProp $Ctx.Infra 'networking.management.infrastructure_pool'
    $local = Get-AzlProp $Ctx.Infra 'identity.local_admin'
    $request = [pscustomobject]@{
        Validators = @('Connectivity', 'Hardware', 'Software', 'ActiveDirectory', 'Network', 'ArcIntegration')
        Nodes = @($addresses.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Address = $addresses[$_] } })
        NodeUser = [string](Get-AzlProp $local 'username' ''); NodePassword = $(if ($Ctx.Cache.ContainsKey('AdminPlain')) { [string]$Ctx.Cache['AdminPlain'] } else { '' })
        UseSsl = [bool]$Ctx.Remoting.UseSsl; Authentication = [string]$Ctx.Remoting.Authentication
        Proxy = $(if ([string](Get-AzlProp $Ctx.Infra 'scenario.outbound_path' '') -in 'proxy', 'proxy_arc_gateway') { [string](Get-AzlProp $Ctx.Infra 'networking.outbound.proxy.url' '') } else { '' })
        Identity = $Ctx.Identity; Domain = $lcm.Domain; OuPath = $lcm.OuPath; NamingPrefix = [string](Get-AzlProp $Ctx.Infra 'cluster.naming_prefix' ''); ClusterName = $Ctx.Cluster
        ActiveDirectoryServer = $(if ($lcm.DomainControllers.Count) { $lcm.DomainControllers[0] } else { $lcm.Domain })
        LcmUser = $(if ($lcm.Netbios) { "$($lcm.Netbios)\$($lcm.User)" } elseif ($lcm.Domain) { "$($lcm.Domain.Split('.')[0].ToUpperInvariant())\$($lcm.User)" } else { $lcm.User })
        LcmPassword = $(if ($Ctx.Cache.ContainsKey('LcmPlain')) { [string]$Ctx.Cache['LcmPlain'] } else { '' })
        Subscription = $Ctx.Subscription; ResourceGroup = ($Ctx.ResourceGroup); Tenant = $Ctx.Tenant
        IpPools = @([pscustomobject]@{ StartingAddress = [string](Get-AzlProp $pool 'start' ''); EndingAddress = [string](Get-AzlProp $pool 'end' '') })
        ManagementSubnet = [string](Get-AzlProp $Ctx.Infra 'networking.management.subnet' '')
        Intents = $(if ($set.Set -and $set.Set.Parameters.Contains('intentList')) { @($set.Set.Parameters['intentList']) } else { @() })
    }
    if ($request.LcmPassword) { Register-AzlPclSecret $request.LcmPassword }
    $answer = Invoke-AzlPclAdapter $Ctx EnvChecker @($request)
    $Ctx.Cache['Ec'] = $answer
    return $answer
}

function Convert-AzlPclEnvironmentResult {
    <#
    .SYNOPSIS
        One validator's results as one gate result: Failed on a critical failure, Warning on a warning-level failure, else Passed.
        A validator that did not run is Skipped, with the reason.
    #>
    param($Validator, [string]$Name, [string]$Remedy)
    if (-not $Validator -or -not [bool](Get-AzlProp $Validator 'ran' $false)) {
        Stop-AzlPclSkip "The $Name validator did not run: $([string](Get-AzlProp $Validator 'reason' 'no answer'))" $Remedy
    }
    $results = @(ConvertTo-AzlPclList (Get-AzlProp $Validator 'results' @()))
    $failed = @($results | Where-Object { [string]$_.status -match '^(?i)fail' })
    $critical = @($failed | Where-Object { [string]$_.severity -match '^(?i)crit' })
    $line = { param($r) "$($r.title) [$($r.target)]: $($r.description)$(if ($r.remediation) { " Remediation: $($r.remediation)" })" }
    $details = @($results | ForEach-Object { "$($_.status)/$($_.severity) $($_.name)" })
    if ($critical.Count) { return New-AzlPclResult Failed "The $Name validator reports $($critical.Count) critical issue(s) of $($results.Count) tests: $((@($critical | ForEach-Object { & $line $_ })) -join ' | ')" $Remedy -Details $details }
    if ($failed.Count) { return New-AzlPclResult Warning "The $Name validator reports $($failed.Count) warning(s) of $($results.Count) tests: $((@($failed | ForEach-Object { & $line $_ })) -join ' | ')" $Remedy -Details $details }
    New-AzlPclResult Passed "The $Name validator ran $($results.Count) test(s); all succeeded." -Details $details
}

$script:EcSource = "$script:Learn/manage/use-environment-checker?$script:View"
$script:EcInstall = 'Install-Module AzStackHci.EnvironmentChecker -Repository PSGallery (on this host, not on the nodes; Windows PowerShell 5.1). The gate never installs it; offline, save the module from a connected machine (Save-Module) and copy it.'

Register-AzlPclCheck -Id 'RDY-001' -Category readiness -Title 'Environment Checker, connectivity validator: outbound connectivity to the Azure endpoints' -Source $script:EcSource -Reads 'the Environment Checker, run from this host against the nodes' -Run {
    param($Ctx)
    $ec = Get-AzlPclEnvironmentChecker $Ctx
    Convert-AzlPclEnvironmentResult -Validator (Get-AzlProp $ec 'validators.Connectivity') -Name 'connectivity' -Remedy $script:EcInstall
}
Register-AzlPclCheck -Id 'RDY-002' -Category readiness -Title 'Environment Checker, hardware validator: processors, memory, adapters, disks, no storage pool, Secure Boot, TPM 2.0' -Source $script:EcSource -Reads 'the Environment Checker, run from this host against the nodes' -Run {
    param($Ctx)
    $ec = Get-AzlPclEnvironmentChecker $Ctx
    Convert-AzlPclEnvironmentResult -Validator (Get-AzlProp $ec 'validators.Hardware') -Name 'hardware' -Remedy $script:EcInstall
}
Register-AzlPclCheck -Id 'RDY-003' -Category readiness -Title 'Environment Checker, software validator: same NTP, same OS version, resolvable local Administrators (run with -Exclude Test-IsNotPartofDomain)' -Source $script:EcSource -Reads 'the Environment Checker, run from this host against the nodes' -Run {
    param($Ctx)
    $ec = Get-AzlPclEnvironmentChecker $Ctx
    Convert-AzlPclEnvironmentResult -Validator (Get-AzlProp $ec 'validators.Software') -Name 'software' -Remedy $script:EcInstall
}
Register-AzlPclCheck -Id 'RDY-004' -Category readiness -Title 'Environment Checker, Active Directory validator (Invoke-AzStackHciExternalActiveDirectoryValidation)' -Source $script:EcSource -Reads 'the Environment Checker, run from this host against Active Directory' -Applies $script:IsAd -Run {
    param($Ctx)
    $ec = Get-AzlPclEnvironmentChecker $Ctx
    Convert-AzlPclEnvironmentResult -Validator (Get-AzlProp $ec 'validators.ActiveDirectory') -Name 'Active Directory' -Remedy "$script:EcInstall Run it from a host that reaches the domain controllers."
}
Register-AzlPclCheck -Id 'RDY-005' -Category readiness -Title 'Environment Checker, network validator: IP ranges free, adapters, storage connection (Invoke-AzStackHciNetworkValidation)' -Source $script:EcSource -Reads 'the Environment Checker, run from this host against the nodes, with the ARM intent list' -Run {
    param($Ctx)
    $set = Get-AzlPclParameterSet $Ctx
    if (-not $set.Set) { Stop-AzlPclSkip "The network validator needs the intents the ARM Validate will send, and the parameters cannot be generated (AZR-017): $($set.Error)" }
    $ec = Get-AzlPclEnvironmentChecker $Ctx
    Convert-AzlPclEnvironmentResult -Validator (Get-AzlProp $ec 'validators.Network') -Name 'network' -Remedy $script:EcInstall
}
Register-AzlPclCheck -Id 'RDY-006' -Category readiness -Title 'Environment Checker, Arc integration validator: no name clash, region valid, resource and role assignment limits' -Source $script:EcSource -Reads 'the Environment Checker with the Az context, run from this host' -Run {
    param($Ctx)
    $null = Get-AzlPclAzure $Ctx
    $ec = Get-AzlPclEnvironmentChecker $Ctx
    Convert-AzlPclEnvironmentResult -Validator (Get-AzlProp $ec 'validators.ArcIntegration') -Name 'Arc integration' -Remedy "$script:EcInstall The Az modules must be available to Windows PowerShell 5.1 with the same sign-in."
}

# ---------------------------------------------------------------------------------------------------------------------
# What runs on a node: the gate's own read only payload (Windows PowerShell 5.1 syntax; a node ships no pwsh)
# ---------------------------------------------------------------------------------------------------------------------

$script:PclBody = @'
# Pre-cluster verification read. Changes nothing on the node.
$Az = @{ err = @{}; adminAccount = $null; os = $null; cs = $null; primarySuffix = ''; cpu = @(); mem = @(); fw = $null; features = @(); reboot = $null; time = $null; dns = @(); phys = @(); pools = @(); vdisks = 0
    cluster = $null; nics = @(); vms = $null; sshd = $null; admins = @(); ec = @(); tcp = @(); https = @(); ping = @(); dnsq = @() }
function Invoke-Section([string]$name, [scriptblock]$sb) {
    try { & $sb } catch { $Az.err[$name] = $_.Exception.Message }
}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
$utc = (Get-Date).ToUniversalTime().ToString('o')

Invoke-Section 'os' {
    $os = Get-CimInstance Win32_OperatingSystem
    $ubr = ''
    try { $ubr = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR } catch { $ubr = '' }
    $Az.os = [pscustomobject]@{ caption = [string]$os.Caption; build = ('{0}.{1}' -f $os.Version, $ubr) }
}
Invoke-Section 'cs' {
    $c = Get-CimInstance Win32_ComputerSystem
    $Az.cs = [pscustomobject]@{ partOfDomain = [bool]$c.PartOfDomain; domain = [string]$c.Domain; memBytes = [int64]$c.TotalPhysicalMemory; manufacturer = [string]$c.Manufacturer; model = [string]$c.Model; hypervisor = [bool]$c.HypervisorPresent }
    try { $Az.primarySuffix = [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters').Domain } catch { $Az.primarySuffix = '' }
}
Invoke-Section 'cpu' {
    $Az.cpu = @(Get-CimInstance Win32_Processor | ForEach-Object {
            [pscustomobject]@{ caption = [string]$_.Caption; family = [int]$_.Family; manufacturer = [string]$_.Manufacturer; maxClock = [int]$_.MaxClockSpeed; cores = [int]$_.NumberOfEnabledCore; logical = [int]$_.NumberOfLogicalProcessors
                threads = [int]$_.ThreadCount; vt = [bool]$_.VirtualizationFirmwareEnabled; slat = [bool]$_.SecondLevelAddressTranslationExtensions }
        })
}
Invoke-Section 'mem' { $Az.mem = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object { [int64]$_.Capacity }) }
Invoke-Section 'fw' {
    $b = Get-CimInstance Win32_BIOS
    $sb = $null
    try { $sb = [bool](Confirm-SecureBootUEFI) } catch { $sb = $null }
    $tpm = $null
    try { $tpm = Get-Tpm } catch { $tpm = $null }
    $spec = ''
    try { $spec = [string](Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm).SpecVersion } catch { $spec = '' }
    $present = $null; $ready = $null
    if ($tpm) { $present = [bool]$tpm.TpmPresent; $ready = [bool]$tpm.TpmReady }
    $Az.fw = [pscustomobject]@{ biosVersion = [string]$b.SMBIOSBIOSVersion; biosVendor = [string]$b.Manufacturer; secureBoot = $sb; tpmPresent = $present; tpmReady = $ready; tpmSpec = $spec }
}
Invoke-Section 'features' {
    $all = @{}
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) { foreach ($f in @(Get-WindowsFeature)) { $all[[string]$f.Name] = [bool]$f.Installed } }
    $Az.features = @(foreach ($w in @(Get-P $P 'features' @())) {
            $found = $all.ContainsKey([string]$w)
            $inst = $null
            if ($found) { $inst = $all[[string]$w] }
            [pscustomobject]@{ n = [string]$w; found = $found; installed = $inst }
        })
}
Invoke-Section 'reboot' {
    $r = [pscustomobject]@{ cbs = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'); wu = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'); files = $false; rename = $false }
    try { $v = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop; $r.files = [bool]$v.PendingFileRenameOperations } catch { $null = $_ }
    try {
        $a = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
        $n = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
        $r.rename = ($a -ne $n)
    }
    catch { $null = $_ }
    $Az.reboot = $r
}
Invoke-Section 'time' {
    $src = (& w32tm.exe /query /source 2>$null | Select-Object -First 1)
    $w = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $Az.time = [pscustomobject]@{ src = [string]$src; type = [string](Get-P $w 'Type' ''); peers = [string](Get-P $w 'NtpServer' '') }
}
Invoke-Section 'dns' {
    $Az.dns = @(Get-DnsClient -ErrorAction SilentlyContinue | ForEach-Object {
            $row = $_
            $sv = @(Get-DnsClientServerAddress -InterfaceIndex $row.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
            [pscustomobject]@{ n = [string]$row.InterfaceAlias; idx = [int]$row.InterfaceIndex; suffix = [string]$row.ConnectionSpecificSuffix; servers = @($sv | ForEach-Object { [string]$_ }) }
        })
}
Invoke-Section 'disks' {
    $disks = @{}
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue)) { $disks[[int]$d.Number] = $d }
    $Az.phys = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            $num = $null
            if ([string]$_.DeviceId -match '^\d+$') { $num = [int]$_.DeviceId }
            $d = $null
            if ($null -ne $num -and $disks.ContainsKey($num)) { $d = $disks[$num] }
            $boot = $false; $system = $false; $style = ''; $parts = 0
            if ($d) { $boot = [bool]$d.IsBoot; $system = [bool]$d.IsSystem; $style = [string]$d.PartitionStyle; $parts = [int]$d.NumberOfPartitions }
            [pscustomobject]@{ num = $num; name = [string]$_.FriendlyName; serial = ([string]$_.SerialNumber).Trim(); size = [int64]$_.Size; bus = [string]$_.BusType; media = [string]$_.MediaType; canPool = [bool]$_.CanPool
                reason = (@($_.CannotPoolReason) -join ','); health = [string]$_.HealthStatus; fw = [string]$_.FirmwareVersion; boot = $boot; system = $system; style = $style; parts = $parts }
        })
}
Invoke-Section 'pools' {
    $Az.pools = @(Get-StoragePool -ErrorAction SilentlyContinue | Where-Object { -not $_.IsPrimordial } | ForEach-Object { [string]$_.FriendlyName })
    $Az.vdisks = @(Get-VirtualDisk -ErrorAction SilentlyContinue).Count
}
Invoke-Section 'cluster' {
    $svc = Get-Service ClusSvc -ErrorAction SilentlyContinue
    $name = ''
    $status = ''
    if ($svc) { $status = [string]$svc.Status }
    if ($svc -and $svc.Status -eq 'Running') { try { $name = [string](Get-Cluster -ErrorAction Stop).Name } catch { $name = '' } }
    $Az.cluster = [pscustomobject]@{ svc = $status; name = $name }
}
Invoke-Section 'nics' {
    $Az.nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
            $a = $_
            $jumbo = $null
            $jp = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*JumboPacket' -ErrorAction SilentlyContinue
            if ($jp) { $jumbo = [string]@($jp.RegistryValue)[0] }
            $nd = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*NetworkDirect' -ErrorAction SilentlyContinue
            $rdma = Get-NetAdapterRdma -Name $a.Name -ErrorAction SilentlyContinue
            $op = $null
            $en = $false
            if ($rdma) { $en = [bool]$rdma.Enabled; if ($rdma.PSObject.Properties['Operational']) { $op = [bool]$rdma.Operational } }
            $ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | ForEach-Object { [string]$_.IPAddress })
            $gw = @(Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.NextHop })
            [pscustomobject]@{ n = [string]$a.Name; desc = [string]$a.InterfaceDescription; st = [string]$a.Status; speed = [int64]$a.Speed; mac = ([string]$a.MacAddress -replace '[-:]', '').ToLowerInvariant(); drvProv = [string]$a.DriverProvider
                drvVer = [string]$a.DriverVersion; idx = [int]$a.ifIndex; mtu = [int]$a.MtuSize; jumbo = $jumbo; rdmaCapable = [bool]($nd -or $rdma); rdmaEnabled = $en; rdmaOp = $op; ips = $ips; gw = $gw }
        })
}
Invoke-Section 'vms' {
    $sw = @()
    if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
        $sw = @(Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ n = [string]$_.Name; uplinks = @($_.NetAdapterInterfaceDescriptions | ForEach-Object { [string]$_ }) } })
    }
    $in = @()
    if (Get-Command Get-NetIntent -ErrorAction SilentlyContinue) { try { $in = @(Get-NetIntent -ErrorAction Stop | ForEach-Object { [string]$_.IntentName }) } catch { $in = @() } }
    $Az.vms = [pscustomobject]@{ switches = $sw; intents = $in }
}
Invoke-Section 'sshd' {
    $s = Get-Service sshd -ErrorAction SilentlyContinue
    if ($s) { $Az.sshd = [pscustomobject]@{ status = [string]$s.Status; start = [string]$s.StartType } }
}
Invoke-Section 'admins' {
    $Az.admins = @(& net.exe localgroup Administrators 2>$null | Where-Object { $_ -and $_ -notmatch '^(Alias name|Comment|Members|The command completed|-+$)' } | ForEach-Object { [string]$_.Trim() })
}
Invoke-Section 'adminAccount' {
    $user = [string](Get-P $P 'adminUser' '')
    if (-not $user) { return }
    $u = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
    if ($u) { $sid = [string]$u.SID.Value; $Az.adminAccount = [pscustomobject]@{ user = $user; sid = $sid; builtin = [bool]($sid -match '-500$'); enabled = [bool]$u.Enabled } }
}
Invoke-Section 'ec' {
    $Az.ec = @(Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ name = [string]$_.Name; version = [string]$_.Version } })
}

function Test-Tcp([string]$Address, [int]$Port, [int]$Milliseconds) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($Milliseconds, $false)) { return $false }
        $client.EndConnect($ar)
        return [bool]$client.Connected
    }
    catch { return $false }
    finally { $client.Close() }
}
Invoke-Section 'tcp' {
    $Az.tcp = @(foreach ($t in @(Get-P $P 'tcp' @())) { [pscustomobject]@{ h = [string]$t.h; p = [int]$t.p; ok = (Test-Tcp ([string]$t.h) ([int]$t.p) 3000) } })
}
Invoke-Section 'https' {
    $proxy = [string](Get-P $P 'proxy' '')
    $Az.https = @(foreach ($u in @(Get-P $P 'https' @())) {
            $ok = $false; $status = ''; $err = ''
            try {
                $req = [System.Net.HttpWebRequest]::Create([string]$u)
                $req.Method = 'HEAD'; $req.Timeout = 15000
                if ($proxy) { $req.Proxy = New-Object System.Net.WebProxy($proxy) }
                $resp = $req.GetResponse(); $status = [string][int]$resp.StatusCode; $resp.Close(); $ok = $true
            }
            catch [System.Net.WebException] {
                # An HTTP error status means the endpoint answered over a trusted TLS connection; no response means it did not.
                if ($_.Exception.Response) { $ok = $true; $status = [string][int]$_.Exception.Response.StatusCode } else { $err = $_.Exception.Message }
            }
            catch { $err = $_.Exception.Message }
            [pscustomobject]@{ u = [string]$u; ok = $ok; status = $status; err = $err }
        })
}
Invoke-Section 'ping' {
    $png = New-Object System.Net.NetworkInformation.Ping
    $Az.ping = @(foreach ($a in @(Get-P $P 'ping' @())) {
            $ok = $false
            try { $r = $png.Send([string]$a, 800); $ok = ($r.Status -eq 'Success') } catch { $ok = $false }
            [pscustomobject]@{ a = [string]$a; ok = $ok }
        })
}
Invoke-Section 'dnsq' {
    $Az.dnsq = @(foreach ($q in @(Get-P $P 'dnsq' @())) {
            $ok = $false; $addrs = @(); $err = ''
            try {
                $addrs = @(Resolve-DnsName -Name ([string]$q.name) -Server ([string]$q.server) -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress })
                $ok = ($addrs.Count -gt 0)
            }
            catch { $err = $_.Exception.Message }
            [pscustomobject]@{ name = [string]$q.name; server = [string]$q.server; ok = $ok; addrs = $addrs; err = $err }
        })
}

Write-Result ([pscustomobject]@{
        v = 1; host = $env:COMPUTERNAME; utc = $utc; os = $Az.os; cs = $Az.cs; primarySuffix = $Az.primarySuffix; cpu = $Az.cpu; mem = $Az.mem; fw = $Az.fw; features = $Az.features; reboot = $Az.reboot; time = $Az.time
        dns = $Az.dns; phys = $Az.phys; pools = $Az.pools; vdisks = $Az.vdisks; cluster = $Az.cluster; nics = $Az.nics; vms = $Az.vms; sshd = $Az.sshd; admins = $Az.admins; ec = $Az.ec
        tcp = $Az.tcp; https = $Az.https; ping = $Az.ping; dnsq = $Az.dnsq; adminAccount = $Az.adminAccount; err = $Az.err
    })
'@

function Get-AzlPclPayload {
    <#
    .SYNOPSIS
        The text of the gate's node script (the OS configuration's prologue, then the read only body). Changes nothing on the node.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return ((Get-AzlNodePrologue) + [Environment]::NewLine + $script:PclBody)
}

function Invoke-AzlPclReadNode {
    <#
    .SYNOPSIS
        The default ReadNode of the adapter: the OS configuration's Read payload (adapters, time, local administrator, storage, SAN) and
        the gate's own payload, over WinRM (New-AzlWinRmTransport, Invoke-AzlNodeScript), trying the node's addresses in order. Read only.
        A transient script file under C:\ProgramData\AzureLocal\osconfig is written and removed by the transport, as for the OS configuration.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    $last = ''
    foreach ($address in @($Request.Addresses)) {
        $transport = New-AzlWinRmTransport -Address @{ $Request.Node = $address } -Credential $Request.Credential -UseSsl:([bool]$Request.UseSsl) -Authentication $Request.Authentication
        try {
            $read = Invoke-AzlNodeScript -Transport $transport -Node $Request.Node -Script (Get-AzlNodePayload -Name Read) -Parameters ([hashtable]$Request.ReadParameters) -Secrets @{ adminPassword = [string]$Request.AdminPassword } -TimeoutSeconds 120 -Tries 1 -Kind Read
            $pcl = Invoke-AzlNodeScript -Transport $transport -Node $Request.Node -Script (Get-AzlPclPayload) -Parameters ([hashtable]$Request.PclParameters) -TimeoutSeconds 300 -Tries 1 -Kind PreClusterRead
            return [pscustomobject]@{ Read = $read; Pcl = $pcl; Address = $address }
        }
        catch { $last = "${address}: $($_.Exception.Message)" }
        finally { try { & $transport.CloseSession $transport $Request.Node } catch { Write-Verbose "The session to $($Request.Node) was not closed: $($_.Exception.Message)" } }
    }
    throw "Node $($Request.Node) could not be read at $(@($Request.Addresses) -join ', '). Last error: $last"
}

# ---------------------------------------------------------------------------------------------------------------------
# The Environment Checker, run from this host (Windows PowerShell 5.1) against the nodes; nothing is installed and nothing is changed
# ---------------------------------------------------------------------------------------------------------------------

$script:EcRunner = @'
param([string]$ParamsPath, [string]$OutPath)
$ErrorActionPreference = 'Stop'
$P = Get-Content -LiteralPath $ParamsPath -Raw | ConvertFrom-Json
$out = @{ available = $false; reason = ''; validators = @{} }
function Save-Out { ($out | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $OutPath -Encoding UTF8 }
function ConvertTo-Row($r) {
    # Status and Severity as text; when the module gives numbers: Status 0 success, 1 failure; Severity 0 informational, 1 warning, 2 critical, 3 hidden.
    $st = [string]$r.Status; $sv = [string]$r.Severity
    if ($st -match '^\d+$') { if ($st -eq '0') { $st = 'SUCCESS' } else { $st = 'FAILURE' } }
    if ($sv -match '^\d+$') { $sv = @('INFORMATIONAL', 'WARNING', 'CRITICAL', 'HIDDEN')[[int]$sv] }
    @{ name = [string]$r.Name; title = [string]$r.Title; status = $st; severity = $sv; description = [string]$r.Description; remediation = [string]$r.Remediation; target = [string]$r.TargetResourceName }
}
function Read-Report {
    $f = Join-Path $HOME '.AzStackHci\AzStackHciEnvironmentReport.json'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    return @($j | ForEach-Object { ConvertTo-Row $_ })
}
try {
    if (-not (Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker)) { $out.reason = 'The module AzStackHci.EnvironmentChecker is not installed on this host.'; Save-Out; exit 0 }
    Import-Module AzStackHci.EnvironmentChecker
    $out.available = $true
    $sessions = @()
    $nodePw = ConvertTo-SecureString $env:AZL_PCL_NODE_PASSWORD -AsPlainText -Force
    try {
        foreach ($n in @($P.nodes)) {
            $cred = New-Object System.Management.Automation.PSCredential(($n.name + '\' + $P.nodeUser), $nodePw)
            $args2 = @{ ComputerName = $n.address; Credential = $cred; Authentication = $P.authentication; ErrorAction = 'Stop' }
            if ($P.useSsl) { $args2.UseSSL = $true }
            $sessions += New-PSSession @args2
        }
    }
    catch { $out.reason = 'Sessions to the nodes could not be opened: ' + $_.Exception.Message }
    $report = Join-Path $HOME '.AzStackHci\AzStackHciEnvironmentReport.json'
    foreach ($v in @($P.validators)) {
        $entry = @{ ran = $false; reason = ''; results = @() }
        try {
            if ($v -in 'Connectivity', 'Hardware', 'Software', 'Network' -and -not $sessions.Count) { throw 'there is no session to a node' }
            if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report -Force }
            switch ($v) {
                'Connectivity' { if ($P.proxy) { Invoke-AzStackHciConnectivityValidation -PsSession $sessions -Proxy $P.proxy | Out-Null } else { Invoke-AzStackHciConnectivityValidation -PsSession $sessions | Out-Null } }
                'Hardware' { Invoke-AzStackHciHardwareValidation -PsSession $sessions | Out-Null }
                'Software' { Invoke-AzStackHciSoftwareValidation -PsSession $sessions -Exclude Test-IsNotPartofDomain | Out-Null }
                'ActiveDirectory' {
                    if ($P.identity -ne 'active_directory') { throw 'the design does not use Active Directory' }
                    $lpw = ConvertTo-SecureString $env:AZL_PCL_LCM_PASSWORD -AsPlainText -Force
                    $lc = New-Object System.Management.Automation.PSCredential($P.lcmUser, $lpw)
                    $names = (@($P.nodes) | ForEach-Object { $_.name }) -join ','
                    Invoke-AzStackHciExternalActiveDirectoryValidation -ADOUPath $P.ouPath -DomainFQDN $P.domain -NamingPrefix $P.namingPrefix -ActiveDirectoryServer $P.adServer -ActiveDirectoryCredentials $lc -ClusterName $P.clusterName -PhysicalMachineNames $names | Out-Null
                }
                'Network' {
                    $cred0 = New-Object System.Management.Automation.PSCredential(($P.nodes[0].name + '\' + $P.nodeUser), $nodePw)
                    Invoke-AzStackHciNetworkValidation -IpPools @($P.ipPools) -ManagementSubnetValue $P.managementSubnet -PSSession $sessions -SessionCredential $cred0 -AtcHostIntents @($P.intents) | Out-Null
                }
                'ArcIntegration' {
                    $names2 = [string[]]@($P.nodes | ForEach-Object { $_.name })
                    Invoke-AzStackHciArcIntegrationValidation -SubscriptionID $P.subscription -RegistrationResourceGroupName $P.resourceGroup -ArcResourceGroupName $P.resourceGroup -NodeNames $names2 | Out-Null
                }
            }
            $entry.results = Read-Report
            $entry.ran = $true
            if (-not $entry.results.Count) { $entry.ran = $false; $entry.reason = 'the validator wrote no result' }
        }
        catch { $entry.reason = $_.Exception.Message }
        $out.validators[$v] = $entry
    }
}
catch { $out.reason = $_.Exception.Message }
finally { Save-Out; foreach ($s in $sessions) { Remove-PSSession $s -ErrorAction SilentlyContinue } }
'@

function Invoke-AzlPclEnvironmentChecker {
    <#
    .SYNOPSIS
        The default EnvChecker of the adapter: runs Microsoft's AzStackHci.EnvironmentChecker validators in Windows PowerShell 5.1 on THIS host
        against the nodes (Learn allows a staging server or workstation, and says to uninstall the module from the nodes). The module is
        never installed here; when it is not installed, or powershell.exe is not there, every validator is reported with the reason, and the
        readiness checks end as Skipped. The passwords go to the child process through its environment, never on a command line or in a file.
    .OUTPUTS
        available, reason, validators (Connectivity, Hardware, Software, ActiveDirectory, Network, ArcIntegration -> ran, reason, results).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    $none = { param($why) $v = @{}; foreach ($n in $Request.Validators) { $v[$n] = @{ ran = $false; reason = $why; results = @() } }; return @{ available = $false; reason = $why; validators = $v } }
    if (-not $IsWindows) { return (& $none 'The Environment Checker is a Windows PowerShell 5.1 module; this host is not Windows.') }
    $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $powershell) { return (& $none 'powershell.exe (Windows PowerShell 5.1) is not available on this host.') }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('azl-pcl-ec-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $dir
    try {
        $runner = Join-Path $dir 'run.ps1'; $paramsFile = Join-Path $dir 'params.json'; $outFile = Join-Path $dir 'out.json'
        [IO.File]::WriteAllText($runner, $script:EcRunner, [Text.UTF8Encoding]::new($true))
        $params = @{
            validators = @($Request.Validators); nodes = @($Request.Nodes | ForEach-Object { @{ name = $_.Name; address = $_.Address } }); nodeUser = $Request.NodeUser; authentication = $Request.Authentication; useSsl = [bool]$Request.UseSsl; proxy = $Request.Proxy
            identity = $Request.Identity; domain = $Request.Domain; ouPath = $Request.OuPath; namingPrefix = $Request.NamingPrefix; clusterName = $Request.ClusterName; adServer = $Request.ActiveDirectoryServer; lcmUser = $Request.LcmUser
            subscription = $Request.Subscription; resourceGroup = $Request.ResourceGroup; ipPools = @($Request.IpPools | ForEach-Object { @{ StartingAddress = $_.StartingAddress; EndingAddress = $_.EndingAddress } }); managementSubnet = $Request.ManagementSubnet; intents = @($Request.Intents)
        }
        ($params | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $paramsFile -Encoding utf8NoBOM
        $info = [System.Diagnostics.ProcessStartInfo]::new($powershell.Source)
        foreach ($a in '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-ParamsPath', $paramsFile, '-OutPath', $outFile) { $info.ArgumentList.Add($a) }
        $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $info.Environment['AZL_PCL_NODE_PASSWORD'] = [string]$Request.NodePassword
        $info.Environment['AZL_PCL_LCM_PASSWORD'] = [string]$Request.LcmPassword
        $process = [System.Diagnostics.Process]::Start($info)
        $null = $process.StandardOutput.ReadToEndAsync(); $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(1800000)) { try { $process.Kill($true) } catch { Write-Verbose "The Environment Checker process could not be stopped: $($_.Exception.Message)" }; return (& $none 'The Environment Checker did not finish within 30 minutes and was stopped.') }
        if (-not (Test-Path -LiteralPath $outFile)) { return (& $none "The Environment Checker run produced no result (exit code $($process.ExitCode)).") }
        $answer = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json -AsHashtable -Depth 12
        return $answer
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# =====================================================================================================================
# THE RUN
# =====================================================================================================================

function Get-AzlPclPlan {
    <#
    .SYNOPSIS
        Mode Plan: every check of the catalog, whether it applies to this file, and what it reads. Offline: nothing is asked of Azure, a
        domain controller or a node.
    .OUTPUTS
        Id, Category, Title, Applies, Reason, Reads, Blocking, Fixable, Source.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [string[]]$Category, [object[]]$Definition)
    $ctx = New-AzlPclContext -Infrastructure $Infrastructure -Adapter @{} -Settings ([ordered]@{}) -Remoting $null -Mode Plan
    if (-not $Definition) { $Definition = @($script:Catalog) }
    @(foreach ($def in $Definition) {
            if ($Category -and $def.Category -notin $Category) { continue }
            $applies = $true
            try { $applies = & $def.Applies $ctx $def } catch { $applies = $true }
            [pscustomobject]@{
                Id = $def.Id; Category = $def.Category; Title = $def.Title; Applies = ($applies -isnot [string]); Reason = $(if ($applies -is [string]) { $applies } else { '' })
                Reads = $def.Reads; Blocking = $def.Blocking; Fixable = $def.Fixable; Source = $def.Source
            }
        })
}

function Format-AzlPclPlan {
    param([Parameter(Mandatory)][object[]]$Plan, [string]$Cluster)
    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add("## Pre-cluster verification plan: $Cluster"); $l.Add('')
    $l.Add("$(@($Plan | Where-Object { $_.Applies }).Count) of $($Plan.Count) checks apply to this file. Nothing was read: this is the plan, not a result. Run with -Mode Verify to check.")
    $l.Add(''); $l.Add('| Check | Category | Applies | Reads | Blocking | -Fix | Title |'); $l.Add('| --- | --- | --- | --- | --- | --- | --- |')
    foreach ($p in $Plan) { $l.Add("| $($p.Id) | $($p.Category) | $(if ($p.Applies) { 'yes' } else { 'no: ' + $p.Reason }) | $($p.Reads) | $($p.Blocking) | $($p.Fixable) | $(($p.Title -replace '\|', '/')) |") }
    return ($l -join [Environment]::NewLine)
}

function Invoke-AzlPclCheckSet {
    # Runs the checks one after the other; each result is finalized (blocking, accepted skips), added to the list and written to the feed.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Run, [Parameter(Mandatory)][object[]]$Definition, [string[]]$Accepted = @())
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($def in $Definition) {
        $applies = $true
        try { $applies = & $def.Applies $Ctx $def } catch { $applies = $true }
        if ($applies -is [string]) { $raw = @(New-AzlPclResult NotApplicable $applies) }
        else {
            try { $raw = @(& $def.Run $Ctx $def) }
            catch {
                if ($_.Exception.Data['AzlSkip']) { $raw = @(New-AzlPclResult Skipped $_.Exception.Message ([string]$_.Exception.Data['AzlRemedy'])) }
                else { $raw = @(New-AzlPclResult Failed "The check could not run: $($_.Exception.Message)" 'Read the message, fix the cause and run the verification again.') }
            }
        }
        $raw = @($raw | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-AzlPclResultObject $_ } | Where-Object { $_ })
        if (-not $raw.Count) { $raw = @(New-AzlPclResult Failed 'The check returned no result.' 'This is a defect of the check; report it.') }
        foreach ($r in $raw) {
            $isAccepted = ($r.Status -eq 'Skipped') -and ($def.Id -in $Accepted)
            $blocking = (($r.Status -eq 'Failed') -and $def.Blocking) -or (($r.Status -eq 'Skipped') -and $def.Blocking -and -not $isAccepted)
            $message = $r.Message
            if ($r.Status -eq 'Skipped') {
                $message += $(if ($isAccepted) { " [Skipped; ACCEPTED by the operator with -AcceptSkipped $($def.Id)]" } else { " [Skipped checks block the verdict: fix the cause, or accept this check with -AcceptSkipped $($def.Id)]" })
            }
            $final = [pscustomobject]@{
                Id = $def.Id; Category = $def.Category; Title = $def.Title; Source = $def.Source; Status = [string]$r.Status; Node = [string]$r.Node
                Message = (Hide-AzlPclSecret $message); Remedy = (Hide-AzlPclSecret ([string]$r.Remedy)); Blocking = [bool]$blocking; Accepted = [bool]$isAccepted
                Details = @($r.Details | ForEach-Object { Hide-AzlPclSecret ([string]$_) })
            }
            $all.Add($final)
            $null = Write-AzlPclEvent -Run $Run -Type Check -Check $def -Result $final
        }
    }
    return $all.ToArray()
}

function Invoke-AzlPreClusterVerification {
    <#
    .SYNOPSIS
        The pre-cluster verification gate: Plan (offline) or Verify (read only against Azure, Active Directory and the nodes).
    .DESCRIPTION
        Verify writes report.json, summary.md and precluster-verification-events.jsonl into the report directory. The ARM Validate and
        Deploy accept the result only when its verdict is Pass, its fileHash is the SHA-256 of the infrastructure file now, it has not
        expired and it covers all six categories. Default: nothing is changed anywhere. -Fix registers the mandatory resource providers
        that are not registered (Azure side only).
    .PARAMETER AcceptSkipped
        Ids of checks that may stay Skipped. A Skipped check blocks unless named here; the report records the acceptance.
    .PARAMETER Category
        Run only these categories (azure, identity, nodes, network, storage, readiness). A partial run never passes the ARM precondition.
    .PARAMETER Settings
        Run settings (see Get-AzlArmRunSetting); a 'remoting' entry (transport, useSsl, authentication) sets how the nodes are reached.
    .PARAMETER Adapter
        New-AzlPclAdapter, or a table with the members a test replaces.
    .OUTPUTS
        ExitCode, Verdict, Mode, Message, NextAction, ReportDirectory, ReportPath, SummaryPath, EventPath, Counts, Checks, RunId, FileHash,
        ExpiresUtc, Plan.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'A plain -Fix opt-in: the default never changes anything and Plan never does.')]
    param(
        [string]$InfrastructureFile,
        [System.Collections.IDictionary]$Infrastructure,
        [string]$HandoffFile,
        [object]$OsConfigurationReport,
        [ValidateSet('Plan', 'Verify')][string]$Mode = 'Plan',
        [string]$ReportDirectory,
        [string[]]$AcceptSkipped,
        [switch]$Fix,
        [string[]]$Category,
        [System.Collections.IDictionary]$Settings,
        [string]$ConfigPath,
        [string[]]$AcknowledgeKnownIssues,
        [System.Collections.IDictionary]$Adapter = (New-AzlPclAdapter),
        [string]$ExtensionFolder = (Get-AzlPclExtensionFolder)
    )
    $script:Secrets.Clear()
    $defaults = New-AzlPclAdapter
    foreach ($k in $defaults.Keys) { if (-not $Adapter.Contains($k)) { $Adapter[$k] = $defaults[$k] } }
    # The verification modules: their checks join the catalog, and the read only adapter members they bring fill the gaps of the adapter.
    $extension = Import-AzlPclExtension -Folder $ExtensionFolder
    foreach ($k in $extension.AdapterDefaults.Keys) { if (-not $Adapter.Contains($k)) { $Adapter[$k] = $extension.AdapterDefaults[$k] } }
    $definitions = @(Get-AzlPclDefinitionSet $extension)
    $contract = Get-AzlPclContract
    $out = [ordered]@{ ExitCode = 0; Verdict = ''; Mode = $Mode; Message = ''; NextAction = ''; ReportDirectory = ''; ReportPath = ''; SummaryPath = ''; EventPath = ''; Counts = $null; Checks = @(); RunId = ''; FileHash = ''; ExpiresUtc = ''; Plan = @() }
    try {
        # ---- inputs
        $infra = if ($Infrastructure) { $Infrastructure } elseif ($InfrastructureFile) {
            if (-not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { Stop-AzlPclInput "Infrastructure file not found: $InfrastructureFile" }
            try { Import-AzlInfrastructure -Path $InfrastructureFile } catch { Stop-AzlPclInput "The master file is not valid: $($_.Exception.Message)" }
        } else { Stop-AzlPclInput 'Give -InfrastructureFile (or -Infrastructure).' }
        if (-not [string](Get-AzlProp $infra 'cluster.name' '')) { Stop-AzlPclInput 'cluster.name is empty in infrastructure.yml.' }
        $categories = @($Category | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
        foreach ($c in $categories) { if ($c -notin $contract.Categories) { Stop-AzlPclInput "Unknown category '$c'. Known: $($contract.Categories -join ', ')." } }
        $accepted = @($AcceptSkipped | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
        foreach ($id in $accepted) { if (-not @($definitions | Where-Object { $_.Id -eq $id }).Count) { Stop-AzlPclInput "-AcceptSkipped names '$id', which is not a check id. See docs/pre-cluster-verification.md or run with -Mode Plan." } }
        $armSettings = [ordered]@{}; $remotingRaw = $null
        if ($Settings) { foreach ($k in $Settings.Keys) { if ([string]$k -eq 'remoting') { $remotingRaw = $Settings[$k] } else { $armSettings[$k] = $Settings[$k] } } }
        if ($AcknowledgeKnownIssues) { $armSettings['acknowledgeKnownIssues'] = @($AcknowledgeKnownIssues | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $run = Get-AzlArmRunSetting -Infrastructure $infra -ConfigPath $ConfigPath -Settings $armSettings
        $remoting = try { Get-AzlRemotingSetting -Infrastructure $infra -Setting $(if ($remotingRaw) { @{ remoting = $remotingRaw } } else { @{} }) } catch { Stop-AzlPclInput $_.Exception.Message }
        $reportDir = if ($ReportDirectory) { $ReportDirectory } else { Resolve-AzlPclReportDirectory -InfrastructureFile $InfrastructureFile -Configured ([string]$run.preClusterVerificationReportDirectory) -Infrastructure $infra }
        $out.ReportDirectory = $reportDir
        $selected = @($definitions | Where-Object { -not $categories -or $_.Category -in $categories })
        $partial = [bool]($categories -and @($categories | Select-Object -Unique).Count -lt $contract.Categories.Count)
        $cluster = [string](Get-AzlProp $infra 'cluster.name' '')

        # ---- Plan: offline, what would be checked
        if ($Mode -eq 'Plan') {
            $plan = @(Get-AzlPclPlan -Infrastructure $infra -Category $categories -Definition $definitions)
            $out.Plan = $plan
            $null = New-Item -ItemType Directory -Force -Path $reportDir
            ConvertTo-Json -InputObject ([ordered]@{ schema = 1; mode = 'Plan'; cluster = $cluster; generatedUtc = (& $Adapter.Now).ToUniversalTime().ToString('o'); checks = $plan }) -Depth 6 | Set-Content -LiteralPath (Join-Path $reportDir 'plan.json') -Encoding utf8NoBOM
            Format-AzlPclPlan -Plan $plan -Cluster $cluster | Set-Content -LiteralPath (Join-Path $reportDir 'plan.md') -Encoding utf8NoBOM
            $out.Message = "Plan: $(@($plan | Where-Object { $_.Applies }).Count) of $($plan.Count) checks apply to $cluster. Nothing was read and no result was written for the ARM run."
            $out.NextAction = "Run the checks: $(Get-AzlPclCommand -InfrastructureFile $InfrastructureFile -ReportDirectory $ReportDirectory -HandoffFile $HandoffFile -OsConfigurationReport $(if ($OsConfigurationReport -is [string]) { $OsConfigurationReport } else { '' }))"
            $out.Checks = @($plan)
            return [pscustomobject]$out
        }

        # ---- Verify
        if (-not $InfrastructureFile -or -not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { Stop-AzlPclInput 'Mode Verify needs -InfrastructureFile: the result is tied to the SHA-256 of that file.' }
        $fileHash = Get-AzlPclFileHash -Path $InfrastructureFile
        $handoff = if ($HandoffFile) { if (-not (Test-Path -LiteralPath $HandoffFile)) { Stop-AzlPclInput "Handoff file not found: $HandoffFile" }; Read-AzlHandoff -Path $HandoffFile } else { $null }
        $osReport = if ($OsConfigurationReport -is [string] -and $OsConfigurationReport) { Read-AzlArmOsReport -Path $OsConfigurationReport } elseif ($OsConfigurationReport -and $OsConfigurationReport -isnot [string]) { $OsConfigurationReport } else { $null }
        $ctx = New-AzlPclContext -Infrastructure $infra -InfrastructureFile $InfrastructureFile -Handoff $handoff -OsReport $osReport -Adapter $Adapter -Settings $run -Remoting $remoting -Fix ([bool]$Fix) -Mode Verify
        $null = New-Item -ItemType Directory -Force -Path $reportDir
        $reportPath = Join-Path $reportDir $contract.ReportFile
        $summaryPath = Join-Path $reportDir $contract.SummaryFile
        $eventPath = Join-Path $reportDir $contract.EventFile
        # No result counts while a run is in progress: the previous report moves aside first.
        if (Test-Path -LiteralPath $reportPath) { Move-Item -LiteralPath $reportPath -Destination (Join-Path $reportDir 'report.previous.json') -Force }
        if (Test-Path -LiteralPath $eventPath) { Remove-Item -LiteralPath $eventPath -Force }
        $runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $runState = [pscustomobject]@{ RunId = $runId; EventPath = $eventPath; Seq = 0; Adapter = $Adapter }
        $started = (& $Adapter.Now).ToUniversalTime()
        $null = Write-AzlPclEvent -Run $runState -Type RunStarted -Extra @{ message = "Pre-cluster verification of $cluster started: $($selected.Count) checks, $($ctx.Nodes.Count) node(s), categories $(if ($categories) { $categories -join ', ' } else { 'all' }), -Fix $([bool]$Fix)." }
        $results = @(Invoke-AzlPclCheckSet -Ctx $ctx -Run $runState -Definition $selected -Accepted $accepted)

        # ---- verdict, report, summary
        $completed = (& $Adapter.Now).ToUniversalTime()
        $expires = $completed.AddHours([int]$run.preClusterVerificationMaxAgeHours)
        $blocking = @($results | Where-Object { $_.Blocking })
        $verdict = if ($blocking.Count) { 'Fail' } else { 'Pass' }
        $counts = Get-AzlPclCount $results
        $report = [ordered]@{
            schema = 1; runId = $runId; mode = 'Verify'; partial = $partial; verdict = $verdict; cluster = $cluster; infrastructureFile = ([IO.Path]::GetFullPath($InfrastructureFile)); fileHash = $fileHash
            startedUtc = $started.ToString('o', [cultureinfo]::InvariantCulture); completedUtc = $completed.ToString('o', [cultureinfo]::InvariantCulture); expiresUtc = $expires.ToString('o', [cultureinfo]::InvariantCulture)
            maxAgeHours = [int]$run.preClusterVerificationMaxAgeHours; counts = $counts; acceptedSkipped = @($results | Where-Object { $_.Accepted } | ForEach-Object { $_.Id } | Select-Object -Unique); fixesApplied = [bool]$Fix
            modules = @($extension.Modules | ForEach-Object { [ordered]@{ name = $_.Name; checks = $_.Checks; error = $_.Error } })
            categories = [ordered]@{}
            checks = @($results | ForEach-Object { [ordered]@{ checkId = $_.Id; category = $_.Category; title = $_.Title; status = $_.Status; node = $_.Node; message = $_.Message; remedy = $_.Remedy; source = $_.Source; blocking = $_.Blocking; accepted = $_.Accepted; details = @($_.Details) } })
        }
        foreach ($cat in $script:CategoryNames) {
            $inCat = @($results | Where-Object { $_.Category -eq $cat })
            if ($inCat.Count) { $row = [ordered]@{ results = $inCat.Count; blocking = @($inCat | Where-Object { $_.Blocking }).Count }; foreach ($s in $script:Statuses) { $row[$s] = @($inCat | Where-Object { $_.Status -eq $s }).Count }; $report.categories[$cat] = $row }
        }
        (Hide-AzlPclSecret ($report | ConvertTo-Json -Depth 8)) | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
        (Hide-AzlPclSecret (Format-AzlPclSummary -Report ([pscustomobject]$report))) | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
        $null = Write-AzlPclEvent -Run $runState -Type RunCompleted -Extra @{ message = "Verdict ${verdict}: $($blocking.Count) blocking result(s) of $($results.Count)."; verdict = $verdict; counts = $counts; fileHash = $fileHash; expiresUtc = $expires.ToString('o', [cultureinfo]::InvariantCulture) }

        $out.Verdict = $verdict; $out.Counts = $counts; $out.Checks = $results; $out.RunId = $runId; $out.FileHash = $fileHash; $out.ExpiresUtc = $report.expiresUtc
        $out.ReportPath = $reportPath; $out.SummaryPath = $summaryPath; $out.EventPath = $eventPath
        $armScript = Join-Path (Split-Path -Parent $contract.GateScript) 'Invoke-AzureLocalArmDeployment.ps1'
        if ($verdict -eq 'Pass') {
            $out.ExitCode = 0
            $out.Message = "Verdict Pass: $($results.Count) results ($((($counts.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '))). Valid until $($report.expiresUtc)$(if ($partial) { '; a PARTIAL run, the ARM run will not accept it' })."
            $out.NextAction = "Run the ARM Validate: & '$armScript' -InfrastructureFile '$InfrastructureFile' -Mode Validate"
        }
        else {
            $out.ExitCode = 1
            $first = $blocking | Select-Object -First 1
            $out.Message = "Verdict Fail: $($blocking.Count) blocking result(s): $((@($blocking | ForEach-Object { "$($_.Id)$(if ($_.Node -ne '*') { '@' + $_.Node })" } | Select-Object -Unique)) -join ', ')."
            $out.NextAction = "$($first.Id): $($first.Remedy)"
        }
    }
    catch {
        $code = if ($_.Exception.Data -and $_.Exception.Data.Contains('AzlExit')) { [int]$_.Exception.Data['AzlExit'] } else { 1 }
        $out.ExitCode = $code
        $out.Message = Hide-AzlPclSecret $_.Exception.Message
        $out.NextAction = if ($code -eq 2) { 'Fix the input and run again.' } else { 'Read the message above.' }
    }
    return [pscustomobject]$out
}

Export-ModuleMember -Function Get-AzlPclExtensionFolder, Import-AzlPclExtension, Get-AzlPclCatalog, Get-AzlPclPlan, New-AzlPclAdapter, Invoke-AzlPreClusterVerification, Get-AzlPclPayload, Hide-AzlPclSecret, Get-AzlPclOuRight
