#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Path,
    [switch]$SkipCollectionInstall,
    [switch]$SkipSyntaxCheck,
    [ValidateSet('Auto', 'Native', 'WSL', 'Basic')]
    [string]$ExecutionMode = 'Auto',
    [string]$WslDistribution = 'Ubuntu-24.04',
    [string]$WslUser = 'root'
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $Path) {
    $Path = Join-Path $repoRoot 'src\ansible'
}

if (-not (Test-Path $Path)) {
    throw "Ansible path not found: $Path"
}

function Test-NativeCommandsAvailable {
    foreach ($command in @('ansible-lint', 'ansible-playbook')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            return $false
        }
    }

    if (-not $SkipCollectionInstall -and -not (Get-Command 'ansible-galaxy' -ErrorAction SilentlyContinue)) {
        return $false
    }

    return $true
}

function Test-WslCommandsAvailable {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    $distroList = & wsl.exe --list --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $installed = @($distroList | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
    if ($installed -notcontains $WslDistribution) {
        return $false
    }

    $requiredCommands = @('ansible-lint', 'ansible-playbook')
    if (-not $SkipCollectionInstall) {
        $requiredCommands += 'ansible-galaxy'
    }

    foreach ($requiredCommand in $requiredCommands) {
        & wsl.exe -d $WslDistribution -u $WslUser -- which $requiredCommand 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
    }

    return $true
}

function Get-PythonCommandName {
    foreach ($command in @('python', 'python3')) {
        if (Get-Command $command -ErrorAction SilentlyContinue) {
            return $command
        }
    }

    return $null
}

function Test-BasicDependenciesAvailable {
    $pythonCommand = Get-PythonCommandName
    if (-not $pythonCommand) {
        return $false
    }

    & $pythonCommand -c "import yaml" 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

function Convert-ToWslPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath
    )

    if ($WindowsPath -like '/*') {
        return $WindowsPath
    }

    if ($WindowsPath -match '^(?<drive>[A-Za-z]):\\(?<rest>.*)$') {
        $driveLetter = $Matches['drive'].ToLowerInvariant()
        $restOfPath = $Matches['rest'] -replace '\\', '/'
        return "/mnt/$driveLetter/$restOfPath"
    }

    throw "Failed to convert Windows path to WSL path: $WindowsPath"
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Invoke-WslCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [switch]$StreamOutput
    )

    $wslWorkingDirectory = Convert-ToWslPath -WindowsPath $WorkingDirectory
    $wslArguments = @('-d', $WslDistribution, '-u', $WslUser, '--cd', $wslWorkingDirectory, '--', $Command) + $Arguments

    if ($StreamOutput) {
        & wsl.exe @wslArguments
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output = @()
        }
    }

    $output = & wsl.exe @wslArguments 2>&1

    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
    }
}

function Invoke-WslRawCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Arguments = @(),

        [switch]$IgnoreExitCode,

        [switch]$StreamOutput
    )

    $wslArguments = @('-d', $WslDistribution, '-u', $WslUser, '--', $Command) + $Arguments

    if ($StreamOutput) {
        & wsl.exe @wslArguments
        $exitCode = $LASTEXITCODE
        if (-not $IgnoreExitCode -and $exitCode -ne 0) {
            throw "WSL command failed: $Command (exit code $exitCode)"
        }

        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output = @()
        }
    }

    $output = & wsl.exe @wslArguments 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw "WSL command failed: $Command`n$($output -join [Environment]::NewLine)"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function New-WslValidationWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [string]$InventoryFileName = 'hosts.yml'
    )

    $wslSourcePath = Convert-ToWslPath -WindowsPath $SourcePath
    $workspacePathResult = Invoke-WslRawCommand -Command 'mktemp' -Arguments @('-d', '/tmp/ansible-qa-XXXXXX')
    $workspaceRoot = ($workspacePathResult.Output | Select-Object -Last 1).ToString().Trim()

    try {
        Invoke-WslRawCommand -Command 'cp' -Arguments @('-R', "$wslSourcePath/.", "$workspaceRoot/") | Out-Null

        $inventoryTarget = "$workspaceRoot/inventory/$InventoryFileName"
        $inventoryExample = "$workspaceRoot/inventory/hosts.yml.example"
        $inventoryExists = Invoke-WslRawCommand -Command 'test' -Arguments @('-f', $inventoryTarget) -IgnoreExitCode
        if ($inventoryExists.ExitCode -ne 0) {
            $inventoryExampleExists = Invoke-WslRawCommand -Command 'test' -Arguments @('-f', $inventoryExample) -IgnoreExitCode
            if ($inventoryExampleExists.ExitCode -eq 0) {
                Invoke-WslRawCommand -Command 'cp' -Arguments @($inventoryExample, $inventoryTarget) | Out-Null
            }
        }

        return $workspaceRoot
    }
    catch {
        Remove-WslValidationWorkspace -WorkspacePath $workspaceRoot
        throw "Failed to prepare WSL validation workspace: $($_.Exception.Message)"
    }
}

