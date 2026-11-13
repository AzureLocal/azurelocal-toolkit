#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the ARM Validate and Deploy run: settings, state machine, polling on a fake clock, failing step, known issues,
# idempotent re-runs, resume, approval, events, report and exit codes. No Azure call is made: the adapter is a fake.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/arm-deployment

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    $script:HandoffFile = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'handoff.v2.json')
    . ([IO.Path]::Combine($PSScriptRoot, 'ArmDeploymentRun.Helpers.ps1'))
    $script:TemplateFile = Join-Path $TestDrive 'template.json'
    '{ "parameters": {}, "resources": [] }' | Set-Content -LiteralPath $script:TemplateFile
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
}

Describe 'Settings' {
    It 'has defaults' {
        $s = Get-AzlArmRunSetting
        $s.validateTimeoutMinutes | Should -Be 90
        $s.deployTimeoutMinutes | Should -Be 360
        $s.pollSeconds | Should -Be 15
        $s.approvalMode | Should -Be 'stop'
        $s.resume | Should -BeFalse
    }
    It 'takes the master file block, in snake_case, then the settings hashtable over it' {
        $infra = @{ deployment = @{ validate_timeout_minutes = 45; approval = 'prompt'; resume = $true; acknowledge_known_issues = @('arc-device-id-name') } }
        $s = Get-AzlArmRunSetting -Infrastructure $infra -Settings @{ approvalMode = 'none'; pollSeconds = 5 }
        $s.validateTimeoutMinutes | Should -Be 45
        $s.approvalMode | Should -Be 'none'
        $s.resume | Should -BeTrue
        $s.pollSeconds | Should -Be 5
        $s.acknowledgeKnownIssues | Should -Contain 'arc-device-id-name'
    }
    It 'reads a settings file' {
        $f = Join-Path $TestDrive 'settings.json'
        '{ "deployTimeoutMinutes": 200 }' | Set-Content -LiteralPath $f
        (Get-AzlArmRunSetting -ConfigPath $f).deployTimeoutMinutes | Should -Be 200
    }
    It 'rejects an unknown key, a bad approval mode and a zero timeout as bad input (exit 2)' {
        foreach ($bad in @(@{ nonsense = 1 }, @{ approvalMode = 'maybe' }, @{ validateTimeoutMinutes = 0 })) {
            $e = $null
            try { Get-AzlArmRunSetting -Settings $bad } catch { $e = $_.Exception }
            $e | Should -Not -BeNullOrEmpty
            $e.Data['AzlExit'] | Should -Be 2
        }
    }
}

Describe 'Run state machine' {
    It '<From> -> <To> is <Allowed>' -ForEach @(
        @{ From = 'Start'; To = 'Prepared'; Allowed = $true }
        @{ From = 'Prepared'; To = 'Validating'; Allowed = $true }
        @{ From = 'Prepared'; To = 'Resumed'; Allowed = $true }
        @{ From = 'Prepared'; To = 'Deploying'; Allowed = $true }
        @{ From = 'Validating'; To = 'ValidationPassed'; Allowed = $true }
        @{ From = 'Validating'; To = 'ValidationFailed'; Allowed = $true }
        @{ From = 'Validating'; To = 'ValidationTimedOut'; Allowed = $true }
        @{ From = 'ValidationPassed'; To = 'AwaitingApproval'; Allowed = $true }
        @{ From = 'AwaitingApproval'; To = 'Deploying'; Allowed = $true }
        @{ From = 'Resumed'; To = 'Deploying'; Allowed = $true }
        @{ From = 'Deploying'; To = 'DeploymentSucceeded'; Allowed = $true }
        @{ From = 'Deploying'; To = 'DeploymentFailed'; Allowed = $true }
        @{ From = 'Deploying'; To = 'DeploymentTimedOut'; Allowed = $true }
        @{ From = 'Prepared'; To = 'AwaitingApproval'; Allowed = $false }
        @{ From = 'Validating'; To = 'Deploying'; Allowed = $false }
        @{ From = 'ValidationFailed'; To = 'Deploying'; Allowed = $false }
        @{ From = 'ValidationFailed'; To = 'Validating'; Allowed = $false }
        @{ From = 'DeploymentFailed'; To = 'Deploying'; Allowed = $false }
        @{ From = 'DeploymentSucceeded'; To = 'Validating'; Allowed = $false }
        @{ From = 'Deploying'; To = 'Prepared'; Allowed = $false }
    ) {
        Test-AzlArmRunTransition -From $From -To $To | Should -Be $Allowed
    }
    It 'records the history and throws on a transition the design does not allow' {
        $s = New-AzlArmRunState
        Set-AzlArmRunState -State $s -To Prepared -Reason 'read'
        Set-AzlArmRunState -State $s -To Validating
        $s.Current | Should -Be 'Validating'
        $s.History.Count | Should -Be 2
        $s.History[1].from | Should -Be 'Prepared'
        { Set-AzlArmRunState -State $s -To Deploying } | Should -Throw '*cannot go to*'
        $s.Current | Should -Be 'Validating'
    }
}

