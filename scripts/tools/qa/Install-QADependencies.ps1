#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$PowerShell,
    [switch]$Terraform,
    [switch]$AzureCli,
    [switch]$ArmTemplates,
    [switch]$Ansible,
    [string]$WslDistribution = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'

if (-not ($PowerShell -or $Terraform -or $AzureCli -or $ArmTemplates -or $Ansible)) {
    $PowerShell = $true
    $Terraform = $true
    $AzureCli = $true
    $ArmTemplates = $true
    $Ansible = $true
}

function Install-PowerShellModuleIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (Get-Module -ListAvailable -Name $Name) {
        Write-Host "$Name is already installed." -ForegroundColor Green
        return
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Install PowerShell module')) {
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }
}

function Install-ArmTtkIfMissing {
    if (Get-Module -ListAvailable -Name 'arm-ttk') {
        Write-Host 'arm-ttk is already installed.' -ForegroundColor Green
        return
    }

    $moduleRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
    $modulePath = Join-Path $moduleRoot 'arm-ttk'
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('arm-ttk-' + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $tempRoot 'arm-ttk.zip'
    $extractPath = Join-Path $tempRoot 'expanded'
    $downloadUrl = 'https://github.com/Azure/arm-ttk/archive/refs/heads/master.zip'

    if ($PSCmdlet.ShouldProcess('arm-ttk', 'Download and install from GitHub')) {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

            $sourceModulePath = Join-Path $extractPath 'arm-ttk-master\arm-ttk'
            if (-not (Test-Path (Join-Path $sourceModulePath 'arm-ttk.psd1'))) {
                throw 'Downloaded ARM TTK archive did not contain the expected module layout.'
            }

            if (Test-Path $modulePath) {
                Remove-Item -Path $modulePath -Recurse -Force
            }

            Copy-Item -Path $sourceModulePath -Destination $modulePath -Recurse -Force
        }
        finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }
}

function Update-ProcessPathFromSystem {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $output = & winget list --exact --id $PackageId --accept-source-agreements 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return ($output | Out-String) -match [regex]::Escape($PackageId)
}

function Install-WingetPackageIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
        Write-Host "$DisplayName is already installed." -ForegroundColor Green
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is required to install $DisplayName automatically."
    }

    if ($PSCmdlet.ShouldProcess($DisplayName, 'Install with winget')) {
        & winget install -e --id $PackageId --accept-package-agreements --accept-source-agreements

        Update-ProcessPathFromSystem

        if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
            Write-Host "$DisplayName is now available on PATH." -ForegroundColor Green
            return
        }

        $wingetExitCode = $LASTEXITCODE
        if (Test-WingetPackageInstalled -PackageId $PackageId) {
            Write-Warning "$DisplayName appears to be installed, but '$CommandName' is not available in the current session PATH yet. Open a new terminal and re-run the QA tool if needed."
            return
        }

        if ($wingetExitCode -ne 0) {
            throw "Failed to install $DisplayName with winget."
        }
    }
}

function Invoke-WslCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string]$Distribution = $WslDistribution,

        [string]$User = 'root',

        [switch]$StreamOutput
    )

    if ($StreamOutput) {
        & wsl.exe -d $Distribution -u $User -- sh -lc $Command
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output = @()
        }
    }

    $output = & wsl.exe -d $Distribution -u $User -- sh -lc $Command 2>&1
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
    }
}

function Test-WslDistributionInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distribution
    )

    $output = & wsl.exe --list --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $installed = @($output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
    return $installed -contains $Distribution
}

function Ensure-WslDistribution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distribution
    )

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'WSL is not installed on this machine.'
    }

    if (Test-WslDistributionInstalled -Distribution $Distribution) {
        Write-Host "WSL distro $Distribution is already installed." -ForegroundColor Green
        return
    }

    if ($PSCmdlet.ShouldProcess($Distribution, 'Install WSL distro for Ansible QA')) {
        & wsl.exe --set-default-version 1 | Out-Null
        & wsl.exe --install $Distribution --version 1 --no-launch
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install WSL distro $Distribution."
        }
    }
}

function Ensure-WslAptPackages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distribution,

        [Parameter(Mandatory = $true)]
        [string[]]$Packages
    )

    $packageList = $Packages -join ' '
    Write-Host "Checking WSL packages in ${Distribution}: $packageList" -ForegroundColor Cyan
    $probe = Invoke-WslCommand -Distribution $Distribution -Command "dpkg -s $packageList >/dev/null 2>&1"
    if ($probe.ExitCode -eq 0) {
        Write-Host "WSL packages already installed: $packageList" -ForegroundColor Green
        return
    }

    if ($PSCmdlet.ShouldProcess($Distribution, "Install apt packages: $packageList")) {
        Write-Host "Installing WSL packages in ${Distribution}: $packageList" -ForegroundColor Cyan
        $result = Invoke-WslCommand -Distribution $Distribution -Command "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y $packageList" -StreamOutput

        if ($result.ExitCode -ne 0) {
            Write-Warning "Initial apt install failed in ${Distribution}. Attempting dpkg recovery and one retry."
            $repairResult = Invoke-WslCommand -Distribution $Distribution -Command 'dpkg --configure -a' -StreamOutput
            if ($repairResult.ExitCode -ne 0) {
                throw "Failed to repair interrupted dpkg state in ${Distribution}."
            }

            $retryResult = Invoke-WslCommand -Distribution $Distribution -Command "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y $packageList" -StreamOutput
            if ($retryResult.ExitCode -ne 0) {
                throw "Failed to install apt packages in ${Distribution}: $packageList"
            }
        }
    }
}

if ($PowerShell) {
    Install-PowerShellModuleIfMissing -Name 'PSScriptAnalyzer'
}

if ($Terraform) {
    Install-WingetPackageIfMissing -PackageId 'Hashicorp.Terraform' -CommandName 'terraform' -DisplayName 'Terraform CLI'
}

if ($AzureCli) {
    Install-WingetPackageIfMissing -PackageId 'Microsoft.AzureCLI' -CommandName 'az' -DisplayName 'Azure CLI'
}

if ($ArmTemplates) {
    Install-ArmTtkIfMissing
}

if ($Ansible) {
    if ((Get-Command ansible-lint -ErrorAction SilentlyContinue) -and
        (Get-Command ansible-playbook -ErrorAction SilentlyContinue) -and
        (Get-Command ansible-galaxy -ErrorAction SilentlyContinue)) {
        Write-Host 'Ansible commands are already available on PATH.' -ForegroundColor Green
    }
    elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        Ensure-WslDistribution -Distribution $WslDistribution
        Ensure-WslAptPackages -Distribution $WslDistribution -Packages @('python3', 'python3-pip', 'ansible', 'ansible-lint')
    }
    else {
        Write-Warning 'Full Ansible QA on Windows requires native ansible commands on PATH or WSL with Python 3 installed.'
        Write-Host 'Basic Ansible QA is still available through Test-AnsibleCode.ps1 -ExecutionMode Basic if Python and PyYAML are installed.' -ForegroundColor Yellow
    }
}

Write-Host 'QA dependency installation completed.' -ForegroundColor Green