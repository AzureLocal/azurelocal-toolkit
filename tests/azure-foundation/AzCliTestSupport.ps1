#Requires -Version 7.0
# Shared helpers of the *.AzCli.Tests.ps1 files in this folder: a fake "az" that records every call and answers from a list of routes, and a runner that
# starts an Azure CLI script and returns its exit code, its result objects and its messages. No Azure, no tenant and no sign-in is used: the tests mock "az".
# Dot-source it in BeforeAll:  . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the routes and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

# Starts a test: an empty call log, the default routes (sign-in to the tenant, the arcgateway extension present) and a fresh set of ids.
function Initialize-AzFake {
    $global:AzlFakeCalls = [System.Collections.Generic.List[string]]::new()
    $global:AzlFakeRoutes = [System.Collections.Generic.List[object]]::new()
    if (-not $global:AzlFakeTenant) { $global:AzlFakeTenant = [guid]::NewGuid().ToString() }
    Add-AzRoute 'account show*' { $global:AzlFakeTenant }
    Add-AzRoute 'extension show*' '1.0.0'
}

# A route: the first call whose text (all arguments joined by a blank) is -like $Like gets the answer. A later route wins over an earlier one.
# $Out is text, an object (answered as JSON) or a script block that gets the arguments. $Code is the exit code of az.
function Add-AzRoute([string]$Like, [object]$Out = '', [int]$Code = 0) {
    $global:AzlFakeRoutes.Insert(0, [pscustomobject]@{ Like = $Like; Out = $Out; Code = $Code })
}

# The answer az gives for a resource that is not there (exit code 3, the text the Azure CLI prints).
function Add-AzNotFound([string]$Like) {
    Add-AzRoute $Like "ERROR: (ResourceNotFound) The Resource 'Microsoft.Test/things/x' under resource group 'rg' was not found. Code: ResourceNotFound" 3
}

# The fake az. A "show" nobody routed is not found; anything else nobody routed answers with an empty JSON object.
# Each call is recorded as the arguments joined by a blank, without the trailing --output json that the scripts add to every call whose answer they parse.
function global:Invoke-AzFake([object[]]$AzArgs) {
    $line = (($AzArgs | ForEach-Object { "$_" }) -join ' ') -replace ' --output json$', ''
    $global:AzlFakeCalls.Add($line)
    foreach ($route in $global:AzlFakeRoutes) {
        if ($line -like $route.Like) {
            $global:LASTEXITCODE = $route.Code
            if ($route.Out -is [scriptblock]) { return (& $route.Out @AzArgs) }
            if ($route.Out -is [string]) { return $route.Out }
            return ($route.Out | ConvertTo-Json -Depth 12 -Compress)
        }
    }
    if ($line -match ' show( |$)') {
        $global:LASTEXITCODE = 3
        return "ERROR: (ResourceNotFound) The Resource was not found. Code: ResourceNotFound"
    }
    $global:LASTEXITCODE = 0
    '{}'
}

# The recorded az calls whose text is -like $Like.
function Get-AzCall([string]$Like = '*') { @($global:AzlFakeCalls | Where-Object { $_ -like $Like }) }

# A call that writes to Azure: anything but a read (show, list, account, extension).
function Get-AzWriteCall { @($global:AzlFakeCalls | Where-Object { $_ -notmatch '^(account|extension) ' -and $_ -notmatch ' (show|list)( |$)' }) }

# Runs the script. Result objects are the output objects that are not text and not a message record.
function Invoke-AzCliScript([string]$Script, [string]$File, [hashtable]$Extra = @{}, [switch]$DryRun) {
    $global:LASTEXITCODE = $null
    $all = if ($DryRun) { & $Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
    $code = $global:LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $code
        Rows     = @($all | Where-Object { $_ -isnot [string] -and $_ -isnot [Management.Automation.InformationRecord] -and $_ -isnot [Management.Automation.WarningRecord] -and $_ -isnot [Management.Automation.ErrorRecord] -and $_ -isnot [Management.Automation.VerboseRecord] })
        Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
    }
}

# Writes a document (an ordered hashtable) as an infrastructure file in the test drive and returns its path.
function Save-AzInfraFile([object]$Document) {
    $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
    Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $Document)
    $file
}

# Applies an override map to an ordered hashtable: a $null value removes the key.
function Set-AzOverride([System.Collections.IDictionary]$Target, [hashtable]$Override) {
    foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $Target.Remove($k) } else { $Target[$k] = $Override[$k] } }
    $Target
}
