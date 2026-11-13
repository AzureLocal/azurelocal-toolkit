#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The secret resolver (scripts/common/secrets/AzlSecret.psm1): the four providers, every error path, and proof that no secret value
# leaks. Key Vault is mocked (no Azure call, no sign-in). The environment, file and command providers use real temporary files and a
# harmless test command (pwsh -NoProfile -Command). Every secret in this file is a made-up canary string.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/secrets/AzlSecret.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes and temp files.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Tests build fake secure values from made-up canary strings.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:ModulePath = [IO.Path]::Combine($repo, 'scripts', 'common', 'secrets', 'AzlSecret.psm1')
    Import-Module $script:ModulePath -Force

    # Stubs with the Az signatures the module uses, so the mocks work whether or not Az is installed. Global, so the module sees them.
    function global:Get-AzContext { [CmdletBinding()] param() }
    function global:Get-AzKeyVaultSecret { [CmdletBinding()] param([string]$VaultName, [string]$Name, [string]$Version) }
    # Safety net: a test that forgets its own mock must not reach Azure.
    Mock -ModuleName AzlSecret Get-AzContext { throw 'A test tried to reach Azure.' }
    Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw 'A test tried to read Key Vault.' }

    $script:Canary ='Canary-S3cret-9f2c71'
    $script:Vault = 'kv-iic-mgmt-01'

    function New-Secure([string]$Text) { $s = [securestring]::new(); foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }; $s.MakeReadOnly(); $s }
    function ConvertTo-Plain([securestring]$Secure) { [System.Net.NetworkCredential]::new('', $Secure).Password }

    function New-SecretDirectory {
        $d = Join-Path $TestDrive ('secrets-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = New-Item -ItemType Directory -Path $d
        $d
    }
    # A secret file only the current account can read, so a test that wants no warning gets none.
    function Set-PrivateFile([string]$Path) {
        if ($IsWindows) {
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $null = & icacls.exe $Path /inheritance:r /grant:r "*${me}:(F)"
        }
        else { [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    }
    function New-SecretFile([string]$Directory, [string]$Name, [byte[]]$Bytes) {
        $p = Join-Path $Directory $Name
        [IO.File]::WriteAllBytes($p, $Bytes)
        Set-PrivateFile $p
        $p
    }
    function Get-Utf8([string]$Text) { [Text.UTF8Encoding]::new($false).GetBytes($Text) }

    function New-Infra {
        param([string]$Directory, [string[]]$Arguments, [string]$Executable = 'pwsh', [object]$Timeout, [string[]]$Vaults = @($script:Vault))
        $infra = [ordered]@{ key_vaults = @($Vaults | ForEach-Object { [ordered]@{ name = $_; subscription_id = [guid]::Empty.ToString(); resource_group = 'rg-iic-mgmt-01' } }) }
        $secrets = [ordered]@{}
        if ($Directory) { $secrets.file = [ordered]@{ directory = $Directory } }
        if ($Arguments) {
            $secrets.command = [ordered]@{ executable = $Executable; arguments = @($Arguments) }
            if ($null -ne $Timeout) { $secrets.command.timeout_seconds = $Timeout }
        }
        if ($secrets.Count) { $infra.secrets = $secrets }
        $infra
    }
    function New-CommandInfra([string]$Code, [object]$Timeout) { New-Infra -Arguments @('-NoProfile', '-NonInteractive', '-Command', $Code) -Timeout $Timeout }

    # The exception a script block throws, or $null.
    function Get-Failure([scriptblock]$Block) { try { $null = & $Block; $null } catch { $_.Exception } }
    function Get-Category($Failure) { $Failure.Data['AzlSecretError'] }

    # Everything a script block writes to any stream (except the returned objects that are SecureStrings), as text.
    function Get-StreamText([scriptblock]$Block) {
        $out = & { try { & $Block } catch { $_ } } *>&1
        (@($out | Where-Object { $_ -isnot [securestring] } | ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { "$($_.Exception.Message) $($_.ScriptStackTrace) $($_.Exception.Data.Values -join ' ')" } else { "$_" } }) -join "`n")
    }
}

AfterAll {
    Remove-Item function:global:Get-AzContext, function:global:Get-AzKeyVaultSecret -ErrorAction SilentlyContinue
}

Describe 'Reference forms and Get-AzlSecretProvider' {
    It '<Ref> uses the <Provider> provider' -ForEach @(
        @{ Ref = 'keyvault://kv-iic-mgmt-01/local-admin-password'; Provider = 'keyvault' }
        @{ Ref = 'keyvault://kv-iic-mgmt-01/local-admin-password/0123456789abcdef0123456789abcdef'; Provider = 'keyvault' }
        @{ Ref = 'env://AZL_LOCAL_ADMIN'; Provider = 'env' }
        @{ Ref = 'file://lcm-password'; Provider = 'file' }
        @{ Ref = 'file://lcm-password.txt'; Provider = 'file' }
        @{ Ref = 'command://lcm-password'; Provider = 'command' }
    ) {
        Get-AzlSecretProvider $Ref | Should -Be $Provider
    }

    It 'says nothing for text that is not a reference: <Text>' -ForEach @(
        @{ Text = 'hunter2-not-a-reference' }
        @{ Text = '' }
        @{ Text = 'keyvault://kv-iic-mgmt-01' }
        @{ Text = 'keyvault://kv-iic-mgmt-01/a/b' }
        @{ Text = 'https://kv-iic-mgmt-01.vault.azure.net/secrets/x' }
        @{ Text = 'env://1STARTS_WITH_DIGIT' }
        @{ Text = 'env://HAS-DASH' }
        @{ Text = 'file://../other' }
        @{ Text = 'file://sub/name' }
        @{ Text = 'file://sub\name' }
        @{ Text = 'file://C:\secrets\x.txt' }
        @{ Text = 'file://.hidden' }
        @{ Text = 'file://a..b' }
        @{ Text = 'file://name with space' }
        @{ Text = 'file://' }
        @{ Text = 'command://rm -rf /' }
        @{ Text = 'command://a;b' }
        @{ Text = 'command://a|b' }
        @{ Text = 'command://$(x)' }
        @{ Text = "env://NAME`n" }
        @{ Text = "file://name`r`nmore" }
    ) {
        Get-AzlSecretProvider $Text | Should -BeNullOrEmpty
    }

    It 'takes the scheme in any letter case and returns the provider in lower case' {
        Get-AzlSecretProvider 'ENV://AZL_X' | Should -Be 'env'
    }
}

Describe 'Environment variable provider' {
    BeforeAll { $script:Infra = New-Infra }
    AfterEach { Remove-Item Env:AZL_TEST_SECRET -ErrorAction SilentlyContinue }

    It 'returns a SecureString with the value' {
        $env:AZL_TEST_SECRET = $script:Canary
        $s = Get-AzlSecretValue -Reference 'env://AZL_TEST_SECRET' -Infrastructure $script:Infra
        $s | Should -BeOfType ([securestring])
        $s.IsReadOnly() | Should -BeTrue
        ConvertTo-Plain $s | Should -Be $script:Canary
    }
    It 'Get-AzlSecretPlainText returns the same value as a string' {
        $env:AZL_TEST_SECRET = $script:Canary
        Get-AzlSecretPlainText -Reference 'env://AZL_TEST_SECRET' -Infrastructure $script:Infra | Should -BeExactly $script:Canary
    }
    It 'does not change the value (spaces and line breaks inside stay)' {
        $env:AZL_TEST_SECRET = " a b`nc "
        ConvertTo-Plain (Get-AzlSecretValue 'env://AZL_TEST_SECRET' -Infrastructure $script:Infra) | Should -BeExactly " a b`nc "
    }
    It 'fails with NotSet (exit 1) when the variable is missing' {
        $f = Get-Failure { Get-AzlSecretValue 'env://AZL_TEST_SECRET' -Infrastructure $script:Infra }
        Get-Category $f | Should -Be 'NotSet'
        $f.Data['AzlExit'] | Should -Be 1
        $f.Message | Should -Match 'AZL_TEST_SECRET'
    }
    It 'fails with NotSet when the variable is empty' {
        $env:AZL_TEST_SECRET = ''
        Get-Category (Get-Failure { Get-AzlSecretValue 'env://AZL_TEST_SECRET' -Infrastructure $script:Infra }) | Should -Be 'NotSet'
    }
}

Describe 'File provider' {
    BeforeEach { $script:Dir = New-SecretDirectory; $script:Infra = New-Infra -Directory $script:Dir }

    It 'reads one secret per file and removes the trailing line break (LF)' {
        $null = New-SecretFile -Directory $script:Dir -Name 'lcm-password' -Bytes (Get-Utf8 "$($script:Canary)`n")
        ConvertTo-Plain (Get-AzlSecretValue 'file://lcm-password' -Infrastructure $script:Infra) | Should -BeExactly $script:Canary
    }
    It 'removes a trailing CRLF and nothing else (spaces stay)' {
        $null = New-SecretFile -Directory $script:Dir -Name 'lcm-password.txt' -Bytes (Get-Utf8 " $($script:Canary) `r`n")
        ConvertTo-Plain (Get-AzlSecretValue 'file://lcm-password.txt' -Infrastructure $script:Infra) | Should -BeExactly " $($script:Canary) "
    }
    It 'reads UTF-8 text and drops a byte order mark' {
        $null = New-SecretFile -Directory $script:Dir -Name 'bom' -Bytes (@(0xEF, 0xBB, 0xBF) + (Get-Utf8 "p$([char]0xE4)ssw$([char]0xF6)rd-$($script:Canary)"))
        ConvertTo-Plain (Get-AzlSecretValue 'file://bom' -Infrastructure $script:Infra) | Should -BeExactly "p$([char]0xE4)ssw$([char]0xF6)rd-$($script:Canary)"
    }
    It 'keeps line breaks inside a multi-line secret' {
        $null = New-SecretFile -Directory $script:Dir -Name 'pem' -Bytes (Get-Utf8 "line1`nline2`n")
        ConvertTo-Plain (Get-AzlSecretValue 'file://pem' -Infrastructure $script:Infra) | Should -BeExactly "line1`nline2"
    }
    It 'fails with FileNotFound when the file does not exist' {
        $f = Get-Failure { Get-AzlSecretValue 'file://missing' -Infrastructure $script:Infra }
        Get-Category $f | Should -Be 'FileNotFound'
        $f.Message | Should -Not -Match ([regex]::Escape($script:Dir)) -Because 'the message names the reference, not the directory'
    }
    It 'fails with EmptySecret for an empty file and for a file with only a line break' {
        $null = New-SecretFile -Directory $script:Dir -Name 'empty' -Bytes ([byte[]]@())
        $null = New-SecretFile -Directory $script:Dir -Name 'newline' -Bytes (Get-Utf8 "`r`n")
        Get-Category (Get-Failure { Get-AzlSecretValue 'file://empty' -Infrastructure $script:Infra }) | Should -Be 'EmptySecret'
        Get-Category (Get-Failure { Get-AzlSecretValue 'file://newline' -Infrastructure $script:Infra }) | Should -Be 'EmptySecret'
    }
    It 'fails with FileUnsafe for text that is not UTF-8' {
        $null = New-SecretFile -Directory $script:Dir -Name 'latin1' -Bytes ([byte[]](0x70, 0x61, 0xE4, 0x73, 0x73))
        Get-Category (Get-Failure { Get-AzlSecretValue 'file://latin1' -Infrastructure $script:Infra }) | Should -Be 'FileUnsafe'
    }
    It 'fails with TooLarge for a file over 256 KiB' {
        $null = New-SecretFile -Directory $script:Dir -Name 'big' -Bytes ([byte[]]::new(256KB + 1))
        Get-Category (Get-Failure { Get-AzlSecretValue 'file://big' -Infrastructure $script:Infra }) | Should -Be 'TooLarge'
    }
    It 'refuses a link' {
        $target = New-SecretFile -Directory $script:Dir -Name 'real' -Bytes (Get-Utf8 $script:Canary)
        try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $script:Dir 'linked') -Target $target -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'this account cannot create a symbolic link'; return }
        Get-Category (Get-Failure { Get-AzlSecretValue 'file://linked' -Infrastructure $script:Infra }) | Should -Be 'FileUnsafe'
    }
    It 'refuses a reserved device name' -Skip:(-not $IsWindows) {
        $f = Get-Failure { Get-AzlSecretValue 'file://CON' -Infrastructure $script:Infra }
        Get-Category $f | Should -Be 'InvalidReference'
        $f.Data['AzlExit'] | Should -Be 2
    }
    It 'is a NotConfigured input error (exit 2) without secrets.file.directory' {
        $f = Get-Failure { Get-AzlSecretValue 'file://lcm-password' -Infrastructure (New-Infra) }
        Get-Category $f | Should -Be 'NotConfigured'
        $f.Data['AzlExit'] | Should -Be 2
        $f.Message | Should -Match 'secrets.file.directory'
    }
    It 'is a NotConfigured input error when the directory is not absolute' {
        Get-Category (Get-Failure { Get-AzlSecretValue 'file://x' -Infrastructure (New-Infra -Directory 'relative\dir') }) | Should -Be 'NotConfigured'
    }
    It 'does not warn for a file only its owner can read' {
        $null = New-SecretFile -Directory $script:Dir -Name 'private' -Bytes (Get-Utf8 $script:Canary)
        $w = Get-AzlSecretValue 'file://private' -Infrastructure $script:Infra 3>&1 | Where-Object { $_ -is [Management.Automation.WarningRecord] }
        $w | Should -BeNullOrEmpty
    }
    It 'warns, without the value, when Everyone can read the file (Windows)' -Skip:(-not $IsWindows) {
        $p = New-SecretFile -Directory $script:Dir -Name 'open' -Bytes (Get-Utf8 $script:Canary)
        $null = & icacls.exe $p /grant '*S-1-1-0:(R)'
        $LASTEXITCODE | Should -Be 0
        $out = Get-AzlSecretValue 'file://open' -Infrastructure $script:Infra 3>&1
        $w = @($out | Where-Object { $_ -is [Management.Automation.WarningRecord] })
        $w.Count | Should -Be 1
        $w[0].Message | Should -Match 'file://open'
        $w[0].Message | Should -Not -Match $script:Canary
        ($out | Where-Object { $_ -is [securestring] }) | Should -Not -BeNullOrEmpty -Because 'a warning does not stop the read'
    }
    It 'warns when group or other can read the file (Linux, macOS)' -Skip:($IsWindows) {
        $p = New-SecretFile -Directory $script:Dir -Name 'open' -Bytes (Get-Utf8 $script:Canary)
        [IO.File]::SetUnixFileMode($p, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::OtherRead)
        $w = @(Get-AzlSecretValue 'file://open' -Infrastructure $script:Infra 3>&1 | Where-Object { $_ -is [Management.Automation.WarningRecord] })
        $w.Count | Should -Be 1
    }
}

