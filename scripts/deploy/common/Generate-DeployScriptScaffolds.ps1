param(
    [string]$CoverageDocumentPath = 'e:\git\azurelocal.github.io\repo-management\reports\variables\deploy-script-coverage.md',
    [string]$RepositoryRoot = 'e:\git\azurelocal-toolkit'
)

$ErrorActionPreference = 'Stop'

$deployRoot = Join-Path $RepositoryRoot 'scripts\deploy'
$commonDir = Join-Path $deployRoot 'common'

function Get-PowerShellModuleContent {
@'
Set-StrictMode -Version Latest

function Resolve-DeploymentRepositoryRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StartPath
    )

    $item = Get-Item -LiteralPath $StartPath
    if ($item -is [System.IO.FileInfo]) {
        $item = $item.Directory
    }

    while ($null -ne $item) {
        if (Test-Path -LiteralPath (Join-Path $item.FullName 'config\variables\variables.example.yml')) {
            return $item.FullName
        }

        $item = $item.Parent
    }

    throw "Unable to resolve repository root from '$StartPath'."
}

function Initialize-DeploymentConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [string]$ConfigPath = ''
    )

    $resolvedPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        Join-Path $RepositoryRoot 'config\variables\variables.yml'
    }
    else {
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
    }

    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        $templatePath = Join-Path $RepositoryRoot 'config\variables\variables.example.yml'
        if (-not (Test-Path -LiteralPath $templatePath)) {
            throw "Runtime config '$resolvedPath' is missing and no template exists at '$templatePath'."
        }

        $parent = Split-Path -Path $resolvedPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        Copy-Item -LiteralPath $templatePath -Destination $resolvedPath -Force
    }

    return $resolvedPath
}

function New-DeploymentLogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$TaskPath,

        [string]$LogPath = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $parent = Split-Path -Path $LogPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        return $LogPath
    }

    $taskName = Split-Path -Path $TaskPath -Leaf
    $logDirectory = Join-Path $RepositoryRoot (Join-Path 'logs' $taskName)
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

    return Join-Path $logDirectory ((Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')
}

function Write-DeploymentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',

        [string]$LogPath = ''
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR' { Write-Error $Message }
        'WARN' { Write-Warning $Message }
        'DEBUG' { Write-Verbose $Message }
        default { Write-Host $line }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Add-Content -LiteralPath $LogPath -Value $line
    }
}

function Import-DeploymentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $raw = Get-Content -LiteralPath $ConfigPath -Raw
    $convertFromYaml = Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($null -ne $convertFromYaml) {
        return $raw | ConvertFrom-Yaml
    }

    return [ordered]@{
        _config_path = $ConfigPath
        _yaml_parser = 'unavailable'
        _raw = $raw
    }
}

function Get-DeploymentConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [string[]]$PathCandidates
    )

    foreach ($candidate in $PathCandidates) {
        $current = $Configuration
        $matched = $true
        foreach ($segment in ($candidate -split '\.')) {
            if ($current -is [System.Collections.IDictionary] -and $current.Contains($segment)) {
                $current = $current[$segment]
                continue
            }

            $property = $current.PSObject.Properties[$segment]
            if ($null -ne $property) {
                $current = $property.Value
                continue
            }

            $matched = $false
            break
        }

        if ($matched -and $null -ne $current -and -not [string]::IsNullOrWhiteSpace([string]$current)) {
            return $current
        }
    }

    return $null
}

function Resolve-KeyVaultReference {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or -not $Value.StartsWith('keyvault://')) {
        return $Value
    }

    $reference = $Value.Substring('keyvault://'.Length)
    $segments = $reference.Split('/', 2)
    if ($segments.Count -ne 2) {
        throw "Invalid Key Vault reference '$Value'."
    }

    $vaultName = $segments[0]
    $secretName = $segments[1]

    $getAzKeyVaultSecret = Get-Command -Name Get-AzKeyVaultSecret -ErrorAction SilentlyContinue
    if ($null -ne $getAzKeyVaultSecret) {
        try {
            return Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
        }
        catch {
        }
    }

    $azCommand = Get-Command -Name az -ErrorAction SilentlyContinue
    if ($null -ne $azCommand) {
        try {
            $resolved = & $azCommand.Source keyvault secret show --vault-name $vaultName --name $secretName --query value -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolved)) {
                return $resolved
            }
        }
        catch {
        }
    }

    throw "Unable to resolve secret '$secretName' from vault '$vaultName'."
}

