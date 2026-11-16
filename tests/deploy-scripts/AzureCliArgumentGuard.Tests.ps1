#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The guard that keeps a character az.cmd cannot carry out of every Azure CLI script of the toolkit (scripts/common/azure-cli/AzlAzureCliArgument.psm1).
# On Windows az is a batch file; cmd.exe reads & | < > ^ in an argument as operators and %NAME% as a variable. The tests prove, for every *.azcli.ps1 under
# scripts/deploy: it imports the guard, its one function that starts az calls the guard first, and that function refuses an unsafe argument (exit code 2, az
# not started, the value not in the message). No az command is run: az is a stub function.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/AzureCliArgumentGuard.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The stub az and the wrapper under test run in other scopes; a global is how the test counts the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters.')]
param()

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:AzCliScripts = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'deploy')) -Recurse -Filter '*.azcli.ps1' | Sort-Object FullName | ForEach-Object {
            $text = Get-Content -LiteralPath $_.FullName -Raw
            @{ Name = $_.Name; Path = $_.FullName; CallsAz = ($text -match '&\s+az\s+@') }
        })
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1')) -Force
    $global:AzlGuardAzCalls = 0
    $script:Unsafe = @('a&b', 'a|b', 'a<b', 'a>b', 'a^b', '100%', 'say "hi"', "line1`nline2", "line1`rline2")

    # The function of a script that starts az, and the AST facts about it.
    function Get-AzFunction([string]$Path) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $calls = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Ampersand' -and $n.CommandElements[0].Extent.Text -eq 'az' }, $true)
        foreach ($call in $calls) {
            $parent = $call.Parent
            $function = $null
            $block = $null
            while ($parent) {
                if ($parent -is [Management.Automation.Language.ScriptBlockExpressionAst] -and -not $block) { $block = $parent }
                if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { $function = $parent; break }
                $parent = $parent.Parent
            }
            # An az call in a script block that is the -Az argument of Get-AzlSecretPlainTextAzureCli: the module checks the arguments (and the secret).
            $inSecretBlock = $false
            if ($block) {
                $owner = $block.Parent
                while ($owner -and $owner -isnot [Management.Automation.Language.CommandAst]) { $owner = $owner.Parent }
                if ($owner -and $owner.CommandElements[0].Extent.Text -eq 'Get-AzlSecretPlainTextAzureCli') { $inSecretBlock = $true }
            }
            [pscustomobject]@{ Call = $call; Function = $function; InSecretBlock = $inSecretBlock }
        }
    }
}

AfterAll { Remove-Variable -Name AzlGuardAzCalls -Scope Global -ErrorAction SilentlyContinue }

Describe 'AzlAzureCliArgument.psm1' {
    It 'finds an unsafe character in an argument and names the position and the option, never the value' -ForEach @(
        @{ Value = 'a&b' }, @{ Value = 'a|b' }, @{ Value = 'a<b' }, @{ Value = 'a>b' }, @{ Value = 'a^b' }, @{ Value = '100%' }, @{ Value = 'say "hi"' }, @{ Value = "a`nb" }, @{ Value = "a`rb" }
    ) {
        $message = Get-AzlAzureCliArgumentProblem -Argument @('group', 'create', '--name', 'rg-one', '--tags', "owner=$Value")
        $message | Should -Match 'Argument 6 of an az call \(the value of --tags\)'
        $message | Should -Not -Match ([regex]::Escape($Value))
        $message | Should -Not -Match 'owner'
    }

    It 'accepts every argument a script of the toolkit builds from a safe value' {
        Get-AzlAzureCliArgumentProblem -Argument @('group', 'create', '--name', 'rg-azl-01', '--location', 'eastus', '--tags', 'environment=lab', 'owner=ops team', '--query', '[].{name:name,id:id}', '--output', 'json') | Should -BeNullOrEmpty
        Get-AzlAzureCliArgumentProblem -Argument @() | Should -BeNullOrEmpty
        Get-AzlAzureCliArgumentProblem -Argument $null | Should -BeNullOrEmpty
        Get-AzlAzureCliArgumentProblem -Argument @('a', @('b', 'c')) | Should -BeNullOrEmpty
    }

    It 'finds an unsafe argument that arrives inside a nested list' {
        Get-AzlAzureCliArgumentProblem -Argument @('a', @('b', 'c&d')) | Should -Match 'Argument 3'
    }

    It 'names the key and shows the value of a value of the file (map, list and text)' {
        $m = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = 'rg&calc' })
        $m | Should -Match 'azure.resource_group holds the value ''rg&calc'''
        $m = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = [ordered]@{ owner = 'a|b' } })
        $m | Should -Match "tags.owner holds the value 'a\|b'"
        $m = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = [ordered]@{ 'k^ey' = 'x' } })
        $m | Should -Match "key 'k\^ey'"
        $m = Get-AzlAzureCliValueProblem -Value ([ordered]@{ names = @('ok', 'bad%name') })
        $m | Should -Match "names\[1\] holds the value 'bad%name'"
        $m = Get-AzlAzureCliValueProblem -Value ([ordered]@{ text = "a`nb" })
        $m | Should -Match 'a\\nb'
        Get-AzlAzureCliValueProblem -Value ([ordered]@{ a = 'x'; b = @('y', 'z'); c = [ordered]@{ k = 'v' }; d = $null; e = '' }) | Should -BeNullOrEmpty
    }

    It 'leaves the value out of the message of a secret' {
        $m = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'the shared key' = 'Canary&Secret' }) -Secret
        $m | Should -Match 'the shared key holds one of'
        $m | Should -Not -Match 'Canary'
    }

    It 'throws an error with exit code 2 for a secret with an unsafe character, and the error never holds the value' -ForEach @(@{ Value = 'Pa&ss' }, @{ Value = 'Pa%PATH%ss' }, @{ Value = "Pa`nss" }) {
        $err = try { Assert-AzlAzureCliSecret -Name 'keyvault://kv-azl-01/vpn-key' -Value $Value } catch { $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Data['AzlExit'] | Should -Be 2
        $err.Exception.Data['AzlSecretError'] | Should -Be 'UnsafeCharacter'
        $err.Exception.Message | Should -Match 'keyvault://kv-azl-01/vpn-key'
        $err.Exception.Message | Should -Not -Match 'Pa'
        { Assert-AzlAzureCliSecret -Name 'x' -Value 'Plain-Secret_1.2' } | Should -Not -Throw
    }
}

