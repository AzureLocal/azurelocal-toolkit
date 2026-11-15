#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# A YAML mapping that names a key twice keeps only one of them, and which one depends on the reader: the registry
# loaders read without -Ordered and keep the last copy silently. This test reads every YAML file of the registry,
# the variable templates and examples, the pipelines and the Ansible trees with ConvertFrom-Yaml -Ordered, which
# stops on a repeated key. Nothing is run and nothing is sent anywhere.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/YamlDuplicateKeys.Tests.ps1

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $roots = 'config', 'pipelines', 'src/ansible', 'ansible'
    $script:Files = @(foreach ($r in $roots) {
            $path = [IO.Path]::Combine($repo, $r)
            if (Test-Path -LiteralPath $path) {
                Get-ChildItem -LiteralPath $path -Recurse -File -Include '*.yml', '*.yaml' |
                    ForEach-Object { @{ File = $_.FullName.Substring($repo.Length + 1).Replace('\', '/'); Path = $_.FullName } }
            }
        })
}

Describe 'No YAML file of the toolkit names a key twice' {
    BeforeAll { Import-Module powershell-yaml }
    It 'finds the YAML files' -ForEach @{ Count = $script:Files.Count } { $Count | Should -BeGreaterThan 50 }
    It '<File>' -ForEach $script:Files {
        $text = [IO.File]::ReadAllText($Path)
        { $null = ConvertFrom-Yaml -Ordered -AllDocuments $text } | Should -Not -Throw -Because "$File must not repeat a key in one mapping (the readers would disagree about which copy counts)"
    }
}
