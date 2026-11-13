#Requires -Version 7.0
<#
.SYNOPSIS
    Vendor-neutral Redfish discovery core: read-only HTTP, standard DMTF resources, vendor detection, capability report.

.DESCRIPTION
    Hardware discovery is the first stage of the flow: it runs before azurelocal-ztp and before the OS configuration. This
    module is the generic part. It reads the standard Redfish resources (ComputerSystem, Processors, Memory, Storage,
    NetworkAdapters, PCIeDevices, Bios, SecureBoot, UpdateService/FirmwareInventory, Power/Thermal or the newer
    PowerSubsystem/ThermalSubsystem/Sensors, LogServices, Manager) by following links from the service root, and hands the
    vendor specific parts to an adapter (AzlRedfishDell.psm1). This version ships the Dell iDRAC adapter only; any other
    vendor is reported as unsupported in this version.

    Rules this module keeps:
      * Read only. The HTTP layer (Invoke-AzlRedfishRequest) has no method parameter and sends GET. The only other requests
        are the session POST and the DELETE of that same session, and only with -UseSession.
      * Secrets never reach a log, an error message or the output: passwords, tokens and Authorization headers are redacted.
      * A resource the BMC does not offer (404, 501) is notSupported, 401/403 is denied, a timeout or 5xx is error. Each is a
        capability and a readErrors entry, never a silent catch.
      * Unknown is $null, never an empty string. MACs are AA:BB:CC:DD:EE:FF.

    Output is the per-node report (schemaVersion 2.0), see docs/hardware-discovery.md.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'secrets', 'AzlSecret.psm1'))

$script:ToolVersion = '2.0.0'
$script:SchemaVersion = '2.0'
$script:SupportedVendors = @('Dell')
$script:JsonHasDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')
$script:SecretKeyPattern = '(?i)pass(word|phrase)?|secret|token|community|private.?key|auth.?key|product.?key|session.?id|credential'

#region helpers

function Get-RfProp {
    # Reads a property from a parsed object or a dictionary; $Default when it is missing (safe under strict mode).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $Default } }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Get-RfText {
    # A trimmed string, or $null when it is missing or blank (unknown is null, never '').
    param($Object, [string]$Name)
    $v = Get-RfProp $Object $Name
    if ($null -eq $v -or $v -is [System.Collections.IDictionary] -or $v -is [pscustomobject]) { return $null }
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) }
    $s = ([string]$v).Trim()
    if ($s.Length -eq 0) { return $null }
    return $s
}

function Get-RfArray {
    # A property as an array (empty when missing).
    param($Object, [string]$Name)
    $v = Get-RfProp $Object $Name
    if ($null -eq $v) { return @() }
    return @($v)
}

function Get-RfLink {
    # The @odata.id of a link property ({ "@odata.id": ... }), or $null.
    param($Object, [string]$Name)
    $v = Get-RfProp $Object $Name
    if ($null -eq $v) { return $null }
    $id = Get-RfProp $v '@odata.id'
    if ($id) { return [string]$id }
    return $null
}

function Get-RfLinkList {
    # The @odata.id of every element of an array of links.
    param($Items)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($i in @($Items)) { $id = Get-RfProp $i '@odata.id'; if ($id) { $out.Add([string]$id) } }
    return $out.ToArray()
}

function Get-RfStatus {
    param($Object)
    $s = Get-RfProp $Object 'Status'
    if ($null -eq $s) { return $null }
    return [ordered]@{ health = (Get-RfText $s 'Health'); healthRollup = (Get-RfText $s 'HealthRollup'); state = (Get-RfText $s 'State') }
}

function ConvertTo-RfGiB {
    param($Bytes)
    if ($null -eq $Bytes) { return $null }
    return [math]::Round(([double]$Bytes) / 1GB, 2)
}

function ConvertTo-AzlMacAddress {
    <#
    .SYNOPSIS
        A MAC in any common notation into AA:BB:CC:DD:EE:FF. $null when it is not 12 hexadecimal digits.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex.Length -ne 12 -or $hex -ne ($Mac -replace '[:\-\.\s]', '').ToUpperInvariant()) { return $null }
    return (($hex -split '(?<=\G.{2})(?=.)') -join ':')
}

function Remove-AzlRedfishSecret {
    <#
    .SYNOPSIS
        A copy of a parsed value with the value of every secret-looking key replaced by '<redacted>' (or $null when it was null).
    .DESCRIPTION
        Applied to attribute dictionaries (BIOS, BMC) and to raw vendor blocks before they go into the output. The key stays,
        so the output still shows that the attribute exists.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory bookkeeping of one discovery run; no system state changes.')]
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [int]$Depth = 0)
    if ($null -eq $InputObject -or $Depth -gt 25) { return $InputObject }
    if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive -or $InputObject -is [datetime]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary] -or $InputObject -is [pscustomobject]) {
        $out = [ordered]@{}
        $pairs = if ($InputObject -is [System.Collections.IDictionary]) { $InputObject.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } } }
        else { $InputObject.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } } }
        foreach ($p in $pairs) {
            if ($p.Name -match $script:SecretKeyPattern) { $out[$p.Name] = $(if ($null -eq $p.Value) { $null } else { '<redacted>' }) }
            else { $out[$p.Name] = Remove-AzlRedfishSecret -InputObject $p.Value -Depth ($Depth + 1) }
        }
        return $out
    }
    if ($InputObject -is [System.Collections.IEnumerable]) { return , @(foreach ($i in $InputObject) { Remove-AzlRedfishSecret -InputObject $i -Depth ($Depth + 1) }) }
    return $InputObject
}

function Hide-AzlRedfishSecretText {
    # Removes the password, the session token and Basic/Bearer/X-Auth values from a message before it is stored or shown.
    param([AllowNull()][string]$Text, $Context)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    if ($Context) {
        foreach ($s in @($Context.Secrets)) { if ($s -and $s.Length -ge 4) { $t = $t.Replace($s, '<redacted>') } }
    }
    $t = $t -replace '(?i)(authorization|x-auth-token|set-cookie|cookie)\s*[:=]\s*(?:(?:basic|bearer)\s+)?\S+', '$1: <redacted>'
    $t = $t -replace '(?i)\b(basic|bearer)\s+[A-Za-z0-9+/=._-]{8,}', '$1 <redacted>'
    return $t
}

function Limit-AzlRedfishRaw {
    # A raw vendor block, secrets removed, replaced by a marker when its JSON is larger than the cap.
    param($Block, [int]$MaxBytes = 262144)
    if ($null -eq $Block) { return $null }
    $clean = Remove-AzlRedfishSecret -InputObject $Block
    $json = $clean | ConvertTo-Json -Depth 30 -Compress
    if ($json.Length -gt $MaxBytes) { return [ordered]@{ truncated = $true; bytes = $json.Length; maxBytes = $MaxBytes } }
    return $clean
}

#endregion

#region credentials

function Get-AzlBmcKeyVaultSecret {
    # One secret read, through the toolkit's one secret resolver (any provider: keyvault://, env://, file://, command://). The name is
    # kept for the callers. A wrapper so a test replaces it and no vault is needed. The password stays a SecureString.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reference, [System.Collections.IDictionary]$Infrastructure, [switch]$AsPlainText)
    if ($AsPlainText) { return [string](Get-AzlSecretPlainText -Reference $Reference -Infrastructure $Infrastructure) }
    return (Get-AzlSecretValue -Reference $Reference -Infrastructure $Infrastructure)
}

function Resolve-AzlBmcCredential {
    <#
    .SYNOPSIS
        The BMC login. Order: -Credential, then Key Vault references in infrastructure.yml, then a prompt.
    .DESCRIPTION
        The file holds references only (schema 5: hardware.bmc, or nodes[].bmc, username and password as keyvault://vault/secret;
        a username may also be the plain user name). A node's bmc block wins over hardware.bmc. When Key Vault cannot be read,
        it warns (without the secret) and prompts, unless -NoPrompt.
    .PARAMETER Infrastructure
        The parsed infrastructure.yml (ordered dictionary), optional.
    .PARAMETER Node
        A nodes[] entry, optional.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [System.Collections.IDictionary]$Infrastructure,
        [System.Collections.IDictionary]$Node,
        [switch]$NoPrompt
    )
    if ($Credential) { return $Credential }
    $block = $null
    $nodeBmc = Get-RfProp $Node 'bmc'
    if ($nodeBmc -is [System.Collections.IDictionary] -and $nodeBmc.Contains('username') -and $nodeBmc.Contains('password')) { $block = $nodeBmc }
    if (-not $block) {
        $hardwareBmc = Get-RfProp (Get-RfProp $Infrastructure 'hardware') 'bmc'
        if ($hardwareBmc -is [System.Collections.IDictionary] -and $hardwareBmc.Contains('username') -and $hardwareBmc.Contains('password')) { $block = $hardwareBmc }
    }
    $userHint = $null
    if ($block) {
        try {
            $user = [string]$block['username']
            if (Get-AzlSecretProvider -Reference $user) { $user = Get-AzlBmcKeyVaultSecret -Reference $user -Infrastructure $Infrastructure -AsPlainText }
            $userHint = $user
            $password = Get-AzlBmcKeyVaultSecret -Reference ([string]$block['password']) -Infrastructure $Infrastructure
            return [System.Management.Automation.PSCredential]::new($user, $password)
        }
        catch {
            Write-Warning "The BMC credential could not be read: $($_.Exception.Message)"
        }
    }
    if ($NoPrompt) { throw 'No BMC credential: pass -Credential, or put hardware.bmc username and password (secret references) in infrastructure.yml.' }
    $prompt = @{ Message = 'BMC administrator credentials' }
    if ($userHint) { $prompt.UserName = $userHint }
    return (Get-Credential @prompt)
}

#endregion

#region HTTP layer (GET only)

function New-AzlRedfishContext {
    <#
    .SYNOPSIS
        The per-BMC state of one discovery run: address, login, TLS choice, timeouts, cache, capability and error records.
    .PARAMETER VerifyCertificate
        Check the BMC TLS certificate. Default: not checked (BMCs ship a self-signed certificate); the skip applies to these
        requests only.
    .PARAMETER UseSession
        Log in with a Redfish session (X-Auth-Token) instead of Basic on every request. The session POST and its DELETE are
        then the only non-GET requests, and the DELETE is guaranteed in Invoke-AzlRedfishDiscovery's finally.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory bookkeeping of one discovery run; no system state changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BmcAddress,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [switch]$VerifyCertificate,
        [switch]$UseSession,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60,
        [ValidateRange(1, 120)][int]$ConnectTimeoutSeconds = 10,
        [ValidateRange(0, 5)][int]$MaxRetries = 1,
        [ValidateRange(0, 60)][int]$RetryDelaySeconds = 2,
        [ValidateRange(10, 7200)][int]$NodeBudgetSeconds = 900,
        [ValidateRange(1, 10)][int]$MaxAuthFailures = 3,
        [ValidateRange(1, 5000)][int]$MaxMembers = 1000
    )
    $plain = $Credential.GetNetworkCredential().Password
    return [pscustomobject]@{
        BmcAddress = $BmcAddress; Credential = $Credential; VerifyCertificate = $VerifyCertificate.IsPresent; UseSession = $UseSession.IsPresent
        TimeoutSeconds = $TimeoutSeconds; ConnectTimeoutSeconds = $ConnectTimeoutSeconds; MaxRetries = $MaxRetries; RetryDelaySeconds = $RetryDelaySeconds
        MaxAuthFailures = $MaxAuthFailures; MaxMembers = $MaxMembers
        Deadline = [datetime]::UtcNow.AddSeconds($NodeBudgetSeconds)
        Token = $null; SessionPath = $null
        Secrets = [System.Collections.Generic.List[string]]::new([string[]]@($plain))
        Cache = @{}; Areas = [ordered]@{}; CurrentArea = $null
        ReadErrors = [System.Collections.Generic.List[object]]::new()
        OemPaths = [System.Collections.Generic.List[object]]::new()
        Warnings = [System.Collections.Generic.List[string]]::new()
        AuthFailures = 0; RequestCount = 0
    }
}

function Send-AzlRedfishHttp {
    # The single place that talks HTTP. A test replaces Invoke-WebRequest and sees every request this module makes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Get', 'Post', 'Delete')][string]$Method = 'Get',
        [string]$Body
    )
    $uri = if ($Path -match '^https://') { $Path } else { "https://$($Context.BmcAddress)$Path" }
    $request = @{
        Uri = $uri; Method = $Method; Headers = @{ Accept = 'application/json' }; SkipCertificateCheck = (-not $Context.VerifyCertificate)
        SkipHttpErrorCheck = $true; ErrorAction = 'Stop'
    }
    # PowerShell 7.4+: -TimeoutSec is an alias of -ConnectionTimeoutSeconds, and -OperationTimeoutSeconds bounds the response.
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) {
        $request.ConnectionTimeoutSeconds = $Context.ConnectTimeoutSeconds
        $request.OperationTimeoutSeconds = $Context.TimeoutSeconds
    }
    else { $request.TimeoutSec = $Context.TimeoutSeconds }
    if ($Context.Token) { $request.Headers['X-Auth-Token'] = $Context.Token }
    elseif ($Method -ne 'Post' -or -not $Context.UseSession) { $request.Credential = $Context.Credential; $request.Authentication = 'Basic' }
    if ($Method -eq 'Post') { $request.Body = $Body; $request.ContentType = 'application/json' }
    return (Invoke-WebRequest @request)
}

function ConvertTo-AzlRedfishPath {
    param($Context, [string]$Path)
    $p = $Path
    if ($p -match '^https://(?<host>[^/]+)(?<rest>/.*)?$') {
        if ($Matches['host'] -ne $Context.BmcAddress) { throw "Refusing to follow a link to another host ('$($Matches['host'])')." }
        $p = if ($Matches['rest']) { $Matches['rest'] } else { '/' }
    }
    $p = ($p -split '#')[0]
    if ($p.Length -gt 1) { $p = $p.TrimEnd('/') }
    if (-not $p.StartsWith('/')) { $p = "/$p" }
    return $p
}

