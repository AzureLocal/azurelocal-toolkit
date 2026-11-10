#Requires -Version 7.0
<#
.SYNOPSIS
    Writes docs/script-status.md, the table of every task folder under scripts/deploy with its PowerShell and Azure CLI status.

.DESCRIPTION
    One row per task folder (a folder that holds a powershell, azurecli or bash folder), grouped by stage:

        PowerShell          built      the powershell folder holds at least one real script
                            not built  it holds only placeholders, or nothing
        Azure CLI           built      the azurecli folder holds at least one real script
                            not built  Azure CLI applies to the task and there is no real script yet
                            not applicable   the task does not act on Azure (TaskCatalogue.psd1: AzureCli no)
        Azure CLI applies   yes, no or unclear, from TaskCatalogue.psd1

    A placeholder is a script that only imports DeploymentScaffold.psm1 and calls one of its Invoke-Deployment functions. It
    does not do the task: it ends with exit code 3 and changes nothing. It never counts as built.

    The task folders come from the file system and the Azure CLI classification from the catalogue; the two must list the
    same folders, or this script stops with exit code 1 and names the difference.

    The page is generated: change the scripts or the catalogue, then run this script. With -Check nothing is written; the
    script exits 1 when the page on disk differs from what it would write (the Pester tests run this).

.PARAMETER DeployRoot
    The scripts/deploy folder. Default: the one this script is in.

.PARAMETER TaskCatalogPath
    The task catalogue. Default: TaskCatalogue.psd1 next to this script.

.PARAMETER OutputPath
    The page to write. Default: docs/script-status.md in the repository.

.PARAMETER Check
    Compare instead of write; exit 1 when the page is out of date.

.EXAMPLE
    ./scripts/deploy/common/New-DeployScriptStatus.ps1

