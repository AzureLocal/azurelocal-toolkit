#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The utility and lifecycle scripts that read the master infrastructure.yml (schema 5):
#   scripts/common/utilities/tools/Stop-AzureLocalCluster.ps1          shuts the cluster down for transport or maintenance
#   scripts/lifecycle/operations/powershell/Invoke-NodeMaintenanceReboot.ps1   drains, reboots and resumes one node
#   config-loader.ps1 and keyvault-helper.ps1 (scripts/common/utilities/helpers) are retired: Import-AzlInfrastructure and AzlSecret.psm1 replace them
# Invoke-Command, Test-Connection and Start-Sleep are mocked: no cluster, no machine, no vault and no credential is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/utilities/LegacyUtilities.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test credentials are random values made for the run.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:StopScript = [IO.Path]::Combine($script:Repo, 'scripts', 'common', 'utilities', 'tools', 'Stop-AzureLocalCluster.ps1')
    $script:RebootScript = [IO.Path]::Combine($script:Repo, 'scripts', 'lifecycle', 'operations', 'powershell', 'Invoke-NodeMaintenanceReboot.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))

    function New-TestSecret { [guid]::NewGuid().ToString('N') }
    function New-InfraFile {
        param([switch]$NoCluster, [int]$Nodes = 2, [switch]$NoReference)
        $doc = [ordered]@{
            cluster  = [ordered]@{ name = 'iic-clus-01' }
            nodes    = @(1..$Nodes | ForEach-Object { [ordered]@{ name = "iic-n0$_"; management = [ordered]@{ ip_address = "192.0.2.1$_" } } })
            identity = [ordered]@{
                local_admin      = [ordered]@{ username = 'azl-admin'; password = 'env://AZL_TEST_LOCAL_ADMIN' }
                active_directory = [ordered]@{
                    domain_fqdn = 'improbability.cloud'; netbios_name = 'IIC'
                    domain_join_account = [ordered]@{ username = 'svc-azl-join'; password = 'env://AZL_TEST_JOIN' }
                    lcm_user = [ordered]@{ username = 'lcm-iic-01'; password = 'env://AZL_TEST_LCM' }
                }
            }
        }
        if ($NoCluster) { $doc.Remove('cluster') }
        if ($NoReference) { $doc.identity.local_admin.Remove('password'); $doc.identity.active_directory.Remove('domain_join_account'); $doc.identity.active_directory.Remove('lcm_user') }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-TestCredential([string]$User = 'user') { [pscredential]::new($User, (ConvertTo-SecureString -String (New-TestSecret) -AsPlainText -Force)) }
    function Reset-Calls {
        $global:AzlUtilCalls = [System.Collections.Generic.List[object]]::new()
        $global:AzlUtilPings = 0
    }
    function Get-Call([string]$Pattern) { @($global:AzlUtilCalls | Where-Object { $_.Text -match $Pattern }) }
    # Runs a script and returns its exit code and every message as text.
    function Invoke-Tool([string]$Script, [hashtable]$Arguments, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $Script @Arguments -WhatIf 6>&1 3>&1 2>&1 } else { & $Script @Arguments 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Text     = (@($all | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Stop-AzureLocalCluster.ps1' {
    BeforeAll {
        $env:AZL_TEST_JOIN = New-TestSecret
        $script:Cred = New-TestCredential 'IIC\tester'
    }
    AfterAll {
        Remove-Item Env:AZL_TEST_JOIN -ErrorAction SilentlyContinue
        Remove-Variable -Name AzlUtilCalls, AzlUtilPings -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Reset-Calls
        Mock Start-Sleep { }
        Mock Test-Connection { $false }
        Mock Invoke-Command {
            $text = $ScriptBlock.ToString()
            $global:AzlUtilCalls.Add([pscustomobject]@{ Text = $text; Computer = [string]$ComputerName; Credential = $Credential })
            if ($text -match 'Get-Cluster -ErrorAction') {
                return @{
                    ClusterName = 'iic-clus-01'
                    Nodes       = @([pscustomobject]@{ Name = 'iic-n01'; State = 'Up'; NodeWeight = 1 }, [pscustomobject]@{ Name = 'iic-n02'; State = 'Up'; NodeWeight = 1 })
                    VMs         = @([pscustomobject]@{ Name = 'vm-one'; State = 'Online'; OwnerNode = 'iic-n01'; MemoryAssignedGB = 4; CPUUsage = 1; Uptime = '1.00:00:00'; Status = 'Operating normally' })
                    VMCount     = 1
                    StoragePool = [pscustomobject]@{ FriendlyName = 'pool-one'; HealthStatus = 'Healthy'; OperationalStatus = 'OK' }
                }
            }
            if ($text -match 'ClusSvc') { return $true }
            if ($text -match 'GroupType -eq "VirtualMachine" -and \$_.State') { return $null }
            return $env:COMPUTERNAME
        }
    }

    It 'stops before any node is contacted when -Force is not given and it is not a -WhatIf run' {
        $r = Invoke-Tool $script:StopScript @{ InfrastructureFile = (New-InfraFile); Credential = $script:Cred; LogPath = (Join-Path $TestDrive 'a.log') }
        $r.ExitCode | Should -Be 1 -Because $r.Text
        $r.Text | Should -Match '-Force'
        $global:AzlUtilCalls.Count | Should -Be 0
    }

    It 'never asks a question: it carries the standard header and no prompt' {
        $text = Get-Content -LiteralPath $script:StopScript -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Not -Match 'Read-Host|Get-Credential\b(?!.*-Credential)|\$Host\.UI\.Prompt|config-loader|-Solution'
    }

    It 'reads the cluster and the nodes from the file under -WhatIf, and stops and shuts down nothing' {
        $r = Invoke-Tool $script:StopScript @{ InfrastructureFile = (New-InfraFile); Credential = $script:Cred; LogPath = (Join-Path $TestDrive 'b.log') } -DryRun
        $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
        (Get-Call 'Get-Cluster -ErrorAction')[0].Computer | Should -Be '192.0.2.11'
        @(Get-Call 'Stop-Cluster|Stop-Computer|Stop-ClusterGroup|Stop-VM').Count | Should -Be 0
    }

    It 'with -Force: stops the virtual machines, the cluster, then Node 02, then Node 01, as the account it was given' {
        $r = Invoke-Tool $script:StopScript @{ InfrastructureFile = (New-InfraFile); Credential = $script:Cred; Force = $true; LogPath = (Join-Path $TestDrive 'c.log') }
        $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
        $order = @($global:AzlUtilCalls | Where-Object { $_.Text -match 'Stop-ClusterGroup|Stop-Cluster -Force|Stop-Computer' } | ForEach-Object { $_.Computer + ':' + $(if ($_.Text -match 'Stop-Computer') { 'computer' } elseif ($_.Text -match 'Stop-Cluster -Force') { 'cluster' } else { 'vm' }) })
        $order | Should -Be @('192.0.2.11:vm', '192.0.2.11:cluster', '192.0.2.12:computer', '192.0.2.11:computer')
        @($global:AzlUtilCalls | Where-Object { $_.Credential.UserName -ne 'IIC\tester' }).Count | Should -Be 0
    }

    It 'builds the credential from the secret reference of the domain account when none is given' {
        $r = Invoke-Tool $script:StopScript @{ InfrastructureFile = (New-InfraFile); Force = $true; LogPath = (Join-Path $TestDrive 'd.log') }
        $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
        $global:AzlUtilCalls[0].Credential.UserName | Should -Be 'IIC\svc-azl-join'
        $r.Text | Should -Not -Match ([regex]::Escape($env:AZL_TEST_JOIN))
    }

    It 'exits 2 and sends nothing when the credential cannot be built, and does not ask for one' {
        $r = Invoke-Tool $script:StopScript @{ InfrastructureFile = (New-InfraFile -NoReference); Force = $true; LogPath = (Join-Path $TestDrive 'e.log') }
        $r.ExitCode | Should -Be 2 -Because $r.Text
        @(Get-Call 'Get-Cluster -ErrorAction|Stop-').Count | Should -Be 0
    }

    It 'exits 2 when the file has no cluster name and the parameters give none' {
        $r = Invoke-Tool $script:StopScript @{ InfrastructureFile = (New-InfraFile -NoCluster); Credential = $script:Cred; Force = $true; LogPath = (Join-Path $TestDrive 'f.log') }
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $global:AzlUtilCalls.Count | Should -Be 0
    }

    It 'exits 2 when the file has fewer than two machines' {
        $r = Invoke-Tool $script:StopScript @{ InfrastructureFile = (New-InfraFile -Nodes 1); Credential = $script:Cred; Force = $true; LogPath = (Join-Path $TestDrive 'g.log') }
        $r.ExitCode | Should -Be 2 -Because $r.Text
    }

    It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
        $names = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Stop_AzureLocalCluster_ps1' } | ForEach-Object { $_.Node['name'] })
        $declared = @([System.Management.Automation.Language.Parser]::ParseFile($script:StopScript, [ref]$null, [ref]$null).ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($p in $declared) { $names | Should -Contain $p -Because $p }
    }
}

Describe 'Invoke-NodeMaintenanceReboot.ps1' {
    BeforeAll {
        $env:AZL_TEST_LOCAL_ADMIN = New-TestSecret
        $env:AZL_TEST_LCM = New-TestSecret
    }
    AfterAll {
        Remove-Item Env:AZL_TEST_LOCAL_ADMIN, Env:AZL_TEST_LCM -ErrorAction SilentlyContinue
        Remove-Variable -Name AzlUtilCalls, AzlUtilPings -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Reset-Calls
        Mock Start-Sleep { }
        Mock Test-Connection { $global:AzlUtilPings++; $global:AzlUtilPings -gt 1 }
        Mock Invoke-Command {
            $text = $ScriptBlock.ToString()
            $global:AzlUtilCalls.Add([pscustomobject]@{ Text = $text; Computer = [string]$ComputerName; Credential = $Credential; Arguments = @($ArgumentList) })
            if ($text -match 'DrainStatus') { return [pscustomobject]@{ Name = 'iic-n01'; State = 'Up'; DrainStatus = 'NotInitiated' } }
            if ($text -match '\)\.State') { return 'Up' }
            return $null
        }
    }

    It 'carries the standard header and never asks a question' {
        $text = Get-Content -LiteralPath $script:RebootScript -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Match 'SupportsShouldProcess'
        $text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|cluster_nodes|ConvertFrom-Yaml'
    }

    It 'exits 2 when the infrastructure file is missing' {
        $r = Invoke-Tool $script:RebootScript @{ InfrastructureFile = (Join-Path $TestDrive 'missing.yml'); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'r1.log') }
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $global:AzlUtilCalls.Count | Should -Be 0
    }

    It 'plans the work under -WhatIf, finds the node by name, address and fully qualified name, and sends nothing' {
        foreach ($target in 'iic-n01', '192.0.2.11', 'iic-n01.improbability.cloud') {
            Reset-Calls
            $r = Invoke-Tool $script:RebootScript @{ InfrastructureFile = (New-InfraFile); TargetNode = $target; LogPath = (Join-Path $TestDrive 'r2.log') } -DryRun
            $r.Text | Should -Match 'Node resolved\s+: iic-n01 \(192\.0\.2\.11\)' -Because $target
            $r.Text | Should -Match 'Would suspend cluster node'
            $global:AzlUtilCalls.Count | Should -Be 0
        }
    }

    It 'uses a node that is not in the file as it is' {
        $r = Invoke-Tool $script:RebootScript @{ InfrastructureFile = (New-InfraFile); TargetNode = 'other-node'; LogPath = (Join-Path $TestDrive 'r3.log') } -DryRun
        $r.Text | Should -Match 'not found in config'
    }

    It 'suspends, reboots, waits, resumes and checks the node, as the local administrator of the file' {
        $r = Invoke-Tool $script:RebootScript @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'r4.log') }
        $r.ExitCode | Should -BeIn 0, $null -Because $r.Text
        $steps = @($global:AzlUtilCalls | Where-Object { $_.Text -match 'Suspend-ClusterNode|Restart-Computer|Resume-ClusterNode' } | ForEach-Object { [regex]::Match($_.Text, 'Suspend-ClusterNode|Restart-Computer|Resume-ClusterNode').Value })
        $steps | Should -Be @('Suspend-ClusterNode', 'Restart-Computer', 'Resume-ClusterNode')
        $global:AzlUtilCalls[0].Computer | Should -Be '192.0.2.11'
        $global:AzlUtilCalls[0].Credential.UserName | Should -Be '.\azl-admin'
        $r.Text | Should -Not -Match ([regex]::Escape($env:AZL_TEST_LOCAL_ADMIN))
    }

    It 'uses -Credential instead of the accounts of the file' {
        $cred = New-TestCredential 'IIC\tester'
        $null = Invoke-Tool $script:RebootScript @{ InfrastructureFile = (New-InfraFile); TargetNode = 'iic-n01'; Credential = $cred; SkipDrain = $true; LogPath = (Join-Path $TestDrive 'r5.log') }
        @($global:AzlUtilCalls | Where-Object { $_.Credential.UserName -ne 'IIC\tester' }).Count | Should -Be 0
        (Get-Call 'Suspend-ClusterNode').Count | Should -Be 0
    }

    It 'exits 2 and sends nothing when no credential can be built, and does not prompt' {
        $r = Invoke-Tool $script:RebootScript @{ InfrastructureFile = (New-InfraFile -NoReference); TargetNode = 'iic-n01'; LogPath = (Join-Path $TestDrive 'r6.log') }
        $r.ExitCode | Should -Be 2 -Because $r.Text
        $global:AzlUtilCalls.Count | Should -Be 0
    }

    It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
        $names = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Invoke_NodeMaintenanceReboot_ps1' } | ForEach-Object { $_.Node['name'] })
        $declared = @([System.Management.Automation.Language.Parser]::ParseFile($script:RebootScript, [ref]$null, [ref]$null).ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($p in $declared) { $names | Should -Contain $p -Because $p }
    }

    It 'reads only registry keys that exist: <_>' -ForEach 'identity.local_admin.username', 'identity.local_admin.password', 'identity.active_directory.lcm_user.username', 'identity.active_directory.lcm_user.password', 'identity.active_directory.netbios_name', 'identity.active_directory.domain_fqdn', 'nodes[].name', 'nodes[].management.ip_address' {
        @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
    }
}

Describe 'config-loader.ps1 and keyvault-helper.ps1 are retired' {
    It '<_> is gone' -ForEach 'config-loader.ps1', 'keyvault-helper.ps1' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'utilities', 'helpers', $_)) | Should -BeFalse
    }
    It 'the infrastructure file is loaded by Import-AzlInfrastructure and secrets are read by AzlSecret.psm1' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) | Should -BeTrue
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'secrets', 'AzlSecret.psm1')) | Should -BeTrue
    }
    # That no script, pipeline, Ansible file or document names them any more is checked by tests/deploy-scripts/OldLayoutRetired.Tests.ps1.
}