Describe 'Command provider' {
    It 'starts the command with the arguments, replaces {name}, and reads stdout as the secret (trailing line break removed)' {
        $infra = New-CommandInfra 'Write-Output "cmd-{name}-secret"' 20
        ConvertTo-Plain (Get-AzlSecretValue 'command://lcm-password' -Infrastructure $infra) | Should -BeExactly 'cmd-lcm-password-secret'
    }
    It 'passes each argument as one argument: no shell, no splitting, no expansion' {
        $script = Join-Path $TestDrive 'echo-args.ps1'
        Set-Content -LiteralPath $script -Value '[Console]::Out.Write(($args -join "|"))'
        $infra = New-Infra -Arguments @('-NoProfile', '-NonInteractive', '-File', $script, '{name}', 'x y "quoted"', '; echo injected', '$(whoami)', '--{name}--') -Timeout 20
        ConvertTo-Plain (Get-AzlSecretValue 'command://lcm' -Infrastructure $infra) | Should -BeExactly 'lcm|x y "quoted"|; echo injected|$(whoami)|--lcm--'
    }
    It 'closes standard input, so a command that reads it does not wait' {
        $infra = New-CommandInfra '$in = [Console]::In.ReadToEnd(); [Console]::Out.Write("stdin-closed-{name}")' 20
        ConvertTo-Plain (Get-AzlSecretValue 'command://x' -Infrastructure $infra) | Should -BeExactly 'stdin-closed-x'
    }
    It 'fails with CommandFailed, the exit code and the standard error, but not the standard output' {
        $infra = New-CommandInfra '[Console]::Out.Write("STDOUT-VALUE-NOT-FOR-MESSAGES"); [Console]::Error.Write("denied for {name}"); exit 3' 20
        $f = Get-Failure { Get-AzlSecretValue 'command://lcm' -Infrastructure $infra }
        Get-Category $f | Should -Be 'CommandFailed'
        $f.Data['AzlExit'] | Should -Be 1
        $f.Message | Should -Match 'exit code 3'
        $f.Message | Should -Match 'denied for lcm'
        $f.Message | Should -Not -Match 'STDOUT-VALUE-NOT-FOR-MESSAGES'
    }
    It 'removes the secret from the standard error text' {
        $infra = New-CommandInfra "[Console]::Out.Write('$($script:Canary)'); [Console]::Error.Write('bad token $($script:Canary) for {name}'); exit 4" 20
        $f = Get-Failure { Get-AzlSecretValue 'command://lcm' -Infrastructure $infra }
        $f.Message | Should -Match 'bad token \*\*\* for lcm'
        $f.Message | Should -Not -Match $script:Canary
    }
    It 'cuts a long standard error to one short line' {
        $infra = New-CommandInfra '[Console]::Error.Write(("line`n" * 500)); exit 2' 20
        $f = Get-Failure { Get-AzlSecretValue 'command://lcm' -Infrastructure $infra }
        $f.Message.Length | Should -BeLessThan 600
        $f.Message | Should -Not -Match "`n"
    }
    It 'stops a command that runs too long (CommandTimeout)' {
        $infra = New-CommandInfra 'Start-Sleep -Seconds 60; Write-Output "{name}"' 1
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $f = Get-Failure { Get-AzlSecretValue 'command://slow' -Infrastructure $infra }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
        Get-Category $f | Should -Be 'CommandTimeout'
        $f.Message | Should -Match '1 seconds'
    }
    It 'fails with EmptySecret when the command prints nothing' {
        $infra = New-CommandInfra 'Write-Output ""; $null = "{name}"' 20
        Get-Category (Get-Failure { Get-AzlSecretValue 'command://lcm' -Infrastructure $infra }) | Should -Be 'EmptySecret'
    }
    It 'fails with NotConfigured (exit 2) when a setting is wrong: <Case>' -ForEach @(
        @{ Case = 'no command at all'; Infra = { New-Infra } }
        @{ Case = 'the executable is not found'; Infra = { New-Infra -Executable 'no-such-program-azl' -Arguments @('{name}') } }
        @{ Case = 'the executable is a relative path'; Infra = { New-Infra -Executable '.\tool.exe' -Arguments @('{name}') } }
        @{ Case = 'the absolute executable does not exist'; Infra = { New-Infra -Executable (Join-Path $TestDrive 'missing.exe') -Arguments @('{name}') } }
        @{ Case = 'no argument holds {name}'; Infra = { New-Infra -Arguments @('-NoProfile', '-Command', 'Write-Output fixed') } }
        @{ Case = 'the timeout is 0'; Infra = { New-CommandInfra 'Write-Output "{name}"' 0 } }
        @{ Case = 'the timeout is above 300'; Infra = { New-CommandInfra 'Write-Output "{name}"' 301 } }
    ) {
        $f = Get-Failure { Get-AzlSecretValue 'command://lcm' -Infrastructure (& $Infra) }
        Get-Category $f | Should -Be 'NotConfigured'
        $f.Data['AzlExit'] | Should -Be 2
    }
    It 'uses 30 seconds when the timeout is not set' {
        $infra = New-CommandInfra 'Write-Output "{name}"'
        ConvertTo-Plain (Get-AzlSecretValue 'command://ok' -Infrastructure $infra) | Should -BeExactly 'ok'
    }
}

