<#
.SYNOPSIS
    Changes the individual security baseline settings that security.baseline_settings of infrastructure.yml lists, with Set-AzsSecurity.

.DESCRIPTION
    Phase 04 (security and governance), Task 03 (security baselines). Azure Local applies a security baseline when it is deployed and reapplies it on
    every update, and drift control holds each setting at the baseline value, or at the value you customized (Microsoft Learn, Manage security
    defaults for Azure Local). From version 2610 the only supported way to change the value of one setting is Set-AzsSecurity (module
    AzureStackOSConfigAgent, installed by the deployment); Group Policy or the registry is not supported and drift control reverts it. This script
    does exactly that and nothing else: it does not assess the machines, does not set audit policy, TLS, SMB signing or any other value on its
    own, and does not turn drift control off. The features Enable-AzsSecurity and Disable-AzsSecurity switch (Credential Guard, HVCI, DRTM, SMB
    signing and so on) are the deployment's keys under security, not this list.

    For each entry of security.baseline_settings the script connects to one machine of the instance with PowerShell remoting and:
      1. reads the settings that already have a recorded customization (Get-AzsSecurityPolicyIntent);
      2. leaves an entry whose value is recorded already (AlreadySet);
      3. otherwise runs  Set-AzsSecurity -Type <type> -SettingName <name> -Value <value> -Cluster -Confirm:$false
         The scope is always -Cluster, which Learn recommends: the change is recorded as cluster policy intent, applied on every machine and
         applied again by every update. Learn: do not also change such a setting on a single machine.
         For an entry with acknowledge_weaker_security true the script adds -Force, which Learn describes together with -Confirm:$false for
         unattended use: it suppresses the warning that a few settings show. Without it a setting that asks for that confirmation fails
         and is reported, and nothing is changed.
    A setting that Learn lists as blocked (credential protection and authentication, platform integrity, the host firewall, the minimum SMB
    version, remote management, Microsoft Defender Antivirus real-time protection) is refused before anything is sent (exit 2). The names must
    match the Name column of the baseline CSV of your version exactly; the script cannot check them, the cmdlet does.

    The cmdlets exist only on Azure Local 2610 or later, on new deployments or on upgraded ones after the baseline is applied. When they are missing
    the script stops (exit 1) and says so.

    Idempotent. -WhatIf reads the recorded customizations and changes nothing. Resetting a setting to its baseline (Set-AzsSecurity -Default) is not done
    by this script: remove the entry from the file and run the cmdlet by hand if you need that.

    The script does not sign in anywhere and asks nothing. Without -Credential it connects as the local administrator of identity.local_admin (the
    password is a secret reference, read through scripts/common/secrets/AzlSecret.psm1; sign in first with Connect-AzAccount when it is a Key Vault
    reference), or as the account that runs it when the file has no password. Learn says that Get-AzsSecurity -Cluster needs CredSSP or a Remote
    Desktop session; whether Set-AzsSecurity -Cluster over a plain remoting session works is not stated and is not proven here. If it fails with
    an access error, run the script from a Remote Desktop session on a node.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        security.baseline_settings[]: type, name, value, acknowledge_weaker_security
        nodes[].name, nodes[].management.ip_address            the machine to connect to (unless -ComputerName is given)
        identity.local_admin.username, identity.local_admin.password

    Exit codes: 0 every entry is in place (set now, already set, planned under -WhatIf) or the file lists none; 1 the machine could not be reached,
    the cmdlets are missing, or a setting could not be changed; 2 a value in the file is missing or not usable (a type that is not one of the three, a
    name that is blocked, an entry listed twice, no value).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to connect to instead of the first entry of nodes[].

.PARAMETER Credential
    Optional. The account for the remoting session. Without it the script uses identity.local_admin of the file, or the account that runs it.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Set-SecurityBaselines.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Reads which customizations are recorded and shows which settings would be changed. Changes nothing.

