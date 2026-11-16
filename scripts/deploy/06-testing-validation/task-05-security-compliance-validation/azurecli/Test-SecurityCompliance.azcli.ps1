<#
.SYNOPSIS
    Validates the Azure side of the security and compliance posture with the Azure CLI. Read only.

.DESCRIPTION
    Stage 06 (testing and validation), Task 05, Azure CLI variant of Test-SecurityCompliance.ps1, for the part of that script that acts on Azure. It checks:
    - Microsoft Defender for Cloud free level: Foundational CSPM (the Microsoft.Security resource provider is registered) and the Microsoft cloud
      security benchmark assignment on the subscription or above it. No paid plan is checked, expected or turned on.
    - Azure RBAC role assignments on the resource group of the cluster (including inherited ones), with a warning when there are more Owner assignments
      than -MaximumOwnerAssignments.
    - Azure Policy compliance state of the resource group (counts per compliance state; non-compliant resources are reported as a warning).
    - Writes the findings as one JSON report when -OutputPath names a folder.
    The checks that run on the nodes (BitLocker, Microsoft Defender Antivirus, audit policy) are not Azure work and stay with Test-SecurityCompliance.ps1
    (PowerShell remoting); this script does not read the cluster.

    Read only: it changes nothing in Azure and nothing on the cluster. The script does not sign in and asks nothing: run az login to the tenant of
    azure.tenant_id first, as an account that may read the subscription. It does not change the Azure CLI default subscription: every call carries
    --subscription.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group
        security.defender_for_cloud.enabled and security.defender_for_cloud.apply_cloud_security_benchmark: when the design turns the free Defender for
        Cloud level (or the benchmark assignment) off, that check is not run. Both are true when the key is absent (the registry default).

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 no check failed (warnings do not fail); 1 a Defender for Cloud check failed or a precondition failed (az missing, not signed in, wrong
    tenant, an Azure call failed); 2 a value of the file is missing or the file cannot be read.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER OutputPath
    Folder to save the JSON validation report in. Empty (the default): no report file is written.

.PARAMETER MaximumOwnerAssignments
    The most Owner role assignments on the resource group before the script warns. Default: 3 (the Azure RBAC best practice: fewer than three owners).

.EXAMPLE
    az login --tenant <tenant-id>
    ./Test-SecurityCompliance.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Checks the free Defender for Cloud level, the role assignments and the policy compliance of the resource group.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$OutputPath = '',
    [ValidateRange(1, 1000)][int]$MaximumOwnerAssignments = 3
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common'))
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'azure-cli', 'AzlAzureCliArgument.psm1')) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
# Built-in initiative "Microsoft cloud security benchmark". Fixed by Microsoft: the ID is the same in every tenant (Microsoft Learn, Azure Policy built-in initiatives).
$BenchmarkDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
# The resource provider that carries Foundational CSPM, the free plan of Defender for Cloud. Fixed by Azure.
$SecurityProvider = 'Microsoft.Security'
# The built-in role name Azure RBAC uses for full access.
$OwnerRoleName = 'Owner'

function Write-Report([string]$Message, [string]$Level = 'INFO') {
    Write-Information -MessageData ('[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message) -InformationAction Continue
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the text of standard output; throws when az ends with an error.
function Invoke-Az {
    $arguments = @($args | ForEach-Object { $_ } | ForEach-Object { [string]$_ })
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $arguments
    if ($unsafe) { Exit-InputProblem $unsafe }
    $all = @(& az @arguments '--only-show-errors' 2>&1)
    $code = $LASTEXITCODE
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw $(if ($err) { $err.Trim() } else { $out.Trim() }) }
    $out.Trim()
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }
# security.defender_for_cloud.enabled and apply_cloud_security_benchmark: both true when the key is absent (the registry default).
$defenderEnabled = $true
$checkBenchmark = $true
$enabledValue = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'security.defender_for_cloud.enabled'
$benchmarkValue = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'security.defender_for_cloud.apply_cloud_security_benchmark'
if ($enabledValue -is [bool]) { $defenderEnabled = $enabledValue }
if ($benchmarkValue -is [bool]) { $checkBenchmark = $benchmarkValue }
$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$subscriptionId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
$resourceGroupName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.resource_group')).Trim()
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $resourceGroupName) { Exit-InputProblem 'azure.resource_group is required in the infrastructure file.' }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Test-SecurityCompliance.ps1.' }
try { $signedInTenant = Invoke-Az account show --subscription $subscriptionId --query tenantId --output tsv }
catch { Exit-Failed "Not signed in to Azure for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($_.Exception.Message)" }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Report '========================================' 'HEADER'
Write-Report 'Security and compliance validation (Azure side, Azure CLI)' 'HEADER'
Write-Report '========================================' 'HEADER'
Write-Report "Subscription: $subscriptionId, resource group: $resourceGroupName"

$report = [ordered]@{ Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; SubscriptionId = $subscriptionId; ResourceGroup = $resourceGroupName; Sections = [ordered]@{} }
$subscriptionScope = "/subscriptions/$subscriptionId"
$groupScope = "$subscriptionScope/resourceGroups/$resourceGroupName"
$problems = 0

