#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The rows of the variables research with status hardcoded_in_script (storage, security and acceptance groups): what was settled in code.
# Every cluster, Azure and module call is a stub or a mock; nothing is contacted.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/HardcodedRows.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cmdlets they replace.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The pool stub answers from a global, because a mocked command runs in its own scope.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stubs and test helpers.')]
param()

BeforeDiscovery {
    $script:MandatoryCase = @(
        @{ Name = 'Invoke-VerifyPostDeployment.ps1'; Path = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-VerifyPostDeployment.ps1' }
        @{ Name = 'Invoke-ApplySecurityGroups-Orchestrated.ps1'; Path = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-03-security-groups-applied-to-nodes/powershell/Invoke-ApplySecurityGroups-Orchestrated.ps1' }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    function Get-RepoText([string]$RelativePath) { Get-Content -LiteralPath (Join-Path $script:Repo $RelativePath) -Raw }
    function Get-ParamAst([string]$RelativePath) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo $RelativePath), [ref]$null, [ref]$null)
        $ast.ParamBlock.Parameters
    }
    $script:Deploy = 'scripts/deploy'
    $script:VmFleet = "$script:Deploy/06-testing-validation/task-02-vmfleet-storage-testing/powershell/Invoke-VmFleetStorageTest.ps1"
    $script:Verify = "$script:Deploy/04-cluster-deployment/phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-VerifyPostDeployment.ps1"
    $script:ApplyGroups = "$script:Deploy/04-cluster-deployment/phase-06-post-deployment/task-03-security-groups-applied-to-nodes/powershell/Invoke-ApplySecurityGroups-Orchestrated.ps1"
    $script:Registry = Get-RepoText 'config/variables/schema/master-registry.yaml'
    Import-Module powershell-yaml
    # Import-Module is mocked in the VMFleet tests (the script installs the VMFleet module), so the infrastructure module is loaded here, once.
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force -Global

    # Stubs of the cluster and storage cmdlets of the VMFleet script.
    function Get-ClusterSharedVolume { param($Cluster) @() }
    function Get-ClusterNode { param($Cluster) @([pscustomobject]@{ Name = 'iic-01-n01' }) }
    function Get-StoragePool { param($CimSession) $global:AzlHcPools }
    function New-Volume { param($CimSession, $FriendlyName, $Size, $StoragePoolFriendlyName, $FileSystem) $null }
    function Set-Fleet { param($Cluster, $VMs, $AdminPass, $ConnectUser) $null }
    function Start-Fleet { param($Cluster, $Duration, $BlockSize, $RandomPercent, $WritePercent, $Threads, $Outstanding) $null }
    function Get-FleetResultLog { param($Cluster, $Last) @([pscustomobject]@{ IOPS = 1000; AvgLatency = 1.5; MBps = 40 }) }
    function Remove-Fleet { param($Cluster) $null }
    function Install-Module { param($Name, [switch]$Force, $Scope, $RequiredVersion) $null }
    function New-InfraFile {
        param([string]$PoolName)
        $doc = [ordered]@{ cluster = [ordered]@{ name = 'iic-azl-01' } }
        if ($PoolName) { $doc.storage = [ordered]@{ pool = [ordered]@{ name = $PoolName } } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
}

AfterAll { Remove-Variable -Name AzlHcPools -Scope Global -ErrorAction SilentlyContinue }

Describe 'Invoke-VmFleetStorageTest.ps1' {
    BeforeEach {
        $global:AzlHcPools = @([pscustomobject]@{ IsPrimordial = $true; FriendlyName = 'Primordial' }, [pscustomobject]@{ IsPrimordial = $false; FriendlyName = 'SU1_Pool' })
        Mock Get-Module { $null }
        Mock Import-Module { }
        Mock Install-Module { }
        Mock New-Volume { }
        $script:FleetCred = [pscredential]::new('fleetadmin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        Mock Start-Sleep { }
        Mock Start-Fleet { }
        Mock Set-Fleet { }
        Mock Remove-Fleet { }
        Mock Get-ClusterSharedVolume { @() }
        Mock Get-ClusterNode { @([pscustomobject]@{ Name = 'iic-01-n01' }) }
        Mock Get-StoragePool { $global:AzlHcPools }
        Mock Get-FleetResultLog { @([pscustomobject]@{ IOPS = 1000; AvgLatency = 1.5; MBps = 40 }) }
    }

    It 'creates the Collect volume in the pool of storage.pool.name' {
        $null = & (Join-Path $script:Repo $script:VmFleet) -InfrastructureFile (New-InfraFile 'iic-pool') -OutputPath (Join-Path $TestDrive 'o1') -FleetAdminCredential $script:FleetCred 6>&1
        Should -Invoke New-Volume -Times 1 -Exactly -ParameterFilter { $StoragePoolFriendlyName -eq 'iic-pool' -and $FriendlyName -eq 'Collect' }
    }

    It 'finds the one pool of the cluster when the file names none' {
        $null = & (Join-Path $script:Repo $script:VmFleet) -InfrastructureFile (New-InfraFile) -OutputPath (Join-Path $TestDrive 'o2') -FleetAdminCredential $script:FleetCred 6>&1
        Should -Invoke New-Volume -Times 1 -Exactly -ParameterFilter { $StoragePoolFriendlyName -eq 'SU1_Pool' }
    }

    It 'stops when the cluster has two pools and the file names none' {
        $global:AzlHcPools = @([pscustomobject]@{ IsPrimordial = $false; FriendlyName = 'a' }, [pscustomobject]@{ IsPrimordial = $false; FriendlyName = 'b' })
        { & (Join-Path $script:Repo $script:VmFleet) -InfrastructureFile (New-InfraFile) -OutputPath (Join-Path $TestDrive 'o3') -FleetAdminCredential $script:FleetCred 6>&1 } | Should -Throw '*storage.pool.name*'
        Should -Invoke New-Volume -Times 0 -Exactly
    }

    It 'sizes the Collect volume from the parameter CollectVolumeSizeGiB' {
        $null = & (Join-Path $script:Repo $script:VmFleet) -InfrastructureFile (New-InfraFile 'iic-pool') -CollectVolumeSizeGiB 80 -OutputPath (Join-Path $TestDrive 'o4') -FleetAdminCredential $script:FleetCred 6>&1
        Should -Invoke New-Volume -Times 1 -Exactly -ParameterFilter { $Size -eq 80GB }
    }

    It 'installs the version of the parameter VmFleetModuleVersion' {
        $null = & (Join-Path $script:Repo $script:VmFleet) -InfrastructureFile (New-InfraFile 'iic-pool') -VmFleetModuleVersion '1.2.3' -OutputPath (Join-Path $TestDrive 'o5') -FleetAdminCredential $script:FleetCred 6>&1
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $RequiredVersion -eq '1.2.3' }
    }

    It 'installs the latest version without the parameter' {
        $null = & (Join-Path $script:Repo $script:VmFleet) -InfrastructureFile (New-InfraFile 'iic-pool') -OutputPath (Join-Path $TestDrive 'o6') -FleetAdminCredential $script:FleetCred 6>&1
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'VMFleet' }
        Should -Invoke Install-Module -Times 0 -Exactly -ParameterFilter { $Name -eq 'VMFleet' -and $RequiredVersion }
    }

    It 'never prompts: without -FleetAdminCredential it stops before it installs or creates anything' {
        $text = (& (Join-Path $script:Repo $script:VmFleet) -InfrastructureFile (New-InfraFile 'iic-pool') -OutputPath (Join-Path $TestDrive 'o7') 6>&1 2>&1 | Out-String)
        $LASTEXITCODE | Should -Be 2
        $text | Should -Match 'FleetAdminCredential'
        Should -Invoke Install-Module -Times 0 -Exactly -ParameterFilter { $Name -eq 'VMFleet' }
        Should -Invoke New-Volume -Times 0 -Exactly
        (Get-RepoText $script:VmFleet) | Should -Not -Match 'Read-Host'
    }

    It 'gives the fleet the password of -FleetAdminCredential' {
        $null = & (Join-Path $script:Repo $script:VmFleet) -InfrastructureFile (New-InfraFile 'iic-pool') -OutputPath (Join-Path $TestDrive 'o8') -FleetAdminCredential $script:FleetCred 6>&1
        Should -Invoke Set-Fleet -Times 1 -Exactly -ParameterFilter { $AdminPass -is [securestring] }
    }
    It 'types no pool pattern and no volume size into the call' {
        $text = Get-RepoText $script:VmFleet
        $text | Should -Not -Match 'S2D\*'
        $text | Should -Not -Match '-Size 50GB'
    }
}

Describe 'scripts the Azure Local security baseline replaces' {
    It 'removes Set-SecurityLogging.ps1, Set-AzurePolicyConfiguration.ps1 and Set-TelemetryConfiguration.ps1' {
        foreach ($name in 'Set-SecurityLogging.ps1', 'Set-AzurePolicyConfiguration.ps1', 'Set-TelemetryConfiguration.ps1') {
            @(Get-ChildItem -Path (Join-Path $script:Repo $script:Deploy) -Recurse -Filter $name) | Should -BeNullOrEmpty -Because "$name is removed"
        }
    }
    It 'keeps Set-SecurityBaselines.ps1, which changes the baseline with Set-AzsSecurity' {
        (Get-RepoText "$script:Deploy/05-operational-foundations/phase-04-security-governance/task-03-configure-security-baselines/powershell/Set-SecurityBaselines.ps1") | Should -Match 'Set-AzsSecurity'
    }
}

Describe 'a path to the infrastructure file is never guessed' {
    It 'makes InfrastructureFile of <Name> mandatory' -ForEach $script:MandatoryCase {
        $p = Get-ParamAst $Path | Where-Object { $_.Name.VariablePath.UserPath -eq 'InfrastructureFile' }
        $p | Should -Not -BeNullOrEmpty
        $p.DefaultValue | Should -BeNullOrEmpty
        ($p.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' }).NamedArguments.ArgumentName | Should -Contain 'Mandatory'
        (Get-RepoText $Path) | Should -Not -Match 'configs\\infrastructure\.yml"'
    }
}

Describe 'constants carry the rule that fixes them' {
    It 'names the Add-EceFeature feature once (Enable-ArcSdn.ps1)' {
        $text = Get-RepoText "$script:Deploy/04-cluster-deployment/phase-06-post-deployment/task-01-deploy-sdn/powershell/Enable-ArcSdn.ps1"
        $text | Should -Match '\$FeatureName = ''NC'''
        $text | Should -Not -Match '@{ Name = ''NC'''
    }
    It 'names the pass rules of the post-deployment verification' {
        $text = Get-RepoText $script:Verify
        $text | Should -Match '\$MinimumAdGroupsPerLocalGroup = 1'
        $text | Should -Match '\$MinimumCsvVolumes = 1'
        $text | Should -Not -Match 'AdminGroups -gt 0|RmGroups\s+-gt 0|csvVolumes.Count -gt 0'
    }
    It 'gives the default allocation method of a logical network a name' {
        $text = Get-RepoText "$script:Deploy/04-cluster-deployment/phase-06-post-deployment/task-08-logical-network-creation/powershell/New-LogicalNetwork.ps1"
        $text | Should -Match '\$DefaultAllocationMethod = '
        $text | Should -Not -Match '''ip_allocation_method'' ''Static'''
    }
}

Describe 'Terraform follows the registry' {
    It 'derives the action group short name the way Deploy-ActionGroup.ps1 does' {
        (Get-RepoText 'src/terraform/modules/monitoring/main.tf') | Should -Match 'short_name\s*=\s*substr\(replace\(var\.action_group_name'
    }
    It 'has no retention default of its own' {
        (Get-RepoText 'src/terraform/modules/monitoring/variables.tf') | Should -Not -Match 'default\s*=\s*90'
        (Get-RepoText 'src/terraform/environments/azure-local/variables.tf') | Should -Not -Match 'default\s*=\s*90'
    }
}

Describe 'settings registered by hand' {
    It 'registers every setting of src/ansible/ansible.cfg under tools.ansible.config_keys' {
        $lines = @((Get-RepoText 'src/ansible/ansible.cfg') -split "`r?`n" | Where-Object { $_ -match '^\s*[a-z_]+\s*=' })
        $lines.Count | Should -Be 15
        foreach ($line in $lines) {
            $name = ($line -split '=')[0].Trim()
            $script:Registry | Should -Match ('"name":"ansible\.cfg \[[a-z_]+\] ' + [regex]::Escape($name) + '"') -Because "$name is registered"
        }
    }
    It 'registers confirm_wipe_deployed_cluster of the Azure DevOps OS configuration pipeline' {
        $script:Registry | Should -Match '"name":"confirm_wipe_deployed_cluster".*pipelines/azure-devops/os-configuration\.yml:\d+'
        (Get-RepoText 'pipelines/azure-devops/os-configuration.yml') | Should -Match '- name: confirm_wipe_deployed_cluster'
    }
    It 'does not call site.customer documentation only' {
        $script:Registry | Should -Match 'Name of the customer or organization the site belongs to\. Read by Set-CustomerTransfer\.ps1'
        $script:Registry | Should -Not -Match 'customer or organization the site belongs to\. Documentation only'
    }
    It 'does not list network_devices[].model and .management.protocol as documentation only in MIGRATION' {
        $line = @((Get-RepoText 'config/variables/docs/MIGRATION.md') -split "`r?`n" | Where-Object { $_ -match 'A design record that a person fills in' -and $_ -match 'nodes\[\]\.rack' })
        $line.Count | Should -BeGreaterThan 0
        $line[0] | Should -Not -Match 'network_devices\[\]\.model'
        $line[0] | Should -Not -Match '\.management\.protocol'
    }
}