.EXAMPLE
    ./Set-SecurityBaselines.ps1 -InfrastructureFile ./infrastructure.yml

    Sets the listed settings on the whole instance. Run it again: they are reported as AlreadySet.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ComputerName,
    [pscredential]$Credential,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

# The three policy types of Set-AzsSecurity -Type (Microsoft Learn, Customize individual security settings).
$PolicyType = @('SecuritySettings', 'SecuredCore', 'DefenderAntivirus')
# The settings Learn lists as blocked: Set-AzsSecurity refuses them and -Force does not override it.
$BlockedSetting = @(
    'AllowPKU2UAuthenticationAllowOnlineID', 'CredDelegationNonExportable', 'CredSspAllowEncryptionOracle', 'DenyStoredCredsForNetAuth', 'DeviceLockClearTextPassword', 'LANManagerAuthenticationLevel',
    'LimitBlankPasswordConsoleOnly', 'SendUnencryptedPasswordToThirdPartySMBServers',
    'DeviceGuardLsaCfgFlags', 'DeviceGuardRequireMicrosoftSignedBootChain', 'DeviceGuardRequirePlatformSecurityFeatures',
    'FirewallDomainProfileApplyLocalFirewallRules', 'FirewallDomainProfileInboundConnection', 'FirewallDomainProfileState', 'FirewallPrivateProfileInboundConnection', 'FirewallPrivateProfileState',
    'FirewallPublicProfileInboundConnection', 'FirewallPublicProfileState', 'FWDomainLocalConnSecRules',
    'MinimumSMBClientVersion', 'MinimumSMBServerVersion',
    'RemoteManagementAllowRemoteServerManagement', 'WinRMAllowBasicAuthClient', 'WinRMAllowBasicAuthService', 'WinRMAllowUnencryptedClient', 'WinRMAllowUnencryptedService', 'WinRMDisallowRunAsCreds',
    'ASRBlockProcessCreationFromPSExecAndWMICommands', 'DisableAntiSpyware', 'DisableRealtimeMonitoring'
)

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Field($Map, [string]$Key, $Default = $null) {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key] -and "$($Map[$Key])" -ne '') { return $Map[$Key] }
    $Default
}

# The commands that run on the machine. Each takes the step name first, so one remoting call shape serves both.
$Remote = @{
    ReadState = {
        param($Step)
        $set = Get-Command -Name Set-AzsSecurity -ErrorAction SilentlyContinue
        $intent = Get-Command -Name Get-AzsSecurityPolicyIntent -ErrorAction SilentlyContinue
        $json = ''
        if ($intent) { $json = [string](Get-AzsSecurityPolicyIntent | ConvertTo-Json -Depth 8 -Compress) }
        @{ HasSet = [bool]$set; HasIntent = [bool]$intent; IntentJson = $json }
    }
    SetSetting = {
        param($Step, $Type, $Name, $Value, $Force)
        $parameters = @{ Type = $Type; SettingName = $Name; Value = $Value; Cluster = $true; Confirm = $false; ErrorAction = 'Stop' }
        if ($Force) { $parameters.Force = $true }
        $null = Set-AzsSecurity @parameters
    }
}
function Invoke-Machine([string]$Step, [object[]]$Arguments = @()) {
    $call = @{ ComputerName = $script:target; ScriptBlock = $Remote[$Step]; ArgumentList = (, $Step + $Arguments); ErrorAction = 'Stop' }
    if ($script:remoteCredential) { $call.Credential = $script:remoteCredential }
    Invoke-Command @call
}

