#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The step table of Invoke-AzureLocalPostDeployment.ps1 (PostDeploymentSteps.psd1) is the one place that says which steps the post-deployment phase has and in
# which order. This file keeps it true: against the pages of the Implementation guide (phase 06, in the local docs clone: the list of pages, their order and the
# script each page names), against the scripts of the toolkit, and against the registry (the enum of operations.post_cluster.skip_steps). Nothing is run.
# The docs clone is found by $env:AZL_DOCS_REPO, else D:\git\azurelocal\azurelocal.github.io, else a sibling folder azurelocal.github.io; without one the
# comparison with the pages is skipped (the other checks run).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/PostDeploymentSteps.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Phase = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment')
    $script:Table = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:Phase, 'PostDeploymentSteps.psd1'))
    $script:Steps = @($script:Table.Steps)
    $candidates = @($env:AZL_DOCS_REPO, 'D:\git\azurelocal\azurelocal.github.io', [IO.Path]::Combine($script:Repo, '..', 'azurelocal.github.io')) | Where-Object { $_ }
    $script:PagesDir = $null
    foreach ($c in $candidates) {
        $dir = [IO.Path]::Combine($c, 'docs', 'implementation', '04-cluster-deployment', 'phase-06-post-deployment')
        if (Test-Path -LiteralPath $dir -PathType Container) { $script:PagesDir = $dir; break }
    }
    $script:Pages = @()
    if ($script:PagesDir) { $script:Pages = @(Get-ChildItem -LiteralPath $script:PagesDir -Filter 'task-*.mdx' -File | Sort-Object Name) }
}