# 1. Defender for Cloud, free level only.
$defenderResults = @()
if ($defenderEnabled) {
    Write-Report 'Validating Microsoft Defender for Cloud (free level)...' 'HEADER'
    try {
        $state = Invoke-Az provider show --subscription $subscriptionId --namespace $SecurityProvider --query registrationState --output tsv
        $ok = $state -eq 'Registered'
        Write-Report "  Foundational CSPM ($SecurityProvider provider): $state" $(if ($ok) { 'SUCCESS' } else { 'WARN' })
        $defenderResults += [pscustomobject]@{ Plan = 'FoundationalCspm'; Tier = $state; Status = $(if ($ok) { 'PASS' } else { 'FAIL' }) }
        if ($checkBenchmark) {
            $assignments = @(@(Invoke-Az policy assignment list --subscription $subscriptionId --scope $subscriptionScope --disable-scope-strict-match --output json | ConvertFrom-Json) |
                    Where-Object { $null -ne $_ -and -not ([string]$_.scope).StartsWith("$subscriptionScope/", [StringComparison]::OrdinalIgnoreCase) })
            $assigned = @($assignments | Where-Object { [string]$_.policyDefinitionId -eq $BenchmarkDefinitionId }).Count -gt 0
            Write-Report "  Microsoft cloud security benchmark: $(if ($assigned) { 'Assigned' } else { 'NotAssigned' })" $(if ($assigned) { 'SUCCESS' } else { 'WARN' })
            $defenderResults += [pscustomobject]@{ Plan = 'CloudSecurityBenchmark'; Tier = $(if ($assigned) { 'Assigned' } else { 'NotAssigned' }); Status = $(if ($assigned) { 'PASS' } else { 'FAIL' }) }
        }
        else { Write-Report '  Microsoft cloud security benchmark: not checked (security.defender_for_cloud.apply_cloud_security_benchmark is false)' }
    }
    catch {
        Write-Report "  Defender check failed: $($_.Exception.Message)" 'ERROR'
        $defenderResults += [pscustomobject]@{ Plan = 'DefenderForCloud'; Tier = 'Error'; Status = 'FAIL' }
    }
}
else { Write-Report 'Defender for Cloud: not checked (security.defender_for_cloud.enabled is false)' }
$report.Sections['DefenderForCloud'] = $defenderResults
$problems += @($defenderResults | Where-Object Status -EQ 'FAIL').Count

# 2. RBAC role assignments of the resource group.
Write-Report 'Validating RBAC role assignments...' 'HEADER'
$rbac = $null
try {
    $roleAssignments = @(@(Invoke-Az role assignment list --subscription $subscriptionId --scope $groupScope --include-inherited --output json | ConvertFrom-Json) | Where-Object { $null -ne $_ })
    if ($roleAssignments.Count -gt 0) {
        foreach ($roleGroup in @($roleAssignments | Group-Object -Property roleDefinitionName)) { Write-Report "  $($roleGroup.Name): $($roleGroup.Count) assignment(s)" }
    }
    else { Write-Report '  No RBAC assignments found on the resource group scope' 'WARN' }
    $ownerCount = @($roleAssignments | Where-Object { [string]$_.roleDefinitionName -eq $OwnerRoleName }).Count
    if ($ownerCount -gt $MaximumOwnerAssignments) { Write-Report "  $ownerCount Owner assignments (recommended: at most $MaximumOwnerAssignments)" 'WARN' }
    $rbac = [pscustomobject]@{ TotalAssignments = $roleAssignments.Count; OwnerCount = $ownerCount }
}
catch {
    Write-Report "  RBAC check failed: $($_.Exception.Message)" 'ERROR'
    $problems++
}
$report.Sections['RBAC'] = $rbac

# 3. Azure Policy compliance of the resource group.
Write-Report 'Validating Azure Policy compliance...' 'HEADER'
$policy = @()
try {
    $states = @((Invoke-Az policy state list --subscription $subscriptionId --resource-group $resourceGroupName --query '[].complianceState' --output tsv) -split '\r?\n' | Where-Object { $_ })
    if ($states.Count -gt 0) {
        foreach ($stateGroup in @($states | Group-Object)) {
            Write-Report "  $($stateGroup.Name): $($stateGroup.Count) record(s)" $(if ($stateGroup.Name -eq 'NonCompliant') { 'WARN' } else { 'INFO' })
            $policy += [pscustomobject]@{ ComplianceState = $stateGroup.Name; Count = $stateGroup.Count }
        }
    }
    else { Write-Report '  No policy state data available' }
}
catch {
    Write-Report "  Policy compliance check failed: $($_.Exception.Message)" 'ERROR'
    $problems++
}
$report.Sections['AzurePolicy'] = $policy

if ($OutputPath) {
    if (-not (Test-Path -LiteralPath $OutputPath)) { $null = New-Item -Path $OutputPath -ItemType Directory -Force }
    $reportFile = Join-Path $OutputPath "06-security-compliance-azcli-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportFile -Encoding utf8NoBOM
    Write-Report "Report saved: $reportFile"
}

$passed = @($defenderResults | Where-Object Status -EQ 'PASS').Count
Write-Report "Defender for Cloud free level checks passed: $passed / $($defenderResults.Count)"
if ($problems -gt 0) { exit 1 }
exit 0
