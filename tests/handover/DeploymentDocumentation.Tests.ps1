#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Handover: New-DeploymentDocumentation.ps1 reads cluster.name, site.customer and the azure keys from infrastructure.yml, collects the cluster read only,
# and writes a Markdown page and a JSON file. The cluster cmdlets and Invoke-Command are mocked: no cluster, no node, no credential is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/handover/DeploymentDocumentation.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the cluster state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cluster cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'handover', 'documentation', 'powershell', 'New-DeploymentDocumentation.ps1')
    Import-Module powershell-yaml

    function Get-Cluster { [CmdletBinding()] param([string]$Name) }
    function Get-ClusterNode { [CmdletBinding()] param([string]$Cluster) }
    function Get-ClusterQuorum { [CmdletBinding()] param([string]$Cluster) }
    function Get-ClusterNetwork { [CmdletBinding()] param([string]$Cluster) }
    function Get-ClusterSharedVolume { [CmdletBinding()] param([string]$Cluster) }
    function Get-StoragePool { [CmdletBinding()] param([string]$CimSession) }
    function Get-VirtualDisk { [CmdletBinding()] param([string]$CimSession) }

    function New-InfraFile {
        param([hashtable]$Cluster = @{}, [hashtable]$Site = @{}, [hashtable]$Extra = @{})
        $cl = [ordered]@{ name = 'iic-azl-01' }
        foreach ($k in $Cluster.Keys) { if ($null -eq $Cluster[$k]) { $cl.Remove($k) } else { $cl[$k] = $Cluster[$k] } }
        $si = [ordered]@{ customer = 'Improbability Inc' }
        foreach ($k in $Site.Keys) { if ($null -eq $Site[$k]) { $si.Remove($k) } else { $si[$k] = $Site[$k] } }
        $doc = [ordered]@{
            azure    = [ordered]@{ tenant_id = $global:AzlDdTenant; subscription_id = $global:AzlDdSub; resource_group = 'rg-iic-azl-01'; location = 'westeurope' }
            cluster  = $cl
            site     = $si
            identity = [ordered]@{ local_admin = [ordered]@{ username = 'iic-admin'; password = 'keyvault://kv-iic-mgmt-01/local-admin-password' } }
            secrets  = [ordered]@{ provider = 'keyvault' }
        }
        foreach ($k in $Extra.Keys) { $doc[$k] = $Extra[$k] }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Documentation([string]$File, [string]$Out, [switch]$DryRun, [switch]$Credentials) {
        $global:LASTEXITCODE = $null
        $arguments = @{ InfrastructureFile = $File; OutputPath = $Out }
        if ($Credentials) { $arguments.IncludeCredentialLocations = $true }
        $all = if ($DryRun) { & $script:Script @arguments -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script @arguments 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{ ExitCode = $code; Text = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n") }
    }
    $global:AzlDdTenant = [guid]::NewGuid().ToString()
    $global:AzlDdSub = [guid]::NewGuid().ToString()
}

Describe 'New-DeploymentDocumentation.ps1' {
    AfterAll { Remove-Variable -Name AzlDdTenant, AzlDdSub -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-Cluster { [pscustomobject]@{ Name = $Name; Domain = 'improbability.cloud' } }
        Mock Get-ClusterNode { @([pscustomobject]@{ Name = 'iic-node01'; State = 'Up' }, [pscustomobject]@{ Name = 'iic-node02'; State = 'Up' }) }
        Mock Get-ClusterQuorum { [pscustomobject]@{ QuorumType = 'NodeAndCloudMajority' } }
        Mock Get-ClusterNetwork { @([pscustomobject]@{ Name = 'Management'; Address = '192.0.2.0'; Role = 'ClusterAndClient'; State = 'Up' }) }
        Mock Get-ClusterSharedVolume { @([pscustomobject]@{ Name = 'Cluster Virtual Disk (vol-01)'; State = 'Online'; SharedVolumeInfo = @([pscustomobject]@{ FriendlyVolumeName = 'C:\ClusterStorage\vol-01' }) }) }
        Mock Get-StoragePool { @([pscustomobject]@{ FriendlyName = 'SU1_Pool'; Size = 8TB; HealthStatus = 'Healthy'; IsPrimordial = $false }, [pscustomobject]@{ FriendlyName = 'Primordial'; Size = 1TB; HealthStatus = 'Healthy'; IsPrimordial = $true }) }
        Mock Get-VirtualDisk { @([pscustomobject]@{ FriendlyName = 'vol-01'; Size = 2TB; ResiliencySettingName = 'Mirror'; HealthStatus = 'Healthy' }) }
        Mock Invoke-Command {
            if ($ScriptBlock.ToString() -match 'Get-VMSwitch') { @([pscustomobject]@{ Name = 'ConvergedSwitch(mgmt_compute)'; SwitchType = 'External'; EmbeddedTeamingEnabled = $true }) }
            else { @{ Status = 'Connected' } }
        }
    }

    Context 'the package' {
        It 'collects the cluster named by cluster.name and writes a Markdown page and a JSON file named after the customer and the cluster' {
            $out = Join-Path $TestDrive 'pkg'
            $r = Invoke-Documentation (New-InfraFile) $out
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke Get-Cluster -Times 1 -Exactly -ParameterFilter { $Name -eq 'iic-azl-01' }
            Should -Invoke Get-ClusterNode -Times 2 -ParameterFilter { $Cluster -eq 'iic-azl-01' }
            Should -Invoke Invoke-Command -Times 2 -Exactly -ParameterFilter { $ComputerName -eq 'iic-node01' }
            $md = Get-Content -LiteralPath (Join-Path $out 'Improbability-Inc-iic-azl-01-Documentation.md') -Raw
            $md | Should -Match '\*\*Customer:\*\* Improbability Inc'
            $md | Should -Match '\| Cluster name \| iic-azl-01 \|'
            $md | Should -Match '\| iic-node01 \| Up \|'
            $md | Should -Match '\| Management \| 192\.0\.2\.0 \| ClusterAndClient \| Up \|'
            $md | Should -Match 'ConvergedSwitch\(mgmt_compute\) \| External \| True'
            $md | Should -Match '\| SU1_Pool \| 8192 \| Healthy \|'
            $md | Should -Not -Match 'Primordial'
            $md | Should -Match '\| C:\\ClusterStorage\\vol-01 \|'
            $md | Should -Match '\| Azure Arc agent \| Connected \|'
            $md | Should -Match "\| Subscription \| $($global:AzlDdSub) \|"
            $md | Should -Match '\| Location \| westeurope \|'
            $md | Should -Not -Match 'support@|Support Contacts|Windows Admin Center'
            $json = Get-Content -LiteralPath (Join-Path $out 'Improbability-Inc-iic-azl-01-Config.json') -Raw | ConvertFrom-Json
            $json.ClusterName | Should -Be 'iic-azl-01'
            $json.CustomerName | Should -Be 'Improbability Inc'
            @($json.Sections.ClusterConfig.Nodes).Count | Should -Be 2
        }

        It 'leaves a part out with a warning when the cluster cannot report it, and still writes the page' {
            Mock Get-StoragePool { throw 'The CIM session could not be created.' }
            $out = Join-Path $TestDrive 'pkg2'
            $r = Invoke-Documentation (New-InfraFile) $out
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'storage configuration could not be read'
            (Test-Path -LiteralPath (Join-Path $out 'Improbability-Inc-iic-azl-01-Documentation.md')) | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $out 'Improbability-Inc-iic-azl-01-Config.json') -Raw | ConvertFrom-Json).Sections.PSObject.Properties.Name | Should -Not -Contain 'StorageConfig'
        }

        It 'changes nothing on the cluster' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match '\b(Set|New|Remove|Add|Enable|Disable|Start|Stop)-(Cluster|StoragePool|VirtualDisk|Volume|VM)'
        }
    }

    Context 'the credential locations' {
        It 'lists the secret references of the file with their keys, and never a value' {
            $out = Join-Path $TestDrive 'pkg3'
            $null = Invoke-Documentation (New-InfraFile) $out -Credentials
            $md = Get-Content -LiteralPath (Join-Path $out 'Improbability-Inc-iic-azl-01-Documentation.md') -Raw
            $md | Should -Match '## Where the secrets are'
            $md | Should -Match '\| identity\.local_admin\.password \| keyvault://kv-iic-mgmt-01/local-admin-password \|'
        }

        It 'does not write the section without the switch' {
            $out = Join-Path $TestDrive 'pkg4'
            $null = Invoke-Documentation (New-InfraFile) $out
            (Get-Content -LiteralPath (Join-Path $out 'Improbability-Inc-iic-azl-01-Documentation.md') -Raw) | Should -Not -Match 'Where the secrets are|keyvault://'
        }

        It 'finds a reference in a list' {
            $out = Join-Path $TestDrive 'pkg5'
            $extra = @{ network_devices = @([ordered]@{ hostname = 'iic-sw01'; type = 'switch'; credentials = [ordered]@{ username = 'admin'; password = 'env://IIC_SWITCH_PASSWORD' } }) }
            $null = Invoke-Documentation (New-InfraFile -Extra $extra) $out -Credentials
            (Get-Content -LiteralPath (Join-Path $out 'Improbability-Inc-iic-azl-01-Documentation.md') -Raw) | Should -Match '\| network_devices\[0\]\.credentials\.password \| env://IIC_SWITCH_PASSWORD \|'
        }
    }

    Context '-WhatIf and missing values' {
        It 'collects, plans the files and writes nothing' {
            $out = Join-Path $TestDrive 'pkg6'
            $r = Invoke-Documentation (New-InfraFile) $out -DryRun
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'would be written'
            Test-Path -LiteralPath $out | Should -BeFalse
        }

        It 'refuses a missing cluster.name or site.customer (exit 2) and touches no cluster' {
            foreach ($file in (New-InfraFile -Cluster @{ name = $null }), (New-InfraFile -Site @{ customer = $null })) {
                $r = Invoke-Documentation $file (Join-Path $TestDrive 'pkg7')
                $r.ExitCode | Should -Be 2 -Because $r.Text
            }
            Should -Invoke Get-Cluster -Times 0 -Exactly
        }

        It 'refuses a file it cannot read' {
            (Invoke-Documentation (Join-Path $TestDrive 'missing.yml') (Join-Path $TestDrive 'pkg8')).ExitCode | Should -Be 2
        }

        It 'exits 1 when the files cannot be written' {
            $blocker = Join-Path $TestDrive 'a-file'
            Set-Content -LiteralPath $blocker -Value 'x'
            (Invoke-Documentation (New-InfraFile) (Join-Path $blocker 'sub')).ExitCode | Should -Be 1
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads the instance from the file, not from parameters' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'logging\.ps1|support@'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
            @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Be @('InfrastructureFile', 'OutputPath', 'IncludeCredentialLocations', 'LogPath')
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'New_DeploymentDocumentation_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'cluster.name', 'site.customer', 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'azure.location' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