Describe 'The step table' {
    It 'has steps with an id, a task, a title, a script and a plan mode, and no id twice' {
        $script:Table.SchemaVersion | Should -Be 1
        $script:Steps.Count | Should -BeGreaterThan 0
        foreach ($s in $script:Steps) {
            foreach ($f in 'Id', 'Task', 'Title', 'Script', 'Plan') { $s.ContainsKey($f) | Should -BeTrue -Because "$($s.Id) has $f" }
            $s.Plan | Should -BeIn 'WhatIf', 'Run'
            $s.Id | Should -Match '^[a-z][a-z0-9-]*$'
        }
        @($script:Steps | ForEach-Object { $_.Id } | Group-Object | Where-Object Count -GT 1) | Should -BeNullOrEmpty
    }
    It 'keeps the steps of one task together and in the order of the task numbers' {
        $numbers = @($script:Steps | ForEach-Object { [int]($_.Task -replace '^task-(\d\d)-.*$', '$1') })
        $numbers | Should -Be @($numbers | Sort-Object)
    }
    It 'every script and Azure CLI twin of the table is in the task folder the table names, and exists' {
        foreach ($s in $script:Steps) {
            foreach ($p in @($s.Script, $(if ($s.ContainsKey('AzureCliScript')) { $s.AzureCliScript }))) {
                if (-not $p) { continue }
                $p | Should -BeLike "scripts/deploy/04-cluster-deployment/phase-06-post-deployment/$($s.Task)/*" -Because $s.Id
                Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, $p)) | Should -BeTrue -Because "$($s.Id): $p"
            }
        }
    }
    It 'an irreversible step has acknowledgement keys, and only SDN is irreversible' {
        foreach ($s in $script:Steps) {
            if ($s.ContainsKey('Irreversible') -and $s.Irreversible) { @($s.Requires).Count | Should -BeGreaterThan 0 -Because $s.Id }
            else { $s.ContainsKey('Requires') | Should -BeFalse -Because "$($s.Id) is not irreversible" }
        }
        @($script:Steps | Where-Object { $_.ContainsKey('Irreversible') -and $_.Irreversible } | ForEach-Object { $_.Id }) | Should -Be @('sdn')
        $sdn = $script:Steps | Where-Object Id -EQ 'sdn'
        @($sdn.Requires | ForEach-Object { $_.Key }) | Should -Contain 'sdn.acknowledge_maintenance_window'
    }
    It 'sdn-test runs Test-ArcSdn.ps1 right after the sdn step, only when sdn.enabled is true, in the same task, and is not irreversible' {
        $ids = @($script:Steps | ForEach-Object { $_.Id })
        $ids.IndexOf('sdn-test') | Should -Be ($ids.IndexOf('sdn') + 1)
        $step = $script:Steps | Where-Object Id -EQ 'sdn-test'
        $sdn = $script:Steps | Where-Object Id -EQ 'sdn'
        $step.Task | Should -Be $sdn.Task
        $step.Script | Should -BeLike '*/task-01-deploy-sdn/powershell/Test-ArcSdn.ps1'
        $step.Plan | Should -Be 'WhatIf'
        @($step.Applies).Count | Should -Be 1
        $step.Applies[0].Key | Should -Be 'sdn.enabled'
        $step.Applies[0].Is | Should -BeTrue
        $step.ContainsKey('Irreversible') | Should -BeFalse
        # the page task-01 does not name Test-ArcSdn.ps1 yet; when it does, drop ScriptOnPage here (the test of the pages then asks for the name)
        $step.ScriptOnPage | Should -BeFalse
    }
    It 'every condition has a known operator, and every key it reads is a key of the infrastructure schema' {
        $schema = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw | ConvertFrom-Json -AsHashtable
        $conditions = @(foreach ($s in $script:Steps) {
                foreach ($c in @($s['Applies']) + @($s['Requires']) + @($s['Arguments'] | ForEach-Object { $_.When })) { if ($c) { $c } }
                foreach ($r in @($s['Requires'])) { if ($r -and $r.ContainsKey('When')) { $r.When } }
            })
        foreach ($c in $conditions) {
            @([string[]]$c.get_Keys() | Where-Object { $_ -in 'Is', 'IsNot', 'NotEmpty', 'AnyItemHas', 'AnyNotEmpty' }).Count | Should -BeGreaterThan 0 -Because ($c | ConvertTo-Json -Compress)
            $keys = if ($c.ContainsKey('Keys')) { @($c['Keys']) } else { @($c['Key']) }
            foreach ($k in $keys) {
                $node = $schema
                foreach ($part in $k -split '\.') {
                    $props = if ($node.ContainsKey('properties')) { $node['properties'] } else { @{} }
                    $node = if ($props.ContainsKey($part)) { $props[$part] } else { $null }
                    if ($null -eq $node) { break }
                }
                $node | Should -Not -BeNullOrEmpty -Because "the key $k of a condition is in the schema"
            }
        }
    }
    It 'the arguments of a step are switches that exist on its script' {
        foreach ($s in $script:Steps) {
            foreach ($a in @($s['Arguments'])) {
                if (-not $a) { continue }
                (Get-Command -Name ([IO.Path]::Combine($script:Repo, $s.Script)) -CommandType ExternalScript).Parameters[[string]$a.Name].ParameterType.Name | Should -Be 'SwitchParameter' -Because "$($s.Id) $($a.Name)"
            }
        }
    }
}

Describe 'The registry and the table agree' {
    It 'the enum of operations.post_cluster.skip_steps is exactly the ids of the table, in order' {
        $schema = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw | ConvertFrom-Json -AsHashtable
        $skip = $schema['properties']['operations']['properties']['post_cluster']['properties']['skip_steps']
        @($skip['items']['enum']) | Should -Be @($script:Steps | ForEach-Object { $_.Id })
    }
    It 'operations.post_cluster has enabled, skip_steps and allow_node_restarts, all optional' {
        $schema = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw | ConvertFrom-Json -AsHashtable
        $pc = $schema['properties']['operations']['properties']['post_cluster']
        @($pc['properties'].Keys | Sort-Object) | Should -Be @('allow_node_restarts', 'enabled', 'skip_steps')
        if ($pc.ContainsKey('required')) { @($pc['required']) | Should -BeNullOrEmpty }
    }
}