function Get-AzlRedfishErrorKind {
    # notSupported (404, 405, 501), denied (401, 403), error (everything else that is not 2xx).
    param([int]$Status)
    if ($Status -ge 200 -and $Status -lt 300) { return 'ok' }
    if ($Status -in 404, 405, 410, 501) { return 'notSupported' }
    if ($Status -in 401, 403) { return 'denied' }
    return 'error'
}

function Add-RfAreaPath {
    param($Context, [string]$Path, [bool]$Ok)
    $area = $Context.CurrentArea
    if (-not $area) { return }
    $a = $Context.Areas[$area]
    $a.Attempted++
    if ($Ok) { $a.Ok++ }
    if ($a.Paths.Count -lt 40) { $a.Paths.Add($Path) } else { $a.MorePaths++ }
}

function Invoke-AzlRedfishRequest {
    <#
    .SYNOPSIS
        One Redfish GET. Never throws for an HTTP error: returns Ok, Status, Kind, Body and Message.
    .DESCRIPTION
        There is no method parameter: this function can only GET. A timeout, a connection error, a 5xx or a 429 is retried
        MaxRetries times with a growing delay. Three 401 answers in a row stop the run for this BMC (account lockout guard).
        The result of a path is cached for the run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path)
    try { $p = ConvertTo-AzlRedfishPath $Context $Path }
    catch { return [pscustomobject]@{ Ok = $false; Status = 0; Kind = 'error'; Body = $null; Message = $_.Exception.Message; Path = $Path; Retried = $false; Cached = $false } }
    if ($Context.Cache.ContainsKey($p)) {
        $c = $Context.Cache[$p]
        return [pscustomobject]@{ Ok = $c.Ok; Status = $c.Status; Kind = $c.Kind; Body = $c.Body; Message = $c.Message; Path = $p; Retried = $c.Retried; Cached = $true }
    }
    $retried = $false
    $result = $null
    $attempt = 0
    while ($true) {
        if ([datetime]::UtcNow -gt $Context.Deadline) {
            $result = @{ Ok = $false; Status = 0; Kind = 'error'; Body = $null; Message = 'The per-node time budget was used up before this resource was read.' }
            break
        }
        $Context.RequestCount++
        $response = $null
        $failure = $null
        try { $response = Send-AzlRedfishHttp -Context $Context -Path $p -Method Get }
        catch { $failure = Hide-AzlRedfishSecretText -Text $_.Exception.Message -Context $Context }
        $status = if ($response) { [int]$response.StatusCode } else { 0 }
        $transient = ($failure -or $status -eq 429 -or $status -ge 500)
        if ($transient -and $attempt -lt $Context.MaxRetries) {
            $attempt++
            $retried = $true
            Write-Verbose "GET $p -> $(if ($failure) { 'failed' } else { $status }); retry $attempt"
            if ($Context.RetryDelaySeconds -gt 0) { Start-Sleep -Seconds ($Context.RetryDelaySeconds * $attempt) }
            continue
        }
        if ($failure) { $result = @{ Ok = $false; Status = 0; Kind = 'error'; Body = $null; Message = "Request failed: $failure" }; break }
        $text = [string]$response.Content
        $body = $null
        if ($text.Trim().Length -gt 0) {
            $json = @{ Depth = 50 }
            if ($script:JsonHasDateKind) { $json.DateKind = 'String' }
            try { $body = $text | ConvertFrom-Json @json }
            catch {
                try { $body = $text | ConvertFrom-Json -AsHashtable @json }
                catch { $body = $null; if ($status -lt 300) { $status = 502; $failure = 'The response was not valid JSON.' } }
            }
        }
        $kind = Get-AzlRedfishErrorKind -Status $status
        $message = $null
        if ($kind -ne 'ok') {
            $message = Get-RfText (Get-RfProp $body 'error') 'message'
            if (-not $message) { $message = $failure }
            if (-not $message) { $message = "HTTP $status" }
            $message = Hide-AzlRedfishSecretText -Text $message -Context $Context
        }
        $result = @{ Ok = ($kind -eq 'ok'); Status = $status; Kind = $kind; Body = $(if ($kind -eq 'ok') { $body } else { $null }); Message = $message }
        break
    }
    $result.Retried = $retried
    if ($result.Status -eq 401) { $Context.AuthFailures++ } elseif ($result.Ok) { $Context.AuthFailures = 0 }
    $Context.Cache[$p] = $result
    Add-RfAreaPath -Context $Context -Path $p -Ok $result.Ok
    Write-Verbose "GET $p -> $($result.Status) $($result.Kind)"
    if ($Context.AuthFailures -ge $Context.MaxAuthFailures) {
        throw "Authentication was rejected $($Context.AuthFailures) times in a row by $($Context.BmcAddress). Stopping this BMC to avoid locking the account: check the user name and password."
    }
    return [pscustomobject]@{ Ok = $result.Ok; Status = $result.Status; Kind = $result.Kind; Body = $result.Body; Message = $result.Message; Path = $p; Retried = $retried; Cached = $false }
}

function Register-AzlRedfishFailure {
    # Records a failed read in readErrors and in the current area. A resource that was probed and not needed is not registered.
    param($Context, $Result, [string]$Area)
    if ($Result.Ok -or $Result.Cached) { return }
    $areaName = if ($Area) { $Area } else { $Context.CurrentArea }
    $Context.ReadErrors.Add([ordered]@{ area = $areaName; path = $Result.Path; status = $Result.Status; kind = $Result.Kind; message = $Result.Message; retried = $Result.Retried })
    if ($areaName -and $Context.Areas.Contains($areaName)) { $Context.Areas[$areaName].Failures.Add($Result.Kind) }
}

function Read-AzlRedfishResource {
    <#
    .SYNOPSIS
        Reads one resource. Returns the parsed body, or $null on failure (recorded in readErrors unless -Probe).
    .PARAMETER Probe
        The path is one of several variants: a failure is not recorded. Use Register-AzlRedfishFailure when all variants fail.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path, [switch]$Probe)
    $r = Invoke-AzlRedfishRequest -Context $Context -Path $Path
    if (-not $r.Ok -and -not $Probe) { Register-AzlRedfishFailure -Context $Context -Result $r }
    return $r.Body
}

function Get-AzlRedfishMember {
    <#
    .SYNOPSIS
        The body of every member of a collection (follows @odata.nextLink; bounded by MaxMembers).
    .PARAMETER Inline
        Use members that already carry their data (as log entries do) instead of reading each one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path, [switch]$Inline, [switch]$Probe)
    $members = [System.Collections.Generic.List[object]]::new()
    $next = $Path
    $pages = 0
    while ($next -and $pages -lt 50 -and $members.Count -lt $Context.MaxMembers) {
        $collection = Read-AzlRedfishResource -Context $Context -Path $next -Probe:$Probe
        if ($null -eq $collection) { break }
        $pages++
        foreach ($m in @(Get-RfProp $collection 'Members' @())) {
            if ($members.Count -ge $Context.MaxMembers) { break }
            $link = [string](Get-RfProp $m '@odata.id' '')
            $hasData = @($m.PSObject.Properties | Where-Object { $_.Name -ne '@odata.id' }).Count -gt 0
            if ($Inline -and $hasData) { $members.Add($m); continue }
            if (-not $link) { continue }
            $body = Read-AzlRedfishResource -Context $Context -Path $link
            if ($null -ne $body) { $members.Add($body) }
        }
        $next = [string](Get-RfProp $collection 'Members@odata.nextLink' (Get-RfProp $collection '@odata.nextLink' ''))
    }
    return @($members)
}

function Open-AzlRedfishSession {
    <#
    .SYNOPSIS
        Logs in with POST /redfish/v1/SessionService/Sessions. Only used with -UseSession.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $cred = $Context.Credential.GetNetworkCredential()
    $body = [ordered]@{ UserName = $cred.UserName; Password = $cred.Password } | ConvertTo-Json -Compress
    $response = Send-AzlRedfishHttp -Context $Context -Path '/redfish/v1/SessionService/Sessions' -Method Post -Body $body
    $status = [int]$response.StatusCode
    if ($status -lt 200 -or $status -ge 300) { throw "The BMC refused the session login (HTTP $status)." }
    $headers = $response.Headers
    $token = $null
    $location = $null
    foreach ($name in 'X-Auth-Token', 'Location') {
        $v = $null
        if ($headers -is [System.Collections.IDictionary] -and $headers.Contains($name)) { $v = @($headers[$name])[0] }
        elseif ($headers) { $v = Get-RfProp $headers $name }
        if ($name -eq 'X-Auth-Token') { $token = [string]$v } else { $location = [string]$v }
    }
    if (-not $token) { throw 'The BMC accepted the session login but sent no X-Auth-Token.' }
    $Context.Token = $token
    $Context.Secrets.Add($token)
    if ($location) { $Context.SessionPath = ConvertTo-AzlRedfishPath $Context $location }
}

function Close-AzlRedfishSession {
    <#
    .SYNOPSIS
        Deletes the session opened by Open-AzlRedfishSession. Never throws: a failed logout is a warning.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Token) { return }
    try {
        if ($Context.SessionPath) { $null = Send-AzlRedfishHttp -Context $Context -Path $Context.SessionPath -Method Delete }
        else { $Context.Warnings.Add('The session had no Location header, so it could not be deleted; it expires on the BMC.') }
    }
    catch { $Context.Warnings.Add("The session could not be deleted: $(Hide-AzlRedfishSecretText -Text $_.Exception.Message -Context $Context)") }
    finally { $Context.Token = $null; $Context.SessionPath = $null }
}

#endregion

#region capability areas

function Start-AzlRedfishArea {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory bookkeeping of one discovery run; no system state changes.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    if (-not $Context.Areas.Contains($Name)) {
        $Context.Areas[$Name] = @{ Attempted = 0; Ok = 0; Failures = [System.Collections.Generic.List[string]]::new(); Paths = [System.Collections.Generic.List[string]]::new(); MorePaths = 0; Status = $null; Variant = $null; Count = $null; Reason = $null; Notes = [System.Collections.Generic.List[string]]::new() }
    }
    $Context.CurrentArea = $Name
}

function Stop-AzlRedfishArea {
    <#
    .SYNOPSIS
        Closes the current area and decides its status: ok | partial | notSupported | denied | error | skipped.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory bookkeeping of one discovery run; no system state changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Variant,
        $Count,
        [string]$Reason,
        [ValidateSet('ok', 'partial', 'notSupported', 'denied', 'error', 'skipped')][string]$Status
    )
    $a = $Context.Areas[$Context.CurrentArea]
    if ($Status) { $a.Status = $Status }
    elseif ($a.Failures.Count -eq 0) { $a.Status = $(if ($a.Ok -gt 0) { 'ok' } else { 'notSupported' }) }
    elseif ($a.Ok -gt 0 -and -not ($null -ne $Count -and [int]$Count -eq 0)) { $a.Status = 'partial' }
    else {
        $kinds = @($a.Failures | Select-Object -Unique)
        $a.Status = $(if ($kinds.Count -eq 1) { $kinds[0] } else { 'error' })
    }
    if ($Variant) { $a.Variant = $Variant }
    if ($null -ne $Count) { $a.Count = $Count }
    if ($Reason) { $a.Reason = $Reason }
    elseif ($a.Status -notin 'ok', 'skipped' -and -not $a.Reason) {
        $first = $Context.ReadErrors | Where-Object { $_.area -eq $Context.CurrentArea } | Select-Object -First 1
        $a.Reason = $(if ($first) { "$($first.path): $($first.message)" } else { 'The BMC does not link this resource.' })
    }
    $Context.CurrentArea = $null
}

function Add-AzlRedfishNote {
    <#
    .SYNOPSIS
        Adds a note to an area of the capability report: something that was readable but not usable, and why.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Area, [Parameter(Mandatory)][string]$Text)
    if (-not $Context.Areas.Contains($Area)) { Start-AzlRedfishArea -Context $Context -Name $Area; $Context.CurrentArea = $null }
    $Context.Areas[$Area].Notes.Add((Hide-AzlRedfishSecretText -Text $Text -Context $Context))
}

function Skip-AzlRedfishArea {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Reason)
    Start-AzlRedfishArea -Context $Context -Name $Name
    Stop-AzlRedfishArea -Context $Context -Status skipped -Reason $Reason
}

function Add-AzlRedfishOemPath {
    <#
    .SYNOPSIS
        Registers a vendor (OEM) path an adapter used, with how well it is established. Shown in the capability report.
    .PARAMETER Basis
        lab-observed (seen on real hardware), documented (in the vendor's Redfish guide, not seen on hardware here) or
        inferred (not documented where it was read; needs hardware verification).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('lab-observed', 'documented', 'inferred')][string]$Basis,
        [Parameter(Mandatory)][string]$Source,
        [string]$Status = 'ok'
    )
    $Context.OemPaths.Add([ordered]@{ area = $Area; path = $Path; basis = $Basis; source = $Source; status = $Status })
}

function Get-AzlRfCapabilityReport {
    param($Context, $Adapter, [string]$Detail)
    $areas = [ordered]@{}
    foreach ($name in $Context.Areas.Keys) {
        $a = $Context.Areas[$name]
        $paths = @($a.Paths)
        if ($a.MorePaths -gt 0) { $paths += "... and $($a.MorePaths) more" }
        $areas[$name] = [ordered]@{ status = $a.Status; paths = $paths; schemaVariant = $a.Variant; count = $a.Count; reason = $a.Reason; notes = @($a.Notes) }
    }
    $statuses = @($areas.Values | ForEach-Object { $_.status })
    $unproven = @($Context.OemPaths | Where-Object { $_.basis -eq 'inferred' } | ForEach-Object { "$($_.area): $($_.path)" })
    return [ordered]@{
        vendorAdapter = $(if ($Adapter) { $Adapter.Vendor.ToLowerInvariant() } else { 'none' })
        detail        = $Detail.ToLowerInvariant()
        requestCount  = $Context.RequestCount
        areas         = $areas
        oemPaths      = @($Context.OemPaths)
        summary       = [ordered]@{
            ok = @($statuses | Where-Object { $_ -eq 'ok' }).Count; partial = @($statuses | Where-Object { $_ -eq 'partial' }).Count
            notSupported = @($statuses | Where-Object { $_ -eq 'notSupported' }).Count; denied = @($statuses | Where-Object { $_ -eq 'denied' }).Count
            error = @($statuses | Where-Object { $_ -eq 'error' }).Count; skipped = @($statuses | Where-Object { $_ -eq 'skipped' }).Count
        }
        complete      = (@($statuses | Where-Object { $_ -in 'partial', 'denied', 'error' }).Count -eq 0)
        needsHardwareVerification = $unproven
    }
}

