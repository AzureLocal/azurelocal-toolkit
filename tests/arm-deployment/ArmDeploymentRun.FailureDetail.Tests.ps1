#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The whole reason of a failed validation step (report.json, summary.md, the event feed) and the steps of earlier runs.
# The fake Azure payload is shaped like the real one: the exception text of step 170 'ValidateCluster' holds the EnvironmentValidator
# Results as JSON, and the Detail of the Test-Cluster result holds the [!!Failed!!] and [!!Warning!!] lines. No Azure call, no node.

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'ArmDeploymentRun.Helpers.ps1'))
    $script:TemplateFile = Join-Path $TestDrive 'template.json'
    '{ "parameters": {}, "resources": [] }' | Set-Content -LiteralPath $script:TemplateFile
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    $script:DiskSentence = 'Two disks have been found on node iic-azl-n01 that cannot be distinguished from one another. The disk signature and the identifiers in SCSI page 83h VPD are the same for both, so the cluster cannot tell which disk is which. Check the storage mapping of the node.'
    $script:ReportFile = 'C:\Users\lcmuser\AppData\Local\Temp\AzStackHciEnvironmentChecker-ClusterValidationReport-2026.11.07-12.20.31.htm'
    # What Test-Cluster said, as it sits in AdditionalData.Detail.
    $script:ClusterDetail = @(
        "Test-Cluster finished. Report: $($script:ReportFile)"
        '[!!Warning!!] Network - Validate Network Communication: Node iic-azl-n02 has an adapter without a default gateway.'
        "[!!Failed!!] Storage - List Disks: $($script:DiskSentence)"
        ''
        'Inventory - List Cluster Network Information: passed') -join "`r`n"
    $results = @(
        [ordered]@{ Name = 'AzStackHci_Cluster_Validate'; Title = 'Cluster validation'; Description = 'Run Test-Cluster on the node set before the cluster is created'; Status = 'FAILURE'; Severity = 'CRITICAL'; Remediation = 'https://aka.ms/hci-envch'; AdditionalData = [ordered]@{ Source = 'iic-azl-n01'; Detail = $script:ClusterDetail } }
        [ordered]@{ Name = 'AzStackHci_Network_Test'; Description = 'Network is reachable'; Status = 'SUCCESS'; Severity = 'INFORMATIONAL'; Remediation = 'https://aka.ms/hci-envch'; AdditionalData = [ordered]@{ Detail = 'ok' } })
    $script:ResultsJson = ConvertTo-Json -InputObject @($results) -Depth 10 -Compress
    $script:ValidateClusterError = "Type 'ValidateCluster' of Role 'EnvironmentValidator' raised an exception:`r`n`r`nThe environment validation failed. Results: $($script:ResultsJson)"
    $script:Done = [pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' }

    function Get-FailedValidateState {
        param([string[]]$Errors = @($script:ValidateClusterError), [string]$Index = '0.170', [string]$Name = 'ValidateCluster', [object[]]$Extra = @())
        Get-TestState -Validation 'Failed' -ValidationSteps (@(
                Get-TestStep '0.1' 'Validate environment' 'Error' 0 @() '2026-11-07T12:12:00Z'
                Get-TestStep $Index $Name 'Error' 1 $Errors '2026-11-07T12:12:00Z') + @($Extra))
    }
    function Invoke-FailedValidate {
        param([object]$State)
        $w = Get-FakeWorld
        $w.After['validate'] = @($State); $w.ArmAfter['validate'] = @($script:Done)
        Invoke-TestRun -World $w -Mode Validate
    }
}

