#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the second review of the remote management profiles, bootstrap side: F5 (a class without an HTTP window gets no HTTP listener and no
# 5985 rule from the bootstrap), F6 (the smb result file has a name per run, a stale file is deleted first, the result carries a nonce, the file
# is deleted after), F7 (the bootstrap touches only rules that allow exactly 5985 or exactly 5986). sc.exe, net use and Azure are fakes.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/RemotingBootstrap.Review2.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A made-up test password.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake script blocks take the parameters the real ones are called with.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $common = Join-Path (Join-Path $repo 'scripts') 'common'
    foreach ($m in 'AzlRemotingProfile', 'AzlRemotingSession', 'AzlRemotingBootstrap') { Import-Module (Join-Path (Join-Path $common 'remoting') "$m.psm1") -Force }
    Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
    Import-Module powershell-yaml
    $script:Example = Join-Path (Join-Path (Join-Path (Join-Path $repo 'config') 'variables') 'examples') 'infrastructure.example.yml'
    $script:Credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'Tr0ub4dor&3-test-only' -AsPlainText -Force))
    $script:Thumb = 'AB' * 20

    function Resolve-For([string]$Class, [string]$Bootstrap = 'smb') {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        $doc.scenario.environment_class = $Class
        $doc.os_configuration.remoting.bootstrap_transport = $Bootstrap
        $doc.os_configuration.remoting.certificate = $script:Thumb
        Resolve-AzlRemotingProfile -Infrastructure $doc -Override @{ approved_bootstrap = $true; approved_bootstrap_source = 'parameter' }
    }
    function Get-FakeSmb([bool]$FileThere = $false, [string]$ResultText = '') {
        $w = @{ Log = [System.Collections.Generic.List[string]]::new(); FileExists = $FileThere; Result = $ResultText }
        $w.Sc = { param($Arguments) $verb = $Arguments[1]; $w.Log.Add("sc $verb"); if ($verb -eq 'start') { $w.FileExists = $true }; [pscustomobject]@{ ExitCode = $(if ($verb -eq 'start') { 1053 } else { 0 }); Output = '' } }.GetNewClosure()
        $w.NetUse = { param($Arguments) $w.Log.Add('net use'); [pscustomobject]@{ ExitCode = 0; Output = '' } }.GetNewClosure()
        $w.PortTest = { param($a, $p) $true }
        $w.TestFile = { param($Path) $w.FileExists }.GetNewClosure()
        $w.ReadFile = { param($Path) $w.Log.Add('read'); $w.Result }.GetNewClosure()
        $w.DeleteFile = { param($Path) $w.Log.Add("delete $Path"); $w.FileExists = $false }.GetNewClosure()
        $w.Sleep = { param($Seconds) }
        $w
    }
    function Invoke-Smb($W, [string]$Name, [string]$Nonce) {
        $arguments = @{ Node = 'n1'; Address = '192.0.2.11'; Script = 'Write-Output ok'; Credential = $script:Credential; WaitSeconds = 4; Sc = $W.Sc; NetUse = $W.NetUse; PortTest = $W.PortTest; TestFile = $W.TestFile; ReadFile = $W.ReadFile; DeleteFile = $W.DeleteFile; Sleep = $W.Sleep; SkipPlatformCheck = $true }
        if ($Name) { $arguments.ResultName = $Name }
        if ($Nonce) { $arguments.Nonce = $Nonce }
        Invoke-AzlSmbBootstrap @arguments
    }
}