Describe 'every Azure CLI script of the toolkit' {
    It '<Name> imports the guard and starts az only in a function that calls it first' -ForEach @($script:AzCliScripts | Where-Object { $_.CallsAz }) {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match 'AzlAzureCliArgument\.psm1'
        $facts = @(Get-AzFunction $Path)
        $facts.Count | Should -BeGreaterThan 0
        foreach ($fact in $facts) {
            if ($fact.InSecretBlock) { continue }
            $fact.Function | Should -Not -BeNullOrEmpty -Because 'an az call outside a function would skip the guard'
            $body = $fact.Function.Extent.Text
            $guard = $body.IndexOf('Get-AzlAzureCliArgumentProblem', [StringComparison]::Ordinal)
            $guard | Should -BeGreaterThan -1 -Because "the function $($fact.Function.Name) starts az"
            $guard | Should -BeLessThan ($fact.Call.Extent.StartOffset - $fact.Function.Extent.StartOffset) -Because 'the guard runs before az is started'
            $body | Should -Match 'Exit-InputProblem' -Because 'an unsafe argument ends the run with exit code 2'
        }
    }

    It '<Name> has no private pattern of unsafe characters left' -ForEach @($script:AzCliScripts | Where-Object { $_.CallsAz }) {
        (Get-Content -LiteralPath $Path -Raw) | Should -Not -Match '\$UnsafeArgument'
    }

    It '<Name> refuses an unsafe argument with exit code 2, does not start az, and does not echo the value' -ForEach @($script:AzCliScripts | Where-Object { $_.CallsAz }) {
        $fact = @(Get-AzFunction $Path | Where-Object { -not $_.InSecretBlock })[0]
        $name = $fact.Function.Name
        $definition = $fact.Function.Extent.Text
        foreach ($value in $script:Unsafe) {
            $global:AzlGuardAzCalls = 0
            $thrown = & {
                function Exit-InputProblem([string]$Message) { throw "EXIT2:$Message" }
                function az { $global:AzlGuardAzCalls++; $global:LASTEXITCODE = 0; 'ok' }
                . ([scriptblock]::Create($definition))
                try { $null = & $name (, [string[]]@('group', 'create', '--tags', "owner=$value")); '' } catch { $_.Exception.Message }
            }
            $thrown | Should -Match '^EXIT2:' -Because "the value '$($value -replace "[`r`n]", '?')' must stop the run"
            $global:AzlGuardAzCalls | Should -Be 0
            $thrown | Should -Not -Match 'owner'
        }
    }

    It '<Name> passes a safe argument list to az' -ForEach @($script:AzCliScripts | Where-Object { $_.CallsAz }) {
        $fact = @(Get-AzFunction $Path | Where-Object { -not $_.InSecretBlock })[0]
        $name = $fact.Function.Name
        $definition = $fact.Function.Extent.Text
        $global:AzlGuardAzCalls = 0
        & {
            function Exit-InputProblem([string]$Message) { throw "EXIT2:$Message" }
            function az { $global:AzlGuardAzCalls++; $global:LASTEXITCODE = 0; 'ok' }
            . ([scriptblock]::Create($definition))
            $null = & $name (, [string[]]@('group', 'show', '--name', 'rg-azl-01', '--tags', 'owner=ops team'))
        }
        $global:AzlGuardAzCalls | Should -Be 1
    }
}
