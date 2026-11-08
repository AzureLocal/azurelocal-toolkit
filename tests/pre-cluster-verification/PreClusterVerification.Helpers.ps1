# Helpers for the engine tests of the pre-cluster verification gate. Dot-sourced inside BeforeAll. Fakes only: no Azure, no domain controller, no node.
# The engine is tested with a FAKE verification module (written into the test drive): its checks answer from a "world" the tests change. The real
# modules have their own tests (Verification.*.Tests.ps1). Every call of the engine that would touch Azure goes through the adapter, a table of fakes.

. ([IO.Path]::Combine($PSScriptRoot, '..', 'arm-deployment', 'ArmDeploymentRun.Helpers.ps1'))

function New-PclWorld {
    <# The state of a pretend environment. Status: category -> the status the fake check of that category returns (default Passed). #>
    [pscustomobject]@{
        Clock = [pscustomobject]@{ Time = [datetime]::Parse('2026-11-08T12:00:00Z', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal); Sleeps = [System.Collections.Generic.List[double]]::new() }
        Providers = @{}; Registered = [System.Collections.Generic.List[string]]::new(); RegisterFails = @()
        Status = @{}; Message = @{}; Secrets = @{}; Calls = [System.Collections.Generic.List[string]]::new(); RemoteCalls = [System.Collections.Generic.List[object]]::new()
        Ec = @{}; EcRemoveFails = @(); EcInstallFails = @()
    }
}

