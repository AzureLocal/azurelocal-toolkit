#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The node payloads must give the same answer however they are started: as a script FILE (Arc Run Command, a scheduled task) and as a scriptblock created from
# text (what a remoting session used to do). A payload that keeps its results in $script: variables is empty as a scriptblock, with an empty err, and the plan
# then shows a node with no ports. These tests run the Read payload both ways in Windows PowerShell 5.1 (the node's shell) and compare.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/Payload.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A module mock runs in the module scope; a global is how it reports back to the test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transport members take the parameters of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A test credential for a transport object; it is never used.')]
param()

BeforeDiscovery {
    $script:HasWindowsPowerShell = [bool](Get-Command powershell.exe -ErrorAction SilentlyContinue)
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = [IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration')
    Import-Module (Join-Path $dir 'AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $dir 'AzlNodeTransport.psm1') -Force
    $script:ParamsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ mgmtMac = '' } | ConvertTo-Json -Compress)))

    # Runs payload text in Windows PowerShell 5.1 and returns the decoded AZLRESULT. -As File or ScriptBlock.
    function Invoke-PayloadInWindowsPowerShell([string]$Text, [ValidateSet('File', 'ScriptBlock')][string]$As) {
        $file = Join-Path $TestDrive "payload-$As-$([guid]::NewGuid().ToString('N').Substring(0, 6)).ps1"
        [IO.File]::WriteAllText($file, $Text, [Text.UTF8Encoding]::new($true))
        $output = if ($As -eq 'File') {
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file -ParamsB64 $script:ParamsB64 2>&1
        }
        else {
            $command = "& ([scriptblock]::Create([IO.File]::ReadAllText('$file'))) -ParamsB64 '$script:ParamsB64'"
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command 2>&1
        }
        ConvertTo-AzlNodeResult -Text (($output | ForEach-Object { "$_" }) -join "`n")
    }
}

Describe 'Node payloads work however they are started' {
    It 'keeps no result in a $script: variable (Read, Apply)' {
        foreach ($name in 'Read', 'Apply') {
            (Get-AzlNodePayload -Name $name) | Should -Not -Match '\$script:(err|nics|remote|time|sbe|drv|adm|stor|san|reboot)\b' -Because 'a scriptblock created from text has no script scope of its own'
        }
    }

    It 'the Read payload gives the same non-empty shape as a script file and as a scriptblock' -Skip:(-not $script:HasWindowsPowerShell) {
        $text = Get-AzlNodePayload -Name Read
        $file = Invoke-PayloadInWindowsPowerShell $text File
        $block = Invoke-PayloadInWindowsPowerShell $text ScriptBlock
        $file | Should -Not -BeNullOrEmpty
        $block | Should -Not -BeNullOrEmpty
        # the same sections are filled, whichever way it ran
        @($block.nics).Count | Should -Be @($file.nics).Count
        ($null -ne $block.remote) | Should -Be ($null -ne $file.remote)
        ($null -ne $block.time) | Should -Be ($null -ne $file.time)
        # and it is not an empty read with an empty err
        $filled = (@($file.nics).Count -gt 0) -or ($null -ne $file.remote) -or ($null -ne $file.time)
        if (-not $filled) { @($file.err.PSObject.Properties).Count | Should -BeGreaterThan 0 -Because 'a section with no data says why' }
        else { $file.time | Should -Not -BeNullOrEmpty; $file.host | Should -Not -BeNullOrEmpty }
        @($block.err.PSObject.Properties.Name | Sort-Object) | Should -Be @($file.err.PSObject.Properties.Name | Sort-Object)
    }

    It 'a section that returns no data records why in err' {
        $text = Get-AzlNodePayload -Name Read
        $text | Should -Match "Az\.err\['nics'\] = 'Get-NetAdapter -Physical returned no adapter"
        $text | Should -Match "Az\.err\['remote'\]"
        $text | Should -Match "Az\.err\['time'\]"
    }
}

