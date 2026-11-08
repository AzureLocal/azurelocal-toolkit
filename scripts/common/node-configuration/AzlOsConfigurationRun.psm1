#Requires -Version 7.0
<#
.SYNOPSIS
    One OS configuration run for a whole Azure Local instance: every handoff, every node, one plan, one apply, one verification, one report.

.DESCRIPTION
    Invoke-AzureLocalOsConfiguration.ps1 is a thin entry point over Invoke-AzlOsConfiguration. The same function runs standalone and
    inside a pipeline; nothing here knows about a pipeline.

    The run, in order:
      1. Validate the inputs. The infrastructure file; the handoff files merged into one node -> handoff map (a node in two files is an
         error); the method per node (below); the transport; the Azure sign-in; for a machine installed from an ISO the route, the
         credentials and the OS build. Any failure here stops the run with exit code 2 before anything is changed.
      2. Plan for ALL nodes: Set-AzureLocalNodeConfiguration.ps1 once per node, read only. Writes plan-report.json. When
         os_configuration.clear_storage is on it prints exactly which disks on which node would be wiped.
      3. Apply (-Mode Apply), node by node. A node that fails does not stop the others unless -ContinueOnNodeFailure:$false.
      4. Verify: a Plan pass per node that was changed. A node is converged only when this pass finds nothing left to change; the
         status of the commands that did the work doesn't decide it.
      5. report.json (per node: method and evidence, steps, changes, errors, converged, restarted), summary.md, and the exit code.

    Which method? Per node, from the master file and from what is actually there (Resolve-AzlNodeMethod):
      declared   scenario.os_install: iso | simplified
      evidence   (a) a ZTP handoff for the node that says ready, (b) an Arc machine for it that is Connected, (c) the node answers
                 on WinRM at the address in the file.
      Ztp path   Arc Run Command (ARM only). Skips what ZTP guaranteed (OS build, Arc registration, the node's name, BIOS) and verifies
                 it; does the rest.
      Iso path   WinRM with identity.local_admin from a host that reaches the node. Also sets the computer name, checks the OS up
                 front, and registers the machine with Azure Arc.
    Both can be in one cluster. When the declaration and the evidence disagree the evidence wins and a warning names both; when
    there is no evidence the run stops with exit code 2.

    Exit codes: 0 all nodes converged (Plan mode: no node failed and nothing is blocked); 1 a node failed, is blocked or did not
    converge; 2 bad input or nothing reachable.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'infrastructure' 'AzlInfrastructure.psm1'))
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))
Import-Module (Join-Path $PSScriptRoot 'AzlNodePayload.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeTransport.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeConfiguration.psm1')
# HOOK remoting-profiles
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'remoting' 'AzlRemotingProfile.psm1'))
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'remoting' 'AzlRemotingSession.psm1'))
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'remoting' 'AzlRemotingBootstrap.psm1'))

$script:SetScript = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Set-AzureLocalNodeConfiguration.ps1'))
# The order the steps run in (the same as AzlNodeConfiguration): Sbe is last, so a package that can't be delivered never stops the others.
$script:NodeSteps = @('RemoteManagement', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe')
$script:AllSteps = $script:NodeSteps + 'ArcRegistration'
# What ZTP already guaranteed (the computer name, Arc registration) is verified, not redone.
$script:ZtpSteps = @('RemoteManagement', 'Drivers', 'Network', 'Dns', 'Time', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe')
$script:IsoSteps = $script:AllSteps
# Azure Local OS 23H2 is build 25398; anything older cannot be an Azure Local node.
$script:MinimumBuild = 25398

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------

function Write-AzlLine([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }

function Get-AzlInputError([string]$Message) {
    $exception = [System.ArgumentException]::new($Message)
    $exception.Data['AzlInput'] = $true
    return $exception
}

function Test-AzlAzureSignedIn {
    # Seam for tests: is there an Azure sign-in to call ARM with?
    if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) { return $false }
    try { return [bool](Get-AzContext) } catch { return $false }
}

function Test-AzlWinRmPort {
    # Seam for tests: does the address accept a TCP connection on the WinRM port?
    param([Parameter(Mandatory)][string]$Address, [int]$Port = 5985, [int]$TimeoutMilliseconds = 4000)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync($Address, $Port)
        return ($connect.Wait($TimeoutMilliseconds) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-AzlArmToken {
    # Seam for tests: the ARM access token and account of the current Azure sign-in, for registering a machine with Arc.
    $context = Get-AzContext
    $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/').Token
    if ($token -is [securestring]) { $token = $token | ConvertFrom-SecureString -AsPlainText }
    [pscustomobject]@{ Token = [string]$token; AccountId = [string](Get-AzlProp $context 'Account.Id' '') }
}

# ---------------------------------------------------------------------------------------------------------------------
# Handoffs
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlHandoffFile {
    <#
    .SYNOPSIS
        The handoff files named by -HandoffPath: a file, several files, or a directory (every *.ztp-handoff.json in it).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$Path)
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Path | Where-Object { $_ })) {
        if (Test-Path -LiteralPath $entry -PathType Container) {
            $found = @(Get-ChildItem -LiteralPath $entry -Filter '*.ztp-handoff.json' -File | Sort-Object Name)
            if ($found.Count -eq 0) { throw (Get-AzlInputError "No *.ztp-handoff.json file in $entry.") }
            foreach ($f in $found) { $files.Add($f.FullName) }
        }
        elseif (Test-Path -LiteralPath $entry -PathType Leaf) { $files.Add((Resolve-Path -LiteralPath $entry).ProviderPath) }
        else { throw (Get-AzlInputError "Handoff path not found: $entry") }
    }
    return @($files | Select-Object -Unique)
}

function Merge-AzlHandoff {
    <#
    .SYNOPSIS
        Reads every handoff file and merges them into one node -> handoff map. A node name in two files is an error.
    .OUTPUTS
        Files, ByFile (file, handoff as Read-AzlHandoff returns it) and Map (lower-case node name -> File, Entry).
    #>
    [CmdletBinding()]
    param([string[]]$Path)
    $files = @(Get-AzlHandoffFile -Path $Path)
    $byFile = [System.Collections.Generic.List[object]]::new()
    $map = @{}
    foreach ($file in $files) {
        try { $handoff = Read-AzlHandoff -Path $file }
        catch { throw (Get-AzlInputError $_.Exception.Message) }
        $byFile.Add([pscustomobject]@{ File = $file; Handoff = $handoff })
        foreach ($key in @($handoff.Nodes.Keys)) {
            if ($map.ContainsKey($key)) {
                throw (Get-AzlInputError "Node '$key' is in two handoff files: $($map[$key].File) and $file. One node, one handoff: remove the older file or pass the right one.")
            }
            $map[$key] = [pscustomobject]@{ File = $file; Entry = $handoff.Nodes[$key] }
        }
    }
    [pscustomobject]@{ Files = $files; ByFile = $byFile.ToArray(); Map = $map }
}

function Find-AzlMergedHandoff {
    # A node's handoff (File, Handoff, Entry) from a merged set, matched by node name or Arc machine name. $null when none.
    param([object]$Merged, [Parameter(Mandatory)][string]$Name, [string]$ArcMachineName)
    if (-not $Merged) { return $null }
    foreach ($item in $Merged.ByFile) {
        $entry = Get-AzlHandoffNode -Handoff $item.Handoff -Name $Name -ArcMachineName $ArcMachineName
        if ($entry) { return [pscustomobject]@{ File = $item.File; Handoff = $item.Handoff; Entry = $entry } }
    }
    return $null
}

# ---------------------------------------------------------------------------------------------------------------------
# Which method?
# ---------------------------------------------------------------------------------------------------------------------

function Resolve-AzlNodeMethod {
    <#
    .SYNOPSIS
        Decides, for one node, whether it came from ZTP (simplified provisioning) or from an ISO install, and how to reach it.
    .DESCRIPTION
        Pure: it reads only the evidence object it is given (HandoffPresent, HandoffReady, HandoffNote, HandoffContradiction, ArcFound,
        ArcStatus, ArcError, WinRmAnswers, WinRmNote), so a test needs no node and no Azure.

        Auto rules:
          a ready handoff, or (declared simplified and an Arc machine that is Connected)     -> Ztp
              declared iso but a ready handoff exists: Ztp, with a warning naming both
          declared simplified, no ready handoff and no Connected Arc machine                 -> Iso if the node answers on WinRM,
              with a warning naming both; else an error (nothing reachable)
          declared iso (or not set)                                                          -> Iso; an error when the machine isn't
              a Connected Arc machine and doesn't answer on WinRM
          a handoff that names another subscription or resource group than the master file   -> an error (contradictory evidence)
        -Force Ztp needs a handoff or an Arc machine; -Force Iso is taken as given.
        Transport: Ztp -> Arc Run Command; Iso -> Arc Run Command when the machine is a Connected Arc machine, else WinRM.
    .OUTPUTS
        Node, Declared, Method (Ztp|Iso|$null), Source (declared|evidence|forced), Transport, Warnings, Errors, Evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Node,
        [string]$Declared,
        [Parameter(Mandatory)][object]$Evidence,
        [ValidateSet('Auto', 'Ztp', 'Iso')][string]$Force = 'Auto'
    )
    $e = $Evidence
    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $declaredText = if ($Declared) { $Declared } else { 'not set' }
    $arcConnected = [bool]$e.ArcFound -and [string]$e.ArcStatus -eq 'Connected'
    $handoffReady = [bool]$e.HandoffPresent -and [bool]$e.HandoffReady
    $winRm = $e.WinRmAnswers -eq $true
    $method = $null
    $source = 'declared'

    $notes = {
        $parts = @()
        $parts += if ($e.HandoffPresent) { "handoff present but $(if ($e.HandoffNote) { $e.HandoffNote } else { 'not ready' })" } else { 'no handoff' }
        $parts += if ($e.ArcFound) { "Arc machine is $($e.ArcStatus)" } elseif ($e.ArcError) { "Arc lookup failed ($($e.ArcError))" } else { 'no Arc machine' }
        $parts += if ($e.WinRmAnswers -eq $true) { 'answers on WinRM' } elseif ($e.WinRmNote) { $e.WinRmNote } else { 'no answer on WinRM' }
        $parts -join '; '
    }

    if ($e.HandoffContradiction) { $errors.Add("Contradictory evidence for ${Node}: $($e.HandoffContradiction)") }

    if (-not $errors.Count) {
        switch ($Force) {
            'Ztp' {
                if ($e.HandoffPresent -or $e.ArcFound) { $method = 'Ztp'; $source = 'forced' }
                else { $errors.Add("-Method Ztp was forced for $Node, but there is no handoff for it and no Arc machine. The ZTP path needs one of them.") }
            }
            'Iso' { $method = 'Iso'; $source = 'forced' }
            default {
                if ($handoffReady -or ($arcConnected -and $Declared -eq 'simplified')) {
                    $method = 'Ztp'
                    if ($Declared -eq 'iso') {
                        $source = 'evidence'
                        $warnings.Add("$Node is declared os_install 'iso' but a ready ZTP handoff exists for it, so the ZTP path is used. Fix scenario.os_install in the master file if it was provisioned by ZTP.")
                    }
                }
                elseif ($Declared -eq 'simplified') {
                    if ($winRm) {
                        $method = 'Iso'; $source = 'evidence'
                        $warnings.Add("$Node is declared os_install 'simplified' but there is no ready handoff and no Connected Arc machine ($(& $notes)). It answers on WinRM, so the ISO path is used. Check scenario.os_install.")
                    }
                    else { $errors.Add("$Node is declared os_install 'simplified', but there is no evidence of ZTP and nothing reachable: $(& $notes). Pass its handoff file (-HandoffPath), sign in to Azure so its Arc machine is found, or make the node reachable on WinRM.") }
                }
                else {
                    $method = 'Iso'
                    if (-not $arcConnected -and -not $winRm) {
                        $errors.Add("$Node is declared os_install '$declaredText' and nothing reaches it: $(& $notes). The ISO path opens a WinRM session to the address in the file (nodes[].management.ip_address or maintenance_address; -NodeAddress overrides): run from a host that reaches that subnet, or register the machine with Arc first.")
                    }
                }
            }
        }
    }

    $transport = $null
    if ($method -eq 'Ztp') {
        $transport = 'ArcRunCommand'
        if (-not $arcConnected -and $winRm -and -not $e.HandoffPresent) { $transport = 'WinRM' }
    }
    elseif ($method -eq 'Iso') { $transport = if ($arcConnected) { 'ArcRunCommand' } else { 'WinRM' } }

    [pscustomobject]@{
        Node      = $Node
        Declared  = $declaredText
        Method    = $method
        Source    = $source
        Transport = $transport
        Warnings  = $warnings.ToArray()
        Errors    = $errors.ToArray()
        Evidence  = $e
    }
}

