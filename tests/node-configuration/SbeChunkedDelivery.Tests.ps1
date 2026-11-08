#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the SBE package delivery over WinRM (hardware.sbe.delivery winrm_copy): 4 MiB chunks, one capped call per chunk written at an offset of a .part file, resume from the
# last verified chunk boundary, small files first, the SHA-256 of the whole file on the node, then the rename; progress every 5 percent; the real error in the report. The node-side
# operations (Length, PrefixHash, Write, Finish) RUN here for real, locally, against folders in TestDrive (they are Windows PowerShell 5.1 syntax, which pwsh runs too); nothing
# touches a node, the network or Azure.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/SbeChunkedDelivery.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester runs a module mock in the module scope; a global is how the mock reports back to the test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test fixture credential, not a secret.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transport and mock script blocks keep the signature of the real ones.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    foreach ($m in 'infrastructure\AzlInfrastructure', 'azure-local\AzlAzure', 'node-configuration\AzlNodePayload', 'node-configuration\AzlNodeTransport', 'node-configuration\AzlNodeGuard', 'node-configuration\AzlOsConfigurationEvents', 'node-configuration\AzlGuardedChange', 'node-configuration\AzlNodeConfiguration') {
        Import-Module (Join-Path $repo "scripts\common\$m.psm1") -Force
    }
    Import-Module powershell-yaml

    function New-TestFile([string]$Path, [int]$Size, [int]$Seed = 42) {
        $b = [byte[]]::new($Size); [Random]::new($Seed).NextBytes($b); [IO.File]::WriteAllBytes($Path, $b)
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    # The "node": the real node-side operations run locally. The context holds the log and the failure switches.
    $script:RealCall = {
        param($Context, $Op, $Arguments, $TimeoutSeconds)
        $Context.Log.Add([pscustomobject]@{ Op = $Op; Offset = $(if ($Arguments.ContainsKey('Offset')) { [long]$Arguments.Offset } else { -1 }); Count = $(if ($Arguments.ContainsKey('Bytes')) { $Arguments.Bytes.Length } else { 0 }); Timeout = $TimeoutSeconds })
        if ($Context.FailWrite -and $Op -eq 'Write' -and $Context.FailWrite.Invoke([long]$Arguments.Offset, $Context.Log.Count)) { throw 'The call to n1 did not finish within 75 seconds and was abandoned.' }
        & (Get-AzlWinRmFileOpBlock -Op $Op) $Arguments
    }
    $script:Chunk = 1000
}

