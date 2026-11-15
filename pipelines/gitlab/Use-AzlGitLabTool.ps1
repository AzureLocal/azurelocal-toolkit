#Requires -Version 7.0
<#
.SYNOPSIS
    GitLab CI: makes the tool versions of devops.pipelines.tool_versions the ones a job uses.

.DESCRIPTION
    GitHub and Azure DevOps install a tool version with an action or a task (setup-terraform, setup-python, TerraformInstaller,
    UsePythonVersion). GitLab has none, so the GitLab jobs dot-source this script at the start of their pwsh block:

        . ./pipelines/gitlab/Use-AzlGitLabTool.ps1 -Tool Terraform -TerraformVersion $env:AZL_TERRAFORM_VERSION

    Each version is a parameter; the jobs pass the variables task 05 of the CI/CD setup sets from infrastructure.yml
    (AZL_TERRAFORM_VERSION, AZL_PYTHON_VERSION, AZL_ANSIBLE_CORE_VERSION, AZL_ANSIBLE_LINT_VERSION, AZL_POWERSHELL_YAML_VERSION,
    AZL_AZ_POWERSHELL_VERSION, AZL_AZ_KEYVAULT_VERSION). The script holds no version of its own.

      Terraform  Uses terraform from PATH when it is that version; otherwise downloads that release from releases.hashicorp.com into
                 ToolDirectory and puts it first in PATH (for this PowerShell session: dot-source the script).
      Ansible    Creates a virtual environment in ToolDirectory with python<PythonVersion> (py -<PythonVersion> on Windows), installs
                 ansible-core==<AnsibleCoreVersion> and, when given, ansible-lint==<AnsibleLintVersion>, and puts it first in PATH.
      Modules    Installs each PowerShell module whose version is given (powershell-yaml, Az, Az.KeyVault) from the PowerShell Gallery for
                 the current user, unless that version is there.

    Exit: a missing version or a failed download or install throws, so the job fails.

.PARAMETER Tool
    What to prepare: Terraform, Ansible, Modules (one or more).
.PARAMETER TerraformVersion
    The Terraform release (devops.pipelines.tool_versions.terraform, AZL_TERRAFORM_VERSION).
.PARAMETER PythonVersion
    The Python minor version of the Ansible virtual environment (devops.pipelines.tool_versions.python, AZL_PYTHON_VERSION).
.PARAMETER AnsibleCoreVersion
    The ansible-core release (devops.pipelines.tool_versions.ansible_core, AZL_ANSIBLE_CORE_VERSION).
.PARAMETER AnsibleLintVersion
    The ansible-lint release (devops.pipelines.tool_versions.ansible_lint, AZL_ANSIBLE_LINT_VERSION). Empty: ansible-lint is not installed.
.PARAMETER PowerShellYamlVersion
    The powershell-yaml module version (devops.pipelines.tool_versions.powershell_yaml, AZL_POWERSHELL_YAML_VERSION).
.PARAMETER AzPowerShellVersion
    The Az module version (devops.pipelines.tool_versions.az_powershell, AZL_AZ_POWERSHELL_VERSION). Empty: Az is not installed.
.PARAMETER AzKeyVaultVersion
    The Az.KeyVault module version (devops.pipelines.tool_versions.az_keyvault, AZL_AZ_KEYVAULT_VERSION). Empty: Az.KeyVault is not installed.
.PARAMETER ToolDirectory
    Where a downloaded Terraform and the Ansible virtual environment go. Default: .azl-tools under the job's working directory.

.EXAMPLE
    . ./pipelines/gitlab/Use-AzlGitLabTool.ps1 -Tool Ansible -PythonVersion $env:AZL_PYTHON_VERSION -AnsibleCoreVersion $env:AZL_ANSIBLE_CORE_VERSION
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Terraform', 'Ansible', 'Modules')][string[]]$Tool,
    [string]$TerraformVersion,
    [string]$PythonVersion,
    [string]$AnsibleCoreVersion,
    [string]$AnsibleLintVersion,
    [string]$PowerShellYamlVersion,
    [string]$AzPowerShellVersion,
    [string]$AzKeyVaultVersion,
    [string]$ToolDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

