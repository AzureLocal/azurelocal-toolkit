#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The Azure DevOps OS configuration pipeline (pipelines/azure-devops/os-configuration.yml) parses, keeps both approval gates, uses
# PowerShell 7 only, passes only parameters the one entry point has, and carries no value of any ID or secret. Nothing is run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:AdoFile = [IO.Path]::Combine($repo, 'pipelines', 'azure-devops', 'os-configuration.yml')
    $script:EntryScript = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Invoke-AzureLocalOsConfiguration.ps1')
    Import-Module powershell-yaml
    $script:Text = Get-Content -LiteralPath $script:AdoFile -Raw
    $script:Ado = ConvertFrom-Yaml $script:Text

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:EntryScript, [ref]$tokens, [ref]$errors)
    $script:EntryParameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    function Get-ValidateSet([string]$Name) {
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name }
        $attr = $param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        @($attr.PositionalArguments | ForEach-Object { $_.Value })
    }
    $script:WrapperTransports = Get-ValidateSet 'Transport'
    $script:WrapperModes = Get-ValidateSet 'Mode'
    $script:WrapperSteps = Get-ValidateSet 'Step'

    # Every step of a stage's jobs (job -> steps, deployment -> strategy.runOnce.deploy.steps); conditional insertions are flattened.
    function Get-StageStep($Stage) {
        foreach ($job in $Stage['jobs']) {
            $steps = if ($job.Contains('steps')) { $job['steps'] } else { $job['strategy']['runOnce']['deploy']['steps'] }
            foreach ($s in $steps) {
                if ($s -is [System.Collections.IDictionary] -and @($s.Keys)[0] -like '${{ if*') { foreach ($inner in $s[@($s.Keys)[0]]) { $inner } }
                else { $s }
            }
        }
    }
    function Get-AzureStep([string]$StageName) {
        Get-StageStep ($script:Ado['stages'] | Where-Object { $_['stage'] -eq $StageName }) | Where-Object { $_['task'] -eq 'AzurePowerShell@5' }
    }
    # Parameters of the entry point an inline script sets: the keys of its hashtable, $p.Name = ..., and the names in @('ENV', 'Name') pairs.
    function Get-UsedEntryParameter([string]$Inline) {
        $t = $null; $e = $null
        $a = [System.Management.Automation.Language.Parser]::ParseInput($Inline, [ref]$t, [ref]$e)
        if ($e.Count) { throw "The inline script doesn't parse: $($e[0].Message)" }
        $names = [System.Collections.Generic.List[string]]::new()
        $hashes = $a.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        # Only the first hashtable is the splat of the entry point; the second one is the Settings value.
        foreach ($kv in $hashes[0].KeyValuePairs) { $names.Add($kv.Item1.Value) }
        $assign = $a.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)
        foreach ($m in $assign) { if ($m.Left.Expression.Extent.Text -eq '$p') { $names.Add($m.Left.Member.Value) } }
        foreach ($m in [regex]::Matches($Inline, "@\('OSC_\w+', '(\w+)'\)")) { $names.Add($m.Groups[1].Value) }
        $names | Sort-Object -Unique
    }
}

Describe 'Azure DevOps OS configuration pipeline: shape' {
    It 'parses, is run by hand only, and runs the one entry point' {
        $script:Ado | Should -Not -BeNullOrEmpty
        $script:Ado['trigger'] | Should -Be 'none'
        $script:Ado['pr'] | Should -Be 'none'
        $var = @($script:Ado['variables'] | Where-Object { $_.Contains('name') -and $_['name'] -eq 'OSCONFIG_SCRIPT' })
        $var.Count | Should -Be 1
        $var[0]['value'] | Should -Be 'scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1'
        Test-Path -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', '..', $var[0]['value'])) | Should -BeTrue
    }
    It 'has the stages Plan, ConfirmStorageWipe, Apply in that order, and runs queue one after the other' {
        @($script:Ado['stages'] | ForEach-Object { $_['stage'] }) | Should -Be @('Plan', 'ConfirmStorageWipe', 'Apply')
        $script:Ado['lockBehavior'] | Should -Be 'sequential'
    }
    It 'asks for the parameters of the task, with safe defaults' {
        $p = @{}; foreach ($x in $script:Ado['parameters']) { $p[$x['name']] = $x }
        foreach ($n in 'infrastructure_file', 'handoff_path', 'nodes', 'steps', 'mode', 'transport', 'approved_bootstrap', 'clear_storage', 'agent_pool', 'service_connection') { $p.Keys | Should -Contain $n }
        $p['mode']['default'] | Should -Be 'Plan'
        $p['transport']['default'] | Should -Be 'WinRM'
        $p['approved_bootstrap']['type'] | Should -Be 'boolean'
        $p['approved_bootstrap']['default'] | Should -BeFalse
        $p['clear_storage']['type'] | Should -Be 'boolean'
        $p['clear_storage']['default'] | Should -BeFalse
        foreach ($n in 'nodes', 'steps') { $p[$n]['default'] | Should -Be 'all' }
    }
    It 'offers only modes and transports the entry point accepts, and never Auto for the transport (no silent Arc)' {
        $p = @{}; foreach ($x in $script:Ado['parameters']) { $p[$x['name']] = $x }
        @($p['mode']['values']) | Should -Be @('Plan', 'Apply')
        foreach ($m in $p['mode']['values']) { $script:WrapperModes | Should -Contain $m }
        @($p['transport']['values']) | Should -Be @('WinRM', 'ArcRunCommand')
        foreach ($t in $p['transport']['values']) { $script:WrapperTransports | Should -Contain $t }
    }
    It 'documents every step name the entry point accepts' {
        $steps = ($script:Ado['parameters'] | Where-Object { $_['name'] -eq 'steps' })['displayName']
        foreach ($s in $script:WrapperSteps) { $steps | Should -Match $s }
    }
}

