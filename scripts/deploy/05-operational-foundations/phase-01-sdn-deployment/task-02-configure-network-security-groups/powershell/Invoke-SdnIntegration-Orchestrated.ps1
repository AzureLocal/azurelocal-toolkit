<#
.SYNOPSIS
    Day 2 management of the Azure Local network security groups in one run: creates what the file lists and Azure lacks, brings the rules in line
    with the file, then verifies them. Runs the three scripts of the toolkit that do each part.

.DESCRIPTION
    Operational foundations, phase 01 (SDN), Task 02 (manage network security groups). SDN enabled by Azure Arc has no load balancer and no gateway
    (Microsoft Learn, sdn-overview): the day 2 work is the network security groups and their rules. Microsoft documents those groups for the Azure
    CLI only (az stack-hci-vm network nsg); there is no Az PowerShell cmdlet. So this script holds no logic of its own: it runs, in order,

      1. scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-07-configure-nsgs/powershell/New-NetworkSecurityGroup.ps1
         creates every group of networking.network_security_groups[] that Azure lacks, and the rules a group lacks.
      2. scripts/deploy/05-operational-foundations/phase-01-sdn-deployment/task-02-configure-network-security-groups/azurecli/Set-NetworkSecurityGroupRule.azcli.ps1
         updates the rules that differ from the file; with -RemoveUnlistedRules it also removes the rules the file does not list (after every
         rule of the file is in place).
      3. scripts/deploy/05-operational-foundations/phase-01-sdn-deployment/task-03-configure-network-security-groups/azurecli/Test-NetworkSecurityGroupRule.azcli.ps1
         checks every group and rule against the file. Read only.

    A step that ends with exit code 2 (a value in the file is not usable, or SDN is off) or 1 (a call or a precondition failed) stops the run: the
    next step does not run. -WhatIf is passed to steps 1 and 2, which then read Azure and change nothing; step 3 is not run under -WhatIf (it would
    report the groups that the plan has not created).

    Prerequisites: SDN enabled by Azure Arc (sdn.enabled true, Enable-ArcSdn.ps1 of phase 06 task 01), the Azure CLI with the stack-hci-vm extension,
    signed in with az login --tenant <azure.tenant_id>. The scripts read infrastructure.yml themselves (azure.*, tags, sdn.enabled,
    networking.network_security_groups[] with its rules); this script reads no key of its own.

    Exit codes: 0 every step ended with 0; 1 a step failed; 2 a value in the file is missing or not usable, or SDN is off (from the step that found it).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Passed to each step.

.PARAMETER RemoveUnlistedRules
    Optional. Passed to step 2: remove the rules a group has and the file does not list.

.PARAMETER LogPath
    Optional. Passed to each step: the progress lines are appended to this file. Keep it out of the repository.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Invoke-SdnIntegration-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what each step would create or change. Changes nothing.

.EXAMPLE
    ./Invoke-SdnIntegration-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -RemoveUnlistedRules
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [switch]$RemoveUnlistedRules,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$deploy = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
$steps = @(
    @{ Name = 'Create groups and rules'; Path = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-06-post-deployment', 'task-07-configure-nsgs', 'powershell', 'New-NetworkSecurityGroup.ps1'); Plans = $true; Extra = @{} }
    @{ Name = 'Bring rules in line'; Path = [IO.Path]::Combine($deploy, '05-operational-foundations', 'phase-01-sdn-deployment', 'task-02-configure-network-security-groups', 'azurecli', 'Set-NetworkSecurityGroupRule.azcli.ps1'); Plans = $true; Extra = $(if ($RemoveUnlistedRules) { @{ RemoveUnlistedRules = $true } } else { @{} }) }
    @{ Name = 'Verify'; Path = [IO.Path]::Combine($deploy, '05-operational-foundations', 'phase-01-sdn-deployment', 'task-03-configure-network-security-groups', 'azurecli', 'Test-NetworkSecurityGroupRule.azcli.ps1'); Plans = $false; Extra = @{} }
)
foreach ($s in $steps) { if (-not (Test-Path -LiteralPath $s.Path)) { Write-Error "The step script is missing: $($s.Path)" -ErrorAction Continue; exit 1 } }
if (-not (Test-Path -LiteralPath $InfrastructureFile)) { Write-Error "The infrastructure file was not found: $InfrastructureFile" -ErrorAction Continue; exit 2 }

$summary = [System.Collections.Generic.List[object]]::new()
$final = 0
foreach ($s in $steps) {
    if ($WhatIfPreference -and -not $s.Plans) {
        $summary.Add([pscustomobject][ordered]@{ Step = $s.Name; Script = (Split-Path -Leaf $s.Path); ExitCode = $null; Result = 'Skipped'; Detail = 'not run under -WhatIf' })
        continue
    }
    $arguments = @{ InfrastructureFile = $InfrastructureFile } + $s.Extra
    if ($LogPath) { $arguments.LogPath = $LogPath }
    if ($s.Plans) { $arguments.WhatIf = [bool]$WhatIfPreference }
    Write-Information -MessageData "---- $($s.Name): $(Split-Path -Leaf $s.Path)" -InformationAction Continue
    $global:LASTEXITCODE = 0
    $detail = ''
    try { & $s.Path @arguments } catch { $detail = $_.Exception.Message; Write-Error $detail -ErrorAction Continue; $global:LASTEXITCODE = 1 }
    $code = [int]$LASTEXITCODE
    $result = switch ($code) { 0 { 'Passed' } 2 { 'InputProblem' } default { 'Failed' } }
    $summary.Add([pscustomobject][ordered]@{ Step = $s.Name; Script = (Split-Path -Leaf $s.Path); ExitCode = $code; Result = $result; Detail = $detail })
    if ($code -ne 0) { $final = $(if ($code -eq 2) { 2 } else { 1 }); break }
}

$summary
exit $final
