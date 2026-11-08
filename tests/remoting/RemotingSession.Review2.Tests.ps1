#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the second review of the remote management profiles, TrustedHosts side: F8 (exact mode takes only an IP address or a host name,
# never a wildcard or a list) and F9 (a hard kill during a lab or test run leaves '*' behind: the previous and applied values are written to a
# state file before the store is changed, and the next start puts the previous value back). A fake store: no machine setting is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/RemotingSession.Review2.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake script blocks take the parameters the real ones are called with.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $common = Join-Path (Join-Path $repo 'scripts') 'common'
    foreach ($m in 'AzlRemotingProfile', 'AzlRemotingSession') { Import-Module (Join-Path (Join-Path $common 'remoting') "$m.psm1") -Force }
    Import-Module powershell-yaml
    $script:Example = Join-Path (Join-Path (Join-Path $repo 'config') 'infrastructure') 'infrastructure.example.yml'

    function Resolve-For([string]$Class, [scriptblock]$Change, [hashtable]$Override = @{}) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        $doc.scenario.environment_class = $Class
        if ($Change) { & $Change $doc }
        Resolve-AzlRemotingProfile -Infrastructure $doc -Override $Override
    }
    # A TrustedHosts store that is a variable. With -StatePath it has the property the real store has; it records whether the state file was
    # there at the moment of every write.
    function Get-FakeStore([string]$Initial = '', [string]$StatePath = '') {
        $state = @{ Value = $Initial; Writes = [System.Collections.Generic.List[string]]::new(); FileThere = [System.Collections.Generic.List[bool]]::new() }
        $store = [pscustomobject]@{
            Supported = $true; State = $state
            Get       = { $state.Value }.GetNewClosure()
            Set       = { param($Value) $state.FileThere.Add([bool]($StatePath -and (Test-Path -LiteralPath $StatePath))); $state.Value = $Value; $state.Writes.Add($Value) }.GetNewClosure()
        }
        if ($StatePath) { $store | Add-Member -NotePropertyName StatePath -NotePropertyValue $StatePath }
        $store
    }
}

Describe 'F8: TrustedHosts exact mode takes an IP address or a host name only' {
    BeforeEach { Set-AzlRemotingEventSink -Reset -Confirm:$false }

    It '<Value> is refused, and nothing is written' -ForEach @(
        @{ Value = '*' }
        @{ Value = 'x,*' }
        @{ Value = '192.0.2.11,*' }
        @{ Value = '192.0.2.11;198.51.100.7' }
        @{ Value = '*.example.invalid' }
        @{ Value = 'node 1' }
        @{ Value = 'host$(calc)' }
        @{ Value = 'fe80::1%eth0' }
    ) {
        $store = Get-FakeStore 'keep.example.invalid'
        $caught = $null
        try { $null = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'dev') -Address @('192.0.2.11', $Value) -Store $store -Confirm:$false } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -Match 'TrustedHosts'
        $caught.Exception.Data['AzlInput'] | Should -BeTrue
        $store.State.Writes.Count | Should -Be 0
        $store.State.Value | Should -Be 'keep.example.invalid'
    }
    It '<Value> is accepted' -ForEach @(
        @{ Value = '192.0.2.11' }
        @{ Value = 'node01' }
        @{ Value = 'node01.example.invalid' }
        @{ Value = '2001:db8::5' }
        @{ Value = '[2001:db8::5]' }
    ) {
        $store = Get-FakeStore ''
        $s = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'dev') -Address @($Value) -Store $store -Confirm:$false
        $s.Changed | Should -BeTrue
        $store.State.Value | Should -Be $Value
    }
    It 'a value like x,* cannot become a wildcard entry' {
        $store = Get-FakeStore ''
        { Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'dev') -Address @('x,*') -Store $store -Confirm:$false } | Should -Throw
        $store.State.Value | Should -Not -Match '\*'
    }
}

