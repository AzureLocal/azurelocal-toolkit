#Requires -Version 7.0
<#
.SYNOPSIS
    The one secret resolver of the toolkit. A script gives it a secret reference and the loaded infrastructure file; it returns the secret.

.DESCRIPTION
    DESIGN (read this first)

    Reference forms. A reference always names its own provider in its scheme, so one file can mix providers. A reference holds a
    NAME, never a value, a path or a command line.

        keyvault://<vault>/<secret>[/<version>]   Azure Key Vault (the default provider). <vault> must be listed under key_vaults.
        env://<VARIABLE_NAME>                     An environment variable of this process. Letters, digits, underscore.
        file://<name>                             A file in secrets.file.directory. <name>: letters, digits, _ and -, one optional
                                                  extension of up to 10 letters or digits. No slash, no colon, no "..".
        command://<name>                          The output of the command in secrets.command. <name> as for file.

    Why a name only. The directory of the secret files and the command are settings in the master file (section secrets). A
    reference in a shared file therefore cannot point a machine at an arbitrary path (file://C:\Windows\... is not a reference, and
    Windows drive letters and backslashes cannot be quoted safely in a URI) or run an arbitrary command. A string that is not one
    of these four forms is not a reference. It is never used as a value.

    secrets.provider is the provider New-AzlSecretReference uses when the caller does not name one (default keyvault). It never
    changes how an existing reference is read.

    Provider rules
        keyvault  Az.KeyVault Get-AzKeyVaultSecret. No Azure CLI fallback. The vault must be listed in key_vaults, else it is an input
                  error (nothing is sent to Azure). The error says which of these happened: not signed in, vault not found,
                  secret not found, access denied. The module never signs in.
        env       The variable must be set and not empty.
        file      One secret per file, UTF-8 (a leading byte order mark is dropped), at most 256 KiB. The trailing line breaks are
                  removed and nothing else is changed. The file must be a plain file inside the directory (a link is refused).
                  On Windows a warning is written when Everyone, Users or Authenticated Users can read the file; on Linux and macOS
                  when group or other can. The warning names the file, never the content.
        command   secrets.command.executable and secrets.command.arguments. The executable is started directly with the argument
                  array: no shell, no command string, no Invoke-Expression. The text {name} in an argument is replaced by the name
                  in the reference (the name is restricted, so it cannot carry quotes or separators). At least one argument must
                  hold {name}. The standard input is closed. The command must finish within secrets.command.timeout_seconds
                  (default 30), else it is killed. Standard output is the secret (trailing line breaks removed). The exit code and
                  a short, single-line, scrubbed copy of the standard error are reported when it fails; standard output is not.

    Security rules
        1. A secret value is returned only as a SecureString (Get-AzlSecretValue) or, from the clearly named
           Get-AzlSecretPlainText, as a string for the few callers that must put it in a request body. Nothing else returns it.
        2. A value is never written to a file, a log, an error message, the verbose, debug, information or warning streams, or a
           result object. Only references appear in messages. A text that is not a reference is never echoed (it may be a
           password someone pasted by mistake); only its length is.
        3. No Invoke-Expression, no Write-Host of values, no ConvertFrom-SecureString, no ConvertTo-SecureString -AsPlainText.
        4. Errors raised from other code (Az, .NET) are classified here and re-raised without the original text, except the Key
           Vault "unclassified" case, which shows the exception type only.
        5. When in doubt, refuse with a clear message.

    Error behaviour. Every failure is an exception whose Data holds AzlSecretError (the category) and AzlExit (2 for a wrong or
    missing input or setting, 1 for a failed call). Categories: InvalidReference, VaultNotListed, NotConfigured (a setting of the
    master file is missing or unusable), NotSignedIn, VaultNotFound, SecretNotFound, AccessDenied, KeyVaultError, NotSet (env),
    FileNotFound, FileUnsafe, CommandFailed, CommandTimeout, EmptySecret, TooLarge, Unexpected.

    Functions
        Get-AzlSecretValue          reference + infrastructure -> SecureString
        Get-AzlSecretPlainText      the same as a string, for a request body only
        Get-AzlSecretProvider       keyvault, env, file or command; $null when the text is not a reference
        Test-AzlSecretReference     $true when the reference can be resolved now. Pre-flight check. The value is read into memory
                                    to prove it, then discarded, and never returned. For command it runs the command.
        Get-AzlSecretDefaultProvider  secrets.provider (keyvault when not set)
        New-AzlSecretReference      builds a reference for a name in a provider (default: secrets.provider)

    Keys read: secrets.provider, secrets.file.directory, secrets.command.executable, secrets.command.arguments,
    secrets.command.timeout_seconds, key_vaults[].name.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))