if (-not $ToolDirectory) { $ToolDirectory = Join-Path (Get-Location).Path '.azl-tools' }
$null = New-Item -ItemType Directory -Path $ToolDirectory -Force

function Add-AzlToolPath([string]$Directory) {
    $env:PATH = $Directory + [IO.Path]::PathSeparator + $env:PATH
}

if ('Terraform' -in $Tool) {
    if (-not $TerraformVersion) { throw 'Terraform needs -TerraformVersion (AZL_TERRAFORM_VERSION, devops.pipelines.tool_versions.terraform).' }
    $found = Get-Command terraform -ErrorAction SilentlyContinue
    $current = if ($found) { [string]((& $found.Source version -json | ConvertFrom-Json).terraform_version) } else { '' }
    if ($current -ne $TerraformVersion) {
        $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
        $arch = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) { 'Arm64' { 'arm64' } default { 'amd64' } }
        $target = Join-Path $ToolDirectory "terraform-$TerraformVersion"
        $zip = Join-Path $ToolDirectory "terraform-$TerraformVersion.zip"
        # HashiCorp's release host (vendor-fixed). The zip is checked against the SHA256SUMS file HashiCorp publishes with each release.
        $release = "https://releases.hashicorp.com/terraform/$TerraformVersion"
        $name = "terraform_${TerraformVersion}_${os}_${arch}.zip"
        Invoke-WebRequest -Uri "$release/$name" -OutFile $zip
        $sums = (Invoke-WebRequest -Uri "$release/terraform_${TerraformVersion}_SHA256SUMS").Content
        $want = ([regex]::Match([string]$sums, "(?m)^(?<h>[0-9a-f]{64})\s+$([regex]::Escape($name))\s*$")).Groups['h'].Value
        $have = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $want -or $have -ne $want) { Remove-Item -LiteralPath $zip -Force; throw "terraform $TerraformVersion ($name): the SHA-256 of the download does not match HashiCorp's SHA256SUMS." }
        Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
        if (-not $IsWindows) { & chmod +x (Join-Path $target 'terraform') }
        Add-AzlToolPath $target
    }
    Write-Information -MessageData "terraform $TerraformVersion" -InformationAction Continue
}

if ('Ansible' -in $Tool) {
    if (-not $PythonVersion -or -not $AnsibleCoreVersion) { throw 'Ansible needs -PythonVersion and -AnsibleCoreVersion (AZL_PYTHON_VERSION, AZL_ANSIBLE_CORE_VERSION).' }
    $venv = Join-Path $ToolDirectory "ansible-python$PythonVersion"
    if ($IsWindows) { & py "-$PythonVersion" -m venv $venv } else { & "python$PythonVersion" -m venv $venv }
    $bin = Join-Path $venv $(if ($IsWindows) { 'Scripts' } else { 'bin' })
    $packages = @("ansible-core==$AnsibleCoreVersion")
    if ($AnsibleLintVersion) { $packages += "ansible-lint==$AnsibleLintVersion" }
    & (Join-Path $bin 'python') -m pip install --quiet @packages
    Add-AzlToolPath $bin
    Write-Information -MessageData "$($packages -join ', ') on Python $PythonVersion" -InformationAction Continue
}

if ('Modules' -in $Tool) {
    $modules = [ordered]@{ 'powershell-yaml' = $PowerShellYamlVersion; 'Az' = $AzPowerShellVersion; 'Az.KeyVault' = $AzKeyVaultVersion }
    if (-not $PowerShellYamlVersion) { throw 'Modules needs -PowerShellYamlVersion (AZL_POWERSHELL_YAML_VERSION, devops.pipelines.tool_versions.powershell_yaml).' }
    foreach ($m in $modules.GetEnumerator()) {
        if (-not $m.Value) { continue }
        if (-not (Get-Module -ListAvailable $m.Key | Where-Object Version -EQ $m.Value)) { Install-Module $m.Key -RequiredVersion $m.Value -Scope CurrentUser -Force -Repository PSGallery }
        Write-Information -MessageData "$($m.Key) $($m.Value)" -InformationAction Continue
    }
}
