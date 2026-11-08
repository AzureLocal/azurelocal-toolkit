#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-cluster verification gate, category IDENTITY: Active Directory (scenario.identity active_directory), local identity (local_identity),
    DNS records, the nodes' domain state and the dedicated local administrator.

.DESCRIPTION
    Check module for the gate engine. Exports two functions:

      Get-AzlVerificationCheckDefinition   the checks: Id, Category ('identity'), Title, Source (Learn or azurelocal.cloud page), Blocking,
                                           Applies = { param($Context) -> bool }, Run = { param($Context) -> result objects }.
      Get-AzlVerificationAdapterDefault    the real, read only adapters. The engine merges them into $Context.Adapters; tests replace them.

    A result is [pscustomobject] Status (Passed | Failed | Warning | Skipped | NotApplicable), Node ('*' or a node name), Message, Remedy (the exact
    command or steps) and Evidence (short). A check that cannot read what it needs ends as Skipped and says why; a Skipped result blocks the gate.
    No secret is ever put into a Message, Remedy or Evidence.

    $Context (hashtable)
      Infrastructure   the parsed infrastructure file
      Handoff, OsReport, Settings   as the engine builds them (Settings.solutionVersion, when set, is the target solution version)
      Remoting         optional: UseSsl, Authentication for the WinRM sessions to the nodes
      Adapters         the table below; a member that is missing makes the checks that need it Skipped
      IdCache          optional hashtable this module keeps its per-run state in (secrets in memory, LDAP latch, node reads); created when absent

    Adapters (each a hashtable of scriptblocks, replaced by fakes in tests)
      Ad.Search        { param($Filter, $SearchRoot, $Options) } -> Reachable, Server, Entries, AuthFailed, Error. Options: Servers, Credential,
                       Properties, Scope (Subtree | Base | OneLevel), SecurityMasks (Dacl), TimeoutSeconds. Entries: distinguishedName and
                       Properties (name -> values; byte arrays as base64). Default: Invoke-DjLdapSearch of AzlDomainJoin.psm1 (System.DirectoryServices).
      Dns.Resolve      { param($Name, $Server) } -> Ok (the server answered), Addresses, Error. $null when this host has no DNS client.
      Remote.Invoke    { param($Request) } -> Ok, Address, Result, Error, AuthFailed. Request: Node, Addresses, Credential, ScriptBlock,
                       ArgumentList, UseSsl, Authentication. One read only WinRM call as the dedicated local administrator.
      KeyVault.GetSecret  { param($Reference) } -> the secret value (kept in memory only).
      Clock.Now        { } -> [datetime]

    Harvested from the azl-toolkit scripts (03-onprem-readiness/phase-01-active-directory Test-ADConfiguration.ps1 and Invoke-ADValidation-Arc.ps1,
    04-cluster-deployment/phase-05 Test-ADPrerequisites-Standalone.ps1 and Test-LocalIdentityConfig.ps1, phase-03 task-06 Test-DnsClientConfig.ps1)
    and checked against Learn view=azloc-2610.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
Import-Module ([IO.Path]::Combine($script:Common, 'azure-local', 'AzlAzure.psm1')) -ErrorAction Stop
Import-Module ([IO.Path]::Combine($script:Common, 'infrastructure', 'AzlInfrastructure.psm1')) -ErrorAction Stop
Import-Module ([IO.Path]::Combine($script:Common, 'node-configuration', 'AzlDomainJoin.psm1')) -ErrorAction Stop
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AzlVerification.Endpoints.psm1')) -ErrorAction Stop

$script:Learn = 'https://learn.microsoft.com/en-us/azure/azure-local'
$script:View = 'view=azloc-2610'
$script:Docs = 'https://azurelocal.cloud/docs/implementation'
$script:Src = @{
    PrepAd   = "$script:Learn/deploy/deployment-prep-active-directory?$script:View"
    CustomAd = "$script:Learn/plan/configure-custom-settings-active-directory?$script:View"
    Portal   = "$script:Learn/deploy/deploy-via-portal?$script:View"
    InstallOs = "$script:Learn/deploy/deployment-install-os-disaggregated?$script:View"
    Local    = "$script:Learn/deploy/deployment-local-identity-with-key-vault?$script:View"
    LocalArm = "$script:Learn/deploy/deployment-local-identity-with-key-vault-template?$script:View"
    Prereq   = "$script:Learn/deploy/deployment-prerequisites?$script:View"
    Firewall = "$script:Learn/concepts/firewall-requirements?$script:View"
    AdDocs   = "$script:Docs/03-onprem-readiness/phase-01-active-directory"
    EnvCheck = "$script:Docs/03-onprem-readiness/phase-02-enterprise-readiness/task-05-environment-checker-readiness"
}

# Settings this module reads that the variables registry does not have yet. The orchestrator registers them; until then they are optional and
# the defaults below apply (see the report of the build). Nothing reads them from anywhere but the infrastructure file.
$script:UnregisteredSetting = @{
    # bool, default false. true: the instance uses group managed service accounts, which is the only reason a KDS root key matters.
    UseGmsa              = 'identity.active_directory.use_gmsa'
    # bool, default: derived. true: the DNS servers support secure dynamic updates (so node, CNO and VCO records are created at join).
    DnsSecureDynamicUpdates = 'identity.active_directory.dns_secure_dynamic_updates'
}
# Domain controller ports a node must reach: Active Directory Web Services, LDAP, Kerberos (Learn: firewall requirements, prepare Active Directory).
$script:DcPort = @(9389, 389, 88)
# The endpoints Test-DnsClientConfig.ps1 of the azl-toolkit resolves from the nodes.
# The names the nodes must resolve: the Arc, authentication, management and data plane hosts of the one documented list (AzlVerification.Endpoints.psm1) for the region of the file.
function Get-VfIdDnsEndpoint {
    param([Parameter(Mandatory)]$Context)
    $cloud = [string](Get-AzlProp (Get-VfIdInfra $Context) 'scenario.cloud' 'public')
    if ($cloud -ne 'public') { return @() }
    @(Get-AzlEndpointSet -Location ([string](Get-AzlProp (Get-VfIdInfra $Context) 'azure.location' '')) -Group Arc, Auth, Management, DataPlane -Port 443)
}
$script:ComputerClass = [guid]'bf967a86-0de6-11d0-a285-00aa00302ce8'

# ---------------------------------------------------------------------------------------------------------------------
# Results, skips, secrets
# ---------------------------------------------------------------------------------------------------------------------

function New-VfIdResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object.')]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('Passed', 'Failed', 'Warning', 'Skipped', 'NotApplicable')][string]$Status,
        [Parameter(Mandatory, Position = 1)][string]$Message,
        [Parameter(Position = 2)][string]$Remedy = '', [string]$Node = '*', [string]$Evidence = ''
    )
    [pscustomobject]@{ Status = $Status; Node = $Node; Message = $Message; Remedy = $Remedy; Evidence = $Evidence }
}

function Stop-VfIdSkip {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Throws a control-flow exception.')]
    param([Parameter(Mandatory)][string]$Reason, [string]$Remedy = '')
    $e = [System.InvalidOperationException]::new($Reason)
    $e.Data['VfSkip'] = $true
    $e.Data['VfRemedy'] = $Remedy
    throw $e
}

function Get-VfIdCache {
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Contains('IdCache') -or $null -eq $Context['IdCache']) { $Context['IdCache'] = @{ Secrets = [System.Collections.Generic.List[string]]::new(); Latch = @{}; Node = @{}; Ldap = @{} } }
    return $Context['IdCache']
}

function Register-VfIdSecret {
    param([Parameter(Mandatory)]$Context, [AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return }
    $cache = Get-VfIdCache $Context
    if (-not $cache.Secrets.Contains($Value)) { $cache.Secrets.Add($Value) }
}

function Protect-VfIdText {
    # Takes every secret read in this run out of a text, so an error message from a library can never carry one.
    param([Parameter(Mandatory)]$Context, [AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    foreach ($s in (Get-VfIdCache $Context).Secrets) { if ($s.Length -ge 4) { $Text = $Text.Replace($s, '***') } }
    return $Text
}

function Invoke-VfIdCheck {
    # Runs a check body; an exception becomes a Skipped result with the reason (never a silent pass), and secrets are scrubbed from every text.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][scriptblock]$Body)
    $out = [System.Collections.Generic.List[object]]::new()
    try { foreach ($r in @(& $Body)) { if ($null -ne $r) { $out.Add($r) } } }
    catch {
        $remedy = ''
        if ($_.Exception.Data['VfSkip']) { $remedy = [string]$_.Exception.Data['VfRemedy'] }
        $reason = if ($_.Exception.Data['VfSkip']) { $_.Exception.Message } else { "The check could not run: $($_.Exception.Message)" }
        $out.Add((New-VfIdResult Skipped $reason $(if ($remedy) { $remedy } else { 'Read the reason, fix the cause and run the verification again, or accept this check explicitly.' })))
    }
    foreach ($r in $out) {
        $r.Message = Protect-VfIdText $Context ([string]$r.Message)
        $r.Remedy = Protect-VfIdText $Context ([string]$r.Remedy)
        $r.Evidence = Protect-VfIdText $Context ([string]$r.Evidence)
    }
    return $out.ToArray()
}

function ConvertTo-VfIdList {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value) }
    return @($Value)
}

function Get-VfIdAdapter {
    # An adapter member, or the check is Skipped: a missing adapter is "this could not be read", never a pass.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Name)
    $adapters = Get-AzlProp $Context 'Adapters'
    $g = Get-AzlProp $adapters $Group
    $m = Get-AzlProp $g $Name
    if ($null -eq $m) { Stop-VfIdSkip "The verification has no $Group.$Name adapter here, so this could not be read." }
    return $m
}

# ---------------------------------------------------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------------------------------------------------

function Get-VfIdIdentity { param($Context) return [string](Get-AzlProp (Get-AzlProp $Context 'Infrastructure') 'scenario.identity' 'active_directory') }
function Get-VfIdInfra { param($Context) return (Get-AzlProp $Context 'Infrastructure') }

function Get-VfIdLcm {
    param([Parameter(Mandatory)]$Context)
    $i = Get-VfIdInfra $Context
    [pscustomobject]@{
        Domain = [string](Get-AzlProp $i 'identity.active_directory.domain_fqdn' ''); Netbios = [string](Get-AzlProp $i 'identity.active_directory.netbios_name' '')
        OuPath = [string](Get-AzlProp $i 'identity.active_directory.ou_path' ''); User = [string](Get-AzlProp $i 'identity.active_directory.lcm_user.username' '')
        PasswordRef = [string](Get-AzlProp $i 'identity.active_directory.lcm_user.password' '')
        DomainControllers = @(ConvertTo-VfIdList (Get-AzlProp $i 'identity.active_directory.domain_controllers' @()) | ForEach-Object { [string]$_ })
    }
}

function Get-VfIdNode {
    param([Parameter(Mandatory)]$Context)
    return @(ConvertTo-VfIdList (Get-AzlProp (Get-VfIdInfra $Context) 'nodes' @()))
}

function Get-VfIdNodeAddress {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Node)
    $list = [System.Collections.Generic.List[string]]::new()
    $ip = ''
    try { $m = Get-AzlManagementAdapter -Infrastructure (Get-VfIdInfra $Context) -Node $Node; if ($m -and $m.IpAddress) { $ip = [string]$m.IpAddress } } catch { Write-Verbose "Management adapter of the node not resolved: $($_.Exception.Message)" }
    if (-not $ip) { $ip = [string](Get-AzlProp $Node 'management.ip_address' '') }
    foreach ($a in @($ip, [string](Get-AzlProp $Node 'maintenance_address' ''))) { if ($a -and -not $list.Contains($a)) { $list.Add($a) } }
    return $list.ToArray()
}

function Get-VfIdDnsServer {
    param([Parameter(Mandatory)]$Context)
    return @(ConvertTo-VfIdList (Get-AzlProp (Get-VfIdInfra $Context) 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ })
}