#endregion

#region vendor detection

function Resolve-AzlRedfishVendor {
    <#
    .SYNOPSIS
        Which vendor and BMC family this is, from the service root, the system and the manager, with the evidence.
    .DESCRIPTION
        Order: Oem namespaces (high confidence), the ServiceRoot Vendor property, Manufacturer and Model strings, then the
        manager text (iDRAC, iLO, XClarity, iRMC, CIMC). OEM re-badged boxes (DataON and others) often carry an ODM BMC, so
        the Oem namespace wins over Manufacturer. Name is Unknown when nothing matches. Supported is true for the vendors
        this version has an adapter for (Dell).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($ServiceRoot, $System, $Manager)
    $evidence = [System.Collections.Generic.List[string]]::new()
    $oemMap = [ordered]@{ '^Dell' = 'Dell'; '^(Hpe|Hp)$' = 'Hpe'; '^Lenovo' = 'Lenovo'; '^(Supermicro|Smc)' = 'Supermicro'; '^ts_fujitsu|^Fujitsu' = 'Fujitsu'; '^Cisco' = 'Cisco'; '^Ami$|^AMI' = 'Ami' }
    $textMap = [ordered]@{ 'Dell' = 'Dell'; 'HPE|Hewlett' = 'Hpe'; 'Lenovo' = 'Lenovo'; 'Super\s?micro' = 'Supermicro'; 'Fujitsu' = 'Fujitsu'; 'Cisco' = 'Cisco'; 'DataON' = 'DataON'; 'American Megatrends|^AMI$' = 'Ami' }
    $name = $null
    $confidence = 'none'
    foreach ($source in @(@('ServiceRoot', $ServiceRoot), @('System', $System), @('Manager', $Manager))) {
        $oem = Get-RfProp $source[1] 'Oem'
        if ($null -eq $oem) { continue }
        $keys = if ($oem -is [System.Collections.IDictionary]) { @($oem.Keys) } else { @($oem.PSObject.Properties.Name) }
        foreach ($k in $keys) {
            foreach ($pattern in $oemMap.Keys) {
                if ($k -match $pattern) { $evidence.Add("$($source[0]) Oem namespace '$k'"); if (-not $name) { $name = $oemMap[$pattern]; $confidence = 'high' } }
            }
        }
    }
    $strings = @(
        @('ServiceRoot Vendor', (Get-RfText $ServiceRoot 'Vendor')), @('System Manufacturer', (Get-RfText $System 'Manufacturer')),
        @('Manager Model', (Get-RfText $Manager 'Model')), @('Manager Name', (Get-RfText $Manager 'Name')), @('ServiceRoot Product', (Get-RfText $ServiceRoot 'Product'))
    )
    foreach ($s in $strings) {
        if (-not $s[1]) { continue }
        foreach ($pattern in $textMap.Keys) {
            if ($s[1] -match $pattern) { $evidence.Add("$($s[0]) '$($s[1])'"); if (-not $name) { $name = $textMap[$pattern]; $confidence = $(if ($s[0] -eq 'System Manufacturer') { 'medium' } else { 'low' }) } }
        }
    }
    $managerText = "$(Get-RfText $Manager 'Model') $(Get-RfText $Manager 'Name') $(Get-RfText $ServiceRoot 'Product')"
    $bmcMap = [ordered]@{ 'iDRAC|Integrated Dell Remote' = 'Dell'; 'iLO' = 'Hpe'; 'XClarity|XCC' = 'Lenovo'; 'iRMC' = 'Fujitsu'; 'CIMC' = 'Cisco' }
    foreach ($pattern in $bmcMap.Keys) {
        if ($managerText -cmatch $pattern) { $evidence.Add("BMC text matches '$pattern'"); if (-not $name) { $name = $bmcMap[$pattern]; $confidence = 'low' } elseif ($name -eq $bmcMap[$pattern] -and $confidence -eq 'low') { $confidence = 'medium' } }
    }
    if (-not $name) { $name = 'Unknown' }
    $family = 'generic'
    $generation = $null
    $firmware = Get-RfText $Manager 'FirmwareVersion'
    if ($name -eq 'Dell') {
        $g = [regex]::Match("$(Get-RfText $Manager 'Model')", '^(?<n>\d+)G')
        if ($g.Success) { $generation = "$($g.Groups['n'].Value)G" }
        $family = 'idrac'
        if ($generation) {
            $n = [int]$g.Groups['n'].Value
            $family = if ($n -ge 17) { 'idrac10' } elseif ($n -ge 14) { 'idrac9' } elseif ($n -eq 13) { 'idrac8' } else { 'idrac' }
        }
        elseif ($firmware -match '^(?<m>\d+)\.') {
            $family = switch ([int]$Matches['m']) { { $_ -ge 3 -and $_ -le 7 } { 'idrac9' } 2 { 'idrac8' } 1 { 'idrac10' } default { 'idrac' } }
        }
    }
    elseif ($name -eq 'Hpe') { $family = if ($firmware -match 'iLO\s*6|^3\.') { 'ilo6' } else { 'ilo5' } }
    elseif ($name -eq 'Lenovo') { $family = 'xcc' }
    elseif ($name -eq 'Fujitsu') { $family = 'irmc' }
    elseif ($name -eq 'Cisco') { $family = 'cimc' }
    elseif ($name -in 'Supermicro', 'Ami', 'DataON') { $family = 'ami' }
    return [pscustomobject]@{
        Name = $name; Family = $family; Generation = $generation; Confidence = $confidence; Evidence = @($evidence)
        Supported = ($name -in $script:SupportedVendors)
    }
}

function Get-AzlRedfishAdapter {
    <#
    .SYNOPSIS
        The adapter for a vendor: a Get-AzlRedfish<Vendor>Adapter command from AzlRedfish<Vendor>.psm1 next to this module.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Vendor)
    $command = "Get-AzlRedfish${Vendor}Adapter"
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        $file = [System.IO.Path]::Combine($PSScriptRoot, "AzlRedfish$Vendor.psm1")
        if (-not (Test-Path -LiteralPath $file)) { return $null }
        Import-Module $file -Force -Global
    }
    return (& $command)
}

#endregion

#region standard collectors

function Invoke-RfHook {
    # Runs one optional adapter hook; a hook that throws is recorded as a read error and never stops the run.
    param($Context, $Adapter, [string]$Hook, $Report, $Paths, [string]$Detail)
    if (-not $Adapter) { return }
    $block = Get-RfProp (Get-RfProp $Adapter 'Hooks') $Hook
    if ($null -eq $block) { return }
    try { & $block $Context $Report $Paths $Detail }
    catch {
        $Context.ReadErrors.Add([ordered]@{ area = $Context.CurrentArea; path = "adapter hook $Hook"; status = 0; kind = 'error'; message = (Hide-AzlRedfishSecretText -Text $_.Exception.Message -Context $Context); retried = $false })
        if ($Context.CurrentArea -and $Context.Areas.Contains($Context.CurrentArea)) { $Context.Areas[$Context.CurrentArea].Failures.Add('error') }
    }
}

function Get-RfCollectionPath {
    # The first path that is linked by a property of the given resources.
    param([object[]]$From, [string[]]$Name)
    foreach ($f in $From) { foreach ($n in $Name) { $l = Get-RfLink $f $n; if ($l) { return $l } } }
    return $null
}

function Resolve-AzlRfPath {
    # The system, chassis and manager to read: the first member linked from the service root, preferring the system's own links.
    param($Context, $Root, $Fallback)
    $paths = @{ System = $null; Chassis = $null; Manager = $null }
    $systems = @(); $link = Get-RfLink $Root 'Systems'
    if ($link) {
        $collection = Read-AzlRedfishResource -Context $Context -Path $link
        if ($null -eq $collection -and -not $Fallback) {
            $why = $Context.ReadErrors | Select-Object -Last 1
            throw "The system collection $link of $($Context.BmcAddress) could not be read: $($why.kind) (HTTP $($why.status)) $($why.message)"
        }
        $systems = @(Get-RfLinkList (Get-RfProp $collection 'Members'))
    }
    $paths.System = $systems | Select-Object -First 1
    if (-not $paths.System -and $Fallback) { $paths.System = $Fallback.System }
    if (-not $paths.System) { return $null }
    $sysBody = Read-AzlRedfishResource -Context $Context -Path $paths.System
    $chassis = @(Get-RfLinkList (Get-RfProp (Get-RfProp $sysBody 'Links') 'Chassis'))
    if ($chassis.Count -eq 0) { $c = Get-RfLink $Root 'Chassis'; if ($c) { $chassis = @((Read-AzlRedfishResource -Context $Context -Path $c) | ForEach-Object { Get-RfLinkList (Get-RfProp $_ 'Members') } | ForEach-Object { $_ }) } }
    $paths.Chassis = $chassis | Select-Object -First 1
    if (-not $paths.Chassis -and $Fallback) { $paths.Chassis = $Fallback.Chassis }
    $managers = @(Get-RfLinkList (Get-RfProp (Get-RfProp $sysBody 'Links') 'ManagedBy'))
    if ($managers.Count -eq 0) { $m = Get-RfLink $Root 'Managers'; if ($m) { $managers = @((Read-AzlRedfishResource -Context $Context -Path $m) | ForEach-Object { Get-RfLinkList (Get-RfProp $_ 'Members') } | ForEach-Object { $_ }) } }
    $paths.Manager = $managers | Select-Object -First 1
    if (-not $paths.Manager -and $Fallback) { $paths.Manager = $Fallback.Manager }
    $paths.SystemCount = $systems.Count
    return $paths
}

function Get-AzlRfIdentity {
    param($Sys, $Chassis)
    $serials = [System.Collections.Generic.List[object]]::new()
    $add = { param($v, $src) if ($v -and -not ($serials | Where-Object { $_.value -eq $v })) { $serials.Add([ordered]@{ value = $v; source = $src }) } }
    & $add (Get-RfText $Sys 'SKU') 'System.SKU'
    & $add (Get-RfText $Sys 'SerialNumber') 'System.SerialNumber'
    & $add (Get-RfText $Chassis 'SerialNumber') 'Chassis.SerialNumber'
    $rack = Get-RfProp (Get-RfProp (Get-RfProp $Chassis 'Location') 'Placement') 'RackOffset'
    return [ordered]@{
        manufacturer = (Get-RfText $Sys 'Manufacturer'); model = (Get-RfText $Sys 'Model'); serialNumber = (Get-RfText $Sys 'SerialNumber')
        serviceTag = $null; skuOrPartNumber = $(if (Get-RfText $Sys 'SKU') { Get-RfText $Sys 'SKU' } else { Get-RfText $Sys 'PartNumber' })
        partNumber = (Get-RfText $Sys 'PartNumber'); uuid = (Get-RfText $Sys 'UUID'); assetTag = (Get-RfText $Sys 'AssetTag'); hostName = (Get-RfText $Sys 'HostName')
        powerState = (Get-RfText $Sys 'PowerState'); biosVersion = (Get-RfText $Sys 'BiosVersion')
        chassis = [ordered]@{ serialNumber = (Get-RfText $Chassis 'SerialNumber'); type = (Get-RfText $Chassis 'ChassisType'); model = (Get-RfText $Chassis 'Model'); assetTag = (Get-RfText $Chassis 'AssetTag'); rackUnit = $rack }
        voucherSerialCandidates = @($serials)
    }
}

function Get-AzlRfBmc {
    param($Context, $Manager, [string]$Detail)
    $interfaces = @(foreach ($e in (Get-AzlRedfishMember -Context $Context -Path (Get-RfLink $Manager 'EthernetInterfaces'))) {
            $v4 = @(foreach ($a in @(Get-RfProp $e 'IPv4Addresses' @())) { [ordered]@{ address = (Get-RfText $a 'Address'); subnetMask = (Get-RfText $a 'SubnetMask'); origin = (Get-RfText $a 'AddressOrigin'); gateway = (Get-RfText $a 'Gateway') } })
            [ordered]@{
                id = (Get-RfText $e 'Id'); name = (Get-RfText $e 'Name'); mac = (ConvertTo-AzlMacAddress ([string](Get-RfProp $e 'MACAddress' (Get-RfProp $e 'PermanentMACAddress' ''))))
                permanentMac = (ConvertTo-AzlMacAddress ([string](Get-RfProp $e 'PermanentMACAddress' ''))); ipv4 = $v4
                vlan = [ordered]@{ enabled = (Get-RfProp (Get-RfProp $e 'VLAN') 'VLANEnable'); id = (Get-RfProp (Get-RfProp $e 'VLAN') 'VLANId') }
                speedMbps = (Get-RfProp $e 'SpeedMbps'); linkStatus = (Get-RfText $e 'LinkStatus'); hostName = (Get-RfText $e 'HostName'); fqdn = (Get-RfText $e 'FQDN')
            }
        })
    $bmc = [ordered]@{
        managerId = (Get-RfText $Manager 'Id'); name = (Get-RfText $Manager 'Name'); model = (Get-RfText $Manager 'Model'); firmwareVersion = (Get-RfText $Manager 'FirmwareVersion')
        managerType = (Get-RfText $Manager 'ManagerType'); uuid = (Get-RfText $Manager 'UUID'); dateTime = (Get-RfText $Manager 'DateTime'); status = (Get-RfStatus $Manager)
        mac = (@($interfaces | Where-Object { $_.mac } | Select-Object -First 1) | ForEach-Object { $_.mac }); interfaces = $interfaces
        protocols = $null; certificates = @(); licenses = @()
    }
    if ($Detail -eq 'Full') {
        $np = Read-AzlRedfishResource -Context $Context -Path (Get-RfLink $Manager 'NetworkProtocol')
        if ($np) {
            $protocols = [ordered]@{}
            foreach ($p in $np.PSObject.Properties) {
                if ($p.Value -is [pscustomobject] -and $p.Value.PSObject.Properties['ProtocolEnabled']) { $protocols[$p.Name] = [ordered]@{ enabled = $p.Value.ProtocolEnabled; port = (Get-RfProp $p.Value 'Port') } }
            }
            $bmc.protocols = $protocols
            $certLink = Get-RfLink (Get-RfProp $np 'HTTPS') 'Certificates'
            if ($certLink) {
                $bmc.certificates = @(foreach ($c in (Get-AzlRedfishMember -Context $Context -Path $certLink)) {
                        [ordered]@{ id = (Get-RfText $c 'Id'); subject = (Get-RfText (Get-RfProp $c 'Subject') 'CommonName'); issuer = (Get-RfText (Get-RfProp $c 'Issuer') 'CommonName'); validNotBefore = (Get-RfText $c 'ValidNotBefore'); validNotAfter = (Get-RfText $c 'ValidNotAfter') }
                    })
            }
        }
    }
    return $bmc
}