Describe 'Key Vault provider' {
    BeforeEach {
        $script:Infra = New-Infra
        $script:Ref = "keyvault://$($script:Vault)/local-admin-password"
        Mock -ModuleName AzlSecret Get-AzContext { [pscustomobject]@{ Account = 'test' } }
        Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { [pscustomobject]@{ SecretValue = (New-Secure $script:Canary) } }
    }

    It 'reads the secret with Get-AzKeyVaultSecret and returns a SecureString' {
        $s = Get-AzlSecretValue -Reference $script:Ref -Infrastructure $script:Infra
        $s | Should -BeOfType ([securestring])
        ConvertTo-Plain $s | Should -Be $script:Canary
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSecret -Times 1 -Exactly -ParameterFilter { $VaultName -eq $script:Vault -and $Name -eq 'local-admin-password' -and -not $Version }
    }
    It 'passes a version when the reference has one' {
        $null = Get-AzlSecretValue -Reference "$($script:Ref)/0123456789abcdef0123456789abcdef" -Infrastructure $script:Infra
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSecret -Times 1 -Exactly -ParameterFilter { $Version -eq '0123456789abcdef0123456789abcdef' }
    }
    It 'matches the vault name in key_vaults without regard to letter case' {
        $null = Get-AzlSecretValue -Reference 'keyvault://KV-IIC-MGMT-01/x' -Infrastructure $script:Infra
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSecret -Times 1 -Exactly
    }
    It 'refuses a vault that is not listed in key_vaults as an input error, and does not call Azure' {
        $f = Get-Failure { Get-AzlSecretValue 'keyvault://kv-unlisted-01/x' -Infrastructure $script:Infra }
        Get-Category $f | Should -Be 'VaultNotListed'
        $f.Data['AzlExit'] | Should -Be 2
        $f.Message | Should -Match 'kv-unlisted-01'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSecret -Times 0 -Exactly
        Should -Invoke Get-AzContext -ModuleName AzlSecret -Times 0 -Exactly
    }
    It 'refuses every vault when key_vaults is missing' {
        $f = Get-Failure { Get-AzlSecretValue $script:Ref -Infrastructure ([ordered]@{}) }
        Get-Category $f | Should -Be 'VaultNotListed'
    }
    It 'fails with NotSignedIn when there is no Azure context, and does not read' {
        Mock -ModuleName AzlSecret Get-AzContext { $null }
        $f = Get-Failure { Get-AzlSecretValue $script:Ref -Infrastructure $script:Infra }
        Get-Category $f | Should -Be 'NotSignedIn'
        $f.Data['AzlExit'] | Should -Be 1
        $f.Message | Should -Match 'Connect-AzAccount'
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSecret -Times 0 -Exactly
    }
    It 'fails with SecretNotFound when Key Vault returns nothing' {
        Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { $null }
        $f = Get-Failure { Get-AzlSecretValue $script:Ref -Infrastructure $script:Infra }
        Get-Category $f | Should -Be 'SecretNotFound'
        $f.Message | Should -Match 'local-admin-password'
    }
    It 'classifies the Azure error "<Message>" as <Category>' -ForEach @(
        @{ Message = 'Operation returned an invalid status code ''Forbidden'''; Category = 'AccessDenied' }
        @{ Message = 'The user, group or application ''appid=...'' does not have secrets get permission on key vault ''kv'''; Category = 'AccessDenied' }
        @{ Message = 'Operation returned an invalid status code ''Unauthorized'''; Category = 'NotSignedIn' }
        @{ Message = 'Run Connect-AzAccount to login.'; Category = 'NotSignedIn' }
        @{ Message = 'No such host is known. (kv-iic-mgmt-01.vault.azure.net:443)'; Category = 'VaultNotFound' }
        @{ Message = 'Vault kv-iic-mgmt-01 was not found.'; Category = 'VaultNotFound' }
        @{ Message = 'SecretNotFound: A secret with (name/id) x was not found in this key vault.'; Category = 'SecretNotFound' }
        @{ Message = 'something else entirely'; Category = 'KeyVaultError' }
    ) {
        Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw $Message }
        $f = Get-Failure { Get-AzlSecretValue $script:Ref -Infrastructure $script:Infra }
        Get-Category $f | Should -Be $Category
    }
    It 'does not repeat the text of an unclassified Azure error' {
        Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw "RAW-AZURE-TEXT $($script:Canary)" }
        $f = Get-Failure { Get-AzlSecretValue $script:Ref -Infrastructure $script:Infra }
        Get-Category $f | Should -Be 'KeyVaultError'
        $f.Message | Should -Not -Match 'RAW-AZURE-TEXT'
        $f.Message | Should -Not -Match $script:Canary
        $f.InnerException | Should -BeNullOrEmpty
    }
    It 'fails with EmptySecret for an empty secret' {
        Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { [pscustomobject]@{ SecretValue = [securestring]::new() } }
        Get-Category (Get-Failure { Get-AzlSecretValue $script:Ref -Infrastructure $script:Infra }) | Should -Be 'EmptySecret'
    }
    It 'has no Azure CLI fallback: a failed read does not start az' {
        Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw 'something else entirely' }
        Mock -ModuleName AzlSecret Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        $null = Get-Failure { Get-AzlSecretValue $script:Ref -Infrastructure $script:Infra }
        Should -Invoke Get-Command -ModuleName AzlSecret -Times 0 -Exactly -ParameterFilter { $Name -eq 'az' }
    }
}

