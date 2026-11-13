#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the placeholder scripts of the task folders under scripts/deploy from a coverage document.

.DESCRIPTION
    Reads the script list of a coverage document (a Markdown file with a task table and a "Scripts to Create (Complete List)"
    table) and writes one placeholder per entry that does not exist yet:

        PS Standalone, PS Orchestrated   a PowerShell placeholder in powershell/
        AzCLI                            an Azure CLI placeholder in azurecli/, only where scripts/deploy/common/TaskCatalogue.psd1
                                         says Azure CLI applies to the task (AzureCli yes or unclear)

    A placeholder does not do the task: running it ends with exit code 3 and changes nothing (see DeploymentScaffold.psm1).

    What is NOT written:
        Bash        The toolkit has no Bash scripts. Entries of type Bash are skipped.
        AzCLI       for a task whose catalogue entry says AzureCli no (the task runs on a node, against on-premises Active
                    Directory or DNS, against hardware or a BMC, or is OS work). Skipped with a note.
        The module  DeploymentScaffold.psm1 is maintained by hand. This script no longer rewrites it.

    A task that is not in the catalogue stops the run: add it to TaskCatalogue.psd1 first, so the classification stays in one
    place. Existing files are never overwritten.

.PARAMETER CoverageDocumentPath
    The coverage document. It lives outside this repository; pass its path.

.PARAMETER RepositoryRoot
    The repository to write into. Default: the repository this script is in.

.PARAMETER TaskCatalogPath
    The task catalogue. Default: TaskCatalogue.psd1 next to this script.

.EXAMPLE
    ./Generate-DeployScriptScaffolds.ps1 -CoverageDocumentPath ./deploy-script-coverage.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CoverageDocumentPath,
    [string]$RepositoryRoot = ([System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))),
    [string]$TaskCatalogPath = (Join-Path $PSScriptRoot 'TaskCatalogue.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$deployRoot = [System.IO.Path]::Combine($RepositoryRoot, 'scripts', 'deploy')

function Get-CommonLoaderContent {
@'
function Get-DeploymentCommonModulePath {
    $current = Get-Item -LiteralPath $PSScriptRoot
    while ($null -ne $current) {
        $candidate = [System.IO.Path]::Combine($current.FullName, 'scripts', 'deploy', 'common', 'DeploymentScaffold.psm1')
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }

        $current = $current.Parent
    }

    throw "Unable to locate DeploymentScaffold.psm1 from '$PSScriptRoot'."
}

Import-Module (Get-DeploymentCommonModulePath) -Force
'@
}

function Get-PlaceholderHeaderContent {
@'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
'@
}

function Get-PowerShellStandaloneTemplate {
    param(
        [string]$TaskPath,
        [string]$ActionName
    )

    $template = @'
#Requires -Version 7.0
# PLACEHOLDER: this script does not do the task. It ends with exit code 3 (NOT IMPLEMENTED) and changes nothing.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$EnvironmentName = '',
    [string]$ProjectName = '',
    [string]$SubscriptionId = '',
    [string]$ResourceGroupName = '',
    [string]$LogPath = ''
)

#region CONFIGURATION
$environment_name = 'ProjectIIC'
$project_name = 'Azure Local Toolkit'
$subscription_id = ''
$resource_group_name = ''
#endregion

if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { $EnvironmentName = $environment_name }
if ([string]::IsNullOrWhiteSpace($ProjectName)) { $ProjectName = $project_name }
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { $SubscriptionId = $subscription_id }
if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) { $ResourceGroupName = $resource_group_name }

__PLACEHOLDER_HEADER__

__COMMON_LOADER__