$script:Providers = @('keyvault', 'env', 'file', 'command')
$script:NamePart = '[A-Za-z0-9][A-Za-z0-9_-]{0,100}(\.[A-Za-z0-9]{1,10})?'
# \z, not $ : in .NET $ also matches before a final line feed.
$script:Forms = [ordered]@{
    keyvault = '^keyvault://(?<vault>[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9])/(?<secret>[A-Za-z0-9-]{1,127})(/(?<version>[0-9a-fA-F]{32}))?\z'
    env      = '^env://(?<name>[A-Za-z_][A-Za-z0-9_]{0,127})\z'
    file     = "^file://(?<name>$($script:NamePart))\z"
    command  = "^command://(?<name>$($script:NamePart))\z"
}
$script:MaxBytes = 256KB
$script:DefaultTimeoutSeconds = 30
$script:ReservedDeviceName = '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$'

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------

function Stop-AzlSecret {
    # Raises the one error type of this module. The message must never hold a secret value.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Throws an error; changes no system state.')]
    param([Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][string]$Message, [int]$Exit = 1)
    $e = [System.InvalidOperationException]::new($Message)
    $e.Data['AzlSecretError'] = $Category
    $e.Data['AzlExit'] = $Exit
    throw $e
}

function ConvertFrom-AzlSecretReference {
    # Provider and parts of a reference, or $null when the text is not one of the four forms.
    param([AllowNull()][AllowEmptyString()][string]$Reference)
    if ([string]::IsNullOrEmpty($Reference)) { return $null }
    foreach ($provider in $script:Providers) {
        $m = [regex]::Match($Reference, $script:Forms[$provider], [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) { continue }
        $get = { param($g) if ($m.Groups[$g].Success) { $m.Groups[$g].Value } else { $null } }
        return [pscustomobject]@{
            Provider = $provider; Vault = (& $get 'vault'); Secret = (& $get 'secret'); Version = (& $get 'version')
            Name     = $(if ($provider -in 'file', 'command', 'env') { & $get 'name' } else { $null })
        }
    }
    return $null
}

function Get-AzlSecretParsed {
    # The parsed reference, or an InvalidReference error that does not repeat the text.
    param([AllowNull()][AllowEmptyString()][string]$Reference)
    $parsed = ConvertFrom-AzlSecretReference -Reference $Reference
    if (-not $parsed) {
        $length = if ($null -eq $Reference) { 0 } else { $Reference.Length }
        Stop-AzlSecret -Category InvalidReference -Message "The value ($length characters) is not a secret reference. A reference is keyvault://<vault>/<secret>, env://<VARIABLE>, file://<name> or command://<name>. A secret value must never be written where a reference is expected." -Exit 2
    }
    return $parsed
}

function ConvertTo-AzlSecureText {
    # A SecureString from text, without ConvertTo-SecureString -AsPlainText.
    param([Parameter(Mandatory)][string]$Text)
    $secure = [System.Security.SecureString]::new()
    foreach ($c in $Text.ToCharArray()) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    return $secure
}

function Hide-AzlSecretText {
    # Single line, cut short, with the secret removed. For text from another program.
    param([AllowNull()][string]$Text, [AllowNull()][string]$Secret, [int]$Max = 300)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $out = $Text
    if (-not [string]::IsNullOrEmpty($Secret)) { $out = $out.Replace($Secret, '***') }
    $out = ($out -replace '\s+', ' ').Trim()
    if ($out.Length -gt $Max) { $out = $out.Substring(0, $Max - 3) + '...' }
    return $out
}

function ConvertFrom-AzlSecretUtf8 {
    # UTF-8 (strict), byte order mark dropped, trailing line breaks removed. Empty is an error.
    param([byte[]]$Bytes, [string]$Reference)
    $start = if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { 3 } else { 0 }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, $start, $Bytes.Length - $start) }
    catch { Stop-AzlSecret -Category FileUnsafe -Message "$Reference is not valid UTF-8 text." }
    $text = $text.TrimEnd("`r", "`n")
    if ($text.Length -eq 0) { Stop-AzlSecret -Category EmptySecret -Message "$Reference is empty." }
    return $text
}