Describe 'Test-Cluster text' {
    It 'lists each failed and warned check with its whole message' {
        $checks = @(Get-AzlArmClusterCheck $script:ClusterDetail)
        $failed = @($checks | Where-Object Status -eq 'Failed')
        $warned = @($checks | Where-Object Status -eq 'Warning')
        $failed.Count | Should -Be 1
        $failed[0].Name | Should -Be 'Storage - List Disks'
        $failed[0].Message | Should -Be $script:DiskSentence
        $warned.Count | Should -Be 1
        $warned[0].Name | Should -Be 'Network - Validate Network Communication'
        $warned[0].Message | Should -Match 'default gateway'
    }
    It 'joins a marker line with the Category - Check: sentence that follows it' {
        $text = "[!!Failed!!] Storage - List Disks`nStorage - List Disks: Two disks have been found on node n01 that cannot be distinguished from one another.`n"
        $checks = @(Get-AzlArmClusterCheck $text)
        $checks.Count | Should -Be 1
        $checks[0].Status | Should -Be 'Failed'
        $checks[0].Message | Should -Match 'cannot be distinguished from one another'
    }
    It 'reads a text whose line breaks are the two characters backslash n' {
        $checks = @(Get-AzlArmClusterCheck ('[!!Failed!!] Storage - List Disks: first sentence.\r\n[!!Warning!!] Network - X: second.'))
        @($checks.Status) | Should -Be @('Failed', 'Warning')
    }
    It 'finds the report file on the node, also when the backslashes are doubled by JSON' {
        Get-AzlArmTestClusterReportPath "see $($script:ReportFile) for more" | Should -Be $script:ReportFile
        Get-AzlArmTestClusterReportPath ($script:ReportFile.Replace('\', '\\')) | Should -Be $script:ReportFile
        Get-AzlArmTestClusterReportPath 'nothing here' | Should -Be ''
    }
}

Describe 'Failure detail of one step' {
    It 'keeps every result with Name, Description, Status, Remediation and AdditionalData.Detail, and the pointer to the report file' {
        $step = Get-TestStep '0.170' 'ValidateCluster' 'Error' 1 @($script:ValidateClusterError)
        $d = Get-AzlArmFailureDetail -Step $step
        $d.Results.Count | Should -Be 2
        $r = $d.Results | Where-Object Name -eq 'AzStackHci_Cluster_Validate'
        $r.Description | Should -Match 'Run Test-Cluster'
        $r.Remediation | Should -Be 'https://aka.ms/hci-envch'
        $r.Detail | Should -Be $script:ClusterDetail
        @($d.Checks | Where-Object { $_.Status -in 'Failed', 'Warning' }).Count | Should -Be 2
        @($d.Checks | Where-Object Status -eq 'Info').Count | Should -Be 1
        $d.ReportFile | Should -Be $script:ReportFile
        $d.Text | Should -Be $script:ValidateClusterError
    }
    It 'reads an exception that is an object (the ErrorJson of the step) the same way' {
        $obj = [ordered]@{ message = 'EnvironmentValidator failed'; results = @([ordered]@{ Name = 'AzStackHci_Hardware_Test'; Description = 'Hardware is supported'; Status = 'FAILURE'; Remediation = 'https://aka.ms/hci-envch'; AdditionalData = [ordered]@{ Detail = 'The model is not in the catalog.' } }) }
        $step = [pscustomobject]@{ Errors = @('EnvironmentValidator failed'); ErrorJson = @(ConvertTo-Json -InputObject $obj -Depth 10 -Compress) }
        $d = Get-AzlArmFailureDetail -Step $step
        $d.Results.Count | Should -Be 1
        $d.Results[0].Detail | Should -Be 'The model is not in the catalog.'
    }
    It 'a plain text with no structure still comes back whole' {
        $text = 'x' * 5000
        (Get-AzlArmFailureDetail -Step ([pscustomobject]@{ Errors = @($text); ErrorJson = @() })).Text | Should -Be $text
    }
    It 'the one-line form is cut, never the report, and always ends with the report path' {
        $d = Get-AzlArmFailureDetail -Step (Get-TestStep '0.170' 'ValidateCluster' 'Error' 1 @($script:ValidateClusterError))
        $short = Format-AzlArmFailureLine -Detail $d -Max 120 -ReportPath 'C:\r\report.json'
        $short | Should -Match '\.\.\. \(full text: C:\\r\\report\.json\)$'
        $short | Should -Not -Match "[\r\n]"
        $long = Format-AzlArmFailureLine -Detail $d -Max 2000 -ReportPath 'C:\r\report.json'
        $long | Should -Match 'SCSI page 83h VPD'
        $long | Should -Match 'full text: C:\\r\\report\.json\)$'
    }
}

Describe 'Get-AzlDeploymentState keeps the whole exception' {
    It 'an object exception without a message becomes JSON, not "@{...}", and ErrorJson holds every object' {
        $long = 'y' * 3000
        $payload = [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Failed'; reportedProperties = [pscustomobject]@{
                    validationStatus = [pscustomobject]@{ status = 'Failed'; steps = @([pscustomobject]@{ name = 'ValidateCluster'; status = 'Error'; fullStepIndex = '0.170'; startTimeUtc = '2026-11-07T12:10:00Z'; endTimeUtc = '2026-11-07T12:12:00Z'; exception = @($long, [pscustomobject]@{ results = @([pscustomobject]@{ Name = 'N'; Status = 'FAILURE' }) }) }) } } } }
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm { $payload }.GetNewClosure()
        $s = Get-AzlDeploymentState -SubscriptionId 'x' -ResourceGroup 'y' -ClusterName 'z'
        $step = $s.ValidationSteps | Where-Object FullStepIndex -eq '0.170'
        $step.Errors[0] | Should -Be $long
        $step.Errors[1] | Should -Match '"results"'
        @($step.ErrorJson).Count | Should -Be 1
    }
}