Describe 'Azure DevOps OS configuration pipeline: approval gates' {
    It 'Plan is a plain job with no environment, so it is read only and unattended' {
        $plan = $script:Ado['stages'] | Where-Object { $_['stage'] -eq 'Plan' }
        $plan['jobs'][0].Contains('job') | Should -BeTrue
        $plan['jobs'][0].Contains('deployment') | Should -BeFalse
        $plan['jobs'][0].Contains('environment') | Should -BeFalse
    }
    It 'Apply is a deployment job in the environment azure-local-os-configuration, so its approval checks gate it' {
        $apply = $script:Ado['stages'] | Where-Object { $_['stage'] -eq 'Apply' }
        $apply['jobs'][0].Contains('deployment') | Should -BeTrue
        $apply['jobs'][0]['environment'] | Should -Be 'azure-local-os-configuration'
        @($apply['dependsOn']) | Should -Contain 'Plan'
        $apply['condition'] | Should -Match "parameters\.mode.*'Apply'"
    }
    It 'a storage wipe has its own second environment, only for Apply with clear_storage on' {
        $confirm = $script:Ado['stages'] | Where-Object { $_['stage'] -eq 'ConfirmStorageWipe' }
        $apply = $script:Ado['stages'] | Where-Object { $_['stage'] -eq 'Apply' }
        $confirm['jobs'][0].Contains('deployment') | Should -BeTrue
        $confirm['jobs'][0]['environment'] | Should -Be 'azure-local-os-configuration-clear-storage'
        $confirm['jobs'][0]['environment'] | Should -Not -Be $apply['jobs'][0]['environment']
        $confirm['condition'] | Should -Match "parameters\.mode.*'Apply'"
        $confirm['condition'] | Should -Match "parameters\.clear_storage.*'true'"
        @($confirm['dependsOn']) | Should -Contain 'Plan'
    }
    It 'Apply waits for the wipe confirmation (a rejection stops it), and only a skipped confirmation lets it pass' {
        $apply = $script:Ado['stages'] | Where-Object { $_['stage'] -eq 'Apply' }
        @($apply['dependsOn']) | Should -Contain 'ConfirmStorageWipe'
        $apply['condition'] | Should -Match "dependencies\.ConfirmStorageWipe\.result, 'Succeeded', 'Skipped'"
        $apply['condition'] | Should -Not -Match 'always\(\)|failed\('
    }
    It 'the confirmation stage shows the wipe list from the plan artifact and refuses without one' {
        $confirm = $script:Ado['stages'] | Where-Object { $_['stage'] -eq 'ConfirmStorageWipe' }
        $steps = @(Get-StageStep $confirm)
        @($steps | Where-Object { $_['download'] -eq 'current' -and $_['artifact'] -eq 'os-configuration-plan' }).Count | Should -Be 1
        (($steps | ForEach-Object { $_['pwsh'] }) -join "`n") | Should -Match 'wipe-list\.txt'
        (($steps | ForEach-Object { $_['pwsh'] }) -join "`n") | Should -Match 'throw'
    }
    It 'Plan runs -Mode Plan only and never the bootstrap; Apply runs Apply and may bootstrap' {
        $planScript = (Get-AzureStep 'Plan')['inputs']['Inline']
        $applyScript = (Get-AzureStep 'Apply')['inputs']['Inline']
        $planScript | Should -Match "Mode\s+=\s+'Plan'"
        $planScript | Should -Not -Match 'Apply|ApprovedBootstrap|OSC_APPROVED_BOOTSTRAP'
        $applyScript | Should -Match "Mode\s+=\s+'Apply'"
        $applyScript | Should -Match '\$p\.ApprovedBootstrap = \$true'
        $applyScript | Should -Not -Match 'bootstrapTransport'
        $applyScript | Should -Match "OSC_APPROVED_BOOTSTRAP -eq 'true'"
    }
}

