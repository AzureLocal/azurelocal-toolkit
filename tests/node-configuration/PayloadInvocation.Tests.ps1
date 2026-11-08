#Requires -Version 7.0
# The node payload keeps its results in script-scope variables, so it must give the same answer whether it is run as a script
# file or as a scriptblock. A WinRM transport that ran it as a scriptblock returned every section empty with no error.

BeforeAll {
    $common = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') 'scripts'
    $common = Join-Path (Join-Path $common 'common') 'node-configuration'
    Import-Module (Join-Path $common 'AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $common 'AzlNodeTransport.psm1') -Force
    $script:ps51 = Get-Command powershell.exe -ErrorAction SilentlyContinue
}

Describe 'Node payload invocation' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $text = Get-AzlNodePayload 'Read'
        $json = '{"mgmtMac":"000000000000","san":false,"sanDisks":false,"sanType":""}'
        $p = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $q = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('azl-payload-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $file = Join-Path $tmp 'read.ps1'
        $txt = Join-Path $tmp 'read.txt'
        [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText($txt, $text)
        $asFile = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file -ParamsB64 $p -SecretsB64 $q 2>&1
        $cmd = "& ([scriptblock]::Create([IO.File]::ReadAllText('$txt'))) -ParamsB64 '$p' -SecretsB64 '$q'"
        $asBlock = & powershell.exe -NoProfile -NonInteractive -Command $cmd 2>&1
        $script:fileResult = ConvertTo-AzlNodeResult -Text ($asFile -join [Environment]::NewLine)
        $script:blockResult = ConvertTo-AzlNodeResult -Text ($asBlock -join [Environment]::NewLine)
    }
    AfterAll { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force } }

    It 'run as a script file returns the remote management and time sections' {
        $script:fileResult | Should -Not -BeNullOrEmpty
        $script:fileResult.remote | Should -Not -BeNullOrEmpty
        $script:fileResult.time | Should -Not -BeNullOrEmpty
    }

    It 'the transport source runs the payload as a file, never as a scriptblock' {
        $source = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') 'scripts') (Join-Path 'common' (Join-Path 'node-configuration' 'AzlNodeTransport.psm1'))) -Raw
        $source | Should -Not -Match '\[scriptblock\]::Create\(\$Text\)\)\s+-ParamsB64'
        $source | Should -Match 'WriteAllText\(\$file'
    }

    It 'documents that a scriptblock run loses the results, so the file route stays' {
        # If this ever starts returning data as a scriptblock the payload no longer depends on script scope and the file route
        # may be simplified. Until then the two answers differ and the transport must use the file.
        if ($script:blockResult -and $script:blockResult.remote) { Set-ItResult -Skipped -Because 'payload no longer depends on script scope' }
        else { $script:blockResult.remote | Should -BeNullOrEmpty }
    }
}