# The value the intent records for a setting, found anywhere in the tree the cmdlet returned (its exact shape is not documented): a property or a key
# named like the setting, or an object with Name and Value. Returns $null when the setting is not recorded.
function Find-RecordedValue($Node, [string]$Name) {
    if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) { return $null }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [System.Collections.IDictionary] -and $Node -isnot [pscustomobject]) {
        foreach ($item in $Node) { $found = Find-RecordedValue $item $Name; if ($null -ne $found) { return $found } }
        return $null
    }
    $names = @($Node.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($key in $names) { if ($key -ceq $Name) { return , $Node.$key } }
    foreach ($key in 'Name', 'SettingName') {
        if ($names -contains $key -and [string]$Node.$key -ceq $Name) { foreach ($valueKey in 'Value', 'CustomValue', 'Values') { if ($names -contains $valueKey) { return , $Node.$valueKey } } }
    }
    foreach ($key in $names) { $found = Find-RecordedValue $Node.$key $Name; if ($null -ne $found) { return $found } }
    $null
}
# The part of the intent that belongs to one policy type: the value of a property named like the type, or the object whose Type or PolicyType
# is the type. Returns $null when the intent has no such group.
function Find-TypeGroup($Node, [string]$Type) {
    if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) { return $null }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [System.Collections.IDictionary] -and $Node -isnot [pscustomobject]) {
        foreach ($item in $Node) { $found = Find-TypeGroup $item $Type; if ($null -ne $found) { return $found } }
        return $null
    }
    $names = @($Node.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($key in $names) { if ($key -ieq $Type -and $null -ne $Node.$key) { return , $Node.$key } }
    foreach ($key in 'Type', 'PolicyType') { if ($names -contains $key -and [string]$Node.$key -ieq $Type) { return $Node } }
    foreach ($key in $names) { $found = Find-TypeGroup $Node.$key $Type; if ($null -ne $found) { return $found } }
    $null
}
function ConvertTo-ValueText($Value) { (@($Value) | ForEach-Object { "$_" }) -join "`n" }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$security = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'security'
$entryList = @(@(Get-Field $security 'baseline_settings' @()) | Where-Object { $null -ne $_ })
if ($entryList.Count -eq 0) {
    Write-Line 'The file lists no security.baseline_settings: nothing to do.'
    exit 0
}

