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
Import-Module ([IO.Path]::Combine($script:Common, 'node-configuration', 'AzlNodeTransport.psm1'))
Import-Module ([IO.Path]::Combine($script:Common, 'node-configuration', 'AzlRemoting.psm1'))

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
        (whether a Failed or an unaccepted Skipped result blocks the verdict) and Fixable (-Fix can repair it). The built-in checks plus the modules.
    #>
    [CmdletBinding()]
    param([string[]]$Category, [string]$ExtensionFolder = (Get-AzlPclExtensionFolder))
    # The effective catalog: the built-in checks and the checks of the verification modules of the folder.
    $definitions = Get-AzlPclDefinitionSet (Import-AzlPclExtension -Folder $ExtensionFolder)
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
    $a['Remote'] = [ordered]@{ Invoke = { param($Request) Invoke-AzlPclRemote -Request $Request } }
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
            Fix = [bool]$Ctx.Fix; Mode = $Ctx.Mode; Cache = $Ctx.Cache; Remoting = $Ctx.Remoting
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read inside the wrapper script blocks the definition carries.')]
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

function Write-AzlPclFileAtomic {
    # Writes the text to a temporary file next to -Path and moves it over -Path, so a reader sees the old file or the whole new one.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $temporary = "$Path.tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}

function New-AzlPclExtFailure {
    # The check that stands in for a verification module that is missing or does not load: it fails, blocking, with the reason.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Ctx and Def keep the signature of every check Run block; Def is read through the stored text.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory definition; changes no system state.')]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Why)
    [pscustomobject]@{ Id = "EXT-$($Name -replace '^AzlVerification\.', '')"; Category = 'readiness'; Title = "The verification module $Name loads"; Source = "scripts/common/arm-deployment/verification/$Name.psm1"; Reads = 'the verification module file'
        Blocking = $true; Fixable = $false; Module = $Name; Applies = { $true }; Run = { param($Ctx, $Def) throw $Def.Why }; Why = $Why }
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
    param([string]$Folder = (Get-AzlPclExtensionFolder), [string[]]$Expected = @())
    $defs = [System.Collections.Generic.List[object]]::new(); $adapters = [ordered]@{}; $modules = [System.Collections.Generic.List[object]]::new(); $checklists = [System.Collections.Generic.List[object]]::new()
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder -PathType Container)) {
        $why = "The folder of the verification modules does not exist ($Folder), so none of their checks can run."
        $modules.Add([pscustomobject]@{ Name = 'AzlVerification'; Checks = 0; Error = $why; Library = $false })
        $defs.Add((New-AzlPclExtFailure -Name 'AzlVerification.Folder' -Why $why))
    }
    if ($Folder -and (Test-Path -LiteralPath $Folder -PathType Container)) {
        foreach ($want in $Expected) {
            if (-not (Test-Path -LiteralPath (Join-Path $Folder "$want.psm1") -PathType Leaf)) {
                $why = "The verification module $want.psm1 is missing from $Folder, so its checks cannot run."
                $modules.Add([pscustomobject]@{ Name = $want; Checks = 0; Error = $why; Library = $false })
                $defs.Add((New-AzlPclExtFailure -Name $want -Why $why))
            }
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $Folder -Filter 'AzlVerification.*.psm1' -File | Sort-Object Name)) {
            $name = $file.BaseName
            try {
                $module = Import-Module -Name $file.FullName -Force -PassThru -ErrorAction Stop
                $getDefinitions = $module.ExportedCommands['Get-AzlVerificationCheckDefinition']
                $getAdapters = $module.ExportedCommands['Get-AzlVerificationAdapterDefault']
                # A module may also offer the switch port checklist (what its file expects on each switch port) for report.json and summary.md.
                if ($module.ExportedCommands['Get-AzlVerificationSwitchPortChecklist']) { $checklists.Add($module.ExportedCommands['Get-AzlVerificationSwitchPortChecklist']) }
                # A module that exports neither is a library the check modules share (AzlVerification.NodeCommon.psm1); it is loaded, not read.
                if (-not $getDefinitions -and -not $getAdapters) { $modules.Add([pscustomobject]@{ Name = $name; Checks = 0; Error = ''; Library = $true }); continue }
                if (-not $getDefinitions) { throw 'it does not export Get-AzlVerificationCheckDefinition' }
                $count = 0
                foreach ($d in @(& $getDefinitions)) { if ($null -ne $d) { $defs.Add((ConvertTo-AzlPclDefinition -Definition $d -Module $name)); $count++ } }
                if ($getAdapters) { Merge-AzlPclAdapter -Into $adapters -From (& $getAdapters) }
                $modules.Add([pscustomobject]@{ Name = $name; Checks = $count; Error = ''; Library = $false })
            }
            catch {
                $why = "The verification module $name could not be loaded: $($_.Exception.Message)"
                $modules.Add([pscustomobject]@{ Name = $name; Checks = 0; Error = $_.Exception.Message; Library = $false })
                $defs.Add((New-AzlPclExtFailure -Name $name -Why $why))
            }
        }
    }
    [pscustomobject]@{ Definitions = $defs.ToArray(); AdapterDefaults = $adapters; Modules = $modules.ToArray(); ChecklistCommands = $checklists.ToArray() }
}