.EXAMPLE
    ./scripts/deploy/common/New-DeployScriptStatus.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$DeployRoot = ([System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))),
    [string]$TaskCatalogPath = (Join-Path $PSScriptRoot 'TaskCatalogue.psd1'),
    [string]$OutputPath = ([System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'docs', 'script-status.md'))),
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DeployRoot = (Resolve-Path -LiteralPath $DeployRoot).Path.TrimEnd('\', '/')
$placeholderPattern = 'Invoke-Deployment(AzCliPowerShell|Orchestrated|Standalone)\b'

function Get-RelativeTaskPath {
    param([string]$FullPath)
    return $FullPath.Substring($DeployRoot.Length).TrimStart('\', '/').Replace('\', '/')
}

function Get-ScriptCount {
    # Real scripts and placeholders in one folder: a placeholder calls an Invoke-Deployment function of the shared module.
    param([string]$Folder)

    $real = 0
    $placeholder = 0
    if (Test-Path -LiteralPath $Folder -PathType Container) {
        foreach ($file in (Get-ChildItem -LiteralPath $Folder -Recurse -File -Filter '*.ps1')) {
            if ((Get-Content -LiteralPath $file.FullName -Raw) -match $placeholderPattern) { $placeholder++ } else { $real++ }
        }
    }

    return [pscustomobject]@{ Real = $real; Placeholder = $placeholder }
}

# The task folders: every folder that holds a powershell, azurecli or bash folder (scripts/deploy/common is not a task).
$commonRoot = Join-Path $DeployRoot 'common'
$onDisk = [string[]]@(
    Get-ChildItem -LiteralPath $DeployRoot -Recurse -Directory |
        Where-Object { $_.Name -in 'powershell', 'azurecli', 'bash' -and -not $_.FullName.StartsWith($commonRoot + [System.IO.Path]::DirectorySeparatorChar) } |
        ForEach-Object { Get-RelativeTaskPath -FullPath $_.Parent.FullName } |
        Select-Object -Unique
)
[Array]::Sort($onDisk, [System.StringComparer]::Ordinal)

$catalogue = Import-PowerShellDataFile -LiteralPath $TaskCatalogPath
$catalogued = @{}
foreach ($task in $catalogue.Tasks) {
    if ($task.AzureCli -notin 'yes', 'no', 'unclear') {
        throw "Catalogue entry '$($task.Path)' has AzureCli '$($task.AzureCli)'; it must be yes, no or unclear."
    }
    if ($catalogued.ContainsKey($task.Path)) { throw "Catalogue lists '$($task.Path)' twice." }
    $catalogued[$task.Path] = $task
}

$notInCatalogue = @($onDisk | Where-Object { -not $catalogued.ContainsKey($_) })
$notOnDisk = @($catalogued.Keys | Where-Object { $_ -notin $onDisk } | Sort-Object)
if ($notInCatalogue.Count -gt 0 -or $notOnDisk.Count -gt 0) {
    foreach ($path in $notInCatalogue) { Write-Error "Task folder '$path' is not in $TaskCatalogPath. Add it with AzureCli yes, no or unclear." -ErrorAction Continue }
    foreach ($path in $notOnDisk) { Write-Error "Catalogue entry '$path' has no task folder under $DeployRoot. Remove it or restore the folder." -ErrorAction Continue }
    exit 1
}

$rows = @(foreach ($path in $onDisk) {
    $entry = $catalogued[$path]
    $ps = Get-ScriptCount -Folder (Join-Path (Join-Path $DeployRoot $path) 'powershell')
    $az = Get-ScriptCount -Folder (Join-Path (Join-Path $DeployRoot $path) 'azurecli')
    $azureCli = if ($az.Real -gt 0) { 'built' } elseif ($entry.AzureCli -eq 'no') { 'not applicable' } else { 'not built' }
    [pscustomobject]@{
        Path       = $path
        Stage      = $path.Split('/')[0]
        Rest       = $path.Substring($path.IndexOf('/') + 1)
        PowerShell = $(if ($ps.Real -gt 0) { 'built' } else { 'not built' })
        AzureCli   = $azureCli
        Applies    = $entry.AzureCli
        Reason     = $entry.Reason
    }
})

$sb = [System.Text.StringBuilder]::new()
function Out-Line { param([string]$Text = '') [void]$sb.Append($Text).Append("`n") }

Out-Line '# Script status'
Out-Line
Out-Line 'Which task folders under `scripts/deploy` have a script, per kind. **Generated** by `scripts/deploy/common/New-DeployScriptStatus.ps1` from the task folders and from `scripts/deploy/common/TaskCatalogue.psd1`. Do not edit it by hand: change the scripts or the catalogue and run the script. A test fails when this page is out of date (`./scripts/deploy/common/New-DeployScriptStatus.ps1 -Check`).'
Out-Line
Out-Line 'The toolkit is PowerShell. Azure CLI scripts exist only for tasks that act on Azure. Bash is not part of the layout and is not in the tables below.'
Out-Line
# Older Bash scripts that are still in a task folder: said here, so the page does not claim there are none.
$bashTasks = @($rows | Where-Object {
        $bashFolder = Join-Path (Join-Path $DeployRoot $_.Path) 'bash'
        (Test-Path -LiteralPath $bashFolder -PathType Container) -and @(Get-ChildItem -LiteralPath $bashFolder -Recurse -File -Filter '*.sh').Count -gt 0
    })
if ($bashTasks.Count -gt 0) {
    Out-Line "Task folders that still hold an older Bash script: $($bashTasks.Count). They are listed under ""Older Bash scripts"" at the end of this page."
    Out-Line
}
Out-Line '| Word | Meaning |'
Out-Line '|---|---|'
Out-Line '| built | The folder holds at least one real script. A folder can also hold a placeholder next to it (for example an orchestrated variant that is not written yet). |'
Out-Line '| not built | There is no real script. The folder holds only placeholders, or nothing. |'
Out-Line '| not applicable | The task does not act on Azure (it runs on a node, against on-premises Active Directory or DNS, against hardware or a BMC, or is operating system work), so it has no Azure CLI script. |'
Out-Line '| yes / no / unclear | Whether Azure CLI applies to the task. `unclear` means it is not decided; an existing Azure CLI placeholder is kept until it is. |'
Out-Line
Out-Line 'A **placeholder** is a script that does not do the task. Running it prints `NOT IMPLEMENTED: <task> has no <PowerShell or Azure CLI> script yet`, changes nothing and ends with **exit code 3** (the OS configuration and ARM deployment entry points use 0, 1 and 2). Use a real script of the task if there is one, or the steps on the guide page.'
Out-Line

$psBuilt = @($rows | Where-Object PowerShell -eq 'built').Count
$azBuilt = @($rows | Where-Object AzureCli -eq 'built').Count
$azNot = @($rows | Where-Object AzureCli -eq 'not built').Count
$azNa = @($rows | Where-Object AzureCli -eq 'not applicable').Count
Out-Line '## Summary'
Out-Line
Out-Line "Task folders: $($rows.Count)."
Out-Line
Out-Line '| Kind | built | not built | not applicable |'
Out-Line '|---|--:|--:|--:|'
Out-Line ('| PowerShell | {0} | {1} | 0 |' -f $psBuilt, ($rows.Count - $psBuilt))
Out-Line ('| Azure CLI | {0} | {1} | {2} |' -f $azBuilt, $azNot, $azNa)
Out-Line
Out-Line ('Azure CLI applies to {0} tasks, does not apply to {1}, and is not decided for {2}.' -f @($rows | Where-Object Applies -eq 'yes').Count, @($rows | Where-Object Applies -eq 'no').Count, @($rows | Where-Object Applies -eq 'unclear').Count)
Out-Line

foreach ($stage in ($rows | Select-Object -ExpandProperty Stage -Unique)) {
    Out-Line "## $stage"
    Out-Line
    Out-Line '| Task | PowerShell | Azure CLI | Azure CLI applies |'
    Out-Line '|---|---|---|---|'
    foreach ($row in ($rows | Where-Object Stage -eq $stage)) {
        Out-Line ('| `{0}` | {1} | {2} | {3} |' -f $row.Rest, $row.PowerShell, $row.AzureCli, $row.Applies)
    }
    Out-Line
}

$unclear = @($rows | Where-Object Applies -eq 'unclear')
if ($unclear.Count -gt 0) {
    Out-Line '## Tasks that need a decision'
    Out-Line
    Out-Line 'Azure CLI may or may not apply. Decide, then set `AzureCli` to `yes` or `no` in `TaskCatalogue.psd1`.'
    Out-Line
    Out-Line '| Task | Why it is not decided |'
    Out-Line '|---|---|'
    foreach ($row in $unclear) {
        Out-Line ('| `{0}` | {1} |' -f $row.Path, $row.Reason)
    }
    Out-Line
}

if ($bashTasks.Count -gt 0) {
    Out-Line '## Older Bash scripts'
    Out-Line
    Out-Line 'These task folders still hold a Bash script from before the layout was set. Nothing in the toolkit calls them.'
    Out-Line
    foreach ($row in $bashTasks) { Out-Line ('- `{0}`' -f $row.Path) }
    Out-Line
}

$page = $sb.ToString().TrimEnd("`n") + "`n"

if ($Check) {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        Write-Error "$OutputPath doesn't exist; run this script without -Check." -ErrorAction Continue
        exit 1
    }
    $current = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $OutputPath)).Replace("`r`n", "`n")
    if ($current -ne $page) {
        Write-Error "$OutputPath is out of date. Run ./scripts/deploy/common/New-DeployScriptStatus.ps1 and commit the result." -ErrorAction Continue
        exit 1
    }
    Write-Output "$OutputPath is current ($($rows.Count) task folders)."
    return
}

[System.IO.File]::WriteAllText($OutputPath, $page, [System.Text.UTF8Encoding]::new($false))
Write-Output "Wrote $OutputPath ($($rows.Count) task folders)."