function Resolve-DeploymentCredential {
    [CmdletBinding()]
    param(
        [System.Management.Automation.PSCredential]$Credential,

        [AllowNull()]
        [object]$Configuration
    )

    if ($null -ne $Credential) {
        return $Credential
    }

    $username = [string](Get-DeploymentConfigValue -Configuration $Configuration -PathCandidates @(
        'identity.accounts.account_local_admin_username',
        'deployment.admin_upn',
        'site.owner',
        'environment.env_owner'
    ))

    $passwordReference = [string](Get-DeploymentConfigValue -Configuration $Configuration -PathCandidates @(
        'identity.accounts.account_local_admin_password',
        'identity.accounts.password',
        'security.admin_password'
    ))

    if (-not [string]::IsNullOrWhiteSpace($username) -and -not [string]::IsNullOrWhiteSpace($passwordReference)) {
        $password = Resolve-KeyVaultReference -Value $passwordReference
        if (-not [string]::IsNullOrWhiteSpace($password)) {
            $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
            return [System.Management.Automation.PSCredential]::new($username, $securePassword)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($username)) {
        Write-Verbose "Falling back to interactive credential prompt for '$username'."
        return Get-Credential -UserName $username -Message 'Enter credentials for deployment operations.'
    }

    Write-Verbose 'Falling back to interactive credential prompt.'
    return Get-Credential -Message 'Enter credentials for deployment operations.'
}

function Format-DeploymentValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string]) {
        return $Value
    }

    return ($Value | ConvertTo-Json -Depth 8 -Compress)
}

function Invoke-DeploymentStandalone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$TaskPath,

        [Parameter(Mandatory)]
        [string]$ActionName,

        [hashtable]$Configuration = @{},

        [hashtable]$Parameters = @{},

        [string]$LogPath = ''
    )

    $repositoryRoot = Resolve-DeploymentRepositoryRoot -StartPath $ScriptPath
    $resolvedLogPath = New-DeploymentLogPath -RepositoryRoot $repositoryRoot -TaskPath $TaskPath -LogPath $LogPath

    Write-DeploymentLog -Message "Starting standalone script '$ActionName' for task '$TaskPath'." -LogPath $resolvedLogPath
    foreach ($key in ($Configuration.Keys | Sort-Object)) {
        Write-DeploymentLog -Message ("Configuration [{0}] = {1}" -f $key, (Format-DeploymentValue -Value $Configuration[$key])) -Level DEBUG -LogPath $resolvedLogPath
    }

    Write-DeploymentLog -Message 'This script is a standards-compliant scaffold. Add task-specific operations before production use.' -Level WARN -LogPath $resolvedLogPath

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        TaskPath = $TaskPath
        LogPath = $resolvedLogPath
        Parameters = $Parameters
    }
}

function Invoke-DeploymentOrchestrated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$TaskPath,

        [Parameter(Mandatory)]
        [string]$ActionName,

        [string]$ConfigPath = '',

        [System.Management.Automation.PSCredential]$Credential,

        [string[]]$TargetNode = @(),

        [hashtable]$Parameters = @{},

        [string]$LogPath = ''
    )

    $repositoryRoot = Resolve-DeploymentRepositoryRoot -StartPath $ScriptPath
    $resolvedConfigPath = Initialize-DeploymentConfigPath -RepositoryRoot $repositoryRoot -ConfigPath $ConfigPath
    $configuration = Import-DeploymentConfiguration -ConfigPath $resolvedConfigPath
    $resolvedCredential = Resolve-DeploymentCredential -Credential $Credential -Configuration $configuration
    $resolvedLogPath = New-DeploymentLogPath -RepositoryRoot $repositoryRoot -TaskPath $TaskPath -LogPath $LogPath
    $targets = if ($TargetNode.Count -gt 0) { $TargetNode } else { @('all') }

    Write-DeploymentLog -Message "Starting orchestrated script '$ActionName' for task '$TaskPath'." -LogPath $resolvedLogPath
    Write-DeploymentLog -Message ("Using config path '{0}'." -f $resolvedConfigPath) -LogPath $resolvedLogPath
    Write-DeploymentLog -Message ("Resolved credential for '{0}'." -f $resolvedCredential.UserName) -Level DEBUG -LogPath $resolvedLogPath
    foreach ($target in $targets) {
        Write-DeploymentLog -Message ("Prepared target node '{0}'." -f $target) -Level DEBUG -LogPath $resolvedLogPath
    }

    Write-DeploymentLog -Message 'This script is a standards-compliant scaffold. Add task-specific orchestration before production use.' -Level WARN -LogPath $resolvedLogPath

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        ConfigPath = $resolvedConfigPath
        TaskPath = $TaskPath
        TargetNode = $targets
        LogPath = $resolvedLogPath
        Parameters = $Parameters
    }
}