Describe 'Send-AzlFileChunked' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive "sbe-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:dir 'local'), (Join-Path $script:dir 'node')
        $script:local = Join-Path $script:dir 'local\pkg.zip'
        $script:final = Join-Path $script:dir 'node\pkg.zip'
        $script:ctx = @{ Log = [System.Collections.Generic.List[object]]::new(); FailWrite = $null }
        $script:reports = [System.Collections.Generic.List[object]]::new()
        $script:report = { param($Context, $Percent, $Sent, $Total) $Context.Reports.Add([pscustomobject]@{ Percent = $Percent; Sent = $Sent; Total = $Total }) }
        $script:ctx.Reports = $script:reports
    }
    It 'sends the file in chunks of the chunk size, one capped call (60 s) per chunk, each written at its offset; the result equals the file' {
        $hash = New-TestFile $script:local 3500
        $r = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -ChunkBytes $script:Chunk -RetrySeconds 0
        $writes = @($script:ctx.Log | Where-Object Op -eq 'Write')
        $writes.Count | Should -Be 4
        @($writes | ForEach-Object Offset) | Should -Be @(0, 1000, 2000, 3000)
        @($writes | ForEach-Object Count) | Should -Be @(1000, 1000, 1000, 500)
        foreach ($w in $writes) { $w.Timeout | Should -Be 60 }
        (Get-FileHash -LiteralPath $script:final -Algorithm SHA256).Hash | Should -Be $hash
        Test-Path "$($script:final).part" | Should -BeFalse -Because 'the .part file takes its name only after the hash is right'
        $r.Sent | Should -Be 3500
    }
    It 'the default chunk is 4 MiB (9 MiB: 4, 4 and 1 MiB)' {
        $hash = New-TestFile $script:local (9MB)
        $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -RetrySeconds 0
        @($script:ctx.Log | Where-Object Op -eq 'Write' | ForEach-Object Count) | Should -Be @(4MB, 4MB, 1MB)
    }
    It 'the encoded and serialized size of a chunk stays under the 8 MiB mark (raw size times 1.37), well under the 10 MiB WinRM object limit' {
        (Get-AzlSbeChunkSize) * 1.37 | Should -BeLessOrEqual (8MB) -Because 'base64 and CLIXML make a byte[] about 1.37 times its size; 8 MiB raw arrived as 10.5 MB and failed'
        (Get-AzlSbeChunkSize) | Should -Be 4194304
        # measure the real thing: the CLIXML of a full chunk
        $xml = [System.Management.Automation.PSSerializer]::Serialize(@{ Part = 'p'; Offset = [long]0; Bytes = [byte[]]::new((Get-AzlSbeChunkSize)) })
        $xml.Length | Should -BeLessThan (8MB)
    }
    It 'the default chunk size of Send-AzlFileChunked is the checked constant' {
        (Get-Command Send-AzlFileChunked).Parameters['ChunkBytes'].ParameterType | Should -Be ([int])
        $hash = New-TestFile $script:local (Get-AzlSbeChunkSize)
        $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -RetrySeconds 0
        @($script:ctx.Log | Where-Object Op -eq 'Write').Count | Should -Be 1
    }
    It 'resume alignment follows the chunk size: a .part file of 6 MiB is resumed from the 4 MiB boundary (default chunk)' {
        $hash = New-TestFile $script:local (9MB)
        $bytes = [IO.File]::ReadAllBytes($script:local)
        [IO.File]::WriteAllBytes("$($script:final).part", $bytes[0..(6MB - 1)])
        $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -RetrySeconds 0
        @($script:ctx.Log | Where-Object Op -eq 'Write')[0].Offset | Should -Be 4MB
        (Get-FileHash -LiteralPath $script:final -Algorithm SHA256).Hash | Should -Be $hash
    }
    It 'reports progress every 5 percent, increasing, ending at 100' {
        $hash = New-TestFile $script:local 100000
        $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -ChunkBytes 1000 -Report $script:report -RetrySeconds 0
        $p = @($script:reports | ForEach-Object Percent)
        $p.Count | Should -Be 20
        $p[0] | Should -Be 5
        $p[-1] | Should -Be 100
        @($p | Sort-Object) | Should -Be $p
        $script:reports[-1].Sent | Should -Be 100000
        $script:reports[-1].Total | Should -Be 100000
    }
    It 'resumes from the existing .part file, cut to the last full chunk boundary, after checking it against the local file' {
        $hash = New-TestFile $script:local 5200
        # an earlier run left 3500 bytes (3 full chunks and a half) of the same file
        $bytes = [IO.File]::ReadAllBytes($script:local)
        [IO.File]::WriteAllBytes("$($script:final).part", $bytes[0..3499])
        $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -ChunkBytes 1000 -RetrySeconds 0
        $writes = @($script:ctx.Log | Where-Object Op -eq 'Write')
        $writes[0].Offset | Should -Be 3000 -Because '3500 bytes are cut back to the last 1000-byte boundary'
        $writes.Count | Should -Be 3
        @($script:ctx.Log | Where-Object Op -eq 'PrefixHash').Count | Should -Be 1
        (Get-FileHash -LiteralPath $script:final -Algorithm SHA256).Hash | Should -Be $hash
    }
    It 'does not resume from a .part file whose content differs from the local file: it starts again at 0' {
        $hash = New-TestFile $script:local 5200
        $bytes = [IO.File]::ReadAllBytes($script:local)
        $bad = $bytes[0..3499]; $bad[1500] = [byte](($bad[1500] + 1) % 256)
        [IO.File]::WriteAllBytes("$($script:final).part", $bad)
        $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -ChunkBytes 1000 -RetrySeconds 0
        @($script:ctx.Log | Where-Object Op -eq 'Write')[0].Offset | Should -Be 0
        (Get-FileHash -LiteralPath $script:final -Algorithm SHA256).Hash | Should -Be $hash
    }
    It 'a .part file longer than the source is not trusted either' {
        $hash = New-TestFile $script:local 2500
        [IO.File]::WriteAllBytes("$($script:final).part", [byte[]]::new(9000))
        $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -ChunkBytes 1000 -RetrySeconds 0
        @($script:ctx.Log | Where-Object Op -eq 'Write')[0].Offset | Should -Be 0
        (Get-FileHash -LiteralPath $script:final -Algorithm SHA256).Hash | Should -Be $hash
    }
    It 'a hash mismatch of the whole file throws with both hashes and removes the copy; the final file is not created' {
        $null = New-TestFile $script:local 2500
        $thrown = $null
        try { $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 ('0' * 64) -Node n1 -ChunkBytes 1000 -RetrySeconds 0 } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match 'SHA-256 is [0-9A-F]{64}, expected 0{64}'
        $thrown.Exception.Message | Should -Match 'pkg\.zip copied to n1'
        $thrown.Exception.Message | Should -Match 'the copy was removed'
        Test-Path "$($script:final).part" | Should -BeFalse
        Test-Path $script:final | Should -BeFalse
    }
    It 'a chunk that fails once is tried again from the verified boundary; the file still comes out right' {
        $hash = New-TestFile $script:local 4500
        $script:ctx.FailWrite = { param($Offset, $Calls) $Offset -eq 2000 -and -not $script:failedOnce -and ($script:failedOnce = $true) }
        $script:failedOnce = $false
        $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -ChunkBytes 1000 -RetrySeconds 0
        (Get-FileHash -LiteralPath $script:final -Algorithm SHA256).Hash | Should -Be $hash
        @($script:ctx.Log | Where-Object { $_.Op -eq 'Write' -and $_.Offset -eq 2000 }).Count | Should -Be 2
    }
    It 'a chunk that keeps failing stops after the failures in a row, and the error says the file, the node, the offset and the cause' {
        $null = New-TestFile $script:local 4500
        $script:ctx.FailWrite = { param($Offset, $Calls) $Offset -ge 2000 }
        $thrown = $null
        try { $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 '' -Node n1 -ChunkBytes 1000 -RetrySeconds 0 -MaxFailures 2 } catch { $thrown = $_ }
        $thrown.Exception.Message | Should -Match 'pkg\.zip'
        $thrown.Exception.Message | Should -Match 'n1'
        $thrown.Exception.Message | Should -Match '2000 of 4500'
        $thrown.Exception.Message | Should -Match 'did not finish within 75 seconds and was abandoned'
        @($script:ctx.Log | Where-Object { $_.Op -eq 'Write' -and $_.Offset -eq 2000 }).Count | Should -Be 3 -Because 'one try and two more'
        Test-Path $script:final | Should -BeFalse
    }
    It 'the failure message lists the chunk size and the MaxEnvelopeSizekb of the node when it can be read, and says so when it cannot' {
        $null = New-TestFile $script:local 3000
        $script:ctx.FailWrite = { param($Offset, $Calls) $true }
        $thrown = $null
        try { $null = Send-AzlFileChunked -Call { param($Context, $Op, $Arguments, $TimeoutSeconds) if ($Op -eq 'Envelope') { return '500' }; & $script:RealCall $Context $Op $Arguments $TimeoutSeconds } -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 '' -Node n1 -ChunkBytes 1000 -RetrySeconds 0 -MaxFailures 0 } catch { $thrown = $_ }
        $thrown.Exception.Message | Should -Match 'chunks of 1000 bytes'
        $thrown.Exception.Message | Should -Match 'MaxEnvelopeSizekb is 500'
        $thrown = $null
        try { $null = Send-AzlFileChunked -Call { param($Context, $Op, $Arguments, $TimeoutSeconds) if ($Op -eq 'Envelope') { throw 'no session' }; & $script:RealCall $Context $Op $Arguments $TimeoutSeconds } -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 '' -Node n1 -ChunkBytes 1000 -RetrySeconds 0 -MaxFailures 0 } catch { $thrown = $_ }
        $thrown.Exception.Message | Should -Match 'MaxEnvelopeSizekb could not be read'
        $thrown.Exception.Message | Should -Match 'did not finish within 75 seconds'
    }
    It 'the Envelope operation runs on the node block (a number or empty, never a throw)' {
        { & (Get-AzlWinRmFileOpBlock -Op Envelope) @{} } | Should -Not -Throw
    }
    It 'an empty file is a single finish (no chunk to write)' {
        $hash = New-TestFile $script:local 0
        $null = Send-AzlFileChunked -Call $script:RealCall -CallContext $script:ctx -LocalPath $script:local -RemotePath $script:final -Sha256 $hash -Node n1 -ChunkBytes 1000 -RetrySeconds 0
        Test-Path $script:final | Should -BeTrue
        (Get-Item $script:final).Length | Should -Be 0
    }
}

