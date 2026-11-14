#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06, task 09: Invoke-VerifyPostDeployment.ps1 verifies a deployed instance against the schema 5 infrastructure file. Every cluster, node, Azure and az CLI call is
# replaced by a stub; nothing is contacted. It is the one post-deployment verification: the cluster node, identity, quorum, security group, SSH, storage,
# VM image and logical network checks (the earlier per-identity health and domain scripts are gone). Names and addresses are examples; ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/VerifyPostDeployment.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cmdlets they replace.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The az stub answers from a global, because a native command stub runs in its own scope.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-09-post-deployment-verification', 'powershell', 'Invoke-VerifyPostDeployment.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
    $env:AZL_TEST_VERIFY_SECRET = 'Canary-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

    function New-InfraFile {
        param([object[]]$VmImages, [switch]$OldKey, [string]$Identity = 'active_directory', [object[]]$LogicalNetworks = @(), [switch]$NoLogin)
        $doc = [ordered]@{
            scenario   = [ordered]@{ identity = $Identity }
            cluster    = [ordered]@{ name = 'iic-azl-01' }
            azure      = [ordered]@{ subscription_id = '00000000-0000-0000-0000-000000000000'; resource_group = 'rg-iic-azl-01' }
            networking = [ordered]@{ logical_networks = @($LogicalNetworks) }
            identity   = [ordered]@{ local_admin = [ordered]@{ username = 'iic-local-admin'; password = 'env://AZL_TEST_VERIFY_SECRET' } }
            nodes      = @([ordered]@{ name = 'iic-azl-n01'; management = [ordered]@{ ip_address = '192.0.2.11' } }, [ordered]@{ name = 'iic-azl-n02'; management = [ordered]@{ ip_address = '192.0.2.12' } })
        }
        if ($Identity -eq 'active_directory') {
            $doc.identity.active_directory = [ordered]@{ domain_fqdn = 'iic.improbability.cloud'; netbios_name = 'IIC'; lcm_user = [ordered]@{ username = 'iic-lcm'; password = 'env://AZL_TEST_VERIFY_SECRET' } }
        }
        if ($NoLogin) { $doc.identity = [ordered]@{}; if ($Identity -eq 'active_directory') { $doc.identity.active_directory = [ordered]@{ domain_fqdn = 'iic.improbability.cloud' } } }
        if ($PSBoundParameters.ContainsKey('VmImages')) { $doc.storage = [ordered]@{ vm_images = @($VmImages) } }
        # The old key: it must be ignored, not read.
        if ($OldKey) { $doc.marketplace_images = [ordered]@{ images = @([ordered]@{ name = 'old-1' }, [ordered]@{ name = 'old-2' }, [ordered]@{ name = 'old-3' }) } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Get-Image([string]$Name) { [ordered]@{ name = $Name; os_type = 'Windows'; publisher = 'iic-publisher'; offer = 'iic-offer'; sku = 'iic-sku'; version = 'latest'; storage_path = 'iic-path' } }
    function Invoke-Verify {
        param([string]$File, [int]$Succeeded = 5, [switch]$NoCredential, [switch]$WhatIf, [hashtable]$World = @{})
        $global:VerifyTest = @{ Succeeded = $Succeeded; World = $World }
        $log = Join-Path $TestDrive "verify-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
        $arguments = @{ InfrastructureFile = $File; LogPath = $log }
        if (-not $NoCredential) { $arguments.Credential = [pscredential]::new('iic\lcm', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }
        if ($WhatIf) { $arguments.WhatIf = $true }
        $global:LASTEXITCODE = $null
        $null = & $script:Script @arguments 6>&1
        [pscustomobject]@{ Code = $global:LASTEXITCODE; Log = $(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }) }
    }
    # The cluster, node and Azure side, as stubs.
    function Get-ClusterNode { param($Cluster, $ErrorAction) @(
            [pscustomobject]@{ Name = 'iic-azl-n01'; State = 'Up' }
            [pscustomobject]@{ Name = 'iic-azl-n02'; State = $(if ($global:VerifyTest.World['NodeDown']) { 'Down' } else { 'Up' }) }) }
    function Get-ClusterQuorum { param($Cluster, $ErrorAction) [pscustomobject]@{ QuorumType = 'NodeAndCloudWitness' } }
    function Get-Cluster { param($Name) [pscustomobject]@{ QuorumState = 'Normal' } }
    function Get-ClusterResource { param($Cluster, $Name, $ErrorAction) [pscustomobject]@{ Name = $Name } }
    function Get-ClusterParameter { param([Parameter(ValueFromPipeline)]$InputObject, $Name) process { [pscustomobject]@{ Name = $Name; Value = $(if ($global:VerifyTest.World['AdAware']) { $global:VerifyTest.World['AdAware'] } else { 2 }) } } }
    function Get-StoragePool { param($CimSession) [pscustomobject]@{ IsPrimordial = $false; HealthStatus = 'Healthy' } }
    function Get-ClusterSharedVolume { param($Cluster) @([pscustomobject]@{ Name = 'csv1'; State = 'Online' }) }
    function Test-NetConnection { param($ComputerName, $Port, $WarningAction) [pscustomobject]@{ TcpTestSucceeded = $true } }
    function Invoke-Command {
        param($ComputerName, $ScriptBlock, $Credential, $ErrorAction)
        $world = $global:VerifyTest.World
        $text = "$ScriptBlock"
        if ($text -match 'Win32_ComputerSystem') {
            if ($world['Workgroup']) { return [pscustomobject]@{ Domain = 'WORKGROUP'; PartOfDomain = $false; SecureChannel = $null } }
            return [pscustomobject]@{ Domain = $(if ($world['WrongDomain']) { 'other.example.test' } else { 'iic.improbability.cloud' }); PartOfDomain = $true; SecureChannel = $true }
        }
        if ($text -match 'Get-LocalGroupMember') { return @{ AdminGroups = 1; RmGroups = 1 } }
        if ($text -match 'sshd') { return [pscustomobject]@{ Status = 'Running' } }
        throw "unexpected remote call: $text"
    }
    function az {
        $global:LASTEXITCODE = 0
        $text = "$args"
        if ($text -like '*image list*') { return (1..5 | ForEach-Object { [ordered]@{ name = "img-$_"; provisioningState = $(if ($_ -le $global:VerifyTest.Succeeded) { 'Succeeded' } else { 'Failed' }) } } | ConvertTo-Json -AsArray) }
        if ($text -like '*lnet list*') { return (ConvertTo-Json -AsArray @([ordered]@{ name = 'lnet-1'; provisioningState = 'Succeeded' })) }
    }
}

AfterAll { Remove-Variable -Name VerifyTest -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_VERIFY_SECRET -ErrorAction SilentlyContinue }

Describe 'Invoke-VerifyPostDeployment.ps1 compares the Azure VM images with storage.vm_images[]' {
    It 'passes when every registered image Succeeded in Azure' {
        $r = Invoke-Verify (New-InfraFile -VmImages @((Get-Image 'iic-img-1'), (Get-Image 'iic-img-2'))) -Succeeded 5
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'All expected images Succeeded - 5/2'
    }
    It 'fails (exit 1) when fewer images Succeeded than the file lists' {
        $r = Invoke-Verify (New-InfraFile -VmImages @((Get-Image 'iic-img-1'), (Get-Image 'iic-img-2'), (Get-Image 'iic-img-3'))) -Succeeded 2
        $r.Code | Should -Be 1
        $r.Log | Should -Match '\[FAIL\].*All expected images Succeeded - 2/3'
    }
    It 'makes no comparison when the file lists no VM images, and does not fail on the missing key' {
        $r = Invoke-Verify (New-InfraFile) -Succeeded 5
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Not -Match 'All expected images'
    }
    It 'does not read the old key marketplace_images.images' {
        $r = Invoke-Verify (New-InfraFile -OldKey) -Succeeded 0
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Not -Match 'All expected images'
    }
    It 'reads one image given as a single item' {
        $r = Invoke-Verify (New-InfraFile -VmImages @(, (Get-Image 'iic-img-1'))) -Succeeded 1
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'All expected images Succeeded - 1/1'
    }
}

Describe 'Invoke-VerifyPostDeployment.ps1 counts one logical network correctly' {
    It 'compares 1 of 1 for a file with one logical network, whatever az returns for it' {
        $r = Invoke-Verify (New-InfraFile -VmImages @(, (Get-Image 'iic-img-1')) -LogicalNetworks @([ordered]@{ name = 'iic-lnet-1' })) -Succeeded 1
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'All expected networks Succeeded - 1/1'
    }
}

Describe 'Invoke-VerifyPostDeployment.ps1 checks the cluster nodes and the identity (what the earlier health and domain scripts did)' {
    It 'passes when every node is Up, joined to identity.active_directory.domain_fqdn and has a secure channel' {
        $r = Invoke-Verify (New-InfraFile)
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'iic-azl-n01 cluster node state - Up'
        $r.Log | Should -Match 'iic-azl-n02 joined to iic\.improbability\.cloud'
        $r.Log | Should -Match 'secure channel to the domain'
    }
    It 'fails when a node of the file is not Up' {
        $r = Invoke-Verify (New-InfraFile) -World @{ NodeDown = $true }
        $r.Code | Should -Be 1
        $r.Log | Should -Match '\[FAIL\].*iic-azl-n02 cluster node state - Down'
    }
    It 'fails when a node is joined to another domain' {
        $r = Invoke-Verify (New-InfraFile) -World @{ WrongDomain = $true }
        $r.Code | Should -Be 1
        $r.Log | Should -Match '\[FAIL\].*joined to iic\.improbability\.cloud'
    }
    It 'with local_identity checks the workgroup and ADAware 2, and skips the security groups' {
        $r = Invoke-Verify (New-InfraFile -Identity local_identity) -World @{ Workgroup = $true }
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'iic-azl-n01 is in a workgroup'
        $r.Log | Should -Match 'Cluster name ADAware is 2'
        $r.Log | Should -Match '\[SKIP\] Security groups'
    }
    It 'with local_identity fails when ADAware is not 2' {
        $r = Invoke-Verify (New-InfraFile -Identity local_identity) -World @{ Workgroup = $true; AdAware = 1 }
        $r.Code | Should -Be 1
        $r.Log | Should -Match '\[FAIL\].*Cluster name ADAware is 2'
    }
}

Describe 'Invoke-VerifyPostDeployment.ps1 never asks and runs nothing under -WhatIf' {
    It 'stops with exit code 2 when there is no -Credential and the file names no login' {
        $r = Invoke-Verify (New-InfraFile -NoLogin) -NoCredential
        $r.Code | Should -Be 2
        $r.Log | Should -Match 'No login: pass -Credential, or set identity\.active_directory\.lcm_user'
    }
    It 'takes the login from the secret reference of the file when no -Credential is given' {
        $r = Invoke-Verify (New-InfraFile) -NoCredential
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'Login: IIC\\iic-lcm \(from identity\.active_directory\.lcm_user\)'
        $r.Log | Should -Not -Match $env:AZL_TEST_VERIFY_SECRET
    }
    It 'stops with exit code 2 when scenario.identity is not usable' {
        $r = Invoke-Verify (New-InfraFile -Identity kerberos)
        $r.Code | Should -Be 2
        $r.Log | Should -Match 'scenario\.identity must be active_directory or local_identity'
    }
    It 'plans the checks and runs none under -WhatIf' {
        $r = Invoke-Verify (New-InfraFile) -NoCredential -WhatIf
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match '\[WhatIf\] Would read the nodes of iic-azl-01'
        $r.Log | Should -Not -Match '\[PASS\]'
    }
}

Describe 'The post-deployment verification script text' {
    BeforeAll {
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
        $script:Code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
        $script:Raw = Get-Content -LiteralPath $script:Script -Raw
    }
    It 'has the standard header' {
        $script:Raw | Should -Match '(?m)^#Requires -Version 7\.0'
        $script:Raw | Should -Match 'Set-StrictMode -Version Latest'
        $script:Raw | Should -Match "\`$ErrorActionPreference = 'Stop'"
    }
    It 'takes -InfrastructureFile (mandatory), no -ConfigPath, and never prompts' {
        $script:Raw | Should -Match '\[Parameter\(Mandatory\)\]\[string\]\$InfrastructureFile'
        $script:Code | Should -Not -Match 'ConfigPath|Read-Host|Get-Credential|ConvertFrom-Yaml|marketplace_images|\bWacServer\b'
    }
    It 'reads <_>, which is a registered key' -ForEach 'cluster.name', 'scenario.identity', 'identity.active_directory.domain_fqdn', 'identity.active_directory.netbios_name', 'identity.active_directory.lcm_user.username', 'identity.active_directory.lcm_user.password', 'identity.local_admin.username', 'identity.local_admin.password', 'azure.subscription_id', 'azure.resource_group', 'storage.vm_images', 'networking.logical_networks' {
        $script:Raw | Should -Match ([regex]::Escape("-Path '$_'"))
        @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
    }
    It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
        @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
    }
}