function Get-AzlNodeAddressCandidate {
    # The addresses a node may answer on, in the order they are tried: its management address in the file, its maintenance address.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][System.Collections.IDictionary]$Node, [hashtable]$Override)
    $name = [string]$Node['name']
    $list = [System.Collections.Generic.List[string]]::new()
    if ($Override -and $Override.ContainsKey($name) -and $Override[$name]) { $list.Add([string]$Override[$name]) }
    $adapter = Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $Node
    if ($adapter -and $adapter.IpAddress) { $list.Add([string]$adapter.IpAddress) }
    foreach ($candidate in @((Get-AzlProp $Node 'management.ip_address'), (Get-AzlProp $Node 'maintenance_address'))) {
        if ($candidate) { $list.Add([string]$candidate) }
    }
    return @($list | Select-Object -Unique)
}

function Get-AzlLocalAdminCredential {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password was just read from the Key Vault and only ever lives in memory; WinRM needs a PSCredential.')]
    <#
    .SYNOPSIS
        The nodes' local administrator as a credential: the one given, else identity.local_admin with its password read from the
        Key Vault. Never prints the password. Returns Credential (or $null), Source and Error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [pscredential]$Credential)
    if ($Credential) { return [pscustomobject]@{ Credential = $Credential; Source = 'parameter'; Error = '' } }
    $admin = Get-AzlProp $Infrastructure 'identity.local_admin'
    $user = [string](Get-AzlProp $admin 'username' '')
    $reference = [string](Get-AzlProp $admin 'password' '')
    if (-not $user -or -not $reference) { return [pscustomobject]@{ Credential = $null; Source = ''; Error = 'identity.local_admin has no username or password reference in the master file.' } }
    try {
        $secret = Get-AzlSecret -Reference $reference
        $secure = ConvertTo-SecureString -String $secret -AsPlainText -Force
        return [pscustomobject]@{ Credential = [pscredential]::new($user, $secure); Source = "vault ($reference)"; Error = '' }
    }
    catch { return [pscustomobject]@{ Credential = $null; Source = ''; Error = "Can't read the local administrator's password ($reference): $($_.Exception.Message)" } }
}

# HOOK remoting-profiles: which WinRM endpoint of a node answers (HTTPS 5986 or HTTP 5985, by the profile), and the one-time bootstrap
# for a node whose firewall keeps this host out. Without a profile in the context both fall back to the plain 5985 probe.
function Resolve-AzlNodeEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][string]$Address)
    $remoting = if ($Context.PSObject.Properties['Remoting']) { $Context.Remoting } else { $null }
    if (-not $remoting) { return [pscustomobject]@{ Answers = [bool](Test-AzlWinRmPort -Address $Address); UseSsl = $false; Port = 5985; Message = '' } }
    $window = $Context.BootstrapWindow.ContainsKey($Address)
    Resolve-AzlRemotingEndpoint -RemotingProfile $remoting -Address $Address -BootstrapWindow:$window -PortTest { param($a, $p) Test-AzlWinRmPort -Address $a -Port $p }
}

function Invoke-AzlNodeBootstrap {
    <#
    .SYNOPSIS
        When no WinRM endpoint of a node answers: the one-time bootstrap (smb, arc or auto, as os_configuration.remoting says and the
        class allows). Apply mode only; Plan says what it would do. Returns Done (WinRM was opened) and Note.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)][string[]]$Address, [string]$ArcResourceId = '')
    $remoting = if ($Context.PSObject.Properties['Remoting']) { $Context.Remoting } else { $null }
    if (-not $remoting) { return [pscustomobject]@{ Done = $false; Note = '' } }
    $verdict = Test-AzlBootstrapPermitted -Bootstrap $remoting.Bootstrap -Class $remoting.Class -ApprovedBootstrap:$Context.ApprovedBootstrap
    if (-not $verdict.Permitted) { return [pscustomobject]@{ Done = $false; Note = $verdict.Reason } }
    $routes = @($remoting.Bootstrap.Routes) -join ', '
    if ($Context.Mode -ne 'Apply') { return [pscustomobject]@{ Done = $false; Note = "Plan mode changes nothing. In Apply mode the one-time bootstrap ($routes) opens WinRM on $Node first, then the run continues over WinRM." } }
    $thumbprint = if ($remoting.Certificate.Mode -eq 'thumbprint') { $remoting.Certificate.Thumbprint } else { '' }
    if ($remoting.Transport.Scheme -eq 'https' -and -not $remoting.Transport.BootstrapWindowHttp -and -not $thumbprint) {
        return [pscustomobject]@{ Done = $false; Note = "The class $($remoting.Class) never opens HTTP, and the bootstrap can create an HTTPS listener only for a certificate already on the node. Set os_configuration.remoting.certificate to its thumbprint, or open WinRM from the console or the BMC." }
    }
    $admin = $null
    if ($Context.CredentialInfo -and $Context.CredentialInfo.Credential) { $admin = [pscredential]::new('Administrator', $Context.CredentialInfo.Credential.Password) }
    $result = Invoke-AzlWinRmBootstrap -RemotingProfile $remoting -Node $Node -Address $Address[0] -ArcResourceId $ArcResourceId -Credential $admin -ApprovedBootstrap:$Context.ApprovedBootstrap -Thumbprint $thumbprint -ArcWaitSeconds $Context.BootstrapArcWaitSeconds
    $Context.Bootstraps.Add([ordered]@{ node = $Node; ok = $result.Ok; route = $result.Route; attempts = @($result.Attempts | ForEach-Object { [ordered]@{ route = $_.Route; ok = $_.Ok; reason = $_.Reason } }); reason = $result.Reason })
    if ($result.Ok) { $Context.BootstrapWindow[$Address[0]] = $true }
    [pscustomobject]@{ Done = [bool]$result.Ok; Note = $(if ($result.Ok) { "WinRM was opened through the $($result.Route) bootstrap." } else { "The bootstrap failed: $($result.Reason)" }) }
}

