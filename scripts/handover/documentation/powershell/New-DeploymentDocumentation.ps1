<#
.SYNOPSIS
    Writes the deployment documentation package of an Azure Local instance, from infrastructure.yml and from what the cluster reports.

.DESCRIPTION
    Handover, documentation. The script collects, read only:
      - the instance as the file describes it: the customer (site.customer), the cluster name (cluster.name) and where it is in Azure
        (azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location);
      - the cluster as it is now, over PowerShell remoting: the nodes and the quorum, the cluster networks and the virtual switches of one node,
        the storage pools, virtual disks and cluster shared volumes, and the Azure Arc agent status of one node;
    and writes two files in -OutputPath: a Markdown page (cluster overview, network, storage, Azure integration, architecture diagram in Mermaid,
    operational procedures) and a JSON file with the same data. A part the cluster cannot report is left out with a warning; the page is written
    anyway.

    With -IncludeCredentialLocations the page also lists where the secrets are: every secret reference of the file (keyvault://, env://, file://,
    command://) with the key it is under. Only the reference is written, never a value, and nothing is resolved.

    The script changes nothing on the cluster or in Azure. With -WhatIf it collects and writes no file.

    The script does not sign in anywhere and asks nothing. It uses the account that runs it for the cluster cmdlets (FailoverClusters, Storage, Hyper-V).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name, site.customer
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location
        and, with -IncludeCredentialLocations, every secret reference of the file

    Exit codes: 0 the documentation is written (or planned under -WhatIf); 1 the files could not be written; 2 a value in the file is missing
    (cluster.name or site.customer) or the file cannot be read.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER OutputPath
    The folder for the documentation package. It is created when it does not exist.

.PARAMETER IncludeCredentialLocations
    Also list the secret references of the file (where the secrets are kept), never their values.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-DeploymentDocumentation.ps1 -InfrastructureFile ./infrastructure.yml -OutputPath ./handover

    Collects the cluster and writes ./handover/<customer>-<cluster>-Documentation.md and -Config.json.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$IncludeCredentialLocations,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

# Every string of the file that is a secret reference, with the key it is under. The reference only; nothing is resolved.
function Get-SecretReference([object]$Node, [string]$Path) {
    if ($Node -is [string]) {
        if ($Node -match '^(keyvault|env|file|command)://') { [pscustomobject]@{ Key = $Path; Reference = $Node } }
        return
    }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) { Get-SecretReference $Node[$key] $(if ($Path) { "$Path.$key" } else { [string]$key }) }
        return
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $i = -1
        foreach ($item in $Node) { $i++; Get-SecretReference $item "$Path[$i]" }
    }
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$clusterName = Get-Text 'cluster.name'
$customer = Get-Text 'site.customer'
$azure = [ordered]@{
    TenantId       = Get-Text 'azure.tenant_id'
    SubscriptionId = Get-Text 'azure.subscription_id'
    ResourceGroup  = Get-Text 'azure.resource_group'
    Location       = Get-Text 'azure.location'
}
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. It is the cluster the documentation describes.' }
if (-not $customer) { Exit-InputProblem 'site.customer is missing. The package is named after the customer.' }
$secretLocations = @(if ($IncludeCredentialLocations) { Get-SecretReference $infra '' | Sort-Object Key })

$package = [ordered]@{ GeneratedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); CustomerName = $customer; ClusterName = $clusterName; Azure = $azure; Sections = [ordered]@{} }
$sections = $package.Sections

