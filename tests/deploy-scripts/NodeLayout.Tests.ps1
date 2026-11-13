#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# infrastructure.yml (schema 5) lists the machines in nodes[]. The old layout compute.cluster_nodes (a mapping keyed by node, with
# hostname and management_ip) is gone from the schema, so no script under scripts/ may read it. The per-task scripts read the
# node list through Get-AzlInfrastructureNode (scripts/common/infrastructure/AzlInfrastructure.psm1).
# Reads files only; nothing runs against Azure or a node.
# Run: Invoke-Pester ./tests/deploy-scripts/NodeLayout.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $scripts = [System.IO.Path]::Combine($repo, 'scripts')
    $rel = { param($p) [System.IO.Path]::GetRelativePath($repo, $p).Replace('\', '/') }

    # Files that still read compute.cluster_nodes, each with the reason it was left. An entry goes when the file is fixed: the
    # test for a left file fails once the file no longer reads the old layout.
    $reason = @{}
    $files = @(Get-ChildItem -LiteralPath $scripts -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
    # The files to check, as one list: a failure names every file that reads the old layout.
    $script:CodeFile = @($files | Where-Object { -not $reason.ContainsKey((& $rel $_.FullName)) } | ForEach-Object { @{ Path = $_.FullName; Relative = (& $rel $_.FullName) } })
    $script:LeftFile = @($reason.Keys | Sort-Object | ForEach-Object { @{ Path = Join-Path $repo $_; Relative = $_; Reason = $reason[$_] } })
    # Scripts that call the shared reader must import the module that holds it.
    $script:CallerFile = @(
        $files | Where-Object { $_.FullName -notmatch '[\\/]common[\\/]infrastructure[\\/]' } | ForEach-Object {
            $text = Get-Content -LiteralPath $_.FullName -Raw
            if ($text -match '\bGet-AzlInfrastructureNode\b') { @{ Path = $_.FullName; Relative = (& $rel $_.FullName) } }
        }
    )
}

Describe 'Node layout of the scripts' {
    It 'no script reads compute.cluster_nodes (<Count> files checked)' -ForEach @(@{ Files = $script:CodeFile; Count = $script:CodeFile.Count }) {
        $offender = @($Files | Where-Object { (Get-Content -LiteralPath $_.Path -Raw) -match 'cluster_nodes' } | ForEach-Object { $_.Relative })
        $offender | Should -BeNullOrEmpty -Because ('these files still read the old node layout: ' + ($offender -join ', '))
    }

    It 'there are scripts to check' -ForEach @(@{ Count = $script:CodeFile.Count }) {
        $Count | Should -BeGreaterThan 300
    }

    It '<Relative> is left on purpose and still reads the old layout' -ForEach $script:LeftFile {
        Test-Path -LiteralPath $Path | Should -BeTrue -Because 'the file is on the list of files left on purpose'
        (Get-Content -LiteralPath $Path -Raw) | Should -Match 'cluster_nodes' -Because 'the file was fixed: remove it from the list'
        $Reason | Should -Not -BeNullOrEmpty
    }
}

Describe 'Scripts that call Get-AzlInfrastructureNode' {
    It '<Relative> imports AzlInfrastructure.psm1 from a path that exists' -ForEach $script:CallerFile {
        $text = Get-Content -LiteralPath $Path -Raw
        $match = [regex]::Match($text, "Import-Module \(\[IO\.Path\]::GetFullPath\(\[IO\.Path\]::Combine\(\`$PSScriptRoot, (?<parts>[^)]*)\)\)\)")
        $match.Success | Should -BeTrue -Because 'the script must import the module that defines Get-AzlInfrastructureNode'
        $parts = @([regex]::Matches($match.Groups['parts'].Value, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value })
        $parts[-1] | Should -Be 'AzlInfrastructure.psm1'
        $segments = [string[]](@([System.IO.Path]::GetDirectoryName($Path)) + $parts)
        $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($segments))
        Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue -Because "$resolved must exist"
    }

    It '<Relative> declares a PowerShell version' -ForEach $script:CallerFile {
        (Get-Content -LiteralPath $Path -Raw) | Should -Match '(?m)^#Requires\s+-Version\s+\d'
    }
}