function Get-VfIdZone {
    # The DNS domain the nodes' records live in: the AD domain, or the local identity DNS zone.
    param([Parameter(Mandatory)]$Context)
    $i = Get-VfIdInfra $Context
    if ((Get-VfIdIdentity $Context) -eq 'local_identity') { return [string](Get-AzlProp $i 'identity.local_identity.dns_zone' '') }
    return [string](Get-AzlProp $i 'identity.active_directory.domain_fqdn' '')
}

function Get-VfIdDnsMode {
    # Whether the DNS servers support secure dynamic updates: the file says so, else they are domain controllers (Microsoft DNS integrated with AD).
    param([Parameter(Mandatory)]$Context)
    $i = Get-VfIdInfra $Context
    $servers = @(Get-VfIdDnsServer $Context)
    $explicit = Get-AzlProp $i $script:UnregisteredSetting.DnsSecureDynamicUpdates $null
    if ($null -ne $explicit) { return [pscustomobject]@{ Servers = $servers; SecureUpdates = [bool]$explicit; Source = "the file ($($script:UnregisteredSetting.DnsSecureDynamicUpdates))" } }
    $dcs = @((Get-VfIdLcm $Context).DomainControllers)
    $derived = ($servers.Count -gt 0) -and (@($servers | Where-Object { $_ -notin $dcs }).Count -eq 0)
    [pscustomobject]@{ Servers = $servers; SecureUpdates = $derived; Source = $(if ($derived) { 'the DNS servers are the domain controllers of the file' } else { 'the DNS servers are not the domain controllers of the file' }) }
}

function Get-VfIdTargetVersionYymm {
    # The yymm of the target solution version (12.2610.1004.50 -> 2610), or 0 when none is declared.
    param([Parameter(Mandatory)]$Context)
    $v = [string](Get-AzlProp (Get-AzlProp $Context 'Settings') 'solutionVersion' '')
    if (-not $v) { $v = [string](Get-AzlProp (Get-AzlProp $Context 'Handoff') 'VsrVersion' '') }
    if (-not $v) { $v = [string](Get-AzlProp (Get-VfIdInfra $Context) 'provisioning.os_version' '') }
    if ($v -match '^\d+\.(?<yymm>\d{4})\.\d+\.\d+$') { return [int]$Matches.yymm }
    return 0
}

function Test-VfIdPassword {
    # Azure's rule: at least 14 characters with a lower case letter, an upper case letter, a digit and a special character. Returns what is missing.
    param([AllowNull()][string]$Candidate)
    $missing = @()
    if ($null -eq $Candidate) { $Candidate = '' }
    if ($Candidate.Length -lt 14) { $missing += 'at least 14 characters' }
    if ($Candidate -cnotmatch '[a-z]') { $missing += 'a lower case letter' }
    if ($Candidate -cnotmatch '[A-Z]') { $missing += 'an upper case letter' }
    if ($Candidate -notmatch '\d') { $missing += 'a digit' }
    if ($Candidate -notmatch '[^A-Za-z0-9]') { $missing += 'a special character' }
    return $missing
}

function Get-VfIdSecret {
    # A secret from Key Vault, read once per run and kept in memory. The value is registered for scrubbing.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Reference)
    $cache = Get-VfIdCache $Context
    $key = "Secret:$Reference"
    if (-not $cache.ContainsKey($key)) {
        $get = Get-VfIdAdapter $Context 'KeyVault' 'GetSecret'
        try { $plain = [string](& $get $Reference) }
        catch { Stop-VfIdSkip "The secret $Reference could not be read from Key Vault: $(Protect-VfIdText $Context $_.Exception.Message)" 'Sign in to Azure with a principal that can read the secret (Connect-AzAccount) and run the verification again.' }
        Register-VfIdSecret $Context $plain
        $cache[$key] = $plain
    }
    return [string]$cache[$key]
}

# ---------------------------------------------------------------------------------------------------------------------
# Active Directory over LDAP (read only)
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-VfIdLdapFilter([string]$Value) {
    return $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
}

function Get-VfIdDomainDn([string]$Domain) { return (($Domain.Split('.') | Where-Object { $_ } | ForEach-Object { "DC=$_" }) -join ',') }

function Invoke-VfIdLdap {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret was just read from Key Vault; it becomes a SecureString at once and lives in memory only.')]
    <#
    .SYNOPSIS
        One read only LDAP search with the LCM credential from Key Vault, through Adapters.Ad.Search. Ends the check as Skipped when it cannot be asked.
        A rejected credential trips the run's latch: it is not sent again (repeated bad passwords lock the account).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Filter, [string[]]$Property = @('distinguishedname'), [string]$SearchRoot, [string]$Scope = 'Subtree', [string]$SecurityMasks = '', [switch]$AllowAuthFailure)
    $lcm = Get-VfIdLcm $Context
    $cache = Get-VfIdCache $Context
    if ($cache.Latch.ContainsKey('Tripped') -and $cache.Latch['Tripped'] -and -not $AllowAuthFailure) { Stop-VfIdSkip "The LCM credential was rejected earlier in this run ($($cache.Latch['Reason'])), so it is not sent again." 'Fix the LCM user (ID-AD-002) and run the verification again.' }
    if (-not $lcm.DomainControllers.Count -and -not $lcm.Domain) { Stop-VfIdSkip 'identity.active_directory.domain_controllers and domain_fqdn are empty: there is no domain controller to ask.' }
    if (-not $lcm.User -or -not $lcm.PasswordRef) { Stop-VfIdSkip 'identity.active_directory.lcm_user has no username or password reference: there is no credential for the LDAP checks.' }
    $search = Get-VfIdAdapter $Context 'Ad' 'Search'
    $plain = Get-VfIdSecret $Context $lcm.PasswordRef
    $prefix = if ($lcm.Netbios) { $lcm.Netbios } elseif ($lcm.Domain) { $lcm.Domain.Split('.')[0].ToUpperInvariant() } else { '' }
    $user = if ($lcm.User -match '[\\@]') { $lcm.User } elseif ($prefix) { "$prefix\$($lcm.User)" } else { "$($lcm.User)@$($lcm.Domain)" }
    $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
    $servers = if ($lcm.DomainControllers.Count) { $lcm.DomainControllers } else { @($lcm.Domain) }
    $root = if ($SearchRoot) { $SearchRoot } else { Get-VfIdDomainDn $lcm.Domain }
    $options = @{ Servers = $servers; Credential = [pscredential]::new($user, $secure); Properties = @($Property); Scope = $Scope; SecurityMasks = $SecurityMasks; TimeoutSeconds = 20 }
    $answer = & $search $Filter $root $options
    if ([bool](Get-AzlProp $answer 'AuthFailed' $false)) {
        $cache.Latch['Tripped'] = $true
        $cache.Latch['Reason'] = "${user}: $(Protect-VfIdText $Context ([string](Get-AzlProp $answer 'Error' '')))"
    }
    return $answer
}

function Get-VfIdLdapChecked {
    # A search for a check: a rejected credential or a domain controller that does not answer ends the check as Skipped.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Filter, [string[]]$Property = @('distinguishedname'), [string]$SearchRoot, [string]$Scope = 'Subtree', [string]$SecurityMasks = '')
    $answer = Invoke-VfIdLdap -Context $Context -Filter $Filter -Property $Property -SearchRoot $SearchRoot -Scope $Scope -SecurityMasks $SecurityMasks
    if ([bool](Get-AzlProp $answer 'AuthFailed' $false)) { Stop-VfIdSkip "The domain controller rejected the LCM credential, so Active Directory could not be read (ID-AD-002): $(Protect-VfIdText $Context ([string](Get-AzlProp $answer 'Error' '')))" }
    if (-not [bool](Get-AzlProp $answer 'Reachable' $false)) {
        $why = [string](Get-AzlProp $answer 'Error' '')
        Stop-VfIdSkip $(if ($why) { $why } else { 'no domain controller of the file answered on TCP 389 from this host' }) 'Run the verification from a host that reaches the domain controllers on TCP 389 (for example a domain-joined jump server).'
    }
    if ([string](Get-AzlProp $answer 'Error' '')) { Stop-VfIdSkip (Protect-VfIdText $Context ([string]$answer.Error)) 'Run the verification from a host that can read Active Directory.' }
    return $answer
}

function Get-VfIdEntryProperty {
    # The first value of a property of an LDAP entry (Properties is name -> values). $null when absent or empty.
    param($Entry, [string]$Name)
    $props = Get-AzlProp $Entry 'Properties'
    if ($null -eq $props) { return $null }
    $v = if ($props -is [System.Collections.IDictionary]) { $(if ($props.Contains($Name)) { $props[$Name] } else { $null }) } else { Get-AzlProp $props $Name }
    if ($null -eq $v) { return $null }
    $list = @(ConvertTo-VfIdList $v)
    if (-not $list.Count) { return $null }
    return $list[0]
}

function Assert-VfIdEntryProperty {
    # The LDAP helper must return the requested properties (Invoke-DjLdapSearch with the Properties extension); an entry without the Properties member means it does not.
    param($Entry, [string]$Name)
    $props = Get-AzlProp $Entry 'Properties'
    $has = $false
    if ($null -ne $props) { $has = if ($props -is [System.Collections.IDictionary]) { $props.Contains($Name) } else { $null -ne $props.PSObject.Properties[$Name] } }
    if (-not $has) { Stop-VfIdSkip "The LDAP helper returned no '$Name' for the entry, so it could not be read over LDAP (Invoke-DjLdapSearch must return the requested Properties)." 'Update scripts/common/node-configuration/AzlDomainJoin.psm1 (Invoke-DjLdapSearch with Properties, Scope and SecurityMasks), or check the value by hand in Active Directory Users and Computers.' }
}

function Get-VfIdNow {
    param([Parameter(Mandatory)]$Context)
    $clock = Get-AzlProp (Get-AzlProp $Context 'Adapters') 'Clock'
    $now = Get-AzlProp $clock 'Now'
    if ($now) { return [datetime](& $now) }
    return Get-Date
}

function Get-VfIdOu {
    # The OU entry (gpoptions, gplink), read once per run; $null when it does not exist.
    param([Parameter(Mandatory)]$Context)
    $cache = Get-VfIdCache $Context
    if ($cache.Ldap.ContainsKey('Ou')) { return $cache.Ldap['Ou'] }
    $lcm = Get-VfIdLcm $Context
    $a = Get-VfIdLdapChecked -Context $Context -Filter "(&(objectClass=organizationalUnit)(distinguishedName=$(ConvertTo-VfIdLdapFilter $lcm.OuPath)))" -Property @('distinguishedname', 'gpoptions', 'gplink')
    $entry = @($a.Entries) | Select-Object -First 1
    $cache.Ldap['Ou'] = $entry
    return $entry
}

function Get-VfIdLcmUser {
    param([Parameter(Mandatory)]$Context)
    $cache = Get-VfIdCache $Context
    if ($cache.Ldap.ContainsKey('User')) { return $cache.Ldap['User'] }
    $lcm = Get-VfIdLcm $Context
    $a = Get-VfIdLdapChecked -Context $Context -Filter "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-VfIdLdapFilter $lcm.User)))" -Property @('distinguishedname', 'useraccountcontrol', 'accountexpires', 'msds-user-account-control-computed', 'userworkstations', 'objectsid')
    $entries = @($a.Entries)
    $cache.Ldap['User'] = [pscustomobject]@{ Entries = $entries; Server = [string](Get-AzlProp $a 'Server' '') }
    return $cache.Ldap['User']
}