function Remove-WslValidationWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    if (-not $WorkspacePath) {
        return
    }

    Invoke-WslRawCommand -Command 'rm' -Arguments @('-rf', $WorkspacePath) -IgnoreExitCode | Out-Null
}

function Invoke-BasicValidation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AnsibleRoot,

        [Parameter(Mandatory = $true)]
        [string]$SitePlaybookPath,

        [Parameter(Mandatory = $true)]
        [string]$InventoryPath,

        [Parameter(Mandatory = $true)]
        [string]$RequirementsPath
    )

    $pythonCommand = Get-PythonCommandName
    if (-not $pythonCommand) {
        throw 'Python is required for Basic Ansible validation but was not found on PATH.'
    }

    $py = @'
import pathlib
import sys

import yaml


def load_yaml(path):
    text = path.read_text(encoding="utf-8")
    return yaml.safe_load(text) if text.strip() else None


root = pathlib.Path(sys.argv[1])
site_playbook = pathlib.Path(sys.argv[2])
inventory_file = pathlib.Path(sys.argv[3])
requirements_file = pathlib.Path(sys.argv[4])

yaml_files = sorted({*root.rglob("*.yml"), *root.rglob("*.yaml")})
errors = []

for yaml_file in yaml_files:
    try:
        load_yaml(yaml_file)
    except Exception as exc:
        errors.append(f"YAML parse failed: {yaml_file} :: {exc}")

if not site_playbook.exists():
    errors.append(f"Missing site playbook: {site_playbook}")
else:
    try:
        site_data = load_yaml(site_playbook)
        if site_data is None:
            errors.append(f"Site playbook is empty: {site_playbook}")
        elif not isinstance(site_data, list):
            errors.append(f"Site playbook should deserialize to a YAML list: {site_playbook}")
        else:
            for entry in site_data:
                if not isinstance(entry, dict):
                    continue
                playbook_ref = entry.get("ansible.builtin.import_playbook") or entry.get("import_playbook")
                if playbook_ref:
                    playbook_path = site_playbook.parent / playbook_ref
                    if not playbook_path.exists():
                        errors.append(f"Imported playbook not found: {playbook_path}")
    except Exception as exc:
        errors.append(f"Failed to inspect site playbook {site_playbook}: {exc}")

for playbook in sorted(site_playbook.parent.glob("*.yml")):
    try:
        playbook_data = load_yaml(playbook)
    except Exception:
        continue

    if not isinstance(playbook_data, list):
        continue

    for play in playbook_data:
        if not isinstance(play, dict):
            continue
        roles = play.get("roles") or []
        for role in roles:
            role_name = None
            if isinstance(role, str):
                role_name = role
            elif isinstance(role, dict):
                role_name = role.get("role")
            if role_name:
                role_path = root / "roles" / role_name
                if not role_path.exists():
                    errors.append(f"Role path not found for '{role_name}': {role_path}")

if inventory_file.exists():
    try:
        load_yaml(inventory_file)
    except Exception as exc:
        errors.append(f"Inventory parse failed: {inventory_file} :: {exc}")