function Get-AzlNodeEvidence {
    <#
    .SYNOPSIS
        Looks for the evidence Resolve-AzlNodeMethod needs for one node: its handoff, its Arc machine, whether it answers on WinRM.
        Reads only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    $infra = $Context.Infra
    $name = [string]$Node['name']
    $arcName = Get-AzlArcMachineName -Node $Node
    $found = Find-AzlMergedHandoff -Merged $Context.Handoff -Name $name -ArcMachineName $arcName
    $entry = if ($found) { $found.Entry } else { $null }
    $subscription = [string](Get-AzlProp $infra 'azure.subscription_id' '')
    $resourceGroup = [string](Get-AzlProp $infra 'azure.resource_group' '')

    $ready = $false; $handoffNote = ''; $contradiction = ''
    if ($entry) {
        $ready = [bool](Get-AzlProp $entry 'ready' $false)
        if (-not $ready) { $handoffNote = 'ready is false' }
        $hSub = [string](Get-AzlProp $found.Handoff 'SubscriptionId' '')
        $hRg = [string](Get-AzlProp $found.Handoff 'ResourceGroup' '')
        if ($hSub -and $subscription -and $hSub -ne $subscription) { $contradiction = "the handoff ($(Split-Path -Leaf $found.File)) is for another subscription than azure.subscription_id in the master file." }
        elseif ($hRg -and $resourceGroup -and $hRg -ine $resourceGroup) { $contradiction = "the handoff ($(Split-Path -Leaf $found.File)) is for resource group '$hRg', the master file says azure.resource_group '$resourceGroup'." }
    }

    $arc = $null; $arcError = ''
    if ($Context.AzureSignedIn) {
        try {
            $resourceId = if ($entry) { [string](Get-AzlProp $entry 'arcMachineResourceId' '') } else { '' }
            $arc = Find-AzlArcMachine -ArcMachineName $arcName -SubscriptionId $subscription -ResourceGroup $resourceGroup -ResourceId $resourceId -HostName $name
        }
        catch { $arcError = $_.Exception.Message }
    }
    else { $arcError = 'not signed in to Azure' }
    $arcConnected = $arc -and [string]$arc.Status -eq 'Connected'

    # Does it answer on WinRM? Only worth asking when the other evidence is missing.
    $addresses = @(Get-AzlNodeAddressCandidate -Infrastructure $infra -Node $Node -Override $Context.NodeAddress)
    $winRm = $null; $winRmAddress = ''; $winRmNote = ''; $useSsl = $false
    if (-not ($ready -or $arcConnected) -or $Context.Method -eq 'Iso') {
        if ($addresses.Count -eq 0) { $winRm = $false; $winRmNote = 'no management address in the file to try' }
        else {
            $winRm = $false
            $endpoint = $null
            foreach ($address in $addresses) {
                $endpoint = Resolve-AzlNodeEndpoint -Context $Context -Address $address
                if ($endpoint.Answers) { $winRm = $true; $winRmAddress = $address; $useSsl = [bool]$endpoint.UseSsl; break }
            }
            if (-not $winRm) {
                # HOOK remoting-profiles: probe 5985/5986, then (Apply, the class allows it, the operator chose it) the one-time bootstrap, then probe again.
                $attempt = Invoke-AzlNodeBootstrap -Context $Context -Node $name -Address $addresses -ArcResourceId $(if ($arc) { [string]$arc.ResourceId } else { '' })
                if ($attempt.Done) {
                    foreach ($address in $addresses) {
                        $endpoint = Resolve-AzlNodeEndpoint -Context $Context -Address $address
                        if ($endpoint.Answers) { $winRm = $true; $winRmAddress = $address; $useSsl = [bool]$endpoint.UseSsl; break }
                    }
                }
                if (-not $winRm) {
                    $winRmNote = if ($endpoint -and $endpoint.Message) { "$($endpoint.Message)$(if ($attempt.Note) { " $($attempt.Note)" })" } else { "no answer on TCP 5985 at $($addresses -join ', ')" }
                }
            }
        }
    }
    [pscustomobject]@{
        HandoffPresent       = [bool]$entry
        HandoffReady         = $ready
        HandoffNote          = $handoffNote
        HandoffFile          = $(if ($found) { $found.File } else { '' })
        HandoffContradiction = $contradiction
        ArcFound             = [bool]$arc
        ArcStatus            = $(if ($arc) { [string]$arc.Status } else { '' })
        ArcResourceId        = $(if ($arc) { [string]$arc.ResourceId } else { '' })
        ArcError             = $arcError
        WinRmAnswers         = $winRm
        WinRmAddress         = $winRmAddress
        UseSsl               = $useSsl
        WinRmNote            = $winRmNote
        Addresses            = $addresses
    }
}

function Get-AzlNodeStepList {
    <#
    .SYNOPSIS
        The steps that run on a node: those of its method, limited by -Step. Hostname and Arc registration are ISO-path steps.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Ztp', 'Iso')][string]$Method, [string[]]$Step)
    $list = if ($Method -eq 'Ztp') { $script:ZtpSteps } else { $script:IsoSteps }
    if ($Step) { $list = @($list | Where-Object { $_ -in $Step }) }
    return @($list)
}

# ---------------------------------------------------------------------------------------------------------------------
# Run settings
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlRunSetting {
    <#
    .SYNOPSIS
        Optional run settings: from a JSON file (-ConfigPath), over which a hashtable (-Settings) wins. Keys: retryTries,
        retryDelaySeconds, maxPasses, noRestart, failOnPendingChanges, nodeAddress.
    #>
    [CmdletBinding()]
    param([string]$ConfigPath, [hashtable]$Settings)
    $result = @{}
    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw (Get-AzlInputError "Settings file not found: $ConfigPath") }
        try { $file = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable } catch { throw (Get-AzlInputError "Settings file $ConfigPath isn't valid JSON: $($_.Exception.Message)") }
        foreach ($k in $file.Keys) { $result[$k] = $file[$k] }
    }
    if ($Settings) { foreach ($k in $Settings.Keys) { $result[$k] = $Settings[$k] } }
    $known = @('retryTries', 'retryDelaySeconds', 'maxPasses', 'noRestart', 'failOnPendingChanges', 'nodeAddress', 'approvedBootstrap', 'bootstrapArcWaitSeconds')
    foreach ($k in $result.Keys) { if ($k -notin $known) { throw (Get-AzlInputError "Unknown run setting '$k'. Known: $($known -join ', ').") } }
    return $result
}

# ---------------------------------------------------------------------------------------------------------------------
# One call of the OS configuration script, for one node
# ---------------------------------------------------------------------------------------------------------------------

function Invoke-AzlSetNodeConfiguration {
    <#
    .SYNOPSIS
        Runs Set-AzureLocalNodeConfiguration.ps1 with these parameters and reads back the report it wrote. The one place the script is
        called, so a test replaces it.
    .OUTPUTS
        ExitCode, Error, Unknown ($true when the error was a run that ended in state Unknown), Report (the parsed JSON, or $null).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Parameters)
    $global:LASTEXITCODE = 0
    $errorText = ''; $unknown = $false; $exit = 0
    try {
        $null = & $script:SetScript @Parameters
        $exit = [int]$global:LASTEXITCODE
    }
    catch {
        $errorText = $_.Exception.Message
        $unknown = ($_.Exception.Data['AzlState'] -eq 'Unknown')
        $exit = 1
    }
    $report = $null
    if ($Parameters.ContainsKey('ReportPath') -and (Test-Path -LiteralPath $Parameters.ReportPath -PathType Leaf)) {
        try { $report = Get-Content -LiteralPath $Parameters.ReportPath -Raw | ConvertFrom-Json -Depth 20 } catch { $report = $null }
    }
    [pscustomobject]@{ ExitCode = $exit; Error = $errorText; Unknown = $unknown; Report = $report }
}

