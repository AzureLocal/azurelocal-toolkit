#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The SBE package as a requirement, seen from the OS configuration: the package is on the share the automation reads; the build-time side-load stays a separate opt-in that is off by
# default. With the switch off the Sbe step reports the package as available on the share (information); with it on the step pulls from the share, verifies hashes, and names the
# package and the node in the change details and the node report. Fakes only: no share, no node, no Azure. File names follow the vendor pattern and are made up.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/SbeShareRequirement.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transport and mock script blocks keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repo 'scripts\common\infrastructure\AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\azure-local\AzlAzure.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodePayload.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodeTransport.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlNodeConfiguration.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\common\node-configuration\AzlOsConfigurationRun.psm1') -Force
    $script:Sbe = Import-Module (Join-Path $repo 'scripts\common\sbe\AzlSbePackage.psm1') -Force -PassThru
    Import-Module powershell-yaml
    $script:Fixture = Join-Path $repo 'tests\fixtures\infrastructure.fc-san.yml'
    function Get-Infra { Import-AzlInfrastructure -Path $script:Fixture -SkipValidation }

    # New-ConfiguredState (a node that already matches its spec) is shared with NodeConfiguration.Tests.ps1: it is taken out of that file, not copied.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'tests\node-configuration\NodeConfiguration.Tests.ps1'), [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-ConfiguredState' }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))

    function Get-Spec([string]$Delivery = '', [object]$Share = $null, [object]$Bundle = $null) {
        $infra = Get-Infra
        if ($Delivery) { $infra['hardware']['sbe']['delivery'] = $Delivery } else { $null = $infra['hardware']['sbe'].Remove('delivery') }
        if ($Delivery -eq 'node_pull') { $infra['hardware']['sbe']['node_pull_url'] = 'https://files.example.invalid/sbe' }
        Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0] -SbeBundle $Bundle -SbeShare $Share
    }
    function New-Bundle {
        [pscustomobject]@{ Name = 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611'; ZipName = 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'; HashSource = 'SBE_Discovery_Dell.xml'; Source = '\\files.example.invalid\sbe\dell'
            Deployment = [ordered]@{ sbeVersion = '5.0.2609.1611'; sbeFamily = '16G-45n0c-Intel'; sbePublisher = 'Dell' }
            Files = @([pscustomobject]@{ Name = 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'; Path = '\\files.example.invalid\sbe\dell\SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'; Size = 100; Sha256 = 'AA' }
                [pscustomobject]@{ Name = 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.xml'; Path = '\\files.example.invalid\sbe\dell\SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.xml'; Size = 10; Sha256 = 'BB' }) }
    }
    function New-Share([bool]$Available = $true, [string]$Reason = '') {
        [pscustomobject]@{ Available = $Available; Path = '\\files.example.invalid\sbe\dell'; Reason = $Reason; PackageName = 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611'; ZipName = 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'; Family = '16G-45n0c-Intel'; Version = '5.0.2609.1611'; Publisher = 'Dell' }
    }
}

Describe 'Switch off: the package on the share is reported as information, nothing is side-loaded' {
    It 'adds an Info item "package available on the share, not side-loaded (switch off)" next to the Skipped item' {
        $spec = Get-Spec -Share (New-Share)
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec))
        $sbe = @($plan | Where-Object Step -EQ 'Sbe')
        @($sbe | Where-Object Action -EQ 'Skipped').Count | Should -Be 1
        $info = @($sbe | Where-Object Action -EQ 'Info')
        $info.Count | Should -Be 1
        $info[0].Item | Should -Be 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'
        $info[0].Current | Should -Be 'available on the share'
        $info[0].Desired | Should -Be 'not side-loaded (switch off)'
        $info[0].Note | Should -Match 'package available on the share, not side-loaded \(switch off\)'
        $info[0].Note | Should -Match '16G-45n0c-Intel'
        $info[0].Note | Should -Match '5\.0\.2609\.1611'
        $info[0].Note | Should -Match 'Add-SolutionUpdate'
    }
    It 'changes nothing and blocks nothing: the node still converges, no node is asked to read C:\SBE' {
        $spec = Get-Spec -Share (New-Share) -Bundle (New-Bundle)
        $spec.Sbe | Should -BeNullOrEmpty
        $spec.SbeShare.Available | Should -BeTrue
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec))
        @($plan | Where-Object { $_.Action -in 'Change', 'Blocked' }) | Should -BeNullOrEmpty
        $p = Get-AzlNodeReadParameter -Spec $spec
        foreach ($key in 'sbeFiles', 'sbeDir', 'sbeZip') { $p.ContainsKey($key) | Should -BeFalse -Because $key }
    }
    It 'a configured share whose package is not usable from this host is an Info with the reason, never a Blocked item' {
        $spec = Get-Spec -Share (New-Share -Available $false -Reason 'the package SBE_Dell_x is missing SBE_Dell_x.zip')
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec))
        $info = @($plan | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Info' })
        $info.Count | Should -Be 1
        $info[0].Note | Should -Match 'is missing SBE_Dell_x.zip'
        $info[0].Note | Should -Match 'SB-002 to SB-004'
        @($plan | Where-Object Action -EQ 'Blocked') | Should -BeNullOrEmpty
    }
    It 'with no source configured there is no Info item (the Skipped item only)' {
        $spec = Get-Spec
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec))
        @($plan | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Info' }) | Should -BeNullOrEmpty
    }
    It 'the summary says the package is available on the share and not side-loaded' {
        $spec = Get-Spec -Share (New-Share)
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec))
        $record = [ordered]@{ name = 'n1'; method = 'Ztp'; methodSource = 'x'; transport = 'WinRM'; changes = @(); pendingChanges = 0; blocked = 0; status = 'planned'; converged = $true; restarted = $false; errors = @(); plan = $plan }
        $text = Format-AzlOsConfigurationSummary -Record @($record) -Mode Plan
        $text | Should -Match 'package available on the share, not side-loaded \(switch off\): SBE_Dell_16G-45n0c-Intel_5\.0\.2609\.1611\.zip'
        $text | Should -Match 'first cluster update'
    }
}

