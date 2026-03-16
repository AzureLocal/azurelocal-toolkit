<#
.SYNOPSIS
    Common error handling utilities.

.DESCRIPTION
    Provides standardized error handling patterns including retry logic
    and detailed error extraction.

.NOTES
    Dot-source this file to use error handling functions.
#>

<#
.SYNOPSIS
    Invokes a scriptblock with retry logic.

.PARAMETER ScriptBlock
    The scriptblock to execute.

.PARAMETER MaxRetries
    Maximum number of retry attempts (default: 3).

.PARAMETER RetryDelaySeconds
    Delay between retries in seconds (default: 5).

.PARAMETER ExponentialBackoff
    Use exponential backoff for retry delays.

.EXAMPLE
    Invoke-WithRetry -ScriptBlock { Connect-AzAccount } -MaxRetries 3

.EXAMPLE
    Invoke-WithRetry -ScriptBlock { 
        Invoke-RestMethod -Uri $uri 
    } -MaxRetries 5 -ExponentialBackoff
#>
function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelaySeconds = 5,

        [Parameter(Mandatory = $false)]
        [switch]$ExponentialBackoff
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -lt $MaxRetries) {
        $attempt++
        
        try {
            $result = & $ScriptBlock
            return $result
        }
        catch {
            $lastError = $_
            
            if ($attempt -lt $MaxRetries) {
                $delay = if ($ExponentialBackoff) {
                    $RetryDelaySeconds * [Math]::Pow(2, $attempt - 1)
                } else {
                    $RetryDelaySeconds
                }
                
                Write-Log -Level Warning -Message "Attempt $attempt failed. Retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
            }
        }
    }

    # All retries exhausted
    Write-Log -Level Error -Message "All $MaxRetries attempts failed"
    throw $lastError
}

<#
.SYNOPSIS
    Extracts detailed error information.

.PARAMETER ErrorRecord
    The error record to analyze.

.EXAMPLE
    try {
        # Some operation
    } catch {
        $details = Get-ErrorDetails -ErrorRecord $_
        Write-Log -Level Error -Message $details.Summary
    }
#>
function Get-ErrorDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $details = @{
        Message = $ErrorRecord.Exception.Message
        ExceptionType = $ErrorRecord.Exception.GetType().FullName
        ScriptName = $ErrorRecord.InvocationInfo.ScriptName
        LineNumber = $ErrorRecord.InvocationInfo.ScriptLineNumber
        Line = $ErrorRecord.InvocationInfo.Line.Trim()
        StackTrace = $ErrorRecord.ScriptStackTrace
        Summary = ""
    }

    $details.Summary = @"
Error: $($details.Message)
Type: $($details.ExceptionType)
Location: $($details.ScriptName):$($details.LineNumber)
Line: $($details.Line)
"@

    return $details
}

<#
.SYNOPSIS
    Wraps an operation with standardized error handling.

.PARAMETER Operation
    Description of the operation for logging.

.PARAMETER ScriptBlock
    The scriptblock to execute.

.PARAMETER ContinueOnError
    Continue execution even if the operation fails.

.EXAMPLE
    Invoke-Operation -Operation "Create Resource Group" -ScriptBlock {
        New-AzResourceGroup -Name $rgName -Location $location
    }
#>
function Invoke-Operation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [switch]$ContinueOnError
    )

    Write-Log -Level Info -Message "Starting: $Operation"
    
    try {
        $result = & $ScriptBlock
        Write-Log -Level Info -Message "Completed: $Operation"
        return $result
    }
    catch {
        $details = Get-ErrorDetails -ErrorRecord $_
        Write-Log -Level Error -Message "Failed: $Operation"
        Write-Log -Level Error -Message $details.Summary

        if (-not $ContinueOnError) {
            throw
        }
    }
}