# ---------------------------------------------------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlKeyVaultSecureValue {
    param([Parameter(Mandatory)]$Parsed, [Parameter(Mandatory)][string]$Reference, [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure)
    $listed = @(Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'key_vaults' | ForEach-Object { $_ } | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('name') } | ForEach-Object { [string]$_['name'] })
    if ($Parsed.Vault -notin $listed) {
        Stop-AzlSecret -Category VaultNotListed -Message "$Reference names vault $($Parsed.Vault), which is not listed under key_vaults in the infrastructure file. Add the vault there first." -Exit 2
    }
    if (-not (Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        Stop-AzlSecret -Category NotConfigured -Message 'The Az.KeyVault module is not installed (Install-Module Az.KeyVault).' -Exit 2
    }
    $context = $null
    if (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue) { $context = Get-AzContext -ErrorAction SilentlyContinue }
    if (-not $context) { Stop-AzlSecret -Category NotSignedIn -Message "Nobody is signed in to Azure, so $Reference cannot be read. Run Connect-AzAccount first." }
    $arguments = @{ VaultName = $Parsed.Vault; Name = $Parsed.Secret; ErrorAction = 'Stop' }
    if ($Parsed.Version) { $arguments.Version = $Parsed.Version }
    try { $item = Get-AzKeyVaultSecret @arguments }
    catch {
        $text = [string]$_.Exception.Message
        $type = $_.Exception.GetType().Name
        if ($text -match 'SecretNotFound|secret.{0,40}(was )?not found|SecretDisabled') { Stop-AzlSecret -Category SecretNotFound -Message "The secret $($Parsed.Secret) was not found in vault $($Parsed.Vault) ($Reference)." }
        if ($text -match 'VaultNotFound|No such host|could not be resolved|name resolution|vault.{0,60}(was )?not found') { Stop-AzlSecret -Category VaultNotFound -Message "Vault $($Parsed.Vault) was not found, or its name does not resolve ($Reference)." }
        if ($text -match 'Forbidden|AccessDenied|not authorized|does not have secrets|\b403\b') { Stop-AzlSecret -Category AccessDenied -Message "Access to $Reference was denied. The signed-in identity needs read access to secrets on vault $($Parsed.Vault) (Key Vault Secrets User)." }
        if ($text -match 'Connect-AzAccount|Unauthorized|AADSTS|no Azure context|Please (log|sign) in|\b401\b') { Stop-AzlSecret -Category NotSignedIn -Message "The Azure sign-in is missing, expired or for another tenant, so $Reference cannot be read. Run Connect-AzAccount." }
        Stop-AzlSecret -Category KeyVaultError -Message "Key Vault returned an error for $Reference (exception type $type)."
    }
    if (-not $item) { Stop-AzlSecret -Category SecretNotFound -Message "The secret $($Parsed.Secret) was not found in vault $($Parsed.Vault) ($Reference)." }
    $value = $item.SecretValue
    if ($value -isnot [System.Security.SecureString] -or $value.Length -eq 0) { Stop-AzlSecret -Category EmptySecret -Message "$Reference is empty." }
    return $value
}

function Get-AzlEnvironmentSecureValue {
    param([Parameter(Mandatory)]$Parsed, [Parameter(Mandatory)][string]$Reference)
    $text = [Environment]::GetEnvironmentVariable($Parsed.Name)
    if ([string]::IsNullOrEmpty($text)) { Stop-AzlSecret -Category NotSet -Message "The environment variable $($Parsed.Name) ($Reference) is not set or is empty." }
    try { return (ConvertTo-AzlSecureText -Text $text) } finally { $text = $null }
}

