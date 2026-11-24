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
        param([object[]]$VmImages, [switch]$OldKey, [string]$Identity = 'active_directory', [object[]]$LogicalNetworks = @(), [switch]$NoLogin, [string]$Witness = '', [string[]]$LocalGroups = @())
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
        if ($Witness) { $doc.cluster.witness = [ordered]@{ type = $Witness } }
        if ($LocalGroups.Count -gt 0 -and $Identity -eq 'active_directory') { $doc.identity.active_directory.security_groups = @([ordered]@{ name = 'sg-iic-azl-01-admins'; local_groups = @($LocalGroups) }) }
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
        $global:VerifyTest = @{ Succeeded = $Succeeded; World = $World; Calls = @() }
        $log = Join-Path $TestDrive "verify-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
        $arguments = @{ InfrastructureFile = $File; LogPath = $log }
        if (-not $NoCredential) { $arguments.Credential = [pscredential]::new('iic\lcm', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }
        if ($WhatIf) { $arguments.WhatIf = $true }
        $global:LASTEXITCODE = $null
        $null = & $script:Script @arguments 6>&1
        [pscustomobject]@{ Code = $global:LASTEXITCODE; Log = $(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }) }
    }
    # The cluster, node and Azure side, as stubs. Every cluster question is a block that runs on a node (Invoke-Command): the host that runs the script has no
    # cluster tools. $World changes what the node answers.
    function Invoke-Command {
        param($ComputerName, $ScriptBlock, $Credential, $ErrorAction, $ArgumentList)
        $world = $global:VerifyTest.World
        $text = "$ScriptBlock"
        $global:VerifyTest.Calls += @([pscustomobject]@{ Computer = $ComputerName; Text = $text })
        if ($text -match 'Win32_ComputerSystem') {
            if ($world['Workgroup']) { return [pscustomobject]@{ Domain = 'WORKGROUP'; PartOfDomain = $false; SecureChannel = $null } }
            return [pscustomobject]@{ Domain = $(if ($world['WrongDomain']) { 'other.example.test' } else { 'iic.improbability.cloud' }); PartOfDomain = $true; SecureChannel = $true }
        }
        if ($text -match 'Get-ClusterQuorum') {
            $witness = [string]$world['Witness']
            return @{
                QuorumType = 'Majority'; WitnessName = $(if ($witness) { $witness }); WitnessType = $witness
                WitnessState = $(if ($witness) { $(if ($world['WitnessOffline']) { 'Offline' } else { 'Online' }) }); NonVotingNodes = @($world['NoVote'] | Where-Object { $_ })
            }
        }
        if ($text -match 'ADAware') { return [string]$(if ($world['AdAware']) { $world['AdAware'] } else { 2 }) }
        if ($text -match 'Get-ClusterSharedVolume') { return @{ Pools = @('Healthy'); Csv = @(@{ Name = 'csv1'; State = 'Online' }) } }
        if ($text -match 'Get-ClusterNode') { return @(@{ Name = 'iic-azl-n01'; State = 'Up' }, @{ Name = 'iic-azl-n02'; State = $(if ($world['NodeDown']) { 'Down' } else { 'Up' }) }) }
        if ($text -match 'Get-LocalGroupMember') { $counts = @{}; foreach ($group in $ArgumentList[0]) { $counts[[string]$group] = $(if ($world['EmptyGroup'] -eq $group) { 0 } else { 1 }) }; return $counts }
        if ($text -match 'sshd') { return [string]$(if ($world['Sshd']) { $world['Sshd'] } else { 'Stopped' }) }
        throw "unexpected remote call: $text"
    }    function az {
        $global:LASTEXITCODE = 0
        $text = "$args"
        if ($text -like '*image list*') { return (1..5 | ForEach-Object { [ordered]@{ name = "img-$_"; provisioningState = $(if ($_ -le $global:VerifyTest.Succeeded) { 'Succeeded' } else { 'Failed' }) } } | ConvertTo-Json -AsArray) }
        # az stack-hci-vm lists the provisioning state under properties (seen on a deployed instance); the image stub above keeps it at the top: both shapes are read.
        if ($text -like '*lnet list*') { return '[{"name":"lnet-1","properties":{"provisioningState":"Succeeded"}}]' }
    }
}

AfterAll { Remove-Variable -Name VerifyTest -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:AZL_TEST_VERIFY_SECRET -ErrorAction SilentlyContinue }

Describe 'Invoke-VerifyPostDeployment.ps1 compares the Azure VM images with storage.vm_images[]' {
    It 'passes when every registered image Succeeded in Azure' {
        $r = Invoke-Verify (New-InfraFile -VmImages @((Get-Image 'iic-img-1'), (Get-Image 'iic-img-2'))) -Succeeded 5
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'All expected images Succeeded - 5 Succeeded of 5 in rg-iic-azl-01, the file lists 2'
    }
    It 'fails (exit 1) when fewer images Succeeded than the file lists' {
        $r = Invoke-Verify (New-InfraFile -VmImages @((Get-Image 'iic-img-1'), (Get-Image 'iic-img-2'), (Get-Image 'iic-img-3'))) -Succeeded 2
        $r.Code | Should -Be 1
        $r.Log | Should -Match '\[FAIL\].*All expected images Succeeded - 2 Succeeded of 5 in rg-iic-azl-01, the file lists 3'
    }
    It 'makes no comparison when the file lists no VM images, does not fail on the missing key, and does not need az for it' {
        $r = Invoke-Verify (New-InfraFile) -Succeeded 5
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Not -Match 'All expected images'
        $r.Log | Should -Match '\[SKIP\] VM images - the file lists none'
        $r.Log | Should -Match '\[SKIP\] Logical networks - the file lists none'
    }
    It 'does not read the old key marketplace_images.images' {
        $r = Invoke-Verify (New-InfraFile -OldKey) -Succeeded 0
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Not -Match 'All expected images'
    }
    It 'reads one image given as a single item' {
        $r = Invoke-Verify (New-InfraFile -VmImages @(, (Get-Image 'iic-img-1'))) -Succeeded 1
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'All expected images Succeeded - 1 Succeeded of 5 in rg-iic-azl-01, the file lists 1'
    }
}

