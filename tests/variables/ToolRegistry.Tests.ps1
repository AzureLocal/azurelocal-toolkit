#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The registry is master of the variables each tool owns (tools.<tool>.<kind>.<group>.<name>): parameters, settings, config keys,
# events, state and handoff fields, secret names, environment variables. These tests fail when a script parameter is not registered.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $script:RunExternal = $env:AZL_CHECK_EXTERNAL_TOOLS -eq '1'
}

BeforeAll {
    $script:Repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:Scripts = Join-Path $script:Repo 'config\variables\scripts'
    Import-Module (Join-Path $script:Scripts 'VariableRegistry.psm1') -Force
    $script:Registry = @(Get-RegistryVariable -Path (Join-Path $script:Repo 'config\variables\schema\master-registry.yaml'))
}

Describe 'The tools section of the registry' {
    It 'holds variables for <_>' -ForEach 'os_configuration', 'ztp', 'sonar', 'arm_deployment', 'cicd_infra', 'discovery', 'ranger', 'loadtools' {
        $tool = $_
                @($script:Registry | Where-Object { $_.Path -match "^tools\.$tool\.[^.]+\.[^.]+\.[^.]+$" }).Count | Should -BeGreaterThan 10
    }

    It 'registers the OS configuration wrapper parameters (Mode, Step, Node, InfrastructureFile)' {
        $paths = $script:Registry.Path
        foreach ($name in 'Mode', 'Step', 'Node', 'InfrastructureFile') {
            @($paths | Where-Object { $_ -match "^tools\.os_configuration\.parameters\.[^.]+\.$name$" }).Count | Should -BeGreaterThan 0 -Because $name
        }
    }

    It 'gives every tools variable a name' {
        $leaf = @($script:Registry | Where-Object { $_.Path -match '^tools\.[^.]+\.[^.]+\.[^.]+\.[^.]+$' })
        $leaf.Count | Should -BeGreaterThan 2000
        @($leaf | Where-Object { -not $_.Node.Contains('name') }) | Should -BeNullOrEmpty
    }
}

Describe 'Script parameters are registered' {
    It 'every parameter of the <_> scripts in this repository is in the registry' -ForEach 'os_configuration', 'arm_deployment', 'cicd_infra' {
        $problems = @(& (Join-Path $script:Scripts 'Test-ToolParameterRegistration.ps1') -Tool $_ -Root $script:Repo -Registry $script:Registry)
        $lines = @($problems | ForEach-Object { "$(Split-Path -Leaf $_.Script) -$($_.Parameter)" })
        $lines | Should -BeNullOrEmpty -Because "register them in config/variables/schema/master-registry.yaml first: $($lines -join ', ')"
    }

    # tools.discovery describes the Dell Redfish discovery rewrite (branch tk-dell-discovery); the scripts in this branch are the earlier versions.
    It 'discovery scripts are checked once the discovery branch is merged' -Skip {
    }

    It 'reports a parameter that is not registered' {
        $dir = Join-Path $TestDrive 'scripts'
        $null = New-Item -ItemType Directory -Path $dir
        Set-Content (Join-Path $dir 'Invoke-AzureLocalArmDeployment.ps1') -Value 'param([string]$InfrastructureFile, [string]$NotInTheRegistry)'
        $problems = @(& (Join-Path $script:Scripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root $dir -Registry $script:Registry)
        $problems.Parameter | Should -Be @('NotInTheRegistry')
    }

    It 'reports a script no registry group names, with -ReportUnregisteredScripts' {
        $dir = Join-Path $TestDrive 'scripts2'
        $null = New-Item -ItemType Directory -Path $dir
        Set-Content (Join-Path $dir 'Brand-New-Tool.ps1') -Value 'param([string]$Anything)'
        @(& (Join-Path $script:Scripts 'Test-ToolParameterRegistration.ps1') -Tool ztp -Root $dir -Registry $script:Registry).Count | Should -Be 0
        $problems = @(& (Join-Path $script:Scripts 'Test-ToolParameterRegistration.ps1') -Tool ztp -Root $dir -Registry $script:Registry -ReportUnregisteredScripts)
        $problems.Problem | Should -Match 'not registered'
    }
}

Describe 'Tool mappings (ztp, sonar, ranger, loadtools, draftsman)' {
    It '<_>.csv is current and names only registry paths' -ForEach 'ztp', 'sonar', 'ranger', 'loadtools', 'draftsman' {
        $file = Join-Path $script:Repo "config\variables\tool-mappings\$_.csv"
        $file | Should -Exist
        $out = Join-Path $TestDrive 'maps'
        & (Join-Path $script:Scripts 'New-ToolMapping.ps1') -Tool $_ -Registry $script:Registry -OutputDirectory $out 6>$null
        ([IO.File]::ReadAllText($file).Replace("`r`n", "`n")) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $out "$_.csv")).Replace("`r`n", "`n"))
        $known = [System.Collections.Generic.HashSet[string]]::new([string[]]$script:Registry.Path)
        foreach ($row in (Import-Csv $file)) { $known.Contains($row.registry_path) | Should -BeTrue -Because $row.registry_path }
    }
}

Describe 'Tools in other repositories' {
    It 'every parameter of azurelocal-ztp is registered' -Skip:(-not $script:RunExternal) {
        $root = if ($env:AZL_ZTP_REPO) { $env:AZL_ZTP_REPO } else { 'D:\git\azurelocal\azurelocal-ztp' }
        @(& (Join-Path $script:Scripts 'Test-ToolParameterRegistration.ps1') -Tool ztp -Root $root -Registry $script:Registry) | Should -BeNullOrEmpty
    }
    It 'every parameter of azurelocal-sonar is registered' -Skip:(-not $script:RunExternal) {
        $root = if ($env:AZL_SONAR_REPO) { $env:AZL_SONAR_REPO } else { 'D:\git\azurelocal\azurelocal-sonar' }
        @(& (Join-Path $script:Scripts 'Test-ToolParameterRegistration.ps1') -Tool sonar -Root $root -Registry $script:Registry) | Should -BeNullOrEmpty
    }
}
