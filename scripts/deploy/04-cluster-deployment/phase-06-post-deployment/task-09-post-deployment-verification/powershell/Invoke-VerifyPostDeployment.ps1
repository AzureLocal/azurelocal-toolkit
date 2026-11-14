#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies a deployed Azure Local instance against the infrastructure file. Read only.

.DESCRIPTION
    Phase 06 (post-deployment), Task 09. It is also the verification of the deployment itself (Phase 05, task "verify deployment
    completion"): the cluster health checks and the identity checks that the earlier per-identity scripts did are the first two parts here.

    Checks, in this order. Nothing is created, changed or deleted.

      1. Cluster: every node of nodes[] is a cluster node and its state is Up.
      2. Identity: with scenario.identity active_directory every node is joined to identity.active_directory.domain_fqdn and its secure channel
         works. With local_identity every node is in a workgroup and the cluster name resource has ADAware 2 (no Active Directory).
      3. Quorum: a quorum type is set and the quorum state is Normal. (The witness is created by the deployment from cluster.witness.)
      4. Security groups: each node has at least one group in Administrators and in Remote Management Users (the groups
         identity.active_directory.security_groups[].local_groups put there). Active Directory only.
      5. SSH: sshd runs on each node and TCP 22 answers (the WindowsOpenSSH extension of Phase 06 task 04 puts it there).
      6. Storage: a non-primordial storage pool is healthy, at least one cluster shared volume exists and every one is Online.
      7. VM images in Azure: the number of images that Succeeded is not below the number in storage.vm_images[].
      8. Logical networks in Azure: the number that Succeeded is not below the number in networking.logical_networks[].

    -WhatIf lists the checks and runs none.

    The login is -Credential, else the account the file names for the identity: the LCM account (identity.active_directory.lcm_user, as
    <netbios name>\<user>) for active_directory, the local administrator (identity.local_admin, as .\<user>) for local_identity. The password is a
    secret reference read through scripts/common/secrets/AzlSecret.psm1. The script never asks. With neither it stops with exit code 2.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name, nodes[].name, nodes[].management.ip_address
        scenario.identity, identity.active_directory.domain_fqdn, .netbios_name, .lcm_user (username, password)
        identity.local_admin (username, password)
        azure.subscription_id, azure.resource_group
        storage.vm_images[], networking.logical_networks[]

    Exit codes: 0 every check passed (or planned under -WhatIf); 1 a check failed; 2 a value in the file is missing or unusable, or there is no
    login (nothing was checked).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. Only the keys above are read.

.PARAMETER Credential
    Optional. The account for the remoting to the nodes. Without it the account of the file is used (see above).

.PARAMETER TargetNode
    Limit the node checks to these nodes (node names or management addresses). Default: every node of the file.

.PARAMETER LogPath
    Optional. The log file. Default: logs\task-09-post-deployment-verification\<time>_VerifyPostDeployment.log in the current folder.

.EXAMPLE
    ./Invoke-VerifyPostDeployment.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./Invoke-VerifyPostDeployment.ps1 -InfrastructureFile ./infrastructure.yml -TargetNode iic-azl-n01

.NOTES
    Needs the FailoverClusters and Storage modules and az (signed in) for checks 7 and 8.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [pscredential]$Credential,
    [string[]]$TargetNode = @(),
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

# What makes a check pass. They define the check, not a deployment: each task has to leave at least one object behind.
# Security groups apply at least one AD group to the local Administrators and Remote Management Users groups of a node; storage leaves at least one CSV volume.
$MinimumAdGroupsPerLocalGroup = 1
$MinimumCsvVolumes = 1
# The cluster name resource of a cluster without Active Directory has ADAware 2 (Microsoft Learn, Deploy Azure Local with local identity and Azure Key Vault).
$LocalIdentityAdAware = 2
# TCP port of the SSH service of the node. Fixed by the SSH protocol.
$SshPort = 22

$logFile = $LogPath
if (-not $logFile) { $logFile = Join-Path (Join-Path (Join-Path (Get-Location).Path 'logs') 'task-09-post-deployment-verification') ('{0:yyyy-MM-dd_HHmmss}_VerifyPostDeployment.log' -f (Get-Date)) }
$logDir = Split-Path -Parent $logFile
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1,-5}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $script:logFile -Value $line -Encoding utf8 -WhatIf:$false
    $color = switch ($Level) { 'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'PASS' { 'Green' } default { 'Cyan' } }
    Write-Host $line -ForegroundColor $color
}
function Exit-InputProblem([string]$Message) { Write-Log $Message 'FAIL'; exit 2 }

Write-Log 'Post-deployment verification'
Write-Log "Log: $logFile"

