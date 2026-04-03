#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for scripts/common/utilities/helpers/config-loader.ps1
.DESCRIPTION
    Tests configuration loading, merging, and path resolution using
    test fixture YAML files from TestDrive. Does not read real config files.
#>

BeforeAll {
    # Ensure powershell-yaml module is present
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        # Skip gracefully if the module is not available in the test environment
        Write-Warning 'powershell-yaml module not found — config-loader tests will be skipped'
        return
    }

    $helpersPath = Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'common' 'utilities' 'helpers'
    . (Join-Path $helpersPath 'logging.ps1')
    # Suppress Export-ModuleMember errors — it is a no-op when dot-sourcing a .ps1 file
    try { . (Join-Path $helpersPath 'config-loader.ps1') } catch {
        if ($_.Exception.Message -notmatch 'Export-ModuleMember') { throw }
    }
}

Describe 'Get-ConfigValue' {
    Context 'Path resolution' {
        It 'should return a top-level key value' {
            $config = @{ azure = @{ tenant = @{ id = 'tenant-123' } } }
            $result = Get-ConfigValue -Config $config -Path 'azure.tenant.id'
            $result | Should -Be 'tenant-123'
        }

        It 'should return null for a missing path' {
            $config = @{ azure = @{ tenant = @{ id = 'tenant-123' } } }
            $result = Get-ConfigValue -Config $config -Path 'azure.missing.key'
            $result | Should -BeNullOrEmpty
        }

        It 'should return null for an empty config' {
            $result = Get-ConfigValue -Config @{} -Path 'any.path'
            $result | Should -BeNullOrEmpty
        }

        It 'should handle a single-segment path' {
            $config = @{ name = 'test' }
            $result = Get-ConfigValue -Config $config -Path 'name'
            $result | Should -Be 'test'
        }

        It 'should return nested hashtable when path points to an object' {
            $config = @{ azure = @{ networks = @{ vnet = 'vnet-001' } } }
            $result = Get-ConfigValue -Config $config -Path 'azure.networks'
            $result | Should -BeOfType [hashtable]
            $result.vnet | Should -Be 'vnet-001'
        }
    }
}

Describe 'Merge-Hashtables' {
    Context 'Config merging' {
        It 'should prefer values from the override config' {
            $base     = @{ key = 'base-value'; other = 'unchanged' }
            $override = @{ key = 'override-value' }
            $result   = Merge-Hashtables -Base $base -Override $override
            $result.key   | Should -Be 'override-value'
            $result.other | Should -Be 'unchanged'
        }

        It 'should include keys only in the base config' {
            $base     = @{ a = 1; b = 2 }
            $override = @{ b = 99 }
            $result   = Merge-Hashtables -Base $base -Override $override
            $result.a | Should -Be 1
            $result.b | Should -Be 99
        }

        It 'should add new keys from the override' {
            $base     = @{ existing = 'yes' }
            $override = @{ newkey = 'added' }
            $result   = Merge-Hashtables -Base $base -Override $override
            $result.existing | Should -Be 'yes'
            $result.newkey   | Should -Be 'added'
        }

        It 'should deep-merge nested hashtables' {
            $base     = @{ network = @{ vnet = 'vnet-base'; subnet = 'subnet-base' } }
            $override = @{ network = @{ vnet = 'vnet-override' } }
            $result   = Merge-Hashtables -Base $base -Override $override
            $result.network.vnet   | Should -Be 'vnet-override'
            $result.network.subnet | Should -Be 'subnet-base'
        }
    }
}

Describe 'Test-ConfigPaths' {
    Context 'Validation' {
        It 'should return IsValid true when all required paths are present' {
            $config = @{
                azure = @{ tenant = @{ id = 'tid' }; subscription = @{ id = 'sid' } }
                azure_infrastructure = @{
                    key_vaults  = @{ platform = @{ name = 'kv-platform' } }
                    resource_groups = @{ management = @{ name = 'rg-mgmt' } }
                }
                solution = @{ name = 'azure-local'; type = 'full' }
            }
            $result = Test-ConfigPaths -Config $config
            $result.IsValid | Should -BeTrue
        }

        It 'should return IsValid false when required paths are missing' {
            $config = @{ azure = @{ tenant = @{ id = 'tid' } } }
            $result = Test-ConfigPaths -Config $config
            $result.IsValid | Should -BeFalse
        }

        It 'should list the missing paths' {
            $config = @{}
            $result = Test-ConfigPaths -Config $config
            $result.MissingPaths.Count | Should -BeGreaterThan 0
        }
    }
}