Describe 'F5: no HTTP window, no HTTP from the bootstrap' {
    BeforeAll {
        $script:NoHttp = New-AzlRemotingBootstrapScript -RemoteAddress @('203.0.113.7/32') -Thumbprint $script:Thumb -Http $false -Nonce 'abcdef0123456789'
        $script:WithHttp = New-AzlRemotingBootstrapScript -RemoteAddress @('192.0.2.0/24') -Http $true
    }
    It 'with Http false it removes the HTTP listener, switches the 5985 rules off, and runs no unconditional Enable-PSRemoting' {
        $script:NoHttp | Should -Match 'Transport=HTTP"\}\|%\{Remove-Item'
        $script:NoHttp | Should -Match 'foreach\(\$r in \$h\)\{Set-NetFirewallRule -Name \$r -Enabled False\}'
        $script:NoHttp | Should -Not -Match 'if\(-not @\(Get-ChildItem WSMan:\\localhost\\Listener -EA 0\)\.Count\)\{Enable-PSRemoting'
        $script:NoHttp | Should -Match 'Get-PSSessionConfiguration'
    }
    It 'the HTTP listener goes only after the HTTPS one is created' {
        $script:NoHttp.IndexOf('New-WSManInstance') | Should -BeGreaterThan 0
        $script:NoHttp.IndexOf('Remove-Item') | Should -BeGreaterThan $script:NoHttp.IndexOf('New-WSManInstance')
    }
    It 'with Http true it is the script as before: Enable-PSRemoting when there is no listener, every WinRM rule scoped, nothing removed' {
        $script:WithHttp | Should -Match 'Enable-PSRemoting -Force -SkipNetworkProfileCheck'
        $script:WithHttp | Should -Match 'foreach\(\$r in \$n\)\{Set-NetFirewallRule -Name \$r -Enabled True -Profile Any -RemoteAddress \$ra\}'
        $script:WithHttp | Should -Not -Match 'Remove-Item'
    }
    It 'without an HTTP window and without a certificate thumbprint there is nothing to open: refused' {
        { New-AzlRemotingBootstrapScript -RemoteAddress @('203.0.113.7/32') -Http $false } | Should -Throw '*thumbprint*'
    }
    It 'both variants parse, with no 7-only syntax, and fit a service command line' {
        foreach ($text in $script:NoHttp, $script:WithHttp) {
            $e = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$e)
            $e | Should -BeNullOrEmpty
            $text | Should -Not -Match '\?\?|&&|\|\|'
        }
        $full = New-AzlRemotingBootstrapScript -RemoteAddress @('192.0.2.0/24', '198.51.100.10/32') -Rdp $true -RdpRemoteAddress @('192.0.2.0/24') -Icmp $true -IcmpRemoteAddress @('192.0.2.0/24') -Thumbprint $script:Thumb -Http $false -Nonce ('ab' * 16) -ResultPath 'C:\Windows\Temp\azl-bootstrap-0123456789abcdef0123456789abcdef.txt'
        (Get-AzlBootstrapCommandLine -Script $full).Length | Should -BeLessThan 7800
    }
    It 'dmz: the profile has no HTTP window, so the scripts the routes get are the HTTPS-only ones' {
        $script:seen = $null
        $p = Resolve-For 'dmz'
        $r = Invoke-AzlWinRmBootstrap -RemotingProfile $p -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -ApprovedBootstrap -Thumbprint $script:Thumb -SmbCommand { param($Node, $Address, $Script, $Account) $script:seen = $Script; [pscustomobject]@{ Route = 'smb'; Ok = $true; Reason = ''; Result = [pscustomobject]@{ ok = $true } } }
        $r.Ok | Should -BeTrue
        $script:seen | Should -Match 'Remove-Item'
        $script:seen | Should -Match 'Enabled False'
    }
    It 'dmz without a thumbprint fails cleanly instead of opening HTTP' {
        $r = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'dmz') -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -ApprovedBootstrap -SmbCommand { throw 'must not run' }
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'never opens HTTP'
    }
    It 'production keeps the bootstrap window: HTTP is opened, and later removed by the RemoteManagement step' {
        $script:seen = $null
        $null = Invoke-AzlWinRmBootstrap -RemotingProfile (Resolve-For 'production') -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -ApprovedBootstrap -SmbCommand { param($Node, $Address, $Script, $Account) $script:seen = $Script; [pscustomobject]@{ Route = 'smb'; Ok = $true; Reason = ''; Result = $null } }
        $script:seen | Should -Match 'Enable-PSRemoting'
        $script:seen | Should -Not -Match 'Remove-Item'
    }
}

Describe 'F7: the bootstrap script touches only rules that are exactly WinRM' {
    It 'finds the rules by an exact LocalPort of 5985 or of 5986, not by a port list that merely contains one' {
        $s = New-AzlRemotingBootstrapScript -RemoteAddress @('Any')
        $s | Should -Match '@\(\$_\.LocalPort\)\.Count -eq 1'
        $s | Should -Match '"\$\(\$_\.LocalPort\)" -eq \$p'
        $s | Should -Not -Match '-contains "5985"'
        $s | Should -Match 'AzlOsConfig-\*'
    }
}