Describe 'Run: a validation that fails at step 170 ValidateCluster' {
    BeforeAll {
        $script:R = Invoke-FailedValidate -State (Get-FailedValidateState)
        $script:Report = Get-Content -LiteralPath $script:R.ReportPath -Raw | ConvertFrom-Json
        $script:Summary = Get-Content -LiteralPath $script:R.SummaryPath -Raw
        $script:Events = Read-TestEvent $script:R.EventPath
    }
    It 'fails the run with exit 1 and names the step' {
        $script:R.ExitCode | Should -Be 1
        $script:R.State | Should -Be 'ValidationFailed'
        $script:R.Message | Should -Match '0\.170'
    }
    It 'report.json holds the full error text, untruncated' {
        $step = $script:Report.validate.failedSteps[0]
        $step.step | Should -Be '0.170'
        $step.errors[0] | Should -Be $script:ValidateClusterError
        $step.errors[0] | Should -Match 'disk signature'
        $step.errors[0] | Should -Match 'SCSI page 83h VPD'
        $script:Report.validate.error | Should -Match 'SCSI page 83h VPD'
    }
    It 'report.json holds every nested result with Name, Description, Status, Remediation and the Detail' {
        $res = @($script:Report.validate.failedSteps[0].results)
        $res.Count | Should -Be 2
        $r = $res | Where-Object name -eq 'AzStackHci_Cluster_Validate'
        $r.description | Should -Match 'Run Test-Cluster'
        $r.status | Should -Be 'FAILURE'
        $r.remediation | Should -Be 'https://aka.ms/hci-envch'
        $r.detail | Should -Be $script:ClusterDetail
    }
    It 'report.json lists the Test-Cluster checks and the report file on the node' {
        $s = $script:Report.validate.failedSteps[0]
        @($s.checks | Where-Object status -eq 'Failed').message | Should -Be $script:DiskSentence
        @($s.checks | Where-Object status -eq 'Warning').Count | Should -Be 1
        $s.testClusterReportFile | Should -Be $script:ReportFile
    }
    It 'summary.md lists each failed and warned check with its message, the report file and the remediation' {
        $script:Summary | Should -Match ([regex]::Escape("**Failed** Storage - List Disks: $($script:DiskSentence)"))
        $script:Summary | Should -Match '\*\*Warning\*\* Network - Validate Network Communication: Node iic-azl-n02'
        $script:Summary | Should -Match ([regex]::Escape($script:ReportFile))
        $script:Summary | Should -Match 'Remediation: https://aka\.ms/hci-envch'
        $script:Summary | Should -Match '1 other check\(s\) passed'
        $script:Summary | Should -Not -Match 'List Di\.\.\.'
        $script:Summary | Should -Not -Match 'List Cluster Network Information'
    }
    It 'the one-line message is cut only at the end and ends with the path of the report' {
        $script:R.Message | Should -Match ([regex]::Escape("(full text: $($script:R.ReportPath))") + '$')
        $script:R.Message | Should -Match 'Storage - List Disks'
    }
    It 'the step event and the failed event carry the whole text in detail and the checks as data' {
        $step = $script:Events | Where-Object { $_.state -eq 'ValidationStep' -and $_.step -eq '0.170' } | Select-Object -Last 1
        $step.level | Should -Be 'Error'
        $step.detail | Should -Be $script:ValidateClusterError
        @($step.checks | Where-Object { $_.status -in 'Failed', 'Warning' }).Count | Should -Be 2
        $step.testClusterReportFile | Should -Be $script:ReportFile
        $step.evidence | Should -Match ([regex]::Escape($script:R.ReportPath))
        $failed = $script:Events | Where-Object state -eq 'ValidationFailed'
        $failed.detail | Should -Match 'SCSI page 83h VPD'
        $failed.evidence | Should -Match ([regex]::Escape($script:R.ReportPath) + '\)$')
    }
}

