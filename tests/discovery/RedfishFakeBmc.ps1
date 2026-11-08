#Requires -Version 7.0
# Test helper (dot-sourced by the Redfish tests): a fake BMC that answers from a synthetic fixture tree.
# Nothing here touches a network, a BMC, a node or an Azure resource. The core's HTTP layer calls Invoke-WebRequest; each test
# mocks that one cmdlet with $script:FakeBmcResponder, so the test sees every request the code makes (method, path, auth, TLS).
Set-StrictMode -Version Latest

$script:FixtureRoot = [System.IO.Path]::Combine($PSScriptRoot, '..', 'fixtures', 'redfish')

function Use-FakeBmc {
    # Loads a fixture tree into $global:AzlTestBmc (Pester mocks run in module scope and read it through the global).
    param([string]$Vendor = 'dell', [string]$Fixture = 'idrac9-ax760-synthetic')
    $file = [System.IO.Path]::Combine($script:FixtureRoot, $Vendor, $Fixture, 'tree.json')
    $tree = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    $bodies = @{}
    foreach ($k in $tree.Keys) { if ($k.StartsWith('/')) { $bodies[$k] = ($tree[$k] | ConvertTo-Json -Depth 50 -Compress) } }
    $global:AzlTestBmc = @{ Tree = $bodies; Status = @{}; Throw = @{}; ThrowCount = @{}; Calls = [System.Collections.Generic.List[object]]::new(); Meta = $tree['_fixture'] }
}

function Remove-FakeBmc { Remove-Variable -Name AzlTestBmc -Scope Global -ErrorAction SilentlyContinue }

function Set-FakeResource {
    # Replaces (or adds) one resource. -Body is a hashtable/ordered dictionary/pscustomobject.
    param([string]$Path, $Body)
    $global:AzlTestBmc.Tree[$Path] = ($Body | ConvertTo-Json -Depth 50 -Compress)
}

function Get-FakeResource {
    # A resource as a mutable hashtable (to change one property and Set-FakeResource it back).
    param([string]$Path)
    return ($global:AzlTestBmc.Tree[$Path] | ConvertFrom-Json -AsHashtable -Depth 50)
}

function Remove-FakeResource { param([string]$Path) $global:AzlTestBmc.Tree.Remove($Path) | Out-Null }

function Get-FakeCall { param([string]$Method) return @($global:AzlTestBmc.Calls | Where-Object { -not $Method -or $_.Method -eq $Method }) }

# The mock body for Invoke-WebRequest. Statuses: $global:AzlTestBmc.Status[path] = 403 answers that code with a Redfish error body;
# Throw[path] = @{ Message = '...'; Times = 1 } makes the first N requests fail like a timeout.
$script:FakeBmcResponder = {
    $bmc = $global:AzlTestBmc
    $path = ([uri]$Uri).AbsolutePath
    $bound = $PesterBoundParameters
    $has = { param($n) $bound.ContainsKey($n) }
    $bmc.Calls.Add([pscustomobject]@{
            Method = "$($bound['Method'])"; Path = $path; Uri = "$Uri"
            Basic = ((& $has 'Authentication') -and "$($bound['Authentication'])" -eq 'Basic' -and (& $has 'Credential'))
            Token = ((& $has 'Headers') -and $bound['Headers'].ContainsKey('X-Auth-Token')); SkipCertificateCheck = ((& $has 'SkipCertificateCheck') -and [bool]$bound['SkipCertificateCheck'])
            ConnectTimeoutSeconds = $bound['ConnectionTimeoutSeconds']; OperationTimeoutSeconds = $bound['OperationTimeoutSeconds']
            SkipHttpErrorCheck = ((& $has 'SkipHttpErrorCheck') -and [bool]$bound['SkipHttpErrorCheck']); Body = $bound['Body']
        })
    if ($bmc.Throw.ContainsKey($path)) {
        if (-not $bmc.ThrowCount.ContainsKey($path)) { $bmc.ThrowCount[$path] = 0 }
        $bmc.ThrowCount[$path]++
        if ($bmc.ThrowCount[$path] -le $bmc.Throw[$path].Times) { throw $bmc.Throw[$path].Message }
    }
    if ("$($bound['Method'])" -eq 'Post' -and $path -eq '/redfish/v1/SessionService/Sessions') {
        return [pscustomobject]@{ StatusCode = 201; Content = '{}'; Headers = @{ 'X-Auth-Token' = @('doc-session-token-0001'); 'Location' = @('/redfish/v1/SessionService/Sessions/1') } }
    }
    if ("$($bound['Method'])" -eq 'Delete') { return [pscustomobject]@{ StatusCode = 204; Content = ''; Headers = @{} } }
    if ($bmc.Status.ContainsKey($path)) {
        return [pscustomobject]@{ StatusCode = [int]$bmc.Status[$path]; Content = '{"error":{"message":"synthetic answer for the test"}}'; Headers = @{} }
    }
    if ($bmc.Tree.ContainsKey($path)) { return [pscustomobject]@{ StatusCode = 200; Content = $bmc.Tree[$path]; Headers = @{} } }
    return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"message":"The resource was not found"}}'; Headers = @{} }
}