function Invoke-AzlNodeRun {
    <#
    .SYNOPSIS
        One Plan or Apply call of the OS configuration script for one node, with that node's method, transport, steps and address.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][ValidateSet('Plan', 'Apply', 'Verify')][string]$Phase
    )
    $steps = @($Record.setSteps)
    if ($steps.Count -eq 0) { return [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Entry = $null; Skipped = $true } }
    $reportFile = Join-Path $Context.NodeReportDirectory ("{0}-{1}.json" -f $Record.name, $Phase.ToLowerInvariant())
    $parameters = @{
        InfrastructureFile = $Context.InfrastructureFile
        Node               = @($Record.name)
        Transport          = $Record.transport
        Step               = $steps
        ReportPath         = $reportFile
        RetryTries         = $Context.RetryTries
        RetryDelaySeconds  = $Context.RetryDelaySeconds
        MaxPasses          = $Context.MaxPasses
    }
    if ($Record.handoffFile) { $parameters.HandoffFile = $Record.handoffFile }
    if ($Context.ClearStorage) { $parameters.ClearStorage = $true }
    if ($Context.NoRestart) { $parameters.NoRestart = $true }
    if ($Context.SkipValidation) { $parameters.SkipValidation = $true }
    if ($Phase -eq 'Apply') { $parameters.Execute = $true }
    if ($Record.transport -eq 'WinRM') {
        $parameters.Credential = $Context.CredentialInfo.Credential
        if ($Record.address) { $parameters.NodeAddress = @{ $Record.name = $Record.address } }
        if ($Record.useSsl) { $parameters.UseSsl = $true }
    }
    elseif ($Context.CredentialInfo.Credential -and 'Sbe' -in $steps -and [string](Get-AzlProp $Context.Infra 'hardware.sbe.delivery' 'skip') -eq 'winrm_copy') {
        # The node is reached over Arc Run Command, which can't carry a file. hardware.sbe.delivery winrm_copy copies the SBE package
        # over WinRM, so the node script gets the local administrator for that one step (the other steps stay on Arc).
        $parameters.Credential = $Context.CredentialInfo.Credential
        if ($Record.address) { $parameters.NodeAddress = @{ $Record.name = $Record.address } }
    }
    $run = Invoke-AzlSetNodeConfiguration -Parameters $parameters
    $entry = $null
    if ($run.Report) { $entry = @($run.Report.nodes | Where-Object { $_.name -ieq $Record.name } | Select-Object -First 1)[0] }
    [pscustomobject]@{ ExitCode = $run.ExitCode; Error = $run.Error; Unknown = $run.Unknown; Entry = $entry; Skipped = $false }
}

# ---------------------------------------------------------------------------------------------------------------------
# Arc registration (ISO path)
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlArcRegistrationItem {
    <#
    .SYNOPSIS
        The Arc registration step as a plan item. Read only: the Arc machine is looked up in Azure; the node isn't touched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Record, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    $infra = $Context.Infra
    $resourceGroup = [string](Get-AzlProp $infra 'azure.resource_group' '')
    $current = 'unknown'; $action = 'Info'; $note = ''
    $arc = $null
    try {
        $arc = Find-AzlArcMachine -ArcMachineName (Get-AzlArcMachineName -Node $Node) -SubscriptionId ([string](Get-AzlProp $infra 'azure.subscription_id' '')) -ResourceGroup $resourceGroup -ResourceId ([string]$Record.evidence.ArcResourceId) -HostName $Record.name
    }
    catch { $note = "Arc lookup failed: $($_.Exception.Message)" }
    if ($arc) {
        $current = "$($arc.Name) is $($arc.Status)"
        if ($arc.Status -eq 'Connected') { $action = 'Ok' } else { $action = 'Change'; $note = 'The Arc machine exists but is not Connected; registration runs again.' }
    }
    elseif (-not $note) { $current = 'not registered'; $action = 'Change'; $note = "Registers the machine into $resourceGroup with Invoke-AzStackHciArcInitialization over WinRM (an ARM token from this run's Azure sign-in)." }
    [pscustomobject]@{ Node = $Record.name; Step = 'ArcRegistration'; Item = 'Azure Arc registration'; Current = $current; Desired = "Connected in $resourceGroup"; Action = $action; Note = $note }
}

function Invoke-AzlArcRegistration {
    <#
    .SYNOPSIS
        Registers an ISO-installed machine with Azure Arc: Invoke-AzStackHciArcInitialization on the node, over WinRM, with the ARM
        token of this run's Azure sign-in (passed as a secret, never written down). Then waits for the Arc machine to be Connected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Record, [Parameter(Mandatory)][System.Collections.IDictionary]$Node, [int]$WaitMinutes = 20)
    $infra = $Context.Infra
    $subscription = [string](Get-AzlProp $infra 'azure.subscription_id' '')
    $resourceGroup = [string](Get-AzlProp $infra 'azure.resource_group' '')
    $token = Get-AzlArmToken
    $gateway = ''
    if ((Get-AzlProp $infra 'scenario.outbound_path' '') -in 'arc_gateway', 'proxy_arc_gateway') {
        $gw = Get-AzlProp $infra 'networking.outbound.arc_gateway'
        $gwGroup = [string](Get-AzlProp $gw 'resource_group' $resourceGroup)
        if (Get-AzlProp $gw 'name') { $gateway = "/subscriptions/$subscription/resourceGroups/$gwGroup/providers/Microsoft.HybridCompute/gateways/$(Get-AzlProp $gw 'name')" }
    }
    $parameters = @{
        subscriptionId = $subscription; resourceGroup = $resourceGroup; tenantId = [string](Get-AzlProp $infra 'azure.tenant_id' '')
        region = [string](Get-AzlProp $infra 'azure.location' ''); accountId = $token.AccountId
        cloud = $(if ((Get-AzlProp $infra 'scenario.cloud' 'public') -eq 'government') { 'AzureUSGovernment' } else { 'AzureCloud' })
        arcGatewayId = $gateway
    }
    $transport = New-AzlWinRmTransport -Address @{ $Record.name = $Record.address } -Credential $Context.CredentialInfo.Credential
    $null = Invoke-AzlNodeScript -Transport $transport -Node $Record.name -Script (Get-AzlNodePayload -Name ArcRegistration) -Parameters $parameters -Secrets @{ armToken = $token.Token } -TimeoutSeconds 7200 -Tries 1
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    do {
        $arc = $null
        try { $arc = Find-AzlArcMachine -ArcMachineName (Get-AzlArcMachineName -Node $Node) -SubscriptionId $subscription -ResourceGroup $resourceGroup -HostName $Record.name } catch { Write-Verbose "Arc lookup: $($_.Exception.Message)" }
        if ($arc -and $arc.Status -eq 'Connected') { return $arc }
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)
    throw "$($Record.name) ran the Arc initialization but its Arc machine is not Connected in $resourceGroup after $WaitMinutes minutes."
}

# ---------------------------------------------------------------------------------------------------------------------
# Preconditions of the ISO path
# ---------------------------------------------------------------------------------------------------------------------

function Test-AzlIsoPrecondition {
    <#
    .SYNOPSIS
        Before anything is changed on a machine reached over WinRM: the route, the credentials, and the OS (Azure Stack HCI OS or
        Windows Server at build 25398 or later). Returns a list of precise problems (empty when fine) and what it saw.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    $problems = [System.Collections.Generic.List[string]]::new()
    $seen = $null
    $name = $Record.name
    if (-not $Record.address) { $problems.Add("${name}: no address to open a WinRM session to. Put nodes[].management.ip_address or maintenance_address in the file, or pass -NodeAddress."); return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $null } }
    if (-not $Context.CredentialInfo.Credential) {
        $problems.Add("${name}: no local administrator credential. $($Context.CredentialInfo.Error) Pass -Credential, or make identity.local_admin.password readable (Key Vault get on the secret).")
        return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $null }
    }
    $endpoint = Resolve-AzlNodeEndpoint -Context $Context -Address $Record.address
    if (-not $endpoint.Answers) {
        if ($endpoint.Message) { $problems.Add("${name}: $($endpoint.Message)") }
        else { $problems.Add("${name}: no route to $($Record.address):5985. The ISO path opens a WinRM session from this host, so this host (or the self-hosted runner) must reach the nodes' management subnet and WinRM must be enabled on the node.") }
        return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $null }
    }
    $Record.useSsl = [bool]$endpoint.UseSsl
    try {
        $transport = New-AzlWinRmTransport -Address @{ $name = $Record.address } -Credential $Context.CredentialInfo.Credential -UseSsl:$endpoint.UseSsl
        $seen = Invoke-AzlNodeScript -Transport $transport -Node $name -Script (Get-AzlNodePayload -Name Preflight) -Tries 1 -TimeoutSeconds 300
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'denied|logon failure|authentication|credentials|unauthorized') { $problems.Add("${name}: the local administrator '$($Context.CredentialInfo.Credential.UserName)' was refused on $($Record.address) ($message). Check identity.local_admin (username and the vault secret), or pass -Credential.") }
        else { $problems.Add("${name}: can't run a command on $($Record.address) over WinRM: $message") }
        return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $null }
    }
    $caption = [string](Get-AzlProp $seen 'caption' '')
    $build = [int](Get-AzlProp $seen 'build' 0)
    if ($caption -notmatch 'Azure Stack HCI|Azure Local|Windows Server') { $problems.Add("${name}: the OS is '$caption'. Azure Local needs the Azure Stack HCI OS (or Windows Server for the early steps).") }
    elseif ($build -lt $script:MinimumBuild) { $problems.Add("${name}: the OS build is $build ($caption). Azure Local needs build $script:MinimumBuild or later (Azure Stack HCI OS 23H2).") }
    return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $seen }
}