Describe 'Polling on a fake clock' {
    BeforeAll {
        function Get-PollRun($World, [hashtable]$Settings = @{}) {
            $set = Get-AzlArmRunSetting -Settings $Settings
            @{ Adapter = (Get-FakeAdapter -World $World); Settings = $set; Subscription = 'sub'; ResourceGroup = 'rg'; Cluster = 'c'; RunId = 'r'; Mode = 'Validate'; SchemaVersion = '5'; EventPath = '' }
        }
        $script:Running = Get-TestState -Validation 'InProgress' -ValidationSteps @(Get-TestStep '0' 'Env' 'InProgress')
        $script:Done = Get-TestState -Validation 'Succeeded' -ValidationSteps @(Get-TestStep '0' 'Env' 'Success')
        $script:ArmRun = [pscustomobject]@{ ProvisioningState = 'Running'; Error = ''; Timestamp = '' }
        $script:ArmOk = [pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' }
    }
    It 'waits 15 s, then 22.5, 33.75, ... up to 120 s (times 1.5 each read)' {
        $w = Get-FakeWorld; $w.Submitted = $true; $w.LastMode = 'validate'
        $w.After['validate'] = @($script:Running, $script:Running, $script:Running, $script:Running, $script:Running, $script:Running, $script:Running, $script:Running, $script:Done)
        $w.ArmAfter['validate'] = @($script:ArmRun, $script:ArmRun, $script:ArmRun, $script:ArmRun, $script:ArmRun, $script:ArmRun, $script:ArmRun, $script:ArmRun, $script:ArmOk)
        $run = Get-PollRun $w
        $out = Wait-AzlArmPhase -Run $run -Phase Validate -DeploymentName 'azl-validate-x' -Submitted $w.Clock.Time -TimeoutMinutes 90
        $out.Outcome | Should -Be 'Succeeded'
        $w.Clock.Sleeps[0] | Should -Be 15
        $w.Clock.Sleeps[1] | Should -Be 22.5
        $w.Clock.Sleeps[2] | Should -Be 33.75
        ($w.Clock.Sleeps | Measure-Object -Maximum).Maximum | Should -Be 120
        $w.Clock.Sleeps.Count | Should -Be 8
    }
    It 'a 6 hour Deploy that never ends times out at the limit, without waiting in real time' {
        $w = Get-FakeWorld; $w.Submitted = $true; $w.LastMode = 'deploy'
        $w.After['deploy'] = @(Get-TestState -Validation 'Succeeded' -Deployment 'InProgress' -DeploymentSteps @(Get-TestStep '0.1' 'Begin cloud deployment' 'InProgress'))
        $w.ArmAfter['deploy'] = @($script:ArmRun)
        $run = Get-PollRun $w
        $start = $w.Clock.Time
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = Wait-AzlArmPhase -Run $run -Phase Deploy -DeploymentName 'azl-deploy-x' -Submitted $start -TimeoutMinutes 360
        $sw.Stop()
        $out.Outcome | Should -Be 'TimedOut'
        ($w.Clock.Time - $start).TotalMinutes | Should -BeGreaterOrEqual 359.9
        ($w.Clock.Time - $start).TotalMinutes | Should -BeLessOrEqual 360.1
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
    }
    It 'a status read that fails is retried; five in a row end the wait as failed' {
        $w = Get-FakeWorld; $w.Submitted = $true; $w.LastMode = 'validate'; $w.PollFailures = 2
        $w.After['validate'] = @($script:Done); $w.ArmAfter['validate'] = @($script:ArmOk)
        (Wait-AzlArmPhase -Run (Get-PollRun $w) -Phase Validate -DeploymentName 'azl-validate-x' -Submitted $w.Clock.Time -TimeoutMinutes 90).Outcome | Should -Be 'Succeeded'
        $w2 = Get-FakeWorld; $w2.Submitted = $true; $w2.LastMode = 'validate'; $w2.PollFailures = 99
        $out = Wait-AzlArmPhase -Run (Get-PollRun $w2) -Phase Validate -DeploymentName 'azl-validate-x' -Submitted $w2.Clock.Time -TimeoutMinutes 90
        $out.Outcome | Should -Be 'Failed'
        $out.Reason | Should -Match '5 times in a row'
    }
    It 'ignores the status of an earlier attempt until the new submission produces its own' {
        $w = Get-FakeWorld; $w.Submitted = $true; $w.LastMode = 'validate'
        $old = Get-TestState -Validation 'Failed' -ValidationSteps @(Get-TestStep '0.3' 'Old step' 'Error' 0 @('old failure') '2026-11-07T08:00:00Z')
        $fresh = Get-TestState -Validation 'Succeeded' -ValidationSteps @(Get-TestStep '0.3' 'Env' 'Success' 0 @() '2026-11-07T12:20:00Z')
        $w.After['validate'] = @($old, $old, $fresh); $w.ArmAfter['validate'] = @($script:ArmRun, $script:ArmRun, $script:ArmOk)
        $out = Wait-AzlArmPhase -Run (Get-PollRun $w) -Phase Validate -DeploymentName 'azl-validate-x' -Submitted $w.Clock.Time -TimeoutMinutes 90
        $out.Outcome | Should -Be 'Succeeded'
        $w.Clock.Sleeps.Count | Should -Be 2
    }
}

Describe 'Phase outcome' {
    It '<Name>' -ForEach @(
        @{ Name = 'Validate: ARM finished and validation succeeded and fresh is Succeeded'; Phase = 'Validate'; Arm = 'Succeeded'; Val = 'Succeeded'; Dep = ''; End = '2026-11-07T12:10:00Z'; Expect = 'Succeeded' }
        @{ Name = 'Validate: validation succeeded but ARM still running keeps waiting'; Phase = 'Validate'; Arm = 'Running'; Val = 'Succeeded'; Dep = ''; End = '2026-11-07T12:10:00Z'; Expect = 'Running' }
        @{ Name = 'Validate: failed and fresh is Failed'; Phase = 'Validate'; Arm = 'Succeeded'; Val = 'Failed'; Dep = ''; End = '2026-11-07T12:10:00Z'; Expect = 'Failed' }
        @{ Name = 'Validate: failed but stale (earlier attempt) keeps waiting'; Phase = 'Validate'; Arm = 'Running'; Val = 'Failed'; Dep = ''; End = '2026-11-07T09:00:00Z'; Expect = 'Running' }
        @{ Name = 'Any: ARM deployment failed is Failed'; Phase = 'Deploy'; Arm = 'Failed'; Val = 'Succeeded'; Dep = 'InProgress'; End = '2026-11-07T12:10:00Z'; Expect = 'Failed' }
        @{ Name = 'Deploy: deployment succeeded (ARM lagging) is Succeeded'; Phase = 'Deploy'; Arm = 'Running'; Val = 'Succeeded'; Dep = 'Succeeded'; End = '2026-11-07T12:10:00Z'; Expect = 'Succeeded' }
        @{ Name = 'Deploy: in progress keeps waiting'; Phase = 'Deploy'; Arm = 'Running'; Val = 'Succeeded'; Dep = 'InProgress'; End = '2026-11-07T12:10:00Z'; Expect = 'Running' }
        @{ Name = 'Deploy: Error status while ARM runs is Failed'; Phase = 'Deploy'; Arm = 'Running'; Val = 'Succeeded'; Dep = 'Error'; End = '2026-11-07T12:10:00Z'; Expect = 'Failed' }
    ) {
        $steps = @(Get-TestStep '0.1' 'S' 'Success' 0 @() $End)
        $state = Get-TestState -Validation $Val -Deployment $Dep -ValidationSteps $steps -DeploymentSteps $steps
        $arm = [pscustomobject]@{ ProvisioningState = $Arm; Error = ''; Timestamp = '' }
        (Get-AzlArmPhaseOutcome -Phase $Phase -Arm $arm -State $state -Submitted ([datetime]'2026-11-07T12:00:00Z').ToUniversalTime()).Outcome | Should -Be $Expect
    }
}

Describe 'Failing step' {
    It 'finds the deepest failing step and quotes the portal step number' {
        $steps = @(
            Get-TestStep '0' 'Cloud deployment' 'Success'
            Get-TestStep '0.40' 'Deploy Moc and ARB Stack' 'Success' 1
            Get-TestStep '0.41' 'Deploy Arc infrastructure components' 'Error' 1 @('ParentResourceNotFound: parent resource machines/tplabs-azl-n01 was not found')
            Get-TestStep '0.41.2' 'DeployVmoArcExtension' 'Error' 2 @('ParentResourceNotFound: machines/tplabs-azl-n01')
            Get-TestStep '0.42' 'Next' 'NotStarted' 1)
        $f = @(Get-AzlArmFailedStep -Steps $steps)
        $f.Count | Should -Be 1
        $f[0].FullStepIndex | Should -Be '0.41.2'
        $f[0].Name | Should -Be 'DeployVmoArcExtension'
    }
    It 'lists two independent failures, in order' {
        $steps = @((Get-TestStep '0.1' 'A' 'Error' 0 @('a')), (Get-TestStep '0.2' 'B' 'Success'), (Get-TestStep '0.3' 'C' 'Failed' 0 @('c')))
        @(Get-AzlArmFailedStep -Steps $steps).FullStepIndex | Should -Be @('0.1', '0.3')
    }
    It 'is empty when nothing failed' {
        @(Get-AzlArmFailedStep -Steps @(Get-TestStep '0.1' 'A' 'Success')) | Should -BeNullOrEmpty
    }
}

Describe 'Known issues' {
    It 'the data file has the issues the design lists, each with a cause and a remediation' {
        $ids = @(Get-AzlArmKnownIssue | ForEach-Object { $_['id'] })
        foreach ($id in 'arc-device-id-name', 'arc-device-id-name-step-0-41', 'unsupported-os-version', 'registration-5901', 'role-assignment-already-exists', 'role-assignment-zombie', 'license-sync-after-failed-validate', 'ad-prerequisites', 'dns-resolution') { $ids | Should -Contain $id }
        foreach ($i in Get-AzlArmKnownIssue) { $i['cause'] | Should -Not -BeNullOrEmpty; @($i['remediation']).Count | Should -BeGreaterThan 0; $i['retry'] | Should -BeIn 'none', 'after-fix', 'resubmit-once', 'no-validate'; $i['confidence'] | Should -BeIn 'documented', 'observed', 'pattern' }
    }
    It 'maps the real 2026-11-06 failure (step 0.41, ParentResourceNotFound, build 2690) to the device-ID Arc name issue' {
        $k = Find-AzlArmKnownIssue -Phase Deploy -StepId '0.41' -StepName 'Deploy Arc infrastructure components' -ErrorText 'ParentResourceNotFound: The Resource Microsoft.HybridCompute/machines/tplabs-azl-n01 was not found' -Build '12.2690.1003.15'
        $k.Id | Should -Be 'arc-device-id-name'
        $k.Retry | Should -Be 'none'
        $k.BuildNote | Should -BeNullOrEmpty
        $k.Remediation.Count | Should -BeGreaterThan 2
    }
    It 'step 0.41 alone, with other text, still points at the same family' {
        (Find-AzlArmKnownIssue -Phase Deploy -StepId '0.41' -StepName 'Something else' -ErrorText 'Unknown error').Id | Should -Be 'arc-device-id-name-step-0-41'
    }
    It 'says when the build is not one the issue was seen on' {
        (Find-AzlArmKnownIssue -Phase Deploy -StepId '0.41' -StepName 'Deploy Arc infrastructure components' -ErrorText 'ParentResourceNotFound' -Build '12.2610.1004.50').BuildNote | Should -Match 'Not yet seen on build 12.2610'
    }
    It 'maps "<Text>" (<Phase>) to <Id>' -ForEach @(
        @{ Phase = 'Validate'; Text = 'Unsupported OS version 10.0.25398.1'; Id = 'unsupported-os-version' }
        @{ Phase = 'Deploy'; Text = 'Error 5901: forbidden on the target Arc machine'; Id = 'registration-5901' }
        @{ Phase = 'Validate'; Text = 'The role assignment already exists. RoleAssignmentExists'; Id = 'role-assignment-already-exists' }
        @{ Phase = 'Validate'; Text = 'Tenant ID, application ID, principal ID, and scope aren''t allowed to be updated'; Id = 'role-assignment-zombie' }
        @{ Phase = 'Validate'; Text = 'could cause license sync problems: license sync'; Id = 'license-sync-after-failed-validate' }
        @{ Phase = 'Validate'; Text = 'AzStackHci_ExternalActiveDirectory_Test failed: the organizational unit is missing'; Id = 'ad-prerequisites' }
        @{ Phase = 'Validate'; Text = 'DNS resolution failed: No such host is known'; Id = 'dns-resolution' }
        @{ Phase = 'Validate'; Text = 'The selected physical network adapter is not binded to the management virtual switch'; Id = 'vmswitch-not-bound' }
    ) {
        (Find-AzlArmKnownIssue -Phase $Phase -ErrorText $Text).Id | Should -Be $Id
    }
    It 'returns nothing for an unknown failure, and respects the phase' {
        Find-AzlArmKnownIssue -Phase Validate -StepId '0.7' -StepName 'X' -ErrorText 'Something new' | Should -BeNullOrEmpty
        Find-AzlArmKnownIssue -Phase Validate -StepId '0.41' -StepName 'Deploy Arc infrastructure components' -ErrorText 'ParentResourceNotFound' | Should -BeNullOrEmpty
    }
}

Describe 'Idempotent decisions' {
    It 'Validate: <Name>' -ForEach @(
        @{ Name = 'no cluster resource submits'; Has = $false; Val = ''; Arm = ''; Kind = 'Submit' }
        @{ Name = 'already validated with these parameters is skipped'; Has = $true; Val = 'Succeeded'; Arm = 'Succeeded'; Kind = 'Skip' }
        @{ Name = 'validated but not by these parameters submits'; Has = $true; Val = 'Succeeded'; Arm = ''; Kind = 'Submit' }
        @{ Name = 'our validation running is attached to'; Has = $true; Val = 'InProgress'; Arm = 'Running'; Kind = 'Attach' }
        @{ Name = 'a validation we did not start is refused'; Has = $true; Val = 'InProgress'; Arm = ''; Kind = 'Refuse' }
        @{ Name = 'a failed validation submits again'; Has = $true; Val = 'Failed'; Arm = 'Succeeded'; Kind = 'Submit' }
    ) {
        $state = if ($Has) { Get-TestState -Validation $Val } else { $null }
        $arm = if ($Arm) { [pscustomobject]@{ ProvisioningState = $Arm } } else { $null }
        (Resolve-AzlArmValidateAction -State $state -ArmValidate $arm).Kind | Should -Be $Kind
    }
    It 'Validate: revalidate submits even when validated' {
        (Resolve-AzlArmValidateAction -State (Get-TestState -Validation 'Succeeded') -ArmValidate ([pscustomobject]@{ ProvisioningState = 'Succeeded' }) -Revalidate).Kind | Should -Be 'Submit'
    }
    It 'Deploy: <Name>' -ForEach @(
        @{ Name = 'validated, nothing deployed submits'; Has = $true; Prov = 'Succeeded'; Val = 'Succeeded'; Dep = 'NotStarted'; Resume = $false; Kind = 'Submit' }
        @{ Name = 'nothing validated is refused'; Has = $false; Prov = ''; Val = ''; Dep = ''; Resume = $false; Kind = 'Refuse' }
        @{ Name = 'validation failed is refused'; Has = $true; Prov = 'Succeeded'; Val = 'Failed'; Dep = ''; Resume = $false; Kind = 'Refuse' }
        @{ Name = 'a running deployment is attached to'; Has = $true; Prov = 'Succeeded'; Val = 'Succeeded'; Dep = 'InProgress'; Resume = $false; Kind = 'Attach' }
        @{ Name = 'a failed deployment is refused without resume'; Has = $true; Prov = 'Failed'; Val = 'Succeeded'; Dep = 'Error'; Resume = $false; Kind = 'Refuse' }
        @{ Name = 'a failed deployment is resubmitted with resume'; Has = $true; Prov = 'Failed'; Val = 'Succeeded'; Dep = 'Error'; Resume = $true; Kind = 'Resubmit' }
        @{ Name = 'a finished deployment is done'; Has = $true; Prov = 'Succeeded'; Val = 'Succeeded'; Dep = 'Succeeded'; Resume = $false; Kind = 'Done' }
    ) {
        $state = if ($Has) { Get-TestState -Prov $Prov -Validation $Val -Deployment $Dep } else { $null }
        (Resolve-AzlArmDeployAction -State $state -Resume:$Resume).Kind | Should -Be $Kind
    }
}

Describe 'Run: Validate' {
    BeforeAll {
        $script:Steps = @(Get-TestStep '0.1' 'Validate environment' 'Success' 0 @() '2026-11-07T12:10:00Z')
        $script:Passed = Get-TestState -Validation 'Succeeded' -ValidationSteps $script:Steps
        $script:Busy = Get-TestState -Validation 'InProgress' -ValidationSteps @(Get-TestStep '0.1' 'Validate environment' 'InProgress' 0 @() '2026-11-07T12:01:00Z')
        $script:ArmRunning = [pscustomobject]@{ ProvisioningState = 'Running'; Error = ''; Timestamp = '' }
        $script:ArmDone = [pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' }
    }
    It 'submits once, waits, passes: exit 0, state ValidationPassed, the events in order' {
        $w = Get-FakeWorld
        $w.After['validate'] = @($script:Busy, $script:Passed); $w.ArmAfter['validate'] = @($script:ArmRunning, $script:ArmDone)
        $r = Invoke-TestRun -World $w -Mode Validate
        $r.ExitCode | Should -Be 0
        $r.State | Should -Be 'ValidationPassed'
        $w.SubmitCalls.Count | Should -Be 1
        $w.SubmitCalls[0].Mode | Should -Be 'Validate'
        $w.SubmitCalls[0].DeploymentName | Should -Be "azl-validate-$($r.Report.parameterHash)"
        $events = Read-TestEvent $r.EventPath
        $states = @($events.state)
        $states[0] | Should -Be 'RunStarted'
        $states[-1] | Should -Be 'RunCompleted'
        $states.IndexOf('ParametersGenerated') | Should -BeLessThan $states.IndexOf('ValidationSubmitted')
        $states.IndexOf('ValidationSubmitted') | Should -BeLessThan $states.IndexOf('ValidationPassed')
        @($events | Where-Object { $_.state -eq 'ValidationStep' }).Count | Should -BeGreaterThan 0
        (@($events | Where-Object state -eq 'ValidationStep')[0]).step | Should -Be '0.1'
        @($r.Report.stateHistory.to) | Should -Be @('Prepared', 'Validating', 'ValidationPassed')
        Test-Path $r.ReportPath | Should -BeTrue
        Test-Path $r.SummaryPath | Should -BeTrue
    }
    It 'a second run with the same parameters does not submit again (idempotent)' {
        $plan = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        $hash = $plan.Report.parameterHash
        $w = Get-FakeWorld
        $w.Before = $script:Passed; $w.BeforeArm["azl-validate-$hash"] = $script:ArmDone
        $r = Invoke-TestRun -World $w -Mode Validate
        $r.ExitCode | Should -Be 0
        $r.State | Should -Be 'ValidationPassed'
        $w.SubmitCalls.Count | Should -Be 0
        @((Read-TestEvent $r.EventPath).state) | Should -Contain 'ValidationSkipped'
    }
    It 'changed parameters (another hash) are validated again' {
        $w = Get-FakeWorld
        $w.Before = $script:Passed; $w.BeforeArm['azl-validate-000000000000'] = $script:ArmDone
        $w.After['validate'] = @($script:Passed); $w.ArmAfter['validate'] = @($script:ArmDone)
        $r = Invoke-TestRun -World $w -Mode Validate
        $r.ExitCode | Should -Be 0
        $w.SubmitCalls.Count | Should -Be 1
    }
    It 'attaches to its own running validation instead of submitting' {
        $plan = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        $hash = $plan.Report.parameterHash
        $w = Get-FakeWorld
        $w.Before = $script:Busy; $w.BeforeArm["azl-validate-$hash"] = [pscustomobject]@{ ProvisioningState = 'Running'; Error = ''; Timestamp = '2026-11-07T11:59:00Z' }
        $w.PreReads = 2; $w.Submitted = $true; $w.LastMode = 'validate'
        $w.After['validate'] = @($script:Busy, $script:Passed); $w.ArmAfter['validate'] = @($script:ArmRunning, $script:ArmDone)
        $r = Invoke-TestRun -World $w -Mode Validate
        $r.ExitCode | Should -Be 0
        $w.SubmitCalls.Count | Should -Be 0
        $r.State | Should -Be 'ValidationPassed'
    }
    It 'a failed validation: exit 1, the failing step, the known issue, and a fix that says Validate can run again' {
        $failed = Get-TestState -Validation 'Failed' -ValidationSteps @(
            Get-TestStep '0.1' 'Validate environment' 'Error' 0 @() '2026-11-07T12:12:00Z'
            Get-TestStep '0.1.4' 'External Active Directory' 'Error' 1 @('AzStackHci_ExternalActiveDirectory_Test: the organizational unit OU=iic-clus01 was not found') '2026-11-07T12:12:00Z')
        $w = Get-FakeWorld
        $w.After['validate'] = @($failed); $w.ArmAfter['validate'] = @($script:ArmDone)
        $r = Invoke-TestRun -World $w -Mode Validate
        $r.ExitCode | Should -Be 1
        $r.State | Should -Be 'ValidationFailed'
        $r.KnownIssue.Id | Should -Be 'ad-prerequisites'
        $r.Message | Should -Match '0\.1\.4'
        $r.Report.validate.failedSteps[0].step | Should -Be '0.1.4'
        $ev = Read-TestEvent $r.EventPath | Where-Object state -eq 'ValidationFailed'
        $ev.knownIssue | Should -Be 'ad-prerequisites'
        $ev.step | Should -Be '0.1.4'
        $ev.level | Should -Be 'Error'
        $r.NextAction | Should -Match 'ad-prerequisites'
    }
    It 'an unknown failure has no known issue and still names the step' {
        $failed = Get-TestState -Validation 'Failed' -ValidationSteps @(Get-TestStep '0.9' 'Brand new check' 'Error' 0 @('weird') '2026-11-07T12:12:00Z')
        $w = Get-FakeWorld
        $w.After['validate'] = @($failed); $w.ArmAfter['validate'] = @($script:ArmDone)
        $r = Invoke-TestRun -World $w -Mode Validate
        $r.ExitCode | Should -Be 1
        $r.KnownIssue | Should -BeNullOrEmpty
        $r.Message | Should -Match '0\.9'
    }
    It 'refuses to Validate an instance in a failed deployment state (Microsoft: license sync): exit 1, nothing submitted' {
        $w = Get-FakeWorld
        $w.Before = Get-TestState -Prov 'Failed' -Validation 'Succeeded' -Deployment 'Error'
        $r = Invoke-TestRun -World $w -Mode Validate
        $r.ExitCode | Should -Be 1
        $w.SubmitCalls.Count | Should -Be 0
        ($r.Preconditions | Where-Object { $_.name -eq 'NoLeftoverFailedDeployment' }).result | Should -Be 'Failed'
        $r.Message | Should -Match 'NoLeftoverFailedDeployment'
    }
    It 'a validation that does not end in 90 minutes is ValidationTimedOut (exit 1) and Azure is left running' {
        $w = Get-FakeWorld
        $w.After['validate'] = @($script:Busy); $w.ArmAfter['validate'] = @($script:ArmRunning)
        $start = $w.Clock.Time
        $r = Invoke-TestRun -World $w -Mode Validate
        $r.ExitCode | Should -Be 1
        $r.State | Should -Be 'ValidationTimedOut'
        ($w.Clock.Time - $start).TotalMinutes | Should -BeGreaterThan 89
        $r.NextAction | Should -Match 'again to attach'
        @((Read-TestEvent $r.EventPath).state) | Should -Contain 'ValidationTimedOut'
    }
    It '-WhatIf checks everything, writes the report, and submits nothing' {
        $w = Get-FakeWorld
        $r = Invoke-TestRun -World $w -Mode Validate -DryRun
        $r.ExitCode | Should -Be 0
        $w.SubmitCalls.Count | Should -Be 0
        $r.Report.validate.wouldSubmit | Should -Match 'azl-validate-'
        $r.Message | Should -Match 'WhatIf'
        Test-Path $r.ReportPath | Should -BeTrue
    }
}

Describe 'Run: Deploy and resume' {
    BeforeAll {
        $script:ValidatedState = Get-TestState -Validation 'Succeeded' -Deployment 'NotStarted' -ValidationSteps @(Get-TestStep '0.1' 'V' 'Success' 0 @() '2026-11-07T11:00:00Z')
        $script:ArmOkD = [pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' }
        $script:ArmRunD = [pscustomobject]@{ ProvisioningState = 'Running'; Error = ''; Timestamp = '' }
        $script:Deploying = Get-TestState -Validation 'Succeeded' -Deployment 'InProgress' -DeploymentSteps @(Get-TestStep '0.1' 'Begin cloud deployment' 'InProgress' 0 @() '2026-11-07T12:05:00Z')
        $script:Deployed = Get-TestState -Validation 'Succeeded' -Deployment 'Succeeded' -DeploymentSteps @(Get-TestStep '0.57' 'Done' 'Success' 0 @() '2026-11-07T13:30:00Z')
        $script:Fail041 = Get-TestState -Prov 'Failed' -Validation 'Succeeded' -Deployment 'Error' -DeploymentSteps @(
            Get-TestStep '0.40' 'Deploy Moc and ARB Stack' 'Success' 1 @() '2026-11-07T12:40:00Z'
            Get-TestStep '0.41' 'Deploy Arc infrastructure components' 'Error' 1 @('ParentResourceNotFound: machines/tplabs-azl-n01 was not found') '2026-11-07T12:50:00Z')
        function Get-Hash { (Invoke-TestRun -World (Get-FakeWorld) -Mode Plan).Report.parameterHash }
    }
    It 'Deploy without a successful validation is refused by a precondition: exit 1, nothing submitted' {
        $w = Get-FakeWorld
        $r = Invoke-TestRun -World $w -Mode Deploy
        $r.ExitCode | Should -Be 1
        $w.SubmitCalls.Count | Should -Be 0
        ($r.Preconditions | Where-Object name -eq 'ValidatedBeforeDeploy').result | Should -Be 'Failed'
    }
    It 'Deploy after a validation of these parameters submits azl-deploy-<hash> and succeeds' {
        $hash = Get-Hash
        $w = Get-FakeWorld
        $w.Before = $script:ValidatedState; $w.BeforeArm["azl-validate-$hash"] = $script:ArmOkD
        $w.After['deploy'] = @($script:Deploying, $script:Deployed); $w.ArmAfter['deploy'] = @($script:ArmRunD, $script:ArmOkD)
        $r = Invoke-TestRun -World $w -Mode Deploy
        $r.ExitCode | Should -Be 0
        $r.State | Should -Be 'DeploymentSucceeded'
        $w.SubmitCalls[0].Mode | Should -Be 'Deploy'
        $w.SubmitCalls[0].DeploymentName | Should -Be "azl-deploy-$hash"
        @($r.Report.stateHistory.to) | Should -Be @('Prepared', 'Deploying', 'DeploymentSucceeded')
        @((Read-TestEvent $r.EventPath).state) | Should -Contain 'DeploymentSucceeded'
    }
    It 'a Deploy that fails at step 0.41 is matched to the device-ID Arc name issue, and the event carries the step and the issue' {
        $hash = Get-Hash
        $w = Get-FakeWorld
        $w.Before = $script:ValidatedState; $w.BeforeArm["azl-validate-$hash"] = $script:ArmOkD
        $w.After['deploy'] = @($script:Fail041); $w.ArmAfter['deploy'] = @([pscustomobject]@{ ProvisioningState = 'Failed'; Error = 'Deployment failed'; Timestamp = '' })
        $r = Invoke-TestRun -World $w -Mode Deploy -Handoff $script:HandoffFile
        $r.ExitCode | Should -Be 1
        $r.State | Should -Be 'DeploymentFailed'
        $r.KnownIssue.Id | Should -Be 'arc-device-id-name'
        $ev = Read-TestEvent $r.EventPath | Where-Object state -eq 'DeploymentFailed'
        $ev.step | Should -Be '0.41'
        $ev.knownIssue | Should -Be 'arc-device-id-name'
        $r.NextAction | Should -Match 'arc-device-id-name'
        (Get-Content -LiteralPath $r.SummaryPath -Raw) | Should -Match 'Known issue: arc-device-id-name'
    }
    It 'a failed deployment is not retried without -Resume (precondition), and nothing is submitted' {
        $w = Get-FakeWorld
        $w.Before = $script:Fail041
        $r = Invoke-TestRun -World $w -Mode Deploy
        $r.ExitCode | Should -Be 1
        $w.SubmitCalls.Count | Should -Be 0
        ($r.Preconditions | Where-Object name -eq 'NoLeftoverFailedDeployment').result | Should -Be 'Failed'
    }
    It '-Resume of a failure whose known issue says "do not retry" is refused until the issue is acknowledged' {
        $w = Get-FakeWorld
        $w.Before = $script:Fail041
        $r = Invoke-TestRun -World $w -Mode Deploy -Resume
        $r.ExitCode | Should -Be 1
        $w.SubmitCalls.Count | Should -Be 0
        $r.Message | Should -Match 'arc-device-id-name'
        $r.NextAction | Should -Match 'acknowledge_known_issues'
        @((Read-TestEvent $r.EventPath).state) | Should -Contain 'PhaseRefused'
    }
    It '-Resume with the issue acknowledged resubmits the same deployment name, and enters Resumed' {
        $hash = Get-Hash
        $w = Get-FakeWorld
        $w.Before = $script:Fail041
        $w.After['deploy'] = @($script:Deploying, $script:Deployed); $w.ArmAfter['deploy'] = @($script:ArmRunD, $script:ArmOkD)
        $r = Invoke-TestRun -World $w -Mode Deploy -Resume -Settings @{ acknowledgeKnownIssues = @('arc-device-id-name') }
        $r.ExitCode | Should -Be 0
        $w.SubmitCalls.Count | Should -Be 1
        $w.SubmitCalls[0].DeploymentName | Should -Be "azl-deploy-$hash"
        $w.SubmitCalls[0].SkipValidationCheck | Should -BeTrue
        @($r.Report.stateHistory.to) | Should -Be @('Prepared', 'Resumed', 'Deploying', 'DeploymentSucceeded')
        $events = Read-TestEvent $r.EventPath
        @($events.state) | Should -Contain 'DeploymentResumed'
        ($events | Where-Object state -eq 'DeploymentResumed').evidence | Should -Match 'Resubmitted'
    }
    It 'a transient failure (5901) is resumed with -Resume, no acknowledgement needed' {
        $failed5901 = Get-TestState -Prov 'Failed' -Validation 'Succeeded' -Deployment 'Error' -DeploymentSteps @(Get-TestStep '0.5' 'Register' 'Error' 0 @('Error 5901: 403 on the target Arc machine') '2026-11-07T12:50:00Z')
        $w = Get-FakeWorld
        $w.Before = $failed5901
        $w.After['deploy'] = @($script:Deployed); $w.ArmAfter['deploy'] = @($script:ArmOkD)
        $r = Invoke-TestRun -World $w -Mode Deploy -Resume
        $r.ExitCode | Should -Be 0
        $w.SubmitCalls.Count | Should -Be 1
    }
    It 'a running deployment is attached to: nothing is submitted, state Resumed' {
        $w = Get-FakeWorld
        $w.Before = $script:Deploying; $w.PreReads = 2; $w.Submitted = $true; $w.LastMode = 'deploy'
        $w.After['deploy'] = @($script:Deploying, $script:Deployed); $w.ArmAfter['deploy'] = @($script:ArmRunD, $script:ArmOkD)
        $r = Invoke-TestRun -World $w -Mode Deploy
        $r.ExitCode | Should -Be 0
        $w.SubmitCalls.Count | Should -Be 0
        @($r.Report.stateHistory.to) | Should -Be @('Prepared', 'Resumed', 'Deploying', 'DeploymentSucceeded')
    }
    It 'an instance that is already deployed is reported, not deployed again' {
        $w = Get-FakeWorld
        $w.Before = $script:Deployed
        $r = Invoke-TestRun -World $w -Mode Deploy
        $r.ExitCode | Should -Be 0
        $r.State | Should -Be 'DeploymentSucceeded'
        $w.SubmitCalls.Count | Should -Be 0
    }
    It 'a deployment that does not end in 6 hours is DeploymentTimedOut (exit 1), nothing is cancelled' {
        $hash = Get-Hash
        $w = Get-FakeWorld
        $w.Before = $script:ValidatedState; $w.BeforeArm["azl-validate-$hash"] = $script:ArmOkD
        $w.After['deploy'] = @($script:Deploying); $w.ArmAfter['deploy'] = @($script:ArmRunD)
        $start = $w.Clock.Time
        $r = Invoke-TestRun -World $w -Mode Deploy
        $r.ExitCode | Should -Be 1
        $r.State | Should -Be 'DeploymentTimedOut'
        ($w.Clock.Time - $start).TotalMinutes | Should -BeGreaterThan 359
        $r.NextAction | Should -Match 'attach'
    }
}

Describe 'Run: ValidateAndDeploy and the approval gate' {
    BeforeAll {
        $script:VPassed = Get-TestState -Validation 'Succeeded' -ValidationSteps @(Get-TestStep '0.1' 'V' 'Success' 0 @() '2026-11-07T12:10:00Z')
        $script:DDone = Get-TestState -Validation 'Succeeded' -Deployment 'Succeeded' -DeploymentSteps @(Get-TestStep '0.57' 'D' 'Success' 0 @() '2026-11-07T13:30:00Z')
        $script:Ok = [pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' }
        function Get-VdWorld { $w = Get-FakeWorld; $w.After['validate'] = @($script:VPassed); $w.ArmAfter['validate'] = @($script:Ok); $w.After['deploy'] = @($script:DDone); $w.ArmAfter['deploy'] = @($script:Ok); $w }
    }
    It 'approval mode stop (default) ends after Validate in AwaitingApproval with exit 0 and does not deploy' {
        $w = Get-VdWorld
        $r = Invoke-TestRun -World $w -Mode ValidateAndDeploy
        $r.ExitCode | Should -Be 0
        $r.State | Should -Be 'AwaitingApproval'
        $w.SubmitCalls.Count | Should -Be 1
        $w.SubmitCalls[0].Mode | Should -Be 'Validate'
        @((Read-TestEvent $r.EventPath).state) | Should -Contain 'ApprovalRequested'
        $r.NextAction | Should -Match 'Mode Deploy'
    }
    It 'approval none (-AutoApprove) validates, then deploys' {
        $w = Get-VdWorld
        $r = Invoke-TestRun -World $w -Mode ValidateAndDeploy -AutoApprove
        $r.ExitCode | Should -Be 0
        $r.State | Should -Be 'DeploymentSucceeded'
        @($w.SubmitCalls.Mode) | Should -Be @('Validate', 'Deploy')
        @($r.Report.stateHistory.to) | Should -Be @('Prepared', 'Validating', 'ValidationPassed', 'AwaitingApproval', 'Deploying', 'DeploymentSucceeded')
        @((Read-TestEvent $r.EventPath).state) | Should -Contain 'ApprovalGranted'
    }
    It 'approval prompt: yes deploys, no stops' {
        $w = Get-VdWorld
        (Invoke-TestRun -World $w -Mode ValidateAndDeploy -Settings @{ approvalMode = 'prompt' } -Override @{ Prompt = { $true } }).State | Should -Be 'DeploymentSucceeded'
        $w2 = Get-VdWorld
        $r = Invoke-TestRun -World $w2 -Mode ValidateAndDeploy -Settings @{ approvalMode = 'prompt' } -Override @{ Prompt = { $false } }
        $r.State | Should -Be 'AwaitingApproval'
        $w2.SubmitCalls.Count | Should -Be 1
    }
    It 'approval prompt without a console behaves as stop' {
        $w = Get-VdWorld
        (Invoke-TestRun -World $w -Mode ValidateAndDeploy -Settings @{ approvalMode = 'prompt' } -Override @{ Prompt = { $null } }).State | Should -Be 'AwaitingApproval'
    }
    It 'a failed validation never reaches the gate' {
        $w = Get-FakeWorld
        $w.After['validate'] = @(Get-TestState -Validation 'Failed' -ValidationSteps @(Get-TestStep '0.2' 'X' 'Error' 0 @('boom') '2026-11-07T12:10:00Z')); $w.ArmAfter['validate'] = @($script:Ok)
        $r = Invoke-TestRun -World $w -Mode ValidateAndDeploy -AutoApprove
        $r.State | Should -Be 'ValidationFailed'
        $r.ExitCode | Should -Be 1
        @($w.SubmitCalls.Mode) | Should -Be @('Validate')
    }
}

Describe 'Preconditions before the run' {
    It 'names every precondition' {
        Get-AzlArmPreconditionName | Should -Contain 'OsConfigurationConverged'
        Get-AzlArmPreconditionName | Should -Contain 'ArcMachineNaming'
        @(Get-AzlArmPreconditionName).Count | Should -BeGreaterOrEqual 14
    }
    It 'a clean Plan passes every check that can run' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        $r.ExitCode | Should -Be 0
        @($r.Preconditions | Where-Object result -eq 'Failed') | Should -BeNullOrEmpty
        ($r.Preconditions | Where-Object name -eq 'OsConfigurationConverged' | Select-Object -First 1).result | Should -Be 'Passed'
    }
    It 'a node that did not converge fails OsConfigurationConverged for that node' {
        $infra = Get-TestInfra
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan -OsReport (Get-TestOsReport -Infra $infra -NotConverged @('iic-n02'))
        $r.ExitCode | Should -Be 1
        $bad = @($r.Preconditions | Where-Object { $_.name -eq 'OsConfigurationConverged' -and $_.result -eq 'Failed' })
        $bad.Count | Should -Be 1
        $bad[0].node | Should -Be 'iic-n02'
    }
}

Describe 'Events, report and exit codes' {
    It 'every event line has the contract fields, UTC time, stage ArmDeployment' {
        $w = Get-FakeWorld
        $r = Invoke-TestRun -World $w -Mode Plan
        $lines = @(Get-Content -LiteralPath $r.EventPath)
        $lines.Count | Should -BeGreaterThan 5
        foreach ($line in $lines) {
            $e = $line | ConvertFrom-Json
            foreach ($f in 'timestamp', 'node', 'stage', 'step', 'state', 'evidence', 'level', 'nextAction') { $e.PSObject.Properties.Name | Should -Contain $f }
            $e.stage | Should -Be 'ArmDeployment'
            $line | Should -Match '"timestamp":"[^"]+Z"'
            $e.level | Should -BeIn 'Info', 'Warning', 'Error'
        }
        @($lines | ConvertFrom-Json | Where-Object state -eq 'PreconditionChecked').Count | Should -BeGreaterThan 10
        ($lines | ConvertFrom-Json | Where-Object state -eq 'PreconditionChecked' | Select-Object -First 1).result | Should -BeIn 'Passed', 'Failed', 'Warning', 'Skipped'
    }
    It 'the event file is UTF-8 without a BOM and the lines are appended on a second run' {
        $dir = Join-Path $TestDrive 'twice'
        $null = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Dir $dir
        $first = @(Get-Content -LiteralPath (Join-Path $dir 'arm-deployment-events.jsonl')).Count
        $null = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Dir $dir
        @(Get-Content -LiteralPath (Join-Path $dir 'arm-deployment-events.jsonl')).Count | Should -BeGreaterThan $first
        $bytes = [IO.File]::ReadAllBytes((Join-Path $dir 'arm-deployment-events.jsonl'))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
    }
    It 'no secret value is ever written: not in the report, the events, the summary or the parameter file' {
        $hash = (Invoke-TestRun -World (Get-FakeWorld) -Mode Plan).Report.parameterHash
        $w = Get-FakeWorld
        $w.Before = Get-TestState -Validation 'NotStarted'
        $leaky = Get-TestState -Validation 'Failed' -ValidationSteps @(Get-TestStep '0.2' 'Join' 'Error' 0 @('Logon failed for password Sup3r-S3cret-Value! on the node') '2026-11-07T12:10:00Z')
        $w.After['validate'] = @($leaky); $w.ArmAfter['validate'] = @([pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' })
        $r = Invoke-TestRun -World $w -Mode Validate
        $w.SecretReads.Count | Should -BeGreaterThan 0
        $w.SubmitCalls[0].SecretKeys | Should -Contain 'localAdminPassword'
        foreach ($f in Get-ChildItem -LiteralPath $r.ReportDirectory -File) { (Get-Content -LiteralPath $f.FullName -Raw) | Should -Not -Match 'Sup3r-S3cret-Value' }
        (Get-Content -LiteralPath $r.ReportPath -Raw) | Should -Match '\*\*\*'
        $hash | Should -Not -BeNullOrEmpty
    }
    It 'the parameter file has null secrets and the sources table names the keys' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        $p = Get-Content -LiteralPath (Join-Path $r.ReportDirectory 'iic-clus01.parameters.json') -Raw | ConvertFrom-Json
        $p.parameters.localAdminPassword.value | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $r.ReportDirectory 'parameter-sources.md') -Raw) | Should -Match 'identity.local_admin.password'
    }
    It 'exit 2: <Name>' -ForEach @(
        @{ Name = 'a missing infrastructure file'; Extra = @{ InfrastructureFile = 'Z:\no\such\file.yml' } }
        @{ Name = 'no file at all'; Extra = @{} }
        @{ Name = 'a missing OS configuration report'; Extra = @{ OsConfigurationReport = 'Z:\no\report.json' } }
        @{ Name = 'a missing handoff file'; Extra = @{ HandoffFile = 'Z:\no\handoff.json' } }
        @{ Name = 'an unknown setting'; Extra = @{ Settings = @{ bogus = 1 } } }
    ) {
        $a = @{ Mode = 'Plan'; ReportDirectory = (Join-Path $TestDrive 'bad2'); Adapter = (Get-FakeAdapter -World (Get-FakeWorld)) }
        if (-not $Extra.ContainsKey('InfrastructureFile')) { $a.Infrastructure = Get-TestInfra }
        foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
        if ($Name -eq 'no file at all') { $a.Remove('Infrastructure') }
        $r = Invoke-AzlArmDeploymentRun @a
        $r.ExitCode | Should -Be 2
    }
    It 'exit 2: not signed in to Azure when the mode needs it (the run does not sign in itself)' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Override @{ GetContext = { $null } }
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'signed in'
    }
    It 'Plan without a sign-in is allowed: the Azure checks are Skipped, not Failed' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetContext = { $null } }
        $r.ExitCode | Should -Be 0
        ($r.Preconditions | Where-Object name -eq 'ResourceGroup').result | Should -Be 'Skipped'
    }
    It 'exit 2: an unsupported scenario says so (iSCSI SAN with local identity)' {
        $infra = Get-TestInfra -Storage san
        $infra.storage.san.type = 'iscsi'
        $infra.scenario.identity = 'local_identity'
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'iSCSI'
    }
    It 'RunCompleted is the last event and carries the exit code' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        $last = (Read-TestEvent $r.EventPath)[-1]
        $last.state | Should -Be 'RunCompleted'
        $last.exitCode | Should -Be 0
    }
}
