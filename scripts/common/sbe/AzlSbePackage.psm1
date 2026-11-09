#Requires -Version 7.0
<#
.SYNOPSIS
    The OEM Solution Builder Extension (SBE) package on the share the automation reads it from: is it required, where is it, which package is
    it, is it the right one for the hardware and the solution version, and how it is imported into the cluster later.

.DESCRIPTION
    Requirement (owner, 9 Nov): the SBE package is downloaded and available on a share the automation can read. The toolkit still never
    side-loads it at build time unless the file says so (hardware.sbe.delivery, default skip, rule D46). This module holds the logic that
    the pre-cluster verification (SB- checks), the OS configuration Sbe step and the post-deployment import helper share. It is pure
    except for the default share reader (Get-AzlSbeDefaultReader), which only lists, reads and hashes files, read only.

    A package is three files (Microsoft Learn, "Import and rediscover updates"):
        SBE_Discovery_<Vendor>.xml                the discovery manifest: families, versions, SupportedModels, validated solution versions
        SBE_<Vendor>_<Family>_<Version>.xml       the payload manifest (inventory and signed software bill of materials)
        SBE_<Vendor>_<Family>_<Version>.zip       the payload

    Nothing here knows a model or a family. The family-to-model mapping is the SupportedModels list of the package's own discovery manifest.
    The vendor catalog (config/oem/<vendor>.json, sbe.acquisition and sbe.requiredByDefault) says whether the vendor needs a manual download.

    Share reader: a table of scriptblocks, replaced by fakes in tests.
        List(request)            -> @{ Ok; ErrorKind (NotFound|AccessDenied|Unreachable|Other); Error; Files = @(@{ Name; Length }) }
        ReadText(request, name)  -> the text of a small file (an xml manifest)
        GetHash(request, name)   -> the SHA-256 (upper case hex) of a file
    The reader never writes to the share. request = @{ Path; Username; Password }. The password is held in memory only and never written or shown.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'arm-deployment', 'AzlArmDeploymentRun.psm1'))

$script:ConfigRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'config'))

# ---------------------------------------------------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlSbeModelKey {
    <#
    .SYNOPSIS
        A hardware model as a comparison key: letters and digits only, lower case. AX-760, AX760 and "ax 760" are one key; PowerEdge R760 and PowerEdgeR760 are one key.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Model)
    if ($null -eq $Model) { return '' }
    return ([regex]::Replace($Model, '[^A-Za-z0-9]', '')).ToLowerInvariant()
}

function Split-AzlSbePackageName {
    <#
    .SYNOPSIS
        SBE_<Vendor>_<Family>_<Version>[.zip|.xml] as Vendor, Family, Version, BaseName. $null when the name does not follow the pattern or is a discovery manifest.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Name)
    if (-not $Name) { return $null }
    $base = $Name -replace '\.(zip|xml)$', ''
    if ($base -like 'SBE_Discovery_*') { return $null }
    $m = [regex]::Match($base, '^SBE_(?<vendor>[^_]+)_(?<family>.+)_(?<version>\d+(?:\.\d+){2,3})$')
    if (-not $m.Success) { return $null }
    [pscustomobject]@{ Vendor = $m.Groups['vendor'].Value; Family = $m.Groups['family'].Value; Version = $m.Groups['version'].Value; BaseName = $base }
}

# ---------------------------------------------------------------------------------------------------------------------
# Requirement and source (from the file and the vendor catalog)
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlSbeVendorProfile {
    <#
    .SYNOPSIS
        What config/oem/<vendor>.json says about the vendor's SBE: Acquisition (manual_download, automatic_download or unknown), RequiredByDefault
        ($true, $false or $null when the catalog says nothing), Verified, Note. $null when the vendor has no file.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Vendor, [string]$ConfigRoot = $script:ConfigRoot)
    if (-not $Vendor) { return $null }
    $path = Join-Path (Join-Path $ConfigRoot 'oem') "$($Vendor.Trim().ToLowerInvariant()).json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 10
    $sbe = Get-AzlProp $json 'sbe' $null
    $required = Get-AzlProp $sbe 'requiredByDefault' $null
    [pscustomobject]@{
        Vendor            = [string](Get-AzlProp $json 'oem' $Vendor)
        Acquisition       = [string](Get-AzlProp $sbe 'acquisition' 'unknown')
        RequiredByDefault = $(if ($null -eq $required) { $null } else { [bool]$required })
        Verified          = [bool](Get-AzlProp $sbe 'verified' $false)
        Note              = [string](Get-AzlProp $sbe 'acquisitionNote' '')
    }
}