function Get-VfIdOuRight {
    <#
    .SYNOPSIS
        From the DACL of an OU (base64 of the binary descriptor) and the SIDs the LCM user acts as (the user and its groups), which of the rights of Learn's
        permission table the allow entries grant. Needs System.DirectoryServices (Windows).
    #>
    param([Parameter(Mandatory)][string]$DescriptorBase64, [Parameter(Mandatory)][string[]]$Sid)
    $security = [System.DirectoryServices.ActiveDirectorySecurity]::new()
    $security.SetSecurityDescriptorBinaryForm([Convert]::FromBase64String($DescriptorBase64))
    $got = @{ ListChildren = $false; ReadProperty = $false; ReadControl = $false; CreateComputer = $false; DeleteComputer = $false; RecoveryInformation = $false }
    $denied = [System.Collections.Generic.List[string]]::new()
    foreach ($rule in $security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.IdentityReference.Value -notin $Sid) { continue }
        $m = [int]$rule.ActiveDirectoryRights
        $all = (($m -band 0xF01FF) -eq 0xF01FF) -or (($m -band 0x10000000) -ne 0)
        $anyObject = ($rule.ObjectType -eq [guid]::Empty)
        $computerObject = ($anyObject -or $rule.ObjectType -eq $script:ComputerClass)
        $scoped = ($rule.InheritedObjectType -ne [guid]::Empty -and $rule.InheritedObjectType -ne $script:ComputerClass)
        $inheritsToChildren = ($rule.InheritanceType -in @([System.DirectoryServices.ActiveDirectorySecurityInheritance]::All, [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents))
        if ($rule.AccessControlType -eq 'Deny') {
            if ($m -band 0x3) { $denied.Add("deny entry for $($rule.IdentityReference.Value) (rights $($rule.ActiveDirectoryRights))") }
            continue
        }
        if ($scoped) {
            # An entry that applies only to one other child class (Learn: the msFVE-RecoveryInformation entry, full control).
            if ($all -or (($m -band (65536 + 262144 + 524288 + 32)) -eq (65536 + 262144 + 524288 + 32))) { $got.RecoveryInformation = $true }
            continue
        }
        if ($all -and $anyObject) {
            foreach ($k in @('ListChildren', 'ReadProperty', 'ReadControl', 'CreateComputer', 'DeleteComputer')) { $got[$k] = $true }
            if ($inheritsToChildren) { $got.RecoveryInformation = $true }
            continue
        }
        if ($m -band 4) { $got.ListChildren = $true }
        if (($m -band 16) -and $anyObject) { $got.ReadProperty = $true }
        if ($m -band 131072) { $got.ReadControl = $true }
        if (($m -band 1) -and $computerObject) { $got.CreateComputer = $true }
        if (($m -band 2) -and $computerObject) { $got.DeleteComputer = $true }
    }
    [pscustomobject]@{ Right = $got; Denied = $denied.ToArray() }
}

function ConvertFrom-VfIdSidBase64([string]$Base64) {
    return [System.Security.Principal.SecurityIdentifier]::new([Convert]::FromBase64String($Base64), 0).Value
}

# ---------------------------------------------------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------------------------------------------------

function Resolve-VfIdRecord {
    # A name against every DNS server of the file: Answers (server -> addresses), Silent (servers that did not answer).
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Server)
    $resolve = Get-VfIdAdapter $Context 'Dns' 'Resolve'
    $answers = [ordered]@{}; $silent = @()
    foreach ($s in $Server) {
        $r = & $resolve $Name $s
        if ($null -eq $r) { Stop-VfIdSkip 'This host has no DNS client (Resolve-DnsName), so DNS records could not be asked for.' }
        if (-not [bool](Get-AzlProp $r 'Ok' $false)) { $silent += $s; continue }
        $answers[$s] = @(ConvertTo-VfIdList (Get-AzlProp $r 'Addresses' @()) | ForEach-Object { [string]$_ })
    }
    [pscustomobject]@{ Answers = $answers; Silent = $silent }
}

# ---------------------------------------------------------------------------------------------------------------------
# The nodes: one read only WinRM call per node, as the dedicated local administrator
# ---------------------------------------------------------------------------------------------------------------------

# Runs on the node (Windows PowerShell 5.1 syntax). Reads only. $Spec: LocalAdmin, Queries (name, type, server), Tcp (host, port), Dc.
$script:NodeProbe = {
    param($Spec)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = [ordered]@{ computer = [string]$env:COMPUTERNAME }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $out.partOfDomain = [bool]$cs.PartOfDomain
    $out.domain = [string]$cs.Domain
    $tcp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $out.primarySuffix = [string]$tcp.Domain
    $members = @()
    try { $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { [string]$_.Name }) }
    catch {
        $members = @()
        $group = [ADSI]'WinNT://./Administrators,group'
        foreach ($m in @($group.Invoke('Members'))) { $path = [string]$m.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $m, $null); $members += (($path -replace '^WinNT://', '') -replace '/', '\') }
    }
    $out.admins = @($members)
    $u = Get-LocalUser -Name ([string]$Spec.LocalAdmin) -ErrorAction SilentlyContinue
    $out.admin = [ordered]@{ exists = [bool]$u; enabled = $(if ($u) { [bool]$u.Enabled } else { $false }); sid = $(if ($u) { [string]$u.SID.Value } else { '' }) }
    $out.dnsClient = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | ForEach-Object { [ordered]@{ alias = [string]$_.InterfaceAlias; servers = @($_.ServerAddresses) } })
    $dnsq = @()
    foreach ($q in @($Spec.Queries)) {
        $ok = $false; $addrs = @(); $err = ''
        try {
            $r = @(Resolve-DnsName -Name ([string]$q.name) -Server ([string]$q.server) -Type ([string]$q.type) -DnsOnly -ErrorAction Stop)
            if ([string]$q.type -eq 'SRV') { $addrs = @($r | Where-Object { $_.Type -eq 'SRV' } | ForEach-Object { [string]$_.NameTarget }) } else { $addrs = @($r | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress }) }
            $ok = ($addrs.Count -gt 0)
        }
        catch { $err = [string]$_.Exception.Message }
        $dnsq += [ordered]@{ name = [string]$q.name; type = [string]$q.type; server = [string]$q.server; ok = $ok; addrs = @($addrs); error = $err }
    }
    $out.dnsq = @($dnsq)
    $tcpResults = @()
    foreach ($t in @($Spec.Tcp)) {
        $ok = $false
        $c = New-Object System.Net.Sockets.TcpClient
        try { $task = $c.ConnectAsync([string]$t.host, [int]$t.port); $ok = ($task.Wait(3000) -and $c.Connected) } catch { $ok = $false } finally { $c.Dispose() }
        $tcpResults += [ordered]@{ host = [string]$t.host; port = [int]$t.port; ok = $ok }
    }
    $out.tcp = @($tcpResults)
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    $out.sshd = $(if ($svc) { [ordered]@{ status = [string]$svc.Status; start = [string]$svc.StartType } } else { $null })
    if ($out.partOfDomain) { $out.secureChannel = [bool](Test-ComputerSecureChannel -ErrorAction SilentlyContinue) } else { $out.secureChannel = $null }
    [pscustomobject]$out
}

function Get-VfIdProbeSpec {
    param([Parameter(Mandatory)]$Context)
    $i = Get-VfIdInfra $Context
    $identity = Get-VfIdIdentity $Context
    $zone = Get-VfIdZone $Context
    $servers = @(Get-VfIdDnsServer $Context)
    $queries = [System.Collections.Generic.List[object]]::new()
    $tcp = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $servers) {
        if ($identity -eq 'active_directory' -and $zone) {
            $queries.Add(@{ name = $zone; type = 'A'; server = $s })
            $queries.Add(@{ name = "_ldap._tcp.dc._msdcs.$zone"; type = 'SRV'; server = $s })
        }
        if ($identity -eq 'local_identity' -and $zone) { foreach ($n in (Get-VfIdNode $Context)) { $queries.Add(@{ name = "$([string]$n['name']).$zone"; type = 'A'; server = $s }) } }
        foreach ($e in (Get-VfIdDnsEndpoint $Context)) { $queries.Add(@{ name = $e.Host; type = 'A'; server = $s }) }
    }
    if ($identity -eq 'active_directory') {
        foreach ($dc in (Get-VfIdLcm $Context).DomainControllers) { foreach ($p in $script:DcPort) { $tcp.Add(@{ host = $dc; port = $p }) } }
    }
    return @{ LocalAdmin = [string](Get-AzlProp $i 'identity.local_admin.username' ''); Queries = $queries.ToArray(); Tcp = $tcp.ToArray() }
}

function Get-VfIdProbe {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret was just read from Key Vault; it becomes a SecureString at once and lives in memory only.')]
    <#
    .SYNOPSIS
        What one node says, read once per run through Adapters.Remote.Invoke as the dedicated local administrator: Ok, Error, AuthFailed, Address, Data.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Node)
    $cache = Get-VfIdCache $Context
    $name = [string]$Node['name']
    if ($cache.Node.ContainsKey($name)) { return $cache.Node[$name] }
    $r = [pscustomobject]@{ Name = $name; Ok = $false; Error = ''; AuthFailed = $false; Address = ''; Data = $null }
    try {
        $invoke = Get-VfIdAdapter $Context 'Remote' 'Invoke'
        $i = Get-VfIdInfra $Context
        $user = [string](Get-AzlProp $i 'identity.local_admin.username' '')
        $ref = [string](Get-AzlProp $i 'identity.local_admin.password' '')
        if (-not $user -or -not $ref) { throw 'identity.local_admin.username or password is not set: there is no credential for the node.' }
        $plain = Get-VfIdSecret $Context $ref
        $addresses = @(Get-VfIdNodeAddress $Context $Node)
        if (-not $addresses.Count) { throw "Node $name has no management address in the file (nodes[].management.ip_address)." }
        $remoting = Get-AzlProp $Context 'Remoting'
        $request = [pscustomobject]@{
            Node = $name; Addresses = $addresses; Credential = [pscredential]::new("$name\$user", (ConvertTo-SecureString -String $plain -AsPlainText -Force))
            ScriptBlock = $script:NodeProbe; ArgumentList = @((Get-VfIdProbeSpec $Context))
            UseSsl = [bool](Get-AzlProp $remoting 'UseSsl' $false); Authentication = [string](Get-AzlProp $remoting 'Authentication' 'Negotiate')
        }
        $answer = & $invoke $request
        $r.Address = [string](Get-AzlProp $answer 'Address' '')
        $r.AuthFailed = [bool](Get-AzlProp $answer 'AuthFailed' $false)
        if (-not [bool](Get-AzlProp $answer 'Ok' $false)) { throw [string](Get-AzlProp $answer 'Error' 'the node did not answer') }
        $r.Data = Get-AzlProp $answer 'Result'
        if (-not $r.Data) { throw 'the node answered without data' }
        $r.Ok = $true
    }
    catch {
        $r.Error = Protect-VfIdText $Context $_.Exception.Message
        if ($_.Exception.Data['VfSkip']) { $r.Error = $_.Exception.Message }
    }
    $cache.Node[$name] = $r
    return $r
}

function Invoke-VfIdPerNode {
    # Runs -Body as { param($Name, $Data, $Node) } for each node that could be read; a node that could not be read gets a Skipped result that says why.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][scriptblock]$Body)
    foreach ($n in (Get-VfIdNode $Context)) {
        $name = [string]$n['name']
        $p = Get-VfIdProbe -Context $Context -Node $n
        if (-not $p.Ok) {
            $why = if ($p.AuthFailed) { "the node rejected the local administrator credential: $($p.Error)" } else { $p.Error }
            New-VfIdResult Skipped "$name could not be read as the local administrator, so this was not checked on it: $why" 'Make the node reachable over WinRM with the identity.local_admin credential (see ID-LA-003), then run the verification again.' -Node $name
            continue
        }
        & $Body $name $p.Data $n
    }
}