Describe 'The WinRM transport''s Stage' {
    It 'copies through the chunked operations, writes SbeDeliveryProgress events, and returns the record' {
        $dir = Join-Path $TestDrive 'stage'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'local'), (Join-Path $dir 'node')
        $local = Join-Path $dir 'local\SBE_Dell_X_1.0.zip'
        $final = Join-Path $dir 'node\SBE_Dell_X_1.0.zip'
        $hash = New-TestFile $local 200000
        $global:StageOps = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlNodeTransport Invoke-AzlWinRmFileOp {
            $global:StageOps.Add("$Op/$TimeoutSeconds")
            & (Get-AzlWinRmFileOpBlock -Op $Op) $Argument
        }
        $ctx = New-AzlGuardEventContext
        $t = New-AzlWinRmTransport -Address @{ n1 = '192.0.2.11' } -Credential ([pscredential]::new('u', (ConvertTo-SecureString 'x' -AsPlainText -Force)))
        Set-AzlTransportHeartbeat -Transport $t -Heartbeat (New-AzlWaitHeartbeat -EventContext $ctx -Node n1 -Transport WinRM) -Confirm:$false
        $r = Send-AzlNodeFile -Transport $t -Node n1 -LocalPath $local -RemotePath $final -Sha256 $hash
        $r.Name | Should -Be 'SBE_Dell_X_1.0.zip'
        (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash | Should -Be $hash
        $global:StageOps[0] | Should -Match '^Length/'
        @($global:StageOps | Where-Object { $_ -like 'Write/*' }) | ForEach-Object { $_ | Should -Be 'Write/60' }
        $global:StageOps[-1] | Should -Match '^Finish/'
        $e = @($ctx.Sink | Where-Object state -eq 'SbeDeliveryProgress')
        $e.Count | Should -BeGreaterThan 0
        $e[-1].percent | Should -Be 100
        $e[-1].file | Should -Be 'SBE_Dell_X_1.0.zip'
        $e[0].step | Should -Be 'Transport'
        Remove-Variable -Name StageOps -Scope Global -ErrorAction SilentlyContinue
    }
    It 'does not delete or restart from a .part file by itself any more (the old Stage removed it before every copy)' {
        $text = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\scripts\common\node-configuration\AzlNodeTransport.psm1') -Raw)
        $text | Should -Not -Match 'Copy-Item -LiteralPath \$LocalPath -Destination \$part -ToSession'
        $text | Should -Not -Match 'Remove-Item -LiteralPath \$Part -Force \} -ArgumentList'
    }
}