# ---------------------------------------------------------------------------------------------------------------------
# Plan, apply, verify
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlPlanItem {
    param([object]$Item, [string]$Node)
    [pscustomobject]@{
        Node = $Node; Step = [string](Get-AzlProp $Item 'step' (Get-AzlProp $Item 'Step' '')); Item = [string](Get-AzlProp $Item 'item' (Get-AzlProp $Item 'Item' ''))
        Current = [string](Get-AzlProp $Item 'current' (Get-AzlProp $Item 'Current' '')); Desired = [string](Get-AzlProp $Item 'desired' (Get-AzlProp $Item 'Desired' ''))
        Action = [string](Get-AzlProp $Item 'action' (Get-AzlProp $Item 'Action' '')); Note = [string](Get-AzlProp $Item 'note' (Get-AzlProp $Item 'Note' ''))
    }
}

function Merge-AzlRunResult {
    # Folds one Plan or Verify call into the node's record. Returns $true when the node could be read.
    param([System.Collections.IDictionary]$Record, [object]$Run, [string]$Phase)
    $Record.phases[$Phase] = [ordered]@{ exitCode = $Run.ExitCode; error = $Run.Error; skipped = $Run.Skipped }
    if ($Run.Skipped) { $Record.plan = @(); return $true }
    if (-not $Run.Entry) {
        $Record.errors += "$Phase of $($Record.name) failed: $(if ($Run.Error) { $Run.Error } else { "the script wrote no report (exit code $($Run.ExitCode))." })"
        return $false
    }
    $Record.plan = @(@($Run.Entry.plan) | ForEach-Object { ConvertTo-AzlPlanItem -Item $_ -Node $Record.name })
    $Record.ports = @($Run.Entry.ports)
    $Record.sanDisks = @($Run.Entry.sanDisks)
    $Record.hostname = [string](Get-AzlProp $Run.Entry 'hostname' '')
    $Record.osVersion = [string](Get-AzlProp $Run.Entry 'osVersion' '')
    # hardware.sbe.delivery skip: the node is not failed, but the package is not on it and the OEM drivers wait, so say it once.
    if ($Phase -eq 'Plan' -and @($Record.plan | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Info' -and $_.Note -match 'NOT DELIVERED' }).Count) {
        $Record.warnings += "$($Record.name): the SBE package is NOT DELIVERED (hardware.sbe.delivery is skip or not set), so the OEM network drivers are skipped. Set hardware.sbe.delivery to node_pull or winrm_copy, or put the package in C:\SBE yourself."
    }
    return $true
}

function Merge-AzlRecordCount {
    param([System.Collections.IDictionary]$Record)
    $Record.pendingChanges = @($Record.plan | Where-Object { $_.Action -eq 'Change' }).Count
    $Record.blocked = @($Record.plan | Where-Object { $_.Action -eq 'Blocked' }).Count
    $Record.wipe = @($Record.plan | Where-Object { $_.Step -eq 'ClearStorage' -and $_.Action -eq 'Change' } | ForEach-Object {
            [ordered]@{ node = $Record.name; disks = $_.Current; note = $_.Note }
        })
}

function Test-AzlZtpVerification {
    # What ZTP guaranteed, checked rather than redone: the node's name, its Arc machine, the handoff.
    param([System.Collections.IDictionary]$Record)
    $checks = @()
    $e = $Record.evidence
    $checks += [ordered]@{ check = 'handoff ready'; ok = [bool]($e.HandoffPresent -and $e.HandoffReady); detail = $(if ($e.HandoffPresent) { "ready=$($e.HandoffReady)" } else { 'no handoff passed; verified through the Arc machine' }) }
    $checks[-1].ok = $checks[-1].ok -or $e.ArcStatus -eq 'Connected'
    $checks += [ordered]@{ check = 'Arc machine connected'; ok = ($e.ArcStatus -eq 'Connected'); detail = $(if ($e.ArcFound) { $e.ArcStatus } else { 'not found' }) }
    if ($Record.hostname) {
        $checks += [ordered]@{ check = 'computer name'; ok = ($Record.hostname -ieq $Record.name); detail = "node reports '$($Record.hostname)', file says '$($Record.name)'; ZTP names the machine, so it is not renamed here" }
    }
    return $checks
}

function Invoke-AzlPlanPhase {
    param([object]$Context, [System.Collections.IDictionary]$Record, [System.Collections.IDictionary]$Node, [string]$Phase = 'Plan')
    $run = Invoke-AzlNodeRun -Context $Context -Record $Record -Phase $Phase
    $readable = Merge-AzlRunResult -Record $Record -Run $run -Phase $Phase
    if (-not $readable) { $Record.status = 'failed'; return }
    if ($Record.method -eq 'Iso' -and 'ArcRegistration' -in $Record.steps) {
        $item = Get-AzlArcRegistrationItem -Context $Context -Record $Record -Node $Node
        $Record.plan = @($Record.plan) + $item
        if ($item.Action -eq 'Ok') { $Record.evidence.ArcStatus = 'Connected'; $Record.evidence.ArcFound = $true }
    }
    if ($Record.method -eq 'Ztp') {
        $Record.verification = @(Test-AzlZtpVerification -Record $Record)
        foreach ($v in $Record.verification | Where-Object { -not $_.ok }) { $Record.errors += "Verification failed for $($Record.name): $($v.check) ($($v.detail))." }
    }
    Merge-AzlRecordCount -Record $Record
    if ($Phase -eq 'Plan') { $Record.status = 'planned' }
}

function Resolve-AzlWinRmAddress {
    # A node's address can change while it is configured (the installer's address becomes the static one): find where it answers now.
    param([object]$Context, [System.Collections.IDictionary]$Record, [System.Collections.IDictionary]$Node)
    if ($Record.transport -ne 'WinRM') { return }
    foreach ($address in @(Get-AzlNodeAddressCandidate -Infrastructure $Context.Infra -Node $Node -Override $Context.NodeAddress)) {
        $endpoint = Resolve-AzlNodeEndpoint -Context $Context -Address $address
        if ($endpoint.Answers) { $Record.address = $address; $Record.useSsl = [bool]$endpoint.UseSsl; return }
    }
}

function Invoke-AzlApplyPhase {
    param([object]$Context, [System.Collections.IDictionary]$Record, [System.Collections.IDictionary]$Node)
    Resolve-AzlWinRmAddress -Context $Context -Record $Record -Node $Node
    $arcPending = @($Record.plan | Where-Object { $_.Step -eq 'ArcRegistration' -and $_.Action -eq 'Change' }).Count -gt 0
    $setPending = @($Record.plan | Where-Object { $_.Step -ne 'ArcRegistration' -and $_.Action -eq 'Change' }).Count -gt 0
    if ($setPending -or $Record.blocked -gt 0) {
        $run = Invoke-AzlNodeRun -Context $Context -Record $Record -Phase Apply
        $Record.phases['Apply'] = [ordered]@{ exitCode = $run.ExitCode; error = $run.Error; unknown = $run.Unknown }
        if ($run.Entry) {
            $Record.changes += @(@($run.Entry.changes) | ForEach-Object { [ordered]@{ pass = $_.Pass; id = $_.Id; status = $_.Status; detail = $_.Detail } })
            if ($run.Entry.restarted) { $Record.restarted = $true }
        }
        if ($run.Error) {
            if ($run.Unknown) { $Record.warnings += "The Apply of $($Record.name) ended in state Unknown after $($Context.RetryTries) tries; convergence is decided by the verification pass, not by the command." }
            else { $Record.errors += "Apply of $($Record.name) failed: $($run.Error)" }
        }
    }
    if ($arcPending) {
        try {
            Resolve-AzlWinRmAddress -Context $Context -Record $Record -Node $Node
            $arc = Invoke-AzlArcRegistration -Context $Context -Record $Record -Node $Node
            $Record.changes += [ordered]@{ pass = 1; id = 'ArcRegistration'; status = 'changed'; detail = "registered as $($arc.Name) ($($arc.Status))" }
            $Record.evidence.ArcFound = $true; $Record.evidence.ArcStatus = 'Connected'; $Record.evidence.ArcResourceId = $arc.ResourceId
        }
        catch {
            $Record.changes += [ordered]@{ pass = 1; id = 'ArcRegistration'; status = 'failed'; detail = $_.Exception.Message }
            $Record.errors += "Arc registration of $($Record.name) failed: $($_.Exception.Message)"
        }
    }
    $Record.status = 'applied'
}

function Get-AzlWipeList {
    <#
    .SYNOPSIS
        The disks that will be wiped: one entry per node with a ClearStorage change in its plan, from the plan and nothing else.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Record)
    @($Record | Where-Object { @($_.wipe).Count } | ForEach-Object { foreach ($w in $_.wipe) { [pscustomobject]@{ Node = $w.node; Disks = $w.disks; Note = $w.note } } })
}

