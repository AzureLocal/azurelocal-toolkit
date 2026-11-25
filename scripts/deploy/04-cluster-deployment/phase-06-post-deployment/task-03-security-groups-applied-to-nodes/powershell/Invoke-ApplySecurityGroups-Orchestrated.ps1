<#
.SYNOPSIS
    Adds the Active Directory security groups of identity.active_directory.security_groups[] to the local groups of every cluster node
    (Administrators, Remote Management Users, ...), from the local_groups of each entry. Idempotent. Checks the result.

.DESCRIPTION
    Phase 06 (post-deployment), Task 03 (security groups applied to nodes). Each entry of identity.active_directory.security_groups[] that lists
    local_groups is added (as <netbios name>\<name>) to those local groups on every node of nodes[]. An entry with no local_groups is not applied to
    the nodes (it is applied elsewhere, for example on a Windows Admin Center server). The groups must exist in Active Directory first (Phase 01
    task 02).

    It runs from a management host over PowerShell remoting, one node after the other, at the management address of the node (so NTLM works from a host
    that is not in the domain). For every node:
      1. reads (read only): the groups resolve on the node (a group that does not exist in the domain is a failure for that node, and nothing is
         added there), and which of them are members of their local groups already;
      2. adds each group that is not a member yet (Add-LocalGroupMember); a group that is a member is reported as AlreadyMember;
      3. the check after (the validation of the guide page): reads the local groups again and confirms every group is in every local group the file
         names. A group that is not confirmed fails the node.

    Idempotent. -WhatIf does step 1 and shows what would be added; it adds nothing and does not read anything that changes.

    The login for the nodes is -Credential, else the LCM account of the file (identity.active_directory.lcm_user, as <netbios name>\<user>; the
    password is a secret reference read through scripts/common/secrets/AzlSecret.psm1). The script never asks. With neither, or without the domain
    or the LCM user name, it stops with exit code 2 and nothing is changed (also under -WhatIf, because the plan reads the nodes).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        identity.active_directory.netbios_name, identity.active_directory.security_groups[] (name, local_groups)
        identity.active_directory.lcm_user (username, password)
        nodes[].name, nodes[].management.ip_address

    Exit codes: 0 every node is as the file says (done now, already so, or planned under -WhatIf); 1 a node failed (not reachable, a group not found or
    not confirmed); 2 the file or the login is missing or not usable (nothing was changed).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required.

.PARAMETER Credential
    Optional. The account for the remoting to the nodes. Without it the LCM account of the file is used.

.PARAMETER TargetNode
    Optional. Limit the run to these nodes (node names of the file, or an address). Default: every node of the file.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Invoke-ApplySecurityGroups-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Reads the nodes and shows which groups would be added. Changes nothing.

.EXAMPLE
    ./Invoke-ApplySecurityGroups-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml

    Adds the groups that are missing. Run it again: AlreadyMember.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [pscredential]$Credential,
    [string[]]$TargetNode = @(),
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

# The commands that run on a node. Each takes the step name first, so one remoting call shape serves all of them (and a test can tell them apart).
$Remote = @{
    # Read only: does each group resolve on the node (to a SID), and who is in each local group.
    ReadState = {
        param($Step, $AdGroups, $LocalGroups)
        $resolved = @{}
        foreach ($group in @($AdGroups)) {
            try { $resolved[[string]$group] = [string]([System.Security.Principal.NTAccount]::new([string]$group).Translate([System.Security.Principal.SecurityIdentifier])).Value }
            catch { $resolved[[string]$group] = '' }
        }
        $members = @{}
        foreach ($local in @($LocalGroups)) {
            $list = @()
            try { $list = @(Get-LocalGroupMember -Group ([string]$local) -ErrorAction Stop | ForEach-Object { @{ Name = [string]$_.Name; Sid = [string]$_.SID.Value } }) }
            catch { $list = $null }
            $members[[string]$local] = $list
        }
        @{ Computer = [string]$env:COMPUTERNAME; Resolved = $resolved; Members = $members }
    }
    # The only step that writes: adds one group to one local group (a member that is there already is not an error).
    AddMember = {
        param($Step, $LocalGroup, $AdGroup)
        try { Add-LocalGroupMember -Group ([string]$LocalGroup) -Member ([string]$AdGroup) -ErrorAction Stop; 'Added' }
        catch { if ($_.Exception.Message -match 'already a member') { 'AlreadyMember' } else { throw } }
    }
}
function Invoke-Node([string]$Computer, [string]$Step, [object[]]$Arguments = @()) {
    Invoke-Command -ComputerName $Computer -Credential $script:remoteCredential -ScriptBlock $Remote[$Step] -ArgumentList (, $Step + $Arguments) -ErrorAction Stop
}

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch -Wildcard ($Action) { 'Failed' { '[failed]  ' } 'Already*' { '[exists]  ' } 'Would*' { '[plan]    ' } default { '[done]    ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $Item, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}

Write-Line 'Invoke-ApplySecurityGroups-Orchestrated started'

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }
Write-Line "Loaded the infrastructure file: $InfrastructureFile"

# identity.active_directory.security_groups[]: name, purpose, local_groups. An entry with no local_groups is not applied to the nodes.
$domainNetbios = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory.netbios_name')).Trim()
$groupValue = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory.security_groups'
$groupList = @(@($groupValue) | Where-Object { $null -ne $_ })
$assignments = [System.Collections.Generic.List[object]]::new()
foreach ($group in $groupList) {
    if ($group -isnot [System.Collections.IDictionary]) { continue }
    $name = ([string]$group['name']).Trim()
    $localGroups = @(@($group['local_groups']) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($localGroups.Count -eq 0) { Write-Warning "Skipping '$name' - local_groups is empty"; continue }
    if (-not $name) { Exit-InputProblem 'An entry of identity.active_directory.security_groups has local_groups but no name.' }
    if (-not $domainNetbios) { Exit-InputProblem 'identity.active_directory.netbios_name is missing. The groups are added as <netbios name>\<group name>.' }
    $assignments.Add([pscustomobject]@{ Key = $name; AdGroup = "$domainNetbios\$name"; LocalGroups = $localGroups })
    Write-Line "Will assign: $domainNetbios\$name -> [$($localGroups -join ', ')]"
}
if ($assignments.Count -eq 0) {
    Write-Line 'No groups with local_groups assignments found - nothing to do'
    exit 0
}

# ---- the nodes: management addresses (NTLM works from a host outside the domain)
$fileNodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
$targets = @(if ($TargetNode.Count -gt 0) {
        foreach ($t in $TargetNode) {
            $match = @($fileNodes | Where-Object { $_.Name -ieq $t.Trim() -or $_.ManagementIp -eq $t.Trim() } | Select-Object -First 1)
            if ($match) { [pscustomobject]@{ Name = $match[0].Name; Address = $(if ($match[0].ManagementIp) { $match[0].ManagementIp } else { $match[0].Name }) } }
            else { [pscustomobject]@{ Name = $t.Trim(); Address = $t.Trim() } }
        }
    }
    else { $fileNodes | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Address = $(if ($_.ManagementIp) { $_.ManagementIp } else { $_.Name }) } } })