if requirements_file.exists():
    try:
        load_yaml(requirements_file)
    except Exception as exc:
        errors.append(f"Collection requirements parse failed: {requirements_file} :: {exc}")

if errors:
    for error in errors:
        print(error)
    raise SystemExit(1)

print(f"Parsed YAML files: {len(yaml_files)}")
print(f"Validated site playbook imports: {site_playbook}")
print(f"Validated inventory file: {inventory_file}")
if requirements_file.exists():
    print(f"Validated collection requirements: {requirements_file}")
'@

    $output = & $pythonCommand -c $py $AnsibleRoot $SitePlaybookPath $InventoryPath $RequirementsPath 2>&1
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
    }
}

$resolvedExecutionMode = $ExecutionMode
if ($resolvedExecutionMode -eq 'Auto') {
    if (Test-NativeCommandsAvailable) {
        $resolvedExecutionMode = 'Native'
    }
    elseif (Test-WslCommandsAvailable) {
        $resolvedExecutionMode = 'WSL'
    }
    elseif (Test-BasicDependenciesAvailable) {
        $resolvedExecutionMode = 'Basic'
    }
    else {
        throw 'Ansible dependencies are not available. Install native ansible commands, configure WSL, or use a Python environment with PyYAML for Basic mode.'
    }
}

if ($resolvedExecutionMode -eq 'Native' -and -not (Test-NativeCommandsAvailable)) {
    throw 'ExecutionMode Native was requested, but required ansible commands are not available on PATH.'
}

if ($resolvedExecutionMode -eq 'WSL' -and -not (Test-WslCommandsAvailable)) {
    throw "ExecutionMode WSL was requested, but required ansible commands are not available inside WSL distro '$WslDistribution'."
}

if ($resolvedExecutionMode -eq 'Basic' -and -not (Test-BasicDependenciesAvailable)) {
    throw 'ExecutionMode Basic was requested, but Python with PyYAML is not available.'
}

$playbookRoot = Join-Path $Path 'playbooks'
$roleRoot = Join-Path $Path 'roles'
$requirementsPath = Join-Path $Path 'collections\requirements.yml'
$sitePlaybook = Join-Path $playbookRoot 'site.yml'
$inventoryPath = Join-Path $Path 'inventory\hosts.yml'
$inventoryExamplePath = Join-Path $Path 'inventory\hosts.yml.example'

if (-not (Test-Path $playbookRoot)) {
    throw "Ansible playbook path not found: $playbookRoot"
}

if (-not (Test-Path $roleRoot)) {
    throw "Ansible role path not found: $roleRoot"
}

if (-not (Test-Path $sitePlaybook)) {
    throw "Ansible site playbook not found: $sitePlaybook"
}

if (-not (Test-Path $inventoryPath)) {
    if (Test-Path $inventoryExamplePath) {
        $inventoryPath = $inventoryExamplePath
    }
    else {
        throw 'Neither inventory/hosts.yml nor inventory/hosts.yml.example exists.'
    }
}

$failures = New-Object System.Collections.Generic.List[object]
$wslValidationPath = $null
$workingPath = $Path
$syntaxInventoryArgument = $inventoryPath

if ($resolvedExecutionMode -eq 'WSL') {
    $wslValidationPath = New-WslValidationWorkspace -SourcePath $Path
    $workingPath = $wslValidationPath
    $syntaxInventoryArgument = 'inventory/hosts.yml'
}

