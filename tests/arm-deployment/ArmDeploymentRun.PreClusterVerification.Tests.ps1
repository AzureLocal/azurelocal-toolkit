#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The precondition PreClusterVerification of the ARM Validate and Deploy: the run goes ahead only with a passing, current result of the pre-cluster
# verification gate for the same infrastructure file; -SkipPreClusterVerification is the only bypass and is recorded. Fakes only: no Azure, no node.

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlPreClusterGate.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'ArmDeploymentRun.Helpers.ps1'))
    $script:TemplateFile = Join-Path $TestDrive 'template.json'
    '{ "parameters": {}, "resources": [] }' | Set-Content -LiteralPath $script:TemplateFile
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    function New-GateEnvironment {
        <# An infrastructure file on disk, and the directory the gate would write to. #>
        $infra = Get-TestInfra
        $dir = Join-Path $TestDrive ('gate-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = New-Item -ItemType Directory -Path (Join-Path $dir 'env'), (Join-Path $dir 'live')
        $file = Join-Path $dir 'env\infrastructure.yml'
        ($infra | ConvertTo-Yaml) | Set-Content -LiteralPath $file -Encoding utf8NoBOM
        [pscustomobject]@{ Infra = $infra; File = $file; Live = (Join-Path $dir 'live') }
    }
    function Write-GateResult {
        <# A result of the gate as the gate writes it (report.json of the contract), valid at the time of the fake clock (2026-11-07T12:00:00Z). #>
        param($Env, [hashtable]$Override = @{})
        $r = [ordered]@{ schema = 1; runId = 'run0123456789'; mode = 'Verify'; partial = $false; verdict = 'Pass'; cluster = 'iic-clus01'; fileHash = (Get-AzlPclFileHash -Path $Env.File); expiresUtc = '2026-11-07T16:00:00.0000000Z'; checks = @() }
        foreach ($k in $Override.Keys) { $r[$k] = $Override[$k] }
        $r | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Env.Live 'report.json')
    }
    function Invoke-GatedRun($Env, [string]$Mode = 'Validate', [hashtable]$Settings = @{}) {
        $s = $Settings.Clone()
        if (-not $s.ContainsKey('skipPreClusterVerification')) { $s['skipPreClusterVerification'] = $false }
        if (-not $s.ContainsKey('preClusterVerificationReportDirectory')) { $s['preClusterVerificationReportDirectory'] = $Env.Live }
        $w = Get-FakeWorld
        $r = Invoke-TestRun -World $w -Infra $Env.Infra -InfraFile $Env.File -Mode $Mode -Settings $s
        $r | Add-Member -NotePropertyName World -NotePropertyValue $w -Force
        $r
    }
    function Get-Gate($Result) { @($Result.Preconditions | Where-Object { $_.name -eq 'PreClusterVerification' }) }
}

Describe 'No result of the gate' {
    It 'fails Mode Validate, names the exact command, and submits nothing' {
        $e = New-GateEnvironment
        $r = Invoke-GatedRun $e
        (Get-Gate $r).result | Should -Be 'Failed'
        (Get-Gate $r).evidence | Should -Match 'no result of the pre-cluster verification'
        (Get-Gate $r).nextAction | Should -Match 'Invoke-AzureLocalPreClusterVerification\.ps1'
        (Get-Gate $r).nextAction | Should -Match '-Mode Verify'
        (Get-Gate $r).nextAction | Should -Match ([regex]::Escape($e.File))
        $r.ExitCode | Should -Be 1
        $r.World.SubmitCalls.Count | Should -Be 0
        $r.NextAction | Should -Match 'Invoke-AzureLocalPreClusterVerification'
    }
    It 'fails Mode Deploy the same way' {
        $e = New-GateEnvironment
        $r = Invoke-GatedRun $e -Mode Deploy
        (Get-Gate $r).result | Should -Be 'Failed'
        $r.ExitCode | Should -Be 1
    }
    It 'only warns in Mode Plan, which never blocks' {
        $e = New-GateEnvironment
        $r = Invoke-GatedRun $e -Mode Plan
        (Get-Gate $r).result | Should -Be 'Warning'
        $r.ExitCode | Should -Be 0
    }
}