$plans = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($entry in $entryList) {
    $index++
    $at = "security.baseline_settings[$index]"
    if ($entry -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a setting (a map with type, name and value)." }
    $typeText = ([string](Get-Field $entry 'type' '')).Trim()
    $type = @($PolicyType | Where-Object { $_ -ieq $typeText }) | Select-Object -First 1
    if (-not $type) { Exit-InputProblem "$at.type '$typeText' is not one of: $($PolicyType -join ', ')." }
    $name = ([string](Get-Field $entry 'name' '')).Trim()
    if ($name -notmatch '^[A-Za-z0-9_.-]+$') { Exit-InputProblem "$at.name '$name' is missing or is not a setting name from the Name column of the baseline CSV (letters, digits, underscore, period, hyphen)." }
    if ($BlockedSetting -contains $name) { Exit-InputProblem "$at.name '$name' is a setting Microsoft blocks from customization (Microsoft Learn, Settings you can't customize). Remove it from the file." }
    if ($seen.ContainsKey("$type|$name")) { Exit-InputProblem "${at}: the setting $type/$name is listed twice." }
    $seen["$type|$name"] = $true

    $raw = Get-Field $entry 'value'
    if ($null -eq $raw) { Exit-InputProblem "$at.value is missing for $name." }
    if ($raw -is [System.Collections.IDictionary] -or $raw -is [bool] -or $raw -is [double]) { Exit-InputProblem "$at.value must be a string, a whole number or a list of strings. Write a value such as true or 1.5 in quotes, exactly as the baseline CSV writes it." }
    $value = if ($raw -is [System.Collections.IEnumerable] -and $raw -isnot [string]) { @($raw | ForEach-Object { "$_" }) } else { "$raw" }
    if (@($value).Count -eq 0 -or (@($value) | Where-Object { $_ -eq '' })) { Exit-InputProblem "$at.value for $name is empty." }

    $acknowledgeRaw = Get-Field $entry 'acknowledge_weaker_security' $false
    if ($acknowledgeRaw -isnot [bool]) { Exit-InputProblem "$at.acknowledge_weaker_security must be true or false." }
    $plans.Add([pscustomobject]@{ Type = $type; Name = $name; Value = $value; Force = [bool]$acknowledgeRaw; Text = (ConvertTo-ValueText $value) })
}

# ---- where to connect, and as whom
$nodeInfo = @(Get-AzlInfrastructureNode -Infrastructure $infra)
$target = if ($ComputerName) { $ComputerName.Trim() } elseif ($nodeInfo.Count -gt 0) { $(if ($nodeInfo[0].ManagementIp) { $nodeInfo[0].ManagementIp } else { $nodeInfo[0].Name }) } else { '' }
if (-not $target) { Exit-InputProblem 'nodes[] is empty. The script connects to a machine of the instance (or give -ComputerName).' }
$remoteCredential = $Credential
if (-not $remoteCredential) {
    $adminUser = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.local_admin.username')).Trim()
    $adminReference = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.local_admin.password')).Trim()
    if ($adminUser -and $adminReference) {
        try { $secret = Get-AzlSecretValue -Reference $adminReference -Infrastructure $infra }
        catch {
            $code = if ($_.Exception.Data.Contains('AzlExit')) { [int]$_.Exception.Data['AzlExit'] } else { 1 }
            if ($code -eq 2) { Exit-InputProblem "The password of identity.local_admin could not be read: $($_.Exception.Message)" }
            Exit-Failed "The password of identity.local_admin could not be read: $($_.Exception.Message)"
        }
        $remoteCredential = [pscredential]::new(".\$adminUser", $secret)
    }
}

# ---- the machine as it is (read only)
Write-Line "Machine '$target': reading the recorded security customizations"
try { $state = Invoke-Machine 'ReadState' }
catch { Exit-Failed "The machine '$target' could not be read: $($_.Exception.Message)" }
if (-not $state.HasSet) {
    Exit-Failed "Set-AzsSecurity was not found on '$target'. It exists on Azure Local 2610 or later, on new deployments or upgraded ones after the security baseline is applied (Microsoft Learn: Manage security defaults, and Manage security after upgrading Azure Local)."
}
$intent = $null
if ($state.HasIntent -and $state.IntentJson) {
    try { $intent = ConvertFrom-Json -InputObject ([string]$state.IntentJson) -Depth 12 }
    catch { Write-Warning "The recorded customizations could not be read as a list ($($_.Exception.Message)); every setting is set again, which changes nothing when the value is the same." }
}
elseif (-not $state.HasIntent) { Write-Warning "Get-AzsSecurityPolicyIntent was not found on '$target'; every setting is set again, which changes nothing when the value is the same." }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed] ' } 'AlreadySet' { '[exists] ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[done]   ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Item, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}

foreach ($plan in $plans) {
    $item = "$($plan.Type)/$($plan.Name)"
    try {
        # Only the group of this setting's own policy type counts. When that group is not found the setting is set again, which is harmless;
        # a value recorded under another type must never make this one look done.
        $ownType = if ($null -ne $intent) { Find-TypeGroup $intent $plan.Type } else { $null }
        $recorded = if ($null -ne $ownType) { Find-RecordedValue $ownType $plan.Name } else { $null }
        if ($null -ne $recorded -and (ConvertTo-ValueText $recorded) -ceq $plan.Text) { Add-Row $item 'AlreadySet' "recorded value $($plan.Text -replace "`n", ', ')"; continue }
        $shown = $plan.Text -replace "`n", ', '
        if ($PSCmdlet.ShouldProcess("security setting $item on the instance (through '$target')", "Set to '$shown' (-Cluster)")) {
            Invoke-Machine 'SetSetting' @($plan.Type, $plan.Name, $plan.Value, $plan.Force)
            Add-Row $item 'Set' "$shown on every machine, recorded as cluster policy intent"
        }
        else { Add-Row $item 'WouldSet' $shown }
    }
    catch {
        $detail = $_.Exception.Message
        if (-not $plan.Force -and $detail -match 'warn|confirm|weaken') { $detail += ' If this setting weakens security and you accept that, set acknowledge_weaker_security to true for it.' }
        Add-Row $item 'Failed' $detail
    }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