try {
    if ($resolvedExecutionMode -eq 'Basic') {
        Write-Warning 'Running Basic Ansible validation only. Full ansible-lint and ansible-playbook syntax-check are not available in this mode.'
        $basicResult = Invoke-BasicValidation -AnsibleRoot $Path -SitePlaybookPath $sitePlaybook -InventoryPath $inventoryPath -RequirementsPath $requirementsPath
        if ($basicResult.Output.Count -gt 0) {
            $basicResult.Output | Write-Host
        }

        if ($basicResult.ExitCode -ne 0) {
            $failures.Add([PSCustomObject]@{ Stage = 'basic-validation'; Output = ($basicResult.Output -join [Environment]::NewLine) })
        }
    }
    elseif (-not $SkipCollectionInstall -and (Test-Path $requirementsPath)) {
        Write-Host 'Installing required Ansible collections...' -ForegroundColor Cyan
        if ($resolvedExecutionMode -eq 'WSL') {
            $collectionResult = Invoke-WslCommand -Command 'ansible-galaxy' -Arguments @('collection', 'install', '-r', 'collections/requirements.yml') -WorkingDirectory $workingPath -StreamOutput
        }
        else {
            $collectionResult = Invoke-NativeCommand -Command 'ansible-galaxy' -Arguments @('collection', 'install', '-r', $requirementsPath) -WorkingDirectory $workingPath
        }

        if ($collectionResult.Output.Count -gt 0) {
            $collectionResult.Output | Write-Host
        }

        if ($collectionResult.ExitCode -ne 0) {
            $failures.Add([PSCustomObject]@{ Stage = 'collections'; Output = ($collectionResult.Output -join [Environment]::NewLine) })
        }
    }

    if ($resolvedExecutionMode -ne 'Basic') {
        Write-Host 'Running ansible-lint...' -ForegroundColor Cyan
        if ($resolvedExecutionMode -eq 'WSL') {
            $lintResult = Invoke-WslCommand -Command 'ansible-lint' -Arguments @('playbooks', 'roles') -WorkingDirectory $workingPath -StreamOutput
        }
        else {
            $lintResult = Invoke-NativeCommand -Command 'ansible-lint' -Arguments @('playbooks', 'roles') -WorkingDirectory $workingPath
        }

        if ($lintResult.Output.Count -gt 0) {
            $lintResult.Output | Write-Host
        }

        if ($lintResult.ExitCode -ne 0) {
            $failures.Add([PSCustomObject]@{ Stage = 'ansible-lint'; Output = ($lintResult.Output -join [Environment]::NewLine) })
        }

        if (-not $SkipSyntaxCheck) {
            Write-Host "Running ansible-playbook --syntax-check with inventory $inventoryPath" -ForegroundColor Cyan
            if ($resolvedExecutionMode -eq 'WSL') {
                $syntaxResult = Invoke-WslCommand -Command 'ansible-playbook' -Arguments @('-i', $syntaxInventoryArgument, '--syntax-check', 'playbooks/site.yml') -WorkingDirectory $workingPath -StreamOutput
            }
            else {
                $syntaxResult = Invoke-NativeCommand -Command 'ansible-playbook' -Arguments @('-i', $syntaxInventoryArgument, '--syntax-check', $sitePlaybook) -WorkingDirectory $workingPath
            }

            if ($syntaxResult.Output.Count -gt 0) {
                $syntaxResult.Output | Write-Host
            }

            if ($syntaxResult.ExitCode -ne 0) {
                $failures.Add([PSCustomObject]@{ Stage = 'syntax-check'; Output = ($syntaxResult.Output -join [Environment]::NewLine) })
            }
        }
    }
}
finally {
    if ($wslValidationPath) {
        Remove-WslValidationWorkspace -WorkspacePath $wslValidationPath
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Ansible QA failures:' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- [$($failure.Stage)]" -ForegroundColor Red
        if ($failure.Output) {
            Write-Host $failure.Output -ForegroundColor DarkRed
        }
    }
}

$summary = [PSCustomObject]@{
    Path = $Path
    InventoryPath = $inventoryPath
    ExecutionMode = $resolvedExecutionMode
    CollectionsInstalled = ($resolvedExecutionMode -ne 'Basic' -and -not $SkipCollectionInstall.IsPresent -and (Test-Path $requirementsPath))
    SyntaxCheckSkipped = ($resolvedExecutionMode -eq 'Basic' -or $SkipSyntaxCheck.IsPresent)
    Failures = $failures.Count
}

Write-Output $summary

if ($failures.Count -gt 0) {
    throw "Ansible QA failed with $($failures.Count) failure(s)."
}

Write-Host 'Ansible QA passed.' -ForegroundColor Green