Invoke-DeploymentStandalone `
    -ScriptPath $PSCommandPath `
    -TaskPath '__TASK_PATH__' `
    -ActionName '__ACTION_NAME__' `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters `
    -Configuration ([ordered]@{
        environment_name = $EnvironmentName
        project_name = $ProjectName
        subscription_id = $SubscriptionId
        resource_group_name = $ResourceGroupName
    })
'@

    return $template.Replace('__PLACEHOLDER_HEADER__', (Get-PlaceholderHeaderContent).Trim()).Replace('__COMMON_LOADER__', (Get-CommonLoaderContent).Trim()).Replace('__TASK_PATH__', $TaskPath).Replace('__ACTION_NAME__', $ActionName)
}

function Get-PowerShellOrchestratedTemplate {
    param(
        [string]$TaskPath,
        [string]$ActionName
    )

    $template = @'
#Requires -Version 7.0
# PLACEHOLDER: this script does not do the task. It ends with exit code 3 (NOT IMPLEMENTED) and changes nothing.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = '',
    [System.Management.Automation.PSCredential]$Credential = $null,
    [string[]]$TargetNode = @(),
    [string]$LogPath = ''
)

__PLACEHOLDER_HEADER__

__COMMON_LOADER__

Invoke-DeploymentOrchestrated `
    -ScriptPath $PSCommandPath `
    -TaskPath '__TASK_PATH__' `
    -ActionName '__ACTION_NAME__' `
    -ConfigPath $ConfigPath `
    -Credential $Credential `
    -TargetNode $TargetNode `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters
'@

    return $template.Replace('__PLACEHOLDER_HEADER__', (Get-PlaceholderHeaderContent).Trim()).Replace('__COMMON_LOADER__', (Get-CommonLoaderContent).Trim()).Replace('__TASK_PATH__', $TaskPath).Replace('__ACTION_NAME__', $ActionName)
}

function Get-AzCliPowerShellTemplate {
    param(
        [string]$TaskPath,
        [string]$ActionName
    )

    $template = @'
#Requires -Version 7.0
# PLACEHOLDER: this script does not do the task. It ends with exit code 3 (NOT IMPLEMENTED) and changes nothing.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = '',
    [string]$LogPath = ''
)

__PLACEHOLDER_HEADER__

__COMMON_LOADER__

