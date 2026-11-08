#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The read-only preconditions before Validate and Deploy. Each is run through a Plan (or Deploy) with a fake adapter, so the
# test also covers the wiring: events, the report and the exit code. No Azure call, no node.

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
    $script:Handoff2690 = Join-Path $TestDrive 'handoff-2690.json'
    (Get-Content -LiteralPath $script:HandoffFile -Raw).Replace('12.2610.1004.50', '12.2690.1003.15') | Set-Content -LiteralPath $script:Handoff2690
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
    function Get-Pre($Result, [string]$Name, [string]$Node) { @($Result.Preconditions | Where-Object { $_.name -eq $Name -and (-not $Node -or $_.node -eq $Node) }) }
    function Get-DeviceIdArc {
        param($World, [string[]]$Nodes)
        foreach ($n in $Nodes) { $World.Nodes[$n] = [pscustomobject]@{ Name = '3f2a9c1e-5b7d-4e21-9a0c-1d2e3f4a5b6c-1'; ResourceId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/3f2a9c1e-5b7d-4e21-9a0c-1d2e3f4a5b6c-1"; Status = 'Connected'; OsVersion = '10.0.26100.32230'; ComputerName = $n } }
    }
}

Describe 'AzureContext, ResourceGroup, ResourceProviders, Permissions' {
    It 'a context for another subscription fails AzureContext' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetContext = { [pscustomobject]@{ SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = '00000000-0000-0000-0000-000000000000'; Account = 'x' } } }
        (Get-Pre $r AzureContext).result | Should -Be 'Failed'
        (Get-Pre $r AzureContext).evidence | Should -Match 'subscription'
        $r.ExitCode | Should -Be 1
    }
    It 'a missing resource group fails and says how to fix it' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetResourceGroup = { $null } }
        (Get-Pre $r ResourceGroup).result | Should -Be 'Failed'
        (Get-Pre $r ResourceGroup).nextAction | Should -Match 'azure.resource_group'
    }
    It 'an unregistered mandatory provider fails with the command, whichever one it is (the full list is in ArmDeploymentRun.ResourceProviders.Tests.ps1)' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetProviderState = { param($Subscription, $Namespace) $null = $Subscription; if ($Namespace -eq 'Microsoft.AzureStackHCI') { 'NotRegistered' } else { 'Registered' } } }
        (Get-Pre $r ResourceProviders).result | Should -Be 'Failed'
        (Get-Pre $r ResourceProviders).evidence | Should -Match 'Microsoft.AzureStackHCI'
        (Get-Pre $r ResourceProviders).nextAction | Should -Match 'Register-AzResourceProvider -ProviderNamespace Microsoft.AzureStackHCI'
        $r2 = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetProviderState = { param($Subscription, $Namespace) $null = $Subscription; if ($Namespace -eq 'Microsoft.Insights') { 'NotRegistered' } else { 'Registered' } } }
        (Get-Pre $r2 ResourceProviders).result | Should -Be 'Failed'
        $r2.ExitCode | Should -Be 1
    }
    It 'Permissions: Owner passes, Reader fails, Contributor (no role assignment write) fails and names it' {
        $owner = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Override @{ GetPermission = { , @([pscustomobject]@{ Actions = @('*'); NotActions = @() }) } }
        (Get-Pre $owner Permissions).result | Should -Be 'Passed'
        $reader = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetPermission = { , @([pscustomobject]@{ Actions = @('*/read'); NotActions = @() }) } }
        (Get-Pre $reader Permissions).result | Should -Be 'Failed'
        $contrib = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetPermission = { , @([pscustomobject]@{ Actions = @('*'); NotActions = @('Microsoft.Authorization/*/Write', 'Microsoft.Authorization/*/Delete') }) } }
        (Get-Pre $contrib Permissions).result | Should -Be 'Failed'
        (Get-Pre $contrib Permissions).evidence | Should -Match 'Microsoft.Authorization/roleAssignments/write'
    }
    It 'Permissions: permissions that cannot be read are a Warning, not a Failure' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetPermission = { @() } }
        (Get-Pre $r Permissions).result | Should -Be 'Warning'
    }
}