function Get-AzlPclDefinitionSet {
    # The built-in catalog with the modules' definitions; a module definition with the Id of a built-in check replaces it.
    param($Extension)
    $byId = [ordered]@{}
    foreach ($d in $script:Catalog) { $byId[$d.Id] = $d }
    $fromModule = @{}
    if ($Extension) {
        foreach ($d in $Extension.Definitions) {
            if ($fromModule.ContainsKey($d.Id) -and $fromModule[$d.Id] -ne $d.Module) {
                # Two modules with one id: the second never silently wins. It becomes a failing check of its own.
                $dup = New-AzlPclExtFailure -Name "$($d.Module).Duplicate-$($d.Id)" -Why "The verification module $($d.Module) defines the check id $($d.Id), which the module $($fromModule[$d.Id]) already defines."
                $byId[$dup.Id] = $dup
                continue
            }
            $fromModule[$d.Id] = $d.Module
            $byId[$d.Id] = $d
        }
    }
    # The one check -Fix can repair: the module's resource provider check (the module itself never changes Azure).
    if ($byId.Contains('AZ-004')) { $byId['AZ-004'].Fixable = $true }
    return @($byId.Values)
}

function ConvertTo-AzlPclResultObject {
    # A result of a check as the engine reads it: an object or a table with Status, Node, Message, Remedy, Evidence (or Details).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Result is read inside the accessor script block.')]
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

function Merge-AzlPclAdapter {
    <#
    .SYNOPSIS
        Adds to -Into the members of -From that it does not have. A group (a table of members, such as Azure, Remote, Ad) present on both sides is
        merged member by member. What -Into has always stays: a test's fake, or an engine default, wins over a module's default.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Into, [Parameter(Mandatory)][System.Collections.IDictionary]$From)
    foreach ($k in @($From.Keys)) {
        if (-not $Into.Contains($k)) { $Into[$k] = $(if ($From[$k] -is [System.Collections.IDictionary]) { $copy = [ordered]@{}; foreach ($m in $From[$k].Keys) { $copy[$m] = $From[$k][$m] }; $copy } else { $From[$k] }) }
        elseif ($Into[$k] -is [System.Collections.IDictionary] -and $From[$k] -is [System.Collections.IDictionary]) {
            foreach ($m in @($From[$k].Keys)) { if (-not $Into[$k].Contains($m)) { $Into[$k][$m] = $From[$k][$m] } }
        }
    }
}