Invoke-DeploymentAzCliPowerShell `
    -ScriptPath $PSCommandPath `
    -TaskPath '__TASK_PATH__' `
    -ActionName '__ACTION_NAME__' `
    -ConfigPath $ConfigPath `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters
'@

    return $template.Replace('__PLACEHOLDER_HEADER__', (Get-PlaceholderHeaderContent).Trim()).Replace('__COMMON_LOADER__', (Get-CommonLoaderContent).Trim()).Replace('__TASK_PATH__', $TaskPath).Replace('__ACTION_NAME__', $ActionName)
}

function Add-CellValue {
    param(
        [string]$CurrentValue,
        [string]$NewValue
    )

    $trimmed = $CurrentValue.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $NewValue
    }

    $parts = $trimmed -split '<br/>'
    if ($parts -contains $NewValue) {
        return $trimmed
    }

    return $trimmed + '<br/>' + $NewValue
}

# The task catalogue: the one list of task folders and of whether Azure CLI applies to them.
$catalogue = Import-PowerShellDataFile -LiteralPath $TaskCatalogPath
$azureCliOf = @{}
foreach ($task in $catalogue.Tasks) {
    $azureCliOf[$task.Path] = $task.AzureCli
}

$docLines = Get-Content -LiteralPath $CoverageDocumentPath
$taskMap = @{}
foreach ($line in $docLines) {
    if ($line -eq '## Standards-Based Script Authoring Plan') {
        break
    }

    if ($line -match '^\|\s*(\d+)\s*\|\s*([^|]+?/[^|]+?)\s*\|') {
        $taskMap[[int]$matches[1]] = $matches[2].Trim()
    }
}

$entries = New-Object System.Collections.Generic.List[object]
$skippedBash = 0
$skippedNotAzure = 0
$inScriptsSection = $false
foreach ($line in $docLines) {
    if ($line -eq '## Scripts to Create (Complete List)' -or $line -eq '## Scripts Created (Complete List)') {
        $inScriptsSection = $true
        continue
    }

    if (-not $inScriptsSection) {
        continue
    }

    if ($line -match '^\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|\s*`([^`]+)`\s*\|\s*([^|]+?)\s*\|\s*`([^`]+)`\s*\|') {
        $entry = [pscustomobject]@{
            TaskNumber = [int]$matches[1]
            TaskName = $matches[2].Trim()
            ScriptName = $matches[3].Trim()
            ScriptType = $matches[4].Trim()
            Subfolder = $matches[5].Trim().Trim('/')
        }

        if (-not $taskMap.ContainsKey($entry.TaskNumber)) {
            throw "Task number $($entry.TaskNumber) was not found in the coverage table."
        }

        $taskPath = $taskMap[$entry.TaskNumber]
        if (-not $azureCliOf.ContainsKey($taskPath)) {
            throw "Task '$taskPath' is not in the task catalogue '$TaskCatalogPath'. Add it with AzureCli yes, no or unclear first."
        }

        if ($entry.ScriptType -eq 'Bash') {
            Write-Output "Skipped (the toolkit has no Bash scripts): $taskPath / $($entry.ScriptName)"
            $skippedBash++
            continue
        }

        if ($entry.ScriptType -eq 'AzCLI' -and $azureCliOf[$taskPath] -eq 'no') {
            Write-Output "Skipped (Azure CLI does not apply to this task): $taskPath / $($entry.ScriptName)"
            $skippedNotAzure++
            continue
        }

        $entries.Add($entry)
    }
}

$created = 0
$skipped = 0
foreach ($entry in $entries) {
    $taskPath = $taskMap[$entry.TaskNumber]
    $targetDirectory = Join-Path $deployRoot ($taskPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $targetDirectory = Join-Path $targetDirectory $entry.Subfolder
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null

    $targetFile = Join-Path $targetDirectory $entry.ScriptName
    if (Test-Path -LiteralPath $targetFile) {
        $skipped++
        continue
    }

    $actionName = [System.IO.Path]::GetFileNameWithoutExtension($entry.ScriptName)
    switch ($entry.ScriptType) {
        'PS Standalone' { $content = Get-PowerShellStandaloneTemplate -TaskPath $taskPath -ActionName $actionName }
        'PS Orchestrated' { $content = Get-PowerShellOrchestratedTemplate -TaskPath $taskPath -ActionName $actionName }
        'AzCLI' { $content = Get-AzCliPowerShellTemplate -TaskPath $taskPath -ActionName $actionName }
        default { throw "Unsupported script type '$($entry.ScriptType)'." }
    }

    Set-Content -LiteralPath $targetFile -Value $content -Encoding utf8
    $created++
}

$entriesByTask = @{}
foreach ($entry in $entries) {
    if (-not $entriesByTask.ContainsKey($entry.TaskNumber)) {
        $entriesByTask[$entry.TaskNumber] = @()
    }
    $entriesByTask[$entry.TaskNumber] += $entry
}

for ($i = 0; $i -lt $docLines.Count; $i++) {
    $line = $docLines[$i]
    if ($line -match '^\|\s*(\d+)\s*\|\s*([^|]+?/[^|]+?)\s*\|') {
        $taskNumber = [int]$matches[1]
        if (-not $entriesByTask.ContainsKey($taskNumber)) {
            continue
        }

        $parts = $line.Split('|')
        foreach ($entry in $entriesByTask[$taskNumber]) {
            switch ($entry.ScriptType) {
                'PS Standalone' { $parts[7] = ' ' + (Add-CellValue -CurrentValue $parts[7] -NewValue $entry.ScriptName) + ' ' }
                'PS Orchestrated' { $parts[8] = ' ' + (Add-CellValue -CurrentValue $parts[8] -NewValue $entry.ScriptName) + ' ' }
                'AzCLI' { $parts[9] = ' ' + (Add-CellValue -CurrentValue $parts[9] -NewValue $entry.ScriptName) + ' ' }
            }
        }

        if ($parts[14].Trim() -ne 'Not needed') {
            $parts[14] = ' Pass '
        }

        $docLines[$i] = '| ' + (($parts[1..14] | ForEach-Object { $_.Trim() }) -join ' | ') + ' |'
    }
}

$docText = $docLines -join "`r`n"
$docText = $docText.Replace('## Scripts to Create (Complete List)', '## Scripts Created (Complete List)')
$docText = $docText.Replace('> Derived from blank cells in the coverage table where the corresponding language column shows "Needed = Yes."', '> Derived from blank cells in the coverage table where the corresponding language column showed "Needed = Yes."')
$docText = $docText.Replace('> Each entry is one script file that does not yet exist and must be authored.', '> Each entry below has now been authored and added to the mapped toolkit task folder.')
$docText = $docText.Replace('| Tasks with no scripts yet (In progress) | 6 |', '| Tasks with no scripts yet (In progress) | 0 |')
$docText = $docText.Replace('### Scripts-to-Create Summary', '### Scripts Created Summary')
Set-Content -LiteralPath $CoverageDocumentPath -Value $docText -Encoding utf8

Write-Output "Created $created placeholders; skipped $skipped existing; left out $skippedBash Bash and $skippedNotAzure Azure CLI entries."