Describe 'NamesAvailable and KeyVaultSecrets' {
    It 'a taken storage account name fails; a name that is already in the resource group passes (a re-run)' {
        $taken = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Override @{ TestNameAvailable = { param($Subscription, $ResourceGroup, $Type, $Name) $null = $Subscription, $ResourceGroup, $Type; [pscustomobject]@{ Available = ($Name -ne 'stiicazl01diag'); ExistsInResourceGroup = $false; Reason = 'already taken' } } }
        (Get-Pre $taken NamesAvailable).result | Should -Be 'Failed'
        (Get-Pre $taken NamesAvailable).evidence | Should -Match 'stiicazl01diag'
        $again = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Override @{ TestNameAvailable = { [pscustomobject]@{ Available = $false; ExistsInResourceGroup = $true; Reason = '' } } }
        (Get-Pre $again NamesAvailable).result | Should -Be 'Passed'
    }
    It 'the Key Vault name is checked only when the vault is created, and a soft-deleted name shows as taken' {
        $infra = Get-TestInfra
        $infra.cluster.key_vault.create_new = $false
        $seen = [System.Collections.Generic.List[string]]::new()
        $null = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Validate -Override @{ TestNameAvailable = { param($Subscription, $ResourceGroup, $Type, $Name) $null = $Subscription, $ResourceGroup, $Type; $seen.Add("$Type/$Name"); [pscustomobject]@{ Available = $true; ExistsInResourceGroup = $false; Reason = '' } }.GetNewClosure() }
        $seen | Should -Not -Contain 'keyvault/kv-iic-azl-01'
        $seen | Should -Contain 'storage/stiicazl01diag'
    }
    It 'a secret that is not in the vault fails and names the parameter, the vault and the secret, not the value' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ TestSecret = { param($Vault, $Secret) $null = $Vault; $Secret -ne 'lcm-password' } }
        $c = Get-Pre $r KeyVaultSecrets
        $c.result | Should -Be 'Failed'
        $c.evidence | Should -Match 'AzureStackLCMAdminPassword'
        $c.evidence | Should -Match 'lcm-password'
        $c.evidence | Should -Match 'kv-iic-mgmt-01'
    }
    It 'a vault that is not under key_vaults fails' {
        $infra = Get-TestInfra
        $infra.identity.local_admin.password = 'keyvault://kv-unlisted/local-admin-password'
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        (Get-Pre $r KeyVaultSecrets).result | Should -Be 'Failed'
        (Get-Pre $r KeyVaultSecrets).evidence | Should -Match 'kv-unlisted is not listed under key_vaults'
    }
    It 'the secret values are never read by the check' {
        $w = Get-FakeWorld
        $null = Invoke-TestRun -World $w -Mode Plan
        $w.SecretReads.Count | Should -Be 0
    }
}