Describe 'The node-side file operations (run for real)' {
    BeforeEach { $script:d = Join-Path $TestDrive "ops-$([guid]::NewGuid().ToString('N').Substring(0, 6))"; $null = New-Item -ItemType Directory -Force -Path $script:d }
    It 'Length creates the folder and answers 0 for a missing .part file, the size for an existing one' {
        $folder = Join-Path $script:d 'C\SBE'
        $part = Join-Path $folder 'x.zip.part'
        (& (Get-AzlWinRmFileOpBlock -Op Length) @{ Folder = $folder; Part = $part }) | Should -Be 0
        Test-Path $folder | Should -BeTrue
        [IO.File]::WriteAllBytes($part, [byte[]]::new(123))
        (& (Get-AzlWinRmFileOpBlock -Op Length) @{ Folder = $folder; Part = $part }) | Should -Be 123
    }
    It 'Write at an offset leaves exactly offset + count bytes (a longer old tail is cut), and answers the length' {
        $part = Join-Path $script:d 'w.part'
        [IO.File]::WriteAllBytes($part, [byte[]]::new(5000))
        $len = & (Get-AzlWinRmFileOpBlock -Op Write) @{ Part = $part; Offset = [int64]1000; Bytes = [byte[]](1..200 | ForEach-Object { 7 }) }
        $len | Should -Be 1200
        (Get-Item $part).Length | Should -Be 1200
    }
    It 'PrefixHash is the SHA-256 of the first Count bytes; it is empty when the file is shorter' {
        $part = Join-Path $script:d 'p.part'
        $b = [byte[]]::new(3000); [Random]::new(1).NextBytes($b); [IO.File]::WriteAllBytes($part, $b)
        $want = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($b[0..1999])) -replace '-', ''
        (& (Get-AzlWinRmFileOpBlock -Op PrefixHash) @{ Part = $part; Count = [int64]2000 }) | Should -Be $want
        (& (Get-AzlWinRmFileOpBlock -Op PrefixHash) @{ Part = $part; Count = [int64]4000 }) | Should -BeNullOrEmpty
    }
    It 'Finish refuses a part file of the wrong length (and keeps it for a resume), and a wrong hash (and removes it)' {
        $part = Join-Path $script:d 'f.part'; $final = Join-Path $script:d 'f'
        [IO.File]::WriteAllBytes($part, [byte[]]::new(100))
        (& (Get-AzlWinRmFileOpBlock -Op Finish) @{ Part = $part; Final = $final; Want = ''; Length = [int64]200 }) | Should -Match 'holds 100 bytes, expected 200'
        Test-Path $part | Should -BeTrue
        (& (Get-AzlWinRmFileOpBlock -Op Finish) @{ Part = $part; Final = $final; Want = ('0' * 64); Length = [int64]100 }) | Should -Match '^SHA-256 is'
        Test-Path $part | Should -BeFalse
    }
    It 'are Windows PowerShell 5.1 syntax: no ternary, no null-coalescing, no &&' {
        foreach ($op in 'Length', 'PrefixHash', 'Write', 'Finish') {
            $text = (Get-AzlWinRmFileOpBlock -Op $op).ToString()
            $text | Should -Not -Match '\?\?'
            $text | Should -Not -Match '&&'
            $text | Should -Not -Match '\) \? '
        }
    }
}