function Invoke-DeploymentAzCliPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$TaskPath,

        [Parameter(Mandatory)]
        [string]$ActionName,

        [string]$ConfigPath = '',

        [hashtable]$Parameters = @{},

        [string]$LogPath = ''
    )

    $repositoryRoot = Resolve-DeploymentRepositoryRoot -StartPath $ScriptPath
    $resolvedConfigPath = Initialize-DeploymentConfigPath -RepositoryRoot $repositoryRoot -ConfigPath $ConfigPath
    $null = Import-DeploymentConfiguration -ConfigPath $resolvedConfigPath
    $resolvedLogPath = New-DeploymentLogPath -RepositoryRoot $repositoryRoot -TaskPath $TaskPath -LogPath $LogPath

    if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI 'az' was not found in PATH."
    }

    Write-DeploymentLog -Message "Starting Azure CLI PowerShell wrapper '$ActionName' for task '$TaskPath'." -LogPath $resolvedLogPath
    Write-DeploymentLog -Message ("Using config path '{0}'." -f $resolvedConfigPath) -LogPath $resolvedLogPath
    Write-DeploymentLog -Message 'This script is a standards-compliant scaffold. Add task-specific az commands before production use.' -Level WARN -LogPath $resolvedLogPath

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        ConfigPath = $resolvedConfigPath
        TaskPath = $TaskPath
        LogPath = $resolvedLogPath
        Parameters = $Parameters
    }
}

Export-ModuleMember -Function *
'@
}