Describe 'Arc machines' {
    It 'every node must have a Connected Arc machine in the instance''s resource group' {
        $w = Get-FakeWorld
        $w.Nodes['iic-n01'] = [pscustomobject]@{ Name = 'iic-n01'; ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/iic-n01'; Status = 'Disconnected'; OsVersion = '10.0.26100.32230'; ComputerName = 'iic-n01' }
        $w.Nodes['iic-n02'] = [pscustomobject]@{ Name = 'iic-n02'; ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-other/providers/Microsoft.HybridCompute/machines/iic-n02'; Status = 'Connected'; OsVersion = '10.0.26100.32230'; ComputerName = 'iic-n02' }
        $r = Invoke-TestRun -World $w -Mode Plan
        (Get-Pre $r ArcMachinesConnected iic-n01).result | Should -Be 'Failed'
        (Get-Pre $r ArcMachinesConnected iic-n01).evidence | Should -Match 'Disconnected'
        (Get-Pre $r ArcMachinesConnected iic-n02).evidence | Should -Match 'rg-other'
    }
    It 'a node with no Arc machine fails with what to do' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetArcMachine = { $null } }
        @(Get-Pre $r ArcMachinesConnected | Where-Object result -eq 'Failed').Count | Should -Be 2
    }
    It 'names that follow the host pass ArcMachineNaming' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        @(Get-Pre $r ArcMachineNaming | Where-Object result -eq 'Passed').Count | Should -Be 2
    }
    It 'device-ID Arc names are only a Warning before Validate (Validate does not reach step 0.41)' {
        $w = Get-FakeWorld; Get-DeviceIdArc $w 'iic-n01', 'iic-n02'
        $r = Invoke-TestRun -World $w -Mode Plan -Handoff $script:Handoff2690
        @(Get-Pre $r ArcMachineNaming | Where-Object result -eq 'Warning').Count | Should -Be 2
        (Get-Pre $r ArcMachineNaming iic-n01).evidence | Should -Match 'arc-device-id-name'
        $r.ExitCode | Should -Be 0
    }
    It 'device-ID Arc names on build 2690 BLOCK the Deploy, and no Deploy is submitted' {
        $hash = (Invoke-TestRun -World (Get-FakeWorld) -Mode Plan).Report.parameterHash
        $w = Get-FakeWorld; Get-DeviceIdArc $w 'iic-n01', 'iic-n02'
        $w.Before = Get-TestState -Validation 'Succeeded' -Deployment 'NotStarted'; $w.BeforeArm["azl-validate-$hash"] = [pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' }
        $r = Invoke-TestRun -World $w -Mode Deploy -Handoff $script:Handoff2690
        @(Get-Pre $r ArcMachineNaming | Where-Object result -eq 'Failed').Count | Should -Be 2
        $r.ExitCode | Should -Be 1
        $w.SubmitCalls.Count | Should -Be 0
        (Get-Pre $r ArcMachineNaming iic-n01).nextAction | Should -Match 'acknowledge_known_issues'
    }
    It 'the same on another build only warns, and an acknowledged issue only warns' {
        $hash = (Invoke-TestRun -World (Get-FakeWorld) -Mode Plan).Report.parameterHash
        foreach ($case in @(@{ Handoff = $script:HandoffFile; Settings = @{} }, @{ Handoff = $script:Handoff2690; Settings = @{ acknowledgeKnownIssues = @('arc-device-id-name') } })) {
            $w = Get-FakeWorld; Get-DeviceIdArc $w 'iic-n01', 'iic-n02'
            $w.Before = Get-TestState -Validation 'Succeeded' -Deployment 'NotStarted'; $w.BeforeArm["azl-validate-$hash"] = [pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' }
            $w.After['deploy'] = @(Get-TestState -Validation 'Succeeded' -Deployment 'Succeeded' -DeploymentSteps @(Get-TestStep '0.57' 'Done' 'Success' 0 @() '2026-11-07T13:30:00Z')); $w.ArmAfter['deploy'] = @([pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' })
            $r = Invoke-TestRun -World $w -Mode Deploy -Handoff $case.Handoff -Settings $case.Settings
            @(Get-Pre $r ArcMachineNaming | Where-Object result -eq 'Failed') | Should -BeNullOrEmpty
            $r.ExitCode | Should -Be 0
        }
    }
    It 'a name that differs from the host but is not a device ID is a Warning that points at nodes[].arc_machine_name' {
        $w = Get-FakeWorld
        $w.Nodes['iic-n01'] = [pscustomobject]@{ Name = 'arc-iic-n01'; ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/arc-iic-n01'; Status = 'Connected'; OsVersion = '10.0.26100.32230'; ComputerName = 'iic-n01' }
        $r = Invoke-TestRun -World $w -Mode Plan
        (Get-Pre $r ArcMachineNaming iic-n01).result | Should -Be 'Warning'
        (Get-Pre $r ArcMachineNaming iic-n01).evidence | Should -Match 'arc_machine_name'
    }
}

Describe 'OS configuration, build and SBE' {
    It 'without a report the check is Skipped and says what to run; with require_os_configuration_report it fails' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -OsReport $null
        (Get-Pre $r OsConfigurationConverged).result | Should -Be 'Skipped'
        $r2 = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -OsReport $null -Settings @{ requireOsConfigurationReport = $true }
        (Get-Pre $r2 OsConfigurationConverged).result | Should -Be 'Failed'
        $r2.ExitCode | Should -Be 1
    }
    It 'a report for another cluster fails' {
        $infra = Get-TestInfra
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan -OsReport (Get-TestOsReport -Infra $infra -Cluster 'other-clus')
        (Get-Pre $r OsConfigurationConverged).result | Should -Be 'Failed'
        (Get-Pre $r OsConfigurationConverged).evidence | Should -Match 'other-clus'
    }
    It 'a node that is not in the report fails; the others pass' {
        $infra = Get-TestInfra
        $report = Get-TestOsReport -Infra $infra
        $report.nodes = @($report.nodes[0])
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan -OsReport $report -Settings @{}
        (Get-Pre $r OsConfigurationConverged iic-n02).result | Should -Be 'Failed'
        (Get-Pre $r OsConfigurationConverged iic-n01).result | Should -Be 'Passed'
    }
    It 'a plan report with nothing to change counts as converged; pending changes and errors do not' {
        $infra = Get-TestInfra
        $report = Get-TestOsReport -Infra $infra
        $report.mode = 'Plan'
        foreach ($n in $report.nodes) { $n.converged = $false }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan -OsReport $report
        @(Get-Pre $r OsConfigurationConverged | Where-Object result -eq 'Passed').Count | Should -Be 2
        $report.nodes[1].planned.changes = 3
        $r2 = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan -OsReport $report
        (Get-Pre $r2 OsConfigurationConverged iic-n02).result | Should -Be 'Failed'
        (Get-Pre $r2 OsConfigurationConverged iic-n02).evidence | Should -Match '3 change'
    }
    It 'an old report is a Warning' {
        $infra = Get-TestInfra
        $report = Get-TestOsReport -Infra $infra
        $report.generatedUtc = '2026-11-01T00:00:00.0000000Z'
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan -OsReport $report
        (Get-Pre $r OsConfigurationConverged iic-n01).result | Should -Be 'Warning'
        $r.ExitCode | Should -Be 0
    }
    It 'reads a report directory with report.json and node-reports/' {
        $infra = Get-TestInfra
        $dir = Join-Path $TestDrive 'osreport'
        $null = New-Item -ItemType Directory -Path (Join-Path $dir 'node-reports') -Force
        $report = Get-TestOsReport -Infra $infra
        $full = $report | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        foreach ($n in $full.nodes) { $n.PSObject.Properties.Remove('ports'); $n.PSObject.Properties.Remove('sanDisks') }
        $full | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dir 'report.json')
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dir 'node-reports' 'all.json')
        $read = Read-AzlArmOsReport -Path $dir
        @($read.nodes[0].ports).Count | Should -BeGreaterThan 3
        @($read.nodes[0].sanDisks).Count | Should -Be 2
    }
    It 'nodes on different OS builds fail OsBuildConsistent' {
        $w = Get-FakeWorld
        $w.Nodes['iic-n02'] = [pscustomobject]@{ Name = 'iic-n02'; ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/iic-n02'; Status = 'Connected'; OsVersion = '10.0.25398.1'; ComputerName = 'iic-n02' }
        $r = Invoke-TestRun -World $w -Mode Plan
        (Get-Pre $r OsBuildConsistent).result | Should -Be 'Failed'
        (Get-Pre $r OsBuildConsistent).evidence | Should -Match 'iic-n02=10.0.25398.1'
    }
    It 'no SBE configured is Passed with the note that the deployment has no Solution Builder Extension (the SBE is opt-in)' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        $p = Get-Pre $r SbeConsistent
        $p.result | Should -Be 'Passed'
        $p.evidence | Should -Match 'deploying without a Solution Builder Extension'
    }
    It 'no hardware.sbe block at all is the same: Passed, never Warning' {
        $infra = Get-TestInfra
        $infra.hardware.Remove('sbe')
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        (Get-Pre $r SbeConsistent).result | Should -Be 'Passed'
        (Get-Pre $r SbeConsistent).evidence | Should -Match 'deploying without a Solution Builder Extension'
    }
    It 'an SBE version without a family is a Warning that names hardware.sbe.family' {
        $infra = Get-TestInfra
        $infra.hardware.sbe = [ordered]@{ publisher = 'Dell'; version = '4.1.2506.9' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        (Get-Pre $r SbeConsistent).result | Should -Be 'Warning'
        (Get-Pre $r SbeConsistent).nextAction | Should -Match 'hardware.sbe.family'
    }
    It 'SBE values in the file pass' {
        $infra = Get-TestInfra
        $infra.hardware.sbe = [ordered]@{ publisher = 'Dell'; family = 'AX-Series'; version = '4.1.2506.9'; manifest_source = 'https://example.invalid/m.xml'; manifest_creation_date = '2026-06-01' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        (Get-Pre $r SbeConsistent).result | Should -Be 'Passed'
    }
}

Describe 'DNS, time and identity' {
    It 'no DNS servers (static management) fails; an invalid address fails; DHCP does not need them' {
        $infra = Get-TestInfra; $infra.networking.management.dns_servers = @()
        (Get-Pre (Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan) DnsAndTime).result | Should -Be 'Failed'
        $infra2 = Get-TestInfra; $infra2.networking.management.dns_servers = @('dns.example.invalid')
        (Get-Pre (Invoke-TestRun -World (Get-FakeWorld) -Infra $infra2 -Mode Plan) DnsAndTime).evidence | Should -Match 'not an IP address'
    }
    It 'no NTP server is a Warning' {
        $infra = Get-TestInfra; $infra.networking.ntp_servers = @()
        (Get-Pre (Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan) DnsAndTime).result | Should -Be 'Warning'
    }
    It 'a pending Dns change in the OS report fails' {
        $infra = Get-TestInfra
        $report = Get-TestOsReport -Infra $infra
        $report.nodes[0].plan = @([pscustomobject]@{ step = 'Dns'; action = 'Change' })
        (Get-Pre (Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan -OsReport $report) DnsAndTime).evidence | Should -Match 'iic-n01 still has a pending Dns change'
    }
    It 'a domain the DNS servers cannot resolve from this host is a Warning (a runner may not reach them)' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ ResolveDns = { $false } }
        (Get-Pre $r DnsAndTime).result | Should -Be 'Warning'
        $r.ExitCode | Should -Be 0
    }
    It 'Active Directory: an OU at the top of the domain fails; an OU or LCM user that is not there fails; no AD access is Skipped' {
        $infra = Get-TestInfra; $infra.identity.active_directory.ou_path = 'DC=improbability,DC=cloud'
        (Get-Pre (Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan) ActiveDirectoryPrepared).evidence | Should -Match 'top level'
        $missing = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ TestActiveDirectory = { [pscustomobject]@{ OuExists = $false; LcmUserExists = $true } } }
        (Get-Pre $missing ActiveDirectoryPrepared).result | Should -Be 'Failed'
        (Get-Pre $missing ActiveDirectoryPrepared).evidence | Should -Match 'OU=iic-clus01'
        $none = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ TestActiveDirectory = { $null } }
        (Get-Pre $none ActiveDirectoryPrepared).result | Should -Be 'Skipped'
        (Get-Pre $none ActiveDirectoryPrepared).nextAction | Should -Match 'Invoke-AzStackHciExternalActiveDirectoryValidation'
    }
    It 'an LCM user name over 20 characters is bad input (exit 2) naming the key' {
        $infra = Get-TestInfra; $infra.identity.active_directory.lcm_user.username = 'lcm-user-name-that-is-too-long'
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'lcm_user.username'
    }
    It 'local identity runs the local identity check and not the Active Directory one' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-TestInfra -Identity local_identity) -Mode Plan
        @(Get-Pre $r LocalIdentityPrerequisites).Count | Should -Be 1
        @(Get-Pre $r ActiveDirectoryPrepared).Count | Should -Be 0
        $r.ExitCode | Should -Be 0
    }
}