Describe 'Send-AzlSbePackage delivers the small files first' {
    It 'orders winrm_copy files by size, smallest first (the xml before the zip), whatever the plan order' {
        $order = [System.Collections.Generic.List[string]]::new()
        $t = [pscustomobject]@{ Kind = 'WinRM'; Stage = $null }
        $t.Stage = { param($Self, $Node, $LocalPath, $RemotePath, $Sha256) $order.Add((Split-Path $LocalPath -Leaf)); [pscustomobject]@{ Name = (Split-Path $LocalPath -Leaf); Url = $null } }.GetNewClosure()
        $spec = [pscustomobject]@{ Name = 'n1'; Sbe = [pscustomobject]@{ Dir = 'C:\SBE' } }
        $item = @(
            [pscustomobject]@{ Apply = @{ id = 'Sbe/a.zip'; kind = 'sbe-file'; route = 'winrm_copy'; name = 'a.zip'; sha256 = 'AA'; localPath = 'D:\sbe\a.zip'; size = 960846559 } }
            [pscustomobject]@{ Apply = @{ id = 'Sbe/a.xml'; kind = 'sbe-file'; route = 'winrm_copy'; name = 'a.xml'; sha256 = 'BB'; localPath = 'D:\sbe\a.xml'; size = 4096 } }
            [pscustomobject]@{ Apply = @{ id = 'Sbe/b.xml'; kind = 'sbe-file'; route = 'winrm_copy'; name = 'b.xml'; sha256 = 'CC'; localPath = 'D:\sbe\b.xml'; size = 2048 } })
        $r = @(Send-AzlSbePackage -Spec $spec -Transport $t -Item $item)
        @($order) | Should -Be @('b.xml', 'a.xml', 'a.zip')
        @($r | Where-Object Status -eq 'changed').Count | Should -Be 3
    }
    It 'a failure of the big file leaves the small one delivered and gives the real error text in the result' {
        $t = [pscustomobject]@{ Kind = 'WinRM'; Stage = $null }
        $t.Stage = { param($Self, $Node, $LocalPath, $RemotePath, $Sha256) if ($LocalPath -like '*.zip') { throw 'pkg.zip: chunk at 8388608 of 960846559 bytes failed: the call to n1 did not finish within 75 seconds and was abandoned.' }; [pscustomobject]@{ Name = 'x'; Url = $null } }
        $spec = [pscustomobject]@{ Name = 'n1'; Sbe = [pscustomobject]@{ Dir = 'C:\SBE' } }
        $item = @(
            [pscustomobject]@{ Apply = @{ id = 'Sbe/a.zip'; kind = 'sbe-file'; route = 'winrm_copy'; name = 'a.zip'; sha256 = 'AA'; localPath = 'D:\sbe\a.zip'; size = 960846559 } }
            [pscustomobject]@{ Apply = @{ id = 'Sbe/a.xml'; kind = 'sbe-file'; route = 'winrm_copy'; name = 'a.xml'; sha256 = 'BB'; localPath = 'D:\sbe\a.xml'; size = 4096 } })
        $r = @(Send-AzlSbePackage -Spec $spec -Transport $t -Item $item)
        ($r | Where-Object Name -eq 'a.xml').Status | Should -Be 'changed'
        ($r | Where-Object Name -eq 'a.zip').Status | Should -Be 'failed'
        ($r | Where-Object Name -eq 'a.zip').Detail | Should -Match 'chunk at 8388608 of 960846559 bytes failed'
    }
}