function Get-AzlSbeRequirement {
    <#
    .SYNOPSIS
        Whether the SBE package is required for this deployment. Pure (reads the vendor catalog file).
    .DESCRIPTION
        hardware.sbe.requirement says it: required, or not_applicable (which needs hardware.sbe.not_applicable_reason). When the key is absent
        the vendor catalog decides: a vendor that needs a manual download (Dell, HPE, DataON) is required, a vendor whose cluster downloads it
        itself (Lenovo Premier) is not required by default, a vendor the catalog does not know is Unknown.
    .OUTPUTS
        State: Required | NotApplicable | NotApplicableNoReason | NotRequiredByCatalog | Unknown | Invalid.
        From (file or vendor catalog), Reason, Vendor, Profile.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Infrastructure, [string]$ConfigRoot = $script:ConfigRoot)
    $vendor = ([string](Get-AzlProp $Infrastructure 'hardware.vendor' '')).Trim()
    $vendorProfile = Get-AzlSbeVendorProfile -Vendor $vendor -ConfigRoot $ConfigRoot
    $declared = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.requirement' '')).Trim().ToLowerInvariant()
    $reason = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.not_applicable_reason' '')).Trim()
    $result = { param($State, $From, $Why) [pscustomobject]@{ State = $State; From = $From; Reason = $Why; Vendor = $vendor; Profile = $vendorProfile } }
    switch ($declared) {
        'required' { return (& $result 'Required' 'hardware.sbe.requirement' 'the file says the package is required') }
        'not_applicable' {
            if ($reason) { return (& $result 'NotApplicable' 'hardware.sbe.requirement' $reason) }
            return (& $result 'NotApplicableNoReason' 'hardware.sbe.requirement' 'hardware.sbe.requirement is not_applicable but hardware.sbe.not_applicable_reason is empty')
        }
        '' { }
        default { return (& $result 'Invalid' 'hardware.sbe.requirement' "hardware.sbe.requirement is '$declared'; it is required or not_applicable") }
    }
    if (-not $vendor) { return (& $result 'Unknown' 'hardware.vendor' 'hardware.vendor is empty, so the vendor catalog cannot say whether an SBE package is required') }
    if (-not $vendorProfile -or $null -eq $vendorProfile.RequiredByDefault) { return (& $result 'Unknown' 'vendor catalog' "the vendor catalog (config/oem) has no SBE entry for '$vendor'") }
    if ($vendorProfile.RequiredByDefault) { return (& $result 'Required' 'vendor catalog' "$vendor's SBE is a manual download (vendor catalog: $($vendorProfile.Acquisition)$(if (-not $vendorProfile.Verified) { ', not yet verified against the vendor pages' }))") }
    return (& $result 'NotRequiredByCatalog' 'vendor catalog' "$vendor's cluster downloads the SBE itself (vendor catalog: $($vendorProfile.Acquisition)$(if (-not $vendorProfile.Verified) { ', not yet verified against the vendor pages' }))")
}