Describe 'A result of the gate' {
    It 'lets the Validate go ahead when the verdict is Pass, the hash is the file''s and it has not expired' {
        $e = New-GateEnvironment
        Write-GateResult $e
        $r = Invoke-GatedRun $e
        (Get-Gate $r).result | Should -Be 'Passed'
        (Get-Gate $r).evidence | Should -Match 'valid until'
        $r.Report.preClusterVerification.status | Should -Be 'Passed'
        $r.Report.preClusterVerification.runId | Should -Be 'run0123456789'
    }
    It 'refuses a result whose hash is not the hash of the file now' {
        $e = New-GateEnvironment
        Write-GateResult $e
        Add-Content $e.File "`n# edited after the verification"
        $r = Invoke-GatedRun $e
        (Get-Gate $r).result | Should -Be 'Failed'
        (Get-Gate $r).evidence | Should -Match 'changed since the verification'
        $r.World.SubmitCalls.Count | Should -Be 0
    }
    It 'refuses an expired result' {
        $e = New-GateEnvironment
        Write-GateResult $e @{ expiresUtc = '2026-11-07T11:59:00.0000000Z' }
        (Get-Gate (Invoke-GatedRun $e)).evidence | Should -Match 'expired'
    }
    It 'refuses a Fail verdict, a partial run and a result that is not a Verify' {
        $e = New-GateEnvironment
        Write-GateResult $e @{ verdict = 'Fail'; checks = @(@{ blocking = $true }) }
        (Get-Gate (Invoke-GatedRun $e)).evidence | Should -Match 'verdict Fail'
        Write-GateResult $e @{ partial = $true }
        (Get-Gate (Invoke-GatedRun $e)).evidence | Should -Match 'only some categories'
        Write-GateResult $e @{ mode = 'Plan' }
        (Get-Gate (Invoke-GatedRun $e)).evidence | Should -Match 'only a Verify run counts'
    }
    It 'looks in the environment data folder by default (arm-report\verification\live next to the evidence folder)' {
        $e = New-GateEnvironment
        $data = Join-Path $TestDrive 'site'
        $null = New-Item -ItemType Directory -Path (Join-Path $data 'arm-report\verification\live')
        $e.Infra.provisioning['simplified'] = [ordered]@{ evidence_path = (Join-Path $data 'evidence') }
        ($e.Infra | ConvertTo-Yaml) | Set-Content -LiteralPath $e.File -Encoding utf8NoBOM
        $live = Join-Path $data 'arm-report\verification\live'
        $e.Live = $live
        Write-GateResult $e
        $w = Get-FakeWorld
        $r = Invoke-TestRun -World $w -Infra $e.Infra -InfraFile $e.File -Mode Validate -Settings @{ skipPreClusterVerification = $false }
        (Get-Gate $r).result | Should -Be 'Passed'
    }
}

Describe '-SkipPreClusterVerification' {
    It 'is the only bypass: warned loudly, recorded in the report, the summary and the feed, and the run goes ahead' {
        $e = New-GateEnvironment

        $r = Invoke-GatedRun $e -Settings @{ skipPreClusterVerification = $true }
        (Get-Gate $r).result | Should -Be 'Warning'
        (Get-Gate $r).evidence | Should -Match 'BYPASSED'
        $r.Report.preClusterVerification.status | Should -Be 'Bypassed'
        $r.Report.preClusterVerification.bypassed | Should -BeTrue
        (Get-Content $r.SummaryPath -Raw) | Should -Match 'BYPASSED with -SkipPreClusterVerification'
        $report = Get-Content $r.ReportPath -Raw | ConvertFrom-Json
        $report.preClusterVerification.status | Should -Be 'Bypassed'
        $event = Read-TestEvent $r.EventPath | Where-Object { $_.step -eq 'PreClusterVerification' }
        $event.level | Should -Be 'Warning'
        $event.evidence | Should -Match 'BYPASSED'
        $r.World.SubmitCalls.Count | Should -BeGreaterThan 0 -Because "the run goes ahead and submits the Validate"
    }
    It 'is not read from the master file or a settings file' {
        $infra = Get-TestInfra
        $infra['deployment'] = [ordered]@{ skip_pre_cluster_verification = $true }
        { Get-AzlArmRunSetting -Infrastructure $infra } | Should -Throw '*explicit switch*'
    }
    It 'is a switch of the wrapper script and of the run' {
        (Get-Command Invoke-AzlArmDeploymentRun).Parameters.Keys | Should -Contain 'SkipPreClusterVerification'
        $script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-05-cluster-deployment', 'Invoke-AzureLocalArmDeployment.ps1')
        (Get-Content $script -Raw) | Should -Match '\[switch\]\$SkipPreClusterVerification'
    }
}