Describe 'Switch on: the step pulls the package from the configured share and records which SBE went to which node' {
    It 'the spec names the package, its family and version, and the share it is read from' {
        $spec = Get-Spec -Delivery winrm_copy -Bundle (New-Bundle)
        $spec.Sbe.Family | Should -Be '16G-45n0c-Intel'
        $spec.Sbe.Version | Should -Be '5.0.2609.1611'
        $spec.Sbe.Publisher | Should -Be 'Dell'
        $spec.Sbe.Source | Should -Be '\\files.example.invalid\sbe\dell'
    }
    It 'winrm_copy plans a Change per file that reads from the share and checks the SHA-256 on the node (approval is the -Execute of the plan, like every node change)' {
        $spec = Get-Spec -Delivery winrm_copy -Bundle (New-Bundle)
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec))
        $changes = @($plan | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Change' })
        $changes.Count | Should -Be 2
        $changes[0].Note | Should -Match 'read from \\\\files\.example\.invalid\\sbe\\dell'
        $changes[0].Note | Should -Match 'SHA-256 is checked on the node'
        ($changes | ForEach-Object { $_.Apply.localPath }) | Should -Contain '\\files.example.invalid\sbe\dell\SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'
    }
    It 'no Info item about the share is added when the switch is on (the files are the plan)' {
        $spec = Get-Spec -Delivery winrm_copy -Bundle (New-Bundle) -Share (New-Share)
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec))
        @($plan | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Info' }) | Should -BeNullOrEmpty
    }
    It 'every change detail names the package, family, version, the share and the node; the hash is shown' {
        $t = [pscustomobject]@{ Kind = 'WinRM'; Stage = $null }
        $t.Stage = { param($Self, $Node, $LocalPath, $RemotePath, $Sha256) [pscustomobject]@{ Name = (Split-Path $LocalPath -Leaf); Url = $null } }
        $spec = Get-Spec -Delivery winrm_copy -Bundle (New-Bundle)
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec) | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Change' })
        $r = @(Send-AzlSbePackage -Spec $spec -Transport $t -Item $plan)
        $r.Count | Should -Be 2
        foreach ($x in $r) {
            $x.Status | Should -Be 'changed'
            $x.Detail | Should -Match 'SBE package SBE_Dell_16G-45n0c-Intel_5\.0\.2609\.1611 \(family 16G-45n0c-Intel, version 5\.0\.2609\.1611\) from \\\\files\.example\.invalid\\sbe\\dell to '
            $x.Detail | Should -Match 'SHA-256 verified \((AA|BB)\)'
        }
    }
    It 'a failed delivery says which package failed on which node' {
        $t = [pscustomobject]@{ Kind = 'WinRM'; Stage = $null }
        $t.Stage = { param($Self, $Node, $LocalPath, $RemotePath, $Sha256) throw 'copied to n1 but SHA-256 is AA, expected BB; the copy was removed.' }
        $spec = Get-Spec -Delivery winrm_copy -Bundle (New-Bundle)
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec) | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Change' })
        $r = @(Send-AzlSbePackage -Spec $spec -Transport $t -Item $plan)
        @($r | Where-Object Status -EQ 'failed').Count | Should -BeGreaterThan 0
        ($r | Where-Object Status -EQ 'failed' | Select-Object -First 1).Detail | Should -Match 'SHA-256 is AA, expected BB'
    }
}