function Test-VfIdMember([object[]]$Member, [string]$Name, [string]$Domain, [string]$Netbios) {
    foreach ($m in $Member) {
        $s = [string]$m
        if ($s -ieq $Name -or $s -ieq "$Netbios\$Name" -or $s -ieq "$Name@$Domain" -or $s -ieq "$(($Domain -split '\.')[0])\$Name") { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------------------------------------------------

$script:Check = [System.Collections.Generic.List[object]]::new()

function Add-VfIdCheck {
    param(
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][scriptblock]$Run, [scriptblock]$Applies = { $true }, [bool]$Blocking = $true
    )
    $script:Check.Add([pscustomobject]@{ Id = $Id; Category = 'identity'; Title = $Title; Source = $Source; Blocking = $Blocking; Applies = $Applies; Run = $Run })
}

$script:IsAd = { param($Context) (Get-VfIdIdentity $Context) -eq 'active_directory' }
$script:IsLocal = { param($Context) (Get-VfIdIdentity $Context) -eq 'local_identity' }
$script:HasHostRecords = {
    param($Context)
    if ((Get-VfIdIdentity $Context) -eq 'active_directory') { return $true }
    return ([string](Get-AzlProp (Get-VfIdInfra $Context) 'identity.local_identity.dns_server_config' '') -eq 'use_dns_server')
}

# ---- Active Directory

Add-VfIdCheck -Id 'ID-AD-001' -Title 'Active Directory settings in the file follow Learn (domain, OU path, LCM user name)' -Source $script:Src.PrepAd -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        $problems = @()
        if (-not $lcm.Domain) { $problems += 'identity.active_directory.domain_fqdn is empty' }
        if (-not $lcm.OuPath) { $problems += 'identity.active_directory.ou_path is empty' }
        else {
            if ($lcm.OuPath -notmatch '^\s*OU=') { $problems += "ou_path '$($lcm.OuPath)' does not start with OU=: the OU can't be the top level of the domain" }
            if ($lcm.OuPath -notmatch '(^|,)\s*DC=') { $problems += "ou_path '$($lcm.OuPath)' has no DC= parts: Learn asks for the distinguished name including the domain components" }
            if ($lcm.OuPath -match '[&"''<>]') { $problems += "ou_path '$($lcm.OuPath)' contains one of & `" ' < >, which the OU path doesn't support" }
        }
        if (-not $lcm.User) { $problems += 'identity.active_directory.lcm_user.username is empty' }
        else {
            if ($lcm.User -match '[\\@]') { $problems += "the LCM user name '$($lcm.User)' includes a domain; give only the user name" }
            elseif ($lcm.User.Length -gt 20) { $problems += "the LCM user name is $($lcm.User.Length) characters; the limit is 20" }
            elseif ($lcm.User -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') { $problems += "the LCM user name '$($lcm.User)' may contain only letters, numbers, hyphens and underscores, and must not start with a hyphen or a number" }
            if ($lcm.User -ieq [string](Get-AzlProp (Get-VfIdInfra $Context) 'identity.local_admin.username' '')) { $problems += 'the LCM user name must differ from the local administrator name' }
        }
        if (-not $lcm.PasswordRef) { $problems += 'identity.active_directory.lcm_user.password is empty' }
        if ($lcm.Netbios -and $lcm.Netbios.Length -gt 15) { $problems += "netbios_name '$($lcm.Netbios)' is longer than 15 characters" }
        if ($problems) { return New-VfIdResult Failed ('identity.active_directory: ' + ($problems -join '; ') + '.') 'Fix identity.active_directory in infrastructure.yml. Learn: the LCM user name is 1 to 20 characters (letters, numbers, hyphens, underscores), not starting with a hyphen or a number, with no domain part; the OU path is a distinguished name below the domain, with none of & " '' < >.' -Evidence ($problems -join ' | ') }
        if (-not $lcm.DomainControllers.Count) { return New-VfIdResult Warning 'identity.active_directory.domain_controllers is empty, so the domain name is used to find a domain controller (set the addresses for a deterministic check).' 'Set identity.active_directory.domain_controllers.' -Evidence "ou=$($lcm.OuPath)" }
        New-VfIdResult Passed "OU $($lcm.OuPath) and LCM user $($lcm.User) follow Learn's rules in $($lcm.Domain)." -Evidence "ou=$($lcm.OuPath); user=$($lcm.User)"
    }
}

Add-VfIdCheck -Id 'ID-AD-002' -Title 'A domain controller answers on LDAP and accepts the LCM credential' -Source "$($script:Src.PrepAd); azl-toolkit Test-ADConfiguration.ps1 (LDAP connectivity)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        $latch = (Get-VfIdCache $Context).Latch
        if ($latch.ContainsKey('Tripped') -and $latch['Tripped']) { return New-VfIdResult Failed "The domain controller rejected the LCM credential ($($lcm.User)) earlier in this run: $($latch['Reason']). It is not sent again (repeated bad passwords lock the account)." "Check the password in Key Vault ($($lcm.PasswordRef)) and that the account is enabled and not locked: Get-ADUser $($lcm.User) -Properties Enabled,LockedOut" -Evidence 'credential rejected' }
        $a = Invoke-VfIdLdap -Context $Context -Filter '(objectClass=domainDNS)' -Property @('distinguishedname') -SearchRoot (Get-VfIdDomainDn $lcm.Domain) -Scope Base
        if ([bool](Get-AzlProp $a 'AuthFailed' $false)) { return New-VfIdResult Failed "The domain controller rejected the LCM credential ($($lcm.User)). It is not sent again in this run (repeated bad passwords lock the account)." "Check the password in Key Vault ($($lcm.PasswordRef)) and that the account is enabled and not locked: Get-ADUser $($lcm.User) -Properties Enabled,LockedOut" -Evidence (Protect-VfIdText $Context ([string](Get-AzlProp $a 'Error' ''))) }
        if (-not [bool](Get-AzlProp $a 'Reachable' $false)) {
            $why = [string](Get-AzlProp $a 'Error' '')
            Stop-VfIdSkip $(if ($why) { $why } else { "no domain controller of the file answered on TCP 389 from this host (tried $($lcm.DomainControllers -join ', '))" }) 'Run the verification from a host that reaches the domain controllers on TCP 389 (for example a domain-joined jump server).'
        }
        if ([string](Get-AzlProp $a 'Error' '')) { return New-VfIdResult Failed "The LDAP search on $([string](Get-AzlProp $a 'Server' '')) failed: $(Protect-VfIdText $Context ([string]$a.Error))" 'Check LDAP signing and the account, or run from a domain-joined host.' }
        New-VfIdResult Passed "Domain controller $([string](Get-AzlProp $a 'Server' '')) answered and accepted $($lcm.User)." -Evidence "server=$([string](Get-AzlProp $a 'Server' ''))"
    }
}

Add-VfIdCheck -Id 'ID-AD-003' -Title 'The dedicated OU exists' -Source "$($script:Src.PrepAd); azl-toolkit Test-ADConfiguration.ps1 (Cluster OU)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        $ou = Get-VfIdOu $Context
        if (-not $ou) { return New-VfIdResult Failed "The OU $($lcm.OuPath) does not exist in $($lcm.Domain). Learn: Active Directory preparation (the dedicated OU) was not done." "New-HciAdObjectsPreCreation -AzureStackLCMUserCredential (Get-Credential) -AsHciOUName '$($lcm.OuPath)'   (module AsHciADArtifactsPreCreationTool: Install-Module AsHciADArtifactsPreCreationTool -Repository PSGallery -Force)" -Evidence "ou=$($lcm.OuPath)" }
        New-VfIdResult Passed "The OU $($lcm.OuPath) exists." -Evidence "dn=$([string]$ou.distinguishedName)"
    }
}

Add-VfIdCheck -Id 'ID-AD-004' -Title 'The LCM user exists, is enabled, not locked, not expired, may log on interactively and is in the OU' -Source "$($script:Src.PrepAd) (Deployment user requirements); azl-toolkit Test-ADConfiguration.ps1 (LCM user exists, enabled, in cluster OU)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        $u = Get-VfIdLcmUser $Context
        if (-not $u.Entries.Count) { return New-VfIdResult Failed "The LCM user $($lcm.User) does not exist in $($lcm.Domain)." "New-HciAdObjectsPreCreation -AzureStackLCMUserCredential (Get-Credential) -AsHciOUName '$($lcm.OuPath)'   (creates the user in the OU)" -Evidence "user=$($lcm.User)" }
        if ($u.Entries.Count -gt 1) { return New-VfIdResult Failed "$($u.Entries.Count) accounts match the LCM user name $($lcm.User): $((@($u.Entries | ForEach-Object { [string]$_.distinguishedName })) -join '; '). The name must be unique." 'Remove or rename the duplicates.' }
        $e = $u.Entries[0]
        # An attribute the DC did not return is an empty list, and [int]$null is 0 (enabled, not locked, never expires): a missing value is Skipped, never read as healthy.
        foreach ($p in 'useraccountcontrol', 'msds-user-account-control-computed', 'accountexpires') {
            Assert-VfIdEntryProperty $e $p
            if (@(ConvertTo-VfIdList (Get-VfIdEntryProperty $e $p)).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string](Get-VfIdEntryProperty $e $p))) { Stop-VfIdSkip "The domain controller returned no value for '$p' of the LCM user, so the account state could not be read over LDAP." 'Check the account by hand: Get-ADUser <user> -Properties Enabled, LockedOut, AccountExpirationDate.' }
        }
        $uac = [int](Get-VfIdEntryProperty $e 'useraccountcontrol')
        $computed = [int](Get-VfIdEntryProperty $e 'msds-user-account-control-computed')
        $expires = [int64](Get-VfIdEntryProperty $e 'accountexpires')
        $now = Get-VfIdNow $Context
        $problems = @(); $warnings = @()
        if ($uac -band 0x2) { $problems += 'the account is disabled' }
        if ($computed -band 0x10) { $problems += 'the account is locked out' }
        if ($uac -band 0x40000) { $problems += 'the account requires a smart card (no interactive logon with a password)' }
        if ($expires -gt 0 -and $expires -lt [int64]::MaxValue -and [datetime]::FromFileTimeUtc($expires) -lt $now.ToUniversalTime()) { $problems += "the account expired on $([datetime]::FromFileTimeUtc($expires).ToString('yyyy-MM-dd'))" }
        $ws = Get-VfIdEntryProperty $e 'userworkstations'
        if ($ws) { $warnings += "the account may log on only to: $ws" }
        $dn = [string]$e.distinguishedName
        if ($problems) { return New-VfIdResult Failed "The LCM user $dn cannot be used: $($problems -join '; ')." "Set-ADUser $($lcm.User) -Enabled `$true; Unlock-ADAccount $($lcm.User); Set-ADUser $($lcm.User) -SmartcardLogonRequired `$false -AccountExpirationDate `$null" -Evidence "uac=$uac" }
        $inOu = $dn.EndsWith($lcm.OuPath, [StringComparison]::OrdinalIgnoreCase)
        if ($warnings) { return New-VfIdResult Warning "The LCM user $dn exists and is enabled, but $($warnings -join '; '); the deployment signs it in on every node." 'Clear the logon workstation restriction: Set-ADUser <user> -LogonWorkstations $null' -Evidence "dn=$dn" }
        if (-not $inOu) { return New-VfIdResult Warning "The LCM user $dn is enabled and usable but is not in the OU $($lcm.OuPath). Learn allows the user anywhere in the directory (the rights on the OU matter, see ID-AD-007), and the preparation tool creates it in the OU." "Optional: Move-ADObject -Identity '$dn' -TargetPath '$($lcm.OuPath)'" -Evidence "dn=$dn" }
        New-VfIdResult Passed "The LCM user $dn exists in the OU, is enabled, not locked, not expired and not restricted. Learn also needs the Log on as a batch job right (a deny in the default domain policy is not readable over LDAP)." -Evidence "dn=$dn"
    }
}

