#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pre-cluster verification, SBE package (SB-) checks. Fakes only: no share, no Azure, no node, no credential. The share is a table of file names to
# size, text and hash; the nodes' models come from a fake Node.GetHardware. File names follow the vendor pattern SBE_<Vendor>_<Family>_<Version>
# and are made up (HPE, Lenovo and DataON examples are not real packages); the Dell excerpt is the repository's public discovery fixture.

BeforeAll {
    $script:VerDir = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'common', 'arm-deployment', 'verification'))
    $script:Mod = Import-Module ([IO.Path]::Combine($script:VerDir, 'AzlVerification.Sbe.psm1')) -Force -PassThru
    $script:DellExcerpt = Get-Content -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', 'fixtures', 'sbe', 'SBE_Discovery_Dell.excerpt.xml')) -Raw
    $script:Ids = 'SB-001', 'SB-002', 'SB-003', 'SB-004', 'SB-005', 'SB-006'

    function New-SbeDiscovery {
        # A discovery manifest with the given entries: @{ Vendor; Family; Version; Models; Solutions; Hash; SizeMb }.
        param([Parameter(Mandatory)][object[]]$Entry)
        $x = foreach ($e in $Entry) {
            $name = "SBE_$($e.Vendor)_$($e.Family)_$($e.Version)"
            $models = ($e.Models | ForEach-Object { "<SupportedModel>$_</SupportedModel>" }) -join ''
            $sol = ($e.Solutions | ForEach-Object { "<Package Type=`"Solution`" Version=`"$_`" Inject=`"true`" />" }) -join ''
            @"
  <ApplicableUpdate Version="$($e.Version)" Type="SBE" Family="$($e.Family)">
    <ValidatedConfigurations><RequiredPackages>$sol</RequiredPackages></ValidatedConfigurations>
    <UpdateInfo>
      <UpdateName>$name</UpdateName><Publisher>$($e.Vendor)</Publisher><Version>$($e.Version)</Version>
      <SupportedModels>$models</SupportedModels><PackageSizeInMb>$($e.SizeMb)</PackageSizeInMb><PackageHash>$($e.Hash)</PackageHash>
    </UpdateInfo>
    <MetadataFile Name="$name.xml" Uri="" />
    <File Name="$name.zip" Uri="" Type="DownloadConnector" />
  </ApplicableUpdate>
"@
        }
        "<?xml version=`"1.0`" encoding=`"utf-8`"?><SBEUpdatesManifest><ManifestInfo ManifestType=`"SBE`" CreationDate=`"2026-10-21T20:27:08Z`" />$($x -join "`n")</SBEUpdatesManifest>"
    }

    function Get-SbeFixtureHash([string]$Family, [string]$Version) {
        # The PackageHash the Dell excerpt gives for one entry, so the fake payload can carry exactly it.
        $m = [regex]::Match($script:DellExcerpt, "Family=`"$([regex]::Escape($Family))`">(?s:.*?)<PackageHash>(?<h>[0-9A-F]+)</PackageHash>")
        $m.Groups['h'].Value
    }

    function New-SbeShare {
        # Files: name -> @{ Text; Length; Hash }. Returns the table the fake reader answers from, plus the calls it saw.
        param([hashtable]$File)
        [pscustomobject]@{ File = $File; Requests = [System.Collections.Generic.List[object]]::new(); Unreachable = $null; Hashed = [System.Collections.Generic.List[string]]::new() }
    }

    function New-SbeContext {
        param(
            [Parameter(Mandatory)]$Share, [hashtable]$Hardware = @{ vendor = 'Dell'; model = 'AX-760' }, [hashtable]$Sbe = @{ source_path = '\\files.example.invalid\sbe\dell' },
            [string]$Solution = '12.2610.1004.50', [hashtable]$NodeModel = @{ n01 = 'AX-760'; n02 = 'AX-760' }, [hashtable]$Secret = @{}, [switch]$NoSolution, [hashtable]$ExtraAdapter = @{}
        )
        $hw = [ordered]@{}; foreach ($k in $Hardware.Keys) { $hw[$k] = $Hardware[$k] }
        if ($Sbe.Count) { $hw['sbe'] = [ordered]@{}; foreach ($k in $Sbe.Keys) { $hw['sbe'][$k] = $Sbe[$k] } }
        $infra = [ordered]@{
            hardware = $hw; provisioning = [ordered]@{ os_version = $(if ($NoSolution) { '' } else { $Solution }) }
            nodes = @([ordered]@{ name = 'n01'; network_adapters = @([ordered]@{ roles = @('management'); ip_address = '192.0.2.11' }) }, [ordered]@{ name = 'n02'; network_adapters = @([ordered]@{ roles = @('management'); ip_address = '192.0.2.12' }) })
        }
        $sh = $Share; $nm = $NodeModel; $sec = $Secret
        $adapters = @{
            Sbe      = @{
                List     = { param($Request) $sh.Requests.Add($Request); if ($sh.Unreachable) { return $sh.Unreachable }; @{ Ok = $true; ErrorKind = ''; Error = ''; Files = @($sh.File.Keys | ForEach-Object { @{ Name = $_; Length = [int64]$sh.File[$_].Length } }) } }.GetNewClosure()
                ReadText = { param($Request, $Name) [string]$sh.File[$Name].Text }.GetNewClosure()
                GetHash  = { param($Request, $Name) $sh.Hashed.Add($Name); [string]$sh.File[$Name].Hash }.GetNewClosure()
            }
            KeyVault = @{ GetSecret = { param($Reference) if (-not $sec.ContainsKey($Reference)) { throw "no such secret $Reference" }; $sec[$Reference] }.GetNewClosure() }
            Node     = @{ GetHardware = { param($Node, $Context) $null = $Context; if (-not $nm.ContainsKey($Node)) { throw 'node not reachable' }; @{ cs = @{ manufacturer = 'Dell'; model = $nm[$Node] } } }.GetNewClosure() }
        }
        foreach ($k in $ExtraAdapter.Keys) { $adapters[$k] = $ExtraAdapter[$k] }
        @{ Infrastructure = $infra; Handoff = $null; OsReport = $null; Settings = @{}; Adapters = $adapters }
    }

    function Invoke-Sb {
        param([Parameter(Mandatory)]$Context)
        $out = [ordered]@{}
        foreach ($d in (& $script:Mod.ExportedCommands['Get-AzlVerificationCheckDefinition'])) {
            $out[$d.Id] = @(if (& $d.Applies $Context) { & $d.Run $Context } else { [pscustomobject]@{ Status = 'NotApplicable'; Node = '*'; Message = 'does not apply' } })
        }
        $out
    }

    function New-DellShare {
        # A share with the Dell excerpt and one package of the given family and version; the payload carries the PackageHash the excerpt gives.
        param([string]$Family = '16G-45n0c-Intel', [string]$Version = '5.0.2609.1611', [int64]$ZipLength = 1000, [string]$Hash)
        if (-not $Hash) { $Hash = Get-SbeFixtureHash $Family }
        $name = "SBE_Dell_${Family}_$Version"
        New-SbeShare -File @{
            'SBE_Discovery_Dell.xml' = @{ Text = $script:DellExcerpt; Length = 1000; Hash = '' }
            "$name.xml"              = @{ Text = '<SBEDetailedMetadata/>'; Length = 500; Hash = '' }
            "$name.zip"              = @{ Text = ''; Length = $ZipLength; Hash = $Hash }
        }
    }

    function New-VendorShare {
        # A made-up vendor package (name pattern SBE_<Vendor>_<Family>_<Version>) with its generated discovery manifest.
        param([string]$Vendor, [string]$Family, [string]$Version, [string[]]$Model, [string[]]$Solution = @('12.*.1004.*'), [string]$Hash = ('AB' * 32))
        $name = "SBE_${Vendor}_${Family}_$Version"
        $xml = New-SbeDiscovery -Entry @(@{ Vendor = $Vendor; Family = $Family; Version = $Version; Models = $Model; Solutions = $Solution; Hash = $Hash; SizeMb = 12 })
        New-SbeShare -File @{
            "SBE_Discovery_$Vendor.xml" = @{ Text = $xml; Length = 800; Hash = '' }
            "$name.xml"                 = @{ Text = '<SBEDetailedMetadata/>'; Length = 300; Hash = '' }
            "$name.zip"                 = @{ Text = ''; Length = 5000; Hash = $Hash }
        }
    }
}

Describe 'Contract' {
    It 'exports the two commands and six well formed blocking definitions' {
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationCheckDefinition'
        $script:Mod.ExportedCommands.Keys | Should -Contain 'Get-AzlVerificationAdapterDefault'
        $defs = @(& $script:Mod.ExportedCommands['Get-AzlVerificationCheckDefinition'])
        $defs.Count | Should -Be 6
        foreach ($d in $defs) {
            $d.Id | Should -Match '^SB-\d{3}$'; $d.Category | Should -Be 'nodes'; $d.Title | Should -Not -BeNullOrEmpty; $d.Source | Should -Not -BeNullOrEmpty
            $d.Blocking | Should -BeTrue; $d.Run | Should -BeOfType [scriptblock]
        }
    }
    It 'the default adapter brings the three read only share members and nothing that writes' {
        $a = & $script:Mod.ExportedCommands['Get-AzlVerificationAdapterDefault']
        @($a.Sbe.Keys | Sort-Object) | Should -Be @('GetHash', 'List', 'ReadText')
    }
}

Describe 'Dell, the lab facts' {
    It 'family 16G-45n0c-Intel 5.0.2609.1611 on AX-760 nodes for solution 12.2610.1004.50 passes every check' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare))
        foreach ($id in $script:Ids) { @($r[$id] | Where-Object Status -NE 'Passed').Count | Should -Be 0 -Because "$id : $(($r[$id] | ForEach-Object { $_.Message }) -join ' | ')" }
        @($r['SB-005']).Count | Should -Be 2
        $r['SB-004'][0].Message | Should -Match 'matches the manifest'
    }
    It 'the 17G-Intel package against AX-760 nodes FAILS SB-005 with the exact reason and names the family that fits' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare -Family '17G-Intel' -Version '5.0.2609.1715'))
        $r['SB-003'][0].Status | Should -Be 'Passed'
        $r['SB-004'][0].Status | Should -Be 'Passed'
        @($r['SB-005'] | Where-Object Status -EQ 'Failed').Count | Should -Be 2
        $m = $r['SB-005'][0].Message
        $m | Should -Match 'n01'
        $m | Should -Match 'SBE_Dell_17G-Intel_5\.0\.2609\.1715 is family 17G-Intel'
        $m | Should -Match 'AX670, AX770, PowerEdgeR670 and PowerEdgeR770'
        $m | Should -Match 'AX-760'
        $m | Should -Match 'Invalid'
        $m | Should -Match 'SBE_Dell_16G-45n0c-Intel_5\.0\.2609\.1611 \(family 16G-45n0c-Intel, 5\.0\.2609\.1611\) for AX-760, validated with solution 12\.2610\.1004\.50'
        $r['SB-005'][0].Remedy | Should -Match '16G-45n0c-Intel'
        $r['SB-006'][0].Status | Should -Be 'Passed'
    }
    It 'a share with the old 16G package: version 5.0.2609.1611 is the one for 12.2610.1004; a solution it is not validated for fails SB-006 and names the validated versions' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Solution '12.2701.1008.7')
        $r['SB-006'][0].Status | Should -Be 'Failed'
        $r['SB-006'][0].Message | Should -Match 'validated for solution 12\.\*\.1004\.\* and 12\.\*\.1003\.\*'
        $r['SB-006'][0].Message | Should -Match 'ErrorUnvalidatedSolutionAndSbeCombination'
    }
    It 'a folder with only the discovery manifest (the payload was never downloaded) fails SB-003 and names the package to download' {
        $share = New-SbeShare -File @{ 'SBE_Discovery_Dell.xml' = @{ Text = $script:DellExcerpt; Length = 1000; Hash = '' } }
        $r = Invoke-Sb (New-SbeContext $share)
        $r['SB-003'][0].Status | Should -Be 'Failed'
        $r['SB-003'][0].Message | Should -Match 'no package'
        $r['SB-003'][0].Message | Should -Match 'SBE_Dell_16G-45n0c-Intel_5\.0\.2609\.1611 \(family 16G-45n0c-Intel, 5\.0\.2609\.1611\) for AX-760, validated with solution 12\.2610\.1004\.50'
        $r['SB-004'][0].Status | Should -Be 'Skipped'
        foreach ($id in 'SB-005', 'SB-006') { $r[$id][0].Status | Should -Be 'Skipped' }
    }
    It 'with a 16G and a 17G package on the share and no family in the file, the one whose SupportedModels list the nodes is chosen' {
        $share = New-DellShare
        $share.File['SBE_Dell_17G-Intel_5.0.2609.1715.xml'] = @{ Text = '<x/>'; Length = 10; Hash = '' }
        $share.File['SBE_Dell_17G-Intel_5.0.2609.1715.zip'] = @{ Text = ''; Length = 10; Hash = (Get-SbeFixtureHash '17G-Intel') }
        $r = Invoke-Sb (New-SbeContext $share)
        $r['SB-003'][0].Message | Should -Match 'SBE_Dell_16G-45n0c-Intel_5\.0\.2609\.1611\.zip'
        $r['SB-003'][0].Message | Should -Match 'whose SupportedModels list'
        foreach ($id in $script:Ids) { @($r[$id] | Where-Object Status -NE 'Passed').Count | Should -Be 0 -Because $id }
    }
    It 'with two packages and nothing that can choose between them, SB-003 fails and says so' {
        $share = New-DellShare
        $share.File['SBE_Dell_AX-15G_5.0.2609.1511.xml'] = @{ Text = '<x/>'; Length = 10; Hash = '' }
        $share.File['SBE_Dell_AX-15G_5.0.2609.1511.zip'] = @{ Text = ''; Length = 10; Hash = 'x' }
        $r = Invoke-Sb (New-SbeContext $share -Hardware @{ vendor = 'Dell'; model = 'AX-999' } -NodeModel @{ n01 = 'AX-999'; n02 = 'AX-999' })
        $r['SB-003'][0].Status | Should -Be 'Failed'
        $r['SB-003'][0].Message | Should -Match 'more than one package'
    }
    It 'hardware.sbe.family alone chooses the package when the share holds several (the model is not needed)' {
        $share = New-DellShare
        $share.File['SBE_Dell_17G-Intel_5.0.2609.1715.xml'] = @{ Text = '<x/>'; Length = 10; Hash = '' }
        $share.File['SBE_Dell_17G-Intel_5.0.2609.1715.zip'] = @{ Text = ''; Length = 10; Hash = (Get-SbeFixtureHash '17G-Intel') }
        $r = Invoke-Sb (New-SbeContext $share -Hardware @{ vendor = 'Dell' } -Sbe @{ source_path = '\\files.example.invalid\sbe'; family = '17G-Intel' } -NodeModel @{})
        $r['SB-003'][0].Status | Should -Be 'Passed'
        $r['SB-003'][0].Message | Should -Match '17G-Intel_5\.0\.2609\.1715\.zip'
    }
    It 'hardware.sbe.family and version choose the package when the share holds several' {
        $share = New-DellShare
        $share.File['SBE_Dell_17G-Intel_5.0.2609.1715.xml'] = @{ Text = '<x/>'; Length = 10; Hash = '' }
        $share.File['SBE_Dell_17G-Intel_5.0.2609.1715.zip'] = @{ Text = ''; Length = 10; Hash = (Get-SbeFixtureHash '17G-Intel') }
        $r = Invoke-Sb (New-SbeContext $share -Sbe @{ source_path = '\\files.example.invalid\sbe'; family = '17G-Intel'; version = '5.0.2609.1715' })
        $r['SB-003'][0].Message | Should -Match 'chosen by hardware.sbe.family 17G-Intel'
        @($r['SB-005'] | Where-Object Status -EQ 'Failed').Count | Should -Be 2
    }
}

Describe 'Other vendors, made-up packages that follow the vendor name pattern' -ForEach @(
    @{ Vendor = 'HPE'; Family = 'Gen11-Standard'; Version = '4.2.2610.1001'; Model = @('ExampleDL380Gen11', 'ExampleDL145Gen11'); NodeModel = 'Example DL380 Gen11'; Other = 'ExampleDL360Gen10' }
    @{ Vendor = 'Lenovo'; Family = 'MX-Premier'; Version = '5.1.2610.2004'; Model = @('ExampleMX650V3'); NodeModel = 'Example-MX650-V3'; Other = 'ExampleMX630V2' }
    @{ Vendor = 'DataON'; Family = 'S2D-Gen7'; Version = '2.0.2610.1010'; Model = @('ExampleS2D7'); NodeModel = 'Example S2D7'; Other = 'ExampleS2D5' }
) {
    It '<Vendor> <Family>: passes for the right model and solution (names are compared as letters and digits)' {
        $share = New-VendorShare -Vendor $Vendor -Family $Family -Version $Version -Model $Model
        $r = Invoke-Sb (New-SbeContext $share -Hardware @{ vendor = $Vendor; model = $NodeModel } -NodeModel @{ n01 = $NodeModel; n02 = $NodeModel })
        foreach ($id in $script:Ids) { @($r[$id] | Where-Object Status -NE 'Passed').Count | Should -Be 0 -Because "$id : $(($r[$id] | ForEach-Object { $_.Message }) -join ' | ')" }
    }
    It '<Vendor> <Family>: fails SB-005 for a node of another model, only on that node' {
        $share = New-VendorShare -Vendor $Vendor -Family $Family -Version $Version -Model $Model
        $r = Invoke-Sb (New-SbeContext $share -Hardware @{ vendor = $Vendor; model = $NodeModel } -NodeModel @{ n01 = $NodeModel; n02 = $Other })
        ($r['SB-005'] | Where-Object Node -EQ 'n01').Status | Should -Be 'Passed'
        $bad = $r['SB-005'] | Where-Object Node -EQ 'n02'
        $bad.Status | Should -Be 'Failed'
        $bad.Message | Should -Match $Other
    }
    It '<Vendor> <Family>: fails SB-006 for a solution version the package is not validated with' {
        $share = New-VendorShare -Vendor $Vendor -Family $Family -Version $Version -Model $Model -Solution @('12.*.1002.*')
        $r = Invoke-Sb (New-SbeContext $share -Hardware @{ vendor = $Vendor; model = $NodeModel } -NodeModel @{ n01 = $NodeModel; n02 = $NodeModel })
        $r['SB-006'][0].Status | Should -Be 'Failed'
        $r['SB-006'][0].Message | Should -Match '12\.\*\.1002\.\*'
    }
}

Describe 'SB-004 consistency' {
    It 'a payload whose SHA-256 differs from the manifest fails and shows both hashes' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare -Hash ('0' * 64)))
        $r['SB-004'][0].Status | Should -Be 'Failed'
        $r['SB-004'][0].Message | Should -Match ('0' * 64)
        $r['SB-004'][0].Message | Should -Match (Get-SbeFixtureHash '16G-45n0c-Intel')
        $r['SB-004'][0].Message | Should -Match 'incomplete or modified'
    }
    It 'a hash pinned in the file that differs from the payload fails' {
        $share = New-DellShare
        $r = Invoke-Sb (New-SbeContext $share -Sbe @{ source_path = '\\files.example.invalid\sbe'; package_sha256 = ('1' * 64) })
        $r['SB-004'][0].Status | Should -Be 'Failed'
        $r['SB-004'][0].Message | Should -Match 'package_sha256'
    }
    It 'a pinned size that differs fails; the right size passes' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare -ZipLength 1000) -Sbe @{ source_path = '\\files.example.invalid\sbe'; package_size_bytes = 999 })
        $r['SB-004'][0].Status | Should -Be 'Failed'; $r['SB-004'][0].Message | Should -Match 'package_size_bytes'
        $ok = Invoke-Sb (New-SbeContext (New-DellShare -ZipLength 1000) -Sbe @{ source_path = '\\files.example.invalid\sbe'; package_size_bytes = 1000 })
        $ok['SB-004'][0].Status | Should -Be 'Passed'
    }
    It 'an empty payload fails' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare -ZipLength 0))
        $r['SB-004'][0].Status | Should -Be 'Failed'; $r['SB-004'][0].Message | Should -Match 'is empty \(0 bytes\)'
    }
    It 'a payload manifest and a payload of different releases fail SB-003 (names do not agree)' {
        $share = New-SbeShare -File @{
            'SBE_Discovery_Dell.xml'                              = @{ Text = $script:DellExcerpt; Length = 1000; Hash = '' }
            'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.xml'          = @{ Text = '<x/>'; Length = 10; Hash = '' }
            'SBE_Dell_16G-45n0c-Intel_5.0.2606.1616.zip'          = @{ Text = ''; Length = 10; Hash = 'x' }
        }
        $r = Invoke-Sb (New-SbeContext $share -Sbe @{ source_path = '\\files.example.invalid\sbe' })
        $r['SB-003'][0].Status | Should -Be 'Failed'
        $r['SB-003'][0].Message | Should -Match 'do not belong together'
    }
    It 'a package that the discovery manifest does not list fails SB-004' {
        $name = 'SBE_Dell_16G-45n0c-Intel_5.0.2699.1'
        $share = New-SbeShare -File @{
            'SBE_Discovery_Dell.xml' = @{ Text = $script:DellExcerpt; Length = 1000; Hash = '' }
            "$name.xml"              = @{ Text = '<x/>'; Length = 10; Hash = '' }
            "$name.zip"              = @{ Text = ''; Length = 10; Hash = 'x' }
        }
        $r = Invoke-Sb (New-SbeContext $share)
        $r['SB-004'][0].Status | Should -Be 'Failed'; $r['SB-004'][0].Message | Should -Match 'is not listed in SBE_Discovery_Dell.xml'
        $r['SB-005'][0].Status | Should -Be 'Skipped'
        $r['SB-006'][0].Status | Should -Be 'Skipped'
    }
    It 'a publisher, family and version in the file that are not the package on the source fail SB-003 and say what the file declares' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Sbe @{ source_path = '\\files.example.invalid\sbe'; family = '16G-45n0c-Intel'; version = '5.0.2609.1611'; publisher = 'HPE' })
        $r['SB-003'][0].Status | Should -Be 'Failed'; $r['SB-003'][0].Message | Should -Match 'declares publisher HPE family 16G-45n0c-Intel version 5.0.2609.1611'
        $r['SB-004'][0].Status | Should -Be 'Skipped'
    }
    It 'a broken discovery manifest is Skipped, never Passed' {
        $share = New-DellShare
        $share.File['SBE_Discovery_Dell.xml'].Text = '<NotAManifest/>'
        $r = Invoke-Sb (New-SbeContext $share)
        foreach ($id in 'SB-004', 'SB-005', 'SB-006') { $r[$id][0].Status | Should -Be 'Skipped' -Because $id }
    }
    It 'an unreadable payload hash is Skipped' {
        $share = New-DellShare
        $ctx = New-SbeContext $share
        $ctx.Adapters.Sbe.GetHash = { param($Request, $Name) throw 'The network name is no longer available' }
        $r = Invoke-Sb $ctx
        $r['SB-004'][0].Status | Should -Be 'Skipped'; $r['SB-004'][0].Message | Should -Match 'could not be computed'
    }
    It 'with no hash anywhere the result is a Warning, not a Passed' {
        $xml = (New-SbeDiscovery -Entry @(@{ Vendor = 'HPE'; Family = 'Gen11-Standard'; Version = '4.2.2610.1001'; Models = @('ExampleDL380Gen11'); Solutions = @('12.*.1004.*'); Hash = ''; SizeMb = 12 }))
        $share = New-SbeShare -File @{ 'SBE_Discovery_HPE.xml' = @{ Text = $xml; Length = 100; Hash = '' }; 'SBE_HPE_Gen11-Standard_4.2.2610.1001.xml' = @{ Text = '<x/>'; Length = 10; Hash = '' }; 'SBE_HPE_Gen11-Standard_4.2.2610.1001.zip' = @{ Text = ''; Length = 10; Hash = '' } }
        $r = Invoke-Sb (New-SbeContext $share -Hardware @{ vendor = 'HPE'; model = 'ExampleDL380Gen11' } -NodeModel @{ n01 = 'ExampleDL380Gen11'; n02 = 'ExampleDL380Gen11' })
        $r['SB-004'][0].Status | Should -Be 'Warning'
    }
}

Describe 'SB-002 the share' {
    It 'an unreachable share is Skipped on SB-002 and on everything after it; nothing is Passed' {
        $share = New-DellShare
        $share.Unreachable = @{ Ok = $false; ErrorKind = 'Unreachable'; Error = 'The network path was not found.'; Files = @() }
        $r = Invoke-Sb (New-SbeContext $share)
        $r['SB-001'][0].Status | Should -Be 'Passed'
        $r['SB-002'][0].Status | Should -Be 'Skipped'
        $r['SB-002'][0].Message | Should -Match 'The network path was not found'
        foreach ($id in 'SB-003', 'SB-004', 'SB-005', 'SB-006') { $r[$id][0].Status | Should -Be 'Skipped' -Because $id; $r[$id][0].Message | Should -Match 'SB-002' }
    }
    It 'a folder that does not exist on a server that answered is Failed' {
        $share = New-DellShare
        $share.Unreachable = @{ Ok = $false; ErrorKind = 'NotFound'; Error = 'Cannot find path'; Files = @() }
        (Invoke-Sb (New-SbeContext $share))['SB-002'][0].Status | Should -Be 'Failed'
    }
    It 'a refused credential is Failed with the account named in the remedy' {
        $share = New-DellShare
        $share.Unreachable = @{ Ok = $false; ErrorKind = 'AccessDenied'; Error = 'Access is denied'; Files = @() }
        $x = (Invoke-Sb (New-SbeContext $share))['SB-002'][0]
        $x.Status | Should -Be 'Failed'; $x.Remedy | Should -Match 'source_username'
    }
    It 'the credential comes from Key Vault, reaches the reader and never appears in a result' {
        $share = New-DellShare
        $pw = 'Pa55-example-NOT-real-9'
        $ctx = New-SbeContext $share -Sbe @{ source_path = '\\files.example.invalid\sbe'; source_username = 'svc-sbe-read'; source_password = 'keyvault://kv-example/sbe-reader' } -Secret @{ 'keyvault://kv-example/sbe-reader' = $pw }
        $r = Invoke-Sb $ctx
        $share.Requests[0].Username | Should -Be 'svc-sbe-read'
        $share.Requests[0].Password | Should -Be $pw
        $all = ($r.Values | ForEach-Object { $_ } | ForEach-Object { "$($_.Message) $($_.Remedy) $($_.Evidence)" }) -join ' '
        $all | Should -Not -Match ([regex]::Escape($pw))
        $r['SB-001'][0].Message | Should -Match 'svc-sbe-read'
    }
    It 'a secret that cannot be read from Key Vault is Skipped' {
        $share = New-DellShare
        $r = Invoke-Sb (New-SbeContext $share -Sbe @{ source_path = '\\files.example.invalid\sbe'; source_username = 'svc-sbe-read'; source_password = 'keyvault://kv-example/sbe-reader' })
        $r['SB-002'][0].Status | Should -Be 'Skipped'; $r['SB-002'][0].Message | Should -Match 'could not be read from Key Vault'
        $share.Requests.Count | Should -Be 0
    }
    It 'a user name without a password reference is Skipped with the reason' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Sbe @{ source_path = '\\files.example.invalid\sbe'; source_username = 'svc-sbe-read' })
        $r['SB-002'][0].Status | Should -Be 'Skipped'; $r['SB-002'][0].Message | Should -Match 'source_password'
    }
    It 'a host without the share adapter is Skipped, not Passed' {
        $ctx = New-SbeContext (New-DellShare); $ctx.Adapters.Remove('Sbe')
        $r = Invoke-Sb $ctx
        foreach ($id in 'SB-002', 'SB-003', 'SB-004', 'SB-005', 'SB-006') { $r[$id][0].Status | Should -Be 'Skipped' -Because $id }
    }
    It 'the share is listed once per run and the payload is hashed once' {
        $share = New-DellShare
        $null = Invoke-Sb (New-SbeContext $share)
        $share.Requests.Count | Should -Be 1
        $share.Hashed.Count | Should -Be 1
    }
    It 'the legacy hardware.sbe.bundle_path is read when source_path is not set' {
        $share = New-DellShare
        $r = Invoke-Sb (New-SbeContext $share -Sbe @{ bundle_path = '\\files.example.invalid\legacy' })
        $share.Requests[0].Path | Should -Be '\\files.example.invalid\legacy'
        $r['SB-001'][0].Message | Should -Match 'hardware.sbe.bundle_path'
    }
}

Describe 'SB-001 required, source configured, or not applicable with a reason' {
    It 'a Dell file with no hardware.sbe block is REQUIRED by the vendor catalog and fails: no source' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Sbe @{})
        $r['SB-001'][0].Status | Should -Be 'Failed'
        $r['SB-001'][0].Message | Should -Match 'hardware.sbe.source_path is empty'
        $r['SB-001'][0].Remedy | Should -Match 'not_applicable_reason'
        foreach ($id in 'SB-002', 'SB-003', 'SB-004', 'SB-005', 'SB-006') { $r[$id][0].Status | Should -Be 'Skipped' -Because $id }
    }
    It 'not_applicable with a reason is NotApplicable on every check and carries the reason' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Sbe @{ requirement = 'not_applicable'; not_applicable_reason = 'The cluster downloads the package with the vendor credential' })
        foreach ($id in $script:Ids) { $r[$id][0].Status | Should -Be 'NotApplicable' -Because $id }
        $r['SB-001'][0].Message | Should -Match 'vendor credential'
    }
    It 'not_applicable WITHOUT a reason fails SB-001 and checks nothing else as fine' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Sbe @{ requirement = 'not_applicable' })
        $r['SB-001'][0].Status | Should -Be 'Failed'; $r['SB-001'][0].Message | Should -Match 'not_applicable_reason'
        foreach ($id in 'SB-002', 'SB-003', 'SB-004', 'SB-005', 'SB-006') { $r[$id][0].Status | Should -Be 'Skipped' -Because $id }
    }
    It 'not_applicable beats a configured source: nothing is read' {
        $share = New-DellShare
        $null = Invoke-Sb (New-SbeContext $share -Sbe @{ source_path = '\\files.example.invalid\sbe'; requirement = 'not_applicable'; not_applicable_reason = 'No SBE exists for this model' })
        $share.Requests.Count | Should -Be 0
    }
    It 'an unknown requirement value fails' {
        (Invoke-Sb (New-SbeContext (New-DellShare) -Sbe @{ requirement = 'maybe' }))['SB-001'][0].Status | Should -Be 'Failed'
    }
    It 'a vendor the catalog says downloads automatically (Lenovo) is a Warning with no statement, and NotApplicable after' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Hardware @{ vendor = 'Lenovo'; model = 'X' } -Sbe @{})
        $r['SB-001'][0].Status | Should -Be 'Warning'
        $r['SB-001'][0].Message | Should -Match 'vendor catalog'
        foreach ($id in 'SB-002', 'SB-003') { $r[$id][0].Status | Should -Be 'NotApplicable' -Because $id }
    }
    It 'a vendor that is not in the catalog cannot decide: Skipped, never Passed' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Hardware @{ vendor = 'ExampleCorp'; model = 'X' } -Sbe @{})
        $r['SB-001'][0].Status | Should -Be 'Skipped'; $r['SB-001'][0].Remedy | Should -Match 'hardware.sbe.requirement'
    }
    It 'requirement required for a vendor that downloads automatically still needs the source' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Hardware @{ vendor = 'Lenovo'; model = 'X' } -Sbe @{ requirement = 'required' })
        $r['SB-001'][0].Status | Should -Be 'Failed'
    }
}

Describe 'SB-005 and SB-006 inputs' {
    It 'no hardware model anywhere is Skipped per node' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -Hardware @{ vendor = 'Dell' } -NodeModel @{})
        @($r['SB-005'] | Where-Object Status -EQ 'Skipped').Count | Should -Be 2
    }
    It 'the file model alone is enough when the nodes cannot be read; the unreadable node is not a failure' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -NodeModel @{})
        @($r['SB-005'] | Where-Object Status -EQ 'Passed').Count | Should -Be 2
        $r['SB-005'][0].Message | Should -Match 'hardware.model in the file'
    }
    It 'the model the node reports is checked too: a file that says AX-760 on a node that reports another model fails' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -NodeModel @{ n01 = 'AX-760'; n02 = 'AX-670' })
        ($r['SB-005'] | Where-Object Node -EQ 'n02').Status | Should -Be 'Failed'
        ($r['SB-005'] | Where-Object Node -EQ 'n02').Message | Should -Match 'AX-670 \(reported by the node\)'
    }
    It 'a manifest with no SupportedModels cannot prove the family: Skipped' {
        $xml = New-SbeDiscovery -Entry @(@{ Vendor = 'HPE'; Family = 'Gen11-Standard'; Version = '4.2.2610.1001'; Models = @(); Solutions = @('12.*.1004.*'); Hash = ('AB' * 32); SizeMb = 12 })
        $share = New-VendorShare -Vendor HPE -Family 'Gen11-Standard' -Version '4.2.2610.1001' -Model @('x')
        $share.File['SBE_Discovery_HPE.xml'].Text = $xml
        $r = Invoke-Sb (New-SbeContext $share -Hardware @{ vendor = 'HPE'; model = 'ExampleDL380Gen11' } -NodeModel @{ n01 = 'ExampleDL380Gen11'; n02 = 'ExampleDL380Gen11' })
        @($r['SB-005'] | Where-Object Status -EQ 'Skipped').Count | Should -Be 2
        $r['SB-005'][0].Message | Should -Match 'no SupportedModels'
    }
    It 'no target solution version is Skipped on SB-006' {
        $r = Invoke-Sb (New-SbeContext (New-DellShare) -NoSolution)
        $r['SB-006'][0].Status | Should -Be 'Skipped'; $r['SB-006'][0].Message | Should -Match 'target solution version'
    }
    It 'the run setting solutionVersion is the target' {
        $ctx = New-SbeContext (New-DellShare) -Solution '12.2701.1008.7'
        $ctx.Settings = @{ solutionVersion = '12.2610.1004.50' }
        (Invoke-Sb $ctx)['SB-006'][0].Status | Should -Be 'Passed'
    }
}

Describe 'The library' {
    It 'model keys ignore case and punctuation' {
        $m = Import-Module ([IO.Path]::Combine($script:VerDir, '..', '..', 'sbe', 'AzlSbePackage.psm1')) -Force -PassThru
        & $m { ConvertTo-AzlSbeModelKey 'AX-760' } | Should -Be 'ax760'
        & $m { ConvertTo-AzlSbeModelKey 'PowerEdge R760' } | Should -Be 'poweredger760'
        $p = & $m { Split-AzlSbePackageName 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip' }
        $p.Vendor | Should -Be 'Dell'; $p.Family | Should -Be '16G-45n0c-Intel'; $p.Version | Should -Be '5.0.2609.1611'
        & $m { Split-AzlSbePackageName 'SBE_Discovery_Dell.xml' } | Should -BeNullOrEmpty
        & $m { Split-AzlSbePackageName 'readme.txt' } | Should -BeNullOrEmpty
    }
    It 'the import plan lists the three files and the exact commands, and executes nothing' {
        $m = Import-Module ([IO.Path]::Combine($script:VerDir, '..', '..', 'sbe', 'AzlSbePackage.psm1')) -Force -PassThru
        $pkg = [pscustomobject]@{ DiscoveryName = 'SBE_Discovery_Dell.xml'; PayloadName = 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.xml'; ZipName = 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'; ZipLength = 99; PayloadLength = 9 }
        $plan = & $m { param($p) Get-AzlSbeImportPlan -SourcePath '\\files.example.invalid\sbe\dell\' -Package $p } $pkg
        @($plan.Files).Count | Should -Be 3
        ($plan.Commands -join "`n") | Should -Match 'Add-SolutionUpdate -SourceFolder ''C:\\ClusterStorage\\Infrastructure_1\\Shares\\SU1_Infrastructure_1\\import'''
        ($plan.Commands -join "`n") | Should -Match 'Copy-Item -LiteralPath ''\\\\files.example.invalid\\sbe\\dell\\SBE_Discovery_Dell.xml'''
        ($plan.Commands -join "`n") | Should -Match 'Get-SolutionUpdate'
    }
}