Describe 'Run: other failures' {
    It 'an EnvironmentValidator step that is not Test-Cluster lists each non-passing result with its Remediation URL' {
        $results = @(
            [ordered]@{ Name = 'AzStackHci_Connectivity_Endpoint'; Description = 'Required endpoints are reachable'; Status = 'FAILURE'; Remediation = 'https://aka.ms/hci-envch#connectivity'; AdditionalData = [ordered]@{ Detail = 'login.microsoftonline.com was not reachable.' } }
            [ordered]@{ Name = 'AzStackHci_Hardware_Test'; Description = 'Hardware is supported'; Status = 'WARNING'; Remediation = 'https://aka.ms/hci-envch#hardware'; AdditionalData = [ordered]@{ Detail = 'Firmware is older than the baseline.' } }
            [ordered]@{ Name = 'AzStackHci_Time_Test'; Description = 'Time is in sync'; Status = 'SUCCESS'; Remediation = 'https://aka.ms/hci-envch#time'; AdditionalData = [ordered]@{ Detail = 'ok' } })
        $text = "Type 'InvokeEnvironmentChecker' of Role 'EnvironmentValidator' raised an exception: $(ConvertTo-Json -InputObject @($results) -Depth 10 -Compress)"
        $r = Invoke-FailedValidate -State (Get-FailedValidateState -Errors @($text) -Index '0.60' -Name 'InvokeEnvironmentChecker')
        $summary = Get-Content -LiteralPath $r.SummaryPath -Raw
        $summary | Should -Match 'FAILURE\*\* `AzStackHci_Connectivity_Endpoint`: Required endpoints are reachable'
        $summary | Should -Match 'Remediation: https://aka\.ms/hci-envch#connectivity'
        $summary | Should -Match 'Detail: login\.microsoftonline\.com was not reachable\.'
        $summary | Should -Match 'WARNING\*\* `AzStackHci_Hardware_Test`'
        $summary | Should -Not -Match 'AzStackHci_Time_Test'
        $rep = Get-Content -LiteralPath $r.ReportPath -Raw | ConvertFrom-Json
        @($rep.validate.failedSteps[0].results).Count | Should -Be 3
    }
    It 'a failure with no structure shows the whole error text in summary.md' {
        $text = ('A long plain error. ' * 80).Trim()
        $r = Invoke-FailedValidate -State (Get-FailedValidateState -Errors @($text) -Index '0.9' -Name 'Plain')
        (Get-Content -LiteralPath $r.SummaryPath -Raw) | Should -Match ([regex]::Escape($text))
        (Get-Content -LiteralPath $r.ReportPath -Raw | ConvertFrom-Json).validate.failedSteps[0].errors[0] | Should -Be $text
        $r.Message | Should -Match 'full text: '
    }
    It 'secrets are still removed from the full text' {
        $text = 'The call failed with Sup3r-S3cret-Value! in the body.'
        $w = Get-FakeWorld
        $w.After['validate'] = @(Get-FailedValidateState -Errors @($text) -Index '0.9' -Name 'Plain'); $w.ArmAfter['validate'] = @($script:Done)
        $r = Invoke-TestRun -World $w -Mode Validate
        (Get-Content -LiteralPath $r.ReportPath -Raw) | Should -Not -Match 'Sup3r-S3cret'
        (Get-Content -LiteralPath $r.SummaryPath -Raw) | Should -Not -Match 'Sup3r-S3cret'
        (Get-Content -LiteralPath $r.EventPath -Raw) | Should -Not -Match 'Sup3r-S3cret'
    }
}