function Get-PclFakeModuleText {
    <# A verification module with one check per category (FK-<category>) and an AZ-004 that reads the 13 providers the way the real one does. #>
    $checks = foreach ($category in 'azure', 'identity', 'nodes', 'network', 'storage', 'readiness') {
        @"
        @{ Id = 'FK-$category'; Category = '$category'; Title = 'A fake $category check'; Source = 'https://learn.microsoft.com/fake?view=azloc-2610'; Blocking = `$true
           Applies = { param(`$Context) `$true }
           Run = {
               param(`$Context)
               `$w = `$Context.Adapters['FakeWorld']
               `$status = if (`$w.Status.ContainsKey('$category')) { `$w.Status['$category'] } else { 'Passed' }
               if (`$status -eq 'Throw') { throw 'the fake exploded' }
               `$message = if (`$w.Message.ContainsKey('$category')) { `$w.Message['$category'] } else { 'ok' }
               @{ Status = `$status; Node = '*'; Message = `$message; Remedy = 'fix the $category thing'; Evidence = 'seen by the fake' }
           } }
"@
    }
    @"
function Get-AzlVerificationAdapterDefault { @{ Fake = @{ Fact = { 'real-fact' } } } }
function Get-AzlVerificationCheckDefinition {
    @(
$($checks -join "`n")
        @{ Id = 'AZ-004'; Category = 'azure'; Title = 'All mandatory resource providers are registered (fake)'; Source = 'x'; Blocking = `$true
           Applies = { param(`$Context) `$true }
           Run = {
               param(`$Context)
               `$missing = @(`$Context.Adapters['FakeWorld'].Providers.GetEnumerator() | Where-Object { `$_.Value -ne 'Registered' } | ForEach-Object { `$_.Key })
               if (`$missing) { @{ Status = 'Failed'; Node = '*'; Message = "Not registered: `$(`$missing -join ', ')"; Remedy = 'Register them' } } else { @{ Status = 'Passed'; Node = '*'; Message = 'all registered' } }
           } }
    )
}
Export-ModuleMember -Function Get-AzlVerificationAdapterDefault, Get-AzlVerificationCheckDefinition
"@
}

function New-PclModuleFolder {
    <# A folder with the fake module (and any other file: name -> text). #>
    param([hashtable]$Files = @{})
    $dir = Join-Path $TestDrive ('ext-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -ItemType Directory -Path $dir
    if (-not $Files.Count) { $Files = @{ 'AzlVerification.Fake.psm1' = (Get-PclFakeModuleText) } }
    foreach ($name in $Files.Keys) { $Files[$name] | Set-Content -LiteralPath (Join-Path $dir $name) -Encoding utf8NoBOM }
    $dir
}

function New-PclAdapter {
    <# The gate's adapter with the members the engine uses replaced by fakes that answer from the world. -Override replaces members. #>
    param([Parameter(Mandatory)]$World, [Parameter(Mandatory)][System.Collections.IDictionary]$Infra, [hashtable]$Override = @{})
    $w = $World; $infra = $Infra
    $a = New-AzlPclAdapter
    # The engine supplies Remote.Invoke itself (both forms) unless a test brings its own through -Override.
    $a.Remove('Remote')
    $a['FakeWorld'] = $w
    $a['Now'] = { $w.Clock.Time }.GetNewClosure()
    $a['Sleep'] = { param($Seconds) $w.Clock.Sleeps.Add([double]$Seconds); $w.Clock.Time = $w.Clock.Time.AddSeconds([double]$Seconds) }.GetNewClosure()
    $a['GetContext'] = { [pscustomobject]@{ SubscriptionId = [string]$infra.azure.subscription_id; TenantId = [string]$infra.azure.tenant_id; Account = 'tester@example.invalid' } }.GetNewClosure()
    $a['GetSubscription'] = { [pscustomobject]@{ State = 'Enabled'; TenantId = [string]$infra.azure.tenant_id; DisplayName = 'lab' } }.GetNewClosure()
    $a['GetProviderState'] = { param($Subscription, $Namespace) $null = $Subscription; if ($w.Providers.ContainsKey($Namespace)) { $w.Providers[$Namespace] } else { 'Registered' } }.GetNewClosure()
    $a['RegisterProvider'] = {
        param($Subscription, $Namespace)
        $null = $Subscription
        $w.Calls.Add("RegisterProvider:$Namespace")
        if ($Namespace -in $w.RegisterFails) { throw "AuthorizationFailed: no permission to register $Namespace" }
        $w.Registered.Add($Namespace); $w.Providers[$Namespace] = 'Registered'
    }.GetNewClosure()
    $a['GetSecret'] = { param($Reference) $w.Calls.Add("GetSecret:$Reference"); if ($w.Secrets.ContainsKey($Reference)) { $w.Secrets[$Reference] } else { 'Sup3r-S3cret-Value!' } }.GetNewClosure()
    foreach ($k in $Override.Keys) { $a[$k] = $Override[$k] }
    $a
}

function New-PclRemoteFake {
    <# Remote.Invoke(node, scriptblock, arguments) that records the call and answers the Environment Checker install and removal from the world. #>
    param([Parameter(Mandatory)]$World)
    $w = $World
    {
        param($Node, $ScriptBlock, $ArgumentList)
        $text = $ScriptBlock.ToString()
        $w.RemoteCalls.Add([pscustomobject]@{ Node = $Node; Kind = $(if ($text -match 'Uninstall-Module') { 'Remove' } elseif ($text -match 'Install-Module') { 'Install' } else { 'Other' }) })
        if ($text -match 'Uninstall-Module') {
            if ($Node -in $w.EcRemoveFails) { throw "uninstall failed on $Node" }
            $w.Ec[$Node] = $false
            return [pscustomobject]@{ present = $false }
        }
        if ($text -match 'Install-Module') {
            if ($Node -in $w.EcInstallFails) { throw "install failed on $Node" }
            $had = [bool]($w.Ec.ContainsKey($Node) -and $w.Ec[$Node])
            $w.Ec[$Node] = $true
            return [pscustomobject]@{ had = $had; present = $true }
        }
    }.GetNewClosure()
}

function Get-PclInfra {
    <# The ARM test infrastructure (Storage Spaces Direct, mgmt+compute and storage intents). #>
    param([ValidateSet('active_directory', 'local_identity')][string]$Identity = 'active_directory', [ValidateSet('s2d', 'san')][string]$Storage = 's2d', [int]$Nodes = 2)
    Get-TestInfra -Identity $Identity -Storage $Storage -Nodes $Nodes
}

function Write-PclInfraFile {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infra, [Parameter(Mandatory)][string]$Directory)
    $null = New-Item -ItemType Directory -Force -Path $Directory
    $path = Join-Path $Directory 'infrastructure.yml'
    ($Infra | ConvertTo-Yaml) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    $path
}

function Invoke-PclRun {
    <# One Verify (or Plan) run with the fake adapter and the fake module. -World and -Infra default to a healthy pair. #>
    param(
        $World, [System.Collections.IDictionary]$Infra, [string]$Mode = 'Verify', [string]$Dir, [string[]]$AcceptSkipped, [switch]$Fix, [string[]]$Category,
        [hashtable]$Override = @{}, [hashtable]$Settings = @{}, [string]$InfraFile, [string[]]$AcknowledgeKnownIssues, [string]$ExtensionFolder,
        [switch]$InstallEnvironmentChecker, [switch]$KeepEnvironmentChecker
    )
    if (-not $Infra) { $Infra = Get-PclInfra }
    if (-not $World) { $World = New-PclWorld }
    if (-not $Dir) { $Dir = Join-Path $TestDrive ('pcl-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
    if (-not $InfraFile) { $InfraFile = Write-PclInfraFile -Infra $Infra -Directory (Join-Path $Dir 'env') }
    $arguments = @{
        Infrastructure = $Infra; InfrastructureFile = $InfraFile; Mode = $Mode; ReportDirectory = (Join-Path $Dir 'live'); OsConfigurationReport = (Get-TestOsReport -Infra $Infra)
        Adapter = (New-PclAdapter -World $World -Infra $Infra -Override $Override); Settings = $Settings
        ExtensionFolder = $(if ($ExtensionFolder) { $ExtensionFolder } else { New-PclModuleFolder })
    }
    if ($AcceptSkipped) { $arguments.AcceptSkipped = $AcceptSkipped }
    if ($Fix) { $arguments.Fix = $true }
    if ($Category) { $arguments.Category = $Category }
    if ($AcknowledgeKnownIssues) { $arguments.AcknowledgeKnownIssues = $AcknowledgeKnownIssues }
    if ($InstallEnvironmentChecker) { $arguments.InstallEnvironmentChecker = $true }
    if ($KeepEnvironmentChecker) { $arguments.KeepEnvironmentChecker = $true }
    $result = Invoke-AzlPreClusterVerification @arguments
    $result | Add-Member -NotePropertyName World -NotePropertyValue $World -Force
    $result | Add-Member -NotePropertyName Infra -NotePropertyValue $Infra -Force
    $result | Add-Member -NotePropertyName InfraFile -NotePropertyValue $InfraFile -Force
    $result
}

function Get-PclCheck($Result, [string]$Id, [string]$Node) {
    @($Result.Checks | Where-Object { $_.Id -eq $Id -and (-not $Node -or $_.Node -eq $Node) })
}

function Read-PclEvent([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