function Get-AzlRfSystem {
    param($Context, $Sys, [string]$Detail)
    $boot = Get-RfProp $Sys 'Boot'
    $tpm = @(foreach ($m in @(Get-RfProp $Sys 'TrustedModules' @())) {
            [ordered]@{ interfaceType = (Get-RfText $m 'InterfaceType'); state = (Get-RfText (Get-RfProp $m 'Status') 'State'); firmwareVersion = (Get-RfText $m 'FirmwareVersion'); source = 'System.TrustedModules' }
        })
    # TrustedModules is deprecated since ComputerSystem 1.19 in favour of Links.TrustedComponents: read it when TrustedModules lists nothing.
    if (@($tpm).Count -eq 0 -and $Detail -ne 'Summary') {
        $tpm = @(foreach ($l in @(Get-RfLinkList (Get-RfProp (Get-RfProp $Sys 'Links') 'TrustedComponents'))) {
                $c = Read-AzlRedfishResource -Context $Context -Path $l
                if ($c) { [ordered]@{ interfaceType = $null; state = (Get-RfText (Get-RfProp $c 'Status') 'State'); firmwareVersion = (Get-RfText $c 'FirmwareVersion'); manufacturer = (Get-RfText $c 'Manufacturer'); model = (Get-RfText $c 'Model'); componentType = (Get-RfText $c 'TrustedComponentType'); source = 'Links.TrustedComponents' } }
            })
    }
    $secure = [ordered]@{ supported = $false; enabled = $null; currentBoot = $null; mode = $null }
    $sbLink = Get-RfLink $Sys 'SecureBoot'
    if ($sbLink -and $Detail -ne 'Summary') {
        $sb = Read-AzlRedfishResource -Context $Context -Path $sbLink
        if ($sb) { $secure = [ordered]@{ supported = $true; enabled = (Get-RfProp $sb 'SecureBootEnable'); currentBoot = (Get-RfText $sb 'SecureBootCurrentBoot'); mode = (Get-RfText $sb 'SecureBootMode') } }
    }
    $ps = Get-RfProp $Sys 'ProcessorSummary'
    $ms = Get-RfProp $Sys 'MemorySummary'
    return [ordered]@{
        biosVersion = (Get-RfText $Sys 'BiosVersion'); bootMode = (Get-RfText $boot 'BootSourceOverrideMode')
        boot = [ordered]@{ overrideEnabled = (Get-RfText $boot 'BootSourceOverrideEnabled'); overrideTarget = (Get-RfText $boot 'BootSourceOverrideTarget'); order = @(Get-RfProp $boot 'BootOrder' @()) }
        secureBoot = $secure; tpm = $tpm
        virtualization = [ordered]@{ vtx = $null; sriov = $null; iommu = $null; source = $null }
        processorSummary = [ordered]@{ count = (Get-RfProp $ps 'Count'); model = (Get-RfText $ps 'Model'); cores = (Get-RfProp $ps 'CoreCount'); threads = (Get-RfProp $ps 'LogicalProcessorCount') }
        health = (Get-RfStatus $Sys); status = (Get-RfText (Get-RfProp $Sys 'Status') 'State'); powerState = (Get-RfText $Sys 'PowerState')
        indicatorLed = (Get-RfText $Sys 'IndicatorLED'); memoryTotalGiB = (Get-RfProp $ms 'TotalSystemMemoryGiB')
    }
}

function Get-AzlRfProcessor {
    param($Context, $Sys)
    $link = Get-RfLink $Sys 'Processors'
    if (-not $link) { return , @() }
    return , @(foreach ($p in (Get-AzlRedfishMember -Context $Context -Path $link)) {
            $id = Get-RfProp $p 'ProcessorId'
            [ordered]@{
                id = (Get-RfText $p 'Id'); socket = (Get-RfText $p 'Socket'); name = (Get-RfText $p 'Name'); model = (Get-RfText $p 'Model'); manufacturer = (Get-RfText $p 'Manufacturer')
                processorType = (Get-RfText $p 'ProcessorType'); architecture = $(if (Get-RfText $p 'ProcessorArchitecture') { Get-RfText $p 'ProcessorArchitecture' } else { Get-RfText $p 'InstructionSet' })
                cores = (Get-RfProp $p 'TotalCores'); threads = (Get-RfProp $p 'TotalThreads'); maxSpeedMHz = (Get-RfProp $p 'MaxSpeedMHz'); microcodeVersion = (Get-RfText $id 'MicrocodeInfo')
                serialNumber = (Get-RfText $p 'SerialNumber'); partNumber = (Get-RfText $p 'PartNumber'); health = (Get-RfStatus $p)
                memoryMiB = $($mem = @(Get-RfProp $p 'ProcessorMemory' @() | ForEach-Object { Get-RfProp $_ 'CapacityMiB' } | Where-Object { $null -ne $_ }); if ($mem.Count -gt 0) { ($mem | Measure-Object -Sum).Sum } else { $null })
            }
        })
}

function Get-AzlRfMemory {
    param($Context, $Sys, $Summary)
    $modules = @()
    $link = Get-RfLink $Sys 'Memory'
    if ($link) {
        $modules = @(foreach ($m in (Get-AzlRedfishMember -Context $Context -Path $link)) {
                $loc = Get-RfProp $m 'MemoryLocation'
                $state = Get-RfText (Get-RfProp $m 'Status') 'State'
                [ordered]@{
                    id = (Get-RfText $m 'Id'); slot = $(if (Get-RfText $m 'DeviceLocator') { Get-RfText $m 'DeviceLocator' } else { Get-RfText $m 'Name' })
                    location = [ordered]@{ socket = (Get-RfProp $loc 'Socket'); memoryController = (Get-RfProp $loc 'MemoryController'); channel = (Get-RfProp $loc 'Channel'); slot = (Get-RfProp $loc 'Slot') }
                    capacityMiB = (Get-RfProp $m 'CapacityMiB'); type = (Get-RfText $m 'MemoryDeviceType'); baseModuleType = (Get-RfText $m 'BaseModuleType'); speedMHz = (Get-RfProp $m 'OperatingSpeedMhz')
                    manufacturer = (Get-RfText $m 'Manufacturer'); partNumber = (Get-RfText $m 'PartNumber'); serialNumber = (Get-RfText $m 'SerialNumber')
                    ecc = (Get-RfText $m 'ErrorCorrection'); rank = (Get-RfProp $m 'RankCount'); health = (Get-RfStatus $m); present = ($state -ne 'Absent')
                }
            })
    }
    return [ordered]@{ totalGiB = $Summary; modules = $modules }
}

function Get-AzlRfPcieDevice {
    # PCIe device paths: the Chassis collection first (where Dell iDRAC9 has it), then the Systems collection. The first source that
    # lists a device wins and is recorded; a source that answers 404 is not an error while another one works.
    param($Context, $Paths, $Sys, $Chassis)
    $sources = @(
        [pscustomobject]@{ Variant = 'Chassis/PCIeDevices'; Collections = @((Get-RfLink $Chassis 'PCIeDevices')); Direct = @(Get-RfLinkList (Get-RfProp (Get-RfProp $Chassis 'Links') 'PCIeDevices')); WellKnown = $(if ($Paths.Chassis) { "$($Paths.Chassis)/PCIeDevices" } else { $null }) }
        [pscustomobject]@{ Variant = 'Systems/PCIeDevices'; Collections = @((Get-RfLink $Sys 'PCIeDevices')); Direct = @(Get-RfLinkList (Get-RfProp (Get-RfProp $Sys 'Links') 'PCIeDevices')) + @(Get-RfLinkList (Get-RfProp $Sys 'PCIeDevices')); WellKnown = "$($Paths.System)/PCIeDevices" }
    )
    $failed = [System.Collections.Generic.List[object]]::new()
    foreach ($src in $sources) {
        $links = [System.Collections.Generic.List[string]]::new()
        $tried = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($c in @($src.Collections) + @($src.WellKnown)) {
            if (-not $c -or -not $tried.Add($c)) { continue }
            $r = Invoke-AzlRedfishRequest -Context $Context -Path $c
            if ($r.Ok) { foreach ($l in @(Get-RfLinkList (Get-RfProp $r.Body 'Members'))) { if (-not $links.Contains($l)) { $links.Add($l) } } }
            else { $failed.Add($r) }
            if ($links.Count -gt 0) { break }
        }
        if ($links.Count -eq 0) { foreach ($l in @($src.Direct)) { if ($l -and -not $links.Contains($l)) { $links.Add($l) } } }
        if ($links.Count -gt 0) { return [pscustomobject]@{ Variant = $src.Variant; Links = $links.ToArray() } }
    }
    foreach ($f in $failed) { Register-AzlRedfishFailure -Context $Context -Result $f }
    return [pscustomobject]@{ Variant = $null; Links = @() }
}

function Get-AzlRfPcie {
    param($Context, $Paths, $Sys, $Chassis)
    $found = Get-AzlRfPcieDevice -Context $Context -Paths $Paths -Sys $Sys -Chassis $Chassis
    # Functions listed on the system (PCIeFunctions) can be matched to a device by Links.PCIeDevice.
    $systemFunctions = $null
    $devices = @()
    foreach ($l in $found.Links) {
        $d = Read-AzlRedfishResource -Context $Context -Path $l
        if ($null -eq $d) { continue }
        $fnLinks = @(Get-RfLinkList (Get-RfProp (Get-RfProp $d 'Links') 'PCIeFunctions'))
        $fnCollection = Get-RfLink $d 'PCIeFunctions'
        $functions = @()
        if ($fnLinks.Count -gt 0) { $functions = @(foreach ($f in $fnLinks) { Read-AzlRedfishResource -Context $Context -Path $f }) | Where-Object { $_ } }
        elseif ($fnCollection) { $functions = @(Get-AzlRedfishMember -Context $Context -Path $fnCollection) }
        else {
            if ($null -eq $systemFunctions) {
                $sfLink = Get-RfLink $Sys 'PCIeFunctions'
                $systemFunctions = if ($sfLink) { @(Get-AzlRedfishMember -Context $Context -Path $sfLink -Probe) } else { @() }
            }
            $functions = @($systemFunctions | Where-Object { (Get-RfLink (Get-RfProp $_ 'Links') 'PCIeDevice') -eq $l })
        }
        $iface = Get-RfProp $d 'PCIeInterface'
        $fn = @(foreach ($f in $functions) {
                [ordered]@{ id = (Get-RfText $f 'Id'); name = (Get-RfText $f 'Name'); deviceId = (Get-RfText $f 'DeviceId'); vendorId = (Get-RfText $f 'VendorId'); subsystemId = (Get-RfText $f 'SubsystemId')
                    subsystemVendorId = (Get-RfText $f 'SubsystemVendorId'); classCode = (Get-RfText $f 'ClassCode'); deviceClass = (Get-RfText $f 'DeviceClass'); functionType = (Get-RfText $f 'FunctionType'); health = (Get-RfStatus $f) }
            })
        $devices += , ([ordered]@{
                id = (Get-RfText $d 'Id'); path = $l; slot = (Get-RfText (Get-RfProp (Get-RfProp (Get-RfProp $d 'Slot') 'Location') 'PartLocation') 'ServiceLabel'); name = (Get-RfText $d 'Name'); description = (Get-RfText $d 'Description')
                manufacturer = (Get-RfText $d 'Manufacturer'); model = (Get-RfText $d 'Model'); partNumber = (Get-RfText $d 'PartNumber'); serialNumber = (Get-RfText $d 'SerialNumber'); firmwareVersion = (Get-RfText $d 'FirmwareVersion')
                deviceType = (Get-RfText $d 'DeviceType'); lanesInUse = (Get-RfProp $iface 'LanesInUse'); maxLanes = (Get-RfProp $iface 'MaxLanes'); generation = (Get-RfText $iface 'PCIeType'); maxGeneration = (Get-RfText $iface 'MaxPCIeType')
                health = (Get-RfStatus $d); functions = $fn
            })
    }
    $gpus = @(foreach ($d in $devices) {
            $isGpu = (@($d.functions | Where-Object { $_.deviceClass -eq 'DisplayController' -or $_.classCode -match '^0x03' }).Count -gt 0) -or ("$($d.name) $($d.description) $($d.model)" -match '(?i)\bGPU\b|\bNVIDIA\b|Instinct|Accelerator')
            if ($isGpu) { [ordered]@{ id = $d.id; name = $d.name; model = $(if ($d.model) { $d.model } else { $d.description }); manufacturer = $d.manufacturer; slot = $d.slot; memoryGiB = $null; vendorId = (@($d.functions | ForEach-Object { $_.vendorId }) | Where-Object { $_ } | Select-Object -First 1); firmwareVersion = $d.firmwareVersion } }
        })
    return [pscustomobject]@{ devices = $devices; gpus = $gpus; Variant = $found.Variant }
}
function Test-RfGenericLabel {
    # True when a text is empty, a bare adapter id or another label that names no hardware model. The vendor adapter adds its own.
    param([string]$Text, $AdapterDef)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    if ($Text.Trim() -match '^[A-Za-z]+\.[A-Za-z]+\.\d+(-\d+)*$') { return $true }
    $vendorTest = Get-RfProp $AdapterDef 'IsGenericModel'
    if ($vendorTest) { return [bool](& $vendorTest $Text) }
    return $false
}