Add-VfIdCheck -Id 'ID-AD-005' -Title 'LCM password policy: at least 14 characters with lower, upper, digit and special character; user name is not admin' -Source "$($script:Src.PrepAd) (Active Directory preparation module, AzureStackLCMUserCredential)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        if (-not $lcm.PasswordRef) { return New-VfIdResult Failed 'identity.active_directory.lcm_user.password is empty: there is no password to check.' 'Set identity.active_directory.lcm_user.password to a keyvault:// reference.' }
        $problems = @()
        if ($lcm.User -ieq 'admin') { $problems += "the user name is 'admin', which Learn forbids" }
        $missing = @(Test-VfIdPassword (Get-VfIdSecret $Context $lcm.PasswordRef))
        if ($missing) { $problems += "the password lacks $($missing -join ', ')" }
        if ($problems) { return New-VfIdResult Failed "LCM user $($lcm.User): $($problems -join '; ') (value not shown)." "Set a new password in Key Vault ($($lcm.PasswordRef)) that is at least 14 characters with a lower case letter, an upper case letter, a digit and a special character, then: Set-ADAccountPassword $($lcm.User) -Reset" -Evidence "missing=$($missing.Count)" }
        New-VfIdResult Passed "The LCM password ($($lcm.PasswordRef)) meets the length and complexity rule and the user name is not 'admin' (value not shown)." -Evidence 'rule: 14+ chars, 4 classes'
    }
}

Add-VfIdCheck -Id 'ID-AD-006' -Title 'Group policy inheritance is blocked on the OU (Block Inheritance); enforced GPOs above it are reported' -Source "$($script:Src.PrepAd) (note on enforced GPOs); $($script:Src.CustomAd)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        $ou = Get-VfIdOu $Context
        if (-not $ou) { Stop-VfIdSkip 'The OU does not exist (ID-AD-003), so Block Inheritance could not be read.' }
        Assert-VfIdEntryProperty $ou 'gpoptions'
        # gPOptions bit 1 is "block policy inheritance"; an attribute that was never set is 0.
        $options = [int](Get-VfIdEntryProperty $ou 'gpoptions')
        if (-not ($options -band 1)) { return New-VfIdResult Failed "Group policy inheritance is not blocked on $($lcm.OuPath) (gPOptions $options). Learn: Block Inheritance is required so that no GPO conflicts with the security defaults Azure Local manages." "Set-GPInheritance -Target '$($lcm.OuPath)' -IsBlocked Yes" -Evidence "gPOptions=$options" }
        # Ancestors, nearest first: an enforced GPO link (option 2) is not stopped by Block Inheritance.
        $parts = @($lcm.OuPath -split '(?<!\\),' | ForEach-Object { $_.Trim() })
        $ancestors = @()
        for ($k = 1; $k -lt $parts.Count; $k++) { $candidate = ($parts[$k..($parts.Count - 1)]) -join ','; if ($candidate -match '(^|,)DC=') { $ancestors += $candidate } }
        $enforced = @()
        if ($ancestors.Count) {
            $filter = '(|' + (($ancestors | ForEach-Object { "(distinguishedName=$(ConvertTo-VfIdLdapFilter $_))" }) -join '') + ')'
            $a = Get-VfIdLdapChecked -Context $Context -Filter $filter -Property @('distinguishedname', 'gplink')
            foreach ($e in @($a.Entries)) {
                $link = [string](Get-VfIdEntryProperty $e 'gplink')
                foreach ($m in [regex]::Matches($link, '\[(?<dn>[^;\]]+);(?<opt>\d+)\]')) { $opt = [int]$m.Groups['opt'].Value; if (($opt -band 2) -and -not ($opt -band 1)) { $enforced += "$($m.Groups['dn'].Value) (linked at $($e.distinguishedName))" } }
            }
        }
        if ($enforced.Count) { return New-VfIdResult Warning "Block Inheritance is on, but $($enforced.Count) enforced GPO link(s) above the OU still apply: $($enforced -join '; '). Learn: enforced GPOs are not blocked by Block Inheritance." 'Exclude the machine accounts of the Azure Local instance from these GPOs with a WMI filter (Learn: Prepare Active Directory, note on enforced GPOs).' -Evidence "enforced=$($enforced.Count)" }
        New-VfIdResult Passed "Block Inheritance is set on $($lcm.OuPath) (gPOptions $options) and no enforced GPO link above it applies." -Evidence "gPOptions=$options"
    }
}

Add-VfIdCheck -Id 'ID-AD-007' -Title 'The LCM user holds Learn''s delegated rights on the OU: list, read all properties, read permissions, create and delete computer objects' -Source "$($script:Src.CustomAd) (Required permissions)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        $u = Get-VfIdLcmUser $Context
        if ($u.Entries.Count -ne 1) { Stop-VfIdSkip 'The LCM user was not found exactly once (ID-AD-004), so its rights on the OU cannot be compared.' }
        $a = Get-VfIdLdapChecked -Context $Context -Filter "(&(objectClass=organizationalUnit)(distinguishedName=$(ConvertTo-VfIdLdapFilter $lcm.OuPath)))" -Property @('distinguishedname', 'ntsecuritydescriptor') -SecurityMasks Dacl
        $ou = @($a.Entries) | Select-Object -First 1
        if (-not $ou) { Stop-VfIdSkip 'The OU does not exist (ID-AD-003).' }
        Assert-VfIdEntryProperty $ou 'ntsecuritydescriptor'
        $descriptor = Get-VfIdEntryProperty $ou 'ntsecuritydescriptor'
        $sidText = Get-VfIdEntryProperty $u.Entries[0] 'objectsid'
        if (-not $descriptor -or -not $sidText) { Stop-VfIdSkip 'The security descriptor of the OU or the SID of the LCM user was not returned over LDAP, so the delegated rights could not be compared.' 'Check by hand (Active Directory Users and Computers > OU > Properties > Security > Advanced) against the permission table in Learn: Custom Active Directory configuration.' }
        $sids = [System.Collections.Generic.List[string]]::new()
        $sids.Add((ConvertFrom-VfIdSidBase64 ([string]$sidText)))
        $sids.Add('S-1-5-11'); $sids.Add('S-1-1-0')
        # The groups of the user (constructed attribute tokenGroups) count too; when they can't be read, only direct entries are compared.
        $note = ''
        try {
            $g = Invoke-VfIdLdap -Context $Context -Filter '(objectClass=*)' -Property @('tokengroups') -SearchRoot ([string]$u.Entries[0].distinguishedName) -Scope Base
            $entry = @(Get-AzlProp $g 'Entries' @()) | Select-Object -First 1
            $tokens = if ($entry) { Get-AzlProp (Get-AzlProp $entry 'Properties') 'tokengroups' @() } else { @() }
            foreach ($t in @(ConvertTo-VfIdList $tokens)) { $sids.Add((ConvertFrom-VfIdSidBase64 ([string]$t))) }
        }
        catch { $note = ' (the groups of the user could not be read, so only entries for the user itself, Authenticated Users and Everyone were compared)' }
        $rights = Get-VfIdOuRight -DescriptorBase64 ([string]$descriptor) -Sid $sids.ToArray()
        $r = $rights.Right
        $names = [ordered]@{ ListChildren = 'list contents'; ReadProperty = 'read all properties'; ReadControl = 'read permissions'; CreateComputer = 'create computer objects'; DeleteComputer = 'delete computer objects' }
        $missing = @($names.Keys | Where-Object { -not $r[$_] } | ForEach-Object { $names[$_] })
        $remedy = "Run New-HciAdObjectsPreCreation again for this OU and user, or delegate on $($lcm.OuPath) to $($lcm.User): list contents, read all properties, read permissions, create and delete Computer objects, and full control on descendant msFVE-RecoveryInformation objects (Learn: Custom Active Directory configuration, Required permissions)."
        if ($missing) { return New-VfIdResult Failed "On $($lcm.OuPath) the LCM user $($lcm.User) lacks: $($missing -join ', ')$note." $remedy -Evidence "missing=$($missing -join ',')" }
        if ($rights.Denied.Count) { return New-VfIdResult Warning "The LCM user holds the rights, but the OU also has $($rights.Denied -join '; '): a deny wins over an allow." 'Remove the deny entry on the OU.' -Evidence "denied=$($rights.Denied.Count)" }
        if (-not $r.RecoveryInformation) { return New-VfIdResult Warning "The LCM user can read, create and delete computer objects in $($lcm.OuPath), but no entry gives it full control of descendant msFVE-RecoveryInformation objects (BitLocker recovery information), which Learn lists$note." "Grant it with PowerShell, not the delegation wizard (Learn: Custom Active Directory configuration): the msFVE-RecoveryInformation entry, or run New-HciAdObjectsPreCreation again." -Evidence 'recovery entry not found' }
        New-VfIdResult Passed "The LCM user $($lcm.User) holds list contents, read all properties, read permissions, create and delete computer objects and the BitLocker recovery entry on $($lcm.OuPath)$note." -Evidence 'rights: 5 of 5 + recovery'
    }
}

Add-VfIdCheck -Id 'ID-AD-008' -Title 'Computer objects of the nodes and the cluster that already exist (pre-created) are in the OU' -Source "$($script:Src.PrepAd) (moving computer objects to another OU after deployment isn't supported); $($script:Src.CustomAd)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        $cluster = [string](Get-AzlProp (Get-VfIdInfra $Context) 'cluster.name' '')
        $targets = @(Get-VfIdNode $Context | ForEach-Object { [pscustomobject]@{ Name = [string]$_['name']; Kind = 'node'; Node = [string]$_['name'] } })
        if ($cluster) { $targets += [pscustomobject]@{ Name = $cluster; Kind = 'cluster (CNO)'; Node = '*' } }
        foreach ($t in $targets) {
            $a = Get-VfIdLdapChecked -Context $Context -Filter "(&(objectCategory=computer)(cn=$(ConvertTo-VfIdLdapFilter $t.Name)))" -Property @('distinguishedname', 'dnshostname')
            $entries = @($a.Entries)
            if (-not $entries.Count) { New-VfIdResult Passed "No computer object named $($t.Name) ($($t.Kind)) exists; the deployment creates it in the OU." -Node $t.Node -Evidence 'absent'; continue }
            $outside = @($entries | Where-Object { -not ([string]$_.distinguishedName).EndsWith($lcm.OuPath, [StringComparison]::OrdinalIgnoreCase) })
            if ($outside.Count) { New-VfIdResult Failed "The computer object $($outside[0].distinguishedName) ($($t.Kind)) is outside the OU $($lcm.OuPath). Learn: moving computer objects to another OU after the deployment isn't supported." "Move it into the OU before the deployment: Move-ADObject -Identity '$($outside[0].distinguishedName)' -TargetPath '$($lcm.OuPath)'   (or delete a stale object)" -Node $t.Node -Evidence "dn=$($outside[0].distinguishedName)" }
            else { New-VfIdResult Passed "The computer object $($entries[0].distinguishedName) ($($t.Kind)) is in the OU (pre-created)." -Node $t.Node -Evidence "dn=$($entries[0].distinguishedName)" }
        }
    }
}