function Invoke-AzlPclRemote {
    <#
    .SYNOPSIS
        The default Adapters.Remote.Invoke: one read only WinRM call to a node, as the local administrator, over the toolkit's session options
        (New-AzlWinRmSessionOption of AzlNodeTransport: an open timeout of 30 s and a cancel timeout of 5 s), trying the node's addresses in order.
        The call runs as a job and is abandoned after a time limit, so a stalled node can never hang the run.
    .OUTPUTS
        Ok, Address, Result, Error, AuthFailed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request, [int]$TimeoutSeconds = 180)
    $last = ''; $auth = $false
    foreach ($address in @($Request.Addresses)) {
        $session = $null
        try {
            $arguments = @{ ComputerName = $address; Credential = $Request.Credential; SessionOption = (New-AzlWinRmSessionOption -SkipCertificateCheck:([bool]$Request.UseSsl)); ErrorAction = 'Stop' }
            $authentication = [string]$Request.Authentication
            if ($authentication) { $arguments.Authentication = $authentication }
            if ($Request.UseSsl) { $arguments.UseSSL = $true }
            $session = New-PSSession @arguments
            $job = Invoke-Command -Session $session -ScriptBlock $Request.ScriptBlock -ArgumentList @($Request.ArgumentList) -AsJob
            if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) { Stop-Job -Job $job; Remove-Job -Job $job -Force; throw "the call did not finish within $TimeoutSeconds seconds and was abandoned" }
            $result = Receive-Job -Job $job -ErrorAction Stop
            Remove-Job -Job $job -Force
            return [pscustomobject]@{ Ok = $true; Address = $address; Result = $result; Error = ''; AuthFailed = $false }
        }
        catch {
            $last = "${address}: $($_.Exception.Message)"
            if ($_.Exception.Message -match '(?i)access is denied|logon failure|user name or password is incorrect|authentication') { $auth = $true }
        }
        finally { if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } }
    }
    [pscustomobject]@{ Ok = $false; Address = ''; Result = $null; Error = $last; AuthFailed = $auth }
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
    if ($Report.environmentChecker) { $l.Add("- **Environment Checker on the nodes:** $($Report.environmentChecker.note)") }
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
    if (@($Report.switchPortChecklist).Count) {
        $l.Add('### Switch port checklist'); $l.Add('')
        $l.Add('The gate cannot read a switch. Verify each port against the file; the file is the authority.'); $l.Add('')
        $l.Add('| Switch | Port | Node | File port | MAC | Expected mode | Expected VLANs | Host tags | From the file |'); $l.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
        foreach ($r in @($Report.switchPortChecklist)) { $l.Add("| $($r.switch) | $($r.port) | $($r.node) | $($r.filePort) | $($r.mac) | $($r.expectedMode) | $(@($r.expectedVlans) -join ', ') | $(if ($r.hostTag -gt 0) { $r.hostTag } else { 'untagged' }) | $($r.source -replace '\|', '/') |") }
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

# ---------------------------------------------------------------------------------------------------------------------
# AZURE and IDENTITY: the checks of these categories are in verification/AzlVerification.Azure.psm1 and AzlVerification.Identity.psm1 (loaded by the
# engine). Built in here is only what no module has: the ARM parameters, and the -Fix handler of the resource providers (Invoke-AzlPclFix).
# ---------------------------------------------------------------------------------------------------------------------

Register-AzlPclCheck -Id 'ARM-001' -Category azure -Title 'The ARM parameters can be generated from the file and match the template' -Source "$script:Learn/deploy/deployment-azure-resource-manager-template?$script:View" -Reads 'the file (and the OS configuration report for adapter names)' -Run {
    param($Ctx)
    $r = Get-AzlPclParameterSet $Ctx
    if ($r.Error) { return New-AzlPclResult Failed "The ARM parameters cannot be generated from the file: $($r.Error)" 'Fix the file (Test-InfrastructureFile.ps1 names the key), then run the verification again.' }
    if ($r.Problems.Count) { return New-AzlPclResult Failed "$($r.Problems.Count) problem(s) in the ARM parameter set for template $($r.Set.Template.Name): $($r.Problems -join ' | ')" 'Fill the keys named above in infrastructure.yml (parameter-sources.md of an ARM Plan run maps each ARM parameter to its key).' -Details @($r.Problems) }
    New-AzlPclResult Passed "Template $($r.Set.Template.Name): $($r.Set.Parameters.Count) parameters generated and checked against the template."
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

function New-AzlPclRemoteRequest {
    <#
    .SYNOPSIS
        The request of Remote.Invoke for a node called by name: the node's management addresses from the file, the local administrator from Key Vault
        (read once, kept in memory, scrubbed from every output), the remoting settings of the run.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret was just read from Key Vault; it is made a SecureString at once and only ever lives in memory.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory request; changes no system state.')]
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    $user = [string](Get-AzlProp (Get-AzlProp $Ctx.Infra 'identity.local_admin') 'username' '')
    $null = Get-AzlPclAdminSecure -Ctx $Ctx
    $entry = @($Ctx.Nodes | Where-Object { ([string]$_['name']) -ieq $Node }) | Select-Object -First 1
    $addresses = @()
    if ($entry) {
        $mgmt = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $entry
        if ($mgmt -and $mgmt.IpAddress) { $addresses += [string]$mgmt.IpAddress }
        $addresses += @(Get-AzlNodeRemotingAddress -Node $entry -ManagementMac $(if ($mgmt) { [string]$mgmt.MacAddress } else { '' }))
    }
    $addresses = @($addresses | Where-Object { $_ } | Select-Object -Unique)
    if (-not $addresses.Count) { $addresses = @($Node) }
    $short = ($Node -split '\.')[0]
    [pscustomobject]@{
        Node = $Node; Addresses = $addresses; Credential = [pscredential]::new("$short\$user", $Ctx.Cache['AdminSecure']); ScriptBlock = $ScriptBlock; ArgumentList = @($ArgumentList)
        UseSsl = [bool]$(if ($Ctx.Remoting) { $Ctx.Remoting.UseSsl } else { $false }); Authentication = [string]$(if ($Ctx.Remoting) { $Ctx.Remoting.Authentication } else { 'Negotiate' })
    }
}

function Invoke-AzlPclRemoteShim {
    <#
    .SYNOPSIS
        The engine's Adapters.Remote.Invoke, both forms: (node name, script block [, argument list]) returns what the script block output and throws when the
        call fails; (request object) returns Ok, Address, Result, Error, AuthFailed. It runs in this module, so it reads the context of the run from the module.
    #>
    param($First, $Second, $Third)
    if ($First -is [string]) {
        $request = New-AzlPclRemoteRequest -Ctx $script:ShimContext -Node $First -ScriptBlock $Second -ArgumentList @($Third)
        $answer = Invoke-AzlPclRemote -Request $request
        if (-not $answer.Ok) { throw "The call to $First failed: $($answer.Error)" }
        return $answer.Result
    }
    return (Invoke-AzlPclRemote -Request $First)
}

function Get-AzlPclAdminSecure {
    <#
    .SYNOPSIS
        The local administrator password from Key Vault as a SecureString, read once per run and kept in memory (registered for scrubbing). Throws when the file
        names no local administrator.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret was just read from Key Vault; it is made a SecureString at once and only ever lives in memory.')]
    param([Parameter(Mandatory)]$Ctx)
    $local = Get-AzlProp $Ctx.Infra 'identity.local_admin'
    $user = [string](Get-AzlProp $local 'username' ''); $ref = [string](Get-AzlProp $local 'password' '')
    if (-not $user -or -not $ref) { throw 'identity.local_admin.username or password is not set: there is no credential for the node.' }
    if (-not $Ctx.Cache.ContainsKey('AdminSecure')) {
        $plain = [string](Invoke-AzlPclAdapter $Ctx GetSecret @($ref))
        Register-AzlPclSecret $plain
        $Ctx.Cache['AdminSecure'] = ConvertTo-SecureString -String $plain -AsPlainText -Force
        $plain = $null
    }
    return $Ctx.Cache['AdminSecure']
}

function Set-AzlPclReadinessCredential {
    <#
    .SYNOPSIS
        Gives the readiness adapter (Adapters.Readiness.Credential and .Address) the local administrator credential the engine already uses for Remote.Invoke
        and the management address of every node, unless the module or the caller already brought them. The Software and Network validators compare the nodes
        through PowerShell sessions opened from one node and need exactly that credential (a local account: .\user). Returns $true when it set them.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fills an in-memory table; changes no system state.')]
    param([Parameter(Mandatory)]$Ctx)
    $readiness = $Ctx.Adapter['Readiness']
    if ($readiness -isnot [System.Collections.IDictionary]) { return $false }
    if ($readiness.Contains('Credential') -and $readiness['Credential']) { return $false }
    $secure = Get-AzlPclAdminSecure -Ctx $Ctx
    $user = [string](Get-AzlProp (Get-AzlProp $Ctx.Infra 'identity.local_admin') 'username' '')
    $map = @{}
    foreach ($n in $Ctx.Nodes) {
        $mgmt = Get-AzlManagementAdapter -Infrastructure $Ctx.Infra -Node $n
        if ($mgmt -and $mgmt.IpAddress) { $map[[string]$n['name']] = [string]$mgmt.IpAddress }
    }
    $readiness['Credential'] = [pscredential]::new(".\$user", $secure)
    if (-not $readiness.Contains('Address') -or -not $readiness['Address'] -or -not @($readiness['Address'].Keys).Count) { $readiness['Address'] = $map }
    return $true
}

function Set-AzlPclEnvironmentChecker {
    <#
    .SYNOPSIS
        Installs (-Action Install) or removes (-Action Remove) the Environment Checker module on every node, through Remote.Invoke. Only with
        -InstallEnvironmentChecker; the gate never installs it otherwise. Learn says to remove it from the nodes before the deployment, so the
        run removes what it installed in a finally block (unless -KeepEnvironmentChecker). Returns the nodes it acted on and the errors.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only called for the explicit -InstallEnvironmentChecker switch, which is the operator confirmation; it is removed again at the end.')]
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][ValidateSet('Install', 'Remove')][string]$Action)
    $install = {
        $ErrorActionPreference = 'Stop'
        $had = [bool](Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker)
        if (-not $had) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) { $null = Install-PackageProvider -Name NuGet -Force -Scope AllUsers }
            Install-Module -Name AzStackHci.EnvironmentChecker -Repository PSGallery -Scope AllUsers -Force -AllowClobber
        }
        [pscustomobject]@{ had = $had; present = [bool](Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker) }
    }
    $remove = {
        $ErrorActionPreference = 'Stop'
        Remove-Module AzStackHci.EnvironmentChecker -Force -ErrorAction SilentlyContinue
        Get-Module AzStackHci.EnvironmentChecker -ListAvailable | Where-Object { $_.Path -like "*$($_.Version)*" } | Uninstall-Module -Force
        [pscustomobject]@{ present = [bool](Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker) }
    }
    $invoke = $Ctx.Adapter['Remote']['Invoke']
    $done = [System.Collections.Generic.List[string]]::new(); $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        try {
            $r = & $invoke $name $(if ($Action -eq 'Install') { $install } else { $remove }) @()
            $r = @($r) | Select-Object -Last 1
            if ($Action -eq 'Install' -and -not [bool](Get-AzlProp $r 'had' $false)) { $done.Add($name) }
            elseif ($Action -eq 'Remove' -and -not [bool](Get-AzlProp $r 'present' $true)) { $done.Add($name) }
            elseif ($Action -eq 'Remove') { $errors.Add("${name}: the module is still installed after the removal") }
        }
        catch { $errors.Add("${name}: $(Hide-AzlPclSecret $_.Exception.Message)") }
    }
    [pscustomobject]@{ Nodes = $done.ToArray(); Errors = $errors.ToArray() }
}