Describe 'Input errors that are the same for every provider' {
    BeforeAll { $script:Infra = New-Infra }

    It 'a text that is not a reference is an InvalidReference input error (exit 2)' {
        $f = Get-Failure { Get-AzlSecretValue 'just-a-plain-password' -Infrastructure $script:Infra }
        Get-Category $f | Should -Be 'InvalidReference'
        $f.Data['AzlExit'] | Should -Be 2
    }
    It 'treats null and empty as not a reference' {
        Get-Category (Get-Failure { Get-AzlSecretValue $null -Infrastructure $script:Infra }) | Should -Be 'InvalidReference'
        Get-Category (Get-Failure { Get-AzlSecretValue '' -Infrastructure $script:Infra }) | Should -Be 'InvalidReference'
    }
    It 'needs the infrastructure file' {
        Get-Category (Get-Failure { Get-AzlSecretValue 'env://X' -Infrastructure $null }) | Should -Be 'NotConfigured'
    }
    It 'an error from outside the module is reported as Unexpected, without its text' {
        Mock -ModuleName AzlSecret Get-AzlEnvironmentSecureValue { throw "OUTSIDE-TEXT $($script:Canary)" }
        $f = Get-Failure { Get-AzlSecretValue 'env://X' -Infrastructure $script:Infra }
        Get-Category $f | Should -Be 'Unexpected'
        $f.Message | Should -Not -Match 'OUTSIDE-TEXT'
        $f.Message | Should -Not -Match $script:Canary
    }
}