# ---- the values, from the infrastructure file only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$clusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing in the infrastructure file.' }
$identityMode = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.identity')).Trim().ToLowerInvariant()
if ($identityMode -notin 'active_directory', 'local_identity') { Exit-InputProblem "scenario.identity must be active_directory or local_identity; found '$identityMode'." }
$domainFqdn = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory.domain_fqdn')).Trim()
if ($identityMode -eq 'active_directory' -and -not $domainFqdn) { Exit-InputProblem 'identity.active_directory.domain_fqdn is missing in the infrastructure file.' }
$subscriptionId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
$resourceGroup = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.resource_group')).Trim()

$allNodes = @(@(Get-AzlInfrastructureNode -Infrastructure $infra) | ForEach-Object { [pscustomobject]@{ Hostname = [string]$_.Name; Ip = [string]$_.ManagementIp } })
$nodesToCheck = if ($TargetNode.Count -gt 0) { @($allNodes | Where-Object { $_.Hostname -in $TargetNode -or $_.Ip -in $TargetNode }) } else { $allNodes }
if ($nodesToCheck.Count -eq 0) { Exit-InputProblem 'No node to check: nodes[] is empty or -TargetNode matches none.' }

$logicalNetworkValue = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking.logical_networks'
$logicalNetworks = @(@($logicalNetworkValue) | Where-Object { $null -ne $_ })
$vmImageValue = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage.vm_images'
$vmImages = @(@($vmImageValue) | Where-Object { $null -ne $_ })

Write-Log "Cluster:  $clusterName ($identityMode)"
Write-Log "Nodes:    $(($nodesToCheck | ForEach-Object { "$($_.Hostname)($($_.Ip))" }) -join ', ')"

# ---- the login: -Credential, else the account of the file. Nothing is asked.
if (-not $Credential -and -not $WhatIfPreference) {
    if ($identityMode -eq 'active_directory') {
        $netbios = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory.netbios_name')).Trim()
        $user = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory.lcm_user.username')).Trim()
        $reference = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory.lcm_user.password')).Trim()
        $account = if ($netbios) { "$netbios\$user" } else { $user }
        $what = 'identity.active_directory.lcm_user'
    }
    else {
        $user = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.local_admin.username')).Trim()
        $reference = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.local_admin.password')).Trim()
        $account = ".\$user"
        $what = 'identity.local_admin'
    }
    if (-not $user -or -not $reference) { Exit-InputProblem "No login: pass -Credential, or set $what username and password (a secret reference) in the infrastructure file." }
    try { $secret = Get-AzlSecretValue -Reference $reference -Infrastructure $infra }
    catch { Exit-InputProblem "The password of $what could not be read: $($_.Exception.Message)" }
    $Credential = [pscredential]::new($account, $secret)
    Write-Log "Login: $account (from $what)"
}
$credParam = if ($Credential) { @{ Credential = $Credential } } else { @{} }

# ---- the checks
$passCount = 0; $failCount = 0; $skipCount = 0
function Write-Check {
    param([bool]$Pass, [string]$Check, [string]$Detail = '')
    $level = if ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Log "  [$level] $Check$(if ($Detail) { " - $Detail" })" $level
    if ($Pass) { $script:passCount++ } else { $script:failCount++ }
}
function Write-Skip([string]$Check, [string]$Reason = '') { Write-Log "  [SKIP] $Check$(if ($Reason) { " - $Reason" })" 'WARN'; $script:skipCount++ }
function Write-Failure([string]$Text) { Write-Log "  [FAIL] $Text" 'FAIL'; $script:failCount++ }
function Write-Plan([string]$Text) { Write-Log "  [WhatIf] $Text" 'WARN' }

# 1. Cluster nodes
Write-Log ''; Write-Log 'Check 1 - Cluster nodes'
if ($WhatIfPreference) { Write-Plan "Would read the nodes of $clusterName and check that each node of the file is Up" }
else {
    try {
        $clusterNodes = @(Get-ClusterNode -Cluster $clusterName -ErrorAction Stop)
        foreach ($node in $nodesToCheck) {
            $member = $clusterNodes | Where-Object { [string]$_.Name -eq $node.Hostname } | Select-Object -First 1
            if (-not $member) { Write-Check -Pass $false -Check "$($node.Hostname) is a cluster node" -Detail 'not found in the cluster'; continue }
            Write-Check -Pass ([string]$member.State -eq 'Up') -Check "$($node.Hostname) cluster node state" -Detail ([string]$member.State)
        }
    }
    catch { Write-Failure "Cluster node query failed: $($_.Exception.Message)" }
}