Describe 'The table and the pages of the Implementation guide (phase 06) agree' {
    It 'the docs clone has the pages of the phase' {
        if (-not $script:PagesDir) { Set-ItResult -Skipped -Because 'no docs clone found (set AZL_DOCS_REPO)'; return }
        $script:Pages.Count | Should -BeGreaterThan 0
    }
    It 'the tasks of the table are the pages of the guide, in the order of the pages (the file names and sidebar_position agree)' {
        if (-not $script:PagesDir) { Set-ItResult -Skipped -Because 'no docs clone found (set AZL_DOCS_REPO)'; return }
        $pageNames = @($script:Pages | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
        $tasks = @($script:Steps | ForEach-Object { $_.Task } | Select-Object -Unique)
        $tasks | Should -Be $pageNames -Because 'a page the table does not run, or a task the guide does not have, is a drift'
        $positions = @($script:Pages | ForEach-Object { $m = [regex]::Match((Get-Content -LiteralPath $_.FullName -TotalCount 12 | Out-String), '(?m)^sidebar_position:\s*(\d+)'); if ($m.Success) { [int]$m.Groups[1].Value } else { 0 } })
        $positions | Should -Be @($positions | Sort-Object) -Because 'the order of the files is the order of the sidebar'
    }
    It 'each page names the script of its steps, except the pages the table marks (ScriptOnPage false), and names the Azure CLI twin' {
        if (-not $script:PagesDir) { Set-ItResult -Skipped -Because 'no docs clone found (set AZL_DOCS_REPO)'; return }
        foreach ($s in $script:Steps) {
            # a page writes a path with either slash, or only the name of the script in a table of its folder
            $page = [IO.File]::ReadAllText([IO.Path]::Combine($script:PagesDir, "$($s.Task).mdx")).Replace('\','/')
            $names = { param([string]$path) $page.Contains($path) -or $page.Contains([IO.Path]::GetFileName($path)) }
            if ($s.ContainsKey('ScriptOnPage') -and -not $s.ScriptOnPage) { (& $names $s.Script) | Should -BeFalse -Because "$($s.Id): the table says the page does not name it, so drop ScriptOnPage when the page does" }
            else { (& $names $s.Script) | Should -BeTrue -Because "$($s.Id): the page $($s.Task) names $($s.Script)" }
            if ($s.ContainsKey('AzureCliScript')) { (& $names $s.AzureCliScript) | Should -BeTrue -Because "$($s.Id): the page names its Azure CLI twin" }
        }
    }
    It 'every script of the phase that a page lists in a script table is run by a step, or is called by one of the scripts of a step' {
        if (-not $script:PagesDir) { Set-ItResult -Skipped -Because 'no docs clone found (set AZL_DOCS_REPO)'; return }
        $run = @($script:Steps | ForEach-Object { $_.Script; if ($_.ContainsKey('AzureCliScript')) { $_.AzureCliScript } })
        $pageScripts = @($script:Pages | ForEach-Object { [regex]::Matches([IO.File]::ReadAllText($_.FullName), '(?m)^\| `(scripts/deploy/04-cluster-deployment/phase-06-post-deployment/[^`]+\.ps1)`') | ForEach-Object { $_.Groups[1].Value } } | Sort-Object -Unique)
        $notRun = @($pageScripts | Where-Object { $_ -notin $run })
        # what a step's own script calls (the verification script runs Invoke-VerifyPostDeployment.ps1 and its Azure CLI twin; the quorum page also lists the
        # storage account script and the verification script for a check): named here so a new page script cannot be left out without a decision
        $reason = @{
            'Invoke-VerifyPostDeployment.ps1'             = 'run by the verification step (Invoke-PostDeploymentVerification-Orchestrated.ps1)'
            'Invoke-VerifyPostDeployment.azcli.ps1'       = 'run by the verification step (Invoke-PostDeploymentVerification-Orchestrated.ps1)'
            'New-CloudWitnessStorageAccount.azcli.ps1'    = 'only the storage account of the cloud witness: the quorum step creates a missing account itself'
            'New-SanVolume.ps1'                           = 'run by the external storage step (Invoke-ExternalStorageHybrid-Orchestrated.ps1)'
        }
        foreach ($p in $notRun) { $reason.ContainsKey([IO.Path]::GetFileName($p)) | Should -BeTrue -Because "$p is on a page of the phase and no step runs it: add a step, or say here why not" }
    }
}