Describe 'Test-AzlSecretReference (pre-flight)' {
    BeforeEach {
        $script:Dir = New-SecretDirectory
        $script:Infra = New-Infra -Directory $script:Dir
        $env:AZL_TEST_SECRET = $script:Canary
    }
    AfterEach { Remove-Item Env:AZL_TEST_SECRET -ErrorAction SilentlyContinue }

    It 'returns $true for a reference that can be read, and nothing else' {
        $r = Test-AzlSecretReference 'env://AZL_TEST_SECRET' -Infrastructure $script:Infra
        $r | Should -BeOfType ([bool])
        $r | Should -BeTrue
    }
    It 'returns $false, not an exception, for a reference that cannot be read' {
        Test-AzlSecretReference 'env://AZL_NOT_SET_ANYWHERE' -Infrastructure $script:Infra | Should -BeFalse
        Test-AzlSecretReference 'file://missing' -Infrastructure $script:Infra | Should -BeFalse
    }
    It 'returns $false for text that is not a reference' {
        Test-AzlSecretReference 'plain' -Infrastructure $script:Infra | Should -BeFalse
    }
    It 'with -Detailed returns the provider, the result and the category, and no value' {
        $d = Test-AzlSecretReference 'env://AZL_TEST_SECRET' -Infrastructure $script:Infra -Detailed
        $d.Provider | Should -Be 'env'
        $d.Resolvable | Should -BeTrue
        $d.Reference | Should -Be 'env://AZL_TEST_SECRET'
        ($d | ConvertTo-Json -Depth 5) | Should -Not -Match $script:Canary
        $bad = Test-AzlSecretReference 'file://missing' -Infrastructure $script:Infra -Detailed
        $bad.Resolvable | Should -BeFalse
        $bad.Category | Should -Be 'FileNotFound'
    }
    It 'does not echo a text that is not a reference, even a password pasted by mistake' {
        $d = Test-AzlSecretReference $script:Canary -Infrastructure $script:Infra -Detailed
        $d.Category | Should -Be 'InvalidReference'
        ($d | ConvertTo-Json -Depth 5) | Should -Not -Match $script:Canary
        $d.Reference | Should -Not -Match $script:Canary
    }
    It 'proves a Key Vault reference without a sign-in call to Azure when Get-AzKeyVaultSecret is mocked' {
        Mock -ModuleName AzlSecret Get-AzContext { [pscustomobject]@{ Account = 'test' } }
        Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { [pscustomobject]@{ SecretValue = (New-Secure $script:Canary) } }
        Test-AzlSecretReference "keyvault://$($script:Vault)/x" -Infrastructure $script:Infra | Should -BeTrue
    }
}