function Get-AzlRfNicModel {
    # The adapter model, first source that gives a real model wins: the adapter's own Model, a vendor hint (Dell NIC product name),
    # the controller entries, the linked PCIe device (Model, then Description), the adapter Name. A generic label ('Network Adapter
    # View', 'NIC in Slot 3', a bare id) is never a model: it is listed in Rejected and the model stays empty if nothing else names the card.
    param($Context, $Adapter, $Controllers, $Functions, $AdapterDef)
    $rejected = [System.Collections.Generic.List[string]]::new()
    $try = {
        param([string]$text, [string]$source)
        $t = if ($text) { $text.Trim() } else { '' }
        if (-not (Test-RfGenericLabel -Text $t -AdapterDef $AdapterDef)) { return [pscustomobject]@{ Model = $t; Source = $source; Rejected = @($rejected) } }
        if ($t -and -not $rejected.Contains($t)) { $rejected.Add($t) }
        return $null
    }
    $hit = & $try (Get-RfText $Adapter 'Model') 'adapter'
    if ($hit) { return $hit }
    $hint = Get-RfProp (Get-RfProp $AdapterDef 'Hooks') 'NicModelHint'
    if ($hint) {
        $h = & $hint $Context $Functions
        if ($h) { $hit = & $try ([string]$h.Model) ([string]$h.Source); if ($hit) { return $hit } }
    }
    foreach ($c in @($Controllers)) {
        foreach ($n in 'Model', 'Description') { $hit = & $try (Get-RfText $c $n) 'controller'; if ($hit) { return $hit } }
    }
    foreach ($c in @($Controllers)) {
        foreach ($l in @(Get-RfLinkList (Get-RfProp (Get-RfProp $c 'Links') 'PCIeDevices'))) {
            $d = Read-AzlRedfishResource -Context $Context -Path $l
            $hit = & $try (Get-RfText $d 'Model') 'pcie-device-model'
            if ($hit) { return $hit }
            if ((Get-RfText $d 'Description') -ne (Get-RfText $d 'Name')) { $hit = & $try (Get-RfText $d 'Description') 'pcie-device-description'; if ($hit) { return $hit } }
        }
    }
    $hit = & $try (Get-RfText $Adapter 'Name') 'adapter-name'
    if ($hit) { return $hit }
    return [pscustomobject]@{ Model = $null; Source = 'none'; Rejected = @($rejected) }
}
function Get-AzlRfNetwork {
    param($Context, $Sys, $Chassis, $AdapterDef, [string]$Detail)
    $adaptersPath = Get-RfLink $Sys 'NetworkAdapters'
    $origin = 'Systems'
    if (-not $adaptersPath) { $adaptersPath = Get-RfLink $Chassis 'NetworkAdapters'; $origin = 'Chassis' }
    $result = [ordered]@{ adapters = @(); hostInterfaces = @() }
    if (-not $adaptersPath) { return [pscustomobject]@{ Network = $result; Variant = $null; Count = 0; Warnings = @() } }
    $variants = [System.Collections.Generic.HashSet[string]]::new()
    $variants.Add("NetworkAdapters@$origin") | Out-Null
    $warnings = [System.Collections.Generic.List[string]]::new()
    $adapters = [System.Collections.Generic.List[object]]::new()
    foreach ($adapter in (Get-AzlRedfishMember -Context $Context -Path $adaptersPath)) {
        $adapterId = Get-RfText $adapter 'Id'
        $controller = @(Get-RfProp $adapter 'Controllers' @()) | Select-Object -First 1
        $portsPath = Get-RfLink $adapter 'Ports'
        $portVariant = 'Ports'
        if (-not $portsPath) { $portsPath = Get-RfLink $adapter 'NetworkPorts'; $portVariant = 'NetworkPorts' }
        $ports = @()
        if ($portsPath) { $ports = @(Get-AzlRedfishMember -Context $Context -Path $portsPath); $variants.Add($portVariant) | Out-Null }
        else {
            $linked = @(Get-RfLinkList (Get-RfProp (Get-RfProp $controller 'Links') 'Ports')) + @(Get-RfLinkList (Get-RfProp (Get-RfProp $controller 'Links') 'NetworkPorts'))
            if ($linked.Count -gt 0) { $ports = @($linked | ForEach-Object { Read-AzlRedfishResource -Context $Context -Path $_ } | Where-Object { $_ }); $variants.Add('Ports') | Out-Null }
        }
        $fnPath = Get-RfLink $adapter 'NetworkDeviceFunctions'
        $functions = if ($fnPath) { @(Get-AzlRedfishMember -Context $Context -Path $fnPath) } else { @() }
        $portsFromFunctions = $false
        if ($ports.Count -eq 0 -and $functions.Count -gt 0) {
            # Some firmware lists only functions (one per port): the port is built from the function.
            $ports = @($functions | ForEach-Object { [pscustomobject]@{ Id = (Get-RfProp $_ 'Id'); PhysicalPortNumber = $null; FromFunction = $true } })
            $portsFromFunctions = $true
            $variants.Add('functions-only') | Out-Null
        }
        $modelInfo = Get-AzlRfNicModel -Context $Context -Adapter $adapter -Controllers @(Get-RfProp $adapter 'Controllers' @()) -Functions $functions -AdapterDef $AdapterDef
        $labeler = Get-RfProp $AdapterDef 'PortLabel'
        $portList = [System.Collections.Generic.List[object]]::new()
        $ordinal = 0
        foreach ($port in $ports) {
            $ordinal++
            $portId = Get-RfText $port 'Id'
            $function = @($functions | Where-Object {
                    $assoc = @(Get-RfLinkList (Get-RfProp $_ 'AssociatedNetworkPorts')) + @(Get-RfLinkList (Get-RfProp (Get-RfProp $_ 'Links') 'Ports'))
                    $fid = [string](Get-RfProp $_ 'Id' '')
                    ($portId -and ($fid -eq $portId -or $fid -like "$portId-*")) -or ($assoc | Where-Object { $_ -and $_.EndsWith("/$portId") })
                }) | Select-Object -First 1
            if (-not $function -and $ports.Count -eq 1 -and $functions.Count -eq 1) { $function = $functions[0] }
            $eth = Get-RfProp $function 'Ethernet'
            $portEth = Get-RfProp $port 'Ethernet'
            $mac = $null; $macSource = $null
            foreach ($candidate in @(Get-RfProp $port 'AssociatedNetworkAddresses' @()) + @(Get-RfProp $portEth 'AssociatedMACAddresses' @()) + @(Get-RfProp $port 'MACAddress')) {
                $m = ConvertTo-AzlMacAddress ([string]$candidate)
                if ($m) { $mac = $m; $macSource = 'Port'; break }
            }
            if (-not $mac) {
                foreach ($n in 'MACAddress', 'PermanentMACAddress') { $m = ConvertTo-AzlMacAddress ([string](Get-RfProp $eth $n '')); if ($m) { $mac = $m; $macSource = 'Function'; break } }
            }
            $permanent = ConvertTo-AzlMacAddress ([string](Get-RfProp $eth 'PermanentMACAddress' ''))
            $physical = Get-RfText $port 'PhysicalPortNumber'
            $label = if ($labeler) { & $labeler $adapter $port $ordinal } else { $null }
            if (-not $label) { $label = [pscustomobject]@{ Name = "$adapterId Port $(if ($physical) { $physical } else { $ordinal })"; Slot = $adapterId; PortNumber = $physical } }
            $link = Get-RfText $port 'LinkStatus'
            $speed = Get-RfProp $port 'CurrentLinkSpeedMbps'
            if ($null -eq $speed -and $null -ne (Get-RfProp $port 'CurrentSpeedGbps')) { $speed = [int]([double](Get-RfProp $port 'CurrentSpeedGbps') * 1000) }
            $maxSpeed = Get-RfProp $port 'MaxSpeedMbps'
            if ($null -eq $maxSpeed -and $null -ne (Get-RfProp $port 'MaxSpeedGbps')) { $maxSpeed = [int]([double](Get-RfProp $port 'MaxSpeedGbps') * 1000) }
            if ($null -eq $maxSpeed) { $caps = @(Get-RfProp $port 'SupportedLinkCapabilities' @() | ForEach-Object { Get-RfProp $_ 'LinkSpeedMbps' } | Where-Object { $null -ne $_ }); if ($caps.Count -gt 0) { $maxSpeed = ($caps | Measure-Object -Maximum).Maximum } }
            $lldp = Get-RfProp $portEth 'LLDPReceive'
            if (-not $mac) { $warnings.Add("NetworkAdapters: port $portId of $adapterId has no MAC in Redfish.") }
            # The hardware facts the file keeps per port (nodes[].network_adapters[]): the number of the port on the card, the PCI location and the RDMA capability.
            # The standard Redfish resources carry the port number. The PCI location and the RDMA capability are vendor data, so a vendor adapter gives them through the
            # optional hooks NicPciLocation and NicRdma (nothing here is specific to a brand; a hook that finds nothing leaves the value empty).
            $portNumberText = if ($label.PortNumber) { "$($label.PortNumber)" } elseif ($physical) { "$physical" } else { "$ordinal" }
            $portIndex = if ($portNumberText -match '^\d+$') { [int]$portNumberText } else { $ordinal }
            $pciHook = Get-RfProp (Get-RfProp $AdapterDef 'Hooks') 'NicPciLocation'
            $pciLocation = if ($pciHook) { & $pciHook $Context $function } else { $null }
            $rdmaHook = Get-RfProp (Get-RfProp $AdapterDef 'Hooks') 'NicRdma'
            $rdmaValue = if ($rdmaHook) { & $rdmaHook $Context $function $adapter } else { $null }
            $portList.Add([ordered]@{
                    id = $portId; name = $label.Name; slot = $label.Slot; portNumber = $(if ($label.PortNumber) { $label.PortNumber } else { $physical }); portIndex = $portIndex; adapterId = $adapterId
                    pciLocation = $pciLocation; rdma = $rdmaValue
                    mac = $mac; macSource = $macSource; permanentMac = $permanent; linkStatus = $link; linkUp = $(if ($link) { $link -in @('Up', 'LinkUp') } else { $null })
                    speedMbps = $speed; maxSpeedMbps = $maxSpeed; mtu = (Get-RfProp $eth 'MTUSize'); flowControl = (Get-RfText $port 'FlowControlStatus')
                    lldp = $(if ($lldp) { Remove-AzlRedfishSecret -InputObject $lldp } else { $null }); functionId = (Get-RfText $function 'Id'); deviceEnabled = (Get-RfProp $function 'DeviceEnabled')
                    builtFromFunction = $portsFromFunctions
                })
        }
        $adapters.Add([ordered]@{
                id = $adapterId; name = (Get-RfText $adapter 'Name'); manufacturer = (Get-RfText $adapter 'Manufacturer'); model = $modelInfo.Model; modelSource = $modelInfo.Source; modelRejected = @($modelInfo.Rejected)
                partNumber = (Get-RfText $adapter 'PartNumber'); serialNumber = (Get-RfText $adapter 'SerialNumber'); firmwarePackage = (Get-RfText $controller 'FirmwarePackageVersion')
                location = (Get-RfText (Get-RfProp (Get-RfProp $controller 'Location') 'PartLocation') 'ServiceLabel')
                ports = $portList.ToArray()
                functions = @(foreach ($f in $functions) {
                        $fe = Get-RfProp $f 'Ethernet'
                        [ordered]@{ id = (Get-RfText $f 'Id'); type = (Get-RfText $f 'NetDevFuncType'); deviceEnabled = (Get-RfProp $f 'DeviceEnabled'); mac = (ConvertTo-AzlMacAddress ([string](Get-RfProp $fe 'MACAddress' '')))
                            permanentMac = (ConvertTo-AzlMacAddress ([string](Get-RfProp $fe 'PermanentMACAddress' ''))); capabilities = @(Get-RfProp $f 'NetDevFuncCapabilities' @()); mtu = (Get-RfProp $fe 'MTUSize') }
                    })
                rdma = [ordered]@{ state = $null; protocol = $null; source = 'unknown' }
            })
    }
    # A port name is unique on a machine. A collision is kept distinguishable and reported.
    $seen = @{}
    foreach ($a in $adapters) {
        foreach ($p in $a.ports) {
            $key = ([string]$p.name).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { $seen[$key]++; $warnings.Add("NetworkAdapters: two ports are both named '$($p.name)'; the second is renamed."); $p.name = "$($p.name) ($($seen[$key]))" } else { $seen[$key] = 1 }
        }
    }
    $result.adapters = $adapters.ToArray()
    if ($Detail -eq 'Full') {
        $hostLink = Get-RfLink $Sys 'EthernetInterfaces'
        if ($hostLink) {
            $result.hostInterfaces = @(foreach ($e in (Get-AzlRedfishMember -Context $Context -Path $hostLink)) {
                    [ordered]@{ id = (Get-RfText $e 'Id'); mac = (ConvertTo-AzlMacAddress ([string](Get-RfProp $e 'MACAddress' ''))); permanentMac = (ConvertTo-AzlMacAddress ([string](Get-RfProp $e 'PermanentMACAddress' ''))); linkStatus = (Get-RfText $e 'LinkStatus'); speedMbps = (Get-RfProp $e 'SpeedMbps') }
                })
        }
    }
    $portCount = 0; foreach ($a in $adapters) { $portCount += @($a.ports).Count }
    return [pscustomobject]@{ Network = $result; Variant = (($variants | Sort-Object) -join ', '); Count = $portCount; Warnings = @($warnings) }
}