function Get-BashHelperContent {
@'
#!/usr/bin/env bash
set -euo pipefail

resolve_repo_root() {
  local start_path="$1"
  local current_path
  current_path="$(cd "$start_path" && pwd)"

  while [[ "$current_path" != "/" ]]; do
    if [[ -f "$current_path/config/variables/variables.example.yml" ]]; then
      printf '%s\n' "$current_path"
      return 0
    fi
    current_path="$(dirname "$current_path")"
  done

  return 1
}

initialize_config_path() {
  local repo_root="$1"
  local requested_path="${2:-}"
  local resolved_path
  local template_path="$repo_root/config/variables/variables.example.yml"

  if [[ -n "$requested_path" ]]; then
    resolved_path="$requested_path"
  else
    resolved_path="$repo_root/config/variables/variables.yml"
  fi

  if [[ ! -f "$resolved_path" ]]; then
    if [[ ! -f "$template_path" ]]; then
      printf 'Runtime config missing and no template found at %s\n' "$template_path" >&2
      return 1
    fi

    mkdir -p "$(dirname "$resolved_path")"
    cp "$template_path" "$resolved_path"
  fi

  printf '%s\n' "$resolved_path"
}

new_log_path() {
  local repo_root="$1"
  local task_path="$2"
  local requested_path="${3:-}"
  local task_name
  local log_dir

  if [[ -n "$requested_path" ]]; then
    mkdir -p "$(dirname "$requested_path")"
    printf '%s\n' "$requested_path"
    return 0
  fi

  task_name="$(basename "$task_path")"
  log_dir="$repo_root/logs/$task_name"
  mkdir -p "$log_dir"
  printf '%s/%s.log\n' "$log_dir" "$(date +%Y%m%d-%H%M%S)"
}

write_log() {
  local log_path="$1"
  local level="$2"
  local message="$3"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" | tee -a "$log_path"
}

invoke_bash_deployment() {
  local script_path="$1"
  local task_path="$2"
  local action_name="$3"
  shift 3

  local config_path=""
  local log_path=""
  local passthrough=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config-path)
        config_path="$2"
        shift 2
        ;;
      --log-path)
        log_path="$2"
        shift 2
        ;;
      *)
        passthrough+=("$1")
        shift
        ;;
    esac
  done

  local script_dir
  local repo_root
  local resolved_config_path
  local resolved_log_path

  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  repo_root="$(resolve_repo_root "$script_dir")"
  resolved_config_path="$(initialize_config_path "$repo_root" "$config_path")"
  resolved_log_path="$(new_log_path "$repo_root" "$task_path" "$log_path")"

  write_log "$resolved_log_path" INFO "Starting Bash scaffold '$action_name' for task '$task_path'."
  write_log "$resolved_log_path" INFO "Using config path '$resolved_config_path'."

  if ! command -v az >/dev/null 2>&1; then
    write_log "$resolved_log_path" ERROR "Azure CLI 'az' was not found in PATH."
    return 1
  fi

    write_log "$resolved_log_path" WARN "This script is a standards-compliant scaffold. Add task-specific Bash operations before production use."
  if [[ ${#passthrough[@]} -gt 0 ]]; then
    write_log "$resolved_log_path" DEBUG "Passthrough arguments: ${passthrough[*]}"
  fi
}
'@
}

function Get-CommonLoaderContent {
@'
function Get-DeploymentCommonModulePath {
    $current = Get-Item -LiteralPath $PSScriptRoot
    while ($null -ne $current) {
        $candidate = Join-Path $current.FullName 'scripts\deploy\common\DeploymentScaffold.psm1'
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

function Get-PowerShellStandaloneTemplate {
    param(
        [string]$TaskPath,
        [string]$ActionName
    )

    $template = @'
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

__COMMON_LOADER__

Invoke-DeploymentStandalone `
    -ScriptPath $PSCommandPath `
    -TaskPath '__TASK_PATH__' `
    -ActionName '__ACTION_NAME__' `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters `
    -Configuration [ordered]@{
        environment_name = $EnvironmentName
        project_name = $ProjectName
        subscription_id = $SubscriptionId
        resource_group_name = $ResourceGroupName
    }
'@

    return $template.Replace('__COMMON_LOADER__', (Get-CommonLoaderContent).Trim()).Replace('__TASK_PATH__', $TaskPath).Replace('__ACTION_NAME__', $ActionName)
}

function Get-PowerShellOrchestratedTemplate {
    param(
        [string]$TaskPath,
        [string]$ActionName
    )

    $template = @'
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = '',
    [System.Management.Automation.PSCredential]$Credential = $null,
    [string[]]$TargetNode = @(),
    [string]$LogPath = ''
)

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

    return $template.Replace('__COMMON_LOADER__', (Get-CommonLoaderContent).Trim()).Replace('__TASK_PATH__', $TaskPath).Replace('__ACTION_NAME__', $ActionName)
}

function Get-AzCliPowerShellTemplate {
    param(
        [string]$TaskPath,
        [string]$ActionName
    )

    $template = @'
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = '',
    [string]$LogPath = ''
)

__COMMON_LOADER__

Invoke-DeploymentAzCliPowerShell `
    -ScriptPath $PSCommandPath `
    -TaskPath '__TASK_PATH__' `
    -ActionName '__ACTION_NAME__' `
    -ConfigPath $ConfigPath `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters
'@

    return $template.Replace('__COMMON_LOADER__', (Get-CommonLoaderContent).Trim()).Replace('__TASK_PATH__', $TaskPath).Replace('__ACTION_NAME__', $ActionName)
}

function Get-BashTemplate {
    param(
        [string]$TaskPath,
        [string]$ActionName
    )

    $template = @'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_DIR="$SCRIPT_DIR"
COMMON_SCRIPT=""
while [[ -n "$CURRENT_DIR" && "$CURRENT_DIR" != "$(dirname "$CURRENT_DIR")" ]]; do
  CANDIDATE="$CURRENT_DIR/scripts/deploy/common/deployment-scaffold.sh"
  if [[ -f "$CANDIDATE" ]]; then
    COMMON_SCRIPT="$CANDIDATE"
    break
  fi
  CURRENT_DIR="$(dirname "$CURRENT_DIR")"
done

if [[ -z "$COMMON_SCRIPT" ]]; then
  printf 'Unable to locate deployment-scaffold.sh from %s\n' "$SCRIPT_DIR" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$COMMON_SCRIPT"
invoke_bash_deployment "$0" '__TASK_PATH__' '__ACTION_NAME__' "$@"
'@

    return $template.Replace('__TASK_PATH__', $TaskPath).Replace('__ACTION_NAME__', $ActionName)
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

New-Item -ItemType Directory -Force -Path $commonDir | Out-Null
Set-Content -LiteralPath (Join-Path $commonDir 'DeploymentScaffold.psm1') -Value (Get-PowerShellModuleContent) -Encoding utf8
Set-Content -LiteralPath (Join-Path $commonDir 'deployment-scaffold.sh') -Value (Get-BashHelperContent) -Encoding utf8

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
        $entries.Add([pscustomobject]@{
            TaskNumber = [int]$matches[1]
            TaskName = $matches[2].Trim()
            ScriptName = $matches[3].Trim()
            ScriptType = $matches[4].Trim()
            Subfolder = $matches[5].Trim().Trim('/')
        })
    }
}

$created = 0
$skipped = 0
foreach ($entry in $entries) {
    if (-not $taskMap.ContainsKey($entry.TaskNumber)) {
        throw "Task number $($entry.TaskNumber) was not found in the coverage table."
    }

    $taskPath = $taskMap[$entry.TaskNumber]
    $targetDirectory = Join-Path $deployRoot ($taskPath -replace '/', '\\')
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
        'Bash' { $content = Get-BashTemplate -TaskPath $taskPath -ActionName $actionName }
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
                'Bash' { $parts[11] = ' ' + (Add-CellValue -CurrentValue $parts[11] -NewValue $entry.ScriptName) + ' ' }
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

Write-Host "Created $created scripts; skipped $skipped existing scripts."