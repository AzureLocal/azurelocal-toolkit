#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-cluster verification, SBE (SB-): the OEM Solution Builder Extension package is downloaded, available on a share the automation can read,
    and it is the RIGHT package for the hardware and the solution version.

.DESCRIPTION
    Owner requirement (9 Nov): the SBE package must be downloaded and available on a share the automation can pull it from. It is needed for the
    first cluster update anyway (a vendor whose SBE has no download connector for the cluster reports AdditionalContentRequired; Dell's download is
    login gated), and optionally at build time. The toolkit still never side-loads it at build time unless the file says so (hardware.sbe.delivery,
    default skip); these checks are about the package being there and being the right one.

      SB-001  the package is required and its source is configured (hardware.sbe.source_path), or the file says not_applicable with a reason
      SB-002  the source is reachable from this host with the credential of the file / Key Vault (read only)
      SB-003  the three expected files are there: SBE_Discovery_<Vendor>.xml, SBE_<Vendor>_<Family>_<Version>.xml and .zip
      SB-004  the files agree: names, discovery entry, sizes above zero, the SHA-256 against the manifest (and the hash the file pins)
      SB-005  the family matches the hardware model of EVERY node (the discovery manifest's SupportedModels, nothing is hard coded)
      SB-006  the SBE version is validated for the target solution version (the discovery manifest's validated solution versions)

    Every check that cannot read what it needs ends Skipped (blocking unless accepted), never Passed. A package that is present but wrong
    (the 17G family on 16G nodes) is Failed with the exact reason.

    The checks sit in the category nodes (the vendor baseline of the machines). They read a share, not the nodes; only SB-005 also reads the model each
    node reports, through the same one-call snapshot the NODES checks use. Contract with the engine: see AzlVerification.NodeCommon.psm1. Read only.

    Share reader (Adapters.Sbe): List(request), ReadText(request, name), GetHash(request, name). Tests replace them with fakes.
    Credential (Adapters.KeyVault.GetSecret): hardware.sbe.source_password is a keyvault:// reference; the secret is kept in memory only.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'AzlArmDeploymentRun.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'sbe', 'AzlSbePackage.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AzlVerification.NodeCommon.psm1'))

$script:SbeDoc = 'https://learn.microsoft.com/en-us/azure/azure-local/update/solution-builder-extension?view=azloc-2610'
$script:ImportDoc = 'https://learn.microsoft.com/en-us/azure/azure-local/update/update-via-powershell-23h2?view=azloc-2610#step-3-import-and-rediscover-updates'

function Protect-AzlVerSbeText {
    # Takes the share password out of a text, so an error from a library can never carry it.
    param([AllowNull()][string]$Text, [string[]]$Secret = @())
    if ($null -eq $Text) { return '' }
    foreach ($s in $Secret) { if ($s -and $s.Length -ge 4) { $Text = $Text.Replace($s, '***') } }
    return $Text
}

function Get-AzlVerSbeSetup {
    <#
    .SYNOPSIS
        What every SB- check starts from, worked out once per run (cached in the context): the requirement, the source, the share request (with the
        credential read from Key Vault) and the one read of the share. Stage says how far it got.
    .OUTPUTS
        Requirement, Source, Verify ($true when the share is to be read), Stage (NotApplicable | NoSource | BadCredential | NoCredential | NoReader | Unreachable | Listed
        | NotChecked), Reason, Scan, Request, Secret, Models (the models the file declares).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $cache = Get-AzlVerCache $Context
    if ($cache.ContainsKey('SbeSetup')) { return $cache['SbeSetup'] }
    $infra = Get-AzlVerInfra $Context
    $requirement = Get-AzlSbeRequirement -Infrastructure $infra
    $source = Get-AzlSbeSource -Infrastructure $infra
    $model = ([string](Get-AzlProp $infra 'hardware.model' '')).Trim()
    $setup = [ordered]@{ Requirement = $requirement; Source = $source; Verify = $false; Stage = 'NotChecked'; Reason = ''; Scan = $null; Request = $null; Secret = @(); Models = @($model | Where-Object { $_ }) }
    $state = $requirement.State
    $verify = ($state -eq 'Required') -or ($state -in 'NotRequiredByCatalog', 'Unknown' -and $source.Path)
    $setup.Verify = [bool]$verify
    if ($state -in 'NotApplicable') { $setup.Stage = 'NotApplicable'; $setup.Reason = $requirement.Reason }
    elseif (-not $verify) { $setup.Stage = 'NotChecked'; $setup.Reason = $requirement.Reason }
    elseif (-not $source.Path) { $setup.Stage = 'NoSource'; $setup.Reason = 'hardware.sbe.source_path is empty' }
    else {
        $password = ''
        if ($source.Username -and -not $source.PasswordRef) { $setup.Stage = 'BadCredential'; $setup.Reason = 'hardware.sbe.source_username is set but hardware.sbe.source_password (a keyvault:// reference) is not' }
        elseif ($source.PasswordRef -and -not $source.Username) { $setup.Stage = 'BadCredential'; $setup.Reason = 'hardware.sbe.source_password is set but hardware.sbe.source_username is not' }
        elseif ($source.PasswordRef) {
            $get = Get-AzlVerAdapterMember -Context $Context -Group 'KeyVault' -Name 'GetSecret'
            if (-not $get) { $setup.Stage = 'NoCredential'; $setup.Reason = 'there is no Key Vault adapter here, so the share credential cannot be read' }
            else {
                try { $password = [string](& $get $source.PasswordRef) }
                catch { $setup.Stage = 'NoCredential'; $setup.Reason = "the share credential $($source.PasswordRef) could not be read from Key Vault: $($_.Exception.Message)" }
                if ($password) { $setup.Secret = @($password) }
                elseif ($setup.Stage -ne 'NoCredential') { $setup.Stage = 'NoCredential'; $setup.Reason = "the share credential $($source.PasswordRef) is empty in Key Vault" }
            }
        }
        if ($setup.Stage -eq 'NotChecked') {
            $list = Get-AzlVerAdapterMember -Context $Context -Group 'Sbe' -Name 'List'
            $text = Get-AzlVerAdapterMember -Context $Context -Group 'Sbe' -Name 'ReadText'
            if (-not $list -or -not $text) { $setup.Stage = 'NoReader'; $setup.Reason = 'the adapter has no Sbe.List / Sbe.ReadText here' }
            else {
                $setup.Request = @{ Path = $source.Path; Username = $source.Username; Password = $password }
                $reader = @{ List = $list; ReadText = $text }
                try {
                    $setup.Scan = Get-AzlSbeSourceScan -Request $setup.Request -Reader $reader -Family $source.Family -Version $source.Version -Publisher $source.Publisher -Model $setup.Models
                    $setup.Stage = $setup.Scan.Stage
                    if ($setup.Stage -ne 'Listed') { $setup.Reason = Protect-AzlVerSbeText -Text ([string]$setup.Scan.List.Error) -Secret $setup.Secret }
                }
                catch { $setup.Stage = 'Unreachable'; $setup.Reason = Protect-AzlVerSbeText -Text $_.Exception.Message -Secret $setup.Secret }
            }
        }
    }
    $cache['SbeSetup'] = [pscustomobject]$setup
    return $cache['SbeSetup']
}

function Get-AzlVerSbeBlock {
    <#
    .SYNOPSIS
        The result a check returns when the share was not read (or the check does not apply): NotApplicable, or Skipped with the reason that stopped it. $null when the share was listed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Setup, [Parameter(Mandatory)][string]$Upstream)
    switch ($Setup.Stage) {
        'Listed' { return $null }
        'NotApplicable' { return (New-AzlVerResult NotApplicable "The file declares the SBE package not applicable: $($Setup.Reason)" -Evidence 'hardware.sbe.requirement=not_applicable') }
        'NotChecked' {
            if ($Setup.Requirement.State -eq 'NotRequiredByCatalog') { return (New-AzlVerResult NotApplicable "The package is not required by default for this vendor and no source is configured: $($Setup.Reason)") }
            return (New-AzlVerResult Skipped "Not checked: $($Setup.Reason)." 'Set hardware.sbe.requirement (required or not_applicable with hardware.sbe.not_applicable_reason).')
        }
        'NoSource' { return (New-AzlVerResult Skipped "Not checked, there is no source: $($Setup.Reason) ($Upstream)." 'Set hardware.sbe.source_path to the share or folder that holds the downloaded package.') }
        default { return (New-AzlVerResult Skipped "Not checked, the source could not be read ($Upstream): $($Setup.Reason)." 'Make the source readable from this host (SB-002), then run the verification again.') }
    }
}

function Get-AzlVerSbeFile {
    # The names of the files a package needs, for a message.
    param($Package, [string]$Discovery = 'SBE_Discovery_<Vendor>.xml')
    "$Discovery, $($Package.PayloadName) and $($Package.ZipName)"
}

function Get-AzlVerSbeDownloadHint {
    # The vendor-specific route in one sentence (vendor catalog), for the remedies.
    param($Setup)
    $p = $Setup.Requirement.Profile
    if ($p -and $p.Acquisition -eq 'manual_download') { return "Download the three files from your hardware vendor ($($p.Vendor): a manual download, usually behind a support login) into the source folder." }
    if ($p -and $p.Acquisition -eq 'automatic_download') { return "$($p.Vendor)'s cluster can download the package itself; if you still want it on the share, download the three files from the vendor into the source folder." }
    return 'Download the three files from your hardware vendor into the source folder.'
}

function Get-AzlVerSbeBestForModel {
    # A sentence naming the package(s) of the manifest that list a model and are validated with the target solution.
    param($Entry, [string]$Model, [string]$Solution)
    $with = @(Find-AzlSbeEntryForModel -Entry $Entry -Model $Model -Solution $Solution)
    $any = @(Find-AzlSbeEntryForModel -Entry $Entry -Model $Model)
    if ($with.Count) { return "The manifest lists $($with[0].Name) (family $($with[0].Family), $($with[0].Version)) for $Model$(if ($Solution) { ", validated with solution $Solution" })." }
    if ($any.Count) { return "The manifest lists $($any[0].Name) (family $($any[0].Family), $($any[0].Version)) for $Model, but not validated with solution $Solution." }
    return "No package of the manifest lists $Model."
}

function Get-AzlVerificationAdapterDefault {
    <#
    .SYNOPSIS
        The read only share reader of the SB- checks: Sbe.List, Sbe.ReadText, Sbe.GetHash (Get-AzlSbeDefaultReader).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $reader = Get-AzlSbeDefaultReader
    @{ Sbe = @{ List = $reader.List; ReadText = $reader.ReadText; GetHash = $reader.GetHash } }
}

function Get-AzlVerificationCheckDefinition {
    <#
    .SYNOPSIS
        The check definitions of the SBE package (SB-001 to SB-006), category nodes.
    #>
    [CmdletBinding()]
    param()
    $defs = [System.Collections.Generic.List[object]]::new()
    $reads = 'the SBE source (a share or folder, read only)'
    $source = "$($script:SbeDoc); $($script:ImportDoc)"

    $defs.Add((New-AzlVerDefinition -Id 'SB-001' -Category nodes -Reads $reads -Source $source `
                -Title 'The SBE package is required and its source (a share the automation can read) is configured, or the file declares it not applicable with a reason' -Run {
                param($Context)
                $s = Get-AzlVerSbeSetup $Context
                $r = $s.Requirement
                switch ($r.State) {
                    'NotApplicable' { return (New-AzlVerResult NotApplicable "The file declares the SBE package not applicable: $($r.Reason)." -Evidence 'hardware.sbe.requirement=not_applicable') }
                    'NotApplicableNoReason' { return (New-AzlVerResult Failed "hardware.sbe.requirement is not_applicable but hardware.sbe.not_applicable_reason is empty. A package is declared not applicable only with the reason (no SBE exists for this hardware, or the cluster downloads it with the vendor credential)." 'Set hardware.sbe.not_applicable_reason, or set hardware.sbe.requirement to required and hardware.sbe.source_path.') }
                    'Invalid' { return (New-AzlVerResult Failed "$($r.Reason)." 'Set hardware.sbe.requirement to required or not_applicable.') }
                    'NotRequiredByCatalog' {
                        if (-not $s.Source.Path) { return (New-AzlVerResult Warning "$($r.Reason), so no package source is required. This is the vendor catalog's default, not a statement in the file. You need the package for the first update only if the cluster does not download it." 'State it in the file: hardware.sbe.requirement not_applicable with hardware.sbe.not_applicable_reason, or required with hardware.sbe.source_path.') }
                    }
                    'Unknown' {
                        if (-not $s.Source.Path) { return (New-AzlVerResult Skipped "Whether the SBE package is required cannot be decided: $($r.Reason)." 'Set hardware.sbe.requirement to required (with hardware.sbe.source_path) or to not_applicable (with hardware.sbe.not_applicable_reason).') }
                    }
                }
                if (-not $s.Source.Path) {
                    return (New-AzlVerResult Failed "The SBE package is required ($($r.Reason)) but no source is configured: hardware.sbe.source_path is empty. The package must be downloaded and available on a share the automation can read, for the build and for the first cluster update." "Download the vendor's SBE package (discovery manifest, payload manifest and payload zip) and set hardware.sbe.source_path to the share or folder that holds them. $(Get-AzlVerSbeDownloadHint $s) If your hardware has no SBE, or the cluster downloads it with the vendor credential, set hardware.sbe.requirement not_applicable and hardware.sbe.not_applicable_reason.")
                }
                $cred = if ($s.Source.Username) { "read as $($s.Source.Username) with the password from $($s.Source.PasswordRef)" } else { 'read with the account running the automation' }
                New-AzlVerResult Passed "The SBE package source is configured: $($s.Source.Path) ($($s.Source.From); $cred)." -Evidence "requirement=$($r.State) from $($r.From)"
            }))

    $defs.Add((New-AzlVerDefinition -Id 'SB-002' -Category nodes -Reads $reads -Source $source `
                -Title 'The SBE source is reachable from this host with the configured credential (read only)' -Run {
                param($Context)
                $s = Get-AzlVerSbeSetup $Context
                if ($s.Stage -in 'NotApplicable', 'NotChecked', 'NoSource') { return (Get-AzlVerSbeBlock $s 'SB-001') }
                if ($s.Stage -eq 'Listed') {
                    $n = @($s.Scan.List.Files).Count
                    return (New-AzlVerResult Passed "The SBE source $($s.Source.Path) is readable from this host: $n file(s) listed." -Evidence "files=$n")
                }
                if ($s.Stage -eq 'Unreachable') {
                    $kind = [string]$s.Scan.List.ErrorKind
                    $fix = switch ($kind) {
                        'NotFound' { 'Check hardware.sbe.source_path: the server answered but the folder does not exist.' }
                        'AccessDenied' { 'The credential was refused or has no read permission: check hardware.sbe.source_username and the Key Vault secret, and give the account Read on the share and the folder.' }
                        default { 'Make the share reachable from the host that runs the automation (name resolution, TCP 445, firewall), or run the verification from a host that reaches it.' }
                    }
                    $msg = "The SBE source $($s.Source.Path) could not be read from this host ($kind): $($s.Reason)"
                    if ($kind -in 'NotFound', 'AccessDenied') { return (New-AzlVerResult Failed $msg $fix -Evidence "errorKind=$kind") }
                    return (New-AzlVerResult Skipped "$msg. The package was not checked from here." $fix -Evidence "errorKind=$kind")
                }
                New-AzlVerResult Skipped "The SBE source $($s.Source.Path) was not read: $($s.Reason)." 'Fix the credential or the adapter, then run the verification again.'
            }))

    $defs.Add((New-AzlVerDefinition -Id 'SB-003' -Category nodes -Reads $reads -Source $source `
                -Title 'The three package files are there: SBE_Discovery_<Vendor>.xml, SBE_<Vendor>_<Family>_<Version>.xml and SBE_<Vendor>_<Family>_<Version>.zip' -Run {
                param($Context)
                $s = Get-AzlVerSbeSetup $Context
                $block = Get-AzlVerSbeBlock $s 'SB-002'
                if ($block) { return $block }
                $scan = $s.Scan
                $hint = Get-AzlVerSbeDownloadHint $s
                $problems = [System.Collections.Generic.List[string]]::new()
                if ($scan.Discovery.Count -eq 0) { $problems.Add('no SBE_Discovery_<Vendor>.xml (the discovery manifest)') }
                elseif ($scan.Discovery.Count -gt 1) { $problems.Add("$($scan.Discovery.Count) discovery manifests ($($scan.Discovery -join ', ')), keep the one of your vendor") }
                $zipBases = @($scan.Zips | ForEach-Object { $_ -replace '\.zip$', '' }); $xmlBases = @($scan.PayloadXmls | ForEach-Object { $_ -replace '\.xml$', '' })
                if ($scan.Selected) {
                    $p = $scan.Selected
                    if (-not $p.PayloadPresent) { $problems.Add("no payload manifest $($p.PayloadName)") }
                    if (-not $p.ZipPresent) { $problems.Add("no payload $($p.ZipName)") }
                }
                elseif ($scan.Ambiguous.Count) { $problems.Add("more than one package on the source ($($scan.Ambiguous -join ', ')) and none can be chosen: set hardware.sbe.family and hardware.sbe.version, or keep one package per source") }
                elseif ($zipBases.Count -or $xmlBases.Count) { $problems.Add("the packages on the source cannot be used: $($scan.SelectionNote)") }
                else {
                    $models = @($s.Models)
                    $named = if ($scan.Entries.Count -and $models.Count) { Get-AzlVerSbeBestForModel -Entry $scan.Entries -Model $models[0] -Solution (Get-AzlVerTargetSolution $Context) } else { '' }
                    $problems.Add("no package: neither SBE_<Vendor>_<Family>_<Version>.xml nor .zip is on the source$(if ($named) { ". $named" })")
                }
                if ($zipBases.Count -and $xmlBases.Count -and @($zipBases | Where-Object { $_ -notin $xmlBases }).Count -and @($xmlBases | Where-Object { $_ -notin $zipBases }).Count) {
                    $problems.Add("the payload manifest and the payload do not belong together: manifest $($xmlBases -join ', ') versus payload $($zipBases -join ', ')")
                }
                if ($problems.Count) {
                    return (New-AzlVerResult Failed ("The SBE source $($s.Source.Path) is missing files: " + ($problems -join '; ') + '. Microsoft: the package is always three files with the same name stem (discovery manifest, payload manifest, payload).') "$hint Expected names: SBE_Discovery_<Vendor>.xml, SBE_<Vendor>_<Family>_<Version>.xml, SBE_<Vendor>_<Family>_<Version>.zip." -Evidence "discovery=$($scan.Discovery -join ',') zips=$($scan.Zips -join ',') xmls=$($scan.PayloadXmls -join ',')")
                }
                New-AzlVerResult Passed "The package is complete: $(Get-AzlVerSbeFile $scan.Selected $scan.DiscoveryName) ($($scan.SelectionNote))." -Evidence "package=$($scan.Selected.BaseName)"
            }))

    $defs.Add((New-AzlVerDefinition -Id 'SB-004' -Category nodes -Reads $reads -Source $source `
                -Title 'The package files agree: names match the discovery entry, sizes above zero, SHA-256 matches the manifest (and the hash pinned in the file)' -Run {
                param($Context)
                $s = Get-AzlVerSbeSetup $Context
                $block = Get-AzlVerSbeBlock $s 'SB-002'
                if ($block) { return $block }
                $scan = $s.Scan
                $p = $scan.Selected
                if (-not $p -or -not $p.ZipPresent -or -not $p.PayloadPresent -or $scan.Discovery.Count -ne 1) { return (New-AzlVerResult Skipped 'The package is not complete (SB-003), so its files were not compared with each other.' 'Fix SB-003 first.') }
                if ($scan.DiscoveryError) { return (New-AzlVerResult Skipped "The discovery manifest could not be read, so the package was not compared with it: $($scan.DiscoveryError)" 'Download SBE_Discovery_<Vendor>.xml again from the vendor.') }
                $problems = [System.Collections.Generic.List[string]]::new()
                $entry = $scan.Entry
                if (-not $entry) { $problems.Add("$($p.BaseName) is not listed in $($scan.DiscoveryName) (UpdateName): the discovery manifest and the payload come from different downloads") }
                else {
                    if ($entry.Family -ine $p.Family) { $problems.Add("the file name says family $($p.Family), the manifest says $($entry.Family)") }
                    if ($entry.Version -ne $p.Version) { $problems.Add("the file name says version $($p.Version), the manifest says $($entry.Version)") }
                    if ($entry.Publisher -and $entry.Publisher -ine $p.Vendor) { $problems.Add("the file name says vendor $($p.Vendor), the manifest says publisher $($entry.Publisher)") }
                    if ($entry.FileName -and $entry.FileName -ne $p.ZipName) { $problems.Add("the manifest names the payload $($entry.FileName), the source has $($p.ZipName)") }
                    if ($entry.MetadataFileName -and $entry.MetadataFileName -ne $p.PayloadName) { $problems.Add("the manifest names the payload manifest $($entry.MetadataFileName), the source has $($p.PayloadName)") }
                }
                if ($p.ZipLength -le 0) { $problems.Add("$($p.ZipName) is empty (0 bytes)") }
                if ($p.PayloadLength -le 0) { $problems.Add("$($p.PayloadName) is empty (0 bytes)") }
                $src = $s.Source
                if ($src.PackageSize -gt 0 -and $p.ZipLength -gt 0 -and $p.ZipLength -ne $src.PackageSize) { $problems.Add("$($p.ZipName) is $($p.ZipLength) bytes, hardware.sbe.package_size_bytes says $($src.PackageSize)") }
                if ($src.Publisher -and $src.Publisher -ine $p.Vendor) { $problems.Add("hardware.sbe.publisher is $($src.Publisher), the package is from $($p.Vendor)") }
                if ($src.Family -and $src.Family -ine $p.Family) { $problems.Add("hardware.sbe.family is $($src.Family), the package is family $($p.Family)") }
                if ($src.Version -and $src.Version -ne $p.Version) { $problems.Add("hardware.sbe.version is $($src.Version), the package is version $($p.Version)") }
                $pinned = $src.PackageSha256
                $manifestHash = if ($entry) { [string]$entry.PackageHash } else { '' }
                if ($pinned -and $manifestHash -and $pinned -ne $manifestHash) { $problems.Add("hardware.sbe.package_sha256 ($pinned) differs from the manifest's PackageHash ($manifestHash)") }
                $actual = ''
                $hashNote = ''
                if ($p.ZipLength -gt 0 -and ($pinned -or $manifestHash)) {
                    $get = Get-AzlVerAdapterMember -Context $Context -Group 'Sbe' -Name 'GetHash'
                    if (-not $get) { return (New-AzlVerResult Skipped 'The adapter has no Sbe.GetHash here, so the SHA-256 of the payload was not checked.' 'Run the verification from the host that reads the share.') }
                    try { $actual = ([string](& $get $s.Request $p.ZipName)).ToUpperInvariant() }
                    catch { return (New-AzlVerResult Skipped "The SHA-256 of $($p.ZipName) could not be computed, so the payload was not checked against the manifest: $(Protect-AzlVerSbeText -Text $_.Exception.Message -Secret $s.Secret)" 'Make the file readable from this host and run the verification again.') }
                    if ($manifestHash -and $actual -ne $manifestHash) { $problems.Add("$($p.ZipName) has SHA-256 $actual, $($scan.DiscoveryName) says $manifestHash (the download is incomplete or modified)") }
                    if ($pinned -and $actual -ne $pinned) { $problems.Add("$($p.ZipName) has SHA-256 $actual, hardware.sbe.package_sha256 says $pinned") }
                    $hashNote = "SHA-256 $actual"
                }
                elseif (-not $pinned -and -not $manifestHash -and $p.ZipLength -gt 0) { $hashNote = 'no hash in the manifest or the file, so the payload hash was not compared' }
                if ($problems.Count) {
                    return (New-AzlVerResult Failed ("The SBE package $($p.BaseName) is not consistent: " + ($problems -join '; ') + '.') 'Download the package again from the vendor, all three files from the same release, and check the SHA-256 against the vendor page.' -Evidence "zipBytes=$($p.ZipLength) $hashNote")
                }
                if (-not $pinned -and -not $manifestHash) {
                    return (New-AzlVerResult Warning "The package names agree and the sizes are above zero, but neither the manifest nor the file gives a SHA-256, so the payload content was not verified." 'Set hardware.sbe.package_sha256 to the SHA-256 the vendor publishes for the payload.' -Evidence "zipBytes=$($p.ZipLength)")
                }
                New-AzlVerResult Passed "The package files agree: $($p.BaseName) is family $($p.Family) version $($p.Version) in $($scan.DiscoveryName); the payload is $($p.ZipLength) bytes with $hashNote, which matches $(if ($manifestHash) { 'the manifest' } else { 'the hash in the file' })$(if ($pinned -and $manifestHash) { ' and the hash in the file' })." -Evidence "zipBytes=$($p.ZipLength) $hashNote"
            }))

    $defs.Add((New-AzlVerDefinition -Id 'SB-005' -Category nodes -Reads "$reads and the model each node reports" -Source $source `
                -Title 'The package family matches the hardware model of EVERY node (SupportedModels of the package''s own discovery manifest)' -Run {
                param($Context)
                $s = Get-AzlVerSbeSetup $Context
                $block = Get-AzlVerSbeBlock $s 'SB-002'
                if ($block) { return $block }
                $scan = $s.Scan
                $p = $scan.Selected
                if (-not $p) { return (New-AzlVerResult Skipped "No package could be chosen on the source (SB-003), so its family was not compared with the nodes. $($scan.SelectionNote)" 'Fix SB-003 first.') }
                if ($scan.DiscoveryError) { return (New-AzlVerResult Skipped "The discovery manifest could not be read, so the family was not compared with the models: $($scan.DiscoveryError)" 'Download SBE_Discovery_<Vendor>.xml again from the vendor.') }
                $entry = $scan.Entry
                if (-not $entry) { return (New-AzlVerResult Skipped "$($p.BaseName) is not listed in $($scan.DiscoveryName), so its SupportedModels are not known (SB-004)." 'Fix SB-004 first.') }
                $solution = Get-AzlVerTargetSolution $Context
                $fileModel = [string](@($s.Models) | Select-Object -First 1)
                $nodes = @(Get-AzlVerNodeList $Context)
                if (-not $nodes.Count) { return (New-AzlVerResult Skipped 'The file lists no nodes (nodes[].name).' 'Fill nodes[] in the infrastructure file.') }
                foreach ($n in $nodes) {
                    # The models checked for this node: the file's (hardware.model, the same on every node) and the one the node reports, when it can be read.
                    $models = [System.Collections.Generic.List[object]]::new()
                    if ($fileModel) { $models.Add([pscustomobject]@{ Model = $fileModel; From = 'hardware.model in the file' }) }
                    $live = Get-AzlVerNodeData -Context $Context -Node $n.Name -Section 'GetHardware'
                    if ($live.Ok) {
                        $reported = [string](Get-AzlProp $live.Data 'cs.model' '')
                        if ($reported) { $models.Add([pscustomobject]@{ Model = $reported; From = 'reported by the node' }) }
                    }
                    if (-not $models.Count) {
                        New-AzlVerResult Skipped "$($n.Name): no hardware model is known (hardware.model is empty and the node did not report one$(if (-not $live.Ok) { ": $($live.Error)" })), so the family of $($p.BaseName) was not compared with it." 'Set hardware.model in the file, or make the node readable (ND-001).' -Node $n.Name
                        continue
                    }
                    if (-not $entry.SupportedModels.Count) {
                        New-AzlVerResult Skipped "$($n.Name): the discovery manifest lists no SupportedModels for $($p.BaseName), so the family cannot be compared with the model $($models[0].Model)." 'Check the model against your vendor''s SBE release notes, then accept SB-005 with -AcceptSkipped.' -Node $n.Name
                        continue
                    }
                    $bad = [System.Collections.Generic.List[string]]::new(); $good = [System.Collections.Generic.List[string]]::new(); $suggest = ''
                    foreach ($m in $models) {
                        $t = Test-AzlSbeFamilyForModel -Entry $entry -Model $m.Model -AllEntry $scan.Entries -Solution $solution
                        if ($t.Status -eq 'Match') { $good.Add("$($m.Model) ($($m.From))") }
                        else {
                            $bad.Add("$($m.Model) ($($m.From))")
                            if (-not $suggest) { $suggest = Get-AzlVerSbeBestForModel -Entry $scan.Entries -Model $m.Model -Solution $solution }
                        }
                    }
                    if ($bad.Count) {
                        New-AzlVerResult Failed "$($n.Name): the SBE package $($p.BaseName) is family $($p.Family), which supports $(Join-AzlVerList $entry.SupportedModels) ($($scan.DiscoveryName)). This node is $(Join-AzlVerList $bad), which that family does not list, so Azure would list the update Invalid. $suggest" "Download the package of the family that lists the model ($suggest) and replace the files on the source. Do not use $($p.Family) on this hardware." -Node $n.Name -Evidence "family=$($p.Family) supported=$($entry.SupportedModels -join ',') model=$(@($bad) -join ',')"
                    }
                    else {
                        New-AzlVerResult Passed "$($n.Name): the SBE family $($p.Family) lists $(Join-AzlVerList $good)." -Node $n.Name -Evidence "family=$($p.Family) models=$(@($good) -join ',')"
                    }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'SB-006' -Category nodes -Reads $reads -Source $source `
                -Title 'The SBE version is validated for the target solution version (the validated solution versions of the package''s discovery manifest)' -Run {
                param($Context)
                $s = Get-AzlVerSbeSetup $Context
                $block = Get-AzlVerSbeBlock $s 'SB-002'
                if ($block) { return $block }
                $scan = $s.Scan
                $p = $scan.Selected
                if (-not $p) { return (New-AzlVerResult Skipped "No package could be chosen on the source (SB-003), so its version was not compared with the solution version. $($scan.SelectionNote)" 'Fix SB-003 first.') }
                if ($scan.DiscoveryError) { return (New-AzlVerResult Skipped "The discovery manifest could not be read, so the version was not compared with the solution version: $($scan.DiscoveryError)" 'Download SBE_Discovery_<Vendor>.xml again from the vendor.') }
                if (-not $scan.Entry) { return (New-AzlVerResult Skipped "$($p.BaseName) is not listed in $($scan.DiscoveryName), so its validated solution versions are not known (SB-004)." 'Fix SB-004 first.') }
                $solution = Get-AzlVerTargetSolution $Context
                if (-not $solution) { return (New-AzlVerResult Skipped "The target solution version is not known (neither the run setting solutionVersion, the ZTP handoff nor provisioning.os_version gives one), so SBE $($p.Version) was not compared with it." 'Set deployment.solution_version (run setting solutionVersion), for example 12.2610.1004.50.') }
                $r = Test-AzlArmSbeSolution -Catalog $scan.Entries -Family $p.Family -Version $p.Version -Solution $solution
                if ($r.Status -eq 'NotListed') { return (New-AzlVerResult Skipped "SBE $($p.Version) (family $($p.Family)) is not listed in $($scan.DiscoveryName), so it was not compared with solution $solution (SB-004)." 'Fix SB-004 first.') }
                if ($r.Status -eq 'Validated') {
                    return (New-AzlVerResult Passed "SBE $($p.Version) (family $($p.Family)) is validated with solution $($r.MatchedPattern) in $($scan.DiscoveryName); the target is $solution." -Evidence "validated=$($r.MatchedPattern) target=$solution")
                }
                $patterns = Join-AzlVerList @($r.Entry.SolutionPatterns | ForEach-Object { $_.Pattern })
                $best = if (@($r.ValidatedVersions).Count) { "Use SBE $(@($r.ValidatedVersions)[0]) of family $($p.Family) (validated: $(@($r.ValidatedVersions) -join ', '))." } else { "No SBE of family $($p.Family) in $($scan.DiscoveryName) is validated with solution $solution." }
                New-AzlVerResult Failed "SBE $($p.Version) (family $($p.Family)) is validated for solution $patterns, the target solution is $solution. Azure would stop the Validate with ErrorUnvalidatedSolutionAndSbeCombination. $best" "Download the validated SBE package from the vendor and replace the files on the source, or deploy a solution version this SBE is validated for." -Evidence "validated=$patterns target=$solution"
            }))

    return $defs.ToArray()
}

Export-ModuleMember -Function Get-AzlVerificationCheckDefinition, Get-AzlVerificationAdapterDefault