Describe 'The node report says which SBE it got (Get-AzlNodeSbeReport)' {
    It 'available-not-side-loaded when the share holds it and the switch is off' {
        $spec = Get-Spec -Share (New-Share)
        $plan = @(Compare-AzlNodeState -Spec $spec -State (New-ConfiguredState $spec))
        $r = Get-AzlNodeSbeReport -Record @{ plan = $plan; changes = @() }
        $r.state | Should -Be 'available-not-side-loaded'
        $r.package | Should -Be 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'
    }
    It 'delivered, with the change details, once the files were copied' {
        $plan = @([pscustomobject]@{ Step = 'Sbe'; Item = 'C:\SBE\SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'; Action = 'Ok' })
        $changes = @([ordered]@{ pass = 0; id = 'Sbe/SBE_Dell_16G-45n0c-Intel_5.0.2609.1611.zip'; status = 'changed'; detail = 'copied [SBE package X to n1]' })
        $r = Get-AzlNodeSbeReport -Record @{ plan = $plan; changes = $changes }
        $r.state | Should -Be 'delivered'
        $r.files[0].detail | Should -Match 'to n1'
    }
    It 'not-delivered when a delivery was asked for and a file failed' {
        $plan = @([pscustomobject]@{ Step = 'Sbe'; Item = 'C:\SBE\SBE_Dell_x_1.0.zip'; Action = 'Change' })
        $changes = @([ordered]@{ pass = 0; id = 'Sbe/SBE_Dell_x_1.0.zip'; status = 'failed'; detail = 'boom' })
        (Get-AzlNodeSbeReport -Record @{ plan = $plan; changes = $changes }).state | Should -Be 'not-delivered'
    }
    It 'not-configured when the step has nothing to say' {
        (Get-AzlNodeSbeReport -Record @{ plan = @(); changes = @() }).state | Should -Be 'not-configured'
    }
}

