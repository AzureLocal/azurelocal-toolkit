#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# No JSON file under config/ repeats a property name inside one object.
# ConvertFrom-Json (with or without -AsHashtable) keeps the later copy of a repeated key without a word, so a second entry silently
# replaces the first: config/azure/arm-templates/parameter-sources.json once listed nodes, chapType, chapUsername and chapCredential
# twice and the iSCSI mapping was lost. The test parses every file with Newtonsoft.Json (part of PowerShell 7) set to fail on a
# duplicate property name (JsonLoadSettings.DuplicatePropertyNameHandling = Error), so the error names the file, the line and the key.
# Reads files only; nothing runs against Azure or a node.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/ConfigJsonDuplicateKeys.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $jsonCase = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($repo, 'config')) -Recurse -File -Filter '*.json' |
            Sort-Object FullName |
            ForEach-Object { @{ Path = $_.FullName; Name = [IO.Path]::GetRelativePath($repo, $_.FullName).Replace('\', '/') } })
}

BeforeAll {
    # Returns $null when the text has no repeated property name in any object, else the message of the parser (line, position, key).
    function Get-DuplicatePropertyError([string]$Text) {
        $settings = [Newtonsoft.Json.Linq.JsonLoadSettings]::new()
        $settings.DuplicatePropertyNameHandling = [Newtonsoft.Json.Linq.DuplicatePropertyNameHandling]::Error
        $settings.CommentHandling = [Newtonsoft.Json.Linq.CommentHandling]::Ignore
        try { $null = [Newtonsoft.Json.Linq.JToken]::Parse($Text, $settings); return $null }
        catch { return $_.Exception.InnerException.Message ?? $_.Exception.Message }
    }
}

Describe 'The duplicate check itself' {
    It 'finds a key repeated in a nested object' {
        Get-DuplicatePropertyError '{ "a": 1, "b": { "c": 1, "c": 2 } }' | Should -Match "'c'"
    }
    It 'finds a key repeated at the top' {
        Get-DuplicatePropertyError '{ "a": 1, "a": 2 }' | Should -Not -BeNullOrEmpty
    }
    It 'accepts the same key in two different objects' {
        Get-DuplicatePropertyError '{ "x": { "c": 1 }, "y": { "c": 2 }, "z": [ { "c": 1 }, { "c": 2 } ] }' | Should -BeNullOrEmpty
    }
}

Describe 'No JSON file under config/ repeats a key in one object' {
    It 'finds the JSON files (an empty list would hide a regression)' -ForEach @(@{ Count = $jsonCase.Count }) {
        $Count | Should -BeGreaterThan 10
    }
    It '<Name> has no repeated property name' -ForEach $jsonCase {
        Get-DuplicatePropertyError (Get-Content -LiteralPath $Path -Raw) | Should -BeNullOrEmpty -Because "$Name repeats a key; ConvertFrom-Json would keep only the later copy"
    }
}