function Test-AzlSecretFileBroadAccess {
    # $true when the file can be read by everybody on the machine. Errors while checking mean "unknown", which is $false.
    param([Parameter(Mandatory)][string]$Path)
    try {
        if ($IsWindows) {
            $broad = @('S-1-1-0', 'S-1-5-32-545', 'S-1-5-11')
            foreach ($rule in (Get-Acl -LiteralPath $Path -ErrorAction Stop).Access) {
                if ($rule.AccessControlType -ne 'Allow' -or -not ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData)) { continue }
                $sid = try { $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
                if ($sid -in $broad) { return $true }
            }
            return $false
        }
        $mode = [IO.File]::GetUnixFileMode($Path)
        return [bool]($mode -band ([IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::OtherRead))
    }
    catch { return $false }
}

function Get-AzlFileSecureValue {
    param([Parameter(Mandatory)]$Parsed, [Parameter(Mandatory)][string]$Reference, [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure)
    $directory = [string](Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'secrets.file.directory')
    if ([string]::IsNullOrWhiteSpace($directory)) { Stop-AzlSecret -Category NotConfigured -Message "$Reference needs secrets.file.directory in the infrastructure file." -Exit 2 }
    if (-not [IO.Path]::IsPathRooted($directory) -or ($IsWindows -and $directory -notmatch '^([A-Za-z]:[\\/]|\\\\)')) { Stop-AzlSecret -Category NotConfigured -Message 'secrets.file.directory must be an absolute path.' -Exit 2 }
    $base = [IO.Path]::GetFullPath($directory)
    if ($Parsed.Name -match ($script:ReservedDeviceName) -or ($Parsed.Name.Split('.')[0] -match $script:ReservedDeviceName)) { Stop-AzlSecret -Category InvalidReference -Message "$Reference uses a reserved device name." -Exit 2 }
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($base, $Parsed.Name))
    if (-not $path.StartsWith($base.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Stop-AzlSecret -Category InvalidReference -Message "$Reference does not stay inside secrets.file.directory." -Exit 2 }
    $info = [IO.FileInfo]::new($path)
    if (-not $info.Exists) { Stop-AzlSecret -Category FileNotFound -Message "The file for $Reference does not exist in secrets.file.directory." }
    if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint -or $info.LinkTarget) { Stop-AzlSecret -Category FileUnsafe -Message "The file for $Reference is a link. Links are refused; put the secret in a plain file." }
    if ($info.Length -gt $script:MaxBytes) { Stop-AzlSecret -Category TooLarge -Message "The file for $Reference is larger than $($script:MaxBytes / 1KB) KiB." }
    if (Test-AzlSecretFileBroadAccess -Path $path) {
        Write-Warning "The file for $Reference can be read by everybody on this machine (Everyone, Users or group/other). Restrict it to the account that runs the toolkit."
    }
    $bytes = [IO.File]::ReadAllBytes($path)
    try { return (ConvertTo-AzlSecureText -Text (ConvertFrom-AzlSecretUtf8 -Bytes $bytes -Reference $Reference)) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Get-AzlCommandSecureValue {
    param([Parameter(Mandatory)]$Parsed, [Parameter(Mandatory)][string]$Reference, [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure)
    $executable = [string](Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'secrets.command.executable')
    $template = @(Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'secrets.command.arguments' | ForEach-Object { $_ } | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    $timeoutValue = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'secrets.command.timeout_seconds'
    $timeout = if ($null -eq $timeoutValue) { $script:DefaultTimeoutSeconds } else { [int]$timeoutValue }
    if ([string]::IsNullOrWhiteSpace($executable)) { Stop-AzlSecret -Category NotConfigured -Message "$Reference needs secrets.command.executable in the infrastructure file." -Exit 2 }
    if (-not ($template | Where-Object { $_.Contains('{name}') })) { Stop-AzlSecret -Category NotConfigured -Message 'secrets.command.arguments must hold {name} in at least one argument.' -Exit 2 }
    if ($timeout -lt 1 -or $timeout -gt 300) { Stop-AzlSecret -Category NotConfigured -Message 'secrets.command.timeout_seconds must be from 1 to 300.' -Exit 2 }
    if ($executable -match '[\\/]') {
        if (-not [IO.Path]::IsPathRooted($executable)) { Stop-AzlSecret -Category NotConfigured -Message 'secrets.command.executable must be a command name or an absolute path.' -Exit 2 }
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { Stop-AzlSecret -Category NotConfigured -Message 'secrets.command.executable does not exist.' -Exit 2 }
        $file = $executable
    }
    else {
        $found = Get-Command -Name $executable -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { Stop-AzlSecret -Category NotConfigured -Message "secrets.command.executable '$executable' was not found on the path." -Exit 2 }
        $file = $found.Source
    }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $file
    foreach ($argument in $template) { $start.ArgumentList.Add($argument.Replace('{name}', $Parsed.Name)) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stdout = $null
    try {
        try { $null = $process.Start() } catch { Stop-AzlSecret -Category CommandFailed -Message "The command for $Reference could not be started (exception type $($_.Exception.GetType().Name))." }
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($timeout * 1000)) {
            try { $process.Kill($true) } catch { Write-Verbose 'The command had already ended.' }
            Stop-AzlSecret -Category CommandTimeout -Message "The command for $Reference did not finish within $timeout seconds and was stopped."
        }
        $process.WaitForExit()
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = Hide-AzlSecretText -Text $stderr -Secret $stdout.TrimEnd("`r", "`n")
            Stop-AzlSecret -Category CommandFailed -Message "The command for $Reference failed with exit code $($process.ExitCode).$(if ($detail) { " Standard error: $detail" })"
        }
        $text = $stdout.TrimEnd("`r", "`n")
        if ($text.Length -eq 0) { Stop-AzlSecret -Category EmptySecret -Message "The command for $Reference returned no output." }
        if ([Text.Encoding]::UTF8.GetByteCount($text) -gt $script:MaxBytes) { Stop-AzlSecret -Category TooLarge -Message "The command for $Reference returned more than $($script:MaxBytes / 1KB) KiB." }
        return (ConvertTo-AzlSecureText -Text $text)
    }
    finally { $process.Dispose(); $stdout = $null }
}

# ---------------------------------------------------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlSecretProvider {
    <#
    .SYNOPSIS
        The provider a secret reference uses: keyvault, env, file or command. $null when the text is not a reference.
    .EXAMPLE
        Get-AzlSecretProvider 'env://AZL_LOCAL_ADMIN'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowNull()][AllowEmptyString()][string]$Reference)
    $parsed = ConvertFrom-AzlSecretReference -Reference $Reference
    if ($parsed) { return $parsed.Provider }
    return $null
}

function Get-AzlSecretValue {
    <#
    .SYNOPSIS
        The secret a reference points to, as a SecureString. Reads the provider; changes nothing.
    .DESCRIPTION
        Use this wherever the receiver accepts a SecureString or a PSCredential. The value is never logged or written. See the
        top of this file for the reference forms, the provider rules and the errors.
    .PARAMETER Reference
        keyvault://<vault>/<secret>, env://<VARIABLE>, file://<name> or command://<name>.
    .PARAMETER Infrastructure
        The loaded infrastructure file (Import-AzlInfrastructure). It holds key_vaults and the secrets section.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()][AllowEmptyString()][string]$Reference,
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$Infrastructure
    )
    if ($null -eq $Infrastructure) { Stop-AzlSecret -Category NotConfigured -Message 'The infrastructure file is needed to read a secret reference, and none was given.' -Exit 2 }
    $parsed = Get-AzlSecretParsed -Reference $Reference
    Write-Verbose "Reading secret reference $Reference with the $($parsed.Provider) provider."
    try {
        switch ($parsed.Provider) {
            'keyvault' { return (Get-AzlKeyVaultSecureValue -Parsed $parsed -Reference $Reference -Infrastructure $Infrastructure) }
            'env' { return (Get-AzlEnvironmentSecureValue -Parsed $parsed -Reference $Reference) }
            'file' { return (Get-AzlFileSecureValue -Parsed $parsed -Reference $Reference -Infrastructure $Infrastructure) }
            'command' { return (Get-AzlCommandSecureValue -Parsed $parsed -Reference $Reference -Infrastructure $Infrastructure) }
        }
    }
    catch {
        if ($_.Exception.Data.Contains('AzlSecretError')) { throw }
        # Anything else came from outside this module: say only what kind of error it was.
        Stop-AzlSecret -Category Unexpected -Message "Reading $Reference failed unexpectedly (exception type $($_.Exception.GetType().Name))."
    }
}