Describe 'The default provider and New-AzlSecretReference' {
    It 'is keyvault when secrets.provider is not set' {
        Get-AzlSecretDefaultProvider -Infrastructure (New-Infra) | Should -Be 'keyvault'
    }
    It 'reads secrets.provider' {
        $infra = New-Infra; $infra.secrets = [ordered]@{ provider = 'file' }
        Get-AzlSecretDefaultProvider -Infrastructure $infra | Should -Be 'file'
    }
    It 'refuses an unknown provider as an input error' {
        $infra = New-Infra; $infra.secrets = [ordered]@{ provider = 'registry' }
        $f = Get-Failure { Get-AzlSecretDefaultProvider -Infrastructure $infra }
        Get-Category $f | Should -Be 'NotConfigured'
        $f.Data['AzlExit'] | Should -Be 2
    }
    It 'builds a Key Vault reference with the only listed vault' {
        New-AzlSecretReference -Name 'lcm-password' -Infrastructure (New-Infra) | Should -Be "keyvault://$($script:Vault)/lcm-password"
    }
    It 'needs -Vault when key_vaults lists more than one' {
        $infra = New-Infra -Vaults @('kv-iic-mgmt-01', 'kv-iic-mgmt-02')
        Get-Category (Get-Failure { New-AzlSecretReference -Name 'x' -Infrastructure $infra }) | Should -Be 'NotConfigured'
        New-AzlSecretReference -Name 'x' -Vault 'kv-iic-mgmt-02' -Infrastructure $infra | Should -Be 'keyvault://kv-iic-mgmt-02/x'
    }
    It 'builds a reference in the default provider, or in the one named' {
        $infra = New-Infra; $infra.secrets = [ordered]@{ provider = 'file' }
        New-AzlSecretReference -Name 'lcm-password' -Infrastructure $infra | Should -Be 'file://lcm-password'
        New-AzlSecretReference -Name 'AZL_X' -Provider env -Infrastructure $infra | Should -Be 'env://AZL_X'
        New-AzlSecretReference -Name 'lcm' -Provider command -Infrastructure $infra | Should -Be 'command://lcm'
    }
    It 'refuses a name that cannot be part of a reference' {
        $infra = New-Infra; $infra.secrets = [ordered]@{ provider = 'file' }
        Get-Category (Get-Failure { New-AzlSecretReference -Name '..\x' -Infrastructure $infra }) | Should -Be 'InvalidReference'
    }
}

