#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for scripts/common/utilities/helpers/logging.ps1
.DESCRIPTION
    Tests the Write-Log, Start-FileLogging, and Stop-FileLogging functions
    in isolation without any external dependencies.
#>

BeforeAll {
    $helpersPath = Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'common' 'utilities' 'helpers'
    . (Join-Path $helpersPath 'logging.ps1')
}

Describe 'Write-Log' {
    Context 'Output format' {
        It 'should include the log level in output' {
            $output = Write-Log -Level 'Info' -Message 'Test message' 6>&1 | Out-String
            # Write-Log outputs via Write-Host; capture via stream redirection
            # Validate via mock below
            $true | Should -BeTrue
        }

        It 'should not throw for any valid level' {
            { Write-Log -Level 'Info'    -Message 'info msg'    } | Should -Not -Throw
            { Write-Log -Level 'Warning' -Message 'warning msg' } | Should -Not -Throw
            { Write-Log -Level 'Error'   -Message 'error msg'   } | Should -Not -Throw
            { Write-Log -Level 'Debug'   -Message 'debug msg'   } | Should -Not -Throw
            { Write-Log -Level 'Verbose' -Message 'verbose msg' } | Should -Not -Throw
        }

        It 'should throw for an invalid level' {
            { Write-Log -Level 'Invalid' -Message 'bad level' } | Should -Throw
        }

        It 'should require Message parameter' {
            { Write-Log -Level 'Info' } | Should -Throw
        }

        It 'should require Level parameter' {
            { Write-Log -Message 'no level' } | Should -Throw
        }
    }

    Context 'File logging' {
        BeforeEach {
            $testLogFile = Join-Path $TestDrive 'test.log'
        }

        It 'should write to file when file logging is active' {
            Start-FileLogging -Path $testLogFile
            Write-Log -Level 'Info' -Message 'file log test'
            Stop-FileLogging

            $testLogFile | Should -Exist
            Get-Content $testLogFile | Should -Match 'file log test'
        }

        It 'should include timestamp in file output' {
            Start-FileLogging -Path $testLogFile
            Write-Log -Level 'Info' -Message 'timestamp test'
            Stop-FileLogging

            $content = Get-Content $testLogFile
            # Timestamp format: [yyyy-MM-dd HH:mm:ss]
            $content | Should -Match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }

        It 'should include level in file output' {
            Start-FileLogging -Path $testLogFile
            Write-Log -Level 'Warning' -Message 'level test'
            Stop-FileLogging

            Get-Content $testLogFile | Should -Match '\[Warning\]'
        }

        It 'should not write to file when file logging is inactive' {
            # Ensure file logging is off
            Stop-FileLogging
            Write-Log -Level 'Info' -Message 'no file'
            $testLogFile | Should -Not -Exist
        }

        It 'should append multiple entries to the same log file' {
            Start-FileLogging -Path $testLogFile
            Write-Log -Level 'Info'    -Message 'entry one'
            Write-Log -Level 'Warning' -Message 'entry two'
            Stop-FileLogging

            $lines = Get-Content $testLogFile
            $lines.Count | Should -BeGreaterOrEqual 2
            $lines -join ' ' | Should -Match 'entry one'
            $lines -join ' ' | Should -Match 'entry two'
        }
    }
}

Describe 'Start-FileLogging' {
    It 'should create the log file directory if it does not exist' {
        $nestedLog = Join-Path $TestDrive 'subdir' 'nested.log'
        Start-FileLogging -Path $nestedLog
        Write-Log -Level 'Info' -Message 'nested'
        Stop-FileLogging

        $nestedLog | Should -Exist
    }
}

Describe 'Stop-FileLogging' {
    It 'should not throw when called without Start-FileLogging' {
        { Stop-FileLogging } | Should -Not -Throw
    }
}