function Format-AzlWipeList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$WipeList, [Parameter(Mandatory)][bool]$ClearStorage, [Parameter(Mandatory)][string]$Mode, [string]$Source = '')
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $ClearStorage) { $lines.Add('Storage wipe: off (os_configuration.clear_storage is false). Leftover storage is reported, nothing is wiped.'); return ($lines -join [Environment]::NewLine) }
    $verb = if ($Mode -eq 'Apply') { 'WILL BE WIPED NOW' } else { 'WOULD BE WIPED if you apply' }
    $lines.Add("STORAGE WIPE ($Source). Local disks that $verb. Boot, system, SAN (FC, iSCSI) and USB disks are never touched.")
    if (@($WipeList).Count -eq 0) { $lines.Add('  Nothing to wipe: no leftover local storage was found on any node.') }
    foreach ($w in $WipeList) { $lines.Add("  $($w.Node): $($w.Disks)") }
    return ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlOsConfigurationExitCode {
    <#
    .SYNOPSIS
        0 all converged (Plan: nothing failed or blocked), 1 a node failed, is blocked or didn't converge, 2 bad input.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record, [string[]]$ClusterProblem = @(), [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan', [switch]$FailOnPendingChanges, [switch]$InputError)
    if ($InputError) { return 2 }
    if (@($ClusterProblem).Count) { return 1 }
    foreach ($r in $Record) {
        if ($r.status -in 'failed', 'skipped') { return 1 }
        if (@($r.errors).Count -and -not $r.converged) { return 1 }
        if ($r.blocked -gt 0) { return 1 }
        if ($Mode -eq 'Apply' -and -not $r.converged) { return 1 }
        if ($Mode -eq 'Plan' -and $FailOnPendingChanges -and $r.pendingChanges -gt 0) { return 1 }
    }
    return 0
}

function Format-AzlOsConfigurationSummary {
    <#
    .SYNOPSIS
        The human summary: a table with one row per node. -Markdown for a job summary.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record, [string]$Mode = 'Plan', [switch]$Markdown, [int]$ExitCode = 0)
    $rows = foreach ($r in $Record) {
        [pscustomobject][ordered]@{
            Node      = $r.name
            Method    = "$($r.method) ($($r.methodSource))"
            Transport = $r.transport
            Changes   = $(if ($Mode -eq 'Apply') { @($r.changes | Where-Object { $_.status -eq 'changed' }).Count } else { "$($r.pendingChanges) planned" })
            Converged = $(if ($Mode -eq 'Apply') { $r.converged } else { if ($r.pendingChanges -eq 0 -and $r.blocked -eq 0 -and $r.status -ne 'failed') { 'yes (nothing to change)' } else { 'no' } })
            Restarted = $r.restarted
            Errors    = @($r.errors).Count
        }
    }
    if ($Markdown) {
        $lines = @("| Node | Method | Transport | Changes | Converged | Restarted | Errors |", '| --- | --- | --- | --- | --- | --- | --- |')
        foreach ($row in $rows) { $lines += "| $($row.Node) | $($row.Method) | $($row.Transport) | $($row.Changes) | $($row.Converged) | $($row.Restarted) | $($row.Errors) |" }
        $lines += ''; $lines += "Exit code: $ExitCode"
        return ($lines -join [Environment]::NewLine)
    }
    return (($rows | Format-Table -AutoSize -Wrap | Out-String -Width 200).TrimEnd() + [Environment]::NewLine + "Exit code: $ExitCode")
}

function ConvertTo-AzlNodeReport {
    param([System.Collections.IDictionary]$Record)
    [ordered]@{
        name           = $Record.name
        method         = [ordered]@{ declared = $Record.declared; resolved = $Record.method; source = $Record.methodSource; transport = $Record.transport; warnings = @($Record.methodWarnings) }
        evidence       = [ordered]@{
            handoff = [ordered]@{ present = $Record.evidence.HandoffPresent; ready = $Record.evidence.HandoffReady; file = $Record.evidence.HandoffFile }
            arc     = [ordered]@{ found = $Record.evidence.ArcFound; status = $Record.evidence.ArcStatus; error = $Record.evidence.ArcError }
            winrm   = [ordered]@{ answers = $Record.evidence.WinRmAnswers; address = $Record.evidence.WinRmAddress; note = $Record.evidence.WinRmNote }
        }
        address        = $Record.address
        steps          = @($Record.steps)
        status         = $Record.status
        planned        = [ordered]@{ changes = $Record.pendingChanges; blocked = $Record.blocked }
        plan           = @($Record.plan | ForEach-Object { [ordered]@{ step = $_.Step; item = $_.Item; current = $_.Current; desired = $_.Desired; action = $_.Action; note = $_.Note } })
        changes        = @($Record.changes)
        verification   = @($Record.verification)
        wipe           = @($Record.wipe)
        errors         = @($Record.errors)
        warnings       = @($Record.warnings)
        converged      = [bool]$Record.converged
        restarted      = [bool]$Record.restarted
        phases         = $Record.phases
    }
}

function Get-AzlRemotingReportBlock {
    param([Parameter(Mandatory)][object]$Context)
    $block = ConvertTo-AzlRemotingReport -RemotingProfile $Context.Remoting
    $block['trustedHostsPolicy'] = if ($Context.TrustedHosts) { [ordered]@{ mode = $Context.TrustedHosts.Mode; previous = $Context.TrustedHosts.Previous; applied = $Context.TrustedHosts.Applied; changed = $Context.TrustedHosts.Changed; restoreAfterRun = $Context.TrustedHosts.Restore; restored = [bool]($Context.TrustedHosts.PSObject.Properties['Restored'] -and $Context.TrustedHosts.Restored) } } else { $null }
    $block['bootstraps'] = @($Context.Bootstraps)
    $block['events'] = @(Get-AzlRemotingEvent | ForEach-Object { [ordered]@{ timestamp = $_.timestamp; node = $_.node; state = $_.state; level = $_.level; evidence = $_.evidence } })
    return $block
}

function Write-AzlOsConfigurationReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record, [Parameter(Mandatory)][string]$FileName, [string[]]$ClusterProblem = @(), [int]$ExitCode = 0, [string]$Message = '')
    $report = [ordered]@{
        schemaVersion  = 1
        generatedUtc   = [datetime]::UtcNow.ToString('o')
        mode           = $Context.Mode
        cluster        = $Context.ClusterName
        infrastructure = $Context.InfrastructureFile
        clearStorage   = [ordered]@{ enabled = [bool]$Context.ClearStorage; source = $Context.ClearStorageSource }
        handoffFiles   = @($Context.HandoffFiles)
        exitCode       = $ExitCode
        message        = $Message
        clusterProblems = @($ClusterProblem)
        # HOOK remoting-profiles: the effective profile, the TrustedHosts policy and its restore, the bootstraps, the profile's events
        remoting       = $(if ($Context.PSObject.Properties['Remoting'] -and $Context.Remoting) { Get-AzlRemotingReportBlock -Context $Context } else { $null })
        wipeList       = @(Get-AzlWipeList -Record $Record | ForEach-Object { [ordered]@{ node = $_.Node; disks = $_.Disks } })
        nodes          = @($Record | ForEach-Object { ConvertTo-AzlNodeReport -Record $_ })
    }
    $path = Join-Path $Context.ReportDirectory $FileName
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

# ---------------------------------------------------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlNodeRecord {
    param([System.Collections.IDictionary]$Node, [object]$Resolution, [string[]]$Step)
    $method = $Resolution.Method
    $steps = if ($method) { @(Get-AzlNodeStepList -Method $method -Step $Step) } else { @() }
    $evidence = $Resolution.Evidence
    [ordered]@{
        name = [string]$Node['name']; declared = $Resolution.Declared; method = $method; methodSource = $Resolution.Source; methodWarnings = @($Resolution.Warnings)
        transport = $Resolution.Transport; address = $(if ($Resolution.Transport -eq 'WinRM') { $evidence.WinRmAddress } else { '' }); useSsl = [bool]($evidence.PSObject.Properties['UseSsl'] -and $evidence.UseSsl)
        handoffFile = $evidence.HandoffFile; evidence = $evidence
        steps = $steps; setSteps = @($steps | Where-Object { $_ -in $script:NodeSteps })
        status = 'pending'; plan = @(); changes = @(); errors = @(); warnings = @(); verification = @(); wipe = @()
        ports = @(); sanDisks = @(); hostname = ''; osVersion = ''
        pendingChanges = 0; blocked = 0; converged = $false; restarted = $false; phases = [ordered]@{}
    }
}

function Test-AzlSanConsistency {
    # Every node must see the same SAN disks (the same UniqueIds).
    param([object[]]$Record)
    $sets = @{}
    foreach ($r in $Record) {
        if ($r.status -in 'failed', 'skipped' -or @($r.sanDisks).Count -eq 0) { continue }
        $sets[$r.name] = @($r.sanDisks | ForEach-Object { $_.uid } | Sort-Object) -join ','
    }
    if (@($sets.Values | Select-Object -Unique).Count -gt 1) { return @("The nodes don't see the same SAN disks (UniqueIds differ): $(($sets.GetEnumerator() | ForEach-Object { "$($_.Key)=[$($_.Value)]" }) -join '; ')") }
    return @()
}