Add-VfIdCheck -Id 'ID-DNS-001' -Title 'DNS host (A) records of every node exist and match the management address' -Source "$($script:Src.CustomAd) (Required DNS records); $($script:Src.Local) (Configure DNS server)" -Applies $script:HasHostRecords -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $identity = Get-VfIdIdentity $Context
        $zone = Get-VfIdZone $Context
        if (-not $zone) { return New-VfIdResult Failed 'There is no DNS domain (identity.active_directory.domain_fqdn or identity.local_identity.dns_zone) to look the nodes up in.' 'Set it in infrastructure.yml.' }
        $mode = Get-VfIdDnsMode $Context
        if (-not $mode.Servers.Count) { return New-VfIdResult Failed 'networking.management.dns_servers is empty.' 'Set the DNS servers of the management network.' }
        foreach ($n in (Get-VfIdNode $Context)) {
            $name = [string]$n['name']
            $expected = ''
            try { $m = Get-AzlManagementAdapter -Infrastructure (Get-VfIdInfra $Context) -Node $n; if ($m) { $expected = [string]$m.IpAddress } } catch { Write-Verbose "No management adapter: $($_.Exception.Message)" }
            if (-not $expected) { $expected = [string](Get-AzlProp $n 'management.ip_address' '') }
            $fqdn = "$name.$zone"
            $r = Resolve-VfIdRecord -Context $Context -Name $fqdn -Server $mode.Servers
            $required = ($identity -eq 'local_identity') -or -not $mode.SecureUpdates
            $fix = "Add-DnsServerResourceRecordA -ZoneName '$zone' -Name '$name' -IPv4Address '$expected'   (on the DNS server; Learn: a Host (A) record for every machine); verify: nslookup $fqdn"
            $none = @($r.Answers.Keys | Where-Object { -not $r.Answers[$_].Count })
            $wrong = @($r.Answers.Keys | Where-Object { $r.Answers[$_].Count -and $expected -and $expected -notin $r.Answers[$_] })
            if ($r.Silent.Count -eq $mode.Servers.Count) { Stop-VfIdSkip "None of the DNS servers ($($mode.Servers -join ', ')) answered the query for $fqdn from this host." 'Run the verification from a host that reaches the DNS servers (UDP/TCP 53).' }
            elseif ($wrong) { New-VfIdResult Failed "$fqdn resolves to $($r.Answers[$wrong[0]] -join ', ') on $($wrong[0]), not to the management address $expected." $fix -Node $name -Evidence "got=$($r.Answers[$wrong[0]] -join ',')" }
            elseif ($none.Count) {
                $why = if ($required) { 'Learn requires a Host (A) record for every machine' + $(if ($identity -eq 'active_directory') { ' when the DNS server does not support secure dynamic updates' } else { ' for local identity' }) } else { 'The DNS servers support secure dynamic updates, so the record is created at domain join; Learn requires it up front only without them' }
                New-VfIdResult $(if ($required) { 'Failed' } else { 'Warning' }) "$fqdn has no A record on $($none -join ', '). $why." $fix -Node $name -Evidence "dnsMode=$($mode.Source)"
            }
            else { New-VfIdResult Passed "$fqdn resolves to $expected on every DNS server ($($mode.Servers -join ', '))." -Node $name -Evidence "ip=$expected" }
        }
    }
}

Add-VfIdCheck -Id 'ID-DNS-002' -Title 'Cluster name (CNO) and client access point (VCO) host A records exist when DNS has no secure dynamic updates' -Source "$($script:Src.CustomAd) (Required DNS records; Cluster aware updating)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $zone = Get-VfIdZone $Context
        $cluster = [string](Get-AzlProp (Get-VfIdInfra $Context) 'cluster.name' '')
        $mode = Get-VfIdDnsMode $Context
        if (-not $cluster) { return New-VfIdResult Failed 'cluster.name is empty: there is no cluster name to look up.' 'Set cluster.name.' }
        if (-not $mode.Servers.Count) { return New-VfIdResult Failed 'networking.management.dns_servers is empty.' 'Set the DNS servers of the management network.' }
        $fqdn = "$cluster.$zone"
        $r = Resolve-VfIdRecord -Context $Context -Name $fqdn -Server $mode.Servers
        if ($r.Silent.Count -eq $mode.Servers.Count) { Stop-VfIdSkip "None of the DNS servers answered the query for $fqdn from this host." 'Run the verification from a host that reaches the DNS servers.' }
        $none = @($r.Answers.Keys | Where-Object { -not $r.Answers[$_].Count })
        $first = [string](Get-AzlProp (Get-VfIdInfra $Context) 'networking.management.infrastructure_pool.start' '<the first infrastructure address>')
        $fix = "Add-DnsServerResourceRecordA -ZoneName '$zone' -Name '$cluster' -IPv4Address '$first'; also a Host (A) record for the Cluster Aware Updating client access point (VCO). Learn: Custom Active Directory configuration, Required DNS records."
        if ($mode.SecureUpdates) {
            if ($none.Count) { return New-VfIdResult Warning "The cluster name $fqdn has no A record yet. DNS supports secure dynamic updates ($($mode.Source)), so the CNO and VCO records are created by the deployment; Learn requires them up front only without secure dynamic updates." $fix -Evidence 'records created at deployment' }
            return New-VfIdResult Passed "The cluster name $fqdn already resolves ($(($r.Answers.Values | ForEach-Object { $_ -join ', ' } | Select-Object -Unique) -join '; ')); DNS supports secure dynamic updates." -Evidence "dnsMode=$($mode.Source)"
        }
        if ($none.Count) {
            New-VfIdResult Failed "The cluster name $fqdn (CNO) has no A record on $($none -join ', '), and DNS does not support secure dynamic updates ($($mode.Source)). Learn: create a Host (A) record for each machine, the cluster CNO and the cluster VCO before you deploy." $fix -Evidence "cno=$fqdn"
        }
        else { New-VfIdResult Passed "The cluster name $fqdn (CNO) resolves on every DNS server." -Evidence "cno=$fqdn" }
        New-VfIdResult Warning "The CAU client access point (VCO) record needs a Host (A) record without secure dynamic updates; Learn gives no fixed name for it, so it can't be looked up. Create it when you set up Cluster Aware Updating: Learn says to disable dynamic DNS update on the management adapter and create the VCO at once." "Get-NetAdapter 'vManagement*' | Set-DnsClient -RegisterThisConnectionsAddress `$false   (then create the VCO and its A record)" -Evidence 'vco name not predictable'
    }
}

Add-VfIdCheck -Id 'ID-AD-009' -Title 'Nodes resolve the domain and its domain controllers with the file''s DNS servers, and reach ADWS (9389), LDAP (389) and Kerberos (88)' -Source "$($script:Src.PrepAd) (firewall); $($script:Src.Firewall); azl-toolkit Test-DnsClientConfig.ps1" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $domain = Get-VfIdZone $Context
        $servers = @(Get-VfIdDnsServer $Context)
        Invoke-VfIdPerNode -Context $Context -Body {
            param($Name, $D)
            $q = @(ConvertTo-VfIdList (Get-AzlProp $D 'dnsq' @()) | Where-Object { [string]$_.name -eq $domain -or [string]$_.name -like '_ldap._tcp.*' })
            $bad = @($q | Where-Object { -not $_.ok })
            $tcp = @(ConvertTo-VfIdList (Get-AzlProp $D 'tcp' @()))
            $adws = @($tcp | Where-Object { [int]$_.port -eq 9389 })
            $adwsDown = ($adws.Count -gt 0) -and (@($adws | Where-Object { $_.ok }).Count -eq 0)
            $others = @($tcp | Where-Object { [int]$_.port -ne 9389 -and -not $_.ok })
            if (-not $q.Count) { New-VfIdResult Skipped "$Name returned no DNS answers for $domain, so name resolution could not be judged." 'Check the node read (ID-LA-003).' -Node $Name }
            elseif ($bad.Count) { New-VfIdResult Failed "$Name cannot resolve $(@($bad | ForEach-Object { "$($_.name) ($($_.type)) on $($_.server)" } | Select-Object -First 4) -join '; '). The domain join fails with 'No such host is known'." "On the node: Resolve-DnsName $domain -Server <dns server>. Fix networking.management.dns_servers and the zone ($($servers -join ', ')), then run the OS configuration (Dns step)." -Node $Name -Evidence "failed=$($bad.Count) of $($q.Count)" }
            elseif ($adwsDown) { New-VfIdResult Failed "$Name cannot reach Active Directory Web Services (TCP 9389) on any domain controller ($(@($adws | ForEach-Object { $_.host }) -join ', '))." 'On the node: Test-NetConnection <domain controller> -Port 9389. Open ADWS and the Active Directory Gateway Management Service on the firewall (Learn: Firewall requirements).' -Node $Name -Evidence 'adws down' }
            elseif ($others.Count) { New-VfIdResult Warning "$Name cannot reach $(@($others | ForEach-Object { "$($_.host):$($_.port)" }) -join ', '); the domain join and the deployment use them." 'Open the ports between the node and the domain controllers.' -Node $Name -Evidence "blocked=$($others.Count)" }
            else { New-VfIdResult Passed "$Name resolves $domain (A and the domain controller SRV record) on every DNS server and reaches ADWS, LDAP and Kerberos on the domain controllers." -Node $Name -Evidence "dnsq=$($q.Count) ok" }
        }
    }
}

Add-VfIdCheck -Id 'ID-AD-010' -Title 'Domain join state of the nodes: workgroup, or joined to the file''s domain (supported from 2604) with the deployment user in local Administrators' -Source "$($script:Src.InstallOs) (Domain join before deployment); azl-toolkit Test-ADPrerequisites-Standalone.ps1 (secure channel)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        $yymm = Get-VfIdTargetVersionYymm $Context
        Invoke-VfIdPerNode -Context $Context -Body {
            param($Name, $D)
            $joined = [bool](Get-AzlProp $D 'partOfDomain' $false)
            $domain = [string](Get-AzlProp $D 'domain' '')
            if (-not $joined) { New-VfIdResult Passed "$Name is in the workgroup '$domain'. Learn: if the machines are not domain joined beforehand, they are joined to the domain during the deployment." -Node $Name -Evidence 'workgroup'; return }
            if ($domain -ine $lcm.Domain) { New-VfIdResult Failed "$Name is joined to the domain $domain, not to $($lcm.Domain) of the file." "Remove-Computer -WorkgroupName WORKGROUP -Restart on the node, or fix identity.active_directory.domain_fqdn." -Node $Name -Evidence "domain=$domain"; return }
            $problems = @(); $remedy = @()
            if ($yymm -gt 0 -and $yymm -lt 2604) { $problems += "domain join before the deployment is supported from version 2604, and the target is $yymm"; $remedy += 'Remove-Computer -WorkgroupName WORKGROUP -Restart (the deployment joins the machine itself), or target 2604 or later' }
            $admins = @(ConvertTo-VfIdList (Get-AzlProp $D 'admins' @()) | ForEach-Object { [string]$_ })
            if (-not (Test-VfIdMember $admins $lcm.User $lcm.Domain $lcm.Netbios)) {
                $prefix = if ($lcm.Netbios) { $lcm.Netbios } else { ($lcm.Domain -split '\.')[0] }
                $problems += "the deployment user $prefix\$($lcm.User) is not in the local Administrators group (Learn: when you domain join beforehand, add the deployment user)"
                $remedy += "Add-LocalGroupMember -Group 'Administrators' -Member '$prefix\$($lcm.User)'   (on the node)"
            }
            if ($null -ne (Get-AzlProp $D 'secureChannel' $null) -and -not [bool]$D.secureChannel) { $problems += 'the secure channel to the domain is broken (Test-ComputerSecureChannel)'; $remedy += 'Test-ComputerSecureChannel -Repair -Credential (Get-Credential)  (on the node)' }
            if ($problems) { New-VfIdResult Failed "$Name is joined to $domain, but $($problems -join '; ')." ($remedy -join '; ') -Node $Name -Evidence "problems=$($problems.Count)" }
            else { New-VfIdResult Passed "$Name is joined to $domain (supported before the deployment from 2604), the secure channel is healthy and $($lcm.User) is a local administrator." -Node $Name -Evidence 'joined' }
        }
    }
}

Add-VfIdCheck -Id 'ID-AD-011' -Title 'Disjoint namespace: the primary DNS suffix of a joined node matches the domain' -Source "$($script:Src.CustomAd) (Disjoint namespace)" -Applies $script:IsAd -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $lcm = Get-VfIdLcm $Context
        Invoke-VfIdPerNode -Context $Context -Body {
            param($Name, $D)
            if (-not [bool](Get-AzlProp $D 'partOfDomain' $false)) { New-VfIdResult NotApplicable "$Name is in a workgroup: its DNS suffix is set when it joins." -Node $Name; return }
            $primary = [string](Get-AzlProp $D 'primarySuffix' '')
            if ($primary -ieq $lcm.Domain) { New-VfIdResult Passed "$Name's primary DNS suffix is ${primary}: no disjoint namespace." -Node $Name -Evidence "suffix=$primary" }
            else { New-VfIdResult Failed "$Name's primary DNS suffix is '$primary' but the Active Directory domain is $($lcm.Domain): a disjoint namespace. Learn: append the DNS suffix to the management adapter of every node (Group Policy can't be used)." "Set-DnsClient -InterfaceIndex <management adapter index> -ConnectionSpecificSuffix '$($lcm.Domain)'; verify: nslookup $Name.$($lcm.Domain)" -Node $Name -Evidence "suffix=$primary" }
        }
    }
}