function New-AzlPclEndpointProbe {
    <#
    .SYNOPSIS
        Adapters.Azure.TestEndpoint(Address, Target[], Credential) on top of Adapters.Remote.Invoke: TCP probes from the node at Address.
        Rows of Host, Port, Ok, Error.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read inside the returned script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a script block; changes no system state.')]
    param([Parameter(Mandatory)]$Adapter, $Remoting)
    $probe = {
        param($List)
        foreach ($t in $List) {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            try {
                $task = $tcp.ConnectAsync([string]$t.Host, [int]$t.Port)
                $ok = $task.Wait(5000) -and $tcp.Connected
                [pscustomobject]@{ Host = [string]$t.Host; Port = [int]$t.Port; Ok = [bool]$ok; Error = $(if ($ok) { '' } else { 'no answer in 5 seconds' }) }
            }
            catch { [pscustomobject]@{ Host = [string]$t.Host; Port = [int]$t.Port; Ok = $false; Error = $_.Exception.GetBaseException().Message } }
            finally { $tcp.Dispose() }
        }
    }
    $ssl = [bool]$(if ($Remoting) { $Remoting.UseSsl } else { $false })
    $authentication = [string]$(if ($Remoting) { $Remoting.Authentication } else { 'Negotiate' })
    {
        param($Address, $Target, [pscredential]$Credential)
        $request = [pscustomobject]@{ Node = [string]$Address; Addresses = @([string]$Address); Credential = $Credential; ScriptBlock = $probe; ArgumentList = @(, @($Target)); UseSsl = $ssl; Authentication = $authentication }
        $answer = & $Adapter['Remote']['Invoke'] $request
        if (-not $answer.Ok) { throw "the probe from $Address did not run: $($answer.Error)" }
        @($answer.Result | ForEach-Object { [pscustomobject]@{ Host = $_.Host; Port = $_.Port; Ok = $_.Ok; Error = $_.Error } })
    }.GetNewClosure()
}

