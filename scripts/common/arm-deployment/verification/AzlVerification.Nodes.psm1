#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-cluster verification, categories NODES (ND-) and READINESS (RD-): what a node must be before the Azure Local deployment starts,
    and Microsoft's own Environment Checker validators where the module is installed on the nodes.

.DESCRIPTION
    Harvested, not written from scratch. Sources, per check, are in the check definitions; in short:
      azl-toolkit 04-cluster-deployment/phase-02-os-installation Test-OsDeployment.ps1 (OS, domain, features),
      phase-03-os-configuration task-06 Test-DnsClientConfig / Test-DnsConfiguration, task-07 NTP, task-10 hostname,
      task-13 Invoke-Phase03Verification-Orchestrated.ps1 (the per node verification block), phase-04-arc-registration
      Invoke-ArcPrerequisites-Orchestrated.ps1 (Environment Checker run), the node payload of the OS configuration
      (AzlNodePayload.psm1) for the shape of the reads, Microsoft Learn (azloc-2610) deployment-prerequisites,
      system-requirements-23h2, deployment-install-os and manage/use-environment-checker.

    Contract with the engine: Get-AzlVerificationCheckDefinition and Get-AzlVerificationAdapterDefault (see AzlVerification.NodeCommon.psm1).
    Each check: Id, Category, Title, Source, Blocking, Applies = { param($Context) }, Run = { param($Context) } returning results
    @{ Status; Node; Message; Remedy; Evidence }. Read only. No secret is ever put in a message or in evidence.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AzlVerification.NodeCommon.psm1'))

$script:Src = Get-AzlVerConstant Source
$script:EcInstallNode = 'On the node, in Windows PowerShell 5.1: Install-Module -Name AzStackHci.EnvironmentChecker -Repository PSGallery -Force (offline: Save-Module -Name AzStackHci.EnvironmentChecker -Path <folder> on a connected machine, copy it to the node). After the verification, as Learn says, remove it before the deployment: Remove-Module AzStackHci.EnvironmentChecker -Force; Get-Module AzStackHci.EnvironmentChecker -ListAvailable | Where-Object {$_.Path -like "*$($_.Version)*"} | Uninstall-Module -Force'

function Get-AzlVerBootDisk {
    # The boot disk(s) of a node from the Get-Disk rows: IsBoot (BOSS, M.2 or the OS drive).
    param($Disk)
    @(ConvertTo-AzlVerList $Disk | Where-Object { [bool](Get-AzlProp $_ 'boot' $false) })
}

# =====================================================================================================================
# NODES
# =====================================================================================================================