Describe 'F6: the smb result file' {
    It 'each script gets its own result path, a GUID name, never the old fixed one' {
        $a = New-AzlRemotingBootstrapScript -RemoteAddress @('Any')
        $b = New-AzlRemotingBootstrapScript -RemoteAddress @('Any')
        $a | Should -Match 'C:\\Windows\\Temp\\azl-bootstrap-[0-9a-f]{32}\.txt'
        $a | Should -Not -Match 'azl-bootstrap-winrm'
        $a | Should -Not -Be $b
    }
    It 'the script puts the nonce in its result line, and a bad nonce is refused' {
        (New-AzlRemotingBootstrapScript -RemoteAddress @('Any') -Nonce 'abcdef0123456789') | Should -Match 'nonce="abcdef0123456789"'
        { New-AzlRemotingBootstrapScript -RemoteAddress @('Any') -Nonce 'x";calc;"' } | Should -Throw '*nonce*'
    }
    It 'Read-AzlBootstrapResult with a nonce accepts only a result that carries it' {
        $line = 'AZLBOOT:{"ok":true,"nonce":"abcdef0123456789"}'
        (Read-AzlBootstrapResult -Text $line -Nonce 'abcdef0123456789').ok | Should -BeTrue
        Read-AzlBootstrapResult -Text $line -Nonce '0000000000000000' | Should -BeNullOrEmpty
        Read-AzlBootstrapResult -Text 'AZLBOOT:{"ok":true}' -Nonce 'abcdef0123456789' | Should -BeNullOrEmpty
        (Read-AzlBootstrapResult -Text 'AZLBOOT:{"ok":true}').ok | Should -BeTrue
    }
    It 'a result file that was already there is deleted BEFORE sc start, and what the run reads is the run''s own' {
        $name = 'azl-bootstrap-0123456789abcdef0123456789abcdef.txt'
        $w = Get-FakeSmb $true 'AZLBOOT:{"ok":true,"nonce":"0123456789abcdef"}'
        $r = Invoke-Smb $w $name '0123456789abcdef'
        $r.Ok | Should -BeTrue
        $log = @($w.Log)
        $first = ($log | Select-String -SimpleMatch 'delete' | Select-Object -First 1).LineNumber
        $log.IndexOf("delete \\192.0.2.11\C`$\Windows\Temp\$name") | Should -BeLessThan $log.IndexOf('sc start')
        $log | Should -Contain 'read'
        $first | Should -Not -BeNullOrEmpty
    }
    It 'a stale result with another nonce is not accepted, and the file is gone afterwards' {
        $name = 'azl-bootstrap-0123456789abcdef0123456789abcdef.txt'
        $w = Get-FakeSmb $false 'AZLBOOT:{"ok":true,"nonce":"deadbeefdeadbeef"}'
        $r = Invoke-Smb $w $name '0123456789abcdef'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'nonce'
        $w.FileExists | Should -BeFalse
    }
    It 'the file is deleted after it was read' {
        $name = 'azl-bootstrap-0123456789abcdef0123456789abcdef.txt'
        $w = Get-FakeSmb $false 'AZLBOOT:{"ok":true,"nonce":"0123456789abcdef"}'
        $null = Invoke-Smb $w $name '0123456789abcdef'
        $w.FileExists | Should -BeFalse
        @($w.Log | Where-Object { $_ -like 'delete *' }).Count | Should -Be 1
    }
    It 'a result file name this tool does not make is refused (no path trickery)' {
        $r = Invoke-Smb (Get-FakeSmb) '..\..\x.txt' ''
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'not one this tool makes'
    }
    It 'two runs use two different files and nonces' {
        $script:scripts = [System.Collections.Generic.List[string]]::new()
        $cmd = { param($Node, $Address, $Script, $Account) $script:scripts.Add($Script); [pscustomobject]@{ Route = 'smb'; Ok = $true; Reason = ''; Result = $null } }
        $p = Resolve-For 'lab'
        $null = Invoke-AzlWinRmBootstrap -RemotingProfile $p -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -SmbCommand $cmd
        $null = Invoke-AzlWinRmBootstrap -RemotingProfile $p -Node 'n1' -Address '192.0.2.11' -Credential $script:Credential -SmbCommand $cmd
        $names = @($script:scripts | ForEach-Object { [regex]::Match($_, 'azl-bootstrap-[0-9a-f]{32}\.txt').Value })
        $names[0] | Should -Not -BeNullOrEmpty
        $names[0] | Should -Not -Be $names[1]
        foreach ($s in $script:scripts) { $s | Should -Match 'nonce="[0-9a-f]{32}"' }
    }
}