function Get-AzlSecretPlainText {
    <#
    .SYNOPSIS
        The secret a reference points to, as plain text. Only for a caller that must put the value in a request body or a protected
        parameter. Prefer Get-AzlSecretValue.
    .DESCRIPTION
        The string is not logged by this module. The caller must not log, write or return it, and must not keep it longer than
        the request needs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()][AllowEmptyString()][string]$Reference,
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$Infrastructure
    )
    $secure = Get-AzlSecretValue -Reference $Reference -Infrastructure $Infrastructure
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        $secure.Dispose()
    }
}

function Test-AzlSecretReference {
    <#
    .SYNOPSIS
        $true when the reference can be resolved now. For pre-flight checks. Never returns the value.
    .DESCRIPTION
        The secret is read into memory to prove that it can be read (a Key Vault read, a file read, an environment lookup, or a run
        of the command), then discarded. With -Detailed the result is an object: Reference (the text if it is a reference, else a
        note), Provider, Resolvable, Category, Message. It holds no value and no text that is not a reference.
    #>
    [CmdletBinding()]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()][AllowEmptyString()][string]$Reference,
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$Infrastructure,
        [switch]$Detailed
    )
    $parsed = ConvertFrom-AzlSecretReference -Reference $Reference
    $result = [ordered]@{
        Reference = $(if ($parsed) { $Reference } else { '<not a secret reference>' }); Provider = $(if ($parsed) { $parsed.Provider } else { $null })
        Resolvable = $false; Category = ''; Message = ''
    }
    $secure = $null
    try {
        $secure = Get-AzlSecretValue -Reference $Reference -Infrastructure $Infrastructure
        $result.Resolvable = $true
    }
    catch {
        $result.Category = [string]$(if ($_.Exception.Data.Contains('AzlSecretError')) { $_.Exception.Data['AzlSecretError'] } else { 'Unexpected' })
        $result.Message = if ($_.Exception.Data.Contains('AzlSecretError')) { $_.Exception.Message } else { 'The check failed unexpectedly.' }
    }
    finally { if ($secure) { $secure.Dispose() } }
    if ($Detailed) { return [pscustomobject]$result }
    return [bool]$result.Resolvable
}