function Get-AzlVerificationCheckDefinition {
    <#
    .SYNOPSIS
        The check definitions of the NODES and READINESS categories (ND-001 to ND-012, RD-001 to RD-007).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The per node script blocks take the one signature (Name, Data, NodeInfo) whether a check needs all three or not.')]
    [CmdletBinding()]
    param()
    $defs = [System.Collections.Generic.List[object]]::new()

    $defs.Add((New-AzlVerDefinition -Id 'ND-001' -Category nodes -Title 'Every node answers over WinRM and the read of it is complete' `
                -Source "$($script:Src.Install); azl-toolkit phase-02-os-installation Test-OsDeployment.ps1 (reachable)" -Run {
                param($Context)
                $nodes = @(Get-AzlVerNodeList $Context)
                if (-not $nodes.Count) { return New-AzlVerResult Skipped 'The file lists no nodes (nodes[].name).' 'Fill nodes[] in the infrastructure file.' }
                foreach ($n in $nodes) {
                    $read = Get-AzlVerNodeData -Context $Context -Node $n.Name -Section 'GetSnapshot'
                    if (-not $read.Ok) {
                        if ($read.PSObject.Properties['NoAdapter']) { New-AzlVerResult Skipped "$($n.Name) was not read: $($read.Error)" 'Run the verification from the host that reaches the nodes over WinRM.' -Node $n.Name }
                        else { New-AzlVerResult Failed "$($n.Name) could not be read: $($read.Error) Learn: the local administrator credentials must be identical on all machines. Every node check is Skipped for this node." "Check WinRM on the node (Test-WSMan $($n.Name)), the management address in the file, the firewall, and that the local administrator password in Key Vault is the node's." -Node $n.Name -Evidence $read.Error }
                        continue
                    }
                    $D = $read.Data; $Name = $n.Name
                    $err = Get-AzlProp $D 'err' $null
                    $sections = @()
                    if ($err -is [System.Collections.IDictionary]) { $sections = @($err.Keys) }
                    elseif ($err) { $sections = @($err.PSObject.Properties | ForEach-Object { $_.Name }) }
                    $build = [string](Get-AzlProp $D 'os.build' 'unknown')
                    if ($sections.Count) { New-AzlVerResult Failed "$Name answered (OS $build) but these parts of the read failed: $(Join-AzlVerList $sections). Checks that need them are Skipped for this node, never read as fine." "On the node run the failing read by hand (Get-Disk, Get-NetAdapter, Get-WindowsFeature, mpclaim) and fix what stops it." -Node $Name -Evidence ($sections -join ',') }
                    else { New-AzlVerResult Passed "$Name answered over WinRM (OS $build)." -Node $Name -Evidence "os.build=$build" }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-002' -Category nodes -Title 'Computer name equals the node name in the file and is a valid name' `
                -Source "$($script:Src.Install); azl-toolkit phase-03-os-configuration task-10 Set-NodeHostname / task-13 Task10_Hostname" -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetOsBuild' -Body {
                    param($Name, $D, $N)
                    $actual = [string](Get-AzlProp $D 'host' '')
                    $problems = @()
                    if ($actual -ine $Name) { $problems += "its computer name is '$actual', the file says '$Name'" }
                    if ($Name -match '_') { $problems += 'the name contains an underscore (Learn: not supported, it breaks storage path creation)' }
                    if ($Name.Length -gt 15) { $problems += 'the name is longer than 15 characters (NetBIOS)' }
                    if ($problems) { New-AzlVerResult Failed "${Name}: $($problems -join '; ')." "On the node: Rename-Computer -NewName $Name -Restart (or the OS configuration Hostname step)." -Node $Name -Evidence "host=$actual" }
                    else { New-AzlVerResult Passed "The computer name of $Name matches the file and is valid." -Node $Name -Evidence "host=$actual" }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-003' -Category nodes -Title 'All nodes run exactly the same OS build' `
                -Source "https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610; $($script:Src.EnvChecker) (software validator: same OS version)" -Run {
                param($Context)
                $all = Get-AzlVerAllNodeData -Context $Context -Section 'GetOsBuild'
                if (-not $all.Data.Count) { Stop-AzlVerSkip "No node could be read (ND-001): $(Join-AzlVerList @($all.Unread.Keys))." 'Make the nodes reachable, then run the verification again.' }
                $builds = [ordered]@{}
                foreach ($k in $all.Data.Keys) { $builds[$k] = [string](Get-AzlProp $all.Data[$k] 'os.build' '') }
                $evidence = (($builds.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
                $distinct = @($builds.Values | Where-Object { $_ } | Select-Object -Unique)
                if ($distinct.Count -gt 1) { return New-AzlVerResult Failed "The nodes run different OS builds: $evidence. Microsoft requires the same exact OS version on every node." 'Install the same build on every node (same ISO or the same updates), then run the verification again.' -Evidence $evidence }
                if ($all.Unread.Count) { return New-AzlVerResult Skipped "Every node that could be read runs $($distinct[0]), but $(Join-AzlVerList @($all.Unread.Keys)) could not be read (ND-001)." 'Make those nodes reachable, then run the verification again.' -Evidence $evidence }
                New-AzlVerResult Passed "Every node runs OS build $($distinct[0])." -Evidence $evidence
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-004' -Category nodes -Title 'The OS build is the one the target solution version ships with' `
                -Source "https://learn.microsoft.com/en-us/azure/azure-local/whats-new?view=azloc-2610; config/known-issues/arm-deployment.json (unsupported-os-version)" -Run {
                param($Context)
                $target = Get-AzlVerTargetSolution $Context
                if (-not $target) { return New-AzlVerResult NotApplicable 'No target solution version is declared (Settings.solutionVersion, the ZTP handoff or provisioning.os_version), so the OS build is not compared with one.' }
                $line = (($target.Split('.') | Select-Object -First 3) -join '.')
                Invoke-AzlVerPerNode -Context $Context -Section 'GetOsBuild' -Body {
                    param($Name, $D, $N)
                    $build = [string](Get-AzlProp $D 'os.build' '')
                    $map = ConvertFrom-AzlVerOsBuild $build
                    if (-not $map) { New-AzlVerResult Skipped "$Name runs OS build $build, which is not in the table of builds seen with a solution version, so it cannot be compared with the target $target. Azure refuses an OS build it does not accept for new deployments (Unsupported OS version)." "Install the OS build of solution $target (the lab: solution 12.2610.1004.50 is OS build 26100.33650)." -Node $Name -Evidence "os.build=$build" }
                    elseif ($map.Version -eq $line) { New-AzlVerResult Passed "$Name's OS build $build ships with solution $($map.Version), the line of the target $target." -Node $Name -Evidence "os.build=$build target=$target" }
                    else { New-AzlVerResult Failed "$Name's OS build $build ships with solution $($map.Version), but the deployment targets $target." "Install the OS build of solution $target on $Name, or change provisioning.os_version." -Node $Name -Evidence "os.build=$build target=$target" }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-005' -Category nodes -Title 'Time: a real NTP source (not the CMOS clock), the same on every node, in step with this host' `
                -Source "$($script:Src.Install); azl-toolkit phase-03-os-configuration task-07 Set-NTPConfiguration / task-13 Task07_NTP; Learn software validator (same NTP on all nodes)" -Run {
                param($Context)
                $expected = @(ConvertTo-AzlVerList (Get-AzlProp (Get-AzlVerInfra $Context) 'networking.ntp_servers' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
                $maxSkew = [double](Get-AzlVerSetting $Context 'verificationMaxClockSkewSeconds')
                $now = Get-AzlVerNow $Context
                $peerSets = [ordered]@{}
                Invoke-AzlVerPerNode -Context $Context -Section 'GetTime' -Body {
                    param($Name, $D, $N)
                    $src = [string](Get-AzlProp $D 'time.src' '')
                    $rawPeers = [string](Get-AzlProp $D 'time.peers' '')
                    $peers = @($rawPeers -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -replace ',0x[0-9a-fA-F]+$', '').ToLowerInvariant() } | Sort-Object -Unique)
                    $peerSets[$Name] = ($peers -join ' ')
                    $problems = @(); $warnings = @()
                    if ($src -match '(?i)Local CMOS Clock|Free-running System Clock') { $problems += "the time source is '$src' (Learn: validate the machine is not using the local CMOS clock)" }
                    $utc = [datetime]::MinValue
                    if ([datetime]::TryParse([string](Get-AzlProp $D 'utc' ''), [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$utc)) {
                        $skew = [math]::Abs(($utc - $now).TotalSeconds)
                        if ($skew -gt $maxSkew) { $problems += "its clock differs from this host by $([math]::Round($skew)) seconds (Kerberos allows 300)" }
                        elseif ($skew -gt 60) { $warnings += "its clock differs from this host by $([math]::Round($skew)) seconds" }
                    }
                    if ($expected.Count -and $peers.Count -and @($expected | Where-Object { $_ -notin $peers }).Count) { $warnings += "its NTP peers ($($peers -join ', ')) do not include all of networking.ntp_servers ($($expected -join ', ')); a domain-joined node syncs from the domain hierarchy instead" }
                    if ($rawPeers -and $rawPeers -notmatch '0x8' -and $src -notmatch 'Local CMOS') { $warnings += 'the NTP peers carry no ,0x8 flag (Learn: w32tm /config /manualpeerlist:"server,0x8" /syncfromflags:manual /update)' }
                    if ($problems) { New-AzlVerResult Failed "${Name}: $($problems -join '; ')." 'On the node: w32tm /config /manualpeerlist:"<ntp server>,0x8" /syncfromflags:manual /update; w32tm /resync (or the OS configuration Time step).' -Node $Name -Evidence "source=$src peers=$($peers -join ',')" }
                    elseif ($warnings) { New-AzlVerResult Warning "${Name}: $($warnings -join '; ')." 'On the node: w32tm /config /manualpeerlist:"<ntp server>,0x8" /syncfromflags:manual /update' -Node $Name -Evidence "source=$src peers=$($peers -join ',')" }
                    else { New-AzlVerResult Passed "$Name syncs from '$src' with peers $($peers -join ', ') and its clock is in step." -Node $Name -Evidence "source=$src" }
                }
                if (@($peerSets.Values | Select-Object -Unique).Count -gt 1) { New-AzlVerResult Failed ('The nodes use different NTP configurations: ' + (($peerSets.GetEnumerator() | ForEach-Object { "$($_.Key) = [$($_.Value)]" }) -join '; ') + '. Learn: all nodes must be configured with the same, valid NTP server.') 'Configure the same time source on every node.' }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-006' -Category nodes -Title 'DNS client: the nodes use the DNS servers of the file, the same on every node, none of them public' `
                -Source "$($script:Src.NetPlan) (DNS server considerations); azl-toolkit phase-03-os-configuration task-06 Test-DnsClientConfig.ps1" -Run {
                param($Context)
                $expected = @(ConvertTo-AzlVerList (Get-AzlProp (Get-AzlVerInfra $Context) 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ } | Sort-Object)
                $public = Get-AzlVerConstant PublicDns
                $sets = [ordered]@{}
                Invoke-AzlVerPerNode -Context $Context -Section 'GetDns' -Body {
                    param($Name, $D, $N)
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $rows = @(ConvertTo-AzlVerList (Get-AzlProp $D 'dns' @()))
                    $withGw = @($nics | Where-Object { @(ConvertTo-AzlVerList (Get-AzlProp $_ 'gw' @())).Count })
                    $take = if ($withGw.Count) { @($withGw | ForEach-Object { $i = $_.idx; $rows | Where-Object { $_.idx -eq $i } }) } else { $rows }
                    $servers = @($take | ForEach-Object { ConvertTo-AzlVerList (Get-AzlProp $_ 'servers' @()) } | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -notlike '127.*' -and $_ -notlike '169.254.*' } | Select-Object -Unique | Sort-Object)
                    $sets[$Name] = ($servers -join ',')
                    $pub = @($servers | Where-Object { $_ -in $public })
                    if ($pub) { New-AzlVerResult Failed "$Name uses the public resolver $(Join-AzlVerList $pub). Learn: all DNS servers must resolve the on-premises domain; public DNS such as 8.8.8.8 is not supported, and DNS can't be changed after the deployment." 'Set the DNS servers of the domain (networking.management.dns_servers) with the OS configuration Dns step.' -Node $Name -Evidence "dns=$($servers -join ',')" }
                    elseif ($expected.Count -and (($servers -join ',') -ne ($expected -join ','))) { New-AzlVerResult Failed "$Name uses DNS servers [$($servers -join ', ')], the file says [$($expected -join ', ')]. Learn: the DNS servers of the nodes and of the infrastructure range must be the same and can't be changed after the deployment." 'Run the OS configuration (Dns step) so the node uses networking.management.dns_servers.' -Node $Name -Evidence "dns=$($servers -join ',')" }
                    elseif (-not $servers.Count) { New-AzlVerResult Failed "$Name has no DNS server on the adapter with the default gateway." 'Run the OS configuration Dns step.' -Node $Name }
                    else { New-AzlVerResult Passed "$Name uses DNS servers $($servers -join ', ') (the file's)." -Node $Name -Evidence "dns=$($servers -join ',')" }
                }
                if (@($sets.Values | Select-Object -Unique).Count -gt 1) { New-AzlVerResult Failed ('The nodes use different DNS servers: ' + (($sets.GetEnumerator() | ForEach-Object { "$($_.Key) = [$($_.Value)]" }) -join '; ') + '. Learn: DNS servers across all the nodes must be the same.') 'Run the OS configuration (Dns step).' }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-007' -Category nodes -Title 'No pending restart on any node' `
                -Source "$($script:Src.Install); azl-toolkit phase-04-arc-registration pre-registration checks" -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetReboot' -Body {
                    param($Name, $D, $N)
                    $r = Get-AzlProp $D 'reboot' $null
                    $why = @()
                    if ([bool](Get-AzlProp $r 'cbs' $false)) { $why += 'component servicing (RebootPending)' }
                    if ([bool](Get-AzlProp $r 'wu' $false)) { $why += 'Windows Update (RebootRequired)' }
                    if ([bool](Get-AzlProp $r 'rename' $false)) { $why += 'a computer rename' }
                    if ($why) { New-AzlVerResult Failed "$Name is waiting for a restart: $(Join-AzlVerList $why). A restart that lands during the deployment fails it." "Restart-Computer -ComputerName $Name -Force, then run the verification again." -Node $Name -Evidence ($why -join ',') }
                    elseif ([bool](Get-AzlProp $r 'files' $false)) { New-AzlVerResult Warning "$Name has PendingFileRenameOperations; this is usually harmless but a restart clears it." "Restart-Computer -ComputerName $Name" -Node $Name -Evidence 'PendingFileRenameOperations' }
                    else { New-AzlVerResult Passed "$Name has no pending restart." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-008' -Category nodes -Title 'Processors and memory: identical processors, at least the minimum memory, virtualization on, at least what the file declares' `
                -Source "$($script:Src.SysReq) (Machine and storage requirements); Learn hardware validator (Processor, Memory)" -Run {
                param($Context)
                $minGib = [double](Get-AzlVerSetting $Context 'verificationMinMemoryGiB')
                $wantCores = [int](Get-AzlProp (Get-AzlVerInfra $Context) 'hardware.cpu_cores' 0)
                $wantGib = [int](Get-AzlProp (Get-AzlVerInfra $Context) 'hardware.memory_gib' 0)
                $sigs = [ordered]@{}; $mems = [ordered]@{}
                Invoke-AzlVerPerNode -Context $Context -Section 'GetHardware' -Body {
                    param($Name, $D, $N)
                    $cpu = @(ConvertTo-AzlVerList (Get-AzlProp $D 'cpu' @()))
                    $memBytes = [int64](Get-AzlProp $D 'cs.memBytes' 0)
                    $sigs[$Name] = (@($cpu | ForEach-Object { "$($_.caption)|$($_.family)|$($_.manufacturer)|$($_.maxClock)|$($_.cores)|$($_.logical)|$($_.threads)" }) -join ';')
                    $mems[$Name] = (@(ConvertTo-AzlVerList (Get-AzlProp $D 'mem' @())) | Measure-Object -Sum).Sum
                    $gib = [math]::Round($memBytes / 1GB, 1)
                    $problems = @(); $warnings = @()
                    if ($gib -lt ($minGib - 2)) { $problems += "it has $gib GiB memory (Learn: at least $minGib GB per machine)" }
                    if ($cpu.Count -eq 0) { $problems += 'no processor was reported' }
                    elseif (@($cpu | Where-Object { -not [bool](Get-AzlProp $_ 'vt' $false) }).Count -and -not [bool](Get-AzlProp $D 'cs.hypervisor' $false)) { $problems += 'hardware virtualization (Intel VT or AMD-V) is not enabled in the BIOS' }
                    $logical = (@($cpu | ForEach-Object { [int](Get-AzlProp $_ 'logical' 0) }) | Measure-Object -Sum).Sum
                    if ($wantCores -gt 0 -and $logical -gt 0 -and $logical -lt $wantCores) { $warnings += "it has $logical logical processors, the file declares hardware.cpu_cores $wantCores" }
                    if ($wantGib -gt 0 -and $gib -lt ($wantGib * 0.9)) { $warnings += "it has $gib GiB memory, the file declares hardware.memory_gib $wantGib" }
                    if ($problems) { New-AzlVerResult Failed "${Name}: $($problems -join '; ')." 'Fix the hardware or the BIOS setting (Learn: System requirements, Machine and storage requirements).' -Node $Name -Evidence "mem=${gib}GiB logical=$logical" }
                    elseif ($warnings) { New-AzlVerResult Warning "${Name}: $($warnings -join '; ')." 'Check hardware.cpu_cores and hardware.memory_gib in the file against the node.' -Node $Name -Evidence "mem=${gib}GiB logical=$logical" }
                    else { New-AzlVerResult Passed "$Name has $gib GiB memory, $logical logical processors and virtualization enabled." -Node $Name -Evidence "mem=${gib}GiB logical=$logical" }
                }
                if (@($sigs.Values | Select-Object -Unique).Count -gt 1) { New-AzlVerResult Failed ('The processors differ between the nodes (Learn: Caption, Family, Manufacturer, MaxClockSpeed, NumberOfEnabledCore, NumberOfLogicalProcessors and ThreadCount must match): ' + (($sigs.GetEnumerator() | ForEach-Object { "$($_.Key) = [$($_.Value)]" }) -join '; ')) 'Use machines with the same processor model and the same core settings in the BIOS.' }
                if (@($mems.Values | Select-Object -Unique).Count -gt 1) { New-AzlVerResult Warning ('The installed memory differs between the nodes: ' + (($mems.GetEnumerator() | ForEach-Object { "$($_.Key) = $([math]::Round($_.Value / 1GB, 1)) GiB" }) -join ', ') + '. The hardware validator warns about inconsistent memory.') 'Use the same memory on every node.' }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-009' -Category nodes -Title 'Boot disk is at least the minimum size (the BOSS card is the boot device)' `
                -Source "$($script:Src.SysReq) (Boot drive: at least 200 GB)" -Run {
                param($Context)
                $minGb = [double](Get-AzlVerSetting $Context 'verificationMinBootDiskGB')
                Invoke-AzlVerPerNode -Context $Context -Section 'GetDisks' -Body {
                    param($Name, $D, $N)
                    $boot = @(Get-AzlVerBootDisk (Get-AzlProp $D 'disks' @()))
                    if (-not $boot.Count) { return New-AzlVerResult Failed "$Name reports no boot disk (Get-Disk IsBoot)." 'Check the node: Get-Disk | Where-Object IsBoot' -Node $Name }
                    $size = [int64](Get-AzlProp $boot[0] 'size' 0)
                    $gb = [math]::Round($size / 1e9)
                    if ($size -lt ($minGb * 1e9 * 0.95)) { New-AzlVerResult Failed "The boot disk of $Name ($(Get-AzlProp $boot[0] 'name' 'disk')) is $gb GB. Learn: a minimum of $minGb GB." "Use a boot drive of at least $minGb GB (BOSS virtual disk)." -Node $Name -Evidence "boot=${gb}GB" }
                    else { New-AzlVerResult Passed "The boot disk of $Name is $gb GB." -Node $Name -Evidence "boot=${gb}GB" }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-010' -Category nodes -Title 'Required Windows features are installed (Hyper-V, Failover Clustering, Data Center Bridging, Network ATC, BitLocker)' `
                -Source "$($script:Src.SysReq); azl-toolkit phase-02-os-installation Test-OsDeployment.ps1 (Get-RequiredWindowsFeatures)" -Run {
                param($Context)
                $required = Get-AzlVerConstant RequiredFeature
                $advised = Get-AzlVerConstant AdvisedFeature
                Invoke-AzlVerPerNode -Context $Context -Section 'GetFeatures' -Body {
                    param($Name, $D, $N)
                    $rows = @(ConvertTo-AzlVerList (Get-AzlProp $D 'features' @()))
                    $off = @($rows | Where-Object { $_.n -in $required -and $_.found -and $_.installed -eq $false } | ForEach-Object { $_.n })
                    $unknown = @($rows | Where-Object { $_.n -in $required -and -not $_.found } | ForEach-Object { $_.n })
                    $advisedOff = @($rows | Where-Object { $_.n -in $advised -and $_.found -and $_.installed -eq $false } | ForEach-Object { $_.n })
                    if ($off) { New-AzlVerResult Failed "On $Name these Windows features are not installed: $(Join-AzlVerList $off)." ('On the node: Install-WindowsFeature -Name ' + ($off -join ',') + ' -IncludeManagementTools (restart if asked)') -Node $Name -Evidence ($off -join ',') }
                    elseif ($rows.Count -eq 0 -or $unknown.Count -eq $required.Count) { New-AzlVerResult Skipped "$Name does not list any of the features by name (Get-WindowsFeature is not available), so they were not verified." 'Verify by hand: Get-WindowsFeature Hyper-V, Failover-Clustering, Data-Center-Bridging, NetworkATC, BitLocker.' -Node $Name }
                    elseif ($unknown) { New-AzlVerResult Skipped "$Name does not list $(Join-AzlVerList $unknown) by that name." 'Verify the feature by hand.' -Node $Name -Evidence ($unknown -join ',') }
                    elseif ($advisedOff) { New-AzlVerResult Warning "$Name lacks the management features $(Join-AzlVerList $advisedOff) (the earlier toolkit verification expected them)." ('On the node: Install-WindowsFeature -Name ' + ($advisedOff -join ',') + ' -IncludeManagementTools') -Node $Name -Evidence ($advisedOff -join ',') }
                    else { New-AzlVerResult Passed "$Name has Hyper-V, Failover Clustering, Data Center Bridging, Network ATC and BitLocker installed." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-011' -Category nodes -Title 'Secure Boot on, TPM 2.0 present and ready, the same BIOS version on all nodes' `
                -Source "$($script:Src.SysReq); $($script:Src.EnvChecker) (hardware validator: Firmware tests)" -Run {
                param($Context)
                $bios = [ordered]@{}
                Invoke-AzlVerPerNode -Context $Context -Section 'GetHardware' -Body {
                    param($Name, $D, $N)
                    $fw = Get-AzlProp $D 'fw' $null
                    $bios[$Name] = [string](Get-AzlProp $fw 'biosVersion' '')
                    $problems = @(); $warnings = @()
                    $sb = Get-AzlProp $fw 'secureBoot' $null
                    if ($sb -eq $false) { $problems += 'Secure Boot is off (hardware validator: Critical)' } elseif ($null -eq $sb) { $warnings += 'Secure Boot state could not be read (legacy BIOS mode?)' }
                    $present = Get-AzlProp $fw 'tpmPresent' $null; $ready = Get-AzlProp $fw 'tpmReady' $null
                    if ($present -eq $false) { $problems += 'no TPM is present' }
                    elseif ($ready -eq $false) { $problems += 'the TPM is present but not ready' }
                    elseif ($null -eq $present) { $warnings += 'the TPM state could not be read' }
                    $spec = [string](Get-AzlProp $fw 'tpmSpec' '')
                    if ($spec -and $spec -notmatch '^2\.0') { $problems += "the TPM specification is '$spec', Azure Local needs TPM 2.0" }
                    if ($problems) { New-AzlVerResult Failed "${Name}: $($problems -join '; ')." 'Enable UEFI Secure Boot and TPM 2.0 in the BIOS (iDRAC: System BIOS > System Security).' -Node $Name -Evidence "secureBoot=$sb tpmSpec=$spec" }
                    elseif ($warnings) { New-AzlVerResult Warning "${Name}: $($warnings -join '; ')." 'Check Secure Boot and the TPM on the node (Confirm-SecureBootUEFI; Get-Tpm).' -Node $Name }
                    else { New-AzlVerResult Passed "$Name has Secure Boot on and a ready TPM $spec (BIOS $($bios[$Name]))." -Node $Name -Evidence "bios=$($bios[$Name])" }
                }
                if (@($bios.Values | Where-Object { $_ } | Select-Object -Unique).Count -gt 1) { New-AzlVerResult Warning ('The BIOS versions differ between the nodes (hardware validator: BIOS for consistent properties): ' + (($bios.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join ', ')) 'Update the BIOS so that every node has the same version.' }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'ND-012' -Category nodes -Title 'No node is already a member of a cluster' `
                -Source "$($script:Src.Install) (clean the machines before the deployment); azl-toolkit phase-03-os-configuration task-11 Clear-StorageConfiguration" -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetDisks' -Body {
                    param($Name, $D, $N)
                    $c = Get-AzlProp $D 'cluster' $null
                    $svc = [string](Get-AzlProp $c 'svc' ''); $cn = [string](Get-AzlProp $c 'name' '')
                    if ($svc -eq 'Running' -and $cn) { New-AzlVerResult Failed "$Name is already a member of the cluster '$cn' (the cluster service is running). A deployment needs clean machines." 'On the node: Clear-ClusterNode -Force, then clean the drives (the OS configuration ClearStorage step); or reinstall the OS.' -Node $Name -Evidence "ClusSvc=$svc cluster=$cn" }
                    else { New-AzlVerResult Passed "$Name is not part of a running cluster." -Node $Name -Evidence "ClusSvc=$svc" }
                }
            }))

    # ---- READINESS -----------------------------------------------------------------------------------------------------
    $defs.Add((New-AzlVerDefinition -Id 'RD-001' -Category readiness -Title 'The Environment Checker module (AzStackHci.EnvironmentChecker) is installed on every node' `
                -Source "$($script:Src.EnvChecker) (Install Environment Checker); $($script:Src.DocsEnv)" -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetEnvChecker' -Body {
                    param($Name, $D, $N)
                    $ec = @(ConvertTo-AzlVerList (Get-AzlProp $D 'ec' @()))
                    if ($ec.Count) { New-AzlVerResult Passed "$Name has AzStackHci.EnvironmentChecker $(Join-AzlVerList @($ec | ForEach-Object { $_.version })). Learn: remove it before the deployment starts, to avoid conflicts." -Node $Name -Evidence "version=$(@($ec | ForEach-Object { $_.version }) -join ',')" }
                    else { New-AzlVerResult Skipped "$Name does not have the module AzStackHci.EnvironmentChecker, so Microsoft's own validators did not run there." $script:EcInstallNode -Node $Name }
                }
            }))

    $validators = @(
        @{ Id = 'RD-002'; Name = 'Connectivity'; Title = 'Environment Checker, connectivity validator: outbound connectivity to the Azure endpoints (Invoke-AzStackHciConnectivityValidation)'; Blocking = $true; Applies = { param($Context) $true } }
        @{ Id = 'RD-003'; Name = 'Hardware'; Title = 'Environment Checker, hardware validator: processors, memory, adapters, disks, no storage pool, Secure Boot, TPM 2.0 (Invoke-AzStackHciHardwareValidation)'; Blocking = $true; Applies = { param($Context) $true } }
        @{ Id = 'RD-004'; Name = 'Software'; Title = 'Environment Checker, software validator: same NTP, same OS version, resolvable local Administrators (Invoke-AzStackHciSoftwareValidation -Exclude Test-IsNotPartofDomain)'; Blocking = $true; Applies = { param($Context) $true } }
        @{ Id = 'RD-005'; Name = 'Network'; Title = 'Environment Checker, network validator: IP ranges free, adapters, storage connection (Invoke-AzStackHciNetworkValidation)'; Blocking = $true; Applies = { param($Context) $true } }
        @{ Id = 'RD-006'; Name = 'ActiveDirectory'; Title = 'Environment Checker, Active Directory validator (Invoke-AzStackHciExternalActiveDirectoryValidation)'; Blocking = $false
            Applies = { param($Context) if ([string](Get-AzlProp (Get-AzlVerInfra $Context) 'scenario.identity' 'active_directory') -eq 'active_directory') { $true } else { $false } } }
        @{ Id = 'RD-007'; Name = 'ArcIntegration'; Title = 'Environment Checker, Arc integration validator: no name clash, region valid, resource and role assignment limits (Invoke-AzStackHciArcIntegrationValidation)'; Blocking = $false; Applies = { param($Context) $true } }
    )
    foreach ($v in $validators) {
        $name = $v.Name
        # A script block bound to this module, so that it sees the private helpers when the engine runs it.
        $run = $ExecutionContext.SessionState.Module.NewBoundScriptBlock([scriptblock]::Create("param(`$Context) Invoke-AzlVerValidatorCheck -Context `$Context -Name '$name'"))
        $defs.Add((New-AzlVerDefinition -Id $v.Id -Category readiness -Title $v.Title -Source "$($script:Src.EnvChecker) ($name validator); $($script:Src.DocsEnv)" `
                    -Reads 'the Environment Checker module on the nodes (read only; it writes its log and report under the profile folder of the user)' -Blocking $v.Blocking -Applies $v.Applies -Run $run))
    }    return $defs.ToArray()
}

function Invoke-AzlVerValidatorCheck {
    # The body of RD-002 to RD-007: ask Readiness.Run for the validator and turn its answer into results.
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read inside nested script blocks.')]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    Invoke-AzlVerCheckBody -Body {
        $m = Get-AzlVerAdapterMember -Context $Context -Group 'Readiness' -Name 'Run'
        if (-not $m) { Stop-AzlVerSkip "The adapter has no Readiness.Run here, so the $Name validator did not run." $script:EcInstallNode }
        $answer = & $m $Name $Context
        ConvertFrom-AzlVerValidatorAnswer -Answer $answer -Name $Name
    }
}
function ConvertFrom-AzlVerValidatorAnswer {
    <#
    .SYNOPSIS
        Results of a check from the answer of Readiness.Run: Available, Reason, Remedy, Results (Node, Name, Title, Status, Severity,
        Description, Remediation, Target). Not available: Skipped, with the reason and the install command.
    #>
    [CmdletBinding()]
    param($Answer, [Parameter(Mandatory)][string]$Name)
    if (-not [bool](Get-AzlProp $Answer 'Available' $false)) {
        $remedy = [string](Get-AzlProp $Answer 'Remedy' $script:EcInstallNode)
        Stop-AzlVerSkip "The $Name validator did not run: $([string](Get-AzlProp $Answer 'Reason' 'no answer'))" $remedy
    }
    $rows = @(ConvertTo-AzlVerList (Get-AzlProp $Answer 'Results' @()))
    if (-not $rows.Count) { Stop-AzlVerSkip "The $Name validator ran but wrote no result." $script:EcInstallNode }
    # Only an explicit success counts as a pass. A status that is empty, ERROR, ABORTED, SKIPPED or one a newer module adds is not a success; a
    # skipped test did not run (Skipped), anything else that is not a success is a finding. A finding is critical unless its severity is explicitly
    # WARNING or INFORMATIONAL: an empty or unknown severity is read as the worst.
    $isSuccess = { param($r) [string](Get-AzlProp $r 'Status' '') -match '^(?i)\s*(success|succeeded|pass|passed)\s*$' }
    $isSkip = { param($r) [string](Get-AzlProp $r 'Status' '') -match '^(?i)\s*skip' }
    $failed = @($rows | Where-Object { -not (& $isSuccess $_) -and -not (& $isSkip $_) })
    $skippedRows = @($rows | Where-Object { & $isSkip $_ })
    $nodes = @($rows | ForEach-Object { [string](Get-AzlProp $_ 'Node' '*') } | Select-Object -Unique)
    foreach ($nd in $nodes) {
        $mine = @($rows | Where-Object { [string](Get-AzlProp $_ 'Node' '*') -eq $nd })
        $bad = @($failed | Where-Object { [string](Get-AzlProp $_ 'Node' '*') -eq $nd })
        $notRun = @($skippedRows | Where-Object { [string](Get-AzlProp $_ 'Node' '*') -eq $nd })
        $critical = @($bad | Where-Object { [string](Get-AzlProp $_ 'Severity' '') -notmatch '^(?i)\s*(warn|info)' })
        $line = { param($r) "$(Get-AzlProp $r 'Title' (Get-AzlProp $r 'Name' '')) [$(Get-AzlProp $r 'Target' '')]: $(Get-AzlProp $r 'Description' '')" }
        $remedy = (@($bad | ForEach-Object { [string](Get-AzlProp $_ 'Remediation' '') } | Where-Object { $_ } | Select-Object -Unique) -join '; ')
        $evidence = (@($bad | ForEach-Object { "$($_.Severity) $($_.Name)" }) -join ', ')
        if ($critical.Count) { New-AzlVerResult Failed "The $Name validator reports $($critical.Count) critical issue(s) of $($mine.Count) tests: $((@($critical | ForEach-Object { & $line $_ })) -join ' | ')" $(if ($remedy) { $remedy } else { 'Fix what the validator names and run it again.' }) -Node $nd -Evidence $evidence }
        elseif ($notRun.Count) { New-AzlVerResult Skipped "The $Name validator skipped $($notRun.Count) of $($mine.Count) tests on this node, so they were not verified: $((@($notRun | ForEach-Object { & $line $_ })) -join ' | ')" $script:EcInstallNode -Node $nd -Evidence (@($notRun | ForEach-Object { "$($_.Name)" }) -join ', ') }
        elseif ($bad.Count) { New-AzlVerResult Warning "The $Name validator reports $($bad.Count) warning(s) of $($mine.Count) tests: $((@($bad | ForEach-Object { & $line $_ })) -join ' | ')" $remedy -Node $nd -Evidence $evidence }
        else { New-AzlVerResult Passed "The $Name validator ran $($mine.Count) test(s); all reported success." -Node $nd }
    }
}

# =====================================================================================================================
# The default adapter (real, read only)
# =====================================================================================================================

$script:ValidatorScript = {
    param([string]$Validator, [string]$ParamJson, [object[]]$Sessions)
    $ErrorActionPreference = 'Stop'
    $m = Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $m) { return (@{ available = $false; reason = 'the module AzStackHci.EnvironmentChecker is not installed on this node' } | ConvertTo-Json -Compress) }
    Import-Module AzStackHci.EnvironmentChecker -ErrorAction Stop
    $P = $ParamJson | ConvertFrom-Json
    $rows = @()
    try {
        switch ($Validator) {
            'Connectivity' { if ($P.proxy) { $rows = @(Invoke-AzStackHciConnectivityValidation -PassThru -Proxy $P.proxy) } else { $rows = @(Invoke-AzStackHciConnectivityValidation -PassThru) } }
            'Hardware' { $rows = @(Invoke-AzStackHciHardwareValidation -PassThru) }
            'Software' { $rows = @(Invoke-AzStackHciSoftwareValidation -PsSession $Sessions -Exclude Test-IsNotPartofDomain -PassThru) }
            'Network' { $rows = @(Invoke-AzStackHciNetworkValidation -IpPools @($P.ipPools) -ManagementSubnetValue $P.managementSubnet -PSSession $Sessions -AtcHostIntents @($P.intents) -PassThru) }
        }
    }
    catch { return (@{ available = $true; reason = ''; error = $_.Exception.Message; results = @() } | ConvertTo-Json -Compress -Depth 6) }
    $out = @($rows | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Name) } | ForEach-Object {
            @{ name = [string]$_.Name; title = [string]$_.Title; status = [string]$_.Status; severity = [string]$_.Severity; description = [string]$_.Description; remediation = [string]$_.Remediation; target = [string]$_.TargetResourceName }
        })
    return (@{ available = $true; reason = ''; results = $out } | ConvertTo-Json -Compress -Depth 6)
}

function Invoke-AzlVerReadinessDefault {
    <#
    .SYNOPSIS
        The default Readiness.Run(validator, Context): Connectivity and Hardware run locally on every node that has the module; Software
        and Network run on the first node with PowerShell sessions to all the nodes (they compare the nodes); Active Directory and Arc
        integration need credentials this tool does not hold on a node and say so. Nothing is installed and nothing is changed.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read inside nested script blocks.')]
    param([Parameter(Mandatory)][string]$Validator, [Parameter(Mandatory)]$Context)
    # The credential and the address map the engine gave to Get-AzlVerificationAdapterDefault travel in the adapter itself.
    $cred = Get-AzlProp (Get-AzlVerContextValue $Context 'Adapters') 'Readiness.Credential' $null
    $map = Get-AzlProp (Get-AzlVerContextValue $Context 'Adapters') 'Readiness.Address' @{}
    & {
        $remote = Get-AzlVerAdapterMember -Context $Context -Group 'Remote' -Name 'Invoke'
        if (-not $remote) { return @{ Available = $false; Reason = 'the adapter has no Remote.Invoke here (nodes are not reachable from this host)' } }
        $nodes = @(Get-AzlVerNodeList $Context)
        $infra = Get-AzlVerInfra $Context
        $convert = {
            param($Node, $Raw)
            $o = ($Raw | Where-Object { $_ -is [string] } | Select-Object -Last 1) | ConvertFrom-Json -Depth 8
            @{ Available = [bool]$o.available; Reason = [string](Get-AzlProp $o 'reason' ''); Error = [string](Get-AzlProp $o 'error' ''); Node = $Node
                Rows = @(ConvertTo-AzlVerList (Get-AzlProp $o 'results' @()) | ForEach-Object { @{ Node = $Node; Name = $_.name; Title = $_.title; Status = $_.status; Severity = $_.severity; Description = $_.description; Remediation = $_.remediation; Target = $_.target } }) }
        }
        switch ($Validator) {
            { $_ -in 'Connectivity', 'Hardware' } {
                $param = (@{ proxy = [string](Get-AzlProp $infra 'networking.outbound.proxy.url' '') } | ConvertTo-Json -Compress)
                $rows = @(); $why = @()
                foreach ($n in $nodes) {
                    $r = & $convert $n.Name (& $remote $n.Name $script:ValidatorScript @($Validator, $param, @()))
                    if (-not $r.Available) { $why += "$($n.Name): $($r.Reason)"; continue }
                    if ($r.Error) { $why += "$($n.Name): $($r.Error)"; continue }
                    $rows += $r.Rows
                }
                if ($why.Count -and -not $rows.Count) { return @{ Available = $false; Reason = ($why -join '; ') } }
                if ($why.Count) { $rows += @{ Node = '*'; Name = 'NotRun'; Title = 'Validator did not run on every node'; Status = 'FAILURE'; Severity = 'CRITICAL'; Description = ($why -join '; '); Remediation = 'Install the module on those nodes (RD-001).'; Target = '' } }
                return @{ Available = $true; Results = $rows }
            }
            { $_ -in 'Software', 'Network' } {
                if (-not $cred) { return @{ Available = $false; Reason = "the $Validator validator compares the nodes through PowerShell sessions and needs the local administrator credential, which this host did not pass to the adapter (Get-AzlVerificationAdapterDefault -Credential)" } }
                $first = $nodes[0]
                $pool = Get-AzlProp $infra 'networking.management.infrastructure_pool' $null
                $param = (@{
                        proxy = ''; managementSubnet = [string](Get-AzlProp $infra 'networking.management.subnet' '')
                        ipPools = @(@{ StartingAddress = [string](Get-AzlProp $pool 'start' ''); EndingAddress = [string](Get-AzlProp $pool 'end' '') })
                        intents = @(Get-AzlVerIntent $Context | ForEach-Object { @{ Name = $_.Name; TrafficType = @($_.Traffic); Adapter = @($_.Adapters); OverrideAdapterProperty = $false; OverrideQosPolicy = $false; OverrideVirtualSwitchConfiguration = $false } })
                    } | ConvertTo-Json -Compress -Depth 6)
                $targets = @($nodes | ForEach-Object { if ($map -and $map.ContainsKey($_.Name)) { [string]$map[$_.Name] } elseif ($_.ManagementIp) { $_.ManagementIp } else { $_.Name } })
                $wrapper = {
                    param([string]$Validator, [string]$ParamJson, [object[]]$Targets, [pscredential]$Credential, [string]$InnerText)
                    $sessions = @()
                    try {
                        foreach ($t in $Targets) { $sessions += Microsoft.PowerShell.Core\New-PSSession -ComputerName $t -Credential $Credential -ErrorAction Stop }
                        $inner = [scriptblock]::Create($InnerText)
                        & $inner $Validator $ParamJson $sessions
                    }
                    finally { foreach ($s in $sessions) { Remove-PSSession $s -ErrorAction SilentlyContinue } }
                }
                $raw = & $remote $first.Name $wrapper @($Validator, $param, $targets, $cred, $script:ValidatorScript.ToString())
                $r = & $convert '*' $raw
                if (-not $r.Available) { return @{ Available = $false; Reason = "$($first.Name): $($r.Reason)" } }
                if ($r.Error) { return @{ Available = $false; Reason = "$($first.Name): the validator stopped: $($r.Error)" } }
                return @{ Available = $true; Results = $r.Rows }
            }
            'ActiveDirectory' { return @{ Available = $false; Reason = 'the Active Directory validator needs the LCM credential and a domain controller; the identity checks (IDN-*) cover the same facts without a credential on a node. Run it by hand where wanted: Invoke-AzStackHciExternalActiveDirectoryValidation -ADOUPath <ou> -DomainFQDN <domain> -NamingPrefix <prefix> -ActiveDirectoryServer <dc> -ActiveDirectoryCredentials (Get-Credential) -ClusterName <cluster> -PhysicalMachineNames <nodes>' } }
            'ArcIntegration' { return @{ Available = $false; Reason = 'the Arc integration validator needs an Azure sign-in on the node; the Azure checks (AZR-010, AZR-012) cover the same facts. Run it by hand where wanted: Connect-AzAccount -Tenant <tenant> -Subscription <subscription> -DeviceCode; Invoke-AzStackHciArcIntegrationValidation -SubscriptionID <subscription> -RegistrationResourceGroupName <rg> -ArcResourceGroupName <rg> -NodeNames <nodes>' } }
            default { return @{ Available = $false; Reason = "unknown validator $Validator" } }
        }
    }
}

function Get-AzlVerificationAdapterDefault {
    <#
    .SYNOPSIS
        The real, read only adapter members of the NODES and READINESS checks: Remote.Invoke, Node.* (one remote call per node,
        cached) and Readiness.Run. The engine merges them with the other categories' members; tests replace any of them.
    .PARAMETER Credential
        The local administrator credential of the nodes (the engine resolves it from Key Vault). Without it WinRM uses the current identity.
    .PARAMETER Address
        Node name -> address to connect to, when the name does not resolve.
    #>
    [CmdletBinding()]
    param([pscredential]$Credential, [hashtable]$Address = @{}, [switch]$UseSsl, [string]$Authentication = 'Default')
    @{
        Remote    = @{ Invoke = (New-AzlVerRemoteDefault -Credential $Credential -Address $Address -UseSsl:$UseSsl -Authentication $Authentication) }
        Node      = (New-AzlVerNodeAdapterDefault)
        Readiness = @{ Run = { param($Validator, $Context) Invoke-AzlVerReadinessDefault -Validator $Validator -Context $Context }; Credential = $Credential; Address = $Address }
    }
}

Export-ModuleMember -Function Get-AzlVerificationCheckDefinition, Get-AzlVerificationAdapterDefault