Describe 'Invoke-VerifyPostDeployment.ps1 counts one logical network correctly' {
    It 'compares 1 of 1 for a file with one logical network, whatever az returns for it' {
        $r = Invoke-Verify (New-InfraFile -VmImages @(, (Get-Image 'iic-img-1')) -LogicalNetworks @([ordered]@{ name = 'iic-lnet-1' })) -Succeeded 1
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'All expected networks Succeeded - 1 Succeeded of 1 in rg-iic-azl-01, the file lists 1'
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

Describe 'Invoke-VerifyPostDeployment.ps1 asks the cluster on a node, and checks what the file asks for (found on the first run on a deployed instance)' {
    It 'sends the cluster questions to the first node of the file at its management address, not to the cluster name' {
        $r = Invoke-Verify (New-InfraFile)
        $r.Code | Should -Be 0 -Because $r.Log
        @($global:VerifyTest.Calls | Where-Object { $_.Text -match 'Get-ClusterNode|Get-ClusterQuorum|Get-ClusterSharedVolume' } | ForEach-Object { $_.Computer } | Sort-Object -Unique) | Should -Be @('192.0.2.11')
        (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match '-Cluster \$clusterName|-CimSession \$clusterName|QuorumState'
    }
    It 'passes the quorum check without a witness when the file names none, and reads no quorum state from the cluster object' {
        $r = Invoke-Verify (New-InfraFile)
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match 'Quorum type configured - Majority'
        $r.Log | Should -Match 'Every node that is Up has a vote'
        $r.Log | Should -Match 'No witness: the file names none'
    }
    It 'fails when the file asks for a witness (<Type>) and the cluster has none' -ForEach @(@{ Type = 'cloud' }, @{ Type = 'file_share' }) {
        $r = Invoke-Verify (New-InfraFile -Witness $Type)
        $r.Code | Should -Be 1
        $r.Log | Should -Match "\[FAIL\].*Witness \($Type, cluster\.witness\.type\) - the cluster has no witness"
    }
    It 'passes with the witness of the file Online, and fails for another type or a witness that is not Online' {
        (Invoke-Verify (New-InfraFile -Witness cloud) -World @{ Witness = 'Cloud Witness' }).Code | Should -Be 0
        $r = Invoke-Verify (New-InfraFile -Witness cloud) -World @{ Witness = 'File Share Witness' }
        $r.Code | Should -Be 1
        $r.Log | Should -Match '\[FAIL\].*Witness is a Cloud Witness'
        $r = Invoke-Verify (New-InfraFile -Witness cloud) -World @{ Witness = 'Cloud Witness'; WitnessOffline = $true }
        $r.Code | Should -Be 1
        $r.Log | Should -Match '\[FAIL\].*Witness is Online - Offline'
    }
    It 'fails when a node that is Up has no vote' {
        $r = Invoke-Verify (New-InfraFile) -World @{ NoVote = @('iic-azl-n02') }
        $r.Code | Should -Be 1
        $r.Log | Should -Match '\[FAIL\].*Every node that is Up has a vote - no vote: iic-azl-n02'
    }
    It 'skips the security groups when the file puts no group in a local group, and checks exactly the local groups it names' {
        $r = Invoke-Verify (New-InfraFile)
        $r.Log | Should -Match '\[SKIP\] Security groups - the file puts no Active Directory group in a local group'
        $r = Invoke-Verify (New-InfraFile -LocalGroups 'Administrators', 'Remote Management Users') -World @{ EmptyGroup = 'Remote Management Users' }
        $r.Code | Should -Be 1
        $r.Log | Should -Match '\[PASS\] iic-azl-n01 - Administrators AD group\(s\) - 1'
        $r.Log | Should -Match '\[FAIL\] iic-azl-n01 - Remote Management Users AD group\(s\) - 0'
    }
    It 'skips SSH on a node where sshd does not run (an optional task), and checks the port where it does' {
        $r = Invoke-Verify (New-InfraFile)
        $r.Code | Should -Be 0 -Because $r.Log
        $r.Log | Should -Match '\[SKIP\] iic-azl-n01 - SSH - sshd is Stopped'
        $r = Invoke-Verify (New-InfraFile) -World @{ Sshd = 'Running' }
        $r.Code | Should -Be 1 -Because 'no machine answers on port 22 at the documentation address of the test'
        $r.Log | Should -Match '\[PASS\] iic-azl-n01 - sshd service - Running'
        $r.Log | Should -Match '\[FAIL\] iic-azl-n01 - port 22 reachable'
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