function Invoke-AzlPclFix {
    <#
    .SYNOPSIS
        The -Fix of the gate, Azure side only: registers the mandatory resource providers that are not registered (the failing check AZ-004) and waits until
        they are Registered. Returns the Fixed result, or a Failed one that says why not. Only reached with -Fix in Mode Verify.
    #>
    param([Parameter(Mandatory)]$Ctx)
    $azure = if ($Ctx.Adapter['Azure'] -is [System.Collections.IDictionary]) { $Ctx.Adapter['Azure'] } else { @{} }
    $read = { param($Ns) if ($azure.Contains('GetProviderState') -and $azure['GetProviderState']) { & $azure['GetProviderState'] $Ctx.Subscription $Ns } else { Invoke-AzlPclAdapter $Ctx GetProviderState @($Ctx.Subscription, $Ns) } }
    $providers = @(Get-AzlArmMandatoryProvider)
    $state = [ordered]@{}
    foreach ($ns in $providers) { $state[$ns] = [string](& $read $ns) }
    $missing = @($providers | Where-Object { $state[$_] -ne 'Registered' })
    if (-not $missing) { return New-AzlPclResult Passed "All $($providers.Count) mandatory resource providers are registered." }
    $notFound = @($missing | Where-Object { $state[$_] -eq 'NotFound' })
    if ($notFound) { return New-AzlPclResult Failed "These providers do not exist in the subscription, so they cannot be registered: $($notFound -join ', ')." 'A sovereign cloud may not offer a provider; check the Azure cloud of the file.' }
    $requested = [System.Collections.Generic.List[string]]::new()
    foreach ($ns in $missing) {
        if ($state[$ns] -eq 'Registering') { continue }
        try { $null = Invoke-AzlPclAdapter $Ctx RegisterProvider @($Ctx.Subscription, $ns) }
        catch { return New-AzlPclResult Failed "Registering $ns failed: $($_.Exception.Message)" "Owner or Contributor on the subscription is needed. Register it yourself: Register-AzResourceProvider -ProviderNamespace $ns" }
        $requested.Add($ns)
    }
    $deadline = (& $Ctx.Adapter.Now).AddMinutes(15)
    $pending = @($missing)
    while ($true) {
        $pending = @($pending | Where-Object { [string](& $read $_) -ne 'Registered' })
        if (-not $pending) { break }
        if ((& $Ctx.Adapter.Now) -ge $deadline) { return New-AzlPclResult Failed "Registration was requested ($($requested -join ', ')) but these are not Registered after 15 minutes: $($pending -join ', ')." 'Wait for them (Get-AzResourceProvider -ProviderNamespace <name> shows RegistrationState), then run the verification again.' }
        $null = Invoke-AzlPclAdapter $Ctx Sleep @(10)
    }
    New-AzlPclResult Fixed "Registered by -Fix: $($missing -join ', '). The other $($providers.Count - $missing.Count) mandatory providers already were Registered."
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
        # -Fix (Verify only): the failing resource provider check is repaired on the Azure side, and the result says so.
        if ($def.Fixable -and $Ctx.Fix -and $Ctx.Mode -eq 'Verify' -and @($raw | Where-Object { $_.Status -eq 'Failed' }).Count) {
            try { $raw = @(Invoke-AzlPclFix -Ctx $Ctx) }
            catch { $raw = @(New-AzlPclResult Failed "-Fix could not run: $($_.Exception.Message)" 'Register the providers yourself with Register-AzResourceProvider -ProviderNamespace <name>.') }
        }
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
        [System.Collections.IDictionary]$Adapter,
        [string]$ExtensionFolder = (Get-AzlPclExtensionFolder),
        [switch]$InstallEnvironmentChecker,
        [switch]$KeepEnvironmentChecker,
        [switch]$AllowRevalidate
    )
    $script:Secrets.Clear()
    # No -Adapter: the engine builds everything. A table the caller gives holds only what the caller wants to replace (a test's fakes).
    if ($null -eq $Adapter) { $Adapter = [ordered]@{} }
    # Who supplied what decides who wins: a member the caller gave (a test's fake) beats the engine's, which beats a module's default.
    $callerHasRemote = ($Adapter.Contains('Remote') -and $Adapter['Remote'] -is [System.Collections.IDictionary] -and $Adapter['Remote'].Contains('Invoke'))
    $callerHasTestEndpoint = ($Adapter.Contains('Azure') -and $Adapter['Azure'] -is [System.Collections.IDictionary] -and $Adapter['Azure'].Contains('TestEndpoint'))
    Merge-AzlPclAdapter -Into $Adapter -From (New-AzlPclAdapter)
    # The verification modules: their checks join the catalog, and the read only adapter members they bring (groups Azure, Ad, Dns, Remote, KeyVault, Clock ...) fill the gaps.
    # The default folder must hold every module of the repository; a missing one is a failing check. A folder given by a test holds what the test says.
    $expectedModules = if ($ExtensionFolder -eq (Get-AzlPclExtensionFolder)) { @('AzlVerification.Azure', 'AzlVerification.Identity', 'AzlVerification.Network', 'AzlVerification.Nodes', 'AzlVerification.Sbe', 'AzlVerification.Storage', 'AzlVerification.NodeCommon', 'AzlVerification.Endpoints') } else { @() }
    $extension = Import-AzlPclExtension -Folder $ExtensionFolder -Expected $expectedModules
    Merge-AzlPclAdapter -Into $Adapter -From $extension.AdapterDefaults
    $definitions = @(Get-AzlPclDefinitionSet $extension)
    $contract = Get-AzlPclContract
    $out = [ordered]@{ ExitCode = 0; Verdict = ''; Mode = $Mode; Message = ''; NextAction = ''; ReportDirectory = ''; ReportPath = ''; SummaryPath = ''; EventPath = ''; Counts = $null; Checks = @(); RunId = ''; FileHash = ''; ExpiresUtc = ''; Plan = @() }
    try {
        # ---- inputs
        # The hash of the bytes is taken before they are parsed, and compared again after the checks: a result belongs to one version of the file.
        $fileHash = if ($InfrastructureFile -and (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { Get-AzlPclFileHash -Path $InfrastructureFile } else { '' }
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
        if ($InstallEnvironmentChecker) { $armSettings['installEnvironmentChecker'] = $true }
        if ($KeepEnvironmentChecker) { $armSettings['keepEnvironmentChecker'] = $true }
        if ($AllowRevalidate) { $armSettings['allowRevalidate'] = $true }
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
        $handoff = if ($HandoffFile) { if (-not (Test-Path -LiteralPath $HandoffFile)) { Stop-AzlPclInput "Handoff file not found: $HandoffFile" }; Read-AzlHandoff -Path $HandoffFile } else { $null }
        $osReport = if ($OsConfigurationReport -is [string] -and $OsConfigurationReport) { Read-AzlArmOsReport -Path $OsConfigurationReport } elseif ($OsConfigurationReport -and $OsConfigurationReport -isnot [string]) { $OsConfigurationReport } else { $null }
        $ctx = New-AzlPclContext -Infrastructure $infra -InfrastructureFile $InfrastructureFile -Handoff $handoff -OsReport $osReport -Adapter $Adapter -Settings $run -Remoting $remoting -Fix ([bool]$Fix) -Mode Verify
        # Remote.Invoke serves both forms the modules use: (node, scriptblock [, arguments]) returning what the script block output, and the request object
        # returning Ok, Address, Result, Error, AuthFailed. A caller's own Remote.Invoke (a test's fake) is left alone.
        if (-not $callerHasRemote) {
            $script:ShimContext = $ctx
            $Adapter['Remote']['Invoke'] = ${function:Invoke-AzlPclRemoteShim}
        }
        # The readiness validators open PowerShell sessions between the nodes: they need the same local administrator credential. A secret that cannot be read only leaves them Skipped, with the reason.
        try { $null = Set-AzlPclReadinessCredential -Ctx $ctx } catch { Write-Verbose "No readiness credential: $($_.Exception.Message)" }
        # The nodes are probed from the node itself over the engine's WinRM call (Adapters.Remote.Invoke), so a workgroup node reached by IP is not Skipped.
        if (-not $callerHasTestEndpoint -and $Adapter['Remote'] -is [System.Collections.IDictionary] -and $Adapter['Remote'].Contains('Invoke')) {
            if (-not ($Adapter['Azure'] -is [System.Collections.IDictionary])) { $Adapter['Azure'] = [ordered]@{} }
            $Adapter['Azure']['TestEndpoint'] = New-AzlPclEndpointProbe -Adapter $Adapter -Remoting $remoting
        }
        $null = New-Item -ItemType Directory -Force -Path $reportDir
        $reportPath = Join-Path $reportDir $contract.ReportFile
        $summaryPath = Join-Path $reportDir $contract.SummaryFile
        $eventPath = Join-Path $reportDir $contract.EventFile
        $out.ReportPath = $reportPath; $out.SummaryPath = $summaryPath; $out.EventPath = $eventPath
        # No result counts while a run is in progress: the previous report moves aside first.
        if (Test-Path -LiteralPath $reportPath) { Move-Item -LiteralPath $reportPath -Destination (Join-Path $reportDir 'report.previous.json') -Force }
        if (Test-Path -LiteralPath $eventPath) { Remove-Item -LiteralPath $eventPath -Force }
        $runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $runState = [pscustomobject]@{ RunId = $runId; EventPath = $eventPath; Seq = 0; Adapter = $Adapter }
        $started = (& $Adapter.Now).ToUniversalTime()
        $null = Write-AzlPclEvent -Run $runState -Type RunStarted -Extra @{ message = "Pre-cluster verification of $cluster started: $($selected.Count) checks, $($ctx.Nodes.Count) node(s), categories $(if ($categories) { $categories -join ', ' } else { 'all' }), -Fix $([bool]$Fix)." }
        $runCompleted = $false
        try {
        # The Environment Checker: only with -InstallEnvironmentChecker is it put on the nodes, and (Learn: remove it before the deployment) taken off again at the end.
        $envChecker = [ordered]@{ requested = [bool]$run.installEnvironmentChecker; kept = [bool]$run.keepEnvironmentChecker; installedOn = @(); removedFrom = @(); errors = @(); note = 'The gate did not touch the Environment Checker on the nodes.' }
        try {
            if ($envChecker.requested) {
                $installed = Set-AzlPclEnvironmentChecker -Ctx $ctx -Action Install
                $envChecker.installedOn = @($installed.Nodes); $envChecker.errors = @($installed.Errors)
            }
            $results = @(Invoke-AzlPclCheckSet -Ctx $ctx -Run $runState -Definition $selected -Accepted $accepted)
        }
        finally {
            if ($envChecker.requested -and -not $run.keepEnvironmentChecker) {
                $removed = Set-AzlPclEnvironmentChecker -Ctx $ctx -Action Remove
                $envChecker.removedFrom = @($removed.Nodes); $envChecker.errors = @($envChecker.errors) + @($removed.Errors)
            }
        }
        $envChecker.note = if (-not $envChecker.requested) { 'The gate did not install or touch the Environment Checker on the nodes (readiness checks that need it are Skipped where it is missing).' }
        elseif ($run.keepEnvironmentChecker) { "The gate installed the Environment Checker on $(@($envChecker.installedOn).Count) node(s) and KEPT it (-KeepEnvironmentChecker). Learn: uninstall it from the nodes before the deployment." }
        elseif (@($envChecker.errors).Count) { "The gate installed the Environment Checker on $(@($envChecker.installedOn).Count) node(s); removing it failed on some: $(@($envChecker.errors) -join '; '). Learn: uninstall it from the nodes before the deployment." }
        else { "The gate installed the Environment Checker on $(@($envChecker.installedOn).Count) node(s) for this run and REMOVED it again from $(@($envChecker.removedFrom).Count) node(s) at the end (Learn: uninstall it from the nodes before the deployment)." }

        # ---- the switch port checklist: what the file expects on each switch port (the gate cannot read a switch)
        $checklist = [System.Collections.Generic.List[object]]::new()
        foreach ($command in @($extension.ChecklistCommands)) {
            try { foreach ($row in @(& $command -Context (Get-AzlPclContextTable $ctx))) { $checklist.Add($row) } }
            catch { Write-Verbose "The switch port checklist could not be made: $($_.Exception.Message)" }
        }

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
            environmentChecker = $envChecker
            switchPortChecklist = @($checklist)
            modules = @($extension.Modules | ForEach-Object { [ordered]@{ name = $_.Name; checks = $_.Checks; error = $_.Error } })
            categories = [ordered]@{}
            checks = @($results | ForEach-Object { [ordered]@{ checkId = $_.Id; category = $_.Category; title = $_.Title; status = $_.Status; node = $_.Node; message = $_.Message; remedy = $_.Remedy; source = $_.Source; blocking = $_.Blocking; accepted = $_.Accepted; details = @($_.Details) } })
        }
        foreach ($cat in $script:CategoryNames) {
            $inCat = @($results | Where-Object { $_.Category -eq $cat })
            if ($inCat.Count) { $row = [ordered]@{ results = $inCat.Count; blocking = @($inCat | Where-Object { $_.Blocking }).Count }; foreach ($s in $script:Statuses) { $row[$s] = @($inCat | Where-Object { $_.Status -eq $s }).Count }; $report.categories[$cat] = $row }
        }
        # The file the checks ran against must still be the file that was parsed.
        if ((Get-AzlPclFileHash -Path $InfrastructureFile) -ne $fileHash) { throw 'The infrastructure file changed while the checks ran, so the result would describe a file that no longer exists. Run the verification again.' }
        # summary.md first, report.json last, each through a temporary file: a Pass report exists only when every output was written.
        Write-AzlPclFileAtomic -Path $summaryPath -Text (Hide-AzlPclSecret (Format-AzlPclSummary -Report ([pscustomobject]$report)))
        Write-AzlPclFileAtomic -Path $reportPath -Text (Hide-AzlPclSecret ($report | ConvertTo-Json -Depth 8))
        $eventOk = Write-AzlPclEvent -Run $runState -Type RunCompleted -Extra @{ message = "Verdict ${verdict}: $($blocking.Count) blocking result(s) of $($results.Count)."; verdict = $verdict; counts = $counts; fileHash = $fileHash; expiresUtc = $expires.ToString('o', [cultureinfo]::InvariantCulture) }
        if (-not $eventOk) { throw 'The RunCompleted event could not be written to the feed.' }
        $runCompleted = $true
        }
        catch {
            # A run that fails after it started still ends its feed, and leaves no report that could unlock the ARM run.
            $failure = Hide-AzlPclSecret $_.Exception.Message
            if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue }
            if (-not $runCompleted) { $null = Write-AzlPclEvent -Run $runState -Type RunCompleted -Extra @{ message = "The run failed: $failure"; verdict = 'Error'; counts = @{}; fileHash = $fileHash; expiresUtc = '' } }
            throw
        }

        $out.Verdict = $verdict; $out.Counts = $counts; $out.Checks = $results; $out.RunId = $runId; $out.FileHash = $fileHash; $out.ExpiresUtc = $report.expiresUtc
        $out.ReportPath = $reportPath; $out.SummaryPath = $summaryPath; $out.EventPath = $eventPath
        $armScript = Join-Path (Split-Path -Parent $contract.GateScript) 'Invoke-AzureLocalArmDeployment.ps1'
        if ($verdict -eq 'Pass') {
            $out.ExitCode = $(if ($partial) { 3 } else { 0 })
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

Export-ModuleMember -Function Get-AzlPclExtensionFolder, Import-AzlPclExtension, Get-AzlPclCatalog, Get-AzlPclPlan, New-AzlPclAdapter, Invoke-AzlPreClusterVerification, Hide-AzlPclSecret