Describe 'F9: a hard kill during a lab or test run leaves the wildcard behind: the next start puts the old value back' {
    BeforeEach {
        Set-AzlRemotingEventSink -Reset -Confirm:$false
        $script:StatePath = Join-Path $TestDrive ("th-{0}.json" -f [guid]::NewGuid().ToString('N'))
    }

    It 'writes the previous and the applied value to the state file BEFORE the store is changed' {
        $store = Get-FakeStore 'keep.example.invalid' $script:StatePath
        $null = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $store.State.FileThere[0] | Should -BeTrue -Because 'the file has to exist when the store is written'
        $file = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        $file.previous | Should -Be 'keep.example.invalid'
        $file.applied | Should -Be '*'
    }
    It 'a normal restore puts the value back and removes the state file' {
        $store = Get-FakeStore 'keep.example.invalid' $script:StatePath
        $s = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $null = Restore-AzlTrustedHostsPolicy -Session $s -Store $store -Confirm:$false
        $store.State.Value | Should -Be 'keep.example.invalid'
        Test-Path -LiteralPath $script:StatePath | Should -BeFalse
    }
    It 'after a kill (no restore) the next start restores the old value first and never records the wildcard as the previous value' {
        $store = Get-FakeStore 'keep.example.invalid' $script:StatePath
        $null = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $store.State.Value | Should -Be '*'
        # the process died here: the finally block never ran
        $second = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false 3>$null
        $second.Previous | Should -Be 'keep.example.invalid'
        @($store.State.Writes) | Should -Be @('*', 'keep.example.invalid', '*')
        $null = Restore-AzlTrustedHostsPolicy -Session $second -Store $store -Confirm:$false
        $store.State.Value | Should -Be 'keep.example.invalid'
        Test-Path -LiteralPath $script:StatePath | Should -BeFalse
    }
    It 'a production start also cleans up what a killed lab run left, and sets nothing' {
        $store = Get-FakeStore 'keep.example.invalid' $script:StatePath
        $null = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $null = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'production') -Store $store -Confirm:$false 3>$null
        $store.State.Value | Should -Be 'keep.example.invalid'
        Test-Path -LiteralPath $script:StatePath | Should -BeFalse
    }
    It 'a value somebody changed after the kill is left alone, and the state file goes' {
        $store = Get-FakeStore 'keep.example.invalid' $script:StatePath
        $null = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $store.State.Value = 'someone-else.example.invalid'
        $null = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'production') -Store $store -Confirm:$false 3>$null
        $store.State.Value | Should -Be 'someone-else.example.invalid'
        Test-Path -LiteralPath $script:StatePath | Should -BeFalse
    }
    It 'a run that is still alive in another process is not undone' {
        $other = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -PassThru -WindowStyle Hidden
        try {
            $other.Refresh()
            $store = Get-FakeStore '*' $script:StatePath
            $record = [ordered]@{ previous = 'keep.example.invalid'; applied = '*'; processId = $other.Id; processStart = $other.StartTime.ToUniversalTime().Ticks; written = '2026-01-01T00:00:00Z' }
            New-Item -ItemType Directory -Force -Path (Split-Path $script:StatePath) | Out-Null
            Set-Content -LiteralPath $script:StatePath -Value ($record | ConvertTo-Json)
            $null = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'production') -Store $store -Confirm:$false 3>$null
            $store.State.Value | Should -Be '*' -Because 'the other run owns the wildcard'
            Test-Path -LiteralPath $script:StatePath | Should -BeTrue
        }
        finally { Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue }
    }
    It 'a damaged state file is removed with a warning and does not stop the run' {
        $store = Get-FakeStore 'keep.example.invalid' $script:StatePath
        Set-Content -LiteralPath $script:StatePath -Value '{ damaged'
        $s = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false 3>$null
        $s.Previous | Should -Be 'keep.example.invalid'
        $store.State.Value | Should -Be '*'
    }
    It 'a profile that keeps the value after the run writes no state file' {
        $store = Get-FakeStore 'keep.example.invalid' $script:StatePath
        $p = Resolve-For 'lab'
        $p.TrustedHosts.RestoreAfterRun = $false
        $null = Set-AzlTrustedHostsPolicy -RemotingProfile $p -Store $store -Confirm:$false
        Test-Path -LiteralPath $script:StatePath | Should -BeFalse
    }
    It 'a store without a state path (a test double) still works' {
        $store = Get-FakeStore 'keep.example.invalid'
        $s = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $null = Restore-AzlTrustedHostsPolicy -Session $s -Store $store -Confirm:$false
        $store.State.Value | Should -Be 'keep.example.invalid'
    }
    It 'the real store carries the state path in the common application data folder' -Skip:(-not $IsWindows) {
        $real = Get-AzlTrustedHostsStore
        $real.StatePath | Should -Match 'AzureLocal'
        $real.StatePath | Should -Match 'trustedhosts-state\.json$'
    }
}