# 2. Identity
Write-Log ''; Write-Log "Check 2 - Identity ($identityMode)"
foreach ($node in $nodesToCheck) {
    if ($WhatIfPreference) { Write-Plan "Would read the domain membership of $($node.Hostname) ($($node.Ip))"; continue }
    try {
        $state = Invoke-Command -ComputerName $node.Ip @credParam -ErrorAction Stop -ScriptBlock {
            $system = Get-CimInstance -ClassName Win32_ComputerSystem
            $channel = $null
            if ($system.PartOfDomain) { $channel = [bool](Test-ComputerSecureChannel -ErrorAction SilentlyContinue) }
            [pscustomobject]@{ Domain = [string]$system.Domain; PartOfDomain = [bool]$system.PartOfDomain; SecureChannel = $channel }
        }
        if ($identityMode -eq 'active_directory') {
            Write-Check -Pass ($state.PartOfDomain -and $state.Domain -ieq $domainFqdn) -Check "$($node.Hostname) joined to $domainFqdn" -Detail $state.Domain
            Write-Check -Pass ($state.SecureChannel -eq $true) -Check "$($node.Hostname) secure channel to the domain"
        }
        else { Write-Check -Pass (-not $state.PartOfDomain) -Check "$($node.Hostname) is in a workgroup" -Detail $state.Domain }
    }
    catch { Write-Failure "$($node.Hostname) identity check failed: $($_.Exception.Message)" }
}
if ($identityMode -eq 'local_identity') {
    if ($WhatIfPreference) { Write-Plan "Would read ADAware of the cluster name resource of $clusterName" }
    else {
        try {
            $adAware = Get-ClusterResource -Cluster $clusterName -Name 'Cluster Name' -ErrorAction Stop | Get-ClusterParameter -Name ADAware -ErrorAction Stop
            Write-Check -Pass ([int]$adAware.Value -eq $LocalIdentityAdAware) -Check "Cluster name ADAware is $LocalIdentityAdAware (no Active Directory)" -Detail ([string]$adAware.Value)
        }
        catch { Write-Failure "ADAware could not be read: $($_.Exception.Message)" }
    }
}

# 3. Quorum
Write-Log ''; Write-Log 'Check 3 - Cluster quorum'
if ($WhatIfPreference) { Write-Plan "Would query the quorum of $clusterName" }
else {
    try {
        $quorum = Get-ClusterQuorum -Cluster $clusterName -ErrorAction Stop
        $quorumState = [string](Get-Cluster -Name $clusterName).QuorumState
        Write-Check -Pass ($null -ne $quorum.QuorumType) -Check 'Quorum type configured' -Detail ([string]$quorum.QuorumType)
        Write-Check -Pass ($quorumState -eq 'Normal') -Check 'Quorum state Normal' -Detail $quorumState
    }
    catch { Write-Failure "Cluster quorum query failed: $($_.Exception.Message)" }
}

# 4. Security groups
Write-Log ''; Write-Log 'Check 4 - Security groups'
if ($identityMode -ne 'active_directory') { Write-Skip 'Security groups' 'the instance has no Active Directory' }
else {
    foreach ($node in $nodesToCheck) {
        if ($WhatIfPreference) { Write-Plan "Would check the local group membership on $($node.Hostname) ($($node.Ip))"; continue }
        try {
            $groups = Invoke-Command -ComputerName $node.Ip @credParam -ErrorAction Stop -ScriptBlock {
                @{
                    AdminGroups = @(Get-LocalGroupMember -Group 'Administrators' | Where-Object ObjectClass -EQ 'Group').Count
                    RmGroups    = @(Get-LocalGroupMember -Group 'Remote Management Users' | Where-Object ObjectClass -EQ 'Group').Count
                }
            }
            Write-Check -Pass ($groups.AdminGroups -ge $MinimumAdGroupsPerLocalGroup) -Check "$($node.Hostname) - Administrators AD group(s)" -Detail "$($groups.AdminGroups)"
            Write-Check -Pass ($groups.RmGroups -ge $MinimumAdGroupsPerLocalGroup) -Check "$($node.Hostname) - Remote Management Users AD group(s)" -Detail "$($groups.RmGroups)"
        }
        catch { Write-Failure "$($node.Hostname) group check failed: $($_.Exception.Message)" }
    }
}

