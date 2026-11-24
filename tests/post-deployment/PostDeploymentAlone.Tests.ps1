#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Owner requirement D150: every task of the post-deployment phase runs TOGETHER (Invoke-AzureLocalPostDeployment.ps1) and ALONE. This file proves the
# second part: each script of the eleven tasks (and each Azure CLI twin) is started by itself in Plan mode (-WhatIf) against the toolkit's example file,
# with no orchestrator, only its own parameters, and ends with one of its documented exit codes (0, 1 or 2) and not with a binding or parse error.
# It also proves that no task script knows the orchestrator or reads another task's output files, and that the orchestrator calls a script with its
# public parameters only.
# Nothing reaches a cluster or Azure: the child process has Invoke-Command, New-PSSession and az replaced by functions that throw, and the example file
# holds placeholders (the all-zero subscription), so a script stops at its own input check or at the blocked connection.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/PostDeploymentAlone.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $table = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'PostDeploymentSteps.psd1'))
    $script:Cases = @(foreach ($s in $table.Steps) {
            @{ Id = $s.Id; Task = $s.Task; Relative = $s.Script; Kind = 'PowerShell' }
            if ($s.ContainsKey('AzureCliScript')) { @{ Id = $s.Id; Task = $s.Task; Relative = $s.AzureCliScript; Kind = 'AzureCli' } }
        })
    $script:Tasks = @($table.Steps | ForEach-Object { @{ Task = $_.Task } } | Sort-Object { $_.Task } -Unique)
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($script:Repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $script:Phase = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment')
    # The script runs in a child pwsh, by itself, in Plan mode. Remoting and the Azure CLI are blocked: they throw.
    function Invoke-Alone([string]$Path, [string]$LogFile) {
        $own = (Get-Command -Name $Path -CommandType ExternalScript).Parameters
        $extra = (@(if ($own.ContainsKey('LogPath')) { "-LogPath '$($LogFile.Replace("'", "''"))'" }) + @(if ($own.ContainsKey('WhatIf')) { '-WhatIf' })) -join ' '
        $wrapper = @"
function global:Invoke-Command { throw 'blocked: a unit test reaches no machine' }
function global:New-PSSession { throw 'blocked: a unit test reaches no machine' }
function global:Enter-PSSession { throw 'blocked: a unit test reaches no machine' }
function global:az { throw 'blocked: a unit test reaches no Azure' }
function global:Get-AzKeyVaultSecret { throw 'blocked: a unit test reaches no Azure' }
function global:Connect-AzAccount { throw 'blocked: a unit test reaches no Azure' }
function global:Get-AzContext { $null }
function global:Test-WSMan { throw 'blocked: a unit test reaches no machine' }
function global:Test-NetConnection { throw 'blocked: a unit test reaches no machine' }
function global:Resolve-DnsName { throw 'blocked: a unit test reaches no machine' }
function global:Invoke-RestMethod { throw 'blocked: a unit test reaches no network' }
function global:Invoke-WebRequest { throw 'blocked: a unit test reaches no network' }
`$global:LASTEXITCODE = 0
& '$($Path.Replace("'", "''"))' -InfrastructureFile '$($script:Example.Replace("'", "''"))' $extra
exit `$LASTEXITCODE
"@
        $out = & pwsh -NoProfile -NonInteractive -Command $wrapper 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
}

Describe 'Each post-deployment script runs alone in Plan mode against the example file' {
    It '<Id> (<Kind>): <Relative> ends with exit code 0, 1 or 2 and no binding or parse error' -ForEach $script:Cases {
        $path = [IO.Path]::Combine($script:Repo, $Relative)
        $path | Should -Exist
        $log = Join-Path $TestDrive ("$Id-$Kind.log")
        # the wrapper adds -LogPath and -WhatIf only to a script that has them (the SBE plan has neither: it prints and changes nothing)
        $r = Invoke-Alone $path $log
        $r.ExitCode | Should -BeIn 0, 1, 2 -Because $r.Output
        $r.Output.Trim() | Should -Not -BeNullOrEmpty -Because 'the script ran and said what it found'
        $r.Output | Should -Not -Match 'parameter cannot be found|Cannot bind|ParserError|is not recognized as|Orchestrator|Invoke-AzureLocalPostDeployment|PostDeploymentSteps' -Because $r.Output
    }
}

Describe 'No task script knows the orchestrator or another task''s output' {
    It '<Id> (<Kind>): names neither the orchestrator, its table, its report or its events' -ForEach $script:Cases {
        $text = [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $Relative))
        $text | Should -Not -Match 'Invoke-AzureLocalPostDeployment|AzlPostDeploymentRun|PostDeploymentSteps|post-deployment-events'
    }
    It '<Id> (<Kind>): reads no file of another task' -ForEach $script:Cases {
        $text = [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $Relative))
        $own = $Task
        # a read of a file under another task folder of the phase (Get-Content, Import-Clixml, ReadAllText, ConvertFrom-Json of a path)
        $hits = @([regex]::Matches($text, '(?im)^[^#\r\n]*(Get-Content|Import-Clixml|Import-PowerShellDataFile|ReadAllText|ReadAllLines|Import-Csv)[^\r\n]*\btask-\d\d-[a-z0-9-]+') |
                ForEach-Object { $_.Value } | Where-Object { $_ -notmatch [regex]::Escape($own) })
        $hits | Should -BeNullOrEmpty
    }
    It 'no task script of the phase writes or reads the report of a run' {
        foreach ($f in Get-ChildItem -LiteralPath $script:Phase -Recurse -Filter '*.ps1' | Where-Object { $_.Name -ne 'Invoke-AzureLocalPostDeployment.ps1' }) {
            [IO.File]::ReadAllText($f.FullName) | Should -Not -Match 'summary\.md|report\.json' -Because $f.Name
        }
    }
}

Describe 'The orchestrator calls a script with its public parameters only' {
    BeforeAll {
        $script:Module = Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'post-deployment', 'AzlPostDeploymentRun.psm1')) -Force -PassThru
        $script:Table = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:Phase, 'PostDeploymentSteps.psd1'))
    }
    It '<Task>: -Only <Task> selects exactly its steps and nothing else' -ForEach $script:Tasks {
        $steps = @($script:Table.Steps)
        $picked = @(Resolve-AzlPostDeploymentSelection -Steps $steps -Only $Task)
        $picked.Count | Should -BeGreaterThan 0
        @($picked | ForEach-Object { $_.Task } | Select-Object -Unique) | Should -Be @($Task)
        @($picked).Count | Should -Be @($steps | Where-Object { $_.Task -eq $Task }).Count
    }
    It 'every parameter the orchestrator can pass exists on the script it passes it to, or is not passed' {
        # the orchestrator passes only InfrastructureFile, LogPath, ComputerName, Credential, Confirm, WhatIf and the table's Arguments
        foreach ($s in $script:Table.Steps) {
            $p = (Get-Command -Name ([IO.Path]::Combine($script:Repo, $s.Script)) -CommandType ExternalScript).Parameters
            $p.ContainsKey('InfrastructureFile') | Should -BeTrue -Because $s.Id
            if ($s.ContainsKey('Arguments')) { foreach ($a in $s.Arguments) { $p.ContainsKey([string]$a.Name) | Should -BeTrue -Because "$($s.Id) argument $($a.Name)" } }
            if ($s.Plan -eq 'WhatIf') { $p.ContainsKey('WhatIf') | Should -BeTrue -Because "$($s.Id) is planned with -WhatIf" }
            else { $p.ContainsKey('WhatIf') | Should -BeFalse -Because "$($s.Id) has no -WhatIf, so Plan runs it as it is" }
        }
    }
}