Describe 'Get-AzlSbeBundle with a package name, and Get-AzlSbeShareInfo' {
    BeforeAll {
        function New-ShareFolder([string[]]$Family = @('16G-45n0c-Intel'), [switch]$SkipZip) {
            $dir = Join-Path $TestDrive ('share-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            $null = New-Item -ItemType Directory $dir
            $entries = foreach ($f in $Family) {
                $name = "SBE_Dell_${f}_5.0.1"
                $zip = Join-Path $dir "$name.zip"
                Set-Content -LiteralPath $zip -Value "package $f"
                Set-Content -LiteralPath (Join-Path $dir "$name.xml") -Value '<x/>'
                $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
                "<ApplicableUpdate Version=`"5.0.1`" Family=`"$f`"><UpdateInfo><UpdateName>$name</UpdateName><Publisher>Dell</Publisher><PackageHash>$hash</PackageHash><SupportedModels><SupportedModel>AX760</SupportedModel></SupportedModels></UpdateInfo></ApplicableUpdate>"
            }
            "<SBEUpdatesManifest><ManifestInfo CreationDate=`"2026-09-01`"/>$($entries -join '')</SBEUpdatesManifest>" | Set-Content -LiteralPath (Join-Path $dir 'SBE_Discovery_Dell.xml')
            if ($SkipZip) { Remove-Item (Join-Path $dir "SBE_Dell_$($Family[0])_5.0.1.zip") }
            $dir
        }
        function New-InfraWith([string]$Path, [string]$Model = 'AX-760') {
            [ordered]@{ hardware = [ordered]@{ vendor = 'Dell'; model = $Model; sbe = [ordered]@{ source_path = $Path } } }
        }
    }
    It 'takes the named package out of a share that holds two, and hashes it' {
        $dir = New-ShareFolder -Family '16G-45n0c-Intel', '17G-Intel'
        { Get-AzlSbeBundle -Path $dir -OfflineManifest } | Should -Throw '*Expected one*'
        $b = Get-AzlSbeBundle -Path $dir -OfflineManifest -PackageName 'SBE_Dell_17G-Intel_5.0.1'
        $b.ZipName | Should -Be 'SBE_Dell_17G-Intel_5.0.1.zip'
        $b.Source | Should -Be $dir
        $b.Deployment.sbeFamily | Should -Be '17G-Intel'
    }
    It 'a hash that differs from the manifest throws (the copy is verified at the source before anything is sent)' {
        $dir = New-ShareFolder
        Set-Content -LiteralPath (Join-Path $dir 'SBE_Dell_16G-45n0c-Intel_5.0.1.zip') -Value 'tampered'
        { Get-AzlSbeBundle -Path $dir -OfflineManifest } | Should -Throw '*SHA-256*'
    }
    It 'share info: available, with the package, family and version; reads the share without hashing' {
        $dir = New-ShareFolder
        $info = & $script:Sbe { param($i) Get-AzlSbeShareInfo -Infrastructure $i } (New-InfraWith $dir)
        $info.Available | Should -BeTrue
        $info.PackageName | Should -Be 'SBE_Dell_16G-45n0c-Intel_5.0.1'
        $info.Family | Should -Be '16G-45n0c-Intel'
        $info.Version | Should -Be '5.0.1'
        $info.Path | Should -Be $dir
    }
    It 'share info: a missing payload is not available and names the file' {
        $dir = New-ShareFolder -SkipZip
        $info = & $script:Sbe { param($i) Get-AzlSbeShareInfo -Infrastructure $i } (New-InfraWith $dir)
        $info.Available | Should -BeFalse
        $info.Reason | Should -Match 'SBE_Dell_16G-45n0c-Intel_5\.0\.1\.zip'
    }
    It 'share info: a share that cannot be listed is not available and carries the reason' {
        $info = & $script:Sbe { param($i) Get-AzlSbeShareInfo -Infrastructure $i } (New-InfraWith (Join-Path $TestDrive 'no-such-folder'))
        $info.Available | Should -BeFalse
        $info.Reason | Should -Not -BeNullOrEmpty
    }
    It 'share info: no source configured gives nothing' {
        (& $script:Sbe { param($i) Get-AzlSbeShareInfo -Infrastructure $i } ([ordered]@{ hardware = [ordered]@{ vendor = 'Dell' } })) | Should -BeNullOrEmpty
    }
    It 'mounting a source without a credential returns the path as it is and maps nothing' {
        $m = & $script:Sbe { param($i) Mount-AzlSbeSource -Source (Get-AzlSbeSource -Infrastructure $i) } (New-InfraWith '\\files.example.invalid\sbe\dell')
        $m.Path | Should -Be '\\files.example.invalid\sbe\dell'
        $m.Drive | Should -Be ''
    }
}
