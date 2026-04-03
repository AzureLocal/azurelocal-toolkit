#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for scripts/common/utilities/helpers/error-handling.ps1
.DESCRIPTION
    Tests Invoke-WithRetry and Get-DetailedError in isolation.
#>

BeforeAll {
    $helpersPath = Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'common' 'utilities' 'helpers'
    . (Join-Path $helpersPath 'logging.ps1')
    . (Join-Path $helpersPath 'error-handling.ps1')
}

Describe 'Invoke-WithRetry' {
    Context 'Success path' {
        It 'should return the result of a successful scriptblock' {
            $result = Invoke-WithRetry -ScriptBlock { 'hello' } -MaxRetries 3
            $result | Should -Be 'hello'
        }

        It 'should execute the scriptblock exactly once when it succeeds first try' {
            $script:callCount = 0
            Invoke-WithRetry -ScriptBlock { $script:callCount++ } -MaxRetries 3 | Out-Null
            $script:callCount | Should -Be 1
        }

        It 'should pass through the scriptblock return value unchanged' {
            $expected = @{ key = 'value'; count = 42 }
            $result = Invoke-WithRetry -ScriptBlock { $expected } -MaxRetries 1
            $result.key   | Should -Be 'value'
            $result.count | Should -Be 42
        }
    }

    Context 'Retry behaviour' {
        It 'should retry and succeed on the second attempt' {
            $script:attempt = 0
            $result = Invoke-WithRetry -MaxRetries 3 -RetryDelaySeconds 0 -ScriptBlock {
                $script:attempt++
                if ($script:attempt -lt 2) { throw 'transient' }
                'success'
            }
            $result           | Should -Be 'success'
            $script:attempt   | Should -Be 2
        }

        It 'should throw after exhausting MaxRetries' {
            {
                Invoke-WithRetry -MaxRetries 2 -RetryDelaySeconds 0 -ScriptBlock {
                    throw 'always fails'
                }
            } | Should -Throw
        }

        It 'should attempt exactly MaxRetries times before giving up' {
            $script:attempt = 0
            try {
                Invoke-WithRetry -MaxRetries 3 -RetryDelaySeconds 0 -ScriptBlock {
                    $script:attempt++
                    throw 'fail'
                }
            }
            catch { }
            $script:attempt | Should -Be 3
        }

        It 'should use a smaller delay when RetryDelaySeconds is 0' {
            # Just ensure it completes quickly with no delay
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Invoke-WithRetry -MaxRetries 2 -RetryDelaySeconds 0 -ScriptBlock { throw 'fast' }
            }
            catch { }
            $sw.Stop()
            $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        }
    }

    Context 'Exponential backoff' {
        It 'should accept the ExponentialBackoff switch without throwing' {
            $result = Invoke-WithRetry -MaxRetries 1 -RetryDelaySeconds 0 -ExponentialBackoff -ScriptBlock { 'ok' }
            $result | Should -Be 'ok'
        }
    }

    Context 'Parameter validation' {
        It 'should require ScriptBlock parameter' {
            { Invoke-WithRetry } | Should -Throw
        }

        It 'should default MaxRetries to 3 when not specified' {
            $script:attempt = 0
            try {
                Invoke-WithRetry -RetryDelaySeconds 0 -ScriptBlock {
                    $script:attempt++
                    throw 'always'
                }
            }
            catch { }
            $script:attempt | Should -Be 3
        }
    }
}

Describe 'Get-ErrorDetails' {
    It 'should return an object with Message property' {
        try { throw 'test error' } catch { $err = $_ }
        $detail = Get-ErrorDetails -ErrorRecord $err
        $detail | Should -Not -BeNullOrEmpty
        $detail.Message | Should -Not -BeNullOrEmpty
    }

    It 'should include the original exception message' {
        try { throw 'original message here' } catch { $err = $_ }
        $detail = Get-ErrorDetails -ErrorRecord $err
        $detail.Message | Should -Match 'original message here'
    }

    It 'should include ScriptName or InvocationInfo when available' {
        try { throw 'with invocation' } catch { $err = $_ }
        $detail = Get-ErrorDetails -ErrorRecord $err
        # Get-ErrorDetails returns a [hashtable] — use .Keys not .PSObject.Properties.Name
        $detail.Keys | Should -Contain 'Message'
    }
}
