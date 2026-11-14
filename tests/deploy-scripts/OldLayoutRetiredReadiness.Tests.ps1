#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The old variables layout is retired: no script of scripts/deploy 03, 05, 06 and common, scripts/tools, scripts/lifecycle or scripts/common/utilities takes
# -ConfigPath or -ConfigFile (or an alias of them), asks for a credential or a value, or loads config-loader.ps1 or keyvault-helper.ps1. The scripts that a
# schema 5 script replaces are gone. These tests read files; nothing is run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/OldLayoutRetired.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $deploy = [IO.Path]::Combine($repoRoot, 'scripts', 'deploy')
    $script:Removed = @(
        @{ Name = 'Invoke-ADValidation-Arc.ps1'; Folder = '03-onprem-readiness/phase-01-active-directory/task-01-ou-creation-pre-creation-artifacts/powershell'; Instead = 'scripts/common/arm-deployment/verification/AzlVerification.Identity.psm1'; Why = 'ID-AD-003, ID-AD-004 and ID-AD-012 of the pre-cluster verification check the OU, the LCM user and the KDS root key' }
        @{ Name = 'Invoke-ADValidation-AzVM.ps1'; Folder = '03-onprem-readiness/phase-01-active-directory/task-01-ou-creation-pre-creation-artifacts/powershell'; Instead = 'scripts/common/arm-deployment/verification/AzlVerification.Identity.psm1'; Why = 'the same checks' }
        @{ Name = 'Test-ADConfiguration.ps1'; Folder = '03-onprem-readiness/phase-01-active-directory/task-01-ou-creation-pre-creation-artifacts/powershell'; Instead = 'scripts/common/arm-deployment/verification/AzlVerification.Identity.psm1'; Why = 'the same checks' }
        @{ Name = 'Test-HardwareInspection.ps1'; Folder = '03-onprem-readiness/phase-02-enterprise-readiness/task-01-hardware-inspection/powershell'; Instead = 'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Get-HardwareInventory.ps1'; Why = 'the Redfish inventory of model, service tag, memory, storage and adapters' }
        @{ Name = 'Set-InfrastructurePrep.ps1'; Folder = '03-onprem-readiness/phase-02-enterprise-readiness/task-02-network-service-verification/powershell'; Instead = 'scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Set-AzureLocalNodeConfiguration.ps1'; Why = 'the OS configuration installs the features and sets the time source; the node checks ND-001 to ND-012 verify them' }
        @{ Name = 'Set-FirewallEndpoint.ps1'; Folder = '03-onprem-readiness/phase-03-network-infrastructure/task-03-firewall-endpoint-verification/powershell'; Instead = 'scripts/common/arm-deployment/verification/AzlVerification.Endpoints.psm1'; Why = 'AZ-023 and NW-005 probe the endpoints Learn lists, from each node' }
        @{ Name = 'Test-NetworkReadiness.ps1'; Folder = '03-onprem-readiness/phase-03-network-infrastructure/task-04-network-validation/powershell'; Instead = 'scripts/common/arm-deployment/verification/AzlVerification.Network.psm1'; Why = 'NW-001 to NW-015 of the pre-cluster verification' }
        @{ Name = 'Test-SdnPrerequisites.ps1'; Folder = '05-operational-foundations/phase-01-sdn-deployment/task-01-validate-sdn-prerequisites/powershell'; Instead = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-01-deploy-sdn/powershell/Enable-ArcSdn.ps1'; Why = 'Enable-ArcSdn.ps1 checks what Learn lists as prerequisites and plans under -WhatIf' }
        @{ Name = 'Set-SdnIntegration.ps1'; Folder = '05-operational-foundations/phase-01-sdn-deployment/task-02-configure-network-security-groups/powershell'; Instead = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-01-deploy-sdn/powershell/Enable-ArcSdn.ps1'; Why = 'SDN enabled by Azure Arc has no load balancer or gateway to configure' }
        @{ Name = 'Invoke-PostTerraformConfiguration.ps1'; Folder = 'common'; Instead = 'scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1'; Why = 'it only called placeholders and loaded config-loader.ps1' }
    )
    $script:RemovedOutside = @(
        @{ Path = 'scripts/tools/authoring/Convert-ToStandaloneScript.ps1'; Why = 'it baked the values of a file into a script' }
        @{ Path = 'scripts/lifecycle/updates/powershell/Invoke-ClusterUpdates.ps1'; Why = 'Learn lists manual runs of Cluster-Aware Updating, SConfig and the updates pane of the machine resource as unsupported ways to update Azure Local, and the script ran Windows Update on the machines; Start-SolutionUpdateAfterDeployment.ps1 and Azure Update Manager update the system' }
        @{ Path = 'scripts/common/utilities/helpers/config-loader.ps1'; Why = 'Import-AzlInfrastructure is the one loader' }
        @{ Path = 'scripts/common/utilities/helpers/keyvault-helper.ps1'; Why = 'AzlSecret.psm1 is the one secret resolver' }
        @{ Path = 'config/variables/variables.example.yml'; Why = 'the old layout' }
        @{ Path = 'config/variables/schema/variables.schema.json'; Why = 'the old layout' }
        @{ Path = 'config/variables/scripts/validate-variables.ps1'; Why = 'it validated the old layout' }
        @{ Path = 'config/variables/scripts/Test-VariablesFile.ps1'; Why = 'it validated the old layout' }
        @{ Path = 'config/variables/scripts/Test-VariableConfig.ps1'; Why = 'it wrapped the old validators' }
    )
    $script:Placeholders = @(
        foreach ($area in '03-onprem-readiness', '05-operational-foundations', '06-testing-validation') {
            Get-ChildItem -LiteralPath ([IO.Path]::Combine($deploy, $area)) -Recurse -File -Filter '*.ps1' |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Invoke-Deployment(AzCliPowerShell|Orchestrated|Standalone)\b' } |
                ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
        }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Scopes = @(
        'scripts/deploy/03-onprem-readiness', 'scripts/deploy/05-operational-foundations', 'scripts/deploy/06-testing-validation', 'scripts/deploy/common',
        'scripts/tools', 'scripts/lifecycle', 'scripts/common/utilities'
    ) | ForEach-Object { Join-Path $script:Repo $_ }
    function Get-ScopeScript {
        foreach ($scope in $script:Scopes) { Get-ChildItem -LiteralPath $scope -Recurse -File -Filter '*.ps1' }
    }
}

Describe 'The scripts a schema 5 script replaces are gone' {
    It '<Name> is removed from <Folder> and <Why>' -ForEach $script:Removed {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', $Folder.Replace('/', [IO.Path]::DirectorySeparatorChar), $Name)) | Should -BeFalse
    }
    It 'the script that does the job instead of <Name> is there' -ForEach $script:Removed {
        $target = if ($Instead -like 'scripts/*') { $Instead } else { "scripts/deploy/$Instead" }
        Test-Path -LiteralPath (Join-Path $script:Repo $target) | Should -BeTrue
    }
    It '<Path> is removed' -ForEach $script:RemovedOutside {
        Test-Path -LiteralPath (Join-Path $script:Repo $Path) | Should -BeFalse
    }
    It 'the task folder of a removed script keeps its wrapper and its catalogue entry' -ForEach @($script:Removed | Where-Object { $_.Folder -ne 'common' }) {
        $taskDirectory = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', $Folder.Replace('/', [IO.Path]::DirectorySeparatorChar))
        @(Get-ChildItem -LiteralPath $taskDirectory -Filter '*-Orchestrated.ps1').Count | Should -BeGreaterThan 0
        $task = $Folder -replace '/powershell$', ''
        $catalogue = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', 'common', 'TaskCatalogue.psd1'))
        @($catalogue.Tasks | Where-Object { $_.Path -eq $task }).Count | Should -Be 1
    }
}

Describe 'No script of these folders uses the old layout' {
    It 'no script takes -ConfigPath or -ConfigFile, or an alias of them' {
        $found = foreach ($file in Get-ScopeScript) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            if (-not $ast.ParamBlock) { continue }
            foreach ($parameter in $ast.ParamBlock.Parameters) {
                $aliases = @($parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' } | ForEach-Object { $_.PositionalArguments | ForEach-Object { $_.Value } })
                if ($parameter.Name.VariablePath.UserPath -in 'ConfigPath', 'ConfigFile' -or $aliases -contains 'ConfigPath' -or $aliases -contains 'ConfigFile') { "$($file.FullName.Substring($script:Repo.Length + 1)): -$($parameter.Name.VariablePath.UserPath)" }
            }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'no script asks for a credential or a value' {
        $found = foreach ($file in Get-ScopeScript) {
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$null)
            $hit = @($tokens | Where-Object { $_.Kind -eq 'Identifier' -or $_.Kind -eq 'Generic' } | Where-Object { $_.Text -in 'Read-Host', 'Get-Credential' -or $_.Text -like '*PromptForCredential*' })
            if ($hit.Count) { "$($file.FullName.Substring($script:Repo.Length + 1)): $($hit[0].Text)" }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'no script, pipeline or document loads config-loader.ps1 or keyvault-helper.ps1, or calls Get-SolutionConfig' {
        $skip = 'CHANGELOG.md', 'MIGRATION.md', 'master-registry.yaml', 'OldLayoutRetired.Tests.ps1', 'LegacyUtilities.Tests.ps1', 'variable-map.csv', 'variable-map-external-readers.csv', 'ztp.csv'
        $hits = foreach ($root in 'scripts', 'pipelines', 'ansible', 'docs', 'src', 'tools', 'README.md') {
            $path = Join-Path $script:Repo $root
            if (-not (Test-Path -LiteralPath $path)) { continue }
            Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/](deferred|optional|node_modules|\.terraform|fixtures)[\\/]' -and $_.Name -notin $skip -and $_.Length -lt 3MB } |
                Select-String -Pattern '(?<![\w-])(config-loader|keyvault-helper)\.ps1|Get-SolutionConfig' -List
        }
        @($hits | ForEach-Object { $_.Path.Substring($script:Repo.Length + 1) } | Where-Object { $_ -notmatch 'cicd-infra-audit\.md$|utilities[\\/]helpers[\\/]README\.md$' }) | Should -BeNullOrEmpty
    }

    It 'no pipeline variable points at config/variables/variables.yml' {
        $hits = Get-ChildItem -LiteralPath (Join-Path $script:Repo 'pipelines') -Recurse -File | Select-String -Pattern 'variables\.yml|CONFIG_PATH' -List
        @($hits | ForEach-Object { $_.Path.Substring($script:Repo.Length + 1) }) | Should -BeNullOrEmpty
    }
}

Describe 'The placeholders of scripts/deploy 03, 05 and 06 take -InfrastructureFile' {
    It 'finds the placeholders (42 of them when this was written)' {
        $count = 0
        foreach ($area in '03-onprem-readiness', '05-operational-foundations', '06-testing-validation') {
            $count += @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', $area)) -Recurse -File -Filter '*.ps1' |
                    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Invoke-Deployment(AzCliPowerShell|Orchestrated|Standalone)\b' }).Count
        }
        $count | Should -BeGreaterThan 30
    }
    It '<Name> takes a mandatory -InfrastructureFile and has no -ConfigPath, -Credential or -TargetNode' -ForEach $script:Placeholders {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match '\[Parameter\(Mandatory\)\]\[string\]\$InfrastructureFile'
        $text | Should -Not -Match 'ConfigPath|\$Credential|\$TargetNode'
    }
}

Describe 'DeploymentScaffold.psm1 and the generator' {
    BeforeAll {
        $script:Scaffold = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', 'common', 'DeploymentScaffold.psm1')
        $script:Generator = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', 'common', 'Generate-DeployScriptScaffolds.ps1')
    }
    It 'takes -InfrastructureFile in the two functions that took -ConfigPath' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Scaffold, [ref]$null, [ref]$null)
        foreach ($name in 'Invoke-DeploymentOrchestrated', 'Invoke-DeploymentAzCliPowerShell') {
            $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            @($function.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Contain 'InfrastructureFile'
        }
    }
    It 'has no -ConfigPath any more (no placeholder passes it)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Scaffold, [ref]$null, [ref]$null)
        foreach ($name in 'Invoke-DeploymentOrchestrated', 'Invoke-DeploymentAzCliPowerShell') {
            $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            @($function.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Not -Contain 'ConfigPath'
        }
    }
    It 'ends a placeholder call with exit code 3' {
        $module = $script:Scaffold
        $command = "Import-Module '$module' -Force; Invoke-DeploymentOrchestrated -TaskPath 'x/y/z' -InfrastructureFile 'ignored'"
        $null = & pwsh -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should -Be 3
    }
    It 'the generator writes -InfrastructureFile and no -ConfigPath' {
        $text = Get-Content -LiteralPath $script:Generator -Raw
        $text | Should -Match '\$InfrastructureFile'
        $text | Should -Not -Match 'ConfigPath'
    }
}