if ($targets.Count -eq 0) { Exit-InputProblem 'nodes[] is empty in the infrastructure file, and no -TargetNode was given.' }
Write-Line "Target nodes: $(($targets | ForEach-Object { $_.Address }) -join ', ')"

# ---- the login: -Credential, else the LCM account of the file. Nothing is asked.
$remoteCredential = $Credential
if (-not $remoteCredential) {
    $lcmUser = Get-Text 'identity.active_directory.lcm_user.username'
    $reference = Get-Text 'identity.active_directory.lcm_user.password'
    if (-not $domainNetbios -or -not $lcmUser) { Exit-InputProblem 'No login: pass -Credential, or set identity.active_directory.netbios_name and identity.active_directory.lcm_user.username in the file.' }
    if (-not $reference) { Exit-InputProblem 'No login: pass -Credential, or set identity.active_directory.lcm_user.username and password (a secret reference) in the file.' }
    try { $secret = Get-AzlSecretValue -Reference $reference -Infrastructure $infra }
    catch { Exit-InputProblem "The password of identity.active_directory.lcm_user could not be read: $($_.Exception.Message). Pass -Credential, or fix the secret reference." }
    $account = if ($lcmUser -match '\\|@') { $lcmUser } else { "$domainNetbios\$lcmUser" }
    $remoteCredential = [pscredential]::new($account, $secret)
    Write-Line "Credentials resolved for '$account'."
}

$adGroups = @($assignments | ForEach-Object { $_.AdGroup })
$allLocalGroups = @($assignments | ForEach-Object { $_.LocalGroups } | Sort-Object -Unique)
$readArguments = @(, $adGroups) + @(, $allLocalGroups)

foreach ($target in $targets) {
    $node = $target.Name
    try {
        # 1. read (also under -WhatIf)
        $state = Invoke-Node $target.Address 'ReadState' $readArguments
        $resolved = $state['Resolved']
        $members = $state['Members']
        $unresolved = @($adGroups | Where-Object { -not $resolved[$_] })
        if ($unresolved) {
            Add-Row "$node groups" 'Failed' "not found in the domain (create them first, Phase 01 task 02): $($unresolved -join ', '). Nothing was added on this node."
            continue
        }
        foreach ($a in $assignments) {
            foreach ($local in $a.LocalGroups) {
                $item = "$node $($a.AdGroup) in $local"
                if ($null -eq $members[$local]) { Add-Row $item 'Failed' "the local group '$local' could not be read on the node"; continue }
                $present = @($members[$local] | Where-Object { $_.Sid -eq $resolved[$a.AdGroup] -or $_.Name -ieq $a.AdGroup }).Count -gt 0
                if ($present) { Add-Row $item 'AlreadyMember'; continue }
                # 2. add
                if ($PSCmdlet.ShouldProcess("$node ($($target.Address))", "Add $($a.AdGroup) to the local group $local")) {
                    $null = Invoke-Node $target.Address 'AddMember' @($local, $a.AdGroup)
                    Add-Row $item 'Added'
                }
                else { Add-Row $item 'WouldAdd' }
            }
        }
        # 3. the check after (not under -WhatIf: nothing was added)
        if (-not $WhatIfPreference) {
            $after = Invoke-Node $target.Address 'ReadState' $readArguments
            $missing = foreach ($a in $assignments) {
                foreach ($local in $a.LocalGroups) {
                    $list = $after['Members'][$local]
                    if ($null -eq $list -or @($list | Where-Object { $_.Sid -eq $after['Resolved'][$a.AdGroup] -or $_.Name -ieq $a.AdGroup }).Count -eq 0) { "$($a.AdGroup) in $local" }
                }
            }
            if ($missing) { Add-Row "$node check" 'Failed' "not confirmed in the local group after the run: $(@($missing) -join '; ')" }
            else { Add-Row "$node check" 'Verified' 'every group is in every local group the file names' }
        }
    }
    catch { Add-Row "$node" 'Failed' "PowerShell remoting failed: $($_.Exception.Message)" }
}

Write-Line 'Invoke-ApplySecurityGroups-Orchestrated complete'
$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