Add-VfIdCheck -Id 'ID-AD-012' -Title 'KDS root key (Learn 2610 does not require it for Azure Local; only for gMSA)' -Source "$($script:Src.PrepAd); azl-toolkit Test-ADConfiguration.ps1 (KDS Root Key, not a Learn requirement)" -Applies $script:IsAd -Blocking $false -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $gmsa = Get-AzlProp (Get-VfIdInfra $Context) $script:UnregisteredSetting.UseGmsa $false
        if (-not [bool]$gmsa) { return New-VfIdResult NotApplicable "Learn 2610 does not list a KDS root key among the Active Directory requirements for Azure Local: the preparation article names a dedicated OU, blocked GPO inheritance and a user with rights on the OU. A KDS root key is needed only for group managed service accounts, and the file does not ask for gMSA ($($script:UnregisteredSetting.UseGmsa) is not true), so it is not checked." }
        $lcm = Get-VfIdLcm $Context
        $a = Get-VfIdLdapChecked -Context $Context -Filter '(objectClass=msKds-ProvRootKey)' -Property @('distinguishedname', 'mskds-domainid') -SearchRoot "CN=Master Root Keys,CN=Group Key Distribution Service,CN=Services,CN=Configuration,$(Get-VfIdDomainDn $lcm.Domain)"
        if (@($a.Entries).Count) { New-VfIdResult Passed "A KDS root key exists ($(@($a.Entries).Count)); the file asks for gMSA." -Evidence "keys=$(@($a.Entries).Count)" }
        else { New-VfIdResult Failed 'The file asks for group managed service accounts but the domain has no KDS root key.' 'Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))   (lab only; in production wait 10 hours for replication)' -Evidence 'keys=0' }
    }
}

# ---- Local identity

Add-VfIdCheck -Id 'ID-LI-001' -Title 'Local identity settings: DNS zone, DNS server configuration and the template parameters they feed are present' -Source "$($script:Src.LocalArm) (ARM template parameters reference); $($script:Src.Local)" -Applies $script:IsLocal -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $i = Get-VfIdInfra $Context
        $li = Get-AzlProp $i 'identity.local_identity'
        $zone = [string](Get-AzlProp $li 'dns_zone' ''); $cfg = [string](Get-AzlProp $li 'dns_server_config' '')
        $forwarders = @(ConvertTo-VfIdList (Get-AzlProp $li 'dns_forwarders' @()))
        $problems = @()
        if (-not $zone) { $problems += 'identity.local_identity.dns_zone is empty (dnsZones: the zone name establishes the private, authoritative DNS namespace of the cluster)' }
        elseif ($zone -notmatch '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$') { $problems += "dns_zone '$zone' is not a fully qualified domain name" }
        if ($cfg -notin 'use_dns_server', 'use_forwarder') { $problems += "dns_server_config is '$cfg'; it must be use_dns_server (UseDnsServer: an existing DNS server) or use_forwarder (UseForwarder)" }
        if ($cfg -eq 'use_forwarder' -and -not $forwarders.Count) { $problems += 'dns_server_config is use_forwarder but dns_forwarders is empty (dnsZones.dnsForwarder)' }
        if ($cfg -eq 'use_dns_server' -and -not @(Get-VfIdDnsServer $Context).Count) { $problems += 'dns_server_config is use_dns_server but networking.management.dns_servers is empty' }
        if (-not (Get-AzlProp $i 'cluster.name' '')) { $problems += 'cluster.name is empty (namingPrefix and the system''s DNS record)' }
        if (-not (Get-AzlProp $i 'networking.management.infrastructure_pool.start' '')) { $problems += 'networking.management.infrastructure_pool.start is empty (startingIPAddress, and the address of the system''s DNS record)' }
        if ($problems) { return New-VfIdResult Failed ('Local identity: ' + ($problems -join '; ') + '.') 'Fix identity.local_identity in infrastructure.yml (template create-adless-cluster-external-dns-public-preview: identityProvider LocalIdentity, dnsServerConfig, dnsZones).' -Evidence ($problems -join ' | ') }
        New-VfIdResult Passed "Local identity: zone $zone, $cfg$(if ($forwarders.Count) { ", $($forwarders.Count) forwarder(s)" })." -Evidence "zone=$zone; config=$cfg"
    }
}

Add-VfIdCheck -Id 'ID-LI-002' -Title 'Local identity: static IP addresses only (no DHCP) for the nodes' -Source "$($script:Src.Local) (Prerequisites 4)" -Applies $script:IsLocal -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $i = Get-VfIdInfra $Context
        if ([bool](Get-AzlProp $i 'networking.management.use_dhcp' $false)) { return New-VfIdResult Failed 'networking.management.use_dhcp is true. Learn: the nodes require static IP addresses and don''t support DHCP with local identity.' 'Set networking.management.use_dhcp to false and give every node a static management address.' }
        $dhcp = @()
        foreach ($n in (Get-VfIdNode $Context)) { try { $m = Get-AzlManagementAdapter -Infrastructure $i -Node $n; if ($m -and [string]$m.IpAssignment -like 'dhcp*') { $dhcp += [string]$n['name'] } } catch { Write-Verbose "No management adapter: $($_.Exception.Message)" } }
        if ($dhcp) { return New-VfIdResult Failed "These nodes take their management address from DHCP in the file: $($dhcp -join ', '). Learn: local identity doesn't support DHCP." 'Set the management port''s ip_assignment to static for these nodes.' -Evidence "dhcp=$($dhcp -join ',')" }
        New-VfIdResult Passed 'The file uses static management addresses only.' -Evidence 'static'
    }
}

Add-VfIdCheck -Id 'ID-LI-003' -Title 'Local identity: A records for every node and for the system (first infrastructure address) in the zone' -Source "$($script:Src.Local) (Configure DNS server for Azure Local, steps 2 and 3)" -Applies { param($Context) (Get-VfIdIdentity $Context) -eq 'local_identity' -and [string](Get-AzlProp (Get-VfIdInfra $Context) 'identity.local_identity.dns_server_config' '') -eq 'use_dns_server' } -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $i = Get-VfIdInfra $Context
        $zone = Get-VfIdZone $Context
        $servers = @(Get-VfIdDnsServer $Context)
        $cluster = [string](Get-AzlProp $i 'cluster.name' '')
        $first = [string](Get-AzlProp $i 'networking.management.infrastructure_pool.start' '')
        if (-not $zone -or -not $servers.Count) { return New-VfIdResult Failed 'The DNS zone or the DNS servers are not set (ID-LI-001).' 'Set identity.local_identity.dns_zone and networking.management.dns_servers.' }
        $records = @()
        foreach ($n in (Get-VfIdNode $Context)) {
            $ip = ''
            try { $m = Get-AzlManagementAdapter -Infrastructure $i -Node $n; if ($m) { $ip = [string]$m.IpAddress } } catch { Write-Verbose "No management adapter: $($_.Exception.Message)" }
            if (-not $ip) { $ip = [string](Get-AzlProp $n 'management.ip_address' '') }
            $records += [pscustomobject]@{ Name = "$([string]$n['name']).$zone"; Expected = $ip; Node = [string]$n['name'] }
        }
        $records += [pscustomobject]@{ Name = "$cluster.$zone"; Expected = $first; Node = '*' }
        $bad = @()
        foreach ($rec in $records) {
            $r = Resolve-VfIdRecord -Context $Context -Name $rec.Name -Server $servers
            foreach ($s in $servers) {
                if ($r.Silent -contains $s) { $bad += "$($rec.Name): DNS server $s did not answer"; continue }
                $a = @($r.Answers[$s])
                if (-not $a.Count) { $bad += "$($rec.Name): no A record on $s (expected $($rec.Expected))" }
                elseif ($rec.Expected -and $rec.Expected -notin $a) { $bad += "$($rec.Name): $($a -join ', ') on $s, expected $($rec.Expected)" }
            }
        }
        if ($bad.Count -and @($bad | Where-Object { $_ -notmatch 'did not answer' }).Count -eq 0) { Stop-VfIdSkip "The DNS servers did not answer from this host: $($bad -join '; ')" 'Run the verification from a host that reaches the DNS servers.' }
        if ($bad) { return New-VfIdResult Failed "DNS records for the local identity deployment are missing or wrong: $($bad -join '; '). Learn: a Host (A) record for each node, and one for the system itself using the first IP address of the range allocated to it." "Add-DnsServerResourceRecordA -ZoneName '$zone' -Name '<name>' -IPv4Address '<address>' for each record above; verify with Resolve-DnsName <name>.$zone" -Evidence "bad=$($bad.Count)" }
        New-VfIdResult Passed "$($records.Count) A records ($(@(Get-VfIdNode $Context).Count) nodes and the system $cluster.$zone) resolve correctly on every DNS server." -Evidence "records=$($records.Count)"
    }
}

Add-VfIdCheck -Id 'ID-LI-004' -Title 'Local identity: nodes are in a workgroup and resolve the node names of the zone with the file''s DNS servers' -Source "$($script:Src.Local) (Prerequisites 5; Configure DNS server, steps 3 and 6); azl-toolkit Test-LocalIdentityConfig.ps1 (WORKGROUP)" -Applies $script:IsLocal -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $zone = Get-VfIdZone $Context
        $cfg = [string](Get-AzlProp (Get-VfIdInfra $Context) 'identity.local_identity.dns_server_config' '')
        Invoke-VfIdPerNode -Context $Context -Body {
            param($Name, $D)
            $problems = @(); $remedy = @()
            if ([bool](Get-AzlProp $D 'partOfDomain' $false)) { $problems += "it is joined to the domain $(Get-AzlProp $D 'domain' ''); a local identity deployment needs a workgroup machine"; $remedy += 'Remove-Computer -WorkgroupName WORKGROUP -Restart  (on the node)' }
            if ($cfg -eq 'use_dns_server') {
                $q = @(ConvertTo-VfIdList (Get-AzlProp $D 'dnsq' @()) | Where-Object { [string]$_.name -like "*.$zone" })
                $bad = @($q | Where-Object { -not $_.ok })
                if ($bad.Count) { $problems += "it cannot resolve $(@($bad | ForEach-Object { "$($_.name) on $($_.server)" } | Select-Object -First 3) -join ', ')"; $remedy += "On the node: Resolve-DnsName <node>.$zone -Server <dns server>; create the missing Host (A) records (ID-LI-003)" }
            }
            if ($problems) { New-VfIdResult Failed "${Name}: $($problems -join '; ')." ($remedy -join '; ') -Node $Name -Evidence "problems=$($problems.Count)" }
            else { New-VfIdResult Passed "$Name is in a workgroup$(if ($cfg -eq 'use_dns_server') { " and resolves the node names of $zone with every DNS server of the file" })." -Node $Name -Evidence 'workgroup' }
        }
    }
}

Add-VfIdCheck -Id 'ID-LI-005' -Title 'Local identity: SSH (sshd) is enabled on every node' -Source "$($script:Src.Local) (Prerequisites 6)" -Applies $script:IsLocal -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        Invoke-VfIdPerNode -Context $Context -Body {
            param($Name, $D)
            $ssh = Get-AzlProp $D 'sshd'
            if (-not $ssh) { New-VfIdResult Failed "$Name has no sshd service. Learn: enable SSH on each node for remote access from the Azure portal." 'On the node: Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Set-Service sshd -StartupType Automatic; Start-Service sshd' -Node $Name -Evidence 'no sshd' }
            elseif ([string]$ssh.status -ne 'Running') { New-VfIdResult Failed "On $Name sshd is $($ssh.status) (start type $($ssh.start))." 'Set-Service sshd -StartupType Automatic; Start-Service sshd   (on the node)' -Node $Name -Evidence "sshd=$($ssh.status)" }
            else { New-VfIdResult Passed "sshd is Running on $Name (start type $($ssh.start))." -Node $Name -Evidence 'sshd running' }
        }
    }
}

# ---- Local administrator and DNS client (both modes)