function Get-AzlSbeSource {
    <#
    .SYNOPSIS
        Where the package is available to the automation, from the file: hardware.sbe.source_path, else the older hardware.sbe.bundle_path.
        Also the read credential reference (Key Vault, never the secret), the pinned hash and size, and the family and version the file declares.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Infrastructure)
    $path = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.source_path' '')).Trim()
    $from = 'hardware.sbe.source_path'
    if (-not $path) { $path = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.bundle_path' '')).Trim(); $from = 'hardware.sbe.bundle_path' }
    if (-not $path) { $from = '' }
    $size = Get-AzlProp $Infrastructure 'hardware.sbe.package_size_bytes' $null
    [pscustomobject]@{
        Path           = $path
        From           = $from
        IsUnc          = $path.StartsWith('\\')
        Username       = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.source_username' '')).Trim()
        PasswordRef    = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.source_password' '')).Trim()
        PackageSha256  = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.package_sha256' '')).Trim().ToUpperInvariant()
        PackageSize    = $(if ($null -ne $size -and "$size" -ne '') { [int64]$size } else { [int64]0 })
        Publisher      = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.publisher' '')).Trim()
        Family         = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.family' '')).Trim()
        Version        = ([string](Get-AzlProp $Infrastructure 'hardware.sbe.version' '')).Trim()
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The discovery manifest
# ---------------------------------------------------------------------------------------------------------------------

function Read-AzlSbeDiscoveryText {
    <#
    .SYNOPSIS
        The entries of an SBE discovery manifest (the text of SBE_Discovery_<Vendor>.xml): one per ApplicableUpdate. DTDs are refused.
    .OUTPUTS
        Name (UpdateName), Version, Family, Publisher, PackageHash (upper case), PackageSizeMb, SupportedModels, SolutionPatterns (Pattern,
        MinVersionRequired), MetadataFileName, FileName, Description. SolutionPatterns, Name, Version and Family are what Test-AzlArmSbeSolution reads.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $xml = [xml]::new()
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Text), $settings)
    try { $xml.Load($reader) } finally { $reader.Dispose() }
    $root = $xml.SelectSingleNode('/SBEUpdatesManifest')
    if (-not $root) { throw 'Not an SBE discovery manifest (no SBEUpdatesManifest root).' }
    foreach ($node in $root.SelectNodes('ApplicableUpdate')) {
        $patterns = foreach ($package in $node.SelectNodes('ValidatedConfigurations/RequiredPackages/Package[@Type="Solution"]')) {
            [pscustomobject]@{ Pattern = [string]$package.GetAttribute('Version'); MinVersionRequired = [string]$package.GetAttribute('MinVersionRequired') }
        }
        $models = foreach ($m in $node.SelectNodes('UpdateInfo/SupportedModels/SupportedModel')) { ([string]$m.InnerText).Trim() }
        $size = 0.0
        [void][double]::TryParse([string]$node.SelectSingleNode('UpdateInfo/PackageSizeInMb')?.InnerText, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$size)
        [pscustomobject]@{
            Name             = ([string]$node.SelectSingleNode('UpdateInfo/UpdateName')?.InnerText).Trim()
            Version          = [string]$node.GetAttribute('Version')
            Family           = [string]$node.GetAttribute('Family')
            Publisher        = ([string]$node.SelectSingleNode('UpdateInfo/Publisher')?.InnerText).Trim()
            PackageHash      = ([string]$node.SelectSingleNode('UpdateInfo/PackageHash')?.InnerText).Trim().ToUpperInvariant()
            PackageSizeMb    = $size
            SupportedModels  = @($models | Where-Object { $_ })
            SolutionPatterns = @($patterns)
            MetadataFileName = [string]$node.SelectSingleNode('MetadataFile')?.GetAttribute('Name')
            FileName         = [string]$node.SelectSingleNode('File')?.GetAttribute('Name')
            Description      = ([string]$node.SelectSingleNode('UpdateInfo/Description')?.InnerText).Trim()
        }
    }
}