Describe 'Leftover state, the runner and the skip list' {
    It 'a running deployment or an instance that is already deployed blocks a Validate' {
        $running = Get-FakeWorld; $running.Before = Get-TestState -Validation 'Succeeded' -Deployment 'InProgress'
        (Get-Pre (Invoke-TestRun -World $running -Mode Validate) NoLeftoverFailedDeployment).result | Should -Be 'Failed'
        $done = Get-FakeWorld; $done.Before = Get-TestState -Validation 'Succeeded' -Deployment 'Succeeded'
        (Get-Pre (Invoke-TestRun -World $done -Mode Validate) NoLeftoverFailedDeployment).evidence | Should -Match 'already deployed'
    }
    It '-AllowRevalidate lets a Validate through a failed state (support-guided only)' {
        $w = Get-FakeWorld; $w.Before = Get-TestState -Prov 'Failed' -Validation 'Succeeded' -Deployment 'Error'
        (Get-Pre (Invoke-TestRun -World $w -Mode Plan -Settings @{ allowRevalidate = $true }) NoLeftoverFailedDeployment).result | Should -Be 'Passed'
    }
    It 'a precondition on the skip list is recorded as Skipped on purpose, not hidden' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Settings @{ skipPreconditions = @('Permissions') } -Override @{ GetPermission = { , @([pscustomobject]@{ Actions = @('*/read'); NotActions = @() }) } }
        (Get-Pre $r Permissions).result | Should -Be 'Skipped'
        (Get-Pre $r Permissions).evidence | Should -Match 'on purpose'
    }
    It 'a check that throws is a Failure with the message; a missing adapter member is a Skip' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetProviderState = { throw 'HTTP 403 reading providers' } }
        (Get-Pre $r ResourceProviders).result | Should -Be 'Failed'
        (Get-Pre $r ResourceProviders).evidence | Should -Match 'could not run.*403'
        $r2 = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetPermission = $null }
        (Get-Pre $r2 Permissions).result | Should -Be 'Skipped'
    }
    It 'every precondition writes a PreconditionChecked event with its name and result' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        $events = Read-TestEvent $r.EventPath | Where-Object state -eq 'PreconditionChecked'
        foreach ($name in 'AzureContext', 'ResourceGroup', 'ResourceProviders', 'Permissions', 'KeyVaultSecrets', 'ArcMachinesConnected', 'OsConfigurationConverged', 'DnsAndTime', 'ActiveDirectoryPrepared', 'NoLeftoverFailedDeployment') {
            @($events | Where-Object name -eq $name).Count | Should -BeGreaterThan 0
        }
        @($events | Where-Object { $_.name -eq 'ArcMachinesConnected' }).node | Should -Be @('iic-n01', 'iic-n02')
    }
}

Describe 'A DNS probe that cannot run' {
    It 'is unknown, not a failed lookup: the check passes and says the domain was not resolved' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ ResolveDns = { $null } }
        (Get-Pre $r DnsAndTime).result | Should -Be 'Passed'
        (Get-Pre $r DnsAndTime).evidence | Should -Match 'not resolved'
    }
}
