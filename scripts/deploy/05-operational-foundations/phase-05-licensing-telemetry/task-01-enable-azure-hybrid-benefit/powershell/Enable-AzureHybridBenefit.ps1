<#
.SYNOPSIS
    Activates Azure Hybrid Benefit for the Azure Local instance when operations.licensing.azure_hybrid_benefit of infrastructure.yml is true.

.DESCRIPTION
    Phase 05 (licensing and telemetry), Task 01. Azure Hybrid Benefit for Azure Local is a setting of the Azure Local instance (the cluster resource),
    not of the Arc machines of the nodes. It waives the Azure Local host service fee for an instance whose physical cores are covered by Windows
    Server Datacenter licenses with active Software Assurance (Microsoft Learn, Azure Hybrid Benefit for Azure Local).

    When operations.licensing.azure_hybrid_benefit is true the script:
      1. reads the instance (Get-AzStackHciCluster) and its Software Assurance status;
      2. does nothing when the benefit is already Enabled;
      3. otherwise activates it with Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -SoftwareAssuranceIntent Enable, the call Microsoft
         Learn documents for PowerShell, and reads the status again.

    When the key is false or missing the script does nothing and says so. The script never turns the benefit off: Learn says it cannot be
    deactivated for an instance once activated in the portal, and the benefit ends with the Software Assurance term. Activating it does not
    start the Windows Server subscription add-on (task 02).

    Learn limits the benefit to hyperconverged instances with cloud connected management and no external storage. The script therefore refuses
    scenario.storage_architecture san or hybrid and scenario.connectivity disconnected (exit 2) and sends nothing to Azure.

    Idempotent. -WhatIf reads the instance and changes nothing. The script reads Azure (read only) and writes only with
    Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit, behind -WhatIf. It does not sign in: run Connect-AzAccount to the tenant in
    azure.tenant_id first, with a role that can write to the instance (Contributor or Owner). The script changes the subscription of the session
    while it works and puts it back. Whether your organization has Software Assurance is not checked: Azure answers "We couldn't find your
    Software Assurance contract" when it has none (see the troubleshooting section of the Learn page).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name
        scenario.storage_architecture, scenario.connectivity
        operations.licensing.azure_hybrid_benefit

    Exit codes: 0 the benefit is Enabled (activated now, already there, planned under -WhatIf) or the file does not ask for it; 1 an Azure call
    failed or a precondition failed (not signed in, wrong tenant, Az.StackHCI missing, the instance not found, the activation failed); 2 a value
    in the file is missing or not usable, or the scenario cannot use the benefit.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Enable-AzureHybridBenefit.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows the Software Assurance status of the instance and whether it would be activated. Changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Enable-AzureHybridBenefit.ps1 -InfrastructureFile ./infrastructure.yml

    Activates the benefit. Run it again: it reports that the benefit is already Enabled.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Status([object]$Cluster) {
    if ($Cluster -and $Cluster.PSObject.Properties['SoftwareAssurancePropertySoftwareAssuranceStatus'] -and $Cluster.SoftwareAssurancePropertySoftwareAssuranceStatus) { return [string]$Cluster.SoftwareAssurancePropertySoftwareAssuranceStatus }
    ''
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$requested = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.licensing.azure_hybrid_benefit'
if ($null -ne $requested -and $requested -isnot [bool]) { Exit-InputProblem "operations.licensing.azure_hybrid_benefit must be true or false; found '$requested'." }
if ($requested -ne $true) {
    Write-Line 'operations.licensing.azure_hybrid_benefit is not true: nothing to do. This script never turns the benefit off.'
    exit 0
}

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$clusterName = Get-Text 'cluster.name'
$architecture = (Get-Text 'scenario.storage_architecture').ToLowerInvariant()
$connectivity = (Get-Text 'scenario.connectivity').ToLowerInvariant()

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The Azure Local instance is in it.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. It is the name of the Azure Local instance.' }
if ($architecture -in 'san', 'hybrid') { Exit-InputProblem "scenario.storage_architecture is $architecture. Azure Hybrid Benefit for Azure Local supports only hyperconverged instances with no external storage (Microsoft Learn). Set operations.licensing.azure_hybrid_benefit to false." }
if ($connectivity -eq 'disconnected') { Exit-InputProblem 'scenario.connectivity is disconnected. Azure Hybrid Benefit for Azure Local supports only instances with cloud connected management (Microsoft Learn).' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzStackHciCluster', 'Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.StackHCI modules: Install-Module Az.Accounts, Az.StackHCI -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$row = [ordered]@{ Cluster = $clusterName; Action = ''; Status = ''; Detail = '' }
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    $cluster = $null
    try { $cluster = Get-AzStackHciCluster -Name $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    if (-not $cluster) { throw "The Azure Local instance '$clusterName' was not found in the resource group '$group'. Deploy it first, then run this script." }

    $status = Get-Status $cluster
    $row.Status = $status
    if ($status -ieq 'Enabled') {
        $row.Action = 'AlreadyEnabled'
        Write-Line "[exists]  Azure Hybrid Benefit is already Enabled on '$clusterName', nothing changed."
    }
    elseif ($PSCmdlet.ShouldProcess("Azure Local instance '$clusterName' in '$group'", 'Activate Azure Hybrid Benefit (it cannot be deactivated afterwards)')) {
        Write-Warning 'Azure Hybrid Benefit cannot be deactivated for an instance after activation. It needs Windows Server Datacenter licenses with active Software Assurance for the physical cores of the instance.'
        $null = Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -ClusterName $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -SoftwareAssuranceIntent 'Enable' -ErrorAction Stop
        $after = Get-AzStackHciCluster -Name $clusterName -ResourceGroupName $group -SubscriptionId $subscriptionId -ErrorAction Stop
        $row.Status = Get-Status $after
        $row.Action = 'Activated'
        if ($row.Status -ine 'Enabled') { $row.Detail = "The call succeeded, but the status reads '$($row.Status)'. Read it again in a few minutes." }
        Write-Line "[done]    Azure Hybrid Benefit activated on '$clusterName' (status: $($row.Status))."
    }
    else {
        $row.Action = 'WouldActivate'
        Write-Line "[plan]    Azure Hybrid Benefit would be activated on '$clusterName' (status now: $(if ($status) { $status } else { 'not reported' }))."
    }
}
catch {
    $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
    Write-Warning "${clusterName}: $($row.Detail)"
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
