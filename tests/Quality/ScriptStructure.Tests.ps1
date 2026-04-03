#Requires -Modules Pester
<#
.SYNOPSIS
    Structural compliance tests for all scripts in scripts/
.DESCRIPTION
    Validates that every PowerShell script in the scripts/ directory follows
    the Azure Local Cloud scripting standards:
      - Has a .SYNOPSIS block
      - Has a .DESCRIPTION block
      - Has a .NOTES block containing Author: and Version:
      - Uses [CmdletBinding()]
#>

BeforeDiscovery {
    $repoRoot    = Join-Path $PSScriptRoot '..' '..'
    $scriptsRoot = Join-Path $repoRoot 'scripts'

    $scriptFiles = Get-ChildItem -Path $scriptsRoot -Recurse -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch [regex]::Escape($PSScriptRoot) }

    $script:scriptTestCases = $scriptFiles | ForEach-Object { @{ ScriptFile = $_ } }
}

Describe 'Script Structure Compliance' {
    Context 'Comment-based help' {
        It '<ScriptFile.Name> should have a .SYNOPSIS block' -ForEach $script:scriptTestCases {
            $content = Get-Content $ScriptFile.FullName -Raw
            $content | Should -Match '\.SYNOPSIS'
        }

        It '<ScriptFile.Name> should have a .DESCRIPTION block' -ForEach $script:scriptTestCases {
            $content = Get-Content $ScriptFile.FullName -Raw
            $content | Should -Match '\.DESCRIPTION'
        }

        It '<ScriptFile.Name> should have a .NOTES block' -ForEach $script:scriptTestCases {
            $content = Get-Content $ScriptFile.FullName -Raw
            $content | Should -Match '\.NOTES'
        }
    }

    Context 'Script standards' {
        It '<ScriptFile.Name> should use [CmdletBinding()]' -ForEach $script:scriptTestCases {
            $content = Get-Content $ScriptFile.FullName -Raw
            $content | Should -Match '\[CmdletBinding\(\)'
        }

        It '<ScriptFile.Name> should declare Author in .NOTES' -ForEach $script:scriptTestCases {
            $content = Get-Content $ScriptFile.FullName -Raw
            $content | Should -Match '(?i)Author\s*:'
        }

        It '<ScriptFile.Name> should declare Version in .NOTES' -ForEach $script:scriptTestCases {
            $content = Get-Content $ScriptFile.FullName -Raw
            $content | Should -Match '(?i)Version\s*:\s*\d+\.\d+'
        }
    }

    Context 'File naming' {
        It '<ScriptFile.Name> should follow Verb-Noun.ps1 naming or az-verb-resource pattern' -ForEach $script:scriptTestCases {
            # Accept: Verb-Noun.ps1, Invoke-Verb-Action.ps1, az-verb-resource.ps1, helpers (lowercase)
            $name = $ScriptFile.Name
            $validPattern = $name -match '^[A-Z][a-z]+-[A-Z]' -or      # Verb-Noun
                            $name -match '^az-' -or                      # Azure CLI
                            $name -match '^[a-z].*\.ps1$'               # lowercase helpers
            $validPattern | Should -BeTrue -Because "'$name' does not match Verb-Noun.ps1, az-verb-resource.ps1, or lowercase helper naming"
        }
    }
}
