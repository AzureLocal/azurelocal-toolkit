#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the verify pass of the OS configuration run when the node does not answer: a report with no node entry (or a partial one) must be a failure that names
# what is missing, never "Index was outside the bounds of the array". The OS configuration script, Azure and the nodes are all mocked.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/OsConfigurationVerifyRead.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mocks run in the module scope and read these through the global scope; AfterAll removes them.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $nc = [IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration')
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module (Join-Path $nc 'AzlOsConfigurationRun.psm1') -Force
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
}
Describe 'The verification read of a node that does not answer ' {
    BeforeAll {
        $global:VfCalls = [System.Collections.Generic.List[object]]::new()
        $global:VfVerify = 'normal'
        $global:VfApplied = [System.Collections.Generic.HashSet[string]]::new()
        function global:Get-VfFakeSetResult($Parameters, $EventPhase) {
            $name = $Parameters.Node[0]
            $global:VfCalls.Add([pscustomobject]@{ Node = $name; Phase = $EventPhase; Execute = $Parameters.ContainsKey('Execute') })
            if ($Parameters.ContainsKey('Execute')) { [void]$global:VfApplied.Add($name) }
            if ($EventPhase -eq 'Verify') {
                # What the script writes when the node is restarting again and cannot be reached: a report about itself, with no node in it.
                if ($global:VfVerify -eq 'not-ready') { return [pscustomobject]@{ ExitCode = 1; Error = ''; Unknown = $false; Report = [pscustomobject]@{ schemaVersion = 1; executed = $false; error = "NOT READY: 1 node(s) can't be reached over PowerShell remoting. Nothing was changed."; nodes = @() } } }
                if ($global:VfVerify -eq 'no-entry') { return [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Report = [pscustomobject]@{ schemaVersion = 1; nodes = @() } } }
                if ($global:VfVerify -eq 'other-node') { return [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Report = [pscustomobject]@{ schemaVersion = 1; nodes = @([pscustomobject]@{ name = 'somebody-else'; plan = @() }) } } }
                if ($global:VfVerify -eq 'partial') { return [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Report = [pscustomobject]@{ schemaVersion = 1; nodes = @([pscustomobject]@{ name = $name; hostname = $name; domainJoin = [pscustomobject]@{} }) } } }
            }
            $joined = $global:VfApplied.Contains($name)
            $domainJoin = [pscustomobject]@{ applicable = $true; domainJoined = $joined; domain = 'improbability.cloud'; ou = 'OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud'; secureChannel = $joined; credential = 'lcm_user'; error = '' }
            $entry = [pscustomobject]@{
                name = $name; hostname = $name; osVersion = '10.0.26100.1'; converged = $joined; restarted = $joined; ports = @(); sanDisks = @()
                changes = @(if ($joined) { [pscustomobject]@{ Pass = 1; Id = 'DomainJoin/join'; Status = 'changed'; Detail = 'joined' } })
                plan = @([pscustomobject]@{ step = 'DomainJoin'; item = 'domain membership'; current = 'workgroup WORKGROUP'; desired = 'improbability.cloud'; action = $(if ($joined) { 'Ok' } else { 'Change' }); note = '' })
                domainJoin = $domainJoin
            }
            [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Report = [pscustomobject]@{ nodes = @($entry) } }
        }
        $script:Infra = Join-Path $TestDrive 'verify.yml'
        Copy-Item -LiteralPath $script:Fixture -Destination $script:Infra
        function Invoke-VfRun {
            $out = Join-Path $TestDrive "out-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
            $result = Invoke-AzlOsConfiguration -InfrastructureFile $script:Infra -Mode Apply -ReportDirectory $out -SkipValidation -Method Iso -Step DomainJoin -Node 'iic-n01' 6>$null 3>$null
            $result | Add-Member -NotePropertyName Out -NotePropertyValue $out -Force
            $result
        }
    }
    AfterAll { Remove-Item Function:\Get-VfFakeSetResult -ErrorAction SilentlyContinue; Remove-Variable VfCalls, VfVerify, VfApplied -Scope Global -ErrorAction SilentlyContinue }
    BeforeEach {
        $global:VfCalls.Clear(); $global:VfApplied.Clear(); $global:VfVerify = 'normal'
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlSetNodeConfiguration { Get-VfFakeSetResult $Parameters $EventPhase }
        Mock -ModuleName AzlOsConfigurationRun Test-AzlAzureSignedIn { $true }
        Mock -ModuleName AzlOsConfigurationRun Test-AzlWinRmPort { $true }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlRemotingPreCheck {
            foreach ($c in $Candidate) { [pscustomobject]@{ Node = $c.Name; Reachable = $true; Address = @($c.Addresses)[0]; Port = 5985; Result = 'Open'; Credential = 'vault'; Diagnosis = ''; Tried = @($c.Addresses) } }
        }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlSecret { 'not-the-join-password' }
        Mock -ModuleName AzlOsConfigurationRun Find-AzlArcMachine { [pscustomobject]@{ Name = $ArcMachineName; ResourceId = "/subscriptions/x/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ArcMachineName"; Location = 'eastus'; Status = 'Connected'; Interfaces = @() } }
        Mock -ModuleName AzlOsConfigurationRun New-AzlWinRmTransport { [pscustomobject]@{ Kind = 'WinRM' } }
        Mock -ModuleName AzlOsConfigurationRun Get-AzlRunNodeIdentity { [pscustomobject]@{ ComputerName = $Name.ToUpperInvariant(); Mac = @('00:00:5E:00:53:10', '00:00:5E:00:53:20') } }
        Mock -ModuleName AzlOsConfigurationRun Invoke-AzlNodeScript { [pscustomobject]@{ caption = 'Microsoft Azure Stack HCI'; build = 26100; host = 'WIN-X' } }
    }

    It 'a verify read that reports no node (NOT READY, nodes is empty) is a named failure with the reason, never an index error' {
        $global:VfVerify = 'not-ready'
        $result = Invoke-VfRun
        $errors = @($result.Records[0].errors) -join ' | '
        $errors | Should -Not -Match 'Index was outside the bounds'
        $errors | Should -Match 'Verify of iic-n01 failed'
        $errors | Should -Match 'NOT READY'
        $result.Records[0].converged | Should -BeFalse
        $result.ExitCode | Should -Be 1
        @($global:VfCalls | ForEach-Object { "$($_.Phase)" }) | Should -Contain 'Verify'
    }
    It 'a verify read with no node entry and no reason still names what is missing' {
        $global:VfVerify = 'no-entry'
        $result = Invoke-VfRun
        $errors = @($result.Records[0].errors) -join ' | '
        $errors | Should -Not -Match 'Index was outside the bounds'
        $errors | Should -Match "Verify of iic-n01 failed"
        $errors | Should -Match "no entry for iic-n01"
        $result.Records[0].converged | Should -BeFalse
    }
    It 'a verify report that is about another node only is the same named failure' {
        $global:VfVerify = 'other-node'
        $result = Invoke-VfRun
        (@($result.Records[0].errors) -join ' | ') | Should -Match 'no entry for iic-n01'
        $result.Records[0].converged | Should -BeFalse
    }
    It 'a partial entry (the plan section is missing) names the section instead of throwing or passing as converged' {
        $global:VfVerify = 'partial'
        $result = Invoke-VfRun
        $errors = @($result.Records[0].errors) -join ' | '
        $errors | Should -Not -Match 'cannot be found on this object|Index was outside'
        $errors | Should -Match "Verify of iic-n01 failed: .*'plan' section"
        $result.Records[0].converged | Should -BeFalse
        $result.ExitCode | Should -Be 1
    }
}