# 5. SSH
Write-Log ''; Write-Log 'Check 5 - SSH'
foreach ($node in $nodesToCheck) {
    if ($WhatIfPreference) { Write-Plan "Would check the sshd service and port $SshPort on $($node.Hostname) ($($node.Ip))"; continue }
    try {
        $sshd = Invoke-Command -ComputerName $node.Ip @credParam -ErrorAction Stop -ScriptBlock { Get-Service sshd -ErrorAction SilentlyContinue }
        Write-Check -Pass ($null -ne $sshd -and [string]$sshd.Status -eq 'Running') -Check "$($node.Hostname) - sshd service" -Detail $(if ($sshd) { [string]$sshd.Status } else { 'not installed' })
    }
    catch { Write-Failure "$($node.Hostname) sshd check failed: $($_.Exception.Message)" }
    $port = Test-NetConnection -ComputerName $node.Ip -Port $SshPort -WarningAction SilentlyContinue
    Write-Check -Pass ([bool]$port.TcpTestSucceeded) -Check "$($node.Hostname) - port $SshPort reachable"
}

# 6. Storage
Write-Log ''; Write-Log 'Check 6 - Storage'
if ($WhatIfPreference) { Write-Plan "Would query the storage pool and the cluster shared volumes of $clusterName" }
else {
    try {
        $pool = @(Get-StoragePool -CimSession $clusterName | Where-Object IsPrimordial -EQ $false)
        if ($pool.Count -gt 0) { Write-Check -Pass (@($pool | Where-Object { [string]$_.HealthStatus -ne 'Healthy' }).Count -eq 0) -Check 'Storage pool health' -Detail (($pool | ForEach-Object { [string]$_.HealthStatus }) -join ', ') }
        else { Write-Failure "No storage pool found on $clusterName" }
        $csvVolumes = @(Get-ClusterSharedVolume -Cluster $clusterName)
        Write-Check -Pass ($csvVolumes.Count -ge $MinimumCsvVolumes) -Check 'CSV volumes mounted' -Detail "$($csvVolumes.Count) volume(s)"
        foreach ($csv in $csvVolumes) { Write-Check -Pass ([string]$csv.State -eq 'Online') -Check "  $($csv.Name)" -Detail ([string]$csv.State) }
    }
    catch { Write-Failure "Storage check failed: $($_.Exception.Message)" }
}

# 7. VM images in Azure
Write-Log ''; Write-Log 'Check 7 - VM images (Azure)'
if (-not $subscriptionId -or -not $resourceGroup) { Write-Skip 'VM images' 'azure.subscription_id or azure.resource_group is not in the file' }
elseif ($WhatIfPreference) { Write-Plan "Would run: az stack-hci-vm image list --resource-group $resourceGroup" }
else {
    $imagesJson = az stack-hci-vm image list --subscription $subscriptionId --resource-group $resourceGroup --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $imagesJson) {
        $images = @($imagesJson | ConvertFrom-Json)
        $succeeded = @($images | Where-Object { $_.provisioningState -eq 'Succeeded' })
        Write-Check -Pass ($images.Count -gt 0) -Check "VM images in $resourceGroup" -Detail "$($images.Count) found"
        if ($vmImages.Count -gt 0) { Write-Check -Pass ($succeeded.Count -ge $vmImages.Count) -Check 'All expected images Succeeded' -Detail "$($succeeded.Count)/$($vmImages.Count)" }
    }
    else { Write-Failure 'Could not query VM images: check the az sign-in' }
}

# 8. Logical networks in Azure
Write-Log ''; Write-Log 'Check 8 - Logical networks (Azure)'
if (-not $subscriptionId -or -not $resourceGroup) { Write-Skip 'Logical networks' 'azure.subscription_id or azure.resource_group is not in the file' }
elseif ($WhatIfPreference) { Write-Plan "Would run: az stack-hci-vm network lnet list --resource-group $resourceGroup" }
else {
    $lnetsJson = az stack-hci-vm network lnet list --subscription $subscriptionId --resource-group $resourceGroup --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $lnetsJson) {
        $lnets = @($lnetsJson | ConvertFrom-Json)
        $succeeded = @($lnets | Where-Object { $_.provisioningState -eq 'Succeeded' })
        Write-Check -Pass ($lnets.Count -gt 0) -Check "Logical networks in $resourceGroup" -Detail "$($lnets.Count) found"
        if ($logicalNetworks.Count -gt 0) { Write-Check -Pass ($succeeded.Count -ge $logicalNetworks.Count) -Check 'All expected networks Succeeded' -Detail "$($succeeded.Count)/$($logicalNetworks.Count)" }
    }
    else { Write-Failure 'Could not query logical networks: check the az sign-in' }
}

# ---- summary
Write-Log ''
Write-Log "Summary: $passCount passed, $failCount failed, $skipCount skipped"
if ($WhatIfPreference) { Write-Log 'Planned only: re-run without -WhatIf to run the checks.' 'WARN'; exit 0 }
if ($failCount -gt 0) { Write-Log "$failCount check(s) failed. Log: $logFile" 'FAIL'; exit 1 }
exit 0