function Get-AzlSecretDefaultProvider {
    <#
    .SYNOPSIS
        secrets.provider from the infrastructure file: keyvault, env, file or command. keyvault when the key is not set.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure)
    $value = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'secrets.provider'
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return 'keyvault' }
    if ([string]$value -notin $script:Providers) { Stop-AzlSecret -Category NotConfigured -Message "secrets.provider must be one of $($script:Providers -join ', ')." -Exit 2 }
    return [string]$value
}

function New-AzlSecretReference {
    <#
    .SYNOPSIS
        Builds a secret reference for a name. The provider is -Provider, else secrets.provider.
    .DESCRIPTION
        keyvault needs the vault: -Vault, or the only vault listed under key_vaults. The result is checked against the reference
        forms, so a name that cannot be a reference is refused. Reads nothing from any provider.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string; changes no system state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [ValidateSet('keyvault', 'env', 'file', 'command')][string]$Provider,
        [string]$Vault
    )
    if (-not $Provider) { $Provider = Get-AzlSecretDefaultProvider -Infrastructure $Infrastructure }
    $text = switch ($Provider) {
        'keyvault' {
            if (-not $Vault) {
                $names = @(Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'key_vaults' | ForEach-Object { $_ } | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['name'] })
                if ($names.Count -ne 1) { Stop-AzlSecret -Category NotConfigured -Message 'Name the vault (-Vault): key_vaults does not list exactly one.' -Exit 2 }
                $Vault = $names[0]
            }
            "keyvault://$Vault/$Name"
        }
        default { "${Provider}://$Name" }
    }
    $null = Get-AzlSecretParsed -Reference $text
    return $text
}

Export-ModuleMember -Function Get-AzlSecretValue, Get-AzlSecretPlainText, Get-AzlSecretProvider, Test-AzlSecretReference, Get-AzlSecretDefaultProvider, New-AzlSecretReference
