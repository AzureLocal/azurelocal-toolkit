<#
.SYNOPSIS
    Standardized logging functions.

.DESCRIPTION
    Provides consistent logging across all scripts in the repository.
    Supports console output and optional file logging.

.NOTES
    Dot-source this file to use logging functions.
#>

# Script-level variables for file logging
$script:LogFile = $null
$script:LogToFile = $false

<#
.SYNOPSIS
    Writes a formatted log message.

.PARAMETER Level
    Log level: Info, Warning, Error, Debug, Verbose

.PARAMETER Message
    The message to log.

.EXAMPLE
    Write-Log -Level Info -Message "Starting deployment"
    Write-Log -Level Error -Message "Deployment failed"
#>
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Info", "Warning", "Error", "Debug", "Verbose")]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formattedMessage = "[$timestamp] [$Level] $Message"

    # Console output with colors
    switch ($Level) {
        "Info" {
            Write-Host $formattedMessage -ForegroundColor White
        }
        "Warning" {
            Write-Host $formattedMessage -ForegroundColor Yellow
        }
        "Error" {
            Write-Host $formattedMessage -ForegroundColor Red
        }
        "Debug" {
            if ($DebugPreference -ne "SilentlyContinue") {
                Write-Host $formattedMessage -ForegroundColor Gray
            }
        }
        "Verbose" {
            if ($VerbosePreference -ne "SilentlyContinue") {
                Write-Host $formattedMessage -ForegroundColor Cyan
            }
        }
    }

    # File logging
    if ($script:LogToFile -and $script:LogFile) {
        Add-Content -Path $script:LogFile -Value $formattedMessage
    }
}

<#
.SYNOPSIS
    Starts logging to a file.

.PARAMETER Path
    Path to the log file.

.PARAMETER Append
    Append to existing file instead of overwriting.

.EXAMPLE
    Start-LogFile -Path "deployment.log"
#>
function Start-LogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [switch]$Append
    )

    $script:LogFile = $Path
    $script:LogToFile = $true

    if (-not $Append -and (Test-Path $Path)) {
        Remove-Item $Path -Force
    }

    # Ensure directory exists
    $logDir = Split-Path -Parent $Path
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Write-Log -Level Info -Message "Log file started: $Path"
}

<#
.SYNOPSIS
    Stops logging to a file.

.EXAMPLE
    Stop-LogFile
#>
function Stop-LogFile {
    [CmdletBinding()]
    param()

    if ($script:LogToFile) {
        Write-Log -Level Info -Message "Log file ended"
        $script:LogToFile = $false
        $script:LogFile = $null
    }
}

<#
.SYNOPSIS
    Writes a section header for better log readability.

.PARAMETER Title
    The section title.

.EXAMPLE
    Write-LogSection -Title "Starting Deployment"
#>
function Write-LogSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $separator = "=" * 60
    Write-Log -Level Info -Message $separator
    Write-Log -Level Info -Message $Title
    Write-Log -Level Info -Message $separator
}