Describe 'Steps of an earlier run' {
    BeforeAll {
        $script:OldStep = Get-TestStep '0.60' 'InvokeEnvironmentChecker' 'Error' 1 @('Old run: the connectivity check failed for login.microsoftonline.com.') '2026-11-05T08:00:00Z'
    }
    It 'Select-AzlArmCurrentStep drops a step whose time is before the run started and keeps a step with no time' {
        $steps = @($script:OldStep, (Get-TestStep '0.170' 'ValidateCluster' 'Error' 1 @('new') '2026-11-07T12:12:00Z'), (Get-TestStep '0.200' 'Later' 'NotStarted' 1 @() ''))
        $split = Select-AzlArmCurrentStep -Steps $steps -Since ([datetime]::Parse('2026-11-07T12:00:00Z').ToUniversalTime()) -DeploymentName 'azl-validate-0123456789ab'
        @($split.Current.FullStepIndex) | Should -Be @('0.170', '0.200')
        @($split.Ignored).Count | Should -Be 1
        $split.Ignored[0].FullStepIndex | Should -Be '0.60'
        $split.Ignored[0].Reason | Should -Match 'before this run started'
    }
    It 'Select-AzlArmCurrentStep drops a step that names another deployment hash, and keeps the current one' {
        $steps = @(
            (Get-TestStep '0.1' 'Other' 'Error' 0 @('Failure of azl-validate-aaaaaaaaaaaa') '')
            (Get-TestStep '0.2' 'Mine' 'Error' 0 @('Failure of azl-validate-0123456789ab') ''))
        $split = Select-AzlArmCurrentStep -Steps $steps -DeploymentName 'azl-validate-0123456789ab'
        @($split.Current.FullStepIndex) | Should -Be @('0.2')
        $split.Ignored[0].Reason | Should -Match 'azl-validate-aaaaaaaaaaaa'
    }
    It 'without a start time and a name nothing is dropped' {
        @((Select-AzlArmCurrentStep -Steps @($script:OldStep)).Current).Count | Should -Be 1
    }
    It 'the old 0.60 error is not attributed to the new run: not the failing step, not in the events, not in the report steps' {
        $r = Invoke-FailedValidate -State (Get-FailedValidateState -Extra @($script:OldStep))
        $r.ExitCode | Should -Be 1
        $rep = Get-Content -LiteralPath $r.ReportPath -Raw | ConvertFrom-Json
        @($rep.validate.failedSteps).Count | Should -Be 1
        $rep.validate.failedSteps[0].step | Should -Be '0.170'
        @($rep.validate.steps.step) | Should -Not -Contain '0.60'
        @($rep.validate.ignoredSteps.step) | Should -Be @('0.60')
        $events = Read-TestEvent $r.EventPath
        @($events | Where-Object { $_.step -eq '0.60' }).Count | Should -Be 0
        (Get-Content -LiteralPath $r.EventPath -Raw) | Should -Not -Match 'Old run: the connectivity check'
        $ignoredEvent = $events | Where-Object state -eq 'StaleStepsIgnored'
        @($ignoredEvent).Count | Should -Be 1
        $ignoredEvent.step | Should -Be ''
        @($ignoredEvent.ignoredSteps.step) | Should -Be @('0.60')
        $r.Message | Should -Not -Match 'Old run'
        (Get-Content -LiteralPath $r.SummaryPath -Raw) | Should -Match 'Ignored 1 step\(s\) of an earlier run: 0\.60 InvokeEnvironmentChecker'
    }
    It 'a step of another deployment name is not attributed to the new run either' {
        $other = Get-TestStep '0.61' 'Leftover' 'Error' 1 @('Failed in azl-validate-ffffffffffff') '2026-11-07T12:13:00Z'
        $r = Invoke-FailedValidate -State (Get-FailedValidateState -Extra @($other))
        $rep = Get-Content -LiteralPath $r.ReportPath -Raw | ConvertFrom-Json
        @($rep.validate.failedSteps.step) | Should -Be @('0.170')
        @($rep.validate.ignoredSteps.step) | Should -Be @('0.61')
    }
    It 'an attached deployment keeps the steps it already has (nothing is dropped by time)' {
        $plan = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        $hash = $plan.Report.parameterHash
        $busy = Get-TestState -Validation 'InProgress' -ValidationSteps @(Get-TestStep '0.1' 'Validate environment' 'InProgress' 0 @() '2026-11-07T11:00:00Z')
        $failed = Get-TestState -Validation 'Failed' -ValidationSteps @(Get-TestStep '0.170' 'ValidateCluster' 'Error' 1 @('boom') '2026-11-07T11:30:00Z')
        $w = Get-FakeWorld
        $w.Before = $busy; $w.BeforeArm["azl-validate-$hash"] = [pscustomobject]@{ ProvisioningState = 'Running'; Error = ''; Timestamp = '2026-11-07T11:00:00Z' }
        $w.PreReads = 2; $w.Submitted = $true; $w.LastMode = 'validate'
        $w.After['validate'] = @($failed); $w.ArmAfter['validate'] = @($script:Done)
        $r = Invoke-TestRun -World $w -Mode Validate
        $r.Report.validate.action | Should -Be 'Attach'
        @($r.Report.validate.failedSteps.step) | Should -Be @('0.170')
        @($r.Report.validate.ignoredSteps).Count | Should -Be 0
    }
}