Describe 'The host refuses a read that returned nothing' {
    It 'throws instead of planning against nothing' {
        $line = {
            param($Object)
            $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 6 -Compress))
            $ms = [IO.MemoryStream]::new(); $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress); $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
            'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
        }
        $empty = [pscustomobject]@{ v = 1; host = 'WIN-X'; boot = '2026-11-07T01:00:00Z'; nics = @(); remote = $null; time = $null; sbe = @(); drv = @(); admin = $null; stor = $null; san = $null; err = [pscustomobject]@{} }
        $transport = [pscustomobject]@{ Kind = 'WinRM'; Invoke = { param($Self, $Node, $Script, $Parameters, $Secrets, $TimeoutSeconds) [pscustomobject]@{ Output = (& $line $empty); Failed = $false; Error = ''; State = 'Succeeded' } }.GetNewClosure() }
        { Invoke-AzlNodeScript -Transport $transport -Node n1 -Script 'x' } | Should -Throw '*node read returned no data*'
    }

    It 'still returns a read that has data in at least one section' {
        $line = {
            param($Object)
            $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 6 -Compress))
            $ms = [IO.MemoryStream]::new(); $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress); $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
            'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
        }
        $some = [pscustomobject]@{ v = 1; host = 'WIN-X'; nics = @([pscustomobject]@{ n = 'Port0'; mac = '00005e005311' }); remote = $null; time = $null; err = [pscustomobject]@{} }
        $transport = [pscustomobject]@{ Kind = 'WinRM'; Invoke = { param($Self, $Node, $Script, $Parameters, $Secrets, $TimeoutSeconds) [pscustomobject]@{ Output = (& $line $some); Failed = $false; Error = ''; State = 'Succeeded' } }.GetNewClosure() }
        (Invoke-AzlNodeScript -Transport $transport -Node n1 -Script 'x').host | Should -Be 'WIN-X'
    }
}

Describe 'The WinRM transport runs the payload as a file in the session' {
    It 'creates a file on the node, runs it with the call operator, and removes it in finally; never a scriptblock from text' {
        $script:Captured = $null
        Mock -ModuleName AzlNodeTransport Get-AzlWinRmSession { 'session' }
        Mock -ModuleName AzlNodeTransport Invoke-Command -RemoveParameterType Session { $global:AzlSentBlock = $ScriptBlock.ToString(); $global:AzlSentArgs = $ArgumentList; '' }
        $t = New-AzlWinRmTransport -Address @{ n1 = '192.0.2.11' } -Credential ([pscredential]::new('u', (ConvertTo-SecureString 'x' -AsPlainText -Force)))
        $null = & $t.Invoke $t 'n1' 'PAYLOAD-TEXT' @{ a = 1 } @{ secret = 's' } 60
        $block = $global:AzlSentBlock
        $block | Should -Match '\.ps1'
        $block | Should -Match 'WriteAllText'
        $block | Should -Match 'UTF8Encoding\(\$true\)'
        $block | Should -Match 'Set-ExecutionPolicy Bypass -Scope Process'
        $block | Should -Match '& \$file -ParamsB64 \$ParamsB64 -SecretsB64 \$SecretsB64'
        $block | Should -Match 'finally \{ Remove-Item -LiteralPath \$file'
        $block | Should -Match 'icacls'
        $block | Should -Not -Match 'scriptblock\]::Create'
        $global:AzlSentArgs[0] | Should -Be 'PAYLOAD-TEXT'
        # the secret travels as an argument, not in the text of the script or on a command line
        ($global:AzlSentArgs -join ' ') | Should -Not -Match 'secret'
        Remove-Variable -Name AzlSentBlock, AzlSentArgs -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'A WinRM call that is abandoned after its timeout is indeterminate, not a plain failure' {
    It 'the transport reports State TimedOut and Invoke-AzlNodeScript throws an error marked Indeterminate (the script may have run)' {
        Mock -ModuleName AzlNodeTransport Get-AzlWinRmSession { 'session' }
        Mock -ModuleName AzlNodeTransport Invoke-Command -RemoveParameterType Session { [pscustomobject]@{ Id = 1 } }
        Mock -ModuleName AzlNodeTransport Wait-Job -RemoveParameterType Job { $null }
        Mock -ModuleName AzlNodeTransport Stop-Job -RemoveParameterType Job {}
        Mock -ModuleName AzlNodeTransport Remove-Job -RemoveParameterType Job {}
        Mock -ModuleName AzlNodeTransport Remove-PSSession -RemoveParameterType Session {}
        $t = New-AzlWinRmTransport -Address @{ n1 = '192.0.2.11' } -Credential ([pscredential]::new('u', (ConvertTo-SecureString 'x' -AsPlainText -Force)))
        $run = & $t.Invoke $t 'n1' 'PAYLOAD-TEXT' @{} @{} 30
        $run.Failed | Should -BeTrue
        $run.State | Should -Be 'TimedOut'
        $caught = $null
        try { Invoke-AzlNodeScript -Transport $t -Node n1 -Script 'x' -Tries 1 -TimeoutSeconds 30 } catch { $caught = $_ }
        $caught.Exception.Data['AzlState'] | Should -Be 'Indeterminate'
        $caught.Exception.Message | Should -Match 'INDETERMINATE'
        $caught.Exception.Message | Should -Match 'abandoned'
    }
}