function Get-AzlRfStorage {
    param($Context, $Sys)
    $link = Get-RfLink $Sys 'Storage'
    $controllers = [System.Collections.Generic.List[object]]::new()
    if (-not $link) { return [ordered]@{ controllers = @(); drives = @(); volumes = @(); bootDevice = [ordered]@{ kind = $null; controllerId = $null; driveIds = @(); volumeId = $null; capacityGiB = $null; hasVirtualDisk = $false; needsVirtualDisk = $false; detection = 'not-evaluated' } } }
    foreach ($storage in (Get-AzlRedfishMember -Context $Context -Path $link)) {
        $id = Get-RfText $storage 'Id'
        $sc = @(Get-RfProp $storage 'StorageControllers' @()) | Select-Object -First 1
        if (-not $sc) {
            $ctlLink = Get-RfLink $storage 'Controllers'
            if ($ctlLink) { $sc = @(Get-AzlRedfishMember -Context $Context -Path $ctlLink) | Select-Object -First 1 }
        }
        $drives = @(foreach ($d in @(Get-RfProp $storage 'Drives' @())) {
                $dl = [string](Get-RfProp $d '@odata.id' '')
                if (-not $dl) { continue }
                $detail = Read-AzlRedfishResource -Context $Context -Path $dl
                if ($detail) {
                    $cap = Get-RfProp $detail 'CapacityBytes'
                    $loc = Get-RfProp (Get-RfProp $detail 'PhysicalLocation') 'PartLocation'
                    [ordered]@{
                        id = (Get-RfText $detail 'Id'); name = (Get-RfText $detail 'Name'); controllerId = $id; model = (Get-RfText $detail 'Model'); manufacturer = (Get-RfText $detail 'Manufacturer')
                        serialNumber = (Get-RfText $detail 'SerialNumber'); partNumber = (Get-RfText $detail 'PartNumber'); firmwareVersion = (Get-RfText $detail 'Revision')
                        capacityBytes = $cap; capacityGiB = (ConvertTo-RfGiB $cap); mediaType = (Get-RfText $detail 'MediaType'); protocol = (Get-RfText $detail 'Protocol'); blockSizeBytes = (Get-RfProp $detail 'BlockSizeBytes')
                        bay = (Get-RfText $loc 'ServiceLabel'); slot = (Get-RfProp $loc 'LocationOrdinalValue'); health = (Get-RfStatus $detail)
                        predictedLifeLeftPercent = (Get-RfProp $detail 'PredictedMediaLifeLeftPercent'); powerOnHours = $null; isBoot = $false
                    }
                }
            })
        $volLink = Get-RfLink $storage 'Volumes'
        $volumes = @(if ($volLink) {
                foreach ($v in (Get-AzlRedfishMember -Context $Context -Path $volLink)) {
                    $cap = Get-RfProp $v 'CapacityBytes'
                    [ordered]@{
                        id = (Get-RfText $v 'Id'); name = (Get-RfText $v 'Name'); controllerId = $id; raidType = (Get-RfText $v 'RAIDType'); volumeType = (Get-RfText $v 'VolumeType')
                        capacityBytes = $cap; capacityGiB = (ConvertTo-RfGiB $cap); driveIds = @(Get-RfLinkList (Get-RfProp (Get-RfProp $v 'Links') 'Drives') | ForEach-Object { ($_ -split '/')[-1] })
                        bootable = $null; health = (Get-RfStatus $v)
                    }
                }
            })
        $cache = Get-RfProp (Get-RfProp $storage 'CacheSummary') 'TotalCacheSizeMiB'
        $controllers.Add([ordered]@{
                id = $id; name = (Get-RfText $storage 'Name'); model = (Get-RfText $sc 'Model'); manufacturer = (Get-RfText $sc 'Manufacturer'); firmwareVersion = (Get-RfText $sc 'FirmwareVersion')
                supportedRaidTypes = @(Get-RfProp $sc 'SupportedRAIDTypes' @()); protocols = @(Get-RfProp $sc 'SupportedDeviceProtocols' @()); cacheMiB = $cache; health = (Get-RfStatus $storage)
                isBootController = $false; drives = $drives; volumes = $volumes
            })
    }
    $allDrives = @($controllers | ForEach-Object { $_.drives } | ForEach-Object { $_ })
    $allVolumes = @($controllers | ForEach-Object { $_.volumes } | ForEach-Object { $_ })
    return [ordered]@{
        controllers = $controllers.ToArray(); drives = $allDrives; volumes = $allVolumes
        bootDevice = [ordered]@{ kind = $null; controllerId = $null; driveIds = @(); volumeId = $null; capacityGiB = $null; hasVirtualDisk = $false; needsVirtualDisk = $false; detection = 'not-detected' }
    }
}

function Get-RfFirmwareCategory {
    param([string]$Text)
    switch -Regex ($Text) {
        '(?i)\bBIOS\b' { return 'bios' }
        '(?i)iDRAC|Remote Access|\bBMC\b|Lifecycle Controller|\biLO\b|XClarity' { return 'bmc' }
        '(?i)CPLD' { return 'cpld' }
        '(?i)Power Supply|\bPSU\b|PWR SPLY|^PS\d' { return 'psu' }
        '(?i)GPU|NVIDIA|Accelerator|Instinct' { return 'gpu' }
        '(?i)NIC|Ethernet|Mellanox|ConnectX|Broadcom|Intel.*Network|Adapter' { return 'nic' }
        '(?i)PERC|BOSS|RAID|HBA|Storage Controller|SAS|AHCI|NVMe Controller' { return 'storage' }
        '(?i)Disk|SSD|HDD|Drive|NVMe' { return 'drive' }
        default { return 'other' }
    }
}

function Get-AzlRfFirmware {
    param($Context, $Root)
    $us = Read-AzlRedfishResource -Context $Context -Path (Get-RfLink $Root 'UpdateService')
    $link = Get-RfLink $us 'FirmwareInventory'
    if (-not $link) { return $null }
    return , @(foreach ($f in (Get-AzlRedfishMember -Context $Context -Path $link)) {
            $name = Get-RfText $f 'Name'
            [ordered]@{
                component = $name; id = (Get-RfText $f 'Id'); version = (Get-RfText $f 'Version'); updateable = (Get-RfProp $f 'Updateable'); status = (Get-RfStatus $f)
                releaseDate = (Get-RfText $f 'ReleaseDate'); softwareId = (Get-RfText $f 'SoftwareId'); relatedItem = @(Get-RfLinkList (Get-RfProp $f 'RelatedItem'))
                category = (Get-RfFirmwareCategory "$name $(Get-RfText $f 'Id')"); source = 'UpdateService.FirmwareInventory'
            }
        })
}

function Get-AzlRfBiosSetting {
    param($Context, $Sys)
    $link = Get-RfLink $Sys 'Bios'
    if (-not $link) { return $null }
    $bios = Read-AzlRedfishResource -Context $Context -Path $link
    if (-not $bios) { return $null }
    $pending = $null
    $settingsPath = Get-RfProp (Get-RfProp (Get-RfProp $bios '@Redfish.Settings') 'SettingsObject') '@odata.id'
    if ($settingsPath) {
        $p = Read-AzlRedfishResource -Context $Context -Path ([string]$settingsPath)
        if ($p) { $pending = Remove-AzlRedfishSecret -InputObject (Get-RfProp $p 'Attributes') }
    }
    return [ordered]@{ attributes = (Remove-AzlRedfishSecret -InputObject (Get-RfProp $bios 'Attributes')); pendingAttributes = $pending; registryVersion = (Get-RfText $bios 'AttributeRegistry') }
}

function Get-AzlRfHealth {
    param($Context, $Sys, $Chassis)
    $sensors = [System.Collections.Generic.List[object]]::new()
    $power = $null
    $thermal = $null
    $variants = [System.Collections.Generic.List[string]]::new()
    $threshold = { param($t) $o = [ordered]@{}; if ($t) { foreach ($p in $t.PSObject.Properties) { $o[$p.Name] = (Get-RfProp $p.Value 'Reading') } }; $o }

    # Power: the newer PowerSubsystem, else the classic Power resource.
    $psLink = Get-RfLink $Chassis 'PowerSubsystem'
    if ($psLink) {
        $variants.Add('PowerSubsystem')
        $ps = Read-AzlRedfishResource -Context $Context -Path $psLink
        $supplyLink = Get-RfLink $ps 'PowerSupplies'
        $supplies = if ($supplyLink) { @(Get-AzlRedfishMember -Context $Context -Path $supplyLink) } else { @() }
        $power = [ordered]@{
            consumedWatts = (Get-RfProp (Get-RfProp $ps 'Allocation') 'AllocatedWatts'); capacityWatts = (Get-RfProp $ps 'CapacityWatts'); redundancy = @()
            supplies = @(foreach ($s in $supplies) { [ordered]@{ id = (Get-RfText $s 'Id'); name = (Get-RfText $s 'Name'); model = (Get-RfText $s 'Model'); serialNumber = (Get-RfText $s 'SerialNumber'); firmwareVersion = (Get-RfText $s 'FirmwareVersion'); capacityWatts = (Get-RfProp $s 'PowerCapacityWatts'); state = (Get-RfStatus $s) } })
        }
    }
    else {
        $pLink = Get-RfLink $Chassis 'Power'
        $p = if ($pLink) { Read-AzlRedfishResource -Context $Context -Path $pLink } else { $null }
        if ($p) {
            $variants.Add('Power')
            $pc = @(Get-RfProp $p 'PowerControl' @()) | Select-Object -First 1
            $power = [ordered]@{
                consumedWatts = (Get-RfProp $pc 'PowerConsumedWatts'); capacityWatts = (Get-RfProp $pc 'PowerCapacityWatts')
                redundancy = @(foreach ($r in @(Get-RfProp $p 'Redundancy' @())) { [ordered]@{ name = (Get-RfText $r 'Name'); mode = (Get-RfText $r 'Mode'); state = (Get-RfStatus $r) } })
                supplies = @(foreach ($s in @(Get-RfProp $p 'PowerSupplies' @())) { [ordered]@{ id = $null; name = (Get-RfText $s 'Name'); model = (Get-RfText $s 'Model'); serialNumber = (Get-RfText $s 'SerialNumber'); firmwareVersion = (Get-RfText $s 'FirmwareVersion'); capacityWatts = (Get-RfProp $s 'PowerCapacityWatts'); state = (Get-RfStatus $s) } })
            }
            foreach ($v in @(Get-RfProp $p 'Voltages' @())) { $sensors.Add([ordered]@{ name = (Get-RfText $v 'Name'); reading = (Get-RfProp $v 'ReadingVolts'); unit = 'V'; type = 'Voltage'; thresholds = [ordered]@{}; state = (Get-RfStatus $v) }) }
        }
    }
    # Thermal: ThermalSubsystem (fans, metrics), else the classic Thermal resource.
    $tsLink = Get-RfLink $Chassis 'ThermalSubsystem'
    if ($tsLink) {
        $variants.Add('ThermalSubsystem')
        $ts = Read-AzlRedfishResource -Context $Context -Path $tsLink
        $fanLink = Get-RfLink $ts 'Fans'
        $fans = if ($fanLink) { @(Get-AzlRedfishMember -Context $Context -Path $fanLink) } else { @() }
        $metricLink = Get-RfLink $ts 'ThermalMetrics'
        $metrics = if ($metricLink) { Read-AzlRedfishResource -Context $Context -Path $metricLink } else { $null }
        $thermal = [ordered]@{
            temperatures = @(foreach ($t in @(Get-RfProp $metrics 'TemperatureReadingsCelsius' @())) { [ordered]@{ name = (Get-RfText $t 'DeviceName'); readingCelsius = (Get-RfProp $t 'Reading') } })
            fans = @(foreach ($f in $fans) { [ordered]@{ name = (Get-RfText $f 'Name'); reading = (Get-RfProp (Get-RfProp $f 'SpeedPercent') 'SpeedRPM'); unit = 'RPM'; state = (Get-RfStatus $f) } })
        }
    }
    else {
        $tLink = Get-RfLink $Chassis 'Thermal'
        $t = if ($tLink) { Read-AzlRedfishResource -Context $Context -Path $tLink } else { $null }
        if ($t) {
            $variants.Add('Thermal')
            $thermal = [ordered]@{
                temperatures = @(foreach ($x in @(Get-RfProp $t 'Temperatures' @())) { [ordered]@{ name = (Get-RfText $x 'Name'); readingCelsius = (Get-RfProp $x 'ReadingCelsius'); upperCritical = (Get-RfProp $x 'UpperThresholdCritical'); upperNonCritical = (Get-RfProp $x 'UpperThresholdNonCritical'); state = (Get-RfStatus $x) } })
                fans = @(foreach ($f in @(Get-RfProp $t 'Fans' @())) { [ordered]@{ name = (Get-RfText $f 'Name'); reading = (Get-RfProp $f 'Reading'); unit = (Get-RfText $f 'ReadingUnits'); state = (Get-RfStatus $f) } })
            }
            foreach ($x in $thermal.temperatures) { $sensors.Add([ordered]@{ name = $x.name; reading = $x.readingCelsius; unit = 'Cel'; type = 'Temperature'; thresholds = [ordered]@{ upperCritical = $x.upperCritical; upperNonCritical = $x.upperNonCritical }; state = $x.state }) }
            foreach ($f in $thermal.fans) { $sensors.Add([ordered]@{ name = $f.name; reading = $f.reading; unit = $f.unit; type = 'Fan'; thresholds = [ordered]@{}; state = $f.state }) }
        }
    }
    # Sensors: the standard Sensors collection (newer schema).
    $senLink = Get-RfLink $Chassis 'Sensors'
    if ($senLink) {
        $found = @(Get-AzlRedfishMember -Context $Context -Path $senLink -Probe)
        if ($found.Count -gt 0) { $variants.Add('Sensors') }
        foreach ($s in $found) { $sensors.Add([ordered]@{ name = (Get-RfText $s 'Name'); reading = (Get-RfProp $s 'Reading'); unit = (Get-RfText $s 'ReadingUnits'); type = (Get-RfText $s 'ReadingType'); thresholds = (& $threshold (Get-RfProp $s 'Thresholds')); state = (Get-RfStatus $s) }) }
    }
    return [pscustomobject]@{
        Health = [ordered]@{
            sensors = $sensors.ToArray(); power = $power; thermal = $thermal
            leds = [ordered]@{ system = $(if (Get-RfText $Sys 'IndicatorLED') { Get-RfText $Sys 'IndicatorLED' } else { Get-RfProp $Sys 'LocationIndicatorActive' }); chassis = $(if (Get-RfText $Chassis 'IndicatorLED') { Get-RfText $Chassis 'IndicatorLED' } else { Get-RfProp $Chassis 'LocationIndicatorActive' }) }
        }
        Variant = ($variants -join ', ')
    }
}