Describe 'No secret value leaks' {
    BeforeEach {
        $script:Dir = New-SecretDirectory
        $null = New-SecretFile -Directory $script:Dir -Name 'lcm-password' -Bytes (Get-Utf8 "$($script:Canary)`n")
        $script:Infra = New-Infra -Directory $script:Dir -Arguments @('-NoProfile', '-NonInteractive', '-Command', "[Console]::Out.Write('$($script:Canary)')")
        $env:AZL_TEST_SECRET = $script:Canary
        Mock -ModuleName AzlSecret Get-AzContext { [pscustomobject]@{ Account = 'test' } }
        Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { [pscustomobject]@{ SecretValue = (New-Secure $script:Canary) } }
    }
    AfterEach { Remove-Item Env:AZL_TEST_SECRET -ErrorAction SilentlyContinue }

    It 'writes nothing with the value to the verbose, debug, information, warning or error streams: <Ref>' -ForEach @(
        @{ Ref = 'env://AZL_TEST_SECRET' }
        @{ Ref = 'file://lcm-password' }
        @{ Ref = 'command://lcm' }
        @{ Ref = 'keyvault://kv-iic-mgmt-01/x' }
    ) {
        $ref = $Ref
        $text = Get-StreamText { Get-AzlSecretValue $ref -Infrastructure $script:Infra -Verbose -Debug -InformationAction Continue -WarningAction Continue }
        $text | Should -Match ([regex]::Escape($ref)) -Because 'the verbose line names the reference'
        $text | Should -Not -Match $script:Canary
        $text = Get-StreamText { Get-AzlSecretPlainText $ref -Infrastructure $script:Infra -Verbose -Debug -InformationAction Continue -WarningAction Continue | Out-Null }
        $text | Should -Not -Match $script:Canary
        $text = Get-StreamText { Test-AzlSecretReference $ref -Infrastructure $script:Infra -Detailed -Verbose -Debug -InformationAction Continue -WarningAction Continue | ConvertTo-Json | Write-Output }
        $text | Should -Not -Match $script:Canary
    }

    It 'returns only a SecureString from Get-AzlSecretValue, and its text form does not show the value' {
        $s = Get-AzlSecretValue 'env://AZL_TEST_SECRET' -Infrastructure $script:Infra
        @($s).Count | Should -Be 1
        $s | Should -BeOfType ([securestring])
        "$s" | Should -Not -Match $script:Canary
        ($s | Out-String) | Should -Not -Match $script:Canary
    }

    It 'does not put the value in any error, whatever fails: <Case>' -ForEach @(
        @{ Case = 'a pasted password as the reference'; Block = { Get-AzlSecretValue $script:Canary -Infrastructure $script:Infra } }
        @{ Case = 'a pasted password with a scheme-like prefix'; Block = { Get-AzlSecretValue "file://$($script:Canary)/x" -Infrastructure $script:Infra } }
        @{ Case = 'a missing file'; Block = { Get-AzlSecretValue 'file://nothing-here' -Infrastructure $script:Infra } }
        @{ Case = 'a failing command that prints the value'; Block = { Get-AzlSecretValue 'command://x' -Infrastructure (New-CommandInfra "[Console]::Out.Write('$($script:Canary)'); [Console]::Error.Write('$($script:Canary)'); exit 9" 20) } }
        @{ Case = 'a Key Vault error carrying the value'; Block = { Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw "oops $($script:Canary)" }; Get-AzlSecretValue 'keyvault://kv-iic-mgmt-01/x' -Infrastructure $script:Infra } }
        @{ Case = 'an unlisted vault'; Block = { Get-AzlSecretValue 'keyvault://kv-other-01/x' -Infrastructure $script:Infra } }
    ) {
        $text = Get-StreamText $Block
        $text | Should -Not -BeNullOrEmpty
        $text | Should -Not -Match $script:Canary
    }

    It 'reports only the length of text that is not a reference' {
        $f = Get-Failure { Get-AzlSecretValue $script:Canary -Infrastructure $script:Infra }
        $f.Message | Should -Match "$($script:Canary.Length) characters"
    }
}