# ---- the cluster as it is (read only); a part that fails is left out with a warning
function Get-ClusterConfiguration {
    try {
        $cluster = Get-Cluster -Name $clusterName -ErrorAction Stop
        $nodes = @(Get-ClusterNode -Cluster $clusterName -ErrorAction Stop)
        $sections.ClusterConfig = [ordered]@{
            Name = [string]$cluster.Name; Domain = [string]$cluster.Domain; NodeCount = $nodes.Count
            Nodes = @($nodes | ForEach-Object { [ordered]@{ Name = [string]$_.Name; State = [string]$_.State } })
            QuorumType = [string](Get-ClusterQuorum -Cluster $clusterName -ErrorAction Stop).QuorumType
        }
        Write-Line "[done]    Cluster: $($cluster.Name) with $($nodes.Count) node(s)."
    }
    catch { Write-Warning "The cluster configuration could not be read: $($_.Exception.Message)" }
}
function Get-UpNode { (@(Get-ClusterNode -Cluster $clusterName -ErrorAction Stop) | Where-Object { [string]$_.State -eq 'Up' } | Select-Object -First 1).Name }
function Get-NetworkConfiguration {
    try {
        $networks = @(Get-ClusterNetwork -Cluster $clusterName -ErrorAction Stop)
        $switches = @(Invoke-Command -ComputerName (Get-UpNode) -ScriptBlock { Get-VMSwitch | Select-Object Name, SwitchType, EmbeddedTeamingEnabled } -ErrorAction Stop)
        $sections.NetworkConfig = [ordered]@{
            ClusterNetworks = @($networks | ForEach-Object { [ordered]@{ Name = [string]$_.Name; Address = [string]$_.Address; Role = [string]$_.Role; State = [string]$_.State } })
            VirtualSwitches = @($switches | ForEach-Object { [ordered]@{ Name = [string]$_.Name; Type = [string]$_.SwitchType; SetEnabled = [string]$_.EmbeddedTeamingEnabled } })
        }
        Write-Line "[done]    Networks: $($networks.Count), virtual switches: $($switches.Count)."
    }
    catch { Write-Warning "The network configuration could not be read: $($_.Exception.Message)" }
}
function Get-StorageConfiguration {
    try {
        $pools = @(Get-StoragePool -CimSession $clusterName -ErrorAction Stop | Where-Object { $_.IsPrimordial -eq $false })
        $disks = @(Get-VirtualDisk -CimSession $clusterName -ErrorAction Stop)
        $volumes = @(Get-ClusterSharedVolume -Cluster $clusterName -ErrorAction Stop)
        $sections.StorageConfig = [ordered]@{
            StoragePools = @($pools | ForEach-Object { [ordered]@{ Name = [string]$_.FriendlyName; SizeGB = [math]::Round($_.Size / 1GB, 0); HealthStatus = [string]$_.HealthStatus } })
            VirtualDisks = @($disks | ForEach-Object { [ordered]@{ Name = [string]$_.FriendlyName; SizeTB = [math]::Round($_.Size / 1TB, 2); ResiliencySetting = [string]$_.ResiliencySettingName; HealthStatus = [string]$_.HealthStatus } })
            CSVs         = @($volumes | ForEach-Object { [ordered]@{ Name = [string]$_.Name; Path = [string]@($_.SharedVolumeInfo)[0].FriendlyVolumeName; State = [string]$_.State } })
        }
        Write-Line "[done]    Storage: $($pools.Count) pool(s), $($disks.Count) virtual disk(s), $($volumes.Count) cluster shared volume(s)."
    }
    catch { Write-Warning "The storage configuration could not be read: $($_.Exception.Message)" }
}
function Get-AzureIntegrationDetail {
    $sections.AzureIntegration = [ordered]@{ ArcStatus = 'not reported'; SubscriptionId = $azure.SubscriptionId; ResourceGroup = $azure.ResourceGroup; TenantId = $azure.TenantId; Location = $azure.Location }
    try {
        $arc = Invoke-Command -ComputerName (Get-UpNode) -ScriptBlock {
            $agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
            if (Test-Path -LiteralPath $agent) { $status = & $agent show --json 2>&1 | ConvertFrom-Json; return @{ Status = [string]$status.status } }
            $null
        } -ErrorAction Stop
        if ($arc) { $sections.AzureIntegration.ArcStatus = [string]$arc.Status; Write-Line "[done]    Azure Arc agent: $($arc.Status)." }
    }
    catch { Write-Warning "The Azure Arc agent status could not be read: $($_.Exception.Message)" }
}

function Get-Row([object]$Items, [scriptblock]$Format) { (@($Items) | Where-Object { $null -ne $_ } | ForEach-Object { & $Format $_ }) -join "`n" }

Write-Line "Documentation of '$clusterName' for $customer"
Get-ClusterConfiguration
Get-NetworkConfiguration
Get-StorageConfiguration
Get-AzureIntegrationDetail

$cc = if ($sections.Contains('ClusterConfig')) { $sections.ClusterConfig } else { [ordered]@{ Domain = 'not reported'; NodeCount = 'not reported'; QuorumType = 'not reported'; Nodes = @() } }
$nc = if ($sections.Contains('NetworkConfig')) { $sections.NetworkConfig } else { [ordered]@{ ClusterNetworks = @(); VirtualSwitches = @() } }
$sc = if ($sections.Contains('StorageConfig')) { $sections.StorageConfig } else { [ordered]@{ StoragePools = @(); VirtualDisks = @(); CSVs = @() } }
$ai = $sections.AzureIntegration
$credentialSection = if ($IncludeCredentialLocations) {
    "`n---`n`n## Where the secrets are`n`nThese are references. They name where a secret is kept; no value is written here.`n`n| Key | Reference |`n| --- | --- |`n$(Get-Row $secretLocations { param($s) "| $($s.Key) | $($s.Reference) |" })`n"
} else { '' }