function Get-AzlRfEvent {
    param($Context, $Sys, $Manager, [int]$SampleSize = 10)
    $services = [System.Collections.Generic.List[object]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($owner in @($Sys, $Manager)) {
        $lsLink = Get-RfLink $owner 'LogServices'
        if (-not $lsLink) { continue }
        foreach ($ls in (Get-AzlRedfishMember -Context $Context -Path $lsLink)) {
            $lsPath = [string](Get-RfProp $ls '@odata.id' (Get-RfText $ls 'Id'))
            if (-not $seen.Add($lsPath)) { continue }
            $entryLink = Get-RfLink $ls 'Entries'
            $list = @()
            $total = $null
            if ($entryLink) {
                $coll = Read-AzlRedfishResource -Context $Context -Path $entryLink
                $total = Get-RfProp $coll 'Members@odata.count'
                $list = @(Get-AzlRedfishMember -Context $Context -Path $entryLink -Inline)
            }
            foreach ($e in $list) { $entries.Add([pscustomobject]@{ Service = (Get-RfText $ls 'Id'); Entry = $e }) }
            $services.Add([ordered]@{ id = (Get-RfText $ls 'Id'); name = (Get-RfText $ls 'Name'); maxRecords = (Get-RfProp $ls 'MaxNumberOfRecords'); overwritePolicy = (Get-RfText $ls 'OverWritePolicy'); dateTime = (Get-RfText $ls 'DateTime'); entryCount = $(if ($null -ne $total) { $total } else { $list.Count }); entriesRead = $list.Count })
        }
    }
    $sorted = @($entries | Sort-Object { [string](Get-RfProp $_.Entry 'Created' '') } -Descending)
    $critical = @($sorted | Where-Object { (Get-RfText $_.Entry 'Severity') -eq 'Critical' })
    $warning = @($sorted | Where-Object { (Get-RfText $_.Entry 'Severity') -eq 'Warning' })
    $one = { param($x) [ordered]@{ service = $x.Service; id = (Get-RfText $x.Entry 'Id'); created = (Get-RfText $x.Entry 'Created'); severity = (Get-RfText $x.Entry 'Severity'); message = (Hide-AzlRedfishSecretText -Text (Get-RfText $x.Entry 'Message') -Context $Context); messageId = (Get-RfText $x.Entry 'MessageId') } }
    $total = 0; foreach ($s in $services) { $total += [int]$s.entryCount }
    return [ordered]@{
        logServices = $services.ToArray()
        summary = [ordered]@{
            total = $total; entriesRead = $entries.Count; critical = $critical.Count; warning = $warning.Count
            lastCritical = $(if ($critical.Count -gt 0) { & $one $critical[0] } else { $null }); lastEntryAt = $(if ($sorted.Count -gt 0) { Get-RfText $sorted[0].Entry 'Created' } else { $null })
            sample = @($sorted | Select-Object -First $SampleSize | ForEach-Object { & $one $_ })
        }
    }
}

#endregion

#region orchestration

function Invoke-AzlRedfishDiscovery {
    <#
    .SYNOPSIS
        Reads one BMC (GET only) and returns the per-node report (schemaVersion 2.0).
    .DESCRIPTION
        Starts at /redfish/v1, follows links to the system, chassis and manager, detects the vendor, reads the standard
        resources, runs the adapter hooks for the vendor parts, and ends with the capability report and readErrors. A resource
        that cannot be read is a capability and a readErrors entry; the run goes on. It throws when the service root or the
        system cannot be read, when the credentials are rejected three times in a row, and for a vendor this version has no
        adapter for ("Unsupported vendor in this version").
    .PARAMETER Vendor
        Auto (detect), Dell or None. Dell forces the Dell adapter when detection is wrong or the BMC hides its identity. None reads the
        standard resources only: no vendor adapter, no vendor (OEM) path, and no "Unsupported vendor" stop for any BMC. The vendor is
        still detected and reported.
    .PARAMETER Detail
        Summary (identity, BMC interfaces, summary values, network, storage and boot device), Inventory (Summary plus Secure Boot,
        TPM, processors, memory, PCIe devices and GPUs, and the firmware inventory; no BIOS attributes, sensors or logs) or Full
        (everything the BMC offers).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$BmcAddress,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [ValidateSet('Auto', 'Dell', 'None')][string]$Vendor = 'Auto',
        [ValidateSet('Summary', 'Full', 'Inventory')][string]$Detail = 'Full',
        [switch]$VerifyCertificate,
        [switch]$UseSession,
        [int]$TimeoutSeconds = 60,
        [int]$RetryDelaySeconds = 2,
        [int]$NodeBudgetSeconds = 900,
        [int]$MaxMembers = 1000
    )
    $started = [datetime]::UtcNow
    $ctx = New-AzlRedfishContext -BmcAddress $BmcAddress -Credential $Credential -VerifyCertificate:$VerifyCertificate -UseSession:$UseSession `
        -TimeoutSeconds $TimeoutSeconds -RetryDelaySeconds $RetryDelaySeconds -NodeBudgetSeconds $NodeBudgetSeconds -MaxMembers $MaxMembers
    try {
        if ($UseSession) { Open-AzlRedfishSession -Context $ctx }
        $full = ($Detail -ne 'Summary')
        $deep = ($Detail -eq 'Full')

        Start-AzlRedfishArea -Context $ctx -Name identity
        $root = Read-AzlRedfishResource -Context $ctx -Path '/redfish/v1'
        if (-not $root) {
            $why = ($ctx.ReadErrors | Select-Object -First 1)
            if ($why -and $why.status -eq 401) { throw "The BMC at $BmcAddress rejected the credentials (HTTP 401) when reading the Redfish service root: check the user name and password." }
            throw "The BMC at $BmcAddress did not return the Redfish service root: $(if ($why) { "$($why.kind) $($why.message)" } else { 'no answer' })."
        }
        $adapter = if ($Vendor -eq 'Dell') { Get-AzlRedfishAdapter -Vendor Dell } else { $null }
        $paths = Resolve-AzlRfPath -Context $ctx -Root $root -Fallback $(if ($adapter) { Get-RfProp $adapter 'FallbackPaths' } else { $null })
        if (-not $paths) { throw "The service root of $BmcAddress lists no computer system, so there is nothing to discover." }
        $sys = Read-AzlRedfishResource -Context $ctx -Path $paths.System
        if (-not $sys) { throw "The computer system $($paths.System) of $BmcAddress could not be read: $(($ctx.ReadErrors | Select-Object -Last 1).message)" }
        $chassis = if ($paths.Chassis) { Read-AzlRedfishResource -Context $ctx -Path $paths.Chassis } else { $null }
        $manager = if ($paths.Manager) { Read-AzlRedfishResource -Context $ctx -Path $paths.Manager } else { $null }

        $detected = Resolve-AzlRedfishVendor -ServiceRoot $root -System $sys -Manager $manager
        $evidence = [System.Collections.Generic.List[string]]::new()
        foreach ($e in $detected.Evidence) { $evidence.Add($e) }
        if ($Vendor -eq 'Dell') {
            $evidence.Add("vendor override: -Vendor $Vendor$(if ($detected.Name -ne $Vendor) { " (detection said $($detected.Name))" })")
        }
        elseif ($Vendor -eq 'Auto' -and -not $detected.Supported) {
            throw ("Unsupported vendor in this version: detected '$($detected.Name)' (BMC family $($detected.Family), confidence $($detected.Confidence); " +
                "evidence: $(if ($detected.Evidence.Count -gt 0) { $detected.Evidence -join '; ' } else { 'none' })). " +
                "This version of hardware discovery supports Dell iDRAC only; nothing was collected from $BmcAddress. Use -Vendor Dell only if this really is a Dell iDRAC.")
        }
        if ($Vendor -eq 'None') { $evidence.Add('standard resources only: no vendor adapter is used') }
        elseif (-not $adapter) { $adapter = Get-AzlRedfishAdapter -Vendor $detected.Name }
        if ($Vendor -ne 'None' -and -not $adapter) { throw "No adapter is installed for vendor '$($detected.Name)'." }
        $vendorName = if ($Vendor -eq 'None') { $detected.Name } elseif ($Vendor -ne 'Auto') { $Vendor } else { $detected.Name }
        $confidence = if ($Vendor -eq 'None') { $detected.Confidence } elseif ($Vendor -ne 'Auto' -and $detected.Name -ne $Vendor) { 'override' } else { $detected.Confidence }

        $report = [ordered]@{
            schemaVersion = $script:SchemaVersion; tool = [ordered]@{ name = 'AzlRedfishCore'; version = $script:ToolVersion }
            collectedAt = $started.ToString('yyyy-MM-ddTHH:mm:ssZ'); durationSeconds = 0; bmcAddress = $BmcAddress; detail = $Detail.ToLowerInvariant()
            vendor = [ordered]@{ name = $vendorName; family = $detected.Family; generation = $detected.Generation; confidence = $confidence; evidence = @($evidence); adapter = $(if ($adapter) { "AzlRedfish$($adapter.Vendor)" } else { 'none' }); supportedInThisVersion = ($null -ne $adapter) }
            identity = $null; bmc = $null; system = $null; processors = @(); memory = $null; pcie = @(); gpus = @(); network = $null; storage = $null; firmware = @()
            settings = [ordered]@{ bios = $null; bmc = [ordered]@{ attributes = $null; source = $null } }
            health = [ordered]@{ sensors = @(); power = $null; thermal = $null; leds = $null }
            events = [ordered]@{ logServices = @(); summary = $null }
            raw = [ordered]@{}; capabilities = $null; readErrors = @(); warnings = @()
        }
        $report.identity = Get-AzlRfIdentity -Sys $sys -Chassis $chassis
        Invoke-RfHook $ctx $adapter 'OemSystem' $report $paths $Detail
        Stop-AzlRedfishArea -Context $ctx -Count 1

        Start-AzlRedfishArea -Context $ctx -Name bmc
        $report.bmc = if ($manager) { Get-AzlRfBmc -Context $ctx -Manager $manager -Detail $Detail } else { $null }
        Invoke-RfHook $ctx $adapter 'OemBmc' $report $paths $Detail
        if ($manager) { Stop-AzlRedfishArea -Context $ctx -Count @($report.bmc.interfaces).Count -Variant $(if ($deep) { 'ManagerNetworkProtocol' } else { 'EthernetInterfaces' }) }
        else { Stop-AzlRedfishArea -Context $ctx -Status notSupported -Reason 'No manager is linked from the system.' }


        # security (Secure Boot, TPM) belongs to the system read; Summary skips the SecureBoot request
        if ($full) {
            Start-AzlRedfishArea -Context $ctx -Name security
            $report.system = Get-AzlRfSystem -Context $ctx -Sys $sys -Detail $Detail
            $sb = [bool]$report.system.secureBoot.supported
            $tp = @($report.system.tpm).Count -gt 0
            if ($sb -and $tp) { Stop-AzlRedfishArea -Context $ctx -Status ok -Variant 'SecureBoot, TrustedModules' -Count @($report.system.tpm).Count }
            elseif ($sb -or $tp) { Stop-AzlRedfishArea -Context $ctx -Status partial -Variant 'SecureBoot, TrustedModules' -Count @($report.system.tpm).Count -Reason 'SecureBoot or TrustedModules is not available on this system (see readErrors).' }
            else { Stop-AzlRedfishArea -Context $ctx -Reason 'The system exposes neither SecureBoot nor TrustedModules.' }
        }
        else {
            $report.system = Get-AzlRfSystem -Context $ctx -Sys $sys -Detail $Detail
            Skip-AzlRedfishArea -Context $ctx -Name security -Reason 'Summary detail: Secure Boot and TPM are read with -Detail Full.'
        }

        if ($full) {
            Start-AzlRedfishArea -Context $ctx -Name processors
            $report.processors = Get-AzlRfProcessor -Context $ctx -Sys $sys
            Stop-AzlRedfishArea -Context $ctx -Count @($report.processors).Count
            Start-AzlRedfishArea -Context $ctx -Name memory
            $report.memory = Get-AzlRfMemory -Context $ctx -Sys $sys -Summary $report.system.memoryTotalGiB
            Stop-AzlRedfishArea -Context $ctx -Count @($report.memory.modules).Count
            Start-AzlRedfishArea -Context $ctx -Name pcie
            $pcie = Get-AzlRfPcie -Context $ctx -Paths $paths -Sys $sys -Chassis $chassis
            $report.pcie = $pcie.devices
            $report.gpus = $pcie.gpus
            if ($pcie.Variant) { Stop-AzlRedfishArea -Context $ctx -Count @($pcie.devices).Count -Variant $pcie.Variant } else { Stop-AzlRedfishArea -Context $ctx -Count 0 -Reason 'Neither the Chassis nor the Systems path lists PCIe devices.' }
        }
        else {
            $report.processors = @()
            $report.memory = [ordered]@{ totalGiB = $report.system.memoryTotalGiB; modules = @() }
            $report.pcie = @()
            $report.gpus = @()
            Skip-AzlRedfishArea -Context $ctx -Name processors -Reason 'Summary detail: only ProcessorSummary (count, model) is reported.'
            Skip-AzlRedfishArea -Context $ctx -Name memory -Reason 'Summary detail: only the total memory is reported.'
            Skip-AzlRedfishArea -Context $ctx -Name pcie -Reason 'Summary detail: PCIe devices and GPUs are read with -Detail Full.'
        }

        Start-AzlRedfishArea -Context $ctx -Name network
        $net = Get-AzlRfNetwork -Context $ctx -Sys $sys -Chassis $chassis -AdapterDef $adapter -Detail $Detail
        $report.network = $net.Network
        foreach ($w in $net.Warnings) { $ctx.Warnings.Add($w) }
        Invoke-RfHook $ctx $adapter 'OemNetwork' $report $paths $Detail
        if ($net.Variant) { Stop-AzlRedfishArea -Context $ctx -Variant $net.Variant -Count $net.Count }
        else { Stop-AzlRedfishArea -Context $ctx -Count 0 -Reason 'The system and the chassis link no NetworkAdapters.' }

        Start-AzlRedfishArea -Context $ctx -Name storage
        $report.storage = Get-AzlRfStorage -Context $ctx -Sys $sys
        Invoke-RfHook $ctx $adapter 'OemStorage' $report $paths $Detail
        Stop-AzlRedfishArea -Context $ctx -Variant 'Storage' -Count @($report.storage.controllers).Count

        if ($full) {
            Start-AzlRedfishArea -Context $ctx -Name firmware
            $fw = Get-AzlRfFirmware -Context $ctx -Root $root
            if ($null -ne $fw) { $report.firmware = $fw }
            Invoke-RfHook $ctx $adapter 'OemFirmware' $report $paths $Detail
            if ($null -ne $fw) { Stop-AzlRedfishArea -Context $ctx -Variant 'UpdateService.FirmwareInventory' -Count @($report.firmware).Count }
            else { Stop-AzlRedfishArea -Context $ctx -Count 0 -Reason 'UpdateService does not link a FirmwareInventory.' }
        }
        if ($deep) {
            Start-AzlRedfishArea -Context $ctx -Name bios
            $report.settings.bios = Get-AzlRfBiosSetting -Context $ctx -Sys $sys
            Invoke-RfHook $ctx $adapter 'OemSettings' $report $paths $Detail
            if ($report.settings.bios) { Stop-AzlRedfishArea -Context $ctx -Variant 'Bios' -Count @($report.settings.bios.attributes.Keys).Count }
            else { Stop-AzlRedfishArea -Context $ctx -Count 0 -Reason 'The system does not link a Bios resource.' }

            Start-AzlRedfishArea -Context $ctx -Name sensors
            $h = Get-AzlRfHealth -Context $ctx -Sys $sys -Chassis $chassis
            $report.health = $h.Health
            Invoke-RfHook $ctx $adapter 'OemHealth' $report $paths $Detail
            if ($h.Variant) { Stop-AzlRedfishArea -Context $ctx -Variant $h.Variant -Count @($report.health.sensors).Count }
            else { Stop-AzlRedfishArea -Context $ctx -Count 0 -Reason 'The chassis links no Sensors, Power, Thermal, PowerSubsystem or ThermalSubsystem.' }

            Start-AzlRedfishArea -Context $ctx -Name events
            $report.events = Get-AzlRfEvent -Context $ctx -Sys $sys -Manager $manager
            if (@($report.events.logServices).Count -gt 0) { Stop-AzlRedfishArea -Context $ctx -Variant 'LogServices' -Count $report.events.summary.total }
            else { Stop-AzlRedfishArea -Context $ctx -Count 0 -Reason 'Neither the system nor the manager links LogServices.' }
        }
        else {
            foreach ($a in 'bios', 'sensors', 'events') { Skip-AzlRedfishArea -Context $ctx -Name $a -Reason "$Detail detail: $a is read with -Detail Full." }
        }
        if (-not $full) { Skip-AzlRedfishArea -Context $ctx -Name firmware -Reason 'Summary detail: firmware is read with -Detail Inventory or Full.' }

        foreach ($a in @($report.network.adapters)) {
            if (-not $a.model) {
                $seen = if (@($a.modelRejected).Count -gt 0) { " Generic labels rejected: $((@($a.modelRejected) | ForEach-Object { "'$_'" }) -join ', ')." } else { '' }
                Add-AzlRedfishNote -Context $ctx -Area network -Text "$($a.id): no real model found; the model is left empty rather than a generic label.$seen"
            }
        }
        $report.capabilities = Get-AzlRfCapabilityReport -Context $ctx -Adapter $adapter -Detail $Detail
        $report.readErrors = @($ctx.ReadErrors)
        $report.warnings = @($ctx.Warnings)
        $report.durationSeconds = [math]::Round(([datetime]::UtcNow - $started).TotalSeconds, 1)
    }
    finally {
        if ($UseSession) { Close-AzlRedfishSession -Context $ctx }
    }
    return $report
}

function Invoke-AzlRedfishBatch {
    <#
    .SYNOPSIS
        Runs a script block once per item with bounded parallelism. A failure of one item never stops the others.
    .DESCRIPTION
        The script block receives the item and the Shared object: { param($Item, $Shared) ... }. It runs in its own runspace
        when -ThrottleLimit is above 1, so it must import the modules it needs itself. Returns one result per item:
        Item, Result, Error (the message, or $null).
    .PARAMETER ThrottleLimit
        Maximum nodes read at the same time. 1 runs them one after another. Default 4: BMCs are fragile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        $Shared,
        [ValidateRange(1, 16)][int]$ThrottleLimit = 4
    )
    if ($Item.Count -eq 0) { return , @() }
    if ($ThrottleLimit -le 1 -or $Item.Count -eq 1) {
        return , @(foreach ($i in $Item) {
                try { [pscustomobject]@{ Item = $i; Result = (& $ScriptBlock $i $Shared); Error = $null } }
                catch { [pscustomobject]@{ Item = $i; Result = $null; Error = $_.Exception.Message } }
            })
    }
    $text = $ScriptBlock.ToString()
    return , @($Item | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $work = [scriptblock]::Create($using:text)
            try { [pscustomobject]@{ Item = $_; Result = (& $work $_ $using:Shared); Error = $null } }
            catch { [pscustomobject]@{ Item = $_; Result = $null; Error = $_.Exception.Message } }
        })
}

function ConvertTo-AzlDiscoveryLegacyView {
    <#
    .SYNOPSIS
        The flat view of a schema 2.0 report that the infrastructure.yml tools read: Identity.ServiceTag, NetworkPorts, Boss.
    .DESCRIPTION
        Select-AzlManagementPort, ConvertTo-AzlDiscoveryProposal and Get-AzlDiscoveryChange work on one entry per physical port
        with a MAC. A port without a MAC is left out here (it is in the report, with a warning).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$Report)
    $identity = Get-RfProp $Report 'identity'
    $bmc = Get-RfProp $Report 'bmc'
    $ports = @(foreach ($a in @(Get-RfProp (Get-RfProp $Report 'network') 'adapters' @())) {
            foreach ($p in @(Get-RfProp $a 'ports' @())) {
                if (-not (Get-RfProp $p 'mac')) { continue }
                [ordered]@{
                    Name = [string](Get-RfProp $p 'name' ''); Slot = [string](Get-RfProp $p 'slot' ''); MacAddress = [string](Get-RfProp $p 'mac'); MacSource = [string](Get-RfProp $p 'macSource' '')
                    AdapterId = [string](Get-RfProp $a 'id' ''); PortId = [string](Get-RfProp $p 'id' ''); AdapterModel = [string](Get-RfProp $a 'model' ''); AdapterManufacturer = [string](Get-RfProp $a 'manufacturer' '')
                    FirmwarePackage = [string](Get-RfProp $a 'firmwarePackage' ''); LinkStatus = [string](Get-RfProp $p 'linkStatus' ''); LinkUp = [bool](Get-RfProp $p 'linkUp' $false)
                    LinkSpeedMbps = (Get-RfProp $p 'speedMbps'); MaxSpeedMbps = (Get-RfProp $p 'maxSpeedMbps'); PhysicalPortNumber = (Get-RfProp $p 'portNumber')
                    PortIndex = (Get-RfProp $p 'portIndex'); PciLocation = (Get-RfProp $p 'pciLocation'); Rdma = [string](Get-RfProp $p 'rdma' '')
                }
            }
        })
    $storage = Get-RfProp $Report 'storage'
    $boot = Get-RfProp $storage 'bootDevice'
    $bossController = @(Get-RfProp $storage 'controllers' @()) | Where-Object { (Get-RfProp $_ 'id') -eq (Get-RfProp $boot 'controllerId') } | Select-Object -First 1
    $toDrive = { param($d) [ordered]@{ Id = $d.id; Name = $d.name; Model = $d.model; Manufacturer = $d.manufacturer; SerialNumber = $d.serialNumber; CapacityBytes = $d.capacityBytes; MediaType = $d.mediaType; Protocol = $d.protocol; Health = (Get-RfProp $d.health 'health') } }
    $toVolume = { param($v) [ordered]@{ Id = $v.id; Name = $v.name; RaidType = $v.raidType; VolumeType = $v.volumeType; CapacityBytes = $v.capacityBytes; Health = (Get-RfProp $v.health 'health') } }
    $isBoss = ((Get-RfProp $boot 'kind') -eq 'boss')
    $controllers = @(foreach ($c in @(Get-RfProp $storage 'controllers' @())) {
            [ordered]@{ Id = $c.id; Name = $c.name; Model = [string]$c.model; Manufacturer = [string]$c.manufacturer; FirmwareVersion = [string]$c.firmwareVersion; Drives = @($c.drives | ForEach-Object { & $toDrive $_ }); Volumes = @($c.volumes | ForEach-Object { & $toVolume $_ }) }
        })
    return [ordered]@{
        SchemaVersion = '2.0 (legacy view)'; CollectedAt = [string](Get-RfProp $Report 'collectedAt' ''); BmcAddress = [string](Get-RfProp $Report 'bmcAddress' '')
        Identity = [ordered]@{
            ServiceTag = [string]$(if (Get-RfProp $identity 'serviceTag') { Get-RfProp $identity 'serviceTag' } else { Get-RfProp $identity 'serialNumber' '' }); SerialNumber = [string](Get-RfProp $identity 'serialNumber' '')
            Model = [string](Get-RfProp $identity 'model' ''); Manufacturer = [string](Get-RfProp $identity 'manufacturer' ''); Uuid = [string](Get-RfProp $identity 'uuid' ''); HostName = [string](Get-RfProp $identity 'hostName' '')
            BiosVersion = [string](Get-RfProp $identity 'biosVersion' ''); PowerState = [string](Get-RfProp $identity 'powerState' '')
        }
        Bmc = [ordered]@{ Address = [string](Get-RfProp $Report 'bmcAddress' ''); MacAddress = (Get-RfProp $bmc 'mac'); Interfaces = @(Get-RfProp $bmc 'interfaces' @() | ForEach-Object { [ordered]@{ Id = $_.id; MacAddress = $_.mac; SpeedMbps = $_.speedMbps } }) }
        Processors = [ordered]@{ Count = (Get-RfProp (Get-RfProp (Get-RfProp $Report 'system') 'processorSummary') 'count'); Model = [string](Get-RfProp (Get-RfProp (Get-RfProp $Report 'system') 'processorSummary') 'model' '') }
        MemoryGiB = (Get-RfProp (Get-RfProp $Report 'memory') 'totalGiB')
        NetworkPorts = $ports
        Storage = [ordered]@{ Controllers = $controllers }
        Boss = [ordered]@{
            Present = $isBoss; ControllerId = $(if ($isBoss) { $boot.controllerId } else { $null }); ControllerName = $(if ($isBoss -and $bossController) { $bossController.name } else { $null })
            Detection = $(if ($isBoss) { $boot.detection } else { $null }); DriveCount = $(if ($isBoss) { @($boot.driveIds).Count } else { 0 })
            Drives = @(if ($isBoss -and $bossController) { $bossController.drives | ForEach-Object { & $toDrive $_ } }); Volumes = @(if ($isBoss -and $bossController) { $bossController.volumes | ForEach-Object { & $toVolume $_ } })
            HasVirtualDisk = $(if ($isBoss) { [bool]$boot.hasVirtualDisk } else { $false }); NeedsVirtualDisk = $(if ($isBoss) { [bool]$boot.needsVirtualDisk } else { $false })
        }
        Warnings = @(Get-RfProp $Report 'warnings' @())
        NodeName = $null
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-RfProp', 'Get-RfText', 'Get-RfArray', 'Get-RfLink', 'Get-RfLinkList', 'Get-RfStatus', 'ConvertTo-RfGiB', 'ConvertTo-AzlMacAddress'
    'Remove-AzlRedfishSecret', 'Hide-AzlRedfishSecretText', 'Limit-AzlRedfishRaw'
    'Get-AzlBmcKeyVaultSecret', 'Resolve-AzlBmcCredential'
    'New-AzlRedfishContext', 'Invoke-AzlRedfishRequest', 'Read-AzlRedfishResource', 'Get-AzlRedfishMember', 'Register-AzlRedfishFailure', 'Open-AzlRedfishSession', 'Close-AzlRedfishSession'
    'Start-AzlRedfishArea', 'Stop-AzlRedfishArea', 'Skip-AzlRedfishArea', 'Add-AzlRedfishOemPath', 'Add-AzlRedfishNote'
    'Resolve-AzlRedfishVendor', 'Get-AzlRedfishAdapter', 'Invoke-AzlRedfishDiscovery', 'Invoke-AzlRedfishBatch', 'ConvertTo-AzlDiscoveryLegacyView'
)