Describe 'The module text' {
    BeforeAll {
        $tokens = $null; $errors = $null
        $script:Ast = [Management.Automation.Language.Parser]::ParseFile($script:ModulePath, [ref]$tokens, [ref]$errors)
        $script:ParseErrors = $errors
        $script:Source = Get-Content -LiteralPath $script:ModulePath -Raw
        $script:Commands = @($script:Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
        $script:CommandNames = @($script:Commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }

    It 'parses without errors' { $script:ParseErrors | Should -BeNullOrEmpty }
    It 'has the standard header' {
        $script:Source | Should -Match '(?m)^#Requires -Version 7\.0'
        $script:Source | Should -Match '(?m)^Set-StrictMode -Version Latest'
        $script:Source | Should -Match "(?m)^\`$ErrorActionPreference = 'Stop'"
    }
    It 'documents the design in its top comment: reference forms, security rules, error behaviour' {
        $head = $script:Source.Substring(0, [Math]::Min($script:Source.Length, 9000))
        $head | Should -Match 'keyvault://<vault>/<secret>'
        $head | Should -Match 'env://<VARIABLE_NAME>'
        $head | Should -Match 'file://<name>'
        $head | Should -Match 'command://<name>'
        $head | Should -Match 'Security rules'
        $head | Should -Match 'Error behaviour'
    }
    It 'never calls Invoke-Expression or its alias' {
        $script:CommandNames | Should -Not -Contain 'Invoke-Expression'
        $script:CommandNames | Should -Not -Contain 'iex'
    }
    It 'never calls Write-Host' { $script:CommandNames | Should -Not -Contain 'Write-Host' }
    It 'never calls ConvertFrom-SecureString' { $script:CommandNames | Should -Not -Contain 'ConvertFrom-SecureString' }
    It 'never uses -AsPlainText (ConvertTo-SecureString, Get-AzKeyVaultSecret)' {
        $names = @($script:Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandParameterAst] }, $true) | ForEach-Object ParameterName)
        $names | Should -Not -Contain 'AsPlainText'
        $script:CommandNames | Should -Not -Contain 'ConvertTo-SecureString'
    }
    It 'does not start the Azure CLI or any shell' {
        foreach ($n in 'az', 'cmd', 'cmd.exe', 'sh', 'bash', 'powershell', 'pwsh', 'Start-Process') { $script:CommandNames | Should -Not -Contain $n }
        $script:Source | Should -Not -Match 'UseShellExecute\s*=\s*\$true'
    }
    It 'writes no log line from a variable that holds a value' {
        $valueVariables = 'text', 'value', 'stdout', 'stderr', 'secure', 'bytes', 'plain', 'item', 'detail'
        $writers = @($script:Commands | Where-Object { $_.GetCommandName() -in 'Write-Verbose', 'Write-Debug', 'Write-Information', 'Write-Warning', 'Write-Output', 'Write-Error' })
        $writers.Count | Should -BeGreaterThan 0
        foreach ($w in $writers) {
            $used = @($w.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath.ToLowerInvariant() })
            $used | Where-Object { $_ -in $valueVariables } | Should -BeNullOrEmpty -Because $w.Extent.Text
        }
    }
    It 'exports exactly the public functions' {
        (Get-Module AzlSecret).ExportedFunctions.Keys | Sort-Object | Should -Be (@('Get-AzlSecretDefaultProvider', 'Get-AzlSecretPlainText', 'Get-AzlSecretProvider', 'Get-AzlSecretValue', 'New-AzlSecretReference', 'Test-AzlSecretReference') | Sort-Object)
    }
    It 'reads only keys that exist in the registry: <_>' -ForEach 'secrets.provider', 'secrets.file.directory', 'secrets.command.executable', 'secrets.command.arguments', 'secrets.command.timeout_seconds', 'key_vaults' {
        $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
        $parts = $_.Split('.')
        $parts[-1] | Should -Not -BeNullOrEmpty
        $registry | Should -Match "(?m)^\s+$([regex]::Escape($parts[-1])):"
        $script:Source | Should -Match "'$([regex]::Escape($_))'"
    }
}