Add-VfIdCheck -Id 'ID-LA-001' -Title 'The dedicated local administrator in the file is named, is not the built-in Administrator and differs from the LCM user' -Source "$($script:Src.Local) (Prerequisites 2); $($script:Src.PrepAd) (the LCM name can't equal the local admin)" -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $i = Get-VfIdInfra $Context
        $user = [string](Get-AzlProp $i 'identity.local_admin.username' '')
        $ref = [string](Get-AzlProp $i 'identity.local_admin.password' '')
        $problems = @()
        if (-not $user) { $problems += 'identity.local_admin.username is empty' }
        elseif ($user -in 'Administrator', 'Guest', 'DefaultAccount') { $problems += "identity.local_admin.username is '$user', a built-in account. Learn: create a local administrator and don't use the built-in Administrator account" }
        if (-not $ref) { $problems += 'identity.local_admin.password is empty (a keyvault:// reference)' }
        if ($user -and (Get-VfIdIdentity $Context) -eq 'active_directory' -and $user -ieq [string](Get-AzlProp $i 'identity.active_directory.lcm_user.username' '')) { $problems += 'the local administrator and the LCM user have the same name' }
        if ($problems) { return New-VfIdResult Failed ('identity.local_admin: ' + ($problems -join '; ') + '.') 'Set identity.local_admin.username to a dedicated account (for example azl-admin) and its password to a keyvault:// reference.' -Evidence ($problems -join ' | ') }
        New-VfIdResult Passed "The dedicated local administrator is '$user' (not a built-in account), its password is a Key Vault reference." -Evidence "user=$user"
    }
}

Add-VfIdCheck -Id 'ID-LA-002' -Title 'Local administrator password policy: at least 14 characters with lower, upper, digit and special character' -Source "$($script:Src.Prereq) (Local administrator credentials); $($script:Src.InstallOs)" -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $ref = [string](Get-AzlProp (Get-VfIdInfra $Context) 'identity.local_admin.password' '')
        if (-not $ref) { return New-VfIdResult Failed 'identity.local_admin.password is empty: there is no password to check.' 'Set identity.local_admin.password to a keyvault:// reference.' }
        $missing = @(Test-VfIdPassword (Get-VfIdSecret $Context $ref))
        if ($missing) { return New-VfIdResult Failed "The local administrator password ($ref) lacks $($missing -join ', ') (value not shown)." "Set a new secret in Key Vault ($ref) and the same password for the account on every node (net user <name> <password>, or SConfig option 3)." -Evidence "missing=$($missing.Count)" }
        New-VfIdResult Passed "The local administrator password ($ref) meets the length and complexity rule (value not shown)." -Evidence 'rule: 14+ chars, 4 classes'
    }
}

Add-VfIdCheck -Id 'ID-LA-003' -Title 'The Key Vault password opens a WinRM session as the dedicated local administrator on every node' -Source "$($script:Src.Local) (identical credentials on every node); $($script:Src.Prereq)" -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $user = [string](Get-AzlProp (Get-VfIdInfra $Context) 'identity.local_admin.username' '')
        foreach ($n in (Get-VfIdNode $Context)) {
            $name = [string]$n['name']
            $p = Get-VfIdProbe -Context $Context -Node $n
            if ($p.Ok) { New-VfIdResult Passed "A read only WinRM session opened on $name as $name\$user with the Key Vault password (address $($p.Address))." -Node $name -Evidence "address=$($p.Address)"; continue }
            if ($p.AuthFailed) { New-VfIdResult Failed "$name rejected $name\$user with the password from Key Vault: $($p.Error)" "Set the same password for $user on the node and in Key Vault (identity.local_admin.password); the credential must be identical on every node." -Node $name -Evidence 'auth rejected'; continue }
            New-VfIdResult Skipped "$name could not be reached over WinRM, so the credential could not be tried: $($p.Error)" 'Make the node reachable (network, WinRM listener, TrustedHosts or HTTPS) and run the verification again.' -Node $name
        }
    }
}

Add-VfIdCheck -Id 'ID-LA-004' -Title 'On every node the dedicated local administrator exists, is enabled, is in local Administrators and is not the built-in Administrator' -Source "$($script:Src.Local) (Prerequisites 2.1); azl-toolkit Deploy-CreateLocalAdmin.ps1, Test-LocalIdentityConfig.ps1" -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $user = [string](Get-AzlProp (Get-VfIdInfra $Context) 'identity.local_admin.username' '')
        Invoke-VfIdPerNode -Context $Context -Body {
            param($Name, $D)
            $adm = Get-AzlProp $D 'admin'
            $problems = @()
            if (-not $adm -or -not [bool](Get-AzlProp $adm 'exists' $false)) { $problems += "the local user $user does not exist" }
            else {
                if (-not [bool](Get-AzlProp $adm 'enabled' $false)) { $problems += "the local user $user is disabled" }
                # The built-in Administrator always has RID 500, even when renamed.
                if ([string](Get-AzlProp $adm 'sid' '') -match '-500$') { $problems += "$user is the built-in Administrator account (RID 500), renamed" }
                $members = @(ConvertTo-VfIdList (Get-AzlProp $D 'admins' @()) | ForEach-Object { [string]$_ })
                if (-not (@($members | Where-Object { $_ -ieq $user -or $_ -ieq "$Name\$user" }).Count)) { $problems += "$user is not in the local Administrators group" }
            }
            if ($problems) { New-VfIdResult Failed "${Name}: $($problems -join '; ')." "On the node: New-LocalUser -Name $user -Password (Read-Host -AsSecureString); Add-LocalGroupMember -Group Administrators -Member $user   (SConfig option 3 does the same); same name and password on every node." -Node $Name -Evidence "problems=$($problems.Count)" }
            else { New-VfIdResult Passed "$user exists on $Name, is enabled, is a local administrator and is not the built-in account." -Node $Name -Evidence "sid=$([string](Get-AzlProp $adm 'sid' ''))" }
        }
    }
}

Add-VfIdCheck -Id 'ID-DNS-003' -Title 'The DNS servers on the nodes are the file''s, and the nodes resolve the Azure endpoints with them' -Source "azl-toolkit Test-DnsClientConfig.ps1 (DNS servers, Azure endpoint resolution); $($script:Src.Prereq) (DNS server must resolve the AD domain; can't be changed after deployment)" -Run {
    param($Context)
    Invoke-VfIdCheck $Context {
        $expected = @(Get-VfIdDnsServer $Context)
        if (-not $expected.Count) { return New-VfIdResult Failed 'networking.management.dns_servers is empty.' 'Set the DNS servers of the management network.' }
        Invoke-VfIdPerNode -Context $Context -Body {
            param($Name, $D)
            $clients = @(ConvertTo-VfIdList (Get-AzlProp $D 'dnsClient' @()))
            $actual = @($clients | ForEach-Object { @(ConvertTo-VfIdList $_.servers) } | ForEach-Object { [string]$_ } | Select-Object -Unique)
            $missing = @($expected | Where-Object { $_ -notin $actual })
            $documented = @(Get-VfIdDnsEndpoint $Context)
            $tierOf = @{}; foreach ($x in $documented) { $tierOf[[string]$x.Host] = [string]$x.Tier }
            $endpoints = @(ConvertTo-VfIdList (Get-AzlProp $D 'dnsq' @()) | Where-Object { $tierOf.ContainsKey([string]$_.name) })
            $failedAll = @($endpoints | Where-Object { -not $_.ok })
            $failed = @($failedAll | Where-Object { $tierOf[[string]$_.name] -ne 'Optional' })
            if (-not $clients.Count) { New-VfIdResult Skipped "$Name returned no DNS client configuration." 'Check the node read (ID-LA-003).' -Node $Name }
            elseif ($missing.Count) { New-VfIdResult Failed "$Name does not use DNS server(s) $($missing -join ', ') of the file (it has: $($actual -join ', ')). They can't be changed after the deployment." "On the node: Set-DnsClientServerAddress -InterfaceAlias <management adapter> -ServerAddresses $($expected -join ',')   (or run the OS configuration Dns step)" -Node $Name -Evidence "have=$($actual -join ',')" }
            elseif ($failed.Count) { New-VfIdResult Failed "$Name cannot resolve $(@($failed | ForEach-Object { "$($_.name) on $($_.server)" } | Select-Object -First 4) -join '; ') with the file's DNS servers." 'Add DNS forwarding on the DNS servers to a resolver that answers external names (Learn: set up DNS forwarding), then Resolve-DnsName management.azure.com on the node.' -Node $Name -Evidence "failed=$($failed.Count) of $($endpoints.Count)" }
            else { New-VfIdResult Passed "$Name uses the file's DNS servers ($($expected -join ', ')) and resolves the $(@($documented).Count) documented Azure endpoints with each. $(Format-AzlEndpointNotTested -Location ([string](Get-AzlProp (Get-VfIdInfra $Context) 'azure.location' '')))" -Node $Name -Evidence "endpoints=$($endpoints.Count) ok" }
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlVerificationCheckDefinition {
    <#
    .SYNOPSIS
        The identity checks of the pre-cluster verification gate.
    .OUTPUTS
        Id, Category ('identity'), Title, Source, Blocking, Applies ({ param($Context) -> bool }), Run ({ param($Context) -> results }).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return $script:Check.ToArray()
}

function Get-AzlVerificationAdapterDefault {
    <#
    .SYNOPSIS
        The real adapters for the identity checks. All of them read only.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    @{
        Ad       = @{
            Search = {
                param($Filter, $SearchRoot, $Options)
                $request = [pscustomobject]@{
                    Servers = @($Options.Servers); Port = 389; Credential = $Options.Credential; SearchRoot = $SearchRoot; Filter = $Filter
                    Properties = @($Options.Properties); TimeoutSeconds = [int]$Options.TimeoutSeconds; Scope = [string]$Options.Scope; SecurityMasks = [string]$Options.SecurityMasks
                }
                $module = Get-Module -Name AzlDomainJoin
                & $module { param($Request) Invoke-DjLdapSearch -Request $Request } $request
            }
        }
        Dns      = @{
            Resolve = {
                param($Name, $Server)
                # Ok is false when the server did not answer; Addresses is empty when it has no record.
                if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { return $null }
                try { [pscustomobject]@{ Ok = $true; Addresses = @(Resolve-DnsName -Name $Name -Server $Server -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress }); Error = '' } }
                catch {
                    $text = $_.Exception.Message
                    $missing = $text -match 'DNS name does not exist|DNS_ERROR_RCODE_NAME_ERROR|No such host|does not exist'
                    [pscustomobject]@{ Ok = [bool]$missing; Addresses = @(); Error = $text }
                }
            }
        }
        Remote   = @{
            Invoke = {
                param($Request)
                $last = ''
                $auth = $false
                $option = New-PSSessionOption -OpenTimeout 20000 -OperationTimeout 60000 -SkipCACheck -SkipCNCheck
                foreach ($address in @($Request.Addresses)) {
                    try {
                        $arguments = @{
                            ComputerName = $address; Credential = $Request.Credential; ScriptBlock = $Request.ScriptBlock; ArgumentList = @($Request.ArgumentList)
                            Authentication = $Request.Authentication; SessionOption = $option; ErrorAction = 'Stop'
                        }
                        if ($Request.UseSsl) { $arguments.UseSSL = $true }
                        $result = Invoke-Command @arguments
                        return [pscustomobject]@{ Ok = $true; Address = $address; Result = $result; Error = ''; AuthFailed = $false }
                    }
                    catch {
                        $last = "${address}: $($_.Exception.Message)"
                        if ($_.Exception.Message -match '(?i)access is denied|logon failure|user name or password is incorrect|authentication') { $auth = $true }
                    }
                }
                [pscustomobject]@{ Ok = $false; Address = ''; Result = $null; Error = $last; AuthFailed = $auth }
            }
        }
        KeyVault = @{ GetSecret = { param($Reference) Get-AzlSecret -Reference $Reference } }
        Clock    = @{ Now = { Get-Date } }
    }
}

Export-ModuleMember -Function Get-AzlVerificationCheckDefinition, Get-AzlVerificationAdapterDefault