function Invoke-AzlOsConfiguration {
    <#
    .SYNOPSIS
        The whole OS configuration run. See the module description. Returns Context, Records, ExitCode, Report paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InfrastructureFile,
        [string[]]$HandoffPath,
        [string[]]$Node,
        [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan',
        [ValidateSet('RemoteManagement', 'Sbe', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'ArcRegistration')][string[]]$Step,
        [string]$ReportDirectory,
        [string]$ConfigPath,
        [hashtable]$Settings,
        [bool]$ContinueOnNodeFailure = $true,
        [ValidateSet('Auto', 'ArcRunCommand', 'WinRM')][string]$Transport = 'Auto',
        [ValidateSet('Auto', 'Ztp', 'Iso')][string]$Method = 'Auto',
        [pscredential]$Credential,
        [hashtable]$NodeAddress,
        [switch]$ClearStorage,
        [switch]$FailOnPendingChanges,
        [switch]$SkipValidation,
        # HOOK remoting-profiles: the pipeline approval of the one-time bootstrap (production and dmz need it), and a TrustedHosts store for a test.
        [switch]$ApprovedBootstrap,
        [object]$TrustedHostsStore
    )
    $records = @()
    $context = $null
    $trustedSession = $null
    $trustedStore = if ($TrustedHostsStore) { $TrustedHostsStore } else { Get-AzlTrustedHostsStore }
    try {
        # ---- 1. validate the inputs
        if (-not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { throw (Get-AzlInputError "Infrastructure file not found: $InfrastructureFile") }
        $run = Get-AzlRunSetting -ConfigPath $ConfigPath -Settings $Settings
        try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation:$SkipValidation }
        catch { throw (Get-AzlInputError $_.Exception.Message) }
        $infraNodes = @($infra.nodes)
        if ($Node) { foreach ($n in $Node) { if ($n -notin @($infraNodes | ForEach-Object { $_['name'] })) { throw (Get-AzlInputError "Node $n isn't in $InfrastructureFile. Nodes there: $(@($infraNodes | ForEach-Object { $_['name'] }) -join ', ').") } } }
        $nodes = @($infraNodes | Where-Object { -not $Node -or $_['name'] -in $Node })
        if ($nodes.Count -eq 0) { throw (Get-AzlInputError "No nodes in $InfrastructureFile.") }
        $merged = if ($HandoffPath) { Merge-AzlHandoff -Path $HandoffPath } else { $null }

        $reportDir = if ($ReportDirectory) { $ReportDirectory } else { Join-Path ([IO.Path]::GetTempPath()) 'azl-osconfig' }
        $null = New-Item -ItemType Directory -Force -Path $reportDir
        $nodeReportDir = Join-Path $reportDir 'node-reports'
        $null = New-Item -ItemType Directory -Force -Path $nodeReportDir

        $clearFromFile = (Get-AzlProp $infra 'os_configuration.clear_storage' $false) -eq $true
        $clear = $ClearStorage.IsPresent -or $clearFromFile
        $clearSource = if ($ClearStorage.IsPresent) { '-ClearStorage switch' } elseif ($clearFromFile) { 'os_configuration.clear_storage in the master file' } else { 'off' }
        $tries = if ($run.ContainsKey('retryTries')) { [int]$run.retryTries } else { 3 }
        $delays = if ($run.ContainsKey('retryDelaySeconds')) { @($run.retryDelaySeconds | ForEach-Object { [int]$_ }) } else { @(15, 45, 120) }
        $addressOverride = @{}
        if ($run.ContainsKey('nodeAddress')) { foreach ($k in $run.nodeAddress.Keys) { $addressOverride[$k] = $run.nodeAddress[$k] } }
        if ($NodeAddress) { foreach ($k in $NodeAddress.Keys) { $addressOverride[$k] = $NodeAddress[$k] } }
        $failOnPending = $FailOnPendingChanges.IsPresent -or ($run.ContainsKey('failOnPendingChanges') -and $run.failOnPendingChanges -eq $true)

        $context = [pscustomobject]@{
            Infra = $infra; InfrastructureFile = $InfrastructureFile; Mode = $Mode; Handoff = $merged; HandoffFiles = $(if ($merged) { $merged.Files } else { @() })
            ClearStorage = $clear; ClearStorageSource = $clearSource; ReportDirectory = $reportDir; NodeReportDirectory = $nodeReportDir
            ClusterName = [string](Get-AzlProp $infra 'cluster.name' 'cluster'); AzureSignedIn = (Test-AzlAzureSignedIn)
            NodeAddress = $addressOverride; Method = $Method; CredentialInfo = $null
            RetryTries = $tries; RetryDelaySeconds = $delays; MaxPasses = $(if ($run.ContainsKey('maxPasses')) { [int]$run.maxPasses } else { 3 })
            NoRestart = ($run.ContainsKey('noRestart') -and $run.noRestart -eq $true); SkipValidation = $SkipValidation.IsPresent
            Remoting = $null; ApprovedBootstrap = $false; BootstrapWindow = @{}; Bootstraps = [System.Collections.Generic.List[object]]::new(); TrustedHosts = $null
            BootstrapArcWaitSeconds = $(if ($run.ContainsKey('bootstrapArcWaitSeconds')) { [int]$run.bootstrapArcWaitSeconds } else { 180 })
        }
        $context.CredentialInfo = Get-AzlLocalAdminCredential -Infrastructure $infra -Credential $Credential

        # HOOK remoting-profiles: the effective remote management profile, printed and recorded before anything changes. A bad class
        # (or any error in the profile) is bad input: exit code 2 with a message that names the allowed values.
        $override = @{}
        if ($ApprovedBootstrap) { $override.approved_bootstrap = $true; $override.approved_bootstrap_source = 'parameter' }
        elseif ($run.ContainsKey('approvedBootstrap') -and $run.approvedBootstrap -eq $true) { $override.approved_bootstrap = $true; $override.approved_bootstrap_source = 'settings' }
        $remotingProfile = Resolve-AzlRemotingProfile -Infrastructure $infra -Override $override
        Set-AzlRemotingEventSink -Path (Join-Path $reportDir 'remoting-events.jsonl') -Reset -Confirm:$false
        $context.Remoting = $remotingProfile
        $context.ApprovedBootstrap = $ApprovedBootstrap.IsPresent -or ($run.ContainsKey('approvedBootstrap') -and $run.approvedBootstrap -eq $true)
        Send-AzlRemotingProfileEvent -RemotingProfile $remotingProfile
        foreach ($line in @(Format-AzlRemotingProfile -RemotingProfile $remotingProfile)) { Write-AzlLine $line }
        Assert-AzlRemotingProfile -RemotingProfile $remotingProfile
        # The one place the orchestrator's TrustedHosts changes; restored below (and in the finally block if the run is cut short).
        $trustedAddresses = @(@($remotingProfile.TrustedHosts.Addresses) + @($addressOverride.Values | ForEach-Object { [string]$_ }) | Where-Object { $_ } | Select-Object -Unique)
        $trustedSession = Set-AzlTrustedHostsPolicy -RemotingProfile $remotingProfile -Address $trustedAddresses -Store $trustedStore -Confirm:$false
        $context.TrustedHosts = $trustedSession
        $declared = [string](Get-AzlProp $infra 'scenario.os_install' '')

        Write-AzlLine "OS configuration: $($context.ClusterName), mode $Mode, $($nodes.Count) node(s), report directory $reportDir"
        if ($merged) { Write-AzlLine "Handoffs: $($merged.Files.Count) file(s) merged, $($merged.Map.Count) node(s)." }
        if ($merged) {
            foreach ($key in $merged.Map.Keys) {
                if (-not (@($infraNodes | Where-Object { ([string]$_['name']) -ieq $key -or (Get-AzlArcMachineName -Node $_) -ieq $key }).Count)) { Write-Warning "Handoff $($merged.Map[$key].File) names node '$key', which isn't in the infrastructure file." }
            }
        }

        $records = [System.Collections.Generic.List[object]]::new()
        $inputProblems = [System.Collections.Generic.List[string]]::new()
        $nodeByName = @{}
        foreach ($n in $nodes) {
            $nodeByName[[string]$n['name']] = $n
            $evidence = Get-AzlNodeEvidence -Context $context -Node $n
            $resolution = Resolve-AzlNodeMethod -Node ([string]$n['name']) -Declared $declared -Evidence $evidence -Force $Method
            foreach ($e in $resolution.Errors) { $inputProblems.Add($e) }
            foreach ($w in $resolution.Warnings) { Write-Warning $w }
            if ($Transport -ne 'Auto' -and $resolution.Method) { $resolution.Transport = $Transport }
            $record = Get-AzlNodeRecord -Node $n -Resolution $resolution -Step $Step
            $records.Add($record)
            if ($resolution.Method) { Write-AzlLine "  $($record.name): method $($record.method) ($($record.methodSource); declared $declared), transport $($record.transport)$(if ($record.address) { ", address $($record.address)" })." }
        }
        if ($inputProblems.Count) { throw (Get-AzlInputError (($inputProblems | ForEach-Object { "- $_" }) -join [Environment]::NewLine)) }

        # transport needs
        $arcNodes = @($records | Where-Object { $_.transport -eq 'ArcRunCommand' })
        if ($arcNodes.Count -and -not $context.AzureSignedIn) { throw (Get-AzlInputError "Azure Arc Run Command needs an Azure sign-in (Connect-AzAccount, or azure/login in a pipeline) for: $(($arcNodes | ForEach-Object { $_.name }) -join ', ').") }
        $needsArcStep = @($records | Where-Object { $_.method -eq 'Iso' -and 'ArcRegistration' -in $_.steps })
        if ($needsArcStep.Count -and -not $context.AzureSignedIn) { throw (Get-AzlInputError "Arc registration needs an Azure sign-in to look up the Arc machine and get an ARM token: $(($needsArcStep | ForEach-Object { $_.name }) -join ', ').") }

        # ISO path: route, credentials, OS
        $pre = [System.Collections.Generic.List[string]]::new()
        foreach ($r in @($records | Where-Object { $_.method -eq 'Iso' -and $_.transport -eq 'WinRM' })) {
            $check = Test-AzlIsoPrecondition -Context $context -Record $r
            foreach ($p in $check.Problems) { $pre.Add($p) }
            if ($check.Seen) { $r.warnings += "OS: $(Get-AzlProp $check.Seen 'caption' '') build $(Get-AzlProp $check.Seen 'build' '')" }
        }
        if ($pre.Count) { throw (Get-AzlInputError (($pre | ForEach-Object { "- $_" }) -join [Environment]::NewLine)) }

        # ---- 2. plan for ALL nodes
        Write-AzlLine ''
        Write-AzlLine '== Plan: all nodes (read only)'
        $stop = $false
        foreach ($r in $records) {
            if ($stop) { $r.status = 'skipped'; $r.errors += 'Skipped: an earlier node failed and -ContinueOnNodeFailure is off.'; continue }
            Write-AzlLine "-- $($r.name)"
            try { Invoke-AzlPlanPhase -Context $context -Record $r -Node $nodeByName[$r.name] }
            catch { $r.status = 'failed'; $r.errors += "Plan of $($r.name) failed: $($_.Exception.Message)" }
            if ($r.status -eq 'failed' -and -not $ContinueOnNodeFailure) { $stop = $true }
        }
        $clusterProblems = @(Test-AzlSanConsistency -Record $records)
        foreach ($r in $records) { $r.converged = ($r.status -eq 'planned' -and $r.pendingChanges -eq 0 -and $r.blocked -eq 0 -and @($r.errors).Count -eq 0) }
        $wipe = @(Get-AzlWipeList -Record $records)
        $null = Write-AzlOsConfigurationReport -Context $context -Record $records -FileName 'plan-report.json' -ClusterProblem $clusterProblems
        $wipeText = Format-AzlWipeList -WipeList $wipe -ClearStorage $clear -Mode $Mode -Source $clearSource
        Set-Content -LiteralPath (Join-Path $reportDir 'wipe-list.txt') -Value $wipeText -Encoding utf8NoBOM
        Write-AzlLine ''
        foreach ($r in $records) {
            $show = @($r.plan | Where-Object { $_.Action -ne 'Ok' })
            if ($show.Count) { Write-AzlLine (Format-AzlPlan -Plan $show) }
            foreach ($e in $r.errors) { Write-Warning $e }
        }
        Write-AzlLine $wipeText

        # ---- 3. apply
        if ($Mode -eq 'Apply') {
            Write-AzlLine ''
            Write-AzlLine '== Apply: node by node'
            $stop = $false
            foreach ($r in $records) {
                if ($r.status -eq 'skipped') { continue }
                if ($stop) { $r.status = 'skipped'; $r.errors += 'Skipped: an earlier node failed and -ContinueOnNodeFailure is off.'; continue }
                if ($r.status -eq 'failed') { if (-not $ContinueOnNodeFailure) { $stop = $true }; continue }
                if ($r.pendingChanges -eq 0 -and $r.blocked -eq 0) { Write-AzlLine "-- $($r.name): nothing to change"; $r.converged = (@($r.errors).Count -eq 0); continue }
                Write-AzlLine "-- $($r.name): applying $($r.pendingChanges) change(s)"
                try { Invoke-AzlApplyPhase -Context $context -Record $r -Node $nodeByName[$r.name] }
                catch { $r.errors += "Apply of $($r.name) failed: $($_.Exception.Message)" }
                if (@($r.errors).Count -and -not $ContinueOnNodeFailure) { $stop = $true }
            }

            # ---- 4. verify: a Plan pass proves convergence
            Write-AzlLine ''
            Write-AzlLine '== Verify: a Plan pass per changed node'
            foreach ($r in $records) {
                if ($r.status -ne 'applied') { continue }
                Write-AzlLine "-- $($r.name)"
                $before = @($r.errors).Count
                Resolve-AzlWinRmAddress -Context $context -Record $r -Node $nodeByName[$r.name]
                $r.verification = @()
                try { Invoke-AzlPlanPhase -Context $context -Record $r -Node $nodeByName[$r.name] -Phase Verify }
                catch { $r.status = 'failed'; $r.errors += "Verification of $($r.name) failed: $($_.Exception.Message)" }
                $verifyErrors = @(@($r.errors) | Select-Object -Skip $before)
                $r.converged = ($r.status -ne 'failed' -and $r.pendingChanges -eq 0 -and $r.blocked -eq 0 -and $verifyErrors.Count -eq 0)
                if ($r.converged -and $before -gt 0) { $r.warnings += "Recovered: the verification pass found nothing left to change although a step reported an error (errors kept in the report)." }
                if (-not $r.converged -and $r.status -ne 'failed') { $r.status = 'applied' }
                Write-AzlLine "   $($r.name): $(if ($r.converged) { 'converged' } else { "NOT converged ($($r.pendingChanges) change(s) left, $($r.blocked) blocked)" })"
            }
            $clusterProblems = @(Test-AzlSanConsistency -Record $records)
        }
        foreach ($p in $clusterProblems) { Write-Warning $p }

        # ---- 5. report
        # HOOK remoting-profiles: TrustedHosts goes back to what it was before the report is written (it says so).
        if ($trustedSession) { $null = Restore-AzlTrustedHostsPolicy -Session $trustedSession -Store $trustedStore -Confirm:$false }
        $exit = Get-AzlOsConfigurationExitCode -Record $records -ClusterProblem $clusterProblems -Mode $Mode -FailOnPendingChanges:$failOnPending
        $reportPath = Write-AzlOsConfigurationReport -Context $context -Record $records -FileName 'report.json' -ClusterProblem $clusterProblems -ExitCode $exit
        $summary = Format-AzlOsConfigurationSummary -Record $records -Mode $Mode -ExitCode $exit
        $markdown = (Format-AzlOsConfigurationSummary -Record $records -Mode $Mode -ExitCode $exit -Markdown) + [Environment]::NewLine + [Environment]::NewLine + '```' + [Environment]::NewLine + $wipeText + [Environment]::NewLine + '```'
        Set-Content -LiteralPath (Join-Path $reportDir 'summary.md') -Value $markdown -Encoding utf8NoBOM
        Write-AzlLine ''
        Write-AzlLine $summary
        Write-AzlLine "Report: $reportPath"
        return [pscustomobject]@{ ExitCode = $exit; Records = $records.ToArray(); ReportPath = $reportPath; ReportDirectory = $reportDir; Summary = $summary; WipeList = $wipe; Message = '' }
    }
    catch {
        $isInput = [bool]$_.Exception.Data['AzlInput']
        if ($trustedSession) { try { $null = Restore-AzlTrustedHostsPolicy -Session $trustedSession -Store $trustedStore -Confirm:$false } catch { Write-Warning "TrustedHosts was not restored: $($_.Exception.Message)" } }
        $message = $_.Exception.Message
        Write-AzlLine ''
        Write-AzlLine "$(if ($isInput) { 'BAD INPUT' } else { 'FAILED' }): $message"
        if ($context) {
            try {
                $null = Write-AzlOsConfigurationReport -Context $context -Record @($records) -FileName 'report.json' -ExitCode $(if ($isInput) { 2 } else { 1 }) -Message $message
            }
            catch { Write-Verbose "Couldn't write the report: $($_.Exception.Message)" }
        }
        return [pscustomobject]@{ ExitCode = $(if ($isInput) { 2 } else { 1 }); Records = @($records); ReportPath = ''; ReportDirectory = ''; Summary = ''; WipeList = @(); Message = $message }
    }
    finally {
        # HOOK remoting-profiles: never leave a TrustedHosts entry (above all a wildcard) behind, whatever happened.
        if ($trustedSession) { try { $null = Restore-AzlTrustedHostsPolicy -Session $trustedSession -Store $trustedStore -Confirm:$false } catch { Write-Warning "TrustedHosts was not restored: $($_.Exception.Message)" } }
    }
}

Export-ModuleMember -Function Get-AzlHandoffFile, Merge-AzlHandoff, Find-AzlMergedHandoff, Resolve-AzlNodeMethod, Get-AzlNodeStepList, Get-AzlNodeEvidence, Get-AzlRunSetting, Get-AzlWipeList, Format-AzlWipeList, Get-AzlOsConfigurationExitCode, Format-AzlOsConfigurationSummary, Test-AzlIsoPrecondition, Invoke-AzlOsConfiguration