function Find-AzlSbeEntryForModel {
    <#
    .SYNOPSIS
        The entries of a discovery manifest whose SupportedModels list a hardware model, newest version first; with -Solution only those validated with it.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry, [Parameter(Mandatory)][string]$Model, [string]$Solution = '')
    $key = ConvertTo-AzlSbeModelKey $Model
    $found = @($Entry | Where-Object { $key -and @($_.SupportedModels | ForEach-Object { ConvertTo-AzlSbeModelKey $_ }) -contains $key })
    if ($Solution) { $found = @($found | Where-Object { @($_.SolutionPatterns | Where-Object { Test-AzlArmSolutionVersionMatch -Pattern $_.Pattern -Version $Solution -MinVersionRequired $_.MinVersionRequired }).Count }) }
    @($found | Sort-Object { $v = $null; if ([version]::TryParse($_.Version, [ref]$v)) { $v } else { [version]'0.0' } } -Descending)
}

# ---------------------------------------------------------------------------------------------------------------------
# The share reader
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlSbeDefaultReader {
    <#
    .SYNOPSIS
        The real share reader: lists, reads and hashes files of a folder or UNC share, read only. With a user name and password it maps the share for the
        call with New-PSDrive (no -Persist) and removes the drive again. Nothing is written to the share.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password was just read from Key Vault; it becomes a SecureString at once and lives in memory only.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Name is read inside the nested script block that runs against the mapped share.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $with = {
        param($Request, [scriptblock]$Body)
        $drive = $null
        try {
            $root = [string]$Request.Path
            $user = [string](Get-AzlProp $Request 'Username' ''); $pw = [string](Get-AzlProp $Request 'Password' '')
            if ($user -and $pw -and $root.StartsWith('\\')) {
                $parts = $root.TrimStart('\').Split('\')
                $share = "\\$($parts[0])\$($parts[1])"
                $name = 'SbeSrc' + [guid]::NewGuid().ToString('N').Substring(0, 6)
                $credential = [pscredential]::new($user, (ConvertTo-SecureString -String $pw -AsPlainText -Force))
                $drive = New-PSDrive -Name $name -PSProvider FileSystem -Root $share -Credential $credential -Scope Script -ErrorAction Stop
                $rest = if ($parts.Count -gt 2) { ($parts | Select-Object -Skip 2) -join '\' } else { '' }
                $root = if ($rest) { "${name}:\$rest" } else { "${name}:\" }
            }
            & $Body $root
        }
        finally { if ($drive) { Remove-PSDrive -Name $drive.Name -Force -ErrorAction SilentlyContinue } }
    }
    @{
        List = {
            param($Request)
            try {
                $files = & $with $Request { param($root) @(Get-ChildItem -LiteralPath $root -File -ErrorAction Stop | ForEach-Object { @{ Name = $_.Name; Length = [int64]$_.Length } }) }
                @{ Ok = $true; ErrorKind = ''; Error = ''; Files = @($files) }
            }
            catch {
                $e = $_.Exception
                $kind = if ($e -is [System.UnauthorizedAccessException] -or $e.Message -match 'denied|logon failure|password is incorrect|user name') { 'AccessDenied' }
                elseif ($e -is [System.IO.DirectoryNotFoundException] -or $e.Message -match 'Cannot find path|does not exist') { 'NotFound' }
                elseif ($e -is [System.IO.IOException] -or $e.Message -match 'network path|network name|not found|unreachable|timed out') { 'Unreachable' }
                else { 'Other' }
                @{ Ok = $false; ErrorKind = $kind; Error = $e.Message; Files = @() }
            }
        }.GetNewClosure()
        ReadText = { param($Request, $Name) & $with $Request { param($root) Get-Content -LiteralPath (Join-Path $root $Name) -Raw -ErrorAction Stop } }.GetNewClosure()
        GetHash  = { param($Request, $Name) & $with $Request { param($root) (Get-FileHash -LiteralPath (Join-Path $root $Name) -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant() } }.GetNewClosure()
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The package on the share
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlSbeSourceScan {
    <#
    .SYNOPSIS
        Reads a share once, without hashing: lists it, finds the discovery manifest(s) and the package(s), reads the discovery manifest and picks the
        package. This is the light read (OS configuration information, the import helper); the gate adds the hashes.
    .PARAMETER Request
        @{ Path; Username; Password }.
    .PARAMETER Reader
        The share reader (see the module header). Default: Get-AzlSbeDefaultReader.
    .PARAMETER Family / Version
        The family and version the file declares (hardware.sbe.family / version); they select the package when the share holds more than one.
    .PARAMETER Model
        The hardware models of the nodes: with no family declared and several packages on the share, the one whose SupportedModels list every model is taken.
    .OUTPUTS
        Stage: Listed | Unreachable. List (the reader's answer). Discovery (file names), Zips, PayloadXmls. DiscoveryError, Entries (all entries of the manifest),
        Package: Selected (BaseName, Vendor, Family, Version, ZipName, PayloadName, ZipPresent, PayloadPresent, ZipLength, PayloadLength), Entry (the manifest
        entry of the package, or $null), Ambiguous (names), SelectionNote.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        $Reader,
        [string]$Family = '', [string]$Version = '', [string]$Publisher = '', [string[]]$Model = @()
    )
    if (-not $Reader) { $Reader = Get-AzlSbeDefaultReader }
    $scan = [ordered]@{
        Stage = 'Unreachable'; List = $null; Discovery = @(); Zips = @(); PayloadXmls = @(); DiscoveryError = ''; DiscoveryName = ''; Entries = @(); Selected = $null; Entry = $null; Ambiguous = @(); SelectionNote = ''
    }
    $list = & $Reader.List $Request
    $scan.List = $list
    if (-not $list.Ok) { return [pscustomobject]$scan }
    $scan.Stage = 'Listed'
    $names = @($list.Files | ForEach-Object { [string]$_.Name })
    $length = @{}; foreach ($f in $list.Files) { $length[[string]$f.Name] = [int64]$f.Length }
    $scan.Discovery = @($names | Where-Object { $_ -like 'SBE_Discovery_*.xml' } | Sort-Object)
    $scan.Zips = @($names | Where-Object { $_ -like 'SBE_*.zip' -and $_ -notlike 'SBE_Discovery_*' } | Sort-Object)
    $scan.PayloadXmls = @($names | Where-Object { $_ -like 'SBE_*.xml' -and $_ -notlike 'SBE_Discovery_*' } | Sort-Object)

    if ($scan.Discovery.Count -eq 1) {
        $scan.DiscoveryName = $scan.Discovery[0]
        try { $scan.Entries = @(Read-AzlSbeDiscoveryText -Text ([string](& $Reader.ReadText $Request $scan.Discovery[0]))) }
        catch { $scan.DiscoveryError = "$($scan.Discovery[0]) could not be read as an SBE discovery manifest: $($_.Exception.Message)" }
    }
    elseif ($scan.Discovery.Count -gt 1) { $scan.DiscoveryError = "The source holds $($scan.Discovery.Count) discovery manifests ($($scan.Discovery -join ', ')); keep the one of your hardware vendor." }

    # Candidate packages: every base name with a zip or a payload manifest.
    $bases = @((@($scan.Zips) + @($scan.PayloadXmls)) | ForEach-Object { $_ -replace '\.(zip|xml)$', '' } | Sort-Object -Unique)
    $parsed = @($bases | ForEach-Object { Split-AzlSbePackageName $_ } | Where-Object { $_ })
    $unparsed = @($bases | Where-Object { -not (Split-AzlSbePackageName $_) })
    $pick = $null
    # What the file declares (publisher, family, version) narrows the packages on the source; what is left is narrowed by the nodes' model when there is more than one.
    $declared = [bool]($Family -or $Version -or $Publisher)
    $filtered = @($parsed | Where-Object { (-not $Family -or $_.Family -ieq $Family) -and (-not $Version -or $_.Version -eq $Version) -and (-not $Publisher -or $_.Vendor -ieq $Publisher) })
    if ($declared -and -not $filtered.Count -and $parsed.Count) {
        $what = (@(if ($Publisher) { "publisher $Publisher" }; if ($Family) { "family $Family" }; if ($Version) { "version $Version" }) -join ' ')
        $scan.SelectionNote = "the file declares $what, which is not among the packages on the source ($(@($parsed | ForEach-Object { $_.BaseName }) -join ', '))"
    }
    elseif ($filtered.Count -eq 1) {
        $pick = $filtered[0]
        $scan.SelectionNote = $(if ($declared -and $parsed.Count -gt 1) { "chosen by hardware.sbe.family/version/publisher ($($pick.BaseName))" } elseif ($declared) { 'the package the file declares' } else { 'the only package on the source' })
        if ($Family -and $Version -and $parsed.Count -gt 1) { $scan.SelectionNote = "chosen by hardware.sbe.family $Family and hardware.sbe.version $Version" }
    }
    elseif ($filtered.Count -gt 1) {
        $keys = @($Model | Where-Object { $_ } | ForEach-Object { ConvertTo-AzlSbeModelKey $_ })
        $fit = @()
        if ($keys.Count -and $scan.Entries.Count) {
            $fit = @($filtered | Where-Object {
                    $p = $_
                    $entry = @($scan.Entries | Where-Object { $_.Name -eq $p.BaseName }) | Select-Object -First 1
                    $entry -and (@($keys | Where-Object { @($entry.SupportedModels | ForEach-Object { ConvertTo-AzlSbeModelKey $_ }) -notcontains $_ }).Count -eq 0)
                })
        }
        if ($fit.Count -eq 1) { $pick = $fit[0]; $scan.SelectionNote = "the only one of $($filtered.Count) packages on the source whose SupportedModels list the nodes' model" }
        else { $scan.Ambiguous = @($filtered | ForEach-Object { $_.BaseName }) }
    }
    elseif ($Family -and $Version -and -not $parsed.Count) {
        # Nothing on the share yet: the package the file asks for.
        $vendor = if ($Publisher) { $Publisher } else { '' }
        if ($vendor) { $pick = [pscustomobject]@{ Vendor = $vendor; Family = $Family; Version = $Version; BaseName = "SBE_${vendor}_${Family}_$Version" }; $scan.SelectionNote = 'named by hardware.sbe (publisher, family, version); not on the source' }
    }
    if ($pick) {
        $zip = "$($pick.BaseName).zip"; $payload = "$($pick.BaseName).xml"
        $scan.Selected = [pscustomobject]@{
            BaseName = $pick.BaseName; Vendor = $pick.Vendor; Family = $pick.Family; Version = $pick.Version; ZipName = $zip; PayloadName = $payload; DiscoveryName = $scan.DiscoveryName
            ZipPresent = ($names -contains $zip); PayloadPresent = ($names -contains $payload)
            ZipLength = $(if ($length.ContainsKey($zip)) { $length[$zip] } else { [int64]0 }); PayloadLength = $(if ($length.ContainsKey($payload)) { $length[$payload] } else { [int64]0 })
        }
        $scan.Entry = @($scan.Entries | Where-Object { $_.Name -eq $pick.BaseName }) | Select-Object -First 1
    }
    if ($unparsed.Count) { $scan.SelectionNote = (($scan.SelectionNote, "ignored (not SBE_<Vendor>_<Family>_<Version>): $($unparsed -join ', ')") | Where-Object { $_ }) -join '; ' }
    [pscustomobject]$scan
}

function Test-AzlSbeFamilyForModel {
    <#
    .SYNOPSIS
        Whether the package's discovery entry lists a hardware model in SupportedModels. The mapping is the manifest's, nothing here names a model.
    .OUTPUTS
        Status: Match | Mismatch | NoModelList. Supported (the list), Suggested (entries of the whole manifest that list the model, newest first, validated with -Solution when given).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Model, [AllowEmptyCollection()][object[]]$AllEntry = @(), [string]$Solution = '')
    $supported = @($Entry.SupportedModels)
    if (-not $supported.Count) { return [pscustomobject]@{ Status = 'NoModelList'; Supported = @(); Suggested = @() } }
    $key = ConvertTo-AzlSbeModelKey $Model
    $match = $key -and (@($supported | ForEach-Object { ConvertTo-AzlSbeModelKey $_ }) -contains $key)
    $suggested = if ($match) { @() } else { @(Find-AzlSbeEntryForModel -Entry $AllEntry -Model $Model -Solution $Solution) }
    [pscustomobject]@{ Status = $(if ($match) { 'Match' } else { 'Mismatch' }); Supported = $supported; Suggested = $suggested }
}

function Get-AzlSbeShareInfo {
    <#
    .SYNOPSIS
        What the SBE source holds, in the shape the OS configuration Sbe step reports when nothing is side-loaded (Get-AzlNodeSpec -SbeShare): Available,
        Path, PackageName, ZipName, Family, Version, Publisher, Reason. Reads the share without hashing; nothing is copied. $null when no source is configured.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The value was read from Key Vault for this run; it is held in memory only and never written.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Infrastructure, $Reader, [string]$Password = '')
    $src = Get-AzlSbeSource -Infrastructure $Infrastructure
    if (-not $src.Path) { return $null }
    $model = ([string](Get-AzlProp $Infrastructure 'hardware.model' '')).Trim()
    $info = { param($ok, $why, $p) [pscustomobject]@{
            Available = $ok; Path = $src.Path; Reason = $why
            PackageName = $(if ($p) { $p.BaseName } else { '' }); ZipName = $(if ($p) { $p.ZipName } else { '' })
            Family = $(if ($p) { $p.Family } else { '' }); Version = $(if ($p) { $p.Version } else { '' }); Publisher = $(if ($p) { $p.Vendor } else { '' })
        } }
    try {
        $scan = Get-AzlSbeSourceScan -Request @{ Path = $src.Path; Username = $src.Username; Password = $Password } -Reader $Reader -Family $src.Family -Version $src.Version -Publisher $src.Publisher -Model @($model | Where-Object { $_ })
    }
    catch { return (& $info $false $_.Exception.Message $null) }
    if ($scan.Stage -ne 'Listed') { return (& $info $false ([string]$scan.List.Error) $null) }
    $p = $scan.Selected
    if (-not $p) { return (& $info $false $(if ($scan.Ambiguous.Count) { "more than one package on the source ($($scan.Ambiguous -join ', '))" } else { 'no SBE package (SBE_<Vendor>_<Family>_<Version>.zip and .xml) on the source' }) $null) }
    $missing = @()
    if (-not $scan.Discovery.Count) { $missing += 'SBE_Discovery_<Vendor>.xml' } elseif ($scan.Discovery.Count -gt 1) { $missing += 'one discovery manifest (several are there)' }
    if (-not $p.PayloadPresent) { $missing += $p.PayloadName }
    if (-not $p.ZipPresent) { $missing += $p.ZipName }
    if ($missing.Count) { return (& $info $false "the package $($p.BaseName) is missing $($missing -join ', ')" $p) }
    return (& $info $true '' $p)
}

function Mount-AzlSbeSource {
    <#
    .SYNOPSIS
        Makes the SBE source readable under a path, for the OS configuration that copies files out of it: the path itself when no credential is configured, else the
        share mapped for the run with the account of hardware.sbe.source_username (New-PSDrive, no -Persist). Remove it with Dismount-AzlSbeSource.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password was just read from Key Vault; it becomes a SecureString at once and lives in memory only.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Maps a read only drive for the run and removes it again.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The value was read from Key Vault for this run; it is held in memory only and never written.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source, [string]$Password = '')
    if (-not $Source.Username -or -not $Password -or -not $Source.IsUnc) { return [pscustomobject]@{ Path = $Source.Path; Drive = '' } }
    $parts = $Source.Path.TrimStart('\').Split('\')
    if ($parts.Count -lt 2) { throw "The SBE source $($Source.Path) is not a \\server\share path, so it cannot be mapped for the account $($Source.Username)." }
    $name = 'SbeSrc' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $credential = [pscredential]::new($Source.Username, (ConvertTo-SecureString -String $Password -AsPlainText -Force))
    $null = New-PSDrive -Name $name -PSProvider FileSystem -Root "\\$($parts[0])\$($parts[1])" -Credential $credential -Scope Global -ErrorAction Stop
    $rest = if ($parts.Count -gt 2) { ($parts | Select-Object -Skip 2) -join '\' } else { '' }
    [pscustomobject]@{ Path = $(if ($rest) { "${name}:\$rest" } else { "${name}:\" }); Drive = $name }
}

function Dismount-AzlSbeSource {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Removes the drive Mount-AzlSbeSource mapped for the run.')]
    <#
    .SYNOPSIS
        Removes the drive Mount-AzlSbeSource mapped for the run (a no-op when none was mapped).
    #>
    [CmdletBinding()]
    param([AllowNull()]$Mount)
    if ($Mount -and $Mount.Drive) { Remove-PSDrive -Name $Mount.Drive -Scope Global -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------------------------------------
# The post-deployment import (Learn: Update Azure Local by using PowerShell, step 3 "Import and rediscover updates")
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlSbeImportPlan {
    <#
    .SYNOPSIS
        The files to import into the cluster's update service with Add-SolutionUpdate, and the exact commands. Nothing is executed or copied.
    .DESCRIPTION
        Microsoft Learn: when an update reports AdditionalContentRequired (a vendor whose SBE has no download connector for this cluster), import the three
        SBE files: copy them into a folder of the infrastructure volume, run Add-SolutionUpdate -SourceFolder on it, then Get-SolutionUpdate until it is Ready.
    .OUTPUTS
        Files (Name, Length), SourceFolder (the share), ImportFolder, Commands (strings, in order), Notes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)]$Package,
        [string]$ImportFolder = 'C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import'
    )
    $files = @(
        [pscustomobject]@{ Name = [string]$Package.DiscoveryName; Length = [int64]0; Role = 'discovery manifest' }
        [pscustomobject]@{ Name = [string]$Package.PayloadName; Length = [int64]$Package.PayloadLength; Role = 'payload manifest' }
        [pscustomobject]@{ Name = [string]$Package.ZipName; Length = [int64]$Package.ZipLength; Role = 'payload' }
    )
    $src = $SourcePath.TrimEnd('\')
    $commands = @(
        "# On a machine of the cluster, signed in as the deployment user (Learn: Update Azure Local by using PowerShell, step 3). The share must be readable from the machine.",
        "New-Item -ItemType Directory -Force -Path '$ImportFolder' | Out-Null"
    )
    foreach ($f in $files) { $commands += "Copy-Item -LiteralPath '$src\$($f.Name)' -Destination '$ImportFolder' -Force" }
    $commands += "Get-FileHash -Algorithm SHA256 -Path '$ImportFolder\$($Package.ZipName)'   # compare with the PackageHash of $($Package.DiscoveryName)"
    $commands += "Add-SolutionUpdate -SourceFolder '$ImportFolder'"
    $commands += 'Get-SolutionUpdate | Format-Table DisplayName, PackageType, Version, SbeVersion, State   # run again until the update is Ready (discovery is asynchronous)'
    [pscustomobject]@{
        Files        = $files
        SourceFolder = $src
        ImportFolder = $ImportFolder
        Commands     = $commands
        Notes        = @(
            'These commands are listed, not executed by the toolkit.',
            'An update that reports Invalid does not match the hardware model or family: import only the SBE family that matches the nodes (Learn: Update phases).',
            'Vendors with a download connector and credentials on the cluster (Set-SolutionExtensionSecretLocation) show the update as Ready without an import.'
        )
    }
}

Export-ModuleMember -Function ConvertTo-AzlSbeModelKey, Split-AzlSbePackageName, Get-AzlSbeVendorProfile, Get-AzlSbeRequirement, Get-AzlSbeSource, Read-AzlSbeDiscoveryText, Find-AzlSbeEntryForModel, Get-AzlSbeDefaultReader, Get-AzlSbeSourceScan, Test-AzlSbeFamilyForModel, Get-AzlSbeShareInfo, Mount-AzlSbeSource, Dismount-AzlSbeSource, Get-AzlSbeImportPlan