$markdown = @"
# Azure Local deployment documentation

**Customer:** $customer
**Cluster:** $clusterName
**Generated:** $($package.GeneratedAt)

---

## Cluster overview

| Property | Value |
| --- | --- |
| Cluster name | $clusterName |
| Domain | $($cc.Domain) |
| Node count | $($cc.NodeCount) |
| Quorum type | $($cc.QuorumType) |

### Cluster nodes

| Node name | State |
| --- | --- |
$(Get-Row $cc.Nodes { param($n) "| $($n.Name) | $($n.State) |" })

---

## Network configuration

### Cluster networks

| Name | Address | Role | State |
| --- | --- | --- | --- |
$(Get-Row $nc.ClusterNetworks { param($n) "| $($n.Name) | $($n.Address) | $($n.Role) | $($n.State) |" })

### Virtual switches

| Name | Type | SET enabled |
| --- | --- | --- |
$(Get-Row $nc.VirtualSwitches { param($s) "| $($s.Name) | $($s.Type) | $($s.SetEnabled) |" })

---

## Storage configuration

### Storage pools

| Name | Size (GB) | Health |
| --- | --- | --- |
$(Get-Row $sc.StoragePools { param($p) "| $($p.Name) | $($p.SizeGB) | $($p.HealthStatus) |" })

### Virtual disks

| Name | Size (TB) | Resiliency | Health |
| --- | --- | --- | --- |
$(Get-Row $sc.VirtualDisks { param($d) "| $($d.Name) | $($d.SizeTB) | $($d.ResiliencySetting) | $($d.HealthStatus) |" })

### Cluster shared volumes

| Name | Path | State |
| --- | --- | --- |
$(Get-Row $sc.CSVs { param($v) "| $($v.Name) | $($v.Path) | $($v.State) |" })

---

## Azure integration

| Property | Value |
| --- | --- |
| Azure Arc agent | $($ai.ArcStatus) |
| Tenant | $($ai.TenantId) |
| Subscription | $($ai.SubscriptionId) |
| Resource group | $($ai.ResourceGroup) |
| Location | $($ai.Location) |

---

## Architecture diagram

``````mermaid
graph TB
    subgraph Azure["Azure"]
        ARM[Azure Resource Manager]
        ARC[Azure Arc]
        MON[Azure Monitor]
    end

    subgraph OnPrem["On-premises"]
        subgraph Cluster["$clusterName"]
$(Get-Row $cc.Nodes { param($n) "            NODE$($n.Name -replace '[^A-Za-z0-9]', '')[$($n.Name)]" })
        end
        subgraph Storage["Storage"]
            POOL[Storage pool]
            CSV[Cluster shared volumes]
        end
    end

    ARC --> Cluster
    MON --> Cluster
    Cluster --> Storage
    Cluster --> ARM
``````

---

## Operational procedures

- Check the cluster health in the Azure portal and in Azure Monitor Insights, and review the alerts.
- Check the storage capacity.
- Review the Windows and Azure Local updates in the Azure portal and apply them in a maintenance window.
- Troubleshooting on a node: ``Get-ClusterNode``, ``Get-ClusterResource``, ``Get-StoragePool``, ``Get-VirtualDisk``, ``azcmagent show``.
$credentialSection
---

*This document was generated by the Azure Local toolkit.*
"@

$safe = { param($text) ($text -replace '[^A-Za-z0-9._-]+', '-').Trim('-') }
$baseName = "$(& $safe $customer)-$(& $safe $clusterName)"
if ($PSCmdlet.ShouldProcess($OutputPath, "Write $baseName-Documentation.md and $baseName-Config.json")) {
    try {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $OutputPath "$baseName-Documentation.md") -Value $markdown -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $OutputPath "$baseName-Config.json") -Value ($package | ConvertTo-Json -Depth 10) -Encoding UTF8
    }
    catch { Exit-Failed "The documentation could not be written to ${OutputPath}: $($_.Exception.Message)" }
    Write-Line "[done]    Documentation written to $OutputPath ($baseName-Documentation.md and $baseName-Config.json)."
}
else { Write-Line "[plan]    The documentation would be written to $OutputPath as $baseName-Documentation.md and $baseName-Config.json." }

[pscustomobject]@{ Customer = $customer; Cluster = $clusterName; Sections = @($sections.Keys) -join ', '; SecretReferences = $secretLocations.Count; OutputPath = $OutputPath }
exit 0