Describe 'The report says why the SBE package is not on a node' {
    BeforeAll {
        function New-Result([object[]]$Plan, [object[]]$Changes = @(), [object[]]$Guard = @(), [string]$Err = '') {
            [pscustomobject]@{ Node = 'iic-n01'; Plan = $Plan; Changes = $Changes; Guard = $Guard; Error = $Err }
        }
        $script:SbePlan = @([pscustomobject]@{ Step = 'Sbe'; Item = 'C:\SBE\a.zip'; Action = 'Change'; Note = 'winrm_copy: copied over WinRM' })
    }
    It 'with no Sbe change entry and a guarded change that stopped the run: "not attempted: run stopped at guarded change <id> (<state>)"' {
        $guard = @([pscustomobject]@{ ChangeId = 'abc123def456'; Group = 'Services'; State = 'Unknown'; Reason = 'x' })
        $text = Get-AzlSbeNotDeliveredReason -Result (New-Result $script:SbePlan -Guard $guard) -Delivery winrm_copy
        $text | Should -Be 'not attempted: run stopped at guarded change abc123def456 (Unknown)'
    }
    It 'attempted and failed: the real error text of the failed file' {
        $changes = @([pscustomobject]@{ Id = 'Sbe/a.zip'; Status = 'failed'; Detail = 'winrm_copy failed: a.zip copied to iic-n01 but SHA-256 is AA, expected BB; the copy was removed.' })
        $text = Get-AzlSbeNotDeliveredReason -Result (New-Result $script:SbePlan -Changes $changes) -Delivery winrm_copy
        $text | Should -Match '^attempted and failed: '
        $text | Should -Match 'SHA-256 is AA, expected BB'
    }
    It 'a run that ended with an error before the SBE step says so' {
        $text = Get-AzlSbeNotDeliveredReason -Result (New-Result $script:SbePlan -Err 'The call to n1 timed out') -Delivery winrm_copy
        $text | Should -Match '^not attempted: the run ended with an error'
        $text | Should -Match 'timed out'
    }
    It 'nothing stopped the run and nothing was tried: not attempted, run ended before the step; no route says it was not requested' {
        (Get-AzlSbeNotDeliveredReason -Result (New-Result $script:SbePlan) -Delivery winrm_copy) | Should -Match '^not attempted: the run ended before the SBE step'
        foreach ($none in 'none', 'skip', '') { (Get-AzlSbeNotDeliveredReason -Result (New-Result $script:SbePlan) -Delivery $none) | Should -Match 'no SBE side-loading requested' }
    }
    It 'an ObservedCommitted guard did not stop the run, so it is not named as the stop' {
        $guard = @([pscustomobject]@{ ChangeId = 'abc123def456'; Group = 'Services'; State = 'ObservedCommitted'; Reason = 'x' })
        (Get-AzlSbeNotDeliveredReason -Result (New-Result $script:SbePlan -Guard $guard) -Delivery winrm_copy) | Should -Not -Match 'run stopped at guarded change'
    }
    It 'the closing line and the report of Set-AzureLocalNodeConfiguration use it' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\scripts\deploy\04-cluster-deployment\phase-03-os-configuration\Set-AzureLocalNodeConfiguration.ps1') -Raw
        $text | Should -Match 'Get-AzlSbeNotDeliveredReason'
        $text | Should -Match 'sbeNotDeliveredDetail'
    }
}