Describe 'Azure DevOps OS configuration pipeline: the entry point and PowerShell 7' {
    It 'the entry point has every parameter the pipeline passes (<Stage>)' -ForEach @(@{ Stage = 'Plan' }, @{ Stage = 'Apply' }) {
        $used = @(Get-UsedEntryParameter (Get-AzureStep $Stage)['inputs']['Inline'])
        foreach ($n in 'InfrastructureFile', 'Mode', 'Transport', 'ReportDirectory', 'EventLogPath', 'HandoffPath', 'Node', 'Step', 'ClearStorage') { $used | Should -Contain $n }
        foreach ($u in $used) { $script:EntryParameters | Should -Contain $u }
        if ($Stage -eq 'Apply') { $used | Should -Contain 'ApprovedBootstrap' }
    }
    It 'calls the script through the OSCONFIG_SCRIPT variable and fails the task on a non-zero exit code (<Stage>)' -ForEach @(@{ Stage = 'Plan' }, @{ Stage = 'Apply' }) {
        $inline = (Get-AzureStep $Stage)['inputs']['Inline']
        $inline | Should -Match '& \$env:OSCONFIG_SCRIPT @p'
        $inline | Should -Match 'LASTEXITCODE -ne 0\) \{ throw'
        $inline | Should -Match 'Set-StrictMode -Version Latest'
        $inline | Should -Match '\$ErrorActionPreference = .Stop.'
    }
    It 'uses PowerShell 7 only: pwsh steps, AzurePowerShell with pwsh true, no script, bash, powershell or cmd step' {
        foreach ($stage in $script:Ado['stages']) {
            foreach ($s in (Get-StageStep $stage)) {
                foreach ($bad in 'script', 'bash', 'powershell', 'cmd') { $s.Contains($bad) | Should -BeFalse -Because "step '$($s['displayName'])' uses $bad" }
                if ($s['task'] -like 'AzurePowerShell@*') { $s['inputs']['pwsh'] | Should -BeTrue }
                if ($s['task'] -like 'PowerShell@*') { $s['inputs']['pwsh'] | Should -BeTrue }
            }
        }
        $script:Text | Should -Not -Match '(?m)^\s*-\s*(powershell|bash|script|cmd):'
    }
    It 'runs on a self-hosted pool chosen by a parameter, with pwsh as a demand' {
        foreach ($stage in $script:Ado['stages']) {
            $pool = $stage['jobs'][0]['pool']
            $pool['name'] | Should -Be '${{ parameters.agent_pool }}'
            @($pool['demands']) | Should -Contain 'pwsh'
            $pool.Contains('vmImage') | Should -BeFalse
        }
    }
    It 'signs in to Azure through a service connection named by a parameter' {
        foreach ($name in 'Plan', 'Apply') {
            (Get-AzureStep $name)['inputs']['azureSubscription'] | Should -Be '${{ parameters.service_connection }}'
        }
    }
}

Describe 'Azure DevOps OS configuration pipeline: artifacts' {
    It 'publishes the plan artifact and the report artifact even after a failure, with the files the run writes' {
        $plan = @(Get-StageStep ($script:Ado['stages'] | Where-Object { $_['stage'] -eq 'Plan' }))
        $apply = @(Get-StageStep ($script:Ado['stages'] | Where-Object { $_['stage'] -eq 'Apply' }))
        foreach ($case in @(@{ Steps = $plan; Artifact = 'os-configuration-plan' }, @{ Steps = $apply; Artifact = 'os-configuration-report' })) {
            $pub = @($case.Steps | Where-Object { $_['task'] -like 'PublishPipelineArtifact@*' })
            $pub.Count | Should -Be 1
            $pub[0]['inputs']['artifact'] | Should -Be $case.Artifact
            $pub[0]['condition'] | Should -Be 'always()'
            $collect = (@($case.Steps | Where-Object { $_.Contains('pwsh') -and $_['pwsh'] -match 'Copy-Item' } | ForEach-Object { $_['pwsh'] })) -join "`n"
            foreach ($f in 'report.json', 'summary.md', 'os-configuration-events.jsonl') { $collect | Should -Match ([regex]::Escape($f)) }
            $collect | Should -Match 'uploadsummary'
        }
        (($plan | ForEach-Object { $_['pwsh'] }) -join "`n") | Should -Match 'wipe-list\.txt'
    }
}

Describe 'Azure DevOps OS configuration pipeline: no value of any ID or secret' {
    It 'holds no GUID, password, token or key' {
        $script:Text | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $script:Text | Should -Not -Match '(?im)^\s*(password|secret|client-secret|token|key|sas)\s*:\s*[^\s$<{]'
        $script:Text | Should -Not -Match 'AccountKey=|SharedAccessSignature|-----BEGIN|ghp_[A-Za-z0-9]{20,}'
        $script:Text | Should -Not -Match '(?i)ConvertTo-SecureString'
    }
    It 'takes secrets only from a variable group, and sets no variable whose name looks like a secret' {
        @($script:Ado['variables'] | Where-Object { $_.Contains('group') }).Count | Should -BeGreaterThan 0
        foreach ($v in @($script:Ado['variables'] | Where-Object { $_.Contains('name') })) { $v['name'] | Should -Not -Match '(?i)password|secret|token|key|credential' }
        $script:Text | Should -Not -Match '(?i)\$\([^)]*(password|secret)[^)]*\)'
    }
}
